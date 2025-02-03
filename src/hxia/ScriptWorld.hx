package hxia;

// The tier-neutral script-world interface: everything shared host policy needs to know about a
// tier's representation of script-defined values, and nothing else. The T3 interpreter answers
// with its ScriptObject/EnumValue/ScriptClass descriptors; the T1 js lowerer with its tagged
// prototypes, {__e,__i,__n,__p} wrappers, and SC/ED tables. Policy written against this interface
// (the script-aware serializer today; the reflection/dispatch layer as the universal host API
// consolidates) lands on every tier at once instead of being duplicated per host.
interface ScriptWorld {
	function isInstance(v:Dynamic):Bool;
	function instanceClassName(v:Dynamic):String;
	function instanceFieldNames(v:Dynamic):Array<String>;
	function getInstanceField(v:Dynamic, name:String):Dynamic;
	function setInstanceField(v:Dynamic, name:String, value:Dynamic):Void;
	function hasClass(name:String):Bool;
	// A blank instance with no constructor run and no field defaults (unserialization fills it).
	function createEmpty(name:String):Dynamic;

	function isEnumVal(v:Dynamic):Bool;
	function enumTypeName(v:Dynamic):String;
	function enumIndex(v:Dynamic):Int;
	function enumCtor(v:Dynamic):String;
	function enumParams(v:Dynamic):Array<Dynamic>;
	function hasEnum(name:String):Bool;
	function ctorIndexOf(name:String, ctor:String):Int;
	function ctorNameOf(name:String, index:Int):String;
	function newEnum(name:String, index:Int, ctor:String, params:Array<Dynamic>):Dynamic;

	// Class/enum type tokens (a type referenced as a value).
	function isClassToken(v:Dynamic):Bool;
	function isEnumToken(v:Dynamic):Bool;
	function tokenName(v:Dynamic):String;
	function classToken(name:String):Dynamic;
	function enumToken(name:String):Dynamic;

	// Member access with the tier's full lookup semantics (fields and methods; T3 binds through its
	// descriptor, T1 through the prototype chain) - unlike getInstanceField, which is the raw
	// own-field read unserialization uses.
	function memberRead(v:Dynamic, name:String):Dynamic;
	function memberWrite(v:Dynamic, name:String, value:Dynamic):Void;
	// Own field or class member - Reflect.hasField over a script instance.
	function hasInstanceField(v:Dynamic, name:String):Bool;
	// A bound invoker for a method visible on the instance, or null when there is none
	// (how shared code runs get_/set_ property accessors without seeing the representation).
	function accessor(v:Dynamic, name:String):Null<Array<Dynamic>->Dynamic>;
	// Static field access on a script class by name; prop routes through a get_/set_
	// accessor when one exists (Reflect.getProperty/setProperty vs field/setField).
	function staticRead(name:String, field:String, prop:Bool):Dynamic;
	function staticWrite(name:String, field:String, value:Dynamic, prop:Bool):Void;

	// Class shape, for Type.* over a script class.
	function superClassName(name:String):Null<String>;
	function classInstanceFields(name:String):Array<String>;
	function classStaticFields(name:String):Array<String>;
	function createInstance(name:String, args:Array<Dynamic>):Dynamic;
	// createEmptyInstance: no constructor, but value-typed fields carry their zero defaults
	// (cpp zero-initialises them, and the corpus asserts it).
	function createDefaulted(name:String):Dynamic;

	// Enum shape, for Type.* over a script enum.
	function enumCtorNames(name:String):Array<String>;
	function ctorArityOf(name:String, index:Int):Int;
	// The real host Enum behind a wrapped host-enum value, or null for a script enum value.
	function enumHostToken(v:Dynamic):Null<Enum<Dynamic>>;
	function newHostEnum(he:Enum<Dynamic>, name:String, index:Int, ctor:String, params:Array<Dynamic>):Dynamic;

	// A type with no runtime Class on the host (Int/Float/Class/Enum on js) is carried as an interned
	// name token, never a raw string - a raw string is indistinguishable from a string value, and
	// Type.typeof(Class) must be TObject, not TClass(String).
	function isPrimToken(v:Dynamic):Bool;
	function primTokenName(v:Dynamic):String;

	// The three leaf answers of the shared isOfType dispatch: by compile-time type name, a script
	// instance against a script class name (super chain + interfaces), and the tier's host-side
	// fallback for a token that belongs to neither script world.
	function isOfTypeNamed(v:Dynamic, name:String):Bool;
	function instanceIsOfClass(v:Dynamic, className:String):Bool;
	function hostIsOfType(v:Dynamic, token:Dynamic):Bool;
}
