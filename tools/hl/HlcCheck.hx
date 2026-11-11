import haxe.io.Bytes;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlcOcaml;
import hxc.codegen.hl.HlDump.HlHashOrder;

// Checks HlcOcaml's models of OCaml's Hashtbl.hash, Hashtbl and Marshal against values Haxe 4.3.7 produced:
// t$fun_ names from its HL/C types.c (MD5 of Marshal.to_bytes of hl2c's type_desc), and the local
// declaration order of P_main (Hashtbl.iter over (string, int) keys).
// Usage: haxe -cp src -cp tools/hl --run HlcCheck
class HlcCheck {
	static var failures = 0;

	static function check(name:String, ok:Bool, ?detail:String) {
		if (!ok) {
			failures++;
			Sys.println("FAIL " + name + (detail == null ? "" : ": " + detail));
		}
	}

	static function eq<T>(name:String, got:T, want:T) {
		check(name, got == want, "got " + Std.string(got) + ", want " + Std.string(want));
	}

	static function proto(name:String):HlClassProto {
		return {
			pname: name,
			pid: 0,
			pclassglobal: null,
			psuper: null,
			pvirtuals: [],
			pproto: [],
			pnfields: 0,
			pfields: [],
			pindex: new Map(),
			pfunctions: new Map(),
			pinterfaces: [],
			pbindings: []
		};
	}

	// hl2c.ml's type_desc: DSimple of ttype (tag 0) | DFun of type_desc list * type_desc * bool (tag 1)
	// | DNamed of string (tag 2) | DVirtual of (string * type_desc) array (tag 3). DNamed holds the very
	// string of the proto (p.pname), and DVirtual's names are the vfields' own strings.
	static function descValue(t:HlType):OValue {
		return switch t {
			case HFun(args, ret):
				OBlock(new OBlockRef(1, [list([for (a in args) descValue(a)]), descValue(ret), OInt(1)]));
			case HObj(_):
				OBlock(new OBlockRef(2, [OStr(HlcOcaml.typeNameString(t))]));
			case HVirtual(vp):
				var vb = block(block(HlcOcaml.ttypeValue(t)).fields[0]);
				var fields = block(vb.fields[0]).fields;
				// The constructor's one field is the array, a block of its own.
				OBlock(new OBlockRef(3, [
					OBlock(new OBlockRef(0, [
						for (i in 0...vp.vfields.length)
							OBlock(new OBlockRef(0, [block(fields[i]).fields[0], descValue(vp.vfields[i].t)]))
					]))
				]));
			default:
				OBlock(new OBlockRef(0, [HlcOcaml.ttypeValue(t)]));
		}
	}

	static function block(v:OValue):OBlockRef {
		return switch v {
			case OBlock(b): b;
			default: throw "not a block: " + Std.string(v);
		}
	}

	static function list(items:Array<OValue>):OValue {
		var l = OInt(0);
		var i = items.length;
		while (i-- > 0) l = OBlock(new OBlockRef(0, [items[i], l]));
		return l;
	}

	static function funName(t:HlType):String {
		return "t$fun_" + HlcOcaml.md5Hex(HlcOcaml.marshal(descValue(t))).substr(0, 7);
	}

	static function vrtName(t:HlType):String {
		return "t$vrt_" + HlcOcaml.md5Hex(HlcOcaml.marshal(descValue(t))).substr(0, 7);
	}

	static function key(s:String, i:Int):OValue {
		return OBlock(new OBlockRef(0, [OStr(new OString(s)), OInt(i)]));
	}

	static function keyString(k:OValue):String {
		var b = block(k);
		return switch [b.fields[0], b.fields[1]] {
			case [OStr(s), OInt(i)]: s.s + "," + i;
			default: "?";
		}
	}

