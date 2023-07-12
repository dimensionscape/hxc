package hxc.eval;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.context.Context;
import hxc.typing.TyperContext;
import hxc.typing.Typer;
import hxc.typing.AccessKind.FieldAccess;
import hxc.eval.EvalValue;
import hxc.eval.EvalContext;
import hxc.eval.EvalHash;

// Runs macro functions at compile time: the typer hands a macro call here, the arguments are
// encoded into haxe.macro.Expr values, the function runs in a macro-mode interpreter, and the
// returned Expr value is decoded back to an AST and typed in place.
class EvalMacro {
	static var macroCtx:Null<EvalContext> = null;
	static var lastModuleCount:Int = -1;
	static var curPos:Position = Position.nullPos;

	static function regBuiltin(ec:EvalContext, typeName:String, fieldName:String, f:VFunc):Void {
		var key = EvalHash.hash(typeName);
		var list = ec.builtins.staticBuiltins.get(key);
		if (list == null) { list = []; ec.builtins.staticBuiltins.set(key, list); }
		list.push({name: EvalHash.hash(fieldName), v: VFunction(f, true)});
	}

	static function registerContext(ec:EvalContext, com:Context):Void {
		regBuiltin(ec, "haxe.macro.Context", "defined", function(a) return com.defines.rawDefined(strOf(a[0])) ? VTrue : VFalse);
		regBuiltin(ec, "haxe.macro.Context", "currentPos", function(a) return VNull);
		regBuiltin(ec, "haxe.macro.Context", "error", function(a) { throw new TypingError(strOf(a[0]), curPos); });
		regBuiltin(ec, "haxe.macro.Context", "fatalError", function(a) { throw new TypingError(strOf(a[0]), curPos); });
		regBuiltin(ec, "haxe.macro.Context", "warning", function(a) { Sys.println("Warning: " + strOf(a[0])); return VNull; });
		regBuiltin(ec, "haxe.macro.Context", "makeExpr", function(a) return makeExprValue(ec, a[0]));
	}

