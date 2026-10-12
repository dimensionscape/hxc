package hxc.ast;

import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.core.StringHelper;
import hxc.core.NotFound;
import hxc.core.ExitException;

enum Keyword {
	KwdFunction; KwdClass; KwdVar; KwdIf; KwdElse; KwdWhile; KwdDo; KwdFor;
	KwdBreak; KwdContinue; KwdReturn; KwdExtends; KwdImplements; KwdImport;
	KwdSwitch; KwdCase; KwdDefault; KwdStatic; KwdPublic; KwdPrivate; KwdTry;
	KwdCatch; KwdNew; KwdThis; KwdThrow; KwdExtern; KwdEnum; KwdIn; KwdInterface;
	KwdUntyped; KwdCast; KwdOverride; KwdTypedef; KwdDynamic; KwdPackage;
	KwdInline; KwdUsing; KwdNull; KwdTrue; KwdFalse; KwdAbstract; KwdMacro;
	KwdFinal; KwdOperator; KwdOverload;
}

enum Binop {
	OpAdd; OpMult; OpDiv; OpSub; OpAssign; OpEq; OpNotEq; OpGt; OpGte; OpLt;
	OpLte; OpAnd; OpOr; OpXor; OpBoolAnd; OpBoolOr; OpShl; OpShr; OpUShr; OpMod;
	OpAssignOp(op:Binop); OpInterval; OpArrow; OpIn; OpNullCoal;
}

enum Unop {
	Increment; Decrement; Not; Neg; NegBits; Spread;
}

enum StringLiteralKind {
	SDoubleQuotes; SSingleQuotes;
}

enum Constant {
	CInt(v:String, ?suffix:String);
	CFloat(v:String, ?suffix:String);
	CString(s:String, kind:StringLiteralKind);
	CIdent(s:String);
	CRegexp(r:String, opt:String);
}

enum Token {
	Eof;
	Const(c:Constant);
	Kwd(k:Keyword);
	Comment(s:String);
	CommentLine(s:String);
	TBinop(op:Binop);
	TUnop(op:Unop);
	Semicolon;
	Comma;
	BrOpen; BrClose;
	BkOpen; BkClose;
	POpen; PClose;
	Dot; DblDot; QuestionDot; Arrow;
	IntInterval(s:String);
	Sharp(s:String);
	Question; At;
	Dollar(s:String);
	TSpread;
}

enum UnopFlag {
	Prefix; Postfix;
}

enum WhileFlag {
	NormalWhile; DoWhile;
}

enum QuoteStatus {
	NoQuotes; DoubleQuotes;
}

enum EFieldKind {
	EFNormal; EFSafe;
}

enum FunctionKind {
	FKAnonymous;
	FKNamed(name:PlacedName, inlined:Bool);
	FKArrow;
}

enum DisplayKind {
	DKCall; DKDot; DKStructure; DKMarked; DKPattern(b:Bool);
}

typedef PlacedName = {name:String, pos:Position};

typedef TypePath = {
	tpackage:Array<String>,
	tname:String,
	tparams:Array<TypeParamOrConst>,
	tsub:Null<String>,
};

typedef PlacedTypePath = {path:TypePath, pos:Position};

typedef TypeHint = {ct:ComplexType, pos:Position};

enum TypeParamOrConst {
	TPType(t:TypeHint);
	TPExpr(e:Expr);
}

enum ComplexType {
	CTPath(t:TypePath);
	CTFunction(args:Array<TypeHint>, ret:TypeHint);
	CTAnonymous(fields:Array<ClassField>);
	CTParent(t:TypeHint);
	CTExtend(paths:Array<PlacedTypePath>, fields:Array<ClassField>);
	CTOptional(t:TypeHint);
	CTNamed(n:PlacedName, t:TypeHint);
	CTIntersection(tl:Array<TypeHint>);
}

@:structInit
class DocBlock {
	public var own:Null<String>;
	public var inherited:Array<String>;

	public function new(own:Null<String>, ?inherited:Array<String>) {
		this.own = own;
		this.inherited = inherited == null ? [] : inherited;
	}
}

typedef Documentation = Null<DocBlock>;

typedef MetadataEntry = {name:String, params:Array<Expr>, pos:Position};
typedef Metadata = Array<MetadataEntry>;

typedef TypeParam = {
	tpName:PlacedName,
	tpParams:Array<TypeParam>,
	tpConstraints:Null<TypeHint>,
	tpDefault:Null<TypeHint>,
	tpMeta:Metadata,
};

typedef FunctionArg = {
	name:PlacedName,
	opt:Bool,
	meta:Metadata,
	type:Null<TypeHint>,
	value:Null<Expr>,
};

typedef Func = {
	fParams:Array<TypeParam>,
	fArgs:Array<FunctionArg>,
	fType:Null<TypeHint>,
	fExpr:Null<Expr>,
};

enum Access {
	APublic; APrivate; AStatic; AOverride; ADynamic; AInline; AMacro; AFinal;
	AExtern; AAbstract; AOverload;
}

typedef PlacedAccess = {access:Access, pos:Position};

enum ClassFieldKind {
	FVar(t:Null<TypeHint>, e:Null<Expr>);
	FFun(f:Func);
	FProp(get:PlacedName, set:PlacedName, t:Null<TypeHint>, e:Null<Expr>);
}

// Class fields use reference semantics.
@:structInit
class ClassField {
	public var cffName:PlacedName;
	public var cffDoc:Documentation;
	public var cffPos:Position;
	public var cffMeta:Metadata;
	public var cffAccess:Array<PlacedAccess>;
	public var cffKind:ClassFieldKind;

	public function new(cffName:PlacedName, cffDoc:Documentation, cffPos:Position, cffMeta:Metadata, cffAccess:Array<PlacedAccess>,
			cffKind:ClassFieldKind) {
		this.cffName = cffName;
		this.cffDoc = cffDoc;
		this.cffPos = cffPos;
		this.cffMeta = cffMeta;
		this.cffAccess = cffAccess;
		this.cffKind = cffKind;
	}
}

typedef EVar = {
	evName:PlacedName,
	evFinal:Bool,
	evStatic:Bool,
	evType:Null<TypeHint>,
	evExpr:Null<Expr>,
	evMeta:Metadata,
};

typedef ObjectField = {name:String, pos:Position, quotes:QuoteStatus, expr:Expr};

typedef SwitchCase = {values:Array<Expr>, guard:Null<Expr>, expr:Null<Expr>, pos:Position};

