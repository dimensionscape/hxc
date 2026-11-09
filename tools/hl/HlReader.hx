import haxe.io.Bytes;
import hxc.codegen.hl.HlCode;

// A .hl reader, the mirror of HlWriter (and of HashLink's src/code.c), used only to check the writer
// against files Haxe wrote. It keeps what the writer needs and the dump prints; ONop strings are not in a
// file, and pindex, pfunctions and pinterfaces (lookups only) are left empty.
class HlReader {
	var b:Bytes;
	var pos = 0;

	function new(b:Bytes) {
		this.b = b;
	}

	// A file does not hold function names (fpath), which the dump prints: funNames, when given, maps a
	// function index to the name the dump shows (HlDump.fundeclName), and is split back into an fpath.
	public static function read(bytes:Bytes, ?funNames:Map<Int, String>):{code:HlCodeData, debug:Bool} {
		var r = new HlReader(bytes).readCode();
		if (funNames != null) for (f in r.code.functions) {
			var n = funNames.get(f.findex);
			if (n == null || n == "fun$" + f.findex) continue;
			var dot = n.lastIndexOf(".");
			f.fpath = {cls: n.substr(0, dot < 0 ? 0 : dot), name: dot < 0 ? n : n.substr(dot + 1)};
		}
		return r;
	}

	inline function byte():Int {
		if (pos >= b.length) throw "no more data";
		return b.get(pos++);
	}

	function readI32():Int {
		var a = byte(), c = byte(), d = byte(), e = byte();
		return a | (c << 8) | (d << 16) | (e << 24);
	}

	function readDouble():Float {
		var f = b.getDouble(pos);
		pos += 8;
		return f;
	}

	// hl_read_index
	function index():Int {
		var c = byte();
		if (c & 0x80 == 0) return c & 0x7F;
		if (c & 0x40 == 0) {
			var v = byte() | ((c & 31) << 8);
			return c & 0x20 == 0 ? v : -v;
		}
		var d = byte(), e = byte(), f = byte();
		var v = ((c & 31) << 24) | (d << 16) | (e << 8) | f;
		return c & 0x20 == 0 ? v : -v;
	}

	function readStrings(n:Int):Array<String> {
		var size = readI32();
		var base = pos;
		pos += size;
		var out = [];
		var p = base;
		for (_ in 0...n) {
			var len = index();
			out.push(b.getString(p, len));
			p += len + 1;
		}
		return out;
	}

	// hl_read_debug_infos
	function readDebugInfos(nops:Int):Array<{file:Int, line:Int}> {
		var curfile = -1, curline = 0;
		var out = [];
		while (out.length < nops) {
			var c = byte();
			if (c & 1 != 0) {
				curfile = ((c >> 1) << 8) | byte();
			} else if (c & 2 != 0) {
				var delta = c >> 6;
				var count = (c >> 2) & 15;
				for (_ in 0...count) out.push({file: curfile, line: curline});
				curline += delta;
			} else if (c & 4 != 0) {
				curline += c >> 3;
				out.push({file: curfile, line: curline});
			} else {
				var b2 = byte(), b3 = byte();
				curline = (c >> 3) | (b2 << 5) | (b3 << 13);
				out.push({file: curfile, line: curline});
			}
		}
		return out;
	}

