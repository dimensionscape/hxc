package hxc.codegen.hl;

import haxe.ds.ObjectMap;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import hxc.codegen.hl.HlCode;

// Exact models of the OCaml 4.14 runtime behaviour hl2c.ml's output depends on, on a 64-bit build (Haxe on
// Windows is one):
//   - Hashtbl.hash: runtime/hash.c caml_hash with count 10, limit 100, seed 0;
//   - the polymorphic Hashtbl (stdlib/hashtbl.ml): bucket order of add, replace, resize, iter and fold;
//   - Marshal.to_bytes v [Marshal.Closures]: runtime/extern.c with sharing, small header.
// Values are modelled by OValue. Physical identity, which Marshal's sharing and compare's shortcut see, is
// Haxe object identity of OString and OBlockRef. A field OCaml holds but this model does not (a class proto's
// PMaps) is the sentinel OBlock(HlcOcaml.UNMODELLED): reaching it in a hash walk, a compare or a marshal throws
// Unmodelled. A virtual proto's vindex PMap is modelled, with its `compare` closure as OBlock(HlcOcaml.PMAP_CMP).
// This module imports nothing from hxc outside hxc.codegen.hl, so tools/hl/HlcCheck runs under haxe --run.

// An OCaml string (String_tag block). The bytes are the UTF-8 of s.
class OString {
	public final s:String;

	var cache:Null<Bytes>;

	public function new(s:String) {
		this.s = s;
	}

	public function bytes():Bytes {
		if (cache == null) cache = Bytes.ofString(s);
		return cache;
	}

	public function toString():String
		return '"' + s + '"';
}

// An OCaml structured block: a tag below No_scan_tag and its fields. A zero-field block is an atom.
class OBlockRef {
	public final tag:Int;
	public var fields:Array<OValue>;

	public function new(tag:Int, fields:Array<OValue>) {
		this.tag = tag;
		this.fields = fields;
	}

	public function toString():String
		return this == HlcOcaml.UNMODELLED ? "<unmodelled>" : "[" + tag + "|" + fields.join(",") + "]";
}

enum OValue {
	// An immediate int (OCaml's are 63-bit; these hold 32).
	OInt(i:Int);
	OStr(s:OString);
	OBlock(b:OBlockRef);
	// A boxed float (Double_tag). There is no identity: each occurrence is its own block.
	ODouble(f:Float);
}

// Thrown when a hash walk, a compare or a marshal reaches the sentinel. The message is the path from the
// root, as field indexes ("root.2.0").
class Unmodelled extends haxe.Exception {
	public final path:String;

	public function new(path:String) {
		super(path);
		this.path = path;
	}
}

class HlcOcaml {
	public static final UNMODELLED = new OBlockRef(0, []);

	// The `cmp` closure of every PMap built from PMap.empty (ExtLib's `{cmp = compare; map}`): one physical
	// value (Closure_tag), so compare and equal skip it by identity. Compare raises on two different
	// closures (not modelled: there is only this one), and a hash walk or a marshal throws Unmodelled on it.
	public static final PMAP_CMP = new OBlockRef(247, []);

	// ---- runtime/hash.c ----

	static inline function rotl(x:Int, n:Int):Int
		return (x << n) | (x >>> (32 - n));

	// 32-bit product, low word, without relying on the target's overflow behaviour.
	public static inline function mul32(a:Int, b:Int):Int {
		var aLo = a & 0xFFFF, aHi = a >>> 16;
		return ((aLo * b) + (((aHi * b) & 0xFFFF) << 16)) | 0;
	}

	// MIX(h, d), caml_hash_mix_uint32.
	public static function mix(h:Int, d:Int):Int {
		d = mul32(d, 0xcc9e2d51);
		d = rotl(d, 15);
		d = mul32(d, 0x1b873593);
		h ^= d;
		h = rotl(h, 13);
		h = mul32(h, 5) + 0xe6546b64;
		return h | 0;
	}

	// caml_hash_mix_string: little-endian 32-bit words, then up to 3 bytes, then the length.
	public static function mixString(h:Int, b:Bytes):Int {
		var n = b.length;
		var i = 0;
		while (i + 4 <= n) {
			h = mix(h, b.get(i) | (b.get(i + 1) << 8) | (b.get(i + 2) << 16) | (b.get(i + 3) << 24));
			i += 4;
		}
		var r = n & 3;
		if (r != 0) {
			var w = 0;
			if (r == 3) w = b.get(i + 2) << 16;
			if (r >= 2) w |= b.get(i + 1) << 8;
			w |= b.get(i);
			h = mix(h, w);
		}
		return h ^ n;
	}

