package hxc.codegen.dotnet;

import sys.FileSystem;
import hxc.context.Context;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.PeData.PeErrorMessage;

// The assembly that defines a .NET type, for lowering: a loaded library (ctx.netLibs) first, then the
// assemblies the --net-libs reference, transitively and breadth first, each found beside the file that
// references it or else in the .NET reference pack, following type forwarders; and last, for a
// hand-written extern that no assembly references, the reference pack's own types. The assemblies read
// here are reference-only (NetLibrary.refOnly): Haxe 4.3.7's loader never follows references, so typing
// must not see them.
class NetRefs {
	final ctx:Context;
	// the files read, by path; null when one could not be read
	final byFile = new Map<String, Null<NetLibrary>>();
	// why a file could not be read, by path
	final unreadable = new Map<String, String>();
	// the assembly a reference names from a directory, keyed by "<dir>\n<lower-case name>"
	final located = new Map<String, Null<NetLibrary>>();
	// for a reference not located, by the same key: the candidate files that could not be read, and why
	final locateFailures = new Map<String, Array<String>>();
	// definer's answers, by IlPaths.key
	final found = new Map<String, Null<NetLibrary>>();
	// for a type not found, by IlPaths.key: the missing references that could have defined it
	final unresolved = new Map<String, Array<String>>();
	var packSearched = false;
	var pack:Null<String> = null;
	// the reference pack's top-level types (IlPaths.key) and the first file, by name, defining each
	var packIndex:Null<Map<String, String>> = null;
	// the namespaces of the reference pack's types and those enclosing them, dotted
	final packNamespaces = new Map<String, Bool>();
	// namespaceExists's answer set, made once
	var namespaces:Null<Map<String, Bool>> = null;

	public static function of(ctx:Context):NetRefs {
		if (ctx.netRefs == null) ctx.netRefs = new NetRefs(ctx);
		return ctx.netRefs;
	}

	function new(ctx:Context) {
		this.ctx = ctx;
	}

	public function definer(path:IlPath):Null<NetLibrary> {
		for (lib in ctx.netLibs) if (lib.definesType(path)) return lib;
		var key = IlPaths.key(path);
		if (found.exists(key)) return found.get(key);
		var notes:Array<String> = [];
		var r = search(path, notes);
		found.set(key, r);
		if (r == null) unresolved.set(key, notes);
		return r;
	}

	// Why no assembly defines `path`: the reference pack was needed and is not installed, or nothing
	// defines it, naming the references that are missing where one could have.
	public function missing(path:IlPath):String {
		var s = NetConverter.ilpathS(path);
		if (definer(path) != null) throw "internal error: " + s + " is defined";
		var notes = unresolved.get(IlPaths.key(path));
		var why = notes == null || notes.length == 0 ? "" : " (" + notes.join("; ") + ")";
		if (referencePack() == null)
			return "the .NET " + NetSetup.dotnetVersion(ctx) + " reference pack (Microsoft.NETCore.App.Ref) was not found; it is needed for " + s + why;
		return "no referenced assembly defines the .NET type " + s + why;
	}

	// System.Runtime, which the attributes the backend writes on its own come from (AttributesToIl.runtimeAttr):
	// a loaded library of that name, else the reference pack's; null when neither is there.
	public function runtimeLibrary():Null<NetLibrary> {
		for (lib in ctx.netLibs) if (fileName(lib.filePath).toLowerCase() == "system.runtime.dll") return lib;
		var rp = referencePack();
		if (rp == null) return null;
		var f = rp + "/System.Runtime.dll";
		return FileSystem.exists(f) ? read(f) : null;
	}

	function referencePack():Null<String> {
		if (!packSearched) {
			packSearched = true;
			pack = NetSetup.referencePack(ctx);
		}
		return pack;
	}

	static function dirOf(file:String):String {
		var s = file.split("\\").join("/");
		var i = s.lastIndexOf("/");
		return i < 0 ? "." : i == 0 ? "/" : s.substr(0, i);
	}

	static function fileName(file:String):String {
		var s = file.split("\\").join("/");
		return s.substr(s.lastIndexOf("/") + 1);
	}

