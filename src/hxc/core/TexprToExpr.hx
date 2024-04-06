package hxc.core;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals.Path;

class TexprToExpr {
	// Raised when a type has no syntactic form (an open monomorph).
	static function exit():Dynamic throw new hxc.core.ExitException();

	static function mkTypePath(p:Path, ?sub:String, ?params:Array<TypeParamOrConst>):TypePath {
		return {tpackage: p.pack, tname: p.name, tparams: params == null ? [] : params, tsub: sub};
	}

	// The module path carries the dot path, a sub-type keeps its own name in tsub.
	static function tpath(p:Path, mp:Path, pl:Array<TypeParamOrConst>):ComplexType {
		return if (mp.name == p.name) CTPath(mkTypePath(p, pl));
		else CTPath(mkTypePath(mp, p.name, pl));
	}

	public static function convertType(t:T):ComplexType {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null: exit();
					case some: convertType(some);
				}
			case TInst(c, tl) if (c.isPrivate):
				CTPath(mkTypePath({pack: [], name: c.path.name}, [for (x in tl) tparam(x)]));
			case TEnum(e, tl) if (e.isPrivate):
				CTPath(mkTypePath({pack: [], name: e.path.name}, [for (x in tl) tparam(x)]));
			case TType(td, tl) if (td.isPrivate):
				CTPath(mkTypePath({pack: [], name: td.path.name}, [for (x in tl) tparam(x)]));
			case TAbstract(a, tl) if (a.isPrivate):
				CTPath(mkTypePath({pack: [], name: a.path.name}, [for (x in tl) tparam(x)]));
			case TEnum(e, pl):
				tpath(e.path, e.module != null ? e.module.path : e.path, [for (x in pl) tparam(x)]);
			case TInst(c = {kind: KExpr(_)}, pl):
				tpath({pack: [], name: c.path.name}, {pack: [], name: c.path.name}, [for (x in pl) tparam(x)]);
			case TInst(c = {kind: KTypeParameter(_)}, pl):
				tpath({pack: [], name: c.path.name}, {pack: [], name: c.path.name}, [for (x in pl) tparam(x)]);
			case TInst(c, pl):
				tpath(c.path, c.module != null ? c.module.path : c.path, [for (x in pl) tparam(x)]);
			case TType(td, pl):
				if (td.path.name.length > 0 && td.path.name.charCodeAt(0) == "#".code)
					convertType(TypeFunctions.follow(t));
				else
					tpath(td.path, td.module != null ? td.module.path : td.path, [for (x in pl) tparam(x)]);
			case TAbstract(a, pl):
				tpath(a.path, a.module != null ? a.module.path : a.path, [for (x in pl) tparam(x)]);
			case TFun(sig):
				CTFunction([for (arg in sig.args) {
					var ct = convertTypeHint(arg.t);
					if (arg.name != "") ct = {ct: CTNamed({name: arg.name, pos: Position.nullPos}, ct), pos: Position.nullPos};
					if (arg.opt) ct = {ct: CTOptional(ct), pos: Position.nullPos};
					ct;
				}], convertTypeHint(sig.ret));
			case TAnon(a):
				switch (a.status.get()) {
					case Statics(c):
						tpath({pack: [], name: "Class"}, {pack: [], name: "Class"},
							[TPType({ct: tpath(c.path, c.path, []), pos: Position.nullPos})]);
					case EnumStatics(e):
						tpath({pack: [], name: "Enum"}, {pack: [], name: "Enum"},
							[TPType({ct: tpath(e.path, e.path, []), pos: Position.nullPos})]);
					case _:
						CTAnonymous([for (name in a.fields.keys()) anonField(a.fields.get(name))]);
				}
			case TDynamic(null):
				tpath({pack: [], name: "Dynamic"}, {pack: [], name: "Dynamic"}, []);
			case TDynamic(t2):
				tpath({pack: [], name: "Dynamic"}, {pack: [], name: "Dynamic"}, [tparam(t2)]);
			case TLazy(f):
				convertType(TypeFunctions.lazyType(f));
		}
	}

	static function anonField(f:TClassField):ClassField {
		var access:Array<PlacedAccess> = [];
		inline function add(a:Access):Void access.unshift({access: a, pos: Position.nullPos});
		if (TypeFunctions.hasClassFieldFlag(f, CfPublic)) add(APublic) else add(APrivate);
		if (TypeFunctions.hasClassFieldFlag(f, CfFinal)) add(AFinal);
		if (TypeFunctions.hasClassFieldFlag(f, CfExtern)) add(AExtern);
		var kind:ClassFieldKind = switch [f.kind, TypeFunctions.follow(f.type)] {
			case [Var(v), _]:
				function accString(va:VarAccess, getOrSet:String):String {
					return switch (va) {
						case AccNormal | AccCtor | AccInline | AccRequire(_, _): "default";
						case AccNo: "null";
						case AccNever: "never";
						case AccCall: getOrSet;
					}
				}
				FProp({name: accString(v.read, "get"), pos: Position.nullPos},
					{name: accString(v.write, "set"), pos: Position.nullPos},
					mkTypeHint(f.type, Position.nullPos), null);
			case [Method(_), TFun(sig)]:
				FFun({
					fParams: [],
					fArgs: [for (arg in sig.args) ({
						name: {name: arg.name, pos: Position.nullPos},
						opt: arg.opt,
						meta: [],
						type: convertTypeHint(arg.t),
						value: null
					} : FunctionArg)],
					fType: convertTypeHint(sig.ret),
					fExpr: null
				});
			case _:
				exit();
		};
		return {
			cffName: {name: f.name, pos: Position.nullPos},
			cffDoc: f.doc,
			cffPos: f.pos,
			cffMeta: f.meta,
			cffAccess: access,
			cffKind: kind
		};
	}

	static function convertTypeHint(t:T):TypeHint {
		return {ct: convertType(t), pos: Position.nullPos};
	}

	static function tparam(t:T):TypeParamOrConst {
		return switch (t) {
			case TInst({kind: KExpr(e)}, _): TPExpr(e);
			case _: TPType(convertTypeHint(t));
		}
	}

	// An open monomorph carries no hint.
	public static function mkTypeHint(t:T, p:Position):Null<TypeHint> {
		return switch (TypeFunctions.follow(t)) {
			case TMono(_): null;
			case _: try {ct: convertType(t), pos: p} catch (_:hxc.core.ExitException) null;
		}
	}

	static function exprOfTypePath(p:Path, pos:Position):Expr {
		if (p.pack.length == 0) return new Expr(EConst(CIdent(p.name)), pos);
		var e = new Expr(EConst(CIdent(p.pack[0])), pos);
		for (i in 1...p.pack.length) e = new Expr(EField(e, p.pack[i], EFNormal), pos);
		return new Expr(EField(e, p.name, EFNormal), pos);
	}

	public static function convertExpr(e:TExpr):Expr {
		function fullTypePath(t:ModuleType):Path {
			var mp:Path, p:Path;
			switch (t) {
				case TClassDecl(c): mp = c.module != null ? c.module.path : c.path; p = c.path;
				case TEnumDecl(en): mp = en.module != null ? en.module.path : en.path; p = en.path;
				case TAbstractDecl(a): mp = a.module != null ? a.module.path : a.path; p = a.path;
				case TTypeDecl(td): mp = td.module != null ? td.module.path : td.path; p = td.path;
			}
			return if (mp.name == p.name) p else {pack: mp.pack.concat([mp.name]), name: p.name};
		}
		inline function mkIdent(n:String):String return n == "`trace" ? "trace" : n;
		inline function eopt(eo:Null<TExpr>):Null<Expr> return eo == null ? null : convertExpr(eo);
		var p = e.pos;
		var def:ExprDef = switch (e.expr) {
			case TConst(c):
				EConst(TypeFunctions.tconstToConst(c));
			case TLocal(v):
				EConst(CIdent(mkIdent(v.name)));
			case TArray(e1, e2):
				EArray(convertExpr(e1), convertExpr(e2));
			case TBinop(op, e1, e2):
				EBinop(op, convertExpr(e1), convertExpr(e2));
			case TField(e1, f):
				EField(convertExpr(e1), TypeFunctions.fieldName(f), EFNormal);
			case TTypeExpr(t):
				exprOfTypePath(fullTypePath(t), e.pos).expr;
			case TParenthesis(e1):
				EParenthesis(convertExpr(e1));
			case TObjectDecl(fl):
				EObjectDecl([for (f in fl) {name: f.key.name, expr: convertExpr(f.expr), quotes: f.key.quotes, pos: f.key.pos}]);
			case TArrayDecl(el):
				EArrayDecl([for (x in el) convertExpr(x)]);
			case TCall(e1, el):
				ECall(convertExpr(e1), [for (x in el) convertExpr(x)]);
			case TNew(c, pl, el):
				var ct = try convertType(TInst(c, pl)) catch (_:hxc.core.ExitException) convertType(TInst(c, []));
				var tp = switch (ct) { case CTPath(tp2): tp2; case _: exit(); };
				ENew({path: tp, pos: Position.nullPos}, [for (x in el) convertExpr(x)]);
			case TUnop(op, flag, e1):
				EUnop(op, flag, convertExpr(e1));
			case TFunction(f):
				EFunction(FKAnonymous, {
					fParams: [],
					fArgs: [for (a in f.args) ({
						name: {name: a.v.name, pos: a.v.pos},
						opt: false,
						meta: a.v.meta,
						type: mkTypeHint(a.v.type, Position.nullPos),
						value: a.c == null ? null : convertExpr(a.c)
					} : FunctionArg)],
					fType: mkTypeHint(f.type, Position.nullPos),
					fExpr: convertExpr(f.expr)
				});
			case TVarExpr(v, eo):
				EVars([Ast.mkEvar({name: v.name, pos: v.pos}, mkTypeHint(v.type, v.pos),
					eopt(eo), TypeFunctions.hasVarFlag(v, VFinal), false, v.meta)]);
			case TBlock(el):
				EBlock([for (x in el) convertExpr(x)]);
			case TFor(v, it, e1):
				var ein = new Expr(EBinop(OpIn, new Expr(EConst(CIdent(v.name)), it.pos), convertExpr(it)), it.pos);
				EFor(ein, convertExpr(e1));
			case TIf(c, e1, e2):
				EIf(convertExpr(c), convertExpr(e1), eopt(e2));
			case TWhile(e1, e2, flag):
				EWhile(convertExpr(e1), convertExpr(e2), flag);
			case TSwitch(subj, cases, def2):
				var scases:Array<SwitchCase> = [for (c in cases) {
					values: [for (v in c.values) convertExpr(v)],
					guard: null,
					expr: c.expr.expr.match(TBlock([])) ? null : convertExpr(c.expr),
					pos: c.expr.pos
				}];
				var d = switch (eopt(def2)) {
					case null: null;
					case {expr: EBlock([])}: {e: null, pos: Position.nullPos};
					case conv: {e: conv, pos: conv.pos};
				};
				ESwitch(convertExpr(subj), scases, d);
			case TEnumIndex(_) | TEnumParameter(_, _, _):
				// Considered complex; the AST rides in TMeta(Meta.Ast).
				exit();
			case TTry(e1, catches):
				ETry(convertExpr(e1), [for (c in catches) {
					var ct = {ct: convertType(c.v.type), pos: Position.nullPos};
					var ce = convertExpr(c.expr);
					({name: {name: c.v.name, pos: c.v.pos}, type: ct, expr: ce, pos: ce.pos} : Catch);
				}]);
			case TReturn(eo):
				EReturn(eopt(eo));
			case TBreak:
				EBreak;
			case TContinue:
				EContinue;
			case TThrow(e1):
				EThrow(convertExpr(e1));
			case TCast(e1, mto):
				var th:Null<TypeHint> = switch (mto) {
					case null: null;
					case mt:
						var t2:T = switch (mt) {
							case TClassDecl(c): TInst(c, []);
							case TEnumDecl(en): TEnum(en, []);
							case TTypeDecl(td): TType(td, []);
							case TAbstractDecl(a): TAbstract(a, []);
						}
						{ct: convertType(t2), pos: Position.nullPos};
				}
				ECast(convertExpr(e1), th);
			case TMeta(m, _) if (m.name == ":ast" && m.params.length == 1):
				m.params[0].expr;
			case TMeta(m, e1):
				EMeta(m, convertExpr(e1));
			case TIdent(s):
				EConst(CIdent(s));
		}
		return new Expr(def, p);
	}
}