typedef Catch = {name:PlacedName, type:Null<TypeHint>, expr:Expr, pos:Position};

enum ExprDef {
	EConst(c:Constant);
	EArray(e1:Expr, e2:Expr);
	EBinop(op:Binop, e1:Expr, e2:Expr);
	EField(e:Expr, field:String, kind:EFieldKind);
	EParenthesis(e:Expr);
	EObjectDecl(fields:Array<ObjectField>);
	EArrayDecl(values:Array<Expr>);
	ECall(e:Expr, params:Array<Expr>);
	ENew(t:PlacedTypePath, params:Array<Expr>);
	EUnop(op:Unop, flag:UnopFlag, e:Expr);
	EVars(vars:Array<EVar>);
	EFunction(kind:FunctionKind, f:Func);
	EBlock(exprs:Array<Expr>);
	EFor(it:Expr, expr:Expr);
	EIf(econd:Expr, eif:Expr, eelse:Null<Expr>);
	EWhile(econd:Expr, e:Expr, flag:WhileFlag);
	ESwitch(e:Expr, cases:Array<SwitchCase>, edef:Null<{e:Null<Expr>, pos:Position}>);
	ETry(e:Expr, catches:Array<Catch>);
	EReturn(e:Null<Expr>);
	EBreak;
	EContinue;
	EUntyped(e:Expr);
	EThrow(e:Expr);
	ECast(e:Expr, t:Null<TypeHint>);
	EIs(e:Expr, t:TypeHint);
	EDisplay(e:Expr, kind:DisplayKind);
	ETernary(econd:Expr, eif:Expr, eelse:Expr);
	ECheckType(e:Expr, t:TypeHint);
	EMeta(entry:MetadataEntry, e:Expr);
}

@:structInit
class Expr {
	public var expr:ExprDef;
	public var pos:Position;

	public function new(expr:ExprDef, pos:Position) {
		this.expr = expr;
		this.pos = pos;
	}

	public static function ensureBlock(e:Expr):Expr {
		return switch e.expr {
			case EBlock(_): e;
			case _: new Expr(EBlock([e]), e.pos);
		}
	}

	public static function fieldAssoc(name:String, fl:Array<ObjectField>):Expr {
		for (f in fl)
			if (f.name == name)
				return f.expr;
		throw new NotFound("Ast.hx:258");
	}

	public static function fieldMemAssoc(name:String, fl:Array<ObjectField>):Bool {
		try {
			for (f in fl)
				if (f.name == name)
					throw new ExitException();
			return false;
		} catch (e:ExitException) {
			return true;
		}
	}

	// A positional debug dump of an expr tree.
	public static function dumpWithPos(e:Expr):String {
		var buf = new StringBuf();
		function pad4(n:Int):String
			return StringTools.lpad(Std.string(n), " ", 4);
		function loop2(tabs:String, e:Expr):Void {
			var p = e.pos;
			function add(s:String):Void
				buf.add(pad4(p.min) + "-" + pad4(p.max) + " " + tabs + s + "\n");
			function loop(e:Expr):Void
				loop2(tabs + "  ", e);
			switch e.expr {
				case EConst(ct): add(Ast.sConstant(ct));
				case EArray(e1, e2): add("EArray"); loop(e1); loop(e2);
				case EBinop(op, e1, e2): add("EBinop " + Ast.sBinop(op)); loop(e1); loop(e2);
				case EField(e1, s, _): add("EField " + s); loop(e1);
				case EParenthesis(e1): add("EParenthesis"); loop(e1);
				case EObjectDecl(fl):
					add("EObjectDecl");
					for (f in fl) {
						buf.add(pad4(f.pos.min) + "-" + pad4(f.pos.max) + " " + tabs + f.name + "\n");
						loop(f.expr);
					}
				case EArrayDecl(el): add("EArrayDecl"); for (x in el) loop(x);
				case ECall(e1, el): add("ECall"); loop(e1); for (x in el) loop(x);
				case ENew(tp, el): add("ENew " + Globals.sTypePath({pack: tp.path.tpackage, name: tp.path.tname})); for (x in el) loop(x);
				case EUnop(op, _, e1): add("EUnop " + Ast.sUnop(op)); loop(e1);
				case EVars(vl):
					add("EVars");
					for (v in vl) {
						var tHint = v.evType == null ? "" : ":" + Printer.sComplexType("", v.evType.ct);
						add(tabs + "  " + v.evName.name + tHint);
						if (v.evExpr != null)
							loop2(tabs + "      ", v.evExpr);
					}
				case EFunction(_, f): add("EFunction"); if (f.fExpr != null) loop(f.fExpr);
				case EBlock(el): add("EBlock"); for (x in el) loop(x);
				case EFor(e1, e2): add("EFor"); loop(e1); loop(e2);
				case EIf(e1, e2, eo): add("EIf"); loop(e1); loop(e2); if (eo != null) loop(eo);
				case EWhile(e1, e2, _): add("EWhile"); loop(e1); loop(e2);
				case ESwitch(e1, cases, def):
					add("ESwitch");
					loop(e1);
					for (cs in cases) {
						for (x in cs.values) loop2(tabs + "    ", x);
						if (cs.expr != null) loop2(tabs + "      ", cs.expr);
					}
					if (def != null && def.e != null) loop2(tabs + "      ", def.e);
				case ETry(e1, catches): add("ETry"); loop(e1); for (c in catches) loop2(tabs + "    ", c.expr);
				case EReturn(eo): add("EReturn"); if (eo != null) loop(eo);
				case EBreak: add("EBreak");
				case EContinue: add("EContinue");
				case EUntyped(e1): add("EUntyped"); loop(e1);
				case EThrow(e1): add("EThrow"); loop(e1);
				case ECast(e1, _): add("ECast"); loop(e1);
				case EIs(e1, _): add("EIs"); loop(e1);
				case EDisplay(e1, dk): add("EDisplay " + Ast.sDisplayKind(dk)); loop(e1);
				case ETernary(e1, e2, e3): add("ETernary"); loop(e1); loop(e2); loop(e3);
				case ECheckType(e1, _): add("ECheckType"); loop(e1);
				case EMeta(m, e1): add("EMeta " + m.name); loop(e1);
			}
		}
		loop2("", e);
		return buf.toString();
	}

	public static function findIdent(e:Expr):Null<String> {
		return switch e.expr {
			case EConst(c): switch c {
					case CIdent(s): s;
					case _: null;
				};
			case _: null;
		}
	}
}

