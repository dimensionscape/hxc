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
			// The 18-digit form prints with "%.17g": msvcrt's printf only generates 17 significant digits
			// for "%.18g" and zero-fills the rest, and %g then strips those trailing zeros, so the two
			// agree there. No double needs more than 17 digits to round-trip, so the value is kept.
			case 18: untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.17g", v); return ::String(buf); })({0})', f);
			case _: Std.string(f);
		}
		return msvcrtExponent(s);
		#else
		// Interp type-check fallback; the native binary uses the C formatter
		return Std.string(f);
		#end
	}

	// Normalize folded float lexemes to match reference output.
	static function msvcrtExponent(s:String):String {
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
