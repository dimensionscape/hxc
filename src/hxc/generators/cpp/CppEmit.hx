package hxc.generators.cpp;

import hxc.core.Type;
import hxc.context.Context;
import hxc.generators.cpp.CppType;
import hxc.generators.cpp.CppExpr;

// hxc.generators.cpp.CppEmit: emit C++ text from the retyped cpp IR, (gen_cpp_ast_expression_tree /
// gen_with_injection). The retype pass (CppRetype) produced the CppExpr; this walks it and writes C++ to a
// CppWriter. Ported in tranches: the core statement/expression nodes land first; the native-interop and
// script nodes follow. Unported nodes throw loudly.
class CppEmit {
	final com:Context;
	final writer:CppWriter;
	final debugLevel:Int;
	final smartStrings:Bool;
	final realThisPtr:Bool;
	var lastLine:Int = -1;
	var tempId:Int = 0;
	var rootPos:hxc.ast.Position;
	// The enclosing class dot-path and function name, used for a local closure's stack frame.
	var emitClassName:String = "";
	var emitFuncName:String = "";
	// The injection prologue (emitted at the top block's start; consumed once)
	var topPrologue:Null<Bool->Void> = null;

	// The per-file unique-id counter (goto labels, const-array names). Shared across every method body
	// emitted into one .cpp/.h and threaded by the caller (CppGenClass); a null default keeps a fresh
	// per-body counter for standalone use.
	var fileId:{v:Int};

	// True when this body is emitted into a header (an inline __new/__alloc), so a nested closure's stack
	// frame only declares (not defines) its StackPosition; the cpp copy of the body defines it.
	public var forHeader:Bool = false;

	public function new(com:Context, writer:CppWriter, debugLevel:Int, realThisPtr:Bool, ?fileId:{v:Int}, forHeader:Bool = false) {
		this.com = com;
		this.writer = writer;
		this.debugLevel = debugLevel;
		this.realThisPtr = realThisPtr;
		this.smartStrings = com.defines.rawDefined("hxcpp_smart_strings");
		this.fileId = fileId != null ? fileId : {v: 0};
		this.forHeader = forHeader;
	}

	inline function out(s:String):Void writer.write(s);

	inline function spacer():String return debugLevel > 0 ? "            \t" : "";

	// genExpressionTree retypes the body and emits it, with an optional prologue (the stack-frame /
	// default-values injection) emitted at the top block's start.
	// The setvar: a literal prefix (e.g. `origin = ` or `_hx_result = `) emitted just before the last
	// statement of the top block
	var topSetvar:String = "";

	public function genExpressionTree(functionArgs:Array<TVar>, functionType:T, bodyExpr:TExpr, ?prologue:Bool->Void, ?setvar:String, ?className:String, ?funcName:String):Void {
		rootPos = bodyExpr.pos;
		emitClassName = className == null ? "" : className;
		emitFuncName = funcName == null ? "" : funcName;
		// /4372: the body is always wrapped in a block (idempotent for method bodies that are already
		// blocks; wraps a bare entry call like com.main so it emits `{ call; }`)
		var cppTree = CppRetype.retypeExpression(com, realThisPtr, fileId, TCppVoid, functionArgs, functionType, hxc.core.TypeFunctions.mkBlock(bodyExpr), false);
		lastLine = -1;
		topPrologue = prologue;
		topSetvar = setvar == null ? "" : setvar;
		genWithInjection(cppTree, true);
	}

	// A super() constructor call becomes a C++ base initializer list `:Super(args)` emitted between the
	// constructor signature and its body; each argument is retyped as a Dynamic value.
	public function genConstructorSuperInit(superPath:String, args:Array<TExpr>, functionArgs:Array<TVar>):Void {
		out("\n:" + superPath + "(");
		var sep = "";
		for (arg in args) {
			out(sep); sep = ",";
			gen(CppRetype.retypeExpression(com, realThisPtr, fileId, TCppDynamic, functionArgs, com.basic.tvoid, arg, false));
		}
		out(")\n");
	}

	// Prefix a statement with its HXLINE/HXDLIN debug marker
	function outputP(expr:CppExpr):Void {
		if (debugLevel > 0) {
			var line = lineOf(expr.pos);
			var lineName = StringTools.lpad(Std.string(line), " ", 4);
			out((line != lastLine ? "HXLINE" : "HXDLIN") + "(" + lineName + ")\t");
			lastLine = line;
		}
		writer.writeI("");
	}

	// Map a position to its 1-based source line. hxc's Position keeps a per-file lineStarts index (built
	// from the file content, cached) and binary-searches min -> line.
	// An unknown/synthetic position resolves to line 1; Position.lineNumber yields 0 there, so clamp to 1.
	inline function lineOf(pos:hxc.ast.Position):Int {
		return CppEmit.getErrorLine(pos);
	}

	public static inline function getErrorLine(pos:hxc.ast.Position):Int {
		var l = hxc.ast.Position.lineNumber(pos);
		return l <= 0 ? 1 : l;
	}

	inline function gen(expr:CppExpr):Void {
		genWithInjection(expr, true);
	}

