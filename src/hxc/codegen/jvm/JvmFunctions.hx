package hxc.codegen.jvm;

import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmSignature;
import hxc.codegen.jvm.JvmBuilder;
import hxc.codegen.jvm.JvmMethod;
import hxc.codegen.jvm.JvmClass;

// the function objects a closure becomes. Signatures are classified down to the shapes the runtime actually
// has, and each one forwards to the next more general shape until everything is Object.

enum SignatureClassification {
	CByte;
	CChar;
	CDouble;
	CFloat;
	CInt;
	CLong;
	CShort;
	CBool;
	CObject;
}

typedef MethodSignatureInfo = {
	arity:Int,
	name:String,
	hasNonobject:Bool,
	sortString:String,
	cargs:Array<SignatureClassification>,
	cret:Null<SignatureClassification>,
	dargs:Array<JSignature>,
	dret:Null<JSignature>,
	?next:MethodSignatureInfo,
};

enum TypedFunctionKind {
	FuncLocal(name:Null<String>);
	FuncMember(path:JPath, name:String);
	FuncStatic(path:JPath, name:String);
}

class JvmFunctions {
	public static function stringOfClassification(c:SignatureClassification):String {
		return switch (c) {
			case CByte: "Byte"; case CChar: "Char"; case CDouble: "Double"; case CFloat: "Float";
			case CInt: "Int"; case CLong: "Long"; case CShort: "Short"; case CBool: "Bool";
			case CObject: "Object";
		}
	}

	public static function classify(jsig:JSignature):SignatureClassification {
		return switch (jsig) {
			case TByte: CByte;
			case TChar: CChar;
			case TDouble: CDouble;
			case TFloat: CFloat;
			case TInt: CInt;
			case TLong: CLong;
			case TShort: CShort;
			case TBool: CBool;
			case TObject(_, _) | TObjectInner(_, _) | TArray(_, _) | TMethod(_, _)
				| TTypeParameter(_) | TUninitialized(_): CObject;
		}
	}

	public static function declassify(c:SignatureClassification):JSignature {
		return switch (c) {
			case CByte: TByte; case CChar: TChar; case CDouble: TDouble; case CFloat: TFloat;
			case CInt: TInt; case CLong: TLong; case CShort: TShort; case CBool: TBool;
			case CObject: NativeSignatures.objectPathSig(NativeSignatures.objectPath);
		}
	}
}

class TypedFunctions {
	var signatures:Map<String, MethodSignatureInfo> = new Map();
	var maxArity = 0;

	public function new() {}

	public function registerSignature(tl:Array<JSignature>, tr:Null<JSignature>):MethodSignatureInfo {
		return getSignature([for (t in tl) JvmFunctions.classify(t)],
			tr == null ? null : JvmFunctions.classify(tr));
	}

	public function objectify(meth:MethodSignatureInfo):MethodSignatureInfo {
		return getSignature([for (_ in meth.cargs) CObject], meth.cret);
	}

	static function key(cl:Array<SignatureClassification>, cr:Null<SignatureClassification>):String {
		return [for (c in cl) JvmFunctions.stringOfClassification(c)].join(",")
			+ "|" + (cr == null ? "CVoid" : JvmFunctions.stringOfClassification(cr));
	}

	function getSignature(cl:Array<SignatureClassification>, cr:Null<SignatureClassification>):MethodSignatureInfo {
		var found = signatures.get(key(cl, cr));
		return found != null ? found : doRegisterSignature(cl, cr);
	}

	// a signature with anything other than Object forwards to the all Object one; otherwise a non-Object
	// return forwards to the Object returning one.
	function doRegisterSignature(cl:Array<SignatureClassification>, cr:Null<SignatureClassification>):MethodSignatureInfo {
		var hasNonobject = false;
		for (c in cl) if (c != CObject) { hasNonobject = true; break; }
		var meth:MethodSignatureInfo = {
			arity: cl.length,
			name: "invoke",
			hasNonobject: hasNonobject,
			sortString: "[" + [for (c in cl) JvmFunctions.stringOfClassification(c)].join(", ") + "] "
				+ (cr == null ? "CVoid" : JvmFunctions.stringOfClassification(cr)),
			cargs: cl,
			cret: cr,
			dargs: [for (c in cl) JvmFunctions.declassify(c)],
			dret: cr == null ? null : JvmFunctions.declassify(cr),
			next: null
		};
		if (meth.arity > maxArity) maxArity = meth.arity;
		signatures.set(key(meth.cargs, meth.cret), meth);
		if (meth.hasNonobject)
			meth.next = objectify(meth);
		else if (cr != CObject)
			meth.next = getSignature(meth.cargs, CObject);
		return meth;
	}

