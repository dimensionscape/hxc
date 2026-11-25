package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.OverloadResolution;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.ExternMembers;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.TclassToIl.ClassPlan;
import hxc.codegen.dotnet.TclassToIl.MethodPlan;
import hxc.codegen.dotnet.TexprToIl.Place;
import hxc.codegen.dotnet.TexprToIl.Ret;
import hxc.codegen.dotnet.TexprToIl.Slot;
import hxc.codegen.dotnet.TexprToIl.SpillMode;
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.strip;

// The control flow of TexprToIl: if, while, switch, return, throw and try, and the spilling of operands
// that a try would otherwise discard. Shares its state through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprCalls, hxc.codegen.dotnet.TexprDynamic,
	hxc.codegen.dotnet.CsToIl)
class TexprFlow {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	// The type of a value `if` or `switch`: the surrounding one, else its own.
	function valueRet(ret:Ret, e:TExpr):Ret {
		return switch (ret) {
			case RValue(null):
				var t = tl.sig(e.type);
				t.match(LVoid) ? ret : RValue(t);
			case _: ret;
		}
	}

	// A statement's condition and branches have sequence points; a value's belong to the statement it is
	// part of.
	function ifExpr(ret:Ret, e:TExpr, cond:TExpr, eif:TExpr, eelse:Null<TExpr>):Void {
		if (eelse == null && needVal(ret)) throw new Unsupported("Void values", true);
		var r = valueRet(ret, e);
		var statement = !needVal(ret);
		var other = code.newLabel();
		if (statement) tl.conditionPoint(cond);
		tl.ops.jumpIf(cond, other, false);
		if (statement) tl.statementPoint(eif);
		tl.texpr(r, eif);
		if (eelse == null) {
			code.markIfUsed(other);
			return;
		}
		var end = code.newLabel();
		if (code.reachable()) code.branch(IlOps.BR, end);
		code.markIfUsed(other);
		if (statement) tl.statementPoint(eelse);
		tl.texpr(r, eelse);
		code.markIfUsed(end);
	}

	function whileLoop(ret:Ret, cond:TExpr, body:TExpr, flag:WhileFlag):Void {
		// A loop head is a backward branch target, which needs an empty stack.
		if (code.depth != 0) throw new Unsupported("loops inside expressions", true);
		var top = code.newLabel(), cont = code.newLabel(), brk = code.newLabel();
		var isDo = flag.match(DoWhile);
		// As Roslyn, the condition goes after the body, with a jump to it first, so that an iteration takes one branch.
		// A constant one has nothing to test.
		var atBottom = isDo || !TexprToIl.isBoolConst(cond);
		if (atBottom && !isDo) {
			// The jump is no line of the source.
			if (tl.points) code.point(null);
			code.willReach(top);
			code.branch(IlOps.BR, cont);
		}
		code.mark(top);
		tl.loops.push({brk: brk, cont: atBottom ? cont : top, tries: tl.tryDepth});
		try {
			if (atBottom) {
				tl.statementPoint(body);
				tl.texpr(RVoid, body);
				code.markIfUsed(cont);
				tl.conditionPoint(cond);
				tl.ops.jumpIf(cond, top, true);
			} else {
				tl.conditionPoint(cond);
				tl.ops.jumpIf(cond, brk, false);
				tl.statementPoint(body);
				tl.texpr(RVoid, body);
				if (code.reachable()) code.branch(IlOps.BR, top);
			}
		} catch (x:Dynamic) {
			tl.loops.pop();
			throw x;
		}
		tl.loops.pop();
		code.markIfUsed(brk);
		tl.coerce(LVoid, ret);
	}

