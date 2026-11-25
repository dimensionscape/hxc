// The haxe.Serializer corpus (milestone 3b): `gen <file>` serializes every value twice (plain, and
// with useCache + useEnumIndex) into name<TAB>serialized lines and appends the hand-written INPUTS;
// `rt <in> <file>` unserializes each line of <in> and serializes the value again. Both write the
// lines to <file> and print them to stdout through Sorted, which writes the entries of a StringMap or
// ObjectMap with two or more keys in a fixed order: hxcs takes their order from per-process hash
// codes (String.GetHashCode is randomized on .NET Core). Everything else prints as written.
import haxe.Serializer;
import haxe.Unserializer;

enum E {
	A;
	B(i:Int, s:String);
	C(e:E);
	D(?x:Int, f:Float);
}

class Pt {
	public var x:Int;
	public var y:Float;
	public var tag:String;
	public var next:Pt;

	public function new(x:Int, y:Float) {
		this.x = x;
		this.y = y;
	}
}

class Sub extends Pt {
	public var ok:Bool;
	public var n:Null<Int>;
	public var any:Dynamic;
	public static var ignored = 5;

	public function new() {
		super(1, 2);
	}
}

class Holder {
	public var n:Null<Int>;
	public var i:Int;
	public var b:Bool;
	public var f:Float;
	public var s:String;

	public function new() {}
}

class Typed {
	public var a:Array<Int>;
	public var f:Array<Float>;
	public var m:Map<String, Int>;
	public var l:List<String>;
	public var s:Array<String>;

	public function new() {}
}

class Custom {
	public var v:Int = 3;

	public function new() {}

	@:keep public function hxSerialize(s:Serializer) {
		s.serialize(v);
		s.serialize("c");
	}

	@:keep public function hxUnserialize(u:Unserializer) {
		v = u.unserialize();
		u.unserialize();
	}
}

// htmlparser's HtmlNode shape, which the server app uses: the serializer arrives through an anonymous type.
class Structural {
	public var t:String = "t";

	public function new() {}

	@:keep public function hxSerialize(s:{function serialize(d:Dynamic):Void;}) {
		s.serialize(t);
	}

	@:keep public function hxUnserialize(s:{function unserialize():Dynamic;}) {
		t = s.unserialize();
	}
}

class Sorted extends Serializer {
	override public function serialize(v:Dynamic) {
		var c = Type.getClass(v);
		var name = c == null ? "" : Type.getClassName(c);
		if (name == "haxe.ds.StringMap" && count((v : haxe.ds.StringMap<Dynamic>).keys()) > 1) {
			var m:haxe.ds.StringMap<Dynamic> = v;
			buf.add("b");
			for (k in sort([for (k in m.keys()) k]).keys) {
				serializeString(k);
				serialize(m.get(k));
			}
			buf.add("h");
		} else if (name == "haxe.ds.ObjectMap" && count((v : haxe.ds.ObjectMap<Dynamic, Dynamic>).keys()) > 1) {
			var m:haxe.ds.ObjectMap<Dynamic, Dynamic> = v;
			var keys = [for (k in m.keys()) k];
			var r = sort([for (k in keys) Serializer.run(k)]);
			buf.add("M");
			for (i in r.order) {
				serialize(keys[i]);
				serialize(m.get(keys[i]));
			}
			buf.add("h");
		} else
			super.serialize(v);
	}

	static function count(it:Iterator<Dynamic>):Int {
		var n = 0;
		for (_ in it)
			n++;
		return n;
	}

	// Insertion sort, so the corpus needs no closures for it.
	static function sort(a:Array<String>):{keys:Array<String>, order:Array<Int>} {
		var keys = a.copy(), order = [for (i in 0...a.length) i];
		for (i in 1...keys.length) {
			var j = i;
			while (j > 0 && keys[j - 1] > keys[j]) {
				var t = keys[j];
				keys[j] = keys[j - 1];
				keys[j - 1] = t;
				var o = order[j];
				order[j] = order[j - 1];
				order[j - 1] = o;
				j--;
			}
		}
		return {keys: keys, order: order};
	}
}

