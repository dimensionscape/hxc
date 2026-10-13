package hxc.codegen.jvm;

import haxe.io.BytesOutput;
import hxc.codegen.jvm.JvmGlobals;

// The signature model the emitter uses, and how it is written out. The class-file reader has its own copy
// of this model (hxc.codegen.java.JData); this one adds TUninitialized, which only stack map frames
// produce.

typedef JPath = {pack:Array<String>, name:String};

enum JWildcard {
	WExtends; // +
	WSuper;   // -
	WNone;
}

enum JTypeArgument {
	TType(w:JWildcard, s:JSignature);
	TAny; // `*`
}

enum JSignature {
	TByte;   // B
	TChar;   // C
	TDouble; // D
	TFloat;  // F
	TInt;    // I
	TLong;   // J
	TShort;  // S
	TBool;   // Z
	TObject(path:JPath, params:Array<JTypeArgument>);            // L Classname
	TObjectInner(pack:Array<String>, inners:Array<JInnerName>);  // L Classname ClassTypeSignatureSuffix
	TArray(s:JSignature, size:Null<Int>);                        // [
	TMethod(args:Array<JSignature>, ret:Null<JSignature>);       // (
	TTypeParameter(name:String);                                 // T
	TUninitialized(offset:Null<Int>);
}

typedef JInnerName = {name:String, params:Array<JTypeArgument>};

class JvmSignature {
	static inline function path(pack:Array<String>, name:String):JPath return {pack: pack, name: name};

	public static function hasTypeParameter(jsig:JSignature):Bool {
		return switch (jsig) {
			case TTypeParameter(_): true;
			case TArray(s, _): hasTypeParameter(s);
			case TObject(_, params):
				var found = false;
				for (p in params) switch (p) {
					case TType(_, s) if (hasTypeParameter(s)): found = true; break;
					case _:
				}
				found;
			case _: false;
		}
	}

	public static function encodePath(p:JPath):String {
		return p.pack.length == 0 ? p.name : p.pack.join("/") + "/" + p.name;
	}

	public static function writeParam(full:Bool, ch:BytesOutput, param:JTypeArgument):Void {
		switch (param) {
			case TAny: JvmGlobals.writeByte(ch, "*".code);
			case TType(w, s):
				switch (w) {
					case WExtends: JvmGlobals.writeByte(ch, "+".code);
					case WSuper: JvmGlobals.writeByte(ch, "-".code);
					case WNone:
				}
				writeSignature(full, ch, s);
		}
	}

	public static function writeSignature(full:Bool, ch:BytesOutput, jsig:JSignature):Void {
		switch (jsig) {
			case TByte: JvmGlobals.writeByte(ch, "B".code);
			case TChar: JvmGlobals.writeByte(ch, "C".code);
			case TDouble: JvmGlobals.writeByte(ch, "D".code);
			case TFloat: JvmGlobals.writeByte(ch, "F".code);
			case TInt: JvmGlobals.writeByte(ch, "I".code);
			case TLong: JvmGlobals.writeByte(ch, "J".code);
			case TShort: JvmGlobals.writeByte(ch, "S".code);
			case TBool: JvmGlobals.writeByte(ch, "Z".code);
			case TObject(p, params):
				JvmGlobals.writeByte(ch, "L".code);
				JvmGlobals.writeString(ch, encodePath(p));
				if (params.length != 0 && full) {
					JvmGlobals.writeByte(ch, "<".code);
					for (param in params) writeParam(full, ch, param);
					JvmGlobals.writeByte(ch, ">".code);
				}
				JvmGlobals.writeByte(ch, ";".code);
			case TObjectInner(pack, inners):
				JvmGlobals.writeByte(ch, "L".code);
				for (p in pack) {
					JvmGlobals.writeString(ch, p);
					JvmGlobals.writeByte(ch, "/".code);
				}
				var first = true;
				for (inner in inners) {
					if (first) first = false else JvmGlobals.writeByte(ch, ".".code);
					JvmGlobals.writeString(ch, inner.name);
					if (inner.params.length != 0) {
						JvmGlobals.writeByte(ch, "<".code);
						for (param in inner.params) writeParam(full, ch, param);
						JvmGlobals.writeByte(ch, ">".code);
					}
				}
				JvmGlobals.writeByte(ch, ";".code);
			case TArray(s, size):
				JvmGlobals.writeByte(ch, "[".code);
				if (size != null) JvmGlobals.writeString(ch, Std.string(size));
				writeSignature(full, ch, s);
			case TMethod(_, _):
				// A method type is carried at run time as a haxe.jvm.Function.
				writeSignature(full, ch, NativeSignatures.haxeFunctionSig);
			case TTypeParameter(name):
				if (full) {
					JvmGlobals.writeByte(ch, "T".code);
					JvmGlobals.writeString(ch, name);
					JvmGlobals.writeByte(ch, ";".code);
				} else
					JvmGlobals.writeString(ch, "Ljava/lang/Object;");
			case TUninitialized(io):
				JvmGlobals.writeString(ch, "uninitialized");
				if (io == null) JvmGlobals.writeString(ch, " this");
				else JvmGlobals.writeString(ch, "(" + io + ")");
		}
	}