	// caml_hash_mix_double: NaNs normalised, -0.0 as +0.0, low word then high word.
	static function mixDouble(h:Int, f:Float):Int {
		var bits = haxe.io.FPHelper.doubleToI64(f);
		var hi = bits.high, lo = bits.low;
		if ((hi & 0x7FF00000) == 0x7FF00000 && (lo | (hi & 0xFFFFF)) != 0) {
			hi = 0x7FF00000;
			lo = 1;
		} else if (hi == 0x80000000 && lo == 0) {
			hi = 0;
		}
		return mix(mix(h, lo), hi);
	}

	// FINAL_MIX.
	public static function finalMix(h:Int):Int {
		h ^= h >>> 16;
		h = mul32(h, 0x85ebca6b);
		h ^= h >>> 13;
		h = mul32(h, 0xc2b2ae35);
		h ^= h >>> 16;
		return h;
	}

	// Hashtbl.hash: caml_hash 10 100 0.
	public static function hash(v:OValue):Int
		return hashParam(10, 100, 0, v);

	// caml_hash(count, limit, seed, obj): a breadth-first walk over at most `limit` queued values that stops
	// after `count` meaningful ones (ints, strings, floats). A block mixes its header (size << 10 | tag, colour
	// cleared) without counting. An immediate mixes as its tagged word 2n+1, which for a 32-bit n is the low
	// 32 bits caml_hash_mix_intnat keeps. The result is masked to 30 bits.
	public static function hashParam(count:Int, limit:Int, seed:Int, obj:OValue):Int {
		var sz = limit;
		if (sz < 0 || sz > 256) sz = 256;
		var num = count;
		var h = seed;
		var queue:Array<OValue> = [obj];
		var parent:Array<Int> = [-1];
		var slot:Array<Int> = [-1];
		var rd = 0, wr = 1;
		while (rd < wr && num > 0) {
			var at = rd;
			var v = queue[rd++];
			switch v {
				case OInt(i):
					h = mix(h, (i << 1) | 1);
					num--;
				case OStr(s):
					h = mixString(h, s.bytes());
					num--;
				case ODouble(f):
					h = mixDouble(h, f);
					num--;
				case OBlock(b):
					if (b == UNMODELLED || b == PMAP_CMP) throw new Unmodelled(queuePath(parent, slot, at));
					var len = b.fields.length;
					h = mix(h, (len << 10) | b.tag);
					for (i in 0...len) {
						if (wr >= sz) break;
						queue[wr] = b.fields[i];
						parent[wr] = at;
						slot[wr] = i;
						wr++;
					}
			}
		}
		return finalMix(h) & 0x3FFFFFFF;
	}

	static function queuePath(parent:Array<Int>, slot:Array<Int>, at:Int):String {
		var parts = [];
		while (at > 0) {
			parts.unshift(Std.string(slot[at]));
			at = parent[at];
		}
		parts.unshift("root");
		return parts.join(".");
	}

	// ---- compare = 0 (runtime/compare.c, total) ----

	// Structural equality as `compare a b = 0`: a depth-first walk, fields left to right, physically equal
	// strings and blocks skip their contents, floats compare with nan = nan and -0.0 = 0.0. Reaching the
	// sentinel on either side throws, even against itself: every unmodelled field shares the one sentinel,
	// which OCaml's distinct PMaps do not.
	public static function equal(a:OValue, b:OValue):Bool
		return eqRec(a, b, "root");

	static function eqRec(a:OValue, b:OValue, path:String):Bool {
		switch [a, b] {
			case [OBlock(x), _] if (x == UNMODELLED):
				throw new Unmodelled(path);
			case [_, OBlock(y)] if (y == UNMODELLED):
				throw new Unmodelled(path);
			case [OInt(x), OInt(y)]:
				return x == y;
			case [OStr(x), OStr(y)]:
				return x == y || x.s == y.s;
			case [ODouble(x), ODouble(y)]:
				return x == y || (Math.isNaN(x) && Math.isNaN(y));
			case [OBlock(x), OBlock(y)]:
				if (x == y) return true;
				if (x.tag != y.tag || x.fields.length != y.fields.length) return false;
				// Unreachable while PMAP_CMP is the only Closure_tag block: two are identical, others differ by tag.
				if (x == PMAP_CMP || y == PMAP_CMP) throw new Unmodelled(path + " (functional value)");
				for (i in 0...x.fields.length) if (!eqRec(x.fields[i], y.fields[i], path + "." + i)) return false;
				return true;
			default:
				return false;
		}
	}