	// The body with its injection (omitted for the no-injection body form)
	function genWithInjection(expr:CppExpr, newLine:Bool):Void {
		switch (expr.expr) {
			case CppBlock(exprs, closures, gc):
				writer.beginBlock();
				// Local closures are defined at the block start
				for (c in closures) genClosure(c);
				// The injection prologue (stack frame etc.) is emitted once, for the top block
				if (topPrologue != null) { var p = topPrologue; topPrologue = null; p(gc); }
				lastLine = lineOf(rootPos);
				var remaining = exprs.length;
				for (e in exprs) {
					outputP(e);
					// The setvar prefix is emitted before the block's last statement
					if (remaining == 1 && topSetvar != "") { out(topSetvar); topSetvar = ""; }
					gen(e);
					writer.terminateLine();
					remaining--;
				}
				out(spacer());
				if (newLine) writer.endBlock() else writer.endBlockLine();
			case CppInt(i):
				out((i > -1000000000 && i < 1000000000) ? Std.string(i) : "(int)" + Std.string(i));
			case CppFloat(f): out("((Float)" + f + ")");
			case CppString(s): out(CppTypeText.strq(smartStrings, s));
			case CppBool(b): out(b ? "true" : "false");
			case CppNull: out("null()");
			case CppNil: out("nil");
			case CppThis(ThisReal): out("::hx::ObjectPtr<OBJ_>(this)");
			case CppThis(_): out("__this");
			case CppSuper(thiscall): out("::hx::ObjectPtr<super>(" + (thiscall.match(ThisReal) ? "this" : "__this.mPtr") + ")");
			case CppBreak: out("break");
			case CppContinue: out("continue");
			case CppGoto(label): out("goto " + labelName(label));
			case CppReturn(null): out("return");
			case CppReturn(value): out("return "); gen(value);
			case CppThrow(value): out("HX_STACK_DO_THROW("); gen(value); out(")");
			case CppNullAccess: out("::hx::Throw(" + CppTypeText.strq(smartStrings, "Null access") + ")");
			case CppVar(loc): genVarLoc(loc);
			case CppVarDecl(v, init):
				out(CppTypeText.tcppToString(CppTypeOf.cppTypeOf(v.type)) + " " + CppTypeText.cppVarNameOf(v));
				switch (init) { case null: case i: out(" = "); gen(i); }
			// An assignment used as a value (non-void cpptype, e.g. nested inside `a + (b = c)`) is wrapped
			// in parentheses so C++ precedence keeps the assignment together; a statement is not.
			case CppSet(lvalue, value):
				var close = expr.ctype.match(TCppVoid) ? "" : { out("("); ")"; };
				genLValue(lvalue); out(" = "); gen(value);
				out(close);
			// CppBinop: UShr/Mod/Div-by-zero call runtime helpers, else (left op right)
			case CppBinop(OpUShr, l, r): out("::hx::UShr("); gen(l); out(","); gen(r); out(")");
			case CppBinop(OpMod, l, r):
				out("::hx::Mod("); gen(l); out(isConstantZero(r) ? ",(double)( " : ","); gen(r); out(isConstantZero(r) ? " ))" : ")");
			case CppBinop(OpDiv, l, r) if (isConstantZero(r)): out("::hx::DivByZero("); gen(l); out(")");
			case CppBinop(op, l, r):
				out("("); gen(l); out(" " + stringOfOp(op) + " "); gen(r); out(")");
			case CppCompare(opName, l, r, _): out("::hx::" + opName + "( "); gen(l); out(","); gen(r); out(" )");
			case CppNullCompare(op, l): out("::hx::" + op + "( "); gen(l); out(" )");
			case CppUnop(unop, value):
				out(switch (unop) { case CppNot: "!"; case CppNeg: "-"; case CppNegBits: "~"; });
				out("("); gen(value); out(")");
			// CppIf: statement (if/else) or value (ternary) form
			case CppIf(cond, block, null): out("if ("); gen(cond); out(") "); gen(block);
			case CppIf(cond, block, elze) if (expr.ctype.match(TCppVoid)):
				out("if ("); gen(cond); out(") "); gen(block); outI("else "); gen(elze);
			case CppIf(cond, block, elze): gen(cond); out(" ? "); gen(block); out(" : "); gen(elze);
			case CppClassOf(path, native):
				var p = "::" + CppTypeText.joinClassPathRemap(path, "::");
				p = switch (p) { case "::Int": "int"; case "::Bool": "bool"; case x: x; };
				if (native) out("null()");
				else if (p == "::Array") out("::hx::ArrayBase::__mClass");
				else out("::hx::ClassOf< " + p + " >()");
			case CppDynamicField(obj, name):
				gen(obj); out("->__Field(" + CppTypeText.strq(smartStrings, name) + ",::hx::paccDynamic)");
			case CppEnumIndex(obj):
				gen(obj);
				// A Dynamic-typed enum value must be cast to EnumBase before _hx_getIndex
				if (CppTypeOf.cppIsDynamicType(obj.ctype)) out(".StaticCast< ::hx::EnumBase >()");
				out("->_hx_getIndex()");
			case CppCall(func, args): genCall(func, args, expr);
			// Raw C++ from __cpp__, with {N} interpolated to argument N.
			case CppCode(code, exprs): emitCppCode(code, exprs);
			case CppFunction(func, _): genFunctionValue(func, expr);
			// Scalar/variant casts; CppCast/CppCastStatic pass through for now (their per-target wrapper
			// emission is refined in a later tranche)
			case CppCastScalar(e, scalar): out("( (" + scalar + ")("); gen(e); out(") )");
			case CppCastVariant(e): out(" ::Dynamic("); gen(e); out(")");
			// CppCast: `( (toType)(expr) )` in the general case, with a few special forms
			case CppCast(e, toType):
				switch [e.expr, e.ctype, toType] {
					case [CppCall(FuncInternal(_, _, _), _), _, _]:
						gen(e); out(".StaticCast< " + CppTypeText.tcppToString(toType) + " >()");
					case [_, TCppObjC(_), _] | [_, TCppObjCBlock(_, _), _]:
						out("( (" + CppTypeText.tcppToString(toType) + ")((id) ( "); gen(e); out(") ))");
					case [_, _, TCppObjectPtr]:
						out("::hx::DynamicPtr("); gen(e); out(")");
					case [_, TCppPointer(_, _), TCppStar(_, _)] | [_, TCppPointer(_, _), TCppRawPointer(_, _)]:
						out("( (" + CppTypeText.tcppToString(toType) + ")( ("); gen(e); out(").get_raw()) )");
					case _:
						out("( (" + CppTypeText.tcppToString(toType) + ")("); gen(e); out(") )");
				}
			case CppCastStatic(e, _): gen(e);
			// CppNewNative: a raw C++ `new` of a native/extern type.
			case CppNewNative(e): out("new "); gen(e);
			// CppAddressOf/CppDereference: the &/* pointer operators.
			case CppAddressOf(e): out("&("); gen(e); out(")");
			case CppDereference(e): out("(*("); gen(e); out("))");
			// CppFunctionAddress: a ::cpp::Function wrapping the &Class_obj::member pointer.
			case CppFunctionAddress(klass, member):
				var signature = ctxFunctionSignature(false, member.type, "");
				out("::cpp::Function< " + signature + ">(::hx::AnyCast(");
				out("&::" + CppTypeText.joinClassPathRemap(klass.path, "::") + "_obj::" + CppTypeText.cppMemberNameOf(member));
				out(" ))");
			// CppExtern: a bare extern name, prefixed with `::` when global.
			case CppExtern(name, isGlobal): if (isGlobal) out(" ::"); out(name);
			// CppTCast: an interface cast is a runtime ::hx::interface_check; any other cast goes through
			// ::hx::TCast<T>::cast (the "Dynamic" fast path never fires because the type text is prefixed
			// with " ::").
			case CppTCast(e, cppType):
				switch (cppType) {
					case TCppInterface(i):
						out(" ::hx::interface_check("); gen(e); out("," + cppClassHash(i) + ")");
					case _:
						var toType = CppTypeText.tcppToString(cppType);
						if (toType == "Dynamic") {
							out(" ::Dynamic("); gen(e); out(")");
						} else {
							out("::hx::TCast< " + toType + " >::cast("); gen(e); out(")");
						}
				}
			// CppArrayDecl const-scalar-array optimization: an all-literal scalar array is emitted as a
			// `static const T _hx_array_data_<classhash>_<id>[]` table at the file top plus
			// `::Array_obj<T>::fromData(id,count)` in the body; it bumps the shared file-id counter.
			case CppArrayDecl(exprList) if (isConstScalarArray(expr.ctype, exprList)):
				var valueType = switch (expr.ctype) { case TCppScalarArray(v): v; case _: TCppVoid; };
				var typeName = CppTypeText.tcppToString(valueType);
				fileId.v++;
				var classHash = StringTools.lpad(StringTools.hex(CppTypeText.genHash32(0, emitClassName), 8).toLowerCase(), "0", 8);
				var id = "_hx_array_data_" + classHash + "_" + fileId.v;
				writer.writeH("static const " + typeName + " " + id + "[] = {\n\t");
				for (e in exprList) writer.writeH(switch (e.expr) {
					case CppInt(i): "(" + typeName + ")" + i + ",";
					case CppFloat(f): f + ",";
					case CppString(s): CppTypeText.strq(smartStrings, s) + ",";
					case CppBool(b): b ? "1," : "0,";
					case _: "";
				});
				writer.writeH("\n};\n");
				out("::Array_obj< " + typeName + " >::fromData( " + id + "," + exprList.length + ")");
			case CppArrayDecl(exprList):
				var arrayType = ""; var close = "";
				switch (expr.ctype) {
					case TCppObjectArray(_): arrayType = "::Array_obj< ::Dynamic>";
					case TCppScalarArray(value): arrayType = "::Array_obj< " + CppTypeText.tcppToString(value) + " >";
					case TCppDynamicArray: arrayType = "::cpp::VirtualArray_obj";
					case _: arrayType = " ::Dynamic( ::cpp::VirtualArray_obj"; close = ")";
				}
				out(arrayType + "::__new(" + exprList.length + ")");
				for (idx in 0...exprList.length) { out("->init(" + idx + ","); gen(exprList[idx]); out(")"); }
				out(close);
			case CppArray(arrayLoc): switch (arrayLoc) {
				case ArrayTyped(obj, idx, _): gen(obj); out("->__get("); gen(idx); out(")");
				case ArrayPointer(obj, idx): gen(obj); out(".ptr["); gen(idx); out("]");
				case ArrayRawPointer(obj, idx): gen(obj); out("["); gen(idx); out("]");
				case ArrayObject(obj, idx, elem):
					var close = if (isDynamicType(elem)) "" else switch (elem) {
						case TCppDynamicArray: out(CppTypeText.tcppToString(elem) + "( "); ")";
						case _: ".StaticCast< " + CppTypeText.tcppToString(elem) + " >()";
					};
					gen(obj); out("->__get("); gen(idx); out(")" + close);
				case ArrayVirtual(obj, idx): gen(obj); out("->__get("); gen(idx); out(")");
				case ArrayDynamic(obj, idx): gen(obj); out("->__GetItem("); gen(idx); out(")");
				case ArrayImplements(_, obj, idx): gen(obj); out("->__get("); gen(idx); out(")");
			}
			case CppCrement(incFlag, preFlag, lvalue):
				var op = incFlag.match(CppIncrement) ? "++" : "--";
				if (preFlag.match(Prefix)) out(op);
				genLValue(lvalue);
				if (preFlag.match(Postfix)) out(op);
			case CppModify(op, lvalue, rvalue):
				out(stringOfOpEq(op)); out("("); genLValue(lvalue); out(","); gen(rvalue); out(")");
			case CppPosition(name, line, clazz, func):
				out("::hx::SourceInfo(" + CppTypeText.strq(smartStrings, name) + "," + line + ","
					+ CppTypeText.strq(smartStrings, clazz) + "," + CppTypeText.strq(smartStrings, func) + ")");
			case CppIntSwitch(cond, cases, defVal):
				out("switch((int)("); gen(cond); out("))");
				writer.beginBlock();
				for (c in cases) {
					out(spacer()); writer.writeI("");
					for (v in c.values) out("case (int)" + v + ": ");
					gen(c.body);
					out(spacer()); writer.writeI("break;\n");
				}
				switch (defVal) { case null: case e: outI("default:"); gen(e); }
				out(spacer()); writer.endBlock();
			// General (string) switch: an if-chain over a temp, then the shared goto label
			case CppSwitch(cond, condType, cases, defVal, label):
				var tmp = "_hx_switch_" + tempId; tempId++;
				out(CppTypeText.tcppToString(condType) + " " + tmp + " = "); gen(cond); out(";\n");
				for (c in cases) {
					outI("if ( ");
					var orStr = "";
					for (v in c.values) { out(orStr + " (" + tmp + "=="); gen(v); out(")"); orStr = " || "; }
					out(" )");
					gen(c.body);
				}
				switch (defVal) { case null: case e: outI("/* default */"); gen(e); }
				outI(labelName(label) + ":");
			case CppWhile(cond, block, flag, loopId):
				switch (flag) {
					case NormalWhile: out("while("); gen(cond); out(")"); lastLine = -1; gen(block);
					case DoWhile: out("do "); lastLine = -1; genWithInjection(block, false); out(" while("); gen(cond); out(");\n");
				}
				if (loopId > -1) outI(labelName(loopId) + ":");
			// CppEnumField: a reference to an enum constructor as a dynamic value.
			case CppEnumField(en, ef):
				out("::" + CppTypeText.joinClassPathRemap(en.path, "::") + "_obj::" + cppEnumNameOf(ef) + "_dyn()");
			// CppEnumParameter: read the nth argument of an enum value via its typed getter.
			case CppEnumParameter(obj, field, index):
				var valueType = CppTypeOf.cppTypeOf(CppTypeOf.getNthType(field, index));
				var baseType = CppTypeOf.enumGetterType(valueType);
				gen(obj);
				if (CppTypeOf.cppIsDynamicType(obj.ctype)) out(".StaticCast< ::hx::EnumBase >()");
				out("->_hx_get" + baseType + "(" + index + ")");
				switch (valueType) {
					case TCppObjectArray(_) | TCppScalarArray(_) | TCppDynamicArray | TCppClass | TCppEnum(_) | TCppInst(_, _):
						out(".StaticCast< " + CppTypeText.tcppToString(valueType) + " >()");
					case _:
				}
			// CppObjectDecl: an anonymous object literal. A small struct literal builds a typed AnonStruct;
			// otherwise a dynamic Anon with fields set by hash order.
			case CppObjectDecl(fields, isStruct):
				var length = fields.length;
				var lengthStr = Std.string(length);
				var isDyn = !expr.ctype.match(TCppVoid);
				if (isDyn) out(" ::Dynamic(");
				if (isStruct && length > 0 && length <= 5) {
					out("::hx::AnonStruct" + lengthStr + "_obj< "
						+ fields.map(function(f) return CppTypeText.tcppToString(f.expr.ctype)).join(",") + " >::Create(");
					var sep = "";
					for (f in fields) { out(sep + CppTypeText.strq(smartStrings, f.name) + ","); sep = ","; gen(f.expr); }
					out(")");
				} else {
					out("::hx::Anon_obj::Create(" + lengthStr + ")");
					var sorted = fields.map(function(f) return {name: f.name, expr: f.expr, h: CppTypeText.genHash32(0, f.name)});
					sorted.sort(function(a, b) return a.h < b.h ? -1 : (a.h > b.h ? 1 : 0));
					writer.pushIndent();
					var idx = 0;
					for (s in sorted) {
						out("\n" + spacer());
						writer.writeI("->setFixed(" + idx + "," + CppTypeText.strq(smartStrings, s.name) + ",");
						gen(s.expr);
						out(")");
						idx++;
					}
				}
				if (isDyn) out(")");
				writer.popIndent();
			// CppClosure use: instantiate the local closure struct, passing `this` (if captured) and each
			// captured (undeclared) variable by name.
			case CppClosure(closure):
				out(" ::Dynamic(new _hx_Closure_" + closure.closeId + "(");
				var sep = "";
				switch (closure.closeThis) {
					case null:
					case th: out(th.match(ThisReal) ? "this" : "__this"); sep = ",";
				}
				for (name in closure.closeUndeclared.keys()) {
					out(sep); sep = ",";
					out(CppTypeText.keywordRemap(name));
				}
				out("))");
			// CppTry: a try block whose injection prologue registers each catch type, then a single
			// `catch(::Dynamic _hx_e)` that dispatches by runtime type to each catch body.
			case CppTry(body, catches):
				inline function cppVarTypeOf(v:TVar):String return CppTypeText.tcppToString(CppTypeOf.cppTypeOf(v.type));
				inline function cppMacroVarTypeOf(v:TVar):String {
					var t = cppVarTypeOf(v);
					return t.indexOf(",") >= 0 ? StringTools.replace(t, ",", " HX_COMMA ") : t;
				}
				out("try ");
				topPrologue = function(gc) {
					for (idx in 0...catches.length)
						outI("HX_STACK_CATCHABLE(" + cppMacroVarTypeOf(catches[idx].v) + ", " + idx + ");\n");
				};
				genWithInjection(body, false);
				if (catches.length > 0) {
					out(" catch( ::Dynamic _hx_e) ");
					writer.beginBlock();
					var seenDynamic = false;
					var elseStr = "";
					for (c in catches) {
						var typeName = cppVarTypeOf(c.v);
						switch (CppTypeOf.cppTypeOf(c.v.type)) {
							case TCppInterface(klass):
								outI(elseStr + "if (::hx::TIsInterface< (int)" + cppClassHash(klass) + " >(_hx_e.mPtr))");
							case TCppString:
								outI(elseStr + "if (_hx_e.IsClass< ::String >() && _hx_e->toString()!=null() )");
							case _:
								if (typeName == "Dynamic") { seenDynamic = true; outI(elseStr); }
								else outI(elseStr + "if (_hx_e.IsClass< " + typeName + " >() )");
						}
						var cc = c;
						var tn = typeName;
						topPrologue = function(gc) {
							outI("HX_STACK_BEGIN_CATCH\n");
							outI(tn + " " + CppTypeText.cppVarNameOf(cc.v) + " = _hx_e;\n");
						};
						genWithInjection(cc.body, true);
						elseStr = "else ";
					}
					if (!seenDynamic) {
						outI("else {\n");
						outI("\tHX_STACK_DO_THROW(_hx_e);\n");
						outI("}\n");
					}
					out(spacer());
					writer.endBlock();
				}
			case _:
				throw new hxc.core.TypingError("emit: CppExprDef not ported yet: " + expr.expr.getName(), expr.pos);
		}
	}

