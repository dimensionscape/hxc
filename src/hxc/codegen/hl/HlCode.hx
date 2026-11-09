package hxc.codegen.hl;

// The HashLink code model: a port of the types in Haxe 4.3.7's hlcode.ml (ttype and its protos, opcode,
// fundecl, code). OCaml lists become arrays, tuples become anonymous structures, `string index` fields
// keep their Int and (where hlcode.ml has the name too) the String beside it.

typedef HlField = {name:String, nameIndex:Int, t:HlType};

// hlcode.ml: class_proto
typedef HlClassProto = {
	pname:String,
	pid:Int,
	pclassglobal:Null<Int>,
	psuper:Null<HlClassProto>,
	pvirtuals:Array<Int>,
	pproto:Array<HlFieldProto>,
	pnfields:Int,
	pfields:Array<HlField>,
	// Lookups only: nothing in genhl.ml or hlcode.ml iterates these.
	pindex:Map<String, {index:Int, t:HlType}>,
	pfunctions:Map<String, Int>,
	pinterfaces:Array<{t:HlType, index:Int}>,
	pbindings:Array<{fid:Int, fidx:Int}>
}

// hlcode.ml: enum_proto
typedef HlEnumProto = {
	ename:String,
	eid:Int,
	eglobal:Null<Int>,
	efields:Array<{name:String, nameIndex:Int, t:Array<HlType>}>
}

// hlcode.ml: field_proto
typedef HlFieldProto = {
	fname:String,
	fid:Int,
	fmethod:Int,
	fvirtual:Null<Int>
}

// hlcode.ml: virtual_proto
typedef HlVirtualProto = {
	vfields:Array<HlField>,
	vindex:Map<String, Int>
}

// hlcode.ml: ttype
enum HlType {
	HVoid;
	HUI8;
	HUI16;
	HI32;
	HI64;
	HF32;
	HF64;
	HBool;
	HBytes;
	HDyn;
	HFun(args:Array<HlType>, ret:HlType);
	HObj(p:HlClassProto);
	HArray;
	HType;
	HRef(t:HlType);
	HVirtual(v:HlVirtualProto);
	HDynObj;
	HAbstract(name:String, nameIndex:Int);
	HEnum(e:HlEnumProto);
	HNull(t:HlType);
	HMethod(args:Array<HlType>, ret:HlType);
	HStruct(p:HlClassProto);
	HPacked(t:HlType);
}

