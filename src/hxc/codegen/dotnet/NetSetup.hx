package hxc.codegen.dotnet;

import sys.FileSystem;
import hxc.context.Context;
import hxc.context.ModuleLoader;

class NetSetup {
	// Defines the .NET version and target, then locates the std directories that match them and
	// collects their DLLs into ctx.netStdFiles.
	public static function beforeGenerate(ctx:Context):Void {
		var defines = ctx.defines;
		var netcoreVer:Null<String> = defines.rawDefined("netcore_ver") ? defines.rawDefinedValue("netcore_ver") : null;

		var netVer:Int;
		if (defines.rawDefined("net_ver")) {
			var s = defines.rawDefinedValue("net_ver");
			var v = parseInt(s);
			if (v == null) throw "Invalid value for -D net-ver. Expected format: xx (e.g. 20, 35, 40, 45, 50)";
			netVer = v;
		} else if (netcoreVer != null) {
			// 4.7 was released around .NET core 2.1
			defines.rawDefineValue("net_ver", "47");
			netVer = 47;
		} else {
			defines.rawDefineValue("net_ver", "20");
			netVer = 20;
		}
		if (netVer < 20)
			throw ".NET version is defined to target .NET " + netVer
				+ ", but the compiler can only output code to versions equal or superior to .NET 2.0 (defined as 20)";
		for (v in [20, 21, 30, 35, 40, 45, 50]) {
			if (v > netVer) break;
			defines.rawDefine("NET_" + v);
		}

		var netTarget = defines.rawDefined("net_target") ? defines.rawDefinedValue("net_target").toLowerCase() : "net";
		defines.rawDefineValue("net_target", netTarget);
		defines.rawDefine(netTarget);

		// every std directory holding the digraph NET_TARGET-NET_VER
		var digraph = if (netTarget == "netcore") {
			if (netcoreVer == null) throw ".NET target is defined as netcore but -D netcore-ver is missing";
			netTarget + "-" + netcoreVer;
		} else
			netTarget + "-" + netVer;
		// the reference conses both com.net_std and its matches, so the two reversals cancel and the
		// directories are read in command-line order
		var matched = [];
		var stds = ctx.netStd.length == 0 ? ["netlib"] : ctx.netStd;
		for (std in stds) {
			var dir = ModuleLoader.findFileOpt(ctx, std + "/" + digraph);
			if (dir != null && FileSystem.exists(dir) && FileSystem.isDirectory(dir)) matched.push(dir);
		}
		// With no --net-std and no netlib directory on the class path (hxcs not installed), hxc's own copy
		// of hxcs's Mono netlib directories serves the digraphs it carries (Netlib).
		var bundled = ctx.netStd.length == 0 && matched.length == 0 ? Netlib.files(digraph) : [];
		if (matched.length == 0 && bundled.length == 0)
			throw "No .NET std lib directory with the pattern '" + digraph + "' was found in the -net-std search path. "
				+ "Try updating the hxcs lib to the latest version, or specifying another -net-std path.";
		for (dir in matched)
			for (f in FileSystem.readDirectory(dir))
				if (StringTools.endsWith(f.toLowerCase(), ".dll")) ctx.netStdFiles.push(dir + "/" + f);
		for (f in bundled) ctx.netStdFiles.push(f);
		// each std library is read as soon as it is found
		for (f in ctx.netStdFiles) addNetLib(ctx, f, true, false).load();
	}

	// Registers the library: it is looked up by Haxe path after every library added before it, and
	// its types are built by the first extern loader that has them. The caller reads it with load().
	public static function addNetLib(ctx:Context, file:String, isStd:Bool, isExtern:Bool):NetLibrary {
		var realFile = if (Netlib.isVirtual(file) || FileSystem.exists(file)) file else {
			var f = ModuleLoader.findFileOpt(ctx, file);
			if (f == null) f = ModuleLoader.findFileOpt(ctx, file + ".dll");
			if (f == null) throw ".NET lib " + file + " not found";
			f;
		}
		var lib = new NetLibrary(ctx, file, realFile, isStd);
		lib.isExtern = isExtern;
		ctx.netLibs.push(lib);
		ctx.loadExternType.push({
			name: realFile,
			load: function(path:hxc.core.Globals.Path, p:hxc.ast.Position) return lib.build(path, p)
		});
		return lib;
	}

