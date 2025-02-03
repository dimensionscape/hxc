package hxia;

import hxia.interp.HostRegistry;
import hxia.interp.Mediator;

// Tier-neutral host dispatch policy shared by the T3 interpreter and the T1 js host: the
// pieces of the universal host API that never touch script-value representation (policy
// that does goes through ScriptWorld instead). A rule here lands on every tier at once,
// which is the point - these all started as duplicated code that had to be fixed twice.
class HostCore {
	// The cppia carries typed map methods (setInt/getString/...); they resolve to set/get
	// on the IMap interface. Apply only to map RECEIVERS - translating unconditionally
	// clobbers same-named methods elsewhere (e.g. Bytes.getString).
	public static function mapMethodShim(m:String):String {
		return switch (m) {
			case "setInt" | "setString" | "setFloat" | "setBool" | "setInt64" | "setObject": "set";
			case "getInt" | "getString" | "getFloat" | "getBool" | "getInt64" | "getObject": "get";
			case _: m;
		};
	}

	// The cppia flattens generic type params into the type name (`new Array<Object>()` ->
	// "Array.Object"), but constructors are registered under the base name. If the full
	// name is not bound, strip trailing param segments until a registered ctor is found.
	public static function construct(registry:HostRegistry, type:String, args:Array<Dynamic>):Dynamic {
		if (!registry.hasNew(type)) {
			var t = type;
			while (t.indexOf(".") >= 0) {
				t = t.substr(0, t.lastIndexOf("."));
				if (registry.hasNew(t))
					return registry.construct(t, args);
			}
		}
		return registry.construct(type, args);
	}

	// The host-static tail every tier ends dispatch with: a registry binding first, else a
	// reflective call on an authority-free (neutral-static) std class through the mediated
	// seam, else the registry's own miss handling (which raises the unbound-static error).
	public static function callStaticTail(registry:HostRegistry, mediator:Mediator, type:String, member:String,
			args:Array<Dynamic>):Dynamic {
		if (registry.hasStatic(type, member))
			return registry.staticCall(type, member, args);
		var neutral = registry.neutralStaticClass(type);
		if (neutral != null)
			return mediator.callMethod(neutral, member, args);
		return registry.staticCall(type, member, args);
	}
}
