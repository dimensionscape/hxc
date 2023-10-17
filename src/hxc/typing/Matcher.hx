package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.TexprTools;
import hxc.core.WithType;
import hxc.core.Globals;
import hxc.core.TypingError;

// Signals that a decision-tree column holds an extractor pattern; compile catches it and routes to
// compileExtractors. Extractor.
private class MatchExtractor extends haxe.Exception {
	public function new() super("match-extractor");
}

enum ConKind {
	ConConst(c:TConstant);
	ConEnum(e:TEnum, ef:TEnumField);
	ConStatic(c:TClass, cf:TClassField);
	ConTypeExpr(mt:ModuleType);
	ConFields(fields:Array<String>);
	ConArray(i:Int);
}

typedef Con = {kind:ConKind, pos:Position};

class Constructor {
	public static inline function make(kind:ConKind, pos:Position):Con {
		return {kind: kind, pos: pos};
	}

	static function sConst(ct:TConstant):String {
		return switch (ct) {
			case TInt(i): Std.string(i);
			case TFloat(f): f;
			case TString(s): '"' + s + '"';
			case TBool(b): b ? "true" : "false";
			case TNull: "null";
			case TThis: "this";
			case TSuper: "super";
		};
	}

	static function constEq(a:TConstant, b:TConstant):Bool {
		return switch ([a, b]) {
			case [TInt(i1), TInt(i2)]: i1 == i2;
			case [TFloat(f1), TFloat(f2)]: f1 == f2;
			case [TString(s1), TString(s2)]: s1 == s2;
			case [TBool(b1), TBool(b2)]: b1 == b2;
			case [TNull, TNull] | [TThis, TThis] | [TSuper, TSuper]: true;
			case _: false;
		};
	}

	public static function toString(con:Con):String {
		return switch (con.kind) {
			case ConConst(ct): sConst(ct);
			case ConEnum(_, ef): ef.name;
			case ConStatic(c, cf):
				var path = switch (c.kind) { case KAbstractImpl(a): a.path; case _: c.path; };
				Globals.sTypePath(path) + "." + cf.name;
			case ConTypeExpr(mt): Globals.sTypePath(TypeFunctions.tInfos(mt).path);
			case ConFields(fields): "{ " + fields.join(", ") + " }";
			case ConArray(i): "<array " + i + ">";
		};
	}

	// Equal (physical equality for enum/class/type; structural for constants).
	public static function equal(con1:Con, con2:Con):Bool {
		return switch ([con1.kind, con2.kind]) {
			case [ConConst(ct1), ConConst(ct2)]: constEq(ct1, ct2);
			case [ConEnum(en1, ef1), ConEnum(en2, ef2)]: en1 == en2 && ef1 == ef2;
			case [ConStatic(c1, cf1), ConStatic(c2, cf2)]: c1 == c2 && cf1 == cf2;
			case [ConTypeExpr(mt1), ConTypeExpr(mt2)]: mt1 == mt2;
			case [ConFields(_), ConFields(_)]: true;
			case [ConArray(i1), ConArray(i2)]: i1 == i2;
			case _: false;
		};
	}

	public static function arity(con:Con):Int {
		return switch (con.kind) {
			case ConEnum(_, ef): switch (ef.type) { case TFun(sig): sig.args.length; case _: 0; };
			case ConConst(_): 0;
			case ConFields(fields): fields.length;
			case ConArray(i): i;
			case ConTypeExpr(_): 0;
			case ConStatic(_, _): 0;
		};
	}

	// Compare (ordering for the decision-tree tables).
	public static function compare(con1:Con, con2:Con):Int {
		inline function cmpStr(a:String, b:String):Int return a < b ? -1 : (a > b ? 1 : 0);
		return switch ([con1.kind, con2.kind]) {
			case [ConConst(ct1), ConConst(ct2)]: cmpStr(sConst(ct1), sConst(ct2));
			case [ConEnum(_, ef1), ConEnum(_, ef2)]: ef1.index - ef2.index;
			case [ConStatic(_, cf1), ConStatic(_, cf2)]: cmpStr(cf1.name, cf2.name);
			case [ConTypeExpr(mt1), ConTypeExpr(mt2)]: cmpStr(Globals.sTypePath(TypeFunctions.tInfos(mt1).path), Globals.sTypePath(TypeFunctions.tInfos(mt2).path));
			case [ConFields(_), ConFields(_)]: 0;
			case [ConArray(i1), ConArray(i2)]: i1 - i2;
			case _: -1;
		};
	}

	public static function toTexpr(ctx:TyperContext, matchDebug:Bool, con:Con):TExpr {
		var p = con.pos;
		var basic = ctx.com.basic;
		return switch (con.kind) {
			case ConEnum(_, ef):
				matchDebug ? TexprTools.makeString(basic, ef.name, p) : TexprTools.makeInt(basic, ef.index, p);
			case ConConst(ct): TexprTools.makeConstTexpr(basic, ct, p);
			case ConArray(i): TexprTools.makeInt(basic, i, p);
			case ConStatic(c, cf): TexprTools.makeStaticField(c, cf, p);
			case ConTypeExpr(mt): TexprTools.makeTypeExpr(mt, p);
			case ConFields(_): throw new TypingError("Something went wrong", p);
		};
	}
}

enum PatKind {
	PatConstructor(con:Con, patterns:Array<Pattern>);
	PatVariable(v:TVar);
	PatAny;
	PatBind(v:TVar, pat:Pattern);
	PatOr(a:Pattern, b:Pattern);
	PatTuple(patterns:Array<Pattern>);
	PatExtractor(v:TVar, e:TExpr, pat:Pattern);
}

typedef Pattern = {pat:PatKind, pos:Position};
typedef UnappliedTypeParam = {m:TMono, old:Null<T>};

class PatternContext {
	public var ctx:TyperContext;
	public var orLocals:Null<Map<String, {v:TVar, p:Position}>>;
	public var ctxLocals:Map<String, TVar>;
	public var currentLocals:Map<String, {v:TVar, p:Position}>;
	public var inReification:Bool;
	public var isPostfixMatch:Bool;
	public var unapplyTypeParameters:Void->Array<UnappliedTypeParam>;

	public function new(ctx:TyperContext, ctxLocals:Map<String, TVar>) {
		this.ctx = ctx;
		this.orLocals = null;
		this.ctxLocals = ctxLocals;
		this.currentLocals = new Map();
		this.inReification = false;
		this.isPostfixMatch = false;
		this.unapplyTypeParameters = function() return [];
	}
}

private class TypeParameterFrame {
	public static function unapply(params:TypeParams, monos:TParams):Array<UnappliedTypeParam> {
		var out:Array<UnappliedTypeParam> = [];
		var len = params.length < monos.length ? params.length : monos.length;
		for (i in 0...len) switch [monos[i], TypeFunctions.follow(monos[i])] {
			case [TMono(m), TMono(_)]:
				out.push({m: m, old: m.type});
				TypeUnification.monoBind(m, params[i].type);
			case _:
		}
		return out;
	}

	public static function reapply(unapplied:Array<UnappliedTypeParam>):Void {
		for (u in unapplied) switch (u.old) {
			case null: TypeUnification.unbind(u.m);
			case t: TypeUnification.monoBind(u.m, t);
		}
	}
}

class PatternMaker {
	static function unify(ctx:TyperContext, a:T, b:T, p:Position):Void {
		try TypeUnification.unifyDefault(a, b) catch (e:UnifyError) throw new TypingError(hxc.core.TPrinting.betterErrorMessage(e.errors), p);
	}

