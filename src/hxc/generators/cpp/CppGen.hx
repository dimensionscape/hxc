package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;
import hxc.core.Globals.Path;
import hxc.generators.cpp.CppType;

// hxc.generators.cpp.CppGen: the source generation driver - walk com.types, write a .cpp/.h per
// non-internal, non-extern class, plus __boot__, __main__/__lib__, __files__, __resources__, Build.xml and
// Options.txt.
class CppGen {
	public static function generate(com:Context):Void {
		// The interface-slot map is per-generation state; reset it before the class pass fills it.
		CppScriptable.resetInterfaceSlots();
		// Interface method slots are numbered in REVERSE com.types order, each interface assigning its
		// methods' slots on first sight. The class loop below runs forward, so pre-assign the slots in
		// reverse order here.
		if (com.defines.rawDefined("scriptable")) {
			var rev = com.types.copy();
			rev.reverse();
			for (mt in rev) switch (mt) {
				case TClassDecl(c) if (shouldEmit(c) && TypeFunctions.hasClassFlag(c, CInterface) && !TypeFunctions.hasMeta(":nativeGen", c.meta)):
					for (f in CppScriptable.allVirtualFunctions(c)) CppScriptable.cppGetInterfaceSlot(CppTypeText.keywordRemap(f.name));
				case _:
			}
		}
		var base = com.file;
		var sourceExtension = sourceFileExtension(com);
		ensureDir(base);
		ensureDir(base + "/src");
		ensureDir(base + "/include");

		// Class-id pre-pass: assign every eligible type its id (collision-avoided) before any class is
		// emitted, so classId()/parent-id lookups are byte-exact synthesize the forwarding constructor
		// for every subclass that inherits one but declares none, so __new/__alloc and __construct match
		// the oracle. rewrite each override method's signature to match its overridden base (return type
		// + arg types) so C++ virtual overrides are covariant-clean; must run before add_constructor and
		// generation. a static `__init__` is the class-init block, not a reflective static method. hxc's
		// typer leaves it in orderedStatics; move its (non-trivial) body to init here (cpp-only) so it
		// emits as `void C::__init__()` and is dropped from method/reflection emission, matching the
		// oracle.
		for (mt in com.types) switch (mt) {
			case TClassDecl(c):
				var initCf = null;
				for (cf in c.orderedStatics) if (cf.name == "__init__") { initCf = cf; break; }
				if (initCf != null) {
					switch (initCf.expr) {
						case {expr: TFunction(tf)}:
							var trivial = switch (tf.expr.expr) {
								case TBlock([]) | TConst(_) | TObjectDecl([]): true;
								case TBlock([{expr: TConst(_)}]): true;
								case _: false;
							};
							if (!trivial && c.init == null) c.init = tf.expr;
						case _:
					}
					c.orderedStatics = c.orderedStatics.filter(function(f) return f != initCf);
					c.statics.remove("__init__");
				}
			case _:
		}
		for (mt in com.types) CppFixOverrides.fixOverrides(com, mt);
		// Constructor synthesis (the forwarding/inherited/compiler-generated constructors) is done at typer
		// time by Filters.run -> Typer.ensureInheritedCtor for every platform, so no cpp-gen pass is needed.
		CppGenClass.buildTypeIds(com);
		CppGenClass.createMemberTypes(com);
		CppGenClass.superDeps = CppReferenced.createSuperDependencies(com);
		CppGenClass.constructorDeps = CppReferenced.createConstructorDependencies(com);
		CppGenClass.fileInfo = new Map();
		var generatedHeaders = new Map<String, Bool>();
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (shouldEmit(c)): generatedHeaders.set(Context.pathKey(c.path), true);
			case TEnumDecl(e) if (shouldEmitEnum(e)): generatedHeaders.set(Context.pathKey(e.path), true);
			case _:
		}

