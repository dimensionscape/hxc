package hxc.codegen.jvm;

import haxe.ds.StringMap;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TexprTools;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.codegen.GenShared;
import hxc.codegen.jvm.GenJvm;
import hxc.codegen.jvm.JvmSignature;
import hxc.codegen.jvm.JvmSignature.JSignature;
import hxc.codegen.jvm.JvmSignature.JPath;
import hxc.codegen.jvm.JvmSignature.NativeSignatures;
import hxc.codegen.jvm.JvmClass.ClassBuilder;
import hxc.codegen.jvm.JvmMethod;
import hxc.codegen.jvm.JvmMethod.MethodBuilder;
import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmGlobals.MethodAccessFlags;
import hxc.codegen.jvm.JvmAttribute;
import hxc.codegen.jvm.JvmBuilder;
import hxc.codegen.OverloadResolution;
import hxc.codegen.jvm.JvmGlobals.FieldAccessFlags;

// The class-level generation: the reflective accessors a class needs so Reflect.field and Reflect.setField
// reach its real fields, and the class builder itself.

typedef DynamicField = {name:String, jsig:JSignature, kind:hxc.core.Type.FieldKind};

class DynamicAccess {
	// _hx_getField dispatches on the field name, _hx_setField on its hash. Both fall through to the super
	// implementation for anything not declared here.
	public static function generate(gctx:GenerationContext, jc:ClassBuilder, fields:Array<DynamicField>,
			isAnon:Bool):Void {
		if (fields.length != 0) {
			var jsig = NativeSignatures.methodSig([NativeSignatures.stringSig], NativeSignatures.objectSig);
			var jm = jc.spawnMethod("_hx_getField", jsig, [MethodAccessFlags.MPublic,
				MethodAccessFlags.MSynthetic]);
			var acc = jm.addLocal("name", NativeSignatures.stringSig, VarArgument);
			jm.finalizeArguments();
			var cases = [
				for (f in fields) {
					values: [f.name],
					f: function() {
						switch [f.kind, f.jsig] {
							case [Method(MethNormal) | Method(MethInline), TMethod(args, _)]:
								if (gctx.dynamicLevel >= 2) {
									FieldClosure.createFieldClosure(gctx, jc, jc.getThisPath(), jm, f.name,
										f.jsig, function() jm.loadThis());
								} else {
									// The cheaper form: pass the argument classes to Jvm.readFieldClosure
									// and let the runtime build the
									// closure.
									jm.loadThis();
									jm.string(f.name);
									jm.newNativeArray(NativeSignatures.javaClassSig,
										[for (a in args) function() jm.getClass(a)]);
									jm.invokestatic(NativeSignatures.haxeJvmPath, "readFieldClosure",
										NativeSignatures.methodSig([NativeSignatures.objectSig,
											NativeSignatures.stringSig,
											NativeSignatures.arraySig(NativeSignatures.javaClassSig)],
											NativeSignatures.objectSig));
								}
							case _:
								jm.loadThis();
								jm.getfield(jc.getThisPath(), f.name, f.jsig);
								jm.expectReferenceType();
						}
						jm.replaceTop(NativeSignatures.objectSig);
					}
				}
			];
			var def = function() {
				jm.loadThis();
				acc.load();
				jm.invokespecial(jc.getSuperPath(), "_hx_getField", jsig);
			};
			jm.stringSwitch(true, acc.load, cases, def);
			jm.returnOp();
		}
		// A method or a never-writable var cannot be assigned through reflection at all.
		var wfields = [
			for (f in fields)
				if (switch (f.kind) {
					case Method(MethNormal) | Method(MethInline): false;
					case Var(a) if (a.write == AccNever): false;
					case _: true;
				}) f
		];
		if (wfields.length == 0) return;
		var jsig = NativeSignatures.methodSig([NativeSignatures.stringSig, NativeSignatures.objectSig], null);
		var jm = jc.spawnMethod("_hx_setField", jsig, [MethodAccessFlags.MPublic,
			MethodAccessFlags.MSynthetic]);
		var acc1 = jm.addLocal("name", NativeSignatures.stringSig, VarArgument);
		var acc2 = jm.addLocal("value", NativeSignatures.objectSig, VarArgument);
		jm.finalizeArguments();
		acc1.load();
		jm.invokevirtual(NativeSignatures.stringPath, "hashCode", NativeSignatures.methodSig([], TInt));
		var def = function() {
			jm.loadThis();
			acc1.load();
			acc2.load();
			jm.invokespecial(jc.getSuperPath(), "_hx_setField", jsig);
		};
		var cases = [
			for (f in wfields) {
				values: [MethodBuilder.javaHash(f.name)],
				f: function() {
					jm.loadThis();
					acc2.load();
					jm.castTo(f.jsig);
					jm.putfield(jc.getThisPath(), f.name, f.jsig);
					// For an anonymous object on which Reflect.deleteField has been used (_hx_deletedAField
					// is set), the
					// write is also passed on to the super implementation.
					if (isAnon) {
						jm.loadThis();
						jm.getfield(jc.getThisPath(), "_hx_deletedAField", NativeSignatures.booleanSig);
						jm.ifThen(function(r) jm.getCode().ifNull(NativeSignatures.booleanSig, r),
							function() def());
					}
				}
			}
		];
		jm.intSwitch(false, cases, def);
		jm.returnOp();
	}
}

