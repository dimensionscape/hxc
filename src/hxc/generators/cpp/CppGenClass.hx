package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;
import hxc.generators.cpp.CppType;
import hxc.generators.cpp.CppExpr;

// hxc.generators.cpp.CppGenClass: emit the .h and .cpp for a class. Method bodies flow through CppEmit.
class CppGenClass {
	final com:Context;
	final classDef:TClass;
	// The per-file goto-label/const-array id counter, reset per .h/.cpp.
	var cppFileId:{v:Int} = {v: -1};
	final smartName:String; // The source class name, e.g. "Probe00Hello"
	final className:String; // "Probe00Hello_obj"
	final defString:String; // "Probe00Hello" (the include guard token; underscored package)
	final smartStrings:Bool;
	// Interface cast-adapter forwarders declared in the header, accumulated during the cpp pass
	// (genInterfaceGlue) and emitted by genHeader.
	var headerGlue:Array<String> = [];

	public function new(com:Context, classDef:TClass) {
		this.com = com;
		this.classDef = classDef;
		this.smartName = classDef.path.name;
		this.className = smartName + "_obj";
		this.defString = joinPath(classDef.path, "_");
		this.smartStrings = com.defines.rawDefined("hxcpp_smart_strings");
	}

	public static function joinPath(p:hxc.core.Globals.Path, sep:String):String {
		return p.pack.length == 0 ? p.name : p.pack.join(sep) + sep + p.name;
	}

	// The type-id table: one pass over com.types assigns every non-extern, non-internal, non-macro
	// class/enum an id via makeId (collision + reserved-range avoidance). The table is keyed by the class
	// text ("::" + the joined class path). Must run before any class is emitted.
	public static var typeIds:Map<String, Int> = new Map();
	// The boot registration lists (reverse com.types order); consumed by CppGen.genBoot.
	public static var bootEnums:Array<hxc.core.Globals.Path> = [];
	public static var bootClasses:Array<hxc.core.Globals.Path> = [];
	public static var nonbootClasses:Array<hxc.core.Globals.Path> = [];
	// Every class's @:buildXml code, accumulated in com.types order, appended to Build.xml after
	// BuildCommon.xml (the std lib pulls in ${HXCPP}/src/hx/libs/std/Build.xml here).
	public static var buildExtra:String = "";

	// The class meta's string arg, \r\n-normalized, plus a "\n".
	public static function getClassCode(c:TClass, metaName:String):String {
		for (entry in c.meta) if (entry.name == metaName && entry.params.length > 0) {
			switch (entry.params[0].expr) {
				case EConst(CString(s, _)):
					var code = s.split("\r\n").join("\n");
					return code == "" ? "" : code + "\n";
				case _:
			}
		}
		return "";
	}

	static inline function getClassBuildXml(c:TClass):String {
		return getClassCode(c, ":buildXml");
	}

	// "class.field" -> "virtual " for every member method that a subclass overrides (walk each class's
	// supers and mark the super field names against this class's members). A leaf method never in the table
	// stays non-virtual.
	public static var memberTypes:Map<String, String> = new Map();

	// The super/interface closure used by the referenced-type walk.
	public static var superDeps:Map<String, Array<hxc.core.Globals.Path>> = new Map();

	// Class path -> constructor field, for the referenced-type walk.
	public static var constructorDeps:Map<String, TClassField> = new Map();

