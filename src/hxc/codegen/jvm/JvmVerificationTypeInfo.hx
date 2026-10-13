package hxc.codegen.jvm;

import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmSignature;

// What a stack map frame says a local or stack slot holds.

enum VerificationTypeInfo {
	VTop;
	VInteger;
	VFloat;
	VDouble;
	VLong;
	VNull;
	VUninitializedThis;
	VObject(i:JvmConstantPoolIndex);
	VUninitialized(offset:Int);
}

class JvmVerificationTypeInfo {
	public static function ofSignature(pool:JvmConstantPool, jsig:JSignature):VerificationTypeInfo {
		return switch (jsig) {
			case TByte | TChar | TBool | TShort | TInt: VInteger;
			case TFloat: VFloat;
			case TLong: VLong;
			case TDouble: VDouble;
			case TObject(path, _): VObject(pool.addPath(path));
			case TMethod(_, _): VObject(pool.addPath(NativeSignatures.haxeFunctionPath));
			// An array class is named by its own descriptor rather than a path.
			case TArray(_, _): VObject(pool.addPath({pack: [], name: JvmSignature.generateSignature(false, jsig)}));
			case TTypeParameter(_): VObject(pool.addPath({pack: ["java", "lang"], name: "Object"}));
			case TUninitialized(i) if (i != null): VUninitialized(i);
			case TUninitialized(_): VUninitializedThis;
			case _: JvmGlobals.jerror("no verification type for " + JvmSignature.sSignatureKind(jsig));
		}
	}

	public static function toString(vtt:VerificationTypeInfo):String {
		return switch (vtt) {
			case VTop: "top";
			case VInteger: "integer";
			case VFloat: "float";
			case VLong: "long";
			case VDouble: "double";
			case VNull: "null";
			case VUninitializedThis: "uninitializedThis";
			case VObject(i): "object " + i;
			case VUninitialized(i): "uninitializedVariable " + i;
		}
	}
}
