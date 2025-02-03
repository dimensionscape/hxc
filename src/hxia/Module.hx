package hxia;

import hxia.Errors;

// A loaded script module: one artifact in its own namespace. Type identity is (module, dotted
// path), so two modules may define the same path without conflict (PLATFORM.md section 4) -
// nothing here consults a global type registry, only this module's own world.
//
// Tier-agnostic by construction: everything it can do is expressed through ScriptWorld plus
// the two entry closures the Runtime supplies for the tier it chose.
class Module {
	public var id(default, null):String;
	public var manifest(default, null):Manifest;
	// Which tier actually backs this module ("T3" sandboxed interpreter, "T1" lowered js).
	public var tier(default, null):String;
	public var world(default, null):ScriptWorld;

	final bootFn:Void->Void;
	final runFn:Void->Void;
	var didBoot = false;
	var didRun = false;

	public function new(id:String, manifest:Manifest, tier:String, world:ScriptWorld, bootFn:Void->Void, runFn:Void->Void) {
		this.id = id;
		this.manifest = manifest;
		this.tier = tier;
		this.world = world;
		this.bootFn = bootFn;
		this.runFn = runFn;
	}

	// Statics and class initializers. Explicit and deterministic: the host decides the order
	// across modules, and boot never runs main.
	public function boot():Void {
		if (didBoot)
			return;
		didBoot = true;
		bootFn();
	}

	// The artifact's entry point. Boots first if the host did not.
	public function run():Void {
		boot();
		if (didRun)
			return;
		didRun = true;
		runFn();
	}

	public function has(scriptClass:String):Bool
		return world.hasClass(scriptClass);

	// Construct a script class. The result is a script value of this module's world; a host
	// holds it as an opaque handle and reaches into it with method/field below (or through an
	// interface seam the script implements).
	public function make<T>(scriptClass:String, args:Array<Dynamic>):T {
		boot();
		if (!world.hasClass(scriptClass))
			throw new LinkError([scriptClass]);
		return cast world.createInstance(scriptClass, args != null ? args : []);
	}

	// A bound instance method, or null when the class has no such method.
	public function method(obj:Dynamic, name:String):Null<Array<Dynamic>->Dynamic>
		return world.accessor(obj, name);

	public function call(obj:Dynamic, name:String, ?args:Array<Dynamic>):Dynamic {
		var m = world.accessor(obj, name);
		if (m == null)
			throw new LinkError([world.instanceClassName(obj) + "." + name]);
		return m(args != null ? args : []);
	}

	public function get(obj:Dynamic, field:String):Dynamic
		return world.memberRead(obj, field);

	public function set(obj:Dynamic, field:String, value:Dynamic):Void
		world.memberWrite(obj, field, value);

	// A script static field: `stat("pkg.Class.field")`. Property accessors run when the
	// script declares them, so the host sees the value the script would.
	public function stat(dotPath:String):Dynamic {
		boot();
		var s = split(dotPath);
		return world.staticRead(s.cls, s.name, true);
	}

	public function setStat(dotPath:String, value:Dynamic):Void {
		boot();
		var s = split(dotPath);
		world.staticWrite(s.cls, s.name, value, true);
	}

	// A script static function as a host callable: `func("pkg.Class.method")`.
	public function func(dotPath:String):Dynamic {
		boot();
		var s = split(dotPath);
		var f = world.staticRead(s.cls, s.name, false);
		if (f == null || !Reflect.isFunction(f))
			throw new LinkError([dotPath]);
		return f;
	}

	function split(dotPath:String):{cls:String, name:String} {
		var dot = dotPath.lastIndexOf(".");
		if (dot < 0)
			throw new LinkError([dotPath]);
		var cls = dotPath.substr(0, dot);
		if (!world.hasClass(cls))
			throw new LinkError([cls]);
		return {cls: cls, name: dotPath.substr(dot + 1)};
	}

	public function invoke(dotPath:String, ?args:Array<Dynamic>):Dynamic
		return Reflect.callMethod(null, func(dotPath), args != null ? args : []);
}
