package hxc.filters;

// hxc.filters.Exceptions: throw/try lowering and the stack-saving pass (constructor patching lives
// in typing/ExceptionFilters)

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.typing.TyperContext;

private class ExcContext {
	public var typer:TyperContext;
	public var basic:BasicTypes;
	public var wildcardCatchType:T;
	public var baseThrowType:T;
	public var throwsAnything:Bool;
	public var catchesAnything:Bool;
	public var haxeExceptionClass:TClass;
	public var haxeExceptionType:T;
	public var valueExceptionClass:TClass;
	public var valueExceptionType:T;
	public var nativeThrows:Array<String>;
	public var nativeCatches:Array<String>;

	public function new() {}
}

// The per-try temp-var pair (caught haxe.Exception + unwrapped value)
private class Catch {
	var ctx:ExcContext;
	var catchLocal:TExpr;
	var hxExceptionVar:Null<TVar> = null;
	var unwrappedVar:Null<TVar> = null;

	public function new(ctx:ExcContext, catchLocal:TExpr) {
		this.ctx = ctx;
		this.catchLocal = catchLocal;
	}

	public function getHaxeException(p:Position):TExpr {
		if (hxExceptionVar == null)
			hxExceptionVar = TypeFunctions.allocVar(VGenerated, "`", ctx.haxeExceptionType, p);
		return TypeFunctions.mk(TLocal(hxExceptionVar), hxExceptionVar.type, p);
	}

	public function unwrap(p:Position):TExpr {
		if (unwrappedVar == null)
			unwrappedVar = TypeFunctions.allocVar(VGenerated, "`", TypeFunctions.tDynamic, p);
		return TypeFunctions.mk(TLocal(unwrappedVar), unwrappedVar.type, p);
	}

	public function declareHaxeException(p:Position):TExpr {
		if (hxExceptionVar == null) return TypeFunctions.mk(TBlock([]), ctx.basic.tvoid, p);
		var caught = Exceptions.haxeExceptionStaticCall(ctx, "caught", [catchLocal], p);
		return TypeFunctions.mk(TVarExpr(hxExceptionVar, caught), ctx.basic.tvoid, p);
	}

	public function declareUnwrap(p:Position):TExpr {
		if (unwrappedVar == null) return TypeFunctions.mk(TBlock([]), ctx.basic.tvoid, p);
		var unwrapCall = Exceptions.haxeExceptionInstanceCall(ctx, getHaxeException(p), "unwrap", [], p);
		return TypeFunctions.mk(TVarExpr(unwrappedVar, unwrapCall), ctx.basic.tvoid, p);
	}
}