	// Polymorphic `compare a b` (compare.c, total), as its sign: physically equal values are equal; an
	// immediate is below any block and ints compare by value; blocks compare by tag (String_tag 252 and
	// Double_tag 253 above every structured tag), then strings by bytes then length, doubles with nan equal
	// to itself and below every other float, structured blocks by size and then field by field, depth first.
	// Reaching the sentinel throws, as in equal. A walk deeper than 100000 throws too: OCaml would not end.
	public static function compare(a:OValue, b:OValue):Int
		return cmpRec(a, b, "root", 0);

	static function cmpRec(a:OValue, b:OValue, path:String, depth:Int):Int {
		if (depth > 100000) throw new Unmodelled(path + " (compare does not end)");
		switch [a, b] {
			case [OBlock(x), _] if (x == UNMODELLED):
				throw new Unmodelled(path);
			case [_, OBlock(y)] if (y == UNMODELLED):
				throw new Unmodelled(path);
			case [OInt(x), OInt(y)]:
				return x < y ? -1 : x > y ? 1 : 0;
			case [OInt(_), _]:
				return -1;
			case [_, OInt(_)]:
				return 1;
			default:
		}
		var ta = tagOf(a), tb = tagOf(b);
		if (ta != tb) return ta < tb ? -1 : 1;
		switch [a, b] {
			case [OStr(x), OStr(y)]:
				if (x == y) return 0;
				var bx = x.bytes(), by = y.bytes();
				var n = bx.length < by.length ? bx.length : by.length;
				for (i in 0...n) {
					var cx = bx.get(i), cy = by.get(i);
					if (cx != cy) return cx < cy ? -1 : 1;
				}
				return bx.length < by.length ? -1 : bx.length > by.length ? 1 : 0;
			case [ODouble(x), ODouble(y)]:
				if (x < y) return -1;
				if (x > y) return 1;
				if (x != y) {
					if (x == x) return 1;
					if (y == y) return -1;
				}
				return 0;
			case [OBlock(x), OBlock(y)]:
				if (x == y) return 0;
				// Unreachable while PMAP_CMP is the only Closure_tag block: two are identical, others differ by tag.
				if (x == PMAP_CMP || y == PMAP_CMP) throw new Unmodelled(path + " (functional value)");
				var n = x.fields.length;
				if (n != y.fields.length) return n < y.fields.length ? -1 : 1;
				for (i in 0...n) {
					var c = cmpRec(x.fields[i], y.fields[i], path + "." + i, depth + 1);
					if (c != 0) return c;
				}
				return 0;
			default:
				throw "unreachable";
		}
	}

	static function tagOf(v:OValue):Int {
		return switch v {
			case OStr(_): 252;
			case ODouble(_): 253;
			case OBlock(b): b.tag;
			case OInt(_): -1;
		}
	}

	// ---- runtime/extern.c ----

	// Marshal.to_bytes v [Marshal.Closures]: the 20-byte small header (magic, data length, object count,
	// 32-bit and 64-bit heap words), then the data. Sharing is by physical identity (OString, OBlockRef);
	// atoms are never shared or counted.
	public static function marshal(v:OValue):Bytes {
		var m = new Marshaller();
		m.run(v);
		var data = m.out.getBytes();
		var res = Bytes.alloc(20 + data.length);
		store32(res, 0, 0x8495A6BE);
		store32(res, 4, data.length);
		store32(res, 8, m.objCounter);
		store32(res, 12, m.size32);
		store32(res, 16, m.size64);
		res.blit(20, data, 0, data.length);
		return res;
	}

	static inline function store32(b:Bytes, pos:Int, v:Int) {
		b.set(pos, v >>> 24);
		b.set(pos + 1, v >>> 16);
		b.set(pos + 2, v >>> 8);
		b.set(pos + 3, v);
	}

