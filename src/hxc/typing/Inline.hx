package hxc.typing;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.typing.TyperContext;
import hxc.typing.TypeFields;

// Falling back to a normal TCall whenever a construct is outside the handled subset. Exact
// in result for what it handles, safe otherwise.
private class InlineBail extends haxe.Exception {
	public function new() super("inline-bail");
}

// Compile-time expansion of inline-function calls, a safe subset ported It handles expression-bodied inline
// functions (single or final return, no early returns, no nested switch/try/closures, no type parameters):
// arguments and `this` bind to fresh locals and the body is substituted in place. Anything else bails and
// the caller emits a normal call. Types in the inlined body are left as-is (the evaluator runs the result
// without re-typing, so values stay correct).
class Inline {
	static var depth = 0;

	public static function tryInline(ctx:TyperContext, e:TExpr, params:Array<TExpr>, tret:T, p:Position):Null<TExpr> {
		if (depth > 32) return null;
		var cf:TClassField = null;
		var c:Null<TClass> = null;
		var ethis:Null<TExpr> = null;
		var isStatic = false;
		switch (e.expr) {
			case TField(et, fa):
				switch (fa) {
					case FStatic(cc, f): c = cc; cf = f; isStatic = true;
					case FInstance(cc, _, f): c = cc; cf = f; ethis = et;
					case FClosure(cwp, f): c = cwp == null ? null : cwp.c; cf = f; ethis = et;
					case FAnon(f): cf = f; ethis = et;
					case _: return null;
				}
			case _:
				return null;
		}
		switch (cf.kind) {
			case Method(MethInline):
			case _: return null;
		}
		// A method's own type parameters do not affect the inlined value: the evaluator runs the body
		// without re-typing, so the substitution proceeds with the body types left as-is (the params
		// would only matter for the return type, which the evaluator does not need).
		// Force the callee's body to be typed first: it may live in a module that has not been
		// installed yet, so type it on demand from its owning class, then follow the lazy as a backstop.
		if (c != null) TypeFields.forceFieldBody(ctx.com, c, cf);
		TypeFunctions.follow(cf.type);
		var body = cf.expr;
		if (body == null) return null;
		var tf = switch (body.expr) {
			case TFunction(f): f;
			case _: return null;
		};
		if (tf.args.length != params.length) return null;
		// An abstract instance member (CfImpl) is an impl static whose first arg is the abstract `this`;
		// a mutation of `this` must write back to an lvalue receiver.
		var absMember = TypeFunctions.hasClassFieldFlag(cf, CfImpl);
		// The type-substitution config. An abstract implementation static maps through the abstract's
		// parameters taken from the receiver argument everything else through inline_default_config on
		// the receiver type.
		var cfg = if (absMember && c != null && c.kind.match(KAbstractImpl(_))) {
			var t = cf.name == "_new" ? tret : (params.length == 0 ? null : TypeFunctions.follow(params[0].type));
			switch (t) {
				case TAbstract(a, pl):
					var monos:TParams = [for (_ in cf.params) TypeFunctions.mkMono()];
					{
						hasParams: a.params.length > 0 || cf.params.length > 0,
						mapType: function(t2:T):T return TypeFunctions.applyParams(a.params, pl, TypeFunctions.applyParams(cf.params, monos, t2))
					};
				case _:
					inlineDefaultConfig(cf, ethis == null ? TypeFunctions.tDynamic : ethis.type);
			}
		} else inlineDefaultConfig(cf, ethis == null ? TypeFunctions.tDynamic : ethis.type);
		depth++;
		var r = try doInline(ctx, cf, cfg, tf, ethis, isStatic, params, tret, absMember, p) catch (_:InlineBail) null;
		depth--;
		return r;
	}

