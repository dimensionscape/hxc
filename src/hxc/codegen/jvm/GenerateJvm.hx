package hxc.codegen.jvm;

import haxe.ds.StringMap;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.codegen.jvm.JvmBuilder.AnnotationKind;
import hxc.codegen.jvm.JvmOutput;
import hxc.codegen.jvm.JvmFunctions;
import hxc.core.Type;
import hxc.core.TexprTools;
import hxc.core.TypeFunctions;
import hxc.codegen.GenShared;
import hxc.codegen.jvm.GenJvm;
import hxc.codegen.jvm.JvmSignature;
import hxc.codegen.jvm.JvmSignature.JSignature;
import hxc.codegen.jvm.JvmSignature.JPath;
import hxc.codegen.jvm.JvmSignature.NativeSignatures;
import hxc.codegen.jvm.JvmData.JCmp;
import hxc.codegen.jvm.JvmClass.ClassBuilder;
import hxc.codegen.jvm.JvmMethod;
import hxc.codegen.jvm.JvmMethod.MethodBuilder;
import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmGlobals.MethodAccessFlags;
import hxc.codegen.jvm.JvmGlobals.FieldAccessFlags;
import hxc.codegen.jvm.TclassToJvm.DynamicAccess;
import hxc.codegen.jvm.TclassToJvm.GenerateClass;

// Enum generation, the anonymous structure classes, and the generate entry point of the JVM target.

