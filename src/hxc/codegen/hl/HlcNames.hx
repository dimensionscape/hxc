package hxc.codegen.hl;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlcOcaml;

// The naming, C-type and literal functions of Haxe 4.3.7's hl2c.ml (84-365, the OFloat text near 805, and
// 1100-1255): identifiers, C types, the t$ type names, the s$/g$ global names, the function table, string
// literals, field hashes and float literals. Strings are OCaml strings, so lengths, digests, comparisons and
// escapes work on their UTF-8 bytes.
// This module imports nothing from hxc outside hxc.codegen.hl, so tools/hl/HlcCheck runs it under haxe --run.

// hl2c.ml: code_module
class CodeModule {
	public final name:String;
	public var functions:Array<FunctionEntry> = [];
	public var types:Array<HlType> = [];

	public function new(name:String) {
		this.name = name;
	}
}

// hl2c.ml: function_entry. calledBy and calling are OCaml lists: index 0 is the head, the entry added last.
class FunctionEntry {
	public final index:Int;
	public var name:String = "";
	public var decl:Null<HlFunction> = null;
	public var args:Array<HlType> = [];
	public var ret:HlType = HVoid;
	public var module:Null<CodeModule> = null;
	public var calledBy:Array<FunctionEntry> = [];
	public var calling:Array<FunctionEntry> = [];

	public function new(index:Int) {
		this.index = index;
	}
}

// hl2c.ml: hash, with the context's hash_cache, hash_mem and hash_cache_list. A string's hash is hl_hash,
// moved up by one (Int32.add) while another string already holds it.
class HashCache {
	var cache = new Map<Int, Int>();
	var mem = new Map<Int, Bool>();

	// List.rev hash_cache_list: the string indexes in the order they were first hashed.
	public final order:Array<Int> = [];

	public function new() {}

	public function hash(strings:Array<String>, sid:Int):Int {
		var h = cache.get(sid);
		if (h != null) return h;
		var h = HlcNames.hlHash(strings[sid]);
		while (mem.exists(h)) h = (h + 1) | 0;
		cache.set(sid, h);
		mem.set(h, true);
		order.push(sid);
		return h;
	}
}

// make_types_idents' result: the t$ name of each type of an HlTypeTable, found as PMap.find finds it.
class HlcTypeIdents {
	public final table:HlTypeTable;

	final names:Array<String>;

	public function new(table:HlTypeTable, names:Array<String>) {
		this.table = table;
		this.names = names;
	}

	// type_name
	public function get(t:HlType):String {
		var i = table.indexOf(t);
		if (i == null) throw "type_name: not a gathered type: " + HlDump.tstr(t);
		return names[i];
	}

	// The name of table.types[i].
	public function at(i:Int):String
		return names[i];
}

// An ExtLib PMap node (an AVL tree that allows a height difference of two).
private class PNode {
	public final l:Null<PNode>;
	public final k:Int;
	public final r:Null<PNode>;
	public final h:Int;

	public function new(l:Null<PNode>, k:Int, r:Null<PNode>, h:Int) {
		this.l = l;
		this.k = k;
		this.r = r;
		this.h = h;
	}
}

class HlcNames {
	// ---- 84-365 ----

	public static final keywords:Map<String, Bool> = [
		for (k in [
			"auto", "bool", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto",
			"if", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
			"void", "volatile", "while",
			// Values
			"NULL", "true", "false",
			// MS specific
			"asm", "dllimport2", "dllexport2", "naked2", "thread2",
			// reserved by HLC
			"t",
			// GCC
			"typeof",
			// C11
			"_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local", "_Pragma",
			"inline", "restrict", "_restrict"
		])
			k => true
	];

	public static function ident(i:String):String
		return keywords.exists(i) || StringTools.startsWith(i, "__") ? "_hx_" + i : i;

	// ExtString.String.nsplit then String.concat: the same as a replace.
	public static function tname(str:String):String
		return ident(StringTools.replace(str, ".", "__"));