enum EnumFlag {
	EPrivate; EExtern;
}

enum ClassFlag {
	HInterface; HExtern; HPrivate;
	HExtends(t:PlacedTypePath);
	HImplements(t:PlacedTypePath);
	HFinal; HAbstract;
}

enum AbstractFlag {
	AbPrivate; AbFrom(t:TypeHint); AbTo(t:TypeHint); AbOver(t:TypeHint); AbExtern; AbEnum;
}

typedef EnumConstructor = {
	ecName:PlacedName,
	ecDoc:Documentation,
	ecMeta:Metadata,
	ecArgs:Array<{name:String, opt:Bool, type:TypeHint}>,
	ecPos:Position,
	ecParams:Array<TypeParam>,
	ecType:Null<TypeHint>,
};

typedef Definition<F, D> = {
	dName:PlacedName,
	dDoc:Documentation,
	dParams:Array<TypeParam>,
	dMeta:Metadata,
	dFlags:Array<F>,
	dData:D,
};

enum ImportMode {
	INormal;
	IAsName(n:PlacedName);
	IAll;
}

typedef Import = {path:Array<PlacedName>, mode:ImportMode, ?pos:Position};

enum TypeDef {
	EClass(d:Definition<ClassFlag, Array<ClassField>>);
	EEnum(d:Definition<EnumFlag, Array<EnumConstructor>>);
	ETypedef(d:Definition<EnumFlag, TypeHint>);
	EAbstract(d:Definition<AbstractFlag, Array<ClassField>>);
	EStatic(d:Definition<PlacedAccess, ClassFieldKind>);
	EImport(i:Import);
	EUsing(path:Array<PlacedName>);
}

typedef TypeDecl = {decl:TypeDef, pos:Position};

typedef Package = {pack:Array<String>, decls:Array<TypeDecl>};

enum DeclFlag {
	DPrivate; DExtern; DFinal; DMacro; DDynamic; DInline; DPublic; DStatic; DOverload;
}

typedef PlacedDeclFlag = {flag:DeclFlag, pos:Position};

class InvalidEscapeSequence extends haxe.Exception {
	public final c:Int;
	public final i:Int;
	public final escMsg:Null<String>;

	public function new(c:Int, i:Int, escMsg:Null<String>) {
		super("Invalid_escape_sequence");
		this.c = c;
		this.i = i;
		this.escMsg = escMsg;
	}
}

class Ast {
	public static final ctMono:ComplexType = CTPath({tpackage: ["$"], tname: "_hx_mono", tparams: [], tsub: null});

	public static function mkTypePath(path:Path, ?sub:String, ?params:Array<TypeParamOrConst>):TypePath {
		if (path.name == "")
			throw new haxe.Exception("Empty module name is not allowed");
		return {tpackage: path.pack, tname: path.name, tsub: sub, tparams: params == null ? [] : params};
	}

	public static function mkEvar(name:PlacedName, ?t:TypeHint, ?eo:Expr, isFinal:Bool = false, isStatic:Bool = false, ?meta:Metadata):EVar {
		return {
			evName: name,
			evFinal: isFinal,
			evStatic: isStatic,
			evType: t,
			evExpr: eo,
			evMeta: meta == null ? [] : meta,
		};
	}

	public static function isLowerIdent(i:String):Bool {
		if (i.length == 0)
			throw new haxe.Exception("Identifier name must not be empty");
		// Use a loop to avoid allocating a recursive closure for each path segment.
		var p = 0;
		while (true) {
			var c = i.charCodeAt(p);
			if (c >= "a".code && c <= "z".code) return true;
			if (c != "_".code) return false;
			if (p + 1 >= i.length) return true;
			p++;
		}
	}

	public static inline function pos(e:Expr):Position {
		return e.pos;
	}

	public static function docFromString(s:String):Documentation {
		return new DocBlock(s, []);
	}

	public static function docFromStringOpt(s:Null<String>):Documentation {
		return s == null ? null : new DocBlock(s, []);
	}

	public static function genDocText(d:DocBlock):String {
		var docs = d.own != null ? [d.own].concat(d.inherited) : d.inherited;
		return docs.join("\n");
	}

	public static function genDocTextOpt(d:Documentation):Null<String> {
		return d == null ? null : genDocText(d);
	}

	public static function getOwnDocOpt(d:Documentation):Null<String> {
		return d == null ? null : d.own;
	}

	public static function isPostfix(e:Expr, op:Unop):Bool {
		return switch op {
			case Increment | Decrement | Not: true;
			case Neg | NegBits | Spread: false;
		}
	}

	public static inline function punion(p:Position, p2:Position):Position {
		return Position.union(p, p2);
	}

	public static function punionEl(el:Array<{pos:Position}>):Position {
		if (el.length == 0)
			return Position.nullPos;
		if (el.length == 1)
			return el[0].pos;
		return punion(el[0].pos, punionEl(el.slice(1)));
	}

	public static function parsePath(s:String):Path {
		var parts = s.split(".");
		var name = parts[parts.length - 1];
		var pack = parts.slice(0, parts.length - 1);
		return {pack: pack, name: name};
	}

	public static function sConstant(c:Constant):String {
		return switch c {
			case CInt(s, suffix): suffix == null ? s : s + suffix;
			case CFloat(s, suffix): suffix == null ? s : s + suffix;
			case CString(s, _): "\"" + StringHelper.sEscape(s) + "\"";                    
			case CIdent(s): s;
			case CRegexp(r, _): "~/" + r + "/";
		}
	}

	public static function sAccess(a:Access):String {
		return switch a {
			case APublic: "public";
			case APrivate: "private";
			case AStatic: "static";
			case AOverride: "override";
			case ADynamic: "dynamic";
			case AInline: "inline";
			case AMacro: "macro";
			case AFinal: "final";
			case AExtern: "extern";
			case AAbstract: "abstract";
			case AOverload: "overload";
		}
	}

	public static function sPlacedAccess(pa:PlacedAccess):String {
		return sAccess(pa.access);
	}

