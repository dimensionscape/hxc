package hxc.typing;

import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.Ref;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.WithType;
import hxc.core.TypingError;
import hxc.context.Context;
import hxc.typing.TyperContext.CurrentFun;

// Types class field bodies into expr. Field types are installed as TLazy so the first access to a
// field forces its body to type, resolving an inferred (unannotated) type before any consumer in
// another module can bind it. A final flush forces every remaining field.
class TypeFields {
	public static function typeAllModules(ctx:Context):Void {
		hxc.eval.EvalMacro.runBuildMacros(ctx);
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
					try cf.type = TypeFunctions.lazyType(r) catch (_:haxe.Exception) {}
				case _:
			}
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
			installField(ctx, tctx, m, cf, cff, isStatic);
			pending.push(cf);
		}
	}

	static function installField(ctx:Context, tctx:TyperContext, m:ModuleDef, cf:TClassField, cff:ClassField, isStatic:Bool):Void {
		// Idempotent: a field already lazy or already typed is left alone so typeAllModules can
		// be re-run to pick up modules loaded on demand.
		switch (cf.type) { case TLazy(_): return; case _: }
		if (cf.expr != null) return;
		var sigType = cf.type;
		var r = new Ref(LAvailable(sigType));
		var force = function():T {
			// Re-entry while typing returns the resolved signature, breaking cycles.
			r.set(LProcessing(function() return sigType));
			var savedMod = ctx.currentModule;
			ctx.currentModule = m;
			try {
				typeFieldBody(tctx, cf, cff, isStatic, sigType);
			} catch (_:haxe.Exception) {
				ctx.unresolvedFields++;
			}
			ctx.currentModule = savedMod;
			r.set(LAvailable(sigType));
			return sigType;
		};
		r.set(LWait(force));
		cf.type = TLazy(r);
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
			switch (cf.type) { case TLazy(r): try cf.type = TypeFunctions.lazyType(r) catch (_:haxe.Exception) {}; case _: }
			try typeFieldBody(tctx, cf, cff, isStatic, cf.type) catch (_:haxe.Exception) { ctx.unresolvedFields++; }
		}
		ctx.currentModule = savedMod;
	}

	static var _forcing:Array<TClassField> = [];

	// Type a single field body on demand. Inline expansion needs a callee body that may not be
	// installed yet (its module is processed later, or loaded on demand); the owning class is known
	// from the call site, so locate the syntactic field and run its body typing here.
	public static function forceFieldBody(ctx:Context, c:TClass, cf:TClassField):Void {
		if (cf.expr != null) return;
		// Only force at the outermost inline; a deep inline-call chain would otherwise recurse here
		// (the reference inlines opportunistically and never forces). Nested calls bail to a TCall.
		if (_forcing.length > 0) return;
		for (f in _forcing) if (f == cf) return;
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return;
		var d = switch (entry.decl) { case EClass(dd): dd; case _: return; };
		var cff:ClassField = null;
		for (f in d.dData) if (f.cffName.name == cf.name) { cff = f; break; }
		if (cff == null) return;
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
		try typeFieldBody(tctx, cf, cff, isStatic, cf.type) catch (_:haxe.Exception) {}
		ctx.currentModule = savedMod;
		_forcing.remove(cf);
	}

	static function typeFieldBody(tctx:TyperContext, cf:TClassField, cff:ClassField, isStatic:Bool, sigType:T):Void {
		var restore = Typer.saveLocals(tctx);
		var oldField = tctx.curfield;
		var oldFun = tctx.curfun;
		var oldParams = tctx.typeParams;
		// A static field sees only its own type params; the class params are out of scope.
		var isAbsImpl = switch (tctx.curclass.kind) { case KAbstractImpl(_): true; case _: false; };
		tctx.curfield = cf;
		tctx.curfun = isStatic ? FunStatic : (cff.cffName.name == "new" ? FunConstructor : FunMember);
		if (isStatic && !isAbsImpl) tctx.typeParams = [];
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
						var te = Typer.castOrUnify(tctx, sigType, Typer.typeExpr(tctx, eo, WithTypeTools.withType(sigType)), cff.cffPos);
						cf.expr = checkCast(te, sigType);
					}
				case FFun(fd):
					var sig = switch (TypeFunctions.follow(sigType)) { case TFun(s): s; case _: null; };
					var ret = sig != null ? sig.ret : tctx.t.tvoid;
					var args = buildArgs(tctx, sig, fd);
					var tf = Typer.typeFunction(tctx, args, ret, tctx.curfun, fd.fExpr, cff.cffPos);
					cf.expr = TypeFunctions.mk(TFunction(tf), sigType, cff.cffPos);
				case FProp(_, _, _, eo):
					// A physical property (e.g. (default,null)) can carry an initializer, bound to expr
					// exactly like a variable; the accessors are typed as their own get_/set_ methods.
					if (eo != null) {
						var te = Typer.castOrUnify(tctx, sigType, Typer.typeExpr(tctx, eo, WithTypeTools.withType(sigType)), cff.cffPos);
						cf.expr = checkCast(te, sigType);
					}
			}
		} catch (e:haxe.Exception) {
			cleanup();
			throw e;
		}
		cleanup();
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
			var v = TypeFunctions.allocVar(VUser(TVOArgument), fa.name.name, at, fa.name.pos);
			var def:Null<TExpr> = if (fa.value != null) Typer.typeExpr(tctx, fa.value, WithTypeTools.withType(at))
				else if (fa.opt) TypeFunctions.mk(TConst(TNull), at, fa.name.pos)
				else null;
			result.push({v: v, c: def});
		}
		return result;
	}
}