	// A chain of comparisons in case order, then the default.
	// At the end of a method with a value, a switch without a default covers every value its subject
	// can have, or the typer would want a return after it (the analyzer drops the @:exhaustive of a
	// `return switch` when it moves the return into the cases). A value none of the cases matches
	// reaches the end of gencs's C# method, which returns the default value; here it returns it
	// itself, and the end of the switch is reachable only from the cases. A switch used as a value that
	// has no default (the matcher leaves none when the cases cover the subject, as with a guard on one
	// constructor of an enum) has that default value when nothing matches, as the temporary gencs
	// declares for it does. As for an `if`, a statement's subject and cases have sequence points.
	function switchExpr(ret:Ret, e:TExpr, subject:TExpr, cases:Array<TSwitchCase>, def:Null<TExpr>):Void {
		var r = valueRet(ret, e);
		var valueDefault:Null<IlSigNorm> = def != null ? null : switch (r) {
			case RValue(s): s;
			case _: null;
		}
		var statement = !needVal(ret);
		if (statement) tl.conditionPoint(subject);
		var returnsDefault = def == null && ret.match(RReturn) && !tl.ret.match(LVoid);
		// A switch on enumIndex(x) of a .NET enum is one on x, against the constructors' values.
		var ext = TexprToIl.externEnumIndex(subject);
		if (ext != null) subject = ext.value;
		// A Null<T> subject switches on its value, as HardNullableSynf unwraps it.
		var own = tl.sig(subject.type);
		var st = tl.unNull(own);
		var isString = st.match(LString);
		// A Class or Enum value against types compares as `==` on them does (TexprOps.typeEquality).
		// isTypeCase needs no System.Type operand (equalityTypeOperand): a pattern constant cannot be a System.Type value.
		var isType = ext == null && IlPaths.sigEq(st, TexprCalls.systemType) && Lambda.foreach(cases, c -> Lambda.foreach(c.values, TexprOps.isTypeCase));
		// A Float compares as C#'s == does (gencs's SwitchToIf): NaN matches nothing, -0.0 matches 0.
		// A Dynamic compares with Runtime.eq, as gencs's `if (Runtime.eq(__temp_switch1, "clear"))`.
		var isObject = ext == null && !isType && st.match(LObject);
		if (ext == null && !isString && !isType && !isObject && !st.match(LInt32 | LBool | LFloat64)) throw new Unsupported("switch on this type", false);
		var local:Null<Slot> = null;
		switch (strip(subject).expr) {
			case TLocal(v) if (!tl.isHaxeNull(own)): local = tl.slot(v);
			case _:
		}
		var tmp = -1;
		if (local == null) {
			tl.texpr(RValue(st), subject);
			tmp = code.addLocal(st);
			code.stloc(tmp);
		}
		var bodies = [for (_ in cases) code.newLabel()];
		var eq = isString ? g.mb.memberRef(g.typeTokenOf(LString), "op_Equality", g.sigs.method(false, LBool, [LString, LString], 0)) : 0;
		for (i in 0...cases.length) for (v in cases[i].values) {
			if (local != null) tl.load(local) else code.ldloc(tmp);
			if (ext != null) {
				var i = TexprToIl.constInt(v);
				if (i == null) throw new Unsupported("switch on this type", false);
				tl.calls.externEnumLiteral(ext.en, TexprToIl.enumFieldAt(ext.en, i));
			} else if (!isType) {
				tl.texpr(RValue(st), v);
			}
			if (isType) {
				tl.ops.typeCase(v);
				code.branch(IlOps.BRTRUE, bodies[i]);
			} else if (isString) {
				code.opToken(IlOps.CALL, eq, 2, 1);
				code.branch(IlOps.BRTRUE, bodies[i]);
			} else if (isObject) {
				tl.dyn.runtimeCall("eq");
				code.branch(IlOps.BRTRUE, bodies[i]);
			} else {
				code.branch(IlOps.BEQ, bodies[i]);
			}
		}
		var end = code.newLabel();
		var defLabel = def == null && !returnsDefault && valueDefault == null ? end : code.newLabel();
		code.branch(IlOps.BR, defLabel);
		for (i in 0...cases.length) {
			code.markIfUsed(bodies[i]);
			if (statement) tl.statementPoint(cases[i].expr);
			tl.texpr(r, cases[i].expr);
			if (code.reachable()) code.branch(IlOps.BR, end);
		}
		if (def != null) {
			code.mark(defLabel);
			if (statement) tl.statementPoint(def);
			tl.texpr(r, def);
		} else if (valueDefault != null) {
			code.mark(defLabel);
			tl.pushDefault(valueDefault);
		} else if (returnsDefault) {
			code.markIfUsed(defLabel);
			if (code.reachable()) {
				tl.pushDefault(tl.ret);
				exitMethod(true);
			}
		}
		code.markIfUsed(end);
	}

