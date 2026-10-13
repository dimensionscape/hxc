package hxc.codegen.jvm;

import haxe.ds.StringMap;
import hxc.ast.Ast;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TexprTools;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.Ref;
import hxc.ast.Position;
import hxc.codegen.GenShared;
import hxc.codegen.jvm.GenJvm;
import hxc.codegen.jvm.JvmSignature;
import hxc.codegen.jvm.JvmSignature.JSignature;
import hxc.codegen.jvm.JvmSignature.JPath;
import hxc.codegen.jvm.JvmSignature.JTypeArgument;
import hxc.codegen.jvm.JvmSignature.NativeSignatures;
import hxc.codegen.jvm.JvmData;
import hxc.codegen.jvm.JvmData.JCmp;
import hxc.codegen.jvm.JvmClass.ClassBuilder;
import hxc.codegen.jvm.JvmMethod;
import hxc.codegen.jvm.JvmMethod.MethodBuilder;
import hxc.codegen.jvm.JvmMethod.NativeArray;
import hxc.codegen.jvm.JvmCode.CodeBuilder;
import hxc.codegen.jvm.JvmFunctions.TypedFunction;
import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmGlobals.MethodAccessFlags;
import hxc.codegen.jvm.JvmGlobals.FieldKind;
import hxc.codegen.GenShared.TanonIdentification;
import hxc.codegen.OverloadResolution;
import hxc.filters.Exceptions;
import hxc.codegen.jvm.JvmGlobals.FieldAccessFlags;

// The expression generator: turns typed expressions into the bytecode of one method.

typedef LocalAccess = {slot:Int, load:Void->Void, store:Void->Void};

// BlockExit is what an enclosing block has to run on the way out, whichever way control leaves it.
// CompareKind: a comparison either maps onto one JVM branch op, or needs its own emitter.
enum BlockExit {
	ExitExecute(f:Void->Void);
	ExitLoop;
}

enum CompareKind {
	CmpNormal(cmp:JCmp, jsig:JSignature);
	CmpSpecial(f:Ref<Int>->Void);
}

class TexprToJvm {
	var gctx:GenerationContext;
	var fieldInfo:Null<FieldGenerationInfo>;
	var jc:ClassBuilder;
	var jm:MethodBuilder;
	var returnType:Null<JSignature>;

	var com:Context;
	var code:CodeBuilder;

	var localLookup:Map<Int, LocalAccess> = new Map();
	var lastLine:Int = 0;

	var env:Null<Array<{id:Int, name:String, jsig:JSignature}>> = null;
	var blockExits:Array<BlockExit> = [];
	var caughtExceptions:Array<HaxeException> = [];
	var breakLabel:Null<JvmMethod.Label> = null;
	var continueLabel:Null<JvmMethod.Label> = null;

	public function new(gctx:GenerationContext, fieldInfo:Null<FieldGenerationInfo>, jc:ClassBuilder,
			jm:MethodBuilder, returnType:Null<JSignature>) {
		this.gctx = gctx;
		this.fieldInfo = fieldInfo;
		this.jc = jc;
		this.jm = jm;
		this.returnType = returnType;
		com = gctx.com;
		code = jm.getCode();
	}

	public function vtype(t:T):JSignature {
		return GenJvm.jsignatureOfType(gctx, t);
	}

	function mknull(t:T):T {
		return com.basic.tnull(GenJvm.follow(t));
	}


	public function addNamedLocal(name:String, jsig:JSignature):LocalAccess {
		return jm.addLocal(name, jsig, VarArgument);
	}

	public function addLocal(v:TVar, initState:JvmMethod.VarInitState):LocalAccess {
		var acc = jm.addLocal(v.name, vtype(v.type), initState);
		localLookup.set(v.id, acc);
		return acc;
	}

	public function getLocalById(vid:Int, vname:String):LocalAccess {
		if (vid == 0 && env == null)
			return {slot: 0, load: function() jm.loadThis(), store: function() throw "die"};
		var acc = localLookup.get(vid);
		if (acc != null) return acc;
		if (env != null) {
			for (e in env) if (e.id == vid) {
				return {
					slot: -1,
					load: function() {
						jm.loadThis();
						jm.getfield(jc.getThisPath(), e.name, e.jsig);
					},
					store: function() {
						jm.loadThis();
						jm.putfield(jc.getThisPath(), e.name, e.jsig);
					}
				};
			}
		}
		throw "Unbound local: " + vname;
	}

	public function getLocal(v:TVar):LocalAccess {
		return getLocalById(v.id, v.name);
	}

	public function setEnv(env:Array<{id:Int, name:String, jsig:JSignature}>):Void {
		this.env = env;
	}


	public function expectReferenceType():Void {
		jm.expectReferenceType();
	}

	public function castTo(t:T):Void {
		jm.castTo(vtype(t));
	}

	public function castExpect(ret:Ret, t:T):Void {
		switch (ret) {
			case RValue(jsig, _) if (jsig != null): jm.castTo(jsig);
			case _: castTo(t);
		}
	}

	public function makeStaticClosureField(name:String, jcClosure:ClassBuilder):Void {
		var jmInit = jcClosure.getStaticInitMethod();
		var jfClosure = jcClosure.spawnField(name, jcClosure.getJsig(),
			[FieldAccessFlags.FdStatic, FieldAccessFlags.FdPublic, FieldAccessFlags.FdFinal]);
		jmInit.construct(ConstructInit, jcClosure.getThisPath(), function() return []);
		jmInit.putstatic(jcClosure.getThisPath(), jfClosure.getName(), jfClosure.getJsig());
	}

	// A local function becomes its own closure class, capturing what it reads from outside as constructor
	// arguments stored in fields.
	public function tfunction(ret:Ret, e:TExpr, tf:TFunc):Void {
		var captured = TexprTools.collectCapturedVars(e);
		var env = [for (v in captured.outside) {id: v.id, name: v.name, jsig: vtype(v.type)}];
		if (captured.accessesThis)
			env = [{id: 0, name: "this", jsig: jc.getJsig()}].concat(env);
		var context = [for (e in env) {name: e.name, jsig: e.jsig}];
		var name = switch (ret) {
			case RValue(_, s): s;
			case _: null;
		};
		var wf = new TypedFunction(gctx.typedFunctions, FuncLocal(name), jc, jm, context);
		var jcClosure = wf.getClassBuilder();
		wf.generateConstructor(env.length != 0);
		var filter = switch (ret) {
			case RValue(TObject(path, _), _): [path];
			case _: [];
		};
		var args = [
			for (a in tf.args) {
				// An argument with a default value takes a nullable type so that null can stand for an
				// omitted
				// argument. This changes the variable's type in place.
				if (a.c != null) a.v.type = mknull(a.v.type);
				{name: a.v.name, jsig: vtype(a.v.type)};
			}
		];
		var jret = GenJvm.returnOfType(gctx, tf.type);
		var jmInvoke = wf.generateInvoke(args, jret, filter);
		var handler = new TexprToJvm(gctx, fieldInfo, jcClosure, jmInvoke, jret);
		handler.setEnv(env);
		var argAccs = [for (a in tf.args) {acc: handler.addLocal(a.v, VarArgument), v: a.v, c: a.c}];
		jmInvoke.finalizeArguments();
		// An optional argument with a real default tests for null and fills it in.
		for (a in argAccs) {
			if (a.c == null || isConstNull(a.c)) continue;
			a.acc.load();
			var jsig = vtype(a.v.type);
			var e = a.c;
			var acc = a.acc;
			jmInvoke.ifThen(function(r) jmInvoke.getCode().ifNonnull(jsig, r), function() {
				handler.texpr(RValue(jsig, null), e);
				jmInvoke.castTo(jsig);
				acc.store();
			});
		}
		handler.texpr(RReturn, tf.expr);
		if (env.length == 0) {
			// No capture, so one shared instance in a static field is enough.
			var name = jcClosure.getThisPath().name;
			makeStaticClosureField(name, jcClosure);
			jm.getstatic(jcClosure.getThisPath(), name,
				NativeSignatures.objectPathSig(jcClosure.getThisPath()));
		} else {
			jm.construct(ConstructInit, jcClosure.getThisPath(), function() {
				return [
					for (e in env) {
						getLocalById(e.id, e.name).load();
						e.jsig;
					}
				];
			});
		}
		GenJvm.writeClass(gctx, jcClosure.getThisPath(),
			jcClosure.exportClass(gctx.defaultExportConfig));
	}