	public static function isGcPtr(t:HlType):Bool {
		return switch t {
			case HVoid | HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HType | HRef(_) | HMethod(_, _) | HPacked(_): false;
			case HBytes | HDyn | HFun(_, _) | HObj(_) | HArray | HVirtual(_) | HDynObj | HAbstract(_, _) | HEnum(_) | HNull(_) | HStruct(_): true;
		}
	}

	public static function isPtr(t:HlType):Bool {
		return switch t {
			case HVoid | HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool: false;
			default: true;
		}
	}

	// ctype_no_ptr: the C type name and how many `*` follow it.
	public static function ctypeNoPtr(t:HlType):{name:String, stars:Int} {
		return switch t {
			case HVoid: {name: "void", stars: 0};
			case HUI8: {name: "unsigned char", stars: 0};
			case HUI16: {name: "unsigned short", stars: 0};
			case HI32: {name: "int", stars: 0};
			case HI64: {name: "int64", stars: 0};
			case HF32: {name: "float", stars: 0};
			case HF64: {name: "double", stars: 0};
			case HBool: {name: "bool", stars: 0};
			case HBytes: {name: "vbyte", stars: 1};
			case HDyn: {name: "vdynamic", stars: 1};
			case HFun(_, _): {name: "vclosure", stars: 1};
			case HObj(p) | HStruct(p): {name: tname(p.pname), stars: 0};
			case HArray: {name: "varray", stars: 1};
			case HType: {name: "hl_type", stars: 1};
			case HRef(t):
				var c = ctypeNoPtr(t);
				{name: c.name, stars: c.stars + 1};
			case HVirtual(_): {name: "vvirtual", stars: 1};
			case HDynObj: {name: "vdynobj", stars: 1};
			case HAbstract(name, _): {name: name, stars: 1};
			case HEnum(_): {name: "venum", stars: 1};
			case HNull(_): {name: "vdynamic", stars: 1};
			case HMethod(_, _): {name: "void", stars: 1};
			case HPacked(t):
				var c = ctypeNoPtr(t);
				{name: "struct _" + c.name, stars: c.stars};
		}
	}

	public static function ctype(t:HlType):String {
		var c = ctypeNoPtr(t);
		return c.stars == 0 ? c.name : c.name + StringTools.lpad("", "*", c.stars);
	}

	public static function argsRepr(args:Array<HlType>):String
		return args.length == 0 ? "void" : [for (a in args) ctype(a)].join(",");

	public static function castFun(s:String, args:Array<HlType>, t:HlType):String
		return "((" + ctype(t) + " (*)(" + argsRepr(args) + "))" + s + ")";

	public static function dynValueField(t:HlType):String {
		return "->v." + switch t {
			case HUI8: "ui8";
			case HUI16: "ui16";
			case HI32: "i";
			case HI64: "i64";
			case HF32: "f";
			case HF64: "d";
			case HBool: "b";
			default: "ptr";
		}
	}

	public static function typeId(t:HlType):String {
		return switch t {
			case HVoid: "HVOID";
			case HUI8: "HUI8";
			case HUI16: "HUI16";
			case HI32: "HI32";
			case HI64: "HI64";
			case HF32: "HF32";
			case HF64: "HF64";
			case HBool: "HBOOL";
			case HBytes: "HBYTES";
			case HDyn: "HDYN";
			case HFun(_, _): "HFUN";
			case HObj(_): "HOBJ";
			case HArray: "HARRAY";
			case HType: "HTYPE";
			case HRef(_): "HREF";
			case HVirtual(_): "HVIRTUAL";
			case HDynObj: "HDYNOBJ";
			case HAbstract(_, _): "HABSTRACT";
			case HEnum(_): "HENUM";
			case HNull(_): "HNULL";
			case HMethod(_, _): "HMETHOD";
			case HStruct(_): "HSTRUCT";
			case HPacked(_): "HPACKED";
		}
	}

	public static function varType(n:String, t:HlType):String
		return ctype(t) + " " + ident(n);

