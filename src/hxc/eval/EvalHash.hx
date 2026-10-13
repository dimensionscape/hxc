package hxc.eval;

import hxc.core.Globals.Path;

// Name interning: every field/type name used by the interpreter is mapped to a small int so
// field lookup and prototype offset tables key on ints. Ids are assigned sequentially, which
// is deterministic and collision-free. revHash recovers the original name for reflection.
class EvalHash {
	static var forward:Map<String, Int> = new Map();
	static var reverse:Map<Int, String> = new Map();
	static var nextId:Int = 0;

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
		var key = path.dottedKey();
		if (path.evalHashId < 0) path.evalHashId = hash(key);
		return path.evalHashId;
	}

	public static final keyLength = hash("length");
	public static final keyToString = hash("toString");
	public static final keyOutsideBounds = hash("OutsideBounds");
	public static final keyLow = hash("low");
	public static final keyHigh = hash("high");
	public static final keyNext = hash("next");
	public static final keyHasNext = hash("hasNext");
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
	public static final keyArray = hash("Array");
	public static final keyEvalVector = hash("eval.Vector");
	public static final keyString = hash("String");
	public static final keyHaxeException = hash("haxe.Exception");
	public static final keyHaxeValueException = hash("haxe.ValueException");
	public static final keyHaxeDsOption = hash("haxe.ds.Option");
	public static final keyHaxeDsStringMap = hash("haxe.ds.StringMap");
	public static final keyHaxeDsIntMap = hash("haxe.ds.IntMap");
	public static final keyHaxeDsObjectMap = hash("haxe.ds.ObjectMap");
	public static final keyHaxeIoBytes = hash("haxe.io.Bytes");
	public static final keyDate = hash("Date");
	public static final keyDynamic = hash("Dynamic");
	public static final keyValueType = hash("ValueType");
	public static final keyEReg = hash("EReg");
	public static final keyStringBuf = hash("StringBuf");
	public static final keyInt = hash("Int");
	public static final keyFloat = hash("Float");
	public static final keyBool = hash("Bool");
	public static final keyClass = hash("Class");
	public static final keyEnum = hash("Enum");
	public static final keyEnumValue = hash("EnumValue");
	public static final key___init__ = hash("__init__");
	public static final keyNew = hash("new");
	public static final keyQuestionmark = hash("?");
}
