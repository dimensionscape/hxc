package hxc.eval;

import hxc.core.Globals.Path;

// Name interning: every field/type name used by the interpreter is mapped to a small int so
// field lookup and prototype offset tables key on ints. Ids are assigned sequentially, which
// is deterministic and collision-free. revHash recovers the original name for reflection.
class EvalHash {
	static var forward:Map<String, Int> = new Map();
	static var reverse:Map<Int, String> = new Map();
	static var nextId:Int = 0;

	public static function dbgRoots():Array<{name:String, root:Dynamic}> {
		return [{name: "EvalHash.forward", root: forward}, {name: "EvalHash.reverse", root: reverse}];
	}

	public static function hash(s:String):Int {
		var id = forward.get(s);
		if (id != null) return id;
		id = nextId++;
		forward.set(s, id);
		reverse.set(id, s);
		return id;
	}

	public static function revHash(i:Int):String {
		return reverse.get(i);
	}

	public static function pathHash(path:Path):Int {
		return hash(path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name);
	}

	public static final keyLength = hash("length");
	public static final key_toString = hash("toString");
	public static final key_OutsideBounds = hash("OutsideBounds");
	public static final keyLow = hash("low");
	public static final keyHigh = hash("high");
	public static final keyNext = hash("next");
	public static final key_hasNext = hash("hasNext");
	public static final keyIterator = hash("iterator");
	public static final key___meta__ = hash("__meta__");
	public static final keyGet = hash("get");
	public static final keySet = hash("set");
	public static final keyPos = hash("pos");
	public static final keyMin = hash("min");
	public static final keyMax = hash("max");
	public static final keyFile = hash("file");
	public static final keyMessage = hash("message");
	public static final keyName = hash("name");
	public static final keyError = hash("error");
	public static final keyExceptionMessage = hash("__exceptionMessage");
	public static final keyExceptionStack = hash("__exceptionStack");
	public static final keyNativeException = hash("__nativeException");
	public static final keyNativeStack = hash("__nativeStack");
	public static final key_Array = hash("Array");
	public static final key_eval_Vector = hash("eval.Vector");
	public static final key_String = hash("String");
	public static final key_haxe_Exception = hash("haxe.Exception");
	public static final key_haxe_ValueException = hash("haxe.ValueException");
	public static final key_haxe_ds_Option = hash("haxe.ds.Option");
	public static final key_haxe_ds_StringMap = hash("haxe.ds.StringMap");
	public static final key_haxe_ds_IntMap = hash("haxe.ds.IntMap");
	public static final key_haxe_ds_ObjectMap = hash("haxe.ds.ObjectMap");
	public static final key_haxe_io_Bytes = hash("haxe.io.Bytes");
	public static final key_Date = hash("Date");
	public static final key_Dynamic = hash("Dynamic");
	public static final key_ValueType = hash("ValueType");
	public static final key_EReg = hash("EReg");
	public static final key_StringBuf = hash("StringBuf");
	public static final key_Int = hash("Int");
	public static final key_Float = hash("Float");
	public static final key_Bool = hash("Bool");
	public static final key_Class = hash("Class");
	public static final key_Enum = hash("Enum");
	public static final key_EnumValue = hash("EnumValue");
	public static final key___init__ = hash("__init__");
	public static final keyNew = hash("new");
	public static final keyQuestionmark = hash("?");
}
