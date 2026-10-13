package hxc.codegen.jvm;

import haxe.io.BytesOutput;
import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmData;
import hxc.codegen.jvm.JvmVerificationTypeInfo;

// every attribute that gets written, and its payload.

typedef JAnnotation = {annType:Int, annElements:Array<JAnnotationElement>};
typedef JAnnotationElement = {index:JvmConstantPoolIndex, value:JAnnotationElementValue};
// the tag character and the value it introduces
typedef JAnnotationElementValue = {tag:Int, value:JAnnotationValue};

enum JAnnotationValue {
	ValConst(i:Int);              // B, C, D, E, F, I, J, S, Z, s
	ValEnum(i1:Int, i2:Int);      // e
	ValClass(i:Int);              // c, V -> Void
	ValAnnotation(a:JAnnotation); // @
	ValArray(l:Array<JAnnotationElementValue>); // [
}

// jvms-4.7.4
enum JStackMapFrame {
	StackSame(i:Int);
	Stack1StackItem(i:Int, t:VerificationTypeInfo);
	Stack1StackItemExtended(i:Int, t:VerificationTypeInfo);
	StackChop1(i:Int);
	StackChop2(i:Int);
	StackChop3(i:Int);
	StackSameExtended(i:Int);
	StackAppend1(i:Int, t1:VerificationTypeInfo);
	StackAppend2(i:Int, t1:VerificationTypeInfo, t2:VerificationTypeInfo);
	StackAppend3(i:Int, t1:VerificationTypeInfo, t2:VerificationTypeInfo, t3:VerificationTypeInfo);
	StackFull(i:Int, tl1:Array<VerificationTypeInfo>, tl2:Array<VerificationTypeInfo>);
}

// jvms-4.7.13
typedef JvmLocalDebug = {
	ldStartPc:Int,
	ldLength:Int,
	ldNameIndex:JvmConstantPoolIndex,
	ldDescriptorIndex:JvmConstantPoolIndex,
	ldIndex:Int,
};

typedef JvmInnerClass = {
	icInnerClassInfoIndex:Int,
	icOuterClassInfoIndex:Int,
	icInnerNameIndex:Int,
	icInnerClassAccessFlags:Int,
};

typedef JBootstrapMethod = {bmMethodRef:JvmConstantPoolIndex, bmArguments:Array<JvmConstantPoolIndex>};

// jvms-4.7
enum JAttribute {
	AttributeConstantValue(i:JvmConstantPoolIndex);
	AttributeCode(code:JvmCodeData);
	AttributeStackMapTable(frames:Array<JStackMapFrame>);
	AttributeExceptions(a:Array<JvmConstantPoolIndex>);
	AttributeSourceFile(i:JvmConstantPoolIndex);
	AttributeLineNumberTable(a:Array<{pc:Int, line:Int}>);
	AttributeSignature(i:JvmConstantPoolIndex);
	AttributeLocalVariableTable(table:Array<JvmLocalDebug>);
	AttributeLocalVariableTypeTable(table:Array<JvmLocalDebug>);
	AttributeInnerClasses(icl:Array<JvmInnerClass>);
	AttributeEnclosingMethod(i1:JvmConstantPoolIndex, i2:JvmConstantPoolIndex);
	AttributeRuntimeVisibleAnnotations(al:Array<JAnnotation>);
	AttributeRuntimeVisibleParameterAnnotations(al:Array<Array<JAnnotation>>);
	AttributeBootstrapMethods(a:Array<JBootstrapMethod>);
}

class JvmAttribute {
	public static function writeVerificationType(ch:BytesOutput, t:VerificationTypeInfo):Void {
		switch (t) {
			case VTop: JvmGlobals.writeByte(ch, 0);
			case VInteger: JvmGlobals.writeByte(ch, 1);
			case VFloat: JvmGlobals.writeByte(ch, 2);
			case VDouble: JvmGlobals.writeByte(ch, 3);
			case VLong: JvmGlobals.writeByte(ch, 4);
			case VNull: JvmGlobals.writeByte(ch, 5);
			case VUninitializedThis: JvmGlobals.writeByte(ch, 6);
			case VObject(i):
				JvmGlobals.writeByte(ch, 7);
				JvmGlobals.writeUi16(ch, i);
			case VUninitialized(i):
				JvmGlobals.writeByte(ch, 8);
				JvmGlobals.writeUi16(ch, i);
		}
	}

