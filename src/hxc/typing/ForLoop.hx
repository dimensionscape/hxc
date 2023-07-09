package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Texpr;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;

class ForLoop {
	// Resolve a method access `e.name` for a 0-argument call, returning the callee texpr.
	static function methodCallee(ctx:TyperContext, e:TExpr, name:String, p:Position):TExpr {
		var acc = Fields.typeField(ctx, e, name, p, MCall([]), WithTypeTools.value);
		return switch (acc) {
			case AKField(fa): FieldAccessTools.getFieldExpr(fa, FCall);
			case AKExpr(ce): ce;
			case _: throw new TypingError("Cannot call " + name, p);
		};
	}

	static function call0(ctx:TyperContext, e:TExpr, name:String, p:Position):TExpr {
		var ce = methodCallee(ctx, e, name, p);
		var ret = switch (TypeFunctions.follow(ce.type)) {
			case TFun(sig): sig.ret;
			case _: TypeFunctions.mkMono();
		};
		return Calls.makeCall(ctx, ce, [], ret, p);
	}

	public static function typeForLoop(ctx:TyperContext, it:Expr, e2:Expr, p:Position):TExpr {
		var vName:String;
		var e1Expr:Expr;
		switch (it.expr) {
			case EBinop(OpIn, lhs, rhs):
				vName = switch (lhs.expr) {
					case EConst(CIdent(i)): i;
					case _: throw new TypingError("Identifier expected", lhs.pos);
				};
				e1Expr = rhs;
			case _:
				throw new TypingError("For expression should be 'v in expr'", it.pos);
		}
		var basic = ctx.com.basic;
		var e1 = Typer.typeExpr(ctx, e1Expr, WithTypeTools.value);
		// The iterator is e1.iterator when e1 is iterable, otherwise e1 itself.
		var iterExpr = try call0(ctx, e1, "iterator", p) catch (_:TypingError) e1;
		var pt = switch (TypeFunctions.follow(methodCallee(ctx, iterExpr, "next", p).type)) {
			case TFun(sig): sig.ret;
			case _: TypeFunctions.mkMono();
		};
		var oldLoop = ctx.inLoop;
		var oldLocals = Typer.saveLocals(ctx);
		ctx.inLoop = true;
		var vIt = Typer.addLocal(ctx, VGenerated, "_hx_it", iterExpr.type, p);
		var eIt = Texpr.makeLocal(vIt, p);
		var v = Typer.addLocalWithOrigin(ctx, TVOForVariable, vName, pt, p);
		var body = Typer.typeExpr(ctx, Expr.ensureBlock(e2), WithTypeTools.noValue);
		ctx.inLoop = oldLoop;
		oldLocals();
		var ehasnext = call0(ctx, eIt, "hasNext", p);
		var enext = call0(ctx, eIt, "next", p);
		var whileBody = TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(v, enext), basic.tvoid, p),
			body
		]), basic.tvoid, p);
		var ewhile = TypeFunctions.mk(TWhile(ehasnext, whileBody, NormalWhile), basic.tvoid, p);
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(vIt, iterExpr), basic.tvoid, p),
			ewhile
		]), basic.tvoid, p);
	}
}
