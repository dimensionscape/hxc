package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.generators.cpp.CppType;
import hxc.generators.cpp.CppExpr;

using StringTools;

// The assign-op forms carry their inner operator through IaBinOp.
enum CppiaOp {
	IaFunction;
	IaVar;
	IaToInterface;
	IaToDynArray;
	IaToDataArray;
	IaToInterfaceArray;
	IaFun;
	IaCast;
	IaTCast;
	IaBlock;
	IaBreak;
	IaContinue;
	IaIsNull;
	IaNotNull;
	IaSet;
	IaCall;
	IaCallGlobal;
	IaCallStatic;
	IaCallMember;
	IaCallSuper;
	IaCallThis;
	IaCallSuperNew;
	IaCreateEnum;
	IaADef;
	IaIf;
	IaIfElse;
	IaFStatic;
	IaFName;
	IaFThisInst;
	IaFLink;
	IaFThisName;
	IaFEnum;
	IaThrow;
	IaArrayI;
	IaPlusPlus;
	IaPlusPlusPost;
	IaMinusMinus;
	IaMinusMinusPost;
	IaNeg;
	IaBitNot;
	IaLogicNot;
	IaTVars;
	IaVarDecl;
	IaVarDeclI;
	IaNew;
	IaReturn;
	IaRetVal;
	IaPosInfo;
	IaObjDef;
	IaClassOf;
	IaWhile;
	IaFor;
	IaEnumI;
	IaSwitch;
	IaTry;
	IaImplDynamic;
	IaConstInt;
	IaConstFloat;
	IaConstString;
	IaConstFalse;
	IaConstTrue;
	IaConstNull;
	IaConsThis;
	IaConstSuper;
	IaCastInt;
	IaCastBool;
	IaInterface;
	IaClass;
	IaAccessNormal;
	IaAccessNot;
	IaAccessResolve;
	IaAccessCall;
	IaEnum;
	IaInline;
	IaMain;
	IaNoMain;
	IaResources;
	IaReso;
	IaNoCast;
	IaAccessCallNative;
	IaBinOp(op:Binop);
}

class CppiaWriter {
	final com:Context;
	final filename:String;
	final asciiOut:Bool;
	final debug:Bool;
	final doComment:Bool;
	final indentStr:String;
	var indent:String = "";
	var indents:Array<String> = [];
	var justFinishedBlock:Bool = false;
	var classCount:Int = 0;
	var returnType:T;
	final buffer:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
	final identTable:Map<String, Int> = new Map();
	var identCount:Int = 0;
	final fileTable:Map<String, Int> = new Map();
	final identBuffer:StringBuf = new StringBuf();
	final cppiaAst:Bool;
	final typeTable:Map<String, Int> = new Map();
	var typeCount:Int = 0;
	final typeBuffer:StringBuf = new StringBuf();

	public function new(com:Context, filename:String, asciiOut:Bool) {
		this.com = com;
		this.filename = filename;
		this.asciiOut = asciiOut;
		this.debug = asciiOut;
		this.doComment = asciiOut && com.defines.rawDefined("annotate_source");
		this.indentStr = asciiOut ? "\t" : "";
		this.cppiaAst = !com.defines.rawDefined("no_cppia_ast");
		this.returnType = TypeFunctions.mkMono();
	}