// hlcode.ml: opcode. The constructor order is the opcode number the file format uses (the writer takes it
// from the constructor index), so it must stay as hlcode.ml has it.
enum HlOp {
	// register storing
	OMov(dst:Int, src:Int);
	OInt(dst:Int, i:Int);
	OFloat(dst:Int, f:Int);
	OBool(dst:Int, b:Bool);
	OBytes(dst:Int, s:Int);
	OString(dst:Int, s:Int);
	ONull(dst:Int);
	// binops
	OAdd(dst:Int, a:Int, b:Int);
	OSub(dst:Int, a:Int, b:Int);
	OMul(dst:Int, a:Int, b:Int);
	OSDiv(dst:Int, a:Int, b:Int);
	OUDiv(dst:Int, a:Int, b:Int);
	OSMod(dst:Int, a:Int, b:Int);
	OUMod(dst:Int, a:Int, b:Int);
	OShl(dst:Int, a:Int, b:Int);
	OSShr(dst:Int, a:Int, b:Int);
	OUShr(dst:Int, a:Int, b:Int);
	OAnd(dst:Int, a:Int, b:Int);
	OOr(dst:Int, a:Int, b:Int);
	OXor(dst:Int, a:Int, b:Int);
	// unops
	ONeg(dst:Int, src:Int);
	ONot(dst:Int, src:Int);
	OIncr(r:Int);
	ODecr(r:Int);
	// calls
	OCall0(dst:Int, f:Int);
	OCall1(dst:Int, f:Int, a:Int);
	OCall2(dst:Int, f:Int, a:Int, b:Int);
	OCall3(dst:Int, f:Int, a:Int, b:Int, c:Int);
	OCall4(dst:Int, f:Int, a:Int, b:Int, c:Int, d:Int);
	OCallN(dst:Int, f:Int, args:Array<Int>);
	OCallMethod(dst:Int, field:Int, args:Array<Int>);
	OCallThis(dst:Int, field:Int, args:Array<Int>);
	OCallClosure(dst:Int, closure:Int, args:Array<Int>);
	// closures
	OStaticClosure(dst:Int, f:Int);
	OInstanceClosure(dst:Int, f:Int, obj:Int);
	OVirtualClosure(dst:Int, obj:Int, field:Int);
	// field access
	OGetGlobal(dst:Int, global:Int);
	OSetGlobal(global:Int, src:Int);
	OField(dst:Int, obj:Int, field:Int);
	OSetField(obj:Int, field:Int, src:Int);
	OGetThis(dst:Int, field:Int);
	OSetThis(field:Int, src:Int);
	ODynGet(dst:Int, obj:Int, name:Int);
	ODynSet(obj:Int, name:Int, src:Int);
	// jumps
	OJTrue(r:Int, offset:Int);
	OJFalse(r:Int, offset:Int);
	OJNull(r:Int, offset:Int);
	OJNotNull(r:Int, offset:Int);
	OJSLt(a:Int, b:Int, offset:Int);
	OJSGte(a:Int, b:Int, offset:Int);
	OJSGt(a:Int, b:Int, offset:Int);
	OJSLte(a:Int, b:Int, offset:Int);
	OJULt(a:Int, b:Int, offset:Int);
	OJUGte(a:Int, b:Int, offset:Int);
	OJNotLt(a:Int, b:Int, offset:Int);
	OJNotGte(a:Int, b:Int, offset:Int);
	OJEq(a:Int, b:Int, offset:Int);
	OJNotEq(a:Int, b:Int, offset:Int);
	OJAlways(offset:Int);
	// coerce
	OToDyn(dst:Int, src:Int);
	OToSFloat(dst:Int, src:Int);
	OToUFloat(dst:Int, src:Int);
	OToInt(dst:Int, src:Int);
	OSafeCast(dst:Int, src:Int);
	OUnsafeCast(dst:Int, src:Int);
	OToVirtual(dst:Int, src:Int);
	// control flow
	OLabel(unused:Int);
	ORet(r:Int);
	OThrow(r:Int);
	ORethrow(r:Int);
	OSwitch(r:Int, offsets:Array<Int>, eend:Int);
	ONullCheck(r:Int);
	OTrap(r:Int, offset:Int);
	OEndTrap(b:Bool);
	// memory access
	OGetUI8(dst:Int, base:Int, pos:Int);
	OGetUI16(dst:Int, base:Int, pos:Int);
	OGetMem(dst:Int, base:Int, pos:Int);
	OGetArray(dst:Int, arr:Int, index:Int);
	OSetUI8(base:Int, pos:Int, src:Int);
	OSetUI16(base:Int, pos:Int, src:Int);
	OSetMem(base:Int, pos:Int, src:Int);
	OSetArray(arr:Int, index:Int, src:Int);
	// type operations
	ONew(dst:Int);
	OArraySize(dst:Int, arr:Int);
	OType(dst:Int, t:HlType);
	OGetType(dst:Int, src:Int);
	OGetTID(dst:Int, src:Int);
	// references
	ORef(dst:Int, src:Int);
	OUnref(dst:Int, src:Int);
	OSetref(ref:Int, src:Int);
	// enums
	OMakeEnum(dst:Int, construct:Int, args:Array<Int>);
	OEnumAlloc(dst:Int, construct:Int);
	OEnumIndex(dst:Int, e:Int);
	OEnumField(dst:Int, e:Int, construct:Int, index:Int);
	OSetEnumField(e:Int, index:Int, src:Int);
	// misc
	OAssert(unused:Int);
	ORefData(dst:Int, src:Int);
	ORefOffset(dst:Int, ref:Int, offset:Int);
	ONop(s:String);
}

// hlcode.ml: fundecl
typedef HlFunction = {
	fpath:{cls:String, name:String},
	findex:Int,
	ftype:HlType,
	regs:Array<HlType>,
	code:Array<HlOp>,
	debug:Array<{file:Int, line:Int}>,
	assigns:Array<{name:Int, reg:Int}>
}

