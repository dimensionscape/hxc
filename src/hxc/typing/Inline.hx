package hxc.typing;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeUnification;
import hxc.core.TypeFunctions;
import hxc.core.TypingError;
import hxc.core.TexprTools;
import hxc.typing.TyperContext;
import hxc.typing.TypeFields;

// Falling back to a normal TCall whenever a construct is outside the handled subset. Exact
// in result for what it handles, safe otherwise.
private class InlineBail extends haxe.Exception {
	// A bail caused by a return in non-terminal position; a FORCED inline reports this case
	// instead of falling back.
	public var notFinalReturn:Bool;
	public function new(notFinalReturn = false) {
		super("inline-bail");
		this.notFinalReturn = notFinalReturn;
	}
}

// Compile-time expansion of inline-function calls, a safe subset ported It handles expression-bodied inline
// functions (single or final return, no early returns, no nested switch/try/closures, no type parameters):
// arguments and `this` bind to fresh locals and the body is substituted in place. Anything else bails and
// the caller emits a normal call. Class/method type parameters are substituted throughout the inlined tree
// so declaration-side parameters do not leak into caller ASTs / inline_default_config, finalize's
// map_expr_type).
class Inline {
	static var depth = 0;
	// The declared return type of the inline function whose body is currently being mapped;
	// null outside a body map.
	static var inlineFuncRetType:Null<T> = null;

	static inline function isInlineVoid(t:T):Bool {
		return switch (t) { case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void"; case _: false; };
	}
	// A field already being inlined does not inline again inside its own expansion, so a
	// self-recursive inline function stays a call.
	static var cfStack:Array<TClassField> = [];

	public static function tryInline(ctx:TyperContext, e:TExpr, params:Array<TExpr>, tret:T, p:Position, forceInline = false):Null<TExpr> {
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
				// D no-inline suppresses regular inlining; an extern-inline (a member of an extern class,
				// or a field flagged @:extern) is forced and still expands. + is_forced_inline.
				if (!forceInline && ctx.com.defines.rawDefined("no_inline")
					&& !((c != null && TypeFunctions.hasClassFlag(c, CExtern)) || TypeFunctions.hasMeta(":extern", cf.meta)))
					return null;
			case _ if (forceInline):
			case _: return null;
		}
		// The arguments reduce before the inline runs, so a constant-foldable argument reaches the
		// platform api substitutions as a constant (Std.int(1 + 2.0) folds to 3 instead of lowering to
		// `3. | 0`).
		params = [for (x in params) hxc.optimization.Optimizer.reduceExpression(ctx, x)];
		// The platform api substitutions run before the body inline, so a js Std.isOfType(o, String)
		// folds to a typeof check instead of its body.
		if (c != null) {
			var api = hxc.optimization.Optimizer.apiInline(ctx, c, cf.name, params, p);
			if (api != null) return api;
		}
		// A method's own type parameters do not affect the inlined value: the evaluator runs the body
		// without re-typing, so the substitution proceeds with the body types left as-is (the params
		// would only matter for the return type, which the evaluator does not need).
		// Force the callee's body to be typed first: it may live in a module that has not been
		// installed yet, so type it on demand from its owning class, then follow the lazy as a backstop.
		if (c != null) TypeFields.forceFieldBody(ctx.com, c, cf);
		TypeFunctions.follow(cf.type);
		// Inline from exprUnoptimized when it is set (the pre-analyzer body saved by save_class_state),
		// falling back to expr. This only matters for a module reused from the compilation cache, whose
		// expr has been analyzer-transformed; inlining that into a fresh caller would carry
		// analyzer-split temps into a body the pre-analyzer checks still visit. A freshly typed field has
		// exprUnoptimized = null, so the one-shot path is unaffected.
		var body = switch (cf.exprUnoptimized) {
			case some if (some != null && some.expr.match(TFunction(_))): some;
			case _: cf.expr;
		};
		if (body == null) return null;
		var tf = switch (body.expr) {
			case TFunction(f): f;
			case _: return null;
		};
		// An abstract instance member (CfImpl) is an impl static whose first arg is the abstract `this`;
		// a mutation of `this` must write back to an lvalue receiver.
		var absMember = TypeFunctions.hasClassFieldFlag(cf, CfImpl);
		var absThisArg = absMember && cf.name != "_new";
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
		var r = try doInline(ctx, tf, ethis, isStatic, params, tret, absMember, mapType, p, absThisArg) catch (b:InlineBail) {
			// A forced inline of a normal method with an early return cannot fall back to a
			// call; it is reported at the call.
			if (forceInline && b.notFinalReturn && !cf.kind.match(Method(MethInline))) {
				depth--;
				cfStack.pop();
				throw new TypingError("Function " + cf.name + " cannot be inlined because of a not final return", p);
			}
			null;
		};
		depth--;
		cfStack.pop();
		if (r != null) r = inlineMetadata(r, cf.meta);
		return r;
	}

	// @:pure (except inferredPure) and @:deprecated travel on the inlined expression as metas;
	// fusion's pure-element arms read them.
	static function inlineMetadata(e:TExpr, meta:hxc.ast.Ast.Metadata):TExpr {
		for (m in meta) switch (m.name) {
			case ":pure":
				var inferred = m.params.length == 1 && m.params[0].expr.match(hxc.ast.Ast.ExprDef.EConst(CIdent("inferredPure")));
				if (!inferred) e = TypeFunctions.mk(TMeta(m, e), e.type, e.pos);
			case ":deprecated":
				e = TypeFunctions.mk(TMeta(m, e), e.type, e.pos);
			case _:
		}
		return e;
	}