	function readCode():{code:HlCodeData, debug:Bool} {
		if (byte() != "H".code || byte() != "L".code || byte() != "B".code) throw "invalid HL bytecode header";
		var version = byte();
		var flags = index();
		var nints = index();
		var nfloats = index();
		var nstrings = index();
		var nbytes = version >= 5 ? index() : 0;
		var ntypes = index();
		var nglobals = index();
		var nnatives = index();
		var nfunctions = index();
		var nconstants = version >= 4 ? index() : 0;
		var entrypoint = index();
		var debug = flags & 1 != 0;
		var ints = [for (_ in 0...nints) readI32()];
		var floats = [for (_ in 0...nfloats) readDouble()];
		var strings = readStrings(nstrings);
		var bytes:Array<Bytes> = [];
		if (version >= 5) {
			var total = readI32();
			var start = pos;
			pos += total;
			var offs = [for (_ in 0...nbytes) index()];
			for (i in 0...nbytes) {
				var from = offs[i], to = i + 1 < nbytes ? offs[i + 1] : total;
				bytes.push(b.sub(start + from, to - from));
			}
		}
		var debugfiles = [];
		if (debug) {
			var n = index();
			debugfiles = readStrings(n);
		}
		var types = readTypes(ntypes, strings);
		function type():HlType {
			return types[index()];
		}
		var globals = [for (_ in 0...nglobals) type()];
		var natives = [for (_ in 0...nnatives) {
			var lib = index();
			var name = index();
			var t = type();
			{lib: lib, name: name, t: t, findex: index()};
		}];
		var functions = [];
		for (_ in 0...nfunctions) {
			var ftype = type();
			var findex = index();
			var nregs = index();
			var nops = index();
			var regs = [for (_ in 0...nregs) type()];
			var code = [for (_ in 0...nops) readOp(types)];
			var dbg = [];
			var assigns = [];
			if (debug) {
				dbg = readDebugInfos(nops);
				var na = index();
				for (_ in 0...na) {
					var name = index();
					assigns.push({name: name, reg: index() - 1});
				}
			}
			functions.push({
				fpath: {cls: "", name: ""},
				findex: findex,
				ftype: ftype,
				regs: regs,
				code: code,
				debug: dbg,
				assigns: assigns
			});
		}
		var constants = [];
		for (_ in 0...nconstants) {
			var g = index();
			var n = index();
			constants.push({global: g, fields: [for (_ in 0...n) index()]});
		}
		return {
			code: {
				version: version,
				entrypoint: entrypoint,
				strings: strings,
				ints: ints,
				floats: floats,
				bytes: bytes,
				globals: globals,
				natives: natives,
				functions: functions,
				debugfiles: debugfiles,
				constants: constants
			},
			debug: debug
		};
	}

