package hxia.cppia;

import haxe.io.Bytes;

// Reads the binary (CPPIB) body: a stream of varint-packed integers. Encoding (from the
// writer's binary `write`): a byte < 254 is that value; byte 254 precedes a 2-byte
// little-endian value (< 65536); byte 255 precedes a 4-byte little-endian signed value.
class BinReader {
	final b:Bytes;
	public var pos:Int;

	public function new(b:Bytes, pos:Int = 0) {
		this.b = b;
		this.pos = pos;
	}

	public inline function atEnd():Bool
		return pos >= b.length;

	public function readInt():Int {
		var b0 = b.get(pos++);
		if (b0 < 254)
			return b0;
		if (b0 == 254) {
			var v = b.get(pos) | (b.get(pos + 1) << 8);
			pos += 2;
			return v;
		}
		var v = b.get(pos) | (b.get(pos + 1) << 8) | (b.get(pos + 2) << 16) | (b.get(pos + 3) << 24);
		pos += 4;
		return v;
	}

	// Raw bytes (for resource data); advances the cursor.
	public function readBytes(len:Int):Bytes {
		var out = b.sub(pos, len);
		pos += len;
		return out;
	}
}