	public static function sKeyword(k:Keyword):String {
		return switch k {
			case KwdFunction: "function";
			case KwdClass: "class";
			case KwdStatic: "static";
			case KwdVar: "var";
			case KwdIf: "if";
			case KwdElse: "else";
			case KwdWhile: "while";
			case KwdDo: "do";
			case KwdFor: "for";
			case KwdBreak: "break";
			case KwdReturn: "return";
			case KwdContinue: "continue";
			case KwdExtends: "extends";
			case KwdImplements: "implements";
			case KwdImport: "import";
			case KwdSwitch: "switch";
			case KwdCase: "case";
			case KwdDefault: "default";
			case KwdPrivate: "private";
			case KwdPublic: "public";
			case KwdTry: "try";
			case KwdCatch: "catch";
			case KwdNew: "new";
			case KwdThis: "this";
			case KwdThrow: "throw";
			case KwdExtern: "extern";
			case KwdEnum: "enum";
			case KwdIn: "in";
			case KwdInterface: "interface";
			case KwdUntyped: "untyped";
			case KwdCast: "cast";
			case KwdOverride: "override";
			case KwdTypedef: "typedef";
			case KwdDynamic: "dynamic";
			case KwdPackage: "package";
			case KwdInline: "inline";
			case KwdUsing: "using";
			case KwdNull: "null";
			case KwdTrue: "true";
			case KwdFalse: "false";
			case KwdAbstract: "abstract";
			case KwdMacro: "macro";
			case KwdFinal: "final";
			case KwdOperator: "operator";
			case KwdOverload: "overload";
		}
	}

	public static function sBinop(op:Binop):String {
		return switch op {
			case OpAdd: "+";
			case OpMult: "*";
			case OpDiv: "/";
			case OpSub: "-";
			case OpAssign: "=";
			case OpEq: "==";
			case OpNotEq: "!=";
			case OpGte: ">=";
			case OpLte: "<=";
			case OpGt: ">";
			case OpLt: "<";
			case OpAnd: "&";
			case OpOr: "|";
			case OpXor: "^";
			case OpBoolAnd: "&&";
			case OpBoolOr: "||";
			case OpShr: ">>";
			case OpUShr: ">>>";
			case OpShl: "<<";
			case OpMod: "%";
			case OpAssignOp(op): sBinop(op) + "=";
			case OpInterval: "...";
			case OpArrow: "=>";
			case OpIn: " in ";
			case OpNullCoal: "??";
		}
	}

	public static function sUnop(op:Unop):String {
		return switch op {
			case Increment: "++";
			case Decrement: "--";
			case Not: "!";
			case Neg: "-";
			case NegBits: "~";
			case Spread: "...";
		}
	}

	public static function sToken(t:Token):String {
		return switch t {
			case Eof: "<end of file>";
			case Const(c): sConstant(c);
			case Kwd(k): sKeyword(k);
			case Comment(s): "/*" + s + "*/";
			case CommentLine(s): "//" + s;
			case TBinop(o): sBinop(o);
			case TUnop(o): sUnop(o);
			case Semicolon: ";";
			case Comma: ",";
			case BkOpen: "[";
			case BkClose: "]";
			case BrOpen: "{";
			case BrClose: "}";
			case POpen: "(";
			case PClose: ")";
			case Dot: ".";
			case DblDot: ":";
			case QuestionDot: "?.";
			case Arrow: "->";
			case IntInterval(s): s + "...";
			case Sharp(s): "#" + s;
			case Question: "?";
			case At: "@";
			case Dollar(v): "$" + v;
			case TSpread: "...";
		}
	}

	public static function efield(e:Expr, s:String):ExprDef {
		return EField(e, s, EFNormal);
	}

