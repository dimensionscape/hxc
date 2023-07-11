package hxc.eval;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.eval.EvalValue;
import hxc.eval.EvalValue.EvalValueTools;
import hxc.eval.EvalContext;
import hxc.eval.EvalField;
import hxc.eval.EvalHash;
import hxc.eval.EvalExceptions;

// Direct tree-walk over typed expressions. Locals live in the current frame's slot array,
// addressed through a variable-id to slot map filled on first use. The reference precompiles
// each expression to a closure; that and the bytecode tier are a performance concern left for
// later.
class EvalEmitter {
	static function slot(env:EvalEnv, vid:Int):Int {
		var s = env.slots.get(vid);
		if (s != null) return s;
		s = env.locals.length;
		env.slots.set(vid, s);
		env.locals.push(VNull);
		return s;
	}

	public static function eval(ctx:EvalContext, e:TExpr):EvalValue {
		var env = EvalContext.getEval(ctx).env;
		return switch (e.expr) {
			case TConst(TThis): env.vthis == null ? VNull : env.vthis;
			case TConst(c): evalConst(c);
			case TLocal(v): env.locals[slot(env, v.id)];
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, _): eval(ctx, e1);
			case TBlock(el):
				var r:EvalValue = VNull;
				for (x in el) r = eval(ctx, x);
				r;
			case TVarExpr(v, eo):
				env.locals[slot(env, v.id)] = eo == null ? VNull : eval(ctx, eo);
				VNull;
			case TBinop(op, e1, e2): evalBinop(ctx, op, e1, e2, e.pos);
			case TUnop(op, flag, e1): evalUnop(ctx, op, flag, e1, e.pos);
			case TIf(econd, eif, eelse):
				if (EvalMisc.isTrue(eval(ctx, econd))) eval(ctx, eif);
				else if (eelse != null) eval(ctx, eelse);
				else VNull;
			case TWhile(econd, body, flag): evalWhile(ctx, econd, body, flag);
			case TReturn(eo): throw new EvalReturn(eo == null ? VNull : eval(ctx, eo));
			case TBreak: throw new EvalBreak();
			case TContinue: throw new EvalContinue();
			case TThrow(e1): EvalExceptions.throwValue(ctx, eval(ctx, e1), e.pos);
			case TArrayDecl(el): VArray(new VArray([for (x in el) eval(ctx, x)], el.length));
			case TTypeExpr(mt):
				EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(TypeFunctions.tInfos(mt).path), e.pos).pvalue;
			case TField(e1, fa): evalField(ctx, e1, fa, e.pos);
			case TCall(callee, callArgs): evalCall(ctx, callee, callArgs, e.pos);
			case TNew(c, _, newArgs): evalNew(ctx, c, [for (a in newArgs) eval(ctx, a)], e.pos);
			case TSwitch(subject, cases, edef): evalSwitch(ctx, subject, cases, edef);
			case TEnumParameter(e1, _, index):
				switch (eval(ctx, e1)) {
					case VEnumValue(ev): ev.eargs[index];
					case v: EvalExceptions.unexpectedValue(ctx, v, "enum value");
				}
			case TEnumIndex(e1):
				switch (eval(ctx, e1)) {
					case VEnumValue(ev): VInt(ev.eindex);
					case v: EvalExceptions.unexpectedValue(ctx, v, "enum value");
				}
			case _: EvalExceptions.excString(ctx, "Unsupported expression in eval: " + Std.string(e.expr).split("(")[0]);
		};
	}

	static function evalConst(c:TConstant):EvalValue {
		return switch (c) {
			case TInt(i): VInt(i);
			case TFloat(s): VFloat(Std.parseFloat(s));
			case TString(s): VString(new VString(s, s.length));
			case TBool(b): b ? VTrue : VFalse;
			case TNull: VNull;
			case TThis: VNull;
			case TSuper: VNull;
		};
	}

	static function binopValue(ctx:EvalContext, op:Binop, a:EvalValue, b:EvalValue, p:Position):EvalValue {
		return switch (op) {
			case OpAdd: EvalMisc.opAdd(ctx, p, a, b);
			case OpSub: EvalMisc.opSub(ctx, p, a, b);
			case OpMult: EvalMisc.opMult(ctx, p, a, b);
			case OpDiv: EvalMisc.opDiv(ctx, p, a, b);
			case OpMod: EvalMisc.opMod(ctx, p, a, b);
			case OpEq: EvalMisc.opEq(a, b);
			case OpNotEq: EvalMisc.opNotEq(a, b);
			case OpGt: EvalMisc.opGt(a, b);
			case OpGte: EvalMisc.opGte(a, b);
			case OpLt: EvalMisc.opLt(a, b);
			case OpLte: EvalMisc.opLte(a, b);
			case OpAnd: EvalMisc.opAnd(ctx, p, a, b);
			case OpOr: EvalMisc.opOr(ctx, p, a, b);
			case OpXor: EvalMisc.opXor(ctx, p, a, b);
			case OpShl: EvalMisc.opShl(ctx, p, a, b);
			case OpShr: EvalMisc.opShr(ctx, p, a, b);
			case OpUShr: EvalMisc.opUShr(ctx, p, a, b);
			case _: EvalExceptions.excString(ctx, "Unsupported binop");
		};
	}

	static function evalBinop(ctx:EvalContext, op:Binop, e1:TExpr, e2:TExpr, p:Position):EvalValue {
		return switch (op) {
			case OpBoolAnd: EvalMisc.isTrue(eval(ctx, e1)) ? eval(ctx, e2) : VFalse;
			case OpBoolOr: EvalMisc.isTrue(eval(ctx, e1)) ? VTrue : eval(ctx, e2);
			case OpAssign: assign(ctx, e1, eval(ctx, e2));
			case OpAssignOp(sub):
				switch (e1.expr) {
					case TLocal(v):
						var env = EvalContext.getEval(ctx).env;
						var s = slot(env, v.id);
						var r = binopValue(ctx, sub, env.locals[s], eval(ctx, e2), p);
						env.locals[s] = r;
						r;
					case _: EvalExceptions.excString(ctx, "Unsupported compound assignment target");
				}
			case _: binopValue(ctx, op, eval(ctx, e1), eval(ctx, e2), p);
		};
	}

	static function fieldKey(fa:TFieldAccess):Int {
		return switch (fa) {
			case FStatic(_, cf) | FInstance(_, _, cf) | FAnon(cf) | FClosure(_, cf): EvalHash.hash(cf.name);
			case FEnum(_, ef): EvalHash.hash(ef.name);
			case FDynamic(s): EvalHash.hash(s);
		};
	}

	static function assign(ctx:EvalContext, lhs:TExpr, value:EvalValue):EvalValue {
		switch (lhs.expr) {
			case TLocal(v):
				var env = EvalContext.getEval(ctx).env;
				env.locals[slot(env, v.id)] = value;
			case TField(_, FStatic(c, cf)):
				var proto = EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(c.path), lhs.pos);
				proto.pfields[EvalContext.getProtoFieldIndex(proto, EvalHash.hash(cf.name), lhs.pos)] = value;
			case TField(e1, fa):
				EvalField.setField(ctx, eval(ctx, e1), fieldKey(fa), value, lhs.pos);
			case _:
				EvalExceptions.excString(ctx, "Unsupported assignment target");
		}
		return value;
	}

	static function evalUnop(ctx:EvalContext, op:Unop, flag:UnopFlag, e1:TExpr, p:Position):EvalValue {
		return switch (op) {
			case Not: switch (eval(ctx, e1)) { case VNull | VFalse: VTrue; case _: VFalse; };
			case Neg:
				switch (eval(ctx, e1)) {
					case VInt(i): VInt(-i);
					case VFloat(f): VFloat(-f);
					case v: EvalExceptions.unexpectedValue(ctx, v, "number");
				}
			case NegBits:
				switch (eval(ctx, e1)) {
					case VInt(i): VInt(~i);
					case v: EvalExceptions.unexpectedValue(ctx, v, "Int");
				}
			case Increment | Decrement:
				switch (e1.expr) {
					case TLocal(v):
						var env = EvalContext.getEval(ctx).env;
						var s = slot(env, v.id);
						var old = env.locals[s];
						var delta = op == Increment ? 1 : -1;
						var next = switch (old) {
							case VInt(i): VInt(i + delta);
							case VFloat(f): VFloat(f + delta);
							case _: EvalExceptions.unexpectedValue(ctx, old, "number");
						};
						env.locals[s] = next;
						flag == Prefix ? next : old;
					case _: EvalExceptions.excString(ctx, "Unsupported increment target");
				}
			case _: EvalExceptions.excString(ctx, "Unsupported unop");
		};
	}

	static function evalWhile(ctx:EvalContext, econd:TExpr, body:TExpr, flag:WhileFlag):EvalValue {
		switch (flag) {
			case NormalWhile:
				while (EvalMisc.isTrue(eval(ctx, econd))) {
					try eval(ctx, body) catch (_:EvalBreak) break catch (_:EvalContinue) {}
				}
			case DoWhile:
				var go = true;
				while (go) {
					try eval(ctx, body) catch (_:EvalBreak) break catch (_:EvalContinue) {}
					go = EvalMisc.isTrue(eval(ctx, econd));
				}
		}
		return VNull;
	}

	static function evalField(ctx:EvalContext, e1:TExpr, fa:TFieldAccess, p:Position):EvalValue {
		return switch (fa) {
			case FStatic(c, cf):
				EvalField.protoFieldRaise(EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(c.path), p), EvalHash.hash(cf.name));
			case FEnum(en, ef):
				EvalField.protoFieldRaise(EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(en.path), p), EvalHash.hash(ef.name));
			case FInstance(_, _, cf) | FClosure(_, cf):
				EvalField.dynamicField(ctx, eval(ctx, e1), EvalHash.hash(cf.name));
			case FAnon(cf):
				EvalField.field(ctx, eval(ctx, e1), EvalHash.hash(cf.name));
			case FDynamic(s):
				EvalField.dynamicField(ctx, eval(ctx, e1), EvalHash.hash(s));
		};
	}

	static function evalCall(ctx:EvalContext, callee:TExpr, argExprs:Array<TExpr>, p:Position):EvalValue {
		var fn = EvalValueTools.vresolve(eval(ctx, callee));
		var args = [for (a in argExprs) eval(ctx, a)];
		return switch (fn) {
			case VFunction(f, _): f(args);
			case VFieldClosure(recv, f): f([recv].concat(args));
			case v: EvalExceptions.unexpectedValue(ctx, v, "function");
		};
	}

	static function evalSwitch(ctx:EvalContext, subject:TExpr, cases:Array<TSwitchCase>, edef:Null<TExpr>):EvalValue {
		var v = eval(ctx, subject);
		for (c in cases) {
			for (cv in c.values) {
				if (EvalValueTools.equals(v, eval(ctx, cv))) return eval(ctx, c.expr);
			}
		}
		return edef != null ? eval(ctx, edef) : VNull;
	}

	static function evalNew(ctx:EvalContext, c:TClass, args:Array<EvalValue>, p:Position):EvalValue {
		var proto = EvalContext.getInstancePrototype(ctx, EvalHash.pathHash(c.path), p);
		var inst = new VInstance(proto.pinstanceFields.copy(), proto, INormal);
		var ctor = ctx.constructors.get(EvalHash.pathHash(c.path));
		if (ctor != null) ctor([VInstance(inst)].concat(args));
		return VInstance(inst);
	}

	// Run a function body in a fresh frame with the given arguments bound, returning the value
	// produced by a return statement (or null).
	public static function runBody(ctx:EvalContext, args:Array<{vid:Int, value:EvalValue}>, body:TExpr, ?vthis:EvalValue):EvalValue {
		var info:EvalEnvInfo = {isStatic: vthis == null, file: 0, kind: EKEntrypoint, numLocals: 0, numCaptures: 0};
		var env = EvalContext.pushEnvironment(ctx, info);
		env.vthis = vthis;
		for (a in args) env.locals[slot(env, a.vid)] = a.value;
		var ret = try {
			eval(ctx, body);
			VNull;
		} catch (r:EvalReturn) {
			r.value;
		}
		EvalContext.popEnvironment(ctx, env);
		return ret;
	}
}
