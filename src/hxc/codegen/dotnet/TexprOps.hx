package hxc.codegen.dotnet;

import hxc.ast.Ast;
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
import hxc.codegen.dotnet.TexprToIl.constInt;
import hxc.codegen.dotnet.TexprToIl.is64;
import hxc.codegen.dotnet.TexprToIl.isExtern;
import hxc.codegen.dotnet.TexprToIl.isIntLike;
import hxc.codegen.dotnet.TexprToIl.isNullConst;
import hxc.codegen.dotnet.TexprToIl.isNumeric;
import hxc.codegen.dotnet.TexprToIl.isReference;
import hxc.codegen.dotnet.TexprToIl.isStringClass;
import hxc.codegen.dotnet.TexprToIl.isTypeParam;
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.strip;

private enum TypeOperand {
	OStatics;
	OValue;
	ONull;
}

// The operators of TexprToIl: arithmetic, comparison, boolean conditions, increments and compound
// assignment, and string concatenation. Shares its state through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprFlow, hxc.codegen.dotnet.TexprCalls, hxc.codegen.dotnet.TexprDynamic)
class TexprOps {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	function binary(ret:Ret, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):Void {
		// An operator with a Dynamic operand goes through haxe.lang.Runtime.
		if (tl.dyn.binop(ret, e, op, e1, e2)) return;
		switch (op) {
			case OpBoolAnd | OpBoolOr:
				boolValue(ret, e);
			case OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte:
				compare(ret, op, e1, e2);
			case OpAdd if (tl.sig(e.type).match(LString)):
				pushString(e1);
				pushString(e2);
				concat();
				tl.coerce(LString, ret);
			case OpAnd | OpOr | OpXor if (netEnum(tl.sig(e1.type)) && IlPaths.sigEq(tl.sig(e1.type), tl.sig(e2.type))):
				// cs.Flags's operators, C#'s on a .NET enum: the underlying integer's, typed as the enum.
				var s = tl.sig(e1.type);
				tl.texpr(RValue(s), e1);
				tl.texpr(RValue(s), e2);
				arith(op, s);
				tl.coerce(s, ret);
			case OpAdd | OpSub | OpMult | OpDiv | OpMod if (isSingle(e1) || isSingle(e2)):
				singleBinary(ret, e, op, e1, e2);
			case OpAdd | OpSub | OpMult | OpDiv | OpMod | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr:
				var s1 = tl.operandSig(op, e1), s2 = tl.operandSig(op, e2);
				if (is64(s1) || is64(s2)) {
					wideBinary(ret, e, op, e1, e2, s1, s2);
					return;
				}
				// A Null<T> result is computed in T and wrapped again, as HardNullableSynf does.
				var own = tl.sig(e.type);
				var t = tl.unNull(own);
				// The value of a small integer's `op=` whose right side holds a try (TexprFlow.spillForTry).
				if (isNarrow(own)) {
					tl.texpr(RValue(LInt32), e1);
					narrowTail(op, own, e2);
					tl.coerce(own, ret);
					return;
				}
				// Bitwise operators and shifts take Int operands only.
				if (!isArith(op) && !(isIntLike(s1) && isIntLike(s2) && isIntLike(t)))
					throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
				// `+` is the operator HardNullableSynf unwraps itself; the others gencs casts first.
				var add = op.match(OpAdd);
				tl.nullOperand(RValue(t), e1, add);
				numericTail(op, t, e2, s1, true, add);
				tl.dyn.finish(t, own, ret);
			case _:
				throw new Unsupported("the " + Ast.sBinop(op) + " operator", false);
		}
	}

	static function isArith(op:Binop):Bool return op.match(OpAdd | OpSub | OpMult | OpDiv | OpMod);

	// A Single operand (a Null<Single>'s value).
	function isSingle(e:TExpr):Bool {
		var s = try tl.sig(e.type) catch (_:Unsupported) null;
		return s != null && tl.unNull(s).match(LFloat32);
	}

	// An arithmetic operator with a Single operand, as C# binds it: in Double with a Float operand, else
	// in Single; the result then goes to the expression's type.
	function singleBinary(ret:Ret, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):Void {
		var s1 = tl.unNull(tl.sig(e1.type)), s2 = tl.unNull(tl.sig(e2.type));
		if (!(isNumeric(s1) || s1.match(LFloat32)) || !(isNumeric(s2) || s2.match(LFloat32)))
			throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		var t = s1.match(LFloat64) || s2.match(LFloat64) ? LFloat64 : LFloat32;
		var add = op.match(OpAdd);
		tl.nullOperand(RValue(s1), e1, add);
		tl.convert(s1, t);
		tl.nullOperand(RValue(s2), e2, add);
		tl.convert(s2, t);
		arith(op, t);
		switch (ret) {
			case RValue(null): tl.convert(t, tl.sig(e.type));
			case _: tl.coerce(t, ret);
		}
	}

	// Whether `s` is a .NET enum, whose values are its underlying integer on the stack.
	function netEnum(s:IlSigNorm):Bool {
		return switch (s) {
			case LValueType(p, []): g.externs.enumUnderlying(p) != null;
			case _: false;
		}
	}

