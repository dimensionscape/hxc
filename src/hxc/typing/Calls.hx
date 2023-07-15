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
		// Abstract @:arrayAccess read: dispatch to the impl getter taking (this, key).
		switch (TypeFunctions.follow(e1.type)) {
			case TAbstract(a, tl) if (a.impl != null && a.array.length > 0 && !mode.match(MSet(_))):
				for (cf in a.array) {
					switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, cf.type))) {
						case TFun(sig) if (sig.args.length == 2):
							var implExpr = Texpr.makeStaticThis(a.impl, p);
							var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(a.impl), false, p), FCall);
							var key = Typer.castOrUnify(ctx, sig.args[1].t, e2, e2.pos);
							return AKExpr(makeCall(ctx, fieldExpr, [e1, key], sig.ret, p));
						case _:
					}
				}
			case _:
		}
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
		switch (callee.expr) {
			case EConst(CIdent("trace")) if (!ctx.locals.exists("trace")):
				return typeTrace(ctx, el, withType, p);
			case EConst(CIdent("super")):
				return typeSuperCall(ctx, el, p);
			case _:
		}
		var acc = Typer.typeAccess(ctx, callee.expr, callee.pos, MCall(el), withType);
		return buildCall(ctx, acc, el, withType, p);
	}

	static function typeSuperCall(ctx:TyperContext, el:Array<Expr>, p:Position):TExpr {
		var sup = ctx.curclass.superClass;
		if (sup == null) throw new TypingError("Class does not have a super class", p);
		var c = sup.c;
		var sig = if (c.constructor == null) {args: [], ret: ctx.com.basic.tvoid} else switch (TypeFunctions.follow(TypeFunctions.applyParams(c.params, sup.params, c.constructor.type))) {
			case TFun(s): s;
			case _: {args: [], ret: ctx.com.basic.tvoid};
		};
		var r = unifyCallArgs(ctx, el, sig.args, sig.ret, p);
		var superExpr = TypeFunctions.mk(TConst(TSuper), TInst(c, sup.params), p);
		return TypeFunctions.mk(TCall(superExpr, r.el), ctx.com.basic.tvoid, p);
	}

	// `trace(v, ...)` lowers to haxe.Log.trace(v, posInfos) with the call's position info.
	static function typeTrace(ctx:TyperContext, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		function strE(s:String):Expr return new Expr(EConst(CString(s, SDoubleQuotes)), p);
		function fld(name:String, e:Expr):ObjectField return {name: name, expr: e, quotes: NoQuotes, pos: p};
		var v = el.length > 0 ? el[0] : strE("");
		var customParams = el.length > 1 ? new Expr(EArrayDecl(el.slice(1)), p) : new Expr(EConst(CIdent("null")), p);
		var infos = new Expr(EObjectDecl([
			fld("fileName", strE(p.file)),
			fld("lineNumber", new Expr(EConst(CInt("0", null)), p)),
			fld("className", strE(ctx.curclass.path.name)),
			fld("methodName", strE(ctx.curfield == null ? "" : ctx.curfield.name)),
			fld("customParams", customParams)
		]), p);
		var haxePkg = new Expr(EConst(CIdent("haxe")), p);
		var logTrace = new Expr(EField(new Expr(EField(haxePkg, "Log", EFNormal), p), "trace", EFNormal), p);
		return Typer.typeExpr(ctx, new Expr(ECall(logTrace, [v, infos]), p), withType);
	}

	public static function buildCall(ctx:TyperContext, acc:AccessKind, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		return switch (acc) {
			case AKExpr(ce): callExpr(ctx, ce, el, p);
			case AKField(fa) if (hxc.eval.EvalMacro.isMacroField(fa.field)):
				hxc.eval.EvalMacro.run(ctx, fa, el, withType, p);
			case AKField(fa): callExpr(ctx, monomorphizeParams(ctx, fa.field, FieldAccessTools.getFieldExpr(fa, FCall)), el, p);
			case AKUsingField(se):
				// Static-extension / abstract impl call: the receiver is the first argument.
				var ce = monomorphizeParams(ctx, se.access.field, FieldAccessTools.getFieldExpr(se.access, FCall));
				switch (TypeFunctions.follow(ce.type)) {
					case TFun(sig) if (sig.args.length > 0):
						var r = unifyCallArgs(ctx, el, sig.args.slice(1), sig.ret, p);
						makeCall(ctx, ce, [se.thisExpr].concat(r.el), sig.ret, p);
					case _: throw new TypingError("Static-extension target is not a function", p);
				}
			case AKNo(_, pp): throw new TypingError("This expression cannot be called", pp);
			case _: throw new TypingError("This call form is not yet ported (overloads / abstract ops / using)", p);
		};
	}

	// A generic method's own type parameters become fresh monomorphs for the call.
	static function monomorphizeParams(ctx:TyperContext, cf:TClassField, ce:TExpr):TExpr {
		if (cf.params.length == 0) return ce;
		var monos:TParams = [for (_ in cf.params) Typer.spawnMonomorph(ctx, ce.pos)];
		return TypeFunctions.mk(ce.expr, TypeFunctions.applyParams(cf.params, monos, ce.type), ce.pos);
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