	// The reference-only library in `file`, cached unless `keep` is false. Null, with the reason in
	// `unreadable`, when the file cannot be opened or the readers reject it (a native DLL, a damaged file:
	// a PeErrorMessage, or one of the strings they throw); any other exception is an hxc bug, and propagates.
	function read(file:String, keep = true):Null<NetLibrary> {
		if (byFile.exists(file)) return byFile.get(file);
		var why:Null<String> = null;
		var lib = new NetLibrary(ctx, file, file, false);
		lib.refOnly = true;
		try {
			sys.io.File.read(file, true).close();
		} catch (_:Dynamic) {
			why = "could not be opened";
		}
		if (why == null) try {
			lib.load();
		} catch (e:PeErrorMessage) {
			// the message without PeErrorMessage's `PeReader.Error_message("...")` wrapping
			var m = e.message, open = e.message.indexOf("(\""), close = e.message.lastIndexOf("\")");
			if (open >= 0 && close > open) m = m.substring(open + 2, close);
			why = "is not a .NET assembly: " + m;
		} catch (e:String) {
			// the readers' other errors (bounds, assertions) all come from data they cannot make sense of
			why = "could not be read: " + e;
		}
		if (why != null) {
			unreadable.set(file, why);
			byFile.set(file, null);
			return null;
		}
		if (keep) byFile.set(file, lib);
		return lib;
	}

	// The assembly a reference from a file in `dir` names: a loaded library of that name, else the file
	// beside the referencing one, else the reference pack's.
	function locate(name:String, dir:String):Null<NetLibrary> {
		var lower = name.toLowerCase();
		var key = dir + "\n" + lower;
		if (located.exists(key)) return located.get(key);
		var r:Null<NetLibrary> = null;
		for (lib in ctx.netLibs) if (fileName(lib.filePath).toLowerCase() == lower + ".dll") {
			r = lib;
			break;
		}
		if (r == null) {
			var cands = [dir + "/" + name + ".dll"];
			var rp = referencePack();
			if (rp != null && rp != dir) cands.push(rp + "/" + name + ".dll");
			var failures = [];
			for (c in cands) if (FileSystem.exists(c) && !FileSystem.isDirectory(c)) {
				r = read(c);
				if (r != null) break;
				var where = c == cands[0] ? fileName(c) + " beside it" : "the reference pack's " + fileName(c);
				failures.push(where + " " + unreadable.get(c));
			}
			if (r == null && failures.length > 0) locateFailures.set(key, failures);
		}
		located.set(key, r);
		return r;
	}

	// The files that were there for the assembly `name`, which `referrer` names, but could not be read;
	// null when there were none.
	function readFailures(referrer:NetLibrary, name:String):Null<Array<String>> {
		return locateFailures.get(dirOf(referrer.filePath) + "\n" + name.toLowerCase());
	}

	function notFound(referrer:NetLibrary, verb:String, name:String):String {
		var head = fileName(referrer.filePath) + " " + verb + " " + name;
		var failures = readFailures(referrer, name);
		if (failures != null) return head + ", but " + failures.join(" and ");
		return head + ", which is neither beside it nor in the reference pack";
	}

	// `lib`, if it defines `path`, else the assembly its forwarders send `path` to.
	function resolveIn(lib:NetLibrary, path:IlPath, notes:Array<String>, depth:Int):Null<NetLibrary> {
		if (lib.definesType(path)) return lib;
		if (depth > 8) return null;
		var to = lib.forwarderTarget(path);
		if (to == null) return null;
		var next = locate(to, dirOf(lib.filePath));
		if (next == null) {
			var note = notFound(lib, "forwards it to", to);
			if (notes.indexOf(note) < 0) notes.push(note);
			return null;
		}
		return resolveIn(next, path, notes, depth + 1);
	}

	// Whether an assembly named `name` might define a type of namespace `ns`, by the usual naming of
	// assemblies after the namespaces they hold.
	static function namedFor(name:String, ns:Array<String>):Bool {
		var n = ns.join(".");
		return n != "" && (name == n || StringTools.startsWith(name, n + ".") || StringTools.startsWith(n, name + "."));
	}