	static function main() {
		var str = HObj(proto("String"));
		var arrDyn = HObj(proto("hl.types.ArrayDyn"));
		var arrBase = HObj(proto("hl.types.ArrayBase"));

		// Function type names (Haxe 4.3.7's types.c).
		eq("(i32):String", funName(HFun([HI32], str)), "t$fun_431710a");
		eq("(bytes,i32):String", funName(HFun([HBytes, HI32], str)), "t$fun_7daa93c");
		eq("(dyn):bytes", funName(HFun([HDyn], HBytes)), "t$fun_83f90f5");
		eq("(bytes):String", funName(HFun([HBytes], str)), "t$fun_07b476c");
		eq("(String,String):String", funName(HFun([str, str], str)), "t$fun_2e5590a");
		// Further vectors from the same types.c.
		eq("():void", funName(HFun([], HVoid)), "t$fun_7b48b4f");
		eq("(i32,i32):i32", funName(HFun([HI32, HI32], HI32)), "t$fun_1f02863");
		eq("(i32,ref(i32)):bytes", funName(HFun([HI32, HRef(HI32)], HBytes)), "t$fun_fab01bb");
		eq("(hl.types.ArrayBase,ref(bool)):hl.types.ArrayDyn", funName(HFun([arrBase, HRef(HBool)], arrDyn)), "t$fun_17cbfdc");
		var cmp = HFun([HDyn, HDyn], HI32);
		eq("(hl.types.ArrayDyn,(dyn,dyn):i32,i32,i32):void", funName(HFun([arrDyn, cmp, HI32, HI32], HVoid)), "t$fun_8245b77");
		eq("(bytes,i32,i32,(i32,i32):i32):void", funName(HFun([HBytes, HI32, HI32, HFun([HI32, HI32], HI32)], HVoid)), "t$fun_544176c");
		var posInfos = HVirtual({
			vfields: [
				{name: "className", nameIndex: 0, t: str},
				{name: "customParams", nameIndex: 0, t: arrDyn},
				{name: "fileName", nameIndex: 0, t: str},
				{name: "lineNumber", nameIndex: 0, t: HI32},
				{name: "methodName", nameIndex: 0, t: str}
			],
			vindex: new Map()
		});
		eq("virtual(className:String,...)", vrtName(posInfos), "t$vrt_eaa6a3b");
		eq("(dyn,virtual(...)):String", funName(HFun([HDyn, posInfos], str)), "t$fun_358bb66");
		eq("(dyn,virtual(...)):void", funName(HFun([HDyn, posInfos], HVoid)), "t$fun_439b121");

		// Local-declaration order (P_main): replace in this order, then iter.
		var decls = new CamlHashtbl<Bool>();
		for (k in [key("int", 0), key("String", 0), key("vclosure", 1), key("haxe__$Log", 0), key("int", 1), key("vbyte", 1), key("vdynobj", 1),
			key("vvirtual", 1)])
			decls.replace(k, true);
		var order = [];
		decls.iter((k, _) -> order.push(keyString(k)));
		eq("P_main declaration order", order.join(" "), "vdynobj,1 String,0 vvirtual,1 haxe__$Log,0 vclosure,1 int,1 vbyte,1 int,0");
		var folded = decls.fold((k, _, acc:Array<String>) -> {
			acc.push(keyString(k));
			acc;
		}, []);
		eq("fold visits as iter", folded.join(" "), order.join(" "));
		check("find", decls.find(key("vbyte", 1)) == true);
		check("find missing", decls.find(key("vbyte", 0)) == null);
		check("mem", decls.mem(key("haxe__$Log", 0)) && !decls.mem(key("haxe__$Log", 1)));

		// Strings hash as HlDump's string-keyed model does.
		eq("hash \"hello\"", HlcOcaml.hash(OStr(new OString("hello"))), HlHashOrder.stringHash("hello"));
		eq("hash \"\"", HlcOcaml.hash(OStr(new OString(""))), 0);
		for (s in ["a", "ab", "abc", "abcd", "abcde", "haxe__$Log", "t$fun_431710a"])
			eq("hash " + s, HlcOcaml.hash(OStr(new OString(s))), HlHashOrder.stringHash(s));

		// The sentinel throws when the walk reaches it.
		var bad = OBlock(new OBlockRef(0, [OInt(1), OInt(2), OBlock(HlcOcaml.UNMODELLED), OInt(4)]));
		var threw = false;
		try
			HlcOcaml.hash(bad)
		catch (e:Unmodelled)
			threw = true;
		check("hash reaches sentinel", threw);
		// ... but not when ten meaningful values come first.
		var far = OBlock(new OBlockRef(0, [for (i in 0...10) OInt(i)].concat([OBlock(HlcOcaml.UNMODELLED)])));
		var farOk = try {
			HlcOcaml.hash(far);
			true;
		} catch (e:Unmodelled) false;
		check("hash stops before sentinel", farOk);
		threw = false;
		try
			HlcOcaml.marshal(bad)
		catch (e:Unmodelled)
			threw = true;
		check("marshal reaches sentinel", threw);

		// 70 adds: 16 -> 32 -> 64 buckets. iter goes by hash land 63, each bucket newest first.
		var t = new CamlHashtbl<Int>();
		for (i in 0...70) t.add(OInt(i), i);
		var got = [];
		t.iter((k, v) -> got.push(v));
		var want = [];
		for (b in 0...64) {
			var i = 70;
			while (i-- > 0) if (HlcOcaml.hash(OInt(i)) & 63 == b) want.push(i);
		}
		eq("70 adds visit order", got.join(","), want.join(","));
		var seen = new Map<Int, Bool>();
		for (i in 0...70) seen.set(HlcOcaml.hash(OInt(i)) & 63, true);
		check("70 adds spread over more than 32 buckets", Lambda.count(seen) > 32);

		// Marshal sharing: the same OString twice is a shared reference; equal but distinct strings are not.
		var s = new OString("ab");
		var shared = HlcOcaml.marshal(OBlock(new OBlockRef(0, [OStr(s), OStr(s)])));
		eq("marshal shared", shared.sub(20, shared.length - 20).toHex(), "a0" + "226162" + "0401");
		var apart = HlcOcaml.marshal(OBlock(new OBlockRef(0, [OStr(s), OStr(new OString("ab"))])));
		eq("marshal apart", apart.sub(20, apart.length - 20).toHex(), "a0" + "226162" + "226162");
		eq("marshal header", shared.sub(0, 20).toHex(), "8495a6be" + "00000006" + "00000002" + "00000005" + "00000005");

		if (failures > 0) {
			Sys.println("HlcCheck: " + failures + " check(s) failed");
			Sys.exit(1);
		}
		Sys.println("HlcCheck: all checks passed");
	}
}
