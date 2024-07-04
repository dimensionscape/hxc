package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.generators.cpp.CppType;
import hxc.generators.cpp.CppExpr;
import hxc.generators.cpp.CppTypeOf;
import hxc.generators.cpp.CppTypeText;

// hxc.generators.cpp.CppRetype: lower the typed AST (TExpr) into the cpp IR (CppExpr), (retype_expression).
// This is the highest-risk, byte-exactness-determining pass; it threads a requested C++ type down the tree
// and decides every box/unbox/cast/temp. Ported in tranches (see docs/cpp/RETYPE_IR.md): the scaffold +
// autocast tail + simple arms land first; the TField/TCall/TNew/TFunction/TBinop/TUnop/TSwitch/TTry/...
// arms follow. Unported arms throw loudly. Named CppRetype (not Retype) to avoid the
// ModuleCheckPolicy.Retype enum-constructor collision.
class CppRetype {
	public static inline function mkCppExpr(def:CppExprDef, t:CppType, pos:Position):CppExpr {
		return {expr: def, ctype: t, pos: pos};
	}

	// TNull/TThis/TSuper are handled by the caller's arms.
	public static function cppConstType(cval:TConstant):{def:CppExprDef, t:CppType} {
		return switch (cval) {
			case TInt(i): {def: CppInt(i), t: TCppScalar("int")};
			case TBool(b): {def: CppBool(b), t: TCppScalar("bool")};
			case TFloat(f): {def: CppFloat(StringTools.replace(f, "_", "")), t: TCppScalar("Float")};
			case TString(s): {def: CppString(s), t: TCppString};
			case _: {def: CppNull, t: TCppNull};
		}
	}

	// `fileId` is the shared unique-id counter.
	public static function retypeExpression(com:Context, realThisPtr:Bool, fileId:{v:Int}, requestType:CppType,
			functionArgs:Array<TVar>, functionType:T, exprTree:TExpr, forInjection:Bool):CppExpr {
		return new RetypeSession(com, realThisPtr, fileId, functionArgs, functionType, forInjection).retype(requestType, exprTree);
	}

	// The cppia writer resolves the constructor prototype the same way TNew retyping does.
	public static function resolveConstructorOverload(c:TClass, tl:Array<T>, args:Array<TExpr>):Null<TClassField> {
		return RetypeSession.selectConstructor(c, tl, args);
	}
}

// One retypeExpression call's mutable state + the recursive lowering.
private class RetypeSession {
	final com:Context;
	final forCppia:Bool;
	final fileId:{v:Int};
	var declarations:Map<String, Bool>;
	var undeclared:Map<String, TVar>;
	// Insertion order of `undeclared` (first-insert encounter order); feeds the hash-table bucket-order
	// model that fixes the emitted capture order.
	var undeclaredOrder:Array<String>;
	var gcStack:Bool;
	var injection:Bool;
	var thisReal:CppThis;
	var functionReturnType:CppType;
	var revClosures:Array<CppClosure>;
	var closureId:Int;
	var usesThis:Null<CppThis>;
	final loopStack:Array<{id:Int, used:{v:Bool}}>;

	public function new(com:Context, realThisPtr:Bool, fileId:{v:Int}, functionArgs:Array<TVar>, functionType:T, forInjection:Bool) {
		this.com = com;
		this.fileId = fileId;
		this.forCppia = com.defines.rawDefined("cppia");
		this.declarations = new Map();
		this.undeclared = new Map();
		this.undeclaredOrder = [];
		this.gcStack = false;
		this.injection = forInjection;
		this.thisReal = realThisPtr ? ThisReal : ThisDynamic;
		this.functionReturnType = CppTypeOf.cppTypeOf(functionType);
		this.revClosures = [];
		this.closureId = 0;
		this.usesThis = null;
		this.loopStack = [];
		declarations.set("__trace", true); // __trace is a top-level function.
		for (a in functionArgs) declarations.set(a.name, true);
	}

	inline function mk(def:CppExprDef, t:CppType, pos:Position):CppExpr {
		return {expr: def, ctype: t, pos: pos};
	}

	function allocFileId():Int { fileId.v++; return fileId.v; }

	// Push a loop label; the returned close() yields the label id if a
	// break used it (via CppGoto), else -1
	function beginLoop():Void->Int {
		var entry = {id: allocFileId(), used: {v: false}};
		loopStack.unshift(entry);
		return function():Int {
			if (loopStack.length == 0) throw new hxc.core.TypingError("Invalid internal loop handling", hxc.ast.Position.nullPos);
			var top = loopStack.shift();
			return top.used.v ? top.id : -1;
		};
	}

	// Dispatch, wrap, then apply the autocast tail.
	public function retype(returnType:CppType, expr:TExpr):CppExpr {
		var pair = dispatch(returnType, expr);
		var cppExpr = mk(pair.def, pair.t, expr.pos);
		return autocast(returnType, cppExpr, pair.def, expr.pos);
	}