	public static function opInfo(op:CppiaOp):{name:String, index:Int} {
		return switch (op) {
			case IaFunction: {name: "FUNCTION", index: 1};
			case IaVar: {name: "VAR", index: 2};
			case IaToInterface: {name: "TOINTERFACE", index: 3};
			case IaToDynArray: {name: "TODYNARRAY", index: 4};
			case IaToDataArray: {name: "TODATAARRAY", index: 5};
			case IaToInterfaceArray: {name: "TOINTERFACEARRAY", index: 6};
			case IaFun: {name: "FUN", index: 7};
			case IaCast: {name: "CAST", index: 8};
			case IaBlock: {name: "BLOCK", index: 9};
			case IaBreak: {name: "BREAK", index: 10};
			case IaContinue: {name: "CONTINUE", index: 11};
			case IaIsNull: {name: "ISNULL", index: 12};
			case IaNotNull: {name: "NOTNULL", index: 13};
			case IaSet: {name: "SET", index: 14};
			case IaCall: {name: "CALL", index: 15};
			case IaCallGlobal: {name: "CALLGLOBAL", index: 16};
			case IaCallStatic: {name: "CALLSTATIC", index: 17};
			case IaCallMember: {name: "CALLMEMBER", index: 18};
			case IaCallSuper: {name: "CALLSUPER", index: 19};
			case IaCallThis: {name: "CALLTHIS", index: 20};
			case IaCallSuperNew: {name: "CALLSUPERNEW", index: 21};
			case IaCreateEnum: {name: "CREATEENUM", index: 22};
			case IaADef: {name: "ADEF", index: 23};
			case IaIf: {name: "IF", index: 24};
			case IaIfElse: {name: "IFELSE", index: 25};
			case IaFName: {name: "FNAME", index: 27};
			case IaFStatic: {name: "FSTATIC", index: 28};
			case IaFThisInst: {name: "FTHISINST", index: 29};
			case IaFLink: {name: "FLINK", index: 30};
			case IaFThisName: {name: "FTHISNAME", index: 31};
			case IaFEnum: {name: "FENUM", index: 32};
			case IaThrow: {name: "THROW", index: 33};
			case IaArrayI: {name: "ARRAYI", index: 34};
			case IaPlusPlus: {name: "++", index: 35};
			case IaPlusPlusPost: {name: "+++", index: 36};
			case IaMinusMinus: {name: "--", index: 37};
			case IaMinusMinusPost: {name: "---", index: 38};
			case IaNeg: {name: "NEG", index: 39};
			case IaBitNot: {name: "~", index: 40};
			case IaLogicNot: {name: "!", index: 41};
			case IaTVars: {name: "TVARS", index: 42};
			case IaVarDecl: {name: "VARDECL", index: 43};
			case IaVarDeclI: {name: "VARDECLI", index: 44};
			case IaNew: {name: "NEW", index: 45};
			case IaReturn: {name: "RETURN", index: 46};
			case IaRetVal: {name: "RETVAL", index: 47};
			case IaPosInfo: {name: "POSINFO", index: 48};
			case IaObjDef: {name: "OBJDEF", index: 49};
			case IaClassOf: {name: "CLASSOF", index: 50};
			case IaWhile: {name: "WHILE", index: 51};
			case IaFor: {name: "FOR", index: 52};
			case IaEnumI: {name: "ENUMI", index: 53};
			case IaSwitch: {name: "SWITCH", index: 54};
			case IaTry: {name: "TRY", index: 55};
			case IaImplDynamic: {name: "IMPLDYNAMIC", index: 56};
			case IaConstInt: {name: "i", index: 57};
			case IaConstFloat: {name: "f", index: 58};
			case IaConstString: {name: "s", index: 59};
			case IaConstFalse: {name: "false", index: 60};
			case IaConstTrue: {name: "true", index: 61};
			case IaConstNull: {name: "NULL", index: 62};
			case IaConsThis: {name: "THIS", index: 63};
			case IaConstSuper: {name: "SUPER", index: 64};
			case IaCastInt: {name: "CASTINT", index: 65};
			case IaCastBool: {name: "CASTBOOL", index: 66};
			case IaInterface: {name: "INTERFACE", index: 67};
			case IaClass: {name: "CLASS", index: 68};
			case IaAccessNormal: {name: "N", index: 69};
			case IaAccessNot: {name: "n", index: 70};
			case IaAccessResolve: {name: "R", index: 71};
			case IaAccessCall: {name: "C", index: 72};
			case IaEnum: {name: "ENUM", index: 73};
			case IaInline: {name: "INLINE", index: 74};
			case IaMain: {name: "MAIN", index: 75};
			case IaNoMain: {name: "NOMAIN", index: 76};
			case IaResources: {name: "RESOURCES", index: 77};
			case IaReso: {name: "RESO", index: 78};
			case IaNoCast: {name: "NOCAST", index: 79};
			case IaAccessCallNative: {name: "V", index: 80};
			case IaTCast: {name: "TCAST", index: 221};
			case IaBinOp(bop):
				switch (bop) {
					case OpAdd: {name: "+", index: 101};
					case OpMult: {name: "*", index: 102};
					case OpDiv: {name: "/", index: 103};
					case OpSub: {name: "-", index: 104};
					case OpAssign: {name: "=", index: 105};
					case OpEq: {name: "==", index: 106};
					case OpNotEq: {name: "!=", index: 107};
					case OpGte: {name: ">=", index: 108};
					case OpLte: {name: "<=", index: 109};
					case OpGt: {name: ">", index: 110};
					case OpLt: {name: "<", index: 111};
					case OpAnd: {name: "&", index: 112};
					case OpOr: {name: "|", index: 113};
					case OpXor: {name: "^", index: 114};
					case OpBoolAnd: {name: "&&", index: 115};
					case OpBoolOr: {name: "||", index: 116};
					case OpShr: {name: ">>", index: 117};
					case OpUShr: {name: ">>>", index: 118};
					case OpShl: {name: "<<", index: 119};
					case OpMod: {name: "%", index: 120};
					case OpInterval: {name: "...", index: 121};
					case OpArrow: {name: "=>", index: 122};
					case OpIn: {name: " in ", index: 123};
					case OpNullCoal: {name: "??", index: 124};
					case OpAssignOp(inner):
						switch (inner) {
							case OpAdd: {name: "+=", index: 201};
							case OpMult: {name: "*=", index: 202};
							case OpDiv: {name: "/=", index: 203};
							case OpSub: {name: "-=", index: 204};
							case OpAnd: {name: "&=", index: 212};
							case OpOr: {name: "|=", index: 213};
							case OpXor: {name: "^=", index: 214};
							case OpBoolAnd: {name: "&&=", index: 215};
							case OpBoolOr: {name: "||=", index: 216};
							case OpShr: {name: ">>=", index: 217};
							case OpUShr: {name: ">>>=", index: 218};
							case OpShl: {name: "<<=", index: 219};
							case OpMod: {name: "%=", index: 220};
							case _: throw new TypingError("Bad assign op in cppia", Position.nullPos);
						}
				}
		}
	}

	public function stringId(name:String):Int {
		var found = identTable.get(name);
		if (found != null) return found;
		var size = identCount++;
		identTable.set(name, size);
		// The reader consumes the prefixed count in bytes
		identBuffer.add(haxe.io.Bytes.ofString(name).length + " " + name + "\n");
		return size;
	}

	public function incClasses():Void classCount++;

	public function stringText(name:String):String return stringId(name) + " ";

	public function typeId(name:String):Int {
		var name = name == "::hx::Class" ? "::Class" : name;
		var found = typeTable.get(name);
		if (found != null) return found;
		var size = typeCount++;
		typeTable.set(name, size);
		typeBuffer.add(haxe.io.Bytes.ofString(name).length + " " + name + "\n");
		return size;
	}

	// Text passes through; binary re-parses each token as an integer and
	// emits it length-prefixed (1 byte below 254, 254+2 bytes below 65536, else 255+4 bytes).
	public function write(str:String):Void {
		if (asciiOut) {
			buffer.addString(str);
		} else {
			for (tok in ~/[\n\t ]+/g.split(str)) {
				if (tok == "") continue;
				var i = Std.parseInt(tok);
				if (i == null) throw new TypingError("Bad cppia binary token: " + tok, Position.nullPos);
				if (i >= 0 && i < 254) {
					buffer.addByte(i & 255);
				} else if (i >= 0 && i < 65536) {
					buffer.addByte(254);
					buffer.addByte(i & 255);
					buffer.addByte((i >> 8) & 255);
				} else {
					buffer.addByte(255);
					buffer.addByte(i & 255);
					buffer.addByte((i >> 8) & 255);
					buffer.addByte((i >> 16) & 255);
					buffer.addByte((i >> 24) & 255);
				}
			}
		}
		justFinishedBlock = false;
	}

	public function comment(text:String):Void if (doComment) write("# " + text + "\n");

	public function commentOf(text:String):String return doComment ? " # " + text : "";

	public function typeTextString(typeName:String):String return typeId(typeName) + " ";

	public function typeText(typeT:T):String {
		var tname = cppiaAst ? CppiaGen.scriptCppTypeString(CppTypeOf.cppTypeOf(typeT)) : CppiaGen.scriptTypeString(typeT);
		return typeId(tname) + " ";
	}

	public function astType(cppType:CppType):String return typeId(CppiaGen.scriptCppTypeString(cppType)) + " ";

	public function writeType(typeT:T):Void write(typeText(typeT));

	public function boolText(value:Bool):String return value ? "1" : "0";

	public function writeBool(value:Bool):Void write(value ? "1 " : "0 ");

	public function staticText(value:Bool):String return value ? "1" : "0";

	public function writeData(str:String):Void buffer.addString(str);

	public function wint(ival:Int):Void write(ival + " ");

	public function ident(name:String):Void wint(stringId(name));

	public function cppInstText(clazz:TClass):String {
		return (clazz.path.pack.length == 0 && clazz.path.name == "Array")
			? typeTextString("Array")
			: typeTextString(CppTypeOf.joinClassPath(clazz.path, "."));
	}

