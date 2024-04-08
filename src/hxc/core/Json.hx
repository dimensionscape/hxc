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
		var v = reader.parseValue();
		reader.skipWs();
		if (!reader.eof()) throw new JsonError("Unexpected trailing characters at position " + reader.posOf());
		return v;
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

	function fail(msg:String):Dynamic {
		throw new JsonError(msg + " at position " + pos);
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
		if (s.substr(pos, w.length) != w) fail("Expected " + w);
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
			if (eof() || StringTools.fastCodeAt(s, pos) != '"'.code) fail("Expected object key");
			var name = parseString();
			skipWs();
			if (eof() || StringTools.fastCodeAt(s, pos) != ":".code) fail("Expected :");
			pos++;
			var value = parseValue();
			fields.push({name: name, value: value});
			skipWs();
			if (eof()) fail("Unterminated object");
			switch (StringTools.fastCodeAt(s, pos)) {
				case ",".code: pos++;
				case "}".code: pos++; return JObject(fields);
				case _: fail("Expected , or }");
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
			if (eof()) fail("Unterminated array");
			switch (StringTools.fastCodeAt(s, pos)) {
				case ",".code: pos++;
				case "]".code: pos++; return JArray(values);
				case _: fail("Expected , or ]");
			}
		}
	}

	function parseString():String {
		pos++; // "
		var buf = new StringBuf();
		while (true) {
			if (eof()) fail("Unterminated string");
			var c = StringTools.fastCodeAt(s, pos++);
			switch (c) {
				case '"'.code: return buf.toString();
				case "\\".code:
					if (eof()) fail("Unterminated escape");
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
							var hex = s.substr(pos, 4);
							if (hex.length < 4) fail("Invalid unicode escape");
							var code = Std.parseInt("0x" + hex);
							if (code == null) fail("Invalid unicode escape");
							pos += 4;
							// A surrogate pair combines into one code point.
							if (code >= 0xD800 && code <= 0xDBFF && s.substr(pos, 2) == "\\u") {
								var hex2 = s.substr(pos + 2, 4);
								var low = Std.parseInt("0x" + hex2);
								if (low != null && low >= 0xDC00 && low <= 0xDFFF) {
									pos += 6;
									buf.addChar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00));
								} else buf.addChar(code);
							} else buf.addChar(code);
						case _: fail("Invalid escape");
					}
				case _: buf.addChar(c);
			}
		}
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
		if (pos == start) fail("Invalid character");
		var text = s.substr(start, pos - start);
		if (isFloat) {
			var f = Std.parseFloat(text);
			if (Math.isNaN(f)) fail("Invalid number");
			return JFloat(f);
		}
		var i = Std.parseInt(text);
		if (i == null) {
			var f = Std.parseFloat(text);
			if (Math.isNaN(f)) fail("Invalid number");
			return JFloat(f);
		}
		return JInt(i);
	}
}
