package hxc.typing;

import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.WithType;
import hxc.core.TypingError;
import hxc.context.Context;
import hxc.typing.TyperContext.CurrentFun;

// Types class field bodies into expr, once signatures are resolved.
class TypeFields {
	public static function typeAllModules(ctx:Context):Void {
		var i = 0;
		while (i < ctx.modules.length) {
			typeModuleFields(ctx, ctx.modules[i]);
			i++;
		}
	}

	public static function typeModuleFields(ctx:Context, m:ModuleDef):Void {
		// A module pulled in while typing another may not have had its signatures resolved yet.
		TypeResolve.resolveModule(ctx, m);
		var savedMod = ctx.currentModule;
		ctx.currentModule = m;
		for (mt in m.types) {
			switch (mt) {
				case TClassDecl(c):
					var entry = ctx.declOfType.get(Context.pathKey(c.path));
					if (entry == null) continue;
					switch (entry.decl) {
						case EClass(d): typeClassFields(ctx, c, d);
						case _:
					}
				case _:
			}
		}
		ctx.currentModule = savedMod;
	}

	static function typeClassFields(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>):Void {
		var tctx = new TyperContext(ctx);
		tctx.curclass = c;
		tctx.typeParams = c.params;
		tctx.tthis = TInst(c, TypeFunctions.extractParamTypes(c.params));
		// On an abstract impl class a syntactically non-static field is a static member.
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		for (cff in d.dData) {
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			if (isAbsImpl && !isStatic && cff.cffName.name != "new") isStatic = true;
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(cff.cffName.name);
			if (cf == null) continue;
			try {
				initField(tctx, cf, cff, isStatic);
			} catch (_:haxe.Exception) {
				ctx.unresolvedFields++;
			}
		}
	}

	static function initField(tctx:TyperContext, cf:TClassField, cff:ClassField, isStatic:Bool):Void {
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
						var te = Typer.castOrUnify(tctx, cf.type, Typer.typeExpr(tctx, eo, WithTypeTools.withType(cf.type)), cff.cffPos);
						cf.expr = checkCast(te, cf.type);
					}
				case FFun(fd):
					var sig = switch (TypeFunctions.follow(cf.type)) { case TFun(s): s; case _: null; };
					var ret = sig != null ? sig.ret : tctx.t.tvoid;
					var args = buildArgs(tctx, sig, fd);
					var tf = Typer.typeFunction(tctx, args, ret, tctx.curfun, fd.fExpr, cff.cffPos);
					cf.expr = TypeFunctions.mk(TFunction(tf), cf.type, cff.cffPos);
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