	// `return`: a `ret`, or inside a try a store to the return local and a `leave` to the label after
	// the outermost try, which returns it.
	function exitMethod(withValue:Bool):Void {
		if (tl.tryDepth == 0) {
			code.op(IlOps.RET, withValue ? 1 : 0, 0);
			return;
		}
		if (withValue) {
			if (tl.retLocal < 0) tl.retLocal = code.addLocal(tl.ret);
			code.stloc(tl.retLocal);
		}
		if (tl.retLabel < 0) tl.retLabel = code.newLabel();
		code.branch(IlOps.LEAVE, tl.retLabel);
	}

	static final systemException:IlSigNorm = LClass({ns: ["System"], nested: [], name: "Exception"}, []);

	// IL `rethrow`, which throws the exception of the catch it is in again, keeping its stack trace. It is
	// valid in a catch body, and in a try block inside one, but not in a finally handler or a local
	// function (C# error CS0156).
	function rethrow(pos:Position):Void {
		if (tl.handlers.length == 0 || !tl.handlers[tl.handlers.length - 1].isCatch) {
			var u = Unsupported.error("a rethrow (a bare `throw`, cs.Lib.rethrow) must be directly inside a catch (C# error CS0156)");
			u.pos = pos;
			throw u;
		}
		code.op(IlOps.RETHROW, 0, 0);
	}

	// Whether `v` is the variable of the innermost enclosing catch, and that catch's body never assigns it,
	// so `throw v` throws what `rethrow` does.
	function isRethrowable(v:TVar):Bool {
		if (tl.handlers.length == 0) return false;
		var frame = tl.handlers[tl.handlers.length - 1];
		return frame.isCatch && frame.v.id == v.id && !assigns(v, frame.body);
	}

	// Whether `e` assigns `v`: `=`, a compound assignment, `++` or `--`.
	static function assigns(v:TVar, e:TExpr):Bool {
		function isV(x:TExpr) return switch (strip(x).expr) {
			case TLocal(v2): v2.id == v.id;
			case _: false;
		}
		return switch (e.expr) {
			case TBinop(OpAssign | OpAssignOp(_), lhs, _) if (isV(lhs)): true;
			case TUnop(Increment | Decrement, _, e1) if (isV(e1)): true;
			case _: TexprTools.checkExpr(x -> assigns(v, x), e);
		}
	}

	// The exceptions filter has already wrapped values that are not .NET exceptions. A rethrow is `throw`
	// of the filter's own catch variable (when no catch matched; it is never assigned), `cs.Lib.rethrow`
	// (`throw untyped __rethrow__`) and `throw e` of the catch's own, unchanged variable. gencs writes the
	// first two as `throw;` and the third as `throw e;`, which resets the stack trace.
	function throwExpr(e1:TExpr, pos:Position):Void {
		switch (strip(e1).expr) {
			case TIdent("__rethrow__"):
				rethrow(pos);
				return;
			case TLocal(v) if (isRethrowable(v)):
				rethrow(pos);
				return;
			case _:
		}
		var s = tl.sig(e1.type);
		if (!s.match(LObject | LClass(_, _))) throw new Unsupported("throw of " + hxc.core.TPrinting.sTypeStr(e1.type), false);
		tl.texpr(RValue(s), e1);
		if (!code.reachable()) return;
		// Dynamic, such as haxe.Exception.thrown's result, is cast as C# casts a thrown value.
		if (s.match(LObject)) tl.castTo(systemException);
		code.op(IlOps.THROW, 1, 0);
	}

	// The type a catch clause catches: a class, as the exceptions filter leaves only native types here.
	function catchClass(v:TVar):IlSigNorm {
		var s = tl.sig(v.type);
		if (!s.match(LClass(_, _))) throw new Unsupported("catch of " + hxc.core.TPrinting.sTypeStr(v.type), false);
		return s;
	}