	inline function labelName(i:Int):String return "_hx_goto_" + i;

	// A non-empty scalar array whose every element is a literal.
	function isConstScalarArray(ctype:CppType, exprList:Array<CppExpr>):Bool {
		if (exprList.length == 0) return false;
		return switch (ctype) {
			case TCppScalarArray(_):
				for (e in exprList) switch (e.expr) { case CppInt(_) | CppFloat(_) | CppString(_) | CppBool(_): case _: return false; }
				true;
			case _: false;
		};
	}

	static inline function isDynamicType(t:CppType):Bool {
		return switch (t) {
			case TCppDynamic | TCppObject | TCppVariant | TCppWrapped(_) | TCppGlobal | TCppNull | TCppInterface(_): true;
			case _: false;
		}
	}

	// The spacer + indented write used by nested statement markers
	inline function outI(value:String):Void {
		out(spacer());
		writer.writeI(value);
	}

	// The enum constructor's C++ name (@:native override or keyword-remapped).
	function cppEnumNameOf(ef:TEnumField):String {
		for (m in ef.meta) if (m.name == ":native" && m.params.length > 0) switch (m.params[0].expr) {
			case EConst(CString(s, _)): return s;
			case _:
		}
		return CppTypeText.keywordRemap(ef.name);
	}

