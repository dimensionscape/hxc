package hxia.lower;

import hxia.interp.HostRegistry;
import hxia.interp.Mediator;

// The `$host` seam the lowered T1 code calls into, backed by the same HostRegistry (and therefore
// the same NeutralStd bindings) the T3 interpreter uses. Sharing the registry means a T1/T3
// difference is always a lowering difference, never two different std surfaces. The dispatch order
// follows Interp.callStatic/construct/callMember.
class JsHost implements hxia.ScriptWorld {
	final registry:HostRegistry;
	final mediator:Mediator;

	public function new(registry:HostRegistry, ?mediator:Mediator) {
		this.registry = registry;
		this.mediator = mediator != null ? mediator : new Mediator(null, function(t, m) return registry.memberBinding(t, m));
	}

	// The lowered module's script tables (classes, statics, static vars, enum descriptors) and its
	// $enum builder, handed over at load so reflection over a script type is answered by the script
	// world and the host can construct script enum values (Type.createEnum).
	var SC:Dynamic = null;
	var SS:Dynamic = null;
	var SV:Dynamic = null;
	var ED:Dynamic = null;
	var mkEnum:Dynamic = null;

	public function bindTables(sc:Dynamic, ss:Dynamic, sv:Dynamic, ?ed:Dynamic, ?mk:Dynamic):Void {
		this.SC = sc;
		this.SS = ss;
		this.SV = sv;
		this.ED = ed;
		this.mkEnum = mk;
	}

	// A host enum constructor referenced from the script (haxe.ds.Option.Some, ...): build the same
	// {__e, __i, __n, __p} wrapper the lowered module uses for its own enums, so a switch reads __i
	// off either kind identically - the interpreter's mkHostEnum. __he keeps the real Enum for the
	// boundary; no-arg constructors are interned so `None == None` holds.
	final hostEnumSingletons:Map<String, Dynamic> = new Map();

	public function hostEnum(type:String, ctor:String, args:Array<Dynamic>):Dynamic {
		var dotted = StringTools.replace(StringTools.startsWith(type, "::") ? type.substr(2) : type, "::", ".");
		var he = Type.resolveEnum(dotted);
		if (he == null)
			throw "hxia: cannot resolve host enum '" + dotted + "'";
		var idx = Type.getEnumConstructs(he).indexOf(ctor);
		if (idx < 0)
			throw "No such constructor " + ctor;
		if (args.length == 0) {
			var key = dotted + "." + ctor;
			var s = hostEnumSingletons.get(key);
			if (s == null) {
				s = mkWrapper(dotted, idx, ctor, [], he);
				hostEnumSingletons.set(key, s);
			}
			return s;
		}
		return mkWrapper(dotted, idx, ctor, args, he);
	}

	function mkWrapper(e:String, i:Int, n:String, p:Array<Dynamic>, he:Enum<Dynamic>):Dynamic {
		var o:Dynamic = {};
		Reflect.setField(o, "__e", e);
		Reflect.setField(o, "__i", i);
		Reflect.setField(o, "__n", n);
		Reflect.setField(o, "__p", p);
		Reflect.setField(o, "__he", he);
		return o;
	}

	static inline function isWrapper(v:Dynamic):Bool
		return v != null && Reflect.field(v, "__e") != null && Reflect.field(v, "__i") != null;

	// A host enum value RETURNED from a host call (Type.typeof -> ValueType, ...) is wrapped so the
	// lowered code's __Index reads and switches see the wrapper shape (the interpreter's wrapHostEnum).
	function wrapRet(v:Dynamic):Dynamic {
		if (v != null && !isWrapper(v) && Reflect.isEnumValue(v)) {
			var he = Type.getEnum(v);
			return mkWrapper(Type.getEnumName(he), Type.enumIndex(v), Type.enumConstructor(v),
				[for (p in Type.enumParameters(v)) wrapRet(p)], he);
		}
		return v;
	}

