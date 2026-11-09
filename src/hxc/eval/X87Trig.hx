package hxc.eval;

import haxe.Int64;
import haxe.io.FPHelper;

// Math.sin and Math.cos as Haxe's Windows binaries compute them. Those are built with mingw-w64, whose sin
// and cos run the x87 FSIN/FCOS instructions, and the x87 reduces the argument by a 66-bit approximation of
// pi (P66, which is below pi by about 4e-21) rather than by pi. Near a zero of the function the difference
// is large: cos(PI / 2) is 6.1230317691118863e-17 there, where a C library computes 6.123233995736766e-17,
// and it grows with the argument (cos(1e10) differs in the 12th digit). The x87 works in 64-bit precision,
// and the result is rounded to 64 bits and then to a double. mingw first reduces an argument of 2^63 or more
// exactly modulo 2 * FLDPI (pi to 64 bits) with FPREM1, as the instructions refuse such arguments.
//
// The same here, exactly: the reductions are exact, the sine or cosine of the reduced argument is computed
// in double-double precision (about 104 bits), and that is rounded to 64 bits and then to 53. Haxe's other
// Math functions on Windows (exp, log, pow, atan2, and tan, atan, asin, acos from msvcrt) can differ from
// the C library hxc links in the last bit for some arguments; that is not emulated.
class X87Trig {
	public static function sin(x:Float):Float return trig(x, 0);

	public static function cos(x:Float):Float return trig(x, 1);

	// P66 / 2 = 0x3243F6A8885A308D3 / 2^65, in three 22-bit limbs, so that a limb times an integer of up
	// to 21 bits is an exact double.
	static final H0 = 3294198 / 2097152.0; // * 2^-21
	static final H1 = 2761238 / 8796093022208.0; // * 2^-43
	static final H2 = 2296019 / 36893488147419103232.0; // * 2^-65
	static final H_APPROX = 1.5707963267948966;
	static final TWO_21 = 2097152.0;
	static final TWO_42 = 4398046511104.0;
	static final TWO_63 = 9223372036854775808.0;

	// 0 for sin, 1 for cos (cos t = sin(t + pi/2), one quadrant on).
	static function trig(x:Float, shift:Int):Float {
		if (Math.isNaN(x) || !Math.isFinite(x)) return Math.NaN;
		if (x == 0) return shift == 0 ? x : 1.0;
		var xh = x, xl = 0.0;
		if (Math.abs(x) >= TWO_63) {
			var r = remainderTwoPi64(x);
			xh = r.hi;
			xl = r.lo;
		}
		// k = the nearest integer to x / (P66 / 2), r = x - k * P66 / 2 exactly, as an expansion.
		var e = xl == 0 ? [xh] : [xl, xh];
		var kd = Math.fround(xh / H_APPROX);
		var quadrant = 0;
		if (kd != 0) {
			e = subtractMultiple(e, kd);
			quadrant = Std.int(kd - 4 * Math.ffloor(kd / 4));
			// kd came from a division rounded to a double, so it can be off by a little for a large x.
			var d = Math.fround(compress(e).hi / H_APPROX);
			if (d != 0) {
				e = subtractMultiple(e, d);
				quadrant += Std.int(d);
			}
		}
		var r = compress(e);
		// The nearest k leaves |r| <= P66 / 4; a k off by one at the boundary is corrected here.
		var quarter = ddAdd(new DD(H0 / 2, 0), ddAdd(new DD(H1 / 2, 0), new DD(H2 / 2, 0)));
		if (ddSub(r, quarter).hi > 0) {
			r = compress(subtractMultiple(e, 1));
			quadrant++;
		} else if (ddAdd(r, quarter).hi < 0) {
			r = compress(subtractMultiple(e, -1));
			quadrant--;
		}
		var v = switch ((quadrant + shift) & 3) {
			case 0: sinDD(r);
			case 1: cosDD(r);
			case 2: ddNeg(sinDD(r));
			case _: ddNeg(cosDD(r));
		};
		return roundViaExtended(v);
	}

	// The expansion e minus k * P66 / 2, exactly, for an integer k below 2^63.
	static function subtractMultiple(e:Array<Float>, k:Float):Array<Float> {
		var sign = k < 0 ? -1.0 : 1.0;
		var a = Math.abs(k);
		var k2 = Math.ffloor(a / TWO_42);
		var rest = a - k2 * TWO_42;
		var k1 = Math.ffloor(rest / TWO_21);
		var k0 = rest - k1 * TWO_21;
		for (kl in [k0, k1 * TWO_21, k2 * TWO_42])
			if (kl != 0)
				for (h in [H0, H1, H2])
					e = grow(e, -sign * kl * h);
		return e;
	}

	// The IEEE remainder of x by 2 * FLDPI (FPREM1), exactly, as a double-double: |x| = m * 2^s with
	// s >= 11, 2 * FLDPI = Q / 2^61, so the remainder is (m * 2^(s + 61) mod Q) / 2^61, taken to the
	// nearest multiple (Q is odd, so there is no tie).
	static function remainderTwoPi64(x:Float):DD {
		var bits = FPHelper.doubleToI64(x);
		var exponent = (bits.high >>> 20) & 0x7FF;
		var a = Int64.make(bits.high & 0xFFFFF | 0x100000, bits.low);
		var q = Int64.make(0xC90FDAA2, 0x2168C235);
		for (_ in 0...exponent - 1075 + 61) {
			// a < q, so 2a mod q is a + a or a - (q - a), in unsigned 64-bit arithmetic.
			var rest = q - a;
			a = Int64.ucompare(a, rest) >= 0 ? a - rest : a + a;
		}
		var negative = Int64.ucompare(a, q - a) > 0;
		if (negative) a = q - a;
		// a < 2^63 now: two exact 32-bit halves.
		var hi = unsigned32(a.high) * 4294967296.0 / 2305843009213693952.0; // / 2^61
		var lo = unsigned32(a.low) / 2305843009213693952.0;
		var r = quickTwoSum(hi, lo);
		if (negative != (x < 0)) r = ddNeg(r);
		return r;
	}

