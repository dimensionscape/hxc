package hxc.codegen.jvm;

import hxc.core.Ref;
import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmData;
import hxc.codegen.jvm.JvmSignature;
import hxc.codegen.jvm.JvmAttribute;
import hxc.codegen.jvm.JvmBuilder;
import hxc.codegen.jvm.JvmCode;
import hxc.codegen.jvm.JvmVerificationTypeInfo;
import hxc.codegen.jvm.JvmClass;

// Emitting a method. Locals live in scopes, and a stack frame is recorded at every branch target so the
// verifier can be handed a StackMapTable.

enum VarInitState {
	VarArgument;
	VarWillInit;
	VarNeedDefault;
}

enum ConstructionKind {
	ConstructInitPlusNew;
	ConstructInit;
}

typedef JvmLocal = {init:Ref<Null<Int>>, name:String, t:JSignature};
typedef DebugLocal = {fp:Int, length:Int, name:String, jsig:JSignature, index:Int};
typedef StackFrameEntry = {offset:Int, locals:Array<VerificationTypeInfo>, stack:Array<VerificationTypeInfo>};

class NativeArray {
	public static function read(code:CodeBuilder, ja:JSignature, je:JSignature):Void {
		switch (je) {
			case TBool: code.baload(TBool, ja);
			case TByte: code.baload(TByte, ja);
			case TChar: code.caload(ja);
			case TDouble: code.daload(ja);
			case TFloat: code.faload(ja);
			case TInt: code.iaload(ja);
			case TLong: code.laload(ja);
			case TShort: code.saload(ja);
			case _: code.aaload(ja, je);
		}
	}

	public static function write(code:CodeBuilder, ja:JSignature, je:JSignature):Void {
		switch (je) {
			case TBool: code.bastore(TBool, ja);
			case TByte: code.bastore(TByte, ja);
			case TChar: code.castore(ja);
			case TDouble: code.dastore(ja);
			case TFloat: code.fastore(ja);
			case TInt: code.iastore(ja);
			case TLong: code.lastore(ja);
			case TShort: code.sastore(ja);
			case _: code.aastore(ja, je);
		}
	}

	// Primitive element types are allocated by newarray with their own type code; everything else by
	// anewarray.
	public static function create(code:CodeBuilder, pool:JvmConstantPool, je:JSignature):JSignature {
		var ja:JSignature = TArray(je, null);
		inline function primitive(i:Int) code.newarray(ja, i);
		inline function reference(path:JPath) code.anewarray(ja, pool.addPath(path));
		switch (je) {
			case TBool: primitive(4);
			case TChar: primitive(5);
			case TFloat: primitive(6);
			case TDouble: primitive(7);
			case TByte: primitive(8);
			case TShort: primitive(9);
			case TInt: primitive(10);
			case TLong: primitive(11);
			case TObject(path, _): reference(path);
			case TMethod(_, _): reference(NativeSignatures.haxeFunctionPath);
			case TTypeParameter(_): reference(NativeSignatures.objectPath);
			case TArray(_, _): code.anewarray(ja, pool.addType(JvmSignature.generateSignature(false, je)));
			case TObjectInner(_, _) | TUninitialized(_): JvmGlobals.jerror("cannot create an array of " + JvmSignature.sSignatureKind(je));
		}
		return ja;
	}
}

class MethodBuilder extends BaseBuilder {
	public var code(default, null):CodeBuilder;

	var jc:ClassBuilder;
	var name:String;
	var jsig:JSignature;
	var maxNumLocals = 0;
	var debugLocals:Array<DebugLocal> = [];
	var stackFrames:Array<StackFrameEntry> = [];
	var exceptions:Array<JvmExceptionData> = [];
	var argumentLocals:Array<JvmLocal> = [];
	var argumentAnnotations:Map<Int, Array<AnnotationDecl>> = new Map();
	// Kept in hash-table order: exportMethod writes the Exceptions attribute in the reverse of the bucket
	// visit order.
	var thrownExceptions = new hxc.core.NameHash.HashTableOrder();
	var regexCount = 0;

	var locals:Array<JvmLocal> = [];
	var localOffset = 0;

	public function new(jc:ClassBuilder, name:String, jsig:JSignature) {
		super();
		this.jc = jc;
		this.name = name;
		this.jsig = jsig;
		this.code = new CodeBuilder(jc.getPool());
	}

	public function hasMethodFlag(flag:Int):Bool {
		return MethodAccessFlags.hasFlag(accessFlags, flag);
	}

	// The returned function reverts to the previous scope, recording the range each local of this scope was
	// live for.
	public function pushScope():Void->Void {
		var oldLocals = locals.copy();
		var oldOffset = localOffset;
		return function() {
			var delta = localOffset - oldOffset;
			var fpEnd = code.getFp();
			var i = delta;
			var idx = 0;
			while (i != 0) {
				if (idx >= locals.length) JvmGlobals.jerror("local scope underflow");
				var l = locals[idx++];
				if (l.init.value == null) JvmGlobals.jerror("Uninitialized local " + l.name);
				var fp = l.init.value;
				var t = switch (l.t) {
					case TUninitialized(o) if (o == null): TObject(jc.getThisPath(), []);
					case t: t;
				};
				debugLocals.unshift({
					fp: fp, length: fpEnd - fp, name: l.name, jsig: t,
					index: oldOffset + i - JvmSignature.signatureSize(t)
				});
				i -= JvmSignature.signatureSize(t);
			}
			locals = oldLocals.copy();
			localOffset = oldOffset;
		};
	}