enum SuperCtorMode {
	SCNone;
	SCJava;
	SCHaxe;
}

class TclassToJvm {
	var gctx:GenerationContext;
	var c:TClass;
	var isAnnotation:Bool;
	var fieldInits:Array<TExpr> = [];
	var delayedFieldInits:Array<TExpr> = [];
	var jc:ClassBuilder;

	public function new(gctx:GenerationContext, c:TClass) {
		this.gctx = gctx;
		this.c = c;
		isAnnotation = TypeFunctions.hasMeta(":annotation", c.meta);
		var superPath = switch (c.superClass) {
			case null:
				// A Haxe class without a parent extends haxe.jvm.Object, which carries the reflective
				// accessors;
				// interfaces and @:nativeGen classes extend java.lang.Object.
				(TypeFunctions.hasClassFlag(c, CInterface) || TypeFunctions.hasMeta(":nativeGen", c.meta))
					? NativeSignatures.objectPath : NativeSignatures.haxeObjectPath;
			case s: s.c.path;
		};
		jc = new ClassBuilder(c.path, superPath);
	}

	function setAccessFlags():Void {
		jc.addAccessFlag(1); // public
		if (TypeFunctions.hasClassFlag(c, CFinal)) jc.addAccessFlag(0x10);
		if (TypeFunctions.hasClassFlag(c, CInterface)) {
			jc.addAccessFlag(0x200);
			jc.addAccessFlag(0x400);
		}
		if (isAnnotation) {
			jc.addAccessFlag(0x2000);
			jc.addInterface({pack: ["java", "lang", "annotation"], name: "Annotation"}, []);
			jc.addAnnotation(NativeSignatures.retentionPath,
				[{name: "value", kind: AEnum(NativeSignatures.retentionPolicySig, "RUNTIME")}]);
		}
		if (TypeFunctions.hasClassFlag(c, CAbstract)) jc.addAccessFlag(0x400); // abstract
		if (TypeFunctions.hasMeta(":jvm.synthetic", c.meta)) jc.addAccessFlag(0x1000); // synthetic
	}