	// The receiver class's parameters including the superclass chain, paired with the actual types
	// they are applied to.
	static function getChainParams(c:TClass, pl:TParams):{params:TypeParams, tl:TParams} {
		if (c.superClass == null) return {params: c.params, tl: pl};
		var spl = switch (TypeFunctions.applyParams(c.params, pl, TInst(c.superClass.c, c.superClass.params))) {
			case TInst(_, pl2): pl2;
			case _: throw new InlineBail();
		};
		var up = getChainParams(c.superClass.c, spl);
		return {params: c.params.concat(up.params), tl: pl.concat(up.tl)};
	}

	static function configLoop(t:T):{params:TypeParams, tl:TParams} {
		return switch (TypeFunctions.follow(t)) {
			case TInst({kind: KTypeParameter(constraints)}, _):
				var ps:TypeParams = [];
				var ts:TParams = [];
				for (ct in constraints) {
					var r = configLoop(ct);
					ps = r.params.concat(ps);
					ts = r.tl.concat(ts);
				}
				{params: ps, tl: ts};
			case TInst(c, pl): getChainParams(c, pl);
			case _: {params: [], tl: []};
		};
	}

	// Substitute both the receiver class's and the callee's own type parameters; the callee's get
	// fresh monomorphs which the argument unification later binds to the call site's concrete types.
	static function inlineDefaultConfig(cf:TClassField, t:T):{hasParams:Bool, mapType:T->T} {
		var tp = configLoop(t);
		var pmonos:TParams = [for (_ in cf.params) TypeFunctions.mkMono()];
		var tmonos = tp.tl.concat(pmonos);
		var tparams = tp.params.concat(cf.params);
		return {
			hasParams: tparams.length > 0,
			mapType: function(t2:T):T return TypeFunctions.applyParams(tparams, tmonos, t2)
		};
	}

	// / 620 map_expr_type: apply the bound substitution to every type in the inlined tree. The passed
	// argument expressions keep their call-site types, so any subtree that is one of them is returned
	// untouched . Only variables the inliner itself created map (the reference's i_outside guard); a
	// caller variable reachable through a bound receiver expression keeps its type. Each variable maps
	// once (all occurrences share the object).
	static function mapExprType(mapType:T->T, args:Array<TExpr>, varWatermark:Int, mappedVars:Map<Int, Bool>, e:TExpr):TExpr {
		for (a in args) if (a == e) return e;
		function mapVar(v:TVar):Void {
			if (v.id >= varWatermark && !mappedVars.exists(v.id)) {
				mappedVars.set(v.id, true);
				v.type = mapType(v.type);
			}
		}
		switch (e.expr) {
			case TVarExpr(v, _): mapVar(v);
			case TFor(v, _, _): mapVar(v);
			case TLocal(v): mapVar(v);
			case TNew(_, tl, _): for (i in 0...tl.length) tl[i] = mapType(tl[i]);
			case _:
		}
		var e2 = TexprTools.mapExpr(function(x) return mapExprType(mapType, args, varWatermark, mappedVars, x), e);
		e2.type = mapType(e2.type);
		return e2;
	}