	// The C++ return-type + abi + parenthesized arg-type list.
	function ctxFunctionSignature(includeNames:Bool, tfun:T, abi:String):String {
		return switch (hxc.core.TypeFunctions.follow(tfun)) {
			case TFun(sig): CppTypeText.tcppToString(CppTypeOf.cppTypeOf(sig.ret)) + " " + abi + "(" + ctxTfunArgList(includeNames, sig.args) + ")";
			case _: "void *";
		}
	}

	// Arg types (optionally with names); an optional scalar arg is wrapped in ::hx::Null< > since a scalar
	// cannot itself hold null.
	function ctxTfunArgList(includeNames:Bool, args:Array<{name:String, opt:Bool, t:T}>):String {
		function oType(o:Bool, argType:T):String {
			var typeStr = CppTypeText.tcppToString(CppTypeOf.cppTypeOf(argType));
			return (o && CppTypeOf.cppTypeOf(argType).match(TCppScalar(_)) && typeStr != "Dynamic")
				? "::hx::Null< " + typeStr + " > " : typeStr;
		}
		return [for (a in args) oType(a.opt, a.t) + (includeNames ? " " + CppTypeText.keywordRemap(a.name) : "")].join(",");
	}

	// The 0x-prefixed 32-bit hash of the class path, used as an interface id.
	function cppClassHash(klass:TClass):String {
		return "0x" + StringTools.lpad(StringTools.hex(CppTypeText.genHash32(0, CppTypeOf.joinClassPath(klass.path, "::")), 8).toLowerCase(), "0", 8);
	}

