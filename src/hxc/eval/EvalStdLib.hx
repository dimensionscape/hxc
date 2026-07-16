package hxc.eval;

import hxc.ast.Position;
import hxc.ast.Ast.Import;
import hxc.ast.Ast.ImportMode;
import hxc.ast.Ast.PlacedName;
import hxc.core.Type.ModuleType;
import hxc.core.TypeFunctions;
import hxc.eval.EvalValue;
import hxc.eval.EvalValue.EvalValueTools;
import hxc.eval.EvalContext;
import hxc.eval.EvalField;
import hxc.eval.EvalMisc;
import hxc.eval.EvalHash;
import hxc.eval.EvalString;
import hxc.eval.Pcre2.Pcre2Flag;
#if cpp
import cpp.NativeSocket;
#end

typedef ThreadConditionState = {
	var cond:sys.thread.Condition;
	var owner:Null<sys.thread.Thread>;
	var count:Int;
}

// Native builtins for extern standard-library types. Each entry maps a type and field name to a
// value (a function or a constant) that the prototype builder installs on the type's prototype.
#if cpp
@:cppFileCode('#include <stdio.h>\n#include <string.h>\n#include <time.h>\n#include <errno.h>\n#include <fcntl.h>\n#include <sys/stat.h>\n#ifdef _WIN32\n#include <direct.h>\n#include <io.h>\n#include <wchar.h>\n#include <windows.h>\n#else\n#include <unistd.h>\n#endif\n// Return null on success or strerror(errno) on failure. Operations: 0 unlink, 1 rmdir, 2 mkdir, 3\n// rename, 4 chdir, 5 stat, 6 open for reading, 7 open for writing. Windows rename uses MoveFileEx\n// and maps its error to errno.\nstatic ::String hxc_fs_call(int op, ::String a, ::String b) {\n	int r = 0;\n#ifdef _WIN32\n	const wchar_t *wa = a.wchar_str();\n	switch (op) {\n		case 0: r = _wunlink(wa); break;\n		case 1: r = _wrmdir(wa); break;\n		case 2: r = _wmkdir(wa); break;\n		case 3: {\n			if (MoveFileExW(wa, b.wchar_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH | MOVEFILE_COPY_ALLOWED)) return ::String();\n			switch (GetLastError()) {\n				case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: case ERROR_INVALID_DRIVE: case ERROR_BAD_NETPATH: case ERROR_BAD_NET_NAME: case ERROR_BAD_PATHNAME: case ERROR_FILENAME_EXCED_RANGE: errno = ENOENT; break;\n				case ERROR_FILE_EXISTS: case ERROR_ALREADY_EXISTS: errno = EEXIST; break;\n				case ERROR_NOT_SAME_DEVICE: errno = EXDEV; break;\n				case ERROR_DIR_NOT_EMPTY: errno = ENOTEMPTY; break;\n				case ERROR_NOT_ENOUGH_MEMORY: errno = ENOMEM; break;\n				case ERROR_INVALID_HANDLE: errno = EBADF; break;\n				default: errno = EACCES; break;\n			}\n			r = -1;\n			break;\n		}\n		case 4: r = _wchdir(wa); break;\n		case 5: { struct _stat64 st; r = _wstat64(wa, &st); break; }\n		case 6: { int fd = _wopen(wa, _O_RDONLY | _O_BINARY, 0); if (fd >= 0) { _close(fd); return ::String(); } r = -1; break; }\n		case 7: { int fd = _wopen(wa, _O_WRONLY | _O_BINARY, 0); if (fd >= 0) { _close(fd); return ::String(); } r = -1; break; }\n	}\n#else\n	const char *ca = a.utf8_str();\n	switch (op) {\n		case 0: r = unlink(ca); break;\n		case 1: r = rmdir(ca); break;\n		case 2: r = mkdir(ca, 0755); break;\n		case 3: r = rename(ca, b.utf8_str()); break;\n		case 4: r = chdir(ca); break;\n		case 5: { struct stat st; r = stat(ca, &st); break; }\n		case 6: { int fd = open(ca, O_RDONLY); if (fd >= 0) { close(fd); return ::String(); } r = -1; break; }\n		case 7: { int fd = open(ca, O_WRONLY); if (fd >= 0) { close(fd); return ::String(); } r = -1; break; }\n	}\n#endif\n	if (r == 0) return ::String();\n	return ::String(strerror(errno));\n}\n// On Windows, read the process environment block used by libuv and chdir, including drive entries\n// such as "=C:". The C library copy used by hxcpp getenv can be stale. Elsewhere they are the same.\nstatic ::String hxc_env_get(::String name) {\n#ifdef _WIN32\n\tconst wchar_t *wn = name.wchar_str();\n\tDWORD n = GetEnvironmentVariableW(wn, NULL, 0);\n\tif (n == 0) return ::String();\n\twchar_t *buf = (wchar_t*)malloc(n * sizeof(wchar_t));\n\tDWORD m = GetEnvironmentVariableW(wn, buf, n);\n\t::String r = ::String::create(buf, (int)m);\n\tfree(buf);\n\treturn r;\n#else\n\tconst char *v = getenv(name.utf8_str());\n\treturn v ? ::String(v) : ::String();\n#endif\n}\n#ifndef _WIN32\nextern char **environ;\n#endif\nstatic Array< ::String> hxc_env_list() {\n\tArray< ::String> out = Array_obj< ::String>::__new(0, 0);\n#ifdef _WIN32\n\twchar_t *block = GetEnvironmentStringsW();\n\tif (!block) return out;\n\tfor (wchar_t *e = block; *e; e += wcslen(e) + 1) out->push(::String::create(e, (int)wcslen(e)));\n\tFreeEnvironmentStringsW(block);\n#else\n\tfor (char **e = environ; *e; e++) out->push(::String(*e));\n#endif\n\treturn out;\n}')
#end
class EvalStdLib {
	static function reg(map:Map<Int, Array<BuiltinField>>, typeName:String, fieldName:String, v:EvalValue):Void {
		var key = EvalHash.hash(typeName);
		var list = map.get(key);
		if (list == null) {
			list = [];
			map.set(key, list);
		}
		list.push({name: EvalHash.hash(fieldName), v: withArity(typeName, fieldName, v)});
	}

	// A native given more arguments than its wrapper takes (an instance native's receiver counted) is
	// "Invalid number of call arguments: Expected <n>, got <m>", n being what the wrapper reports.
	static function withArity(typeName:String, fieldName:String, v:EvalValue):EvalValue {
		return switch (v) {
			case VFunction(f, isStatic):
				var a = EvalNativeArity.table.get(typeName + (isStatic ? "." : "#") + fieldName);
				if (a == null) v else {
					var most = a >> 4;
					var reported = a & 15;
					VFunction(function(args:Array<EvalValue>):EvalValue {
						if (args.length > most) return EvalExceptions.invalidCallArgNumber(EvalContext.getCtx(), reported, args.length);
						return f(args);
					}, isStatic);
				}
			case _: v;
		};
	}

	static inline function vfn(f:VFunc):EvalValue return VFunction(f, true);

	// An instance builtin: a non-static function so dispatch wraps it with the receiver.
	static inline function vmethod(f:VFunc):EvalValue return VFunction(f, false);

	static inline function arg(a:Array<EvalValue>, i:Int):EvalValue return i < a.length ? a[i] : VNull;