	static function addLocal(pctx:PatternContext, isFinal:Bool, name:String, t:T, p:Position):TVar {
		var isWildcard = name == "_";
		if (!isWildcard && pctx.isPostfixMatch) throw new TypingError("Pattern variables are not allowed in .match patterns", p);
		if (!isWildcard && pctx.currentLocals.exists(name)) throw new TypingError("Variable " + name + " is bound multiple times", p);
		if (pctx.orLocals != null && !isWildcard) {
			var entry = pctx.orLocals.get(name);
			if (entry == null) throw new TypingError("Variable " + name + " must appear exactly once in each sub-pattern", p);
			var v = entry.v;
			unify(pctx.ctx, t, v.type, p);
			if (isFinal) TypeFunctions.addVarFlag(v, VFinal);
			pctx.currentLocals.set(name, {v: v, p: p});
			return v;
		}
		var v = TypeFunctions.allocVar(VUser(TVOPatternVariable), name, t, p);
		if (isFinal) TypeFunctions.addVarFlag(v, VFinal);
		pctx.currentLocals.set(name, {v: v, p: p});
		pctx.ctx.locals.set(name, v);
		return v;
	}

	static function getGeneralModuleType(ctx:TyperContext, mt:ModuleType, p:Position):T {
		function load(name:String):T {
			return Typeload.loadInstance(ctx.com, ctx.typeParams, {tpackage: [], tname: name, tparams: [], tsub: null}, p, true);
		}
		return switch (mt) {
			case TClassDecl(_): load("Class");
			case TEnumDecl(_): load("Enum");
			case TAbstractDecl(a) if (TypeFunctions.hasMeta(":runtimeValue", a.meta)): load("Class");
			case TTypeDecl(_):
				switch (TypeFunctions.follow(TypeFunctions.typeOfModuleType(mt))) {
					case TInst(c, _): getGeneralModuleType(ctx, TClassDecl(c), p);
					case TEnum(en, _): getGeneralModuleType(ctx, TEnumDecl(en), p);
					case TAbstract(a, _): getGeneralModuleType(ctx, TAbstractDecl(a), p);
					case _: throw new TypingError("Cannot use this type as a value", p);
				}
			case _:
				throw new TypingError("Cannot use this type as a value", p);
		}
	}

	static function unifyTypePattern(ctx:TyperContext, mt:ModuleType, t:T, p:Position):Void {
		var tcl = switch (TypeFunctions.follow(getGeneralModuleType(ctx, mt, p))) {
			case TAbstract(a, _): TAbstract(a, [TypeFunctions.mkMono()]);
			case other: other;
		};
		unify(ctx, tcl, t, p);
	}

	// A typed value pattern may be wrapped by an implicit abstract cast (e.g. an enum-abstract value whose
	// stored constant is `cast N`), a metadata node, or parentheses; the constant/ctor to match on is
	// underneath.
	static function skipValue(e:TExpr):TExpr {
		return switch (e.expr) {
			case TCast(e1, null): skipValue(e1);
			case TMeta(_, e1): skipValue(e1);
			case TParenthesis(e1): skipValue(e1);
			case _: e;
		};
	}

	static function handleIdent(pctx:PatternContext, t:T, i:String, p:Position):PatKind {
		function checkTyped(e:TExpr):Null<PatKind> {
			return switch (skipValue(e).expr) {
				case TConst(ct): unify(pctx.ctx, e.type, t, p); PatConstructor(Constructor.make(ConConst(ct), p), []);
				case TField(_, FEnum(en, ef)): unify(pctx.ctx, e.type, t, p); PatConstructor(Constructor.make(ConEnum(en, ef), p), []);
				case TField(_, FStatic(c, cf)): unify(pctx.ctx, e.type, t, p); PatConstructor(Constructor.make(ConStatic(c, cf), p), []);
				case TTypeExpr(mt): unifyTypePattern(pctx.ctx, mt, t, p); PatConstructor(Constructor.make(ConTypeExpr(mt), p), []);
				case _: null;
			};
		}
		try {
			var e = Typer.typeExpr(pctx.ctx, new Expr(EConst(CIdent(i)), p), WithTypeTools.withType(t));
			var pat = checkTyped(e);
			if (pat != null) return pat;
		} catch (_:TypingError) {}
		// An ident that typed to a non-pattern value (e.g. a same-named local) or failed to type is
		// resolved as a field of the subject's module type (an enum-abstract constant), and only captures
		// when that fails too. .
		try {
			var mt = TypeFunctions.moduleTypeOfType(t);
			var emt = TexprTools.makeTypeExpr(mt, p);
			var acc = Fields.typeField(pctx.ctx, emt, i, p, MGet, WithTypeTools.value);
			var pat = checkTyped(Typer.accGet(pctx.ctx, acc));
			if (pat != null) return pat;
		} catch (_:Dynamic) {}
		var v = addLocal(pctx, false, i, t, p);
		return PatVariable(v);
	}

