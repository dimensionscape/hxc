import haxe.io.Bytes;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlcOcaml;
import hxc.codegen.hl.HlcNames;
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

	static function emptyCode():HlCodeData {
		return {
			version: 4,
			entrypoint: 0,
			strings: [],
			ints: [],
			floats: [],
			bytes: [],
			globals: [],
			natives: [],
			functions: [],
			debugfiles: [],
			constants: []
		};
	}

	// A code whose globals are String constants with these values, in this order.
	static function stringConstants(values:Array<String>):HlCodeData {
		var code = emptyCode();
		var str = HObj(proto("String"));
		for (i in 0...values.length) {
			code.strings.push(values[i]);
			code.globals.push(str);
			code.constants.push({global: i, fields: [i, values[i].length]});
		}
		return code;
	}

	// HlcNames against Haxe 4.3.7's HL/C output (scratch probes; the sources are in the Task 3 report).
	static function namesChecks() {
		var str = HObj(proto("String"));

		// make_types_idents: the five function types of the hlc-probe's types.c, and the types under them.
		var code = emptyCode();
		var funs = [HFun([HI32], str), HFun([HBytes, HI32], str), HFun([HDyn], HBytes), HFun([HBytes], str), HFun([str, str], str)];
		code.globals = funs.copy();
		var ids = HlcNames.makeTypesIdents(new HlTypeTable(code));
		eq("ident (i32):String", ids.get(funs[0]), "t$fun_431710a");
		eq("ident (bytes,i32):String", ids.get(funs[1]), "t$fun_7daa93c");
		eq("ident (dyn):bytes", ids.get(funs[2]), "t$fun_83f90f5");
		eq("ident (bytes):String", ids.get(funs[3]), "t$fun_07b476c");
		eq("ident (String,String):String", ids.get(funs[4]), "t$fun_2e5590a");
		eq("ident String", ids.get(str), "t$String");
		eq("ident i32", ids.get(HI32), "t$_i32");
		eq("ident bytes", ids.get(HBytes), "t$_bytes");
		eq("ident void", ids.get(HVoid), "t$_void");
		// Names that are not function types (the hlc-probe and the sharing probe's types.c).
		var nul = HNull(HI32);
		var code2 = emptyCode();
		var abs = HAbstract("hl_bytes_map", 0);
		var dynObj = HObj(proto("$String"));
		code2.globals = [nul, HRef(HBool), abs, dynObj, HObj(proto("hl.types.ArrayBase"))];
		var ids2 = HlcNames.makeTypesIdents(new HlTypeTable(code2));
		eq("ident null(i32)", ids2.get(nul), "t$nul_i32");
		eq("ident ref(bool)", ids2.get(HRef(HBool)), "t$ref_bool");
		eq("ident abstract", ids2.get(abs), "t$hl_bytes_map");
		eq("ident $String", ids2.get(dynObj), "t$$String");
		eq("ident dotted", ids2.get(code2.globals[4]), "t$hl_types_ArrayBase");

		// Sharing inside a marshalled desc (the sharing probe's types.c). genhl's to_type builds each HNull and
		// HRef afresh, so two in one function type are distinct blocks; a shared one is a back-reference and
		// gives another name. BytesMap's three uses are one hl.Abstract<"hl_bytes_map"> declaration, so one
		// object here (one name string in genhl), and one virtual proto reached twice is one DVirtual.
		var code3 = emptyCode();
		var nullsApart = HFun([HNull(HI32), HNull(HI32)], HNull(HI32));
		var nullShared = HNull(HI32);
		var oneApart = HFun([HNull(HI32)], HNull(HI32));
		var oneShared = HFun([nullShared], nullShared);
		var mixed = HFun([HNull(HF64), HRef(HF64), HNull(HF64), HRef(HF64)], HVoid);
		var absFun = HFun([abs, abs], abs);
		var inner = HVirtual({vfields: [{name: "x", nameIndex: 0, t: HI32}], vindex: new Map()});
		var outer = HVirtual({vfields: [{name: "x", nameIndex: 0, t: HI32}, {name: "y", nameIndex: 0, t: inner}], vindex: new Map()});
		var twice = HFun([outer, outer], HVoid);
		var recProto:HlVirtualProto = {vfields: [], vindex: new Map()};
		var rec = HVirtual(recProto);
		recProto.vfields = [{name: "next", nameIndex: 0, t: rec}, {name: "v", nameIndex: 0, t: HI32}];
		var recFun = HFun([rec, rec], HVoid);
		code3.globals = [nullsApart, oneApart, mixed, absFun, twice, recFun];
		var ids3 = HlcNames.makeTypesIdents(new HlTypeTable(code3));
		eq("ident (null(i32),null(i32)):null(i32)", ids3.get(nullsApart), "t$fun_c61184d");
		eq("ident (null(i32)):null(i32)", ids3.get(oneApart), "t$fun_5a98bcd");
		eq("ident (null(f64),ref(f64),null(f64),ref(f64)):void", ids3.get(mixed), "t$fun_3c9cb46");
		eq("ident (abstract x3)", ids3.get(absFun), "t$fun_cdd866e");
		eq("ident virtual(x,y:virtual(x))", ids3.get(outer), "t$vrt_4edc966");
		eq("ident virtual(x)", ids3.get(inner), "t$vrt_7ef285a");
		eq("ident (virtual,virtual):void", ids3.get(twice), "t$fun_c8b47b0");
		eq("ident virtual(next:...,v)", ids3.get(rec), "t$vrt_a19e6bb");
		eq("ident (rec,rec):void", ids3.get(recFun), "t$fun_53f504f");
		var code4 = emptyCode();
		code4.globals = [oneShared];
		check("shared null(i32) is a back-reference", HlcNames.makeTypesIdents(new HlTypeTable(code4)).get(oneShared) != "t$fun_5a98bcd");
		// An abstract's name string is shared per hl.Abstract<"..."> declaration, not per name (the abstract
		// probe's types.c): direct(a:hl.Abstract<"hlc_d">, b:hl.Abstract<"hlc_d">):hl.Abstract<"hlc_d"> has three
		// declarations, three strings; viaTypedef(a:X, b:X):X with typedef X = hl.Abstract<"hlc_x"> has one;
		// mixedDecl(a:X, b:hl.Abstract<"hlc_x">) has two. hxc's front end makes one HAbstract per declaration
		// (HlContext.abstractTypes), and ttypeValue one string per HAbstract.
		var code5 = emptyCode();
		var direct = HFun([HAbstract("hlc_d", 1), HAbstract("hlc_d", 1)], HAbstract("hlc_d", 1));
		var x = HAbstract("hlc_x", 2);
		var viaTypedef = HFun([x, x], x);
		var mixedDecl = HFun([x, HAbstract("hlc_x", 2)], HVoid);
		code5.globals = [direct, viaTypedef, mixedDecl];
		var ids5 = HlcNames.makeTypesIdents(new HlTypeTable(code5));
		eq("ident (abstract x3, three declarations)", ids5.get(direct), "t$fun_2dadd64");
		eq("ident (abstract x3, one declaration)", ids5.get(viaTypedef), "t$fun_d8cc033");
		eq("ident (abstract x2, two declarations)", ids5.get(mixedDecl), "t$fun_b11d96e");
		eq("ident abstract hlc_x", ids5.get(x), "t$hlc_x");

		// A vfield's name string is its class field's cf_name, so fields with one nameOrigin share it (the
		// hlc-shared-*-names and hlc-separate-field-names cases' types.c). two(a:Box<Int>, b:Box<String>):
		// apply_params' copies keep Box's "value"; two(a:{value:Int}, b:{value:String}) has two strings.
		var boxValue = {};
		function boxes(o1:Null<{}>, o2:Null<{}>):HlType
			return HFun([
				HVirtual({vfields: [{name: "value", nameIndex: 47, t: HI32, nameOrigin: o1}], vindex: new Map()}),
				HVirtual({vfields: [{name: "value", nameIndex: 47, t: str, nameOrigin: o2}], vindex: new Map()})
			], HI32);
		// One table each: make_types_idents' types_descs would give the later virtuals the first ones' descs.
		function boxName(t:HlType):String {
			var code = emptyCode();
			code.globals = [t];
			return HlcNames.makeTypesIdents(new HlTypeTable(code)).get(t);
		}
		eq("ident (Box<Int>,Box<String>):i32, one \"value\"", boxName(boxes(boxValue, boxValue)), "t$fun_9d35f87");
		eq("ident ({value:Int},{value:String}):i32, two \"value\"", boxName(boxes({}, {})), "t$fun_f101870");
		eq("ident (virtual(value),virtual(value)):i32, no origin", boxName(boxes(null, null)), "t$fun_f101870");
		// mac(a:Built, b:Built2) of hlc-macro-literal-names (one "x" and one "y", the macro's literals) and of
		// hlc-macro-separate-names (four strings), with -D hl_no_opt.
		function built(xs:Array<{}>, ys:Array<{}>):HlType
			return HFun([
				HVirtual({vfields: [{name: "x", nameIndex: 47, t: HI32, nameOrigin: xs[0]}, {name: "y", nameIndex: 48, t: HI32, nameOrigin: ys[0]}], vindex: new Map()}),
				HVirtual({vfields: [{name: "x", nameIndex: 47, t: str, nameOrigin: xs[1]}, {name: "y", nameIndex: 48, t: HI32, nameOrigin: ys[1]}], vindex: new Map()})
			], HI32);
		var litX = {}, litY = {};
		eq("ident (Built,Built2):i32, macro literals", boxName(built([litX, litX], [litY, litY])), "t$fun_1355c99");
		eq("ident (Built,Built2):i32, separate strings", boxName(built([{}, {}], [{}, {}])), "t$fun_2da0c0a");
		// interface IB extends IA { function g(a:IA):Int; }: IB's virtual holds IA's f itself, so "f" is shared
		// with g's argument, IA's virtual.
		var fOrigin = {};
		var fType = HMethod([], HI32);
		var ia = HVirtual({vfields: [{name: "f", nameIndex: 0, t: fType, nameOrigin: fOrigin}], vindex: new Map()});
		var ib = HVirtual({
			vfields: [
				{name: "g", nameIndex: 0, t: HMethod([ia], HI32), nameOrigin: {}},
				{name: "f", nameIndex: 0, t: fType, nameOrigin: fOrigin}
			],
			vindex: new Map()
		});
		var code7 = emptyCode();
		code7.globals = [ib];
		var ids7 = HlcNames.makeTypesIdents(new HlTypeTable(code7));
		eq("ident IB, one \"f\"", ids7.get(ib), "t$vrt_992e488");
		eq("ident IA", ids7.get(ia), "t$vrt_07f2cb0");

		// make_global_names: the hlc-probe's globals.c, then the global-names probe's.
		var gcode = stringConstants(["hello ", "s"]);
		var gn = HlcNames.makeGlobalNames(gcode, ["", ""]);
		eq("global hello", gn[0], "s$hello_");
		eq("global s", gn[1], "s$s");
		var values = ["a b", "a_b", "a-b", "0123456789012345678901234567890123456789", "_", "84c4047", "(", "!", "?", "zz", "zz ", "h\u00e9llo", "x\ty",
			StringTools.lpad("", "A", 80), "abcdefghijklmnopqrstuvwxyz012345", "abcdefghijklmnopqrstuvwxyz0123456", "q\"\\n\r\x01z"];
		var want = ["s$0cc9cd4", "s$dbf08e0", "s$8ca2ed5", "s$9f0ae03", "s$b14a7b8", "s$84c4047_1", "s$84c4047", "s$9033e0e", "s$d1457b7", "s$zz", "s$zz_",
			"s$h_llo", "s$x_y", "s$d1d9abe", "s$abcdefghijklmnopqrstuvwxyz012345", "s$2e34e06", "s$q_n_z"];
		var gn2 = HlcNames.makeGlobalNames(stringConstants(values), [for (_ in values) ""]);
		for (i in 0...values.length) eq("global " + HlcNames.ocamlEscaped(values[i]), gn2[i], want[i]);
		// The hlc-global-names case's constants, with the names in Haxe's hl/globals.c for it.
		var caseValues = ["a b", "a_b", "a-b", "_", "0123456789012345678901234567890123456789"];
		var caseWant = ["s$0cc9cd4", "s$dbf08e0", "s$8ca2ed5", "s$b14a7b8", "s$9f0ae03"];
		var gn3 = HlcNames.makeGlobalNames(stringConstants(caseValues), [for (_ in caseValues) ""]);
		for (i in 0...caseValues.length) eq("hlc-global-names " + caseValues[i], gn3[i], caseWant[i]);

		// short_digest, the hash of a field name (types.c's field tables) and the collision loop (hl_hash of
		// fcbzlgd and fhnmljx is the same; Haxe hashed fcbzlgd first).
		eq("short_digest (", HlcNames.shortDigest("("), "84c4047");
		eq("short_digest \\n", HlcNames.shortDigest("\n"), "68b329d");
		eq("hl_hash __type__", HlcNames.hlHash("__type__"), -10071174);
		eq("hl_hash bytes", HlcNames.hlHash("bytes"), -40368287);
		eq("hl_hash toString", HlcNames.hlHash("toString"), 409915697);
		eq("hl_hash __implementedBy__", HlcNames.hlHash("__implementedBy__"), 25734275);
		var hc = new HashCache();
		var hstrings = ["fcbzlgd", "fhnmljx"];
		eq("hash fcbzlgd", hc.hash(hstrings, 0), -451069868);
		eq("hash fhnmljx", hc.hash(hstrings, 1), -451069867);
		eq("hash fcbzlgd again", hc.hash(hstrings, 0), -451069868);
		eq("hash order", hc.order.join(","), "0,1");

		// string: USTR with s_escape below 64 bytes, string$<digest> from 64 (globals.c).
		var scode = emptyCode();
		scode.strings = ["q\"\\n\r\x01z", "h\u00e9llo", StringTools.lpad("", "A", 80)];
		var defs = [];
		eq("string escaped", HlcNames.stringLiteral(scode, 0, defs.push), 'USTR("q\\"\\\\n\\r\\x01z")');
		eq("string utf8", HlcNames.stringLiteral(scode, 1, defs.push), 'USTR("h\u00e9llo")');
		eq("string long", HlcNames.stringLiteral(scode, 2, defs.push), "string$d1d9abe");
		eq("string long define", defs.join("|"), "extern vbyte string$d1d9abe[];");

		// The OFloat text (the float probes' _std/P.c).
		var negZero = haxe.io.FPHelper.i64ToDouble(0, 0x80000000);
		var floats:Array<{f:Float, s:String}> = [
			{f: 0.1, s: "0.10000000000000001"},
			{f: 1e300, s: "1.0000000000000001e+300"},
			{f: 5e-324, s: "4.9406564584124654e-324"},
			{f: negZero, s: "-0."},
			{f: Math.POSITIVE_INFINITY, s: "inf."},
			{f: Math.NEGATIVE_INFINITY, s: "-inf."},
			{f: 1.0, s: "1."},
			{f: 100.0, s: "100."},
			{f: 1e21, s: "1e+021"},
			{f: 1e-7, s: "9.9999999999999995e-008"},
			{f: 1e18, s: "1000000000000000000."},
			{f: 1e19, s: "1e+019"},
			{f: 0.3, s: "0.29999999999999999"},
			{f: 2.0 / 3.0, s: "0.66666666666666663"},
			{f: 1e-5, s: "1.0000000000000001e-005"},
			{f: 0.0001, s: "0.0001"},
			{f: 2.5e-310, s: "2.5000000000000171e-310"},
			{f: 1.7976931348623157e308, s: "1.7976931348623157e+308"},
			{f: 3.0e15, s: "3000000000000000."},
			{f: 123456789012345678901234.0, s: "1.2345678901234569e+023"},
			// exact ties at the 17th digit round down
			{f: 100000000000000.125, s: "100000000000000.12"},
			{f: 100000000000000.375, s: "100000000000000.37"},
			{f: 1000000000000000.75, s: "1000000000000000.7"},
			{f: 1152921504606846976.0, s: "1152921504606847000."},
			{f: 0.99999999999999999, s: "1."},
			{f: 0.9999999999999999, s: "0.99999999999999989"},
			{f: 2.2250738585072009e-308, s: "2.2250738585072009e-308"}
		];
		for (v in floats) eq("float " + v.s, HlcNames.floatLiteral(v.f), v.s);

		// String.escaped (OCaml), on UTF-8 bytes.
		eq("escaped", HlcNames.ocamlEscaped("a\"b\\c\n\t\x01\u00e9"), "a\\\"b\\\\c\\n\\t\\001\\195\\169");

		// ident and the C types.
		// (a keyword probe's _std/P.h: fields int, t and plain; the hlc-probe's __constructor__)
		eq("ident int", HlcNames.ident("int"), "_hx_int");
		eq("ident t", HlcNames.ident("t"), "_hx_t");
		eq("ident plain", HlcNames.ident("plain"), "plain");
		eq("ident __constructor__", HlcNames.ident("__constructor__"), "_hx___constructor__");
		eq("var_type", HlcNames.varType("int", HI32), "int _hx_int");
		eq("ctype String", HlcNames.ctype(str), "String");
		eq("ctype $String", HlcNames.ctype(HObj(proto("$String"))), "$String");
		eq("ctype hl.types.ArrayBase", HlcNames.ctype(HObj(proto("hl.types.ArrayBase"))), "hl__types__ArrayBase");
		eq("ctype abstract", HlcNames.ctype(abs), "hl_bytes_map*");
		eq("ctype ref(i32)", HlcNames.ctype(HRef(HI32)), "int*");
		eq("ctype enum", HlcNames.ctype(HEnum({ename: "haxe.io.Error", eid: 1, eglobal: null, efields: []})), "venum*");
		eq("args_repr", HlcNames.argsRepr([HBytes, HI32, HRef(HI32)]), "vbyte*,int,int*");
		eq("args_repr void", HlcNames.argsRepr([]), "void");

		// A 7-digit collision (hlc-digest-collision's types.c): both digests start f8d4f18, and the type
		// PMap.mapi visits second gets the full digest. Re-signing a desc (desc_string on DSimple (HRef t) with
		// a function t) also finds its 7 digits taken: Haxe wrote t$ref_t$fun_cb6e3d37d4a166890af599b23180a494.
		var collA = HFun([HI32, HF64, str, HBool], HI32);
		var collB = HFun([HBool, HDyn, HBool, HF64, HI32], str);
		eq("(i32,f64,String,bool):i32", funName(collA), "t$fun_f8d4f18");
		eq("(bool,dyn,bool,f64,i32):String", funName(collB), "t$fun_f8d4f18");
		eq("(i32,f64,String,bool):i32 full", HlcOcaml.md5Hex(HlcOcaml.marshal(descValue(collA))), "f8d4f18090985197954432adf9fb76cc");
		eq("(bool,dyn,bool,f64,i32):String full", HlcOcaml.md5Hex(HlcOcaml.marshal(descValue(collB))), "f8d4f1891ec96b1ed214e7240a057de3");
		var f64Bool = HFun([HF64], HBool);
		eq("(f64):bool full", HlcOcaml.md5Hex(HlcOcaml.marshal(descValue(f64Bool))), "cb6e3d37d4a166890af599b23180a494");
		eq("(ref((f64):bool)):bool", funName(HFun([HRef(f64Bool)], HBool)), "t$fun_19055a6");
		for (pair in [[collA, collB], [collB, collA]]) {
			var c = emptyCode();
			c.globals = pair;
			var cids = HlcNames.makeTypesIdents(new HlTypeTable(c));
			var a = cids.get(collA), b = cids.get(collB);
			var names = a + " " + b;
			check("one collision side keeps 7 digits", names == "t$fun_f8d4f18 t$fun_f8d4f1891ec96b1ed214e7240a057de3"
				|| names == "t$fun_f8d4f18090985197954432adf9fb76cc t$fun_f8d4f18", names);
		}
		var c = emptyCode();
		var refF = HRef(f64Bool);
		c.globals = [f64Bool, refF];
		var cids = HlcNames.makeTypesIdents(new HlTypeTable(c));
		var signs = cids.get(f64Bool) + " " + cids.get(refF);
		check("ref re-signs its function type",
			signs == "t$fun_cb6e3d3 t$ref_t$fun_cb6e3d37d4a166890af599b23180a494"
			|| signs == "t$fun_cb6e3d37d4a166890af599b23180a494 t$ref_t$fun_cb6e3d3", signs);
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

		// A virtual's vindex: ExtLib's PMap of (name, index) added in index order. Sorted names make a chain,
		// since PMap's bal tolerates a height difference of 2; two protos with equal vfields compare equal
		// through it (the shared `compare` closure is skipped by identity).
		function abc():HlType
			return HVirtual({vfields: [for (n in ["a", "b", "c"]) {name: n, nameIndex: 0, t: HI32}], vindex: new Map()});
		var va = abc(), vb = abc();
		var vindex = block(block(HlcOcaml.ttypeValue(va)).fields[0]).fields[1];
		var shape = Std.string(block(vindex).fields[1]);
		eq("vindex shape", shape,
			'OBlock([0|OInt(0),OStr("a"),OInt(0),OBlock([0|OInt(0),OStr("b"),OInt(1),OBlock([0|OInt(0),OStr("c"),OInt(2),OInt(0),OInt(1)]),OInt(2)]),OInt(3)])');
		eq("equal virtuals compare", HlcOcaml.compare(HlcOcaml.ttypeValue(HFun([va], HI32)), HlcOcaml.ttypeValue(HFun([vb], HI32))), 0);
		threw = false;
		try
			HlcOcaml.hash(vindex)
		catch (e:Unmodelled)
			threw = true;
		check("hash reaches the PMap's closure", threw);

		// hl.Ref of a class marshals its proto, maps and all (hlc-ref probes: class C { public var x:Int; }
		// and static function f(r:hl.Ref<C>)). The maps' compare closure is written with the MD5 of haxe.exe's
		// code as loaded, which differs with the load address: Haxe named (ref(C)):void t$fun_02c4ee9 when
		// that MD5 was 97bc8dcb... and t$fun_9e384e2 (a copy of haxe.exe) when it was 445b13c4... . pid 34,
		// $C global 3, "x" string 35; pindex is {x: (0, i32)} after genhl's two adds, and pfunctions and
		// pinterfaces are PMap.empty, one record.
		function refC():HlType {
			var c = proto("C");
			c.pid = 34;
			c.pclassglobal = 3;
			c.pnfields = 1;
			var x = {};
			c.pfields = [{name: "x", nameIndex: 35, t: HI32, nameOrigin: x}];
			c.pindexAdds = [{name: "x", nameOrigin: x, index: 0, t: HVoid}, {name: "x", nameOrigin: x, index: 0, t: HI32}];
			c.pfunctionsAdds = [];
			return HFun([HRef(HObj(c))], HVoid);
		}
		var message = try {
			funName(refC());
			"no throw";
		} catch (e:Unmodelled) e.message;
		check("marshal reaches the PMap's closure", StringTools.startsWith(message, "the compare closure of a PMap") && StringTools.endsWith(message, "(root.0.0.0.0.0.8.0)"), message);
		for (v in [["97bc8dcb49ae5139dfd2acd5b9f11deb", "t$fun_02c4ee9"], ["445b13c45744cefec91ef7bd19790bc1", "t$fun_9e384e2"]]) {
			HlcOcaml.haxeCodeDigest = Bytes.ofHex(v[0]);
			eq("(ref(C)):void with code MD5 " + v[0].substr(0, 8), funName(refC()), v[1]);
		}
		HlcOcaml.haxeCodeDigest = null;

		// A proto's maps are built once the walk that reached it is done. When that build throws (here
		// pinterfaces compares two interfaces whose maps are the sentinel), the next walk still builds its own.
		var two = proto("Two");
		two.pindexAdds = [];
		two.pfunctionsAdds = [];
		two.pinterfaces = [{t: HObj(proto("I")), index: 0}, {t: HObj(proto("I")), index: 1}];
		var mapsThrew = try {
			HlcOcaml.ttypeValue(HObj(two));
			false;
		} catch (e:Unmodelled) true;
		check("a proto's map build reaches the sentinel", mapsThrew);
		var after = proto("After");
		after.pindexAdds = [];
		after.pfunctionsAdds = [];
		var afterProto = block(block(HlcOcaml.ttypeValue(HObj(after))).fields[0]);
		check("the next walk builds its proto's maps", !afterProto.fields[8].match(OBlock(_ == HlcOcaml.UNMODELLED => true)), Std.string(afterProto.fields[8]));
		// A later walk that reaches the proto whose build threw makes it again rather than finding the
		// half-built one, maps still the sentinel, in the memo: a subclass's walk throws the same way, and once
		// the interfaces no longer compare, the proto comes back with its maps.
		var sub = proto("Sub");
		sub.psuper = two;
		var subThrew = try {
			HlcOcaml.ttypeValue(HObj(sub));
			false;
		} catch (e:Unmodelled) true;
		check("a later walk reaching the proto builds it again", subThrew);
		two.pinterfaces = [{t: HObj(proto("I")), index: 0}];
		var twoProto = block(block(HlcOcaml.ttypeValue(HObj(two))).fields[0]);
		for (i in 8...11)
			check("the proto reached again has map " + i, !twoProto.fields[i].match(OBlock(_ == HlcOcaml.UNMODELLED => true)), Std.string(twoProto.fields[i]));
		HlcOcaml.resetMemo();

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

		namesChecks();

		if (failures > 0) {
			Sys.println("HlcCheck: " + failures + " check(s) failed");
			Sys.exit(1);
		}
		Sys.println("HlcCheck: all checks passed");
	}
}
