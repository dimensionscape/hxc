package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;
import hxc.typing.Matcher.Match;

class Calls {
	public static function makeCall(ctx:TyperContext, e:TExpr, params:Array<TExpr>, t:T, p:Position):TExpr {
		// A call to an inline function expands in place; on any unhandled construct it falls back here.
		var inlined = Inline.tryInline(ctx, e, params, t, p);
		if (inlined != null) return inlined;
		return TypeFunctions.mk(TCall(e, params), t, p);
	}

	public static function arrayAccess(ctx:TyperContext, e1:TExpr, e2:TExpr, mode:AccessMode, p:Position):AccessKind {
		// Abstract @:arrayAccess. A write defers to the assignment/compound handlers (which call the
		// (this, key, value) setter); a read dispatches here to the (this, key) getter.
		switch (TypeFunctions.follow(e1.type)) {
			case TAbstract(a, tl) if (a.impl != null && a.array.length > 0 && mode.match(MSet(_))):
				return AKAccess(a, tl, a.impl, e1, e2);
			case TAbstract(a, tl) if (a.impl != null && a.array.length > 0):
				for (cf in a.array) {
					switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, cf.type))) {
						case TFun(sig) if (sig.args.length == 2):
							var implExpr = TexprTools.makeStaticThis(a.impl, p);
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

	// Abstract @:arrayAccess write: call the impl setter taking (this, key, value). .
	public static function arraySet(ctx:TyperContext, a:TAbstract, tl:TParams, c:TClass, ebase:TExpr, ekey:TExpr, valueExpr:Expr, p:Position):TExpr {
		return arraySetValue(ctx, a, tl, c, ebase, ekey, function(vt:T) return Typer.typeExpr(ctx, valueExpr, WithTypeTools.withType(vt)), p);
	}

	// Setter call with an already-computed value; valueFn receives the setter's value-parameter type so a
	// plain write can infer its literal, while a compound write supplies the precomputed op result.
	public static function arraySetValue(ctx:TyperContext, a:TAbstract, tl:TParams, c:TClass, ebase:TExpr, ekey:TExpr, valueFn:T->TExpr, p:Position):TExpr {
		for (cf in a.array) {
			switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, cf.type))) {
				case TFun(sig) if (sig.args.length == 3):
					var implExpr = TexprTools.makeStaticThis(c, p);
					var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(c), false, p), FCall);
					var key = Typer.castOrUnify(ctx, sig.args[1].t, ekey, ekey.pos);
					var val = Typer.castOrUnify(ctx, sig.args[2].t, valueFn(sig.args[2].t), p);
					return makeCall(ctx, fieldExpr, [ebase, key, val], sig.ret, p);
				case _:
			}
		}
		throw new TypingError("No matching @:arrayAccess setter", p);
	}

	// The element type of a haxe.Rest<T>, or null if `t` is not a rest type.
	static function restElemType(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, params) if (params.length == 1 && a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Rest"): params[0];
			case _: null;
		};
	}

	public static function unifyCallArgs(ctx:TyperContext, el:Array<Expr>, args:Array<TSignatureArg>, r:T, callp:Position):{el:Array<TExpr>, tfunc:T} {
		function typeAgainst(name:String, t:T, e:Expr):TExpr {
			var te = Typer.typeExpr(ctx, e, WithTypeTools.withArgument(t, name));
			return Typer.castOrUnify(ctx, t, te, te.pos);
		}
		var out:Array<TExpr> = [];
		var ei = 0, ai = 0;
		while (ei < el.length || ai < args.length) {
			// A trailing haxe.Rest<T> parameter absorbs every remaining argument. On targets without native
			// rest support (eval, cpp) they are wrapped in an array and coerced through Rest's @:from
			// Array;
			// a single spread `...e` passes its source array directly.
			if (args.length - ai == 1 && !args[ai].opt) {
				var argT = restElemType(args[ai].t);
				if (argT != null) {
					var name = args[ai].name;
					var rt = args[ai].t;
					var remaining = el.slice(ei);
					var spreadInner:Null<Expr> = (remaining.length == 1) ? (switch (remaining[0].expr) { case EUnop(Spread, Prefix, e): e; case _: null; }) : null;
					var restExpr:TExpr;
					if (spreadInner != null) {
						restExpr = typeAgainst(name, rt, spreadInner);
					} else if (remaining.length == 0) {
						restExpr = typeAgainst(name, rt, new Expr(EArrayDecl([]), callp));
					} else {
						var arr = new Expr(EArrayDecl(remaining), callp);
						var toType = switch (TypeFunctions.follow(argT)) {
							case TDynamic(_):
								var dynHint:TypeHint = {ct: CTPath({tpackage: [], tname: "Dynamic", tparams: [], tsub: null}), pos: callp};
								var arrHint:TypeHint = {ct: CTPath({tpackage: [], tname: "Array", tparams: [TPType(dynHint)], tsub: null}), pos: callp};
								new Expr(ECheckType(arr, arrHint), callp);
							case _: arr;
						};
						restExpr = typeAgainst(name, rt, toType);
					}
					out.push(restExpr);
					ei = el.length;
					ai = args.length;
					continue;
				}
			}
			if (ei >= el.length) {
				var a = args[ai];
				if (!a.opt) throw new TypingError("Not enough arguments", callp);
				out.push(TexprTools.makeNull(ctx.com.basic.tnull(a.t), callp));
				ai++;
			} else if (ai >= args.length) {
				throw new TypingError("Too many arguments", el[ei].pos);
			} else {
				var a = args[ai];
				// Optional-argument skipping: if the value does not fit this optional parameter but more
				// parameters than values remain, skip (default) the parameter and retry the value against
				// the next one. This binds e.g. equals(v, v2, pos) past `?msg` onto `?pos`.
				var mightSkip = (el.length - ei - 1) < (args.length - ai - 1);
				var te:Null<TExpr> = null;
				var skip = false;
				try te = typeAgainst(a.name, a.t, el[ei]) catch (err:TypingError) {
					if (a.opt && mightSkip) skip = true;
					else throw err;
				}
				if (skip) {
					out.push(TexprTools.makeNull(ctx.com.basic.tnull(a.t), callp));
					ai++;
				} else {
					out.push(te);
					ei++;
					ai++;
				}
			}
		}
		return {el: out, tfunc: TFun({args: args, ret: r})};
	}

	// `f.bind(params)` builds `{ var f = <fn>; var g = given...; return function(missing) return f(all); }`.
	// A param that is `_`, or an argument past the supplied params, stays a parameter of the bound function.
	static function typeBind(ctx:TyperContext, fe:TExpr, sig:TSignature, params:Array<Expr>, p:Position):TExpr {
		var tvoid = ctx.com.basic.tvoid;
		var decls:Array<TExpr> = [];
		var fv = TypeFunctions.allocVar(VGenerated, "`f", fe.type, p);
		decls.push(TypeFunctions.mk(TVarExpr(fv, fe), tvoid, p));
		var feLocal = TexprTools.makeLocal(fv, p);
		var callArgs:Array<TExpr> = [];
		var missingVl:Array<TVar> = [];
		var missingArgs:Array<TSignatureArg> = [];
		var pi = 0;
		for (arg in sig.args) {
			var isUnderscore = pi < params.length && (switch (params[pi].expr) { case EConst(CIdent("_")): true; case _: false; });
			if (pi >= params.length || isUnderscore) {
				var v = TypeFunctions.allocVar(VGenerated, arg.name, arg.t, p);
				missingVl.push(v);
				missingArgs.push({name: arg.name, opt: arg.opt, t: arg.t});
				callArgs.push(TexprTools.makeLocal(v, p));
				if (isUnderscore) pi++;
			} else {
				var te = Typer.castOrUnify(ctx, arg.t, Typer.typeExpr(ctx, params[pi], WithTypeTools.withArgument(arg.t, arg.name)), params[pi].pos);
				var v = TypeFunctions.allocVar(VGenerated, arg.name, arg.t, p);
				decls.push(TypeFunctions.mk(TVarExpr(v, te), tvoid, p));
				callArgs.push(TexprTools.makeLocal(v, p));
				pi++;
			}
		}
		if (pi < params.length) throw new TypingError("Too many callback arguments", p);
		var call = makeCall(ctx, feLocal, callArgs, sig.ret, p);
		var body = TypeFunctions.mk(TReturn(call), sig.ret, p);
		var tf = new TFunc([for (v in missingVl) {v: v}], sig.ret, body);
		var ft = TFun({args: missingArgs, ret: sig.ret});
		decls.push(TypeFunctions.mk(TFunction(tf), ft, p));
		return TypeFunctions.mk(TBlock(decls), ft, p);
	}

	// A call target goes through buildCall (core: plain function value and method call).
	public static function typeCall(ctx:TyperContext, callee:Expr, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		switch (callee.expr) {
			case EConst(CIdent("trace")) if (!ctx.locals.exists("trace")):
				return typeTrace(ctx, el, withType, p);
			case EConst(CIdent("super")):
				return typeSuperCall(ctx, el, p);
			case EField(e1, "match", _) if (el.length == 1):
				// `e.match(pattern)` on an enum is sugar for `switch e { case pattern: true; case _: false;
				// }`.
				// Only intercept for enum-ish receivers; an abstract that defines its own `match` impl
				// keeps the
				// normal call.
				var et = Typer.typeExpr(ctx, e1, WithTypeTools.value);
				if (hasEnumMatch(et.type)) {
					var cases:Array<SwitchCase> = [{values: [el[0]], guard: null, expr: new Expr(EConst(CIdent("true")), p), pos: p}];
					var def = {e: new Expr(EConst(CIdent("false")), p), pos: p};
					return Match.matchExpr(ctx, e1, cases, def, WithTypeTools.withType(ctx.com.basic.tbool), true, p);
				}
			case EField(e1, "bind", _):
				// `f.bind(args)` partial application: when f is a function, bind the given args and return
				// a
				// closure over the missing ones (`_` or omitted).
				var fe = try Typer.typeExpr(ctx, e1, WithTypeTools.value) catch (_:TypingError) null;
				if (fe != null) switch (TypeFunctions.follow(fe.type)) {
					case TFun(sig): return typeBind(ctx, fe, sig, el, p);
					case _:
				}
			case _:
		}
		var acc = Typer.typeAccess(ctx, callee.expr, callee.pos, MCall(el), withType);
		return buildCall(ctx, acc, el, withType, p);
	}

	// True when `.match()` applies: the receiver is an enum, or a @:forward abstract over one that
	// does not define its own `match`.
	static function hasEnumMatch(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TEnum(_, _): true;
			case TAbstract(a, tl) if (TypeFunctions.hasMeta(":forward", a.meta) && !TypeFunctions.hasMeta(":coreType", a.meta)):
				if (a.impl != null && a.impl.statics.exists("match") && TypeFunctions.hasClassFieldFlag(a.impl.statics.get("match"), CfImpl)) false
				else hasEnumMatch(TypeFunctions.applyParams(a.params, tl, a.thisType));
			case _: false;
		};
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
			case AKAccessor(_):
				// Calling a property whose value is itself callable: read it through the getter, then call
				// the
				// resulting value.
				callExpr(ctx, Typer.accGet(ctx, acc), el, p);
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
