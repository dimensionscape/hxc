package hxia;

// A loaded script module. The shapes are the contract; bodies are stubs.
class Module {
	public var id(default, null):String;
	public var manifest(default, null):Manifest;

	function new() {}

	public function boot():Void
		throw new haxe.exceptions.NotImplementedException();

	public function run():Void
		throw new haxe.exceptions.NotImplementedException();

	public function make<T>(scriptClass:String, args:Array<Dynamic>):T
		throw new haxe.exceptions.NotImplementedException();

	public function func(dotPath:String):Dynamic
		throw new haxe.exceptions.NotImplementedException();
}
