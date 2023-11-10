package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.filters.NullSafety;
import hxc.filters.NullSafetyScopes;
import hxc.filters.NullSafetyLocal;

// Recursively checks typed expressions for null safety.
class ExprChecker {
	public var mode:SafetyMode;
	var immediateExecution:ImmediateExecution;
	var report:Array<{msg:String, pos:Position}>;
	var localSafety:LocalSafety;
	var returnTypes:Array<T> = [];
	var isPretending:Bool = false;

	public function new(mode:SafetyMode, immediateExecution:ImmediateExecution, report:Array<{msg:String, pos:Position}>) {
		this.mode = mode;
		this.immediateExecution = immediateExecution;
		this.report = report;
		localSafety = new LocalSafety(mode);
	}

	public function error(msg:String, positions:Array<Position>):Void {
		if (isPretending) return;
		var pos = Position.nullPos;
		for (p in positions) if (p != null && p.min >= 0) { pos = p; break; }
		NullSafety.addError(report, msg, pos);
	}

	// Check nullability structurally; the type alone is insufficient.
	function isNullableExpr(e:TExpr):Bool {
		e = NullSafety.revealExpr(e);
		return switch (e.expr) {
			case TConst(TNull): true;
			case TConst(_): false;
			case TParenthesis(e1): isNullableExpr(e1);
			case TMeta(m, _) if (NullSafety.containsUnsafeMeta([m])): false;
			case TMeta(_, e1): isNullableExpr(e1);
			case TThrow(_) | TReturn(_) | TContinue | TBreak: false;
			case TBinop(OpAssign | OpAssignOp(_), _, right): isNullableExpr(right);
			case TBlock(exprs):
				localSafety.blockDeclared();
				var nullable = false;
				for (i in 0...exprs.length) {
					if (i == exprs.length - 1) nullable = isNullableExpr(exprs[i])
					else switch (exprs[i].expr) {
						case TVarExpr(v, _): localSafety.declareVar(v);
						case _:
					}
				}
				localSafety.scopeClosed();
				nullable;
			case TIf(_, _, _):
				var nullable = false;
				localSafety.processIf(e, isNullableExpr, function(_) {}, function(body) nullable = nullable || isNullableExpr(body));
				nullable;
			case _:
				NullSafety.isNullableType(e.type) && !localSafety.isSafe(e);
		}
	}

	// Can expr be passed where toType is expected.
	function canPassExpr(expr:TExpr, toType:T, p:Position):Bool {
		switch ([expr.expr, toType]) {
			case [TLocal(v), _] if (NullSafety.containsUnsafeMeta(v.meta)): return true;
			case [TObjectDecl(fields), TAnon(anon)]:
				for (f in fields) {
					var fieldTo = anon.fields.get(f.key.name);
					if (fieldTo == null) return false;
					if (!canPassExpr(f.expr, fieldTo.type, p)) return false;
				}
				return true;
			case _:
		}
		if (isNullableExpr(expr) && !NullSafety.isNullableType(toType, true)) return false;
		var exprType = NullSafety.unfoldNull(expr.type);
		return try {
			new Unificator().unify(exprType, toType);
			true;
		} catch (_:SafetyError) {
			error("Cannot unify " + NullSafety.strType(exprType) + " with " + NullSafety.strType(toType), [p, expr.pos]);
			true; // The error is already logged.
		}
	}

	public function checkRootExpr(e:TExpr):Void {
		checkExpr(e);
		localSafety.clear();
		returnTypes = [];
	}