	static inline function unsigned32(i:Int):Float return i < 0 ? i + 4294967296.0 : i;

	// A double-double rounded to 64 bits and then to 53, as the x87 stores its result to a double. The
	// two roundings differ from one only when the 64-bit result is the midpoint between hi and its
	// neighbour on lo's side; that midpoint then rounds to the even one of them.
	static function roundViaExtended(v:DD):Float {
		var r = quickTwoSum(v.hi, v.lo);
		if (r.lo == 0) return r.hi;
		var next = neighbour(r.hi, r.lo > 0);
		var gap = next - r.hi;
		if (Math.abs(r.lo - gap / 2) > Math.abs(gap) / 4096) return r.hi;
		return FPHelper.doubleToI64(r.hi).low & 1 == 0 ? r.hi : next;
	}

	static function neighbour(x:Float, up:Bool):Float {
		var bits = FPHelper.doubleToI64(x);
		var away = up == (x > 0);
		bits = away ? bits + 1 : bits - 1;
		return FPHelper.i64ToDouble(bits.low, bits.high);
	}

	// sin and cos by their Taylor series, for |r| <= P66 / 4: the last terms are below 2^-118.
	static function sinDD(r:DD):DD {
		var c = coefficients();
		var r2 = ddMul(r, r);
		var s = new DD(-c[31].hi, -c[31].lo);
		var i = 29;
		while (i >= 1) {
			var ci = (i >> 1) & 1 == 0 ? c[i] : ddNeg(c[i]);
			s = ddAdd(ddMul(s, r2), ci);
			i -= 2;
		}
		return ddMul(s, r);
	}

	static function cosDD(r:DD):DD {
		var c = coefficients();
		var r2 = ddMul(r, r);
		var s = new DD(-c[30].hi, -c[30].lo);
		var i = 28;
		while (i >= 0) {
			var ci = (i >> 1) & 1 == 0 ? c[i] : ddNeg(c[i]);
			s = ddAdd(ddMul(s, r2), ci);
			i -= 2;
		}
		return s;
	}

	// 1 / n! for n up to 31.
	static var inverseFactorials:Null<Array<DD>> = null;

	static function coefficients():Array<DD> {
		if (inverseFactorials == null) {
			var c = [new DD(1, 0)];
			for (n in 1...32) c.push(ddDivInt(c[n - 1], n));
			inverseFactorials = c;
		}
		return inverseFactorials;
	}

	// Shewchuk's GROW-EXPANSION: e (non-overlapping, increasing magnitude) plus b, exactly.
	static function grow(e:Array<Float>, b:Float):Array<Float> {
		var out = [];
		var q = b;
		for (c in e) {
			var s = q + c;
			var bb = s - q;
			var err = (q - (s - bb)) + (c - bb);
			if (err != 0) out.push(err);
			q = s;
		}
		out.push(q);
		return out;
	}

	// An expansion's sum as a double-double, adding from the smallest component.
	static function compress(e:Array<Float>):DD {
		var r = new DD(0, 0);
		for (c in e) r = ddAdd(r, new DD(c, 0));
		return r;
	}

	static function quickTwoSum(a:Float, b:Float):DD {
		var s = a + b;
		return new DD(s, b - (s - a));
	}

	static function twoSum(a:Float, b:Float):DD {
		var s = a + b;
		var bb = s - a;
		return new DD(s, (a - (s - bb)) + (b - bb));
	}

	static function twoProd(a:Float, b:Float):DD {
		var p = a * b;
		var ca = 134217729.0 * a;
		var ah = ca - (ca - a);
		var al = a - ah;
		var cb = 134217729.0 * b;
		var bh = cb - (cb - b);
		var bl = b - bh;
		return new DD(p, ((ah * bh - p) + ah * bl + al * bh) + al * bl);
	}

	static function ddAdd(a:DD, b:DD):DD {
		var s = twoSum(a.hi, b.hi);
		var t = twoSum(a.lo, b.lo);
		var r = quickTwoSum(s.hi, s.lo + t.hi);
		return quickTwoSum(r.hi, r.lo + t.lo);
	}

	static inline function ddNeg(a:DD):DD return new DD(-a.hi, -a.lo);

	static function ddSub(a:DD, b:DD):DD return ddAdd(a, ddNeg(b));

	static function ddMul(a:DD, b:DD):DD {
		var p = twoProd(a.hi, b.hi);
		return quickTwoSum(p.hi, p.lo + (a.hi * b.lo + a.lo * b.hi));
	}

	static function ddDivInt(a:DD, n:Int):DD {
		var q1 = a.hi / n;
		var p = twoProd(q1, n);
		var q2 = ((a.hi - p.hi) - p.lo + a.lo) / n;
		return quickTwoSum(q1, q2);
	}
}

private class DD {
	public final hi:Float;
	public final lo:Float;

	public inline function new(hi:Float, lo:Float) {
		this.hi = hi;
		this.lo = lo;
	}
}
