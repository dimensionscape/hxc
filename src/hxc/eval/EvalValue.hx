package hxc.eval;

import haxe.io.Bytes;
import hxc.ast.Position;
import hxc.core.Type.ModuleType;

// Result of a relational comparison.
enum Cmp {
	CEq;
	CSup;
	CInf;
	CUndef;
}

// The interpreter runtime value. Ints are 32-bit host ints. Booleans use two nullary
// constructors rather than VBool(b).
enum EvalValue {
	VNull;
	VTrue;
	VFalse;
	VInt(v:Int);
	VFloat(v:Float);
	VEnumValue(e:VEnumValue);
	VObject(o:VObject);
	VInstance(i:VInstance);
	VString(s:VString);
	VArray(a:VArray);
	VVector(v:Array<EvalValue>);
	VPrototype(p:VPrototype);
	VFunction(f:VFunc, isStatic:Bool);
	VFieldClosure(v:EvalValue, f:VFunc);
	VLazy(f:Void->EvalValue);
	VNativeString(s:hxc.eval.EvalString.ByteString);
	VHandle(h:EvalHandle);
	// VInt64 / VUInt64 (eval.integers): the 64 bits in a box, since these compare physically and every
	// native answers a fresh one.
	VInt64(b:EvalInt64);
	VUInt64(b:EvalInt64);
}

class EvalInt64 {
	public final v:haxe.Int64;

	public function new(v:haxe.Int64) {
		this.v = v;
	}
}

// The libuv objects eval.luv hands out (hxc.eval.EvalLuv). `native` is the object the binding
// (hxc.eval.Luv) allocated; two handles are the same when they wrap the same one.
enum EvalHandleKind {
	HLoop;
	HIdle;
	HTimer;
	HAsync;
	HOnce;
	HMutex;
	HRwLock;
	HSemaphore;
	HCondition;
	HBarrier;
	HPrepare;
	HCheck;
	HBuffer;
	HSockAddr;
	HTcp;
	HUdp;
	HPipe;
	HTty;
	HSignal;
	HFsEvent;
	HFsPoll;
	HFile;
	HFileRequest;
	HFileModeNumeric;
	HDir;
	HRandomRequest;
	HAddrRequest;
	HNameRequest;
	HThreadPoolRequest;
	HProcess;
	HRedirection;
	HThread;
}

class EvalHandle {
	public final kind:EvalHandleKind;
	public final native:Dynamic;

	public function new(kind:EvalHandleKind, native:Dynamic) {
		this.kind = kind;
		this.native = native;
	}
}

// A callable: takes the argument list, returns a value.
typedef VFunc = Array<EvalValue>->EvalValue;

// The string's UTF-8 bytes, its length in characters as the creating site computed it, and the (at
// most two) cursors getOffset walks from.
class VString {
	public var sstring:hxc.eval.EvalString.ByteString;
	public var slength:Int;
	public var soffsets:Null<Array<hxc.eval.EvalString.OffsetCursor>> = null;

	public function new(sstring:hxc.eval.EvalString.ByteString, slength:Int) {
		this.sstring = sstring;
		this.slength = slength;
	}
}

// Dynamic array. alength tracks the live length independently of the backing array.
@:structInit
class VArray {
	public var avalues:Array<EvalValue>;
	public var alength:Int;
	public function new(avalues:Array<EvalValue>, alength:Int) {
		this.avalues = avalues;
		this.alength = alength;
	}
}

// Anonymous object: fields live in an offset-indexed array, addressed either through a shared
// prototype or, once fields are added dynamically, through a per-object name-to-offset map.
@:structInit
class VObject {
	public var ofields:Array<EvalValue>;
	public var oproto:VObjectProto;
	public function new(ofields:Array<EvalValue>, oproto:VObjectProto) {
		this.ofields = ofields;
		this.oproto = oproto;
	}
}

enum VObjectProto {
	OProto(p:VPrototype);
	ODictionary(m:Map<Int, EvalValue>);
}

// The static face of a class or enum. Instance and static fields are offset-indexed arrays;
// the name maps give the offset for a hashed name.
@:structInit
class VPrototype {
	public var ppath:Int;
	public var pfields:Array<EvalValue>;
	public var pnames:Map<Int, Int>;
	public var pinstanceFields:Array<EvalValue>;
	public var pinstanceNames:Map<Int, Int>;
	public var pparent:Null<VPrototype>;
	public var pkind:VPrototypeKind;
	public var pvalue:EvalValue;
	public function new(ppath:Int, pfields:Array<EvalValue>, pnames:Map<Int, Int>, pinstanceFields:Array<EvalValue>,
			pinstanceNames:Map<Int, Int>, pparent:Null<VPrototype>, pkind:VPrototypeKind, pvalue:EvalValue) {
		this.ppath = ppath;
		this.pfields = pfields;
		this.pnames = pnames;
		this.pinstanceFields = pinstanceFields;
		this.pinstanceNames = pinstanceNames;
		this.pparent = pparent;
		this.pkind = pkind;
		this.pvalue = pvalue;
	}
}

enum VPrototypeKind {
	PClass(superFields:Array<Int>);
	PEnum(constructors:Array<{name:String, args:Array<Int>}>);
	PInstance;
	PObject;
}

