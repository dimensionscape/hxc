package hxia.cppia;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

// Serializes a ModuleIR back to canonical cppia bytes. For an unmodified IR the output
// is byte-identical to the input (the H0 round-trip guarantee): the header is rebuilt
// from the parsed tables (each entry's recorded byte length is its content length) and
// the preserved body is appended verbatim.
class Emit {
	static inline var NL = 0x0A;
	static inline var SP = 0x20;

	public static function bytes(m:ModuleIR):Bytes {
		var buf = new BytesBuffer();
		addLine(buf, m.magic);
		addTable(buf, m.strings);
		addTable(buf, m.types);
		addLine(buf, Std.string(m.classCount));
		buf.addBytes(m.body, 0, m.body.length);
		return buf.getBytes();
	}

	static function addTable(buf:BytesBuffer, entries:Array<Bytes>):Void {
		addLine(buf, Std.string(entries.length));
		for (e in entries) {
			addAscii(buf, Std.string(e.length));
			buf.addByte(SP);
			buf.addBytes(e, 0, e.length);
			buf.addByte(NL);
		}
	}

	static function addLine(buf:BytesBuffer, s:String):Void {
		addAscii(buf, s);
		buf.addByte(NL);
	}

	static function addAscii(buf:BytesBuffer, s:String):Void {
		var b = Bytes.ofString(s);
		buf.addBytes(b, 0, b.length);
	}
}
