package hxc.codegen.hl;

import haxe.io.Bytes;
import hxc.codegen.hl.HlCode;

// The text dump of -D dump (dump/hlcode.txt): a port of tstr, ostr and dump in Haxe 4.3.7's hlcode.ml.
class HlDump {
	// hlcode.ml: tstr. `stack` is the virtuals being printed, so a cyclic one prints as "...".
	public static function tstr(t:HlType, ?detailed:Bool = false):String {
		return tstrIn(t, [], detailed);
	}

	static function tstrIn(t:HlType, stack:Array<HlVirtualProto>, detailed:Bool):String {
		return switch t {
			case HVoid: "void";
			case HUI8: "ui8";
			case HUI16: "ui16";
			case HI32: "i32";
			case HI64: "i64";
			case HF32: "f32";
			case HF64: "f64";
			case HBool: "bool";
			case HBytes: "bytes";
			case HDyn: "dyn";
			case HFun(args, ret): "(" + [for (a in args) tstrIn(a, stack, detailed)].join(",") + "):" + tstrIn(ret, stack, detailed);
			case HMethod(args, ret): "method:(" + [for (a in args) tstrIn(a, stack, detailed)].join(",") + "):" + tstrIn(ret, stack, detailed);
			case HObj(o) if (!detailed): o.pname;
			case HStruct(s) if (!detailed): "@" + s.pname;
			case HObj(o) | HStruct(o):
				var fields = "{" + [for (f in o.pfields) f.name + " : " + tstrIn(f.t, [], false)].join(",") + "}";
				var proto = "{" + [for (p in o.pproto) (p.fvirtual == null ? "" : "virtual ") + p.fname + "@" + p.fmethod].join(",") + "}";
				var str = o.pname + "[" + (o.psuper == null ? "" : ">" + o.psuper.pname + " ") + "fields=" + fields + " proto=" + proto + "]";
				t.match(HObj(_)) ? str : "@" + str;
			case HArray: "array";
			case HType: "type";
			case HRef(t): "ref(" + tstrIn(t, [], false) + ")";
			case HVirtual(v) if (stack.indexOf(v) >= 0): "...";
			case HVirtual(v): "virtual(" + [for (f in v.vfields) f.name + ":" + tstrIn(f.t, [v].concat(stack), false)].join(",") + ")";
			case HDynObj: "dynobj";
			case HAbstract(s, _): "abstract(" + s + ")";
			case HEnum(e) if (e.eid == 0): "enum(" + [for (p in e.efields[0].t) tstrIn(p, [], false)].join(",") + ")";
			case HEnum(e): "enum(" + e.ename + ")";
			case HNull(t): "null(" + tstrIn(t, [], false) + ")";
			case HPacked(t): "packed(" + tstrIn(t, [], false) + ")";
		}
	}

	static function regs(a:Array<Int>):String {
		return a.join(",");
	}

