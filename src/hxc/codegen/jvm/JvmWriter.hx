package hxc.codegen.jvm;

import haxe.io.BytesOutput;
import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmData;

// The low-level writing of the class-file structures in JvmData.

class JvmWriter {
	public static function writeJvmAttribute(ch:BytesOutput, jvma:JvmAttributeData):Void {
		JvmGlobals.writeUi16(ch, jvma.attrIndex);
		JvmGlobals.writeUi32(ch, jvma.attrData.length);
		JvmGlobals.writeBytes(ch, jvma.attrData);
	}

	public static function writeJvmAttributes(ch:BytesOutput, jvmal:Array<JvmAttributeData>):Void {
		JvmGlobals.writeArray16(ch, writeJvmAttribute, jvmal);
	}

	public static function writeJvmField(ch:BytesOutput, jvmf:JvmFieldData):Void {
		JvmGlobals.writeUi16(ch, jvmf.fieldAccessFlags);
		JvmGlobals.writeUi16(ch, jvmf.fieldNameIndex);
		JvmGlobals.writeUi16(ch, jvmf.fieldDescriptorIndex);
		writeJvmAttributes(ch, jvmf.fieldAttributes);
	}

	public static function writeJvmClass(ch:BytesOutput, jvmc:JvmClassData):Void {
		JvmGlobals.writeByte(ch, 0xCA);
		JvmGlobals.writeByte(ch, 0xFE);
		JvmGlobals.writeByte(ch, 0xBA);
		JvmGlobals.writeByte(ch, 0xBE);
		JvmGlobals.writeUi16(ch, jvmc.classMinorVersion);
		JvmGlobals.writeUi16(ch, jvmc.classMajorVersion);
		JvmGlobals.writeBytes(ch, jvmc.classConstantPool);
		JvmGlobals.writeUi16(ch, jvmc.classAccessFlags);
		JvmGlobals.writeUi16(ch, jvmc.classThisClass);
		JvmGlobals.writeUi16(ch, jvmc.classSuperClass);
		JvmGlobals.writeUi16(ch, jvmc.classInterfaces.length);
		for (i in jvmc.classInterfaces) JvmGlobals.writeUi16(ch, i);
		JvmGlobals.writeUi16(ch, jvmc.classFields.length);
		for (f in jvmc.classFields) writeJvmField(ch, f);
		JvmGlobals.writeUi16(ch, jvmc.classMethods.length);
		for (f in jvmc.classMethods) writeJvmField(ch, f);
		writeJvmAttributes(ch, jvmc.classAttributes);
	}

	public static function writeException(ch:BytesOutput, jvme:JvmExceptionData):Void {
		JvmGlobals.writeUi16(ch, jvme.excStartPc);
		JvmGlobals.writeUi16(ch, jvme.excEndPc);
		JvmGlobals.writeUi16(ch, jvme.excHandlerPc);
		JvmGlobals.writeUi16(ch, jvme.excCatchType == null ? 0 : jvme.excCatchType);
	}