		// exe_classes: (path, deps) in reverse com.types order . deps = the Build.xml <depend> list = self
		// header + referenced headers (same order as the .cpp includes).
		var exeClasses:Array<{path:Path, deps:Array<Path>, mt:ModuleType}> = [];
		// -D cppgen-trace: log each type to stderr (flushed) right before it is emitted, so a hard crash
		// during generation names the culprit as the last line printed instead of failing silently.
		var trace = com.defines.rawDefined("cppgen-trace");
		inline function traceType(kind:String, path:Path):Void {
			if (trace) { Sys.stderr().writeString("[cppgen] " + kind + " " + CppGenClass.joinPath(path, ".") + "\n"); Sys.stderr().flush(); }
		}
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (shouldEmit(c)):
				traceType("class", c.path);
				var gc = new CppGenClass(com, c);
				var p = CppGenClass.joinPath(c.path, "/");
				ensureDir(base + "/include/" + dirOf(p));
				ensureDir(base + "/src/" + dirOf(p));
				var nativeGen = TypeFunctions.hasMeta(":nativeGen", c.meta);
				// The cpp is generated before the header so interface-glue forwarders accumulated during
				// the cpp pass are available when the header is emitted. A @:nativeGen interface writes
				// only a header, no cpp.
				var isNativeGenInterface = nativeGen && TypeFunctions.hasClassFlag(c, CInterface);
				var cppText = isNativeGenInterface ? null : (nativeGen ? gc.genNativeGenCpp() : gc.genCpp());
				writeSourceFile(com, base + "/include/" + p + ".h", nativeGen ? gc.genNativeGenHeader() : gc.genHeader());
				if (!isNativeGenInterface)
					writeSourceFile(com, base + "/src/" + p + sourceExtension, cppText);
				// Deps = self + referenced types, SORTED together (matches the .cpp include order)
				var refs = [c.path].concat(gc.referencedPaths()).filter(function(p) return generatedHeaders.exists(Context.pathKey(p)));
				refs.sort(function(a, b) return Reflect.compare(CppGenClass.joinPath(a, "/"), CppGenClass.joinPath(b, "/")));
				if (!(TypeFunctions.hasClassFlag(c, CInterface) && CppTypeOf.isNativeGenClass(c)))
					exeClasses.unshift({path: c.path, deps: refs, mt: mt});
			case TEnumDecl(e) if (shouldEmitEnum(e)):
				traceType("enum", e.path);
				var ge = new CppGenEnum(com, e);
				var p = CppGenClass.joinPath(e.path, "/");
				ensureDir(base + "/include/" + dirOf(p));
				ensureDir(base + "/src/" + dirOf(p));
				writeSourceFile(com, base + "/include/" + p + ".h", ge.genHeader());
				writeSourceFile(com, base + "/src/" + p + sourceExtension, ge.genCpp());
				var erefs = CppReferenced.findReferencedTypesFlags(com, TEnumDecl(e), "*", CppGenClass.superDeps, CppGenClass.constructorDeps, false, false).deps;
				erefs.sort(function(a, b) return Reflect.compare(CppGenClass.joinPath(a, "/"), CppGenClass.joinPath(b, "/")));
				exeClasses.unshift({path: e.path, deps: erefs, mt: mt});
			case _:
		}

		// An extern class contributes its @:sourceFile native source to the Build.xml __externs__ group
		// (prepended while walking com.types, so reverse type order).
		var externSrc:Array<String> = [];
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (CppTypeOf.isExternClass(c)):
				var srcs = CppReferenced.getAllMetaStringPath(c.meta, ":sourceFile");
				if (srcs.length > 0) externSrc.unshift(srcs[0]);
			case _:
		}

		genBoot(com, base, sourceExtension);
		genMain(com, base, sourceExtension);
		genFiles(com, base, sourceExtension);
		genResources(com, base, sourceExtension);
		genExportClassesInfo(com, exeClasses);
		genBuildXml(com, base, exeClasses, sourceExtension, externSrc);
		genOptions(com, base);
		if (!com.defines.rawDefined("no_compilation")) compileNative(com, base);
	}

	// Objc always selects Objective-C++, otherwise -D file_extension supplies the suffix, defaulting
	// to C++.
	static function sourceFileExtension(com:Context):String {
		if (com.defines.rawDefined("objc")) return ".mm";
		return "." + com.defines.rawDefinedValueSafe("file_extension", "cpp");
	}

	// Invoke hxcpp after the project files have been written.
	static function compileNative(com:Context, base:String):Void {
		var args = ["run", "hxcpp", "Build.xml", "haxe"];
		if (com.debug) args.push("-Ddebug");
		var skip = ["true", "sys", "dce", "cpp", "debug"];
		var names = [for (k in com.defines.values.keys()) k];
		names.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
		for (name in names) {
			if (skip.indexOf(name) < 0) args.push("-D" + name + "=" + com.defines.values.get(name));
		}
		for (path in com.classPath) args.push("-I" + path);
		var oldDir = Sys.getCwd();
		try {
			Sys.setCwd(base);
			var result = Sys.command("haxelib", args);
			Sys.setCwd(oldDir);
			if (result != 0) throw "Build failed";
		} catch (e:Dynamic) {
			Sys.setCwd(oldDir);
			throw e;
		}
	}

	static function shouldEmit(c:TClass):Bool {
		return !CppTypeOf.isInternalClass(c.path) && !CppTypeOf.isExternClass(c)
			&& !TypeFunctions.hasMeta(":macro", c.meta);
	}

	static function shouldEmitEnum(e:TEnum):Bool {
		// An enum is generated when it is neither extern nor an internal class. A @:nativeGen enum is still
		// generated with the ordinary EnumBase header (unlike a @:nativeGen class), so it must not be
		// excluded here.
		return !CppTypeOf.isInternalClass(e.path) && !e.isExtern;
	}

	static function guardedInclude(path:Path):String {
		var guard = CppGenClass.joinPath(path, "_");
		var inc = CppGenClass.joinPath(path, "/");
		return "#ifndef INCLUDED_" + guard + "\n#include <" + inc + ".h>\n#endif\n";
	}

	// __boot_all registers every class. Include + register order is boot enums ++ boot classes ++ nonboot
	// classes (each list is reverse com.types order).
	static function genBoot(com:Context, base:String, sourceExtension:String):Void {
		var order = CppGenClass.bootEnums.concat(CppGenClass.bootClasses).concat(CppGenClass.nonbootClasses);
		var scriptable = com.defines.rawDefined("scriptable");
		var b = new StringBuf();
		b.add("#include <hxcpp.h>\n\n");
		for (p in order) b.add(guardedInclude(p));
		// A scriptable build lists every interface method name (sorted by its assigned slot id) so the
		// cppia loader can bind them.
		if (scriptable) {
			b.add("#include <hx/Scriptable.h>\n");
			var funcs = [for (name in CppScriptable.interfaceSlots.keys()) {name: name, id: CppScriptable.interfaceSlots.get(name)}];
			funcs.sort(function(a, b) return a.id - b.id);
			b.add("static const char *scriptableInterfaceFuncs[] = {\n\t0,\n\t0,\n");
			for (f in funcs) b.add("\t\"" + f.name + "\", //" + (-f.id) + "\n");
			b.add("};\n");
		}
		b.add("\nvoid __files__boot();\n");
		b.add("\nvoid __boot_all()\n{\n");
		b.add("__files__boot();\n");
		b.add("::hx::RegisterResources( ::hx::GetResources() );\n");
		if (scriptable) b.add("::hx::ScriptableRegisterNameSlots(scriptableInterfaceFuncs," + CppScriptable.interfaceSlotCount + ");\n");
		for (p in order) b.add("::" + CppTypeText.joinClassPathRemap(p, "::") + "_obj::__register();\n");
		// The boot sequence: enums __boot(), then (init classes __init__), then boot classes __boot()
		// (reversed back to com.types order).
		for (p in CppGenClass.bootEnums) b.add("::" + CppTypeText.joinClassPathRemap(p, "::") + "_obj::__boot();\n");
		// Every class with a init runs its __init__() (com.types order).
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (c.init != null && shouldEmit(c)):
				b.add("::" + CppTypeText.joinClassPathRemap(c.path, "::") + "_obj::__init__();\n");
			case _:
		}
		var bootCls = CppGenClass.bootClasses.copy();
		bootCls.reverse();
		// Classes boot in two passes: the cpp classes (the cpp package, EReg, haxe.Log) first, then
		// everything else.
		inline function isCppClass(p:hxc.core.Globals.Path):Bool
			return (p.pack.length > 0 && p.pack[0] == "cpp")
				|| (p.pack.length == 0 && p.name == "EReg")
				|| (p.pack.length == 1 && p.pack[0] == "haxe" && p.name == "Log");
		for (p in bootCls) if (isCppClass(p)) b.add("::" + CppTypeText.joinClassPathRemap(p, "::") + "_obj::__boot();\n");
		for (p in bootCls) if (!isCppClass(p)) b.add("::" + CppTypeText.joinClassPathRemap(p, "::") + "_obj::__boot();\n");
		b.add("}\n\n");
		writeSourceFile(com, base + "/src/__boot__" + sourceExtension, b.toString());
	}

	// __hxcpp_main runs the entry call; __lib__ is the library form.
	static function genMain(com:Context, base:String, sourceExtension:String):Void {
		for (isMain in [true, false]) {
			var name = isMain ? "__main__" : "__lib__";
			var w = new CppWriter();
			w.writeH("#include <hxcpp.h>\n\n#include <stdio.h>\n\nextern \"C\" void __hxcpp_main();\n\nextern \"C\" void __hxcpp_lib_main();\n\n");
			// With a main class the referenced headers are included, then "\n\n"; without one (for example
			// -D static_link) neither is emitted.
			if (com.main != null) {
				for (p in mainRefs(com)) w.writeH(guardedInclude(p));
				w.write("\n\n");
			}
			if (isMain) w.write("\n#include <hx/HxcppMain.h>\n\n");
			w.write("void __hxcpp_main() {\n");
			if (com.main != null) {
				// The prologue pushes the "hxcpp" "__hxcpp_main" entry stack frame (its position is
				// synthetic, so file "?" and line 1).
				var mainFile = com.main.pos.file;
				var mainLine = CppEmit.getErrorLine(com.main.pos);
				new CppEmit(com, w, 1, true).genExpressionTree([], TypeFunctions.tDynamic, com.main,
					function(gc) CppGenClass.hxStackPush(com, w, "hxcpp", "__hxcpp_main", mainFile, mainLine, gc));
			}
			w.write("\t}\n\nvoid __hxcpp_lib_main() {\n\tHX_TOP_OF_STACK\n\t::hx::Boot();\n\t__boot_all();\n\t__hxcpp_main();\n\t}\n");
			writeSourceFile(com, base + "/src/" + name + sourceExtension, w.getHeader() + w.getBody());
		}
	}

	// The classes referenced by the entry expression (for the __main__ includes). The main is a block
	// (the entry call plus the event-loop pump), so walk the whole tree and collect each
	// field/new/type target's class path; those are already the _Impl_/_Fields_ variants the include
	// list needs.
	static function mainRefs(com:Context):Array<Path> {
		var paths:Array<Path> = [];
		function add(p:Path):Void {
			for (q in paths) if (q.name == p.name && q.pack.join(".") == p.pack.join(".")) return;
			paths.push(p);
			// Main deps come from find_referenced_types over the @Main class, which pulls each referenced
			// type's super chain (add_type follows super_deps); so a main class extending utest.Test drags
			// in utest.Test and utest.ITest.
			var sd = CppGenClass.superDeps.get(CppTypeOf.joinClassPath(p, "."));
			if (sd != null) for (sp in sd) add(sp);
		}
		function walk(e:TExpr):Void {
			switch (e.expr) {
				case TField(_, FStatic(c, _)) | TField(_, FInstance(c, _, _)): add(c.path);
				case TField(_, FClosure(cwp, _)) if (cwp != null): add(cwp.c.path);
				case TTypeExpr(TClassDecl(c)): add(c.path);
				case TNew(c, _, _): add(c.path);
				case _:
			}
			hxc.core.TexprTools.iter(walk, e);
		}
		if (com.main != null) walk(com.main);
		paths.sort(function(a, b) return Reflect.compare(CppGenClass.joinPath(a, "/"), CppGenClass.joinPath(b, "/")));
		return paths;
	}

	// The debugger's file + class tables (empty unless HXCPP_DEBUGGER). __hxcpp_all_files is the sorted set
	// of stripped source files touched by stack frames; _fullpath is each one's absolute path; and
	// __hxcpp_all_classes is every non-extern, non-interface class in com.types order.
	static function genFiles(com:Context, base:String, sourceExtension:String):Void {
		var b = new StringBuf();
		b.add("#include <hxcpp.h>\n\n");
		b.add("namespace hx {\n");
		var keys = [for (k in CppGenClass.fileInfo.keys()) k];
		keys.sort(Reflect.compare);
		b.add("const char *__hxcpp_all_files[] = {\n");
		b.add("#ifdef HXCPP_DEBUGGER\n");
		for (k in keys) b.add(CppGenClass.constCharStar(k) + ",\n");
		b.add("#endif\n 0 };\n\n");
		b.add("const char *__hxcpp_all_files_fullpath[] = {\n");
		b.add("#ifdef HXCPP_DEBUGGER\n");
		var platformExt = "." + hxc.core.Globals.platformName(com.platform);
		for (k in keys) {
			// Each name resolves through the classpath search first; an unresolvable name (e.g. a
			// macro-made position file) absolutizes as-is against the cwd.
			// A PLATFORM-SPECIFIC file (`X.<platform>.hx`) is cached under its stripped representation
			// (`X.hx`), never under its literal name, so the classpath search cannot resolve the literal
			// path and it absolutizes against the cwd like any unresolvable name.
			var noExt = haxe.io.Path.withoutExtension(k);
			var isPlatformSpecific = haxe.io.Path.extension(k) == "hx"
				&& noExt.length > platformExt.length && noExt.substr(noExt.length - platformExt.length) == platformExt;
			var resolved = k;
			if (!isPlatformSpecific) for (dir in com.classPath) {
				var candidate = (dir == "" ? "" : (StringTools.endsWith(dir, "/") || StringTools.endsWith(dir, "\\") ? dir : dir + "/")) + k;
				if (sys.FileSystem.exists(candidate) && !sys.FileSystem.isDirectory(candidate)) { resolved = candidate; break; }
			}
			var full = try sys.FileSystem.fullPath(resolved) catch (_:Dynamic) resolved;
			b.add(CppGenClass.constCharStar(full) + ",\n");
		}
		b.add("#endif\n 0 };\n\n");
		b.add("const char *__hxcpp_all_classes[] = {\n");
		b.add("#ifdef HXCPP_DEBUGGER\n");
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (!CppTypeOf.isExternClass(c) && !TypeFunctions.hasClassFlag(c, CInterface)):
				b.add(CppGenClass.constCharStar(CppGenClass.joinPath(c.path, ".")) + ",\n");
			case _:
		}
		b.add("#endif\n 0 };\n");
		b.add("} // namespace hx\n");
		b.add("void __files__boot() { __hxcpp_set_debugger_info(::hx::__hxcpp_all_classes, ::hx::__hxcpp_all_files_fullpath); }\n");
		writeSourceFile(com, base + "/src/__files__" + sourceExtension, b.toString());
	}

	// Each embedded resource becomes a src/resources/__res_N.cpp byte blob (a 4-byte header then the data
	// then a null), and __resources__.cpp declares them extern and lists them in the __Resources table
	// (name, length, blob+4). With no resource the table is just the terminator.
	static function genResources(com:Context, base:String, sourceExtension:String):Void {
		// The resources live in a hash table and every resource pass walks it in bucket order, so the
		// __res_N index assignment follows the bucket walk over the resource names, not insertion order.
		var names = {
			var h = new hxc.core.NameHash.HashTableOrder();
			for (n in com.resourceOrder) h.add(n, hxc.core.NameHash.NameHash.stringHash(n));
			h.visitOrder();
		};
		// One data blob per resource.
		if (names.length > 0) ensureDir(base + "/src/resources");
		for (idx in 0...names.length) {
			var data = com.resources.get(names[idx]);
			var id = "__res_" + idx;
			var rb = new StringBuf();
			rb.add("namespace hx {\n");
			rb.add("unsigned char " + id + "[] = {\n");
			rb.add("0x80, 0x00, 0x00, 0x80,\n");
			for (i in 0...data.length) {
				rb.add(data.get(i) + ",");
				if (i % 10 == 9) rb.add("\n");
			}
			rb.add("0x00 };\n");
			rb.add("}\n");
			writeSourceFile(com, base + "/src/resources/" + id + sourceExtension, rb.toString());
		}
		var smartStrings = com.defines.rawDefined("hxcpp_smart_strings");
		var b = new StringBuf();
		b.add("#include <hxcpp.h>\n\n");
		b.add("namespace hx {\n");
		for (idx in 0...names.length) b.add("extern unsigned char __res_" + idx + "[];\n");
		b.add("}\n\n");
		b.add("::hx::Resource __Resources[] = {\n");
		for (idx in 0...names.length)
			b.add("\t{ " + CppTypeText.strq(smartStrings, names[idx]) + "," + com.resources.get(names[idx]).length + ",::hx::__res_" + idx + " + 4 },\n");
		b.add("\t{ ::String(null()),0,0 }\n};\n\n");
		b.add("namespace hx { Resource *GetResources() { return __Resources; } }\n");
		writeSourceFile(com, base + "/src/__resources__" + sourceExtension, b.toString());
	}

	// Write the generated class and source-file list for scriptable and DLL builds.
	static function genExportClassesInfo(com:Context, exeClasses:Array<{path:Path, deps:Array<Path>, mt:ModuleType}>):Void {
		if (!com.defines.rawDefined("scriptable") && !com.defines.rawDefined("dll_export")) return;
		var filename = com.defines.rawDefinedValueSafe("dll_export", "export_classes.info");
		if (filename == "1") filename = "export_classes.info";
		if (filename == "") return;
		function escape(s:String):String {
			return StringTools.replace(StringTools.replace(StringTools.replace(s, "\\", "\\\\"), " ", "\\s"), "\n", "\\n");
		}
		function fullPath(file:String):String {
			var resolved = file;
			if (!sys.FileSystem.exists(resolved) || sys.FileSystem.isDirectory(resolved)) {
				for (dir in com.classPath) {
					var candidate = dir + file;
					if (sys.FileSystem.exists(candidate) && !sys.FileSystem.isDirectory(candidate)) {
						resolved = candidate;
						break;
					}
				}
			}
			return try sys.FileSystem.fullPath(resolved) catch (_:Dynamic) file;
		}
		var b = new StringBuf();
		for (entry in exeClasses) switch (entry.mt) {
			case TClassDecl(c): b.add((TypeFunctions.hasClassFlag(c, CInterface) ? "interface " : "class ") + CppGenClass.joinPath(entry.path, ".") + "\n");
			case TEnumDecl(_): b.add("enum " + CppGenClass.joinPath(entry.path, ".") + "\n");
			case _:
		}
		var files = [for (file in CppGenClass.fileInfo.keys()) file];
		files.sort(Reflect.compare);
		for (file in files) if (file != "?") b.add("file " + escape(file) + " " + escape(fullPath(file)) + "\n");
		writeFile(filename, b.toString());
	}

	static function genBuildXml(com:Context, base:String, exeClasses:Array<{path:Path, deps:Array<Path>, mt:ModuleType}>, sourceExtension:String, externSrc:Array<String>):Void {
		var api = com.defines.rawDefinedValueSafe("hxcpp_api_level", "430");
		var exe = com.main != null ? mainClassName(com) : "output";
		var mainDeps = com.main != null ? mainRefs(com) : [];
		var b = new StringBuf();
		// One <file> per class, with a <depend> per non-internal dep
		function fileEntry(name:String, deps:Array<Path>, fileXml:String):Void {
			b.add("  <file name=\"src/" + name + sourceExtension + "\" ");
			if (fileXml != "") b.add(fileXml);
			b.add(">\n");
			for (p in deps)
				if (!CppTypeOf.isInternalClass(p))
					b.add("   <depend name=\"include/" + CppGenClass.joinPath(p, "/") + ".h\"/>\n");
			b.add("  </file>\n");
		}
		b.add("<xml>\n<set name=\"HXCPP_API_LEVEL\" value=\"" + api + "\" />\n");
		b.add("<files id=\"haxe\">\n<compilerflag value=\"-Iinclude\"/>\n");
		for (e in exeClasses) fileEntry(CppGenClass.joinPath(e.path, "/"), e.deps, "");
		// __boot__ depends on the boot enums + boot classes.
		fileEntry("__boot__", CppGenClass.bootEnums.concat(CppGenClass.bootClasses), "");
		fileEntry("__files__", [], "if='HXCPP_DEBUGGER'");
		b.add("   <file name=\"${HXCPP}/src/hx/NoFiles.cpp\" unless=\"HXCPP_DEBUGGER\" />\n");
		fileEntry("__resources__", [], "");
		b.add("</files>\n");
		b.add("<files id=\"__lib__\">\n<compilerflag value=\"-Iinclude\"/>\n");
		fileEntry("__lib__", mainDeps, "");
		b.add("</files>\n");
		b.add("<files id=\"__main__\">\n<compilerflag value=\"-Iinclude\"/>\n");
		fileEntry("__main__", mainDeps, "");
		b.add("</files>\n");
		b.add("<files id=\"__resources__\">\n");
		var resCount = [for (k in com.resources.keys()) k].length;
		for (idx in 0...resCount) b.add("  <file name=\"src/resources/__res_" + idx + sourceExtension + "\" />\n");
		b.add("</files>\n");
		b.add("<files id=\"__externs__\">\n");
		for (src in externSrc) b.add("<file name=\"" + src + "\" />\n");
		b.add("</files>\n");
		b.add("<set name=\"HAXE_OUTPUT\" value=\"" + exe + "\" />\n");
		b.add("<include name=\"${HXCPP}/build-tool/BuildCommon.xml\"/>\n");
		// The accumulated @:buildXml code (the std lib's Build.xml includes)
		b.add(CppGenClass.buildExtra);
		// The smart-strings guard error (emitted when -D hxcpp_smart_strings is set)
		if (com.defines.rawDefined("hxcpp_smart_strings"))
			b.add("<error value=\"Hxcpp is out of date - please update\" unlessApi=\"" + api + "\" />\n");
		b.add("</xml>\n");
		writeFile(base + "/Build.xml", b.toString());
	}

	// Options.txt: every define (sorted, minus a few internal ones) as name=value, then hxcpp=<first line
	// of `haxelib path hxcpp`>.
	static function genOptions(com:Context, base:String):Void {
		var skip = ["true", "sys", "dce", "cpp", "debug"];
		var names = [for (k in com.defines.values.keys()) k];
		// Byte-lexicographic key order (uppercase before lowercase)
		names.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
		var b = new StringBuf();
		for (name in names) {
			if (skip.indexOf(name) >= 0) continue;
			b.add(name + "=" + escapeCommand(com.defines.values.get(name)) + "\n");
		}
		var hxcpp = "";
		try {
			var p = new sys.io.Process("haxelib", ["path", "hxcpp"]);
			hxcpp = p.stdout.readLine();
			p.close();
		} catch (_:Dynamic) {}
		b.add("hxcpp=" + hxcpp + "\n");
		writeFile(base + "/Options.txt", b.toString());
	}

	static function escapeCommand(s:String):String {
		if (s == null) return "";
		return s.split("\\").join("\\\\").split("\"").join("\\\"");
	}

	// The exe name is the main class's own name (com.mainClass), not the first type referenced from the
	// main block.
	static function mainClassName(com:Context):String {
		return com.mainClass != null ? com.mainClass.name : "output";
	}

	static function ensureDir(dir:String):Void {
		if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
	}

	static function dirOf(relPath:String):String {
		var i = relPath.lastIndexOf("/");
		return i < 0 ? "" : relPath.substr(0, i);
	}

	static function writeFile(path:String, content:String):Void {
		// Match the host oracle: the emitter only ever writes "\n", so a blanket split/join produces no
		// double-CR.
		if (Sys.systemName() == "Windows") content = content.split("\n").join("\r\n");
		sys.io.File.saveContent(path, content);
	}

	static function writeSourceFile(com:Context, path:String, content:String):Void {
		var sourceHeader = com.defines.rawDefinedValueSafe("source_header", "");
		if (sourceHeader != "") content = "// " + sourceHeader + "\n" + content;
		writeFile(path, content);
	}
}