	// A protected region with a typed clause per catch, in order. Each part leaves to the end with its
	// value, if the try has one, in a temporary.
	function tryExpr(ret:Ret, e:TExpr, body:TExpr, catches:Array<TCatch>):Void {
		// Operands before a try are spilled (spillForTry); this is a position that does not spill.
		if (code.depth != 0) throw new Unsupported("`try` inside this expression", false);
		var r = valueRet(ret, e);
		var t = switch (r) {
			case RValue(s): s;
			case _: null;
		}
		// At the end of the method (RReturn), so are the ends of the body and the catches.
		var inner = t == null && !r.match(RReturn) ? RVoid : r;
		var classes = [for (c in catches) catchClass(c.v)];
		var result = t == null ? -1 : code.addLocal(t);
		var end = code.newLabel();
		function leave() {
			if (!code.reachable()) return;
			if (result >= 0) code.stloc(result);
			code.branch(IlOps.LEAVE, end);
		}
		var outermost = tl.tryDepth == 0;
		var open = code.openTries;
		var frames = tl.handlers.length;
		// A value try's catches have points of their own, inside the statement around the try.
		var outer = tl.statementPos, mark = needVal(ret) ? tl.pointMark() : -1;
		tl.tryDepth++;
		try {
			code.beginTry();
			tl.texpr(inner, body);
			leave();
			for (i in 0...catches.length) {
				// The handler starts with the exception on the stack; it is its variable's scope.
				code.beginCatch(g.typeTokenOf(classes[i]));
				code.openScope();
				tl.catchPoint(catches[i].v);
				var local = {arg: false, index: code.addLocal(classes[i]), sig: classes[i]};
				tl.store(local);
				tl.slots.set(catches[i].v.id, local);
				tl.nameLocal(catches[i].v, local.index);
				tl.handlers.push({isCatch: true, v: catches[i].v, body: catches[i].expr});
				tl.texpr(inner, catches[i].expr);
				tl.handlers.pop();
				leave();
				code.closeScope();
			}
			code.endTry();
		} catch (x:Dynamic) {
			tl.handlers.resize(frames);
			tl.tryDepth--;
			code.abandonTries(open);
			if (outermost) tl.retLabel = -1;
			throw x;
		}
		tl.tryDepth--;
		if (outermost) returnAfterTry();
		code.markIfUsed(end);
		tl.resumePoint(mark, outer);
		if (t == null) tl.coerce(LVoid, ret) else if (code.reachable()) {
			code.ldloc(result);
			tl.coerce(t, ret);
		}
	}

	// After the outermost try: the label a `return` inside it leaves to, which returns the value it
	// stored.
	function returnAfterTry():Void {
		if (tl.retLabel < 0) return;
		code.markIfUsed(tl.retLabel);
		if (code.reachable()) {
			// No Haxe line wrote it.
			if (tl.points) code.point(null);
			if (tl.ret.match(LVoid)) {
				code.op(IlOps.RET, 0, 0);
			} else {
				code.ldloc(tl.retLocal);
				code.op(IlOps.RET, 1, 0);
			}
		}
		tl.retLabel = -1;
	}

	// A protected region with a finally handler, in statement position: `body` lowers the block, which
	// leaves to the end, and `fin` the handler, which ends with endfinally. A jump out of the block is a
	// `leave`, which runs the handler.
	function tryFinally(body:() -> Void, fin:() -> Void):Void {
		if (code.depth != 0) throw "internal error: a try/finally entered with a non-empty stack";
		var end = code.newLabel();
		var outermost = tl.tryDepth == 0;
		var open = code.openTries;
		var frames = tl.handlers.length;
		tl.tryDepth++;
		try {
			code.beginTry();
			body();
			if (code.reachable()) code.branch(IlOps.LEAVE, end);
			code.beginFinally();
			tl.handlers.push({isCatch: false, v: null, body: null});
			fin();
			tl.handlers.pop();
			code.op(IlOps.ENDFINALLY, 0, 0);
			code.endTry();
		} catch (x:Dynamic) {
			tl.handlers.resize(frames);
			tl.tryDepth--;
			code.abandonTries(open);
			if (outermost) tl.retLabel = -1;
			throw x;
		}
		tl.tryDepth--;
		if (outermost) returnAfterTry();
		code.markIfUsed(end);
	}

