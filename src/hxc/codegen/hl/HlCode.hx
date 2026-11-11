package hxc.codegen.hl;

// The HashLink code model: a port of the types in Haxe 4.3.7's hlcode.ml (ttype and its protos, opcode,
// fundecl, code). OCaml lists become arrays, tuples become anonymous structures, `string index` fields
// keep their Int and (where hlcode.ml has the name too) the String beside it.

// nameOrigin stands for the OCaml string `name` is: two fields with the same origin hold one physical string,
// which hl2c's Marshal of a type description writes once (HlcOcaml.fieldTuple). A vfield's is its class
// field's TypeFunctions.nameOrigin; null gives the field a string of its own.
typedef HlField = {name:String, nameIndex:Int, t:HlType, ?nameOrigin:{}};

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
	// in the order of genhl's PMap.add calls; one that replaces an equal key keeps the first one's place
	pinterfaces:Array<{t:HlType, index:Int}>,
	pbindings:Array<{fid:Int, fidx:Int}>,
	// genhl's PMap.add calls on pindex and pfunctions, in order, for hl2c's type digest (HlcOcaml models the
	// maps from them). HlTypes.classType keeps them; a proto made elsewhere has none, and its maps stay
	// unmodelled.
	?pindexAdds:Array<HlPMapAdd>,
	?pfunctionsAdds:Array<HlPMapAdd>
}

// One PMap.add on a class proto's pindex (value (index, t)) or pfunctions (value index; t unused). The key is
// `name`, the OCaml string nameOrigin stands for (see HlField).
typedef HlPMapAdd = {name:String, nameOrigin:{}, index:Int, t:HlType}

// hlcode.ml: enum_proto
typedef HlEnumProto = {
	ename:String,
	eid:Int,
	eglobal:Null<Int>,
	efields:Array<{name:String, nameIndex:Int, t:Array<HlType>}>
}