	public static function md5Hex(b:Bytes):String
		return haxe.crypto.Md5.make(b).toHex();

	// ---- stdlib/array.ml ----

	// OCaml's Array.sort: a ternary heap sort, so equal elements do not keep their order.
	public static function arraySort<X>(a:Array<X>, cmp:X->X->Int):Void {
		// maxson's `raise (Bottom i)` is answered as -1 - i
		function maxson(l:Int, i:Int):Int {
			var i31 = i + i + i + 1;
			var x = i31;
			if (i31 + 2 < l) {
				if (cmp(a[i31], a[i31 + 1]) < 0) x = i31 + 1;
				if (cmp(a[x], a[i31 + 2]) < 0) x = i31 + 2;
				return x;
			}
			return if (i31 + 1 < l && cmp(a[i31], a[i31 + 1]) < 0) i31 + 1 else if (i31 < l) i31 else -1 - i;
		}
		function trickle(l:Int, i:Int, e:X):Void {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) {
					a[-1 - j] = e;
					return;
				}
				if (cmp(a[j], e) > 0) {
					a[i] = a[j];
					i = j;
				} else {
					a[i] = e;
					return;
				}
			}
		}
		function bubble(l:Int, i:Int):Int {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) return -1 - j;
				a[i] = a[j];
				i = j;
			}
		}
		function trickleup(i:Int, e:X):Void {
			while (true) {
				var father = Std.int((i - 1) / 3);
				if (cmp(a[father], e) < 0) {
					a[i] = a[father];
					if (father > 0) i = father;
					else {
						a[0] = e;
						return;
					}
				} else {
					a[i] = e;
					return;
				}
			}
		}
		var l = a.length;
		var i = Std.int((l + 1) / 3) - 1;
		while (i >= 0) {
			trickle(l, i, a[i]);
			i--;
		}
		i = l - 1;
		while (i >= 2) {
			var e = a[i];
			a[i] = a[0];
			trickleup(bubble(i, 0), e);
			i--;
		}
		if (l > 1) {
			var e = a[1];
			a[1] = a[0];
			a[0] = e;
		}
	}

	// ---- ttype in its hlcode.ml layout ----

	// One OCaml value per source object: a type, a proto, a field tuple, an array or a list. hxc objects that
	// are the same object give the same OBlockRef, so sharing that hxc keeps is sharing OCaml would see.
	static var memo = new ObjectMap<{}, OValue>();
	static var listMemo = new ObjectMap<{}, OValue>();

	// Forgets every value ttypeValue made: call once per output, so one compile's types are not kept alive.
	public static function resetMemo():Void {
		memo = new ObjectMap();
		listMemo = new ObjectMap();
	}

	// ttype, from hlcode.ml: constant constructors are ints in declaration order (HVoid 0 .. HDynObj 12),
	// the others are blocks tagged in declaration order (HFun 0 .. HPacked 9).
	public static function ttypeValue(t:HlType):OValue {
		var c = constIndex(t);
		if (c >= 0) return OInt(c);
		var key:{} = cast t;
		var known = memo.get(key);
		if (known != null) return known;
		var b = new OBlockRef(blockTag(t), []);
		var v = OBlock(b);
		memo.set(key, v);
		b.fields = switch t {
			case HFun(args, ret) | HMethod(args, ret): [listOf(args, ttypeValue), ttypeValue(ret)];
			case HObj(p) | HStruct(p): [classProto(p)];
			case HRef(t) | HNull(t) | HPacked(t): [ttypeValue(t)];
			case HVirtual(vp): [virtualProto(vp)];
			// One string per HAbstract object: the front end makes one object per hl.Abstract<"..."> declaration,
			// whose name genhl shares (HlContext.abstractTypes).
			case HAbstract(name, index): [OStr(new OString(name)), OInt(index)];
			case HEnum(e): [enumProto(e)];
			default: throw "unreachable";
		}
		return v;
	}

	static function constIndex(t:HlType):Int {
		return switch t {
			case HVoid: 0;
			case HUI8: 1;
			case HUI16: 2;
			case HI32: 3;
			case HI64: 4;
			case HF32: 5;
			case HF64: 6;
			case HBool: 7;
			case HBytes: 8;
			case HDyn: 9;
			case HArray: 10;
			case HType: 11;
			case HDynObj: 12;
			default: -1;
		}
	}

	static function blockTag(t:HlType):Int {
		return switch t {
			case HFun(_, _): 0;
			case HObj(_): 1;
			case HRef(_): 2;
			case HVirtual(_): 3;
			case HAbstract(_, _): 4;
			case HEnum(_): 5;
			case HNull(_): 6;
			case HMethod(_, _): 7;
			case HStruct(_): 8;
			case HPacked(_): 9;
			default: throw "constant ttype has no block tag";
		}
	}

	// The string a DNamed holds for this type, as make_types_idents takes it: the very string of the proto
	// (p.pname, e.ename) or of the HAbstract.
	public static function typeNameString(t:HlType):OString {
		var b = blockOf(ttypeValue(t));
		return switch t {
			case HObj(_) | HStruct(_) | HEnum(_): stringOf(blockOf(b.fields[0]).fields[0]);
			case HAbstract(_, _): stringOf(b.fields[0]);
			default: throw "no name string for " + Std.string(t);
		}
	}

	static function blockOf(v:OValue):OBlockRef {
		return switch v {
			case OBlock(b): b;
			default: throw "not a block";
		}
	}

	static function stringOf(v:OValue):OString {
		return switch v {
			case OStr(s): s;
			default: throw "not a string";
		}
	}

	// class_proto: pname, pid, pclassglobal, psuper, pvirtuals, pproto, pnfields, pfields, pindex, pfunctions,
	// pinterfaces, pbindings. The three PMaps are the sentinel.
	static function classProto(p:HlClassProto):OValue {
		var key:{} = p;
		var known = memo.get(key);
		if (known != null) return known;
		var b = new OBlockRef(0, []);
		var v = OBlock(b);
		memo.set(key, v);
		b.fields = [
			OStr(new OString(p.pname)),
			OInt(p.pid),
			intOption(p.pclassglobal),
			p.psuper == null ? OInt(0) : some(classProto(p.psuper)),
			arrayOf(p.pvirtuals, i -> OInt(i)),
			arrayOf(p.pproto, fieldProto),
			OInt(p.pnfields),
			arrayOf(p.pfields, fieldTuple),
			OBlock(UNMODELLED),
			OBlock(UNMODELLED),
			OBlock(UNMODELLED),
			listOf(p.pbindings, bindingTuple)
		];
		return v;
	}

	// enum_proto: ename, eid, eglobal, efields of (string * string index * ttype array).
	static function enumProto(e:HlEnumProto):OValue {
		var key:{} = e;
		var known = memo.get(key);
		if (known != null) return known;
		var b = new OBlockRef(0, []);
		var v = OBlock(b);
		memo.set(key, v);
		b.fields = [
			OStr(new OString(e.ename)),
			OInt(e.eid),
			intOption(e.eglobal),
			arrayOf(e.efields, f -> memoBlock(f, () -> [OStr(new OString(f.name)), OInt(f.nameIndex), arrayOf(f.t, ttypeValue)]))
		];
		return v;
	}

	// field_proto: fname, fid, fmethod, fvirtual.
	static function fieldProto(f:HlFieldProto):OValue
		return memoBlock(f, () -> [OStr(new OString(f.fname)), OInt(f.fid), OInt(f.fmethod), intOption(f.fvirtual)]);

	// virtual_proto: vfields, vindex. genhl builds vindex by adding each vfield's name (the tuple's own string)
	// with its index, in index order, to PMap.empty.
	static function virtualProto(vp:HlVirtualProto):OValue {
		return memoBlock(vp, () -> {
			var fields = arrayOf(vp.vfields, fieldTuple);
			var map = OInt(0);
			var tuples = blockOf(fields).fields;
			for (i in 0...tuples.length) map = pmapAdd(blockOf(tuples[i]).fields[0], OInt(i), map);
			[fields, OBlock(new OBlockRef(0, [OBlock(PMAP_CMP), map]))];
		});
	}

	// ExtLib's PMap.add on the map: Empty is 0, Node (l, k, v, r, h) a tag-0 block; keys under compare, an
	// equal key replaced in place, the AVL rebalanced as PMap's bal does (height difference above 2).
	static function pmapAdd(x:OValue, d:OValue, m:OValue):OValue {
		return switch m {
			case OBlock(n):
				var l = n.fields[0], k = n.fields[1], r = n.fields[3];
				var c = compare(x, k);
				if (c == 0) node(l, x, d, r, n.fields[4]);
				else if (c < 0) pmapBal(pmapAdd(x, d, l), k, n.fields[2], r);
				else pmapBal(l, k, n.fields[2], pmapAdd(x, d, r));
			default: node(OInt(0), x, d, OInt(0), OInt(1));
		}
	}

	static function node(l:OValue, k:OValue, v:OValue, r:OValue, h:OValue):OValue
		return OBlock(new OBlockRef(0, [l, k, v, r, h]));

	static function pmapHeight(m:OValue):Int {
		return switch m {
			case OBlock(n): switch n.fields[4] {
					case OInt(h): h;
					default: throw "not a PMap node";
				}
			default: 0;
		}
	}

	static function pmapMake(l:OValue, k:OValue, v:OValue, r:OValue):OValue {
		var hl = pmapHeight(l), hr = pmapHeight(r);
		return node(l, k, v, r, OInt((hl > hr ? hl : hr) + 1));
	}

	static function pmapBal(l:OValue, k:OValue, v:OValue, r:OValue):OValue {
		var hl = pmapHeight(l), hr = pmapHeight(r);
		if (hl > hr + 2) {
			var ln = blockOf(l);
			var ll = ln.fields[0], lk = ln.fields[1], lv = ln.fields[2], lr = ln.fields[3];
			if (pmapHeight(ll) >= pmapHeight(lr)) return pmapMake(ll, lk, lv, pmapMake(lr, k, v, r));
			var lrn = blockOf(lr);
			return pmapMake(pmapMake(ll, lk, lv, lrn.fields[0]), lrn.fields[1], lrn.fields[2], pmapMake(lrn.fields[3], k, v, r));
		}
		if (hr > hl + 2) {
			var rn = blockOf(r);
			var rl = rn.fields[0], rk = rn.fields[1], rv = rn.fields[2], rr = rn.fields[3];
			if (pmapHeight(rr) >= pmapHeight(rl)) return pmapMake(pmapMake(l, k, v, rl), rk, rv, rr);
			var rln = blockOf(rl);
			return pmapMake(pmapMake(l, k, v, rln.fields[0]), rln.fields[1], rln.fields[2], pmapMake(rln.fields[3], rk, rv, rr));
		}
		return node(l, k, v, r, OInt((hl >= hr ? hl : hr) + 1));
	}

	// (string * string index * ttype)
	static function fieldTuple(f:HlField):OValue
		return memoBlock(f, () -> [OStr(new OString(f.name)), OInt(f.nameIndex), ttypeValue(f.t)]);

	// (int * int)
	static function bindingTuple(b:{fid:Int, fidx:Int}):OValue
		return memoBlock(b, () -> [OInt(b.fid), OInt(b.fidx)]);

	// A tag-0 block for a source object, registered before its fields are built so cycles close on it.
	static function memoBlock(src:{}, fields:() -> Array<OValue>):OValue {
		var known = memo.get(src);
		if (known != null) return known;
		var b = new OBlockRef(0, []);
		var v = OBlock(b);
		memo.set(src, v);
		b.fields = fields();
		return v;
	}

	// An OCaml array: a tag-0 block, or the atom when empty.
	static function arrayOf<T>(a:Array<T>, f:T->OValue):OValue
		return memoBlock(a, () -> [for (x in a) f(x)]);

	// An OCaml list from an hxc array: [] is 0, x :: l a tag-0 block [x; l]. The whole list is one value per
	// array, so two arrays never share a tail.
	static function listOf<T>(a:Array<T>, f:T->OValue):OValue {
		var key:{} = a;
		var known = listMemo.get(key);
		if (known != null) return known;
		var items = [for (x in a) f(x)];
		var l = OInt(0);
		var i = items.length;
		while (i-- > 0) l = OBlock(new OBlockRef(0, [items[i], l]));
		listMemo.set(key, l);
		return l;
	}

	static function some(v:OValue):OValue
		return OBlock(new OBlockRef(0, [v]));

	static function intOption(i:Null<Int>):OValue
		return i == null ? OInt(0) : some(OInt(i));
}

