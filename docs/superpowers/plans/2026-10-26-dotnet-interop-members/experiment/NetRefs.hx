package hxc.codegen.dotnet;

import sys.FileSystem;
import hxc.context.Context;
import hxc.codegen.dotnet.IlData;

// EXPERIMENT (D:/_hxc4a/refs): finds the assembly that defines a .NET type no --net-lib/--net-std
// assembly defines: the assemblies those reference, found beside them, then the framework's reference
// pack; type forwarders are followed. The assemblies it reads are only for lowering (refOnly).
class NetRefs {
	final ctx:Context;
	// by lower-case simple name; null when no file was found
	final byName = new Map<String, Null<NetLibrary>>();
	final found = new Map<String, Null<NetLibrary>>();
	var refPack:Null<String> = null;
	var refPackSearched = false;

	public static function of(ctx:Context):NetRefs {
		if (ctx.netRefs == null) ctx.netRefs = new NetRefs(ctx);
		return ctx.netRefs;
	}

	function new(ctx:Context) this.ctx = ctx;

	public function definer(path:IlPath):Null<NetLibrary> {
		for (lib in ctx.netLibs) if (lib.definesType(path)) return lib;
		var key = IlPaths.key(path);
		if (found.exists(key)) return found.get(key);
		var r = search(path);
		if (ctx.defines.rawDefined("net_refs_debug"))
			Sys.println("net-refs: " + NetConverter.ilpathS(path) + " -> " + (r == null ? "none" : r.filePath));
		found.set(key, r);
		return r;
	}

	static function dirOf(f:String):String {
		var s = f.split("\\").join("/");
		var i = s.lastIndexOf("/");
		return i < 0 ? "." : s.substr(0, i);
	}

	function findRefPack():Null<String> {
		if (refPackSearched) return refPack;
		refPackSearched = true;
		var ver = ctx.defines.rawDefined("dotnet_version") ? ctx.defines.rawDefinedValueSafe("dotnet_version") : "10";
		var roots = [];
		var env = Sys.getEnv("DOTNET_ROOT");
		if (env != null) roots.push(env);
		for (r in ["C:/Program Files/dotnet", "/usr/share/dotnet", "/usr/local/share/dotnet", "/usr/lib/dotnet"]) roots.push(r);
		for (root in roots) {
			var packs = root + "/packs/Microsoft.NETCore.App.Ref";
			if (!FileSystem.exists(packs)) continue;
			var best:Null<String> = null, bestPatch = -1;
			for (v in FileSystem.readDirectory(packs)) {
				var parts = v.split(".");
				if (parts.length < 3 || parts[0] != ver) continue;
				var patch = Std.parseInt(parts[2]);
				if (patch != null && patch > bestPatch) {
					bestPatch = patch;
					best = v;
				}
			}
			if (best != null) {
				var d = packs + "/" + best + "/ref/net" + ver + ".0";
				if (FileSystem.exists(d)) return refPack = d;
			}
		}
		return null;
	}

	// The assembly named `name`: a loaded one, else one beside `near`, else the reference pack's.
	function load(name:String, near:Null<String>):Null<NetLibrary> {
		var k = name.toLowerCase();
		if (byName.exists(k)) return byName.get(k);
		for (lib in ctx.netLibs) {
			var f = lib.filePath.split("\\").join("/");
			var base = f.substr(f.lastIndexOf("/") + 1);
			if (base.toLowerCase() == k + ".dll") {
				byName.set(k, lib);
				return lib;
			}
		}
		var cands = [];
		if (near != null) cands.push(near + "/" + name + ".dll");
		var rp = findRefPack();
		if (rp != null) cands.push(rp + "/" + name + ".dll");
		for (c in cands) if (FileSystem.exists(c)) {
			var lib = new NetLibrary(ctx, c, c, false);
			lib.refOnly = true;
			var ok = try {
				lib.load();
				true;
			} catch (_:Dynamic) false;
			if (!ok) continue;
			if (ctx.defines.rawDefined("net_refs_debug")) Sys.println("net-refs: read " + c);
			byName.set(k, lib);
			return lib;
		}
		byName.set(k, null);
		return null;
	}

	// Follows `lib`'s forwarders for `path` to the defining assembly.
	function resolveIn(lib:NetLibrary, path:IlPath, depth:Int):Null<NetLibrary> {
		if (lib.definesType(path)) return lib;
		if (depth > 8) return null;
		var to = lib.forwardedTo(path);
		if (to == null) return null;
		var next = load(to, dirOf(lib.filePath));
		return next == null ? null : resolveIn(next, path, depth + 1);
	}

	function search(path:IlPath):Null<NetLibrary> {
		// breadth first over the references of the --net-lib assemblies, then of the --net-std ones
		var seen = new Map<String, Bool>();
		var queue:Array<NetLibrary> = [];
		for (l in ctx.netLibs) if (!l.isStd) queue.push(l);
		for (l in ctx.netLibs) if (l.isStd) queue.push(l);
		var i = 0;
		while (i < queue.length) {
			var lib = queue[i++];
			var r = resolveIn(lib, path, 0);
			if (r != null) return r;
			for (n in lib.assemblyRefNames()) {
				var k = n.toLowerCase();
				if (seen.exists(k)) continue;
				seen.set(k, true);
				var dep = load(n, dirOf(lib.filePath));
				if (dep != null && queue.indexOf(dep) < 0) queue.push(dep);
			}
		}
		// a hand-written extern that no assembly references: the whole reference pack
		var rp = findRefPack();
		if (rp != null) for (f in FileSystem.readDirectory(rp)) if (StringTools.endsWith(f.toLowerCase(), ".dll")) {
			var lib = load(f.substr(0, f.length - 4), null);
			if (lib == null) continue;
			var r = resolveIn(lib, path, 0);
			if (r != null) return r;
		}
		return null;
	}
}
