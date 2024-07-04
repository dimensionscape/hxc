package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.WarningList.Warning;
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
	static function checkAbstractCallWrite(ctx:TyperContext, receiver:TExpr, fa:FieldAccess, p:Position):Void {
		var cf = fa.field;
		if (!TypeFunctions.hasClassFieldFlag(cf, CfImpl)) return;
		var host = try FieldAccessTools.getHostClassRaise(fa.host) catch (_:Dynamic) null;
		if (host == null) return;
		hxc.typing.TypeFields.forceFieldBody(ctx.com, host, cf);
		var body = cf.expr;
		if (body == null) return;
		var arg:TVar = null;
		switch (body.expr) { case TFunction(tf) if (tf.args.length > 0): arg = tf.args[0].v; case _: return; }
		var writes = false;
		function visit(e:TExpr):Void switch (e.expr) {
			case TBinop(OpAssign | OpAssignOp(_), {expr: TLocal(v)}, _) if (v == arg): writes = true;
			case TUnop(Increment | Decrement, _, {expr: TLocal(v)}) if (v == arg): writes = true;
			case _: TexprTools.iter(visit, e);
		};
		visit(body);
		if (!writes) return;
		switch (receiver.expr) {
			case TLocal(v) if (TypeFunctions.hasVarFlag(v, VFinal)):
				throw new TypingError("Cannot modify abstract value of final local", p);
			case _:
		}
	}

	public static function makeCall(ctx:TyperContext, e:TExpr, params:Array<TExpr>, t:T, p:Position, forceInline = false, forcePos:Null<Position> = null):TExpr {
		var inlinePos = forcePos == null ? p : forcePos;
		if (forceInline) switch (e.expr) {
			case TField(base, FInstance(c, _, cf)):
				if (TypeFunctions.hasClassFieldFlag(cf, CfAbstract)) switch (base.expr) {
					case TConst(TSuper):
						throw new TypingError("abstract method " + cf.name + " cannot be accessed directly", p);
					case _:
				}
				if (TypeFunctions.hasClassFieldFlag(cf, CfAbstract) && !cf.kind.match(Method(MethInline)))
					throw new TypingError("Cannot force inline on abstract method", inlinePos);
				function hasOverride(c2:TClass):Bool {
					if (c2.fields.exists(cf.name)) return true;
					for (d in c2.descendants) if (hasOverride(d)) return true;
					return false;
				}
				for (d in c.descendants) if (hasOverride(d))
					throw new TypingError("Cannot force inline-call to " + cf.name + " because it is overridden", p);
			case _:
		}
		if (!forceInline) switch (e.expr) {
			case TField(base, FInstance(_, _, cf)):
				if (TypeFunctions.hasClassFieldFlag(cf, CfAbstract)) switch (base.expr) {
					case TConst(TSuper): throw new TypingError("abstract method " + cf.name + " cannot be accessed directly", p);
					case _:
				}
			case _:
		}
		// A call to an inline function expands in place; on any unhandled construct it falls back here.
		var inlined = Inline.tryInline(ctx, e, params, t, p, forceInline);
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
				return AKExpr(abstractArrayGet(ctx, a, tl, a.impl, e1, e2, p).expr);
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
				// Array<Dynamic> element access stays Dynamic instead of spawning a monomorph (which a
				// later
				// access would bind, retyping the read).
				if (c.path.pack.length == 0 && c.path.name == "Array") switch (tl) {
					case [td] if (TypeFunctions.follow(td).match(TDynamic(null))):
						try TypeUnification.unifyDefault(e2.type, ctx.com.basic.tint)
						catch (_:UnifyError) throw new TypingError("Array index must be of type Int", e2.pos);
						return AKExpr(TypeFunctions.mk(TArray(e1, e2), TypeFunctions.tDynamic, p));
					case _:
				}
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
			// Untyped code swallows both failures
			if (!ctx.untypedMode)
				throw new TypingError("Array access is not allowed on " + hxc.core.TPrinting.sTypeStr(e1.type), e1.pos);
		}
		try {
			TypeUnification.unifyDefault(e2.type, ctx.com.basic.tint);
		} catch (_:UnifyError) {
			if (!ctx.untypedMode)
				throw new TypingError("Array index must be of type Int", e2.pos);
		}
		return AKExpr(TypeFunctions.mk(TArray(e1, e2), pt, p));
	}

	// An @:arrayAccess method's own type parameters are instantiated as constrained monomorphs so the
	// key and value unify against them while the constraints still apply.
	static function arrayAccessFieldType(tl:TParams, a:TAbstract, cf:TClassField):T {
		var t = TypeFunctions.applyParams(a.params, tl, cf.type);
		if (cf.params.length > 0) {
			var monos = TypeUnification.spawnConstrainedMonos(function(t2) return TypeFunctions.applyParams(a.params, tl, t2), cf.params);
			t = TypeFunctions.applyParams(cf.params, monos, t);
		}
		return t;
	}

	// The type the candidate's first (this) parameter must accept: the underlying type for an
	// instance-style member, the abstract itself for a static @:op([]) form.
	static function arrayAccessThisType(a:TAbstract, tl:TParams, cf:TClassField):T {
		return TypeFunctions.hasClassFieldFlag(cf, CfImpl)
			? TypeFunctions.applyParams(a.params, tl, a.thisType)
			: TAbstract(a, tl);
	}

	public static function abstractArrayGet(ctx:TyperContext, a:TAbstract, tl:TParams, c:TClass, ebase:TExpr, ekey:TExpr, p:Position):{expr:TExpr, key:TExpr} {
		for (cf in a.array) {
			if (cf.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx.com, c, cf);
			switch (TypeFunctions.follow(arrayAccessFieldType(tl, a, cf))) {
				case TFun(sig) if (sig.args.length == 2 || (sig.args.length == 3 && sig.args[2].opt)):
					try {
						// The first parameter is the abstract itself; a candidate whose declared this-type
						// does not
						// unify with this instantiation is skipped.
						TypeUnification.unifyDefault(sig.args[0].t, arrayAccessThisType(a, tl, cf));
						var key = Typer.castOrUnify(ctx, sig.args[1].t, ekey, ekey.pos);
						if (cf.expr == null && !TypeFunctions.hasClassFieldFlag(cf, CfExtern))
							return {expr: TypeFunctions.mk(TArray(ebase, key), sig.ret, p), key: key};
						var implExpr = TexprTools.makeStaticThis(c, p);
						var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(c), false, p), FCall);
						return {expr: makeCall(ctx, fieldExpr, padPosInfos(ctx, sig.args, [ebase, key], p), sig.ret, p), key: key};
					} catch (_:TypingError) {} catch (_:hxc.core.TypeUnification.UnifyError) {}
				case _:
			}
		}
		// One shared print context, key side first.
		var pctx = hxc.core.TPrinting.printContext();
		var keyS = hxc.core.TPrinting.sType(pctx, ekey.type);
		var aS = hxc.core.TPrinting.sType(pctx, TAbstract(a, tl));
		throw new TypingError("No @:arrayAccess function for " + aS + " accepts argument of " + keyS, p);
	}

	// Abstract @:arrayAccess write: call the impl setter taking (this, key, value). .
	public static function arraySet(ctx:TyperContext, a:TAbstract, tl:TParams, c:TClass, ebase:TExpr, ekey:TExpr, valueExpr:Expr, p:Position):TExpr {
		return arraySetValue(ctx, a, tl, c, ebase, ekey, function(vt:T) return Typer.typeExpr(ctx, valueExpr, WithTypeTools.withType(vt)), p);
	}

	// Setter call with an already-computed value; valueFn receives the setter's value-parameter type so a
	// plain write can infer its literal, while a compound write supplies the precomputed op result.
	public static function arraySetValue(ctx:TyperContext, a:TAbstract, tl:TParams, c:TClass, ebase:TExpr, ekey:TExpr, valueFn:T->TExpr, p:Position, throwOnFail:Bool = true):Null<TExpr> {
		var lastVal:Null<TExpr> = null;
		for (cf in a.array) {
			if (cf.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx.com, c, cf);
			switch (TypeFunctions.follow(arrayAccessFieldType(tl, a, cf))) {
				case TFun(sig) if (sig.args.length == 3 || (sig.args.length == 4 && sig.args[3].opt)):
					try {
						TypeUnification.unifyDefault(sig.args[0].t, arrayAccessThisType(a, tl, cf));
						var key = Typer.castOrUnify(ctx, sig.args[1].t, ekey, ekey.pos);
						var val = valueFn(sig.args[2].t);
						lastVal = val;
						val = Typer.castOrUnify(ctx, sig.args[2].t, val, p);
						if (cf.expr == null && !TypeFunctions.hasClassFieldFlag(cf, CfExtern)) {
							var ea = TypeFunctions.mk(TArray(ebase, key), sig.ret, p);
							return TypeFunctions.mk(TBinop(OpAssign, ea, val), sig.ret, p);
						}
						var implExpr = TexprTools.makeStaticThis(c, p);
						var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(c), false, p), FCall);
						return makeCall(ctx, fieldExpr, padPosInfos(ctx, sig.args, [ebase, key, val], p), sig.ret, p);
					} catch (_:TypingError) {} catch (_:hxc.core.TypeUnification.UnifyError) {}
				case _:
			}
		}
		if (!throwOnFail) return null;
		// Value side prints first, then key, then the abstract (one shared context).
		var pctx = hxc.core.TPrinting.printContext();
		var valS = hxc.core.TPrinting.sType(pctx, lastVal != null ? lastVal.type : TypeFunctions.tDynamic);
		var keyS = hxc.core.TPrinting.sType(pctx, ekey.type);
		var aS = hxc.core.TPrinting.sType(pctx, TAbstract(a, tl));
		throw new TypingError("No @:arrayAccess function for " + aS + " accepts arguments of " + keyS + " and " + valS, p);
	}

	// The element type of a haxe.Rest<T>, or null if `t` is not a rest type.
	static function restElemType(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, params) if (params.length == 1 && a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Rest"): params[0];
			case _: null;
		};
	}

	public static function unifyCallArgs(ctx:TyperContext, el:Array<Expr>, args:Array<TSignatureArg>, r:T, callp:Position):{el:Array<TExpr>, tfunc:T} {
		// ctx.inCallArgs is set around the argument loop.
		var savedInCallArgs = ctx.inCallArgs;
		ctx.inCallArgs = true;
		try {
			var r2 = unifyCallArgsInner(ctx, el, args, r, callp);
			ctx.inCallArgs = savedInCallArgs;
			return r2;
		} catch (e:haxe.Exception) {
			ctx.inCallArgs = savedInCallArgs;
			throw e;
		}
	}

	static function unifyCallArgsInner(ctx:TyperContext, el:Array<Expr>, args:Array<TSignatureArg>, r:T, callp:Position):{el:Array<TExpr>, tfunc:T} {
		function typeAgainst(name:String, t:T, e:Expr):TExpr {
			var te = Typer.typeExpr(ctx, e, WithTypeTools.withArgument(t, name));
			DebugDump.unify("call-arg " + name, te.type, t, te.pos);
			return Typer.castOrUnify(ctx, t, te, te.pos);
		}
		// Optional parameters skipped while fitting a later argument, oldest first, each with the
		// error it produced. When a subsequent argument cannot be placed, the first skipped
		// parameter's error is reported instead.
		var skipped:Array<{name:String, msg:String, pos:Position, depth:Int}> = [];
		// Annotate the argument's error with the parameter name; the have/want rendering drops the
		// trailing annotation.
		function argError(msg:String, name:String, opt:Bool, pos:Position, depth:Int):TypingError {
			if (StringTools.startsWith(msg, "error: ")) return new TypingError(msg, pos, depth);
			// A call error from typing the argument itself is not an argument-unification failure; it
			// reports plain. (handle_errors keeps Call_error out of WithTypeError).
			if (StringTools.startsWith(msg, "Not enough arguments") || StringTools.startsWith(msg, "Too many arguments")) return new TypingError(msg, pos, depth);
			if (StringTools.startsWith(msg, "Type parameters of multi type abstracts must be known")) return new TypingError(msg, pos, depth);
			if (StringTools.startsWith(msg, "Cannot use null as ternary condition")) return new TypingError(msg, pos, depth);
			if (msg.indexOf(" has no field ") >= 0) return new TypingError(msg, pos, depth);
			if (msg.indexOf("For function argument '") >= 0) return new TypingError(msg, pos, depth);
			return new TypingError(msg + "\nFor " + (opt ? "optional " : "") + "function argument '" + name + "'", pos, depth);
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
					// Platforms with native rest args pass each argument individually; a lone spread stays
					// a
					// spread unop
					if (ctx.com.platformConfig.supportsRestArgs) {
						if (spreadInner != null) {
							var te = typeAgainst(name, rt, spreadInner);
							out.push(TypeFunctions.mk(TUnop(Spread, Prefix, te), rt, remaining[0].pos));
						} else if (TypeFunctions.follow(argT).match(TMono(_))) {
							var tel:Array<TExpr> = [];
							for (e in remaining) {
								switch (e.expr) {
									case EUnop(Spread, Prefix, _): throw new TypingError("Cannot spread arguments with additional rest arguments", e.pos);
									case _: tel.push(typeAgainst(name, Typer.spawnMonomorph(ctx, e.pos), e));
								}
							}
							TypeUnification.unifyDefault(Typer.unifyMinRaise(ctx, tel), argT);
							for (te in tel) out.push(te);
						} else {
							for (e in remaining) {
								switch (e.expr) {
									case EUnop(Spread, Prefix, _): throw new TypingError("Cannot spread arguments with additional rest arguments", e.pos);
									case _: out.push(typeAgainst(name, argT, e));
								}
							}
						}
						ei = el.length;
						ai = args.length;
						continue;
					}
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
				// Trailing optional parameters fill right to left; a tail that stays empty is OMITTED
				// unless
				// the platform pads nulls, with a trailing PosInfos parameter auto-filled; a null pads
				// before
				// any filled tail
				function tailLoop(k:Int):Array<TExpr> {
					if (k >= args.length) return [];
					var a = args[k];
					if (args.length - k == 1 && !a.opt && restElemType(a.t) != null) {
						if (ctx.com.platformConfig.supportsRestArgs) return [];
						return [typeAgainst(a.name, a.t, new Expr(EArrayDecl([]), callp))];
					}
					if (!a.opt) throw new TypingError("Not enough arguments, expected " + [for (x in args.slice(k)) x.name + ":" + hxc.core.TPrinting.sTypeStr(x.t)].join(", "), callp);
					var rest = tailLoop(k + 1);
					var pi = makePosInfosArg(ctx, a.t, callp);
					if (rest.length == 0 && !ctx.com.platformConfig.padNulls)
						return pi != null ? [pi] : [];
					// A PosInfos parameter's default value is filled in even when padding nulls
					return [pi != null ? pi : TexprTools.makeNull(ctx.com.basic.tnull(a.t), callp)].concat(rest);
				}
				for (te in tailLoop(ai)) out.push(te);
				ai = args.length;
			} else if (ai >= args.length) {
				// A skipped optional parameter's error takes precedence over "Too many arguments".
				if (skipped.length > 0) throw argError(skipped[0].msg, skipped[0].name, true, skipped[0].pos, skipped[0].depth);
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
					if (a.opt && mightSkip) {
						skip = true;
						skipped.push({name: a.name, msg: err.message, pos: err.pos, depth: err.depth});
					} else if (skipped.length > 0) {
						// Report the first skipped parameter's own error, not this one.
						throw argError(skipped[0].msg, skipped[0].name, true, skipped[0].pos, skipped[0].depth);
					} else {
						throw argError(err.message, a.name, a.opt, err.pos, err.depth);
					}
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
		// A function literal, local function or immutable method value is called directly; an instance
		// closure binds only its RECEIVER to a temp and calls the method through FInstance; anything else
		// binds the whole function value.
		inline function immutableMethod(cf:TClassField):Bool
			return switch (cf.kind) { case Method(k): k != MethDynamic; case _: false; };
		var feLocal = switch (fe.expr) {
			case TFunction(_) | TLocal({kind: VUser(TVOLocalFunction)}):
				fe;
			case TField(_, FStatic(_, cf) | FInstance(_, _, cf)) if (immutableMethod(cf)):
				fe;
			case TField(eobj, FClosure(cwp, cf)) if (cwp != null && immutableMethod(cf)):
				var vobj = TypeFunctions.allocVar(VGenerated, "`", eobj.type, eobj.pos);
				decls.push(TypeFunctions.mk(TVarExpr(vobj, eobj), tvoid, eobj.pos));
				TypeFunctions.mk(TField(TexprTools.makeLocal(vobj, eobj.pos), FInstance(cwp.c, cwp.params, cf)), fe.type, fe.pos);
			case _:
				var fv = TypeFunctions.allocVar(VGenerated, "`", fe.type, fe.pos);
				decls.push(TypeFunctions.mk(TVarExpr(fv, fe), tvoid, fe.pos));
				TexprTools.makeLocal(fv, fe.pos);
		};
		var callArgs:Array<TExpr> = [];
		var missingVl:Array<TVar> = [];
		var missingArgs:Array<TSignatureArg> = [];
		var pi = 0;
		for (arg in sig.args) {
			var isUnderscore = pi < params.length && (switch (params[pi].expr) { case EConst(CIdent("_")): true; case _: false; });
			if (pi >= params.length && arg.opt) {
				// An optional argument past the given parameters is consumed at bind time instead of
				// staying on
				// the closure: PosInfos receives the bind-site infos, pad-null targets get null, anything
				// else
				// is dropped.
				var infos = makePosInfosArg(ctx, arg.t, p);
				if (infos != null) callArgs.push(infos);
				else if (ctx.com.platformConfig.padNulls) callArgs.push(TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, p));
				continue;
			}
			if (pi >= params.length || isUnderscore) {
				// The missing arg keeps its position on the closure. An optional arg becomes Null<t> so the
				// bound closure can pass null through to the original function's default.
				var vt = arg.opt ? ctx.com.basic.tnull(arg.t) : arg.t;
				var v = TypeFunctions.allocVar(VGenerated, arg.name, vt, p);
				missingVl.push(v);
				missingArgs.push({name: arg.name, opt: arg.opt, t: vt});
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
		// A void-returning bound call stays a bare statement.
		var isVoid = switch (TypeFunctions.follow(sig.ret)) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
		var body = isVoid ? call : TypeFunctions.mk(TReturn(call), sig.ret, p);
		// An optional closure arg defaults to null so a no-arg call reaches the original function as
		// null and triggers its own default.
		var tfArgs:Array<TFuncArg> = [for (i in 0...missingVl.length)
			{v: missingVl[i], c: missingArgs[i].opt ? TexprTools.makeNull(missingVl[i].type, Position.nullPos) : null}];
		var tf = new TFunc(tfArgs, sig.ret, body);
		var ft = TFun({args: missingArgs, ret: sig.ret});
		decls.push(TypeFunctions.mk(TFunction(tf), ft, p));
		return TypeFunctions.mk(TBlock(decls), ft, p);
	}

	// A call target goes through buildCall (core: plain function value and method call).
	public static function typeCall(ctx:TyperContext, callee:Expr, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		return Typer.accGet(ctx, typeCallAccess(ctx, callee, el, withType, p));
	}

	public static function typeCallAccess(ctx:TyperContext, callee:Expr, el:Array<Expr>, withType:WithType, p:Position, forceInline = false, forcePos:Null<Position> = null):AccessKind {
		switch (callee.expr) {
			case EConst(CIdent("null")):
				throw new TypingError("This expression cannot be called", callee.pos);
			case EConst(CIdent("trace")) if (!ctx.locals.exists("trace")):
				return AKExpr(typeTrace(ctx, el, withType, p));
			case EConst(CIdent("$type")) if (el.length == 1):
				// $type(e): type e, report its type, return e unchanged; $type(_) reports the expected
				// with-type instead.
				switch (el[0].expr) {
					case EConst(CIdent("_")):
						ctx.com.warning(WInfo, hxc.core.WarningList.fromMeta(ctx.curfield.meta).concat(hxc.core.WarningList.fromMeta(ctx.curclass.meta)), WithTypeTools.toString(withType), p);
						return AKExpr(TypeFunctions.mk(TConst(TNull), TDynamic(null), p));
					case _:
						var te = Typer.typeExpr(ctx, el[0], WithTypeTools.value);
						ctx.com.warning(WInfo, hxc.core.WarningList.fromMeta(ctx.curfield.meta).concat(hxc.core.WarningList.fromMeta(ctx.curclass.meta)), hxc.core.TPrinting.sTypeStr(te.type), te.pos);
						return AKExpr(te);
				}
			case EConst(CIdent("super")):
				return AKExpr(typeSuperCall(ctx, el, p));
			case EConst(CIdent("__unprotect__")) if (el.length == 1 && el[0].expr.match(EConst(CString(_, _)))):
				// `__unprotect__("name")` is a Flash-only obfuscation guard; every other target types it
				// away
				// to the bare string.
				var e = Typer.typeExpr(ctx, el[0], WithTypeTools.value);
				if (ctx.com.platform == Flash) {
					var eUnprotect = TypeFunctions.mk(TIdent("__unprotect__"), TypeFunctions.tfun([e.type], e.type), p);
					return AKExpr(TypeFunctions.mk(TCall(eUnprotect, [e]), e.type, e.pos));
				}
				return AKExpr(e);
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
					var matched = Match.matchExpr(ctx, e1, cases, def, WithTypeTools.withType(ctx.com.basic.tbool), true, p);
					var matchedVoid = switch (TypeFunctions.follow(matched.type)) {
						case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Void"): true;
						case _: false;
					};
					return AKExpr(matchedVoid
						? TypeFunctions.mk(matched.expr, ctx.com.basic.tbool, matched.pos)
						: matched);
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
		// An immediately invoked function is a value in callee position even when the call itself is a
		// statement call targets with WithType.value).
		var calleeWt = withType;
		{
			var inner = callee.expr;
			while (true) switch (inner) {
				case EParenthesis(e1): inner = e1.expr;
				case EFunction(_, _): calleeWt = WithTypeTools.value; break;
				case _: break;
			}
		}
		var acc = Typer.typeAccess(ctx, callee.expr, callee.pos, MCall(el), calleeWt);
		Typer.noteDisplayAccess(acc, callee.pos);
		return buildCallAccess(ctx, acc, el, withType, p, forceInline, forcePos);
	}

	// Only a compound expression must be bound to a temp so the null guard evaluates it once; a
	// local, type expr, const or a field/parenthesis chain over one is duplicated in place.
	public static function needsTempVar(e:TExpr):Bool {
		return switch (e.expr) {
			case TLocal(_) | TTypeExpr(_) | TConst(_): false;
			case TField(e1, _) | TParenthesis(e1): needsTempVar(e1);
			case _: true;
		};
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
		// Type the super constructor's body first so an unannotated parameter is inferred from the body
		// (binding its monomorph to the class parameter) before the call arguments unify; otherwise the
		// argument binds the shared signature monomorph to the call's concrete type, and the later body
		// typing drops the field assignment on a unification failure.
		if (c.constructor != null && c.constructor.expr == null)
			TypeFields.forceFieldBody(ctx.com, c, c.constructor);
		// The super constructor resolves through overloads, trying every @:overload variant. Gather the
		// constructor signatures (primary + overloads, walking up and applying the super's type
		// params) and try each, first success wins (like typeNew's overload retry).
		var ctorTypes = Typer.findConstructorTypes(ctx, c, sup.params);
		if (ctorTypes.length == 0) ctorTypes = [TFun({args: [], ret: ctx.com.basic.tvoid})];
		var r:Dynamic = null;
		var firstError:Null<Dynamic> = null;
		for (ctorType in ctorTypes) {
			var sig = switch (TypeFunctions.follow(ctorType)) {
				case TFun(s): s;
				case _: {args: [], ret: ctx.com.basic.tvoid};
			};
			try {
				r = TypeUnification.withMonoRollback(function() return unifyCallArgs(ctx, el, sig.args, sig.ret, p));
				break;
			} catch (e:hxc.core.TypeUnification.UnifyError) {
				if (firstError == null) firstError = e;
			} catch (e:TypingError) {
				if (firstError == null) firstError = e;
			}
		}
		if (r == null) throw (firstError != null ? firstError : new TypingError("No matching super constructor overload", p));
		var superExpr = TypeFunctions.mk(TConst(TSuper), TInst(c, sup.params), p);
		return TypeFunctions.mk(TCall(superExpr, r.el), ctx.com.basic.tvoid, p);
	}

	// A final optional `?p:haxe.PosInfos` the caller omits is filled with the call-site position info.
	// The file is made relative: the first class-path entry whose slashed, lowercased string
	// prefixes the file's full path is stripped; otherwise the file stays as stored. Macro contexts
	// keep file verbatim.
	public static function posInfosFile(ctx:TyperContext, pfile:String):String {
		if (ctx.com.isMacro) return pfile;
		if (ctx.com.defines.rawDefined("absolute_path")) return StringTools.replace(sys.FileSystem.absolutePath(pfile), "\\", "/");
		var fpath = StringTools.replace(sys.FileSystem.absolutePath(pfile), "\\", "/");
		var fpathLower = fpath.toLowerCase();
		for (cp in ctx.com.classPath) {
			var spath = StringTools.replace(cp, "\\", "/").toLowerCase();
			if (spath.length > 0 && spath.length < fpathLower.length && fpathLower.substr(0, spath.length) == spath)
				return fpath.substr(spath.length);
		}
		return pfile;
	}

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
			fld("fileName", strE(posInfosFile(ctx, callp.file))),
			fld("lineNumber", new Expr(EConst(CInt(Std.string(Position.lineNumber(callp)), null)), callp)),
			fld("className", strE(ctx.curclass == null ? "" : hxc.core.Globals.sTypePath(ctx.curclass.path))),
			fld("methodName", strE(ctx.curfield == null ? "" : ctx.curfield.name))
		]), callp);
		return try Typer.typeExpr(ctx, infos, WithTypeTools.withType(t)) catch (_:Dynamic) null;
	}

	// Pad an abstract-dispatch call (op, cast, array access, resolve) with the call-site PosInfos
	// when the impl method declares one more trailing optional argument of that type, as an
	// ordinary call's arguments are padded.
	public static function padPosInfos(ctx:TyperContext, sigArgs:Array<TSignatureArg>, el:Array<TExpr>, callp:Position):Array<TExpr> {
		if (sigArgs.length != el.length + 1) return el;
		var last = sigArgs[sigArgs.length - 1];
		if (!last.opt) return el;
		var pi = makePosInfosArg(ctx, last.t, callp);
		return pi == null ? el : el.concat([pi]);
	}

	// `e == null ? "null" : e.toString()` (js is not isStatic, so the null check always applies),
	// with a temp when e needs one
	public static function callToString(ctx:TyperContext, e:TExpr):TExpr {
		var tstring = ctx.com.basic.tstring;
		function genToString(x:TExpr):TExpr {
			// Ignore visibility of the toString field
			ctx.privateAccess++;
			var acc = hxc.typing.Fields.typeField(ctx, x, "toString", x.pos, MCall([]), WithTypeTools.withType(tstring));
			ctx.privateAccess--;
			return buildCall(ctx, acc, [], WithTypeTools.withType(tstring), x.pos);
		}
		// A static-platform non-nullable operand never takes the null branch, and the `e == null` check
		// below would type a null at the operand's non-nullable basic type, tripping the static-null
		// check.
		if (ctx.com.platformConfig.isStatic && !TypeFunctions.isNullable(e.type))
			return genToString(e);
		var stringNull = TypeFunctions.mk(TConst(TString("null")), tstring, e.pos);
		var simple = switch (e.expr) { case TLocal(_) | TConst(_) | TTypeExpr(_): true; case _: false; };
		if (!simple) {
			var tmp = TypeFunctions.allocVar(VGenerated, "tmp", e.type, e.pos);
			var tmpLocal = TexprTools.makeLocal(tmp, tmp.pos);
			var checkNull = TypeFunctions.mk(TBinop(OpEq, tmpLocal, TexprTools.makeNull(tmp.type, tmp.pos)), ctx.com.basic.tbool, e.pos);
			return TypeFunctions.mk(TBlock([
				TypeFunctions.mk(TVarExpr(tmp, e), tmp.type, tmp.pos),
				TypeFunctions.mk(TIf(checkNull, stringNull, genToString(tmpLocal)), tstring, tmp.pos)
			]), tstring, e.pos);
		}
		var checkNull = TypeFunctions.mk(TBinop(OpEq, e, TexprTools.makeNull(e.type, e.pos)), ctx.com.basic.tbool, e.pos);
		return TypeFunctions.mk(TIf(checkNull, stringNull, genToString(e)), tstring, e.pos);
	}

	// Trace(v, ...) keeps the `trace magic call on js with dce so the generator can decide between
	// console.log and haxe.Log.trace; otherwise it lowers to haxe.Log.trace with the call-site
	// position info
	static function typeTrace(ctx:TyperContext, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		if (ctx.com.defines.rawDefined("no_traces"))
			return TypeFunctions.mk(TConst(TNull), ctx.com.basic.tvoid, p);
		function strE(s:String):Expr return new Expr(EConst(CString(s, SDoubleQuotes)), p);
		function fld(name:String, e:Expr):ObjectField return {name: name, expr: e, quotes: NoQuotes, pos: p};
		function mkToStringMeta(e:Expr):Expr return new Expr(EMeta({name: ":toString", params: [], pos: Position.nullPos}, e), e.pos);
		var v = el.length > 0 ? el[0] : strE("");
		// customParams only with extra args, methodName only inside a named field
		var fields = [
			fld("fileName", strE(posInfosFile(ctx, p.file))),
			fld("lineNumber", new Expr(EConst(CInt(Std.string(Position.lineNumber(p)), null)), p)),
			fld("className", strE(hxc.core.Globals.sTypePath(ctx.curclass.path)))
		];
		if (ctx.curfield != null && ctx.curfield.name != "")
			fields.push(fld("methodName", strE(ctx.curfield.name)));
		if (el.length > 1)
			fields.push(fld("customParams", new Expr(EArrayDecl([for (e2 in el.slice(1)) mkToStringMeta(e2)]), p)));
		var infos = new Expr(EObjectDecl(fields), p);
		if ((ctx.com.platform.match(Js) || ctx.com.platform.match(Python)) && el.length <= 1 && ctx.com.hasDce()) {
			var e = Typer.typeExpr(ctx, v, WithTypeTools.value);
			var tinfos = Typer.typeExpr(ctx, infos, WithTypeTools.value);
			e = switch (TypeFunctions.follow(e.type)) {
				case TAbstract(a, _) if (a.impl != null && a.impl.statics.exists("toString")):
					callToString(ctx, e);
				case _:
					e;
			};
			var eTrace = TypeFunctions.mk(TIdent("`trace"), TypeFunctions.tDynamic, p);
			return TypeFunctions.mk(TCall(eTrace, [e, tinfos]), ctx.com.basic.tvoid, p);
		}
		var haxePkg = new Expr(EConst(CIdent("haxe")), p);
		var logTrace = new Expr(EField(new Expr(EField(haxePkg, "Log", EFNormal), p), "trace", EFNormal), p);
		return Typer.typeExpr(ctx, new Expr(ECall(logTrace, [mkToStringMeta(v), infos]), p), WithTypeTools.noValue);
	}

	public static function buildCallAccess(ctx:TyperContext, acc:AccessKind, el:Array<Expr>, withType:WithType, p:Position, forceInline = false, forcePos:Null<Position> = null):AccessKind {
		return switch (acc) {
			case AKSafeNav(sn):
				AKSafeNav({
					pos: sn.pos,
					base: sn.base,
					tempVar: sn.tempVar,
				access: buildCallAccess(ctx, sn.access, el, withType, p, forceInline, forcePos)
				});
			case _:
				AKExpr(buildCall(ctx, acc, el, withType, p, forceInline, forcePos));
		};
	}

	// Calling a sibling impl method that reassigns `this` from a non inline context spreads the
	// modification illegally; an allowed context inherits the flag instead.
	static function checkModifiesThis(ctx:TyperContext, se:StaticExtensionAccess, p:Position):Void {
		var host = try FieldAccessTools.getHostClassRaise(se.access.host) catch (_:Dynamic) null;
		if (host == null) return;
		checkModifiesThisDirect(ctx, host, se.access.field, se.thisExpr, p);
	}

	public static function checkModifiesThisDirect(ctx:TyperContext, host:TClass, f:TClassField, receiver:TExpr, p:Position):Void {
		if (f.name == "_new" || f.name == "new") return;
		if (!ctx.curclass.kind.match(KAbstractImpl(_))) return;
		var receiverIsThis = switch (receiver.expr) {
			case TLocal(v): v.name == "this" || TypeFunctions.hasMeta(":this", v.meta) || TypeFunctions.hasMeta(":implicitThis", v.meta);
			case _: false;
		};
		if (!receiverIsThis) return;
		if (host != ctx.curclass) return;
		TypeFields.forceFieldBody(ctx.com, host, f);
		if (!TypeFunctions.hasClassFieldFlag(f, CfModifiesThis)) return;
		if (Typer.assignToThisIsAllowed(ctx))
			TypeFunctions.addClassFieldFlag(ctx.curfield, CfModifiesThis);
		else
			throw new TypingError("Abstract 'this' value can only be modified inside an inline function. '" + f.name + "' modifies 'this'", p);
	}

	public static function buildCall(ctx:TyperContext, acc:AccessKind, el:Array<Expr>, withType:WithType, p:Position, forceInline = false, forcePos:Null<Position> = null):TExpr {
		return switch (acc) {
			case AKExpr(ce): callExpr(ctx, ce, el, p, forceInline, forcePos);
			case AKField(fa) if (hxc.eval.EvalMacro.isMacroField(fa.field)):
				// Deprecation check on the static macro call path.
				hxc.filters.DeprecationCheck.checkFieldUse(ctx, fa.field, p);
				hxc.eval.EvalMacro.run(ctx, fa, el, withType, p);
			case AKField(fa):
				// A super call to a dynamic method is rejected.
				switch [fa.on.expr, fa.field.kind] {
					case [TConst(TSuper), Method(MethDynamic)]:
						throw new TypingError("Cannot call super." + fa.field.name + " since it's a dynamic method", p);
					case _:
				}
				callFieldAccess(ctx, fa, el, p, withType, forceInline, forcePos);
			case AKUsingField(se) if (hxc.eval.EvalMacro.isMacroField(se.access.field)):
				hxc.eval.EvalMacro.run(ctx, se.access, [typedExprToSyntax(ctx, se.thisExpr)].concat(el), withType, p);
			case AKUsingField(se):
				// Static-extension / abstract impl call: the receiver is the first argument. A generic
				// method specializes here like a plain field call does.
				checkModifiesThis(ctx, se, p);
				checkAbstractCallWrite(ctx, se.thisExpr, se.access, p);
				var mono = monomorphizeParamsWith(ctx, se.access.field, callFieldExpr(ctx, se.access), se.access);
				var ce = mono.expr;
				switch (TypeFunctions.follow(ce.type)) {
					case TFun(sig) if (sig.args.length > 0):
						// The receiver unifies against the first parameter before the syntactic args, so a method
						// type param binds from the receiver, not from a later lambda argument. An abstract impl
						// receiver unifies as the applied underlying type, except _new. A @:multiType receiver goes
						// through the abstract cast and replaces the receiver expression.
						var recvThis = se.thisExpr;
						function isMultiType(t:T):Bool
							return switch (TypeFunctions.follow(t)) {
								case TAbstract(a, _): TypeFunctions.hasMeta(":multiType", a.meta);
								case _: false;
							}
						switch (se.access.host) {
							case FHAbstract(a, atl, _) if (se.access.field.name != "_new"):
								try {
									hxc.core.TypeUnification.unifyDefault(TypeFunctions.applyParams(a.params, atl, a.thisType), sig.args[0].t);
								} catch (ue:hxc.core.TypeUnification.UnifyError) {
									throw new TypingError(hxc.core.TPrinting.betterErrorMessage(ue.errors), recvThis.pos);
								}
							case _ if (isMultiType(recvThis.type) || isMultiType(sig.args[0].t)):
								recvThis = Typer.castOrUnify(ctx, sig.args[0].t, recvThis, recvThis.pos);
							case _:
								try {
									hxc.core.TypeUnification.unifyDefault(recvThis.type, sig.args[0].t);
								} catch (ue:hxc.core.TypeUnification.UnifyError) {
									throw new TypingError(hxc.core.TPrinting.betterErrorMessage(ue.errors), recvThis.pos);
								}
						}
						var r = unifyCallArgs(ctx, el, sig.args.slice(1), sig.ret, p);
						var faCall = genericFieldAccess(ctx, se.access, se.access.field, mono.monos, ce.type, withType);
						if (faCall != se.access) ce = FieldAccessTools.getFieldExpr(faCall, FCall);
						var ret = switch (TypeFunctions.follow(ce.type)) { case TFun(sig2): sig2.ret; case _: sig.ret; };
						makeCall(ctx, ce, [recvThis].concat(r.el), ret, p, forceInline, forcePos);
					case _: throw new TypingError("Static-extension target is not a function", p);
				}
			case AKNo(_, pp): throw new TypingError("This expression cannot be called", pp);
			case AKAccessor(_):
				// Calling a property whose value is itself callable: read it through the getter, then call
				// the
				// resulting value.
				callExpr(ctx, Typer.accGet(ctx, acc), el, p, forceInline, forcePos);
			case AKResolve(_, _):
				// Calling a resolve field reads it through the resolve method, then calls the result.
				callExpr(ctx, Typer.accGet(ctx, acc), el, p, forceInline, forcePos);
			case AKSafeNav(sn):
				Typer.accGet(ctx, buildCallAccess(ctx, acc, el, withType, p, forceInline, forcePos));
			case AKUsingAccessor(_):
				// Calling an abstract property whose value is itself callable: read it through the impl
				// accessor (with the receiver), then call the resulting value.
				callExpr(ctx, Typer.accGet(ctx, acc), el, p, forceInline, forcePos);
			case AKAccess(_, _, _, _, _):
				// An array access on an abstract cannot be called.
				throw new TypingError("This expression cannot be called", p);
		};
	}

	// The texpr-to-syntax CONVERTER (getTypedExpr, pattern rebuilding); an expression with no
	// syntactic form stores instead.
	public static function texprToSyntax(ctx:TyperContext, e:TExpr):Expr {
		return try hxc.core.TexprToExpr.convertExpr(e) catch (_:hxc.core.ExitException) typedExprToSyntax(ctx, e);
	}

	// A primitive constant passes as plain syntax; EVERYTHING else stores and passes the
	// @:storedTypedExpr marker, so the macro sees the typed expression by id. The counter is
	// incr-first (the first id is 1).
	public static function typedExprToSyntax(ctx:TyperContext, e:TExpr):Expr {
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
			case _:
				var id = ++hxc.context.Context.nextStoredTypedExprId;
				ctx.com.storedTypedExprs.set(id, e);
				var eid = new Expr(EConst(CInt(Std.string(id), null)), p);
				new Expr(EMeta({name: ":storedTypedExpr", params: [], pos: Position.nullPos}, eid), p);
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

	static function callFieldAccess(ctx:TyperContext, fa:FieldAccess, el:Array<Expr>, p:Position, ?withType:WithType, forceInline = false, forcePos:Null<Position> = null):TExpr {
		// An unhinted parameter's type is inferred from the body; force it before argument unification
		// so the signature is complete. Only an open signature forces, keeping diagnostic order.
		if (fa.field.expr == null) switch (TypeFunctions.follow(fa.field.type)) {
			case TFun(sig):
				// An unhinted RETURN also forces the body: a no-return body links its return to Void, which
				// must
				// settle before an overloaded call reads it.
				var hasOpenArg = TypeFunctions.follow(sig.ret).match(TMono(_));
				for (a in sig.args) if (TypeFunctions.follow(a.t).match(TMono(_))) hasOpenArg = true;
				if (hasOpenArg) switch (fa.host) {
					case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c): TypeFields.forceFieldBody(ctx.com, c, fa.field);
					case FHAnon:
				}
			case _:
		}
		var candidates = [fa.field].concat(fa.field.overloads);
		// Each failed candidate: the overload field, its rendered error, and the error position.
		var failures:Array<{cf:TClassField, msg:String, pos:Position, depth:Int}> = [];
		// With several candidates an argument error must RAISE so the next overload is tried: a lambda
		// body error inside a block would otherwise be recorded as a batch diagnostic and the first
		// candidate would win with a poisoned result. Trial diagnostics roll back per attempt.
		var multi = candidates.length > 1;
		var receiverExtern = switch (fa.host) {
			case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c): TypeFunctions.hasClassFlag(c, CExtern);
			case FHAnon: false;
		};
		if (!receiverExtern) switch (TypeFunctions.follow(fa.on.type)) {
			case TInst(c, _): receiverExtern = TypeFunctions.hasClassFlag(c, CExtern);
			case _:
		}
		var allExtern = multi && receiverExtern && TypeFunctions.hasClassFieldFlag(fa.field, CfOverload);
		var successes:Array<{cf:TClassField, expr:TExpr}> = [];
		for (cf in candidates) {
			var diagBefore = ctx.com.diagnostics.length;
			var oldRaise = ctx.com.raiseTypingErrors;
			if (multi) ctx.com.raiseTypingErrors = true;
			inline function restore() {
				if (multi) {
					ctx.com.raiseTypingErrors = oldRaise;
					if (ctx.com.diagnostics.length > diagBefore) {
						// A failed attempt's WARNINGS stay (a $type inside a lambda reports once per typing
						// attempt);
						// only trial ERRORS roll back.
						var kept = [for (i in diagBefore...ctx.com.diagnostics.length) if (ctx.com.diagnostics[i].severity != hxc.core.Globals.MessageSeverity.Error) ctx.com.diagnostics[i]];
						ctx.com.diagnostics.resize(diagBefore);
						for (d in kept) ctx.com.diagnostics.push(d);
					}
				}
			}
			try {
				var r = TypeUnification.withMonoRollback(function() {
					var fa2 = FieldAccessTools.create(fa.on, cf, fa.host, fa.isInline, fa.pos);
					var mono = monomorphizeParamsWith(ctx, cf, callFieldExpr(ctx, fa2), fa2);
					var ce = mono.expr;
					return switch (TypeFunctions.follow(ce.type)) {
						case TFun(sig):
							var r = unifyCallArgs(ctx, el, sig.args, sig.ret, p);
							// A generic method with a return-only type parameter (e.g. cpp.Stdlib.malloc<T>
							// : cpp.Pointer<T>, whose T is not in any argument) infers T from the expected
							// type before
							// makeCall inlines and closes the monomorphs; otherwise T defaults to Dynamic
							// and the inlined
							// cast is cpp.Pointer<Dynamic>. A @:generic method does the same inside
							// genericFieldAccess
							// (unifying the call's return with the with-type first); do the same for a
							// plain generic method
							// here.
							if (cf.params.length > 0 && !TypeFunctions.hasClassFieldFlag(cf, CfGeneric) && withType != null)
								switch (withType) {
									case WithType(t, _): try TypeUnification.unifyDefault(sig.ret, t) catch (_:hxc.core.TypeUnification.UnifyError) {}
									case _:
								}
							var faCall = genericFieldAccess(ctx, fa2, cf, mono.monos, r.tfunc, withType);
							if (faCall != fa2) ce = FieldAccessTools.getFieldExpr(faCall, FCall);
							var ret = switch (TypeFunctions.follow(ce.type)) {
								case TFun(sig2): sig2.ret;
								case _: sig.ret;
							};
							if (DebugDump.enabled("select", p))
								DebugDump.selected("call", p, "field " + faCall.field.name + " -> " + DebugDump.typeString(ret));
							makeCall(ctx, ce, r.el, ret, p, forceInline, forcePos);
						case _:
							callExpr(ctx, ce, el, p);
					}
				});
				if (multi) ctx.com.raiseTypingErrors = oldRaise;
				if (!allExtern) return r;
				successes.push({cf: cf, expr: r});
			} catch (e:UnifyError) {
				restore();
				failures.push({cf: cf, msg: hxc.core.TPrinting.betterErrorMessage(e.errors), pos: p, depth: 0});
			} catch (e:TypingError) {
				restore();
				failures.push({cf: cf, msg: e.message, pos: e.pos == null ? p : e.pos, depth: e.depth});
			} catch (e:haxe.Exception) {
				restore();
				throw e;
			}
		}
		if (successes.length == 1) return successes[0].expr;
		var externAmbiguous = successes.length > 1 && receiverExtern && TypeFunctions.hasClassFieldFlag(fa.field, CfOverload);
		if (externAmbiguous) {
			var minArgs = 0x7fffffff;
			for (s in successes) switch (TypeFunctions.follow(s.cf.type)) {
				case TFun(sig) if (sig.args.length < minArgs): minArgs = sig.args.length;
				case _:
			}
			var narrow = [for (s in successes) switch (TypeFunctions.follow(s.cf.type)) {
				case TFun(sig) if (sig.args.length == minArgs): s;
				case _: null;
			}].filter(function(s) return s != null);
			if (narrow.length == 1) return narrow[0].expr;
			ctx.com.addDiagnostic("Ambiguous overload, candidates follow", p);
			for (s in successes)
				ctx.com.addDiagnostic("... " + hxc.core.TPrinting.sTypeStr(s.cf.type), s.cf.namePos, 1);
			return successes[0].expr;
		}
		if (successes.length > 1) return successes[0].expr;
		if (failures.length == 0) throw new TypingError("No matching overload", p);
		// A single candidate (or several failing identically) raises the one error; distinct failures
		// report each overload with its own reason (duplicates removed by message, then either the one
		// located error or the "reasons follow" block).
		var distinct:Array<{cf:TClassField, msg:String, pos:Position, depth:Int}> = [];
		for (f in failures) {
			var seen = false;
			for (d in distinct) if (d.msg == f.msg) { seen = true; break; }
			if (!seen) distinct.push(f);
		}
		if (distinct.length == 1) throw new TypingError(distinct[0].msg, distinct[0].pos, distinct[0].depth);
		ctx.com.addDiagnostic("Could not find a suitable overload, reasons follow", p);
		for (f in distinct) {
			ctx.com.addDiagnostic("Overload resolution failed for " + hxc.core.TPrinting.sTypeStr(f.cf.type), p, 1);
			ctx.com.addDiagnostic(f.msg, f.pos, 2);
		}
		throw new TypingError("End of overload failure reasons", p, 1);
	}

	// A generic method's own type parameters become fresh monomorphs for the call. The host's class
	// parameters apply to the constraints, so `getInstance<S:T>` on a GenericTest<MyC> constrains S to
	// MyC rather than to the raw class parameter T.
	static function hostParamMap(fa:Null<FieldAccess>):T->T {
		if (fa == null) return function(t) return t;
		return switch (fa.host) {
			case FHInstance(c, tl) if (c.params.length > 0 && tl.length == c.params.length):
				function(t) return TypeFunctions.applyParams(c.params, tl, t);
			case FHAbstract(a, tl, _) if (a.params.length > 0 && tl.length == a.params.length):
				function(t) return TypeFunctions.applyParams(a.params, tl, t);
			case _: function(t) return t;
		};
	}

	static function monomorphizeParamsWith(ctx:TyperContext, cf:TClassField, ce:TExpr, ?fa:FieldAccess):{expr:TExpr, monos:TParams} {
		if (cf.params.length == 0) return {expr: ce, monos: []};
		var hostMap = hostParamMap(fa);
		var monos:TParams = TypeUnification.spawnConstrainedMonos(hostMap, cf.params);
		// The signature gets the same host mapping as the constraints, so a class parameter appearing in
		// both stays one type (host params apply first, then field params).
		return {expr: TypeFunctions.mk(ce.expr, TypeFunctions.applyParams(cf.params, monos, hostMap(ce.type)), ce.pos), monos: monos};
	}

	static function monomorphizeParams(ctx:TyperContext, cf:TClassField, ce:TExpr, ?fa:FieldAccess):TExpr {
		return monomorphizeParamsWith(ctx, cf, ce, fa).expr;
	}

	static function genericFieldAccess(ctx:TyperContext, fa:FieldAccess, cf:TClassField, monos:TParams, callType:T, ?withType:WithType):FieldAccess {
		if (cf.params.length == 0 || !TypeFunctions.hasClassFieldFlag(cf, CfGeneric)) return fa;
		// A constructor is never specialized: typeNew builds a constructor call, which bypasses the
		// CfGeneric dispatch of an ordinary field call, so a @:generic (abstract) constructor keeps its
		// open method params and simply inlines.
		if (cf.name == "new" || cf.name == "_new") return fa;
		var host = try FieldAccessTools.getHostClassRaise(fa.host) catch (_:hxc.core.NotFound) return fa;
		TypeFields.forceFieldBody(ctx.com, host, cf);
		if (cf.expr == null) return fa;
		// A return-only parameter infers from the expected type before the monomorphs close unifies fc_ret
		// with the with-type first).
		if (withType != null) switch (withType) {
			case WithType(t, _): switch (TypeFunctions.follow(callType)) {
				case TFun(sig): try TypeUnification.unifyDefault(sig.ret, t) catch (_:UnifyError) {}
				case _:
			}
			case _:
		}
		propagateGenericConstraints(ctx, cf.params, monos, hostParamMap(fa));
		closeGenericMonos(monos);
		var params = [for (m in monos) TypeFunctions.follow(m)];
		// Names from the raw bound monos (its loop resolves one step per follow_or), so a typedef-typed
		// parameter keeps its typedef path.
		var name = cf.name + "_" + genericSuffix(monos);
		var stat = switch (fa.host) { case FHStatic(_) | FHAbstract(_, _, _): true; case _: false; }
		// A @:genericClassPerMethod host puts each specialization, under the method's own name, on a
		// synthesized class <Class>_<method>_<Params> in its own module, so the specialization is
		// resolvable by that type path.
		var target = host;
		if (stat && TypeFunctions.hasMeta(":genericClassPerMethod", host.meta)) {
			target = genericMethodContainer(ctx, host, cf, params);
			name = cf.name;
		}
		var fields = stat ? target.statics : target.fields;
		var ordered = stat ? target.orderedStatics : target.orderedFields;
		var cf2 = fields.get(name);
		if (cf2 == null) {
			function subst(t:T):T return substituteGenericMethodType(cf.params, params, t);
			// Cf2's type from fcc.fc_type, which keeps the host class type parameters symbolic in the
			// argument types (only the method params and the return mono are resolved). The specialization
			// is shared across every instantiation of the host, so an argument typed by a class param must
			// stay generic (T, erased to Dynamic in codegen), never bound to one call site's argument type.
			// Taking the whole call type would bind such a param (T -> Int), which then mismatches the
			// cloned body's symbolic argument var and forces a _tmp_ rename in fix_override. So take the
			// argument types from the raw field signature and only the return type from the inferred call.
			var sigType = {
				var callFun = TypeFunctions.follow(resolveGenericMonos(subst(callType)));
				var rawFun = TypeFunctions.follow(cf.type);
				switch [callFun, rawFun] {
					case [TFun(cs), TFun(rs)] if (cs.args.length == rs.args.length):
						TFun({args: [for (i in 0...rs.args.length) {name: cs.args[i].name, opt: cs.args[i].opt, t: subst(rs.args[i].t)}], ret: cs.ret});
					case _:
						resolveGenericMonos(subst(callType));
				}
			};
			cf2 = TypeFunctions.mkField(name, sigType, cf.pos, cf.namePos, TypeFunctions.hasClassFieldFlag(cf, CfPublic), stat);
			cf2.doc = cf.doc;
			cf2.meta = cf.meta;
			cf2.kind = cf.kind;
			cf2.expr = Typeload.cloneExpr(cf.expr, subst, new Map());
			cf2.exprUnoptimized = cf.exprUnoptimized == null ? null : Typeload.cloneExpr(cf.exprUnoptimized, subst, new Map());
			cf2.flags = cf.flags;
			TypeFunctions.removeClassFieldFlag(cf2, CfGeneric);
			if (stat) TypeFunctions.addClassFieldFlag(cf2, CfStatic);
			else TypeFunctions.removeClassFieldFlag(cf2, CfStatic);
			fields.set(name, cf2);
			ordered.unshift(cf2);
		}
		if (target != host)
			return FieldAccessTools.create(TexprTools.makeStaticThis(target, fa.pos), cf2, FHStatic(target), fa.isInline, fa.pos);
		return FieldAccessTools.create(fa.on, cf2, fa.host, fa.isInline, fa.pos);
	}

	// Find or create the module-level container class for one @:genericClassPerMethod method
	// specialization.
	static function genericMethodContainer(ctx:TyperContext, host:TClass, cf:TClassField, params:TParams):TClass {
		var path = {pack: host.path.pack.copy(), name: host.path.name + "_" + cf.name + "_" + genericSuffix(params)};
		var key = hxc.context.Context.pathKey(path);
		var existing = ctx.com.moduleLut.get(key);
		if (existing != null) {
			for (mt in existing.types) switch (mt) {
				case TClassDecl(cg): return cg;
				case _:
			}
		}
		var mg = new ModuleDef(TypeFunctions.allocMid(), path, [], null, TypeFunctions.moduleExtra("", "", 0.0, MFake, []));
		mg.extra.processed = 2;
		var cg = TypeFunctions.mkClass(mg, path, host.pos, host.namePos);
		cg.build = function():BuildState return Built;
		cg.module = mg;
		mg.types = [TClassDecl(cg)];
		ctx.com.modules.push(mg);
		ctx.com.types.push(TClassDecl(cg));
		ctx.com.moduleLut.set(key, mg);
		ctx.com.typeToModule.set(key, path);
		TypeFunctions.addDependency(mg, host.module);
		return cg;
	}

	static function propagateGenericConstraints(ctx:TyperContext, cparams:TypeParams, monos:TParams, ?hostMap:T->T):Void {
		for (i in 0...cparams.length) {
			if (i >= monos.length) break;
			var actual = TypeFunctions.follow(monos[i]);
			switch (actual) {
				case TMono(r) if (r.type == null):
					continue;
				case _:
			}
			switch (TypeFunctions.follow(cparams[i].type)) {
				case TInst(c, _):
					switch (c.kind) {
						case KTypeParameter(constr):
							for (ct in constr) {
								// The host's class parameters apply to the constraint like they do to the
								// signature, so a constraint naming a class parameter checks the actual type.
								var expected = applyGenericConstraintParams(cparams, monos, hostMap != null ? hostMap(ct) : ct);
								try {
									TypeUnification.unifyDefault(actual, expected);
									if (TypeFunctions.hasMono(expected)) {
										try {
											unifyIteratorConstraint(ctx, actual, expected);
										} catch (_:UnifyError) {}
									}
								} catch (e:UnifyError) {
									if (!unifyIteratorConstraint(ctx, actual, expected)) throw e;
								}
							}
						case _:
					}
				case _:
			}
		}
	}

	static function applyGenericConstraintParams(cparams:TypeParams, monos:TParams, t:T):T {
		function typeParamHit(t:T):Null<T> {
			switch (TypeFunctions.follow(t)) {
				case TInst(c, []):
					for (i in 0...cparams.length) if (i < monos.length) {
						switch (TypeFunctions.follow(cparams[i].type)) {
							case TInst(pc, []) if (sameTypeParam(c, pc)):
								return monos[i];
							case _:
						}
					}
					return null;
				case _:
					return null;
			}
		}
		function loop(t:T):T {
			var hit = typeParamHit(t);
			if (hit != null) return hit;
			return switch (t) {
				case TMono(r):
					switch (r.type) {
						case null: t;
						case some: loop(some);
					}
				case TEnum(e, tl):
					TEnum(e, [for (x in tl) loop(x)]);
				case TInst(c, tl):
					TInst(c, [for (x in tl) loop(x)]);
				case TAbstract(a, tl):
					TAbstract(a, [for (x in tl) loop(x)]);
				case TType(td, tl):
					loop(TypeFunctions.applyTypedef(td, [for (x in tl) loop(x)]));
				case TFun(sig):
					TFun({args: [for (arg in sig.args) {name: arg.name, opt: arg.opt, t: loop(arg.t)}], ret: loop(sig.ret)});
				case TAnon(an):
					var fields = new haxe.ds.StringMap<TClassField>();
					for (name in an.fields.keys()) {
						var f = TypeFunctions.copyField(an.fields.get(name));
						f.type = loop(f.type);
						fields.set(name, f);
					}
					TypeFunctions.mkAnon(an.status, fields);
				case TLazy(f):
					loop(TypeFunctions.lazyType(f));
				case TDynamic(null):
					t;
				case TDynamic(t2):
					TDynamic(loop(t2));
			}
		}
		return loop(t);
	}

	static function sameTypeParam(c:TClass, pc:TClass):Bool {
		if (c == pc) return true;
		return switch [c.kind, pc.kind] {
			case [KTypeParameter(_), KTypeParameter(_)]:
				c.path.name == pc.path.name
					&& c.path.pack.length == pc.path.pack.length
					&& {
						var same = true;
						for (i in 0...c.path.pack.length) if (c.path.pack[i] != pc.path.pack[i]) {
							same = false;
							break;
						}
						same;
					};
			case _:
				false;
		}
	}

	static function unifyIteratorConstraint(ctx:TyperContext, actual:T, expected:T):Bool {
		var actualNext = iteratorNextType(ctx, actual);
		var expectedNext = iteratorNextType(ctx, expected);
		if (actualNext == null || expectedNext == null) return false;
		TypeUnification.unifyDefault(actualNext, expectedNext);
		return true;
	}

	static function iteratorNextType(ctx:TyperContext, t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, tl):
				c.build();
				var r = try TypeFunctions.classField(c, tl, "next") catch (_:hxc.core.NotFound) return null;
				switch (r.c2) {
					case null:
					case cwp: TypeFields.forceFieldBody(ctx.com, cwp.c, r.f);
				}
				r = try TypeFunctions.classField(c, tl, "next") catch (_:hxc.core.NotFound) return null;
				switch (TypeFunctions.follow(r.t)) {
					case TFun(sig) if (sig.args.length == 0): sig.ret;
					case _: null;
				}
			case TAnon(an):
				if (!an.fields.exists("next") || !an.fields.exists("hasNext")) return null;
				var next = an.fields.get("next");
				switch (TypeFunctions.follow(next.type)) {
					case TFun(sig) if (sig.args.length == 0): sig.ret;
					case _: null;
				}
			case _:
				null;
		}
	}

	static function closeGenericMonos(monos:TParams):Void {
		for (m in monos) switch (TypeFunctions.follow(m)) {
			case TMono(r): TypeUnification.close(r);
			case _:
		}
	}

	static function substituteGenericMethodType(cparams:TypeParams, params:TParams, t:T):T {
		return resolveGenericMonos(TypeFunctions.applyParams(cparams, params, t));
	}

	static function resolveGenericMonos(t:T):T {
		// Flattens bound monos to their targets so the clone shares nothing with the call site, but keeps
		// the type structure itself: dispatching on follow(t) here would strip Null<...> wrappers and
		// expand typedefs (the substitution maps structurally).
		return switch (t) {
			case TMono(r):
				switch (r.type) { case null: t; case some: resolveGenericMonos(some); }
			case TFun(sig):
				TFun({args: [for (a in sig.args) {name: a.name, opt: a.opt, t: resolveGenericMonos(a.t)}], ret: resolveGenericMonos(sig.ret)});
			case TInst(c, params):
				TInst(c, [for (p in params) resolveGenericMonos(p)]);
			case TEnum(e, params):
				TEnum(e, [for (p in params) resolveGenericMonos(p)]);
			case TAbstract(a, params):
				TAbstract(a, [for (p in params) resolveGenericMonos(p)]);
			case TType(td, params):
				TType(td, [for (p in params) resolveGenericMonos(p)]);
			case TDynamic(t2):
				TDynamic(t2 == null ? null : resolveGenericMonos(t2));
			case TLazy(f):
				resolveGenericMonos(TypeFunctions.lazyType(f));
			case _:
				t;
		}
	}

	// Name each top-level type parameter through loop(true).
	static function genericSuffix(params:TParams):String {
		return [for (p in params) genericLoop(true, p)].join("_");
	}

	// An unsafe character spells _<charcode>_
	static function identSafe(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			var ok = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code) || c == "_".code;
			if (ok) b.addChar(c) else b.add("_" + c + "_");
		}
		return b.toString();
	}

	// The type path with its package joined by underscores.
	static function pathUnderscore(path:hxc.core.Globals.Path):String {
		return path == null ? "T" : (path.pack.length == 0 ? path.name : path.pack.join("_") + "_" + path.name);
	}

	static var genericPartDepth = 0;

	// The raw type names the part (no eager follow), so a typedef parameter keeps its typedef path
	// (Issue7985 gen_..._Rec); only a non-top unknown degrades to "_" through follow_or, and Dynamic
	// spells "Dynamic" only at top.
	static function genericLoop(top:Bool, t:T):String {
		// Recursive structures would loop forever; past a sane depth the part degrades to "_"
		// (hxc guard; the reference cannot recurse here because typedefs stop unfollowed).
		if (genericPartDepth > 10) return "_";
		genericPartDepth++;
		var r = switch (t) {
			case TInst(c, tl):
				switch (c.kind) {
					case KExpr(e): identSafe(hxc.ast.Ast.Printer.sExpr(e));
					case _: identSafe(pathUnderscore(c.path)) + genericLoopTl(top, tl);
				}
			case TType(td, tl): pathUnderscore(td.path) + genericLoopTl(top, tl);
			case TEnum(en, tl): pathUnderscore(en.path) + genericLoopTl(top, tl);
			case TAnon(an):
				var names = [for (n in an.fields.keys()) n];
				names.sort(function(x, y) return x < y ? 1 : (x > y ? -1 : 0));
				"anon_" + [for (n in names) n + "_" + genericLoop(false, TypeFunctions.follow(an.fields.get(n).type))].join("_");
			case TFun(sig): "func_" + [for (a in sig.args) genericLoop(false, a.t)].join("_") + "_" + genericLoop(false, sig.ret);
			case TAbstract(a, tl): pathUnderscore(a.path) + genericLoopTl(top, tl);
			case _ if (!top): genericFollowOr(t, top, function() return "_");
			case TMono(r) if (r.type == null):
				genericPartDepth--;
				throw new TypingError("Could not determine type for parameter", Position.nullPos);
			case TDynamic(_): "Dynamic";
			case _: genericFollowOr(t, top, function():String {
				genericPartDepth--;
				throw new TypingError("Unsupported type parameter", Position.nullPos);
			});
		};
		genericPartDepth--;
		return r;
	}

	static function genericLoopTl(top:Bool, tl:TParams):String {
		return tl.length == 0 ? "" : "_" + [for (t in tl) genericLoop(top, t)].join("_");
	}

	// Resolve one step; an unresolvable type takes the fallback.
	static function genericFollowOr(t:T, top:Bool, orFn:Void->String):String {
		var ft = TypeFunctions.followOnce(t);
		return ft == t ? orFn() : genericLoop(top, ft);
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

	static function callExpr(ctx:TyperContext, ce0:TExpr, el:Array<Expr>, p:Position, forceInline = false, forcePos:Null<Position> = null):TExpr {
		var ce = monomorphizeLocalParams(ctx, ce0);
		return switch (TypeFunctions.follow(ce.type)) {
			case TFun(sig):
				var r = unifyCallArgs(ctx, el, sig.args, sig.ret, p);
				if (DebugDump.enabled("select", p))
					DebugDump.selected("call", p, "function -> " + DebugDump.typeString(sig.ret));
				makeCall(ctx, ce, r.el, sig.ret, p, forceInline, forcePos);
			case TMono(_):
				var args = [for (e in el) Typer.typeExpr(ctx, e, WithTypeTools.value)];
				var ret = TypeFunctions.mkMono();
				// The mono callee binds to a function of the typed argument types, so later passes see a
				// TFun and
				// the analyzer keeps a field access on its receiver.
				TypeUnification.unifyDefault(TFun({args: [for (a in args) {name: "", opt: false, t: a.type}], ret: ret}), ce.type);
				DebugDump.selected("call", p, "mono function");
				makeCall(ctx, ce, args, ret, p, forceInline, forcePos);
			case TDynamic(_):
				var args = [for (e in el) Typer.typeExpr(ctx, e, WithTypeTools.value)];
				DebugDump.selected("call", p, "dynamic function");
				makeCall(ctx, ce, args, TDynamic(null), p, forceInline, forcePos);
			case TAbstract(a, tl) if (a.call != null && a.impl != null):
				// @:op(a()) call operator: dispatch to the impl call field with the abstract value as its
				// first
				// (`this`) argument.
				// Force the call method's body so an inferred return settles from the body before this call
				// unifies it with the expected type.
				if (a.call.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx.com, a.impl, a.call);
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
				// Untyped code may call any value; the result is dynamic under ctx.untyped)
				if (ctx.untypedMode) {
					var args = [for (e in el) Typer.typeExpr(ctx, e, WithTypeTools.value)];
					makeCall(ctx, ce, args, TDynamic(null), p);
				} else
					throw new TypingError("Cannot call a non-function value", p);
		};
	}
}