	static function doInline(ctx:TyperContext, cf:TClassField, cfg:{hasParams:Bool, mapType:T->T}, tf:TFunc, ethis:Null<TExpr>, isStatic:Bool, params:Array<TExpr>, tret:T, absMember:Bool, p:Position):TExpr {
		var subst = new Map<Int, TExpr>();
		var binds:Array<TExpr> = [];
		var tvoid = ctx.com.basic.tvoid;
		// Every variable allocated from here on belongs to this inline expansion
		var varWatermark = TypeFunctions.allocVar(VGenerated, "_hx_mark", TypeFunctions.tDynamic, p).id;
		var vthis:Null<TVar> = null;
		if (!isStatic) {
			if (ethis == null) throw new InlineBail();
			vthis = TypeFunctions.allocVar(VGenerated, "_hx_this", ethis.type, p);
			binds.push(TypeFunctions.mk(TVarExpr(vthis, ethis), tvoid, p));
		}
		// A side-effecting argument always binds to a temp; once anything had a side effect (an argument
		// or the mapped body: assignments, calls, news), any argument that might be affected and lacks
		// @:semantics(value) binds too.
		var checker = hxc.optimization.OptimizerTexpr.createAffectionChecker();
		var hadSideEffect = bodyHasSideEffect(tf.expr);
		var paramSideEffect:Array<Bool> = [];
		for (param in params) {
			var se = hxc.optimization.OptimizerTexpr.hasSideEffect(param);
			paramSideEffect.push(se);
			if (se) {
				checker.collectModifiedLocals(param);
				hadSideEffect = true;
			}
		}
		function valueSemantics(t:T):Bool {
			return hxc.optimization.AnalyzerFusion.ExtTypeSemantics.hasValueSemantics(t);
		}
		for (i in 0...tf.args.length) {
			var av = tf.args[i].v;
			var param = params[i];
			if (tf.args[i].c != null) switch (param.expr) {
				case TConst(TNull): param = tf.args[i].c;
				case _:
			}
			// The abstract `this` (first arg of an abstract member) binds to a local receiver directly, so
			// `++this` / `this = ...` writes back to the caller's variable; other args are call-by-value.
			// A stable lvalue receiver (a local or a side-effect-free field chain) substitutes
			// directly, so this-assignments write back through it.
			var use = argUsage(av, tf.expr);
			var hasRuntimeDefault = tf.args[i].c != null && !tf.args[i].c.expr.match(TConst(TNull));
			// An unwritten local or constant argument substitutes without a
			// temp; any other expression substitutes when it is used at most once; a captured
			// non-constant argument or one with a runtime default needs the local.
			var forceTemp = paramSideEffect[i]
				|| (hadSideEffect && checker.mightBeAffected(param) && !valueSemantics(param.type));
			var substitutable = !forceTemp && !hasRuntimeDefault
				&& !(use.captured && !param.expr.match(TConst(_)))
				&& switch (param.expr) {
					case TConst(TNull): false;
					case TLocal(_) | TConst(_): !use.writes;
					case TFunction(_): use.reads <= 1 && !use.writes;
					case _: !use.writes && use.reads <= 1;
				};
			if (absMember && i == 0 && isStableLvalue(param)) {
				subst.set(av.id, param);
			} else if (!(absMember && i == 0) && substitutable) {
				subst.set(av.id, param);
			} else {
				var nv = TypeFunctions.allocVar(VGenerated, av.name, av.type, p);
				nv.extra = new TVarExtra([], param);
				subst.set(av.id, TypeFunctions.mk(TLocal(nv), nv.type, p));
				binds.push(TypeFunctions.mk(TVarExpr(nv, param), tvoid, p));
				// An optional argument with a non-null default falls back when the passed value is null at
				// runtime: if (v == null) v = default. (i_default_value) and
				var dflt = tf.args[i].c;
				if (dflt != null && !dflt.expr.match(TConst(TNull))) {
					var ve = TypeFunctions.mk(TLocal(nv), nv.type, p);
					var cond = TypeFunctions.mk(TBinop(OpEq, ve, TypeFunctions.mk(TConst(TNull), nv.type, p)), ctx.com.basic.tbool, p);
					binds.push(TypeFunctions.mk(TIf(cond, TypeFunctions.mk(TBinop(OpAssign, ve, dflt), nv.type, p), null), tvoid, p));
				}
			}
		}
		var value = inlineBody(ctx, tf.expr, subst, vthis);
		var result = TypeFunctions.mk(TBlock(binds.concat([value])), tret, p);
		if (cfg.hasParams) {
			// Bind the callee's fresh type-parameter monomorphs by unifying the mapped field type against
			// the actual argument and return types; an abstract implementation member's first argument
			// unifies against the mapped abstract this.
			var mt = cfg.mapType(TypeFunctions.follow(cf.type));
			var argTl:Array<TSignatureArg> = [for (prm in params) {name: "", opt: false, t: prm.type}];
			if (absMember && cf.name != "_new" && argTl.length > 0) {
				switch (TypeFunctions.follow(params[0].type)) {
					case TAbstract(a, _): argTl[0] = {name: "", opt: false, t: cfg.mapType(a.thisType)};
					case _:
				}
			}
			var tb:T = TFun({args: argTl, ret: tret});
			try hxc.core.TypeUnification.unifyDefault(mt, tb)
			catch (_:hxc.core.TypeUnification.UnifyError) throw new InlineBail();
			result = mapExprType(cfg.mapType, params, varWatermark, new Map<Int, Bool>(), result);
			result.type = tret;
		}
		return result;
	}

