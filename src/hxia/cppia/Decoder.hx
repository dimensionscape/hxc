package hxia.cppia;

import hxia.cppia.OpTree;

// Decodes a binary (CPPIB) module body into a ModuleTree: the structural frame (classes,
// interfaces, enums, main) plus each expression as an OpNode tree. The grammar is the
// reverse of the writer (CppiaWriter matchTreeExpr + the structural emitters). Most ops
// follow a regular shape (fixed int operands + fixed or count-given children); the
// irregular ones (calls with a receiver, FUN, TRY, SWITCH, OBJDEF) have dedicated code.
//
// Text (CPPIA) decoding shares this grammar but needs a different front-end (names +
// POSINFO prefixes); it is a later slice. Resources (the raw tail) are not modelled here.
class Decoder {
	final r:BinReader;

	// Name -> {ints, childFromIntIndex (-1 = use fixed), fixed}
	static var regular:Map<String, {ints:Int, from:Int, fixed:Int}> = null;

	function new(r:BinReader) {
		this.r = r;
	}

	public static function decode(ir:ModuleIR):ModuleTree {
		if (!ir.isBinary())
			throw new DecodeError("Decoder handles binary (CPPIB) only for now; got " + ir.magic);
		return new Decoder(new BinReader(ir.body)).module(ir.classCount);
	}

	function module(classCount:Int):ModuleTree {
		var m = new ModuleTree();
		for (_ in 0...classCount)
			m.decls.push(decl());
		var top = readOp();
		switch (top) {
			case "MAIN": m.hasMain = true; m.main = expr();
			case "NOMAIN": m.hasMain = false;
			case other: throw new DecodeError("expected MAIN/NOMAIN, got " + other);
		}
		// Full-consumption check: the op stream ends exactly at RESOURCES. If the grammar
		// under-read anywhere, the cursor lands mid-operand and this fails.
		var after = readOp();
		if (after != "RESOURCES")
			throw new DecodeError("op stream did not end at RESOURCES; got " + after + " at " + r.pos);
		// RESOURCES <count>, then <count> RESO <nameId> <len> headers, then the raw data blocks
		// back to back (CppiaGen writes all headers first, then all data). Names are string ids.
		var count = r.readInt();
		var lens = [];
		for (_ in 0...count) {
			var head = readOp();
			if (head != "RESO")
				throw new DecodeError("expected RESO in resource table, got " + head + " at " + r.pos);
			var nameId = r.readInt();
			var len = r.readInt();
			m.resources.push({nameId: nameId, data: null});
			lens.push(len);
		}
		for (i in 0...count)
			m.resources[i].data = r.readBytes(lens[i]);
		return m;
	}

	function decl():DeclNode {
		var head = readOp();
		return switch (head) {
			case "CLASS" | "INTERFACE": classDecl(head == "INTERFACE");
			case "ENUM": enumDecl();
			case other: throw new DecodeError("expected CLASS/INTERFACE/ENUM, got " + other);
		};
	}

	function classDecl(isInterface:Bool):DeclNode {
		var d = new DeclNode(isInterface ? "interface" : "class");
		var instId = r.readInt();
		var superId = r.readInt();
		var nIfaces = r.readInt();
		d.ints = [instId, superId, nIfaces];
		for (_ in 0...nIfaces)
			d.ints.push(r.readInt());
		var fieldCount = r.readInt();
		for (_ in 0...fieldCount)
			d.fields.push(field(isInterface));
		return d;
	}

	function field(isInterface:Bool):FieldNode {
		var head = readOp();
		return switch (head) {
			case "FUNCTION":
				var f = new FieldNode("function");
				var isStatic = r.readInt(), isDyn = r.readInt(), nameId = r.readInt(), retType = r.readInt(), nArgs = r.readInt();
				f.ints = [isStatic, isDyn, nameId, retType, nArgs];
				for (_ in 0...nArgs)
					f.args.push([r.readInt(), r.readInt(), r.readInt()]);
				if (!isInterface)
					f.body = expr();
				f;
			case "VAR":
				var f = new FieldNode("var");
				// Static, readAcc, writeAcc, extern, nameId, type, hasExpr
				for (_ in 0...7)
					f.ints.push(r.readInt());
				if (f.ints[6] == 1)
					f.body = expr();
				f;
			case other:
				throw new DecodeError("expected FUNCTION/VAR field, got " + other);
		};
	}

	function enumDecl():DeclNode {
		var d = new DeclNode("enum");
		var enumId = r.readInt();
		var nCtors = r.readInt();
		d.ints = [enumId, nCtors];
		for (_ in 0...nCtors) {
			var nameId = r.readInt();
			var nArgs = r.readInt();
			var ctor = [nameId, nArgs];
			for (_ in 0...nArgs) {
				ctor.push(r.readInt()); // Arg name id
				ctor.push(r.readInt()); // Arg type
			}
			d.enumCtors.push(ctor);
		}
		var metaMarker = r.readInt();
		if (metaMarker == 1)
			d.enumMeta = expr();
		return d;
	}

