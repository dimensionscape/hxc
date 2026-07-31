package hxc.core;

class StringHelper {
	public static function uppercase(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var code = s.charCodeAt(i);
			if (97 <= code && code <= 122)
				b.addChar(code - 32);
			else
				b.addChar(code);
		}
		return b.toString();
	}

	public static function capitalize(s:String):String {
		if (s.length == 0)
			return "";
		var b = new StringBuf();
		var code0 = s.charCodeAt(0);
		b.addChar(97 <= code0 && code0 <= 122 ? code0 - 32 : code0);
		for (i in 1...s.length)
			b.addChar(s.charCodeAt(i));
		return b.toString();
	}

	// An empty name is an InvalidArgument, not a plain failure.
	public static function startsUppercaseIdentifier(x:String):Bool {
		if (x.length == 0)
			throw new JsonRpc.InvalidArgument("Identifier name must not be empty");
		function loop(p:Int):Bool {
			var c = x.charCodeAt(p);
			if (c >= "A".code && c <= "Z".code)
				return true;
			else if (c == "_".code)
				return p + 1 < x.length && loop(p + 1);
			else
				return false;
		}
		return loop(0);
	}

	// Identifier shape and not a keyword.
	static var keywords:Map<String, Bool> = [for (k in [
		"function", "class", "static", "var", "if", "else", "while", "do", "for",
		"break", "continue", "return", "extends", "implements", "import", "switch",
		"case", "default", "private", "public", "try", "catch", "new", "this",
		"throw", "extern", "enum", "in", "interface", "untyped", "cast", "override",
		"typedef", "dynamic", "package", "inline", "using", "null", "true", "false",
		"abstract", "macro", "final", "operator", "overload"
	]) k => true];

	public static function isValidIdentifier(s:String):Bool {
		if (s.length == 0) return false;
		inline function alpha(c:Int) return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code;
		if (!alpha(s.charCodeAt(0))) return false;
		for (i in 1...s.length) {
			var c = s.charCodeAt(i);
			if (!alpha(c) && !(c >= "0".code && c <= "9".code)) return false;
		}
		return !keywords.exists(s);
	}

	public static function checkUppercase(x:String):Void {
		if (x.length == 0)
			throw new haxe.Exception("empty part");
		else if (!startsUppercaseIdentifier(x))
			throw new haxe.Exception("Class name must start with an uppercase letter");
	}

	public static function sEscape(s:String, hex:Bool = true):String {
		var b = new StringBuf();
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i);
			switch (c) {
				case "\n".code: b.add("\\n");
				case "\t".code: b.add("\\t");
				case "\r".code: b.add("\\r");
				case '"'.code: b.add("\\\"");
				case "\\".code: b.add("\\\\");
				case _ if (c < 32 && hex): b.add("\\x" + StringTools.hex(c, 2));
				case _:
					// A surrogate pair joins into one code point: addChar on a lone half
					// yields U+FFFD on this host runtime.
					if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
						var lo = s.charCodeAt(i + 1);
						if (lo >= 0xDC00 && lo <= 0xDFFF) {
							b.addChar(0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00));
							i += 2;
							continue;
						}
					}
					b.addChar(c);
			}
			i++;
		}
		return b.toString();
	}
}
