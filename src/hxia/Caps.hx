package hxia;

// Runtime side of the capability vocabulary. hxia.macro.Atoms derives the same names at macro time
// from the same enum (FsRead -> "fs.read", NetClient -> "net.client", Proc -> "proc", SysInfo ->
// "sys.info"); this is that mapping for values that exist at runtime. A manifest requests UNSCOPED
// atoms (what the compile-time mask emits); the scope carried by a granted Capability narrows it at
// call time, it does not change what is requested.
class Caps {
	public static function atomOf(c:Capability):String
		return atomOfCtor(Type.enumConstructor(c));

	// FsRead -> ["Fs","Read"] -> "fs.read"
	public static function atomOfCtor(ctor:String):String {
		var words = [];
		var cur = new StringBuf();
		for (i in 0...ctor.length) {
			var ch = ctor.charAt(i);
			if (i > 0 && ch >= "A" && ch <= "Z") {
				words.push(cur.toString());
				cur = new StringBuf();
			}
			cur.add(ch);
		}
		words.push(cur.toString());
		return [for (w in words) w.toLowerCase()].join(".");
	}

	public static function all():Array<String>
		return [for (n in Type.getEnumConstructs(Capability)) atomOfCtor(n)];

	// The requested atoms a grant set does not cover. Proc is unscoped authority that
	// subsumes the scoped fs/net atoms (Capability's own note: it nullifies their scopes),
	// so granting it covers them.
	public static function missing(requires:Array<String>, granted:Array<Capability>):Array<String> {
		var have = [for (g in granted) atomOf(g)];
		var proc = have.indexOf("proc") >= 0;
		var out = [];
		for (r in requires) {
			if (have.indexOf(r) >= 0)
				continue;
			if (proc && (StringTools.startsWith(r, "fs.") || StringTools.startsWith(r, "net.")))
				continue;
			out.push(r);
		}
		return out;
	}
}
