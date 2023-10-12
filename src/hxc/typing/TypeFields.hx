package hxc.typing;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.Ref;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TexprTools;
import hxc.core.WithType;
import hxc.core.TypingError;
import hxc.context.Context;
import hxc.context.Context.ContextError;
import hxc.eval.EvalExceptions.EvalRunTimeException;
import hxc.eval.EvalStdLib;
import hxc.typing.TyperContext.CurrentFun;

// Types class field bodies into expr. Field types are installed as TLazy so the first access to a
// field forces its body to type, resolving an inferred (unannotated) type before any consumer in
// another module can bind it. A final flush forces every remaining field.
class TypeFields {
	static var lazyFieldTypes:haxe.ds.ObjectMap<TClassField, T> = new haxe.ds.ObjectMap();
	// Field bodies whose typing has been attempted. A body that errors leaves expr null, so the
	// expr idempotency guard alone would let a later installAndForce pass (re-run when a body loads
	// modules on demand) re-type it and re-report its errors. Each body is typed at most once.
	static var bodyTyped:haxe.ds.ObjectMap<TClassField, Bool> = new haxe.ds.ObjectMap();

	public static function typeAllModules(ctx:Context):Void {
		if (!ctx.isMacro) hxc.eval.EvalMacro.runBuildMacros(ctx);
		// installAndForce is single-pass; a body it types can load more modules on demand. Repeat
		// at the top level until the module set is closed (installAndForce stays re-entrancy-safe
		// for the nested call build macros make).
		var n = -1;
		while (ctx.modules.length != n) {
			n = ctx.modules.length;
			installAndForce(ctx);
		}
	}