	// hl_read_type for every type, then the types resolved: protos are created first so the types they
	// (and the function types around them) refer to can come later in the table.
	function readTypes(n:Int, strings:Array<String>):Array<HlType> {
		var raw:Array<Dynamic> = [];
		var protos:Array<Dynamic> = [];
		for (i in 0...n) {
			var kind = byte();
			var r:Dynamic = {kind: kind};
			switch kind {
				case 10, 20:
					var cnt = byte();
					r.args = [for (_ in 0...cnt) index()];
					r.ret = index();
				case 11, 21:
					r.pid = index();
					r.sup = index();
					r.global = index();
					var nfields = index();
					var nproto = index();
					var nbind = index();
					r.fields = [for (_ in 0...nfields) {
						var nm = index();
						{nameIndex: nm, t: index()};
					}];
					r.proto = [for (_ in 0...nproto) {
						var fid = index();
						var fm = index();
						{fid: fid, fmethod: fm, fvirtual: index()};
					}];
					r.bindings = [for (_ in 0...nbind) {
						var fid = index();
						{fid: fid, fidx: index()};
					}];
				case 14, 19, 22:
					r.t = index();
				case 15:
					var nfields = index();
					r.fields = [for (_ in 0...nfields) {
						var nm = index();
						{nameIndex: nm, t: index()};
					}];
				case 17:
					r.nameIndex = index();
				case 18:
					r.eid = index();
					r.global = index();
					var ncons = index();
					r.fields = [for (_ in 0...ncons) {
						var nm = index();
						var np = byte();
						{nameIndex: nm, t: [for (_ in 0...np) index()]};
					}];
				case 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 12 | 13 | 16:
				case _:
					throw "invalid type " + kind;
			}
			raw.push(r);
		}
		var resolved:Array<HlType> = [];
		var done:Array<Bool> = [for (_ in 0...n) false];
		var classProtos:Array<HlClassProto> = [];
		var enumProtos:Array<HlEnumProto> = [];
		var virtProtos:Array<HlVirtualProto> = [];
		// shells first
		for (i in 0...n) {
			var r = raw[i];
			switch (r.kind : Int) {
				case 11, 21:
					var p:HlClassProto = {
						pname: strings[r.pid],
						pid: r.pid,
						pclassglobal: r.global == 0 ? null : r.global - 1,
						psuper: null,
						pvirtuals: [],
						pproto: [for (f in (r.proto : Array<Dynamic>)) {fname: strings[f.fid], fid: f.fid, fmethod: f.fmethod, fvirtual: f.fvirtual < 0 ? null : f.fvirtual}],
						pnfields: 0,
						pfields: [],
						pindex: new Map(),
						pfunctions: new Map(),
						pinterfaces: [],
						pbindings: r.bindings
					};
					classProtos[i] = p;
					resolved[i] = r.kind == 11 ? HObj(p) : HStruct(p);
					done[i] = true;
				case 18:
					var e:HlEnumProto = {
						ename: strings[r.eid],
						eid: r.eid,
						eglobal: r.global == 0 ? null : r.global - 1,
						efields: []
					};
					enumProtos[i] = e;
					resolved[i] = HEnum(e);
					done[i] = true;
				case 15:
					var v:HlVirtualProto = {vfields: [], vindex: new Map()};
					virtProtos[i] = v;
					resolved[i] = HVirtual(v);
					done[i] = true;
				case _:
			}
		}
		function get(i:Int):HlType {
			if (done[i]) return resolved[i];
			var r = raw[i];
			var t:HlType = switch (r.kind : Int) {
				case 0: HVoid;
				case 1: HUI8;
				case 2: HUI16;
				case 3: HI32;
				case 4: HI64;
				case 5: HF32;
				case 6: HF64;
				case 7: HBool;
				case 8: HBytes;
				case 9: HDyn;
				case 10: HFun([for (a in (r.args : Array<Int>)) get(a)], get(r.ret));
				case 20: HMethod([for (a in (r.args : Array<Int>)) get(a)], get(r.ret));
				case 12: HArray;
				case 13: HType;
				case 14: HRef(get(r.t));
				case 16: HDynObj;
				case 17: HAbstract(strings[r.nameIndex], r.nameIndex);
				case 19: HNull(get(r.t));
				case 22: HPacked(get(r.t));
				case _: throw "unreachable";
			}
			resolved[i] = t;
			done[i] = true;
			return t;
		}
		for (i in 0...n) get(i);
		for (i in 0...n) {
			var r = raw[i];
			var cp = classProtos[i];
			if (cp != null) {
				if (r.sup >= 0) cp.psuper = switch resolved[r.sup] {
					case HObj(s) | HStruct(s): s;
					case _: throw "invalid super";
				}
				cp.pfields = [for (f in (r.fields : Array<Dynamic>)) {name: strings[f.nameIndex], nameIndex: f.nameIndex, t: get(f.t)}];
				cp.pnfields = cp.pfields.length;
			}
			var ep = enumProtos[i];
			if (ep != null) ep.efields = [for (f in (r.fields : Array<Dynamic>)) {name: strings[f.nameIndex], nameIndex: f.nameIndex, t: [for (t in (f.t : Array<Int>)) get(t)]}];
			var vp = virtProtos[i];
			if (vp != null) vp.vfields = [for (f in (r.fields : Array<Dynamic>)) {name: strings[f.nameIndex], nameIndex: f.nameIndex, t: get(f.t)}];
		}
		return resolved;
	}

	function regList():Array<Int> {
		var n = byte();
		return [for (_ in 0...n) index()];
	}

