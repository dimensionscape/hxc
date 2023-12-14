package hxc.generators.cpp;

import hxc.core.Type;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals.Path;
import hxc.generators.cpp.CppType;

// hxc.generators.cpp: the retype IR expression tree. One mutually-recursive group: the CppExpr node + its
// variants (CppExprDef) + the location and closure sub-types. The retype pass (CppRetype.hx) lowers the
// typed AST (TExpr) into this; the emitter turns it into C++ text. The fields are named `ctype` and
// `closeThis` because `type`/`this` are Haxe keywords.

// Tcppexpr (1409): a retyped node = its expression form + resolved C++ type + source position.
typedef CppExpr = {
	expr:CppExprDef,
	ctype:CppType,
	pos:Position,
}

typedef CppClosure = {
	closeType:CppType,
	closeArgs:Array<{v:TVar, dflt:Null<TExpr>}>,
	closeExpr:CppExpr,
	closeId:Int,
	closeUndeclared:Map<String, TVar>,
	closeThis:Null<CppThis>,
}

// Tcppcrementop (1426)
enum CppCrementOp {
	CppIncrement;
	CppDecrement;
}

// Tcppunop (1430)
enum CppUnop {
	CppNeg;
	CppNegBits;
	CppNot;
}

// Tcppthis (1435)
enum CppThis {
	ThisReal;
	ThisFake;
	ThisDynamic;
}

// Tcppvarloc (1440): a variable lvalue location
enum CppVarLoc {
	VarLocal(v:TVar);
	VarClosure(v:TVar);
	VarThis(cf:TClassField, t:CppType);
	VarInstance(e:CppExpr, cf:TClassField, clazz:String, op:String);
	VarInterface(e:CppExpr, cf:TClassField);
	VarStatic(c:TClass, objc:Bool, cf:TClassField);
	VarInternal(e:CppExpr, op:String, name:String);
}

// Tcppinst (1449)
enum CppInstKind {
	InstPtr;
	InstObjC;
	InstStruct;
}

// Tcppfuncloc (1454): a callable location
enum CppFuncLoc {
	FuncThis(cf:TClassField, t:CppType);
	FuncInstance(e:CppExpr, inst:CppInstKind, cf:TClassField);
	FuncStatic(c:TClass, objc:Bool, cf:TClassField);
	FuncTemplate(c:TClass, cf:TClassField, path:Path, native:Bool);
	FuncInterface(e:CppExpr, c:TClass, cf:TClassField);
	FuncEnumConstruct(e:TEnum, ef:TEnumField);
	FuncSuperConstruct(t:CppType);
	FuncSuper(thiz:CppThis, t:CppType, cf:TClassField);
	FuncNew(t:CppType);
	FuncExpression(e:CppExpr);
	FuncInternal(e:CppExpr, name:String, join:String);
	FuncExtern(name:String, isGlobal:Bool);
	FuncFromStaticFunction;
}

// Tcpparrayloc (1469): an array-element lvalue location
enum CppArrayLoc {
	ArrayTyped(arr:CppExpr, idx:CppExpr, elem:CppType);
	ArrayPointer(arr:CppExpr, idx:CppExpr);
	ArrayRawPointer(arr:CppExpr, idx:CppExpr);
	ArrayObject(arr:CppExpr, idx:CppExpr, elem:CppType);
	ArrayVirtual(arr:CppExpr, idx:CppExpr);
	ArrayImplements(c:TClass, arr:CppExpr, idx:CppExpr);
	ArrayDynamic(arr:CppExpr, idx:CppExpr);
}

// Tcpplvalue (1478): anything assignable
enum CppLValue {
	CppVarRef(loc:CppVarLoc);
	CppArrayRef(loc:CppArrayLoc);
	CppDynamicRef(e:CppExpr, name:String);
	CppExternRef(name:String, isGlobal:Bool);
}

enum CppExprDef {
	CppInt(v:haxe.Int32);
	CppFloat(s:String);
	CppString(s:String);
	CppBool(b:Bool);
	CppNull;
	CppNullAccess;
	CppNil;
	CppThis(t:CppThis);
	CppSuper(t:CppThis);
	CppCode(code:String, args:Array<CppExpr>);
	CppClosure(c:CppClosure);
	CppVar(loc:CppVarLoc);
	CppExtern(name:String, isGlobal:Bool);
	CppDynamicField(e:CppExpr, name:String);
	CppFunction(loc:CppFuncLoc, t:CppType);
	CppEnumIndex(e:CppExpr);
	CppEnumField(en:TEnum, ef:TEnumField);
	CppCall(loc:CppFuncLoc, args:Array<CppExpr>);
	CppFunctionAddress(c:TClass, cf:TClassField);
	CppNewNative(e:CppExpr);
	CppAddressOf(e:CppExpr);
	CppDereference(e:CppExpr);
	CppArray(loc:CppArrayLoc);
	CppCrement(op:CppCrementOp, flag:UnopFlag, lval:CppLValue);
	CppSet(lval:CppLValue, e:CppExpr);
	CppModify(op:Binop, lval:CppLValue, e:CppExpr);
	CppBinop(op:Binop, l:CppExpr, r:CppExpr);
	CppCompare(s:String, l:CppExpr, r:CppExpr, op:Binop);
	CppNullCompare(s:String, e:CppExpr);
	CppObjectDecl(fields:Array<{name:String, expr:CppExpr}>, isStruct:Bool);
	CppPosition(file:String, line:haxe.Int32, className:String, methodName:String);
	CppArrayDecl(items:Array<CppExpr>);
	CppUnop(op:CppUnop, e:CppExpr);
	CppVarDecl(v:TVar, e:Null<CppExpr>);
	CppBlock(items:Array<CppExpr>, closures:Array<CppClosure>, gc:Bool);
	CppFor(v:TVar, init:CppExpr, body:CppExpr);
	CppIf(cond:CppExpr, e1:CppExpr, e2:Null<CppExpr>);
	CppWhile(cond:CppExpr, body:CppExpr, flag:WhileFlag, id:Int);
	CppIntSwitch(cond:CppExpr, cases:Array<{values:Array<haxe.Int32>, body:CppExpr}>, def:Null<CppExpr>);
	CppSwitch(cond:CppExpr, condType:CppType, cases:Array<{values:Array<CppExpr>, body:CppExpr}>, def:Null<CppExpr>, id:Int);
	CppTry(body:CppExpr, catches:Array<{v:TVar, body:CppExpr}>);
	CppBreak;
	CppContinue;
	CppClassOf(path:Path, native:Bool);
	CppGoto(id:Int);
	CppReturn(e:Null<CppExpr>);
	CppThrow(e:CppExpr);
	CppEnumParameter(e:CppExpr, ef:TEnumField, index:Int);
	CppTCast(e:CppExpr, t:CppType);
	CppCast(e:CppExpr, t:CppType);
	CppCastStatic(e:CppExpr, t:CppType);
	CppCastScalar(e:CppExpr, s:String);
	CppCastVariant(e:CppExpr);
	CppCastObjC(e:CppExpr, c:TClass);
	CppCastObjCBlock(e:CppExpr, args:Array<CppType>, ret:CppType);
	CppCastProtocol(e:CppExpr, c:TClass);
	CppCastNative(e:CppExpr);
}
