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
		// object of a generated constructor, so the host reflection sees nothing. Answer it here, the
		// way the interpreter's typeReflect does for its ScriptObject/ScriptClass descriptors.
		if (type == "Type" || type == "Reflect") {
			var handled = scriptReflect(type, member, args);
			if (handled != NotHandled)
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
		if (registry.hasStatic(type, member))
			return wrapRet(registry.staticCall(type, member, args));
		var neutral = registry.neutralStaticClass(type);
		if (neutral != null)
			return wrapRet(mediator.callMethod(neutral, member, args));
		return wrapRet(registry.staticCall(type, member, args));
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
		return wrapRet(mediator.callMethod(o, member, args));
	}

	static function mapMethodShim(m:String):String {
		return switch (m) {
			case "setInt" | "setString" | "setFloat" | "setBool" | "setInt64" | "setObject": "set";
			case "getInt" | "getString" | "getFloat" | "getBool" | "getInt64" | "getObject": "get";
			case _: m;
		};
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

	// Std.isOfType against a runtime token of any world - mirrors the interpreter's scriptIsOfType.
	function stdIs(v:Dynamic, token:Dynamic):Bool {
		if (token == null)
			return false;
		if (Std.isOfType(token, String))
			return isOfType(v, token);
		var pt = Reflect.field(token, "__ptype");
		if (pt != null)
			return isOfType(v, pt);
		if (isScriptClass(token)) {
			if (js.Syntax.instanceof(v, token))
				return true;
			// An interface constructor: instances never chain to it, so consult the __ifs flags.
			var ifs:Dynamic = v != null ? Reflect.field(v, "__ifs") : null;
			return ifs != null && Reflect.field(ifs, Reflect.field(token, "__cname")) == true;
		}
		if (isEnumDesc(token))
			return isWrapper(v) && Reflect.field(v, "__e") == Reflect.field(token, "__ename");
		return Std.isOfType(v, token);
	}

	// `is` against a host type, by name (the lowered code handles script classes itself).
	public function isOfType(v:Dynamic, t:String):Bool {
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

	function scriptReflect(type:String, member:String, args:Array<Dynamic>):Dynamic {
		var a0:Dynamic = args.length > 0 ? args[0] : null;
		if (type == "Type") {
			// Enum reflection over the wrapper shape / script-enum descriptors.
			switch (member) {
				case "typeof":
					// Build the ValueType wrapper DIRECTLY so the param survives (the interpreter's mkValueType):
					// host typeof on a script value would just say TObject, and a class/enum token used as a value
					// is TObject.
					if (isScriptValue(a0)) return mkValueType("TClass", [Reflect.field(a0, "constructor")]);
					if (isWrapper(a0)) {
						var d = ED != null ? Reflect.field(ED, Reflect.field(a0, "__e")) : null;
						return mkValueType("TEnum", [d != null ? d : Reflect.field(a0, "__he")]);
					}
					if (isScriptClass(a0) || isEnumDesc(a0) || (a0 != null && Reflect.field(a0, "__ptype") != null))
						return mkValueType("TObject", []);
				case "enumIndex":
					if (isWrapper(a0)) return Reflect.field(a0, "__i");
				case "enumConstructor":
					if (isWrapper(a0)) return Reflect.field(a0, "__n");
				case "enumParameters":
					if (isWrapper(a0)) return (Reflect.field(a0, "__p") : Array<Dynamic>).copy();
				case "enumEq":
					if (isWrapper(a0) || isWrapper(args[1])) return enumEq(a0, args[1]);
				case "getEnum":
					if (isWrapper(a0)) {
						var he = Reflect.field(a0, "__he");
						if (he != null) return he;
						return Reflect.field(ED, Reflect.field(a0, "__e"));
					}
				case "getEnumName":
					if (isEnumDesc(a0)) return Reflect.field(a0, "__ename");
				case "resolveEnum":
					var d = ED != null ? Reflect.field(ED, a0) : null;
					if (d != null) return d;
				case "getEnumConstructs":
					if (isEnumDesc(a0)) return (Reflect.field(a0, "ctors") : Array<Dynamic>).copy();
				case "createEnum":
					if (isEnumDesc(a0)) return createScriptEnum(a0, args[1], args[2]);
				case "createEnumIndex":
					if (isEnumDesc(a0)) {
						var ctors:Array<Dynamic> = Reflect.field(a0, "ctors");
						return createScriptEnum(a0, ctors[args[1]], args[2]);
					}
				case _:
			}
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
					if (isScriptClass(a0)) {
						var lst:Array<Dynamic> = Reflect.field(a0, "__ifields");
						return lst != null ? lst.copy() : protoFields(a0);
					}
				case "getClassFields":
					if (isScriptClass(a0)) return classFields(Reflect.field(a0, "__cname"));
				case "allEnums":
					if (isEnumDesc(a0)) {
						var ctors:Array<Dynamic> = Reflect.field(a0, "ctors");
						var arity:Array<Dynamic> = Reflect.field(a0, "arity");
						var en = Reflect.field(a0, "__ename");
						return [for (i in 0...ctors.length) if (arity[i] == 0) mkEnum(en, i, ctors[i], [])];
					}
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
		// Reflect.* over a script instance is plain JS field access; the fields live on the object. A
		// script class receiver is a static access answered from the SS/SV tables, and getProperty/
		// setProperty run the get_/set_ accessor when one exists - the interpreter's staticGet/ property
		// routing.
		switch (member) {
			case "field":
				if (isScriptValue(a0)) return Reflect.field(a0, args[1]);
				if (isScriptClass(a0)) return staticRead(Reflect.field(a0, "__cname"), args[1]);
			case "setField":
				if (isScriptValue(a0)) { Reflect.setField(a0, args[1], args[2]); return null; }
				if (isScriptClass(a0)) { Reflect.setField(SV, Reflect.field(a0, "__cname") + "." + args[1], args[2]); return null; }
			case "getProperty":
				if (isScriptValue(a0)) {
					var g = Reflect.field(a0, "get_" + args[1]);
					if (Reflect.isFunction(g)) return Reflect.callMethod(a0, g, []);
					return Reflect.field(a0, args[1]);
				}
				if (isScriptClass(a0)) {
					var cn = Reflect.field(a0, "__cname");
					var g = Reflect.field(SS, cn + ".get_" + args[1]);
					if (g != null) return Reflect.callMethod(null, g, []);
					return staticRead(cn, args[1]);
				}
			case "setProperty":
				if (isScriptValue(a0)) {
					var st = Reflect.field(a0, "set_" + args[1]);
					if (Reflect.isFunction(st)) { Reflect.callMethod(a0, st, [args[2]]); return null; }
					Reflect.setField(a0, args[1], args[2]);
					return null;
				}
				if (isScriptClass(a0)) {
					var cn = Reflect.field(a0, "__cname");
					var st = Reflect.field(SS, cn + ".set_" + args[1]);
					if (st != null) { Reflect.callMethod(null, st, [args[2]]); return null; }
					Reflect.setField(SV, cn + "." + args[1], args[2]);
					return null;
				}
			case "fields":
				if (isScriptValue(a0)) return Reflect.fields(a0).filter(function(f) return f != "__sc" && f != "__cname" && f != "__b");
			case "hasField":
				if (isScriptValue(a0)) return Reflect.hasField(a0, args[1]) || Reflect.field(a0, args[1]) != null;
			case _:
		}
		return NotHandled;
	}

	// Type.createEnum over a script-enum descriptor: validate the constructor and arity (the
	// interpreter's makeEnum throws on both), then build via the module's $enum so no-arg values
	// share the module's interned singletons.
	function createScriptEnum(desc:Dynamic, ctor:String, ?params:Array<Dynamic>):Dynamic {
		var ctors:Array<Dynamic> = Reflect.field(desc, "ctors");
		var idx = ctors.indexOf(ctor);
		if (idx < 0)
			throw "No such constructor " + ctor;
		var arity:Array<Dynamic> = Reflect.field(desc, "arity");
		var np = params != null ? params.length : 0;
		if (np != arity[idx])
			throw "Invalid number of arguments : " + ctor;
		return mkEnum(Reflect.field(desc, "__ename"), idx, ctor, params != null ? params : []);
	}

	function mkValueType(ctor:String, params:Array<Dynamic>):Dynamic {
		var vt:Enum<Dynamic> = Type.ValueType;
		return mkWrapper(Type.getEnumName(vt), Type.getEnumConstructs(vt).indexOf(ctor), ctor, params, vt);
	}

	// Structural equality over the wrapper shape (either side may be a plain value).
	function enumEq(a:Dynamic, b:Dynamic):Bool {
		if (!isWrapper(a) || !isWrapper(b))
			return a == b;
		if (Reflect.field(a, "__e") != Reflect.field(b, "__e") || Reflect.field(a, "__i") != Reflect.field(b, "__i"))
			return false;
		var pa:Array<Dynamic> = Reflect.field(a, "__p");
		var pb:Array<Dynamic> = Reflect.field(b, "__p");
		if (pa.length != pb.length)
			return false;
		for (i in 0...pa.length)
			if (!enumEq(pa[i], pb[i]) && pa[i] != pb[i])
				return false;
		return true;
	}

	// A static read: the var table first, then a static method as a value.
	function staticRead(cn:String, name:String):Dynamic {
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