	public static function make(pctx:PatternContext, toplevel:Bool, t:T, e:Expr):Pattern {
		var ctx = pctx.ctx;
		var p = e.pos;
		var basic = ctx.com.basic;
		function unifyExpected(t2:T) unify(ctx, t2, t, p);

		var kind:PatKind = switch (e.expr) {
			case EParenthesis(e1) | ECast(e1, null):
				return make(pctx, toplevel, t, e1);
			case ECheckType(e1, {ct: CTPath(tp)}) if (tp.tpackage.length == 2 && tp.tpackage[0] == "haxe" && tp.tpackage[1] == "macro" && tp.tname == "Expr" && tp.tsub == null):
				// `case (macro EXPR : haxe.macro.Expr)`: a reification pattern matches against the reified
				// AST. Position fields are ignored from here on.
				var old = pctx.inReification;
				pctx.inReification = true;
				var r = make(pctx, toplevel, t, e1);
				pctx.inReification = old;
				return r;
			case EConst(CInt(_, _)) | EConst(CFloat(_, _)) | EConst(CString(_, _)) | EConst(CIdent("true")) | EConst(CIdent("false")) | EConst(CIdent("null")):
				var ce = TexprTools.typeConstant(basic, switch (e.expr) { case EConst(c): c; case _: throw "unreachable"; }, p);
				unifyExpected(ce.type);
				switch (ce.expr) {
					case TConst(ct): PatConstructor(Constructor.make(ConConst(ct), p), []);
					case _: throw new TypingError("Unrecognized constant pattern", p);
				}
			case EConst(CIdent(i)):
				if (i == "_") PatAny else handleIdent(pctx, t, i, p);
			case EVars([ev]) if (ev.evType == null && ev.evExpr == null):
				var v = addLocal(pctx, ev.evFinal, ev.evName.name, t, ev.evName.pos);
				PatVariable(v);
			case EBinop(OpOr, e1, e2):
				var pctx1 = clone(pctx);
				pctx1.currentLocals = new Map();
				var pat1 = make(pctx1, toplevel, t, e1);
				var pctx2 = clone(pctx);
				pctx2.currentLocals = new Map();
				pctx2.orLocals = pctx1.currentLocals;
				var pat2 = make(pctx2, toplevel, t, e2);
				for (name in pctx1.currentLocals.keys()) {
					var entry = pctx1.currentLocals.get(name);
					if (!pctx2.currentLocals.exists(name) && name != "_") throw new TypingError("Variable " + name + " must appear exactly once in each sub-pattern", entry.p);
					pctx.currentLocals.set(name, entry);
				}
				PatOr(pat1, pat2);
			case EBinop(OpAssign, e1, e2):
				switch (e1.expr) {
					case EConst(CIdent(s)):
						var v = addLocal(pctx, false, s, t, e1.pos);
						var pat = make(pctx, false, t, e2);
						PatBind(v, pat);
					case EParenthesis(inner):
						return make(pctx, toplevel, t, new Expr(EBinop(OpAssign, inner, e2), p));
					case _:
						throw new TypingError("Unrecognized pattern", p);
				}
			case EBinop(OpArrow, e1, e2):
				// Extractor pattern `expr => subpattern`: bind `_` to the subject, type the extractor
				// expression, then match subpattern against its result type.
				var restore = Typer.saveLocals(ctx);
				ctx.locals = pctx.ctxLocals.copy();
				var v = Typer.addLocal(ctx, VGenerated, "_", t, p);
				var unapplied = pctx.unapplyTypeParameters();
				var te1 = try Typer.typeExpr(ctx, e1, WithTypeTools.value) catch (ex:Dynamic) {
					TypeParameterFrame.reapply(unapplied);
					restore();
					throw ex;
				};
				TypeParameterFrame.reapply(unapplied);
				v.name = "tmp";
				restore();
				var pat = make(pctx, toplevel, te1.type, e2);
				return {pat: PatExtractor(v, te1, pat), pos: p};
			case EArrayDecl(el):
				var et = switch (TypeFunctions.follow(t)) { case TInst(_, [x]): x; case _: TypeFunctions.tDynamic; };
				PatConstructor(Constructor.make(ConArray(el.length), p), [for (e2 in el) make(pctx, false, et, e2)]);
			case EObjectDecl(fields):
				// Structure pattern: match named fields against the expected anon type. Fields the pattern
				// omits are filled with wildcards so every structure pattern for the type carries the same
				// field set (and arity) -- the matcher then treats them as one constructor. (record fill).
				var anonFields = switch (TypeFunctions.follow(t)) { case TAnon(a): a.fields; case _: null; };
				var mentioned = new Map<String, Expr>();
				for (f in fields) mentioned.set(f.name, f.expr);
				var allNames = anonFields == null ? [for (f in fields) f.name] : [for (k in anonFields.keys()) k];
				var pairs = [for (name in allNames) {
					var cf = anonFields == null ? null : anonFields.get(name);
					var fe = mentioned.get(name);
					// An omitted field, or a reification position field (carries no matchable info), is a wildcard.
					var sub = if (fe == null || (pctx.inReification && (name == "pos" || name == "posPath" || name == "namePos")))
						({pat: PatAny, pos: fe == null ? p : fe.pos} : Pattern)
						else make(pctx, false, cf != null ? cf.type : TypeFunctions.tDynamic, fe);
					{name: name, sub: sub};
				}];
				pairs.sort(function(a2, b2) return a2.name < b2.name ? -1 : (a2.name > b2.name ? 1 : 0));
				PatConstructor(Constructor.make(ConFields([for (pr in pairs) pr.name]), p), [for (pr in pairs) pr.sub]);
			case ECall(ec, el):
				var head = Typer.typeExpr(ctx, ec, WithTypeTools.withType(t));
				switch (head.expr) {
					case TField(_, FEnum(en, ef)):
						switch (TypeFunctions.follow(head.type)) {
							case TFun(sig):
								var headTl = switch (TypeFunctions.follow(sig.ret)) {
									case TEnum(_, tl): tl;
									case _: throw new TypingError("This pattern is not yet ported", p);
								};
								var declaredTl = switch (TypeFunctions.follow(ef.type)) {
									case TFun(declared):
										switch (TypeFunctions.follow(declared.ret)) {
											case TEnum(_, tl): tl;
											case _: headTl;
										}
									case _: headTl;
								};
								var enumParams = TypeFunctions.extractParamTypes(en.params);
								var tl = [for (i in 0...headTl.length) {
									var declared = i < declaredTl.length ? declaredTl[i] : headTl[i];
									var param = i < enumParams.length ? enumParams[i] : null;
									param != null && declared == param ? headTl[i] : declared;
								}];
								function mapEnum(x:T):T return TypeFunctions.applyParams(en.params, tl, x);
								var monos = TypeUnification.spawnConstrainedMonos(mapEnum, ef.params);
								function map(x:T):T return mapEnum(TypeFunctions.applyParams(ef.params, monos, x));
								unify(ctx, map(ef.type), head.type, head.pos);
								var args = switch (TypeFunctions.follow(head.type)) {
									case TFun(sig2):
										unifyExpected(sig2.ret);
										sig2.args;
									case _: throw new TypingError("This pattern is not yet ported", p);
								};
								// A single `_` argument matches every constructor argument; otherwise match
								// positionally, filling omitted trailing optional args with wildcards.
								var single = el.length == 1 && (switch (el[0].expr) { case EConst(CIdent("_")): true; case _: false; });
								var subs:Array<Pattern> = [];
								var ei = 0;
								for (ai in 0...args.length) {
									if (single) subs.push({pat: PatAny, pos: el[0].pos});
									else if (ei < el.length) { subs.push(make(pctx, false, args[ai].t, el[ei])); ei++; }
									else if (args[ai].opt) subs.push({pat: PatAny, pos: p});
									else throw new TypingError("Not enough arguments", p);
								}
								if (!single && ei < el.length) throw new TypingError("Too many arguments", p);
								TypeParameterFrame.unapply(ef.params, monos);
								PatConstructor(Constructor.make(ConEnum(en, ef), p), subs);
							case _: throw new TypingError("This pattern is not yet ported", p);
						}
					case _: throw new TypingError("This pattern is not yet ported", p);
				}
			case EField(_, _, _):
				// A qualified value pattern (Type.Const / Type.EnumCtor / static const) matches by value.
				var te = try Typer.typeExpr(ctx, e, WithTypeTools.withType(t)) catch (_:TypingError) null;
				if (te == null) throw new TypingError("This pattern is not yet ported", p);
				switch (skipValue(te).expr) {
					case TConst(ct): unifyExpected(te.type); PatConstructor(Constructor.make(ConConst(ct), p), []);
					case TField(_, FEnum(en, ef)): unifyExpected(te.type); PatConstructor(Constructor.make(ConEnum(en, ef), p), []);
					case TField(_, FStatic(c, cf)): unifyExpected(te.type); PatConstructor(Constructor.make(ConStatic(c, cf), p), []);
					case TTypeExpr(mt): unifyTypePattern(ctx, mt, t, p); PatConstructor(Constructor.make(ConTypeExpr(mt), p), []);
					case _: throw new TypingError("This pattern is not yet ported", p);
				}
			case _:
				throw new TypingError("This pattern is not yet ported", p);
		};
		return {pat: kind, pos: p};
	}

	static function clone(pctx:PatternContext):PatternContext {
		var c = new PatternContext(pctx.ctx, pctx.ctxLocals);
		c.orLocals = pctx.orLocals;
		c.currentLocals = pctx.currentLocals;
		c.inReification = pctx.inReification;
		c.isPostfixMatch = pctx.isPostfixMatch;
		return c;
	}
}

typedef Case = {guard:Null<TExpr>, expr:Null<TExpr>, pos:Position};

class CaseMaker {
	static function unify(ctx:TyperContext, a:T, b:T, p:Position):Void {
		try TypeUnification.unifyDefault(a, b) catch (e:UnifyError) throw new TypingError(hxc.core.TPrinting.betterErrorMessage(e.errors), p);
	}