// A class instance: fields are offset-indexed via iproto.pinstanceNames; ikind carries any
// native payload.
@:structInit
class VInstance {
	public var ifields:Array<EvalValue>;
	public var iproto:VPrototype;
	public var ikind:EvalInstanceKind;
	public function new(ifields:Array<EvalValue>, iproto:VPrototype, ?ikind:EvalInstanceKind) {
		this.ifields = ifields;
		this.iproto = iproto;
		this.ikind = ikind == null ? INormal : ikind;
	}
}

// Native payload behind some instances. The map, regex, buffer, channel, thread, and SSL kinds
// arrive with their respective builtins.
enum EvalInstanceKind {
	INormal;
	IBytes(b:Bytes);
	IDate(timestamp:Float);
	IPos(p:Position);
	ITypeDecl(mt:ModuleType);
	IRef(v:EvalValue);
	// ILazyType: the lazy a macro's TLazy(f) carries, and the function that forces it.
	ILazyType(r:hxc.core.Ref<hxc.core.Type.TLazy>, get:Void->EvalValue);
	// IBuffer holds a StringBuf's buffer, IUtf8 a haxe.Utf8 buffer.
	IBuffer(buf:hxc.eval.EvalString.VStringBuffer);
	IUtf8(buf:hxc.eval.EvalString.ByteBuffer);
	IRegex(re:EvalRegex);
	IMap(m:Map<String, MapEntry>);
	// The mbedtls contexts (hxc.eval.Mbedtls.MbedtlsObject, Dynamic here as EvalHandle's native is:
	// the object exists only where mbedtls is built).
	IMbedtlsConfig(o:Dynamic);
	IMbedtlsCtrDrbg(o:Dynamic);
	IMbedtlsEntropy(o:Dynamic);
	IMbedtlsPkContext(o:Dynamic);
	IMbedtlsSsl(o:Dynamic);
	IMbedtlsX509Crt(o:Dynamic);
}

// A native map entry keeps the original key alongside its value, so iteration over keys (and
// key/value pairs) can recover keys that do not round-trip through the string storage key
// (enum values, object identities).
typedef MapEntry = {key:EvalValue, value:EvalValue};

@:structInit
class VEnumValue {
	public var eindex:Int;
	public var eargs:Array<EvalValue>;
	public var epath:Int;
	public var enpos:Null<Position>;
	public function new(eindex:Int, eargs:Array<EvalValue>, epath:Int, enpos:Null<Position>) {
		this.eindex = eindex;
		this.eargs = eargs;
		this.epath = epath;
		this.enpos = enpos;
	}
}

class EvalValueTools {
	public static final vnull = VNull;
	public static final vtrue = VTrue;
	public static final vfalse = VFalse;

	public static inline function vbool(b:Bool):EvalValue return b ? VTrue : VFalse;
	public static inline function vint(i:Int):EvalValue return VInt(i);
	public static inline function vfloat(f:Float):EvalValue return VFloat(f);
	public static inline function vprototype(p:VPrototype):EvalValue return VPrototype(p);
	public static inline function vinstance(i:VInstance):EvalValue return VInstance(i);
	public static inline function vobject(o:VObject):EvalValue return VObject(o);
	public static inline function vfunction(f:VFunc):EvalValue return VFunction(f, false);
	public static inline function vstaticFunction(f:VFunc):EvalValue return VFunction(f, true);
	public static inline function vfieldClosure(v:EvalValue, f:VFunc):EvalValue return VFieldClosure(v, f);
	public static inline function venumValue(e:VEnumValue):EvalValue return VEnumValue(e);
	public static inline function vnativeString(s:hxc.eval.EvalString.ByteString):EvalValue return VNativeString(s);

	// Force a lazy value to its underlying value.
	public static function vresolve(v:EvalValue):EvalValue {
		return switch (v) {
			case VLazy(f): vresolve(f());
			case _: v;
		};
	}

	public static inline function vstringEqual(s1:VString, s2:VString):Bool {
		return s1 == s2 || s1.sstring == s2.sstring;
	}

	// Haxe-level equality: structural for primitives, physical for reference values.
	public static function equals(a:EvalValue, b:EvalValue):Bool {
		return switch [a, b] {
			case [VTrue, VTrue] | [VFalse, VFalse] | [VNull, VNull]: true;
			case [VInt(x), VInt(y)]: x == y;
			case [VFloat(x), VFloat(y)]: x == y;
			case [VFloat(x), VInt(y)]: x == y;
			case [VInt(x), VFloat(y)]: x == y;
			case [VEnumValue(x), VEnumValue(y)]:
				x == y || (x.eindex == y.eindex && x.eargs.length == 0 && y.eargs.length == 0 && x.epath == y.epath);
			case [VObject(x), VObject(y)]: x == y;
			case [VInstance(x), VInstance(y)]: x == y;
			case [VString(x), VString(y)]: vstringEqual(x, y);
			case [VArray(x), VArray(y)]: x == y;
			case [VVector(x), VVector(y)]: x == y;
			case [VFunction(x, _), VFunction(y, _)]: Reflect.compareMethods(x, y);
			case [VPrototype(x), VPrototype(y)]: x.ppath == y.ppath;
			case [VNativeString(x), VNativeString(y)]: x == y;
			// Handles: the same kind over the same libuv object
			case [VHandle(x), VHandle(y)]: x.kind == y.kind && x.native == y.native;
			// `a == b`: the same value, not an equal one
			case [VInt64(x), VInt64(y)] | [VUInt64(x), VUInt64(y)]: x == y;
			case [VLazy(f), _]: equals(f(), b);
			case [_, VLazy(f)]: equals(a, f());
			case _: a == b;
		};
	}
}
