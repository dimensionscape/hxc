package hxc.eval;

import hxc.eval.EvalString.ByteString;
import hxc.eval.EvalString.EvalString;
import hxc.eval.EvalValue;

/**
	eval.integers.Int64 and UInt64 over the host's 64-bit integers. Both are stored as their 64 bits; the
	unsigned operations read them as unsigned.
**/
@:cppFileCode('
#include <stdio.h>

static int hxc_parse_digit(unsigned char c) {
	if (c >= 48 && c <= 57) return c - 48;
	if (c >= 65 && c <= 70) return c - 65 + 10;
	if (c >= 97 && c <= 102) return c - 97 + 10;
	return -1;
}

// Parse an optional sign and base prefix followed by digits. The unsigned form rejects a leading
// minus and accepts values through 2^64-1. Return 0 on failure.
static int hxc_parse64(const unsigned char *s, int len, int uonly, unsigned long long *out) {
	const unsigned char *p = s;
	const unsigned char *end = s + len;
	int sign = 1, base = 10, signedness = 1, d;
	unsigned long long res, threshold;
	if (p < end && *p == 45) { sign = -1; p++; }
	else if (p < end && *p == 43) p++;
	if (p < end && *p == 48 && p + 1 < end) {
		switch (p[1]) {
			case 120: case 88: base = 16; signedness = 0; p += 2; break;
			case 111: case 79: base = 8; signedness = 0; p += 2; break;
			case 98: case 66: base = 2; signedness = 0; p += 2; break;
			case 117: case 85: signedness = 0; p += 2; break;
		}
	}
	if (uonly && sign < 0) return 0;
	threshold = ((unsigned long long)-1) / (unsigned long long)base;
	if (p >= end) return 0;
	d = hxc_parse_digit(*p);
	if (d < 0 || d >= base) return 0;
	for (p++, res = (unsigned long long)d; p < end; p++) {
		unsigned char c = *p;
		if (c == 95) continue;
		d = hxc_parse_digit(c);
		if (d < 0 || d >= base) break;
		if (res > threshold) return 0;
		res = (unsigned long long)base * res + (unsigned long long)d;
		if (res < (unsigned long long)d) return 0;
	}
	if (p != end) return 0;
	if (!uonly && signedness) {
		if (sign >= 0) { if (res >= (1ULL << 63)) return 0; }
		else { if (res > (1ULL << 63)) return 0; }
	}
	*out = sign < 0 ? (unsigned long long)(-(long long)res) : res;
	return 1;
}
')
@:access(hxc.eval.EvalStdLib)
class EvalIntegers {
	static inline function vfn(f:VFunc):EvalValue return VFunction(f, true);

	static inline function arg(a:Array<EvalValue>, i:Int):EvalValue return i < a.length ? a[i] : VNull;

	static inline function i64(v:haxe.Int64):EvalValue return VInt64(new EvalInt64(v));

	static inline function u64(v:haxe.Int64):EvalValue return VUInt64(new EvalInt64(v));

	static function decodeU64(ctx:EvalContext, v:EvalValue):haxe.Int64 {
		return switch (v) {
			case VUInt64(b): b.v;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.integers.UInt64");
		};
	}

	static function decodeI64(ctx:EvalContext, v:EvalValue):haxe.Int64 {
		return switch (v) {
			case VInt64(b): b.v;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.integers.Int64");
		};
	}

	public static function int64ToString(v:haxe.Int64):String {
		var s:String = null;
		untyped __cpp__("{ char hxc_buf[32]; snprintf(hxc_buf, 32, \"%lld\", (long long){1}); {0} = ::String(hxc_buf); }", s, v);
		return s;
	}

	public static function uint64ToString(v:haxe.Int64):String {
		var s:String = null;
		untyped __cpp__("{ char hxc_buf[32]; snprintf(hxc_buf, 32, \"%llu\", (unsigned long long){1}); {0} = ::String(hxc_buf); }", s, v);
		return s;
	}

	static function parse(ctx:EvalContext, v:EvalValue, unsignedOnly:Bool):Null<haxe.Int64> {
		var b = EvalStdLib.decodeString(ctx, v).toBytes();
		var out:haxe.Int64 = 0;
		var ok:Int = 0;
		untyped __cpp__("{ unsigned long long hxc_r = 0; {0} = hxc_parse64({1}->length > 0 ? (const unsigned char*){1}->b->GetBase() : (const unsigned char*)\"\", {1}->length, {2} ? 1 : 0, &hxc_r); {3} = (::cpp::Int64)hxc_r; }",
			ok, b, unsignedOnly, out);
		return ok != 0 ? out : null;
	}

	// Signed and unsigned comparison: -1, 0 or 1.
	static function compareSigned(a:haxe.Int64, b:haxe.Int64):Int
		return untyped __cpp__("(((::cpp::Int64){0} > (::cpp::Int64){1}) - ((::cpp::Int64){0} < (::cpp::Int64){1}))", a, b);

	static function compareUnsigned(a:haxe.Int64, b:haxe.Int64):Int
		return untyped __cpp__("(((::cpp::UInt64){0} > (::cpp::UInt64){1}) - ((::cpp::UInt64){0} < (::cpp::UInt64){1}))", a, b);

	// Both libraries shift in C (the count taken modulo 64 by the machine); right shift is
	// arithmetic for Int64 and logical for UInt64.
	static function shiftLeft(a:haxe.Int64, n:Int):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)((::cpp::UInt64){0} << ({1} & 63))", a, n);

	static function shiftRightSigned(a:haxe.Int64, n:Int):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)((::cpp::Int64){0} >> ({1} & 63))", a, n);

	static function shiftRightUnsigned(a:haxe.Int64, n:Int):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)((::cpp::UInt64){0} >> ({1} & 63))", a, n);

	static function divUnsigned(a:haxe.Int64, b:haxe.Int64):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)((::cpp::UInt64){0} / (::cpp::UInt64){1})", a, b);

	static function remUnsigned(a:haxe.Int64, b:haxe.Int64):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)((::cpp::UInt64){0} % (::cpp::UInt64){1})", a, b);

	// Signed 64-bit division and remainder: the minimum Int64 divided by -1 is itself with remainder 0, not
	// a trap.
	static function divSigned(a:haxe.Int64, b:haxe.Int64):haxe.Int64 {
		if (b == -1) return untyped __cpp__("(::cpp::Int64)(0ULL - (::cpp::UInt64){0})", a);
		return untyped __cpp__("((::cpp::Int64){0} / (::cpp::Int64){1})", a, b);
	}

	static function remSigned(a:haxe.Int64, b:haxe.Int64):haxe.Int64 {
		if (b == -1) return 0;
		return untyped __cpp__("((::cpp::Int64){0} % (::cpp::Int64){1})", a, b);
	}

	static function wrapAdd(a:haxe.Int64, b:haxe.Int64):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)((::cpp::UInt64){0} + (::cpp::UInt64){1})", a, b);

	static function wrapSub(a:haxe.Int64, b:haxe.Int64):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)((::cpp::UInt64){0} - (::cpp::UInt64){1})", a, b);

	static function wrapMul(a:haxe.Int64, b:haxe.Int64):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)((::cpp::UInt64){0} * (::cpp::UInt64){1})", a, b);

	// An instance of haxe._Int64.___Int64 (or a subclass), its high and low halves joined.
	static function decodeHaxeI64(ctx:EvalContext, v:EvalValue):haxe.Int64 {
		var path = EvalHash.hash("haxe._Int64.___Int64");
		switch (v) {
			case VInstance(vi):
				var p = vi.iproto;
				while (p != null && p.ppath != path) p = p.pparent;
				if (p != null) {
					var hi = vi.iproto.pinstanceNames.get(EvalHash.keyHigh);
					var lo = vi.iproto.pinstanceNames.get(EvalHash.keyLow);
					if (hi == null || lo == null) throw new EvalExceptions.HostException("Not_found");
					var high = EvalStdLib.decodeI32(ctx, vi.ifields[hi]);
					var low = EvalStdLib.decodeI32(ctx, vi.ifields[lo]);
					return haxe.Int64.make(high, low);
				}
			case _:
		}
		return EvalExceptions.unexpectedValue(ctx, v, "haxe.Int64");
	}

	static final divisionByZero = "Division_by_zero";

	public static function init(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		inline function reg(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);
		inline function throwString(msg:String):Dynamic return EvalExceptions.excString(ctx, msg);

		var u = "eval.integers._UInt64.UInt64_Impl_";
		reg(u, "MAX", u64(haxe.Int64.make(0xFFFFFFFF, 0xFFFFFFFF)));
		reg(u, "ZERO", u64(0));
		reg(u, "ONE", u64(1));
		reg(u, "ofInt", vfn(a -> u64(haxe.Int64.ofInt(EvalStdLib.decodeI32(ctx, arg(a, 0))))));
		reg(u, "ofString", vfn(a -> {
			var r = parse(ctx, arg(a, 0), true);
			r == null ? throwString("The string is not a valid UInt64 representation") : u64(r);
		}));
		reg(u, "max", vfn(a -> {
			var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1));
			u64(compareUnsigned(x, y) >= 0 ? x : y);
		}));
		reg(u, "min", vfn(a -> {
			var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1));
			u64(compareUnsigned(x, y) <= 0 ? x : y);
		}));
		reg(u, "compare", vfn(a -> {
			var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1));
			VInt(compareUnsigned(x, y));
		}));
		reg(u, "toInt", vfn(a -> VInt(decodeU64(ctx, arg(a, 0)).low)));
		reg(u, "toInt64", vfn(a -> i64(decodeU64(ctx, arg(a, 0)))));
		reg(u, "toString", vfn(a -> VString(EvalString.createAscii(ByteString.ofText(uint64ToString(decodeU64(ctx, arg(a, 0))))))));
		reg(u, "successor", vfn(a -> u64(wrapAdd(decodeU64(ctx, arg(a, 0)), 1))));
		reg(u, "predecessor", vfn(a -> u64(wrapSub(decodeU64(ctx, arg(a, 0)), 1))));
		reg(u, "remainder", vfn(a -> {
			var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1));
			y == 0 ? throwString(divisionByZero) : u64(remUnsigned(x, y));
		}));
		reg(u, "add", vfn(a -> { var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1)); u64(wrapAdd(x, y)); }));
		reg(u, "sub", vfn(a -> { var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1)); u64(wrapSub(x, y)); }));
		reg(u, "mul", vfn(a -> { var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1)); u64(wrapMul(x, y)); }));
		reg(u, "div", vfn(a -> {
			var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1));
			y == 0 ? throwString(divisionByZero) : u64(divUnsigned(x, y));
		}));
		reg(u, "logand", vfn(a -> { var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1)); u64(x & y); }));
		reg(u, "logor", vfn(a -> { var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1)); u64(x | y); }));
		reg(u, "logxor", vfn(a -> { var x = decodeU64(ctx, arg(a, 0)), y = decodeU64(ctx, arg(a, 1)); u64(x ^ y); }));
		reg(u, "shift_left", vfn(a -> {
			var x = decodeU64(ctx, arg(a, 0)), n = EvalStdLib.decodeInt(ctx, arg(a, 1));
			u64(shiftLeft(x, n));
		}));
		reg(u, "shift_right", vfn(a -> {
			var x = decodeU64(ctx, arg(a, 0)), n = EvalStdLib.decodeInt(ctx, arg(a, 1));
			u64(shiftRightUnsigned(x, n));
		}));
		reg(u, "lognot", vfn(a -> u64(~decodeU64(ctx, arg(a, 0)))));

		var i = "eval.integers._Int64.Int64_Impl_";
		reg(i, "MAX", i64(haxe.Int64.make(0x7FFFFFFF, 0xFFFFFFFF)));
		reg(i, "MIN", i64(haxe.Int64.make(0x80000000, 0)));
		reg(i, "ZERO", i64(0));
		reg(i, "ONE", i64(1));
		reg(i, "ofInt", vfn(a -> i64(haxe.Int64.ofInt(EvalStdLib.decodeI32(ctx, arg(a, 0))))));
		reg(i, "ofString", vfn(a -> {
			var r = parse(ctx, arg(a, 0), false);
			r == null ? throwString("The string is not a valid Int64 representation") : i64(r);
		}));
		reg(i, "ofHxInt64", vfn(a -> i64(decodeHaxeI64(ctx, arg(a, 0)))));
		reg(i, "max", vfn(a -> {
			var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1));
			i64(compareSigned(x, y) >= 0 ? x : y);
		}));
		reg(i, "min", vfn(a -> {
			var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1));
			i64(compareSigned(x, y) <= 0 ? x : y);
		}));
		reg(i, "compare", vfn(a -> {
			var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1));
			VInt(compareSigned(x, y));
		}));
		reg(i, "toInt", vfn(a -> VInt(decodeI64(ctx, arg(a, 0)).low)));
		reg(i, "toUInt64", vfn(a -> u64(decodeI64(ctx, arg(a, 0)))));
		reg(i, "toHxInt64", vfn(a -> {
			var x = decodeI64(ctx, arg(a, 0));
			EvalStdLib.encodeHaxeI64(ctx, x.low, x.high);
		}));
		reg(i, "toString", vfn(a -> VString(EvalString.createAscii(ByteString.ofText(int64ToString(decodeI64(ctx, arg(a, 0))))))));
		reg(i, "successor", vfn(a -> i64(wrapAdd(decodeI64(ctx, arg(a, 0)), 1))));
		reg(i, "predecessor", vfn(a -> i64(wrapSub(decodeI64(ctx, arg(a, 0)), 1))));
		reg(i, "remainder", vfn(a -> {
			var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1));
			y == 0 ? throwString(divisionByZero) : i64(remSigned(x, y));
		}));
		reg(i, "add", vfn(a -> { var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1)); i64(wrapAdd(x, y)); }));
		reg(i, "sub", vfn(a -> { var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1)); i64(wrapSub(x, y)); }));
		reg(i, "mul", vfn(a -> { var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1)); i64(wrapMul(x, y)); }));
		reg(i, "div", vfn(a -> {
			var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1));
			y == 0 ? throwString(divisionByZero) : i64(divSigned(x, y));
		}));
		reg(i, "logand", vfn(a -> { var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1)); i64(x & y); }));
		reg(i, "logor", vfn(a -> { var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1)); i64(x | y); }));
		reg(i, "logxor", vfn(a -> { var x = decodeI64(ctx, arg(a, 0)), y = decodeI64(ctx, arg(a, 1)); i64(x ^ y); }));
		reg(i, "shift_left", vfn(a -> {
			var x = decodeI64(ctx, arg(a, 0)), n = EvalStdLib.decodeInt(ctx, arg(a, 1));
			i64(shiftLeft(x, n));
		}));
		reg(i, "shift_right", vfn(a -> {
			var x = decodeI64(ctx, arg(a, 0)), n = EvalStdLib.decodeInt(ctx, arg(a, 1));
			i64(shiftRightSigned(x, n));
		}));
		reg(i, "lognot", vfn(a -> i64(~decodeI64(ctx, arg(a, 0)))));
	}
}