class P {
	static function values():Array<{name:String, v:Dynamic}> {
		var bytes = haxe.io.Bytes.alloc(10);
		for (i in 0...10)
			bytes.set(i, i * 29);
		var sm1 = new haxe.ds.StringMap<Dynamic>();
		sm1.set("a", 1);
		var sm3 = new haxe.ds.StringMap<Dynamic>();
		sm3.set("a", 1);
		sm3.set("b", "two");
		sm3.set("c", null);
		var im = new haxe.ds.IntMap<Dynamic>();
		im.set(1, "x");
		im.set(7, "y");
		im.set(-3, 2.5);
		im.set(100, null);
		var om1 = new haxe.ds.ObjectMap<Dynamic, Dynamic>();
		om1.set(new Pt(1, 2), 5);
		var om2 = new haxe.ds.ObjectMap<Dynamic, Dynamic>();
		om2.set(new Pt(1, 2), 5);
		om2.set(new Pt(3, 4), "v");
		var l = new List<Dynamic>();
		l.add(1);
		l.add("a");
		l.add(null);
		var p = new Pt(3, 4.5);
		p.tag = "hi there";
		p.next = new Pt(1, 1);
		var sub = new Sub();
		sub.ok = true;
		sub.any = {k: [1]};
		var shared = new Pt(9, 9);
		var ints:Array<Int> = [];
		ints[3] = 1;
		var nints:Array<Null<Int>> = [];
		nints[3] = 1;
		var o2:Dynamic = {};
		Reflect.setField(o2, "a", 1);
		Reflect.setField(o2, "b", "two");
		Reflect.setField(o2, "c", 1.5);
		var base:Array<{name:String, v:Dynamic}> = [
			{name: "int0", v: 0}, {name: "int", v: 123}, {name: "negint", v: -45}, {name: "maxint", v: 2147483647}, {name: "minint", v: -2147483648},
			{name: "float", v: 1.5}, {name: "negfloat", v: -0.5}, {name: "floatwhole", v: 3.0}, {name: "float100", v: 100.0},
			{name: "floatsmall", v: 1e-7}, {name: "float1e-5", v: 1e-5}, {name: "float1e-4", v: 0.0001}, {name: "floatbig", v: 1.0e300},
			{name: "float1e15", v: 1e15}, {name: "float1e16", v: 1e16}, {name: "float1e21", v: 1e21}, {name: "float2^31", v: 2147483648.0},
			{name: "float-2^31-1", v: -2147483649.0}, {name: "float2^32", v: 4294967296.0}, {name: "floatfrac", v: 123456789.125},
			{name: "float01", v: 0.1}, {name: "float0.1+0.2", v: 0.1 + 0.2}, {name: "pi", v: Math.PI}, {name: "denormal", v: 5e-324},
			{name: "maxfloat", v: 1.7976931348623157e308},
			{name: "nan", v: Math.NaN}, {name: "inf", v: Math.POSITIVE_INFINITY}, {name: "ninf", v: Math.NEGATIVE_INFINITY}, {name: "negzero", v: -0.0},
			{name: "null", v: null}, {name: "true", v: true}, {name: "false", v: false},
			{name: "string", v: "hello"}, {name: "emptystr", v: ""}, {name: "ustr", v: "héllo wörld %/&"}, {name: "reserved", v: "a!*'()~-_.+"},
			{name: "astral", v: "\u{1F600}"}, {name: "combining", v: "é"}, {name: "controls", v: "tab\tline\nnul\x00"},
			{name: "longstr", v: StringTools.rpad("", "x", 70000)},
			{name: "date", v: Date.fromTime(86400000.0 * 365)}, {name: "date2", v: new Date(2020, 1, 29, 12, 34, 56)},
			{name: "datefrac", v: Date.fromTime(1583008496789.5)}, {name: "dateneg", v: Date.fromTime(-1.0)},
			{name: "datefallback1", v: Date.fromTime(1604219400000.0)}, {name: "datefallback2", v: Date.fromTime(1604223000000.0)},
			{name: "dategap", v: new Date(2020, 2, 8, 2, 30, 0)},
			{name: "bytes", v: bytes}, {name: "bytes0", v: haxe.io.Bytes.alloc(0)}, {name: "bytes1", v: haxe.io.Bytes.alloc(1)}, {name: "bytes2", v: haxe.io.Bytes.alloc(2)},
			{name: "array", v: [1, 2, null, null, 3, "x"]}, {name: "arrayempty", v: []}, {name: "arrayhole", v: [null, null, null, 1]},
			{name: "arrayfloat", v: [1.0, 2.5]}, {name: "arraybool", v: [true, false]}, {name: "arraystr", v: ["a", null, "b"]},
			{name: "arraynested", v: [[1], [2, [3]]]}, {name: "arrayinthole", v: ints}, {name: "arraynullinthole", v: nints},
			{name: "stringmap1", v: sm1}, {name: "stringmap3", v: sm3}, {name: "intmap", v: im},
			{name: "objectmap1", v: om1}, {name: "objectmap2", v: om2}, {name: "list", v: l},
			{name: "anon", v: {a: 1, b: "two", c: [3]}}, {name: "anonempty", v: {}}, {name: "anonmixed", v: {x: 1.5, y: 2, z: "s", w: null, v: true}},
			{name: "anonset", v: o2}, {name: "anonnested", v: {o: {p: {q: 1}}}},
			{name: "obj", v: p}, {name: "sub", v: sub}, {name: "enumA", v: A}, {name: "enumB", v: B(1, "z")}, {name: "enumC", v: C(C(A))},
			{name: "enumDnull", v: D(null, 2.0)}, {name: "enumD", v: D(4, 2.5)}, {name: "option", v: haxe.ds.Option.Some(1)},
			{name: "class", v: Pt}, {name: "classString", v: String}, {name: "classArray", v: Array}, {name: "enumtype", v: E},
			{name: "custom", v: new Custom()}, {name: "structural", v: new Structural()},
			{name: "function", v: P.main},
			{name: "shared", v: [shared, shared, {s: shared}]},
			{name: "strshared", v: ["aa", "aa", "bb", "aa"]},
		];
		#if corpus_typed
		// Plan 3c: maps and lists whose type parameters are not Dynamic, and generic classes by name.
		var tsm = new Map<String, Int>();
		tsm.set("a", 1);
		tsm.set("b", 2);
		var tim = new Map<Int, String>();
		tim.set(1, "x");
		tim.set(7, "y");
		var tom = new haxe.ds.ObjectMap<Dynamic, Int>();
		tom.set(new Pt(1, 2), 5);
		var tl = new List<Int>();
		tl.add(1);
		tl.add(2);
		var em = new haxe.ds.EnumValueMap<E, Int>();
		em.set(A, 1);
		em.set(B(1, "q"), 2);
		var th = new Typed();
		th.a = [1, 2];
		th.f = [1.0, 2.5];
		th.m = ["k" => 1];
		th.l = new List();
		th.l.add("s");
		base = base.concat([
			{name: "tstringmap", v: tsm}, {name: "tintmap", v: tim}, {name: "tobjectmap", v: tom}, {name: "tlist", v: tl},
			{name: "enumvaluemap", v: em}, {name: "typed", v: th}, {name: "classStringMap", v: haxe.ds.StringMap},
		]);
		#end
		return base;
	}