	function expr():OpNode {
		var name = readOp();
		return switch (name) {
			// Receiver-then-args calls
			case "CALLMEMBER":
				var t = r.readInt(), n = r.readInt(), argc = r.readInt();
				var kids = [expr()]; // Receiver
				for (_ in 0...argc)
					kids.push(expr());
				new OpNode(name, [t, n, argc], kids);
			case "CALL":
				var argc = r.readInt();
				var kids = [expr()]; // Func
				for (_ in 0...argc)
					kids.push(expr());
				new OpNode(name, [argc], kids);
			case "FUN":
				fun();
			case "TRY":
				tryOp();
			case "SWITCH":
				switchOp();
			case "OBJDEF":
				var count = r.readInt();
				var ints = [count];
				for (_ in 0...count)
					ints.push(r.readInt()); // Field name ids
				var kids = [for (_ in 0...count) expr()];
				new OpNode(name, ints, kids);
			case _:
				regularOp(name);
		};
	}

	function regularOp(name:String):OpNode {
		if (regular == null)
			buildRegular();
		var spec = regular.get(name);
		if (spec == null)
			throw new DecodeError("no grammar for op '" + name + "' at " + r.pos);
		var ints = [for (_ in 0...spec.ints) r.readInt()];
		var nKids = spec.from >= 0 ? ints[spec.from] : spec.fixed;
		var kids = [for (_ in 0...nKids) expr()];
		return new OpNode(name, ints, kids);
	}

	// FUN <type> <argc> [per arg: nameId id captured type initMarker (+const if 1)] body
	function fun():OpNode {
		var type = r.readInt(), argc = r.readInt();
		var ints = [type, argc];
		var kids = [];
		for (_ in 0...argc) {
			for (_ in 0...4)
				ints.push(r.readInt());            
			var marker = r.readInt();
			ints.push(marker);
			if (marker == 1)
				kids.push(expr()); // Scalar default value
		}
		kids.push(expr()); // body
		return new OpNode("FUN", ints, kids);
	}

	// TRY <count> block [per catch: nameId id captured type catchBody]
	function tryOp():OpNode {
		var count = r.readInt();
		var ints = [count];
		var kids = [expr()]; // Guarded block
		for (_ in 0...count) {
			for (_ in 0...4)
				ints.push(r.readInt()); // Catch var
			kids.push(expr()); // Catch body
		}
		return new OpNode("TRY", ints, kids);
	}

	// SWITCH <caseCount> <hasDefault> cond [per case: <nValues> values... body] [default]
	function switchOp():OpNode {
		var caseCount = r.readInt(), hasDefault = r.readInt();
		var ints = [caseCount, hasDefault];
		var kids = [expr()]; // Condition
		for (_ in 0...caseCount) {
			var nValues = r.readInt();
			ints.push(nValues);
			for (_ in 0...nValues)
				kids.push(expr());
			kids.push(expr()); // Case body
		}
		if (hasDefault == 1)
			kids.push(expr());
		return new OpNode("SWITCH", ints, kids);
	}

	function readOp():String {
		var at = r.pos;
		var idx = r.readInt();
		var name = OpCodes.byIndex(idx);
		if (name == null)
			throw new DecodeError("unknown opcode index " + idx + " at " + at);
		return name;
	}

	static function buildRegular():Void {
		regular = new Map();
		inline function put(names:Array<String>, ints:Int, from:Int, fixed:Int)
			for (n in names)
				regular.set(n, {ints: ints, from: from, fixed: fixed});
		// Leaves / consts
		put(["true", "false", "NULL", "THIS", "SUPER", "BREAK", "CONTINUE", "RETURN"], 0, -1, 0);
		put(["i", "f", "s"], 1, -1, 0);
		put(["VAR"], 1, -1, 0);
		put(["CLASSOF"], 1, -1, 0);
		put(["FTHISINST", "FSTATIC", "FTHISNAME", "FENUM"], 2, -1, 0);
		put(["POSINFO"], 4, -1, 0);
		// Unary / single-child
		put(["ISNULL", "NOTNULL", "++", "+++", "--", "---", "NEG", "~", "!", "THROW", "CASTINT", "CASTBOOL", "TODYNARRAY"], 0, -1, 1);
		put(["RETVAL", "TCAST", "TODATAARRAY", "TOINTERFACEARRAY"], 1, -1, 1);
		put(["FLINK", "FNAME", "ENUMI", "TOINTERFACE"], 2, -1, 1);
		// Two-child
		put(["IF", "SET", "+", "-", "*", "/", "%", "<", ">", "<=", ">=", "==", "!=",
			"&", "|", "^", "&&", "||", ">>", ">>>", "<<", "...", "=>", " in ", "??", "=",
			"+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "&&=", "||=", ">>=", ">>>=", "<<="], 0, -1, 2);
		put(["ARRAYI"], 1, -1, 2);
		// While, if-else
		put(["WHILE"], 1, -1, 2);
		put(["IFELSE"], 0, -1, 3);
		// Counted children
		put(["BLOCK"], 1, 0, 0);
		put(["ADEF"], 2, 1, 0);
		put(["TVARS"], 1, 0, 0);
		// Var decls (inside TVARS)
		put(["VARDECL"], 4, -1, 0);
		put(["VARDECLI"], 5, -1, 1);
		// Calls without a receiver child (args counted by last int)
		put(["CALLSTATIC", "CALLTHIS", "CALLSUPER", "CREATEENUM"], 3, 2, 0);
		put(["CALLGLOBAL", "CALLSUPERNEW", "NEW"], 2, 1, 0);
	}
}

class DecodeError extends haxe.Exception {
	public function new(message:String) super(message);
}