	function dispatch(returnType:CppType, expr:TExpr):{def:CppExprDef, t:CppType} {
		return switch (expr.expr) {
			case TConst(TThis):
				usesThis = thisReal;
				{def: CppThis(thisReal), t: thisReal == ThisDynamic ? TCppDynamic : CppTypeOf.cppTypeOf(expr.type)};
			case TConst(TSuper):
				usesThis = thisReal;
				{def: CppSuper(thisReal), t: thisReal == ThisDynamic ? TCppDynamic : CppTypeOf.cppTypeOf(expr.type)};
			case TConst(c):
				var ct = CppRetype.cppConstType(c);
				{def: ct.def, t: ct.t};
			// TLocal: an in-scope local reads as VarLocal; an out-of-scope one is a capture
			// (VarClosure if flagged VCaptured, else an extern reference) and is recorded as undeclared.
			case TLocal(tvar):
				if (declarations.exists(tvar.name)) {def: CppVar(VarLocal(tvar)), t: CppTypeOf.cppTypeOf(tvar.type)};
				else {
					if (!undeclared.exists(tvar.name)) undeclaredOrder.push(tvar.name);
					undeclared.set(tvar.name, tvar);
					if (TypeFunctions.hasVarFlag(tvar, VCaptured)) {def: CppVar(VarClosure(tvar)), t: CppTypeOf.cppTypeOf(tvar.type)};
					else {def: CppExtern(tvar.name, false), t: CppTypeOf.cppTypeOf(tvar.type)};
				}
			case TIdent("__global__"): {def: CppClassOf({pack: [], name: ""}, false), t: TCppGlobal};
			case TIdent(name): {def: CppExtern(name, false), t: returnType};
			// TIf (3128): condition in bool context; branches blockified only in statement (Void) context
			case TIf(ec, e1, e2):
				var recEc = retype(TCppScalar("bool"), ec);
				var isValue = !returnType.match(TCppVoid);
				var recE1 = retype(returnType, isValue ? e1 : TypeFunctions.mkBlock(e1));
				var recE2 = e2 == null ? null : retype(returnType, isValue ? e2 : TypeFunctions.mkBlock(e2));
				{def: CppIf(recEc, recE1, recE2), t: isValue ? CppTypeOf.cppTypeOf(expr.type) : TCppVoid};
			// TCast without a target type (3182): auto-cast rules keyed on the C++ type text
			case TCast(base, null):
				var castType = CppTypeOf.cppTypeOf(expr.type);
				var baseCpp = retype(castType, base);
				var baseStr = CppTypeText.tcppToString(baseCpp.ctype);
				if (baseStr == CppTypeText.tcppToString(castType)) {def: baseCpp.expr, t: baseCpp.ctype};
				else switch (castType) {
					case TCppObjC(k): {def: CppCastObjC(baseCpp, k), t: castType};
					case TCppPointer(_, _) | TCppRawPointer(_, _) | TCppStar(_, _) | TCppInst(_, _): {def: CppCast(baseCpp, castType), t: castType};
					case TCppString: {def: CppCastScalar(baseCpp, "::String"), t: castType};
					case TCppCode(t) if (baseStr != CppTypeText.tcppToString(t)): {def: CppCast(baseCpp, t), t: t};
					case TCppNativePointer(_): {def: CppCastNative(baseCpp), t: castType};
					case TCppObjCBlock(args, ret): {def: CppCastObjCBlock(baseCpp, args, ret), t: castType};
					case TCppProtocol(p): {def: CppCastProtocol(baseCpp, p), t: castType};
					case TCppDynamic if (baseCpp.ctype.match(TCppClass)): {def: CppCast(baseCpp, TCppDynamic), t: TCppDynamic};
					case _: {def: baseCpp.expr, t: baseCpp.ctype};
				}
			// TCast with a target type (3205): an explicit cast(e, T), resolved via the type path
			case TCast(base, mt):
				var baseCpp = retype(CppTypeOf.cppTypeOf(base.type), base);
				var baseStr = CppTypeText.tcppToString(baseCpp.ctype);
				var defaultReturnType = returnType.match(TCppUnchanged) ? CppTypeOf.cppTypeOf(expr.type) : returnType;
				var castType = CppTypeOf.cppTypeFromPathOf(CppTypeOf.tPath(mt), [], function() return defaultReturnType);
				if (baseStr == CppTypeText.tcppToString(castType)) {def: baseCpp.expr, t: baseCpp.ctype};
				else switch (castType) {
					case TCppNativePointer(_): {def: CppCastNative(baseCpp), t: castType};
					case TCppVoid: {def: CppTCast(baseCpp, CppTypeOf.cppTypeOf(expr.type)), t: castType};
					case TCppDynamic: {def: baseCpp.expr, t: baseCpp.ctype};
					case _: {def: CppTCast(baseCpp, castType), t: castType};
				}
			// TBinop: assignment/compound-assign via toLvalue, the null/instance/pointer/complex
			// comparison dispatch, else a plain CppBinop
			case TBinop(op, left, right):
				var binOpType = switch (op) {
					case OpDiv: TCppScalar("Float");
					case OpBoolAnd | OpBoolOr: TCppScalar("bool");
					case OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr: TCppScalar("int");
					case OpAssign: retype(TCppUnchanged, left).ctype;
					case OpMult | OpSub: CppTypeOf.cppTypeOf(expr.type);
					case _: TCppUnchanged;
				};
				var e1 = retype(binOpType, left);
				var e2 = retype(binOpType, right);
				var complex = isComplexCompare(e1.ctype) || isComplexCompare(e2.ctype);
				var pointer = isPointerCompare(e1.ctype) || isPointerCompare(e2.ctype);
				var instance = isInstanceCompare(e1.ctype) || isInstanceCompare(e2.ctype);
				var e1Null = e1.ctype.match(TCppNull);
				var e2Null = e2.ctype.match(TCppNull);
				var ref:CppExprDef = switch (op) {
					case OpAssign: var lv = toLvalue(e1); if (lv.gc) gcStack = true; CppSet(lv.lvalue, e2);
					case OpAssignOp(o): var lv = toLvalue(e1); if (lv.gc) gcStack = true; CppModify(o, lv.lvalue, e2);
					case OpEq | OpGte | OpLte if (e1Null && e2Null): CppBool(true);
					case _ if (e1Null && e2Null): CppBool(false);
					case OpEq | OpGte | OpLte if (e1Null): CppNullCompare("IsNull", e2);
					case OpNotEq if (e1Null): CppNullCompare("IsNotNull", e2);
					case OpEq | OpGte | OpLte if (e2Null): CppNullCompare("IsNull", e1);
					case OpNotEq if (e2Null): CppNullCompare("IsNotNull", e1);
					case OpEq if (instance): CppCompare("IsInstanceEq", e1, e2, op);
					case OpNotEq if (instance): CppCompare("IsInstanceNotEq", e1, e2, op);
					case OpEq if (pointer): CppCompare("IsPointerEq", e1, e2, op);
					case OpNotEq if (pointer): CppCompare("IsPointerNotEq", e1, e2, op);
					case OpEq if (complex): CppCompare("IsEq", e1, e2, op);
					case OpNotEq if (complex): CppCompare("IsNotEq", e1, e2, op);
					case OpGte if (complex): CppCompare("IsGreaterEq", e1, e2, op);
					case OpLte if (complex): CppCompare("IsLessEq", e1, e2, op);
					case OpGt if (complex): CppCompare("IsGreater", e1, e2, op);
					case OpLt if (complex): CppCompare("IsLess", e1, e2, op);
					case _: CppBinop(op, e1, e2);
				};
				switch [op, e1.ctype, e2.ctype] {
					case [OpAdd, _, TCppVariant] | [OpAdd, TCppVariant, _]: {def: ref, t: TCppVariant};
					case _: {def: ref, t: CppTypeOf.cppTypeOf(expr.type)};
				}
			// Break/continue/throw (2519/2530/2533)
			case TBreak:
				if (forCppia) {def: CppBreak, t: TCppVoid} else switch (loopStack) {
					case []: {def: CppBreak, t: TCppVoid};
					case _: var top = loopStack[0]; top.used.v = true; {def: CppGoto(top.id), t: TCppVoid};
				}
			case TContinue: {def: CppContinue, t: TCppVoid};
			case TThrow(e1): {def: CppThrow(retype(TCppDynamic, e1)), t: TCppVoid};
			// TMeta(Fixed) re-flags an object decl as a struct (2536); other meta/parens pass through (2543)
			case TMeta(m, e1) if (m.name == ":fixed"):
				var c = retype(returnType, e1);
				switch (c.expr) {
					case CppObjectDecl(fields, false): {def: CppObjectDecl(fields, true), t: c.ctype};
					case _: {def: c.expr, t: c.ctype};
				}
			case TMeta(_, e1): var c = retype(returnType, e1); {def: c.expr, t: c.ctype};
			case TParenthesis(e1): var c = retype(returnType, e1); {def: c.expr, t: c.ctype};
			case TArrayDecl(el): {def: CppArrayDecl([for (e in el) retype(TCppDynamic, e)]), t: CppTypeOf.cppTypeOf(expr.type)};
			// TArray (2936): array element access, dispatched by the receiver's cpp array kind, then
			// wrapped in a static cast when the element type needs narrowing to the expression type
			case TArray(e1, e2):
				var res:{arr:CppExprDef, elem:CppType} = if (CppTypeOf.cppIsNativeArrayAccess(CppTypeOf.cppTypeOf(e1.type))) {
					var obj = retype(TCppUnchanged, e1);
					var idx = retype(TCppScalar("int"), e2);
					{arr: CppArray(ArrayRawPointer(obj, idx)), elem: CppTypeOf.cppTypeOf(expr.type)};
				} else {
					var obj = retype(TCppDynamic, e1);
					var idx = retype(TCppScalar("int"), e2);
					switch (obj.ctype) {
						case TCppScalarArray(scalar): {arr: CppArray(ArrayTyped(obj, idx, scalar)), elem: scalar};
						case TCppPointer(_, elem): {arr: CppArray(ArrayPointer(obj, idx)), elem: elem};
						case TCppRawPointer(_, elem): {arr: CppArray(ArrayRawPointer(obj, idx)), elem: elem};
						case TCppObjectArray(TCppDynamic): {arr: CppArray(ArrayObject(obj, idx, TCppDynamic)), elem: TCppDynamic};
						case TCppObjectArray(elem): {arr: CppArray(ArrayObject(obj, idx, elem)), elem: elem};
						case TCppInst(klass, _) if (klass.arrayAccess != null): {arr: CppArray(ArrayImplements(klass, obj, idx)), elem: CppTypeOf.cppTypeOf(expr.type)};
						case TCppDynamicArray: {arr: CppArray(ArrayVirtual(obj, idx)), elem: TCppDynamic};
						case _: {arr: CppArray(ArrayDynamic(obj, idx)), elem: TCppDynamic};
					}
				};
				var returnT = CppTypeOf.cppTypeOf(expr.type);
				if (CppTypeText.cppCanStaticCast(res.elem, returnT)) {def: CppCastStatic(mk(res.arr, returnT, expr.pos), returnT), t: returnT};
				else {def: res.arr, t: res.elem};
			// TBlock (3083): each element retyped in Void context (the last at its value type when the
			// block's value is being injected into a caller variable); declarations/closures are scoped.
			case TBlock(exprList):
				var inject = injection;
				injection = false;
				var oldDeclarations = declarations.copy();
				var oldClosures = revClosures;
				revClosures = [];
				var localClosures:Array<CppClosure> = [];
				var remaining = exprList.length;
				var cppExprs:Array<CppExpr> = [];
				for (e in exprList) {
					var targetType = (inject && remaining == 1) ? CppTypeOf.cppTypeOf(e.type) : TCppVoid;
					remaining--;
					var result = retype(targetType, e);
					localClosures = revClosures.concat(localClosures);
					revClosures = [];
					cppExprs.push(result);
				}
				declarations = oldDeclarations;
				revClosures = oldClosures;
				var closures = localClosures.copy();
				closures.reverse();
				{def: CppBlock(cppExprs, closures, gcStack), t: TCppVoid};
			case TNew(classDef, tl, args):
				var ctor = selectConstructor(classDef, tl, args);
				var argTypes = ctor == null ? [] : CppTypeOf.cppFunctionArgsRet(ctor.type).args;
				var retypedArgs = retypeFunctionArgs(args, argTypes, expr);
				var createdType = CppTypeOf.cppTypeOf(expr.type);
				gcStack = gcStack || switch (createdType) { case TCppInst(t, _): !CppTypeOf.isNativeClass(t); case _: false; };
				{def: CppCall(FuncNew(createdType), retypedArgs), t: createdType};
			// TFunction: a closure. Save/swap all scope state, retype the body with `this` faked
			// and fresh declarations/captures, build the closure, then propagate its free vars (captures)
			// that aren't local here up to the enclosing scope and hoist the closure onto revClosures.
			case TFunction(func):
				var oldThisReal = thisReal;
				thisReal = ThisFake;
				var oldUndeclared = undeclared;
				var oldUndeclaredOrder = undeclaredOrder;
				var oldDeclarations = declarations;
				var oldUsesThis = usesThis;
				var oldGcStack = gcStack;
				var oldReturnType = functionReturnType;
				var ret = CppTypeOf.cppTypeOf(func.type);
				functionReturnType = ret;
				usesThis = null;
				undeclared = new Map();
				undeclaredOrder = [];
				declarations = new Map();
				for (a in func.args) declarations.set(a.v.name, true);
				var cppExpr = retype(TCppVoid, TypeFunctions.mkBlock(func.expr));
				// Captures are emitted in hash-table walk order: buckets ascend over the hash of the name,
				// chains newest-first.
				// Reproduce that walk from the encounter order via the calibrated model.
				var iterOrder = {
					var h = new hxc.core.NameHash.HashTableOrder();
					for (n in undeclaredOrder) h.add(n, hxc.core.NameHash.NameHash.stringHash(n));
					h.visitOrder();
				};
				var result:CppClosure = {
					closeExpr: cppExpr,
					closeId: closureId,
					closeUndeclared: undeclared,
					closeUndeclaredOrder: iterOrder,
					closeType: ret,
					closeArgs: [for (a in func.args) {v: a.v, dflt: a.c}],
					closeThis: usesThis,
				};
				closureId++;
				var childUndeclared = undeclared;
				declarations = oldDeclarations;
				undeclared = oldUndeclared;
				undeclaredOrder = oldUndeclaredOrder;
				// Re-insert the child's captures into the enclosing table in the child's bucket-walk order,
				// so the parent's insertion order follows that walk.
				for (name in iterOrder) {
					var tvar = childUndeclared.get(name);
					if (!declarations.exists(name)) {
						if (!undeclared.exists(name)) undeclaredOrder.push(name);
						undeclared.set(name, tvar);
					}
				}
				functionReturnType = oldReturnType;
				thisReal = oldThisReal;
				usesThis = (usesThis != null) ? oldThisReal : oldUsesThis;
				gcStack = oldGcStack;
				revClosures.unshift(result);
				{def: CppClosure(result), t: TCppDynamic};
			// TVarExpr (3122): a local var declaration; its initializer is retyped at the var's cpp type
			case TVarExpr(v, e):
				var varType = CppTypeOf.cppTypeOf(v.type);
				var init = e == null ? null : retype(varType, e);
				declarations.set(v.name, true);
				{def: CppVarDecl(v, init), t: varType};
			case TReturn(null): {def: CppReturn(null), t: TCppVoid};
			case TReturn(e1): {def: CppReturn(retype(functionReturnType, e1)), t: TCppVoid};
			// TEnumParameter (2476): the nth argument of an enum value; its type is the enum field's nth
			// argument type cast to a variant.
			case TEnumParameter(enumObj, enumField, enumIndex):
				var retypedObj = retype(TCppDynamic, enumObj);
				var t = CppTypeOf.cppCastVariantTypeOf(CppTypeOf.cppTypeOf(CppTypeOf.getNthType(enumField, enumIndex)));
				{def: CppEnumParameter(retypedObj, enumField, enumIndex), t: t};
			case TEnumIndex(enumObj): {def: CppEnumIndex(retype(TCppDynamic, enumObj)), t: TCppScalar("int")};
			// TObjectDecl (3108/3115): a {fileName,lineNumber,className,methodName} shape becomes a
			// CppPosition; any other anon object becomes a CppObjectDecl
			case TObjectDecl(fields):
				switch (matchPosInfo(fields)) {
					case null:
						var retypedEls = [for (f in fields) {name: f.key.name, expr: retype(TCppDynamic, f.expr)}];
						{def: CppObjectDecl(retypedEls, false), t: returnType.match(TCppVoid) ? TCppVoid : TCppDynamic};
					case p: {def: p, t: TCppDynamic};
				}
			// TSwitch (3137): statement-context switch. An int/bool condition with all-const-int cases
			// lowers to CppIntSwitch; otherwise (e.g. string switch) each case block is terminated with a
			// CppGoto to a shared label and it lowers to CppSwitch.
			case TSwitch(condition, cases, def):
				var conditionType = CppTypeOf.cppTypeOf(condition.type);
				var recCond = retype(conditionType, condition);
				var cppDef = def == null ? null : retype(TCppVoid, TypeFunctions.mkBlock(def));
				var isIntCond = switch (conditionType) { case TCppScalar("int") | TCppScalar("bool"): true; case _: false; };
				if (!forCppia && isIntCond && allIntCases(cases)) {
					var intCases = [for (c in cases) {values: [for (v in c.values) constIntOf(v)], body: retype(TCppVoid, TypeFunctions.mkBlock(c.expr))}];
					{def: CppIntSwitch(recCond, intCases, cppDef), t: TCppVoid};
				} else if (forCppia) {
					var recCases = [for (c in cases) {values: [for (v in c.values) retype(conditionType, v)], body: retype(TCppVoid, TypeFunctions.mkBlock(c.expr))}];
					{def: CppSwitch(recCond, conditionType, recCases, cppDef, -1), t: TCppVoid};
				} else {
					var label = allocFileId();
					var recCases = [for (c in cases) {
						var body = retype(TCppVoid, TypeFunctions.mkBlock(c.expr));
						var withGoto = cppAppendBlock(body, mk(CppGoto(label), TCppVoid, c.expr.pos));
						{values: [for (v in c.values) retype(conditionType, v)], body: withGoto};
					}];
					{def: CppSwitch(recCond, conditionType, recCases, cppDef, label), t: TCppVoid};
				}
			// TTry (3165): a statement-context try; the try and each (scoped) catch retype in Void context
			case TTry(tryBlock, catches):
				var cppBlock = retype(TCppVoid, tryBlock);
				var cppCatches = [for (c in catches) {
					var oldDeclarations = declarations.copy();
					declarations.set(c.v.name, true);
					var cb = retype(TCppVoid, c.expr);
					declarations = oldDeclarations;
					{v: c.v, body: cb};
				}];
				{def: CppTry(cppBlock, cppCatches), t: TCppVoid};
			// TTypeExpr: a type reference becomes CppClassOf; the cpp.Int64 impl maps to cpp.Int64
			case TTypeExpr(mt):
				var path = switch (mt) {
					case TClassDecl(c) if (c.path.pack.length == 2 && c.path.pack[0] == "cpp" && c.path.pack[1] == "_Int64" && c.path.name == "Int64_Impl_"): {pack: ["cpp"], name: "Int64"};
					case _: CppTypeOf.tPath(mt);
				};
				{def: CppClassOf(path, CppTypeOf.isNativeGenModule(mt)), t: TCppClass};
			// TFor (3065): scoped loop var; init at the var's cpp type, body in Void context
			case TFor(v, init, block):
				var oldDeclarations = declarations.copy();
				declarations.set(v.name, true);
				var recInit = retype(CppTypeOf.cppTypeOf(v.type), init);
				var recBlock = retype(TCppVoid, TypeFunctions.mkBlock(block));
				declarations = oldDeclarations;
				{def: CppFor(v, recInit, recBlock), t: TCppVoid};
			// TWhile (3073): condition in bool context; a loop label is allocated for break -> goto
			case TWhile(e1, e2, flag):
				var condition = retype(TCppScalar("bool"), e1);
				var close = beginLoop();
				var block = retype(TCppVoid, TypeFunctions.mkBlock(e2));
				{def: CppWhile(condition, block, flag, close()), t: TCppVoid};
			// TUnop: increment/decrement via toLvalue -> CppCrement, else CppUnop
			case TUnop(op, pre, e1):
				var targetType = switch (op) {
					case Not: TCppScalar("bool");
					case NegBits: TCppScalar("int");
					case _: CppTypeOf.cppTypeOf(e1.type);
				};
				var re1 = retype(targetType, e1);
				var ref:CppExprDef = switch (op) {
					case Increment: var lv = toLvalue(re1); if (lv.gc) gcStack = true; CppCrement(CppIncrement, pre, lv.lvalue);
					case Decrement: var lv = toLvalue(re1); if (lv.gc) gcStack = true; CppCrement(CppDecrement, pre, lv.lvalue);
					case Neg: CppUnop(CppNeg, re1);
					case Not: CppUnop(CppNot, re1);
					case NegBits: CppUnop(CppNegBits, re1);
					case Spread: throw new hxc.core.TypingError("Unexpected spread operator", expr.pos);
				};
				{def: ref, t: CppTypeOf.cppTypeOf(expr.type)};
			// TField (2548): the FStatic + FEnum arms (instance/anon/dynamic follow in a later tranche)
			case TField(_, FStatic(_, member)) if (member.name == "nativeFromStaticFunction"):
				{def: CppFunction(FuncFromStaticFunction, CppTypeOf.cppMemberReturnType(member)), t: CppTypeOf.cppTypeOf(member.type)};
			case TField(_, FStatic(clazz, member)):
				var exprType = CppTypeOf.cppTypeOf(member.type);
				var objC = CppTypeOf.isObjcClass(clazz);
				if (CppTypeOf.isVarField(member)) {def: CppVar(VarStatic(clazz, objC, member)), t: exprType};
				else {def: CppFunction(FuncStatic(clazz, objC, member), CppTypeOf.cppMemberReturnType(member)), t: exprType};
			case TField(_, FEnum(en, ef)): {def: CppEnumField(en, ef), t: TCppEnum(en)};
			// Resolve an instance field or bound method.
			case TField(obj, FInstance(clazz, params, member)): fieldInstance(obj, clazz, params, member, expr);
			case TField(obj, FClosure(cwp, member)) if (cwp != null): fieldInstance(obj, cwp.c, cwp.params, member, expr);
			// FDynamic (2670): a reflective field access, with String/enum/array/global/class specials
			case TField(obj, FDynamic(fieldName)):
				var o = retype(TCppDynamic, obj);
				if (o.ctype.match(TCppNull)) {def: CppNullAccess, t: TCppDynamic};
				else if (fieldName == "cca" && o.ctype.match(TCppString)) {def: CppFunction(FuncInternal(o, "cca", "."), TCppScalar("int")), t: TCppDynamic};
				else if (fieldName == "__s" && o.ctype.match(TCppString)) {def: CppVar(VarInternal(o, ".", "utf8_str()")), t: TCppRawPointer("const ", TCppScalar("char"))};
				else if (fieldName == "__Index") {def: CppEnumIndex(o), t: TCppScalar("int")};
				// A field of __global__ is a global extern (checked before the internal-member routing, so
				// `__global__.__hxcpp_println` becomes ::__hxcpp_println, not a member call on the global)
				else if (o.ctype.match(TCppGlobal)) {def: CppExtern(fieldName, true), t: CppTypeOf.cppTypeOf(expr.type)};
				else if (CppTypeText.isInternalMember(fieldName) || isRealArray(o)) {
					var cppType = CppTypeOf.cppReturnType(expr.type);
					if (o.ctype.match(TCppString)) {def: CppFunction(FuncInternal(o, fieldName, "."), cppType), t: cppType};
					else {def: CppFunction(FuncInternal(o, fieldName, "->"), cppType), t: cppType};
				}
				else if (o.ctype.match(TCppClass)) switch (o.expr) {
					case CppClassOf(path, _): {def: CppExtern(CppTypeText.joinClassPathRemap(path, "::") + "_obj::" + fieldName, true), t: CppTypeOf.cppTypeOf(expr.type)};
					case _: {def: CppVar(VarInternal(o, "->", fieldName)), t: CppTypeOf.cppTypeOf(expr.type)};
				}
				else {def: CppDynamicField(o, fieldName), t: TCppVariant};
			// FAnon / FClosure(None) (2654): a field on an anonymous structure (or a bare closure);
			// retype the receiver as Dynamic then route to a global extern, null access, internal
			// member call, or a dynamic-variant field.
			case TField(obj, FAnon(member)) | TField(obj, FClosure(null, member)):
				var o = retype(TCppDynamic, obj);
				var fieldName = member.name;
				if (o.ctype.match(TCppGlobal)) {def: CppExtern(fieldName, true), t: CppTypeOf.cppTypeOf(expr.type)};
				else if (o.ctype.match(TCppNull)) {def: CppNullAccess, t: TCppDynamic};
				else if (CppTypeText.isInternalMember(fieldName)) {
					var cppType = CppTypeOf.cppReturnType(expr.type);
					if (o.ctype.match(TCppString)) {def: CppFunction(FuncInternal(o, fieldName, "."), cppType), t: cppType};
					else {def: CppFunction(FuncInternal(o, fieldName, "->"), cppType), t: cppType};
				}
				else {def: CppDynamicField(o, fieldName), t: TCppVariant};
			case TField(_, fa):
				throw new hxc.core.TypingError("retype: TField arm not ported yet: " + fa.getName(), expr.pos);
			// TCall (2711): the generic callee dispatch (the array/map/native/template specials follow)
			// TCall __cpp__ (2701): raw C++ code injection. The first argument is the code string, the rest
			// are typed operands substituted into it.
			case TCall({expr: TIdent("__cpp__")}, args):
				var code = switch (args[0].expr) {
					case TConst(TString(s)): s;
					case _: throw new hxc.core.TypingError("__cpp__'s first argument must be a string", expr.pos);
				};
				var rest = [for (i in 1...args.length) retype(TCppCode(CppTypeOf.cppTypeOf(args[i].type)), args[i])];
				{def: CppCode(code, rest), t: TCppCode(CppTypeOf.cppTypeOf(expr.type))};
			case TCall(func, args):
				var retypedFunc = retype(TCppUnchanged, func);
				switch (retypedFunc.ctype) {
					case TCppNull: {def: CppNullAccess, t: TCppDynamic};
					case TCppFunction(argTypes, retType, _) | TCppObjCBlock(argTypes, retType):
						{def: CppCall(FuncExpression(retypedFunc), retypeFunctionArgs(args, argTypes, expr)), t: retType};
					case _:
						var cppType = CppTypeOf.cppTypeOf(expr.type);
						switch (retypedFunc.expr) {
							case CppFunction(funcLoc, functionReturnType): callFunction(funcLoc, functionReturnType, returnType, args, expr);
							case CppEnumIndex(_): {def: retypedFunc.expr, t: retypedFunc.ctype};
							case CppExtern(name, isGlobal):
								{def: CppCall(FuncExtern(name, isGlobal), [for (a in args) retype(TCppUnchanged, a)]), t: cppType};
							// A call on an enum constructor value builds that constructor directly.
							case CppEnumField(enm, ef):
								{def: CppCall(FuncEnumConstruct(enm, ef), [for (a in args) retype(TCppDynamic, a)]), t: cppType};
							// A call on `super` is a superclass constructor chain.
							case CppSuper(_):
								{def: CppCall(FuncSuperConstruct(retypedFunc.ctype), [for (a in args) retype(TCppDynamic, a)]), t: TCppVoid};
							case CppDynamicField(obj, name):
								var retypedArgs = [for (a in args) retype(TCppDynamic, a)];
								switch ([obj.ctype, name]) {
									case [TCppGlobal, _]: {def: CppCall(FuncExtern(name, true), [for (a in args) retype(TCppUnchanged, a)]), t: cppType};
									case [TCppString, _]: {def: CppCall(FuncInternal(obj, name, "."), retypedArgs), t: cppType};
									case [_, "__Tag"]: {def: CppCall(FuncInternal(obj, "_hx_getTag", "->"), retypedArgs), t: cppType};
									case [_, _] if (CppTypeText.isInternalMember(name)): {def: CppCall(FuncInternal(obj, name, "->"), retypedArgs), t: cppType};
									case _: {def: CppCall(FuncExpression(retypedFunc), retypedArgs), t: TCppDynamic};
								}
							case _:
								{def: CppCall(FuncExpression(retypedFunc), [for (a in args) retype(TCppDynamic, a)]), t: TCppDynamic};
						}
				}
			case _: throw new hxc.core.TypingError("retype: TExpr arm not ported yet: " + expr.expr.getName(), expr.pos);
		}
	}