	// Where an override's signature differs from what the supertype declares, the JVM needs a bridge method
	// under the supertype's signature that forwards to the real one.
	function buildBridges():Void {
		function makeBridge(name:String, jsigFrom:JSignature, jsigTo:JSignature) {
			var from = switch (jsigFrom) {
				case TMethod(a, r): {args: a, ret: r};
				case _: throw "die";
			};
			var to = switch (jsigTo) {
				case TMethod(a, r): {args: a, ret: r};
				case _: throw "die";
			};
			var jm = jc.spawnMethod(name, jsigFrom, [MethodAccessFlags.MPublic,
				MethodAccessFlags.MSynthetic, MethodAccessFlags.MBridge]);
			gctx.typedFunctions.makeForwardMethodJsig(jc, jm, name, from.args, from.ret, to.args, to.ret);
		}
		function maybeMakeBridge(name:String, jsigFrom:JSignature, jsigTo:JSignature) {
			if (!jc.hasMethod(name, jsigFrom)) makeBridge(name, jsigFrom, jsigTo);
		}
		function compareFields(cfImpl:TClassField, cfSuper:TClassField) {
			var jsigSuper = GenJvm.jsignatureOfType(gctx, cfSuper.type);
			var jsigImpl = GenJvm.jsignatureOfType(gctx, cfImpl.type);
			if (!JvmSignature.eq(jsigSuper, jsigImpl))
				maybeMakeBridge(cfImpl.name, jsigSuper, jsigImpl);
		}
		function findOverload(mapType:T->T, c2:TClass, cf:TClassField) {
			var tl = switch (GenJvm.follow(mapType(cf.type))) {
				case TFun(sig): sig.args;
				case _: throw "die";
			};
			return OverloadResolution.resolveInstanceOverload(false, mapType, c2, cf.name,
				[for (a in tl) TexprTools.makeNull(a.t, Position.nullPos)]);
		}
		function ifMethod(f:TClassField->Void, cf:TClassField) {
			switch (cf.kind) {
				case Method(_):
					f(cf);
					for (cf2 in cf.overloads) f(cf2);
				case _:
			}
		}
		switch (c.superClass) {
			case null:
			case sup:
				var cSup = sup.c;
				var mapType = function(t) return TypeFunctions.applyParams(cSup.params, sup.params, t);
				function checkOverride(cf:TClassField) {
					if (TypeFunctions.hasClassFieldFlag(cf, CfOverload)) {
						switch (findOverload(mapType, cSup, cf)) {
							case null:
							case r: compareFields(cf, r.cf);
						}
					} else {
						var r = TypeFunctions.rawClassField(function(cf) return cf.type, cSup,
							TypeFunctions.extractParamTypes(cSup.params), cf.name);
						compareFields(cf, r.f);
					}
				}
				for (cf in c.orderedFields)
					ifMethod(function(cf) if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)) checkOverride(cf), cf);
		}
		function checkInterface(mapType:T->T, cw:TClassWithParams) {
			var cInt = cw.c;
			var mapType2 = function(t) return mapType(TypeFunctions.applyParams(cInt.params, cw.params, t));
			for (cf in cInt.orderedFields) ifMethod(function(cf) {
				switch (findOverload(mapType2, c, cf)) {
					case null:
					case r: compareFields(r.cf, cf);
				}
			}, cf);
			for (cw2 in cInt.interfaces) checkInterface(mapType2, cw2);
		}
		for (cw in c.interfaces) checkInterface(function(t) return t, cw);
	}

	function setInterfaces():Void {
		for (cw in c.interfaces) {
			if (isAnnotation && cw.c.path.pack.length == 3 && cw.c.path.name == "Annotation") continue;
			jc.addInterface(cw.c.path, [for (t in cw.params) GenJvm.jtypeArgumentOfTypeTop(gctx, t)]);
		}
	}

	// The EmptyConstructor overload, which lets a subclass be allocated without running any constructor
	// body.
	function generateEmptyCtor():Void {
		var jsigEmpty = NativeSignatures.methodSig([NativeSignatures.haxeEmptyConstructorSig], null);
		var jm = jc.spawnMethod("<init>", jsigEmpty, [MethodAccessFlags.MPublic,
			MethodAccessFlags.MSynthetic]);
		var acc = jm.addLocal("_", NativeSignatures.haxeEmptyConstructorSig, VarArgument);
		jm.loadThis();
		if (c.constructor == null) {
			var handler = new TexprToJvm(gctx, null, jc, jm, null);
			for (e in fieldInits) handler.texpr(RVoid, e);
		}
		switch (c.superClass) {
			case null:
				// Haxe type with no parent class, call Object.<init>()
				jm.callSuperCtor(ConstructInit, NativeSignatures.methodSig([], null));
			case _:
				// Parent class exists, call SuperClass.<init>(EmptyConstructor)
				acc.load();
				jm.callSuperCtor(ConstructInit, jsigEmpty);
		}
		if (c.constructor == null) {
			var handler = new TexprToJvm(gctx, null, jc, jm, null);
			for (e in delayedFieldInits) handler.texpr(RVoid, e);
		}
		jm.returnOp();
	}

	// The constructors a subclass has to carry because its superclass declares them.
	function generateImplicitCtors():Void {
		var sm = gctx.preprocessor.getImplicitCtor(c);
		var keys = [for (k in sm.keys()) k];
		keys.sort(Reflect.compare);
		for (k in keys) {
			var entry = sm.get(k);
			var cmode = GenJvm.getConstructionMode(entry.c, entry.cf);
			var jm = jc.spawnMethod(cmode == ConstructInit ? "<init>" : "new",
				GenJvm.jsignatureOfType(gctx, entry.cf.type), [MethodAccessFlags.MPublic]);
			var handler = new TexprToJvm(gctx, null, jc, jm, null);
			jm.loadThis();
			for (e in fieldInits) handler.texpr(RVoid, e);
			var tl = switch (GenJvm.follow(entry.cf.type)) {
				case TFun(sig): sig.args;
				case _: throw "die";
			};
			for (a in tl) jm.addLocal(a.name, GenJvm.jsignatureOfType(gctx, a.t), VarArgument).load();
			jm.callSuperCtor(cmode, jm.getJsig());
			for (e in delayedFieldInits) handler.texpr(RVoid, e);
			jm.returnOp();
		}
	}

	public function generateExpr(gctx:GenerationContext, fieldInfo:Null<FieldGenerationInfo>,
			jc:ClassBuilder, jm:MethodBuilder, e:TExpr, scmode:SuperCtorMode, mtype:MethodType):Void {
		var body = e;
		var args:Array<TFuncArg> = [];
		var tr:Null<JSignature> = null;
		switch (e.expr) {
			case TFunction(tf):
				body = tf.expr;
				args = tf.args;
				tr = GenJvm.returnOfType(gctx, tf.type);
			case _:
		}
		var handler = new TexprToJvm(gctx, fieldInfo, jc, jm, tr);
		for (a in args) {
			var slot = handler.addLocal(a.v, VarArgument).slot;
			var annot = AnnotationHandler.convertAnnotations(a.v.meta);
			if (annot.length != 0) jm.addArgumentAnnotation(slot, [for (a in annot) {path: a.path, annot: a.a}]);
		}
		jm.finalizeArguments();
		switch (mtype) {
			case MConstructor:
				for (e in fieldInits) handler.texpr(RVoid, e);
				switch (scmode) {
					case SCJava:
						handler.objectConstructor();
					case SCHaxe:
						jm.loadThis();
						jm.getCode().aconstNull(jc.getJsig());
						jm.callSuperCtor(ConstructInit,
							NativeSignatures.methodSig([NativeSignatures.haxeEmptyConstructorSig], null));
					case SCNone:
				}
				for (e in delayedFieldInits) handler.texpr(RVoid, e);
			case _:
		}
		handler.texpr(RReturn, body);
	}

	public function generateMethod(gctx:GenerationContext, jc:ClassBuilder, c:TClass, mtype:MethodType,
			cf:TClassField):Void {
		var jsig = GenJvm.jsignatureOfType(gctx, cf.type);
		var flags = TypeFunctions.hasMeta(":private", cf.meta) ? [MethodAccessFlags.MPrivate]
			: (TypeFunctions.hasMeta(":protected", cf.meta) ? [MethodAccessFlags.MProtected]
				: [MethodAccessFlags.MPublic]);
		if (TypeFunctions.hasClassFlag(c, CInterface)) flags = [MethodAccessFlags.MAbstract].concat(flags);
		if (mtype == MStatic) flags = [MethodAccessFlags.MStatic].concat(flags);
		if (TypeFunctions.hasClassFieldFlag(cf, CfFinal)) flags = [MethodAccessFlags.MFinal].concat(flags);
		if (TypeFunctions.hasMeta(":jvm.synthetic", cf.meta))
			flags = [MethodAccessFlags.MSynthetic].concat(flags);
		if (TypeFunctions.hasMeta(":native", cf.meta) && TypeFunctions.hasMeta(":jni", cf.meta))
			flags = [MethodAccessFlags.MNative].concat(flags);
		if (TypeFunctions.hasClassFieldFlag(cf, CfAbstract)) flags = [MethodAccessFlags.MAbstract].concat(flags);
		var name = cf.name;
		var scmode = SCNone;
		if (mtype == MConstructor) {
			function hasSuperCtor(c:TClass):Bool {
				return switch (c.superClass) {
					case null: false;
					case s: s.c.constructor != null || hasSuperCtor(s.c);
				}
			}
			if (GenJvm.getConstructionMode(c, cf) == ConstructInit) {
				name = "<init>";
				scmode = c.superClass == null ? SCJava : (!hasSuperCtor(c) ? SCHaxe : SCNone);
			}
		}
		var jm = jc.spawnMethod(name, jsig, flags);
		if (cf.expr != null)
			generateExpr(gctx, gctx.preprocessor.getFieldInfo(cf.meta), jc, jm, cf.expr, scmode, mtype);
		if (cf.params.length != 0 || c.params.length != 0) {
			var stl = [for (tp in cf.params) tp.name + ":Ljava/lang/Object;"].join("");
			var ssig = JvmSignature.generateMethodSignature(true, GenJvm.jsignatureOfType(gctx, cf.type));
			var s = cf.params.length == 0 ? ssig : "<" + stl + ">" + ssig;
			jm.addAttribute(AttributeSignature(jc.getPool().addString(s)));
		}
		AnnotationHandler.generateAnnotations(jm, cf.meta);
	}

	// A static initialized with a non-nullable Int or a String constant gets a ConstantValue attribute. Any
	// other static initializer is appended to the class init; an instance field initializer is collected to
	// run inside every constructor.
	public function generateField(gctx:GenerationContext, jc:ClassBuilder, c:TClass, mtype:MethodType,
			cf:TClassField):Void {
		var jsig = GenJvm.jsignatureOfType(gctx, cf.type);
		var flags = TypeFunctions.hasMeta(":private", cf.meta) ? [FieldAccessFlags.FdPrivate]
			: (TypeFunctions.hasMeta(":protected", cf.meta) ? [FieldAccessFlags.FdProtected]
				: [FieldAccessFlags.FdPublic]);
		if (mtype == MStatic) flags = [FieldAccessFlags.FdStatic].concat(flags);
		if (TypeFunctions.hasMeta(":jvm.synthetic", cf.meta))
			flags = [FieldAccessFlags.FdSynthetic].concat(flags);
		if (TypeFunctions.hasMeta(":volatile", cf.meta))
			flags = [FieldAccessFlags.FdVolatile].concat(flags);
		var jm = jc.spawnField(cf.name, jsig, flags);
		function def(e:TExpr) {
			var p = Position.nullPos;
			var efield = TexprTools.makeStaticField(c, cf, p);
			var eop = TypeFunctions.mk(TBinop(OpAssign, efield, e), cf.type, p);
			c.init = c.init == null ? eop : TypeFunctions.concat(c.init, eop);
		}
		if (cf.expr == null) {
			// haxe.Resource.content is filled in with the names of the embedded resources.
			if (c.path.pack.length == 1 && c.path.pack[0] == "haxe" && c.path.name == "Resource"
				&& cf.name == "content") {
				// The names are listed in the reverse of resourceFoldOrder (hash-table bucket order), not
				// in the
				// StringMap's own order.
				var el = [];
				for (name in gctx.com.resourceFoldOrder())
					el.unshift(TexprTools.makeString(gctx.com.basic, name, Position.nullPos));
				def(TypeFunctions.mk(TArrayDecl(el), gctx.com.basic.tarray(gctx.com.basic.tstring),
					Position.nullPos));
			}
		} else if (mtype != MStatic) {
			var tl = TypeFunctions.extractParamTypes(c.params);
			var ethis = TypeFunctions.mk(TConst(TThis), TInst(c, tl), Position.nullPos);
			var efield = TypeFunctions.mk(TField(ethis, FInstance(c, tl, cf)), cf.type, Position.nullPos);
			var eop = TypeFunctions.mk(TBinop(OpAssign, efield, cf.expr), cf.type, Position.nullPos);
			// A dynamic method has to be assigned AFTER the super call, the rest before it.
			switch (cf.kind) {
				case Method(MethDynamic): delayedFieldInits.push(eop);
				case _: fieldInits.push(eop);
			}
		} else {
			var handled = false;
			switch (cf.expr.expr) {
				case TConst(ct):
					switch (ct) {
						case TInt(i) if (!TypeFunctions.isNullable(cf.type)):
							jm.addAttribute(AttributeConstantValue(jc.getPool().add(ConstInt(i))));
							handled = true;
						case TString(s):
							jm.addAttribute(AttributeConstantValue(jc.getPool().addConstString(s)));
							handled = true;
						case _:
					}
				case _:
			}
			if (!handled) def(cf.expr);
		}
		// Object, array and type-parameter fields also get a Signature attribute with their generic
		// signature,
		// see https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html#jvms-4.3.4
		switch (jsig) {
			case TObject(_, _) | TArray(_, _) | TTypeParameter(_):
				jm.addAttribute(AttributeSignature(
					jc.getPool().addString(JvmSignature.generateSignature(true, jsig))));
			case _:
		}
		AnnotationHandler.generateAnnotations(jm, cf.meta);
	}

	public function generateMain(e:TExpr):Void {
		var jsig = NativeSignatures.methodSig([NativeSignatures.arraySig(NativeSignatures.stringSig)], null);
		var jm = jc.spawnMethod("main", jsig, [MethodAccessFlags.MPublic, MethodAccessFlags.MStatic]);
		var acc = jm.addLocal("args", TArray(NativeSignatures.stringSig, null), VarArgument);
		if (gctx.com.hasFeature("haxe.root.Sys.args")) {
			acc.load();
			jm.putstatic({pack: ["haxe", "root"], name: "Sys"}, "_args",
				TArray(NativeSignatures.stringSig, null));
		}
		jm.invokestatic({pack: ["haxe", "java"], name: "Init"}, "init",
			NativeSignatures.methodSig([], null));
		generateExpr(gctx, null, jc, jm, e, SCNone, MStatic);
		if (!jm.isTerminated()) jm.returnOp();
	}

	function generateFields():Void {
		function field(mtype:MethodType, cf:TClassField) {
			switch (cf.kind) {
				case Method(MethNormal) | Method(MethInline):
					// Only the overloads flagged CfOverload get their own method.
					var l = [cf].concat([for (cf2 in cf.overloads)
						if (TypeFunctions.hasClassFieldFlag(cf2, CfOverload)) cf2]);
					for (cf2 in l)
						if (!TypeFunctions.hasClassFieldFlag(cf2, CfExtern))
							generateMethod(gctx, jc, c, mtype, cf2);
				case _:
					if (!TypeFunctions.hasClassFlag(c, CInterface) && TypeFunctions.isPhysicalField(cf))
						generateField(gctx, jc, c, mtype, cf);
			}
		}
		switch (gctx.entryPoint) {
			case null:
			case ep: if (ep.c == c) generateMain(ep.e);
		}
		// A static __init__ is carried as a class field. It is left out of the ordinary statics and its
		// body goes
		// into <clinit> ahead of the class init; as an ordinary static method nothing would call it, and
		// the
		// statics it sets would stay null.
		var staticInitCf = c.statics.get("__init__");
		for (cf in c.orderedStatics) if (cf != staticInitCf) field(MStatic, cf);
		for (cf in c.orderedFields) field(MInstance, cf);
		if (c.constructor != null) field(MConstructor, c.constructor);
		// The combined init is generated once, as a single block with RReturn, so the return is emitted
		// inside
		// the block's scope and the live ranges pushScope records include it.
		var initE:Null<TExpr> = null;
		if (staticInitCf != null && staticInitCf.expr != null) switch (staticInitCf.expr.expr) {
			case TFunction(tf): initE = tf.expr;
			case _:
		}
		if (c.init != null) initE = initE == null ? c.init : TypeFunctions.concat(initE, c.init);
		if (initE != null) {
			var jm = jc.getStaticInitMethod();
			var handler = new TexprToJvm(gctx, null, jc, jm, null);
			handler.texpr(RReturn, TypeFunctions.mkBlock(initE));
		}
	}

	function generateSignature():Void {
		jc.setTypeParameters([
			for (tp in c.params) {
				name: tp.name,
				constraints: switch (GenJvm.follow(tp.type)) {
					case TInst(ci, _):
						switch (ci.kind) {
							case KTypeParameter(tl):
								[for (t in tl) NativeSignatures.getBoxedType(GenJvm.jsignatureOfType(gctx, t))];
							case _: [];
						}
					case _: [];
				}
			}
		]);
		switch (c.superClass) {
			case null:
			case sup:
				jc.setSuperParameters([for (t in sup.params) GenJvm.jtypeArgumentOfTypeTop(gctx, t)]);
		}
	}

	function generateClassAnnotations():Void {
		AnnotationHandler.generateAnnotations(jc, c.meta);
		jc.addAnnotation({pack: ["haxe", "jvm", "annotation"], name: "ClassReflectionInformation"},
			[{name: "hasSuperClass", kind: ABool(c.superClass != null)}]);
	}

	public function generate():Void {
		setAccessFlags();
		jc.setSourceFile(c.pos.file);
		generateFields();
		setInterfaces();
		if (!TypeFunctions.hasClassFlag(c, CInterface)) {
			generateEmptyCtor();
			generateImplicitCtors();
			buildBridges();
		}
		generateSignature();
		if (gctx.dynamicLevel > 0 && !TypeFunctions.hasMeta(":nativeGen", c.meta)
			&& !TypeFunctions.hasClassFlag(c, CInterface))
			DynamicAccess.generate(gctx, jc, [
				for (cf in c.orderedFields)
					{name: cf.name, jsig: GenJvm.jsignatureOfType(gctx, cf.type), kind: cf.kind}
			], false);
		generateClassAnnotations();
		GenJvm.writeClass(gctx, c.path, jc.exportClass(gctx.defaultExportConfig));
	}
}

class GenerateClass {
	public static function generateClass(gctx:GenerationContext, c:TClass):Void {
		new TclassToJvm(gctx, c).generate();
	}
}