	public static function generateSignature(full:Bool, jsig:JSignature):String {
		var ch = new BytesOutput();
		ch.bigEndian = true;
		writeSignature(full, ch, jsig);
		return ch.getBytes().toString();
	}

	public static function generateMethodSignature(full:Bool, jsig:JSignature):String {
		var ch = new BytesOutput();
		ch.bigEndian = true;
		switch (jsig) {
			case TMethod(args, ret):
				JvmGlobals.writeByte(ch, "(".code);
				for (a in args) writeSignature(full, ch, a);
				JvmGlobals.writeByte(ch, ")".code);
				if (ret == null) JvmGlobals.writeByte(ch, "V".code);
				else writeSignature(full, ch, ret);
			case _:
				writeSignature(full, ch, jsig);
		}
		return ch.getBytes().toString();
	}

	// Size in slots: a long or a double occupies two.
	public static function signatureSize(jsig:JSignature):Int {
		return switch (jsig) {
			case TDouble | TLong: 2;
			case _: 1;
		}
	}

	public static function equalsAtRuntime(jsig1:JSignature, jsig2:JSignature):Bool {
		return switch [jsig1, jsig2] {
			case [TByte, TByte] | [TChar, TChar] | [TDouble, TDouble] | [TFloat, TFloat]
				| [TInt, TInt] | [TLong, TLong] | [TShort, TShort] | [TBool, TBool]
				| [TObjectInner(_, _), TObjectInner(_, _)] | [TArray(_, _), TArray(_, _)]
				| [TMethod(_, _), TMethod(_, _)] | [TTypeParameter(_), TTypeParameter(_)]
				| [TUninitialized(_), TUninitialized(_)]:
				true;
			case [TObject(p1, _), TObject(p2, _)]:
				samePath(p1, p2);
			case [TObject(p, _), TTypeParameter(_)] | [TTypeParameter(_), TObject(p, _)]:
				samePath(p, NativeSignatures.objectPath);
			case _: false;
		}
	}

