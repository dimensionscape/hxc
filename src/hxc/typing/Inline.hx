package hxc.typing;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.typing.TyperContext;
import hxc.typing.TypeFields;

// Falling back to a normal TCall whenever a construct is outside the handled subset. Exact
// in result for what it handles, safe otherwise.
private class InlineBail extends haxe.Exception {
	public function new() super("inline-bail");
}

// Compile-time expansion of inline-function calls, a safe subset ported It handles expression-bodied inline
// functions (single or final return, no early returns, no nested loops/switch/try/closures, no type
// parameters): arguments and `this` bind to fresh locals and the body is substituted in place. Anything
// else bails and the caller emits a normal call. Types in the inlined body are left as-is (the evaluator
// runs the result without re-typing, so values stay correct).
class Inline {
	public static function tryInline(ctx:TyperContext, e:TExpr, params:Array<TExpr>, tret:T, p:Position):Null<TExpr> {
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
		return try doInline(ctx, tf, ethis, isStatic, params, tret, absMember, p) catch (_:InlineBail) null;
	}

	static function doInline(ctx:TyperContext, tf:TFunc, ethis:Null<TExpr>, isStatic:Bool, params:Array<TExpr>, tret:T, absMember:Bool, p:Position):TExpr {
		var subst = new Map<Int, TVar>();
		var binds:Array<TExpr> = [];
		var tvoid = ctx.com.basic.tvoid;
		var vthis:Null<TVar> = null;
		if (!isStatic) {
			if (ethis == null) throw new InlineBail();
			vthis = TypeFunctions.allocVar(VGenerated, "_hx_this", ethis.type, p);
			binds.push(TypeFunctions.mk(TVarExpr(vthis, ethis), tvoid, p));
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
			var directLocal = (absMember && i == 0) ? (switch (param.expr) { case TLocal(v): v; case _: null; }) : null;
			if (directLocal != null) {
				subst.set(av.id, directLocal);
			} else {
				var nv = TypeFunctions.allocVar(VGenerated, av.name, av.type, p);
				subst.set(av.id, nv);
				binds.push(TypeFunctions.mk(TVarExpr(nv, param), tvoid, p));
			}
		}
		var value = inlineBody(ctx, tf.expr, subst, vthis);
		return TypeFunctions.mk(TBlock(binds.concat([value])), tret, p);
	}

	// The body reduced to its result value: a single or final return's value, else the body itself.
	static function inlineBody(ctx:TyperContext, body:TExpr, subst:Map<Int, TVar>, vthis:Null<TVar>):TExpr {
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

	// Substitutes argument/this locals; bails on anything outside the handled subset (notably any
	// non-final return, nested function, or loop/switch/try carrying control flow).
	static function mapExpr(ctx:TyperContext, e:TExpr, subst:Map<Int, TVar>, vthis:Null<TVar>):TExpr {
		function m(x:TExpr):TExpr return mapExpr(ctx, x, subst, vthis);
		var ne:TExprExpr = switch (e.expr) {
			case TConst(TThis):
				if (vthis == null) throw new InlineBail();
				TLocal(vthis);
			case TConst(_): e.expr;
			case TLocal(v): subst.exists(v.id) ? TLocal(subst.get(v.id)) : e.expr;
			case TArray(e1, e2): TArray(m(e1), m(e2));
			case TBinop(op, e1, e2): TBinop(op, m(e1), m(e2));
			case TField(e1, fa): TField(m(e1), fa);
			case TParenthesis(e1): TParenthesis(m(e1));
			case TObjectDecl(fields): TObjectDecl([for (f in fields) {key: f.key, expr: m(f.expr)}]);
			case TArrayDecl(vals): TArrayDecl([for (x in vals) m(x)]);
			case TCall(e1, ps): TCall(m(e1), [for (x in ps) m(x)]);
			case TNew(c, tp, args): TNew(c, tp, [for (x in args) m(x)]);
			case TUnop(op, fl, e1): TUnop(op, fl, m(e1));
			case TVarExpr(v, eo):
				var nv = TypeFunctions.allocVar(VGenerated, v.name, v.type, v.pos);
				subst.set(v.id, nv);
				TVarExpr(nv, eo == null ? null : m(eo));
			case TBlock(el): TBlock([for (x in el) m(x)]);
			case TIf(c, a, b): TIf(m(c), m(a), b == null ? null : m(b));
			case TCast(e1, mt): TCast(m(e1), mt);
			case TMeta(entry, e1): TMeta(entry, m(e1));
			case TThrow(e1): TThrow(m(e1));
			case TEnumParameter(e1, ef, idx): TEnumParameter(m(e1), ef, idx);
			case TEnumIndex(e1): TEnumIndex(m(e1));
			case TTypeExpr(_) | TIdent(_) | TBreak | TContinue: e.expr;
			case TReturn(_) | TFunction(_) | TWhile(_, _, _) | TFor(_, _, _) | TSwitch(_, _, _) | TTry(_, _):
				throw new InlineBail();
		};
		return TypeFunctions.mk(ne, e.type, e.pos);
	}
}