	// The body-map pass flags a side effect on assignments, increments,
	// calls and constructions anywhere in the inlined body.
	static function bodyHasSideEffect(e:TExpr):Bool {
		var found = false;
		function loop(e:TExpr):Void {
			if (found) return;
			switch (e.expr) {
				case TBinop(OpAssign | OpAssignOp(_), _, _) | TUnop(Increment | Decrement, _, _) | TCall(_, _) | TNew(_, _, _):
					found = true;
				case _:
					TexprTools.iter(loop, e);
			}
		}
		loop(e);
		return found;
	}

	// Usage analysis for one argument variable: read count, write flag, and
	// whether a closure inside the body captures it.
	static function argUsage(v:TVar, body:TExpr):{reads:Int, writes:Bool, captured:Bool} {
		var reads = 0, writes = false, captured = false;
		function loop(inClosure:Bool, e:TExpr):Void {
			switch (e.expr) {
				case TLocal(v2) if (v2 == v):
					reads++;
					if (inClosure) captured = true;
				case TBinop(OpAssign, {expr: TLocal(v2)}, e2) if (v2 == v):
					writes = true;
					loop(inClosure, e2);
				case TBinop(OpAssignOp(_), {expr: TLocal(v2)}, e2) if (v2 == v):
					reads++;
					writes = true;
					if (inClosure) captured = true;
					loop(inClosure, e2);
				case TUnop(Increment | Decrement, _, {expr: TLocal(v2)}) if (v2 == v):
					reads++;
					writes = true;
					if (inClosure) captured = true;
				case TFunction(f):
					loop(true, f.expr);
				case _:
					TexprTools.iter(function(e2) loop(inClosure, e2), e);
			}
		}
		loop(false, body);
		return {reads: reads, writes: writes, captured: captured};
	}

	// A side-effect-free lvalue: re-reading and assigning through it is equivalent to a bound
	// receiver, so the substituted body mutates the caller's storage.
	public static function isStableLvalue(e:TExpr):Bool {
		return switch (e.expr) {
			case TLocal(_): true;
			case TConst(_): true;
			case TField(e1, _): isStableLvalue(e1);
			case TArray(e1, e2): isStableLvalue(e1) && isStableLvalue(e2);
			case TTypeExpr(_): true;
			case TParenthesis(e1): isStableLvalue(e1);
			case _: false;
		};
	}

	// The body reduced to its result value: a single or final return's value, else the body itself.
	static function inlineBody(ctx:TyperContext, body:TExpr, subst:Map<Int, TExpr>, vthis:Null<TVar>):TExpr {
		switch (body.expr) {
			case TReturn(eo):
				return eo == null ? TypeFunctions.mk(TConst(TNull), ctx.com.basic.tvoid, body.pos) : mapExpr(ctx, eo, subst, vthis);
			case TBlock(stmts):
				if (stmts.length == 0) return body;
				var out:Array<TExpr> = [];
				for (i in 0...stmts.length) {
					var s = stmts[i];
					if (i == stmts.length - 1) switch (s.expr) {
						case TReturn(eo): out.push(eo == null ? TypeFunctions.mk(TConst(TNull), ctx.com.basic.tvoid, s.pos) : mapExpr(ctx, eo, subst, vthis));
						case _: out.push(mapExpr(ctx, s, subst, vthis));
					} else out.push(mapExpr(ctx, s, subst, vthis));
				}
				return TypeFunctions.mk(TBlock(out), body.type, body.pos);
			case _:
				return mapExpr(ctx, body, subst, vthis);
		}
	}