	// The mirror of HlWriter.writeOp (and of hl_read_opcode): the opcode number is the HlOp constructor index.
	function readOp(types:Array<HlType>):HlOp {
		var oid = byte();
		return switch oid {
			case 0: OMov(index(), index());
			case 1: OInt(index(), index());
			case 2: OFloat(index(), index());
			case 3: OBool(index(), index() != 0);
			case 4: OBytes(index(), index());
			case 5: OString(index(), index());
			case 6: ONull(index());
			case 7: OAdd(index(), index(), index());
			case 8: OSub(index(), index(), index());
			case 9: OMul(index(), index(), index());
			case 10: OSDiv(index(), index(), index());
			case 11: OUDiv(index(), index(), index());
			case 12: OSMod(index(), index(), index());
			case 13: OUMod(index(), index(), index());
			case 14: OShl(index(), index(), index());
			case 15: OSShr(index(), index(), index());
			case 16: OUShr(index(), index(), index());
			case 17: OAnd(index(), index(), index());
			case 18: OOr(index(), index(), index());
			case 19: OXor(index(), index(), index());
			case 20: ONeg(index(), index());
			case 21: ONot(index(), index());
			case 22: OIncr(index());
			case 23: ODecr(index());
			case 24: OCall0(index(), index());
			case 25: OCall1(index(), index(), index());
			case 26: OCall2(index(), index(), index(), index());
			case 27: OCall3(index(), index(), index(), index(), index());
			case 28: OCall4(index(), index(), index(), index(), index(), index());
			case 29: var r = index(), f = index(); OCallN(r, f, regList());
			case 30: var r = index(), f = index(); OCallMethod(r, f, regList());
			case 31: var r = index(), f = index(); OCallThis(r, f, regList());
			case 32: var r = index(), f = index(); OCallClosure(r, f, regList());
			case 33: OStaticClosure(index(), index());
			case 34: OInstanceClosure(index(), index(), index());
			case 35: OVirtualClosure(index(), index(), index());
			case 36: OGetGlobal(index(), index());
			case 37: OSetGlobal(index(), index());
			case 38: OField(index(), index(), index());
			case 39: OSetField(index(), index(), index());
			case 40: OGetThis(index(), index());
			case 41: OSetThis(index(), index());
			case 42: ODynGet(index(), index(), index());
			case 43: ODynSet(index(), index(), index());
			case 44: OJTrue(index(), index());
			case 45: OJFalse(index(), index());
			case 46: OJNull(index(), index());
			case 47: OJNotNull(index(), index());
			case 48: OJSLt(index(), index(), index());
			case 49: OJSGte(index(), index(), index());
			case 50: OJSGt(index(), index(), index());
			case 51: OJSLte(index(), index(), index());
			case 52: OJULt(index(), index(), index());
			case 53: OJUGte(index(), index(), index());
			case 54: OJNotLt(index(), index(), index());
			case 55: OJNotGte(index(), index(), index());
			case 56: OJEq(index(), index(), index());
			case 57: OJNotEq(index(), index(), index());
			case 58: OJAlways(index());
			case 59: OToDyn(index(), index());
			case 60: OToSFloat(index(), index());
			case 61: OToUFloat(index(), index());
			case 62: OToInt(index(), index());
			case 63: OSafeCast(index(), index());
			case 64: OUnsafeCast(index(), index());
			case 65: OToVirtual(index(), index());
			case 66: OLabel(0);
			case 67: ORet(index());
			case 68: OThrow(index());
			case 69: ORethrow(index());
			case 70:
				var r = index();
				var n = index();
				var offs = [for (_ in 0...n) index()];
				OSwitch(r, offs, index());
			case 71: ONullCheck(index());
			case 72: OTrap(index(), index());
			case 73: OEndTrap(index() != 0);
			case 74: OGetUI8(index(), index(), index());
			case 75: OGetUI16(index(), index(), index());
			case 76: OGetMem(index(), index(), index());
			case 77: OGetArray(index(), index(), index());
			case 78: OSetUI8(index(), index(), index());
			case 79: OSetUI16(index(), index(), index());
			case 80: OSetMem(index(), index(), index());
			case 81: OSetArray(index(), index(), index());
			case 82: ONew(index());
			case 83: OArraySize(index(), index());
			case 84: OType(index(), types[index()]);
			case 85: OGetType(index(), index());
			case 86: OGetTID(index(), index());
			case 87: ORef(index(), index());
			case 88: OUnref(index(), index());
			case 89: OSetref(index(), index());
			case 90: var r = index(), f = index(); OMakeEnum(r, f, regList());
			case 91: OEnumAlloc(index(), index());
			case 92: OEnumIndex(index(), index());
			case 93: OEnumField(index(), index(), index(), index());
			case 94: OSetEnumField(index(), index(), index());
			case 95: OAssert(0);
			case 96: ORefData(index(), index());
			case 97: ORefOffset(index(), index(), index());
			case 98: ONop("");
			case _: throw "invalid opcode " + oid;
		}
	}
}