	// The C++ type text with commas escaped for a macro argument.
	function cppMacroVarType(v:TVar):String {
		var t = CppTypeText.tcppToString(CppTypeOf.cppTypeOf(v.type));
		return t.indexOf(",") >= 0 ? StringTools.replace(t, ",", " HX_COMMA ") : t;
	}

	// The (type, name) of a closure/function argument; an optional argument takes the Null<T> type, and one
	// with a real default is renamed with the unpack prefix.
	function cppArgTypeName(v:TVar, dflt:Null<TExpr>, prefix:String):{t:String, n:String} {
		var remap = CppTypeText.cppVarNameOf(v);
		return switch (dflt) {
			case null: {t: CppTypeText.tcppToString(CppTypeOf.cppTypeOf(v.type)), n: remap};
			case {expr: TConst(TNull)}: {t: CppTypeText.tcppToString(CppTypeOf.cppTypeOfNull([], v.type)), n: remap};
			case _: {t: CppTypeText.tcppToString(CppTypeOf.cppTypeOfNull([], v.type)), n: prefix + remap};
		};
	}

	function cppArgList(args:Array<{v:TVar, dflt:Null<TExpr>}>, prefix:String):String {
		return args.map(function(a) { var r = cppArgTypeName(a.v, a.dflt, prefix); return r.t + " " + r.n; }).join(",");
	}

