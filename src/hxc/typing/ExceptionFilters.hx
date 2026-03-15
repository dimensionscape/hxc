package hxc.typing;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;

// Adds `this.__shiftStack()` to every constructor of a class extending haxe.Exception, so the
// stack captured by the base constructor drops one frame per constructor level and starts at the
// construction site.
class ExceptionFilters {
	// The constructor patch as a type filter, for the macro world's `ready`: nothing to patch unless
	// haxe.Exception has a __shiftStack.
	public static function patcher(tctx:TyperContext):ModuleType->Void {
		var ctx = tctx.com;
		var excCls:Null<TClass> = null;
		for (m in ctx.modules) for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (c.path.name == "Exception" && c.path.pack.length == 1 && c.path.pack[0] == "haxe"):
				excCls = c;
			case _:
		}
		var shiftCf = excCls == null ? null : excCls.fields.get("__shiftStack");
		if (shiftCf == null) return function(_) {};
		return function(mt:ModuleType) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern) && c != excCls && TypeFunctions.extendsClass(c, excCls)):
				patchConstructor(tctx, c, excCls, shiftCf);
			case _:
		}
	}

	public static function run(ctx:Context):Void {
		var excCls:Null<TClass> = null;
		for (m in ctx.modules) for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (c.path.name == "Exception" && c.path.pack.length == 1 && c.path.pack[0] == "haxe"):
				excCls = c;
			case _:
		}
		if (excCls == null) return;
		var shiftCf = excCls.fields.get("__shiftStack");
		if (shiftCf == null) return;
		var tctx = new TyperContext(ctx);
		for (m in ctx.modules) for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern) && c != excCls && TypeFunctions.extendsClass(c, excCls)):
				patchConstructor(tctx, c, excCls, shiftCf);
			case _:
		}
	}

	static function patchConstructor(tctx:TyperContext, c:TClass, excCls:TClass, shiftCf:TClassField):Void {
		var ctx = tctx.com;
		// A subclass with no constructor of its own gets its forwarding constructor synthesized here,
		// before
		// patching, so it too shifts the stack.
		Typer.ensureInheritedCtor(tctx, c);
		var ctor = c.constructor;
		if (ctor == null) return;
		if (ctor.expr == null) TypeFields.forceFieldBody(ctx, c, ctor);
		switch (ctor.expr) {
			case null:
			case fe: switch (fe.expr) {
				case TFunction(fn):
					var tvoid = ctx.basic.tvoid;
					function shiftStack(p:Position):TExpr {
						var ethis = TypeFunctions.mk(TConst(TThis), TInst(c, TypeFunctions.extractParamTypes(c.params)), p);
						var efield = TypeFunctions.mk(TField(ethis, FInstance(excCls, [], shiftCf)), shiftCf.type, p);
						var rt = switch (TypeFunctions.follow(shiftCf.type)) { case TFun(sig): sig.ret; case _: tvoid; };
						// makeCall inlines __shiftStack in place, so the void body keeps its block.
						return hxc.typing.Calls.makeCall(tctx, efield, [], rt, p);
					}
					// A shift runs before every return (the map reaches them all) and once at the end; a
					// nested
					// function keeps its own returns untouched.
					function add(e:TExpr):TExpr {
						return switch (e.expr) {
							case TFunction(_): e;
							case TReturn(_): TypeFunctions.mk(TBlock([shiftStack(e.pos), e]), e.type, e.pos);
							case _: hxc.core.TexprTools.mapExpr(add, e);
						};
					}
					var body = TypeFunctions.mk(TBlock([add(fn.expr), shiftStack(fn.expr.pos)]), tvoid, fn.expr.pos);
					ctor.expr = TypeFunctions.mk(TFunction(new TFunc(fn.args, fn.type, body)), fe.type, fe.pos);
				case _:
			}
		}
	}
}
