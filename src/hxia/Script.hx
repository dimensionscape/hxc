package hxia;

// Script-facing introspection and structured host messaging. Tiny by design: plain Haxe std is the
// script API; the profile decides what resolves.
class Script {
	public static var hosted(default, null):Bool = false;
	public static var granted(default, null):haxe.ds.ReadOnlyArray<String> = [];

	public static function post(topic:String, data:Dynamic):Void
		throw new haxe.exceptions.NotImplementedException();
}