	// Dispatch a retyped CppFunction callee to a CppCall.
	function callFunction(funcLoc:CppFuncLoc, functionReturnType:CppType, returnType:CppType, args:Array<TExpr>, expr:TExpr):{def:CppExprDef, t:CppType} {
		return switch (funcLoc) {
			// cpp.Function.fromStaticFunction(f): the single retyped arg must be a static
			// function; the call collapses to a CppFunctionAddress of that member.
			case FuncFromStaticFunction:
				var retypedArgs = [for (a in args) retype(TCppDynamic, a)];
				switch (retypedArgs) {
					case [{expr: CppFunction(FuncStatic(clazz, false, member), funcReturn)}]:
						{def: CppFunctionAddress(clazz, member), t: funcReturn};
					case _:
						throw new hxc.core.TypingError("cpp.Function.fromStaticFunction must be called on static function", expr.pos);
				}
				// A _hx_create_array_length static call is the array constructor: rewrite it to
				// a `new` of the concrete array type (Object/Scalar array from the return type, else a
				// dynamic
				// VirtualArray), so it emits ::Array_obj<T>::__new(len) instead of a bare (undeclared)
				// call.
			case FuncStatic(_, false, member) if (member.name == "_hx_create_array_length"):
				var retypedArgs = [for (a in args) retype(TCppDynamic, a)];
					// The array kind is keyed off the requested return type; the call's own cpp type
					// (::Array< int > here) is that type, so an Object/Scalar array uses
					// ::Array_obj<T>::__new.
				var callType = returnType;
				var arrType = switch (callType) { case TCppObjectArray(_) | TCppScalarArray(_): callType; case _: TCppDynamicArray; };
				{def: CppCall(FuncNew(arrType), retypedArgs), t: callType};
			// @:templatedCall takes its leading Class argument as a C++ template parameter.
			case FuncStatic(clazz, false, member) if (TypeFunctions.hasMeta(":templatedCall", member.meta)):
				var retypedArgs = [for (a in args) retype(TCppDynamic, a)];
				if (retypedArgs.length == 0) throw new hxc.core.TypingError("First parameter of template function must be a Class", expr.pos);
				switch (retypedArgs[0].expr) {
					case CppClassOf(path, native): {def: CppCall(FuncTemplate(clazz, member, path, native), retypedArgs.slice(1)), t: functionReturnType};
					case _: throw new hxc.core.TypingError("First parameter of template function must be a Class", expr.pos);
				}
			// Unused typed-array splice calls remove elements in place.
			case FuncInstance(obj, InstPtr, member) if (!forCppia && returnType.match(TCppVoid) && isArraySpliceCall(obj, member)):
				var retypedArgs = [for (a in args) retype(TCppDynamic, a)];
				var arrayMember = TypeFunctions.copyField(member);
				arrayMember.name = "removeRange";
				{def: CppCall(FuncInstance(obj, InstPtr, arrayMember), retypedArgs), t: TCppVoid};
			// Typed-array concat keeps its concrete element type for every argument.
			case FuncInstance(obj, InstPtr, member) if (isArrayConcatCall(obj, member)):
				{def: CppCall(FuncInstance(obj, InstPtr, member), [for (a in args) retype(obj.ctype, a)]), t: returnType};
			// Use typed getters for scalar and String values.
			case FuncInstance(obj, InstPtr, member) if (isMapGetCall(obj, member)):
				var retypedArgs = [for (a in args) retype(TCppDynamic, a)];
				var getter:{name:String, type:CppType} = switch (returnType) {
					case TCppVoid | TCppScalar("bool"): {name: forCppia ? "getBool" : "get_bool", type: returnType};
					case TCppScalar("int"): {name: forCppia ? "getInt" : "get_int", type: returnType};
					case TCppScalar("::cpp::Int64"): {name: forCppia ? "getInt64" : "get_int64", type: returnType};
					case TCppScalar("Float"): {name: forCppia ? "getFloat" : "get_float", type: returnType};
					case TCppString: {name: forCppia ? "getString" : "get_string", type: returnType};
					case _: {name: "get", type: TCppDynamic};
				};
				var mapMember = TypeFunctions.copyField(member);
				mapMember.name = getter.name;
				{def: CppCall(FuncInstance(obj, InstPtr, mapMember), retypedArgs), t: getter.type};
			// Maps use typed setters for scalar and String values.
			case FuncInstance(obj, InstPtr, member) if (forCppia && isMapSetCall(obj, member)):
				var retypedArgs = [for (a in args) retype(TCppDynamic, a)];
				var fname = switch (retypedArgs) {
					case [_, {ctype: TCppScalar("bool")}]: "setBool";
					case [_, {ctype: TCppScalar("int")}]: "setInt";
					case [_, {ctype: TCppScalar("::cpp::Int64")}]: "setInt64";
					case [_, {ctype: TCppScalar("Float")}]: "setFloat";
					case [_, {ctype: TCppString}]: "setString";
					case _: "set";
				}
				var mapMember = TypeFunctions.copyField(member);
				mapMember.name = fname;
				{def: CppCall(FuncInstance(obj, InstPtr, mapMember), retypedArgs), t: CppTypeOf.cppTypeOf(expr.type)};
			// The &/* pointer intrinsics: cpp.Native.addressOf/star/star's native names
				// (::hx::AddressOf/StarOf/Dereference) lower to CppAddressOf/CppDereference, not a call to a
				// nonexistent hxcpp function.
				case FuncStatic(_, false, member) if (hxc.ast.Ast.getMetaString(member.meta, ":native") == "::hx::AddressOf"):
					var arg = retype(TCppUnchanged, args[0]);
					var rawType = switch (arg.ctype) { case TCppReference(x): x; case x: x; };
					{def: CppAddressOf(arg), t: TCppRawPointer("", rawType)};
				case FuncStatic(_, false, member) if (hxc.ast.Ast.getMetaString(member.meta, ":native") == "::hx::StarOf"):
					var arg = retype(TCppUnchanged, args[0]);
					var rawType = switch (arg.ctype) { case TCppReference(x): x; case x: x; };
					{def: CppAddressOf(arg), t: TCppStar(rawType, false)};
			case FuncStatic(_, false, member) if (hxc.ast.Ast.getMetaString(member.meta, ":native") == "::hx::Dereference"):
				var arg = retype(TCppUnchanged, args[0]);
				var rawType = switch (arg.ctype) { case TCppStar(x, _): x; case x: x; };
				{def: CppDereference(arg), t: TCppReference(rawType)};
			case FuncInstance(_, InstPtr, _) if (CppTypeText.cppCanStaticCast(functionReturnType, CppTypeOf.cppTypeOf(expr.type))):
				var retypedArgs = [for (a in args) retype(TCppDynamic, a)];
				var cppType = CppTypeOf.cppTypeOf(expr.type);
				var call = mk(CppCall(funcLoc, retypedArgs), functionReturnType, expr.pos);
				{def: CppCastStatic(call, cppType), t: cppType};
			case FuncInstance(_, InstStruct, cf) if (isTFun(cf.type)):
				{def: CppCall(funcLoc, retypeFunctionArgs(args, structTfunArgCppTypes(cf.type, args), expr)), t: returnType};
			case FuncInstance(_, _, cf) | FuncStatic(_, _, cf) | FuncThis(cf, _) if (isTFun(cf.type)):
				{def: CppCall(funcLoc, retypeFunctionArgs(args, tfunArgCppTypes(cf.type), expr)), t: functionReturnType};
			case _:
				{def: CppCall(funcLoc, [for (a in args) retype(TCppDynamic, a)]), t: functionReturnType};
		}
	}