	public static function make(ctx:TyperContext, t:T, el:Array<Expr>, eg:Null<Expr>, eoAst:Null<Expr>, withType:WithType, postfixMatch:Bool, p:Position):{c:Case, pat:Pattern} {
		if (el.length == 0) throw new TypingError("case without pattern", p);
		var e = el[el.length - 1];
		var i = el.length - 2;
		while (i >= 0) {
			e = new Expr(EBinop(OpOr, el[i], e), Position.union(el[i].pos, e.pos));
			i--;
		}
		var save = Typer.saveLocals(ctx);
		var monos:TParams = [for (_ in ctx.typeParams) TypeFunctions.mkMono()];
		function map(t:T):T return TypeFunctions.applyParams(ctx.typeParams, monos, t);
		var oldTypes:Array<{v:TVar, t:T}> = [];
		for (v in ctx.locals) {
			oldTypes.push({v: v, t: v.type});
			v.type = map(v.type);
		}
		var oldRet = ctx.ret;
		ctx.ret = map(ctx.ret);
		function cleanup() {
			ctx.ret = oldRet;
			for (old in oldTypes) old.v.type = old.t;
			save();
		}
		var pctx = new PatternContext(ctx, ctx.locals);
		pctx.isPostfixMatch = postfixMatch;
		pctx.unapplyTypeParameters = function() return TypeParameterFrame.unapply(ctx.typeParams, monos);
		var pat:Pattern;
		try {
			pat = PatternMaker.make(pctx, true, map(t), e);
			TypeParameterFrame.unapply(ctx.typeParams, monos);
		} catch (ex:Dynamic) {
			cleanup();
			throw ex;
		}
		var egT:Null<TExpr> = if (eg == null) null else {
			try {
				var ge = Typer.typeExpr(ctx, eg, WithTypeTools.value);
				Typer.castOrUnify(ctx, ctx.com.basic.tbool, ge, ge.pos);
			} catch (ex:Dynamic) {
				cleanup();
				throw ex;
			}
		};
		var eoT:Null<TExpr> = try {
			switch ([eoAst, withType]) {
				case [null, WithType(wt, _)]:
					unify(ctx, ctx.com.basic.tvoid, wt, e.pos);
					null;
				case [null, _]:
					null;
				case [body, WithType(wt, src)]:
					var mapped = map(wt);
					var be = Typer.typeExpr(ctx, body, WithType(mapped, src));
					Typer.castOrUnify(ctx, mapped, be, be.pos);
				case [body, _]:
					Typer.typeExpr(ctx, body, withType);
			}
		} catch (ex:Dynamic) {
			cleanup();
			throw ex;
		};
		cleanup();
		return {c: {guard: egT, expr: eoT, pos: p}, pat: pat};
	}

	// A tuple switch (`switch [a, b]`) matches each subject column separately: a `[p1..pn]` case
	// becomes n element patterns against the n subject types, and a bare `_` becomes n wildcards.
	public static function makeTuple(ctx:TyperContext, types:Array<T>, el:Array<Expr>, eg:Null<Expr>, eoAst:Null<Expr>, withType:WithType, postfixMatch:Bool, p:Position):{c:Case, pats:Array<Pattern>} {
		if (el.length == 0) throw new TypingError("case without pattern", p);
		if (el.length > 1) throw new TypingError("or-patterns over a tuple switch are not yet supported", p);
		var save = Typer.saveLocals(ctx);
		var monos:TParams = [for (_ in ctx.typeParams) TypeFunctions.mkMono()];
		function map(t:T):T return TypeFunctions.applyParams(ctx.typeParams, monos, t);
		var oldTypes:Array<{v:TVar, t:T}> = [];
		for (v in ctx.locals) {
			oldTypes.push({v: v, t: v.type});
			v.type = map(v.type);
		}
		var oldRet = ctx.ret;
		ctx.ret = map(ctx.ret);
		function cleanup() {
			ctx.ret = oldRet;
			for (old in oldTypes) old.v.type = old.t;
			save();
		}
		var pctx = new PatternContext(ctx, ctx.locals);
		pctx.isPostfixMatch = postfixMatch;
		pctx.unapplyTypeParameters = function() return TypeParameterFrame.unapply(ctx.typeParams, monos);
		var mappedTypes = [for (t in types) map(t)];
		var pats:Array<Pattern>;
		try {
			pats = switch (el[0].expr) {
				case EArrayDecl(elems) if (elems.length == mappedTypes.length):
					[for (i in 0...mappedTypes.length) PatternMaker.make(pctx, true, mappedTypes[i], elems[i])];
				case EConst(CIdent("_")):
					[for (i in 0...mappedTypes.length) ({pat: PatAny, pos: el[0].pos} : Pattern)];
				case _:
					throw new TypingError("tuple switch case must be a [..] pattern of arity " + mappedTypes.length, p);
			};
			TypeParameterFrame.unapply(ctx.typeParams, monos);
		} catch (ex:Dynamic) {
			cleanup();
			throw ex;
		}
		var egT:Null<TExpr> = if (eg == null) null else {
			try {
				var ge = Typer.typeExpr(ctx, eg, WithTypeTools.value);
				Typer.castOrUnify(ctx, ctx.com.basic.tbool, ge, ge.pos);
			} catch (ex:Dynamic) {
				cleanup();
				throw ex;
			}
		};
		var eoT:Null<TExpr> = try {
			switch ([eoAst, withType]) {
				case [null, WithType(wt, _)]: unify(ctx, ctx.com.basic.tvoid, wt, p); null;
				case [null, _]: null;
				case [body, WithType(wt, src)]:
					var mapped = map(wt);
					var be = Typer.typeExpr(ctx, body, WithType(mapped, src));
					Typer.castOrUnify(ctx, mapped, be, be.pos);
				case [body, _]: Typer.typeExpr(ctx, body, withType);
			}
		} catch (ex:Dynamic) {
			cleanup();
			throw ex;
		};
		cleanup();
		return {c: {guard: egT, expr: eoT, pos: p}, pats: pats};
	}
}

// The decision-tree node (mutable for goto/texpr memoization).
class Dt {
	public var t:DtKind;
	public var i:Int;
	public var pos:Position;
	public var gotoTarget:Bool;
	public var texpr:Null<TExpr>;
	public function new(t:DtKind, i:Int, p:Position) {
		this.t = t;
		this.i = i;
		this.pos = p;
		this.gotoTarget = false;
		this.texpr = null;
	}
}

enum DtKind {
	Leaf(c:Case);
	Switch(subject:TExpr, cases:Array<{con:Con, unguarded:Bool, dt:Dt}>, def:Dt);
	Bind(bindings:Array<Binding>, dt:Dt);
	Guard(e:TExpr, dt1:Dt, dt2:Dt);
	GuardNull(e:TExpr, dt1:Dt, dt2:Dt);
	Fail;
}

// A pattern-variable binding produced during compilation: bind v (at p) to the subject e.
typedef Binding = {v:TVar, p:Position, e:TExpr};

// One row of the pattern matrix during compilation: (case, accumulated bindings, the row patterns).
typedef MatchCase = {c:Case, bindings:Array<Binding>, patterns:Array<Pattern>};

class MatcherContext {
	public var ctx:TyperContext;
	public var matchPos:Position;
	public var matchDebug:Bool;
	public var count:Int;
	public function new(ctx:TyperContext, p:Position) {
		this.ctx = ctx;
		this.matchPos = p;
		this.matchDebug = false;
		this.count = 0;
	}
}

class DtCompile {
	static function makeList<A>(n:Int, x:A):Array<A> {
		return [for (_ in 0...n) x];
	}

	static function mkDt(mctx:MatcherContext, t:DtKind, p:Position):Dt {
		var d = new Dt(t, mctx.count, p);
		mctx.count++;
		return d;
	}

	public static function leaf(mctx:MatcherContext, c:Case):Dt return mkDt(mctx, Leaf(c), c.pos);
	public static function fail(mctx:MatcherContext, p:Position):Dt return mkDt(mctx, Fail, p);
	public static function switchDt(mctx:MatcherContext, subject:TExpr, cases:Array<{con:Con, unguarded:Bool, dt:Dt}>, def:Dt):Dt return mkDt(mctx, Switch(subject, cases, def), subject.pos);
	public static function bind(mctx:MatcherContext, bindings:Array<Binding>, dt:Dt):Dt return mkDt(mctx, Bind(bindings, dt), dt.pos);
	public static function guard(mctx:MatcherContext, e:TExpr, dt1:Dt, dt2:Dt):Dt return mkDt(mctx, Guard(e, dt1, dt2), Position.union(dt1.pos, dt2.pos));
	public static function guardNull(mctx:MatcherContext, e:TExpr, dt1:Dt, dt2:Dt):Dt return mkDt(mctx, GuardNull(e, dt1, dt2), Position.union(dt1.pos, dt2.pos));