	public function getMaxArity():Int return maxArity;

	// each argument is cast on the way through, a missing one takes its default, and a surplus return value
	// is popped.
	public function makeForwardMethodJsig(jc:ClassBuilder, jm:MethodBuilder, name:String,
			argsFrom:Array<JSignature>, retFrom:Null<JSignature>,
			argsTo:Array<JSignature>, retTo:Null<JSignature>):Void {
		var args = [for (i in 0...argsFrom.length) jm.addLocal("arg" + i, argsFrom[i], VarArgument)];
		jm.finalizeArguments();
		jm.loadThis();
		for (i in 0...argsTo.length) {
			if (i < args.length) {
				args[i].load();
				jm.castTo(argsTo[i]);
			} else
				jm.loadDefaultValue(argsTo[i]);
		}
		jm.invokevirtual(jc.getThisPath(), name, NativeSignatures.methodSig(argsTo, retTo));
		if (retFrom != null && retTo != null) jm.castTo(retFrom);
		else if (retFrom == null && retTo != null) jm.getCode().popOp();
		else if (retFrom != null && retTo == null) jm.loadDefaultValue(retFrom);
		jm.returnOp();
	}

	public function makeForwardMethod(jc:ClassBuilder, jm:MethodBuilder,
			methFrom:MethodSignatureInfo, methTo:MethodSignatureInfo):Void {
		makeForwardMethodJsig(jc, jm, methTo.name, methFrom.dargs, methFrom.dret, methTo.dargs, methTo.dret);
	}

	// dispatch on the argument count to the invoke of that arity.
	public function generateInvokeDynamic(jc:ClassBuilder):Void {
		var arraySig:JSignature = TArray(NativeSignatures.objectSig, null);
		var jm = jc.spawnMethod("invokeDynamic",
			NativeSignatures.methodSig([arraySig], NativeSignatures.objectSig), [MethodAccessFlags.MPublic]);
		var args = jm.addLocal("args", arraySig, VarArgument);
		jm.finalizeArguments();
		args.load();
		jm.getCode().arraylength(arraySig);
		var cases = [
			for (i in 0...maxArity) {
				values: [i],
				f: function() {
					jm.loadThis();
					var sigs = [
						for (index in 0...i) {
							args.load();
							jm.getCode().iconst(index);
							jm.getCode().aaload(arraySig, NativeSignatures.objectSig);
							NativeSignatures.objectSig;
						}
					];
					jm.invokevirtual(jc.getThisPath(), "invoke",
						NativeSignatures.methodSig(sigs, NativeSignatures.objectSig));
					jm.returnOp();
				}
			}
		];
		jm.intSwitch(true, cases, function() {
			jm.construct(ConstructInit, {pack: ["java", "lang"], name: "IllegalArgumentException"}, function() return []);
			jm.getCode().athrow();
			jm.setTerminated(true);
		});
	}

	public function generateClosureDispatch():ClassBuilder {
		var jc = new ClassBuilder({pack: ["haxe", "jvm"], name: "ClosureDispatch"}, NativeSignatures.haxeFunctionPath);
		jc.addAccessFlag(1);
		var jmCtor = jc.spawnMethod("<init>", NativeSignatures.methodSig([], null), [MethodAccessFlags.MPublic]);
		jmCtor.finalizeArguments();
		jmCtor.loadThis();
		jmCtor.callSuperCtor(ConstructInit, NativeSignatures.methodSig([], null));
		jmCtor.returnOp();
		var args:Array<JSignature> = [];
		var i = 0;
		while (true) {
			var jm = jc.spawnMethod("invoke", NativeSignatures.methodSig(args, NativeSignatures.objectSig),
				[MethodAccessFlags.MPublic]);
			var vars = [for (k in 0...i) jm.addLocal("arg" + k, NativeSignatures.objectSig, VarArgument)];
			jm.loadThis();
			jm.newNativeArray(NativeSignatures.objectSig, [for (v in vars) function() v.load()]);
			jm.invokevirtual(NativeSignatures.haxeFunctionPath, "invokeDynamic",
				NativeSignatures.methodSig([NativeSignatures.arraySig(NativeSignatures.objectSig)], NativeSignatures.objectSig));
			jm.returnOp();
			if (i >= maxArity) break;
			args = [NativeSignatures.objectSig].concat(args);
			i++;
		}
		return jc;
	}

