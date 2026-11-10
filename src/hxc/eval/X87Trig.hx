package hxc.eval;

import haxe.Int64;
import haxe.ds.Vector;
import haxe.io.FPHelper;

// Math.sin and Math.cos as Haxe's Windows binaries compute them. Those are built with mingw-w64, whose sin
// and cos run the x87 FSIN/FCOS instructions, and the x87 reduces the argument by a 66-bit approximation of
// pi (P66, which is below pi by about 4e-21) rather than by pi. Near a zero of the function the difference
// is large: cos(PI / 2) is 6.1230317691118863e-17 there, where a C library computes 6.123233995736766e-17,
// and it grows with the argument (cos(1e10) differs in the 12th digit). The x87 works in 64-bit precision,
// and the result is rounded to 64 bits and then to a double. mingw first reduces an argument of 2^63 or more
// exactly modulo 2 * FLDPI (pi to 64 bits) with FPREM1, as the instructions refuse such arguments.
//
// The same here: the reductions are exact, the sine or cosine of the reduced argument is computed in
// double-double precision (about 104 bits), and that is rounded to 64 bits and then to 53. This models FSIN
// and FCOS as correctly rounded to 64 bits, which the hardware only promises to within an extended ulp, and
// the microcode is vendor-specific: it matched Haxe 4.3.7 bit for bit on 55,064 arguments on the one host it
// was tested on (an AMD Zen 5 CPU), and is unverified on Intel ones. Haxe's other
// Math functions on Windows (exp, log, pow, atan2, and tan, atan, asin, acos from msvcrt) can differ from
// the C library hxc links in the last bit for some arguments; that is not emulated.
//
// The cost (2026-11-10, Ryzen AI 9 HX 370 pinned to its Zen 5 cores, a 1e6-iteration loop of
// `acc += Math.sin(x) + Math.cos(x)` under --interp, best of three): Haxe 4.3.7 102 ms, of which 28 ms is the
// loop without the calls, so about 37 ns a call. hxc took 3.4 s, about 1.65 us a call (some 45 times Haxe's),
// when every double-double step allocated its result and the expansion was rebuilt as new arrays. Without
// those allocations, the arithmetic unchanged step for step, it takes 0.96-1.03 s, about 0.46 us a call (10
// times the whole loop, 12 times a call); a cheap native, Math.sqrt, costs hxc's interpreter about 70 ns a
// call. The rewrite gave the same bits as Haxe 4.3.7's interpreter for sin and cos of 300,000 arguments
// (around 1, up to 2^70, any finite exponent, and near multiples of pi/2), as the old code did.
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
		// mingw returns a NaN argument itself (sign and payload kept) and the positive quiet NaN for an infinity.
		if (Math.isNaN(x)) return x;
		if (!Math.isFinite(x)) return FPHelper.i64ToDouble(0, 0x7FF80000);
		if (x == 0) return shift == 0 ? x : 1.0;
		var o = new DD(0, 0);
		var xh = x, xl = 0.0;
		if (Math.abs(x) >= TWO_63) {
			remainderTwoPi64(x, o);
			xh = o.hi;
			xl = o.lo;
		}
		// k = the nearest integer to x / (P66 / 2), r = x - k * P66 / 2 exactly, as an expansion e[0...n],
		// worked on in place (it starts with at most 2 components, and each subtraction adds at most 9).
		var e = new Vector<Float>(32);
		var n = 0;
		if (xl != 0) e[n++] = xl;
		e[n++] = xh;
		var kd = Math.fround(xh / H_APPROX);
		var quadrant = 0;
		if (kd != 0) {
			n = subtractMultiple(e, n, kd);
			quadrant = Std.int(kd - 4 * Math.ffloor(kd / 4));
			// kd came from a division rounded to a double, so it can be off by a little for a large x.
			compress(e, n, o);
			var d = Math.fround(o.hi / H_APPROX);
			if (d != 0) {
				n = subtractMultiple(e, n, d);
				quadrant += Std.int(d);
			}
		}
		compress(e, n, o);
		// The nearest k leaves |r| <= P66 / 4; a k off by one at the boundary is corrected here.
		var rh = o.hi, rl = o.lo;
		ddAdd(rh, rl, -QUARTER.hi, -QUARTER.lo, o);
		if (o.hi > 0) {
			compress(e, subtractMultiple(e, n, 1), o);
			quadrant++;
		} else {
			ddAdd(rh, rl, QUARTER.hi, QUARTER.lo, o);
			if (o.hi < 0) {
				compress(e, subtractMultiple(e, n, -1), o);
				quadrant--;
			} else {
				o.hi = rh;
				o.lo = rl;
			}
		}
		switch ((quadrant + shift) & 3) {
			case 0:
				sinDD(o.hi, o.lo, o);
			case 1:
				cosDD(o.hi, o.lo, o);
			case 2:
				sinDD(o.hi, o.lo, o);
				o.hi = -o.hi;
				o.lo = -o.lo;
			case _:
				cosDD(o.hi, o.lo, o);
				o.hi = -o.hi;
				o.lo = -o.lo;
		}
		return roundViaExtended(o.hi, o.lo);
	}

	// P66 / 4 as a double-double.
	static final QUARTER = quarter();

	static function quarter():DD {
		var o = new DD(0, 0);
		ddAdd(H1 / 2, 0, H2 / 2, 0, o);
		ddAdd(H0 / 2, 0, o.hi, o.lo, o);
		return o;
	}

	// The expansion e[0...n] minus k * P66 / 2, exactly and in place, for an integer k below 2^63; returns
	// the new length.
	static function subtractMultiple(e:Vector<Float>, n:Int, k:Float):Int {
		var sign = k < 0 ? -1.0 : 1.0;
		var a = Math.abs(k);
		var k2 = Math.ffloor(a / TWO_42);
		var rest = a - k2 * TWO_42;
		var k1 = Math.ffloor(rest / TWO_21);
		var k0 = rest - k1 * TWO_21;
		n = addLimbTimesHalfP66(e, n, -sign * k0);
		n = addLimbTimesHalfP66(e, n, -sign * (k1 * TWO_21));
		return addLimbTimesHalfP66(e, n, -sign * (k2 * TWO_42));
	}

	// e[0...n] plus m * P66 / 2, one limb of P66 / 2 at a time (each product is exact).
	static function addLimbTimesHalfP66(e:Vector<Float>, n:Int, m:Float):Int {
		if (m == 0) return n;
		n = grow(e, n, m * H0);
		n = grow(e, n, m * H1);
		return grow(e, n, m * H2);
	}

	// The IEEE remainder of x by 2 * FLDPI (FPREM1), exactly, as a double-double into o: |x| = m * 2^s with
	// s >= 11, 2 * FLDPI = Q / 2^61, so the remainder is (m * 2^(s + 61) mod Q) / 2^61, taken to the
	// nearest multiple (Q is odd, so there is no tie).
	static function remainderTwoPi64(x:Float, o:DD):Void {
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
		quickTwoSum(hi, lo, o);
		if (negative != (x < 0)) {
			o.hi = -o.hi;
			o.lo = -o.lo;
		}
	}

	static inline function unsigned32(i:Int):Float return i < 0 ? i + 4294967296.0 : i;

	// A double-double rounded to 64 bits and then to 53, as the x87 stores its result to a double. The
	// two roundings differ from one only when the 64-bit result is the midpoint between hi and its
	// neighbour on lo's side; that midpoint then rounds to the even one of them.
	static function roundViaExtended(vh:Float, vl:Float):Float {
		// quickTwoSum(vh, vl)
		var rh = vh + vl;
		var rl = vl - (rh - vh);
		if (rl == 0) return rh;
		var next = neighbour(rh, rl > 0);
		var gap = next - rh;
		if (Math.abs(rl - gap / 2) > Math.abs(gap) / 4096) return rh;
		return FPHelper.doubleToI64(rh).low & 1 == 0 ? rh : next;
	}

	static function neighbour(x:Float, up:Bool):Float {
		var bits = FPHelper.doubleToI64(x);
		var away = up == (x > 0);
		bits = away ? bits + 1 : bits - 1;
		return FPHelper.i64ToDouble(bits.low, bits.high);
	}

	// sin and cos of r by their Taylor series, for |r| <= P66 / 4 (the last terms are below 2^-118), into o.
	static function sinDD(rh:Float, rl:Float, o:DD):Void {
		series(rh, rl, 31, o);
		ddMul(o.hi, o.lo, rh, rl, o);
	}

	static function cosDD(rh:Float, rl:Float, o:DD):Void {
		series(rh, rl, 30, o);
	}

	// The terms of degree top, top - 2, ... 0 or 1 in r, as a polynomial in r^2 by Horner's rule from the top
	// term down; the odd one (sin's) still wants multiplying by r.
	static function series(rh:Float, rl:Float, top:Int, o:DD):Void {
		var c = coefficients();
		ddMul(rh, rl, rh, rl, o);
		var r2h = o.hi, r2l = o.lo;
		var sh = -c[top].hi, sl = -c[top].lo;
		var i = top - 2;
		while (i >= 0) {
			var ci = c[i];
			ddMul(sh, sl, r2h, r2l, o);
			if ((i >> 1) & 1 == 0) ddAdd(o.hi, o.lo, ci.hi, ci.lo, o); else ddAdd(o.hi, o.lo, -ci.hi, -ci.lo, o);
			sh = o.hi;
			sl = o.lo;
			i -= 2;
		}
		o.hi = sh;
		o.lo = sl;
	}

	// 1 / n! for n up to 31.
	static var inverseFactorials:Null<Array<DD>> = null;

	static function coefficients():Array<DD> {
		if (inverseFactorials == null) {
			var c = [new DD(1, 0)];
			for (n in 1...32) {
				var d = new DD(0, 0);
				ddDivInt(c[n - 1].hi, c[n - 1].lo, n, d);
				c.push(d);
			}
			inverseFactorials = c;
		}
		return inverseFactorials;
	}

	// Shewchuk's GROW-EXPANSION: e[0...n] (non-overlapping, increasing magnitude) plus b, exactly. In place:
	// a component is written at or below the one just read. Returns the new length, at most n + 1.
	static function grow(e:Vector<Float>, n:Int, b:Float):Int {
		var j = 0;
		var q = b;
		for (i in 0...n) {
			var c = e[i];
			var s = q + c;
			var bb = s - q;
			var err = (q - (s - bb)) + (c - bb);
			if (err != 0) e[j++] = err;
			q = s;
		}
		e[j++] = q;
		return j;
	}

	// The sum of e[0...n] as a double-double, adding from the smallest component, into o.
	static function compress(e:Vector<Float>, n:Int, o:DD):Void {
		var rh = 0.0, rl = 0.0;
		for (i in 0...n) {
			ddAdd(rh, rl, e[i], 0, o);
			rh = o.hi;
			rl = o.lo;
		}
		o.hi = rh;
		o.lo = rl;
	}

	// The double-double operations take their operands as Floats and write the result into o, so o may be
	// where an operand came from, and nothing on the way allocates (this runs for every Math.sin and cos a
	// macro calls). Each keeps the operation order of the textbook form in its comments, bit for bit.
	static function quickTwoSum(a:Float, b:Float, o:DD):Void {
		var s = a + b;
		var l = b - (s - a);
		o.hi = s;
		o.lo = l;
	}

	static function ddAdd(ah:Float, al:Float, bh:Float, bl:Float, o:DD):Void {
		// (s, se) = twoSum(ah, bh), (t, te) = twoSum(al, bl)
		var s = ah + bh;
		var sb = s - ah;
		var se = (ah - (s - sb)) + (bh - sb);
		var t = al + bl;
		var tb = t - al;
		var te = (al - (t - tb)) + (bl - tb);
		// (u, v) = quickTwoSum(s, se + t), then quickTwoSum(u, v + te)
		var b1 = se + t;
		var u = s + b1;
		var v = b1 - (u - s);
		var b2 = v + te;
		var w = u + b2;
		var wl = b2 - (w - u);
		o.hi = w;
		o.lo = wl;
	}

	static function ddMul(ah:Float, al:Float, bh:Float, bl:Float, o:DD):Void {
		// (p, pl) = twoProd(ah, bh), then quickTwoSum(p, pl + (ah * bl + al * bh))
		var p = ah * bh;
		var ca = 134217729.0 * ah;
		var xh = ca - (ca - ah);
		var xl = ah - xh;
		var cb = 134217729.0 * bh;
		var yh = cb - (cb - bh);
		var yl = bh - yh;
		var pl = ((xh * yh - p) + xh * yl + xl * yh) + xl * yl;
		quickTwoSum(p, pl + (ah * bl + al * bh), o);
	}

	static function ddDivInt(ah:Float, al:Float, n:Int, o:DD):Void {
		var q1 = ah / n;
		// (p, pl) = twoProd(q1, n)
		var nf:Float = n;
		var p = q1 * nf;
		var ca = 134217729.0 * q1;
		var xh = ca - (ca - q1);
		var xl = q1 - xh;
		var cb = 134217729.0 * nf;
		var yh = cb - (cb - nf);
		var yl = nf - yh;
		var pl = ((xh * yh - p) + xh * yl + xl * yh) + xl * yl;
		quickTwoSum(q1, ((ah - p) - pl + al) / n, o);
	}
}

private class DD {
	public var hi:Float;
	public var lo:Float;

	public inline function new(hi:Float, lo:Float) {
		this.hi = hi;
		this.lo = lo;
	}
}