	function search(path:IlPath, notes:Array<String>):Null<NetLibrary> {
		// the --net-libs, then what they reference. The --net-std directories' libraries were searched
		// already and their references are not followed, so they are never queued.
		var queue = [for (lib in ctx.netLibs) if (ctx.netStdFiles.indexOf(lib.filePath) < 0) lib];
		var queued = new Map<String, Bool>();
		for (lib in ctx.netLibs) queued.set(lib.filePath, true);
		var i = 0;
		while (i < queue.length) {
			var lib = queue[i++];
			var r = resolveIn(lib, path, notes, 0);
			if (r != null) return r;
			var dir = dirOf(lib.filePath);
			for (name in lib.assemblyRefs()) {
				var dep = locate(name, dir);
				if (dep == null) {
					// a file that is there but cannot be read is always named
					var note = notFound(lib, "references", name);
					if ((namedFor(name, path.ns) || readFailures(lib, name) != null) && notes.indexOf(note) < 0) notes.push(note);
				} else if (!queued.exists(dep.filePath)) {
					queued.set(dep.filePath, true);
					queue.push(dep);
				}
			}
		}
		// a hand-written extern that no assembly references
		var lib = packDefiner(path);
		if (lib != null) return lib;
		// the types of a pack assembly that could not be read are missing from the index
		var rp = referencePack();
		if (rp != null) {
			var bad = [for (f => why in unreadable) if (dirOf(f) == rp) "the reference pack's " + fileName(f) + " " + why];
			bad.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			for (note in bad) if (notes.indexOf(note) < 0) notes.push(note);
		}
		return null;
	}

	// The reference pack's assembly defining `path`, or null when the pack (or the type in it) is missing.
	public function packDefiner(path:IlPath):Null<NetLibrary> {
		var top:IlPath = path.nested.length > 0 ? {ns: path.ns, nested: [], name: path.nested[0]} : path;
		var file = indexPack().get(IlPaths.key(top));
		var lib = file == null ? null : read(file);
		return lib != null && lib.definesType(path) ? lib : null;
	}

	static function addNamespaces(to:Map<String, Bool>, p:IlPath):Void {
		for (k in 1...p.ns.length + 1) to.set(p.ns.slice(0, k).join("."), true);
	}

	// Whether a type `definer` can find is in the namespace `ns` or in one inside it, as C#'s name lookup sees
	// namespaces (inline C#, CsToIl): those of the loaded libraries, of the assemblies they reference
	// (transitively, as `search` follows them) and of the reference pack.
	public function namespaceExists(ns:Array<String>):Bool {
		if (namespaces == null) {
			namespaces = new Map();
			var queue = [for (lib in ctx.netLibs) lib];
			var queued = new Map<String, Bool>();
			for (lib in ctx.netLibs) queued.set(lib.filePath, true);
			var i = 0;
			while (i < queue.length) {
				var lib = queue[i++];
				for (p in lib.topLevelTypes()) addNamespaces(namespaces, p);
				if (ctx.netStdFiles.indexOf(lib.filePath) >= 0) continue;
				var dir = dirOf(lib.filePath);
				for (name in lib.assemblyRefs()) {
					var dep = locate(name, dir);
					if (dep != null && !queued.exists(dep.filePath)) {
						queued.set(dep.filePath, true);
						queue.push(dep);
					}
				}
			}
			indexPack();
			for (k in packNamespaces.keys()) namespaces.set(k, true);
		}
		return namespaces.exists(ns.join("."));
	}

	// Reads every assembly of the reference pack once, keeping only which file defines each top-level
	// type; files are read in name order, so the first definer is the same on every machine.
	function indexPack():Map<String, String> {
		if (packIndex != null) return packIndex;
		packIndex = new Map();
		var rp = referencePack();
		if (rp == null) return packIndex;
		var files = [for (f in FileSystem.readDirectory(rp)) if (StringTools.endsWith(f.toLowerCase(), ".dll")) f];
		files.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (f in files) {
			var lib = read(rp + "/" + f, false);
			if (lib == null) continue;
			for (p in lib.topLevelTypes()) {
				var key = IlPaths.key(p);
				if (!packIndex.exists(key)) packIndex.set(key, rp + "/" + f);
				addNamespaces(packNamespaces, p);
			}
		}
		return packIndex;
	}
}
