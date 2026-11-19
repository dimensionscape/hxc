package hxc.core;

// File-system calls that cost much more on one host than on the others when written the plain way.
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
#endif
// 1 for a directory, 0 for anything else that is there, -1 when the attributes do not settle it (nothing
// by that name, or a link, whose target decides).
static int hxc_dir_by_attributes(::String file) {
#ifdef _WIN32
	DWORD a = GetFileAttributesW(file.wchar_str());
	if (a == INVALID_FILE_ATTRIBUTES || (a & FILE_ATTRIBUTE_REPARSE_POINT)) return -1;
	return (a & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
#else
	return -1;
#endif
}
')
#end
class HostFile {
	// A directory's entries, or null when it cannot be listed. On .NET a missing directory is asked for
	// first: the exception a failed listing raises there costs several times what the listing does.
	public static function readDirectoryOpt(dir:String):Null<Array<String>> {
		#if cs
		if (!cs.system.io.Directory.Exists(dir)) return null;
		#end
		return try sys.FileSystem.readDirectory(dir) catch (_:Dynamic) null;
	}

	// Whether there is a directory by that name; false for a file and for nothing at all. On Windows the
	// C++ runtime answers through stat, which opens the file: four system calls where the attributes take
	// one. The attributes answer for a plain path; a link, a missing name and a path the runtime would
	// rewrite first (a drive, a trailing separator) still go the runtime's way.
	public static function isDirectory(path:String):Bool {
		#if cpp
		if (path.length > 3) {
			var last = path.charCodeAt(path.length - 1);
			if (last != "/".code && last != "\\".code) {
				var r:Int = untyped __cpp__("hxc_dir_by_attributes({0})", path);
				if (r >= 0) return r == 1;
			}
		}
		return sys.FileSystem.isDirectory(path);
		#elseif cs
		return cs.system.io.Directory.Exists(path);
		#else
		return try sys.FileSystem.isDirectory(path) catch (_:Dynamic) false;
		#end
	}
}
