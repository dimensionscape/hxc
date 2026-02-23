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
@:cppFileCode("#include <stdio.h>\n#include <string.h>\n#include <time.h>")
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
	public static function decodeVString(ctx:EvalContext, v:EvalValue):String {
		return switch (v) {
			case VString(s): s.sstring;
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
		return EvalExceptions.excString(ctx, v == VNull ? "Null Access" : "Unexpected value " + stringOf(v) + ", expected " + expected, p);
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

	static function decodeBool(ctx:EvalContext, v:EvalValue):Bool {
		return switch (v) {
			case VTrue: true;
			case VFalse: false;
			case _: EvalExceptions.unexpectedValue(ctx, v, "bool");
		};
	}

	// A function is called with the arguments, a field closure with its receiver first, and anything
	// else is "Cannot call <value>".
	static function callValue(ctx:EvalContext, f:EvalValue, args:Array<EvalValue>):EvalValue {
		return switch (f) {
			case VFunction(fn, _): fn(args);
			case VFieldClosure(recv, fn): fn([recv].concat(args));
			case _: EvalExceptions.excString(ctx, "Cannot call " + stringOf(f));
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
		var str = thisString(ctx, a);
		return stringFastCodeAt(str, decodeInt(ctx, arg(a, 1)));
	}

	// String.substr, which haxe.Utf8.sub also is: a position past the end is "" before the length is
	// looked at, and the length is an Int or null (a float is unexpected).
	static function stdStringSubstr(ctx:EvalContext, a:Array<EvalValue>):EvalValue {
		var str = thisString(ctx, a);
		var pos = decodeInt(ctx, arg(a, 1));
		if (pos >= stringLength(str)) return mkStr("");
		return mkStr(stringSubstr(str, pos, switch (arg(a, 2)) {
			case VNull: null;
			case VInt(i): i;
			case v: EvalExceptions.unexpectedValue(ctx, v, "int");
		}));
	}

	// A binary flag is true or null for binary.
	static function fileBinaryFlag(v:EvalValue):Bool {
		return switch (v) {
			case VTrue | VNull: true;
			case _: false;
		};
	}

	// A receiver (or a string argument) that is not a string is unexpected.
	static function thisString(ctx:EvalContext, a:Array<EvalValue>):String {
		return switch (a[0]) {
			case VString(s): normalizeString(s.sstring);
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
			case _: EvalExceptions.excString(ctx, "Cannot call " + stringOf(fn));
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
			if (path == EvalHash.hash("sys.thread.Semaphore")) return name == EvalHash.hash("acquire") || name == EvalHash.hash("tryAcquire") || name == EvalHash.hash("release");
			if (path == EvalHash.hash("sys.thread.Condition")) return name == EvalHash.hash("acquire") || name == EvalHash.hash("tryAcquire") || name == EvalHash.hash("release") || name == EvalHash.hash("wait") || name == EvalHash.hash("signal") || name == EvalHash.hash("broadcast");
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

	static function protoFieldNames(proto:VPrototype):Array<EvalValue> {
		return [for (n in proto.pnames.keys()) mkStr(EvalHash.revHash(n))];
	}

	static function classFieldNames(ctx:EvalContext, proto:VPrototype):Array<EvalValue> {
		var names = new Map<Int, Bool>();
		var out:Array<EvalValue> = [];
		function add(n:Int):Void {
			if (!names.exists(n) && !isReflectHidden(proto.ppath, n, true)) {
				names.set(n, true);
				out.push(mkStr(EvalHash.revHash(n)));
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
		return out;
	}

	static function instanceFieldNames(proto:VPrototype):Array<EvalValue> {
		var names = new Map<Int, Bool>();
		var out:Array<EvalValue> = [];
		function add(n:Int):Void {
			if (!names.exists(n)) {
				names.set(n, true);
				out.push(mkStr(EvalHash.revHash(n)));
			}
		}
		function loop(p:VPrototype):Void {
			if (p.pparent != null) loop(p.pparent);
			for (n in instanceFieldKeys(p)) add(n);
			for (n in sortedFieldKeys(p.pnames)) if (!isReflectHidden(p.ppath, n, false)) add(n);
		}
		loop(proto);
		return out;
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
			case v: EvalExceptions.excString(EvalContext.getCtx(), "Cannot call " + stringOf(v));
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
			case VArray(_): EvalExceptions.excString(ctx, "Unexpected value VArray(" + stringOfDepth(params, 0) + "), expected array");
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

	static function thisBuffer(a:Array<EvalValue>):StringBuf {
		return switch (a[0]) {
			case VInstance(vi): switch (vi.ikind) {
				case IBuffer(b): b;
				case _:
					// A subclass of the native-backed StringBuf constructs through its own typed
					// constructor, so the native buffer attaches on first use and every native call
					// on the instance shares it.
					var b = new StringBuf();
					vi.ikind = IBuffer(b);
					b;
			};
			case _: new StringBuf();
		};
	}

	// EReg's receiver: a value that is not a regex is unexpected.
	static function thisRegex(a:Array<EvalValue>):EReg {
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

	static function countRegexCaptures(pattern:String):Int {
		var count = 0;
		var escaped = false;
		var inClass = false;
		var i = 0;
		while (i < pattern.length) {
			var c = pattern.charCodeAt(i);
			if (escaped) {
				escaped = false;
			} else if (c == "\\".code) {
				escaped = true;
			} else if (c == "[".code) {
				inClass = true;
			} else if (c == "]".code) {
				inClass = false;
			} else if (!inClass && c == "(".code) {
				var next = pattern.charCodeAt(i + 1);
				if (next == "?".code) {
					var kind = pattern.charCodeAt(i + 2);
					if (kind == "'".code) count++;
					else if (kind == "<".code) {
						var after = pattern.charCodeAt(i + 3);
						if (after != "=".code && after != "!".code) count++;
					}
				} else {
					count++;
				}
			}
			i++;
		}
		return count;
	}

	static function validateRegexFlags(flags:String):Void {
		for (i in 0...flags.length) {
			var c = flags.charCodeAt(i);
			switch (c) {
				case "i".code | "s".code | "m".code | "u".code | "g".code:
				case _:
					throw new hxc.eval.EvalExceptions.HostException("Unsupported regexp option '" + flags.charAt(i) + "'", true);
			}
		}
	}

	static function regexEscape(s:String):String {
		var buf = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			switch (c) {
				case "\\".code | "^".code | "$".code | ".".code | "[".code | "]".code | "*".code | "+".code | "?".code:
					buf.addChar("\\".code);
				case _:
			}
			buf.addChar(c);
		}
		return buf.toString();
	}

	static function regexReplacement(re:EReg, by:String, opName:String):String {
		var info = regexInfo(re);
		var captureCount = info == null ? 9 : info.captureCount;
		var buf = new StringBuf();
		var pendingDollar = false;
		for (i in 0...by.length) {
			var c = by.charCodeAt(i);
			if (pendingDollar) {
				pendingDollar = false;
				if (c == "$".code) {
					buf.addChar(c);
				} else if (c >= "0".code && c <= "9".code) {
					var n = c - "0".code;
					if (n > captureCount) throw opName + ": backreference denotes nonexistent subpattern";
					var m = try re.matched(n) catch (_:Dynamic) null;
					if (m != null) buf.add(m);
				} else {
					buf.addChar("$".code);
					buf.addChar(c);
				}
			} else if (c == "$".code) {
				pendingDollar = true;
			} else {
				buf.addChar(c);
			}
		}
		if (pendingDollar) buf.addChar("$".code);
		return buf.toString();
	}

	static function regexReplace(re:EReg, s:String, by:String):String {
		var info = regexInfo(re);
		var global = info != null && info.global;
		var buf = new StringBuf();
		var pos = 0;
		while (true) {
			if (!re.matchSub(s, pos)) {
				buf.add(s.substr(pos));
				break;
			}
			var p = re.matchedPos();
			buf.add(s.substr(pos, p.pos - pos));
			buf.add(regexReplacement(re, by, global ? "Pcre2.replace" : "Pcre2.replace_first"));
			var next = p.pos + p.len;
			if (!global) {
				buf.add(s.substr(next));
				break;
			}
			if (p.len == 0) {
				if (next >= s.length) break;
				buf.add(s.charAt(next));
				pos = next + 1;
			} else {
				pos = next;
				if (pos >= s.length) break;
			}
		}
		return buf.toString();
	}

	static function regexSplit(re:EReg, s:String):Array<String> {
		if (s.length == 0) return [""];
		var info = regexInfo(re);
		var global = info != null && info.global;
		var copyOffset = 0;
		var out:Array<String> = [];
		var pos = 0;
		while (true) {
			if (!re.matchSub(s, pos)) {
				out.push(s.substr(copyOffset));
				break;
			}
			var p = re.matchedPos();
			out.push(s.substr(copyOffset, p.pos - copyOffset));
			copyOffset = p.pos + p.len;
			var next = pos == copyOffset ? copyOffset + 1 : copyOffset;
			if (next >= s.length) {
				out.push("");
				break;
			}
			if (global) {
				pos = next;
			} else {
				out.push(s.substr(copyOffset));
				break;
			}
		}
		return out;
	}

	static function utf16IndexOfCodePoint(s:String, pos:Int):Int {
		if (pos <= 0) return 0;
		var i = 0;
		var count = 0;
		while (i < s.length && count < pos) {
			var c = s.charCodeAt(i++);
			if (c >= 0xD800 && c <= 0xDBFF && i < s.length) {
				var c2 = s.charCodeAt(i);
				if (c2 >= 0xDC00 && c2 <= 0xDFFF) i++;
			}
			count++;
		}
		return i;
	}

	static function utf16LengthOfCodePoints(s:String, pos:Int, len:Int):Int {
		if (len < 0) return -1;
		var start = utf16IndexOfCodePoint(s, pos);
		var end = utf16IndexOfCodePoint(s, pos + len);
		return end - start;
	}

	static function utf16IndexOfUtf8Byte(s:String, bytePos:Int):Null<Int> {
		if (bytePos < 0) return null;
		var i = 0;
		var bytes = 0;
		while (i < s.length) {
			if (bytes == bytePos) return i;
			var c = s.charCodeAt(i++);
			if (c >= 0xD800 && c <= 0xDBFF && i < s.length) {
				var c2 = s.charCodeAt(i);
				if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
					i++;
					c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
				}
			}
			bytes += c < 0x80 ? 1 : (c < 0x800 ? 2 : (c < 0x10000 ? 3 : 4));
			if (bytes > bytePos) return null;
		}
		return bytes == bytePos ? i : null;
	}

	static function regexMatch(re:EReg, s:String):Bool {
		var info = regexInfo(re);
		if (info != null) info.lastSubject = s;
		var ok = re.match(s);
		if (info != null) info.matched = ok;
		return ok;
	}

	static function regexMatchSub(re:EReg, s:String, pos:Int, len:Int):Bool {
		var info = regexInfo(re);
		if (info != null) info.lastSubject = s;
		var start = utf16IndexOfUtf8Byte(s, pos);
		if (start == null) {
			if (info != null) info.matched = false;
			return false;
		}
		var hostLen = -1;
		if (len >= 0) {
			var end = utf16IndexOfUtf8Byte(s, pos + len);
			if (end == null) {
				if (info != null) info.matched = false;
				return false;
			}
			hostLen = end - start;
		}
		var ok = re.matchSub(s, start, hostLen);
		if (info != null) info.matched = ok;
		return ok;
	}

	static function regexEnsureMatched(re:EReg):Void {
		var info = regexInfo(re);
		if (info != null && !info.matched) throw "Invalid regex operation because no match was made";
	}

	static function regexMatchedPos(re:EReg):{pos:Int, len:Int} {
		regexEnsureMatched(re);
		var p = re.matchedPos();
		var info = regexInfo(re);
		var s = info == null ? null : info.lastSubject;
		if (s == null) return p;
		return {
			pos: stringLength(s.substr(0, p.pos)),
			len: stringLength(s.substr(p.pos, p.len))
		};
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

	static function int64Part(ctx:EvalContext, v:EvalValue, name:Int):Int {
		var field = EvalField.field(ctx, v, name);
		if (field == VNull) throw "Int64 field not found";
		return toInt(field);
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
	static var fileInputs = new haxe.ds.ObjectMap<VInstance, {input:haxe.io.Input, file:Null<sys.io.FileInput>, eof:Bool}>();
	static var fileOutputs = new haxe.ds.ObjectMap<VInstance, {output:haxe.io.Output, file:Null<sys.io.FileOutput>}>();
	static var nativeBytesOutputs = new haxe.ds.ObjectMap<VInstance, Map<String, MapEntry>>();
	// A subclass instance whose super constructor is a native builtin (new StringInput -> super ->
	// BytesInput's builtin) delegates its native state to the instance the builtin constructed.
	public static var superDelegates = new haxe.ds.ObjectMap<VInstance, VInstance>();
	static function nativeSelf(vi:VInstance):VInstance {
		var d = superDelegates.get(vi);
		return d != null ? d : vi;
	}

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
	static var nativeThreads = new haxe.ds.ObjectMap<VInstance, {id:Int, messages:sys.thread.Deque<EvalValue>, events:EvalValue}>();
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

	static var nativeThreadSelfTls:sys.thread.Tls<VInstance> = new sys.thread.Tls();
	static var nativeThreadNextId = 1;
	static var evalContext:Null<EvalContext> = null;
	static var nativeXml = new haxe.ds.ObjectMap<VInstance, Xml>();
	static var nativeXmlValues = new haxe.ds.ObjectMap<Xml, VInstance>();
	static var nativeRegexInfo = new haxe.ds.ObjectMap<EReg, {captureCount:Int, global:Bool, lastSubject:Null<String>, matched:Bool, ?source:String}>();
	static var objectFieldOrders = new haxe.ds.ObjectMap<VObject, Array<Int>>();
	static var stringHashCache = new Map<String, Int>();
	static var macroMessages:Array<EvalValue> = [];

	static function regexInfo(re:EReg):{captureCount:Int, global:Bool, lastSubject:Null<String>, matched:Bool, ?source:String} {
		var info = nativeRegexInfo.get(re);
		if (info == null) {
			info = {captureCount: 9, global: false, lastSubject: null, matched: false};
			nativeRegexInfo.set(re, info);
		}
		return info;
	}

	static function objId(o:{}):Int {
		if (objIds.exists(o)) return objIds.get(o);
		var id = objIdNext++;
		objIds.set(o, id);
		return id;
	}

	static function jsonToValue(ctx:EvalContext, v:Dynamic):EvalValue {
		if (v == null) return VNull;
		if (Std.isOfType(v, Bool)) return v ? VTrue : VFalse;
		if (Std.isOfType(v, Int)) return VInt(v);
		if (Std.isOfType(v, Float)) return VFloat(v);
		if (Std.isOfType(v, String)) return mkStr(v);
		if (Std.isOfType(v, Array)) {
			var arr:Array<Dynamic> = v;
			return VArray(new VArray([for (item in arr) jsonToValue(ctx, item)], arr.length));
		}
		var fields = new Map<Int, EvalValue>();
		for (name in Reflect.fields(v)) fields.set(EvalHash.hash(name), jsonToValue(ctx, Reflect.field(v, name)));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function valueToJson(v:EvalValue):Dynamic {
		return switch (EvalValueTools.vresolve(v)) {
			case VNull: null;
			case VTrue: true;
			case VFalse: false;
			case VInt(i): i;
			case VFloat(f): f;
			case VString(s): normalizeString(s.sstring);
			case VNativeString(s): bytesString(rawStringBytes(s), 0, s.length);
			case VArray(va): [for (i in 0...va.alength) valueToJson(va.avalues[i])];
			case VVector(vv): [for (item in vv) valueToJson(item)];
			case VObject(o):
				var obj = {};
				var fields = objectFieldMap(o);
				for (key in objectDictionaryKeys(fields)) Reflect.setField(obj, EvalHash.revHash(key), valueToJson(fields.get(key)));
				obj;
			case VInstance(vi):
				var obj = {};
				for (key in instanceFieldKeys(vi.iproto)) Reflect.setField(obj, EvalHash.revHash(key), valueToJson(vi.ifields[vi.iproto.pinstanceNames.get(key)]));
				obj;
			case _: null;
		}
	}

	static function jsonFieldNames(fields:Map<Int, EvalValue>):Array<String> {
		return [for (key in objectDictionaryKeys(fields)) EvalHash.revHash(key)];
	}

	static function jsonString(s:String):String {
		return haxe.Json.stringify(s);
	}

	static function jsonPrintValue(v:EvalValue, ?space:String):String {
		var buf = new StringBuf();
		var pretty = space != null;
		var nind = 0;
		inline function newl():Void {
			if (pretty) buf.addChar("\n".code);
		}
		inline function ipad():Void {
			if (pretty) for (_ in 0...nind) buf.add(space);
		}
		var write:EvalValue->Void = null;
		function fieldsString(names:Array<String>, get:String->EvalValue):Void {
			buf.addChar("{".code);
			var empty = true;
			for (name in names) {
				var value = EvalValueTools.vresolve(get(name));
				switch (value) {
					case VFunction(_, _) | VFieldClosure(_, _):
						continue;
					case _:
				}
				if (empty) {
					nind++;
					empty = false;
				} else {
					buf.addChar(",".code);
				}
				newl();
				ipad();
				buf.add(jsonString(name));
				buf.addChar(":".code);
				if (pretty) buf.addChar(" ".code);
				write(value);
			}
			if (!empty) {
				nind--;
				newl();
				ipad();
			}
			buf.addChar("}".code);
		}
		write = function(value:EvalValue):Void {
			switch (EvalValueTools.vresolve(value)) {
				case VNull:
					buf.add("null");
				case VTrue:
					buf.add("true");
				case VFalse:
					buf.add("false");
				case VInt(i):
					buf.add(i);
				case VFloat(f):
					buf.add(Math.isFinite(f) ? floatString(f) : "null");
				case VString(s):
					buf.add(jsonString(normalizeString(s.sstring)));
				case VNativeString(s):
					buf.add(jsonString(s));
				case VArray(va):
					buf.addChar("[".code);
					var last = va.alength - 1;
					for (i in 0...va.alength) {
						if (i > 0) {
							buf.addChar(",".code);
						} else {
							nind++;
						}
						newl();
						ipad();
						write(va.avalues[i]);
						if (i == last) {
							nind--;
							newl();
							ipad();
						}
					}
					buf.addChar("]".code);
				case VVector(vv):
					buf.addChar("[".code);
					var last = vv.length - 1;
					for (i in 0...vv.length) {
						if (i > 0) {
							buf.addChar(",".code);
						} else {
							nind++;
						}
						newl();
						ipad();
						write(vv[i]);
						if (i == last) {
							nind--;
							newl();
							ipad();
						}
					}
					buf.addChar("]".code);
				case VObject(o):
					var fields = objectFieldMap(o);
					fieldsString(jsonFieldNames(fields), name -> fields.get(EvalHash.hash(name)));
				case VInstance(vi):
					switch (vi.ikind) {
						case IDate(ts):
							buf.add(jsonString(Date.fromTime(ts).toString()));
						case _:
							var names = [for (key in vi.iproto.pinstanceNames.keys()) EvalHash.revHash(key)];
							names.sort(Reflect.compare);
							fieldsString(names, name -> vi.ifields[vi.iproto.pinstanceNames.get(EvalHash.hash(name))]);
					}
				case VEnumValue(ev):
					buf.add(ev.eindex);
				case VFunction(_, _) | VFieldClosure(_, _):
					buf.add("\"<fun>\"");
				case VPrototype(_) | VLazy(_):
					buf.add("null");
			}
		}
		write(v);
		return buf.toString();
	}

	static function valueToHost(ctx:EvalContext, v:EvalValue):Dynamic {
		return switch (EvalValueTools.vresolve(v)) {
			case VNull: null;
			case VTrue: true;
			case VFalse: false;
			case VInt(i): i;
			case VFloat(f): f;
			case VString(s): normalizeString(s.sstring);
			case VNativeString(s): s;
			case VArray(va): [for (i in 0...va.alength) valueToHost(ctx, va.avalues[i])];
			case VVector(vv): [for (item in vv) valueToHost(ctx, item)];
			case VObject(o):
				var obj = {};
				for (name in fieldNames(VObject(o))) Reflect.setField(obj, name, valueToHost(ctx, EvalField.field(ctx, VObject(o), EvalHash.hash(name))));
				obj;
			case VInstance(vi):
				switch (vi.ikind) {
					case IDate(ts):
						Date.fromTime(ts);
					case IBytes(b):
						b;
					case IMap(m):
						switch (EvalHash.revHash(vi.iproto.ppath)) {
							case "haxe.ds.StringMap":
								var out = new haxe.ds.StringMap<Dynamic>();
								for (entry in m) out.set(stringOf(entry.key), valueToHost(ctx, entry.value));
								out;
							case "haxe.ds.IntMap":
								var out = new haxe.ds.IntMap<Dynamic>();
								for (entry in m) out.set(toInt(entry.key), valueToHost(ctx, entry.value));
								out;
							case _:
								var obj = {};
								for (entry in m) Reflect.setField(obj, stringOf(entry.key), valueToHost(ctx, entry.value));
								obj;
						}
					case _:
						if (vi.iproto.ppath == EvalHash.hash("haxe.ds.List")) {
							var out = new haxe.ds.List<Dynamic>();
							for (item in iterableValues(ctx, VInstance(vi))) out.add(valueToHost(ctx, item));
							out;
						} else {
							var obj = {};
							for (name in fieldNames(VInstance(vi))) Reflect.setField(obj, name, valueToHost(ctx, EvalField.field(ctx, VInstance(vi), EvalHash.hash(name))));
							obj;
						}
				}
			case VEnumValue(ev):
				enumConstructorName(ev);
			case VFunction(_, _) | VFieldClosure(_, _):
				var fn = v;
				Reflect.makeVarArgs(function(args:Array<Dynamic>) {
					return valueToHost(ctx, applyFn(fn, [for (arg in args) hostToValue(ctx, arg)]));
				});
			case _: null;
		}
	}

	static function hostToValue(ctx:EvalContext, v:Dynamic):EvalValue {
		if (v == null) return VNull;
		if (Std.isOfType(v, Bool)) return v ? VTrue : VFalse;
		if (Std.isOfType(v, Int)) return VInt(v);
		if (Std.isOfType(v, Float)) return VFloat(v);
		if (Std.isOfType(v, String)) return mkStr(v);
		if (Reflect.isFunction(v)) {
			return VFunction(function(args:Array<EvalValue>):EvalValue {
				return hostToValue(ctx, Reflect.callMethod(null, v, [for (arg in args) valueToHost(ctx, arg)]));
			}, true);
		}
		if (Std.isOfType(v, Date)) return mkDate(ctx, (cast v : Date).getTime());
		if (Std.isOfType(v, haxe.io.Bytes)) return mkBytes(ctx, (cast v : haxe.io.Bytes));
		if (Std.isOfType(v, haxe.ds.List)) {
			var list:haxe.ds.List<Dynamic> = cast v;
			return listValue(ctx, [for (item in list) hostToValue(ctx, item)]);
		}
		if (Std.isOfType(v, haxe.ds.StringMap)) {
			var map = new Map<String, MapEntry>();
			var src:haxe.ds.StringMap<Dynamic> = cast v;
			for (key in src.keys()) {
				var k = mkStr(key);
				map.set(mapKey(k), {key: k, value: hostToValue(ctx, src.get(key))});
			}
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.ds.StringMap"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(map)));
		}
		if (Std.isOfType(v, haxe.ds.IntMap)) {
			var map = new Map<String, MapEntry>();
			var src:haxe.ds.IntMap<Dynamic> = cast v;
			for (key in src.keys()) {
				var k = VInt(key);
				map.set(mapKey(k), {key: k, value: hostToValue(ctx, src.get(key))});
			}
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.ds.IntMap"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(map)));
		}
		if (Std.isOfType(v, Array)) {
			var arr:Array<Dynamic> = v;
			return VArray(new VArray([for (item in arr) hostToValue(ctx, item)], arr.length));
		}
		var fields = new Map<Int, EvalValue>();
		var order:Array<Int> = [];
		for (name in Reflect.fields(v)) {
			var key = EvalHash.hash(name);
			order.push(key);
			fields.set(key, hostToValue(ctx, Reflect.field(v, name)));
		}
		var o = new VObject([], ODictionary(fields));
		objectFieldOrders.set(o, order);
		return VObject(o);
	}

	static function serializeStringTag(s:String, buf:StringBuf):Void {
		s = urlEncode(s);
		buf.add("y");
		buf.add(s.length);
		buf.add(":");
		buf.add(s);
	}

	static function serializerBoolField(ctx:EvalContext, v:EvalValue, name:String, fallback:Bool):Bool {
		var field = EvalField.dynamicField(ctx, v, EvalHash.hash(name));
		return field == VNull ? fallback : field == VTrue;
	}

	static function serializerUseEnumIndex(ctx:EvalContext, serializer:EvalValue):Bool {
		return serializerBoolField(ctx, serializer, "useEnumIndex", serializerBoolField(ctx, classValue(ctx, EvalHash.hash("haxe.Serializer")), "USE_ENUM_INDEX", false));
	}

	static function serializerUseCache(ctx:EvalContext, serializer:EvalValue):Bool {
		return serializerBoolField(ctx, serializer, "useCache", serializerBoolField(ctx, classValue(ctx, EvalHash.hash("haxe.Serializer")), "USE_CACHE", false));
	}

	static function serializeEval(ctx:EvalContext, value:EvalValue, useEnumIndex:Bool, useCache:Bool, forSignature:Bool = false):String {
		var buf = new StringBuf();
		var cache:Array<EvalValue> = [];
		var customCount = 0;
		var shash = new Map<String, Int>();
		var scount = 0;
		function stringTag(s:String):Void {
			var idx = shash.get(s);
			if (idx != null) {
				buf.add("R");
				buf.add(idx);
				return;
			}
			shash.set(s, scount++);
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
					stringTag(normalizeString(s.sstring));
				case VNativeString(s):
					stringTag(s);
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
						stringTag(name);
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
										stringTag(stringOf(entry.key));
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
										stringTag(stringOf(entry.key));
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
								stringTag(EvalHash.revHash(vi.iproto.ppath));
								for (name in fieldNames(VInstance(vi))) {
									stringTag(name);
									loop(EvalField.field(ctx, VInstance(vi), EvalHash.hash(name)));
								}
								buf.add("g");
							}
					}
				case VEnumValue(ev):
					if (useCache && serializeRef(VEnumValue(ev))) return;
					buf.add(useEnumIndex ? "j" : "w");
					stringTag(EvalHash.revHash(ev.epath));
					if (useEnumIndex) {
						buf.add(":");
						buf.add(ev.eindex);
					} else {
						stringTag(enumConstructorName(ev));
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
					stringTag(EvalHash.revHash(proto.ppath));
				case VFunction(_, _) | VFieldClosure(_, _):
					// A function is a custom entity, 'F' and a running count. custom_name is defined ABOVE loop
					// and closes over value_signature's own parameter, so the cache entry it takes is the
					// TOP-LEVEL value, not the function: the first custom entity in a value registers that
					// top-level value and every later one finds it and prints 'r<index>'. Caching the
					// function itself gave a second F where the reference back-references.
					if (!forSignature) EvalExceptions.excString(ctx, "Cannot serialize function")
					else if (!serializeRef(value)) { buf.add("F"); buf.add(customCount++); }
				case VLazy(_):
					EvalExceptions.excString(ctx, "unreachable");
			}
		}
		loop(value);
		return buf.toString();
	}

	static function mapInstance(ctx:EvalContext, path:String, map:Map<String, MapEntry>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash(path));
		return proto == null ? VNull : VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(map)));
	}

	static function unserializeEval(ctx:EvalContext, data:String):EvalValue {
		var pos = 0;
		var cache:Array<EvalValue> = [];
		var scache:Array<String> = [];
		function get():Int return pos < data.length ? data.charCodeAt(pos) : 0;
		function readDigits():Int {
			var start = pos;
			if (data.charCodeAt(pos) == "-".code) pos++;
			while (pos < data.length) {
				var c = data.charCodeAt(pos);
				if (c < "0".code || c > "9".code) break;
				pos++;
			}
			return Std.parseInt(data.substr(start, pos - start));
		}
		function readFloatString():String {
			var start = pos;
			while (pos < data.length) {
				var c = data.charCodeAt(pos);
				var ok = (c >= "0".code && c <= "9".code) || c == "-".code || c == "+".code || c == ".".code || c == "e".code || c == "E".code;
				if (!ok) break;
				pos++;
			}
			return data.substr(start, pos - start);
		}
		var loop:Void->EvalValue = null;
		var fields:EvalValue->Void = null;
		fields = function(target:EvalValue):Void {
			while (get() != "g".code) {
				var name = stringOf(loop());
				setDynamicField(target, EvalHash.hash(name), loop());
			}
			pos++;
		};
		loop = function():EvalValue {
			var start = pos;
			return switch (data.charCodeAt(pos++)) {
				case "n".code: VNull;
				case "t".code: VTrue;
				case "f".code: VFalse;
				case "z".code: VInt(0);
				case "i".code: VInt(readDigits());
				case "d".code: VFloat(Std.parseFloat(readFloatString()));
				case "k".code: VFloat(hostNan);
				case "m".code: VFloat(Math.NEGATIVE_INFINITY);
				case "p".code: VFloat(Math.POSITIVE_INFINITY);
				case "y".code:
					var len = readDigits();
					if (data.charCodeAt(pos++) != ":".code || data.length - pos < len) EvalExceptions.excString(ctx, "Invalid string length");
					var s = urlDecode(data.substr(pos, len));
					pos += len;
					scache.push(s);
					mkStr(s);
				case "R".code:
					var idx = readDigits();
					if (idx < 0 || idx >= scache.length) EvalExceptions.excString(ctx, "Invalid string reference");
					mkStr(scache[idx]);
				case "r".code:
					var idx = readDigits();
					if (idx < 0 || idx >= cache.length) EvalExceptions.excString(ctx, "Invalid reference");
					cache[idx];
				case "a".code:
					var values:Array<EvalValue> = [];
					var va = new VArray(values, 0);
					var out = VArray(va);
					cache.push(out);
					while (get() != "h".code) {
						if (get() == "u".code) {
							pos++;
							var n = readDigits();
							for (_ in 0...n) values.push(VNull);
						} else {
							values.push(loop());
						}
					}
					pos++;
					va.alength = values.length;
					out;
				case "o".code:
					var out = VObject(new VObject([], ODictionary(new Map())));
					cache.push(out);
					fields(out);
					out;
				case "c".code:
					var name = stringOf(loop());
					var proto = ctx.instancePrototypes.get(EvalHash.hash(name));
					if (proto == null) EvalExceptions.excString(ctx, "Class not found " + name);
					var out = VInstance(new VInstance(proto.pinstanceFields.copy(), proto, INormal));
					cache.push(out);
					fields(out);
					out;
				case "w".code:
					var name = stringOf(loop());
					var constructor = stringOf(loop());
					if (data.charCodeAt(pos++) != ":".code) EvalExceptions.excString(ctx, "Invalid enum format");
					var count = readDigits();
					var args = [for (_ in 0...count) loop()];
					var params = VArray(new VArray(args, args.length));
					var out = createEnumByName(ctx, classValue(ctx, EvalHash.hash(name)), EvalHash.hash(constructor), params);
					cache.push(out);
					out;
				case "j".code:
					var name = stringOf(loop());
					if (data.charCodeAt(pos++) != ":".code) EvalExceptions.excString(ctx, "Invalid enum format");
					var index = readDigits();
					var proto = ctx.staticPrototypes.get(EvalHash.hash(name));
					if (proto == null) EvalExceptions.excString(ctx, "Enum not found " + name);
					var constructor = switch (proto.pkind) {
						case PEnum(cs):
							if (index < 0 || index >= cs.length) EvalExceptions.excString(ctx, "Unknown enum index " + name + "@" + index);
							cs[index].name;
						case _: EvalExceptions.excString(ctx, "Enum not found " + name);
					}
					if (data.charCodeAt(pos++) != ":".code) EvalExceptions.excString(ctx, "Invalid enum format");
					var count = readDigits();
					var args = [for (_ in 0...count) loop()];
					var params = VArray(new VArray(args, args.length));
					var out = createEnumByName(ctx, classValue(ctx, EvalHash.hash(name)), EvalHash.hash(constructor), params);
					cache.push(out);
					out;
				case "l".code:
					var out = mkList(ctx);
					cache.push(out);
					while (get() != "h".code) callValueOn(out, EvalField.dynamicField(ctx, out, EvalHash.hash("add")), [loop()]);
					pos++;
					out;
				case "b".code:
					var map:Map<String, MapEntry> = new Map();
					var out = mapInstance(ctx, "haxe.ds.StringMap", map);
					cache.push(out);
					while (get() != "h".code) {
						var key = loop();
						map.set(mapKey(key), {key: key, value: loop()});
					}
					pos++;
					out;
				case "q".code:
					var map:Map<String, MapEntry> = new Map();
					var out = mapInstance(ctx, "haxe.ds.IntMap", map);
					cache.push(out);
					while (get() == ":".code) {
						pos++;
						var key = VInt(readDigits());
						map.set(mapKey(key), {key: key, value: loop()});
					}
					if (data.charCodeAt(pos++) != "h".code) EvalExceptions.excString(ctx, "Invalid IntMap format");
					out;
				case "M".code:
					var map:Map<String, MapEntry> = new Map();
					var out = mapInstance(ctx, "haxe.ds.ObjectMap", map);
					cache.push(out);
					while (get() != "h".code) {
						var key = loop();
						map.set(mapKey(key), {key: key, value: loop()});
					}
					pos++;
					out;
				case "v".code:
					var out = mkDate(ctx, Std.parseFloat(readFloatString()));
					cache.push(out);
					out;
				case "s".code:
					var len = readDigits();
					if (data.charCodeAt(pos++) != ":".code || data.length - pos < len) EvalExceptions.excString(ctx, "Invalid bytes length");
					pos += len;
					var out = hostToValue(ctx, haxe.Unserializer.run(data.substr(start, pos - start)));
					cache.push(out);
					out;
				case "A".code:
					var name = stringOf(loop());
					var out = classValue(ctx, EvalHash.hash(name));
					if (out == VNull) EvalExceptions.excString(ctx, "Class not found " + name);
					out;
				case "B".code:
					var name = stringOf(loop());
					var out = classValue(ctx, EvalHash.hash(name));
					if (out == VNull) EvalExceptions.excString(ctx, "Enum not found " + name);
					out;
				case "x".code:
					EvalExceptions.excString(ctx, stringOf(loop()));
				case _:
					pos--;
					EvalExceptions.excString(ctx, "Invalid char " + data.charAt(pos) + " at position " + pos);
			}
		};
		return loop();
	}

	static function serializerAppend(ctx:EvalContext, serializer:EvalValue, value:EvalValue):EvalValue {
		var data = serializeEval(ctx, value, serializerUseEnumIndex(ctx, serializer), serializerUseCache(ctx, serializer));
		var buf = EvalField.field(ctx, serializer, EvalHash.hash("buf"));
		thisBuffer([buf]).add(data);
		return VNull;
	}

	static function serializerToString(ctx:EvalContext, serializer:EvalValue):EvalValue {
		var buf = EvalField.field(ctx, serializer, EvalHash.hash("buf"));
		return mkStr(thisBuffer([buf]).toString());
	}

	static function unserializeString(ctx:EvalContext, data:String):EvalValue {
		return unserializeEval(ctx, data);
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

	static function dateToolsFormat(d:Date, f:String):String {
		function get(e:String):String {
			return switch (e) {
				case "%": "%";
				case "a": dateDayShortNames[d.getDay()];
				case "A": dateDayNames[d.getDay()];
				case "b" | "h": dateMonthShortNames[d.getMonth()];
				case "B": dateMonthNames[d.getMonth()];
				case "C": StringTools.lpad(Std.string(Std.int(d.getFullYear() / 100)), "0", 2);
				case "d": StringTools.lpad(Std.string(d.getDate()), "0", 2);
				case "D": dateToolsFormat(d, "%m/%d/%y");
				case "e": Std.string(d.getDate());
				case "F": dateToolsFormat(d, "%Y-%m-%d");
				case "H" | "k": StringTools.lpad(Std.string(d.getHours()), e == "H" ? "0" : " ", 2);
				case "I" | "l":
					var hour = d.getHours() % 12;
					StringTools.lpad(Std.string(hour == 0 ? 12 : hour), e == "I" ? "0" : " ", 2);
				case "m": StringTools.lpad(Std.string(d.getMonth() + 1), "0", 2);
				case "M": StringTools.lpad(Std.string(d.getMinutes()), "0", 2);
				case "n": "\n";
				case "p": d.getHours() > 11 ? "PM" : "AM";
				case "r": dateToolsFormat(d, "%I:%M:%S %p");
				case "R": dateToolsFormat(d, "%H:%M");
				case "s": Std.string(Std.int(d.getTime() / 1000));
				case "S": StringTools.lpad(Std.string(d.getSeconds()), "0", 2);
				case "t": "\t";
				case "T": dateToolsFormat(d, "%H:%M:%S");
				case "u":
					var day = d.getDay();
					day == 0 ? "7" : Std.string(day);
				case "w": Std.string(d.getDay());
				case "y": StringTools.lpad(Std.string(d.getFullYear() % 100), "0", 2);
				case "Y": Std.string(d.getFullYear());
				case _: throw "Date.format %" + e + "- not implemented yet.";
			}
		}
		var r = new StringBuf();
		var p = 0;
		while (true) {
			var np = f.indexOf("%", p);
			if (np < 0) break;
			r.addSub(f, p, np - p);
			r.add(get(f.substr(np + 1, 1)));
			p = np + 2;
		}
		r.addSub(f, p, f.length - p);
		return r.toString();
	}

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

	static function bytesString(b:haxe.io.Bytes, pos:Int, len:Int):String {
		var out = new StringBuf();
		var end = pos + len;
		var i = pos;
		while (i < end) {
			var c = b.get(i++);
			if (c < 0x80) {
				out.addChar(c);
			} else if (c >= 0xC2 && c <= 0xDF) {
				if (i < end) {
					var c2 = b.get(i);
					if (c2 >= 0x80 && c2 <= 0xBF) {
						i++;
						addUtf8Char(out, ((c & 0x1F) << 6) | (c2 & 0x3F));
					} else {
						addUtf8Char(out, 0xFFFD);
					}
				} else {
					addUtf8Char(out, 0xFFFD);
				}
			} else if (c >= 0xE0 && c <= 0xEF) {
				var min = c == 0xE0 ? 0xA0 : 0x80;
				if (i + 1 < end) {
					var c2 = b.get(i);
					var c3 = b.get(i + 1);
					if (c2 >= min && c2 <= 0xBF && c3 >= 0x80 && c3 <= 0xBF) {
						i += 2;
						addUtf8Char(out, ((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F));
					} else {
						addUtf8Char(out, 0xFFFD);
					}
				} else {
					i = end;
					addUtf8Char(out, 0xFFFD);
				}
			} else if (c >= 0xF0 && c <= 0xF4) {
				var min = c == 0xF0 ? 0x90 : 0x80;
				if (i + 2 < end) {
					var c2 = b.get(i);
					var c3 = b.get(i + 1);
					var c4 = b.get(i + 2);
					if (c2 >= min && c2 <= 0xBF && c3 >= 0x80 && c3 <= 0xBF && c4 >= 0x80 && c4 <= 0xBF) {
						i += 3;
						addUtf8Char(out, ((c & 0x07) << 18) | ((c2 & 0x3F) << 12) | ((c3 & 0x3F) << 6) | (c4 & 0x3F));
					} else {
						addUtf8Char(out, 0xFFFD);
					}
				} else {
					i = end;
					addUtf8Char(out, 0xFFFD);
				}
			} else {
				addUtf8Char(out, 0xFFFD);
			}
		}
		return out.toString();
	}

	static function bytesRawString(b:haxe.io.Bytes, pos:Int, len:Int):String {
		var out = new StringBuf();
		for (i in pos...pos + len) out.addChar(b.get(i));
		return out.toString();
	}

	static function rawStringBytes(s:String):haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(s.length);
		for (i in 0...s.length) b.set(i, s.charCodeAt(i) & 0xFF);
		return b;
	}

	static function bytesStringStrict(b:haxe.io.Bytes, pos:Int, len:Int):String {
		var raw = bytesRawString(b, pos, len);
		if (utf8ByteCodes(raw) == null) throw "Invalid string";
		return bytesString(b, pos, len);
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
		fileInputs.set(vi, {input: input, file: file, eof: false});
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
		fileOutputs.set(vi, {output: output, file: file});
		return VInstance(vi);
	}

	static function thisFileInput(a:Array<EvalValue>):{input:haxe.io.Input, file:Null<sys.io.FileInput>, eof:Bool} {
		return fileInputs.get(thisInstance(a, "FileInput"));
	}

	static function thisFileOutput(a:Array<EvalValue>):{output:haxe.io.Output, file:Null<sys.io.FileOutput>} {
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

	static function hashMethodValue(v:EvalValue):haxe.crypto.Hmac.HashMethod {
		return switch (v) {
			case VEnumValue(ev): switch (ev.eindex) {
				case 1: haxe.crypto.Hmac.HashMethod.SHA1;
				case 2: haxe.crypto.Hmac.HashMethod.SHA256;
				case _: haxe.crypto.Hmac.HashMethod.MD5;
			}
			case _: haxe.crypto.Hmac.HashMethod.MD5;
		}
	}

	static function mkHmac(ctx:EvalContext, method:EvalValue):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.crypto.Hmac"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		cryptoHmacs.set(vi, new haxe.crypto.Hmac(hashMethodValue(method)));
		return VInstance(vi);
	}

	static function thisHmac(a:Array<EvalValue>):haxe.crypto.Hmac {
		var hmac = cryptoHmacs.get(thisInstance(a, "Hmac"));
		if (hmac == null) throw "Unexpected value for Hmac";
		return hmac;
	}

	static function mkBaseCode(ctx:EvalContext, base:EvalValue):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.crypto.BaseCode"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		cryptoBaseCodes.set(vi, new haxe.crypto.BaseCode(decodeBytes(base)));
		return VInstance(vi);
	}

	static function thisBaseCode(a:Array<EvalValue>):haxe.crypto.BaseCode {
		var baseCode = cryptoBaseCodes.get(thisInstance(a, "BaseCode"));
		if (baseCode == null) throw "Unexpected value for BaseCode";
		return baseCode;
	}

	static function mkTemplate(ctx:EvalContext, source:EvalValue):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.Template"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		nativeTemplates.set(vi, new haxe.Template(stringOf(source)));
		return VInstance(vi);
	}

	static function thisTemplate(a:Array<EvalValue>):haxe.Template {
		var template = nativeTemplates.get(thisInstance(a, "Template"));
		if (template == null) throw "Unexpected value for Template";
		return template;
	}

	static function templateGlobalsHost(ctx:EvalContext):Dynamic {
		var proto = ctx.staticPrototypes.get(EvalHash.hash("haxe.Template"));
		if (proto == null) return {};
		var idx = proto.pnames.get(EvalHash.hash("globals"));
		return idx == null ? {} : valueToHost(ctx, proto.pfields[idx]);
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

	// A host list becomes the std's List, built through its own interpreted constructor and add;
	// the reference interprets haxe.ds.List and hxc's native stood in for it.
	static function listValue(ctx:EvalContext, items:Array<EvalValue>):EvalValue {
		var l = EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.ds.List"), []);
		for (item in items) callValueOn(l, EvalField.dynamicField(ctx, l, EvalHash.hash("add")), [item]);
		return l;
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

	static function callStaticValue(ctx:EvalContext, typeName:String, fieldName:String, args:Array<EvalValue>):EvalValue {
		var proto = ctx.staticPrototypes.get(EvalHash.hash(typeName));
		if (proto == null) return VNull;
		return switch (EvalField.field(ctx, VPrototype(proto), EvalHash.hash(fieldName))) {
			case VFunction(f, _): f(args);
			case VFieldClosure(recv, f): f([recv].concat(args));
			case _: VNull;
		};
	}

	static function mkNativeThread(ctx:EvalContext, ?job:EvalValue):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("eval.vm.NativeThread"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		// Tevents starts vnull; the typed std sets it.
		nativeThreads.set(vi, {id: nativeThreadNextId++, messages: new sys.thread.Deque(), events: VNull});
		if (job != null && job != VNull) {
			// A real OS thread runs the job under the interpreter lock; its per-thread self and environment
			// stack come from thread-locals. An uncaught interpreted exception reports on stderr like the
			// reference thread wrapper.
			var j = job;
			sys.thread.Thread.create(function() {
				gilEnter();
				nativeThreadSelfTls.value = vi;
				try {
					applyFn(j, []);
				} catch (e:Dynamic) {
					try Sys.stderr().writeString(Std.string(e) + "
") catch (_:Dynamic) {}
				}
				gilLeave();
			});
		}
		return VInstance(vi);
	}

	static function nativeThreadSelfValue(ctx:EvalContext):EvalValue {
		if (nativeThreadSelfTls.value == null) {
			switch (mkNativeThread(ctx)) {
				case VInstance(vi): nativeThreadSelfTls.value = vi;
				case v: return v;
			}
		}
		return VInstance(nativeThreadSelfTls.value);
	}

	static function nativeThreadData(a:Array<EvalValue>):{id:Int, messages:sys.thread.Deque<EvalValue>, events:EvalValue} {
		return nativeThreads.get(thisInstance(a, "NativeThread"));
	}

	static function setStaticFieldIfExists(ctx:EvalContext, typeName:String, fieldName:String, value:EvalValue):Void {
		var proto = ctx.staticPrototypes.get(EvalHash.hash(typeName));
		if (proto == null) return;
		var idx = proto.pnames.get(EvalHash.hash(fieldName));
		if (idx != null) proto.pfields[idx] = value;
	}

	static function xmlTypeValue(x:Xml):EvalValue {
		return VInt(cast x.nodeType);
	}

	static function setInstanceFieldIfExists(vi:VInstance, name:String, value:EvalValue):Void {
		var idx = vi.iproto.pinstanceNames.get(EvalHash.hash(name));
		if (idx != null) vi.ifields[idx] = value;
	}

	static function ensureInstanceField(proto:VPrototype, name:String):Void {
		var key = EvalHash.hash(name);
		if (!proto.pinstanceNames.exists(key)) {
			proto.pinstanceNames.set(key, proto.pinstanceFields.length);
			proto.pinstanceFields.push(VNull);
		}
	}

	static function instanceFieldIfExists(vi:VInstance, name:String):Null<EvalValue> {
		var idx = vi.iproto.pinstanceNames.get(EvalHash.hash(name));
		return idx == null ? null : vi.ifields[idx];
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

	static function syncXmlHostFields(vi:VInstance, x:Xml):Void {
		switch (instanceFieldIfExists(vi, "nodeName")) {
			case VString(s) if (x.nodeType == Xml.Element): x.nodeName = normalizeString(s.sstring);
			case VNativeString(s) if (x.nodeType == Xml.Element): x.nodeName = s;
			case _:
		}
		switch (instanceFieldIfExists(vi, "nodeValue")) {
			case VString(s) if (x.nodeType != Xml.Element && x.nodeType != Xml.Document): x.nodeValue = normalizeString(s.sstring);
			case VNativeString(s) if (x.nodeType != Xml.Element && x.nodeType != Xml.Document): x.nodeValue = s;
			case _:
		}
	}

	static function syncXmlHostTreeFields(vi:VInstance, x:Xml):Void {
		syncXmlHostFields(vi, x);
		switch (x.nodeType) {
			case Xml.Element | Xml.Document:
				for (child in x) {
					var childVi = nativeXmlValues.get(child);
					if (childVi != null) syncXmlHostTreeFields(childVi, child);
				}
			case _:
		}
	}

	static function thisXml(a:Array<EvalValue>):Xml {
		var vi = thisInstance(a, "Xml");
		var x = nativeXml.get(vi);
		if (x != null) syncXmlHostTreeFields(vi, x);
		return x;
	}

	static function xmlChildren(ctx:EvalContext, x:Xml, ?elementsOnly:Bool, ?name:String):Array<EvalValue> {
		var out:Array<EvalValue> = [];
		for (child in x) {
			if (elementsOnly == true && child.nodeType != Xml.Element) continue;
			if (name != null && child.nodeName != name) continue;
			out.push(xmlValue(ctx, child));
		}
		return out;
	}

	static function processArgs(ctx:EvalContext, v:EvalValue):Null<Array<String>> {
		return switch (v) {
			case VNull: null;
			case VArray(va): [for (i in 0...va.alength) stringOf(va.avalues[i])];
			case _: EvalExceptions.unexpectedValue(ctx, v, "array");
		}
	}

	static function stringArray(v:EvalValue):Array<String> {
		return switch (v) {
			case VArray(va): [for (i in 0...va.alength) va.avalues[i] == VNull ? null : stringOf(va.avalues[i])];
			case _: [];
		}
	}

	public static function valueKind(v:EvalValue):String {
		return EvalExceptions.sValueKind(v);
	}

	static function pathToString(ctx:EvalContext, v:EvalValue):String {
		var dir = EvalField.field(ctx, v, EvalHash.hash("dir"));
		var file = EvalField.field(ctx, v, EvalHash.hash("file"));
		var ext = EvalField.field(ctx, v, EvalHash.hash("ext"));
		var backslash = EvalField.field(ctx, v, EvalHash.hash("backslash")) == VTrue;
		return (dir == VNull ? "" : stringOf(dir) + (backslash ? "\\" : "/"))
			+ (file == VNull ? "" : stringOf(file))
			+ (ext == VNull ? "" : "." + stringOf(ext));
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

	static function eof(ctx:EvalContext):Dynamic {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.io.Eof"));
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

	static function mkBytesOutput(ctx:EvalContext):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.io.BytesOutput"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		var buf = newBytesBufferMap();
		nativeBytesOutputs.set(vi, buf);
		setInstanceFieldIfExists(vi, "b", bytesBufferValue(ctx, buf));
		return VInstance(vi);
	}

	static function thisBytesOutput(a:Array<EvalValue>):Map<String, MapEntry> {
		var vi = thisInstance(a, "BytesOutput");
		var buf = nativeBytesOutputs.get(vi);
		if (buf == null) throw "Unexpected value for BytesOutput";
		return buf;
	}

	static function mkBytesInput(ctx:EvalContext, bytesValue:EvalValue, posValue:EvalValue, lenValue:EvalValue):EvalValue {
		var bytes = decodeBytes(bytesValue);
		var pos = posValue == VNull ? 0 : toInt(posValue);
		var len = lenValue == VNull ? bytes.length - pos : toInt(lenValue);
		if (pos < 0 || len < 0 || pos + len > bytes.length) throw "Outside bounds";
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.io.BytesInput"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		nativeBytesInputs.set(vi, {bytes: bytes, pos: pos, len: len, totlen: len});
		syncBytesInputFields(vi);
		return VInstance(vi);
	}

	static function thisBytesInput(a:Array<EvalValue>):{bytes:haxe.io.Bytes, pos:Int, len:Int, totlen:Int} {
		var vi = nativeSelf(thisInstance(a, "BytesInput"));
		var input = nativeBytesInputs.get(vi);
		if (input == null) throw "Unexpected value for BytesInput";
		return input;
	}

	static function syncBytesInputFields(vi:VInstance):Void {
		var input = nativeBytesInputs.get(vi);
		if (input == null) return;
		setInstanceFieldIfExists(vi, "pos", VInt(input.pos));
		setInstanceFieldIfExists(vi, "len", VInt(input.len));
		setInstanceFieldIfExists(vi, "totlen", VInt(input.totlen));
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

	static function nativeStringOf(v:EvalValue):String {
		return switch (v) {
			case VNativeString(s): s;
			case VString(s):
				var b = haxe.io.Bytes.ofString(normalizeString(s.sstring));
				bytesRawString(b, 0, b.length);
			case _:
				var s = stringOf(v);
				var b = haxe.io.Bytes.ofString(s);
				bytesRawString(b, 0, b.length);
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

	public static function exceptionStackValue(ctx:EvalContext):EvalValue {
		// The recorded frames are already innermost-first, the order a stack value carries.
		return stackItems(ctx, EvalContext.getEval(ctx).exceptionStack);
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

	static function objectIterator(items:Array<EvalValue>):EvalValue {
		var index = 0;
		return mkObject([
			{name: "hasNext", value: VFunction(function(_) return EvalValueTools.vbool(index < items.length), true)},
			{name: "next", value: VFunction(function(_) return index < items.length ? items[index++] : VNull, true)}
		]);
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

	static function traceString(ctx:EvalContext, value:EvalValue, infos:EvalValue):String {
		var s = stringOf(value);
		if (infos == VNull) return s + "\n";
		var fileName = stringOf(EvalField.field(ctx, infos, EvalHash.hash("fileName")));
		var lineNumber = toInt(EvalField.field(ctx, infos, EvalHash.hash("lineNumber")));
		var params = EvalField.field(ctx, infos, EvalHash.hash("customParams"));
		var parts = [s];
		switch (params) {
			case VArray(va):
				for (i in 0...va.alength) parts.push(stringOf(va.avalues[i]));
			case _:
		}
		// Trace appends the platform line end like println. .
		return fileName + ":" + lineNumber + ": " + parts.join(",") + (Sys.systemName() == "Windows" ? "\r\n" : "\n");
	}

	static function writeStdoutString(s:String, newline:Bool):Void {
		// During a wait-server request, macro-time stdout joins the framed response; the whole logical
		// write (content plus line end) is one encoded chunk.
		if (hxc.Compiler.requestOutput != null) {
			hxc.Compiler.serverPrint(s + (newline ? (Sys.systemName() == "Windows" ? "\r\n" : "\n") : ""));
			return;
		}
		var start = 0;
		var i = 0;
		while (i < s.length) {
			if (s.charCodeAt(i) == 0) {
				if (i > start) Sys.print(s.substr(start, i - start));
				var out = Sys.stdout();
				out.writeByte(0);
				start = i + 1;
			}
			i++;
		}
		if (start < s.length) Sys.print(s.substr(start));
		// Eval's println appends the PLATFORM line end explicitly (stdout itself is binary), so
		// interpreted output keeps \r\n on Windows.
		if (newline) {
			Sys.print(Sys.systemName() == "Windows" ? "\r\n" : "\n");
			// print_endline flushes; a macro's println must reach the terminal before a
			// diagnostic the compiler then writes to stderr, as it does in the reference.
			Sys.stdout().flush();
		}
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
			case VNativeString(s): "ns:" + s;
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
			case VString(s):
				// Two host strings with equal units can still hash apart when their internal
				// representations differ (byte string vs wide string); rebuild per unit so
				// every equal key shares one concrete form.
				var n = normalizeString(s.sstring);
				var b = new StringBuf();
				for (i in 0...n.length) b.addChar(n.charCodeAt(i));
				b.toString();
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

	public static function normalizeString(s:String):String {
		var codes = utf8ByteCodes(s);
		if (codes == null) return s;
		var buf = new StringBuf();
		for (c in codes) addUtf8Char(buf, c);
		return buf.toString();
	}

	public static function stringLength(s:String):Int {
		return utf8Codes(s).length;
	}

	public static function stringCompare(a:String, b:String):Int {
		var ac = utf8Codes(normalizeString(a));
		var bc = utf8Codes(normalizeString(b));
		var len = ac.length < bc.length ? ac.length : bc.length;
		for (i in 0...len) {
			if (ac[i] != bc[i]) return ac[i] < bc[i] ? -1 : 1;
		}
		return ac.length == bc.length ? 0 : (ac.length < bc.length ? -1 : 1);
	}

	public static function runtimeStringLength(s:VString):Int {
		var logical = stringLength(s.sstring);
		return s.slength != s.sstring.length || (s.slength != logical && isUtf8ByteString(s.sstring)) ? s.slength : logical;
	}

	static inline function mkStr(s:String):EvalValue {
		var ns = normalizeString(s);
		return VString(new VString(ns, stringLength(ns)));
	}
	static inline function mkStrLen(s:String, len:Int):EvalValue return VString(new VString(normalizeString(s), len));
	static inline function mkNullStr(s:String):EvalValue return s == null ? VNull : mkStr(s);

	public static function stringFastCodeAt(s:String, index:Int):EvalValue {
		var codes = utf8Codes(s);
		return index < 0 || index >= codes.length ? VNull : VInt(codes[index]);
	}

	static function stringFromCodes(codes:Array<Int>, start:Int, len:Int):String {
		var buf = new StringBuf();
		var end = Std.int(Math.min(codes.length, start + len));
		for (i in start...end) addUtf8Char(buf, codes[i]);
		return buf.toString();
	}

	static function stringCharAt(s:String, index:Int):String {
		var codes = utf8Codes(s);
		return index < 0 || index >= codes.length ? "" : stringFromCodes(codes, index, 1);
	}

	static function addUtf8Char(buf:StringBuf, c:Int):Void {
		// fromCharCode encodes the BMP correctly but caps there (astral becomes U+FFFD);
		// addChar handles the astral range but writes small values as raw bytes.
		if (c > 0xFFFF) buf.addChar(c) else buf.add(String.fromCharCode(c));
	}

	static function addUtf8EncodedChar(buf:StringBuf, c:Int):Void {
		if (c < 0x80) {
			buf.addChar(c);
		} else if (c < 0x800) {
			buf.addChar(0xC0 | (c >> 6));
			buf.addChar(0x80 | (c & 0x3F));
		} else if (c < 0x10000) {
			buf.addChar(0xE0 | (c >> 12));
			buf.addChar(0x80 | ((c >> 6) & 0x3F));
			buf.addChar(0x80 | (c & 0x3F));
		} else {
			buf.addChar(0xF0 | (c >> 18));
			buf.addChar(0x80 | ((c >> 12) & 0x3F));
			buf.addChar(0x80 | ((c >> 6) & 0x3F));
			buf.addChar(0x80 | (c & 0x3F));
		}
	}

	static function utf8Encode(s:String):String {
		var buf = new StringBuf();
		for (c in utf8Codes(s)) addUtf8EncodedChar(buf, c);
		return buf.toString();
	}

	static function utf8EncodedLength(s:String):Int {
		var len = 0;
		for (c in utf8Codes(s)) {
			len += c < 0x80 ? 1 : (c < 0x800 ? 2 : (c < 0x10000 ? 3 : 4));
		}
		return len;
	}

	static function utf8Decode(s:String):String {
		var buf = new StringBuf();
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i++);
			if (c < 0x80) {
				addUtf8Char(buf, c);
			} else if (c < 0xE0 && i < s.length) {
				addUtf8Char(buf, ((c & 0x1F) << 6) | (s.charCodeAt(i++) & 0x3F));
			} else if (c < 0xF0 && i + 1 < s.length) {
				var c2 = s.charCodeAt(i++);
				var c3 = s.charCodeAt(i++);
				addUtf8Char(buf, ((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F));
			} else if (i + 2 < s.length) {
				var c2 = s.charCodeAt(i++);
				var c3 = s.charCodeAt(i++);
				var c4 = s.charCodeAt(i++);
				addUtf8Char(buf, ((c & 0x07) << 18) | ((c2 & 0x3F) << 12) | ((c3 & 0x3F) << 6) | (c4 & 0x3F));
			} else {
				addUtf8Char(buf, c);
			}
		}
		return buf.toString();
	}

	static function utf8Codes(s:String):Array<Int> {
		var bytes = utf8ByteCodes(s);
		if (bytes != null) return bytes;
		var out = [];
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i++);
			if (c >= 0xD800 && c <= 0xDBFF && i < s.length) {
				var c2 = s.charCodeAt(i);
				if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
					i++;
					c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
				}
			}
			out.push(c);
		}
		return out;
	}

	static function utf8ByteCodes(s:String):Null<Array<Int>> {
		var out = [];
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i++);
			if (c > 0xFF) return null;
			if (c < 0x80) {
				out.push(c);
			} else if (c >= 0xC2 && c <= 0xDF && i < s.length) {
				var c2 = s.charCodeAt(i++);
				if (c2 < 0x80 || c2 > 0xBF) return null;
				out.push(((c & 0x1F) << 6) | (c2 & 0x3F));
			} else if (c >= 0xE0 && c <= 0xEF && i + 1 < s.length) {
				var c2 = s.charCodeAt(i++);
				var c3 = s.charCodeAt(i++);
				var min = c == 0xE0 ? 0xA0 : 0x80;
				if (c2 < min || c2 > 0xBF || c3 < 0x80 || c3 > 0xBF) return null;
				out.push(((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F));
			} else if (c >= 0xF0 && c <= 0xF4 && i + 2 < s.length) {
				var c2 = s.charCodeAt(i++);
				var c3 = s.charCodeAt(i++);
				var c4 = s.charCodeAt(i++);
				var min = c == 0xF0 ? 0x90 : 0x80;
				if (c2 < min || c2 > 0xBF || c3 < 0x80 || c3 > 0xBF || c4 < 0x80 || c4 > 0xBF) return null;
				out.push(((c & 0x07) << 18) | ((c2 & 0x3F) << 12) | ((c3 & 0x3F) << 6) | (c4 & 0x3F));
			} else {
				return null;
			}
		}
		return out;
	}

	static function utf8Valid(s:String):Bool {
		if (utf8ByteCodes(s) != null) return true;
		for (i in 0...s.length) if (s.charCodeAt(i) > 0xFF) return true;
		return false;
	}

	static function bytesOfStringValue(v:EvalValue):haxe.io.Bytes {
		return switch (EvalValueTools.vresolve(v)) {
			case VString(s) if (s.slength != stringLength(s.sstring) && utf8ByteCodes(s.sstring) != null):
				haxe.io.Bytes.ofString(s.sstring);
			case VString(s):
				haxe.io.Bytes.ofString(normalizeString(s.sstring));
			case VNativeString(s):
				haxe.io.Bytes.ofString(s);
			// decode_vstring, a null a Null Access.
			case VNull: EvalExceptions.excString(EvalContext.getCtx(), "Null Access");
			case other: EvalExceptions.excString(EvalContext.getCtx(), "Unexpected value " + valueKind(other) + "(" + stringOf(other) + "), expected string");
		}
	}

	static function stringReplace(s:String, sub:String, by:String):String {
		s = normalizeString(s);
		sub = normalizeString(sub);
		by = normalizeString(by);
		if (sub.length == 0) {
			if (by.length == 0 || s.length == 0) return s;
			var codes = utf8Codes(s);
			var b = new StringBuf();
			for (i in 0...codes.length) {
				b.add(stringFromCodes(codes, i, 1));
				if (i != codes.length - 1) b.add(by);
			}
			return b.toString();
		}
		return s.split(sub).join(by);
	}

	static function stringSubstr(s:String, pos:Int, len:Null<Int>):String {
		var codes = utf8Codes(s);
		var l = codes.length;
		if (pos < 0) {
			pos = l + pos;
			if (pos < 0) pos = 0;
		}
		if (pos > l) pos = l;
		var n = len == null ? l - pos : len;
		if (n < 0) n = l + n - pos;
		if (n < 0) n = 0;
		return stringFromCodes(codes, pos, n);
	}

	static function stringSubstring(s:String, start:Int, end:Null<Int>):String {
		var codes = utf8Codes(s);
		var l = codes.length;
		if (start < 0) start = 0;
		if (start > l) start = l;
		var stop = end == null ? l : end;
		if (stop < 0) stop = 0;
		if (stop > l) stop = l;
		if (start > stop) {
			var tmp = start;
			start = stop;
			stop = tmp;
		}
		return stringFromCodes(codes, start, stop - start);
	}

	static function stringSplit(s:String, delimiter:String):Array<String> {
		s = normalizeString(s);
		delimiter = normalizeString(delimiter);
		if (delimiter == "") {
			var codes = utf8Codes(s);
			return [for (i in 0...codes.length) stringFromCodes(codes, i, 1)];
		}
		return s.split(delimiter);
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

	static function stringIndexOf(s:String, sub:String, start:Int):Int {
		var codes = utf8Codes(normalizeString(s));
		var subCodes = utf8Codes(normalizeString(sub));
		if (subCodes.length == 0) {
			if (start < 0) return 0;
			return start > codes.length ? codes.length : start;
		}
		if (start < 0) start = codes.length + start;
		if (start < 0) start = 0;
		if (start > codes.length - subCodes.length) return -1;
		var max = codes.length - subCodes.length;
		for (i in start...max + 1) {
			var matched = true;
			for (j in 0...subCodes.length) {
				if (codes[i + j] != subCodes[j]) {
					matched = false;
					break;
				}
			}
			if (matched) return i;
		}
		return -1;
	}

	static function stringLastIndexOf(s:String, sub:String, startValue:Null<Int>):Int {
		var codes = utf8Codes(normalizeString(s));
		var subCodes = utf8Codes(normalizeString(sub));
		var start:Int = startValue == null ? codes.length : startValue;
		if (subCodes.length == 0) {
			if (start < 0) return 0;
			return start > codes.length ? codes.length : start;
		}
		if (start < 0) return -1;
		var i = start > codes.length - subCodes.length ? codes.length - subCodes.length : start;
		while (i >= 0) {
			var matched = true;
			for (j in 0...subCodes.length) {
				if (codes[i + j] != subCodes[j]) {
					matched = false;
					break;
				}
			}
			if (matched) return i;
			i--;
		}
		return -1;
	}

	static function stringHex(n:Int, digits:EvalValue):String {
		var s = "";
		var hexChars = "0123456789ABCDEF";
		do {
			s = hexChars.charAt(n & 15) + s;
			n >>>= 4;
		} while (n > 0);
		if (digits != VNull) {
			var l = toInt(digits);
			while (s.length < l) s = "0" + s;
		}
		return s;
	}

	static function stringHtmlEscape(s:String, quotes:Bool):String {
		var buf = new StringBuf();
		for (i in 0...s.length) {
			switch (s.charCodeAt(i)) {
				case "&".code:
					buf.add("&amp;");
				case "<".code:
					buf.add("&lt;");
				case ">".code:
					buf.add("&gt;");
				case "\"".code if (quotes):
					buf.add("&quot;");
				case "'".code if (quotes):
					buf.add("&#039;");
				case code:
					buf.addChar(code);
			}
		}
		return buf.toString();
	}

	static function stringHtmlUnescape(s:String):String {
		return stringReplace(stringReplace(stringReplace(stringReplace(stringReplace(s, "&gt;", ">"), "&lt;", "<"), "&quot;", "\""), "&#039;", "'"), "&amp;", "&");
	}

	static function stringStartsWith(s:String, start:String):Bool {
		return s.length >= start.length && stringLastIndexOf(s, start, 0) == 0;
	}

	static function stringEndsWith(s:String, end:String):Bool {
		var elen = end.length;
		var slen = s.length;
		return slen >= elen && stringIndexOf(s, end, slen - elen) == slen - elen;
	}

	static function stringIsSpace(s:String, pos:Int):Bool {
		var c = s.charCodeAt(pos);
		return c != null && ((c > 8 && c < 14) || c == 32);
	}

	static function stringLTrim(s:String):String {
		var l = s.length;
		var r = 0;
		while (r < l && stringIsSpace(s, r)) r++;
		return r > 0 ? s.substr(r, l - r) : s;
	}

	static function stringRTrim(s:String):String {
		var l = s.length;
		var r = 0;
		while (r < l && stringIsSpace(s, l - r - 1)) r++;
		return r > 0 ? s.substr(0, l - r) : s;
	}

	static function stringLPad(s:String, c:String, l:Int):String {
		if (c.length <= 0) return s;
		var buf = new StringBuf();
		l -= s.length;
		while (buf.length < l) buf.add(c);
		buf.add(s);
		return buf.toString();
	}

	static function stringRPad(s:String, c:String, l:Int):String {
		if (c.length <= 0) return s;
		var buf = new StringBuf();
		buf.add(s);
		while (buf.length < l) buf.add(c);
		return buf.toString();
	}

	public static function isUtf8ByteString(s:String):Bool {
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i++);
			if (c > 0xFF) return false;
			if (c < 0x80) continue;
			var need = 0;
			var min = 0;
			if (c >= 0xC2 && c <= 0xDF) {
				need = 1;
				min = 0x80;
			} else if (c >= 0xE0 && c <= 0xEF) {
				need = 2;
				min = c == 0xE0 ? 0xA0 : 0x80;
			} else if (c >= 0xF0 && c <= 0xF4) {
				need = 3;
				min = c == 0xF0 ? 0x90 : 0x80;
			} else {
				return false;
			}
			for (j in 0...need) {
				if (i >= s.length) return false;
				var c2 = s.charCodeAt(i++);
				if (c2 < min || c2 > 0xBF) return false;
				min = 0x80;
			}
		}
		return true;
	}

	static function urlEncode(s:String):String {
		var hex = "0123456789ABCDEF";
		var b = new StringBuf();
		function addByte(c:Int):Void {
			if ((c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code)
				|| (c >= "0".code && c <= "9".code) || c == "_".code || c == "-".code || c == ".".code) {
				b.addChar(c);
			} else {
				b.addChar("%".code);
				b.addChar(hex.charCodeAt(c >> 4));
				b.addChar(hex.charCodeAt(c & 15));
			}
		}
		function addCodePoint(c:Int):Void {
			if (c < 0x80) addByte(c);
			else if (c < 0x800) {
				addByte(0xC0 | (c >> 6));
				addByte(0x80 | (c & 0x3F));
			} else if (c < 0x10000) {
				addByte(0xE0 | (c >> 12));
				addByte(0x80 | ((c >> 6) & 0x3F));
				addByte(0x80 | (c & 0x3F));
			} else {
				addByte(0xF0 | (c >> 18));
				addByte(0x80 | ((c >> 12) & 0x3F));
				addByte(0x80 | ((c >> 6) & 0x3F));
				addByte(0x80 | (c & 0x3F));
			}
		}
		if (isUtf8ByteString(s)) {
			for (i in 0...s.length) addByte(s.charCodeAt(i));
			return b.toString();
		}
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i++);
			if (c >= 0xD800 && c <= 0xDBFF && i < s.length) {
				var c2 = s.charCodeAt(i);
				if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
					i++;
					c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
				}
			}
			if (c < 0x80) addByte(c) else addCodePoint(c);
		}
		return b.toString();
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

	static function urlDecode(s:String):String {
		var out:Array<Int> = [];
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i);
			if (c == null) break;
			if (c == "%".code) {
				var h = decodeHex(s, i + 1);
				if (h == null) {
					i++;
				} else {
					out.push(h);
					i += 3;
				}
			} else if (c == "+".code) {
				out.push(" ".code);
				i++;
			} else if (c <= 0x7F) {
				out.push(c);
				i++;
			} else {
				var bs = haxe.io.Bytes.ofString(s.charAt(i));
				for (j in 0...bs.length) out.push(bs.get(j));
				i++;
			}
		}
		var bytes = haxe.io.Bytes.alloc(out.length);
		for (i in 0...out.length) bytes.set(i, out[i]);
		return bytes.toString();
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

	static function callToString(v:EvalValue, depth:Int):Null<String> {
		return try {
			var ctx = EvalContext.getCtx();
			var fn = EvalField.field(ctx, v, EvalHash.hash("toString"));
			fn == VNull ? null : stringOfDepth(callValueOn(v, fn, []), depth + 1);
		} catch (_:Dynamic) {
			null;
		}
	}

	static function protoString(proto:VPrototype):String {
		return switch (proto.pkind) {
			case PClass(_): "Class<" + EvalHash.revHash(proto.ppath) + ">";
			case PEnum(_): "Enum<" + EvalHash.revHash(proto.ppath) + ">";
			case PInstance | PObject: EvalHash.revHash(proto.ppath);
		};
	}

	static function objectString(o:VObject, depth:Int):String {
		var parts:Array<String> = [];
		var fields = objectFieldMap(o);
		var keys = switch (o.oproto) {
			case OProto(proto): instanceFieldKeys(proto);
			case ODictionary(_): objectDictionaryKeys(fields);
		};
		// Fields print at the depth objectString received (the +1 happened at the VObject dispatch); a
		// second increment here would truncate one level early.
		for (k in keys) if (fields.exists(k)) parts.push(EvalHash.revHash(k) + ": " + stringOfDepth(fields.get(k), depth));
		return "{" + parts.join(", ") + "}";
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

	static function stringOfDepth(v:EvalValue, depth:Int):String {
		if (depth > maxPrintDepth()) return "<...>";
		return switch (EvalValueTools.vresolve(v)) {
			case VNull: "null";
			case VTrue: "true";
			case VFalse: "false";
			case VInt(i): Std.string(i);
			case VFloat(f): floatString(f);
			case VString(s): normalizeString(s.sstring);
			case VNativeString(s): s;
			case VFunction(_, _): "#fun";
			case VFieldClosure(_, _): "#closure";
			case VEnumValue(ev):
				var name = enumConstructorName(ev);
				ev.eargs.length == 0 ? name : name + "(" + [for (a in ev.eargs) stringOfDepth(a, depth + 1)].join(",") + ")";
			case VArray(va): "[" + [for (i in 0...va.alength) stringOfDepth(va.avalues[i], depth + 1)].join(",") + "]";
			case VVector(vv): "[" + [for (x in vv) stringOfDepth(x, depth + 1)].join(",") + "]";
			case VObject(o):
				var s = callToString(VObject(o), depth);
				s == null ? objectString(o, depth + 1) : s;
			case VInstance(vi):
				switch (vi.ikind) {
					case IDate(ts): sDate(ts);
					case IPos(p): posString(p);
					// The regex's source.
					case IRegex(re):
						var info = nativeRegexInfo.get(re);
						info == null || info.source == null ? "~//" : info.source;
					case _:
						var s = callToString(VInstance(vi), depth);
						s == null ? EvalHash.revHash(vi.iproto.ppath) : s;
				}
			case VPrototype(proto):
				var s = callToString(VPrototype(proto), depth);
				s == null ? protoString(proto) : s;
			case VLazy(_): throw "unreachable";
		};
	}

	// A string or nothing. A null is a Null Access and any other value an Unexpected value, both
	// uncaught exceptions of the macro; stringOf answers "null".
	public static function decodeString(ctx:EvalContext, v:EvalValue):String {
		return switch (EvalValueTools.vresolve(v)) {
			case VString(s): s.sstring;
			case VNativeString(s): s;
			case VNull: EvalExceptions.excString(ctx, "Null Access");
			case r: EvalExceptions.excString(ctx, "Unexpected value " + valueKind(r) + "(" + stringOf(r) + "), expected string");
		}
	}

	public static function stringOf(v:EvalValue):String {
		return stringOfDepth(v, 0);
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
		nativeThreads = new haxe.ds.ObjectMap();
		nativeThreadSelfTls.value = null;
		nativeThreadNextId = 1;
		threadEventHandlers = new Map();
		threadEventHandlerNextId = 1;
		nativeRegexInfo = new haxe.ds.ObjectMap();
		macroMessages = [];
		var s = ctx.builtins.staticBuiltins;

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
		reg(s, "String", "fromCharCode", vfn(a -> mkStr(String.fromCharCode(ucharOfInt(decodeInt(ctx, arg(a, 0)))))));
		// StringTools has natives for fastCodeAt (String.charCodeAt), replace, urlEncode and urlDecode
		// only; the other StringTools functions, unsafeCodeAt included, are the std's Haxe code, run with
		// its own frames and verdicts.
		reg(s, "StringTools", "fastCodeAt", vfn(a -> stdStringCharCodeAt(ctx, a)));
		// By, sub and s are decoded (decodeVString), in that order.
		reg(s, "StringTools", "replace", vfn(a -> {
			var by = decodeVString(ctx, arg(a, 2));
			var sub = decodeVString(ctx, arg(a, 1));
			var str = decodeVString(ctx, arg(a, 0));
			mkStr(stringReplace(str, sub, by));
		}));
		reg(s, "StringTools", "urlEncode", vfn(a -> mkStr(urlEncode(decodeString(ctx, arg(a, 0))))));
		reg(s, "StringTools", "urlDecode", vfn(a -> mkStr(urlDecode(decodeString(ctx, arg(a, 0))))));
		// The bound is decoded by decodeI32.
		reg(s, "Std", "random", vfn(a -> VInt(Std.random(decodeI32(ctx, arg(a, 0))))));
		reg(s, "Std", "isOfType", vfn(a -> EvalValueTools.vbool(stdIsOfTypeCtx(ctx, arg(a, 0), arg(a, 1)))));
		reg(s, "Std", "is", vfn(a -> EvalValueTools.vbool(stdIsOfTypeCtx(ctx, arg(a, 0), arg(a, 1)))));
		reg(s, "Std", "downcast", vfn(a -> stdDowncast(ctx, arg(a, 0), arg(a, 1))));
		reg(s, "Std", "instance", vfn(a -> stdDowncast(ctx, arg(a, 0), arg(a, 1))));

		reg(s, "Std", "int", vfn(a -> stdInt(arg(a, 0))));
		reg(s, "Std", "string", vfn(a -> mkStr(stringOf(arg(a, 0)))));
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
		reg(s, "Sys", "println", vfn(a -> { writeStdoutString(stringOf(arg(a, 0)), true); VNull; }));
		reg(s, "Sys", "print", vfn(a -> { writeStdoutString(stringOf(arg(a, 0)), false); VNull; }));
		reg(s, "Sys", "args", vfn(a -> {
			var args = [for (s in Sys.args()) mkStr(s)];
			VArray(new VArray(args, args.length));
		}));
		reg(s, "Sys", "_command", vfn(a -> {
			var cmd = decodeString(ctx, arg(a, 0));
			flushStdout();
			VInt(Sys.command(cmd));
		}));
		reg(s, "Sys", "command", vfn(a -> {
			var cmd = stringOf(arg(a, 0));
			var args = processArgs(ctx, arg(a, 1));
			flushStdout();
			return VInt(args == null ? Sys.command(cmd) : Sys.command(cmd, args));
		}));
		reg(s, "Sys", "cpuTime", vfn(a -> VFloat(Sys.cpuTime())));
		reg(s, "Sys", "environment", vfn(a -> mkStringMap(ctx, Sys.environment())));
		// Sys.exit raises an exit exception; the compiler marks the compile failed for a non-zero code
		// and flushes the message list before returning it. Exiting the host process here would throw away
		// every warning a macro had queued, including the ones explaining why it was exiting.
		reg(s, "Sys", "exit", vfn(a -> throw new hxc.eval.EvalExceptions.EvalSysExit(decodeInt(ctx, arg(a, 0)))));
		reg(s, "Sys", "getCwd", vfn(a -> mkStr(Sys.getCwd())));
		reg(s, "Sys", "getEnv", vfn(a -> {
			var v = Sys.getEnv(decodeString(ctx, arg(a, 0)));
			v == null ? VNull : mkStr(v);
		}));
		reg(s, "Sys", "getChar", vfn(a -> VInt(Sys.getChar(decodeBool(ctx, arg(a, 0))))));
		reg(s, "Sys", "programPath", vfn(a -> sysProgramPath(ctx)));
		// A null value unsets the variable.
		reg(s, "Sys", "putEnv", vfn(a -> {
			var name = decodeString(ctx, arg(a, 0));
			Sys.putEnv(name, arg(a, 1) == VNull ? null : decodeString(ctx, arg(a, 1)));
			VNull;
		}));
		reg(s, "Sys", "setCwd", vfn(a -> { Sys.setCwd(decodeString(ctx, arg(a, 0))); VNull; }));
		reg(s, "Sys", "setTimeLocale", vfn(a -> VFalse));
		reg(s, "Sys", "sleep", vfn(a -> { var t = num(ctx, arg(a, 0)); gilBlocking(function() { Sys.sleep(t); return VNull; }); }));
		reg(s, "Sys", "stderr", vfn(a -> mkOutput(ctx, Sys.stderr(), null)));
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
					VFunction(function(args) return resolveMacroPath(ctx, decodeString(ctx, arg(args, 0))), true);
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
						var msgs = [for (d in com.diagnostics) if (!d.severity.match(Error)) macroMessage(ctx, d.severity.match(Warning) ? "Warning" : "Info", VString(new VString(d.message, d.message.length)), mkPos(ctx, d.pos))];
						return VArray(new VArray(msgs, msgs.length));
					}, true);
				case "filter_messages":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var pred = arg(args, 0);
						com.diagnostics = [for (d in com.diagnostics)
							if (d.severity.match(Error) || EvalMisc.isTrue(applyFn(pred, [macroMessage(ctx, d.severity.match(Warning) ? "Warning" : "Info", VString(new VString(d.message, d.message.length)), mkPos(ctx, d.pos))]))) d];
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
					// haxe.Serializer's format with the value cache and enum indices, and a function
					// serialized as a custom entity rather than refused.
					VFunction(function(args) return mkStr(haxe.crypto.Md5.encode(serializeEval(ctx, arg(args, 0), true, true, true))), true);
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
						var name = decodeString(ctx, arg(args, 0));
						if (com.forbiddenPackages.exists(name)) com.forbiddenPackages.remove(name);
						return VNull;
					}, true);
				case "add_class_path":
					VFunction(function(args) {
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						var cp = decodeString(ctx, arg(args, 0));
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
						var full = (cur == null ? [] : cur.copy()).concat([decodeString(ctx, arg(args, 0))]);
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
						var file = decodeString(ctx, arg(args, 0));
						var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
						return EvalExceptions.excString(ctx, "Target " + hxc.core.Globals.platformName(com.platform)
							+ " does not support native libraries (trying to load " + file + ")");
					}, true);
				case "add_native_arg":
					// Java, cs and cpp prepend the argument to cArgs.
					VFunction(function(args) {
						var narg = decodeString(ctx, arg(args, 0));
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
			EvalExceptions.excString(ctx, "error loading shared library: " + nativeStringOf(arg(a, 0)))));

		var inst = ctx.builtins.instanceBuiltins;

		reg(inst, "haxe.Exception", "get_stack", vmethod(a -> {
			// Cache-once, slicing the constructor-chain frames counted by __skipStack (the eval std
			// Exception.get_stack, whose interpreted body this builtin shadows).
			var cached = EvalField.field(ctx, arg(a, 0), EvalHash.keyExceptionStack);
			if (cached != VNull) cached else {
				var native = EvalField.field(ctx, arg(a, 0), EvalHash.keyNativeStack);
				var skip = switch (EvalField.field(ctx, arg(a, 0), EvalHash.hash("__skipStack"))) {
					case VInt(i): i;
					case _: 0;
				};
				var result = if (skip > 0) switch (native) {
					case VArray(va):
						var out = arrayLive(va).slice(skip);
						VArray(new VArray(out, out.length));
					case _: native;
				} else native;
				EvalField.setField(ctx, arg(a, 0), EvalHash.keyExceptionStack, result, Position.nullPos);
				result;
			}
		}));
		// String: the receiver and a string argument are `this`, an index is decodeInt and an optional
		// one defaultInt, each decoded in the native's order.
		reg(inst, "String", "charAt", vmethod(a -> {
			var str = thisString(ctx, a);
			mkStr(stringCharAt(str, decodeInt(ctx, arg(a, 1))));
		}));
		reg(inst, "String", "charCodeAt", vmethod(a -> stdStringCharCodeAt(ctx, a)));
		reg(inst, "String", "cca", vmethod(a -> stdStringCharCodeAt(ctx, a)));
		reg(inst, "String", "indexOf", vmethod(a -> {
			var sub = thisString(ctx, [arg(a, 1)]);
			var str = thisString(ctx, a);
			VInt(stringIndexOf(str, sub, defaultInt(ctx, arg(a, 2), 0)));
		}));
		reg(inst, "String", "lastIndexOf", vmethod(a -> {
			var sub = thisString(ctx, [arg(a, 1)]);
			var str = thisString(ctx, a);
			VInt(stringLastIndexOf(str, sub, arg(a, 2) == VNull ? null : decodeInt(ctx, arg(a, 2))));
		}));
		reg(inst, "String", "toUpperCase", vmethod(a -> mkStr(thisString(ctx, a).toUpperCase())));
		reg(inst, "String", "toLowerCase", vmethod(a -> mkStr(thisString(ctx, a).toLowerCase())));
		reg(inst, "String", "substr", vmethod(a -> stdStringSubstr(ctx, a)));
		reg(inst, "String", "substring", vmethod(a -> {
			var str = thisString(ctx, a);
			var start = decodeInt(ctx, arg(a, 1));
			mkStr(stringSubstring(str, start, arg(a, 2) == VNull ? null : decodeInt(ctx, arg(a, 2))));
		}));
		reg(inst, "String", "split", vmethod(a -> {
			var str = thisString(ctx, a);
			var parts = stringSplit(str, decodeVString(ctx, arg(a, 1)));
			VArray(new VArray([for (p in parts) mkStr(p)], parts.length));
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
			var sep = decodeVString(ctx, arg(a, 1));
			var va = thisArray(ctx, a);
			mkStr([for (i in 0...va.alength) stringOf(va.avalues[i])].join(sep));
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
			mkStr("[" + [for (i in 0...va.alength) stringOf(va.avalues[i])].join(",") + "]");
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
			var vv = thisVector(ctx, a);
			mkStr([for (v in vv) stringOf(v)].join(decodeVString(ctx, arg(a, 1))));
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
				var name = EvalHash.hash(decodeVString(ctx, arg(a, 1)));
				switch (EvalValueTools.vresolve(o)) {
					case VPrototype(proto) if (isReflectHidden(proto.ppath, name, true)): VNull;
					case VInstance(vi) if (isReflectHidden(vi.iproto.ppath, name, false)): VNull;
					case _: EvalField.dynamicField(ctx, o, name);
				}
			}
		}));
		reg(s, "Reflect", "setField", vfn(a -> {
			reflectSetField(ctx, arg(a, 0), EvalHash.hash(decodeVString(ctx, arg(a, 1))), arg(a, 2));
			VNull;
		}));
		reg(s, "Reflect", "hasField", vfn(a -> {
			var name = EvalHash.hash(decodeVString(ctx, arg(a, 1)));
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
			var name = EvalHash.hash(decodeVString(ctx, arg(a, 1)));
			EvalValueTools.vbool(deleteDynamicField(arg(a, 0), name));
		}));
		reg(s, "Reflect", "getProperty", vfn(a -> {
			var o = arg(a, 0);
			if (o == VNull) VNull else {
				var name = decodeVString(ctx, arg(a, 1));
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
			var name = decodeVString(ctx, arg(a, 1));
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
				proto.ppath == EvalHash.key_String && args.length == 1 ? mkStr(stringOf(args[0])) : EvalEmitter.constructPath(ctx, proto.ppath, args);
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
			var constr = EvalHash.hash(decodeVString(ctx, arg(a, 1)));
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
			var path = EvalHash.hash(decodeVString(ctx, arg(a, 0)));
			var p = ctx.staticPrototypes.get(path);
			p == null ? (isCoreClassPath(path) ? coreClassValue(ctx, path) : VNull) : p.pvalue;
		}));
		reg(s, "Type", "resolveEnum", vfn(a -> {
			var p = ctx.staticPrototypes.get(EvalHash.hash(decodeVString(ctx, arg(a, 0))));
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
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IBuffer(new StringBuf())));
		});
		ctors.set(EvalHash.hash("haxe.Utf8"), function(a) {
			// The size is defaultInt.
			defaultInt(ctx, arg(a, 0), 0);
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.Utf8"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IBuffer(new StringBuf())));
		});
		ctors.set(EvalHash.hash("EReg"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("EReg"));
			// The pattern and the options are decodeString, decoded right to left.
			var flags = decodeString(ctx, arg(a, 1));
			var pattern = decodeString(ctx, arg(a, 0));
			validateRegexFlags(flags);
			var re = new EReg(pattern, flags);
			nativeRegexInfo.set(re, {captureCount: countRegexCaptures(pattern), global: flags.indexOf("g") >= 0, lastSubject: null, matched: false, source: "~/" + pattern + "/" + flags});
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IRegex(re)));
		});
		emptyCtors.set(EvalHash.hash("EReg"), function() {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("EReg"));
			var re = new EReg("", "");
			nativeRegexInfo.set(re, {captureCount: 0, global: false, lastSubject: null, matched: false, source: "~//"});
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IRegex(re)));
		});

		reg(inst, "StringBuf", "add", vmethod(a -> {
			thisBuffer(a).add(stringOf(arg(a, 1)));
			VNull;
		}));
		// The char is decode_int, the string decode_vstring, the position decode_int and the length an
		// Int32 or null.
		reg(inst, "StringBuf", "addChar", vmethod(a -> {
			var buf = thisBuffer(a);
			buf.add(stringFromCodes([ucharOfInt(decodeInt(ctx, arg(a, 1)))], 0, 1));
			VNull;
		}));
		reg(inst, "StringBuf", "addSub", vmethod(a -> {
			var s = decodeVString(ctx, arg(a, 1));
			var pos = decodeInt(ctx, arg(a, 2));
			var len = switch (arg(a, 3)) {
				case VNull: stringLength(s) - pos;
				case VInt(i): i;
				case v: EvalExceptions.unexpectedValue(ctx, v, "int");
			};
			if (len > 0) thisBuffer(a).add(stringFromCodes(utf8Codes(s), pos, len));
			VNull;
		}));
		reg(inst, "StringBuf", "toString", vmethod(a -> mkStr(thisBuffer(a).toString())));
		// Length is a (get, never) property whose default getter reads the std's internal buffer; the
		// native instance keeps its own buffer, so the accessor resolves through the host length.
		reg(inst, "StringBuf", "get_length", vmethod(a -> VInt(thisBuffer(a).length)));

		// charCodeAt and sub are String's, a string argument is decode_string (length's decode_vstring) and
		// iter call_values its callback.
		reg(s, "haxe.Utf8", "charCodeAt", vfn(a -> stdStringCharCodeAt(ctx, a)));
		reg(s, "haxe.Utf8", "compare", vfn(a -> {
			var x = bytesOfStringValue(arg(a, 0));
			var y = bytesOfStringValue(arg(a, 1));
			VInt(bytesCompare(x, y));
		}));
		reg(s, "haxe.Utf8", "decode", vfn(a -> mkStr(utf8Decode(decodeString(ctx, arg(a, 0))))));
		reg(s, "haxe.Utf8", "encode", vfn(a -> {
			var s = decodeString(ctx, arg(a, 0));
			VString(new VString(utf8Encode(s), utf8EncodedLength(s)));
		}));
		reg(s, "haxe.Utf8", "iter", vfn(a -> {
			var str = decodeString(ctx, arg(a, 0));
			var fn = arg(a, 1);
			for (c in utf8Codes(str)) callValue(ctx, fn, [VInt(c)]);
			VNull;
		}));
		reg(s, "haxe.Utf8", "length", vfn(a -> switch (arg(a, 0)) {
			case VString(vs): VInt(runtimeStringLength(vs));
			case v: EvalExceptions.unexpectedValue(ctx, v, "string");
		}));
		reg(s, "haxe.Utf8", "sub", vfn(a -> stdStringSubstr(ctx, a)));
		reg(s, "haxe.Utf8", "validate", vfn(a -> EvalValueTools.vbool(utf8Valid(decodeString(ctx, arg(a, 0))))));
		reg(inst, "haxe.Utf8", "addChar", vmethod(a -> {
			var buf = thisBuffer(a);
			addUtf8Char(buf, ucharOfInt(decodeInt(ctx, arg(a, 1))));
			VNull;
		}));
		reg(inst, "haxe.Utf8", "toString", vmethod(a -> {
			var s = thisBuffer(a).toString();
			mkStrLen(s, haxe.io.Bytes.ofString(s).length);
		}));

		// Escape, map, match, matchSub, replace and split each decode_string their subject and
		// replacement; a null subject is a Null Access.
		reg(inst, "EReg", "match", vmethod(a -> {
			var s = decodeString(ctx, arg(a, 1));
			EvalValueTools.vbool(regexMatch(thisRegex(a), s));
		}));
		// And maybe_run: no match made, then a group that is not one of the pattern's (evalStdLib's
		// num_of_subs, the capture count plus one), then an unmatched group is null.
		reg(inst, "EReg", "matched", vmethod(a -> {
			var re = thisRegex(a);
			var n = decodeInt(ctx, arg(a, 1));
			var info = regexInfo(re);
			if (!info.matched) EvalExceptions.excString(ctx, "Invalid regex operation because no match was made");
			if (n < 0 || n > info.captureCount) EvalExceptions.excString(ctx, "Invalid group");
			try mkNullStr(re.matched(n)) catch (e:Dynamic) EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "EReg", "matchedLeft", vmethod(a -> try {
			var re = thisRegex(a);
			regexEnsureMatched(re);
			mkStr(re.matchedLeft());
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "EReg", "matchedRight", vmethod(a -> try {
			var re = thisRegex(a);
			regexEnsureMatched(re);
			mkStr(re.matchedRight());
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "EReg", "matchedPos", vmethod(a -> {
			var p = try regexMatchedPos(thisRegex(a)) catch (e:Dynamic) {
				return EvalExceptions.excString(ctx, Std.string(e));
			};
			var m = new Map();
			m.set(EvalHash.hash("pos"), VInt(p.pos));
			m.set(EvalHash.hash("len"), VInt(p.len));
			VObject(new VObject([], ODictionary(m)));
		}));
		// The receiver, the subject, the position and the length, decoded in that order; a negative
		// length is the default.
		reg(inst, "EReg", "matchSub", vmethod(a -> {
			var re = thisRegex(a);
			var s = decodeString(ctx, arg(a, 1));
			var pos = decodeInt(ctx, arg(a, 2));
			var len = defaultInt(ctx, arg(a, 3), -1);
			// The subject is cut at pos + len and the regex stub refuses a position outside it, both
			// Invalid_argument no macro catches.
			var byteLen = haxe.io.Bytes.ofString(s).length;
			var l = len < 0 ? byteLen - pos : len;
			if (pos + l <= byteLen) {
				if (pos + l < 0) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("String.sub / Bytes.sub")');
				if (pos < 0 || pos > pos + l) throw new hxc.eval.EvalExceptions.HostException('Invalid_argument("Pcre2.pcre2_match_stub: illegal position")');
			}
			EvalValueTools.vbool(regexMatchSub(re, s, pos, len));
		}));
		reg(inst, "EReg", "split", vmethod(a -> {
			var re = thisRegex(a);
			var s = decodeString(ctx, arg(a, 1));
			var info = regexInfo(re);
			if (info != null) info.lastSubject = s;
			var parts = regexSplit(re, s);
			VArray(new VArray([for (p in parts) mkStr(p)], parts.length));
		}));
		reg(inst, "EReg", "replace", vmethod(a -> {
			var re = thisRegex(a);
			var info = regexInfo(re);
			var by = decodeString(ctx, arg(a, 2));
			var s = decodeString(ctx, arg(a, 1));
			if (info != null) info.lastSubject = s;
			mkStr(regexReplace(re, s, by));
		}));
		reg(inst, "EReg", "map", vmethod(a -> {
			var recv = arg(a, 0);
			var fn = arg(a, 2);
			var re = thisRegex(a);
			var s = decodeString(ctx, arg(a, 1));
			var info = regexInfo(re);
			if (info != null) info.lastSubject = s;
			var out = re.map(s, function(_) {
				if (info != null) info.matched = true;
				return stringOf(callValueOn(recv, fn, [recv]));
			});
			// Map leaves no match behind.
			if (info != null) info.matched = false;
			mkStr(out);
		}));
		reg(s, "EReg", "escape", vfn(a -> mkStr(regexEscape(decodeString(ctx, arg(a, 0))))));


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
			reg(inst, mapPath, "toString", vmethod(a -> mkStr(mapToString(arg(a, 0)))));
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
			return try mkNativeProcess(ctx, new sys.io.Process(stringOf(arg(a, 0)), processArgs(ctx, arg(a, 1)))) catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		});
		ctors.set(EvalHash.hash("sys.thread.Mutex"), function(a) return mkThreadMutex(ctx));
		ctors.set(EvalHash.hash("sys.thread.Lock"), function(a) return mkThreadLock(ctx));
		ctors.set(EvalHash.hash("sys.thread.Tls"), function(a) return mkThreadTls(ctx));
		ctors.set(EvalHash.hash("sys.thread.Deque"), function(a) return mkThreadDeque(ctx));
		ctors.set(EvalHash.hash("sys.thread.Condition"), function(a) return mkThreadCondition(ctx));
		ctors.set(EvalHash.hash("sys.thread.Semaphore"), function(a) return mkThreadSemaphore(ctx, toInt(arg(a, 0))));
		ctors.set(EvalHash.hash("eval.vm.NativeThread"), function(a) {
			if (ctx.isMacro) return EvalExceptions.excString(ctx, "Creating threads in macros is not supported");
			return mkNativeThread(ctx, arg(a, 0));
		});
		reg(s, "Date", "now", vfn(a -> mkDate(ctx, Date.now().getTime())));
		// The time is num and the string decodeString.
		reg(s, "Date", "fromTime", vfn(a -> mkDate(ctx, num(ctx, arg(a, 0)))));
		reg(s, "Date", "fromString", vfn(a -> dateFromString(ctx, decodeString(ctx, arg(a, 0)))));

		// sys.FileSystem / sys.io.File: macros read the source tree at compile time; the interpreter
		// host has real filesystem access.
		// A path is decoded as a string.
		reg(s, "sys.FileSystem", "exists", vfn(a -> sys.FileSystem.exists(decodeString(ctx, arg(a, 0))) ? VTrue : VFalse));
		reg(s, "sys.FileSystem", "isDirectory", vfn(a -> sys.FileSystem.isDirectory(decodeString(ctx, arg(a, 0))) ? VTrue : VFalse));
		reg(s, "sys.FileSystem", "readDirectory", vfn(a -> {
			var d = sys.FileSystem.readDirectory(decodeString(ctx, arg(a, 0)));
			VArray(new VArray([for (f in d) mkStr(f)], d.length));
		}));
		reg(s, "sys.FileSystem", "createDirectory", vfn(a -> { sys.FileSystem.createDirectory(decodeString(ctx, arg(a, 0))); VNull; }));
		reg(s, "sys.FileSystem", "deleteDirectory", vfn(a -> { sys.FileSystem.deleteDirectory(decodeString(ctx, arg(a, 0))); VNull; }));
		reg(s, "sys.FileSystem", "deleteFile", vfn(a -> { sys.FileSystem.deleteFile(decodeString(ctx, arg(a, 0))); VNull; }));
		// fullPath: the decode sits inside the native's catch-all handler, so a null argument's Null
		// Access prints as the runtime exception value, and a refused empty path prints as the
		// get_full_path failure.
		reg(s, "sys.FileSystem", "fullPath", vfn(a -> {
			var f = try decodeString(ctx, arg(a, 0)) catch (_:EvalExceptions.EvalRunTimeException) EvalExceptions.excString(ctx, "EvalContext.RunTimeException(_, _, _)");
			f == "" ? EvalExceptions.excString(ctx, "Failure(\"get_full_path\")") : mkStr(sys.FileSystem.fullPath(f));
		}));
		reg(s, "sys.FileSystem", "absolutePath", vfn(a -> mkStr(sys.FileSystem.absolutePath(stringOf(arg(a, 0))))));
		// Rename: both paths are decoded, the new one first.
		reg(s, "sys.FileSystem", "rename", vfn(a -> {
			var newPath = decodeString(ctx, arg(a, 1));
			sys.FileSystem.rename(decodeString(ctx, arg(a, 0)), newPath);
			VNull;
		}));
		// Stat: a failure on the patched path is a Unix error; the host's stat answers zeros for a path
		// that is not there.
		reg(s, "sys.FileSystem", "stat", vfn(a -> {
			var path = decodeString(ctx, arg(a, 0));
			if (!sys.FileSystem.exists(path)) EvalExceptions.excString(ctx, "No such file or directory(stat, " + fsPatchPath(path) + ")");
			mkFileStat(ctx, sys.FileSystem.stat(path));
		}));
		reg(s, "sys.net.Host", "localhost", vfn(a -> mkStr(sys.net.Host.localhost())));
		reg(s, "sys.net.Host", "resolve", vfn(a -> VInt(hostIpInt(stringOf(arg(a, 0))))));
		reg(s, "sys.net.Host", "hostToString", vfn(a -> mkStr(new sys.net.Host(hostIpString(toInt(arg(a, 0)))).toString())));
		reg(s, "sys.net.Host", "hostReverse", vfn(a -> mkStr(new sys.net.Host(hostIpString(toInt(arg(a, 0)))).reverse())));
		// A path is decode_string, a binary flag true or null for binary.
		reg(s, "sys.io.File", "append", vfn(a -> mkFileOutput(ctx, sys.io.File.append(decodeString(ctx, arg(a, 0)), fileBinaryFlag(arg(a, 1))))));
		// An unreadable file raises "Could not read file <path>".
		reg(s, "sys.io.File", "getBytes", vfn(a -> {
			var path = decodeString(ctx, arg(a, 0));
			try mkBytes(ctx, sys.io.File.getBytes(path)) catch (_:Dynamic) EvalExceptions.excString(ctx, "Could not read file " + path);
		}));
		reg(s, "sys.io.File", "getContent", vfn(a -> {
			var path = decodeString(ctx, arg(a, 0));
			try mkStr(sys.io.File.getContent(path)) catch (_:Dynamic) EvalExceptions.excString(ctx, "Could not read file " + path);
		}));
		reg(s, "sys.io.File", "read", vfn(a -> {
			var path = decodeString(ctx, arg(a, 0));
			mkFileInput(ctx, sys.io.File.read(path, fileBinaryFlag(arg(a, 1))));
		}));
		reg(s, "sys.io.File", "saveBytes", vfn(a -> {
			var path = decodeString(ctx, arg(a, 0));
			sys.io.File.saveBytes(path, decodeBytes(arg(a, 1)));
			VNull;
		}));
		reg(s, "sys.io.File", "saveContent", vfn(a -> {
			var path = decodeString(ctx, arg(a, 0));
			sys.io.File.saveContent(path, decodeString(ctx, arg(a, 1)));
			VNull;
		}));
		reg(s, "sys.io.File", "update", vfn(a -> mkFileOutput(ctx, sys.io.File.update(decodeString(ctx, arg(a, 0)), fileBinaryFlag(arg(a, 1))))));
		reg(s, "sys.io.File", "write", vfn(a -> mkFileOutput(ctx, sys.io.File.write(decodeString(ctx, arg(a, 0)), fileBinaryFlag(arg(a, 1))))));
		reg(inst, "sys.io.FileInput", "close", vmethod(a -> {
			var vi = thisInstance(a, "FileInput");
			fileInputs.get(vi).input.close();
			fileInputs.remove(vi);
			VNull;
		}));
		reg(inst, "sys.io.FileInput", "eof", vmethod(a -> EvalValueTools.vbool(thisFileInput(a).eof)));
		reg(inst, "sys.io.FileInput", "seek", vmethod(a -> {
			var ch = thisFileInput(a);
			ch.eof = false;
			ch.file.seek(toInt(arg(a, 1)), fileSeekMode(arg(a, 2)));
			VNull;
		}));
		reg(inst, "sys.io.FileInput", "tell", vmethod(a -> VInt(thisFileInput(a).file.tell())));
		reg(inst, "sys.io.FileInput", "readByte", vmethod(a -> {
			var ch = thisFileInput(a);
			try VInt(ch.input.readByte()) catch (_:Dynamic) {
				ch.eof = true;
				eof(ctx);
			}
		}));
		reg(inst, "sys.io.FileInput", "readBytes", vmethod(a -> {
			var ch = thisFileInput(a);
			var n = try ch.input.readBytes(decodeBytes(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3))) catch (_:Dynamic) {
				ch.eof = true;
				eof(ctx);
			}
			if (n == 0) {
				ch.eof = true;
				eof(ctx);
			}
			VInt(n);
		}));
		reg(inst, "sys.io.FileOutput", "close", vmethod(a -> {
			var vi = thisInstance(a, "FileOutput");
			fileOutputs.get(vi).output.close();
			fileOutputs.remove(vi);
			VNull;
		}));
		reg(inst, "sys.io.FileOutput", "flush", vmethod(a -> { thisFileOutput(a).output.flush(); VNull; }));
		reg(inst, "sys.io.FileOutput", "seek", vmethod(a -> {
			var out = thisFileOutput(a);
			out.file.seek(toInt(arg(a, 1)), fileSeekMode(arg(a, 2)));
			VNull;
		}));
		reg(inst, "sys.io.FileOutput", "tell", vmethod(a -> VInt(thisFileOutput(a).file.tell())));
		reg(inst, "sys.io.FileOutput", "writeByte", vmethod(a -> { thisFileOutput(a).output.writeByte(toInt(arg(a, 1))); VNull; }));
		reg(inst, "sys.io.FileOutput", "writeString", vmethod(a -> { thisFileOutput(a).output.writeString(stringOf(arg(a, 1))); VNull; }));
		reg(inst, "sys.io.FileOutput", "writeBytes", vmethod(a -> VInt(thisFileOutput(a).output.writeBytes(
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
		reg(s, "eval.vm.NativeThread", "self", vfn(a -> nativeThreadSelfValue(ctx)));
		reg(s, "eval.vm.NativeThread", "delay", vfn(a -> { Sys.sleep(toFloat(arg(a, 0))); VNull; }));
		reg(s, "eval.vm.NativeThread", "exit", vfn(a -> EvalExceptions.excString(ctx, "sys.thread.Thread.exit is not supported by eval")));
		reg(s, "eval.vm.NativeThread", "join", vfn(a -> VNull));
		reg(s, "eval.vm.NativeThread", "yield", vfn(a -> { Sys.sleep(0); VNull; }));
		reg(s, "eval.vm.NativeThread", "readMessage", vfn(a -> {
			switch (nativeThreadSelfValue(ctx)) {
				case VInstance(vi):
					var deque = nativeThreads.get(vi).messages;
					var blocking = arg(a, 0) == VTrue;
					var v = blocking
						? gilBlocking(function() return deque.pop(true))
						: deque.pop(false);
					v == null ? VNull : v;
				case _: VNull;
			}
		}));
		reg(inst, "eval.vm.NativeThread", "id", vmethod(a -> VInt(nativeThreadData(a).id)));
		reg(inst, "eval.vm.NativeThread", "kill", vmethod(a -> throw "Field index for kill not found on prototype eval.vm.NativeThread"));
		reg(inst, "eval.vm.NativeThread", "sendMessage", vmethod(a -> { nativeThreadData(a).messages.add(arg(a, 1)); VNull; }));
		// get_events/set_events: events is a plain value slot on the thread record, null until the typed
		// std installs an EventLoop.
		reg(inst, "eval.vm.NativeThread", "get_events", vmethod(a -> nativeThreadData(a).events));
		reg(inst, "eval.vm.NativeThread", "set_events", vmethod(a -> {
			nativeThreadData(a).events = arg(a, 1);
			arg(a, 1);
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "fromBytes", vfn(a -> {
			var b = decodeBytes(arg(a, 0));
			VNativeString(bytesRawString(b, 0, b.length));
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "fromString", vfn(a -> arg(a, 0) == VNull ? VNull : VNativeString(nativeStringOf(arg(a, 0)))));
		reg(s, "eval._NativeString.NativeString_Impl_", "toBytes", vfn(a -> mkBytes(ctx, rawStringBytes(nativeStringOf(arg(a, 0))))));
		reg(s, "eval._NativeString.NativeString_Impl_", "toString", vfn(a -> {
			var raw = nativeStringOf(arg(a, 0));
			mkStr(bytesString(rawStringBytes(raw), 0, raw.length));
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "concat", vfn(a -> VNativeString(nativeStringOf(arg(a, 0)) + nativeStringOf(arg(a, 1)))));
		reg(s, "eval._NativeString.NativeString_Impl_", "char", vfn(a -> {
			var raw = nativeStringOf(arg(a, 0));
			var pos = toInt(arg(a, 1));
			mkStr(bytesString(rawStringBytes(raw), pos, 1));
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "code", vfn(a -> VInt(nativeStringOf(arg(a, 0)).charCodeAt(toInt(arg(a, 1))))));
		reg(s, "eval._NativeString.NativeString_Impl_", "get_length", vfn(a -> VInt(nativeStringOf(arg(a, 0)).length)));
		reg(s, "eval._NativeString.NativeString_Impl_", "sub", vfn(a -> {
			var str = nativeStringOf(arg(a, 0));
			var start = toInt(arg(a, 1));
			var max = str.length - start;
			var len = arg(a, 2) == VNull ? max : Std.int(Math.min(toInt(arg(a, 2)), max));
			if (start < 0 || len < 0) throw "Invalid arguments for eval.NativeString.sub";
			VNativeString(str.substr(start, len));
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
		reg(s, "haxe.io.Bytes", "ofString", vfn(a -> mkBytes(ctx, bytesOfStringValue(arg(a, 0)))));
		// The digits are the string's bytes, an odd count is an error and nothing else is checked.
		reg(s, "haxe.io.Bytes", "ofHex", vfn(a -> {
			var src = bytesOfStringValue(arg(a, 0));
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
		reg(s, "haxe.crypto.Md5", "encode", vfn(a -> mkStr(haxe.crypto.Md5.encode(decodeString(ctx, arg(a, 0))))));
		reg(s, "haxe.crypto.Md5", "make", vfn(a -> mkBytes(ctx, haxe.crypto.Md5.make(decodeBytes(arg(a, 0))))));
		reg(s, "haxe.crypto.Sha1", "encode", vfn(a -> mkStr(haxe.crypto.Sha1.encode(decodeString(ctx, arg(a, 0))))));
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
			var bytes = ctx.resources.get(decodeString(ctx, arg(a, 0)));
			bytes == null ? VNull : mkStr(bytes.toString());
		}));
		reg(s, "haxe.Resource", "getBytes", vfn(a -> {
			var bytes = ctx.resources.get(decodeString(ctx, arg(a, 0)));
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
			try mkStr(bytesString(b, pos, len)) catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "haxe.io.Bytes", "getUInt16", vmethod(a -> orOutsideBounds(ctx, () -> {
			var pos = decodeInt(ctx, arg(a, 1));
			var b = thisBytes(a);
			pos < 0 || pos > b.length - 2 ? null : VInt(b.getUInt16(pos));
		})));
		reg(inst, "haxe.io.Bytes", "toString", vmethod(a -> {
			var b = thisBytes(a);
			try mkStr(bytesStringStrict(b, 0, b.length)) catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
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
			switch (arg(a, 1)) {
				case VString(_):
				case v: EvalExceptions.unexpectedValue(ctx, v, "string");
			}
			var b = bytesOfStringValue(arg(a, 1));
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
			var selected = sys.net.Socket.select(
				[for (v in read) socketValue(v)],
				[for (v in write) socketValue(v)],
				[for (v in others) socketValue(v)],
				timeout
			);
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
		reg(inst, "eval.vm.NativeSocket", "accept", vmethod(a -> mkNativeSocket(ctx, thisSocket(a).accept())));
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
			thisSocket(a).connect(new sys.net.Host(hostIpString(toInt(arg(a, 1)))), toInt(arg(a, 2)));
			VNull;
		}));
		reg(inst, "eval.vm.NativeSocket", "host", vmethod(a -> hostInfo(thisSocket(a).host())));
		reg(inst, "eval.vm.NativeSocket", "listen", vmethod(a -> { thisSocket(a).listen(toInt(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "peer", vmethod(a -> hostInfo(thisSocket(a).peer())));
		reg(inst, "eval.vm.NativeSocket", "receive", vmethod(a -> try VInt(thisSocket(a).input.readBytes(
			decodeBytes(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3)))) catch (_:haxe.io.Eof) VInt(0)));
		reg(inst, "eval.vm.NativeSocket", "receiveChar", vmethod(a -> VInt(thisSocket(a).input.readByte())));
		reg(inst, "eval.vm.NativeSocket", "send", vmethod(a -> VInt(thisSocket(a).output.writeBytes(
			decodeBytes(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3))))));
		reg(inst, "eval.vm.NativeSocket", "sendChar", vmethod(a -> { thisSocket(a).output.writeByte(toInt(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setFastSend", vmethod(a -> { thisSocket(a).setFastSend(arg(a, 1) == VTrue); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setBroadcast", vmethod(a -> { setSocketBroadcast(thisSocket(a), arg(a, 1) == VTrue); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setTimeout", vmethod(a -> { thisSocket(a).setTimeout(toFloat(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "shutdown", vmethod(a -> { thisSocket(a).shutdown(arg(a, 1) == VTrue, arg(a, 2) == VTrue); VNull; }));
	}

	// /:1604/:1663 toString: the table folded, so in its keys' order, each entry "key => value" (an IntMap
	// key string_of_int, a StringMap key the string, an ObjectMap key its s_value) and the entries joined
	// by "," .
	static function mapToString(v:EvalValue):String {
		return "[" + [for (e in orderedMapEntries(v)) stringOf(e.key) + " => " + stringOf(e.value)].join(",") + "]";
	}
}