	static function isConstNull(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(TNull): true;
			case _: false;
		}
	}


	public function readNativeArray(vta:JSignature, vte:JSignature):Void {
		NativeArray.read(code, vta, vte);
	}

	public function writeNativeArray(vta:JSignature, vte:JSignature):Void {
		NativeArray.write(code, vta, vte);
	}

	// A field read off a structure. If anonIdentification knows a class with this shape, an instanceof test
	// selects a direct getfield; otherwise the read goes through Jvm.readField.
	public function readAnonField(cast_:Void->Void, t:T, cf:TClassField):Void {
		function def() {
			jm.string(cf.name);
			jm.invokestatic(NativeSignatures.haxeJvmPath, "readField",
				NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.stringSig],
					NativeSignatures.objectSig));
			cast_();
		}
		switch (gctx.anonIdentification.identify(true, t)) {
			case null:
				def();
			case pfm:
				var cf2 = pfm.pfmFields.get(cf.name);
				var path = pfm.pfmPath;
				code.dup();
				code.instanceof(path);
				jm.ifThenElse(function(r) code.if_(CmpEq, r), function() {
					jm.castTo(NativeSignatures.objectPathSig(path));
					jm.getfield(path, cf2.name, vtype(cf2.type));
					cast_();
				}, function() def());
		}
	}

	// A static method used as a value becomes a closure class with no context, so one instance in a static
	// field serves every use.
	public function readStaticClosure(path:JPath, name:String,
			args:Array<{name:String, jsig:JSignature}>, ret:Null<JSignature>):Void {
		var jsig = NativeSignatures.methodSig([for (a in args) a.jsig], ret);
		var key = closureKey(path, name, jsig);
		var closurePath = gctx.closurePaths.get(key);
		if (closurePath == null) {
			var wf = new TypedFunction(gctx.typedFunctions, FuncStatic(path, name), jc, jm, []);
			var jcClosure = wf.getClassBuilder();
			wf.generateConstructor(false);
			var jmInvoke = wf.generateInvoke(args, ret, []);
			var vars = [for (a in args) jmInvoke.addLocal(a.name, a.jsig, VarArgument)];
			jmInvoke.finalizeArguments();
			for (v in vars) v.load();
			jmInvoke.invokestatic(path, name, NativeSignatures.methodSig([for (a in args) a.jsig], ret));
			jmInvoke.returnOp();
			closurePath = jcClosure.getThisPath();
			gctx.closurePaths.set(key, closurePath);
			makeStaticClosureField(name, jcClosure);
			GenJvm.writeClass(gctx, jcClosure.getThisPath(),
				jcClosure.exportClass(gctx.defaultExportConfig));
		}
		jm.getstatic(closurePath, name, NativeSignatures.objectPathSig(closurePath));
	}

	public static function closureKey(path:JPath, name:String, jsig:JSignature):String {
		return path.pack.join("/") + "/" + path.name + "|" + name + "|"
			+ JvmSignature.generateSignature(false, jsig);
	}


	// Reading a field. Which of these arms fires decides whether the result is a direct getfield, a closure
	// object, or a dynamic lookup through Jvm.readField.
	public function read(cast_:Void->Void, e1:TExpr, fa:TFieldAccess):Void {
		function readStaticClosureOf(path:JPath, cf:TClassField) {
			switch (GenJvm.follow(cf.type)) {
				case TFun(sig):
					readStaticClosure(path, cf.name,
						[for (a in sig.args) {name: a.name, jsig: vtype(a.t)}],
						GenJvm.returnOfType(gctx, sig.ret));
				case _:
					throw "die";
			}
		}
		function dynamicRead(s:String) {
			texpr(RValue(null, null), e1);
			jm.string(s);
			jm.invokestatic(NativeSignatures.haxeJvmPath, "readField",
				NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.stringSig],
					NativeSignatures.objectSig));
			cast_();
		}
		switch (fa) {
			case FStatic(c, cf) if (isJavaLangMath(c.path)
				&& (cf.name == "NaN" || cf.name == "POSITIVE_INFINITY"
					|| cf.name == "NEGATIVE_INFINITY")):
				jm.getstatic(NativeSignatures.doublePath, cf.name, TDouble);
			case FStatic(c, cf) if (isJavaLangMath(c.path)
				&& (cf.name == "isNaN" || cf.name == "isFinite")):
				readStaticClosureOf(NativeSignatures.doublePath, cf);
			case FStatic(c, cf) if (isJavaLangString(c.path) && cf.name == "fromCharCode"):
				readStaticClosureOf({pack: ["haxe", "jvm"], name: "StringExt"}, cf);
			case FStatic(c, cf) if (isNormalOrInlineMethod(cf)):
				readStaticClosureOf(c.path, cf);
			case FStatic(c, cf):
				jm.getstatic(c.path, cf.name, vtype(cf.type));
				cast_();
			case FInstance(c, _, cf) if (isJavaLangString(c.path) && cf.name == "length"):
				texpr(RValue(null, null), e1);
				jm.invokevirtual(NativeSignatures.stringPath, "length",
					NativeSignatures.methodSig([], TInt));
			case FInstance(c, _, cf) if (isJavaNativeArray(c.path) && cf.name == "length"):
				texpr(RValue(null, null), e1);
				code.arraylength(vtype(e1.type));
			case FInstance(c, _, cf) if (!GenJvm.isInterfaceVarAccess(c, cf)):
				texpr(RValue(null, null), e1);
				jm.getfield(c.path, cf.name, vtype(cf.type));
				cast_();
			case FClosure(cw, cf) if (cw != null && isDynamicMethod(cf)
				&& !GenJvm.isInterfaceVarAccess(cw.c, cf)):
				texpr(RValue(null, null), e1);
				jm.getfield(cw.c.path, cf.name, vtype(cf.type));
				cast_();
			case FEnum(en, ef) if (!isFunType(GenJvm.follow(ef.type))):
				var jsig = vtype(ef.type);
				var offset = jc.getPool().addField(en.path, ef.name, jsig, FKField);
				code.getstatic(offset, jsig);
				cast_();
			case FAnon(cf):
				texpr(RValue(null, null), e1);
				readAnonField(cast_, e1.type, cf);
			case FDynamic(s):
				dynamicRead(s);
			case FInstance(_, _, cf):
				dynamicRead(cf.name);
			case FEnum(_, ef):
				dynamicRead(ef.name);
			case FClosure(null, cf):
				dynamicRead(cf.name);
			case FClosure(cw, cf):
				if (TypeFunctions.hasClassFlag(cw.c, CInterface)) dynamicRead(cf.name);
				else FieldClosure.createFieldClosure(gctx, jc, cw.c.path, jm, cf.name,
					vtype(cf.type), function() texpr(RValue(null, null), e1));
		}
	}

	static function isJavaLangMath(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang" && p.name == "Math";
	}

	static function isJavaLangString(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang" && p.name == "String";
	}

	static function isJavaNativeArray(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 1 && p.pack[0] == "java" && p.name == "NativeArray";
	}

	static function isNormalOrInlineMethod(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Method(MethNormal) | Method(MethInline): true;
			case _: false;
		}
	}

	static function isDynamicMethod(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Method(MethDynamic): true;
			case _: false;
		}
	}

	static function isFunType(t:T):Bool {
		return switch (t) {
			case TFun(_): true;
			case _: false;
		}
	}

	// The shared shape of assignment, compound assignment and increment. `ak` says whether the old value is
	// wanted and on which side, `f` leaves the new value on the stack, and `apply` places the dup that
	// keeps a copy for the expression's own value.
	public function readWrite(ret:Ret, ak:AccessKind, e:TExpr, f:Void->Void):Void {
		function apply(dup:Void->Void) {
			if (GenJvm.needVal(ret) && ak == AKPost) dup();
			f();
			if (GenJvm.needVal(ret) && ak != AKPost) dup();
		}
		function def(s:String, t:T) {
			if (ak != AKNone) code.dup();
			jm.string(s);
			if (ak != AKNone) {
				code.dupX1();
				jm.invokestatic(NativeSignatures.haxeJvmPath, "readField",
					NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.stringSig],
						NativeSignatures.objectSig));
				castExpect(ret, t);
			}
			apply(function() code.dupX2());
			castTo(mknull(t));
			jm.invokestatic(NativeSignatures.haxeJvmPath, "writeField",
				NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.stringSig,
					NativeSignatures.objectSig], null));
		}
		switch (TexprTools.skip(e).expr) {
			case TLocal(v):
				var acc = getLocal(v);
				if (ak != AKNone) acc.load();
				apply(function() code.dup());
				castTo(v.type);
				acc.store();
			case TField(_, FStatic(c, cf)):
				var jsigCf = vtype(cf.type);
				if (ak != AKNone) jm.getstatic(c.path, cf.name, jsigCf);
				apply(function() code.dup());
				jm.castTo(jsigCf);
				jm.putstatic(c.path, cf.name, jsigCf);
			case TField(e1, FInstance(c, _, cf)) if (!GenJvm.isInterfaceVarAccess(c, cf)):
				texpr(RValue(null, null), e1);
				var jsigCf = vtype(cf.type);
				if (ak != AKNone) {
					code.dup();
					jm.getfield(c.path, cf.name, jsigCf);
				}
				apply(function() code.dupX1());
				castTo(cf.type);
				jm.putfield(c.path, cf.name, jsigCf);
			case TField(e1, FAnon(cf)):
				texpr(RValue(null, null), e1);
				switch (gctx.anonIdentification.identify(true, e1.type)) {
					case null:
						def(cf.name, cf.type);
					case pfm:
						var cf2 = pfm.pfmFields.get(cf.name);
						var path = pfm.pfmPath;
						code.dup();
						code.instanceof(path);
						var jsigCf = vtype(cf2.type);
						jm.ifThenElse(function(r) code.if_(CmpEq, r), function() {
							jm.castTo(NativeSignatures.objectPathSig(path));
							if (ak != AKNone) {
								code.dup();
								jm.getfield(path, cf2.name, jsigCf);
							}
							apply(function() code.dupX1());
							jm.castTo(jsigCf);
							jm.putfield(path, cf2.name, jsigCf);
						}, function() {
							def(cf2.name, cf2.type);
							if (GenJvm.needVal(ret)) jm.castTo(jsigCf);
						});
				}
			case TField(e1, FDynamic(s)):
				texpr(RValue(null, null), e1);
				def(s, e.type);
			case TField(e1, FInstance(_, _, cf)):
				texpr(RValue(null, null), e1);
				def(cf.name, e.type);
			case TArray(e1, e2):
				switch (GenJvm.follow(e1.type)) {
					case TInst(c, [t]) if (isHaxeRootArray(c.path)):
						texpr(RValue(null, null), e1);
						if (ak != AKNone) code.dup();
						texpr(RValue(null, null), e2);
						jm.castTo(TInt);
						if (ak != AKNone) {
							code.dupX1();
							jm.invokevirtual(c.path, "__get",
								NativeSignatures.methodSig([TInt], NativeSignatures.objectSig));
							castExpect(ret, e.type);
						}
						apply(function() code.dupX2());
						jm.expectReferenceType();
						jm.invokevirtual(c.path, "__set",
							NativeSignatures.methodSig([TInt, NativeSignatures.objectSig], null));
					case TInst(c, [t]) if (isJavaNativeArray(c.path)):
						var vte = vtype(t);
						var vta = vtype(e1.type);
						texpr(RValue(null, null), e1);
						if (ak != AKNone) code.dup();
						texpr(RValue(null, null), e2);
						if (ak != AKNone) {
							code.dupX1();
							readNativeArray(vta, vte);
						}
						apply(function() code.dupX2());
						castTo(t);
						writeNativeArray(vta, vte);
					case _:
						texpr(RValue(null, null), e1);
						if (ak != AKNone) code.dup();
						texpr(RValue(null, null), e2);
						jm.castTo(TInt);
						if (ak != AKNone) {
							code.dupX1();
							jm.invokestatic(NativeSignatures.haxeJvmPath, "arrayRead",
								NativeSignatures.methodSig([NativeSignatures.objectSig, TInt],
									NativeSignatures.objectSig));
						}
						apply(function() code.dupX2());
						castTo(e.type);
						expectReferenceType();
						jm.invokestatic(NativeSignatures.haxeJvmPath, "arrayWrite",
							NativeSignatures.methodSig([NativeSignatures.objectSig, TInt,
								NativeSignatures.objectSig], null));
				}
			case _:
				throw "die";
		}
	}

	static function isHaxeRootArray(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 2 && p.pack[0] == "haxe" && p.pack[1] == "root" && p.name == "Array";
	}



	public function applyCmp(cmp:CompareKind):Ref<Int>->Void {
		return switch (cmp) {
			case CmpNormal(op, _): function(r) code.if_(op, r);
			case CmpSpecial(f): f;
		}
	}

	// Emits a jump to labelElse when the condition fails. Short-circuit operators become jumps rather than
	// materialized booleans, and `flip` carries the negation down.
	public function condition(flip:Bool, e:TExpr, labelThen:JvmMethod.Label, labelElse:JvmMethod.Label):Void {
		var before = code.stack.save().size;
		function boolAnd(flip:Bool, e1:TExpr, e2:TExpr) {
			var labelThen2 = jm.spawnLabel("then2");
			condition(flip, e1, labelThen2, labelElse);
			labelThen2.here();
			condition(flip, e2, labelThen, labelElse);
		}
		function boolOr(flip:Bool, e1:TExpr, e2:TExpr) {
			var labelElse2 = jm.spawnLabel("else2");
			condition(!flip, e1, labelElse2, labelThen);
			labelElse2.here();
			condition(flip, e2, labelThen, labelElse);
		}
		switch (TexprTools.skip(e).expr) {
			case TBinop(op, e1, e2) if (isCmpOp(op)):
				var jop = GenJvm.convertCmpOp(op);
				if (flip) jop = GenJvm.flipCmpOp(jop);
				labelElse.apply(applyCmp(binopCompare(jop, e1, e2)));
			case TBinop(OpBoolAnd, e1, e2) if (!flip):
				boolAnd(false, e1, e2);
			case TBinop(OpBoolAnd, e1, e2) if (!involvesFloatCompare(e1)):
				boolOr(true, e1, e2);
			case TBinop(OpBoolOr, e1, e2) if (flip):
				boolAnd(true, e1, e2);
			case TBinop(OpBoolOr, e1, e2) if (!involvesFloatCompare(e1)):
				boolOr(false, e1, e2);
			case TUnop(Not, _, e1) if (!involvesFloatCompare(e1)):
				condition(!flip, e1, labelThen, labelElse);
			case _:
				texpr(RValue(TBool, null), e);
		}
		var after = code.stack.save().size;
		// Only a value actually left on the stack needs testing.
		if (after > before) {
			jm.castTo(TBool);
			labelElse.if_(flip ? CmpNe : CmpEq);
		}
	}

	static function isCmpOp(op:Binop):Bool {
		return switch (op) {
			case OpEq | OpNotEq | OpLt | OpGt | OpLte | OpGte: true;
			case _: false;
		}
	}

	// A float comparison cannot be flipped by negating the jump, because NaN makes both directions false,
	// so the rewrites that rely on negation are refused.
	static function involvesFloatCompare(e:TExpr):Bool {
		var found = false;
		function loop(e:TExpr) {
			if (found) return;
			switch (e.expr) {
				case TBinop(op, e1, e2) if (isCmpOp(op)):
					if (isFloatT(GenJvm.follow(e1.type)) || isFloatT(GenJvm.follow(e2.type))) {
						found = true;
						return;
					}
					loop(e1);
					loop(e2);
				case _:
					TexprTools.iter(loop, e);
			}
		}
		loop(e);
		return found;
	}

	static function isFloatT(t:T):Bool {
		return switch (t) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Float";
			case _: false;
		}
	}

	// An all-Int switch becomes a real JVM switch, an all-String switch becomes the hash-based one, and
	// anything else is rewritten into an if chain.
	public function switchExpr(ret:Ret, e1:TExpr, cases:Array<TSwitchCase>, def:Null<TExpr>):Void {
		var needVal = switch (ret) {
			case RValue(_, _): true;
			case RReturn: returnType != null;
			case _: false;
		};
		if (cases.length == 0) {
			texpr(ret, e1);
		} else if (allConstInt(cases)) {
			var jcases = [
				for (c in cases) {
					values: [
						for (e in c.values) switch (e.expr) {
							case TConst(TInt(i)): i;
							case _: throw "die";
						}
					],
					f: function() texpr(ret, c.expr)
				}
			];
			var jdef = def == null ? null : function() texpr(ret, def);
			texpr(RValue(null, null), e1);
			jm.castTo(TInt);
			jm.intSwitch(needVal, jcases, jdef);
		} else if (allConstString(cases)) {
			var jcases = [
				for (c in cases) {
					values: [
						for (e in c.values) switch (e.expr) {
							case TConst(TString(s)): s;
							case _: throw "die";
						}
					],
					f: function() texpr(ret, c.expr)
				}
			];
			var jdef = def == null ? null : function() texpr(ret, def);
			texpr(RValue(null, null), e1);
			jm.castTo(NativeSignatures.stringSig);
			var acc = jm.addLocal("_hx_tmp", NativeSignatures.stringSig, VarWillInit);
			acc.store();
			jm.stringSwitch(needVal, acc.load, jcases, jdef);
		} else {
			var popScope = jm.pushScope();
			texpr(RValue(null, null), e1);
			var v = TypeFunctions.allocVar(VGenerated, "tmp", e1.type, Position.nullPos);
			var acc = addLocal(v, VarWillInit);
			castTo(v.type);
			acc.store();
			var ev = TypeFunctions.mk(TLocal(v), v.type, Position.nullPos);
			// Prepending leaves `el` in reverse case order.
			var el = [];
			for (c in cases) {
				function f(e2:TExpr) return TypeFunctions.mk(TBinop(OpEq, ev, e2), com.basic.tbool, e2.pos);
				var eCond = switch (c.values) {
					case []:
						throw "die";
					case [e2]:
						f(e2);
					case values:
						var eacc = f(values[0]);
						for (i in 1...values.length)
							eacc = TypeFunctions.mk(TBinop(OpBoolOr, eacc, f(values[i])), com.basic.tbool,
								values[i].pos);
						eacc;
				};
				el.unshift({cond: eCond, then: c.expr});
			}
			// When an exhaustive switch that has to produce a value is rewritten without a default, its
			// last case
			// serves as the default, to satisfy control flow.
			var def2 = def;
			if (needVal && def == null) {
				// `el` is reversed, so the last case is at its head
				if (el.length == 0) throw "die";
				def2 = el.shift().then;
			}
			var e:Null<TExpr> = def2;
			for (c in el) e = TypeFunctions.mk(TIf(c.cond, c.then, e), c.then.type, c.then.pos);
			if (e == null) throw "Option.get";
			texpr(ret, e);
			popScope();
		}
	}

	static function allConstInt(cases:Array<TSwitchCase>):Bool {
		for (c in cases) if (!GenJvm.isConstIntPattern(c.values)) return false;
		return true;
	}

	static function allConstString(cases:Array<TSwitchCase>):Bool {
		for (c in cases) if (!GenJvm.isConstStringPattern(c.values)) return false;
		return true;
	}


	public function binopExprs(castType:JSignature, f1:Ret->Void, f2:Ret->Void):Void {
		f1(RValue(castType, null));
		jm.castTo(castType);
		f2(RValue(castType, null));
		jm.castTo(castType);
	}

	// The type both operands are widened to before the operation.
	public function getBinopTypeSig(jsig1:JSignature, jsig2:JSignature):JSignature {
		var u1 = NativeSignatures.getUnboxedType(jsig1);
		var u2 = NativeSignatures.getUnboxedType(jsig2);
		if (isStringSig(u1) || isStringSig(u2)) return NativeSignatures.stringSig;
		inline function either(want:JSignature) return Type.enumEq(u1, want) || Type.enumEq(u2, want);
		if (either(TLong)) return TLong;
		if (either(TDouble)) return TDouble;
		if (either(TFloat)) return TFloat;
		if (either(TInt)) return TInt;
		if (either(TShort)) return TShort;
		if (either(TChar)) return TChar;
		if (either(TByte)) return TByte;
		if (either(TBool)) return TBool;
		if (JvmSignature.eq(u1, NativeSignatures.stringSig) || JvmSignature.eq(u2, NativeSignatures.stringSig))
			return NativeSignatures.stringSig;
		return NativeSignatures.objectSig;
	}

	static function isStringSig(jsig:JSignature):Bool {
		return switch (jsig) {
			case TObject(p, _): p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang"
				&& p.name == "String";
			case _: false;
		}
	}

	public function getBinopType(t1:T, t2:T):JSignature {
		return getBinopTypeSig(GenJvm.jsignatureOfType(gctx, t1), GenJvm.jsignatureOfType(gctx, t2));
	}


	// Emits the actual comparison for whatever two values are on the stack. The op is flipped in most arms
	// because the JVM branch jumps when the condition FAILS.
	public function doCompare(op:JCmp):CompareKind {
		var items = code.stack.getStackItems(2);
		inline function isIntLike(t:JSignature) return switch (t) {
			case TInt | TByte | TChar | TShort | TBool: true;
			case _: false;
		};
		inline function isString(t:JSignature) return switch (t) {
			case TObject(p, []): p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang"
				&& p.name == "String";
			case _: false;
		};
		inline function isObjectOrTypeParam(t:JSignature) return switch (t) {
			case TObject(p, []): p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang"
				&& p.name == "Object";
			case TTypeParameter(_): true;
			case _: false;
		};
		inline function isRef(t:JSignature) return switch (t) {
			case TObject(_, _) | TArray(_, _) | TMethod(_, _): true;
			case _: false;
		};
		if (items.length != 2)
			throw "Bad stack: " + [for (t in items) JvmSignature.generateSignature(false, t)].join(", ");
		var t1 = items[0];
		var t2 = items[1];
		if (isIntLike(t1) && isIntLike(t2)) {
			var op2 = GenJvm.flipCmpOp(op);
			return CmpSpecial(function(r) code.ifIcmp(op2, r));
		}
		if (isString(t1) && isString(t2)) {
			jm.invokestatic(NativeSignatures.haxeJvmPath, "stringCompare",
				NativeSignatures.methodSig([NativeSignatures.stringSig, NativeSignatures.stringSig], TInt));
			return CmpNormal(GenJvm.flipCmpOp(op), TBool);
		}
		if (isObjectOrTypeParam(t1) || isObjectOrTypeParam(t2)) {
			jm.invokestatic(NativeSignatures.haxeJvmPath, "compare",
				NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.objectSig], TInt));
			return CmpNormal(GenJvm.flipCmpOp(op), TBool);
		}
		if (isRef(t1) && isRef(t2))
			return CmpSpecial(Type.enumEq(op, CmpEq) ? function(r) code.ifAcmpNe(t1, t2, r)
				: function(r) code.ifAcmpEq(t1, t2, r));
		if (Type.enumEq(t1, TDouble) && Type.enumEq(t2, TDouble)) {
			var op2 = GenJvm.flipCmpOp(op);
			switch (op2) {
				case CmpGe | CmpGt: code.dcmpg();
				case _: code.dcmpl();
			}
			return CmpNormal(op2, TDouble);
		}
		if (Type.enumEq(t1, TFloat) && Type.enumEq(t2, TFloat)) {
			var op2 = GenJvm.flipCmpOp(op);
			switch (op2) {
				case CmpGe | CmpGt: code.fcmpg();
				case _: code.fcmpl();
			}
			return CmpNormal(op2, TFloat);
		}
		if (Type.enumEq(t1, TLong) && Type.enumEq(t2, TLong)) {
			var op2 = GenJvm.flipCmpOp(op);
			code.lcmpl();
			return CmpNormal(op2, TLong);
		}
		throw "Can't compare " + JvmSignature.generateSignature(false, t1) + " and "
			+ JvmSignature.generateSignature(false, t2);
	}

	// Materializes a comparison as a boolean rather than a jump.
	public function boolop(cmp:CompareKind):Void {
		jm.ifThenElse(applyCmp(cmp), function() code.bconst(true), function() code.bconst(false));
	}

	// Compares two expressions. Most of the bulk is the boxed cases, where a null on either side has to
	// decide the result before the numeric comparison can run at all.
	public function binopCompare(op:JCmp, e1:TExpr, e2:TExpr):CompareKind {
		var sig1 = GenJvm.jsignatureOfType(gctx, e1.type);
		var sig2 = GenJvm.jsignatureOfType(gctx, e2.type);
		var s1 = TexprTools.skip(e1);
		var s2 = TexprTools.skip(e2);
		if (isConstNull(s1) && !NativeSignatures.isUnboxed(sig2)) {
			texpr(RValue(null, null), e2);
			return CmpSpecial(Type.enumEq(op, CmpEq) ? function(r) code.ifNonnull(sig2, r)
				: function(r) code.ifNull(sig2, r));
		}
		if (isConstNull(s2) && !NativeSignatures.isUnboxed(sig1)) {
			texpr(RValue(null, null), e1);
			return CmpSpecial(Type.enumEq(op, CmpEq) ? function(r) code.ifNonnull(sig1, r)
				: function(r) code.ifNull(sig1, r));
		}
		// Comparing against a literal 0 is one op rather than two, so it gets its own arms.
		switch (s1.expr) {
			case TConst(TInt(i)) if (i == 0 && Type.enumEq(sig2, TInt)):
				var op2 = switch (op) {
					case CmpGt: CmpGe;
					case CmpLt: CmpLe;
					case CmpLe: CmpLt;
					case CmpGe: CmpGt;
					case CmpEq: CmpNe;
					case CmpNe: CmpEq;
				};
				// The skipped other operand is emitted, and it is cast to the literal's type rather than
				// its own.
				texpr(RValue(null, null), s2);
				castTo(s1.type);
				return CmpNormal(op2, TInt);
			case _:
		}
		switch (s2.expr) {
			case TConst(TInt(i)) if (i == 0 && Type.enumEq(sig1, TInt)):
				// Likewise, the skipped e1 is emitted and cast to the literal's type.
				var op2 = GenJvm.flipCmpOp(op);
				texpr(RValue(null, null), s1);
				castTo(s2.type);
				return CmpNormal(op2, TInt);
			case _:
		}
		var u1 = NativeSignatures.isUnboxed(sig1);
		var u2 = NativeSignatures.isUnboxed(sig2);
		if (u1 && u2) {
			binopExprs(getBinopType(e1.type, e2.type), function(r) texpr(r, e1), function(r) texpr(r, e2));
			return doCompare(op);
		}
		if (!u1 && !u2) {
			var un1 = NativeSignatures.getUnboxedType(sig1);
			var un2 = NativeSignatures.getUnboxedType(sig2);
			if (JvmSignature.eq(sig1, un1) && JvmSignature.eq(sig2, un2)) {
				// No basic types involved, do normal comparison
				texpr(RValue(null, null), e1);
				texpr(RValue(null, null), e2);
				return doCompare(op);
			}
			// At least one of the types is a wrapped numeric one
			var castType = getBinopTypeSig(un1, un2);
			texpr(RValue(null, null), e1);
			code.dup();
			jm.ifThenElse(function(r) code.ifNonnull(sig1, r), function() {
				code.popOp();
				texpr(RValue(null, null), e2);
				switch (op) {
					case CmpEq | CmpGe | CmpLe:
						boolop(CmpSpecial(function(r) code.ifNonnull(sig2, r)));
					case CmpNe:
						boolop(CmpSpecial(function(r) code.ifNull(sig2, r)));
					case _:
						code.popOp();
						code.bconst(false);
				}
			}, function() {
				jm.castTo(castType, true);
				texpr(RValue(null, null), e2);
				code.dup();
				jm.ifThenElse(function(r) code.ifNonnull(sig2, r), function() {
					code.popOp();
					code.popOp();
					code.bconst(Type.enumEq(op, CmpNe));
				}, function() {
					jm.castTo(castType, true);
					boolop(doCompare(op));
				});
			});
			return CmpNormal(CmpEq, TBool);
		}
		if (!u1 && u2) {
			texpr(RValue(null, null), e1);
			code.dup();
			jm.ifThenElse(function(r) code.ifNonnull(sig1, r), function() {
				code.popOp();
				code.bconst(Type.enumEq(op, CmpNe));
			}, function() {
				var un1 = NativeSignatures.getUnboxedType(sig1);
				var isFloaty = switch (un1) {
					case TFloat | TDouble: true;
					case _: false;
				};
				if (isFloaty && Type.enumEq(sig2, TInt)) {
					jm.castTo(un1, true);
					texpr(RValue(null, null), e2);
					jm.castTo(un1, true);
				} else {
					jm.castTo(sig2, true);
					texpr(RValue(null, null), e2);
				}
				boolop(doCompare(op));
			});
			return CmpNormal(CmpEq, TBool);
		}
		// u1 && !u2
		texpr(RValue(null, null), e1);
		var un2 = NativeSignatures.getUnboxedType(sig2);
		var isFloaty = switch (un2) {
			case TFloat | TDouble: true;
			case _: false;
		};
		var cast_:Void->Void;
		if (Type.enumEq(sig1, TInt) && isFloaty) {
			jm.castTo(un2, true);
			texpr(RValue(null, null), e2);
			cast_ = function() jm.castTo(un2, true);
		} else {
			texpr(RValue(null, null), e2);
			cast_ = function() jm.castTo(sig1, true);
		}
		code.dup();
		jm.ifThenElse(function(r) code.ifNonnull(sig2, r), function() {
			code.popOp();
			code.popOp();
			code.bconst(Type.enumEq(op, CmpNe));
		}, function() {
			cast_();
			boolop(doCompare(op));
		});
		return CmpNormal(CmpEq, TBool);
	}


	// The arithmetic itself, dispatched on the type both operands were widened to. Anything that is not a
	// primitive or a String goes through a Jvm.opXxx helper.
	public function binopBasic(ret:Ret, op:Binop, castType:JSignature, f1:Ret->Void, f2:Ret->Void):Void {
		function emitExprs() binopExprs(castType, f1, f2);
		function methodName():String {
			return switch (op) {
				case OpAdd: "opAdd";
				case OpSub: "opSub";
				case OpMult: "opMul";
				case OpDiv: "opDiv";
				case OpMod: "opMod";
				case OpAnd: "opAnd";
				case OpOr: "opOr";
				case OpXor: "opXor";
				case OpShl: "opShl";
				case OpShr: "opShr";
				case OpUShr: "opUshr";
				case _: throw "die";
			}
		}
		function dynamicOp() {
			emitExprs();
			jm.invokestatic(NativeSignatures.haxeJvmPath, methodName(),
				NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.objectSig],
					NativeSignatures.objectSig));
		}
		switch (castType) {
			case TByte | TShort | TInt:
				switch (op) {
					case OpAdd: emitExprs(); code.iadd();
					case OpSub: emitExprs(); code.isub();
					case OpMult: emitExprs(); code.imul();
					// Division of integers produces a Float, so both sides widen to double first.
					case OpDiv:
						f1(RValue(TDouble, null));
						jm.castTo(TDouble);
						f2(RValue(TDouble, null));
						jm.castTo(TDouble);
						code.ddiv();
					case OpAnd: emitExprs(); code.iand();
					case OpOr: emitExprs(); code.ior();
					case OpXor: emitExprs(); code.ixor();
					case OpShl: emitExprs(); code.ishl();
					case OpShr: emitExprs(); code.ishr();
					case OpUShr: emitExprs(); code.iushr();
					case OpMod: emitExprs(); code.irem();
					case _: throw "Unsupported binop on TInt: " + Std.string(op);
				}
			case TFloat:
				emitExprs();
				switch (op) {
					case OpAdd: code.fadd();
					case OpSub: code.fsub();
					case OpMult: code.fmul();
					case OpDiv: code.fdiv();
					case OpMod: code.frem();
					case _: throw "Unsupported binop on TFloat: " + Std.string(op);
				}
			case TDouble:
				emitExprs();
				switch (op) {
					case OpAdd: code.dadd();
					case OpSub: code.dsub();
					case OpMult: code.dmul();
					case OpDiv: code.ddiv();
					case OpMod: code.drem();
					case _: throw "Unsupported binop on TDouble: " + Std.string(op);
				}
			case TLong:
				switch (op) {
					case OpAdd: emitExprs(); code.ladd();
					case OpSub: emitExprs(); code.lsub();
					case OpMult: emitExprs(); code.lmul();
					case OpDiv: emitExprs(); code.ldivOp();
					case OpAnd: emitExprs(); code.landOp();
					case OpOr: emitExprs(); code.lorOp();
					case OpXor: emitExprs(); code.lxorOp();
					// The shift distance of a long shift is an int, not a long.
					case OpShl:
						f1(RValue(TLong, null));
						jm.castTo(TLong);
						f2(RValue(TLong, null));
						jm.castTo(TInt);
						code.lshl();
					case OpShr:
						f1(RValue(TLong, null));
						jm.castTo(TLong);
						f2(RValue(TInt, null));
						jm.castTo(TInt);
						code.lshr();
					case OpUShr:
						f1(RValue(TLong, null));
						jm.castTo(TLong);
						f2(RValue(TInt, null));
						jm.castTo(TInt);
						code.lushr();
					case OpMod: emitExprs(); code.lrem();
					case _: throw "Unsupported binop on TInt: " + Std.string(op);
				}
			case TBool:
				binopBoolOrDynamic(op, f1, f2, dynamicOp);
			case TTypeParameter(_):
				binopBoolOrDynamic(op, f1, f2, dynamicOp);
			case TObject(path, _) if (isJavaLangObjectPath(path)):
				binopBoolOrDynamic(op, f1, f2, dynamicOp);
			case TObject(path, _):
				if (isJavaLangStringPath(path)) {
					f1(RValue(null, null));
					jm.castTo(castType, false, true);
					f2(RValue(null, null));
					jm.castTo(castType, false, true);
					jm.invokestatic(NativeSignatures.haxeJvmPath, "stringConcat",
						NativeSignatures.methodSig([NativeSignatures.objectSig, NativeSignatures.objectSig],
							NativeSignatures.stringSig));
				} else {
					dynamicOp();
				}
			case _:
				throw "Unsupported operation " + Std.string(op) + " on "
					+ JvmSignature.generateSignature(false, castType);
		}
	}

	// && and || short-circuit even where the operands are boxed
	function binopBoolOrDynamic(op:Binop, f1:Ret->Void, f2:Ret->Void, dynamicOp:Void->Void):Void {
		function operand(f:Ret->Void) {
			f(RValue(TBool, null));
			jm.castTo(TBool);
		}
		switch (op) {
			case OpBoolAnd:
				operand(f1);
				jm.ifThenElse(function(r) code.if_(CmpEq, r), function() operand(f2),
					function() code.bconst(false));
			case OpBoolOr:
				operand(f1);
				jm.ifThenElse(function(r) code.if_(CmpEq, r), function() code.bconst(true),
					function() operand(f2));
			case _:
				dynamicOp();
		}
	}

	static function isJavaLangObjectPath(p:JPath):Bool {
		return p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang" && p.name == "Object";
	}

	static function isJavaLangStringPath(p:JPath):Bool {
		return p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang" && p.name == "String";
	}

	public function varSlotIsInInt8Range(v:TVar):Bool {
		var slot = getLocal(v).slot;
		// A signed 8-bit check, so slots 128 to 255 are excluded even though iinc's index byte is unsigned.
		return slot >= -128 && slot <= 127;
	}

	public function binop(ret:Ret, op:Binop, e1:TExpr, e2:TExpr):Void {
		if (isCmpOp(op)) {
			boolop(binopCompare(GenJvm.convertCmpOp(op), e1, e2));
			return;
		}
		switch (op) {
			case OpAssign:
				readWrite(ret, AKNone, e1, function() {
					texpr(RValue(GenJvm.jsignatureOfType(gctx, e1.type), null), e2);
					castTo(e1.type);
				});
			case OpAssignOp(op2):
				var jsig1 = GenJvm.jsignatureOfType(gctx, e1.type);
				// x += <small int literal> on an int local is one iinc, no load and store
				var s1 = TexprTools.skip(e1);
				var s2 = TexprTools.skip(e2);
				var handled = false;
				switch [op2, s1.expr, s2.expr] {
					case [OpAdd, TLocal(v), TConst(TInt(i))]
						if (GenJvm.isReallyInt(v.type) && inInt8Range(i) && varSlotIsInInt8Range(v)):
						var acc = getLocal(v);
						code.iinc(acc.slot, i);
						if (GenJvm.needVal(ret)) acc.load();
						handled = true;
					case [OpSub, TLocal(v), TConst(TInt(i))]
						if (GenJvm.isReallyInt(v.type) && inInt8Range(-i) && varSlotIsInInt8Range(v)):
						var acc = getLocal(v);
						code.iinc(acc.slot, -i);
						if (GenJvm.needVal(ret)) acc.load();
						handled = true;
					case _:
				}
				if (!handled) {
					readWrite(ret, AKPre, e1, function() {
						binopBasic(ret, op2, getBinopType(e1.type, e2.type), function(_) {},
							function(r) texpr(r, e2));
						jm.castTo(jsig1);
					});
				}
			case _:
				binopBasic(ret, op, getBinopType(e1.type, e2.type), function(r) texpr(r, e1),
					function(r) texpr(r, e2));
		}
	}

	static inline function inInt8Range(i:Int):Bool {
		return i >= -128 && i <= 127;
	}

	public function unop(ret:Ret, op:Unop, flag:UnopFlag, e:TExpr):Void {
		var s = TexprTools.skip(e);
		switch (op) {
			case Increment | Decrement:
				switch (s.expr) {
					case TLocal(v) if (GenJvm.isReallyInt(v.type) && varSlotIsInInt8Range(v)):
						var acc = getLocal(v);
						if (flag == Postfix && GenJvm.needVal(ret)) acc.load();
						code.iinc(acc.slot, op == Increment ? 1 : -1);
						if (flag == Prefix && GenJvm.needVal(ret)) acc.load();
					case _:
						var isNull = TypeFunctions.isNull(e.type);
						readWrite(ret, flag == Prefix ? AKPre : AKPost, e, function() {
							switch (code.stack.top()) {
								case TLong:
									code.lconst(haxe.Int64.ofInt(1));
									if (op == Increment) code.ladd() else code.lsub();
								case TDouble:
									code.dconst(1.0);
									if (op == Increment) code.dadd() else code.dsub();
								case TFloat:
									code.fconst(1.0);
									if (op == Increment) code.fadd() else code.fsub();
								case TByte | TShort | TInt:
									code.iconst(1);
									if (op == Increment) code.iadd() else code.isub();
									if (isNull) expectReferenceType();
								case _:
									jm.invokestatic(NativeSignatures.haxeJvmPath,
										op == Increment ? "opIncrement" : "opDecrement",
										NativeSignatures.methodSig([NativeSignatures.objectSig],
											NativeSignatures.objectSig));
							}
						});
				}
			case Neg:
				texpr(RValue(null, null), e);
				var jsig = GenJvm.jsignatureOfType(gctx, GenJvm.follow(e.type));
				jm.castTo(jsig);
				switch (jsig) {
					case TLong: code.lneg();
					case TDouble: code.dneg();
					case TFloat: code.fneg();
					case TByte | TShort | TInt: code.ineg();
					case _:
						jm.invokestatic(NativeSignatures.haxeJvmPath, "opNeg",
							NativeSignatures.methodSig([NativeSignatures.objectSig],
								NativeSignatures.objectSig));
				}
				castTo(e.type);
			case Not:
				jm.ifThenElseLabeled(function(lt, le) condition(false, e, lt, le),
					function() code.bconst(false), function() code.bconst(true));
			case Spread:
				texpr(RValue(GenJvm.jsignatureOfType(gctx, e.type), null), e);
			case NegBits:
				var jsig = GenJvm.jsignatureOfType(gctx, GenJvm.follow(e.type));
				texpr(RValue(null, null), e);
				jm.castTo(jsig);
				switch (jsig) {
					case TByte | TShort | TInt:
						code.iconst(-1);
						code.ixor();
					case TLong:
						code.lconst(haxe.Int64.ofInt(-1));
						code.lxorOp();
					case _:
						jm.invokestatic(NativeSignatures.haxeJvmPath, "opNegBits",
							NativeSignatures.methodSig([NativeSignatures.objectSig],
								NativeSignatures.objectSig));
				}
				castTo(e.type);
		}
	}



	public function newNativeArray(jsig:JSignature, el:Array<TExpr>):Void {
		jm.newNativeArray(jsig, [for (e in el) function() texpr(RValue(jsig, null), e)]);
	}

	// Pushes the arguments of a call and reports the signatures they actually landed on. A trailing
	// haxe.Rest collects whatever is left into a native array.
	public function callArguments(t:T, el:Array<TExpr>, cast_:Bool = true):{tl:Array<JSignature>, tr:Null<JSignature>} {
		var tl:Array<TSignatureArg>;
		var tr:Null<JSignature>;
		switch (GenJvm.follow(t)) {
			case TFun(sig):
				tl = sig.args;
				tr = GenJvm.returnOfType(gctx, sig.ret);
			case _:
				tl = [for (e in el) new TSignatureArg("", false, e.type)];
				tr = NativeSignatures.objectSig;
		}
		var acc = [];
		var ti = 0;
		var ei = 0;
		while (true) {
			if (ti < tl.length && ei < el.length) {
				var t2 = tl[ti].t;
				var e = el[ei];
				var jsig = GenJvm.jsignatureOfType(gctx, t2);
				var rest = ti == tl.length - 1 ? restElemType(TypeFunctions.follow(t2)) : null;
				if (rest != null) {
					switch (e.expr) {
						case TUnop(Spread, _, e2):
							texpr(RValue(jsig, null), e2);
						case _:
							newNativeArray(GenJvm.jsignatureOfType(gctx, rest), el.slice(ei));
					}
					acc.push(jsig);
					break;
				}
				texpr(RValue(jsig, null), e);
				if (cast_) {
					jm.castTo(jsig);
					acc.push(jsig);
				} else {
					acc.push(code.stack.top());
				}
				ti++;
				ei++;
				continue;
			}
			// One parameter left over with no argument to fill it: only a Rest gets an empty array.
			if (ti == tl.length - 1 && ei >= el.length) {
				var rest = restElemType(TypeFunctions.follow(tl[ti].t));
				if (rest != null) {
					var jsig = GenJvm.jsignatureOfType(gctx, tl[ti].t);
					newNativeArray(GenJvm.jsignatureOfType(gctx, rest), []);
					acc.push(jsig);
				}
				break;
			}
			if (ei >= el.length) break;
			if (ti >= tl.length) {
				// More arguments than parameters: the extra ones are pushed as they are, without a cast.
				texpr(RValue(null, null), el[ei]);
				acc.push(vtype(el[ei].type));
				ei++;
				continue;
			}
			break;
		}
		return {tl: acc, tr: tr};
	}

	// The element type of a haxe.Rest, or null for any other type.
	static function restElemType(t:T):Null<T> {
		return switch (t) {
			case TAbstract(a, params) if (params.length == 1 && a.path.pack.length == 1
				&& a.path.pack[0] == "haxe" && a.path.name == "Rest"): params[0];
			case _: null;
		};
	}


	// Emits a call. Most arms are a specific callee that maps onto a JVM opcode or a Java library method
	// directly; anything else goes through the haxe.jvm.Function invoke.
	public function call(ret:Ret, tr:T, e1:TExpr, el:Array<TExpr>):Void {
		function invoke(t:T):Null<JSignature> {
			jm.castTo(NativeSignatures.haxeFunctionSig);
			// Arguments are not cast here; the typed function registered for their actual signature handles
			// that.
			var r = callArguments(t, el, false);
			var meth = gctx.typedFunctions.registerSignature(r.tl, r.tr);
			jm.invokevirtual(NativeSignatures.haxeFunctionPath, meth.name,
				NativeSignatures.methodSig(meth.dargs, meth.dret));
			return r.tr;
		}
		var tro:Null<JSignature> = null;
		var handled = true;
		var s1 = TexprTools.skip(e1);
		switch (s1.expr) {
			case TField(_, FStatic(c, cf)) if (isHaxeJvmJvm(c.path) && cf.name == "referenceEquals"):
				var r = callArguments(cf.type, el);
				switch (r.tl) {
					case [t1, t2]: boolop(CmpSpecial(function(rf) code.ifAcmpNe(t1, t2, rf)));
					case _: throw "die";
				}
				tro = r.tr;
			case TField(_, FStatic(c, cf)) if (isHaxeJvmJvm(c.path) && cf.name == "instanceof"):
				switch (el) {
					case [ea1, {expr: TTypeExpr(mt), pos: pe}]:
						texpr(RValue(null, null), ea1);
						expectReferenceType();
						var path = switch (GenJvm.jsignatureOfType(gctx, TypeFunctions.typeOfModuleType(mt))) {
							case TObject(p, _): p;
							case _: throw new hxc.core.TypingError("Class expected", pe);
						};
						code.instanceof(path);
						tro = TBool;
					case _:
						throw new hxc.core.TypingError("Type expression expected", e1.pos);
				}
			case TField(_, FStatic(c, cf)) if (isJavaLangMathPath(c.path)
				&& (cf.name == "isNaN" || cf.name == "isFinite")):
				switch (el) {
					case [ea1]:
						texpr(RValue(null, null), ea1);
						jm.castTo(TDouble);
						jm.invokestatic({pack: ["java", "lang"], name: "Double"}, cf.name,
							NativeSignatures.methodSig([TDouble], TBool));
						tro = TBool;
					case _: throw "die";
				}
			case TField(_, FStatic(c, cf)) if (isJavaLangMathPath(c.path)
				&& (cf.name == "floor" || cf.name == "ceil" || cf.name == "round")):
				switch (el) {
					case [ea1]:
						texpr(RValue(null, null), ea1);
						jm.castTo(TDouble);
						var rsig = cf.name == "round" ? TLong : TDouble;
						jm.invokestatic({pack: ["java", "lang"], name: "Math"}, cf.name,
							NativeSignatures.methodSig([TDouble], rsig));
						jm.castTo(TInt);
						tro = TInt;
					case _: throw "die";
				}
			case TField(_, FStatic(c, cf)) if (isJavaLangMathPath(c.path)
				&& (cf.name == "ffloor" || cf.name == "fceil")):
				var r = callArguments(cf.type, el);
				// ffloor and fceil are Java's floor and ceil with an f prefix, so the prefix is dropped.
				jm.invokestatic(c.path, cf.name.substr(1), NativeSignatures.methodSig(r.tl, r.tr));
				tro = r.tr;
			case TField(_, FStatic(c, cf)) if (isInt64Impl(c.path) && cf.name == "make"):
				switch (el) {
					case [{expr: TConst(TInt(i1))}, {expr: TConst(TInt(i2))}]:
						var high = haxe.Int64.shl(haxe.Int64.ofInt(i1), 32);
						var low = haxe.Int64.and(haxe.Int64.ofInt(i2), haxe.Int64.make(0, 0xFFFFFFFF));
						code.lconst(haxe.Int64.or(high, low));
						tro = TLong;
					case [ea1, ea2]:
						texpr(RValue(TLong, null), ea1);
						jm.castTo(TLong);
						code.iconst(32);
						code.lshl();
						texpr(RValue(TLong, null), ea2);
						jm.castTo(TLong);
						code.lconst(haxe.Int64.make(0, 0xFFFFFFFF));
						code.landOp();
						code.lorOp();
						tro = TLong;
					case _: throw "die";
				}
			case TIdent("__array__"):
				tro = nativeArrayMake(tr, el, e1);
			case TField(_, FStatic(c, cf)) if (isJavaNativeArrayPath(c.path) && cf.name == "make"):
				tro = nativeArrayMake(tr, el, e1);
			case TField(_, FStatic(c, cf)) if (isHaxeEnumTools(c.path) && cf.name == "values"):
				switch (el) {
					case [ea1]:
						var jsigRet = NativeSignatures.arraySig(
							NativeSignatures.objectPathSig(NativeSignatures.objectPath));
						var meth = gctx.typedFunctions.registerSignature([], jsigRet);
						var jsigMeth = NativeSignatures.methodSig(meth.dargs, meth.dret);
						read(function() jm.castTo(jsigMeth), ea1, FDynamic("values"));
						jm.invokevirtual(NativeSignatures.haxeFunctionPath, meth.name, jsigMeth);
						tro = jsigRet;
					case _: throw "die";
				}
			case TField(_, FStatic(c, cf)) if (isNormalOrInlineMethod(cf)):
				var r = callArguments(cf.type, el);
				jm.invokestatic(c.path, cf.name, NativeSignatures.methodSig(r.tl, r.tr));
				tro = r.tr;
			case TField(ef1, FInstance(c, _, cf)) if (isStringBufNoDescendants(c) && cf.name == "add"):
				texpr(RValue(null, null), ef1);
				var jsig;
				switch (el) {
					case [ea1]:
						texpr(RValue(null, null), ea1);
						jsig = switch (code.stack.top()) {
							case t = TBool | TChar | TDouble | TFloat | TInt | TLong: t;
							case t = TObject(p, _) if (isJavaLangStringPath(p)): t;
							case TByte | TShort:
								jm.castTo(TInt);
								TInt;
							case _:
								jm.castTo(NativeSignatures.objectSig);
								NativeSignatures.objectSig;
						};
					case _:
						callArguments(cf.type, el);
						jsig = NativeSignatures.objectSig;
				}
				jm.invokevirtual(c.path, "add", NativeSignatures.methodSig([jsig], null));
				tro = null;
			case TField(ef1, FInstance(c, _, cf)) if (isNormalOrInlineMethod(cf)):
				var isSuper = switch (ef1.expr) {
					case TConst(TSuper):
						code.aload(jc.getJsig(), 0);
						true;
					case _:
						texpr(RValue(null, null), ef1);
						false;
				};
				var r = callArguments(cf.type, el);
				var msig = NativeSignatures.methodSig(r.tl, r.tr);
				if (isSuper) jm.invokespecial(c.path, cf.name, msig);
				else if (TypeFunctions.hasClassFlag(c, CInterface)) jm.invokeinterface(c.path, cf.name, msig);
				else jm.invokevirtual(c.path, cf.name, msig);
				tro = r.tr;
			case TField(_, FEnum(en, ef)):
				var r = callArguments(ef.type, el);
				var jtr = vtype(tr);
				jm.invokestatic(en.path, ef.name, NativeSignatures.methodSig(r.tl, jtr));
				tro = jtr;
			case TField(e11, FAnon(cf)):
				// A structure whose shape matches a generated interface is called through it.
				var done = false;
				switch (gctx.anonIdentification.identify(false, e11.type)) {
					case null:
					case pfm:
						switch (gctx.typedefInterfaces.getInterfaceClass(pfm.pfmPath)) {
							case null:
							case ci:
								var rcf = TypeFunctions.rawClassField(function(cf) return cf.type, ci, [],
									cf.name);
								var pathInner = switch (rcf.c2) {
									case null: throw "die";
									case cw: cw.c.path;
								};
								texpr(RValue(null, null), e11);
								var r = callArguments(rcf.f.type, el);
								jm.invokeinterface(pathInner, rcf.f.name, vtype(rcf.f.type));
								if (r.tr != null) jm.castTo(r.tr);
								tro = r.tr;
								done = true;
						}
				}
				if (!done) {
					texpr(RValue(null, null), e1);
					tro = invoke(e1.type);
				}
			case TConst(TSuper):
				// The preprocessor has already worked out which super constructor each super call reaches
				// (superCallFields), in the same order the generator walks the expressions.
				var info = fieldInfo;
				if (info == null || info.superCallFields.length == 0)
					throw new hxc.core.TypingError("Something went wrong", e1.pos);
				var hd = info.superCallFields.shift();
				var kind = GenJvm.getConstructionMode(hd.c, hd.cf);
				switch (kind) {
					case ConstructInitPlusNew if (jm.getName() == "<init>"):
						jm.loadThis();
						code.aconstNull(NativeSignatures.haxeEmptyConstructorSig);
						jm.callSuperCtor(ConstructInit,
							NativeSignatures.methodSig([NativeSignatures.haxeEmptyConstructorSig], null));
					case _:
				}
				jm.loadThis();
				var r = callArguments(hd.cf.type, el);
				jm.callSuperCtor(kind, NativeSignatures.methodSig(r.tl, null));
				tro = null;
			case TIdent("__lock__"):
				tro = lock(el);
			case _:
				handled = false;
		}
		if (!handled) {
			texpr(RValue(null, null), e1);
			var t = switch (e1.expr) {
				// A call through a local variable that has type parameters uses the general (unapplied)
				// type, which is
				// the variable's own type. Cases such as a Rest<T> argument need this.
				case TLocal(v) if (v.extra != null && v.extra.params != null
					&& v.extra.params.length != 0): v.type;
				case _: e1.type;
			};
			tro = invoke(t);
		}
		if (!GenJvm.needVal(ret)) {
			if (tro != null) code.popOp();
		} else {
			if (tro == null) throw "die";
			castTo(tr);
		}
	}

	function nativeArrayMake(tr:T, el:Array<TExpr>, e1:TExpr):Null<JSignature> {
		return switch (GenJvm.follow(tr)) {
			case TInst(c, [t]) if (isJavaNativeArrayPath(c.path)):
				var jsig = vtype(t);
				newNativeArray(jsig, el);
				NativeSignatures.arraySig(jsig);
			case _:
				throw new hxc.core.TypingError("Bad __array__ type", e1.pos);
		}
	}

	// __lock__ is a monitorenter with a handler that releases on any throw
	function lock(el:Array<TExpr>):Null<JSignature> {
		switch (el) {
			case [ea1, ea2]:
				texpr(RValue(null, null), ea1);
				code.dup();
				var acc = jm.addLocal("tmp", vtype(ea1.type), VarWillInit);
				acc.store();
				code.monitorenter();
				function fExit() {
					acc.load();
					code.monitorexit();
				}
				blockExits.unshift(ExitExecute(fExit));
				var fpFrom = code.getFp();
				texpr(RVoid, ea2);
				var termTry = jm.isTerminated();
				if (!jm.isTerminated()) fExit();
				var fpTo = code.getFp();
				var rTry = jm.maybeMakeJump();
				var fpTarget = code.getFp();
				var popScope = jm.pushScope();
				code.stack.push(NativeSignatures.throwableSig);
				jm.addStackFrame();
				jm.addException({
					excStartPc: fpFrom,
					excEndPc: fpTo,
					excHandlerPc: fpTarget,
					excCatchType: null
				});
				{
					var acc2 = jm.addLocal("tmp", NativeSignatures.throwableSig, VarWillInit);
					acc2.store();
					fExit();
					jm.addException({
						excStartPc: fpTarget,
						excEndPc: code.getFp(),
						excHandlerPc: fpTarget,
						excCatchType: null
					});
					acc2.load();
					code.athrow();
				}
				popScope();
				blockExits.shift();
				if (!termTry) jm.addStackFrame();
				jm.closeJumps(true, [{term: termTry, r: rTry}]);
				return null;
			case _:
				throw "die";
		}
	}

	static function isHaxeJvmJvm(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 2 && p.pack[0] == "haxe" && p.pack[1] == "jvm" && p.name == "Jvm";
	}

	static function isJavaLangMathPath(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang" && p.name == "Math";
	}

	static function isInt64Impl(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 1 && p.pack[0] == "haxe" && p.name == "Int64$Int64_Impl_";
	}

	static function isJavaNativeArrayPath(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 1 && p.pack[0] == "java" && p.name == "NativeArray";
	}

	static function isHaxeEnumTools(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 1 && p.pack[0] == "haxe" && p.name == "EnumTools";
	}

	static function isStringBufNoDescendants(c:TClass):Bool {
		return c.path.pack.length == 2 && c.path.pack[0] == "haxe" && c.path.pack[1] == "root"
			&& c.path.name == "StringBuf" && c.descendants.length == 0;
	}


	// The try body is one exception range, and every catch registers a handler over that same range.
	public function tryCatch(ret:Ret, e1:TExpr, catches:Array<TCatch>):Void {
		var restore = jm.startBranch();
		var fpFrom = code.getFp();
		var oldExceptions = caughtExceptions;
		var excl = [
			for (c in catches) {
				var exc = new HaxeException(gctx, c.v.type);
				caughtExceptions = [exc].concat(caughtExceptions);
				{exc: exc, v: c.v, e: c.expr};
			}
		];
		texpr(ret, e1);
		caughtExceptions = oldExceptions;
		var termTry = jm.isTerminated();
		var rTry = jm.maybeMakeJump();
		var fpTo = code.getFp();
		function startExceptionBlock(path:JPath, jsig:JSignature) {
			restore();
			var fpTarget = code.getFp();
			var offset = jc.getPool().addPath(path);
			jm.addException({
				excStartPc: fpFrom,
				excEndPc: fpTo,
				excHandlerPc: fpTarget,
				excCatchType: offset
			});
			code.stack.push(jsig);
			jm.addStackFrame();
		}
		function runCatchExpr(v:TVar, e:TExpr):Bool {
			var popScope = jm.pushScope();
			addLocal(v, VarWillInit).store();
			texpr(ret, e);
			popScope();
			return jm.isTerminated();
		}
		var rl = [];
		for (x in excl) {
			startExceptionBlock(x.exc.nativePath, x.exc.nativeType);
			var term = runCatchExpr(x.v, x.e);
			rl.unshift({term: term, r: jm.maybeMakeJump()});
		}
		jm.closeJumps(true, [{term: termTry, r: rTry}].concat(rl));
	}

	// Whatever the enclosing blocks have to run on the way out. A loop exit stops at the loop; a return
	// runs everything.
	public function emitBlockExits(isLoopExit:Bool):Void {
		for (x in blockExits) switch (x) {
			case ExitLoop:
				if (isLoopExit) return;
			case ExitExecute(f):
				f();
		}
	}


	// A constant is emitted in whatever width the consumer asked for, so an Int literal feeding a long
	// lands as lconst rather than iconst plus a widening cast.
	public function const(ret:Ret, t:T, ct:TConstant):Void {
		switch (ct) {
			case TInt(i):
				switch (ret) {
					case RValue(TLong, _): code.lconst(haxe.Int64.ofInt(i));
					case RValue(TObject(p, _), _) if (isBoxed(p, "Long")): code.lconst(haxe.Int64.ofInt(i));
					case RValue(TDouble, _): code.dconst(i);
					case RValue(TObject(p, _), _) if (isBoxed(p, "Double")): code.dconst(i);
					case _: code.iconst(i);
				}
			case TFloat(f):
				switch (ret) {
					case RValue(TFloat, _): code.fconst(hxc.core.Numeric.parseFloatLit(f));
					case RValue(TObject(p, _), _) if (isBoxed(p, "Float")): code.fconst(hxc.core.Numeric.parseFloatLit(f));
					case _: code.dconst(hxc.core.Numeric.parseFloatLit(f));
				}
			case TBool(b):
				code.bconst(b);
			case TNull:
				jm.loadDefaultValue(vtype(t));
			case TThis:
				getLocalById(0, "this").load();
			case TString(s):
				jm.string(s);
			case TSuper:
				throw "Invalid super access";
		}
	}

	static function isBoxed(p:JPath, name:String):Bool {
		return p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang" && p.name == name;
	}

	// An EReg literal is compiled once into a static field rather than on every evaluation.
	public function spawnCompiledPatternField(s1:String, s2:String) {
		var name = "_hx_pattern_" + JvmGlobals.patchName(jm.getName()) + "_" + jm.getNextRegexId();
		var jf = jc.spawnField(name, NativeSignatures.haxeCompiledPatternSig,
			[FieldAccessFlags.FdStatic, FieldAccessFlags.FdPrivate, FieldAccessFlags.FdFinal]);
		var jmInit = jc.getStaticInitMethod();
		jmInit.string(s1);
		jmInit.string(s2);
		jmInit.invokestatic(NativeSignatures.haxeEregPath, "compilePattern",
			NativeSignatures.methodSig([NativeSignatures.stringSig, NativeSignatures.stringSig],
				NativeSignatures.haxeCompiledPatternSig));
		jmInit.putstatic(jc.getThisPath(), jf.getName(), jf.getJsig());
		return jf;
	}

	public function texpr(ret:Ret, e:TExpr):Void {
		if (!jm.isTerminated()) texprInner(ret, e);
	}

	function texprInner(ret:Ret, e:TExpr):Void {
		code.setLine(hxc.generators.cpp.CppEmit.getErrorLine(e.pos));
		switch (e.expr) {
			case TVarExpr(v, e1) if (e1 != null):
				texpr(RValue(GenJvm.jsignatureOfType(gctx, v.type), v.name), e1);
				castTo(v.type);
				addLocal(v, VarWillInit).store();
			case TVarExpr(v, _):
				addLocal(v, VarNeedDefault);
			case TLocal(_) | TConst(_) | TTypeExpr(_) if (!GenJvm.needVal(ret)):
			case TLocal(v):
				getLocal(v).load();
			case TTypeExpr(mt):
				var t = TypeFunctions.typeOfModuleType(mt);
				if (isVoidType(GenJvm.follow(t))) jm.getBasicTypeClass("Void");
				else jm.getClass(GenJvm.jsignatureOfType(gctx, t));
			case TUnop(op, flag, e1):
				switch (op) {
					case Not | Neg | NegBits if (!GenJvm.needVal(ret)): texpr(ret, e1);
					case _: unop(ret, op, flag, e1);
				}
			case TBinop(OpAdd, e1, e2) if (GenJvm.isString(GenJvm.follow(e.type))):
				// String concatenation flattens into one StringBuilder rather than nesting.
				var sbPath:JPath = {pack: ["java", "lang"], name: "StringBuilder"};
				var sbSig = NativeSignatures.objectPathSig(sbPath);
				jm.construct(ConstructInit, sbPath, function() return []);
				function loop(e:TExpr) {
					switch (e.expr) {
						case TBinop(OpAdd, e1, e2) if (GenJvm.isString(GenJvm.follow(e.type))):
							loop(e1);
							loop(e2);
						case _:
							texpr(RValue(null, null), e);
							var jsig = switch (code.stack.top()) {
								case t = TByte | TBool | TChar | TShort | TInt | TLong: t;
								case TFloat | TDouble:
									// Haxe prints 2.0 as 2, so a float goes through Jvm.toString rather
									// than StringBuilder.append.
									jm.expectReferenceType();
									jm.invokestatic(NativeSignatures.haxeJvmPath, "toString",
										NativeSignatures.methodSig([NativeSignatures.objectSig],
											NativeSignatures.stringSig));
									NativeSignatures.stringSig;
								case _:
									NativeSignatures.objectSig;
							};
							jm.invokevirtual(sbPath, "append", NativeSignatures.methodSig([jsig], sbSig));
					}
				}
				loop(e1);
				loop(e2);
				jm.invokevirtual(sbPath, "toString",
					NativeSignatures.methodSig([], NativeSignatures.stringSig));
			case TBinop(op, e1, e2):
				switch (op) {
					case OpAssign | OpAssignOp(_):
						binop(ret, op, e1, e2);
					case _ if (!GenJvm.needVal(ret)):
						texpr(ret, e1);
						texpr(ret, e2);
					case _:
						binop(ret, op, e1, e2);
				}
			case TConst(ct):
				const(ret, e.type, ct);
			case TIf(e1, e2, null):
				jm.ifThenLabeled(function(lt, le) condition(false, e1, lt, le),
					function() texpr(RVoid, TypeFunctions.mkBlock(e2)));
			case TIf(e1, e2, e3):
				jm.ifThenElseLabeled(function(lt, le) condition(false, e1, lt, le), function() {
					texpr(ret, TypeFunctions.mkBlock(e2));
					if (GenJvm.needVal(ret)) castTo(e.type);
				}, function() {
					texpr(ret, TypeFunctions.mkBlock(e3));
					if (GenJvm.needVal(ret)) castTo(e.type);
				});
			case TSwitch(e1, cases, def):
				switchExpr(ret, e1, cases, def);
			case TWhile(e1, e2, flag):
				blockExits.unshift(ExitLoop);
				var isTrueLoop = switch (TexprTools.skip(e1).expr) {
					case TConst(TBool(true)): true;
					case _: false;
				};
				var continueLabel2 = jm.spawnLabel("continue");
				var breakLabel2 = jm.spawnLabel("break");
				var bodyLabel = jm.spawnLabel("body");
				var restore = jm.startBranch();
				if (flag == DoWhile) {
					bodyLabel.goto();
					restore();
				}
				var oldContinue = continueLabel;
				continueLabel = continueLabel2;
				var oldBreak = breakLabel;
				breakLabel = breakLabel2;
				continueLabel2.here();
				if (!isTrueLoop) condition(false, e1, bodyLabel, breakLabel2);
				var popScope = jm.pushScope();
				bodyLabel.here();
				texpr(RVoid, e2);
				if (!jm.isTerminated()) continueLabel2.goto();
				popScope();
				restore();
				// A while(true) that nothing breaks out of never falls through.
				if (breakLabel2.wasJumpedTo() || !isTrueLoop) breakLabel2.here();
				else jm.setTerminated(true);
				continueLabel = oldContinue;
				breakLabel = oldBreak;
				blockExits.shift();
			case TBreak:
				emitBlockExits(true);
				if (breakLabel == null) throw "break outside loop";
				breakLabel.goto();
			case TContinue:
				emitBlockExits(true);
				if (continueLabel == null) throw "continue outside loop";
				continueLabel.goto();
			case TTry(e1, catches):
				tryCatch(ret, e1, catches);
			case TField(e1, fa):
				if (!GenJvm.needVal(ret)) texpr(ret, e1);
				else read(function() castExpect(ret, e.type), e1, fa);
			case TCall(e1, el):
				call(ret, e.type, e1, el);
			case TNew(c, [t], [e1]) if (isJavaNativeArrayPath(c.path)):
				texpr(GenJvm.needVal(ret) ? RValue(null, null) : RVoid, e1);
				// An unused allocation is skipped, even though it could throw for a negative size.
				if (GenJvm.needVal(ret))
					NativeArray.create(code, jc.getPool(), GenJvm.jsignatureOfType(gctx, t));
			case TNew(c, [], [{expr: TConst(TString(s1))}, {expr: TConst(TString(s2))}])
				if (isHaxeRootEReg(c.path) && jm != jc.getStaticInitMethod()):
				var jf = spawnCompiledPatternField(s1, s2);
				jm.construct(ConstructInit, NativeSignatures.haxeEregPath, function() {
					jm.getstatic(jc.getThisPath(), jf.getName(), jf.getJsig());
					return [jf.getJsig()];
				});
			case TNew(c, tl, el):
				switch (OverloadResolution.maybeResolveConstructorOverload(c, tl, el)) {
					case null:
						throw new hxc.core.TypingError("Could not find overload", e.pos);
					case r:
						jm.construct(GenJvm.getConstructionMode(r.c, r.cf), c.path,
							function() return callArguments(r.cf.type, el).tl, !GenJvm.needVal(ret));
				}
			case TReturn(null):
				emitBlockExits(false);
				jm.returnOp();
			case TReturn(e1):
				texpr(RValue(null, null), e1);
				if (!jm.isTerminated()) {
					if (returnType == null) throw "Option.get";
					jm.castTo(returnType);
					emitBlockExits(false);
					jm.returnOp();
				}
			case TFunction(tf):
				tfunction(ret, e, tf);
			case TArrayDecl(el) if (!GenJvm.needVal(ret)):
				for (e in el) texpr(ret, e);
			case TArrayDecl(el):
				switch (GenJvm.follow(e.type)) {
					case TInst(c, [t]) if (isHaxeRootArray(c.path)):
						newNativeArray(GenJvm.jsignatureOfType(gctx, mknull(t)), el);
						jm.invokestatic({pack: ["haxe", "root"], name: "Array"}, "ofNative",
							NativeSignatures.methodSig([NativeSignatures.arraySig(NativeSignatures.objectSig)],
								NativeSignatures.objectPathSig({pack: ["haxe", "root"], name: "Array"})));
						castTo(e.type);
					case _:
						throw "die";
				}
			case TArray(e1, e2) if (!GenJvm.needVal(ret)):
				// An unused array read is dropped and only its operands are evaluated; reading a Haxe Array
				// does not
				// throw.
				texpr(ret, e1);
				texpr(ret, e2);
			case TArray(e1, e2):
				switch (GenJvm.follow(e1.type)) {
					case TInst(c, [t]) if (isHaxeRootArray(c.path)):
						texpr(RValue(null, null), e1);
						texpr(RValue(TInt, null), e2);
						jm.castTo(TInt);
						jm.invokevirtual(c.path, "__get",
							NativeSignatures.methodSig([TInt], NativeSignatures.objectSig));
						castTo(e.type);
					case TInst(c, [t]) if (isJavaNativeArrayPath(c.path)):
						texpr(RValue(null, null), e1);
						var vt = vtype(e1.type);
						var vte = vtype(t);
						texpr(RValue(null, null), e2);
						readNativeArray(vt, vte);
					case _:
						texpr(RValue(null, null), e1);
						texpr(RValue(null, null), e2);
						jm.castTo(TInt);
						jm.invokestatic(NativeSignatures.haxeJvmPath, "arrayRead",
							NativeSignatures.methodSig([NativeSignatures.objectSig, TInt],
								NativeSignatures.objectSig));
						castTo(e.type);
				}
			case TBlock([]):
				if (Type.enumEq(ret, RReturn) && !jm.isTerminated()) jm.returnOp();
			case TBlock(el):
				var popScope = jm.pushScope();
				for (i in 0...el.length) {
					if (i == el.length - 1) {
						texpr(ret, el[i]);
						if (Type.enumEq(ret, RReturn) && !jm.isTerminated()) jm.returnOp();
					} else {
						texpr(RVoid, el[i]);
					}
				}
				popScope();
			case TCast(e1, null):
				texpr(ret, e1);
				if (GenJvm.needVal(ret)) castTo(e.type);
			case TCast(e1, mt):
				texpr(RValue(null, null), e1);
				var jsig = GenJvm.jsignatureOfType(gctx, TypeFunctions.typeOfModuleType(mt));
				if (NativeSignatures.isUnboxed(jsig) || NativeSignatures.isUnboxed(code.stack.top()))
					jm.castTo(jsig);
				else code.checkcast(TypeFunctions.tInfos(mt).path);
				if (!GenJvm.needVal(ret)) code.popOp();
			case TParenthesis(e1):
				texpr(ret, e1);
			case TMeta(_, e1):
				texpr(ret, e1);
			case TFor(v, e1, e2):
				texpr(ret, hxc.optimization.AnalyzerTexpr.TexprFilter.forRemap(com.basic, v, e1, e2, e.pos));
			case TEnumIndex(e1):
				texpr(RValue(null, null), e1);
				jm.invokevirtual(NativeSignatures.javaEnumPath, "ordinal",
					NativeSignatures.methodSig([], TInt));
			case TEnumParameter(e1, ef, i):
				texpr(RValue(null, null), e1);
				var path, name, jsigArg;
				switch (GenJvm.follow(ef.type)) {
					case TFun(sig):
						var en = switch (GenJvm.follow(sig.ret)) {
							case TEnum(en, _): en;
							case _: throw "die";
						};
						path = en.path;
						name = sig.args[i].name;
						jsigArg = vtype(sig.args[i].t);
					case _:
						throw "die";
				}
				// Each enum constructor is its own class, named Enum$Ctor.
				var cpath:JPath = {pack: path.pack, name: path.name + "$" + ef.name};
				var jsig = NativeSignatures.objectPathSig(cpath);
				jm.castTo(jsig);
				jm.getfield(cpath, name, jsigArg);
				castTo(e.type);
			case TThrow(e1):
				texpr(RValue(null, null), e1);
				// Evaluating the operand can already terminate the code (as in `throw throw e`), and then
				// no athrow is
				// emitted.
				if (!jm.isTerminated()) {
					if (!Exceptions.isHaxeException(e1.type)
						&& !TypeUnification.doesUnify(e1.type, gctx.runtimeException)) {
						var exc = new HaxeException(gctx, e1.type);
						var covered = false;
						for (exc2 in caughtExceptions) if (exc.isAssignableTo(exc2)) {
							covered = true;
							break;
						}
						if (!covered) jm.addThrownException(exc.nativePath);
					}
					code.athrow();
					jm.setTerminated(true);
				}
			case TObjectDecl(fl):
				objectDecl(fl);
			case TIdent(_):
				throw new hxc.core.TypingError("Invalid identifier", e.pos);
		}
	}

	// An object literal whose shape anonIdentification knows, and whose field names are all valid
	// identifiers, becomes a construction of that class; anything else becomes a haxe.jvm.DynamicObject
	// filled field by field.
	function objectDecl(fl:Array<TObjectField>):Void {
		var hadInvalidFieldName = false;
		// The literal's own type may have optional fields, so a closed anonymous type is built from the
		// fields
		// actually present.
		var fields = new StringMap();
		for (f in fl) {
			var cf = TypeFunctions.mkField(f.key.name, f.expr.type, f.expr.pos, f.expr.pos);
			if (!hxc.core.StringHelper.isValidIdentifier(f.key.name)) hadInvalidFieldName = true;
			fields.set(f.key.name, cf);
		}
		var t = TypeFunctions.mkAnon(new Ref(AnonStatus.Closed), fields);
		var pfm = gctx.anonIdentification.identify(true, t);
		if (pfm != null && !hadInvalidFieldName) {
			var lut = new StringMap<Void->Void>();
			jm.construct(ConstructInit, pfm.pfmPath, function() {
				// Step 1: evaluate the field expressions in source order, into temporaries unless they are
				// constants,
				// type expressions or functions.
				for (f in fl) {
					var jsig = vtype(f.expr.type);
					var load = switch (TexprTools.skip(f.expr).expr) {
						case TConst(_) | TTypeExpr(_) | TFunction(_):
							var e = f.expr;
							function() texpr(RValue(null, null), e);
						case _:
							var acc = jm.addLocal("_hx_tmp_" + f.key.name, jsig, VarWillInit);
							texpr(RValue(null, null), f.expr);
							acc.store();
							acc.load;
					};
					lut.set(f.key.name, load);
				}
				// Step 2: load the fields in constructor argument order, which is sorted by name.
				var order = fl.copy();
				order.sort(function(a, b) return a.key.name < b.key.name ? -1 : (a.key.name > b.key.name ? 1 : 0));
				return [
					for (f in order) {
						lut.get(f.key.name)();
						var jsig = vtype(pfm.pfmFields.get(f.key.name).type);
						jm.castTo(jsig);
						jsig;
					}
				];
			});
		} else {
			jm.construct(ConstructInit, NativeSignatures.haxeDynamicObjectPath, function() return []);
			for (f in fl) {
				code.dup();
				jm.string(f.key.name);
				texpr(RValue(null, null), f.expr);
				expectReferenceType();
				jm.invokevirtual(NativeSignatures.haxeDynamicObjectPath, "_hx_setField",
					NativeSignatures.methodSig([NativeSignatures.stringSig, NativeSignatures.objectSig],
						null));
			}
		}
	}

	static function isVoidType(t:T):Bool {
		return switch (t) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		}
	}

	static function isHaxeRootEReg(p:hxc.core.Globals.Path):Bool {
		return p.pack.length == 2 && p.pack[0] == "haxe" && p.pack[1] == "root" && p.name == "EReg";
	}


	public function objectConstructor():Void {
		var path = jc.getSuperPath();
		var offset = jc.getPool().addField(path, "<init>", NativeSignatures.methodSig([], null), FKMethod);
		jm.loadThis();
		code.invokespecial(offset, jc.getJsig(), [], []);
		jm.setThisInitialized();
	}
}