	// Over format_code: emit the raw code, normalizing CRLF to LF, with {N} replaced by argument N and
	// {{ /
	// }} collapsing to a literal brace.
	function emitCppCode(code:String, exprs:Array<CppExpr>):Void {
		code = code.split("\r\n").join("\n");
		var i = 0;
		var n = code.length;
		while (i < n) {
			var c = code.charAt(i);
			if (c == "{") {
				if (i + 1 < n && code.charAt(i + 1) == "{") { out("{"); i += 2; continue; }
				var j = code.indexOf("}", i + 1);
				if (j > i + 1) {
					var idx = Std.parseInt(code.substring(i + 1, j));
					if (idx != null && idx >= 0 && idx < exprs.length) { gen(exprs[idx]); i = j + 1; continue; }
				}
				out("{"); i += 1;
			} else if (c == "}" && i + 1 < n && code.charAt(i + 1) == "}") {
				out("}"); i += 2;
			} else {
				out(c); i += 1;
			}
		}
	}

	function defaultValueString(value:TExpr):String {
		return switch (value.expr) {
			case TConst(TInt(i)): Std.string(i);
			case TConst(TFloat(f)): "((Float)" + f + ")";
			case TConst(TString(s)): CppTypeText.strq(smartStrings, s);
			case TConst(TBool(b)): b ? "true" : "false";
			case TConst(TNull): "null()";
			// An enum constructor default (function foo(t = None)) emits the dynamic getter
			case TField(_, FEnum(enm, ef)): "::" + CppTypeText.joinClassPathRemap(enm.path, "::") + "_obj::" + cppEnumNameOf(ef) + "_dyn()";
			case _: "/* Hmmm */";
		};
	}

	// Unpack each optional argument's default from its __o_ shadow.
	public function cppGenDefaultValues(args:Array<{v:TVar, dflt:Null<TExpr>}>, prefix:String):Void {
		for (a in args) switch (a.dflt) {
			case null:
			case {expr: TConst(TNull)}:
			case const:
				var vtype = CppTypeOf.cppTypeOf(a.v.type);
				var notNull = CppTypeOf.isCppScalar(vtype);
				var name = CppTypeText.cppVarNameOf(a.v);
				var spacer = debugLevel > 0 ? "            \t" : "";
				var pname = prefix + name;
				out(spacer + "\t" + CppTypeText.tcppToString(vtype) + " " + name + " = " + pname);
				out(notNull ? ".Default(" + defaultValueString(const) + ");\n"
					: ";\n" + spacer + "\tif (::hx::IsNull(" + pname + ")) " + name + " = " + defaultValueString(const) + ";\n");
		}
	}

	// Emit a local closure struct definition. The debug>=2 stack details are skipped (the emitter runs at
	// debug level 1).
	function genClosure(closure:CppClosure):Void {
		var undeclared = closure.closeUndeclared;
		var argc = 0;
		for (_ in undeclared.keys()) argc++;
		if (argc >= 20 || closure.closeArgs.length >= 20) writer.addBigClosures();
		var argsCount = Std.string(closure.closeArgs.length);
		outI("HX_BEGIN_LOCAL_FUNC_S" + argc + "(");
		out(closure.closeThis != null ? "::hx::LocalThisFunc," : "::hx::LocalFunc,");
		out("_hx_Closure_" + closure.closeId);
		for (name in undeclared.keys())
			out("," + cppMacroVarType(undeclared.get(name)) + "," + CppTypeText.keywordRemap(name));
		out(") HXARGC(" + argsCount + ")\n");
		outI(CppTypeText.tcppToString(closure.closeType) + " _hx_run(" + cppArgList(closure.closeArgs, "__o_") + ")");
		var saved = topPrologue;
		// A closure body carries no injection: only the top block gets the field-init setvar. Clear it so
		// the closure's own last statement (its return) does not swallow the outer `name = ` prefix, which
		// belongs on the closure-call expression in the enclosing block.
		var savedSetvar = topSetvar;
		topSetvar = "";
		topPrologue = function(gc) {
			cppGenDefaultValues(closure.closeArgs, "__o_");
			// gen_closure uses the tree's output_i (spacer + write_i), so the closure frame is indented by
			// the closure body depth .
			CppGenClass.hxStackPush(com, writer, emitClassName, emitFuncName, closure.closeExpr.pos.file, lineOf(closure.closeExpr.pos), gc, null, debugLevel, forHeader, true);
		};
		genWithInjection(closure.closeExpr, true);
		topPrologue = saved;
		topSetvar = savedSetvar;
		var ret = closure.closeType.match(TCppVoid) ? "(void)" : "return";
		outI("HX_END_LOCAL_FUNC" + argsCount + "(" + ret + ")\n\n");
	}

	// The C++ operator text (assignment is lowered earlier)
	function stringOfOp(op:hxc.ast.Ast.Binop):String {
		return switch (op) {
			case OpAdd: "+"; case OpMult: "*"; case OpDiv: "/"; case OpSub: "-";
			case OpEq: "=="; case OpNotEq: "!="; case OpGt: ">"; case OpGte: ">=";
			case OpLt: "<"; case OpLte: "<="; case OpAnd: "&"; case OpOr: "|"; case OpXor: "^";
			case OpBoolAnd: "&&"; case OpBoolOr: "||"; case OpShl: "<<"; case OpShr: ">>";
			case OpUShr: "<<<"; case OpMod: "%"; case OpInterval: "..."; case OpArrow: "->";
			case OpIn: " in "; case OpNullCoal: "??";
			case OpAssign | OpAssignOp(_): throw new hxc.core.TypingError("Unprocessed OpAssign", rootPos);
		}
	}