	public static function specialize(subject:TExpr, con:Con, cases:Array<MatchCase>):Array<MatchCase> {
		var arity = Constructor.arity(con);
		var out:Array<MatchCase> = [];
		for (mc in cases) {
			var r = specializeRow(subject, con, arity, mc);
			if (r != null) out.push(r);
		}
		return out;
	}

	static function specializeRow(subject:TExpr, con:Con, arity:Int, mc:MatchCase):Null<MatchCase> {
		if (mc.patterns.length == 0) return null;
		var head = mc.patterns[0];
		var rest = mc.patterns.slice(1);
		return switch (head.pat) {
			case PatConstructor(con2, patterns1) if (Constructor.equal(con, con2)):
				{c: mc.c, bindings: mc.bindings, patterns: patterns1.concat(rest)};
			case PatVariable(v):
				{c: mc.c, bindings: [{v: v, p: head.pos, e: subject}].concat(mc.bindings), patterns: makeList(arity, {pat: PatAny, pos: head.pos}).concat(rest)};
			case PatAny:
				{c: mc.c, bindings: mc.bindings, patterns: makeList(arity, head).concat(rest)};
			case PatBind(v, pat1):
				specializeRow(subject, con, arity, {c: mc.c, bindings: [{v: v, p: head.pos, e: subject}].concat(mc.bindings), patterns: [pat1].concat(rest)});
			case _:
				null;
		};
	}

	public static function defaultMatrix(subject:TExpr, cases:Array<MatchCase>):Array<MatchCase> {
		var out:Array<MatchCase> = [];
		for (mc in cases) {
			var r = defaultRow(subject, mc);
			if (r != null) out.push(r);
		}
		return out;
	}

	static function defaultRow(subject:TExpr, mc:MatchCase):Null<MatchCase> {
		if (mc.patterns.length == 0) return null;
		var head = mc.patterns[0];
		var rest = mc.patterns.slice(1);
		return switch (head.pat) {
			case PatVariable(v):
				{c: mc.c, bindings: [{v: v, p: head.pos, e: subject}].concat(mc.bindings), patterns: rest};
			case PatAny:
				{c: mc.c, bindings: mc.bindings, patterns: rest};
			case PatBind(v, pat1):
				defaultRow(subject, {c: mc.c, bindings: [{v: v, p: head.pos, e: subject}].concat(mc.bindings), patterns: [pat1].concat(rest)});
			case _:
				null;
		};
	}

	public static function isWildcardPattern(pat:Pattern):Bool {
		return switch (pat.pat) {
			case PatVariable(_) | PatAny: true;
			case PatBind(_, pat1): isWildcardPattern(pat1);
			case _: false;
		};
	}

	// Expand (or-patterns, binds over sub-patterns, tuples).
	public static function expand(cases:Array<MatchCase>):Array<MatchCase> {
		var out:Array<MatchCase> = [];
		for (mc in cases) {
			for (r in expandRow(function(pat) return pat, mc)) out.push(r);
		}
		return out;
	}

	static function expandRow(f:Pattern->Pattern, mc:MatchCase):Array<MatchCase> {
		if (mc.patterns.length == 0) return [mc];
		var head = mc.patterns[0];
		var rest = mc.patterns.slice(1);
		return switch (head.pat) {
			case PatOr(pat1, pat2):
				expandRow(f, {c: mc.c, bindings: mc.bindings, patterns: [pat1].concat(rest)})
					.concat(expandRow(f, {c: mc.c, bindings: mc.bindings, patterns: [pat2].concat(rest)}));
			case PatBind(v, pat1):
				var p = head.pos;
				expandRow(function(pat2) return f({pat: PatBind(v, pat2), pos: p}), {c: mc.c, bindings: mc.bindings, patterns: [pat1].concat(rest)});
			case PatTuple(patterns1):
				expandRow(f, {c: mc.c, bindings: mc.bindings, patterns: patterns1.concat(rest)});
			case _:
				[{c: mc.c, bindings: mc.bindings, patterns: [f(head)].concat(rest)}];
		};
	}

	// Move the first column with a real constructor to the front.
	public static function selectColumn(subjects:Array<TExpr>, cases:Array<MatchCase>):{subjects:Array<TExpr>, cases:Array<MatchCase>} {
		function findCol(patterns:Array<Pattern>):Int {
			var i = 0;
			var ps = patterns;
			while (true) {
				if (ps.length == 0) return 0;
				switch (ps[0].pat) {
					case PatVariable(_) | PatAny | PatExtractor(_, _, _): i++; ps = ps.slice(1);
					case PatBind(_, pat1): ps = [pat1].concat(ps.slice(1));
					case _: return i;
				}
			}
		}
		var col = cases.length == 0 ? 0 : findCol(cases[0].patterns);
		if (col == 0) return {subjects: subjects, cases: cases};
		// Sort: selected column first, then the preceding columns reversed, then the
		// rest (applied identically to subjects and patterns so they stay aligned).
		function move<A>(l:Array<A>):Array<A> {
			var before = l.slice(0, col);
			before.reverse();
			return [l[col]].concat(before).concat(l.slice(col + 1));
		}
		return {
			subjects: move(subjects),
			cases: [for (mc in cases) {c: mc.c, bindings: mc.bindings, patterns: move(mc.patterns)}]
		};
	}

	// A fresh generated local (unique id from allocVar).
	static function genLocal(ctx:TyperContext, t:T, p:Position):TVar {
		return TypeFunctions.allocVar(VGenerated, "_hx_g", t, p);
	}

	static function isNullConst(con:Con):Bool {
		return switch (con.kind) { case ConConst(TNull): true; case _: false; };
	}

	static function getSubSubjects(mctx:MatcherContext, e:TExpr, con:Con, argPositions:Array<Position>):Array<TExpr> {
		return switch (con.kind) {
			case ConConst(_) | ConTypeExpr(_) | ConStatic(_, _): [];
			case ConEnum(en, ef):
				var pl = TypeUnification.spawnConstrainedMonos(function(t) return t, en.params);
				var ten = TEnum(en, pl);
				var subject = TypeUnification.typeIseqDefault(ten, e.type) ? e : TypeFunctions.mk(TCast(e, null), ten, e.pos);
				switch (TypeFunctions.follow(ef.type)) {
					case TFun(sig):
						[for (i in 0...sig.args.length) TypeFunctions.mk(TEnumParameter(subject, ef, i),
							TypeFunctions.applyParams(en.params, pl, TypeFunctions.monomorphs(ef.params, sig.args[i].t)),
							i < argPositions.length ? argPositions[i] : con.pos)];
					case _: [];
				}
			case ConArray(n):
				var et = switch (TypeFunctions.follow(e.type)) { case TInst(_, [t]): t; case _: TypeFunctions.tDynamic; };
				[for (i in 0...n) TypeFunctions.mk(TArray(e, TexprTools.makeInt(mctx.ctx.com.basic, i, e.pos)), et, i < argPositions.length ? argPositions[i] : con.pos)];
			case ConFields(fields):
				[for (i in 0...fields.length) {
					var name = fields[i];
					var p = i < argPositions.length ? argPositions[i] : con.pos;
					Typer.accGet(mctx.ctx, Fields.typeField(mctx.ctx, e, name, p, MGet, WithTypeTools.value));
				}];
		};
	}

	static function enumConstructorReturn(ef:TEnumField):T {
		return switch (TypeFunctions.follow(ef.type)) {
			case TFun(sig): sig.ret;
			case t: t;
		}
	}

