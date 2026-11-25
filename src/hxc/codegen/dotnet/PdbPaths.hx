package hxc.codegen.dotnet;

import haxe.io.Path;

// The name a PDB's Document row gives a source file, with forward slashes, by the first rule that fits:
// a -D dotnet-pathmap entry, hxc-runtime/ under the embedded runtime, the full path in a -D dotnet-debug-jit
// build, relative to the current folder, haxe-std/ under the std path, haxelib/<library>/ under a library's
// class path, else the full path with a warning. The names the DLL holds for trace and ?pos arguments are
// Haxe's own.

class PdbPaths {
	static inline final STD = "haxe-std/";
	static inline final RUNTIME = "hxc-runtime/";
	static final windows = Sys.systemName() == "Windows";

	// The current folder, the std roots and the library class paths, absolute, ending with a slash.
	final cwd:String;
	final stdRoots:Array<String>;
	final libraries:Array<{classPath:String, library:String}>;
	final pathmap:Array<{from:String, to:String}>;
	// A debugger opens a Document by its name, and a short name is no file it can open.
	final fullPaths:Bool;
	final warn:(String) -> Void;
	// The files the full-path warning has named.
	final warned = new Map<String, Bool>();

	public function new(cwd:String, stdRoots:Array<String>, libraries:Array<{classPath:String, library:String}>, pathmap:Array<{from:String, to:String}>,
			fullPaths:Bool, warn:(String) -> Void) {
		this.cwd = folder(cwd);
		this.stdRoots = [for (r in stdRoots) folder(r)];
		this.libraries = [for (l in libraries) {classPath: folder(l.classPath), library: l.library}];
		this.pathmap = pathmap;
		this.fullPaths = fullPaths;
		this.warn = warn;
	}

	static function folder(p:String):String {
		return Path.addTrailingSlash(full(p));
	}

	static function full(p:String):String {
		return Path.normalize(sys.FileSystem.absolutePath(p));
	}

	// `s` without `prefix`, when `s` starts with it (case-insensitive on Windows), else null.
	static function after(s:String, prefix:String):Null<String> {
		if (prefix.length > s.length) return null;
		var head = s.substr(0, prefix.length);
		return (windows ? head.toLowerCase() == prefix.toLowerCase() : head == prefix) ? s.substr(prefix.length) : null;
	}

	// The pairs of a -D dotnet-pathmap value, `<from>=<to>` separated by commas, or null when it is not
	// that. A relative <from> is relative to `cwd`.
	public static function parsePathmap(s:String, cwd:String):Null<Array<{from:String, to:String}>> {
		var pairs = [];
		for (entry in s.split(",")) {
			var eq = entry.indexOf("=");
			if (eq <= 0) return null;
			var from = entry.substr(0, eq).split("\\").join("/");
			// A <from> need not end at a folder, so its trailing slash is kept apart from the normalizing.
			var slash = StringTools.endsWith(from, "/");
			if (slash) from = from.substr(0, from.length - 1);
			from = full(StringTools.startsWith(from, "/") || from.charAt(1) == ":" ? from : folder(cwd) + from);
			pairs.push({from: slash ? from + "/" : from, to: entry.substr(eq + 1).split("\\").join("/")});
		}
		return pairs;
	}

	public function name(file:String):String {
		var virtual = RuntimeSources.isVirtual(file);
		// A file of the embedded runtime is on no disk.
		var path = virtual ? file : full(file);
		var best = null, rest = null;
		for (m in pathmap) {
			var r = after(path, m.from);
			if (r != null && (best == null || m.from.length > best.from.length)) {
				best = m;
				rest = r;
			}
		}
		if (best != null) return best.to + rest;
		if (virtual) return RUNTIME + path.substr(RuntimeSources.ROOT.length);
		if (fullPaths) return path;
		rest = after(path, cwd);
		if (rest != null) return rest;
		for (root in stdRoots) {
			rest = after(path, root);
			if (rest != null) return STD + rest;
		}
		// The longest class path, as a library inside another's folder wins over it.
		var lib = null;
		for (l in libraries) {
			var r = after(path, l.classPath);
			if (r != null && (lib == null || l.classPath.length > lib.classPath.length)) {
				lib = l;
				rest = r;
			}
		}
		if (lib != null) return "haxelib/" + lib.library + "/" + rest;
		if (!warned.exists(path)) {
			warned.set(path, true);
			warn("the PDB names " + path + " by its full path, as it is outside the build folder, the Haxe std and haxelib libraries; "
				+ "-D dotnet-pathmap=<from>=<to> shortens it");
		}
		return path;
	}
}