// extern_rec, depth first: a block's header, then field 0, then the rest in order.
private class Marshaller {
	public final out = new BytesBuffer();
	public var objCounter = 0;
	public var size32 = 0;
	public var size64 = 0;

	final strings = new ObjectMap<OString, Int>();
	final blocks = new ObjectMap<OBlockRef, Int>();

	public function new() {}

	public function run(root:OValue) {
		// The stack holds blocks whose later fields are still to write, with the next index of each.
		var stackB:Array<OBlockRef> = [];
		var stackI:Array<Int> = [];
		var v = root;
		while (true) {
			var descend:Null<OBlockRef> = null;
			switch v {
				case OInt(n):
					externInt(n);
				case ODouble(f):
					out.addByte(0x0C); // CODE_DOUBLE_LITTLE
					out.addDouble(f);
					size32 += 1 + 2;
					size64 += 1 + 1;
					objCounter++;
				case OStr(s):
					var pos = strings.get(s);
					if (pos != null) {
						sharedReference(objCounter - pos);
					} else {
						var b = s.bytes();
						var len = b.length;
						if (len < 0x20)
							out.addByte(0x20 + len);
						else if (len < 0x100)
							code8(0x09, len);
						else
							code32(0x0A, len);
						out.add(b);
						size32 += 1 + Std.int((len + 4) / 4);
						size64 += 1 + Std.int((len + 8) / 8);
						strings.set(s, objCounter++);
					}
				case OBlock(b):
					if (b == HlcOcaml.UNMODELLED || b == HlcOcaml.PMAP_CMP) throw new Unmodelled(path(stackB, stackI));
					var sz = b.fields.length;
					if (sz == 0) {
						header(0, b.tag);
					} else {
						var pos = blocks.get(b);
						if (pos != null) {
							sharedReference(objCounter - pos);
						} else {
							header(sz, b.tag);
							size32 += 1 + sz;
							size64 += 1 + sz;
							blocks.set(b, objCounter++);
							descend = b;
						}
					}
			}
			if (descend != null) {
				stackB.push(descend);
				stackI.push(0);
			}
			// next_item: the next field of the innermost block that has one left.
			while (stackB.length > 0 && stackI[stackI.length - 1] >= stackB[stackB.length - 1].fields.length) {
				stackB.pop();
				stackI.pop();
			}
			if (stackB.length == 0) return;
			var top = stackB.length - 1;
			v = stackB[top].fields[stackI[top]];
			stackI[top]++;
		}
	}

