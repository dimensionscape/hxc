package hxia;

// Reflect.* policy over script values, written once against ScriptWorld and shared by the
// T3 interpreter and the T1 js host (the universal-host-API convergence: a rule here lands
// on every tier at once). Anything not involving a script value returns NotHandled and the
// tier's host path owns it.
class WorldReflect {
	// Distinct from a handled call that legitimately returns null.
	public static final NotHandled:Dynamic = {hxiaNotHandled: true};

	public static function reflect(world:ScriptWorld, member:String, args:Array<Dynamic>):Dynamic {
		var a0:Dynamic = args.length > 0 ? args[0] : null;
		var inst = a0 != null && world.isInstance(a0);
		var cls = a0 != null && world.isClassToken(a0);
		switch (member) {
			case "field":
				if (cls) return world.staticRead(world.tokenName(a0), args[1], false);
				if (inst) return world.memberRead(a0, args[1]);
			case "setField":
				if (cls) { world.staticWrite(world.tokenName(a0), args[1], args[2], false); return null; }
				if (inst) { world.memberWrite(a0, args[1], args[2]); return null; }
			case "getProperty":
				if (cls) return world.staticRead(world.tokenName(a0), args[1], true);
				if (inst) {
					// A property read must run its get_<name> accessor, not read the raw field:
					// a pure property has no backing field and a computed one differs from it.
					var get = world.accessor(a0, "get_" + args[1]);
					if (get != null) return get([]);
					return world.memberRead(a0, args[1]);
				}
			case "setProperty":
				if (cls) { world.staticWrite(world.tokenName(a0), args[1], args[2], true); return null; }
				if (inst) {
					var set = world.accessor(a0, "set_" + args[1]);
					if (set != null) { set([args[2]]); return null; }
					world.memberWrite(a0, args[1], args[2]);
					return null;
				}
			case "fields":
				if (inst) return world.instanceFieldNames(a0);
			case "hasField":
				if (inst) return world.hasInstanceField(a0, args[1]);
			case "isEnumValue":
				return world.isEnumVal(a0) || Reflect.isEnumValue(a0);
			case _:
		}
		return NotHandled;
	}
}