	static function paramCompatible(subject:T, constructor:T):Bool {
		if (subject == constructor) return true;
		return switch (TypeFunctions.follow(subject)) {
			case TMono(_): true;
			case TInst(c, _):
				switch (c.kind) {
					case KTypeParameter(_): true;
					case _: TypeUnification.typeIseqDefault(subject, constructor);
				}
			case _: TypeUnification.typeIseqDefault(subject, constructor);
		}
	}

	public static function enumConstructorCompatible(subjectType:T, en:TEnum, ef:TEnumField):Bool {
		return switch [TypeFunctions.follow(subjectType), TypeFunctions.follow(enumConstructorReturn(ef))] {
			case [TEnum(se, stl), TEnum(re, rtl)] if (se == en && re == en && stl.length == rtl.length):
				for (i in 0...stl.length) if (!paramCompatible(stl[i], rtl[i])) return false;
				true;
			case [TEnum(se, _), _] if (se == en):
				true;
			case _:
				false;
		}
	}

	static function refineSubjects(subject:TExpr, con:Con, rest:Array<TExpr>):Array<TExpr> {
		var subst:Array<{from:T, to:T}> = switch (con.kind) {
			case ConEnum(en, ef):
				switch [TypeFunctions.follow(subject.type), TypeFunctions.follow(enumConstructorReturn(ef))] {
					case [TEnum(se, stl), TEnum(re, rtl)] if (se == en && re == en && stl.length == rtl.length):
						[for (i in 0...stl.length) {from: stl[i], to: rtl[i]}];
					case _:
						[];
				}
			case _:
				[];
		};
		if (subst.length == 0) return rest;
		function mapType(t:T):T {
			for (s in subst) if (t == s.from) return s.to;
			return TypeFunctions.map(mapType, t);
		}
		return [for (e in rest) TypeFunctions.mk(e.expr, mapType(e.type), e.pos)];
	}

	static function getColumnSigma(subject:TExpr, cases:Array<MatchCase>):{sigma:Array<{con:Con, unguarded:Bool, argPositions:Array<Position>}>, nullCases:Array<MatchCase>} {
		var sigma:Array<{con:Con, unguarded:Bool, argPositions:Array<Position>}> = [];
		var unguarded:Array<Con> = [];
		var nullCases:Array<MatchCase> = [];
		function addSigma(con:Con, argPositions:Array<Position>) {
			for (s in sigma) if (Constructor.equal(s.con, con)) { s.argPositions = argPositions; return; }
			sigma.push({con: con, unguarded: false, argPositions: argPositions});
		}
		function markUnguarded(con:Con) {
			for (c in unguarded) if (Constructor.equal(c, con)) return;
			unguarded.push(con);
		}
		for (mc in cases) {
			function loop(bindings:Array<Binding>, pat:Pattern) {
				switch (pat.pat) {
					case PatConstructor(con, _) if (isNullConst(con)):
						nullCases.push({c: mc.c, bindings: bindings, patterns: mc.patterns.slice(1)});
					case PatConstructor(con, patterns):
						if (mc.c.guard == null) markUnguarded(con);
						addSigma(con, [for (pp in patterns) pp.pos]);
					case PatBind(v, pat1):
						loop([{v: v, p: pat.pos, e: subject}].concat(bindings), pat1);
					case PatVariable(_) | PatAny:
					case PatExtractor(_, _, _):
						throw new MatchExtractor();
					case _:
						throw new TypingError("Unexpected pattern: " + (switch (pat.pat) { case PatTuple(_): "tuple"; case _: "?"; }), mc.c.pos);
				}
			}
			loop(mc.bindings, mc.patterns[0]);
		}
		for (s in sigma) for (c in unguarded) if (Constructor.equal(c, s.con)) { s.unguarded = true; break; }
		sigma.sort(function(a, b) return a.con.pos.min - b.con.pos.min);
		return {sigma: sigma, nullCases: nullCases};
	}

	public static function compile(mctx:MatcherContext, subjects:Array<TExpr>, cases:Array<MatchCase>):Dt {
		if (cases.length == 0) {
			return fail(mctx, subjects.length > 0 ? subjects[0].pos : mctx.matchPos);
		}
		var first = cases[0];
		var allWild = true;
		for (pat in first.patterns) if (!isWildcardPattern(pat)) { allWild = false; break; }
		if (allWild) {
			return compileLeaf(mctx, subjects, first, cases.slice(1));
		}
		var cs = expand(cases);
		var sel = selectColumn(subjects, cs);
		cs = expand(sel.cases);
		return try compileSwitch(mctx, sel.subjects, cs) catch (_:MatchExtractor) compileExtractors(mctx, sel.subjects, cs);
	}

	static function compileLeaf(mctx:MatcherContext, subjects:Array<TExpr>, mc:MatchCase, cases:Array<MatchCase>):Dt {
		var dt = leaf(mctx, mc.c);
		dt = switch (mc.c.guard) {
			case null: dt;
			case e: guard(mctx, e, dt, compile(mctx, subjects, cases));
		};
		// Loop patterns el bindings: pair leftover patterns with subjects to bind vars.
		var bindings = mc.bindings.copy();
		var patterns = mc.patterns;
		var el = subjects;
		var pi = 0, ei = 0;
		while (true) {
			if (patterns.length - pi == 1 && isPatAny(patterns[pi])) break;                       
			if (pi >= patterns.length && ei >= el.length) break;
			if (pi >= patterns.length) throw new TypingError("Invalid match: Not enough patterns", el[ei].pos);
			if (ei >= el.length) throw new TypingError("Invalid match: Too many patterns", patterns[pi].pos);
			var head = patterns[pi];
			switch (head.pat) {
				case PatVariable(v):
					bindings.unshift({v: v, p: head.pos, e: el[ei]});
					pi++; ei++;
				case PatBind(v, pat1):
					bindings.unshift({v: v, p: head.pos, e: el[ei]});
					patterns = [pat1].concat(patterns.slice(pi + 1));
					el = el.slice(ei);
					pi = 0; ei = 0;
				case _:
					pi++; ei++;
			}
		}
		if (bindings.length == 0) return dt;
		bindings.reverse();
		return bind(mctx, bindings, dt);
	}

	static inline function isPatAny(pat:Pattern):Bool return switch (pat.pat) { case PatAny: true; case _: false; };

	static function compileSwitch(mctx:MatcherContext, subjects:Array<TExpr>, cases:Array<MatchCase>):Dt {
		if (subjects.length == 0) throw new TypingError("Internal match failure", mctx.matchPos);
		var subject = subjects[0];
		var rest = subjects.slice(1);
		var sig = getColumnSigma(subject, cases);
		var switchCases:Array<{con:Con, unguarded:Bool, dt:Dt}> = [];
		for (s in sig.sigma) {
			var subSubjects = getSubSubjects(mctx, subject, s.con, s.argPositions);
			var bindings:Array<Binding> = [];
			var subExprs:Array<TExpr> = [];
			for (sse in subSubjects) {
				var v = genLocal(mctx.ctx, sse.type, sse.pos);
				bindings.push({v: v, p: v.pos, e: sse});
				subExprs.push(TexprTools.makeLocal(v, v.pos));
			}
			var newSubjects = subExprs.concat(refineSubjects(subject, s.con, rest));
			var spec = specialize(subject, s.con, cases);
			var dt = compile(mctx, newSubjects, spec);
			dt = bind(mctx, bindings, dt);
			switchCases.push({con: s.con, unguarded: s.unguarded, dt: dt});
		}
		// A structure pattern is irrefutable (every value of the type has the fields): bind the fields
		// and continue with no switch test, which has no runtime discriminant to emit.
		if (switchCases.length == 1 && sig.nullCases.length == 0 && (switch (sig.sigma[0].con.kind) { case ConFields(_): true; case _: false; }))
			return switchCases[0].dt;
		var def = defaultMatrix(subject, cases);
		var switchDefault = compile(mctx, rest, def);
		var dt = switchCases.length == 0 ? switchDefault : switchDt(mctx, subject, switchCases, switchDefault);
		if (sig.nullCases.length == 0) {
			return TypeFunctions.isExplicitNull(subject.type) ? guardNull(mctx, subject, switchDefault, dt) : dt;
		}
		var dtNull = compile(mctx, rest, sig.nullCases.concat(def));
		return guardNull(mctx, subject, dtNull, dt);
	}

