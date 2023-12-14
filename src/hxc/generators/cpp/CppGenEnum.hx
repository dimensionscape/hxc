package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals.Path;
import hxc.context.Context;

// hxc.generators.cpp.CppGenEnum: one .cpp + .h per enum. The enum extends ::hx::EnumBase_obj; each
// constructor is a static factory (CreateEnum for a parametrized one, a const field for a nullary one) plus
// the reflection glue (__GetStatic/__FindIndex/__FindArgCount/__Field/__register/__boot). The
// per-constructor sections come out in alphabetical name order; only sStaticFields is ordered by
// constructor index.
class CppGenEnum {
	final com:Context;
	final enumDef:TEnum;
	final classPath:Path;
	final justClassName:String;
	final className:String;              
	final remapClassName:String;                
	final smartStrings:Bool;

	public function new(com:Context, enumDef:TEnum) {
		this.com = com;
		this.enumDef = enumDef;
		this.classPath = enumDef.path;
		this.justClassName = classPath.name;
		this.className = justClassName + "_obj";
		this.remapClassName = "::" + CppTypeText.joinClassPathRemap(classPath, "::");
		this.smartStrings = com.defines.rawDefined("hxcpp_smart_strings");
	}

	inline function strq(s:String):String return CppTypeText.strq(smartStrings, s);

	// The constructors in alphabetical name order.
	function constructorsByName():Array<TEnumField> {
		var names = [for (k in enumDef.constrs.keys()) k];
		names.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
		return [for (n in names) enumDef.constrs.get(n)];
	}

	static function argCount(c:TEnumField):Int {
		return switch (c.type) { case TFun(sig): sig.args.length; case _: 0; };
	}

	// The arg list with names: an optional scalar arg is wrapped in ::hx::Null< >.
	static function tfunArgList(args:Array<{name:String, opt:Bool, t:T}>):String {
		function oType(o:Bool, argType:T):String {
			var typeStr = CppTypeText.tcppToString(CppTypeOf.cppTypeOf(argType));
			return (o && CppTypeOf.cppTypeOf(argType).match(TCppScalar(_)) && typeStr != "Dynamic")
				? "::hx::Null< " + typeStr + " > " : typeStr;
		}
		return [for (a in args) oType(a.opt, a.t) + " " + CppTypeText.keywordRemap(a.name)].join(",");
	}

	function genOpenNamespace(w:CppWriter):Void {
		for (ns in classPath.pack) w.write("namespace " + CppTypeText.keywordRemap(ns) + "{\n");
	}

	function genCloseNamespace(w:CppWriter):Void {
		for (ns in classPath.pack) w.write("} // end namespace " + ns + "\n");
	}

	function addInclude(w:CppWriter, path:Path):Void {
		var guard = CppGenClass.joinPath(path, "_");
		var incPath = CppGenClass.joinPath(path, "/");
		w.writeHUnique("#ifndef INCLUDED_" + guard + "\n#include <" + incPath + ".h>\n#endif\n");
	}