	// A host static: a registry binding first, else a reflective call on an authority-free std class
	// through the mediated seam (the same two-step the interpreter uses).
	public function callStatic(type:String, member:String, args:Array<Dynamic>):Dynamic {
		// Type.*/Reflect.* over a SCRIPT value cannot go to the host: a script instance is a plain JS
		// object of a generated constructor, so the host reflection sees nothing. Both are the shared
		// WorldReflect policy, answered through this class's ScriptWorld implementation.
		if (type == "Reflect" || type == "Type") {
			var handled = type == "Reflect"
				? hxia.WorldReflect.reflect(this, member, args)
				: hxia.WorldReflect.type(this, member, args);
			if (handled != hxia.WorldReflect.NotHandled)
				return handled;
		}
		// Std.isOfType with a RUNTIME token (the isTrue-loop shape): the token may be a script class
		// constructor, an interface, a script-enum descriptor, or a primitive name string ($classof falls
		// back to the type name when the host has no runtime Class, e.g. Int/Float on js).
		if (type == "Std") {
			switch (member) {
				case "isOfType":
					return stdIs(args[0], args[1]);
				case "downcast", "instance":
					return stdIs(args[0], args[1]) ? args[0] : null;
				case _:
			}
		}
		return wrapRet(hxia.HostCore.callStaticTail(registry, mediator, type, member, args));
	}

	public function construct(type:String, args:Array<Dynamic>):Dynamic {
		return hxia.HostCore.construct(registry, type, args);
	}

	public function callMember(o:Dynamic, member:String, args:Array<Dynamic>):Dynamic {
		// The cppia map remap (setString/getInt/...) applies only to map receivers; translating it
		// unconditionally would clobber same-named methods elsewhere (e.g. Bytes.getString).
		if (Std.isOfType(o, haxe.Constraints.IMap))
			member = hxia.HostCore.mapMethodShim(member);
		return wrapRet(mediator.callMethod(o, member, args));
	}


	public function getStatic(type:String, member:String):Dynamic {
		// Math's constants before the neutral reflective read: native js Math has no "NaN"/"PI" property,
		// so Reflect.field would return undefined and NaN comparisons silently change (undefined ==
		// undefined is true where NaN == NaN must be false).
		if (type == "Math") {
			switch (member) {
				case "NaN": return Math.NaN;
				case "POSITIVE_INFINITY": return Math.POSITIVE_INFINITY;
				case "NEGATIVE_INFINITY": return Math.NEGATIVE_INFINITY;
				case "PI": return Math.PI;
				case _:
			}
		}
		var neutral = registry.neutralStaticClass(type);
		if (neutral != null)
			return mediator.getField(neutral, member);
		var cls = Type.resolveClass(type);
		return cls != null ? mediator.getField(cls, member) : null;
	}

	// Std.isOfType against a runtime token of any world - the shared dispatch over T1 tokens.
	function stdIs(v:Dynamic, token:Dynamic):Bool
		return hxia.WorldReflect.isOfType(this, v, token);

	public function isOfTypeNamed(v:Dynamic, name:String):Bool
		return isOfType(v, name);

	public function instanceIsOfClass(v:Dynamic, className:String):Bool {
		var c = Reflect.field(SC, className);
		if (c != null && js.Syntax.instanceof(v, c))
			return true;
		// An interface: instances never chain to its constructor, so consult the __ifs flags.
		var ifs:Dynamic = Reflect.field(v, "__ifs");
		return ifs != null && Reflect.field(ifs, className) == true;
	}

	public function hostIsOfType(v:Dynamic, token:Dynamic):Bool
		return Std.isOfType(v, token);

	// A static write to a neutral-static host type reaches the real class (haxe.Serializer.USE_CACHE
	// must be visible to the shim's constructor), the interpreter's setStatic host fallback.
	public function setStatic(type:String, member:String, v:Dynamic):Dynamic {
		var neutral = registry.neutralStaticClass(type);
		if (neutral != null) {
			mediator.setField(neutral, member, v);
			return v;
		}
		var cls = Type.resolveClass(type);
		if (cls != null)
			mediator.setField(cls, member, v);
		return v;
	}

	// `is` against a host type, by name (the lowered code handles script classes itself).
	public function isOfType(v:Dynamic, t:String):Bool {
		var shim = hxia.HostCore.shimTypeNames(v);
		if (shim != null)
			return shim.indexOf(t) >= 0;
		return switch (t) {
			case "Dynamic": true;
			case "Int" | "UInt": Std.isOfType(v, Int);
			case "Float" | "Single": Std.isOfType(v, Float);
			case "Bool": Std.isOfType(v, Bool);
			// A class/enum descriptor used as a value is an instance of Class / Enum (and nothing
			// else) - the interpreter's PrimType.matches rule.
			case "Class": isScriptClass(v);
			case "Enum": isEnumDesc(v);
			case _:
				var cls = Type.resolveClass(t);
				cls != null && Std.isOfType(v, cls);
		};
	}