	function isConstantZero(e:CppExpr):Bool {
		return switch (e.expr) {
			case CppFloat(x): Std.parseFloat(x) == 0.0;
			case CppInt(i): i == 0;
			case CppCastScalar(inner, _): isConstantZero(inner);
			case _: false;
		}
	}

	// The generic CppCall(func, args) path (native/objc/quick-alloc specials come later)
	function genCall(func:CppFuncLoc, args:Array<CppExpr>, expr:CppExpr):Void {
		// A `new C(args)` on a quick-allocatable class lowers to the fast __alloc path `C_obj::__alloc(
		// HX_CTX ,args)` instead of a __new call
		switch (func) {
			case FuncNew(TCppInst(klass, p)) if (!CppTypeOf.isNativeClass(klass)):
				out(CppTypeText.cppClassPathOf(klass, p) + "_obj::__alloc( HX_CTX ");
				for (arg in args) { out(","); gen(arg); }
				out(")");
				return;
			case _:
		}
		var doCall = true;
		var closeCall = "";
		var argsRef = args;
		switch (func) {
			case FuncThis(field, _): out("this->" + CppTypeText.cppMemberNameOf(field));
			case FuncInstance(obj, inst, field):
				var accessOp = (obj.ctype.match(TCppString) || inst.match(InstStruct)) ? "." : "->";
				gen(obj); out(accessOp + CppTypeText.cppMemberNameOf(field));
			// A call through an interface routes to the interface's static dispatch stub
			// `Iface_obj::method(receiver, args)` (the receiver becomes the first argument); a native-gen
			// interface keeps the direct `receiver->method(args)` form.
			case FuncInterface(obj, clazz, field) if (!CppTypeOf.isNativeGenClass(clazz)):
				out(CppTypeText.cppClassName(clazz) + "::" + CppTypeText.cppMemberNameOf(field));
				argsRef = [obj].concat(args);
			case FuncInterface(obj, _, field): gen(obj); out("->" + CppTypeText.cppMemberNameOf(field));
			// A @:nativeStaticExtension static call C.f(first, rest...) lowers to first->f(rest...): the
			// first argument becomes the receiver, the rest stay as call arguments.
			case FuncStatic(clazz, false, field) if (hxc.core.TypeFunctions.hasMeta(":nativeStaticExtension", field.meta)):
				if (argsRef.length < 1)
					throw new hxc.core.TypingError("Native static extensions must have at least 1 argument", expr.pos);
				gen(argsRef[0]); out("->" + CppTypeText.cppMemberNameOf(field));
				argsRef = argsRef.slice(1);
			case FuncStatic(clazz, _, field):
				var rename = hxc.ast.Ast.getMetaString(field.meta, ":native");
				if (rename != null && rename != "") {
					if (rename.indexOf(" ") >= 0) { out("("); closeCall = ")"; }
					out(rename);
				} else {
					out(CppTypeText.cppClassName(clazz)); out("::" + CppTypeText.cppMemberNameOf(field));
				}
			// @:templatedCall emits the leading Class argument between angle brackets.
			case FuncTemplate(clazz, field, path, native):
				var rename = hxc.ast.Ast.getMetaString(field.meta, ":native");
				if (rename != null && rename != "") {
					if (rename.indexOf(" ") >= 0) { out("("); closeCall = ")"; }
					out(rename);
				} else {
					out(CppTypeText.cppClassName(clazz)); out("::" + CppTypeText.cppMemberNameOf(field));
				}
				out("< " + cppTemplateParam(path, native) + "  >");
			case FuncNew(newType): out(newTarget(newType, expr));
			case FuncInternal(f, name, join): gen(f); out(join + name);
			case FuncExtern(name, isGlobal): if (isGlobal) out(" ::"); out(name);
			case FuncExpression(e): gen(e);
			// FuncSuper: a call up to the superclass method.
			case FuncSuper(_, TCppInst(klass, p), field) if (CppTypeOf.isNativeClass(klass)):
				out(CppTypeText.cppClassPathOf(klass, p) + "::" + CppTypeText.cppMemberNameOf(field));
			case FuncSuper(thiz, _, field):
				out((thiz.match(ThisReal) ? "this->" : "__->") + "super::" + CppTypeText.cppMemberNameOf(field));
			// FuncSuperConstruct: chain to the superclass constructor; a native super needs no call at all.
			case FuncSuperConstruct(TCppInst(klass, _)) if (CppTypeOf.isNativeClass(klass)):
				doCall = false;
			case FuncSuperConstruct(_):
				out((realThisPtr ? "" : "__this->") + "super::__construct");
			// FuncEnumConstruct: a direct call to the enum constructor factory.
			case FuncEnumConstruct(enm, ef):
				out("::" + CppTypeText.joinClassPathRemap(enm.path, "::") + "_obj::" + cppEnumNameOf(ef));
			case _:
				// FuncEnumConstruct/FuncSuper/FuncSuperConstruct/FuncTemplate/FuncInterface-native land
				// with the enum/super/interface tranche
				throw new hxc.core.TypingError("emit: CppCall func form not ported yet: " + func.getName(), expr.pos);
		}
		if (doCall) {
			var sep = "";
			out("(");
			for (arg in argsRef) { out(sep); sep = ","; gen(arg); }
			out(")" + closeCall);
		}
	}

	static function cppTemplateParam(path:hxc.core.Globals.Path, native:Bool):String {
		var p = "::" + CppTypeText.joinClassPathRemap(path, "::");
		if (native) return p;
		return switch (p) {
			case "::Array": "::hx::ArrayBase";
			case "::Int": "int";
			case "::Bool": "bool";
			case _: p;
		}
	}