	public function genCpp():String {
		var w = new CppWriter();
		w.writeH("#include <hxcpp.h>\n\n");
		var refs = CppReferenced.findReferencedTypesFlags(com, TEnumDecl(enumDef), "*", CppGenClass.superDeps, CppGenClass.constructorDeps, false, false);
		for (p in refs.deps) addInclude(w, p);
		genOpenNamespace(w);
		w.write("\n");

		// Constructor factories
		for (c in constructorsByName()) {
			var name = CppTypeText.keywordRemap(c.name);
			switch (c.type) {
				case TFun(sig):
					w.write(remapClassName + " " + className + "::" + name + "(" + tfunArgList(sig.args) + ")\n");
					w.write("{\n\treturn ::hx::CreateEnum< " + className + " >(" + strq(name) + "," + c.index + "," + sig.args.length + ")");
					for (i in 0...sig.args.length) w.write("->_hx_init(" + i + "," + CppTypeText.keywordRemap(sig.args[i].name) + ")");
					w.write(";\n}\n\n");
				case _:
					w.write(remapClassName + " " + className + "::" + name + ";\n\n");
			}
		}

		w.write("bool " + className + "::__GetStatic(const ::String &inName, ::Dynamic &outValue, ::hx::PropertyAccess inCallProp)\n{\n");
		for (c in constructorsByName()) {
			var dyn = argCount(c) > 0 ? "_dyn()" : "";
			w.write("\tif (inName==" + strq(c.name) + ") { outValue = " + className + "::" + CppTypeText.keywordRemap(c.name) + dyn + "; return true; }\n");
		}
		w.write("\treturn super::__GetStatic(inName, outValue, inCallProp);\n}\n\n");

		w.write("HX_DEFINE_CREATE_ENUM(" + className + ")\n\n");

		w.write("int " + className + "::__FindIndex(::String inName)\n{\n");
		for (c in constructorsByName()) w.write("\tif (inName==" + strq(c.name) + ") return " + c.index + ";\n");
		w.write("\treturn super::__FindIndex(inName);\n");
		w.write("}\n\n");

		// Dynamic constructors
		for (c in constructorsByName()) {
			var count = argCount(c);
			if (count > 0)
				w.write("STATIC_HX_DEFINE_DYNAMIC_FUNC" + count + "(" + className + "," + CppTypeText.keywordRemap(c.name) + ",return)\n\n");
		}

		w.write("int " + className + "::__FindArgCount(::String inName)\n{\n");
		for (c in constructorsByName()) w.write("\tif (inName==" + strq(c.name) + ") return " + argCount(c) + ";\n");
		w.write("\treturn super::__FindArgCount(inName);\n");
		w.write("}\n\n");

		w.write("::hx::Val " + className + "::__Field(const ::String &inName,::hx::PropertyAccess inCallProp)\n{\n");
		for (c in constructorsByName()) {
			w.write("\tif (inName==" + strq(c.name) + ") return " + CppTypeText.keywordRemap(c.name));
			if (argCount(c) > 0) w.write("_dyn()");
			w.write(";\n");
		}
		w.write("\treturn super::__Field(inName,inCallProp);\n}\n\n");

		// sStaticFields, ordered by index
		w.write("static ::String " + className + "_sStaticFields[] = {\n");
		var byIndex = constructorsByName();
		byIndex.sort(function(a, b) return a.index - b.index);
		for (c in byIndex) w.write("\t" + strq(c.name) + ",\n");
		w.write("\t::String(null())\n};\n\n");

		w.write("::hx::Class " + className + "::__mClass;\n\n");
		w.write("Dynamic __Create_" + className + "() { return new " + className + "; }\n\n");

		w.write("void " + className + "::__register()\n{\n");
		var textName = strq(CppTypeOf.joinClassPath(classPath, "."));
		w.write("\n::hx::Static(__mClass) = ::hx::_hx_RegisterClass(" + textName + ", ::hx::TCanCast< " + className + " >," + className + "_sStaticFields,0,\n");
		w.write("\t&__Create_" + className + ", &__Create,\n");
		w.write("\t&super::__SGetClass(), &Create" + className + ", 0\n");
		w.write("#ifdef HXCPP_VISIT_ALLOCS\n    , 0\n#endif\n");
		w.write("#ifdef HXCPP_SCRIPTABLE\n    , 0\n#endif\n");
		w.write(");\n");
		w.write("\t__mClass->mGetStaticField = &" + className + "::__GetStatic;\n");
		w.write("}\n\n");

		// __boot: the runtime metadata (__mClass->__meta__) first, then each nullary constructor's const
		// enum value.
		w.write("void " + className + "::__boot()\n{\n");
		var meta = hxc.core.TexprTools.buildMetadata(com.basic, TEnumDecl(enumDef));
		if (meta != null) {
			var cppFileId = {v: -1};
			var dotName = CppGenClass.joinPath(classPath, ".");
			var frameLine = hxc.generators.cpp.CppEmit.getErrorLine(meta.pos);
			var frameFile = meta.pos.file;
			var emit = new hxc.generators.cpp.CppEmit(com, w, 1, false, cppFileId);
			emit.genExpressionTree([], TypeFunctions.tDynamic, meta,
				function(gc) CppGenClass.hxStackPush(com, w, dotName, "boot", frameFile, frameLine, gc, cppFileId),
				"__mClass->__meta__ = ", dotName, "boot");
		}
		for (c in constructorsByName()) switch (c.type) {
			case TFun(_):
			case _:
				w.write(CppTypeText.keywordRemap(c.name) + " = ::hx::CreateConstEnum< " + className + " >(" + strq(c.name) + "," + c.index + ");\n");
		}
		w.write("}\n\n");

		w.write("\n");
		genCloseNamespace(w);
		return w.getHeader() + w.getBody();
	}

	public function genHeader():String {
		var w = new CppWriter();
		var defString = CppGenClass.joinPath(classPath, "_");
		w.writeH("#ifndef INCLUDED_" + defString + "\n");
		w.writeH("#define INCLUDED_" + defString + "\n\n");
		w.writeH("#ifndef HXCPP_H\n#include <hxcpp.h>\n#endif\n\n");

		var refs = CppReferenced.findReferencedTypesFlags(com, TEnumDecl(enumDef), "*", CppGenClass.superDeps, CppGenClass.constructorDeps, false, false);
		for (i in 0...refs.deps.length) CppReferenced.genForwardDecl(w, refs.deps[i], refs.flags[i]);

		genOpenNamespace(w);
		w.write("\n\n");
		var superT = "::hx::EnumBase_obj";
		w.write("class " + className + " : public " + superT + "\n");
		w.write("{\n\ttypedef " + superT + " super;\n");
		w.write("\t\ttypedef " + className + " OBJ_;\n");
		w.write("\n\tpublic:\n");
		w.write("\t\t" + className + "() {};\n");
		w.write("\t\tHX_DO_ENUM_RTTI;\n");
		w.write("\t\tstatic void __boot();\n");
		w.write("\t\tstatic void __register();\n");
		w.write("\t\tstatic bool __GetStatic(const ::String &inName, Dynamic &outValue, ::hx::PropertyAccess inCallProp);\n");
		w.write("\t\t::String GetEnumName( ) const { return " + strq(CppTypeOf.joinClassPath(classPath, ".")) + "; }\n");
		w.write("\t\t::String __ToString() const { return " + strq(justClassName + ".") + " + _hx_tag; }\n\n");

		for (c in constructorsByName()) {
			var name = CppTypeText.keywordRemap(c.name);
			w.write("\t\tstatic " + remapClassName + " " + name);
			switch (c.type) {
				case TFun(sig):
					w.write("(" + tfunArgList(sig.args) + ");\n");
					w.write("\t\tstatic ::Dynamic " + name + "_dyn();\n");
				case _:
					w.write(";\n");
					w.write("\t\tstatic inline " + remapClassName + " " + name + "_dyn() { return " + name + "; }\n");
			}
		}

		w.write("};\n\n");
		genCloseNamespace(w);
		w.write("\n#endif /* INCLUDED_" + defString + " */ \n");
		return w.getHeader() + w.getBody();
	}
}