	// hlcode.ml: hl_hash. Int32 arithmetic over the bytes up to the first NUL; Int32.rem truncates.
	public static function hlHash(s:String):Int {
		var b = Bytes.ofString(s);
		var h = 0;
		for (i in 0...b.length) {
			var c = b.get(i);
			if (c == 0) break;
			h = (HlcOcaml.mul32(h, 223) + c) | 0;
		}
		return h % 0x1FFFFF7B;
	}

	// The first 7 hex digits of the MD5 of the string's bytes.
	public static function shortDigest(s:String):String
		return HlcOcaml.md5Hex(Bytes.ofString(s)).substr(0, 7);

	static inline var STRING_DATA_LIMIT = 64;

	// hl2c.ml: string. `define` is the context's define (it ignores a line it already holds).
	public static function stringLiteral(code:HlCodeData, sid:Int, define:String->Void):String {
		var s = code.strings[sid];
		if (Bytes.ofString(s).length < STRING_DATA_LIMIT) return 'USTR("' + sEscape(s) + '")';
		var id = shortDigest(s);
		define("extern vbyte string$" + id + "[];");
		return "string$" + id;
	}

	// Haxe's StringHelper.s_escape (hex on): \n \t \r \" \\, \xHH below 0x20, every other byte as it is.
	public static function sEscape(s:String):String {
		var b = Bytes.ofString(s);
		var out = new BytesBuffer();
		for (i in 0...b.length) {
			var c = b.get(i);
			switch c {
				case 0x0A: addAscii(out, "\\n");
				case 0x09: addAscii(out, "\\t");
				case 0x0D: addAscii(out, "\\r");
				case 0x22: addAscii(out, "\\\"");
				case 0x5C: addAscii(out, "\\\\");
				case _ if (c < 0x20): addAscii(out, "\\x" + StringTools.hex(c, 2));
				case _: out.addByte(c);
			}
		}
		return out.getBytes().toString();
	}

	static function addAscii(out:BytesBuffer, s:String):Void {
		for (i in 0...s.length) out.addByte(s.charCodeAt(i));
	}

	// OCaml's String.escaped, on the UTF-8 bytes.
	public static function ocamlEscaped(s:String):String
		return HlDump.escaped(s);

	// ---- the OFloat text (about line 805) ----

	// sprintf "%.19g", then a "." when the text has neither "." nor "e".
	public static function floatLiteral(f:Float):String {
		var s = formatG19(f);
		return s.indexOf(".") >= 0 || s.indexOf("e") >= 0 ? s : s + ".";
	}

	static function isWindows():Bool {
		#if sys
		return Sys.systemName() == "Windows";
		#else
		return false;
		#end
	}

	// OCaml's Printf "%.19g" (caml_format_float). Haxe for Windows is a MinGW build that uses msvcrt's printf
	// and defines HAS_BROKEN_PRINTF, so: caml_format_float writes nan, inf and -inf itself; msvcrt gives at
	// most 17 significant digits, zero after them, rounding the exact value half down (an exact tie at the
	// 17th digit goes down); the exponent has at least three digits. Elsewhere glibc gives 19 exactly
	// rounded digits (half to even) and a two-digit exponent.
	static function formatG19(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (!Math.isFinite(f)) return f < 0 ? "-inf" : "inf";
		var windows = isWindows();
		var precision = 19;
		var neg = f < 0 || (f == 0 && 1 / f < 0);
		var digits:String, pointAt:Int;
		if (f == 0) {
			digits = "0";
			pointAt = 1;
		} else {
			var e = exactDecimal(Math.abs(f));
			digits = e.digits;
			pointAt = e.pointAt;
			var keep = windows ? 17 : precision;
			if (digits.length > keep) {
				var up = roundsUp(digits, keep, !windows);
				var d = [for (i in 0...keep) digits.charCodeAt(i) - "0".code];
				if (up) {
					var i = keep - 1;
					while (i >= 0 && d[i] == 9) d[i--] = 0;
					if (i < 0) {
						d.unshift(1);
						d.pop();
						pointAt++;
					} else {
						d[i]++;
					}
				}
				digits = d.join("");
			}
		}
		// %g: the exponent X the e-style text would have decides; trailing zeros go, and the point with them.
		var end = digits.length;
		while (end > 1 && digits.charAt(end - 1) == "0") end--;
		digits = digits.substr(0, end);
		var x = f == 0 ? 0 : pointAt - 1;
		var out:String;
		if (x < -4 || x >= precision) {
			var ex = Std.string(x < 0 ? -x : x);
			while (ex.length < (windows ? 3 : 2)) ex = "0" + ex;
			out = digits.charAt(0) + (digits.length > 1 ? "." + digits.substr(1) : "") + "e" + (x < 0 ? "-" : "+") + ex;
		} else if (x >= 0) {
			out = digits.length <= x + 1 ? digits + StringTools.lpad("", "0", x + 1 - digits.length) : digits.substr(0, x + 1) + "." + digits.substr(x + 1);
		} else {
			out = "0." + StringTools.lpad("", "0", -x - 1) + digits;
		}
		return neg ? "-" + out : out;
	}

