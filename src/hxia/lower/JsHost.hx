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

	// The lowered module's script tables (classes, statics, static vars), handed over at load so
	// reflection over a script type is answered by the script world.
	var SC:Dynamic = null;

	public function bindTables(sc:Dynamic, ss:Dynamic, sv:Dynamic):Void
		this.SC = sc;

	// A host static: a registry binding first, else a reflective call on an authority-free std class
	// through the mediated seam (the same two-step the interpreter uses).
	public function callStatic(type:String, member:String, args:Array<Dynamic>):Dynamic {
		// Type.*/Reflect.* over a SCRIPT value cannot go to the host: a script instance is a plain JS
		// object of a generated constructor, so the host reflection sees nothing. Answer it here, the
		// way the interpreter's typeReflect does for its ScriptObject/ScriptClass descriptors.
		if (type == "Type" || type == "Reflect") {
			var handled = scriptReflect(type, member, args);
			if (handled != NotHandled)
				return handled;
		}
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

	// A script class is a generated JS constructor tagged __cname; its instances carry __sc. Anything
	// not involving one of those is left to the host (NotHandled).
	static var NotHandled:Dynamic = {hxiaNotHandled: true};

	// __sc lives on the prototype, so this must be a plain property read - Reflect.hasField only sees
	// own fields and would report false for every script instance.
	static inline function isScriptValue(v:Dynamic):Bool
		return v != null && Reflect.field(v, "__sc") == true;

	static inline function isScriptClass(c:Dynamic):Bool
		return c != null && Reflect.field(c, "__cname") != null && Reflect.isFunction(c);

	function scriptReflect(type:String, member:String, args:Array<Dynamic>):Dynamic {
		var a0:Dynamic = args.length > 0 ? args[0] : null;
		if (type == "Type") {
			switch (member) {
				case "getClass":
					if (isScriptValue(a0)) return Reflect.field(a0, "constructor");
				case "getClassName":
					if (isScriptClass(a0)) return Reflect.field(a0, "__cname");
				case "resolveClass":
					var c = Reflect.field(SC, a0);
					if (c != null) return c;
				case "createInstance":
					if (isScriptClass(a0)) return instantiate(a0, args[1]);
				case "createEmptyInstance":
					if (isScriptClass(a0)) return instantiate(a0, null);
				case "getInstanceFields":
					if (isScriptClass(a0)) return protoFields(a0);
				case "getSuperClass":
					if (isScriptClass(a0)) {
						var proto = Reflect.field(a0, "prototype");
						var sp = untyped __js__("Object.getPrototypeOf")(proto);
						return (sp != null && Reflect.field(sp, "__cname") != null) ? Reflect.field(sp, "constructor") : null;
					}
				case _:
			}
			return NotHandled;
		}
		// Reflect.* over a script instance is plain JS field access; the fields live on the object.
		switch (member) {
			case "field":
				if (isScriptValue(a0)) return Reflect.field(a0, args[1]);
			case "setField":
				if (isScriptValue(a0)) { Reflect.setField(a0, args[1], args[2]); return null; }
			case "fields":
				if (isScriptValue(a0)) return Reflect.fields(a0).filter(function(f) return f != "__sc" && f != "__cname");
			case "hasField":
				if (isScriptValue(a0)) return Reflect.hasField(a0, args[1]) || Reflect.field(a0, args[1]) != null;
			case _:
		}
		return NotHandled;
	}

	function instantiate(cls:Dynamic, args:Null<Array<Dynamic>>):Dynamic {
		var o = Type.createEmptyInstance(cls);
		var ctor = Reflect.field(o, "__ctor");
		if (ctor != null && args != null)
			Reflect.callMethod(o, ctor, args);
		return o;
	}

	// Instance fields of a script class: every enumerable name up the prototype chain, minus the
	// interpreter-facing tags, matching what Type.getInstanceFields reports for a script class.
	static function protoFields(cls:Dynamic):Array<String> {
		var out:Array<String> = [];
		var p:Dynamic = Reflect.field(cls, "prototype");
		while (p != null) {
			for (f in Reflect.fields(p))
				if (f != "__sc" && f != "__cname" && f != "constructor" && f != "__ctor" && out.indexOf(f) < 0)
					out.push(f);
			p = untyped __js__("Object.getPrototypeOf")(p);
		}
		return out;
	}
}
