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

	// Type.* policy over script classes/enums (which are not host types). Tokens and enum
	// values are recognized through the world; anything host-only returns NotHandled.
	public static function type(world:ScriptWorld, member:String, args:Array<Dynamic>):Dynamic {
		var a0:Dynamic = args.length > 0 ? args[0] : null;
		switch (member) {
			case "getClass":
				if (world.isInstance(a0)) return world.classToken(world.instanceClassName(a0));
				if (world.isEnumVal(a0)) return null;
			case "getClassName":
				if (a0 != null && world.isClassToken(a0)) return world.tokenName(a0);
				if (world.isPrimToken(a0)) return world.primTokenName(a0);
			case "getEnumName":
				if (a0 != null && world.isEnumToken(a0)) return world.tokenName(a0);
			case "resolveClass":
				if (world.hasClass(a0)) return world.classToken(a0);
			case "resolveEnum":
				if (world.hasEnum(a0)) return world.enumToken(a0);
			case "getSuperClass":
				if (a0 != null && world.isClassToken(a0)) {
					var s = world.superClassName(world.tokenName(a0));
					return s == null ? null : world.classToken(s);
				}
			case "getInstanceFields":
				if (a0 != null && world.isClassToken(a0)) return world.classInstanceFields(world.tokenName(a0));
			case "getClassFields":
				if (a0 != null && world.isClassToken(a0)) return world.classStaticFields(world.tokenName(a0));
			case "createInstance":
				if (a0 != null && world.isClassToken(a0)) return world.createInstance(world.tokenName(a0), args[1]);
			case "createEmptyInstance":
				if (a0 != null && world.isClassToken(a0)) return world.createDefaulted(world.tokenName(a0));
			case "getEnum":
				if (world.isEnumVal(a0)) {
					var h = world.enumHostToken(a0);
					return h != null ? h : world.enumToken(world.enumTypeName(a0));
				}
			case "getEnumConstructs":
				if (a0 != null && world.isEnumToken(a0)) return world.enumCtorNames(world.tokenName(a0));
			case "allEnums":
				// All no-argument constructor VALUES of a script enum, in declaration order.
				if (a0 != null && world.isEnumToken(a0)) {
					var en = world.tokenName(a0);
					var ctors = world.enumCtorNames(en);
					return [
						for (i in 0...ctors.length)
							if (world.ctorArityOf(en, i) == 0) world.newEnum(en, i, ctors[i], [])
					];
				}
			case "createEnum":
				if (a0 != null && world.isEnumToken(a0))
					return makeEnum(world, world.tokenName(a0), world.ctorIndexOf(world.tokenName(a0), args[1]), args[1], args[2]);
			case "createEnumIndex":
				if (a0 != null && world.isEnumToken(a0)) {
					var en = world.tokenName(a0);
					var idx:Int = args[1];
					var ctors = world.enumCtorNames(en);
					return makeEnum(world, en, idx, idx >= 0 && idx < ctors.length ? ctors[idx] : null, args[2]);
				}
			case "enumParameters":
				if (world.isEnumVal(a0)) return world.enumParams(a0).copy();
			case "enumConstructor":
				if (world.isEnumVal(a0)) return world.enumCtor(a0);
			case "enumIndex":
				if (world.isEnumVal(a0)) return world.enumIndex(a0);
			case "enumEq":
				if (world.isEnumVal(a0) || world.isEnumVal(args[1])) return enumEq(world, a0, args[1]);
			case "typeof":
				// Build the ValueType wrapper DIRECTLY through the world so the param survives
				// the boundary (host typeof on a script value would just say TObject, and on cpp
				// Type.enumParameters over a host enum holding a script Dynamic returns null).
				if (world.isInstance(a0))
					return mkValueType(world, "TClass", [world.classToken(world.instanceClassName(a0))]);
				if (world.isEnumVal(a0)) {
					var t = world.enumToken(world.enumTypeName(a0));
					return mkValueType(world, "TEnum", [t != null ? t : world.enumHostToken(a0)]);
				}
				// A class/enum/primitive token referenced as a value is a plain object: TObject.
				if (a0 != null && (world.isClassToken(a0) || world.isEnumToken(a0) || world.isPrimToken(a0)))
					return mkValueType(world, "TObject", []);
			case _:
		}
		return NotHandled;
	}

	// Std.isOfType/downcast against a RUNTIME token, which may belong to either world: a
	// primitive/name token, a script enum descriptor, a script class, or a host Class. The
	// dispatch order is the policy; each tier supplies the three leaf answers.
	public static function isOfType(world:ScriptWorld, v:Dynamic, token:Dynamic):Bool {
		// A null type is never matched (and TestReflect's isTrue does pass null).
		if (token == null)
			return false;
		// A type with no runtime Class resolves to a name token; a bare string reaches here
		// the same way from the lowered code's $classof fallback.
		if (world.isPrimToken(token))
			return world.isOfTypeNamed(v, world.primTokenName(token));
		if (Std.isOfType(token, String))
			return world.isOfTypeNamed(v, token);
		if (world.isEnumToken(token))
			return world.isEnumVal(v) && world.enumTypeName(v) == world.tokenName(token);
		if (world.isClassToken(token))
			return world.isInstance(v) && world.instanceIsOfClass(v, world.tokenName(token));
		// A script instance is never an instance of a host class.
		if (world.isInstance(v))
			return false;
		return world.hostIsOfType(v, token);
	}

	// Type.createEnum/createEnumIndex validation: both throw on an unknown constructor or a
	// wrong argument count (TestReflect asserts the throws), then build through the world so
	// no-arg values share the tier's interned singletons.
	static function makeEnum(world:ScriptWorld, en:String, index:Int, ctor:String, params:Array<Dynamic>):Dynamic {
		var ctors = world.enumCtorNames(en);
		if (index < 0 || index >= ctors.length)
			throw "No such constructor " + ctor;
		var np = params != null ? params.length : 0;
		if (np != world.ctorArityOf(en, index))
			throw "Invalid number of arguments : " + ctor;
		return world.newEnum(en, index, ctor, params != null ? params : []);
	}

	static function mkValueType(world:ScriptWorld, ctor:String, params:Array<Dynamic>):Dynamic {
		var vt:Enum<Dynamic> = Type.ValueType;
		return world.newHostEnum(vt, Type.getEnumName(vt), Type.getEnumConstructs(vt).indexOf(ctor), ctor, params);
	}

	// Structural equality over enum values of either world (either side may be a plain value). Two
	// wrappers of the same host enum can carry different type strings (a script- built value uses the
	// cppia string, a wrapped host return uses Type.getEnumName), so the host token is the canonical
	// identity when both sides have one.
	static function enumEq(world:ScriptWorld, a:Dynamic, b:Dynamic):Bool {
		if (!world.isEnumVal(a) || !world.isEnumVal(b))
			return a == b;
		var ha = world.enumHostToken(a), hb = world.enumHostToken(b);
		var sameType = (ha != null && hb != null) ? ha == hb : world.enumTypeName(a) == world.enumTypeName(b);
		if (!sameType || world.enumIndex(a) != world.enumIndex(b))
			return false;
		var pa = world.enumParams(a), pb = world.enumParams(b);
		if (pa.length != pb.length)
			return false;
		for (i in 0...pa.length)
			if (!enumEq(world, pa[i], pb[i]) && pa[i] != pb[i])
				return false;
		return true;
	}
}
