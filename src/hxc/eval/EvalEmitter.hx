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

	// Find the frame that declares a variable, walking the lexical chain for captured locals.
	static function findEnv(env:EvalEnv, vid:Int):EvalEnv {
		var e = env;
		while (e != null) {
			if (e.slots.exists(vid)) return e;
			e = e.lexicalParent;
		}
		return env;
	}

	public static function eval(ctx:EvalContext, e:TExpr):EvalValue {
		var env = EvalContext.getEval(ctx).env;
		return switch (e.expr) {
			case TConst(TThis): env.vthis == null ? VNull : env.vthis;
			case TConst(c): evalConst(c);
			case TLocal(v): var fe = findEnv(env, v.id); fe.locals[slot(fe, v.id)];
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
			case TObjectDecl(fields):
				var m = new Map<Int, EvalValue>();
				for (f in fields) m.set(EvalHash.hash(f.key.name), eval(ctx, f.expr));
				VObject(new VObject([], ODictionary(m)));
			case TTry(e1, catches):
				var ev = EvalContext.getEval(ctx);
				var savedEnv = ev.env;
				try {
					eval(ctx, e1);
				} catch (ex:EvalRunTimeException) {
					ev.env = savedEnv;
					if (catches.length == 0) throw ex;
					// First-catch binding; per-catch type filtering is deferred.
					var c = catches[0];
					savedEnv.locals[slot(savedEnv, c.v.id)] = ex.value;
					eval(ctx, c.expr);
				}
			case TArray(e1, e2):
				switch (eval(ctx, e1)) {
					case VArray(va):
						var idx = switch (eval(ctx, e2)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
						(idx >= 0 && idx < va.alength) ? va.avalues[idx] : VNull;
					case v: EvalExceptions.unexpectedValue(ctx, v, "Array");
				}
			case TTypeExpr(mt):
				EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(TypeFunctions.tInfos(mt).path), e.pos).pvalue;
			case TFunction(tf): VFunction(makeClosure(ctx, tf, EvalContext.getEval(ctx).env), false);
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
						var fe = findEnv(EvalContext.getEval(ctx).env, v.id);
						var s = slot(fe, v.id);
						var r = binopValue(ctx, sub, fe.locals[s], eval(ctx, e2), p);
						fe.locals[s] = r;
						r;
					case TField(fe, fa):
						var obj = eval(ctx, fe);
						var name = fieldKey(fa);
						var r = binopValue(ctx, sub, EvalField.field(ctx, obj, name), eval(ctx, e2), p);
						EvalField.setField(ctx, obj, name, r, p);
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
				var fe = findEnv(EvalContext.getEval(ctx).env, v.id);
				fe.locals[slot(fe, v.id)] = value;
			case TField(_, FStatic(c, cf)):
				var proto = EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(c.path), lhs.pos);
				proto.pfields[EvalContext.getProtoFieldIndex(proto, EvalHash.hash(cf.name), lhs.pos)] = value;
			case TField(e1, fa):
				EvalField.setField(ctx, eval(ctx, e1), fieldKey(fa), value, lhs.pos);
			case TArray(e1, e2):
				switch (eval(ctx, e1)) {
					case VArray(va):
						var idx = switch (eval(ctx, e2)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
						while (va.avalues.length <= idx) va.avalues.push(VNull);
						va.avalues[idx] = value;
						if (idx >= va.alength) va.alength = idx + 1;
					case v: EvalExceptions.unexpectedValue(ctx, v, "Array");
				}
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
						var fe = findEnv(EvalContext.getEval(ctx).env, v.id);
						var s = slot(fe, v.id);
						var old = fe.locals[s];
						var delta = op == Increment ? 1 : -1;
						var next = switch (old) {
							case VInt(i): VInt(i + delta);
							case VFloat(f): VFloat(f + delta);
							case _: EvalExceptions.unexpectedValue(ctx, old, "number");
						};
						fe.locals[s] = next;
						flag == Prefix ? next : old;
					case TField(fe, fa):
						var obj = eval(ctx, fe);
						var name = fieldKey(fa);
						var old = EvalField.field(ctx, obj, name);
						var delta = op == Increment ? 1 : -1;
						var next = switch (old) {
							case VInt(i): VInt(i + delta);
							case VFloat(f): VFloat(f + delta);
							case _: EvalExceptions.unexpectedValue(ctx, old, "number");
						};
						EvalField.setField(ctx, obj, name, next, p);
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
		switch (callee.expr) {
			case TConst(TSuper):
				var args = [for (a in argExprs) eval(ctx, a)];
				var vthis = EvalContext.getEval(ctx).env.vthis;
				switch (TypeFunctions.follow(callee.type)) {
					case TInst(c, _):
						var ctor = ctx.constructors.get(EvalHash.pathHash(c.path));
						if (ctor != null) ctor([vthis].concat(args));
					case _:
				}
				return VNull;
			case _:
		}
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

	// A closure captures its defining frame and runs its body in a child frame linked to it.
	static function makeClosure(ctx:EvalContext, tf:TFunc, captured:EvalEnv):VFunc {
		return function(args:Array<EvalValue>):EvalValue {
			var env2 = EvalContext.pushEnvironment(ctx, {isStatic: true, file: 0, kind: EKLocalFunction(0), numLocals: 0, numCaptures: 0});
			env2.lexicalParent = captured;
			env2.vthis = captured == null ? null : captured.vthis;
			for (i in 0...tf.args.length) {
				env2.locals[slot(env2, tf.args[i].v.id)] = i < args.length ? args[i] : VNull;
			}
			var r = try {
				eval(ctx, tf.expr);
				VNull;
			} catch (ret:EvalReturn) {
				ret.value;
			}
			EvalContext.popEnvironment(ctx, env2);
			return r;
		};
	}

	static function evalNew(ctx:EvalContext, c:TClass, args:Array<EvalValue>, p:Position):EvalValue {
		var key = EvalHash.pathHash(c.path);
		var special = ctx.builtins.constructorBuiltins.get(key);
		if (special != null) return special(args);
		return constructClass(ctx, c, key, args, p);
	}

	public static function constructClass(ctx:EvalContext, c:TClass, key:Int, args:Array<EvalValue>, p:Position):EvalValue {
		var proto = EvalContext.getInstancePrototype(ctx, key, p);
		var inst = new VInstance(proto.pinstanceFields.copy(), proto, INormal);
		var instVal = VInstance(inst);
		applyFieldInits(ctx, c, instVal);
		var ctor = ctx.constructors.get(key);
		if (ctor != null) ctor([instVal].concat(args));
		return instVal;
	}

	// Construct an instance of a type known only by its path hash (for stdlib builtins).
	public static function constructPath(ctx:EvalContext, key:Int, args:Array<EvalValue>):EvalValue {
		return switch (ctx.typeCache.get(key)) {
			case TClassDecl(c): constructClass(ctx, c, key, args, Position.nullPos);
			case _: VNull;
		};
	}

	// Instance variable initializers run on the new object before the constructor body.
	static function applyFieldInits(ctx:EvalContext, c:TClass, instVal:EvalValue):Void {
		for (cf in c.orderedFields) {
			switch (cf.kind) {
				case Var(_) if (cf.expr != null):
					var env = EvalContext.pushEnvironment(ctx, {isStatic: false, file: 0, kind: EKEntrypoint, numLocals: 0, numCaptures: 0});
					env.vthis = instVal;
					var v = eval(ctx, cf.expr);
					EvalContext.popEnvironment(ctx, env);
					EvalField.setField(ctx, instVal, EvalHash.hash(cf.name), v, c.pos);
				case _:
			}
		}
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
