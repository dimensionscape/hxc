package hxia.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Type;

using StringTools;

// The capability-atom vocabulary, derived at macro time from the hxia.Capability enum so there is
// one source of atom names. A constructor name maps to its atom by splitting at uppercase
// boundaries and lowercasing: FsRead -> "fs.read", NetClient -> "net.client", Proc -> "proc",
// SysInfo -> "sys.info".
class Atoms {
	static var cache:Null<Array<String>> = null;

	public static function all():Array<String> {
		if (cache != null)
			return cache;
		var out = [];
		switch (Context.getType("hxia.Capability")) {
			case TEnum(_.get() => e, _):
				for (name in e.names)
					out.push(atomOf(name));
			case _:
				Context.error("hxia.Capability is not an enum", Context.currentPos());
		}
		cache = out;
		return out;
	}

	public static function isKnown(atom:String):Bool
		return all().indexOf(atom) >= 0;

	// FsRead -> ["Fs","Read"] -> "fs.read"
	static function atomOf(ctor:String):String {
		var words = [];
		var cur = new StringBuf();
		for (i in 0...ctor.length) {
			var c = ctor.charAt(i);
			if (i > 0 && c >= "A" && c <= "Z") {
				words.push(cur.toString());
				cur = new StringBuf();
			}
			cur.add(c);
		}
		words.push(cur.toString());
		return [for (w in words) w.toLowerCase()].join(".");
	}
}
#end