	static function isMapGetCall(obj:CppExpr, member:TClassField):Bool {
		if (member.name != "get") return false;
		return switch (obj.ctype) {
			case TCppInst(c, _): switch [c.path.pack, c.path.name] {
				case [["cpp"], "Int64Map"] | [["haxe", "ds"], "IntMap"] | [["haxe", "ds"], "StringMap"] | [["haxe", "ds"], "ObjectMap"]: true;
				case _: false;
			};
			case _: false;
		}
	}

	static function isMapSetCall(obj:CppExpr, member:TClassField):Bool {
		if (member.name != "set") return false;
		return switch (obj.ctype) {
			case TCppInst(c, _): switch [c.path.pack, c.path.name] {
				case [["cpp"], "Int64Map"] | [["haxe", "ds"], "IntMap"] | [["haxe", "ds"], "StringMap"] | [["haxe", "ds"], "ObjectMap"]: true;
				case _: false;
			};
			case _: false;
		}
	}

	static function isArraySpliceCall(obj:CppExpr, member:TClassField):Bool {
		return member.name == "splice" && switch (obj.ctype) {
			case TCppScalarArray(_) | TCppObjectArray(_): true;
			case _: false;
		}
	}

	static function isArrayConcatCall(obj:CppExpr, member:TClassField):Bool {
		return member.name == "concat" && switch (obj.ctype) {
			case TCppScalarArray(_) | TCppObjectArray(_): true;
			case _: false;
		}
	}

