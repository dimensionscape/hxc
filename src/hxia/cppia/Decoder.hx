package hxia.cppia;

import hxia.cppia.OpTree;

// Decodes a binary (CPPIB) module body into a ModuleTree: the structural frame (classes,
// interfaces, enums, main) plus each expression as an OpNode tree. The grammar is the
// reverse of the writer (CppiaWriter matchTreeExpr + the structural emitters). Most ops
// follow a regular shape (fixed int operands + fixed or count-given children); the
// irregular ones (calls with a receiver, FUN, TRY, SWITCH, OBJDEF) have dedicated code.
//
// Text (CPPIA) decoding shares this grammar through a second front-end: ops arrive as name
// tokens instead of indices, and each expression is prefixed by `fileId line` (the writer's
// debug flag equals asciiOut, so text modules always carry positions - the only place they
// exist). The one no-pos expression is a FUN argument's inline scalar default, which the
// writer emits via genExpressionOnly (CppiaWriter genFuncArgs).
class Decoder {
	final br:Null<BinReader>;
	final tr:Null<TextReader>;

	// Name -> {ints, childFromIntIndex (-1 = use fixed), fixed}
	static var regular:Map<String, {ints:Int, from:Int, fixed:Int}> = null;

	function new(br:Null<BinReader>, tr:Null<TextReader>) {
		this.br = br;
		this.tr = tr;
	}

	public static function decode(ir:ModuleIR):ModuleTree {
		return ir.isBinary()
			? new Decoder(new BinReader(ir.body), null).module(ir.classCount)
			: new Decoder(null, new TextReader(ir.body)).module(ir.classCount);
	}

	inline function readInt():Int
		return br != null ? br.readInt() : tr.readInt();

	inline function readBytes(len:Int):haxe.io.Bytes
		return br != null ? br.readBytes(len) : tr.readBytes(len);