	public function generateVarArgs():ClassBuilder {
		var jc = new ClassBuilder({pack: ["haxe", "jvm"], name: "VarArgs"}, NativeSignatures.haxeFunctionPath);
		jc.addAccessFlag(1);
		var jmCtor = jc.spawnMethod("<init>", NativeSignatures.methodSig([NativeSignatures.haxeFunctionSig], null),
			[MethodAccessFlags.MPublic]);
		jmCtor.addArgumentAndField("func", NativeSignatures.haxeFunctionSig,
			[FieldAccessFlags.FdPublic, FieldAccessFlags.FdFinal]);
		jmCtor.finalizeArguments();
		jmCtor.loadThis();
		jmCtor.callSuperCtor(ConstructInit, NativeSignatures.methodSig([], null));
		jmCtor.returnOp();
		var haxeArrayPath:JPath = {pack: ["haxe", "root"], name: "Array"};
		var args:Array<JSignature> = [];
		var i = 0;
		while (true) {
			var jm = jc.spawnMethod("invoke", NativeSignatures.methodSig(args, NativeSignatures.objectSig),
				[MethodAccessFlags.MPublic, MethodAccessFlags.MBridge, MethodAccessFlags.MSynthetic]);
			var vars = [for (k in 0...i) jm.addLocal("arg" + k, NativeSignatures.objectSig, VarArgument)];
			jm.loadThis();
			jm.getfield(jc.getThisPath(), "func", NativeSignatures.haxeFunctionSig);
			jm.newNativeArray(NativeSignatures.objectSig, [for (v in vars) function() v.load()]);
			jm.invokestatic(haxeArrayPath, "ofNative",
				NativeSignatures.methodSig([NativeSignatures.arraySig(NativeSignatures.objectSig)],
					NativeSignatures.objectPathSig(haxeArrayPath)));
			jm.invokevirtual(NativeSignatures.haxeFunctionPath, "invoke",
				NativeSignatures.methodSig([NativeSignatures.objectSig], NativeSignatures.objectSig));
			jm.returnOp();
			if (i >= maxArity) break;
			args = [NativeSignatures.objectSig].concat(args);
			i++;
		}
		return jc;
	}

	// the function class itself, one invoke per registered shape, each forwarding to the next until the
	// all-Object one.
	public function generate():ClassBuilder {
		var l = [for (v in signatures) v];
		l.sort(function(a, b) {
			if (a.arity != b.arity) return a.arity < b.arity ? -1 : 1;
			return a.sortString < b.sortString ? -1 : (a.sortString > b.sortString ? 1 : 0);
		});
		var jc = new ClassBuilder(NativeSignatures.haxeFunctionPath, NativeSignatures.objectPath);
		jc.addAccessFlag(1);
		for (meth in l) {
			var jm = jc.spawnMethod(meth.name, NativeSignatures.methodSig(meth.dargs, meth.dret),
				[MethodAccessFlags.MPublic, MethodAccessFlags.MBridge, MethodAccessFlags.MSynthetic]);
			if (meth.next != null)
				makeForwardMethod(jc, jm, meth, meth.next);
			else if (meth.arity < maxArity && !meth.hasNonobject)
				makeForwardMethod(jc, jm, meth, getSignature([CObject].concat(meth.cargs), meth.cret));
			else {
				for (i in 0...meth.dargs.length) jm.addLocal("arg" + i, meth.dargs[i], VarArgument);
				jm.finalizeArguments();
				if (meth.dret != null) jm.loadDefaultValue(meth.dret);
				jm.returnOp();
			}
		}
		var jmCtor = jc.spawnMethod("<init>", NativeSignatures.methodSig([], null), [MethodAccessFlags.MPublic]);
		jmCtor.loadThis();
		jmCtor.callSuperCtor(ConstructInit, NativeSignatures.methodSig([], null));
		jmCtor.returnOp();
		generateInvokeDynamic(jc);
		return jc;
	}
}

// the java interfaces a haxe function can be handed to directly.
typedef JavaFunctionalInterface = {
	jargs:Array<JSignature>,
	jret:Null<JSignature>,
	jpath:JPath,
	jname:String,
	jparams:Array<String>,
};