	public function instText(clazz:TClass):String {
		return (clazz.path.pack.length == 0 && clazz.path.name == "Array")
			? typeId("Array< ::Dynamic >") + " "
			: typeText(TInst(clazz, []));
	}

	public function instName(clazz:TClass):Void write(cppiaAst ? cppInstText(clazz) : instText(clazz));

	public function enumText(e:TEnum):String return typeText(TEnum(e, []));

	public function op(x:CppiaOp):String {
		var info = opInfo(x);
		return (debug ? info.name : Std.string(info.index)) + " ";
	}

	public function writeOp(o:CppiaOp):Void write(op(o));

	public function writeOpLine(o:CppiaOp):Void write(op(o) + "\n");

	public function close():Void {
		var out = sys.io.File.write(filename, true);
		out.writeString(asciiOut ? "CPPIA\n" : "CPPIB\n");
		out.writeString(identCount + "\n");
		out.writeString(identBuffer.toString());
		out.writeString(typeCount + "\n");
		out.writeString(typeBuffer.toString());
		out.writeString(classCount + "\n");
		out.write(buffer.getBytes());
		out.close();
	}

	public function fileId(file:String):Int {
		var found = fileTable.get(file);
		if (found != null) return found;
		var strippedFile = CppGenClass.stripFile(com, file);
		var result = stringId(strippedFile);
		fileTable.set(file, result);
		return result;
	}

	public function constText(c:TConstant):String {
		return switch (c) {
			case TInt(i): op(IaConstInt) + i + " ";
			case TFloat(f): op(IaConstFloat) + stringText(CppiaGen.replaceFloatSeparators(f));
			case TString(s): op(IaConstString) + stringText(s);
			case TBool(true): op(IaConstTrue);
			case TBool(false): op(IaConstFalse);
			case TNull: op(IaConstNull);
			case TThis: op(IaConsThis);
			case TSuper: op(IaConstSuper);
		}
	}

	public function getArrayType(t:T):CppiaArrayOf {
		return switch (TypeFunctions.follow(t)) {
			case TInst(k, [param]) if (k.path.pack.length == 0 && k.path.name == "Array"):
				var typeName = CppiaGen.typeStringSuff("", param, false);
				switch (typeName) {
					case "::String": ArrayData("String");
					case "int" | "Float" | "bool" | "String" | "unsigned char" | "::cpp::UInt8": ArrayData(typeName);
					case "cpp::ArrayBase" | "cpp::VirtualArray" | "Dynamic": ArrayAny;
					case _ if (CppiaGen.isInterfaceType(param)): ArrayInterface(typeId(CppiaGen.scriptTypeString(param)));
					case _: ArrayObject;
				}
			case TAbstract(abs, pl) if (abs.impl != null && !TypeFunctions.hasMeta(":coreType", abs.meta)):
				getArrayType(CppTypeOf.cppGetUnderlyingType(abs, pl));
			case _: ArrayNone;
		}
	}

	public function pushReturn(inType:T):Void->Void {
		var oldReturnType = returnType;
		returnType = inType;
		return function() returnType = oldReturnType;
	}

	public function fileText(file:String):String return Std.string(fileId(file));

	public function indentOne():Void write(indentStr);

	public function pushIndent():Void {
		indents.unshift(indentStr);
		indent = indents.join("");
	}

	public function popIndent():Void {
		if (indents.length > 0) {
			indents.shift();
			indent = indents.join("");
		} else {
			indent = "/*?*/";
		}
	}

	public function writeI(x:String):Void write(indent + x);

	public function getIndent():String return indent;

	public function beginExpr():Void pushIndent();

	public function endExpr():Void {
		if (!justFinishedBlock) write("\n");
		popIndent();
		justFinishedBlock = true;
	}

	public function voidFunc(isStatic:Bool, isDynamic:Bool, funcName:String, fieldExpression:TExpr):Void {
		comment(funcName);
		write(op(IaFunction) + staticText(isStatic) + " " + boolText(isDynamic) + " " + stringText(funcName) + " ");
		write(typeTextString("Void") + "0\n");
		genExpression(fieldExpression);
	}

	public function func(isStatic:Bool, isDynamic:Bool, funcName:String, ret:T, args:Array<hxc.core.Type.TSignatureArg>,
			isInterface:Bool, fieldExpression:Null<TExpr>, abstractPos:Position):Void {
		comment(funcName);
		write(op(IaFunction) + staticText(isStatic) + " " + boolText(isDynamic) + " " + stringText(funcName) + " ");
		write(typeText(ret) + args.length + " ");
		for (a in args) write(stringText(a.name) + boolText(a.opt) + " " + typeText(a.t) + " ");
		write("\n");
		if (!isInterface) {
			var functionDef = fieldExpression == null ? null : switch (fieldExpression.expr) {
				case TFunction(fd): fd;
				case _: null;
			}
			if (functionDef != null) {
				if (cppiaAst) {
					var fnArgs = [for (a in functionDef.args) a.v];
					var cppExpr = CppRetype.retypeExpression(com, true, {v: 0}, TCppVoid, fnArgs, functionDef.type, functionDef.expr, false);
					beginExpr();
					writePos(functionDef.expr);
					write(op(IaFun) + typeText(functionDef.type) + fnArgs.length + "\n");
					var close = genFuncArgs([for (a in functionDef.args) {v: a.v, init: a.c}]);
					genExpressionTree(cppExpr);
					endExpr();
					close();
				} else {
					genExpression(fieldExpression);
				}
			} else {
				// Abstract function: a dummy body that should not get called
				beginExpr();
				wpos(abstractPos);
				writeOpLine(IaReturn);
				endExpr();
			}
		}
	}

	public function varField(readAcc:CppiaOp, writeAcc:CppiaOp, isExtern:Bool, isStatic:Bool, name:String, varType:T, varExpr:Null<TExpr>):Void {
		write(op(IaVar) + staticText(isStatic) + " " + op(readAcc) + op(writeAcc)
			+ boolText(isExtern) + " " + stringText(name) + typeText(varType)
			+ (varExpr != null ? "1" : "0")
			+ (doComment ? " # " + name + "\n" : "\n"));
		if (varExpr != null) {
			if (cppiaAst) {
				var toType = CppTypeOf.cppTypeOf(varExpr.type);
				var cppExpr = CppRetype.retypeExpression(com, true, {v: 0}, toType, [], TypeFunctions.tDynamic, varExpr, false);
				genExpressionTree(cppExpr);
			} else {
				genExpression(varExpr);
			}
		}
	}

	public function implDynamic():Void writeOpLine(IaImplDynamic);

	public function writeVar(v:TVar):Void {
		ident(v.name);
		wint(v.id);
		writeBool(TypeFunctions.hasVarFlag(v, VCaptured));
		writeType(v.type);
	}