	function getLocalsForStackFrame(l:Array<JvmLocal>):Array<VerificationTypeInfo> {
		return [
			for (e in l)
				e.init.value == null ? VTop : JvmVerificationTypeInfo.ofSignature(jc.getPool(), e.t)
		];
	}

	public function getNextRegexId():Int {
		return regexCount++;
	}

	// Has to be called on every branch target. A frame already recorded at this position is replaced, which
	// happens with nested branches.
	public function addStackFrame():Void {
		var l = getLocalsForStackFrame(locals);
		var astack = [for (js in code.getStack().getStack()) JvmVerificationTypeInfo.ofSignature(jc.getPool(), js)];
		var r = code.getFp();
		if (stackFrames.length > 0 && stackFrames[0].offset == r) stackFrames.shift();
		stackFrames.unshift({offset: r, locals: l, stack: astack});
	}

	public function addException(exc:JvmExceptionData):Void {
		exceptions.unshift(exc);
	}

	public function addThrownException(path:JPath):Void {
		thrownExceptions.addInt(jc.getPool().addPath(path));
	}


	public function string(s:String):Void {
		code.sconst(NativeSignatures.stringSig, jc.getPool().addConstString(s));
	}

	static function methodParts(jsigm:JSignature):{args:Array<JSignature>, ret:Array<JSignature>} {
		return switch (jsigm) {
			case TMethod(tl, tr): {args: tl, ret: tr == null ? [] : [tr]};
			case _: JvmGlobals.jerror("not a method signature");
		}
	}

	public function invokevirtual(path:JPath, name:String, jsigm:JSignature):Void {
		var p = methodParts(jsigm);
		code.invokevirtual(code.getPool().addField(path, name, jsigm, FKMethod),
			NativeSignatures.objectPathSig(path), p.args, p.ret);
	}

	public function invokeinterface(path:JPath, name:String, jsigm:JSignature):Void {
		var p = methodParts(jsigm);
		code.invokeinterface(code.getPool().addField(path, name, jsigm, FKInterfaceMethod),
			NativeSignatures.objectPathSig(path), p.args, p.ret);
	}

	public function invokespecial(path:JPath, name:String, jsigm:JSignature):Void {
		var p = methodParts(jsigm);
		code.invokespecial(code.getPool().addField(path, name, jsigm, FKMethod),
			NativeSignatures.objectPathSig(path), p.args, p.ret);
	}

	public function invokestatic(path:JPath, name:String, jsigm:JSignature):Void {
		var p = methodParts(jsigm);
		code.invokestatic(code.getPool().addField(path, name, jsigm, FKMethod), p.args, p.ret);
	}

	public function getfield(path:JPath, name:String, jsigf:JSignature):Void {
		code.getfield(code.getPool().addField(path, name, jsigf, FKField),
			NativeSignatures.objectPathSig(path), jsigf);
	}

	public function putfield(path:JPath, name:String, jsigf:JSignature):Void {
		code.putfield(code.getPool().addField(path, name, jsigf, FKField),
			NativeSignatures.objectPathSig(path), jsigf);
	}

	public function getstatic(path:JPath, name:String, jsigf:JSignature):Void {
		code.getstatic(code.getPool().addField(path, name, jsigf, FKField), jsigf);
	}

	public function putstatic(path:JPath, name:String, jsigf:JSignature):Void {
		code.putstatic(code.getPool().addField(path, name, jsigf, FKField), jsigf);
	}

	public function getBasicTypeClass(name:String):Void {
		getstatic({pack: ["java", "lang"], name: name}, "TYPE", NativeSignatures.javaClassSig);
	}

	public function getClass(jsig:JSignature):Void {
		inline function classOf(t:JSignature):JSignature
			return TObject(NativeSignatures.javaClassPath, [TType(WNone, t)]);
		switch (jsig) {
			case TByte: getBasicTypeClass("Byte");
			case TChar: getBasicTypeClass("Character");
			case TDouble: getBasicTypeClass("Double");
			case TFloat: getBasicTypeClass("Float");
			case TInt: getBasicTypeClass("Integer");
			case TLong: getBasicTypeClass("Long");
			case TShort: getBasicTypeClass("Short");
			case TBool: getBasicTypeClass("Boolean");
			case TObject(path, _):
				code.ldc(code.getPool().addPath(path), classOf(NativeSignatures.objectPathSig(path)));
			case TTypeParameter(_):
				code.ldc(code.getPool().addPath(NativeSignatures.objectPath), classOf(NativeSignatures.objectSig));
			case TArray(_, _):
				code.ldc(code.getPool().addPath({pack: [], name: JvmSignature.generateSignature(false, jsig)}),
					classOf(NativeSignatures.objectSig));
			case TMethod(_, _):
				code.ldc(code.getPool().addPath(NativeSignatures.haxeFunctionPath), classOf(NativeSignatures.objectSig));
			case _:
				JvmGlobals.jerror("no class for " + JvmSignature.sSignatureKind(jsig));
		}
	}

	public function loadThis():Void {
		code.aload(getThisSig(), 0);
	}

	public function callSuperCtor(kind:ConstructionKind, jsigMethod:JSignature):Void {
		if (hasMethodFlag(MethodAccessFlags.MStatic)) JvmGlobals.jerror("super constructor call in a static method");
		switch (kind) {
			case ConstructInitPlusNew: invokespecial(jc.getSuperPath(), "new", jsigMethod);
			case ConstructInit:
				invokespecial(jc.getSuperPath(), "<init>", jsigMethod);
				setThisInitialized();
		}
	}