	/**
		Structural equality on a signature.

		Type.enumEq cannot stand in for that on hxcpp: it compares an enum's parameters by IDENTITY, so two
		structurally identical values differ as soon as one carries an ARRAY, even an EMPTY one. TObject's
		type arguments and TMethod's argument list are both arrays, which covers every object type and every
		method signature.

		Comparing against a PARAMETERLESS constructor (TInt, TDouble, ...) is safe with Type.enumEq; this is
		for the rest.
	**/
	public static function eq(a:Null<JSignature>, b:Null<JSignature>):Bool {
		if (a == b) return true;
		if (a == null || b == null) return false;
		return switch [a, b] {
			case [TObject(p1, tl1), TObject(p2, tl2)]: samePath(p1, p2) && eqArgs(tl1, tl2);
			case [TObjectInner(pk1, in1), TObjectInner(pk2, in2)]:
				if (pk1.length != pk2.length || in1.length != in2.length) false;
				else {
					var ok = true;
					for (i in 0...pk1.length) if (pk1[i] != pk2[i]) { ok = false; break; }
					if (ok) for (i in 0...in1.length)
						if (in1[i].name != in2[i].name || !eqArgs(in1[i].params, in2[i].params)) { ok = false; break; }
					ok;
				}
			case [TArray(s1, n1), TArray(s2, n2)]: n1 == n2 && eq(s1, s2);
			case [TMethod(a1, r1), TMethod(a2, r2)]:
				if (a1.length != a2.length || !eq(r1, r2)) false;
				else {
					var ok = true;
					for (i in 0...a1.length) if (!eq(a1[i], a2[i])) { ok = false; break; }
					ok;
				}
			case [TTypeParameter(n1), TTypeParameter(n2)]: n1 == n2;
			case [TUninitialized(o1), TUninitialized(o2)]: o1 == o2;
			case _: Type.enumIndex(a) == Type.enumIndex(b);
		}
	}

	static function eqArgs(a:Array<JTypeArgument>, b:Array<JTypeArgument>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) {
			var same = switch [a[i], b[i]] {
				case [TAny, TAny]: true;
				case [TType(w1, s1), TType(w2, s2)]: w1 == w2 && eq(s1, s2);
				case _: false;
			}
			if (!same) return false;
		}
		return true;
	}

	public static inline function samePath(a:JPath, b:JPath):Bool {
		return a.name == b.name && a.pack.join("/") == b.pack.join("/");
	}

	public static function sWildcard(w:JWildcard):String {
		return switch (w) { case WExtends: "WExtends"; case WSuper: "WSuper"; case WNone: "WNone"; }
	}

	public static function sSignatureKind(jsig:JSignature):String {
		return switch (jsig) {
			case TByte: "TByte"; case TChar: "TChar"; case TDouble: "TDouble"; case TFloat: "TFloat";
			case TInt: "TInt"; case TLong: "TLong"; case TShort: "TShort"; case TBool: "TBool";
			case TObject(p, params):
				"TObject(" + (p.pack.length == 0 ? p.name : p.pack.join(".") + "." + p.name)
					+ ",[" + [for (x in params) sSignatureParamKind(x)].join(",") + "])";
			case TObjectInner(_, _): "TObjectInner";
			case TArray(s, io): "TArray(" + sSignatureKind(s) + "," + (io == null ? "None" : Std.string(io)) + ")";
			case TMethod(args, ret):
				"TMethod([" + [for (a in args) sSignatureKind(a)].join(",") + "],"
					+ (ret == null ? "None" : sSignatureKind(ret)) + ")";
			case TTypeParameter(name): "TTypeParameter(" + name + ")";
			// The misspelling is intentional and must be kept, since this text can appear in error output.
			case TUninitialized(io): "TUninitilaized(" + (io == null ? "None" : Std.string(io)) + ")";
		}
	}

	public static function sSignatureParamKind(a:JTypeArgument):String {
		return switch (a) {
			case TAny: "TAny";
			case TType(wc, jsig): "TType(" + sWildcard(wc) + "," + sSignatureKind(jsig) + ")";
		}
	}
}

