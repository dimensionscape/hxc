package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.Globals.Path;
import hxc.ast.Ast;
import hxc.generators.cpp.CppType;

// hxc.generators.cpp.CppTypeOf: map a Haxe type to its C++ type (the CppType lattice), (cpp_type_of +
// cpp_type_from_path + cpp_type_of_null + cpp_instance_type), plus the small gencpp predicates it leans on.
// No output; this is the substrate the retype pass rides on.
class CppTypeOf {

	public static function joinClassPath(path:Path, sep:String):String {
		var result = path.pack.length == 0 ? path.name : path.pack.join(sep) + sep + path.name;
		var idx = result.indexOf("+");
		return if (idx >= 0) result.substr(0, idx) + result.substr(idx + 1) else result;
	}

	// Implemented by the hxcpp runtime, no .cpp generated.
	public static function isInternalClass(path:Path):Bool {
		return switch [path.pack, path.name] {
			case [[], "Int"] | [[], "Void"] | [[], "String"] | [[], "Null"] | [[], "Float"]
				| [[], "Array"] | [[], "Class"] | [[], "Enum"] | [[], "Bool"]
				| [[], "Dynamic"] | [[], "ArrayAccess"] | [[], "Math"] | [[], "Single"]: true;
			case [["cpp"], "FastIterator"] | [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"]
				| [["cpp"], "RawPointer"] | [["cpp"], "RawConstPointer"] | [["cpp"], "Function"]
				| [["cpp"], "VirtualArray"]
				| [["cpp"], "Int8"] | [["cpp"], "UInt8"] | [["cpp"], "Char"]
				| [["cpp"], "Int16"] | [["cpp"], "UInt16"]
				| [["cpp"], "Int32"] | [["cpp"], "UInt32"]
				| [["cpp"], "Int64"] | [["cpp"], "UInt64"]
				| [["cpp"], "Float32"] | [["cpp"], "Float64"]: true;
			case _: false;
		}
	}

	// Ast.getMetaString already extracts the first string param.
	static inline function getMetaString(meta:Metadata, key:String):String {
		var s = Ast.getMetaString(meta, key);
		return s == null ? "" : s;
	}

	public static inline function isScalarAbstract(a:TAbstract):Bool {
		return TypeFunctions.hasMeta(":scalar", a.meta) && TypeFunctions.hasMeta(":coreType", a.meta);
	}

	public static function isCppScalar(cppType:CppType):Bool {
		return switch (cppType) { case TCppScalar(_): true; case _: false; }
	}

	public static inline function isObjcClass(klass:TClass):Bool {
		return TypeFunctions.hasClassFlag(klass, CExtern) && TypeFunctions.hasMeta(":objc", klass.meta);
	}

	public static function isNativeGenClass(klass:TClass):Bool {
		return TypeFunctions.hasMeta(":nativeGen", klass.meta) || switch (klass.kind) {
			case KAbstractImpl(a): TypeFunctions.hasMeta(":nativeGen", a.meta);
			case _: false;
		};
	}

	public static function isExternClass(c:TClass):Bool {
		return TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasMeta(":extern", c.meta) || switch (c.kind) {
			case KAbstractImpl(a): TypeFunctions.hasMeta(":extern", a.meta);
			case _: false;
		};
	}

	public static function isNativeClass(c:TClass):Bool {
		return (isExternClass(c) || isNativeGenClass(c)) && !isInternalClass(c.path);
	}

	public static inline function isExternEnum(e:TEnum):Bool {
		return e.isExtern || TypeFunctions.hasMeta(":extern", e.meta);
	}

	public static function cppIsNativeArrayAccess(t:CppType):Bool {
		return switch (t) {
			case TCppStruct(s) | TCppReference(s): cppIsNativeArrayAccess(s);
			case TCppInst(klass, _) if (klass.arrayAccess != null && isExternClass(klass) && TypeFunctions.hasMeta(":nativeArrayAccess", klass.meta)): true;
			case _: false;
		}
	}

	// The path of a module type
	public static function tPath(mt:ModuleType):Path {
		return switch (mt) {
			case TClassDecl(c): c.path;
			case TEnumDecl(e): e.path;
			case TTypeDecl(d): d.path;
			case TAbstractDecl(a): a.path;
		}
	}

	public static function isNativeGenModule(mt:ModuleType):Bool {
		return switch (mt) { case TClassDecl(c): isNativeGenClass(c); case _: false; };
	}

	public static function typeHasMetaKey(haxeType:T, key:String):Bool {
		return switch (TypeFunctions.followWithAbstracts(haxeType)) {
			case TInst(klass, _): TypeFunctions.hasMeta(key, klass.meta);
			case TType(td, _): TypeFunctions.hasMeta(key, td.meta);
			case TEnum(en, _): TypeFunctions.hasMeta(key, en.meta);
			case _: false;
		}
	}

	public static function cppReturnType(haxeType:T):CppType {
		return switch (haxeType) {
			case TFun(sig): cppTypeOf(sig.ret);
			case _: TCppDynamic;
		}
	}

	public static inline function cppMemberReturnType(member:TClassField):CppType {
		return cppReturnType(member.type);
	}

	public static function isVarField(field:TClassField):Bool {
		return switch (field.kind) {
			case Var(_): true;
			case Method(MethDynamic): true;
			case _: false;
		}
	}

	public static inline function cppTfunArgTypeOf(opt:Bool, t:T):CppType {
		return opt ? cppTypeOfNull([], t) : cppTypeOf(t);
	}

	public static inline function cppFunctionArgsRet(functionType:T):{args:Array<CppType>, ret:CppType} {
		return cppFunctionTypeOfArgsRet([], functionType);
	}


	public static inline function cppTypeOf(haxeType:T):CppType {
		return cppTypeOfStack([], haxeType);
	}

	public static inline function cppTypeFromPathOf(path:Path, params:Array<T>, def:Void->CppType):CppType {
		return cppTypeFromPath([], path, params, def);
	}

	static function cppTypeOfStack(stack:Array<T>, haxeType:T):CppType {
		for (s in stack) if (TypeUnification.fastEq(haxeType, s)) return TCppDynamic;
		var stack2 = [haxeType].concat(stack);
		return switch (haxeType) {
			case TMono(r): switch (r.type) { case null: TCppDynamic; case t: cppTypeOfStack(stack2, t); };
			case TEnum(en, _): TCppEnum(en);
			case TInst(klass, _) if (isTypeParam(klass) && klass.path.pack.length == 0 && klass.path.name == "Array"): TCppObject;
			case TInst(klass, _) if (isTypeParam(klass)): TCppDynamic;
			case TInst(klass, params): cppInstanceType(stack2, klass, params);
			case TAbstract(abs, pl) if (!TypeFunctions.hasMeta(":coreType", abs.meta)):
				// The underlying type is taken one level deep; for a
				// @:multiType abstract (Map) it resolves the concrete specialization (IntMap/StringMap/...)
				// before falling back to the plain underlying (IMap).
				cppTypeFromPath(stack2, abs.path, pl, function() return cppTypeOfStack(stack2, cppGetUnderlyingType(abs, pl)));
			case TAbstract(a, params):
				cppTypeFromPath(stack2, a.path, params, function() {
					return if (isScalarAbstract(a)) {
						var native = getMetaString(a.meta, ":native");
						TCppScalar(native == "" ? joinClassPath(a.path, "::") : native);
					} else TCppDynamic;
				});
			case TType(typeDef, params):
				cppTypeFromPath(stack2, typeDef.path, params, function() return cppTypeOfStack(stack2, TypeFunctions.applyTypedef(typeDef, params)));
			case TFun(_): TCppObject;
			case TAnon(_): TCppObject;
			case TDynamic(_): TCppDynamic;
			case TLazy(f): cppTypeOfStack(stack2, TypeFunctions.lazyType(f));
		}
	}

	static inline function isTypeParam(klass:TClass):Bool {
		return klass.kind.match(KTypeParameter(_));
	}

	static function cppTypeFromPath(stack:Array<T>, path:Path, params:Array<T>, def:Void->CppType):CppType {
		return switch [path.pack, path.name] {
			case [[], "Void"] | [[], "void"]: TCppVoid;
			case [[], "Bool"]: TCppScalar("bool");
			case [[], "Float"]: TCppScalar("Float");
			case [[], "Int"]: TCppScalar("int");
			case [[], "EnumValue"]: TCppObject;
			case [[], "Class"] | [[], "Enum"]: TCppClass;
			case [[], "Single"]: TCppScalar("float");
			case [["cpp"], "Char"]: TCppScalar("char");
			case [["cpp"], "Object"]: TCppObjectPtr;
			case [["cpp"], "Float32"]: TCppScalar("float");
			case [["cpp"], "Float64"]: TCppScalar("double");
			case [["cpp"], "Int8"]: TCppScalar("signed char");
			case [["cpp"], "Int16"]: TCppScalar("short");
			case [["cpp"], "Int32"]: TCppScalar("int");
			case [["cpp"], "Int64"]: TCppScalar("::cpp::Int64");
			case [["cpp"], "UInt8"]: TCppScalar("unsigned char");
			case [["cpp"], "UInt16"]: TCppScalar("unsigned short");
			case [["cpp"], "UInt32"]: TCppScalar("unsigned int");
			case [["cpp"], "UInt64"]: TCppScalar("::cpp::UInt64");
			case [["cpp"], "VarArg"]: TCppVarArg;
			case [["cpp"], "AutoCast"]: TCppAutoCast;
			case [[], "String"] if (params.length == 0): TCppString;
			case [["cpp"], "FastIterator"] if (params.length == 1): TCppFastIterator(cppTypeOfStack(stack, params[0]));
			case [["cpp"], "Pointer"] if (params.length == 1): TCppPointer("Pointer", cppTypeOfStack(stack, params[0]));
			case [["cpp"], "ConstPointer"] if (params.length == 1): TCppPointer("ConstPointer", cppTypeOfStack(stack, params[0]));
			case [["cpp"], "RawPointer"] if (params.length == 1): TCppRawPointer("", cppTypeOfStack(stack, params[0]));
			case [["cpp"], "RawConstPointer"] if (params.length == 1): TCppRawPointer("const ", cppTypeOfStack(stack, params[0]));
			case [["cpp"], "Function"] if (params.length == 2): cppFunctionTypeOf(stack, params[0], params[1]);
			case [["cpp"], "Callable"] | [["cpp"], "CallableData"] if (params.length == 1): cppFunctionTypeOfString(stack, params[0], "");
			case [["cpp", "objc"], "ObjcBlock"] if (params.length == 1):
				var ar = cppFunctionTypeOfArgsRet(stack, params[0]);
				TCppObjCBlock(ar.args, ar.ret);
			case [["cpp"], "Rest"] if (params.length == 1): TCppRest(cppTypeOfStack(stack, params[0]));
			case [["cpp", "objc"], "Protocol"] if (params.length == 1):
				switch (TypeFunctions.followWithAbstracts(params[0])) {
					case TInst(klass, []) if (TypeFunctions.hasClassFlag(klass, CInterface)): TCppProtocol(klass);
					case _: throw "cpp.objc.Protocol must refer to an interface";
				};
			case [["cpp"], "Reference"] if (params.length == 1): TCppReference(cppTypeOfStack(stack, params[0]));
			case [["cpp"], "Struct"] if (params.length == 1): TCppStruct(cppTypeOfStack(stack, params[0]));
			case [["cpp"], "Star"] if (params.length == 1): TCppStar(cppTypeOfPointer(stack, params[0]), false);
			case [["cpp"], "ConstStar"] if (params.length == 1): TCppStar(cppTypeOfPointer(stack, params[0]), true);
			case [[], "Array"] if (params.length == 1): arrayType(cppTypeOfStack(stack, params[0]));
			case [[], "Null"] if (params.length == 1): cppTypeOfNull(stack, params[0]);
			case _: def();
		}
	}

	// A @:multiType abstract resolves to its concrete specialization
	// when the definitive key type is known; otherwise (mono key, or
	// no @:multiType) it falls back to the plain underlying type.
	public static function cppGetUnderlyingType(abs:TAbstract, pl:Array<T>):T {
		if (TypeFunctions.hasMeta(":multiType", abs.meta)) {
			try return hxc.typing.Typer.resolveMultiTypeConcrete(abs, pl, hxc.ast.Position.nullPos) catch (_:Dynamic) {}
		}
		// Return the IMMEDIATE underlying (thisType with params
		// applied), not the fully-recursed one. So a @:forward abstract over Map resolves to Map, and
		// cppTypeOf then re-processes Map and hits its multiType specialization; fully recursing here would
		// walk straight past Map to IMap and lose the concrete map type.
		return TypeFunctions.applyParams(abs.params, pl, abs.thisType);
	}

	static function arrayType(arrayOf:CppType):CppType {
		return switch (arrayOf) {
			case TCppVoid | TCppDynamic: TCppDynamicArray;
			case TCppObject | TCppObjectPtr | TCppReference(_) | TCppStruct(_) | TCppStar(_, _)
				| TCppEnum(_) | TCppInst(_, _) | TCppInterface(_) | TCppProtocol(_) | TCppClass
				| TCppDynamicArray | TCppObjectArray(_) | TCppScalarArray(_): TCppObjectArray(arrayOf);
			case _: TCppScalarArray(arrayOf);
		}
	}

	// The C++ type a value takes when stored in a variant.
	public static function cppVariantTypeOf(t:CppType):CppType {
		return switch (t) {
			case TCppDynamic | TCppUnchanged | TCppObject | TCppObjectPtr | TCppReference(_) | TCppStruct(_)
				| TCppStar(_, _) | TCppVoid | TCppFastIterator(_) | TCppDynamicArray | TCppObjectArray(_)
				| TCppScalarArray(_) | TCppWrapped(_) | TCppObjC(_) | TCppObjCBlock(_, _) | TCppRest(_)
				| TCppInst(_, _) | TCppInterface(_) | TCppProtocol(_) | TCppCode(_) | TCppClass | TCppGlobal
				| TCppNull | TCppEnum(_): TCppDynamic;
			case TCppString: TCppString;
			case TCppFunction(_, _, _) | TCppNativePointer(_) | TCppPointer(_, _) | TCppRawPointer(_, _)
				| TCppAutoCast | TCppVarArg | TCppVoidStar: TCppVoidStar;
			case TCppScalar("Int") | TCppScalar("bool") | TCppScalar("Float"): t;
			case TCppScalar("::cpp::Int64"): TCppScalar("Int64");
			case TCppScalar("double") | TCppScalar("float"): TCppScalar("Float");
			case TCppScalar(_): TCppScalar("int");
			case TCppVariant: TCppVariant;
		};
	}

	// Like cppVariantTypeOf but preserves array/class/enum/inst.
	public static function cppCastVariantTypeOf(t:CppType):CppType {
		return switch (t) {
			case TCppObjectArray(_) | TCppScalarArray(_) | TCppDynamicArray | TCppClass | TCppEnum(_) | TCppInst(_, _): t;
			case _: cppVariantTypeOf(t);
		};
	}

	// The type of an enum constructor's nth argument.
	public static function getNthType(field:TEnumField, index:Int):T {
		return switch (TypeFunctions.follow(field.type)) {
			case TFun(sig) if (index < sig.args.length): sig.args[index].t;
			case _: throw new hxc.core.NotFound();
		};
	}

	// The _hx_get<suffix> accessor suffix for an enum parameter's type.
	public static function enumGetterType(t:CppType):String {
		return switch (cppVariantTypeOf(t)) {
			case TCppString: "String";
			case TCppScalar("int"): "Int";
			case TCppScalar("bool"): "Bool";
			case TCppScalar(x): x;
			case _: "Object";
		};
	}

	public static function cppIsDynamicType(t:CppType):Bool {
		return switch (t) {
			case TCppDynamic | TCppObject | TCppVariant | TCppWrapped(_) | TCppGlobal | TCppNull | TCppInterface(_): true;
			case _: false;
		};
	}

	public static function cppTypeOfNull(stack:Array<T>, p:T):CppType {
		var baseType = cppTypeOfStack(stack, p);
		return if (typeHasMetaKey(p, ":notNull") || isCppScalar(baseType)) TCppObject else baseType;
	}

	static function cppTypeOfPointer(stack:Array<T>, p:T):CppType {
		return switch (p) {
			case TAbstract(a, [t]) if (a.path.pack.length == 0 && a.path.name == "Null"): cppTypeOfStack(stack, t);
			case x: cppTypeOfStack(stack, x);
		}
	}

	// The abi comes from the second type param's @:abi meta.
	static function cppFunctionTypeOf(stack:Array<T>, functionType:T, abi:T):CppType {
		var abiString = switch (TypeFunctions.followWithAbstracts(abi)) {
			case TInst(klass1, _): getMetaString(klass1.meta, ":abi");
			case _: throw "cpp.Function abi must be a class";
		};
		return cppFunctionTypeOfString(stack, functionType, abiString);
	}

	static function cppFunctionTypeOfString(stack:Array<T>, functionType:T, abiString:String):CppType {
		var ar = cppFunctionTypeOfArgsRet(stack, functionType);
		return TCppFunction(ar.args, ar.ret, abiString);
	}

	static function cppFunctionTypeOfArgsRet(stack:Array<T>, functionType:T):{args:Array<CppType>, ret:CppType} {
		return switch (TypeFunctions.followWithAbstracts(functionType)) {
			case TFun(sig):
				// Optional args are Dynamic when they could not normally be null
				var args = sig.args.map(function(a) return a.opt ? cppTypeOfNull(stack, a.t) : cppTypeOfStack(stack, a.t));
				{args: args, ret: cppTypeOfStack(stack, sig.ret)};
			case _: {args: [TCppVoid], ret: TCppVoid};
		}
	}

	public static inline function cppInstanceTypeOf(klass:TClass, params:Array<T>):CppType {
		return cppInstanceType([], klass, params);
	}

	public static function cppIsStructAccess(t:CppType):Bool {
		return switch (t) {
			case TCppFunction(_, _, _): true;
			case TCppStruct(_): false;
			case TCppInst(c, _): TypeFunctions.hasMeta(":structAccess", c.meta);
			case TCppReference(r): cppIsStructAccess(r);
			case _: false;
		}
	}

	public static inline function isCppObjcType(t:CppType):Bool {
		return switch (t) { case TCppObjC(_): true; case _: false; };
	}

	static function cppInstanceType(stack:Array<T>, klass:TClass, params:Array<T>):CppType {
		return cppTypeFromPath(stack, klass.path, params, function() {
			return if (isObjcClass(klass)) TCppObjC(klass);
			else if (TypeFunctions.hasClassFlag(klass, CInterface) && isNativeGenClass(klass)) TCppNativePointer(klass);
			else if (TypeFunctions.hasClassFlag(klass, CInterface)) TCppInterface(klass);
			else TCppInst(klass, params.map(function(p) return cppTypeOfStack(stack, p)));
		});
	}
}