	public static function unescape(s:String):String {
		var b = new StringBuf();
		var i = 0;
		var esc = false;
		while (i != s.length) {
			var c = s.charCodeAt(i);
			if (esc) {
				var inext = i + 1;
				switch c {
					case "n".code: b.addChar(10);
					case "r".code: b.addChar(13);
					case "t".code: b.addChar(9);
					case '"'.code | "'".code | "\\".code: b.addChar(c);
					case _ if (c >= "0".code && c <= "3".code):
						// '0'..'3' -> octal of 3 chars starting at i
						var u = i + 3 <= s.length ? parseRadixStrict(s.substr(i, 3), 8) : null;
						if (u == null)
							throw new InvalidEscapeSequence(c, i, null);
						if (u > 127)
							throw new InvalidEscapeSequence(c, i,
								"Values greater than \\177 are not allowed. Use \\u00" + StringTools.hex(u, 2).toLowerCase() + " instead.");
						b.addChar(u);
						inext += 2;
					case "x".code:
						var hex = i + 1 + 2 <= s.length ? s.substr(i + 1, 2) : null;
						var u = hex == null ? null : parseRadixStrict(hex, 16);
						if (u == null)
							throw new InvalidEscapeSequence(c, i, "Must be followed by a hexadecimal sequence.");
						if (u > 127)
							throw new InvalidEscapeSequence(c, i, "Values greater than \\x7f are not allowed. Use \\u00" + hex + " instead.");
						b.addChar(u);
						inext += 2;
					case "u".code:
						var u:Null<Int> = null;
						var a = 0;
						var u4 = i + 1 + 4 <= s.length ? parseRadixStrict(s.substr(i + 1, 4), 16) : null;
						if (u4 != null) {
							u = u4;
							a = 4;
						} else {
							var noHex = "Must be followed by a hexadecimal sequence enclosed in curly brackets.";
							if (i + 1 >= s.length || s.charCodeAt(i + 1) != "{".code)
								throw new InvalidEscapeSequence(c, i, noHex);
							var close = s.indexOf("}", i + 3);
							if (close < 0)
								throw new InvalidEscapeSequence(c, i, noHex);
							var l = close - (i + 2);
							var uu = parseRadixStrict(s.substr(i + 2, l), 16);
							if (uu == null)
								throw new InvalidEscapeSequence(c, i, noHex);
							if (uu > 0x10FFFF)
								throw new InvalidEscapeSequence(c, i, "Maximum allowed value for unicode escape sequence is \\u{10FFFF}");
							u = uu;
							a = l + 2;
						}
						if (u >= 0xD800 && u < 0xE000)
							throw new InvalidEscapeSequence(c, i, "UTF-16 surrogates are not allowed in strings.");
						// Append code points directly; appending UTF-8 bytes would encode them twice.
						b.addChar(u);
						inext += a;
					case _:
						throw new InvalidEscapeSequence(c, i, null);
				}
				esc = false;
				i = inext;
			} else {
				if (c == "\\".code) {
					esc = true;
					i = i + 1;
				} else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length && s.charCodeAt(i + 1) >= 0xDC00 && s.charCodeAt(i + 1) < 0xE000) {
					// Copy an astral character whole; hxcpp's StringBuf.addChar corrupts lone surrogates.
					b.addChar(0x10000 + ((c - 0xD800) << 10) + (s.charCodeAt(i + 1) - 0xDC00));
					i = i + 2;
				} else {
					b.addChar(c);
					i = i + 1;
				}
			}
		}
		return b.toString();
	}

	// Ignore digit separators except a leading underscore. Clamp overflow above the maximum code point
	// so the caller can reject it.
	static function parseRadixStrict(str:String, radix:Int):Null<Int> {
		if (str.length == 0 || str.charCodeAt(0) == "_".code)
			return null;
		var n = 0;
		for (i in 0...str.length) {
			var c = str.charCodeAt(i);
			if (c == "_".code)
				continue;                                                       
			var d;
			if (c >= "0".code && c <= "9".code)
				d = c - "0".code;
			else if (c >= "a".code && c <= "f".code)
				d = c - "a".code + 10;
			else if (c >= "A".code && c <= "F".code)
				d = c - "A".code + 10;
			else
				return null;
			if (d >= radix)
				return null;
			n = n * radix + d;
			if (n > 0x10FFFF)
				n = 0x110000; // past the max code point: stay above it without 32-bit wrap
		}
		return n;
	}

	public static function mapExpr(loop:Expr->Expr, e:Expr):Expr {
		var def = switch e.expr {
			case EConst(_): e.expr;
			case EArray(e1, e2): EArray(loop(e1), loop(e2));
			case EBinop(op, e1, e2): EBinop(op, loop(e1), loop(e2));
			case EField(e1, f, efk): EField(loop(e1), f, efk);
			case EParenthesis(e1): EParenthesis(loop(e1));
			case EObjectDecl(fl): EObjectDecl([for (of in fl) {name: of.name, pos: of.pos, quotes: of.quotes, expr: loop(of.expr)}]);
			case EArrayDecl(el): EArrayDecl([for (x in el) loop(x)]);
			case ECall(e1, el): ECall(loop(e1), [for (x in el) loop(x)]);
			case ENew(t, el): ENew(meTpath(loop, t), [for (x in el) loop(x)]);
			case EUnop(op, f, e1): EUnop(op, f, loop(e1));
			case EVars(vl): EVars([
					for (v in vl)
						{
							evName: v.evName,
							evFinal: v.evFinal,
							evStatic: v.evStatic,
							evType: v.evType == null ? null : meTypeHint(loop, v.evType),
							evExpr: v.evExpr == null ? null : loop(v.evExpr),
							evMeta: v.evMeta,
						}
				]);
			case EFunction(kind, f): EFunction(kind, meFunc(loop, f));
			case EBlock(el): EBlock([for (x in el) loop(x)]);
			case EFor(e1, e2): EFor(loop(e1), loop(e2));
			case EIf(e1, e2, e3): EIf(loop(e1), loop(e2), e3 == null ? null : loop(e3));
			case EWhile(econd, e1, f): EWhile(loop(econd), loop(e1), f);
			case ESwitch(e1, cases, def2):
				ESwitch(loop(e1), [
					for (cs in cases)
						{
							values: [for (x in cs.values) loop(x)],
							guard: cs.guard == null ? null : loop(cs.guard),
							expr: cs.expr == null ? null : loop(cs.expr),
							pos: cs.pos,
						}
				], def2 == null ? null : {e: def2.e == null ? null : loop(def2.e), pos: def2.pos});
			case ETry(e1, catches):
				ETry(loop(e1), [
					for (ca in catches)
						{
							name: ca.name,
							type: ca.type == null ? null : meTypeHint(loop, ca.type),
							expr: loop(ca.expr),
							pos: ca.pos,
						}
				]);
			case EReturn(e1): EReturn(e1 == null ? null : loop(e1));
			case EBreak: EBreak;
			case EContinue: EContinue;
			case EUntyped(e1): EUntyped(loop(e1));
			case EThrow(e1): EThrow(loop(e1));
			case ECast(e1, t): ECast(loop(e1), t == null ? null : meTypeHint(loop, t));
			case EIs(e1, t): EIs(loop(e1), meTypeHint(loop, t));
			case EDisplay(e1, f): EDisplay(loop(e1), f);
			case ETernary(e1, e2, e3): ETernary(loop(e1), loop(e2), loop(e3));
			case ECheckType(e1, t): ECheckType(loop(e1), meTypeHint(loop, t));
			case EMeta(m, e1): EMeta(m, loop(e1));
		};
		return new Expr(def, e.pos);
	}

	static function meTparam(loop:Expr->Expr, p:TypeParamOrConst):TypeParamOrConst {
		return switch p {
			case TPType(t): TPType(meTypeHint(loop, t));
			case TPExpr(e): TPExpr(loop(e));
		}
	}

	static function meTypeHint(loop:Expr->Expr, th:TypeHint):TypeHint {
		var ct = switch th.ct {
			case CTPath(t):
				CTPath({tpackage: t.tpackage, tname: t.tname, tparams: [for (p in t.tparams) meTparam(loop, p)], tsub: t.tsub});
			case CTFunction(cl, c): CTFunction([for (t in cl) meTypeHint(loop, t)], meTypeHint(loop, c));
			case CTAnonymous(fl): CTAnonymous([for (f in fl) meCfield(loop, f)]);
			case CTParent(t): CTParent(meTypeHint(loop, t));
			case CTExtend(tl, fl): CTExtend([for (t in tl) meTpath(loop, t)], [for (f in fl) meCfield(loop, f)]);
			case CTOptional(t): CTOptional(meTypeHint(loop, t));
			case CTNamed(n, t): CTNamed(n, meTypeHint(loop, t));
			case CTIntersection(tl): CTIntersection([for (t in tl) meTypeHint(loop, t)]);
		};
		return {ct: ct, pos: th.pos};
	}

	static function meCfield(loop:Expr->Expr, f:ClassField):ClassField {
		var kind = switch f.cffKind {
			case FVar(t, e): FVar(t == null ? null : meTypeHint(loop, t), e == null ? null : loop(e));
			case FFun(fn): FFun(meFunc(loop, fn));
			case FProp(get, set, t, e): FProp(get, set, t == null ? null : meTypeHint(loop, t), e == null ? null : loop(e));
		};
		return {
			cffName: f.cffName,
			cffDoc: f.cffDoc,
			cffPos: f.cffPos,
			cffMeta: f.cffMeta,
			cffAccess: f.cffAccess,
			cffKind: kind,
		};
	}

	static function meTparamdecl(loop:Expr->Expr, t:TypeParam):TypeParam {
		return {
			tpName: t.tpName,
			tpConstraints: t.tpConstraints == null ? null : meTypeHint(loop, t.tpConstraints),
			tpDefault: t.tpDefault == null ? null : meTypeHint(loop, t.tpDefault),
			tpParams: [for (p in t.tpParams) meTparamdecl(loop, p)],
			tpMeta: t.tpMeta,
		};
	}

	static function meFunc(loop:Expr->Expr, f:Func):Func {
		return {
			fParams: [for (p in f.fParams) meTparamdecl(loop, p)],
			fArgs: [
				for (a in f.fArgs)
					{
						name: a.name,
						opt: a.opt,
						meta: a.meta,
						type: a.type == null ? null : meTypeHint(loop, a.type),
						value: a.value == null ? null : loop(a.value),
					}
			],
			fType: f.fType == null ? null : meTypeHint(loop, f.fType),
			fExpr: f.fExpr == null ? null : loop(f.fExpr),
		};
	}

	static function meTpath(loop:Expr->Expr, tp:PlacedTypePath):PlacedTypePath {
		return {
			path: {
				tpackage: tp.path.tpackage,
				tname: tp.path.tname,
				tparams: [for (p in tp.path.tparams) meTparam(loop, p)],
				tsub: tp.path.tsub,
			},
			pos: tp.pos,
		};
	}

	public static function iterExpr(loop:Expr->Void, e:Expr):Void {
		switch e.expr {
			case EConst(_) | EContinue | EBreak | EReturn(null): {}
			case EParenthesis(e1) | EField(e1, _, _) | EUnop(_, _, e1) | EReturn(e1) | EThrow(e1) | EMeta(_, e1) | ECheckType(e1, _) |
				EDisplay(e1, _) | ECast(e1, _) | EIs(e1, _) | EUntyped(e1):
				loop(e1);
			case EArray(e1, e2) | EBinop(_, e1, e2) | EFor(e1, e2) | EWhile(e1, e2, _) | EIf(e1, e2, null):
				loop(e1);
				loop(e2);
			case ETernary(e1, e2, e3) | EIf(e1, e2, e3):
				loop(e1);
				loop(e2);
				loop(e3);
			case EArrayDecl(el) | ENew(_, el) | EBlock(el):
				for (x in el)
					loop(x);
			case ECall(e1, el):
				loop(e1);
				for (x in el)
					loop(x);
			case EObjectDecl(fl):
				for (f in fl)
					loop(f.expr);
			case ETry(e1, catches):
				loop(e1);
				for (c in catches)
					loop(c.expr);
			case ESwitch(e1, cases, def):
				loop(e1);
				for (cs in cases) {
					for (x in cs.values)
						loop(x);
					if (cs.guard != null)
						loop(cs.guard);
					if (cs.expr != null)
						loop(cs.expr);
				}
				if (def != null && def.e != null)
					loop(def.e);
			case EFunction(_, f):
				for (a in f.fArgs)
					if (a.value != null)
						loop(a.value);
				if (f.fExpr != null)
					loop(f.fExpr);
			case EVars(vl):
				for (v in vl)
					if (v.evExpr != null)
						loop(v.evExpr);
		}
	}

	public static function sObjectKeyName(name:String, qs:QuoteStatus):String {
		return switch qs {
			case DoubleQuotes: "\"" + StringHelper.sEscape(name) + "\"";
			case NoQuotes: name;
		}
	}

	public static function sDisplayKind(dk:DisplayKind):String {
		return switch dk {
			case DKCall: "DKCall";
			case DKDot: "DKDot";
			case DKStructure: "DKStructure";
			case DKMarked: "DKMarked";
			case DKPattern(_): "DKPattern";
		}
	}

	public static function getValueMeta(meta:Metadata):haxe.ds.StringMap<Expr> {
		var result = new haxe.ds.StringMap<Expr>();
		for (m in meta) {
			if (m.name == ":value") {
				if (m.params.length == 1) {
					switch m.params[0].expr {
						case EObjectDecl(values):
							for (f in values)
								result.set(f.name, f.expr);
						case _:
					}
				}
				return result;                                    
			}
		}
		return result;
	}

	public static function stringListOfExprPathRaise(e:Expr):Array<String> {
		return switch e.expr {
			case EConst(CIdent(i)): [i];
			case EField(e1, f, _): [f].concat(stringListOfExprPathRaise(e1));
			case _: throw new ExitException();
		}
	}

	public static function stringPosListOfExprPathRaise(e:Expr):Array<{s:String, p:Position}> {
		return switch e.expr {
			case EConst(CIdent(i)): [{s: i, p: e.pos}];
			case EField(e1, f, _): [{s: f, p: e.pos}].concat(stringPosListOfExprPathRaise(e1));
			case _: throw new ExitException();
		}
	}

	public static function exprOfTypePath(path:Path, p:Position):Expr {
		if (path.pack.length == 0)
			return new Expr(EConst(CIdent(path.name)), p);
		var rest = path.pack.slice(1);
		var e = new Expr(EConst(CIdent(path.pack[0])), p);
		for (s in rest)
			e = new Expr(efield(e, s), p);
		return new Expr(efield(e, path.name), p);
	}

	public static function matchPath(recursive:Bool, sl:Array<String>, slPattern:Array<String>):Bool {
		function loop(top:Bool, a:Array<String>, b:Array<String>):Bool {
			if (a.length == 0 && b.length == 0)
				return true;
			// Always recurse into types of package paths
			if (a.length >= 2 && b.length == 1 && isLowerIdent(b[0]) && !isLowerIdent(a[1]))
				return a[0] == b[0];
			if (a.length == 1 && b.length == 0 && top)
				return true;
			if (b.length == 0)
				return recursive;
			if (a.length == 0)
				return false;
			return a[0] == b[0] && loop(false, a.slice(1), b.slice(1));
		}
		return loop(true, sl, slPattern);
	}

	public static function fullDotPath2(mpath:Path, tpath:Path):Array<String> {
		if (pathEq(mpath, tpath))
			return tpath.pack.concat([tpath.name]);
		else
			return mpath.pack.concat([mpath.name, tpath.name]);
	}

	static function pathEq(a:Path, b:Path):Bool {
		if (a.name != b.name || a.pack.length != b.pack.length)
			return false;
		for (i in 0...a.pack.length)
			if (a.pack[i] != b.pack[i])
				return false;
		return true;
	}

	public static function safeForAll2<A, B>(f:(A, B) -> Bool, a:Array<A>, b:Array<B>):Bool {
		try {
			if (a.length != b.length)
				throw new haxe.Exception("for_all2");
			for (i in 0...a.length)
				if (!f(a[i], b[i]))
					return false;
			return true;
		} catch (e:Dynamic) {
			return false;
		}
	}

	public static function removeDuplicates<T>(f:(T, T) -> Bool, l:Array<T>):Array<T> {
		if (l.length == 0)
			return [];
		var x = l[0];
		var rest = l.slice(1);
		var filtered = [for (xp in rest) if (f(x, xp)) xp];
		return [x].concat(removeDuplicates(f, filtered));
	}

	public static function hasMetaOption(metas:Metadata, meta:String, s:String):Bool {
		for (m in metas) {
			if (m.name == meta) {
				var found = false;
				for (p in m.params)
					switch p.expr {
						case EConst(CIdent(s2)) if (s == s2): found = true;
						case _:
					}
				if (found)
					return true;
			}
		}
		return false;
	}

	public static function getMetaOptions(metas:Metadata, meta:String):Array<String> {
		for (m in metas)
			if (m.name == meta) {
				var out = [];
				for (p in m.params)
					switch p.expr {
						case EConst(CIdent(s2)): out.push(s2);
						case _:
					}
				return out;
			}
		return [];
	}

	public static function getMetaString(meta:Metadata, key:String):Null<String> {
		for (m in meta) {
			if (m.name == key && m.params.length == 1) {
				switch m.params[0].expr {
					case EConst(CString(name, _)): return name;
					case _:
				}
			}
		}
		return null;
	}
}