	public function writeList(prefix:String, len:Int):Void write(prefix + " " + len + "\n");

	public function wpos(p:Position):Void {
		if (debug)
			write(fileText(p.file) + "\t" + CppEmit.getErrorLine(p) + indent);
	}

	public function writePos(expr:TExpr):Void wpos(expr.pos);

	public function writeCppPos(expr:CppExpr):Void wpos(expr.pos);

	public function checkCast(toType:T, expr:TExpr, forceCast:Bool, fromGenExpression:Bool):Void {
		function writeCast(text:String):Bool {
			if (!fromGenExpression) writePos(expr);
			write(text + "\n");
			beginExpr();
			genExpression(expr);
			endExpr();
			return true;
		}
		var wasCast = if (CppiaGen.isInterfaceType(toType)) {
			if (CppiaGen.isDynamicInCppia(com, expr)) {
				writeCast(op(IaToInterface) + typeText(toType) + " " + typeTextString("Dynamic"));
			} else if (!CppiaGen.isMatchingInterfaceType(toType, expr.type)) {
				writeCast(op(IaToInterface) + typeText(toType) + " " + typeText(expr.type));
			} else {
				false;
			}
		} else {
			var exprArrayType = CppiaGen.isDynamicInCppia(com, expr) ? ArrayNone : getArrayType(expr.type);
			switch [getArrayType(toType), exprArrayType] {
				case [ArrayAny, _]: false;
				case [ArrayObject, ArrayData(_)]: writeCast(op(IaToDynArray));
				case [ArrayObject, ArrayObject]: false;
				case [ArrayObject, ArrayNone] | [ArrayObject, ArrayAny]: writeCast(op(IaToDataArray) + typeTextString("Array.Object"));
				case [ArrayData(t), ArrayNone] | [ArrayData(t), ArrayObject] | [ArrayData(t), ArrayAny]:
					writeCast(op(IaToDataArray) + typeTextString("Array." + t));
				case [ArrayInterface(t), ArrayNone] | [ArrayInterface(t), ArrayAny]: writeCast(op(IaToInterfaceArray) + t);
				case [_, _]: false;
			}
		}
		if (!wasCast) {
			if (forceCast) {
				var castOp = switch (CppiaGen.typeString(expr.type)) {
					case "int": IaCastInt;
					case "bool": IaCastBool;
					case _ if (CppiaGen.isInterfaceType(toType)): IaNoCast;
					case _: IaCast;
				}
				writeOpLine(castOp);
			}
			genExpression(expr);
		}
	}

	public function genFuncArgs(args:Array<{v:TVar, init:Null<TExpr>}>):Void->Void {
		var genInits:Array<{v:TVar, const:TExpr}> = [];
		for (a in args) {
			write(indent + indentStr);
			writeVar(a.v);
			switch (a.init) {
				case null: write("0\n");
				case {expr: TConst(TNull)}: write("0\n");
				case const:
					var argType = CppTypeOf.cppTypeOf(const.type);
					if (CppTypeOf.isCppScalar(argType) || argType.match(TCppString)) {
						write("1 ");
						genExpressionOnly(const);
						write("\n");
					} else {
						genInits.unshift({v: a.v, const: const});
						write("0\n");
					}
			}
		}
		if (genInits.length == 0) {
			return function() {};
		} else {
			beginExpr();
			writePos(genInits[0].const);
			writeList(op(IaBlock), genInits.length + 1);
			for (gi in genInits) {
				var const = gi.const;
				var arg = gi.v;
				inline function startExpr() {
					beginExpr();
					writePos(const);
				}
				function localVar() {
					beginExpr();
					writePos(const);
					write(op(IaVar) + arg.id + commentOf(arg.name));
					endExpr();
				}
				startExpr();
				writeOpLine(IaIf);
				startExpr();
				writeOpLine(IaIsNull);
				localVar();
				endExpr();
				startExpr();
				writeOpLine(IaSet);
				localVar();
				genExpression(const);
				endExpr();
				beginExpr();
			}
			return function() endExpr();
		}
	}

	public function genExpression(expr:TExpr):Void {
		beginExpr();
		writePos(expr);
		genExpressionOnly(expr);
		endExpr();
	}