	// Substitutes argument/this locals; bails on anything outside the handled subset.
	static function mapExpr(ctx:TyperContext, e:TExpr, subst:Map<Int, TExpr>, vthis:Null<TVar>):TExpr {
		function m(x:TExpr):TExpr return mapExpr(ctx, x, subst, vthis);
		var ne:TExprExpr = switch (e.expr) {
			case TConst(TThis):
				if (vthis == null) throw new InlineBail();
				TLocal(vthis);
			case TConst(_): e.expr;
			case TLocal(v):
				if (subst.exists(v.id)) return subst.get(v.id);
				e.expr;
			case TArray(e1, e2): TArray(m(e1), m(e2));
			case TBinop(op, e1, e2): TBinop(op, m(e1), m(e2));
			case TField(e1, fa): TField(m(e1), fa);
			case TParenthesis(e1): TParenthesis(m(e1));
			case TObjectDecl(fields): TObjectDecl([for (f in fields) {key: f.key, expr: m(f.expr)}]);
			case TArrayDecl(vals): TArrayDecl([for (x in vals) m(x)]);
			case TCall(e1, ps):
				// A nested inline call in the body expands too, so a sibling call mutating the
				// abstract this still writes back to the substituted receiver (the reference
				// inliner expands inline calls inside inlined bodies).
				var me1 = m(e1);
				var mps = [for (x in ps) m(x)];
				var nested = tryInline(ctx, me1, mps, e.type, e.pos);
				if (nested != null) return nested;
				TCall(me1, mps);
			case TNew(c, tp, args): TNew(c, tp, [for (x in args) m(x)]);
			case TUnop(op, fl, e1): TUnop(op, fl, m(e1));
			case TVarExpr(v, eo):
				var nv = TypeFunctions.allocVar(VGenerated, v.name, v.type, v.pos);
				subst.set(v.id, TypeFunctions.mk(TLocal(nv), nv.type, v.pos));
				TVarExpr(nv, eo == null ? null : m(eo));
			case TBlock(el): TBlock([for (x in el) m(x)]);
			case TFor(v, e1, e2):
				var me1 = m(e1);
				var hadOld = subst.exists(v.id);
				var old = hadOld ? subst.get(v.id) : null;
				var nv = TypeFunctions.allocVar(VGenerated, v.name, v.type, v.pos);
				subst.set(v.id, TypeFunctions.mk(TLocal(nv), nv.type, v.pos));
				var me2 = m(e2);
				if (hadOld) subst.set(v.id, old) else subst.remove(v.id);
				TFor(nv, me1, me2);
			case TIf(c, a, b): TIf(m(c), m(a), b == null ? null : m(b));
			case TWhile(c, body, flag): TWhile(m(c), m(body), flag);
			case TCast(e1, mt): TCast(m(e1), mt);
			case TMeta(entry, e1): TMeta(entry, m(e1));
			case TThrow(e1): TThrow(m(e1));
			case TEnumParameter(e1, ef, idx): TEnumParameter(m(e1), ef, idx);
			case TEnumIndex(e1): TEnumIndex(m(e1));
			case TTypeExpr(_) | TIdent(_) | TBreak | TContinue: e.expr;
			case TReturn(_) | TFunction(_) | TSwitch(_, _, _) | TTry(_, _):
				throw new InlineBail();
		};
		return TypeFunctions.mk(ne, e.type, e.pos);
	}
}
