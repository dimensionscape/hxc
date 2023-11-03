package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.NotFound;
import hxc.core.TypingError;
import hxc.core.TexprTools;
import hxc.core.WithType;
import hxc.debug.DebugDump;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;
import hxc.typing.Matcher.Match;
import hxc.typing.TyperContext.CurrentFun;
import hxc.typing.Typeload;

class Typer {

	// A fresh mono, recorded in the per-function list.
	public static function spawnMonomorph(ctx:TyperContext, p:Position):T {
		var mono = TypeUnification.monoCreate();
		ctx.monomorphs.unshift({m: mono, p: p}); // Prepends (newest first)
		return TMono(mono);
	}

	public static function saveLocals(ctx:TyperContext):Void->Void {
		var saved = ctx.locals.copy();
		return function() ctx.locals = saved;
	}

	public static function addLocal(ctx:TyperContext, k:TVarKind, n:String, t:T, p:Position):TVar {
		var v = TypeFunctions.allocVar(k, n, t, p);
		ctx.locals.set(n, v);
		return v;
	}

	public static function addLocalWithOrigin(ctx:TyperContext, origin:TVarOrigin, n:String, t:T, p:Position):TVar {
		return addLocal(ctx, VUser(origin), n, t, p);
	}

	public static function monoOrDynamic(ctx:TyperContext, withType:WithType, p:Position):T {
		return switch (withType) {
			case NoValue: TDynamic(null);
			case Value(_) | WithType(_, _): spawnMonomorph(ctx, p);
		};
	}

	public static function castOrUnify(ctx:TyperContext, t:T, e:TExpr, p:Position):TExpr {
		if (TypeUnification.fastEq(e.type, t)) return e;
		// The cast-field search runs before plain unification: its strict first pass can pick a @:from
		// whose parameter matches exactly even when the value would also unify with a plain `from` type.
		if (!TypeUnification.typeIseqDefault(t, e.type)) {
			var casted = tryAbstractCast(ctx, e, t, p);
			if (casted != null) return casted;
		} else return e;
		var uerr:Array<hxc.core.TypeUnification.UnifyErrorKind> = null;
		try {
			TypeUnification.unifyDefault(e.type, t);
			return e;
		} catch (ue:UnifyError) { uerr = ue.errors; }
		// Untyped code swallows the unification failure and keeps the value
		if (ctx.untypedMode) return e;
		throw new TypingError(hxc.core.TPrinting.betterErrorMessage(uerr), p);
	}

	static function doesUnify(a:T, b:T):Bool {
		return try { TypeUnification.unifyDefault(a, b); true; } catch (_:UnifyError) false;
	}

	static function prefersAbstractCast(from:T, to:T):Bool {
		return switch [TypeFunctions.follow(from), TypeFunctions.follow(to)] {
			case [TAbstract(a, tl), _] if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				hasDirectToCast(a, tl, to);
			case _:
				false;
		}
	}

	static function hasDirectToCast(a:TAbstract, tl:Array<T>, to:T):Bool {
		for (castField in a.toField) {
			var castType = TypeFunctions.applyParams(a.params, tl, castField.t);
			if (sameDirectCastTarget(castType, to)) return true;
		}
		return false;
	}

	static function sameDirectCastTarget(a:T, b:T):Bool {
		return switch [TypeFunctions.follow(a), TypeFunctions.follow(b)] {
			case [TDynamic(_), TDynamic(_)]:
				true;
			case [TAbstract(a1, _), TAbstract(a2, _)]:
				a1 == a2;
			case [TInst(c1, _), TInst(c2, _)]:
				c1 == c2;
			case [TEnum(e1, _), TEnum(e2, _)]:
				e1 == e2;
			case _:
				false;
		}
	}

	// Implicit abstract conversion. The search is recursive: a declarative from/to type can expose a nested
	// runtime cast field.
	static function tryAbstractCast(ctx:TyperContext, e:TExpr, t:T, p:Position):Null<TExpr> {
		try return abstractCastLoop(ctx, e, t, e.type, [], p) catch (_:NotFound) return null;
	}

