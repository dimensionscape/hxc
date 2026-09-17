package hxc.compiler;

// Collect from the server context's cached parsed files. An uninitialized context first explores
// its class paths; one-shot runs retain no files.

import hxc.context.Context;
import hxc.ast.Ast;

typedef ScannedFile = {
	key:String,
	file:String,
	pack:Array<String>,
	moduleName:String,
	decls:Array<TypeDecl>
};

class ToplevelScan {
	public static var exclude:Array<String> = [];

	public static function excluded(pack:Array<String>, moduleName:String):Bool {
		var dotPath = pack.length == 0 ? moduleName : pack.join(".") + "." + moduleName;
		for (e in exclude) if (StringTools.startsWith(dotPath, e + ".")) return true;
		return false;
	}
	public static function uninitialize(sign:String):Void
		hxc.context.DisplayJson.cache.getContext(sign).initialized = false;

	public static function get(ctx:Context):Array<ScannedFile> {
		// Only the server parse hook populates the files collected here.
		if (!hxc.context.ServerCache.cacheMode) return [];
		var sign = ctx.defines.getSignature();
		var cc = hxc.context.DisplayJson.cache.getContext(sign);
		if (!cc.initialized) {
			cc.initialized = true;
			explore(ctx);
		}
		consumeRemovedFiles(ctx, sign);
		var out:Array<ScannedFile> = [];
		for (key in cc.fileSeq) {
			var f = cc.files.get(key);
			if (f == null || f.decls == null) continue;
			// Cache the module name used by server/files.
			if (f.moduleName == null) f.moduleName = moduleNameOfFile(f.path);
			out.push({key: key, file: f.path, pack: f.pack, moduleName: f.moduleName, decls: f.decls});
		}
		return out;
	}

	// Visit files in the context's hash-bucket order across all server requests.
	public static function foldOrder(ctx:Context):Array<String> {
		if (!hxc.context.ServerCache.cacheMode) return [];
		return hxc.context.DisplayJson.cache.getContext(ctx.defines.getSignature()).fileOrder.visitOrder();
	}

	static function moduleNameOfFile(file:String):String {
		var base = StringTools.replace(file, "\\", "/").split("/").pop();
		var parts = base.split(".");
		return switch (parts.length) {
			case 1: parts[0];
			case 2: parts[0];
			case _: parts.slice(0, parts.length - 2).join(".");
		};
	}

	// Reparse removed files unless the context holds them again, then clear each removal entry.
	static function consumeRemovedFiles(ctx:Context, sign:String):Void {
		var cc = hxc.context.DisplayJson.cache.getContext(sign);
		var keys = [for (k in cc.removedFiles.keys()) k];
		if (keys.length == 0) return;
		for (k in keys) {
			var path = cc.removedFiles.get(k);
			cc.removedFiles.remove(k);
			if (path == null || cc.files.exists(k)) continue;
			if (!StringTools.endsWith(path, ".hx")) continue;
			try {
				var src = sys.io.File.getContent(path);
				var pkg:Package = hxc.parser.Parser.parseModuleString(src, path, ctx.defines);
				// The server parse hook recaches files for later invalidation; display files remain excluded.
				hxc.context.ServerCache.cacheParsedFile(ctx, path, pkg.pack, pkg.decls);
			} catch (_:Dynamic) {}
		}
	}

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

	// Explore each unique directory once and cache parsed module files. Exclude the display file and
	// discard package-directory mismatches.
	public static function explore(ctx:Context):Void {
		var checked = new haxe.ds.StringMap<Bool>();
		for (cp in ctx.classPath) {
			if (cp == "") continue;
			exploreDir(ctx, StringTools.endsWith(cp, "/") || StringTools.endsWith(cp, "\\") ? cp : cp + "/", [], checked);
		}
	}

	static function exploreDir(ctx:Context, dir:String, pack:Array<String>, checked:haxe.ds.StringMap<Bool>):Void {
		var unique = hxc.core.PathKey.key(dir);
		var dotPath = pack.join(".");
		if (exclude.indexOf(dotPath) >= 0 || checked.exists(unique)) return;
		checked.set(unique, true);
		var entries = try sys.FileSystem.readDirectory(dir) catch (_:Dynamic) return;
		// Match NTFS's case-insensitive directory ordering because cache insertion affects completion
		// order.
		entries.sort(function(a, b) {
			var al = a.toLowerCase(), bl = b.toLowerCase();
			return al < bl ? -1 : al > bl ? 1 : (a < b ? -1 : a > b ? 1 : 0);
		});
		var displayFile = hxc.parser.Parser.displayFile;
		var displayKey = displayFile == null ? null : hxc.core.PathKey.key(displayFile);
		var cc = hxc.context.DisplayJson.cache.getContext(ctx.defines.getSignature());
		for (file in entries) {
			if (file == "." || file == "..") continue;
			var full = dir + file;
			var isDir = try sys.FileSystem.isDirectory(full) catch (_:Dynamic) false;
			var c0 = file.charCodeAt(0);
			if (isDir && c0 >= "a".code && c0 <= "z".code) {
				// A directory with a package rule (another platform's tree, sys on a non-sys target)
				if (forbiddenPacks(ctx).exists(file)) continue;
				exploreDir(ctx, full + "/", pack.concat([file]), checked);
			} else if (file.length > 3 && StringTools.endsWith(file, ".hx")) {
				var name = file.substr(0, file.length - 3);
				// The suffix slice includes its leading dot, so it never matches the platform name; dotted
				// module files are skipped.
				if (name.indexOf(".") >= 0) continue;
				if (displayKey != null && hxc.core.PathKey.key(full) == displayKey) continue;
				if (exclude.indexOf(dotPath == "" ? name : dotPath + "." + name) >= 0) continue;
				try {
					var r = hxc.context.ModuleLoader.parseForExploration(ctx, {pack: pack, name: name});
					if (r != null && r.pack.join(".") != pack.join(".")) cc.removeFileForReal(r.file.toLowerCase());
				} catch (_:Dynamic) {}
			}
		}
	}
}
