package hxia.cppia;

// The cppia opcode vocabulary: the authoritative name <-> index mapping shared by the decoder and
// any re-encoder, matching hxc's CppiaWriter.opInfo. Text cppia writes the name, binary writes the
// INDEX; both denote the same op. Structural keywords (class/function/...) frame the op stream and
// are listed separately.
class OpCodes {
	// Name -> index, exactly as the writer emits.
	public static final ops:Array<{name:String, index:Int}> = [
		{name: "FUNCTION", index: 1}, {name: "VAR", index: 2}, {name: "TOINTERFACE", index: 3},
		{name: "TODYNARRAY", index: 4}, {name: "TODATAARRAY", index: 5}, {name: "TOINTERFACEARRAY", index: 6},
		{name: "FUN", index: 7}, {name: "CAST", index: 8}, {name: "BLOCK", index: 9},
		{name: "BREAK", index: 10}, {name: "CONTINUE", index: 11}, {name: "ISNULL", index: 12},
		{name: "NOTNULL", index: 13}, {name: "SET", index: 14}, {name: "CALL", index: 15},
		{name: "CALLGLOBAL", index: 16}, {name: "CALLSTATIC", index: 17}, {name: "CALLMEMBER", index: 18},
		{name: "CALLSUPER", index: 19}, {name: "CALLTHIS", index: 20}, {name: "CALLSUPERNEW", index: 21},
		{name: "CREATEENUM", index: 22}, {name: "ADEF", index: 23}, {name: "IF", index: 24},
		{name: "IFELSE", index: 25}, {name: "FNAME", index: 27}, {name: "FSTATIC", index: 28},
		{name: "FTHISINST", index: 29}, {name: "FLINK", index: 30}, {name: "FTHISNAME", index: 31},
		{name: "FENUM", index: 32}, {name: "THROW", index: 33}, {name: "ARRAYI", index: 34},
		{name: "++", index: 35}, {name: "+++", index: 36}, {name: "--", index: 37},
		{name: "---", index: 38}, {name: "NEG", index: 39}, {name: "~", index: 40},
		{name: "!", index: 41}, {name: "TVARS", index: 42}, {name: "VARDECL", index: 43},
		{name: "VARDECLI", index: 44}, {name: "NEW", index: 45}, {name: "RETURN", index: 46},
		{name: "RETVAL", index: 47}, {name: "POSINFO", index: 48}, {name: "OBJDEF", index: 49},
		{name: "CLASSOF", index: 50}, {name: "WHILE", index: 51}, {name: "FOR", index: 52},
		{name: "ENUMI", index: 53}, {name: "SWITCH", index: 54}, {name: "TRY", index: 55},
		{name: "IMPLDYNAMIC", index: 56}, {name: "i", index: 57}, {name: "f", index: 58},
		{name: "s", index: 59}, {name: "false", index: 60}, {name: "true", index: 61},
		{name: "NULL", index: 62}, {name: "THIS", index: 63}, {name: "SUPER", index: 64},
		{name: "CASTINT", index: 65}, {name: "CASTBOOL", index: 66}, {name: "INTERFACE", index: 67},
		{name: "CLASS", index: 68}, {name: "N", index: 69}, {name: "n", index: 70},
		{name: "R", index: 71}, {name: "C", index: 72}, {name: "ENUM", index: 73},
		{name: "INLINE", index: 74}, {name: "MAIN", index: 75}, {name: "NOMAIN", index: 76},
		{name: "RESOURCES", index: 77}, {name: "RESO", index: 78}, {name: "NOCAST", index: 79},
		{name: "V", index: 80}, {name: "TCAST", index: 221},
		// Binops
		{name: "+", index: 101}, {name: "*", index: 102}, {name: "/", index: 103}, {name: "-", index: 104},
		{name: "=", index: 105}, {name: "==", index: 106}, {name: "!=", index: 107}, {name: ">=", index: 108},
		{name: "<=", index: 109}, {name: ">", index: 110}, {name: "<", index: 111}, {name: "&", index: 112},
		{name: "|", index: 113}, {name: "^", index: 114}, {name: "&&", index: 115}, {name: "||", index: 116},
		{name: ">>", index: 117}, {name: ">>>", index: 118}, {name: "<<", index: 119}, {name: "%", index: 120},
		{name: "...", index: 121}, {name: "=>", index: 122}, {name: " in ", index: 123}, {name: "??", index: 124},
		// Assign-ops
		{name: "+=", index: 201}, {name: "*=", index: 202}, {name: "/=", index: 203}, {name: "-=", index: 204},
		{name: "&=", index: 212}, {name: "|=", index: 213}, {name: "^=", index: 214}, {name: "&&=", index: 215},
		{name: "||=", index: 216}, {name: ">>=", index: 217}, {name: ">>>=", index: 218}, {name: "<<=", index: 219},
		{name: "%=", index: 220},
	];

	static var byNameLut:Null<Map<String, Int>> = null;
	static var byIndexLut:Null<Map<Int, String>> = null;

	public static function byName(name:String):Null<Int> {
		if (byNameLut == null) {
			byNameLut = new Map();
			for (o in ops) byNameLut.set(o.name, o.index);
		}
		return byNameLut.exists(name) ? byNameLut.get(name) : null;
	}

	public static function byIndex(index:Int):Null<String> {
		if (byIndexLut == null) {
			byIndexLut = new Map();
			for (o in ops) byIndexLut.set(o.index, o.name);
		}
		return byIndexLut.exists(index) ? byIndexLut.get(index) : null;
	}

	public static function isOp(name:String):Bool
		return byName(name) != null;
}