	// Anything free of locals/this/object/array literals counts as constant, so a static function
	// reference substitutes into a captured position (a closure).
	static function isConstantForCapture(e:TExpr):Bool {
		var constant = true;
		function loop(x:TExpr):Void {
			if (!constant) return;
			switch (x.expr) {
				case TLocal(_) | TConst(TThis) | TObjectDecl(_) | TArrayDecl(_): constant = false;
				case TField(_, FEnum(_, _)) | TTypeExpr(_) | TConst(_):
				case _: TexprTools.iter(loop, x);
			}
		}
		loop(e);
		return constant;
	}

	static function isOptionalArg(v:TVar):Bool {
		return TypeFunctions.hasMeta(":optional", v.meta) || TypeFunctions.isNullable(v.type);
	}

	public static function needsInline(ctx:TyperContext, c:Null<TClass>, cf:TClassField):Bool {
		return cf.kind.match(Method(MethInline)) && ctx.com.foptimize;
	}

	// The inliner entry with an explicit callee: class, field, function and receiver expression
	// (the call-site resolution is the caller's).
	public static function typeInline(ctx:TyperContext, c:Null<TClass>, cf:TClassField, tf:TFunc, ethis:Null<TExpr>, params:Array<TExpr>, tret:T, p:Position, selfCallingClosure:Bool = false):Null<TExpr> {
		if (depth > 32) return null;
		// The platform api substitutions run before the body inline, so a js Std.isOfType(o, String)
		// folds to a typeof check instead of its body.
		if (ethis != null) {
			var apiCls:Null<TClass> = switch (TypeFunctions.follow(ethis.type)) {
				case TInst(c2, _): c2;
				case TAnon(a): switch (a.status.get()) { case Statics(c2): c2; case _: null; };
				case _: null;
			};
			if (apiCls != null) {
				var r = hxc.optimization.Optimizer.apiInline(ctx, apiCls, cf.name, params, p);
				if (r != null) return r;
			}
		}
		var absMember = TypeFunctions.hasClassFieldFlag(cf, CfImpl);
		var absThisArg = absMember && cf.name != "_new";
		var mapType = buildMapType(c, cf, ethis, params, tret);
		params = inlineRestParams(ctx, tf, params, mapType == null ? (function(t) return t) : mapType, p);
		if (tf.args.length != params.length) return null;
		if (cfStack.indexOf(cf) >= 0) return null;
		cfStack.push(cf);
		depth++;
		var r = try doInline(ctx, tf, ethis, ethis == null, params, tret, absMember, mapType, p, absThisArg, selfCallingClosure) catch (_:InlineBail) null;
		depth--;
		cfStack.pop();
		if (r != null) r = inlineMetadata(r, cf.meta);
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
					// Also bind a RETURN-only method type parameter from the (already inferred) return type,
					// so a generic function whose type parameter appears only in its result - e.g.
					// cpp.Stdlib.malloc<T>:cpp.Pointer<T> - infers T instead of leaving it Dynamic.
					if (tret != null)
						try hxc.core.TypeUnification.unifyDefault(tret, mapSoFar(sig.ret)) catch (_:haxe.Exception) {};
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
		var fRef:TExpr->TExpr = null;
		function fv(v:TVar):TVar {
			if (!mappedVars.exists(v.id)) {
				mappedVars.set(v.id, true);
				v.type = mt(v.type);
				// The stored expr type-maps along, so the
				// abstract receiver type it carries concretizes with the substitution.
				if (v.extra != null && v.extra.expr != null)
					v.extra = new TVarExtra(v.extra.params, fRef(v.extra.expr));
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
		fRef = f;
		return f(root);
	}

	static function doInline(ctx:TyperContext, tf:TFunc, ethis:Null<TExpr>, isStatic:Bool, params:Array<TExpr>, tret:T, absMember:Bool, mapType:Null<T->T>, p:Position, absThisArg:Bool, selfCallingClosure:Bool = false):TExpr {
		var subst = new Map<Int, TExpr>();
		var binds:Array<TExpr> = [];
		var tvoid = ctx.com.basic.tvoid;
		var vthis:Null<TVar> = null;
		// A side-effecting argument always binds to a temp; once anything had a side effect (an argument
		// or the mapped body: assignments, calls, news), any argument that might be affected and lacks
		// @:semantics(value) binds too.
		var checker = hxc.optimization.OptimizerTexpr.createAffectionChecker();
		var hadSideEffect = bodyHasSideEffect(tf.expr);
		var ethisSideEffect = !isStatic && ethis != null && hxc.optimization.OptimizerTexpr.hasSideEffect(ethis);
		if (ethisSideEffect) {
			checker.collectModifiedLocals(ethis);
			hadSideEffect = true;
		}
		var paramSideEffect:Array<Bool> = [];
		for (param in params) {
			var se = hxc.optimization.OptimizerTexpr.hasSideEffect(param);
			paramSideEffect.push(se);
			if (se) {
				checker.collectModifiedLocals(param);
				hadSideEffect = true;
			}
		}
		if (!isStatic) {
			if (ethis == null) throw new InlineBail();
			// The receiver is just the first inlined var (named _this), so it follows the same substitution
			// rules as arguments: a local or `this` substitutes; anything else substitutes only when read at
			// most once and not forced to a temp by the side-effect rules.
			var thisReads = countThisUses(tf.expr);
			var forceTempThis = ethisSideEffect
				|| (hadSideEffect && checker.mightBeAffected(ethis) && !hxc.optimization.AnalyzerFusion.ExtTypeSemantics.hasValueSemantics(ethis.type));
			var directThis = !forceTempThis
				&& (ethis.expr.match(TConst(TThis) | TLocal(_)) || thisReads <= 1);
			if (!directThis) {
				// The bound receiver behaves as compiler-generated in fusion, so
				// a single-use receiver temp fuses back regardless of extern purity.
				vthis = TypeFunctions.allocVar(VGenerated, "_this", ethis.type, p);
				binds.push(TypeFunctions.mk(TVarExpr(vthis, ethis), tvoid, p));
			}
		}
		function valueSemantics(t:T):Bool {
			return hxc.optimization.AnalyzerFusion.ExtTypeSemantics.hasValueSemantics(t);
		}
		// The runtime default checks emit after every argument declaration, in REVERSE argument order,
		// and only for an argument the body actually reads.
		var defaultChecks:Array<TExpr> = [];
		for (i in 0...tf.args.length) {
			var av = tf.args[i].v;
			var param = params[i];
			// A null argument (an omitted optional) takes the default CONSTANT directly, repositioned to the
			// call site, with no runtime default check; only a possibly-null runtime value keeps the default
			// temp.
			var passedNull = false;
			if (tf.args[i].c != null) switch (param.expr) {
				case TConst(TNull):
					var c = tf.args[i].c;
					param = TypeFunctions.mk(c.expr, c.type, param.pos);
					passedNull = true;
				case _:
			}
			// A Null<T> value passed where a static platform expects a
			// non-nullable T forces the local.
			var nullMismatch = ctx.com.platformConfig.isStatic && !TypeFunctions.isNullable(av.type) && TypeFunctions.isNull(param.type);
			// A Dynamic mismatch between argument and parameter casts once
			// through the arg expression, so DCE and the read-count rules see a single cast.
			var dynamicV = TypeFunctions.follow(av.type).match(TDynamic(null));
			var dynamicE = TypeFunctions.follow(param.type).match(TDynamic(null));
			if (dynamicV != dynamicE) param = TypeFunctions.mk(TCast(param, null), av.type, param.pos);
			// The abstract `this` (first arg of an abstract member) binds to a local receiver directly, so
			// `++this` / `this = ...` writes back to the caller's variable; other args are call-by-value.
			// A stable lvalue receiver (a local or a side-effect-free field chain) substitutes
			// directly, so this-assignments write back through it.
			var use = argUsage(av, tf.expr);
			// The runtime default applies only when the passed value was
			// not the null constant and the platform can see a null there at runtime.
			var hasRuntimeDefault = !passedNull && tf.args[i].c != null && !tf.args[i].c.expr.match(TConst(TNull))
				&& (!ctx.com.platformConfig.isStatic || TypeFunctions.isNullable(av.type));
			// An unwritten local or constant argument substitutes without a
			// temp; any other expression substitutes when it is used at most once; a captured
			// non-constant argument or one with a runtime default needs the local.
			var forceTemp = paramSideEffect[i]
				|| nullMismatch
				|| (hadSideEffect && checker.mightBeAffected(param) && !valueSemantics(param.type));
			// The abstract `this` is argument 0 of an abstract member, EXCEPT for `_new`: an
			// abstract constructor creates the underlying value in a synthesized local, so its
			// first argument is a real parameter and must not be wrapped in the abstract-this cast
			// (the abstract this is the :this-meta var, which `_new`'s params lack).
			var isAbsThis = absThisArg && i == 0;
			// A WRITTEN abstract `this` always substitutes so the assignment writes back through the
			// caller's lvalue; otherwise an abstract `this` substitutes only when it is a plain local and
			// any other receiver follows the ordinary read-count rules, so a multi-read field chain binds a
			// `this` temp.
			var substitutable = (isAbsThis && use.writes)
				|| (!forceTemp && !hasRuntimeDefault
				&& !(use.captured && !isConstantForCapture(param))
				&& switch (param.expr) {
					case TLocal(_) if (isAbsThis): true;
					case TConst(TNull): false;
					case TLocal(_) | TConst(_): !use.writes;
					// Calls do not count against a function argument.
					case TFunction(_): use.reads <= 1 && !use.writes;
					case _: !use.writes && use.reads + use.called <= 1;
				});
			// Every READ of the abstract `this` substitutes wrapped in a TCast at the receiver type;
			// assignment left-hand sides strip it again (inline_params, TCast when in_assignment). The cast
			// keeps Texpr.equal from conflating the abstract this with its underlying value in later fusion.
			inline function absThisCast(e:TExpr):TExpr
				return isAbsThis ? TypeFunctions.mk(TCast(e, null), av.type, e.pos) : e;
			if (ctx.com.defines.rawDefined("inline_debug")) Sys.println("[INL] " + av.name
				+ " reads=" + use.reads + " writes=" + use.writes + " called=" + use.called
				+ " captured=" + use.captured + " forceTemp=" + forceTemp + " subst=" + substitutable
				+ " paramKind=" + Std.string(param.expr).substr(0,22)
				+ " ptype=" + hxc.core.TPrinting.sTypeStr(param.type)
				+ " atype=" + hxc.core.TPrinting.sTypeStr(av.type));
			if (substitutable) {
				subst.set(av.id, isAbsThis ? absThisCast(param) : param);
			} else {
				// The bound local takes the SOURCE kind mapped through VUser -> VInlined, and is downgraded
				// to VGenerated only when it is read at most once and never written. Keeping the VInlined
				// kind in the other case is what stops the analyzer (for which neither VUser nor VInlined
				// counts as compiler generated) from fusing the local without -D analyzer-optimize.
				var nv = TypeFunctions.allocVar(declareKind(av), av.name, av.type, p);
				if (use.reads + use.called <= 1 && !use.writes) nv.kind = VGenerated;
				nv.extra = new TVarExtra([], param);
				subst.set(av.id, absThisCast(TypeFunctions.mk(TLocal(nv), nv.type, p)));
				binds.push(TypeFunctions.mk(TVarExpr(nv, param), tvoid, p));
				// A multiply-read function argument still inlines at its call sites (each a fresh tvar copy);
				// non-call reads keep the bound local, which local-dce drops when every read was a call.
				switch (param.expr) {
					case TFunction(_) if (!use.writes):
						nv.meta = [{name: ":inlineIfCalled", params: [], pos: p}].concat(nv.meta);
					case _:
				}
				// An optional argument with a non-null default falls back when the passed value is null
				// at runtime: if (v == null) v = default. A null argument already replaced by the default
				// constant gets no such check.
				var dflt = tf.args[i].c;
				// On a static platform a non-nullable arg can never be null, so the default check is
				// skipped; emitting it would type a null at the non-nullable arg type and trip the
				// static-null check.
				if (hasRuntimeDefault && dflt != null && !dflt.expr.match(TConst(TNull))
						&& (!ctx.com.platformConfig.isStatic || TypeFunctions.isNullable(av.type))
						&& use.reads > 0) {
					var ve = TypeFunctions.mk(TLocal(nv), nv.type, p);
					var cond = TypeFunctions.mk(TBinop(OpEq, ve, TypeFunctions.mk(TConst(TNull), nv.type, p)), ctx.com.basic.tbool, p);
					defaultChecks.unshift(TypeFunctions.mk(TIf(cond, TypeFunctions.mk(TBinop(OpAssign, ve, dflt), nv.type, p), null), tvoid, p));
				}
			}
		}
		// The receiver and argument bindings precede the default checks in binds; they are
		// materialized at the inlined body position, not the call position. This differs only when
		// the body keeps its own positions (a self-calling closure), where the body sits on a later
		// line than the call site.
		var argBindCount = binds.length;
		for (dc in defaultChecks) binds.push(dc);
		// A self-calling closure (an immediately-called TFunction) keeps its body positions, like
		// the keep_inline_positions define.
		var keepPositions = selfCallingClosure || ctx.com.defines.rawDefined("keep_inline_positions");
		// The return-type rule consults the inlined function's declared return type; scope it to
		// this body map (save/restore so a nested inline restores the outer value).
		var savedRetType = inlineFuncRetType;
		inlineFuncRetType = tf.type;
		var value = inlineBody(ctx, tf.expr, subst, vthis, ethis, p, keepPositions, absMember);
		inlineFuncRetType = savedRetType;
		if (absMember) checkAbstractWrite(value, p);
		// A single-expression block unwraps to its expression only when the body returned a
		// value; a void body keeps its block.
		var hasReturnValue = bodyHasReturnValue(tf.expr);
		if (hasReturnValue)
			value = switch (value.expr) { case TBlock([one]): one; case _: value; };
		// The argument-binding TVars take the finalized body position.
		for (i in 0...argBindCount) switch (binds[i].expr) {
			case TVarExpr(v, eo): binds[i] = TypeFunctions.mk(TVarExpr(v, eo), tvoid, value.pos);
			case _:
		}
		// With argument bindings present, a block body SPLICES its
		// elements after the binds instead of nesting as one element.
		var result = if (binds.length == 0) value else {
			var bodyEls = switch (value.expr) {
				case TBlock(bl): bl;
				case _: [value];
			};
			TypeFunctions.mk(TBlock(binds.concat(bodyEls)), tret, p);
		};
		// The wrap check reads `follow e.type` before map_type substitutes parameters, so an inlined body
		// typed as an open mono or a raw type parameter casts even when the substituted type equals tret
		// (the cpp oracle keeps `cast unsafeGet(...)` for Vector.get<String>).
		var preMapType = result.type;
		if (mapType != null) {
			var skipExprs = params.copy();
			if (ethis != null) skipExprs.push(ethis);
			result = mapInlinedTypes(mapType, skipExprs, result);
		}
		// With no bindings the value stands alone: it keeps its own (substituted) type when that
		// equals the expected return, and gets a cast otherwise.
		if (binds.length == 0) {
			if (!hasReturnValue) {
				// A body without a value return keeps its block, retyped to
				// the return type; a bare statement gains one. No cast on this path.
				result = switch (result.expr) {
					case TBlock(_): TypeFunctions.mk(result.expr, tret, result.pos);
					case _: TypeFunctions.mk(TBlock([result]), tret, result.pos);
				};
			} else {
				// A mono/type-param body is accepted bare only for a
				// Void return; otherwise it casts. Anything else compares the MAPPED type to
				// tret with EqDoNotFollowNull on static targets (EqStrict elsewhere).
				var needsCast = switch (TypeFunctions.follow(preMapType)) {
					case TMono(_) | TInst({kind: KTypeParameter(_)}, _):
						!TypeFunctions.follow(tret).match(TAbstract({path: {pack: [], name: "Void"}}, _));
					case _:
						try {
							hxc.core.TypeUnification.typeEqKind(
								ctx.com.platformConfig.isStatic ? EqDoNotFollowNull : EqStrict, result.type, tret);
							false;
						} catch (_:Dynamic) true;
				};
				if (needsCast) result = TypeFunctions.mk(TCast(result, null), tret, p);
			}
		}
		// A constant-initialized local this inline bound, with no remaining use, drops to an empty block
		// (expression reduction's no-op filter strips it from block element lists). Covers the null
		// receiver a multiType @:to cast is called with (the `var t = null` of Map's toIntMap).
		// Eligibility is restricted to the binds; body-declared clones live in subst values
		// indistinguishably from substituted caller locals, so they stay exempt.
		var inlineVars = new Map<Int, Bool>();
		for (b in binds) switch (b.expr) {
			case TVarExpr(v, _): inlineVars.set(v.id, true);
			case _:
		}
		if (vthis != null) inlineVars.set(vthis.id, true);
		var used = new Map<Int, Bool>();
		function countLocals(e:TExpr):Void {
			switch (e.expr) {
				case TLocal(v): used.set(v.id, true);
				case TVarExpr(_, eo): if (eo != null) countLocals(eo);
				case _: TexprTools.iter(countLocals, e);
			}
		}
		countLocals(result);
		function dropUnusedVars(e:TExpr):TExpr {
			return switch (e.expr) {
				case TVarExpr(v, {expr: TConst(_)}) if (inlineVars.exists(v.id) && !used.exists(v.id)):
					TypeFunctions.mk(TBlock([]), e.type, e.pos);
				case _: TexprTools.mapExpr(dropUnusedVars, e);
			}
		}
		return dropUnusedVars(result);
	}

	static function countThisUses(root:TExpr):Int {
		var count = 0;
		// A read inside a loop body counts double, so a receiver used once in
		// a loop still binds to a temp.
		function loop(inLoop:Bool, e:TExpr):Void {
			switch (e.expr) {
				case TConst(TThis): count += inLoop ? 2 : 1;
				case TFor(_, e1, body):
					loop(inLoop, e1);
					loop(true, body);
				case TWhile(cond, body, _):
					loop(inLoop, cond);
					loop(true, body);
				case _: TexprTools.iter(function(x) loop(inLoop, x), e);
			}
		}
		loop(false, root);
		return count;
	}

	// Abstract operator bodies may write through their abstract receiver. Preserve the reference
	// check_write diagnostics after receiver substitution, in particular for final fields and locals
	// passed to the inline operator.
	static function checkAbstractWrite(root:TExpr, ?errorPos:Position):Void {
		var ep = function(e:TExpr) return errorPos == null ? e.pos : errorPos;
		function check(e:TExpr):Void {
			switch (e.expr) {
				case TBinop(OpAssign | OpAssignOp(_), lhs, _):
					switch (lhs.expr) {
						case TLocal(v) if (TypeFunctions.hasVarFlag(v, VFinal)):
							throw new TypingError("Cannot modify abstract value of final local", ep(lhs));
						case TField(_, fa):
							var cf = switch (fa) {
								case FInstance(_, _, f) | FStatic(_, f) | FAnon(f) | FClosure(_, f): f;
								case FEnum(_, _) | FDynamic(_): null;
							};
							if (cf != null && TypeFunctions.hasClassFieldFlag(cf, CfFinal))
								throw new TypingError("Cannot modify abstract value of final field", ep(lhs));
						case _:
					}
					check(lhs);
					TexprTools.iter(check, e);
				case TUnop(Increment | Decrement, _, lhs):
					switch (lhs.expr) {
						case TLocal(v) if (TypeFunctions.hasVarFlag(v, VFinal)):
							throw new TypingError("Cannot modify abstract value of final local", ep(lhs));
						case TField(_, fa):
							var cf = switch (fa) {
								case FInstance(_, _, f) | FStatic(_, f) | FAnon(f) | FClosure(_, f): f;
								case FEnum(_, _) | FDynamic(_): null;
							};
							if (cf != null && TypeFunctions.hasClassFieldFlag(cf, CfFinal))
								throw new TypingError("Cannot modify abstract value of final field", ep(lhs));
						case _:
					}
					TexprTools.iter(check, e);
				case _:
					TexprTools.iter(check, e);
			}
		}
		check(root);
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
	static function argUsage(v:TVar, body:TExpr):{reads:Int, called:Int, writes:Bool, captured:Bool} {
		var reads = 0, called = 0, writes = false, captured = false;
		// A read inside a loop body counts double.
		function loop(inClosure:Bool, inLoop:Bool, e:TExpr):Void {
			inline function bump() reads += inLoop ? 2 : 1;
			switch (e.expr) {
				// A use in DIRECT callee position counts as a call, not a read; the TFunction substitution
				// rule looks only at reads.
				case TCall({expr: TLocal(v2)}, args) if (v2 == v):
					called += inLoop ? 2 : 1;
					if (inClosure) captured = true;
					for (a in args) loop(inClosure, inLoop, a);
				case TLocal(v2) if (v2 == v):
					bump();
					if (inClosure) captured = true;
				case TBinop(OpAssign, {expr: TLocal(v2)}, e2) if (v2 == v):
					writes = true;
					loop(inClosure, inLoop, e2);
				case TBinop(OpAssignOp(_), {expr: TLocal(v2)}, e2) if (v2 == v):
					bump();
					writes = true;
					if (inClosure) captured = true;
					loop(inClosure, inLoop, e2);
				case TUnop(Increment | Decrement, _, {expr: TLocal(v2)}) if (v2 == v):
					bump();
					writes = true;
					if (inClosure) captured = true;
				case TFunction(f):
					loop(true, inLoop, f.expr);
				case TFor(_, e1, e2):
					loop(inClosure, inLoop, e1);
					loop(inClosure, true, e2);
				case TWhile(cond, e2, _):
					loop(inClosure, inLoop, cond);
					loop(inClosure, true, e2);
				case _:
					TexprTools.iter(function(e2) loop(inClosure, inLoop, e2), e);
			}
		}
		loop(false, false, body);
		return {reads: reads, called: called, writes: writes, captured: captured};
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
	static function inlineBody(ctx:TyperContext, body:TExpr, subst:Map<Int, TExpr>, vthis:Null<TVar>, ethis:Null<TExpr>, inlinePos:Position,
			keepPositions:Bool, abstractMember:Bool):TExpr {
		switch (body.expr) {
			case TReturn(eo):
				return eo == null ? TypeFunctions.mk(TConst(TNull), ctx.com.basic.tvoid, keepPositions ? body.pos : inlinePos) : mapExpr(ctx, eo, subst, vthis, ethis, inlinePos, keepPositions);
			case TBlock(stmts):
				if (stmts.length == 0) {
					// An empty terminal body maps to a null value typed as a fresh monomorph; the position
					// map
					// puts the block at the call position too.
					var t = TypeFunctions.mkMono();
					var bp = keepPositions ? body.pos : inlinePos;
					return TypeFunctions.mk(TBlock([TypeFunctions.mk(TConst(TNull), t, inlinePos)]), t, bp);
				}
				if (abstractMember && stmts.length == 2) switch (stmts[0].expr) {
					case TIf(condition, thenExpr, null) if (endsInReturn(thenExpr)):
						var thenValue = mapTerminal(ctx, thenExpr, subst, vthis, ethis, inlinePos, keepPositions);
						var elseValue = mapTerminal(ctx, stmts[1], subst, vthis, ethis, inlinePos, keepPositions);
						var valueType = thenValue.type != ctx.com.basic.tvoid ? thenValue.type : elseValue.type;
						return TypeFunctions.mk(TIf(mapExpr(ctx, condition, subst, vthis, ethis, inlinePos, keepPositions), thenValue, elseValue), valueType,
							keepPositions ? body.pos : inlinePos);
					case _:
				}
				var out:Array<TExpr> = [];
				var i = 0;
				while (i < stmts.length) {
					var s = stmts[i];
					var folded = foldEarlyReturnIf(stmts, i);
					if (folded != null) { out.push(mapTerminal(ctx, folded, subst, vthis, ethis, inlinePos, keepPositions)); break; }
					if (i == stmts.length - 1) out.push(mapTerminal(ctx, s, subst, vthis, ethis, inlinePos, keepPositions));
					else out.push(mapExpr(ctx, s, subst, vthis, ethis, inlinePos, keepPositions));
					i++;
				}
				return TypeFunctions.mk(TBlock(out), out[out.length - 1].type, keepPositions ? body.pos : inlinePos);
			case _:
				return mapTerminal(ctx, body, subst, vthis, ethis, inlinePos, keepPositions);
		}
	}

	// A `return e` in the body itself (not inside a nested closure) marks the inlined
	// expression as value-producing; it is set when a terminal `return e` is mapped, and
	// `return;` does not set it.
	static function bodyHasReturnValue(e:TExpr):Bool {
		var found = false;
		function loop(x:TExpr):Void {
			if (found) return;
			switch (x.expr) {
				case TReturn(eo): if (eo != null) found = true;
				case TFunction(_):
				case _: hxc.core.TexprTools.iter(loop, x);
			}
		}
		loop(e);
		return found;
	}

	static function endsInReturn(e:TExpr):Bool {
		return switch (e.expr) {
			case TReturn(_): true;
			case TBlock(stmts): stmts.length > 0 && endsInReturn(stmts[stmts.length - 1]);
			case _: false;
		};
	}

	// The expression is guaranteed to run a return when evaluated; constructs that may not
	// execute their body do not count.
	static function hasTermReturn(e:TExpr):Bool {
		switch (e.expr) {
			case TReturn(_): return true;
			case TFunction(_): return false;
			case TIf(_, _, null): return false;
			case TSwitch(_, _, null): return false;
			case TFor(_, _, _) | TWhile(_, _, NormalWhile): return false;
			case TTry(a, catches):
				var all = hasTermReturn(a);
				for (c in catches) all = all && hasTermReturn(c.expr);
				return all;
			case TIf(cond, a, b):
				return hasTermReturn(cond) || (hasTermReturn(a) && hasTermReturn(b));
			case TSwitch(cond, cases, def):
				if (hasTermReturn(cond)) return true;
				var all = hasTermReturn(def);
				for (c in cases) all = all && hasTermReturn(c.expr);
				return all;
			case TBinop(OpBoolAnd, a, b):
				return hasTermReturn(a) && hasTermReturn(b);
			case _:
				var found = false;
				hxc.core.TexprTools.iter(function(x) { if (!found) found = hasTermReturn(x); }, e);
				return found;
		}
	}

	// A `if (cond) <guaranteed return>;` statement folds the block's tail into its else branch so
	// the early return becomes terminal.
	static function foldEarlyReturnIf(stmts:Array<TExpr>, i:Int):Null<TExpr> {
		if (i >= stmts.length - 1) return null;
		return switch (stmts[i].expr) {
			case TIf(cond, e1, null) if (hasTermReturn(e1)):
				var s = stmts[i];
				var rest = stmts.slice(i + 1);
				var restBlock = TypeFunctions.mk(TBlock(rest), s.type, rest[rest.length - 1].pos);
				TypeFunctions.mk(TIf(cond, e1, restBlock), s.type, s.pos);
			case _: null;
		};
	}

	static function mapTerminal(ctx:TyperContext, e:TExpr, subst:Map<Int, TExpr>, vthis:Null<TVar>, ethis:Null<TExpr>, inlinePos:Position,
			keepPositions:Bool):TExpr {
		function m(x:TExpr):TExpr return mapExpr(ctx, x, subst, vthis, ethis, inlinePos, keepPositions);
		function terminal(x:TExpr):TExpr return mapTerminal(ctx, x, subst, vthis, ethis, inlinePos, keepPositions);
		// A Dynamic or Void inline-function return sticks to the whole inlined value; otherwise a node
		// whose own type is Void takes its branches' common type, and any other node keeps its own (more
		// precise) type. Without the last rule an if/switch typed to the declared return (e.g. Int over
		// Null<Int> branches) collapses to the branch type and the caller boxes it.
		function sharedType(values:Array<TExpr>):T {
			if (inlineFuncRetType != null) {
				var ftt = TypeFunctions.follow(inlineFuncRetType);
				if (ftt.match(TDynamic(_)) || isInlineVoid(ftt)) return inlineFuncRetType;
			}
			if (!isInlineVoid(TypeFunctions.follow(e.type))) return e.type;
			for (value in values) if (value.type != ctx.com.basic.tvoid) return value.type;
			return e.type;
		}
		switch (e.expr) {
			case TReturn(eo):
				return eo == null ? TypeFunctions.mk(TConst(TNull), ctx.com.basic.tvoid, keepPositions ? e.pos : inlinePos) : terminal(eo);
			case TBlock(stmts) if (stmts.length == 0):
				// An empty terminal block maps to a null value at the call position; the position map
				// repositions the block itself there as well.
				var t = TypeFunctions.mkMono();
				return TypeFunctions.mk(TBlock([TypeFunctions.mk(TConst(TNull), t, inlinePos)]), t, keepPositions ? e.pos : inlinePos);
			case TBlock(stmts):
				var out:Array<TExpr> = [];
				var i = 0;
				while (i < stmts.length) {
					var folded = foldEarlyReturnIf(stmts, i);
					if (folded != null) { out.push(terminal(folded)); break; }
					out.push(i == stmts.length - 1 ? terminal(stmts[i]) : m(stmts[i]));
					i++;
				}
				return TypeFunctions.mk(TBlock(out), out[out.length - 1].type, keepPositions ? e.pos : inlinePos);
			case TIf(c, a, b) if (b != null):
				var thenExpr = terminal(a);
				var elseExpr = terminal(b);
				return TypeFunctions.mk(TIf(m(c), thenExpr, elseExpr), sharedType([thenExpr, elseExpr]), keepPositions ? e.pos : inlinePos);
			case TSwitch(c, cases, def):
				var mappedCases = [for (caseDef in cases) {values: [for (v in caseDef.values) m(v)], expr: terminal(caseDef.expr)}];
				var mappedDefault = def == null ? null : terminal(def);
				var values = [for (caseDef in mappedCases) caseDef.expr];
				if (mappedDefault != null) values.push(mappedDefault);
				return TypeFunctions.mk(TSwitch(m(c), mappedCases, mappedDefault), sharedType(values), keepPositions ? e.pos : inlinePos);
			case TTry(e1, catches):
				// A terminal try maps its body and catch branches as terminal; the node takes the branches'
				// shared type (return_type).
				var body = terminal(e1);
				var mappedCatches = [for (c in catches) {
					var nv = TypeFunctions.allocVar(declareKind(c.v), c.v.name, c.v.type, c.v.pos);
					subst.set(c.v.id, TypeFunctions.mk(TLocal(nv), nv.type, c.v.pos));
					{v: nv, expr: terminal(c.expr)};
				}];
				var values = [body].concat([for (c in mappedCatches) c.expr]);
				return TypeFunctions.mk(TTry(body, mappedCatches), sharedType(values), keepPositions ? e.pos : inlinePos);
			case TParenthesis(e1):
				// Parentheses forward the term flag.
				var inner = terminal(e1);
				return TypeFunctions.mk(TParenthesis(inner), inner.type, keepPositions ? e.pos : inlinePos);
			case TMeta(entry, e1):
				// Metadata forwards the term flag and takes the
				// mapped expression's type.
				var inner = terminal(e1);
				return TypeFunctions.mk(TMeta(entry, inner), inner.type, keepPositions ? e.pos : inlinePos);
			case _:
				return m(e);
		}
	}

	// A body-declared local re-declared while inlining keeps its original kind, except a user var becomes
	// VInlined rather than VGenerated.
	static inline function declareKind(v:TVar):TVarKind {
		return switch (v.kind) {
			case VUser(_): VInlined;
			case k: k;
		};
	}

	// The non-terminal mapping lane: substitutes argument/this locals; a non-final return
	// aborts the inline. inLocalFun is set inside a closure, whose returns map through.
	static function mapExpr(ctx:TyperContext, e:TExpr, subst:Map<Int, TExpr>, vthis:Null<TVar>, ethis:Null<TExpr>, inlinePos:Position, keepPositions:Bool,
			inLocalFun:Bool = false):TExpr {
		function m(x:TExpr):TExpr return mapExpr(ctx, x, subst, vthis, ethis, inlinePos, keepPositions, inLocalFun);
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
				if (subst.exists(v.id)) {
					var se = subst.get(v.id);
					// A local-shaped substitution (a body-local clone or an argument temp) reads like any mapped
					// node: each READ takes the remapped position, not the declaration's. A non-local argument
					// value keeps its own position verbatim.
					return switch (se.expr) {
						case TLocal(_): TypeFunctions.mk(se.expr, se.type, keepPositions ? e.pos : inlinePos);
						case _: se;
					};
				}
				e.expr;
			case TArray(e1, e2): TArray(m(e1), m(e2));
			case TBinop(op = OpAssign | OpAssignOp(_), e1, e2):
				// inline_params a substitution cast unwraps on the assignment left-hand side so the write
				// goes to the underlying lvalue.
				var me1 = m(e1);
				switch (me1.expr) { case TCast(inner, null): me1 = inner; case _: }
				// The map's assign arm rebuilds a local left-hand side in place ({e1 with expr = TLocal
				// l.i_subst}), so it keeps its ORIGINAL position through the inline remap; the emitted
				// statement line derives from it.
				switch ([e1.expr, me1.expr]) {
					case [TLocal(_), TLocal(_)]: me1 = TypeFunctions.mk(me1.expr, me1.type, e1.pos);
					case _:
				}
				TBinop(op, me1, m(e2));
			case TBinop(op, e1, e2): TBinop(op, m(e1), m(e2));
			case TField(e1, fa): TField(m(e1), fa);
			case TParenthesis(e1): TParenthesis(m(e1));
			case TObjectDecl(fields): TObjectDecl([for (f in fields) {key: f.key, expr: m(f.expr)}]);
			case TArrayDecl(vals): TArrayDecl([for (x in vals) m(x)]);
			case TCall(se = {expr: TField(_, FStatic({path: {pack: [], name: "Std"}}, {name: "string"}))}, [sp]):
				// When substitution changes the argument's type (an abstract flowing into a scalar param),
				// cast it back so Std.string keeps the parameter's static-type semantics.
				var msp = m(sp);
				if (!hxc.core.TypeUnification.fastEq(TypeFunctions.follow(sp.type), TypeFunctions.follow(msp.type)))
					msp = TypeFunctions.mk(TCast(msp, null), sp.type, msp.pos);
				TCall(m(se), [msp]);
			case TCall(e1, ps):
				// A nested inline call in the body expands too, so a sibling call mutating the
				// abstract this still writes back to the substituted receiver (the reference
				// inliner expands inline calls inside inlined bodies).
				var me1 = m(e1);
				// finalize.inline_params VIInlineIfCalled: a call through a bound function-arg
				// local inlines the function expression (fresh tvars per site); the immediate
				// call then collapses in reduce.
				switch (me1.expr) {
					case TLocal(v2) if (v2.extra != null && v2.extra.expr != null
							&& TypeFunctions.hasMeta(":inlineIfCalled", v2.meta)):
						me1 = TexprTools.duplicateTvars(function(x) return x, v2.extra.expr);
					case _:
				}
				var mps = [for (x in ps) m(x)];
				var nested = tryInline(ctx, me1, mps, e.type, e.pos);
				if (nested != null) return nested;
				TCall(me1, mps);
			case TNew(c, tp, args): TNew(c, tp, [for (x in args) m(x)]);
			case TUnop(op = Increment | Decrement, fl, e1):
				// Increment targets unwrap the substitution cast like assignment left-hand sides.
				var me1 = m(e1);
				switch (me1.expr) { case TCast(inner, null): me1 = inner; case _: }
				// Like the assign arm, a local increment target keeps its original position {e1 with expr =
				// TLocal l.i_subst} in place).
				switch ([e1.expr, me1.expr]) {
					case [TLocal(_), TLocal(_)]: me1 = TypeFunctions.mk(me1.expr, me1.type, e1.pos);
					case _:
				}
				TUnop(op, fl, me1);
			case TUnop(op, fl, e1): TUnop(op, fl, m(e1));
			case TVarExpr(v, eo):
				if (TypeFunctions.hasVarFlag(v, VStatic)) throw new TypingError("Inline functions cannot have static locals", v.pos);
				var nv = TypeFunctions.allocVar(declareKind(v), v.name, v.type, v.pos);
				// The declared copy keeps extra; find_abstract chases its expr to recover the abstract receiver
				// type behind an IMap-typed temp.
				nv.extra = v.extra;
				subst.set(v.id, TypeFunctions.mk(TLocal(nv), nv.type, v.pos));
				TVarExpr(nv, eo == null ? null : m(eo));
			case TBlock(el): TBlock([for (x in el) m(x)]);
			case TFor(v, e1, e2):
				var me1 = m(e1);
				var hadOld = subst.exists(v.id);
				var old = hadOld ? subst.get(v.id) : null;
				var nv = TypeFunctions.allocVar(declareKind(v), v.name, v.type, v.pos);
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
			case TReturn(eo):
				// A return inside a local function belongs to the closure and maps through;
				// anywhere else in non-terminal position the inline gives up.
				if (!inLocalFun) throw new InlineBail(true);
				TReturn(eo == null ? null : m(eo));
			case TSwitch(subject, cases, def):
				// A non-terminal switch maps structurally; only a return inside one still aborts. (the
				// Type.map_expr catch-all; TSwitch is special-cased only `when term`).
				TSwitch(m(subject), [for (c in cases) {values: [for (v in c.values) m(v)], expr: m(c.expr)}], def == null ? null : m(def));
			case TTry(e1, catches):
				// Try branches map with the current term flag (non-terminal here); each catch variable
				// re-declares as a fresh local (state#declare).
				var me1 = m(e1);
				TTry(me1, [for (c in catches) {
					var nv = TypeFunctions.allocVar(declareKind(c.v), c.v.name, c.v.type, c.v.pos);
					subst.set(c.v.id, TypeFunctions.mk(TLocal(nv), nv.type, c.v.pos));
					{v: nv, expr: m(c.expr)};
				}]);
			case TFunction(f):
				// A closure inside the inlined body maps non-terminal with inLocalFun set, its own
				// arguments
				// re-declared as fresh locals; outer substitutions apply inside so the closure references
				// the
				// inlined bindings rather than the callee's argument vars.
				var nargs:Array<TFuncArg> = [for (a in f.args) {
					var nv = TypeFunctions.allocVar(declareKind(a.v), a.v.name, a.v.type, a.v.pos);
					subst.set(a.v.id, TypeFunctions.mk(TLocal(nv), nv.type, a.v.pos));
					{v: nv, c: a.c == null ? null : m(a.c)};
				}];
				var body = mapExpr(ctx, f.expr, subst, vthis, ethis, inlinePos, keepPositions, true);
				TFunction(new TFunc(nargs, f.type, body));
		};
		return TypeFunctions.mk(ne, e.type, keepPositions ? e.pos : inlinePos);
	}

}
