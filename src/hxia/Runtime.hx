package hxia;

typedef Limits = {?fuelPerCall:Int, ?maxCallDepth:Int, ?maxAllocBytes:Int}

// Holds the sandboxed tier plus whichever trusted-fast backends the target supports;
// `load` selects per artifact by trust policy. Bodies are stubs.
class Runtime {
	public var modules(default, null):haxe.ds.ReadOnlyArray<Module>;

	public function new(host:Host, ?limits:Limits) {
		modules = [];
		throw new haxe.exceptions.NotImplementedException();
	}

	public function load(bytes:haxe.io.Bytes):Module
		throw new haxe.exceptions.NotImplementedException();

	public function loadFile(path:String):Module
		throw new haxe.exceptions.NotImplementedException();

	public function dispose():Void
		throw new haxe.exceptions.NotImplementedException();
}