class GenerateJvm {
	// the equals a generated enum constructor carries. Each field is compared in turn and any mismatch
	// returns false immediately.
	static function generateEnumEquals(gctx:GenerationContext, jcCtor:ClassBuilder)
			:{jm:MethodBuilder, compareField:String->JSignature->Void} {
		var r = FieldClosure.generateEqualsFunction(jcCtor,
			NativeSignatures.haxeEnumSig(NativeSignatures.objectSig));
		var jmEquals = r.jm;
		var code = jmEquals.getCode();
		var handler = new TexprToJvm(gctx, null, jcCtor, jmEquals, TBool);
		function isHaxeEnum(jsig:JSignature):Bool {
			return switch (jsig) {
				case TObject(path, _): gctx.enumPaths.exists(Globals.sTypePath(new Path(path.pack, path.name)));
				case _: false;
			}
		}
		function bailIfNotEqual() {
			jmEquals.ifThen(function(rf) code.if_(CmpNe, rf), function() {
				code.bconst(false);
				jmEquals.returnOp();
			});
		}
		function compare(jsig:JSignature) {
			if (NativeSignatures.isDynamicAtRuntime(jsig)) {
				// a Dynamic field could hold an enum, so the runtime has to decide
				jmEquals.invokestatic(NativeSignatures.haxeJvmPath, "maybeEnumEq",
					NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.objectSig], TBool));
				bailIfNotEqual();
			} else if (isHaxeEnum(jsig)) {
				jmEquals.invokestatic(NativeSignatures.haxeTypePath, "enumEq",
					NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.objectSig], TBool));
				bailIfNotEqual();
			} else {
				jmEquals.ifThen(handler.applyCmp(handler.doCompare(CmpNe)), function() {
					code.bconst(false);
					jmEquals.returnOp();
				});
			}
		}
		r.load();
		jmEquals.invokevirtual(NativeSignatures.javaEnumPath, "ordinal",
			NativeSignatures.methodSig([], TInt));
		jmEquals.loadThis();
		jmEquals.invokevirtual(NativeSignatures.javaEnumPath, "ordinal",
			NativeSignatures.methodSig([], TInt));
		compare(TInt);
		function compareField(n:String, jsig:JSignature) {
			r.load();
			jmEquals.getfield(jcCtor.getThisPath(), n, jsig);
			jmEquals.loadThis();
			jmEquals.getfield(jcCtor.getThisPath(), n, jsig);
			compare(jsig);
		}
		return {jm: jmEquals, compareField: compareField};
	}

	// an enum becomes an abstract base class plus one final inner class per constructor. An argumentless
	// constructor also gets a static instance.
	public static function generateEnum(gctx:GenerationContext, en:TEnum):Void {
		var jcEnum = new ClassBuilder(en.path, NativeSignatures.haxeEnumPath);
		jcEnum.addAccessFlag(0x1); // public
		jcEnum.addAccessFlag(0x400); // abstract
		if (TypeFunctions.hasMeta(":jvm.synthetic", en.meta)) jcEnum.addAccessFlag(0x1000); // synthetic
		var jsigEnumCtor = NativeSignatures.methodSig([TInt, NativeSignatures.stringSig], null);
		{
			var jmCtor = jcEnum.spawnMethod("<init>", jsigEnumCtor, [MethodAccessFlags.MProtected]);
			jmCtor.loadThis();
			var l1 = jmCtor.addLocal("index", TInt, VarArgument);
			var l2 = jmCtor.addLocal("name", NativeSignatures.stringSig, VarArgument);
			l1.load();
			l2.load();
			jmCtor.callSuperCtor(ConstructInit, jsigEnumCtor);
			jmCtor.returnOp();
		}
		var inits = [];
		var names = [];
		for (name in en.names) {
			var ef = en.constrs.get(name);
			var args = switch (GenJvm.follow(ef.type)) {
				case TFun(sig): [for (a in sig.args) {name: a.name, jsig: GenJvm.jsignatureOfType(gctx, a.t)}];
				case _: [];
			};
			var jsigs = [for (a in args) a.jsig];
			var jcCtor = jcEnum.spawnInnerClass(null, jcEnum.getThisPath(), ef.name);
			jcCtor.addAccessFlag(0x10); // final
			{
				var jsigMethod = NativeSignatures.methodSig(jsigs, null);
				var jmCtor = jcCtor.spawnMethod("<init>", jsigMethod, [MethodAccessFlags.MPublic]);
				jmCtor.loadThis();
				jmCtor.getCode().iconst(ef.index);
				jmCtor.string(ef.name);
				jmCtor.callSuperCtor(ConstructInit, jsigEnumCtor);
				for (a in args)
					jmCtor.addArgumentAndField(a.name, a.jsig,
						[FieldAccessFlags.FdPublic, FieldAccessFlags.FdFinal]);
				jmCtor.returnOp();
			}
			jcCtor.addAnnotation({pack: ["haxe", "jvm", "annotation"], name: "EnumValueReflectionInformation"},
				[{name: "argumentNames", kind: AArray([for (a in args) AString(a.name)])}]);
			if (args.length != 0) {
				var jmParams = jcCtor.spawnMethod("_hx_getParameters",
					NativeSignatures.methodSig([], NativeSignatures.arraySig(NativeSignatures.objectSig)),
					[MethodAccessFlags.MPublic, MethodAccessFlags.MSynthetic]);
				var eq = generateEnumEquals(gctx, jcCtor);
				var fl = [
					for (a in args) {
						eq.compareField(a.name, a.jsig);
						function() {
							jmParams.loadThis();
							jmParams.getfield(jcCtor.getThisPath(), a.name, a.jsig);
							jmParams.castTo(NativeSignatures.objectSig);
						};
					}
				];
				eq.jm.getCode().bconst(true);
				eq.jm.returnOp();
				jmParams.newNativeArray(NativeSignatures.objectSig, fl);
				jmParams.returnOp();
			}
			GenJvm.writeClass(gctx, jcCtor.getThisPath(), jcCtor.exportClass(gctx.defaultExportConfig));
			if (args.length == 0) {
				var jmStatic = jcEnum.spawnField(ef.name, jcEnum.getJsig(),
					[FieldAccessFlags.FdPublic, FieldAccessFlags.FdStatic, FieldAccessFlags.FdFinal,
						FieldAccessFlags.FdEnum]);
				inits.push({jmStatic: jmStatic, jcCtor: jcCtor});
			} else {
				var jsigStatic = NativeSignatures.methodSig(jsigs, jcEnum.getJsig());
				var jmStatic = jcEnum.spawnMethod(ef.name, jsigStatic,
					[MethodAccessFlags.MPublic, MethodAccessFlags.MStatic]);
				jmStatic.construct(ConstructInit, jcCtor.getThisPath(), function() {
					for (a in args) jmStatic.addLocal(a.name, a.jsig, VarArgument).load();
					return jsigs;
				});
				jmStatic.returnOp();
			}
			names.push(AString(name));
		}
		if (inits.length > 0) {
			// Assign static fields for ctors without args
			var jmClinit = jcEnum.spawnMethod("<clinit>", NativeSignatures.methodSig([], null),
				[MethodAccessFlags.MStatic]);
			var jmValues = jcEnum.spawnMethod("values",
				NativeSignatures.methodSig([],
					NativeSignatures.arraySig(NativeSignatures.objectPathSig(jcEnum.getThisPath()))),
				[MethodAccessFlags.MPublic, MethodAccessFlags.MStatic]);
			var fl = [
				for (i in inits) {
					jmClinit.construct(ConstructInit, i.jcCtor.getThisPath(), function() return []);
					jmClinit.putstatic(jcEnum.getThisPath(), i.jmStatic.getName(), i.jmStatic.getJsig());
					function() jmValues.getstatic(jcEnum.getThisPath(), i.jmStatic.getName(),
						i.jmStatic.getJsig());
				}
			];
			jmValues.newNativeArray(NativeSignatures.objectPathSig(jcEnum.getThisPath()), fl);
			jmValues.returnOp();
			// __meta__ holds the enum's run-time metadata. TODO: do this via annotations instead?
			switch (TexprTools.buildMetadata(gctx.com.basic, TEnumDecl(en))) {
				case null:
				case e:
					jcEnum.spawnField("__meta__", NativeSignatures.objectSig,
						[FieldAccessFlags.FdStatic, FieldAccessFlags.FdPublic]);
					var handler = new TexprToJvm(gctx, null, jcEnum, jmClinit, null);
					handler.texpr(RValue(null, null), e);
					jmClinit.putstatic(jcEnum.getThisPath(), "__meta__", NativeSignatures.objectSig);
			}
			jmClinit.returnOp();
		}
		AnnotationHandler.generateAnnotations(jcEnum, en.meta);
		jcEnum.addAnnotation({pack: ["haxe", "jvm", "annotation"], name: "EnumReflectionInformation"},
			[{name: "constructorNames", kind: AArray(names)}]);
		GenJvm.writeClass(gctx, en.path, jcEnum.exportClass(gctx.defaultExportConfig));
	}

	public static function generateModuleType(gctx:GenerationContext, mt:ModuleType):Void {
		switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern)):
				GenerateClass.generateClass(gctx, c);
			case TEnumDecl(en) if (!en.isExtern):
				generateEnum(gctx, en);
			case _:
		}
	}

	// one class per distinct anonymous structure shape
	public static function generateAnons(gctx:GenerationContext):Void {
		var keys = gctx.anonIdentification.pfmKeysInHashtblOrder();
		for (k in keys) {
			var pfm = gctx.anonIdentification.getPfms.get(k);
			var path = pfm.pfmPath;
			var fields = [
				for (f in GenJvm.convertFields(gctx, pfm)) {name: f.name, jsig: (f.sig : JSignature)}
			];
			var jc = new ClassBuilder(new Path(path.pack, path.name),
				NativeSignatures.haxeDynamicObjectPath);
			jc.addAccessFlag(0x1);
			{
				var jmCtor = jc.spawnMethod("<init>",
					NativeSignatures.methodSig([for (f in fields) f.jsig], null),
					[MethodAccessFlags.MPublic]);
				jmCtor.loadThis();
				jmCtor.getCode().aconstNull(NativeSignatures.haxeEmptyConstructorSig);
				jmCtor.callSuperCtor(ConstructInit,
					NativeSignatures.methodSig([NativeSignatures.haxeEmptyConstructorSig], null));
				for (f in fields) jmCtor.addArgumentAndField(f.name, f.jsig, [FieldAccessFlags.FdPublic]);
				jmCtor.returnOp();
			}
			{
				var stringMapPath:JPath = {pack: ["haxe", "ds"], name: "StringMap"};
				var stringMapSig = NativeSignatures.objectPathSig(stringMapPath);
				var jmFields = jc.spawnMethod("_hx_getKnownFields",
					NativeSignatures.methodSig([], stringMapSig),
					[MethodAccessFlags.MProtected, MethodAccessFlags.MSynthetic]);
				var acc = jmFields.addLocal("tmp", stringMapSig, VarWillInit);
				jmFields.construct(ConstructInit, stringMapPath, function() return []);
				acc.store();
				for (f in fields) {
					acc.load();
					jmFields.getCode().sconst(NativeSignatures.stringSig,
						jc.getPool().addConstString(f.name));
					jmFields.loadThis();
					jmFields.getfield(jc.getThisPath(), f.name, f.jsig);
					jmFields.expectReferenceType();
					jmFields.invokevirtual(stringMapPath, "set",
						NativeSignatures.methodSig([NativeSignatures.stringSig, NativeSignatures.objectSig],
							null));
				}
				acc.load();
				jmFields.returnOp();
			}
			// This has to run even with dynamicLevel = 0 because the entire DynamicObject logic
			// depends on it.
			DynamicAccess.generate(gctx, jc, [
				for (f in fields)
					{name: f.name, jsig: f.jsig, kind: FieldKind.Var(new VarKind(AccNormal, AccNormal))}
			], true);
			switch (gctx.typedefInterfaces.getInterfaceClass(path)) {
				case null:
				case c:
					jc.addInterface(c.path, []);
					for (cf in c.orderedFields) {
						var jsigCf = GenJvm.jsignatureOfType(gctx, cf.type);
						var jm = jc.spawnMethod(cf.name, jsigCf, [MethodAccessFlags.MPublic]);
						var sig = switch (GenJvm.follow(cf.type)) {
							case TFun(s): s;
							case _: throw "die";
						};
						var locals = [
							for (a in sig.args) {
								var jsig = GenJvm.jsignatureOfType(gctx, a.t);
								{acc: jm.addLocal(a.name, jsig, VarArgument), jsig: jsig};
							}
						];
						jm.finalizeArguments();
						jm.loadThis();
						jm.getfield({pack: path.pack, name: path.name}, cf.name, jsigCf);
						for (l in locals) l.acc.load();
						var jret = GenJvm.returnOfType(gctx, sig.ret);
						var meth = gctx.typedFunctions.registerSignature([for (l in locals) l.jsig], jret);
						jm.invokevirtual(NativeSignatures.haxeFunctionPath, meth.name,
							NativeSignatures.methodSig(meth.dargs, meth.dret));
						if (jret != null) jm.castTo(jret);
						jm.returnOp();
					}
			}
			GenJvm.writeClass(gctx, new Path(path.pack, path.name),
				jc.exportClass(gctx.defaultExportConfig));
		}
	}

	public static function generateTypedFunctions(gctx:GenerationContext):Void {
		for (jc in [gctx.typedFunctions.generate(), gctx.typedFunctions.generateVarArgs(),
			gctx.typedFunctions.generateClosureDispatch()])
			GenJvm.writeClass(gctx, new Path(jc.getThisPath().pack, jc.getThisPath().name),
				jc.exportClass(gctx.defaultExportConfig));
	}

	static function getEntryPoint(com:Context):Null<{name:String, c:TClass, e:TExpr}> {
		if (com.mainClass == null || com.main == null) return null;
		var path = com.mainClass;
		var m = null;
		for (m2 in com.modules) if (Globals.sTypePath(m2.path) == Globals.sTypePath(path)) {
			m = m2;
			break;
		}
		if (m == null) return null;
		var c = null;
		if (m.statics != null && m.statics.statics.exists("main")) c = m.statics;
		else for (t in m.types) switch (t) {
			case TClassDecl(c2) if (Globals.sTypePath(c2.path) == Globals.sTypePath(path)):
				c = c2;
				break;
			case _:
		}
		if (c == null) return null;
		return {name: path.name, c: c, e: com.main};
	}

	public static function generate(jvmFlag:Bool, com:Context):Void {
		var ep = getEntryPoint(com);
		var jarName = ep == null ? "jar" : ep.name;
		var entryPoint = ep == null ? null : {c: ep.c, e: ep.e};
		var compressionLevel = 6;
		var cl = (com.defines.rawDefined("jvm.compression_level") ? com.defines.rawDefinedValue("jvm.compression_level") : null);
		if (cl != null) {
			var v = Std.parseInt(cl);
			if (v != null) compressionLevel = v;
		}
		if (compressionLevel < 0 || compressionLevel > 9)
			throw "Invalid value for -D jvm.compression-level: Must be >=0 and <= 9";
		function createJar(path:String):JvmOutput return new JarOutput(path, compressionLevel);
		var outDir:String;
		var out:JvmOutput;
		if (jvmFlag) {
			var file = com.file.split("\\").join("/");
			var idx = file.lastIndexOf("/");
			var fileName = idx < 0 ? file : file.substr(idx + 1);
			var directory = idx < 0 ? null : file.substr(0, idx);
			if (fileName != "") {
				if (directory == null) {
					outDir = "./";
					out = createJar("./" + com.file);
				} else {
					mkdirFromPath(directory + "/");
					outDir = directory + "/";
					out = createJar(com.file);
				}
			} else if (directory != null) {
				outDir = directory + "/";
				out = new FileOutput(outDir);
			} else {
				throw "Please specify an output file name";
			}
		} else {
			var jn = com.debug ? jarName + "-Debug" : jarName;
			var jarDir = com.file + (StringTools.endsWith(com.file, "/") ? "" : "/");
			outDir = jarDir;
			out = createJar(jarDir + jn + ".jar");
		}
		var anonIdentification = new TanonIdentification(new Path(NativeSignatures.haxeDynamicObjectPath.pack, NativeSignatures.haxeDynamicObjectPath.name));
		var dynamicLevel = 1;
		var dl = (com.defines.rawDefined("jvm.dynamic_level") ? com.defines.rawDefinedValue("jvm.dynamic_level") : null);
		if (dl != null) {
			var v = Std.parseInt(dl);
			if (v != null) dynamicLevel = v;
		}
		if (dynamicLevel < 0 || dynamicLevel > 2)
			throw "Invalid value for -D jvm.dynamic-level: Must be >=0 and <= 2";
		var gctx = new GenerationContext();
		gctx.com = com;
		gctx.out = out;
		gctx.runtimeException = TInst(GenJvm.resolveClass(com,
			new Path(["java", "lang"], "RuntimeException")), []);
		gctx.entryPoint = entryPoint;
		gctx.exception = TInst(GenJvm.resolveClass(com, new Path(["java", "lang"], "Exception")), []);
		gctx.throwable = TInst(GenJvm.resolveClass(com, new Path(["java", "lang"], "Throwable")), []);
		gctx.anonIdentification = anonIdentification;
		gctx.typedFunctions = new JvmFunctions.TypedFunctions();
		gctx.closurePaths = new StringMap();
		gctx.enumPaths = new StringMap();
		gctx.defaultExportConfig = {exportDebug: true};
		gctx.detailTimes = com.defines.rawDefined("jvm_times");
		gctx.jarCompressionLevel = compressionLevel;
		gctx.dynamicLevel = dynamicLevel;
		// The preprocessor keys implicitCtors on this rendering of a constructor's type, so it must tell
		// constructor overloads apart. generateSignature renders every TMethod as Lhaxe/jvm/Function; (a
		// method type is a function object at run time), which would put every overload of an inherited
		// constructor, such as new(Float) and new(Bytes), under one key and leave the class a single
		// inherited <init>. The method signature distinguishes them.
		gctx.preprocessor = new Preprocessor(com.basic,
			function(t) return JvmSignature.generateMethodSignature(true, GenJvm.jsignatureOfType(gctx, t)));
		gctx.typedefInterfaces = new TypedefInterfaces(gctx.preprocessor.getInfos, anonIdentification);
		gctx.typedefInterfaces.addInterfaceRewrite(new Path(["haxe", "root"], "Iterator"),
			new Path(["java", "util"], "Iterator"), true);
		// a non-std java lib is copied next to the jar and named on its Class-Path
		var classPaths = [];
		for (lib in com.javaLibs) {
			if (lib.isStd || lib.isExtern) continue;
			var dir = outDir + "lib/";
			mkdirFromPath(dir + "x");
			var p = lib.filePath.split("\\").join("/");
			var name = p.substr(p.lastIndexOf("/") + 1);
			sys.io.File.saveBytes(dir + name, sys.io.File.getBytes(lib.filePath));
			classPaths.push("lib/" + name + " \n");
		}
		// resources go into the jar in hash-table bucket order (see HashTableOrder), not in the order they
		// were added
		for (name in com.resourceFoldOrder())
			gctx.out.addEntry(com.resources.get(name), escapeResName(name, true));
		JvmPreprocessor.preprocess(gctx);
		for (mt in com.types) generateModuleType(gctx, mt);
		for (c in typedefInterfaceClasses(gctx)) generateModuleType(gctx, TClassDecl(c));
		generateAnons(gctx);
		generateTypedFunctions(gctx);
		var manifestContent = "Manifest-Version: 1.0\n"
			+ "Created-By: Haxe (Haxe Foundation)"
			+ (entryPoint == null ? "" : "\nMain-Class: " + Globals.sTypePath(entryPoint.c.path))
			+ (classPaths.length == 0 ? "" : "\nClass-Path: " + classPaths.join(" "))
			+ "\n\n";
		gctx.out.addEntry(haxe.io.Bytes.ofString(manifestContent), "META-INF/MANIFEST.MF");
		gctx.out.close();
	}

	static function typedefInterfaceClasses(gctx:GenerationContext):Array<TClass> {
		// The $Interface classes are generated in hash-table bucket order, which decides their position in
		// the jar.
		var keys = gctx.typedefInterfaces.interfaceKeysInHashtblOrder();
		return [for (k in keys) gctx.typedefInterfaces.getInterfaces.get(k)];
	}

	/**
		The passthrough set is exactly a-z A-Z 0-9 _ and dot. `-` is NOT in it: it leads the escape itself,
		so a literal one is escaped as well. With allowDirs, `/` also passes through, so the resource lands
		in a directory inside the jar.

		The name is escaped byte by byte, so a non-ASCII name escapes one -xNNN per byte.
	**/
	static function escapeResName(name:String, allowDirs:Bool):String {
		var buf = new StringBuf();
		var b = haxe.io.Bytes.ofString(name);
		for (i in 0...b.length) {
			var code = b.get(i);
			if ((code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code)
				|| (code >= "0".code && code <= "9".code) || code == "_".code || code == ".".code)
				buf.addChar(code);
			else if (code == "/".code && allowDirs)
				buf.addChar(code);
			else
				buf.add("-x" + code);
		}
		return buf.toString();
	}

	static function mkdirFromPath(file:String):Void {
		var norm = file.split("\\").join("/");
		var idx = norm.lastIndexOf("/");
		if (idx <= 0) return;
		var dir = norm.substr(0, idx);
		if (dir != "" && !sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
	}
}
