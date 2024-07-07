package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;

// The cppia host-side scriptable helpers. A `-D scriptable` build emits, per
// class, a `<class>__scriptable` dispatch subclass plus CPPIA_CALL trampolines so a compiled host can run
// cppia scripts that override its methods. These pure helpers classify a haxe type into the CppiaCtx
// push/get/run/return method suffix, the one-letter signature, and the stack-slot size type.
class CppScriptable {
	// The CppiaCtx accessor suffix for a value of this type (an optional
	// argument is boxed, so only String stays typed, everything else becomes Object).
	public static function scriptType(t:T, optional:Bool):String {
		// Keys off the "::"-prefixed C++ type text, which for the classify cases equals
		// tcppToString(cppTypeOf) - not CppiaGen.typeString, whose cppia bytecode naming drops the "::"
		// (String -> "String" not "::String").
		var s = CppTypeText.tcppToString(CppTypeOf.cppTypeOf(t));
		if (optional) return s == "::String" ? "String" : "Object";
		return switch (s) {
			case "bool": "Int";
			case "int" | "::cpp::Int32": "Int";
			case "Float": "Float";
			case "::String": "String";
			case "Null": "Void";
			// The type-string form yields "Void"; the tcpp form is the lowercase "void" - same slot.
			case "Void" | "void": "Void";
			case "float" | "::cpp::Float32" | "::cpp::Float64": "Float";
			case "::cpp::Int64" | "::cpp::UInt64": "Object";
			case _: "Object";
		};
	}

	// The one-letter signature code for a type.
	public static function scriptSignature(t:T, optional:Bool):String {
		return switch (scriptType(t, optional)) {
			case "Bool": "b";
			case "Int": "i";
			case "Float": "f";
			case "String": "s";
			case "Void" | "void": "v";
			case _: "o";
		};
	}

	// The C++ stack-slot type used to advance the CppiaCtx arg pointer.
	public static function scriptSizeType(t:T, optional:Bool):String {
		return switch (scriptType(t, optional)) {
			case "Object": "void *";
			case "Int": "int";
			case "Bool": "bool";
			case x: x;
		};
	}

	// A whole-generation map from an interface
	// method name to a slot id (counting up from 2). Shared across all classes; the boot table lists the
	// names sorted by id, and ScriptableRegisterNameSlots is passed the final count.
	public static var interfaceSlots:Map<String, Int> = new Map();
	public static var interfaceSlotCount:Int = 2;

	public static function resetInterfaceSlots():Void {
		interfaceSlots = new Map();
		interfaceSlotCount = 2;
	}

	// The slot for an interface method name, assigning the next id
	// on first sight.
	public static function cppGetInterfaceSlot(name:String):Int {
		if (interfaceSlots.exists(name)) return interfaceSlots.get(name);
		var result = interfaceSlotCount;
		interfaceSlots.set(name, result);
		interfaceSlotCount++;
		return result;
	}

	// Fold the class's own Method (non-dynamic, TFun) fields onto the base list; an override REPLACES
	// the base entry in place (keeping its slot), others prepend. The referenced-type walk
	// (CppReferenced) keeps only the set; the scriptable vtable needs this exact ordering because
	// cppia looks functions up by index.
	static function currentVirtualFunctionsRev(clazz:TClass, baseFunctions:Array<TClassField>):Array<TClassField> {
		var result = baseFunctions;
		for (elem in clazz.orderedFields) {
			switch [TypeFunctions.follow(elem.type), elem.kind] {
				case [_, Method(MethDynamic)]:
				case [TFun(_), Method(_)]:
					if (TypeFunctions.hasClassFieldFlag(elem, CfOverride) && Lambda.exists(result, function(e) return e.name == elem.name))
						result = [for (e in result) e.name == elem.name ? elem : e];
					else
						result = [elem].concat(result);
				case _:
			}
		}
		return result;
	}

	// currentVirtualFunctionsRev over the super chain (super first),
	// then reversed so the most-derived declaration order reads top-down.
	public static function allVirtualFunctions(clazz:TClass):Array<TClassField> {
		function rec(c:TClass):Array<TClassField>
			return currentVirtualFunctionsRev(c, c.superClass != null ? rec(c.superClass.c) : []);
		var r = rec(clazz);
		r.reverse();
		return r;
	}

	// This class's own virtual functions in declaration order (the __scriptableFunctions table indexes
	// these).
	public static function ownVirtualFunctions(clazz:TClass):Array<TClassField> {
		var r = currentVirtualFunctionsRev(clazz, []);
		r.reverse();
		return r;
	}
}