	// The token of the public instance Equals(S) that the non-generic Haxe @:struct class at `p` declares, or 0.
	function haxeSelfEquals(s:IlSigNorm, p:IlPath):Int {
		var c = g.classAt(p);
		if (c == null || TypeFunctions.hasClassFlag(c, CExtern)) return 0;
		var cf = c.fields.get("Equals");
		if (cf == null) return 0;
		for (f in [cf].concat(cf.overloads)) {
			var plan = g.ownerOf.get(f), m = g.methodPlans.get(f);
			if (plan == null || m == null || plan.classParams.length > 0 || !TypeFunctions.hasClassFieldFlag(f, CfPublic) || TypeFunctions.hasClassFieldFlag(f, CfStatic)) continue;
			if (m.name == "Equals" && m.hasThis && m.args.length == 1 && IlPaths.sigEq(m.args[0], s) && m.ret.match(LBool)) return g.memberOf(plan, plan.thisSig, f);
		}
		return 0;
	}

	// `e` is a struct of type `s`; pushes whether it equals default(s), as gencs's `e.Equals(default(S))` is
	// bound: to the struct's own public Equals(S) when it declares one, else to Object.Equals. With the null
	// first, gencs's receiver is default(S) and `e` the argument.
	function structIsDefault(s:IlSigNorm, e:TExpr, nullFirst:Bool):Void {
		tl.texpr(RValue(s), e);
		var tmp = code.addLocal(s);
		code.stloc(tmp);
		var token = switch (s) {
			case LValueType(p, []): g.externs.declaresSelfEquals(p) ? g.mb.memberRef(g.typeTokenOf(s), "Equals", g.sigs.method(true, LBool, [s], 0)) : haxeSelfEquals(s, p);
			case _: 0;
		}
		if (token != 0) {
			var zero = code.addLocal(s);
			code.ldloca(zero);
			code.opToken(IlOps.INITOBJ, g.typeTokenOf(s), 1, 0);
			code.ldloca(nullFirst ? zero : tmp);
			if (nullFirst) code.ldloc(tmp) else code.ldloc(zero);
			code.opToken(IlOps.CALL, token, 2, 1);
			return;
		}
		if (nullFirst) {
			tl.defaultValue(s);
			code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
			code.ldloc(tmp);
			code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
		} else {
			code.ldloc(tmp);
			code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
			tl.defaultValue(s);
			code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
		}
		code.opToken(IlOps.CALLVIRT, g.mb.memberRef(g.typeTokenOf(LObject), "Equals", g.sigs.method(true, LBool, [LObject], 0)), 2, 1);
	}

	// C# promotes a UInt and an Int operand to long: their comparisons and remainder are a long's.
	static function mixesUIntAndInt(s1:IlSigNorm, s2:IlSigNorm):Bool {
		return isIntLike(s1) && isIntLike(s2) && !IlPaths.sigEq(s1, s2);
	}

	// The int32 on the stack, of type `s`, as a long.
	function widen(s:IlSigNorm):Void {
		code.op(s.match(LUInt32) ? IlOps.CONV_U8 : IlOps.CONV_I8, 1, 1);
	}

	// The type C# computes an operator on `s1` and `s2` in when one is an Int64 or UInt64: Float when
	// the other is a Float, else the 64-bit type, which an Int or UInt widens to; null for an Int64 with
	// a UInt64, which C# refuses.
	static function wideType(s1:IlSigNorm, s2:IlSigNorm):Null<IlSigNorm> {
		if (s1.match(LFloat64) || s2.match(LFloat64)) return LFloat64;
		if (s1.match(LUInt64) || s2.match(LUInt64)) return s1.match(LInt64) || s2.match(LInt64) ? null : LUInt64;
		return LInt64;
	}

	// The operand of type `s` on the stack as the operator's type `t` (wideType): an Int with a UInt64
	// zero-extends, as C# converts a constant.
	function widenTo(s:IlSigNorm, t:IlSigNorm):Void {
		if (IlPaths.sigEq(s, t)) return;
		if (isIntLike(s) && is64(t)) {
			if (t.match(LUInt64)) code.op(IlOps.CONV_U8, 1, 1) else widen(s);
		} else {
			tl.convert(s, t);
		}
	}

	// `op` with an Int64 or UInt64 operand, as C# binds it (wideType): `/` and `%` of two integers are
	// integer division and remainder whatever the expression's type, and a shift's count is an Int.
	function wideBinary(ret:Ret, e:TExpr, op:Binop, e1:TExpr, e2:TExpr, s1:IlSigNorm, s2:IlSigNorm):Void {
		var bad = new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		var shift = op.match(OpShl | OpShr | OpUShr);
		var t = shift ? s1 : wideType(s1, s2);
		if (t == null || shift && !is64(t) || !isArith(op) && t.match(LFloat64)) throw bad;
		var add = op.match(OpAdd);
		tl.nullOperand(RValue(s1), e1, add);
		widenTo(s1, t);
		if (shift) {
			shiftCount(e2, 63);
			code.op(op.match(OpShl) ? IlOps.SHL : op.match(OpShr) && t.match(LInt64) ? IlOps.SHR : IlOps.SHR_UN, 2, 1);
		} else {
			tl.nullOperand(RValue(s2), e2, add);
			widenTo(s2, t);
			arith(op, t);
		}
		// gencs's CastDetect types an operator other than `/` and the shifts on a UInt and another Int-like
		// operand (an Int64 or UInt64 too) as UInt: `((uint)((a + ui)))`. Otherwise the value keeps C#'s type
		// (a Float operation typed Int64 stays a Float) until its destination converts it.
		if (!shift && !op.match(OpDiv) && (s1.match(LUInt32) || s2.match(LUInt32))) {
			code.op(IlOps.CONV_U4, 1, 1);
			t = LUInt32;
		}
		switch (ret) {
			case RValue(null): tl.convert(t, tl.sig(e.type));
			case _: tl.coerce(t, ret);
		}
	}