	// The compact frames encode their offset in the tag byte itself.
	public static function writeStackMapFrame(ch:BytesOutput, frame:JStackMapFrame):Void {
		switch (frame) {
			case StackSame(i):
				if (i >= 64) JvmGlobals.jerror("stack frame offset out of range");
				JvmGlobals.writeByte(ch, i);
			case Stack1StackItem(i, t):
				if (i >= 64) JvmGlobals.jerror("stack frame offset out of range");
				JvmGlobals.writeByte(ch, i + 64);
				writeVerificationType(ch, t);
			case Stack1StackItemExtended(i, t):
				JvmGlobals.writeByte(ch, 247);
				JvmGlobals.writeUi16(ch, i);
				writeVerificationType(ch, t);
			case StackChop1(i1):
				JvmGlobals.writeByte(ch, 250);
				JvmGlobals.writeUi16(ch, i1);
			case StackChop2(i1):
				JvmGlobals.writeByte(ch, 249);
				JvmGlobals.writeUi16(ch, i1);
			case StackChop3(i1):
				JvmGlobals.writeByte(ch, 248);
				JvmGlobals.writeUi16(ch, i1);
			case StackSameExtended(i):
				JvmGlobals.writeByte(ch, 251);
				JvmGlobals.writeUi16(ch, i);
			case StackAppend1(i1, t1):
				JvmGlobals.writeByte(ch, 252);
				JvmGlobals.writeUi16(ch, i1);
				writeVerificationType(ch, t1);
			case StackAppend2(i1, t1, t2):
				JvmGlobals.writeByte(ch, 253);
				JvmGlobals.writeUi16(ch, i1);
				writeVerificationType(ch, t1);
				writeVerificationType(ch, t2);
			case StackAppend3(i1, t1, t2, t3):
				JvmGlobals.writeByte(ch, 254);
				JvmGlobals.writeUi16(ch, i1);
				writeVerificationType(ch, t1);
				writeVerificationType(ch, t2);
				writeVerificationType(ch, t3);
			case StackFull(i1, tl1, tl2):
				JvmGlobals.writeByte(ch, 255);
				JvmGlobals.writeUi16(ch, i1);
				JvmGlobals.writeArray16(ch, writeVerificationType, tl1);
				JvmGlobals.writeArray16(ch, writeVerificationType, tl2);
		}
	}

	public static function writeAnnotation(ch:BytesOutput, ann:JAnnotation):Void {
		JvmGlobals.writeUi16(ch, ann.annType);
		JvmGlobals.writeArray16(ch, function(_, e:JAnnotationElement) {
			JvmGlobals.writeUi16(ch, e.index);
			writeElementValue(ch, e.value);
		}, ann.annElements);
	}

	static function writeElementValue(ch:BytesOutput, ev:JAnnotationElementValue):Void {
		JvmGlobals.writeByte(ch, ev.tag);
		switch (ev.value) {
			case ValConst(i): JvmGlobals.writeUi16(ch, i);
			case ValEnum(i1, i2):
				JvmGlobals.writeUi16(ch, i1);
				JvmGlobals.writeUi16(ch, i2);
			case ValClass(i): JvmGlobals.writeUi16(ch, i);
			case ValAnnotation(a): writeAnnotation(ch, a);
			case ValArray(l): JvmGlobals.writeArray16(ch, function(_, v) writeElementValue(ch, v), l);
		}
	}

