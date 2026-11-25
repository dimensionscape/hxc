package hxc.codegen.dotnet;

// hxc's own copy of the hxcs runtime: the .hx files under runtime/ beside this file, embedded in the
// binary when hxc is built. With -D dotnet they are served from ROOT, a class-path entry that is no
// directory, so a runtime file's positions read `<hxc-dotnet-runtime>/cs/internal/Runtime.hx`.
#if !macro
@:build(hxc.codegen.dotnet.RuntimeSourcesBuild.build())
#end
class RuntimeSources {
	public static inline final ROOT = "<hxc-dotnet-runtime>/";

	// A path under ROOT, which never reaches the file system.
	public static function isVirtual(path:String):Bool {
		return StringTools.startsWith(path, ROOT);
	}

	// The embedded file at a path relative to ROOT, or null.
	public static function get(path:String):Null<String> {
		return embedded(path);
	}

	// The content of a path under ROOT, or null.
	public static function content(file:String):Null<String> {
		return isVirtual(file) ? embedded(file.substr(ROOT.length)) : null;
	}

	// The names in a directory under ROOT, as FileSystem.readDirectory lists a real one: files and
	// subdirectories, each once. Null for a directory that does not exist.
	public static function readDirectory(dir:String):Null<Array<String>> {
		var bare = ROOT.substr(0, ROOT.length - 1);
		if (dir != bare && !isVirtual(dir)) return null;
		var rel = dir == bare ? "" : dir.substr(ROOT.length);
		while (StringTools.endsWith(rel, "/")) rel = rel.substr(0, rel.length - 1);
		var prefix = rel == "" ? "" : rel + "/";
		var names:Array<String> = [];
		for (p in paths) {
			if (!StringTools.startsWith(p, prefix)) continue;
			var rest = p.substr(prefix.length);
			var slash = rest.indexOf("/");
			var name = slash < 0 ? rest : rest.substr(0, slash);
			if (names.indexOf(name) < 0) names.push(name);
		}
		return names.length == 0 && rel != "" ? null : names;
	}
}