	// hlcode.ml: ostr
	public static function ostr(fstr:Int->String, o:HlOp):String {
		return switch o {
			case OMov(a, b): 'mov $a,$b';
			case OInt(r, i): 'int $r,@$i';
			case OFloat(r, i): 'float $r,@$i';
			case OString(r, s): 'string $r,@$s';
			case OBytes(r, s): 'bytes $r,@$s';
			case OBool(r, b): b ? 'true $r' : 'false $r';
			case ONull(r): 'null $r';
			case OAdd(r, a, b): 'add $r,$a,$b';
			case OSub(r, a, b): 'sub $r,$a,$b';
			case OMul(r, a, b): 'mul $r,$a,$b';
			case OSDiv(r, a, b): 'sdiv $r,$a,$b';
			case OUDiv(r, a, b): 'udiv $r,$a,$b';
			case OSMod(r, a, b): 'smod $r,$a,$b';
			case OUMod(r, a, b): 'umod $r,$a,$b';
			case OShl(r, a, b): 'shl $r,$a,$b';
			case OSShr(r, a, b): 'sshr $r,$a,$b';
			case OUShr(r, a, b): 'ushr $r,$a,$b';
			case OAnd(r, a, b): 'and $r,$a,$b';
			case OOr(r, a, b): 'or $r,$a,$b';
			case OXor(r, a, b): 'xor $r,$a,$b';
			case ONeg(r, v): 'neg $r,$v';
			case ONot(r, v): 'not $r,$v';
			case OIncr(r): 'incr $r';
			case ODecr(r): 'decr $r';
			case OCall0(r, g): 'call $r, ${fstr(g)}()';
			case OCall1(r, g, a): 'call $r, ${fstr(g)}($a)';
			case OCall2(r, g, a, b): 'call $r, ${fstr(g)}($a,$b)';
			case OCall3(r, g, a, b, c): 'call $r, ${fstr(g)}($a,$b,$c)';
			case OCall4(r, g, a, b, c, d): 'call $r, ${fstr(g)}($a,$b,$c,$d)';
			case OCallN(r, g, rl): 'call $r, ${fstr(g)}(${regs(rl)})';
			case OCallMethod(_, _, []): "callmethod ???";
			case OCallMethod(r, f, rl): 'callmethod $r, ${rl[0]}[$f](${regs(rl.slice(1))})';
			case OCallClosure(r, f, rl): 'callclosure $r, $f(${regs(rl)})';
			case OCallThis(r, f, rl): 'callthis $r, [$f](${regs(rl)})';
			case OStaticClosure(r, f): 'staticclosure $r, ${fstr(f)}';
			case OInstanceClosure(r, f, v): 'instanceclosure $r, ${fstr(f)}($v)';
			case OGetGlobal(r, g): 'global $r, $g';
			case OSetGlobal(g, r): 'setglobal $g, $r';
			case ORet(r): 'ret $r';
			case OJTrue(r, d): 'jtrue $r,$d';
			case OJFalse(r, d): 'jfalse $r,$d';
			case OJNull(r, d): 'jnull $r,$d';
			case OJNotNull(r, d): 'jnotnull $r,$d';
			case OJSLt(a, b, i): 'jslt $a,$b,$i';
			case OJSGte(a, b, i): 'jsgte $a,$b,$i';
			case OJSGt(r, a, b): 'jsgt $r,$a,$b';
			case OJSLte(r, a, b): 'jslte $r,$a,$b';
			case OJULt(a, b, i): 'jult $a,$b,$i';
			case OJUGte(a, b, i): 'jugte $a,$b,$i';
			case OJNotLt(a, b, i): 'jnotlt $a,$b,$i';
			case OJNotGte(a, b, i): 'jnotgte $a,$b,$i';
			case OJEq(a, b, i): 'jeq $a,$b,$i';
			case OJNotEq(a, b, i): 'jnoteq $a,$b,$i';
			case OJAlways(d): 'jalways $d';
			case OToDyn(r, a): 'todyn $r,$a';
			case OToSFloat(r, a): 'tosfloat $r,$a';
			case OToUFloat(r, a): 'toufloat $r,$a';
			case OToInt(r, a): 'toint $r,$a';
			case OLabel(_): "label";
			case ONew(r): 'new $r';
			case OField(r, o, i): 'field $r,$o[$i]';
			case OVirtualClosure(r, o, m): 'virtualclosure $r,$o[$m]';
			case OSetField(o, i, r): 'setfield $o[$i],$r';
			case OGetThis(r, i): 'getthis $r,[$i]';
			case OSetThis(i, r): 'setthis [$i],$r';
			case OThrow(r): 'throw $r';
			case ORethrow(r): 'rethrow $r';
			case OGetUI8(r, b, p): 'getui8 $r,$b[$p]';
			case OGetUI16(r, b, p): 'getui16 $r,$b[$p]';
			case OGetMem(r, b, p): 'getmem $r,$b[$p]';
			case OGetArray(r, a, i): 'getarray $r,$a[$i]';
			case OSetUI8(r, p, v): 'setui8 $r,$p,$v';
			case OSetUI16(r, p, v): 'setui16 $r,$p,$v';
			case OSetMem(r, p, v): 'setmem $r,$p,$v';
			case OSetArray(a, i, v): 'setarray $a[$i],$v';
			case OSafeCast(r, v): 'safecast $r,$v';
			case OUnsafeCast(r, v): 'unsafecast $r,$v';
			case OArraySize(r, a): 'arraysize $r,$a';
			case OType(r, t): 'type $r,${tstr(t)}';
			case OGetType(r, v): 'gettype $r,$v';
			case OGetTID(r, v): 'gettid $r,$v';
			case ORef(r, v): 'ref $r,&$v';
			case OUnref(v, r): 'unref $v,*$r';
			case OSetref(r, v): 'setref *$r,$v';
			case OToVirtual(r, v): 'tovirtual $r,$v';
			case ODynGet(r, o, f): 'dynget $r,$o[@$f]';
			case ODynSet(o, f, v): 'dynset $o[@$f],$v';
			case OMakeEnum(r, e, pl): 'makeenum $r, $e(${regs(pl)})';
			case OEnumAlloc(r, e): 'enumalloc $r, $e';
			case OEnumIndex(r, e): 'enumindex $r, $e';
			case OEnumField(r, e, i, n): 'enumfield $r, $e[$i:$n]';
			case OSetEnumField(e, i, r): 'setenumfield $e[$i], $r';
			case OSwitch(r, idx, eend): 'switch $r [${regs(idx)}] $eend';
			case ONullCheck(r): 'nullcheck $r';
			case OTrap(r, i): 'trap $r, $i';
			case OEndTrap(b): 'endtrap $b';
			case OAssert(_): "assert";
			case ORefData(r, d): 'refdata $r, $d';
			case ORefOffset(r, r2, off): 'refoffset $r, $r2, $off';
			case ONop(s): s == "" ? "nop" : "nop " + s;
		}
	}