// hlcode.ml: field_proto. nameOrigin stands for the OCaml string fname is, as in HlField.
typedef HlFieldProto = {
	fname:String,
	fid:Int,
	fmethod:Int,
	fvirtual:Null<Int>,
	?nameOrigin:{}
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
// OCaml table is a PMap under polymorphic compare: equal for the same physical value, otherwise field by field.
// So an object or enum is its (pname, pid) / (ename, eid), and everything else is structural. A virtual can
// reach itself (a recursive typedef), and there compare stops only at physically equal values: when it ends
// with 0 the two types unfold to the same infinite tree, so two separately built virtuals with the same
// unfolding share one index even when their cycles are shaped differently (a virtual whose `next` is
// another copy of itself equals that copy). The key below is that unfolding cut at a fixed depth, and
// `same` settles the types under one key by comparing them coinductively.
class HlTypeTable {
	public var types(default, null):Array<HlType> = [];

	// key -> indices of the types under it
	var index = new Map<String, Array<Int>>();

	// how many virtuals (or unnamed enums) deep the key looks before cutting
	static inline var KEY_DEPTH = 3;

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

	public static function key(t:HlType, depth:Int):String {
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
			case HFun(args, ret): "F(" + [for (a in args) key(a, depth)].join(",") + ")" + key(ret, depth);
			case HMethod(args, ret): "M(" + [for (a in args) key(a, depth)].join(",") + ")" + key(ret, depth);
			case HObj(p): "O" + p.pid + ":" + p.pname;
			case HStruct(p): "S" + p.pid + ":" + p.pname;
			case HArray: "a";
			case HType: "t";
			case HRef(t): "R" + key(t, depth);
			case HVirtual(_) if (depth >= KEY_DEPTH): "V~";
			case HVirtual(v): "V(" + [for (f in v.vfields) f.name + ":" + f.nameIndex + ":" + key(f.t, depth + 1)].join(",") + ")";
			case HDynObj: "o";
			case HAbstract(name, i): "A" + i + ":" + name;
			case HEnum(e) if (e.eid != 0): "E" + e.eid + ":" + e.ename;
			// eid 0 is not unique (the unnamed enums closures use), so the rest is compared too
			case HEnum(_) if (depth >= KEY_DEPTH): "E~";
			case HEnum(e):
				"E0(" + e.eglobal + ":" + [for (f in e.efields) f.name + ":" + f.nameIndex + ":" + [for (t in f.t) key(t, depth + 1)].join("+")].join(",") + ")";
			case HNull(t): "N" + key(t, depth);
			case HPacked(t): "P" + key(t, depth);
		}
	}

	// Whether OCaml's compare finds a and b equal (when it ends): a pair of virtuals or unnamed enums is
	// assumed equal while their fields are compared, which is where compare would meet the same pair again.
	public static function same(a:HlType, b:HlType, assumed:Array<Array<Dynamic>>):Bool {
		return switch [a, b] {
			case [HFun(a1, r1), HFun(a2, r2)] | [HMethod(a1, r1), HMethod(a2, r2)]:
				if (a1.length != a2.length) return false;
				for (i in 0...a1.length) if (!same(a1[i], a2[i], assumed)) return false;
				same(r1, r2, assumed);
			case [HObj(p1), HObj(p2)] | [HStruct(p1), HStruct(p2)]:
				p1.pid == p2.pid && p1.pname == p2.pname;
			case [HRef(t1), HRef(t2)] | [HNull(t1), HNull(t2)] | [HPacked(t1), HPacked(t2)]:
				same(t1, t2, assumed);
			case [HVirtual(v1), HVirtual(v2)]:
				if (v1 == v2) return true;
				for (p in assumed) if (p[0] == v1 && p[1] == v2) return true;
				if (v1.vfields.length != v2.vfields.length) return false;
				assumed.push([v1, v2]);
				for (i in 0...v1.vfields.length) {
					var f1 = v1.vfields[i], f2 = v2.vfields[i];
					if (f1.name != f2.name || f1.nameIndex != f2.nameIndex || !same(f1.t, f2.t, assumed)) return false;
				}
				true;
			case [HAbstract(n1, i1), HAbstract(n2, i2)]:
				n1 == n2 && i1 == i2;
			case [HEnum(e1), HEnum(e2)]:
				if (e1 == e2) return true;
				if (e1.eid != 0 || e2.eid != 0) return e1.eid == e2.eid && e1.ename == e2.ename;
				for (p in assumed) if (p[0] == e1 && p[1] == e2) return true;
				if (e1.ename != e2.ename || e1.eglobal != e2.eglobal || e1.efields.length != e2.efields.length) return false;
				assumed.push([e1, e2]);
				for (i in 0...e1.efields.length) {
					var f1 = e1.efields[i], f2 = e2.efields[i];
					if (f1.name != f2.name || f1.nameIndex != f2.nameIndex || f1.t.length != f2.t.length) return false;
					for (j in 0...f1.t.length) if (!same(f1.t[j], f2.t[j], assumed)) return false;
				}
				true;
			case _:
				// the constructors without arguments
				a.getIndex() == b.getIndex() && a.getParameters().length == 0;
		}
	}

	function find(t:HlType, k:String):Null<Int> {
		var bucket = index.get(k);
		if (bucket != null) for (i in bucket) if (same(types[i], t, [])) return i;
		return null;
	}

	// The index of a type the table gathered, or null.
	public function indexOf(t:HlType):Null<Int> {
		return find(t, key(t, 0));
	}

	function getType(t:HlType):Void {
		switch t {
			case HObj({psuper: p}) if (p != null): getType(HObj(p));
			case HStruct({psuper: p}) if (p != null): getType(HStruct(p));
			case _:
		}
		var k = key(t, 0);
		if (find(t, k) != null) return;
		var bucket = index.get(k);
		if (bucket == null) index.set(k, bucket = []);
		bucket.push(types.length);
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

// Functions of hlcode.ml that need nothing but the code model.
class HlCodeUtils {
	// hlcode.ml: is_dynamic
	public static function isDynamic(t:HlType):Bool {
		return switch t {
			case HDyn | HFun(_) | HObj(_) | HArray | HVirtual(_) | HDynObj | HNull(_) | HEnum(_): true;
			case _: false;
		}
	}

	// hlcode.ml: resolve_field. The field with index fid, counting from the root class's first field; null
	// where OCaml raises Not_found.
	public static function resolveField(p:HlClassProto, fid:Int):Null<HlField> {
		var pl = [];
		while (p != null) {
			pl.unshift(p);
			p = p.psuper;
		}
		for (p in pl) {
			var d = fid - p.pfields.length;
			if (d < 0) return p.pfields[fid];
			fid = d;
		}
		return null;
	}
}
