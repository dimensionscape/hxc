package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Globals.Path;
import hxc.generators.cpp.CppType;
import hxc.generators.cpp.CppExpr;
import hxc.generators.cpp.CppiaWriter.CppiaOp;

// hxc.generators.cpp.CppiaGen: the cppia bytecode target. The type
// naming helpers, the per-class/per-enum script emitters and the driver; the
// opcode stream itself is written by CppiaWriter.
class CppiaGen {
	public static function cppEnumPathOf(en:TEnum):String {
		var globalNamespace = Ast.getMetaString(en.meta, ":native") != "" ? "" : "::";
		return globalNamespace + CppTypeText.joinClassPathRemap(en.path, "::");
	}

	public static function removeParens(e:TExpr):TExpr {
		return switch (e.expr) {
			case TParenthesis(e1): removeParens(e1);
			case TMeta(_, e1): removeParens(e1);
			case _: e;
		}
	}

	public static function removeParensCast(e:TExpr):TExpr {
		return switch (e.expr) {
			case TParenthesis(e1): removeParensCast(e1);
			case TMeta(_, e1): removeParensCast(e1);
			case TCast(e1, null): removeParensCast(e1);
			case _: e;
		}
	}

	public static function isInterfaceType(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(klass, _): TypeFunctions.hasClassFlag(klass, CInterface);
			case _: false;
		}
	}

	public static function isMatchingInterfaceType(t0:T, t1:T):Bool {
		return switch [TypeFunctions.follow(t0), TypeFunctions.follow(t1)] {
			case [TInst(k0, _), TInst(k1, _)]: k0 == k1;
			case _: false;
		}
	}

	public static function isArrayOrDynArray(haxeType:T):Bool {
		return switch (TypeFunctions.follow(haxeType)) {
			case TInst(klass, _): klass.path.pack.length == 0 && klass.path.name == "Array";
			case TType(td, _): td.path.pack.length == 0 && td.path.name == "Array";
			case _: false;
		}
	}

	public static function isThis(e:TExpr):Bool {
		return removeParens(e).expr.match(TConst(TThis));
	}

	public static function isSuper(e:TExpr):Bool {
		return removeParens(e).expr.match(TConst(TSuper));
	}

	public static function isRealFunction(field:TClassField):Bool {
		return switch (field.kind) {
			case Method(MethNormal) | Method(MethInline): true;
			case _: false;
		}
	}

	public static function isArray(haxeType:T):Bool {
		return switch (TypeFunctions.follow(haxeType)) {
			case TInst(klass, params) if (klass.path.pack.length == 0 && klass.path.name == "Array"):
				!isDynamicArrayParam(params[0]);
			case TType(td, params) if (td.path.pack.length == 0 && td.path.name == "Array"):
				!isDynamicArrayParam(params[0]);
			case _: false;
		}
	}

	static function isDynamicArrayParam(haxeType:T):Bool {
		if (typeString(TypeFunctions.follow(haxeType)) == "Dynamic") return true;
		return switch (TypeFunctions.follow(haxeType)) {
			case TInst(klass, _):
				switch [klass.path.pack, klass.path.name] {
					case [[], "Array"] | [[], "Class"] | [["cpp"], "FastIterator"] | [["cpp"], "RawPointer"]
						| [["cpp"], "ConstRawPointer"] | [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"]
						| [["cpp"], "Function"]: false;
					case _: klass.kind.match(KTypeParameter(_));
				}
			case _: false;
		}
	}

	public static function isPointer(haxeType:T, includeRaw:Bool):Bool {
		function pathIs(pack:Array<String>, name:String):Bool {
			return switch [pack, name] {
				case [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"] | [["cpp"], "Function"]: true;
				case [["cpp"], "RawPointer"] | [["cpp"], "RawConstPointer"]: includeRaw;
				case _: false;
			}
		}
		return switch (TypeFunctions.follow(haxeType)) {
			case TInst(klass, _): pathIs(klass.path.pack, klass.path.name);
			case TType(td, _): pathIs(td.path.pack, td.path.name);
			case TAbstract(abs, _): pathIs(abs.path.pack, abs.path.name);
			case _: false;
		}
	}

	static function isNativePointer(e:TExpr):Bool {
		var t = typeString(e.type);
		return t.length > 1 && t.charAt(t.length - 1) == "*";
	}

	static function isVirtualArray(e:TExpr):Bool {
		return typeString(e.type) == "cpp::VirtualArray";
	}

	static function isExternClassInstance(e:TExpr):Bool {
		return switch (TypeFunctions.follow(e.type)) {
			case TInst(klass, _): TypeFunctions.hasClassFlag(klass, CExtern);
			case _: false;
		}
	}

	public static function replaceFloatSeparators(s:String):String {
		return StringTools.replace(s, "_", "");
	}

	public static function isMacro(meta:Metadata):Bool {
		return TypeFunctions.hasMeta(":macro", meta);
	}

	// typeStringSuff with remap=true
	public static function typeString(haxeType:T):String {
		return typeStringSuff("", haxeType, true);
	}

	// The objc and cpp.Function signature corners raise; every
	// path the cppia writer reaches stays clear of them.
	public static function typeStringSuff(suffix:String, haxeType:T, remap:Bool):String {
		function joinPath(p:Path):String {
			return remap ? CppTypeText.joinClassPathRemap(p, "::") : CppTypeOf.joinClassPath(p, "::");
		}
		return switch (haxeType) {
			case TMono(r): r.type == null ? "Dynamic" + suffix : typeStringSuff(suffix, r.type, remap);
			case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Void"): "Void";
			case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Bool"): "bool";
			case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Float"): "Float";
			case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Int"): "int";
			case TAbstract(a, []) if (a.path.pack.join(".") == "cpp" && a.path.name == "UInt8"): "unsigned char";
			case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "EnumValue"): "Dynamic";
			case TAbstract(a, [t]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				switch (TypeFunctions.follow(t)) {
					case TAbstract(a2, _) if (a2.path.pack.length == 0
						&& (a2.path.name == "Int" || a2.path.name == "Float" || a2.path.name == "Bool")):
						"Dynamic" + suffix;
					case ft if (CppTypeOf.typeHasMetaKey(ft, ":notNull")): "Dynamic" + suffix;
					case _: typeStringSuff(suffix, t, remap);
				}
			case TEnum(en, _): cppEnumPathOf(en) + suffix;
			case TInst(klass, params): classString(klass, suffix, params, remap);
			case TType(td, params):
				switch [td.path.pack, td.path.name] {
					case [[], "Array"]:
						switch (params) {
							case [t] if (typeString(TypeFunctions.follow(t)) == "Dynamic"): "Dynamic";
							case [t]: "Array< " + typeString(TypeFunctions.follow(t)) + " >";
							case _: throw new TypingError("Bad Array typedef", Position.nullPos);
						}
					case [["cpp"], "FastIterator"]: "::cpp::FastIterator< " + typeString(TypeFunctions.follow(params[0])) + " >";
					case [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"]: "::cpp::Pointer< " + typeString(TypeFunctions.follow(params[0])) + " >";
					case [["cpp"], "RawPointer"]: " " + typeString(TypeFunctions.follow(params[0])) + " *";
					case [["cpp"], "RawConstPointer"]: "const " + typeString(TypeFunctions.follow(params[0])) + " *";
					case [["cpp"], "Function"]: throw new TypingError("cpp.Function in cppia", Position.nullPos);
					case _: typeStringSuff(suffix, TypeFunctions.applyTypedef(td, params), remap);
				}
			case TFun(_): "Dynamic" + suffix;
			case TAnon(_): "Dynamic";
			case TDynamic(_): "Dynamic" + suffix;
			case TLazy(f): typeStringSuff(suffix, TypeFunctions.lazyType(f), remap);
			// A core-type abstract underlies itself; hxc gives it an impl class,
			// so exclude it here or the underlying recursion
			// never terminates (cpp.Int64).
			case TAbstract(abs, pl) if (abs.impl != null && !TypeFunctions.hasMeta(":coreType", abs.meta)):
				typeStringSuff(suffix, CppTypeOf.cppGetUnderlyingType(abs, pl), remap);
			case TAbstract(abs, _): "::" + joinPath(abs.path) + suffix;
		}
	}

	// The class-string branches reachable through cppia type naming
	static function classString(klass:TClass, suffix:String, params:Array<T>, remap:Bool):String {
		function joinPath(p:Path):String {
			return remap ? CppTypeText.joinClassPathRemap(p, "::") : CppTypeOf.joinClassPath(p, "::");
		}
		return switch [klass.path.pack, klass.path.name] {
			case [_, "Void"]: "Void";
			case [[], "Float"]: "Float";
			case [[], "Int"]: "int";
			case [[], "Bool"]: "bool";
			case [[], "Enum"] | [[], "Class"]: "::hx::Class";
			case [[], "EnumValue"]: "Dynamic";
			case [[], "Array"]:
				// Dynamic params collapse to cpp::ArrayBase, else Array< elem >
				var isDyn = params.length > 0 && isDynamicArrayParam(params[0]);
				if (isDyn) "cpp::ArrayBase" + suffix
				else klass.path.name + suffix + "< " + [for (p in params) arrayElementType(p)].join(",") + " >";
			case [["cpp"], "FastIterator"]: "::cpp::FastIterator" + suffix + "< " + [for (p in params) typeString(p)].join(",") + " >";
			case [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"]: "::cpp::Pointer< " + [for (p in params) typeString(p)].join(",") + " >";
			case [["cpp"], "RawPointer"]: " " + [for (p in params) typeString(p)].join(",") + " * ";
			case [["cpp"], "RawConstPointer"]: " const " + [for (p in params) typeString(p)].join(",") + " * ";
			case [["cpp"], "Function"]: throw new TypingError("cpp.Function in cppia", Position.nullPos);
			case [["cpp"], "UInt8"]: "unsigned char";
			case [[], "#Int"]: "/* # */int";
			case [[], "Null"]:
				switch (params) {
					case [t]:
						switch (TypeFunctions.follow(t)) {
							case TAbstract(a2, _) if (a2.path.pack.length == 0
								&& (a2.path.name == "Int" || a2.path.name == "Float" || a2.path.name == "Bool")): "Dynamic";
							case TAbstract(a2, _) if (a2.path.pack.join(".") == "cpp" && a2.path.name == "UInt8"): "Dynamic";
							case ft if (CppTypeOf.typeHasMetaKey(ft, ":notNull")): "Dynamic";
							case ft: "/*NULL*/" + typeString(ft);
						}
					case _: throw new TypingError("Bad Null<>", Position.nullPos);
				}
			case _ if (isDynamicTypeParam(klass.kind)): "Dynamic";
			case _ if (TypeFunctions.hasClassFlag(klass, CInterface) && CppTypeOf.isNativeGenClass(klass)):
				joinPath(klass.path) + " *";
			case _ if (CppTypeOf.isNativeClass(klass)):
				var classParams = params.length == 0 ? "" : "< " + [for (p in params) typeString(p)].join(",") + " >";
				joinPath(klass.path) + classParams;
			case _:
				var globalNamespace = Ast.getMetaString(klass.meta, ":native") != "" ? "" : "::";
				globalNamespace + joinPath(klass.path) + suffix;
		}
	}

	static function arrayElementType(haxeType:T):String {
		var x = typeString(haxeType);
		if (cantBeNull(haxeType)) return x;
		if (isInterfaceType(TypeFunctions.follow(haxeType))) return x;
		if (x == "::String") return "::String";
		return "::Dynamic";
	}

	static function cantBeNull(haxeType:T):Bool {
		return isNumeric(typeString(haxeType)) || CppTypeOf.typeHasMetaKey(haxeType, ":notNull");
	}

	static function isNumeric(s:String):Bool {
		return switch (s) {
			case "Int" | "Bool" | "Float" | "::haxe::io::Unsigned_char__" | "unsigned char" | "int" | "bool"
				| "double" | "float" | "unsigned int" | "short" | "unsigned short" | "char" | "signed char"
				| "long" | "unsigned long" | "cpp::Int8" | "cpp::UInt8" | "cpp::Int16" | "cpp::UInt16"
				| "cpp::Int32" | "cpp::UInt32" | "cpp::Int64" | "cpp::UInt64" | "cpp::Float32" | "cpp::Float64": true;
			case _: false;
		}
	}

	static function isDynamicTypeParam(kind:TClassKind):Bool {
		return switch (kind) {
			case KTypeParameter(constraints): constraints.length == 0;
			case _: false;
		}
	}

	public static function scriptTypeString(haxeType:T):String {
		return switch (haxeType) {
			case TAbstract(a, [t]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				switch (TypeFunctions.follow(t)) {
					case TAbstract(a2, _) if (a2.path.pack.length == 0
						&& (a2.path.name == "Int" || a2.path.name == "Float" || a2.path.name == "Bool")): "Dynamic";
					case _: scriptTypeString(t);
				}
			case TInst(k, [t]) if (k.path.pack.length == 0 && k.path.name == "Null"):
				switch (TypeFunctions.follow(t)) {
					case TAbstract(a2, _) if (a2.path.pack.length == 0
						&& (a2.path.name == "Int" || a2.path.name == "Float" || a2.path.name == "Bool")): "Dynamic";
					case _: scriptTypeString(t);
				}
			case _:
				switch (TypeFunctions.follow(haxeType)) {
					case TType(td, _) if (td.path.pack.length == 0 && td.path.name == "Array"): "Array";
					case TInst(klass, params) if (klass.path.pack.length == 0 && klass.path.name == "Array"):
						switch (params) {
							case [t]:
								switch (typeStringSuff("", t, false)) {
									case "int": "Array.int";
									case "Float": "Array.Float";
									case "bool": "Array.bool";
									case "::String": "Array.String";
									case "unsigned char": "Array.unsigned char";
									case "::cpp::UInt8": "Array.unsigned char";
									case "Dynamic": "Array.Any";
									case _: "Array.Object";
								}
							case _: "Array.Object";
						}
					case TAbstract(abs, pl) if (abs.impl != null && !TypeFunctions.hasMeta(":coreType", abs.meta)):
						scriptTypeString(CppTypeOf.cppGetUnderlyingType(abs, pl));
					case ft: typeStringSuff("", ft, false);
				}
		}
	}

	public static function scriptCppTypeString(cppType:CppType):String {
		return switch (cppType) {
			case TCppDynamic | TCppUnchanged | TCppWrapped(_) | TCppObject: "Dynamic";
			case TCppObjectPtr: ".*.hx.Object*";
			case TCppReference(t): ".ref." + scriptCppTypeString(t);
			case TCppStruct(t): ".struct." + scriptCppTypeString(t);
			case TCppStar(t, _): "*." + scriptCppTypeString(t);
			case TCppVoid: "void";
			case TCppVoidStar: "*.void";
			case TCppRest(_): "vaarg_list";
			case TCppVarArg: "vararg";
			case TCppAutoCast: ".cpp.AutoCast";
			case TCppVariant: ".cpp.Variant";
			case TCppEnum(en): CppTypeOf.joinClassPath(en.path, ".");
			case TCppScalar(scalar): scalar;
			case TCppString: "String";
			case TCppFastIterator(it): "cpp.FastIterator." + scriptCppTypeString(it);
			case TCppPointer(_, valueType): "cpp.Pointer." + scriptCppTypeString(valueType);
			case TCppRawPointer(_, valueType): "cpp.RawPointer." + scriptCppTypeString(valueType);
			case TCppFunction(_): "cpp.Function";
			case TCppObjCBlock(_): "cpp.ObjCBlock";
			case TCppDynamicArray: "Array.Any";
			case TCppObjectArray(_): "Array.Object";
			case TCppScalarArray(value): "Array." + scriptCppTypeString(value);
			case TCppObjC(_): "cpp.ObjC";
			case TCppProtocol(_): "cpp.ObjC.Protocol";
			case TCppNativePointer(klass): "cpp.Pointer." + CppTypeOf.joinClassPath(klass.path, ".");
			case TCppInterface(klass): CppTypeOf.joinClassPath(klass.path, ".");
			case TCppInst(klass, _): CppTypeOf.joinClassPath(klass.path, ".");
			case TCppClass: "Class";
			case TCppGlobal: "?global";
			case TCppNull: "null";
			case TCppCode(_): "Dynamic";
		}
	}

	// The cppia path never fills the member-types table (there is no
	// member-types pre-pass), so every lookup misses.
	static var memberTypes:Map<String, String> = new Map();

	public static function isDynamicInCppia(com:Context, expr:TExpr):Bool {
		return switch (expr.expr) {
			case TCast(_, null): true;
			case _: isDynamicInCpp(com, expr);
		}
	}

	static function isDynamicInCpp(com:Context, expr:TExpr):Bool {
		var exprType = typeString(switch (TypeFunctions.follow(expr.type)) {
			case TFun(sig): sig.ret;
			case _: expr.type;
		});
		if (exprType == "Dynamic" || exprType == "cpp::ArrayBase") return true;
		return switch (expr.expr) {
			case TEnumParameter(_, _, _): true;
			case TField(obj, field):
				isDynamicMemberLookupInCpp(com, obj, field) || isDynamicMemberReturnInCpp(com, obj, field);
			case TArray(obj, _): isDynamicInCpp(com, obj) || isVirtualArray(obj);
			case TTypeExpr(_): false;
			case TCall(func, _):
				var isIaCall = switch (removeParensCast(func).expr) {
					case TField({expr: TIdent("__global__")}, _): false;
					case TField(_, FStatic(_, field)) if (isRealFunction(field)): false;
					case TField(obj, FInstance(_, _, field)) if (isThis(obj) && isRealFunction(field)): false;
					case TField(obj, FInstance(_, _, _)) if (isSuper(obj)): false;
					case TField(_, FInstance(_, _, field)) if (field.name == "_hx_getIndex"): false;
					case TField(obj, FInstance(_, _, field)) if (field.name == "__Index"
						|| (!isDynamicInCppia(com, obj) && isRealFunction(field))): false;
					case TField(obj, FDynamic(name)) if (CppTypeText.isInternalMember(name)
						|| (typeString(obj.type) == "::String" && name == "cca")): false;
					case TConst(TSuper): false;
					case TField(_, FEnum(_, _)): false;
					case _: true;
				}
				if (isIaCall) true
				else switch (TypeFunctions.follow(func.type)) {
					case TFun(_): isDynamicInCpp(com, func);
					case _: true;
				}
			case TParenthesis(e1) | TMeta(_, e1): isDynamicInCpp(com, e1);
			case TCast(_, null): typeString(expr.type) == "Dynamic";
			case TIdent("__global__"): false;
			case TConst(TNull): true;
			case _: false;
		}
	}

	static function isDynamicMemberLookupInCpp(com:Context, fieldObject:TExpr, field:TFieldAccess):Bool {
		var member = TypeFunctions.fieldName(field);
		if (CppTypeText.isInternalMember(member)) return false;
		if (isNativePointer(fieldObject)) return false;
		if (isPointer(fieldObject.type, true)) return false;
		if (fieldObject.expr.match(TTypeExpr(_))) return false;
		if (isDynamicInCpp(com, fieldObject)) return true;
		if (isArray(fieldObject.type)) return false;
		var tstr = typeString(fieldObject.type);
		return switch (tstr) {
			case "::String" | "Null" | "::hx::Class" | "::Enum" | "::Math" | "::ArrayAccess": false;
			case "Dynamic": true;
			case name:
				memberTypes.exists(name + "." + member) ? false : !isExternClassInstance(fieldObject);
		}
	}

	static function isDynamicMemberReturnInCpp(com:Context, fieldObject:TExpr, field:TFieldAccess):Bool {
		var member = TypeFunctions.fieldName(field);
		if (isArray(fieldObject.type)) return false;
		if (isPointer(fieldObject.type, true)) return false;
		if (CppTypeText.isInternalMember(member)) return false;
		return switch (fieldObject.expr) {
			case TTypeExpr(mt):
				var fullName = "::" + CppTypeText.joinClassPathRemap(CppTypeOf.tPath(mt), "::") + "." + member;
				var memType = memberTypes.get(fullName);
				memType == null ? true : (memType == "Dynamic" || memType == "cpp::ArrayBase" || memType == "cpp::VirtualArray");
			case _:
				var tstr = typeString(fieldObject.type);
				switch (tstr) {
					case "::String" | "Null" | "::hx::Class" | "::Enum" | "::Math" | "::ArrayAccess": false;
					case "Dynamic" | "cpp::ArrayBase" | "cpp::VirtualArray": true;
					case name:
						var memType = memberTypes.get(name + "." + member);
						memType == null ? true : (memType == "Dynamic" || memType == "cpp::ArrayBase" || memType == "cpp::VirtualArray");
				}
		}
	}

	public static function generateScriptClass(com:Context, script:CppiaWriter, classDef:TClass):Void {
		script.incClasses();
		var classText = CppTypeOf.joinClassPath(classDef.path, ".");
		script.comment("Class " + classText);
		script.writeOp(TypeFunctions.hasClassFlag(classDef, CInterface) ? IaInterface : IaClass);
		script.instName(classDef);
		switch (classDef.superClass) {
			case null: script.ident("");
			case {c: c}: script.instName(c);
		}
		script.wint(classDef.interfaces.length);
		for (imp in classDef.interfaces) script.instName(imp.c);
		script.write("\n");
		// Some map impl classes have their bodies discarded
		function nonDodgyFunction(allowEmpty:Bool, field:TClassField):Bool {
			if (TypeFunctions.hasClassFlag(classDef, CInterface)) return true;
			return switch [field.kind, field.expr] {
				case [Var(_), _]: true;
				case [Method(MethDynamic), _]: true;
				case [Method(MethNormal), null] if (allowEmpty): true;
				case [Method(_), e] if (e != null): true;
				case _: false;
			}
		}
		var orderedStatics = classDef.orderedStatics.filter(nonDodgyFunction.bind(false));
		var orderedFields = classDef.orderedFields.filter(nonDodgyFunction.bind(true));
		script.write(Std.string(orderedFields.length + orderedStatics.length
			+ (classDef.constructor != null ? 1 : 0)
			+ (classDef.init != null ? 1 : 0)) + "\n");

		function generateField(isStatic:Bool, field:TClassField):Void {
			switch [field.kind, TypeFunctions.follow(field.type)] {
				case [Var({read: AccInline, write: AccNever}), _]:
					script.writeOpLine(IaInline);
				case [Var(v), _]:
					function modeCode(mode:VarAccess):CppiaOp {
						return switch (mode) {
							case AccNormal | AccCtor: IaAccessNormal;
							case AccNo: IaAccessNot;
							case AccNever: IaAccessNot;
							case AccCall:
								(TypeFunctions.hasMeta(":nativeProperty", classDef.meta)
									|| TypeFunctions.hasMeta(":nativeProperty", field.meta)
									|| com.defines.rawDefined("force_native_property"))
									? IaAccessCallNative : IaAccessCall;
							case AccInline: IaAccessNormal;
							case AccRequire(_, _): IaAccessNormal;
						}
					}
					var isExtern = !TypeFunctions.isPhysicalField(field);
					script.varField(modeCode(v.read), modeCode(v.write), isExtern, isStatic, field.name, field.type, field.expr);
				case [Method(MethDynamic), TFun(sig)]:
					script.func(isStatic, true, field.name, sig.ret, sig.args, TypeFunctions.hasClassFlag(classDef, CInterface), field.expr, field.pos);
				case [Method(_), TFun(sig)] if (field.name == "new"):
					script.func(true, false, "new", TInst(classDef, []), sig.args, false, field.expr, field.pos);
				case [Method(_), TFun(sig)]:
					script.func(isStatic, false, field.name, sig.ret, sig.args, TypeFunctions.hasClassFlag(classDef, CInterface), field.expr, field.pos);
				case [Method(_), _]:
					Sys.println("Unknown method type " + CppTypeOf.joinClassPath(classDef.path, ".") + "." + field.name);
			}
		}
		if (classDef.constructor != null) generateField(true, classDef.constructor);
		if (classDef.init != null) script.voidFunc(true, false, "__init__", classDef.init);
		for (f in orderedFields) generateField(false, f);
		for (f in orderedStatics) generateField(true, f);
		script.write("\n");
	}

	public static function generateScriptEnum(com:Context, script:CppiaWriter, enumDef:TEnum, meta:Null<TExpr>):Void {
		script.incClasses();
		var sortedItems = [for (name in enumDef.names) enumDef.constrs.get(name)];
		sortedItems.sort(function(f1, f2) return f1.index - f2.index);
		script.writeList(script.op(IaEnum) + script.enumText(enumDef), sortedItems.length);
		for (constructor in sortedItems) {
			var name = script.stringText(constructor.name);
			switch (constructor.type) {
				case TFun(sig):
					script.write(name + " " + sig.args.length);
					for (a in sig.args) script.write(" " + script.stringText(a.name) + " " + script.typeText(a.t));
					script.write("\n");
				case _:
					script.write(name + " 0\n");
			}
		}
		if (meta != null) {
			script.write("1\n");
			script.genExpression(meta);
		} else {
			script.write("0\n");
		}
		script.write("\n");
	}

	public static function generate(com:Context):Void {
		var debug = com.debug;
		var trace = com.defines.rawDefined("cppgen-trace");
		// Override fixing runs for the Cpp platform before either generator.
		for (mt in com.types) CppFixOverrides.fixOverrides(com, mt);
		mkdirFromPath(com.file);
		var script = new CppiaWriter(com, com.file, com.debug);
		script.stringId("");
		script.typeId("");
		for (objectDef in com.types) {
			switch (objectDef) {
				case TClassDecl(classDef) if (TypeFunctions.hasClassFlag(classDef, CExtern)):
				case TClassDecl(classDef):
					var isInternal = CppTypeOf.isInternalClass(classDef.path);
					if (isInternal || isMacro(classDef.meta)) {
						if (debug) {}
					} else {
						if (trace) { Sys.stderr().writeString("[cppia] class " + CppTypeOf.joinClassPath(classDef.path, ".") + "\n"); Sys.stderr().flush(); }
						generateScriptClass(com, script, classDef);
					}
				case TEnumDecl(enumDef) if (enumDef.isExtern):
				case TEnumDecl(enumDef):
					var isInternal = CppTypeOf.isInternalClass(enumDef.path);
					if (!isInternal) {
						var meta = TexprTools.buildMetadata(com.basic, objectDef);
						generateScriptEnum(com, script, enumDef, meta);
					}
				case TTypeDecl(_) | TAbstractDecl(_):
			}
		}
		if (com.main == null) script.writeOpLine(IaNoMain);
		else {
			script.writeOpLine(IaMain);
			script.genExpression(com.main);
		}
		var resourceNames = [for (k in com.resources.keys()) k];
		script.write(script.op(IaResources) + resourceNames.length + "\n");
		for (name in resourceNames) {
			var data = com.resources.get(name);
			script.write(script.op(IaReso) + script.stringText(name) + data.length + "\n");
		}
		for (name in resourceNames) script.writeData(com.resources.get(name).toString());
		script.close();
	}

	static function mkdirFromPath(file:String):Void {
		var norm = file.split("\\").join("/");
		var idx = norm.lastIndexOf("/");
		if (idx <= 0) return;
		var dir = norm.substr(0, idx);
		if (dir != "" && !sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
	}
}