	static function makeExprValue(ec:EvalContext, v:EvalValue):EvalValue {
		var ed = switch (v) {
			case VInt(i): mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CInt", [mkString(Std.string(i)), VNull])]);
			case VFloat(f): mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CFloat", [mkString(Std.string(f)), VNull])]);
			case VString(s): mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CString", [mkString(s.sstring), VNull])]);
			case VTrue: mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CIdent", [mkString("true")])]);
			case VFalse: mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CIdent", [mkString("false")])]);
			case VNull: mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CIdent", [mkString("null")])]);
			case _: throw new TypingError("Context.makeExpr: unsupported value", curPos);
		};
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("expr"), ed);
		fields.set(EvalHash.hash("pos"), VNull);
		return VObject(new VObject([], ODictionary(fields)));
	}

	public static function isMacroField(cf:TClassField):Bool {
		return switch (cf.kind) { case Method(MethMacro): true; case _: false; };
	}

	static function getContext(com:Context):EvalContext {
		if (macroCtx == null || lastModuleCount != com.modules.length) {
			// Type any modules loaded on demand, then build the interpreter over all of them.
			hxc.typing.TypeFields.typeAllModules(com);
			var ec = EvalMain.create(true);
			registerContext(ec, com);
			EvalMain.addModules(ec, com.modules);
			macroCtx = ec;
			lastModuleCount = com.modules.length;
		}
		EvalContext.setCtx(macroCtx);
		return macroCtx;
	}

	public static function run(tctx:TyperContext, fa:FieldAccess, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		curPos = p;
		var ec = getContext(tctx.com);
		var path = switch (fa.host) {
			case FHStatic(c): c.path;
			case _: throw new TypingError("Only static macro functions are supported", p);
		};
		var proto = ec.staticPrototypes.get(EvalHash.pathHash(path));
		if (proto == null) throw new TypingError("Macro type not loaded: " + path.name, p);
		var idx = proto.pnames.get(EvalHash.hash(fa.field.name));
		if (idx == null) throw new TypingError("Macro not found: " + fa.field.name, p);
		var fn = switch (proto.pfields[idx]) {
			case VFunction(f, _): f;
			case _: throw new TypingError("Not a macro function: " + fa.field.name, p);
		};
		var args = [for (e in el) encodeExpr(ec, e)];
		var result = fn(args);
		var astExpr = decodeExpr(ec, result, p);
		return Typer.typeExpr(tctx, astExpr, withType);
	}


	static function ctorName(ec:EvalContext, v:EvalValue):String {
		return switch (v) {
			case VEnumValue(ev): switch (ec.typeCache.get(ev.epath)) {
				case TEnumDecl(en): en.names[ev.eindex];
				case _: throw "macro decode: not an enum value";
			};
			case _: throw "macro decode: expected enum value";
		};
	}

	static function eargs(v:EvalValue):Array<EvalValue> {
		return switch (v) { case VEnumValue(ev): ev.eargs; case _: throw "macro decode: expected enum value"; };
	}

	static function strOf(v:EvalValue):String {
		return switch (v) { case VString(s): s.sstring; case VNativeString(s): s; case _: throw "macro decode: expected string"; };
	}

	static function strOpt(v:EvalValue):Null<String> {
		return switch (v) { case VNull: null; case _: strOf(v); };
	}

	static function boolOf(v:EvalValue):Bool {
		return switch (v) { case VTrue: true; case _: false; };
	}

	static function arrOf(v:EvalValue):Array<EvalValue> {
		return switch (v) { case VArray(a): a.avalues.slice(0, a.alength); case VNull: []; case _: throw "macro decode: expected array"; };
	}

	static function decodeExpr(ec:EvalContext, v:EvalValue, dp:Position):Expr {
		if (v == VNull) return new Expr(EConst(CIdent("null")), dp);
		var ed = decodeExprDef(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp);
		return new Expr(ed, dp);
	}

	static function decodeExprOpt(ec:EvalContext, v:EvalValue, dp:Position):Null<Expr> {
		return v == VNull ? null : decodeExpr(ec, v, dp);
	}

	static function decodeExprDef(ec:EvalContext, v:EvalValue, dp:Position):ExprDef {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "EConst": EConst(decodeConstant(ec, a[0]));
			case "EArray": EArray(decodeExpr(ec, a[0], dp), decodeExpr(ec, a[1], dp));
			case "EBinop": EBinop(decodeBinop(ec, a[0]), decodeExpr(ec, a[1], dp), decodeExpr(ec, a[2], dp));
			case "EField": EField(decodeExpr(ec, a[0], dp), strOf(a[1]), EFNormal);
			case "EParenthesis": EParenthesis(decodeExpr(ec, a[0], dp));
			case "EObjectDecl": EObjectDecl([for (f in arrOf(a[0])) decodeObjField(ec, f, dp)]);
			case "EArrayDecl": EArrayDecl([for (e in arrOf(a[0])) decodeExpr(ec, e, dp)]);
			case "ECall": ECall(decodeExpr(ec, a[0], dp), [for (e in arrOf(a[1])) decodeExpr(ec, e, dp)]);
			case "EUnop": EUnop(decodeUnop(ec, a[0]), boolOf(a[1]) ? Postfix : Prefix, decodeExpr(ec, a[2], dp));
			case "EIf": EIf(decodeExpr(ec, a[0], dp), decodeExpr(ec, a[1], dp), decodeExprOpt(ec, a[2], dp));
			case "EReturn": EReturn(decodeExprOpt(ec, a[0], dp));
			case "EBlock": EBlock([for (e in arrOf(a[0])) decodeExpr(ec, e, dp)]);
			case "EVars": EVars([for (vv in arrOf(a[0])) decodeVar(ec, vv, dp)]);
			case "EThrow": EThrow(decodeExpr(ec, a[0], dp));
			case "EMeta": decodeExpr(ec, a[1], dp).expr;
			case other: throw new TypingError("Macro decode: unhandled ExprDef " + other, dp);
		};
	}

	static function decodeObjField(ec:EvalContext, v:EvalValue, dp:Position):ObjectField {
		return {name: strOf(EvalField.field(ec, v, EvalHash.hash("field"))), pos: dp, quotes: NoQuotes, expr: decodeExpr(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp)};
	}

	static function decodeVar(ec:EvalContext, v:EvalValue, dp:Position):EVar {
		return {
			evName: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))), pos: dp},
			evFinal: boolOf(EvalField.field(ec, v, EvalHash.hash("isFinal"))),
			evStatic: false,
			evType: null,
			evExpr: decodeExprOpt(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp),
			evMeta: []
		};
	}

	static function decodeConstant(ec:EvalContext, v:EvalValue):Constant {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "CInt": CInt(strOf(a[0]), a.length > 1 ? strOpt(a[1]) : null);
			case "CFloat": CFloat(strOf(a[0]), a.length > 1 ? strOpt(a[1]) : null);
			case "CString": CString(strOf(a[0]), SDoubleQuotes);
			case "CIdent": CIdent(strOf(a[0]));
			case "CRegexp": CRegexp(strOf(a[0]), strOf(a[1]));
			case other: throw "macro decode: unhandled Constant " + other;
		};
	}

	static function decodeBinop(ec:EvalContext, v:EvalValue):Binop {
		return switch (ctorName(ec, v)) {
			case "OpAdd": OpAdd; case "OpMult": OpMult; case "OpDiv": OpDiv; case "OpSub": OpSub; case "OpMod": OpMod;
			case "OpEq": OpEq; case "OpNotEq": OpNotEq; case "OpLt": OpLt; case "OpLte": OpLte; case "OpGt": OpGt; case "OpGte": OpGte;
			case "OpAnd": OpAnd; case "OpOr": OpOr; case "OpXor": OpXor; case "OpBoolAnd": OpBoolAnd; case "OpBoolOr": OpBoolOr;
			case "OpShl": OpShl; case "OpShr": OpShr; case "OpUShr": OpUShr;
			case "OpAssign": OpAssign; case "OpInterval": OpInterval; case "OpArrow": OpArrow; case "OpIn": OpIn;
			case "OpAssignOp": OpAssignOp(decodeBinop(ec, eargs(v)[0]));
			case other: throw "macro decode: unhandled Binop " + other;
		};
	}

	static function decodeUnop(ec:EvalContext, v:EvalValue):Unop {
		return switch (ctorName(ec, v)) {
			case "OpIncrement": Increment; case "OpDecrement": Decrement;
			case "OpNot": Not; case "OpNeg": Neg; case "OpNegBits": NegBits;
			case other: throw "macro decode: unhandled Unop " + other;
		};
	}


	static var enumCache:Map<String, TEnum> = new Map();

	static function findEnum(ec:EvalContext, name:String):TEnum {
		var cached = enumCache.get(name);
		if (cached != null) return cached;
		for (mt in ec.typeCache) switch (mt) {
			case TEnumDecl(en) if (en.path.name == name && en.path.pack.length == 2 && en.path.pack[0] == "haxe" && en.path.pack[1] == "macro"):
				enumCache.set(name, en);
				return en;
			case _:
		}
		throw "macro encode: enum not loaded: " + name;
	}

	static function mkEnumValue(ec:EvalContext, enumName:String, ctor:String, args:Array<EvalValue>):EvalValue {
		var en = findEnum(ec, enumName);
		var ef = en.constrs.get(ctor);
		if (ef == null) throw "macro encode: no constructor " + ctor + " in " + enumName;
		return VEnumValue(new VEnumValue(ef.index, args, EvalHash.pathHash(en.path), ef.namePos));
	}

	static function mkString(s:String):EvalValue {
		return s == null ? VNull : VString(new VString(s, s.length));
	}

	static function encodeExpr(ec:EvalContext, e:Expr):EvalValue {
		var ed = encodeExprDef(ec, e.expr);
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("expr"), ed);
		fields.set(EvalHash.hash("pos"), VNull);
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeExprDef(ec:EvalContext, ed:ExprDef):EvalValue {
		return switch (ed) {
			case EConst(c): mkEnumValue(ec, "ExprDef", "EConst", [encodeConstant(ec, c)]);
			case EArray(e1, e2): mkEnumValue(ec, "ExprDef", "EArray", [encodeExpr(ec, e1), encodeExpr(ec, e2)]);
			case EBinop(op, e1, e2): mkEnumValue(ec, "ExprDef", "EBinop", [encodeBinop(ec, op), encodeExpr(ec, e1), encodeExpr(ec, e2)]);
			case EField(e1, f, _): mkEnumValue(ec, "ExprDef", "EField", [encodeExpr(ec, e1), mkString(f)]);
			case EParenthesis(e1): mkEnumValue(ec, "ExprDef", "EParenthesis", [encodeExpr(ec, e1)]);
			case EArrayDecl(el): mkEnumValue(ec, "ExprDef", "EArrayDecl", [encodeArray([for (e in el) encodeExpr(ec, e)])]);
			case ECall(e1, el): mkEnumValue(ec, "ExprDef", "ECall", [encodeExpr(ec, e1), encodeArray([for (e in el) encodeExpr(ec, e)])]);
			case EUnop(op, flag, e1): mkEnumValue(ec, "ExprDef", "EUnop", [encodeUnop(ec, op), (switch (flag) { case Postfix: VTrue; case Prefix: VFalse; }), encodeExpr(ec, e1)]);
			case EIf(c, t, eo): mkEnumValue(ec, "ExprDef", "EIf", [encodeExpr(ec, c), encodeExpr(ec, t), eo == null ? VNull : encodeExpr(ec, eo)]);
			case EReturn(eo): mkEnumValue(ec, "ExprDef", "EReturn", [eo == null ? VNull : encodeExpr(ec, eo)]);
			case EBlock(el): mkEnumValue(ec, "ExprDef", "EBlock", [encodeArray([for (e in el) encodeExpr(ec, e)])]);
			case EVars(vl): mkEnumValue(ec, "ExprDef", "EVars", [encodeArray([for (v in vl) encodeVar(ec, v)])]);
			case EThrow(e1): mkEnumValue(ec, "ExprDef", "EThrow", [encodeExpr(ec, e1)]);
			case _: throw "macro encode: unhandled ExprDef";
		};
	}

	static function encodeVar(ec:EvalContext, ev:EVar):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(ev.evName.name));
		fields.set(EvalHash.hash("isFinal"), ev.evFinal ? VTrue : VFalse);
		fields.set(EvalHash.hash("expr"), ev.evExpr == null ? VNull : encodeExpr(ec, ev.evExpr));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeArray(items:Array<EvalValue>):EvalValue {
		return VArray(new VArray(items, items.length));
	}

	static function encodeConstant(ec:EvalContext, c:Constant):EvalValue {
		return switch (c) {
			case CInt(s, suf): mkEnumValue(ec, "Constant", "CInt", [mkString(s), mkString(suf)]);
			case CFloat(s, suf): mkEnumValue(ec, "Constant", "CFloat", [mkString(s), mkString(suf)]);
			case CString(s, _): mkEnumValue(ec, "Constant", "CString", [mkString(s), VNull]);
			case CIdent(s): mkEnumValue(ec, "Constant", "CIdent", [mkString(s)]);
			case CRegexp(r, o): mkEnumValue(ec, "Constant", "CRegexp", [mkString(r), mkString(o)]);
		};
	}

	static function encodeBinop(ec:EvalContext, op:Binop):EvalValue {
		var name = switch (op) {
			case OpAdd: "OpAdd"; case OpMult: "OpMult"; case OpDiv: "OpDiv"; case OpSub: "OpSub"; case OpMod: "OpMod";
			case OpEq: "OpEq"; case OpNotEq: "OpNotEq"; case OpLt: "OpLt"; case OpLte: "OpLte"; case OpGt: "OpGt"; case OpGte: "OpGte";
			case OpAnd: "OpAnd"; case OpOr: "OpOr"; case OpXor: "OpXor"; case OpBoolAnd: "OpBoolAnd"; case OpBoolOr: "OpBoolOr";
			case OpShl: "OpShl"; case OpShr: "OpShr"; case OpUShr: "OpUShr";
			case OpAssign: "OpAssign"; case OpInterval: "OpInterval"; case OpArrow: "OpArrow"; case OpIn: "OpIn"; case OpNullCoal: "OpNullCoal";
			case OpAssignOp(sub): return mkEnumValue(ec, "Binop", "OpAssignOp", [encodeBinop(ec, sub)]);
		};
		return mkEnumValue(ec, "Binop", name, []);
	}

	static function encodeUnop(ec:EvalContext, op:Unop):EvalValue {
		var name = switch (op) {
			case Increment: "OpIncrement"; case Decrement: "OpDecrement";
			case Not: "OpNot"; case Neg: "OpNeg"; case NegBits: "OpNegBits"; case Spread: "OpSpread";
		};
		return mkEnumValue(ec, "Unop", name, []);
	}
}
