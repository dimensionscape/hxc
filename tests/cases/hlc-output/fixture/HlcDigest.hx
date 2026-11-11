import haxe.macro.Context;

class HlcDigest {
	// Prints "== <relative path> <length> <md5>" for each file under dir (the HL/C output directory), in
	// sorted relative-path order, once the generator has written them. The length and MD5 are those of the
	// file's text with the case directory replaced by $CASE and the std root by $STD, in the spellings
	// HlDigest uses: the case directory in the native spelling (\ on Windows), the std root as HAXE_STD_PATH
	// (or the class path entry ending in hl/_std, less that) gives it and in the native spelling. The result
	// is only hashed, never written.
	public static function after(dir:String):Void {
		Context.onAfterGenerate(function() {
			var subs = substitutions();
			var files:Array<String> = [];
			walk(dir, "", files);
			files.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
			for (f in files) {
				var text = sub(sys.io.File.getContent(dir + "/" + f), subs);
				var bytes = haxe.io.Bytes.ofString(text);
				Sys.println("== " + f + " " + bytes.length + " " + haxe.crypto.Md5.make(bytes).toHex());
			}
		});
	}

	static function walk(root:String, rel:String, out:Array<String>):Void {
		var path = rel == "" ? root : root + "/" + rel;
		for (e in sys.FileSystem.readDirectory(path)) {
			var r = rel == "" ? e : rel + "/" + e;
			if (sys.FileSystem.isDirectory(root + "/" + r)) walk(root, r, out);
			else out.push(r);
		}
	}

	static function trimEnd(d:String):String {
		while (d.length > 0 && (StringTools.endsWith(d, "/") || StringTools.endsWith(d, "\\"))) d = d.substr(0, d.length - 1);
		return d;
	}

	static function native(d:String):String {
		return Sys.systemName() == "Windows" ? StringTools.replace(d, "/", "\\") : d;
	}

	// [from, to] pairs, longest first.
	static function substitutions():Array<Array<String>> {
		var std = Sys.getEnv("HAXE_STD_PATH");
		if (std == null || std == "") {
			std = "";
			for (cp in Context.getClassPath()) {
				var c = trimEnd(cp);
				var f = StringTools.replace(c, "\\", "/");
				if (StringTools.endsWith(f, "/hl/_std")) std = c.substr(0, c.length - "/hl/_std".length);
			}
		}
		std = trimEnd(std);
		var cwd = native(trimEnd(Sys.getCwd()));
		var all:Array<Array<String>> = [];
		for (p in [[cwd, "$CASE"], [std, "$STD"], [native(std), "$STD"]]) {
			if (p[0].length == 0) continue;
			var dup = false;
			for (x in all) if (x[0] == p[0]) dup = true;
			if (!dup) all.push(p);
		}
		all.sort((a, b) -> b[0].length - a[0].length);
		return all;
	}

	static function sub(s:String, subs:Array<Array<String>>):String {
		for (r in subs) s = StringTools.replace(s, r[0], r[1]);
		return s;
	}
}
