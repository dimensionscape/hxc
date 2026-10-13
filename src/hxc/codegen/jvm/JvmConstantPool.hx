package hxc.codegen.jvm;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmSignature;

// the pool every other part interns into. An entry is added once; a long or a double takes the index after
// it as well.

typedef InnerClassEntry = {outer:JPath, name:String, offset:Int};

class JvmConstantPool {
	var pool:Array<JvmConstant> = [];
	var lut:Map<String, Int> = new Map();
	var luti:Map<Int, Int> = new Map();
	var nextIndex = 1;
	var closed = false;
	var innerClasses:Map<String, InnerClassEntry> = new Map();
	// the hash-table bucket order that commitInnerClasses visits innerClasses in
	var innerOrder = new hxc.core.NameHash.HashTableOrder();

	public function new() {}

	// MODIFIED utf-8. A null byte is two bytes and anything beyond the basic plane is written as its
	// surrogate pair, each encoded on its own.
	public static function utf8jvm(input:String):Bytes {
		var ch = new BytesOutput();
		var i = 0;
		while (i < input.length) {
			var b = input.charCodeAt(i++);
			// hxc strings carry a supplementary code point as a surrogate pair
			if (b >= 0xD800 && b <= 0xDBFF && i < input.length) {
				var lo = input.charCodeAt(i);
				if (lo >= 0xDC00 && lo <= 0xDFFF) {
					i++;
					b = 0x10000 + ((b - 0xD800) << 10) + (lo - 0xDC00);
				}
			}
			if (b > 0 && b <= 0x7F)
				ch.writeByte(b);
			else if (b <= 0x7FF) {
				ch.writeByte(0xC0 | (b >> 6));
				ch.writeByte(0x80 | (b & 0x3F));
			} else if (b <= 0xFFFF) {
				ch.writeByte(0xE0 | (b >> 12));
				ch.writeByte(0x80 | ((b >> 6) & 0x3F));
				ch.writeByte(0x80 | (b & 0x3F));
			} else {
				ch.writeByte(0xED);
				ch.writeByte(0xA0 | ((b >> 16) - 1));
				ch.writeByte(0x80 | ((b >> 10) & 0x3F));
				ch.writeByte(0xED);
				ch.writeByte(0xB0 | ((b >> 6) & 0x0F));
				ch.writeByte(0x80 | (b & 0x3F));
			}
		}
		return ch.getBytes();
	}

	/**
		The pool is keyed on the constant itself; this is that identity as a string.

		A float or double is keyed by its exact BIT PATTERN, never by Std.string of it.
	**/
	static function constKey(c:JvmConstant):String {
		return switch (c) {
			case ConstUtf8(s): "u" + s;
			case ConstInt(i): "i" + i;
			case ConstFloat(f): "f" + haxe.io.FPHelper.floatToI32(f);
			case ConstLong(i): "l" + i;
			case ConstDouble(f): "d" + haxe.io.FPHelper.doubleToI64(f);
			case ConstClass(i): "c" + i;
			case ConstString(i): "s" + i;
			case ConstFieldref(a, b): "F" + a + ":" + b;
			case ConstMethodref(a, b): "M" + a + ":" + b;
			case ConstInterfaceMethodref(a, b): "I" + a + ":" + b;
			case ConstNameAndType(a, b): "N" + a + ":" + b;
			case ConstMethodHandle(k, i): "H" + k + ":" + i;
			case ConstMethodType(i): "T" + i;
			case ConstInvokeDynamic(a, b): "D" + a + ":" + b;
		}
	}

	public function add(const:JvmConstant):Int {
		var key = constKey(const);
		var found = lut.get(key);
		if (found != null) return found;
		if (closed) JvmGlobals.jerror("constant pool is closed");
		var i = nextIndex;
		nextIndex++;
		pool.push(const);
		lut.set(key, i);
		luti.set(i, pool.length - 1);
		switch (const) {
			case ConstDouble(_) | ConstLong(_): nextIndex++;
			case _:
		}
		return i;
	}

	public function get(i:Int):JvmConstant {
		return pool[luti.get(i)];
	}

	static function sTypePath(p:JPath):String {
		return p.pack.length == 0 ? p.name : p.pack.join("/") + "/" + p.name;
	}

	public function addType(s:String):Int {
		var offset = add(ConstUtf8(s));
		return add(ConstClass(offset));
	}

	// a name with a $ in it also records the inner-class pair.
	public function addPath(path:JPath):Int {
		var s = sTypePath(path);
		var offset = addType(s);
		if (path.name.indexOf("$") >= 0 && !StringTools.startsWith(s, "[")) {
			var idx = path.name.indexOf("$");
			var name1 = path.name.substr(0, idx);
			var name2 = path.name.substr(idx + 1);
			var outer:JPath = {pack: path.pack, name: name1};
			var key = sTypePath(outer) + "$" + name2;
			innerClasses.set(key, {outer: outer, name: name2, offset: offset});
			innerOrder.add(key, hxc.core.NameHash.NameHash.innerKeyHash(path.pack, name1, name2));
		}
		return offset;
	}

