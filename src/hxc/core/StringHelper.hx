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

	public static function startsUppercaseIdentifier(x:String):Bool {
		if (x.length == 0)
			throw new haxe.Exception("Identifier name must not be empty");
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

	public static function checkUppercase(x:String):Void {
		if (x.length == 0)
			throw new haxe.Exception("empty part");
		else if (!startsUppercaseIdentifier(x))
			throw new haxe.Exception("Class name must start with an uppercase letter");
	}

	public static function sEscape(s:String, hex:Bool = true):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			switch (c) {
				case "\n".code: b.add("\\n");
				case "\t".code: b.add("\\t");
				case "\r".code: b.add("\\r");
				case '"'.code: b.add("\\\"");
				case "\\".code: b.add("\\\\");
				case _ if (c < 32 && hex): b.add("\\x" + StringTools.hex(c, 2));
				case _: b.addChar(c);
			}
		}
		return b.toString();
	}
}
