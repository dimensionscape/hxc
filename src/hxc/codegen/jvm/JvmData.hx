package hxc.codegen.jvm;

import haxe.io.Bytes;
import hxc.core.Ref;
import hxc.codegen.jvm.JvmGlobals;

// the records that are written out, and the opcode set.

typedef JvmAttributeData = {attrIndex:JvmConstantPoolIndex, attrData:Bytes};

typedef JvmFieldData = {
	fieldAccessFlags:Int,
	fieldNameIndex:Int,
	fieldDescriptorIndex:Int,
	fieldAttributes:Array<JvmAttributeData>,
};

typedef JvmClassData = {
	classMinorVersion:Int,
	classMajorVersion:Int,
	classConstantPool:Bytes,
	classAccessFlags:Int,
	classThisClass:Int,
	classSuperClass:Int,
	classInterfaces:Array<Int>,
	classFields:Array<JvmFieldData>,
	classMethods:Array<JvmFieldData>,
	classAttributes:Array<JvmAttributeData>,
};

typedef JvmExceptionData = {
	excStartPc:Int,
	excEndPc:Int,
	excHandlerPc:Int,
	excCatchType:Null<JvmConstantPoolIndex>,
};

typedef JvmCodeData = {
	codeMaxStack:Int,
	codeMaxLocals:Int,
	codeCode:Bytes,
	codeExceptions:Array<JvmExceptionData>,
	codeAttributes:Array<JvmAttributeData>,
};

enum JCmp {
	CmpEq;
	CmpNe;
	CmpLt;
	CmpGe;
	CmpGt;
	CmpLe;
}

enum JOpWide {
	OpWIinc(a:Int, b:Int);
	OpWIload(a:Int);
	OpWFload(a:Int);
	OpWAload(a:Int);
	OpWLload(a:Int);
	OpWDload(a:Int);
	OpWIstore(a:Int);
	OpWFstore(a:Int);
	OpWAstore(a:Int);
	OpWLstore(a:Int);
	OpWDstore(a:Int);
}

enum JOpCode {
	OpD2f;
	OpD2i;
	OpD2l;
	OpDadd;
	OpDaload;
	OpDastore;
	OpDcmpg;
	OpDcmpl;
	OpDdiv;
	OpDconst_0;
	OpDconst_1;
	OpDload_0;
	OpDload_1;
	OpDload_2;
	OpDload_3;
	OpDload(a:Int);
	OpDmul;
	OpDneg;
	OpDrem;
	OpDreturn;
	OpDstore_0;
	OpDstore_1;
	OpDstore_2;
	OpDstore_3;
	OpDstore(a:Int);
	OpDsub;
	OpF2d;
	OpF2i;
	OpF2l;
	OpFadd;
	OpFaload;
	OpFastore;
	OpFcmpg;
	OpFcmpl;
	OpFdiv;
	OpFconst_0;
	OpFconst_1;
	OpFconst_2;
	OpFload_0;
	OpFload_1;
	OpFload_2;
	OpFload_3;
	OpFload(a:Int);
	OpFmul;
	OpFneg;
	OpFrem;
	OpFreturn;
	OpFstore_0;
	OpFstore_1;
	OpFstore_2;
	OpFstore_3;
	OpFstore(a:Int);
	OpFsub;
	OpI2b;
	OpI2c;
	OpI2d;
	OpI2f;
	OpI2l;
	OpI2s;
	OpIadd;
	OpIaload;
	OpIand;
	OpIastore;
	OpIconst_m1;
	OpIconst_0;
	OpIconst_1;
	OpIconst_2;
	OpIconst_3;
	OpIconst_4;
	OpIconst_5;
	OpIdiv;
	OpIload_0;
	OpIload_1;
	OpIload_2;
	OpIload_3;
	OpIload(a:Int);
	OpImul;
	OpIneg;
	OpIor;
	OpIrem;
	OpIreturn;
	OpIshl;
	OpIshr;
	OpIstore_0;
	OpIstore_1;
	OpIstore_2;
	OpIstore_3;
	OpIstore(a:Int);
	OpIsub;
	OpIushr;
	OpIxor;
	OpL2d;
	OpL2f;
	OpL2i;
	OpLadd;
	OpLaload;
	OpLand;
	OpLastore;
	OpLconst_0;
	OpLconst_1;
	OpLcmp;
	OpLdiv;
	OpLload_0;
	OpLload_1;
	OpLload_2;
	OpLload_3;
	OpLload(a:Int);
	OpLmul;
	OpLneg;
	OpLor;
	OpLrem;
	OpLreturn;
	OpLshl;
	OpLshr;
	OpLstore_0;
	OpLstore_1;
	OpLstore_2;
	OpLstore_3;
	OpLstore(a:Int);
	OpLsub;
	OpLushr;
	OpLxor;
	OpSaload;
	OpSastore;
	OpSipush(a:Int);
	OpAaload;
	OpAastore;
	OpAnewarray(a:Int);
	OpArraylength;
	OpBaload;
	OpBastore;
	OpBipush(a:Int);
	OpCaload;
	OpCastore;
	OpMultianewarray(a:Int, b:Int);
	OpNewarray(a:Int);
	OpAload_0;
	OpAload_1;
	OpAload_2;
	OpAload_3;
	OpAload(a:Int);
	OpAreturn;
	OpAstore_0;
	OpAstore_1;
	OpAstore_2;
	OpAstore_3;
	OpAstore(a:Int);
	OpNew(a:Int);
	OpInstanceof(a:Int);
	OpCheckcast(a:Int);
	OpInvokedynamic(a:Int);
	OpInvokeinterface(a:Int, b:Int);
	OpInvokespecial(a:Int);
	OpInvokestatic(a:Int);
	OpInvokevirtual(a:Int);
	OpGetfield(a:Int);
	OpGetstatic(a:Int);
	OpPutfield(a:Int);
	OpPutstatic(a:Int);
	OpIf_acmpeq(a:Ref<Int>);
	OpIf_acmpne(a:Ref<Int>);
	OpIf_icmp(a:JCmp, b:Ref<Int>);
	OpIf(a:JCmp, b:Ref<Int>);
	OpIfnonnull(a:Ref<Int>);
	OpIfnull(a:Ref<Int>);
	OpGoto(a:Ref<Int>);
	OpGoto_w(a:Ref<Int>);
	OpJsr(a:Ref<Int>);
	OpJsr_w(a:Ref<Int>);
	OpAconst_null;
	OpDup;
	OpDup_x1;
	OpDup_x2;
	OpDup2;
	OpDup2_x1;
	OpDup2_x2;
	OpLdc(a:Int);
	OpLdc_w(a:Int);
	OpLdc2_w(a:Int);
	OpNop;
	OpPop;
	OpPop2;
	OpSwap;
	OpAthrow;
	OpIinc(a:Int, b:Int);
	OpLookupswitch(pad:Int, def:Ref<Int>, cases:Array<{v:Int, offset:Ref<Int>}>);
	OpTableswitch(pad:Int, def:Ref<Int>, low:Int, high:Int, offsets:Array<Ref<Int>>);
	OpMonitorenter;
	OpMonitorexit;
	OpRet(a:Int);
	OpReturn;
	OpWide(a:JOpWide);
}
