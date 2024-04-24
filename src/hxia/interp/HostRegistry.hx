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

	public function new() {}

	public function bindMember(type:String, member:String, fn:(Dynamic, Array<Dynamic>) -> Dynamic):Void
		members.set(type + "." + member, fn);

	public function memberBinding(type:String, member:String):Null<(Dynamic, Array<Dynamic>) -> Dynamic>
		return members.get(type + "." + member);

	public function bindNew(type:String, fn:Array<Dynamic>->Dynamic):Void
		ctors.set(type, fn);

	public function construct(type:String, args:Array<Dynamic>):Dynamic {
		var fn = ctors.get(type);
		if (fn == null)
			throw new hxia.interp.InterpError("unbound host constructor " + type);
		return fn(args);
	}

	public function hasNew(type:String):Bool
		return ctors.exists(type);

	public function bindStatic(type:String, member:String, fn:Array<Dynamic>->Dynamic):Void
		statics.set(type + "." + member, fn);

	public function staticCall(type:String, member:String, args:Array<Dynamic>):Dynamic {
		var fn = statics.get(type + "." + member);
		if (fn == null)
			throw new hxia.interp.InterpError("unbound host static " + type + "." + member);
		return fn(args);
	}

	public function hasStatic(type:String, member:String):Bool
		return statics.exists(type + "." + member);
}