	// FInstance/FClosure(Some): an instance field or method access. The receiver is
	// retyped at the instance type; the result depends on struct-access, var-vs-method, interface,
	// objc, and the array-method return-type fixups.
	function fieldInstance(obj:TExpr, clazz:TClass, params:Array<T>, member:TClassField, expr:TExpr):{def:CppExprDef, t:CppType} {
		var funcReturn = CppTypeOf.cppMemberReturnType(member);
		var owner = clazz;
		var ownerParams = params;
		switch (TypeFunctions.follow(obj.type)) {
			case TInst(c, _): switch (c.kind) {
				case KGenericInstance(base, _) if (base == clazz):
					owner = c;
					ownerParams = [];
				case _:
			}
			case _:
		}
		var clazzType = CppTypeOf.cppInstanceTypeOf(owner, ownerParams);
		var retypedObj = retype(clazzType, obj);
		var exprType = CppTypeOf.cppTypeOf(member.type);
		var isObjc = CppTypeOf.isCppObjcType(retypedObj.ctype);
		if (retypedObj.ctype.match(TCppNull)) return {def: CppNullAccess, t: TCppDynamic};
		if (retypedObj.ctype.match(TCppDynamic) && !TypeFunctions.hasClassFlag(owner, CInterface)) {
			if (CppTypeText.isInternalMember(member.name)) return {def: CppFunction(FuncInstance(retypedObj, InstPtr, member), funcReturn), t: exprType};
			return {def: CppDynamicField(retypedObj, member.name), t: TCppVariant};
		}
		// The receiver is an interface reference but the member resolved to a concrete class (a
		// multi-type Map field stored as its IMap interface, whose member re-resolves to the concrete
		// map when the inlined call site has concrete key/value types). The runtime object is some
		// implementation, not necessarily that class, so a direct member call is invalid; dispatch
		// dynamically on the interface reference.
		if (retypedObj.ctype.match(TCppInterface(_)) && !TypeFunctions.hasClassFlag(owner, CInterface))
			return {def: CppDynamicField(retypedObj, member.name), t: TCppVariant};
		if (CppTypeOf.cppIsStructAccess(retypedObj.ctype)) return switch (retypedObj.expr) {
			case CppThis(ThisReal): {def: CppVar(VarThis(member, retypedObj.ctype)), t: exprType};
			case CppSuper(thiz): {def: CppFunction(FuncSuper(thiz, retypedObj.ctype, member), funcReturn), t: exprType};
			case _:
				if (CppTypeOf.isVarField(member)) {def: CppVar(VarInstance(retypedObj, member, CppTypeText.tcppToString(clazzType), ".")), t: exprType};
				else {def: CppFunction(FuncInstance(retypedObj, InstStruct, member), funcReturn), t: exprType};
		};
		if (CppTypeOf.isVarField(member)) {
			var vType = switch [retypedObj.ctype, exprType] {
				case [TCppPointer(_, t), TCppDynamic] | [TCppRawPointer(_, t), TCppDynamic]: t;
				case _: exprType;
			};
			return switch (retypedObj.expr) {
				case CppThis(ThisReal): {def: CppVar(VarThis(member, retypedObj.ctype)), t: vType};
				case _: switch [retypedObj.ctype, member.name] {
					case [TCppDynamicArray, "length"] if (!forCppia): {def: CppCall(FuncInternal(retypedObj, "get_length", "->"), []), t: vType};
					case [TCppInterface(_), _] | [TCppDynamic, _]: {def: CppDynamicField(retypedObj, member.name), t: TCppVariant};
					case [TCppObjC(_), _]: {def: CppVar(VarInstance(retypedObj, member, CppTypeText.tcppToString(clazzType), ".")), t: vType};
					case _:
						var op = (CppTypeOf.cppIsStructAccess(retypedObj.ctype) || retypedObj.ctype.match(TCppString)) ? "." : "->";
						{def: CppVar(VarInstance(retypedObj, member, CppTypeText.tcppToString(clazzType), op)), t: vType};
				}
			};
		}
		if (TypeFunctions.hasClassFlag(owner, CInterface) && !isObjc) return {def: CppFunction(FuncInterface(retypedObj, owner, member), funcReturn), t: exprType};
		var isArrayObj = switch (retypedObj.ctype) { case TCppDynamicArray | TCppObjectArray(_) | TCppScalarArray(_): true; case _: false; };
		var mReturn = if (isArrayObj) switch (member.name) {
			case "map": TCppDynamicArray;
			case "splice" | "slice" | "concat" | "copy" | "filter": retypedObj.ctype;
			case _: funcReturn;
		} else switch [retypedObj.ctype, funcReturn] {
			case [TCppPointer(_, t), TCppDynamic] | [TCppRawPointer(_, t), TCppDynamic]: t;
			case _: funcReturn;
		};
		return switch (retypedObj.expr) {
			case CppThis(ThisReal): {def: CppFunction(FuncThis(member, retypedObj.ctype), mReturn), t: exprType};
			case CppSuper(thiz): {def: CppFunction(FuncSuper(thiz, retypedObj.ctype, member), mReturn), t: exprType};
			case _: {def: CppFunction(FuncInstance(retypedObj, isObjc ? InstObjC : InstPtr, member), mReturn), t: exprType};
		};
	}