	// Install lazy field typers for every loaded module and force them. Separate from the build
	// pre-pass so the macro interpreter can re-run this without recursing into build macros.
	public static function installAndForce(ctx:Context):Void {
		var pending:Array<TClassField> = [];
		var i = 0;
		while (i < ctx.modules.length) {
			installModuleFields(ctx, ctx.modules[i], pending);
			i++;
		}
		// Force any field not reached on demand, then unwrap the lazy back to its concrete
		// signature so downstream consumers never see a TLazy.
		for (cf in pending) {
			switch (cf.type) {
				case TLazy(r):
					try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e);
				case _:
			}
		}
	}

	static function recordFieldError(ctx:Context, e:Dynamic):Void {
		if (Std.isOfType(e, TypingError)) {
			var te:TypingError = cast e;
			ctx.addDiagnostic(te.message, te.pos);
		} else if (Std.isOfType(e, ContextError)) {
			var ce:ContextError = cast e;
			ctx.addDiagnostic(ce.message, ce.pos);
		} else if (Std.isOfType(e, EvalRunTimeException)) {
			var re:EvalRunTimeException = cast e;
			ctx.addDiagnostic(EvalStdLib.stringOf(re.value), re.pos);
		} else if (Std.isOfType(e, haxe.Exception)) {
			ctx.unresolvedFields++;
		} else {
			throw e;
		}
	}

	public static function installLazy(ctx:Context):Void {
		var pending:Array<TClassField> = [];
		var i = 0;
		while (i < ctx.modules.length) {
			installModuleFields(ctx, ctx.modules[i], pending);
			i++;
		}
	}

	static function installModuleFields(ctx:Context, m:ModuleDef, pending:Array<TClassField>):Void {
		TypeResolve.resolveModule(ctx, m);
		for (mt in m.types) {
			switch (mt) {
				case TClassDecl(c):
					var entry = ctx.declOfType.get(Context.pathKey(c.path));
					if (entry == null) continue;
					switch (entry.decl) {
						case EClass(d): installClassFields(ctx, c, d, m, pending);
						case _:
					}
				case _:
			}
		}
	}

	static function installClassFields(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, m:ModuleDef, pending:Array<TClassField>):Void {
		var tctx = new TyperContext(ctx);
		tctx.curclass = c;
		tctx.typeParams = c.params;
		tctx.tthis = TInst(c, TypeFunctions.extractParamTypes(c.params));
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		for (cff in d.dData) {
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			if (isAbsImpl && !isStatic && cff.cffName.name != "new") isStatic = true;
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(cff.cffName.name);
			if (cf == null) continue;
			if (!hasFieldBody(cff)) continue;
			if (TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) continue;
			installField(ctx, tctx, m, cf, cff, isStatic);
			pending.push(cf);
		}
	}

	static function hasFieldBody(cff:ClassField):Bool {
		return switch (cff.cffKind) {
			case FVar(_, eo) | FProp(_, _, _, eo): eo != null;
			case FFun(fd): fd.fExpr != null;
		};
	}

	public static function fieldHasSyntaxBody(ctx:Context, c:TClass, cf:TClassField):Bool {
		var cff = findFieldDecl(ctx, c, cf);
		return cff != null && hasFieldBody(cff);
	}

	// A macro function is typed only in the macro world; in the host (non-macro) context its body is
	// discarded and it is invoked through the macro interpreter. Its body must not be host-typed (it
	// references haxe.macro.* identifiers that resolve only under `macro`).
	static function skipMacroBodyInHost(ctx:Context, cf:TClassField):Bool {
		return !ctx.isMacro && cf.kind.match(Method(MethMacro));
	}

	static function installField(ctx:Context, tctx:TyperContext, m:ModuleDef, cf:TClassField, cff:ClassField, isStatic:Bool):Void {
		// Idempotent: a field already lazy or already typed is left alone so typeAllModules can
		// be re-run to pick up modules loaded on demand.
		switch (cf.type) { case TLazy(_): return; case _: }
		if (cf.expr != null) return;
		// A body that already ran (successfully or with an error) is not re-typed on later passes.
		if (bodyTyped.exists(cf)) return;
		if (skipMacroBodyInHost(ctx, cf)) return;
		var sigType = cf.type;
		lazyFieldTypes.set(cf, sigType);
		var r = new Ref(LAvailable(sigType));
		var force = function():T {
			for (f in _forcing) if (f == cf) return sigType;
			// Re-entry while typing returns the resolved signature, breaking cycles.
			r.set(LProcessing(function() return sigType));
			cf.type = sigType;
			_forcing.push(cf);
			var savedMod = ctx.currentModule;
			ctx.currentModule = m;
			try {
				typeFieldBody(tctx, cf, cff, isStatic, sigType);
			} catch (e:Dynamic) recordFieldError(ctx, e);
			ctx.currentModule = savedMod;
			_forcing.remove(cf);
			r.set(LAvailable(sigType));
			return sigType;
		};
		r.set(LWait(force));
		cf.type = TLazy(r);
	}

	public static function fieldCallType(cf:TClassField):T {
		return switch (cf.type) {
			case TLazy(_):
				var t = lazyFieldTypes.get(cf);
				t == null ? cf.type : t;
			case _:
				cf.type;
		}
	}

	// Force the field bodies of a single class whose fields were just rewritten by a @:build macro.
	// A full installAndForce per build is O(builds x modules) and re-enters through lazy typing; this
	// types only the rewritten class, so the cost stays proportional to the fields actually added.
	public static function forceClassFields(ctx:Context, c:TClass):Void {
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return;
		var d = switch (entry.decl) { case EClass(dd): dd; case _: return; };
		var tctx = new TyperContext(ctx);
		tctx.curclass = c;
		tctx.typeParams = c.params;
		tctx.tthis = TInst(c, TypeFunctions.extractParamTypes(c.params));
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var savedMod = ctx.currentModule;
		ctx.currentModule = c.module;
		for (cff in d.dData) {
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			if (isAbsImpl && !isStatic && cff.cffName.name != "new") isStatic = true;
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(cff.cffName.name);
			if (cf == null || cf.expr != null) continue;
			if (!hasFieldBody(cff)) continue;
			if (TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) continue;
			if (skipMacroBodyInHost(ctx, cf)) continue;
			switch (cf.type) { case TLazy(r): try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e); case _: }
			try {
				typeFieldBody(tctx, cf, cff, isStatic, cf.type);
			} catch (e:Dynamic) recordFieldError(ctx, e);
		}
		ctx.currentModule = savedMod;
	}

	static var _forcing:Array<TClassField> = [];

	// Type a single field body on demand. Inline expansion needs a callee body that may not be
	// installed yet (its module is processed later, or loaded on demand); the owning class is known
	// from the call site, so locate the syntactic field and run its body typing here.
	public static function forceFieldBody(ctx:Context, c:TClass, cf:TClassField):Void {
		if (cf.expr != null) return;
		switch (cf.type) {
			case TLazy(r):
				try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e);
				if (cf.expr != null) return;
			case _:
		}
		// Re-entry on the same field returns its current (still-open) signature, as a lazy type still in
		// progress does. A different field is forced normally even when nested, so an inline callee's
		// return type is inferred before its result is consumed by the caller.
		for (f in _forcing) if (f == cf) return;
		var cff = findFieldDecl(ctx, c, cf);
		if (cff == null) return;
		if (!hasFieldBody(cff)) return;
		var isInlineField = switch (cf.kind) { case Method(MethInline) | Var({read: AccInline}): true; case _: false; };
		if ((TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) && !isInlineField) return;
		if (skipMacroBodyInHost(ctx, cf)) return;
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var isStatic = false;
		for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
		if (isAbsImpl && !isStatic && cff.cffName.name != "new") isStatic = true;
		var tctx = new TyperContext(ctx);
		tctx.curclass = c;
		tctx.typeParams = c.params;
		tctx.tthis = TInst(c, TypeFunctions.extractParamTypes(c.params));
		_forcing.push(cf);
		var savedMod = ctx.currentModule;
		ctx.currentModule = c.module;
		try {
			typeFieldBody(tctx, cf, cff, isStatic, cf.type);
		} catch (e:Dynamic) recordFieldError(ctx, e);
		ctx.currentModule = savedMod;
		_forcing.remove(cf);
	}

	static function findFieldDecl(ctx:Context, c:TClass, cf:TClassField):Null<ClassField> {
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return null;
		var d = switch (entry.decl) { case EClass(dd): dd; case _: return null; };
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var nameSeen = new haxe.ds.StringMap<Int>();
		for (f in d.dData) {
			var fStatic = false;
			for (a in f.cffAccess) if (a.access == AStatic) fStatic = true;
			if (isAbsImpl && !fStatic && f.cffName.name != "new") fStatic = true;
			var base = if (!fStatic && f.cffName.name == "new") c.constructor
				else (fStatic ? c.statics : c.fields).get(f.cffName.name);
			if (base == null) continue;
			var key = (fStatic ? "s:" : "i:") + f.cffName.name;
			var occ = nameSeen.exists(key) ? nameSeen.get(key) : 0;
			nameSeen.set(key, occ + 1);
			var target = if (occ > 0 && base.overloads.length >= occ) base.overloads[base.overloads.length - occ] else base;
			if (target == cf) return f;
		}
		return null;
	}

	static function typeFieldBody(tctx:TyperContext, cf:TClassField, cff:ClassField, isStatic:Bool, sigType:T):Void {
		bodyTyped.set(cf, true);
		var restore = Typer.saveLocals(tctx);
		// A field body starts with no locals in scope. Lazy typing can force one body while another is
		// still open (its type is queried from the first body), so start clean and let restore() give
		// the caller its locals back; otherwise a stale local shadows a same-named member.
		tctx.locals = new haxe.ds.StringMap();
		var oldField = tctx.curfield;
		var oldFun = tctx.curfun;
		var oldParams = tctx.typeParams;
		// A static field sees only its own type params; the class params are out of scope. The exception is
		// an abstract member (CfImpl): its body references the abstract's own type params (via the
		// underlying `this` type), so put those in scope.
		var abstractParams = switch (tctx.curclass.kind) { case KAbstractImpl(a): a.params; case _: null; };
		var isAbsImpl = abstractParams != null;
		var isAbstractMember = isAbsImpl && TypeFunctions.hasClassFieldFlag(cf, CfImpl);
		tctx.curfield = cf;
		tctx.curfun = isAbstractMember ? FunMemberAbstract : (isStatic ? FunStatic : (cff.cffName.name == "new" ? FunConstructor : FunMember));
		if (isAbstractMember) tctx.typeParams = abstractParams;
		else if (isStatic && !isAbsImpl) tctx.typeParams = [];
		// The method's own type parameters are in scope within its body.
		if (cf.params.length > 0) tctx.typeParams = tctx.typeParams.concat(cf.params);
		function cleanup() {
			tctx.curfield = oldField;
			tctx.curfun = oldFun;
			tctx.typeParams = oldParams;
			restore();
		}
		try {
			switch (cff.cffKind) {
				case FVar(_, eo):
					if (eo != null) {
						setValueMeta(cf, [eo]);
						var te = typeVarInitializer(tctx, sigType, eo, hasVarHint(cff.cffKind), cff.cffPos);
						cf.expr = checkCast(te, sigType);
					}
				case FFun(fd):
					setFunctionValueMeta(cf, fd);
					var sig = switch (TypeFunctions.follow(sigType)) { case TFun(s): s; case _: null; };
					var ret = sig != null ? sig.ret : tctx.t.tvoid;
					var args = buildArgs(tctx, sig, fd);
					var tf = Typer.typeFunction(tctx, args, ret, tctx.curfun, fd.fExpr, cff.cffPos);
					tf.expr = localStatics(tctx, tf.expr);
					cf.expr = TypeFunctions.mk(TFunction(tf), sigType, cff.cffPos);
				case FProp(_, _, _, eo):
					// A physical property (e.g. (default,null)) can carry an initializer, bound to expr
					// exactly like a variable; the accessors are typed as their own get_/set_ methods.
					if (eo != null) {
						setValueMeta(cf, [eo]);
						var te = typeVarInitializer(tctx, sigType, eo, hasVarHint(cff.cffKind), cff.cffPos);
						cf.expr = checkCast(te, sigType);
					}
			}
		} catch (e:haxe.Exception) {
			cleanup();
			throw e;
		}
		cleanup();
	}

	static function setValueMeta(cf:TClassField, params:Array<Expr>):Void {
		cf.meta = [{name: ":value", params: params, pos: cf.pos}].concat([for (m in cf.meta) if (m.name != ":value") m]);
	}

	static function setFunctionValueMeta(cf:TClassField, fd:Func):Void {
		var fields:Array<ObjectField> = [];
		for (arg in fd.fArgs) if (arg.value != null)
			fields.push({name: arg.name.name, pos: arg.name.pos, quotes: NoQuotes, expr: arg.value});
		if (fields.length > 0)
			setValueMeta(cf, [new Expr(EObjectDecl(fields), cf.pos)]);
	}

	static function hasVarHint(k:ClassFieldKind):Bool {
		return switch (k) {
			case FVar(th, _) | FProp(_, _, th, _): th != null;
			case _: true;
		};
	}

	static function typeVarInitializer(tctx:TyperContext, sigType:T, eo:Expr, hasHint:Bool, p:Position):TExpr {
		if (hasHint) return Typer.castOrUnify(tctx, sigType, Typer.typeExpr(tctx, eo, WithTypeTools.withType(sigType)), p);
		var te = Typer.typeExpr(tctx, eo, WithTypeTools.value);
		TypeUnification.unifyDefault(te.type, sigType);
		return te;
	}

	static function promoteLocalStatic(tctx:TyperContext, lut:Map<Int, TClassField>, v:TVar, eo:Null<TExpr>):Void {
		var name = tctx.curfield.name + "_" + v.name;
		if (tctx.curclass.statics.exists(name))
			throw new TypingError("The expanded name of this local (" + name + ") conflicts with another static field", v.pos);
		if (eo != null) checkLocalStaticInit(eo);
		var cf = TypeFunctions.mkField(name, v.type, v.pos, v.pos, false, true);
		cf.meta = [{name: ":noCompletion", params: [], pos: Position.nullPos}].concat(v.meta);
		TypeFunctions.addClassFieldFlag(cf, CfNoLookup);
		cf.expr = eo;
		tctx.curclass.statics.set(name, cf);
		tctx.curclass.orderedStatics.push(cf);
		lut.set(v.id, cf);
	}

	static function checkLocalStaticInit(e:TExpr):Void {
		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TLocal(_) | TFunction(_):
					throw new TypingError("Accessing local variables in static initialization is not allowed", e.pos);
				case TConst(TThis) | TConst(TSuper):
					throw new TypingError("Accessing `this` in static initialization is not allowed", e.pos);
				case TReturn(_) | TBreak | TContinue:
					throw new TypingError("This kind of control flow in static initialization is not allowed", e.pos);
				case TArray(e1, e2) | TBinop(_, e1, e2):
					loop(e1); loop(e2);
				case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TThrow(e1) | TCast(e1, _) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1):
					loop(e1);
				case TObjectDecl(fields):
					for (f in fields) loop(f.expr);
				case TArrayDecl(el) | TBlock(el):
					for (x in el) loop(x);
				case TCall(e1, el):
					loop(e1);
					for (x in el) loop(x);
				case TNew(_, _, el):
					for (x in el) loop(x);
				case TVarExpr(_, eo):
					if (eo != null) loop(eo);
				case TFor(_, e1, e2):
					loop(e1); loop(e2);
				case TIf(e1, e2, e3):
					loop(e1); loop(e2); if (e3 != null) loop(e3);
				case TWhile(e1, e2, _):
					loop(e1); loop(e2);
				case TSwitch(e1, cases, edef):
					loop(e1);
					for (c in cases) {
						for (v in c.values) loop(v);
						loop(c.expr);
					}
					if (edef != null) loop(edef);
				case TTry(e1, catches):
					loop(e1);
					for (c in catches) loop(c.expr);
				case TConst(_) | TTypeExpr(_) | TIdent(_):
			}
		}
		loop(e);
	}

	static function localStatics(tctx:TyperContext, e:TExpr):TExpr {
		var lut:Map<Int, TClassField> = new Map();
		var loop:TExpr->TExpr = null;
		function opt(e:Null<TExpr>):Null<TExpr> return e == null ? null : loop(e);
		function arr(el:Array<TExpr>):Array<TExpr> return [for (x in el) loop(x)];
		loop = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TBlock(el):
					var out:Array<TExpr> = [];
					for (x in el) switch (x.expr) {
						case TVarExpr(v, eo) if (TypeFunctions.hasVarFlag(v, VStatic)):
							promoteLocalStatic(tctx, lut, v, eo);
						case _:
							out.push(loop(x));
					}
					e.expr = TBlock(out);
					e;
				case TLocal(v) if (TypeFunctions.hasVarFlag(v, VStatic)):
					var cf = lut.get(v.id);
					if (cf == null) throw new TypingError("Could not find local static " + v.name + " (id " + v.id + ")", e.pos);
					TexprTools.makeStaticField(tctx.curclass, cf, e.pos);
				case TArray(e1, e2): e.expr = TArray(loop(e1), loop(e2)); e;
				case TBinop(op, e1, e2): e.expr = TBinop(op, loop(e1), loop(e2)); e;
				case TField(e1, fa): e.expr = TField(loop(e1), fa); e;
				case TParenthesis(e1): e.expr = TParenthesis(loop(e1)); e;
				case TObjectDecl(fields): e.expr = TObjectDecl([for (f in fields) {key: f.key, expr: loop(f.expr)}]); e;
				case TArrayDecl(values): e.expr = TArrayDecl(arr(values)); e;
				case TCall(e1, params): e.expr = TCall(loop(e1), arr(params)); e;
				case TNew(c, params, args): e.expr = TNew(c, params, arr(args)); e;
				case TUnop(op, flag, e1): e.expr = TUnop(op, flag, loop(e1)); e;
				case TFunction(f): f.expr = loop(f.expr); e;
				case TVarExpr(v, eo): e.expr = TVarExpr(v, opt(eo)); e;
				case TFor(v, e1, e2): e.expr = TFor(v, loop(e1), loop(e2)); e;
				case TIf(econd, eif, eelse): e.expr = TIf(loop(econd), loop(eif), opt(eelse)); e;
				case TWhile(econd, body, flag): e.expr = TWhile(loop(econd), loop(body), flag); e;
				case TSwitch(subject, cases, edef):
					e.expr = TSwitch(loop(subject), [for (c in cases) {values: arr(c.values), expr: loop(c.expr)}], opt(edef));
					e;
				case TTry(e1, catches): e.expr = TTry(loop(e1), [for (c in catches) {v: c.v, expr: loop(c.expr)}]); e;
				case TReturn(eo): e.expr = TReturn(opt(eo)); e;
				case TThrow(e1): e.expr = TThrow(loop(e1)); e;
				case TCast(e1, mt): e.expr = TCast(loop(e1), mt); e;
				case TMeta(entry, e1): e.expr = TMeta(entry, loop(e1)); e;
				case TEnumParameter(e1, ef, index): e.expr = TEnumParameter(loop(e1), ef, index); e;
				case TEnumIndex(e1): e.expr = TEnumIndex(loop(e1)); e;
				case TConst(_) | TTypeExpr(_) | TIdent(_) | TBreak | TContinue | TLocal(_): e;
			}
		};
		return loop(e);
	}

	// An Int literal bound to a Float field is rewritten to a Float literal.
	static function checkCast(te:TExpr, t:T):TExpr {
		if (TypeUnification.typeIseqDefault(te.type, t)) return te;
		return switch ([te.expr, TypeFunctions.follow(t)]) {
			case [TConst(TInt(i)), TAbstract(a, _)] if (a.path.pack.length == 0 && a.path.name == "Float"):
				TypeFunctions.mk(TConst(TFloat(Std.string(i))), t, te.pos);
			case _: te;
		};
	}

	static function buildArgs(tctx:TyperContext, sig:Null<TSignature>, fd:Func):Array<TFuncArg> {
		var result:Array<TFuncArg> = [];
		for (i in 0...fd.fArgs.length) {
			var fa = fd.fArgs[i];
			var at = (sig != null && i < sig.args.length) ? sig.args[i].t : TypeFunctions.mkMono();
			var kind = if (tctx.curfun.match(FunMemberAbstract) && i == 0 && fa.name.name == "this") VAbstractThis else VUser(TVOArgument);
			var v = TypeFunctions.allocVar(kind, fa.name.name, at, fa.name.pos);
			var def:Null<TExpr> = if (fa.value != null) Typer.typeExpr(tctx, fa.value, WithTypeTools.withType(at))
				else if (fa.opt) TypeFunctions.mk(TConst(TNull), at, fa.name.pos)
				else null;
			result.push({v: v, c: def});
		}
		return result;
	}
}
