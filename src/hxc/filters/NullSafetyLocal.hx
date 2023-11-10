package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.filters.NullSafety;
import hxc.filters.NullSafetyScopes;

// Collects null-checked locals/fields across nested scopes.
class LocalSafety {
	var mode:SafetyMode;
	var scopes:Array<SafetyScope>;

	public function new(mode:SafetyMode) {
		this.mode = mode;
		scopes = [new SafetyScope(mode, STNormal, new Map(), new Map())];
	}

	public function clear():Void {
		scopes = [new SafetyScope(mode, STNormal, new Map(), new Map())];
	}

	function getCurrentScope():SafetyScope {
		return scopes[0];
	}

	public function getSafeLocalsCopy():Map<String, TExpr> {
		var out:Map<String, TExpr> = new Map();
		var cur = getCurrentScope();
		for (k in cur.safeLocals.keys()) out.set(k, cur.safeLocals.get(k));
		return out;
	}

	public function filterSafety(sample:Map<String, TExpr>):Void {
		getCurrentScope().filterSafety(sample);
	}

	public function functionDeclared(immediateExecution:Bool, fn:TFunc):Void {
		var scope = if (immediateExecution || mode == SMLoose)
			new SafetyScope(mode, STImmediateClosure, getCurrentScope().safeLocals, getCurrentScope().neverSafe)
		else
			new SafetyScope(mode, STClosure, new Map(), new Map());
		scopes.unshift(scope);
		for (a in fn.args) scope.declareVar(a.v);
	}

	public function blockDeclared():Void {
		scopes.unshift(new SafetyScope(mode, STNormal, getCurrentScope().safeLocals, getCurrentScope().neverSafe));
	}

	public function loopDeclared(e:TExpr):Void {
		var scope = new SafetyScope(mode, STLoop, getCurrentScope().safeLocals, getCurrentScope().neverSafe);
		scopes.unshift(scope);
		switch (e.expr) {
			case TFor(v, _, _): scope.declareVar(v);
			case TWhile(_, _, _):
			case _:
		}
	}

	public function scopeClosed():Void {
		if (scopes.length > 1) scopes.shift();
	}

	public function declareVar(v:TVar, isSafe:Bool = false):Void {
		var scope = getCurrentScope();
		scope.declareVar(v);
		if (isSafe) scope.addToSafety(TypeFunctions.mk(TVarExpr(v, null), v.type, v.pos));
	}

	public function isSafe(expr:TExpr):Bool {
		if (!NullSafety.isNullableType(expr.type)) return true;
		function captured():Bool {
			return switch (expr.expr) {
				case TLocal(localVar):
					for (current in scopes) {
						if (current.ownsVar(localVar)) return false;
						if (current.scopeType == STClosure) return true;
					}
					false;
				case _: false;
			}
		}
		return (mode == SMLoose || !captured()) && getCurrentScope().isSafe(expr);
	}

	public function processWhile(expr:TExpr, isNullableExpr:TExpr->Bool, conditionCallback:TExpr->Void, bodyCallback:(Void->Void)->TExpr->Void):Void {
		switch (expr.expr) {
			case TWhile(condition, body, DoWhile):
				var originalSafeLocals = getSafeLocalsCopy();
				conditionCallback(condition);
				var res = NullSafety.processCondition(mode, condition, isNullableExpr, function(_) {});
				bodyCallback(function() {
					for (notNull in res.notNulls) {
						switch (NullSafety.getSubject(mode, notNull)) {
							case SNotSuitable:
							case subj:
								if (originalSafeLocals.exists(NullSafety.subjectKey(subj)))
									getCurrentScope().addToSafety(notNull);
						}
					}
				}, body);
			case TWhile(condition, body, NormalWhile):
				conditionCallback(condition);
				var res = NullSafety.processCondition(mode, condition, isNullableExpr, function(_) {});
				for (n in res.notNulls) getCurrentScope().addToSafety(n);
				bodyCallback(function() {
					for (n in res.notNulls) getCurrentScope().addToSafety(n);
				}, body);
				for (n in res.notNulls) getCurrentScope().removeFromSafety(n);
			case _:
		}
	}

	public function processLoopBody(firstCheck:Void->Void, intermediateAction:Null<Void->Void>, secondCheck:Void->Void):Void {
		var originalSafeLocals = getSafeLocalsCopy();
		// The first pass finds out which vars become unsafe in the loop.
		firstCheck();
		filterSafety(originalSafeLocals);
		if (intermediateAction != null) intermediateAction();
		secondCheck();
	}

	public function processTry(tryBlock:TExpr, catches:Array<TCatch>, checkExpr:TExpr->Void):Void {
		var originalSafeLocals = getSafeLocalsCopy();
		checkExpr(tryBlock);
		filterSafety(originalSafeLocals);
		var safeAfterTry = getSafeLocalsCopy();
		var safeAfterCatches = getSafeLocalsCopy();
		for (c in catches) {
			getCurrentScope().resetTo(safeAfterTry);
			checkExpr(c.expr);
			for (key in [for (k in safeAfterCatches.keys()) k]) {
				var v = safeAfterCatches.get(key);
				if (!isSafe(v)) safeAfterCatches.remove(key);
			}
		}
		getCurrentScope().resetTo(safeAfterCatches);
	}