	public function loadDefaultValue(jsig:JSignature):Void {
		switch (jsig) {
			case TByte | TBool | TChar | TShort | TInt: code.iconst(0);
			case TFloat: code.fconst(0.0);
			case TDouble: code.dconst(0.0);
			case TLong: code.lconst(haxe.Int64.ofInt(0));
			case jsig: code.aconstNull(jsig);
		}
	}

	public function returnOp():Void {
		switch (jsig) {
			case TMethod(_, tr):
				if (tr == null) code.returnVoid();
				else code.returnValue(tr);
			case _: JvmGlobals.jerror("not a method signature");
		}
	}


	public function addArgumentAndField(name:String, jsigField:JSignature, flags:Array<Int>):Void {
		if (hasMethodFlag(MethodAccessFlags.MStatic)) JvmGlobals.jerror("argument field in a static method");
		jc.spawnField(name, jsigField, flags);
		var l = addLocal(name, jsigField, VarArgument);
		loadThis();
		l.load();
		putfield(jc.getThisPath(), name, jsigField);
	}

	// `f` pushes the constructor arguments and returns their signatures. With noValue the stack is left as
	// it
	// was, otherwise the new object is left on it.
	public function construct(kind:ConstructionKind, path:JPath, f:Void->Array<JSignature>, ?noValue:Bool = false):Void {
		code.new_(code.getPool().addPath(path));
		switch (kind) {
			case ConstructInitPlusNew:
				code.dup();
				code.aconstNull(NativeSignatures.haxeEmptyConstructorSig);
				invokespecial(path, "<init>", NativeSignatures.methodSig([NativeSignatures.haxeEmptyConstructorSig], null));
				if (!noValue) replaceTop(NativeSignatures.objectPathSig(path));
				if (!noValue) code.dup();
				var jsigs = f();
				invokevirtual(path, "new", NativeSignatures.methodSig(jsigs, null));
			case ConstructInit:
				if (!noValue) code.dup();
				var jsigs = f();
				invokespecial(path, "<init>", NativeSignatures.methodSig(jsigs, null));
				if (!noValue) replaceTop(NativeSignatures.objectPathSig(path));
		}
	}

	public function newNativeArray(jsig:JSignature, fl:Array<Void->Void>):Void {
		code.iconst(fl.length);
		var jasig = NativeArray.create(code, jc.getPool(), jsig);
		for (i in 0...fl.length) {
			code.dup();
			code.iconst(i);
			fl[i]();
			castTo(jsig);
			NativeArray.write(code, jasig, jsig);
		}
	}

	// Boxes a primitive on top of the stack through its wrapper's valueOf.
	public function expectReferenceType():Void {
		function wrapNull(jsig:JSignature, name:String):Void {
			var path:JPath = {pack: ["java", "lang"], name: name};
			invokestatic(path, "valueOf", NativeSignatures.methodSig([jsig], NativeSignatures.objectPathSig(path)));
		}
		switch (code.getStack().top()) {
			case t = TByte: wrapNull(t, "Byte");
			case t = TChar: wrapNull(t, "Character");
			case t = TDouble: wrapNull(t, "Double");
			case t = TFloat: wrapNull(t, "Float");
			case t = TInt: wrapNull(t, "Integer");
			case t = TLong: wrapNull(t, "Long");
			case t = TShort: wrapNull(t, "Short");
			case t = TBool: wrapNull(t, "Boolean");
			case _:
		}
	}