	// Zip args with their declared cpp types (TCppRest = varargs)
	function retypeFunctionArgs(args:Array<TExpr>, argTypes:Array<CppType>, expr:TExpr):Array<CppExpr> {
		var result:Array<CppExpr> = [];
		var ai = 0, ti = 0;
		while (true) {
			if (argTypes.length - ti == 1) switch (argTypes[ti]) {
				case TCppRest(rest):
					while (ai < args.length) { result.push(retype(rest, args[ai])); ai++; }
					return result;
				case _:
			}
			if (ai >= args.length && ti >= argTypes.length) return result;
			else if (ai < args.length && ti < argTypes.length) { result.push(retype(argTypes[ti], args[ai])); ai++; ti++; }
			else if (ti >= argTypes.length) throw new hxc.core.TypingError("Too many args", expr.pos);
			else throw new hxc.core.TypingError("Too many types", expr.pos);
		}
	}

	static inline function isComplexCompare(t:CppType):Bool {
		return switch (t) { case TCppScalar(_) | TCppString: false; case _: true; };
	}

	static inline function isPointerCompare(t:CppType):Bool {
		return switch (t) { case TCppObjectArray(_) | TCppScalarArray(_) | TCppDynamicArray | TCppClass | TCppEnum(_): true; case _: false; };
	}

