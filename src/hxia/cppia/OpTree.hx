package hxia.cppia;

// A decoded op node: the opcode name, its integer operands (ids/counts/literals, in
// emission order), and its child expressions. Generic on purpose so the whole grammar
// decodes into one shape the evaluator walks; per-op meaning is given by the opcode.
class OpNode {
	public var op:String;
	public var ints:Array<Int>;
	public var kids:Array<OpNode>;
	// Source position from a text (debug) module: string-table id of the file and 1-based
	// line. 0/0 on binary modules, which carry no positions (writer debug = asciiOut).
	public var file:Int = 0;
	public var line:Int = 0;

	public function new(op:String, ?ints:Array<Int>, ?kids:Array<OpNode>) {
		this.op = op;
		this.ints = ints == null ? [] : ints;
		this.kids = kids == null ? [] : kids;
	}
}

// A decoded field: a function (with its body op) or a var (with an optional init op).
class FieldNode {
	public var kind:String; // "function" | "var"
	public var ints:Array<Int>; // Header operands
	public var args:Array<Array<Int>>; // Per-arg [nameId, opt, type] (functions)
	public var body:Null<OpNode>;

	public function new(kind:String) {
		this.kind = kind;
		this.ints = [];
		this.args = [];
		this.body = null;
	}
}

// A decoded type declaration: a class/interface (fields) or an enum (constructors).
class DeclNode {
	public var kind:String; // "class" | "interface" | "enum"
	public var ints:Array<Int>;
	public var fields:Array<FieldNode>;
	public var enumCtors:Array<Array<Int>>;
	public var enumMeta:Null<OpNode>;

	public function new(kind:String) {
		this.kind = kind;
		this.ints = [];
		this.fields = [];
		this.enumCtors = [];
		this.enumMeta = null;
	}
}

// The whole decoded module (structural frame; body ops as trees). Resources are left as
// the raw tail offset for now.
class ModuleTree {
	public var decls:Array<DeclNode> = [];
	public var main:Null<OpNode> = null;
	public var hasMain:Bool = false;
	// Embedded resources (--resource), each {nameId into the string table, raw bytes}. Parsed from
	// the RESOURCES tail that follows MAIN/NOMAIN; names are resolved against strings in the Interp.
	public var resources:Array<{nameId:Int, data:haxe.io.Bytes}> = [];

	public function new() {}
}