	// Unboxing goes through the wrapper's own accessor when the value is known not to be null, and through
	// haxe.jvm.Jvm otherwise, which tolerates null.
	function expectBasicType(jsig:JSignature, notNull:Bool):Void {
		if (notNull) {
			function unwrapNull(tname:String, name:String):Void {
				castTo(NativeSignatures.getBoxedType(jsig));
				invokevirtual({pack: ["java", "lang"], name: tname}, name, NativeSignatures.methodSig([], jsig));
			}
			switch (jsig) {
				case TByte: unwrapNull("Number", "byteValue");
				case TChar: unwrapNull("Character", "charValue");
				case TDouble: unwrapNull("Number", "doubleValue");
				case TFloat: unwrapNull("Number", "floatValue");
				case TInt: unwrapNull("Number", "intValue");
				case TLong: unwrapNull("Number", "longValue");
				case TShort: unwrapNull("Number", "shortValue");
				case TBool: unwrapNull("Boolean", "booleanValue");
				case _:
			}
		} else {
			function unwrapNull(tname:String, name:String):Void {
				invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, name,
					NativeSignatures.methodSig([NativeSignatures.objectSig], jsig));
			}
			switch (jsig) {
				case TByte: unwrapNull("Byte", "toByte");
				case TChar: unwrapNull("Character", "toChar");
				case TDouble: unwrapNull("Double", "toDouble");
				case TFloat: unwrapNull("Float", "toFloat");
				case TInt: unwrapNull("Integer", "toInt");
				case TLong: unwrapNull("Long", "toLong");
				case TShort: unwrapNull("Short", "toShort");
				case TBool: unwrapNull("Boolean", "toBoolean");
				case _:
			}
		}
	}

	static inline function isJavaLangNamed(path:JPath, name:String):Bool {
		return path.name == name && path.pack.length == 2 && path.pack[0] == "java" && path.pack[1] == "lang";
	}

	// A boxed java.lang number type other than the one named by `except`.
	static function isNumberSig(except:String, jsig:JSignature):Bool {
		return switch (jsig) {
			case TObject(p, _) if (p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang"):
				switch (p.name) {
					case "Byte" | "Short" | "Integer" | "Long" | "Float" | "Double": p.name != except;
					case _: false;
				}
			case _: false;
		}
	}

	public function castTo(jsig:JSignature, ?notNull:Bool = false, ?allowToString:Bool = false):Void {
		var jsig2 = code.getStack().top();
		function unboxedToByte():Void {
			switch (code.getStack().top()) {
				case TByte | TBool:
				case TChar | TShort | TInt: code.i2b(TByte);
				case TLong: code.l2i(); unboxedToByte();
				case TFloat: code.f2i(); unboxedToByte();
				case TDouble: code.d2i(); unboxedToByte();
				case js: JvmGlobals.jerror(JvmSignature.sSignatureKind(js));
			}
		}
		function unboxedToShort():Void {
			switch (code.getStack().top()) {
				case TShort:
				case TBool | TByte | TChar | TInt: code.i2s();
				case TLong: code.l2i(); unboxedToShort();
				case TFloat: code.f2i(); unboxedToShort();
				case TDouble: code.d2i(); unboxedToShort();
				case js: JvmGlobals.jerror(JvmSignature.sSignatureKind(js));
			}
		}
		function unboxedToInt():Void {
			switch (code.getStack().top()) {
				case TBool | TByte | TShort | TChar | TInt: replaceTop(TInt);
				case TLong: code.l2i();
				case TFloat: code.f2i();
				case TDouble: code.d2i();
				case js: JvmGlobals.jerror(JvmSignature.sSignatureKind(js));
			}
		}
		function unboxedToLong():Void {
			switch (code.getStack().top()) {
				case TBool | TByte | TShort | TChar | TInt: code.i2l();
				case TLong:
				case TFloat: code.f2l();
				case TDouble: code.d2l();
				case js: JvmGlobals.jerror(JvmSignature.sSignatureKind(js));
			}
		}
		function unboxedToFloat():Void {
			switch (code.getStack().top()) {
				case TBool | TByte | TShort | TChar | TInt: code.i2f();
				case TLong: code.l2f();
				case TFloat:
				case TDouble: code.d2f();
				case js: JvmGlobals.jerror(JvmSignature.sSignatureKind(js));
			}
		}
		function unboxedToDouble():Void {
			switch (code.getStack().top()) {
				case TBool | TByte | TShort | TChar | TInt: code.i2d();
				case TLong: code.l2d();
				case TFloat: code.f2d();
				case TDouble:
				case js: JvmGlobals.jerror(JvmSignature.sSignatureKind(js));
			}
		}
		function getConv(name:String):Void->Void {
			return switch (name) {
				case "Byte": unboxedToByte;
				case "Short": unboxedToShort;
				case "Integer": unboxedToInt;
				case "Long": unboxedToLong;
				case "Float": unboxedToFloat;
				case "Double": unboxedToDouble;
				case _: JvmGlobals.jerror("no conversion for " + name);
			}
		}
		function numberTo(name:String):Void {
			var boxedSig:JSignature = TObject({pack: ["java", "lang"], name: name}, []);
			invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, "numberTo" + name,
				NativeSignatures.methodSig([NativeSignatures.numberSig], boxedSig));
		}
		function dynamicTo(name:String):Void {
			var boxedSig:JSignature = TObject({pack: ["java", "lang"], name: name}, []);
			invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, "dynamicTo" + name,
				NativeSignatures.methodSig([NativeSignatures.objectSig], boxedSig));
		}
		function numericCastBoxed(name:String, js:JSignature):Void {
			if (NativeSignatures.isUnboxed(js)) {
				getConv(name)();
				expectReferenceType();
			} else if (isNumberSig(name, js)) numberTo(name);
			else if (NativeSignatures.isDynamicAtRuntime(js)) dynamicTo(name);
			else code.checkcast({pack: ["java", "lang"], name: name});
		}
		function numericCastUnboxed(name:String, js:JSignature):Void {
			if (NativeSignatures.isUnboxed(js)) getConv(name)();
			else {
				expectBasicType(NativeSignatures.getUnboxedType(TObject({pack: ["java", "lang"], name: name}, [])), false);
				getConv(name)();
			}
		}
		switch [jsig, jsig2] {
			case [TObject(p, _), js] if (isJavaLangNamed(p, "Byte")): numericCastBoxed("Byte", js);
			case [TByte, js]: numericCastUnboxed("Byte", js);
			case [TObject(p, _), js] if (isJavaLangNamed(p, "Short")): numericCastBoxed("Short", js);
			case [TShort, js]: numericCastUnboxed("Short", js);
			case [TObject(p, _), js] if (isJavaLangNamed(p, "Integer")): numericCastBoxed("Integer", js);
			case [TInt, js]: numericCastUnboxed("Integer", js);
			case [TObject(p, _), js] if (isJavaLangNamed(p, "Long")): numericCastBoxed("Long", js);
			case [TLong, js]: numericCastUnboxed("Long", js);
			case [TObject(p, _), js] if (isJavaLangNamed(p, "Float")): numericCastBoxed("Float", js);
			case [TFloat, js]: numericCastUnboxed("Float", js);
			case [TObject(p, _), js] if (isJavaLangNamed(p, "Double")): numericCastBoxed("Double", js);
			case [TDouble, js]: numericCastUnboxed("Double", js);
			case [TChar, TDouble]: code.d2i(); code.i2c();
			case [TChar, TFloat]: code.f2i(); code.i2c();
			case [TChar, TByte | TShort | TInt]: code.i2c();
			case [TChar, TLong]: code.l2i(); code.i2c();
			case [TBool, TInt]: replaceTop(TBool);
			case [TObject(p1, _), TObject(p2, _)] if (JvmSignature.samePath(p1, p2)):
			case [TObject(p1, _), _] if (isJavaLangNamed(p1, "String") && allowToString):
				expectReferenceType();
				invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, "toString",
					NativeSignatures.methodSig([NativeSignatures.objectSig], NativeSignatures.stringSig));
			case [TObject(p1, _), t2]:
				if (NativeSignatures.isUnboxed(t2)) expectReferenceType();
				// A checkcast to Object is never needed, but the stack top is still retyped so the recorded
				// frames
				// stay wide enough.
				else if (JvmSignature.samePath(p1, NativeSignatures.objectPath)) replaceTop(NativeSignatures.objectSig);
				else code.checkcast(p1);
			case [TMethod(_, _), TMethod(_, _)]:
			case [TMethod(_, _), _]: code.checkcast(NativeSignatures.haxeFunctionPath);
			case [TArray(j1, _), TArray(j2, _)] if (JvmSignature.eq(j1, j2)):
			case [TArray(_, _), _]: code.checkcastSig(jsig);
			case [t1, t2]:
				switch [NativeSignatures.isUnboxed(t1), NativeSignatures.isUnboxed(t2)] {
					case [true, false]: expectBasicType(t1, notNull);
					case [false, true]: expectReferenceType();
					case _:
				}
		}
	}


	// The returned function puts the stack and the termination flag back, so several branches can each
	// start from the same state. Locals are not touched; pushScope handles those.
	public function startBranch():Void->Void {
		var save = code.getStack().save();
		var oldTerminated = code.isTerminated();
		return function() {
			code.getStack().restore(save);
			code.setTerminated(oldTerminated);
		};
	}

	public function spawnLabel(name:String):Label {
		return new Label(this, name);
	}

	public function ifThenElse(fIf:Ref<Int>->Void, fThen:Void->Void, fElse:Void->Void):Void {
		ifThenElseLabeled(function(labelThen, labelElse) labelElse.apply(fIf), fThen, fElse);
	}

	// The exit label is only placed when at least one side falls through.
	public function ifThenElseLabeled(fIf:Label->Label->Void, fThen:Void->Void, fElse:Void->Void):Void {
		var labelThen = spawnLabel("then");
		var labelElse = spawnLabel("else");
		var labelExit = spawnLabel("exit");
		fIf(labelThen, labelElse);
		labelThen.here();
		var restore = startBranch();
		var pop = pushScope();
		fThen();
		pop();
		var termThen = isTerminated();
		if (!isTerminated()) labelExit.goto();
		restore();
		labelElse.here();
		fElse();
		if (termThen && isTerminated()) setTerminated(true);
		else {
			setTerminated(false);
			labelExit.here();
		}
	}

	public function ifThen(fIf:Ref<Int>->Void, fThen:Void->Void):Void {
		ifThenLabeled(function(_, labelElse) labelElse.apply(fIf), fThen);
	}

	public function ifThenLabeled(fIf:Label->Label->Void, fThen:Void->Void):Void {
		var labelThen = spawnLabel("then");
		var labelElse = spawnLabel("else");
		fIf(labelThen, labelElse);
		labelThen.here();
		var restore = startBranch();
		var pop = pushScope();
		fThen();
		pop();
		restore();
		labelElse.here();
	}

	// Emits a goto, to be patched later by closeJumps, unless the code has already terminated, and returns
	// the offset to patch.
	public function maybeMakeJump():Ref<Int> {
		var r = new Ref(code.getFp());
		if (!isTerminated()) code.goto(r);
		return r;
	}

	// Points every pending jump at the current position. A stack frame is needed here unless the switch was
	// exhaustive and every branch terminated.
	public function closeJumps(isExhaustive:Bool, rl:Array<{term:Bool, r:Ref<Int>}>):Void {
		var fp2 = code.getFp();
		var term = true;
		for (e in rl) {
			e.r.value = fp2 - e.r.value;
			term = term && e.term;
		}
		term = isExhaustive && term;
		setTerminated(term);
		if (!term) addStackFrame();
	}

	// String.hashCode as the JVM computes it, so the switch buckets agree with what hashCode() returns at
	// run time. A supplementary code point hashes as its two surrogates.
	public static function javaHash(s:String):Int {
		var h = 0;
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i++);
			if (c >= 0xD800 && c <= 0xDBFF && i < s.length) {
				var lo = s.charCodeAt(i);
				if (lo >= 0xDC00 && lo <= 0xDFFF) {
					i++;
					c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
				}
			}
			if (c > 0xFFFF) {
				h = 31 * h + ((c >> 10) + 0xD7C0);
				h = 31 * h + ((c & 0x3FF) | 0xDC00);
			} else
				h = 31 * h + c;
		}
		return h;
	}

	// Switches on the hash, then compares with equals inside each bucket, since distinct strings can share
	// a
	// hash. The subject may be null, which is tested first.
	public function stringSwitch(needVal:Bool, load:Void->Void, cases:Array<{values:Array<String>, f:Void->Void}>,
			def:Null<Void->Void>):Void {
		var bucketKeys:Array<Int> = [];
		var buckets:Map<Int, Array<{s:String, index:Int}>> = new Map();
		var exprs = [for (c in cases) {f: c.f, numJumps: c.values.length}];
		for (index in 0...cases.length)
			for (str in cases[index].values) {
				var hash = javaHash(str);
				if (!buckets.exists(hash)) {
					buckets.set(hash, []);
					bucketKeys.unshift(hash);
				}
				// Prepending leaves each bucket in reverse insertion order, and the `equals` chain below
				// tests the
				// strings in that order.
				buckets.get(hash).unshift({s: str, index: index});
			}
		if (def == null && needVal) {
			def = function() {
				string("Match failure");
				invokestatic({pack: ["haxe", "jvm"], name: "Exception"}, "wrap",
					NativeSignatures.methodSig([NativeSignatures.objectSig], NativeSignatures.exceptionSig));
				getCode().athrow();
			};
		}
		var labelDef = spawnLabel("default");
		var labelExit = spawnLabel("exit");
		load();
		labelDef.apply(function(r) code.ifNull(NativeSignatures.stringSig, r));
		load();
		invokevirtual(NativeSignatures.stringPath, "hashCode", NativeSignatures.methodSig([], TInt));
		var exprLabels = [for (_ in exprs) spawnLabel("case-expr")];
		var jumpTable = [for (hash in bucketKeys) {hash: hash, label: spawnLabel("hash-match")}];
		var sorted = [for (e in jumpTable) {v: e.hash, offset: e.label.mkOffset()}];
		sorted.sort(function(a, b) return a.v < b.v ? -1 : (a.v > b.v ? 1 : 0));
		code.lookupswitch(labelDef.mkOffset(), sorted);
		var restore = startBranch();
		for (e in jumpTable) {
			e.label.here();
			for (entry in buckets.get(e.hash)) {
				restore();
				var popScope = pushScope();
				var ex = exprs[entry.index];
				load();
				string(entry.s);
				invokevirtual(NativeSignatures.stringPath, "equals",
					NativeSignatures.methodSig([NativeSignatures.objectSig], TBool));
				if (ex.numJumps == 1)
					ifThen(function(r) code.if_(CmpEq, r), function() {
						ex.f();
						if (!isTerminated()) labelExit.goto();
					});
				else
					exprLabels[entry.index].apply(function(r) code.if_(CmpNe, r));
				popScope();
			}
			labelDef.goto();
		}
		for (i in 0...exprs.length) {
			if (exprs[i].numJumps != 1) {
				restore();
				exprLabels[i].here();
				var popScope = pushScope();
				exprs[i].f();
				popScope();
				if (!isTerminated()) labelExit.goto();
			}
		}
		if (def != null) {
			restore();
			labelDef.here();
			var popScope = pushScope();
			def();
			popScope();
			if (!isTerminated()) labelExit.goto();
		}
		if (labelExit.wasJumpedTo()) labelExit.here();
		if (def == null) {
			setTerminated(false);
			labelDef.here();
		} else if (labelExit.wasJumpedTo()) setTerminated(false);
		else setTerminated(true);
	}

	// A tableswitch when the values are dense enough to be worth the padding, a lookupswitch otherwise. A
	// switch that has to produce a value gets a throwing default.
	public function intSwitch(needVal:Bool, cases:Array<{values:Array<Int>, f:Void->Void}>, def:Null<Void->Void>):Void {
		if (def == null && needVal) {
			def = function() {
				string("Match failure");
				invokestatic({pack: ["haxe", "jvm"], name: "Exception"}, "wrap",
					NativeSignatures.methodSig([NativeSignatures.objectSig], NativeSignatures.exceptionSig));
				getCode().athrow();
			};
		}
		var flatCases:Array<{v:Int, offset:Ref<Int>}> = [];
		var caseLut:Map<Int, Label> = new Map();
		var imin:Float = 2147483647;
		var imax:Float = -2147483648;
		var labelled = [
			for (c in cases) {
				var rl = [
					for (v in c.values) {
						var r = spawnLabel("case");
						if (v < imin) imin = v;
						if (v > imax) imax = v;
						flatCases.push({v: v, offset: r.mkOffset()});
						caseLut.set(v, r);
						r;
					}
				];
				{rl: rl, f: c.f};
			}
		];
		var labelDef = spawnLabel("default");
		var diff = imax - imin;
		var useTableswitch = diff < (flatCases.length + 10) && diff >= 0;
		if (useTableswitch) {
			var lo = Std.int(imin);
			var hi = Std.int(imax);
			var offsets = [
				for (i in 0...(hi - lo + 1)) {
					var l = caseLut.get(i + lo);
					(l == null ? labelDef : l).mkOffset();
				}
			];
			code.tableswitch(labelDef.mkOffset(), lo, hi, offsets);
		} else {
			flatCases.sort(function(a, b) return a.v < b.v ? -1 : (a.v > b.v ? 1 : 0));
			code.lookupswitch(labelDef.mkOffset(), flatCases);
		}
		var restore = startBranch();
		var labelExit = spawnLabel("exit");
		if (def != null) {
			labelDef.here();
			var popScope = pushScope();
			def();
			popScope();
			if (!isTerminated()) labelExit.goto();
		}
		for (idx in 0...labelled.length) {
			var c = labelled[idx];
			restore();
			for (l in c.rl) l.here();
			var popScope = pushScope();
			c.f();
			popScope();
			if (idx < labelled.length - 1 && !isTerminated()) labelExit.goto();
		}
		if (labelExit.wasJumpedTo()) labelExit.here();
		if (def == null) {
			setTerminated(false);
			labelDef.here();
		} else if (labelExit.wasJumpedTo())
			setTerminated(false);
	}

	// A local occupies one slot, or two for a long or a double. It counts as initialized, for stack frames
	// and debug ranges, from its first store (an argument or a defaulted local from the start).
	public function addLocal(name:String, jsig:JSignature, initState:VarInitState):{slot:Int, load:Void->Void, store:Void->Void} {
		var slot = localOffset;
		var load:Void->Void;
		var store:Void->Void;
		var d:Int;
		switch (jsig) {
			case TInt | TBool | TByte | TShort | TChar:
				if (initState == VarNeedDefault) { code.iconst(0); code.istore(slot); }
				load = function() code.iload(slot, jsig);
				store = function() code.istore(slot);
				d = 1;
			case TLong:
				if (initState == VarNeedDefault) { code.lconst(haxe.Int64.ofInt(0)); code.lstore(slot); }
				load = function() code.lload(slot);
				store = function() code.lstore(slot);
				d = 2;
			case TFloat:
				if (initState == VarNeedDefault) { code.fconst(0.0); code.fstore(slot); }
				load = function() code.fload(slot);
				store = function() code.fstore(slot);
				d = 1;
			case TDouble:
				if (initState == VarNeedDefault) { code.dconst(0.0); code.dstore(slot); }
				load = function() code.dload(slot);
				store = function() code.dstore(slot);
				d = 2;
			case _:
				if (initState == VarNeedDefault) { code.aconstNull(jsig); code.astore(jsig, slot); }
				load = function() code.aload(jsig, slot);
				store = function() code.astore(jsig, slot);
				d = 1;
		}
		var init = new Ref<Null<Int>>(null);
		locals.unshift({init: init, name: name, t: jsig});
		localOffset += d;
		if (localOffset > maxNumLocals) maxNumLocals = localOffset;
		var didStore = false;
		function checkStore() {
			if (!didStore) {
				didStore = true;
				init.value = code.getFp();
			}
		}
		switch (initState) {
			case VarArgument | VarNeedDefault: checkStore();
			case _:
		}
		return {slot: slot, load: load, store: function() { store(); checkStore(); }};
	}

	// Locals are prepended, so `this`, declared first, is the last one.
	public function getThisSig():JSignature {
		if (locals.length == 0) JvmGlobals.jerror("no this");
		return locals[locals.length - 1].t;
	}

	public function setThisInitialized():Void {
		if (locals.length == 0) JvmGlobals.jerror("no this");
		var last = locals[locals.length - 1];
		locals[locals.length - 1] = {init: last.init, name: last.name, t: jc.getJsig()};
	}

	public function replaceTop(jsig:JSignature):Void {
		code.getStack().replace(jsig);
	}

	public function addArgumentAnnotation(slot:Int, a:Array<{path:JPath, annot:Annotation}>):Void {
		argumentAnnotations.set(slot, [for (e in a) {jsig: TObject(e.path, []), a: e.annot}]);
	}

	// Called once every argument is declared. The stack map table describes its frames relative to these
	// argument locals.
	public function finalizeArguments():Void {
		argumentLocals = locals.copy();
	}

	public function getCode():CodeBuilder return code;
	public function isTerminated():Bool return code.isTerminated();
	public function getName():String return name;
	public function getJsig():JSignature return jsig;
	public function setTerminated(b:Bool):Void code.setTerminated(b);

	// Each frame is expressed as a delta against the one before it, and only falls back to the full form
	// when no compact one fits.
	function getStackMapTable():Array<JStackMapFrame> {
		var lastLocals = getLocalsForStackFrame(argumentLocals);
		var lastOffset = -1;
		var lastLocalsLength = argumentLocals.length;
		var acc:Array<JStackMapFrame> = [];
		var frames = stackFrames.copy();
		frames.reverse();
		for (f in frames) {
			var cur = f.offset - lastOffset - 1;
			var aLocals = f.locals.copy();
			aLocals.reverse();
			var localsLength = aLocals.length;
			var stack = f.stack.copy();
			stack.reverse();
			inline function def():JStackMapFrame return StackFull(cur, aLocals, stack);
			var delta = localsLength - lastLocalsLength;
			var entry:JStackMapFrame = if (f.stack.length == 0 && delta == 0) {
				if (sameTypes(lastLocals, f.locals)) (cur < 64 ? StackSame(cur) : StackSameExtended(cur));
				else def();
			} else if (f.stack.length == 1 && delta == 0) {
				if (sameTypes(lastLocals, f.locals)) (cur < 64 ? Stack1StackItem(cur, f.stack[0]) : Stack1StackItemExtended(cur, f.stack[0]));
				else def();
			} else if (f.stack.length == 0 && delta == 1) {
				sameTypes(lastLocals, f.locals.slice(1)) ? StackAppend1(cur, f.locals[0]) : def();
			} else if (f.stack.length == 0 && delta == 2) {
				sameTypes(lastLocals, f.locals.slice(2)) ? StackAppend2(cur, f.locals[1], f.locals[0]) : def();
			} else if (f.stack.length == 0 && delta == 3) {
				sameTypes(lastLocals, f.locals.slice(3)) ? StackAppend3(cur, f.locals[2], f.locals[1], f.locals[0]) : def();
			} else if (f.stack.length == 0 && delta == -1) {
				sameTypes(lastLocals.slice(1), f.locals) ? StackChop1(cur) : def();
			} else if (f.stack.length == 0 && delta == -2) {
				sameTypes(lastLocals.slice(2), f.locals) ? StackChop2(cur) : def();
			} else if (f.stack.length == 0 && delta == -3) {
				sameTypes(lastLocals.slice(3), f.locals) ? StackChop3(cur) : def();
			} else def();
			acc.push(entry);
			lastOffset = f.offset;
			lastLocals = f.locals;
			lastLocalsLength = localsLength;
		}
		return acc;
	}

	static function sameTypes(a:Array<VerificationTypeInfo>, b:Array<VerificationTypeInfo>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (!Type.enumEq(a[i], b[i])) return false;
		return true;
	}

	function getJCode(config:ExportConfig):JvmCodeData {
		var attributes:Array<JAttribute> = [];
		var lines = code.getLines();
		if (config.exportDebug && lines.length > 0) attributes.push(AttributeLineNumberTable(lines));
		var stackMapTable = getStackMapTable();
		if (stackMapTable.length > 0) attributes.push(AttributeStackMapTable(stackMapTable));
		var exc = exceptions.copy();
		exc.reverse();
		if (config.exportDebug && debugLocals.length > 0) {
			var typeLocals:Array<JvmLocalDebug> = [];
			var l:Array<JvmLocalDebug> = [];
			for (d in debugLocals) {
				var descriptorIndex = jc.getPool().addString(JvmSignature.generateSignature(false, d.jsig));
				var ld:JvmLocalDebug = {
					ldStartPc: d.fp,
					ldLength: d.length,
					ldNameIndex: jc.getPool().addString(d.name),
					ldDescriptorIndex: descriptorIndex,
					ldIndex: d.index
				};
				if (JvmSignature.hasTypeParameter(d.jsig))
					typeLocals.push({
						ldStartPc: ld.ldStartPc, ldLength: ld.ldLength, ldNameIndex: ld.ldNameIndex,
						ldDescriptorIndex: jc.getPool().addString(JvmSignature.generateSignature(true, d.jsig)),
						ldIndex: ld.ldIndex
					});
				l.push(ld);
			}
			attributes.push(AttributeLocalVariableTable(l));
			if (typeLocals.length > 0) attributes.push(AttributeLocalVariableTypeTable(typeLocals));
		}
		var written = [for (a in attributes) JvmAttribute.writeAttribute(jc.getPool(), a)];
		return {
			codeMaxStack: code.getMaxStackSize(),
			codeMaxLocals: maxNumLocals,
			codeCode: code.exportCode(),
			codeExceptions: exc,
			codeAttributes: written
		};
	}

	public function exportMethod(config:ExportConfig):JvmFieldData {
		if (wasExported) JvmGlobals.jerror("method was already exported");
		wasExported = true;
		commitAnnotations(jc.getPool());
		if (code.getFp() > 0) addAttribute(AttributeCode(getJCode(config)));
		var thrown = thrownExceptions.visitOrderInt();
		thrown.reverse();
		if (thrown.length > 0) addAttribute(AttributeExceptions(thrown));
		var annotatedArgs = [for (k in argumentAnnotations.keys()) k];
		if (annotatedArgs.length > 0) {
			var l = argumentLocals.length;
			var offset = hasMethodFlag(MethodAccessFlags.MStatic) ? 0 : 1;
			var a = [
				for (i in 0...(l - offset)) {
					var annot = argumentAnnotations.get(i + offset);
					annot == null ? [] : JvmBuilder.convertAnnotations(jc.getPool(), annot);
				}
			];
			addAttribute(AttributeRuntimeVisibleParameterAnnotations(a));
		}
		var attributes = exportAttributes(jc.getPool());
		return {
			fieldAccessFlags: accessFlags,
			fieldNameIndex: jc.getPool().addString(name),
			fieldDescriptorIndex: jc.getPool().addString(JvmSignature.generateMethodSignature(false, jsig)),
			fieldAttributes: attributes
		};
	}

	public function exportField():JvmFieldData {
		if (code.getFp() != 0) JvmGlobals.jerror("field builder emitted code");
		if (wasExported) JvmGlobals.jerror("field was already exported");
		wasExported = true;
		commitAnnotations(jc.getPool());
		var attributes = exportAttributes(jc.getPool());
		return {
			fieldAccessFlags: accessFlags,
			fieldNameIndex: jc.getPool().addString(name),
			fieldDescriptorIndex: jc.getPool().addString(JvmSignature.generateSignature(false, jsig)),
			fieldAttributes: attributes
		};
	}
}

