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
		return TypeFunctions.mk(TCall(fe, [e, typeExpr]), ret, p);
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
		var body = TypeFunctions.mk(TBlock([
			katch.declareHaxeException(catchVar.pos),
			katch.declareUnwrap(catchVar.pos),
			transformed
		]), t, p);
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
				var out = [catchesAsValueException(ctx, handleAsValueException, null, t, p)];
				if (valueExceptionCatch != null) out = out.concat(catchesToIfs(ctx, [valueExceptionCatch], t, p));
				return out;
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
				return [catchesAsValueException(ctx, handleAsValueException, null, t, p)].concat(catchesToIfs(ctx, cs, t, p));
			}
			if (ctx.catchesAnything && hxc.core.TypeUnification.fastEq(ctx.valueExceptionType, TypeFunctions.followWithAbstracts(v.type)))
				return [catchesAsValueException(ctx, handleAsValueException, current, t, p)]
					.concat(transform([], valueExceptionCatch != null ? valueExceptionCatch : current, rest));
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
		function loadType(dotted:String):T {
			if (dotted == "Dynamic" || dotted == "StdTypes.Dynamic") return TypeFunctions.tDynamic;
			var parts = dotted.split(".");
			var name = parts.pop();
			var mt = com.getType({pack: parts, name: name}, Position.nullPos);
			return switch (mt) {
				case TClassDecl(cls): TInst(cls, []);
				case TAbstractDecl(a): TAbstract(a, []);
				case _: throw new TypingError(dotted + " is expected to be a class or an abstract", Position.nullPos);
			};
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
		switch (com.getType({pack: ["haxe"], name: "Exception"}, Position.nullPos)) {
			case TClassDecl(cls):
				ctx.haxeExceptionClass = cls;
				ctx.haxeExceptionType = TInst(cls, []);
			case _: throw new TypingError("haxe.Exception is expected to be a class", Position.nullPos);
		}
		switch (com.getType({pack: ["haxe"], name: "ValueException"}, Position.nullPos)) {
			case TClassDecl(cls):
				ctx.valueExceptionClass = cls;
				ctx.valueExceptionType = TInst(cls, []);
			case _: throw new TypingError("haxe.ValueException is expected to be a class", Position.nullPos);
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
}
