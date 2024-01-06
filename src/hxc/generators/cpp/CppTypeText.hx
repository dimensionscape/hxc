package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals.Path;
import hxc.ast.Ast;
import hxc.generators.cpp.CppType;
import hxc.generators.cpp.CppTypeOf;

// hxc.generators.cpp.CppTypeText: render a CppType as its C++ type text, plus the
// name and path remappers and the internal/known member gates. Used by the retype TCast
// same-type check and by the C++ emitter.
class CppTypeText {
	public static function isInternalMember(member:String):Bool {
		if (member == "toString") return true;
		if (member.length > 1 && member.substr(0, 2) == "__") {
			return switch (member) {
				case "__ArgCount" | "__ArrayImplRef" | "__CStr" | "__Compare" | "__Create"
					| "__CreateEmpty" | "__FieldRef" | "__FindArgCount"
					| "__GetFieldMap" | "__GetHandle" | "__GetItem"
					| "__GetScriptCallable" | "__GetScriptVTable"
					| "__Param" | "__Remove" | "__SGetClass"
					| "__Set" | "__SetItem" | "__TArrayImplRef"
					| "__ToDouble" | "__ToInt" | "__ToInterface" | "__ToObject"
					| "__Visit" | "__WCStr" | "__a" | "__blit" | "__boot"
					| "__boot_all" | "__compare" | "__concat" | "__construct" | "__copy"
					| "__filter" | "__get_args" | "__hx_dump_stack" | "__hx_field_iter" | "__hxt_gc_new"
					| "__indexOf" | "__insert" | "__instanceof" | "__int" | "__iterator"
					| "__join" | "__lastIndexOf" | "__loadprim" | "__mClass" | "__mDynamicFields"
					| "__map" | "__memcmp" | "__new" | "__pop" | "__prime"
					| "__push" | "__qsort" | "__unshift" | "__unsafeStringReference" | "__time_stamp"
					| "__superString" | "__splice" | "__shift" | "__slice" | "__sort"
					| "__s_id" | "__run" | "__root" | "__register" | "__remove"
					| "__removeAt" | "__reverse" | "__zero"
					| "__Field" | "__IField" | "__Run" | "__Is" | "__GetClass" | "__GetType" | "__ToString"
					| "__s" | "__GetPtr" | "__SetField" | "__length" | "__IsArray" | "__SetThis" | "__Internal"
					| "__EnumParams" | "__Index" | "__Tag" | "__GetFields" | "__HasField"
					| "__get" | "__set" | "__unsafe_get" | "__unsafe_set" | "__global__"
					| "__SetSize" | "__trace" | "__GetRealObject" | "__SetSizeExact" | "__cpp__"
					| "__URLEncode" | "__URLDecode" | "__IsEnum": true;
				case _: member.length > 4 && member.substr(0, 4) == "__hx";
			}
		}
		return false;
	}

	public static inline function isKnownMember(member:String):Bool {
		return member == "__meta__" || member == "__rtti" || member == "_Compare";
	}

	// Rename identifiers that clash with C++ keywords/macros
	public static function keywordRemap(name:String):String {
		if (isInternalMember(name) || isKnownMember(name)) return name;
		if (name.length > 1 && name.substr(0, 2) == "__") return "_hx_" + name;
		return switch (name) {
			case "int" | "Int" | "Bool" | "super"
				| "auto" | "char" | "const" | "delete" | "double" | "Float" | "enum"
				| "extern" | "float" | "friend" | "goto" | "long" | "operator" | "protected"
				| "register" | "short" | "signed" | "sizeof" | "template" | "typedef"
				| "union" | "unsigned" | "void" | "volatile" | "or" | "and" | "xor" | "or_eq" | "not"
				| "and_eq" | "xor_eq" | "typeof" | "stdin" | "stdout" | "stderr" | "system"
				| "BIG_ENDIAN" | "LITTLE_ENDIAN" | "assert" | "NULL" | "wchar_t" | "EOF"
				| "bool" | "const_cast" | "dynamic_cast" | "explicit" | "export" | "mutable" | "namespace"
				| "reinterpret_cast" | "static_cast" | "typeid" | "typename" | "virtual"
				| "_Complex" | "INFINITY" | "NAN"
				| "INT_MIN" | "INT_MAX" | "INT8_MIN" | "INT8_MAX" | "UINT8_MAX" | "INT16_MIN"
				| "INT16_MAX" | "UINT16_MAX" | "INT32_MIN" | "INT32_MAX" | "UINT32_MAX"
				| "asm" | "near" | "far" | "_w64"
				| "HX_" | "HXLINE" | "HXDLIN"
				| "NO" | "YES"
				| "abstract" | "decltype" | "finally" | "nullptr" | "static_assert"
				| "struct": "_hx_" + name;
			case x: x;
		}
	}