class JavaFunctionalInterfaces {
	public static var all(default, null):Array<JavaFunctionalInterface> = [];

	public static function add(args:Array<JSignature>, ret:Null<JSignature>, path:JPath, name:String,
			params:Array<String>):Void {
		all.push({jargs: args, jret: ret, jpath: path, jname: name, jparams: params});
	}

	// a type parameter takes whatever the caller has, boxed; anything else has to match exactly.
	public static function unify(jfi:JavaFunctionalInterface, args:Array<JSignature>,
			ret:Null<JSignature>):Null<{jfi:JavaFunctionalInterface, params:Array<JTypeArgument>}> {
		function loop(params:Array<{name:String, t:JSignature}>, want:Array<JSignature>,
				have:Array<JSignature>):Null<{jfi:JavaFunctionalInterface, params:Array<JTypeArgument>}> {
			if (want.length == 0 && have.length == 0) {
				var out = [];
				for (p in jfi.jparams) {
					var found = null;
					for (e in params) if (e.name == p) { found = e.t; break; }
					// An unbound type parameter throws NotFound rather than returning null. The exception
					// escapes findCompatible and is caught by checkFunctionalInterfaces in
					// TypedFunction.generateInvoke, so no functional interface at all is attached for this
					// signature, instead of only this candidate being skipped.
					if (found == null) throw new hxc.core.NotFound();
					out.push(TType(WNone, found));
				}
				return {jfi: jfi, params: out};
			}
			if (want.length == 0 || have.length == 0) return null;
			var want1 = want[0];
			var have1 = have[0];
			return switch (want1) {
				case TTypeParameter(n):
					loop([{name: n, t: NativeSignatures.getBoxedType(have1)}].concat(params), want.slice(1), have.slice(1));
				case _:
					!JvmSignature.eq(have1, want1) ? null : loop(params, want.slice(1), have.slice(1));
			}
		}
		if (jfi.jret == null && ret == null) return loop([], jfi.jargs, args);
		if (jfi.jret != null && ret != null) {
			return switch (jfi.jret) {
				case TTypeParameter(n):
					loop([{name: n, t: NativeSignatures.getBoxedType(ret)}], jfi.jargs, args);
				case jsig1:
					!JvmSignature.eq(jsig1, ret) ? null : loop([], jfi.jargs, args);
			}
		}
		return null;
	}

	public static function findCompatible(args:Array<JSignature>, ret:Null<JSignature>,
			filter:Array<JPath>):Array<{jfi:JavaFunctionalInterface, params:Array<JTypeArgument>}> {
		var acc = [];
		for (jfi in all) {
			var pass = filter.length == 0;
			if (!pass) for (p in filter) if (JvmSignature.samePath(p, jfi.jpath)) { pass = true; break; }
			if (!pass) continue;
			if (jfi.jparams.length == 0) {
				if (sameSigs(jfi.jargs, args) && sameRet(jfi.jret, ret)) acc.unshift({jfi: jfi, params: []});
			} else {
				var r = unify(jfi, args, ret);
				if (r != null) acc.unshift(r);
			}
		}
		return acc;
	}

	static function sameSigs(a:Array<JSignature>, b:Array<JSignature>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (!JvmSignature.eq(a[i], b[i])) return false;
		return true;
	}

	static function sameRet(a:Null<JSignature>, b:Null<JSignature>):Bool {
		if (a == null || b == null) return a == null && b == null;
		return JvmSignature.eq(a, b);
	}
}

// one closure, as an inner class of whatever declared it.
class TypedFunction {
	var functions:TypedFunctions;
	var jcClosure:ClassBuilder;

	public function new(functions:TypedFunctions, kind:TypedFunctionKind, hostClass:ClassBuilder,
			hostMethod:MethodBuilder, context:Array<{name:String, jsig:JSignature}>) {
		this.functions = functions;
		this.context = context;
		var name = switch (kind) {
			case FuncLocal(s):
				var n = JvmGlobals.patchName(hostMethod.getName());
				if (s != null) n = n + "_" + s;
				"Closure_" + n + "_" + hostClass.getNextClosureId(n);
			case FuncStatic(path, name) | FuncMember(path, name):
				path.name + "_" + JvmGlobals.patchName(name);
		};
		jcClosure = hostClass.spawnInnerClass(null, NativeSignatures.haxeFunctionPath, name);
		jcClosure.addAccessFlag(0x10);
	}