	static inline function isInstanceCompare(t:CppType):Bool {
		return switch (t) { case TCppInterface(_) | TCppInst(_, _): true; case _: false; };
	}

	function isObjectElement(memberType:CppType):Bool {
		return switch (memberType) {
			case TCppInst(x, _) | TCppInterface(x): !CppTypeOf.isExternClass(x);
			case TCppDynamic | TCppObject | TCppObjectPtr | TCppEnum(_) | TCppString | TCppFunction(_, _, _)
				| TCppDynamicArray | TCppObjectArray(_) | TCppWrapped(_) | TCppScalarArray(_) | TCppClass: true;
			case _: false;
		}
	}

	// Only under generational GC.
	inline function isGcElement(memberType:CppType):Bool {
		return com.defines.rawDefined("HXCPP_GC_GENERATIONAL") && isObjectElement(memberType);
	}

	// Turn a retyped value into an assignable lvalue, flagging GC targets
	function toLvalue(value:CppExpr):{lvalue:CppLValue, gc:Bool} {
		return switch (value.expr) {
			case CppVar(loc): switch (loc) {
				case VarClosure(v) if (isGcElement(CppTypeOf.cppTypeOf(v.type))): {lvalue: CppVarRef(loc), gc: true};
				case VarThis(member, _) if (isGcElement(CppTypeOf.cppTypeOf(member.type))): {lvalue: CppVarRef(loc), gc: true};
				case VarInstance(_, member, _, "->") if (isGcElement(CppTypeOf.cppTypeOf(member.type))): {lvalue: CppVarRef(loc), gc: true};
				case _: {lvalue: CppVarRef(loc), gc: false};
			}
			case CppArray(arrayloc):
				var gc = switch (arrayloc) {
					case ArrayObject(_, _, _) if (isGcElement(TCppDynamic)): true;
					case ArrayTyped(_, _, t) if (isGcElement(t)): true;
					case _: false;
				};
				{lvalue: CppArrayRef(arrayloc), gc: gc};
			case CppDynamicField(e, name): {lvalue: CppDynamicRef(e, name), gc: false};
			case CppTCast(e, _) | CppCast(e, _) | CppCastStatic(e, _) | CppCastObjC(e, _) | CppCastScalar(e, _) | CppCastVariant(e): toLvalue(e);
			case CppCastObjCBlock(e, _, _): toLvalue(e);
			case CppExtern(name, isGlobal): {lvalue: CppExternRef(name, isGlobal), gc: false};
			case _: throw new hxc.core.TypingError("Could not convert expression to l-value", value.pos);
		}
	}

	static inline function isTFun(t:T):Bool {
		return switch (t) { case TFun(_): true; case _: false; };
	}

	// The declared constructor, walking the super chain for an inherited one
	static function getConstructor(c:TClass):Null<TClassField> {
		if (c.constructor != null) return c.constructor;
		return c.superClass != null ? getConstructor(c.superClass.c) : null;
	}

	// With an overloaded constructor,
	// pick the overload whose parameter types unify with the actual arguments. A non-overloaded
	// constructor is returned unchanged (the common case). Only the selected signature's argument
	// types matter here, since a cpp `new` emits `Class_obj::__new(args)` with no named constructor.
	public static function selectConstructor(c:TClass, tl:Array<T>, args:Array<TExpr>):Null<TClassField> {
		var cf = getConstructor(c);
		if (cf == null) return null;
		if (cf.overloads.length == 0 && !TypeFunctions.hasClassFieldFlag(cf, CfOverload)) return cf;
		var countMatch:Null<TClassField> = null;
		for (cand in [cf].concat(cf.overloads)) {
			var ct = tl.length > 0 ? TypeFunctions.applyParams(c.params, tl, cand.type) : cand.type;
			switch (TypeFunctions.follow(ct)) {
				case TFun(sig):
					var required = 0;
					for (a in sig.args) if (!a.opt) required++;
					if (args.length < required || args.length > sig.args.length) continue;
					if (countMatch == null) countMatch = cand;
					var ok = true;
					for (i in 0...args.length)
						if (!ctorArgUnifies(args[i].type, sig.args[i].t)) { ok = false; break; }
					if (ok) return cand;
				case _:
			}
		}
		return countMatch != null ? countMatch : cf;
	}

	static function ctorArgUnifies(a:T, b:T):Bool {
		return try hxc.core.TypeUnification.withMonoRollback(function() {
			hxc.core.TypeUnification.unifyDefault(a, b);
			return true;
		}) catch (_:hxc.core.TypeUnification.UnifyError) false;
	}

	// The {fileName,lineNumber,className,methodName} pos-info object -> CppPosition
	static function matchPosInfo(fields:Array<TObjectField>):Null<CppExprDef> {
		if (fields.length != 4) return null;
		if (fields[0].key.name != "fileName" || fields[1].key.name != "lineNumber"
			|| fields[2].key.name != "className" || fields[3].key.name != "methodName") return null;
		return switch [fields[0].expr.expr, fields[1].expr.expr, fields[2].expr.expr, fields[3].expr.expr] {
			case [TConst(TString(file)), TConst(TInt(line)), TConst(TString(className)), TConst(TString(meth))]:
				CppPosition(file, line, className, meth);
			case _: null;
		}
	}

	static inline function isRealArray(o:CppExpr):Bool {
		return switch (o.ctype) { case TCppScalarArray(_) | TCppObjectArray(_): true; case _: false; };
	}