	function newTarget(newType:CppType, expr:CppExpr):String {
		return switch (newType) {
			case TCppString: "::String";
			case TCppDynamicArray: "::cpp::VirtualArray_obj::__new";
			case TCppObjectArray(_): "::Array_obj< ::Dynamic>::__new";
			case TCppScalarArray(value): "::Array_obj< " + CppTypeText.tcppToString(value) + " >::__new";
			case TCppObjC(klass): CppTypeText.cppClassPathOf(klass, []) + "_obj::__new";
			case TCppNativePointer(klass): "new " + CppTypeText.cppClassPathOf(klass, []);
			case TCppInst(klass, p) if (CppTypeOf.isNativeClass(klass)): CppTypeText.cppClassPathOf(klass, p);
			case TCppInst(klass, p): CppTypeText.cppClassPathOf(klass, p) + "_obj::__new";
			case TCppClass: "::hx::Class_obj::__new";
			case TCppFunction(_, _, _): CppTypeText.tcppToString(newType);
			case _: throw new hxc.core.TypingError("emit: unknown 'new' target " + CppTypeText.tcppToString(newType), expr.pos);
		}
	}

	// A function value (CppFunction, not a call)
	function genFunctionValue(func:CppFuncLoc, expr:CppExpr):Void {
		switch (func) {
			case FuncThis(field, _): out("this->" + CppTypeText.cppMemberNameOf(field) + "_dyn()");
			case FuncStatic(clazz, _, field):
				var rename = hxc.ast.Ast.getMetaString(field.meta, ":native");
				if (rename != null && rename != "") out(rename);
				else { out(CppTypeText.cppClassName(clazz)); out("::" + CppTypeText.cppMemberNameOf(field) + "_dyn()"); }
			case FuncExpression(e): gen(e);
			case FuncExtern(name, isGlobal): if (isGlobal) out(" ::"); out(name);
			// An instance method reference as a dynamic closure
			case FuncInstance(e, inst, field):
				gen(e);
				out((e.ctype.match(TCppString) || inst.match(InstStruct) ? "." : "->") + CppTypeText.cppMemberNameOf(field) + "_dyn()");
			case FuncInterface(e, _, field):
				gen(e);
				out("->__Field(" + CppTypeText.strq(smartStrings, field.name) + ", ::hx::paccDynamic)");
			case FuncInternal(e, name, _):
				gen(e);
				out("->__Field(" + CppTypeText.strq(smartStrings, name) + ",::hx::paccDynamic)");
			case _:
				throw new hxc.core.TypingError("emit: CppFunction form not ported yet: " + func.getName(), expr.pos);
		}
	}

	function genVarLoc(loc:CppVarLoc):Void {
		switch (loc) {
			case VarClosure(v) | VarLocal(v): out(CppTypeText.cppVarNameOf(v));
			case VarStatic(clazz, objc, member):
				var rename = hxc.ast.Ast.getMetaString(member.meta, ":native");
				if (rename != null && rename != "") out(rename);
				else if (objc) { out(CppTypeText.joinClassPathRemap(clazz.path, "::")); out("." + CppTypeText.cppMemberNameOf(member)); }
				else { out(CppTypeText.cppClassName(clazz)); out("::" + CppTypeText.cppMemberNameOf(member)); }
			case VarThis(member, _): out("this->" + CppTypeText.cppMemberNameOf(member));
			case VarInstance(obj, member, _, op): gen(obj); out(op + CppTypeText.cppMemberNameOf(member));
			case VarInternal(obj, op, member): gen(obj); out(op + member);
			case VarInterface(obj, member): gen(obj); out("->" + CppTypeText.cppMemberNameOf(member) + "_get()");
		}
	}

	function genLValue(lvalue:CppLValue):Void {
		switch (lvalue) {
			case CppVarRef(loc): genVarLoc(loc);
			case CppArrayRef(arrayLoc): switch (arrayLoc) {
				case ArrayObject(obj, idx, _): out("::hx::IndexRef("); gen(obj); out(".mPtr,"); gen(idx); out(")");
				case ArrayTyped(obj, idx, _) | ArrayRawPointer(obj, idx): gen(obj); out("["); gen(idx); out("]");
				case ArrayPointer(obj, idx): gen(obj); out(".ptr["); gen(idx); out("]");
				case ArrayVirtual(obj, idx) | ArrayDynamic(obj, idx): out("::hx::IndexRef("); gen(obj); out(".mPtr,"); gen(idx); out(")");
				case ArrayImplements(_, obj, idx): out("::hx::__ArrayImplRef("); gen(obj); out(","); gen(idx); out(")");
			}
			case CppExternRef(name, isGlobal): if (isGlobal) out(" ::"); out(name);
			case CppDynamicRef(e, name):
				var objPtr = e.ctype.match(TCppVariant) ? "getObject()" : ".mPtr";
				out("::hx::FieldRef(("); gen(e); out(")" + objPtr + "," + CppTypeText.strq(smartStrings, name) + ")");
		}
	}

	// The compound-assignment runtime helper
	function stringOfOpEq(op:hxc.ast.Ast.Binop):String {
		return switch (op) {
			case OpAdd: "::hx::AddEq"; case OpMult: "::hx::MultEq"; case OpDiv: "::hx::DivEq";
			case OpSub: "::hx::SubEq"; case OpAnd: "::hx::AndEq"; case OpOr: "::hx::OrEq";
			case OpXor: "::hx::XorEq"; case OpShl: "::hx::ShlEq"; case OpShr: "::hx::ShrEq";
			case OpUShr: "::hx::UShrEq"; case OpMod: "::hx::ModEq";
			case _: throw new hxc.core.TypingError("Bad assign op", rootPos);
		}
	}
}
