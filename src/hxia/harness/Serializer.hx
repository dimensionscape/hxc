package hxia.harness;

// The canonical value serializer. Identical pure-Haxe output on every target, so
// Std.string (which varies by target: object field order, float text, null shapes)
// is never used.
class Serializer {
	public static function value(v:Dynamic):String {
		if (v == null)
			return "null";
		return switch (Type.typeof(v)) {
			case TBool: (v : Bool) ? "true" : "false";
			case TInt: Std.string((v : Int));
			case TFloat: floatText(v);
			case TClass(String): quote(v);
			case TClass(Array): array(v);
			case TClass(c) if (isMap(c)): map(v);
			case TClass(c): throw "Serializer: opaque class instance " + Type.getClassName(c) + " passed to Guard.portable";
			case TObject: anon(v);
			case TEnum(_): enumValue(v);
			case other: throw "Serializer: unserializable value kind " + other;
		}
	}

	// NaN/Inf spelled fixed; integral floats forced to `.0`; otherwise a shared
	// shortest-ish decimal via a fixed %.17g-then-trim, identical on all targets.
	static function floatText(f:Float):String {
		if (Math.isNaN(f))
			return "NaN";
		if (!Math.isFinite(f))
			return f > 0 ? "Inf" : "-Inf";
		if (f == Math.ffloor(f) && Math.abs(f) < 1e15) {
			var i = Std.int(f);
			// -0.0 canonicalizes to 0.0
			return (i == 0 ? "0" : Std.string(i)) + ".0";
		}
		return trimDecimal(fixed17(f));
	}

	// A deterministic 17-significant-digit rendering built from integer math so it
	// does not depend on the platform's Std.string(Float).
	static function fixed17(f:Float):String {
		var neg = f < 0;
		var a = neg ? -f : f;
		var exp = 0;
		while (a >= 10) { a /= 10; exp++; }
		while (a < 1) { a *= 10; exp--; }
		// A in [1,10); take 17 significant digits
		var digits = new StringBuf();
		for (i in 0...17) {
			var d = Std.int(a);
			if (d > 9) d = 9;
			digits.add(d);
			a = (a - d) * 10;
		}
		var ds = digits.toString();
		var sb = new StringBuf();
		if (neg) sb.add("-");
		if (exp >= 0 && exp < 17) {
			sb.add(ds.substr(0, exp + 1));
			sb.add(".");
			sb.add(ds.substr(exp + 1));
		} else {
			sb.add(ds.charAt(0));
			sb.add(".");
			sb.add(ds.substr(1));
			sb.add("e");
			sb.add(exp);
		}
		return sb.toString();
	}

	static function trimDecimal(s:String):String {
		if (s.indexOf(".") < 0 || s.indexOf("e") >= 0)
			return s;
		var end = s.length;
		while (end > 0 && s.charAt(end - 1) == "0") end--;
		if (end > 0 && s.charAt(end - 1) == ".") end++; // Keep one trailing zero
		return s.substr(0, end);
	}

	static function quote(s:String):String {
		return "\"" + escape(s) + "\"";
	}

	// Escapes control chars so a value never breaks the line protocol.
	public static function escape(s:String):String {
		var sb = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charAt(i);
			switch (c) {
				case "\\": sb.add("\\\\");
				case "\t": sb.add("\\t");
				case "\n": sb.add("\\n");
				case "\r": sb.add("\\r");
				case "\"": sb.add("\\\"");
				case _: sb.add(c);
			}
		}
		return sb.toString();
	}

	static function array(a:Array<Dynamic>):String {
		return "[" + [for (x in a) value(x)].join(",") + "]";
	}

	// Maps serialize as key-sorted pairs, since iteration order is HOST-DEFINED.
	// Dispatch through the typed IMap interface: calling keys()/get() via Dynamic
	// does not resolve on js (the abstract forwards are compile-time only).
	static function map(m:Dynamic):String {
		var im:haxe.Constraints.IMap<Dynamic, Dynamic> = cast m;
		var pairs:Array<{k:String, v:String}> = [];
		var keys = im.keys();
		while (keys.hasNext()) {
			var k = keys.next();
			pairs.push({k: value(k), v: value(im.get(k))});
		}
		pairs.sort(function(a, b) return a.k < b.k ? -1 : (a.k > b.k ? 1 : 0));
		return "{" + [for (p in pairs) p.k + "=>" + p.v].join(",") + "}";
	}

	// Anonymous objects: lexicographically sorted field names.
	static function anon(o:Dynamic):String {
		var fields = Reflect.fields(o);
		fields.sort(Reflect.compare);
		return "{" + [for (f in fields) f + ":" + value(Reflect.field(o, f))].join(",") + "}";
	}

	static function enumValue(e:Dynamic):String {
		var name = Type.enumConstructor(e);
		var params = Type.enumParameters(e);
		if (params.length == 0)
			return name;
		return name + "(" + [for (p in params) value(p)].join(",") + ")";
	}

	static function isMap(c:Class<Dynamic>):Bool {
		var n = Type.getClassName(c);
		return n == "haxe.ds.StringMap" || n == "haxe.ds.IntMap" || n == "haxe.ds.ObjectMap" || n == "haxe.ds.EnumValueMap";
	}
}