	static function path(stackB:Array<OBlockRef>, stackI:Array<Int>):String {
		var parts = ["root"];
		for (i in 0...stackI.length) parts.push(Std.string(stackI[i] - 1));
		return parts.join(".");
	}

	function externInt(n:Int) {
		if (n >= 0 && n < 0x40) {
			out.addByte(0x40 + n);
		} else if (n >= -(1 << 7) && n < (1 << 7)) {
			code8(0x00, n);
		} else if (n >= -(1 << 15) && n < (1 << 15)) {
			out.addByte(0x01);
			out.addByte(n >> 8);
			out.addByte(n);
		} else if (n < -(1 << 30) || n >= (1 << 30)) {
			// CODE_INT64: the value sign-extended to 64 bits.
			out.addByte(0x03);
			var hi = n >> 31;
			for (s in [24, 16, 8, 0]) out.addByte(hi >>> s);
			for (s in [24, 16, 8, 0]) out.addByte(n >>> s);
		} else {
			code32(0x02, n);
		}
	}

	function sharedReference(d:Int) {
		if (d < 0x100) {
			code8(0x04, d);
		} else if (d < 0x10000) {
			out.addByte(0x05);
			out.addByte(d >> 8);
			out.addByte(d);
		} else {
			code32(0x06, d);
		}
	}