// hlcode.ml: code. ints are 32-bit values (Int32 in OCaml).
typedef HlCodeData = {
	version:Int,
	entrypoint:Int,
	strings:Array<String>,
	ints:Array<Int>,
	floats:Array<Float>,
	bytes:Array<haxe.io.Bytes>,
	globals:Array<HlType>,
	natives:Array<{lib:Int, name:Int, t:HlType, findex:Int}>,
	functions:Array<HlFunction>,
	debugfiles:Array<String>,
	constants:Array<{global:Int, fields:Array<Int>}>
}

// The type table gather_types builds: every type once, in first-visit order, and the index of each. The
// OCaml table compares types with polymorphic compare: equal for the same physical value, otherwise field
// by field. So an object or enum is its (pname, pid) / (ename, eid), a virtual is its fields compared
// element by element (two separately built equal virtuals share one index), and everything else is
// structural. The key string below encodes exactly that.
class HlTypeTable {
	public var types(default, null):Array<HlType> = [];

	var index = new Map<String, Int>();
	var virtualStack:Array<HlVirtualProto> = [];
	var enumStack:Array<HlEnumProto> = [];

	// hlcode.ml: gather_types
	public function new(code:HlCodeData) {
		for (t in [HVoid, HUI8, HUI16, HI32, HI64, HF32, HF64, HBool, HType, HDyn]) getType(t); // make sure all basic types get lower indexes
		for (g in code.globals) getType(g);
		for (n in code.natives) getType(n.t);
		for (f in code.functions) {
			getType(f.ftype);
			for (r in f.regs) getType(r);
			for (op in f.code) switch op {
				case OType(_, t): getType(t);
				case _:
			}
		}
	}

	function key(t:HlType):String {
		return switch t {
			case HVoid: "v";
			case HUI8: "1";
			case HUI16: "2";
			case HI32: "3";
			case HI64: "4";
			case HF32: "5";
			case HF64: "6";
			case HBool: "b";
			case HBytes: "B";
			case HDyn: "d";
			case HFun(args, ret): "F(" + [for (a in args) key(a)].join(",") + ")" + key(ret);
			case HMethod(args, ret): "M(" + [for (a in args) key(a)].join(",") + ")" + key(ret);
			case HObj(p): "O" + p.pid + ":" + p.pname;
			case HStruct(p): "S" + p.pid + ":" + p.pname;
			case HArray: "a";
			case HType: "t";
			case HRef(t): "R" + key(t);
			case HVirtual(v):
				// a virtual reaching itself is the same value, as with physical equality in OCaml
				var depth = virtualStack.indexOf(v);
				if (depth >= 0) return "V@" + depth;
				virtualStack.push(v);
				var k = "V(" + [for (f in v.vfields) f.name + ":" + f.nameIndex + ":" + key(f.t)].join(",") + ")";
				virtualStack.pop();
				k;
			case HDynObj: "o";
			case HAbstract(name, i): "A" + i + ":" + name;
			case HEnum(e) if (e.eid != 0): "E" + e.eid + ":" + e.ename;
			case HEnum(e):
				// eid 0 is not unique (the unnamed enums closures use), so compare the rest too
				var depth = enumStack.indexOf(e);
				if (depth >= 0) return "E@" + depth;
				enumStack.push(e);
				var k = "E0(" + e.eglobal + ":" + [for (f in e.efields) f.name + ":" + f.nameIndex + ":" + [for (t in f.t) key(t)].join("+")].join(",") + ")";
				enumStack.pop();
				k;
			case HNull(t): "N" + key(t);
			case HPacked(t): "P" + key(t);
		}
	}

	// The index of a type the table gathered, or null.
	public function indexOf(t:HlType):Null<Int> {
		return index.get(key(t));
	}

	function getType(t:HlType):Void {
		switch t {
			case HObj({psuper: p}) if (p != null): getType(HObj(p));
			case HStruct({psuper: p}) if (p != null): getType(HStruct(p));
			case _:
		}
		var k = key(t);
		if (index.exists(k)) return;
		index.set(k, types.length);
		types.push(t);
		switch t {
			case HFun(args, ret) | HMethod(args, ret):
				for (a in args) getType(a);
				getType(ret);
			case HObj(p) | HStruct(p):
				for (f in p.pfields) getType(f.t);
			case HNull(t) | HRef(t):
				getType(t);
			case HVirtual(v):
				for (f in v.vfields) getType(f.t);
			case HEnum(e):
				for (f in e.efields) for (t in f.t) getType(t);
			case _:
		}
	}
}
