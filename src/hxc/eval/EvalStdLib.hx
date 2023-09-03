package hxc.eval;

import hxc.ast.Position;
import hxc.core.Type.ModuleType;
import hxc.eval.EvalValue;
import hxc.eval.EvalValue.EvalValueTools;
import hxc.eval.EvalContext;
import hxc.eval.EvalField;
import hxc.eval.EvalMisc;
import hxc.eval.EvalHash;

// Native builtins for extern standard-library types. Each entry maps a type and field name to a
// value (a function or a constant) that the prototype builder installs on the type's prototype.
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
			case VString(s): s.sstring;
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

	static function objectDictionaryKeys(fields:Map<Int, EvalValue>):Array<Int> {
		var keys = [for (k in fields.keys()) k];
		keys.sort(function(a, b) {
			var d = seededStringHash(EvalHash.revHash(b)) - seededStringHash(EvalHash.revHash(a));
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
			if (path == EvalHash.hash("haxe.Serializer")) return name == EvalHash.hash("serialize") || name == EvalHash.hash("serializeException") || name == EvalHash.key_toString;
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

	static function instanceFieldNames(proto:VPrototype):Array<EvalValue> {
		var names = new Map<Int, Bool>();
		function loop(p:VPrototype):Void {
			if (p.pparent != null) loop(p.pparent);
			for (n in p.pinstanceNames.keys()) names.set(n, true);
			for (n in p.pnames.keys()) names.set(n, true);
		}
		loop(proto);
		return [for (n in names.keys()) mkStr(EvalHash.revHash(n))];
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
					case _: VNull;
				}
			case _: VNull;
		};
	}

	static function unexpectedEnumParams(ctx:EvalContext, params:EvalValue):Dynamic {
		return switch (params) {
			case VArray(_): EvalExceptions.excString(ctx, "Unexpected value VArray(" + stringOfDepth(params, 0) + "), expected array");
			case _: EvalExceptions.unexpectedValue(ctx, params, "array");
		};
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
	static var nativeSockets = new haxe.ds.ObjectMap<VInstance, sys.net.Socket>();
	static var fileInputs = new haxe.ds.ObjectMap<VInstance, {input:haxe.io.Input, file:Null<sys.io.FileInput>, eof:Bool}>();
	static var fileOutputs = new haxe.ds.ObjectMap<VInstance, {output:haxe.io.Output, file:Null<sys.io.FileOutput>}>();
	static var nativeProcesses = new haxe.ds.ObjectMap<VInstance, sys.io.Process>();
	static var threadMutexes = new haxe.ds.ObjectMap<VInstance, {mutex:sys.thread.Mutex, owner:Null<sys.thread.Thread>, count:Int}>();
	static var threadLocks = new haxe.ds.ObjectMap<VInstance, sys.thread.Lock>();
	static var threadTls = new haxe.ds.ObjectMap<VInstance, sys.thread.Tls<EvalValue>>();
	static var threadDeques = new haxe.ds.ObjectMap<VInstance, sys.thread.Deque<EvalValue>>();
	static var nativeXml = new haxe.ds.ObjectMap<VInstance, Xml>();
	static var nativeXmlValues = new haxe.ds.ObjectMap<Xml, VInstance>();
	static var objectFieldOrders = new haxe.ds.ObjectMap<VObject, Array<Int>>();
	static var stringHashCache = new Map<String, Int>();

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
			case VString(s): s.sstring;
			case VNativeString(s): s;
			case VArray(va): [for (i in 0...va.alength) valueToJson(va.avalues[i])];
			case VVector(vv): [for (item in vv) valueToJson(item)];
			case VObject(o):
				var obj = {};
				var fields = objectFieldMap(o);
				var names = [for (key in fields.keys()) EvalHash.revHash(key)];
				names.sort(Reflect.compare);
				for (name in names) Reflect.setField(obj, name, valueToJson(fields.get(EvalHash.hash(name))));
				obj;
			case VInstance(vi):
				var obj = {};
				var names = [for (key in vi.iproto.pinstanceNames.keys()) EvalHash.revHash(key)];
				names.sort(Reflect.compare);
				for (name in names) Reflect.setField(obj, name, valueToJson(vi.ifields[vi.iproto.pinstanceNames.get(EvalHash.hash(name))]));
				obj;
			case _: null;
		}
	}

	static function jsonFieldNames(fields:Map<Int, EvalValue>):Array<String> {
		var names = [for (key in fields.keys()) EvalHash.revHash(key)];
		names.sort(Reflect.compare);
		return names;
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
					buf.add(Math.isFinite(f) ? Std.string(f) : "null");
				case VString(s):
					buf.add(jsonString(s.sstring));
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
			case VString(s): s.sstring;
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
			case _: null;
		}
	}

	static function hostToValue(ctx:EvalContext, v:Dynamic):EvalValue {
		if (v == null) return VNull;
		if (Std.isOfType(v, Bool)) return v ? VTrue : VFalse;
		if (Std.isOfType(v, Int)) return VInt(v);
		if (Std.isOfType(v, Float)) return VFloat(v);
		if (Std.isOfType(v, String)) return mkStr(v);
		if (Std.isOfType(v, Date)) return mkDate(ctx, (cast v : Date).getTime());
		if (Std.isOfType(v, haxe.io.Bytes)) return mkBytes(ctx, (cast v : haxe.io.Bytes));
		if (Std.isOfType(v, haxe.ds.List)) {
			var out = EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.ds.List"), []);
			var list:haxe.ds.List<Dynamic> = cast v;
			for (item in list) callValueOn(out, EvalField.dynamicField(ctx, out, EvalHash.hash("add")), [hostToValue(ctx, item)]);
			return out;
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
						buf.add(f);
					}
				case VString(s):
					stringTag(s.sstring);
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
					buf.add(haxe.Serializer.run(valueToHost(ctx, VObject(o))));
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
					throw "Cannot serialize function";
				case VLazy(_):
					throw "unreachable";
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
					if (data.charCodeAt(pos++) != ":".code || data.length - pos < len) throw "Invalid string length";
					var s = urlDecode(data.substr(pos, len));
					pos += len;
					scache.push(s);
					mkStr(s);
				case "R".code:
					var idx = readDigits();
					if (idx < 0 || idx >= scache.length) throw "Invalid string reference";
					mkStr(scache[idx]);
				case "r".code:
					var idx = readDigits();
					if (idx < 0 || idx >= cache.length) throw "Invalid reference";
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
					if (proto == null) throw "Class not found " + name;
					var out = VInstance(new VInstance(proto.pinstanceFields.copy(), proto, INormal));
					cache.push(out);
					fields(out);
					out;
				case "w".code:
					var name = stringOf(loop());
					var constructor = stringOf(loop());
					if (data.charCodeAt(pos++) != ":".code) throw "Invalid enum format";
					var count = readDigits();
					var args = [for (_ in 0...count) loop()];
					var params = VArray(new VArray(args, args.length));
					var out = createEnumByName(ctx, classValue(ctx, EvalHash.hash(name)), EvalHash.hash(constructor), params);
					cache.push(out);
					out;
				case "j".code:
					var name = stringOf(loop());
					if (data.charCodeAt(pos++) != ":".code) throw "Invalid enum format";
					var index = readDigits();
					var proto = ctx.staticPrototypes.get(EvalHash.hash(name));
					if (proto == null) throw "Enum not found " + name;
					var constructor = switch (proto.pkind) {
						case PEnum(cs):
							if (index < 0 || index >= cs.length) throw "Unknown enum index " + name + "@" + index;
							cs[index].name;
						case _: throw "Enum not found " + name;
					}
					if (data.charCodeAt(pos++) != ":".code) throw "Invalid enum format";
					var count = readDigits();
					var args = [for (_ in 0...count) loop()];
					var params = VArray(new VArray(args, args.length));
					var out = createEnumByName(ctx, classValue(ctx, EvalHash.hash(name)), EvalHash.hash(constructor), params);
					cache.push(out);
					out;
				case "l".code:
					var out = EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.ds.List"), []);
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
					if (data.charCodeAt(pos++) != "h".code) throw "Invalid IntMap format";
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
					if (data.charCodeAt(pos++) != ":".code || data.length - pos < len) throw "Invalid bytes length";
					pos += len;
					var out = hostToValue(ctx, haxe.Unserializer.run(data.substr(start, pos - start)));
					cache.push(out);
					out;
				case "A".code:
					var name = stringOf(loop());
					var out = classValue(ctx, EvalHash.hash(name));
					if (out == VNull) throw "Class not found " + name;
					out;
				case "B".code:
					var name = stringOf(loop());
					var out = classValue(ctx, EvalHash.hash(name));
					if (out == VNull) throw "Enum not found " + name;
					out;
				case "x".code:
					throw stringOf(loop());
				case _:
					pos--;
					throw "Invalid char " + data.charAt(pos) + " at position " + pos;
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

	static function thisXml(a:Array<EvalValue>):Xml {
		return nativeXml.get(thisInstance(a, "Xml"));
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

	static function mkBytesBuffer(ctx:EvalContext):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.io.BytesBuffer"));
		var buf:Map<String, MapEntry> = new Map();
		bytesBufferSetLength(buf, 0);
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(buf)));
	}

	static function nativeStringOf(v:EvalValue):String {
		return switch (v) {
			case VNativeString(s): s;
			case VString(s): s.sstring;
			case _: stringOf(v);
		};
	}

	static function mkStringMap(ctx:EvalContext, values:Map<String, String>):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.ds.StringMap"));
		var m:Map<String, MapEntry> = new Map();
		for (k in values.keys()) m.set(k, {key: mkStr(k), value: mkStr(values.get(k))});
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(m)));
	}

	static function mkObject(fields:Array<{name:String, value:EvalValue}>):EvalValue {
		var m:Map<Int, EvalValue> = new Map();
		for (f in fields) m.set(EvalHash.hash(f.name), f.value);
		return VObject(new VObject([], ODictionary(m)));
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

	static function mkNativeSocket(ctx:EvalContext, socket:sys.net.Socket):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalHash.hash("eval.vm.NativeSocket"));
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		nativeSockets.set(vi, socket);
		return VInstance(vi);
	}

	static function thisSocket(a:Array<EvalValue>):sys.net.Socket {
		return nativeSockets.get(thisInstance(a, "NativeSocket"));
	}

	static function hostInfo(info:{host:sys.net.Host, port:Int}):EvalValue {
		return mkObject([
			{name: "ip", value: VInt(info.host.ip)},
			{name: "port", value: VInt(info.port)}
		]);
	}

	// A map's runtime key folds to a string for storage; StringMap keeps the string, IntMap the int,
	// EnumValueMap a structural digest of the constructor index and (recursively) its arguments.
	static function mapKey(v:EvalValue):String {
		return switch (v) {
			case VString(s): s.sstring;
			case VInt(i): Std.string(i);
			case VEnumValue(ev): "e:" + ev.epath + ":" + ev.eindex + ":" + [for (a in ev.eargs) mapKey(a)].join(",");
			case VObject(o): "o:" + objId(o);
			case VInstance(vi): "o:" + objId(vi);
			case _: stringOf(v);
		};
	}

	static function toFloat(v:EvalValue):Float {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f): f;
			case _: Math.NaN;
		};
	}

	static inline function mkStr(s:String):EvalValue return VString(new VString(s, s.length));
	static inline function mkStrLen(s:String, len:Int):EvalValue return VString(new VString(s, len));

	static function stringFastCodeAt(s:String, index:Int):EvalValue {
		var c = s.charCodeAt(index);
		return c == null ? VNull : VInt(c);
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
		for (i in 0...s.length) addUtf8EncodedChar(buf, s.charCodeAt(i));
		return buf.toString();
	}

	static function utf8Decode(s:String):String {
		var buf = new StringBuf();
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i++);
			if (c < 0x80) {
				buf.addChar(c);
			} else if (c < 0xE0 && i < s.length) {
				buf.addChar(((c & 0x1F) << 6) | (s.charCodeAt(i++) & 0x3F));
			} else if (c < 0xF0 && i + 1 < s.length) {
				var c2 = s.charCodeAt(i++);
				var c3 = s.charCodeAt(i++);
				buf.addChar(((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F));
			} else if (i + 2 < s.length) {
				var c2 = s.charCodeAt(i++);
				var c3 = s.charCodeAt(i++);
				var c4 = s.charCodeAt(i++);
				buf.addChar(((c & 0x07) << 18) | ((c2 & 0x3F) << 12) | ((c3 & 0x3F) << 6) | (c4 & 0x3F));
			} else {
				buf.addChar(c);
			}
		}
		return buf.toString();
	}

	static function utf8Codes(s:String):Array<Int> {
		var decoded = utf8Decode(s);
		return decoded.length < s.length ? [for (i in 0...decoded.length) decoded.charCodeAt(i)] : [for (i in 0...s.length) s.charCodeAt(i)];
	}

	static function utf8Valid(s:String):Bool {
		return true;
	}

	static function stringReplace(s:String, sub:String, by:String):String {
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

	static function stringIndexOf(s:String, sub:String, startValue:EvalValue):Int {
		var start = startValue == VNull ? 0 : toInt(startValue);
		if (sub.length == 0) {
			if (start < 0) return 0;
			return start > s.length ? s.length : start;
		}
		if (start < 0) start = s.length + start;
		if (start < 0) start = 0;
		if (start > s.length - sub.length) return -1;
		var max = s.length - sub.length;
		for (i in start...max + 1) {
			if (s.substr(i, sub.length) == sub) return i;
		}
		return -1;
	}

	static function stringLastIndexOf(s:String, sub:String, startValue:EvalValue):Int {
		var start = startValue == VNull ? s.length : toInt(startValue);
		if (sub.length == 0) {
			if (start < 0) return 0;
			return start > s.length ? s.length : start;
		}
		if (start < 0) return -1;
		var i = start > s.length - sub.length ? s.length - sub.length : start;
		while (i >= 0) {
			if (s.substr(i, sub.length) == sub) return i;
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
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			if (c <= 0xFF) addByte(c) else addCodePoint(c);
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

	static function stringOfDepth(v:EvalValue, depth:Int):String {
		if (depth > maxPrintDepth()) return "<...>";
		return switch (EvalValueTools.vresolve(v)) {
			case VNull: "null";
			case VTrue: "true";
			case VFalse: "false";
			case VInt(i): Std.string(i);
			case VFloat(f):
				var s = Std.string(f);
				StringTools.endsWith(s, ".") ? s.substr(0, s.length - 1) : s;
			case VString(s): s.sstring;
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
					case IPos(_): "#pos";
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
					case "Class": switch (v) { case VPrototype(p): switch (p.pkind) { case PClass(_): true; case _: false; }; case _: false; };
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

	static function stdDowncast(v:EvalValue, t:EvalValue):EvalValue {
		return switch (t) {
			case VPrototype(_): stdIsOfType(v, t) ? v : VNull;
			case _: VFalse;
		};
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
		switch (n) {
			case VNull:
				throw "Null Access";
			case _:
				gcMajor();
				return VInt(0);
		}
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
		var s = ctx.builtins.staticBuiltins;

		reg(s, "Math", "PI", VFloat(Math.PI));
		reg(s, "Math", "NaN", VFloat(Math.NaN));
		reg(s, "Math", "POSITIVE_INFINITY", VFloat(Math.POSITIVE_INFINITY));
		reg(s, "Math", "NEGATIVE_INFINITY", VFloat(Math.NEGATIVE_INFINITY));
		reg(s, "Math", "floor", vfn(a -> VInt(Math.floor(toFloat(arg(a, 0))))));
		reg(s, "Math", "ceil", vfn(a -> VInt(Math.ceil(toFloat(arg(a, 0))))));
		reg(s, "Math", "round", vfn(a -> VInt(Math.round(toFloat(arg(a, 0))))));
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
		reg(s, "Xml", "parse", vfn(a -> xmlValue(ctx, Xml.parse(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createElement", vfn(a -> xmlValue(ctx, Xml.createElement(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createPCData", vfn(a -> xmlValue(ctx, Xml.createPCData(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createCData", vfn(a -> xmlValue(ctx, Xml.createCData(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createComment", vfn(a -> xmlValue(ctx, Xml.createComment(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createDocType", vfn(a -> xmlValue(ctx, Xml.createDocType(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createProcessingInstruction", vfn(a -> xmlValue(ctx, Xml.createProcessingInstruction(stringOf(arg(a, 0))))));
		reg(s, "Xml", "createDocument", vfn(a -> xmlValue(ctx, Xml.createDocument())));
		reg(s, "haxe.xml.Printer", "print", vfn(a -> mkStr(haxe.xml.Printer.print(thisXml([arg(a, 0)]), arg(a, 1) == VTrue))));
		reg(s, "Std", "random", vfn(a -> VInt(Std.random(toInt(arg(a, 0))))));
		reg(s, "Std", "isOfType", vfn(a -> EvalValueTools.vbool(stdIsOfType(arg(a, 0), arg(a, 1)))));
		reg(s, "Std", "is", vfn(a -> EvalValueTools.vbool(stdIsOfType(arg(a, 0), arg(a, 1)))));
		reg(s, "Std", "downcast", vfn(a -> stdDowncast(arg(a, 0), arg(a, 1))));
		reg(s, "Std", "instance", vfn(a -> stdDowncast(arg(a, 0), arg(a, 1))));

		reg(s, "Std", "int", vfn(a -> VInt(Std.int(toFloat(arg(a, 0))))));
		reg(s, "Std", "string", vfn(a -> mkStr(stringOf(arg(a, 0)))));
		reg(s, "Std", "parseInt", vfn(a -> { var r = Std.parseInt(stringOf(arg(a, 0))); r == null ? VNull : VInt(r); }));
		reg(s, "Std", "parseFloat", vfn(a -> VFloat(Std.parseFloat(stringOf(arg(a, 0))))));
		reg(s, "haxe.Log", "trace", vfn(a -> { Sys.print(traceString(ctx, arg(a, 0), arg(a, 1))); VNull; }));
		reg(s, "Sys", "println", vfn(a -> { Sys.println(stringOf(arg(a, 0))); VNull; }));
		reg(s, "Sys", "print", vfn(a -> { Sys.print(stringOf(arg(a, 0))); VNull; }));
		reg(s, "Sys", "args", vfn(a -> {
			var args = [for (s in Sys.args()) mkStr(s)];
			VArray(new VArray(args, args.length));
		}));
		reg(s, "Sys", "_command", vfn(a -> VInt(Sys.command(stringOf(arg(a, 0))))));
		reg(s, "Sys", "command", vfn(a -> {
			var cmd = stringOf(arg(a, 0));
			var args = processArgs(ctx, arg(a, 1));
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
		reg(s, "eval.vm.Gc", "allocated_bytes", vfn(a -> VFloat(gcCurrentBytes())));
		reg(s, "eval.vm.Gc", "compact", vfn(a -> { gcCompact(); VNull; }));
		reg(s, "eval.vm.Gc", "counters", vfn(a -> gcCounters()));
		reg(s, "eval.vm.Gc", "finalise", vfn(a -> VNull));
		reg(s, "eval.vm.Gc", "finalise_release", vfn(a -> VNull));
		reg(s, "eval.vm.Gc", "full_major", vfn(a -> { gcMajor(); VNull; }));
		reg(s, "eval.vm.Gc", "get", vfn(a -> gcControl()));
		reg(s, "eval.vm.Gc", "major", vfn(a -> { gcMajor(); VNull; }));
		reg(s, "eval.vm.Gc", "major_slice", vfn(a -> gcMajorSlice(a.length == 0 ? VInt(0) : arg(a, 0))));
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

		var inst = ctx.builtins.instanceBuiltins;

		reg(inst, "String", "charAt", vmethod(a -> mkStr(thisString(a).charAt(toInt(arg(a, 1))))));
		reg(inst, "String", "charCodeAt", vmethod(a -> {
			var str = thisString(a);
			var i = toInt(arg(a, 1));
			(i >= 0 && i < str.length) ? VInt(str.charCodeAt(i)) : VNull;
		}));
		reg(inst, "String", "cca", vmethod(a -> {
			var str = thisString(a);
			var i = toInt(arg(a, 1));
			(i >= 0 && i < str.length) ? VInt(str.charCodeAt(i)) : VNull;
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
			mkStr(a.length > 2 && arg(a, 2) != VNull ? str.substr(pos, toInt(arg(a, 2))) : str.substr(pos));
		}));
		reg(inst, "String", "substring", vmethod(a -> {
			var str = thisString(a);
			var start = toInt(arg(a, 1));
			mkStr(a.length > 2 && arg(a, 2) != VNull ? str.substring(start, toInt(arg(a, 2))) : str.substring(start));
		}));
		reg(inst, "String", "split", vmethod(a -> {
			var parts = thisString(a).split(stringOf(arg(a, 1)));
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
		reg(inst, "Array", "iterator", vmethod(a -> EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.iterators.ArrayIterator"), [a[0]])));
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
			var i = a.length > 2 && arg(a, 2) != VNull ? toInt(arg(a, 2)) : last;
			if (i < 0) i = va.alength + i;
			if (i < 0) i = 0 else if (i > last) i = last;
			while (i >= 0) { if (EvalValueTools.equals(va.avalues[i], t)) { idx = i; break; } i--; }
			VInt(idx);
		}));
		reg(inst, "Array", "resize", vmethod(a -> {
			var va = thisArray(a); var len = toInt(arg(a, 1));
			if (len < 0) len = 0;
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
			case VPrototype(proto): switch (proto.pkind) { case PClass(_): EvalEmitter.constructPath(ctx, proto.ppath, argList(arg(a, 1))); case _: VNull; };
			case _: VNull;
		}));
		reg(s, "Type", "createEmptyInstance", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) {
				case PClass(_):
					var iproto = ctx.instancePrototypes.get(proto.ppath);
					iproto == null ? VNull : VInstance(new VInstance(iproto.pinstanceFields.copy(), iproto, INormal));
				case _: VNull;
			};
			case _: VNull;
		}));

		reg(s, "Type", "getClassFields", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): switch (proto.pkind) { case PClass(_): var ns = protoFieldNames(proto); VArray(new VArray(ns, ns.length)); case _: VNull; };
			case _: VNull;
		}));
		reg(s, "Type", "getInstanceFields", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto):
				var ip = ctx.instancePrototypes.get(proto.ppath);
				if (ip == null) VNull else {
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
			case _: VNull;
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
			var p = ctx.staticPrototypes.get(EvalHash.hash(stringOf(arg(a, 0))));
			p == null ? VNull : p.pvalue;
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
			var list = EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.ds.List"), []);
			for (v in iterableValues(ctx, arg(a, 0))) callValueOn(list, EvalField.dynamicField(ctx, list, EvalHash.hash("add")), [v]);
			list;
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
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IRegex(new EReg(stringOf(arg(a, 0)), stringOf(arg(a, 1))))));
		});

		reg(inst, "StringBuf", "add", vmethod(a -> {
			thisBuffer(a).add(stringOf(arg(a, 1)));
			VNull;
		}));
		reg(inst, "StringBuf", "addChar", vmethod(a -> {
			thisBuffer(a).addChar(toInt(arg(a, 1)));
			VNull;
		}));
		reg(inst, "StringBuf", "addSub", vmethod(a -> {
			thisBuffer(a).add(stringOf(arg(a, 1)).substr(toInt(arg(a, 2)), toInt(arg(a, 3))));
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
		reg(s, "haxe.Utf8", "encode", vfn(a -> mkStr(utf8Encode(stringOf(arg(a, 0))))));
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
			mkStr(buf.toString());
		}));
		reg(s, "haxe.Utf8", "validate", vfn(a -> EvalValueTools.vbool(utf8Valid(stringOf(arg(a, 0))))));
		reg(inst, "haxe.Utf8", "addChar", vmethod(a -> { addUtf8Char(thisBuffer(a), toInt(arg(a, 1))); VNull; }));
		reg(inst, "haxe.Utf8", "toString", vmethod(a -> {
			var s = thisBuffer(a).toString();
			mkStrLen(s, haxe.io.Bytes.ofString(s).length);
		}));

		reg(inst, "EReg", "match", vmethod(a -> EvalValueTools.vbool(thisRegex(a).match(stringOf(arg(a, 1))))));
		reg(inst, "EReg", "matched", vmethod(a -> mkStr(thisRegex(a).matched(toInt(arg(a, 1))))));
		reg(inst, "EReg", "matchedLeft", vmethod(a -> mkStr(thisRegex(a).matchedLeft())));
		reg(inst, "EReg", "matchedRight", vmethod(a -> mkStr(thisRegex(a).matchedRight())));
		reg(inst, "EReg", "matchedPos", vmethod(a -> {
			var p = thisRegex(a).matchedPos();
			var m = new Map();
			m.set(EvalHash.hash("pos"), VInt(p.pos));
			m.set(EvalHash.hash("len"), VInt(p.len));
			VObject(new VObject([], ODictionary(m)));
		}));
		reg(inst, "EReg", "matchSub", vmethod(a -> {
			var len = a.length > 3 && arg(a, 3) != VNull ? toInt(arg(a, 3)) : -1;
			EvalValueTools.vbool(thisRegex(a).matchSub(stringOf(arg(a, 1)), toInt(arg(a, 2)), len));
		}));
		reg(inst, "EReg", "split", vmethod(a -> {
			var parts = thisRegex(a).split(stringOf(arg(a, 1)));
			VArray(new VArray([for (p in parts) mkStr(p)], parts.length));
		}));
		reg(inst, "EReg", "replace", vmethod(a -> mkStr(thisRegex(a).replace(stringOf(arg(a, 1)), stringOf(arg(a, 2))))));
		reg(inst, "EReg", "map", vmethod(a -> {
			var recv = arg(a, 0);
			var fn = arg(a, 2);
			mkStr(thisRegex(a).map(stringOf(arg(a, 1)), function(_) return stringOf(callValueOn(recv, fn, [recv]))));
		}));
		reg(s, "EReg", "escape", vfn(a -> mkStr(EReg.escape(stringOf(arg(a, 0))))));

		// haxe.ds maps (StringMap/IntMap) backed by a native dictionary.
		function iteratorOf(items:Array<EvalValue>):EvalValue
			return EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.iterators.ArrayIterator"), [VArray(new VArray(items, items.length))]);
		reg(inst, "Xml", "get_nodeName", vmethod(a -> mkStr(thisXml(a).nodeName)));
		reg(inst, "Xml", "set_nodeName", vmethod(a -> {
			var x = thisXml(a);
			x.nodeName = stringOf(arg(a, 1));
			syncXmlFields(ctx, thisInstance(a, "Xml"), x);
			arg(a, 1);
		}));
		reg(inst, "Xml", "get_nodeValue", vmethod(a -> mkStr(thisXml(a).nodeValue)));
		reg(inst, "Xml", "set_nodeValue", vmethod(a -> {
			var x = thisXml(a);
			x.nodeValue = stringOf(arg(a, 1));
			syncXmlFields(ctx, thisInstance(a, "Xml"), x);
			arg(a, 1);
		}));
		reg(inst, "Xml", "get", vmethod(a -> {
			var v = thisXml(a).get(stringOf(arg(a, 1)));
			v == null ? VNull : mkStr(v);
		}));
		reg(inst, "Xml", "set", vmethod(a -> { thisXml(a).set(stringOf(arg(a, 1)), stringOf(arg(a, 2))); VNull; }));
		reg(inst, "Xml", "remove", vmethod(a -> { thisXml(a).remove(stringOf(arg(a, 1))); VNull; }));
		reg(inst, "Xml", "exists", vmethod(a -> EvalValueTools.vbool(thisXml(a).exists(stringOf(arg(a, 1))))));
		reg(inst, "Xml", "attributes", vmethod(a -> iteratorOf([for (name in thisXml(a).attributes()) mkStr(name)])));
		reg(inst, "Xml", "iterator", vmethod(a -> iteratorOf(xmlChildren(ctx, thisXml(a)))));
		reg(inst, "Xml", "elements", vmethod(a -> iteratorOf(xmlChildren(ctx, thisXml(a), true))));
		reg(inst, "Xml", "elementsNamed", vmethod(a -> iteratorOf(xmlChildren(ctx, thisXml(a), true, stringOf(arg(a, 1))))));
		reg(inst, "Xml", "firstChild", vmethod(a -> {
			var x = thisXml(a).firstChild();
			x == null ? VNull : xmlValue(ctx, x);
		}));
		reg(inst, "Xml", "firstElement", vmethod(a -> {
			var x = thisXml(a).firstElement();
			x == null ? VNull : xmlValue(ctx, x);
		}));
		reg(inst, "Xml", "addChild", vmethod(a -> {
			var parent = thisXml(a);
			var child = thisXml([arg(a, 1)]);
			parent.addChild(child);
			syncXmlFields(ctx, thisInstance(a, "Xml"), parent);
			syncXmlFields(ctx, thisInstance([arg(a, 1)], "Xml"), child);
			VNull;
		}));
		reg(inst, "Xml", "removeChild", vmethod(a -> {
			var parent = thisXml(a);
			var child = thisXml([arg(a, 1)]);
			parent.removeChild(child);
			syncXmlFields(ctx, thisInstance(a, "Xml"), parent);
			syncXmlFields(ctx, thisInstance([arg(a, 1)], "Xml"), child);
			VNull;
		}));
		reg(inst, "Xml", "insertChild", vmethod(a -> {
			var parent = thisXml(a);
			var child = thisXml([arg(a, 1)]);
			parent.insertChild(child, toInt(arg(a, 2)));
			syncXmlFields(ctx, thisInstance(a, "Xml"), parent);
			syncXmlFields(ctx, thisInstance([arg(a, 1)], "Xml"), child);
			VNull;
		}));
		reg(inst, "Xml", "toString", vmethod(a -> mkStr(thisXml(a).toString())));
		for (mapPath in ["haxe.ds.StringMap", "haxe.ds.IntMap", "haxe.ds.EnumValueMap", "haxe.ds.ObjectMap"]) {
			ctors.set(EvalHash.hash(mapPath), function(a) {
				var proto = ctx.instancePrototypes.get(EvalHash.hash(mapPath));
				return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(new Map())));
			});
			reg(inst, mapPath, "set", vmethod(a -> { thisMap(a).set(mapKey(arg(a, 1)), {key: arg(a, 1), value: arg(a, 2)}); VNull; }));
			reg(inst, mapPath, "get", vmethod(a -> { var m = thisMap(a); var k = mapKey(arg(a, 1)); m.exists(k) ? m.get(k).value : VNull; }));
			reg(inst, mapPath, "exists", vmethod(a -> EvalValueTools.vbool(thisMap(a).exists(mapKey(arg(a, 1))))));
			reg(inst, mapPath, "remove", vmethod(a -> { var m = thisMap(a); var k = mapKey(arg(a, 1)); var had = m.exists(k); m.remove(k); EvalValueTools.vbool(had); }));
			reg(inst, mapPath, "iterator", vmethod(a -> iteratorOf([for (e in thisMap(a)) e.value])));
			reg(inst, mapPath, "keys", vmethod(a -> iteratorOf([for (e in thisMap(a)) e.key])));
			reg(inst, mapPath, "keyValueIterator", vmethod(a -> objectIterator([for (e in thisMap(a)) mkObject([{name: "key", value: e.key}, {name: "value", value: e.value}])])));
			reg(inst, mapPath, "clear", vmethod(a -> { thisMap(a).clear(); VNull; }));
			reg(inst, mapPath, "copy", vmethod(a -> {
				var proto = ctx.instancePrototypes.get(EvalHash.hash(mapPath));
				var nm = new Map(); var src = thisMap(a); for (k in src.keys()) nm.set(k, src.get(k));
				VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IMap(nm)));
			}));
			reg(inst, mapPath, "toString", vmethod(a -> mkStr(mapToString(thisMap(a)))));
		}
		reg(inst, "haxe.ds.IntMap", "toString", vmethod(a -> mkStr(mapToString(thisMap(a)))));

		// New Array() builds an empty dynamic array, matching the [] literal.
		ctors.set(EvalHash.hash("Array"), function(a) return VArray(new VArray([], 0)));
		ctors.set(EvalHash.hash("eval.Vector"), function(a) return VVector([for (_ in 0...toInt(arg(a, 0))) VNull]));
		ctors.set(EvalHash.hash("haxe.io.BytesBuffer"), function(a) return mkBytesBuffer(ctx));

		// Date: a native instance carrying its epoch timestamp.
		ctors.set(EvalHash.hash("Date"), function(a) {
			var d = new Date(toInt(arg(a, 0)), toInt(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3)), toInt(arg(a, 4)), toInt(arg(a, 5)));
			return mkDate(ctx, d.getTime());
		});
		ctors.set(EvalHash.hash("sys.io._Process.NativeProcess"), function(a) {
			return try mkNativeProcess(ctx, new sys.io.Process(stringOf(arg(a, 0)), processArgs(ctx, arg(a, 1)))) catch (e:Dynamic) {
				EvalExceptions.excString(ctx, Std.string(e));
			}
		});
		ctors.set(EvalHash.hash("sys.thread.Mutex"), function(a) return mkThreadMutex(ctx));
		ctors.set(EvalHash.hash("sys.thread.Lock"), function(a) return mkThreadLock(ctx));
		ctors.set(EvalHash.hash("sys.thread.Tls"), function(a) return mkThreadTls(ctx));
		ctors.set(EvalHash.hash("sys.thread.Deque"), function(a) return mkThreadDeque(ctx));
		reg(s, "Date", "now", vfn(a -> mkDate(ctx, Date.now().getTime())));
		reg(s, "Date", "fromTime", vfn(a -> mkDate(ctx, toFloat(arg(a, 0)))));
		reg(s, "Date", "fromString", vfn(a -> mkDate(ctx, Date.fromString(stringOf(arg(a, 0))).getTime())));
		reg(s, "DateTools", "format", vfn(a -> mkStr(dateToolsFormat(Date.fromTime(thisDate([arg(a, 0)])), stringOf(arg(a, 1))))));
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
		reg(s, "haxe.Unserializer", "run", vfn(a -> unserializeString(ctx, stringOf(arg(a, 0)))));
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
		reg(s, "sys.net.Host", "resolve", vfn(a -> VInt(new sys.net.Host(stringOf(arg(a, 0))).ip)));
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
		reg(s, "eval._NativeString.NativeString_Impl_", "fromBytes", vfn(a -> VNativeString(thisBytes([arg(a, 0)]).toString())));
		reg(s, "eval._NativeString.NativeString_Impl_", "fromString", vfn(a -> arg(a, 0) == VNull ? VNull : VNativeString(stringOf(arg(a, 0)))));
		reg(s, "eval._NativeString.NativeString_Impl_", "toBytes", vfn(a -> mkBytes(ctx, haxe.io.Bytes.ofString(nativeStringOf(arg(a, 0))))));
		reg(s, "eval._NativeString.NativeString_Impl_", "toString", vfn(a -> mkStr(nativeStringOf(arg(a, 0)))));
		reg(s, "eval._NativeString.NativeString_Impl_", "concat", vfn(a -> VNativeString(nativeStringOf(arg(a, 0)) + nativeStringOf(arg(a, 1)))));
		reg(s, "eval._NativeString.NativeString_Impl_", "char", vfn(a -> mkStr(nativeStringOf(arg(a, 0)).charAt(toInt(arg(a, 1))))));
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
		reg(s, "haxe.io.Bytes", "ofString", vfn(a -> mkBytes(ctx, haxe.io.Bytes.ofString(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Bytes", "ofHex", vfn(a -> mkBytes(ctx, haxe.io.Bytes.ofHex(stringOf(arg(a, 0))))));
		reg(s, "haxe.io.Bytes", "ofData", vfn(a -> arg(a, 0)));
		reg(s, "haxe.io.Bytes", "fastGet", vfn(a -> VInt(thisBytes([arg(a, 0)]).get(toInt(arg(a, 1))))));
		reg(s, "haxe.crypto.Crc32", "make", vfn(a -> VInt(haxe.crypto.Crc32.make(thisBytes([arg(a, 0)])))));
		reg(s, "haxe.crypto.Adler32", "make", vfn(a -> VInt(haxe.crypto.Adler32.make(thisBytes([arg(a, 0)])))));
		reg(s, "haxe.crypto.Base64", "encode", vfn(a -> mkStr(haxe.crypto.Base64.encode(thisBytes([arg(a, 0)]), arg(a, 1) == VNull || arg(a, 1) == VTrue))));
		reg(s, "haxe.crypto.Base64", "decode", vfn(a -> mkBytes(ctx, haxe.crypto.Base64.decode(stringOf(arg(a, 0)), arg(a, 1) == VNull || arg(a, 1) == VTrue))));
		reg(s, "haxe.crypto.Base64", "urlEncode", vfn(a -> mkStr(haxe.crypto.Base64.urlEncode(thisBytes([arg(a, 0)]), arg(a, 1) == VTrue))));
		reg(s, "haxe.crypto.Base64", "urlDecode", vfn(a -> mkBytes(ctx, haxe.crypto.Base64.urlDecode(stringOf(arg(a, 0)), arg(a, 1) == VTrue))));
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
		reg(inst, "haxe.io.Bytes", "get", vmethod(a -> VInt(thisBytes(a).get(toInt(arg(a, 1))))));
		reg(inst, "haxe.io.Bytes", "set", vmethod(a -> { thisBytes(a).set(toInt(arg(a, 1)), toInt(arg(a, 2))); VNull; }));
		reg(inst, "haxe.io.Bytes", "getData", vmethod(a -> arg(a, 0)));
		reg(inst, "haxe.io.Bytes", "getDouble", vmethod(a -> VFloat(thisBytes(a).getDouble(toInt(arg(a, 1))))));
		reg(inst, "haxe.io.Bytes", "getFloat", vmethod(a -> VFloat(thisBytes(a).getFloat(toInt(arg(a, 1))))));
		reg(inst, "haxe.io.Bytes", "getInt32", vmethod(a -> VInt(thisBytes(a).getInt32(toInt(arg(a, 1))))));
		reg(inst, "haxe.io.Bytes", "getString", vmethod(a -> mkStr(thisBytes(a).getString(toInt(arg(a, 1)), toInt(arg(a, 2))))));
		reg(inst, "haxe.io.Bytes", "getUInt16", vmethod(a -> VInt(thisBytes(a).getUInt16(toInt(arg(a, 1))))));
		reg(inst, "haxe.io.Bytes", "toString", vmethod(a -> mkStr(thisBytes(a).toString())));
		reg(inst, "haxe.io.Bytes", "toHex", vmethod(a -> mkStr(thisBytes(a).toHex())));
		reg(inst, "haxe.io.Bytes", "sub", vmethod(a -> mkBytes(ctx, thisBytes(a).sub(toInt(arg(a, 1)), toInt(arg(a, 2))))));
		reg(inst, "haxe.io.Bytes", "fill", vmethod(a -> { thisBytes(a).fill(toInt(arg(a, 1)), toInt(arg(a, 2)), toInt(arg(a, 3))); VNull; }));
		reg(inst, "haxe.io.Bytes", "blit", vmethod(a -> { thisBytes(a).blit(toInt(arg(a, 1)), thisBytes([arg(a, 2)]), toInt(arg(a, 3)), toInt(arg(a, 4))); VNull; }));
		reg(inst, "haxe.io.Bytes", "compare", vmethod(a -> VInt(thisBytes(a).compare(thisBytes([arg(a, 1)])))));
		reg(inst, "haxe.io.Bytes", "setDouble", vmethod(a -> { thisBytes(a).setDouble(toInt(arg(a, 1)), toFloat(arg(a, 2))); VNull; }));
		reg(inst, "haxe.io.Bytes", "setFloat", vmethod(a -> { thisBytes(a).setFloat(toInt(arg(a, 1)), toFloat(arg(a, 2))); VNull; }));
		reg(inst, "haxe.io.Bytes", "setInt32", vmethod(a -> { thisBytes(a).setInt32(toInt(arg(a, 1)), toInt(arg(a, 2))); VNull; }));
		reg(inst, "haxe.io.Bytes", "setUInt16", vmethod(a -> { thisBytes(a).setUInt16(toInt(arg(a, 1)), toInt(arg(a, 2))); VNull; }));
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
		reg(inst, "eval.vm.NativeSocket", "receive", vmethod(a -> VInt(thisSocket(a).input.readBytes(
			thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3))))));
		reg(inst, "eval.vm.NativeSocket", "receiveChar", vmethod(a -> VInt(thisSocket(a).input.readByte())));
		reg(inst, "eval.vm.NativeSocket", "send", vmethod(a -> VInt(thisSocket(a).output.writeBytes(
			thisBytes([arg(a, 1)]), toInt(arg(a, 2)), toInt(arg(a, 3))))));
		reg(inst, "eval.vm.NativeSocket", "sendChar", vmethod(a -> { thisSocket(a).output.writeByte(toInt(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setFastSend", vmethod(a -> { thisSocket(a).setFastSend(arg(a, 1) == VTrue); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "setTimeout", vmethod(a -> { thisSocket(a).setTimeout(toFloat(arg(a, 1))); VNull; }));
		reg(inst, "eval.vm.NativeSocket", "shutdown", vmethod(a -> { thisSocket(a).shutdown(arg(a, 1) == VTrue, arg(a, 2) == VTrue); VNull; }));
	}

	static function mapToString(m:Map<String, MapEntry>):String {
		var parts = [];
		for (e in m) parts.push(stringOf(e.key) + " => " + stringOf(e.value));
		return "[" + parts.join(", ") + "]";
	}
}
