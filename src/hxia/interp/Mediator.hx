package hxia.interp;

// The single seam through which the interpreter touches host values reflectively: member calls,
// field reads/writes, and script-level Reflect. Because all reflection goes through here (never raw
// Reflect scattered in the evaluator), a policy can actually confine authority: a script cannot
// reach a host member the policy denies, and it cannot bypass the check with its own Reflect calls.
// The default policy is permissive (the neutral std surface); a host tightens it.
class Mediator {
	// (hostTypeName, member) -> allowed?
	final policy:(String, String) -> Bool;
	// (typeName, member) -> typed instance binding, for methods reflection cannot reach.
	final memberResolver:Null<(String, String) -> Null<(Dynamic, Array<Dynamic>) -> Dynamic>>;

	public function new(?policy:(String, String) -> Bool,
			?memberResolver:(String, String) -> Null<(Dynamic, Array<Dynamic>) -> Dynamic>) {
		this.policy = policy != null ? policy : function(_, _) return true;
		this.memberResolver = memberResolver;
	}

	public function callMethod(obj:Dynamic, member:String, args:Array<Dynamic>):Dynamic {
		check(obj, member);
		if (memberResolver != null) {
			var bound = memberResolver(typeName(obj), member);
			if (bound != null)
				return bound(obj, args);
		}
		var fn = Reflect.field(obj, member);
		if (fn == null || !Reflect.isFunction(fn))
			throw new InterpError("hxia: host member " + typeName(obj) + "." + member
				+ " is not reflectively callable (inlined or DCE'd); bind it in the registry");
		return Reflect.callMethod(obj, fn, args);
	}

	// A method read as a value (`o.method` used as a closure): if the registry binds this member
	// as a typed call, return it bound to the receiver. Needed when the host method has no
	// reflective field (inline methods on js), so `o.iterator` / `o.hasNext` resolve to a
	// callable instead of undefined.
	public function methodValue(obj:Dynamic, member:String):Null<Dynamic> {
		if (memberResolver != null) {
			var bound = memberResolver(typeName(obj), member);
			if (bound != null)
				return Reflect.makeVarArgs(function(args:Array<Dynamic>) return bound(obj, args));
		}
		return null;
	}

	public function getField(obj:Dynamic, member:String):Dynamic {
		check(obj, member);
		return Reflect.field(obj, member);
	}

	public function setField(obj:Dynamic, member:String, value:Dynamic):Void {
		check(obj, member);
		Reflect.setField(obj, member, value);
	}

	public function fields(obj:Dynamic):Array<String>
		return Reflect.fields(obj);

	function check(obj:Dynamic, member:String):Void {
		var tn = typeName(obj);
		if (!policy(tn, member))
			throw new InterpError("hxia: reflective access to " + tn + "." + member + " denied by policy");
	}

	static function typeName(obj:Dynamic):String {
		if (obj == null)
			return "Null";
		var c = Type.getClass(obj);
		if (c != null) {
			var n = Type.getClassName(c);
			if (n != null)
				return n;
		}
		return switch (Type.typeof(obj)) {
			case TObject: "Anon";
			case TFunction: "Function";
			case _: "?";
		};
	}
}