	static function abstractCastLoop(ctx:TyperContext, e:TExpr, tleft:T, tright:T, stack:Array<{l:T, r:T}>, p:Position):TExpr {
		for (s in stack)
			if (TypeUnification.fastEq(tleft, s.l) && TypeUnification.fastEq(tright, s.r))
				throw new NotFound();
		var stack2 = [{l: tleft, r: tright}].concat(stack);
		var uctx = TypeUnification.defaultUnificationContext;
		switch [TypeFunctions.follow(tleft), TypeFunctions.follow(tright)] {
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)]:
				var found = TypeUnification.findToFrom(uctx, e.type, tleft, a2, tl2, a1, tl1);
				if (found == null) throw new NotFound();
				return makeAbstractCast(ctx, found.a, found.tl, found.castField, e, tleft, p);
			case [TAbstract(a, tl), _]:
				try {
					return makeAbstractCast(ctx, a, tl, TypeUnification.findFrom(uctx, e.type, a, tl), e, tleft, p);
				} catch (_:NotFound) {
					for (tc in a.from) {
						var tnext = TypeFunctions.applyParams(a.params, tl, tc);
						if (!TypeUnification.typeIseqDefault(tnext, tleft))
							return abstractCastLoop(ctx, e, tnext, tright, stack2, p);
					}
					throw new NotFound();
				}
			case [_, TAbstract(a, tl)]:
				try {
					return makeAbstractCast(ctx, a, tl, TypeUnification.findTo(uctx, tleft, a, tl), e, tleft, p);
				} catch (_:NotFound) {
					for (tc in a.to) {
						var tnext = TypeFunctions.applyParams(a.params, tl, tc);
						if (!TypeUnification.typeIseqDefault(tnext, tright))
							return abstractCastLoop(ctx, e, tleft, tnext, stack2, p);
					}
					throw new NotFound();
				}
			case _:
				throw new NotFound();
		}
	}

	static function makeAbstractCast(ctx:TyperContext, a:TAbstract, tl:Array<T>, castField:TAbstractCast, e:TExpr, t:T, p:Position):TExpr {
		if (TypeFunctions.hasMeta(":multiType", castField.cf.meta)) return TypeFunctions.mk(TCast(e, null), t, p);
		if (a.path.pack.length == 0 && a.path.name == "Any" && castField.cf.name == "__promote") return TypeFunctions.mk(TCast(e, null), t, p);
		if (TypeFunctions.hasClassFieldFlag(castField.cf, CfExtern)) return TypeFunctions.mk(TCast(e, null), t, p);
		if (a.impl == null) throw new NotFound();
		return callImplCast(ctx, a.impl, castField.cf, e, t, p);
	}

	// A trailing optional ?p:haxe.PosInfos on a cast method receives the call-site info.
	static function castArgs(ctx:TyperContext, cf:TClassField, e:TExpr, p:Position):Array<TExpr> {
		return switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): Calls.padPosInfos(ctx, sig.args, [e], p);
			case _: [e];
		};
	}

	static function callImplCast(ctx:TyperContext, implC:TClass, cf:TClassField, e:TExpr, t:T, p:Position):TExpr {
		if (hxc.eval.EvalMacro.isMacroField(cf)) return callMacroCast(ctx, implC, cf, e, t, p);
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), p);
		var staticExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p), FCall);
		return Calls.makeCall(ctx, staticExpr, castArgs(ctx, cf, e, p), t, p);
	}

	static function callImplCastDirect(ctx:TyperContext, implC:TClass, cf:TClassField, e:TExpr, t:T, p:Position):TExpr {
		if (hxc.eval.EvalMacro.isMacroField(cf)) return callMacroCast(ctx, implC, cf, e, t, p);
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), p);
		var staticExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p), FCall);
		return TypeFunctions.mk(TCall(staticExpr, castArgs(ctx, cf, e, p)), t, p);
	}

	static function callMacroCast(ctx:TyperContext, implC:TClass, cf:TClassField, e:TExpr, t:T, p:Position):TExpr {
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), p);
		var fa = FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p);
		return castOrUnify(ctx, t, hxc.eval.EvalMacro.run(ctx, fa, [Calls.typedExprToSyntax(ctx, e)], WithTypeTools.withType(t), p), p);
	}

	static function isVoid(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	static function defaultCatchTypeHint(p:Position):TypeHint {
		return {
			ct: CTPath({tpackage: ["haxe"], tname: "Exception", tparams: [], tsub: null}),
			pos: p
		};
	}

	static function isDynamic(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TDynamic(_): true;
			case _: false;
		}
	}

	static function checkCatchTypeParams(params:TParams, p:Position):Void {
		for (pt in params) switch (TypeFunctions.followWithAbstracts(pt)) {
			case TDynamic(_):
			case _: throw new TypingError("Catch class parameter must be Dynamic", p);
		}
	}

	static function isGenericCatchParameter(ctx:TyperContext, c:TClass):Bool {
		if (!TypeFunctions.hasClassFieldFlag(ctx.curfield, CfGeneric)) return false;
		for (tp in ctx.curfield.params) switch (TypeFunctions.follow(tp.type)) {
			case TInst(c2, _) if (c2 == c):
				return true;
			case _:
		}
		return false;
	}

	// A type param is constructible if a constraint exposes a `new` field, is haxe.Constructible<T>, or
	// nests another constructible type param.
	static function getConstructibleConstraint(ctx:TyperContext, tl:Array<T>, p:Position):Null<TSignature> {
		function extractFunction(t:T):TSignature {
			return switch (TypeFunctions.follow(t)) {
				case TFun(sig): sig;
				case _: throw new TypingError("Constructible type parameter should be function", p);
			};
		}
		function loop(tl:Array<T>):Null<TSignature> {
			for (t in tl) switch (TypeFunctions.follow(t)) {
				case TAnon(a):
					var nf = a.fields.get("new");
					if (nf != null) return extractFunction(nf.type);
				case TAbstract(a, [t1]) if (a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Constructible"):
					return extractFunction(t1);
				case TInst(c, _) if (c.kind.match(KTypeParameter(_))):
					var tl1 = switch (c.kind) { case KTypeParameter(x): x; case _: []; };
					var r = loop(tl1);
					if (r != null) return r;
				case _:
			}
			return null;
		}
		return loop(tl);
	}

	static function isGenericParameter(ctx:TyperContext, c:TClass):Bool {
		if (ctx.curclass != null) {
			switch (ctx.curclass.kind) {
				case KGeneric:
					for (tp in ctx.curclass.params) switch (TypeFunctions.follow(tp.type)) {
						case TInst(c2, _) if (c2 == c): return true;
						case _:
					}
				case _:
			}
		}
		if (ctx.curfield != null && TypeFunctions.hasClassFieldFlag(ctx.curfield, CfGeneric)) {
			for (tp in ctx.curfield.params) switch (TypeFunctions.follow(tp.type)) {
				case TInst(c2, _) if (c2 == c): return true;
				case _:
			}
		}
		return false;
	}

	static function normalizeCatchType(ctx:TyperContext, t:T, p:Position):T {
		function loop(t:T):T {
			return switch (TypeFunctions.follow(t)) {
				case TInst(c, _) if (c.kind.match(KTypeParameter(_)) && !isGenericCatchParameter(ctx, c)):
					throw new TypingError("Cannot catch non-generic type parameter", p);
				case TInst(_, params) | TEnum(_, params):
					checkCatchTypeParams(params, p);
					t;
				case TAbstract(a, params) if (TypeFunctions.hasMeta(":runtimeValue", a.meta)):
					checkCatchTypeParams(params, p);
					t;
				case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
					loop(TypeFunctions.getUnderlyingType(a, tl));
				case TDynamic(_):
					t;
				case _:
					throw new TypingError("Catch type must be a class, an enum or Dynamic", p);
			}
		}
		return loop(t);
	}

	static function checkCatchUnreachable(prev:Array<TCatch>, t:T, p:Position):Void {
		for (c in prev) {
			if (isDynamic(c.v.type)) throw new TypingError("This block is unreachable", p);
			if (!isDynamic(t)) {
				try {
					TypeUnification.unifyDefault(t, c.v.type);
					throw new TypingError("This block is unreachable", p);
				} catch (_:UnifyError) {}
			}
		}
	}

	// The compile-time value of a single-character string's `.code`. A host string is UTF-16 here, so a
	// character outside the BMP is a surrogate pair (two units) that combines into its codepoint. Returns
	// null when the literal is not exactly one codepoint, letting normal field access report the error.
	static function singleCodePoint(s:String):Null<Int> {
		if (s.length == 1) return s.charCodeAt(0);
		if (s.length == 2) {
			var hi = s.charCodeAt(0);
			var lo = s.charCodeAt(1);
			if (hi >= 0xD800 && hi <= 0xDBFF && lo >= 0xDC00 && lo <= 0xDFFF)
				return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
		}
		return null;
	}

	public static function unifyMinRaise(ctx:TyperContext, el:Array<TExpr>):T {
		var basic = ctx.com.basic;
		if (el.length == 0) return spawnMonomorph(ctx, Position.nullPos);
		if (el.length == 1) return el[0].type;

		function chkNull(e:TExpr):Bool {
			if (TypeFunctions.isNull(e.type) || TypeFunctions.isExplicitNull(e.type)) return true;
			return switch (e.expr) {
				case TConst(TNull): true;
				case TBlock(el2): el2.length == 0 ? false : chkNull(el2[el2.length - 1]);
				case TParenthesis(e2): chkNull(e2);
				case TMeta(_, e2): chkNull(e2);
				case _: false;
			};
		}

		var t = spawnMonomorph(ctx, Position.nullPos);
		var hasError = false;
		for (e in el) {
			if (chkNull(e)) t = basic.tnull(t);
			try {
				TypeUnification.unifyDefault(e.type, t);
			} catch (_:UnifyError) {
				try {
					TypeUnification.unifyDefault(t, e.type);
					t = TypeFunctions.isNull(t) ? basic.tnull(e.type) : e.type;
				} catch (_:UnifyError) {
					hasError = true;
					break;
				}
			}
		}
		if (!hasError) return t;

		var anonMin = unifyMinConstAnon(ctx, el);
		if (anonMin != null) return anonMin;

		var funMin = unifyMinFun(el);
		if (funMin != null) return funMin;

		var commonTypes = TypeUnification.collectBaseTypes(t);
		var dynTypes = [];
		for (ty in commonTypes) {
			switch (ty) {
				case TInst(c, params) if (params.length > 0 && hasUnifyMinDynamic(c)):
					dynTypes.push(TInst(c, [for (_ in params) TDynamic(null)]));
				case _:
			}
		}
		dynTypes.reverse();
		if (dynTypes.length > 0) commonTypes = commonTypes.concat(dynTypes);
		var elTail = el.slice(1);
		var tl = [for (e in elTail) e.type];
		return switch (TypeUnification.unify_min_(TypeUnification.defaultUnificationContext, commonTypes, tl)) {
			case UnifyMinOk(t2): t2;
			case UnifyMinError(l, index):
				throw new TypingError("Cannot find a common type for the given expressions", elTail[index].pos);
		};
	}

	static function unifyMinConstAnon(ctx:TyperContext, el:Array<TExpr>):Null<T> {
		var fieldsByExpr:Array<haxe.ds.StringMap<TExpr>> = [];
		var fieldNames:Array<String> = [];
		var fieldCount = -1;
		for (e in el) {
			switch [TypeFunctions.follow(e.type), e.expr] {
				case [TAnon(a), TObjectDecl(fields)] if (a.status.get().match(Const)):
					var map = new haxe.ds.StringMap<TExpr>();
					for (f in fields) map.set(f.key.name, f.expr);
					var count = 0;
					for (_ in map.keys()) count++;
					if (fieldCount == -1) {
						fieldCount = count;
						for (n in map.keys()) fieldNames.push(n);
					} else if (fieldCount != count) {
						return null;
					}
					for (n in fieldNames) if (!map.exists(n)) return null;
					fieldsByExpr.push(map);
				case _:
					return null;
			}
		}
		var fields = new haxe.ds.StringMap<TClassField>();
		for (n in fieldNames) {
			var exprs = [for (m in fieldsByExpr) m.get(n)];
			var ft = try unifyMinRaise(ctx, exprs) catch (_:TypingError) return null;
			fields.set(n, TypeFunctions.mkField(n, ft, exprs[0].pos, Position.nullPos));
		}
		return TypeFunctions.mkAnon(new hxc.core.Ref(Closed), fields);
	}

	// Common type of function values: per argument keep the type every other argument type unifies into
	// (contravariance), and unify-min the returns.
	static function unifyMinFun(el:Array<TExpr>):Null<T> {
		var args:Array<TSignatureArg>;
		var tr0:T;
		switch (TypeFunctions.follow(el[0].type)) {
			case TFun(sig): args = sig.args.copy(); tr0 = sig.ret;
			case _: return null;
		}
		var rets:Array<T> = [];
		for (i in 1...el.length) {
			switch (TypeFunctions.follow(el[i].type)) {
				case TFun(sig):
					if (sig.args.length != args.length) return null;
					for (j in 0...args.length) {
						var tcur = args[j].t;
						var argnew = sig.args[j];
						if (TypeUnification.doesUnify(argnew.t, tcur)) args[j] = argnew;
						else if (!TypeUnification.doesUnify(tcur, argnew.t)) return null;
					}
					rets.push(sig.ret);
				case _: return null;
			}
		}
		var commonTypes = TypeUnification.collectBaseTypes(tr0);
		return switch (TypeUnification.unify_min_(TypeUnification.defaultUnificationContext, commonTypes, rets)) {
			case UnifyMinOk(tr): TFun({args: args, ret: tr});
			case UnifyMinError(_, _): null;
		};
	}

	static function hasUnifyMinDynamic(c:TClass):Bool {
		if (TypeFunctions.hasMeta(":unifyMinDynamic", c.meta)) return true;
		return switch (c.superClass) {
			case null: false;
			case s: hasUnifyMinDynamic(s.c);
		};
	}

	public static function unifyMin(ctx:TyperContext, el:Array<TExpr>):T {
		return try unifyMinRaise(ctx, el) catch (_:TypingError) el[0].type;
	}

	public static function unifyMinForTypeSource(ctx:TyperContext, el:Array<TExpr>, src:Null<WithTypeSource>):T {
		return switch (src) {
			case ImplicitReturn if (Lambda.exists(el, function(e) return isVoid(e.type))):
				ctx.com.basic.tvoid;
			case _: unifyMin(ctx, el);
		};
	}

	static function arrayElementFromType(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, [et]) if (c.path.pack.length == 0 && c.path.name == "Array"):
				switch (TypeFunctions.follow(et)) {
					case TMono(_): null;
					case _: et;
				}
			case _:
				null;
		}
	}

	static function expectedArrayElement(ctx:TyperContext, t:T):Null<T> {
		function loop(seen:Array<T>, t:T):Null<T> {
			t = TypeFunctions.follow(t);
			var direct = arrayElementFromType(t);
			if (direct != null) return direct;
			return switch (t) {
				case TAbstract(a, tl):
					for (seenT in seen) if (TypeUnification.fastEq(seenT, t)) return null;
					var hits:Array<T> = [];
					function addHit(ft:T):Void {
						var et = loop(seen.concat([t]), ft);
						if (et != null) hits.push(et);
					}
					for (ft in a.from) addHit(TypeFunctions.applyParams(a.params, tl, ft));
					for (fc in a.fromField) {
						switch (TypeFunctions.follow(fc.cf.type)) {
							case TFun(sig) if (sig.args.length > 0):
								var monos = [for (_ in fc.cf.params) TypeFunctions.mkMono()];
								function map(x:T):T return TypeFunctions.applyParams(a.params, tl, TypeFunctions.applyParams(fc.cf.params, monos, x));
								try {
									TypeUnification.unifyDefault(map(sig.ret), t);
									addHit(map(sig.args[0].t));
								} catch (_:UnifyError) {}
							case _:
						}
					}
					hits.length == 1 ? hits[0] : null;
				case TDynamic(_):
					t;
				case _:
					null;
			}
		}
		return loop([], t);
	}

	static function abstractFromTypes(ctx:TyperContext, t:T):Array<T> {
		t = TypeFunctions.follow(t);
		return switch (t) {
			case TAbstract(a, tl):
				var hits:Array<T> = [];
				for (ft in a.from) hits.push(TypeFunctions.applyParams(a.params, tl, ft));
				for (fc in a.fromField) {
					switch (TypeFunctions.follow(fc.cf.type)) {
						case TFun(sig) if (sig.args.length == 1):
							var monos = [for (_ in fc.cf.params) TypeFunctions.mkMono()];
							function map(x:T):T return TypeFunctions.applyParams(a.params, tl, TypeFunctions.applyParams(fc.cf.params, monos, x));
							try {
								TypeUnification.unifyDefault(map(sig.ret), t);
								hits.push(map(sig.args[0].t));
							} catch (_:UnifyError) {}
						case _:
					}
				}
				hits;
			case _:
				[];
		}
	}

	public static function typeExpr(ctx:TyperContext, e:Expr, withType:WithType, ?mode:AccessMode):TExpr {
		if (mode == null) mode = MGet;
		var basic = ctx.com.basic;
		var p = e.pos;
		var typed = switch (e.expr) {
			case EConst(c): typeConst(ctx, c, p, mode, withType);
			case EParenthesis(e1):
				var te = typeExpr(ctx, e1, withType);
				TypeFunctions.mk(TParenthesis(te), te.type, te.pos);
			case EBlock([]) if (emptyBlockIsObject(withType)):
				// `{}` parses as an empty block; in a value position with a known (non-mono) type it is an
				// empty object literal, not a Void block.
				typeExpr(ctx, new Expr(EObjectDecl([]), p), withType);
			case EBlock(l):
				var restore = saveLocals(ctx);
				var te = typeBlock(ctx, l, withType, p);
				restore();
				te;
			case EVars(vl): typeVars(ctx, vl, p);
			case EIf(econd, e1, e2): typeIf(ctx, econd, e1, e2, withType, false, p);
			case ETernary(econd, e1, e2): typeIf(ctx, econd, e1, e2, withType, true, p);
			case EWhile(cond, body, NormalWhile):
				var oldLoop = ctx.inLoop;
				var c = castOrUnify(ctx, basic.tbool, typeExpr(ctx, cond, WithTypeTools.value), p);
				ctx.inLoop = true;
				var b = typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
				ctx.inLoop = oldLoop;
				TypeFunctions.mk(TWhile(c, b, NormalWhile), basic.tvoid, p);
			case EWhile(cond, body, DoWhile):
				var oldLoop = ctx.inLoop;
				ctx.inLoop = true;
				var b = typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
				ctx.inLoop = oldLoop;
				var c = typeExpr(ctx, cond, WithTypeTools.value);
				c = castOrUnify(ctx, basic.tbool, c, c.pos);
				TypeFunctions.mk(TWhile(c, b, DoWhile), basic.tvoid, p);
			case EReturn(re):
				if (!ctx.inFunction) throw new TypingError("Return outside function", p);
				typeReturn(ctx, re, withType, p);
			case EBreak:
				if (!ctx.inLoop) throw new TypingError("Break outside loop", p);
				TypeFunctions.mk(TBreak, monoOrDynamic(ctx, withType, p), p);
			case EContinue:
				if (!ctx.inLoop) throw new TypingError("Continue outside loop", p);
				TypeFunctions.mk(TContinue, monoOrDynamic(ctx, withType, p), p);
			case EThrow(e1):
				var te = typeExpr(ctx, e1, WithTypeTools.value);
				TypeFunctions.mk(TThrow(te), monoOrDynamic(ctx, withType, p), p);
			case EUntyped(e1):
				var old = ctx.untypedMode;
				ctx.untypedMode = true;
				var te = try typeExpr(ctx, e1, withType) catch (err:haxe.Exception) { ctx.untypedMode = old; throw err; }
				ctx.untypedMode = old;
				TypeFunctions.mk(te.expr, spawnMonomorph(ctx, te.pos), te.pos);
			case EMeta(m, e1) if (m.name == ":privateAccess"):
				ctx.privateAccess++;
				var rPriv = try typeExpr(ctx, e1, withType) catch (err:haxe.Exception) { ctx.privateAccess--; throw err; };
				ctx.privateAccess--;
				return rPriv;
			case EMeta(m, e1) if (m.name == ":noPrivateAccess"):
				// Strips any enclosing @:privateAccess for the subexpression.
				var oldPa = ctx.privateAccess;
				ctx.privateAccess = 0;
				var rNoPriv = try typeExpr(ctx, e1, withType) catch (err:haxe.Exception) { ctx.privateAccess = oldPa; throw err; };
				ctx.privateAccess = oldPa;
				return rNoPriv;
			case EMeta(m, e1) if (m.name == ":bypassAccessor"):
					// The next field access typed within e1 consumes this and becomes a raw access.
					var oldBypass = ctx.bypassAccessor;
					ctx.bypassAccessor = oldBypass + 1;
					var teBypass = try typeExpr(ctx, e1, withType) catch (err:haxe.Exception) { ctx.bypassAccessor = oldBypass; throw err; }
					ctx.bypassAccessor = oldBypass;
					teBypass;
			case EMeta(m, e1) if (m.name == ":mergeBlock"):
					// A @:mergeBlock block opens no scope; its declarations merge into the enclosing block.
					// Type the inner statements in the current scope and wrap them so the enclosing block
					// splices them (see typeBlock).
					switch (e1.expr) {
						case EBlock(el):
							var inner = typeBlock(ctx, el, withType, p);
							TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: p}, inner), inner.type, inner.pos);
						case _: typeExpr(ctx, e1, withType);
					}
				case EMeta(m, e1) if (m.name == ":storedTypedExpr"):
					var id = switch (e1.expr) {
						case EConst(CInt(s, _)): Std.parseInt(s);
						case _: null;
					}
					if (id == null || !ctx.com.storedTypedExprs.exists(id)) throw new TypingError("Unknown stored typed expression", p);
					// Fresh tvars on every retrieval so the expression does not share variable slots with
					// its original (macro-time) context; this rebinds to the enclosing context.
					TexprTools.duplicateTvars(function(te) {
						return ctx.tthis != null ? TypeFunctions.mk(TConst(TThis), ctx.tthis, te.pos) : te;
					}, ctx.com.storedTypedExprs.get(id));
				case EMeta(_, e1):
				typeExpr(ctx, e1, withType);
			case EField(_, _, _) | EArray(_, _) | ECall(_, _):
				accGet(ctx, typeAccess(ctx, e.expr, p, mode, withType));
			case EBinop(op, e1, e2):
				Operators.typeBinop(ctx, op, e1, e2, false, withType, p);
			case EUnop(op, flag, e1):
				Operators.typeUnop(ctx, op, flag, e1, withType, p);
			case ESwitch(e1, cases, def):
				Match.matchExpr(ctx, e1, cases, def, withType, false, p);
			case EFor(it, body):
				ForLoop.typeForLoop(ctx, it, body, p);
			case ENew(tp, el):
				typeNew(ctx, tp, el, withType, p);
			case EFunction(kind, f):
				var savedTypeParams = ctx.typeParams;
				var localParams:TypeParams = [];
				if (f.fParams.length > 0) {
					// A local function's own type parameters (`function foo<T>(...)`) are in scope for its
					// argument/return hints and body.
					var declPath:hxc.core.Globals.Path = {pack: [], name: switch (kind) { case FKNamed(n, _): n.name; case _: "`localfun"; }};
					for (tp in f.fParams) localParams.push(Typeload.typeTypeParam(ctx.com, declPath, () -> savedTypeParams.concat(localParams), tp));
					ctx.typeParams = savedTypeParams.concat(localParams);
				}
				var args:Array<TFuncArg> = [];
				for (fa in f.fArgs) {
					var at = Typeload.loadTypeHint(ctx.com, ctx.typeParams, fa.type, fa.opt);
					args.push({v: TypeFunctions.allocVar(VUser(TVOLocalVariable), fa.name.name, at, fa.name.pos), c: null});
				}
				var ret = Typeload.loadTypeHint(ctx.com, ctx.typeParams, f.fType, false);
				// Top-down inference: bind unannotated (mono) arg/return types from an expected function
				// type.
				function expectVoid(t:T):Bool {
					return switch (TypeFunctions.follow(t)) {
						case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
						case _: false;
					}
				}
				function maybeUnifyArg(t1:T, t2:T):Void {
					switch (TypeFunctions.follow(t1)) {
						case TMono(_): try TypeUnification.unifyDefault(t2, t1) catch (_:Dynamic) {}
						case _:
					}
				}
				function maybeUnifyRet(t2:T):Void {
					if (!expectVoid(t2)) switch (TypeFunctions.follow(ret)) {
						case TMono(_): try TypeUnification.unifyDefault(ret, t2) catch (_:Dynamic) {}
						case _:
					}
				}
				function applyFunExpectation(t:T):Bool {
					return switch (TypeFunctions.follow(t)) {
						case TFun(sig) if (sig.args.length == args.length):
							for (i in 0...args.length) maybeUnifyArg(args[i].v.type, sig.args[i].t);
							maybeUnifyRet(sig.ret);
							true;
						case _:
							false;
					}
				}
				function flattenAbstractSources(t:T, seen:Array<T>):Array<T> {
					t = TypeFunctions.follow(t);
					return switch (t) {
						case TAbstract(_, _):
							for (seenT in seen) if (TypeUnification.fastEq(seenT, t)) return [];
							var sources = abstractFromTypes(ctx, t);
							if (sources.length == 1) flattenAbstractSources(sources[0], seen.concat([t])) else {
								var out:Array<T> = [];
								for (source in sources) switch (TypeFunctions.follow(source)) {
									case TAbstract(_, _): out = out.concat(flattenAbstractSources(source, seen.concat([t])));
									case _: out.push(source);
								}
								out;
							}
						case _:
							[t];
					}
				}
				function commonType(types:Array<T>):Null<T> {
					if (types.length == 0) return null;
					var first = types[0];
					for (i in 1...types.length) if (!TypeUnification.typeIseqDefault(first, types[i])) return null;
					return first;
				}
				function applyAbstractFunctionMatrix(t:T):Void {
					var candidates = [for (source in flattenAbstractSources(t, [])) switch (TypeFunctions.follow(source)) {
						case TFun(sig) if (sig.args.length == args.length): sig;
						case _: null;
					}].filter(x -> x != null);
					if (candidates.length == 0) return;
					for (i in 0...args.length) {
						var t = commonType([for (sig in candidates) sig.args[i].t]);
						if (t != null) maybeUnifyArg(args[i].v.type, t);
					}
					var rt = commonType([for (sig in candidates) sig.ret]);
					if (rt != null) maybeUnifyRet(rt);
				}
				switch (withType) {
					case WithType(wt, _):
						if (!applyFunExpectation(wt)) applyAbstractFunctionMatrix(wt);
					case _:
				}
				// An arg is optional in the function type when marked `?` or given a default value.
				var ft = TFun({args: [for (i in 0...args.length) {name: args[i].v.name, opt: f.fArgs[i].opt || f.fArgs[i].value != null, t: args[i].v.type}], ret: ret});
				// A named local function binds its name (in scope before the body, so it can recurse)
				// and evaluates to a TVar assignment; an anonymous one is just the function value.
				var namedVar:Null<TVar> = switch (kind) {
					case FKNamed(n, _): addLocal(ctx, VUser(TVOLocalVariable), n.name, ft, n.pos);
					case _: null;
				};
				// A named generic local function stores its type params so a later call can monomorphize them.
				if (namedVar != null && localParams.length > 0) namedVar.extra = new TVarExtra(localParams);
				// Type each argument default value against its (possibly inferred) type, binding an unbound
				// monomorph and recording it for runtime default insertion. .
				for (i in 0...args.length) {
					var fa = f.fArgs[i];
					var at = args[i].v.type;
					if (fa.value != null) args[i].c = typeExpr(ctx, fa.value, WithTypeTools.withType(at));
					else if (fa.opt) args[i].c = TypeFunctions.mk(TConst(TNull), at, fa.name.pos);
				}
				var tf = typeFunction(ctx, args, ret, ctx.curfun, f.fExpr, p);
				ctx.typeParams = savedTypeParams;
				var fnExpr = TypeFunctions.mk(TFunction(tf), ft, p);
				namedVar != null ? TypeFunctions.mk(TVarExpr(namedVar, fnExpr), ctx.com.basic.tvoid, p) : fnExpr;
			case EArrayDecl(el):
				switch (el) {
					case [{expr: EFor(_, _)}] | [{expr: EWhile(_, _, _)}]:
						typeArrayComprehension(ctx, el[0], withType, p);
					case _ if (el.length > 0 && (switch (el[0].expr) { case EBinop(OpArrow, _, _): true; case _: false; })):
						typeMapDeclaration(ctx, el, withType, p);
					case _:
						var emptyMap:Null<TExpr> = null;
						if (el.length == 0) switch (withType) {
							case WithType(wt, _):
								switch (TypeFunctions.follow(wt)) {
									case TAbstract(a, _) if (a.path.name == "Map"):
										var tp:PlacedTypePath = {path: {tpackage: ["haxe", "ds"], tname: "Map", tparams: [], tsub: null}, pos: p};
										emptyMap = typeNew(ctx, tp, [], withType, p);
									case _:
								}
							case _:
						}
						if (emptyMap != null) emptyMap else {
							var expectedEt:Null<T> = switch (withType) {
								case WithType(wt, _): expectedArrayElement(ctx, wt);
								case _: null;
							};
							var ewt = expectedEt == null ? WithTypeTools.value : WithTypeTools.withType(expectedEt);
							// An element that does not unify with the expected element type coerces through
							// an implicit abstract cast.
							var tl = [for (e in el) {
								var te = typeExpr(ctx, e, ewt);
								if (expectedEt != null) {
									try hxc.core.TypeUnification.unifyDefault(te.type, expectedEt)
									catch (_:hxc.core.TypeUnification.UnifyError) te = castOrUnify(ctx, expectedEt, te, e.pos);
								}
								te;
							}];
							var et = expectedEt != null ? expectedEt : (tl.length == 0 ? spawnMonomorph(ctx, p) : unifyMin(ctx, tl));
							TypeFunctions.mk(TArrayDecl(tl), ctx.com.basic.tarray(et), p);
						}
				}
			case EObjectDecl(fields):
				// A field may appear only once in an object literal.
				{
					var seen = new haxe.ds.StringMap<Bool>();
					for (f in fields) {
						if (seen.exists(f.name)) throw new TypingError("Duplicate field in object declaration : " + f.name, f.pos);
						seen.set(f.name, true);
					}
				}
				// A `{...}` literal against a @:structInit class types as a call to that class's
				// constructor, matching fields to constructor arguments by name.
				var scHit = switch (withType) {
					case WithType(wt, _): switch (TypeFunctions.follow(wt)) {
						case TInst(c, tl) if (TypeFunctions.hasMeta(":structInit", c.meta)): {c: c, tl: tl, t: TypeFunctions.follow(wt)};
						case _: null;
					};
					case _: null;
				};
				var scSig = scHit == null ? null : switch (findConstructorType(ctx, scHit.c, scHit.tl)) {
					case null: null;
					case ct: switch (TypeFunctions.follow(ct)) { case TFun(sig): sig; case _: null; };
				};
				if (scHit != null && scSig != null) {
					// Type each provided field against its constructor-arg type in the object literal
					// source order; build the call in the constructor declared arg order, hoisting a field
					// into a temp when a later-source field has a side effect, so initializers still run in
					// source order.
					var argByName = new haxe.ds.StringMap<TSignatureArg>();
					for (arg in scSig.args) argByName.set(arg.name, arg);
					var byName = new haxe.ds.StringMap<TExpr>();
					for (f in fields) {
						var arg = argByName.get(f.name);
						var te = typeExpr(ctx, f.expr, arg != null ? WithTypeTools.withStructureField(arg.t, f.name) : WithTypeTools.value);
						if (arg != null) te = castOrUnify(ctx, arg.t, te, te.pos);
						byName.set(f.name, te);
					}
					var evars:Array<TExpr> = [];
					var hadSideEffect = false;
					var fi = fields.length - 1;
					while (fi >= 0) {
						var fname = fields[fi].name;
						var te = byName.get(fname);
						switch (te.expr) {
							case TConst(_) | TTypeExpr(_) | TFunction(_):
							case _:
								if (hadSideEffect) {
									var v = TypeFunctions.allocVar(VGenerated, "`s", te.type, te.pos);
									evars.unshift(TypeFunctions.mk(TVarExpr(v, te), te.type, te.pos));
									byName.set(fname, TexprTools.makeLocal(v, te.pos));
								} else if (hasSideEffect(te)) {
									hadSideEffect = true;
								}
						}
						fi--;
					}
					var el:Array<TExpr> = [];
					for (arg in scSig.args) {
						var te = byName.get(arg.name);
						if (te != null) el.push(te);
						else if (arg.opt) el.push(TexprTools.makeNull(arg.t, p));
						else throw new TypingError("Object requires field " + arg.name, p);
					}
					var enew = TypeFunctions.mk(TNew(scHit.c, scHit.tl, el), scHit.t, p);
					if (evars.length == 0) enew else TypeFunctions.mk(TBlock(evars.concat([enew])), scHit.t, p);
				} else {
					var tfields:Array<TObjectField> = [];
					var anonFields = new haxe.ds.StringMap<TClassField>();
					var expected = expectedAnonFromWithType(withType);
					for (f in fields) {
						var ef = expected != null ? expected.fields.get(f.name) : null;
						var fwt = ef != null ? WithTypeTools.withType(ef.type) : WithTypeTools.value;
						var te = typeExpr(ctx, f.expr, fwt);
						// Against an expected field type, coerce the value to it so an implicit abstract cast
						// (e.g. Int -> Int64 @:from) applies, matching the field's declared type.
						if (ef != null) te = castOrUnify(ctx, ef.type, te, f.pos);
						tfields.push({key: {name: f.name, pos: f.pos, quotes: f.quotes}, expr: te});
						// Against an expected structure the field takes the expected type (the value was
						// just coerced to it), so e.g. `({f: -1} : {f:Float})` is `{f:Float}`, not
						// `{f:Int}`. ODKWithStructure.
						var anonField = TypeFunctions.mkField(f.name, ef != null ? ef.type : te.type, f.pos, f.pos);
						if (ef != null && TypeFunctions.hasClassFieldFlag(ef, CfFinal)) TypeFunctions.addClassFieldFlag(anonField, CfFinal);
						anonFields.set(f.name, anonField);
					}
					var t = TypeFunctions.mkAnon(new hxc.core.Ref(Const), anonFields);
					// A literal against an expected structure must provide every non-optional expected
					// field and nothing more. Recorded, not raised, so every violation is reported (and a
					// macro Context.typeof raises through the record).
					if (expected != null && !ctx.untypedMode) {
						var missing:Array<String> = [];
						for (n in expected.fields.keys()) {
							var ef = expected.fields.get(n);
							if (!TypeFunctions.hasMeta(":optional", ef.meta) && !anonFields.exists(n)) missing.push(n);
						}
						// Missing fields are listed in descending name order.
						missing.sort(function(x, y) return x < y ? 1 : (x > y ? -1 : 0));
						if (missing.length == 1) ctx.com.addDiagnostic("Object requires field " + missing[0], p);
						else if (missing.length > 1) ctx.com.addDiagnostic("Object requires fields: " + missing.join(", "), p);
						for (f in fields) {
							if (!expected.fields.exists(f.name))
								ctx.com.addDiagnostic(hxc.core.TPrinting.sTypeStr(t) + " has extra field " + f.name, f.pos);
						}
					}
					TypeFunctions.mk(TObjectDecl(tfields), t, p);
				}
			case ETry(e1, catches):
				var te = typeExpr(ctx, e1, withType);
				var tcatches:Array<TCatch> = [];
				var bodies = [te];
				for (c in catches) {
					var th = c.type != null ? c.type : defaultCatchTypeHint(c.pos);
					var catchType = Typeload.loadComplexType(ctx.com, ctx.typeParams, th);
					var normalizedCatchType = normalizeCatchType(ctx, catchType, th.pos);
					checkCatchUnreachable(tcatches, normalizedCatchType, c.expr.pos);
					var restore = saveLocals(ctx);
					var v = addLocal(ctx, VUser(TVOCatchVariable), c.name.name, catchType, c.pos);
					var cbody = typeExpr(ctx, c.expr, withType);
					v.type = normalizedCatchType;
					restore();
					tcatches.push({v: v, expr: cbody});
					bodies.push(cbody);
				}
				TypeFunctions.mk(TTry(te, tcatches), unifyMin(ctx, bodies), p);
			case ECast(e1, ct):
				var te = typeExpr(ctx, e1, WithTypeTools.value);
				if (ct == null) {
					TypeFunctions.mk(TCast(te, null), spawnMonomorph(ctx, p), p);
				} else {
					var t = Typeload.loadComplexType(ctx.com, ctx.typeParams, ct);
					// The runtime-checked cast target: an abstract without @:runtimeValue resolves to its
					// underlying type, so the eval safe-cast check sees the concrete class (or the
					// @:runtimeValue basic).
					function loop(t:T):Null<ModuleType> return switch (TypeFunctions.follow(t)) {
						case TInst(c, _): TClassDecl(c);
						case TEnum(en, _): TEnumDecl(en);
						case TAbstract(a, _) if (TypeFunctions.hasMeta(":runtimeValue", a.meta)): TAbstractDecl(a);
						case TAbstract(a, params): loop(TypeFunctions.getUnderlyingType(a, params));
						case _: null;
					};
					TypeFunctions.mk(TCast(te, loop(t)), t, p);
				}
			case EIs(e1, th):
				// `x is T` is sugar for Std.isOfType(x, T); T must be a named type path (its type
				// parameters are ignored at runtime).
				switch (th.ct) {
					case CTPath(tp):
						if (tp.tparams.length > 0) ctx.com.addDiagnostic("Type parameters are not supported for the `is` operator", th.pos);
						var e = typeExpr(ctx, e1, WithTypeTools.value);
						var mt = Typeload.resolveTypePath(ctx.com, {pack: tp.tpackage, name: tp.tname}, tp.tsub, th.pos);
						var eType = TexprTools.makeTypeExpr(mt, th.pos);
						var std = switch (Typeload.resolveTypePath(ctx.com, {pack: [], name: "Std"}, null, p)) {
							case TClassDecl(c): c;
							case _: throw new TypingError("Std is not a class", p);
						};
						var cf = std.statics.get("isOfType");
						if (cf == null) throw new TypingError("Field not found : isOfType", p);
						var stdIs = TexprTools.makeStaticField(std, cf, p);
						TypeFunctions.mk(TCall(stdIs, [e, eType]), ctx.com.basic.tbool, p);
					case _:
						ctx.com.addDiagnostic("Unsupported type for `is` operator", th.pos);
						TexprTools.makeBool(ctx.com.basic, false, p);
				}
			case EDisplay(_, _):
				throw new TypingError("Display is not yet ported", p);
			case ECheckType(e1, th):
				var t = Typeload.loadComplexType(ctx.com, ctx.typeParams, th);
				var te = typeExpr(ctx, e1, WithTypeTools.withType(t));
				var te2 = castOrUnify(ctx, t, te, p);
				TypeUnification.fastEq(te2.type, t) ? te2 : TypeFunctions.mk(TCast(te2, null), t, p);
		};
		DebugDump.typed("typeExpr", typed);
		return typed;
	}

	static function expectedAnonFromWithType(withType:WithType):Null<TAnon> {
		return switch (withType) {
			case WithType(t, _): expectedAnonFromType(t, []);
			case _: null;
		}
	}

	static function expectedAnonFromType(t:T, seen:Array<T>):Null<TAnon> {
		return switch (TypeFunctions.follow(t)) {
			case TAnon(a):
				a;
			case TAbstract(a, params) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				for (old in seen) if (TypeUnification.shallowEq(t, old)) return null;
				var hits:Array<TAnon> = [];
				var nextSeen = seen.concat([t]);
				for (fromType in a.from) {
					var hit = expectedAnonFromType(TypeFunctions.applyParams(a.params, params, fromType), nextSeen);
					if (hit != null) hits.push(hit);
				}
				// @:from function argument types are candidates too; more than one structure candidate
				// means the literal types plainly and unification decides. + ODKFailed.
				for (c in a.fromField) {
					switch (TypeFunctions.follow(c.cf.type)) {
						case TFun(sig) if (sig.args.length == 1):
							var hit = expectedAnonFromType(TypeFunctions.applyParams(a.params, params, sig.args[0].t), nextSeen);
							if (hit != null) hits.push(hit);
						case _:
					}
				}
				hits.length == 1 ? hits[0] : null;
			case _:
				null;
		}
	}

	// Desugar single-quote string interpolation ('$ident' / '${expr}') into concatenation.
	public static function formatString(str:String, p:Position, ?defines:hxc.core.Define):Expr {
		function strLit(v:String):Expr return new Expr(EConst(CString(v, SDoubleQuotes)), p);
		function isIdentStart(c:Int):Bool return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code;
		function isIdentChar(c:Int):Bool return isIdentStart(c) || (c >= "0".code && c <= "9".code);
		var parts:Array<Expr> = [];
		var buf = new StringBuf();
		function flush() { var t = buf.toString(); if (t.length > 0) { parts.push(strLit(t)); buf = new StringBuf(); } }
		var i = 0;
		var n = str.length;
		while (i < n) {
			var c = str.charCodeAt(i);
			if (c == "$".code && i + 1 < n) {
				var d = str.charCodeAt(i + 1);
				if (d == "$".code) { buf.addChar("$".code); i += 2; }
				else if (d == "{".code) {
					flush();
					var depth = 1;
					var j = i + 2;
					var sb = new StringBuf();
					while (j < n && depth > 0) {
						var cj = str.charCodeAt(j);
						if (cj == "{".code) { depth++; sb.addChar(cj); }
						else if (cj == "}".code) { depth--; if (depth > 0) sb.addChar(cj); }
						else sb.addChar(cj);
						j++;
					}
					parts.push(hxc.parser.Parser.parseExprString(sb.toString(), p.file, defines));
					i = j;
				} else if (isIdentStart(d)) {
					flush();
					var j = i + 1;
					var sb = new StringBuf();
					while (j < n && isIdentChar(str.charCodeAt(j))) { sb.addChar(str.charCodeAt(j)); j++; }
					parts.push(new Expr(EConst(CIdent(sb.toString())), p));
					i = j;
				} else { buf.addChar(c); i++; }
			} else { buf.addChar(c); i++; }
		}
		flush();
		if (parts.length == 0) return strLit("");
		// Lead with an empty string literal so the whole chain concatenates as String.
		var acc = strLit("");
		for (part in parts) acc = new Expr(EBinop(OpAdd, acc, part), p);
		return acc;
	}

	static function typeConst(ctx:TyperContext, c:Constant, p:Position, mode:AccessMode, withType:WithType):TExpr {
		var basic = ctx.com.basic;
		return switch (c) {
			case CIdent(s):
				if (s == "super" && !withType.match(NoValue)) throw new TypingError("Cannot use super as value", p);
				accGet(ctx, typeIdent(ctx, s, p, mode, withType));
			case CInt(s, suffix):
				if (suffix == null) TexprTools.typeConstant(basic, c, p);
				else switch (suffix) {
					case "i32":
						var i = Std.parseInt(StringTools.replace(s, "_", ""));
						if (i == null) throw new TypingError("Cannot represent " + s + " with a 32 bit integer", p);
						TypeFunctions.mk(TConst(TInt(i)), basic.tint, p);
					case "i64":
						// NNNi64 is a haxe.Int64 literal: split the 64-bit value into high/low halves and
						// build haxe.Int64.make(high, low).
						var v = parseInt64Literal(StringTools.replace(s, "_", ""));
						function intExpr(n:Int):Expr return new Expr(EConst(CInt(Std.string(n), null)), p);
						var mk = new Expr(EField(new Expr(EField(new Expr(EConst(CIdent("haxe")), p), "Int64", EFNormal), p), "make", EFNormal), p);
						var call = new Expr(ECall(mk, [intExpr(v.high), intExpr(v.low)]), p);
						typeExpr(ctx, call, withType);
					case "u32":
						// NNNu32 is `(NNN : UInt)`.
						var inner = new Expr(EConst(CInt(s, null)), p);
						var ct:TypeHint = {ct: CTPath({tpackage: [], tname: "UInt", tparams: [], tsub: null}), pos: p};
						typeExpr(ctx, new Expr(ECheckType(inner, ct), p), withType);
					case other: throw new TypingError(other + " is not a valid integer suffix", p);
				}
			case CFloat(s, suffix):
				if (suffix == null) TexprTools.typeConstant(basic, c, p);
				else switch (suffix) {
					case "f64": TexprTools.typeConstant(basic, CFloat(s, null), p);
					case other: throw new TypingError(other + " is not a valid float suffix", p);
				}
			case CString(str, SSingleQuotes) if (str.indexOf("$") >= 0):
				typeExpr(ctx, formatString(str, p), withType);
			case CString(_, _):
				TexprTools.typeConstant(basic, c, p);
			case CRegexp(r, opt):
				var tp:PlacedTypePath = {path: {tpackage: [], tname: "EReg", tparams: [], tsub: null}, pos: p};
				var args = [new Expr(EConst(CString(r, SDoubleQuotes)), p), new Expr(EConst(CString(opt, SDoubleQuotes)), p)];
				typeNew(ctx, tp, args, withType, p);
		};
	}

	// Type_ident (subset): locals and the literal idents. Member/static fields, types,
	// imports, and globals resolve in the fields-dispatch unit.
	static function typeIdent(ctx:TyperContext, i:String, p:Position, mode:AccessMode, withType:WithType):AccessKind {
		if (i == "abstract") {
			return switch [mode, ctx.curclass.kind] {
				case [MSet(_), KAbstractImpl(_)]: throw new TypingError("Property 'abstract' is read-only", p);
				case [MGet, KAbstractImpl(a)] | [MCall(_), KAbstractImpl(a)]:
					var v = ctx.locals.get("this");
					if (v == null) throw new TypingError("Cannot reference this abstract here", p);
					var tl = TypeFunctions.extractParamTypes(a.params);
					AKExpr(TypeFunctions.mk(TLocal(v), TAbstract(a, tl), p));
				case _:
					throw new TypingError("Property 'abstract' is reserved and only available in abstracts", p);
			}
		}
		if (ctx.locals.exists(i)) {
			return AKExpr(TexprTools.makeLocal(ctx.locals.get(i), p));
		}
		switch (i) {
			case "null": return AKExpr(TypeFunctions.mk(TConst(TNull), ctx.com.basic.tnull(spawnMonomorph(ctx, p)), p));
			case "true": return AKExpr(TexprTools.makeBool(ctx.com.basic, true, p));
			case "false": return AKExpr(TexprTools.makeBool(ctx.com.basic, false, p));
			case "this": return AKExpr(TypeFunctions.mk(TConst(TThis), ctx.tthis, p));
			case _:
		}
		if (ctx.curclass != TypeFunctions.nullClass) {
			// Member-variable lookup searches the whole inheritance chain, not just the class's own fields,
			// so a bare call to an inherited method resolves against `this`. The access uses the class the
			// field was found in as its host.
			if (!ctx.curfun.match(FunStatic)) {
				var found = try TypeFunctions.rawClassField(function(f) return TypeFunctions.fieldType(f), ctx.curclass, TypeFunctions.extractParamTypes(ctx.curclass.params), i) catch (_:hxc.core.NotFound) null;
				if (found != null) {
					var thisExpr = TypeFunctions.mk(TConst(TThis), ctx.tthis, p);
					var host:FieldHost = switch (found.c2) { case null: FHAnon; case cw: FHInstance(cw.c, cw.params); };
					// Dispatch on the field kind so a property read/write goes through its accessor
					// (get_/set_), not a raw field access.
					return Fields.fieldAccess(ctx, mode, found.f, host, thisExpr, p);
				}
			}
			var smf = ctx.curclass.statics.get(i);
			if (smf != null) {
				// Inside an abstract impl method, a bare call to a sibling member method threads `this`.
				var absImpl = switch (ctx.curclass.kind) { case KAbstractImpl(ab): ab; case _: null; };
				if (absImpl != null && TypeFunctions.hasClassFieldFlag(smf, CfImpl) && ctx.locals.exists("this")) {
					var thisExpr = TexprTools.makeLocal(ctx.locals.get("this"), p);
					// A bare reference to a sibling abstract member threads `this`: a method becomes a
					// static extension call, a var/property dispatches through its accessor (get_/set_)
					// rather than emitting a raw static field access.
					switch (smf.kind) {
						case Method(_):
							return AKUsingField(FieldAccessTools.makeStaticExtensionAccess(ctx.curclass, smf, thisExpr, false, p));
						case Var(_):
							return Fields.fieldAccess(ctx, mode, smf, FHAbstract(absImpl, TypeFunctions.extractParamTypes(absImpl.params), ctx.curclass), thisExpr, p);
					}
				}
				var typeExpr = TexprTools.makeTypeExpr(TClassDecl(ctx.curclass), p);
				return Fields.fieldAccess(ctx, mode, smf, FieldAccessTools.getHost(ctx.curclass, smf), typeExpr, p);
			}
		}
		switch (withType) {
			case WithType(wt, _):
				var expectedEnum = expectedEnumLike(wt, []);
				if (expectedEnum != null && expectedEnum.constrs.exists(i)) {
					var acc = Fields.enumConstructor(ctx, expectedEnum, TexprTools.makeTypeExpr(TEnumDecl(expectedEnum), p), i, p);
					// A constructor function's return unifies with the expected type so the enum's type
					// parameters bind from the expectation before the arguments; failure is ignored. .
					switch (acc) {
						case AKExpr(te):
							switch (TypeFunctions.follow(te.type)) {
								case TFun(sig): try TypeUnification.unifyDefault(sig.ret, wt) catch (_:UnifyError) {};
								case _:
							}
						case _:
					}
					return acc;
				}
				switch (TypeFunctions.follow(wt)) {
					case TAbstract(a, tl) if (a.isEnum && a.impl != null && a.impl.statics.exists(i)):
						// An enum-abstract value used unqualified resolves against the expected type, like an
						// enum constructor: look it up as an @:enum static on the abstract's impl class.
						var cf = a.impl.statics.get(i);
						if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) {
							cf.type = TAbstract(a, tl);
							var typeExpr = TexprTools.makeTypeExpr(TClassDecl(a.impl), p);
							return Fields.fieldAccess(ctx, mode, cf, FHStatic(a.impl), typeExpr, p);
						}
					case _:
				}
			case _:
		}
		var bareEnum = findBareEnumLike(ctx, i);
		if (bareEnum != null) switch (bareEnum) {
			case TEnumDecl(en):
				return Fields.enumConstructor(ctx, en, TexprTools.makeTypeExpr(TEnumDecl(en), p), i, p);
			case TAbstractDecl(a) if (a.impl != null):
				var cf = a.impl.statics.get(i);
				// Without an expected type the value's abstract parameters are fresh constrained
				// monomorphs, not the declared type parameters. (the enum field type unifies with
				// TAbstract(a, spawnConstrainedMonos ...)).
				if (TypeFunctions.hasClassFieldFlag(cf, CfEnum))
					cf.type = TAbstract(a, TypeUnification.spawnConstrainedMonos(function(t) return t, a.params));
				return Fields.fieldAccess(ctx, mode, cf, FHStatic(a.impl), TexprTools.makeTypeExpr(TClassDecl(a.impl), p), p);
			case _:
		}
		// A module-level field (Haxe 4.2 module-level `var`/`function`, stored in the synthetic
		// <Module>_Fields_ class) is visible unqualified within its own module.
		var modStatic = resolveModuleStatic(ctx, i, p, mode);
		if (modStatic != null) return modStatic;
		var resolvedToTypeParameter = false;
		for (tp in ctx.typeParams) if (tp.name == i) {
			resolvedToTypeParameter = true;
			switch (TypeFunctions.follow(TypeFunctions.extractParamType(tp))) {
				case TInst(c, _) if (isGenericParameter(ctx, c) && TypeFunctions.hasMeta(":const", c.meta)):
					var e = TexprTools.makeTypeExpr(TClassDecl(c), p);
					return AKExpr(TypeFunctions.mk(e.expr, TypeFunctions.extractParamType(tp), e.pos));
				case _:
			}
			break;
		}
		if (i == "trace") {
			var logMt = ctx.com.getType({pack: ["haxe"], name: "Log"}, p, null);
			try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(logMt).module) catch (_:Dynamic) {}
			return Fields.typeField(ctx, TexprTools.makeTypeExpr(logMt, p), "trace", p, mode, withType);
		}
		// A static-field import (`import M.field`) or a static wildcard (`import M.*` on a type) makes a
		// static field or enum constructor available unqualified.
		var imp = resolveImportedStatic(ctx, i, p, mode);
		if (imp != null) return imp;
		var mt = hxc.context.ModuleLoader.resolveBareType(ctx.com, ctx.com.currentModule, i, p);
		if (mt == null) {
			try mt = ctx.com.getType({pack: [], name: i}, p, null) catch (_:hxc.context.Context.ContextError) mt = null;
		}
		if (mt == null) {
			// In untyped mode an unresolved identifier becomes a TIdent, letting reification builtins such
			// as $__mk_pos__ (recognized by the interpreter) pass typing. A name that is a package root on
			// the class path stays unresolved instead, so the enclosing field chain resolves it as a type
			// path .
			if (ctx.untypedMode && !isPackageRoot(ctx, i)) return AKExpr(TypeFunctions.mk(TIdent(i), spawnMonomorph(ctx, p), p));
			if (resolvedToTypeParameter) throw new TypingError("Only @:const type parameters on @:generic classes can be used as value", p);
			throw new TypingError("Unknown identifier : " + i, p);
		}
		// Hxc resolves field types in a separate pass; resolve the referenced module so its
		// statics have real types (idempotent via processed).
		try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
		switch (mt) { case TClassDecl(c): hxc.eval.EvalMacro.ensureBuilt(ctx.com, c); case _: }
		return AKExpr(TexprTools.makeTypeExpr(mt, p));
	}

	static var packageRootCache:Null<haxe.ds.StringMap<Bool>> = null;

	// True when `name` is a package directory on the class path.
	static function isPackageRoot(ctx:TyperContext, name:String):Bool {
		if (packageRootCache == null) packageRootCache = new haxe.ds.StringMap();
		var hit = packageRootCache.get(name);
		if (hit != null) return hit;
		var found = false;
		for (cp in ctx.com.classPath) {
			if (sys.FileSystem.exists(cp + name) && sys.FileSystem.isDirectory(cp + name)) {
				found = true;
				break;
			}
		}
		packageRootCache.set(name, found);
		return found;
	}

	static function expectedEnumLike(t:T, stack:Array<T>):Null<TEnum> {
		for (s in stack) if (TypeUnification.shallowEq(t, s)) return null;
		return switch (TypeFunctions.follow(t)) {
			case TEnum(en, _):
				en;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta) && a.from.length == 1):
				expectedEnumLike(TypeFunctions.applyParams(a.params, tl, a.from[0]), [t].concat(stack));
			case _:
				null;
		}
	}

	// Parse an i64 literal string (decimal or 0x-hex) into its 64-bit value.
	static function parseInt64Literal(s:String):haxe.Int64 {
		if (s.length >= 2 && (s.substr(0, 2) == "0x" || s.substr(0, 2) == "0X")) {
			var v = haxe.Int64.ofInt(0);
			var sixteen = haxe.Int64.ofInt(16);
			for (i in 2...s.length) {
				var c = s.charCodeAt(i);
				var d = if (c >= "0".code && c <= "9".code) c - "0".code
					else if (c >= "a".code && c <= "f".code) c - "a".code + 10
					else if (c >= "A".code && c <= "F".code) c - "A".code + 10
					else 0;
				v = haxe.Int64.add(haxe.Int64.mul(v, sixteen), haxe.Int64.ofInt(d));
			}
			return v;
		}
		return haxe.Int64.parseString(s);
	}

	// A bare identifier provided by an explicit static-field import (`import M.field`) or a static
	// wildcard import (`import M.*` where M is a type): resolve it as that type's static field or
	// enum constructor. Abstract members (CfImpl, which need `this`) are not importable unqualified.
	static function resolveImportedStatic(ctx:TyperContext, i:String, p:Position, mode:AccessMode):Null<AccessKind> {
		var m = ctx.com.currentModule;
		if (m == null) return null;
		var imports = ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports == null) return null;
		function tryType(mt:ModuleType, lookupName:String):Null<AccessKind> {
			try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
			switch (mt) {
				case TClassDecl(c):
					hxc.eval.EvalMacro.ensureBuilt(ctx.com, c);
					var cf = c.statics.get(lookupName);
					if (cf != null) return Fields.fieldAccess(ctx, mode, cf, FHStatic(c), TexprTools.makeTypeExpr(TClassDecl(c), p), p);
				case TAbstractDecl(a) if (a.impl != null):
					var cf = a.impl.statics.get(lookupName);
					if (cf != null && !TypeFunctions.hasClassFieldFlag(cf, CfImpl))
						return Fields.fieldAccess(ctx, mode, cf, FHStatic(a.impl), TexprTools.makeTypeExpr(TClassDecl(a.impl), p), p);
				case TEnumDecl(en) if (en.constrs.exists(lookupName)):
					return Fields.enumConstructor(ctx, en, TexprTools.makeTypeExpr(TEnumDecl(en), p), lookupName, p);
				case _:
			}
			return null;
		}
		var g = imports.globals.get(i);
		if (g != null) {
			var mt = try ctx.com.getType(g.ownerPath, p, g.ownerSub) catch (_:Dynamic) null;
			if (mt != null) { var r = tryType(mt, g.field != null ? g.field : i); if (r != null) return r; }
		}
		for (w in imports.wildcards) {
			var mt = try ctx.com.getType(w, p, null) catch (_:Dynamic) null;
			if (mt != null) { var r = tryType(mt, i); if (r != null) return r; }
		}
		return null;
	}

	// A bare identifier naming a module-level field (stored on the synthetic <Module>_Fields_ class).
	static function resolveModuleStatic(ctx:TyperContext, i:String, p:Position, mode:AccessMode):Null<AccessKind> {
		var m = ctx.com.currentModule;
		if (m == null || m.statics == null) return null;
		var c = m.statics;
		var cf = c.statics.get(i);
		if (cf == null) return null;
		return Fields.fieldAccess(ctx, mode, cf, FHStatic(c), TexprTools.makeTypeExpr(TClassDecl(c), p), p);
	}

	// A bare identifier that names a constructor of an enum, or a member of an enum abstract, declared
	// in the current module or brought in by a module import. Returns the owning enum/abstract decl.
	static function findBareEnumLike(ctx:TyperContext, i:String):Null<ModuleType> {
		var m = ctx.com.currentModule;
		if (m == null) return null;
		function scan(types:Array<ModuleType>):Null<ModuleType> {
			for (mt in types) switch (mt) {
				case TEnumDecl(en) if (en.constrs.exists(i)): return mt;
				case TAbstractDecl(a) if (a.isEnum && a.impl != null && a.impl.statics.exists(i)): return mt;
				case TTypeDecl(td):
					switch (TypeFunctions.follow(td.type)) {
						case TEnum(en, _) if (en.constrs.exists(i)): return TEnumDecl(en);
						case TAbstract(a, _) if (a.isEnum && a.impl != null && a.impl.statics.exists(i)): return TAbstractDecl(a);
						case _:
					}
				case _:
			}
			return null;
		}
		var ownTypes = m.types.copy();
		ownTypes.reverse();
		var own = scan(ownTypes);
		if (own != null) return own;
		// A module import brings the constructors/members of that module's enums into scope.
		var imports = ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports != null) {
			function scanPath(path:hxc.core.Globals.Path):Null<ModuleType> {
				var md = try hxc.context.ModuleLoader.loadModule(ctx.com, path, Position.nullPos) catch (_:Dynamic) null;
				if (md != null) try hxc.typing.TypeResolve.resolveModule(ctx.com, md) catch (_:Dynamic) {}
				return md == null ? null : scan(md.types);
			}
			for (imp in imports.names) { var r = scanPath(imp.modulePath); if (r != null) return r; }
			for (w in imports.wildcards) { var r = scanPath(w); if (r != null) return r; }
		}
		return null;
	}

	static function flattenIdentPath(e:ExprDef):Null<Array<String>> {
		return switch (e) {
			case EConst(CIdent(s)): [s];
			case EField(e1, f, _):
				var pre = flattenIdentPath(e1.expr);
				pre == null ? null : pre.concat([f]);
			case _: null;
		};
	}

	// Resolves a dotted ident chain (pack.Type.field...) as a package-qualified type path.
	static function tryTypePath(ctx:TyperContext, e:ExprDef, p:Position, mode:AccessMode, withType:WithType):Null<AccessKind> {
		var segs = flattenIdentPath(e);
		if (segs == null || segs.length < 2) return null;
		var typeIdx = -1;
		for (i in 0...segs.length) {
			var c = segs[i].charCodeAt(0);
			if (c >= "A".code && c <= "Z".code) { typeIdx = i; break; }
		}
		if (typeIdx < 0) return null;
		var pack = segs.slice(0, typeIdx);
		// A leading `std` package selects the standard library type, bypassing a shadowing local or import
		// (e.g. `std.haxe.crypto.Md5` while a local `var haxe` is in scope). (std pack).
		if (pack.length > 0 && pack[0] == "std") pack = pack.slice(1);
		var name = segs[typeIdx];
		var rest = segs.slice(typeIdx + 1);
		// A module with no same-named main type (e.g. unit.MyMacro holds only MyRestMacro /
		// MyMacroHelper) leaves the main-type lookup empty; keep going so the sub-type lookup below
		// can still resolve the path rather than bailing to a field access.
		var mt = try ctx.com.getType({pack: pack, name: name}, p, null) catch (_:Dynamic) null;
		// pack.Module.SubType.field: when the next segment names a sub-type of the module, resolve it as
		// the type (module + sub) rather than a field access on the module's main type.
		if (rest.length > 0) {
			var c0 = rest[0].charCodeAt(0);
			if (c0 >= "A".code && c0 <= "Z".code) {
				var subMt = try ctx.com.getType({pack: pack, name: name}, p, rest[0]) catch (_:Dynamic) null;
				if (subMt != null) { mt = subMt; rest = rest.slice(1); }
			}
		}
		if (mt == null) return null;
		try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
		switch (mt) { case TClassDecl(c): hxc.eval.EvalMacro.ensureBuilt(ctx.com, c); case _: }
		var acc:AccessKind = AKExpr(TexprTools.makeTypeExpr(mt, p));
		for (i in 0...rest.length) {
			var isLast = i == rest.length - 1;
			acc = Fields.typeField(ctx, accGet(ctx, acc), rest[i], p, isLast ? mode : MGet, isLast ? withType : WithTypeTools.value);
		}
		return acc;
	}

	static function typeArrayComprehension(ctx:TyperContext, e:Expr, withType:WithType, p:Position):TExpr {
		// Uses a gen local; the syntactic name must stay unique for resolution, so the typed var is
		// renamed to the backtick form afterwards (RenameVars then produces _g like the reference)
		var acc = "_hx_comp";
		var mapped = comprehensionPush(acc, e);
		var init = mapped.isMap
			? new Expr(ENew({path: {tpackage: ["haxe", "ds"], tname: "Map", tparams: [], tsub: null}, pos: p}, []), p)
			: new Expr(EArrayDecl([]), p);
		var decl = new Expr(EVars([{evName: {name: acc, pos: p}, evFinal: false, evStatic: false, evType: null, evExpr: init, evMeta: []}]), p);
		var te = typeExpr(ctx, new Expr(EBlock([decl, mapped.expr, new Expr(EConst(CIdent(acc)), p)]), p), withType);
		switch (te.expr) {
			case TBlock(el) if (el.length > 0):
				switch (el[0].expr) {
					case TVarExpr(v, _) if (v.name == acc):
						v.name = "`";
						v.kind = VGenerated;
					case _:
				}
			case _:
		}
		return te;
	}

	// Lowers a comprehension body so each tail expression updates the accumulator.
	static function comprehensionPush(acc:String, e:Expr):{expr:Expr, isMap:Bool} {
		inline function same(expr:Expr, isMap:Bool) return {expr: expr, isMap: isMap};
		inline function call(name:String, args:Array<Expr>):Expr
			return new Expr(ECall(new Expr(EField(new Expr(EConst(CIdent(acc)), e.pos), name, EFNormal), e.pos), args), e.pos);
		return switch (e.expr) {
			case EFor(it, body):
				var b = comprehensionPush(acc, body);
				same(new Expr(EFor(it, b.expr), e.pos), b.isMap);
			case EWhile(c, body, flag):
				var b = comprehensionPush(acc, body);
				same(new Expr(EWhile(c, b.expr, flag), e.pos), b.isMap);
			case EIf(c, e1, e2):
				var b1 = comprehensionPush(acc, e1);
				var b2 = e2 == null ? null : comprehensionPush(acc, e2);
				same(new Expr(EIf(c, b1.expr, b2 == null ? null : b2.expr), e.pos), b1.isMap || (b2 != null && b2.isMap));
			case EBlock(l) if (l.length > 0):
				var nl = l.copy();
				var last = comprehensionPush(acc, nl[nl.length - 1]);
				nl[nl.length - 1] = last.expr;
				same(new Expr(EBlock(nl), e.pos), last.isMap);
			case EParenthesis(e1):
				var b = comprehensionPush(acc, e1);
				same(new Expr(EParenthesis(b.expr), e.pos), b.isMap);
			case EBinop(OpArrow, a, b):
				same(call("set", [a, b]), true);
			case _:
				same(call("push", [e]), false);
		};
	}

	// Acc_get (subset).
	// Read of a field flagged inline (AccInline var, or an inline method closure). For an inline var the
	// stored constant value is substituted at the access site.
	static function samePath(a:hxc.core.Globals.Path, b:hxc.core.Globals.Path):Bool {
		return a.name == b.name && a.pack.join(".") == b.pack.join(".");
	}

	static function externInlineImplClass(c:TClass):TClass {
		var m = c.module;
		var implPath = {pack: m.path.pack.concat(["_" + m.path.name]), name: m.path.name + "_Impl_"};
		for (mt in m.types) switch (mt) {
			case TClassDecl(c2) if (samePath(c2.path, implPath)):
				return c2;
			case _:
		}
		var c2 = TypeFunctions.mkClass(m, implPath, c.pos, Position.nullPos);
		m.types.unshift(TClassDecl(c2));
		return c2;
	}

	static function externInlineField(ctx:TyperContext, c:TClass, cf:TClassField):TClassField {
		var c2 = externInlineImplClass(c);
		var cf2 = c2.statics.get(cf.name);
		if (cf2 != null) return cf2;
		TypeFields.forceFieldBody(ctx.com, c, cf);
		var body = cf.expr == null ? null : foldInlineStatics(ctx, cf.expr);
		cf2 = new TClassField(cf.name, cf.type, cf.pos, cf.namePos, cf.doc, cf.meta.copy(), Method(MethNormal), cf.params.copy(), body, cf.exprUnoptimized, cf.overloads.copy(), cf.flags);
		TypeFunctions.removeClassFieldFlag(cf2, CfExtern);
		TypeFunctions.addClassFieldFlag(cf2, CfStatic);
		c2.statics.set(cf2.name, cf2);
		c2.orderedStatics.unshift(cf2);
		return cf2;
	}

	static function foldedInlineStatic(ctx:TyperContext, c:TClass, cf:TClassField, p:Position):Null<TExpr> {
		switch (cf.kind) {
			case Var({read: AccInline}):
				TypeFields.forceFieldBody(ctx.com, c, cf);
				return switch (cf.expr) {
					case null:
						null;
					case e:
						var e2 = TypeFunctions.mk(e.expr, e.type, p);
						TypeUnification.typeIseqDefault(cf.type, e2.type) ? e2 : TypeFunctions.mk(TCast(e2, null), cf.type, p);
				}
			case _:
				return null;
		}
	}

	static function foldInlineStatics(ctx:TyperContext, e:TExpr):TExpr {
		function m(x:TExpr):TExpr return foldInlineStatics(ctx, x);
		var ne:TExprExpr = switch (e.expr) {
			case TField(e1, fa):
				switch (fa) {
					case FStatic(c, cf):
						var folded = foldedInlineStatic(ctx, c, cf, e.pos);
						if (folded != null) return folded;
						TField(m(e1), fa);
					case _:
						TField(m(e1), fa);
				}
			case TArray(e1, e2): TArray(m(e1), m(e2));
			case TBinop(op, e1, e2): TBinop(op, m(e1), m(e2));
			case TParenthesis(e1): TParenthesis(m(e1));
			case TObjectDecl(fields): TObjectDecl([for (f in fields) {key: f.key, expr: m(f.expr)}]);
			case TArrayDecl(values): TArrayDecl([for (x in values) m(x)]);
			case TCall(e1, params): TCall(m(e1), [for (x in params) m(x)]);
			case TNew(c, params, args): TNew(c, params, [for (x in args) m(x)]);
			case TUnop(op, flag, e1): TUnop(op, flag, m(e1));
			case TFunction(f): TFunction(new TFunc([for (a in f.args) {v: a.v, c: a.c == null ? null : m(a.c)}], f.type, m(f.expr)));
			case TVarExpr(v, eo): TVarExpr(v, eo == null ? null : m(eo));
			case TBlock(exprs): TBlock([for (x in exprs) m(x)]);
			case TFor(v, e1, e2): TFor(v, m(e1), m(e2));
			case TIf(econd, eif, eelse): TIf(m(econd), m(eif), eelse == null ? null : m(eelse));
			case TWhile(econd, e1, flag): TWhile(m(econd), m(e1), flag);
			case TSwitch(e1, cases, edef):
				TSwitch(m(e1), [for (c in cases) {values: [for (v in c.values) m(v)], expr: m(c.expr)}], edef == null ? null : m(edef));
			case TTry(e1, catches): TTry(m(e1), [for (c in catches) {v: c.v, expr: m(c.expr)}]);
			case TReturn(eo): TReturn(eo == null ? null : m(eo));
			case TThrow(e1): TThrow(m(e1));
			case TCast(e1, mt): TCast(m(e1), mt);
			case TMeta(entry, e1): TMeta(entry, m(e1));
			case TEnumParameter(e1, ef, index): TEnumParameter(m(e1), ef, index);
			case TEnumIndex(e1): TEnumIndex(m(e1));
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_):
				e.expr;
		};
		return TypeFunctions.mk(ne, e.type, e.pos);
	}

	static function inlineRead(ctx:TyperContext, fa:FieldAccess):TExpr {
		var cf = fa.field;
		var p = fa.pos;
		return switch (cf.kind) {
			case Method(_):
				var wrapClass = switch (TypeFunctions.follow(fa.on.type)) {
					case TInst(c, _) if ((TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) && !TypeFunctions.hasMeta(":runtime", cf.meta)):
						throw new TypingError("Can't create closure on an extern inline member method", p);
					case TAnon(a):
						switch (a.status.value) {
							case Statics(c) if (TypeFunctions.hasClassFlag(c, CExtern) && !TypeFunctions.hasMeta(":runtime", cf.meta)):
								c;
							case Statics(_) if (TypeFunctions.hasClassFieldFlag(cf, CfExtern) && !TypeFunctions.hasMeta(":runtime", cf.meta)):
								throw new TypingError("Cannot create closure on @:extern inline method", p);
							case _:
								null;
						}
					case _:
						null;
				};
				if (wrapClass != null) {
					var c2 = externInlineImplClass(wrapClass);
					var cf2 = externInlineField(ctx, wrapClass, cf);
					FieldAccessTools.getFieldExpr(FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(c2), p), cf2, FHStatic(c2), true, p), FRead);
				} else {
					FieldAccessTools.getFieldExpr(fa, FRead);
				}
			case Var(_):
				if (cf.expr == null) {
					// The inline var's initializer may not be typed yet (its module is processed later,
					// or it is an enum-abstract value forced on demand); type its body before reading the
					// stored constant. A genuine cycle leaves expr null and falls through to the error.
					var host = try FieldAccessTools.getHostClassRaise(fa.host) catch (_:hxc.core.NotFound) null;
					if (host != null) hxc.typing.TypeFields.forceFieldBody(ctx.com, host, cf);
				}
				switch (cf.expr) {
					case null: throw new TypingError("Recursive inline is not supported", p);
					case e:
						// apply_params is the identity for static/instance hosts, so substituting the stored
						// value only moves it to the access position; a TCast bridges any type mismatch.
						var e2 = TypeFunctions.mk(e.expr, e.type, p);
						var tf = cf.type;
						TypeUnification.typeIseqDefault(tf, e2.type) ? e2 : TypeFunctions.mk(TCast(e2, null), tf, p);
				}
		};
	}

	// An empty `{}` is an object literal (not a Void block) when a value of a known structure type is
	// expected. With no expected value, or an implicit return into a still-open monomorph, it stays a block.
	static function emptyBlockIsObject(wt:WithType):Bool {
		return switch (wt) {
			case NoValue: false;
			case WithType(t, ImplicitReturn): switch (TypeFunctions.follow(t)) { case TMono(_): false; case _: true; };
			case _: true;
		};
	}

	public static function accGet(ctx:TyperContext, acc:AccessKind):TExpr {
		return switch (acc) {
			case AKExpr(e): e;
			case AKField(fa): fa.isInline ? inlineRead(ctx, fa) : FieldAccessTools.getFieldExpr(fa, FRead);
			case AKNo(_, p): throw new TypingError("This expression cannot be accessed for reading", p);
			case AKAccessor(fa):
				switch (FieldAccessTools.resolveAccessor(fa, MGet)) {
					case AccessorFound(getterFa):
						Calls.buildCall(ctx, AKField(getterFa), [], WithTypeTools.value, fa.pos);
					case AccessorAnon:
						// No accessor field is available (anon structure or extern class): synthesize a
						// dynamic get_<name>() call.
						var t = fa.field.type;
						var tf = TFun({args: [], ret: t});
						Calls.makeCall(ctx, TypeFunctions.mk(TField(fa.on, TypeFunctions.quickFieldDynamic(fa.on.type, "get_" + fa.field.name)), tf, fa.pos), [], t, fa.pos);
					case AccessorNotFound | AccessorInvalid:
						throw new TypingError("This field cannot be accessed for reading", fa.pos);
				}
			case AKUsingAccessor(se):
				// Reading an abstract property calls the impl's get_<name>(this).
				var fa = se.access;
				var implC = FieldAccessTools.getHostClassRaise(fa.host);
				var getterCf = implC.statics.get("get_" + fa.field.name);
				if (getterCf == null) throw new TypingError("This field cannot be accessed for reading", fa.pos);
				var getterFa = FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(implC), fa.pos), getterCf, FHStatic(implC), false, fa.pos);
				Calls.buildCall(ctx, AKUsingField({thisExpr: se.thisExpr, access: getterFa}), [], WithTypeTools.value, fa.pos);
			case AKUsingField(se):
				// Reading an abstract/static-extension field: a property calls its impl getter with the
				// receiver; otherwise read the impl field directly.
				var fa = se.access;
				var implC = FieldAccessTools.getHostClassRaise(fa.host);
				var getterCf = implC.statics.get("get_" + fa.field.name);
				if (getterCf != null) {
					var getterFa = FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(implC), fa.pos), getterCf, FHStatic(implC), false, fa.pos);
					Calls.buildCall(ctx, AKUsingField({thisExpr: se.thisExpr, access: getterFa}), [], WithTypeTools.value, fa.pos);
				} else {
					var fieldExpr = FieldAccessTools.getFieldExpr(fa, FGet);
					switch (TypeFunctions.follow(fieldExpr.type)) {
						case TFun(sig) if (sig.args.length > 0):
							var p = fa.pos;
							var receiverType = switch (TypeFunctions.follow(se.thisExpr.type)) {
								case TAbstract(a, tl) if (TypeFunctions.hasClassFieldFlag(fa.field, CfImpl)):
									TypeFunctions.applyParams(a.params, tl, a.thisType);
								case _:
									se.thisExpr.type;
							};
							try TypeUnification.unifyDefault(receiverType, sig.args[0].t) catch (_:Dynamic) {};
							var rest = sig.args.slice(1);
							var ret = sig.ret;
							var tcall = TFun({args: rest, ret: ret});
							var args:Array<TFuncArg> = [];
							var locals:Array<TExpr> = [];
							for (a in rest) {
								var vt = a.opt ? ctx.com.basic.tnull(a.t) : a.t;
								var name = a.name == "" ? "`arg" : a.name;
								var v = TypeFunctions.allocVar(VGenerated, name, vt, p);
								args.push({v: v, c: a.opt ? TypeFunctions.mk(TConst(TNull), vt, p) : null});
								locals.push(TypeFunctions.mk(TLocal(v), vt, p));
							}
							var call = Calls.makeCall(ctx, fieldExpr, [se.thisExpr].concat(locals), ret, p);
							var body = isVoid(TypeFunctions.follow(ret)) ? call : TypeFunctions.mk(TReturn(call), TypeFunctions.tDynamic, p);
							TypeFunctions.mk(TFunction(new TFunc(args, ret, body)), tcall, p);
						case _:
							FieldAccessTools.getFieldExpr(fa, FRead);
					}
				}
			case AKAccess(_, _, _, _, _): throw new TypingError("Abstract array access is not yet ported", Position.nullPos);
			case AKResolve(se, name):
				// A macro resolve method runs at type time with the receiver as syntax and the field name
				// as a string literal; the resolve call goes through the field call, which dispatches macro
				// methods.
				if (se.access.field.kind.match(Method(MethMacro))) {
					var eName = new Expr(EConst(CString(name, SDoubleQuotes)), se.access.pos);
					return hxc.eval.EvalMacro.run(ctx, se.access, [Calls.typedExprToSyntax(ctx, se.thisExpr), eName], WithTypeTools.value, se.access.pos);
				}
				var ce = FieldAccessTools.getFieldExpr(se.access, FCall);
				switch (TypeFunctions.follow(ce.type)) {
					case TFun(sig) if (sig.args.length >= 2):
						var eName = TexprTools.makeString(ctx.com.basic, name, se.access.pos);
						var nameArg = castOrUnify(ctx, sig.args[1].t, eName, eName.pos);
						Calls.makeCall(ctx, ce, Calls.padPosInfos(ctx, sig.args, [se.thisExpr, nameArg], se.access.pos), sig.ret, se.access.pos);
					case _:
						throw new TypingError("Resolve target is not a function", se.access.pos);
				}
			case AKSafeNav(sn):
				var ethen = accGet(ctx, sn.access);
				var t = ctx.com.basic.tnull(ethen.type);
				if (!TypeFunctions.isNull(ethen.type) && !TypeFunctions.isExplicitNull(ethen.type))
					ethen = TypeFunctions.mk(TCast(ethen, null), t, ethen.pos);
				var enullBase = TypeFunctions.mk(TConst(TNull), sn.base.type, sn.pos);
				var econd = TypeFunctions.mk(TBinop(OpNotEq, sn.base, enullBase), ctx.com.basic.tbool, sn.pos);
				var eelse = TypeFunctions.mk(TConst(TNull), t, sn.pos);
				var eif = TypeFunctions.mk(TIf(econd, ethen, eelse), t, sn.pos);
				sn.tempVar == null ? eif : TypeFunctions.mk(TBlock([sn.tempVar, eif]), t, sn.pos);
		};
	}

	// `T.new` is the constructor as a value: a function `(args) -> new T(args)`. Handles a class and a
	// @:forward.new abstract (whose construction forwards to the underlying class).
	static function constructorValue(ctx:TyperContext, e1:Expr, mode:AccessMode, p:Position):Null<AccessKind> {
		var te1 = try typeExpr(ctx, e1, WithTypeTools.value) catch (_:TypingError) return null;
		// An abstract with its own constructor: `A.new` is a closure over the impl `_new` static.
		switch (te1.expr) {
			case TTypeExpr(TAbstractDecl(a)) if (a.impl != null && !TypeFunctions.hasMeta(":forward.new", a.meta) && a.impl.statics.exists("_new")):
				if (mode.match(MSet(_))) throw new TypingError("Cannot set constructor", p);
				if (mode.match(MCall(_))) throw new TypingError("Cannot call constructor like this, use 'new " + hxc.core.Globals.sTypePath(a.path) + "()' instead", p);
				// Building the closure over `_new` can fail for a complex (e.g. inline, generic) ctor; fall
				// back to the normal access path rather than dropping the whole enclosing field.
				return try {
					var newCf = a.impl.statics.get("_new");
					hxc.typing.TypeFields.forceFieldBody(ctx.com, a.impl, newCf);
					var atl:TParams = [for (_ in a.params) TypeFunctions.mkMono()];
					var sig = switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, atl, TypeFunctions.follow(newCf.type)))) { case TFun(s): s; case _: null; };
					if (sig == null) null;
					else {
						var retT = TAbstract(a, atl);
						var vl = [for (arg in sig.args) TypeFunctions.allocVar(VGenerated, arg.name, arg.t, p)];
						var el:Array<TExpr> = [for (v in vl) TexprTools.makeLocal(v, p)];
						var implExpr = TexprTools.makeTypeExpr(TClassDecl(a.impl), p);
						var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, newCf, FHStatic(a.impl), false, p), FCall);
						var call = Calls.makeCall(ctx, fieldExpr, el, retT, p);
						var body = TypeFunctions.mk(TReturn(call), retT, p);
						var tf = new TFunc([for (v in vl) {v: v}], retT, body);
						AKExpr(TypeFunctions.mk(TFunction(tf), TFun({args: sig.args, ret: retT}), p));
					}
				} catch (_:haxe.Exception) null;
			case _:
		}
		// (target class, its params, the value type of `new`, an optional cast target for an abstract)
		var target:Null<{c:TClass, tl:TParams, vt:T, castTo:Null<T>}> = switch (te1.expr) {
			case TTypeExpr(TClassDecl(c)):
				var monos:TParams = [for (_ in c.params) TypeFunctions.mkMono()];
				{c: c, tl: monos, vt: TInst(c, monos), castTo: null};
			case TTypeExpr(TAbstractDecl(a)) if (a.impl != null && TypeFunctions.hasMeta(":forward.new", a.meta)):
				var atl:TParams = [for (_ in a.params) TypeFunctions.mkMono()];
				switch (TypeFunctions.follow(a.thisType)) {
					case TInst(uc, upl): {c: uc, tl: upl, vt: TInst(uc, upl), castTo: TAbstract(a, atl)};
					case _: null;
				}
			case _: null;
		};
		if (target == null) return null;
		if (mode.match(MSet(_))) throw new TypingError("Cannot set constructor", p);
		if (mode.match(MCall(_))) throw new TypingError("Cannot call constructor like this, use 'new " + hxc.core.Globals.sTypePath(target.c.path) + "()' instead", p);
		hxc.eval.EvalMacro.ensureBuilt(ctx.com, target.c);
		// An inherited constructor resolves on the nearest ancestor declaring one, with the ancestor's
		// parameters applied along the chain; none anywhere is "does not have a constructor".
		var ownerC = target.c;
		var ownerTl = target.tl;
		var ctor = ownerC.constructor;
		while (ctor == null && ownerC.superClass != null) {
			var sup = ownerC.superClass;
			ownerTl = [for (t in sup.params) TypeFunctions.applyParams(ownerC.params, ownerTl, t)];
			ownerC = sup.c;
			ctor = ownerC.constructor;
		}
		if (ctor == null)
			throw new TypingError(hxc.core.Globals.sTypePath(target.c.path) + " does not have a constructor", p);
		if (TypeFunctions.hasClassFlag(target.c, CAbstract))
			throw new TypingError(hxc.core.Globals.sTypePath(target.c.path) + " is abstract and cannot be constructed", p);
		hxc.typing.TypeFields.forceFieldBody(ctx.com, ownerC, ctor);
		var sig = switch (TypeFunctions.follow(TypeFunctions.applyParams(ownerC.params, ownerTl, TypeFunctions.follow(ctor.type)))) { case TFun(s): s; case _: return null; };
		var vl = [for (arg in sig.args) TypeFunctions.allocVar(VGenerated, arg.name, arg.t, p)];
		var el:Array<TExpr> = [for (v in vl) TexprTools.makeLocal(v, p)];
		var enew = TypeFunctions.mk(TNew(target.c, target.tl, el), target.vt, p);
		var result = target.castTo == null ? enew : TypeFunctions.mk(TCast(enew, null), target.castTo, p);
		var retT = target.castTo == null ? target.vt : target.castTo;
		var body = TypeFunctions.mk(TReturn(result), retT, p);
		var tf = new TFunc([for (v in vl) {v: v}], retT, body);
		return AKExpr(TypeFunctions.mk(TFunction(tf), TFun({args: sig.args, ret: retT}), p));
	}

	public static function typeAccess(ctx:TyperContext, edef:ExprDef, p:Position, mode:AccessMode, withType:WithType):AccessKind {
		return switch (edef) {
			case EConst(CIdent(s)):
				typeIdent(ctx, s, p, mode, withType);
			case EField(e1, field, EFSafe):
				if (StringTools.startsWith(field, "$")) throw new TypingError("Field names starting with $ are not allowed", p);
				var base = typeExpr(ctx, e1, WithTypeTools.value);
				var safeBase = base;
				var temp:Null<TExpr> = null;
				switch (base.expr) {
					case TLocal(_) | TTypeExpr(_) | TConst(_):
					case _:
						var v = TypeFunctions.allocVar(VGenerated, "`tmp", base.type, base.pos);
						temp = TypeFunctions.mk(TVarExpr(v, base), ctx.com.basic.tvoid, base.pos);
						safeBase = TexprTools.makeLocal(v, base.pos);
				}
				AKSafeNav({pos: p, base: safeBase, tempVar: temp, access: Fields.typeField(ctx, safeBase, field, p, mode, withType)});
			case EField(e1, field, _):
				if (StringTools.startsWith(field, "$")) throw new TypingError("Field names starting with $ are not allowed", p);
				if (field == "new") {
					var cv = constructorValue(ctx, e1, mode, p);
					if (cv != null) return cv;
				}
				switch (e1.expr) {
					case EConst(CString(s, _)) if (field == "code"):
						var cp = singleCodePoint(s);
						if (cp != null) return AKExpr(TypeFunctions.mk(TConst(TInt(cp)), ctx.com.basic.tint, p));
					case EConst(CIdent("super")):
						// `super.field` resolves the field against the superclass with a TSuper receiver, so
						// the call dispatches to the inherited definition rather than an override.
						var sup = ctx.curclass.superClass;
						if (sup == null) throw new TypingError("Current class does not have a super class", p);
						var superExpr = TypeFunctions.mk(TConst(TSuper), TInst(sup.c, sup.params), e1.pos);
						return Fields.typeField(ctx, superExpr, field, p, mode, withType);
					case _:
				}
				try {
					var acc = typeAccess(ctx, e1.expr, e1.pos, MGet, WithTypeTools.value);
					switch (acc) {
						case AKSafeNav(sn):
							AKSafeNav({
								pos: sn.pos,
								base: sn.base,
								tempVar: sn.tempVar,
								access: Fields.typeField(ctx, accGet(ctx, sn.access), field, p, mode, withType)
							});
						case _:
							Fields.typeField(ctx, accGet(ctx, acc), field, p, mode, withType);
					}
				} catch (err:TypingError) {
					var acc = tryTypePath(ctx, EField(e1, field, EFNormal), p, mode, withType);
					if (acc == null) throw err;
					acc;
				}
			case EArray(e1, e2):
				var a1 = typeAccess(ctx, e1.expr, e1.pos, MGet, WithTypeTools.value);
				var te2 = typeExpr(ctx, e2, WithTypeTools.value);
				switch (a1) {
					case AKSafeNav(sn):
						AKSafeNav({
							pos: sn.pos,
							base: sn.base,
							tempVar: sn.tempVar,
							access: Calls.arrayAccess(ctx, accGet(ctx, sn.access), te2, mode, p)
						});
					case _:
						Calls.arrayAccess(ctx, accGet(ctx, a1), te2, mode, p);
				}
			case ECall(e1, params):
				Calls.typeCallAccess(ctx, e1, params, withType, p);
			case _:
				AKExpr(typeExpr(ctx, new Expr(edef, p), withType));
		};
	}

	static function typeBlock(ctx:TyperContext, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		var acc:Array<TExpr> = [];
		function merge(e:TExpr) {
			switch (e.expr) {
				case TMeta(m, inner) if (m.name == ":mergeBlock"):
					switch (inner.expr) {
						case TBlock(el2): for (x in el2) acc.push(x);
						case _: acc.push(e);
					}
				case _: acc.push(e);
			}
		}
		var i = 0;
		while (i < el.length) {
			var wt = (i == el.length - 1) ? withType : WithTypeTools.noValue;
			// A statement that fails to type is recorded and skipped so the rest of the block still types,
			// accumulating multiple errors instead of aborting on the first.
			try {
				merge(typeExpr(ctx, el[i], wt));
			} catch (err:TypingError) {
				ctx.com.addDiagnostic(err.message, err.pos, err.depth);
			}
			i++;
		}
		var t = acc.length == 0 ? ctx.com.basic.tvoid : acc[acc.length - 1].type;
		return TypeFunctions.mk(TBlock(acc), t, p);
	}

	static function typeVars(ctx:TyperContext, vl:Array<EVar>, p:Position):TExpr {
		var basic = ctx.com.basic;
		var out:Array<{v:TVar, e:Null<TExpr>}> = [];
		for (ev in vl) {
			var n = ev.evName.name;
			var pv = ev.evName.pos;
			var t = Typeload.loadTypeHint(ctx.com, ctx.typeParams, ev.evType);
			var e:Null<TExpr> = switch (ev.evExpr) {
				case null: null;
				case ex:
					var oldLoop = ctx.inLoop;
					if (ev.evStatic) ctx.inLoop = false;
					var te = typeExpr(ctx, ex, WithTypeTools.withType(t));
					ctx.inLoop = oldLoop;
					castOrUnify(ctx, t, te, p);
			};
			var v = addLocalWithOrigin(ctx, TVOLocalVariable, n, t, pv);
			v.meta = ev.evMeta;
			if (ev.evFinal) TypeFunctions.addVarFlag(v, VFinal);
			if (ev.evStatic) TypeFunctions.addVarFlag(v, VStatic);
			out.push({v: v, e: e});
		}
		for (ve in out) {
			if (isVoid(TypeFunctions.follow(ve.v.type)))
				throw new TypingError("Variables of type Void are not allowed", ve.v.pos);
		}
		if (out.length == 1) {
			return TypeFunctions.mk(TVarExpr(out[0].v, out[0].e), basic.tvoid, p);
		}
		var block = [for (ve in out) TypeFunctions.mk(TVarExpr(ve.v, ve.e), basic.tvoid, p)];
		var e = TypeFunctions.mk(TBlock(block), basic.tvoid, p);
		return TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: p}, e), e.type, e.pos);
	}

	static function typeIf(ctx:TyperContext, econd:Expr, e1:Expr, e2:Null<Expr>, withType:WithType, isTernary:Bool, p:Position):TExpr {
		var c = typeExpr(ctx, econd, WithTypeTools.value);
		if (isTernary) switch (c.expr) {
			case TConst(TNull): throw new TypingError("Cannot use null as ternary condition", c.pos);
			case _:
		}
		c = castOrUnify(ctx, ctx.com.basic.tbool, c, p);
		var te1 = typeExpr(ctx, Expr.ensureBlock(e1), withType);
		return switch (e2) {
			case null: TypeFunctions.mk(TIf(c, te1, null), ctx.com.basic.tvoid, p);
			case ex2:
				var te2 = typeExpr(ctx, Expr.ensureBlock(ex2), withType);
				makeIfThenElse(ctx, c, te1, te2, withType, p);
		};
	}

	public static function makeIfThenElse(ctx:TyperContext, e0:TExpr, e1:TExpr, e2:TExpr, withType:WithType, p:Position):TExpr {
		var t:T;
		switch (withType) {
			case NoValue:
				t = ctx.com.basic.tvoid;
			case Value(_):
				t = unifyMin(ctx, [e1, e2]);
			case WithType(tt, src):
				var ft = TypeFunctions.follow(tt);
				var useMin = switch (ft) {
					case TMono(_): true;
					case _: isVoid(ft);
				};
				if (useMin) {
					t = unifyMinForTypeSource(ctx, [e1, e2], src);
				} else {
					e1 = castOrUnify(ctx, tt, e1, e1.pos);
					e2 = castOrUnify(ctx, tt, e2, e2.pos);
					t = tt;
				}
		}
		return TypeFunctions.mk(TIf(e0, e1, e2), t, p);
	}

	static function typeReturn(ctx:TyperContext, e:Null<Expr>, withType:WithType, p:Position):TExpr {
		switch (e) {
			case null:
				var v = ctx.com.basic.tvoid;
				try {
					TypeUnification.unifyDefault(v, ctx.ret);
				} catch (_:UnifyError) {
					throw new TypingError("Void should be " + "the function's return type", p);
				}
				var expectVoid = switch (withType) {
					case WithType(t, _): isVoid(t);
					case Value(ImplicitReturn): true;
					case _: false;
				};
				return TypeFunctions.mk(TReturn(null), expectVoid ? v : monoOrDynamic(ctx, withType, p), p);
			case ex:
				var withExpected = isVoid(TypeFunctions.follow(ctx.ret)) ? WithTypeTools.noValue : WithTypeTools.withType(ctx.ret);
				var teRaw = typeExpr(ctx, ex, withExpected);
				// Returning a value from a Void function discards the value rather than unifying it.
				// ctx.ret may only just have settled to Void while typing teRaw (an inner `return` in an
				// unannotated arrow whose return mono that branch binds), so re-check here, not only up
				// front. `return null` is exempt: it stays a type error ("Cannot return null from
				// Void-function"), handled by the value path below.
				if (isVoid(TypeFunctions.follow(ctx.ret)) && !isVoid(TypeFunctions.follow(teRaw.type)) && !teRaw.expr.match(TConst(TNull))) {
					var vt = monoOrDynamic(ctx, withType, p);
					return TypeFunctions.mk(TBlock([teRaw, TypeFunctions.mk(TReturn(null), vt, p)]), vt, teRaw.pos);
				}
				switch (ex.expr) {
					case EUntyped(_):
						return TypeFunctions.mk(TReturn(TypeFunctions.mk(TCast(teRaw, null), ctx.ret, teRaw.pos)), monoOrDynamic(ctx, withType, p), p);
					case _:
				}
				var te = castOrUnify(ctx, ctx.ret, teRaw, p);
				if (isVoid(TypeFunctions.follow(te.type))) {
					switch (te.expr) {
						case TConst(TNull): throw new TypingError("Cannot return null from Void-function", p);
						case _:
					}
					var t = monoOrDynamic(ctx, withType, p);
					return TypeFunctions.mk(TBlock([te, TypeFunctions.mk(TReturn(null), t, p)]), t, te.pos);
				}
				return TypeFunctions.mk(TReturn(te), monoOrDynamic(ctx, withType, p), p);
		}
	}

	public static function typeFunction(ctx:TyperContext, args:Array<TFuncArg>, ret:T, fmode:CurrentFun, bodyExpr:Null<Expr>, p:Position):TFunc {
		var oldInFunction = ctx.inFunction;
		var oldCurfun = ctx.curfun;
		var oldRet = ctx.ret;
		var oldLoop = ctx.inLoop;
		var restore = saveLocals(ctx);
		ctx.inFunction = true;
		ctx.curfun = fmode;
		ctx.ret = ret;
		ctx.inLoop = false;
		for (a in args) ctx.locals.set(a.v.name, a.v);
		function reset() {
			restore();
			ctx.inFunction = oldInFunction;
			ctx.curfun = oldCurfun;
			ctx.ret = oldRet;
			ctx.inLoop = oldLoop;
		}
		if (bodyExpr == null) {
			reset();
			throw new TypingError("Function body required", p);
		}
		var te = try typeExpr(ctx, bodyExpr, WithTypeTools.noValue) catch (e:TypingError) {
			reset();
			throw e;
		}
		// An inferred return type with no value-return settles to Void.
		switch (TypeFunctions.follow(ret)) {
			case TMono(_) if (!hasReturn(te)):
				try TypeUnification.unifyDefault(ctx.com.basic.tvoid, ret) catch (_:UnifyError) {}
			case _:
		}
		reset();
		return new TFunc(args, ret, te);
	}

	// A class without its own constructor inherits the nearest superclass constructor, with the superclass
	// type arguments substituted along the inheritance chain. Generate a constructor for a @:structInit
	// class that lacks one, from its physical var fields (one argument per field, assigned to it),
	// threading the superclass constructor for inheritance. / get_struct_init_super_info.
	static function ensureStructInitCtor(ctx:TyperContext, c:TClass):Void {
		if (c.constructor != null) return;
		if (!TypeFunctions.hasMeta(":structInit", c.meta)) return;
		var params = TypeFunctions.extractParamTypes(c.params);
		var tvoid = ctx.com.basic.tvoid;
		var tthis = TypeFunctions.mk(TConst(TThis), TInst(c, params), c.pos);
		var args:Array<TFuncArg> = [];
		var sigArgs:Array<TSignatureArg> = [];
		var body:Array<TExpr> = [];
		for (cf in c.orderedFields) {
			var physical = switch (cf.kind) {
				case Var(k): switch (k.read) { case AccCall | AccInline | AccRequire(_, _): false; case _: switch (k.write) { case AccCall: false; case _: true; } };
				case _: false;
			};
			if (!physical) continue;
			switch (cf.type) { case TLazy(r): cf.type = TypeFunctions.lazyType(r); case _: }
			var opt = TypeFunctions.hasMeta(":optional", cf.meta);
			var at = opt ? ctx.com.basic.tnull(cf.type) : cf.type;
			var v = TypeFunctions.allocVar(VGenerated, cf.name, at, cf.namePos);
			args.push({v: v});
			sigArgs.push({name: cf.name, opt: opt, t: at});
			var ef = TypeFunctions.mk(TField(tthis, FInstance(c, params, cf)), cf.type, cf.pos);
			var ev = TypeFunctions.mk(TLocal(v), v.type, cf.pos);
			body.push(TypeFunctions.mk(TBinop(OpAssign, ef, ev), cf.type, cf.pos));
		}
		if (c.superClass != null) {
			ensureStructInitCtor(ctx, c.superClass.c);
			if (c.superClass.c.constructor != null) {
				var st = TypeFunctions.applyParams(c.superClass.c.params, c.superClass.params, c.superClass.c.constructor.type);
				switch (TypeFunctions.follow(st)) {
					case TFun(ssig):
						var superLocals:Array<TExpr> = [];
						for (sa in ssig.args) {
							var sv = TypeFunctions.allocVar(VGenerated, sa.name, sa.t, c.pos);
							args.push({v: sv});
							sigArgs.push({name: sa.name, opt: sa.opt, t: sa.t});
							superLocals.push(TypeFunctions.mk(TLocal(sv), sa.t, c.pos));
						}
						var superCallee = TypeFunctions.mk(TConst(TSuper), TInst(c.superClass.c, c.superClass.params), c.pos);
						body.unshift(TypeFunctions.mk(TCall(superCallee, superLocals), tvoid, c.pos));
					case _:
				}
			}
		}
		var tf = new TFunc(args, tvoid, TypeFunctions.mk(TBlock(body), tvoid, c.pos));
		var ctorType = TFun({args: sigArgs, ret: tvoid});
		var cfCtor = TypeFunctions.mkField("new", ctorType, c.pos, c.pos);
		cfCtor.kind = Method(MethNormal);
		cfCtor.expr = TypeFunctions.mk(TFunction(tf), ctorType, c.pos);
		c.constructor = cfCtor;
	}

	static function findConstructorType(ctx:TyperContext, c:TClass, tl:TParams):Null<T> {
		var all = findConstructorTypes(ctx, c, tl);
		return all.length == 0 ? null : all[0];
	}

	// The primary constructor type plus its @:overload variants, class params applied (overloads are
	// expanded for the call-site retry).
	static function findConstructorTypes(ctx:TyperContext, c:TClass, tl:TParams):Array<T> {
		var cur = c;
		var curTl = tl;
		while (cur != null) {
			ensureStructInitCtor(ctx, cur);
			if (cur.constructor != null) {
				var cf = cur.constructor;
				var curTl2 = curTl;
				var curCl = cur;
				inline function apply(t:T):T return TypeFunctions.applyParams(curCl.params, curTl2, t);
				return [apply(cf.type)].concat([for (o in cf.overloads) apply(o.type)]);
			}
			if (cur.superClass == null) return [];
			hxc.eval.EvalMacro.ensureBuilt(ctx.com, cur.superClass.c);
			var superTl = [for (sp in cur.superClass.params) TypeFunctions.applyParams(cur.params, curTl, sp)];
			cur = cur.superClass.c;
			curTl = superTl;
		}
		return [];
	}

	static function hasTypeParameter(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, params):
				switch (c.kind) {
					case KTypeParameter(_): true;
					case _: hasTypeParameterParams(params);
				}
			case TEnum(_, params) | TType(_, params) | TAbstract(_, params):
				hasTypeParameterParams(params);
			case TFun(sig):
				for (arg in sig.args) if (hasTypeParameter(arg.t)) return true;
				hasTypeParameter(sig.ret);
			case TAnon(a):
				for (name in a.fields.keys()) if (hasTypeParameter(a.fields.get(name).type)) return true;
				false;
			case TLazy(f):
				hasTypeParameter(TypeFunctions.lazyType(f));
			case TDynamic(t):
				t != null && hasTypeParameter(t);
			case TMono(_):
				false;
		}
	}

	static function hasTypeParameterParams(params:Array<T>):Bool {
		for (t in params) if (hasTypeParameter(t)) return true;
		return false;
	}

	// Construct a value of the underlying type a @:forward.new abstract forwards to: a class via its
	// constructor, an abstract via its _new impl, or a nested @:forward.new abstract by recursing on
	// its underlying. .
	static function constructForwarded(ctx:TyperContext, t:T, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		return switch (TypeFunctions.follow(t)) {
			case TInst(uc, upl):
				hxc.eval.EvalMacro.ensureBuilt(ctx.com, uc);
				var ctorType = findConstructorType(ctx, uc, upl);
				if (ctorType == null) throw new TypingError(uc.path.name + " does not have a constructor", p);
				var sig = switch (TypeFunctions.follow(ctorType)) { case TFun(s): s; case _: {args: [], ret: ctx.com.basic.tvoid}; };
				var r = Calls.unifyCallArgs(ctx, el, sig.args, sig.ret, p);
				TypeFunctions.mk(TNew(uc, upl, r.el), TInst(uc, upl), p);
			case TAbstract(ua, ual) if (ua.impl != null && ua.impl.statics.exists("_new")):
				var newCf = ua.impl.statics.get("_new");
				TypeFields.forceFieldBody(ctx.com, ua.impl, newCf);
				var implExpr = TexprTools.makeTypeExpr(TClassDecl(ua.impl), p);
				var fa = FieldAccessTools.create(implExpr, newCf, FHAbstract(ua, ual, ua.impl), false, p);
				Calls.buildCall(ctx, AKField(fa), el, withType, p);
			case TAbstract(ua, ual) if (ua.impl != null && TypeFunctions.hasMeta(":forward.new", ua.meta)):
				var inner = constructForwarded(ctx, TypeFunctions.applyParams(ua.params, ual, ua.thisType), el, withType, p);
				TypeFunctions.mk(TCast(inner, null), TAbstract(ua, ual), p);
			case _:
				throw new TypingError("This type cannot be constructed", p);
		};
	}

	public static function typeNew(ctx:TyperContext, tp:PlacedTypePath, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		var t:T;
		if (tp.path.tparams.length == 0) {
			ctx.com.callArgumentStack.unshift(el);
			try {
				t = Typeload.loadInstance(ctx.com, ctx.typeParams, tp.path, tp.pos, true);
				ctx.com.callArgumentStack.shift();
			} catch (e:Dynamic) {
				ctx.com.callArgumentStack.shift();
				throw e;
			}
		} else {
			t = Typeload.loadInstance(ctx.com, ctx.typeParams, tp.path, tp.pos, false);
		}
		return switch (TypeFunctions.follow(t)) {
				case TInst(c, params) if (c.kind.match(KTypeParameter(_))):
					// New T() on a generic type parameter resolves the constructor from a constructible
					// constraint.
					if (!isGenericParameter(ctx, c)) throw new TypingError("Only generic type parameters can be constructed", p);
					var ctl = switch (c.kind) { case KTypeParameter(x): x; case _: []; };
					switch (getConstructibleConstraint(ctx, ctl, p)) {
						case null: throw new TypingError(c.path.name + " does not have a constructor", p);
						case cc:
							var r = Calls.unifyCallArgs(ctx, el, cc.args, cc.ret, p);
							TypeFunctions.mk(TNew(c, params, r.el), t, p);
					}
			case TInst(c, tl):
				var tl = switch (c.kind) {
					case KGeneric if (tp.path.tparams.length == 0 && hasTypeParameterParams(tl)):
						TypeUnification.spawnConstrainedMonos(function(t) return t, c.params);
					case _:
						tl;
				}
				var t = TInst(c, tl);
				// An abstract class has no direct construction.
				if (TypeFunctions.hasClassFlag(c, CAbstract))
					throw new TypingError(hxc.core.Globals.sTypePath(c.path) + " is abstract and cannot be constructed", p);
				hxc.eval.EvalMacro.ensureBuilt(ctx.com, c);
				// Force the constructor body so its unannotated param types are inferred from the body (e.g.
				// `new(x) this.x = x` gives x the field type) before call args are unified against them; else
				// the
				// first call site binds those still-open param monos to its arg types, corrupting later
				// constructions.
				if (c.constructor != null) TypeFields.forceFieldBody(ctx.com, c, c.constructor);
				var ctorTypes = findConstructorTypes(ctx, c, tl);
				if (ctorTypes.length == 0) throw new TypingError(c.path.name + " does not have a constructor", p);
				if (c.constructor != null) Fields.checkConstructorAccess(ctx, c, c.constructor, p);
				// Try each constructor signature, first success wins (overload retry).
				var r:Dynamic = null;
				var firstError:Null<Dynamic> = null;
				for (ctorType in ctorTypes) {
					var sig = switch (TypeFunctions.follow(ctorType)) {
						case TFun(s): s;
						case _: {args: [], ret: ctx.com.basic.tvoid};
					};
					try {
						r = TypeUnification.withMonoRollback(function() return Calls.unifyCallArgs(ctx, el, sig.args, sig.ret, p));
						break;
					} catch (e:hxc.core.TypeUnification.UnifyError) {
						if (firstError == null) firstError = e;
					} catch (e:TypingError) {
						if (firstError == null) firstError = e;
					}
				}
				if (r == null) throw (firstError != null ? firstError : new TypingError("No matching overload", p));
				switch (c.kind) {
					case KGeneric if (!TypeFunctions.hasMono(TInst(c, tl))):
						var gc = Typeload.specializeGenericClass(ctx.com, c, tl, p);
						TypeFunctions.mk(TNew(gc, [], r.el), TInst(gc, []), p);
					case KGeneric:
						// Parameters not inferable from the arguments: an expected type that is already a
						// specialization of this class is used directly. .
						var fromExpected = switch (withType) {
							case WithType(wt, _):
								switch (TypeFunctions.follow(wt)) {
									case TInst(gc2, tl2):
										switch (gc2.kind) {
											case KGenericInstance(base, _) if (base == c): TypeFunctions.mk(TNew(gc2, tl2, r.el), TInst(gc2, tl2), p);
											case _: null;
										}
									case _: null;
								}
							case _: null;
						};
						fromExpected != null ? fromExpected : TypeFunctions.mk(TNew(c, tl, r.el), t, p);
					case _:
						TypeFunctions.mk(TNew(c, tl, r.el), t, p);
				}
			case TAbstract(a, atl) if (TypeFunctions.hasMeta(":multiType", a.meta)):
				// A @:multiType abstract (Map) picks a concrete implementation by unifying the key type
				// against each @:to cast's key-parameter constraint, then constructs that type. The
				// expression is typed as the abstract (Map) so it unifies with Map-typed targets; the
				// concrete type is only the constructed runtime value (field access goes through the
				// abstract impl).
				var usedAtl = atl.length == 0 && tp.path.tparams.length == 0
					? [for (_ in a.params) spawnMonomorph(ctx, p)]
					: atl;
				if (tp.path.tparams.length == 0) switch (withType) {
					case WithType(wt, _):
						switch (TypeFunctions.follow(wt)) {
							case TAbstract(wa, wtl) if (wa == a && wtl.length == a.params.length):
								usedAtl = wtl;
							case _:
						}
					case _:
				}
				var ctorSelection = selectMultiTypeByCtorArgs(ctx, a, usedAtl, el, p);
				if (ctorSelection != null) {
					return buildMultiTypeCastCall(ctx, a, usedAtl, ctorSelection.castField, ctorSelection.castType, ctorSelection.ret, ctorSelection.args, p);
				}
				if (a.impl != null && multiTypeHasOpenSelector(a, usedAtl)) {
					var sig = switch (a.impl.statics.get("_new")) {
						case null:
							{args: [], ret: ctx.com.basic.tvoid};
						case newCf:
							TypeFields.forceFieldBody(ctx.com, a.impl, newCf);
							var newType = TypeFunctions.applyParams(a.params, usedAtl, newCf.type);
							switch (TypeFunctions.follow(newType)) {
								case TFun(s): s;
								case _: {args: [], ret: ctx.com.basic.tvoid};
							}
					}
					var r = Calls.unifyCallArgs(ctx, el, sig.args, sig.ret, p);
					return TypeFunctions.mk(TNew(a.impl, usedAtl, r.el), TAbstract(a, usedAtl), p);
				}
				var selection = resolveMultiType(ctx, a, usedAtl, p);
				return buildMultiTypeCastCall(ctx, a, usedAtl, selection.castField, selection.castType, selection.ret, [], p);
			case TAbstract(a, atl) if (a.impl != null && a.impl.statics.exists("_new")):
				// An abstract is constructed by calling its impl _new static, with the abstract type
				// parameters applied so a generic abstract threads them (a rigid type parameter would
				// otherwise fail to unify against the arguments).
				var newCf = a.impl.statics.get("_new");
				TypeFields.forceFieldBody(ctx.com, a.impl, newCf);
				var implExpr = TexprTools.makeTypeExpr(TClassDecl(a.impl), p);
				var fa = FieldAccessTools.create(implExpr, newCf, FHAbstract(a, atl, a.impl), false, p);
				Calls.buildCall(ctx, AKField(fa), el, withType, p);
			case TAbstract(a, atl) if (a.impl != null && TypeFunctions.hasMeta(":forward.new", a.meta)):
				// @:forward.new forwards construction to the underlying type: build the underlying value
				// and cast it to the abstract. . Apply the abstract's type arguments so `new
				// Foo<Array<Int>>()` forwards to Array's constructor (not the bare type parameter T) and a
				// `new Foo<Bar>()` / `new Foo<Foo<_>>()` forwards into the underlying abstract's own
				// constructor.
				var enew = constructForwarded(ctx, TypeFunctions.applyParams(a.params, atl, a.thisType), el, withType, p);
				TypeFunctions.mk(TCast(enew, null), TAbstract(a, atl), p);
			case _:
				throw new TypingError("This type cannot be constructed", p);
		};
	}

	static function typeMapDeclaration(ctx:TyperContext, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		var mapParams = switch (withType) {
			case WithType(wt, _): getMapParams(ctx, wt);
			case _: null;
		};
		var tkey = mapParams == null ? spawnMonomorph(ctx, p) : mapParams.k;
		var tval = mapParams == null ? spawnMonomorph(ctx, p) : mapParams.v;
		var keys:Array<TExpr> = [];
		var values:Array<TExpr> = [];
		// A repeated constant key is an error.
		var seenKeys:Array<TExpr> = [];
		function checkKey(k:TExpr):Void {
			switch (k.expr) {
				case TConst(c):
					for (prev in seenKeys) if (std.Type.enumEq(prev.expr, k.expr)) throw new TypingError("Duplicate key", k.pos);
					seenKeys.push(k);
				case _:
			}
		}
		for (e in el) switch (e.expr) {
			case EBinop(OpArrow, k, v):
				if (mapParams == null) {
					var tk = typeExpr(ctx, k, WithTypeTools.value);
					checkKey(tk);
					keys.push(tk);
					values.push(typeExpr(ctx, v, WithTypeTools.value));
				} else {
					var tk = typeExpr(ctx, k, WithTypeTools.withType(tkey));
					checkKey(tk);
					var tv = typeExpr(ctx, v, WithTypeTools.withType(tval));
					keys.push(castOrUnify(ctx, tkey, tk, tk.pos));
					values.push(castOrUnify(ctx, tval, tv, tv.pos));
				}
			case _:
				throw new TypingError("Invalid map literal entry", e.pos);
		}
		if (mapParams == null) {
			tkey = unifyMinRaise(ctx, keys);
			tval = unifyMinRaise(ctx, values);
		}
		var mt = Typeload.resolveTypePath(ctx.com, {pack: ["haxe", "ds"], name: "Map"}, null, p);
		TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module);
		var a = switch (mt) {
			case TAbstractDecl(ab): ab;
			case _: throw new TypingError("Map is not an abstract", p);
		};
		var impl = a.impl;
		if (impl == null) throw new TypingError("Map has no implementation", p);
		var tmap = TAbstract(a, [tkey, tval]);
		var tmp = TypeFunctions.allocVar(VUser(TVOLocalVariable), "`map", tmap, p);
		var local = TypeFunctions.mk(TLocal(tmp), tmap, p);
		var newMap = TypeFunctions.mk(TNew(impl, [tkey, tval], []), tmap, p);
		var setCf = impl.statics.get("set");
		if (setCf == null) throw new TypingError("Map.set is not available", p);
		var setExpr = TypeFunctions.mk(TField(TexprTools.makeTypeExpr(TClassDecl(impl), p), FStatic(impl, setCf)),
			TFun({args: [{name: "this", opt: false, t: tmap}, {name: "key", opt: false, t: tkey}, {name: "value", opt: false, t: tval}], ret: ctx.com.basic.tvoid}), p);
		var block:Array<TExpr> = [TypeFunctions.mk(TVarExpr(tmp, newMap), ctx.com.basic.tvoid, p)];
		for (i in 0...keys.length)
			block.push(Calls.makeCall(ctx, setExpr, [local, keys[i], values[i]], ctx.com.basic.tvoid, p));
		block.push(local);
		return TypeFunctions.mk(TBlock(block), tmap, p);
	}

	static function getMapParams(ctx:TyperContext, t:T):Null<{k:T, v:T}> {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, [tk, tv]) if (a.path.pack.join(".") == "haxe.ds" && a.path.name == "Map"):
				{k: tk, v: tv};
			case TInst(c, [tv]) if (c.path.pack.join(".") == "haxe.ds" && c.path.name == "StringMap"):
				{k: ctx.com.basic.tstring, v: tv};
			case TInst(c, [tv]) if (c.path.pack.join(".") == "haxe.ds" && c.path.name == "IntMap"):
				{k: ctx.com.basic.tint, v: tv};
			case TInst(c, [tk, tv]) if (c.path.pack.join(".") == "haxe.ds" && (c.path.name == "ObjectMap" || c.path.name == "EnumValueMap")):
				{k: tk, v: tv};
			case _:
				null;
		};
	}

	// Select a @:multiType abstract's concrete implementation: the first @:to cast whose key
	// type-parameter constraint is satisfied by the actual key type, with the concrete return
	// type specialized to the actual type parameters.
	static function resolveMultiType(ctx:TyperContext, a:TAbstract, atl:Array<T>, p:Position):{castField:TAbstractCast, castType:T, ret:T} {
		return resolveMultiTypeSelection(a, atl, p);
	}

	public static function resolveMultiTypeConcrete(a:TAbstract, atl:Array<T>, p:Position):T {
		return resolveMultiTypeSelection(a, atl, p).ret;
	}

	static function resolveMultiTypeSelection(a:TAbstract, atl:Array<T>, p:Position):{castField:TAbstractCast, castType:T, ret:T} {
		// Follow an abstract key to its underlying type so a key like `enum abstract Foo(String)` selects
		// the impl for its underlying (StringMap), matching the reference.
		var key = atl.length > 0 ? TypeFunctions.followWithAbstracts(atl[0]) : TypeFunctions.tDynamic;
		if (TypeFunctions.hasMono(key))
			throw new TypingError("Type parameters of multi type abstracts must be known", p);
		for (toCast in a.toField) {
			var cf = toCast.cf;
			if (cf.params.length == 0) {
				if (a.params.length == 0) {
					var castType = applyMultiTypeCastType(a, atl, cf);
					return {castField: toCast, castType: castType, ret: TypeFunctions.follow(toCast.t)};
				}
				continue;
			}
			// An unconstrained key parameter accepts any key (the fallback impl, e.g. ObjectMap).
			var constraints = multiTypeConstraints(cf.params[0]);
			var ok = true;
			for (cn in constraints) if (!tryUnifyMulti(key, cn)) { ok = false; break; }
			if (ok) {
				var castType = applyMultiTypeCastType(a, atl, cf);
				return {castField: toCast, castType: castType, ret: TypeFunctions.applyParams(cf.params, atl, toCast.t)};
			}
		}
		throw new TypingError("Cannot resolve multi-type for " + a.path.name, p);
	}

	static function applyMultiTypeCastType(a:TAbstract, atl:Array<T>, cf:TClassField):T {
		var t = cf.type;
		if (cf.params.length > 0) {
			var params = cf.params.length == atl.length ? atl : [for (_ in cf.params) TypeFunctions.mkMono()];
			t = TypeFunctions.applyParams(cf.params, params, t);
		}
		if (a.params.length > 0) t = TypeFunctions.applyParams(a.params, atl, t);
		return t;
	}

	static function selectMultiTypeByCtorArgs(ctx:TyperContext, a:TAbstract, atl:Array<T>, el:Array<Expr>, p:Position):Null<{castField:TAbstractCast, castType:T, ret:T, args:Array<TExpr>}> {
		if (el.length == 0) return null;
		var typedArgs = [for (e in el) typeExpr(ctx, e, WithTypeTools.value)];
		for (toCast in a.toField) {
			var found = try TypeUnification.withMonoRollback(function() {
				var castType = applyMultiTypeCastType(a, atl, toCast.cf);
				return switch (TypeFunctions.follow(castType)) {
					case TFun(sig) if (sig.args.length == typedArgs.length + 1):
						var receiver = TypeFunctions.applyParams(a.params, atl, a.thisType);
						TypeUnification.unifyDefault(receiver, sig.args[0].t);
						var args:Array<TExpr> = [];
						for (i in 0...typedArgs.length) {
							args.push(castOrUnify(ctx, sig.args[i + 1].t, typedArgs[i], typedArgs[i].pos));
						}
						{castField: toCast, castType: castType, ret: sig.ret, args: args};
					case _:
						throw new TypingError("No matching multi-type constructor", p);
				}
			}) catch (_:haxe.Exception) null;
			if (found != null) return found;
		}
		return null;
	}

	static function buildMultiTypeCastCall(ctx:TyperContext, a:TAbstract, atl:Array<T>, castField:TAbstractCast, castType:T, ret:T, args:Array<TExpr>, p:Position):TExpr {
		if (a.impl == null) throw new TypingError("Cannot construct multi-type abstract " + a.path.name, p);
		var cf = a.impl.statics.exists(castField.cf.name) ? a.impl.statics.get(castField.cf.name) : castField.cf;
		TypeFields.forceFieldBody(ctx.com, a.impl, cf);
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(a.impl), p);
		var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(a.impl), false, p), FCall);
		var callee = TypeFunctions.mk(fieldExpr.expr, castType, fieldExpr.pos);
		var receiver = TexprTools.makeNull(TAbstract(a, atl), p);
		var call = Calls.makeCall(ctx, callee, [receiver].concat(args), ret, p);
		return TypeFunctions.mk(call.expr, TAbstract(a, atl), p);
	}

	static function multiTypeHasOpenSelector(a:TAbstract, atl:Array<T>):Bool {
		if (atl.length == 0) return false;
		var selector = TypeFunctions.followWithAbstracts(atl[0]);
		if (TypeFunctions.hasMono(selector)) return true;
		return switch (TypeFunctions.follow(selector)) {
			case TInst(c, _): switch (c.kind) { case KTypeParameter(_): true; case _: false; }
			case _: false;
		};
	}

	static function multiTypeConstraints(ttp:TypedTypeParam):Array<T> {
		return switch (TypeFunctions.follow(ttp.type)) {
			case TInst(c, _): switch (c.kind) { case KTypeParameter(tl): tl; case _: []; };
			case _: [];
		};
	}

	static function tryUnifyMulti(a:T, b:T):Bool {
		return try TypeUnification.withMonoRollback(function() {
			TypeUnification.unifyDefault(a, b);
			return true;
		}) catch (_:UnifyError) false;
	}

	static function hasReturn(e:TExpr):Bool {
		return switch (e.expr) {
			case TReturn(eo): eo != null;
			case TFunction(_) | TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_): false;
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2): hasReturn(e1) || hasReturn(e2);
			case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TThrow(e1) | TCast(e1, _) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1): hasReturn(e1);
			case TVarExpr(_, eo): eo != null && hasReturn(eo);
			case TObjectDecl(fields): Lambda.exists(fields, f -> hasReturn(f.expr));
			case TArrayDecl(el) | TBlock(el): Lambda.exists(el, hasReturn);
			case TCall(e1, el): hasReturn(e1) || Lambda.exists(el, hasReturn);
			case TNew(_, _, el): Lambda.exists(el, hasReturn);
			case TIf(e1, e2, e3): hasReturn(e1) || hasReturn(e2) || (e3 != null && hasReturn(e3));
			case TWhile(e1, e2, _): hasReturn(e1) || hasReturn(e2);
			case TSwitch(e1, cases, edef): hasReturn(e1) || Lambda.exists(cases, c -> Lambda.exists(c.values, hasReturn) || hasReturn(c.expr)) || (edef != null && hasReturn(edef));
			case TTry(e1, catches): hasReturn(e1) || Lambda.exists(catches, c -> hasReturn(c.expr));
		};
	}

	// Whether evaluating the expression can cause a side effect (assignment, increment, call, allocation,
	// control flow). Object-literal @:structInit field initializers that follow a side-effecting field are
	// hoisted into temp vars so they still evaluate in source order. Conservative (does not model @:pure).
	public static function hasSideEffect(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TIdent(_): false;
			case TNew(_, _, _) | TCall(_, _) | TReturn(_) | TBreak | TContinue | TThrow(_): true;
			case TBinop(OpAssign | OpAssignOp(_), _, _): true;
			case TUnop(Increment | Decrement, _, _): true;
			case TCast(e1, mt): mt != null || hasSideEffect(e1);
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2): hasSideEffect(e1) || hasSideEffect(e2);
			case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1): hasSideEffect(e1);
			case TVarExpr(_, eo): eo != null && hasSideEffect(eo);
			case TObjectDecl(fields): Lambda.exists(fields, f -> hasSideEffect(f.expr));
			case TArrayDecl(el) | TBlock(el): Lambda.exists(el, hasSideEffect);
			case TIf(e1, e2, e3): hasSideEffect(e1) || hasSideEffect(e2) || (e3 != null && hasSideEffect(e3));
			case TWhile(e1, e2, _): hasSideEffect(e1) || hasSideEffect(e2);
			case TSwitch(e1, cases, edef): hasSideEffect(e1) || Lambda.exists(cases, c -> Lambda.exists(c.values, hasSideEffect) || hasSideEffect(c.expr)) || (edef != null && hasSideEffect(edef));
			case TTry(e1, catches): hasSideEffect(e1) || Lambda.exists(catches, c -> hasSideEffect(c.expr));
		};
	}
}
