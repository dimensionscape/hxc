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
import hxc.debug.DebugDump;
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

	// The element type of a class implementing ArrayAccess<T>, walking the superclass chain and applying
	// type parameters at each step; null when no ancestor declares array access.
	static function arrayAccessElem(c:TClass, tl:TParams):Null<T> {
		var cur = c;
		var curtl = tl;
		var guard = 0;
		while (cur != null && guard++ < 50) {
			if (cur.arrayAccess != null) return TypeFunctions.applyParams(cur.params, curtl, cur.arrayAccess);
			if (cur.superClass == null) break;
			var sup = cur.superClass;
			curtl = [for (t in sup.params) TypeFunctions.applyParams(cur.params, curtl, t)];
			cur = sup.c;
		}
		return null;
	}

	// If a class implements haxe.Constraints.IMap<K,V> (haxe.ds.IntMap/StringMap/ObjectMap/...), return
	// its key/value types. Such a map supports `m[k]` as m.get(k) / m.set(k, v); the @:arrayAccess proper
	// lives on the Map abstract, but hxc types map literals as the concrete impl.
	public static function imapKV(c:TClass, tl:TParams):Null<{k:T, v:T}> {
		var cur = c;
		var curtl = tl;
		var guard = 0;
		while (cur != null && guard++ < 50) {
			for (impl in cur.interfaces) {
				var ic = impl.c;
				if (ic.path.name == "IMap") {
					var ps = [for (t in impl.params) TypeFunctions.applyParams(cur.params, curtl, t)];
					if (ps.length >= 2) return {k: ps[0], v: ps[1]};
				}
			}
			if (cur.superClass == null) break;
			var sup = cur.superClass;
			curtl = [for (t in sup.params) TypeFunctions.applyParams(cur.params, curtl, t)];
			cur = sup.c;
		}
		return null;
	}

	public static function arrayAccess(ctx:TyperContext, e1:TExpr, e2:TExpr, mode:AccessMode, p:Position):AccessKind {
		// Abstract @:arrayAccess. A write defers to the assignment/compound handlers (which call the
		// (this, key, value) setter); a read dispatches here to the (this, key) getter.
		switch (TypeFunctions.follow(e1.type)) {
			case TAbstract(a, tl) if (a.impl != null && a.array.length > 0 && mode.match(MSet(_))):
				return AKAccess(a, tl, a.impl, e1, e2);
			case TAbstract(a, tl) if (a.impl != null && a.array.length > 0):
				for (cf in a.array) {
					if (cf.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx.com, a.impl, cf);
					switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, cf.type))) {
						case TFun(sig) if (sig.args.length == 2):
							var key = Typer.castOrUnify(ctx, sig.args[1].t, e2, e2.pos);
							if (cf.expr == null && !TypeFunctions.hasClassFieldFlag(cf, CfExtern))
								return AKExpr(TypeFunctions.mk(TArray(e1, key), sig.ret, p));
							var implExpr = TexprTools.makeStaticThis(a.impl, p);
							var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(a.impl), false, p), FCall);
							return AKExpr(makeCall(ctx, fieldExpr, [e1, key], sig.ret, p));
						case _:
					}
				}
			case _:
		}
		// A class-level @:arrayAccess abstract (no @:arrayAccess methods) forwards array access to its
		// underlying type; follow the chain so the access resolves against the underlying.
		var effType = e1.type;
		var guard = 0;
		while (guard++ < 20) {
			switch (TypeFunctions.follow(effType)) {
				case TAbstract(a, tl) if (TypeFunctions.hasMeta(":arrayAccess", a.meta)):
					effType = TypeFunctions.applyParams(a.params, tl, a.thisType);
				case _: break;
			}
		}
		// A class implementing ArrayAccess<T> (String, eval.Vector, ...) allows native `e[i]` with element
		// type T and an Int index; the read/write both compile to a TArray the evaluator handles directly.
		switch (TypeFunctions.follow(effType)) {
			case TInst(c, tl):
				var elem = arrayAccessElem(c, tl);
				if (elem != null) {
					try TypeUnification.unifyDefault(e2.type, ctx.com.basic.tint)
					catch (_:UnifyError) throw new TypingError("Array index must be of type Int", e2.pos);
					return AKExpr(TypeFunctions.mk(TArray(e1, e2), elem, p));
				}
				var kv = imapKV(c, tl);
				if (kv != null && !mode.match(MSet(_))) {
					// Read `m[k]` as m.get(k) (writes/increments are lowered by typeAssign/typeUnop).
					var key = Typer.castOrUnify(ctx, kv.k, e2, e2.pos);
					var getExpr = Typer.accGet(ctx, Fields.typeField(ctx, e1, "get", p, MGet, WithTypeTools.value));
					return AKExpr(makeCall(ctx, getExpr, [key], ctx.com.basic.tnull(kv.v), p));
				}
			case _:
		}
		var pt = Typer.spawnMonomorph(ctx, p);
		var t = ctx.com.basic.tarray(pt);
		try {
			TypeUnification.unifyDefault(effType, t);
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
			if (cf.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx.com, c, cf);
			switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, cf.type))) {
				case TFun(sig) if (sig.args.length == 3):
					var key = Typer.castOrUnify(ctx, sig.args[1].t, ekey, ekey.pos);
					var val = Typer.castOrUnify(ctx, sig.args[2].t, valueFn(sig.args[2].t), p);
					if (cf.expr == null && !TypeFunctions.hasClassFieldFlag(cf, CfExtern)) {
						var ea = TypeFunctions.mk(TArray(ebase, key), sig.ret, p);
						return TypeFunctions.mk(TBinop(OpAssign, ea, val), sig.ret, p);
					}
					var implExpr = TexprTools.makeStaticThis(c, p);
					var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(c), false, p), FCall);
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
			DebugDump.unify("call-arg " + name, te.type, t, te.pos);
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
				var pi = makePosInfosArg(ctx, a.t, callp);
				out.push(pi != null ? pi : TexprTools.makeNull(ctx.com.basic.tnull(a.t), callp));
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
					var pi = makePosInfosArg(ctx, a.t, callp);
					out.push(pi != null ? pi : TexprTools.makeNull(ctx.com.basic.tnull(a.t), callp));
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
		return Typer.accGet(ctx, typeCallAccess(ctx, callee, el, withType, p));
	}

	public static function typeCallAccess(ctx:TyperContext, callee:Expr, el:Array<Expr>, withType:WithType, p:Position):AccessKind {
		switch (callee.expr) {
			case EConst(CIdent("trace")) if (!ctx.locals.exists("trace")):
				return AKExpr(typeTrace(ctx, el, withType, p));
			case EConst(CIdent("super")):
				return AKExpr(typeSuperCall(ctx, el, p));
			case EField({expr: EConst(CIdent("Std"))}, "string", _) if (el.length == 1):
				var e = Typer.typeExpr(ctx, el[0], WithTypeTools.value);
				var converted = abstractToString(ctx, e, p);
				if (converted != null) return AKExpr(converted);
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
					return AKExpr(Match.matchExpr(ctx, e1, cases, def, WithTypeTools.withType(ctx.com.basic.tbool), true, p));
				}
			case EField(e1, "bind", _):
				// `f.bind(args)` partial application: when f is a function, bind the given args and return
				// a
				// closure over the missing ones (`_` or omitted).
				var fe = try Typer.typeExpr(ctx, e1, WithTypeTools.value) catch (_:TypingError) null;
				if (fe != null) switch (TypeFunctions.follow(fe.type)) {
					case TFun(sig): return AKExpr(typeBind(ctx, fe, sig, el, p));
					case _:
				}
			case _:
		}
		var acc = Typer.typeAccess(ctx, callee.expr, callee.pos, MCall(el), withType);
		return buildCallAccess(ctx, acc, el, withType, p);
	}

	static function abstractToString(ctx:TyperContext, e:TExpr, p:Position):Null<TExpr> {
		switch (TypeFunctions.follow(e.type)) {
			case TAbstract(a, _) if (a.impl != null && a.impl.statics.exists("toString")):
				function call(x:TExpr):TExpr {
					return buildCall(ctx, Fields.typeField(ctx, x, "toString", x.pos, MCall([]), WithTypeTools.withType(ctx.com.basic.tstring)), [], WithTypeTools.withType(ctx.com.basic.tstring), x.pos);
				}
				var strNull = TypeFunctions.mk(TConst(TString("null")), ctx.com.basic.tstring, p);
				var simple = switch (e.expr) { case TLocal(_) | TConst(_): true; case _: false; };
				if (simple) {
					var check = TypeFunctions.mk(TBinop(OpEq, e, TexprTools.makeNull(e.type, e.pos)), ctx.com.basic.tbool, p);
					return TypeFunctions.mk(TIf(check, strNull, call(e)), ctx.com.basic.tstring, p);
				}
				var tmp = TypeFunctions.allocVar(VGenerated, "`tmp", e.type, p);
				var tmpLocal = TexprTools.makeLocal(tmp, p);
				var decl = TypeFunctions.mk(TVarExpr(tmp, e), ctx.com.basic.tvoid, p);
				var check = TypeFunctions.mk(TBinop(OpEq, tmpLocal, TexprTools.makeNull(e.type, e.pos)), ctx.com.basic.tbool, p);
				var body = TypeFunctions.mk(TIf(check, strNull, call(tmpLocal)), ctx.com.basic.tstring, p);
				return TypeFunctions.mk(TBlock([decl, body]), ctx.com.basic.tstring, p);
			case _:
				return null;
		}
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

	// A final optional `?p:haxe.PosInfos` the caller omits is filled with the call-site position info.
	// (unify_call_params PosInfos).
	static function makePosInfosArg(ctx:TyperContext, t:T, callp:Position):Null<TExpr> {
		var isPI = switch (t) {
			case TType(d, _): d.path.name == "PosInfos" && d.path.pack.length == 1 && d.path.pack[0] == "haxe";
			case _: switch (TypeFunctions.follow(t)) {
				case TAnon(an): an.fields.exists("fileName") && an.fields.exists("lineNumber") && an.fields.exists("className") && an.fields.exists("methodName");
				case _: false;
			};
		};
		if (!isPI) return null;
		function strE(v:String):Expr return new Expr(EConst(CString(v, SDoubleQuotes)), callp);
		function fld(name:String, e:Expr):ObjectField return {name: name, expr: e, quotes: NoQuotes, pos: callp};
		var infos = new Expr(EObjectDecl([
			fld("fileName", strE(callp.file)),
			fld("lineNumber", new Expr(EConst(CInt(Std.string(Position.lineNumber(callp)), null)), callp)),
			fld("className", strE(ctx.curclass == null ? "" : ctx.curclass.path.name)),
			fld("methodName", strE(ctx.curfield == null ? "" : ctx.curfield.name))
		]), callp);
		return try Typer.typeExpr(ctx, infos, WithTypeTools.withType(t)) catch (_:Dynamic) null;
	}

	// `trace(v, ...)` lowers to haxe.Log.trace(v, posInfos) with the call's position info.
	static function typeTrace(ctx:TyperContext, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		function strE(s:String):Expr return new Expr(EConst(CString(s, SDoubleQuotes)), p);
		function fld(name:String, e:Expr):ObjectField return {name: name, expr: e, quotes: NoQuotes, pos: p};
		var v = el.length > 0 ? el[0] : strE("");
		var customParams = el.length > 1 ? new Expr(EArrayDecl(el.slice(1)), p) : new Expr(EConst(CIdent("null")), p);
		var infos = new Expr(EObjectDecl([
			fld("fileName", strE(p.file)),
			fld("lineNumber", new Expr(EConst(CInt(Std.string(Position.lineNumber(p)), null)), p)),
			fld("className", strE(ctx.curclass.path.name)),
			fld("methodName", strE(ctx.curfield == null ? "" : ctx.curfield.name)),
			fld("customParams", customParams)
		]), p);
		var haxePkg = new Expr(EConst(CIdent("haxe")), p);
		var logTrace = new Expr(EField(new Expr(EField(haxePkg, "Log", EFNormal), p), "trace", EFNormal), p);
		return Typer.typeExpr(ctx, new Expr(ECall(logTrace, [v, infos]), p), withType);
	}

	public static function buildCallAccess(ctx:TyperContext, acc:AccessKind, el:Array<Expr>, withType:WithType, p:Position):AccessKind {
		return switch (acc) {
			case AKSafeNav(sn):
				AKSafeNav({
					pos: sn.pos,
					base: sn.base,
					tempVar: sn.tempVar,
					access: buildCallAccess(ctx, sn.access, el, withType, p)
				});
			case _:
				AKExpr(buildCall(ctx, acc, el, withType, p));
		};
	}

	public static function buildCall(ctx:TyperContext, acc:AccessKind, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		return switch (acc) {
			case AKExpr(ce): callExpr(ctx, ce, el, p);
			case AKField(fa) if (hxc.eval.EvalMacro.isMacroField(fa.field)):
				hxc.eval.EvalMacro.run(ctx, fa, el, withType, p);
			case AKField(fa): callFieldAccess(ctx, fa, el, p);
			case AKUsingField(se) if (hxc.eval.EvalMacro.isMacroField(se.access.field)):
				hxc.eval.EvalMacro.run(ctx, se.access, [typedExprToSyntax(se.thisExpr)].concat(el), withType, p);
			case AKUsingField(se):
				// Static-extension / abstract impl call: the receiver is the first argument.
				var ce = monomorphizeParams(ctx, se.access.field, callFieldExpr(ctx, se.access));
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
			case AKSafeNav(sn):
				Typer.accGet(ctx, buildCallAccess(ctx, acc, el, withType, p));
			case _: throw new TypingError("This call form is not yet ported (overloads / abstract ops / using)", p);
		};
	}

	public static function typedExprToSyntax(e:TExpr):Expr {
		var p = e.pos;
		return switch (e.expr) {
			case TConst(TInt(i)):
				new Expr(EConst(CInt(Std.string(i), null)), p);
			case TConst(TFloat(s)):
				new Expr(EConst(CFloat(s, null)), p);
			case TConst(TString(s)):
				new Expr(EConst(CString(s, SDoubleQuotes)), p);
			case TConst(TBool(b)):
				new Expr(EConst(CIdent(b ? "true" : "false")), p);
			case TConst(TNull):
				new Expr(EConst(CIdent("null")), p);
			case TConst(TThis):
				new Expr(EConst(CIdent("this")), p);
			case TLocal(v):
				new Expr(EConst(CIdent(v.name)), p);
			case TParenthesis(e1):
				new Expr(EParenthesis(typedExprToSyntax(e1)), p);
			case TField(e1, fa):
				new Expr(EField(typedExprToSyntax(e1), TypeFunctions.fieldName(fa), EFNormal), p);
			case _:
				throw new TypingError("Cannot use this expression as a macro extension receiver", p);
		}
	}

	static function callFieldExpr(ctx:TyperContext, fa:FieldAccess):TExpr {
		var cf = fa.field;
		if (!ctx.com.isMacro && TypeFunctions.hasMono(TypeFields.fieldCallType(cf))) {
			switch (fa.host) {
				case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c):
					TypeFields.forceFieldBody(ctx.com, c, cf);
				case FHAnon:
			}
		}
		return FieldAccessTools.getFieldExpr(fa, FCall);
	}

	static function callFieldAccess(ctx:TyperContext, fa:FieldAccess, el:Array<Expr>, p:Position):TExpr {
		var candidates = [fa.field].concat(fa.field.overloads);
		var firstError:Null<Dynamic> = null;
		for (cf in candidates) {
			try {
				return TypeUnification.withMonoRollback(function() {
					var fa2 = FieldAccessTools.create(fa.on, cf, fa.host, fa.isInline, fa.pos);
					var ce = monomorphizeParams(ctx, cf, callFieldExpr(ctx, fa2));
					return switch (TypeFunctions.follow(ce.type)) {
						case TFun(sig):
							var r = unifyCallArgs(ctx, el, sig.args, sig.ret, p);
							if (DebugDump.enabled("select", p))
								DebugDump.selected("call", p, "field " + cf.name + " -> " + DebugDump.typeString(sig.ret));
							makeCall(ctx, ce, r.el, sig.ret, p);
						case _:
							callExpr(ctx, ce, el, p);
					}
				});
			} catch (e:UnifyError) {
				if (firstError == null) firstError = e;
			} catch (e:TypingError) {
				if (firstError == null) firstError = e;
			}
		}
		if (firstError != null) throw firstError;
		throw new TypingError("No matching overload", p);
	}

	// A generic method's own type parameters become fresh monomorphs for the call.
	static function monomorphizeParams(ctx:TyperContext, cf:TClassField, ce:TExpr):TExpr {
		if (cf.params.length == 0) return ce;
		var monos:TParams = TypeUnification.spawnConstrainedMonos(function(t) return t, cf.params);
		return TypeFunctions.mk(ce.expr, TypeFunctions.applyParams(cf.params, monos, ce.type), ce.pos);
	}

	// A generic local function stores its type params on its TVar (extra); a call gives each a fresh
	// monomorph so the arguments can bind them.
	static function monomorphizeLocalParams(ctx:TyperContext, ce:TExpr):TExpr {
		return switch (ce.expr) {
			case TLocal(v) if (v.extra != null && v.extra.params.length > 0):
				var monos:TParams = TypeUnification.spawnConstrainedMonos(function(t) return t, v.extra.params);
				TypeFunctions.mk(ce.expr, TypeFunctions.applyParams(v.extra.params, monos, ce.type), ce.pos);
			case _: ce;
		};
	}

	static function callExpr(ctx:TyperContext, ce0:TExpr, el:Array<Expr>, p:Position):TExpr {
		var ce = monomorphizeLocalParams(ctx, ce0);
		return switch (TypeFunctions.follow(ce.type)) {
			case TFun(sig):
				var r = unifyCallArgs(ctx, el, sig.args, sig.ret, p);
				if (DebugDump.enabled("select", p))
					DebugDump.selected("call", p, "function -> " + DebugDump.typeString(sig.ret));
				makeCall(ctx, ce, r.el, sig.ret, p);
			case TMono(_):
				var args = [for (e in el) Typer.typeExpr(ctx, e, WithTypeTools.value)];
				DebugDump.selected("call", p, "mono function");
				makeCall(ctx, ce, args, TypeFunctions.mkMono(), p);
			case TDynamic(_):
				var args = [for (e in el) Typer.typeExpr(ctx, e, WithTypeTools.value)];
				DebugDump.selected("call", p, "dynamic function");
				makeCall(ctx, ce, args, TDynamic(null), p);
			case TAbstract(a, tl) if (a.call != null && a.impl != null):
				// @:op(a()) call operator: dispatch to the impl call field with the abstract value as its
				// first (`this`) argument. (call branch).
				var sig = switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, a.call.type))) {
					case TFun(s) if (s.args.length >= 1): s;
					case _: null;
				};
				if (sig == null) throw new TypingError("Cannot call a non-function value", p);
				var implExpr = TexprTools.makeStaticThis(a.impl, p);
				var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, a.call, FHStatic(a.impl), false, p), FCall);
				var r = unifyCallArgs(ctx, el, sig.args.slice(1), sig.ret, p);
				if (DebugDump.enabled("select", p))
					DebugDump.selected("call", p, "abstract callable " + a.call.name + " -> " + DebugDump.typeString(sig.ret));
				makeCall(ctx, fieldExpr, [ce].concat(r.el), sig.ret, p);
			case TAbstract(a, tl) if (TypeFunctions.hasMeta(":callable", a.meta)):
				// @:callable: calling the abstract forwards to its underlying (a function).
				var underlying = TypeFunctions.applyParams(a.params, tl, a.thisType);
				if (DebugDump.enabled("select", p))
					DebugDump.selected("call", p, "callable abstract -> " + DebugDump.typeString(underlying));
				callExpr(ctx, TypeFunctions.mk(ce.expr, underlying, ce.pos), el, p);
			case _:
				throw new TypingError("Cannot call a non-function value", p);
		};
	}
}