	// The typed-AST walker (main, __init__, enum meta)
	public function genExpressionOnly(expr:TExpr):Void {
		var expression = CppiaGen.removeParens(expr);
		switch (expression.expr) {
			case TFunction(functionDef):
				write(op(IaFun) + typeText(functionDef.type) + functionDef.args.length + "\n");
				var close = genFuncArgs([for (a in functionDef.args) {v: a.v, init: a.c}]);
				var pop = pushReturn(functionDef.type);
				genExpression(functionDef.expr);
				pop();
				close();
			case TBlock(exprList):
				writeList(op(IaBlock), exprList.length);
				for (e in exprList) genExpression(e);
			case TConst(const):
				write(constText(const));
			case TBreak:
				writeOp(IaBreak);
			case TContinue:
				writeOp(IaContinue);
			case TBinop(OpAssign, e1, e2):
				writeOpLine(IaSet);
				genExpression(e1);
				checkCast(e1.type, e2, false, false);
			case TBinop(OpEq, e1, {expr: TConst(TNull)}):
				writeOpLine(IaIsNull);
				genExpression(e1);
			case TBinop(OpNotEq, e1, {expr: TConst(TNull)}):
				writeOpLine(IaNotNull);
				genExpression(e1);
			case TBinop(OpEq, {expr: TConst(TNull)}, e1):
				writeOpLine(IaIsNull);
				genExpression(e1);
			case TBinop(OpNotEq, {expr: TConst(TNull)}, e1):
				writeOpLine(IaNotNull);
				genExpression(e1);
			case TBinop(bop, e1, e2):
				writeOpLine(IaBinOp(bop));
				genExpression(e1);
				genExpression(e2);
			case TThrow(e):
				writeOpLine(IaThrow);
				genExpression(e);
			case TArrayDecl(exprList):
				write(op(IaADef) + typeText(expression.type) + " " + exprList.length + "\n");
				for (e in exprList) genExpression(e);
			case TIf(e, e1, null):
				writeOpLine(IaIf);
				genExpression(e);
				genExpression(e1);
			case TIf(e, e1, elze):
				writeOpLine(IaIfElse);
				genExpression(e);
				genExpression(e1);
				genExpression(elze);
			case TCall(func, argList):
				genCall(expression, func, argList);
			case TField(obj, acc):
				var objDynamic = CppiaGen.isDynamicInCppia(com, obj);
				var objType = objDynamic ? "Dynamic" : CppiaGen.scriptTypeString(obj.type);
				var fieldTypeText = objDynamic ? typeTextString("Dynamic") : typeText(obj.type);
				switch (acc) {
					case FDynamic(name):
						write(op(IaFName) + fieldTypeText + " " + stringText(name) + commentOf(name) + "\n");
						genExpression(obj);
					case FStatic(classDef, field):
						write(op(IaFStatic) + instText(classDef) + " " + stringText(field.name) + commentOf(field.name));
					case FInstance(_, _, field) if (CppiaGen.isThis(obj)):
						write(op(IaFThisInst) + fieldTypeText + " " + stringText(field.name) + commentOf(field.name));
					case FInstance(_, _, field):
						write(op(IaFLink) + fieldTypeText + " " + stringText(field.name) + commentOf(objType + "." + field.name) + "\n");
						genExpression(obj);
					case FClosure(_, field) if (CppiaGen.isThis(obj)):
						write(op(IaFThisName) + fieldTypeText + " " + stringText(field.name) + "\n");
					case FAnon(field) if (CppiaGen.isThis(obj)):
						write(op(IaFThisName) + fieldTypeText + " " + stringText(field.name) + commentOf(field.name) + "\n");
					case FClosure(_, field) | FAnon(field):
						write(op(IaFName) + fieldTypeText + " " + stringText(field.name) + commentOf(field.name) + "\n");
						genExpression(obj);
					case FEnum(en, field):
						write(op(IaFEnum) + enumText(en) + " " + stringText(field.name) + commentOf(field.name));
				}
			case TArray(e1, e2):
				write(op(IaArrayI) + typeText(e1.type) + "\n");
				genExpression(e1);
				genExpression(e2);
			case TUnop(uop, flag, e):
				writeOpLine(switch [uop, flag] {
					case [Increment, Prefix]: IaPlusPlus;
					case [Increment, _]: IaPlusPlusPost;
					case [Decrement, Prefix]: IaMinusMinus;
					case [Decrement, _]: IaMinusMinusPost;
					case [Not, _]: IaLogicNot;
					case [Neg, _]: IaNeg;
					case [Spread, _]: throw new TypingError("Unexpected spread operator", e.pos);
					case [NegBits, _]: IaBitNot;
				});
				genExpression(e);
			case TLocal(v):
				write(op(IaVar) + v.id + commentOf(v.name));
			case TVarExpr(tvar, optionalInit):
				write(op(IaTVars) + "1" + commentOf(tvar.name + ":" + CppiaGen.scriptTypeString(tvar.type)) + "\n");
				write("\t\t" + indent);
				switch (optionalInit) {
					case null:
						writeOp(IaVarDecl);
						writeVar(tvar);
					case init:
						writeOp(IaVarDeclI);
						var init = CppiaGen.removeParens(init);
						writeVar(tvar);
						write(" " + typeText(init.type));
						write("\n");
						checkCast(tvar.type, init, false, false);
				}
			case TNew(clazz, params, argList):
				write(op(IaNew) + typeText(TInst(clazz, params)) + argList.length + "\n");
				var resolved = CppRetype.resolveConstructorOverload(clazz, params, argList);
				var protoArgs = resolved == null ? null : switch (resolved.type) {
					case TFun(sig) if (sig.args.length == argList.length): sig.args;
					case _: null;
				}
				if (protoArgs != null) {
					for (i in 0...argList.length) checkCast(protoArgs[i].t, argList[i], false, false);
				} else {
					for (a in argList) genExpression(a);
				}
			case TReturn(null):
				writeOpLine(IaReturn);
			case TReturn(value):
				write(op(IaRetVal) + typeText(value.type) + "\n");
				checkCast(returnType, value, false, false);
			case TObjectDecl([
				{key: {name: "fileName"}, expr: {expr: TConst(TString(file))}},
				{key: {name: "lineNumber"}, expr: {expr: TConst(TInt(line))}},
				{key: {name: "className"}, expr: {expr: TConst(TString(className))}},
				{key: {name: "methodName"}, expr: {expr: TConst(TString(meth))}}
			]):
				write(op(IaPosInfo) + stringText(file) + line + " " + stringText(className) + " " + stringText(meth));
			case TObjectDecl(values):
				write(op(IaObjDef) + values.length);
				write(" ");
				for (v in values) write(stringText(v.key.name));
				write("\n");
				for (v in values) genExpression(v.expr);
			case TTypeExpr(typeExpr):
				var klass = "::" + CppTypeOf.joinClassPath(CppTypeOf.tPath(typeExpr), "::");
				write(op(IaClassOf) + typeId(klass));
			case TWhile(e1, e2, flag):
				write(op(IaWhile) + (flag == NormalWhile ? "1" : "0") + "\n");
				genExpression(e1);
				genExpression(e2);
			case TFor(tvar, init, loop):
				writeOp(IaFor);
				writeVar(tvar);
				write("\n");
				genExpression(init);
				genExpression(loop);
			case TEnumParameter(e, ef, i):
				var en = switch (TypeFunctions.follow(ef.type)) {
					case TEnum(en, _): en;
					case TFun({ret: TEnum(en, _)}): en;
					case _: throw new TypingError("Bad enum parameter", expression.pos);
				}
				write(op(IaEnumI) + typeText(TEnum(en, [])) + i + "\n");
				genExpression(e);
			case TEnumIndex(e):
				write(op(IaCallMember) + typeTextString("::hx::EnumBase") + " " + stringText("__Index") + "0" + commentOf("Enum index") + "\n");
				genExpression(e);
			case TSwitch(condition, cases, optionalDefault):
				write(op(IaSwitch) + cases.length + " " + (optionalDefault == null ? "0" : "1") + "\n");
				genExpression(condition);
				for (c in cases) {
					writeList("\t\t\t" + indent, c.values.length);
					for (value in c.values) genExpression(value);
					genExpression(c.expr);
				}
				if (optionalDefault != null) genExpression(optionalDefault);
			case TTry(e, catches):
				writeList(op(IaTry), catches.length);
				genExpression(e);
				for (c in catches) {
					write("\t\t\t" + indent);
					writeVar(c.v);
					write("\n");
					genExpression(c.expr);
				}
			case TCast(castExpr, TClassDecl(t)):
				write(op(IaTCast) + typeText(TInst(t, [])) + "\n");
				genExpression(castExpr);
			case TCast(castExpr, _):
				checkCast(expression.type, castExpr, true, true);
			case TParenthesis(_):
				throw new TypingError("Unexpected parens", expression.pos);
			case TMeta(_, _):
				throw new TypingError("Unexpected meta", expression.pos);
			case TIdent(_):
				throw new TypingError("Unexpected ident", expression.pos);
		}
	}