	static function holdsTry(e:TExpr):Bool {
		return switch (e.expr) {
			case TTry(_, _): true;
			case TFunction(_): false;
			case _: TexprTools.checkExpr(holdsTry, e);
		}
	}

	// A try block and a loop both start on an empty stack (a loop's head is the target of a backward branch).
	static function containsTry(e:TExpr):Bool {
		return switch (e.expr) {
			case TTry(_, _) | TWhile(_, _, _) | TFor(_, _, _): true;
			case TFunction(_): false;
			case _: TexprTools.checkExpr(containsTry, e);
		}
	}

	// A try block starts on an empty stack, and so does a loop. When one is in an operand pushed after
	// another value, that operand and the ones before it are evaluated into temporaries first, left to
	// right, and the expression is lowered over reads of them. Null when nothing needs that.
	function spillForTry(e:TExpr):Null<TExpr> {
		function with(x:TExprExpr):TExpr return new TExpr(x, e.type, e.pos);
		switch (e.expr) {
			case TBinop(OpAssign, lhs, rhs):
				var parts = placeParts(lhs);
				if (parts == null) return null;
				var ops = spillOperands(parts.ops.concat([rhs]), parts.modes.concat([Spill]), false);
				if (ops == null) return null;
				return with(TBinop(OpAssign, parts.rebuild(ops), ops[ops.length - 1]));
			case TBinop(OpAssignOp(op), lhs, rhs) if (containsTry(rhs)):
				// The place's parts, then its value combined with the right side, then the store.
				var parts = placeParts(lhs);
				var target = lhs;
				if (parts != null) {
					var ops = spillOperands(parts.ops, parts.modes, true);
					if (ops != null) target = parts.rebuild(ops);
				}
				var value = spill(new TExpr(TBinop(op, target, rhs), lhs.type, e.pos));
				return with(TBinop(OpAssign, target, value));
			case TBinop(OpBoolAnd | OpBoolOr | OpAssignOp(_), _, _):
				// The right side of && and || is reached by a branch, with nothing on the stack.
				return null;
			case TBinop(op, e1, e2):
				var ops = spillOperands([e1, e2], [Spill, Spill], false);
				return ops == null ? null : with(TBinop(op, ops[0], ops[1]));
			case TArray(e1, e2):
				var ops = spillOperands([e1, e2], [Spill, Spill], false);
				return ops == null ? null : with(TArray(ops[0], ops[1]));
			case TArrayDecl(el):
				// The new array, a copy and an index are under each element.
				var ops = spillOperands(el, [for (_ in el) Spill], true);
				return ops == null ? null : with(TArrayDecl(ops));
			case TNew(c, params, args):
				if (!Lambda.exists(args, containsTry)) return null;
				var ctorType = c.constructor == null ? null : c.constructor.type;
				var ops = spillOperands(args, argModes(ctorType, args), false);
				return ops == null ? null : with(TNew(c, params, ops));
			case TCall(callee, args):
				// A try in the receiver alone is evaluated first.
				if (!Lambda.exists(args, containsTry)) return null;
				var modes = argModes(callee.type, args);
				switch (callee.expr) {
					case TConst(TSuper):
						// `this` is under the arguments.
						var ops = spillOperands(args, modes, true);
						return ops == null ? null : with(TCall(callee, ops));
					case TField(obj, fa = FInstance(_, _, _)):
						if (strip(obj).expr.match(TConst(TSuper))) {
							var ops = spillOperands(args, modes, true);
							return ops == null ? null : with(TCall(callee, ops));
						}
						var ops = spillOperands([obj].concat(args), [receiverMode(obj)].concat(modes), false);
						if (ops == null) return null;
						return with(TCall(new TExpr(TField(ops[0], fa), callee.type, callee.pos), ops.slice(1)));
					case _:
						var ops = spillOperands(args, modes, false);
						return ops == null ? null : with(TCall(callee, ops));
				}
			case _:
				return null;
		}
	}

