package hxc.codegen.jvm;

import haxe.io.BytesOutput;

// Constant pool entry kinds, access flag sets, and the primitives the rest of the backend writes bytes
// through.

typedef JvmConstantPoolIndex = Int;
typedef JvmBootstrapMethodIndex = Int;

enum JvmConstant {
	ConstUtf8(s:String);
	ConstInt(i:Int);
	ConstFloat(f:Float);
	ConstLong(i:haxe.Int64);
	ConstDouble(f:Float);
	ConstClass(i:JvmConstantPoolIndex);
	ConstString(i:JvmConstantPoolIndex);
	ConstFieldref(a:JvmConstantPoolIndex, b:JvmConstantPoolIndex);
	ConstMethodref(a:JvmConstantPoolIndex, b:JvmConstantPoolIndex);
	ConstInterfaceMethodref(a:JvmConstantPoolIndex, b:JvmConstantPoolIndex);
	ConstNameAndType(a:JvmConstantPoolIndex, b:JvmConstantPoolIndex);
	ConstMethodHandle(kind:Int, i:JvmConstantPoolIndex);
	ConstMethodType(i:JvmConstantPoolIndex);
	ConstInvokeDynamic(bootstrap:JvmBootstrapMethodIndex, i:JvmConstantPoolIndex);
}

enum FieldKind {
	FKField;
	FKMethod;
	FKInterfaceMethod;
}

enum NumericRange {
	Int8Range;
	Int16Range;
	Int32Range;
}

class JvmError {
	public var message(default, null):String;

	public function new(message:String) {
		this.message = message;
	}
}

class JvmGlobals {
	public static function getNumericRange(i:Int):NumericRange {
		return if (i >= -128 && i <= 127) Int8Range
			else if (i >= -32768 && i <= 32767) Int16Range
			else Int32Range;
	}

	public static function getNumericRangeUnsigned(i:Int):NumericRange {
		return if (i <= 0xFF) Int8Range
			else if (i <= 0xFFFF) Int16Range
			else Int32Range;
	}

	public static function inRange(unsigned:Bool, range:NumericRange, i:Int):Bool {
		var r = unsigned ? getNumericRangeUnsigned(i) : getNumericRange(i);
		return switch [r, range] {
			case [Int8Range, Int8Range | Int16Range | Int32Range]: true;
			case [Int16Range, Int16Range | Int32Range]: true;
			case [Int32Range, Int32Range]: true;
			case _: false;
		}
	}

	public static function jerror(s:String):Dynamic {
		throw new JvmError(s);
	}

	// The stream is big endian throughout; the caller sets that once on the output it hands in.
	public static inline function writeByte(ch:BytesOutput, i:Int):Void {
		ch.writeByte(i & 0xFF);
	}

	public static inline function writeBytes(ch:BytesOutput, b:haxe.io.Bytes):Void {
		ch.write(b);
	}

	// The classfile format is big-endian throughout and BytesOutput defaults to little-endian, so these
	// write the bytes explicitly rather than depending on the stream's flag.
	public static inline function writeUi16(ch:BytesOutput, i:Int):Void {
		ch.writeByte((i >> 8) & 0xFF);
		ch.writeByte(i & 0xFF);
	}

	public static inline function writeUi32(ch:BytesOutput, i:Int):Void {
		ch.writeByte((i >>> 24) & 0xFF);
		ch.writeByte((i >> 16) & 0xFF);
		ch.writeByte((i >> 8) & 0xFF);
		ch.writeByte(i & 0xFF);
	}

	public static inline function writeString(ch:BytesOutput, s:String):Void {
		ch.writeString(s);
	}

	public static function writeArray16<T>(ch:BytesOutput, f:BytesOutput->T->Void, a:Array<T>):Void {
		writeUi16(ch, a.length);
		for (x in a) f(ch, x);
	}

	public static function patchName(name:String):String {
		return switch (name) {
			case "<init>": "new";
			case "<clinit>": "__init__";
			case name: name;
		}
	}
}

class ClassAccessFlags {
	public static inline var CPublic = 0x1;
	public static inline var CFinal = 0x10;
	public static inline var CSuper = 0x20;
	public static inline var CInterface = 0x200;
	public static inline var CAbstract = 0x400;
	public static inline var CSynthetic = 0x1000;
	public static inline var CAnnotation = 0x2000;
	public static inline var CEnum = 0x4000;

	public static inline function hasFlag(b:Int, flag:Int):Bool return (b & flag) != 0;
}

class MethodAccessFlags {
	public static inline var MPublic = 0x1;
	public static inline var MPrivate = 0x2;
	public static inline var MProtected = 0x4;
	public static inline var MStatic = 0x8;
	public static inline var MFinal = 0x10;
	public static inline var MSynchronized = 0x20;
	public static inline var MBridge = 0x40;
	public static inline var MVarargs = 0x80;
	public static inline var MNative = 0x100;
	public static inline var MAbstract = 0x400;
	public static inline var MStrict = 0x800;
	public static inline var MSynthetic = 0x1000;

	public static inline function hasFlag(b:Int, flag:Int):Bool return (b & flag) != 0;
}

class FieldAccessFlags {
	public static inline var FdPublic = 0x1;
	public static inline var FdPrivate = 0x2;
	public static inline var FdProtected = 0x4;
	public static inline var FdStatic = 0x8;
	public static inline var FdFinal = 0x10;
	public static inline var FdVolatile = 0x40;
	public static inline var FdTransient = 0x80;
	public static inline var FdSynthetic = 0x1000;
	public static inline var FdEnum = 0x4000;

	public static inline function hasFlag(b:Int, flag:Int):Bool return (b & flag) != 0;
}