	public static function writeOpcode(ch:BytesOutput, code:JOpCode):Void {
		inline function w(i:Int) JvmGlobals.writeByte(ch, i);
		// A two-byte operand, big-endian.
		inline function bp(i:Int) {
			w((i >> 8) & 0xFF);
			w(i & 0xFF);
		}
		// A four-byte operand, big-endian.
		inline function b4(i:Int) {
			w((i >> 24) & 0xFF);
			w((i >> 16) & 0xFF);
			w((i >> 8) & 0xFF);
			w(i & 0xFF);
		}
		switch (code) {
			case OpD2f: w(0x90);
			case OpD2i: w(0x8e);
			case OpD2l: w(0x8f);
			case OpDadd: w(0x63);
			case OpDaload: w(0x31);
			case OpDastore: w(0x52);
			case OpDcmpg: w(0x98);
			case OpDcmpl: w(0x97);
			case OpDdiv: w(0x6f);
			case OpDconst_0: w(0xe);
			case OpDconst_1: w(0xf);
			case OpDload_0: w(0x26);
			case OpDload_1: w(0x27);
			case OpDload_2: w(0x28);
			case OpDload_3: w(0x29);
			case OpDload(a): w(0x18); w(a);
			case OpDmul: w(0x6b);
			case OpDneg: w(0x77);
			case OpDrem: w(0x73);
			case OpDreturn: w(0xaf);
			case OpDstore_0: w(0x47);
			case OpDstore_1: w(0x48);
			case OpDstore_2: w(0x49);
			case OpDstore_3: w(0x4a);
			case OpDstore(a): w(0x39); w(a);
			case OpDsub: w(0x67);
			case OpF2d: w(0x8d);
			case OpF2i: w(0x8b);
			case OpF2l: w(0x8c);
			case OpFadd: w(0x62);
			case OpFaload: w(0x30);
			case OpFastore: w(0x51);
			case OpFcmpg: w(0x96);
			case OpFcmpl: w(0x95);
			case OpFdiv: w(0x6e);
			case OpFconst_0: w(0xb);
			case OpFconst_1: w(0xc);
			case OpFconst_2: w(0xd);
			case OpFload_0: w(0x22);
			case OpFload_1: w(0x23);
			case OpFload_2: w(0x24);
			case OpFload_3: w(0x25);
			case OpFload(a): w(0x17); w(a);
			case OpFmul: w(0x6a);
			case OpFneg: w(0x76);
			case OpFrem: w(0x72);
			case OpFreturn: w(0xae);
			case OpFstore_0: w(0x43);
			case OpFstore_1: w(0x44);
			case OpFstore_2: w(0x45);
			case OpFstore_3: w(0x46);
			case OpFstore(a): w(0x38); w(a);
			case OpFsub: w(0x66);
			case OpI2b: w(0x91);
			case OpI2c: w(0x92);
			case OpI2d: w(0x87);
			case OpI2f: w(0x86);
			case OpI2l: w(0x85);
			case OpI2s: w(0x93);
			case OpIadd: w(0x60);
			case OpIaload: w(0x2e);
			case OpIand: w(0x7e);
			case OpIastore: w(0x4f);
			case OpIconst_m1: w(0x2);
			case OpIconst_0: w(0x3);
			case OpIconst_1: w(0x4);
			case OpIconst_2: w(0x5);
			case OpIconst_3: w(0x6);
			case OpIconst_4: w(0x7);
			case OpIconst_5: w(0x8);
			case OpIdiv: w(0x6c);
			case OpIload_0: w(0x1a);
			case OpIload_1: w(0x1b);
			case OpIload_2: w(0x1c);
			case OpIload_3: w(0x1d);
			case OpIload(a): w(0x15); w(a);
			case OpImul: w(0x68);
			case OpIneg: w(0x74);
			case OpIor: w(0x80);
			case OpIrem: w(0x70);
			case OpIreturn: w(0xac);
			case OpIshl: w(0x78);
			case OpIshr: w(0x7a);
			case OpIstore_0: w(0x3b);
			case OpIstore_1: w(0x3c);
			case OpIstore_2: w(0x3d);
			case OpIstore_3: w(0x3e);
			case OpIstore(a): w(0x36); w(a);
			case OpIsub: w(0x64);
			case OpIushr: w(0x7c);
			case OpIxor: w(0x82);
			case OpL2d: w(0x8a);
			case OpL2f: w(0x89);
			case OpL2i: w(0x88);
			case OpLadd: w(0x61);
			case OpLaload: w(0x2f);
			case OpLand: w(0x7f);
			case OpLastore: w(0x50);
			case OpLconst_0: w(0x9);
			case OpLconst_1: w(0xa);
			case OpLcmp: w(0x94);
			case OpLdiv: w(0x6d);
			case OpLload_0: w(0x1e);
			case OpLload_1: w(0x1f);
			case OpLload_2: w(0x20);
			case OpLload_3: w(0x21);
			case OpLload(a): w(0x16); w(a);
			case OpLmul: w(0x69);
			case OpLneg: w(0x75);
			case OpLor: w(0x81);
			case OpLrem: w(0x71);
			case OpLreturn: w(0xad);
			case OpLshl: w(0x79);
			case OpLshr: w(0x7b);
			case OpLstore_0: w(0x3f);
			case OpLstore_1: w(0x40);
			case OpLstore_2: w(0x41);
			case OpLstore_3: w(0x42);
			case OpLstore(a): w(0x37); w(a);
			case OpLsub: w(0x65);
			case OpLushr: w(0x7d);
			case OpLxor: w(0x83);
			case OpSaload: w(0x35);
			case OpSastore: w(0x56);
			case OpSipush(a): w(0x11); bp(a);
			case OpAaload: w(0x32);
			case OpAastore: w(0x53);
			case OpAnewarray(a): w(0xbd); bp(a);
			case OpArraylength: w(0xbe);
			case OpBaload: w(0x33);
			case OpBastore: w(0x54);
			case OpBipush(a): w(0x10); w(a);
			case OpCaload: w(0x34);
			case OpCastore: w(0x55);
			case OpMultianewarray(a, b): w(0xc5); bp(a); w(b);
			case OpNewarray(a): w(0xbc); w(a);
			case OpAload_0: w(0x2a);
			case OpAload_1: w(0x2b);
			case OpAload_2: w(0x2c);
			case OpAload_3: w(0x2d);
			case OpAload(a): w(0x19); w(a);
			case OpAreturn: w(0xb0);
			case OpAstore_0: w(0x4b);
			case OpAstore_1: w(0x4c);
			case OpAstore_2: w(0x4d);
			case OpAstore_3: w(0x4e);
			case OpAstore(a): w(0x3a); w(a);
			case OpNew(a): w(0xbb); bp(a);
			case OpInstanceof(a): w(0xc1); bp(a);
			case OpCheckcast(a): w(0xc0); bp(a);
			case OpInvokedynamic(a): w(0xba); bp(a); w(0); w(0);
			case OpInvokeinterface(a, b): w(0xb9); bp(a); w(b); w(0);
			case OpInvokespecial(a): w(0xb7); bp(a);
			case OpInvokestatic(a): w(0xb8); bp(a);
			case OpInvokevirtual(a): w(0xb6); bp(a);
			case OpGetfield(a): w(0xb4); bp(a);
			case OpGetstatic(a): w(0xb2); bp(a);
			case OpPutfield(a): w(0xb5); bp(a);
			case OpPutstatic(a): w(0xb3); bp(a);
			case OpIf_acmpeq(a): w(0xa5); bp(a.value);
			case OpIf_acmpne(a): w(0xa6); bp(a.value);
			case OpIfnonnull(a): w(0xc7); bp(a.value);
			case OpIfnull(a): w(0xc6); bp(a.value);
			case OpGoto(a): w(0xa7); bp(a.value);
			case OpGoto_w(a): w(0xc8); b4(a.value);
			case OpJsr(a): w(0xa8); bp(a.value);
			case OpJsr_w(a): w(0xc9); b4(a.value);
			case OpAconst_null: w(0x1);
			case OpDup: w(0x59);
			case OpDup_x1: w(0x5a);
			case OpDup_x2: w(0x5b);
			case OpDup2: w(0x5c);
			case OpDup2_x1: w(0x5d);
			case OpDup2_x2: w(0x5e);
			case OpLdc(a): w(0x12); w(a);
			case OpLdc_w(a): w(0x13); bp(a);
			case OpLdc2_w(a): w(0x14); bp(a);
			case OpNop: w(0x0);
			case OpPop: w(0x57);
			case OpPop2: w(0x58);
			case OpSwap: w(0x5f);
			case OpAthrow: w(0xbf);
			case OpIinc(a, b): w(0x84); w(a); w(b);
			case OpMonitorenter: w(0xc2);
			case OpMonitorexit: w(0xc3);
			case OpRet(a): w(0xa9); w(a);
			case OpReturn: w(0xb1);
			// The comparison is part of the opcode.
			case OpIf(a, b): w(switch (a) {
					case CmpEq: 0x99; case CmpNe: 0x9a; case CmpLt: 0x9b;
					case CmpGe: 0x9c; case CmpGt: 0x9d; case CmpLe: 0x9e;
				}); bp(b.value);
			case OpIf_icmp(a, b): w(switch (a) {
					case CmpEq: 0x9f; case CmpNe: 0xa0; case CmpLt: 0xa1;
					case CmpGe: 0xa2; case CmpGt: 0xa3; case CmpLe: 0xa4;
				}); bp(b.value);
			// `pad` aligns the operands that follow to a four-byte boundary.
			case OpLookupswitch(pad, def, pairs):
				w(0xab);
				for (_ in 0...pad) w(0);
				b4(def.value);
				b4(pairs.length);
				for (p in pairs) {
					b4(p.v);
					b4(p.offset.value);
				}
			case OpTableswitch(pad, def, low, high, offsets):
				w(0xaa);
				for (_ in 0...pad) w(0);
				b4(def.value);
				b4(low);
				b4(high);
				for (o in offsets) b4(o.value);
			case OpWide(op):
				w(0xc4);
				switch (op) {
					case OpWIinc(a, b): w(0x84); bp(a); bp(b);
					case OpWIload(a): w(0x15); bp(a);
					case OpWFload(a): w(0x17); bp(a);
					case OpWAload(a): w(0x19); bp(a);
					case OpWLload(a): w(0x16); bp(a);
					case OpWDload(a): w(0x18); bp(a);
					case OpWIstore(a): w(0x36); bp(a);
					case OpWFstore(a): w(0x38); bp(a);
					case OpWAstore(a): w(0x3a); bp(a);
					case OpWLstore(a): w(0x37); bp(a);
					case OpWDstore(a): w(0x39); bp(a);
				}
		}
	}
}
