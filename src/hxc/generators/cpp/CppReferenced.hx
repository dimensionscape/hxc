package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.ast.Ast;
import hxc.ast.Ast.Metadata;

// hxc.generators.cpp.CppReferenced: the "referenced types" machinery . A class/enum's header lists a
// forward declaration (HX_DECLARE_CLASS<n>) for every type it mentions, and its cpp lists the matching
// #includes; the same walk drives the Build.xml <depend> list and the can_inline_constructor check. Ported:
// create_super_dependencies (7064), create_constructor_dependencies (7082), find_referenced_types_flags
// (4838) and gen_forward_decl (548).
class CppReferenced {
	static inline function key(p:Path):String {
		return CppTypeOf.joinClassPath(p, ".");
	}

	// Each non-extern class maps to the paths of its non-extern super and (real, non-native) interfaces; a
	// non-extern enum maps to the empty list.
	public static function createSuperDependencies(com:Context):Map<String, Array<Path>> {
		var result = new Map<String, Array<Path>>();
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern)):
				var deps:Array<Path> = [];
				if (c.superClass != null && !TypeFunctions.hasClassFlag(c.superClass.c, CExtern)) deps.push(c.superClass.c.path);
				for (imp in realNonNativeInterfaces(c.interfaces))
					if (!TypeFunctions.hasClassFlag(imp.c, CExtern)) deps.push(imp.c.path);
				result.set(key(c.path), deps);
			case TEnumDecl(e) if (!e.isExtern):
				result.set(key(e.path), []);
			case _:
		}
		return result;
	}

	// Each non-extern class maps to its constructor field.
	public static function createConstructorDependencies(com:Context):Map<String, TClassField> {
		var result = new Map<String, TClassField>();
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern)):
				if (c.constructor != null) result.set(key(c.path), c.constructor);
			case _:
		}
		return result;
	}

	// (real_non_native_interfaces / real_interfaces): drop the cpp.rtti marker interfaces.
	static function realNonNativeInterfaces(ifaces:Array<TClassWithParams>):Array<TClassWithParams> {
		return [for (i in ifaces) if (!(i.c.path.pack.length == 2 && i.c.path.pack[0] == "cpp"
			&& i.c.path.pack[1] == "rtti") && !TypeFunctions.hasMeta(":native", i.c.meta)) i];
	}

	// The class's virtual methods (Method, non-dynamic, TFun) resolved across the super chain, most-derived
	// kept per name. Only the fields are needed by the referenced-type walk, so no argument/return-type
	// tuples are collected.
	static function allVirtualFunctions(clazz:TClass):Array<TClassField> {
		var seen = new Map<String, Bool>();
		var acc:Array<TClassField> = [];
		var c = clazz;
		while (c != null) {
			for (elem in c.orderedFields) switch [TypeFunctions.follow(elem.type), elem.kind] {
				case [TFun(_), Method(k)] if (k != MethDynamic):
					if (!seen.exists(elem.name)) { seen.set(elem.name, true); acc.push(elem); }
				case _:
			}
			c = c.superClass != null ? c.superClass.c : null;
		}
		return acc;
	}

	static function includeClassHeader(path:Path):Bool {
		if (path.pack.length == 0 && path.name == "@Main") return false;
		if (path.pack.length == 0 && path.name == "Math") return true;
		if (path.pack.length == 1 && path.pack[0] == "@verbatim") return true;
		return !CppTypeOf.isInternalClass(path);
	}

	// Every string parameter of the given meta key, as a path.
	public static function getAllMetaStringPath(meta:Metadata, mkey:String):Array<String> {
		var acc:Array<String> = [];
		for (m in meta) if (m.name == mkey && m.params.length > 0) switch (m.params[0].expr) {
			case EConst(CString(s, _)): acc.push(s);
			case _:
		}
		return acc;
	}

	// An @:include/@:depend file becomes a @verbatim path (a raw include).
	static inline function pathOfString(s:String):Path {
		return {pack: ["@verbatim"], name: s};
	}

	// Returns the sorted referenced paths and, per path, a flag that is true for a native forward
	// declaration (HX_DECLARE_NATIVE). This port covers the header call (field_name="*", constructor_deps
	// unused, for_depends=false); header_only skips field bodies.
	public static function findReferencedTypesFlags(com:Context, obj:ModuleType, fieldName:String,
			superDeps:Map<String, Array<Path>>, constructorDeps:Map<String, TClassField>, headerOnly:Bool,
			includeSuperArgs:Bool):{deps:Array<Path>, flags:Array<Bool>} {
		var types = new Map<String, {path:Path, isNative:Bool}>();

		function addTypeFlag(isNative:Bool, path:Path):Void {
			var k = key(path);
			if (!types.exists(k)) {
				types.set(k, {path: path, isNative: isNative});
				var sd = superDeps.get(k);
				if (sd != null) for (p in sd) addTypeFlag(isNative, p);
			}
		}
		function addType(path:Path):Void addTypeFlag(false, path);

		function addExternType(decl:ModuleType):Void {
			var meta = TypeFunctions.tInfos(decl).meta;
			var includeFiles = getAllMetaStringPath(meta, ":include");
			if (includeFiles.length > 0) for (inc in includeFiles) addType(pathOfString(inc));
			else if (TypeFunctions.hasMeta(":include", meta)) addType(TypeFunctions.tInfos(decl).path);
		}
		function addNativeGenClass(klass:TClass):Void {
			var includeFiles = getAllMetaStringPath(klass.meta, ":include");
			if (includeFiles.length > 0) for (inc in includeFiles) addType(pathOfString(inc));
			else if (!TypeFunctions.hasClassFlag(klass, CInterface))
				addType(pathOfString(CppTypeOf.joinClassPath(klass.path, "/") + ".h"));
			else addTypeFlag(true, klass.path);
		}

		var visited:Array<T> = [];
		function visitType(inType:T):Void {
			for (t2 in visited) if (TypeUnification.fastEq(inType, t2)) return;
			visited.push(inType);
			switch (TypeFunctions.follow(inType)) {
				case TMono(r): if (r.type != null) visitType(r.type);
				case TEnum(enm, _): if (CppTypeOf.isExternEnum(enm)) addExternType(TEnumDecl(enm)) else addType(enm.path);
				case TInst(klass, params):
					switch [klass.path.pack, klass.path.name] {
						case [[], "Array"] | [[], "Class"] | [["cpp"], "FastIterator"] | [["cpp"], "Pointer"]
							| [["cpp"], "ConstPointer"] | [["cpp"], "Function"] | [["cpp"], "RawPointer"] | [["cpp"], "RawConstPointer"]:
							for (p in params) visitType(p);
						case _:
							if (CppTypeOf.isNativeGenClass(klass)) addNativeGenClass(klass);
							else if (CppTypeOf.isExternClass(klass)) { addExternType(TClassDecl(klass)); for (p in params) visitType(p); }
							else switch (klass.kind) { case KTypeParameter(_): case _: addType(klass.path); }
					}
				case TAbstract(a, _) if (CppTypeOf.isScalarAbstract(a)): addExternType(TAbstractDecl(a));
				// cpp_type_of lowers a non-coreType abstract to its underlying type, so an abstract
				// member/argument is emitted as that underlying class (Map -> StringMap/IntMap, or a chain
				// like A(T) to T where T(X) to X, emitted as X). The referenced-type walk must resolve it
				// the same way, else the emitted class name has no forward-declaration. The reference
				// relies on the field's type already being the concrete type; hxc resolves here.
				case TAbstract(a, params) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
					visitType(CppTypeOf.cppGetUnderlyingType(a, params));
				case TFun(sig): visitType(sig.ret); for (a in sig.args) visitType(a.t);
				case _:
			}
			visited.pop();
		}

		function visitParams(expr:TExpr):Void {
			function visitExpr(e:TExpr):Void {
				switch (e.expr) {
					case TTypeExpr(td):
						switch (td) {
							case TClassDecl(c) if (CppTypeOf.isNativeGenClass(c)): addNativeGenClass(c);
							case TClassDecl(c) if (CppTypeOf.isExternClass(c)): addExternType(TClassDecl(c));
							case TEnumDecl(en) if (CppTypeOf.isExternEnum(en)): addExternType(TEnumDecl(en));
							// A static access on an abstract (haxe.CallStack.callStack()) keeps the abstract as
							// the TTypeExpr in hxc, but the reference AST carries the abstract's impl class (an
							// abstract emits no file of its own, only its _Impl_). Resolve to the impl class so
							// the include list names the file that actually exists, mirroring the reference.
							case TAbstractDecl(a) if (a.impl != null):
								var c = a.impl;
								if (CppTypeOf.isNativeGenClass(c)) addNativeGenClass(c);
								else if (CppTypeOf.isExternClass(c)) addExternType(TClassDecl(c));
								else addType(c.path);
							case _: addType(CppTypeOf.tPath(td));
						}
					case TTry(_, catches): for (c in catches) visitType(c.v.type);
					case TNew(klass, params, _):
						visitType(TInst(klass, params));
						var ctor = constructorDeps.get(key(klass.path));
						if (ctor != null) visitType(ctor.type);
					case TVarExpr(v, _): visitType(v.type);
					case TEnumParameter(_, ef, _): visitType(TypeFunctions.follow(ef.type));
					case TFunction(fd): for (a in fd.args) visitType(a.v.type);
					case TField(_, fa):
						switch (fa) {
							case FInstance(clazz, params, _): visitType(TInst(clazz, params));
							case FClosure(cwp, _) if (cwp != null): visitType(TInst(cwp.c, cwp.params));
							case _:
						}
					case TConst(TSuper):
						switch (TypeFunctions.follow(e.type)) {
							case TInst(klass, _):
								var ctor = constructorDeps.get(key(klass.path));
								if (ctor != null) visitType(ctor.type);
							case _:
						}
					case _:
				}
				hxc.core.TexprTools.iter(visitExpr, e);
				visitType(TypeFunctions.follow(e.type));
			}
			visitExpr(expr);
		}

		function visitField(f:TClassField):Void {
			visitType(f.type);
			if (!headerOnly) switch (f.expr) { case null: case ex: visitParams(ex); }
		}

		switch (obj) {
			case TClassDecl(c):
				var fields = c.orderedFields.concat(c.orderedStatics);
				var all = c.constructor != null ? fields.concat([c.constructor]) : fields;
				if (fieldName != "*") all = [for (f in all) if (f.name == fieldName) f];
				for (f in all) visitField(f);
				if (includeSuperArgs) for (f in allVirtualFunctions(c)) visitField(f);
				if (CppTypeOf.isNativeGenClass(c)) addNativeGenClass(c) else addType(c.path);
				if (c.init != null) visitParams(c.init);
			case TEnumDecl(e):
				addType(e.path);
				for (cn in e.constrs) switch (cn.type) {
					case TFun(sig): for (a in sig.args) visitType(a.t);
					case _:
				}
			case _:
		}

		var deps = [for (v in types) v];
		deps = [for (v in deps) if (includeClassHeader(v.path)) v];
		deps.sort(function(a, b) return compareStrings(key(a.path), key(b.path)));
		return {deps: [for (v in deps) v.path], flags: [for (v in deps) v.isNative]};
	}

	static function compareStrings(a:String, b:String):Int {
		return a < b ? -1 : (a > b ? 1 : 0);
	}

	// A @verbatim path is a guarded #include; otherwise a HX_DECLARE_CLASS (or HX_DECLARE_NATIVE) with the
	// package-arity suffix and the remapped package parts.
	public static function genForwardDecl(w:CppWriter, path:Path, isNative:Bool):Void {
		if (path.pack.length == 1 && path.pack[0] == "@verbatim") {
			w.write(CppGenClass.guardedInclude(path.name));
			return;
		}
		var remapped = CppTypeText.remapClassPath(path);
		w.write((isNative ? "HX_DECLARE_NATIVE" : "HX_DECLARE_CLASS") + remapped.pack.length + "(");
		for (part in remapped.pack) w.write(part + ",");
		w.write(remapped.name + ")\n");
	}
}