	public function getInnerClassOrder():Array<String> {
		return innerOrder.visitOrder();
	}

	public function addString(s:String):Int {
		return add(ConstUtf8(s));
	}

	public function addConstString(s:String):Int {
		var offset = addString(s);
		return add(ConstString(offset));
	}

	public function addNameAndType(name:String, jsig:JSignature, fieldKind:FieldKind):Int {
		var offsetName = addString(name);
		var desc = fieldKind == FKField
			? JvmSignature.generateSignature(false, jsig)
			: JvmSignature.generateMethodSignature(false, jsig);
		var offsetDesc = addString(desc);
		return add(ConstNameAndType(offsetName, offsetDesc));
	}

	public function addField(path:JPath, name:String, jsig:JSignature, fieldKind:FieldKind):Int {
		var offsetClass = addPath(path);
		var offsetInfo = addNameAndType(name, jsig, fieldKind);
		return add(switch (fieldKind) {
			case FKField: ConstFieldref(offsetClass, offsetInfo);
			case FKMethod: ConstMethodref(offsetClass, offsetInfo);
			case FKInterfaceMethod: ConstInterfaceMethodref(offsetClass, offsetInfo);
		});
	}

	public function getInnerClasses():Map<String, InnerClassEntry> {
		return innerClasses;
	}

	// CONSTANT_Long (like CONSTANT_Double) stores its high four bytes before its low four bytes (JVMS
	// 4.4.5), like every other multi-byte field in a class file.
	function writeI64(ch:BytesOutput, i64:haxe.Int64):Void {
		ch.writeInt32(i64.high);
		ch.writeInt32(i64.low);
	}

	function write(ch:BytesOutput):Void {
		JvmGlobals.writeUi16(ch, nextIndex);
		for (const in pool) switch (const) {
			case ConstUtf8(s):
				JvmGlobals.writeByte(ch, 1);
				var b = utf8jvm(s);
				JvmGlobals.writeUi16(ch, b.length);
				ch.write(b);
			case ConstInt(i):
				JvmGlobals.writeByte(ch, 3);
				ch.writeInt32(i);
			case ConstFloat(f):
				JvmGlobals.writeByte(ch, 4);
				if (Math.isNaN(f)) ch.writeInt32(0x7f800001);
				else if (!Math.isFinite(f)) ch.writeInt32(f > 0.0 ? 0x7f800000 : 0xff800000);
				else ch.writeInt32(haxe.io.FPHelper.floatToI32(f));
			case ConstLong(i):
				JvmGlobals.writeByte(ch, 5);
				writeI64(ch, i);
			case ConstDouble(d):
				JvmGlobals.writeByte(ch, 6);
				ch.writeDouble(d);
			case ConstClass(offset):
				JvmGlobals.writeByte(ch, 7);
				JvmGlobals.writeUi16(ch, offset);
			case ConstString(offset):
				JvmGlobals.writeByte(ch, 8);
				JvmGlobals.writeUi16(ch, offset);
			case ConstFieldref(o1, o2):
				JvmGlobals.writeByte(ch, 9);
				JvmGlobals.writeUi16(ch, o1);
				JvmGlobals.writeUi16(ch, o2);
			case ConstMethodref(o1, o2):
				JvmGlobals.writeByte(ch, 10);
				JvmGlobals.writeUi16(ch, o1);
				JvmGlobals.writeUi16(ch, o2);
			case ConstInterfaceMethodref(o1, o2):
				JvmGlobals.writeByte(ch, 11);
				JvmGlobals.writeUi16(ch, o1);
				JvmGlobals.writeUi16(ch, o2);
			case ConstNameAndType(o1, o2):
				JvmGlobals.writeByte(ch, 12);
				JvmGlobals.writeUi16(ch, o1);
				JvmGlobals.writeUi16(ch, o2);
			case ConstMethodHandle(i, offset):
				JvmGlobals.writeByte(ch, 15);
				JvmGlobals.writeByte(ch, i);
				JvmGlobals.writeUi16(ch, offset);
			case ConstMethodType(offset):
				JvmGlobals.writeByte(ch, 16);
				JvmGlobals.writeUi16(ch, offset);
			case ConstInvokeDynamic(o1, o2):
				JvmGlobals.writeByte(ch, 18);
				JvmGlobals.writeUi16(ch, o1);
				JvmGlobals.writeUi16(ch, o2);
		}
	}

	public function close():Bytes {
		closed = true;
		var ch = new BytesOutput();
		ch.bigEndian = true;
		write(ch);
		return ch.getBytes();
	}
}