	// the payload is written first, and the name it is filed under comes out of the match.
	public static function writeAttribute(pool:JvmConstantPool, jvma:JAttribute):JvmAttributeData {
		var ch = new BytesOutput();
		ch.bigEndian = true;
		function writeLocalTable(table:Array<JvmLocalDebug>):Void {
			JvmGlobals.writeArray16(ch, function(_, d:JvmLocalDebug) {
				JvmGlobals.writeUi16(ch, d.ldStartPc);
				JvmGlobals.writeUi16(ch, d.ldLength);
				JvmGlobals.writeUi16(ch, d.ldNameIndex);
				JvmGlobals.writeUi16(ch, d.ldDescriptorIndex);
				JvmGlobals.writeUi16(ch, d.ldIndex);
			}, table);
		}
		var name = switch (jvma) {
			case AttributeConstantValue(const):
				JvmGlobals.writeUi16(ch, const);
				"ConstantValue";
			case AttributeCode(code):
				JvmGlobals.writeUi16(ch, code.codeMaxStack);
				JvmGlobals.writeUi16(ch, code.codeMaxLocals);
				JvmGlobals.writeUi32(ch, code.codeCode.length);
				JvmGlobals.writeBytes(ch, code.codeCode);
				JvmGlobals.writeArray16(ch, JvmWriter.writeException, code.codeExceptions);
				JvmWriter.writeJvmAttributes(ch, code.codeAttributes);
				"Code";
			case AttributeStackMapTable(stackMap):
				JvmGlobals.writeArray16(ch, writeStackMapFrame, stackMap);
				"StackMapTable";
			case AttributeExceptions(a):
				JvmGlobals.writeArray16(ch, function(_, offset) JvmGlobals.writeUi16(ch, offset), a);
				"Exceptions";
			case AttributeInnerClasses(icl):
				JvmGlobals.writeArray16(ch, function(_, ic:JvmInnerClass) {
					JvmGlobals.writeUi16(ch, ic.icInnerClassInfoIndex);
					JvmGlobals.writeUi16(ch, ic.icOuterClassInfoIndex);
					JvmGlobals.writeUi16(ch, ic.icInnerNameIndex);
					JvmGlobals.writeUi16(ch, ic.icInnerClassAccessFlags);
				}, icl);
				"InnerClasses";
			case AttributeEnclosingMethod(i1, i2):
				JvmGlobals.writeUi16(ch, i1);
				JvmGlobals.writeUi16(ch, i2);
				"EnclosingMethod";
			case AttributeSourceFile(offset):
				JvmGlobals.writeUi16(ch, offset);
				"SourceFile";
			case AttributeLineNumberTable(a):
				JvmGlobals.writeArray16(ch, function(_, e) {
					JvmGlobals.writeUi16(ch, e.pc);
					JvmGlobals.writeUi16(ch, e.line);
				}, a);
				"LineNumberTable";
			case AttributeSignature(offset):
				JvmGlobals.writeUi16(ch, offset);
				"Signature";
			case AttributeLocalVariableTable(table):
				writeLocalTable(table);
				"LocalVariableTable";
			case AttributeLocalVariableTypeTable(table):
				writeLocalTable(table);
				"LocalVariableTypeTable";
			case AttributeRuntimeVisibleAnnotations(al):
				JvmGlobals.writeArray16(ch, writeAnnotation, al);
				"RuntimeVisibleAnnotations";
			case AttributeRuntimeVisibleParameterAnnotations(al):
				JvmGlobals.writeByte(ch, al.length);
				for (a in al) JvmGlobals.writeArray16(ch, writeAnnotation, a);
				"RuntimeVisibleParameterAnnotations";
			case AttributeBootstrapMethods(a):
				JvmGlobals.writeArray16(ch, function(_, bm:JBootstrapMethod) {
					JvmGlobals.writeUi16(ch, bm.bmMethodRef);
					JvmGlobals.writeArray16(ch, function(_, i) JvmGlobals.writeUi16(ch, i), bm.bmArguments);
				}, a);
				"BootstrapMethods";
		};
		return {attrIndex: pool.add(ConstUtf8(name)), attrData: ch.getBytes()};
	}
}
