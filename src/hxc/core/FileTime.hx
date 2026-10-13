package hxc.core;

/**
	A file's times, with the sub-second precision hxcpp's FileSystem.stat drops. There are two sources and
	two formulas:
	- fileTime is the last write time of CreateFile(path) as ticks / 1e7 - EPOCH_DIFF, 0 when the file
	  cannot be opened; elsewhere stat's whole-second st_mtime.
	- statTimes gives each time as (ticks - 116444736000000000) / 1e7 on Windows, which is at times one
	  ulp off the first formula, and elsewhere as stat's seconds plus nanoseconds / 1e9.
**/
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
#else
#include <sys/stat.h>
#include <math.h>
#endif
static double hxc_sys_filetime(::String file) {
#ifdef _WIN32
	FILETIME fp;
	ULARGE_INTEGER ui;
	HANDLE h = CreateFileA(file.utf8_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE | FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
	if (h == INVALID_HANDLE_VALUE || !GetFileTime(h, NULL, NULL, &fp)) {
		CloseHandle(h);
		return 0.;
	}
	CloseHandle(h);
	ui.LowPart = fp.dwLowDateTime;
	ui.HighPart = fp.dwHighDateTime;
	return ((double)ui.QuadPart) / 10000000.0 - (134774*24*60*60.0);
#else
	struct stat sbuf;
	if (stat(file.utf8_str(), &sbuf) < 0) return 0.;
	return (double)sbuf.st_mtime;
#endif
}
#ifdef _WIN32
static double hxc_unix_time(FILETIME t) {
	ULARGE_INTEGER ui;
	ui.LowPart = t.dwLowDateTime;
	ui.HighPart = t.dwHighDateTime;
	return (double)(__int64)(ui.QuadPart - 116444736000000000ULL) / 10000000.0;
}
#else
static double hxc_unix_time(time_t sec, long nsec) {
	double s = (double)sec;
	double t = s + (double)nsec / 1e9;
	// A sum rounded up to the next second stays in the second it belongs to.
	if (t == s + 1.0) t = nextafter(t, s);
	return t;
}
#endif
static bool hxc_unix_stat_times(::String file, Array<Float> out) {
#ifdef _WIN32
	WIN32_FILE_ATTRIBUTE_DATA d;
	if (!GetFileAttributesExW(file.wchar_str(), GetFileExInfoStandard, &d)) return false;
	out[0] = hxc_unix_time(d.ftLastAccessTime);
	out[1] = hxc_unix_time(d.ftLastWriteTime);
	out[2] = hxc_unix_time(d.ftCreationTime);
	return true;
#else
	struct stat st;
	if (stat(file.utf8_str(), &st) < 0) return false;
#ifdef __APPLE__
	out[0] = hxc_unix_time(st.st_atimespec.tv_sec, st.st_atimespec.tv_nsec);
	out[1] = hxc_unix_time(st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec);
	out[2] = hxc_unix_time(st.st_ctimespec.tv_sec, st.st_ctimespec.tv_nsec);
#else
	out[0] = hxc_unix_time(st.st_atim.tv_sec, st.st_atim.tv_nsec);
	out[1] = hxc_unix_time(st.st_mtim.tv_sec, st.st_mtim.tv_nsec);
	out[2] = hxc_unix_time(st.st_ctim.tv_sec, st.st_ctim.tv_nsec);
#endif
	return true;
#endif
}
')
#end
class FileTime {
	public static function fileTime(path:String):Float {
		#if cpp
		return untyped __cpp__("hxc_sys_filetime({0})", path);
		#else
		return try sys.FileSystem.stat(path).mtime.getTime() / 1000.0 catch (_:Dynamic) 0.0;
		#end
	}

	// Unix.stat's st_atime, st_mtime and st_ctime in seconds, or null where it raises.
	public static function statTimes(path:String):Null<{atime:Float, mtime:Float, ctime:Float}> {
		#if cpp
		var out:Array<Float> = [0.0, 0.0, 0.0];
		var ok:Bool = untyped __cpp__("hxc_unix_stat_times({0}, {1})", path, out);
		if (ok) return {atime: out[0], mtime: out[1], ctime: out[2]};
		#end
		var st = try sys.FileSystem.stat(path) catch (_:Dynamic) return null;
		return {atime: st.atime.getTime() / 1000.0, mtime: st.mtime.getTime() / 1000.0, ctime: st.ctime.getTime() / 1000.0};
	}
}