	// Whether keeping the first `keep` digits rounds up: above half always, an exact half only to even.
	static function roundsUp(digits:String, keep:Int, halfEven:Bool):Bool {
		var first = digits.charCodeAt(keep) - "0".code;
		if (first != 5) return first > 5;
		for (i in keep + 1...digits.length) if (digits.charCodeAt(i) != "0".code) return true;
		return halfEven && (digits.charCodeAt(keep - 1) - "0".code) % 2 == 1;
	}

	// The exact decimal value of a positive finite double: its significant digits and where the point goes
	// (value = 0.digits * 10^pointAt).
	static function exactDecimal(f:Float):{digits:String, pointAt:Int} {
		var bits = haxe.io.FPHelper.doubleToI64(f);
		var hi = bits.high, lo = bits.low;
		var bexp = (hi >>> 20) & 0x7FF;
		var mhi = hi & 0xFFFFF;
		if (bexp != 0) mhi |= 0x100000;
		var e = (bexp == 0 ? 1 : bexp) - 1075;
		// the mantissa, exact in a Float (below 2^53)
		var m = mhi * 4294967296.0 + (lo < 0 ? lo + 4294967296.0 : lo);
		while (m % 2 == 0) {
			m /= 2;
			e++;
		}
		// little-endian base-10000 limbs
		var limbs:Array<Int> = [];
		while (m > 0) {
			var limb = m % 10000;
			limbs.push(Std.int(limb));
			m = (m - limb) / 10000;
		}
		var shift = 0;
		if (e >= 0) {
			var k = e;
			while (k >= 13) {
				mulSmall(limbs, 8192);
				k -= 13;
			}
			if (k > 0) mulSmall(limbs, 1 << k);
		} else {
			var k = -e;
			shift = k;
			while (k >= 5) {
				mulSmall(limbs, 3125);
				k -= 5;
			}
			var p = 1;
			for (_ in 0...k) p *= 5;
			if (p > 1) mulSmall(limbs, p);
		}
		var buf = new StringBuf();
		var i = limbs.length - 1;
		buf.add(Std.string(limbs[i]));
		while (--i >= 0) buf.add(StringTools.lpad(Std.string(limbs[i]), "0", 4));
		var digits = buf.toString();
		return {digits: digits, pointAt: digits.length - shift};
	}

	static function mulSmall(limbs:Array<Int>, k:Int):Void {
		var carry = 0;
		for (i in 0...limbs.length) {
			var v = limbs[i] * k + carry;
			limbs[i] = v % 10000;
			carry = Std.int(v / 10000);
		}
		while (carry > 0) {
			limbs.push(carry % 10000);
			carry = Std.int(carry / 10000);
		}
	}

	// ---- 1100-1255 ----

