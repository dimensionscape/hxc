package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.ast.Ast;
import hxc.ast.Ast.Metadata;

// hxc.generators.cpp.CppReferenced: the "referenced types" machinery. A class/enum's header lists a forward
// declaration (HX_DECLARE_CLASS<n>) for every type it mentions, and its cpp lists the matching #includes;
// the same walk drives the Build.xml <depend> list and the canInlineConstructor check. Provides
// createSuperDependencies, createConstructorDependencies, findReferencedTypesFlags and genForwardDecl.
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
				if (c.superClass != null && !TypeFunctions.hasClassFlag(c.superClass.c, CExtern)) deps.unshift(c.superClass.c.path);
				for (imp in realNonNativeInterfaces(c.interfaces))
					if (!TypeFunctions.hasClassFlag(imp.c, CExtern)) deps.unshift(imp.c.path);
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

	// A cpp.rtti interface named without type parameters is a marker, and a @:nativeGen class is not a real
	// interface.
	static function realNonNativeInterfaces(ifaces:Array<TClassWithParams>):Array<TClassWithParams> {
		return [for (i in ifaces) if (!(i.c.path.pack.length == 2 && i.c.path.pack[0] == "cpp"
			&& i.c.path.pack[1] == "rtti" && i.params.length == 0) && !CppTypeOf.isNativeGenClass(i.c)) i];
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

	// A `./`-relative @:include/@:cppInclude/@:depend path resolves against the directory of the .hx file
	// the meta sits in, so the emitted #include still finds the companion file from the generated-source
	// directory. A bare header name (e.g. "vector") is left as is. The meta position's file is relative to
	// the invocation cwd, which still holds during codegen (the build step's chdir runs later).
	static function makePathAbsolute(path:String, pos:hxc.ast.Position):String {
		if (path.length >= 2 && path.substr(0, 2) == "./") {
			var base = haxe.io.Path.isAbsolute(pos.file) ? pos.file : haxe.io.Path.join([Sys.getCwd(), pos.file]);
			var joined = haxe.io.Path.join([haxe.io.Path.directory(base), path.substr(2)]);
			return StringTools.replace(haxe.io.Path.normalize(joined), "\\", "/");
		}
		return path;
	}

	// Every string parameter of the given meta key, as a path.
	public static function getAllMetaStringPath(meta:Metadata, mkey:String):Array<String> {
		var acc:Array<String> = [];
		for (m in meta) if (m.name == mkey && m.params.length > 0) switch (m.params[0].expr) {
			case EConst(CString(s, _)): acc.push(makePathAbsolute(s, m.pos));
			case _:
		}
		return acc;
	}

	// An @:include/@:depend file becomes a @verbatim path (a raw include).
	static inline function pathOfString(s:String):Path {
		return {pack: ["@verbatim"], name: s};
	}

	// Returns the sorted referenced paths and, per path, a flag that is true for a native forward
	// declaration (HX_DECLARE_NATIVE); headerOnly skips field bodies. forDepends is the Build.xml <depend>
	// walk (the class/enum deps and the @Main deps): a type's @:depend files stand where its @:include
	// files would.
	public static function findReferencedTypesFlags(com:Context, obj:ModuleType, fieldName:String,
			superDeps:Map<String, Array<Path>>, constructorDeps:Map<String, TClassField>, headerOnly:Bool,
			includeSuperArgs:Bool, forDepends:Bool = false):{deps:Array<Path>, flags:Array<Bool>} {
		var types = new Map<String, {path:Path, isNative:Bool}>();
		if (forDepends)
			for (inc in getAllMetaStringPath(TypeFunctions.tInfos(obj).meta, ":depend")) {
				var p = pathOfString(inc);
				types.set(key(p), {path: p, isNative: true});
			}

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
			var includeFiles = getAllMetaStringPath(meta, forDepends ? ":depend" : ":include");
			if (includeFiles.length > 0) for (inc in includeFiles) addType(pathOfString(inc));
			else if (!forDepends && TypeFunctions.hasMeta(":include", meta)) addType(TypeFunctions.tPath(decl));
		}
		function addNativeGenClass(klass:TClass):Void {
			var includeFiles = getAllMetaStringPath(klass.meta, forDepends ? ":depend" : ":include");
			if (includeFiles.length > 0) for (inc in includeFiles) addType(pathOfString(inc));
			else if (forDepends) addType(klass.path);
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
				// The C++ generator follows through abstracts, so visitType sees a non-coreType abstract as
				// its underlying type (Map as StringMap/IntMap, a chain A(T) to T where T(X) to X as X).
				// TypeFunctions.follow stops at the abstract; it is resolved here the way
				// CppTypeOf.cppTypeOf resolves it.
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
							// A static access on an abstract (haxe.CallStack.callStack()) keeps the
							// abstract as the TTypeExpr, but an abstract emits no file of its own, only its
							// _Impl_. Resolve to the impl class so the include list names the file that
							// actually exists. A @:coreType abstract (cpp.Int64) has no generated impl
							// file; it is a native type pulled in through its own include, so it is not
							// resolved to an _Impl_ file here.
							case TAbstractDecl(a) if (a.impl != null && !TypeFunctions.hasMeta(":coreType", a.meta)):
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
					case TField(receiver, fa):
						switch (fa) {
							case FInstance(clazz, params, _):
								var owner = switch (TypeFunctions.follow(receiver.type)) {
									case TInst(c, _): switch (c.kind) {
										case KGenericInstance(base, _) if (base == clazz): c;
										case _: clazz;
									}
									case _: clazz;
								};
								visitType(TInst(owner, owner == clazz ? params : []));
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
				// The enum's runtime metadata expression too.
				if (!headerOnly) {
					var meta = hxc.core.TexprTools.buildMetadata(com.basic, TEnumDecl(e));
					if (meta != null) visitParams(meta);
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