	inline function at():Int
		return br != null ? br.pos : tr.pos;

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
			throw new DecodeError("op stream did not end at RESOURCES; got " + after + " at " + at());
		// RESOURCES <count>, then <count> RESO <nameId> <len> headers, then the raw data blocks
		// back to back (CppiaGen writes all headers first, then all data). Names are string ids.
		var count = readInt();
		var lens = [];
		for (_ in 0...count) {
			var head = readOp();
			if (head != "RESO")
				throw new DecodeError("expected RESO in resource table, got " + head + " at " + at());
			var nameId = readInt();
			var len = readInt();
			m.resources.push({nameId: nameId, data: null});
			lens.push(len);
		}
		if (tr != null)
			tr.alignData(); // Consume the last header line's terminator, then raw data
		for (i in 0...count)
			m.resources[i].data = readBytes(lens[i]);
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
		var instId = readInt();
		var superId = readInt();
		var nIfaces = readInt();
		d.ints = [instId, superId, nIfaces];
		for (_ in 0...nIfaces)
			d.ints.push(readInt());
		var fieldCount = readInt();
		for (_ in 0...fieldCount)
			d.fields.push(field(isInterface));
		return d;
	}

	function field(isInterface:Bool):FieldNode {
		var head = readOp();
		return switch (head) {
			case "FUNCTION":
				var f = new FieldNode("function");
				var isStatic = readInt(), isDyn = readInt(), nameId = readInt(), retType = readInt(), nArgs = readInt();
				f.ints = [isStatic, isDyn, nameId, retType, nArgs];
				for (_ in 0...nArgs)
					f.args.push([readInt(), readInt(), readInt()]);
				if (!isInterface)
					f.body = expr();
				f;
			case "VAR":
				var f = new FieldNode("var");
				// Static, readAcc, writeAcc, extern, nameId, type, hasExpr. The two accessors are OPS in
				// operand position (writer: op(readAcc) op(writeAcc)) - the binary form is their opcode index
				// (N=69 n=70 R=71 C=72), the text form the letter; map letters back to indices so both
				// front-ends yield the same ints.
				f.ints.push(readInt());
				for (_ in 0...2) {
					if (tr != null) {
						var tok = tr.readToken();
						var idx = OpCodes.byName(tok);
						if (idx == null)
							throw new DecodeError("unknown accessor op '" + tok + "' at " + at());
						f.ints.push(idx);
					} else {
						f.ints.push(readInt());
					}
				}
				for (_ in 0...4)
					f.ints.push(readInt());
				if (f.ints[6] == 1)
					f.body = expr();
				f;
			case "INLINE":
				// An inline var (AccInline/AccNever): a compile-time constant with no runtime
				// representation, emitted by the writer as the bare op with no operands. It has no
				// runtime field, so the interpreter ignores it; we just consume the op to keep the
				// field stream aligned (present when the driver keeps such fields, e.g. -dce std).
				new FieldNode("inline");
			case other:
				throw new DecodeError("expected FUNCTION/VAR/INLINE field, got " + other);
		};
	}

	function enumDecl():DeclNode {
		var d = new DeclNode("enum");
		var enumId = readInt();
		var nCtors = readInt();
		d.ints = [enumId, nCtors];
		for (_ in 0...nCtors) {
			var nameId = readInt();
			var nArgs = readInt();
			var ctor = [nameId, nArgs];
			for (_ in 0...nArgs) {
				ctor.push(readInt()); // Arg name id
				ctor.push(readInt()); // Arg type
			}
			d.enumCtors.push(ctor);
		}
		var metaMarker = readInt();
		if (metaMarker == 1)
			d.enumMeta = expr();
		return d;
	}

	function expr():OpNode {
		// Text modules prefix every expression with `fileId line` (the writer's expression
		// emission, genTreeExpr: beginExpr + writePos + op). Binary modules carry no positions.
		var pfile = 0, pline = 0;
		if (tr != null) {
			pfile = tr.readInt();
			pline = tr.readInt();
		}
		var n = exprBody();
		n.file = pfile;
		n.line = pline;
		return n;
	}

	// The op + operands + children, without the position prefix. Also the read for the one
	// expression the text writer emits bare: a FUN argument's inline scalar default.
	function exprBody():OpNode {
		var name = readOp();
		return switch (name) {
			// Receiver-then-args calls
			case "CALLMEMBER":
				var t = readInt(), n = readInt(), argc = readInt();
				var kids = [expr()]; // Receiver
				for (_ in 0...argc)
					kids.push(expr());
				new OpNode(name, [t, n, argc], kids);
			case "CALL":
				var argc = readInt();
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
				var count = readInt();
				var ints = [count];
				for (_ in 0...count)
					ints.push(readInt()); // Field name ids
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
			throw new DecodeError("no grammar for op '" + name + "' at " + at());
		var ints = [for (_ in 0...spec.ints) readInt()];
		var nKids = spec.from >= 0 ? ints[spec.from] : spec.fixed;
		// TVARS children are the other bare emission: the writer prints each VARDECL/
		// VARDECLI line directly (writeOp + writeVar), not through the expression emission, so they
		// carry no position prefix - while a VARDECLI's init kid does (genTreeExpr).
		var bare = name == "TVARS";
		var kids = [for (_ in 0...nKids) bare ? exprBody() : expr()];
		return new OpNode(name, ints, kids);
	}

	// FUN <type> <argc> [per arg: nameId id captured type initMarker (+const if 1)] body
	function fun():OpNode {
		var type = readInt(), argc = readInt();
		var ints = [type, argc];
		var kids = [];
		for (_ in 0...argc) {
			for (_ in 0...4)
				ints.push(readInt());            
			var marker = readInt();
			ints.push(marker);
			if (marker == 1)
				kids.push(exprBody()); // Scalar default: genExpressionOnly, no pos prefix
		}
		kids.push(expr()); // body
		return new OpNode("FUN", ints, kids);
	}

	// TRY <count> block [per catch: nameId id captured type catchBody]
	function tryOp():OpNode {
		var count = readInt();
		var ints = [count];
		var kids = [expr()]; // Guarded block
		for (_ in 0...count) {
			for (_ in 0...4)
				ints.push(readInt()); // Catch var
			kids.push(expr()); // Catch body
		}
		return new OpNode("TRY", ints, kids);
	}

	// SWITCH <caseCount> <hasDefault> cond [per case: <nValues> values... body] [default]
	function switchOp():OpNode {
		var caseCount = readInt(), hasDefault = readInt();
		var ints = [caseCount, hasDefault];
		var kids = [expr()]; // Condition
		for (_ in 0...caseCount) {
			var nValues = readInt();
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
		if (tr != null) {
			// Ops are name tokens in text mode. The one name containing spaces (" in ",
			// index 123) tokenizes to "in"; map it back so both front-ends yield the same
			// grammar keys.
			var tok = tr.readToken();
			return tok == "in" ? " in " : tok;
		}
		var here = at();
		var idx = readInt();
		var name = OpCodes.byIndex(idx);
		if (name == null)
			throw new DecodeError("unknown opcode index " + idx + " at " + here);
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