	// $bset masks a store into a Bytes backing array; the receiver test lives here because the
	// lowered JS cannot see the Haxe NeutralBytes class.
	public function isBytes(o:Dynamic):Bool
		return Std.isOfType(o, hxia.interp.NeutralBytes);

	// A type with no runtime Class on this host (Int/Float/Class/Enum on js) resolves to an interned
	// name TOKEN, not the raw string - a raw string would be indistinguishable from a string value
	// (Type.typeof(Class) must be TObject, never TClass(String)). The interpreter's PrimType.of.
	final primTokens:Map<String, Dynamic> = new Map();

	public function classOf(t:String):Dynamic {
		var cls = Type.resolveClass(t);
		if (cls != null)
			return cls;
		var tok = primTokens.get(t);
		if (tok == null) {
			tok = {__ptype: t};
			primTokens.set(t, tok);
		}
		return tok;
	}

	// ---- hxia.ScriptWorld: the tier-neutral script-value surface, answered with the lowered
	// module's tables and wrapper shapes. The script-aware serializer programs against this, so the
	// exact same serializer code runs on T1 and T3.
	public function isInstance(v:Dynamic):Bool
		return isScriptValue(v);

	public function instanceClassName(v:Dynamic):String
		return Reflect.field(v, "__cname");

	public function instanceFieldNames(v:Dynamic):Array<String>
		return Reflect.fields(v).filter(function(f) return f != "__sc" && f != "__cname" && f != "__b");

	public function getInstanceField(v:Dynamic, name:String):Dynamic
		return Reflect.field(v, name);

	public function setInstanceField(v:Dynamic, name:String, value:Dynamic):Void
		Reflect.setField(v, name, value);

	public function hasClass(name:String):Bool
		return SC != null && Reflect.field(SC, name) != null;

	public function createEmpty(name:String):Dynamic
		return Type.createEmptyInstance(Reflect.field(SC, name));

	public function isEnumVal(v:Dynamic):Bool
		return isWrapper(v);

	public function enumTypeName(v:Dynamic):String
		return Reflect.field(v, "__e");

	public function enumIndex(v:Dynamic):Int
		return Reflect.field(v, "__i");

	public function enumCtor(v:Dynamic):String
		return Reflect.field(v, "__n");

	public function enumParams(v:Dynamic):Array<Dynamic>
		return Reflect.field(v, "__p");

	public function hasEnum(name:String):Bool
		return ED != null && Reflect.field(ED, name) != null;

	public function ctorIndexOf(name:String, ctor:String):Int
		return (Reflect.field(Reflect.field(ED, name), "ctors") : Array<Dynamic>).indexOf(ctor);

	public function ctorNameOf(name:String, index:Int):String
		return (Reflect.field(Reflect.field(ED, name), "ctors") : Array<Dynamic>)[index];

	public function newEnum(name:String, index:Int, ctor:String, params:Array<Dynamic>):Dynamic
		return mkEnum(name, index, ctor, params);

	public function isClassToken(v:Dynamic):Bool
		return isScriptClass(v);

	public function isEnumToken(v:Dynamic):Bool
		return isEnumDesc(v);

	public function tokenName(v:Dynamic):String {
		var cn = Reflect.field(v, "__cname");
		return cn != null ? cn : Reflect.field(v, "__ename");
	}

	public function classToken(name:String):Dynamic
		return Reflect.field(SC, name);

	public function enumToken(name:String):Dynamic
		return Reflect.field(ED, name);

	// Plain JS property semantics: a member read finds prototype methods too (unbound), the
	// same access the pre-ScriptWorld Reflect cases used.
	public function memberRead(v:Dynamic, name:String):Dynamic
		return Reflect.field(v, name);

	public function memberWrite(v:Dynamic, name:String, value:Dynamic):Void
		Reflect.setField(v, name, value);

	public function hasInstanceField(v:Dynamic, name:String):Bool
		return Reflect.hasField(v, name) || Reflect.field(v, name) != null;

	public function accessor(v:Dynamic, name:String):Null<Array<Dynamic>->Dynamic> {
		var f = Reflect.field(v, name);
		if (!Reflect.isFunction(f))
			return null;
		return function(args) return Reflect.callMethod(v, f, args);
	}

	public function staticRead(name:String, field:String, prop:Bool):Dynamic {
		if (prop) {
			var g = Reflect.field(SS, name + ".get_" + field);
			if (g != null)
				return Reflect.callMethod(null, g, []);
		}
		return staticReadRaw(name, field);
	}

