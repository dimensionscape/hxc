package hxia.lower;

import hxia.interp.HostRegistry;
import hxia.interp.Mediator;

// The `$host` seam the lowered T1 code calls into, backed by the same HostRegistry (and therefore
// the same NeutralStd bindings) the T3 interpreter uses. Sharing the registry means a T1/T3
// difference is always a lowering difference, never two different std surfaces. The dispatch order
// follows Interp.callStatic/construct/callMember.
class JsHost {
	final registry:HostRegistry;
	final mediator:Mediator;

	public function new(registry:HostRegistry) {
		this.registry = registry;
		this.mediator = new Mediator(null, function(t, m) return registry.memberBinding(t, m));
	}

	// A host static: a registry binding first, else a reflective call on an authority-free std class
	// through the mediated seam (the same two-step the interpreter uses).
	public function callStatic(type:String, member:String, args:Array<Dynamic>):Dynamic {
		if (registry.hasStatic(type, member))
			return registry.staticCall(type, member, args);
		var neutral = registry.neutralStaticClass(type);
		if (neutral != null)
			return mediator.callMethod(neutral, member, args);
		return registry.staticCall(type, member, args);
	}

	// The cppia flattens generic type params into the type name ("Array.Object"), but constructors
	// are registered under the base name; strip trailing segments until one is bound.
	public function construct(type:String, args:Array<Dynamic>):Dynamic {
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

	public function callMember(o:Dynamic, member:String, args:Array<Dynamic>):Dynamic {
		// The cppia map remap (setString/getInt/...) applies only to map receivers; translating it
		// unconditionally would clobber same-named methods elsewhere (e.g. Bytes.getString).
		if (Std.isOfType(o, haxe.Constraints.IMap))
			member = mapMethodShim(member);
		return mediator.callMethod(o, member, args);
	}

	static function mapMethodShim(m:String):String {
		return switch (m) {
			case "setInt" | "setString" | "setFloat" | "setBool" | "setInt64" | "setObject": "set";
			case "getInt" | "getString" | "getFloat" | "getBool" | "getInt64" | "getObject": "get";
			case _: m;
		};
	}

	public function getStatic(type:String, member:String):Dynamic {
		var neutral = registry.neutralStaticClass(type);
		if (neutral != null)
			return mediator.getField(neutral, member);
		// Math's constants are inline/property statics on js, so reflection reads null.
		if (type == "Math") {
			switch (member) {
				case "NaN": return Math.NaN;
				case "POSITIVE_INFINITY": return Math.POSITIVE_INFINITY;
				case "NEGATIVE_INFINITY": return Math.NEGATIVE_INFINITY;
				case "PI": return Math.PI;
				case _:
			}
		}
		var cls = Type.resolveClass(type);
		return cls != null ? mediator.getField(cls, member) : null;
	}

	// `is` against a host type, by name (the lowered code handles script classes itself).
	public function isOfType(v:Dynamic, t:String):Bool {
		return switch (t) {
			case "Dynamic": true;
			case "Int" | "UInt": Std.isOfType(v, Int);
			case "Float" | "Single": Std.isOfType(v, Float);
			case "Bool": Std.isOfType(v, Bool);
			case _:
				var cls = Type.resolveClass(t);
				cls != null && Std.isOfType(v, cls);
		};
	}

	public function classOf(t:String):Dynamic {
		var cls = Type.resolveClass(t);
		return cls != null ? (cls : Dynamic) : t;
	}
}