	static function pathRemap(withKeywords:Bool, name:String):String {
		var len = name.length;
		if (len > 3 && name.substr(0, 3) == " ::") return name.substr(3);
		if (len > 2 && name.substr(0, 2) == "::") return name.substr(2);
		return withKeywords ? keywordRemap(name) : name;
	}

	public static function remapClassPath(path:Path):Path {
		return {pack: [for (p in path.pack) pathRemap(true, p)], name: pathRemap(false, path.name)};
	}

	public static function joinClassPathRemap(path:Path, sep:String):String {
		var r = CppTypeOf.joinClassPath(remapClassPath(path), sep);
		return r == "Class" ? "hx::Class" : r;
	}

	public static function cppClassPathOf(klass:TClass, params:Array<CppType>):String {
		if (Ast.getMetaString(klass.meta, ":native") != null) {
			var typeParams = params.length == 0 ? "" : "< " + params.map(tcppToString).join(",") + " >";
			return " " + joinClassPathRemap(klass.path, "::") + typeParams;
		}
		return " ::" + joinClassPathRemap(klass.path, "::");
	}

	public static inline function tcppToString(tcpp:CppType):String {
		return tcppToStringSuffix("", tcpp);
	}

	// Whether a CppCastStatic should wrap a value of funcType
	// where inferredType is expected
	public static function cppCanStaticCast(funcType:CppType, inferredType:CppType):Bool {
		return switch (funcType) {
			case TCppReference(_) | TCppStar(_, _) | TCppStruct(_): false;
			case _: switch (inferredType) {
				case TCppInst(cls, _) if (CppTypeOf.isExternClass(cls)): false;
				case TCppEnum(e) if (CppTypeOf.isExternEnum(e)): false;
				case TCppInst(_, _) | TCppClass | TCppEnum(_): tcppToString(funcType) != tcppToString(inferredType);
				case _: false;
			}
		}
	}

	public static function tcppToStringSuffix(suffix:String, tcpp:CppType):String {
		return switch (tcpp) {
			case TCppDynamic: " ::Dynamic";
			case TCppUnchanged: " ::Dynamic/*Unchanged*/";
			case TCppObject: " ::Dynamic";
			case TCppObjectPtr: " ::hx::Object *";
			case TCppReference(t): tcppToString(t) + " &";
			case TCppStruct(t): "cpp::Struct< " + tcppToString(t) + " >";
			case TCppStar(t, isConst): (isConst ? "const " : "") + tcppToString(t) + " *";
			case TCppVoid: "void";
			case TCppVoidStar: "void *";
			case TCppRest(_): "vaarg_list";
			case TCppVarArg: "vararg";
			case TCppAutoCast: "::cpp::AutoCast";
			case TCppVariant: "::cpp::Variant";
			case TCppEnum(en): " ::" + joinClassPathRemap(en.path, "::") + suffix;
			case TCppScalar(scalar): scalar;
			case TCppString: "::String";
			case TCppFastIterator(it): "::cpp::FastIterator" + suffix + "< " + tcppToString(it) + " >";
			case TCppPointer(ptrType, valueType): "::cpp::" + ptrType + "< " + tcppToString(valueType) + " >";
			case TCppRawPointer(constName, valueType): constName + tcppToString(valueType) + "*";
			case TCppFunction(argTypes, retType, abi):
				"::cpp::Function< " + tcppToString(retType) + " " + abi + " (" + argTypes.map(tcppToString).join(",") + ") >";
			case TCppObjCBlock(argTypes, retType): tcppObjcBlockStruct(argTypes, retType) + "::t";
			case TCppDynamicArray: "::cpp::VirtualArray" + suffix;
			case TCppObjectArray(_): "::Array" + suffix + "< ::Dynamic>";
			case TCppWrapped(_): " ::Dynamic";
			case TCppScalarArray(value): "::Array" + suffix + "< " + tcppToString(value) + " >";
			case TCppObjC(klass):
				var path = joinClassPathRemap(klass.path, "::");
				TypeFunctions.hasClassFlag(klass, CInterface) ? "id < " + path + ">" : path + " *";
			case TCppProtocol(interf):
				var path = Ast.getMetaString(interf.meta, ":objcProtocol");
				"id < " + ((path != null && path != "") ? path : joinClassPathRemap(interf.path, "::")) + ">";
			case TCppNativePointer(klass):
				var name = joinClassPathRemap(klass.path, "::");
				suffix == "_obj" ? name : "::hx::Native< " + name + "* >";
			case TCppInst(klass, p): cppClassPathOf(klass, p) + (CppTypeOf.isNativeClass(klass) ? "" : suffix);
			case TCppInterface(klass) if (suffix == "_obj"): cppClassPathOf(klass, []) + suffix;
			case TCppInterface(_): "::Dynamic";
			case TCppClass: "::hx::Class" + suffix;
			case TCppGlobal: "::Dynamic";
			case TCppNull: " ::Dynamic";
			case TCppCode(_): "Code";
		}
	}