	var context:Array<{name:String, jsig:JSignature}>;

	public function getClassBuilder():ClassBuilder return jcClosure;

	// the captured values become final fields set from the constructor.
	public function generateConstructor(isPublic:Bool):MethodBuilder {
		var contextSigs = [for (c in context) c.jsig];
		var jmCtor = jcClosure.spawnMethod("<init>", NativeSignatures.methodSig(contextSigs, null),
			isPublic ? [MethodAccessFlags.MPublic] : []);
		for (c in context)
			jmCtor.addArgumentAndField(c.name, c.jsig, [FieldAccessFlags.FdPublic, FieldAccessFlags.FdFinal]);
		jmCtor.loadThis();
		jmCtor.callSuperCtor(ConstructInit, NativeSignatures.methodSig([], null));
		jmCtor.returnOp();
		return jmCtor;
	}

	// the invoke of this exact shape, plus a bridge to each more general shape up the chain, plus one per
	// java interface the shape happens to satisfy.
	public function generateInvoke(args:Array<{name:String, jsig:JSignature}>, ret:Null<JSignature>,
			functionalInterfaceFilter:Array<JPath>):MethodBuilder {
		var argSigs = [for (a in args) a.jsig];
		var meth = functions.registerSignature(argSigs, ret);
		var jmInvoke = jcClosure.spawnMethod(meth.name, NativeSignatures.methodSig(argSigs, ret),
			[MethodAccessFlags.MPublic]);
		var implemented:Map<String, Bool> = new Map();
		function addInterface(path:JPath, params:Array<JTypeArgument>) {
			var k = path.pack.join("/") + "/" + path.name;
			if (!implemented.exists(k)) {
				jcClosure.addInterface(path, params);
				implemented.set(k, true);
			}
		}
		function spawnForwardFunction(methFrom:MethodSignatureInfo, methTo:MethodSignatureInfo, isBridge:Bool) {
			var msig = NativeSignatures.methodSig(methFrom.dargs, methFrom.dret);
			if (!jcClosure.hasMethod(methFrom.name, msig)) {
				var flags = isBridge
					? [MethodAccessFlags.MBridge, MethodAccessFlags.MSynthetic, MethodAccessFlags.MPublic]
					: [MethodAccessFlags.MPublic];
				var jmNext = jcClosure.spawnMethod(methFrom.name, msig, flags);
				functions.makeForwardMethod(jcClosure, jmNext, methFrom, methTo);
			}
		}
		function checkFunctionalInterfaces(m:MethodSignatureInfo) {
			// a NotFound from JavaFunctionalInterfaces.unify abandons the whole find-and-attach for this
			// signature
			try {
				for (e in JavaFunctionalInterfaces.findCompatible(m.dargs, m.dret, functionalInterfaceFilter)) {
					addInterface(e.jfi.jpath, e.params);
					spawnForwardFunction({
						arity: m.arity, name: e.jfi.jname, hasNonobject: m.hasNonobject, sortString: m.sortString,
						cargs: m.cargs, cret: m.cret, dargs: m.dargs, dret: m.dret, next: m.next
					}, m, false);
				}
			} catch (_:hxc.core.NotFound) {}
		}
		function loop(m:MethodSignatureInfo) {
			checkFunctionalInterfaces(m);
			if (m.next != null) {
				spawnForwardFunction(m.next, m, true);
				loop(m.next);
			}
		}
		// the declared signature may differ from the classified one at run time, and then it is
		// the declared one that forwards to it
		var returnDiffers = if (meth.dret == null && ret == null) false
			else if (meth.dret != null && ret != null) !JvmSignature.equalsAtRuntime(meth.dret, ret)
			else true;
		var argsDiffer = meth.dargs.length != argSigs.length;
		if (!argsDiffer)
			for (i in 0...meth.dargs.length)
				if (!JvmSignature.equalsAtRuntime(meth.dargs[i], argSigs[i])) { argsDiffer = true; break; }
		if (argsDiffer || returnDiffers) {
			meth = {
				arity: meth.arity, name: meth.name, hasNonobject: meth.hasNonobject, sortString: meth.sortString,
				cargs: meth.cargs, cret: meth.cret, dargs: argSigs, dret: ret, next: meth
			};
		}
		loop(meth);
		return jmInvoke;
	}
}
