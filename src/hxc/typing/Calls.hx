package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.Texpr;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;

class Calls {
	public static function makeCall(ctx:TyperContext, e:TExpr, params:Array<TExpr>, t:T, p:Position):TExpr {
		return TypeFunctions.mk(TCall(e, params), t, p);
	}

	public static function arrayAccess(ctx:TyperContext, e1:TExpr, e2:TExpr, mode:AccessMode, p:Position):AccessKind {
		var pt = Typer.spawnMonomorph(ctx, p);
		var t = ctx.com.basic.tarray(pt);
		try {
			TypeUnification.unifyDefault(e1.type, t);
		} catch (_:UnifyError) {
			throw new TypingError("Array access is not allowed on this type", e1.pos);
		}
		try {
			TypeUnification.unifyDefault(e2.type, ctx.com.basic.tint);
		} catch (_:UnifyError) {
			throw new TypingError("Array index must be of type Int", e2.pos);
		}
		return AKExpr(TypeFunctions.mk(TArray(e1, e2), pt, p));
	}

	public static function unifyCallArgs(ctx:TyperContext, el:Array<Expr>, args:Array<TSignatureArg>, r:T, callp:Position):{el:Array<TExpr>, tfunc:T} {
		function typeAgainst(name:String, t:T, e:Expr):TExpr {
			var te = Typer.typeExpr(ctx, e, WithTypeTools.withArgument(t, name));
			return Typer.castOrUnify(ctx, t, te, te.pos);
		}
		var out:Array<TExpr> = [];
		var ei = 0, ai = 0;
		while (ei < el.length || ai < args.length) {
			if (ei >= el.length) {
				var a = args[ai];
				if (!a.opt) throw new TypingError("Not enough arguments", callp);
				out.push(Texpr.makeNull(ctx.com.basic.tnull(a.t), callp));
				ai++;
			} else if (ai >= args.length) {
				throw new TypingError("Too many arguments", el[ei].pos);
			} else {
				var a = args[ai];
				out.push(typeAgainst(a.name, a.t, el[ei]));
				ei++;
				ai++;
			}
		}
		return {el: out, tfunc: TFun({args: args, ret: r})};
	}

	// A call target goes through buildCall (core: plain function value and method call).
	public static function typeCall(ctx:TyperContext, callee:Expr, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		var acc = Typer.typeAccess(ctx, callee.expr, callee.pos, MCall(el), withType);
		return buildCall(ctx, acc, el, withType, p);
	}

	static function buildCall(ctx:TyperContext, acc:AccessKind, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		return switch (acc) {
			case AKExpr(ce): callExpr(ctx, ce, el, p);
			case AKField(fa): callExpr(ctx, FieldAccessTools.getFieldExpr(fa, FCall), el, p);
			case AKNo(_, pp): throw new TypingError("This expression cannot be called", pp);
			case _: throw new TypingError("This call form is not yet ported (overloads / abstract ops / using)", p);
		};
	}

	static function callExpr(ctx:TyperContext, ce:TExpr, el:Array<Expr>, p:Position):TExpr {
		return switch (TypeFunctions.follow(ce.type)) {
			case TFun(sig):
				var r = unifyCallArgs(ctx, el, sig.args, sig.ret, p);
				makeCall(ctx, ce, r.el, sig.ret, p);
			case TMono(_):
				var args = [for (e in el) Typer.typeExpr(ctx, e, WithTypeTools.value)];
				makeCall(ctx, ce, args, TypeFunctions.mkMono(), p);
			case TDynamic(_):
				var args = [for (e in el) Typer.typeExpr(ctx, e, WithTypeTools.value)];
				makeCall(ctx, ce, args, TDynamic(null), p);
			case _:
				throw new TypingError("Cannot call a non-function value", p);
		};
	}
}
