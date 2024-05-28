package hxc.typing;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;

// Removes a side-effect-free expression whose value is unused, the analyzer elimination the unit
// suite relies on under -D analyzer-optimize (a pure case body like an interpolated string never
// evaluates, so a null receiver inside it never dereferences). Statement positions are tracked
// structurally: a block drops its pure statements, a value block keeps its last element.
class UnusedPure {
	public static function run(ctx:Context):Void {
		if (!ctx.defines.rawDefined("analyzer_optimize")) return;
		// The eliminations here stand in for the analyzer's local-dce, so they obey the same
		// per-field config: @:analyzer(ignore/no_optimize/no_local_dce) and :has_untyped disable
		// them exactly as they disable that pass (an @:analyzer(no_local_dce) method keeps its pure
		// statements).
		inline function fieldRuns(c:hxc.core.Type.TClass, f:TClassField):Bool {
			// An @:analyzer(ignore) class is skipped before any option parsing, so its meta never reaches
			// the per-field config reader (which would warn on the unlisted "ignore" flag, e.g.
			// cpp/_std/Reflect.hx).
			if (hxc.optimization.AnalyzerConfig.isIgnored(c.meta)) return false;
			if (hxc.optimization.AnalyzerConfig.isIgnored(f.meta)) return false;
			var config = hxc.optimization.AnalyzerConfig.getFieldConfig(ctx, c, f);
			return config.optimize && config.localDce;
		}
		for (m in ctx.modules) for (mt in m.types) switch (mt) {
			case TClassDecl(c):
				// A field expression is a value: a method's is its TFunction (whose body is the
				// statement), a var's is its initializer whose result must survive.
				for (f in c.orderedFields) if (f.expr != null && fieldRuns(c, f)) f.expr = value(f.expr);
				for (f in c.orderedStatics) if (f.expr != null && fieldRuns(c, f)) f.expr = value(f.expr);
				if (c.constructor != null && c.constructor.expr != null && fieldRuns(c, c.constructor))
					c.constructor.expr = value(c.constructor.expr);
			case _:
		}
	}