	// The TCall arm of the typed-AST walker
	function genCall(expression:TExpr, func:TExpr, argList:Array<TExpr>):Void {
		var argN = argList.length + " ";
		function genTheCall():Void {
			switch (CppiaGen.removeParensCast(func).expr) {
				case TField({expr: TIdent("__global__")}, field):
					write(op(IaCallGlobal) + stringText(TypeFunctions.fieldName(field)) + argN + commentOf(TypeFunctions.fieldName(field)) + "\n");
				case TField(_, FStatic(classDef, field)) if (CppiaGen.isRealFunction(field)):
					write(op(IaCallStatic) + instText(classDef) + " " + stringText(field.name)
						+ argN + commentOf(CppTypeOf.joinClassPath(classDef.path, ".") + "." + field.name) + "\n");
				case TField(obj, FInstance(_, _, field)) if (CppiaGen.isThis(obj) && CppiaGen.isRealFunction(field)):
					write(op(IaCallThis) + typeText(obj.type) + " " + stringText(field.name) + argN + commentOf(field.name) + "\n");
				case TField(obj, FInstance(_, _, field)) if (CppiaGen.isSuper(obj)):
					write(op(IaCallSuper) + typeText(obj.type) + " " + stringText(field.name) + argN + commentOf(field.name) + "\n");
				// No GetEnumIndex opcode: emit IaCallMember ::hx::EnumBase.__Index
				case TField(obj, FInstance(_, _, field)) if (field.name == "_hx_getIndex" && CppiaGen.scriptTypeString(obj.type) == "::hx::EnumBase"):
					write(op(IaCallMember) + typeTextString("::hx::EnumBase") + " " + stringText("__Index") + argN + commentOf("Enum index") + "\n");
					genExpression(obj);
				case TField(obj, FInstance(_, _, field)) if (field.name == "__Index"
						|| (!CppiaGen.isDynamicInCppia(com, obj) && CppiaGen.isRealFunction(field))):
					write(op(IaCallMember) + typeText(obj.type) + " " + stringText(field.name) + argN + commentOf(field.name) + "\n");
					genExpression(obj);
				case TField(obj, FDynamic(name)) if (CppTypeText.isInternalMember(name)
						|| (CppiaGen.typeString(obj.type) == "::String" && name == "cca")):
					write(op(IaCallMember) + typeText(obj.type) + " " + stringText(name) + argN + commentOf(name) + "\n");
					genExpression(obj);
				case TConst(TSuper):
					write(op(IaCallSuperNew) + typeText(func.type) + " " + argN + "\n");
				case TField(_, FEnum(en, field)):
					write(op(IaCreateEnum) + enumText(en) + " " + stringText(field.name) + argN + commentOf(field.name) + "\n");
				case _:
					write(op(IaCall) + argN + "\n");
					genExpression(func);
			}
			var matchedArgs = switch (func.type) {
				case TFun(sig) if (sig.args.length == argList.length):
					for (i in 0...argList.length) checkCast(sig.args[i].t, argList[i], false, false);
					true;
				case _: false;
			}
			if (!matchedArgs)
				for (a in argList) genExpression(a);
		}
		switch (CppiaGen.removeParensCast(func).expr) {
			case TField(obj, field) if (CppiaGen.isArrayOrDynArray(obj.type) && TypeFunctions.fieldName(field) == "map"):
				switch (getArrayType(expression.type)) {
					case ArrayData(t):
						write(op(IaToDataArray) + typeTextString("Array." + t) + "\n");
						beginExpr();
						writePos(func);
						genTheCall();
						endExpr();
					case ArrayInterface(t):
						write(op(IaToInterfaceArray) + t + "\n");
						beginExpr();
						writePos(func);
						genTheCall();
						endExpr();
					case _:
						genTheCall();
				}
			case _:
				genTheCall();
		}
	}

	// The retype-IR walker
	public function genExpressionTree(expressionTree:CppExpr):Void {
		genTreeExpr(expressionTree);
	}

	function genTreeExpr(expression:CppExpr):Void {
		beginExpr();
		writeCppPos(expression);
		matchTreeExpr(expression);
		endExpr();
	}

