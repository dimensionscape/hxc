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
// the caller emits a normal call. Class/method type parameters are substituted throughout the inlined tree
// so declaration-side parameters do not leak into caller ASTs / inline_default_config, finalize's
// map_expr_type).
class Inline {
	static var depth = 0;
	// A field already being inlined does not inline again inside its own expansion, so a
	// self-recursive inline function stays a call.
	static var cfStack:Array<TClassField> = [];

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
		// An abstract instance member (CfImpl) is an impl static whose first arg is the abstract `this`;
		// a mutation of `this` must write back to an lvalue receiver.
		var absMember = TypeFunctions.hasClassFieldFlag(cf, CfImpl);
		var mapType = buildMapType(c, cf, ethis, params, tret);
		// Collapse the arguments matching a trailing haxe.Rest parameter into one value.
		params = inlineRestParams(ctx, tf, params, mapType == null ? (function(t) return t) : mapType, p);
		// An omitted trailing optional argument binds to null and falls back to its default; the call
		// already type-checked, so a missing trailing argument is optional.
		if (params.length < tf.args.length) {
			var padded = params.copy();
			for (i in params.length...tf.args.length) {
				if (tf.args[i].c == null && !isOptionalArg(tf.args[i].v)) return null;
				padded.push(TypeFunctions.mk(TConst(TNull), tf.args[i].v.type, p));
			}
			params = padded;
		}
		if (tf.args.length != params.length) return null;
		if (cfStack.indexOf(cf) >= 0) return null;
		cfStack.push(cf);
		depth++;
		var r = try doInline(ctx, tf, ethis, isStatic, params, tret, absMember, mapType, p) catch (_:InlineBail) null;
		depth--;
		cfStack.pop();
		return r;
	}

	static function isOptionalArg(v:TVar):Bool {
		return TypeFunctions.hasMeta(":optional", v.meta) || TypeFunctions.isNullable(v.type);
	}

	public static function needsInline(ctx:TyperContext, c:Null<TClass>, cf:TClassField):Bool {
		return cf.kind.match(Method(MethInline)) && ctx.com.foptimize;
	}

	// The inliner entry with an explicit callee: class, field, function and receiver expression
	// (the call-site resolution is the caller's).
	public static function typeInline(ctx:TyperContext, c:Null<TClass>, cf:TClassField, tf:TFunc, ethis:Null<TExpr>, params:Array<TExpr>, tret:T, p:Position):Null<TExpr> {
		if (depth > 32) return null;
		var absMember = TypeFunctions.hasClassFieldFlag(cf, CfImpl);
		var mapType = buildMapType(c, cf, ethis, params, tret);
		params = inlineRestParams(ctx, tf, params, mapType == null ? (function(t) return t) : mapType, p);
		if (tf.args.length != params.length) return null;
		if (cfStack.indexOf(cf) >= 0) return null;
		cfStack.push(cf);
		depth++;
		var r = try doInline(ctx, tf, ethis, ethis == null, params, tret, absMember, mapType, p) catch (_:InlineBail) null;
		depth--;
		cfStack.pop();
		return r;
	}

	// Prepend the class's field initializers to the constructor body, then inline it against the
	// receiver.
	public static function typeInlineCtor(ctx:TyperContext, c:TClass, cf:TClassField, tf:TFunc, ethis:TExpr, el:Array<TExpr>, po:Position):Null<TExpr> {
		var cparams = TypeFunctions.extractParamTypes(c.params);
		var eFieldThis = TypeFunctions.mk(TConst(TThis), TInst(c, cparams), c.pos);
		var fieldInits:Array<TExpr> = [];
		for (fld in c.orderedFields) switch (fld.kind) {
			case Var(_) if (fld.expr != null):
				var fe = fld.expr;
				var lhs = TypeFunctions.mk(TField(eFieldThis, FInstance(c, cparams, fld)), fld.type, fe.pos);
				fieldInits.push(TypeFunctions.mk(TBinop(OpAssign, lhs, fe), fld.type, fe.pos));
			case _:
		}
		var tf2 = if (fieldInits.length == 0) tf else {
			var bl = switch (tf.expr.expr) { case TBlock(b): b; case _: [tf.expr]; };
			new TFunc(tf.args, tf.type, TypeFunctions.mk(TBlock(fieldInits.concat(bl)), ctx.com.basic.tvoid, c.pos));
		};
		return typeInline(ctx, c, cf, tf2, ethis, el, ctx.com.basic.tvoid, po);
	}

	// On a platform with native rest support each trailing argument arrives as its own value, but
	// an inlined body's single rest variable must bind to one value. Collapse the arguments
	// matching a trailing haxe.Rest parameter into a single haxe.Rest.of([...]).
	static function inlineRestParams(ctx:TyperContext, tf:TFunc, params:Array<TExpr>, mapType:T->T, p:Position):Array<TExpr> {
		if (!ctx.com.platformConfig.supportsRestArgs) return params;
		var args = tf.args;
		if (args.length == 0) return params;
		var last = args[args.length - 1].v;
		switch (TypeFunctions.follow(mapType(last.type))) {
			case TAbstract(a, [elem]) if (a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Rest"):
				if (params.length < args.length - 1) return params;
				var out = params.slice(0, args.length - 1);
				var remaining = params.slice(args.length - 1);
				if (remaining.length == 1) switch (remaining[0].expr) {
					case TUnop(Spread, Prefix, e): out.push(e); return out;
					case _:
				}
				if (a.impl == null || !a.impl.statics.exists("of")) return params;
				var tParams = switch (TypeFunctions.follow(elem)) {
					case TMono(_): remaining.length == 0 ? elem : Typer.unifyMin(ctx, remaining);
					case _: elem;
				};
				var array = TypeFunctions.mk(TArrayDecl(remaining), ctx.com.basic.tarray(tParams), p);
				var ofCf = a.impl.statics.get("of");
				var ofType = ofCf.params.length == 1
					? TypeFunctions.applyParams(ofCf.params, [tParams], TypeFunctions.follow(ofCf.type))
					: TypeFunctions.follow(ofCf.type);
				var fieldE = TypeFunctions.mk(TField(TexprTools.makeTypeExpr(TClassDecl(a.impl), p), FStatic(a.impl, ofCf)), ofType, p);
				out.push(TypeFunctions.mk(TCall(fieldE, [array]), TAbstract(a, [tParams]), p));
				return out;
			case _:
				return params;
		}
	}

	// The type substitution for an inline expansion; null when there is nothing to substitute.
	static function buildMapType(c:Null<TClass>, cf:TClassField, ethis:Null<TExpr>, params:Array<TExpr>, tret:T):Null<T->T> {
		if (c != null && c.kind.match(KAbstractImpl(_)) && TypeFunctions.hasClassFieldFlag(cf, CfImpl)) {
			var t = cf.name == "_new" ? tret : (params.length > 0 ? params[0].type : null);
			if (t == null) return null;
			return switch (TypeFunctions.follow(t)) {
				case TAbstract(a, pl) if (a.params.length > 0 || cf.params.length > 0):
					var aParams = a.params, cfParams = cf.params;
					var monos:TParams = [for (_ in cfParams) TypeFunctions.mkMono()];
					function(tt:T):T return TypeFunctions.applyParams(aParams, pl, TypeFunctions.applyParams(cfParams, monos, tt));
				case _: null;
			}
		}
		var ps:TypeParams = [];
		var ts:TParams = [];
		function collect(c2:TClass, pl:TParams):Void {
			ps = ps.concat(c2.params);
			ts = ts.concat(pl);
			if (c2.superClass != null) {
				var spl = switch (TypeFunctions.applyParams(c2.params, pl, TInst(c2.superClass.c, c2.superClass.params))) {
					case TInst(_, pl2): pl2;
					case _: [];
				};
				collect(c2.superClass.c, spl);
			}
		}
		if (ethis != null) switch (TypeFunctions.follow(ethis.type)) {
			case TInst(c2, pl):
				switch (c2.kind) {
					case KTypeParameter(ctl):
						for (ct in ctl) switch (TypeFunctions.follow(ct)) {
							case TInst(c3, pl3): collect(c3, pl3);
							case _:
						}
					case _: collect(c2, pl);
				}
			case _:
		}
		if (cf.params.length > 0) {
			var methodMonos:TParams = [for (_ in cf.params) TypeFunctions.mkMono()];
			ps = ps.concat(cf.params);
			ts = ts.concat(methodMonos);
			// Bind the method's own type parameters from the actual arguments: a using/static call like
			// address<T>(Array<T>) infers T from its argument, so map cf.type's arg types through the
			// substitution so far and unify each against the passed argument. Without this the method
			// type params stay open monomorphs and render as Dynamic (a Pointer<T> becomes Pointer<Dynamic>).
			var mapSoFar = function(tt:T):T return TypeFunctions.applyParams(ps, ts, tt);
			switch (TypeFunctions.follow(cf.type)) {
				case TFun(sig):
					for (i in 0...params.length) if (i < sig.args.length)
						try hxc.core.TypeUnification.unifyDefault(params[i].type, mapSoFar(sig.args[i].t)) catch (_:haxe.Exception) {};
				case _:
			}
		}
		if (ps.length == 0) return null;
		var psf = ps, tsf = ts;
		return function(tt:T):T return TypeFunctions.applyParams(psf, tsf, tt);
	}

	// Substitute the callee's type parameters throughout an inlined tree; original call-argument
	// expressions keep their caller-side types.
	static function mapInlinedTypes(mt:T->T, skip:Array<TExpr>, root:TExpr):TExpr {
		var mappedVars:Map<Int, Bool> = new Map();
		function fv(v:TVar):TVar {
			if (!mappedVars.exists(v.id)) {
				mappedVars.set(v.id, true);
				v.type = mt(v.type);
			}
			return v;
		}
		function f(e:TExpr):TExpr {
			for (s in skip) if (s == e) return e;
			var et = mt(e.type);
			var ne:TExprExpr = switch (e.expr) {
				case TConst(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_): e.expr;
				case TLocal(v): TLocal(fv(v));
				case TArray(e1, e2): TArray(f(e1), f(e2));
				case TBinop(op, e1, e2): TBinop(op, f(e1), f(e2));
				case TFor(v, e1, e2): TFor(fv(v), f(e1), f(e2));
				case TWhile(e1, e2, flag): TWhile(f(e1), f(e2), flag);
				case TThrow(e1): TThrow(f(e1));
				case TEnumParameter(e1, ef, i): TEnumParameter(f(e1), ef, i);
				case TEnumIndex(e1): TEnumIndex(f(e1));
				case TField(e1, fa):
					var m1 = f(e1);
					var nfa = switch (fa) {
						case FClosure(_, _): fa;
						case FAnon(cf2) | FInstance(_, _, cf2) | FStatic(_, cf2):
							try TypeFunctions.quickField(m1.type, cf2.name) catch (_:hxc.core.NotFound) fa;
						case FEnum(_, ef):
							try TypeFunctions.quickField(m1.type, ef.name) catch (_:hxc.core.NotFound) fa;
						case FDynamic(n):
							try TypeFunctions.quickField(m1.type, n) catch (_:hxc.core.NotFound) fa;
					};
					TField(m1, nfa);
				case TParenthesis(e1): TParenthesis(f(e1));
				case TUnop(op, pre, e1): TUnop(op, pre, f(e1));
				case TArrayDecl(el): TArrayDecl([for (x in el) f(x)]);
				case TNew(nc, pl, el):
					// Re-derive the constructed class/params against the substituted type.
					var derived = switch (nc.kind) {
						case KTypeParameter(_) | KGeneric: et;
						case _: mt(TInst(nc, pl));
					};
					switch (TypeFunctions.follow(derived)) {
						case TInst(c2, pl2): TNew(c2, pl2, [for (x in el) f(x)]);
						case TAbstract(a2, pl2) if (a2.impl != null): TNew(a2.impl, pl2, [for (x in el) f(x)]);
						case _: TNew(nc, [for (t0 in pl) mt(t0)], [for (x in el) f(x)]);
					}
				case TBlock(el): TBlock([for (x in el) f(x)]);
				case TObjectDecl(fl): TObjectDecl([for (fd in fl) {key: fd.key, expr: f(fd.expr)}]);
				case TCall(e1, el): TCall(f(e1), [for (x in el) f(x)]);
				case TVarExpr(v, eo): TVarExpr(fv(v), eo == null ? null : f(eo));
				case TFunction(fu):
					for (a in fu.args) fv(a.v);
					TFunction(new TFunc(fu.args, mt(fu.type), f(fu.expr)));
				case TIf(ec, e1, e2): TIf(f(ec), f(e1), e2 == null ? null : f(e2));
				case TCast(e1, mtRef): TCast(f(e1), mtRef);
				case TMeta(entry, e1): TMeta(entry, f(e1));
				case TReturn(eo): TReturn(eo == null ? null : f(eo));
				case TSwitch(e1, cases, def):
					TSwitch(f(e1), [for (cse in cases) {values: [for (v in cse.values) f(v)], expr: f(cse.expr)}], def == null ? null : f(def));
				case TTry(e1, catches):
					TTry(f(e1), [for (ct in catches) {v: fv(ct.v), expr: f(ct.expr)}]);
			};
			return TypeFunctions.mk(ne, et, e.pos);
		}
		return f(root);
	}

	static function doInline(ctx:TyperContext, tf:TFunc, ethis:Null<TExpr>, isStatic:Bool, params:Array<TExpr>, tret:T, absMember:Bool, mapType:Null<T->T>, p:Position):TExpr {
		var subst = new Map<Int, TExpr>();
		var binds:Array<TExpr> = [];
		var tvoid = ctx.com.basic.tvoid;
		var vthis:Null<TVar> = null;
		if (!isStatic) {
			if (ethis == null) throw new InlineBail();
			// A plain local or this receiver substitutes into the body directly, like any unwritten local
			// argument; anything else evaluates once into a receiver binding. (the this argument goes
			// through the same substitution analysis as the others).
			if (!ethis.expr.match(TConst(TThis) | TLocal(_))) {
				// The receiver binding _this with the VInlined kind.
				vthis = TypeFunctions.allocVar(VInlined, "_this", ethis.type, p);
				binds.push(TypeFunctions.mk(TVarExpr(vthis, ethis), tvoid, p));
			}
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
				// On a static platform a non-nullable arg can never be null, so the default check is
				// skipped; emitting it would type a null at the non-nullable arg type and trip the
				// static-null check.
				if (dflt != null && !dflt.expr.match(TConst(TNull))
						&& (!ctx.com.platformConfig.isStatic || TypeFunctions.isNullable(av.type))) {
					var ve = TypeFunctions.mk(TLocal(nv), nv.type, p);
					var cond = TypeFunctions.mk(TBinop(OpEq, ve, TypeFunctions.mk(TConst(TNull), nv.type, p)), ctx.com.basic.tbool, p);
					binds.push(TypeFunctions.mk(TIf(cond, TypeFunctions.mk(TBinop(OpAssign, ve, dflt), nv.type, p), null), tvoid, p));
				}
			}
		}
		var value = inlineBody(ctx, tf.expr, subst, vthis, ethis);
		// Unwrap a single-expression block.
		value = switch (value.expr) { case TBlock([one]): one; case _: value; };
		var result = binds.length == 0 ? value : TypeFunctions.mk(TBlock(binds.concat([value])), tret, p);
		if (mapType != null) {
			var skipExprs = params.copy();
			if (ethis != null) skipExprs.push(ethis);
			result = mapInlinedTypes(mapType, skipExprs, result);
		}
		// With no bindings the value stands alone: it keeps its own (substituted) type when that equals the
		// expected return, and gets a cast otherwise. .
		if (binds.length == 0 && !hxc.core.TypeUnification.typeIseqStrict(result.type, tret))
			result = TypeFunctions.mk(TCast(result, null), tret, p);
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
	static function inlineBody(ctx:TyperContext, body:TExpr, subst:Map<Int, TExpr>, vthis:Null<TVar>, ethis:Null<TExpr>):TExpr {
		switch (body.expr) {
			case TReturn(eo):
				return eo == null ? TypeFunctions.mk(TConst(TNull), ctx.com.basic.tvoid, body.pos) : mapExpr(ctx, eo, subst, vthis, ethis);
			case TBlock(stmts):
				if (stmts.length == 0) return body;
				var out:Array<TExpr> = [];
				for (i in 0...stmts.length) {
					var s = stmts[i];
					if (i == stmts.length - 1) switch (s.expr) {
						case TReturn(eo): out.push(eo == null ? TypeFunctions.mk(TConst(TNull), ctx.com.basic.tvoid, s.pos) : mapExpr(ctx, eo, subst, vthis, ethis));
						case _: out.push(mapExpr(ctx, s, subst, vthis, ethis));
					} else out.push(mapExpr(ctx, s, subst, vthis, ethis));
				}
				return TypeFunctions.mk(TBlock(out), body.type, body.pos);
			case _:
				return mapExpr(ctx, body, subst, vthis, ethis);
		}
	}

	// Substitutes argument/this locals; bails on anything outside the handled subset.
	static function mapExpr(ctx:TyperContext, e:TExpr, subst:Map<Int, TExpr>, vthis:Null<TVar>, ethis:Null<TExpr>):TExpr {
		function m(x:TExpr):TExpr return mapExpr(ctx, x, subst, vthis, ethis);
		var ne:TExprExpr = switch (e.expr) {
			case TConst(TThis):
				if (vthis != null) TLocal(vthis)
				else if (ethis != null) return ethis
				else throw new InlineBail();
			case TCall(es = {expr: TConst(TSuper)}, el):
				// A super constructor call inside an inlined constructor inlines recursively, bringing
				// the parent's field initializers; a parent the inliner cannot expand aborts the whole
				// inline.
				switch (TypeFunctions.follow(es.type)) {
					case TInst(sc, _) if (sc.constructor != null && sc.constructor.kind.match(Method(MethInline))
							&& sc.constructor.expr != null && sc.constructor.expr.expr.match(TFunction(_))):
						var scf = sc.constructor;
						var stf = switch (scf.expr.expr) { case TFunction(f): f; case _: null; };
						var recv = ethis != null ? ethis
							: (vthis != null ? TypeFunctions.mk(TLocal(vthis), vthis.type, e.pos) : throw new InlineBail());
						var r = typeInlineCtor(ctx, sc, scf, stf, recv, el, e.pos);
						if (r == null) throw new InlineBail();
						return m(r);
					case _:
						throw new InlineBail();
				}
			case TConst(TSuper):
				throw new InlineBail();
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