	// Pushes a shift's count, an Int masked as C# does: to 31, or to 63 for a 64-bit value.
	function shiftCount(e2:TExpr, mask:Int):Void {
		var n = constInt(e2);
		if (n != null) {
			code.ldcI4(n & mask);
		} else {
			tl.texpr(RValue(LInt32), e2);
			code.ldcI4(mask);
			code.op(IlOps.AND, 2, 1);
		}
	}

	// Applies `op`, not a shift, to two operands of type `t` on the stack.
	function arith(op:Binop, t:IlSigNorm):Void {
		var unsigned = t.match(LUInt32 | LUInt64);
		code.op(switch (op) {
			case OpAdd: IlOps.ADD;
			case OpSub: IlOps.SUB;
			case OpMult: IlOps.MUL;
			case OpDiv: unsigned ? IlOps.DIV_UN : IlOps.DIV;
			case OpMod: unsigned ? IlOps.REM_UN : IlOps.REM;
			case OpAnd: IlOps.AND;
			case OpOr: IlOps.OR;
			case OpXor: IlOps.XOR;
			case _: throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		}, 2, 1);
	}

	// The left operand, of type `t` on the stack and `left` as typed, is there; this pushes the right
	// one and applies `op`. A compound assignment does not promote: gencs casts its right side to the
	// left's type, so the left type's own remainder applies.
	// `keepNull`: the right operand itself is one HardNullableSynf unwraps (TexprToIl.nullOperand);
	// otherwise only its Null<T> tails are.
	function numericTail(op:Binop, t:IlSigNorm, e2:TExpr, left:IlSigNorm, promote = true, keepNull = false):Void {
		var bad = new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		if (!isNumeric(t)) throw bad;
		if (!isArith(op) && !isIntLike(t) && !is64(t)) throw bad;
		var unsigned = t.match(LUInt32 | LUInt64);
		// Integer `/` reaches here only from a 64-bit compound assignment, which C# divides as integers.
		if (op.match(OpDiv) && !t.match(LFloat64) && !is64(t)) throw bad;
		var right = promote && op.match(OpMod) && isIntLike(t) ? tl.sig(e2.type) : null;
		if (right != null && mixesUIntAndInt(left, right)) {
			// gencs casts the long remainder back to the result type.
			widen(left);
			tl.texpr(RValue(right), e2);
			widen(right);
			code.op(IlOps.REM, 2, 1);
			code.op(IlOps.CONV_I4, 1, 1);
			return;
		}
		switch (op) {
			case OpShl | OpShr | OpUShr:
				shiftCount(e2, is64(t) ? 63 : 31);
				code.op(op.match(OpShl) ? IlOps.SHL : op.match(OpShr) && !unsigned ? IlOps.SHR : IlOps.SHR_UN, 2, 1);
			case _:
				tl.nullOperand(RValue(t), e2, keepNull);
				arith(op, t);
		}
	}

	// Single and the integers smaller than Int, whose values the stack holds as a float32 and an int32.
	static function isNarrow(s:IlSigNorm):Bool return s.match(LFloat32 | LChar | LInt8 | LUInt8 | LInt16 | LUInt16);

	// The left operand, of the narrow type `t`, is there; this pushes the right one and applies `op`, as C# binds the
	// `op=` gencs writes: the right side cast to `t`, except a shift's count, and the result truncated to `t`.
	function narrowTail(op:Binop, t:IlSigNorm, e2:TExpr):Void {
		var single = t.match(LFloat32);
		if (single && !isArith(op)) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		switch (op) {
			case OpShl | OpShr | OpUShr:
				shiftCount(e2, 31);
				code.op(op.match(OpShl) ? IlOps.SHL : op.match(OpShr) ? IlOps.SHR : IlOps.SHR_UN, 2, 1);
			case _:
				tl.nullOperand(RValue(t), e2, false);
				arith(op, t);
		}
		if (!single) tl.convert(LInt32, t);
	}

	function not():Void {
		code.ldcI4(0);
		code.op(IlOps.CEQ, 2, 1);
	}

	// haxe.lang.Runtime.undefined, the value `__hx_getField` gives for a missing field when asked to check.
	static function isUndefined(e:TExpr):Bool {
		return switch (strip(e).expr) {
			case TField(_, FStatic(c, cf)): cf.name == "undefined" && DotnetTypes.haxePath(TClassDecl(c)) == "cs.internal.Runtime";
			case TIdent("__undefined__"): true;
			case _: false;
		}
	}