	// extern_header: PREFIX_SMALL_BLOCK for tag < 16 and size < 8, else CODE_BLOCK32 with the white header
	// (size << 10 | tag), which fits 32 bits for any block this model builds.
	function header(sz:Int, tag:Int) {
		if (tag < 16 && sz < 8) {
			out.addByte(0x80 + tag + (sz << 4));
		} else {
			if (sz >= 1 << 22) throw "block too large for CODE_BLOCK32";
			code32(0x08, (sz << 10) | tag);
		}
	}

	function code8(code:Int, v:Int) {
		out.addByte(code);
		out.addByte(v & 0xFF);
	}

	function code32(code:Int, v:Int) {
		out.addByte(code);
		out.addByte(v >>> 24);
		out.addByte(v >>> 16);
		out.addByte(v >>> 8);
		out.addByte(v);
	}
}

// OCaml's polymorphic Hashtbl (stdlib/hashtbl.ml), unseeded, keyed by OValue with compare = 0 equality.
// Buckets are linked cells as in OCaml, so iter and fold see the same cells OCaml's would, including while
// the table changes under them.
class CamlHashtbl<V> {
	var size = 0;
	var data:Array<Null<CamlCell<V>>>;
	// hashtbl.ml keeps this flag as the sign of initial_size: a resize during a traversal copies cells.
	var ongoingTraversal = false;