class NativeSignatures {
	public static var objectPath(default, null):JPath = {pack: ["java", "lang"], name: "Object"};
	public static var objectSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Object"}, []);
	public static var stringPath(default, null):JPath = {pack: ["java", "lang"], name: "String"};
	public static var stringSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "String"}, []);
	public static var booleanPath(default, null):JPath = {pack: ["java", "lang"], name: "Boolean"};
	public static var booleanSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Boolean"}, []);
	public static var characterPath(default, null):JPath = {pack: ["java", "lang"], name: "Character"};
	public static var characterSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Character"}, []);
	public static var methodTypePath(default, null):JPath = {pack: ["java", "lang", "invoke"], name: "MethodType"};
	public static var methodTypeSig(default, null):JSignature = TObject({pack: ["java", "lang", "invoke"], name: "MethodType"}, []);
	public static var methodLookupPath(default, null):JPath = {pack: ["java", "lang", "invoke"], name: "MethodHandles$Lookup"};
	public static var methodLookupSig(default, null):JSignature = TObject({pack: ["java", "lang", "invoke"], name: "MethodHandles$Lookup"}, []);
	public static var callSitePath(default, null):JPath = {pack: ["java", "lang", "invoke"], name: "CallSite"};
	public static var callSiteSig(default, null):JSignature = TObject({pack: ["java", "lang", "invoke"], name: "CallSite"}, []);
	public static var javaClassPath(default, null):JPath = {pack: ["java", "lang"], name: "Class"};
	public static var javaClassSig(default, null):JSignature =
		TObject({pack: ["java", "lang"], name: "Class"}, [TType(WNone, TObject({pack: ["java", "lang"], name: "Object"}, []))]);
	public static var haxeJvmPath(default, null):JPath = {pack: ["haxe", "jvm"], name: "Jvm"};
	public static var haxeTypePath(default, null):JPath = {pack: ["haxe", "root"], name: "Type"};
	public static var haxeDynamicObjectPath(default, null):JPath = {pack: ["haxe", "jvm"], name: "DynamicObject"};
	public static var haxeDynamicObjectSig(default, null):JSignature = TObject({pack: ["haxe", "jvm"], name: "DynamicObject"}, []);
	public static var haxeExceptionPath(default, null):JPath = {pack: ["haxe"], name: "Exception"};
	public static var haxeExceptionSig(default, null):JSignature = TObject({pack: ["haxe"], name: "Exception"}, []);
	public static var haxeObjectPath(default, null):JPath = {pack: ["haxe", "jvm"], name: "Object"};
	public static var haxeObjectSig(default, null):JSignature = TObject({pack: ["haxe", "jvm"], name: "Object"}, []);
	public static var throwablePath(default, null):JPath = {pack: ["java", "lang"], name: "Throwable"};
	public static var throwableSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Throwable"}, []);
	public static var exceptionPath(default, null):JPath = {pack: ["java", "lang"], name: "Exception"};
	public static var exceptionSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Exception"}, []);
	public static var runtimeExceptionPath(default, null):JPath = {pack: ["java", "lang"], name: "RuntimeException"};
	public static var runtimeExceptionSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "RuntimeException"}, []);
	public static var retentionPath(default, null):JPath = {pack: ["java", "lang", "annotation"], name: "Retention"};
	public static var retentionSig(default, null):JSignature = TObject({pack: ["java", "lang", "annotation"], name: "Retention"}, []);
	public static var retentionPolicyPath(default, null):JPath = {pack: ["java", "lang", "annotation"], name: "RetentionPolicy"};
	public static var retentionPolicySig(default, null):JSignature = TObject({pack: ["java", "lang", "annotation"], name: "RetentionPolicy"}, []);
	public static var javaEnumPath(default, null):JPath = {pack: ["java", "lang"], name: "Enum"};
	public static var haxeEnumPath(default, null):JPath = {pack: ["haxe", "jvm"], name: "Enum"};
	public static var haxeEmptyConstructorPath(default, null):JPath = {pack: ["haxe", "jvm"], name: "EmptyConstructor"};
	public static var haxeEmptyConstructorSig(default, null):JSignature = TObject({pack: ["haxe", "jvm"], name: "EmptyConstructor"}, []);
	public static var haxeFunctionPath(default, null):JPath = {pack: ["haxe", "jvm"], name: "Function"};
	public static var haxeFunctionSig(default, null):JSignature = TObject({pack: ["haxe", "jvm"], name: "Function"}, []);
	public static var haxeCompiledPatternPath(default, null):JPath = {pack: ["haxe", "jvm"], name: "CompiledPattern"};
	public static var haxeCompiledPatternSig(default, null):JSignature = TObject({pack: ["haxe", "jvm"], name: "CompiledPattern"}, []);
	public static var haxeEregPath(default, null):JPath = {pack: ["haxe", "root"], name: "EReg"};
	public static var haxeEregSig(default, null):JSignature = TObject({pack: ["haxe", "root"], name: "EReg"}, []);
	public static var voidPath(default, null):JPath = {pack: ["java", "lang"], name: "Void"};
	public static var voidSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Void"}, []);
	public static var numberPath(default, null):JPath = {pack: ["java", "lang"], name: "Number"};
	public static var numberSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Number"}, []);
	public static var bytePath(default, null):JPath = {pack: ["java", "lang"], name: "Byte"};
	public static var byteSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Byte"}, []);
	public static var shortPath(default, null):JPath = {pack: ["java", "lang"], name: "Short"};
	public static var shortSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Short"}, []);
	public static var integerPath(default, null):JPath = {pack: ["java", "lang"], name: "Integer"};
	public static var integerSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Integer"}, []);
	public static var longPath(default, null):JPath = {pack: ["java", "lang"], name: "Long"};
	public static var longSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Long"}, []);
	public static var floatPath(default, null):JPath = {pack: ["java", "lang"], name: "Float"};
	public static var floatSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Float"}, []);
	public static var doublePath(default, null):JPath = {pack: ["java", "lang"], name: "Double"};
	public static var doubleSig(default, null):JSignature = TObject({pack: ["java", "lang"], name: "Double"}, []);

	public static function javaEnumSig(jsig:JSignature):JSignature return TObject(javaEnumPath, [TType(WNone, jsig)]);
	public static function haxeEnumSig(jsig:JSignature):JSignature return TObject(haxeEnumPath, [TType(WNone, jsig)]);

	public static function arraySig(jsig:JSignature):JSignature return TArray(jsig, null);
	public static function methodSig(args:Array<JSignature>, ret:Null<JSignature>):JSignature return TMethod(args, ret);
	public static function objectPathSig(p:JPath):JSignature return TObject(p, []);

	public static function getBoxedType(jsig:JSignature):JSignature {
		return switch (jsig) {
			case TBool: booleanSig;
			case TChar: characterSig;
			case TByte: byteSig;
			case TShort: shortSig;
			case TInt: integerSig;
			case TLong: longSig;
			case TFloat: floatSig;
			case TDouble: doubleSig;
			case _: jsig;
		}
	}

	// The "Charcter" spelling is intentional: java.lang.Character is never unboxed through this table.
	public static function getUnboxedType(jsig:JSignature):JSignature {
		return switch (jsig) {
			case TObject(p, _) if (isJavaLang(p, "Boolean")): TBool;
			case TObject(p, _) if (isJavaLang(p, "Charcter")): TChar;
			case TObject(p, _) if (isJavaLang(p, "Byte")): TByte;
			case TObject(p, _) if (isJavaLang(p, "Short")): TShort;
			case TObject(p, _) if (isJavaLang(p, "Integer")): TInt;
			case TObject(p, _) if (isJavaLang(p, "Long")): TLong;
			case TObject(p, _) if (isJavaLang(p, "Float")): TFloat;
			case TObject(p, _) if (isJavaLang(p, "Double")): TDouble;
			case _: jsig;
		}
	}

	static inline function isJavaLang(p:JPath, name:String):Bool {
		return p.name == name && p.pack.length == 2 && p.pack[0] == "java" && p.pack[1] == "lang";
	}

	public static function isUnboxed(jsig:JSignature):Bool {
		return switch (jsig) {
			case TBool | TChar | TByte | TShort | TInt | TLong | TFloat | TDouble: true;
			case _: false;
		}
	}

	public static function isDynamicAtRuntime(jsig:JSignature):Bool {
		return switch (jsig) {
			case TObject(p, _) if (isJavaLang(p, "Object")): true;
			case TTypeParameter(_): true;
			case _: false;
		}
	}
}
