package hxc.codegen.hl;

import haxe.io.Bytes;
import hxc.codegen.hl.HlCode;

// The .hl bytecode writer: a port of write_index_gen and write_code in Haxe 4.3.7's genhl.ml.
class HlWriter {
	var buf:Bytes = Bytes.alloc(1 << 16);
	var pos = 0;
	var table:HlTypeTable;

	function new() {}

	// genhl.ml: write_code
	public static function write(code:HlCodeData, debug:Bool):Bytes {
		var w = new HlWriter();
		w.writeCode(code, debug);
		return w.buf.sub(0, w.pos);
	}

	function ensure(n:Int):Void {
		if (pos + n <= buf.length) return;
		var size = buf.length;
		while (pos + n > size) size *= 2;
		var nb = Bytes.alloc(size);
		nb.blit(0, buf, 0, pos);
		buf = nb;
	}

	inline function byte(b:Int):Void {
		ensure(1);
		buf.set(pos++, b & 0xFF);
	}

	// IO.write_i32 and IO.write_real_i32: four bytes, little endian
	function writeI32(v:Int):Void {
		byte(v);
		byte(v >> 8);
		byte(v >> 16);
		byte(v >>> 24);
	}

	function writeDouble(f:Float):Void {
		ensure(8);
		buf.setDouble(pos, f);
		pos += 8;
	}

	function writeBytes(b:Bytes):Void {
		ensure(b.length);
		buf.blit(pos, b, 0, b.length);
		pos += b.length;
	}

	// IO.write_string: the characters then a NUL
	function writeString(s:Bytes):Void {
		writeBytes(s);
		byte(0);
	}

	// genhl.ml: write_index_gen
	//   from -500M to +500M
	//   0[7] = 0-127
	//   10[+/-][5] [8] = -x2000/+x2000
	//   11[+/-][5] [24] = -x20000000/+x20000000
	function writeIndex(i:Int):Void {
		if (i < 0) {
			i = -i;
			if (i < 0x2000) {
				byte((i >>> 8) | 0xA0);
				byte(i & 0xFF);
			} else if (i >= 0x20000000) {
				throw "index out of range";
			} else {
				byte((i >>> 24) | 0xE0);
				byte((i >>> 16) & 0xFF);
				byte((i >>> 8) & 0xFF);
				byte(i & 0xFF);
			}
		} else if (i < 0x80) {
			byte(i);
		} else if (i < 0x2000) {
			byte((i >>> 8) | 0x80);
			byte(i & 0xFF);
		} else if (i >= 0x20000000) {
			throw "index out of range";
		} else {
			byte((i >>> 24) | 0xC0);
			byte((i >>> 16) & 0xFF);
			byte((i >>> 8) & 0xFF);
			byte(i & 0xFF);
		}
	}

	function writeType(t:HlType):Void {
		var i = table.indexOf(t);
		if (i == null) throw "type not in the type table: " + HlDump.tstr(t);
		writeIndex(i);
	}

	function writeRegs(r:Int, f:Int, rl:Array<Int>):Void {
		writeIndex(r);
		writeIndex(f);
		var n = rl.length;
		if (n > 0xFF) throw "too many arguments";
		byte(n);
		for (a in rl) writeIndex(a);
	}