	// H = seed; then h = h*223 + charCode, wrapping at 32 bits
	public static function genHash32(seed:Int, str:String):Int {
		var h = seed;
		for (i in 0...str.length) h = (h * 223 + StringTools.fastCodeAt(str, i)) | 0;
		return h;
	}

	static inline function hex2(v:Int):String {
		return StringTools.hex(v & 0xFF, 2).toLowerCase();
	}

	static inline function hex4(v:Int):String {
		return StringTools.hex(v & 0xFFFF, 4).toLowerCase();
	}

	// The hash runs over the UTF-8 byte encoding of the string; our String exposes UTF-16 code units,
	// so fold each code point's UTF-8 bytes in turn.
	static function genHash32Utf8(seed:Int, s:String):Int {
		var h = seed;
		var i = 0;
		var n = s.length;
		inline function fold(byte:Int) h = (h * 223 + byte) | 0;
		while (i < n) {
			var cp = StringTools.fastCodeAt(s, i);
			if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < n) {
				var lo = StringTools.fastCodeAt(s, i + 1);
				if (lo >= 0xDC00 && lo <= 0xDFFF) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); i += 1; }
			}
			i += 1;
			if (cp < 0x80) fold(cp);
			else if (cp < 0x800) { fold(0xC0 | (cp >> 6)); fold(0x80 | (cp & 0x3F)); }
			else if (cp < 0x10000) { fold(0xE0 | (cp >> 12)); fold(0x80 | ((cp >> 6) & 0x3F)); fold(0x80 | (cp & 0x3F)); }
			else { fold(0xF0 | (cp >> 18)); fold(0x80 | ((cp >> 12) & 0x3F)); fold(0x80 | ((cp >> 6) & 0x3F)); fold(0x80 | (cp & 0x3F)); }
		}
		return h;
	}

	// The string hash as two 16-bit halves, low then high
	public static function genWQStringHash(s:String):String {
		var h = genHash32Utf8(0, s);
		return hex4(h) + "," + hex4(h >>> 16);
	}

	// The four bytes of the string hash, low to high
	public static function genQStringHash(str:String):String {
		var h = genHash32(0, str);
		return hex2(h) + "," + hex2(h >>> 8) + "," + hex2(h >>> 16) + "," + hex2(h >>> 24);
	}

	static function hasUtf8Chars(s:String):Bool {
		for (i in 0...s.length) if (StringTools.fastCodeAt(s, i) > 127) return true;
		return false;
	}

	// Escape the C-string metacharacters (no hex escapes)
	public static function sEscape(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			switch (c) {
				case 92: b.add("\\\\");
				case 34: b.add("\\\"");
				case 10: b.add("\\n");
				case 13: b.add("\\r");
				case 9: b.add("\\t");
				case _: b.addChar(c);
			}
		}
		return b.toString();
	}

	// Hex-encode bytes outside printable ASCII as \xNN""
	static function specialToHex(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c > 127 || c < 32) b.add("\\x" + StringTools.hex(c, 2).toLowerCase() + "\"\"");
			else b.addChar(c);
		}
		return b.toString();
	}

	static function genNarrowString(s:String):String {
		var hexed = specialToHex(sEscape(s));
		if (hexed.length <= 16000) return "HX_(\"" + hexed + "\"," + genQStringHash(s) + ")";
		return "(" + splitNarrowString(s, "") + ")";
	}

	static function splitNarrowString(s:String, plus:String):String {
		var hexed = specialToHex(sEscape(s));
		if (hexed.length <= 16000) return plus + " HX_CSTRING(\"" + hexed + "\")";
		var half = s.length >> 1;
		return splitNarrowString(s.substr(0, half), plus) + splitNarrowString(s.substr(half), "+");
	}

	// The per-code-point escaping inside HX_W(u"..."). The Haxe string exposes UTF-16 code
	// units through fastCodeAt, so combine a surrogate pair into one code point before escaping
	// (control chars named, >=127 as \uXXXX, astral as \UXXXXXXXX).
	static function escapeWideString(s:String):String {
		var b = new StringBuf();
		var i = 0;
		var n = s.length;
		while (i < n) {
			var cp = StringTools.fastCodeAt(s, i);
			if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < n) {
				var lo = StringTools.fastCodeAt(s, i + 1);
				if (lo >= 0xDC00 && lo <= 0xDFFF) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); i += 1; }
			}
			i += 1;
			switch (cp) {
				case 92: b.add("\\\\");
				case 39: b.add("\\'");
				case 34: b.add("\\\"");
				case 13: b.add("\\r");
				case 10: b.add("\\n");
				case 9: b.add("\\t");
				case _:
					if (cp < 32 || (cp >= 127 && cp <= 0xFFFF)) b.add("\\u" + StringTools.hex(cp, 4).toLowerCase());
					else if (cp > 0xFFFF) b.add("\\U" + StringTools.hex(cp, 8).toLowerCase());
					else b.addChar(cp);
			}
		}
		return b.toString();
	}

	// A C++ String literal (HX_("...",hash) or the utf16 HX_W form)
	public static function strq(smartStrings:Bool, s:String):String {
		if (smartStrings && hasUtf8Chars(s)) {
			// The utf16 smart-string path: decode the UTF-8 bytes to code points and escape
			// each (control chars named, everything >=127 as \uXXXX / \UXXXXXXXX)
			return "HX_W(u\"" + escapeWideString(s) + "\"," + genWQStringHash(s) + ")";
		}
		return genNarrowString(s);
	}

	public static function cppClassName(klass:TClass):String {
		var globalNamespace = Ast.getMetaString(klass.meta, ":native") != null ? "" : "::";
		var path = globalNamespace + joinClassPathRemap(klass.path, "::");
		return (CppTypeOf.isNativeClass(klass) || path == "::String") ? path : path + "_obj";
	}

	public static function cppMemberNameOf(member:TClassField):String {
		var rename = Ast.getMetaString(member.meta, ":native");
		return (rename != null && rename != "") ? rename : keywordRemap(member.name);
	}

	public static function cppVarNameOf(v:TVar):String {
		var rename = Ast.getMetaString(v.meta, ":native");
		return (rename != null && rename != "") ? rename : keywordRemap(v.name);
	}

	public static function tcppObjcBlockStruct(argTypes:Array<CppType>, retType:CppType):String {
		var args = argTypes.map(tcppToString).join(",");
		var ret = tcppToString(retType);
		var suffix = Std.string(argTypes.length);
		if (ret == "void") {
			return argTypes.length == 0 ? "::hx::TObjcBlockVoidVoid" : "::hx::TObjcBlockVoidArgs" + suffix + "< " + args + " >";
		}
		return argTypes.length == 0 ? "::hx::TObjcBlockRetVoid< " + ret + " >" : "::hx::TObjcBlockRetArgs" + suffix + "< " + ret + "," + args + " >";
	}
}
