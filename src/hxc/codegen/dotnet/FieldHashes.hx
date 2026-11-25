package hxc.codegen.dotnet;

import haxe.io.Bytes;

// gencs's compile-time field hashes, which the generated `__hx_*` switches and the runtime calls take,
// and the names they were taken of, which haxe.lang.FieldLookup's table starts with.
class FieldHashes {
	// The names hashed since the generation started, by hash; a later name with the same hash replaces
	// the earlier one, as gencs's table keeps one name per hash.
	static var names = new Map<Int, String>();

	// gencommon's hash over the name's UTF-8 bytes, `h * 223 + byte`, kept as 31 bits, then
	// reflectionCFs' mapping of a negative 31-bit value, which together keep the low 31 bits. The
	// runtime's FieldLookup.doHash works on UTF-16 code units, so the two differ for a non-ASCII name,
	// as they do in hxcs.
	public static function hash(name:String):Int {
		var bytes = Bytes.ofString(name, UTF8);
		var h = 0;
		for (i in 0...bytes.length) h = (h * 223 + bytes.get(i)) & 0x7FFFFFFF;
		return h;
	}

	// The hash of `name`, recorded for FieldLookup's table.
	public static function use(name:String):Int {
		var h = hash(name);
		names.set(h, name);
		return h;
	}

	// The names each class's code has hashed, by class and hash, as reflectionCFs' hash_field keeps
	// them per generated class.
	static var claimed = new Map<String, Map<Int, String>>();

	// Records that the code of the class `owner` hashes `name` to `h`; returns the other name that
	// class already hashed to `h`, which gencs refuses as "Field conflict between <name> and <other>",
	// or null.
	public static function claim(owner:String, h:Int, name:String):Null<String> {
		var m = claimed.get(owner);
		if (m == null) claimed.set(owner, m = new Map());
		var other = m.get(h);
		if (other == null) {
			m.set(h, name);
			return null;
		}
		return other == name ? null : other;
	}

	public static function reset():Void {
		names = new Map();
		claimed = new Map();
	}

	// The recorded hashes in ascending order with their names, as FieldLookup searches them.
	public static function table():Array<{id:Int, name:String}> {
		var r = [for (h => n in names) {id: h, name: n}];
		r.sort((a, b) -> a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
		return r;
	}
}
