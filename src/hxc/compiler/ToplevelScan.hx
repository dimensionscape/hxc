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
	// Scan once per server context rather than once per process.
	static var scanned:haxe.ds.StringMap<Array<ScannedFile>> = new haxe.ds.StringMap();

	public static function reset():Void scanned = new haxe.ds.StringMap();

	// Discard this signature's exploration so the next collection rescans class paths.
	public static function uninitialize(sign:String):Void scanned.remove(sign);

	public static function get(ctx:Context):Array<ScannedFile> {
		var sign = ctx.defines.getSignature();
		var out = scanned.get(sign);
		if (out == null) {
			out = [];
			// The first class path wins for each module path.
			var seen = new haxe.ds.StringMap<Bool>();
			for (cp in ctx.classPath) {
				if (cp == "") continue;
				walk(ctx, cp, [], out, seen);
			}
			scanned.set(sign, out);
		}
		consumeRemovedFiles(ctx, sign, out);
		return out;
	}

	// Reparse removed files unless the context holds them again, then clear each removal entry.
	static function consumeRemovedFiles(ctx:Context, sign:String, out:Array<ScannedFile>):Void {
		var cc = hxc.context.DisplayJson.cache.getContext(sign);
		var keys = [for (k in cc.removedFiles.keys()) k];
		if (keys.length == 0) return;
		for (k in keys) {
			var path = cc.removedFiles.get(k);
			cc.removedFiles.remove(k);
			if (path == null || cc.files.exists(k)) continue;
			var moduleName = path.split("/").pop().split("\\").pop();
			if (!StringTools.endsWith(moduleName, ".hx")) continue;
			moduleName = moduleName.substr(0, moduleName.length - 3);
			var idx = -1;
			for (i in 0...out.length) if (norm(out[i].file) == norm(path)) { idx = i; break; }
			try {
				var src = sys.io.File.getContent(path);
				var pkg:Package = hxc.parser.Parser.parseModuleString(src, path, ctx.defines);
				var sf:ScannedFile = {file: path, pack: pkg.pack, moduleName: moduleName, decls: pkg.decls};
				if (idx >= 0) out[idx] = sf else out.push(sf);
				// Parsing caches the file again, allowing later invalidation to schedule another parse.
				cc.files.set(k, {
					path: path,
					time: hxc.core.FileTime.fileTime(path),
					pack: pkg.pack,
					moduleName: moduleName
				});
			} catch (_:Dynamic) {
				if (idx >= 0) out.splice(idx, 1);
			}
		}
	}

	static function norm(f:String):String return StringTools.replace(f, "\\", "/").toLowerCase();

	// Cache package rules per platform because one server serves multiple targets. Forbid other target
	// packages and sys on non-sys targets.
	static var forbidden:haxe.ds.StringMap<haxe.ds.StringMap<Bool>> = new haxe.ds.StringMap();

	static function forbiddenPacks(ctx:Context):haxe.ds.StringMap<Bool> {
		var cur = hxc.core.Globals.platformName(ctx.platform);
		var key = cur + (ctx.defines.rawDefined("sys") ? "|sys" : "");
		var hit = forbidden.get(key);
		if (hit != null) return hit;
		var m = new haxe.ds.StringMap<Bool>();
		for (p in ["js", "lua", "neko", "flash", "php", "cpp", "cs", "java", "python", "hl", "eval", "jvm"])
			if (p != cur) m.set(p, true);
		if (!ctx.defines.rawDefined("sys")) m.set("sys", true);
		forbidden.set(key, m);
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
				// Accept Name.platform.hx only when its suffix matches the current target.
				var dot = moduleName.lastIndexOf(".");
				if (dot >= 0) {
					var platformStr = ctx.isMacro || ctx.defines.rawDefined("macro")
						? "macro" : hxc.core.Globals.platformName(ctx.platform);
					if (moduleName.substr(dot + 1) != platformStr) continue;
					moduleName = moduleName.substr(0, dot);
				}
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
