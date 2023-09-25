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
			case TThrow(e1): EvalExceptions.throwValue(ctx, unwrapThrown(ctx, eval(ctx, e1)), e.pos);
			case TArrayDecl(el): VArray(new VArray([for (x in el) eval(ctx, x)], el.length));
			case TObjectDecl(fields):
				var m = new Map<Int, EvalValue>();
				for (f in fields) m.set(EvalHash.hash(f.key.name), eval(ctx, f.expr));
				VObject(new VObject([], ODictionary(m)));
			case TTry(e1, catches):
				var ev = EvalContext.getEval(ctx);
				var savedEnv = ev.env;
				var result:EvalValue = VNull;
				try {
					result = eval(ctx, e1);
				} catch (ex:EvalRunTimeException) {
					ev.env = savedEnv;
					result = runCatch(ctx, ex.value, catches, savedEnv, function() { throw ex; });
				} catch (ex:Dynamic) {
					// Control-flow signals must reach their own handlers, never a program try/catch.
					if (Std.isOfType(ex, EvalBreak) || Std.isOfType(ex, EvalContinue) || Std.isOfType(ex, EvalReturn) || Std.isOfType(ex, EvalSysExit)) throw ex;
					// Any other host exception is an hxc-internal failure escaping the interpreter (a dropped
					// field, a native builtin error). Present it to the running program as a normal thrown
					// value so its own try/catch (e.g. the utest runner) records an error and continues,
					// instead of aborting the whole run. The value is re-raised if no local catch matches.
					ev.env = savedEnv;
					var s = Std.string(ex);
					var v = VString(new VString(s, s.length));
					result = runCatch(ctx, v, catches, savedEnv, function() return EvalExceptions.throwValue(ctx, v, e.pos));
				}
				result;
			case TArray(e1, e2):
				switch (eval(ctx, e1)) {
					case VArray(va):
						var idx = switch (eval(ctx, e2)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
						(idx >= 0 && idx < va.alength) ? va.avalues[idx] : VNull;
					case VVector(vv):
						var idx = switch (eval(ctx, e2)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
						vecElemGet(vv, idx);
					case v: EvalExceptions.unexpectedValue(ctx, v, "Array");
				}
			case TTypeExpr(mt):
				// A type without an eval prototype (e.g. the core-type abstracts Int/Float/Bool) still
				// needs a value marker carrying its path, for Std.isOfType and reflection.
				var tpath = EvalHash.pathHash(TypeFunctions.tInfos(mt).path);
				var tproto = ctx.staticPrototypes.get(tpath);
				if (tproto == null) {
					tproto = new VPrototype(tpath, [], new Map(), [], new Map(), null, PClass([]), VNull);
					tproto.pvalue = VPrototype(tproto);
					ctx.staticPrototypes.set(tpath, tproto);
				}
				tproto.pvalue;
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

	static function catchMatches(ctx:EvalContext, v:EvalValue, t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TDynamic(_): true;
			case TInst(c, _):
				var path = EvalHash.pathHash(c.path);
				// A non-haxe.Exception value thrown and caught as haxe.Exception (the wildcard type) or
				// haxe.ValueException is wrapped in a haxe.ValueException by the reference before the catch
				// runs (see /caught). The eval binds the raw value, so a plain value like an Int never
				// satisfies isOfTypePath against those types; treat such a catch as a match here and let
				// runCatch build the wrapper. Values already extending haxe.Exception pass through.
				if ((path == EvalHash.key_haxe_Exception || path == EvalHash.key_haxe_ValueException)
					&& !EvalStdLib.isOfTypePath(ctx, v, EvalHash.key_haxe_Exception)) true
				else EvalStdLib.isOfTypePath(ctx, v, path);
			case TEnum(en, _): EvalStdLib.isOfTypePath(ctx, v, EvalHash.pathHash(en.path));
			case TAbstract(a, _):
				// A non-core-type abstract has no runtime identity, so a value is caught by it when the
				// value matches the abstract's underlying representation (e.g. AbstrString from String
				// catches a String). Core-type abstracts (Int/Float/Bool) keep their own path match.
				var ut = TypeFunctions.followWithAbstracts(t);
				if (EvalStdLib.isOfTypePath(ctx, v, EvalHash.pathHash(a.path))) true
				else switch (ut) { case TAbstract(a2, _) if (a2.path == a.path): false; case _: catchMatches(ctx, v, ut); };
			case TType(td, _): EvalStdLib.isOfTypePath(ctx, v, EvalHash.pathHash(td.path));
			case _: false;
		};
	}

	// Throwing a haxe.ValueException throws its wrapped value instead (haxe.Exception.thrown/unwrap):
	// a value caught by a wildcard `catch(e:Exception)` is bound as a ValueException wrapper, and
	// rethrowing it must surface the original value again so an outer catch of its native type matches.
	static function unwrapThrown(ctx:EvalContext, v:EvalValue):EvalValue {
		return switch (v) {
			case VInstance(vi) if (vi.iproto.ppath == EvalHash.key_haxe_ValueException):
				EvalField.field(ctx, v, EvalHash.hash("value"));
			case _: v;
		};
	}

	// A value caught by a haxe.Exception or haxe.ValueException clause that is not already a
	// haxe.Exception instance is wrapped in a freshly built haxe.ValueException, exposing .value
	// (the original) and .message (Std.string(value)); see haxe/ValueException.hx. If the wrapper type
	// is not loaded the raw value is returned unchanged.
	static function wrapCaught(ctx:EvalContext, v:EvalValue, t:T):EvalValue {
		switch (TypeFunctions.follow(t)) {
			case TInst(c, _):
				var path = EvalHash.pathHash(c.path);
				if ((path == EvalHash.key_haxe_Exception || path == EvalHash.key_haxe_ValueException)
					&& !EvalStdLib.isOfTypePath(ctx, v, EvalHash.key_haxe_Exception)) {
					var wrapped = constructPath(ctx, EvalHash.key_haxe_ValueException, [v]);
					return wrapped == VNull ? v : wrapped;
				}
			case _:
		}
		return v;
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
			case OpAssign: assign(ctx, e1, e2);
			case OpAssignOp(sub):
				switch (e1.expr) {
					case TLocal(v):
						var fe = findEnv(EvalContext.getEval(ctx).env, v.id);
						var s = slot(fe, v.id);
						var r = binopValue(ctx, sub, fe.locals[s], eval(ctx, e2), p);
						fe.locals[s] = r;
						r;
					case TField(_, FStatic(c, cf)):
						var proto = EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(c.path), p);
						var idx = EvalContext.getProtoFieldIndex(proto, EvalHash.hash(cf.name), p);
						var r = binopValue(ctx, sub, proto.pfields[idx], eval(ctx, e2), p);
						proto.pfields[idx] = r;
						r;
					case TField(fe, fa):
						var obj = eval(ctx, fe);
						var name = fieldKey(fa);
						var r = binopValue(ctx, sub, EvalField.field(ctx, obj, name), eval(ctx, e2), p);
						EvalField.setField(ctx, obj, name, r, p);
						r;
					case TArray(arrE, idxE):
						switch (eval(ctx, arrE)) {
							case VArray(va):
								var idx = switch (eval(ctx, idxE)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
								var r = binopValue(ctx, sub, arrayElemGet(va, idx), eval(ctx, e2), p);
								arrayElemSet(va, idx, r);
								r;
							case VVector(vv):
								var idx = switch (eval(ctx, idxE)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
								var r = binopValue(ctx, sub, vecElemGet(vv, idx), eval(ctx, e2), p);
								vecElemSet(vv, idx, r);
								r;
							case v: EvalExceptions.unexpectedValue(ctx, v, "Array");
						}
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

	static inline function arrayElemGet(va:VArray, idx:Int):EvalValue {
		return (idx >= 0 && idx < va.alength) ? va.avalues[idx] : VNull;
	}

	static function arrayElemSet(va:VArray, idx:Int, value:EvalValue):Void {
		while (va.avalues.length <= idx) va.avalues.push(VNull);
		va.avalues[idx] = value;
		if (idx >= va.alength) va.alength = idx + 1;
	}

	// A fixed-size eval.Vector: reads out of range yield null and writes out of range are dropped, since a
	// Vector never grows (its slots are allocated at construction).
	static inline function vecElemGet(vv:Array<EvalValue>, idx:Int):EvalValue {
		return (idx >= 0 && idx < vv.length) ? vv[idx] : VNull;
	}

	static inline function vecElemSet(vv:Array<EvalValue>, idx:Int, value:EvalValue):Void {
		if (idx >= 0 && idx < vv.length) vv[idx] = value;
	}

	// `lhs = ve`: the assignment target's location is evaluated left to right before the value, so
	// `a[i++]
	// = i++` reads the index then the value, not the value first.
	static function assign(ctx:EvalContext, lhs:TExpr, ve:TExpr):EvalValue {
		switch (lhs.expr) {
			case TLocal(v):
				var fe = findEnv(EvalContext.getEval(ctx).env, v.id);
				var value = eval(ctx, ve);
				fe.locals[slot(fe, v.id)] = value;
				return value;
			case TField(_, FStatic(c, cf)):
				var proto = EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(c.path), lhs.pos);
				var value = eval(ctx, ve);
				proto.pfields[EvalContext.getProtoFieldIndex(proto, EvalHash.hash(cf.name), lhs.pos)] = value;
				return value;
			case TField(e1, fa):
				var obj = eval(ctx, e1);
				var value = eval(ctx, ve);
				EvalField.setField(ctx, obj, fieldKey(fa), value, lhs.pos);
				return value;
			case TArray(e1, eidx):
				switch (eval(ctx, e1)) {
					case VArray(va):
						var idx = switch (eval(ctx, eidx)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
						var value = eval(ctx, ve);
						while (va.avalues.length <= idx) va.avalues.push(VNull);
						va.avalues[idx] = value;
						if (idx >= va.alength) va.alength = idx + 1;
						return value;
					case VVector(vv):
						var idx = switch (eval(ctx, eidx)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
						var value = eval(ctx, ve);
						vecElemSet(vv, idx, value);
						return value;
					case v: return EvalExceptions.unexpectedValue(ctx, v, "Array");
				}
			case _:
				return EvalExceptions.excString(ctx, "Unsupported assignment target");
		}
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
					case TField(_, FStatic(c, cf)):
						var proto = EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(c.path), p);
						var idx = EvalContext.getProtoFieldIndex(proto, EvalHash.hash(cf.name), p);
						var old = proto.pfields[idx];
						var delta = op == Increment ? 1 : -1;
						var next = switch (old) {
							case VInt(i): VInt(i + delta);
							case VFloat(f): VFloat(f + delta);
							case _: EvalExceptions.unexpectedValue(ctx, old, "number");
						};
						proto.pfields[idx] = next;
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
					case TArray(arrE, idxE):
						switch (eval(ctx, arrE)) {
							case VArray(va):
								var idx = switch (eval(ctx, idxE)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
								var old = arrayElemGet(va, idx);
								var delta = op == Increment ? 1 : -1;
								var next = switch (old) {
									case VInt(i): VInt(i + delta);
									case VFloat(f): VFloat(f + delta);
									case _: EvalExceptions.unexpectedValue(ctx, old, "number");
								};
								arrayElemSet(va, idx, next);
								flag == Prefix ? next : old;
							case VVector(vv):
								var idx = switch (eval(ctx, idxE)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int"); };
								var old = vecElemGet(vv, idx);
								var delta = op == Increment ? 1 : -1;
								var next = switch (old) {
									case VInt(i): VInt(i + delta);
									case VFloat(f): VFloat(f + delta);
									case _: EvalExceptions.unexpectedValue(ctx, old, "number");
								};
								vecElemSet(vv, idx, next);
								flag == Prefix ? next : old;
							case v: EvalExceptions.unexpectedValue(ctx, v, "Array");
						}
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

	// Match a thrown value against a try's catch clauses; run the first that matches, else onUnmatched.
	static function runCatch(ctx:EvalContext, value:EvalValue, catches:Array<TCatch>, savedEnv:EvalEnv, onUnmatched:Void->EvalValue):EvalValue {
		for (c in catches) {
			if (catchMatches(ctx, value, c.v.type)) {
				savedEnv.locals[slot(savedEnv, c.v.id)] = wrapCaught(ctx, value, c.v.type);
				return eval(ctx, c.expr);
			}
		}
		return onUnmatched();
	}

	static function evalField(ctx:EvalContext, e1:TExpr, fa:TFieldAccess, p:Position):EvalValue {
		return switch (fa) {
			case FStatic(c, cf):
				// A static field missing from the prototype means its owning body failed to type and was
				// dropped (a known hxc typing gap). Surface it as a catchable interpreted exception so the
				// running program (e.g. the utest runner) records an error for that test and keeps going,
				// rather than a host NotFound escaping the interpreter and aborting the whole run.
				try EvalField.protoFieldRaise(EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(c.path), p), EvalHash.hash(cf.name))
				catch (_:hxc.core.NotFound) EvalExceptions.excString(ctx, "hxc: " + c.path.name + "." + cf.name + " is not available (compiler typing gap)");
			case FEnum(en, ef):
				try EvalField.protoFieldRaise(EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(en.path), p), EvalHash.hash(ef.name))
				catch (_:hxc.core.NotFound) EvalExceptions.excString(ctx, "hxc: " + en.path.name + "." + ef.name + " is not available (compiler typing gap)");
			case FInstance(_, _, cf) | FClosure(_, cf):
				// Accessing a field on a null receiver raises a catchable Null Object Reference, matching
				// the reference; returning null here would silently mask the error.
				var recv = eval(ctx, e1);
				switch (recv) {
					case VNull: EvalExceptions.excString(ctx, "Null Object Reference");
					case _: EvalField.dynamicField(ctx, recv, EvalHash.hash(cf.name));
				}
			case FAnon(cf):
				// On a class instance/builtin viewed structurally an instance method binds its receiver
				// (e.g. iterator via Iterable); on a plain anonymous object the field is a raw value.
				var recv = eval(ctx, e1);
				switch (recv) {
					case VObject(_): EvalField.field(ctx, recv, EvalHash.hash(cf.name));
					case _: EvalField.dynamicField(ctx, recv, EvalHash.hash(cf.name));
				}
			case FDynamic(s):
				EvalField.dynamicField(ctx, eval(ctx, e1), EvalHash.hash(s));
		};
	}

	static function evalCall(ctx:EvalContext, callee:TExpr, argExprs:Array<TExpr>, p:Position):EvalValue {
		switch (callee.expr) {
			case TIdent("$__mk_pos__"):
				// Reification's position builtin: build a Position value from (file, min, max).
				var a = [for (x in argExprs) eval(ctx, x)];
				var m = new Map<Int, EvalValue>();
				m.set(EvalHash.hash("file"), a[0]);
				m.set(EvalHash.hash("min"), a[1]);
				m.set(EvalHash.hash("max"), a[2]);
				return VObject(new VObject([], ODictionary(m)));
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
			case TField({expr: TConst(TSuper)}, fa):
				// A `super.method()` call dispatches to the definition on the named class, not the
				// receiver's override, so resolve the method from that class's prototype directly.
				var c = switch (fa) { case FInstance(cc, _, _): cc; case FClosure(cc, _): cc == null ? null : cc.c; case _: null; };
				var cf = switch (fa) { case FInstance(_, _, f) | FClosure(_, f): f; case _: null; };
				if (c != null && cf != null) {
					var proto = ctx.instancePrototypes.get(EvalHash.pathHash(c.path));
					var m = superProtoMethod(proto, EvalHash.hash(cf.name));
					var vthis = EvalContext.getEval(ctx).env.vthis;
					var args = [for (a in argExprs) eval(ctx, a)];
					switch (m) {
						case VFunction(f, _): return f([vthis].concat(args));
						case _:
					}
				}
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

	// Resolve a method by hashed name from the given prototype up its parent chain (used for super
	// calls, which start the lookup at the named class rather than the receiver's runtime prototype).
	static function superProtoMethod(proto:Null<VPrototype>, name:Int):EvalValue {
		var p = proto;
		while (p != null) {
			var idx = p.pnames.get(name);
			if (idx != null) return p.pfields[idx];
			p = p.pparent;
		}
		return VNull;
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

	// The value bound to a function parameter: the passed argument, or when it is missing or null, the
	// parameter's default value if it declares one (a compile-time constant), as if the body began with `if
	// (arg == null) arg = default`.
	public static function argValue(ctx:EvalContext, arg:TFuncArg, provided:EvalValue):EvalValue {
		if (arg.c != null) switch (provided) { case VNull: return eval(ctx, arg.c); case _: }
		return provided;
	}

	// A closure captures its defining frame and runs its body in a child frame linked to it.
	static function makeClosure(ctx:EvalContext, tf:TFunc, captured:EvalEnv):VFunc {
		return function(args:Array<EvalValue>):EvalValue {
			var env2 = EvalContext.pushEnvironment(ctx, {isStatic: true, file: 0, kind: EKLocalFunction(0), numLocals: 0, numCaptures: 0});
			env2.lexicalParent = captured;
			env2.vthis = captured == null ? null : captured.vthis;
			for (i in 0...tf.args.length) {
				env2.locals[slot(env2, tf.args[i].v.id)] = argValue(ctx, tf.args[i], i < args.length ? args[i] : VNull);
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
		var cc = c;
		while (ctor == null && cc.superClass != null) {
			cc = cc.superClass.c;
			ctor = ctx.constructors.get(EvalHash.pathHash(cc.path));
		}
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

	// Instance variable initializers run on the new object before the constructor body. A subclass inherits
	// its ancestors' field initializers (each class's inits run in its own constructor, so super() runs
	// them); walk the super chain root-first so ancestor inits apply before the subclass's, and no
	// inherited initializer is skipped.
	static function applyFieldInits(ctx:EvalContext, c:TClass, instVal:EvalValue):Void {
		var chain:Array<TClass> = [];
		var cur = c;
		while (cur != null) {
			chain.push(cur);
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		var i = chain.length - 1;
		while (i >= 0) {
			var cls = chain[i];
			for (cf in cls.orderedFields) {
				switch (cf.kind) {
					case Var(_) if (cf.expr != null):
						var env = EvalContext.pushEnvironment(ctx, {isStatic: false, file: 0, kind: EKEntrypoint, numLocals: 0, numCaptures: 0});
						env.vthis = instVal;
						var v = eval(ctx, cf.expr);
						EvalContext.popEnvironment(ctx, env);
						EvalField.setField(ctx, instVal, EvalHash.hash(cf.name), v, cls.pos);
					case _:
				}
			}
			i--;
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
