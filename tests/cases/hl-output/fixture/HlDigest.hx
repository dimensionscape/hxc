import haxe.macro.Context;

class HlDigest {
	// Prints "== <path> <length> <md5>" once the .hl is written: the length and MD5 of its bytes with the
	// case directory replaced by $CASE and each class path under a std/ directory by $STD (in / and \ forms),
	// as the paths in the debug info would otherwise differ from machine to machine. Only hashed, never written.
	public static function after(path:String):Void {
		Context.onAfterGenerate(function() {
			var bytes = sys.io.File.getBytes(path);
			var cwd = Sys.getCwd();
			var roots = [[cwd, "$CASE"]];
			for (cp in Context.getClassPath()) {
				var c = StringTools.replace(cp, "\\", "/");
				if (StringTools.endsWith(c, "std/")) roots.push([cp, "$STD"]);
			}
			// Longest first, so that a root inside another is not hidden by it.
			var all:Array<Array<String>> = [];
			for (r in roots) {
				var d = r[0];
				while (d.length > 0 && (StringTools.endsWith(d, "/") || StringTools.endsWith(d, "\\"))) d = d.substr(0, d.length - 1);
				if (d.length == 0) continue;
				var f = StringTools.replace(d, "\\", "/");
				all.push([f, r[1]]);
				var b = StringTools.replace(d, "/", "\\");
				if (b != f) all.push([b, r[1]]);
			}
			all.sort((a, b) -> b[0].length - a[0].length);
			var out = bytes;
			for (r in all) out = replaceBytes(out, haxe.io.Bytes.ofString(r[0]), haxe.io.Bytes.ofString(r[1]));
			Sys.println("== " + path + " " + out.length + " " + haxe.crypto.Md5.make(out).toHex());
		});
	}

	static function replaceBytes(s:haxe.io.Bytes, from:haxe.io.Bytes, to:haxe.io.Bytes):haxe.io.Bytes {
		var buf = new haxe.io.BytesBuffer();
		var i = 0, n = s.length, m = from.length;
		while (i < n) {
			var hit = i + m <= n;
			if (hit) {
				for (k in 0...m) if (s.get(i + k) != from.get(k)) { hit = false; break; }
			}
			if (hit) { buf.add(to); i += m; } else { buf.addByte(s.get(i)); i++; }
		}
		return buf.getBytes();
	}
}
