package hxc.core;


class Numeric {
	// Append '.' when the string reads as a plain integer
	static function validFloatLexeme(s:String):String {
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			if (!((c >= "0".code && c <= "9".code) || c == "-".code)) return s;
		}
		return s + ".";
	}

	// C "%.<prec>g" formatting; the shortest-repr search below relies on it
	static function formatG(f:Float, precision:Int):String {
		#if cpp
		var s = switch (precision) {
			case 12: untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.12g", v); return ::String(buf); })({0})', f);
			case 15: untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.15g", v); return ::String(buf); })({0})', f);
			// On Windows the 18-digit form prints with "%.17g": msvcrt's printf only generates 17
			// significant digits for "%.18g" and zero-fills the rest, and %g then strips those trailing
			// zeros, so the two agree there. The C libraries elsewhere print the 18th digit.
			case 18 if (Globals.isWindows): untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.17g", v); return ::String(buf); })({0})', f);
			case 18: untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.18g", v); return ::String(buf); })({0})', f);
			case _: Std.string(f);
		}
		return msvcrtExponent(s);
		#elseif cs
		return msvcrtExponent(printfG(f, precision == 18 && Globals.isWindows ? 17 : precision));
		#else
		// Interp type-check fallback; the native binary uses the C formatter
		return Std.string(f);
		#end
	}

	#if cs
	// C's "%.<precision>g" on .NET, whose "E" and "F" formats give the exact decimal digits of a double:
	// scientific when the exponent is below -4 or not below the precision, fixed otherwise, trailing zeros
	// dropped, and an exponent of at least two digits.
	public static function printfG(f:Float, precision:Int):String {
		if (Math.isNaN(f)) return "nan";
		if (!Math.isFinite(f)) return f > 0 ? "inf" : "-inf";
		var inv = cs.system.globalization.CultureInfo.InvariantCulture;
		var boxed:Dynamic = f;
		var sci:String = cs.system.String.Format(inv, "{0:E" + (precision - 1) + "}", cs.NativeArray.make(boxed));
		var ePos = sci.indexOf("E");
		var negative = sci.charAt(ePos + 1) == "-";
		var x = 0;
		for (i in ePos + 2...sci.length) x = x * 10 + (sci.charCodeAt(i) - "0".code);
		if (negative) x = -x;
		function strip(s:String):String {
			if (s.indexOf(".") < 0) return s;
			var n = s.length;
			while (s.charCodeAt(n - 1) == "0".code) n--;
			if (s.charCodeAt(n - 1) == ".".code) n--;
			return s.substr(0, n);
		}
		if (x < -4 || x >= precision) {
			var ax = negative ? -x : x;
			return strip(sci.substr(0, ePos)) + "e" + (negative ? "-" : "+") + (ax < 10 ? "0" : "") + ax;
		}
		var fixed:String = cs.system.String.Format(inv, "{0:F" + (precision - 1 - x) + "}", cs.NativeArray.make(boxed));
		return strip(fixed);
	}
	#end

	// Msvcrt's printf pads the %g exponent to at least three digits (1.5e+012); the UCRT snprintf hxc
	// links pads to two. Normalize so folded float lexemes keep the three-digit form on Windows. The C
	// libraries elsewhere print two digits, and so does Haxe there.
	static function msvcrtExponent(s:String):String {
		if (!Globals.isWindows) return s;
		var i = s.indexOf("e");
		if (i < 0) return s;
		var digits = s.substr(i + 2);
		while (digits.length < 3) digits = "0" + digits;
		return s.substr(0, i + 2) + digits;
	}

	// floatRepres: the shortest of %.12g/%.15g/%.18g that round-trips.
	// Numeric separators are accepted; TFloat literals keep them raw.
	public static function parseFloatLit(s:String):Float {
		return Std.parseFloat(StringTools.replace(s, "_", ""));
	}

	public static function floatRepres(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (!Math.isFinite(f)) return f < 0.0 ? "neg_infinity" : "infinity";
		var s1 = formatG(f, 12);
		var floatVal = if (f == Std.parseFloat(s1)) s1 else {
			var s2 = formatG(f, 15);
			if (f == Std.parseFloat(s2)) s2 else formatG(f, 18);
		}
		return validFloatLexeme(floatVal);
	}
}