	// hlcode.ml: fundecl_name
	public static function fundeclName(f:HlFunction):String {
		return f.fpath.name == "" ? "fun$" + f.findex : f.fpath.cls + "." + f.fpath.name;
	}

	// OCaml's String.escaped, on the UTF-8 bytes of the string
	public static function escaped(s:String):String
		return escapedBytes(Bytes.ofString(s));

	// String.escaped on bytes that need not be whole UTF-8 (hl2c escapes a string's first 60 bytes).
	public static function escapedBytes(b:Bytes):String {
		var out = new StringBuf();
		for (i in 0...b.length) {
			var c = b.get(i);
			switch c {
				case 0x22: out.add("\\\"");
				case 0x5C: out.add("\\\\");
				case 0x0A: out.add("\\n");
				case 0x09: out.add("\\t");
				case 0x0D: out.add("\\r");
				case 0x08: out.add("\\b");
				case _ if (c >= 0x20 && c <= 0x7E): out.addChar(c);
				case _: out.add("\\" + StringTools.lpad(Std.string(c), "0", 3));
			}
		}
		return out.toString();
	}

	// OCaml's string_of_float: "%.12g", and a "." when that reads as an integer (valid_float_lexem)
	static function stringOfFloat(f:Float):String {
		var s = formatG12(f);
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			if (!((c >= "0".code && c <= "9".code) || c == "-".code)) return s;
		}
		return s + ".";
	}

	static function isWindows():Bool {
		#if sys
		return Sys.systemName() == "Windows";
		#else
		return false;
		#end
	}

	// C's "%.12g". Std.string gives enough decimal digits to round from; ties and the 17th digit never
	// matter at 12 significant digits for the doubles a program holds.
	static function formatG12(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (!Math.isFinite(f)) return f < 0 ? "-inf" : "inf";
		var neg = f < 0 || (f == 0 && 1 / f < 0);
		if (f == 0) return neg ? "-0" : "0";
		var src = Std.string(Math.abs(f)).toLowerCase();
		var e = src.indexOf("e");
		var exp10 = 0;
		if (e >= 0) {
			exp10 = Std.parseInt(src.substr(e + 1));
			src = src.substr(0, e);
		}
		var dot = src.indexOf(".");
		var digits = dot < 0 ? src : src.substr(0, dot) + src.substr(dot + 1);
		// the decimal point sits after intLen digits of `digits`
		var pointAt = (dot < 0 ? src.length : dot) + exp10;
		var lead = 0;
		while (lead < digits.length - 1 && digits.charAt(lead) == "0") lead++;
		digits = digits.substr(lead);
		pointAt -= lead;
		if (digits.length > 12) {
			var up = digits.charCodeAt(12) >= "5".code;
			var d = [for (i in 0...12) digits.charCodeAt(i) - "0".code];
			if (up) {
				var i = 11;
				while (i >= 0) {
					if (d[i] == 9) {
						d[i] = 0;
						i--;
					} else {
						d[i]++;
						break;
					}
				}
				if (i < 0) {
					d.unshift(1);
					d.pop();
					pointAt++;
				}
			}
			digits = d.join("");
		}
		var end = digits.length;
		while (end > 1 && digits.charAt(end - 1) == "0") end--;
		digits = digits.substr(0, end);
		var x = pointAt - 1; // the scientific exponent
		var out:String;
		if (x < -4 || x >= 12) {
			var ex = Std.string(x < 0 ? -x : x);
			// OCaml's printf is the C runtime's: the Windows one pads the exponent to three digits
			while (ex.length < (isWindows() ? 3 : 2)) ex = "0" + ex;
			out = digits.charAt(0) + (digits.length > 1 ? "." + digits.substr(1) : "") + "e" + (x < 0 ? "-" : "+") + ex;
		} else if (x >= 0) {
			out = digits.length <= x + 1 ? digits + StringTools.rpad("", "0", x + 1 - digits.length) : digits.substr(0, x + 1) + "." + digits.substr(x + 1);
		} else {
			out = "0." + StringTools.rpad("", "0", -x - 1) + digits;
		}
		return neg ? "-" + out : out;
	}

	// hlcode.ml: dump
	public static function dump(pr:String->Void, code:HlCodeData):Void {
		var allProtos = new Map<String, HlClassProto>();
		var protoOrder = new HlHashOrder();
		var funnames = new Map<Int, String>();
		// the dump's own tstr notes the object types it prints at the top level (not the ones nested in a
		// type, and not the struct ones)
		function tstrNoting(t:HlType):String {
			switch t {
				case HObj(p):
					if (!allProtos.exists(p.pname)) protoOrder.add(p.pname);
					allProtos.set(p.pname, p);
				case _:
			}
			return tstr(t);
		}
		function str(idx:Int):String {
			return idx >= 0 && idx < code.strings.length ? code.strings[idx] : "INVALID:" + idx;
		}
		function fstr(fid:Int):String {
			var n = funnames.get(fid);
			return n != null ? n : "f@" + StringTools.hex(fid);
		}
		function debugInfos(file:Int, line:Int):String {
			return (file >= 0 && file < code.debugfiles.length ? code.debugfiles[file] : "???") + ":" + line;
		}
		pr("hl v" + code.version);
		pr("entry @" + code.entrypoint);
		pr(code.strings.length + " strings");
		for (i in 0...code.strings.length) pr("\t@" + i + " : " + escaped(code.strings[i]));
		pr(code.bytes.length + " bytes");
		for (i in 0...code.bytes.length) pr("\t@" + i + " : " + code.bytes[i].length);
		pr(code.ints.length + " ints");
		for (i in 0...code.ints.length) pr("\t@" + i + " : " + code.ints[i]);
		pr(code.floats.length + " floats");
		for (i in 0...code.floats.length) pr("\t@" + i + " : " + stringOfFloat(code.floats[i]));
		pr(code.globals.length + " globals");
		for (i in 0...code.globals.length) pr("\t@" + i + " : " + tstrNoting(code.globals[i]));
		pr(code.natives.length + " natives");
		for (n in code.natives) {
			pr("\t@" + n.findex + " native " + str(n.lib) + "@" + str(n.name) + " " + tstrNoting(n.t));
			funnames.set(n.findex, str(n.lib) + "@" + str(n.name));
		}
		for (f in code.functions) funnames.set(f.findex, fundeclName(f));
		pr(code.functions.length + " functions");
		for (f in code.functions) {
			pr("\tfun@" + f.findex + "(" + StringTools.hex(f.findex) + "h) " + tstrNoting(f.ftype));
			var first = f.debug.length > 0 ? f.debug[0] : {file: 0, line: 0};
			var curFid = first.file;
			pr("\t; " + debugInfos(first.file, first.line) + " (" + fundeclName(f) + ")");
			for (i in 0...f.regs.length) pr("\t\tr" + i + " " + tstrNoting(f.regs[i]));
			for (i in 0...f.code.length) {
				var d = i < f.debug.length ? f.debug[i] : {file: 0, line: 0};
				if (d.file != curFid) {
					curFid = d.file;
					pr("\t; " + debugInfos(d.file, d.line));
				}
				pr("\t\t." + StringTools.rpad(Std.string(d.line), " ", 5) + " @" + StringTools.hex(i) + " " + ostr(fstr, f.code[i]));
			}
		}
		// Hashtbl.fold (fun _ p acc -> p :: acc): the bucket walk, reversed
		var names = protoOrder.visitOrder();
		names.reverse();
		pr(names.length + " objects protos");
		for (name in names) {
			var p = allProtos.get(name);
			pr("\t" + p.pname + " " + (p.pclassglobal == null ? "no global" : "@" + p.pclassglobal));
			if (p.psuper != null) pr("\t\textends " + p.psuper.pname);
			pr("\t\t" + p.pfields.length + " fields");
			var startField = 0;
			var s = p.psuper;
			while (s != null) {
				startField += s.pfields.length;
				s = s.psuper;
			}
			for (i in 0...p.pfields.length) pr("\t\t  @" + (i + startField) + " " + str(p.pfields[i].nameIndex) + " " + tstrNoting(p.pfields[i].t));
			pr("\t\t" + p.pproto.length + " methods");
			for (i in 0...p.pproto.length) {
				var f = p.pproto[i];
				pr("\t\t  @" + i + " " + str(f.fid) + " fun@" + f.fmethod + (f.fvirtual == null ? "" : "[" + f.fvirtual + "]"));
			}
			pr("\t\t" + p.pbindings.length + " bindings");
			for (b in p.pbindings) pr("\t\t  @" + b.fid + " fun@" + b.fidx);
		}
		pr(code.constants.length + " constant values");
		for (c in code.constants) pr("    @" + c.global + " " + tstrNoting(code.globals[c.global]) + " [" + c.fields.join(",") + "]");
	}
}