	static function toInt(v:EvalValue):Int {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f): Std.int(f);
			case _: 0;
		};
	}

	// An Int, or a float through a 63-bit integer conversion (NaN and anything past 63 bits come out 0
	// on amd64, and bit 62 wraps the sign); anything else is unexpected. hxc's ints are 32 bits, so a
	// float past them saturates, which keeps a bounds test on the side a wider int is on; a native
	// keeping only the low bits of such a float (Bytes.set, fill, setUInt16) would see different ones.
	public static function decodeInt(ctx:EvalContext, v:EvalValue):Int {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f):
				if (Math.isNaN(f) || !(Math.abs(f) < 9223372036854775808.0)) 0;
				else {
					var t = f < 0 ? Math.fceil(f) : Math.ffloor(f);
					if (t >= 4611686018427387904.0) t -= 9223372036854775808.0;
					else if (t < -4611686018427387904.0) t += 9223372036854775808.0;
					t > 2147483647.0 ? 2147483647 : t < -2147483648.0 ? -2147483648 : Std.int(t);
				}
			case _: EvalExceptions.unexpectedValue(ctx, v, "int");
		};
	}

	// Null is the default, anything else decodeInt.
	public static function defaultInt(ctx:EvalContext, v:EvalValue, d:Int):Int {
		return v == VNull ? d : decodeInt(ctx, v);
	}

	// decodeInt for a native that keeps only the low bits of the value (Bytes.set, fill,
	// setUInt16): a float's integer conversion keeps its low 32 bits, which saturation would lose.
	static function decodeIntLow(ctx:EvalContext, v:EvalValue):Int {
		return switch (v) {
			case VInt(i): i;
			case VFloat(_): switch (stdInt(v)) { case VInt(i): i; case _: 0; };
			case _: EvalExceptions.unexpectedValue(ctx, v, "int");
		};
	}

	// The interpreter's fixed NaN (the bit pattern 0x7FF0_0000_0000_0001) that the natives answer; a
	// NaN a float operation makes is the hardware's.
	public static final hostNan:Float = haxe.io.FPHelper.i64ToDouble(1, 0x7FF00000);

	// The sort arrays use: a ternary heap sort, so elements that compare equal do not keep their
	// order, and the comparator is called in the heap's order.
	static function stableArraySort(a:Array<EvalValue>, cmp:(EvalValue, EvalValue) -> Int):Void {
		// Maxson's `raise (Bottom i)` is answered as -1 - i.
		function maxson(l:Int, i:Int):Int {
			var i31 = i + i + i + 1;
			var x = i31;
			if (i31 + 2 < l) {
				if (cmp(a[i31], a[i31 + 1]) < 0) x = i31 + 1;
				if (cmp(a[x], a[i31 + 2]) < 0) x = i31 + 2;
				return x;
			}
			return if (i31 + 1 < l && cmp(a[i31], a[i31 + 1]) < 0) i31 + 1 else if (i31 < l) i31 else -1 - i;
		}
		function trickle(l:Int, i:Int, e:EvalValue):Void {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) {
					a[-1 - j] = e;
					return;
				}
				if (cmp(a[j], e) > 0) {
					a[i] = a[j];
					i = j;
				} else {
					a[i] = e;
					return;
				}
			}
		}
		function bubble(l:Int, i:Int):Int {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) return -1 - j;
				a[i] = a[j];
				i = j;
			}
		}
		function trickleup(i:Int, e:EvalValue):Void {
			while (true) {
				var father = Std.int((i - 1) / 3);
				if (cmp(a[father], e) < 0) {
					a[i] = a[father];
					if (father > 0) i = father;
					else {
						a[0] = e;
						return;
					}
				} else {
					a[i] = e;
					return;
				}
			}
		}
		var l = a.length;
		var i = Std.int((l + 1) / 3) - 1;
		while (i >= 0) {
			trickle(l, i, a[i]);
			i--;
		}
		i = l - 1;
		while (i >= 2) {
			var e = a[i];
			a[i] = a[0];
			trickleup(bubble(i, 0), e);
			i--;
		}
		if (l > 1) {
			var e = a[1];
			a[1] = a[0];
			a[0] = e;
		}
	}

	// An Int or a float; anything else is unexpected.
	public static function num(ctx:EvalContext, v:EvalValue):Float {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f): f;
			case _: EvalExceptions.unexpectedValue(ctx, v, "number");
		};
	}

	// A string and nothing else.
	public static function decodeVString(ctx:EvalContext, v:EvalValue):VString {
		return switch (v) {
			case VString(s): s;
			case _: EvalExceptions.unexpectedValue(ctx, v, "string");
		};
	}

	// Mktime over a struct tm with tm_isdst -1; -1 from mktime is the error "Result too large(mktime,
	// )". Answers the clock in seconds.
	static function unixMktime(ctx:EvalContext, y:Int, mo:Int, d:Int, h:Int, mi:Int, s:Int):Float {
		#if cpp
		var clock:Float = untyped __cpp__('([](int y, int mo, int d, int h, int mi, int s) { struct tm t; memset(&t, 0, sizeof(t)); t.tm_year = y - 1900; t.tm_mon = mo; t.tm_mday = d; t.tm_hour = h; t.tm_min = mi; t.tm_sec = s; t.tm_isdst = -1; return (double)mktime(&t); })({0}, {1}, {2}, {3}, {4}, {5})', y, mo, d, h, mi, s);
		#else
		var clock = new Date(y, mo, d, h, mi, s).getTime() / 1000;
		#end
		if (clock == -1) EvalExceptions.excString(ctx, "Result too large(mktime, )");
		return clock;
	}

	// Localtime/gmtime on a clock in seconds, one field of the result: 0 sec, 1 min, 2 hour, 3 mday, 4
	// mon, 5 year, 6 wday. The minimum Int when the C library answers no tm (Windows' does for a time
	// before 1970), which is an EINVAL error.
	static function unixTmField(seconds:Float, utc:Bool, field:Int):Int {
		#if cpp
		return untyped __cpp__('([](double s, bool utc, int f) { time_t c = (time_t)s; struct tm *t = utc ? gmtime(&c) : localtime(&c); if (!t) return (int)0x80000000; switch (f) { case 0: return t->tm_sec; case 1: return t->tm_min; case 2: return t->tm_hour; case 3: return t->tm_mday; case 4: return t->tm_mon; case 5: return t->tm_year; default: return t->tm_wday; } })({0}, {1}, {2})', seconds, utc, field);
		#else
		var dt = Date.fromTime(seconds * 1000);
		return switch (field) {
			case 0: utc ? dt.getUTCSeconds() : dt.getSeconds();
			case 1: utc ? dt.getUTCMinutes() : dt.getMinutes();
			case 2: utc ? dt.getUTCHours() : dt.getHours();
			case 3: utc ? dt.getUTCDate() : dt.getDate();
			case 4: utc ? dt.getUTCMonth() : dt.getMonth();
			case 5: (utc ? dt.getUTCFullYear() : dt.getFullYear()) - 1900;
			case _: utc ? dt.getUTCDay() : dt.getDay();
		};
		#end
	}

	// Date's getters: a localtime (or gmtime) failure is printed "Invalid argument(localtime, )".
	static function dateField(ctx:EvalContext, ms:Float, utc:Bool, field:Int):Int {
		var v = unixTmField(ms / 1000, utc, field);
		if (v == 0x80000000) EvalExceptions.excString(ctx, "Invalid argument(" + (utc ? "gmtime" : "localtime") + ", )");
		return v;
	}

	// getTimezoneOffset: the local and UTC broken-down times, each back through mktime, and their
	// difference in minutes.
	static function dateTimezoneOffset(ctx:EvalContext, ms:Float):Int {
		#if cpp
		var r:Float = untyped __cpp__('([](double s) { time_t c = (time_t)s; struct tm *l = localtime(&c); if (!l) return 1e300; struct tm lt = *l; struct tm *g = gmtime(&c); if (!g) return 2e300; struct tm gt = *g; lt.tm_isdst = -1; gt.tm_isdst = -1; time_t a = mktime(&lt); if (a == (time_t)-1) return 3e300; time_t b = mktime(&gt); if (b == (time_t)-1) return 3e300; return ((double)b - (double)a) / 60.0; })({0})', ms / 1000);
		if (r == 1e300) EvalExceptions.excString(ctx, "Invalid argument(localtime, )");
		if (r == 2e300) EvalExceptions.excString(ctx, "Invalid argument(gmtime, )");
		if (r == 3e300) EvalExceptions.excString(ctx, "Result too large(mktime, )");
		return decodeInt(ctx, VFloat(r));
		#else
		return Date.fromTime(ms).getTimezoneOffset();
		#end
	}

	// A Date printed: localtime, uncaught when it fails (the exception ends the compilation), as
	// "%.4d-%.2d-%.2d %.2d:%.2d:%.2d".
	static function sDate(ms:Float):String {
		var s = ms / 1000;
		var year = unixTmField(s, false, 5);
		if (year == 0x80000000) throw new hxc.eval.EvalExceptions.HostException('Unix.Unix_error(Unix.EINVAL, "localtime", "")');
		function pad(v:Int, n:Int):String {
			var neg = v < 0;
			var t = Std.string(neg ? -v : v);
			while (t.length < n) t = "0" + t;
			return neg ? "-" + t : t;
		}
		return pad(year + 1900, 4) + "-" + pad(unixTmField(s, false, 4) + 1, 2) + "-" + pad(unixTmField(s, false, 3), 2) + " "
			+ pad(unixTmField(s, false, 2), 2) + ":" + pad(unixTmField(s, false, 1), 2) + ":" + pad(unixTmField(s, false, 0), 2);
	}

	// hxc_fs_call (the class's C++): the C library's answer to a filesystem call, errno's strerror
	// when it fails and null when it succeeds.
	static function cFs(op:Int, a:String, ?b:String):Null<String> {
		#if cpp
		var r:String = untyped __cpp__('hxc_fs_call({0}, {1}, {2})', op, a, b == null ? "" : b);
		return r;
		#else
		return null;
		#end
	}

	// A system error: "<path>: <strerror>", which the natives turn into a string exception.
	static function sysError(ctx:EvalContext, path:String, err:String):Dynamic {
		return EvalExceptions.excString(ctx, path + ": " + err);
	}

	// A Unix error: "<strerror>(<call>, <arg>)".
	static function unixError(ctx:EvalContext, err:String, call:String, arg:String):Dynamic {
		return EvalExceptions.excString(ctx, err + "(" + call + ", " + arg + ")");
	}

	// A drive root keeps (or gains) its slash, "/" stays and anything else loses its trailing slashes.
	static function fsPatchPath(s:String):String {
		if (s.length > 1 && s.length <= 3 && s.charAt(1) == ":") return haxe.io.Path.addTrailingSlash(s);
		if (s == "/") return "/";
		var l = s.length;
		while (l > 0 && (s.charAt(l - 1) == "/" || s.charAt(l - 1) == "\\")) l--;
		return s.substr(0, l);
	}

	// The emitter's own decode, which prints the value without its kind and raises at the
	// expression's position.
	public static function unexpectedValueP(ctx:EvalContext, v:EvalValue, expected:String, p:hxc.ast.Position):Dynamic {
		return v == VNull ? EvalExceptions.excString(ctx, "Null Access", p) : EvalExceptions.excValues(ctx, ["Unexpected value ", ", expected " + expected], [v], p);
	}

	public static function decodeIntP(ctx:EvalContext, v:EvalValue, p:hxc.ast.Position):Int {
		return switch (v) {
			case VInt(_) | VFloat(_): decodeInt(ctx, v);
			case _: unexpectedValueP(ctx, v, "int", p);
		};
	}

	// A code point from an Int: a value with bit 31 set is Invalid_argument.
	static function ucharOfInt(i:Int):Int {
		if (i < 0) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("UChar.uint_chr")');
		return i;
	}

	// A host open that failed, reported as a system error: the same open's errno (op 6 to read, 7 to
	// write) behind the path; the host's own message if the C library now succeeds.
	static function openError(ctx:EvalContext, path:String, op:Int, hostError:Dynamic):Dynamic {
		var err = cFs(op, path);
		return err != null ? sysError(ctx, path, err) : EvalExceptions.excString(ctx, Std.string(hostError));
	}

	static function decodeBool(ctx:EvalContext, v:EvalValue):Bool {
		return switch (v) {
			case VTrue: true;
			case VFalse: false;
			case _: EvalExceptions.unexpectedValue(ctx, v, "bool");
		};
	}

	static function processGetEnv(name:String):Null<String> {
		#if cpp
		var v:String = untyped __cpp__("hxc_env_get({0})", name);
		return v;
		#else
		return Sys.getEnv(name);
		#end
	}

	static function processEnvironment():Array<String> {
		#if cpp
		return untyped __cpp__("hxc_env_list()");
		#else
		return [for (k => v in Sys.environment()) k + "=" + v];
		#end
	}

	// A function is called with the arguments, a field closure with its receiver first, and anything
	// else is "Cannot call <value>".
	static function callValue(ctx:EvalContext, f:EvalValue, args:Array<EvalValue>):EvalValue {
		return switch (f) {
			case VFunction(fn, _): fn(args);
			case VFieldClosure(recv, fn): fn([recv].concat(args));
			// A macro's TLazy(f) is called to force the type.
			case VInstance({ikind: ILazyType(_, get)}): get();
			case _: EvalExceptions.excValues(ctx, ["Cannot call ", ""], [f]);
		};
	}

	// Stdlib.compare of two byte strings: the common prefix, then the length; -1, 0 or 1.
	static function bytesCompare(b:haxe.io.Bytes, other:haxe.io.Bytes):Int {
		var len = b.length < other.length ? b.length : other.length;
		for (i in 0...len) {
			var x = b.get(i);
			var y = other.get(i);
			if (x != y) return x < y ? -1 : 1;
		}
		return b.length < other.length ? -1 : b.length > other.length ? 1 : 0;
	}

	// String.charCodeAt, which StringTools.fastCodeAt and haxe.Utf8.charCodeAt also are: the string
	// is the receiver or the first argument.
	static function stdStringCharCodeAt(ctx:EvalContext, a:Array<EvalValue>):EvalValue {
		var self = thisString(ctx, a);
		var i = decodeInt(ctx, arg(a, 1));
		return i < 0 || i >= self.slength ? VNull : VInt(EvalString.charAt(self, i));
	}

	// String.substr, which haxe.Utf8.sub also is: a position past the end is "" before the length is
	// looked at, and the length is an Int or null (a float is unexpected).
	static function stdStringSubstr(ctx:EvalContext, a:Array<EvalValue>):EvalValue {
		var self = thisString(ctx, a);
		var clThis = self.slength;
		var cPos = decodeInt(ctx, arg(a, 1));
		if (cPos >= clThis) return EvalString.vEmptyString();
		if (cPos < 0) {
			cPos = self.slength + cPos;
			if (cPos < 0) cPos = 0;
		}
		var cLen = switch (arg(a, 2)) {
			case VNull: clThis - cPos;
			case VInt(i): i;
			case v: EvalExceptions.unexpectedValue(ctx, v, "int");
		};
		if (cLen < 0) cLen = clThis + cLen - cPos
		else if (cLen > clThis - cPos) cLen = clThis - cPos;
		return VString(EvalString.substr(self, cPos, cLen));
	}

	// A binary flag is true or null for binary.
	static function fileBinaryFlag(v:EvalValue):Bool {
		return switch (v) {
			case VTrue | VNull: true;
			case _: false;
		};
	}

	// A receiver (or a string argument) that is not a string is unexpected.
	static function thisString(ctx:EvalContext, a:Array<EvalValue>):VString {
		return switch (a[0]) {
			case VString(s): s;
			case v: EvalExceptions.unexpectedValue(ctx, v, "string");
		};
	}

	// Anything but an array is unexpected.
	static function thisArray(ctx:EvalContext, a:Array<EvalValue>):VArray {
		return switch (a[0]) {
			case VArray(va): va;
			case v: EvalExceptions.unexpectedValue(ctx, v, "array");
		};
	}

	static function arrayLive(va:VArray):Array<EvalValue> {
		return va.avalues.slice(0, va.alength);
	}

	static function arrayEnsure(va:VArray, len:Int):Void {
		while (va.avalues.length < len) va.avalues.push(VNull);
	}

	static function arraySet(va:VArray, i:Int, v:EvalValue):Void {
		if (i >= va.alength) {
			if (i >= va.avalues.length) {
				var len = va.avalues.length * 2 + 5;
				var minLen = i + 5;
				if (len < minLen) len = minLen;
				arrayEnsure(va, len);
			}
			va.alength = i + 1;
		}
		va.avalues[i] = v;
	}

	static function arrayPush(va:VArray, v:EvalValue):Int {
		if (va.alength + 1 >= va.avalues.length) arrayEnsure(va, va.avalues.length * 2 + 5);
		va.avalues[va.alength] = v;
		va.alength++;
		return va.alength;
	}

	static function arrayInsert(va:VArray, pos:Int, v:EvalValue):Void {
		if (va.alength + 1 >= va.avalues.length) arrayEnsure(va, va.avalues.length * 2 + 5);
		var count = va.alength - pos;
		for (i in 0...count) {
			var src = va.alength - i - 1;
			va.avalues[src + 1] = va.avalues[src];
		}
		va.avalues[pos] = v;
		va.alength++;
	}

	static function arrayRemoveAt(va:VArray, pos:Int):Void {
		var count = va.alength - pos - 1;
		for (i in 0...count) va.avalues[pos + i] = va.avalues[pos + i + 1];
		va.alength--;
	}

	static function thisVector(ctx:EvalContext, a:Array<EvalValue>):Array<EvalValue> {
		return switch (a[0]) {
			case VVector(vv): vv;
			case v: EvalExceptions.unexpectedValue(ctx, v, "vector");
		};
	}

	// Map: the callback is a function or a field closure, looked at before any element is, and
	// anything else is "Cannot call <value>". A function is called without the receiver.
	static function mapCallback(ctx:EvalContext, fn:EvalValue):EvalValue->EvalValue {
		return switch (fn) {
			case VFunction(f, _): v -> f([v]);
			case VFieldClosure(recv, f): v -> f([recv, v]);
			case _: EvalExceptions.excValues(ctx, ["Cannot call ", ""], [fn]);
		};
	}

	static function sortedFieldKeys(names:Map<Int, Int>):Array<Int> {
		var keys = [for (k in names.keys()) k];
		keys.sort(function(a, b) return names.get(a) - names.get(b));
		return keys;
	}

	// An instance's field keys in the name-map fold's order, the same one an object's fields take.
	// Not slot order: that is declaration order, which Reflect.fields of an instance (and a value
	// signature over one) never lists.
	static function instanceFieldKeys(proto:VPrototype):Array<Int> {
		return ptmapOrderedKeys([for (k in proto.pinstanceNames.keys()) k]);
	}

	static inline function rotl32(x:Int, n:Int):Int {
		return (x << n) | (x >>> (32 - n));
	}

	static inline function hashMix(h0:Int, d0:Int):Int {
		var d = d0 * 0xcc9e2d51;
		d = rotl32(d, 15);
		d *= 0x1b873593;
		var h = h0 ^ d;
		h = rotl32(h, 13);
		return h * 5 + 0xe6546b64;
	}

	static inline function hashFinalMix(h0:Int):Int {
		var h = h0;
		h ^= h >>> 16;
		h *= 0x85ebca6b;
		h ^= h >>> 13;
		h *= 0xc2b2ae35;
		h ^= h >>> 16;
		return h;
	}

	// String comparison: unsigned byte-wise over the UTF-8 representation.
	static function byteStringCompare(a:String, b:String):Int {
		var ba = haxe.io.Bytes.ofString(a);
		var bb = haxe.io.Bytes.ofString(b);
		var n = ba.length < bb.length ? ba.length : bb.length;
		for (i in 0...n) {
			var d = ba.get(i) - bb.get(i);
			if (d != 0) return d;
		}
		return ba.length - bb.length;
	}

	public static function seededStringHash(s:String):Int {
		var cached = stringHashCache.get(s);
		if (cached != null) return cached;
		var bytes = haxe.io.Bytes.ofString(s);
		var h = 0;
		var i = 0;
		while (i + 4 <= bytes.length) {
			h = hashMix(h, bytes.get(i) | (bytes.get(i + 1) << 8) | (bytes.get(i + 2) << 16) | (bytes.get(i + 3) << 24));
			i += 4;
		}
		var w = 0;
		switch (bytes.length & 3) {
			case 3:
				w = bytes.get(i + 2) << 16;
				w |= bytes.get(i + 1) << 8;
				w |= bytes.get(i);
				h = hashMix(h, w);
			case 2:
				w = bytes.get(i + 1) << 8;
				w |= bytes.get(i);
				h = hashMix(h, w);
			case 1:
				h = hashMix(h, bytes.get(i));
			case _:
		}
		h ^= bytes.length;
		var result = hashFinalMix(h) & 0x3fffffff;
		stringHashCache.set(s, result);
		return result;
	}

	static inline function seededIntHash(i:Int):Int {
		return hashFinalMix(hashMix(0, (i << 1) | 1)) & 0x3fffffff;
	}

	static function hashTableBucketCount(size:Int):Int {
		var buckets = 16;
		while (size > buckets * 2) buckets *= 2;
		return buckets;
	}

	// The eval object field order observable through $v{} and Reflect: ascending Ptmap (little-endian
	// patricia) visit order of the field names' string hashes.
	public static function sortNamesPtmap(names:Array<String>):Array<String> {
		names.sort(function(a, b) {
			var d = ptmapOrderKey(seededStringHash(a)) - ptmapOrderKey(seededStringHash(b));
			return d != 0 ? d : Reflect.compare(a, b);
		});
		return names;
	}

	static inline function ptmapOrderKey(k:Int):Int {
		var r = 0;
		for (i in 0...30) r = (r << 1) | ((k >>> i) & 1);
		return r;
	}

	// An object's fields and an instance's come from the same fold over the name map, prepending, so
	// both come out in the same ptmap order, never in declaration order.
	static function ptmapOrderedKeys(keys:Array<Int>):Array<Int> {
		keys.sort(function(a, b) {
			var d = ptmapOrderKey(seededStringHash(EvalHash.revHash(a))) - ptmapOrderKey(seededStringHash(EvalHash.revHash(b)));
			return d != 0 ? d : Reflect.compare(EvalHash.revHash(a), EvalHash.revHash(b));
		});
		return keys;
	}

	static function objectDictionaryKeys(fields:Map<Int, EvalValue>):Array<Int> {
		return ptmapOrderedKeys([for (k in fields.keys()) k]);
	}

	static function isReflectHidden(path:Int, name:Int, isStatic:Bool):Bool {
		if (isStatic) {
			if (path == EvalHash.hash("haxe.Json")) return name == EvalHash.hash("parse") || name == EvalHash.hash("stringify");
			if (path == EvalHash.hash("haxe.format.JsonParser")) return name == EvalHash.hash("parse");
			if (path == EvalHash.hash("haxe.format.JsonPrinter")) return name == EvalHash.hash("print");
			if (path == EvalHash.hash("haxe.Serializer") || path == EvalHash.hash("haxe.Unserializer")) return name == EvalHash.hash("run");
		} else {
			if (path == EvalHash.hash("haxe.Serializer")) return name == EvalHash.hash("serialize") || name == EvalHash.hash("serializeException") || name == EvalHash.hash("serializeFields")
				|| name == EvalHash.hash("serializeRef") || name == EvalHash.hash("serializeString") || name == EvalHash.key_toString;
			if (path == EvalHash.hash("haxe.Unserializer")) return name == EvalHash.hash("unserialize") || name == EvalHash.hash("getResolver") || name == EvalHash.hash("setResolver");
			#if emscripten
			if (path == EvalHash.hash("sys.thread.Semaphore")) return name == EvalHash.hash("acquire") || name == EvalHash.hash("tryAcquire") || name == EvalHash.hash("release");
			if (path == EvalHash.hash("sys.thread.Condition")) return name == EvalHash.hash("acquire") || name == EvalHash.hash("tryAcquire") || name == EvalHash.hash("release") || name == EvalHash.hash("wait") || name == EvalHash.hash("signal") || name == EvalHash.hash("broadcast");
			#end
		}
		return false;
	}

	static function fieldNames(v:EvalValue):Array<String> {
		return switch (v) {
			case VObject(o):
				switch (o.oproto) {
					case OProto(proto): [for (k in instanceFieldKeys(proto)) EvalHash.revHash(k)];
					case ODictionary(l):
						[for (k in objectDictionaryKeys(l)) EvalHash.revHash(k)];
				};
			case VInstance(vi):
				[for (k in instanceFieldKeys(vi.iproto)) EvalHash.revHash(k)];
			case VPrototype(proto): [for (k in sortedFieldKeys(proto.pnames)) if (!isReflectHidden(proto.ppath, k, true)) EvalHash.revHash(k)];
			case VString(_) | VArray(_) | VVector(_): ["length"];
			case _: [];
		};
	}

	// getClassFields folds the static prototype's name map, prepending: the same ptmap order every
	// other fold over a name map gives, never the map's own iteration.
	static function classFieldNames(ctx:EvalContext, proto:VPrototype):Array<EvalValue> {
		var names = new Map<Int, Bool>();
		var keys:Array<Int> = [];
		function add(n:Int):Void {
			if (!names.exists(n) && !isReflectHidden(proto.ppath, n, true)) {
				names.set(n, true);
				keys.push(n);
			}
		}
		for (n in proto.pnames.keys()) add(n);
		switch (ctx.typeCache.get(proto.ppath)) {
			case TClassDecl(c):
				for (cf in c.orderedStatics) {
					if (!TypeFunctions.hasClassFieldFlag(cf, CfGeneric) && !TypeFunctions.hasClassFieldFlag(cf, CfExtern) && TypeFunctions.isPhysicalField(cf))
						add(EvalHash.hash(cf.name));
				}
				for (name in c.statics.keys()) {
					var cf = c.statics.get(name);
					if (!TypeFunctions.hasClassFieldFlag(cf, CfGeneric) && !TypeFunctions.hasClassFieldFlag(cf, CfExtern) && TypeFunctions.isPhysicalField(cf))
						add(EvalHash.hash(cf.name));
				}
			case _:
		}
		return [for (n in ptmapOrderedKeys(keys)) mkStr(EvalHash.revHash(n))];
	}

	// getInstanceFields: every prototype's names up the chain, fields and methods alike, gathered into
	// one map and listed by the fold that prepends, not each prototype in turn with fields before
	// methods.
	static function instanceFieldNames(proto:VPrototype):Array<EvalValue> {
		var names = new Map<Int, Bool>();
		function loop(p:VPrototype):Void {
			if (p.pparent != null) loop(p.pparent);
			for (n in p.pinstanceNames.keys()) names.set(n, true);
			for (n in p.pnames.keys()) if (!isReflectHidden(p.ppath, n, false)) names.set(n, true);
		}
		loop(proto);
		return [for (n in ptmapOrderedKeys([for (k in names.keys()) k])) mkStr(EvalHash.revHash(n))];
	}

	static function objectFieldMap(o:VObject):Map<Int, EvalValue> {
		return switch (o.oproto) {
			case ODictionary(m):
				var out = new Map();
				for (k in m.keys()) out.set(k, m.get(k));
				out;
			case OProto(proto):
				var out = new Map();
				for (k in proto.pinstanceNames.keys()) out.set(k, o.ofields[proto.pinstanceNames.get(k)]);
				out;
		};
	}

	static function setDynamicField(v:EvalValue, name:Int, value:EvalValue):Void {
		switch (EvalValueTools.vresolve(v)) {
			case VObject(o):
				switch (o.oproto) {
					case ODictionary(m):
						if (!m.exists(name)) {
							var order = objectFieldOrders.get(o);
							if (order == null) {
								order = [for (k in m.keys()) k];
								objectFieldOrders.set(o, order);
							}
							order.push(name);
						}
						m.set(name, value);
					case OProto(proto):
						var idx = proto.pinstanceNames.get(name);
						if (idx != null) o.ofields[idx] = value;
						else {
							var m = objectFieldMap(o);
							m.set(name, value);
							o.oproto = ODictionary(m);
							var order = [for (k in proto.pinstanceNames.keys()) k];
							order.push(name);
							objectFieldOrders.set(o, order);
						}
				}
			case VInstance(vi):
				var idx = vi.iproto.pinstanceNames.get(name);
				if (idx != null) vi.ifields[idx] = value;
			case VPrototype(proto):
				var idx = proto.pnames.get(name);
				if (idx != null) proto.pfields[idx] = value;
			case _:
		}
	}

	static function deleteDynamicField(v:EvalValue, name:Int):Bool {
		return switch (EvalValueTools.vresolve(v)) {
			case VObject(o):
				var m = objectFieldMap(o);
				var had = m.exists(name);
				m.remove(name);
				o.oproto = ODictionary(m);
				var order = objectFieldOrders.get(o);
				if (order != null) order.remove(name);
				had;
			case _:
				false;
		};
	}

	// A runtime field set, as Reflect.setField does it: a field that is not there is ignored and a
	// value that is not an object is unexpected. An array only takes `length`, and Bytes resize
	// whatever the name.
	static function reflectSetField(ctx:EvalContext, o:EvalValue, name:Int, v:EvalValue):Void {
		switch (EvalValueTools.vresolve(o)) {
			case VObject(_) | VPrototype(_):
				setDynamicField(o, name, v);
			case VInstance(vi):
				switch (vi.ikind) {
					case IBytes(b):
						var len = switch (v) { case VInt(i): i; case _: EvalExceptions.unexpectedValue(ctx, v, "int"); };
						var b2 = haxe.io.Bytes.alloc(len);
						b2.blit(0, b, 0, len > b.length ? b.length : len);
						vi.ikind = IBytes(b2);
					case _:
						setDynamicField(o, name, v);
				}
			case VArray(va) if (name == EvalHash.hash("length")):
				var len = switch (v) { case VInt(i): i; case _: EvalExceptions.unexpectedValue(ctx, v, "int"); };
				va.alength = len;
				if (len > va.avalues.length) arrayEnsure(va, len * 2);
			case _:
				EvalExceptions.unexpectedValue(ctx, o, "object");
		}
	}

	static function copyValue(v:EvalValue):EvalValue {
		return switch (EvalValueTools.vresolve(v)) {
			case VNull: VNull;
			case VObject(o):
				var copy = new VObject(o.ofields.copy(), o.oproto);
				var order = objectFieldOrders.get(o);
				if (order != null) objectFieldOrders.set(copy, order.copy());
				VObject(copy);
			case VInstance(vi): VInstance(new VInstance(vi.ifields.copy(), vi.iproto, vi.ikind));
			case VArray(va): VArray(new VArray(va.avalues.copy(), va.alength));
			case VVector(vv): VVector(vv.copy());
			case other: other;
		};
	}

	static function hasField(ctx:EvalContext, v:EvalValue, name:Int):Bool {
		return switch (EvalValueTools.vresolve(v)) {
			case VObject(o):
				switch (o.oproto) {
					case OProto(proto): proto.pinstanceNames.exists(name);
					case ODictionary(m): m.exists(name);
				}
			case VInstance(vi):
				if (isReflectHidden(vi.iproto.ppath, name, false)) false else if (vi.iproto.pinstanceNames.exists(name)) true else {
					var p = vi.iproto;
					var found = false;
					while (p != null && !found) {
						found = p.pnames.exists(name) && !isReflectHidden(p.ppath, name, false);
						p = p.pparent;
					}
					found;
				}
			case VPrototype(proto):
				var p = proto;
				var found = false;
				while (p != null && !found) {
					found = p.pnames.exists(name) && !isReflectHidden(p.ppath, name, true);
					p = p.pparent;
				}
				found;
			case VString(_): name == EvalHash.keyLength || (ctx.stringPrototype != null && hasProtoField(ctx.stringPrototype, name));
			case VArray(_): name == EvalHash.keyLength || (ctx.arrayPrototype != null && hasProtoField(ctx.arrayPrototype, name));
			case VVector(_): name == EvalHash.keyLength || (ctx.vectorPrototype != null && hasProtoField(ctx.vectorPrototype, name));
			case _: false;
		};
	}

	static function hasProtoField(proto:VPrototype, name:Int):Bool {
		var p = proto;
		while (p != null) {
			if (p.pnames.exists(name)) return true;
			p = p.pparent;
		}
		return false;
	}

	static function callValueOn(recv:EvalValue, fn:EvalValue, args:Array<EvalValue>):EvalValue {
		return switch (EvalValueTools.vresolve(fn)) {
			case VFunction(f, isStatic): isStatic ? f(args) : f([recv].concat(args));
			case VFieldClosure(recv2, f): f([recv2].concat(args));
			// A callback that is not a function is "Cannot call <value>", the macro's uncaught exception
			// with
			// no position of its own.
			case v: EvalExceptions.excValues(EvalContext.getCtx(), ["Cannot call ", ""], [v]);
		};
	}

	static function compareMethodsValue(a:EvalValue, b:EvalValue):Bool {
		return switch [EvalValueTools.vresolve(a), EvalValueTools.vresolve(b)] {
			case [VFunction(f1, _), VFunction(f2, _)]: Reflect.compareMethods(f1, f2);
			case [VFieldClosure(v1, f1), VFieldClosure(v2, f2)]:
				Reflect.compareMethods(f1, f2) && EvalMisc.compare(v1, v2) == CEq;
			case _: false;
		};
	}

	static function enumEqValue(a:EvalValue, b:EvalValue):Bool {
		return switch [EvalValueTools.vresolve(a), EvalValueTools.vresolve(b)] {
			case [VEnumValue(ae), VEnumValue(be)]:
				if (ae == be) true;
				else if (ae.eindex != be.eindex || ae.epath != be.epath || ae.eargs.length != be.eargs.length) false;
				else {
					var ok = true;
					for (i in 0...ae.eargs.length) {
						if (!enumEqValue(ae.eargs[i], be.eargs[i])) {
							ok = false;
							break;
						}
					}
					ok;
				}
			case [av, bv]: EvalValueTools.equals(av, bv);
		};
	}

	static function classValue(ctx:EvalContext, path:Int):EvalValue {
		var p = ctx.staticPrototypes.get(path);
		return p == null ? VNull : p.pvalue;
	}

	static function coreClassValue(ctx:EvalContext, path:Int):EvalValue {
		var p = ctx.staticPrototypes.get(path);
		if (p == null) {
			p = new VPrototype(path, [], new Map(), [], new Map(), null, PClass([]), VNull);
			p.pvalue = VPrototype(p);
			ctx.staticPrototypes.set(path, p);
		}
		return p.pvalue;
	}

	static function coreInstancePrototype(ctx:EvalContext, path:Int):VPrototype {
		var p = ctx.instancePrototypes.get(path);
		if (p == null) {
			p = new VPrototype(path, [], new Map(), [], new Map(), null, PInstance, VNull);
			ctx.instancePrototypes.set(path, p);
		}
		return p;
	}

	static function isCoreClassPath(path:Int):Bool {
		return path == EvalHash.key_Int || path == EvalHash.key_Float || path == EvalHash.key_Bool
			|| path == EvalHash.key_Dynamic || path == EvalHash.key_Class || path == EvalHash.key_Enum;
	}

	// Type.createEnum: the constructor is the field of that name (none for a value without fields);
	// an enum value is taken with no or empty arguments and a function is called with them, and
	// anything else is unexpected arguments.
	static function createEnumByName(ctx:EvalContext, e:EvalValue, name:Int, params:EvalValue):EvalValue {
		var f = EvalField.field(ctx, e, name);
		return switch [f, params] {
			case [VEnumValue(_), VNull]: f;
			case [VEnumValue(_), VArray(va)] if (va.alength == 0): f;
			case [VFunction(fn, _), VArray(va)]: fn(va.avalues.slice(0, va.alength));
			case _: unexpectedEnumParams(ctx, params);
		};
	}

	static function unexpectedEnumParams(ctx:EvalContext, params:EvalValue):Dynamic {
		return switch (params) {
			case VArray(_): EvalExceptions.excValues(ctx, ["Unexpected value VArray(", "), expected array"], [params]);
			case _: EvalExceptions.unexpectedValue(ctx, params, "array");
		};
	}

	static function ioError(ctx:EvalContext, name:String):Dynamic {
		EvalExceptions.throwValue(ctx, createEnumByName(ctx, classValue(ctx, EvalHash.hash("haxe.io.Error")), EvalHash.hash(name), VNull), Position.nullPos);
		return VNull;
	}

	static function argList(v:EvalValue):Array<EvalValue> {
		return switch (v) {
			case VArray(va): va.avalues.slice(0, va.alength);
			case _: [];
		};
	}

	static function iterableValues(ctx:EvalContext, v:EvalValue):Array<EvalValue> {
		switch (EvalValueTools.vresolve(v)) {
			case VArray(va):
				return va.avalues.slice(0, va.alength);
			case VVector(vv):
				return vv.copy();
			case _:
		}
		var it = applyFn(EvalField.dynamicField(ctx, v, EvalHash.hash("iterator")), []);
		var values:Array<EvalValue> = [];
		while (EvalMisc.isTrue(callValueOn(it, EvalField.dynamicField(ctx, it, EvalHash.hash("hasNext")), []))) {
			values.push(callValueOn(it, EvalField.dynamicField(ctx, it, EvalHash.hash("next")), []));
		}
		return values;
	}

	static function valueArray(values:Array<EvalValue>):EvalValue {
		return VArray(new VArray(values, values.length));
	}

	static function thisBuffer(a:Array<EvalValue>):VStringBuffer {
		return switch (a[0]) {
			case VInstance(vi): switch (vi.ikind) {
				case IBuffer(b): b;
				case _:
					// A subclass of the native-backed StringBuf constructs through its own typed
					// constructor, so the native buffer attaches on first use and every native call
					// on the instance shares it.
					var b = new VStringBuffer();
					vi.ikind = IBuffer(b);
					b;
			};
			case _: new VStringBuffer();
		};
	}

	// haxe.Utf8's receiver: an IUtf8 instance, anything else unexpected.
	static function thisUtf8(ctx:EvalContext, a:Array<EvalValue>):ByteBuffer {
		return switch (a[0]) {
			case VInstance({ikind: IUtf8(b)}): b;
			case v: EvalExceptions.unexpectedValue(ctx, v, "string");
		};
	}

	// EReg's receiver: a value that is not a regex is unexpected.
	static function thisRegex(a:Array<EvalValue>):EvalRegex {
		return switch (a[0]) {
			case VInstance({ikind: IRegex(r)}): r;
			case v: EvalExceptions.unexpectedValue(EvalContext.getCtx(), v, "EReg");
		};
	}

	// An array's elements; anything else is unexpected.
	static function decodeArray(ctx:EvalContext, v:EvalValue):Array<EvalValue> {
		return switch (v) {
			case VArray(va): va.avalues.slice(0, va.alength);
			case _: EvalExceptions.unexpectedValue(ctx, v, "array");
		};
	}

	// A new EReg: the options in order (an unknown one fails), the pattern compiled with UTF and UCP
	// (a compile error fails with its own wording), and `~/pattern/options` kept for printing.
	static function regexCreate(r:ByteString, opt:ByteString):EvalRegex {
		var global = false;
		var flags = 0;
		for (i in 0...opt.length) {
			switch (opt.get(i)) {
				case "i".code: flags |= (Pcre2Flag.CASELESS : Int);
				case "s".code: flags |= (Pcre2Flag.DOTALL : Int);
				case "m".code: flags |= (Pcre2Flag.MULTILINE : Int);
				case "u".code:
				case "g".code: global = true;
				case c: throw new hxc.eval.EvalExceptions.HostException("Unsupported regexp option '" + String.fromCharCode(c) + "'", true);
			}
		}
		flags |= (Pcre2Flag.UTF : Int) | (Pcre2Flag.UCP : Int);
		var rex = try Pcre2.compile(flags, r) catch (e:hxc.eval.Pcre2.Pcre2Exception) {
			throw new hxc.eval.EvalExceptions.HostException(regexErrorString(e.error), true);
		};
		return new EvalRegex(rex, ByteString.ofRaw("~/" + r.raw() + "/" + opt.raw()), global);
	}

	// The message for a PCRE error.
	static function regexErrorString(e:hxc.eval.Pcre2.Pcre2Error):String {
		return switch (e) {
			case BadPattern(s, i): "at " + i + ": " + s;
			case Partial: "Partial";
			case BadUTF: "BadUTF";
			case BadUTFOffset: "BadUTFOffset";
			case MatchLimit: "MatchLimit";
			case DepthLimit: "DepthLimit";
			case WorkspaceSize: "WorkspaceSize";
			case InternalError(s): "InternalError: " + s;
		};
	}

	// An EReg made without its constructor holds the empty pattern, no options.
	static function regexEmpty():EvalRegex {
		return new EvalRegex(Pcre2.compile(0, ByteString.empty), ByteString.ofRaw("~//"), false);
	}

	// Before a group is read: no match made, then a group the pattern does not have, then a group
	// that did not take part (null).
	static function regexMaybeRun(ctx:EvalContext, re:EvalRegex, n:Int, f:(Int, Int) -> EvalValue):EvalValue {
		if (re.rGroups.length == 0) return EvalExceptions.excString(ctx, "Invalid regex operation because no match was made");
		var ss = re.rGroups[0];
		if (n < 0 || n >= ss.numOfSubs()) return EvalExceptions.excString(ctx, "Invalid group");
		var o = try ss.getSubstringOfs(n) catch (_:hxc.eval.Pcre2.Pcre2NotFound) return VNull;
		return f(o.first, o.last);
	}

	// Both ends clipped to the string, nothing where they cross.
	static function regexSlice(s:ByteString, first:Null<Int>, last:Null<Int>):ByteString {
		var len = s.length;
		function clip(x:Int):Int return x < 0 ? 0 : (x > len ? len : x);
		var i = clip(first == null ? 0 : (first < 0 ? len + first : first));
		var j = clip(last == null ? len : (last < 0 ? len + last : last));
		return (i >= j || i == len) ? ByteString.empty : s.sub(i, j - i);
	}

	// Quote a pattern: a backslash before each of `[ ] * . \ ? + ^ $`.
	static function regexQuote(s:ByteString):ByteString {
		var buf = new ByteBuffer();
		for (i in 0...s.length) {
			var c = s.get(i);
			switch (c) {
				case "[".code | "]".code | "*".code | ".".code | "\\".code | "?".code | "+".code | "^".code | "$".code:
					buf.addByte("\\".code);
				case _:
			}
			buf.addByte(c);
		}
		return buf.contents();
	}

	static function thisMap(a:Array<EvalValue>):Map<String, MapEntry> {
		return switch (a[0]) {
			case VInstance(vi): switch (vi.ikind) { case IMap(m): m; case _: new Map(); };
			case _: new Map();
		};
	}

	static inline var bytesBufferLengthKey = "__bytes_length";

	static inline function bytesBufferByteKey(index:Int):String return "b:" + index;

	static function bytesBufferLength(buf:Map<String, MapEntry>):Int {
		var e = buf.get(bytesBufferLengthKey);
		return e == null ? 0 : toInt(e.value);
	}

	static function bytesBufferSet(buf:Map<String, MapEntry>, key:String, value:EvalValue):Void {
		buf.set(key, {key: mkStr(key), value: value});
	}

	static function bytesBufferSetLength(buf:Map<String, MapEntry>, length:Int):Void {
		bytesBufferSet(buf, bytesBufferLengthKey, VInt(length));
	}

	static function bytesBufferAddByte(buf:Map<String, MapEntry>, byte:Int):Void {
		var length = bytesBufferLength(buf);
		bytesBufferSet(buf, bytesBufferByteKey(length), VInt(byte & 0xFF));
		bytesBufferSetLength(buf, length + 1);
	}

	static function bytesBufferAddBytes(buf:Map<String, MapEntry>, bytes:haxe.io.Bytes, pos:Int, len:Int):Void {
		if (pos < 0 || len < 0 || pos + len > bytes.length) throw "Outside bounds";
		for (i in pos...pos + len) bytesBufferAddByte(buf, bytes.get(i));
	}

	static function bytesBufferToBytes(buf:Map<String, MapEntry>):haxe.io.Bytes {
		var length = bytesBufferLength(buf);
		var bytes = haxe.io.Bytes.alloc(length);
		for (i in 0...length) {
			var e = buf.get(bytesBufferByteKey(i));
			bytes.set(i, e == null ? 0 : toInt(e.value));
		}
		return bytes;
	}

	static function bytesOfFloat(v:Float):haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(4);
		b.setFloat(0, v);
		return b;
	}

	// One byte at a time: false at the first byte off the end, the bytes before it written.
	static function writeBytesOrFail(b:haxe.io.Bytes, pos:Int, bits:haxe.io.Bytes):Bool {
		for (i in 0...bits.length) {
			var at = pos + i;
			if (at < 0 || at >= b.length) return false;
			b.set(at, bits.get(i));
		}
		return true;
	}

	static function int32Bytes(v:Int):haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(4);
		b.setInt32(0, v);
		return b;
	}

	static function bytesOfDouble(v:Float):haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(8);
		b.setDouble(0, v);
		return b;
	}

	static function floatBits(v:Float):Int {
		return bytesOfFloat(v).getInt32(0);
	}

	static function doubleBits(ctx:EvalContext, v:Float):EvalValue {
		var b = bytesOfDouble(v);
		return encodeHaxeI64(ctx, b.getInt32(0), b.getInt32(4));
	}

	static function floatOfBits(v:Int):Float {
		var b = haxe.io.Bytes.alloc(4);
		b.setInt32(0, v);
		return b.getFloat(0);
	}

	static function doubleOfBits(low:Int, high:Int):Float {
		var b = haxe.io.Bytes.alloc(8);
		b.setInt32(0, low);
		b.setInt32(4, high);
		return b.getDouble(0);
	}

	// Stable per-object identity for ObjectMap keys, assigned lazily on first use.
	static var objIds = new haxe.ds.ObjectMap<{}, Int>();
	static var objIdNext = 0;
	static var zipCompress = new haxe.ds.ObjectMap<VInstance, haxe.zip.Compress>();
	static var zipUncompress = new haxe.ds.ObjectMap<VInstance, haxe.zip.Uncompress>();
	static var cryptoHmacs = new haxe.ds.ObjectMap<VInstance, haxe.crypto.Hmac>();
	static var cryptoBaseCodes = new haxe.ds.ObjectMap<VInstance, haxe.crypto.BaseCode>();
	static var nativeTemplates = new haxe.ds.ObjectMap<VInstance, haxe.Template>();
	static var nativeSockets = new haxe.ds.ObjectMap<VInstance, sys.net.Socket>();
	static var fileInputs = new haxe.ds.ObjectMap<VInstance, {input:haxe.io.Input, file:Null<sys.io.FileInput>, eof:Bool, closed:Bool, base:Int, maxPos:Int, read:Bool, closedOffset:Int}>();
	static var fileOutputs = new haxe.ds.ObjectMap<VInstance, {output:haxe.io.Output, file:Null<sys.io.FileOutput>, closed:Bool, closedPos:Int}>();
	static var nativeBytesOutputs = new haxe.ds.ObjectMap<VInstance, Map<String, MapEntry>>();
	// A subclass instance whose super constructor is a native builtin (new StringInput -> super ->
	// BytesInput's builtin) delegates its native state to the instance the builtin constructed.
	public static var superDelegates = new haxe.ds.ObjectMap<VInstance, VInstance>();

	static var nativeBytesInputs = new haxe.ds.ObjectMap<VInstance, {bytes:haxe.io.Bytes, pos:Int, len:Int, totlen:Int}>();
	static var nativeProcesses = new haxe.ds.ObjectMap<VInstance, sys.io.Process>();
	static var nativeLists = new haxe.ds.ObjectMap<VInstance, Array<EvalValue>>();
	static var nativeMapOrders = new haxe.ds.ObjectMap<VInstance, Array<String>>();
	static var threadMutexes = new haxe.ds.ObjectMap<VInstance, {mutex:sys.thread.Mutex, owner:Null<sys.thread.Thread>, count:Int}>();
	static var threadLocks = new haxe.ds.ObjectMap<VInstance, sys.thread.Lock>();
	static var threadTls = new haxe.ds.ObjectMap<VInstance, sys.thread.Tls<EvalValue>>();
	static var threadDeques = new haxe.ds.ObjectMap<VInstance, sys.thread.Deque<EvalValue>>();
	static var threadConditions = new haxe.ds.ObjectMap<VInstance, ThreadConditionState>();
	static var threadSemaphores = new haxe.ds.ObjectMap<VInstance, sys.thread.Semaphore>();
	static var threadEventHandlers = new Map<Int, Dynamic>();
	static var threadEventHandlerNextId = 1;
	// The global interpreter lock: interpreted code runs one thread at a time; blocking natives
	// release it around the OS wait so other interpreter threads can run.
	public static var gil:sys.thread.Mutex = new sys.thread.Mutex();
	// Releasing an UNHELD lock is undefined behavior on the host, so each thread
	// tracks whether it holds the lock; a blocking native on a non-holding thread
	// just runs.
	static var gilHeldTls:sys.thread.Tls<Bool> = new sys.thread.Tls();

	public static function gilEnter():Void {
		gil.acquire();
		gilHeldTls.value = true;
	}

	public static function gilLeave():Void {
		gilHeldTls.value = false;
		gil.release();
	}

	// Runs a blocking native outside the interpreter lock.
	static function gilBlocking(f:Void->EvalValue):EvalValue {
		if (gilHeldTls.value != true) return f();
		gilHeldTls.value = false;
		gil.release();
		var r = try f() catch (e:Dynamic) { gil.acquire(); gilHeldTls.value = true; throw e; };
		gil.acquire();
		gilHeldTls.value = true;
		return r;
	}

	// A blocking libuv call (hxc.eval.Luv) lets go of the lock, answering whether this thread held
	// it; gilReacquire takes it back.
	public static function gilRelease():Bool {
		if (gilHeldTls.value != true) return false;
		gilHeldTls.value = false;
		gil.release();
		return true;
	}

	public static function gilReacquire():Void {
		gil.acquire();
		gilHeldTls.value = true;
	}

	// A wait outside the interpreter lock, for a native that answers a host value.
	static function released<T>(f:Void->T):T {
		if (gilHeldTls.value != true) return f();
		gilHeldTls.value = false;
		gil.release();
		var r = try f() catch (e:Dynamic) { gil.acquire(); gilHeldTls.value = true; throw e; };
		gil.acquire();
		gilHeldTls.value = true;
		return r;
	}

	// A yield on Windows always lets the lock go, since the lock keeps no count of its waiters:
	// LeaveCriticalSection, Sleep(0), EnterCriticalSection.
	public static function gilYield():Void {
		if (gilHeldTls.value != true) return;
		gilLeave();
		hxc.compiler.HostRuntime.sleepZero();
		gilEnter();
	}

	// Preemption: the tick's signal, taken at a poll by the thread holding the lock, is a
	// Thread.yield.
	public static function preemptPoll():Void {
		if (gilHeldTls.value != true) return;
		hxc.compiler.HostRuntime.preemptClear();
		gilYield();
	}

	static var evalContext:Null<EvalContext> = null;
	static var nativeXml = new haxe.ds.ObjectMap<VInstance, Xml>();
	static var nativeXmlValues = new haxe.ds.ObjectMap<Xml, VInstance>();
	static var objectFieldOrders = new haxe.ds.ObjectMap<VObject, Array<Int>>();
	static var stringHashCache = new Map<String, Int>();
	static var macroMessages:Array<EvalValue> = [];

	static function objId(o:{}):Int {
		if (objIds.exists(o)) return objIds.get(o);
		var id = objIdNext++;
		objIds.set(o, id);
		return id;
	}

	// A string is `y`, the url-encoded bytes' length, `:` and those bytes.
	static function serializeStringTag(s:ByteString, buf:StringBuf):Void {
		var e = urlEncode(s);
		buf.add("y");
		buf.add(e.length);
		buf.add(":");
		buf.add(e.raw());
	}

	static function serializeEval(ctx:EvalContext, value:EvalValue, useEnumIndex:Bool, useCache:Bool, forSignature:Bool = false):String {
		var buf = new StringBuf();
		var cache:Array<EvalValue> = [];
		var customCount = 0;
		var shash = new Map<String, Int>();
		var scount = 0;
		function stringTag(s:ByteString):Void {
			var idx = shash.get(s.raw());
			if (idx != null) {
				buf.add("R");
				buf.add(idx);
				return;
			}
			shash.set(s.raw(), scount++);
			serializeStringTag(s, buf);
		}
		function sameCacheValue(a:EvalValue, b:EvalValue):Bool {
			return switch [EvalValueTools.vresolve(a), EvalValueTools.vresolve(b)] {
				case [VArray(aa), VArray(ba)]: aa == ba;
				case [VObject(ao), VObject(bo)]: ao == bo;
				case [VInstance(ai), VInstance(bi)]: ai == bi;
				case [VEnumValue(ae), VEnumValue(be)]: ae == be;
				case [VPrototype(ap), VPrototype(bp)]: ap == bp;
				case [VFunction(af, _), VFunction(bf, _)]: Reflect.compareMethods(af, bf);
				case _: false;
			}
		}
		function serializeRef(v:EvalValue):Bool {
			for (i in 0...cache.length) {
				if (sameCacheValue(cache[i], v)) {
					buf.add("r");
					buf.add(i);
					return true;
				}
			}
			cache.push(v);
			return false;
		}
		function loop(v:EvalValue):Void {
			switch (EvalValueTools.vresolve(v)) {
				case VNull:
					buf.add("n");
				case VTrue:
					buf.add("t");
				case VFalse:
					buf.add("f");
				case VInt(i):
					if (i == 0) buf.add("z") else {
						buf.add("i");
						buf.add(i);
					}
				case VFloat(f):
					if (Math.isNaN(f)) buf.add("k") else if (!Math.isFinite(f)) buf.add(f < 0 ? "m" : "p") else {
						buf.add("d");
						buf.add(floatString(f));
					}
				case VString(s):
					stringTag(s.sstring);
				// A native string's bytes as they are, untagged.
				case VNativeString(s):
					buf.add(s.raw());
				case VInt64(b):
					buf.add("i64");
					buf.add(EvalIntegers.int64ToString(b.v));
				case VUInt64(b):
					buf.add("u64");
					buf.add(EvalIntegers.uint64ToString(b.v));
				case VArray(va):
					if (useCache && serializeRef(VArray(va))) return;
					buf.add("a");
					for (i in 0...va.alength) loop(va.avalues[i]);
					buf.add("h");
				case VVector(vv):
					buf.add("a");
					for (item in vv) loop(item);
					buf.add("h");
				case VObject(o):
					if (useCache && serializeRef(VObject(o))) return;
					buf.add("o");
					for (name in fieldNames(VObject(o))) {
						stringTag(ByteString.ofText(name));
						loop(EvalField.field(ctx, VObject(o), EvalHash.hash(name)));
					}
					buf.add("g");
				case VInstance(vi):
					if (useCache && serializeRef(VInstance(vi))) return;
					switch (vi.ikind) {
						case IDate(ts):
							buf.add("v");
							buf.add(ts);
						case IBytes(b):
							buf.add(haxe.Serializer.run(b));
						case IMap(m):
							// Each table iterates in the reverse of its keys' (folded) order.
							var entries = orderedMapEntries(VInstance(vi));
							entries.reverse();
							switch (EvalHash.revHash(vi.iproto.ppath)) {
								case "haxe.ds.StringMap":
									buf.add("b");
									for (entry in entries) {
										stringTag(valueString(entry.key));
										loop(entry.value);
									}
									buf.add("h");
								case "haxe.ds.IntMap":
									buf.add("q");
									for (entry in entries) {
										buf.add(":");
										buf.add(toInt(entry.key));
										loop(entry.value);
									}
									buf.add("h");
								case "haxe.ds.ObjectMap":
									buf.add("M");
									for (entry in entries) {
										loop(entry.key);
										loop(entry.value);
									}
									buf.add("h");
								case _:
									buf.add("o");
									for (entry in m) {
										stringTag(valueString(entry.key));
										loop(entry.value);
									}
									buf.add("g");
							}
						case _:
							if (vi.iproto.ppath == EvalHash.hash("haxe.ds.List")) {
								buf.add("l");
								for (item in iterableValues(ctx, VInstance(vi))) loop(item);
								buf.add("h");
							} else {
								buf.add("c");
								stringTag(ByteString.ofText(EvalHash.revHash(vi.iproto.ppath)));
								for (name in fieldNames(VInstance(vi))) {
									stringTag(ByteString.ofText(name));
									loop(EvalField.field(ctx, VInstance(vi), EvalHash.hash(name)));
								}
								buf.add("g");
							}
					}
				case VEnumValue(ev):
					if (useCache && serializeRef(VEnumValue(ev))) return;
					buf.add(useEnumIndex ? "j" : "w");
					stringTag(ByteString.ofText(EvalHash.revHash(ev.epath)));
					if (useEnumIndex) {
						buf.add(":");
						buf.add(ev.eindex);
					} else {
						stringTag(ByteString.ofText(enumConstructorName(ev)));
					}
					buf.add(":");
					buf.add(ev.eargs.length);
					for (arg in ev.eargs) loop(arg);
				case VPrototype(proto):
					switch (proto.pkind) {
						case PEnum(_):
							buf.add("B");
						case _:
							buf.add("A");
					}
					stringTag(ByteString.ofText(EvalHash.revHash(proto.ppath)));
				case VFunction(_, _) | VFieldClosure(_, _) | VHandle(_):
					// A function is a custom entity, 'F' and a running count, and so is a handle (also
					// written 'F').
					// The cache entry a custom entity takes is the TOP-LEVEL value being serialized, not
					// the function:
					// the first custom entity in a value registers that top-level value and every later one
					// finds it
					// and prints 'r<index>'. Caching the function itself would give a second F where a
					// back-reference
					// belongs.
					if (!forSignature) EvalExceptions.excString(ctx, "Cannot serialize function")
					else if (!serializeRef(value)) { buf.add("F"); buf.add(customCount++); }
				case VLazy(_):
					EvalExceptions.excString(ctx, "unreachable");
			}
		}
		loop(value);
		return buf.toString();
	}

	static function thisDate(a:Array<EvalValue>):Float {
		return switch (a[0]) {
			case VInstance(vi): switch (vi.ikind) { case IDate(ts): ts; case _: 0.0; };
			case _: 0.0;
		};
	}

	static function mkDate(ctx:EvalContext, ts:Float):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("Date"));
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IDate(ts)));
	}

	static function dateFromString(ctx:EvalContext, s:String):EvalValue {
		function bad():EvalValue return EvalExceptions.excString(ctx, "Invalid date format : " + s);
		function digits(pos:Int, len:Int):Bool {
			for (i in pos...pos + len) {
				var c = s.charCodeAt(i);
				if (c < "0".code || c > "9".code) return false;
			}
			return true;
		}
		function part(pos:Int, len:Int):Int return Std.parseInt(s.substr(pos, len));
		return switch (s.length) {
			// A mktime failure is a Unix error.
			case 19 if (digits(0, 4) && s.charAt(4) == "-" && digits(5, 2) && s.charAt(7) == "-" && digits(8, 2) && s.charAt(10) == " " && digits(11, 2) && s.charAt(13) == ":" && digits(14, 2) && s.charAt(16) == ":" && digits(17, 2)):
				mkDate(ctx, unixMktime(ctx, part(0, 4), part(5, 2) - 1, part(8, 2), part(11, 2), part(14, 2), part(17, 2)) * 1000);
			case 10 if (digits(0, 4) && s.charAt(4) == "-" && digits(5, 2) && s.charAt(7) == "-" && digits(8, 2)):
				mkDate(ctx, unixMktime(ctx, part(0, 4), part(5, 2) - 1, part(8, 2), 0, 0, 0) * 1000);
			case 8 if (digits(0, 2) && s.charAt(2) == ":" && digits(3, 2) && s.charAt(5) == ":" && digits(6, 2)):
				mkDate(ctx, ((part(0, 2) * 60 * 60) + (part(3, 2) * 60) + part(6, 2)) * 1000.0);
			case _:
				bad();
		}
	}

	static final dateDayShortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
	static final dateDayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
	static final dateMonthShortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
	static final dateMonthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

	// A Bytes or nothing; a null is a Null Access, anything else an Unexpected value, both the macro's
	// uncaught exceptions rather than an empty buffer. A receiver that is not Bytes is unexpected.
	static function thisBytes(a:Array<EvalValue>):haxe.io.Bytes {
		return switch (EvalValueTools.vresolve(a[0])) {
			case VInstance({ikind: IBytes(b)}): b;
			case v: EvalExceptions.unexpectedValue(EvalContext.getCtx(), v, "bytes");
		};
	}

	// An argument that is not Bytes is unexpected, expected "string".
	static function decodeBytes(v:EvalValue):haxe.io.Bytes {
		return switch (EvalValueTools.vresolve(v)) {
			case VInstance({ikind: IBytes(b)}): b;
			case v: EvalExceptions.unexpectedValue(EvalContext.getCtx(), v, "string");
		};
	}

	// An Int, or a float through a C conversion to 32 bits (NaN and anything out of range come out
	// as the minimum Int); anything else is unexpected.
	public static function decodeI32(ctx:EvalContext, v:EvalValue):Int {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f): Math.isNaN(f) || !(f > -2147483649.0 && f < 2147483648.0) ? 0x80000000 : Std.int(f);
			case _: EvalExceptions.unexpectedValue(ctx, v, "int");
		};
	}

	// A native's catch-all handler: any failure inside, a decode included, is
	// haxe.io.Error.OutsideBounds. `f` answers null for an access out of range.
	static function orOutsideBounds(ctx:EvalContext, f:Void->Null<EvalValue>):EvalValue {
		var r:Null<EvalValue> = try f() catch (_:Dynamic) null;
		return r == null ? ioError(ctx, "OutsideBounds") : r;
	}

	// A haxe Int64: an instance of haxe._Int64.___Int64 made without running its constructor, with
	// high and low set (NotFound if the class has no such field).
	static function encodeHaxeI64(ctx:EvalContext, low:Int, high:Int):EvalValue {
		var proto = EvalContext.getInstancePrototype(ctx, EvalHash.hash("haxe._Int64.___Int64"), Position.nullPos);
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		var hi = proto.pinstanceNames.get(EvalHash.keyHigh);
		var lo = proto.pinstanceNames.get(EvalHash.keyLow);
		if (hi == null || lo == null) throw new hxc.eval.EvalExceptions.HostException("Not_found");
		vi.ifields[hi] = VInt(high);
		vi.ifields[lo] = VInt(low);
		return VInstance(vi);
	}

	// An instance's field: NotFound if it has no such field.
	static function instanceFieldRaise(ctx:EvalContext, v:EvalValue, name:Int):EvalValue {
		var vi = switch (v) {
			case VInstance(vi): vi;
			case _: EvalExceptions.unexpectedValue(ctx, v, "instance");
		};
		var idx = vi.iproto.pinstanceNames.get(name);
		if (idx == null) throw new hxc.eval.EvalExceptions.HostException("Not_found");
		return vi.ifields[idx];
	}

	static function mkBytes(ctx:EvalContext, b:haxe.io.Bytes):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.io.Bytes"));
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IBytes(b)));
	}

	static function mkFileInput(ctx:EvalContext, input:sys.io.FileInput):EvalValue {
		return mkInput(ctx, input, input);
	}

	static function mkInput(ctx:EvalContext, input:haxe.io.Input, file:Null<sys.io.FileInput>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.io.FileInput"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		fileInputs.set(vi, {input: input, file: file, eof: false, closed: false, base: 0, maxPos: 0, read: false, closedOffset: 0});
		return VInstance(vi);
	}

	static function mkFileOutput(ctx:EvalContext, output:sys.io.FileOutput):EvalValue {
		return mkOutput(ctx, output, output);
	}

	static function mkOutput(ctx:EvalContext, output:haxe.io.Output, file:Null<sys.io.FileOutput>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.io.FileOutput"));
		var com = ctx.com != null ? ctx.com : hxc.eval.EvalMacro.getMacroCom();
		if (com == null) com = hxc.eval.EvalMacro.hostCom;
		if ((proto == null || proto.pparent == null) && com != null) try {
			var out = hxc.context.ModuleLoader.loadModule(com, {pack: ["haxe", "io"], name: "Output"}, Position.nullPos);
			var m = hxc.context.ModuleLoader.loadModule(com, {pack: ["sys", "io"], name: "FileOutput"}, Position.nullPos);
			hxc.typing.TypeResolve.resolveAll(com);
			hxc.typing.TypeFields.installLazy(com);
			EvalMain.addModules(ctx, [out, m]);
			proto = ctx.instancePrototypes.get(EvalHash.hash("sys.io.FileOutput"));
			var outputProto = ctx.instancePrototypes.get(EvalHash.hash("haxe.io.Output"));
			if (proto != null && proto.pparent == null) proto.pparent = outputProto;
		} catch (_:Dynamic) {}
		if (proto == null) {
			proto = new VPrototype(EvalHash.hash("sys.io.FileOutput"), [], new Map(), [], new Map(), null, PClass([]), VNull);
			ctx.instancePrototypes.set(EvalHash.hash("sys.io.FileOutput"), proto);
		}
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		fileOutputs.set(vi, {output: output, file: file, closed: false, closedPos: 0});
		return VInstance(vi);
	}

	// The furthest position a read reached since the channel was opened or last seeked, which is
	// what bounds the channel buffer's refills.
	static function noteRead(ch:{input:haxe.io.Input, file:Null<sys.io.FileInput>, eof:Bool, closed:Bool, base:Int, maxPos:Int, read:Bool, closedOffset:Int}):Void {
		if (ch.file == null) return;
		var p = try ch.file.tell() catch (_:Dynamic) return;
		ch.read = true;
		if (p > ch.maxPos) ch.maxPos = p;
	}

	// A write or seek on a closed output channel flushes into fd -1.
	static function openFileOutput(a:Array<EvalValue>):{output:haxe.io.Output, file:Null<sys.io.FileOutput>, closed:Bool, closedPos:Int} {
		var out = thisFileOutput(a);
		if (out.closed) throw new hxc.eval.EvalExceptions.HostException('Sys_error("Bad file descriptor")');
		return out;
	}

	static function thisFileInput(a:Array<EvalValue>):{input:haxe.io.Input, file:Null<sys.io.FileInput>, eof:Bool, closed:Bool, base:Int, maxPos:Int, read:Bool, closedOffset:Int} {
		return fileInputs.get(thisInstance(a, "FileInput"));
	}

	static function thisFileOutput(a:Array<EvalValue>):{output:haxe.io.Output, file:Null<sys.io.FileOutput>, closed:Bool, closedPos:Int} {
		return fileOutputs.get(thisInstance(a, "FileOutput"));
	}

	static function mkNativeProcess(ctx:EvalContext, proc:sys.io.Process):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.io._Process.NativeProcess"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		nativeProcesses.set(vi, proc);
		return VInstance(vi);
	}

	static function thisProcess(a:Array<EvalValue>):sys.io.Process {
		return nativeProcesses.get(thisInstance(a, "NativeProcess"));
	}

	static function mkList(ctx:EvalContext, ?items:Array<EvalValue>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.ds.List"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		var list = items == null ? [] : items.copy();
		nativeLists.set(vi, list);
		syncListFields(ctx, vi);
		return VInstance(vi);
	}

	static function listNodeValue(ctx:EvalContext, item:EvalValue, next:EvalValue):EvalValue {
		var node = EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.ds._List.ListNode"), [item, next]);
		return node == VNull ? mkObject([{name: "item", value: item}, {name: "next", value: next}]) : node;
	}

	static function syncListFields(ctx:EvalContext, vi:VInstance):Void {
		var list = nativeLists.get(vi);
		if (list == null) return;
		var head:EvalValue = VNull;
		var tail:EvalValue = VNull;
		for (offset in 0...list.length) {
			var node = listNodeValue(ctx, list[list.length - 1 - offset], head);
			if (tail == VNull) tail = node;
			head = node;
		}
		setInstanceFieldIfExists(vi, "h", head);
		setInstanceFieldIfExists(vi, "q", tail);
		setInstanceFieldIfExists(vi, "length", VInt(list.length));
	}

	static function mkThreadMutex(ctx:EvalContext):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.thread.Mutex"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		threadMutexes.set(vi, {mutex: new sys.thread.Mutex(), owner: null, count: 0});
		return VInstance(vi);
	}

	static function thisThreadMutex(a:Array<EvalValue>):{mutex:sys.thread.Mutex, owner:Null<sys.thread.Thread>, count:Int} {
		return threadMutexes.get(thisInstance(a, "Mutex"));
	}

	static function mkThreadLock(ctx:EvalContext):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.thread.Lock"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		threadLocks.set(vi, new sys.thread.Lock());
		return VInstance(vi);
	}

	static function thisThreadLock(a:Array<EvalValue>):sys.thread.Lock {
		return threadLocks.get(thisInstance(a, "Lock"));
	}

	static function mkThreadTls(ctx:EvalContext):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.thread.Tls"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		threadTls.set(vi, new sys.thread.Tls<EvalValue>());
		return VInstance(vi);
	}

	static function thisThreadTls(a:Array<EvalValue>):sys.thread.Tls<EvalValue> {
		return threadTls.get(thisInstance(a, "Tls"));
	}

	static function mkThreadDeque(ctx:EvalContext):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.thread.Deque"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		threadDeques.set(vi, new sys.thread.Deque<EvalValue>());
		return VInstance(vi);
	}

	static function thisThreadDeque(a:Array<EvalValue>):sys.thread.Deque<EvalValue> {
		return threadDeques.get(thisInstance(a, "Deque"));
	}

	// Without libuv (emscripten) the eval overlay's Condition and Semaphore cannot run, so the generic
	// std's stand in over these (ModuleLoader.skipEvalOverlayFile).
	#if emscripten
	static function mkThreadCondition(ctx:EvalContext):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.thread.Condition"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		threadConditions.set(vi, {cond: new sys.thread.Condition(), owner: null, count: 0});
		return VInstance(vi);
	}

	static function thisThreadCondition(a:Array<EvalValue>):ThreadConditionState {
		return threadConditions.get(thisInstance(a, "Condition"));
	}

	static function mkThreadSemaphore(ctx:EvalContext, value:Int):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.thread.Semaphore"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		threadSemaphores.set(vi, new sys.thread.Semaphore(value));
		return VInstance(vi);
	}

	static function thisThreadSemaphore(a:Array<EvalValue>):sys.thread.Semaphore {
		return threadSemaphores.get(thisInstance(a, "Semaphore"));
	}
	#end

	// Spawn: the thread record, then the thread - the descriptor takes the next ident before the new
	// thread runs.
	static function spawnThread(ctx:EvalContext, job:EvalValue):EvalValue {
		var thread = new EvalThreadRecord(hxc.compiler.HostRuntime.threadCreated());
		sys.thread.Thread.create(function() {
			hxc.compiler.HostRuntime.threadStarted(thread.ident);
			// The thread takes the lock as it starts.
			gilEnter();
			// The thread runs on an eval of its own.
			ctx.evalTls.value = new Eval(thread);
			try {
				applyFn(job, []);
			} catch (e:EvalExceptions.EvalRunTimeException) {
				hxc.compiler.HostRuntime.stderrLine(EvalExceptions.getExcErrorMessage(ctx, e));
			} catch (e:EvalExceptions.EvalSysExit) {
				hxc.compiler.HostRuntime.exit(e.code);
			} catch (e:EvalExceptions.EvalThreadExit) {
			} catch (e:Dynamic) {
				// An exception escaping the thread is reported as an uncaught thread exception.
				hxc.compiler.HostRuntime.threadUncaughtException(EvalExceptions.formatException(e));
			}
			ctx.evalTls.value = null;
			thread.terminate();
			gilLeave();
			hxc.compiler.HostRuntime.threadEnded();
		});
		return threadInstance(ctx, thread);
	}

	// A NativeThread instance for the thread: a new instance every time.
	static function threadInstance(ctx:EvalContext, thread:EvalThreadRecord):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("eval.vm.NativeThread"));
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IThread(thread)));
	}

	static function thisThread(ctx:EvalContext, v:EvalValue):EvalThreadRecord {
		return switch (v) {
			case VInstance({ikind: IThread(t)}): t;
			case _: EvalExceptions.unexpectedValue(ctx, v, "Thread");
		};
	}

	static function xmlTypeValue(x:Xml):EvalValue {
		return VInt(cast x.nodeType);
	}

	static function setInstanceFieldIfExists(vi:VInstance, name:String, value:EvalValue):Void {
		var idx = vi.iproto.pinstanceNames.get(EvalHash.hash(name));
		if (idx != null) vi.ifields[idx] = value;
	}

	static function xmlInstance(ctx:EvalContext, x:Xml):VInstance {
		var vi = nativeXmlValues.get(x);
		if (vi == null) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("Xml"));
			vi = new VInstance(proto.pinstanceFields.copy(), proto);
			nativeXmlValues.set(x, vi);
			nativeXml.set(vi, x);
		}
		return vi;
	}

	static function syncXmlFields(ctx:EvalContext, vi:VInstance, x:Xml):Void {
		setInstanceFieldIfExists(vi, "nodeType", xmlTypeValue(x));
		setInstanceFieldIfExists(vi, "parent", x.parent == null ? VNull : VInstance(xmlInstance(ctx, x.parent)));
		setInstanceFieldIfExists(vi, "nodeName", try mkStr(x.nodeName) catch (_:Dynamic) VNull);
		setInstanceFieldIfExists(vi, "nodeValue", try mkStr(x.nodeValue) catch (_:Dynamic) VNull);
		var children = switch (x.nodeType) {
			case Xml.Element | Xml.Document: [for (child in x) xmlValue(ctx, child)];
			case _: [];
		};
		setInstanceFieldIfExists(vi, "children", VArray(new VArray(children, children.length)));
	}

	static function xmlValue(ctx:EvalContext, x:Xml):EvalValue {
		var vi = xmlInstance(ctx, x);
		syncXmlFields(ctx, vi, x);
		return VInstance(vi);
	}

	static function processArgs(ctx:EvalContext, v:EvalValue):Null<Array<String>> {
		return switch (v) {
			case VNull: null;
			case VArray(va): [for (i in 0...va.alength) stringOf(va.avalues[i])];
			case _: EvalExceptions.unexpectedValue(ctx, v, "array");
		}
	}

	public static function valueKind(v:EvalValue):String {
		return EvalExceptions.sValueKind(v);
	}

	static function fileSeekMode(mode:EvalValue):sys.io.FileSeek {
		return switch (mode) {
			case VEnumValue(ev): switch (ev.eindex) {
				case 1: sys.io.FileSeek.SeekCur;
				case 2: sys.io.FileSeek.SeekEnd;
				case _: sys.io.FileSeek.SeekBegin;
			}
			case _: sys.io.FileSeek.SeekBegin;
		};
	}

	// Raising Eof fails with the instance prototype lookup's error when the program never compiled
	// haxe.io.Eof.
	static function eof(ctx:EvalContext):Dynamic {
		var proto = EvalContext.getInstancePrototype(ctx, EvalHash.hash("haxe.io.Eof"), Position.nullPos);
		return EvalExceptions.exc(ctx, VInstance(new VInstance(proto.pinstanceFields.copy(), proto)));
	}

	static function newBytesBufferMap():Map<String, MapEntry> {
		var buf:Map<String, MapEntry> = new Map();
		bytesBufferSetLength(buf, 0);
		return buf;
	}

	static function bytesBufferValue(ctx:EvalContext, buf:Map<String, MapEntry>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.io.BytesBuffer"));
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(buf)));
	}

	static function mkBytesBuffer(ctx:EvalContext):EvalValue {
		return bytesBufferValue(ctx, newBytesBufferMap());
	}

	// Array.iterator: a native's iterator is an OBJECT with hasNext and next over the live array.
	// The std's haxe.iterators classes have no natives and are interpreted, so their frames and null
	// handling are the code's own.
	static function arrayIteratorValue(ctx:EvalContext, arrayValue:EvalValue):EvalValue {
		var arr = thisArray(ctx, [arrayValue]);
		var i = 0;
		return mkObject([
			{name: "hasNext", value: VFunction(function(a) return EvalValueTools.vbool(i < arr.alength), true)},
			{name: "next", value: VFunction(function(a) return i < arr.alength ? arr.avalues[i++] : VNull, true)}
		]);
	}

	// hasNext and next over a snapshot (a map's keys or values).
	static function listIteratorValue(items:Array<EvalValue>):EvalValue {
		var i = 0;
		return mkObject([
			{name: "hasNext", value: VFunction(function(a) return EvalValueTools.vbool(i < items.length), true)},
			{name: "next", value: VFunction(function(a) return i < items.length ? items[i++] : VNull, true)}
		]);
	}

	// The std's MapKeyValueIterator, constructed and run through its own interpreted constructor over
	// the map.
	static function mapKeyValueIteratorValue(ctx:EvalContext, mapValue:EvalValue):EvalValue {
		return hxc.eval.EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.iterators.MapKeyValueIterator"), [mapValue]);
	}

	// A native string and nothing else.
	static function decodeNativeString(ctx:EvalContext, v:EvalValue):ByteString {
		return switch (v) {
			case VNativeString(s): s;
			case _: EvalExceptions.unexpectedValue(ctx, v, "native string");
		};
	}

	static function mkStringMap(ctx:EvalContext, values:Map<String, String>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.ds.StringMap"));
		var m:Map<String, MapEntry> = new Map();
		for (k in values.keys()) m.set(k, {key: mkStr(k), value: mkStr(values.get(k))});
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(m)));
	}

	public static function mkStringMapValues(ctx:EvalContext, values:Map<String, EvalValue>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.ds.StringMap"));
		var m:Map<String, MapEntry> = new Map();
		for (k => v in values) m.set(k, {key: mkStr(k), value: v});
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(m)));
	}

	static function mkStringBytesMap(ctx:EvalContext, values:haxe.ds.StringMap<haxe.io.Bytes>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.ds.StringMap"));
		var m:Map<String, MapEntry> = new Map();
		for (k in values.keys()) {
			var bytes = values.get(k);
			m.set(k, {key: mkStr(k), value: mkBytes(ctx, bytes.sub(0, bytes.length))});
		}
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(m)));
	}

	static function mkPos(ctx:EvalContext, p:Position):EvalValue {
		var path = EvalHash.hash("haxe.macro.Position");
		var proto = ctx.instancePrototypes.get(path);
		if (proto == null) {
			proto = new VPrototype(path, [], new Map(), [], new Map(), null, PClass([]), VNull);
			proto.pvalue = VPrototype(proto);
			ctx.instancePrototypes.set(path, proto);
		}
		return VInstance(new VInstance([], proto, IPos(p)));
	}

	static function posInfos(p:Position):EvalValue {
		return mkObject([
			{name: "min", value: VInt(p.min)},
			{name: "max", value: VInt(p.max)},
			{name: "file", value: mkStr(p.file)}
		]);
	}

	static function importMode(ctx:EvalContext, mode:ImportMode):EvalValue {
		var e = classValue(ctx, EvalHash.hash("haxe.macro.ImportMode"));
		return switch (mode) {
			case INormal:
				createEnumByName(ctx, e, EvalHash.hash("INormal"), VNull);
			case IAsName(alias):
				createEnumByName(ctx, e, EvalHash.hash("IAsName"), valueArray([mkStr(alias.name)]));
			case IAll:
				createEnumByName(ctx, e, EvalHash.hash("IAll"), VNull);
		}
	}

	static function importPathPart(ctx:EvalContext, pn:PlacedName):EvalValue {
		return mkObject([
			{name: "name", value: mkStr(pn.name)},
			{name: "pos", value: mkPos(ctx, pn.pos)}
		]);
	}

	static function importExpr(ctx:EvalContext, imp:Import):EvalValue {
		return mkObject([
			{name: "path", value: valueArray([for (pn in imp.path) importPathPart(ctx, pn)])},
			{name: "mode", value: importMode(ctx, imp.mode)}
		]);
	}

	static function localImports(ctx:EvalContext):EvalValue {
		var com = EvalMacro.currentCompiler();
		var m = EvalMacro.currentModule();
		if (com == null || m == null) return valueArray([]);
		var imports = com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports == null) return valueArray([]);
		return valueArray([for (imp in imports.rawImports) importExpr(ctx, imp)]);
	}

	static function definesForExternal(defines:Map<String, String>):Map<String, String> {
		var out = new Map<String, String>();
		for (k => v in defines) {
			out.set(k, v);
			var dashed = StringTools.replace(k, "_", "-");
			if (dashed != k) out.set(dashed, v);
		}
		return out;
	}

	static inline function externalDefineKey(k:String):String {
		return StringTools.replace(k, "-", "_");
	}

	static function resolveMacroPath(ctx:EvalContext, file:String):EvalValue {
		// An absolute path resolves to itself; the classpath walk falls back to the raw relative path when
		// no empty classpath was listed.
		if (haxe.io.Path.isAbsolute(file)) return mkStr(file);
		// The lookup walks the current compilation's class path - the host's, for a macro called from it
		// - not a copy. The eval context's own list is whatever it was created with, and the macro
		// world's is empty, so with either one every class-path relative name would be "File not found".
		var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
		// The found path is rebuilt from the directory LISTING as `dir/name`, or the bare name when the
		// directory is ".", so `-cp .` yields "P.hx", not "./P.hx".
		function found(path:String):EvalValue {
			var dir = haxe.io.Path.directory(path);
			var own = haxe.io.Path.withoutDirectory(path);
			return mkStr(dir == "" || dir == "." ? own : dir + "/" + own);
		}
		var hadEmpty = false;
		for (cp in (com != null ? com.classPath : ctx.classPath)) {
			if (cp == "") hadEmpty = true;
			var path = cp == "" ? file : cp + file;
			if (sys.FileSystem.exists(path)) return found(path);
		}
		if (!hadEmpty && sys.FileSystem.exists(file)) return found(file);
		return EvalExceptions.excString(ctx, "File not found '" + file + "'");
	}

	static function mkObject(fields:Array<{name:String, value:EvalValue}>):EvalValue {
		var m:Map<Int, EvalValue> = new Map();
		for (f in fields) m.set(EvalHash.hash(f.name), f.value);
		return VObject(new VObject([], ODictionary(m)));
	}

	static function stackEnum(ctx:EvalContext, name:String, args:Array<EvalValue>):EvalValue {
		var path = EvalHash.hash("haxe.StackItem");
		var e = classValue(ctx, path);
		if (e != VNull) return createEnumByName(ctx, e, EvalHash.hash(name), VArray(new VArray(args, args.length)));
		var index = switch (name) {
			case "CFunction": 0;
			case "Module": 1;
			case "FilePos": 2;
			case "Method": 3;
			case "LocalFunction": 4;
			case _: 0;
		}
		return VEnumValue(new VEnumValue(index, args, path, null));
	}

	// A stack item's line and column are the error printer's coordinates (a 1-based column; an
	// unresolved offset is column 0).
	static function stackFilePos(ctx:EvalContext, p:Position, item:EvalValue):EvalValue {
		var file = p == null ? "?" : p.file;
		if (file == null) file = "?";
		var infos = Position.getInfos(p == null ? Position.nullPos : p);
		return stackEnum(ctx, "FilePos", [item, mkStr(file), VInt(infos.line), VInt(infos.column + 1)]);
	}

	// A method or local function is an item at its frame's position; an entry environment
	// (EKEntrypoint) is no item at all.
	static function stackItem(ctx:EvalContext, p:Position, kind:EvalEnvKind):Null<EvalValue> {
		return switch (kind) {
			case EKLocalFunction(index):
				stackFilePos(ctx, p, stackEnum(ctx, "LocalFunction", [VInt(index)]));
			case EKMethod(typeKey, fieldKey):
				var typeName = EvalHash.revHash(typeKey);
				var fieldName = EvalHash.revHash(fieldKey);
				stackFilePos(ctx, p, stackEnum(ctx, "Method", [typeName == null ? VNull : mkStr(typeName), fieldName == null ? VNull : mkStr(fieldName)]));
			case EKEntrypoint:
				null;
		};
	}

	static function stackItems(ctx:EvalContext, frames:Array<{pos:Position, kind:EvalEnvKind}>):EvalValue {
		var items = [];
		for (f in frames) {
			var item = stackItem(ctx, f.pos, f.kind);
			if (item != null) items.push(item);
		}
		return VArray(new VArray(items, items.length));
	}

	// getCallStack: the live environments past the two wrappers (callStack and getCallStack), each at
	// its leave position.
	static function callStackValue(ctx:EvalContext):EvalValue {
		var envs = EvalExceptions.callStack(EvalContext.getEval(ctx));
		if (envs.length >= 2) envs = envs.slice(2);
		return stackItems(ctx, [for (env in envs) {pos: EvalExceptions.envPosition(env), kind: env.info.kind}]);
	}

	// getExceptionStack: the recorded frames reversed. They are recorded innermost first, so the
	// value is outermost first.
	public static function exceptionStackValue(ctx:EvalContext):EvalValue {
		var frames = EvalContext.getEval(ctx).exceptionStack.copy();
		frames.reverse();
		return stackItems(ctx, frames);
	}

	static function macroStackValue(ctx:EvalContext):EvalValue {
		var envs = EvalExceptions.callStack(EvalContext.getEval(ctx));
		var items = [for (_ in envs) mkPos(ctx, Position.nullPos)];
		return VArray(new VArray(items, items.length));
	}

	static function macroMessage(ctx:EvalContext, name:String, msg:EvalValue, pos:EvalValue):EvalValue {
		var params = VArray(new VArray([msg, pos], 2));
		return createEnumByName(ctx, classValue(ctx, EvalHash.hash("haxe.macro.Message")), EvalHash.hash(name), params);
	}

	static function macroPosOf(v:EvalValue, fallback:Position):Position {
		return switch (EvalValueTools.vresolve(v)) {
			case VInstance(vi): switch (vi.ikind) { case IPos(p): p; case _: fallback; }
			case _: fallback;
		};
	}

	static function macroErrorValue(ctx:EvalContext, msg:String, posValue:EvalValue):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.macro.Error"));
		if (proto == null) proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.macro.Expr.Error"));
		if (proto == null) return mkStr(msg);
		ensureInstanceSlot(proto, EvalHash.hash("message"));
		ensureInstanceSlot(proto, EvalHash.hash("get_message"));
		ensureInstanceSlot(proto, EvalHash.hash("pos"));
		ensureInstanceSlot(proto, EvalHash.hash("childErrors"));
		var pos = macroPosOf(posValue, EvalMacro.currentPosition());
		var v:EvalValue = VInstance(new VInstance(proto.pinstanceFields.copy(), proto, INormal));
		EvalField.setField(ctx, v, EvalHash.hash("message"), mkStr(msg), pos);
		EvalField.setField(ctx, v, EvalHash.hash("get_message"), VFunction(function(_) return mkStr(msg), false), pos);
		EvalField.setField(ctx, v, EvalHash.hash("pos"), posValue, pos);
		EvalField.setField(ctx, v, EvalHash.hash("childErrors"), VNull, pos);
		return v;
	}

	static function ensureInstanceSlot(proto:VPrototype, name:Int):Void {
		if (proto.pinstanceNames.exists(name)) return;
		proto.pinstanceNames.set(name, proto.pinstanceFields.length);
		proto.pinstanceFields.push(VNull);
	}

	static function mkFileStat(ctx:EvalContext, stat:sys.FileStat):EvalValue {
		return mkObject([
			{name: "gid", value: VInt(stat.gid)},
			{name: "uid", value: VInt(stat.uid)},
			{name: "atime", value: mkDate(ctx, stat.atime.getTime())},
			{name: "mtime", value: mkDate(ctx, stat.mtime.getTime())},
			{name: "ctime", value: mkDate(ctx, stat.ctime.getTime())},
			{name: "dev", value: VInt(stat.dev)},
			{name: "ino", value: VInt(stat.ino)},
			{name: "nlink", value: VInt(stat.nlink)},
			{name: "rdev", value: VInt(stat.rdev)},
			{name: "size", value: VInt(stat.size)},
			{name: "mode", value: VInt(stat.mode)}
		]);
	}

	static function thisInstance(a:Array<EvalValue>, typeName:String):VInstance {
		return switch (arg(a, 0)) {
			case VInstance(vi): vi;
			case _: throw "Unexpected value for " + typeName;
		};
	}

	static function zipResult(r:Dynamic):EvalValue {
		var wrote:Dynamic = Reflect.field(r, "write");
		if (wrote == null) wrote = Reflect.field(r, "wriet");
		return mkObject([
			{name: "done", value: EvalValueTools.vbool(Reflect.field(r, "done"))},
			{name: "read", value: VInt(Reflect.field(r, "read"))},
			{name: "write", value: VInt(wrote)}
		]);
	}

	static function flushMode(v:EvalValue):haxe.zip.FlushMode {
		return switch (v) {
			case VEnumValue(ev): switch (ev.eindex) {
				case 0: haxe.zip.FlushMode.NO;
				case 1: haxe.zip.FlushMode.SYNC;
				case 2: haxe.zip.FlushMode.FULL;
				case 3: haxe.zip.FlushMode.FINISH;
				case _: haxe.zip.FlushMode.BLOCK;
			}
			case _: haxe.zip.FlushMode.NO;
		};
	}

	// Trace: the value printed, and with infos `file:line: ` before it and its customParams after,
	// each printed; lineEnd either way.
	static function traceString(ctx:EvalContext, value:EvalValue, infos:EvalValue):ByteString {
		var s = valueString(value);
		var le = ByteString.ofRaw(lineEnd());
		if (infos == VNull) return s + le;
		var fileName = decodeString(ctx, EvalField.field(ctx, infos, EvalHash.hash("fileName")));
		var lineNumber = decodeInt(ctx, EvalField.field(ctx, infos, EvalHash.hash("lineNumber")));
		var l = [s];
		switch (EvalField.field(ctx, infos, EvalHash.hash("customParams"))) {
			case VArray(va):
				for (i in 0...va.alength) l.push(valueString(va.avalues[i]));
			case _:
		}
		var buf = new ByteBuffer();
		buf.addString(fileName);
		buf.addString(ByteString.ofRaw(":" + lineNumber + ": "));
		for (i in 0...l.length) {
			if (i > 0) buf.addByte(",".code);
			buf.addString(l[i]);
		}
		buf.addString(le);
		return buf.contents();
	}

	static inline function lineEnd():String return Sys.systemName() == "Windows" ? "\r\n" : "\n";

	// com.print: the bytes to stdout as they are, and println's lineEnd after them.
	static function writeStdoutString(s:ByteString, newline:Bool):Void {
		// During a wait-server request, macro-time stdout joins the framed response; the whole logical
		// write (content plus line end) is one encoded chunk.
		if (hxc.Compiler.requestOutput != null) {
			hxc.Compiler.serverPrint(s.toText() + (newline ? lineEnd() : ""));
			return;
		}
		var out = Sys.stdout();
		if (s.length > 0) out.write(s.toBytes());
		// Eval's println appends the PLATFORM line end explicitly (stdout itself is binary), so
		// interpreted output keeps \r\n on Windows.
		if (newline) out.writeString(lineEnd());
		// Every write to stdout is flushed, for print as for println: what the program printed reaches the
		// terminal before any message the compiler then writes to stderr.
		out.flush();
	}

	static function flushStdout():Void {
		try Sys.stdout().flush() catch (_:Dynamic) {}
	}

	static function sysProgramPath(ctx:EvalContext):EvalValue {
		// programPath: the main class's type, and the full path of its position's file.
		var com = ctx.com;
		if (com == null || com.mainClass == null) return VNull;
		return switch (ctx.typeCache.get(EvalHash.pathHash(com.mainClass))) {
			case TClassDecl(c):
				var file = c.pos.file;
				file == null || file == "?" ? VNull : mkStr(sys.FileSystem.fullPath(file));
			case _: VNull;
		}
	}

	static function hostIpString(ip:Int):String {
		return (ip >>> 24) + "." + ((ip >>> 16) & 0xFF) + "." + ((ip >>> 8) & 0xFF) + "." + (ip & 0xFF);
	}

	static function hostIpInt(host:String):Int {
		var parts = new sys.net.Host(host).toString().split(".");
		if (parts.length != 4) return 0;
		return ((Std.parseInt(parts[0]) & 0xFF) << 24)
			| ((Std.parseInt(parts[1]) & 0xFF) << 16)
			| ((Std.parseInt(parts[2]) & 0xFF) << 8)
			| (Std.parseInt(parts[3]) & 0xFF);
	}

	static function mkNativeSocket(ctx:EvalContext, socket:sys.net.Socket):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("eval.vm.NativeSocket"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		nativeSockets.set(vi, socket);
		return VInstance(vi);
	}

	static function thisSocket(a:Array<EvalValue>):sys.net.Socket {
		return nativeSockets.get(thisInstance(a, "NativeSocket"));
	}

	static function setSocketBroadcast(socket:sys.net.Socket, value:Bool):Void {
		#if cpp
		NativeSocket.socket_set_broadcast(untyped socket.__s, value);
		#else
		throw "setBroadcast is not supported on this host target";
		#end
	}

	static function hostInfo(info:{host:sys.net.Host, port:Int}):EvalValue {
		return mkObject([
			{name: "ip", value: VInt(hostIpInt(info.host.toString()))},
			{name: "port", value: VInt(info.port)}
		]);
	}

	// ObjectMap key equality (every key hashes alike and compares by value equality): numbers by
	// value, an Int equal to the float it is; strings by content; an enum constructor without
	// arguments by its path and index; a prototype by its path; anything else by identity. A NaN
	// equals nothing, itself included, so each is a key of its own.
	static var nanKeys = 0;

	static function objectMapKey(v:EvalValue):String {
		return switch (v) {
			case VNull: "n";
			case VTrue: "t";
			case VFalse: "f";
			case VInt(i): "#" + i;
			case VFloat(f):
				if (Math.isNaN(f)) "nan:" + (nanKeys++);
				else if (f == Math.ffloor(f) && Math.abs(f) < 2147483648.0) "#" + Std.int(f);
				else "#f" + bytesOfDouble(f).toHex();
			case VString(_): "s:" + mapKey(v);
			case VNativeString(s): "ns:" + s.raw();
			case VHandle(h): "h:" + h.kind.getIndex() + ":" + objId(h.native);
			case VInt64(b) | VUInt64(b): "@" + objId(b);
			case VEnumValue(ev) if (ev.eargs.length == 0): "e:" + ev.epath + ":" + ev.eindex;
			case VEnumValue(ev): "@" + objId(ev);
			case VPrototype(p): "p:" + p.ppath;
			case VObject(o): "@" + objId(o);
			case VInstance(vi): "@" + objId(vi);
			case VArray(va): "@" + objId(va);
			case VVector(vv): "@" + objId(vv);
			case VFunction(fn, _): "@" + objId(cast fn);
			case VLazy(f): objectMapKey(f());
			case _: "@" + objId(cast v);
		};
	}

	// A map's runtime key folds to a string for storage; StringMap keeps the string and IntMap the
	// int. An ObjectMap's is objectMapKey.
	static function mapKey(v:EvalValue):String {
		return switch (v) {
			// A StringMap keys on the string's bytes.
			case VString(s): s.sstring.raw();
			case VInt(i): Std.string(i);
			case VEnumValue(ev): "e:" + ev.epath + ":" + ev.eindex + ":" + [for (a in ev.eargs) mapKey(a)].join(",");
			case VObject(o): "o:" + objId(o);
			case VInstance(vi): "o:" + objId(vi);
			case _: stringOf(v);
		};
	}

	public static function orderedMapEntries(v:EvalValue):Array<MapEntry> {
		return switch (v) {
			case VInstance(vi):
				var m = thisMap([v]);
				var order = nativeMapOrders.get(vi);
				var entries = order == null ? [for (e in m) e] : [for (k in order) if (m.exists(k)) m.get(k)];
				if (vi.iproto.ppath == EvalHash.hash("haxe.ds.StringMap")) {
					// A StringMap is ordered by key, and its keys/values fold ascending while PREPENDING, so the
					// exposed iteration order is descending byte-wise key order.
					entries.sort(function(a, b) return -byteStringCompare(stringOf(a.key), stringOf(b.key)));
				} else if (vi.iproto.ppath == EvalHash.hash("haxe.ds.IntMap")) {
					var buckets = hashTableBucketCount(entries.length);
					var positions = order == null ? [for (e in entries) mapKey(e.key)] : order;
					entries.sort(function(a, b) {
						var ak = toInt(a.key);
						var bk = toInt(b.key);
						var d = (seededIntHash(bk) & (buckets - 1)) - (seededIntHash(ak) & (buckets - 1));
						if (d != 0) return d;
						return Reflect.compare(positions.indexOf(mapKey(a.key)), positions.indexOf(mapKey(b.key)));
					});
				}
				entries;
			case _:
				[];
		};
	}

	static function toFloat(v:EvalValue):Float {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f): f;
			case _: Math.NaN;
		};
	}

	static function evalMathInt(f:Float):Int {
		if (Math.isNaN(f) || !Math.isFinite(f)) return 0x80000000;
		var sign = f < 0 ? -1 : 1;
		var r = Math.abs(f) % 2147483648.0;
		var i = Std.int(r);
		return sign < 0 ? -i : i;
	}

	static function isNegativeZero(f:Float):Bool {
		return f == 0 && 1 / f == Math.NEGATIVE_INFINITY;
	}

	static function normalizeFloatExponent(s:String):String {
		var e = s.indexOf("e");
		if (e < 0) e = s.indexOf("E");
		if (e < 0) return s;
		var head = s.substr(0, e);
		var exp = s.substr(e + 1);
		var sign = "";
		if (StringTools.startsWith(exp, "-") || StringTools.startsWith(exp, "+")) {
			sign = exp.substr(0, 1);
			exp = exp.substr(1);
		}
		while (exp.length < 3) exp = "0" + exp;
		return head + "e" + sign + exp;
	}

	static function cFormatFloat(f:Float, precision:Int):String {
		#if cpp
		return switch (precision) {
			case 12:
				untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.12g", v); return String(buf); })({0})', f);
			case 15:
				untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.15g", v); return String(buf); })({0})', f);
			case 17:
				untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.17g", v); return String(buf); })({0})', f);
			case 18:
				untyped __cpp__('([](double v) { char buf[64]; snprintf(buf, sizeof(buf), "%.18g", v); return String(buf); })({0})', f);
			case _:
				Std.string(f);
		}
		#else
		return Std.string(f);
		#end
	}

	static function floatString(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (!Math.isFinite(f)) return f < 0 ? "neg_infinity" : "infinity";
		if (isNegativeZero(f)) return "-0";
		var s = cFormatFloat(f, 12);
		if (Std.parseFloat(s) != f) {
			s = cFormatFloat(f, 15);
			if (Std.parseFloat(s) != f) {
				s = cFormatFloat(f, 17);
				if (Std.parseFloat(s) != f) s = cFormatFloat(f, 18);
			}
		}
		if (StringTools.endsWith(s, ".")) s = s.substr(0, s.length - 1);
		return normalizeFloatExponent(s);
	}

	// A native's result the host computed as TEXT: its UTF-8 bytes (EvalString.createUnknown).
	static inline function mkStr(s:String):EvalValue return EvalString.vOfText(s);
	static inline function mkNullStr(s:String):EvalValue return s == null ? VNull : mkStr(s);

	// Bytes.ofString: the string's bytes as they are.
	static function bytesOfStringValue(ctx:EvalContext, v:EvalValue):haxe.io.Bytes {
		return decodeVString(ctx, EvalValueTools.vresolve(v)).sstring.toBytes();
	}

	static inline function numericWhitespace(code:Int):Bool {
		return code > 8 && code < 14;
	}

	// Std.int: a value that is not a number is null. A float goes through a 63-bit integer
	// conversion - on amd64 NaN, the infinities and anything at or past 2^63 come out 0 - and the low
	// 32 bits are kept.
	static function stdInt(v:EvalValue):EvalValue {
		var f = switch (v) {
			case VInt(i): return VInt(i);
			case VFloat(f): f;
			case _: return VNull;
		};
		if (Math.isNaN(f) || !(Math.abs(f) < 9223372036854775808.0)) return VInt(0);
		var m = (f < 0 ? Math.ceil(f) : Math.floor(f)) % 4294967296.0;
		if (m < 0) m += 4294967296.0;
		if (m >= 2147483648.0) m -= 4294967296.0;
		return VInt(Std.int(m));
	}

	static function stdParseInt(s:String):EvalValue {
		var sp = 0;
		while (sp < s.length) {
			var c = s.charCodeAt(sp);
			if (c == " ".code || numericWhitespace(c)) sp++ else break;
		}
		var start = sp;
		if (sp < s.length && (s.charCodeAt(sp) == "+".code || s.charCodeAt(sp) == "-".code)) sp++;
		var digitsStart = sp;
		var isHex = sp + 1 < s.length && s.charCodeAt(sp) == "0".code && (s.charCodeAt(sp + 1) == "x".code || s.charCodeAt(sp + 1) == "X".code);
		if (isHex) sp += 2;
		var valueStart = sp;
		while (sp < s.length) {
			var c = s.charCodeAt(sp);
			var digit = c >= "0".code && c <= "9".code;
			var hex = isHex && ((c >= "a".code && c <= "f".code) || (c >= "A".code && c <= "F".code));
			if (digit || hex) sp++ else break;
		}
		if (sp == valueStart || (!isHex && sp == digitsStart)) return VNull;
		var parsed = Std.parseInt(s.substr(start, sp - start));
		return parsed == null ? VNull : VInt(parsed);
	}

	static function stdParseFloat(s:String):Float {
		var sp = 0;
		while (sp < s.length) {
			var c = s.charCodeAt(sp);
			if (c == " ".code || numericWhitespace(c)) sp++ else break;
		}
		var pos = sp;
		while (pos < s.length) {
			var c = s.charCodeAt(pos);
			if ((c >= "0".code && c <= "9".code) || c == "-".code || c == "+".code || c == "e".code || c == "E".code || c == ".".code) pos++ else break;
		}
		var part = s.substr(sp, pos - sp);
		var i = 0;
		if (i < part.length && (part.charCodeAt(i) == "+".code || part.charCodeAt(i) == "-".code)) i++;
		var digits = 0;
		while (i < part.length && part.charCodeAt(i) >= "0".code && part.charCodeAt(i) <= "9".code) {
			i++;
			digits++;
		}
		if (i < part.length && part.charCodeAt(i) == ".".code) {
			i++;
			while (i < part.length && part.charCodeAt(i) >= "0".code && part.charCodeAt(i) <= "9".code) {
				i++;
				digits++;
			}
		}
		if (digits == 0) return hostNan;
		if (i < part.length && (part.charCodeAt(i) == "e".code || part.charCodeAt(i) == "E".code)) {
			i++;
			if (i < part.length && (part.charCodeAt(i) == "+".code || part.charCodeAt(i) == "-".code)) i++;
			var expDigits = 0;
			while (i < part.length && part.charCodeAt(i) >= "0".code && part.charCodeAt(i) <= "9".code) {
				i++;
				expDigits++;
			}
			if (expDigits == 0) return hostNan;
		}
		// A float that does not parse is the interpreter's fixed NaN.
		return i == part.length ? Std.parseFloat(part) : hostNan;
	}

	// URL encoding: each BYTE outside [A-Za-z0-9_.-] as %XX.
	static function urlEncode(s:ByteString):ByteString {
		var hex = "0123456789ABCDEF";
		var b = new ByteBuffer();
		for (i in 0...s.length) {
			var c = s.unsafeGet(i);
			if ((c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code)
				|| (c >= "0".code && c <= "9".code) || c == "_".code || c == "-".code || c == ".".code) {
				b.addByte(c);
			} else {
				b.addByte("%".code);
				b.addByte(hex.charCodeAt(c >> 4));
				b.addByte(hex.charCodeAt(c & 0xF));
			}
		}
		return b.contents();
	}

	static function hexValue(c:Null<Int>):Null<Int> {
		if (c == null) return null;
		if (c >= "0".code && c <= "9".code) return c - "0".code;
		if (c >= "a".code && c <= "f".code) return c - "a".code + 10;
		if (c >= "A".code && c <= "F".code) return c - "A".code + 10;
		return null;
	}

	static function decodeHex(s:String, index:Int):Null<Int> {
		var c1 = hexValue(s.charCodeAt(index));
		var c2 = hexValue(s.charCodeAt(index + 1));
		return c1 == null || c2 == null ? null : ((c1 << 4) | c2);
	}

	// StringTools.urlDecode: a %XX escape led by a UTF-8 lead byte reads the escapes its sequence
	// needs, masks their bits and adds the decoded code; a bad escape is skipped over its `%`; any
	// other byte, a non-ASCII one included, is added alone with length 1.
	static function urlDecode(ctx:EvalContext, s:ByteString):VString {
		var b = new VStringBuffer();
		var len = s.length;
		function decode(c:Int):Null<Int> {
			return if (c >= "0".code && c <= "9".code) c - "0".code
				else if (c >= "a".code && c <= "f".code) c - "a".code + 10
				else if (c >= "A".code && c <= "F".code) c - "A".code + 10
				else null;
		}
		function decodeHex(i:Int):Null<Int> {
			var p1 = try decode(s.get(i)) catch (_:hxc.eval.EvalExceptions.HostException) null;
			var p2 = try decode(s.get(i + 1)) catch (_:hxc.eval.EvalExceptions.HostException) null;
			return p1 != null && p2 != null ? ((p1 << 4) | p2) : null;
		}
		function expectHex(i:Int):Int {
			if (s.unsafeGet(i) != "%".code) return EvalExceptions.excString(ctx, "Malformed");
			var c = decodeHex(i + 1);
			return c == null ? EvalExceptions.excString(ctx, "Malformed") : c;
		}
		function addByte(c:Int):Void b.addString(EvalString.createAscii(ByteString.ofRaw(String.fromCharCode(c))));
		var i = 0;
		while (i != len) {
			var c = s.unsafeGet(i);
			if (c == "%".code) {
				var h = decodeHex(i + 1);
				if (h == null) {
					i++;
				} else if (h < 0x80) {
					addByte(h);
					i += 3;
				} else if (h < 0xE0) {
					var c2 = expectHex(i + 3);
					b.addString(EvalString.fromCharCode(((h & 0x3F) << 6) | (c2 & 0x7F)));
					i += 6;
				} else if (h < 0xF0) {
					var c2 = expectHex(i + 3);
					var c3 = expectHex(i + 6);
					b.addString(EvalString.fromCharCode(((h & 0x1F) << 12) | ((c2 & 0x7F) << 6) | (c3 & 0x7F)));
					i += 9;
				} else {
					var c2 = expectHex(i + 3);
					var c3 = expectHex(i + 6);
					var c4 = expectHex(i + 9);
					var k = ((h & 0x0F) << 18) | ((c2 & 0x7F) << 12) | ((c3 & 0x7F) << 6) | (c4 & 0x7F);
					b.addString(EvalString.fromCharCode(k));
					i += 12;
				}
			} else if (c == "+".code) {
				addByte(" ".code);
				i++;
			} else {
				addByte(c);
				i++;
			}
		}
		return b.contents();
	}

	static function maxPrintDepth():Int {
		return try EvalContext.getCtx().maxPrintDepth catch (_:Dynamic) 100;
	}

	static function enumConstructorName(ev:VEnumValue):String {
		return try {
			var p = EvalContext.getCtx().staticPrototypes.get(ev.epath);
			if (p == null) "#unknown" else switch (p.pkind) {
				case PEnum(cs):
					ev.eindex >= 0 && ev.eindex < cs.length ? cs[ev.eindex].name : "#unknown";
				case _: "#unknown";
			}
		} catch (_:Dynamic) {
			"#unknown";
		}
	}

	// The value's toString field, looked up with fieldRaise (a missing field is NotFound, which the
	// callers answer with their own printing), called as callValueOn calls it, and its result printed
	// one level deeper. An exception it raises is the caller's.
	static function callToString(v:EvalValue, depth:Int):Null<VString> {
		var ctx = EvalContext.getCtx();
		var vf = try EvalField.fieldRaise(ctx, v, EvalHash.key_toString) catch (_:hxc.core.NotFound) return null;
		return sValue(callValueOn(v, vf, []), depth + 1);
	}

	static function protoString(proto:VPrototype):VString {
		return switch (proto.pkind) {
			case PClass(_): EvalString.createAscii(ByteString.ofText("Class<" + EvalHash.revHash(proto.ppath) + ">"));
			case PEnum(_): EvalString.createAscii(ByteString.ofText("Enum<" + EvalHash.revHash(proto.ppath) + ">"));
			case PInstance | PObject: EvalString.createAscii(ByteString.ofText(EvalHash.revHash(proto.ppath)));
		};
	}

	// An object prints as `{k: v, ...}` over its fields, its length the UTF-8 length or, when that
	// fails, the byte count.
	static function objectString(o:VObject, depth:Int):VString {
		var buf = new ByteBuffer();
		var fields = objectFieldMap(o);
		var keys = switch (o.oproto) {
			case OProto(proto): instanceFieldKeys(proto);
			case ODictionary(_): objectDictionaryKeys(fields);
		};
		buf.addByte("{".code);
		var first = true;
		// Fields print at the depth objectString received (the +1 happened at the VObject dispatch); a
		// second increment here would truncate one level early.
		for (k in keys) if (fields.exists(k)) {
			if (!first) buf.addString(ByteString.ofRaw(", "));
			first = false;
			buf.addString(ByteString.ofText(EvalHash.revHash(k)));
			buf.addString(ByteString.ofRaw(": "));
			buf.addString(sValue(fields.get(k), depth).sstring);
		}
		buf.addByte("}".code);
		return EvalString.createUnknownVString(buf.contents());
	}

	static function posString(p:Position):String {
		if (p.min == -1) return "#pos((unknown))";
		var info = Position.getInfos(p);
		if (info.line == info.endLine) {
			var c1 = info.column + 1;
			var c2 = info.endColumn + 1;
			var chars = c1 == c2 ? " character " + c1 : " characters " + c1 + "-" + c2;
			return "#pos(" + info.file + ":" + info.line + ":" + chars + ")";
		}
		return "#pos(" + info.file + ":" + info.line + ": lines " + info.line + "-" + info.endLine + ")";
	}

	static inline function ascii(s:String):VString return EvalString.createAscii(ByteString.ofText(s));

	// The value printed as the interpreter's own string, with the length each arm gives it - the byte
	// count for everything it formats itself, a #pos with a non-ASCII file name included, and join's
	// sum of its parts for arrays and enum arguments.
	public static function sValue(v:EvalValue, depth:Int):VString {
		if (depth > maxPrintDepth()) return ascii("<...>");
		return switch (EvalValueTools.vresolve(v)) {
			case VNull: ascii("null");
			case VTrue: ascii("true");
			case VFalse: ascii("false");
			case VInt(i): ascii(Std.string(i));
			case VFloat(f): ascii(floatString(f));
			case VString(s): s;
			case VNativeString(s): EvalString.createUnknownVString(s);
			case VFunction(_, _): ascii("#fun");
			case VFieldClosure(_, _): ascii("#closure");
			case VHandle(_): ascii("#handle");
			// Each as its decimal digits.
			case VInt64(b): ascii(EvalIntegers.int64ToString(b.v));
			case VUInt64(b): ascii(EvalIntegers.uint64ToString(b.v));
			case VEnumValue(ev):
				var name = ascii(enumConstructorName(ev));
				ev.eargs.length == 0 ? name : EvalString.join(EvalString.emptyString(), [
					name,
					ascii("("),
					EvalString.join(ascii(","), [for (a in ev.eargs) sValue(a, depth + 1)]),
					ascii(")")
				]);
			case VArray(va):
				EvalString.join(EvalString.emptyString(), [
					ascii("["),
					EvalString.join(ascii(","), [for (i in 0...va.alength) sValue(va.avalues[i], depth + 1)]),
					ascii("]")
				]);
			case VVector(vv):
				EvalString.join(EvalString.emptyString(), [
					ascii("["),
					EvalString.join(ascii(","), [for (x in vv) sValue(x, depth + 1)]),
					ascii("]")
				]);
			case VObject(o):
				var s = callToString(VObject(o), depth);
				s == null ? objectString(o, depth + 1) : s;
			case VInstance(vi):
				switch (vi.ikind) {
					case IDate(ts): ascii(sDate(ts));
					case IPos(p): ascii(posString(p));
					// A regex prints as its `~/pattern/options` text.
					case IRegex(re): EvalString.createAscii(re.rexString);
					case _:
						var s = callToString(VInstance(vi), depth);
						s == null ? ascii(EvalHash.revHash(vi.iproto.ppath)) : s;
				}
			case VPrototype(proto):
				var s = callToString(VPrototype(proto), depth);
				s == null ? protoString(proto) : s;
			case VLazy(_): throw "unreachable";
		};
	}

	// The printed value's bytes.
	public static inline function valueString(v:EvalValue):ByteString return sValue(v, 0).sstring;

	// A string or nothing. A null is a Null Access and any other value an Unexpected value, both
	// uncaught exceptions of the macro; stringOf answers "null".
	public static function decodeString(ctx:EvalContext, v:EvalValue):ByteString {
		return switch (EvalValueTools.vresolve(v)) {
			case VString(s): s.sstring;
			case VNativeString(s): s;
			case VNull: EvalExceptions.excString(ctx, "Null Access");
			case r: EvalExceptions.excValues(ctx, ["Unexpected value " + valueKind(r) + "(", "), expected string"], [r]);
		}
	}

	// decodeString for a native that hands the bytes to the host as text: a path, a name, a define.
	public static inline function decodeText(ctx:EvalContext, v:EvalValue):String return decodeString(ctx, v).toText();

	// The printed value as host text, for a message leaving the interpreter.
	public static function stringOf(v:EvalValue):String {
		return valueString(v).toText();
	}

	static function isSubProto(p:VPrototype, targetPath:Int):Bool {
		var c = p;
		while (c != null) { if (c.ppath == targetPath) return true; c = c.pparent; }
		return false;
	}

	static function classHierarchyHas(ctx:EvalContext, classPath:Int, targetPath:Int):Bool {
		if (classPath == targetPath) return true;
		return switch (ctx.typeCache.get(classPath)) {
			case TClassDecl(c):
				if (c.superClass != null && classHierarchyHas(ctx, EvalHash.pathHash(c.superClass.c.path), targetPath)) true
				else {
					var found = false;
					for (i in c.interfaces) if (classHierarchyHas(ctx, EvalHash.pathHash(i.c.path), targetPath)) {
						found = true;
						break;
					}
					found;
				}
			case _:
				false;
		};
	}

	static function stdIsOfType(v:EvalValue, t:EvalValue):Bool {
		return switch (t) {
			case VPrototype(proto):
				switch (EvalHash.revHash(proto.ppath)) {
					case "Dynamic": v != VNull;
					case "Int": switch (v) {
						case VInt(_): true;
						case VFloat(f): !Math.isNaN(f) && f >= -2147483648. && f <= 2147483647. && f == Std.int(f);
						case _: false;
					};
					case "Float": switch (v) { case VInt(_) | VFloat(_): true; case _: false; };
					case "Bool": switch (v) { case VTrue | VFalse: true; case _: false; };
					case "String": switch (v) { case VString(_): true; case _: false; };
					case "Array": switch (v) { case VArray(_): true; case _: false; };
					case "eval.Vector": switch (v) { case VVector(_): true; case _: false; };
					case "Class": switch (v) { case VPrototype(p): switch (p.pkind) { case PClass(_): true; case _: false; }; case VInstance(vi): vi.iproto.ppath == EvalHash.key_Class; case _: false; };
					case "Enum": switch (v) { case VPrototype(p): switch (p.pkind) { case PEnum(_): true; case _: false; }; case _: false; };
					case "EnumValue": switch (v) { case VEnumValue(_): true; case _: false; };
					case _: switch (v) {
						case VInstance(vi): isSubProto(vi.iproto, proto.ppath);
						case VEnumValue(ev): ev.epath == proto.ppath;
						case _: false;
					};
				};
			case _: false;
		};
	}

	static function stdIsOfTypeCtx(ctx:EvalContext, v:EvalValue, t:EvalValue):Bool {
		return switch ([v, t]) {
			case [VInstance(vi), VPrototype(proto)] if (classHierarchyHas(ctx, vi.iproto.ppath, proto.ppath)):
				true;
			case _:
				stdIsOfType(v, t);
		};
	}

	static function stdDowncast(ctx:EvalContext, v:EvalValue, t:EvalValue):EvalValue {
		return switch (t) {
			case VPrototype(_): stdIsOfTypeCtx(ctx, v, t) ? v : VNull;
			case _: VFalse;
		};
	}

	public static function isOfTypePath(ctx:EvalContext, v:EvalValue, path:Int):Bool {
		var proto = ctx.staticPrototypes.get(path);
		if (proto == null) {
			proto = new VPrototype(path, [], new Map(), [], new Map(), null, PClass([]), VNull);
			proto.pvalue = VPrototype(proto);
			ctx.staticPrototypes.set(path, proto);
		}
		return stdIsOfTypeCtx(ctx, v, VPrototype(proto));
	}

	static function applyFn(fn:EvalValue, args:Array<EvalValue>):EvalValue {
		return switch (fn) {
			case VFunction(f, _): f(args);
			case VFieldClosure(recv, f): f([recv].concat(args));
			case _: VNull;
		};
	}

	// Type.typeof builds a ValueType enum value; constructor indices match the std declaration
	// order (TNull,TInt,TFloat,TBool,TObject,TFunction,TClass,TEnum,TUnknown).
	static function typeofValue(ctx:EvalContext, v:EvalValue):EvalValue {
		// Type.typeof and Type.getClass go through the same static-prototype value lookup, so the class
		// here is the one Type.getClass gives, a synthetic prototype's (haxe.macro.Position) included; a
		// bare static-prototype lookup would leave that TClass(null).
		function classVal(path:Int):EvalValue {
			return switch (classValue(ctx, path)) {
				case VNull: coreClassValue(ctx, path);
				case cv: cv;
			};
		}
		var idx:Int;
		var args:Array<EvalValue> = [];
		switch (v) {
			case VNull: idx = 0;
			case VInt(_): idx = 1;
			case VFloat(_): idx = 2;
			case VTrue | VFalse: idx = 3;
			case VObject(_) | VPrototype(_): idx = 4;
			case VFunction(_, _) | VFieldClosure(_, _): idx = 5;
			case VString(_): idx = 6; args = [classVal(EvalHash.hash("String"))];
			case VArray(_): idx = 6; args = [classVal(EvalHash.hash("Array"))];
			case VInstance(vi): idx = 6; args = [classVal(vi.iproto.ppath)];
			case VEnumValue(ev): idx = 7; args = [classVal(ev.epath)];
			case _: idx = 8;
		}
		return VEnumValue(new VEnumValue(idx, args, EvalHash.hash("ValueType"), null));
	}

	static var gcMinorHeapSize = 262144;
	static var gcMajorHeapIncrement = 15;
	static var gcSpaceOverhead = 80;
	static var gcVerbose = 0;
	static var gcMaxOverhead = 500;
	static var gcStackLimit = 1048576;
	static var gcAllocationPolicy = 0;
	static var gcMinorCollections = 0;
	static var gcMajorCollections = 0;
	static var gcCompactions = 0;

	static function gcCurrentBytes():Float {
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_CURRENT);
		#else
		return 0;
		#end
	}

	static function gcUsedBytes():Float {
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		#else
		return 0;
		#end
	}

	static function gcWordCount(bytes:Float):Int {
		return Std.int(bytes / 8);
	}

	static function gcMinor():Void {
		gcMinorCollections++;
		#if cpp
		cpp.vm.Gc.run(false);
		#end
	}

	static function gcMajor():Void {
		gcMinorCollections++;
		gcMajorCollections++;
		#if cpp
		cpp.vm.Gc.run(true);
		#end
	}

	static function gcCompact():Void {
		gcMajor();
		gcCompactions++;
		#if cpp
		cpp.vm.Gc.compact();
		#end
	}

	static function gcMajorSlice(n:EvalValue):EvalValue {
		gcMajor();
		return VInt(0);
	}

	static function gcCounters():EvalValue {
		var words = gcWordCount(gcCurrentBytes());
		return mkObject([
			{name: "minor_words", value: VFloat(words)},
			{name: "promoted_words", value: VFloat(0)},
			{name: "major_words", value: VFloat(words)}
		]);
	}

	static function gcStats():EvalValue {
		var used = gcWordCount(gcUsedBytes());
		var current = gcWordCount(gcCurrentBytes());
		return mkObject([
			{name: "minor_words", value: VFloat(current)},
			{name: "promoted_words", value: VFloat(0)},
			{name: "major_words", value: VFloat(current)},
			{name: "minor_collections", value: VInt(gcMinorCollections)},
			{name: "major_collections", value: VInt(gcMajorCollections)},
			{name: "heap_words", value: VInt(current)},
			{name: "heap_chunks", value: VInt(current == 0 ? 0 : 1)},
			{name: "live_words", value: VInt(used)},
			{name: "live_blocks", value: VInt(0)},
			{name: "free_words", value: VInt(0)},
			{name: "free_blocks", value: VInt(0)},
			{name: "largest_free", value: VInt(0)},
			{name: "fragments", value: VInt(0)},
			{name: "compactions", value: VInt(gcCompactions)},
			{name: "top_heap_words", value: VInt(current)},
			{name: "stack_size", value: VInt(0)}
		]);
	}

	static function gcControl():EvalValue {
		return mkObject([
			{name: "minor_heap_size", value: VInt(gcMinorHeapSize)},
			{name: "major_heap_increment", value: VInt(gcMajorHeapIncrement)},
			{name: "space_overhead", value: VInt(gcSpaceOverhead)},
			{name: "verbose", value: VInt(gcVerbose)},
			{name: "max_overhead", value: VInt(gcMaxOverhead)},
			{name: "stack_limit", value: VInt(gcStackLimit)},
			{name: "allocation_policy", value: VInt(gcAllocationPolicy)}
		]);
	}

	static function gcField(ctx:EvalContext, r:EvalValue, name:String, current:Int):Int {
		var v = EvalField.dynamicField(ctx, r, EvalHash.hash(name));
		return v == VNull ? current : toInt(v);
	}

	public static function init(ctx:EvalContext):Void {
		evalContext = ctx;
		threadEventHandlers = new Map();
		threadEventHandlerNextId = 1;
		macroMessages = [];
		var s = ctx.builtins.staticBuiltins;
		EvalIntegers.init(ctx, s);
		#if (cpp && !emscripten)
		// libuv is unavailable on Emscripten.
		EvalLuv.init(ctx, s);
		// mbedtls is unavailable on Emscripten.
		EvalSsl.initConstructors(ctx);
		EvalSsl.initFields(ctx);
		#end

		reg(s, "Math", "PI", VFloat(Math.PI));
		reg(s, "Math", "NaN", VFloat(hostNan));
		reg(s, "Math", "POSITIVE_INFINITY", VFloat(Math.POSITIVE_INFINITY));
		reg(s, "Math", "NEGATIVE_INFINITY", VFloat(Math.NEGATIVE_INFINITY));
		// Math: an argument is num (a value that is not a number is unexpected), an Int passes floor,
		// ceil, round and abs as itself, and the arguments of one call are decoded right to left.
		reg(s, "Math", "floor", vfn(a -> switch (arg(a, 0)) {
			case v = VInt(_): v;
			case v: VInt(evalMathInt(Math.ffloor(num(ctx, v))));
		}));
		reg(s, "Math", "ceil", vfn(a -> switch (arg(a, 0)) {
			case v = VInt(_): v;
			case v: VInt(evalMathInt(Math.fceil(num(ctx, v))));
		}));
		reg(s, "Math", "round", vfn(a -> switch (arg(a, 0)) {
			case v = VInt(_): v;
			case v: VInt(evalMathInt(Math.ffloor(num(ctx, v) + 0.5)));
		}));
		// Abs keeps the minimum Int as it is.
		reg(s, "Math", "abs", vfn(a -> switch (arg(a, 0)) {
			case VInt(i): VInt(i < 0 && i != 0x80000000 ? -i : i);
			case VFloat(f): VFloat(Math.abs(f));
			case v: EvalExceptions.unexpectedValue(ctx, v, "number");
		}));
		reg(s, "Math", "sqrt", vfn(a -> {
			var v = num(ctx, arg(a, 0));
			VFloat(v < 0 ? hostNan : Math.sqrt(v));
		}));
		reg(s, "Math", "pow", vfn(a -> {
			var y = num(ctx, arg(a, 1));
			VFloat(Math.pow(num(ctx, arg(a, 0)), y));
		}));
		reg(s, "Math", "min", vfn(a -> {
			var x = num(ctx, arg(a, 0));
			var y = num(ctx, arg(a, 1));
			VFloat(x < y ? x : Math.isNaN(x) ? x : y);
		}));
		reg(s, "Math", "max", vfn(a -> {
			var x = num(ctx, arg(a, 0));
			var y = num(ctx, arg(a, 1));
			VFloat(x < y ? y : Math.isNaN(y) ? y : x);
		}));
		reg(s, "Math", "log", vfn(a -> VFloat(Math.log(num(ctx, arg(a, 0))))));
		reg(s, "Math", "exp", vfn(a -> VFloat(Math.exp(num(ctx, arg(a, 0))))));
		reg(s, "Math", "sin", vfn(a -> VFloat(Math.sin(num(ctx, arg(a, 0))))));
		reg(s, "Math", "cos", vfn(a -> VFloat(Math.cos(num(ctx, arg(a, 0))))));
		reg(s, "Math", "tan", vfn(a -> VFloat(Math.tan(num(ctx, arg(a, 0))))));
		reg(s, "Math", "asin", vfn(a -> VFloat(Math.asin(num(ctx, arg(a, 0))))));
		reg(s, "Math", "acos", vfn(a -> VFloat(Math.acos(num(ctx, arg(a, 0))))));
		reg(s, "Math", "atan", vfn(a -> VFloat(Math.atan(num(ctx, arg(a, 0))))));
		reg(s, "Math", "ffloor", vfn(a -> VFloat(Math.ffloor(num(ctx, arg(a, 0))))));
		reg(s, "Math", "fceil", vfn(a -> VFloat(Math.fceil(num(ctx, arg(a, 0))))));
		reg(s, "Math", "fround", vfn(a -> VFloat(Math.ffloor(num(ctx, arg(a, 0)) + 0.5))));
		reg(s, "Math", "atan2", vfn(a -> {
			var x = num(ctx, arg(a, 1));
			VFloat(Math.atan2(num(ctx, arg(a, 0)), x));
		}));
		// A value that is not a float is finite, and one that is not a number is NaN.
		reg(s, "Math", "isNaN", vfn(a -> switch (arg(a, 0)) {
			case VFloat(f): EvalValueTools.vbool(Math.isNaN(f));
			case VInt(_): EvalValueTools.vbool(false);
			case _: EvalValueTools.vbool(true);
		}));
		reg(s, "Math", "isFinite", vfn(a -> switch (arg(a, 0)) {
			case VFloat(f): EvalValueTools.vbool(Math.isFinite(f));
			case _: EvalValueTools.vbool(true);
		}));
		reg(s, "Math", "random", vfn(a -> VFloat(Math.random())));
		// fromCharCode encodes any code the UTF-8 encoder takes, past U+10FFFF and surrogates included.
		reg(s, "String", "fromCharCode", vfn(a -> VString(EvalString.fromCharCode(decodeInt(ctx, arg(a, 0))))));
		// StringTools has natives for fastCodeAt (String.charCodeAt), replace, urlEncode and urlDecode
		// only; the other StringTools functions, unsafeCodeAt included, are the std's Haxe code, run with
		// its own frames and verdicts.
		reg(s, "StringTools", "fastCodeAt", vfn(a -> stdStringCharCodeAt(ctx, a)));
		// By, sub and s are decoded (decodeVString), in that order.
		reg(s, "StringTools", "replace", vfn(a -> {
			var by = decodeVString(ctx, arg(a, 2));
			var sub = decodeVString(ctx, arg(a, 1));
			var s1 = decodeVString(ctx, arg(a, 0));
			var blS = s1.sstring.length;
			var buf = new ByteBuffer();
			var replaceCount = 0;
			function create():EvalValue
				return VString(EvalString.createWithLength(buf.contents(), s1.slength + by.slength * replaceCount - sub.slength * replaceCount));
			if (sub.slength == 0) {
				if (by.slength == 0) arg(a, 0)
				else {
					Utf8.iter(s1.sstring, uc -> {
						Utf8.addUchar(buf, uc);
						// "don't add for the final char"
						if (replaceCount != s1.slength - 1) {
							buf.addString(by.sstring);
							replaceCount++;
						}
					});
					create();
				}
			} else {
				var f = EvalString.findSubstring(s1, sub, false);
				var cIndex = 0, bIndex = 0;
				while (true) {
					var hit = f(cIndex, bIndex);
					if (hit == null) {
						buf.addString(s1.sstring.sub(bIndex, blS - bIndex));
						break;
					}
					buf.addString(s1.sstring.sub(bIndex, hit.b - bIndex));
					buf.addString(by.sstring);
					replaceCount++;
					cIndex = hit.c + sub.slength;
					bIndex = hit.next;
				}
				create();
			}
		}));
		reg(s, "StringTools", "urlEncode", vfn(a -> EvalString.createUnknown(urlEncode(decodeString(ctx, arg(a, 0))))));
		reg(s, "StringTools", "urlDecode", vfn(a -> VString(urlDecode(ctx, decodeString(ctx, arg(a, 0))))));
		// The bound is decoded by decodeI32.
		reg(s, "Std", "random", vfn(a -> VInt(Std.random(decodeI32(ctx, arg(a, 0))))));
		reg(s, "Std", "isOfType", vfn(a -> EvalValueTools.vbool(stdIsOfTypeCtx(ctx, arg(a, 0), arg(a, 1)))));
		reg(s, "Std", "is", vfn(a -> EvalValueTools.vbool(stdIsOfTypeCtx(ctx, arg(a, 0), arg(a, 1)))));
		reg(s, "Std", "downcast", vfn(a -> stdDowncast(ctx, arg(a, 0), arg(a, 1))));
		reg(s, "Std", "instance", vfn(a -> stdDowncast(ctx, arg(a, 0), arg(a, 1))));

		reg(s, "Std", "int", vfn(a -> stdInt(arg(a, 0))));
		// A string as it is, anything else printed (sValue).
		reg(s, "Std", "string", vfn(a -> switch (arg(a, 0)) {
			case VString(_): arg(a, 0);
			case v: VString(sValue(v, 0));
		}));
		// The decode is inside the native's own handler, so a value that is not a string answers null
		// and NaN.
		reg(s, "Std", "parseInt", vfn(a -> switch (arg(a, 0)) {
			case VString(_): stdParseInt(stringOf(arg(a, 0)));
			case _: VNull;
		}));
		reg(s, "Std", "parseFloat", vfn(a -> switch (arg(a, 0)) {
			case VString(_): VFloat(stdParseFloat(stringOf(arg(a, 0))));
			case _: VFloat(hostNan);
		}));
		reg(s, "haxe.Log", "trace", vfn(a -> { writeStdoutString(traceString(ctx, arg(a, 0), arg(a, 1)), false); VNull; }));
		reg(s, "Sys", "println", vfn(a -> { writeStdoutString(valueString(arg(a, 0)), true); VNull; }));
		reg(s, "Sys", "print", vfn(a -> { writeStdoutString(valueString(arg(a, 0)), false); VNull; }));
		// The compilation's sys args, not the host process's own argv.
		reg(s, "Sys", "args", vfn(a -> {
			var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
			var args = com == null ? [] : [for (s in com.sysArgs) mkStr(s)];
			VArray(new VArray(args, args.length));
		}));
		reg(s, "Sys", "_command", vfn(a -> {
			var cmd = decodeText(ctx, arg(a, 0));
			// The command runs as the compiler runs one: its output relayed as it comes, and its two thread
			// joins let the interpreter's other threads run meanwhile.
			var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
			gilBlocking(() -> VInt(hxc.Compiler.runCommand(com, cmd)));
		}));
		reg(s, "Sys", "cpuTime", vfn(a -> VFloat(Sys.cpuTime())));
		// The process environment, each entry split at its first '=' (so a drive entry
		// "=C:=C:\\dir" is under the key "")
		reg(s, "Sys", "environment", vfn(a -> {
			var m = new Map<String, String>();
			for (e in processEnvironment()) {
				var i = e.indexOf("=");
				if (i < 0) throw new hxc.eval.EvalExceptions.HostException("ExtString.Invalid_string");
				m.set(e.substr(0, i), e.substr(i + 1));
			}
			mkStringMap(ctx, m);
		}));
		// Sys.exit raises an exit exception; the compiler marks the compile failed for a non-zero code
		// and flushes the message list before returning it. Exiting the host process here would throw away
		// every warning a macro had queued, including the ones explaining why it was exiting.
		reg(s, "Sys", "exit", vfn(a -> throw new hxc.eval.EvalExceptions.EvalSysExit(decodeInt(ctx, arg(a, 0)))));
		reg(s, "Sys", "getCwd", vfn(a -> mkStr(Sys.getCwd())));
		// Getenv, over the process environment block
		reg(s, "Sys", "getEnv", vfn(a -> {
			var v = processGetEnv(decodeText(ctx, arg(a, 0)));
			v == null ? VNull : mkStr(v);
		}));
		reg(s, "Sys", "getChar", vfn(a -> VInt(Sys.getChar(decodeBool(ctx, arg(a, 0))))));
		reg(s, "Sys", "programPath", vfn(a -> sysProgramPath(ctx)));
		// A null value unsets the variable.
		reg(s, "Sys", "putEnv", vfn(a -> {
			var name = decodeText(ctx, arg(a, 0));
			Sys.putEnv(name, arg(a, 1) == VNull ? null : decodeText(ctx, arg(a, 1)));
			VNull;
		}));
		// A chdir failure is a Unix error.
		reg(s, "Sys", "setCwd", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			var err = cFs(4, path);
			if (err != null) unixError(ctx, err, "chdir", path);
			VNull;
		}));
		reg(s, "Sys", "setTimeLocale", vfn(a -> VFalse));
		reg(s, "Sys", "sleep", vfn(a -> { var t = num(ctx, arg(a, 0)); gilBlocking(function() { Sys.sleep(t); return VNull; }); }));
		// Stderr: a FileOutput over the runtime's stderr channel, whose writes wait in its buffer until a
		// flush.
		reg(s, "Sys", "stderr", vfn(a -> mkOutput(ctx, new hxc.compiler.HostRuntime.HostStderrOutput(), null)));
		reg(s, "Sys", "stdin", vfn(a -> mkInput(ctx, Sys.stdin(), null)));
		reg(s, "Sys", "stdout", vfn(a -> mkOutput(ctx, Sys.stdout(), null)));
		reg(s, "Sys", "systemName", vfn(a -> mkStr(Sys.systemName())));
		reg(s, "Sys", "time", vfn(a -> VFloat(Sys.time())));
		reg(s, "haxe.NativeStackTrace", "_callStack", vfn(a -> callStackValue(ctx)));
		reg(s, "haxe.NativeStackTrace", "exceptionStack", vfn(a -> exceptionStackValue(ctx)));
		reg(s, "eval.vm.Gc", "allocated_bytes", vfn(a -> VFloat(gcCurrentBytes())));
		reg(s, "eval.vm.Gc", "compact", vfn(a -> { gcCompact(); VNull; }));
		reg(s, "eval.vm.Gc", "counters", vfn(a -> gcCounters()));
		reg(s, "eval.vm.Gc", "finalise", vfn(a -> VNull));
		reg(s, "eval.vm.Gc", "finalise_release", vfn(a -> VNull));
		reg(s, "eval.vm.Gc", "full_major", vfn(a -> { gcMajor(); VNull; }));
		reg(s, "eval.vm.Gc", "get", vfn(a -> gcControl()));
		reg(s, "eval.vm.Gc", "major", vfn(a -> { gcMajor(); VNull; }));
		reg(s, "eval.vm.Gc", "major_slice", vfn(a -> gcMajorSlice(arg(a, 0))));
		reg(s, "eval.vm.Gc", "minor", vfn(a -> { gcMinor(); VNull; }));
		reg(s, "eval.vm.Gc", "print_stat", vfn(a -> {
			var out = thisFileOutput([arg(a, 0)]).output;
			out.writeString("minor_words: " + stringOf(EvalField.dynamicField(ctx, gcStats(), EvalHash.hash("minor_words"))) + "\n");
			out.writeString("major_words: " + stringOf(EvalField.dynamicField(ctx, gcStats(), EvalHash.hash("major_words"))) + "\n");
			out.flush();
			VNull;
		}));
		reg(s, "eval.vm.Gc", "quick_stat", vfn(a -> gcStats()));
		reg(s, "eval.vm.Gc", "set", vfn(a -> {
			var r = arg(a, 0);
			gcMinorHeapSize = gcField(ctx, r, "minor_heap_size", gcMinorHeapSize);
			gcMajorHeapIncrement = gcField(ctx, r, "major_heap_increment", gcMajorHeapIncrement);
			gcSpaceOverhead = gcField(ctx, r, "space_overhead", gcSpaceOverhead);
			gcVerbose = gcField(ctx, r, "verbose", gcVerbose);
			gcMaxOverhead = gcField(ctx, r, "max_overhead", gcMaxOverhead);
			gcStackLimit = gcField(ctx, r, "stack_limit", gcStackLimit);
			gcAllocationPolicy = gcField(ctx, r, "allocation_policy", gcAllocationPolicy);
			VNull;
		}));
		reg(s, "eval.vm.Gc", "stat", vfn(a -> gcStats()));
		reg(s, "eval.vm.Context", "addBreakpoint", vfn(a -> {
			var file = stringOf(arg(a, 0));
			sys.FileSystem.exists(file) ? VNull : EvalExceptions.excString(ctx, "Could not find file " + file);
		}));
		reg(s, "eval.vm.Context", "breakHere", vfn(a -> VNull));
		reg(s, "eval.vm.Context", "callMacroApi", vfn(a -> callMacroApiValue(ctx, stringOf(arg(a, 0)))));
		registerAfterMacroApi(ctx, s);
	}

	// The load(name) macro-API surface, shared by eval.vm.Context.callMacroApi and the direct
	// haxe.macro.Context.load builtin registered for the macro world.
	public static function callMacroApiValue(ctx:EvalContext, name:String):EvalValue {
		{
			return switch (name) {
				case "define":
					VFunction(function(args) {
						var key = externalDefineKey(stringOf(arg(args, 0)));
						var value = arg(args, 1);
						if (value == VNull) ctx.defines.rawDefine(key);
						else ctx.defines.rawDefineValue(key, stringOf(value));
						return VNull;
					}, true);
				case "defined":
					VFunction(function(args) return ctx.defines.rawDefined(externalDefineKey(stringOf(arg(args, 0)))) ? VTrue : VFalse, true);
				case "defined_value":
					VFunction(function(args) {
						var key = externalDefineKey(stringOf(arg(args, 0)));
						return ctx.defines.rawDefined(key) ? mkStr(ctx.defines.rawDefinedValue(key)) : VNull;
					}, true);
				case "get_defines":
					// The API's com (the host's) defines with their external spellings; the interpreter's
					// own table
					// is not it.
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						return mkStringMap(ctx, definesForExternal(com.defines.values));
					}, true);
				case "class_path":
					VFunction(function(args) return valueArray([for (p in ctx.classPath) mkStr(p)]), true);
				case "resolve_path":
					// The file is decoded before the search.
					VFunction(function(args) return resolveMacroPath(ctx, decodeText(ctx, arg(args, 0))), true);
				case "error" | "fatal_error":
					VFunction(function(args) {
						var posValue = args.length > 1 ? arg(args, 1) : mkPos(ctx, EvalMacro.currentPosition());
						return EvalExceptions.throwValue(ctx, macroErrorValue(ctx, stringOf(arg(args, 0)), posValue), macroPosOf(posValue, EvalMacro.currentPosition()));
					}, true);
				case "report_error":
					VFunction(function(args) {
						var posValue = args.length > 1 ? arg(args, 1) : mkPos(ctx, EvalMacro.currentPosition());
						EvalMacro.reportError(stringOf(arg(args, 0)), macroPosOf(posValue, EvalMacro.currentPosition()));
						return VNull;
					}, true);
				// Warning/info/get_messages/filter_messages share the compiler's message list.
				case "warning":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var posValue = args.length > 1 ? arg(args, 1) : mkPos(ctx, EvalMacro.currentPosition());
						com.addDiagnostic(stringOf(arg(args, 0)), macroPosOf(posValue, EvalMacro.currentPosition()), 0, hxc.core.Globals.MessageSeverity.Warning);
						return VNull;
					}, true);
				case "info":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var posValue = args.length > 1 ? arg(args, 1) : mkPos(ctx, EvalMacro.currentPosition());
						com.addDiagnostic(stringOf(arg(args, 0)), macroPosOf(posValue, EvalMacro.currentPosition()), 0, hxc.core.Globals.MessageSeverity.Information);
						return VNull;
					}, true);
				case "get_messages":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var msgs = [for (d in com.diagnostics) if (!d.severity.match(Error)) macroMessage(ctx, d.severity.match(Warning) ? "Warning" : "Info", EvalString.vOfText(d.message), mkPos(ctx, d.pos))];
						return VArray(new VArray(msgs, msgs.length));
					}, true);
				case "filter_messages":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var pred = arg(args, 0);
						com.diagnostics = [for (d in com.diagnostics)
							if (d.severity.match(Error) || EvalMisc.isTrue(applyFn(pred, [macroMessage(ctx, d.severity.match(Warning) ? "Warning" : "Info", EvalString.vOfText(d.message), mkPos(ctx, d.pos))]))) d];
						return VNull;
					}, true);
				case "init_macros_done":
					VFunction(function(args) {
						var com = EvalMacro.hostCom != null ? EvalMacro.hostCom : ctx.com;
						return (com != null && com.initMacrosDone) ? VTrue : VFalse;
					}, true);
				case "current_pos":
					VFunction(function(args) return mkPos(ctx, EvalMacro.currentPosition()), true);
				case "get_macro_stack":
					VFunction(function(args) return macroStackValue(ctx), true);
				case "contains_display_position":
					VFunction(function(args) return VFalse, true);
				case "get_display_mode":
					VFunction(function(args) return createEnumByName(ctx, classValue(ctx, EvalHash.hash("haxe.macro.DisplayMode")), EvalHash.hash("None"), VNull), true);
				case "get_expected_type" | "get_call_arguments":
					VFunction(function(args) return VNull, true);
				case "get_local_using":
					VFunction(function(args) return EvalMacro.localUsingValue(ctx), true);
				case "get_local_imports":
					VFunction(function(args) return localImports(ctx), true);
				case "local_vars":
					VFunction(function(args) return EvalMacro.localVarsValue(ctx, arg(args, 0)), true);
				case "signature":
					// The value signature: haxe.Serializer's format with the value cache and enum indices,
					// and a
					// function serialized as a custom entity rather than refused.
					// The buffer is bytes, a native string's own included: digest them.
					VFunction(function(args) return mkStr(haxe.crypto.Md5.make(ByteString.ofRaw(serializeEval(ctx, arg(args, 0), true, true, true)).toBytes()).toHex()), true);
				case "add_resource":
					VFunction(function(args) {
						var name = stringOf(arg(args, 0));
						if (name == "") EvalExceptions.excString(ctx, "Empty resource name");
						var bytes = decodeBytes(arg(args, 1));
						ctx.resources.set(name, bytes.sub(0, bytes.length));
						return VNull;
					}, true);
				case "get_resources":
					VFunction(function(args) return mkStringBytesMap(ctx, ctx.resources), true);
				case "make_expr":
					VFunction(function(args) return EvalMacro.makeExprValueArgs(ctx, arg(args, 0), arg(args, 1)), true);
				case "add_global_metadata_impl":
					VFunction(function(args) return EvalMacro.addGlobalMetadataValue(ctx.com != null ? ctx.com : EvalMacro.hostCom, [for (i in 0...5) arg(args, i)]), true);
				case "type_patch":
					VFunction(function(args) return EvalMacro.typePatchValue(ctx.com != null ? ctx.com : EvalMacro.hostCom, [for (i in 0...4) arg(args, i)]), true);
				case "meta_patch":
					VFunction(function(args) return EvalMacro.metaPatchValue(ctx.com != null ? ctx.com : EvalMacro.hostCom, [for (i in 0...4) arg(args, i)]), true);
				case "allow_package":
					// The name is decoded first; then a Forbidden package rule for it is removed (any other
					// rule
					// stays).
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var name = decodeText(ctx, arg(args, 0));
						if (com.forbiddenPackages.exists(name)) com.forbiddenPackages.remove(name);
						return VNull;
					}, true);
				case "add_class_path":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var cp = decodeText(ctx, arg(args, 0));
						if (!StringTools.endsWith(cp, "/") && !StringTools.endsWith(cp, "\\")) cp += "/";
						com.classPath.unshift(cp);
						var mcom = EvalMacro.getMacroCom();
						if (mcom != null) mcom.classPath.unshift(cp);
						// The memo the two worlds share is cleared in place
						if (Sys.getEnv("HXC_DEBUG_TNF") != null) Sys.println("[tnf] CLEAR add_class_path");
						com.moduleNonexistentLut.clear();
						if (mcom != null && mcom.moduleNonexistentLut != com.moduleNonexistentLut) mcom.moduleNonexistentLut.clear();
						return VNull;
					}, true);
				case "get_output":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						return mkStr(com.file);
					}, true);
				case "set_output":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						com.file = stringOf(arg(args, 0));
						return VNull;
					}, true);
				case "get_display_pos":
					VFunction(function(args) return VNull, true);
				case "get_main_expr":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						return com.main == null ? VNull : EvalMacro.encodeTypedExpr(ctx, com.main);
					}, true);
				case "get_module_types":
					// The API's com.types, which only generation fills (Finalization.run) - empty while the
					// compilation is still typing.
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var types = com.typesGenerated ? [for (t in com.types) EvalMacro.encodeModuleType(ctx, t)] : [];
						return VArray(new VArray(types, types.length));
					}, true);
				case "s_expr":
					VFunction(function(args) {
						var e = EvalMacro.decodeTypedExpr(ctx, arg(args, 0));
						// Pretty prints the expression, the default dumps the tagged tree, both over one print
						// context.
						var pretty = arg(args, 1) == VTrue;
						var pctx = hxc.core.TPrinting.printContext();
						var st = function(t:hxc.core.Type.T):String return hxc.core.TPrinting.sType(pctx, t);
						var s = pretty
							? hxc.core.TPrinting.sExprPretty(false, "", false, st, e)
							: hxc.core.TPrinting.sExprAst(true, "", st, e);
						return mkStr(s);
					}, true);
				case "format_string":
					// MacroStringTools.formatString: single-quote interpolation desugared to concatenation.
					VFunction(function(args) {
						var s = stringOf(arg(args, 0));
						var p = switch (EvalValueTools.vresolve(arg(args, 1))) {
							case VInstance(vi): switch (vi.ikind) { case IPos(pp): pp; case _: Position.nullPos; }
							case _: Position.nullPos;
						};
						var host = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						return EvalMacro.encodeExpr(ctx, hxc.typing.Typer.formatString(s, p, host != null ? host.defines : null));
					}, true);
				case "on_null_safety_report":
					VFunction(function(args) {
						var f = arg(args, 0);
						var host = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						// The callback executes in its eval world (like generate callbacks do).
						host.nullSafetyReportCallbacks.push(function(errors) {
							var items:Array<EvalValue> = [for (e in errors) mkObject([
								{name: "msg", value: mkStr(e.msg)},
								{name: "pos", value: mkPos(ctx, e.pos)}
							])];
							var saved = EvalContext.getCtx();
							EvalContext.setCtx(ctx);
							try {
								callValueOn(VNull, f, [VArray(new VArray(items, items.length))]);
								EvalContext.setCtx(saved);
							} catch (e:Dynamic) {
								EvalContext.setCtx(saved);
								throw e;
							}
						});
						return VNull;
					}, true);
				case "get_configuration":
					VFunction(function(args) return EvalMacro.getConfigurationValue(ctx.com != null ? ctx.com : EvalMacro.hostCom, ctx), true);
				case "make_position":
					VFunction(function(args) return mkPos(ctx, new Position(stringOf(arg(args, 2)), toInt(arg(args, 0)), toInt(arg(args, 1)))), true);
				case "get_pos_infos":
					VFunction(function(args) return switch (EvalValueTools.vresolve(arg(args, 0))) {
						case VInstance(vi): switch (vi.ikind) {
							case IPos(p): posInfos(p);
							case _: EvalExceptions.excString(ctx, "Invalid expression");
						}
						case _: EvalExceptions.excString(ctx, "Invalid expression");
					}, true);
				case "timer":
					// A timer under the current one's id, closed by the function returned.
					VFunction(function(args) {
						var cur = hxc.core.Timer.currentId();
						var full = (cur == null ? [] : cur.copy()).concat([decodeText(ctx, arg(args, 0))]);
						var stop = hxc.core.Timer.timer(full);
						return VFunction(function(a2) { stop(); return VNull; }, true);
					}, true);
				case "flush_disk_cache":
					// The file lookup and readdir caches of the API's own com are cleared; a clone has
					// fresh ones.
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						com.readdirCache.clear();
						return VNull;
					}, true);
				case "add_native_lib":
					// The file is decoded, then only a flash, java or cs library is accepted and every
					// other
					// platform fails.
					VFunction(function(args) {
						var file = decodeText(ctx, arg(args, 0));
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						return EvalExceptions.excString(ctx, "Target " + hxc.core.Globals.platformName(com.platform)
							+ " does not support native libraries (trying to load " + file + ")");
					}, true);
				case "add_native_arg":
					// Java, cs and cpp prepend the argument to cArgs.
					VFunction(function(args) {
						var narg = decodeText(ctx, arg(args, 0));
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						return switch (com.platform) {
							case Java | Cs | Cpp: com.cArgs.unshift(narg); VNull;
							case _: EvalExceptions.excString(ctx, "Unsupported platform");
						}
					}, true);
				case _:
					EvalExceptions.excString(ctx, "Macro API not implemented: " + name);
			}
		}
	}

	static function registerAfterMacroApi(ctx:EvalContext, s:Map<Int, Array<BuiltinField>>):Void {
		reg(s, "eval.vm.Context", "loadPlugin", vfn(a ->
			EvalExceptions.excString(ctx, "error loading shared library: " + decodeText(ctx, arg(a, 0)))));

		var inst = ctx.builtins.instanceBuiltins;

		// String: the receiver and a string argument are `this`, an index is decodeInt and an optional
		// one defaultInt, each decoded in the native's order.
		reg(inst, "String", "charAt", vmethod(a -> {
			var self = thisString(ctx, a);
			var i = decodeInt(ctx, arg(a, 1));
			i < 0 || i >= self.slength ? EvalString.vEmptyString() : VString(EvalString.fromCharCode(EvalString.charAt(self, i)));
		}));
		reg(inst, "String", "charCodeAt", vmethod(a -> stdStringCharCodeAt(ctx, a)));
		reg(inst, "String", "cca", vmethod(a -> stdStringCharCodeAt(ctx, a)));
		reg(inst, "String", "indexOf", vmethod(a -> {
			var str = thisString(ctx, [arg(a, 1)]);
			var self = thisString(ctx, a);
			var i = defaultInt(ctx, arg(a, 2), 0);
			if (str.slength == 0) VInt(Std.int(Math.max(0, Math.min(i, self.slength))))
			else {
				if (i >= self.slength) VInt(-1)
				else {
					if (i < 0) i = Std.int(Math.max(self.slength + i, 0));
					var b = EvalString.getOffset(self, i);
					var hit = EvalString.findSubstring(self, str, false)(i, b);
					VInt(hit == null ? -1 : hit.c);
				}
			}
		}));
		reg(inst, "String", "lastIndexOf", vmethod(a -> {
			var str = thisString(ctx, [arg(a, 1)]);
			var self = thisString(ctx, a);
			if (str.slength == 0) {
				var i = defaultInt(ctx, arg(a, 2), self.slength);
				VInt(Std.int(Math.max(0, Math.min(i, self.slength))));
			} else {
				var i = defaultInt(ctx, arg(a, 2), self.slength - str.slength);
				if (i < 0) VInt(-1)
				else {
					if (i >= self.slength - str.slength) i = self.slength - str.slength;
					var b = EvalString.getOffset(self, i);
					var hit = EvalString.findSubstring(self, str, true)(i, b);
					VInt(hit == null ? -1 : hit.c);
				}
			}
		}));
		reg(inst, "String", "toUpperCase", vmethod(a -> VString(EvalString.caseMap(thisString(ctx, a), true))));
		reg(inst, "String", "toLowerCase", vmethod(a -> VString(EvalString.caseMap(thisString(ctx, a), false))));
		reg(inst, "String", "substr", vmethod(a -> stdStringSubstr(ctx, a)));
		reg(inst, "String", "substring", vmethod(a -> {
			var self = thisString(ctx, a);
			var cFirst = decodeInt(ctx, arg(a, 1));
			var clThis = self.slength;
			var cLast = defaultInt(ctx, arg(a, 2), clThis);
			if (cFirst < 0) cFirst = 0;
			if (cLast < 0) cLast = 0;
			if (cFirst > cLast) {
				var t = cFirst;
				cFirst = cLast;
				cLast = t;
			}
			if (cLast > clThis) cLast = clThis;
			if (cFirst > clThis || cFirst == cLast) EvalString.vEmptyString()
			else {
				var bOffset1 = EvalString.getOffset(self, cFirst);
				var cLen = cLast - cFirst;
				var bLen = cLast == clThis ? self.sstring.length - bOffset1 : Utf8.move(self.sstring, bOffset1, cLen) - bOffset1;
				VString(EvalString.createWithLength(self.sstring.sub(bOffset1, bLen), cLen));
			}
		}));
		reg(inst, "String", "split", vmethod(a -> {
			var self = thisString(ctx, a);
			var s = self.sstring;
			var delimiter = decodeVString(ctx, arg(a, 1));
			var blDelimiter = delimiter.sstring.length;
			var blThis = s.length;
			function encodeRange(pos:Int, length:Int, clength:Int):EvalValue
				return VString(EvalString.createWithLength(s.sub(pos, length), clength));
			var acc:Array<EvalValue> = [];
			if (blDelimiter == 0) {
				Utf8.iter(s, uc -> acc.push(VString(EvalString.createWithLength(Utf8.encode(uc), 1))));
			} else if (blDelimiter > blThis) {
				acc.push(encodeRange(0, blThis, self.slength));
			} else {
				var f = EvalString.findSubstring(self, delimiter, false);
				var cIndex = 0, bIndex = 0;
				while (true) {
					var hit = f(cIndex, bIndex);
					if (hit == null) {
						acc.push(encodeRange(bIndex, blThis - bIndex, self.slength - cIndex));
						break;
					}
					acc.push(encodeRange(bIndex, hit.b - bIndex, hit.c - cIndex));
					cIndex = hit.c + delimiter.slength;
					bIndex = hit.next;
				}
			}
			VArray(new VArray(acc, acc.length));
		}));
		reg(inst, "String", "toString", vmethod(a -> arg(a, 0)));

		reg(inst, "Array", "push", vmethod(a -> {
			var va = thisArray(ctx, a);
			VInt(arrayPush(va, arg(a, 1)));
		}));
		reg(inst, "Array", "pop", vmethod(a -> {
			var va = thisArray(ctx, a);
			if (va.alength == 0) VNull;
			else {
				var v = va.avalues[va.alength - 1];
				va.avalues[va.alength - 1] = VNull;
				va.alength--;
				v;
			}
		}));
		reg(inst, "Array", "concat", vmethod(a -> {
			var other = thisArray(ctx, [arg(a, 1)]);
			var va = thisArray(ctx, a);
			var out = arrayLive(va).concat(arrayLive(other));
			VArray(new VArray(out, out.length));
		}));
		reg(inst, "Array", "join", vmethod(a -> {
			// Join: this, then the separator; the elements joined over sValue.
			var va = thisArray(ctx, a);
			var sep = decodeVString(ctx, arg(a, 1));
			VString(EvalString.join(sep, [for (i in 0...va.alength) sValue(va.avalues[i], 0)]));
		}));
		reg(inst, "Array", "indexOf", vmethod(a -> {
			var va = thisArray(ctx, a);
			var target = arg(a, 1);
			var fromIndex = defaultInt(ctx, arg(a, 2), 0);
			if (fromIndex < 0) fromIndex = va.alength + fromIndex;
			if (fromIndex < 0) fromIndex = 0;
			var idx = -1;
			for (i in fromIndex...va.alength) if (EvalValueTools.equals(va.avalues[i], target)) {
				idx = i;
				break;
			}
			VInt(idx);
		}));
		reg(inst, "Array", "toString", vmethod(a -> {
			var va = thisArray(ctx, a);
			// The elements print at depth 0.
			VString(EvalString.join(EvalString.emptyString(), [
				ascii("["),
				EvalString.join(ascii(","), [for (i in 0...va.alength) sValue(va.avalues[i], 0)]),
				ascii("]")
			]));
		}));
		reg(inst, "Array", "iterator", vmethod(a -> arrayIteratorValue(ctx, a[0])));
		reg(inst, "Array", "keyValueIterator", vmethod(a -> EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.iterators.ArrayKeyValueIterator"), [a[0]])));
		reg(inst, "Array", "slice", vmethod(a -> {
			var va = thisArray(ctx, a);
			var length = va.alength;
			var pos = decodeInt(ctx, arg(a, 1));
			var end = defaultInt(ctx, arg(a, 2), length);
			if (end > length) end = length;
			if (pos < 0) pos = length + pos;
			if (end < 0) end = length + end;
			if (pos < 0) pos = 0;
			if (end < 0) end = 0;
			var sub = arrayLive(va).slice(pos, end);
			VArray(new VArray(sub, sub.length));
		}));
		reg(inst, "Array", "splice", vmethod(a -> {
			var va = thisArray(ctx, a);
			var pos = decodeInt(ctx, arg(a, 1));
			var len = decodeInt(ctx, arg(a, 2));
			var length = va.alength;
			if (len < 0 || pos > length) {
				VArray(new VArray([], 0));
			} else {
				if (pos < 0) pos = length + pos;
				if (pos < 0) pos = 0;
				var delta = length - pos;
				if (len > delta) len = delta;
				var removed = [for (i in 0...len) va.avalues[pos + i]];
				for (i in 0...(length - pos - len)) va.avalues[pos + i] = va.avalues[pos + len + i];
				va.alength -= len;
				VArray(new VArray(removed, removed.length));
			}
		}));
		reg(inst, "Array", "reverse", vmethod(a -> {
			var va = thisArray(ctx, a);
			va.avalues = arrayLive(va);
			va.avalues.reverse();
			VNull;
		}));
		reg(inst, "Array", "sort", vmethod(a -> {
			var va = thisArray(ctx, a); var cmp = arg(a, 1);
			va.avalues = arrayLive(va);
			// The comparator is called on the receiver and its answer decoded by decodeInt.
			stableArraySort(va.avalues, (x, y) -> decodeInt(ctx, callValueOn(a[0], cmp, [x, y])));
			VNull;
		}));
		reg(inst, "Array", "contains", vmethod(a -> {
			var va = thisArray(ctx, a); var t = arg(a, 1); var found = false;
			for (i in 0...va.alength) if (EvalValueTools.equals(va.avalues[i], t)) { found = true; break; }
			EvalValueTools.vbool(found);
		}));
		reg(inst, "Array", "filter", vmethod(a -> {
			var va = thisArray(ctx, a); var fn = arg(a, 1); var out:Array<EvalValue> = [];
			for (i in 0...va.alength) {
				var v = va.avalues[i];
				if (EvalMisc.isTrue(callValueOn(a[0], fn, [v]))) out.push(v);
			}
			VArray(new VArray(out, out.length));
		}));
		reg(inst, "Array", "map", vmethod(a -> {
			var va = thisArray(ctx, a); var fn = mapCallback(ctx, arg(a, 1)); var out:Array<EvalValue> = [];
			for (i in 0...va.alength) out.push(fn(va.avalues[i]));
			VArray(new VArray(out, out.length));
		}));
		reg(inst, "Array", "copy", vmethod(a -> { var va = thisArray(ctx, a); var out = arrayLive(va); VArray(new VArray(out, out.length)); }));
		reg(inst, "Array", "remove", vmethod(a -> {
			var va = thisArray(ctx, a); var t = arg(a, 1); var idx = -1;
			for (i in 0...va.alength) if (EvalValueTools.equals(va.avalues[i], t)) { idx = i; break; }
			if (idx >= 0) { arrayRemoveAt(va, idx); EvalValueTools.vbool(true); } else EvalValueTools.vbool(false);
		}));
		reg(inst, "Array", "insert", vmethod(a -> {
			var va = thisArray(ctx, a);
			var pos = decodeInt(ctx, arg(a, 1));
			if (pos >= va.alength) {
				arrayPush(va, arg(a, 2));
			} else {
				if (pos < 0) pos = va.alength + pos;
				if (pos < 0) pos = 0;
				arrayInsert(va, pos, arg(a, 2));
			}
			VNull;
		}));
		reg(inst, "Array", "shift", vmethod(a -> {
			var va = thisArray(ctx, a);
			if (va.alength == 0) VNull else {
				var v = va.avalues[0];
				va.alength--;
				for (i in 0...va.alength) va.avalues[i] = va.avalues[i + 1];
				v;
			}
		}));
		reg(inst, "Array", "unshift", vmethod(a -> {
			var va = thisArray(ctx, a);
			if (va.alength + 1 >= va.avalues.length) {
				var old = va.avalues;
				va.avalues = [for (_ in 0...(old.length * 2 + 5)) VNull];
				for (i in 0...va.alength) va.avalues[i + 1] = old[i];
			} else {
				var i = va.alength;
				while (i > 0) {
					va.avalues[i] = va.avalues[i - 1];
					i--;
				}
			}
			va.avalues[0] = arg(a, 1);
			va.alength++;
			VNull;
		}));
		reg(inst, "Array", "lastIndexOf", vmethod(a -> {
			var va = thisArray(ctx, a); var t = arg(a, 1); var idx = -1; var last = va.alength - 1;
			var i = defaultInt(ctx, arg(a, 2), last);
			if (va.alength == 0) return VInt(-1);
			if (i < 0) i = va.alength + i;
			if (i < 0) i = 0 else if (i > last) i = last;
			while (i >= 0) { if (EvalValueTools.equals(va.avalues[i], t)) { idx = i; break; } i--; }
			VInt(idx);
		}));
		reg(inst, "Array", "resize", vmethod(a -> {
			var va = thisArray(ctx, a); var len = decodeInt(ctx, arg(a, 1));
			if (len < 0) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("Array.fill")');
			if (va.alength < len) arraySet(va, len - 1, VNull);
			else if (va.alength > len) {
				for (i in len...va.alength) va.avalues[i] = VNull;
				va.alength = len;
			}
			VNull;
		}));

		reg(s, "eval.Vector", "fromArrayCopy", vfn(a -> {
			var va = thisArray(ctx, [arg(a, 0)]);
			VVector(va.avalues.slice(0, va.alength));
		}));
		reg(inst, "eval.Vector", "blit", vmethod(a -> {
			// The arguments of one call, decoded right to left.
			var len = decodeInt(ctx, arg(a, 4));
			var destPos = decodeInt(ctx, arg(a, 3));
			var dest = thisVector(ctx, [arg(a, 2)]);
			var srcPos = decodeInt(ctx, arg(a, 1));
			var src = thisVector(ctx, [arg(a, 0)]);
			var tmp = src.slice(srcPos, srcPos + len);
			for (i in 0...len) dest[destPos + i] = tmp[i];
			VNull;
		}));
		reg(inst, "eval.Vector", "toArray", vmethod(a -> {
			var vv = thisVector(ctx, a);
			VArray(new VArray(vv.copy(), vv.length));
		}));
		reg(inst, "eval.Vector", "copy", vmethod(a -> VVector(thisVector(ctx, a).copy())));
		reg(inst, "eval.Vector", "join", vmethod(a -> {
			// The separator, then this.
			var sep = decodeVString(ctx, arg(a, 1));
			var vv = thisVector(ctx, a);
			VString(EvalString.join(sep, [for (v in vv) sValue(v, 0)]));
		}));
		reg(inst, "eval.Vector", "map", vmethod(a -> {
			var vv = thisVector(ctx, a);
			var fn = mapCallback(ctx, arg(a, 1));
			VVector([for (v in vv) fn(v)]);
		}));

		reg(s, "Reflect", "fields", vfn(a -> {
			// Any other value is unexpected, a function included.
			var o = EvalValueTools.vresolve(arg(a, 0));
			switch (o) {
				case VObject(_) | VInstance(_) | VPrototype(_) | VNull | VString(_) | VArray(_) | VVector(_):
				case _: EvalExceptions.unexpectedValue(ctx, arg(a, 0), "object");
			}
			var names = fieldNames(o);
			VArray(new VArray([for (n in names) mkStr(n)], names.length));
		}));
		// Reflect: a field name is decodeVString; field and getProperty answer null for a null object
		// before looking at it.
		reg(s, "Reflect", "field", vfn(a -> {
			var o = arg(a, 0);
			if (o == VNull) VNull else {
				var name = EvalHash.hash(decodeVString(ctx, arg(a, 1)).sstring.toText());
				switch (EvalValueTools.vresolve(o)) {
					case VPrototype(proto) if (isReflectHidden(proto.ppath, name, true)): VNull;
					case VInstance(vi) if (isReflectHidden(vi.iproto.ppath, name, false)): VNull;
					case _: EvalField.dynamicField(ctx, o, name);
				}
			}
		}));
		reg(s, "Reflect", "setField", vfn(a -> {
			reflectSetField(ctx, arg(a, 0), EvalHash.hash(decodeVString(ctx, arg(a, 1)).sstring.toText()), arg(a, 2));
			VNull;
		}));
		reg(s, "Reflect", "hasField", vfn(a -> {
			var name = EvalHash.hash(decodeVString(ctx, arg(a, 1)).sstring.toText());
			EvalValueTools.vbool(hasField(ctx, arg(a, 0), name));
		}));
		reg(s, "Reflect", "isFunction", vfn(a -> EvalValueTools.vbool(switch (arg(a, 0)) {
			case VFunction(_, _) | VFieldClosure(_, _): true;
			case _: false;
		})));
		reg(s, "Reflect", "compare", vfn(a -> VInt(switch (EvalMisc.compare(arg(a, 0), arg(a, 1))) {
			case CEq: 0;
			case CInf: -1;
			case CSup: 1;
			case CUndef: -1;
		})));
		reg(s, "Reflect", "compareMethods", vfn(a -> EvalValueTools.vbool(compareMethodsValue(arg(a, 0), arg(a, 1)))));
		reg(s, "Reflect", "copy", vfn(a -> switch (EvalValueTools.vresolve(arg(a, 0))) {
			// Reflect.copy: only an object, an instance, a string, an array or a vector copies.
			case VNull | VObject(_) | VInstance(_) | VString(_) | VArray(_) | VVector(_): copyValue(arg(a, 0));
			case _: EvalExceptions.unexpectedValue(ctx, arg(a, 0), "object");
		}));
		reg(s, "Reflect", "deleteField", vfn(a -> {
			var name = EvalHash.hash(decodeVString(ctx, arg(a, 1)).sstring.toText());
			EvalValueTools.vbool(deleteDynamicField(arg(a, 0), name));
		}));
		reg(s, "Reflect", "getProperty", vfn(a -> {
			var o = arg(a, 0);
			if (o == VNull) VNull else {
				var name = decodeVString(ctx, arg(a, 1)).sstring.toText();
				var getter = EvalField.field(ctx, o, EvalHash.hash("get_" + name));
				if (getter != VNull) callValueOn(o, getter, []) else EvalField.dynamicField(ctx, o, EvalHash.hash(name));
			}
		}));
		reg(s, "Reflect", "isEnumValue", vfn(a -> EvalValueTools.vbool(switch (arg(a, 0)) {
			case VEnumValue(_): true;
			case _: false;
		})));
		reg(s, "Reflect", "isObject", vfn(a -> EvalValueTools.vbool(switch (EvalValueTools.vresolve(arg(a, 0))) {
			case VObject(_) | VString(_) | VArray(_) | VVector(_) | VInstance(_) | VPrototype(_): true;
			case _: false;
		})));
		// The function is called (callValue) when the result is called.
		reg(s, "Reflect", "makeVarArgs", vfn(a -> {
			var fn = arg(a, 0);
			VFunction(function(vl:Array<EvalValue>):EvalValue return callValue(ctx, fn, [VArray(new VArray(vl, vl.length))]), true);
		}));
		reg(s, "Reflect", "setProperty", vfn(a -> {
			var o = arg(a, 0);
			var name = decodeVString(ctx, arg(a, 1)).sstring.toText();
			var setter = EvalField.field(ctx, o, EvalHash.hash("set_" + name));
			if (setter != VNull) callValueOn(o, setter, [arg(a, 2)]);
			else {
				reflectSetField(ctx, o, EvalHash.hash(name), arg(a, 2));
				VNull;
			}
		}));

		reg(s, "Type", "getClass", vfn(a -> switch (arg(a, 0)) {
			case VInstance(vi):
				// An instance always has a class; a synthetic prototype (haxe.macro.Position) gets a
				// class value on demand.
				switch (classValue(ctx, vi.iproto.ppath)) {
					case VNull: coreClassValue(ctx, vi.iproto.ppath);
					case v: v;
				}
			case VString(_):
				classValue(ctx, EvalHash.key_String);
			case VArray(_):
				classValue(ctx, EvalHash.key_Array);
			case VVector(_):
				classValue(ctx, EvalHash.key_eval_Vector);
			case _: VNull;
		}));
		reg(s, "Type", "typeof", vfn(a -> typeofValue(ctx, arg(a, 0))));
		reg(s, "Type", "getClassName", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) { case PClass(_): mkStr(EvalHash.revHash(proto.ppath)); case _: VNull; };
			case _: VNull;
		}));
		// A class takes decodeArray arguments, and anything else is unexpected.
		reg(s, "Type", "createInstance", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto) if (proto.pkind.match(PClass(_))):
				var args = decodeArray(ctx, arg(a, 1));
				// The String special constructor: the argument as it is.
				proto.ppath == EvalHash.key_String && args.length == 1 ? args[0] : EvalEmitter.constructPath(ctx, proto.ppath, args);
			case v: EvalExceptions.unexpectedValue(ctx, v, "Class");
		}));
		reg(s, "Type", "createEmptyInstance", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) {
				case PClass(_):
					var empty = ctx.builtins.emptyConstructorBuiltins.get(proto.ppath);
					if (empty != null) empty() else {
						var iproto = ctx.instancePrototypes.get(proto.ppath);
						if (iproto == null && isCoreClassPath(proto.ppath)) iproto = coreInstancePrototype(ctx, proto.ppath);
						iproto == null ? VNull : VInstance(new VInstance(iproto.pinstanceFields.copy(), iproto, INormal));
					}
				case _: VNull;
			};
			case _: VNull;
		}));

		reg(s, "Type", "getClassFields", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) { case PClass(_): var ns = classFieldNames(ctx, proto); VArray(new VArray(ns, ns.length)); case _: VNull; };
			case _: VNull;
		}));
		reg(s, "Type", "getInstanceFields", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto):
				var ip = ctx.instancePrototypes.get(proto.ppath);
				if (ip == null && isCoreClassPath(proto.ppath)) {
					VArray(new VArray([], 0));
				} else if (ip == null) VNull else {
					var ns = instanceFieldNames(ip);
					VArray(new VArray(ns, ns.length));
				}
			case _: VNull;
		}));
		reg(s, "Type", "getEnumConstructs", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) { case PEnum(cs): var ns = [for (c in cs) mkStr(c.name)]; VArray(new VArray(ns, ns.length)); case _: VNull; };
			case _: VNull;
		}));
		// The constructor name is decodeVString, decoded first.
		reg(s, "Type", "createEnum", vfn(a -> {
			var constr = EvalHash.hash(decodeVString(ctx, arg(a, 1)).sstring.toText());
			createEnumByName(ctx, arg(a, 0), constr, arg(a, 2));
		}));
		// The index is decodeInt, decoded first; an index past the constructors is an internal failure no
		// macro catches.
		reg(s, "Type", "createEnumIndex", vfn(a -> {
			var idx = decodeInt(ctx, arg(a, 1));
			switch (arg(a, 0)) {
				case VPrototype(proto): switch (proto.pkind) {
					case PEnum(cs):
						// An enum constructor by index: Invalid_argument for a negative index, a failure
						// past the end.
						if (idx < 0) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("List.nth")');
						if (idx >= cs.length) throw new hxc.eval.EvalExceptions.HostException("nth", true);
						createEnumByName(ctx, arg(a, 0), EvalHash.hash(cs[idx].name), arg(a, 2));
					case _: VNull;
				};
				case _: VNull;
			}
		}));
		reg(s, "Type", "allEnums", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) {
				case PEnum(cs):
					var values:Array<EvalValue> = [];
					for (c in cs) {
						var idx = proto.pnames.get(EvalHash.hash(c.name));
						if (idx != null) switch (proto.pfields[idx]) { case VEnumValue(_): values.push(proto.pfields[idx]); case _: };
					}
					VArray(new VArray(values, values.length));
				case _: VNull;
			};
			case _: VNull;
		}));
		// Anything but an enum value is unexpected (null too).
		reg(s, "Type", "enumParameters", vfn(a -> switch (arg(a, 0)) {
			case VEnumValue(ev): VArray(new VArray(ev.eargs.copy(), ev.eargs.length));
			case v: EvalExceptions.unexpectedValue(ctx, v, "enum value");
		}));
		reg(s, "Type", "enumEq", vfn(a -> EvalValueTools.vbool(enumEqValue(arg(a, 0), arg(a, 1)))));
		reg(s, "Type", "enumIndex", vfn(a -> switch (arg(a, 0)) {
			case VEnumValue(ev): VInt(ev.eindex);
			case v: EvalExceptions.unexpectedValue(ctx, v, "enum value");
		}));
		reg(s, "Type", "enumConstructor", vfn(a -> switch (arg(a, 0)) {
			case VEnumValue(ev):
				var p = ctx.staticPrototypes.get(ev.epath);
				if (p == null) VNull else switch (p.pkind) { case PEnum(cs): mkStr(cs[ev.eindex].name); case _: VNull; };
			case v: EvalExceptions.unexpectedValue(ctx, v, "enum value");
		}));
		reg(s, "Type", "getEnum", vfn(a -> switch (arg(a, 0)) {
			case VEnumValue(ev): classValue(ctx, ev.epath);
			case _: VNull;
		}));
		reg(s, "Type", "getEnumName", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) { case PEnum(_): mkStr(EvalHash.revHash(proto.ppath)); case _: VNull; };
			case _: VNull;
		}));
		reg(s, "Type", "getSuperClass", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) { case PClass(_) if (proto.pparent != null): proto.pparent.pvalue; case _: VNull; };
			case _: VNull;
		}));
		// The name is decodeVString.
		reg(s, "Type", "resolveClass", vfn(a -> {
			var path = EvalHash.hash(decodeVString(ctx, arg(a, 0)).sstring.toText());
			var p = ctx.staticPrototypes.get(path);
			p == null ? (isCoreClassPath(path) ? coreClassValue(ctx, path) : VNull) : p.pvalue;
		}));
		reg(s, "Type", "resolveEnum", vfn(a -> {
			var p = ctx.staticPrototypes.get(EvalHash.hash(decodeVString(ctx, arg(a, 0)).sstring.toText()));
			if (p == null) VNull else switch (p.pkind) { case PEnum(_): p.pvalue; case _: VNull; };
		}));
		// callMethod: the arguments decoded first, then the call.
		reg(s, "Reflect", "callMethod", vfn(a -> {
			var args = decodeArray(ctx, arg(a, 2));
			callValueOn(arg(a, 0), arg(a, 1), args);
		}));
		// Lambda is the std's Haxe code, with no natives, so its frames and null handling are the code's
		// own.

		var ctors = ctx.builtins.constructorBuiltins;
		var emptyCtors = ctx.builtins.emptyConstructorBuiltins;
		ctors.set(EvalHash.hash("String"), function(a) return arg(a, 0));
		emptyCtors.set(EvalHash.hash("String"), function() return mkStr(""));
		ctors.set(EvalHash.hash("StringBuf"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("StringBuf"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IBuffer(new VStringBuffer())));
		});
		ctors.set(EvalHash.hash("haxe.Utf8"), function(a) {
			// The size is defaultInt.
			defaultInt(ctx, arg(a, 0), 0);
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.Utf8"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IUtf8(new ByteBuffer())));
		});
		ctors.set(EvalHash.hash("EReg"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("EReg"));
			// The pattern and the options are decodeString, decoded right to left.
			var opt = decodeString(ctx, arg(a, 1));
			var r = decodeString(ctx, arg(a, 0));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IRegex(regexCreate(r, opt))));
		});
		emptyCtors.set(EvalHash.hash("EReg"), function() {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("EReg"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IRegex(regexEmpty())));
		});

		// StringBuf, over a byte buffer: the bytes and the length in characters each add says it added.
		reg(inst, "StringBuf", "add", vmethod(a -> {
			var self = thisBuffer(a);
			var x = arg(a, 1);
			// A string as it is; anything else printed, and counted by its bytes (createAscii).
			var s = switch (x) {
				case VString(s): s;
				case _: EvalString.createAscii(valueString(x));
			};
			self.addString(s);
			VNull;
		}));
		reg(inst, "StringBuf", "addChar", vmethod(a -> {
			var self = thisBuffer(a);
			var i = decodeInt(ctx, arg(a, 1));
			self.bbuffer.addString(EvalString.stringOfCharCode(i));
			self.blength++;
			VNull;
		}));
		reg(inst, "StringBuf", "addSub", vmethod(a -> {
			var self = thisBuffer(a);
			var s = decodeVString(ctx, arg(a, 1));
			var cPos = decodeInt(ctx, arg(a, 2));
			var cLen = switch (arg(a, 3)) {
				case VNull: s.slength - cPos;
				case VInt(i): i;
				case v: EvalExceptions.unexpectedValue(ctx, v, "int");
			};
			if (cLen > 0) {
				var bOffset1 = EvalString.getOffset(s, cPos);
				var bOffset2 = Utf8.move(s.sstring, bOffset1, cLen);
				self.addSubstring(s, bOffset1, bOffset2 - bOffset1, cLen);
			}
			VNull;
		}));
		reg(inst, "StringBuf", "toString", vmethod(a -> VString(thisBuffer(a).contents())));
		reg(inst, "StringBuf", "get_length", vmethod(a -> VInt(thisBuffer(a).blength)));

		// haxe.Utf8, over a UTF-8 buffer (IUtf8): charCodeAt and sub are String's.
		reg(s, "haxe.Utf8", "charCodeAt", vfn(a -> stdStringCharCodeAt(ctx, a)));
		reg(s, "haxe.Utf8", "compare", vfn(a -> {
			var x = decodeString(ctx, arg(a, 0));
			var y = decodeString(ctx, arg(a, 1));
			VInt(ByteString.compare(x, y));
		}));
		// Each code narrowed to a byte, which raises Out_of_range from 256 up.
		reg(s, "haxe.Utf8", "decode", vfn(a -> {
			var str = decodeString(ctx, arg(a, 0));
			Utf8.length(str);
			var buf = new ByteBuffer();
			Utf8.iter(str, uc -> {
				if (uc < 0 || uc >= 0x100) throw new hxc.eval.EvalExceptions.HostException("Extlib_leftovers.UCharExt.Out_of_range");
				buf.addByte(uc);
			});
			EvalString.createUnknown(buf.contents());
		}));
		// Each BYTE taken as a code and encoded.
		reg(s, "haxe.Utf8", "encode", vfn(a -> {
			var str = decodeString(ctx, arg(a, 0));
			var buf = new ByteBuffer();
			for (i in 0...str.length) Utf8.addUchar(buf, str.get(i));
			EvalString.createUnknown(buf.contents());
		}));
		reg(s, "haxe.Utf8", "iter", vfn(a -> {
			var str = decodeString(ctx, arg(a, 0));
			var fn = arg(a, 1);
			Utf8.iter(str, uc -> callValue(ctx, fn, [VInt(uc)]));
			VNull;
		}));
		reg(s, "haxe.Utf8", "length", vfn(a -> VInt(decodeVString(ctx, arg(a, 0)).slength)));
		reg(s, "haxe.Utf8", "sub", vfn(a -> stdStringSubstr(ctx, a)));
		reg(s, "haxe.Utf8", "validate", vfn(a -> EvalValueTools.vbool(Utf8.validate(decodeString(ctx, arg(a, 0))))));
		reg(inst, "haxe.Utf8", "addChar", vmethod(a -> {
			Utf8.addUchar(thisUtf8(ctx, a), Utf8.ucharOfInt(decodeInt(ctx, arg(a, 1))));
			VNull;
		}));
		// The contents counted by their bytes (createAscii).
		reg(inst, "haxe.Utf8", "toString", vmethod(a -> VString(EvalString.createAscii(thisUtf8(ctx, a).contents()))));

		// EReg, over pcre2 on the string's bytes (hxc.eval.Pcre2).
		reg(inst, "EReg", "match", vmethod(a -> {
			// Match: every match from the start (execAll), NO_UTF_CHECK; no match forgets the groups, and a
			// PCRE error is the one message a Haxe catch sees.
			var re = thisRegex(a);
			var s = decodeString(ctx, arg(a, 1));
			re.rString = s;
			try {
				re.rGroups = re.r.execAll(Pcre2Flag.NO_UTF_CHECK, 0, s.toBytes());
				VTrue;
			} catch (_:hxc.eval.Pcre2.Pcre2NotFound) {
				re.rGroups = [];
				VFalse;
			} catch (_:hxc.eval.Pcre2.Pcre2Exception) {
				EvalExceptions.excString(ctx, "PCRE Error (invalid unicode string?)");
			}
		}));
		// Matched: the group's bytes out of the subject the match was made on.
		reg(inst, "EReg", "matched", vmethod(a -> {
			var re = thisRegex(a);
			var n = decodeInt(ctx, arg(a, 1));
			regexMaybeRun(ctx, re, n, (first, last) -> EvalString.createUnknown(regexSlice(re.rString, first, last)));
		}));
		reg(inst, "EReg", "matchedLeft", vmethod(a -> {
			var re = thisRegex(a);
			regexMaybeRun(ctx, re, 0, (first, _) -> EvalString.createUnknown(regexSlice(re.rString, null, first)));
		}));
		reg(inst, "EReg", "matchedRight", vmethod(a -> {
			var re = thisRegex(a);
			regexMaybeRun(ctx, re, 0, (_, last) -> EvalString.createUnknown(regexSlice(re.rString, last, null)));
		}));
		// matchedPos: the byte offsets counted in characters by stepping Utf8.next.
		reg(inst, "EReg", "matchedPos", vmethod(a -> {
			var re = thisRegex(a);
			function charOffset(i:Int):Int {
				var k = 0;
				var o = 0;
				while (i != 0) {
					var n = Utf8.next(re.rString, o);
					i -= n - o;
					k++;
					o = n;
				}
				return k;
			}
			regexMaybeRun(ctx, re, 0, (first, last) -> {
				var f = charOffset(first);
				var l = charOffset(last);
				var m = new Map();
				m.set(EvalHash.hash("pos"), VInt(f));
				m.set(EvalHash.hash("len"), VInt(l - f));
				VObject(new VObject([], ODictionary(m)));
			});
		}));
		// matchSub: the subject cut at pos + len and matched from pos; a failure leaves the
		// previous match standing.
		reg(inst, "EReg", "matchSub", vmethod(a -> {
			var re = thisRegex(a);
			var s = decodeString(ctx, arg(a, 1));
			var pos = decodeInt(ctx, arg(a, 2));
			var lenDefault = s.length - pos;
			var len = defaultInt(ctx, arg(a, 3), lenDefault);
			if (len < 0) len = lenDefault;
			if (pos + len > s.length) return VFalse;
			if (pos + len < 0) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("String.sub / Bytes.sub")');
			var str = s.sub(0, pos + len);
			try {
				var groups = re.r.execAll(Pcre2Flag.NO_UTF_CHECK, pos, str.toBytes());
				re.rString = s;
				re.rGroups = groups;
				VTrue;
			} catch (_:hxc.eval.Pcre2.Pcre2NotFound) VFalse;
		}));
		reg(inst, "EReg", "split", vmethod(a -> {
			var re = thisRegex(a);
			var s = decodeString(ctx, arg(a, 1));
			var slength = s.length;
			if (slength == 0) return VArray(new VArray([EvalString.vEmptyString()], 1));
			var subj = s.toBytes();
			var copyOffset = 0;
			var acc:Array<EvalValue> = [];
			function add(first:Int, last:Int) {
				if (last - first < 0 || first < 0 || last > slength) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("String.sub / Bytes.sub")');
				acc.push(EvalString.createUnknown(s.sub(first, last - first)));
			}
			var pos = 0;
			while (true) {
				var next:Int;
				try {
					var ss = re.r.exec(Pcre2Flag.NO_UTF_CHECK, pos, subj);
					var o = ss.getSubstringOfs(0);
					add(copyOffset, o.first);
					copyOffset = o.last;
					next = pos == o.last ? o.last + 1 : o.last;
					if (next >= slength) {
						acc.push(EvalString.vEmptyString());
						break;
					}
				} catch (_:hxc.eval.Pcre2.Pcre2NotFound) {
					add(copyOffset, slength);
					break;
				}
				if (re.global) pos = next;
				else {
					add(copyOffset, slength);
					break;
				}
			}
			VArray(new VArray(acc, acc.length));
		}));
		// Replace: pcre2's replace, global or first-only, under NO_UTF_CHECK, with the replacement as its
		// template (`$1`, `$$`, ...).
		reg(inst, "EReg", "replace", vmethod(a -> {
			var re = thisRegex(a);
			var s = decodeString(ctx, arg(a, 1));
			var by = decodeString(ctx, arg(a, 2));
			var out = re.global
				? re.r.replace(Pcre2Flag.NO_UTF_CHECK, by.toBytes(), s.toBytes())
				: re.r.replaceFirst(Pcre2Flag.NO_UTF_CHECK, by.toBytes(), s.toBytes());
			EvalString.createUnknown(ByteString.ofBytes(out, 0, out.length));
		}));
		// Map: each match's replacement is the callback's string; an empty match copies one byte and
		// moves on.
		reg(inst, "EReg", "map", vmethod(a -> {
			var recv = arg(a, 0);
			var fn = arg(a, 2);
			var re = thisRegex(a);
			var s = decodeString(ctx, arg(a, 1));
			var subj = s.toBytes();
			var l = s.length;
			var buf = new ByteBuffer();
			re.rString = s;
			var pos = 0;
			while (pos < l) {
				try {
					var ss = re.r.exec(0, pos, subj);
					re.rGroups = [ss];
					var o = ss.getSubstringOfs(0);
					buf.addSub(s, pos, o.first - pos);
					buf.addString(decodeString(ctx, callValueOn(recv, fn, [recv])));
					if (o.last == o.first) {
						if (o.last >= l) break;
						if (re.global) {
							buf.addSub(s, o.first, 1);
							pos = o.first + 1;
						} else {
							buf.addSub(s, o.first, l - o.first);
							break;
						}
					} else if (re.global) {
						pos = o.last;
					} else {
						buf.addSub(s, o.last, l - o.last);
						break;
					}
				} catch (_:hxc.eval.Pcre2.Pcre2NotFound) {
					buf.addSub(s, pos, l - pos);
					break;
				}
			}
			re.rString = ByteString.empty;
			re.rGroups = [];
			EvalString.createUnknown(buf.contents());
		}));
		reg(s, "EReg", "escape", vfn(a -> EvalString.createUnknown(regexQuote(decodeString(ctx, arg(a, 0))))));


		// haxe.ds maps (StringMap/IntMap/ObjectMap) backed by a native dictionary. EnumValueMap is the
		// std's Haxe code (a BalancedTree), with no natives.
		function iteratorOf(items:Array<EvalValue>):EvalValue
			return listIteratorValue(items);
		for (mapPath in ["haxe.ds.StringMap", "haxe.ds.IntMap", "haxe.ds.ObjectMap"]) {
			// An IntMap key is decodeInt, a StringMap key decodeVString and an ObjectMap key any value.
			function argKey(v:EvalValue):EvalValue {
				return switch (mapPath) {
					case "haxe.ds.IntMap": VInt(decodeInt(ctx, v));
					case "haxe.ds.StringMap":
						decodeVString(ctx, v);
						v;
					case _: v;
				};
			}
			function keyString(v:EvalValue):String return mapPath == "haxe.ds.ObjectMap" ? objectMapKey(v) : mapKey(v);
			ctors.set(EvalHash.hash(mapPath), function(a) {
				var proto = ctx.instancePrototypes.get(EvalHash.hash(mapPath));
				var vi = new VInstance(proto.pinstanceFields.copy(), proto, IMap(new Map()));
				nativeMapOrders.set(vi, []);
				return VInstance(vi);
			});
			emptyCtors.set(EvalHash.hash(mapPath), function() {
				var proto = ctx.instancePrototypes.get(EvalHash.hash(mapPath));
				var vi = new VInstance(proto.pinstanceFields.copy(), proto, IMap(new Map()));
				nativeMapOrders.set(vi, []);
				return VInstance(vi);
			});
			reg(inst, mapPath, "set", vmethod(a -> {
				var key = argKey(arg(a, 1));
				var vi = thisInstance(a, mapPath);
				var m = thisMap(a);
				var k = keyString(key);
				if (!m.exists(k)) {
					var order = nativeMapOrders.get(vi);
					if (order == null) {
						order = [for (key in m.keys()) key];
						nativeMapOrders.set(vi, order);
					}
					order.push(k);
				}
				m.set(k, {key: key, value: arg(a, 2)});
				VNull;
			}));
			reg(inst, mapPath, "get", vmethod(a -> {
				var k = keyString(argKey(arg(a, 1)));
				var m = thisMap(a);
				m.exists(k) ? m.get(k).value : VNull;
			}));
			reg(inst, mapPath, "exists", vmethod(a -> {
				var k = keyString(argKey(arg(a, 1)));
				EvalValueTools.vbool(thisMap(a).exists(k));
			}));
			reg(inst, mapPath, "remove", vmethod(a -> {
				var vi = thisInstance(a, mapPath);
				var m = thisMap(a);
				var k = keyString(argKey(arg(a, 1)));
				var had = m.exists(k);
				m.remove(k);
				var order = nativeMapOrders.get(vi);
				if (order != null) order.remove(k);
				EvalValueTools.vbool(had);
			}));
			reg(inst, mapPath, "iterator", vmethod(a -> iteratorOf([for (e in orderedMapEntries(arg(a, 0))) e.value])));
			reg(inst, mapPath, "keys", vmethod(a -> iteratorOf([for (e in orderedMapEntries(arg(a, 0))) e.key])));
			reg(inst, mapPath, "keyValueIterator", vmethod(a -> mapKeyValueIteratorValue(ctx, arg(a, 0))));
			reg(inst, mapPath, "clear", vmethod(a -> {
				var vi = thisInstance(a, mapPath);
				thisMap(a).clear();
				var order = nativeMapOrders.get(vi);
				if (order != null) order.resize(0);
				VNull;
			}));
			// Copy: the same entries under the same keys, in the same table order.
			reg(inst, mapPath, "copy", vmethod(a -> {
				var vi0 = thisInstance(a, mapPath);
				var m = thisMap(a);
				var proto = ctx.instancePrototypes.get(EvalHash.hash(mapPath));
				var nm = new Map();
				var order0 = nativeMapOrders.get(vi0);
				var order = order0 == null ? [for (k in m.keys()) k] : [for (k in order0) if (m.exists(k)) k];
				for (k in order) nm.set(k, {key: m.get(k).key, value: m.get(k).value});
				var vi = new VInstance(proto.pinstanceFields.copy(), proto, IMap(nm));
				nativeMapOrders.set(vi, order);
				VInstance(vi);
			}));
			reg(inst, mapPath, "toString", vmethod(a -> VString(mapToString(arg(a, 0)))));
		}

		// New Array() builds an empty dynamic array, matching the [] literal.
		ctors.set(EvalHash.hash("Array"), function(a) return VArray(new VArray([], 0)));
		emptyCtors.set(EvalHash.hash("Array"), function() return VArray(new VArray([], 0)));
		ctors.set(EvalHash.hash("eval.Vector"), function(a) {
			// New Vector: the length is decodeIntP.
			var length = decodeIntP(ctx, arg(a, 0), EvalContext.getEval(ctx).currentPos);
			if (length < 0) EvalExceptions.excString(ctx, "Vector size must be >= 0", EvalContext.getEval(ctx).currentPos);
			return VVector([for (_ in 0...length) VNull]);
		});
		emptyCtors.set(EvalHash.hash("eval.Vector"), function() return VVector([]));
		ctors.set(EvalHash.hash("haxe.io.BytesBuffer"), function(a) return mkBytesBuffer(ctx));
		emptyCtors.set(EvalHash.hash("haxe.io.BytesBuffer"), function() return mkBytesBuffer(ctx));
		ctors.set(EvalHash.hash("haxe.io.Bytes"), function(a) {
			var length = decodeInt(ctx, arg(a, 0));
			var source = decodeBytes(arg(a, 1));
			var bytes = haxe.io.Bytes.alloc(length);
			bytes.blit(0, source, 0, length > source.length ? source.length : length);
			return mkBytes(ctx, bytes);
		});

		// Date: a native instance carrying its epoch timestamp.
		ctors.set(EvalHash.hash("Date"), function(a) {
			// The six fields decoded with decodeInt, left to right, then mktime.
			var f = [for (i in 0...6) decodeInt(ctx, arg(a, i))];
			return mkDate(ctx, unixMktime(ctx, f[0], f[1], f[2], f[3], f[4], f[5]) * 1000);
		});
		emptyCtors.set(EvalHash.hash("Date"), function() return mkDate(ctx, 0));
		ctors.set(EvalHash.hash("sys.io._Process.NativeProcess"), function(a) {
			var cmd = stringOf(arg(a, 0));
			var args = processArgs(ctx, arg(a, 1));
			// A process that fails to start is reported by the native's own name, "process_run", whatever
			// the system said.
			var proc = try new sys.io.Process(cmd, args) catch (_:Dynamic) null;
			if (proc == null) EvalExceptions.excString(ctx, "process_run");
			return mkNativeProcess(ctx, proc);
		});
		ctors.set(EvalHash.hash("sys.thread.Mutex"), function(a) return mkThreadMutex(ctx));
		ctors.set(EvalHash.hash("sys.thread.Lock"), function(a) return mkThreadLock(ctx));
		ctors.set(EvalHash.hash("sys.thread.Tls"), function(a) return mkThreadTls(ctx));
		ctors.set(EvalHash.hash("sys.thread.Deque"), function(a) return mkThreadDeque(ctx));
		#if emscripten
		ctors.set(EvalHash.hash("sys.thread.Condition"), function(a) return mkThreadCondition(ctx));
		ctors.set(EvalHash.hash("sys.thread.Semaphore"), function(a) return mkThreadSemaphore(ctx, toInt(arg(a, 0))));
		#end
		ctors.set(EvalHash.hash("eval.vm.NativeThread"), function(a) {
			if (ctx.isMacro) return EvalExceptions.excString(ctx, "Creating threads in macros is not supported");
			return spawnThread(ctx, arg(a, 0));
		});
		reg(s, "Date", "now", vfn(a -> mkDate(ctx, Date.now().getTime())));
		// The time is num and the string decodeString.
		reg(s, "Date", "fromTime", vfn(a -> mkDate(ctx, num(ctx, arg(a, 0)))));
		reg(s, "Date", "fromString", vfn(a -> dateFromString(ctx, decodeText(ctx, arg(a, 0)))));

		// sys.FileSystem / sys.io.File: macros read the source tree at compile time; the interpreter
		// host has real filesystem access.
		// A path is decoded as a string.
		reg(s, "sys.FileSystem", "exists", vfn(a -> sys.FileSystem.exists(decodeText(ctx, arg(a, 0))) ? VTrue : VFalse));
		reg(s, "sys.FileSystem", "isDirectory", vfn(a -> sys.FileSystem.isDirectory(decodeText(ctx, arg(a, 0))) ? VTrue : VFalse));
		// A directory check on the patched path (a stat failure is its Sys_error), "No such
		// directory" for anything else, then the directory's entries.
		reg(s, "sys.FileSystem", "readDirectory", vfn(a -> {
			var dir = decodeText(ctx, arg(a, 0));
			var patched = fsPatchPath(dir);
			var err = cFs(5, patched);
			if (err != null) sysError(ctx, patched, err);
			if (!sys.FileSystem.isDirectory(dir)) EvalExceptions.excString(ctx, "No such directory");
			var d = try sys.FileSystem.readDirectory(dir) catch (_:Dynamic) {
				var e2 = cFs(5, dir);
				sysError(ctx, dir, e2 == null ? "No such file or directory" : e2);
			};
			VArray(new VArray([for (f in d) mkStr(f)], d.length));
		}));
		// createDirectory: over the path with a trailing slash, each prefix that does not exist is
		// created, a drive root skipped.
		reg(s, "sys.FileSystem", "createDirectory", vfn(a -> {
			var path = haxe.io.Path.addTrailingSlash(decodeText(ctx, arg(a, 0)));
			var parts = ~/[\\\/]+/g.split(path);
			parts.pop();
			var base = "";
			for (dir in parts) {
				var p = base == "" ? dir : base == "/" ? "/" + dir : base + "/" + dir;
				if (p.length > 0 && (p.charAt(p.length - 1) == "/" || p.charAt(p.length - 1) == "\\")) p = p.substr(0, p.length - 1);
				if (!(p == "" || (p.length == 2 && p.charAt(1) == ":")) && !sys.FileSystem.exists(p)) {
					var err = cFs(2, p);
					if (err != null) unixError(ctx, err, "mkdir", p);
				}
				base = p == "" ? "/" : p;
			}
			VNull;
		}));
		// deleteDirectory: an rmdir failure is a Unix error.
		reg(s, "sys.FileSystem", "deleteDirectory", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			var err = cFs(1, path);
			if (err != null) unixError(ctx, err, "rmdir", path);
			VNull;
		}));
		// deleteFile: a failed removal is its Sys_error.
		reg(s, "sys.FileSystem", "deleteFile", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			var err = cFs(0, path);
			if (err != null) sysError(ctx, path, err);
			VNull;
		}));
		// fullPath: the decode sits inside the native's catch-all handler, so a null argument's Null
		// Access prints as the runtime exception value, and a refused empty path prints as the
		// get_full_path failure.
		reg(s, "sys.FileSystem", "fullPath", vfn(a -> {
			var f = try decodeText(ctx, arg(a, 0)) catch (_:EvalExceptions.EvalRunTimeException) EvalExceptions.excString(ctx, "EvalContext.RunTimeException(_, _, _)");
			f == "" ? EvalExceptions.excString(ctx, "Failure(\"get_full_path\")") : mkStr(sys.FileSystem.fullPath(f));
		}));
		// Rename: both paths are decoded, the new one first.
		reg(s, "sys.FileSystem", "rename", vfn(a -> {
			var newPath = decodeText(ctx, arg(a, 1));
			// A rename's Sys_error carries no path.
			var err = cFs(3, decodeText(ctx, arg(a, 0)), newPath);
			if (err != null) EvalExceptions.excString(ctx, err);
			VNull;
		}));
		// Stat: a failure on the patched path is a Unix error; the host's stat answers zeros for a path
		// that is not there.
		reg(s, "sys.FileSystem", "stat", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			if (!sys.FileSystem.exists(path)) EvalExceptions.excString(ctx, "No such file or directory(stat, " + fsPatchPath(path) + ")");
			mkFileStat(ctx, sys.FileSystem.stat(path));
		}));
		reg(s, "sys.net.Host", "localhost", vfn(a -> mkStr(sys.net.Host.localhost())));
		reg(s, "sys.net.Host", "resolve", vfn(a -> VInt(hostIpInt(stringOf(arg(a, 0))))));
		reg(s, "sys.net.Host", "hostToString", vfn(a -> mkStr(new sys.net.Host(hostIpString(toInt(arg(a, 0)))).toString())));
		reg(s, "sys.net.Host", "hostReverse", vfn(a -> mkStr(new sys.net.Host(hostIpString(toInt(arg(a, 0)))).reverse())));
		// sys.io.File: a path is decodeString, a binary flag true or null for binary. An open that fails
		// is a system error, "<path>: <strerror>".
		reg(s, "sys.io.File", "append", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			mkFileOutput(ctx, try sys.io.File.append(path, fileBinaryFlag(arg(a, 1))) catch (e:Dynamic) openError(ctx, path, 7, e));
		}));
		// An unreadable file raises "Could not read file <path>".
		reg(s, "sys.io.File", "getBytes", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			try mkBytes(ctx, sys.io.File.getBytes(path)) catch (_:Dynamic) EvalExceptions.excString(ctx, "Could not read file " + path);
		}));
		reg(s, "sys.io.File", "getContent", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			// The file's bytes, read in binary mode, as a string (createUnknown).
			try {
				var b = sys.io.File.getBytes(path);
				EvalString.createUnknown(ByteString.ofBytes(b, 0, b.length));
			} catch (_:Dynamic) EvalExceptions.excString(ctx, "Could not read file " + path);
		}));
		reg(s, "sys.io.File", "read", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			mkFileInput(ctx, try sys.io.File.read(path, fileBinaryFlag(arg(a, 1))) catch (e:Dynamic) openError(ctx, path, 6, e));
		}));
		// saveBytes: a failure to open the file is its Sys_error.
		reg(s, "sys.io.File", "saveBytes", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			var bytes = decodeBytes(arg(a, 1));
			try sys.io.File.saveBytes(path, bytes) catch (e:Dynamic) openError(ctx, path, 7, e);
			VNull;
		}));
		reg(s, "sys.io.File", "saveContent", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			// The content's bytes as they are.
			var content = decodeString(ctx, arg(a, 1));
			try sys.io.File.saveBytes(path, content.toBytes()) catch (e:Dynamic) openError(ctx, path, 7, e);
			VNull;
		}));
		reg(s, "sys.io.File", "update", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			mkFileOutput(ctx, try sys.io.File.update(path, fileBinaryFlag(arg(a, 1))) catch (e:Dynamic) openError(ctx, path, 7, e));
		}));
		reg(s, "sys.io.File", "write", vfn(a -> {
			var path = decodeText(ctx, arg(a, 0));
			mkFileOutput(ctx, try sys.io.File.write(path, fileBinaryFlag(arg(a, 1))) catch (e:Dynamic) openError(ctx, path, 7, e));
		}));
		// Close: the channel stays, and closing it again does nothing. The position of a closed channel
		// is the fd offset its buffer reached: refills of up to 64KB from where the last seek left it,
		// capped at the file's length.
		reg(inst, "sys.io.FileInput", "close", vmethod(a -> {
			var ch = thisFileInput(a);
			if (ch.closed) return VNull;
			if (ch.file != null) {
				var offset = ch.base;
				if (ch.read) try {
					ch.file.seek(0, SeekEnd);
					var size = ch.file.tell();
					var reached = ch.base + Std.int(Math.ceil((ch.maxPos - ch.base) / 65536)) * 65536;
					offset = reached < size ? reached : size;
				} catch (_:Dynamic) {}
				ch.closedOffset = offset;
			}
			ch.input.close();
			ch.closed = true;
			VNull;
		}));
		reg(inst, "sys.io.FileInput", "eof", vmethod(a -> EvalValueTools.vbool(thisFileInput(a).eof)));
		// Seek: a destination inside a closed channel's buffer window moves nothing; any other is lseek
		// on fd -1.
		reg(inst, "sys.io.FileInput", "seek", vmethod(a -> {
			var ch = thisFileInput(a);
			ch.eof = false;
			var pos = toInt(arg(a, 1));
			if (ch.closed) {
				var dest = switch (fileSeekMode(arg(a, 2))) {
					case SeekBegin: pos;
					case SeekCur: ch.closedOffset + pos;
					case SeekEnd: throw new hxc.eval.EvalExceptions.HostException('Sys_error("Bad file descriptor")');
				};
				if (dest < ch.closedOffset - 65536 || dest > ch.closedOffset)
					throw new hxc.eval.EvalExceptions.HostException('Sys_error("Bad file descriptor")');
				return VNull;
			}
			ch.file.seek(pos, fileSeekMode(arg(a, 2)));
			ch.base = ch.file.tell();
			ch.maxPos = ch.base;
			ch.read = false;
			VNull;
		}));
		reg(inst, "sys.io.FileInput", "tell", vmethod(a -> {
			var ch = thisFileInput(a);
			VInt(ch.closed ? ch.closedOffset : ch.file.tell());
		}));
		// readByte: a failed byte read, a closed channel's included, is Eof.
		reg(inst, "sys.io.FileInput", "readByte", vmethod(a -> {
			var ch = thisFileInput(a);
			if (ch.closed) {
				ch.eof = true;
				return eof(ctx);
			}
			try {
				// The read that refills the channel runs in a blocking section.
				var b = released(() -> ch.input.readByte());
				noteRead(ch);
				VInt(b);
			} catch (_:Dynamic) {
				ch.eof = true;
				eof(ctx);
			}
		}));
		// readBytes: the read is not guarded, so a closed channel's Sys_error escapes.
		reg(inst, "sys.io.FileInput", "readBytes", vmethod(a -> {
			var ch = thisFileInput(a);
			if (ch.closed && toInt(arg(a, 3)) > 0)
				throw new hxc.eval.EvalExceptions.HostException('Sys_error("Bad file descriptor")');
			var n = if (ch.closed) 0 else {
				var buf = decodeBytes(arg(a, 1));
				var pos = toInt(arg(a, 2));
				var len = toInt(arg(a, 3));
				try released(() -> ch.input.readBytes(buf, pos, len)) catch (_:Dynamic) {
					ch.eof = true;
					eof(ctx);
				}
			}
			if (n == 0) {
				ch.eof = true;
				eof(ctx);
			}
			noteRead(ch);
			VInt(n);
		}));
		// Close: the channel stays; closing or flushing it again does nothing. Its write cursor is then
		// its buffer's end, so its position reads the flushed offset plus the 64KB buffer, and every
		// write or seek flushes into fd -1: Sys_error, which no native catches.
		reg(inst, "sys.io.FileOutput", "close", vmethod(a -> {
			var out = thisFileOutput(a);
			if (out.closed) return VNull;
			out.closedPos = out.file != null ? (try out.file.tell() catch (_:Dynamic) 0) : 0;
			out.output.close();
			out.closed = true;
			VNull;
		}));
		reg(inst, "sys.io.FileOutput", "flush", vmethod(a -> {
			var out = thisFileOutput(a);
			if (!out.closed) out.output.flush();
			VNull;
		}));
		reg(inst, "sys.io.FileOutput", "seek", vmethod(a -> {
			var out = openFileOutput(a);
			out.file.seek(toInt(arg(a, 1)), fileSeekMode(arg(a, 2)));
			VNull;
		}));
		reg(inst, "sys.io.FileOutput", "tell", vmethod(a -> {
			var out = thisFileOutput(a);
			VInt(out.closed ? out.closedPos + 65536 : out.file.tell());
		}));
		reg(inst, "sys.io.FileOutput", "writeByte", vmethod(a -> { openFileOutput(a).output.writeByte(toInt(arg(a, 1))); VNull; }));
		reg(inst, "sys.io.FileOutput", "writeBytes", vmethod(a -> VInt(openFileOutput(a).output.writeBytes(
			decodeBytes(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3))))));
		reg(inst, "sys.io._Process.NativeProcess", "close", vmethod(a -> {
			var vi = thisInstance(a, "NativeProcess");
			nativeProcesses.get(vi).close();
			nativeProcesses.remove(vi);
			VNull;
		}));
		reg(inst, "sys.io._Process.NativeProcess", "exitCode", vmethod(a -> VInt(thisProcess(a).exitCode())));
		reg(inst, "sys.io._Process.NativeProcess", "getPid", vmethod(a -> VInt(thisProcess(a).getPid())));
		reg(inst, "sys.io._Process.NativeProcess", "kill", vmethod(a -> { thisProcess(a).kill(); VNull; }));
		reg(inst, "sys.io._Process.NativeProcess", "readStderr", vmethod(a -> {
			try VInt(thisProcess(a).stderr.readBytes(decodeBytes(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3)))) catch (_:Dynamic) {
				EvalExceptions.excString(ctx, "Could not read stderr");
			}
		}));
		reg(inst, "sys.io._Process.NativeProcess", "readStdout", vmethod(a -> {
			try VInt(thisProcess(a).stdout.readBytes(decodeBytes(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3)))) catch (_:Dynamic) {
				EvalExceptions.excString(ctx, "Could not read stdout");
			}
		}));
		reg(inst, "sys.io._Process.NativeProcess", "closeStdin", vmethod(a -> { thisProcess(a).stdin.close(); VNull; }));
		reg(inst, "sys.io._Process.NativeProcess", "writeStdin", vmethod(a -> VInt(thisProcess(a).stdin.writeBytes(
			decodeBytes(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3))))));
		reg(inst, "sys.io._Process.Stdin", "close", vmethod(a -> {
			var proc = EvalField.field(ctx, arg(a, 0), EvalHash.hash("proc"));
			thisProcess([proc]).stdin.close();
			VNull;
		}));
		reg(inst, "sys.thread.Mutex", "acquire", vmethod(a -> {
			var mutex = thisThreadMutex(a);
			var thread = sys.thread.Thread.current();
			if (mutex.owner != null && mutex.owner == thread) {
				mutex.count++;
			} else {
				gilBlocking(function() { mutex.mutex.acquire(); return VNull; });
				mutex.owner = thread;
				mutex.count = 1;
			}
			VNull;
		}));
		reg(inst, "sys.thread.Mutex", "tryAcquire", vmethod(a -> {
			var mutex = thisThreadMutex(a);
			var thread = sys.thread.Thread.current();
			if (mutex.owner != null && mutex.owner == thread) {
				mutex.count++;
				VTrue;
			} else if (mutex.mutex.tryAcquire()) {
				mutex.owner = thread;
				mutex.count = 1;
				VTrue;
			} else {
				VFalse;
			}
		}));
		reg(inst, "sys.thread.Mutex", "release", vmethod(a -> {
			var mutex = thisThreadMutex(a);
			if (mutex.count > 1) {
				mutex.count--;
			} else {
				mutex.owner = null;
				mutex.count = 0;
				mutex.mutex.release();
			}
			VNull;
		}));
		reg(inst, "sys.thread.Lock", "release", vmethod(a -> { thisThreadLock(a).release(); VNull; }));
		reg(inst, "sys.thread.Lock", "wait", vmethod(a -> {
			var lk = thisThreadLock(a);
			var to = arg(a, 1);
			gilBlocking(function() return EvalValueTools.vbool(to == VNull ? lk.wait() : lk.wait(toFloat(to))));
		}));
		reg(inst, "sys.thread.Tls", "get_value", vmethod(a -> {
			var v = thisThreadTls(a).value;
			v == null ? VNull : v;
		}));
		reg(inst, "sys.thread.Tls", "set_value", vmethod(a -> {
			thisThreadTls(a).value = arg(a, 1);
			arg(a, 1);
		}));
		reg(inst, "sys.thread.Deque", "add", vmethod(a -> { thisThreadDeque(a).add(arg(a, 1)); VNull; }));
		reg(inst, "sys.thread.Deque", "push", vmethod(a -> { thisThreadDeque(a).push(arg(a, 1)); VNull; }));
		reg(inst, "sys.thread.Deque", "pop", vmethod(a -> {
			var dq = thisThreadDeque(a);
			var v = arg(a, 1) == VTrue ? gilBlocking(function() { var r = dq.pop(true); return r == null ? VNull : r; }) : { var r = dq.pop(false); r == null ? VNull : r; };
			v;
		}));
		#if emscripten
		reg(inst, "sys.thread.Condition", "acquire", vmethod(a -> {
			var cond = thisThreadCondition(a);
			var thread = sys.thread.Thread.current();
			if (cond.owner != null && cond.owner == thread) {
				cond.count++;
			} else {
				gilBlocking(function() { cond.cond.acquire(); return VNull; });
				cond.owner = thread;
				cond.count = 1;
			}
			VNull;
		}));
		reg(inst, "sys.thread.Condition", "tryAcquire", vmethod(a -> {
			var cond = thisThreadCondition(a);
			var thread = sys.thread.Thread.current();
			if (cond.owner != null && cond.owner == thread) {
				cond.count++;
				VTrue;
			} else if (cond.cond.tryAcquire()) {
				cond.owner = thread;
				cond.count = 1;
				VTrue;
			} else {
				VFalse;
			}
		}));
		reg(inst, "sys.thread.Condition", "release", vmethod(a -> {
			var cond = thisThreadCondition(a);
			if (cond.count > 1) {
				cond.count--;
			} else {
				cond.owner = null;
				cond.count = 0;
				cond.cond.release();
			}
			VNull;
		}));
		reg(inst, "sys.thread.Condition", "wait", vmethod(a -> {
			var cond = thisThreadCondition(a);
			var thread = sys.thread.Thread.current();
			var count = cond.count <= 0 ? 1 : cond.count;
			cond.owner = null;
			cond.count = 0;
			gilBlocking(function() { cond.cond.wait(); return VNull; });
			cond.owner = thread;
			cond.count = count;
			VNull;
		}));
		reg(inst, "sys.thread.Condition", "signal", vmethod(a -> { thisThreadCondition(a).cond.signal(); VNull; }));
		reg(inst, "sys.thread.Condition", "broadcast", vmethod(a -> { thisThreadCondition(a).cond.broadcast(); VNull; }));
		reg(inst, "sys.thread.Semaphore", "acquire", vmethod(a -> {
			var sem = thisThreadSemaphore(a);
			gilBlocking(function() { sem.acquire(); return VNull; });
		}));
		reg(inst, "sys.thread.Semaphore", "tryAcquire", vmethod(a -> EvalValueTools.vbool(
			arg(a, 1) == VNull ? thisThreadSemaphore(a).tryAcquire() : thisThreadSemaphore(a).tryAcquire(toFloat(arg(a, 1))))));
		reg(inst, "sys.thread.Semaphore", "release", vmethod(a -> { thisThreadSemaphore(a).release(); VNull; }));
		#end
		// Self: the running eval's record, in a new instance.
		reg(s, "eval.vm.NativeThread", "self", vfn(a -> threadInstance(ctx, EvalContext.getEval(ctx).thread)));
		// Delay: a sleep, in a blocking section.
		reg(s, "eval.vm.NativeThread", "delay", vfn(a -> {
			var t = num(ctx, arg(a, 0));
			gilBlocking(function() { Sys.sleep(t); return VNull; });
		}));
		// Exit: stops the thread where it is. One the runtime started returns from its start; the main
		// thread lets the lock go and ends through HostRuntime.mainThreadExit.
		reg(s, "eval.vm.NativeThread", "exit", vfn(a -> {
			if (hxc.compiler.HostRuntime.currentIdent() != 0) throw new EvalExceptions.EvalThreadExit();
			if (gilHeldTls.value == true) gilLeave();
			hxc.compiler.HostRuntime.mainThreadExit();
			VNull;
		}));
		// Join: waits for the thread's end, in a blocking section.
		reg(s, "eval.vm.NativeThread", "join", vfn(a -> {
			var t = thisThread(ctx, arg(a, 0));
			gilBlocking(function() { t.join(); return VNull; });
		}));
		reg(s, "eval.vm.NativeThread", "yield", vfn(a -> { gilYield(); VNull; }));
		// readMessage: a non-blocking pop of an empty deque has no value, an uncaught exception no macro
		// catches.
		reg(s, "eval.vm.NativeThread", "readMessage", vfn(a -> {
			var deque = EvalContext.getEval(ctx).thread.deque;
			var v = decodeBool(ctx, arg(a, 0)) ? gilBlocking(function() return deque.pop(true)) : deque.pop(false);
			if (v == null) throw new EvalExceptions.HostException("Option.No_value");
			v;
		}));
		reg(inst, "eval.vm.NativeThread", "id", vmethod(a -> VInt(thisThread(ctx, arg(a, 0)).ident)));
		// sendMessage puts the message in FRONT of the deque, so the next readMessage takes the newest.
		reg(inst, "eval.vm.NativeThread", "sendMessage", vmethod(a -> { thisThread(ctx, arg(a, 0)).deque.push(arg(a, 1)); VNull; }));
		// get_events/set_events: events is a plain value slot on the thread record, null until the typed
		// std installs an EventLoop.
		reg(inst, "eval.vm.NativeThread", "get_events", vmethod(a -> thisThread(ctx, arg(a, 0)).events));
		reg(inst, "eval.vm.NativeThread", "set_events", vmethod(a -> {
			thisThread(ctx, arg(a, 0)).events = arg(a, 1);
			arg(a, 1);
		}));
		// NativeString: a byte string, read and cut by the byte; an index out of range is the error
		// message thrown as a string.
		reg(s, "eval._NativeString.NativeString_Impl_", "fromBytes", vfn(a -> {
			var b = decodeBytes(arg(a, 0));
			VNativeString(ByteString.ofBytes(b, 0, b.length));
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "fromString", vfn(a -> arg(a, 0) == VNull ? VNull : VNativeString(decodeVString(ctx, arg(a, 0)).sstring)));
		reg(s, "eval._NativeString.NativeString_Impl_", "toBytes", vfn(a -> mkBytes(ctx, decodeNativeString(ctx, arg(a, 0)).toBytes())));
		reg(s, "eval._NativeString.NativeString_Impl_", "toString", vfn(a -> EvalString.createUnknown(decodeNativeString(ctx, arg(a, 0)))));
		reg(s, "eval._NativeString.NativeString_Impl_", "concat", vfn(a -> {
			var s1 = decodeNativeString(ctx, arg(a, 0));
			var s2 = decodeNativeString(ctx, arg(a, 1));
			VNativeString(s1 + s2);
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "char", vfn(a -> {
			var str = decodeNativeString(ctx, arg(a, 0));
			var index = decodeInt(ctx, arg(a, 1));
			var c = try str.get(index) catch (_:hxc.eval.EvalExceptions.HostException) EvalExceptions.excString(ctx, "index out of bounds");
			EvalString.createUnknown(ByteString.ofRaw(String.fromCharCode(c)));
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "code", vfn(a -> {
			var str = decodeNativeString(ctx, arg(a, 0));
			var index = decodeInt(ctx, arg(a, 1));
			VInt(try str.get(index) catch (_:hxc.eval.EvalExceptions.HostException) EvalExceptions.excString(ctx, "index out of bounds"));
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "get_length", vfn(a -> VInt(decodeNativeString(ctx, arg(a, 0)).length)));
		reg(s, "eval._NativeString.NativeString_Impl_", "sub", vfn(a -> {
			var str = decodeNativeString(ctx, arg(a, 0));
			var start = decodeInt(ctx, arg(a, 1));
			var maxLength = str.length - start;
			var length = arg(a, 2) == VNull ? maxLength : {
				var l = decodeInt(ctx, arg(a, 2));
				l > maxLength ? maxLength : l;
			};
			VNativeString(try str.sub(start, length) catch (_:hxc.eval.EvalExceptions.HostException) EvalExceptions.excString(ctx, "Invalid arguments for eval.NativeString.sub"));
		}));
		reg(inst, "Date", "getTime", vmethod(a -> VFloat(thisDate(a))));
		reg(inst, "Date", "getFullYear", vmethod(a -> VInt(dateField(ctx, thisDate(a), false, 5) + 1900)));
		reg(inst, "Date", "getMonth", vmethod(a -> VInt(dateField(ctx, thisDate(a), false, 4))));
		reg(inst, "Date", "getDate", vmethod(a -> VInt(dateField(ctx, thisDate(a), false, 3))));
		reg(inst, "Date", "getHours", vmethod(a -> VInt(dateField(ctx, thisDate(a), false, 2))));
		reg(inst, "Date", "getMinutes", vmethod(a -> VInt(dateField(ctx, thisDate(a), false, 1))));
		reg(inst, "Date", "getSeconds", vmethod(a -> VInt(dateField(ctx, thisDate(a), false, 0))));
		reg(inst, "Date", "getDay", vmethod(a -> VInt(dateField(ctx, thisDate(a), false, 6))));
		reg(inst, "Date", "getUTCFullYear", vmethod(a -> VInt(dateField(ctx, thisDate(a), true, 5) + 1900)));
		reg(inst, "Date", "getUTCMonth", vmethod(a -> VInt(dateField(ctx, thisDate(a), true, 4))));
		reg(inst, "Date", "getUTCDate", vmethod(a -> VInt(dateField(ctx, thisDate(a), true, 3))));
		reg(inst, "Date", "getUTCHours", vmethod(a -> VInt(dateField(ctx, thisDate(a), true, 2))));
		reg(inst, "Date", "getUTCMinutes", vmethod(a -> VInt(dateField(ctx, thisDate(a), true, 1))));
		reg(inst, "Date", "getUTCSeconds", vmethod(a -> VInt(dateField(ctx, thisDate(a), true, 0))));
		reg(inst, "Date", "getUTCDay", vmethod(a -> VInt(dateField(ctx, thisDate(a), true, 6))));
		reg(inst, "Date", "getTimezoneOffset", vmethod(a -> VInt(dateTimezoneOffset(ctx, thisDate(a)))));
		reg(inst, "Date", "toString", vmethod(a -> mkStr(sDate(thisDate(a)))));

		// haxe.io.Bytes: a native instance wrapping a host byte buffer.
		reg(s, "haxe.io.Bytes", "alloc", vfn(a -> {
			var n = decodeInt(ctx, arg(a, 0));
			if (n < 0) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("Bytes.create")');
			mkBytes(ctx, haxe.io.Bytes.alloc(n));
		}));
		reg(s, "haxe.io.Bytes", "ofString", vfn(a -> mkBytes(ctx, bytesOfStringValue(ctx, arg(a, 0)))));
		// The digits are the string's bytes, an odd count is an error and nothing else is checked.
		reg(s, "haxe.io.Bytes", "ofHex", vfn(a -> {
			var src = decodeString(ctx, arg(a, 0)).toBytes();
			if ((src.length & 1) != 0) EvalExceptions.excString(ctx, "Not a hex string (odd number of digits)");
			var ret = haxe.io.Bytes.alloc(src.length >> 1);
			for (i in 0...ret.length) {
				var high = src.get(i * 2);
				var low = src.get(i * 2 + 1);
				high = (high & 0xF) + ((high & 0x40) >> 6) * 9;
				low = (low & 0xF) + ((low & 0x40) >> 6) * 9;
				ret.set(i, ((high << 4) | low) & 0xFF);
			}
			mkBytes(ctx, ret);
		}));
		reg(s, "haxe.io.Bytes", "ofData", vfn(a -> arg(a, 0)));
		// A failed read is null.
		reg(s, "haxe.io.Bytes", "fastGet", vfn(a -> {
			var b = decodeBytes(arg(a, 0));
			var pos = decodeInt(ctx, arg(a, 1));
			pos < 0 || pos >= b.length ? VNull : VInt(b.get(pos));
		}));
		reg(s, "haxe.crypto.Crc32", "make", vfn(a -> VInt(haxe.crypto.Crc32.make(decodeBytes(arg(a, 0))))));
		// The digest of the string's bytes.
		reg(s, "haxe.crypto.Md5", "encode", vfn(a -> mkStr(haxe.crypto.Md5.make(decodeString(ctx, arg(a, 0)).toBytes()).toHex())));
		reg(s, "haxe.crypto.Md5", "make", vfn(a -> mkBytes(ctx, haxe.crypto.Md5.make(decodeBytes(arg(a, 0))))));
		reg(s, "haxe.crypto.Sha1", "encode", vfn(a -> mkStr(haxe.crypto.Sha1.make(decodeString(ctx, arg(a, 0)).toBytes()).toHex())));
		reg(s, "haxe.crypto.Sha1", "make", vfn(a -> mkBytes(ctx, haxe.crypto.Sha1.make(decodeBytes(arg(a, 0))))));
		reg(s, "haxe.zip.Compress", "run",
			vfn(a -> {
				var src = decodeBytes(arg(a, 0));
				mkBytes(ctx, haxe.zip.Compress.run(src, decodeInt(ctx, arg(a, 1))));
			}));
		reg(s, "haxe.zip.Uncompress", "run",
			vfn(a -> {
				// The buffer size is defaultInt 65536. The result is the whole stream whatever the chunk,
				// and the host's
				// execute grows its source when handed the position at its end (hxcpp Array::Item), which a
				// small chunk
				// reaches before the output ends, so the host inflates in chunks of at least 64K. A
				// negative size is
				// refused, zlib makes no progress into an empty chunk, and a stream it refuses is a
				// zlib_inflate failure.
				var src = decodeBytes(arg(a, 0));
				var size = defaultInt(ctx, arg(a, 1), 1 << 16);
				if (size < 0) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("Bytes.create")');
				if (size == 0) throw new hxc.eval.EvalExceptions.HostException("zlib_inflate", true);
				var out = try haxe.zip.Uncompress.run(src, size < 1 << 16 ? 1 << 16 : size) catch (_:Dynamic) throw new hxc.eval.EvalExceptions.HostException("zlib_inflate", true);
				mkBytes(ctx, out);
			}));
		reg(s, "haxe.Resource", "listNames", vfn(a -> {
			var names = [for (name in ctx.resources.keys()) mkStr(name)];
			VArray(new VArray(names, names.length));
		}));
		reg(s, "haxe.Resource", "getString", vfn(a -> {
			var bytes = ctx.resources.get(decodeText(ctx, arg(a, 0)));
			// The resource's bytes, as a string (createUnknown).
			bytes == null ? VNull : EvalString.createUnknown(ByteString.ofBytes(bytes, 0, bytes.length));
		}));
		reg(s, "haxe.Resource", "getBytes", vfn(a -> {
			var bytes = ctx.resources.get(decodeText(ctx, arg(a, 0)));
			bytes == null ? VNull : mkBytes(ctx, bytes);
		}));
		// FPHelper: a float is num, a word decodeI32.
		reg(s, "haxe.io.FPHelper", "doubleToI64", vfn(a -> doubleBits(ctx, num(ctx, arg(a, 0)))));
		reg(s, "haxe.io.FPHelper", "floatToI32", vfn(a -> VInt(floatBits(num(ctx, arg(a, 0))))));
		reg(s, "haxe.io.FPHelper", "i32ToFloat", vfn(a -> VFloat(floatOfBits(decodeI32(ctx, arg(a, 0))))));
		reg(s, "haxe.io.FPHelper", "i64ToDouble", vfn(a -> {
			var low = decodeI32(ctx, arg(a, 0));
			var high = decodeI32(ctx, arg(a, 1));
			VFloat(doubleOfBits(low, high));
		}));
		// A failed read is null.
		reg(inst, "haxe.io.Bytes", "get", vmethod(a -> {
			var b = thisBytes(a);
			var pos = decodeInt(ctx, arg(a, 1));
			pos < 0 || pos >= b.length ? VNull : VInt(b.get(pos));
		}));
		// A failed write is ignored, and the byte is the value's low 8 bits.
		reg(inst, "haxe.io.Bytes", "set", vmethod(a -> {
			var b = thisBytes(a);
			var pos = decodeInt(ctx, arg(a, 1));
			var v = decodeIntLow(ctx, arg(a, 2));
			if (pos >= 0 && pos < b.length) b.set(pos, v & 0xFF);
			VNull;
		}));
		reg(inst, "haxe.io.Bytes", "getData", vmethod(a -> arg(a, 0)));
		reg(inst, "haxe.io.Bytes", "getDouble", vmethod(a -> orOutsideBounds(ctx, () -> {
			var pos = decodeInt(ctx, arg(a, 1));
			var b = thisBytes(a);
			pos < 0 || pos > b.length - 8 ? null : VFloat(b.getDouble(pos));
		})));
		reg(inst, "haxe.io.Bytes", "getFloat", vmethod(a -> orOutsideBounds(ctx, () -> {
			var pos = decodeInt(ctx, arg(a, 1));
			var b = thisBytes(a);
			pos < 0 || pos > b.length - 4 ? null : VFloat(b.getFloat(pos));
		})));
		reg(inst, "haxe.io.Bytes", "getInt32", vmethod(a -> orOutsideBounds(ctx, () -> {
			var pos = decodeInt(ctx, arg(a, 1));
			var b = thisBytes(a);
			pos < 0 || pos > b.length - 4 ? null : VInt(b.getInt32(pos));
		})));
		// The decodes come before the handler, the reads and the instance inside it.
		reg(inst, "haxe.io.Bytes", "getInt64", vmethod(a -> {
			var b = thisBytes(a);
			var pos = decodeInt(ctx, arg(a, 1));
			orOutsideBounds(ctx, () -> pos < 0 || pos > b.length - 8 ? null : encodeHaxeI64(ctx, b.getInt32(pos), b.getInt32(pos + 4)));
		}));
		reg(inst, "haxe.io.Bytes", "getString", vmethod(a -> {
			var b = thisBytes(a);
			var pos = decodeInt(ctx, arg(a, 1));
			var len = decodeInt(ctx, arg(a, 2));
			if (pos < 0 || len < 0 || pos > b.length - len) ioError(ctx, "OutsideBounds");
			// The bytes as they are (createUnknown).
			EvalString.createUnknown(ByteString.ofBytes(b, pos, len));
		}));
		reg(inst, "haxe.io.Bytes", "getUInt16", vmethod(a -> orOutsideBounds(ctx, () -> {
			var pos = decodeInt(ctx, arg(a, 1));
			var b = thisBytes(a);
			pos < 0 || pos > b.length - 2 ? null : VInt(b.getUInt16(pos));
		})));
		reg(inst, "haxe.io.Bytes", "toString", vmethod(a -> {
			var b = thisBytes(a);
			// Bytes that are not valid UTF-8 are "Invalid string".
			var bs = ByteString.ofBytes(b, 0, b.length);
			if (!Utf8.validate(bs)) EvalExceptions.excString(ctx, "Invalid string");
			EvalString.createUnknown(bs);
		}));
		reg(inst, "haxe.io.Bytes", "toHex", vmethod(a -> mkStr(thisBytes(a).toHex())));
		reg(inst, "haxe.io.Bytes", "sub", vmethod(a -> {
			var b = thisBytes(a);
			var pos = decodeInt(ctx, arg(a, 1));
			var len = decodeInt(ctx, arg(a, 2));
			if (pos < 0 || len < 0 || pos > b.length - len) ioError(ctx, "OutsideBounds");
			mkBytes(ctx, b.sub(pos, len));
		}));
		// A range outside the bytes is OutsideBounds, and the byte is the value's low 8 bits.
		reg(inst, "haxe.io.Bytes", "fill", vmethod(a -> {
			var b = thisBytes(a);
			var pos = decodeInt(ctx, arg(a, 1));
			var len = decodeInt(ctx, arg(a, 2));
			var value = decodeIntLow(ctx, arg(a, 3));
			if (pos < 0 || len < 0 || pos > b.length - len) ioError(ctx, "OutsideBounds");
			b.fill(pos, len, value & 0xFF);
			VNull;
		}));
		// A range outside either buffer is OutsideBounds.
		reg(inst, "haxe.io.Bytes", "blit", vmethod(a -> {
			var b = thisBytes(a);
			var pos = decodeInt(ctx, arg(a, 1));
			var src = decodeBytes(arg(a, 2));
			var srcpos = decodeInt(ctx, arg(a, 3));
			var len = decodeInt(ctx, arg(a, 4));
			if (len < 0 || srcpos < 0 || srcpos > src.length - len || pos < 0 || pos > b.length - len) ioError(ctx, "OutsideBounds");
			b.blit(pos, src, srcpos, len);
			VNull;
		}));
		// Two byte strings compare by the common prefix, then the length; -1, 0 or 1.
		reg(inst, "haxe.io.Bytes", "compare", vmethod(a -> {
			var b = thisBytes(a);
			VInt(bytesCompare(b, decodeBytes(arg(a, 1))));
		}));
		// Each write is byte by byte, so one that runs off the end has written the bytes before it.
		reg(inst, "haxe.io.Bytes", "setDouble", vmethod(a -> orOutsideBounds(ctx, () -> {
			var bits = bytesOfDouble(num(ctx, arg(a, 2)));
			var pos = decodeInt(ctx, arg(a, 1));
			writeBytesOrFail(thisBytes(a), pos, bits) ? VNull : null;
		})));
		// No handler, so a write off the end is an index-out-of-bounds error no macro catches (as an
		// array resize's is).
		reg(inst, "haxe.io.Bytes", "setFloat", vmethod(a -> {
			var b = thisBytes(a);
			var pos = decodeInt(ctx, arg(a, 1));
			var bits = bytesOfFloat(num(ctx, arg(a, 2)));
			if (!writeBytesOrFail(b, pos, bits)) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("index out of bounds")');
			VNull;
		}));
		reg(inst, "haxe.io.Bytes", "setInt32", vmethod(a -> orOutsideBounds(ctx, () -> {
			var v = decodeI32(ctx, arg(a, 2));
			var pos = decodeInt(ctx, arg(a, 1));
			writeBytesOrFail(thisBytes(a), pos, int32Bytes(v)) ? VNull : null;
		})));
		// The decodes come before the handler, in this order.
		reg(inst, "haxe.io.Bytes", "setInt64", vmethod(a -> {
			var v = arg(a, 2);
			switch (v) {
				case VInstance(_):
				case _: EvalExceptions.unexpectedValue(ctx, v, "instance");
			}
			var pos = decodeInt(ctx, arg(a, 1));
			var high = decodeI32(ctx, instanceFieldRaise(ctx, v, EvalHash.keyHigh));
			var low = decodeI32(ctx, instanceFieldRaise(ctx, v, EvalHash.keyLow));
			var b = thisBytes(a);
			orOutsideBounds(ctx, () -> writeBytesOrFail(b, pos, int32Bytes(low)) && writeBytesOrFail(b, pos + 4, int32Bytes(high)) ? VNull : null);
		}));
		reg(inst, "haxe.io.Bytes", "setUInt16", vmethod(a -> orOutsideBounds(ctx, () -> {
			var v = decodeIntLow(ctx, arg(a, 2)) & 0xFFFF;
			var pos = decodeInt(ctx, arg(a, 1));
			var bits = haxe.io.Bytes.alloc(2);
			bits.set(0, v & 0xFF);
			bits.set(1, v >> 8);
			writeBytesOrFail(thisBytes(a), pos, bits) ? VNull : null;
		})));
		reg(inst, "haxe.io.BytesBuffer", "get_length", vmethod(a -> VInt(bytesBufferLength(thisMap(a)))));
		// BytesBuffer: a byte keeps the value's low bits, a word is decodeI32, a float num and a string
		// decodeVString.
		reg(inst, "haxe.io.BytesBuffer", "addByte", vmethod(a -> {
			var buf = thisMap(a);
			bytesBufferAddByte(buf, decodeIntLow(ctx, arg(a, 1)));
			VNull;
		}));
		reg(inst, "haxe.io.BytesBuffer", "add", vmethod(a -> { var b = decodeBytes(arg(a, 1)); bytesBufferAddBytes(thisMap(a), b, 0, b.length); VNull; }));
		reg(inst, "haxe.io.BytesBuffer", "addString", vmethod(a -> {
			var buf = thisMap(a);
			// decodeVString, and its bytes.
			var b = decodeVString(ctx, arg(a, 1)).sstring.toBytes();
			bytesBufferAddBytes(buf, b, 0, b.length);
			VNull;
		}));
		reg(inst, "haxe.io.BytesBuffer", "addInt32", vmethod(a -> {
			var buf = thisMap(a);
			var v = decodeI32(ctx, arg(a, 1));
			bytesBufferAddByte(buf, v);
			bytesBufferAddByte(buf, v >> 8);
			bytesBufferAddByte(buf, v >> 16);
			bytesBufferAddByte(buf, v >>> 24);
			VNull;
		}));
		// The value must be an instance, then high and low are decoded by decodeI32.
		reg(inst, "haxe.io.BytesBuffer", "addInt64", vmethod(a -> {
			var buf = thisMap(a);
			var v = arg(a, 1);
			switch (v) {
				case VInstance(_):
				case _: EvalExceptions.unexpectedValue(ctx, v, "instance");
			}
			var high = decodeI32(ctx, instanceFieldRaise(ctx, v, EvalHash.keyHigh));
			var low = decodeI32(ctx, instanceFieldRaise(ctx, v, EvalHash.keyLow));
			bytesBufferAddByte(buf, low);
			bytesBufferAddByte(buf, low >> 8);
			bytesBufferAddByte(buf, low >> 16);
			bytesBufferAddByte(buf, low >>> 24);
			bytesBufferAddByte(buf, high);
			bytesBufferAddByte(buf, high >> 8);
			bytesBufferAddByte(buf, high >> 16);
			bytesBufferAddByte(buf, high >>> 24);
			VNull;
		}));
		reg(inst, "haxe.io.BytesBuffer", "addFloat", vmethod(a -> {
			var buf = thisMap(a);
			var b = bytesOfFloat(num(ctx, arg(a, 1)));
			bytesBufferAddBytes(buf, b, 0, b.length);
			VNull;
		}));
		reg(inst, "haxe.io.BytesBuffer", "addDouble", vmethod(a -> {
			var buf = thisMap(a);
			var b = bytesOfDouble(num(ctx, arg(a, 1)));
			bytesBufferAddBytes(buf, b, 0, b.length);
			VNull;
		}));
		// A range outside the source is OutsideBounds.
		reg(inst, "haxe.io.BytesBuffer", "addBytes", vmethod(a -> {
			var buf = thisMap(a);
			var src = decodeBytes(arg(a, 1));
			var pos = decodeInt(ctx, arg(a, 2));
			var len = decodeInt(ctx, arg(a, 3));
			if (pos < 0 || len < 0 || pos > src.length - len) ioError(ctx, "OutsideBounds");
			bytesBufferAddBytes(buf, src, pos, len);
			VNull;
		}));
		reg(inst, "haxe.io.BytesBuffer", "getBytes", vmethod(a -> mkBytes(ctx, bytesBufferToBytes(thisMap(a)))));
		ctors.set(EvalHash.hash("haxe.zip.Compress"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.zip.Compress"));
			var vi = new VInstance(proto.pinstanceFields.copy(), proto);
			zipCompress.set(vi, new haxe.zip.Compress(decodeInt(ctx, arg(a, 0))));
			return VInstance(vi);
		});
		ctors.set(EvalHash.hash("haxe.zip.Uncompress"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.zip.Uncompress"));
			var vi = new VInstance(proto.pinstanceFields.copy(), proto);
			// The window bits are defaultInt 15.
			zipUncompress.set(vi, new haxe.zip.Uncompress(defaultInt(ctx, arg(a, 0), 15)));
			return VInstance(vi);
		});
		ctors.set(EvalHash.hash("eval.vm.NativeSocket"), function(a) return mkNativeSocket(ctx, new sys.net.Socket()));
		reg(inst, "haxe.zip.Compress", "execute", vmethod(a -> zipResult(zipCompress.get(thisInstance(a, "Compress")).execute(
			decodeBytes(arg(a, 1)), toInt(arg(a, 2)), decodeBytes(arg(a, 3)), toInt(arg(a, 4))))));
		reg(inst, "haxe.zip.Compress", "setFlushMode", vmethod(a -> {
			zipCompress.get(thisInstance(a, "Compress")).setFlushMode(flushMode(arg(a, 1)));
			VNull;
		}));
		reg(inst, "haxe.zip.Compress", "close", vmethod(a -> {
			var vi = thisInstance(a, "Compress");
			zipCompress.get(vi).close();
			zipCompress.remove(vi);
			VNull;
		}));
		reg(inst, "haxe.zip.Uncompress", "execute", vmethod(a -> zipResult(zipUncompress.get(thisInstance(a, "Uncompress")).execute(
			decodeBytes(arg(a, 1)), toInt(arg(a, 2)), decodeBytes(arg(a, 3)), toInt(arg(a, 4))))));
		reg(inst, "haxe.zip.Uncompress", "setFlushMode", vmethod(a -> {
			zipUncompress.get(thisInstance(a, "Uncompress")).setFlushMode(flushMode(arg(a, 1)));
			VNull;
		}));
		reg(inst, "haxe.zip.Uncompress", "close", vmethod(a -> {
			var vi = thisInstance(a, "Uncompress");
			zipUncompress.get(vi).close();
			zipUncompress.remove(vi);
			VNull;
		}));
		reg(s, "eval.vm.NativeSocket", "select", vfn(a -> {
			function socketValue(v:EvalValue):sys.net.Socket {
				var field = EvalField.field(ctx, v, EvalHash.hash("socket"));
				return nativeSockets.get(thisInstance([field], "NativeSocket"));
			}
			function list(v:EvalValue):Array<EvalValue> {
				return switch (v) {
					case VArray(va): va.avalues.slice(0, va.alength);
					case _: [];
				};
			}
			var read = list(arg(a, 0));
			var write = list(arg(a, 1));
			var others = list(arg(a, 2));
			var timeout = arg(a, 3) == VNull ? 0.0 : toFloat(arg(a, 3));
			var rs = [for (v in read) socketValue(v)];
			var ws = [for (v in write) socketValue(v)];
			var os = [for (v in others) socketValue(v)];
			// Unix.select waits outside the runtime lock, as the socket calls below do.
			var selected = null;
			gilBlocking(() -> { selected = sys.net.Socket.select(rs, ws, os, timeout); VNull; });
			function keep(src:Array<EvalValue>, selected:Array<sys.net.Socket>):EvalValue {
				var out:Array<EvalValue> = [];
				for (v in src) {
					var sock = socketValue(v);
					for (s in selected) if (sock == s) {
						out.push(v);
						break;
					}
				}
				return VArray(new VArray(out, out.length));
			}
			mkObject([
				{name: "read", value: keep(read, selected.read)},
				{name: "write", value: keep(write, selected.write)},
				{name: "others", value: keep(others, selected.others)}
			]);
		}));
		// Accept, connect, recv and send let go of the lock while they wait, so the interpreter's other
		// threads run meanwhile.
		reg(inst, "eval.vm.NativeSocket", "accept", vmethod(a -> {
			var socket = thisSocket(a);
			var c:sys.net.Socket = null;
			gilBlocking(() -> { c = socket.accept(); VNull; });
			mkNativeSocket(ctx, c);
		}));
		reg(inst, "eval.vm.NativeSocket", "bind", vmethod(a -> {
			thisSocket(a).bind(new sys.net.Host(hostIpString(toInt(arg(a, 1)))), toInt(arg(a, 2)));
			VNull;
		}));
		reg(inst, "eval.vm.NativeSocket", "close", vmethod(a -> {
			var vi = thisInstance(a, "NativeSocket");
			nativeSockets.get(vi).close();
			nativeSockets.remove(vi);
			VNull;
		}));
		reg(inst, "eval.vm.NativeSocket", "connect", vmethod(a -> {
			var socket = thisSocket(a);
			var host = new sys.net.Host(hostIpString(toInt(arg(a, 1))));
			var port = toInt(arg(a, 2));
			gilBlocking(() -> { socket.connect(host, port); VNull; });
			VNull;
		}));
		reg(inst, "eval.vm.NativeSocket", "host", vmethod(a -> hostInfo(thisSocket(a).host())));
		reg(inst, "eval.vm.NativeSocket", "listen", vmethod(a -> { thisSocket(a).listen(toInt(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "peer", vmethod(a -> hostInfo(thisSocket(a).peer())));
		reg(inst, "eval.vm.NativeSocket", "receive", vmethod(a -> {
			var socket = thisSocket(a);
			var buf = decodeBytes(arg(a, 1));
			var pos = toInt(arg(a, 2));
			var len = toInt(arg(a, 3));
			gilBlocking(() -> try VInt(socket.input.readBytes(buf, pos, len)) catch (_:haxe.io.Eof) VInt(0));
		}));
		reg(inst, "eval.vm.NativeSocket", "receiveChar", vmethod(a -> {
			var socket = thisSocket(a);
			gilBlocking(() -> VInt(socket.input.readByte()));
		}));
		reg(inst, "eval.vm.NativeSocket", "send", vmethod(a -> {
			var socket = thisSocket(a);
			var buf = decodeBytes(arg(a, 1));
			var pos = toInt(arg(a, 2));
			var len = toInt(arg(a, 3));
			gilBlocking(() -> VInt(socket.output.writeBytes(buf, pos, len)));
		}));
		reg(inst, "eval.vm.NativeSocket", "sendChar", vmethod(a -> {
			var socket = thisSocket(a);
			var c = toInt(arg(a, 1));
			gilBlocking(() -> { socket.output.writeByte(c); VNull; });
		}));
		reg(inst, "eval.vm.NativeSocket", "setFastSend", vmethod(a -> { thisSocket(a).setFastSend(arg(a, 1) == VTrue); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setBroadcast", vmethod(a -> { setSocketBroadcast(thisSocket(a), arg(a, 1) == VTrue); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setTimeout", vmethod(a -> { thisSocket(a).setTimeout(toFloat(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "shutdown", vmethod(a -> { thisSocket(a).shutdown(arg(a, 1) == VTrue, arg(a, 2) == VTrue); VNull; }));
	}

	// toString: the table folded, so in its keys' order, each entry "key => value" (the key printed as
	// its map keeps it, the value with sValue at depth 0) and the entries joined by "," inside
	// brackets.
	static function mapToString(v:EvalValue):VString {
		var l = [for (e in orderedMapEntries(v)) EvalString.join(EvalString.emptyString(), [sValue(e.key, 0), ascii(" => "), sValue(e.value, 0)])];
		return EvalString.join(EvalString.emptyString(), [ascii("["), EvalString.join(ascii(","), l), ascii("]")]);
	}
}
