package hxia.cppia;

import haxe.io.Bytes;

// Renders a ModuleIR to readable, diff-friendly text: the string and type tables as
// indexed lines, the class count, and the body. For a text (CPPIA) artifact the body is
// already human-readable and is emitted verbatim; for a binary (CPPIB) artifact the body
// is summarized, not decoded. Dumping two artifacts and diffing them is the differential
// tool for cppia output.
class Dump {
	public static function text(m:ModuleIR, includeBody:Bool = true):String {
		var sb = new StringBuf();
		sb.add("magic " + m.magic + "\n");
		sb.add("strings " + m.strings.length + "\n");
		for (i in 0...m.strings.length)
			sb.add("  [" + i + "] " + show(m.strings[i]) + "\n");
		sb.add("types " + m.types.length + "\n");
		for (i in 0...m.types.length)
			sb.add("  [" + i + "] " + show(m.types[i]) + "\n");
		sb.add("classes " + m.classCount + "\n");
		if (includeBody) {
			if (m.isBinary())
				sb.add("body " + m.body.length + " bytes (binary; opcode decode is a later phase)\n");
			else
				sb.add("body (text, " + m.body.length + " bytes):\n" + m.body.getString(0, m.body.length));
		} else {
			sb.add("body " + m.body.length + " bytes\n");
		}
		return sb.toString();
	}

	// A tables-only dump (no body) for a quick structural diff of two artifacts.
	public static function tables(m:ModuleIR):String
		return text(m, false);

	// Escape control bytes so a table entry stays on one readable line.
	static function show(b:Bytes):String {
		var sb = new StringBuf();
		sb.add("\"");
		for (i in 0...b.length) {
			var c = b.get(i);
			switch (c) {
				case 0x5C: sb.add("\\\\");
				case 0x09: sb.add("\\t");
				case 0x0A: sb.add("\\n");
				case 0x0D: sb.add("\\r");
				case 0x22: sb.add("\\\"");
				case _ if (c < 0x20): sb.add("\\x" + StringTools.hex(c, 2));
				case _: sb.addChar(c);
			}
		}
		sb.add("\"");
		return sb.toString();
	}
}