class Printer {
	public static function sExprInner(tabs:String, e:Expr):String {
		return switch e.expr {
			case EConst(c): Ast.sConstant(c);
			case EArray(e1, e2): sExprInner(tabs, e1) + "[" + sExprInner(tabs, e2) + "]";
			case EBinop(op, e1, e2): sExprInner(tabs, e1) + " " + Ast.sBinop(op) + " " + sExprInner(tabs, e2);
			case EField(e1, f, efk): sExprInner(tabs, e1) + (switch efk {
					case EFNormal: ".";
					case EFSafe: "?.";
				}) + f;
			case EParenthesis(e1): "(" + sExprInner(tabs, e1) + ")";
			case EObjectDecl(fl):
				"{ " + [for (of in fl) Ast.sObjectKeyName(of.name, of.quotes) + " : " + sExprInner(tabs, of.expr)].join(", ") + " }";
			case EArrayDecl(el): "[" + sExprList(tabs, el, ", ") + "]";
			case ECall(e1, el): sExprInner(tabs, e1) + "(" + sExprList(tabs, el, ", ") + ")";
			case ENew(t, el): "new " + sComplexTypePath(tabs, t) + "(" + sExprList(tabs, el, ", ") + ")";
			case EUnop(op, Postfix, e1): sExprInner(tabs, e1) + Ast.sUnop(op);
			case EUnop(op, Prefix, e1): Ast.sUnop(op) + sExprInner(tabs, e1);
			case EFunction(FKNamed(n, inlined), f): (inlined ? "inline " : "") + "function " + n.name + sFunc(tabs, f);
			case EFunction(FKAnonymous, f): "function" + sFunc(tabs, f);
			case EFunction(FKArrow, f): "function" + sFunc(tabs, f, true);
			case EVars(vl): "var " + [for (v in vl) sVar(tabs, v)].join(", ");
			case EBlock([]): "{ }";
			case EBlock(el): sBlock(tabs, el, "{", "\n", "}");
			case EFor(e1, e2): "for (" + sExprInner(tabs, e1) + ") " + sExprInner(tabs, e2);
			case EIf(e, e1, null): "if (" + sExprInner(tabs, e) + ") " + sExprInner(tabs, e1);
			case EIf(e, e1, e2): "if (" + sExprInner(tabs, e) + ") " + sExprInner(tabs, e1) + " else " + sExprInner(tabs, e2);
			case EWhile(econd, e1, NormalWhile): "while (" + sExprInner(tabs, econd) + ") " + sExprInner(tabs, e1);
			case EWhile(econd, e1, DoWhile): "do " + sExprInner(tabs, e1) + " while (" + sExprInner(tabs, econd) + ")";
			case ESwitch(e1, cases, def):
				"switch " + sExprInner(tabs, e1) + " {\n\t" + tabs + [for (cs in cases) sCase(tabs, cs)].join("\n\t" + tabs)
				+ (def == null ? "" : "\n\t" + tabs + "default:" + (def.e == null ? "" : sExprOmitBlock(tabs, def.e))) + "\n" + tabs + "}";
			case ETry(e1, catches): "try " + sExprInner(tabs, e1) + [for (c in catches) sCatch(tabs, c)].join("");
			case EReturn(e1): "return" + sOptExpr(tabs, e1, " ");
			case EBreak: "break";
			case EContinue: "continue";
			case EUntyped(e1): "untyped " + sExprInner(tabs, e1);
			case EThrow(e1): "throw " + sExprInner(tabs, e1);
			case ECast(e1, null): "cast " + sExprInner(tabs, e1);
			case ECast(e1, t): "cast (" + sExprInner(tabs, e1) + ", " + sComplexType(tabs, t.ct) + ")";
			case EIs(e1, t): sExprInner(tabs, e1) + " is " + sComplexType(tabs, t.ct);
			case ETernary(e1, e2, e3): sExprInner(tabs, e1) + " ? " + sExprInner(tabs, e2) + " : " + sExprInner(tabs, e3);
			case ECheckType(e1, t): "(" + sExprInner(tabs, e1) + " : " + sComplexType(tabs, t.ct) + ")";
			case EMeta(m, e1): sMetadata(tabs, m) + " " + sExprInner(tabs, e1);
			case EDisplay(e1, dk): "#DISPLAY(" + sExprInner(tabs, e1) + ", " + Ast.sDisplayKind(dk) + ")";
		}
	}

