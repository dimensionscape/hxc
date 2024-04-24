package hxia.interp;

// The single seam through which the interpreter touches host values reflectively: member calls,
// field reads/writes, and script-level Reflect. Because all reflection goes through here (never raw
// Reflect scattered in the evaluator), a policy can actually confine authority: a script cannot
// reach a host member the policy denies, and it cannot bypass the check with its own Reflect calls.
// The default policy is permissive (the neutral std surface); a host tightens it.
class Mediator {
	// (hostTypeName, member) -> allowed?
	final policy:(String, String) -> Bool;

	public function new(?policy:(String, String) -> Bool) {
		this.policy = policy != null ? policy : function(_, _) return true;
	}

	public function callMethod(obj:Dynamic, member:String, args:Array<Dynamic>):Dynamic {
		check(obj, member);
		return Reflect.callMethod(obj, Reflect.field(obj, member), args);
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