	// The .NET version the output targets: -D dotnet-version, else 10 (GenerateDotnet reports a bad value).
	public static function dotnetVersion(ctx:Context):Int {
		if (!ctx.defines.rawDefined("dotnet_version")) return GenerateDotnet.defaultVersion;
		var v = parseInt(ctx.defines.rawDefinedValueSafe("dotnet_version"));
		return v == null || v < GenerateDotnet.defaultVersion ? GenerateDotnet.defaultVersion : v;
	}

	// The .NET SDK's reference pack for that version, `<dotnet root>/packs/Microsoft.NETCore.App.Ref/
	// <v>.0.<highest patch>/ref/net<v>.0`, or null. Its assemblies keep the version <v>.0.0.0 across
	// patches, so which patch is installed does not change the output.
	public static function referencePack(ctx:Context):Null<String> {
		var root = dotnetRoot();
		if (root == null) return null;
		var v = Std.string(dotnetVersion(ctx));
		var packs = root + "/packs/Microsoft.NETCore.App.Ref";
		if (!FileSystem.exists(packs) || !FileSystem.isDirectory(packs)) return null;
		var best:Null<String> = null, bestPatch = -1;
		for (d in FileSystem.readDirectory(packs)) {
			// release versions only: <v>.0.<patch>
			var parts = d.split(".");
			if (parts.length != 3 || parts[0] != v || parts[1] != "0") continue;
			var c = parts[2].charCodeAt(0);
			var patch = c != null && c >= "0".code && c <= "9".code ? parseInt(parts[2]) : null;
			if (patch == null || patch <= bestPatch) continue;
			var dir = packs + "/" + d + "/ref/net" + v + ".0";
			if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) continue;
			bestPatch = patch;
			best = dir;
		}
		return best;
	}

	// DOTNET_ROOT, else the directory of the `dotnet` found on PATH (a link followed), with `/` separators.
	static function dotnetRoot():Null<String> {
		inline function slashes(s:String) return s.split("\\").join("/");
		var env = Sys.getEnv("DOTNET_ROOT");
		if (env != null && env != "") {
			var r = slashes(env);
			while (r.length > 1 && StringTools.endsWith(r, "/")) r = r.substr(0, r.length - 1);
			return r;
		}
		var path = Sys.getEnv("PATH");
		if (path == null) return null;
		var windows = Sys.systemName() == "Windows";
		for (dir in path.split(windows ? ";" : ":")) {
			if (windows && StringTools.startsWith(dir, "\"") && StringTools.endsWith(dir, "\"") && dir.length >= 2)
				dir = dir.substr(1, dir.length - 2);
			if (dir == "") continue;
			var exe = dir + "/" + (windows ? "dotnet.exe" : "dotnet");
			if (!FileSystem.exists(exe) || FileSystem.isDirectory(exe)) continue;
			var full = slashes(FileSystem.fullPath(exe));
			var i = full.lastIndexOf("/");
			return i <= 0 ? "/" : full.substr(0, i);
		}
		return null;
	}

	// OCaml's int_of_string for a decimal value: an optional sign and digits only.
	public static function parseInt(s:String):Null<Int> {
		var start = s.length > 0 && (s.charAt(0) == "-" || s.charAt(0) == "+") ? 1 : 0;
		if (s.length == start) return null;
		for (i in start...s.length) {
			var c = s.charCodeAt(i);
			if (c < "0".code || c > "9".code) return null;
		}
		return Std.parseInt(s);
	}
}
