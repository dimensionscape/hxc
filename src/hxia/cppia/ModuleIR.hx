package hxia.cppia;

import haxe.io.Bytes;

// The parsed shape of a cppia artifact. The text header (magic, string table, type
// table, class count) is modelled structurally; the body (class defs + expression
// stream + resources) is preserved verbatim as bytes. Full opcode decoding is a later
// phase (the interpreter); H0 needs only a faithful, byte-exact structural model.
//
// String and type entries are Bytes, not String: their byte length is what the format
// records, and content may be non-ASCII, so a byte-faithful model round-trips exactly.
class ModuleIR {
	// "CPPIA" (fully text) or "CPPIB" (text header, binary body).
	public var magic:String;
	public var strings:Array<Bytes>;
	public var types:Array<Bytes>;
	public var classCount:Int;
	public var body:Bytes;

	public function new(magic:String, strings:Array<Bytes>, types:Array<Bytes>, classCount:Int, body:Bytes) {
		this.magic = magic;
		this.strings = strings;
		this.types = types;
		this.classCount = classCount;
		this.body = body;
	}

	public inline function isBinary():Bool
		return magic == "CPPIB";
}
