package hxc.context;

import hxc.core.Globals;
import hxc.core.Globals.Platform;

class Setup {
	public static function getStdClassPaths():Array<String> {
		var env = Sys.getEnv("HAXE_STD_PATH");
		if (env != null) {
			var r = [""];
			for (p in splitDriveAware(env)) r.push(addTrailingSlash(p));
			return r;
		}
		var base = getRealPath(executablePath());
		if (Sys.systemName() != "Windows") {
			var prefix = haxe.io.Path.directory(base);
			var lib = prefix + "/lib";
			var share = prefix + "/share";
			return ["", addTrailingSlash(lib + "/haxe/std"), addTrailingSlash(lib + "/haxe/extraLibs"),
				addTrailingSlash(share + "/haxe/std"), addTrailingSlash(share + "/haxe/extraLibs"),
				addTrailingSlash(base + "/std"), addTrailingSlash(base + "/extraLibs")];
		}
		return ["", addTrailingSlash(base + "/std"), addTrailingSlash(base + "/extraLibs")];
	}

	// Loop: rejoin a leading single drive letter split off by ';' / ':'
	static function splitDriveAware(p:String):Array<String> {
		var parts = ~/[;:]/g.split(p);
		var out = [];
		var i = 0;
		while (i < parts.length) {
			var d = parts[i];
			if (i + 1 < parts.length && d.length == 1 && isAlpha(d.charCodeAt(0))) {
				out.push(d + ":" + parts[i + 1]);
				i += 2;
			} else {
				out.push(d);
				i += 1;
			}
		}
		return out;
	}

	static inline function isAlpha(c:Int):Bool {
		return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code);
	}

	public static function addTrailingSlash(p:String):String {
		if (p == "") return p;
		var last = p.charCodeAt(p.length - 1);
		return (last == "/".code || last == "\\".code) ? p : p + "/";
	}

	static function executablePath():String {
		return try Sys.programPath() catch (_:Dynamic) "./";
	}

	static function getRealPath(p:String):String {
		return try sys.FileSystem.fullPath(p) catch (_:Dynamic) p;
	}

	public static function setupCommonContext(ctx:Context):Void {
		var d = ctx.defines;
		d.rawDefineValue("haxe_ver", haxeVer());
		d.rawDefine("haxe3");
		d.rawDefine("haxe4");
		d.rawDefineValue("haxe", Globals.sVersion);
		d.rawDefine("true");
		d.rawDefineValue("dce", "std");
		ctx.classPath = getStdClassPaths();
		ctx.stdPath = [for (p in ctx.classPath) if (endsWithStd(p)) p];
	}

	static inline function endsWithStd(p:String):Bool {
		return StringTools.endsWith(p, "std/") || StringTools.endsWith(p, "std\\");
	}

	static function haxeVer():String {
		return Globals.versionMajor + "." + StringTools.lpad(Std.string(Globals.version % 1000), "0", 3);
	}

	public static function initPlatform(ctx:Context, pf:Platform):Void {
		ctx.platform = pf;
		ctx.platformConfig = PlatformConfig.get(pf);
		var cfg = ctx.platformConfig;
		var name = Globals.platformName(pf);
		if (cfg.isStatic) ctx.defines.rawDefine("target.static");
		if (cfg.sys) { ctx.defines.rawDefine("target.sys"); ctx.defines.rawDefine("sys"); }
		if (pf == Eval || pf == Cpp) ctx.defines.rawDefine("target.threaded");
		if (cfg.usesUtf16) ctx.defines.rawDefine("target.utf16");
		if (cfg.supportsUnicode) ctx.defines.rawDefine("target.unicode");
		ctx.defines.rawDefineValue("target.name", name);
		ctx.defines.rawDefine(name);
	}

	// Prepend the per-target `<std>/<dir>/_std/` overlay before the
	// base std, keeping any non-std (user) class paths in front.
	public static function addStd(ctx:Context, dir:String):Void {
		var std = ctx.stdPath;
		var nonStd = [for (s in ctx.classPath) if (std.indexOf(s) < 0) s];
		var overlay = [for (p in std) p + dir + "/_std/"];
		ctx.classPath = nonStd.concat(overlay).concat(std);
	}
}