	function matchTreeExpr(expression:CppExpr):Void {
		switch (expression.expr) {
			case CppBlock(exprs, _, _):
				writeList(op(IaBlock), exprs.length);
				for (e in exprs) genTreeExpr(e);
			case CppVarDecl(v, init):
				var name = CppTypeText.cppVarNameOf(v);
				write(op(IaTVars) + "1" + commentOf(name + ":" + CppiaGen.scriptTypeString(v.type)) + "\n");
				write("\t\t" + indent);
				switch (init) {
					case null:
						writeOp(IaVarDecl);
						writeVar(v);
					case init:
						writeOp(IaVarDeclI);
						writeVar(v);
						write(" " + astType(init.ctype));
						write("\n");
						genTreeExpr(init);
				}
			case CppInt(i):
				write(op(IaConstInt) + i + " ");
			case CppFloat(floatAsString):
				write(op(IaConstFloat) + stringText(floatAsString));
			case CppString(s):
				write(op(IaConstString) + stringText(s));
			case CppBool(false):
				writeOp(IaConstFalse);
			case CppBool(true):
				writeOp(IaConstTrue);
			case CppNull:
				writeOp(IaConstNull);
			case CppNil:
				throw new TypingError("Nil not supported in cppia", expression.pos);
			case CppThis(_):
				writeOp(IaConsThis);
			case CppSuper(_):
				writeOp(IaConstSuper);
			case CppBreak:
				writeOp(IaBreak);
			case CppContinue:
				writeOp(IaContinue);
			case CppGoto(_):
				throw new TypingError("Goto not supported in cppia", expression.pos);
			case CppReturn(null):
				writeOpLine(IaReturn);
			case CppReturn(value):
				write(op(IaRetVal) + astType(value.ctype) + "\n");
				genTreeExpr(value);
			case CppWhile(condition, block, whileFlag, _):
				write(op(IaWhile) + (whileFlag == NormalWhile ? "1" : "0") + "\n");
				genTreeExpr(condition);
				genTreeExpr(block);
			case CppIf(condition, block, null):
				writeOpLine(IaIf);
				genTreeExpr(condition);
				genTreeExpr(block);
			case CppIf(condition, block, elze):
				writeOpLine(IaIfElse);
				genTreeExpr(condition);
				genTreeExpr(block);
				genTreeExpr(elze);
			case CppBinop(bop, left, right):
				writeOpLine(IaBinOp(bop));
				genTreeExpr(left);
				genTreeExpr(right);
			case CppVar(loc):
				genVarLoc(loc);
			case CppExtern(name, _):
				throw new TypingError("Unexpected global '" + name + "' in cppia", expression.pos);
			case CppSet(lvalue, rvalue):
				writeOpLine(IaSet);
				genLvalue(lvalue, expression.pos);
				genTreeExpr(rvalue);
			case CppCall(funcLoc, args):
				var argN = args.length + " ";
				switch (funcLoc) {
					case FuncThis(field, inst):
						var name = field.name;
						write(op(IaCallThis) + astType(inst) + " " + stringText(name) + argN + commentOf(name) + "\n");
					case FuncInstance(e, _, field) | FuncInterface(e, _, field):
						write(op(IaCallMember) + astType(e.ctype) + " " + stringText(field.name) + argN + commentOf(field.name) + "\n");
						genTreeExpr(e);
					case FuncStatic(classDef, _, field):
						write(op(IaCallStatic) + cppInstText(classDef) + " " + stringText(field.name)
							+ argN + commentOf(CppTypeOf.joinClassPath(classDef.path, ".") + "." + field.name) + "\n");
					case FuncTemplate(_, _, _, _):
						throw new TypingError("Templated function call not supported in cppia", expression.pos);
					case FuncFromStaticFunction:
						throw new TypingError("Unexpected FuncFromStaticFunction", expression.pos);
					case FuncEnumConstruct(en, field):
						write(op(IaCreateEnum) + enumText(en) + " " + stringText(field.name) + argN + commentOf(field.name) + "\n");
					case FuncSuperConstruct(TCppInst(klass, _)) if (CppTypeOf.isNativeGenClass(klass) && CppTypeOf.isNativeClass(klass)):
						throw new TypingError("Unsupported super for native class constructor", expression.pos);
					case FuncSuperConstruct(childType):
						write(op(IaCallSuperNew) + astType(childType) + " " + argN + "\n");
					case FuncSuper(_, TCppInst(klass, _), _) if (CppTypeOf.isNativeGenClass(klass) && CppTypeOf.isNativeClass(klass)):
						throw new TypingError("Unsupported super for native class method", expression.pos);
					case FuncSuper(_, objType, field):
						write(op(IaCallSuper) + astType(objType) + " " + stringText(field.name) + argN + commentOf(field.name) + "\n");
					case FuncExtern(name, _):
						write(op(IaCallGlobal) + stringText(name) + argN + commentOf(name) + "\n");
					case FuncNew(newType):
						write(op(IaNew) + astType(newType) + argN + "\n");
					case FuncInternal(obj, "cca", ".") if (obj.ctype.match(TCppString)):
						write(op(IaCallMember) + astType(obj.ctype) + " " + stringText("cca") + argN + commentOf("cca") + "\n");
						genTreeExpr(obj);
					case FuncInternal(obj, name, _):
						write(op(IaCallMember) + astType(obj.ctype) + " " + stringText(name) + argN + commentOf(name) + "\n");
						genTreeExpr(obj);
					case FuncExpression(e):
						write(op(IaCall) + argN + "\n");
						genTreeExpr(e);
				}
				for (a in args) genTreeExpr(a);
			case CppFunction(funcLoc, _):
				switch (funcLoc) {
					case FuncThis(field, inst):
						write(op(IaFThisName) + astType(inst) + " " + stringText(field.name)
							+ commentOf(CppiaGen.scriptCppTypeString(inst) + "." + field.name));
					case FuncInternal(e, name, _):
						write(op(IaFLink) + astType(e.ctype) + " " + stringText(name)
							+ commentOf("Internal " + CppiaGen.scriptCppTypeString(e.ctype) + "." + name) + "\n");
						genTreeExpr(e);
					case FuncInstance(e, _, field) | FuncInterface(e, _, field):
						write(op(IaFName) + astType(e.ctype) + " " + stringText(field.name)
							+ commentOf(CppiaGen.scriptCppTypeString(e.ctype) + "." + field.name) + "\n");
						genTreeExpr(e);
					case FuncStatic(classDef, _, field):
						write(op(IaFStatic) + cppInstText(classDef) + " " + stringText(field.name) + commentOf(field.name));
					case FuncExpression(e):
						matchTreeExpr(e);
					case FuncExtern(name, _):
						throw new TypingError("Can't create extern " + name + " closure", expression.pos);
					case FuncSuper(_, _, _) | FuncSuperConstruct(_):
						throw new TypingError("Can't create super closure", expression.pos);
					case FuncNew(_):
						throw new TypingError("Can't create new closure", expression.pos);
					case FuncEnumConstruct(_, _):
						throw new TypingError("Enum constructor outside of CppCall", expression.pos);
					case FuncFromStaticFunction:
						throw new TypingError("Can't create cpp.Function.fromStaticFunction closure", expression.pos);
					case FuncTemplate(_, _, _, _):
						throw new TypingError("Can't create template function closure", expression.pos);
				}
			case CppPosition(file, line, className, meth):
				write(op(IaPosInfo) + stringText(file) + line + " " + stringText(className) + " " + stringText(meth));
			case CppNullCompare("IsNull", e):
				writeOpLine(IaIsNull);
				genTreeExpr(e);
			case CppNullCompare(_, e):
				writeOpLine(IaNotNull);
				genTreeExpr(e);
			case CppCompare(_, left, right, bop):
				writeOpLine(IaBinOp(bop));
				genTreeExpr(left);
				genTreeExpr(right);
			case CppArray(arrayLoc):
				genArray(arrayLoc, expression.pos);
			case CppArrayDecl(exprList):
				write(op(IaADef) + astType(expression.ctype) + " " + exprList.length + "\n");
				for (e in exprList) genTreeExpr(e);
			case CppEnumField(en, field):
				write(op(IaFEnum) + enumText(en) + " " + stringText(field.name) + commentOf(field.name));
			case CppEnumIndex(obj):
				// No GetEnumIndex opcode: emit IaCallMember ::hx::EnumBase.__Index
				write(op(IaCallMember) + typeTextString("::hx::EnumBase") + " " + stringText("__Index") + "0" + commentOf("Enum index") + "\n");
				genTreeExpr(obj);
			case CppDynamicField(obj, name):
				write(op(IaFName) + typeTextString("Dynamic") + " " + stringText(name) + commentOf(name) + "\n");
				genTreeExpr(obj);
			case CppClassOf(path, _):
				var klass = CppTypeOf.joinClassPath(path, ".");
				write(op(IaClassOf) + typeTextString(klass) + commentOf(klass));
			case CppEnumParameter(obj, _, index):
				write(op(IaEnumI) + typeTextString("Dynamic") + index + "\n");
				genTreeExpr(obj);
			case CppClosure(closure):
				write(op(IaFun) + astType(closure.closeType) + closure.closeArgs.length + "\n");
				var close = genFuncArgs([for (a in closure.closeArgs) {v: a.v, init: a.dflt}]);
				genTreeExpr(closure.closeExpr);
				close();
			case CppObjectDecl(values, _):
				write(op(IaObjDef) + values.length);
				write(" ");
				for (v in values) write(stringText(v.name));
				write("\n");
				for (v in values) genTreeExpr(v.expr);
			case CppCrement(incFlag, preFlag, lvalue):
				var crementOp = switch [incFlag, preFlag] {
					case [CppIncrement, Prefix]: IaPlusPlus;
					case [CppIncrement, Postfix]: IaPlusPlusPost;
					case [CppDecrement, Prefix]: IaMinusMinus;
					case [CppDecrement, Postfix]: IaMinusMinusPost;
				}
				writeOpLine(crementOp);
				genLvalue(lvalue, expression.pos);
			case CppModify(bop, lvalue, rvalue):
				writeOpLine(IaBinOp(OpAssignOp(bop)));
				genLvalue(lvalue, expression.pos);
				genTreeExpr(rvalue);
			case CppUnop(uop, e):
				writeOpLine(switch (uop) {
					case CppNot: IaLogicNot;
					case CppNeg: IaNeg;
					case CppNegBits: IaBitNot;
				});
				genTreeExpr(e);
			case CppThrow(value):
				writeOpLine(IaThrow);
				genTreeExpr(value);
			case CppTry(block, catches):
				writeList(op(IaTry), catches.length);
				genTreeExpr(block);
				for (c in catches) {
					write("\t\t\t" + indent);
					writeVar(c.v);
					write("\n");
					genTreeExpr(c.body);
				}
			case CppIntSwitch(_, _, _):
				throw new TypingError("CppIntSwitch not supported in cppia", expression.pos);
			case CppSwitch(condition, _, cases, optionalDefault, _):
				write(op(IaSwitch) + cases.length + " " + (optionalDefault == null ? "0" : "1") + "\n");
				genTreeExpr(condition);
				for (c in cases) {
					writeList("\t\t\t" + indent, c.values.length);
					for (value in c.values) genTreeExpr(value);
					genTreeExpr(c.body);
				}
				if (optionalDefault != null) genTreeExpr(optionalDefault);
			case CppTCast(e, toType):
				write(op(IaTCast) + astType(toType) + "\n");
				genTreeExpr(e);
			case CppCast(e, toType):
				switch (toType) {
					case TCppDynamicArray:
						write(op(IaToDynArray) + "\n");
						genTreeExpr(e);
					case TCppObjectArray(_):
						write(op(IaToDataArray) + typeTextString("Array.Object") + "\n");
						genTreeExpr(e);
					case TCppScalarArray(t):
						write(op(IaToDataArray) + typeTextString("Array." + CppiaGen.scriptCppTypeString(t)) + "\n");
						genTreeExpr(e);
					case _:
						matchTreeExpr(e);
				}
			case CppCastScalar(e, "bool"):
				writeOpLine(IaCastBool);
				genTreeExpr(e);
			case CppCastScalar(e, "int"):
				writeOpLine(IaCastInt);
				genTreeExpr(e);
			case CppCastScalar(e, "Float"):
				write(op(IaTCast) + astType(TCppScalar("Float")) + "\n");
				genTreeExpr(e);
			case CppCastScalar(e, _):
				matchTreeExpr(e);
			case CppCastVariant(e):
				matchTreeExpr(e);
			case CppCastStatic(e, _):
				matchTreeExpr(e);
			case CppNullAccess:
				writeOpLine(IaThrow);
				beginExpr();
				writeCppPos(expression);
				write(op(IaConstString) + stringText("Null access"));
				endExpr();
			case CppCode(_, _) | CppFunctionAddress(_, _) | CppNewNative(_) | CppDereference(_) | CppAddressOf(_)
				| CppFor(_, _, _) | CppCastObjC(_, _) | CppCastObjCBlock(_, _, _) | CppCastProtocol(_, _) | CppCastNative(_):
				throw new TypingError("Unsupported operation in cppia", expression.pos);
		}
	}

