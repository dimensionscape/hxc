package hxia.interp;

// The capability boundary: maps a script's static/host references to real host bindings.
// A binding it does not hold does not exist for the script; everything a script can call
// goes through here.
class HostRegistry {
	// Key "Type.member" -> (args)->result for static calls.
	final statics:Map<String, Array<Dynamic>->Dynamic> = new Map();
	// Dotted type path -> (args)->instance for `new`.
	final ctors:Map<String, Array<Dynamic>->Dynamic> = new Map();
	// "Type.member" -> (obj, args)->result: typed instance-method bindings for host types
	// whose methods are inlined/DCE'd on some targets (e.g. haxe.ds map .set/.get on js), so
	// reflective dispatch cannot reach them.
	final members:Map<String, (Dynamic, Array<Dynamic>) -> Dynamic> = new Map();
	// Authority-free std classes whose statics may resolve reflectively (Math/Lambda/StringTools
	// /Reflect/Type/...). This is still an explicit allow-list: authority-bearing classes (Sys, File)
	// are not marked, so they stay confined to their hand-bound, mediated surface. The value is the
	// actual Class handle: passing it keeps the class alive through the host's DCE (a name string
	// alone would let DCE drop a class the script needs) and avoids a lookup.
	final neutralStatics:Map<String, Class<Dynamic>> = new Map();
	// Every type name this registry holds any binding for. The load-time link check asks the question
	// at type granularity ("can this module reach Sys at all"), which the per-member maps cannot
	// answer without a scan.
	final types:Map<String, Bool> = new Map();

	public function new() {}

	public function knowsType(type:String):Bool
		return types.exists(type);

	// Declare a type reachable without binding anything on it. Interfaces are the case that
	// needs this: a script names haxe.IMap in a signature or an `is` test, so the load-time
	// link check must resolve it, but there is no static, member or constructor to bind.
	public function knowType(type:String):Void
		types.set(type, true);

	public function markNeutralStatic(type:String, cls:Class<Dynamic>):Void {
		neutralStatics.set(type, cls);
		types.set(type, true);
	}

	public function neutralStaticClass(type:String):Null<Class<Dynamic>>
		return neutralStatics.get(type);

	public function bindMember(type:String, member:String, fn:(Dynamic, Array<Dynamic>) -> Dynamic):Void {
		members.set(type + "." + member, fn);
		types.set(type, true);
	}

	public function memberBinding(type:String, member:String):Null<(Dynamic, Array<Dynamic>) -> Dynamic>
		return members.get(type + "." + member);

	public function bindNew(type:String, fn:Array<Dynamic>->Dynamic):Void {
		ctors.set(type, fn);
		types.set(type, true);
	}

	public function construct(type:String, args:Array<Dynamic>):Dynamic {
		var fn = ctors.get(type);
		if (fn == null)
			throw new hxia.interp.InterpError("unbound host constructor " + type);
		return fn(args);
	}

	public function hasNew(type:String):Bool
		return ctors.exists(type);

	public function bindStatic(type:String, member:String, fn:Array<Dynamic>->Dynamic):Void {
		statics.set(type + "." + member, fn);
		types.set(type, true);
	}

	public function staticCall(type:String, member:String, args:Array<Dynamic>):Dynamic {
		var fn = statics.get(type + "." + member);
		if (fn == null)
			throw new hxia.interp.InterpError("unbound host static " + type + "." + member);
		return fn(args);
	}

	public function hasStatic(type:String, member:String):Bool
		return statics.exists(type + "." + member);
}