	// Lines no Serializer writes, read in both directions.
	static var INPUTS = [
		["in.plus", "y1:+"], ["in.jsreserved", "y5:a!'()"], ["in.badescape", "y3:%ZZ"], ["in.lowerhex", "y6:%c3%a9"],
		["in.floatexp", "d1e-7"], ["in.floatexpplus", "d1.5e+300"], ["in.negzero", "d-0"], ["in.floatint", "d3"], ["in.dotfloat", "d.5"],
		["in.bigint", "i2147483648"], ["in.datestr", "v2020-02-29 12:34:56"], ["in.datefrac", "v1583008496789.5"],
		["in.ref", "aoy1:ai1gr1h"], ["in.enumidx", "jy1:E:1:2i1y1:z"], ["in.enumbadidx", "jy1:E:9:0"], ["in.enumbadname", "wy1:Ey1:Q:0"],
		["in.noclass", "cy3:Foog"], ["in.noenum", "wy3:Fooy1:A:0"], ["in.badchar", "Q"], ["in.removedfield", "cy2:Pty4:goneng"],
		["in.nullint3.5", "cy6:Holdery1:nd3.5g"], ["in.intfromstr", "cy6:Holdery1:iy1:5g"], ["in.intfromfloat", "cy6:Holdery1:id2.7g"],
		["in.boolfromint", "cy6:Holdery1:bi1g"], ["in.floatfromint", "cy6:Holdery1:fi2g"], ["in.strfromint", "cy6:Holdery1:si2g"],
		["in.trailing", "i1i2"], ["in.exception", "xy3:err"], ["in.listnull", "lnnh"], ["in.anonintkey", "oi1i2g"],
		["in.enumtypeB", "By1:E"], ["in.classint", "Ay3:Int"], ["in.stringmapdup", "by1:ai1y1:ai2h"], ["in.objectmapint", "Mi1i2h"],
		["in.u0", "au0h"], ["in.bytesodd", "s5:AAAAA"],
		#if corpus_typed
		["in.classstringmap", "cy17:haxe.ds.StringMapg"], ["in.classstringmapA", "Ay17:haxe.ds.StringMap"],
		["in.tarrayint", "cy5:Typedy1:aai1d1.5nhg"], ["in.tarrayfloat", "cy5:Typedy1:fai1d1.5nhg"], ["in.tarraystr", "cy5:Typedy1:say1:ai1nhg"],
		["in.tmap", "cy5:Typedy1:mby1:ad1.5hg"], ["in.tlist", "cy5:Typedy1:lli1hg"],
		#end
	];

