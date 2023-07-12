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
				case FProp(_, _, _, _):
					// Property accessors are typed as their own get_/set_ methods
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