	function compare(ret:Ret, op:Binop, e1:TExpr, e2:TExpr):Void {
		var equality = op.match(OpEq | OpNotEq);
		if (equality && typeEquality(ret, op, e1, e2)) return;
		var isFloat = false;
		// Two UInt operands compare unsigned; a UInt and an Int compare as longs, as in C#.
		var unsigned = false;
		var string = false;
		var netOperator = null;
		if (isNullConst(e1) || isNullConst(e2)) {
			if (!equality) throw new Unsupported("comparing null with the " + Ast.sBinop(op) + " operator", false);
			var other = isNullConst(e1) ? e2 : e1;
			if (isNullConst(other)) throw new Unsupported("comparing null with null", false);
			var s = tl.sig(other.type);
			if (tl.isHaxeNull(s)) {
				// `x == null` on a haxe.lang.Null<T> is `!x.hasValue`.
				tl.texpr(RValue(s), other);
				tl.loadNullField(s, "hasValue");
				if (op.match(OpEq)) not();
				tl.coerce(LBool, ret);
				return;
			}
			if (DotnetTypes.isSystemNullable(s)) {
				// `x == null` on a System.Nullable<T> is `!x.HasValue`, which is what gencs's Equals(default(T)) means.
				tl.texpr(RValue(s), other);
				var tmp = code.addLocal(s);
				code.stloc(tmp);
				code.ldloca(tmp);
				code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(s), "get_HasValue", g.sigs.method(true, LBool, [], 0)), 1, 1);
				if (op.match(OpEq)) not();
				tl.coerce(LBool, ret);
				return;
			}
			if (tl.isStruct(s)) {
				structIsDefault(s, other, isNullConst(e1));
				if (op.match(OpNotEq)) not();
				tl.coerce(LBool, ret);
				return;
			}
			if (netEnum(s) || TexprToIl.clrEnum(other.type) != null) {
				// A .NET or CLR enum against null, as cs.Flags's `has` compares: against default(T), as gencs writes it.
				tl.texpr(RValue(s), other);
				tl.defaultValue(s);
			} else {
				if (DotnetTypes.isValueType(s) || isTypeParam(s)) throw new Unsupported("comparing a value type with null", false);
				netOperator = equalityOperator(op, e1, e2);
				// The operand that is not null goes as its own type: a call of a generic method can return
				// another one, such as StringMap<object>.get's haxe.lang.Null<object> for a Null<Dynamic>.
				tl.texpr(RValue(netOperator != null ? netOperator.args[0] : isNullConst(e1) ? null : s), e1);
				tl.texpr(RValue(netOperator != null ? netOperator.args[1] : isNullConst(e2) ? null : s), e2);
			}
		} else {
			// Null<T> operands compare their values, as HardNullableSynf unwraps them; Char and the small
			// integers compare as Ints, as C# promotes them.
			inline function operand(e:TExpr) return switch (tl.unNull(tl.sig(e.type))) {
				case LChar | LInt8 | LUInt8 | LInt16 | LUInt16: LInt32;
				case s: s;
			}
			var s1 = operand(e1), s2 = operand(e2);
			var idx1 = TexprToIl.externEnumIndex(e1), idx2 = TexprToIl.externEnumIndex(e2);
			if (equality && (idx1 != null && constInt(e2) != null || idx2 != null && constInt(e1) != null)) {
				// enumIndex(x) == i on a .NET enum: x against the value of the constructor at i.
				var x = idx1 != null ? idx1 : idx2;
				tl.texpr(RValue(tl.sig(x.value.type)), x.value);
				tl.calls.externEnumLiteral(x.en, TexprToIl.enumFieldAt(x.en, idx1 != null ? constInt(e2) : constInt(e1)));
			} else if ((s1.match(LFloat32) || s2.match(LFloat32)) && (isNumeric(s1) || s1.match(LFloat32))
				&& (isNumeric(s2) || s2.match(LFloat32))) {
				// A Single operand, as C# binds it (singleBinary): in Double with a Float operand, else in Single.
				var t = s1.match(LFloat64) || s2.match(LFloat64) ? LFloat64 : LFloat32;
				isFloat = true;
				tl.nullOperand(RValue(s1), e1);
				tl.convert(s1, t);
				tl.nullOperand(RValue(s2), e2);
				tl.convert(s2, t);
			} else if (mixesUIntAndInt(s1, s2)) {
				tl.nullOperand(RValue(s1), e1);
				widen(s1);
				tl.nullOperand(RValue(s2), e2);
				widen(s2);
			} else if (isNumeric(s1) && isNumeric(s2) && (is64(s1) || is64(s2))) {
				// An Int64 or UInt64 against a number, as C# binds it.
				var t = wideType(s1, s2);
				if (t == null) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
				isFloat = t.match(LFloat64);
				unsigned = t.match(LUInt64);
				tl.nullOperand(RValue(s1), e1);
				widenTo(s1, t);
				tl.nullOperand(RValue(s2), e2);
				widenTo(s2, t);
			} else if (isNumeric(s1) && isNumeric(s2)) {
				var t = s1.match(LFloat64) || s2.match(LFloat64) ? LFloat64 : s1.match(LUInt32) || s2.match(LUInt32) ? LUInt32 : LInt32;
				isFloat = t.match(LFloat64);
				unsigned = t.match(LUInt32);
				tl.nullOperand(RValue(t), e1);
				tl.nullOperand(RValue(t), e2);
			} else if (equality && (TexprToIl.clrEnum(e1.type) != null && TexprToIl.clrEnum(e1.type) == TexprToIl.clrEnum(e2.type)
				|| TexprToIl.externEnum(e1.type) != null && TexprToIl.externEnum(e1.type) == TexprToIl.externEnum(e2.type)
				|| netEnum(s1) && IlPaths.sigEq(s1, s2))) {
				// Two values of one CLR enum compare as their indices, two of a .NET enum (cs.Flags's
				// EnumUnderlying<T> too) as their values.
				tl.texpr(RValue(s1), e1);
				tl.texpr(RValue(s2), e2);
			} else if (equality && s1.match(LValueType(_, _)) && IlPaths.sigEq(s1, s2) && TexprToIl.externEnum(e1.type) == null) {
				// Two .NET structs of one type, such as System.Decimal, through the operator C# binds.
				netOperator = equalityOperator(op, e1, e2);
				if (netOperator == null) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
				tl.texpr(RValue(netOperator.args[0]), e1);
				tl.texpr(RValue(netOperator.args[1]), e2);
			} else if (equality && s1.match(LIntPtr | LUIntPtr) && IlPaths.sigEq(s1, s2)) {
				// Two IntPtrs (UIntPtrs) compare as the native integers they are on the stack, as C# builds them in.
				tl.texpr(RValue(s1), e1);
				tl.texpr(RValue(s2), e2);
			} else if (equality && s1.match(LBool) && s2.match(LBool)) {
				tl.texpr(RValue(LBool), e1);
				tl.texpr(RValue(LBool), e2);
			} else if (equality && s1.match(LString) && s2.match(LString)) {
				string = true;
				tl.texpr(RValue(LString), e1);
				tl.texpr(RValue(LString), e2);
			} else if (equality && (isUndefined(e1) || isUndefined(e2))) {
				// gencs leaves a comparison with Runtime.undefined C#'s reference comparison.
				tl.texpr(RValue(LObject), e1);
				tl.texpr(RValue(LObject), e2);
			} else if (equality && arrayEquality(e1, e2)) {
				// Runtime.eq, which sees an Array and its #8314 forward as one array. An instantiation of
				// Array goes as itself, as in a comparison of references below.
				tl.texpr(RValue(g.isGenericHaxeClass(s1) ? s1 : null), e1);
				tl.texpr(RValue(g.isGenericHaxeClass(s2) ? s2 : null), e2);
				tl.dyn.runtimeCall("eq");
				if (op.match(OpNotEq)) not();
				tl.coerce(LBool, ret);
				return;
			} else if (equality && isReference(s1) && isReference(s2) && !s1.match(LObject) && !s2.match(LObject)) {
				netOperator = equalityOperator(op, e1, e2);
				// An instantiation of a generic Haxe class goes as itself, so a read of a place erased to object
				// (an Array<Array<Int>>'s element) is cast into it first, as gencs casts it. So does a Null<T> one, which a
				// generic call can give as a haxe.lang.Null<object> (StringMap<object>.get for a Map<String, E>).
				inline function as(s:IlSigNorm, e:TExpr, i:Int) return netOperator != null ? netOperator.args[i]
					: g.isGenericHaxeClass(s) || TypeFunctions.isExplicitNull(e.type) ? s : null;
				tl.texpr(RValue(as(s1, e1, 0)), e1);
				tl.texpr(RValue(as(s2, e2, 1)), e2);
			} else {
				throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
			}
		}
		if (netOperator != null) {
			code.opToken(IlOps.CALL, netOperator.token, 2, 1);
		} else if (string) {
			var eq = g.mb.memberRef(g.typeTokenOf(LString), "op_Equality", g.sigs.method(false, LBool, [LString, LString], 0));
			code.opToken(IlOps.CALL, eq, 2, 1);
			if (op.match(OpNotEq)) not();
		} else {
			switch (op) {
				case OpEq:
					code.op(IlOps.CEQ, 2, 1);
				case OpNotEq:
					code.op(IlOps.CEQ, 2, 1);
					not();
				case OpLt:
					code.compare(unsigned ? IlOps.CLT_UN : IlOps.CLT, isFloat);
				case OpGt:
					code.compare(unsigned ? IlOps.CGT_UN : IlOps.CGT, isFloat);
				case OpLte:
					// An unordered comparison is true on NaN, so inverting it makes <= false there.
					code.compare(isFloat || unsigned ? IlOps.CGT_UN : IlOps.CGT, isFloat);
					not();
				case _:
					code.compare(isFloat || unsigned ? IlOps.CLT_UN : IlOps.CLT, isFloat);
					not();
			}
		}
		tl.coerce(LBool, ret);
	}

	// Whether `==` or `!=` on `e1` and `e2` compares through Runtime.eq so that an Array and its #8314
	// forward are one array (casts notes §2.6): two Arrays, one of them an Array<Dynamic> (the companion
	// interface, which can hold either), or an Array`1<object> (an Array<Null<Int>>, Array<Any>, …), which
	// can forward, and an Array of a basic element (String or a value type), which can be a forward target;
	// gencs's C# can't compare those two (CS0019). Runtime.eq is a comparison of references when neither
	// forwards. An operand typed Dynamic or as a type parameter already goes through Runtime
	// (TexprDynamic.binop), whose eq and refEq resolve forwards too; other Arrays, such as two of one CLR
	// type, compare their references, as in gencs's C#.
	function arrayEquality(e1:TExpr, e2:TExpr):Bool {
		if (TexprCalls.arrayOf(e1.type) == null || TexprCalls.arrayOf(e2.type) == null) return false;
		if (g.types.isCompanionTyped(e1.type) || g.types.isCompanionTyped(e2.type)) return true;
		var a1 = arrayElement(e1), a2 = arrayElement(e2);
		inline function basic(s:IlSigNorm) return s.match(LString) || DotnetTypes.isValueType(s);
		return a1 != null && a2 != null && (a1.match(LObject) && basic(a2) || a2.match(LObject) && basic(a1));
	}

	// The element type of the CLR instantiation of Array an operand typed as one has, or null.
	function arrayElement(e:TExpr):Null<IlSigNorm> {
		return switch (tl.unNull(tl.sig(e.type))) {
			case LClass(_, [s]): s;
			case _: null;
		}
	}

	// What an operand of `==` on types is: a type expression, whose type is its statics; a Class<T> or
	// Enum<T> value; the null constant; or null for anything else.
	static function typeOperand(e:TExpr):Null<TypeOperand> {
		if (isNullConst(e)) return ONull;
		return switch (TypeFunctions.follow(e.type)) {
			case TAnon(a) if (a.status.get().match(Statics(_) | EnumStatics(_))): OStatics;
			case TAbstract(a, [_]) if (a.path.pack.length == 0 && (a.path.name == "Class" || a.path.name == "Enum")): OValue;
			case _: null;
		}
	}

	// typeOperand, where a System.Type is a Class value too: gencs compares two of them with typeEq outside
	// haxe.lang.Runtime, as hxcs's Std.isOfType compares a GenericInterface's type with `==` (probe
	// t7probe/teq).
	function equalityTypeOperand(e:TExpr):Null<TypeOperand> {
		var k = typeOperand(e);
		if (k == null && !tl.inRuntimeClass()) switch (TypeFunctions.follow(e.type)) {
			// Only an extern can be System.Type, so no Haxe class operand gets a sig (and a checkKept) here.
			case TInst(c, []) if (TypeFunctions.hasClassFlag(c, CExtern) && IlPaths.sigEq(tl.sig(e.type), TexprCalls.systemType)):
				return OValue;
			case _:
		}
		return k;
	}

	// `==` or `!=` on Class, Enum or System.Type values, as gencs writes it: Runtime.refEq when an operand is
	// a type expression (DynamicOperators takes those), else Runtime.typeEq, against null too. False when
	// an operand is not one of these.
	function typeEquality(ret:Ret, op:Binop, e1:TExpr, e2:TExpr):Bool {
		var k1 = equalityTypeOperand(e1), k2 = equalityTypeOperand(e2);
		if (k1 == null || k2 == null || k1 == ONull && k2 == ONull) return false;
		var ref = k1 == OStatics || k2 == OStatics;
		var s = ref ? LObject : TexprCalls.systemType;
		tl.texpr(RValue(s), e1);
		tl.texpr(RValue(s), e2);
		tl.dyn.runtimeCall(ref ? "refEq" : "typeEq");
		if (op.match(OpNotEq)) not();
		tl.coerce(LBool, ret);
		return true;
	}

	// Whether a switch case's value compares with a Class or Enum subject as `==` on types does
	// (typeEquality): a type expression, or a Class or Enum value.
	static function isTypeCase(v:TExpr):Bool {
		var k = typeOperand(v);
		return k != null && k != ONull;
	}

	// With a Class or Enum subject on the stack, as a System.Type, pushes whether the case's value
	// (isTypeCase) equals it, as typeEquality compares.
	function typeCase(v:TExpr):Void {
		var ref = typeOperand(v) == OStatics;
		tl.texpr(RValue(ref ? LObject : TexprCalls.systemType), v);
		tl.dyn.runtimeCall(ref ? "refEq" : "typeEq");
	}

	// The .NET class whose operators C# looks up for a value of type `t`: its own, or for a Haxe class
	// its nearest .NET superclass's.
	function netClassOf(t:T):Null<TClass> {
		var c = switch (TypeFunctions.follow(t)) {
			case TInst(c, _): c;
			case _: null;
		}
		while (c != null && !isExtern(c)) c = c.superClass == null ? null : c.superClass.c;
		return c;
	}

	// The op_Equality or op_Inequality C# binds `==` or `!=` on two references to, or null when neither
	// operand's .NET class declares one and the comparison is of references.
	function equalityOperator(op:Binop, e1:TExpr, e2:TExpr):Null<{token:Int, args:Array<IlSigNorm>}> {
		var name = op.match(OpEq) ? "op_Equality" : "op_Inequality";
		var candidates = [];
		for (e in [e1, e2]) {
			if (isNullConst(e)) continue;
			var c = netClassOf(e.type);
			if (c == null || isStringClass(c)) continue;
			for (o in g.externs.operators(c, name)) {
				var seen = false;
				for (k in candidates) if (IlPaths.sigEq(k.parent, o.parent) && IlPaths.sigsEq(k.args, o.args)) seen = true;
				if (!seen) candidates.push(o);
			}
		}
		if (candidates.length == 0) return null;
		function accepts(param:IlSigNorm, e:TExpr):Bool {
			if (isNullConst(e)) return isReference(param);
			var s = tl.sig(e.type);
			return IlPaths.sigEq(s, param) || g.isUpcast(s, param);
		}
		var applicable = [for (o in candidates) if (o.args.length == 2 && accepts(o.args[0], e1) && accepts(o.args[1], e2)) o];
		// C# would pick the best of several by its overload rules, which are not ported.
		if (applicable.length != 1) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these .NET types", false);
		var o = applicable[0];
		var ret = switch (o.sig) {
			case LMethod(_, r, _): r;
			case _: throw "internal error: not a method signature";
		}
		if (!ret.match(LBool)) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these .NET types", false);
		return {token: g.mb.memberRef(g.typeTokenOf(o.parent), name, g.sigs.methodSig(o.sig, 0)), args: o.args};
	}

	// Jumps to `l` when the condition equals `sense`, else falls through.
	function jumpIf(e:TExpr, l:Label, sense:Bool):Void {
		if (!code.reachable()) return;
		switch (e.expr) {
			case TParenthesis(e1) | TMeta(_, e1):
				jumpIf(e1, l, sense);
			case TUnop(Not, _, e1):
				jumpIf(e1, l, !sense);
			case TBinop(OpBoolAnd, a, b) | TBinop(OpBoolOr, a, b):
				// `a && b` jumps on false when either is false; it jumps on true only when both are true.
				var isAnd = e.expr.match(TBinop(OpBoolAnd, _, _));
				if (isAnd != sense) {
					jumpIf(a, l, sense);
					jumpIf(b, l, sense);
				} else {
					var skip = code.newLabel();
					jumpIf(a, skip, !sense);
					jumpIf(b, l, sense);
					code.markIfUsed(skip);
				}
			case TConst(TBool(b)):
				if (b == sense) code.branch(IlOps.BR, l);
			case _:
				// A Dynamic converts through Runtime.toBool, as gencs casts a condition to Bool.
				tl.texpr(RValue(LBool), e);
				code.branch(sense ? IlOps.BRTRUE : IlOps.BRFALSE, l);
		}
	}

	// `&&` and `||` as a value.
	function boolValue(ret:Ret, e:TExpr):Void {
		var f = code.newLabel(), end = code.newLabel();
		jumpIf(e, f, false);
		if (code.reachable()) {
			code.ldcI4(1);
			code.branch(IlOps.BR, end);
		}
		if (code.targeted(f)) {
			code.mark(f);
			code.ldcI4(0);
		}
		code.markIfUsed(end);
		tl.coerce(LBool, ret);
	}

	function unary(ret:Ret, e:TExpr, op:Unop, flag:UnopFlag, e1:TExpr):Void {
		if (op.match(Neg | NegBits) && tl.dyn.unary(ret, e, op, e1)) return;
		switch (op) {
			case Not:
				tl.nullOperand(RValue(LBool), e1, false);
				not();
				tl.coerce(LBool, ret);
			case Neg:
				var own = tl.sig(e.type);
				var t = tl.unNull(own);
				if (!isNumeric(t) && !t.match(LFloat32)) throw new Unsupported("the - operator on these types", false);
				tl.nullOperand(RValue(t), e1, false);
				code.op(IlOps.NEG, 1, 1);
				tl.dyn.finish(t, own, ret);
			case NegBits:
				var own = tl.sig(e.type);
				var t = tl.unNull(own);
				// On a .NET enum, cs.Flags's `~`: the underlying integer's, typed as the enum.
				if (!t.match(LInt32 | LInt64 | LUInt64) && !netEnum(t)) throw new Unsupported("the ~ operator on these types", false);
				tl.nullOperand(RValue(t), e1, false);
				code.op(IlOps.NOT, 1, 1);
				tl.dyn.finish(t, own, ret);
			case Increment | Decrement:
				incDec(ret, e, op.match(Increment), flag.match(Postfix), e1);
			case Spread:
				throw new Unsupported("the spread operator", false);
		}
	}

	function incDec(ret:Ret, e:TExpr, increment:Bool, postfix:Bool, e1:TExpr):Void {
		if (tl.dyn.incDec(ret, e, increment, postfix, e1)) return;
		var p = tl.place(e1);
		if (p == null) throw new Unsupported("this kind of assignment", false);
		var narrow = isNarrow(p.sig);
		if (!isNumeric(p.sig) && !narrow) throw new Unsupported("the " + (increment ? "++" : "--") + " operator on these types", false);
		function step() {
			if (p.sig.match(LFloat32)) {
				code.opR4(IlOps.LDC_R4, 1.0, 0, 1);
			} else if (isIntLike(p.sig) || narrow) {
				code.ldcI4(1);
			} else if (is64(p.sig)) {
				code.ldcI4(1);
				code.op(IlOps.CONV_I8, 1, 1);
			} else {
				code.opR8(IlOps.LDC_R8, 1.0, 0, 1);
			}
			code.op(increment ? IlOps.ADD : IlOps.SUB, 2, 1);
			if (narrow && !p.sig.match(LFloat32)) tl.convert(LInt32, p.sig);
		}
		p.prepare();
		p.load();
		if (!needVal(ret)) {
			step();
			p.store();
			return;
		}
		var tmp = -1;
		if (postfix) {
			tmp = keep(p);
			step();
			p.store();
		} else {
			step();
			tmp = keep(p);
			p.store();
		}
		if (tmp >= 0) code.ldloc(tmp);
		tl.coerce(p.sig, ret);
	}

	// Copies the value on top for after the place's store: it stays under the value, or goes to a temp
	// when the receiver is under it.
	function keep(p:Place):Int {
		if (!p.receiver) {
			code.op(IlOps.DUP, 1, 2);
			return -1;
		}
		return keepTop(p.sig);
	}

	function keepTop(s:IlSigNorm):Int {
		code.op(IlOps.DUP, 1, 2);
		var tmp = code.addLocal(s);
		code.stloc(tmp);
		return tmp;
	}

	function compound(ret:Ret, e:TExpr, op:Binop, lhs:TExpr, rhs:TExpr):Void {
		if (tl.dyn.compound(ret, e, op, lhs, rhs)) return;
		var p = tl.place(lhs);
		if (p == null) throw new Unsupported("this kind of assignment", false);
		p.prepare();
		p.load();
		if (op.match(OpAdd) && p.sig.match(LString)) {
			stringifyTop(LString);
			pushString(rhs);
			concat();
		} else if (isNarrow(p.sig)) {
			narrowTail(op, p.sig, rhs);
		} else {
			numericTail(op, p.sig, rhs, p.sig, false);
		}
		var tmp = needVal(ret) ? keep(p) : -1;
		p.store();
		if (needVal(ret)) {
			if (tmp >= 0) code.ldloc(tmp);
			tl.coerce(p.sig, ret);
		}
	}

	// `+` on Strings: String.Concat over operands that cannot be null.
	function concat():Void {
		var token = g.mb.memberRef(g.typeTokenOf(LString), "Concat", g.sigs.method(false, LString, [LString, LString], 0));
		code.opToken(IlOps.CALL, token, 2, 1);
	}

	// Pushes the operand of a String concatenation as a String; null becomes "null", as Runtime.toString
	// writes it.
	function pushString(e:TExpr):Void {
		var inner = strip(e);
		switch (inner.expr) {
			case TConst(TString(_)):
				tl.texpr(RValue(LString), inner);
				return;
			case TConst(TNull):
				code.opToken(IlOps.LDSTR, g.mb.userString("null"), 0, 1);
				return;
			case TBinop(OpAdd, _, _) if (tl.sig(inner.type).match(LString)):
				// A concatenation is never null.
				tl.texpr(RValue(LString), inner);
				return;
			case _:
		}
		var s = tl.sig(e.type);
		if (tl.isHaxeNull(s)) {
			// A Null<T> through toDynamic(), so an empty one prints null.
			tl.nullOperand(RValue(LObject), e);
			tl.dyn.stdString();
			return;
		}
		if (EnumToIl.enumOfType(e.type) != null) {
			// An enum value through Std.string, as gencs writes it.
			tl.texpr(RValue(LObject), e);
			tl.dyn.stdString();
			return;
		}
		stringKind(s);
		tl.texpr(RValue(s), e);
		stringifyTop(s);
	}

	// Throws for the types a String conversion does not handle yet.
	static function stringKind(s:IlSigNorm):Void {
		switch (s) {
			case LObject | LTypeParam(_) | LMethodTypeParam(_):
			case LString | LBool | LClass(_, _) | LVector(_) | LArray(_, _):
			case _ if (DotnetTypes.isValueType(s)):
			case _:
				throw new Unsupported("this type in string concatenation", false);
		}
	}

	// The value of type `s` on the stack becomes a String.
	function stringifyTop(s:IlSigNorm):Void {
		stringKind(s);
		function nullText() code.opToken(IlOps.LDSTR, g.mb.userString("null"), 0, 1);
		switch (s) {
			case LObject:
				// Std.string, as gencs writes a Dynamic in a concatenation.
				tl.dyn.stdString();
			case LTypeParam(_) | LMethodTypeParam(_):
				code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
				tl.dyn.stdString();
			case LString:
				var notNull = code.newLabel();
				code.op(IlOps.DUP, 1, 2);
				code.branch(IlOps.BRTRUE, notNull);
				code.op(IlOps.POP, 1, 0);
				nullText();
				code.mark(notNull);
			case LBool:
				var isTrue = code.newLabel(), end = code.newLabel();
				code.branch(IlOps.BRTRUE, isTrue);
				code.opToken(IlOps.LDSTR, g.mb.userString("false"), 0, 1);
				code.branch(IlOps.BR, end);
				code.mark(isTrue);
				code.opToken(IlOps.LDSTR, g.mb.userString("true"), 0, 1);
				code.mark(end);
			case _ if (DotnetTypes.isSystemNullable(s)):
				// Through its box, which is null or the T, as Std.string sees a Nullable<T> in gencs: an empty one
				// prints null.
				code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
				tl.dyn.stdString();
			case _ if (DotnetTypes.isValueType(s)):
				code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
				objectToString();
			case _:
				var notNull = code.newLabel(), end = code.newLabel();
				code.op(IlOps.DUP, 1, 2);
				code.branch(IlOps.BRTRUE, notNull);
				code.op(IlOps.POP, 1, 0);
				nullText();
				code.branch(IlOps.BR, end);
				code.mark(notNull);
				objectToString();
				code.mark(end);
		}
	}

	function objectToString():Void {
		var token = g.mb.memberRef(g.typeTokenOf(LObject), "ToString", g.sigs.method(true, LString, [], 0));
		code.opToken(IlOps.CALLVIRT, token, 1, 1);
	}
}