	static function sExprList(tabs:String, el:Array<Expr>, sep:String):String {
		return [for (e in el) sExprInner(tabs, e)].join(sep);
	}

	static function sComplexTypePath(tabs:String, tp:PlacedTypePath):String {
		return Globals.sTypePath({pack: tp.path.tpackage, name: tp.path.tname})
			+ (tp.path.tsub == null ? "" : "." + tp.path.tsub)
			+ sTypeParamOrConsts(tabs, tp.path.tparams);
	}

	static function sTypeParamOrConsts(tabs:String, pl:Array<TypeParamOrConst>):String {
		return pl.length > 0 ? "<" + [for (p in pl) sTypeParamOrConst(tabs, p)].join(",") + ">" : "";
	}

	static function sTypeParamOrConst(tabs:String, p:TypeParamOrConst):String {
		return switch p {
			case TPType(t): sComplexType(tabs, t.ct);
			case TPExpr(e): sExprInner(tabs, e);
		}
	}

	public static function sComplexType(tabs:String, ct:ComplexType):String {
		return switch ct {
			case CTPath(t): sComplexTypePath(tabs, {path: t, pos: Position.nullPos});
			case CTFunction(cl, ret):
				cl.length > 0 ? [for (t in cl) sComplexType(tabs, t.ct)].join(" -> ") : "Void" + " -> " + sComplexType(tabs, ret.ct);
			case CTAnonymous(fl): "{ " + [for (f in fl) sClassField(tabs, f)].join("; ") + "}";
			case CTParent(t): "(" + sComplexType(tabs, t.ct) + ")";
			case CTOptional(t): "?" + sComplexType(tabs, t.ct);
			case CTNamed(n, t): n.name + ":" + sComplexType(tabs, t.ct);
			case CTExtend(tl, fl):
				"{> " + [for (t in tl) sComplexTypePath(tabs, t)].join(" >, ") + ", " + [for (f in fl) sClassField(tabs, f)].join(", ") + " }";
			case CTIntersection(tl): [for (t in tl) sComplexType(tabs, t.ct)].join("&");
		}
	}