	function checkExpr(e:TExpr):Void {
		switch (e.expr) {
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_):
			case TArray(arr, idx): checkArrayAccess(arr, idx, e.pos);
			case TBinop(op, l, r): checkBinop(op, l, r, e.pos);
			case TField(target, access): checkField(target, access, e.pos);
			case TParenthesis(e1): checkExpr(e1);
			case TObjectDecl(fields): for (f in fields) checkExpr(f.expr);
			case TArrayDecl(items): checkArrayDecl(items, e.type, e.pos);
			case TCall(callee, args): checkCall(callee, args, e.pos);
			case TNew(_, _, _): checkNew(e);
			case TUnop(_, _, e1): checkUnop(e1, e.pos);
			case TFunction(fn): checkFunction(fn, false);
			case TVarExpr(v, init): checkVar(v, init, e.pos);
			case TBlock(exprs): checkBlock(exprs, e.pos);
			case TFor(_, _, _): checkFor(e);
			case TIf(_, _, _): checkIf(e);
			case TWhile(_, _, _): checkWhile(e);
			case TSwitch(target, cases, def): checkSwitch(target, cases, def, e.pos);
			case TTry(tryBlock, catches): checkTry(tryBlock, catches);
			case TReturn(expr) if (expr != null): checkReturn(expr, e.pos);
			case TReturn(_):
			case TThrow(expr): checkThrow(expr, e.pos);
			case TCast(expr, _): checkCast(expr, e.type, e.pos);
			case TMeta(m, _) if (NullSafety.containsUnsafeMeta([m])):
			case TMeta(m, e1) if (m.name == ":nullSafety"):
				NullSafety.validateSafetyMeta(report, [m]);
				checkExpr(e1);
			case TMeta(_, e1): checkExpr(e1);
			case TEnumIndex(idx): checkEnumIndex(idx, e.pos);
			case TEnumParameter(e1, _, _): checkExpr(e1);
		}
	}

	function checkBlock(exprs:Array<TExpr>, p:Position):Void {
		localSafety.blockDeclared();
		for (e in exprs) checkExpr(e);
		localSafety.scopeClosed();
	}

	function checkArrayDecl(items:Array<TExpr>, arrType:T, p:Position):Void {
		switch (TypeFunctions.followWithAbstracts(arrType)) {
			case TInst(c, [itemType]) if (c.path.pack.length == 0 && c.path.name == "Array"):
				for (e in items) {
					if (!canPassExpr(e, itemType, e.pos))
						error("Cannot use nullable value of " + NullSafety.strType(e.type) + " as an item in Array<" + NullSafety.strType(itemType) + ">", [e.pos, p]);
				}
			case _:
		}
		for (e in items) checkExpr(e);
	}

	function checkEnumIndex(idx:TExpr, p:Position):Void {
		if (isNullableExpr(idx))
			error("Cannot access nullable enum value.", [idx.pos, p]);
		checkExpr(idx);
	}

	function checkTry(tryBlock:TExpr, catches:Array<TCatch>):Void {
		localSafety.processTry(tryBlock, catches, checkExpr);
	}

	function checkWhile(e:TExpr):Void {
		function checkCondition(condition:TExpr):Void {
			if (isNullableExpr(condition))
				error("Cannot use nullable value as a condition in \"while\".", [condition.pos, e.pos]);
			checkExpr(condition);
		}
		localSafety.loopDeclared(e);
		localSafety.processWhile(e, isNullableExpr, checkCondition,
			function(handleConditionEffect, body) checkLoopBody(handleConditionEffect, body));
		localSafety.scopeClosed();
	}

	function checkFor(e:TExpr):Void {
		switch (e.expr) {
			case TFor(v, iterable, body):
				if (isNullableExpr(iterable))
					error("Cannot iterate over nullable value.", [iterable.pos, e.pos]);
				checkExpr(iterable);
				localSafety.declareVar(v);
				localSafety.loopDeclared(e);
				checkLoopBody(null, body);
				localSafety.scopeClosed();
			case _:
		}
	}

	function checkLoopBody(handleConditionEffect:Null<Void->Void>, body:TExpr):Void {
		localSafety.processLoopBody(
			function() {
				isPretending = true;
				checkExpr(body);
			},
			handleConditionEffect,
			function() {
				isPretending = false;
				checkExpr(body);
			}
		);
	}

	function checkThrow(e:TExpr, p:Position):Void {
		if (isNullableExpr(e))
			error("Cannot throw nullable value.", [p, e.pos]);
		checkExpr(e);
	}

	function checkCast(expr:TExpr, toType:T, p:Position):Void {
		checkExpr(expr);
		switch (toType) {
			case TMono(_): // Untyped cast
			case _:
				if (!canPassExpr(expr, toType, p))
					error("Cannot cast nullable value to not nullable type.", [p, expr.pos]);
		}
	}

	public function checkFunction(fn:TFunc, immediateExec:Bool):Void {
		localSafety.functionDeclared(immediateExec, fn);
		returnTypes.unshift(fn.type);
		if (immediateExec || mode == SMLoose) {
			var originalSafeLocals = localSafety.getSafeLocalsCopy();
			// The first pass finds out which vars become unsafe in this closure.
			isPretending = true;
			checkExpr(fn.expr);
			isPretending = false;
			localSafety.filterSafety(originalSafeLocals);
			checkExpr(fn.expr);
		} else {
			checkExpr(fn.expr);
		}
		returnTypes.shift();
		localSafety.scopeClosed();
	}

	function checkReturn(e:TExpr, p:Position):Void {
		checkExpr(e);
		if (returnTypes.length > 0 && !canPassExpr(e, returnTypes[0], p))
			error("Cannot return nullable value of " + NullSafety.strType(e.type) + " as " + NullSafety.strType(returnTypes[0]), [p, e.pos]);
	}

	function checkSwitch(target:TExpr, cases:Array<TSwitchCase>, def:Null<TExpr>, p:Position):Void {
		if (isNullableExpr(target))
			error("Cannot switch on nullable value.", [target.pos, p]);
		checkExpr(target);
		for (c in cases) checkExpr(c.expr);
		if (def != null) checkExpr(def);
	}

	function checkIf(expr:TExpr):Void {
		function checkCondition(e:TExpr):Void {
			if (isNullableExpr(e))
				error("Cannot use nullable value as condition in \"if\".", [e.pos, expr.pos]);
			checkExpr(e);
		}
		localSafety.processIf(expr, isNullableExpr, checkCondition, checkExpr);
	}

	function checkArrayAccess(arr:TExpr, idx:TExpr, p:Position):Void {
		if (isNullableExpr(arr))
			error("Cannot perform array access on nullable value.", [p, arr.pos]);
		if (isNullableExpr(idx))
			error("Cannot use nullable value as an index for array access.", [p, idx.pos]);
		checkExpr(arr);
		checkExpr(idx);
	}

	function checkBinop(op:Binop, leftExpr:TExpr, rightExpr:TExpr, p:Position):Void {
		function checkBoth():Void {
			checkExpr(leftExpr);
			checkExpr(rightExpr);
		}
		switch (op) {
			case OpEq | OpNotEq: checkBoth();
			case OpBoolAnd:
				localSafety.processAnd(leftExpr, rightExpr, isNullableExpr, checkExpr);
			case OpBoolOr:
				localSafety.processOr(leftExpr, rightExpr, isNullableExpr, checkExpr);
			// String concatenation is safe when either operand is safe.
			case OpAdd | OpAssignOp(OpAdd) if (NullSafety.isStringType(leftExpr.type) || NullSafety.isStringType(rightExpr.type)):
				checkBoth();
				if (NullSafety.isNullableType(leftExpr.type) && NullSafety.isNullableType(rightExpr.type))
					error("Cannot concatenate two nullable values.", [p, leftExpr.pos, rightExpr.pos]);
			case OpAssign:
				checkBoth();
				if (!canPassExpr(rightExpr, leftExpr.type, p)) {
					switch (leftExpr.expr) {
						case TLocal(v) if (NullSafety.containsUnsafeMeta(v.meta)):
						case _:
							error("Cannot assign nullable value here.", [p, rightExpr.pos, leftExpr.pos]);
					}
				} else {
					localSafety.handleAssignment(isNullableExpr, leftExpr, rightExpr);
				}
			case _:
				if (isNullableExpr(leftExpr) || isNullableExpr(rightExpr))
					error("Cannot perform binary operation on nullable value.", [p, leftExpr.pos, rightExpr.pos]);
				checkBoth();
		}
	}

	function checkUnop(e:TExpr, p:Position):Void {
		if (isNullableExpr(e))
			error("Cannot perform unary operation on nullable value.", [p, e.pos]);
		checkExpr(e);
	}

	function checkVar(v:TVar, init:Null<TExpr>, p:Position):Void {
		localSafety.declareVar(v);
		if (init == null) return;
		switch (init.expr) {
			// Local named functions generate `var fn = null; fn = function(){}`.
			case TConst(TNull) if (v.kind.match(VUser(TVOLocalFunction)) || v.kind.match(VGenerated)): return;
			case _:
		}
		var local = TypeFunctions.mk(TLocal(v), v.type, v.pos);
		checkBinop(OpAssign, local, init, p);
	}

	function checkField(target:TExpr, access:TFieldAccess, p:Position):Void {
		checkExpr(target);
		if (isNullableExpr(target))
			error("Cannot access \"" + NullSafety.accessedFieldName(access) + "\" of a nullable value.", [p, target.pos]);
	}

	function checkNew(eNew:TExpr):Void {
		switch (eNew.expr) {
			case TNew(cls, params, args):
				var ctor = getConstructor(cls);
				if (ctor == null) {
					for (a in args) checkExpr(a);
				} else {
					var ctorType = TypeFunctions.applyParams(cls.params, params, ctor.type);
					switch (TypeFunctions.follow(ctorType)) {
						case TFun(sig): checkArgs(eNew, args, sig.args);
						case _:
					}
				}
			case _:
		}
	}

	static function getConstructor(cls:TClass):Null<TClassField> {
		var c = cls;
		while (c != null) {
			if (c.constructor != null) return c.constructor;
			c = c.superClass == null ? null : c.superClass.c;
		}
		return null;
	}

	function checkCall(callee:TExpr, args:Array<TExpr>, p:Position):Void {
		if (isNullableExpr(callee))
			error("Cannot call a nullable value.", [callee.pos, p]);
		switch (callee.expr) {
			case TFunction(fn): checkFunction(fn, true);
			case TParenthesis({expr: TFunction(fn)}): checkFunction(fn, true);
			case _: checkExpr(callee);
		}
		switch (TypeFunctions.follow(callee.type)) {
			case TFun(sig):
				if (NullSafety.isTrace(callee)) {
					// Trace's synthesized infos argument carries customParams; check the real args.
					var realArgs = args;
					if (args.length == 2) switch (args[1].expr) {
						case TObjectDecl(fields):
							for (f in fields) if (f.key.name == "customParams") switch (f.expr.expr) {
								case TArrayDecl(restArgs): realArgs = [args[0]].concat(restArgs);
								case _:
							}
						case _:
					}
					for (a in realArgs) checkExpr(a);
				} else {
					checkArgs(callee, args, sig.args);
				}
			case _:
				for (a in args) checkExpr(a);
		}
		localSafety.callMade();
	}

	function checkArgs(callee:TExpr, args:Array<TExpr>, types:Array<TSignatureArg>):Void {
		var meta = NullSafety.getArgumentsMeta(callee, types.length);
		var n = args.length < types.length ? args.length : types.length;
		for (i in 0...n) {
			var arg = args[i];
			var argType = types[i];
			var argMeta = i < meta.length ? meta[i] : ([] : Metadata);
			var unsafeArgument = NullSafety.containsUnsafeMeta(argMeta);
			if (!argType.opt && !unsafeArgument && !canPassExpr(arg, argType.t, arg.pos)) {
				var fnStr = switch (NullSafety.symbolName(callee)) {
					case "": "";
					case name: " of function \"" + name + "\"";
				};
				var argStr = argType.name == "" ? "" : " \"" + argType.name + "\"";
				error("Cannot pass nullable value to not-nullable argument" + argStr + fnStr + ".", [arg.pos, callee.pos]);
			}
			switch (arg.expr) {
				case TFunction(fn):
					checkFunction(fn, immediateExecution.check(callee, i));
				case TCast(e1, null) if (unsafeArgument && hxc.core.TypeUnification.fastEq(arg.type, argType.t)):
					checkExpr(e1);
				case _:
					checkExpr(arg);
			}
		}
	}
}