	// Extractor columns: introduce one fresh subject per extractor case (its expression evaluated once with
	// `_` bound to the subject), rewrite each case's patterns to target that column, and recompile.
	static function compileExtractors(mctx:MatcherContext, subjects:Array<TExpr>, cases:Array<MatchCase>):Dt {
		if (subjects.length == 0) throw new TypingError("Internal match failure", mctx.matchPos);
		var subject = subjects[0];
		var rest = subjects.slice(1);
		var infos:Array<Null<{v:TVar, e1:TExpr, pat:Pattern, binds:Array<Binding>}>> = [];
		var numEx = 0;
		for (mc in cases) {
			var binds:Array<Binding> = [];
			var pat = mc.patterns[0];
			var info:Null<{v:TVar, e1:TExpr, pat:Pattern, binds:Array<Binding>}> = null;
			var go = true;
			while (go) switch (pat.pat) {
				case PatExtractor(v, e1, inner): info = {v: v, e1: e1, pat: inner, binds: binds}; go = false;
				case PatBind(bv, pat1): binds = binds.concat([{v: bv, p: pat.pos, e: subject}]); pat = pat1;
				case _: go = false;
			}
			if (info != null) numEx++;
			infos.push(info);
		}
		var patAny:Pattern = {pat: PatAny, pos: mctx.matchPos};
		var exSubjects:Array<TExpr> = [];
		var exBindings:Array<Binding> = [];
		var newCases:Array<MatchCase> = [];
		var left = 0;
		for (i in 0...cases.length) {
			var mc = cases[i];
			var info = infos[i];
			var restPatterns = mc.patterns.slice(1);
			if (info != null) {
				var e1 = info.e1;
				var ev = TypeFunctions.allocVar(VExtractorVariable, "_hx_tmp", e1.type, e1.pos);
				// Evaluate the extractor once: bind `_` to the subject, then the extractor var to its result.
				exBindings.push({v: info.v, p: subject.pos, e: subject});
				exBindings.push({v: ev, p: e1.pos, e: e1});
				exSubjects.push(TexprTools.makeLocal(ev, e1.pos));
				var patterns = makeOffsetList(1 + left, numEx - 1 - left, info.pat, patAny).concat(restPatterns);
				newCases.push({c: mc.c, bindings: info.binds.concat(mc.bindings), patterns: patterns});
				left++;
			} else {
				var patterns = makeOffsetList(0, numEx, mc.patterns[0], patAny).concat(restPatterns);
				newCases.push({c: mc.c, bindings: mc.bindings, patterns: patterns});
			}
		}
		var recompSubjects = [subject].concat(exSubjects).concat(rest);
		var dt = compile(mctx, recompSubjects, newCases);
		return exBindings.length == 0 ? dt : bind(mctx, exBindings, dt);
	}

	static function makeOffsetList(left:Int, right:Int, x:Pattern, pad:Pattern):Array<Pattern> {
		var r:Array<Pattern> = [];
		for (_i in 0...left) r.push(pad);
		r.push(x);
		for (_i in 0...right) r.push(pad);
		return r;
	}

	// Compile (entry): bind non-trivial subjects to temps, then compile.
	public static function compileEntry(ctx:TyperContext, matchDebug:Bool, subjects:Array<TExpr>, cases:Array<MatchCase>, p:Position):Dt {
		var mctx = new MatcherContext(ctx, p);
		mctx.matchDebug = matchDebug;
		var subj:Array<TExpr> = [];
		var vars:Array<Binding> = [];
		for (e in subjects) {
			switch (e.expr) {
				case TConst(_) | TLocal(_): subj.push(e);
				case _:
					var v = genLocal(ctx, e.type, e.pos);
					subj.push(TexprTools.makeLocal(v, e.pos));
					vars.push({v: v, p: e.pos, e: e});
			}
		}
		var dt = if (cases.length == 0 && subj.length > 0) {
			switchDt(mctx, subj[0], [], fail(mctx, subj[0].pos));
		} else {
			compile(mctx, subj, cases);
		}
		return vars.length == 0 ? dt : bind(mctx, vars, dt);
	}
}

enum DtRecursion {
	DRToplevel;
	DRAfterSwitch;
	DRDeep;
}

class TexprConverter {
	static function arrayLengthExpr(ctx:TyperContext, subject:TExpr):TExpr {
		return Typer.accGet(ctx, Fields.typeField(ctx, subject, "length", subject.pos, MGet, WithTypeTools.value));
	}

