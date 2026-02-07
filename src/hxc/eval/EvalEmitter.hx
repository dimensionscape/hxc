package hxc.eval;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals;
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
	static var forRemapCache:haxe.ds.ObjectMap<TExpr, TExpr> = new haxe.ds.ObjectMap();

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

	static inline function isAbstractPath(t:T, pack:Array<String>, name:String):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): a.path.name == name && a.path.pack.join(".") == pack.join(".");
			case _: false;
		};
	}

	static function isUIntType(t:T):Bool return isAbstractPath(t, [], "UInt");

	static function isUIntExpr(e:TExpr):Bool return if (isUIntType(e.type)) true else switch (e.expr) {
		case TLocal(v): isUIntType(v.type);
		case TCast(inner, _): isUIntExpr(inner);
		case TMeta(_, inner) | TParenthesis(inner): isUIntExpr(inner);
		case _: false;
	};

	static function unsignedValue(v:EvalValue):EvalValue return switch (v) {
		case VInt(i): VFloat(i < 0 ? 4294967296.0 + i : i + 0.0);
		case _: v;
	};

	static inline function isEvalTarget(ctx:EvalContext):Bool return !ctx.isMacro && ctx.com != null && ctx.com.platform.match(Eval);

	static function evalCast(ctx:EvalContext, e:TExpr, target:T):EvalValue {
		var v = eval(ctx, e);
		if (isAbstractPath(e.type, [], "UInt") && isAbstractPath(target, [], "Float")) {
			return switch (v) {
				case VInt(i): VFloat(i < 0 ? 4294967296.0 + i : i + 0.0);
				case VFloat(_): v;
				case _: v;
			};
		}
		return v;
	}

	public static function eval(ctx:EvalContext, e:TExpr):EvalValue {
		var ev = EvalContext.getEval(ctx);
		var oldPos = ev.currentPos;
		if (e.pos != null && e.pos.min >= 0) ev.currentPos = e.pos;
		var env = ev.env;
		var result = try switch (e.expr) {
			case TConst(TThis): env.vthis == null ? VNull : env.vthis;
			case TConst(c): evalConst(c);
			case TLocal(v): var fe = findEnv(env, v.id); fe.locals[slot(fe, v.id)];
			case TParenthesis(e1) | TMeta(_, e1): eval(ctx, e1);
			case TCast(e1, mt):
				switch (mt) {
					// A safe cast `cast(e,T)` checks the runtime type and throws "Class cast error" unless
					// the value is null or `is v t`. Applied to class, enum, and abstract targets alike;
					// `is` handles the basic-type paths (Int/Float/Bool/String).
					case TClassDecl(_) | TEnumDecl(_) | TAbstractDecl(_):
						var v1 = eval(ctx, e1);
						switch (EvalValueTools.vresolve(v1)) {
							case VNull: v1;
							case _:
								var path = EvalHash.pathHash(TypeFunctions.tInfos(mt).path);
								if (!EvalStdLib.isOfTypePath(ctx, v1, path)) EvalExceptions.excString(ctx, "Class cast error", e.pos);
								else v1;
						}
					case _: evalCast(ctx, e1, e.type);
				}
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
			case TFor(v, eiter, body):
				// A TFor runs as its hasNext/next while loop, lowered once per node and kept.
				// The basic types are the current API's com, the macro com in a macro.
				var com = ctx.com != null ? ctx.com : @:privateAccess hxc.eval.EvalMacro.macroCom;
				if (com == null) evalFor(ctx, v, eiter, body, e.pos) else {
					var r = forRemapCache.get(e);
					if (r == null) {
						r = hxc.optimization.AnalyzerTexpr.TexprFilter.forRemap(com.basic, v, eiter, body, e.pos);
						forRemapCache.set(e, r);
					}
					eval(ctx, r);
				}
			case TReturn(eo): throw new EvalReturn(eo == null ? VNull : eval(ctx, eo));
			case TBreak: throw new EvalBreak();
			case TContinue: throw new EvalContinue();
			case TThrow(e1):
				// A throw raises at its own position. A written throw carries the keyword's span; the throw
				// the typer builds for a macro called inside the macro world carries the call's whole span.
				EvalExceptions.throwValue(ctx, unwrapThrown(ctx, eval(ctx, e1)), e.pos);
			case TArrayDecl(el): VArray(new VArray([for (x in el) eval(ctx, x)], el.length));
			case TObjectDecl(fields):
				var m = new Map<Int, EvalValue>();
				for (f in fields) m.set(EvalHash.hash(f.key.name), eval(ctx, f.expr));
				VObject(new VObject([], ODictionary(m)));
			case TTry(e1, catches):
				var ev = EvalContext.getEval(ctx);
				var savedEnv = ev.env;
				var result:EvalValue = VNull;
				ev.lastExceptionPos = Position.nullPos;
				try {
					result = eval(ctx, e1);
				} catch (ex:EvalRunTimeException) {
					ev.env = savedEnv;
					ev.exceptionStack = EvalExceptions.exceptionStack(ex);
					result = runCatch(ctx, ex.value, catches, savedEnv, function() { throw ex; });
				} catch (ex:Dynamic) {
					// Control-flow signals must reach their own handlers, never a program try/catch.
					if (Std.isOfType(ex, EvalBreak) || Std.isOfType(ex, EvalContinue) || Std.isOfType(ex, EvalReturn) || Std.isOfType(ex, EvalSysExit)) throw ex;
					// A try catches runtime exceptions alone: Context.error's abort and a fatal error are
					// internal exceptions no macro try sees.
					// A typing error raised while a macro API call runs the typer is the same: it reaches
					// the API boundary, where it becomes the macro's Error value.
					if (Std.isOfType(ex, hxc.eval.EvalExceptions.MacroAbort) || Std.isOfType(ex, hxc.core.TypingError.FatalError) || Std.isOfType(ex, hxc.core.TypingError)) throw ex;
					// Any other host exception is an hxc-internal failure escaping the interpreter (a dropped
					// field, a native builtin error). Present it to the running program as a normal thrown
					// value so its own try/catch (e.g. the utest runner) records an error and continues,
					// instead of aborting the whole run. The value is re-raised if no local catch matches.
					ev.env = savedEnv;
					ev.exceptionStack = hostExceptionStack(ev);
					var s = Std.string(ex);
					var v = VString(hxc.eval.EvalValue.VString.createUnknown(s));
					result = runCatch(ctx, v, catches, savedEnv, function() return EvalExceptions.throwValue(ctx, v, e.pos));
				}
				result;
			case TArray(e1, e2):
				switch (eval(ctx, e1)) {
					case VArray(va):
						var idx = switch (eval(ctx, e2)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int", e2.pos); };
						(idx >= 0 && idx < va.alength) ? va.avalues[idx] : VNull;
					case VVector(vv):
						var idx = switch (eval(ctx, e2)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int", e2.pos); };
						vecElemGet(vv, idx);
					case v: EvalExceptions.unexpectedValue(ctx, v, "Array", e1.pos);
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
			// A closure's arguments are exactly its declared ones (this lives in the captured
			// environment), so it is self-contained: a read through a field must not rebind a receiver
			// onto it, unlike a prototype method (e.g. a reassigned dynamic method's replacement).
			case TFunction(tf): VFunction(makeClosure(ctx, tf, EvalContext.getEval(ctx).env), true);
			case TField(e1, fa): evalField(ctx, e1, fa, e.pos);
			case TCall(callee, callArgs): evalCall(ctx, callee, callArgs, e.pos);
			case TNew(c, params, newArgs):
				// A class with a special (native) constructor constructs natively, with no depth check; any
				// other through a constructor call, whose depth check precedes the arguments.
				if (!ctx.builtins.constructorBuiltins.exists(EvalHash.pathHash(c.path))) checkStackDepth(ctx);
				evalNew(ctx, c, params, [for (a in newArgs) eval(ctx, a)], e.pos, newArgs.length == 0 ? null : newArgs[0].pos);
			case TSwitch(subject, cases, edef): evalSwitch(ctx, subject, cases, edef);
			case TEnumParameter(e1, _, index):
				switch (eval(ctx, e1)) {
					case VEnumValue(ev): ev.eargs[index];
					case v: EvalExceptions.unexpectedValue(ctx, v, "enum value", e1.pos);
				}
			case TEnumIndex(e1):
				switch (eval(ctx, e1)) {
					case VEnumValue(ev): VInt(ev.eindex);
					case v: EvalExceptions.unexpectedValue(ctx, v, "enum value", e1.pos);
				}
			case _: EvalExceptions.excString(ctx, "Unsupported expression in eval: " + Std.string(e.expr).split("(")[0], e.pos);
		} catch (ex:Dynamic) {
			if (!Std.isOfType(ex, EvalBreak)
				&& !Std.isOfType(ex, EvalContinue)
				&& !Std.isOfType(ex, EvalReturn)
				&& !Std.isOfType(ex, EvalSysExit)
				&& !Std.isOfType(ex, EvalRunTimeException)
				&& (ev.lastExceptionPos == null || ev.lastExceptionPos.min < 0)) {
				ev.lastExceptionPos = ev.currentPos;
			}
			ev.currentPos = oldPos;
			throw ex;
		};
		ev.currentPos = oldPos;
		return result;
	}

	static function hostExceptionStack(ev:Eval):Array<{pos:Position, kind:EvalEnvKind}> {
		var out = [for (env in EvalExceptions.callStack(ev)) {pos: EvalExceptions.envPosition(env), kind: env.info.kind}];
		var p = ev.lastExceptionPos;
		if (p != null && p.min >= 0) {
			if (out.length > 0) out[0] = {pos: p, kind: out[0].kind};
			else out.push({pos: p, kind: EKEntrypoint});
		}
		return out;
	}

	static function evalConst(c:TConstant):EvalValue {
		return switch (c) {
			case TInt(i): VInt(i);
			case TFloat(s): VFloat(hxc.core.Numeric.parseFloatLit(s));
			case TString(s): VString(hxc.eval.EvalValue.VString.createUnknown(s));
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
	// Throwing a haxe.Exception surfaces its native exception, which for a directly constructed one
	// is the exception itself (its stack survives the throw), and for a wrapper built around a caught
	// value is that original value, so an outer catch of the native type matches. from
	// haxe.Exception.thrown returning (value:Exception).native.
	static function unwrapThrown(ctx:EvalContext, v:EvalValue):EvalValue {
		return switch (v) {
			case VInstance(vi) if (vi.iproto.ppath == EvalHash.hash("haxe.macro.Expr.Error") || vi.iproto.ppath == EvalHash.hash("haxe.macro.Error")): v;
			case VInstance(_) if (EvalStdLib.isOfTypePath(ctx, v, EvalHash.key_haxe_Exception)):
				var native = EvalField.field(ctx, v, EvalHash.keyNativeException);
				native == VNull ? v : native;
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
					if (wrapped != VNull) {
						var stack = EvalStdLib.exceptionStackValue(ctx);
						EvalField.setField(ctx, wrapped, EvalHash.keyExceptionStack, stack, Position.nullPos);
						EvalField.setField(ctx, wrapped, EvalHash.keyNativeStack, stack, Position.nullPos);
						EvalField.setField(ctx, wrapped, EvalHash.keyNativeException, v, Position.nullPos);
						EvalField.setField(ctx, wrapped, EvalHash.hash("__skipStack"), VInt(0), Position.nullPos);
					}
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
			case _: EvalExceptions.excString(ctx, "Unsupported binop", p);
		};
	}

	static function evalBinop(ctx:EvalContext, op:Binop, e1:TExpr, e2:TExpr, p:Position):EvalValue {
		function unsigned(v:EvalValue):EvalValue return switch (v) {
			case VInt(i): VFloat(i < 0 ? 4294967296.0 + i : i + 0.0);
			case _: v;
		};
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
						var proto = ensureStaticProto(ctx, c, p);
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
								var idx = switch (eval(ctx, idxE)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int", idxE.pos); };
								var r = binopValue(ctx, sub, arrayElemGet(va, idx), eval(ctx, e2), p);
								arrayElemSet(va, idx, r);
								r;
							case VVector(vv):
								var idx = switch (eval(ctx, idxE)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int", idxE.pos); };
								var r = binopValue(ctx, sub, vecElemGet(vv, idx), eval(ctx, e2), p);
								vecElemSet(vv, idx, r);
								r;
							case v: EvalExceptions.unexpectedValue(ctx, v, "Array", arrE.pos);
						}
					case _: EvalExceptions.excString(ctx, "Unsupported compound assignment target", p);
				}
			case OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte:
				var left = eval(ctx, e1);
				var right = eval(ctx, e2);
				var unsignedCompare = switch (op) { case OpGt | OpGte | OpLt | OpLte: true; case _: false; };
				binopValue(ctx, op, isEvalTarget(ctx) && unsignedCompare && isUIntExpr(e1) ? unsigned(left) : left, isEvalTarget(ctx) && unsignedCompare && isUIntExpr(e2) ? unsigned(right) : right, p);
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
				var proto = ensureStaticProto(ctx, c, lhs.pos);
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
						var idx = switch (eval(ctx, eidx)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int", eidx.pos); };
						var value = eval(ctx, ve);
						while (va.avalues.length <= idx) va.avalues.push(VNull);
						va.avalues[idx] = value;
						if (idx >= va.alength) va.alength = idx + 1;
						return value;
					case VVector(vv):
						var idx = switch (eval(ctx, eidx)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int", eidx.pos); };
						var value = eval(ctx, ve);
						vecElemSet(vv, idx, value);
						return value;
					case v: return EvalExceptions.unexpectedValue(ctx, v, "Array", e1.pos);
				}
			case _:
				return EvalExceptions.excString(ctx, "Unsupported assignment target", lhs.pos);
		}
	}

	static function evalUnop(ctx:EvalContext, op:Unop, flag:UnopFlag, e1:TExpr, p:Position):EvalValue {
		return switch (op) {
			case Not: switch (eval(ctx, e1)) { case VNull | VFalse: VTrue; case _: VFalse; };
			case Neg:
				switch (eval(ctx, e1)) {
					case VInt(i): VInt(-i);
					case VFloat(f): VFloat(-f);
					case v: EvalExceptions.unexpectedValue(ctx, v, "number", e1.pos);
				}
			case NegBits:
				switch (eval(ctx, e1)) {
					case VInt(i): VInt(~i);
					case v: EvalExceptions.unexpectedValue(ctx, v, "Int", e1.pos);
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
							case _: EvalExceptions.unexpectedValue(ctx, old, "number", e1.pos);
						};
						fe.locals[s] = next;
						flag == Prefix ? next : old;
					case TField(_, FStatic(c, cf)):
						var proto = ensureStaticProto(ctx, c, p);
						var idx = EvalContext.getProtoFieldIndex(proto, EvalHash.hash(cf.name), p);
						var old = proto.pfields[idx];
						var delta = op == Increment ? 1 : -1;
						var next = switch (old) {
							case VInt(i): VInt(i + delta);
							case VFloat(f): VFloat(f + delta);
							case _: EvalExceptions.unexpectedValue(ctx, old, "number", e1.pos);
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
							case _: EvalExceptions.unexpectedValue(ctx, old, "number", e1.pos);
						};
						EvalField.setField(ctx, obj, name, next, p);
						flag == Prefix ? next : old;
					case TArray(arrE, idxE):
						switch (eval(ctx, arrE)) {
							case VArray(va):
								var idx = switch (eval(ctx, idxE)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int", idxE.pos); };
								var old = arrayElemGet(va, idx);
								var delta = op == Increment ? 1 : -1;
								var next = switch (old) {
									case VInt(i): VInt(i + delta);
									case VFloat(f): VFloat(f + delta);
									case _: EvalExceptions.unexpectedValue(ctx, old, "number", e1.pos);
								};
								arrayElemSet(va, idx, next);
								flag == Prefix ? next : old;
							case VVector(vv):
								var idx = switch (eval(ctx, idxE)) { case VInt(i): i; case v: EvalExceptions.unexpectedValue(ctx, v, "Int", idxE.pos); };
								var old = vecElemGet(vv, idx);
								var delta = op == Increment ? 1 : -1;
								var next = switch (old) {
									case VInt(i): VInt(i + delta);
									case VFloat(f): VFloat(f + delta);
									case _: EvalExceptions.unexpectedValue(ctx, old, "number", e1.pos);
								};
								vecElemSet(vv, idx, next);
								flag == Prefix ? next : old;
							case v: EvalExceptions.unexpectedValue(ctx, v, "Array", arrE.pos);
						}
					case _: EvalExceptions.excString(ctx, "Unsupported increment target", e1.pos);
				}
			case _: EvalExceptions.excString(ctx, "Unsupported unop", p);
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

	static function evalFor(ctx:EvalContext, v:TVar, eiter:TExpr, body:TExpr, p:Position):EvalValue {
		var it = eval(ctx, eiter);
		var env = EvalContext.getEval(ctx).env;
		while (EvalMisc.isTrue(callField(ctx, it, "hasNext", [], p))) {
			env.locals[slot(env, v.id)] = callField(ctx, it, "next", [], p);
			try eval(ctx, body) catch (_:EvalBreak) break catch (_:EvalContinue) {}
		}
		return VNull;
	}

	static function callField(ctx:EvalContext, recv:EvalValue, name:String, args:Array<EvalValue>, p:Position):EvalValue {
		// The lowered iterator calls are field calls: the depth check comes first.
		checkStackDepth(ctx);
		return switch (EvalValueTools.vresolve(EvalField.dynamicField(ctx, recv, EvalHash.hash(name)))) {
			case VFunction(f, _): callAt(ctx, p, f, args);
			case VFieldClosure(r, f): callAt(ctx, p, f, [r].concat(args));
			// "Cannot call <value>", with no position of its own; the frame shows the call, which the
			// emitter records before any call.
			case v:
				var ev = EvalContext.getEval(ctx);
				if (ev.env != null) EvalExceptions.setLeavePosition(ev.env, p);
				EvalExceptions.excString(ctx, "Cannot call " + EvalStdLib.stringOf(v));
		}
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

	// `pre` is the receiver already evaluated by a call (evaluated once, before the null check); without it
	// the field read evaluates e1 itself.
	static function evalField(ctx:EvalContext, e1:TExpr, fa:TFieldAccess, p:Position, ?pre:EvalValue):EvalValue {
		return switch (fa) {
			case FStatic(c, cf):
				// A static field missing from the prototype means its owning body was not typed and
				// installed (a module pulled into the macro world after the interpreter was built only
				// force-types its reachable statics). Type it on demand and install it, then retry; a
				// genuine gap surfaces as a catchable interpreted exception so the running program keeps
				// going rather than a host NotFound aborting the whole run.
				try EvalField.protoFieldRaise(ensureStaticProto(ctx, c, p), EvalHash.hash(cf.name))
				catch (_:hxc.core.NotFound) {
					// A macro API class's DECLARED static late-types (its typed wrapper must run); the
					// builtin backs only genuine gaps. (natives through load).
					if (hxc.eval.EvalPrototype.isMacroApiClass(ctx, c)) {
						var late0 = lateStaticMethod(ctx, c, cf);
						if (late0 != null) return late0;
					}
					var builtins = ctx.builtins.staticBuiltins.get(EvalHash.pathHash(c.path));
					if (builtins != null) for (b in builtins) if (b.name == EvalHash.hash(cf.name)) return b.v;
					var late = lateStaticMethod(ctx, c, cf);
					late != null ? late : EvalExceptions.excString(ctx, "hxc: " + c.path.name + "." + cf.name + " is not available (compiler typing gap)", p);
				}
			case FEnum(en, ef):
				try EvalField.protoFieldRaise(EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(en.path), p), EvalHash.hash(ef.name))
				catch (_:hxc.core.NotFound) EvalExceptions.excString(ctx, "hxc: " + en.path.name + "." + ef.name + " is not available (compiler typing gap)", p);
			case FClosure(cwp, cf):
				// A bound-method value read off a null receiver is simply null (no raise).
				var recv = pre != null ? pre : eval(ctx, e1);
				switch (recv) {
					case VNull: VNull;
					case _:
						if (cf.expr == null && ctx.com != null && cwp != null) hxc.typing.TypeFields.forceFieldBody(ctx.com, cwp.c, cf);
						var v = EvalField.dynamicField(ctx, recv, EvalHash.hash(cf.name));
						if (v == VNull) lateInstanceMethod(ctx, recv, cf) else v;
				}
			case FInstance(c, _, cf):
				var recv = pre != null ? pre : eval(ctx, e1);
				switch (recv) {
					case VNull:
						// A null receiver splits by field kind: a method-call receiver fails the null check
						// with "Null Access", a var read fails with "field access on null".
						// An Array's length read decodes the array, whose null is "Null Access".
						switch (cf.kind) {
							case Method(_): EvalExceptions.excString(ctx, "Null Access", e1.pos);
							// Array, eval.Vector and haxe.io.Bytes have their own length reads, whose null
							// is "Null Access".
							case Var(_) if (cf.name == "length" && switch (c.path) {
								case {pack: [], name: "Array"} | {pack: ["haxe", "io"], name: "Bytes"} | {pack: ["eval"], name: "Vector"}: true;
								case _: false;
							}):
								EvalExceptions.excString(ctx, "Null Access", e1.pos);
							case Var(_): EvalExceptions.excString(ctx, "field access on null", e1.pos);
						}
					case _:
						switch (cf.kind) {
							case Method(_):
								if (cf.expr == null && ctx.com != null) hxc.typing.TypeFields.forceFieldBody(ctx.com, c, cf);
								var v = EvalField.dynamicField(ctx, recv, EvalHash.hash(cf.name));
								if (v == VNull) lateInstanceMethod(ctx, recv, cf) else v;
							case Var(_):
								var v = EvalField.field(ctx, recv, EvalHash.hash(cf.name));
								if (v == VNull && cf.name == "stack" && EvalStdLib.isOfTypePath(ctx, recv, EvalHash.key_haxe_Exception)) EvalField.field(ctx, recv, EvalHash.keyNativeStack) else v;
						}
				}
			case FAnon(cf):
				// On a class instance/builtin viewed structurally an instance method binds its receiver
				// (e.g. iterator via Iterable); on a plain anonymous object the field is a raw value.
				var recv = pre != null ? pre : eval(ctx, e1);
				switch (recv) {
					case VObject(_): EvalField.field(ctx, recv, EvalHash.hash(cf.name));
					// A structure's field read raises on a null receiver.
					case VNull: EvalExceptions.excString(ctx, "field access on null", e1.pos);
					case _:
						var v = EvalField.dynamicField(ctx, recv, EvalHash.hash(cf.name));
						if (v == VNull) lateInstanceMethodByName(ctx, recv, cf.name, p) else v;
				}
			case FDynamic(s):
				EvalField.dynamicField(ctx, pre != null ? pre : eval(ctx, e1), EvalHash.hash(s));
		};
	}

	// Types a static method's body on demand and installs it into the class's static prototype,
	// returning the callable value; null when the field has no method body to install. Mirrors
	// lateInstanceMethod for statics (a lazily added macro module force-types only reachable statics).
	static function lateStaticMethod(ctx:EvalContext, c:TClass, cf:TClassField):Null<EvalValue> {
		// The field access may carry a clone (a multiType cast field is rebuilt with the
		// abstract's parameters applied); forcing needs the canonical field, whose identity
		// matches the parsed decl.
		switch (ctx.typeCache.get(EvalHash.pathHash(c.path))) {
			case TClassDecl(realC):
				var real = realC.statics.get(cf.name);
				if (real != null && real != cf) { c = realC; cf = real; }
			case _:
		}
		if (cf.expr == null) {
			var com = ctx.com;
			var mc = hxc.eval.EvalMacro.getMacroCom();
			if (mc != null && c.module != null && mc.moduleLut.get(hxc.context.Context.pathKey(c.module.path)) == c.module) com = mc;
			if (com == null) com = hxc.eval.EvalMacro.hostCom;
			if (com != null) {
				var savedMod = com.currentModule;
				com.currentModule = c.module;
				try hxc.typing.TypeFields.forceFieldBody(com, c, cf) catch (e:Dynamic) {
					if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null)
						Sys.println("[latestatic] force " + c.path.name + "." + cf.name + " threw: " + Std.string(e));
				}
				com.currentModule = savedMod;
				if (com == hxc.eval.EvalMacro.getMacroCom()) hxc.eval.EvalMacro.syncMacroModules();
			}
		}
		return switch (cf.expr) {
			case {expr: TFunction(tf)}:
				var key = EvalHash.pathHash(c.path);
				var proto = ctx.staticPrototypes.get(key);
				if (proto == null) return null;
				var name = EvalHash.hash(cf.name);
				var info = EvalContext.createEnvInfo(true, cf.namePos, EKMethod(key, name), 0, 0);
				var vf = VFunction(EvalPrototype.makeFunction(ctx, tf, false, info), true);
				var idx = proto.pnames.get(name);
				if (idx == null) {
					proto.pnames.set(name, proto.pfields.length);
					proto.pfields.push(vf);
				} else {
					proto.pfields[idx] = vf;
				}
				vf;
			case _: null;
		}
	}

	static function lateInstanceMethod(ctx:EvalContext, recv:EvalValue, cf:TClassField):EvalValue {
		return switch (recv) {
			case VInstance(vi):
				// A method of a lazily loaded module may not have its body typed yet (a macro-world
				// module pulled in during body typing only forces reachable statics); type it now.
				if (cf.expr == null) switch (ctx.typeCache.get(vi.iproto.ppath)) {
					case TClassDecl(c):
						var com = ctx.com;
						var mc = hxc.eval.EvalMacro.getMacroCom();
						if (mc != null && c.module != null && mc.moduleLut.get(hxc.context.Context.pathKey(c.module.path)) == c.module) com = mc;
						if (com == null) com = hxc.eval.EvalMacro.hostCom;
						if (com != null) {
							var savedMod = com.currentModule;
							com.currentModule = c.module;
							try hxc.typing.TypeFields.forceFieldBody(com, c, cf) catch (_:Dynamic) {}
							com.currentModule = savedMod;
							// Typing the body may have pulled new modules into the macro world.
							if (com == hxc.eval.EvalMacro.getMacroCom()) hxc.eval.EvalMacro.syncMacroModules();
						}
					case _:
				}
				switch (cf.expr) {
					case {expr: TFunction(tf)}:
						var name = EvalHash.hash(cf.name);
						var info = EvalContext.createEnvInfo(false, cf.namePos, EKMethod(vi.iproto.ppath, name), 0, 0);
						var vf = VFunction(EvalPrototype.makeFunction(ctx, tf, true, info), false);
						var idx = vi.iproto.pnames.get(name);
						if (idx == null) {
							vi.iproto.pnames.set(name, vi.iproto.pfields.length);
							vi.iproto.pfields.push(vf);
						} else {
							vi.iproto.pfields[idx] = vf;
						}
						switch (vf) {
							case VFunction(f, _): VFieldClosure(recv, f);
							case _: VNull;
						}
					case _:
						var typeName = EvalHash.revHash(vi.iproto.ppath);
						EvalExceptions.excString(ctx, "hxc: method body is not available: " + (typeName == null ? "?" : typeName) + "." + cf.name, cf.namePos);
				}
			case _:
				VNull;
		}
	}

	static function lateInstanceMethodByName(ctx:EvalContext, recv:EvalValue, name:String, p:Position):EvalValue {
		return switch (recv) {
			case VInstance(vi):
				switch (ctx.typeCache.get(vi.iproto.ppath)) {
					case TClassDecl(c):
						try {
							var r = TypeFunctions.rawClassField(function(f) return f.type, c, TypeFunctions.extractParamTypes(c.params), name);
							switch (r.c2) {
								case null:
								case cwp:
									if (r.f.expr == null && ctx.com != null) hxc.typing.TypeFields.forceFieldBody(ctx.com, cwp.c, r.f);
							}
							lateInstanceMethod(ctx, recv, r.f);
						} catch (_:hxc.core.NotFound) {
							VNull;
						}
					case _:
						VNull;
				}
			case _:
				VNull;
		}
	}

	// Every call begins by checking the CALLER's depth, before its receiver and arguments, so the deepest
	// environment is created and reports "Stack overflow" at its first call, with its leave position still
	// at the file start.
	static inline function checkStackDepth(ctx:EvalContext):Void {
		var env = EvalContext.getEval(ctx).env;
		if (env != null && env.stackDepth > ctx.maxStackDepth) EvalExceptions.excString(ctx, "Stack overflow");
	}

	static function evalCall(ctx:EvalContext, callee:TExpr, argExprs:Array<TExpr>, p:Position):EvalValue {
		switch (callee.expr) {
			case TField(_, FEnum(en, ef)):
				// An enum value remembers where it was constructed. A reified type hint is such a value
				// (with a zero-width position), and decoding it as a complex type reports on it.
				var args = [for (a in argExprs) eval(ctx, a)];
				return VEnumValue(new VEnumValue(ef.index, args, EvalHash.pathHash(en.path), p));
			case TIdent("$__mk_pos__"):
				// Reification's position builtin: build a position value from (file, min, max) - an IPos
				// instance, which prints as `#pos(file:line: characters a-b)` - not the {file, min, max} object
				// the reification wrote, so a reified expression thrown out of a macro prints the position.
				return EvalMacro.mkPosValue([for (x in argExprs) eval(ctx, x)]);
			case TConst(TSuper):
				// Super() checks the depth first; a native-backed parent's special super call records no leave
				// position, an interpreted parent's is recorded after the arguments (callAt).
				checkStackDepth(ctx);
				var args = [for (a in argExprs) eval(ctx, a)];
				var vthis = EvalContext.getEval(ctx).env.vthis;
				switch (TypeFunctions.follow(callee.type)) {
					case TInst(c, _):
						var key = EvalHash.pathHash(c.path);
						// A native-backed parent (BytesInput, ...) constructs through a builtin that
						// returns its own instance; the subclass's this delegates its native state to it.
						var cb = ctx.builtins.constructorBuiltins.get(key);
						if (cb != null) {
							switch [vthis, cb(args)] {
								case [VInstance(vt), VInstance(built)]: EvalStdLib.superDelegates.set(vt, built);
								case _:
							}
						} else {
							var ctor = ctx.constructors.get(key);
							if (ctor == null && c.constructor != null) {
								// Same lazy-registration gap as constructClass: the parent's
								// proto may predate its typed bodies.
								forceInWorld(ctx, c);
								var made = hxc.eval.EvalPrototype.makeConstructor(ctx, c);
								if (made != null) { ctx.constructors.set(key, made); ctor = made; }
							}
							if (ctor != null) callAt(ctx, p, ctor, [vthis].concat(args));
						}
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
					// A super field call: the depth check, the arguments, and the call with no leave position
					// recorded.
					checkStackDepth(ctx);
					var args = [for (a in argExprs) eval(ctx, a)];
					switch (m) {
						case VFunction(f, _): return f([vthis].concat(args));
						case _:
					}
				}
			case _:
		}
		switch (callee.expr) {
			// StringTools.fastCodeAt and unsafeCodeAt are intrinsics, not calls: no depth check, and the
			// environment's leave position stays where the last call left it. The string is decoded as a
			// string, the index as an Int at its position.
			case TField(_, FStatic(c, cf)) if (argExprs.length == 2 && c.path.pack.length == 0 && c.path.name == "StringTools" && (cf.name == "fastCodeAt" || cf.name == "unsafeCodeAt")):
				var s = EvalStdLib.decodeString(ctx, eval(ctx, argExprs[0]));
				var index = switch (eval(ctx, argExprs[1])) {
					case VInt(i): i;
					case VFloat(f): Std.int(f);
					case v: EvalExceptions.unexpectedValue(ctx, v, "int", p);
				};
				return EvalStdLib.stringFastCodeAt(s, index);
			case _:
		}
		checkStackDepth(ctx);
		// The emitter is picked by the callee: a proper method records the leave position after its
		// arguments, any other field and any other callee before them.
		var leaveFirst = switch (callee.expr) {
			case TField(_, FStatic(_, cf)): !isProperMethod(cf);
			case TField(_, FInstance(_, _, cf)): !isProperMethod(cf);
			case _: true;
		};
		var fn = switch (callee.expr) {
			// A field call on anything but a static or an enum constructor evaluates its receiver first and
			// null-checks it at the receiver's position, whatever kind of field the call then reads.
			case TField(e1, fa) if (!fa.match(FStatic(_, _) | FEnum(_, _))):
				var recv = eval(ctx, e1);
				if (recv == VNull) EvalExceptions.excString(ctx, "Null Access", e1.pos);
				EvalValueTools.vresolve(evalField(ctx, e1, fa, callee.pos, recv));
			case _: EvalValueTools.vresolve(eval(ctx, callee));
		};
		var caller = EvalContext.getEval(ctx);
		if (leaveFirst && caller.env != null) EvalExceptions.setLeavePosition(caller.env, p);
		var args = [for (a in argExprs) eval(ctx, a)];
		var isTrace = switch (callee.expr) {
			case TField(_, FStatic(c, cf)) if (c.path.pack.join(".") == "haxe" && c.path.name == "Log" && cf.name == "trace"): true;
			case _: false;
		};
		if (isEvalTarget(ctx) && isTrace && argExprs.length > 0 && isUIntExpr(argExprs[0]))
			args[0] = unsignedValue(args[0]);
		if (isEvalTarget(ctx) && isTrace && argExprs.length > 1)
			args[1] = normalizeTraceValue(argExprs[1], args[1]);
		return switch (fn) {
			case VFunction(f, _): leaveFirst ? f(args) : callAt(ctx, p, f, args);
			case VFieldClosure(recv, f): leaveFirst ? f([recv].concat(args)) : callAt(ctx, p, f, [recv].concat(args));
			// "Cannot call <value>", with no position of its own; the frame shows the call, which the
			// emitter records before any call.
			case v:
				var ev = EvalContext.getEval(ctx);
				if (ev.env != null) EvalExceptions.setLeavePosition(ev.env, p);
				EvalExceptions.excString(ctx, "Cannot call " + EvalStdLib.stringOf(v));
		};
	}

	static function normalizeTraceValue(e:TExpr, v:EvalValue):EvalValue {
		if (isUIntExpr(e)) return unsignedValue(v);
		return switch [e.expr, v] {
			case [TCast(inner, _) | TMeta(_, inner) | TParenthesis(inner), value]: normalizeTraceValue(inner, value);
			case [TArrayDecl(el), VArray(va)]:
				for (i in 0...el.length) if (i < va.avalues.length) va.avalues[i] = normalizeTraceValue(el[i], va.avalues[i]);
				v;
			case [TObjectDecl(fields), VObject(o)]:
				switch (o.oproto) {
					case ODictionary(m):
						for (field in fields) {
							var key = EvalHash.hash(field.key.name);
							if (m.exists(key)) m.set(key, normalizeTraceValue(field.expr, m.get(key)));
						}
					case _:
				}
				v;
			case _: v;
		};
	}

	// A proper method: a Method other than a dynamic one.
	static function isProperMethod(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Method(MethDynamic): false;
			case Method(_): true;
			case Var(_): false;
		};
	}

	static function callAt(ctx:EvalContext, p:Position, f:VFunc, args:Array<EvalValue>):EvalValue {
		// The environment records where it last left off, so a stack captured deeper in shows each frame at
		// its active call site rather than its function entry.
		var ev = EvalContext.getEval(ctx);
		if (ev.env != null) EvalExceptions.setLeavePosition(ev.env, p);
		return f(args);
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

	static var freeVarCache:haxe.ds.ObjectMap<TFunc, Array<Int>> = new haxe.ds.ObjectMap();

	// The variable ids a closure body reads from an ENCLOSING scope: the closure's capture set. hxc walks
	// the body and caches it, since a var id is unique per declaration.
	static function freeVarIds(tf:TFunc):Array<Int> {
		var cached = freeVarCache.get(tf);
		if (cached != null) return cached;
		var declared = new Map<Int, Bool>();
		var seen = new Map<Int, Bool>();
		var free:Array<Int> = [];
		for (a in tf.args) declared.set(a.v.id, true);
		function walk(e:TExpr):Void {
			switch (e.expr) {
				case TVarExpr(v, _): declared.set(v.id, true);
				case TFor(v, _, _): declared.set(v.id, true);
				case TTry(_, catches): for (c in catches) declared.set(c.v.id, true);
				case TFunction(f2): for (a in f2.args) declared.set(a.v.id, true);
				case TLocal(v):
					if (!declared.exists(v.id) && !seen.exists(v.id)) {
						seen.set(v.id, true);
						free.push(v.id);
					}
				case _:
			}
			hxc.core.TexprTools.iter(walk, e);
		}
		walk(tf.expr);
		freeVarCache.set(tf, free);
		return free;
	}

	// The captured values are read OUT of the enclosing env when the closure value is created, so each
	// closure keeps its own copy. A captured var that is ASSIGNED was array-boxed first by
	// CapturedVars, so the copy shares that box and mutation still propagates; a read-only capture is
	// snapshotted, which is what gives each iteration of a loop its own value. Chaining to the live
	// parent instead would make every closure built in a loop read the final slot.
	static function snapshotCaptures(tf:TFunc, captured:Null<EvalEnv>):Null<EvalEnv> {
		if (captured == null) return null;
		var ids = freeVarIds(tf);
		if (ids.length == 0) return captured;
		var snap = new EvalEnv(captured.info, [], [], captured.parent, captured.stackDepth, captured.eval);
		snap.vthis = captured.vthis;
		// Anything the walk did not account for still resolves along the real chain.
		snap.lexicalParent = captured;
		for (vid in ids) {
			var owner = findEnv(captured, vid);
			var os = owner.slots.get(vid);
			if (os == null) continue;
			snap.slots.set(vid, snap.locals.length);
			snap.locals.push(owner.locals[os]);
		}
		return snap;
	}

	// A closure captures its defining frame and runs its body in a child frame linked to it.
	static function makeClosure(ctx:EvalContext, tf:TFunc, captured:EvalEnv):VFunc {
		var snap = snapshotCaptures(tf, captured);
		return function(args:Array<EvalValue>):EvalValue {
			var env2 = EvalContext.pushEnvironment(ctx, EvalContext.createEnvInfo(true, tf.expr.pos, EKLocalFunction(0), 0, 0));
			env2.lexicalParent = snap;
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

	static function evalNew(ctx:EvalContext, c:TClass, params:TParams, args:Array<EvalValue>, p:Position, ?argPos:Position):EvalValue {
		switch (c.kind) {
			case KAbstractImpl(a) if (TypeFunctions.hasMeta(":multiType", a.meta)):
				var concrete:Null<T> = try hxc.typing.Typer.resolveMultiTypeConcrete(a, params, p) catch (_:Dynamic) null;
				switch (concrete == null ? null : TypeFunctions.follow(concrete)) {
					case TInst(tc, ctl): return evalNew(ctx, tc, ctl, args, p);
					case _:
						// A generic body can retain an open selector even after its concrete
						// instance is emitted. The value is available now, so select the same
						// @:to constructor by its argument shape.
						for (entry in a.toField) {
							var ft = TypeFunctions.applyParams(a.params, params, entry.cf.type);
								switch (TypeFunctions.follow(ft)) {
								case TFun(sig) if (sig.args.length == args.length + 1):
									var ok = true;
					for (i in 0...args.length) {
										var matched = try runtimeTypeMatches(sig.args[i + 1].t, args[i]) catch (err:Dynamic) {
											false;
										};
										if (!matched) ok = false;
									}
									if (ok) switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, params, entry.t))) {
										case TInst(tc, ctl): return evalNew(ctx, tc, ctl, args, p);
										case _:
									}
								case _:
							}
						}
				}
			case _:
		}
		var key = EvalHash.pathHash(c.path);
		var special = ctx.builtins.constructorBuiltins.get(key);
		if (special != null) {
			var ev = EvalContext.getEval(ctx);
			var oldPos = ev.currentPos;
			if (argPos != null) ev.currentPos = argPos;
			var result:EvalValue;
			// A native constructor records no leave position.
			try result = special(args) catch (ex:Dynamic) { ev.currentPos = oldPos; throw ex; }
			ev.currentPos = oldPos;
			return result;
		}
		return constructClass(ctx, c, key, args, p);
	}

	static function runtimeTypeMatches(t:T, v:EvalValue):Bool return runtimeTypeMatchesDepth(t, v, 0);

	static function runtimeTypeMatchesDepth(t:T, v:EvalValue, depth:Int):Bool {
		if (depth > 8) return true;
		return switch (TypeFunctions.follow(t)) {
			case TDynamic(_): true;
			case TMono(_): true;
			case TType(td, tl): runtimeTypeMatchesDepth(TypeFunctions.applyParams(td.params, tl, td.type), v, depth + 1);
			case TAbstract(a, tl):
				switch (a.path.name) {
					case "Int": switch (v) { case VInt(_): true; case _: false; }
					case "Float": switch (v) { case VFloat(_) | VInt(_): true; case _: false; }
					case "String": switch (v) { case VString(_) | VNativeString(_): true; case _: false; }
					case "Bool": switch (v) { case VTrue | VFalse: true; case _: false; }
					case _: runtimeTypeMatchesDepth(TypeFunctions.applyParams(a.params, tl, a.thisType), v, depth + 1);
				}
			case TInst(c, _):
				switch (c.path.pack.join(".") + "." + c.path.name) {
					case "builtins.Int": switch (v) { case VInt(_): true; case _: false; }
					case "Float": switch (v) { case VFloat(_) | VInt(_): true; case _: false; }
					case "String": switch (v) { case VString(_) | VNativeString(_): true; case _: false; }
					case "Array": switch (v) { case VArray(_): true; case _: false; }
					case _: switch (v) { case VInstance(_): true; case VNull: true; case _: false; }
				}
			case TEnum(_, _): switch (v) { case VEnumValue(_): true; case _: false; }
			case _: true;
		};
	}

	// Force a class's field bodies in the WORLD it belongs to (a macro-world class's decl
	// lives in the macro Context; the host skips macro bodies).
	public static function forceInWorld(ctx:EvalContext, cls:TClass):Void {
		var initCom = ctx.com;
		var mw = hxc.eval.EvalMacro.macroWorld();
		if (mw != null && mw.moduleLut.get(hxc.context.Context.pathKey(cls.module.path)) == cls.module) initCom = mw;
		if (Sys.getEnv("HXC_DEBUG_INITS") != null) {
			var key = hxc.context.Context.pathKey(cls.path);
			Sys.println("[force] " + cls.path.name
				+ " world=" + (initCom == mw ? "macro" : "host")
				+ " decl=" + (initCom != null && initCom.declOfType.get(key) != null)
				+ " mwHasDecl=" + (mw != null && mw.declOfType.get(key) != null));
		}
		if (initCom != null) try hxc.typing.TypeFields.forceClassFields(initCom, cls) catch (_:Dynamic) {}
	}

	// Register a class reached only after the main prototype build pass (a macro dependency
	// constructed from an after-generate callback): super chain first, then instance/static
	// prototypes, static-init delays, and the constructor - the same recipe EvalMain.buildClass
	// applies during startup.
	static function registerLazyClass(ctx:EvalContext, c:TClass):Void {
		var key = EvalHash.pathHash(c.path);
		var haveInst = ctx.instancePrototypes.exists(key);
		var haveStat = ctx.staticPrototypes.exists(key);
		if (haveInst && haveStat) return;
		if (c.superClass != null) registerLazyClass(ctx, c.superClass.c);
		forceInWorld(ctx, c);
		if (!ctx.typeCache.exists(key)) ctx.typeCache.set(key, TClassDecl(c));
		if (!haveInst) {
			var iproto = hxc.eval.EvalPrototype.buildInstance(ctx, c);
			ctx.instancePrototypes.set(key, iproto);
			var ctor = hxc.eval.EvalPrototype.makeConstructor(ctx, c);
			if (ctor != null) ctx.constructors.set(key, ctor);
		}
		if (!haveStat) {
			var r = hxc.eval.EvalPrototype.buildStatic(ctx, c);
			ctx.staticPrototypes.set(r.proto.ppath, r.proto);
			for (d in r.delays) d(r.proto);
			if (r.nonPersistent.length > 0) ctx.staticInits.set(r.proto.ppath, {proto: r.proto, delays: r.nonPersistent});
		}
	}

	// Static prototype lookup that registers a lazily-reached class on demand.
	static function ensureStaticProto(ctx:EvalContext, c:TClass, p:Position):VPrototype {
		if (ctx.staticPrototypes.get(EvalHash.pathHash(c.path)) == null)
			try registerLazyClass(ctx, c) catch (_:Dynamic) {}
		return EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(c.path), p);
	}

	public static function constructClass(ctx:EvalContext, c:TClass, key:Int, args:Array<EvalValue>, p:Position):EvalValue {
		if (ctx.instancePrototypes.get(key) == null)
			try registerLazyClass(ctx, c) catch (e:Dynamic) {
				if (Sys.getEnv("HXC_DEBUG_INITS") != null) Sys.println("[lazy] register failed " + c.path.name + ": " + Std.string(e));
			}
		var proto = EvalContext.getInstancePrototype(ctx, key, p);
		var inst = new VInstance(proto.pinstanceFields.copy(), proto, INormal);
		var instVal = VInstance(inst);
		applyFieldInits(ctx, c, instVal);
		var ctor = ctx.constructors.get(key);
		if (ctor == null && c.constructor != null) {
			// A prototype registered before the class's bodies were typed has no constructor
			// entry (registerLazyClass skips a registered proto); force the class in its world
			// and build the constructor now, so e.g. a macro-world `new haxe.macro.Expr.Error`
			// runs its constructor and carries message and pos.
			forceInWorld(ctx, c);
			var made = hxc.eval.EvalPrototype.makeConstructor(ctx, c);
			if (made != null) { ctx.constructors.set(key, made); ctor = made; }
		}
		var cc = c;
		while (ctor == null && cc.superClass != null) {
			cc = cc.superClass.c;
			ctor = ctx.constructors.get(EvalHash.pathHash(cc.path));
		}
		if (ctor != null) callAt(ctx, p, ctor, [instVal].concat(args));
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
			// A lazily-reached macro-world class (a dependency constructed mid-callback) may
			// not have had its field initializers typed yet; expr == null would silently
			// skip them. Host-world classes are exempt: their initializers were moved into
			// the constructor by patchConstructors, and re-typing here would rebuild them
			// without the filter pipeline (inlining in particular).
			var mw = hxc.eval.EvalMacro.macroWorld();
			if (mw != null && cls.module != null && mw.moduleLut.get(hxc.context.Context.pathKey(cls.module.path)) == cls.module)
				forceInWorld(ctx, cls);
			for (cf in cls.orderedFields) {
				switch (cf.kind) {
					case Var(_) if (cf.expr != null):
						var env = EvalContext.pushEnvironment(ctx, EvalContext.createEnvInfo(false, cf.expr.pos, EKEntrypoint, 0, 0));
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
	public static function runBody(ctx:EvalContext, args:Array<{vid:Int, value:EvalValue}>, body:TExpr, ?vthis:EvalValue, ?info:EvalEnvInfo):EvalValue {
		if (info == null) info = EvalContext.createEnvInfo(vthis == null, body.pos, EKEntrypoint, 0, 0);
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
