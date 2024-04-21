package hxia.cppia;

import haxe.io.Bytes;

// Parses a cppia artifact (text CPPIA or binary CPPIB) into a ModuleIR. Only the text
// header is decoded; the body is preserved verbatim. Byte-cursor based, so string/type
// contents keep their exact bytes.
class Loader {
	static inline var NL = 0x0A; // '\n'
	static inline var SP = 0x20; // ' '

	final b:Bytes;
	var pos:Int = 0;

	function new(b:Bytes) {
		this.b = b;
	}

	public static function parse(b:Bytes):ModuleIR {
		return new Loader(b).run();
	}

	function run():ModuleIR {
		var magic = readTextLine();
		if (magic != "CPPIA" && magic != "CPPIB")
			throw new LoaderError("not a cppia artifact (magic '" + magic + "')");
		var strings = readTable();
		var types = readTable();
		var classCount = Std.parseInt(readTextLine());
		if (classCount == null)
			throw new LoaderError("bad class count");
		var body = b.sub(pos, b.length - pos);
		return new ModuleIR(magic, strings, types, classCount, body);
	}

	// A count line followed by that many `<byteLen> <content>\n` entries.
	function readTable():Array<Bytes> {
		var n = Std.parseInt(readTextLine());
		if (n == null)
			throw new LoaderError("bad table count at " + pos);
		var out = [];
		for (_ in 0...n) {
			var len = readInt();
			expect(SP);
			var content = b.sub(pos, len);
			pos += len;
			expect(NL);
			out.push(content);
		}
		return out;
	}

	// Reads bytes up to (not including) the next '\n', which is consumed; returns the
	// content as a String (used for magic and count lines, which are ASCII).
	function readTextLine():String {
		var start = pos;
		while (pos < b.length && b.get(pos) != NL)
			pos++;
		var s = b.getString(start, pos - start);
		if (pos < b.length)
			pos++; // Consume '\n'
		return s;
	}

	// Reads an ASCII integer (digits) at the cursor, stopping at the first non-digit.
	function readInt():Int {
		var start = pos;
		while (pos < b.length) {
			var c = b.get(pos);
			if (c < 0x30 || c > 0x39)
				break;
			pos++;
		}
		if (pos == start)
			throw new LoaderError("expected integer at " + pos);
		return Std.parseInt(b.getString(start, pos - start));
	}

	function expect(byte:Int):Void {
		if (pos >= b.length || b.get(pos) != byte)
			throw new LoaderError("expected byte " + byte + " at " + pos + ", got " + (pos < b.length ? b.get(pos) : -1));
		pos++;
	}
}

class LoaderError extends haxe.Exception {
	public function new(message:String) super(message);
}
