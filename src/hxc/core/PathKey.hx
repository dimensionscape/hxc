package hxc.core;

// A file is known by its full path (GetFullPathName on Windows), lowercased on Windows. A relative path
// resolves against the current directory, so `./src/A.hx`, `src/A.hx` and the absolute path an editor sends
// are one file.
#if cpp
@:cppFileCode('
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <string.h>
#else
#include <stdlib.h>
#include <limits.h>
#endif
// Use the narrow native real-path API; return the original path on failure.
static ::String hxc_get_real_path(::String path) {
#ifdef _WIN32
	const char sep = 0x5c;
	size_t len, i, last;
	WIN32_FIND_DATAA data;
	HANDLE handle;
	char out[MAX_PATH];
	DWORD n = GetFullPathNameA(path.utf8_str(), MAX_PATH, out, NULL);
	// An oversized path leaves the buffer unset; the stub does not check it.
	if (n == 0 || n >= MAX_PATH)
		return path;
	len = strlen(out);
	i = 0;
	if (len >= 2 && out[1] == 0x3a) {
		if (out[0] >= 0x61 && out[0] <= 0x7a)
			out[0] += 0x41 - 0x61;
		if (len >= 3 && out[2] == sep)
			i = 3;
		else
			i = 2;
	}
	last = i;
	while (i < len) {
		while (i < len && out[i] != sep)
			i++;
		out[i] = 0;
		if ((handle = FindFirstFileA(out, &data)) != INVALID_HANDLE_VALUE) {
			int klen = (int)strlen(data.cFileName);
			if (klen != (int)(i - last)) {
				int d = klen - (int)(i - last);
				if (len + d >= MAX_PATH) { FindClose(handle); return path; }
				memmove(out + i + d, out + i, len - i + 1);
				len += d;
				i += d;
			}
			memcpy(out + last, data.cFileName, klen + 1);
			FindClose(handle);
		}
		if (i < len)
			out[i] = sep;
		i++;
		last = i;
	}
	return ::String(out);
#else
	char buf[PATH_MAX];
	if (realpath(path.utf8_str(), buf) == NULL)
		return path;
	return ::String(buf);
#endif
}
')
#end
class PathKey {
	static var cache = new haxe.ds.StringMap<String>();

	public static function key(path:String):String {
		var k = cache.get(path);
		if (k != null) return k;
		var full = StringTools.replace(fullPath(path), "\\", "/");
		if (Globals.isWindows) full = full.toLowerCase();
		cache.set(path, full);
		return full;
	}

	public static inline function same(a:String, b:String):Bool {
		return a == b || key(a) == key(b);
	}

	// The absolute path of a file. On Windows GetFullPathName, or the path itself where that fails.
	// Elsewhere it is worked out from the string and the current directory without touching the file
	// system, so the file need not exist and symbolic links stay; `.`, `..`, doubled and trailing slashes
	// are folded only when the path has any.
	public static function fullPath(f:String):String {
		if (Globals.isWindows) return try sys.FileSystem.fullPath(f) catch (_:Dynamic) f;
		var length = f.length;
		function skipPastSlash(i:Int):Int {
			while (i < length) {
				if (f.charCodeAt(i) == "/".code) return i + 1;
				i++;
			}
			return i;
		}
		function hasDotsOrDoubleSlash(i:Int):Bool {
			while (i < length) {
				var has = switch (f.charCodeAt(i)) {
					case ".".code:
						if (i + 2 < length) {
							var a = f.charCodeAt(i + 1);
							(a == ".".code && f.charCodeAt(i + 2) == "/".code) || a == "/".code;
						} else if (i + 1 < length) {
							var a = f.charCodeAt(i + 1);
							a == "/".code || a == ".".code;
						} else true;
					case "/".code if (i > 0): true;
					case _: false;
				}
				if (has) return true;
				i = skipPastSlash(i);
			}
			return false;
		}
		var cwd = Sys.getCwd();
		if (cwd.length > 1 && StringTools.endsWith(cwd, "/")) cwd = cwd.substr(0, cwd.length - 1);
		var absolutePath = if (length > 0 && f.charCodeAt(0) == "/".code) f else if (length == 0) cwd else cwd + "/" + f;
		var hasTrailingSlash = length > 0 && f.charCodeAt(length - 1) == "/".code;
		if (!hasTrailingSlash && !hasDotsOrDoubleSlash(0)) return absolutePath;
		// From the last component back, so that each `..` drops the component before it.
		var parts = absolutePath.split("/");
		var normalized:Array<String> = [];
		var skip = 0;
		var i = parts.length;
		while (i-- > 0) {
			var current = parts[i];
			if (current == "..") skip++;
			else if (current == "." || current == "") {}
			else if (skip > 0) skip--;
			else normalized.push(current);
		}
		normalized.reverse();
		return "/" + normalized.join("/");
	}

	// On Windows the full path with the drive letter upper-cased and each component that exists spelled the
	// way FindFirstFile answers it (a short `~` name expands); a component that does not exist, and so
	// everything below it, keeps the case it was given. Elsewhere the full path. The path itself where that
	// fails.
	public static function realPath(p:String):String {
		#if cpp
		return untyped __cpp__("hxc_get_real_path({0})", p);
		#else
		return try sys.FileSystem.fullPath(p) catch (_:Dynamic) p;
		#end
	}

	// A server request can change the current directory, and with it every relative key.
	public static function reset():Void {
		cache = new haxe.ds.StringMap();
	}
}