// A jump target whose offset is patched into every jump that reached it.
class Label {
	var jm:MethodBuilder;
	var name:String;
	var code:CodeBuilder;
	var offset:Null<Int> = null;
	var pending:Array<Ref<Int>> = [];
	var jumpedTo = false;

	public function new(jm:MethodBuilder, name:String) {
		this.jm = jm;
		this.name = name;
		this.code = jm.getCode();
	}

	public function wasJumpedTo():Bool return jumpedTo;

	public function getOffset():Int {
		if (offset == null) JvmGlobals.jerror("Trying to get offset of unset label " + name);
		return offset;
	}

	// A jump made before the label is placed records its own position, and the difference is filled in once
	// the label's position is known.
	public function mkOffset():Ref<Int> {
		var r = new Ref(code.getFp());
		jumpedTo = true;
		if (offset == null) pending.push(r);
		else r.value = offset - r.value;
		return r;
	}

	public function apply(f:Ref<Int>->Void):Void f(mkOffset());
	public function if_(cmp:JCmp):Void code.if_(cmp, mkOffset());
	public function ifNull(jsig:JSignature):Void code.ifNull(jsig, mkOffset());
	public function ifNonnull(jsig:JSignature):Void code.ifNonnull(jsig, mkOffset());
	public function goto():Void code.goto(mkOffset());

	public function at(fp:Int):Void {
		if (offset == null) {
			if (fp == code.getFp()) jm.addStackFrame();
			for (r in pending) r.value = fp - r.value;
			offset = fp;
		} else if (fp != getOffset())
			JvmGlobals.jerror("Trying to instantiate label " + name + " again");
	}

	public function here():Void at(code.getFp());
}
