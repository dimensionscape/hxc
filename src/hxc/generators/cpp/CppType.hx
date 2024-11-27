package hxc.generators.cpp;

import hxc.core.Type;

// hxc.generators.cpp.CppType: the C++ type lattice. The retype
// pass tags every expression with one of these; it drives boxing/unboxing, pointer vs value, and the
// emitted C++ type text. Named CppType (not TCpp) to avoid the TExpr/Texpr Windows header collision.
enum CppType {
	TCppDynamic;
	TCppUnchanged;
	TCppObject;
	TCppObjectPtr;
	TCppVoid;
	TCppNull;
	TCppEnum(e:TEnum);
	TCppScalar(s:String);
	TCppString;
	TCppFastIterator(t:CppType);
	TCppPointer(name:String, t:CppType);
	TCppRawPointer(name:String, t:CppType);
	TCppFunction(args:Array<CppType>, ret:CppType, abi:String);
	TCppObjCBlock(args:Array<CppType>, ret:CppType);
	TCppRest(t:CppType);
	TCppReference(t:CppType);
	TCppStruct(t:CppType);
	TCppStar(t:CppType, isConst:Bool);
	TCppVoidStar;
	TCppVarArg;
	TCppAutoCast;
	TCppDynamicArray;
	TCppObjectArray(t:CppType);
	TCppWrapped(t:CppType);
	TCppScalarArray(t:CppType);
	TCppObjC(c:TClass);
	TCppNativePointer(c:TClass);
	TCppVariant;
	TCppCode(t:CppType);
	TCppInst(c:TClass, params:Array<CppType>);
	TCppInterface(c:TClass);
	TCppProtocol(c:TClass);
	TCppClass;
	TCppGlobal;
}
