package hxia.cppia;

import haxe.io.Bytes;
import hxia.cppia.Decoder.DecodeError;

// Reads the text (CPPIA) body: whitespace-separated tokens. The writer's debug flag equals
// asciiOut, so a text module always carries a `fileId line` prefix before each expression - this is
// the only cppia form that has positions at all. Byte-cursor based (not line-split) so the raw
// resource data tail reads from the same stream. A '#' starts a comment to end of line; body tokens
// are op names and decimal integers, so '#' is unambiguous outside resource data.
class TextReader {
	final b:Bytes;
	public var pos:Int;

	public function new(b:Bytes, pos:Int = 0) {
		this.b = b;
		this.pos = pos;
	}

	inline function isWs(c:Int):Bool
		return c == " ".code || c == "\t".code || c == "\r".code || c == "\n".code;

	function skipWs():Void {
		while (pos < b.length) {
			var c = b.get(pos);
			if (isWs(c)) {
				pos++;
			} else if (c == "#".code) {
				while (pos < b.length && b.get(pos) != "\n".code)
					pos++;
			} else {
				break;
			}
		}
	}

	public function readToken():String {
		skipWs();
		var start = pos;
		while (pos < b.length && !isWs(b.get(pos)))
			pos++;
		if (pos == start)
			throw new DecodeError("unexpected end of text body at " + start);
		return b.getString(start, pos - start);
	}

	public function readInt():Int {
		var t = readToken();
		var v = Std.parseInt(t);
		if (v == null)
			throw new DecodeError("expected integer, got '" + t + "' before " + pos);
		return v;
	}

	// Raw bytes (resource data); the cursor must already be aligned (alignData).
	public function readBytes(len:Int):Bytes {
		var out = b.sub(pos, len);
		pos += len;
		return out;
	}

	// Position the cursor at the raw resource data: the last RESO header line ends with a
	// single newline, then the data blocks follow back to back (whitespace inside data is
	// data, so this must consume exactly the line terminator and nothing more).
	public function alignData():Void {
		while (pos < b.length && (b.get(pos) == " ".code || b.get(pos) == "\t".code || b.get(pos) == "\r".code))
			pos++;
		if (pos < b.length && b.get(pos) == "\n".code)
			pos++;
	}
}