	// The int value of a constant case pattern.
	// Only called on values that passed isConstInt; returns a non-nullable Int32 so a value of 0 survives.
	static function constIntOf(e:TExpr):haxe.Int32 {
		return switch (e.expr) {
			case TConst(TInt(x)): x;
			case TConst(TBool(b)): (b ? 1 : 0);
			case TParenthesis(inner): constIntOf(inner);
			case _: 0;
		}
	}

	// Int-switch eligibility. Test the expression shape directly rather
	// than constIntOf(v) == null: constIntOf returns Null<Int32>, and on the host runtime a value of 0 is
	// indistinguishable from null, which would wrongly reject a `case 0`.
	static function allIntCases(cases:Array<TSwitchCase>):Bool {
		for (c in cases) for (v in c.values) if (!isConstInt(v)) return false;
		return true;
	}

	static function isConstInt(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(TInt(_)) | TConst(TBool(_)): true;
			case TParenthesis(inner): isConstInt(inner);
			case _: false;
		}
	}

	function cppAppendBlock(block:CppExpr, e:CppExpr):CppExpr {
		return switch (block.expr) {
			case CppBlock(items, closures, gc): {expr: CppBlock(items.concat([e]), closures, gc), ctype: block.ctype, pos: block.pos};
			case _: throw new hxc.core.TypingError("Internal error appending expression", block.pos);
		}
	}

	static function tfunArgCppTypes(t:T):Array<CppType> {
		return switch (t) {
			case TFun(sig): [for (a in sig.args) CppTypeOf.cppTfunArgTypeOf(a.opt, a.t)];
			case _: [];
		}
	}

	static function structTfunArgCppTypes(t:T, args:Array<TExpr>):Array<CppType> {
		return switch (t) {
			case TFun(sig): [for (i in 0...args.length) CppTypeOf.cppTfunArgTypeOf(sig.args[i].opt, args[i].type)];
			case _: [];
		}
	}

	// The autocast tail: coerce the retyped node to the requested C++ type.
	function autocast(returnType:CppType, cppExpr:CppExpr, retypedExpr:CppExprDef, pos:Position):CppExpr {
		if (returnType.match(TCppVoid)) return mk(retypedExpr, TCppVoid, pos);
		if (returnType.match(TCppVarArg)) {
			return switch (CppTypeOf.cppVariantTypeOf(cppExpr.ctype)) {
				case TCppVoidStar | TCppScalar(_): cppExpr;
				case TCppString: mk(CppVar(VarInternal(cppExpr, ".", "raw_ptr()")), TCppPointer("ConstPointer", TCppScalar("char")), pos);
				case TCppDynamic: mk(CppCastNative(cppExpr), TCppVoidStar, pos);
				case _:
					var toDynamic = mk(CppCast(cppExpr, TCppDynamic), TCppDynamic, pos);
					mk(CppCastNative(toDynamic), TCppVoidStar, pos);
			}
		}
		var ct = cppExpr.ctype;
		if (isDynamicish(ct)) {
			return switch (returnType) {
				case TCppUnchanged: cppExpr;
				case TCppInst(t, _) if (TypeFunctions.hasMeta(":structAccess", t.meta)):
					var structType = TCppStruct(TCppInst(t, []));
					var structCast = mk(CppCast(cppExpr, structType), structType, pos);
					mk(CppCast(structCast, TCppInst(t, [])), TCppInst(t, []), pos);
				case TCppObjectArray(_) | TCppScalarArray(_) | TCppNativePointer(_) | TCppDynamicArray
					| TCppObjectPtr | TCppVarArg | TCppInst(_, _): mk(CppCast(cppExpr, returnType), returnType, pos);
				case TCppObjC(k): mk(CppCastObjC(cppExpr, k), returnType, pos);
				case TCppObjCBlock(a, r): mk(CppCastObjCBlock(cppExpr, a, r), returnType, pos);
				case TCppScalar(scalar): mk(CppCastScalar(cppExpr, scalar), returnType, pos);
				case TCppString: mk(CppCastScalar(cppExpr, "::String"), returnType, pos);
				case TCppInterface(_) if (ct.match(TCppVariant)): mk(CppCastVariant(cppExpr), returnType, pos);
				case TCppDynamic if (ct.match(TCppVariant)): mk(CppCastVariant(cppExpr), returnType, pos);
				case TCppStar(t, isConst):
					var ptrType = TCppPointer(isConst ? "ConstPointer" : "Pointer", t);
					var ptrCast = mk(CppCast(cppExpr, ptrType), ptrType, pos);
					mk(CppCast(ptrCast, TCppStar(t, isConst)), TCppStar(t, isConst), pos);
				case _: cppExpr;
			}
		}
		return switch [ct, returnType] {
			case [_, TCppUnchanged]: cppExpr;
			case [TCppAutoCast, _] | [TCppObjC(_), TCppDynamic] | [TCppObjCBlock(_, _), TCppDynamic]:
				mk(CppCast(cppExpr, returnType), returnType, pos);
			case [TCppReference(TCppDynamic), TCppReference(_)]: cppExpr;
			case [TCppReference(TCppDynamic), t]: mk(retypedExpr, TCppReference(t), pos);
			case [TCppStar(TCppDynamic, _), TCppStar(_, _)]: cppExpr;
			case [TCppStar(TCppDynamic, isConst), t]: mk(retypedExpr, TCppStar(t, isConst), pos);
			case [TCppStar(t, isConst), TCppDynamic]:
				var ptrType = TCppPointer(isConst ? "ConstPointer" : "Pointer", t);
				var ptrCast = mk(CppCast(cppExpr, ptrType), ptrType, pos);
				mk(CppCast(ptrCast, TCppDynamic), TCppDynamic, pos);
			case [TCppStar(_, _), TCppReference(_)] | [TCppStar(_, _), TCppInst(_, _)] | [TCppStar(_, _), TCppStruct(_)]:
				mk(CppDereference(cppExpr), returnType, pos);
			case [TCppInst(t, _), TCppStar(_, _)] if (CppTypeOf.isNativeClass(t) && isNewNative(cppExpr.expr)):
				mk(CppNewNative(cppExpr), returnType, pos);
			case [TCppInst(_, _), TCppStar(_, _)] | [TCppStruct(_), TCppStar(_, _)]:
				mk(CppAddressOf(cppExpr), returnType, pos);
			case [TCppObjectPtr, TCppObjectPtr]: cppExpr;
			case [TCppObjectPtr, _]: mk(CppCast(cppExpr, TCppDynamic), TCppDynamic, pos);
			case [TCppProtocol(_), TCppProtocol(_)]: cppExpr;
			case [_, TCppProtocol(protocol)]: mk(CppCastProtocol(cppExpr, protocol), returnType, pos);
			case [TCppInst(t, _), TCppDynamic] if (TypeFunctions.hasMeta(":structAccess", t.meta)):
				var structType = TCppStruct(TCppInst(t, []));
				var structCast = mk(CppCast(cppExpr, structType), structType, pos);
				mk(CppCast(structCast, TCppDynamic), TCppDynamic, pos);
			case [_, TCppObjectPtr]: mk(CppCast(cppExpr, TCppObjectPtr), TCppObjectPtr, pos);
			case [TCppDynamicArray, TCppScalarArray(_)] | [TCppDynamicArray, TCppObjectArray(_)]
				| [TCppScalarArray(_), TCppDynamicArray] | [TCppObjectArray(_), TCppDynamicArray] if (forCppia):
				mk(CppCast(cppExpr, returnType), returnType, pos);
			case [TCppScalar(from), TCppScalar(too)] if (from != too): mk(CppCastScalar(cppExpr, too), returnType, pos);
			case [_, _]: cppExpr;
		}
	}

	static inline function isDynamicish(t:CppType):Bool {
		return switch (t) { case TCppVariant | TCppDynamic | TCppObject: true; case _: false; }
	}

	static inline function isNewNative(def:CppExprDef):Bool {
		return switch (def) { case CppCall(FuncNew(_), _): true; case _: false; }
	}
}