	static function completeFiniteCoverage(subject:TExpr, cases:Array<{con:Con, unguarded:Bool, dt:Dt}>):Bool {
		function constKey(ct:TConstant):String {
			return switch (ct) {
				case TInt(v): "i:" + v;
				case TFloat(s): "f:" + s;
				case TString(s): "s:" + s;
				case TBool(b): "b:" + b;
				case TNull: "null";
				case TThis: "this";
				case TSuper: "super";
			}
		}
		function fieldConst(cf:TClassField):Null<TConstant> {
			function loop(e:TExpr):Null<TConstant> {
				return switch (e.expr) {
					case TConst(TNull): null;
					case TConst(ct): ct;
					case TCast(e1, null) | TMeta(_, e1) | TParenthesis(e1): loop(e1);
					case _: null;
				}
			}
			return cf.expr == null ? null : loop(cf.expr);
		}
		switch (TypeFunctions.follow(subject.type)) {
			case TEnum(en, _):
				var found = new Map<String, Bool>();
				for (sc in cases) if (sc.unguarded) switch (sc.con.kind) {
					case ConEnum(en2, ef) if (en2 == en): found.set(ef.name, true);
					case _:
				}
				for (name in en.constrs.keys()) {
					var ef = en.constrs.get(name);
					if (DtCompile.enumConstructorCompatible(subject.type, en, ef) && !found.exists(name)) return false;
				}
				return true;
			case TAbstract(a, _) if (a.isEnum && a.impl != null):
				var found = new Map<String, Bool>();
				var foundConst = new Map<String, Bool>();
				for (sc in cases) if (sc.unguarded) switch (sc.con.kind) {
					case ConStatic(c, cf) if (c == a.impl && a.impl.statics.exists(cf.name) && TypeFunctions.hasClassFieldFlag(a.impl.statics.get(cf.name), CfEnum)):
						found.set(cf.name, true);
					case ConConst(ct):
						foundConst.set(constKey(ct), true);
					case _:
				}
				var total = 0;
				for (cf in a.impl.statics) if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) {
					total++;
					var ct = fieldConst(cf);
					if (!found.exists(cf.name) && (ct == null || !foundConst.exists(constKey(ct)))) return false;
				}
				return total > 0;
			case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Bool"):
				var hasTrue = false;
				var hasFalse = false;
				for (sc in cases) if (sc.unguarded) switch (sc.con.kind) {
					case ConConst(TBool(true)): hasTrue = true;
					case ConConst(TBool(false)): hasFalse = true;
					case _:
				}
				return hasTrue && hasFalse;
			case _:
				return false;
		}
	}

	public static function toTexpr(ctx:TyperContext, tSwitch:T, withType:WithType, dt:Dt):Null<TExpr> {
		return toTexprRec(ctx, tSwitch, withType, dt, DRToplevel);
	}

	static function toTexprRec(ctx:TyperContext, tSwitch:T, withType:WithType, dt:Dt, rec:DtRecursion):Null<TExpr> {
		if (dt.texpr != null) return dt.texpr;
		var basic = ctx.com.basic;
		var e:Null<TExpr> = switch (dt.t) {
			case Leaf(c):
				c.expr != null ? c.expr : TypeFunctions.mk(TBlock([]), basic.tvoid, c.pos);
			case Switch(subject, cases, def):
				if (cases.length == 1) {
					switch (cases[0].con.kind) {
						case ConFields(_):
							return toTexprRec(ctx, tSwitch, withType, cases[0].dt, rec);
						case _:
					}
				}
				var topLevel = rec.match(DRToplevel);
				var nextRec = topLevel ? DRAfterSwitch : DRDeep;
				var complete = completeFiniteCoverage(subject, cases);
				// Only a run-time-finite subject (a true enum or Bool) can drop its default branch; an enum
				// abstract is compile-time finite, so a runtime value can be out of range and a user
				// default must be kept.
				var runtimeFinite = switch (TypeFunctions.follow(subject.type)) {
					case TEnum(_, _): true;
					case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Bool"): true;
					case _: false;
				};
				var defE = (topLevel && complete && runtimeFinite) ? null : toTexprRec(ctx, tSwitch, withType, def, nextRec);
				var swCases:Array<TSwitchCase> = [];
				for (sc in cases) {
					var ce = toTexprRec(ctx, tSwitch, withType, sc.dt, nextRec);
					if (ce != null) swCases.push({values: [Constructor.toTexpr(ctx, false, sc.con)], expr: ce});
				}
				if (defE == null && !complete) switch (withType) {
					case NoValue:
					case _:
						throw new TypingError("Unmatched patterns: _", subject.pos);
				}
				// An enum switch dispatches on the constructor index.
				var swSubject = if (cases.length == 0) subject else switch (cases[0].con.kind) {
					case ConEnum(_, _): TypeFunctions.mk(TEnumIndex(subject), basic.tint, subject.pos);
					case ConArray(_): arrayLengthExpr(ctx, subject);
					case _: subject;
				};
				TypeFunctions.mk(TSwitch(swSubject, swCases, defE), tSwitch, dt.pos);
			case Guard(e, dt1, dt2):
				var eThen = toTexprRec(ctx, tSwitch, withType, dt1, rec);
				if (eThen == null) null else {
					var eElse = toTexprRec(ctx, tSwitch, withType, dt2, rec);
					if (eElse != null) TypeFunctions.mk(TIf(e, eThen, eElse), tSwitch, Position.union(eThen.pos, eElse.pos));
					else if (withType.match(NoValue) && (rec.match(DRToplevel) || rec.match(DRAfterSwitch)))
						TypeFunctions.mk(TIf(e, eThen, null), basic.tvoid, Position.union(e.pos, eThen.pos));
					else null;
				}
			case GuardNull(e, dt1, dt2):
				var topLevel = rec.match(DRToplevel);
				var eThen = toTexprRec(ctx, tSwitch, withType, dt1, rec);
				var eElse = toTexprRec(ctx, tSwitch, withType, dt2, rec);
				if (eThen == null) {
					if (topLevel || withType.match(NoValue)) eElse else throw new TypingError("Unmatched patterns: null", e.pos);
				} else if (eElse == null) {
					if (topLevel || withType.match(NoValue)) {
						var eNull = TypeFunctions.mk(TConst(TNull), e.type, e.pos);
						var cond = TypeFunctions.mk(TBinop(OpEq, e, eNull), basic.tbool, e.pos);
						TypeFunctions.mk(TIf(cond, eThen, null), basic.tvoid, Position.union(e.pos, eThen.pos));
					} else throw new TypingError("Unmatched patterns: _", e.pos);
				} else {
					var eNull = TypeFunctions.mk(TConst(TNull), e.type, e.pos);
					var cond = TypeFunctions.mk(TBinop(OpEq, e, eNull), basic.tbool, e.pos);
					TypeFunctions.mk(TIf(cond, eThen, eElse), tSwitch, dt.pos);
				}
			case Bind(bl, dt2):
				var inner = toTexprRec(ctx, tSwitch, withType, dt2, rec);
				if (inner == null) null else {
					var el = [for (b in bl) TypeFunctions.mk(TVarExpr(b.v, b.e), basic.tvoid, b.p)];
					el.push(inner);
					TypeFunctions.mk(TBlock(el), inner.type, dt.pos);
				}
			case Fail:
				null;
		};
		dt.texpr = e;
		return e;
	}
}

class Match {
	static function bodyExpr(ctx:TyperContext, c:Case):TExpr {
		return c.expr != null ? c.expr : TypeFunctions.mk(TBlock([]), ctx.com.basic.tvoid, c.pos);
	}

	static function inferSwitchType(ctx:TyperContext, withType:WithType, cases:Array<MatchCase>):T {
		return switch (withType) {
			case NoValue: ctx.com.basic.tvoid;
			case Value(_): cases.length == 0 ? ctx.com.basic.tvoid : Typer.unifyMin(ctx, [for (mc in cases) bodyExpr(ctx, mc.c)]);
			case WithType(t, _): t;
		};
	}

	public static function matchExpr(ctx:TyperContext, e:Expr, cases:Array<SwitchCase>, def:Null<{e:Null<Expr>, pos:Position}>, withType:WithType, postfix:Bool, p:Position):TExpr {
		// `switch [a, b]` (a bracket literal) is a tuple match: each element is its own subject with
		// its own type, and the case patterns match column by column.
		var tupleEls:Null<Array<Expr>> = switch (e.expr) { case EArrayDecl(l): l; case _: null; };
		var subjects:Array<TExpr>;
		var subjectTypes:Array<T>;
		if (tupleEls != null) {
			subjects = [for (se in tupleEls) Typer.typeExpr(ctx, se, WithTypeTools.value)];
			subjectTypes = [for (s in subjects) s.type];
		} else {
			var subjectE = Typer.typeExpr(ctx, e, WithTypeTools.value);
			subjects = [subjectE];
			subjectTypes = [subjectE.type];
		}
		var allCases = cases.copy();
		if (def != null) allCases.push({values: [new Expr(EConst(CIdent("_")), def.pos)], guard: null, expr: def.e, pos: def.pos});
		var matchCases:Array<MatchCase> = [];
		for (cas in allCases) {
			if (tupleEls != null) {
				// `case [p..]|[q..]:` over a tuple is an or of tuple patterns; the parser folds the `|`
				// alternatives into an OpOr expr. Flatten it and give each alternative its own case
				// (sharing the guard and body), as the reference matcher does.
				var alts:Array<Expr> = [];
				function flattenOr(e:Expr):Void switch (e.expr) {
					case EBinop(OpOr, a, b): flattenOr(a); flattenOr(b);
					case _: alts.push(e);
				}
				for (v in cas.values) flattenOr(v);
				for (v in alts) {
					var r = CaseMaker.makeTuple(ctx, subjectTypes, [v], cas.guard, cas.expr, withType, postfix, cas.pos);
					matchCases.push({c: r.c, bindings: [], patterns: r.pats});
				}
			} else {
				var r = CaseMaker.make(ctx, subjectTypes[0], cas.values, cas.guard, cas.expr, withType, postfix, cas.pos);
				matchCases.push({c: r.c, bindings: [], patterns: [r.pat]});
			}
		}
		var tSwitch = inferSwitchType(ctx, withType, matchCases);
		var dt = DtCompile.compileEntry(ctx, false, subjects, matchCases, p);
		var te = TexprConverter.toTexpr(ctx, tSwitch, withType, dt);
		if (te == null) throw new TypingError("Unmatched patterns: _", p);
		return te;
	}
}
