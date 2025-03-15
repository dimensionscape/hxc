package hxc.core;

// hxc.core.Json: the compiler-side JSON value model keeps object field order, unlike the host's
// anonymous objects.

enum JsonValue {
	JString(s:String);
	JFloat(f:Float);
	JInt(i:Int);
	JObject(fields:Array<JsonField>);
	JArray(values:Array<JsonValue>);
	JBool(b:Bool);
	JNull;
}

typedef JsonField = {name:String, value:JsonValue};

class JsonError extends haxe.Exception {}

class Json {
	public static function stringOfJson(v:JsonValue):String {
		var buf = new StringBuf();
		write(buf, v);
		return buf.toString();
	}

	static function write(buf:StringBuf, v:JsonValue):Void {
		switch (v) {
			case JString(s):
				writeString(buf, s);
			case JFloat(f):
				var s = Std.string(f);
				buf.add(s);
			case JInt(i):
				buf.add(Std.string(i));
			case JObject(fields):
				buf.addChar("{".code);
				for (i in 0...fields.length) {
					if (i > 0) buf.addChar(",".code);
					writeString(buf, fields[i].name);
					buf.addChar(":".code);
					write(buf, fields[i].value);
				}
				buf.addChar("}".code);
			case JArray(values):
				buf.addChar("[".code);
				for (i in 0...values.length) {
					if (i > 0) buf.addChar(",".code);
					write(buf, values[i]);
				}
				buf.addChar("]".code);
			case JBool(b):
				buf.add(b ? "true" : "false");
			case JNull:
				buf.add("null");
		}
	}

	static function writeString(buf:StringBuf, s:String):Void {
		buf.addChar('"'.code);
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			switch (c) {
				case '"'.code: buf.add('\\"');
				case "\\".code: buf.add("\\\\");
				case "\n".code: buf.add("\\n");
				case "\r".code: buf.add("\\r");
				case "\t".code: buf.add("\\t");
				case 8: buf.add("\\b");
				case 12: buf.add("\\f");
				case c if (c < 0x20): buf.add("\\u" + StringTools.hex(c, 4).toLowerCase());
				case c: buf.addChar(c);
			}
		}
		buf.addChar('"'.code);
	}

	// A recursive-descent reader into the ordered model; the grammar is plain JSON.
	public static function parse(s:String):JsonValue {
		var reader = new JsonReader(s);
		// Reads one value and never looks at what follows it.
		return reader.parseValue();
	}
}

private class JsonReader {
	var s:String;
	var pos:Int;

	public function new(s:String) {
		this.s = s;
		this.pos = 0;
	}

	public function posOf():Int return pos;
	public function eof():Bool return pos >= s.length;

	public function skipWs():Void {
		while (pos < s.length) {
			switch (StringTools.fastCodeAt(s, pos)) {
				case " ".code | "\t".code | "\n".code | "\r".code: pos++;
				case _: return;
			}
		}
	}

	// A JSON error carries the message alone, with no position.
	function fail(msg:String):Dynamic {
		throw new JsonError(msg);
	}

	public function parseValue():JsonValue {
		skipWs();
		if (eof()) fail("Unexpected end of input");
		return switch (StringTools.fastCodeAt(s, pos)) {
			case "{".code: parseObject();
			case "[".code: parseArray();
			case '"'.code: JString(parseString());
			case "t".code:
				expectWord("true");
				JBool(true);
			case "f".code:
				expectWord("false");
				JBool(false);
			case "n".code:
				expectWord("null");
				JNull;
			case _: parseNumber();
		}
	}

	function expectWord(w:String):Void {
		if (s.substr(pos, w.length) != w) fail("Invalid token");
		pos += w.length;
	}