	// A pure expression computes no effect: dropping the whole subtree is safe. Purity is a
	// conservative whitelist; a local declared inside counts as pure because it only escapes if
	// some impure expression reads it, which would keep the subtree.
	static function isPure(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TIdent(_): true;
			case TField(e1, fa):
				// A property read dispatches its accessor; only a plain var read (or a method closure
				// read) is effect-free.
				var readPure = switch (fa) {
					case FDynamic(_): false;
					case FEnum(_, _): true;
					case FInstance(_, _, f) | FStatic(_, f) | FAnon(f) | FClosure(_, f):
						switch (f.kind) {
							case Var({read: AccCall | AccRequire(_, _)}): false;
							case _: true;
						}
				};
				readPure && isPure(e1);
			case TParenthesis(e1) | TMeta(_, e1): isPure(e1);
			case TCast(e1, null): isPure(e1);
			case TBinop(OpAssign | OpAssignOp(_), _, _): false;
			case TBinop(_, a, b): isPure(a) && isPure(b);
			case TUnop(Increment | Decrement, _, _): false;
			case TUnop(_, _, e1): isPure(e1);
			case TArrayDecl(el) | TBlock(el): allPure(el);
			case TObjectDecl(fl): { var ok = true; for (f in fl) if (!isPure(f.expr)) { ok = false; break; } ok; }
			case TVarExpr(_, eo): eo == null || isPure(eo);
			case TIf(c, a, b): isPure(c) && isPure(a) && (b == null || isPure(b));
			case TSwitch(s, cases, def):
				var ok = isPure(s) && (def == null || isPure(def));
				if (ok) for (c in cases) { if (!allPure(c.values) || !isPure(c.expr)) { ok = false; break; } }
				ok;
			case TCall({expr: TField(_, FStatic(c, cf))}, args) if (c.path.pack.length == 0 && c.path.name == "Std" && cf.name == "string"):
				allPure(args);
			case TEnumParameter(e1, _, _) | TEnumIndex(e1): isPure(e1);
			case _: false;
		};
	}

	static function allPure(el:Array<TExpr>):Bool {
		for (e in el) if (!isPure(e)) return false;
		return true;
	}

	// Statement position: the value is unused.
	static function stmt(e:TExpr):TExpr {
		inline function mk2(ed:TExprExpr):TExpr return TypeFunctions.mk(ed, e.type, e.pos);
		return switch (e.expr) {
			case TBlock(el):
				var out = [];
				for (x in el) {
					var y = stmt(x);
					// A var declaration never drops at block level: a later statement may read the
					// local. It still counts as pure inside a wholly dropped subtree, where every
					// possible reader is dropped with it.
					if (!isPure(y) || y.expr.match(TVarExpr(_, _))) out.push(y);
				}
				mk2(TBlock(out));
			case TIf(c, a, b): mk2(TIf(value(c), stmt(a), b == null ? null : stmt(b)));
			case TWhile(c, body, flag): mk2(TWhile(value(c), stmt(body), flag));
			case TFor(v, e1, body): mk2(TFor(v, value(e1), stmt(body)));
			case TSwitch(s, cases, def):
				mk2(TSwitch(value(s), [for (c in cases) {values: c.values, expr: stmt(c.expr)}], def == null ? null : stmt(def)));
			case TTry(e1, catches): mk2(TTry(stmt(e1), [for (c in catches) {v: c.v, expr: stmt(c.expr)}]));
			case TMeta(m, e1): mk2(TMeta(m, stmt(e1)));
			case TParenthesis(e1): mk2(TParenthesis(stmt(e1)));
			case _: value(e);
		};
	}

	// Value position: the expression's result is consumed; only recurse into positions that are
	// themselves statements (function bodies, loop bodies).
	static function value(e:TExpr):TExpr {
		inline function mk2(ed:TExprExpr):TExpr return TypeFunctions.mk(ed, e.type, e.pos);
		return switch (e.expr) {
			case TBlock(el) if (el.length > 0):
				var out = [];
				for (i in 0...el.length - 1) {
					var y = stmt(el[i]);
					if (!isPure(y) || y.expr.match(TVarExpr(_, _))) out.push(y);
				}
				out.push(value(el[el.length - 1]));
				mk2(TBlock(out));
			case TFunction(f): mk2(TFunction(new TFunc(f.args, f.type, stmt(f.expr))));
			case TIf(c, a, b) if (b != null): mk2(TIf(value(c), value(a), value(b)));
			case TIf(c, a, null): mk2(TIf(value(c), stmt(a), null));
			case TWhile(c, body, flag): mk2(TWhile(value(c), stmt(body), flag));
			case TFor(v, e1, body): mk2(TFor(v, value(e1), stmt(body)));
			case TSwitch(s, cases, def):
				mk2(TSwitch(value(s), [for (c in cases) {values: c.values, expr: value(c.expr)}], def == null ? null : value(def)));
			case TTry(e1, catches): mk2(TTry(value(e1), [for (c in catches) {v: c.v, expr: value(c.expr)}]));
			case TVarExpr(v, eo): mk2(TVarExpr(v, eo == null ? null : value(eo)));
			case TReturn(eo): mk2(TReturn(eo == null ? null : value(eo)));
			case TThrow(e1): mk2(TThrow(value(e1)));
			case TBinop(op, a, b): mk2(TBinop(op, value(a), value(b)));
			case TUnop(op, flag, e1): mk2(TUnop(op, flag, value(e1)));
			case TArray(a, i): mk2(TArray(value(a), value(i)));
			case TArrayDecl(el): mk2(TArrayDecl([for (x in el) value(x)]));
			case TObjectDecl(fl): mk2(TObjectDecl([for (f in fl) {key: f.key, expr: value(f.expr)}]));
			case TCall(callee, args): mk2(TCall(value(callee), [for (a in args) value(a)]));
			case TNew(c, tl, args): mk2(TNew(c, tl, [for (a in args) value(a)]));
			case TField(e1, fa): mk2(TField(value(e1), fa));
			case TParenthesis(e1): mk2(TParenthesis(value(e1)));
			case TMeta(m, e1): mk2(TMeta(m, value(e1)));
			case TCast(e1, mt): mk2(TCast(value(e1), mt));
			case TEnumParameter(e1, ef, i): mk2(TEnumParameter(value(e1), ef, i));
			case TEnumIndex(e1): mk2(TEnumIndex(value(e1)));
			case _: e;
		};
	}
}
