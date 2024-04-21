package hxia;

// Reads and writes the hxia manifest: the small deterministic record carried inside a
// script artifact (a RESOURCES sidecar) that declares the profile, the capability atoms
// the script requests, the format/ABI versions, and an optional SDK surface hash.
//
// Pure Haxe (no sys): every host, on every target, reads this. The format is a fixed
// key=value line order so write -> read -> write is byte-identical, which the sign/hash
// layer depends on: the manifest is inside the signed payload.
class ManifestIo {
	// Fixed field order; `sdkSurfaceHash` is emitted only when present. `requires` is
	// comma-joined (atoms contain no commas) and always emitted, empty as `requires=`.
	public static function serialize(m:Manifest):String {
		var sb = new StringBuf();
		sb.add("formatVersion=" + m.formatVersion + "\n");
		sb.add("profile=" + m.profile + "\n");
		sb.add("requires=" + m.requires.join(",") + "\n");
		sb.add("abiLevel=" + m.abiLevel + "\n");
		if (m.sdkSurfaceHash != null)
			sb.add("sdkSurfaceHash=" + m.sdkSurfaceHash + "\n");
		return sb.toString();
	}

	public static function parse(s:String):Manifest {
		var m:Manifest = {profile: "", requires: [], formatVersion: 0, abiLevel: 0};
		for (line in s.split("\n")) {
			if (line == "")
				continue;
			var eq = line.indexOf("=");
			if (eq < 0)
				throw new ManifestError("malformed manifest line: " + line);
			var key = line.substr(0, eq);
			var val = line.substr(eq + 1);
			switch (key) {
				case "formatVersion": m.formatVersion = intOf(val, key);
				case "profile": m.profile = val;
				case "requires": m.requires = val == "" ? [] : val.split(",");
				case "abiLevel": m.abiLevel = intOf(val, key);
				case "sdkSurfaceHash": m.sdkSurfaceHash = val;
				case _: throw new ManifestError("unknown manifest key: " + key);
			}
		}
		return m;
	}

	static function intOf(val:String, key:String):Int {
		var n = Std.parseInt(val);
		if (n == null)
			throw new ManifestError("non-integer " + key + ": " + val);
		return n;
	}
}

class ManifestError extends haxe.Exception {
	public function new(message:String) super(message);
}