	function parseObject():JsonValue {
		pos++; // {
		var fields:Array<JsonField> = [];
		skipWs();
		if (!eof() && StringTools.fastCodeAt(s, pos) == "}".code) {
			pos++;
			return JObject(fields);
		}
		while (true) {
			skipWs();
			if (eof() || StringTools.fastCodeAt(s, pos) != '"'.code) fail("Expected string");
			var name = parseString();
			skipWs();
			if (eof() || StringTools.fastCodeAt(s, pos) != ":".code) fail("Expected ':'");
			pos++;
			var value = parseValue();
			fields.push({name: name, value: value});
			skipWs();
			switch (eof() ? -1 : StringTools.fastCodeAt(s, pos)) {
				case ",".code: pos++;
				case "}".code: pos++; return JObject(fields);
				case _: fail("Expected ',' or '}'");
			}
		}
	}

	function parseArray():JsonValue {
		pos++; // [
		var values:Array<JsonValue> = [];
		skipWs();
		if (!eof() && StringTools.fastCodeAt(s, pos) == "]".code) {
			pos++;
			return JArray(values);
		}
		while (true) {
			values.push(parseValue());
			skipWs();
			switch (eof() ? -1 : StringTools.fastCodeAt(s, pos)) {
				case ",".code: pos++;
				case "]".code: pos++; return JArray(values);
				case _: fail("Expected ',' or ']'");
			}
		}
	}

	function parseString():String {
		pos++; // "
		var buf = new StringBuf();
		while (true) {
			if (eof()) fail("Unexpected end of input");
			var c = StringTools.fastCodeAt(s, pos++);
			switch (c) {
				case '"'.code: return buf.toString();
				case "\\".code:
					if (eof()) fail("Invalid escape sequence");
					var e = StringTools.fastCodeAt(s, pos++);
					switch (e) {
						case '"'.code: buf.addChar('"'.code);
						case "\\".code: buf.addChar("\\".code);
						case "/".code: buf.addChar("/".code);
						case "b".code: buf.addChar(8);
						case "f".code: buf.addChar(12);
						case "n".code: buf.addChar("\n".code);
						case "r".code: buf.addChar("\r".code);
						case "t".code: buf.addChar("\t".code);
						case "u".code:
							var code = hex4(pos);
							if (code == null) fail("Invalid escape sequence");
							pos += 4;
							// A surrogate pair combines into one code point.
							if (code >= 0xD800 && code <= 0xDBFF) {
								var low = s.substr(pos, 2) == "\\u" ? hex4(pos + 2) : null;
								if (low == null)
									fail("Missing escape sequence representing low surrogate for code point beyond U+FFFF");
								if (low < 0xDC00 || low > 0xDFFF)
									fail("Invalid low surrogate for code point beyond U+FFFF");
								pos += 6;
								buf.addChar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00));
							} else buf.addChar(code);
						case _: fail("Invalid escape sequence");
					}
				case _: buf.addChar(c);
			}
		}
	}

	function hex4(at:Int):Null<Int> {
		if (at + 4 > s.length) return null;
		var v = 0;
		for (i in 0...4) {
			var c = StringTools.fastCodeAt(s, at + i);
			var d = if (c >= "0".code && c <= "9".code) c - "0".code
				else if (c >= "a".code && c <= "f".code) c - "a".code + 10
				else if (c >= "A".code && c <= "F".code) c - "A".code + 10
				else return null;
			v = (v << 4) | d;
		}
		return v;
	}

	function parseNumber():JsonValue {
		var start = pos;
		var isFloat = false;
		while (!eof()) {
			var c = StringTools.fastCodeAt(s, pos);
			switch (c) {
				case "-".code | "+".code: pos++;
				case ".".code | "e".code | "E".code:
					isFloat = true;
					pos++;
				case c if (c >= "0".code && c <= "9".code): pos++;
				case _: break;
			}
		}
		if (pos == start) fail("Invalid token");
		var text = s.substr(start, pos - start);
		if (isFloat) {
			var f = Std.parseFloat(text);
			if (Math.isNaN(f)) fail("Invalid token");
			return JFloat(f);
		}
		var i = Std.parseInt(text);
		if (i == null) {
			var f = Std.parseFloat(text);
			if (Math.isNaN(f)) fail("Invalid token");
			return JFloat(f);
		}
		return JInt(i);
	}
}