	// Hashtbl.create n: power_2_above 16 n buckets.
	public function new(initialSize:Int = 0) {
		var s = 16;
		while (s < initialSize) s *= 2;
		data = [for (_ in 0...s) null];
	}

	public function length():Int
		return size;

	inline function index(h:Int):Int
		return h & (data.length - 1);

	public function add(key:OValue, value:V):Void {
		var h = HlcOcaml.hash(key);
		var i = index(h);
		data[i] = new CamlCell(key, value, h, data[i]);
		size++;
		if (size > data.length << 1) resize();
	}

	public function replace(key:OValue, value:V):Void {
		var h = HlcOcaml.hash(key);
		var i = index(h);
		var c = data[i];
		while (c != null) {
			if (HlcOcaml.equal(c.key, key)) {
				c.key = key;
				c.data = value;
				return;
			}
			c = c.next;
		}
		data[i] = new CamlCell(key, value, h, data[i]);
		size++;
		if (size > data.length << 1) resize();
	}

	public function find(key:OValue):Null<V> {
		var c = data[index(HlcOcaml.hash(key))];
		while (c != null) {
			if (HlcOcaml.equal(key, c.key)) return c.data;
			c = c.next;
		}
		return null;
	}

	public function mem(key:OValue):Bool {
		var c = data[index(HlcOcaml.hash(key))];
		while (c != null) {
			if (HlcOcaml.equal(c.key, key)) return true;
			c = c.next;
		}
		return false;
	}

	// resize and insert_all_buckets: old buckets ascending, each front to back, appended to the tail of the
	// new bucket, so cells keep their relative order.
	function resize():Void {
		var odata = data;
		var nsize = odata.length * 2;
		var ndata:Array<Null<CamlCell<V>>> = [for (_ in 0...nsize) null];
		var tails:Array<Null<CamlCell<V>>> = [for (_ in 0...nsize) null];
		var inplace = !ongoingTraversal;
		data = ndata;
		for (i in 0...odata.length) {
			var c = odata[i];
			while (c != null) {
				var next = c.next;
				var cell = inplace ? c : new CamlCell(c.key, c.data, c.hash, null);
				var ni = c.hash & (nsize - 1);
				var tail = tails[ni];
				if (tail == null) ndata[ni] = cell else tail.next = cell;
				tails[ni] = cell;
				c = next;
			}
		}
		if (inplace) for (t in tails) if (t != null) t.next = null;
	}

	public function iter(f:(OValue, V) -> Void):Void {
		var old = ongoingTraversal;
		ongoingTraversal = true;
		try {
			var d = data;
			for (i in 0...d.length) {
				var c = d[i];
				while (c != null) {
					// OCaml's do_bucket matches the cell's fields before calling f.
					var next = c.next;
					f(c.key, c.data);
					c = next;
				}
			}
		} catch (e:Dynamic) {
			ongoingTraversal = old;
			throw e;
		}
		ongoingTraversal = old;
	}

	public function fold<A>(f:(OValue, V, A) -> A, init:A):A {
		var old = ongoingTraversal;
		ongoingTraversal = true;
		var acc = init;
		try {
			var d = data;
			for (i in 0...d.length) {
				var c = d[i];
				while (c != null) {
					var next = c.next;
					acc = f(c.key, c.data, acc);
					c = next;
				}
			}
		} catch (e:Dynamic) {
			ongoingTraversal = old;
			throw e;
		}
		ongoingTraversal = old;
		return acc;
	}
}

private class CamlCell<V> {
	public var key:OValue;
	public var data:V;
	public final hash:Int;
	public var next:Null<CamlCell<V>>;

	public function new(key:OValue, data:V, hash:Int, next:Null<CamlCell<V>>) {
		this.key = key;
		this.data = data;
		this.hash = hash;
		this.next = next;
	}
}
