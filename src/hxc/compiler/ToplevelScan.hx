package hxc.compiler;

// Explore class paths once per server context and collect visible parsed declarations without
// typing them.

import hxc.context.Context;
import hxc.ast.Ast;

typedef ScannedFile = {
	file:String,
	pack:Array<String>,
	moduleName:String,
	decls:Array<TypeDecl>
};

class ToplevelScan {
	// One process-wide scan supplies all requests.
	static var scanned:Null<Array<ScannedFile>> = null;

	public static function reset():Void scanned = null;

	public static function get(ctx:Context):Array<ScannedFile> {
		if (scanned != null) return scanned;
		var out:Array<ScannedFile> = [];
		// The first class path wins for each module path.
		var seen = new haxe.ds.StringMap<Bool>();
		for (cp in ctx.classPath) {
			if (cp == "") continue;
			walk(ctx, cp, [], out, seen);
		}
		scanned = out;
		return out;
	}

	// Skip packages belonging to other targets, including jvm, and skip sys on non-sys targets.
	static var forbidden:Null<haxe.ds.StringMap<Bool>> = null;

	static function forbiddenPacks(ctx:Context):haxe.ds.StringMap<Bool> {
		if (forbidden != null) return forbidden;
		var cur = hxc.core.Globals.platformName(ctx.platform);
		var m = new haxe.ds.StringMap<Bool>();
		for (p in ["js", "lua", "neko", "flash", "php", "cpp", "cs", "java", "python", "hl", "eval", "jvm"])
			if (p != cur) m.set(p, true);
		if (!ctx.defines.rawDefined("sys")) m.set("sys", true);
		forbidden = m;
		return m;
	}

	static function walk(ctx:Context, dir:String, pack:Array<String>, out:Array<ScannedFile>, seen:haxe.ds.StringMap<Bool>):Void {
		var entries = try sys.FileSystem.readDirectory(dir) catch (_:Dynamic) return;
		entries.sort(function(a, b) {
			var al = a.toLowerCase(), bl = b.toLowerCase();
			return al < bl ? -1 : al > bl ? 1 : (a < b ? -1 : a > b ? 1 : 0);
		});
		for (name in entries) {
			if (name.length == 0 || name.charCodeAt(0) == ".".code) continue;
			var full = (StringTools.endsWith(dir, "/") || StringTools.endsWith(dir, "\\") ? dir : dir + "/") + name;
			if (try sys.FileSystem.isDirectory(full) catch (_:Dynamic) false) {
				var c0 = name.charCodeAt(0);
				if (c0 >= "a".code && c0 <= "z".code && !forbiddenPacks(ctx).exists(name))
					walk(ctx, full, pack.concat([name]), out, seen);
			} else if (StringTools.endsWith(name, ".hx")) {
				var moduleName = name.substr(0, name.length - 3);
				var c0 = moduleName.charCodeAt(0);
				if (!((c0 >= "A".code && c0 <= "Z".code))) continue;
				var key = pack.join(".") + "." + moduleName;
				if (seen.exists(key)) continue;
				seen.set(key, true);
				try {
					var src = sys.io.File.getContent(full);
					var pkg:Package = hxc.parser.Parser.parseModuleString(src, full, ctx.defines);
					out.push({file: full, pack: pkg.pack, moduleName: moduleName, decls: pkg.decls});
				} catch (_:Dynamic) {}
			}
		}
	}
}