	// The operands an assignment's target pushes before the value, and the target over new ones; null
	// for a target that pushes nothing.
	function placeParts(lhs:TExpr):Null<{ops:Array<TExpr>, modes:Array<SpillMode>, rebuild:Array<TExpr>->TExpr}> {
		var e = strip(lhs);
		return switch (e.expr) {
			case TArray(e1, e2):
				{ops: [e1, e2], modes: [Spill, Spill], rebuild: ops -> new TExpr(TArray(ops[0], ops[1]), e.type, e.pos)};
			case TField(obj, fa = FInstance(_, _, _)):
				{ops: [obj], modes: [receiverMode(obj)], rebuild: ops -> new TExpr(TField(ops[0], fa), e.type, e.pos)};
			case _:
				null;
		}
	}

	// A struct receiver is used through its address, which is not kept in a temporary: a local's, or a
	// field's of a struct local, stays where it is, as the operands cannot change it; one reached
	// through an object is refused; a value with no home is copied, as it would be anyway.
	function receiverMode(obj:TExpr):SpillMode {
		if (!isStruct(obj)) return Spill;
		if (fixedAddress(obj)) return Keep;
		return strip(obj).expr.match(TField(_, _)) ? Refuse : Spill;
	}

	function isStruct(e:TExpr):Bool {
		var s = try tl.sig(e.type) catch (_:Unsupported) null;
		return s != null && DotnetTypes.isValueType(s);
	}

	function fixedAddress(e:TExpr):Bool {
		return switch (strip(e).expr) {
			case TLocal(_) | TConst(_): true;
			case TField(obj, FInstance(_, _, _)) if (isStruct(obj)): fixedAddress(obj);
			case _: false;
		}
	}

	// A cs.Ref or cs.Out argument is a variable's address, which stays where it is.
	static function argModes(fnType:Null<T>, args:Array<TExpr>):Array<SpillMode> {
		var fargs = fnType == null ? [] : switch (TypeFunctions.follow(fnType)) {
			case TFun(fsig): fsig.args;
			case _: [];
		}
		return [
			for (i in 0...args.length) {
				var byRef = i < fargs.length && switch (fargs[i].t) {
					case TType(d, _): d.path.pack.length == 1 && d.path.pack[0] == "cs" && (d.path.name == "Ref" || d.path.name == "Out");
					case _: false;
				}
				byRef ? Keep : Spill;
			}
		];
	}

	// A Void operand, such as the block that is the body of cs.Lib.lock, is no value on the stack.
	function isVoid(e:TExpr):Bool {
		var s = try tl.sig(e.type) catch (_:Unsupported) null;
		return s != null && s.match(LVoid);
	}

	// The operands up to the last one with a try or a loop, spilled; null when that is the first value pushed.
	function spillOperands(ops:Array<TExpr>, modes:Array<SpillMode>, pushedBefore:Bool):Null<Array<TExpr>> {
		// From the end, so the first operand of an expression that pushes nothing before it is not
		// searched: a chain of binary operators is searched once.
		var last = ops.length - 1;
		var first = pushedBefore ? 0 : 1;
		while (last >= first && !(containsTry(ops[last]) && !isVoid(ops[last]))) last--;
		if (last < first) return null;
		for (i in 0...last + 1) if (modes[i] == Refuse)
			throw new Unsupported((holdsTry(ops[last]) ? "`try`" : "a loop") + " in an operand after a member of a struct field", false);
		return [for (i in 0...ops.length) i <= last && modes[i] == Spill ? spill(ops[i]) : ops[i]];
	}

	// Evaluates `e` into a new temporary and returns a read of it. Constants and temporaries stay.
	function spill(e:TExpr):TExpr {
		switch (strip(e).expr) {
			case TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_) | TNull | TSuper):
				return e;
			case TConst(TThis) if (tl.thisSig != null && !DotnetTypes.isValueType(tl.thisSig)):
				return e;
			case TLocal(v) if (tl.temps.exists(v.id)):
				return e;
			case _:
		}
		var s = tl.sig(e.type);
		tl.texpr(RValue(s), e);
		var v = TypeFunctions.allocVar(VGenerated, "tmp", e.type, e.pos);
		var local = {arg: false, index: code.addLocal(s), sig: s};
		if (code.reachable()) tl.store(local);
		tl.slots.set(v.id, local);
		tl.temps.set(v.id, true);
		return new TExpr(TLocal(v), e.type, e.pos);
	}
}