// OCaml's Hashtbl as dump uses it to collect object protos (Hashtbl.create 0 on string keys): the bucket
// walk order. hash is Hashtbl.hash (caml_hash on a string): one string mix from seed 0, then the final
// avalanche, masked to 30 bits. Create rounds the capacity to 16, add prepends into bucket hash &
// (capacity - 1) and doubles when the size exceeds twice the capacity (a resize keeps the relative order
// within a bucket), replacing a key keeps its position, and fold visits buckets ascending, each front to
// back. This is hxc.core.NameHash.stringHash and HashTableOrder, copied because those pull in the rest of
// hxc.core and this package must stand alone; the hash itself is HlcOcaml's.
class HlHashOrder {
	var cap = 16;
	var size = 0;
	var buckets:Array<Array<{hash:Int, key:String}>> = [for (_ in 0...16) []];

	public function new() {}

	public function add(key:String):Void {
		var hash = stringHash(key);
		buckets[hash & (cap - 1)].unshift({hash: hash, key: key});
		size++;
		if (size > cap << 1) resize();
	}

	function resize():Void {
		var ncap = cap << 1;
		var nb:Array<Array<{hash:Int, key:String}>> = [for (_ in 0...ncap) []];
		for (b in buckets) for (e in b) nb[e.hash & (ncap - 1)].push(e);
		cap = ncap;
		buckets = nb;
	}

	public function visitOrder():Array<String> {
		var out:Array<String> = [];
		for (b in buckets) for (e in b) out.push(e.key);
		return out;
	}

	// Hashtbl.hash on a string: HlcOcaml's caml_hash mixing, from seed 0.
	public static function stringHash(s:String):Int
		return HlcOcaml.finalMix(HlcOcaml.mixString(0, Bytes.ofString(s))) & 0x3FFFFFFF;
}