	static function serialize(name:String, v:Dynamic, sorted:Bool):String {
		var s = sorted ? new Sorted() : new Serializer();
		if (name.indexOf("+cache+idx") >= 0) {
			s.useCache = true;
			s.useEnumIndex = true;
		}
		s.serialize(v);
		return s.toString();
	}

	static function error(ex:Dynamic):String {
		var s = if (Std.isOfType(ex, cs.system.Exception)) {
			var ce:cs.system.Exception = ex;
			Type.getClassName(Type.getClass(ex)) + ": " + ce.Message;
		} else Std.string(ex);
		return "EXC " + StringTools.replace(StringTools.replace(s, "\r", ""), "\n", "\\n");
	}

	static var raw = new StringBuf();
	static var shown = new StringBuf();

	static function add(name:String, v:Dynamic) {
		raw.add(name + "	" + (try serialize(name, v, false) catch (ex:Dynamic) error(ex)) + "
");
		shown.add(name + "	" + (try serialize(name, v, true) catch (ex:Dynamic) error(ex)) + "
");
	}

	static function main() {
		var args = Sys.args();
		if (args[0] == "gen") {
			for (e in values()) {
				add(e.name, e.v);
				add(e.name + "+cache+idx", e.v);
			}
			for (i in INPUTS) {
				raw.add(i[0] + "\t" + i[1] + "\n");
				shown.add(i[0] + "\t" + i[1] + "\n");
			}
			cs.system.io.File.WriteAllText(args[1], raw.toString());
		} else if (args[0] == "rt") {
			for (line in cs.system.io.File.ReadAllText(args[1]).split("\n")) {
				if (line == "")
					continue;
				var i = line.indexOf("\t");
				var name = line.substr(0, i), ser = line.substr(i + 1);
				if (StringTools.startsWith(ser, "EXC ")) {
					raw.add(line + "\n");
					shown.add(line + "\n");
					continue;
				}
				try {
					add(name, new Unserializer(ser).unserialize());
				} catch (ex:Dynamic) {
					raw.add(name + "\t" + error(ex) + "\n");
					shown.add(name + "\t" + error(ex) + "\n");
				}
			}
			cs.system.io.File.WriteAllText(args[2], raw.toString());
		}
		Sys.print(shown.toString());
	}
}