	// valid_ident: each run of bytes outside [A-Za-z0-9_] becomes one "_".
	public static function validIdent(str:String):String {
		var b = Bytes.ofString(str);
		var out = new StringBuf();
		var inRun = false;
		for (i in 0...b.length) {
			var c = b.get(i);
			if ((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code) {
				out.addChar(c);
				inRun = false;
			} else if (!inRun) {
				out.add("_");
				inRun = true;
			}
		}
		return out.toString();
	}

	// make_types_idents. The names come from PMap.mapi over gather_types' PMap, which applies its function
	// in post-order (left subtree, right subtree, node) over the AVL tree that adding the types in gather
	// order under polymorphic compare built; that order decides which of two colliding 7-digit prefixes
	// gets the full digest. make_desc builds the type_desc as an OCaml value (DSimple 0, DFun 1, DNamed 2,
	// DVirtual 3, DContext 4), with the sharing hl2c gives it:
	//   - DSimple t is a fresh block around t's value, which is one value per HlType object (ttypeValue);
	//   - DNamed holds the very string of the proto or the HAbstract (typeNameString), except a packed
	//     struct's name, which "packed_" ^ n makes afresh;
	//   - DVirtual is one value per virtual proto under compare (types_descs), registered before its fields
	//     are made so that a recursive virtual refers to itself; its field names are the vfields' strings;
	//   - DFun's argument list and DContext's array are fresh. DFun makes its result's desc before its
	//     arguments' (OCaml evaluates constructor arguments right to left), which only decides which of two
	//     equal virtual protos types_descs meets first.
	public static function makeTypesIdents(table:HlTypeTable):HlcTypeIdents {
		var types = table.types;
		var values = [for (t in types) HlcOcaml.ttypeValue(t)];
		var root:Null<PNode> = null;
		for (i in 0...types.length) root = pmapAdd(i, root, values);
		var order = [];
		postOrder(root, order);

		// types_descs: virtual proto -> its desc, found by compare = 0 (HlTypeTable.same)
		var vdescs = new Map<String, Array<{vp:HlVirtualProto, v:OValue}>>();
		var hashes = new Map<String, Bool>();

		function makeDesc(t:HlType):OValue {
			switch t {
				case HVoid | HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HBytes | HDyn | HArray | HType | HRef(_) | HDynObj | HNull(_):
					return block(0, [HlcOcaml.ttypeValue(t)]);
				case HFun(tl, r) | HMethod(tl, r):
					var ret = makeDesc(r);
					var items = [for (a in tl) makeDesc(a)];
					var l = OInt(0);
					var i = items.length;
					while (i-- > 0) l = block(0, [items[i], l]);
					return block(1, [l, ret, OInt(t.match(HFun(_, _)) ? 1 : 0)]);
				case HObj(_) | HStruct(_) | HAbstract(_, _):
					return block(2, [OStr(HlcOcaml.typeNameString(t))]);
				case HPacked(t):
					var inner = blockOf(makeDesc(t));
					if (inner.tag != 2) throw "make_desc: packed " + HlDump.tstr(t) + " has no name";
					return block(2, [OStr(new OString("packed_" + stringOf(inner.fields[0]).s))]);
				case HEnum(e) if (e.ename == ""):
					return block(4, [OBlock(new OBlockRef(0, [for (t in e.efields[0].t) makeDesc(t)]))]);
				case HEnum(_):
					return block(2, [OStr(HlcOcaml.typeNameString(t))]);
				case HVirtual(vp):
					var key = HlTypeTable.key(t, 0);
					var bucket = vdescs.get(key);
					if (bucket == null) vdescs.set(key, bucket = []);
					for (e in bucket) if (e.vp == vp || HlTypeTable.same(HVirtual(e.vp), t, [])) return e.v;
					var arr = new OBlockRef(0, []);
					var td = block(3, [OBlock(arr)]);
					bucket.push({vp: vp, v: td});
					var names = vfieldNames(vp);
					arr.fields = [for (_ in vp.vfields) OInt(0)];
					for (i in 0...vp.vfields.length) arr.fields[i] = block(0, [names[i], makeDesc(vp.vfields[i].t)]);
					return td;
			}
		}

		function makeSign(d:OValue):String {
			var dig = HlcOcaml.md5Hex(HlcOcaml.marshal(d));
			var h = dig.substr(0, 7);
			if (hashes.exists(h)) h = dig;
			hashes.set(h, true);
			return h;
		}

		// desc_string, with the type the desc was made from (a DSimple's own type).
		function descString(t:HlType, d:OValue):String {
			var b = blockOf(d);
			return switch b.tag {
				case 0:
					switch t {
						case HNull(t): "t$nul_" + HlDump.tstr(t);
						case HRef(t):
							var inner = makeDesc(t);
							"t$ref_" + (blockOf(inner).tag == 0 ? HlDump.tstr(t) : descString(t, inner));
						default: "t$_" + HlDump.tstr(t);
					}
				case 1: "t$fun_" + makeSign(d);
				case 2: "t$" + StringTools.replace(stringOf(b.fields[0]).s, ".", "_");
				case 3: "t$vrt_" + makeSign(d);
				default: "t$ctx_" + makeSign(d);
			}
		}

		var names = [for (_ in types) ""];
		for (i in order) names[i] = descString(types[i], makeDesc(types[i]));
		return new HlcTypeIdents(table, names);
	}

	// The OCaml strings of a virtual's field names, as its vfield tuples hold them.
	static function vfieldNames(vp:HlVirtualProto):Array<OValue> {
		var t = blockOf(HlcOcaml.ttypeValue(HVirtual(vp)));
		var arr = blockOf(blockOf(t.fields[0]).fields[0]);
		return [for (f in arr.fields) blockOf(f).fields[0]];
	}

	static function stringOf(v:OValue):OString {
		return switch v {
			case OStr(s): s;
			default: throw "not a string";
		}
	}

	static function block(tag:Int, fields:Array<OValue>):OValue
		return OBlock(new OBlockRef(tag, fields));

	static function blockOf(v:OValue):OBlockRef {
		return switch v {
			case OBlock(b): b;
			default: throw "not a block";
		}
	}

	// PMap.add: equal keys replace (never here: the table holds each type once).
	static function pmapAdd(x:Int, n:Null<PNode>, values:Array<OValue>):PNode {
		if (n == null) return new PNode(null, x, null, 1);
		var c = HlcOcaml.compare(values[x], values[n.k]);
		if (c == 0) throw "make_types_idents: two gathered types compare equal";
		if (c < 0) return bal(pmapAdd(x, n.l, values), n.k, n.r);
		return bal(n.l, n.k, pmapAdd(x, n.r, values));
	}

	static inline function height(n:Null<PNode>):Int
		return n == null ? 0 : n.h;

	static function make(l:Null<PNode>, k:Int, r:Null<PNode>):PNode {
		var hl = height(l), hr = height(r);
		return new PNode(l, k, r, (hl > hr ? hl : hr) + 1);
	}

	static function bal(l:Null<PNode>, k:Int, r:Null<PNode>):PNode {
		var hl = height(l), hr = height(r);
		if (hl > hr + 2) {
			if (height(l.l) >= height(l.r)) return make(l.l, l.k, make(l.r, k, r));
			var lr = l.r;
			return make(make(l.l, l.k, lr.l), lr.k, make(lr.r, k, r));
		}
		if (hr > hl + 2) {
			if (height(r.r) >= height(r.l)) return make(make(l, k, r.l), r.k, r.r);
			var rl = r.l;
			return make(make(l, k, rl.l), rl.k, make(rl.r, r.k, r.r));
		}
		return new PNode(l, k, r, (hl >= hr ? hl : hr) + 1);
	}

	// PMap.mapi's order: left subtree, right subtree, then the node.
	static function postOrder(n:Null<PNode>, out:Array<Int>):Void {
		if (n == null) return;
		postOrder(n.l, out);
		postOrder(n.r, out);
		out.push(n.k);
	}

	// make_global_names. Fills gnames' String constants with their string (as hl2c does to its array) and
	// returns each global's C name: s$ for a String constant, g$ otherwise, then the valid identifier, or
	// the short digest when the string is over 32 bytes, is "_" or shares its identifier with another String
	// constant; _1, _2 ... when the name is taken, in (name, index) order.
	public static function makeGlobalNames(code:HlCodeData, gnames:Array<String>):Array<String> {
		var hstrings = new Map<String, Bool>();
		var isCstr = new Map<Int, Bool>();
		for (c in code.constants) {
			switch code.globals[c.global] {
				case HObj(p) if (p.pname == "String"):
					var str = code.strings[c.fields[0]];
					var v = validIdent(str);
					hstrings.set(v, hstrings.exists(v));
					isCstr.set(c.global, true);
					gnames[c.global] = str;
				default:
			}
		}
		var gids = [for (i in 0...gnames.length) {n: gnames[i], b: Bytes.ofString(gnames[i]), g: i}];
		gids.sort((a, b) -> {
			var d = compareBytes(a.b, b.b);
			d != 0 ? d : a.g - b.g;
		});
		var used = new Map<String, Bool>();
		var names = new Map<Int, String>();
		for (e in gids) {
			var str = e.n;
			var body = if (e.b.length > 32) shortDigest(str) else {
				var i = validIdent(str);
				i == "_" || hstrings.get(i) == true ? shortDigest(str) : i;
			}
			var id = (isCstr.exists(e.g) ? "s$" : "g$") + body;
			var rid = id;
			var k = 0;
			while (used.exists(rid)) rid = id + "_" + (++k);
			used.set(rid, true);
			names.set(e.g, rid);
		}
		return [
			for (i in 0...code.globals.length) {
				var n = names.get(i);
				if (n == null) throw "make_global_names: global " + i + " has no name";
				n;
			}
		];
	}

	static function compareBytes(a:Bytes, b:Bytes):Int {
		var n = a.length < b.length ? a.length : b.length;
		for (i in 0...n) {
			var d = a.get(i) - b.get(i);
			if (d != 0) return d;
		}
		return a.length - b.length;
	}

	// make_function_table: natives first by their index, then functions; calledBy and calling are filled
	// from the calls and static or instance closures each function's code makes.
	public static function makeFunctionTable(code:HlCodeData):Array<FunctionEntry> {
		var ftable = [for (i in 0...code.functions.length + code.natives.length) new FunctionEntry(i)];
		for (n in code.natives) {
			var lib = code.strings[n.lib];
			if (lib.charAt(0) == "?") lib = lib.substr(1);
			if (lib == "std") lib = "hl";
			var str = lib + "_" + code.strings[n.name];
			var fname = str == "hl_tls_get" ? str + "_w" : str;
			switch n.t {
				case HFun(args, t):
					var ft = ftable[n.findex];
					ft.name = fname;
					ft.args = args;
					ft.ret = t;
				default:
					throw "make_function_table: native " + fname + " is not a function";
			}
		}
		for (f in code.functions) {
			var ft = ftable[f.findex];
			ft.name = StringTools.replace(HlDump.fundeclName(f), ".", "_");
			switch f.ftype {
				case HFun(args, t):
					ft.args = args;
					ft.ret = t;
				default:
					throw "make_function_table: " + ft.name + " is not a function";
			}
			ft.decl = f;
			for (op in f.code) {
				var fid = switch op {
					case OCall0(_, fid) | OCall1(_, fid, _) | OCall2(_, fid, _, _) | OCall3(_, fid, _, _, _) | OCall4(_, fid, _, _, _, _) | OCallN(_, fid, _) |
						OStaticClosure(_, fid) | OInstanceClosure(_, fid, _):
						fid;
					default:
						-1;
				}
				if (fid < 0) continue;
				var ft2 = ftable[fid];
				if (ft2.calledBy.indexOf(ft) < 0) {
					ft2.calledBy.unshift(ft);
					ft.calling.unshift(ft2);
				}
			}
		}
		return ftable;
	}
}