	function genArray(arrayLoc:CppArrayLoc, pos:Position):Void {
		switch (arrayLoc) {
			case ArrayObject(arrayObj, index, _) | ArrayTyped(arrayObj, index, _):
				write(op(IaArrayI) + astType(arrayObj.ctype) + "\n");
				genTreeExpr(arrayObj);
				genTreeExpr(index);
			case ArrayPointer(_, _) | ArrayRawPointer(_, _):
				throw new TypingError("Unvalid array access in cppia", pos);
			case ArrayVirtual(arrayObj, index) | ArrayImplements(_, arrayObj, index) | ArrayDynamic(arrayObj, index):
				write(op(IaArrayI) + astType(arrayObj.ctype) + "\n");
				genTreeExpr(arrayObj);
				genTreeExpr(index);
		}
	}

	function genLvalue(lvalue:CppLValue, pos:Position):Void {
		beginExpr();
		wpos(pos);
		switch (lvalue) {
			case CppVarRef(varLoc):
				genVarLoc(varLoc);
			case CppArrayRef(arrayLoc):
				genArray(arrayLoc, pos);
			case CppExternRef(name, _):
				throw new TypingError("Unsupported extern '" + name + "' in cppia", pos);
			case CppDynamicRef(e, name):
				write(op(IaFName) + typeTextString("Dynamic") + " " + stringText(name) + commentOf(name) + "\n");
				genTreeExpr(e);
		}
		endExpr();
	}

	function genVarLoc(loc:CppVarLoc):Void {
		switch (loc) {
			case VarClosure(v) | VarLocal(v):
				write(op(IaVar) + v.id + commentOf(v.name));
			case VarStatic(classDef, _, field):
				write(op(IaFStatic) + cppInstText(classDef) + " " + stringText(field.name) + commentOf(field.name));
			case VarThis(field, thisType):
				write(op(IaFThisInst) + astType(thisType) + " " + stringText(field.name) + commentOf(field.name));
			case VarInstance(obj, field, _, _) | VarInterface(obj, field):
				var objType = CppiaGen.scriptCppTypeString(obj.ctype);
				write(op(IaFLink) + astType(obj.ctype) + " " + stringText(field.name) + commentOf(objType + "." + field.name) + "\n");
				genTreeExpr(obj);
			case VarInternal(obj, _, name):
				var objType = CppiaGen.scriptCppTypeString(obj.ctype);
				write(op(IaFLink) + astType(obj.ctype) + " " + stringText(name) + commentOf(objType + "." + name) + "\n");
				genTreeExpr(obj);
		}
	}
}

enum CppiaArrayOf {
	ArrayInterface(id:Int);
	ArrayData(s:String);
	ArrayObject;
	ArrayAny;
	ArrayNone;
}
