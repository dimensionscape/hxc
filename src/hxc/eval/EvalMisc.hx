package hxc.eval;

import hxc.ast.Position;
import hxc.eval.EvalValue;
import hxc.eval.EvalValue.EvalValueTools.equals;
import hxc.eval.EvalValue.EvalValueTools.vbool;
import hxc.eval.EvalContext;
import hxc.eval.EvalExceptions;

class EvalMisc {
	public static inline function fcmp(a:Float, b:Float):Cmp {
		return a == b ? CEq : (a < b ? CInf : (a > b ? CSup : CUndef));
	}

	public static inline function icmp(a:Int, b:Int):Cmp {
		return a == b ? CEq : (a < b ? CInf : CSup);
	}

	public static function compare(a:EvalValue, b:EvalValue):Cmp {
		return switch [a, b] {
			case [VNull, VNull]: CEq;
			case [VInt(x), VInt(y)]: icmp(x, y);
			case [VFloat(x), VFloat(y)]: fcmp(x, y);
			case [VFloat(x), VInt(y)]: fcmp(x, y);
			case [VInt(x), VFloat(y)]: fcmp(x, y);
			case [VTrue, VTrue] | [VFalse, VFalse]: CEq;
			case [VFalse, VTrue]: CInf;
			case [VTrue, VFalse]: CSup;
			// Strings compare by their bytes.
			case [VString(s1), VString(s2)]:
				switch (hxc.eval.EvalString.ByteString.compare(s1.sstring, s2.sstring)) {
					case 0: CEq;
					case n if (n < 0): CInf;
					case _: CSup;
				}
			case [VFunction(f1, _), VFunction(f2, _)]: Reflect.compareMethods(f1, f2) ? CEq : CUndef;
			case [VArray(x), VArray(y)]: x == y ? CEq : CUndef;
			case [VVector(x), VVector(y)]: x == y ? CEq : CUndef;
			case [VObject(x), VObject(y)]: x == y ? CEq : CUndef;
			case [VInstance(x), VInstance(y)]: x == y ? CEq : CUndef;
			case [VPrototype(x), VPrototype(y)]: x == y ? CEq : CUndef;
			case [VEnumValue(x), VEnumValue(y)]:
				if (x == y) CEq;
				else if (x.eindex < y.eindex) CInf;
				else if (x.eindex > y.eindex) CSup;
				else if (x.epath != y.epath) CUndef;
				else if (x.eargs.length == 0 && y.eargs.length == 0) CEq;
				else CUndef;
			case [VFieldClosure(v1, f1), VFieldClosure(v2, f2)]: Reflect.compareMethods(f1, f2) ? compare(v1, v2) : CUndef;
			case [VLazy(f), _]: compare(f(), b);
			case [_, VLazy(f)]: compare(a, f());
			case _: CUndef;
		};
	}

	public static inline function isTrue(v:EvalValue):Bool {
		return switch (v) {
			case VTrue: true;
			case _: false;
		};
	}

	public static function opAdd(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: VInt(a + b);
			case [VFloat(a), VFloat(b)]: VFloat(a + b);
			case [VInt(a), VFloat(b)]: VFloat(a + b);
			case [VFloat(a), VInt(b)]: VFloat(a + b);
			// Two native strings concatenate as bytes; a string concatenates its bytes and lengths with the
			// other side printed (sValue), a native string there included.
			case [VNativeString(a), VNativeString(b)]: VNativeString(a + b);
			case [VString(a), VString(b)]: VString(hxc.eval.EvalString.EvalString.concat(a, b));
			case [VString(a), b]: VString(hxc.eval.EvalString.EvalString.concat(a, EvalStdLib.sValue(b, 0)));
			case [a, VString(b)]: VString(hxc.eval.EvalString.EvalString.concat(EvalStdLib.sValue(a, 0), b));
			// The operands print with the operator, at the operation.
			case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " + ", ""], [v1, v2], p);
		};
	}

	public static function opSub(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: VInt(a - b);
			case [VFloat(a), VFloat(b)]: VFloat(a - b);
			case [VInt(a), VFloat(b)]: VFloat(a - b);
			case [VFloat(a), VInt(b)]: VFloat(a - b);
			case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " - ", ""], [v1, v2], p);
		};
	}

	public static function opMult(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: VInt(a * b);
			case [VFloat(a), VFloat(b)]: VFloat(a * b);
			case [VInt(a), VFloat(b)]: VFloat(a * b);
			case [VFloat(a), VInt(b)]: VFloat(a * b);
			case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " * ", ""], [v1, v2], p);
		};
	}

	public static function opDiv(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: VFloat((a : Float) / b);
			case [VFloat(a), VFloat(b)]: VFloat(a / b);
			case [VInt(a), VFloat(b)]: VFloat(a / b);
			case [VFloat(a), VInt(b)]: VFloat(a / b);
			case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " / ", ""], [v1, v2], p);
		};
	}

	public static function opMod(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] {
			// An Int remainder by zero is the interpreter's fixed NaN, and the minimum Int % -1 is 0 (a C++
			// `%`
			// there traps).
			case [VInt(a), VInt(b)]: b == 0 ? VFloat(EvalStdLib.hostNan) : b == -1 ? VInt(0) : VInt(a % b);
			case [VFloat(a), VFloat(b)]: VFloat(a % b);
			case [VInt(a), VFloat(b)]: VFloat(a % b);
			case [VFloat(a), VInt(b)]: VFloat(a % b);
			case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " % ", ""], [v1, v2], p);
		};
	}

	public static inline function opEq(v1:EvalValue, v2:EvalValue):EvalValue return vbool(equals(v1, v2));
	public static inline function opNotEq(v1:EvalValue, v2:EvalValue):EvalValue return vbool(!equals(v1, v2));
	public static inline function opGt(v1:EvalValue, v2:EvalValue):EvalValue return vbool(compare(v1, v2) == CSup);
	public static inline function opLt(v1:EvalValue, v2:EvalValue):EvalValue return vbool(compare(v1, v2) == CInf);

	public static function opGte(v1:EvalValue, v2:EvalValue):EvalValue {
		return vbool(switch (compare(v1, v2)) { case CSup | CEq: true; case _: false; });
	}

	public static function opLte(v1:EvalValue, v2:EvalValue):EvalValue {
		return vbool(switch (compare(v1, v2)) { case CInf | CEq: true; case _: false; });
	}

	public static function opAnd(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] { case [VInt(a), VInt(b)]: VInt(a & b); case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " & ", ""], [v1, v2], p); };
	}

	public static function opOr(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] { case [VInt(a), VInt(b)]: VInt(a | b); case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " | ", ""], [v1, v2], p); };
	}

	public static function opXor(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] { case [VInt(a), VInt(b)]: VInt(a ^ b); case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " ^ ", ""], [v1, v2], p); };
	}

	public static function opShl(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] { case [VInt(a), VInt(b)]: VInt(a << (b & 31)); case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " << ", ""], [v1, v2], p); };
	}

	public static function opShr(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] { case [VInt(a), VInt(b)]: VInt(a >> (b & 31)); case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " >> ", ""], [v1, v2], p); };
	}

	public static function opUShr(ctx:EvalContext, p:Position, v1:EvalValue, v2:EvalValue):EvalValue {
		return switch [v1, v2] { case [VInt(a), VInt(b)]: VInt(a >>> (b & 31)); case _: EvalExceptions.excValues(ctx, ["Invalid operation: ", " >>> ", ""], [v1, v2], p); };
	}
}
