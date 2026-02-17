package hxc.core;

// A file is known by its full path (GetFullPathName on Windows), lowercased on Windows. A relative path
// resolves against the current directory, so `./src/A.hx`, `src/A.hx` and the absolute path an editor sends
// are one file.
class PathKey {
	static var cache = new haxe.ds.StringMap<String>();

	public static function key(path:String):String {
		var k = cache.get(path);
		if (k != null) return k;
		var full:Null<String> = try sys.FileSystem.fullPath(path) catch (_:Dynamic) null;
		if (full == null) full = path;
		full = StringTools.replace(full, "\\", "/");
		if (Globals.isWindows) full = full.toLowerCase();
		cache.set(path, full);
		return full;
	}

	public static inline function same(a:String, b:String):Bool {
		return a == b || key(a) == key(b);
	}

	// A server request can change the current directory, and with it every relative key.
	public static function reset():Void {
		cache = new haxe.ds.StringMap();
	}
}