	public static function createMemberTypes(com:Context):Void {
		memberTypes = new Map();
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CInterface)):
				var toSuper = c.superClass;
				while (toSuper != null) {
					var superName = joinPath(toSuper.c.path, ".");
					for (member in c.orderedFields)
						memberTypes.set(superName + "." + member.name, "virtual ");
					toSuper = toSuper.c.superClass;
				}
			case _:
		}
	}

	public static function buildTypeIds(com:Context):Void {
		typeIds = new Map();
		var existing = new Map<Int, Bool>();
		// makeId: genHash32 of the seed and name; reserve the first 100 ids for the runtime and skip
		// collisions. The comparison is signed Int32, so a hash with the high bit set (negative) also fails
		// `id < 100` and bumps the seed by 100 (this is why ::Sys lands at seed 300).
		function makeId(name:String):Void {
			var seed = 0;
			while (true) {
				var id = CppTypeText.genHash32(seed, name);
				if (id < 100 || existing.exists(id)) {
					seed += 100;
					continue;
				}
				existing.set(id, true);
				typeIds.set(name, id);
				return;
			}
		}
		bootEnums = [];
		bootClasses = [];
		nonbootClasses = [];
		buildExtra = "";
		for (mt in com.types) switch (mt) {
			case TClassDecl(c):
				if (CppTypeOf.isExternClass(c)) {
					// Extern classes contribute BuildXml only, no id
					buildExtra += getClassBuildXml(c);
				} else if (CppTypeOf.isInternalClass(c.path) || TypeFunctions.hasMeta(":macro", c.meta)) {
					// Internal/macro classes are runtime-provided, no id
				} else {
					makeId("::" + joinPath(c.path, "::"));
					buildExtra += getClassBuildXml(c);
					// Boot vs nonboot, each PREPENDED (so reverse com.types order).
					if (hasBootField(c)) bootClasses.unshift(c.path);
					else if (!TypeFunctions.hasMeta(":nativeGen", c.meta)) nonbootClasses.unshift(c.path);
				}
			case TEnumDecl(e):
				if (e.isExtern) {
					// Extern enum, no id
				} else if (CppTypeOf.isInternalClass(e.path)) {
					// Internal enum, no id
				} else {
					makeId("::" + joinPath(e.path, "::"));
					bootEnums.unshift(e.path);
				}
			case _:
		}
	}

	// An explicit __init__, or any physical static that needs runtime init (a data field, or a dynamic
	// method). Determines boot vs nonboot registration order.
	static function hasBootField(c:TClass):Bool {
		if (c.init != null) return true;
		for (f in c.orderedStatics) {
			if (!TypeFunctions.isPhysicalField(f)) continue;
			if (f.expr == null) continue;
			switch (f.expr.expr) {
				case TFunction(_): if (isDynamicHaxeMethod(f)) return true;
				case _: return true;
			}
		}
		return false;
	}

	// The class id: looked up from the shared typeIds table (0 if absent).
	function classId():Int {
		var id = typeIds.get("::" + joinPath(classDef.path, "::"));
		return id == null ? 0 : id;
	}

	inline function classIdTxt():String {
		return "0x" + StringTools.lpad(StringTools.hex(classId(), 8).toLowerCase(), "0", 8);
	}

	// The per-class scriptable flag: the -D scriptable build EXCEPT for a private class (an abstract's
	// _Impl_ and other private modules get no cppia dispatch surface).
	function isScriptable():Bool {
		return com.defines.rawDefined("scriptable") && !classDef.isPrivate;
	}

	function ctxTypeString(t:T):String {
		return CppTypeText.tcppToString(CppTypeOf.cppTypeOf(t));
	}

	// A native @:unreflective class (a raw pointer type), or a function mentioning one in an argument or
	// return, cannot be reflected on and so gets no dynamic wrapper.
	static function unreflectiveType(t:T):Bool {
		// A native pointer type such as cpp.ConstCharStar reaches its @:unreflective RawConstPointer only
		// through the abstract, so unwrap non-coreType abstracts here (followWithAbstracts already guards
		// the coreType self-cycle).
		return switch (TypeFunctions.followWithAbstracts(t)) {
			case TInst(klass, _): TypeFunctions.hasMeta(":unreflective", klass.meta);
			case TFun(sig):
				var result = unreflectiveType(sig.ret);
				for (arg in sig.args) if (unreflectiveType(arg.t)) result = true;
				result;
			case _: false;
		};
	}

	function reflective(field:TClassField):Bool {
		return !(TypeFunctions.hasMeta(":nativeGen", classDef.meta)
			|| TypeFunctions.hasMeta(":unreflective", classDef.meta)
			|| TypeFunctions.hasMeta(":unreflective", field.meta)
			|| unreflectiveType(field.type));
	}

	static function isDynamicHaxeMethod(f:TClassField):Bool {
		if (f.expr == null) return false;
		return switch (f.expr.expr) {
			case TFunction(_): switch (f.kind) { case Var(_) | Method(MethDynamic): true; case _: false; };
			case _: false;
		}
	}

	// Hxc's loader does not mark an override of a dynamic method as MethDynamic, so at generation time
	// also treat a member that overrides a dynamic super method as dynamic: its Dynamic member slot
	// must hold this class's implementation, read back by value (bind/assignment).
	static function overridesDynamicMethod(c:TClass, f:TClassField):Bool {
		if (f.expr == null || !f.expr.expr.match(TFunction(_))) return false;
		var sup = c.superClass;
		while (sup != null) {
			var pf = sup.c.fields.get(f.name);
			if (pf != null && pf.kind.match(Method(MethDynamic))) return true;
			sup = sup.c.superClass;
		}
		return false;
	}
	static function isDynamicFieldIn(c:TClass, f:TClassField):Bool {
		return isDynamicHaxeMethod(f) || overridesDynamicMethod(c, f);
	}
	function fieldIsDynamic(f:TClassField):Bool {
		return isDynamicFieldIn(classDef, f);
	}

	// The keyword-remapped field name (no @:native handling).
	function nativeFieldNameRemap(isStatic:Bool, field:TClassField):String {
		return CppTypeText.keywordRemap(field.name);
	}

	// The C++ arg list for a bare function signature, each optional scalar widened to ::hx::Null< T >.
	function ctxTfunArgList(args:Array<hxc.core.Type.TSignatureArg>, includeNames:Bool):String {
		return [for (a in args) {
			var typeStr = ctxTypeString(a.t);
			var t = (a.opt && CppTypeOf.cppTypeOf(a.t).match(TCppScalar(_)) && typeStr != "Dynamic") ? "::hx::Null< " + typeStr + " > " : typeStr;
			t + (includeNames ? " " + CppTypeText.keywordRemap(a.name) : "");
		}].join(",");
	}

	function genMemberDefHeader(w:CppWriter, isStatic:Bool, field:TClassField):Void {
		// An interface member: a Method emits either a plain static/virtual decl, or (the common non-static
		// non-native case) a member-function-pointer field plus a static dispatch stub that routes through
		// _hx_getInterface. Not driven by expr (interface fields have no body).
		if (TypeFunctions.hasClassFlag(classDef, CInterface)) {
			var nativeGen = TypeFunctions.hasMeta(":nativeGen", classDef.meta);
			switch [TypeFunctions.follow(field.type), field.kind] {
				case [_, Method(MethDynamic)]:
				case [TFun(sig), Method(_)]:
					var remap = CppTypeText.keywordRemap(field.name);
					var returnType = ctxTypeString(sig.ret);
					var argList = ctxTfunArgList(sig.args, true);
					if (isStatic || nativeGen) {
						w.write((!isStatic ? "\t\tvirtual " : "\t\t") + returnType + " " + remap + "( " + argList + (!isStatic ? ")=0;\n" : ");\n"));
						if (reflective(field)) w.write("\t\tvirtual ::Dynamic " + remap + "_dyn()=0;\n");
					} else {
						var commaArgList = argList == "" ? "" : "," + argList;
						var argNames = [for (a in sig.args) CppTypeText.keywordRemap(a.name)].join(",");
						var castExpr = "::hx::interface_cast< ::" + CppTypeText.joinClassPathRemap(classDef.path, "::") + "_obj *>";
						var hash = genHash(0, joinPath(classDef.path, "::"));
						var returnStr = returnType == "void" ? "" : "return ";
						w.write("\t\t" + returnType + " (::hx::Object :: *_hx_" + remap + ")(" + argList + "); \n");
						w.write("\t\tstatic inline " + returnType + " " + remap + "( ::Dynamic _hx_" + commaArgList + ") {\n");
						w.write("\t\t\t#ifdef HXCPP_CHECK_POINTER\n");
						w.write("\t\t\tif (::hx::IsNull(_hx_)) ::hx::NullReference(\"Object\", false);\n");
						w.write("\t\t\t#ifdef HXCPP_GC_CHECK_POINTER\n");
						w.write("\t\t\t\tGCCheckPointer(_hx_.mPtr);\n");
						w.write("\t\t\t#endif\n");
						w.write("\t\t\t#endif\n");
						w.write("\t\t\t" + returnStr + "(_hx_.mPtr->*( " + castExpr + "(_hx_.mPtr->_hx_getInterface(" + hash + ")))->_hx_" + remap + ")(" + argNames + ");\n\t\t}\n");
					}
				case _:
			}
			return;
		}
		var nonVirtual = TypeFunctions.hasMeta(":nonVirtual", field.meta);
		var doDynamic = (nonVirtual || !isOverride(field)) && reflective(field);
		var remapName = nativeFieldNameRemap(isStatic, field);
		w.write(isStatic ? "\t\tstatic " : "\t\t");
		switch (field.expr == null ? null : field.expr.expr) {
			case TFunction(tf):
				// A `dynamic function` is a Dynamic member holding a closure: emit it as a ::Dynamic field plus
				// an inline _dyn() reference, not as a real method declaration.
				if (fieldIsDynamic(field)) {
					if (doDynamic) {
						w.write("::Dynamic " + remapName + ";\n");
						// A GC-managed dynamic-method field gets a write-barrier setter too, typed
						// ::Dynamic, so a reassignment of `dynamic function f` records the store.
						if (!isStatic && isGcElement(TCppDynamic))
							w.write("\t\tinline ::Dynamic _hx_set_" + remapName + "(::hx::StackContext *_hx_ctx,::Dynamic _hx_v) { HX_OBJ_WB(this,_hx_v.mPtr) return " + remapName + "=_hx_v; }\n");
						w.write(isStatic ? "\t\tstatic " : "\t\t");
						w.write("inline ::Dynamic &" + remapName + "_dyn() {return " + remapName + "; }\n");
					}
					w.write("\n");
					return;
				}
				var returnType = ctxTypeString(tf.type);
				// An instance method is virtual when the member-types table marks it (a subclass overrides
				// it); an internal member (toString and the __-runtime names) is always virtual, and a
				// scriptable build makes every method virtual so the __scriptable subclass can override it.
				if (!isStatic && !nonVirtual) {
					if (!CppTypeText.isInternalMember(field.name) && !com.defines.rawDefined("scriptable")) {
						var key = joinPath(classDef.path, ".") + "." + field.name;
						var v = memberTypes.get(key);
						if (v != null) w.write(v);
					} else {
						w.write("virtual ");
					}
				}
				w.write(returnType == "Void" ? "void" : returnType);
				// The header declaration uses the empty prefix (plain arg names).
				w.write(" " + remapName + "(" + ctxArgList(tf.args, "") + ");\n");
				if (doDynamic) {
					w.write(isStatic ? "\t\tstatic " : "\t\t");
					w.write("::Dynamic " + remapName + "_dyn();\n");
				}
				w.write("\n");
			case _ if (isAbstractMethod(field)):
				// An abstract method emits a virtual with a default-value body so the concrete override
				// dispatches through the vtable; a reflective one also gets a _dyn() wrapper.
				var sig = switch (TypeFunctions.follow(field.type)) { case TFun(s): s; case _: null; };
				var returnType = ctxTypeString(sig.ret);
				var isVoid = returnType == "Void" || returnType == "void";
				w.write("virtual " + (isVoid ? "void" : returnType) + " " + remapName + "(" + ctxTfunArgList(sig.args, true) + ") "
					+ (isVoid ? "{}" : "{ return 0; }") + "\n");
				if (doDynamic) {
					w.write(isStatic ? "\t\tstatic " : "\t\t");
					w.write("::Dynamic " + remapName + "_dyn();\n");
				}
			case _:
				// Member variable declaration: the C++ type + name
				var tcpp = CppTypeOf.cppTypeOf(field.type);
				w.write(CppTypeText.tcppToString(tcpp) + " " + remapName + ";\n");
				// Under HXCPP_GC_GENERATIONAL a GC-pointer member field gets an inline write-barrier
				// setter: a store records itself (HX_OBJ_WB) so the generational collector rescans this
				// object. The barrier argument is the value's raw pointer.
				if (!isStatic && isGcElement(tcpp)) {
					var ts2 = CppTypeText.tcppToString(tcpp);
					var getPtr = tcpp.match(TCppString) ? ".raw_ref()" : ".mPtr";
					w.write("		inline " + ts2 + " _hx_set_" + remapName + "(::hx::StackContext *_hx_ctx," + ts2 + " _hx_v) { HX_OBJ_WB(this,_hx_v" + getPtr + ") return " + remapName + "=_hx_v; }\n");
				}
				// Unify variable/function access: a function-typed var gets a _dyn() accessor (judged
				// through followWithAbstracts, so a cpp.Callable var counts).
				switch (TypeFunctions.followWithAbstracts(field.type)) {
					case TFun(_):
						w.write(isStatic ? "\t\tstatic " : "\t\t");
						w.write("Dynamic " + remapName + "_dyn() { return " + remapName + ";}\n");
					case _:
				}
		}
	}

	function virtualFieldsOf(root:TClass):Array<TClassField> {
		var fields:Array<TClassField> = [];
		function add(c:TClass):Void {
			if (c.superClass != null) add(c.superClass.c);
			else if (TypeFunctions.hasClassFlag(c, CInterface) && c.interfaces.length > 0)
				// The typer represents interface `extends` entries as interfaces, while hxcpp
				// stores the final entry in superClass. Match that C++ inheritance chain here.
				add(c.interfaces[c.interfaces.length - 1].c);
			for (f in c.orderedFields) switch ([TypeFunctions.follow(f.type), f.kind]) {
				case [TFun(_), Method(MethDynamic)]:
				case [TFun(_), Method(_)]:
					var index = -1;
					for (i in 0...fields.length) if (fields[i].name == f.name) { index = i; break; }
					if (TypeFunctions.hasClassFieldFlag(f, CfOverride) && index >= 0) fields[index] = f;
					else if (index < 0) fields.push(f);
				case _:
			}
		}
		add(root);
		return fields;
	}

	function virtualFields():Array<TClassField> return virtualFieldsOf(classDef);

	function cppSuper():Null<TClassWithParams> {
		if (classDef.superClass != null) return classDef.superClass;
		// See virtualFields: interface extends relations live in interfaces in this IR.
		return TypeFunctions.hasClassFlag(classDef, CInterface) && classDef.interfaces.length > 0
			? classDef.interfaces[classDef.interfaces.length - 1]
			: null;
	}

	static function isOverride(field:TClassField):Bool {
		return TypeFunctions.hasClassFieldFlag(field, CfOverride);
	}

	// An optional argument with a non-null default is emitted as a nullable __o_-prefixed shadow
	// (::hx::Null< T > __o_x for a scalar, T __o_x otherwise); its real value is unpacked in the body
	// prologue by cppGenDefaultValues. The prefix distinguishes the two forms: the .cpp method/ctor
	// DEFINITION uses "__o_" (the shadow the body prologue unpacks), while the header declaration uses
	// ""; the arg type is Null-wrapped either way for a scalar default, only the name differs.
	function ctxArgList(args:Array<TFuncArg>, prefix:String = "__o_"):String {
		return args.map(function(a) {
			var typeStr = ctxTypeString(a.v.type);
			var remap = CppTypeText.cppVarNameOf(a.v);
			// The argument is the type part, a space, then the name; the scalar type part keeps a trailing
			// space, so the nullable form ends up with two spaces before the prefixed name.
			var pair = switch (a.c) {
				case null | {expr: TConst(TNull)}: {t: typeStr, n: remap};
				case _ if (CppTypeOf.isCppScalar(CppTypeOf.cppTypeOf(a.v.type))): {t: "::hx::Null< " + typeStr + " > ", n: prefix + remap};
				case _: {t: typeStr, n: prefix + remap};
			};
			return pair.t + " " + pair.n;
		}).join(",");
	}

	// The super class and each interface contribute their @:include files when they have any, and only
	// otherwise their own class header. Both go to the HEADER buffer, ahead of the forward declarations.
	function includeClassHeader(w:CppWriter, c:TClass):Void {
		var includeFiles = CppReferenced.getAllMetaStringPath(c.meta, ":include");
		if (includeFiles.length > 0) for (inc in includeFiles) w.writeHUnique(guardedInclude(inc));
		else addInclude(w, c.path);
	}

	public function genHeader():String {
		cppFileId = {v: -1};
		var w = new CppWriter();
		w.writeH("#ifndef INCLUDED_" + defString + "\n");
		w.writeH("#define INCLUDED_" + defString + "\n\n");
		w.writeH("#ifndef HXCPP_H\n#include <hxcpp.h>\n#endif\n\n");
		// Include the super class's real header, then each implemented (non-rtti) interface's, so their
		// full definitions are available to the class declaration.
		if (classDef.superClass != null) includeClassHeader(w, classDef.superClass.c);
		for (imp in classDef.interfaces)
			if (!(imp.c.path.pack.length == 2 && imp.c.path.pack[0] == "cpp" && imp.c.path.pack[1] == "rtti"))
				includeClassHeader(w, imp.c);
		// From HX_DECLARE_CLASS0 onward goes to the body buffer; the begin above + any inline-ctor stack
		// frames go to the HEADER buffer, so a HX_DECLARE_STACK_FRAME lands between the includes and
		// HX_DECLARE_CLASS0. The forward declarations: a HX_DECLARE_CLASS<n> for every referenced type
		// (self included), sorted by dotted path. The per-class scriptable flag is passed as
		// includeSuperArgs so a cppia host also names the super methods' argument types.
		var refs = CppReferenced.findReferencedTypesFlags(com, TClassDecl(classDef), "*", superDeps, constructorDeps, true, isScriptable());
		for (i in 0...refs.deps.length) CppReferenced.genForwardDecl(w, refs.deps[i], refs.flags[i]);
		// One blank line, the @:headerCode, then the namespace, two blanks, @:headerNamespaceCode.
		w.write("\n");
		w.write(getClassCode(classDef, ":headerCode"));
		genOpenNamespace(w);
		w.write("\n\n");
		w.write(getClassCode(classDef, ":headerNamespaceCode"));
		// Parent/super: normal classes extend their super's _obj type, interfaces use their final extends
		// entry, and roots use ::hx::Object.
		var isInterface = TypeFunctions.hasClassFlag(classDef, CInterface);
		var superDef = cppSuper();
		var superName = superDef != null
			? CppTypeText.tcppToStringSuffix("_obj", CppTypeOf.cppInstanceTypeOf(superDef.c, superDef.params))
			: "::hx::Object";
		// A dll_export (cppia host) build tags classes with the EXTERN attribute macro.
		var attribs = "HXCPP_" + (com.defines.rawDefined("dll_export") ? "EXTERN_" : "") + "CLASS_ATTRIBUTES";
		if (isInterface) {
			w.write("class " + attribs + " " + className + " {\n\tpublic:\n");
			w.write("\t\ttypedef " + superName + " super;\n");
		} else {
			w.write("class " + attribs + " " + className + " : public " + superName + "\n{\n\tpublic:\n");
			w.write("\t\ttypedef " + superName + " super;\n");
			w.write("\t\ttypedef " + className + " OBJ_;\n");
		}
		// An interface header carries no instance scaffolding: just HX_DO_INTERFACE_RTTI (no private ctor /
		// operator new / __new / __alloc / _hx_vtable / __CreateEmpty / __register / _hx_isInstanceOf /
		// __ToString); its methods are pure-virtual member decls handled below.
		if (isInterface) {
			w.write("\t\tHX_DO_INTERFACE_RTTI;\n\n");
		} else {
		w.write("\t\t" + className + "();\n\n\tpublic:\n");
		w.write("\t\tenum { _hx_ClassId = " + classIdTxt() + " };\n\n");
		var ctorTypeArgs = constructorTypeArgs();
		var ctorArgs = constructorArgNames().join(",");
		w.write("\t\tvoid __construct(" + ctorTypeArgs + ");\n");
		var isContainer = hasGcReferences(classDef) ? "true" : "false";
		var gcName = constCharStar(joinPath(classDef.path, "."));
		w.write("\t\tinline void *operator new(size_t inSize, bool inContainer=" + isContainer + ",const char *inName=" + gcName + ")\n");
		w.write("\t\t\t{ return ::hx::Object::operator new(inSize,inContainer,inName); }\n");
		w.write("\t\tinline void *operator new(size_t inSize, int extra)\n");
		w.write("\t\t\t{ return ::hx::Object::operator new(inSize+extra," + isContainer + "," + gcName + "); }\n");
		var ctorTf = ctorFuncDef();
		var allocArgs = "::hx::Ctx *_hx_ctx" + (ctorTypeArgs == "" ? "" : "," + ctorTypeArgs);
		var ptrName = "::hx::ObjectPtr< " + className + " >";
		// An inline-able constructor emits the __new/__alloc bodies directly in the header; otherwise only
		// their declarations, with the bodies emitted in the cpp. An abstract class emits neither, just a
		// blank line, and skips the construction scaffolding.
		if (TypeFunctions.hasClassFlag(classDef, CAbstract)) {
			w.write("\n");
		} else if (canInlineConstructor()) {
			w.write("\n");
			w.write("\t\tinline static " + ptrName + " __new(" + ctorTypeArgs + ") {\n");
			w.write("\t\t\t" + ptrName + " __this = new " + className + "();\n");
			w.write("\t\t\t__this->__construct(" + ctorArgs + ");\n\t\t\treturn __this;\n\t\t}\n\n");
			if (canQuickAlloc()) {
				w.write("\t\tinline static " + ptrName + " __alloc(" + allocArgs + ") {\n");
				w.write("\t\t\t" + className + " *__this = (" + className + "*)(::hx::Ctx::alloc(_hx_ctx, sizeof(" + className + "), " + isContainer + ", " + gcName + "));\n");
				w.write("\t\t\t*(void **)__this = " + className + "::_hx_vtable;\n");
				// The quick-alloc path installs dynamic-method defaults via the nearest self-or-super
				// __alloc_dynamic_functions.
				{
					var dc = nearestDynamicClass();
					if (dc != null) w.write("\t\t\t" + objScope(dc) + "::__alloc_dynamic_functions(_hx_ctx,__this);\n");
				}
				if (ctorTf != null) {
					// The inline ctor body (real this ptr false -> `( (::Point)(__this))->x`); the
					// HX_DECLARE_STACK_FRAME is declared to the header top, HX_STACKFRAME emitted into the body.
					var dotName = joinPath(classDef.path, ".");
					var frameLine = CppEmit.getErrorLine(ctorTf.expr.pos);
					var stripped = stripFile(com, ctorTf.expr.pos.file);
					var varName = "_hx_pos_" + hash64(dotName + "." + stripped) + "_" + frameLine + "_new";
					// The header inline ctor body carries the field's own debug level and (at debug>=2) the
					// HX_STACK_THIS/HX_STACK_ARG registrations. The real this ptr is false here, so `this`
					// is the local __this.
					var allocDbg = classDef.constructor != null ? fieldDebugLevel(classDef.constructor) : baseDebugLevel();
					var emitAlloc = new CppEmit(com, w, allocDbg, false, cppFileId, true);
					var allocDefaults = [for (a in ctorTf.args) {v: a.v, dflt: a.c}];
					emitAlloc.genExpressionTree([for (a in ctorTf.args) a.v], ctorTf.type, ctorTf.expr,
						function(gc) {
							emitAlloc.cppGenDefaultValues(allocDefaults, "__o_");
							fileInfo.set(stripped, ctorTf.expr.pos.file);
							w.writeHUnique("HX_DECLARE_STACK_FRAME(" + varName + ")\n");
							w.write("            \t" + (gc ? "HX_GC_STACKFRAME" : "HX_STACKFRAME") + "(&" + varName + ")\n");
							hxStackDebugVars(w, allocDbg, false, false, [for (a in ctorTf.args) a.v], frameLine);
						}, null, dotName, "new");
					w.write("\t\t\n"); // outputConstructor trailing `out "\n"` (a \t\t-prefixed blank line)
				}
				w.write("\t\t\treturn __this;\n\t\t}\n\n");
			}
		} else {
			w.write("\t\tstatic " + ptrName + " __new(" + ctorTypeArgs + ");\n");
			if (canQuickAlloc()) w.write("\t\tstatic " + ptrName + " __alloc(" + allocArgs + ");\n");
		}
		if (!TypeFunctions.hasClassFlag(classDef, CAbstract)) {
			w.write("\t\tstatic void * _hx_vtable;\n");
			w.write("\t\tstatic Dynamic __CreateEmpty();\n");
			w.write("\t\tstatic Dynamic __Create(::hx::DynamicArray inArgs);\n");
		}
		// A class with dynamic member functions declares its default-installer.
		if (dynamicFunctions().length > 0)
			w.write("\t\tstatic void __alloc_dynamic_functions(::hx::Ctx *_hx_alloc," + className + " *_hx_obj);\n");
		// A scriptable build declares the cppia constructor trampoline handle.
		if (isScriptable())
			w.write("\t\tstatic ::hx::ScriptFunction __script_construct;\n");
		w.write("\t\t//~" + className + "();\n\n");
		w.write("\t\tHX_DO_RTTI_ALL;\n");
		// Reflection method declarations, each gated like its .cpp definition.
		if (hasGetMemberField()) w.write("\t\t::hx::Val __Field(const ::String &inString, ::hx::PropertyAccess inCallProp);\n");
		if (hasGetStaticField()) w.write("\t\tstatic bool __GetStatic(const ::String &inString, Dynamic &outValue, ::hx::PropertyAccess inCallProp);\n");
		if (hasSetMemberField()) w.write("\t\t::hx::Val __SetField(const ::String &inString,const ::hx::Val &inValue, ::hx::PropertyAccess inCallProp);\n");
		if (hasSetStaticField()) w.write("\t\tstatic bool __SetStatic(const ::String &inString, Dynamic &ioValue, ::hx::PropertyAccess inCallProp);\n");
		if (hasGetFields()) w.write("\t\tvoid __GetFields(Array< ::String> &outFields);\n");
		w.write("\t\tstatic void __register();\n");
		// A class with GC-managed member vars overrides __Mark/__Visit to trace them.
		if (hasNewGcReferences(classDef)) {
			w.write("\t\tvoid __Mark(HX_MARK_PARAMS);\n");
			w.write("\t\tvoid __Visit(HX_VISIT_PARAMS);\n");
		}
		w.write("\t\tbool _hx_isInstanceOf(int inClassId);\n");
		// A class implementing interfaces declares the getInterface dispatch.
		if (implementedInterfaces().length > 0) {
			w.write("\t\tvoid *_hx_getInterface(int inHash);\n");
			// The interface cast-adapter forwarders accumulated during the cpp pass.
			if (headerGlue.length > 0) w.write(headerGlue.join("\n"));
		}
		// A class with a init block declares its __init__.
		if (classDef.init != null) w.write("\t\tstatic void __init__();\n\n");
		w.write("\t\t::String __ToString() const { return " + CppTypeText.strq(smartStrings, smartName) + "; }\n\n");
		}
		// The __boot declaration when the class has static initializers.
		if (hasBootField(classDef)) w.write("\t\tstatic void __boot();\n");
		// The ArrayAccess typedef sits between __boot and the statics.
		if (classDef.arrayAccess != null) w.write("\t\ttypedef " + ctxTypeString(classDef.arrayAccess) + " __array_access;\n");
		// Declare all the statics, orderedStatics rather than staticsExceptMeta: only the cpp body skips
		// __meta__ and __rtti, because those are assigned through __mClass instead of defined.
		for (f in classDef.orderedStatics) if (TypeFunctions.isPhysicalField(f)) genMemberDefHeader(w, true, f);
		var instanceFields = isInterface ? virtualFields() : classDef.orderedFields;
		for (f in instanceFields) if (TypeFunctions.isPhysicalField(f)) genMemberDefHeader(w, false, f);
		// @:headerClassCode is injected verbatim just before the class closing brace.
		w.write(getClassCode(classDef, ":headerClassCode"));
		w.write("};\n\n");
		genCloseNamespace(w);
		w.write("\n#endif /* INCLUDED_" + defString + " */ \n");
		return w.getHeader() + w.getBody();
	}

	// A reflective static field means __GetStatic is emitted.
	function hasGetStaticField():Bool {
		for (f in staticsExceptMeta()) if (reflective(f) && isReadable(f)) return true;
		return false;
	}

	// The constructor's typed function (or null).
	function ctorFuncDef():Null<TFunc> {
		if (classDef.constructor == null || classDef.constructor.expr == null) return null;
		return switch (classDef.constructor.expr.expr) {
			case TFunction(tf): tf;
			case _: null;
		};
	}

	// "int x,int y" (the typed arg list) and "x,y" (the arg names)
	function constructorTypeArgs():String {
		var tf = ctorFuncDef();
		return tf == null ? "" : ctxArgList(tf.args);
	}

	function constructorArgNames():Array<String> {
		var tf = ctorFuncDef();
		if (tf == null) return [];
		// The __new/__alloc body forwards these to __construct, so the names must match the __new signature
		// built by ctxArgList: an argument with a non-null default is the __o_-prefixed shadow (default
		// resolution happens inside __construct), a required argument keeps its plain name.
		return [for (a in tf.args) switch (a.c) {
			case null | {expr: TConst(TNull)}: CppTypeText.cppVarNameOf(a.v);
			case _: "__o_" + CppTypeText.cppVarNameOf(a.v);
		}];
	}

	// The __new/__alloc method bodies in the cpp, for a class whose constructor is not inlined into the
	// header.
	function outputConstructorCpp(w:CppWriter):Void {
		var ptrName = "::hx::ObjectPtr< " + className + " >";
		var ctorTypeArgs = constructorTypeArgs();
		var ctorArgs = constructorArgNames().join(",");
		var isContainer = hasGcReferences(classDef) ? "true" : "false";
		var gcName = constCharStar(joinPath(classDef.path, "."));
		w.write(ptrName + " " + className + "::__new(" + ctorTypeArgs + ") {\n");
		w.write("\t" + ptrName + " __this = new " + className + "();\n");
		w.write("\t__this->__construct(" + ctorArgs + ");\n");
		w.write("\treturn __this;\n");
		w.write("}\n\n");
		if (canQuickAlloc()) {
			var allocArgs = "::hx::Ctx *_hx_ctx" + (ctorTypeArgs == "" ? "" : "," + ctorTypeArgs);
			w.write(ptrName + " " + className + "::__alloc(" + allocArgs + ") {\n");
			w.write("\t" + className + " *__this = (" + className + "*)(::hx::Ctx::alloc(_hx_ctx, sizeof(" + className + "), " + isContainer + ", " + gcName + "));\n");
			w.write("\t*(void **)__this = " + className + "::_hx_vtable;\n");
			{
				var dc = nearestDynamicClass();
				if (dc != null) w.write("\t" + objScope(dc) + "::__alloc_dynamic_functions(_hx_ctx,__this);\n");
			}
			w.write("\t__this->__construct(" + ctorArgs + ");\n");
			w.write("\treturn __this;\n");
			w.write("}\n\n");
		}
	}

	// The nearest superclass with its own GC-managed members, as its _obj type; that super's __Mark/__Visit
	// is chained.
	function findNextSuperIteration(c:TClass):String {
		var sup = c.superClass;
		if (sup == null) return "";
		if (hasNewGcReferences(sup.c)) return CppTypeText.tcppToStringSuffix("_obj", CppTypeOf.cppInstanceTypeOf(sup.c, sup.params));
		return findNextSuperIteration(sup.c);
	}

	// A data member (var or dynamic method) is marked/visited by name.
	function dumpFieldIterator(w:CppWriter, iterMacro:String, field:TClassField):Void {
		if (isMemberVar(field))
			w.write("\t" + iterMacro + "(" + CppTypeText.keywordRemap(field.name) + ",\"" + field.name + "\");\n");
	}

	// The instance __Mark/__Visit: trace every data member, then chain to the nearest GC super.
	function genMarkVisit(w:CppWriter):Void {
		var superIter = findNextSuperIteration(classDef);
		var fields = [for (f in classDef.orderedFields) if (TypeFunctions.isPhysicalField(f)) f];
		w.write("void " + className + "::__Mark(HX_MARK_PARAMS)\n{\n");
		w.write("\tHX_MARK_BEGIN_CLASS(" + smartName + ");\n");
		for (f in fields) dumpFieldIterator(w, "HX_MARK_MEMBER_NAME", f);
		if (superIter != "") w.write("\t" + superIter + "::__Mark(HX_MARK_ARG);\n");
		w.write("\tHX_MARK_END_CLASS();\n");
		w.write("}\n\n");
		w.write("void " + className + "::__Visit(HX_VISIT_PARAMS)\n{\n");
		for (f in fields) dumpFieldIterator(w, "HX_VISIT_MEMBER_NAME", f);
		if (superIter != "") w.write("\t" + superIter + "::__Visit(HX_VISIT_ARG);\n");
		w.write("}\n\n");
	}

	// A class has GC-managed members if any physical member var is a non-scalar (an object reference the
	// collector must mark).
	static function hasNewGcReferences(c:TClass):Bool {
		for (f in c.orderedFields)
			if (TypeFunctions.isPhysicalField(f) && (CppTypeOf.isVarField(f) || isDynamicFieldIn(c, f)) && !CppTypeOf.cppTypeOf(f.type).match(TCppScalar(_)))
				return true;
		return false;
	}

	// This class or any superclass has GC-managed members.
	static function hasGcReferences(c:TClass):Bool {
		if (c.superClass != null && hasGcReferences(c.superClass.c)) return true;
		return hasNewGcReferences(c);
	}

	// A non-native class can use the fast __alloc path.
	function canQuickAlloc():Bool {
		return CppTypeOf.canQuickAlloc(classDef);
	}

	// The ctor body is simple (no TReturn / no non-empty array literal) and constructs only this class or a
	// superclass (approximating the referenced-type walk at the TExpr level via TNew targets; those are the
	// types that would need a full definition in the header).
	function canInlineConstructor():Bool {
		var tf = ctorFuncDef();
		// A class with no constructor (or none with a body) is trivially inlinable.
		if (tf == null) return true;
		var allowed = new Map<String, Bool>();
		allowed.set(joinPath(classDef.path, "."), true);
		var sup = classDef.superClass;
		while (sup != null) { allowed.set(joinPath(sup.c.path, "."), true); sup = sup.c.superClass; }
		var ok = true;
		function check(e:TExpr):Void {
			if (!ok) return;
			switch (e.expr) {
				case TReturn(_): ok = false;
				case TArrayDecl(el) if (el.length > 0): ok = false;
				case _:
			}
			if (ok) hxc.core.TexprTools.iter(check, e);
		}
		check(tf.expr);
		if (!ok) return false;
		// The remaining check: every type the constructor references (its body + the class's
		// virtual-function signatures) must already have a full definition in the header, i.e. be this
		// class or a superclass. Otherwise the inline __alloc body would use an incomplete type.
		var refs = CppReferenced.findReferencedTypesFlags(com, TClassDecl(classDef), "new", superDeps, constructorDeps, false, true);
		for (dep in refs.deps) if (!allowed.exists(joinPath(dep, "."))) return false;
		return true;
	}

	static inline function genHash(seed:Int, s:String):String {
		return "0x" + StringTools.lpad(StringTools.hex(CppTypeText.genHash32(seed, s), 8).toLowerCase(), "0", 8);
	}

	static inline function hash64(s:String):String {
		return haxe.crypto.Md5.encode(s).substr(0, 16);
	}

	// Drop the first matching classpath prefix (class path then std path). With -D absolute-path the full
	// path is kept. The stripped name is the stack-frame file and the input to its hashes.
	public static function stripFile(com:Context, file:String):String {
		if (com.defines.rawDefined("absolute_path")) return file;
		for (p in com.classPath)
			if (file.length > p.length && file.substr(0, p.length) == p) return file.substr(p.length);
		for (p in com.stdPath)
			if (file.length > p.length && file.substr(0, p.length) == p) return file.substr(p.length);
		return file;
	}

	// The quoted C string literal for s. Named C escapes for \n \t \r " \\; bytes <32 or >127 become
	// \xHH"". ASCII paths only touch the backslash rule (C:\a -> "C:\\a").
	public static function constCharStar(s:String):String {
		var b = new StringBuf();
		b.addChar('"'.code);
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			switch (c) {
				case '\n'.code: b.add("\\n");
				case '\t'.code: b.add("\\t");
				case '\r'.code: b.add("\\r");
				case '"'.code: b.add("\\\"");
				case '\\'.code: b.add("\\\\");
				default:
					if (c > 127 || c < 32) b.add("\\x" + StringTools.hex(c, 2).toLowerCase() + "\"\"");
					else b.addChar(c);
			}
		}
		b.addChar('"'.code);
		return b.toString();
	}

	// Stripped file -> original file, accumulated across every frame push. CppGen.genFiles reads it for
	// __hxcpp_all_files / __hxcpp_all_files_fullpath.
	public static var fileInfo:Map<String, String> = new Map();

	public static function hxStackPush(com:Context, w:CppWriter, dotName:String, funcName:String, file:String, line:Int, gcStack:Bool = false, ?fileId:{v:Int}, debug:Int = 1, isHeader:Bool = false, indented:Bool = false):Void {
		// A @:noDebug method (debug<=0) emits no debug frame, so its own frame does not pollute the
		// captured call/exception stack (haxe.NativeStackTrace.callStack); it still gets
		// HX_JUST_GC_STACKFRAME when the body allocates.
		if (debug <= 0) {
			// A @:noDebug function body is indented by a single tab, not the 12-space debug spacer, so its
			// HX_JUST_GC_STACKFRAME aligns to one tab.
			if (gcStack) w.write("\tHX_JUST_GC_STACKFRAME\n");
			return;
		}
		// Every stack frame bumps the shared per-file counter (the id is not used here, but the bump keeps
		// goto-label / const-array ids in step).
		if (fileId != null) fileId.v++;
		var strippedFile = stripFile(com, file);
		fileInfo.set(strippedFile, file);
		// The file goes into the C++ string literal escaped, but the hashes and the id are computed from
		// the UNescaped stripped file.
		var escFile = CppTypeText.sEscape(strippedFile);
		var hashClassFunc = genHash(0, dotName + "." + funcName);
		var hashFile = genHash(0, strippedFile);
		var id = hash64(dotName + "." + strippedFile);
		var varName = "_hx_pos_" + id + "_" + line + "_" + funcName;
		// A "*" (anonymous) frame appends " (file:line)" to the display name.
		var fullName = dotName + "." + funcName + (dotName == "*" ? " (" + escFile + ":" + line + ")" : "");
		// A frame emitted into a header only DECLAREs the StackPosition (an inline body in the header); the
		// cpp file DEFINEs it. Emitting the full definition in both would be a redefinition.
		if (isHeader) {
			w.writeHUnique("HX_DECLARE_STACK_FRAME(" + varName + ")\n");
		} else {
			var frameMacro = funcName == "new" ? "HX_DEFINE_STACK_FRAME" : "HX_LOCAL_STACK_FRAME";
			w.writeHUnique(frameMacro + "(" + varName + ",\"" + dotName + "\",\"" + funcName + "\"," + hashClassFunc
				+ ",\"" + fullName + "\",\"" + escFile + "\"," + line + "," + hashFile + ")\n");
		}
		// A method-body prologue writes at the fixed spacer with no writer indent, so the frame sits at the
		// fixed 12-space + tab spacer. A closure prologue adds the writer's indent to the spacer, so its
		// frame is additionally indented by the closure body's depth.
		var frame = (gcStack ? "HX_GC_STACKFRAME" : "HX_STACKFRAME") + "(&" + varName + ")\n";
		if (indented) { w.write("            \t"); w.writeI(frame); }
		else w.write("            \t" + frame);
	}

	// The debug level: -D annotate-source is 3, -D hxcpp-debugger is 2, otherwise the base level (0 when -D
	// no-debug, else 1). Level >= 2 is what makes the prologue register this/args so the interactive
	// debugger can inspect them at a breakpoint.
	function baseDebugLevel():Int {
		if (com.defines.rawDefined("annotate_source")) return 3;
		if (com.defines.rawDefined("HXCPP_DEBUGGER")) return 2;
		return com.defines.rawDefined("no_debug") ? 0 : 1;
	}

	// A @:noDebug field (or class) drops the debug level to 0 for its body.
	function fieldDebugLevel(field:TClassField):Int {
		return (TypeFunctions.hasMeta(":noDebug", field.meta) || TypeFunctions.hasMeta(":noDebug", classDef.meta)) ? 0 : baseDebugLevel();
	}

	// At level >= 2 an argument becomes a debuggable HX_STACK_ARG only when it is a user local of a
	// reflectable, non-native type whose name is not a compiler temp.
	public static function cppNoDebugSymbol(debug:Int, v:TVar):Bool {
		if (debug <= 1) return true;
		if (!v.kind.match(VUser(_))) return true;
		return switch (CppTypeOf.cppTypeOf(v.type)) {
			case TCppStar(_, _) | TCppReference(_): true;
			case TCppInst(c, _) if (TypeFunctions.hasMeta(":structAccess", c.meta) || TypeFunctions.hasMeta(":unreflective", c.meta)): true;
			case _:
				var name = v.name;
				name.length > 4 && name.substr(0, 4) == "_hx_";
		};
	}

	// The level>=2 debugger prologue that follows the stack frame: register `this` (a member method uses
	// `this`, a closure `__this`) and each inspectable argument as a stack variable, then mark the body's
	// opening line so a breakpoint on the signature resolves to a real position.
	static function hxStackDebugVars(w:CppWriter, debug:Int, isStatic:Bool, realThisPtr:Bool, args:Array<TVar>, frameLine:Int):Void {
		if (debug < 2) return;
		if (!isStatic) w.write("            \tHX_STACK_THIS(" + (realThisPtr ? "this" : "__this") + ")\n");
		for (v in args) if (!cppNoDebugSymbol(debug, v))
			w.write("            \tHX_STACK_ARG(" + CppTypeText.cppVarNameOf(v) + ",\"" + v.name + "\")\n");
		w.write("HXLINE(" + StringTools.lpad(Std.string(frameLine), " ", 4) + ")\n");
	}

	function genFieldCpp(w:CppWriter, isStatic:Bool, field:TClassField):Void {
		switch (field.expr == null ? null : field.expr.expr) {
			case TFunction(tf):
				if (fieldIsDynamic(field)) {
					// A dynamic method emits its default-value closure as __default_<name>, and a static
					// one also emits its ::Dynamic storage (referenced by __GetStatic and boot).
					var funcName = "__default_" + nativeFieldNameRemap(isStatic, field);
					var isVoidD = CppTypeOf.cppTypeOf(tf.type).match(TCppVoid);
					w.write("HX_BEGIN_DEFAULT_FUNC(" + funcName + "," + className + ")\n");
					w.write((isVoidD ? "void" : ctxTypeString(tf.type)) + " _hx_run(" + ctxArgList(tf.args, "__o_") + ")");
					var dotNameD = joinPath(classDef.path, ".");
					var frameLineD = CppEmit.getErrorLine(tf.expr.pos);
					var frameFileD = tf.expr.pos.file;
					var dbgD = fieldDebugLevel(field);
					var emitD = new CppEmit(com, w, dbgD, false, cppFileId);
					var defaultsD = [for (a in tf.args) {v: a.v, dflt: a.c}];
					emitD.genExpressionTree([for (a in tf.args) a.v], tf.type, tf.expr,
						function(gc) { emitD.cppGenDefaultValues(defaultsD, "__o_"); hxStackPush(com, w, dotNameD, funcName, frameFileD, frameLineD, gc, cppFileId, dbgD); hxStackDebugVars(w, dbgD, isStatic, false, [for (a in tf.args) a.v], frameLineD); }, null, dotNameD, funcName);
					w.write("HX_END_LOCAL_FUNC" + tf.args.length + "(" + (isVoidD ? "(void)" : "return ") + ")\n");
					w.write("HX_END_DEFAULT_FUNC\n\n");
					if (isStatic) w.write("::Dynamic " + className + "::" + nativeFieldNameRemap(isStatic, field) + ";\n\n");
					return;
				}
				var returnCpp = CppTypeOf.cppTypeOf(tf.type);
				var isVoid = returnCpp.match(TCppVoid);
				var name = nativeFieldNameRemap(isStatic, field);
				w.write((isVoid ? "void" : ctxTypeString(tf.type)) + " " + className + "::" + name + "(" + ctxArgList(tf.args) + ")");
				// The body: emit via CppEmit with the stack-frame prologue
				var dotName = joinPath(classDef.path, ".");
				var file = field.pos.file;
				// The stack-frame line is the error line of the body's position (expr.pos).
				var frameLine = CppEmit.getErrorLine(tf.expr.pos);
				var frameFile = tf.expr.pos.file;
				// The body prologue unpacks optional-argument defaults, then pushes the frame.
				var dbg = fieldDebugLevel(field);
				var emit = new CppEmit(com, w, dbg, !isStatic, cppFileId);
				var defaults = [for (a in tf.args) {v: a.v, dflt: a.c}];
				emit.genExpressionTree([for (a in tf.args) a.v], tf.type, tf.expr,
					function(gc) { emit.cppGenDefaultValues(defaults, "__o_"); hxStackPush(com, w, dotName, field.name, frameFile, frameLine, gc, cppFileId, dbg); hxStackDebugVars(w, dbg, isStatic, true, [for (a in tf.args) a.v], frameLine); }, null, dotName, field.name);
				w.write("\n\n");
				// doDynamic = (nonVirtual || !isOverride) && reflective. A @:nonVirtual override still gets
				// its dynamic wrapper (matching the header decl at genMemberDefHeader).
				var doDynamic = (TypeFunctions.hasMeta(":nonVirtual", field.meta) || !isOverride(field)) && reflective(field);
				if (doDynamic) {
					// A method whose return or an argument is a native pointer / @:structAccess struct
					// cannot round-trip through HX_DEFINE_DYNAMIC_FUNC (each value passes as a Dynamic);
					// emit a _hx_wrap thunk that casts those values, plus a _dyn() built through
					// Create*Function.
					var tcppArgs = [for (a in tf.args) CppTypeOf.cppTypeOf(a.v.type)];
					function needsWrapper(t:CppType):Bool return switch (t) {
						case TCppStar(_, _): true;
						case TCppInst(c, _): TypeFunctions.hasMeta(":structAccess", c.meta);
						case _: false;
					};
					if (needsWrapper(returnCpp) || Lambda.exists(tcppArgs, needsWrapper)) {
						var wrapName = "_hx_wrap" + className + "_" + name;
						w.write("static ::Dynamic " + wrapName + "( ");
						var sep = " ";
						if (!isStatic) { w.write("::hx::Object *obj"); sep = ","; }
						for (i in 0...tcppArgs.length) { w.write(sep + "const Dynamic &a" + i); sep = ","; }
						w.write(") {\n\t");
						if (!isVoid) switch (returnCpp) {
							case TCppStar(_, _): w.write("return (cpp::Pointer<const void *>) ");
							case TCppInst(c, _) if (TypeFunctions.hasMeta(":structAccess", c.meta)):
								w.write("return (cpp::Struct< " + CppTypeText.tcppToString(returnCpp) + " >) ");
							case _: w.write("return ");
						}
						w.write(isStatic ? (className + "::" + name + "(") : ("reinterpret_cast< " + className + " *>(obj)->" + name + "("));
						var sep2 = "";
						for (i in 0...tcppArgs.length) {
							w.write(sep2); sep2 = ",";
							switch (tcppArgs[i]) {
								case TCppStar(t, isConst): w.write("(cpp::" + (isConst ? "Const" : "") + "Pointer<" + CppTypeText.tcppToString(t) + " >) ");
								case TCppInst(c, _) if (TypeFunctions.hasMeta(":structAccess", c.meta)):
									w.write("(cpp::Struct< " + CppTypeText.tcppToString(tcppArgs[i]) + " >) ");
								case _:
							}
							w.write("a" + i);
						}
						w.write(");\n");
						if (isVoid) w.write("\treturn null();\n");
						w.write("}\n");
						w.write("::Dynamic " + className + "::" + name + "_dyn() {\n\treturn ");
						w.write(isStatic
							? ("::hx::CreateStaticFunction" + tcppArgs.length + "(\"" + name + "\"," + wrapName + ");")
							: ("::hx::CreateMemberFunction" + tcppArgs.length + "(\"" + name + "\",this," + wrapName + ");"));
						w.write("}\n");
					} else {
						var ret = isVoid ? "(void)" : "return ";
						w.write((isStatic ? "STATIC_" : "") + "HX_DEFINE_DYNAMIC_FUNC" + tf.args.length + "(" + className + "," + name + "," + ret + ")\n\n");
					}
				}
			case _:
				// Data field: a static physical var gets its storage definition in the cpp (member vars
				// live only in the header); `<type> Class::name;`
				if (isStatic && TypeFunctions.isPhysicalField(field)) {
					var tcpp = CppTypeOf.cppTypeOf(field.type);
					w.write(CppTypeText.tcppToString(tcpp) + " " + className + "::" + nativeFieldNameRemap(isStatic, field) + ";\n\n");
				} else if (isAbstractMethod(field)) {
					// An abstract method defines only its reflective _dyn() wrapper (its virtual default
					// body lives inline in the header).
					var sig = switch (TypeFunctions.follow(field.type)) { case TFun(s): s; case _: null; };
					var ret = CppTypeOf.cppTypeOf(sig.ret).match(TCppVoid) ? "(void)" : "return ";
					w.write("HX_DEFINE_DYNAMIC_FUNC" + sig.args.length + "(" + className + "," + nativeFieldNameRemap(isStatic, field) + "," + ret + ")\n\n");
				}
		}
	}

	// The class .cpp file. Method bodies flow through CppEmit.
	public function genCpp():String {
		cppFileId = {v: -1};
		var w = new CppWriter();
		w.writeH("#include <hxcpp.h>\n\n");
		// Self + every referenced type (extern @:include files become @verbatim guarded includes), sorted
		// by dotted path, with the per-class scriptable flag as includeSuperArgs.
		var refs = CppReferenced.findReferencedTypesFlags(com, TClassDecl(classDef), "*", superDeps, constructorDeps, false, isScriptable()).deps;
		for (p in refs) addInclude(w, p);
		// A scriptable (cppia host) build pulls in the CppiaCtx dispatch header.
		if (isScriptable()) w.writeH("#include <hx/Scriptable.h>\n");
		w.writeH("\n");
		// @:cppFileCode is injected verbatim at file scope (before the namespace opens), then any
		// @:cppInclude files.
		w.write(getClassCode(classDef, ":cppFileCode"));
		for (inc in CppReferenced.getAllMetaStringPath(classDef.meta, ":cppInclude")) w.write("#include \"" + inc + "\"\n");
		// The package namespaces open, then a blank line between the header frames (HX_LOCAL_STACK_FRAME,
		// writeHUnique) and the body's first definition.
		genOpenNamespace(w);
		w.write("\n");
		// @:cppNamespaceCode is injected inside the opened namespace.
		w.write(getClassCode(classDef, ":cppNamespaceCode"));
		// An interface .cpp carries no instance scaffolding: just __mClass + a stripped __register
		// (mSuper/mMembers/TIsInterface), plus any static method bodies and __boot.
		if (TypeFunctions.hasClassFlag(classDef, CInterface)) {
			for (f in staticsExceptMeta()) genFieldCpp(w, true, f);
			w.write("\n");
			genMemberFieldsAndMarks(w);
			genScriptable(w);
			genRegister(w);
			genClassBoot(w);
			genCloseNamespace(w);
			return w.getHeader() + w.getBody();
		}
		// __construct: emit the ctor body (real this ptr), or an empty body when there is no constructor
		var ctorTf = ctorFuncDef();
		var ctorTypeArgs = constructorTypeArgs();
		if (ctorTf == null) {
			w.write("void " + className + "::__construct(" + ctorTypeArgs + ") { }\n\n");
		} else {
			w.write("void " + className + "::__construct(" + ctorTypeArgs + ")");
			var dotName = joinPath(classDef.path, ".");
			var frameLine = CppEmit.getErrorLine(ctorTf.expr.pos);
			var ctorDbg = classDef.constructor != null ? fieldDebugLevel(classDef.constructor) : baseDebugLevel();
			var emitCtor = new CppEmit(com, w, ctorDbg, true, cppFileId);
			var ctorDefaults = [for (a in ctorTf.args) {v: a.v, dflt: a.c}];
			emitCtor.genExpressionTree([for (a in ctorTf.args) a.v], ctorTf.type, ctorTf.expr,
				function(gc) { emitCtor.cppGenDefaultValues(ctorDefaults, "__o_"); hxStackPush(com, w, dotName, "new", ctorTf.expr.pos.file, frameLine, gc, cppFileId, ctorDbg); hxStackDebugVars(w, ctorDbg, false, true, [for (a in ctorTf.args) a.v], frameLine); }, null, dotName, "new");
			// A real ctor body is followed by a single newline (an empty ctor uses " { }\n\n").
			w.write("\n");
		}
		// An abstract class emits no __CreateEmpty/_hx_vtable/__Create bodies.
		if (!TypeFunctions.hasClassFlag(classDef, CAbstract)) {
			w.write("Dynamic " + className + "::__CreateEmpty() { return new " + className + "; }\n\n");
			w.write("void *" + className + "::_hx_vtable = 0;\n\n");
			// __Create passes the constructor args out of the DynamicArray
			var createArgs = [for (i in 0...constructorArgNames().length) "inArgs[" + i + "]"].join(",");
			w.write("Dynamic " + className + "::__Create(::hx::DynamicArray inArgs)\n{\n\t::hx::ObjectPtr< " + className + " > _hx_result = new " + className + "();\n\t_hx_result->__construct(" + createArgs + ");\n\treturn _hx_result;\n}\n\n");
		}
		genIsInstanceOf(w);
		// The interface-implementation vtable structs + _hx_getInterface dispatch.
		genInterfaceGlue(w);
		// The class-init block: `void C::__init__() { <init> }`.
		genClassInit(w);
		// Members first, then statics (staticsExceptMeta).
		for (f in classDef.orderedFields) if (TypeFunctions.isPhysicalField(f)) genFieldCpp(w, false, f);
		for (f in staticsExceptMeta()) if (TypeFunctions.isPhysicalField(f)) genFieldCpp(w, true, f);
		// A "\n" after the field loops (before the non-inline constructor bodies).
		w.write("\n");
		// __alloc_dynamic_functions: install a dynamic method's default closure if unset, then chain to the
		// nearest super that also has dynamic member functions. Emitted right after the field bodies,
		// before the __new/__alloc constructor bodies.
		var dynFns = dynamicFunctions();
		if (dynFns.length > 0) {
			w.write("void " + className + "::__alloc_dynamic_functions(::hx::Ctx *_hx_ctx," + className + " *_hx_obj) {\n");
			for (f in dynFns) {
				var name = CppTypeText.cppMemberNameOf(f);
				w.write("\tif (!_hx_obj->" + name + ".mPtr) _hx_obj->" + name + " = new __default_" + name + "(_hx_obj);\n");
			}
			if (classDef.superClass != null) {
				var sc = classDef.superClass.c;
				while (sc != null) {
					if (hasDynamicMemberFunctions(sc)) { w.write("\t" + objScope(sc) + "::__alloc_dynamic_functions(_hx_ctx,_hx_obj);\n"); break; }
					sc = sc.superClass != null ? sc.superClass.c : null;
				}
			}
			w.write("}\n");
		}
		// A non-inline constructor emits its __new/__alloc bodies in the cpp, after
		// __alloc_dynamic_functions and before the default constructor. An abstract class emits no
		// __new/__alloc bodies.
		if (!canInlineConstructor() && !TypeFunctions.hasClassFlag(classDef, CAbstract)) outputConstructorCpp(w);
		// The C++ default constructor installs each dynamic method's default closure.
		w.write(className + "::" + className + "()\n{\n");
		for (f in dynFns) {
			var name = CppTypeText.cppMemberNameOf(f);
			w.write("\t" + name + " = new __default_" + name + "(this);\n");
		}
		w.write("}\n\n");
		// __Mark/__Visit are emitted after the default constructor, before the reflection methods.
		if (hasNewGcReferences(classDef)) genMarkVisit(w);
		// Reflection methods (each gated on the presence of a reflective field of the right kind)
		if (hasGetMemberField()) genField(w);
		if (hasGetStaticField()) genGetStatic(w);
		if (hasSetMemberField()) genSetField(w);
		if (hasSetStaticField()) genSetStatic(w);
		if (hasGetFields()) genGetFields(w);
		genScriptableStorage(w);
		genMemberFieldsAndMarks(w);
		genScriptable(w);
		genRegister(w);
		genClassBoot(w);
		genCloseNamespace(w);
		return w.getHeader() + w.getBody();
	}

	// A @:nativeGen class is emitted as a plain C++ class (no _obj, no hx::Object base, no vtable /
	// __register / __boot / reflection): just its members, and its constructor body.
	public function genNativeGenHeader():String {
		var w = new CppWriter();
		w.writeH("#ifndef INCLUDED_" + defString + "\n#define INCLUDED_" + defString + "\n\n");
		// The header-file prologue for a @:nativeGen class.
		w.writeH("#ifndef HXCPP_H\n#ifdef HXCPP_API_LEVEL\n#include <hxcpp.h>\n#else\n#include <hx/Native.h>\n#endif\n#endif\n\n");
		// A nativeGen class extending a base emits `: public <native-instance-type>` and includes the
		// base's header (its @:include files, or the base's own header).
		var superName = classDef.superClass != null
			? CppTypeText.tcppToStringSuffix("_obj", CppTypeOf.cppInstanceTypeOf(classDef.superClass.c, classDef.superClass.params))
			: "";
		if (classDef.superClass != null) {
			var superClass = classDef.superClass.c;
			var includeFiles = CppReferenced.getAllMetaStringPath(superClass.meta, ":include");
			if (includeFiles.length > 0) for (inc in includeFiles) w.writeHUnique(guardedInclude(inc));
			else addInclude(w, superClass.path);
		}
		// The forward declarations, which for a nativeGen class are the @verbatim includes: the class's
		// own header plus any the referenced types pull in. They go to the body, so an @:include already
		// written to the header by the super above is emitted a second time here (the header and body
		// writers keep separate dedup state).
		var refs = CppReferenced.findReferencedTypesFlags(com, TClassDecl(classDef), "*", superDeps, constructorDeps, true, isScriptable());
		for (i in 0...refs.deps.length) CppReferenced.genForwardDecl(w, refs.deps[i], refs.flags[i]);
		w.write("\n");
		genOpenNamespace(w);
		w.write("\n\n");
		w.write("class HXCPP_CLASS_ATTRIBUTES " + smartName + (superName == "" ? "" : " : public " + superName) + "\n{\n\tpublic:\n");
		if (classDef.constructor != null) {
			var ctorTf = ctorFuncDef();
			w.write("\t\t" + smartName + "(" + (ctorTf != null ? ctxArgList(ctorTf.args, "") : "") + ");\n\n");
		}
		for (f in classDef.orderedFields) genNativeGenMemberDecl(w, false, f);
		for (f in classDef.orderedStatics) genNativeGenMemberDecl(w, true, f);
		w.write("};\n\n");
		genCloseNamespace(w);
		w.write("\n#endif /* INCLUDED_" + defString + " */ \n");
		return w.getHeader() + w.getBody();
	}

	function genNativeGenMemberDecl(w:CppWriter, isStatic:Bool, f:TClassField):Void {
		var prefix = isStatic ? "\t\tstatic " : "\t\t";
		if (isMemberVar(f)) {
			w.write(prefix + ctxTypeString(f.type) + " " + CppTypeText.cppMemberNameOf(f) + ";\n");
		} else if (isMethodField(f)) switch (f.expr.expr) {
			case TFunction(tf):
				var ret = CppTypeOf.cppTypeOf(tf.type).match(TCppVoid) ? "void" : ctxTypeString(tf.type);
				// A method declaration closes with a blank line.
				w.write(prefix + ret + " " + CppTypeText.cppMemberNameOf(f) + "(" + ctxArgList(tf.args, "") + ");\n\n");
			case _:
		}
	}

	public function genNativeGenCpp():String {
		cppFileId = {v: -1};
		var w = new CppWriter();
		w.writeH("#include <hxcpp.h>\n\n");
		// The referenced-type walk runs for a nativeGen class too: the class's own header is a @verbatim
		// include (path/Name.h), and an extern super's @:include files (BoolVector's @:include("vector"))
		// come in through the super() call in the constructor body, so the cpp includes them.
		var refs = CppReferenced.findReferencedTypesFlags(com, TClassDecl(classDef), "*", superDeps, constructorDeps, false, false).deps;
		for (p in refs) addInclude(w, p);
		w.writeH("\n");
		genOpenNamespace(w);
		// One newline after the namespace opens.
		w.write("\n");
		var dotName = joinPath(classDef.path, ".");
		// The field bodies come first; outputNativeConstructor runs after the field loop, separated by the
		// loop's trailing newline.
		for (f in classDef.orderedFields) genNativeGenMethodCpp(w, false, f);
		for (f in classDef.orderedStatics) genNativeGenMethodCpp(w, true, f);
		w.write("\n");
		var ctorTf = ctorFuncDef();
		if (ctorTf != null) {
			var frameLine = CppEmit.getErrorLine(ctorTf.expr.pos);
			w.write(smartName + "::" + smartName + "(" + ctxArgList(ctorTf.args, "") + ")");
			var ctorDbg = classDef.constructor != null ? fieldDebugLevel(classDef.constructor) : baseDebugLevel();
			var emitCtor = new CppEmit(com, w, ctorDbg, true, cppFileId);
			// A super() call in the ctor body is emitted as a C++ base initializer list.
			if (classDef.superClass != null) {
				var superArgs = findSuperArgs(ctorTf.expr);
				if (superArgs != null) {
					var superName = CppTypeText.tcppToStringSuffix("_obj", CppTypeOf.cppInstanceTypeOf(classDef.superClass.c, classDef.superClass.params));
					emitCtor.genConstructorSuperInit(superName, superArgs, [for (a in ctorTf.args) a.v]);
				}
			}
			var ctorDefaults = [for (a in ctorTf.args) {v: a.v, dflt: a.c}];
			emitCtor.genExpressionTree([for (a in ctorTf.args) a.v], ctorTf.type, ctorTf.expr,
				function(gc) { emitCtor.cppGenDefaultValues(ctorDefaults, "__o_"); hxStackPush(com, w, dotName, "new", ctorTf.expr.pos.file, frameLine, gc, cppFileId, ctorDbg); hxStackDebugVars(w, ctorDbg, false, true, [for (a in ctorTf.args) a.v], frameLine); }, null, dotName, "new");
		}
		genCloseNamespace(w);
		return w.getHeader() + w.getBody();
	}

	// The argument list of the first super() call reached at statement level in the constructor body
	// (unwrapping blocks, parentheses, metadata, and plain casts).
	function findSuperArgs(e:TExpr):Null<Array<TExpr>> {
		return switch (e.expr) {
			case TCall({expr: TConst(TSuper)}, args): args;
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null): findSuperArgs(e1);
			case TBlock(el):
				for (x in el) { var r = findSuperArgs(x); if (r != null) return r; }
				null;
			case _: null;
		};
	}

	function genNativeGenMethodCpp(w:CppWriter, isStatic:Bool, f:TClassField):Void {
		if (!isMethodField(f)) {
			// A @:nativeGen static physical var still needs its storage definition in the cpp (`<type>
			// Class::name;`), just like a normal class's static.
			if (isStatic && TypeFunctions.isPhysicalField(f))
				w.write(CppTypeText.tcppToString(CppTypeOf.cppTypeOf(f.type)) + " " + smartName + "::" + CppTypeText.cppMemberNameOf(f) + ";\n\n");
			return;
		}
		switch (f.expr.expr) {
			case TFunction(tf):
				var ret = CppTypeOf.cppTypeOf(tf.type).match(TCppVoid) ? "void" : ctxTypeString(tf.type);
				var name = CppTypeText.cppMemberNameOf(f);
				var dotName = joinPath(classDef.path, ".");
				var frameLine = CppEmit.getErrorLine(tf.expr.pos);
				w.write(ret + " " + smartName + "::" + name + "(" + ctxArgList(tf.args, "") + ")");
				var ngDbg = fieldDebugLevel(f);
				var emit = new CppEmit(com, w, ngDbg, !isStatic, cppFileId);
				var defaults = [for (a in tf.args) {v: a.v, dflt: a.c}];
				emit.genExpressionTree([for (a in tf.args) a.v], tf.type, tf.expr,
					function(gc) { emit.cppGenDefaultValues(defaults, "__o_"); hxStackPush(com, w, dotName, name, tf.expr.pos.file, frameLine, gc, cppFileId, ngDbg); hxStackDebugVars(w, ngDbg, isStatic, true, [for (a in tf.args) a.v], frameLine); }, null, dotName, name);
				// Every field body is followed by a double newline.
				w.write("\n\n");
			case _:
		}
	}

	// One `namespace <pack>{` per package part (keyword-remapped), closed in the same order with `} // end
	// namespace <pack>`.
	function genOpenNamespace(w:CppWriter):Void {
		for (ns in classDef.path.pack) w.write("namespace " + CppTypeText.keywordRemap(ns) + "{\n");
	}

	function genCloseNamespace(w:CppWriter):Void {
		for (ns in classDef.path.pack) w.write("} // end namespace " + ns + "\n");
	}

	function addInclude(w:CppWriter, path:hxc.core.Globals.Path):Void {
		if (path.pack.length == 1 && path.pack[0] == "@verbatim") {
			w.writeHUnique(guardedInclude(path.name));
			return;
		}
		var guard = joinPath(path, "_");
		var incPath = joinPath(path, "/");
		w.writeHUnique("#ifndef INCLUDED_" + guard + "\n#include <" + incPath + ".h>\n#endif\n");
	}

	// An @:include/@:depend file wrapped in a hash-named include guard.
	public static function guardedInclude(file:String):String {
		var guardName = "INCLUDED_" + hash64(file);
		return "#ifndef " + guardName + "\n#define " + guardName + "\n" + verbatimInclude(file) + "#endif\n";
	}

	// An @-prefixed file is an @import, otherwise a quoted #include.
	static function verbatimInclude(file:String):String {
		if (file.length > 0 && file.charAt(0) == "@") return "@import " + file.substr(1) + ";\n";
		return "#include \"" + file + "\"\n";
	}

	// _hx_isInstanceOf over the class's sorted id list.
	function genIsInstanceOf(w:CppWriter):Void {
		// addParent: the self class id and the sentinel 1, plus each super's class id up the chain
		// (stopping at the first super with no id), then sorted.
		var ids = [classId(), 1];
		var cls = classDef.superClass;
		while (cls != null) {
			var pid = typeIds.get("::" + joinPath(cls.c.path, "::"));
			if (pid == null) break;
			ids.push(pid);
			cls = cls.c.superClass;
		}
		ids.sort(Reflect.compare);
		w.write("bool " + className + "::_hx_isInstanceOf(int inClassId) {\n");
		dumpClasses(w, "\t", ids);
		w.write("}\n\n");
	}

	// A balanced binary search over the sorted class ids.
	function dumpClasses(w:CppWriter, indent:String, classes:Array<Int>):Void {
		inline function txt(c:Int):String return "0x" + StringTools.lpad(StringTools.hex(c, 8).toLowerCase(), "0", 8);
		switch (classes.length) {
			case 0:
			case 1: w.write(indent + "return inClassId==(int)" + txt(classes[0]) + ";\n");
			case 2: w.write(indent + "return inClassId==(int)" + txt(classes[0]) + " || inClassId==(int)" + txt(classes[1]) + ";\n");
			case _:
				var mid = classes[Std.int(classes.length / 2)];
				var low = [for (e in classes) if (e <= mid) e];
				var high = [for (e in classes) if (e > mid) e];
				w.write(indent + "if (inClassId<=(int)" + txt(mid) + ") {\n");
				dumpClasses(w, indent + "\t", low);
				w.write(indent + "} else {\n");
				dumpClasses(w, indent + "\t", high);
				w.write(indent + "}\n");
		}
	}

	// The class-init block: emit `void C::__init__() { <init body> }` (static context, no real this
	// ptr), pushing the __init__ stack frame; nothing when the class has no init.
	function genClassInit(w:CppWriter):Void {
		if (classDef.init == null) return;
		w.write("void " + className + "::__init__()");
		// The __init__ stack frame carries the qualified C++ class name as its dot name, not the dot path.
		var cppName = CppTypeText.cppClassName(classDef);
		var frameLine = CppEmit.getErrorLine(classDef.init.pos);
		// The class-init body gets a fresh file id counter reset to -1, so the __init__ stack frame and any
		// goto/const-array ids in its body use their own counter and do not advance the shared per-file
		// counter that numbers the methods' goto labels and const-array tables.
		var initFileId = {v: -1};
		// The class-init body runs at the global debug level (it is not dropped per-field), so a closure
		// inside __init__ still gets its debug>=2 stack registrations.
		var initDbg = baseDebugLevel();
		new CppEmit(com, w, initDbg, false, initFileId).genExpressionTree([], TypeFunctions.tDynamic, classDef.init,
			function(gc) hxStackPush(com, w, cppName, "__init__", classDef.init.pos.file, frameLine, gc, initFileId, initDbg), null, cppName, "__init__");
		w.write("\n\n");
	}

	// The flat _hx_<pack>_<Name> vtable-struct name of an interface.
	inline function interfaceImplName(iface:TClass):String return "_hx_" + joinPath(iface.path, "_");

	// The implemented-interface set: descend the real interfaces of interfaces through each
	// interface's own interfaces and superClass (transitive), skipping cpp.rtti markers; native-gen
	// interfaces land in a separate table (still descended). The emitted list prepends each key during
	// a hash-table walk, so its order is the REVERSE of the bucket walk over the flat _hx_ names,
	// reproduced through the hash-table order model.
	function implementedInterfaces():Array<TClass> {
		var byName = new Map<String, TClass>();
		var seen = new Map<String, Bool>();
		var nativeSeen = new Map<String, Bool>();
		var h = new hxc.core.NameHash.HashTableOrder();
		function descend(iface:TClass):Void {
			var nm = interfaceImplName(iface);
			var isNative = CppTypeOf.isNativeGenClass(iface);
			var table = isNative ? nativeSeen : seen;
			if (!table.exists(nm)) {
				table.set(nm, true);
				if (!isNative) {
					h.add(nm, hxc.core.NameHash.NameHash.stringHash(nm));
					byName.set(nm, iface);
				}
				for (imp in iface.interfaces) descend(imp.c);
			}
			if (iface.superClass != null) descend(iface.superClass.c);
		}
		for (imp in classDef.interfaces) {
			if (imp.c.path.pack.length == 2 && imp.c.path.pack[0] == "cpp" && imp.c.path.pack[1] == "rtti") continue;
			descend(imp.c);
		}
		var names = h.visitOrder();
		names.reverse();
		return [for (nm in names) byName.get(nm)];
	}

	// The native-gen subset of the implemented-interface set, emitted in hash-table bucket order (not
	// reversed by prepending), consumed by the HX_REGISTER_VTABLE_OFFSET registrations for a class
	// that implements a native interface.
	function nativeImplementedInterfaces():Array<TClass> {
		var byName = new Map<String, TClass>();
		var seen = new Map<String, Bool>();
		var nativeSeen = new Map<String, Bool>();
		var h = new hxc.core.NameHash.HashTableOrder();
		function descend(iface:TClass):Void {
			var nm = interfaceImplName(iface);
			var isNative = CppTypeOf.isNativeGenClass(iface);
			var table = isNative ? nativeSeen : seen;
			if (!table.exists(nm)) {
				table.set(nm, true);
				if (isNative) {
					h.add(nm, hxc.core.NameHash.NameHash.stringHash(nm));
					byName.set(nm, iface);
				}
				for (imp in iface.interfaces) descend(imp.c);
			}
			if (iface.superClass != null) descend(iface.superClass.c);
		}
		for (imp in classDef.interfaces) {
			if (imp.c.path.pack.length == 2 && imp.c.path.pack[0] == "cpp" && imp.c.path.pack[1] == "rtti") continue;
			descend(imp.c);
		}
		return [for (nm in h.visitOrder()) byName.get(nm)];
	}

	// The interface-implementation glue: one static vtable struct of the class's member-function pointers
	// per implemented interface, then _hx_getInterface dispatching the interface hash to its struct
	// (falling through to super). When a concrete method's signature differs from the interface's Dynamic
	// signature (covariant/overloaded), a cast-adapter forwarder is emitted and registered instead of the
	// raw member pointer.
	function genInterfaceGlue(w:CppWriter):Void {
		var order = implementedInterfaces();
		if (order.length == 0) return;
		var cname = "_hx_" + joinPath(classDef.path, "_");
		var implnameFull = CppTypeText.cppClassName(classDef);
		var alreadyGlued = new Map<String, Bool>();
		var cppGlue:Array<String> = [];
		for (iface in order) {
			w.write("static " + CppTypeText.cppClassName(iface) + " " + cname + "_" + interfaceImplName(iface) + "= {\n");
			genInterfaceFuncs(w, iface, implnameFull, interfaceImplName(iface), alreadyGlued, cppGlue);
			w.write("};\n\n");
		}
		// The glue lists are built by PREPENDING each forwarder then emitted as-is, so the output reads in
		// reverse insertion order (interfaces in order, each interface's orderedFields).
		cppGlue.reverse();
		headerGlue.reverse();
		// The glue forwarder bodies precede the _hx_getInterface dispatch. Each body already ends in
		// "\n}\n", and the bodies are joined with a single "\n".
		if (cppGlue.length > 0) w.write(cppGlue.join("\n"));
		w.write("void *" + className + "::_hx_getInterface(int inHash) {\n");
		w.write("\tswitch(inHash) {\n");
		for (iface in order)
			w.write("\t\tcase (int)" + genHash(0, joinPath(iface.path, "::")) + ": return &" + cname + "_" + interfaceImplName(iface) + ";\n");
		w.write("\t}\n");
		// A root class (no super) falls back to super::_hx_getInterface only when scriptable, else returns
		// 0; a subclass returns super unconditionally.
		if (classDef.superClass == null)
			w.write("\t#ifdef HXCPP_SCRIPTABLE\n\treturn super::_hx_getInterface(inHash);\n\t#else\n\treturn 0;\n\t#endif\n");
		else
			w.write("\treturn super::_hx_getInterface(inHash);\n");
		w.write("}\n\n");
	}

	function glueOrder(a:String, b:String):Int {
		function nameOf(text:String):String {
			var end = text.indexOf("(");
			var prefix = text.substr(0, end);
			var space = prefix.lastIndexOf(" ");
			var scope = prefix.lastIndexOf("::");
			return scope > space ? prefix.substr(scope + 2) : prefix.substr(space + 1);
		}
		return Reflect.compare(nameOf(a), nameOf(b));
	}

	// The member-function-pointer cast text for a function type.
	function cppTfunSig(ret:T, args:Array<hxc.core.Type.TSignatureArg>):String {
		return "( " + ctxTypeString(ret) + " (::hx::Object::*)(" + ctxTfunArgList(args, false) + "))";
	}

	// The concrete (this-class-or-super) implementation's signature for an interface method name, used to
	// detect when a cast-adapter forwarder is needed.
	function findClassImplementation(name:String):String {
		var def = classDef;
		while (def != null) {
			for (f in def.orderedFields) if (f.name == name) {
				return switch [TypeFunctions.follow(f.type), f.kind] {
					case [_, Method(MethDynamic)]: "";
					case [TFun(sig), Method(_)]: cppTfunSig(sig.ret, sig.args);
					case _: "";
				};
			}
			def = def.superClass != null ? def.superClass.c : null;
		}
		return "";
	}

	// A member-function-pointer cast per interface method, super first. When the concrete implementation's
	// signature differs from the interface's Dynamic signature, a cast-adapter forwarder (glue) is emitted
	// once and registered in the vtable in place of the raw pointer.
	function genInterfaceFuncs(w:CppWriter, iface:TClass, implnameFull:String, interfaceName:String,
			alreadyGlued:Map<String, Bool>, cppGlue:Array<String>):Void {
		for (field in virtualFieldsOf(iface)) switch [TypeFunctions.follow(field.type), field.kind] {
			case [_, Method(MethDynamic)]:
			case [TFun(sig), Method(_)]:
				var castSig = cppTfunSig(sig.ret, sig.args);
				var classImpl = findClassImplementation(field.name);
				var realName = CppTypeText.cppMemberNameOf(field);
				// IMap.set is overloaded in the impl (String/Int/... keys); force a glue so C++ can pick
				// the member-pointer overload by the forwarder's explicit signature.
				var castKey = realName + "::" + castSig + (interfaceName == "_hx_haxe_IMap" && realName == "set" ? "*" : "");
				var implementationKey = realName + "::" + classImpl;
				if (castKey != implementationKey) {
					var glue = field.name + "_" + StringTools.lpad(StringTools.hex(CppTypeText.genHash32(0, castSig), 8).toLowerCase(), "0", 8);
					if (!alreadyGlued.exists(castKey)) {
						alreadyGlued.set(castKey, true);
						var argList = ctxTfunArgList(sig.args, true);
						var returnType = ctxTypeString(sig.ret);
						var returnStr = returnType == "void" ? "" : "return ";
						var argNames = [for (a in sig.args) CppTypeText.keywordRemap(a.name)].join(",");
						cppGlue.push(returnType + " " + className + "::" + glue + "(" + argList + ") {\n"
							+ "\t\t\t" + returnStr + realName + "(" + argNames + ");\n}\n");
						headerGlue.push("\t\t" + returnType + " " + glue + "(" + argList + ");\n");
					}
					w.write("\t" + castSig + "&" + implnameFull + "::" + glue + ",\n");
				} else {
					w.write("\t" + castSig + "&" + implnameFull + "::" + realName + ",\n");
				}
			case _:
		}
	}

	// A Var or a dynamic method (a MethDynamic backed by a Dynamic member) is a data member. A dynamic
	// method is a physical field but also carries a TFunction body, so it must be classified as a member
	// variable (storage/reflection read a Dynamic field, not a _dyn() wrapper).
	function isMemberVar(f:TClassField):Bool {
		return TypeFunctions.isPhysicalField(f) && (!isMethodField(f) || fieldIsDynamic(f));
	}

	function isAbstractImpl():Bool {
		return classDef.kind.match(KAbstractImpl(_));
	}
	// A field is reflectively readable (into __Field/__GetStatic) unless it is a non-physical read-Never
	// property, an inline var, or an abstract-impl var. A get-property is readable.
	function isReadable(f:TClassField):Bool {
		return switch (f.kind) {
			case Var(k) if (k.read == AccNever && !TypeFunctions.isPhysicalField(f)): false;
			case Var(k) if (k.read == AccInline): false;
			case Var(_) if (isAbstractImpl()): false;
			case _: true;
		};
	}
	// The counterpart of isReadable for __SetField/__SetStatic (a set-property is writable).
	function isWritable(f:TClassField):Bool {
		return switch (f.kind) {
			case Var(k) if (k.write == AccNever && !TypeFunctions.isPhysicalField(f)): false;
			case Var(k) if (k.read == AccInline): false;
			case Var(_) if (isAbstractImpl()): false;
			case _: true;
		};
	}
	// A field written as a plain variable (a var/property, or a dynamic method's Dynamic member), excluding
	// real methods and abstract methods. __SetField/__SetStatic only assign these.
	function variableField(f:TClassField):Bool {
		if (f.expr == null) return !TypeFunctions.hasClassFieldFlag(f, CfAbstract);
		return switch (f.expr.expr) { case TFunction(_): fieldIsDynamic(f); case _: true; };
	}

	// Instance fields that are dynamic haxe methods (a Dynamic member initialized to a __default_<name>
	// closure at construction). The list is built by PREPENDING, so every consumer sees the REVERSE of
	// orderedFields.
	function dynamicFunctions():Array<TClassField> {
		var fns = [for (f in classDef.orderedFields) if (fieldIsDynamic(f)) f];
		fns.reverse();
		return fns;
	}
	static function hasDynamicMemberFunctions(c:TClass):Bool {
		for (f in c.orderedFields) if (isDynamicFieldIn(c, f)) return true;
		return false;
	}
	// The remapped class path joined with "::", plus "_obj" (no leading ::), used for the
	// __alloc_dynamic_functions references.
	static function objScope(c:TClass):String {
		return joinPath(c.path, "::") + "_obj";
	}
	// The nearest self-or-super class declaring dynamic member functions, whose __alloc_dynamic_functions
	// installs the defaults (it recurses to the next such super itself).
	function nearestDynamicClass():Null<TClass> {
		var c = classDef;
		while (c != null) {
			if (hasDynamicMemberFunctions(c)) return c;
			c = c.superClass != null ? c.superClass.c : null;
		}
		return null;
	}

	// A switch on inName.length, one HX_FIELD_EQ test per field (sorted by length, a `break;` before each
	// new case label except the first).
	function dumpQuickFieldTest(w:CppWriter, entries:Array<{name:String, result:String}>):Void {
		if (entries.length == 0) return;
		entries.sort(function(a, b) return a.name.length - b.name.length);
		w.write("\tswitch(inName.length) {\n");
		var lenCase = -1;
		for (e in entries) {
			if (e.name.length != lenCase) {
				if (lenCase >= 0) w.write("\t\tbreak;\n");
				w.write("\tcase " + e.name.length + ":\n");
				lenCase = e.name.length;
			}
			w.write("\t\tif (HX_FIELD_EQ(inName,\"" + e.name + "\") ) { " + e.result + " }\n");
		}
		w.write("\t}\n");
	}

	// toDynamic / toVal wrappers: a plain field value is wrapped `( v )` / `::hx::Val( v )`.
	// A reflective read/write of a @:structAccess or native-pointer field casts the Dynamic through
	// cpp::Struct<T> / cpp::Pointer<T> (the boxed forms), not the raw C++ type.
	function castOf(f:TClassField):String {
		var ct = CppTypeOf.cppTypeOf(f.type);
		return switch (ct) {
			case TCppInst(c, _) if (TypeFunctions.hasMeta(":structAccess", c.meta)):
				"cpp::Struct< " + CppTypeText.tcppToString(ct) + " > ";
			case TCppStar(t, _):
				"cpp::Pointer< " + CppTypeText.tcppToString(t) + " >";
			case _:
				CppTypeText.tcppToString(ct);
		};
	}

	// toCommon: every reflective read wraps `t( value )`, boxing cpp.Struct payloads and raw pointers
	// first.
	function toCommon(t:String, f:TClassField, value:String):String {
		var ct = CppTypeOf.cppTypeOf(f.type);
		var inner = switch (ct) {
			case TCppInst(c, _) if (TypeFunctions.hasMeta(":structAccess", c.meta)):
				"cpp::Struct< " + CppTypeText.tcppToString(ct) + " >( " + value + " )";
			case TCppStar(_, _):
				"cpp::Pointer<void *>( " + value + " )";
			case _: value;
		};
		return t + "( " + inner + " )";
	}
	inline function toVal(f:TClassField, value:String):String return toCommon("::hx::Val", f, value);
	inline function toDynamic(f:TClassField, value:String):String return toCommon("", f, value);

	function hasGetMemberField():Bool {
		for (f in classDef.orderedFields) if (reflective(f) && isReadable(f)) return true;
		return false;
	}
	function hasSetMemberField():Bool {
		for (f in classDef.orderedFields) if (reflective(f) && isWritable(f) && variableField(f)) return true;
		return false;
	}
	// A non-function-typed field (excludes methods and dynamic methods, whose type is a TFun), as
	// listed by __GetFields / Reflect.fields.
	static function isDataField(f:TClassField):Bool {
		// The C++ generator follows abstracts (followWithAbstracts), so a var whose type is a non-core
		// abstract over a function (for example cpp.Callable) is a function field, not data.
		return switch (TypeFunctions.followWithAbstracts(f.type)) { case TFun(_): false; case _: true; };
	}
	function hasGetFields():Bool {
		for (f in classDef.orderedFields) if (isDataField(f)) return true;
		return false;
	}
	function hasSetStaticField():Bool {
		for (f in staticsExceptMeta()) if (reflective(f) && isWritable(f) && variableField(f)) return true;
		return false;
	}

	// __Field: reflective member reads (a var reads directly, a method via *_dyn()).
	function genField(w:CppWriter):Void {
		w.write("::hx::Val " + className + "::__Field(const ::String &inName,::hx::PropertyAccess inCallProp)\n{\n");
		var entries = [];
		for (f in classDef.orderedFields) if (reflective(f) && isReadable(f)) {
			var access = CppTypeText.cppMemberNameOf(f) + (isMemberVar(f) ? "" : "_dyn()");
			// A read-AccCall property routes through its getter: a non-physical one always, a physical one
			// via
			// a ternary that falls back to the backing field.
			var result = switch (f.kind) {
				case Var(k) if (k.read == AccCall && !TypeFunctions.isPhysicalField(f)):
					"if (" + checkPropCall(f) + ") return " + toVal(f, CppTypeText.keywordRemap("get_" + f.name) + "()") + ";";
				case Var(k) if (k.read == AccCall):
					"return " + toVal(f, checkPropCall(f) + " ? " + CppTypeText.keywordRemap("get_" + f.name) + "() : " + access) + ";";
				case _:
					"return " + toVal(f, access) + ";";
			};
			entries.push({name: f.name, result: result});
		}
		dumpQuickFieldTest(w, entries);
		w.write("\treturn super::__Field(inName,inCallProp);\n}\n\n");
	}

	// __GetStatic: reflective static reads (var wrapped `( v )`, method via *_dyn()).
	function genGetStatic(w:CppWriter):Void {
		w.write("bool " + className + "::__GetStatic(const ::String &inName, Dynamic &outValue, ::hx::PropertyAccess inCallProp)\n{\n");
		var entries = [];
		for (f in staticsExceptMeta()) if (reflective(f) && isReadable(f)) {
			var access = CppTypeText.cppMemberNameOf(f) + (isMemberVar(f) ? "" : "_dyn()");
			// A read-AccCall static property routes through its getter under an allowed call.
			var result = switch (f.kind) {
				case Var(k) if (k.read == AccCall && !TypeFunctions.isPhysicalField(f)):
					"if (" + checkPropCall(f) + ") { outValue = " + toDynamic(f, CppTypeText.keywordRemap("get_" + f.name) + "()") + "; return true; }";
				case Var(k) if (k.read == AccCall):
					"outValue = " + toDynamic(f, checkPropCall(f) + " ? " + CppTypeText.keywordRemap("get_" + f.name) + "() : " + access) + "; return true;";
				case _ if (isMemberVar(f)):
					"outValue = " + toDynamic(f, CppTypeText.cppMemberNameOf(f)) + "; return true;";
				case _:
					"outValue = " + CppTypeText.cppMemberNameOf(f) + "_dyn(); return true;";
			};
			entries.push({name: f.name, result: result});
		}
		dumpQuickFieldTest(w, entries);
		w.write("\treturn false;\n}\n\n");
	}

	// __SetField: reflective member-var writes.
	function genSetField(w:CppWriter):Void {
		w.write("::hx::Val " + className + "::__SetField(const ::String &inName,const ::hx::Val &inValue,::hx::PropertyAccess inCallProp)\n{\n");
		var entries = [];
		for (f in classDef.orderedFields) if (reflective(f) && isWritable(f) && variableField(f))
			entries.push({name: f.name, result: setFieldAction(f, "inValue", "inValue")});
		dumpQuickFieldTest(w, entries);
		w.write("\treturn super::__SetField(inName,inValue,inCallProp);\n}\n\n");
	}

	// A property (Var write AccCall) first routes through its set_ accessor when the property call is
	// allowed, then falls back to the direct field write (for a physical field).
	function setFieldAction(f:TClassField, valueVar:String, returnVar:String):String {
		var castable = castOf(f);
		var defaultAction = (isGcElement(CppTypeOf.cppTypeOf(f.type))
			? "_hx_set_" + CppTypeText.cppMemberNameOf(f) + "(HX_CTX_GET," + valueVar + ".Cast< " + castable + " >());"
			: CppTypeText.cppMemberNameOf(f) + "=" + valueVar + ".Cast< " + castable + " >();") + " return " + returnVar + ";";
		return switch (f.kind) {
			case Var(k) if (k.write == AccCall):
				var inVal = "(" + valueVar + ".Cast< " + castable + " >())";
				var setter = CppTypeText.keywordRemap("set_" + f.name);
				"if (" + checkPropCall(f) + ") return " + toVal(f, setter + inVal) + ";"
					+ (TypeFunctions.isPhysicalField(f) ? defaultAction : "");
			case _: defaultAction;
		};
	}

	// A @:nativeProperty field/class accepts any non-Never access, otherwise only paccAlways routes through
	// the accessor.
	function checkPropCall(f:TClassField):String {
		return (TypeFunctions.hasMeta(":nativeProperty", classDef.meta) || TypeFunctions.hasMeta(":nativeProperty", f.meta)
			|| com.defines.rawDefined("force_native_property")) ? "inCallProp != ::hx::paccNever" : "inCallProp == ::hx::paccAlways";
	}

	// Only under the generational GC define is an object member a GC element.
	function isGcElement(t:CppType):Bool {
		return isGcElementFor(com, t);
	}

	public static function isGcElementFor(com:Context, t:CppType):Bool {
		return com.defines.rawDefined("HXCPP_GC_GENERATIONAL") && isObjectElement(t);
	}

	// __SetStatic: reflective static-var writes.
	function genSetStatic(w:CppWriter):Void {
		w.write("bool " + className + "::__SetStatic(const ::String &inName,Dynamic &ioValue,::hx::PropertyAccess inCallProp)\n{\n");
		var entries = [];
		for (f in staticsExceptMeta()) if (reflective(f) && isWritable(f) && variableField(f)) {
			var castable = castOf(f);
			var defaultAction = CppTypeText.cppMemberNameOf(f) + "=ioValue.Cast< " + castable + " >(); return true;";
			// A write-AccCall static property routes through its setter under an allowed call, then (for a
			// physical field) falls back to the direct write.
			var result = switch (f.kind) {
				case Var(k) if (k.write == AccCall):
					"if (" + checkPropCall(f) + ")  ioValue = " + toDynamic(f, CppTypeText.keywordRemap("set_" + f.name) + "(ioValue.Cast< " + castable + " >())") + ";"
						+ (TypeFunctions.isPhysicalField(f) ? " else " + defaultAction : "");
				case _:
					defaultAction;
			};
			entries.push({name: f.name, result: result});
		}
		dumpQuickFieldTest(w, entries);
		w.write("\treturn false;\n}\n\n");
	}

	// __GetFields: push each member-var name, then chain to super.
	function genGetFields(w:CppWriter):Void {
		w.write("void " + className + "::__GetFields(Array< ::String> &outFields)\n{\n");
		for (f in classDef.orderedFields) if (isDataField(f))
			w.write("\toutFields->push(" + CppTypeText.strq(smartStrings, f.name) + ");\n");
		w.write("\tsuper::__GetFields(outFields);\n};\n\n");
	}

	static function isMethodField(f:TClassField):Bool {
		return (f.expr != null && switch (f.expr.expr) { case TFunction(_): true; case _: false; }) || isAbstractMethod(f);
	}

	// An abstract method (declared in an abstract class with no body) has no expr but is still a method:
	// it emits a `virtual ret name() { return 0; }` default and a _dyn() reflective wrapper, not a member
	// variable.
	static function isAbstractMethod(f:TClassField):Bool {
		return f.expr == null && TypeFunctions.hasClassFieldFlag(f, CfAbstract)
			&& switch (f.kind) { case Method(_): true; case _: false; };
	}

	static function fieldArgCount(f:TClassField):Int {
		return switch (TypeFunctions.follow(f.type)) { case TFun(sig): sig.args.length; case _: -1; };
	}

	// The StorageInfo fs kind for a field's C++ type.
	function storageFs(f:TClassField):String {
		return switch (CppTypeOf.cppTypeOf(f.type)) {
			case TCppScalar("bool"): "::hx::fsBool";
			case TCppScalar("int"): "::hx::fsInt";
			case TCppScalar("Float"): "::hx::fsFloat";
			case TCppString: "::hx::fsString";
			case o if (isObjectElement(o)): "::hx::fsObject /* " + CppTypeText.tcppToString(o) + " */ ";
			case u: "::hx::fsUnknown /* " + CppTypeText.tcppToString(u) + " */ ";
		};
	}

	// A member type the GC tracks as an object (a non-extern inst/interface, or any
	// dynamic/object/enum/string/function/array/wrapped/class type).
	static function isObjectElement(t:CppType):Bool {
		return switch (t) {
			case TCppInst(x, _) | TCppInterface(x): !CppTypeOf.isExternClass(x);
			case TCppDynamic | TCppObject | TCppObjectPtr | TCppEnum(_) | TCppString | TCppFunction(_, _, _)
				| TCppDynamicArray | TCppObjectArray(_) | TCppWrapped(_) | TCppScalarArray(_) | TCppClass: true;
			case _: false;
		}
	}

	// Reflective member fields (vars + methods) for sMemberFields / mMembers
	function reflectiveMembers():Array<TClassField> {
		return [for (f in classDef.orderedFields) if (reflective(f) && (isMemberVar(f) || isMethodField(f))) f];
	}

	function memberVars():Array<TClassField> {
		return [for (f in classDef.orderedFields) if (isMemberVar(f)) f];
	}
	function staticVars():Array<TClassField> {
		return [for (f in staticsExceptMeta()) if (isMemberVar(f)) f];
	}
	// The static fields minus __meta__/__rtti, which are not emitted as C++ class statics but live on the
	// runtime Class object (__mClass->__meta__, assigned at boot).
	function staticsExceptMeta():Array<TClassField> {
		return [for (f in classDef.orderedStatics) if (f.name != "__meta__" && f.name != "__rtti") f];
	}
	inline function isMetaField(f:TClassField):Bool {
		return f.name == "__meta__" || f.name == "__rtti";
	}
	// Any static data member exists.
	function hasMarkFunc():Bool {
		return staticVars().length > 0;
	}

	// The scriptable storage-info tables, emitted for classes only.
	function genScriptableStorage(w:CppWriter):Void {
		w.write("#ifdef HXCPP_SCRIPTABLE\n");
		var mv = memberVars();
		if (mv.length > 0) {
			w.write("static ::hx::StorageInfo " + className + "_sMemberStorageInfo[] = {\n");
			for (f in mv) w.write("\t{" + storageFs(f) + ",(int)offsetof(" + className + "," + CppTypeText.cppMemberNameOf(f) + ")," + CppTypeText.strq(smartStrings, f.name) + "},\n");
			w.write("\t{ ::hx::fsUnknown, 0, null()}\n};\n");
		} else w.write("static ::hx::StorageInfo *" + className + "_sMemberStorageInfo = 0;\n");
		var sv = staticVars();
		if (sv.length > 0) {
			w.write("static ::hx::StaticInfo " + className + "_sStaticStorageInfo[] = {\n");
			for (f in sv) w.write("\t{" + storageFs(f) + ",(void *) &" + className + "::" + CppTypeText.cppMemberNameOf(f) + "," + CppTypeText.strq(smartStrings, f.name) + "},\n");
			w.write("\t{ ::hx::fsUnknown, 0, null()}\n};\n");
		} else w.write("static ::hx::StaticInfo *" + className + "_sStaticStorageInfo = 0;\n");
		w.write("#endif\n\n");
	}

	// The sMemberFields list and the GC mark/visit funcs. These are emitted for interfaces too (an
	// interface's __register references sMemberFields, so the array must exist).
	function genMemberFieldsAndMarks(w:CppWriter):Void {
		var rm = reflectiveMembers();
		if (rm.length > 0) {
			w.write("static ::String " + className + "_sMemberFields[] = {\n");
			for (f in rm) w.write("\t" + CppTypeText.strq(smartStrings, f.name) + ",\n");
			w.write("\t::String(null()) };\n\n");
		}
		if (hasMarkFunc()) {
			w.write("static void " + className + "_sMarkStatics(HX_MARK_PARAMS) {\n");
			for (f in staticVars()) w.write("\tHX_MARK_MEMBER_NAME(" + className + "::" + CppTypeText.cppMemberNameOf(f) + ",\"" + f.name + "\");\n");
			w.write("};\n\n");
			w.write("#ifdef HXCPP_VISIT_ALLOCS\n");
			w.write("static void " + className + "_sVisitStatics(HX_VISIT_PARAMS) {\n");
			for (f in staticVars()) w.write("\tHX_VISIT_MEMBER_NAME(" + className + "::" + CppTypeText.cppMemberNameOf(f) + ",\"" + f.name + "\");\n");
			w.write("};\n\n");
			w.write("#endif\n\n");
		}
	}

	// __boot: run each static field's initializer.
	function genClassBoot(w:CppWriter):Void {
		if (!hasBootField(classDef)) return;
		w.write("void " + className + "::__boot()\n{\n");
		for (f in classDef.orderedStatics) genFieldInit(w, f);
		w.write("}\n\n");
	}

	// A var or a dynamic method (excluded from the script-function tables).
	static function isDataMember(f:TClassField):Bool {
		return switch (f.kind) { case Var(_) | Method(MethDynamic): true; case _: false; };
	}

	// A CPPIA_CALL trampoline that unpacks the call arguments from the CppiaCtx stack and invokes the real
	// method, returning the accumulated cppia signature string.
	function generateScriptFunction(w:CppWriter, isStatic:Bool, field:TClassField, scriptName:String, callName:String):String {
		switch (TypeFunctions.follow(field.type)) {
			case TFun(sig) if (!isDataMember(field)):
				var args = sig.args;
				var returnType = sig.ret;
				var isInterface = TypeFunctions.hasClassFlag(classDef, CInterface);
				var isTemplated = !isStatic && !isInterface;
				if (isTemplated) w.write("\ntemplate<bool _HX_SUPER=false>");
				w.write("\nstatic void CPPIA_CALL " + scriptName + "(::hx::CppiaCtx *ctx) {\n");
				var ret = switch (CppTypeOf.cppTypeOf(returnType)) { case TCppScalar("bool"): "b"; case _: CppScriptable.scriptSignature(returnType, false); };
				if (ret != "v") w.write("ctx->return" + CppScriptable.scriptType(returnType, false) + "(");
				function dumpCall(castPrefix:String):String {
					if (isInterface) w.write(className + "::" + callName + "(ctx->getThis()" + (args.length > 0 ? "," : ""));
					else if (isStatic) w.write(className + "::" + callName + "(");
					else w.write("((" + className + "*)ctx->getThis())->" + castPrefix + callName + "(");
					var signature = ret;
					var sep = "";
					var size = "sizeof(void*)";
					for (a in args) {
						w.write(sep + "ctx->get" + CppScriptable.scriptType(a.t, a.opt) + "(" + size + ")");
						signature += CppScriptable.scriptSignature(a.t, a.opt);
						sep = ",";
						size = size + "+sizeof(" + CppScriptable.scriptSizeType(a.t, a.opt) + ")";
					}
					w.write(")");
					return signature;
				}
				var signature;
				if (isTemplated) {
					w.write(" _HX_SUPER ? ");
					dumpCall(className + "::");
					w.write(" : ");
					signature = dumpCall("");
				} else {
					signature = dumpCall("");
				}
				if (ret != "v") w.write(")");
				w.write(";\n}\n");
				return signature;
			case _:
				return "";
		}
	}

	// The __scriptable subclass's override of one virtual method, which dispatches to a bound script (via
	// __scriptVTable) or falls back to the real class method.
	function dumpScriptField(w:CppWriter, idx:Int, field:TClassField):Void {
		var sig = switch (TypeFunctions.follow(field.type)) { case TFun(s): s; case _: return; };
		var fArgs = sig.args;
		var returnT = sig.ret;
		var isInterface = TypeFunctions.hasClassFlag(classDef, CInterface);
		var argsDecl = ctxTfunArgList(fArgs, true);
		var names = [for (a in fArgs) CppTypeText.keywordRemap(a.name)];
		var returnType = ctxTypeString(returnT);
		var ret = (returnType == "Void" || returnType == "void") ? " " : "return ";
		var name = CppTypeText.keywordRemap(field.name);
		var vtable = "__scriptVTable[" + (idx + 1) + "] ";
		w.write("\t" + returnType + " " + name + "( " + argsDecl + " ) {\n");
		if (isInterface) {
			w.write("\t\t::hx::CppiaCtx *__ctx = ::hx::CppiaCtx::getCurrent();\n");
			w.write("\t\t::hx::AutoStack __as(__ctx);\n");
			w.write("\t\t__ctx->pushObject(this);\n");
			for (a in fArgs) w.write("\t\t__ctx->push" + CppScriptable.scriptType(a.t, a.opt) + "(" + CppTypeText.keywordRemap(a.name) + ");\n");
			var interfaceSlot = Std.string(-(CppScriptable.cppGetInterfaceSlot(name)));
			w.write("\t\t" + ret + "__ctx->run" + CppScriptable.scriptType(returnT, false) + "(__GetScriptVTable()[" + interfaceSlot + "]);\n");
			w.write("\t}\n");
		} else {
			w.write("\tif (" + vtable + ") {\n");
			w.write("\t\t::hx::CppiaCtx *__ctx = ::hx::CppiaCtx::getCurrent();\n");
			w.write("\t\t::hx::AutoStack __as(__ctx);\n");
			w.write("\t\t__ctx->pushObject(this);\n");
			for (a in fArgs) w.write("\t\t__ctx->push" + CppScriptable.scriptType(a.t, a.opt) + "(" + CppTypeText.keywordRemap(a.name) + ");\n");
			w.write("\t\t" + ret + "__ctx->run" + CppScriptable.scriptType(returnT, false) + "(" + vtable + ");\n");
			w.write("\t}  else " + ret);
			w.write(className + "::" + name + "(" + names.join(",") + ");");
			if (returnType != "void") w.write("return null();");
			w.write("}\n");
		}
	}

	// The scriptable block: a `<class>__scriptable` dispatch subclass plus the CPPIA_CALL trampolines and
	// the __scriptableFunctions table, so a compiled host can run cppia overrides.
	function genScriptable(w:CppWriter):Void {
		if (!isScriptable()) return;
		if (TypeFunctions.hasMeta(":nativeGen", classDef.meta)) return;
		var isInterface = TypeFunctions.hasClassFlag(classDef, CInterface);
		// Functions dispatched by the subclass: all virtual functions minus toString (kept for
		// interfaces).
		var functions = [for (f in CppScriptable.allVirtualFunctions(classDef)) if (f.name != "toString" || isInterface) f];
		// The table + trampolines use only this class's own virtual functions.
		var newScriptFunctions = isInterface ? CppScriptable.allVirtualFunctions(classDef) : CppScriptable.ownVirtualFunctions(classDef);
		var scriptName = className + "__scriptable";
		if (isInterface) {
			w.write("class " + scriptName + " : public ::hx::Object {\n");
			w.write("public:\n");
		} else {
			w.write("class " + scriptName + " : public " + className + " {\n");
			w.write("   typedef " + scriptName + " __ME;\n");
			w.write("   typedef " + className + " super;\n");
			var hasFunkyToString = Lambda.exists(classDef.orderedStatics, function(f) return f.name == "toString")
				|| Lambda.exists(classDef.orderedFields, function(f) return f.name == "toString" && fieldArgCount(f) != 0);
			var superString = hasFunkyToString ? className + "::super" : className;
			w.write("   typedef " + superString + " __superString;\n");
			w.write("   HX_DEFINE_SCRIPTABLE(HX_ARR_LIST" + constructorArgNames().length + ")\n");
			w.write("\tHX_DEFINE_SCRIPTABLE_DYNAMIC;\n");
		}
		for (i in 0...functions.length) dumpScriptField(w, i, functions[i]);
		w.write("};\n\n");

		var sigs = new Map<String, String>();
		var staticFunctions = [for (f in staticsExceptMeta()) if (reflective(f) && !isDataMember(f)) f];
		var allScriptFunctions = [for (f in newScriptFunctions) f].concat(staticFunctions);
		if (allScriptFunctions.length > 0) {
			for (f in newScriptFunctions) sigs.set(f.name, generateScriptFunction(w, false, f, "__s_" + f.name, CppTypeText.keywordRemap(f.name)));
			for (f in classDef.orderedStatics) sigs.set(f.name, generateScriptFunction(w, true, f, "__s_" + f.name, CppTypeText.keywordRemap(f.name)));
			w.write("#ifndef HXCPP_CPPIA_SUPER_ARG\n#define HXCPP_CPPIA_SUPER_ARG(x)\n#endif\n");
			w.write("static ::hx::ScriptNamedFunction __scriptableFunctions[] = {\n");
			function dumpFunc(f:TClassField, isStaticFlag:String):Void {
				var s = sigs.exists(f.name) ? sigs.get(f.name) : "v";
				w.write("  ::hx::ScriptNamedFunction(\"" + f.name + "\",__s_" + f.name + ",\"" + s + "\", " + isStaticFlag + " ");
				var superCall = (isStaticFlag == "true" || isInterface) ? "0" : ("__s_" + f.name + "<true>");
				w.write("HXCPP_CPPIA_SUPER_ARG(" + superCall + ")");
				w.write(" ),\n");
			}
			for (f in newScriptFunctions) dumpFunc(f, "false");
			for (f in staticFunctions) dumpFunc(f, "true");
			w.write("  ::hx::ScriptNamedFunction(0,0,0 HXCPP_CPPIA_SUPER_ARG(0) ) };\n");
		} else {
			w.write("static ::hx::ScriptNamedFunction *__scriptableFunctions = 0;\n");
		}
		// An interface also emits a static vtable of member-function pointers into the __scriptable
		// dispatcher, one per virtual function.
		if (isInterface) {
			w.write("\n\n" + className + " " + className + "_scriptable = {\n");
			for (f in newScriptFunctions) switch (TypeFunctions.follow(f.type)) {
				case TFun(s):
					w.write("\t( " + ctxTypeString(s.ret) + " (::hx::Object::*)(" + ctxTfunArgList(s.args, true) + "))&" + scriptName + "::" + CppTypeText.keywordRemap(f.name) + ",\n");
				case _:
			}
			w.write("};\n");
		}
	}

	// A static var with a value initializer becomes `name = <value>;` (emitted inside a stack-frame block
	// via CppEmit).
	function genFieldInit(w:CppWriter, field:TClassField):Void {
		if (!TypeFunctions.isPhysicalField(field) || field.expr == null) return;
		switch (field.expr.expr) {
			case TFunction(_):
				// A dynamic method installs its default closure at boot: `name = new __default_name;`. A
				// plain static function is not a boot initializer.
				if (isDynamicHaxeMethod(field)) {
					var name = CppTypeText.cppMemberNameOf(field);
					w.write("\t" + name + " = new __default_" + name + ";\n\n");
				}
			case _:
				// Emit the initializer value prefixed by `<name> = ` (an injection setvar), so the static
				// is referenced bare (origin = 0, not ::Point_obj::origin).
				// __meta__/__rtti are not class statics but fields on the runtime Class object
				// (__mClass->__meta__ and __mClass->__rtti__), so they are assigned there at boot.
				var name = switch (field.name) {
					case "__meta__": "__mClass->__meta__";
					case "__rtti": "__mClass->__rtti__";
					case _: CppTypeText.cppMemberNameOf(field);
				};
				var dotName = joinPath(classDef.path, ".");
				// The boot frame position is the initializer expression's own position (expr.pos), so a
				// macro-expanded static var points at the macro body (Loader.hx), not the class that
				// declares the field.
				var frameLine = CppEmit.getErrorLine(field.expr.pos);
				// The boot init runs at the global debug level (like __init__), so a closure in a static
				// initializer still gets its debug>=2 stack registrations under HXCPP_DEBUGGER.
				var bootDbg = baseDebugLevel();
				new CppEmit(com, w, bootDbg, false, cppFileId).genExpressionTree([], TypeFunctions.tDynamic, field.expr,
					function(gc) hxStackPush(com, w, dotName, "boot", field.expr.pos.file, frameLine, gc, cppFileId, bootDbg), name + " = ", dotName, "boot");
		}
	}

	function genRegister(w:CppWriter):Void {
		var classNameText = joinPath(classDef.path, ".");
		// The interface __register: no _hx_vtable / mConstruct* / mGetStaticField / mStatics; mCanCast is
		// TIsInterface<(int)hash> and mMembers dupFunctions the member fields (empty if none).
		if (TypeFunctions.hasClassFlag(classDef, CInterface)) {
			w.write("::hx::Class " + className + "::__mClass;\n\n");
			w.write("void " + className + "::__register()\n{\n");
			w.write("\t::hx::Static(__mClass) = new ::hx::Class_obj();\n");
			w.write("\t__mClass->mName = " + CppTypeText.strq(smartStrings, classNameText) + ";\n");
			w.write("\t__mClass->mSuper = &super::__SGetClass();\n");
			if (hasMarkFunc()) w.write("\t__mClass->mMarkFunc = " + className + "_sMarkStatics;\n");
			var sMemberFields = reflectiveMembers().length > 0 ? className + "_sMemberFields" : "0 /* sMemberFields */";
			w.write("\t__mClass->mMembers = ::hx::Class_obj::dupFunctions(" + sMemberFields + ");\n");
			w.write("\t__mClass->mCanCast = ::hx::TIsInterface< (int)" + genHash(0, joinPath(classDef.path, "::")) + " >;\n");
			if (hasMarkFunc()) w.write("#ifdef HXCPP_VISIT_ALLOCS\n\t__mClass->mVisitFunc = " + className + "_sVisitStatics;\n#endif\n");
			w.write("\t::hx::_hx_RegisterClass(__mClass->mName, __mClass);\n");
			// A scriptable build registers the interface for cppia dispatch.
			if (isScriptable())
				w.write("  HX_SCRIPTABLE_REGISTER_INTERFACE(\"" + classNameText + "\"," + className + ");\n");
			w.write("}\n\n");
			return;
		}
		// __mClass is declared, then (a scriptable build) __script_construct, then the reflective
		// static-field table - in that order.
		w.write("::hx::Class " + className + "::__mClass;\n\n");
		if (isScriptable()) {
			if (classDef.constructor != null) {
				var sig = generateScriptFunction(w, false, classDef.constructor, "__script_construct_func", "__construct");
				w.write("::hx::ScriptFunction " + className + "::__script_construct(__script_construct_func,\"" + sig + "\");\n");
			} else {
				w.write("::hx::ScriptFunction " + className + "::__script_construct(0,0);\n");
			}
		}
		var reflectiveStatics = [for (f in staticsExceptMeta()) if (reflective(f) && (isMemberVar(f) || isMethodField(f))) f];
		var sStaticFields = if (reflectiveStatics.length > 0) {
			w.write("static ::String " + className + "_sStaticFields[] = {\n");
			for (f in reflectiveStatics) w.write("\t" + CppTypeText.strq(smartStrings, f.name) + ",\n");
			w.write("\t::String(null())\n};\n\n");
			className + "_sStaticFields";
		} else {
			"0 /* sStaticFields */";
		};
		w.write("void " + className + "::__register()\n{\n");
		// An abstract class registers without the vtable dummy or ctor hooks.
		if (!TypeFunctions.hasClassFlag(classDef, CAbstract)) {
			w.write("\t" + className + " _hx_dummy;\n");
			w.write("\t" + className + "::_hx_vtable = *(void **)&_hx_dummy;\n");
		}
		w.write("\t::hx::Static(__mClass) = new ::hx::Class_obj();\n");
		w.write("\t__mClass->mName = " + CppTypeText.strq(smartStrings, classNameText) + ";\n");
		w.write("\t__mClass->mSuper = &super::__SGetClass();\n");
		if (!TypeFunctions.hasClassFlag(classDef, CAbstract)) {
			w.write("\t__mClass->mConstructEmpty = &__CreateEmpty;\n");
			w.write("\t__mClass->mConstructArgs = &__Create;\n");
		}
		var sMemberFields = reflectiveMembers().length > 0 ? className + "_sMemberFields" : "0 /* sMemberFields */";
		w.write("\t__mClass->mGetStaticField = &" + (hasGetStaticField() ? className + "::__GetStatic;\n" : "::hx::Class_obj::GetNoStaticField;\n"));
		w.write("\t__mClass->mSetStaticField = &" + (hasSetStaticField() ? className + "::__SetStatic;\n" : "::hx::Class_obj::SetNoStaticField;\n"));
		if (hasMarkFunc()) w.write("\t__mClass->mMarkFunc = " + className + "_sMarkStatics;\n");
		w.write("\t__mClass->mStatics = ::hx::Class_obj::dupFunctions(" + sStaticFields + ");\n");
		w.write("\t__mClass->mMembers = ::hx::Class_obj::dupFunctions(" + sMemberFields + ");\n");
		w.write("\t__mClass->mCanCast = ::hx::TCanCast< " + className + " >;\n");
		if (hasMarkFunc()) w.write("#ifdef HXCPP_VISIT_ALLOCS\n\t__mClass->mVisitFunc = " + className + "_sVisitStatics;\n#endif\n");
		w.write("#ifdef HXCPP_SCRIPTABLE\n\t__mClass->mMemberStorageInfo = " + className + "_sMemberStorageInfo;\n#endif\n");
		w.write("#ifdef HXCPP_SCRIPTABLE\n\t__mClass->mStaticStorageInfo = " + className + "_sStaticStorageInfo;\n#endif\n");
		w.write("\t::hx::_hx_RegisterClass(__mClass->mName, __mClass);\n");
		// A scriptable build registers the class so the cppia loader can bind script overrides.
		if (isScriptable())
			w.write("  HX_SCRIPTABLE_REGISTER_CLASS(\"" + classNameText + "\"," + className + ");\n");
		// Each implemented native interface registers its vtable offset so a native caller can find the
		// haxe methods through the native interface pointer.
		for (intf in nativeImplementedInterfaces())
			w.write("\tHX_REGISTER_VTABLE_OFFSET( " + className + "," + CppTypeText.joinClassPathRemap(intf.path, "::") + ");\n");
		w.write("}\n\n");
	}
}