	// genhl.ml: write_op. The opcode number is the constructor index, as Obj.tag is in OCaml.
	function writeOp(op:HlOp):Void {
		var oid = Type.enumIndex(op);
		byte(oid);
		switch op {
			case OLabel(_) | ONop(_) | OAssert(_):
			case OBool(r, b):
				writeIndex(r);
				writeIndex(b ? 1 : 0);
			case OEndTrap(b):
				writeIndex(b ? 1 : 0);
			case OCallN(r, f, rl) | OCallClosure(r, f, rl) | OCallMethod(r, f, rl) | OCallThis(r, f, rl) | OMakeEnum(r, f, rl):
				writeRegs(r, f, rl);
			case OType(r, t):
				writeIndex(r);
				writeType(t);
			case OSwitch(r, pl, eend):
				writeIndex(r);
				writeIndex(pl.length);
				for (p in pl) writeIndex(p);
				writeIndex(eend);
			case OCall4(a, b, c, d, e, f):
				writeIndex(a);
				writeIndex(b);
				writeIndex(c);
				writeIndex(d);
				writeIndex(e);
				writeIndex(f);
			case OCall3(a, b, c, d, e):
				writeIndex(a);
				writeIndex(b);
				writeIndex(c);
				writeIndex(d);
				writeIndex(e);
			case OCall2(a, b, c, d) | OEnumField(a, b, c, d):
				writeIndex(a);
				writeIndex(b);
				writeIndex(c);
				writeIndex(d);
			case OAdd(a, b, c) | OSub(a, b, c) | OMul(a, b, c) | OSDiv(a, b, c) | OUDiv(a, b, c) | OSMod(a, b, c) | OUMod(a, b, c) | OShl(a, b, c) | OSShr(a, b, c)
				| OUShr(a, b, c) | OAnd(a, b, c) | OOr(a, b, c) | OXor(a, b, c) | OCall1(a, b, c) | OInstanceClosure(a, b, c) | OVirtualClosure(a, b, c)
				| OField(a, b, c) | OSetField(a, b, c) | ODynGet(a, b, c) | ODynSet(a, b, c) | OJSLt(a, b, c) | OJSGte(a, b, c) | OJSGt(a, b, c) | OJSLte(a, b, c)
				| OJULt(a, b, c) | OJUGte(a, b, c) | OJNotLt(a, b, c) | OJNotGte(a, b, c) | OJEq(a, b, c) | OJNotEq(a, b, c) | OGetUI8(a, b, c) | OGetUI16(a, b, c)
				| OGetMem(a, b, c) | OGetArray(a, b, c) | OSetUI8(a, b, c) | OSetUI16(a, b, c) | OSetMem(a, b, c) | OSetArray(a, b, c) | OSetEnumField(a, b, c)
				| ORefOffset(a, b, c):
				writeIndex(a);
				writeIndex(b);
				writeIndex(c);
			case OMov(a, b) | OInt(a, b) | OFloat(a, b) | OBytes(a, b) | OString(a, b) | ONeg(a, b) | ONot(a, b) | OCall0(a, b) | OStaticClosure(a, b)
				| OGetGlobal(a, b) | OSetGlobal(a, b) | OGetThis(a, b) | OSetThis(a, b) | OJTrue(a, b) | OJFalse(a, b) | OJNull(a, b) | OJNotNull(a, b)
				| OToDyn(a, b) | OToSFloat(a, b) | OToUFloat(a, b) | OToInt(a, b) | OSafeCast(a, b) | OUnsafeCast(a, b) | OToVirtual(a, b) | OTrap(a, b)
				| OArraySize(a, b) | OGetType(a, b) | OGetTID(a, b) | ORef(a, b) | OUnref(a, b) | OSetref(a, b) | OEnumAlloc(a, b) | OEnumIndex(a, b)
				| ORefData(a, b):
				writeIndex(a);
				writeIndex(b);
			case ONull(a) | OIncr(a) | ODecr(a) | OJAlways(a) | ORet(a) | OThrow(a) | ORethrow(a) | ONullCheck(a) | ONew(a):
				writeIndex(a);
		}
	}

	// The strings table: total length, the NUL-terminated strings, then each length.
	function writeStrings(strings:Array<Bytes>):Void {
		var len = 0;
		for (s in strings) len += s.length + 1;
		writeI32(len);
		for (s in strings) writeString(s);
		for (s in strings) writeIndex(s.length);
	}

	// genhl.ml: write_debug_infos. Run-length and delta coded line numbers.
	function writeDebugInfos(debug:Array<{file:Int, line:Int}>):Void {
		var curfile = -1;
		var curpos = 0;
		var rcount = 0;
		function flushRepeat(p:Int):Void {
			while (rcount > 0) {
				if (rcount > 15) {
					byte((15 << 2) | 2);
					rcount -= 15;
				} else {
					var delta = p - curpos;
					delta = (delta > 0 && delta < 4) ? delta : 0;
					byte((delta << 6) | (rcount << 2) | 2);
					rcount = 0;
					curpos += delta;
				}
			}
		}
		for (d in debug) {
			var f = d.file, p = d.line;
			if (f != curfile) {
				flushRepeat(p);
				curfile = f;
				byte((f >>> 7) | 1);
				byte(f & 0xFF);
			}
			if (p != curpos) flushRepeat(p);
			if (p == curpos) {
				rcount++;
			} else {
				var delta = p - curpos;
				if (delta > 0 && delta < 32) {
					byte((delta << 3) | 4);
				} else {
					byte(p << 3);
					byte(p >>> 5);
					byte(p >>> 13);
				}
				curpos = p;
			}
		}
		flushRepeat(curpos);
	}

