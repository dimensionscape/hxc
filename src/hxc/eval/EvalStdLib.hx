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

typedef EvalLoopTimer = {
	var fn:Void->Void;
	var interval:Float;
	var next:Float;
	var cancelled:Bool;
}

typedef EvalLoopState = {
	var pending:Array<Void->Void>;
	var timers:Array<EvalLoopTimer>;
	var promised:Int;
	var started:Bool;
	var isMainThread:Bool;
	var mainLoopNext:Null<Float>;
}

typedef ThreadConditionState = {
	var cond:sys.thread.Condition;
	var owner:Null<sys.thread.Thread>;
	var count:Int;
}

// Native builtins for extern standard-library types. Each entry maps a type and field name to a
// value (a function or a constant) that the prototype builder installs on the type's prototype.
#if cpp
@:cppFileCode("#include <stdio.h>")
#end
class EvalStdLib {
	static function reg(map:Map<Int, Array<BuiltinField>>, typeName:String, fieldName:String, v:EvalValue):Void {
		var key = EvalHash.hash(typeName);
		var list = map.get(key);
		if (list == null) {
			list = [];
			map.set(key, list);
		}
		list.push({name: EvalHash.hash(fieldName), v: v});
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

	static function thisString(a:Array<EvalValue>):String {
		return switch (a[0]) {
			case VString(s): normalizeString(s.sstring);
			case _: "";
		};
	}

	static function thisArray(a:Array<EvalValue>):VArray {
		return switch (a[0]) {
			case VArray(va): va;
			case _: new VArray([], 0);
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

	static function thisVector(a:Array<EvalValue>):Array<EvalValue> {
		return switch (a[0]) {
			case VVector(vv): vv;
			case _: [];
		};
	}

	static function sortedFieldKeys(names:Map<Int, Int>):Array<Int> {
		var keys = [for (k in names.keys()) k];
		keys.sort(function(a, b) return names.get(a) - names.get(b));
		return keys;
	}

	static function instanceFieldKeys(proto:VPrototype):Array<Int> {
		return sortedFieldKeys(proto.pinstanceNames);
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

	static function seededStringHash(s:String):Int {
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

	static inline function ptmapOrderKey(k:Int):Int {
		var r = 0;
		for (i in 0...30) r = (r << 1) | ((k >>> i) & 1);
		return r;
	}

	static function objectDictionaryKeys(fields:Map<Int, EvalValue>):Array<Int> {
		var keys = [for (k in fields.keys()) k];
		keys.sort(function(a, b) {
			var d = ptmapOrderKey(seededStringHash(EvalHash.revHash(a))) - ptmapOrderKey(seededStringHash(EvalHash.revHash(b)));
			return d != 0 ? d : Reflect.compare(EvalHash.revHash(a), EvalHash.revHash(b));
		});
		return keys;
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
			case _: VNull;
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

	static function createEnumByName(ctx:EvalContext, e:EvalValue, name:Int, params:EvalValue):EvalValue {
		return switch (EvalValueTools.vresolve(e)) {
			case VPrototype(proto):
				switch (proto.pkind) {
					case PEnum(_):
						var f = EvalField.field(ctx, VPrototype(proto), name);
						switch [f, params] {
							case [VEnumValue(_), VNull]: f;
							case [VEnumValue(_), VArray(va)] if (va.alength == 0): f;
							case [VFunction(fn, _), VArray(va)]: fn(va.avalues.slice(0, va.alength));
							case _: unexpectedEnumParams(ctx, params);
						}
					case _: unexpectedEnumParams(ctx, params);
				}
			case _: EvalExceptions.unexpectedValue(ctx, e, "enum");
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
			case VInstance(vi): switch (vi.ikind) { case IBuffer(b): b; case _: new StringBuf(); };
			case _: new StringBuf();
		};
	}

	static function thisRegex(a:Array<EvalValue>):EReg {
		return switch (a[0]) {
			case VInstance(vi): switch (vi.ikind) { case IRegex(r): r; case _: new EReg("", ""); };
			case _: new EReg("", "");
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
					throw "Unsupported regexp option '" + flags.charAt(i) + "'";
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

	static function bytesOfDouble(v:Float):haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(8);
		b.setDouble(0, v);
		return b;
	}

	static function floatBits(v:Float):Int {
		return bytesOfFloat(v).getInt32(0);
	}

	static function doubleBits(v:Float):EvalValue {
		var b = bytesOfDouble(v);
		return mkObject([
			{name: "low", value: VInt(b.getInt32(0))},
			{name: "high", value: VInt(b.getInt32(4))}
		]);
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
	static var nativeBytesInputs = new haxe.ds.ObjectMap<VInstance, {bytes:haxe.io.Bytes, pos:Int, len:Int, totlen:Int}>();
	static var nativeProcesses = new haxe.ds.ObjectMap<VInstance, sys.io.Process>();
	static var nativeLists = new haxe.ds.ObjectMap<VInstance, Array<EvalValue>>();
	static var nativeArrayIterators = new haxe.ds.ObjectMap<VInstance, {array:VArray, current:Int}>();
	static var nativeMapKeyValueIterators = new haxe.ds.ObjectMap<VInstance, {entries:Array<MapEntry>, current:Int}>();
	static var nativeMapOrders = new haxe.ds.ObjectMap<VInstance, Array<String>>();
	static var threadMutexes = new haxe.ds.ObjectMap<VInstance, {mutex:sys.thread.Mutex, owner:Null<sys.thread.Thread>, count:Int}>();
	static var threadLocks = new haxe.ds.ObjectMap<VInstance, sys.thread.Lock>();
	static var threadTls = new haxe.ds.ObjectMap<VInstance, sys.thread.Tls<EvalValue>>();
	static var threadDeques = new haxe.ds.ObjectMap<VInstance, sys.thread.Deque<EvalValue>>();
	static var threadConditions = new haxe.ds.ObjectMap<VInstance, ThreadConditionState>();
	static var threadSemaphores = new haxe.ds.ObjectMap<VInstance, sys.thread.Semaphore>();
	static var threadEventLoops = new haxe.ds.ObjectMap<VInstance, EvalLoopState>();
	static var eventLoopObjects = new haxe.ds.ObjectMap<VObject, EvalLoopState>();
	static var threadEventHandlers = new Map<Int, Dynamic>();
	static var threadEventHandlerNextId = 1;
	static var nativeThreads = new haxe.ds.ObjectMap<VInstance, {id:Int, messages:sys.thread.Deque<EvalValue>, events:EvalValue}>();
	static var nativeTimers = new haxe.ds.ObjectMap<VInstance, {loop:EvalLoopState, handler:Dynamic}>();
	static var nativeThreadSelf:Null<VInstance> = null;
	static var nativeThreadNextId = 1;
	static var evalLoopCreated = false;
	static var entryPointThreadCount = 0;
	static var evalContext:Null<EvalContext> = null;
	static var nativeXml = new haxe.ds.ObjectMap<VInstance, Xml>();
	static var nativeXmlValues = new haxe.ds.ObjectMap<Xml, VInstance>();
	static var nativeRegexInfo = new haxe.ds.ObjectMap<EReg, {captureCount:Int, global:Bool, lastSubject:Null<String>, matched:Bool}>();
	static var objectFieldOrders = new haxe.ds.ObjectMap<VObject, Array<Int>>();
	static var stringHashCache = new Map<String, Int>();
	static var macroMessages:Array<EvalValue> = [];

	static function regexInfo(re:EReg):{captureCount:Int, global:Bool, lastSubject:Null<String>, matched:Bool} {
		var info = nativeRegexInfo.get(re);
		if (info == null) {
			info = {captureCount: 9, global: false, lastSubject: null, matched: false};
			nativeRegexInfo.set(re, info);
		}
		return info;
	}

	public static function processEvents():Void {
		var ctx = evalContext;
		var timers = [for (vi in nativeTimers.keys()) nativeTimers.get(vi)];
		for (timer in timers) if (timer != null) evalLoopDrain(ctx, timer.loop, null);
		var self = nativeThreadSelf;
		if (ctx == null || self == null) return;
		var thread = nativeThreads.get(self);
		if (thread == null || thread.events == VNull) return;
		applyFn(EvalField.dynamicField(ctx, thread.events, EvalHash.hash("loop")), []);
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

	static function serializeEval(ctx:EvalContext, value:EvalValue, useEnumIndex:Bool, useCache:Bool):String {
		var buf = new StringBuf();
		var cache:Array<EvalValue> = [];
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
							switch (EvalHash.revHash(vi.iproto.ppath)) {
								case "haxe.ds.StringMap":
									buf.add("b");
									for (entry in m) {
										stringTag(stringOf(entry.key));
										loop(entry.value);
									}
									buf.add("h");
								case "haxe.ds.IntMap":
									buf.add("q");
									for (entry in m) {
										buf.add(":");
										buf.add(toInt(entry.key));
										loop(entry.value);
									}
									buf.add("h");
								case "haxe.ds.ObjectMap":
									buf.add("M");
									for (entry in m) {
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
					EvalExceptions.excString(ctx, "Cannot serialize function");
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
				case "k".code: VFloat(Math.NaN);
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
			case 19 if (digits(0, 4) && s.charAt(4) == "-" && digits(5, 2) && s.charAt(7) == "-" && digits(8, 2) && s.charAt(10) == " " && digits(11, 2) && s.charAt(13) == ":" && digits(14, 2) && s.charAt(16) == ":" && digits(17, 2)):
				mkDate(ctx, new Date(part(0, 4), part(5, 2) - 1, part(8, 2), part(11, 2), part(14, 2), part(17, 2)).getTime());
			case 10 if (digits(0, 4) && s.charAt(4) == "-" && digits(5, 2) && s.charAt(7) == "-" && digits(8, 2)):
				mkDate(ctx, new Date(part(0, 4), part(5, 2) - 1, part(8, 2), 0, 0, 0).getTime());
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

	static function thisBytes(a:Array<EvalValue>):haxe.io.Bytes {
		return switch (a[0]) {
			case VInstance(vi): switch (vi.ikind) { case IBytes(b): b; case _: haxe.io.Bytes.alloc(0); };
			case _: haxe.io.Bytes.alloc(0);
		};
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
		cryptoBaseCodes.set(vi, new haxe.crypto.BaseCode(thisBytes([base])));
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

	static function thisList(a:Array<EvalValue>):Array<EvalValue> {
		var vi = thisInstance(a, "List");
		var list = nativeLists.get(vi);
		if (list == null) throw "Unexpected value for List";
		return list;
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

	static function listValue(ctx:EvalContext, items:Array<EvalValue>):EvalValue {
		return mkList(ctx, items);
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

	static function mkThreadEventLoop(ctx:EvalContext):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("sys.thread.EventLoop"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		threadEventLoops.set(vi, newEvalLoop());
		return VInstance(vi);
	}

	static function thisThreadEventLoop(a:Array<EvalValue>):EvalLoopState {
		return threadEventLoops.get(thisInstance(a, "EventLoop"));
	}

	static function newEvalLoop():EvalLoopState {
		var isMain = !evalLoopCreated;
		evalLoopCreated = true;
		return {pending: [], timers: [], promised: 0, started: false, isMainThread: isMain, mainLoopNext: null};
	}

	static function eventHandlerValue(handler:Dynamic):EvalValue {
		var id = threadEventHandlerNextId++;
		threadEventHandlers.set(id, handler);
		return VInt(id);
	}

	static function eventHandlerOf(v:EvalValue):Dynamic {
		return threadEventHandlers.get(toInt(v));
	}

	static function nextEventTimeValue(ctx:EvalContext, name:String, ?time:Null<Float>):EvalValue {
		var e = classValue(ctx, EvalHash.hash("sys.thread.NextEventTime"));
		if (e == VNull) return VNull;
		if (name == "AnyTime") {
			var p = time == null ? VNull : VFloat(time);
			return createEnumByName(ctx, e, EvalHash.hash(name), VArray(new VArray([p], 1)));
		}
		if (name == "At") {
			return createEnumByName(ctx, e, EvalHash.hash(name), VArray(new VArray([VFloat(time == null ? 0.0 : time)], 1)));
		}
		return createEnumByName(ctx, e, EvalHash.hash(name), VNull);
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

	static function mainLoopHasEvents(ctx:Null<EvalContext>, loop:EvalLoopState):Bool {
		if (ctx == null || !loop.started || !loop.isMainThread) return false;
		return callStaticValue(ctx, "haxe.MainLoop", "hasEvents", []) == VTrue;
	}

	static function evalLoopRunMainLoop(ctx:Null<EvalContext>, loop:EvalLoopState):Bool {
		if (ctx == null || !loop.started || !loop.isMainThread) return false;
		if (!mainLoopHasEvents(ctx, loop)) {
			loop.mainLoopNext = null;
			return false;
		}
		var next = switch (callStaticValue(ctx, "haxe.MainLoop", "tick", [])) {
			case VInt(i): i + 0.0;
			case VFloat(f): f;
			case _: -1.0;
		}
		if (mainLoopHasEvents(ctx, loop))
			loop.mainLoopNext = next < 0 ? null : Sys.time() + next;
		else
			loop.mainLoopNext = null;
		return next <= 0;
	}

	static function evalLoopExpected(ctx:Null<EvalContext>, loop:EvalLoopState):Bool {
		if (loop.pending.length > 0 || loop.promised > 0) return true;
		for (timer in loop.timers) if (!timer.cancelled) return true;
		if (mainLoopHasEvents(ctx, loop)) return true;
		return false;
	}

	static function evalLoopNextDue(ctx:Null<EvalContext>, loop:EvalLoopState):Null<Float> {
		var at:Null<Float> = null;
		for (timer in loop.timers) {
			if (!timer.cancelled && (at == null || timer.next < at)) at = timer.next;
		}
		if (mainLoopHasEvents(ctx, loop)) {
			var next = loop.mainLoopNext == null ? Sys.time() : loop.mainLoopNext;
			if (at == null || next < at) at = next;
		}
		return at;
	}

	static function evalLoopRunPending(loop:EvalLoopState):Bool {
		var ran = false;
		while (loop.pending.length > 0) {
			var pending = loop.pending;
			loop.pending = [];
			for (fn in pending) {
				ran = true;
				fn();
			}
		}
		return ran;
	}

	static function evalLoopRunDue(loop:EvalLoopState):Bool {
		var ran = false;
		var now = Sys.time();
		for (timer in loop.timers.copy()) {
			if (timer.cancelled || timer.next > now) continue;
			ran = true;
			while (timer.next <= now) timer.next += timer.interval;
			timer.fn();
		}
		return ran;
	}

	static function evalLoopStep(ctx:Null<EvalContext>, loop:EvalLoopState):Bool {
		var ran = evalLoopRunPending(loop);
		if (evalLoopRunDue(loop)) ran = true;
		if (evalLoopRunPending(loop)) ran = true;
		if (evalLoopRunMainLoop(ctx, loop)) ran = true;
		if (evalLoopRunPending(loop)) ran = true;
		return ran;
	}

	static function evalLoopWaitStep(ctx:Null<EvalContext>, loop:EvalLoopState):Bool {
		evalLoopRunPending(loop);
		var ran = evalLoopRunDue(loop);
		if (evalLoopRunPending(loop)) ran = true;
		if (evalLoopRunMainLoop(ctx, loop)) ran = true;
		if (evalLoopRunPending(loop)) ran = true;
		return ran;
	}

	static function evalLoopWait(loop:EvalLoopState, ?timeout:Null<Float>):Bool {
		if (loop.started) throw "Event loop already started";
		if (timeout == null) {
			if (loop.pending.length > 0 && evalLoopNextDue(null, loop) == null) return false;
			if (evalLoopWaitStep(null, loop)) return true;
			if (!evalLoopExpected(null, loop)) return false;
		} else if (evalLoopStep(null, loop)) return true;
		if (!evalLoopExpected(null, loop)) return timeout != null;
		var until = timeout == null ? null : Sys.time() + timeout;
		while (evalLoopExpected(null, loop)) {
			var next = evalLoopNextDue(null, loop);
			if (next == null) {
				if (timeout == null) return false;
				var left = until - Sys.time();
				if (left <= 0) return false;
				Sys.sleep(left > 0.01 ? 0.01 : left);
			} else {
				var sleep = next - Sys.time();
				if (until != null && until < next) sleep = until - Sys.time();
				if (sleep > 0) Sys.sleep(sleep > 0.01 ? 0.01 : sleep);
			}
			if (timeout == null) {
				if (evalLoopWaitStep(null, loop)) return true;
			} else if (evalLoopStep(null, loop)) return true;
			if (until != null && Sys.time() >= until) return false;
		}
		return false;
	}

	static function evalLoopDrain(ctx:Null<EvalContext>, loop:EvalLoopState, timeout:Null<Float>):Void {
		if (loop.started) throw "Event loop already started";
		loop.started = true;
		try {
			while (evalLoopExpected(ctx, loop)) {
				if (!evalLoopWaitUnlocked(ctx, loop, timeout)) break;
				timeout = null;
			}
		} catch (e) {
			loop.started = false;
			throw e;
		}
		loop.started = false;
	}

	static function evalLoopWaitUnlocked(ctx:Null<EvalContext>, loop:EvalLoopState, ?timeout:Null<Float>):Bool {
		if (evalLoopStep(ctx, loop)) return true;
		var until = timeout == null ? null : Sys.time() + timeout;
		while (evalLoopExpected(ctx, loop)) {
			var next = evalLoopNextDue(ctx, loop);
			if (next == null) {
				if (timeout == null) return false;
				var left = until - Sys.time();
				if (left <= 0) return false;
				Sys.sleep(left > 0.01 ? 0.01 : left);
			} else {
				var sleep = next - Sys.time();
				if (until != null && until < next) sleep = until - Sys.time();
				if (sleep > 0) Sys.sleep(sleep > 0.01 ? 0.01 : sleep);
			}
			if (evalLoopStep(ctx, loop)) return true;
			if (until != null && Sys.time() >= until) return false;
		}
		return false;
	}

	static function evalLoopRepeat(loop:EvalLoopState, fn:Void->Void, intervalMs:Int):EvalLoopTimer {
		var interval = (intervalMs < 1 ? 1 : intervalMs) / 1000.0;
		var timer = {fn: fn, interval: interval, next: Sys.time() + interval, cancelled: false};
		loop.timers.push(timer);
		return timer;
	}

	static function evalLoopCancel(timer:EvalLoopTimer):Void {
		timer.cancelled = true;
	}

	static function evalLoopPromise(loop:EvalLoopState):Void {
		loop.promised++;
	}

	static function evalLoopRunPromised(loop:EvalLoopState, fn:Void->Void):Void {
		if (loop.promised > 0) loop.promised--;
		loop.pending.push(fn);
	}

	static function evalLoopProgress(ctx:EvalContext, loop:EvalLoopState):EvalValue {
		if (loop.started) throw "Event loop already started";
		if (evalLoopRunDue(loop)) return nextEventTimeValue(ctx, "AnyTime", null);
		var next = evalLoopNextDue(null, loop);
		if (next != null) return nextEventTimeValue(ctx, "At", next);
		if (loop.promised > 0) return nextEventTimeValue(ctx, "AnyTime", null);
		return nextEventTimeValue(ctx, "Never");
	}

	static function threadEventLoopObject(ctx:EvalContext, loop:EvalLoopState):EvalValue {
		var value = mkObject([
			{name: "repeat", value: VFunction(function(a) {
				var fn = arg(a, 0);
				return eventHandlerValue(evalLoopRepeat(loop, function() applyFn(fn, []), toInt(arg(a, 1))));
			}, true)},
			{name: "cancel", value: VFunction(function(a) {
				var handler = eventHandlerOf(arg(a, 0));
				if (handler != null) evalLoopCancel(cast handler);
				return VNull;
			}, true)},
			{name: "promise", value: VFunction(function(a) { evalLoopPromise(loop); return VNull; }, true)},
			{name: "run", value: VFunction(function(a) {
				var fn = arg(a, 0);
				loop.pending.push(function() applyFn(fn, []));
				return VNull;
			}, true)},
			{name: "runPromised", value: VFunction(function(a) {
				var fn = arg(a, 0);
				evalLoopRunPromised(loop, function() applyFn(fn, []));
				return VNull;
			}, true)},
			{name: "progress", value: VFunction(function(a) return evalLoopProgress(ctx, loop), true)},
			{name: "wait", value: VFunction(function(a) return EvalValueTools.vbool(
				arg(a, 0) == VNull ? evalLoopWait(loop) : evalLoopWait(loop, toFloat(arg(a, 0)))), true)},
			{name: "loop", value: VFunction(function(a) { evalLoopDrain(ctx, loop, null); return VNull; }, true)}
		]);
		switch (value) {
			case VObject(o): eventLoopObjects.set(o, loop);
			case _:
		}
		return value;
	}

	static function eventLoopOfValue(v:EvalValue):Null<EvalLoopState> {
		return switch (EvalValueTools.vresolve(v)) {
			case VInstance(vi): threadEventLoops.get(vi);
			case VObject(o): eventLoopObjects.get(o);
			case _: null;
		}
	}

	static function mkTimer(ctx:EvalContext, timeMs:Int):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.Timer"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		var value = VInstance(vi);
		var loop = switch (nativeThreadSelfValue(ctx)) {
			case VInstance(thread):
				var current = eventLoopOfValue(nativeThreadEventLoop(ctx, thread));
				current == null ? newEvalLoop() : current;
			case _: newEvalLoop();
		}
		var handler = evalLoopRepeat(loop, function() {
			applyFn(EvalField.dynamicField(ctx, value, EvalHash.hash("run")), []);
		}, timeMs);
		nativeTimers.set(vi, {loop: loop, handler: handler});
		return value;
	}

	static function stopTimer(a:Array<EvalValue>):Void {
		var vi = thisInstance(a, "Timer");
		var timer = nativeTimers.get(vi);
		if (timer != null) {
			evalLoopCancel(cast timer.handler);
			nativeTimers.remove(vi);
		}
	}

	static function mkNativeThread(ctx:EvalContext, ?job:EvalValue):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("eval.vm.NativeThread"));
		ensureInstanceField(proto, "events");
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		var events = threadEventLoopObject(ctx, newEvalLoop());
		setInstanceFieldIfExists(vi, "events", events);
		nativeThreads.set(vi, {id: nativeThreadNextId++, messages: new sys.thread.Deque(), events: events});
		if (job != null && job != VNull) {
			var old = nativeThreadSelf;
			nativeThreadSelf = vi;
			try {
				applyFn(job, []);
			} catch (e) {
				nativeThreadSelf = old;
				throw e;
			}
			nativeThreadSelf = old;
		}
		return VInstance(vi);
	}

	static function nativeThreadSelfValue(ctx:EvalContext):EvalValue {
		if (nativeThreadSelf == null) {
			switch (mkNativeThread(ctx)) {
				case VInstance(vi): nativeThreadSelf = vi;
				case v: return v;
			}
		}
		return VInstance(nativeThreadSelf);
	}

	static function nativeThreadData(a:Array<EvalValue>):{id:Int, messages:sys.thread.Deque<EvalValue>, events:EvalValue} {
		return nativeThreads.get(thisInstance(a, "NativeThread"));
	}

	static function nativeThreadEventLoop(ctx:EvalContext, vi:VInstance):EvalValue {
		var thread = nativeThreads.get(vi);
		if (thread == null) return VNull;
		if (thread.events == VNull) {
			thread.events = threadEventLoopObject(ctx, newEvalLoop());
			setInstanceFieldIfExists(vi, "events", thread.events);
		}
		return thread.events;
	}

	static function setStaticFieldIfExists(ctx:EvalContext, typeName:String, fieldName:String, value:EvalValue):Void {
		var proto = ctx.staticPrototypes.get(EvalHash.hash(typeName));
		if (proto == null) return;
		var idx = proto.pnames.get(EvalHash.hash(fieldName));
		if (idx != null) proto.pfields[idx] = value;
	}

	static function setEntryPointThreadCount(ctx:EvalContext, count:Int):Void {
		entryPointThreadCount = count;
		setStaticFieldIfExists(ctx, "haxe.EntryPoint", "threadCount", VInt(entryPointThreadCount));
	}

	static function entryPointRunInMainThread(ctx:EvalContext, fn:EvalValue):Void {
		switch (nativeThreadSelfValue(ctx)) {
			case VInstance(vi):
				var loop = eventLoopOfValue(nativeThreadEventLoop(ctx, vi));
				if (loop != null) loop.pending.push(function() applyFn(fn, []));
			case _:
		}
	}

	static function entryPointAddThread(ctx:EvalContext, fn:EvalValue):Void {
		setEntryPointThreadCount(ctx, entryPointThreadCount + 1);
		var mainThread = switch (nativeThreadSelfValue(ctx)) {
			case VInstance(vi): vi;
			case _: null;
		}
		var mainLoop = mainThread == null ? null : eventLoopOfValue(nativeThreadEventLoop(ctx, mainThread));
		if (mainLoop != null) evalLoopPromise(mainLoop);
		try {
			mkNativeThread(ctx, VFunction(function(a) {
				applyFn(fn, []);
				setEntryPointThreadCount(ctx, entryPointThreadCount - 1);
				if (mainLoop != null) evalLoopRunPromised(mainLoop, function() {});
				return VNull;
			}, true));
		} catch (e) {
			setEntryPointThreadCount(ctx, entryPointThreadCount - 1);
			if (mainLoop != null) evalLoopRunPromised(mainLoop, function() {});
			throw e;
		}
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
		var bytes = thisBytes([bytesValue]);
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
		var vi = thisInstance(a, "BytesInput");
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

	static function arrayIteratorValue(ctx:EvalContext, arrayValue:EvalValue):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.iterators.ArrayIterator"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		nativeArrayIterators.set(vi, {array: thisArray([arrayValue]), current: 0});
		setInstanceFieldIfExists(vi, "array", arrayValue);
		setInstanceFieldIfExists(vi, "current", VInt(0));
		return VInstance(vi);
	}

	static function thisArrayIterator(a:Array<EvalValue>):{array:VArray, current:Int} {
		var vi = thisInstance(a, "ArrayIterator");
		var it = nativeArrayIterators.get(vi);
		if (it == null) throw "Unexpected value for ArrayIterator";
		return it;
	}

	static function arrayIteratorSetCurrent(v:EvalValue, current:Int):Void {
		switch (v) {
			case VInstance(vi): setInstanceFieldIfExists(vi, "current", VInt(current));
			case _:
		}
	}

	static function mapKeyValueIteratorValue(ctx:EvalContext, mapValue:EvalValue):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.iterators.MapKeyValueIterator"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		var entries = orderedMapEntries(mapValue);
		if (entries.length == 0) {
			var keys = applyFn(EvalField.dynamicField(ctx, mapValue, EvalHash.hash("keys")), []);
			while (EvalMisc.isTrue(callValueOn(keys, EvalField.dynamicField(ctx, keys, EvalHash.hash("hasNext")), []))) {
				var key = callValueOn(keys, EvalField.dynamicField(ctx, keys, EvalHash.hash("next")), []);
				var value = callValueOn(mapValue, EvalField.dynamicField(ctx, mapValue, EvalHash.hash("get")), [key]);
				entries.push({key: key, value: value});
			}
		}
		nativeMapKeyValueIterators.set(vi, {entries: entries, current: 0});
		setInstanceFieldIfExists(vi, "map", mapValue);
		setInstanceFieldIfExists(vi, "keys", arrayIteratorValue(ctx, VArray(new VArray([for (e in entries) e.key], entries.length))));
		return VInstance(vi);
	}

	static function thisMapKeyValueIterator(a:Array<EvalValue>):{entries:Array<MapEntry>, current:Int} {
		var vi = thisInstance(a, "MapKeyValueIterator");
		var it = nativeMapKeyValueIterators.get(vi);
		if (it == null) throw "Unexpected value for MapKeyValueIterator";
		return it;
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
		for (cp in ctx.classPath) {
			var path = cp == "" ? file : cp + file;
			if (sys.FileSystem.exists(path)) return mkStr(path);
		}
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

	static function stackFilePos(ctx:EvalContext, p:Position, item:EvalValue):EvalValue {
		var file = p == null ? "?" : p.file;
		if (file == null) file = "?";
		var infos = Position.getInfos(p == null ? Position.nullPos : p);
		return stackEnum(ctx, "FilePos", [item, mkStr(file), VInt(infos.line), VInt(infos.column)]);
	}

	static function stackItem(ctx:EvalContext, p:Position, kind:EvalEnvKind):EvalValue {
		return switch (kind) {
			case EKLocalFunction(index):
				stackFilePos(ctx, p, stackEnum(ctx, "LocalFunction", [VInt(index)]));
			case EKMethod(typeKey, fieldKey):
				var typeName = EvalHash.revHash(typeKey);
				var fieldName = EvalHash.revHash(fieldKey);
				stackFilePos(ctx, p, stackEnum(ctx, "Method", [typeName == null ? VNull : mkStr(typeName), fieldName == null ? VNull : mkStr(fieldName)]));
			case EKEntrypoint:
				stackFilePos(ctx, p, VNull);
		};
	}

	static function envStackItem(ctx:EvalContext, env:EvalEnv):EvalValue {
		return stackItem(ctx, EvalExceptions.envPosition(env), env.info.kind);
	}

	static function envCallStackItem(ctx:EvalContext, env:EvalEnv):EvalValue {
		var file = env.info.file == 0 ? "?" : EvalHash.revHash(env.info.file);
		if (file == null) file = "?";
		return stackItem(ctx, new Position(file, env.info.min, env.info.max), env.info.kind);
	}

	static function callStackValue(ctx:EvalContext):EvalValue {
		var envs = EvalExceptions.callStack(EvalContext.getEval(ctx));
		if (envs.length >= 2) envs = envs.slice(2);
		var items = [for (env in envs) envCallStackItem(ctx, env)];
		return VArray(new VArray(items, items.length));
	}

	public static function exceptionStackValue(ctx:EvalContext):EvalValue {
		var frames = EvalContext.getEval(ctx).exceptionStack;
		var items = [for (i in 0...frames.length) {
			var frame = frames[frames.length - 1 - i];
			stackItem(ctx, frame.pos, frame.kind);
		}];
		return VArray(new VArray(items, items.length));
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
		return fileName + ":" + lineNumber + ": " + parts.join(",") + "\n";
	}

	static function writeStdoutString(s:String, newline:Bool):Void {
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
		if (newline) Sys.println("");
	}

	static function flushStdout():Void {
		try Sys.stdout().flush() catch (_:Dynamic) {}
	}

	static function sysProgramPath(ctx:EvalContext):EvalValue {
		for (mt in ctx.typeCache) switch (mt) {
			case TClassDecl(c):
				if (c.statics.exists("main")) {
					var file = c.pos.file;
					return file == null || file == "?" ? VNull : mkStr(sys.FileSystem.fullPath(file));
				}
			case _:
		}
		return VNull;
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

	// A map's runtime key folds to a string for storage; StringMap keeps the string, IntMap the int,
	// EnumValueMap a structural digest of the constructor index and (recursively) its arguments.
	static function mapKey(v:EvalValue):String {
		return switch (v) {
			case VString(s): normalizeString(s.sstring);
			case VInt(i): Std.string(i);
			case VEnumValue(ev): "e:" + ev.epath + ":" + ev.eindex + ":" + [for (a in ev.eargs) mapKey(a)].join(",");
			case VObject(o): "o:" + objId(o);
			case VInstance(vi): "o:" + objId(vi);
			case _: stringOf(v);
		};
	}

	static function orderedMapEntries(v:EvalValue):Array<MapEntry> {
		return switch (v) {
			case VInstance(vi):
				var m = thisMap([v]);
				var order = nativeMapOrders.get(vi);
				var entries = order == null ? [for (e in m) e] : [for (k in order) if (m.exists(k)) m.get(k)];
				if (vi.iproto.ppath == EvalHash.hash("haxe.ds.StringMap")) {
					entries.sort(function(a, b) {
						var ak = stringOf(a.key);
						var bk = stringOf(b.key);
						var d = seededStringHash(ak) - seededStringHash(bk);
						return d != 0 ? d : Reflect.compare(ak, bk);
					});
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

	static function stringFastCodeAt(s:String, index:Int):EvalValue {
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
		buf.add(String.fromCharCode(c));
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
			case _:
				haxe.io.Bytes.ofString(normalizeString(stringOf(v)));
		}
	}

	static function stringReplace(s:String, sub:String, by:String):String {
		s = normalizeString(s);
		sub = normalizeString(sub);
		by = normalizeString(by);
		if (sub.length == 0) {
			if (by.length == 0 || s.length == 0) return s;
			var b = new StringBuf();
			for (i in 0...s.length) {
				b.add(s.charAt(i));
				if (i != s.length - 1) b.add(by);
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
		if (digits == 0) return Math.NaN;
		if (i < part.length && (part.charCodeAt(i) == "e".code || part.charCodeAt(i) == "E".code)) {
			i++;
			if (i < part.length && (part.charCodeAt(i) == "+".code || part.charCodeAt(i) == "-".code)) i++;
			var expDigits = 0;
			while (i < part.length && part.charCodeAt(i) >= "0".code && part.charCodeAt(i) <= "9".code) {
				i++;
				expDigits++;
			}
			if (expDigits == 0) return Math.NaN;
		}
		return i == part.length ? Std.parseFloat(part) : Math.NaN;
	}

	static function stringIndexOf(s:String, sub:String, startValue:EvalValue):Int {
		var codes = utf8Codes(normalizeString(s));
		var subCodes = utf8Codes(normalizeString(sub));
		var start = startValue == VNull ? 0 : toInt(startValue);
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

	static function stringLastIndexOf(s:String, sub:String, startValue:EvalValue):Int {
		var codes = utf8Codes(normalizeString(s));
		var subCodes = utf8Codes(normalizeString(sub));
		var start = startValue == VNull ? codes.length : toInt(startValue);
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
		return s.length >= start.length && stringLastIndexOf(s, start, VInt(0)) == 0;
	}

	static function stringEndsWith(s:String, end:String):Bool {
		var elen = end.length;
		var slen = s.length;
		return slen >= elen && stringIndexOf(s, end, VInt(slen - elen)) == slen - elen;
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
		for (k in keys) if (fields.exists(k)) parts.push(EvalHash.revHash(k) + ": " + stringOfDepth(fields.get(k), depth + 1));
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
					case IDate(ts): Date.fromTime(ts).toString();
					case IPos(p): posString(p);
					case IRegex(_): "#regexp";
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
		function classVal(path:Int):EvalValue {
			var p = ctx.staticPrototypes.get(path);
			return p == null ? VNull : p.pvalue;
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
		nativeThreadSelf = null;
		nativeThreadNextId = 1;
		threadEventLoops = new haxe.ds.ObjectMap();
		eventLoopObjects = new haxe.ds.ObjectMap();
		threadEventHandlers = new Map();
		threadEventHandlerNextId = 1;
		nativeTimers = new haxe.ds.ObjectMap();
		evalLoopCreated = false;
		entryPointThreadCount = 0;
		nativeRegexInfo = new haxe.ds.ObjectMap();
		macroMessages = [];
		var s = ctx.builtins.staticBuiltins;

		reg(s, "Math", "PI", VFloat(Math.PI));
		reg(s, "Math", "NaN", VFloat(Math.NaN));
		reg(s, "Math", "POSITIVE_INFINITY", VFloat(Math.POSITIVE_INFINITY));
		reg(s, "Math", "NEGATIVE_INFINITY", VFloat(Math.NEGATIVE_INFINITY));
		reg(s, "Math", "floor", vfn(a -> VInt(evalMathInt(Math.ffloor(toFloat(arg(a, 0)))))));
		reg(s, "Math", "ceil", vfn(a -> VInt(evalMathInt(Math.fceil(toFloat(arg(a, 0)))))));
		reg(s, "Math", "round", vfn(a -> VInt(evalMathInt(Math.fround(toFloat(arg(a, 0)))))));
		reg(s, "Math", "abs", vfn(a -> VFloat(Math.abs(toFloat(arg(a, 0))))));
		reg(s, "Math", "sqrt", vfn(a -> VFloat(Math.sqrt(toFloat(arg(a, 0))))));
		reg(s, "Math", "pow", vfn(a -> VFloat(Math.pow(toFloat(arg(a, 0)), toFloat(arg(a, 1))))));
		reg(s, "Math", "min", vfn(a -> VFloat(Math.min(toFloat(arg(a, 0)), toFloat(arg(a, 1))))));
		reg(s, "Math", "max", vfn(a -> VFloat(Math.max(toFloat(arg(a, 0)), toFloat(arg(a, 1))))));
		reg(s, "Math", "log", vfn(a -> VFloat(Math.log(toFloat(arg(a, 0))))));
		reg(s, "Math", "exp", vfn(a -> VFloat(Math.exp(toFloat(arg(a, 0))))));
		reg(s, "Math", "sin", vfn(a -> VFloat(Math.sin(toFloat(arg(a, 0))))));
		reg(s, "Math", "cos", vfn(a -> VFloat(Math.cos(toFloat(arg(a, 0))))));
		reg(s, "Math", "tan", vfn(a -> VFloat(Math.tan(toFloat(arg(a, 0))))));
		reg(s, "Math", "asin", vfn(a -> VFloat(Math.asin(toFloat(arg(a, 0))))));
		reg(s, "Math", "acos", vfn(a -> VFloat(Math.acos(toFloat(arg(a, 0))))));
		reg(s, "Math", "atan", vfn(a -> VFloat(Math.atan(toFloat(arg(a, 0))))));
		reg(s, "Math", "ffloor", vfn(a -> VFloat(Math.ffloor(toFloat(arg(a, 0))))));
		reg(s, "Math", "fceil", vfn(a -> VFloat(Math.fceil(toFloat(arg(a, 0))))));
		reg(s, "Math", "fround", vfn(a -> VFloat(Math.fround(toFloat(arg(a, 0))))));
		reg(s, "Math", "atan2", vfn(a -> VFloat(Math.atan2(toFloat(arg(a, 0)), toFloat(arg(a, 1))))));
		reg(s, "Math", "isNaN", vfn(a -> EvalValueTools.vbool(Math.isNaN(toFloat(arg(a, 0))))));
		reg(s, "Math", "isFinite", vfn(a -> EvalValueTools.vbool(Math.isFinite(toFloat(arg(a, 0))))));
		reg(s, "Math", "random", vfn(a -> VFloat(Math.random())));
		reg(s, "String", "fromCharCode", vfn(a -> mkStr(String.fromCharCode(toInt(arg(a, 0))))));
		reg(s, "StringTools", "fastCodeAt", vfn(a -> stringFastCodeAt(stringOf(arg(a, 0)), toInt(arg(a, 1)))));
		reg(s, "StringTools", "unsafeCodeAt", vfn(a -> stringFastCodeAt(stringOf(arg(a, 0)), toInt(arg(a, 1)))));
		reg(s, "StringTools", "replace", vfn(a -> mkStr(stringReplace(stringOf(arg(a, 0)), stringOf(arg(a, 1)), stringOf(arg(a, 2))))));
		reg(s, "StringTools", "hex", vfn(a -> mkStr(stringHex(toInt(arg(a, 0)), arg(a, 1)))));
		reg(s, "StringTools", "htmlEscape", vfn(a -> mkStr(stringHtmlEscape(stringOf(arg(a, 0)), arg(a, 1) == VTrue))));
		reg(s, "StringTools", "htmlUnescape", vfn(a -> mkStr(stringHtmlUnescape(stringOf(arg(a, 0))))));
		reg(s, "StringTools", "contains", vfn(a -> EvalValueTools.vbool(stringIndexOf(stringOf(arg(a, 0)), stringOf(arg(a, 1)), VInt(0)) != -1)));
		reg(s, "StringTools", "startsWith", vfn(a -> EvalValueTools.vbool(stringStartsWith(stringOf(arg(a, 0)), stringOf(arg(a, 1))))));
		reg(s, "StringTools", "endsWith", vfn(a -> EvalValueTools.vbool(stringEndsWith(stringOf(arg(a, 0)), stringOf(arg(a, 1))))));
		reg(s, "StringTools", "isSpace", vfn(a -> EvalValueTools.vbool(stringIsSpace(stringOf(arg(a, 0)), toInt(arg(a, 1))))));
		reg(s, "StringTools", "ltrim", vfn(a -> mkStr(stringLTrim(stringOf(arg(a, 0))))));
		reg(s, "StringTools", "rtrim", vfn(a -> mkStr(stringRTrim(stringOf(arg(a, 0))))));
		reg(s, "StringTools", "trim", vfn(a -> mkStr(stringLTrim(stringRTrim(stringOf(arg(a, 0)))))));
		reg(s, "StringTools", "lpad", vfn(a -> mkStr(stringLPad(stringOf(arg(a, 0)), stringOf(arg(a, 1)), toInt(arg(a, 2))))));
		reg(s, "StringTools", "rpad", vfn(a -> mkStr(stringRPad(stringOf(arg(a, 0)), stringOf(arg(a, 1)), toInt(arg(a, 2))))));
		reg(s, "StringTools", "isEof", vfn(a -> EvalValueTools.vbool(arg(a, 0) == VNull)));
		reg(s, "StringTools", "urlEncode", vfn(a -> mkStr(urlEncode(stringOf(arg(a, 0))))));
		reg(s, "StringTools", "urlDecode", vfn(a -> mkStr(urlDecode(stringOf(arg(a, 0))))));
		reg(s, "haxe.SysTools", "quoteUnixArg", vfn(a -> mkStr(haxe.SysTools.quoteUnixArg(stringOf(arg(a, 0))))));
		reg(s, "haxe.SysTools", "quoteWinArg", vfn(a -> mkStr(haxe.SysTools.quoteWinArg(stringOf(arg(a, 0)), arg(a, 1) == VTrue))));
		reg(s, "Xml", "Element", VInt(0));
		reg(s, "Xml", "PCData", VInt(1));
		reg(s, "Xml", "CData", VInt(2));
		reg(s, "Xml", "Comment", VInt(3));
		reg(s, "Xml", "DocType", VInt(4));
		reg(s, "Xml", "ProcessingInstruction", VInt(5));
		reg(s, "Xml", "Document", VInt(6));
		reg(s, "Xml", "parse", vfn(a -> try xmlValue(ctx, Xml.parse(stringOf(arg(a, 0)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(s, "Xml", "createElement", vfn(a -> xmlValue(ctx, Xml.createElement(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createPCData", vfn(a -> xmlValue(ctx, Xml.createPCData(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createCData", vfn(a -> xmlValue(ctx, Xml.createCData(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createComment", vfn(a -> xmlValue(ctx, Xml.createComment(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createDocType", vfn(a -> xmlValue(ctx, Xml.createDocType(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createProcessingInstruction", vfn(a -> xmlValue(ctx, Xml.createProcessingInstruction(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createDocument", vfn(a -> xmlValue(ctx, Xml.createDocument())));
		reg(s, "haxe.xml.Printer", "print", vfn(a -> mkStr(haxe.xml.Printer.print(thisXml([arg(a, 0)]), arg(a, 1) == VTrue))));
		reg(s, "Std", "random", vfn(a -> VInt(Std.random(toInt(arg(a, 0))))));
		reg(s, "Std", "isOfType", vfn(a -> EvalValueTools.vbool(stdIsOfTypeCtx(ctx, arg(a, 0), arg(a, 1)))));
		reg(s, "Std", "is", vfn(a -> EvalValueTools.vbool(stdIsOfTypeCtx(ctx, arg(a, 0), arg(a, 1)))));
		reg(s, "Std", "downcast", vfn(a -> stdDowncast(ctx, arg(a, 0), arg(a, 1))));
		reg(s, "Std", "instance", vfn(a -> stdDowncast(ctx, arg(a, 0), arg(a, 1))));

		reg(s, "Std", "int", vfn(a -> VInt(Std.int(toFloat(arg(a, 0))))));
		reg(s, "Std", "string", vfn(a -> mkStr(stringOf(arg(a, 0)))));
		reg(s, "Std", "parseInt", vfn(a -> stdParseInt(stringOf(arg(a, 0)))));
		reg(s, "Std", "parseFloat", vfn(a -> VFloat(stdParseFloat(stringOf(arg(a, 0))))));
		reg(s, "haxe.Log", "trace", vfn(a -> { writeStdoutString(traceString(ctx, arg(a, 0), arg(a, 1)), false); VNull; }));
		reg(s, "haxe.EntryPoint", "threadCount", VInt(0));
		reg(s, "haxe.EntryPoint", "addThread", vfn(a -> { entryPointAddThread(ctx, arg(a, 0)); VNull; }));
		reg(s, "haxe.EntryPoint", "runInMainThread", vfn(a -> { entryPointRunInMainThread(ctx, arg(a, 0)); VNull; }));
		reg(s, "haxe.EntryPoint", "wakeup", vfn(a -> VNull));
		reg(s, "haxe.EntryPoint", "run", vfn(a -> { processEvents(); VNull; }));
		reg(s, "Sys", "println", vfn(a -> { writeStdoutString(stringOf(arg(a, 0)), true); VNull; }));
		reg(s, "Sys", "print", vfn(a -> { writeStdoutString(stringOf(arg(a, 0)), false); VNull; }));
		reg(s, "Sys", "args", vfn(a -> {
			var args = [for (s in Sys.args()) mkStr(s)];
			VArray(new VArray(args, args.length));
		}));
		reg(s, "Sys", "_command", vfn(a -> {
			flushStdout();
			VInt(Sys.command(stringOf(arg(a, 0))));
		}));
		reg(s, "Sys", "command", vfn(a -> {
			var cmd = stringOf(arg(a, 0));
			var args = processArgs(ctx, arg(a, 1));
			flushStdout();
			return VInt(args == null ? Sys.command(cmd) : Sys.command(cmd, args));
		}));
		reg(s, "Sys", "cpuTime", vfn(a -> VFloat(Sys.cpuTime())));
		reg(s, "Sys", "environment", vfn(a -> mkStringMap(ctx, Sys.environment())));
		reg(s, "Sys", "exit", vfn(a -> { Sys.exit(toInt(arg(a, 0))); VNull; }));
		reg(s, "Sys", "getCwd", vfn(a -> mkStr(Sys.getCwd())));
		reg(s, "Sys", "getEnv", vfn(a -> {
			var v = Sys.getEnv(stringOf(arg(a, 0)));
			v == null ? VNull : mkStr(v);
		}));
		reg(s, "Sys", "getChar", vfn(a -> VInt(Sys.getChar(arg(a, 0) == VTrue))));
		reg(s, "Sys", "programPath", vfn(a -> sysProgramPath(ctx)));
		reg(s, "Sys", "putEnv", vfn(a -> { Sys.putEnv(stringOf(arg(a, 0)), arg(a, 1) == VNull ? null : stringOf(arg(a, 1))); VNull; }));
		reg(s, "Sys", "setCwd", vfn(a -> { Sys.setCwd(stringOf(arg(a, 0))); VNull; }));
		reg(s, "Sys", "setTimeLocale", vfn(a -> VFalse));
		reg(s, "Sys", "sleep", vfn(a -> { Sys.sleep(toFloat(arg(a, 0))); VNull; }));
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
		reg(s, "eval.vm.Context", "callMacroApi", vfn(a -> {
			var name = stringOf(arg(a, 0));
			switch (name) {
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
					VFunction(function(args) return mkStringMap(ctx, definesForExternal(ctx.defines.values)), true);
				case "class_path":
					VFunction(function(args) return valueArray([for (p in ctx.classPath) mkStr(p)]), true);
				case "resolve_path":
					VFunction(function(args) return resolveMacroPath(ctx, stringOf(arg(args, 0))), true);
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
				case "warning":
					VFunction(function(args) {
						macroMessages.push(macroMessage(ctx, "Warning", arg(args, 0), args.length > 1 ? arg(args, 1) : mkPos(ctx, EvalMacro.currentPosition())));
						return VNull;
					}, true);
				case "info":
					VFunction(function(args) {
						macroMessages.push(macroMessage(ctx, "Info", arg(args, 0), args.length > 1 ? arg(args, 1) : mkPos(ctx, EvalMacro.currentPosition())));
						return VNull;
					}, true);
				case "get_messages":
					VFunction(function(args) return VArray(new VArray(macroMessages.copy(), macroMessages.length)), true);
				case "filter_messages":
					VFunction(function(args) {
						var pred = arg(args, 0);
						macroMessages = [for (msg in macroMessages) if (EvalMisc.isTrue(applyFn(pred, [msg]))) msg];
						return VNull;
					}, true);
				case "init_macros_done":
					VFunction(function(args) return VTrue, true);
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
					VFunction(function(args) return VArray(new VArray([], 0)), true);
				case "get_local_imports":
					VFunction(function(args) return localImports(ctx), true);
				case "local_vars":
					VFunction(function(args) return mkStringMap(ctx, new Map()), true);
				case "signature":
					VFunction(function(args) return mkStr(haxe.crypto.Md5.encode(serializeEval(ctx, arg(args, 0), false, false))), true);
				case "add_resource":
					VFunction(function(args) {
						var name = stringOf(arg(args, 0));
						if (name == "") EvalExceptions.excString(ctx, "Empty resource name");
						var bytes = thisBytes([arg(args, 1)]);
						ctx.resources.set(name, bytes.sub(0, bytes.length));
						return VNull;
					}, true);
				case "get_resources":
					VFunction(function(args) return mkStringBytesMap(ctx, ctx.resources), true);
				case "make_expr":
					VFunction(function(args) return EvalMacro.makeExprValue(ctx, arg(args, 0)), true);
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
				case _:
					EvalExceptions.excString(ctx, "Macro API not implemented: " + name);
			}
		}));
		reg(s, "eval.vm.Context", "loadPlugin", vfn(a ->
			EvalExceptions.excString(ctx, "error loading shared library: " + nativeStringOf(arg(a, 0)))));

		var inst = ctx.builtins.instanceBuiltins;

		reg(inst, "haxe.Exception", "get_stack", vmethod(a -> {
			var stack = EvalField.field(ctx, arg(a, 0), EvalHash.keyExceptionStack);
			stack == VNull ? EvalField.field(ctx, arg(a, 0), EvalHash.keyNativeStack) : stack;
		}));
		reg(inst, "String", "charAt", vmethod(a -> mkStr(stringCharAt(thisString(a), toInt(arg(a, 1))))));
		reg(inst, "String", "charCodeAt", vmethod(a -> {
			var str = thisString(a);
			var i = toInt(arg(a, 1));
			stringFastCodeAt(str, i);
		}));
		reg(inst, "String", "cca", vmethod(a -> {
			var str = thisString(a);
			var i = toInt(arg(a, 1));
			stringFastCodeAt(str, i);
		}));
		reg(inst, "String", "indexOf", vmethod(a -> VInt(stringIndexOf(thisString(a), stringOf(arg(a, 1)), arg(a, 2)))));
		reg(inst, "String", "lastIndexOf", vmethod(a -> {
			var str = thisString(a);
			VInt(stringLastIndexOf(str, stringOf(arg(a, 1)), arg(a, 2)));
		}));
		reg(inst, "String", "toUpperCase", vmethod(a -> mkStr(thisString(a).toUpperCase())));
		reg(inst, "String", "toLowerCase", vmethod(a -> mkStr(thisString(a).toLowerCase())));
		reg(inst, "String", "substr", vmethod(a -> {
			var str = thisString(a);
			var pos = toInt(arg(a, 1));
			mkStr(stringSubstr(str, pos, a.length > 2 && arg(a, 2) != VNull ? toInt(arg(a, 2)) : null));
		}));
		reg(inst, "String", "substring", vmethod(a -> {
			var str = thisString(a);
			var start = toInt(arg(a, 1));
			mkStr(stringSubstring(str, start, a.length > 2 && arg(a, 2) != VNull ? toInt(arg(a, 2)) : null));
		}));
		reg(inst, "String", "split", vmethod(a -> {
			var parts = stringSplit(thisString(a), stringOf(arg(a, 1)));
			VArray(new VArray([for (p in parts) mkStr(p)], parts.length));
		}));
		reg(inst, "String", "toString", vmethod(a -> arg(a, 0)));

		reg(inst, "Array", "push", vmethod(a -> {
			var va = thisArray(a);
			VInt(arrayPush(va, arg(a, 1)));
		}));
		reg(inst, "Array", "pop", vmethod(a -> {
			var va = thisArray(a);
			if (va.alength == 0) VNull;
			else {
				var v = va.avalues[va.alength - 1];
				va.avalues[va.alength - 1] = VNull;
				va.alength--;
				v;
			}
		}));
		reg(inst, "Array", "concat", vmethod(a -> {
			var va = thisArray(a);
			var other = thisArray([arg(a, 1)]);
			var out = arrayLive(va).concat(arrayLive(other));
			VArray(new VArray(out, out.length));
		}));
		reg(inst, "Array", "join", vmethod(a -> {
			var va = thisArray(a);
			mkStr([for (i in 0...va.alength) stringOf(va.avalues[i])].join(stringOf(arg(a, 1))));
		}));
		reg(inst, "Array", "indexOf", vmethod(a -> {
			var va = thisArray(a);
			var target = arg(a, 1);
			var fromIndex = a.length > 2 && arg(a, 2) != VNull ? toInt(arg(a, 2)) : 0;
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
			var va = thisArray(a);
			mkStr("[" + [for (i in 0...va.alength) stringOf(va.avalues[i])].join(",") + "]");
		}));
		reg(inst, "Array", "iterator", vmethod(a -> arrayIteratorValue(ctx, a[0])));
		reg(inst, "IntIterator", "hasNext", vmethod(a -> {
			var self = arg(a, 0);
			EvalValueTools.vbool(toInt(EvalField.field(ctx, self, EvalHash.hash("min"))) < toInt(EvalField.field(ctx, self, EvalHash.hash("max"))));
		}));
		reg(inst, "IntIterator", "next", vmethod(a -> {
			var self = arg(a, 0);
			var min = toInt(EvalField.field(ctx, self, EvalHash.hash("min")));
			setDynamicField(self, EvalHash.hash("min"), VInt(min + 1));
			VInt(min);
		}));
		reg(inst, "haxe.iterators.ArrayIterator", "hasNext", vmethod(a -> {
			var it = thisArrayIterator(a);
			EvalValueTools.vbool(it.current < it.array.alength);
		}));
		reg(inst, "haxe.iterators.ArrayIterator", "next", vmethod(a -> {
			var it = thisArrayIterator(a);
			if (it.current >= it.array.alength) VNull else {
				var value = it.array.avalues[it.current++];
				arrayIteratorSetCurrent(arg(a, 0), it.current);
				value;
			}
		}));
		reg(inst, "haxe.iterators.MapKeyValueIterator", "hasNext", vmethod(a -> {
			var it = thisMapKeyValueIterator(a);
			EvalValueTools.vbool(it.current < it.entries.length);
		}));
		reg(inst, "haxe.iterators.MapKeyValueIterator", "next", vmethod(a -> {
			var it = thisMapKeyValueIterator(a);
			if (it.current >= it.entries.length) VNull else {
				var entry = it.entries[it.current++];
				mkObject([{name: "value", value: entry.value}, {name: "key", value: entry.key}]);
			}
		}));
		reg(inst, "Array", "keyValueIterator", vmethod(a -> EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.iterators.ArrayKeyValueIterator"), [a[0]])));
		reg(inst, "Array", "slice", vmethod(a -> {
			var va = thisArray(a);
			var length = va.alength;
			var pos = toInt(arg(a, 1));
			var end = a.length > 2 && arg(a, 2) != VNull ? toInt(arg(a, 2)) : length;
			if (end > length) end = length;
			if (pos < 0) pos = length + pos;
			if (end < 0) end = length + end;
			if (pos < 0) pos = 0;
			if (end < 0) end = 0;
			var sub = arrayLive(va).slice(pos, end);
			VArray(new VArray(sub, sub.length));
		}));
		reg(inst, "Array", "splice", vmethod(a -> {
			var va = thisArray(a);
			var pos = toInt(arg(a, 1));
			var len = toInt(arg(a, 2));
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
			var va = thisArray(a);
			va.avalues = arrayLive(va);
			va.avalues.reverse();
			VNull;
		}));
		reg(inst, "Array", "sort", vmethod(a -> {
			var va = thisArray(a); var cmp = arg(a, 1);
			va.avalues = arrayLive(va);
			va.avalues.sort((x, y) -> toInt(applyFn(cmp, [x, y])));
			VNull;
		}));
		reg(inst, "Array", "contains", vmethod(a -> {
			var va = thisArray(a); var t = arg(a, 1); var found = false;
			for (i in 0...va.alength) if (EvalValueTools.equals(va.avalues[i], t)) { found = true; break; }
			EvalValueTools.vbool(found);
		}));
		reg(inst, "Array", "filter", vmethod(a -> {
			var va = thisArray(a); var fn = arg(a, 1); var out:Array<EvalValue> = [];
			for (i in 0...va.alength) {
				var v = va.avalues[i];
				if (EvalMisc.isTrue(applyFn(fn, [v]))) out.push(v);
			}
			VArray(new VArray(out, out.length));
		}));
		reg(inst, "Array", "map", vmethod(a -> {
			var va = thisArray(a); var fn = arg(a, 1); var out:Array<EvalValue> = [];
			for (i in 0...va.alength) out.push(applyFn(fn, [va.avalues[i]]));
			VArray(new VArray(out, out.length));
		}));
		reg(inst, "Array", "copy", vmethod(a -> { var va = thisArray(a); var out = arrayLive(va); VArray(new VArray(out, out.length)); }));
		reg(inst, "Array", "remove", vmethod(a -> {
			var va = thisArray(a); var t = arg(a, 1); var idx = -1;
			for (i in 0...va.alength) if (EvalValueTools.equals(va.avalues[i], t)) { idx = i; break; }
			if (idx >= 0) { arrayRemoveAt(va, idx); EvalValueTools.vbool(true); } else EvalValueTools.vbool(false);
		}));
		reg(inst, "Array", "insert", vmethod(a -> {
			var va = thisArray(a);
			var pos = toInt(arg(a, 1));
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
			var va = thisArray(a);
			if (va.alength == 0) VNull else {
				var v = va.avalues[0];
				va.alength--;
				for (i in 0...va.alength) va.avalues[i] = va.avalues[i + 1];
				v;
			}
		}));
		reg(inst, "Array", "unshift", vmethod(a -> {
			var va = thisArray(a);
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
			var va = thisArray(a); var t = arg(a, 1); var idx = -1; var last = va.alength - 1;
			if (va.alength == 0) return VInt(-1);
			var i = a.length > 2 && arg(a, 2) != VNull ? toInt(arg(a, 2)) : last;
			if (i < 0) i = va.alength + i;
			if (i < 0) i = 0 else if (i > last) i = last;
			while (i >= 0) { if (EvalValueTools.equals(va.avalues[i], t)) { idx = i; break; } i--; }
			VInt(idx);
		}));
		reg(inst, "Array", "resize", vmethod(a -> {
			var va = thisArray(a); var len = toInt(arg(a, 1));
			if (len < 0) throw 'Invalid_argument("Array.fill")';
			if (va.alength < len) arraySet(va, len - 1, VNull);
			else if (va.alength > len) {
				for (i in len...va.alength) va.avalues[i] = VNull;
				va.alength = len;
			}
			VNull;
		}));

		reg(s, "eval.Vector", "fromArrayCopy", vfn(a -> {
			var va = thisArray([arg(a, 0)]);
			VVector(va.avalues.slice(0, va.alength));
		}));
		reg(inst, "eval.Vector", "blit", vmethod(a -> {
			var src = thisVector([arg(a, 0)]);
			var srcPos = toInt(arg(a, 1));
			var dest = thisVector([arg(a, 2)]);
			var destPos = toInt(arg(a, 3));
			var len = toInt(arg(a, 4));
			var tmp = src.slice(srcPos, srcPos + len);
			for (i in 0...len) dest[destPos + i] = tmp[i];
			VNull;
		}));
		reg(inst, "eval.Vector", "toArray", vmethod(a -> {
			var vv = thisVector(a);
			VArray(new VArray(vv.copy(), vv.length));
		}));
		reg(inst, "eval.Vector", "copy", vmethod(a -> VVector(thisVector(a).copy())));
		reg(inst, "eval.Vector", "join", vmethod(a -> mkStr([for (v in thisVector(a)) stringOf(v)].join(stringOf(arg(a, 1))))));
		reg(inst, "eval.Vector", "map", vmethod(a -> {
			var fn = arg(a, 1);
			VVector([for (v in thisVector(a)) applyFn(fn, [v])]);
		}));

		reg(s, "Reflect", "fields", vfn(a -> {
			var names = fieldNames(arg(a, 0));
			VArray(new VArray([for (n in names) mkStr(n)], names.length));
		}));
		reg(s, "Reflect", "field", vfn(a -> {
			var o = arg(a, 0);
			var name = EvalHash.hash(stringOf(arg(a, 1)));
			switch (EvalValueTools.vresolve(o)) {
				case VPrototype(proto) if (isReflectHidden(proto.ppath, name, true)): VNull;
				case VInstance(vi) if (isReflectHidden(vi.iproto.ppath, name, false)): VNull;
				case _:
					if (o == VNull) VNull else EvalField.dynamicField(ctx, o, name);
			}
		}));
		reg(s, "Reflect", "setField", vfn(a -> {
			setDynamicField(arg(a, 0), EvalHash.hash(stringOf(arg(a, 1))), arg(a, 2));
			VNull;
		}));
		reg(s, "Reflect", "hasField", vfn(a -> {
			EvalValueTools.vbool(hasField(ctx, arg(a, 0), EvalHash.hash(stringOf(arg(a, 1)))));
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
		reg(s, "Reflect", "copy", vfn(a -> copyValue(arg(a, 0))));
		reg(s, "Reflect", "deleteField", vfn(a -> EvalValueTools.vbool(deleteDynamicField(arg(a, 0), EvalHash.hash(stringOf(arg(a, 1)))))));
		reg(s, "Reflect", "getProperty", vfn(a -> {
			var o = arg(a, 0);
			if (o == VNull) VNull else {
				var name = stringOf(arg(a, 1));
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
		reg(s, "Reflect", "makeVarArgs", vfn(a -> {
			var fn = arg(a, 0);
			VFunction(function(vl:Array<EvalValue>):EvalValue return applyFn(fn, [VArray(new VArray(vl, vl.length))]), true);
		}));
		reg(s, "Reflect", "setProperty", vfn(a -> {
			var o = arg(a, 0);
			var name = stringOf(arg(a, 1));
			var setter = EvalField.field(ctx, o, EvalHash.hash("set_" + name));
			if (setter != VNull) callValueOn(o, setter, [arg(a, 2)]);
			else {
				setDynamicField(o, EvalHash.hash(name), arg(a, 2));
				VNull;
			}
		}));

		reg(s, "Type", "getClass", vfn(a -> switch (arg(a, 0)) {
			case VInstance(vi):
				classValue(ctx, vi.iproto.ppath);
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
		reg(s, "Type", "createInstance", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) {
				case PClass(_) if (proto.ppath == EvalHash.key_String):
					var args = argList(arg(a, 1));
					args.length == 1 ? mkStr(stringOf(args[0])) : EvalEmitter.constructPath(ctx, proto.ppath, args);
				case PClass(_): EvalEmitter.constructPath(ctx, proto.ppath, argList(arg(a, 1)));
				case _: VNull;
			};
			case _: VNull;
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
		reg(s, "Type", "createEnum", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(_):
				createEnumByName(ctx, arg(a, 0), EvalHash.hash(stringOf(arg(a, 1))), arg(a, 2));
			case _: EvalExceptions.unexpectedValue(ctx, arg(a, 0), "enum");
		}));
		reg(s, "Type", "createEnumIndex", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) {
				case PEnum(cs):
					var idx = toInt(arg(a, 1));
					if (idx < 0 || idx >= cs.length) throw "nth";
					createEnumByName(ctx, arg(a, 0), EvalHash.hash(cs[idx].name), arg(a, 2));
				case _: VNull;
			};
			case _: VNull;
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
		reg(s, "Type", "enumParameters", vfn(a -> switch (arg(a, 0)) {
			case VEnumValue(ev): VArray(new VArray(ev.eargs.copy(), ev.eargs.length));
			case _: VArray(new VArray([], 0));
		}));
		reg(s, "Type", "enumEq", vfn(a -> EvalValueTools.vbool(enumEqValue(arg(a, 0), arg(a, 1)))));
		reg(s, "Type", "enumIndex", vfn(a -> switch (arg(a, 0)) { case VEnumValue(ev): VInt(ev.eindex); case _: VInt(0); }));
		reg(s, "Type", "enumConstructor", vfn(a -> switch (arg(a, 0)) {
			case VEnumValue(ev):
				var p = ctx.staticPrototypes.get(ev.epath);
				if (p == null) VNull else switch (p.pkind) { case PEnum(cs): mkStr(cs[ev.eindex].name); case _: VNull; };
			case _: VNull;
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
		reg(s, "Type", "resolveClass", vfn(a -> {
			var path = EvalHash.hash(stringOf(arg(a, 0)));
			var p = ctx.staticPrototypes.get(path);
			p == null ? (isCoreClassPath(path) ? coreClassValue(ctx, path) : VNull) : p.pvalue;
		}));
		reg(s, "Type", "resolveEnum", vfn(a -> {
			var p = ctx.staticPrototypes.get(EvalHash.hash(stringOf(arg(a, 0))));
			if (p == null) VNull else switch (p.pkind) { case PEnum(_): p.pvalue; case _: VNull; };
		}));
		reg(s, "Reflect", "callMethod", vfn(a -> {
			var fn = arg(a, 1); var args = argList(arg(a, 2));
			if (fn == VNull) EvalExceptions.excString(ctx, "Cannot call null") else callValueOn(arg(a, 0), fn, args);
		}));
		reg(s, "Lambda", "array", vfn(a -> valueArray(iterableValues(ctx, arg(a, 0)))));
		reg(s, "Lambda", "list", vfn(a -> {
			listValue(ctx, iterableValues(ctx, arg(a, 0)));
		}));
		reg(s, "Lambda", "map", vfn(a -> valueArray([for (v in iterableValues(ctx, arg(a, 0))) applyFn(arg(a, 1), [v])])));
		reg(s, "Lambda", "mapi", vfn(a -> {
			var i = 0;
			valueArray([for (v in iterableValues(ctx, arg(a, 0))) applyFn(arg(a, 1), [VInt(i++), v])]);
		}));
		reg(s, "Lambda", "flatten", vfn(a -> {
			var out:Array<EvalValue> = [];
			for (it in iterableValues(ctx, arg(a, 0))) out = out.concat(iterableValues(ctx, it));
			valueArray(out);
		}));
		reg(s, "Lambda", "flatMap", vfn(a -> {
			var out:Array<EvalValue> = [];
			for (v in iterableValues(ctx, arg(a, 0))) out = out.concat(iterableValues(ctx, applyFn(arg(a, 1), [v])));
			valueArray(out);
		}));
		reg(s, "Lambda", "has", vfn(a -> {
			for (v in iterableValues(ctx, arg(a, 0))) if (EvalMisc.isTrue(EvalMisc.opEq(v, arg(a, 1)))) return VTrue;
			VFalse;
		}));
		reg(s, "Lambda", "exists", vfn(a -> {
			for (v in iterableValues(ctx, arg(a, 0))) if (EvalMisc.isTrue(applyFn(arg(a, 1), [v]))) return VTrue;
			VFalse;
		}));
		reg(s, "Lambda", "foreach", vfn(a -> {
			for (v in iterableValues(ctx, arg(a, 0))) if (!EvalMisc.isTrue(applyFn(arg(a, 1), [v]))) return VFalse;
			VTrue;
		}));
		reg(s, "Lambda", "iter", vfn(a -> {
			for (v in iterableValues(ctx, arg(a, 0))) applyFn(arg(a, 1), [v]);
			VNull;
		}));
		reg(s, "Lambda", "filter", vfn(a -> valueArray([for (v in iterableValues(ctx, arg(a, 0))) if (EvalMisc.isTrue(applyFn(arg(a, 1), [v]))) v])));
		reg(s, "Lambda", "fold", vfn(a -> {
			var acc = arg(a, 2);
			for (v in iterableValues(ctx, arg(a, 0))) acc = applyFn(arg(a, 1), [v, acc]);
			acc;
		}));
		reg(s, "Lambda", "foldi", vfn(a -> {
			var acc = arg(a, 2);
			var i = 0;
			for (v in iterableValues(ctx, arg(a, 0))) acc = applyFn(arg(a, 1), [v, acc, VInt(i++)]);
			acc;
		}));
		reg(s, "Lambda", "count", vfn(a -> {
			var n = 0;
			var pred = arg(a, 1);
			for (v in iterableValues(ctx, arg(a, 0))) if (pred == VNull || EvalMisc.isTrue(applyFn(pred, [v]))) n++;
			VInt(n);
		}));
		reg(s, "Lambda", "empty", vfn(a -> EvalValueTools.vbool(iterableValues(ctx, arg(a, 0)).length == 0)));
		reg(s, "Lambda", "indexOf", vfn(a -> {
			var i = 0;
			for (v in iterableValues(ctx, arg(a, 0))) {
				if (EvalMisc.isTrue(EvalMisc.opEq(v, arg(a, 1)))) return VInt(i);
				i++;
			}
			VInt(-1);
		}));
		reg(s, "Lambda", "find", vfn(a -> {
			for (v in iterableValues(ctx, arg(a, 0))) if (EvalMisc.isTrue(applyFn(arg(a, 1), [v]))) return v;
			VNull;
		}));
		reg(s, "Lambda", "findIndex", vfn(a -> {
			var i = 0;
			for (v in iterableValues(ctx, arg(a, 0))) {
				if (EvalMisc.isTrue(applyFn(arg(a, 1), [v]))) return VInt(i);
				i++;
			}
			VInt(-1);
		}));
		reg(s, "Lambda", "concat", vfn(a -> valueArray(iterableValues(ctx, arg(a, 0)).concat(iterableValues(ctx, arg(a, 1))))));

		var ctors = ctx.builtins.constructorBuiltins;
		var emptyCtors = ctx.builtins.emptyConstructorBuiltins;
		ctors.set(EvalHash.hash("String"), function(a) return arg(a, 0));
		emptyCtors.set(EvalHash.hash("String"), function() return mkStr(""));
		ctors.set(EvalHash.hash("StringBuf"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("StringBuf"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IBuffer(new StringBuf())));
		});
		ctors.set(EvalHash.hash("haxe.Utf8"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.Utf8"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IBuffer(new StringBuf())));
		});
		ctors.set(EvalHash.hash("EReg"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("EReg"));
			var pattern = stringOf(arg(a, 0));
			var flags = stringOf(arg(a, 1));
			validateRegexFlags(flags);
			var re = new EReg(pattern, flags);
			nativeRegexInfo.set(re, {captureCount: countRegexCaptures(pattern), global: flags.indexOf("g") >= 0, lastSubject: null, matched: false});
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IRegex(re)));
		});
		emptyCtors.set(EvalHash.hash("EReg"), function() {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("EReg"));
			var re = new EReg("", "");
			nativeRegexInfo.set(re, {captureCount: 0, global: false, lastSubject: null, matched: false});
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IRegex(re)));
		});

		reg(inst, "StringBuf", "add", vmethod(a -> {
			thisBuffer(a).add(stringOf(arg(a, 1)));
			VNull;
		}));
		reg(inst, "StringBuf", "addChar", vmethod(a -> {
			thisBuffer(a).add(stringFromCodes([toInt(arg(a, 1))], 0, 1));
			VNull;
		}));
		reg(inst, "StringBuf", "addSub", vmethod(a -> {
			var s = stringOf(arg(a, 1));
			var pos = toInt(arg(a, 2));
			var len = arg(a, 3) == VNull ? stringLength(s) - pos : toInt(arg(a, 3));
			if (len > 0) thisBuffer(a).add(stringFromCodes(utf8Codes(s), pos, len));
			VNull;
		}));
		reg(inst, "StringBuf", "toString", vmethod(a -> mkStr(thisBuffer(a).toString())));
		// Length is a (get, never) property whose default getter reads the std's internal buffer; the
		// native instance keeps its own buffer, so the accessor resolves through the host length.
		reg(inst, "StringBuf", "get_length", vmethod(a -> VInt(thisBuffer(a).length)));

		reg(s, "haxe.Utf8", "charCodeAt", vfn(a -> {
			var codes = utf8Codes(stringOf(arg(a, 0)));
			var index = toInt(arg(a, 1));
			index >= 0 && index < codes.length ? VInt(codes[index]) : VNull;
		}));
		reg(s, "haxe.Utf8", "compare", vfn(a -> VInt(Reflect.compare(stringOf(arg(a, 0)), stringOf(arg(a, 1))))));
		reg(s, "haxe.Utf8", "decode", vfn(a -> mkStr(utf8Decode(stringOf(arg(a, 0))))));
		reg(s, "haxe.Utf8", "encode", vfn(a -> {
			var s = stringOf(arg(a, 0));
			VString(new VString(utf8Encode(s), utf8EncodedLength(s)));
		}));
		reg(s, "haxe.Utf8", "iter", vfn(a -> {
			var fn = arg(a, 1);
			for (c in utf8Codes(stringOf(arg(a, 0)))) applyFn(fn, [VInt(c)]);
			VNull;
		}));
		reg(s, "haxe.Utf8", "length", vfn(a -> VInt(utf8Codes(stringOf(arg(a, 0))).length)));
		reg(s, "haxe.Utf8", "sub", vfn(a -> {
			var codes = utf8Codes(stringOf(arg(a, 0)));
			var pos = toInt(arg(a, 1));
			var len = toInt(arg(a, 2));
			var buf = new StringBuf();
			for (i in pos...Std.int(Math.min(pos + len, codes.length))) addUtf8Char(buf, codes[i]);
			mkStrLen(buf.toString(), Std.int(Math.min(len, Math.max(0, codes.length - pos))));
		}));
		reg(s, "haxe.Utf8", "validate", vfn(a -> EvalValueTools.vbool(utf8Valid(stringOf(arg(a, 0))))));
		reg(inst, "haxe.Utf8", "addChar", vmethod(a -> { addUtf8Char(thisBuffer(a), toInt(arg(a, 1))); VNull; }));
		reg(inst, "haxe.Utf8", "toString", vmethod(a -> {
			var s = thisBuffer(a).toString();
			mkStrLen(s, haxe.io.Bytes.ofString(s).length);
		}));

		reg(inst, "EReg", "match", vmethod(a -> {
			var s = stringOf(arg(a, 1));
			EvalValueTools.vbool(regexMatch(thisRegex(a), s));
		}));
		reg(inst, "EReg", "matched", vmethod(a -> try {
			var re = thisRegex(a);
			regexEnsureMatched(re);
			mkNullStr(re.matched(toInt(arg(a, 1))));
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
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
		reg(inst, "EReg", "matchSub", vmethod(a -> {
			var len = a.length > 3 && arg(a, 3) != VNull ? toInt(arg(a, 3)) : -1;
			EvalValueTools.vbool(regexMatchSub(thisRegex(a), stringOf(arg(a, 1)), toInt(arg(a, 2)), len));
		}));
		reg(inst, "EReg", "split", vmethod(a -> {
			var re = thisRegex(a);
			var s = stringOf(arg(a, 1));
			var info = regexInfo(re);
			if (info != null) info.lastSubject = s;
			var parts = regexSplit(re, s);
			VArray(new VArray([for (p in parts) mkStr(p)], parts.length));
		}));
		reg(inst, "EReg", "replace", vmethod(a -> {
			var re = thisRegex(a);
			var info = regexInfo(re);
			var by = stringOf(arg(a, 2));
			var s = stringOf(arg(a, 1));
			if (info != null) info.lastSubject = s;
			mkStr(regexReplace(re, s, by));
		}));
		reg(inst, "EReg", "map", vmethod(a -> {
			var recv = arg(a, 0);
			var fn = arg(a, 2);
			var re = thisRegex(a);
			var s = stringOf(arg(a, 1));
			var info = regexInfo(re);
			if (info != null) info.lastSubject = s;
			mkStr(re.map(s, function(_) {
				if (info != null) info.matched = true;
				return stringOf(callValueOn(recv, fn, [recv]));
			}));
		}));
		reg(s, "EReg", "escape", vfn(a -> mkStr(regexEscape(stringOf(arg(a, 0))))));

		reg(inst, "haxe.ds.List", "add", vmethod(a -> {
			var list = thisList(a);
			list.push(arg(a, 1));
			syncListFields(ctx, thisInstance(a, "List"));
			VNull;
		}));
		reg(inst, "haxe.ds.List", "push", vmethod(a -> {
			var list = thisList(a);
			list.unshift(arg(a, 1));
			syncListFields(ctx, thisInstance(a, "List"));
			VNull;
		}));
		reg(inst, "haxe.ds.List", "first", vmethod(a -> {
			var list = thisList(a);
			list.length == 0 ? VNull : list[0];
		}));
		reg(inst, "haxe.ds.List", "last", vmethod(a -> {
			var list = thisList(a);
			list.length == 0 ? VNull : list[list.length - 1];
		}));
		reg(inst, "haxe.ds.List", "pop", vmethod(a -> {
			var list = thisList(a);
			if (list.length == 0) return VNull;
			var v = list.shift();
			syncListFields(ctx, thisInstance(a, "List"));
			v;
		}));
		reg(inst, "haxe.ds.List", "isEmpty", vmethod(a -> EvalValueTools.vbool(thisList(a).length == 0)));
		reg(inst, "haxe.ds.List", "clear", vmethod(a -> {
			thisList(a).resize(0);
			syncListFields(ctx, thisInstance(a, "List"));
			VNull;
		}));
		reg(inst, "haxe.ds.List", "remove", vmethod(a -> {
			var list = thisList(a);
			var v = arg(a, 1);
			for (i in 0...list.length) {
				if (EvalMisc.isTrue(EvalMisc.opEq(list[i], v))) {
					list.splice(i, 1);
					syncListFields(ctx, thisInstance(a, "List"));
					return VTrue;
				}
			}
			VFalse;
		}));
		reg(inst, "haxe.ds.List", "iterator", vmethod(a -> objectIterator(thisList(a).copy())));
		reg(inst, "haxe.ds.List", "keyValueIterator", vmethod(a -> {
			var list = thisList(a);
			objectIterator([for (i in 0...list.length) mkObject([{name: "value", value: list[i]}, {name: "key", value: VInt(i)}])]);
		}));
		reg(inst, "haxe.ds.List", "toString", vmethod(a -> mkStr("{" + [for (v in thisList(a)) stringOf(v)].join(", ") + "}")));
		reg(inst, "haxe.ds.List", "join", vmethod(a -> mkStr([for (v in thisList(a)) stringOf(v)].join(stringOf(arg(a, 1))))));
		reg(inst, "haxe.ds.List", "filter", vmethod(a -> {
			var fn = arg(a, 1);
			listValue(ctx, [for (v in thisList(a)) if (EvalMisc.isTrue(applyFn(fn, [v]))) v]);
		}));
		reg(inst, "haxe.ds.List", "map", vmethod(a -> {
			var fn = arg(a, 1);
			listValue(ctx, [for (v in thisList(a)) applyFn(fn, [v])]);
		}));
		reg(inst, "haxe.Template", "execute", vmethod(a -> {
			var macros = arg(a, 2);
			var oldGlobals = haxe.Template.globals;
			haxe.Template.globals = templateGlobalsHost(ctx);
			try {
				var result = thisTemplate(a).execute(valueToHost(ctx, arg(a, 1)), macros == VNull ? null : valueToHost(ctx, macros));
				haxe.Template.globals = oldGlobals;
				mkStr(result);
			} catch (e:Dynamic) {
				haxe.Template.globals = oldGlobals;
				throw e;
			}
		}));
		reg(inst, "haxe.io.Path", "toString", vmethod(a -> mkStr(pathToString(ctx, arg(a, 0)))));

		// haxe.ds maps (StringMap/IntMap) backed by a native dictionary.
		function iteratorOf(items:Array<EvalValue>):EvalValue
			return arrayIteratorValue(ctx, VArray(new VArray(items, items.length)));
		reg(inst, "Xml", "get_nodeName", vmethod(a -> try mkStr(thisXml(a).nodeName) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "set_nodeName", vmethod(a -> {
			try {
				var x = thisXml(a);
				x.nodeName = stringOf(arg(a, 1));
				syncXmlFields(ctx, thisInstance(a, "Xml"), x);
				arg(a, 1);
			} catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "Xml", "get_nodeValue", vmethod(a -> try mkStr(thisXml(a).nodeValue) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "set_nodeValue", vmethod(a -> {
			try {
				var x = thisXml(a);
				x.nodeValue = stringOf(arg(a, 1));
				syncXmlFields(ctx, thisInstance(a, "Xml"), x);
				arg(a, 1);
			} catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "Xml", "get", vmethod(a -> {
			try {
				var v = thisXml(a).get(stringOf(arg(a, 1)));
				v == null ? VNull : mkStr(v);
			} catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "Xml", "set", vmethod(a -> try { thisXml(a).set(stringOf(arg(a, 1)), stringOf(arg(a, 2))); VNull; } catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "remove", vmethod(a -> try { thisXml(a).remove(stringOf(arg(a, 1))); VNull; } catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "exists", vmethod(a -> try EvalValueTools.vbool(thisXml(a).exists(stringOf(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "attributes", vmethod(a -> try iteratorOf([for (name in thisXml(a).attributes()) mkStr(name)]) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "iterator", vmethod(a -> try iteratorOf(xmlChildren(ctx, thisXml(a))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "elements", vmethod(a -> try iteratorOf(xmlChildren(ctx, thisXml(a), true)) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "elementsNamed", vmethod(a -> try iteratorOf(xmlChildren(ctx, thisXml(a), true, stringOf(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "Xml", "firstChild", vmethod(a -> {
			try {
				var x = thisXml(a).firstChild();
				x == null ? VNull : xmlValue(ctx, x);
			} catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "Xml", "firstElement", vmethod(a -> {
			try {
				var x = thisXml(a).firstElement();
				x == null ? VNull : xmlValue(ctx, x);
			} catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "Xml", "addChild", vmethod(a -> {
			try {
				var parent = thisXml(a);
				var child = thisXml([arg(a, 1)]);
				parent.addChild(child);
				syncXmlFields(ctx, thisInstance(a, "Xml"), parent);
				syncXmlFields(ctx, thisInstance([arg(a, 1)], "Xml"), child);
				VNull;
			} catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "Xml", "removeChild", vmethod(a -> {
			try {
				var parent = thisXml(a);
				var child = thisXml([arg(a, 1)]);
				parent.removeChild(child);
				syncXmlFields(ctx, thisInstance(a, "Xml"), parent);
				syncXmlFields(ctx, thisInstance([arg(a, 1)], "Xml"), child);
				VNull;
			} catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "Xml", "insertChild", vmethod(a -> {
			try {
				var parent = thisXml(a);
				var child = thisXml([arg(a, 1)]);
				parent.insertChild(child, toInt(arg(a, 2)));
				syncXmlFields(ctx, thisInstance(a, "Xml"), parent);
				syncXmlFields(ctx, thisInstance([arg(a, 1)], "Xml"), child);
				VNull;
			} catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "Xml", "toString", vmethod(a -> mkStr(thisXml(a).toString())));
		for (mapPath in ["haxe.ds.StringMap", "haxe.ds.IntMap", "haxe.ds.EnumValueMap", "haxe.ds.ObjectMap"]) {
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
				var vi = thisInstance(a, mapPath);
				var m = thisMap(a);
				var k = mapKey(arg(a, 1));
				if (!m.exists(k)) {
					var order = nativeMapOrders.get(vi);
					if (order == null) {
						order = [for (key in m.keys()) key];
						nativeMapOrders.set(vi, order);
					}
					order.push(k);
				}
				m.set(k, {key: arg(a, 1), value: arg(a, 2)});
				VNull;
			}));
			reg(inst, mapPath, "get", vmethod(a -> { var m = thisMap(a); var k = mapKey(arg(a, 1)); m.exists(k) ? m.get(k).value : VNull; }));
			reg(inst, mapPath, "exists", vmethod(a -> EvalValueTools.vbool(thisMap(a).exists(mapKey(arg(a, 1))))));
			reg(inst, mapPath, "remove", vmethod(a -> {
				var vi = thisInstance(a, mapPath);
				var m = thisMap(a);
				var k = mapKey(arg(a, 1));
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
			reg(inst, mapPath, "copy", vmethod(a -> {
				var proto = ctx.instancePrototypes.get(EvalHash.hash(mapPath));
				var nm = new Map();
				var order = [];
				for (e in orderedMapEntries(arg(a, 0))) {
					var k = mapKey(e.key);
					nm.set(k, e);
					order.push(k);
				}
				var vi = new VInstance(proto.pinstanceFields.copy(), proto, IMap(nm));
				nativeMapOrders.set(vi, order);
				VInstance(vi);
			}));
			reg(inst, mapPath, "toString", vmethod(a -> mkStr(mapToString(thisMap(a)))));
		}
		reg(inst, "haxe.ds.IntMap", "toString", vmethod(a -> mkStr(mapToString(thisMap(a)))));

		// New Array() builds an empty dynamic array, matching the [] literal.
		ctors.set(EvalHash.hash("Array"), function(a) return VArray(new VArray([], 0)));
		emptyCtors.set(EvalHash.hash("Array"), function() return VArray(new VArray([], 0)));
		ctors.set(EvalHash.hash("haxe.iterators.ArrayIterator"), function(a) return arrayIteratorValue(ctx, arg(a, 0)));
		ctors.set(EvalHash.hash("haxe.iterators.MapKeyValueIterator"), function(a) return mapKeyValueIteratorValue(ctx, arg(a, 0)));
		ctors.set(EvalHash.hash("eval.Vector"), function(a) return VVector([for (_ in 0...toInt(arg(a, 0))) VNull]));
		emptyCtors.set(EvalHash.hash("eval.Vector"), function() return VVector([]));
		ctors.set(EvalHash.hash("haxe.ds.List"), function(a) return mkList(ctx));
		ctors.set(EvalHash.hash("haxe.crypto.Hmac"), function(a) return mkHmac(ctx, arg(a, 0)));
		ctors.set(EvalHash.hash("haxe.crypto.BaseCode"), function(a) return mkBaseCode(ctx, arg(a, 0)));
		ctors.set(EvalHash.hash("haxe.Template"), function(a) return mkTemplate(ctx, arg(a, 0)));
		ctors.set(EvalHash.hash("haxe.Timer"), function(a) return mkTimer(ctx, toInt(arg(a, 0))));
		ctors.set(EvalHash.hash("haxe.io.BytesBuffer"), function(a) return mkBytesBuffer(ctx));
		emptyCtors.set(EvalHash.hash("haxe.io.BytesBuffer"), function() return mkBytesBuffer(ctx));
		ctors.set(EvalHash.hash("haxe.io.Bytes"), function(a) {
			var length = toInt(arg(a, 0));
			var source = thisBytes([arg(a, 1)]);
			var bytes = haxe.io.Bytes.alloc(length);
			bytes.blit(0, source, 0, length > source.length ? source.length : length);
			return mkBytes(ctx, bytes);
		});
		ctors.set(EvalHash.hash("haxe.io.BytesOutput"), function(a) return mkBytesOutput(ctx));
		ctors.set(EvalHash.hash("haxe.io.BytesInput"), function(a) return mkBytesInput(ctx, arg(a, 0), arg(a, 1), arg(a, 2)));

		// Date: a native instance carrying its epoch timestamp.
		ctors.set(EvalHash.hash("Date"), function(a) {
			var d = new Date(toInt(arg(a, 0)), toInt(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3)), toInt(arg(a, 4)), toInt(arg(a, 5)));
			return mkDate(ctx, d.getTime());
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
		ctors.set(EvalHash.hash("sys.thread.EventLoop"), function(a) return mkThreadEventLoop(ctx));
		ctors.set(EvalHash.hash("eval.vm.NativeThread"), function(a) return mkNativeThread(ctx, arg(a, 0)));
		reg(s, "Date", "now", vfn(a -> mkDate(ctx, Date.now().getTime())));
		reg(s, "Date", "fromTime", vfn(a -> mkDate(ctx, toFloat(arg(a, 0)))));
		reg(s, "Date", "fromString", vfn(a -> dateFromString(ctx, stringOf(arg(a, 0)))));
		reg(s, "DateTools", "format", vfn(a -> mkStr(dateToolsFormat(Date.fromTime(thisDate([arg(a, 0)])), stringOf(arg(a, 1))))));
		reg(s, "haxe.io.Path", "withoutExtension", vfn(a -> mkStr(haxe.io.Path.withoutExtension(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Path", "withoutDirectory", vfn(a -> mkStr(haxe.io.Path.withoutDirectory(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Path", "directory", vfn(a -> mkStr(haxe.io.Path.directory(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Path", "extension", vfn(a -> mkStr(haxe.io.Path.extension(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Path", "withExtension", vfn(a -> mkStr(haxe.io.Path.withExtension(stringOf(arg(a, 0)), stringOf(arg(a, 1))))));
		reg(s, "haxe.io.Path", "join", vfn(a -> mkStr(haxe.io.Path.join(stringArray(arg(a, 0))))));
		reg(s, "haxe.io.Path", "normalize", vfn(a -> mkStr(haxe.io.Path.normalize(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Path", "addTrailingSlash", vfn(a -> mkStr(haxe.io.Path.addTrailingSlash(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Path", "removeTrailingSlashes", vfn(a -> mkStr(haxe.io.Path.removeTrailingSlashes(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Path", "isAbsolute", vfn(a -> EvalValueTools.vbool(haxe.io.Path.isAbsolute(stringOf(arg(a, 0))))));
		reg(s, "haxe.Json", "parse", vfn(a -> jsonToValue(ctx, haxe.Json.parse(stringOf(arg(a, 0))))));
		reg(s, "haxe.Json", "stringify", vfn(a -> mkStr(jsonPrintValue(arg(a, 0), arg(a, 2) == VNull ? null : stringOf(arg(a, 2))))));
		reg(s, "haxe.format.JsonParser", "parse", vfn(a -> jsonToValue(ctx, haxe.Json.parse(stringOf(arg(a, 0))))));
		reg(s, "haxe.format.JsonPrinter", "print", vfn(a -> mkStr(jsonPrintValue(arg(a, 0), arg(a, 2) == VNull ? null : stringOf(arg(a, 2))))));
		reg(s, "haxe.Serializer", "run", vfn(a -> {
			var serializer = classValue(ctx, EvalHash.hash("haxe.Serializer"));
			mkStr(serializeEval(ctx, arg(a, 0), serializerBoolField(ctx, serializer, "USE_ENUM_INDEX", false), serializerBoolField(ctx, serializer, "USE_CACHE", false)));
		}));
		reg(inst, "haxe.Serializer", "serialize", vmethod(a -> serializerAppend(ctx, arg(a, 0), arg(a, 1))));
		reg(inst, "haxe.Serializer", "serializeException", vmethod(a -> serializerAppend(ctx, arg(a, 0), arg(a, 1))));
		reg(inst, "haxe.Serializer", "toString", vmethod(a -> serializerToString(ctx, arg(a, 0))));
		reg(s, "haxe.Unserializer", "run", vfn(a -> {
			var data = arg(a, 0);
			if (data == VNull) EvalExceptions.excString(ctx, "field access on null");
			unserializeString(ctx, stringOf(data));
		}));
		reg(inst, "haxe.Unserializer", "unserialize", vmethod(a -> {
			var self = arg(a, 0);
			var data = stringOf(EvalField.field(ctx, self, EvalHash.hash("buf")));
			setDynamicField(self, EvalHash.hash("pos"), VInt(data.length));
			unserializeString(ctx, data);
		}));

		// sys.FileSystem / sys.io.File: macros read the source tree at compile time; the interpreter
		// host has real filesystem access.
		reg(s, "sys.FileSystem", "exists", vfn(a -> sys.FileSystem.exists(stringOf(arg(a, 0))) ? VTrue : VFalse));
		reg(s, "sys.FileSystem", "isDirectory", vfn(a -> sys.FileSystem.isDirectory(stringOf(arg(a, 0))) ? VTrue : VFalse));
		reg(s, "sys.FileSystem", "readDirectory", vfn(a -> {
			var d = sys.FileSystem.readDirectory(stringOf(arg(a, 0)));
			VArray(new VArray([for (f in d) mkStr(f)], d.length));
		}));
		reg(s, "sys.FileSystem", "createDirectory", vfn(a -> { sys.FileSystem.createDirectory(stringOf(arg(a, 0))); VNull; }));
		reg(s, "sys.FileSystem", "deleteDirectory", vfn(a -> { sys.FileSystem.deleteDirectory(stringOf(arg(a, 0))); VNull; }));
		reg(s, "sys.FileSystem", "deleteFile", vfn(a -> { sys.FileSystem.deleteFile(stringOf(arg(a, 0))); VNull; }));
		reg(s, "sys.FileSystem", "fullPath", vfn(a -> mkStr(sys.FileSystem.fullPath(stringOf(arg(a, 0))))));
		reg(s, "sys.FileSystem", "absolutePath", vfn(a -> mkStr(sys.FileSystem.absolutePath(stringOf(arg(a, 0))))));
		reg(s, "sys.FileSystem", "rename", vfn(a -> { sys.FileSystem.rename(stringOf(arg(a, 0)), stringOf(arg(a, 1))); VNull; }));
		reg(s, "sys.FileSystem", "stat", vfn(a -> mkFileStat(ctx, sys.FileSystem.stat(stringOf(arg(a, 0))))));
		reg(s, "sys.net.Host", "localhost", vfn(a -> mkStr(sys.net.Host.localhost())));
		reg(s, "sys.net.Host", "resolve", vfn(a -> VInt(hostIpInt(stringOf(arg(a, 0))))));
		reg(s, "sys.net.Host", "hostToString", vfn(a -> mkStr(new sys.net.Host(hostIpString(toInt(arg(a, 0)))).toString())));
		reg(s, "sys.net.Host", "hostReverse", vfn(a -> mkStr(new sys.net.Host(hostIpString(toInt(arg(a, 0)))).reverse())));
		reg(s, "sys.io.File", "append", vfn(a -> mkFileOutput(ctx, sys.io.File.append(stringOf(arg(a, 0)), arg(a, 1) != VFalse))));
		reg(s, "sys.io.File", "getBytes", vfn(a -> mkBytes(ctx, sys.io.File.getBytes(stringOf(arg(a, 0))))));
		reg(s, "sys.io.File", "getContent", vfn(a -> mkStr(sys.io.File.getContent(stringOf(arg(a, 0))))));
		reg(s, "sys.io.File", "read", vfn(a -> mkFileInput(ctx, sys.io.File.read(stringOf(arg(a, 0)), arg(a, 1) != VFalse))));
		reg(s, "sys.io.File", "saveBytes", vfn(a -> { sys.io.File.saveBytes(stringOf(arg(a, 0)), thisBytes([arg(a, 1)])); VNull; }));
		reg(s, "sys.io.File", "saveContent", vfn(a -> { sys.io.File.saveContent(stringOf(arg(a, 0)), stringOf(arg(a, 1))); VNull; }));
		reg(s, "sys.io.File", "update", vfn(a -> mkFileOutput(ctx, sys.io.File.update(stringOf(arg(a, 0)), arg(a, 1) != VFalse))));
		reg(s, "sys.io.File", "write", vfn(a -> mkFileOutput(ctx, sys.io.File.write(stringOf(arg(a, 0)), arg(a, 1) != VFalse))));
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
			var n = try ch.input.readBytes(thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3))) catch (_:Dynamic) {
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
		reg(inst, "sys.io.FileOutput", "writeBytes", vmethod(a -> VInt(thisFileOutput(a).output.writeBytes(
			thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3))))));
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
			try VInt(thisProcess(a).stderr.readBytes(thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3)))) catch (_:Dynamic) {
				EvalExceptions.excString(ctx, "Could not read stderr");
			}
		}));
		reg(inst, "sys.io._Process.NativeProcess", "readStdout", vmethod(a -> {
			try VInt(thisProcess(a).stdout.readBytes(thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3)))) catch (_:Dynamic) {
				EvalExceptions.excString(ctx, "Could not read stdout");
			}
		}));
		reg(inst, "sys.io._Process.NativeProcess", "closeStdin", vmethod(a -> { thisProcess(a).stdin.close(); VNull; }));
		reg(inst, "sys.io._Process.NativeProcess", "writeStdin", vmethod(a -> VInt(thisProcess(a).stdin.writeBytes(
			thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3))))));
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
				mutex.mutex.acquire();
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
		reg(inst, "sys.thread.Lock", "wait", vmethod(a -> EvalValueTools.vbool(
			arg(a, 1) == VNull ? thisThreadLock(a).wait() : thisThreadLock(a).wait(toFloat(arg(a, 1))))));
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
			var v = thisThreadDeque(a).pop(arg(a, 1) == VTrue);
			v == null ? VNull : v;
		}));
		reg(inst, "haxe.Timer", "stop", vmethod(a -> { stopTimer(a); VNull; }));
		reg(inst, "sys.thread.EventLoop", "repeat", vmethod(a -> {
			var fn = arg(a, 1);
			eventHandlerValue(evalLoopRepeat(thisThreadEventLoop(a), function() applyFn(fn, []), toInt(arg(a, 2))));
		}));
		reg(inst, "sys.thread.EventLoop", "cancel", vmethod(a -> {
			var handler = eventHandlerOf(arg(a, 1));
			if (handler != null) evalLoopCancel(cast handler);
			VNull;
		}));
		reg(inst, "sys.thread.EventLoop", "promise", vmethod(a -> { evalLoopPromise(thisThreadEventLoop(a)); VNull; }));
		reg(inst, "sys.thread.EventLoop", "run", vmethod(a -> {
			var fn = arg(a, 1);
			thisThreadEventLoop(a).pending.push(function() applyFn(fn, []));
			VNull;
		}));
		reg(inst, "sys.thread.EventLoop", "runPromised", vmethod(a -> {
			var fn = arg(a, 1);
			evalLoopRunPromised(thisThreadEventLoop(a), function() applyFn(fn, []));
			VNull;
		}));
		reg(inst, "sys.thread.EventLoop", "progress", vmethod(a -> evalLoopProgress(ctx, thisThreadEventLoop(a))));
		reg(inst, "sys.thread.EventLoop", "wait", vmethod(a -> EvalValueTools.vbool(
			arg(a, 1) == VNull ? evalLoopWait(thisThreadEventLoop(a)) : evalLoopWait(thisThreadEventLoop(a), toFloat(arg(a, 1))))));
		reg(inst, "sys.thread.EventLoop", "loop", vmethod(a -> { evalLoopDrain(ctx, thisThreadEventLoop(a), null); VNull; }));
		reg(inst, "sys.thread.Condition", "acquire", vmethod(a -> {
			var cond = thisThreadCondition(a);
			var thread = sys.thread.Thread.current();
			if (cond.owner != null && cond.owner == thread) {
				cond.count++;
			} else {
				cond.cond.acquire();
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
			cond.cond.wait();
			cond.owner = thread;
			cond.count = count;
			VNull;
		}));
		reg(inst, "sys.thread.Condition", "signal", vmethod(a -> { thisThreadCondition(a).cond.signal(); VNull; }));
		reg(inst, "sys.thread.Condition", "broadcast", vmethod(a -> { thisThreadCondition(a).cond.broadcast(); VNull; }));
		reg(inst, "sys.thread.Semaphore", "acquire", vmethod(a -> { thisThreadSemaphore(a).acquire(); VNull; }));
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
					var v = nativeThreads.get(vi).messages.pop(arg(a, 0) == VTrue);
					v == null ? VNull : v;
				case _: VNull;
			}
		}));
		reg(s, "sys.thread._Thread.Thread_Impl_", "get_events", vfn(a -> {
			return switch (arg(a, 0)) {
				case VInstance(vi): nativeThreadEventLoop(ctx, vi);
				case _: VNull;
			}
		}));
		reg(s, "sys.thread._Thread.Thread_Impl_", "processEvents", vfn(a -> {
			switch (nativeThreadSelfValue(ctx)) {
				case VInstance(vi):
					var events = nativeThreadEventLoop(ctx, vi);
					applyFn(EvalField.dynamicField(ctx, events, EvalHash.hash("loop")), []);
				case _:
			}
			VNull;
		}));
		reg(inst, "eval.vm.NativeThread", "id", vmethod(a -> VInt(nativeThreadData(a).id)));
		reg(inst, "eval.vm.NativeThread", "kill", vmethod(a -> throw "Field index for kill not found on prototype eval.vm.NativeThread"));
		reg(inst, "eval.vm.NativeThread", "sendMessage", vmethod(a -> { nativeThreadData(a).messages.add(arg(a, 1)); VNull; }));
		reg(inst, "eval.vm.NativeThread", "get_events", vmethod(a -> nativeThreadEventLoop(ctx, thisInstance(a, "NativeThread"))));
		reg(inst, "eval.vm.NativeThread", "set_events", vmethod(a -> {
			var events = arg(a, 1);
			nativeThreadData(a).events = events;
			setInstanceFieldIfExists(thisInstance(a, "NativeThread"), "events", events);
			arg(a, 1);
		}));
		reg(s, "eval._NativeString.NativeString_Impl_", "fromBytes", vfn(a -> {
			var b = thisBytes([arg(a, 0)]);
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
		reg(inst, "Date", "getFullYear", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getFullYear())));
		reg(inst, "Date", "getMonth", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getMonth())));
		reg(inst, "Date", "getDate", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getDate())));
		reg(inst, "Date", "getHours", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getHours())));
		reg(inst, "Date", "getMinutes", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getMinutes())));
		reg(inst, "Date", "getSeconds", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getSeconds())));
		reg(inst, "Date", "getDay", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getDay())));
		reg(inst, "Date", "getUTCFullYear", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getUTCFullYear())));
		reg(inst, "Date", "getUTCMonth", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getUTCMonth())));
		reg(inst, "Date", "getUTCDate", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getUTCDate())));
		reg(inst, "Date", "getUTCHours", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getUTCHours())));
		reg(inst, "Date", "getUTCMinutes", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getUTCMinutes())));
		reg(inst, "Date", "getUTCSeconds", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getUTCSeconds())));
		reg(inst, "Date", "getUTCDay", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getUTCDay())));
		reg(inst, "Date", "getTimezoneOffset", vmethod(a -> VInt(Date.fromTime(thisDate(a)).getTimezoneOffset())));
		reg(inst, "Date", "toString", vmethod(a -> mkStr(Date.fromTime(thisDate(a)).toString())));

		// haxe.io.Bytes: a native instance wrapping a host byte buffer.
		reg(s, "haxe.io.Bytes", "alloc", vfn(a -> mkBytes(ctx, haxe.io.Bytes.alloc(toInt(arg(a, 0))))));
		reg(s, "haxe.io.Bytes", "ofString", vfn(a -> mkBytes(ctx, bytesOfStringValue(arg(a, 0)))));
		reg(s, "haxe.io.Bytes", "ofHex", vfn(a -> mkBytes(ctx, haxe.io.Bytes.ofHex(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Bytes", "ofData", vfn(a -> arg(a, 0)));
		reg(s, "haxe.io.Bytes", "fastGet", vfn(a -> try VInt(thisBytes([arg(a, 0)]).get(toInt(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(s, "haxe.crypto.Crc32", "make", vfn(a -> VInt(haxe.crypto.Crc32.make(thisBytes([arg(a, 0)])))));
		reg(s, "haxe.crypto.Adler32", "make", vfn(a -> VInt(haxe.crypto.Adler32.make(thisBytes([arg(a, 0)])))));
		reg(s, "haxe.crypto.Base64", "encode", vfn(a -> mkStr(haxe.crypto.Base64.encode(thisBytes([arg(a, 0)]), arg(a, 1) == VNull || arg(a, 1) == VTrue))));
		reg(s, "haxe.crypto.Base64", "decode", vfn(a -> try mkBytes(ctx, haxe.crypto.Base64.decode(stringOf(arg(a, 0)), arg(a, 1) == VNull || arg(a, 1) == VTrue)) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(s, "haxe.crypto.Base64", "urlEncode", vfn(a -> mkStr(haxe.crypto.Base64.urlEncode(thisBytes([arg(a, 0)]), arg(a, 1) == VTrue))));
		reg(s, "haxe.crypto.Base64", "urlDecode", vfn(a -> try mkBytes(ctx, haxe.crypto.Base64.urlDecode(stringOf(arg(a, 0)), arg(a, 1) == VTrue)) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(s, "haxe.crypto.Md5", "encode", vfn(a -> mkStr(haxe.crypto.Md5.encode(stringOf(arg(a, 0))))));
		reg(s, "haxe.crypto.Md5", "make", vfn(a -> mkBytes(ctx, haxe.crypto.Md5.make(thisBytes([arg(a, 0)])))));
		reg(s, "haxe.crypto.Sha1", "encode", vfn(a -> mkStr(haxe.crypto.Sha1.encode(stringOf(arg(a, 0))))));
		reg(s, "haxe.crypto.Sha1", "make", vfn(a -> mkBytes(ctx, haxe.crypto.Sha1.make(thisBytes([arg(a, 0)])))));
		reg(s, "haxe.crypto.Sha224", "encode", vfn(a -> mkStr(haxe.crypto.Sha224.encode(stringOf(arg(a, 0))))));
		reg(s, "haxe.crypto.Sha224", "make", vfn(a -> mkBytes(ctx, haxe.crypto.Sha224.make(thisBytes([arg(a, 0)])))));
		reg(s, "haxe.crypto.Sha256", "encode", vfn(a -> mkStr(haxe.crypto.Sha256.encode(stringOf(arg(a, 0))))));
		reg(s, "haxe.crypto.Sha256", "make", vfn(a -> mkBytes(ctx, haxe.crypto.Sha256.make(thisBytes([arg(a, 0)])))));
		reg(s, "haxe.zip.Compress", "run",
			vfn(a -> mkBytes(ctx, haxe.zip.Compress.run(thisBytes([arg(a, 0)]), toInt(arg(a, 1))))));
		reg(s, "haxe.zip.Uncompress", "run",
			vfn(a -> mkBytes(ctx, haxe.zip.Uncompress.run(thisBytes([arg(a, 0)]), arg(a, 1) == VNull ? null : toInt(arg(a, 1))))));
		reg(s, "haxe.Resource", "listNames", vfn(a -> {
			var names = [for (name in ctx.resources.keys()) mkStr(name)];
			VArray(new VArray(names, names.length));
		}));
		reg(s, "haxe.Resource", "getString", vfn(a -> {
			var bytes = ctx.resources.get(stringOf(arg(a, 0)));
			bytes == null ? VNull : mkStr(bytes.toString());
		}));
		reg(s, "haxe.Resource", "getBytes", vfn(a -> {
			var bytes = ctx.resources.get(stringOf(arg(a, 0)));
			bytes == null ? VNull : mkBytes(ctx, bytes);
		}));
		reg(s, "haxe.io.FPHelper", "doubleToI64", vfn(a -> doubleBits(toFloat(arg(a, 0)))));
		reg(s, "haxe.io.FPHelper", "floatToI32", vfn(a -> VInt(floatBits(toFloat(arg(a, 0))))));
		reg(s, "haxe.io.FPHelper", "i32ToFloat", vfn(a -> VFloat(floatOfBits(toInt(arg(a, 0))))));
		reg(s, "haxe.io.FPHelper", "i64ToDouble", vfn(a -> VFloat(doubleOfBits(toInt(arg(a, 0)), toInt(arg(a, 1))))));
		reg(inst, "haxe.io.Bytes", "get", vmethod(a -> try VInt(thisBytes(a).get(toInt(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "set", vmethod(a -> try {
			thisBytes(a).set(toInt(arg(a, 1)), toInt(arg(a, 2)));
			VNull;
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "getData", vmethod(a -> arg(a, 0)));
		reg(inst, "haxe.io.Bytes", "getDouble", vmethod(a -> try VFloat(thisBytes(a).getDouble(toInt(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "getFloat", vmethod(a -> try VFloat(thisBytes(a).getFloat(toInt(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "getInt32", vmethod(a -> try VInt(thisBytes(a).getInt32(toInt(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "getInt64", vmethod(a -> try {
			var b = thisBytes(a);
			var pos = toInt(arg(a, 1));
			mkObject([
				{name: "low", value: VInt(b.getInt32(pos))},
				{name: "high", value: VInt(b.getInt32(pos + 4))}
			]);
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "getString", vmethod(a -> {
			var b = thisBytes(a);
			var pos = toInt(arg(a, 1));
			var len = toInt(arg(a, 2));
			if (pos < 0 || len < 0 || pos + len > b.length) ioError(ctx, "OutsideBounds");
			try mkStr(bytesString(b, pos, len)) catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "haxe.io.Bytes", "getUInt16", vmethod(a -> try VInt(thisBytes(a).getUInt16(toInt(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "toString", vmethod(a -> {
			var b = thisBytes(a);
			try mkStr(bytesStringStrict(b, 0, b.length)) catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		}));
		reg(inst, "haxe.io.Bytes", "toHex", vmethod(a -> mkStr(thisBytes(a).toHex())));
		reg(inst, "haxe.io.Bytes", "sub", vmethod(a -> {
			var b = thisBytes(a);
			var pos = toInt(arg(a, 1));
			var len = toInt(arg(a, 2));
			if (pos < 0 || len < 0 || pos + len > b.length) ioError(ctx, "OutsideBounds");
			mkBytes(ctx, b.sub(pos, len));
		}));
		reg(inst, "haxe.io.Bytes", "fill", vmethod(a -> try {
			thisBytes(a).fill(toInt(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3)));
			VNull;
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "blit", vmethod(a -> try {
			thisBytes(a).blit(toInt(arg(a, 1)), thisBytes([arg(a, 2)]), toInt(arg(a, 3)), toInt(arg(a, 4)));
			VNull;
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "compare", vmethod(a -> VInt(thisBytes(a).compare(thisBytes([arg(a, 1)])))));
		reg(inst, "haxe.io.Bytes", "setDouble", vmethod(a -> try {
			thisBytes(a).setDouble(toInt(arg(a, 1)), toFloat(arg(a, 2)));
			VNull;
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "setFloat", vmethod(a -> try {
			thisBytes(a).setFloat(toInt(arg(a, 1)), toFloat(arg(a, 2)));
			VNull;
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "setInt32", vmethod(a -> try {
			thisBytes(a).setInt32(toInt(arg(a, 1)), toInt(arg(a, 2)));
			VNull;
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "setInt64", vmethod(a -> try {
			var b = thisBytes(a);
			var pos = toInt(arg(a, 1));
			var v = arg(a, 2);
			b.setInt32(pos, int64Part(ctx, v, EvalHash.keyLow));
			b.setInt32(pos + 4, int64Part(ctx, v, EvalHash.keyHigh));
			VNull;
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.Bytes", "setUInt16", vmethod(a -> try {
			thisBytes(a).setUInt16(toInt(arg(a, 1)), toInt(arg(a, 2)));
			VNull;
		} catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.io.BytesBuffer", "get_length", vmethod(a -> VInt(bytesBufferLength(thisMap(a)))));
		reg(inst, "haxe.io.BytesBuffer", "addByte", vmethod(a -> { bytesBufferAddByte(thisMap(a), toInt(arg(a, 1))); VNull; }));
		reg(inst, "haxe.io.BytesBuffer", "add", vmethod(a -> { var b = thisBytes([arg(a, 1)]); bytesBufferAddBytes(thisMap(a), b, 0, b.length); VNull; }));
		reg(inst, "haxe.io.BytesBuffer", "addString", vmethod(a -> { var b = haxe.io.Bytes.ofString(stringOf(arg(a, 1))); bytesBufferAddBytes(thisMap(a), b, 0, b.length); VNull; }));
		reg(inst, "haxe.io.BytesBuffer", "addInt32", vmethod(a -> {
			var v = toInt(arg(a, 1));
			var buf = thisMap(a);
			bytesBufferAddByte(buf, v);
			bytesBufferAddByte(buf, v >> 8);
			bytesBufferAddByte(buf, v >> 16);
			bytesBufferAddByte(buf, v >>> 24);
			VNull;
		}));
		reg(inst, "haxe.io.BytesBuffer", "addInt64", vmethod(a -> {
			var v = arg(a, 1);
			var low = int64Part(ctx, v, EvalHash.keyLow);
			var high = int64Part(ctx, v, EvalHash.keyHigh);
			var buf = thisMap(a);
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
		reg(inst, "haxe.io.BytesBuffer", "addFloat", vmethod(a -> { var b = bytesOfFloat(toFloat(arg(a, 1))); bytesBufferAddBytes(thisMap(a), b, 0, b.length); VNull; }));
		reg(inst, "haxe.io.BytesBuffer", "addDouble", vmethod(a -> { var b = bytesOfDouble(toFloat(arg(a, 1))); bytesBufferAddBytes(thisMap(a), b, 0, b.length); VNull; }));
		reg(inst, "haxe.io.BytesBuffer", "addBytes", vmethod(a -> { bytesBufferAddBytes(thisMap(a), thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3))); VNull; }));
		reg(inst, "haxe.io.BytesBuffer", "getBytes", vmethod(a -> mkBytes(ctx, bytesBufferToBytes(thisMap(a)))));
		reg(inst, "haxe.io.BytesOutput", "get_length", vmethod(a -> VInt(bytesBufferLength(thisBytesOutput(a)))));
		reg(inst, "haxe.io.BytesOutput", "writeByte", vmethod(a -> { bytesBufferAddByte(thisBytesOutput(a), toInt(arg(a, 1))); VNull; }));
		reg(inst, "haxe.io.BytesOutput", "writeBytes", vmethod(a -> {
			var buf = thisBytesOutput(a);
			var bytes = thisBytes([arg(a, 1)]);
			var pos = toInt(arg(a, 2));
			var len = toInt(arg(a, 3));
			if (pos < 0 || len < 0 || pos + len > bytes.length) ioError(ctx, "OutsideBounds");
			bytesBufferAddBytes(buf, bytes, pos, len);
			VInt(len);
		}));
		reg(inst, "haxe.io.BytesOutput", "writeString", vmethod(a -> {
			var bytes = haxe.io.Bytes.ofString(stringOf(arg(a, 1)));
			bytesBufferAddBytes(thisBytesOutput(a), bytes, 0, bytes.length);
			VNull;
		}));
		reg(inst, "haxe.io.BytesOutput", "getBytes", vmethod(a -> mkBytes(ctx, bytesBufferToBytes(thisBytesOutput(a)))));
		reg(inst, "haxe.io.BytesInput", "get_length", vmethod(a -> VInt(thisBytesInput(a).totlen)));
		reg(inst, "haxe.io.BytesInput", "get_position", vmethod(a -> VInt(thisBytesInput(a).pos)));
		reg(inst, "haxe.io.BytesInput", "set_position", vmethod(a -> {
			var input = thisBytesInput(a);
			var p = toInt(arg(a, 1));
			if (p < 0) p = 0;
			else if (p > input.totlen) p = input.totlen;
			input.pos = p;
			input.len = input.totlen - p;
			syncBytesInputFields(thisInstance(a, "BytesInput"));
			VInt(input.pos);
		}));
		reg(inst, "haxe.io.BytesInput", "readByte", vmethod(a -> {
			var input = thisBytesInput(a);
			if (input.len == 0) eof(ctx);
			var byte = input.bytes.get(input.pos);
			input.pos++;
			input.len--;
			syncBytesInputFields(thisInstance(a, "BytesInput"));
			VInt(byte);
		}));
		reg(inst, "haxe.io.BytesInput", "readBytes", vmethod(a -> {
			var input = thisBytesInput(a);
			var out = thisBytes([arg(a, 1)]);
			var pos = toInt(arg(a, 2));
			var len = toInt(arg(a, 3));
			if (pos < 0 || len < 0 || pos + len > out.length) ioError(ctx, "OutsideBounds");
			if (input.len == 0 && len > 0) eof(ctx);
			if (input.len < len) len = input.len;
			for (i in 0...len) out.set(pos + i, input.bytes.get(input.pos + i));
			input.pos += len;
			input.len -= len;
			syncBytesInputFields(thisInstance(a, "BytesInput"));
			VInt(len);
		}));
		reg(s, "haxe.crypto.BaseCode", "encode", vfn(a -> mkStr(haxe.crypto.BaseCode.encode(stringOf(arg(a, 0)), stringOf(arg(a, 1))))));
		reg(s, "haxe.crypto.BaseCode", "decode", vfn(a -> try mkStr(haxe.crypto.BaseCode.decode(stringOf(arg(a, 0)), stringOf(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.crypto.BaseCode", "encodeBytes", vmethod(a -> mkBytes(ctx, thisBaseCode(a).encodeBytes(thisBytes([arg(a, 1)])))));
		reg(inst, "haxe.crypto.BaseCode", "decodeBytes", vmethod(a -> try mkBytes(ctx, thisBaseCode(a).decodeBytes(thisBytes([arg(a, 1)]))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.crypto.BaseCode", "encodeString", vmethod(a -> mkStr(thisBaseCode(a).encodeString(stringOf(arg(a, 1))))));
		reg(inst, "haxe.crypto.BaseCode", "decodeString", vmethod(a -> try mkStr(thisBaseCode(a).decodeString(stringOf(arg(a, 1)))) catch (e:Dynamic) {
			EvalExceptions.excString(ctx, Std.string(e));
		}));
		reg(inst, "haxe.crypto.Hmac", "make", vmethod(a -> mkBytes(ctx, thisHmac(a).make(thisBytes([arg(a, 1)]), thisBytes([arg(a, 2)])))));
		ctors.set(EvalHash.hash("haxe.zip.Compress"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.zip.Compress"));
			var vi = new VInstance(proto.pinstanceFields.copy(), proto);
			zipCompress.set(vi, new haxe.zip.Compress(toInt(arg(a, 0))));
			return VInstance(vi);
		});
		ctors.set(EvalHash.hash("haxe.zip.Uncompress"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.zip.Uncompress"));
			var vi = new VInstance(proto.pinstanceFields.copy(), proto);
			zipUncompress.set(vi, new haxe.zip.Uncompress(arg(a, 0) == VNull ? null : toInt(arg(a, 0))));
			return VInstance(vi);
		});
		ctors.set(EvalHash.hash("eval.vm.NativeSocket"), function(a) return mkNativeSocket(ctx, new sys.net.Socket()));
		reg(inst, "haxe.zip.Compress", "execute", vmethod(a -> zipResult(zipCompress.get(thisInstance(a, "Compress")).execute(
			thisBytes([arg(a, 1)]), toInt(arg(a, 2)), thisBytes([arg(a, 3)]), toInt(arg(a, 4))))));
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
			thisBytes([arg(a, 1)]), toInt(arg(a, 2)), thisBytes([arg(a, 3)]), toInt(arg(a, 4))))));
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
			thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3)))) catch (_:haxe.io.Eof) VInt(0)));
		reg(inst, "eval.vm.NativeSocket", "receiveChar", vmethod(a -> VInt(thisSocket(a).input.readByte())));
		reg(inst, "eval.vm.NativeSocket", "send", vmethod(a -> VInt(thisSocket(a).output.writeBytes(
			thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3))))));
		reg(inst, "eval.vm.NativeSocket", "sendChar", vmethod(a -> { thisSocket(a).output.writeByte(toInt(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setFastSend", vmethod(a -> { thisSocket(a).setFastSend(arg(a, 1) == VTrue); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setBroadcast", vmethod(a -> { setSocketBroadcast(thisSocket(a), arg(a, 1) == VTrue); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setTimeout", vmethod(a -> { thisSocket(a).setTimeout(toFloat(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "shutdown", vmethod(a -> { thisSocket(a).shutdown(arg(a, 1) == VTrue, arg(a, 2) == VTrue); VNull; }));
	}

	static function mapToString(m:Map<String, MapEntry>):String {
		var parts = [];
		for (e in m) parts.push(stringOf(e.key) + " => " + stringOf(e.value));
		return "[" + parts.join(", ") + "]";
	}
}