	public function staticWrite(name:String, field:String, value:Dynamic, prop:Bool):Void {
		if (prop) {
			var st = Reflect.field(SS, name + ".set_" + field);
			if (st != null) {
				Reflect.callMethod(null, st, [value]);
				return;
			}
		}
		Reflect.setField(SV, name + "." + field, value);
	}

	public function superClassName(name:String):Null<String> {
		var proto = Reflect.field(Reflect.field(SC, name), "prototype");
		var sp = untyped __js__("Object.getPrototypeOf")(proto);
		return (sp != null && Reflect.field(sp, "__cname") != null) ? Reflect.field(sp, "__cname") : null;
	}

	public function classInstanceFields(name:String):Array<String> {
		var cls = Reflect.field(SC, name);
		var lst:Array<String> = Reflect.field(cls, "__ifields");
		return lst != null ? lst.copy() : protoFields(cls);
	}

	public function classStaticFields(name:String):Array<String>
		return classFields(name);

	public function createInstance(name:String, args:Array<Dynamic>):Dynamic
		return instantiate(Reflect.field(SC, name), args);

	public function createDefaulted(name:String):Dynamic
		return instantiate(Reflect.field(SC, name), null);

	public function enumCtorNames(name:String):Array<String>
		return (Reflect.field(Reflect.field(ED, name), "ctors") : Array<String>).copy();

	public function ctorArityOf(name:String, index:Int):Int
		return (Reflect.field(Reflect.field(ED, name), "arity") : Array<Int>)[index];

	public function enumHostToken(v:Dynamic):Null<Enum<Dynamic>>
		return Reflect.field(v, "__he");

	public function newHostEnum(he:Enum<Dynamic>, name:String, index:Int, ctor:String, params:Array<Dynamic>):Dynamic
		return mkWrapper(name, index, ctor, params, he);

	public function isPrimToken(v:Dynamic):Bool
		return v != null && Reflect.field(v, "__ptype") != null;

	public function primTokenName(v:Dynamic):String
		return Reflect.field(v, "__ptype");

	// A script class is a generated JS constructor tagged __cname; its instances carry __sc. Anything
	// not involving one of those is left to the host (NotHandled).
	static var NotHandled:Dynamic = {hxiaNotHandled: true};

	// __sc lives on the prototype, so this must be a plain property read - Reflect.hasField only sees
	// own fields and would report false for every script instance.
	static inline function isScriptValue(v:Dynamic):Bool
		return v != null && Reflect.field(v, "__sc") == true;

	static inline function isScriptClass(c:Dynamic):Bool
		return c != null && Reflect.field(c, "__cname") != null && Reflect.isFunction(c);

	static inline function isEnumDesc(v:Dynamic):Bool
		return v != null && Reflect.field(v, "__ename") != null;

	// A static read: the var table first, then a static method as a value.
	function staticReadRaw(cn:String, name:String):Dynamic {
		var key = cn + "." + name;
		if (Reflect.hasField(SV, key))
			return Reflect.field(SV, key);
		return Reflect.field(SS, key);
	}

	function instantiate(cls:Dynamic, args:Null<Array<Dynamic>>):Dynamic {
		var o = Type.createEmptyInstance(cls);
		var ctor = Reflect.field(o, "__ctor");
		if (ctor != null && args != null)
			Reflect.callMethod(o, ctor, args);
		// createEmptyInstance skips the constructor, and cpp zero-initialises value-typed fields;
		// the lowered class carries those defaults (__vdef) so the cpp-compiled cppia's assertions
		// hold - the interpreter's emptyFieldDefault.
		if (args == null) {
			var vd = Reflect.field(cls, "__vdef");
			if (vd != null)
				for (f in Reflect.fields(vd))
					Reflect.setField(o, f, Reflect.field(vd, f));
		}
		return o;
	}

	// Static fields of a script class: the SS/SV keys with this class's prefix (method and var
	// statics respectively), matching the interpreter's ScriptClass.staticFields.
	function classFields(cn:String):Array<String> {
		var out:Array<String> = [];
		var prefix = cn + ".";
		for (k in Reflect.fields(SS))
			if (StringTools.startsWith(k, prefix) && k.indexOf(".", prefix.length) < 0)
				out.push(k.substr(prefix.length));
		for (k in Reflect.fields(SV))
			if (StringTools.startsWith(k, prefix) && k.indexOf(".", prefix.length) < 0) {
				var n = k.substr(prefix.length);
				if (n != "__meta__" && out.indexOf(n) < 0)
					out.push(n);
			}
		return out;
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