	static function sSeparated<T>(g:T->String, sep:String, list:Array<T>):String {
		return list.length > 0 ? [for (x in list) g(x)].join(sep) + sep : "";
	}

	static function sClassField(tabs:String, f:ClassField):String {
		var doc = f.cffDoc == null ? "" : "/**\n\t" + tabs + Ast.genDocText(f.cffDoc) + "\n**/\n";
		var sMeta = function(ml:Metadata) return sSeparated(function(m) return sMetadata(tabs, m), "\n" + tabs, ml);
		var sAccessList = function(al:Array<PlacedAccess>) return sSeparated(Ast.sPlacedAccess, " ", al);
		return switch f.cffKind {
			case FVar(t, e):
				var keyword = "var ";
				var question = "";
				var access = [];
				for (pa in f.cffAccess)
					switch pa.access {
						case AFinal: keyword = "final ";                                
						case _: access.push(pa);
					}
				var meta = [];
				for (m in f.cffMeta)
					if (m.name == ":optional")
						question = "?";                              
					else
						meta.push(m);
				doc + sMeta(meta) + sAccessList(access) + keyword + question + f.cffName.name + sOptTypeHint(tabs, t, " : ") + sOptExpr(tabs, e, " = ");
			case FProp(get, set, t, e):
				doc + sMeta(f.cffMeta) + sAccessList(f.cffAccess) + "var " + f.cffName.name + "(" + get.name + "," + set.name + ")"
				+ sOptTypeHint(tabs, t, " : ") + sOptExpr(tabs, e, " = ");
			case FFun(func):
				doc + sMeta(f.cffMeta) + sAccessList(f.cffAccess) + "function " + f.cffName.name + sFunc(tabs, func);
		}
	}

	static function sMetadata(tabs:String, m:MetadataEntry):String {
		return "@" + m.name + (m.params.length > 0 ? "(" + sExprList(tabs, m.params, ", ") + ")" : "");
	}

	static function sOptExpr(tabs:String, e:Null<Expr>, pre:String):String {
		return e == null ? "" : pre + sExprInner(tabs, e);
	}

	static function sOptTypeHint(tabs:String, t:Null<TypeHint>, pre:String):String {
		return t == null ? "" : pre + sComplexType(tabs, t.ct);
	}

	static function sFunc(tabs:String, f:Func, isArrow:Bool = false):String {
		return sTypeParamList(tabs, f.fParams)
			+ "(" + [for (a in f.fArgs) sFuncArg(tabs, a)].join(", ") + ")"
			+ sOptTypeHint(tabs, f.fType, ":")
			+ (isArrow ? " -> " : "")
			+ sOptExpr(tabs, f.fExpr, " ");
	}

	static function sTypeParam(tabs:String, t:TypeParam):String {
		return t.tpName.name + sTypeParamList(tabs, t.tpParams)
			+ (t.tpConstraints == null ? "" : ":(" + sComplexType(tabs, t.tpConstraints.ct) + ")");
	}

	static function sTypeParamList(tabs:String, tl:Array<TypeParam>):String {
		return tl.length > 0 ? "<" + [for (t in tl) sTypeParam(tabs, t)].join(", ") + ">" : "";
	}

	static function sFuncArg(tabs:String, a:FunctionArg):String {
		return a.opt ? "?" : "" + a.name.name + sOptTypeHint(tabs, a.type, ":") + sOptExpr(tabs, a.value, " = ");
	}

	static function sVar(tabs:String, v:EVar):String {
		var s = v.evName.name + sOptTypeHint(tabs, v.evType, ":") + sOptExpr(tabs, v.evExpr, " = ");
		return v.evMeta.length == 0 ? s : [for (m in v.evMeta) sMetadata(tabs, m)].join(" ") + " " + s;
	}

	static function sCase(tabs:String, cs:SwitchCase):String {
		return "case " + sExprList(tabs, cs.values, ", ")
			+ (cs.guard == null ? ":" : " if (" + sExprInner(tabs, cs.guard) + "):")
			+ (cs.expr == null ? "" : sExprOmitBlock(tabs, cs.expr));
	}

	static function sCatch(tabs:String, c:Catch):String {
		var hint = c.type == null ? "" : ":" + sComplexType(tabs, c.type.ct);
		return " catch(" + c.name.name + hint + ") " + sExprInner(tabs, c.expr);
	}

	static function sBlock(tabs:String, el:Array<Expr>, opn:String, nl:String, cls:String):String {
		return opn + "\n\t" + tabs + sExprList(tabs + "\t", el, ";\n\t" + tabs) + ";" + nl + tabs + cls;
	}

	static function sExprOmitBlock(tabs:String, e:Expr):String {
		return switch e.expr {
			case EBlock([]): "";
			case EBlock(el): sBlock(tabs + "\t", el, "", "", "");
			case _: sExprInner(tabs + "\t", e) + ";";
		}
	}

	public static function sExpr(e:Expr):String {
		return sExprInner("", e);
	}
}