class Exceptions {
	static function isDynamicT(t:T):Bool {
		return switch (TypeFunctions.followWithAbstracts(t)) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Dynamic";
			case TDynamic(null): true;
			case _: false;
		};
	}

	static inline function mkCast(e:TExpr, t:T, p:Position):TExpr {
		return TypeFunctions.mk(TCast(e, null), t, p);
	}

	// haxe.Exception.<method>(args)
	@:allow(hxc.filters)
	static function haxeExceptionStaticCall(ctx:ExcContext, methodName:String, args:Array<TExpr>, p:Position):TExpr {
		var cf = ctx.haxeExceptionClass.statics.get(methodName);
		if (cf == null) throw new TypingError("haxe.Exception has no field " + methodName, p);
		// The field signature may not be typed yet at filter time
		hxc.typing.TypeFields.forceFieldBody(ctx.typer.com, ctx.haxeExceptionClass, cf);
		var ret = switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): sig.ret;
			case _: throw new TypingError("haxe.Exception." + methodName + " is not a function and cannot be called", p);
		};
		// The class being filtered depends on haxe.Exception's module.
		if (ctx.typer.curclass != null)
			hxc.context.ModuleLoader.addDependency(ctx.typer.curclass.module, ctx.haxeExceptionClass.module);
		var fe = TexprTools.makeStaticField(ctx.haxeExceptionClass, cf, p);
		return TypeFunctions.mk(TCall(fe, args), ret, p);
	}

	// <haxe.Exception value>.<method>(args)
	@:allow(hxc.filters)
	static function haxeExceptionInstanceCall(ctx:ExcContext, onExpr:TExpr, methodName:String, args:Array<TExpr>, p:Position):TExpr {
		var fa = try TypeFunctions.quickField(onExpr.type, methodName) catch (_:hxc.core.NotFound)
			throw new TypingError(methodName + " is expected to be an instance method", p);
		switch (fa) {
			case FInstance(cls, _, cf):
				hxc.typing.TypeFields.forceFieldBody(ctx.typer.com, cls, cf);
				var efield = TypeFunctions.mk(TField(onExpr, fa), cf.type, p);
				var ret = switch (TypeFunctions.follow(cf.type)) {
					case TFun(sig): sig.ret;
					case _: throw new TypingError(methodName + " is not a function and cannot be called", p);
				};
				return TypeFunctions.mk(TCall(efield, args), ret, p);
			case _:
				throw new TypingError(methodName + " is expected to be an instance method", p);
		}
	}

	// Std.isOfType(e, t)
	static function stdIs(ctx:ExcContext, e:TExpr, t:T, p:Position):TExpr {
		var t = TypeFunctions.follow(t);
		var stdCls = switch (ctx.typer.com.getType({pack: [], name: "Std"}, p)) {
			case TClassDecl(cls): cls;
			case _: throw new TypingError("Std is expected to be a class", p);
		};
		var cf = stdCls.statics.get("isOfType");
		if (cf == null) throw new TypingError("Std has no field isOfType", p);
		hxc.typing.TypeFields.forceFieldBody(ctx.typer.com, stdCls, cf);
		var ret = switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): sig.ret;
			case _: throw new TypingError("Std.isOfType is not a function and cannot be called", p);
		};
		var mt = try TypeFunctions.moduleTypeOfType(t) catch (_:hxc.core.ExitException) throw new TypingError("Unexpected type for Std.isOfType", p);
		var typeExpr = TypeFunctions.mk(TTypeExpr(mt), t, p);
		var fe = TexprTools.makeStaticField(stdCls, cf, p);
		// The static call routes through the typer's makeCall, so the inline js Std.isOfType folds through
		// apiInline to a typeof check.
		return hxc.typing.Calls.makeCall(ctx.typer, fe, [e, typeExpr], ret, p);
	}

	// Paths compare as dotted strings
	static function isInList(t:T, lst:Array<String>):Bool {
		if (lst.length == 0) return false;
		inline function pathIn(p:Path):Bool return lst.indexOf(Context.sTypePath(p)) >= 0;
		return switch (TypeFunctions.followWithAbstracts(t)) {
			case TInst(_, _):
				function check(cls:TClass):Bool {
					if (pathIn(cls.path)) return true;
					for (i in cls.interfaces) if (check(i.c)) return true;
					return cls.superClass != null && check(cls.superClass.c);
				}
				switch (TypeFunctions.follow(t)) {
					case TInst(cls, _): check(cls);
					case _: false;
				}
			case TAbstract(a, _): pathIn(a.path);
			case TEnum(en, _): pathIn(en.path);
			case _: false;
		};
	}

	static function isNativeThrow(ctx:ExcContext, t:T):Bool {
		return ctx.throwsAnything || isInList(t, ctx.nativeThrows);
	}

	static function isNativeCatch(ctx:ExcContext, t:T):Bool {
		return ctx.catchesAnything || isInList(t, ctx.nativeCatches);
	}

	// Wildcard = Dynamic or haxe.Exception itself
	static function isHaxeWildcardCatch(ctx:ExcContext, t:T):Bool {
		var t = TypeFunctions.followWithAbstracts(t);
		return t.match(TDynamic(null)) || isDynamicT(t) || hxc.core.TypeUnification.fastEq(ctx.haxeExceptionType, t);
	}

	static function isHaxeExceptionClass(cls:TClass, checkParent:Bool = true):Bool {
		if (cls.path.pack.length == 1 && cls.path.pack[0] == "haxe" && cls.path.name == "Exception") return true;
		return checkParent && cls.superClass != null && isHaxeExceptionClass(cls.superClass.c, checkParent);
	}

	static function isHaxeException(t:T, checkParent:Bool = true):Bool {
		return switch (TypeFunctions.followWithAbstracts(t)) {
			case TInst(cls, _): isHaxeExceptionClass(cls, checkParent);
			case _: false;
		};
	}

	static function isVarUsed(v:TVar, e:TExpr):Bool {
		return switch (e.expr) {
			case TLocal(v2): v == v2;
			case _: TexprTools.checkExpr(function(x) return isVarUsed(v, x), e);
		};
	}

	static function containsThrowOrTry(e:TExpr):Bool {
		return switch (e.expr) {
			case TThrow(_) | TTry(_, _): true;
			case _: TexprTools.checkExpr(containsThrowOrTry, e);
		};
	}

	static function isWrappedException(e:TExpr):Bool {
		return switch (e.expr) {
			case TMeta(m, _): m.name == ":wrappedException";
			case _: false;
		};
	}

	static function requiresWrappedThrow(ctx:ExcContext, e:TExpr):Bool {
		if (ctx.throwsAnything || isWrappedException(e)) return false;
		// A value of haxe.Exception type itself (not new) delegates the decision to Exception.thrown,
		// since it may wrap a wildcard catch
		var isStoredHaxeException = isHaxeException(e.type, false) && !e.expr.match(TNew(_, _, _));
		return isStoredHaxeException || (!isNativeThrow(ctx, e.type) && !isHaxeException(e.type));
	}

	static function throwNative(ctx:ExcContext, eThrown:TExpr, t:T, p:Position):TExpr {
		if (!requiresWrappedThrow(ctx, eThrown)) return eThrown;
		var thrown = haxeExceptionStaticCall(ctx, "thrown", [eThrown], p);
		var wrapped = isDynamicT(ctx.baseThrowType) ? thrown : mkCast(thrown, ctx.baseThrowType, p);
		return TypeFunctions.mk(TMeta({name: ":wrappedException", params: [], pos: p}, wrapped), thrown.type, p);
	}

	static function setNeedsExceptionStack(v:TVar):Void {
		if (!TypeFunctions.hasMeta(":needsExceptionStack", v.meta))
			v.meta = [({name: ":needsExceptionStack", params: [], pos: Position.nullPos} : hxc.ast.Ast.MetadataEntry)].concat(v.meta);
	}

	static function catchesToIfs(ctx:ExcContext, catches:Array<TCatch>, t:T, p:Position):Array<TCatch> {
		if (catches.length == 0) return [];
		var firstV = catches[0].v;
		var catchVar = TypeFunctions.allocVar(VGenerated, "`", ctx.wildcardCatchType, firstV.pos);
		TypeFunctions.addVarFlag(catchVar, VCaught);
		var catchLocal = TypeFunctions.mk(TLocal(catchVar), catchVar.type, catchVar.pos);
		var katch = new Catch(ctx, catchLocal);

		function compose(condition:TExpr, body:TExpr, rest:Array<TCatch>, transform:Array<TCatch>->TExpr):TExpr {
			var elseBody = rest.length == 0
				? TypeFunctions.mk(TThrow(catchLocal), TypeFunctions.mkMono(), p)
				: transform(rest);
			return TypeFunctions.mk(TIf(condition, body, elseBody), t, p);
		}

		var transform:Array<TCatch>->TExpr = null;
		transform = function(cs:Array<TCatch>):TExpr {
			if (cs.length == 0) return TypeFunctions.mk(TThrow(catchLocal), t, p);
			var v = cs[0].v;
			var body = cs[0].expr;
			var rest = cs.slice(1);
			var currentT = TypeFunctions.followWithAbstracts(v.type);
			var varUsed = isVarUsed(v, body);
			if (isHaxeException(currentT)) {
				// Catch(e:ExtendsHaxeException); catch(e:haxe.Exception) is a wildcard
				var condition = hxc.core.TypeUnification.fastEq(ctx.haxeExceptionType, currentT)
					? TypeFunctions.mk(TConst(TBool(true)), ctx.basic.tbool, v.pos)
					: stdIs(ctx, katch.getHaxeException(v.pos), v.type, v.pos);
				if (varUsed) {
					body = TypeFunctions.mk(TBlock([
						TypeFunctions.mk(TVarExpr(v, mkCast(katch.getHaxeException(v.pos), v.type, v.pos)), ctx.basic.tvoid, v.pos),
						body
					]), body.type, body.pos);
				}
				return compose(condition, body, rest, transform);
			} else if (currentT.match(TDynamic(null)) || isDynamicT(currentT)) {
				// Catch(e:Dynamic): a wildcard
				setNeedsExceptionStack(catchVar);
				var condition = TypeFunctions.mk(TConst(TBool(true)), ctx.basic.tbool, v.pos);
				var decl = varUsed
					? TypeFunctions.mk(TVarExpr(v, ctx.catchesAnything ? catchLocal : katch.unwrap(v.pos)), ctx.basic.tvoid, v.pos)
					: TypeFunctions.mk(TBlock([]), ctx.basic.tvoid, v.pos);
				body = TypeFunctions.mk(TBlock([decl, body]), body.type, body.pos);
				return compose(condition, body, rest, transform);
			} else if (hxc.core.TypeUnification.fastEq(ctx.wildcardCatchType, currentT)) {
				// Catch(e:NativeWildcardException): a wildcard
				setNeedsExceptionStack(catchVar);
				var condition = TypeFunctions.mk(TConst(TBool(true)), ctx.basic.tbool, v.pos);
				var decl = varUsed
					? TypeFunctions.mk(TVarExpr(v, catchLocal), ctx.basic.tvoid, v.pos)
					: TypeFunctions.mk(TBlock([]), ctx.basic.tvoid, v.pos);
				body = TypeFunctions.mk(TBlock([decl, body]), body.type, body.pos);
				return compose(condition, body, rest, transform);
			} else {
				// Anything else: match on the unwrapped value
				setNeedsExceptionStack(catchVar);
				var condition = stdIs(ctx, katch.unwrap(v.pos), v.type, v.pos);
				var decl = varUsed
					? TypeFunctions.mk(TVarExpr(v, mkCast(katch.unwrap(v.pos), v.type, v.pos)), ctx.basic.tvoid, v.pos)
					: TypeFunctions.mk(TBlock([]), ctx.basic.tvoid, v.pos);
				body = TypeFunctions.mk(TBlock([decl, body]), body.type, body.pos);
				return compose(condition, body, rest, transform);
			}
		}
		var transformed = transform(catches);
		// declareUnwrap runs before declareHaxeException: it creates the haxe-exception
		// temp on demand, and the declaration must see it
		var eUnwrap = katch.declareUnwrap(catchVar.pos);
		var eDeclareHx = katch.declareHaxeException(catchVar.pos);
		var body = TypeFunctions.mk(TBlock([eDeclareHx, eUnwrap, transformed]), t, p);
		return [{v: catchVar, expr: body}];
	}

	static function catchesAsValueException(ctx:ExcContext, nonValueCatches:Array<TCatch>, valueExceptionCatch:Null<TCatch>, t:T, p:Position):TCatch {
		if (nonValueCatches.length == 0 && valueExceptionCatch == null)
			throw new TypingError("Nothing to transform into ValueException catch", p);
		if (nonValueCatches.length == 0) return valueExceptionCatch;
		var catchVar = valueExceptionCatch != null
			? valueExceptionCatch.v
			: {
				var cv = TypeFunctions.allocVar(VGenerated, "`", ctx.valueExceptionType, nonValueCatches[0].v.pos);
				TypeFunctions.addVarFlag(cv, VCaught);
				cv;
			};
		var catchLocal = TypeFunctions.mk(TLocal(catchVar), catchVar.type, catchVar.pos);
		var valueCf = ctx.valueExceptionClass.fields.get("value");
		if (valueCf == null) throw new TypingError("haxe.ValueException is missing field value", p);
		var catchLocalValue = TypeFunctions.mk(TField(catchLocal, FInstance(ctx.valueExceptionClass, [], valueCf)), valueCf.type, catchLocal.pos);
		var finalElse = valueExceptionCatch != null
			? valueExceptionCatch.expr
			: TypeFunctions.mk(TThrow(catchLocal), TypeFunctions.tDynamic, p);
		function traverse(cs:Array<TCatch>):TExpr {
			if (cs.length == 0) return finalElse;
			var v = cs[0].v;
			var body = cs[0].expr;
			setNeedsExceptionStack(catchVar);
			var condition = stdIs(ctx, catchLocalValue, v.type, v.pos);
			var decl = isVarUsed(v, body)
				? TypeFunctions.mk(TVarExpr(v, mkCast(catchLocalValue, v.type, v.pos)), ctx.basic.tvoid, v.pos)
				: TypeFunctions.mk(TBlock([]), ctx.basic.tvoid, v.pos);
			body = TypeFunctions.mk(TBlock([decl, body]), body.type, body.pos);
			return TypeFunctions.mk(TIf(condition, body, traverse(cs.slice(1))), t, p);
		}
		return {v: catchVar, expr: traverse(nonValueCatches)};
	}

	static function catchNative(ctx:ExcContext, catches:Array<TCatch>, t:T, p:Position):Array<TCatch> {
		var transform:(Array<TCatch>, Null<TCatch>, Array<TCatch>)->Array<TCatch> = null;
		transform = function(handleAsValueException:Array<TCatch>, valueExceptionCatch:Null<TCatch>, cs:Array<TCatch>):Array<TCatch> {
			if (cs.length == 0) {
				if (handleAsValueException.length == 0 && valueExceptionCatch == null) return [];
				if (handleAsValueException.length == 0) return catchesToIfs(ctx, [valueExceptionCatch], t, p);
				// The tail is built first.
				var tail = valueExceptionCatch != null ? catchesToIfs(ctx, [valueExceptionCatch], t, p) : [];
				return [catchesAsValueException(ctx, handleAsValueException, null, t, p)].concat(tail);
			}
			var current = cs[0];
			var v = current.v;
			var rest = cs.slice(1);
			// Haxe-specific wildcards go to the if chain
			if (isHaxeWildcardCatch(ctx, v.type)) {
				if (handleAsValueException.length == 0 && valueExceptionCatch == null)
					return catchesToIfs(ctx, cs, t, p);
				if (handleAsValueException.length == 0)
					return catchesToIfs(ctx, [valueExceptionCatch].concat(cs), t, p);
				// The tail is built first.
				var tail = catchesToIfs(ctx, cs, t, p);
				return [catchesAsValueException(ctx, handleAsValueException, null, t, p)].concat(tail);
			}
			if (ctx.catchesAnything && hxc.core.TypeUnification.fastEq(ctx.valueExceptionType, TypeFunctions.followWithAbstracts(v.type))) {
				// The tail is built first.
				var tail = transform([], valueExceptionCatch != null ? valueExceptionCatch : current, rest);
				return [catchesAsValueException(ctx, handleAsValueException, current, t, p)].concat(tail);
			}
			// Native catches stay intact
			if (isNativeCatch(ctx, v.type)) {
				var nextHandle = (ctx.catchesAnything && !isHaxeException(v.type))
					? [current].concat(handleAsValueException)
					: handleAsValueException;
				return [current].concat(transform(nextHandle, valueExceptionCatch, rest));
			}
			// Everything else goes to the if chain
			return catchesToIfs(ctx, handleAsValueException.concat(cs), t, p);
		}
		return transform([], null, catches);
	}

	public static function filter(tctx:TyperContext):TExpr->TExpr {
		var com = tctx.com;
		switch (com.platform) {
			case Js | Eval | Cpp:
			case _: return function(e) return e;
		}
		var cfg = com.platformConfig;
		function resolved(mt:ModuleType):ModuleType {
			// A type loaded on demand at filter time needs its signatures resolved and its field bodies
			// typed; the load-time typing passes have already run
			var m = TypeFunctions.tInfos(mt).module;
			try hxc.typing.TypeResolve.resolveModule(com, m) catch (_:Dynamic) {}
			for (t in m.types) switch (t) {
				case TClassDecl(c): try hxc.typing.TypeFields.forceClassFields(com, c) catch (_:Dynamic) {}
				case _:
			}
			return mt;
		}
		// A path whose last package part is not a lower ident names a module's sub-type. The types load
		// from the typer's current module - the module of the last class the first filter pass visited -
		// so a path with no package walks that module's package first.
		function tp(dotted:String):hxc.ast.Ast.TypePath {
			var parts = dotted.split(".");
			var name = parts.pop();
			if (parts.length > 0 && !hxc.ast.Ast.isLowerIdent(parts[parts.length - 1])) {
				var moduleName = parts.pop();
				return {tpackage: parts, tname: moduleName, tparams: [], tsub: name};
			}
			return {tpackage: parts, tname: name, tparams: [], tsub: null};
		}
		function load(dotted:String):T {
			// The filters' context's module, nullModule included: addDependency ignores that one.
			var saved = com.currentModule;
			com.currentModule = tctx.filterModule;
			var t = try hxc.typing.Typeload.loadInstance(com, [], tp(dotted), Position.nullPos, true)
				catch (e:Dynamic) { com.currentModule = saved; throw e; };
			com.currentModule = saved;
			var mt = try TypeFunctions.moduleTypeOfType(t) catch (_:hxc.core.ExitException) null;
			if (mt != null) resolved(mt);
			return t;
		}
		function loadType(dotted:String):T {
			var t = load(dotted);
			return isDynamicT(t) ? TypeFunctions.tDynamic : t;
		}
		var ctx = new ExcContext();
		ctx.typer = tctx;
		ctx.basic = com.basic;
		ctx.nativeThrows = cfg.nativeThrows;
		ctx.nativeCatches = cfg.nativeCatches;
		ctx.wildcardCatchType = loadType(cfg.wildcardCatch);
		ctx.baseThrowType = loadType(cfg.baseThrow);
		var isDynPath = function(dotted:String) return dotted == "Dynamic" || dotted == "StdTypes.Dynamic";
		ctx.throwsAnything = isDynPath(cfg.baseThrow) && cfg.avoidWrapping;
		ctx.catchesAnything = isDynPath(cfg.wildcardCatch) && cfg.avoidWrapping;
		switch (load("haxe.Exception")) {
			case t = TInst(cls, _):
				ctx.haxeExceptionClass = cls;
				ctx.haxeExceptionType = t;
			case _: throw new TypingError("haxe.Exception is expected to be a class", Position.nullPos);
		}
		switch (load("haxe.ValueException")) {
			case t = TInst(cls, _):
				ctx.valueExceptionClass = cls;
				ctx.valueExceptionType = t;
			case _: throw new TypingError("haxe.ValueException is expected to be a class", Position.nullPos);
		}
		// haxe.NativeStackTrace is loaded here too, a class or an abstract with an impl.
		switch (load("haxe.NativeStackTrace")) {
			case TInst(_, _):
			case TAbstract(a, _) if (a.impl != null):
			case _: throw new TypingError("haxe.NativeStackTrace is expected to be a class or an abstract", Position.nullPos);
		}
		var run:TExpr->TExpr = null;
		run = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TThrow(e1):
					TypeFunctions.mk(TThrow(throwNative(ctx, run(e1), e.type, e.pos)), e.type, e.pos);
				case TTry(e1, catches):
					var catches2 = catchNative(ctx, [for (c in catches) {v: c.v, expr: run(c.expr)}], e.type, e.pos);
					TypeFunctions.mk(TTry(run(e1), catches2), e.type, e.pos);
				case _:
					TexprTools.mapExpr(run, e);
			};
		}
		return function(e:TExpr):TExpr {
			return containsThrowOrTry(e) ? run(e) : e;
		};
	}

	// A catch that keeps the exception stack calls haxe.NativeStackTrace.saveStack(e) first. Runs
	// post-DCE so the feature flag is accurate.
	public static function insertSaveStacks(tctx:TyperContext):TExpr->TExpr {
		var com = tctx.com;
		function nop(e:TExpr):TExpr return e;
		if (!com.hasFeature("haxe.NativeStackTrace.exceptionStack")) return nop;
		var nst:Null<TClass> = switch (com.getType({pack: ["haxe"], name: "NativeStackTrace"}, Position.nullPos)) {
			case TClassDecl(c): try hxc.typing.TypeResolve.resolveModule(com, c.module) catch (_:Dynamic) {}; c;
			case TAbstractDecl(a) if (a.impl != null): a.impl;
			case _: null;
		};
		if (nst == null) return nop;
		var saveCf = nst.statics.get("saveStack");
		if (saveCf == null) return nop;
		function saveStack(v:TVar):TExpr {
			hxc.typing.TypeFields.forceFieldBody(com, nst, saveCf);
			var ret = switch (TypeFunctions.follow(saveCf.type)) { case TFun(sig): sig.ret; case _: com.basic.tvoid; };
			var catchLocal = TypeFunctions.mk(TLocal(v), v.type, v.pos);
			// The class depends on haxe.NativeStackTrace's module.
			if (tctx.curclass != null) hxc.context.ModuleLoader.addDependency(tctx.curclass.module, nst.module);
			var fe = TexprTools.makeStaticField(nst, saveCf, v.pos);
			// makeCall inlines saveStack (an inline function) in place, so it becomes the field write
			return hxc.typing.Calls.makeCall(tctx, fe, [catchLocal], ret, v.pos);
		}
		function run(e:TExpr):TExpr {
			return switch (e.expr) {
				case TTry(e1, catches):
					// Only the TRY body recurses; catch bodies are used as-is, so a nested try inside a catch gets
					// no stack save.
					var nc = [for (c in catches) {
						var body = c.expr;
						if (TypeFunctions.hasMeta(":needsExceptionStack", c.v.meta)) {
							var stmts = switch (body.expr) {
								case TBlock(el): [saveStack(c.v)].concat(el);
								case _: [saveStack(c.v), body];
							};
							{v: c.v, expr: TypeFunctions.mk(TBlock(stmts), body.type, body.pos)};
						} else {v: c.v, expr: body};
					}];
					TypeFunctions.mk(TTry(TexprTools.mapExpr(run, e1), nc), e.type, e.pos);
				case _:
					TexprTools.mapExpr(run, e);
			};
		}
		return run;
	}
}
