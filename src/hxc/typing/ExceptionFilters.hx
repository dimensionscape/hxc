package hxc.typing;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;

// Adds `this.__shiftStack()` to every constructor of a class extending haxe.Exception, so the
// stack captured by the base constructor drops one frame per constructor level and starts at the
// construction site.
class ExceptionFilters {
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
		for (m in ctx.modules) for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern) && c != excCls && TypeFunctions.extendsClass(c, excCls)):
				patchConstructor(ctx, c, excCls, shiftCf);
			case _:
		}
	}

	static function patchConstructor(ctx:Context, c:TClass, excCls:TClass, shiftCf:TClassField):Void {
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
						return TypeFunctions.mk(TCall(efield, []), tvoid, p);
					}
					// A shift runs before every return and once at the end; a nested function keeps
					// its own returns untouched.
					function add(e:TExpr):TExpr {
						return switch (e.expr) {
							case TFunction(_): e;
							case TReturn(_): TypeFunctions.mk(TBlock([shiftStack(e.pos), e]), e.type, e.pos);
							case TBlock(el): TypeFunctions.mk(TBlock([for (x in el) add(x)]), e.type, e.pos);
							case TIf(cond, a, b): TypeFunctions.mk(TIf(cond, add(a), b == null ? null : add(b)), e.type, e.pos);
							case TSwitch(s, cases, def): TypeFunctions.mk(TSwitch(s, [for (cc in cases) {values: cc.values, expr: add(cc.expr)}], def == null ? null : add(def)), e.type, e.pos);
							case TTry(e1, catches): TypeFunctions.mk(TTry(add(e1), [for (cc in catches) {v: cc.v, expr: add(cc.expr)}]), e.type, e.pos);
							case TWhile(cond, body, flag): TypeFunctions.mk(TWhile(cond, add(body), flag), e.type, e.pos);
							case TFor(v, e1, body): TypeFunctions.mk(TFor(v, e1, add(body)), e.type, e.pos);
							case TMeta(mm, e1): TypeFunctions.mk(TMeta(mm, add(e1)), e.type, e.pos);
							case TParenthesis(e1): TypeFunctions.mk(TParenthesis(add(e1)), e.type, e.pos);
							case _: e;
						};
					}
					var body = TypeFunctions.mk(TBlock([add(fn.expr), shiftStack(fn.expr.pos)]), tvoid, fn.expr.pos);
					ctor.expr = TypeFunctions.mk(TFunction(new TFunc(fn.args, fn.type, body)), fe.type, fe.pos);
				case _:
			}
		}
	}
}
