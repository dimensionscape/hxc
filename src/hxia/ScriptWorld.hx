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
}