	public function processIf(expr:TExpr, isNullableExpr:TExpr->Bool, conditionCallback:TExpr->Void, bodyCallback:TExpr->Void):Void {
		switch (expr.expr) {
			case TIf(condition, ifBody, elseBody):
				conditionCallback(condition);
				var res = NullSafety.processCondition(mode, condition, isNullableExpr, function(_) {});
				var nullsInIf = res.nulls;
				// Expressions that were already safe before this if stay untouched.
				var notNulls = [for (e in res.notNulls) if (!isSafe(e)) e];
				var notCondition = TypeFunctions.mk(TUnop(Not, Prefix, condition), condition.type, condition.pos);
				var elseRes = NullSafety.processCondition(mode, notCondition, isNullableExpr, function(_) {});
				var elseNotNulls = [for (e in elseRes.notNulls) if (!isSafe(e)) e];
				var initialSafe = getSafeLocalsCopy();
				for (n in notNulls) getCurrentScope().addToSafety(n);
				bodyCallback(ifBody);
				var safeAfterIf = getSafeLocalsCopy();
				getCurrentScope().resetTo(initialSafe);
				function handleDeadEnd(body:TExpr, safeVars:Array<TExpr>):Void {
					if (TexprTools.hasDeadEnd(body))
						for (v in safeVars) getCurrentScope().addToSafety(v);
				}
				if (elseBody == null) {
					// The if runs only when each of nullsInIf is null: safe-in-if stays safe after.
					for (e in nullsInIf) {
						switch (getCurrentScope().getSubject(e)) {
							case SNotSuitable:
							case subj:
								if (safeAfterIf.exists(NullSafety.subjectKey(subj)))
									getCurrentScope().addToSafety(e);
						}
					}
					for (key in initialSafe.keys()) {
						if (!safeAfterIf.exists(key))
							getCurrentScope().removeFromSafety(initialSafe.get(key));
					}
					handleDeadEnd(ifBody, elseNotNulls);
				} else {
					for (n in elseNotNulls) getCurrentScope().addToSafety(n);
					bodyCallback(elseBody);
					var safeAfterElse = getSafeLocalsCopy();
					getCurrentScope().resetTo(initialSafe);
					for (key in initialSafe.keys()) {
						if (!(safeAfterIf.exists(key) && safeAfterElse.exists(key)))
							getCurrentScope().removeFromSafety(initialSafe.get(key));
						safeAfterIf.remove(key);
						safeAfterElse.remove(key);
					}
					for (key in safeAfterIf.keys()) {
						if (safeAfterElse.exists(key))
							getCurrentScope().addToSafety(safeAfterIf.get(key));
					}
					handleDeadEnd(ifBody, elseNotNulls);
					handleDeadEnd(elseBody, notNulls);
				}
			case _:
		}
	}

	public function processAnd(leftExpr:TExpr, rightExpr:TExpr, isNullableExpr:TExpr->Bool, callback:TExpr->Void):Void {
		callback(leftExpr);
		var res = NullSafety.processCondition(mode, leftExpr, isNullableExpr, function(_) {});
		for (n in res.notNulls) getCurrentScope().addToSafety(n);
		callback(rightExpr);
		for (n in res.notNulls) getCurrentScope().removeFromSafety(n);
	}

	public function processOr(leftExpr:TExpr, rightExpr:TExpr, isNullableExpr:TExpr->Bool, callback:TExpr->Void):Void {
		var res = NullSafety.processCondition(mode, leftExpr, isNullableExpr, callback);
		for (n in res.nulls) getCurrentScope().addToSafety(n);
		callback(rightExpr);
		for (n in res.nulls) getCurrentScope().removeFromSafety(n);
	}

	public function handleAssignment(isNullableExpr:TExpr->Bool, leftExpr:TExpr, rightExpr:TExpr):Void {
		if (!NullSafety.isSuitable(mode, leftExpr)) return;
		getCurrentScope().reassigned(leftExpr);
		if (isNullableExpr(rightExpr)) {
			switch (leftExpr.expr) {
				case TLocal(v):
					var captured = false;
					for (current in scopes) {
						if (current.ownsVar(v)) {
							current.removeFromSafety(leftExpr, captured);
							break;
						} else {
							captured = captured || current.scopeType == STClosure;
							current.removeFromSafety(leftExpr, captured);
						}
					}
				case _:
			}
		} else if (NullSafety.isNullableType(leftExpr.type)) {
			getCurrentScope().addToSafety(leftExpr);
		}
	}

	public function callMade():Void getCurrentScope().callMade();
}