	function writeTypeDef(t:HlType):Void {
		switch t {
			case HVoid: byte(0);
			case HUI8: byte(1);
			case HUI16: byte(2);
			case HI32: byte(3);
			case HI64: byte(4);
			case HF32: byte(5);
			case HF64: byte(6);
			case HBool: byte(7);
			case HBytes: byte(8);
			case HDyn: byte(9);
			case HFun(args, ret) | HMethod(args, ret):
				if (args.length > 0xFF) throw "too many arguments";
				byte(t.match(HFun(_, _)) ? 10 : 20);
				byte(args.length);
				for (a in args) writeType(a);
				writeType(ret);
			case HObj(p) | HStruct(p):
				var isStruct = t.match(HStruct(_));
				byte(isStruct ? 21 : 11);
				writeIndex(p.pid);
				if (p.psuper == null) writeIndex(-1) else writeType(isStruct ? HStruct(p.psuper) : HObj(p.psuper));
				writeIndex(p.pclassglobal == null ? 0 : p.pclassglobal + 1);
				writeIndex(p.pfields.length);
				writeIndex(p.pproto.length);
				writeIndex(p.pbindings.length);
				for (f in p.pfields) {
					writeIndex(f.nameIndex);
					writeType(f.t);
				}
				for (f in p.pproto) {
					writeIndex(f.fid);
					writeIndex(f.fmethod);
					writeIndex(f.fvirtual == null ? -1 : f.fvirtual);
				}
				for (b in p.pbindings) {
					writeIndex(b.fid);
					writeIndex(b.fidx);
				}
			case HArray: byte(12);
			case HType: byte(13);
			case HRef(t):
				byte(14);
				writeType(t);
			case HVirtual(v):
				byte(15);
				writeIndex(v.vfields.length);
				for (f in v.vfields) {
					writeIndex(f.nameIndex);
					writeType(f.t);
				}
			case HDynObj: byte(16);
			case HAbstract(_, i):
				byte(17);
				writeIndex(i);
			case HEnum(e):
				byte(18);
				writeIndex(e.eid);
				writeIndex(e.eglobal == null ? 0 : e.eglobal + 1);
				writeIndex(e.efields.length);
				for (f in e.efields) {
					writeIndex(f.nameIndex);
					if (f.t.length > 0xFF) throw "too many enum parameters";
					byte(f.t.length);
					for (t in f.t) writeType(t);
				}
			case HNull(t):
				byte(19);
				writeType(t);
			case HPacked(t):
				byte(22);
				writeType(t);
		}
	}

	function writeCode(code:HlCodeData, debug:Bool):Void {
		table = new HlTypeTable(code);
		writeString0("HLB");
		byte(code.version);
		byte(debug ? 1 : 0);
		writeIndex(code.ints.length);
		writeIndex(code.floats.length);
		writeIndex(code.strings.length);
		if (code.version >= 5) writeIndex(code.bytes.length);
		writeIndex(table.types.length);
		writeIndex(code.globals.length);
		writeIndex(code.natives.length);
		writeIndex(code.functions.length);
		writeIndex(code.constants.length);
		writeIndex(code.entrypoint);
		for (i in code.ints) writeI32(i);
		for (f in code.floats) writeDouble(f);
		writeStrings([for (s in code.strings) Bytes.ofString(s)]);
		if (code.version >= 5) {
			var total = 0;
			for (b in code.bytes) total += b.length;
			writeI32(total);
			for (b in code.bytes) writeBytes(b);
			var p = 0;
			for (b in code.bytes) {
				writeIndex(p);
				p += b.length;
			}
		}
		if (debug) {
			writeIndex(code.debugfiles.length);
			writeStrings([for (s in code.debugfiles) Bytes.ofString(s)]);
		}
		for (t in table.types) writeTypeDef(t);
		for (g in code.globals) writeType(g);
		for (n in code.natives) {
			writeIndex(n.lib);
			writeIndex(n.name);
			writeType(n.t);
			writeIndex(n.findex);
		}
		for (f in code.functions) {
			writeType(f.ftype);
			writeIndex(f.findex);
			writeIndex(f.regs.length);
			writeIndex(f.code.length);
			for (r in f.regs) writeType(r);
			for (op in f.code) writeOp(op);
			if (debug) {
				writeDebugInfos(f.debug);
				writeIndex(f.assigns.length);
				for (a in f.assigns) {
					writeIndex(a.name);
					writeIndex(a.reg + 1);
				}
			}
		}
		for (c in code.constants) {
			writeIndex(c.global);
			writeIndex(c.fields.length);
			for (f in c.fields) writeIndex(f);
		}
	}

	// IO.nwrite_string of a plain ASCII literal
	function writeString0(s:String):Void {
		writeBytes(Bytes.ofString(s));
	}
}
