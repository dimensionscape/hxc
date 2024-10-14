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

typedef Con = {kind:ConKind, pos:Position, ?subPos:Position};

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

	// Total order over TConstant: the constructor tag orders first (TInt < TFloat < TString < TBool < TNull
	// < TThis < TSuper), then the payload
	static function constCompare(ct1:TConstant, ct2:TConstant):Int {
		inline function cmpStr(a:String, b:String):Int return a < b ? -1 : (a > b ? 1 : 0);
		function tag(ct:TConstant):Int return switch (ct) {
			case TInt(_): 0;
			case TFloat(_): 1;
			case TString(_): 2;
			case TBool(_): 3;
			case TNull: 4;
			case TThis: 5;
			case TSuper: 6;
		};
		return switch ([ct1, ct2]) {
			case [TInt(a), TInt(b)]: a < b ? -1 : (a > b ? 1 : 0);
			case [TFloat(a), TFloat(b)]: cmpStr(a, b);
			case [TString(a), TString(b)]: cmpStr(a, b);
			case [TBool(a), TBool(b)]: a == b ? 0 : (a ? 1 : -1);
			case _: tag(ct1) - tag(ct2);
		};
	}

	// Compare (ordering for the decision-tree tables).
	public static function compare(con1:Con, con2:Con):Int {
		inline function cmpStr(a:String, b:String):Int return a < b ? -1 : (a > b ? 1 : 0);
		return switch ([con1.kind, con2.kind]) {
			case [ConConst(ct1), ConConst(ct2)]: constCompare(ct1, ct2);
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

// Useless: checks for useless patterns based on http://moscova.inria.fr/~maranget/papers/warn/index.html
private enum Useless {
	UFalse;
	UPos(p:Position);
	UTrue;
}

private class UnusedPatternCheck {
	static function copyMatrix(m:Array<Array<Pattern>>):Array<Array<Pattern>> return [for (_ in m) []];

	static function anyPatterns(n:Int, p:Position):Array<Pattern> return [for (_ in 0...n) ({pat: PatAny, pos: p} : Pattern)];

	// Specialization (the U part). A PatVariable head row is DROPPED here (only PatAny expands), unlike
	// uSpecialize2 below.
	static function uSpecialize(isTuple:Bool, con:Con, pM:Array<Array<Pattern>>):Array<Array<Pattern>> {
		var acc:Array<Array<Pattern>> = [];
		var work = pM.copy();
		var i = 0;
		while (i < work.length) {
			var patterns = work[i]; i++;
			if (patterns.length == 0) continue;
			var head = patterns[0], rest = patterns.slice(1);
			switch (head.pat) {
				case PatConstructor(con2, patterns1) if (!isTuple && Constructor.equal(con, con2)):
					acc.push(patterns1.concat(rest));
				case PatTuple(patterns1) if (isTuple):
					acc.push(patterns1.concat(rest));
				case PatAny:
					acc.push(anyPatterns(Constructor.arity(con), head.pos).concat(rest));
				case PatBind(_, pat1):
					work.insert(i, ([pat1] : Array<Pattern>).concat(rest));
				case _:
			}
		}
		return acc;
	}

	static function uDefault(pM:Array<Array<Pattern>>):Array<Array<Pattern>> {
		var acc:Array<Array<Pattern>> = [];
		for (patterns in pM) if (patterns.length > 0) switch (patterns[0].pat) {
			case PatVariable(_) | PatAny: acc.push(patterns.slice(1));
			case _:
		}
		return acc;
	}

	// U: is the vector q useful against matrix pM?
	static function u(pM:Array<Array<Pattern>>, q:Array<Pattern>):Bool {
		if (q.length == 0) return pM.length == 0;
		var q1 = q[0], ql = q.slice(1);
		function loop(pat:Pattern):Bool return switch (pat.pat) {
			case PatConstructor(con, patterns):
				u(uSpecialize(false, con, pM), patterns.concat(ql));
			case PatTuple(patterns):
				u(uSpecialize(true, Constructor.make(ConConst(TNull), pat.pos), pM), patterns.concat(ql));
			case PatVariable(_) | PatAny:
				u(uDefault(pM), ql);
			case PatOr(pat1, pat2):
				u(pM, ([pat1] : Array<Pattern>).concat(ql)) || u(pM, ([pat2] : Array<Pattern>).concat(ql));
			case PatBind(_, pat1):
				loop(pat1);
			case PatExtractor(_, _, _):
				true;
		}
		return loop(q1);
	}

	// transferColumn: move each row head from source to target; an empty source row drops the pair from
	// both.
	static function transferColumn(source:Array<Array<Pattern>>, target:Array<Array<Pattern>>):{source:Array<Array<Pattern>>, target:Array<Array<Pattern>>} {
		var s2:Array<Array<Pattern>> = [], t2:Array<Array<Pattern>> = [];
		for (i in 0...source.length) {
			var patterns1 = source[i], patterns2 = target[i];
			if (patterns1.length > 0) {
				s2.push(patterns1.slice(1));
				t2.push(([patterns1[0]] : Array<Pattern>).concat(patterns2));
			}
		}
		return {source: s2, target: t2};
	}

	// Specialization for u2 (the U2 part): triple-matrix specialization; a PatOr head requeues both
	// alternatives with the row q/r duplicated.
	static function uSpecialize2(isTuple:Bool, con:Con, pM:Array<Array<Pattern>>, qM:Array<Array<Pattern>>, rM:Array<Array<Pattern>>):{p:Array<Array<Pattern>>, q:Array<Array<Pattern>>, r:Array<Array<Pattern>>} {
		var arity = Constructor.arity(con);
		var pAcc:Array<Array<Pattern>> = [], qAcc:Array<Array<Pattern>> = [], rAcc:Array<Array<Pattern>> = [];
		var pW = pM.copy(), qW = qM.copy(), rW = rM.copy();
		var idx = 0;
		while (idx < pW.length) {
			var q1 = qW[idx], r1 = rW[idx];
			var cur = pW[idx]; idx++;
			var again = true;
			while (again) {
				again = false;
				if (cur.length == 0) break;
				var head = cur[0], rest = cur.slice(1);
				switch (head.pat) {
					case PatConstructor(con2, patterns1) if (!isTuple && Constructor.equal(con, con2)):
						pAcc.push(patterns1.concat(rest)); qAcc.push(q1); rAcc.push(r1);
					case PatTuple(patterns1) if (isTuple):
						pAcc.push(patterns1.concat(rest)); qAcc.push(q1); rAcc.push(r1);
					case PatVariable(_) | PatAny:
						pAcc.push(anyPatterns(arity, head.pos).concat(rest)); qAcc.push(q1); rAcc.push(r1);
					case PatOr(pat1, pat2):
						pW.insert(idx, ([pat2] : Array<Pattern>).concat(rest));
						pW.insert(idx, ([pat1] : Array<Pattern>).concat(rest));
						qW.insert(idx, q1); qW.insert(idx, q1);
						rW.insert(idx, r1); rW.insert(idx, r1);
					case PatBind(_, pat1):
						cur = ([pat1] : Array<Pattern>).concat(rest);
						again = true;
					case _:
				}
			}
		}
		return {p: pAcc, q: qAcc, r: rAcc};
	}

	static function combine(u1:Useless, p1:Position, u2v:Useless, p2:Position):Useless {
		return switch [u1, u2v] {
			case [UTrue, UTrue]: UTrue;
			case [UFalse, UFalse]: UFalse;
			case [UTrue, UFalse]: UPos(p2);
			case [UFalse, UTrue]: UPos(p1);
			case [UTrue, UPos(_)]: u2v;
			case [UPos(_), UTrue]: u1;
			case [UFalse, UPos(_)]: UPos(p1);
			case [UPos(_), _]: u1;
		}
	}

	// U2: usefulness with or-pattern position tracking. q and r accumulate by PREPEND.
	static function u2(pM:Array<Array<Pattern>>, qM:Array<Array<Pattern>>, rM:Array<Array<Pattern>>, p:Array<Pattern>, q:Array<Pattern>, r:Array<Pattern>):Useless {
		if (p.length == 0) {
			if (r.length == 0) return u(qM, q) ? UTrue : UFalse;
			// Each deferred or-pattern column i is pulled out of every rM row (the rest joins the qM
			// row), then both alternatives are checked, the second against the first.
			function processRow(i:Int, l:Array<Pattern>, q:Array<Pattern>):{x:Pattern, l:Array<Pattern>} {
				return {x: l[i], l: l.slice(0, i).concat(l.slice(i + 1)).concat(q)};
			}
			var et:Useless = UTrue;
			for (i in 0...r.length) {
				switch (r[i].pat) {
					case PatOr(pat1, pat2):
						var col:Array<Array<Pattern>> = [], mat:Array<Array<Pattern>> = [];
						for (j in 0...rM.length) {
							var pr = processRow(i, rM[j], qM[j]);
							col.push([pr.x]);
							mat.push(pr.l);
						}
						var rNew = processRow(i, r, q).l;
						var et1 = u2(col, mat, copyMatrix(mat), [pat1], rNew, []);
						var qM2 = mat.concat([rNew]);
						var et2 = u2(col.concat([([pat1] : Array<Pattern>)]), qM2, copyMatrix(qM2), [pat2], rNew, []);
						var et3 = combine(et1, pat1.pos, et2, pat2.pos);
						var pu = Position.union(pat1.pos, pat2.pos);
						et = combine(et, pu, et3, pu);
					case _:
						throw new TypingError("Something went wrong", r[i].pos);
				}
			}
			return et;
		}
		var pat0 = p[0], pl = p.slice(1);
		function loop(pat:Pattern):Useless return switch (pat.pat) {
			case PatConstructor(con, patterns):
				var s = uSpecialize2(false, con, pM, qM, rM);
				u2(s.p, s.q, s.r, patterns.concat(pl), q, r);
			case PatTuple(patterns):
				var s = uSpecialize2(true, Constructor.make(ConConst(TNull), pat.pos), pM, qM, rM);
				u2(s.p, s.q, s.r, patterns.concat(pl), q, r);
			case PatVariable(_) | PatAny:
				var t = transferColumn(pM, qM);
				u2(t.source, t.target, rM, pl, ([pat] : Array<Pattern>).concat(q), r);
			case PatOr(_, _):
				var t = transferColumn(pM, rM);
				u2(t.source, qM, t.target, pl, q, ([pat] : Array<Pattern>).concat(r));
			case PatBind(_, pat1):
				loop(pat1);
			case PatExtractor(_, _, _):
				UTrue;
		}
		return loop(pat0);
	}

	static function checkCase(ctx:TyperContext, prior:Array<Array<Pattern>>, mc:MatchCase):Void {
		switch (u2(prior, prior.copy(), copyMatrix(prior), mc.patterns, [], [])) {
			case UFalse: ctx.com.warning(hxc.core.WarningList.Warning.WUnusedPattern, [], "This case is unused", mc.c.pos);
			case UPos(p): ctx.com.warning(hxc.core.WarningList.Warning.WUnusedPattern, [], "This pattern is unused", p);
			case UTrue:
		}
	}

	// A guarded case does not join the preceding matrix.
	public static function check(ctx:TyperContext, cases:Array<MatchCase>):Void {
		var prior:Array<Array<Pattern>> = [];
		for (mc in cases) {
			checkCase(ctx, prior, mc);
			if (mc.c.guard == null) prior.push(mc.patterns);
		}
	}
}

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
	public static var matchSubjectPos:Null<Position> = null;
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

	static function reportPatternTypo(t:T, field:String, pctx:PatternContext, p:Position):Void {
		var path = "", names:Array<String> = [];
		switch (TypeFunctions.follow(t)) {
			case TEnum(en, _): path = hxc.core.Globals.sTypePath(en.path); names = en.names;
			case TAbstract(a, _) if (a.isEnum && a.impl != null):
				path = hxc.core.Globals.sTypePath(a.path);
				names = [for (cf in a.impl.orderedStatics) if (TypeFunctions.hasClassFieldFlag(cf, CfImpl) && TypeFunctions.hasClassFieldFlag(cf, CfEnum)) cf.name];
			case _:
		}
		var similar = hxc.core.StringError.getSimilar(field, names);
		if (similar.length > 0)
			pctx.ctx.com.warning(hxc.core.WarningList.Warning.WTyper, [], "Potential typo detected (expected similar values are " + [for (s in similar) path + "." + s].join(", ") + ")", p);
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
					case TField(_, FEnum(en, ef)):
						hxc.filters.DeprecationCheck.checkEnumUse(pctx.ctx, en, ef, p);
						switch (TypeFunctions.follow(e.type)) {
							case TFun(_):
								pctx.ctx.com.addDiagnostic(hxc.core.TPrinting.sTypeStr(e.type) + " should be " + hxc.core.TPrinting.sTypeStr(t), p);
								throw new TypingError("Invalid match: Not enough patterns", matchSubjectPos == null ? ef.pos : matchSubjectPos);
						case _:
					}
					unify(pctx.ctx, e.type, t, p); PatConstructor(Constructor.make(ConEnum(en, ef), p), []);
				case TField(_, FStatic(c, cf)): unify(pctx.ctx, e.type, t, p); PatConstructor(Constructor.make(ConStatic(c, cf), p), []);
				case TTypeExpr(mt): unifyTypePattern(pctx.ctx, mt, t, p); PatConstructor(Constructor.make(ConTypeExpr(mt), p), []);
				case _: null;
			};
		}
		try {
			// Pattern expressions type in untyped mode so a private enum-abstract constant still matches
			// from another module.
			var oldUntyped = pctx.ctx.untypedMode;
			pctx.ctx.untypedMode = true;
			var e = try Typer.typeExpr(pctx.ctx, new Expr(EConst(CIdent(i)), p), WithTypeTools.withType(t)) catch (ex:Dynamic) {
				pctx.ctx.untypedMode = oldUntyped;
				throw ex;
			};
			pctx.ctx.untypedMode = oldUntyped;
			var pat = checkTyped(e);
			if (pat != null) return pat;
		} catch (err:TypingError) {
			if (err.message == "Invalid match: Not enough patterns") throw err;
		}
		// An ident that typed to a non-pattern value (e.g. a same-named local) or failed to type is
		// resolved as a field of the subject's module type (an enum-abstract constant), and only captures
		// when that fails too. The probe is speculative: diagnostics it records roll back unless it yields
		// a pattern.
		var diagBefore = pctx.ctx.com.diagnostics.length;
		try {
			var mt = TypeFunctions.moduleTypeOfType(t);
			var emt = TexprTools.makeTypeExpr(mt, p);
			var acc = Fields.typeField(pctx.ctx, emt, i, p, MGet, WithTypeTools.value);
			var pat = checkTyped(Typer.accGet(pctx.ctx, acc));
			if (pat != null) return pat;
		} catch (_:Dynamic) {}
		if (pctx.ctx.com.diagnostics.length > diagBefore) pctx.ctx.com.diagnostics.resize(diagBefore);
		// Anything that is not a lower-case identifier (an uppercase name, a $-ident) is not a capture;
		// generated-local and `_` prefixes are excluded.
		if (i.length > 0 && !hxc.ast.Ast.isLowerIdent(i) && i.charCodeAt(0) != "`".code && i.charCodeAt(0) != "_".code) {
			pctx.ctx.com.addDiagnostic("Unknown identifier : " + i + ", pattern variables must be lower-case or with `var ` prefix", p);
			if (pctx.orLocals != null) return PatVariable(addLocal(pctx, false, i, t, p));
			return PatAny;
		}
		var v = addLocal(pctx, false, i, t, p);
		return PatVariable(v);
	}

	// The object-pattern field types come from an anon directly, a or a @:forward abstract's
	// underlying type (filtered by the forwarded field list). Returns null when t is none of these
	// (fields then default to Dynamic).
	static function forwardFilter(a:TAbstract):Null<Map<String, Bool>> {
		for (m in a.meta) if (m.name == ":forward") {
			if (m.params.length == 0) return null;
			var set = new Map<String, Bool>();
			for (pe in m.params) switch (pe.expr) { case EConst(CIdent(sn)): set.set(sn, true); case _: }
			return set;
		}
		return null;
	}
	static function objectPatternFieldTypes(ctx:TyperContext, t:T):Null<{types:Map<String, T>, order:Array<String>, methods:Map<String, Bool>}> {
		var types = new Map<String, T>();
		var methods = new Map<String, Bool>();
		var order:Array<String> = [];
		var found = false;
		inline function add(name:String, ty:T):Void {
			if (!types.exists(name)) { types.set(name, ty); order.push(name); found = true; }
		}
		function collect(t:T):Void {
			switch (TypeFunctions.follow(t)) {
				case TAnon(an):
					var names = [for (cf in an.fields) cf.name];
					names.sort(function(a2, b2) return a2 < b2 ? -1 : (a2 > b2 ? 1 : 0));
					for (n in names) {
						var cf = an.fields.get(n);
						if (cf.kind.match(Method(_))) methods.set(n, true);
						add(n, cf.type);
					}
				case TInst(c, tl):
					// TInst: every accessible, matchable (non-method) field of the class and its supers, supers
					// first and in declaration order. this makes two structure patterns for a class value (`{a:_}`
					// and `{b:_}`) carry the same full field set, so the matcher treats them as one ConFields
					// constructor instead of two and never builds a value-switch on a structure pattern (issue:
					// self-host GenJS).
					function loopClass(c:TClass, tl:Array<T>):Void {
						switch (c.superClass) {
							case null:
							case sup: loopClass(sup.c, [for (t2 in sup.params) TypeFunctions.applyParams(c.params, tl, t2)]);
						}
						for (cf in c.orderedFields) {
							if (cf.kind.match(Method(_)) || !hxc.typing.Fields.canAccess(ctx, c, cf, false)) continue;
							add(cf.name, TypeFunctions.applyParams(c.params, tl, cf.type));
						}
					}
					loopClass(c, tl);
				case TAbstract(a, tl) if (a.impl != null):
					// TAbstract: the abstract's @:impl instance fields (its properties/vars) expose their
					// abstract type, and a @:forward abstract additionally exposes its underlying type's
					// fields (filtered by the @:forward name list) for any name the impl does not already
					// define. Methods are not matchable and are skipped.
					for (cf in a.impl.orderedStatics) {
						if (!TypeFunctions.hasClassFieldFlag(cf, CfImpl) || cf.kind.match(Method(_))) continue;
						add(cf.name, TypeFunctions.applyParams(a.params, tl, cf.type));
					}
					if (TypeFunctions.hasMeta(":forward", a.meta)) {
						var fwd = forwardFilter(a);
						var inner = objectPatternFieldTypes(ctx, TypeFunctions.getUnderlyingType(a, tl));
						if (inner != null) for (name in inner.order) if (fwd == null || fwd.exists(name)) add(name, inner.types.get(name));
					}
				case _:
			}
		}
		collect(t);
		return found ? {types: types, order: order, methods: methods} : null;
	}

	public static function make(pctx:PatternContext, toplevel:Bool, t:T, e:Expr):Pattern {
		var ctx = pctx.ctx;
		var p = e.pos;
		var basic = ctx.com.basic;
		function hasStringInterpolation(s:String):Bool {
			var i = 0;
			while (i + 1 < s.length) {
				if (s.charAt(i) != "$") { i++; continue; }
				var next = s.charAt(i + 1);
				if (next == "{" || ((next >= "A" && next <= "Z") || (next >= "a" && next <= "z") || next == "_")) return true;
				i += 2;
			}
			return false;
		}
		function unifyExpected(t2:T) unify(ctx, t2, t, p);

		// A display position on A PATTERN answers with the pattern's own expected type. hxc has no
		// EDisplay node here (the parser stands a null in directly), so the position is the trigger; the
		// local the pattern would bind is never added, which is why ctx.locals is saved and restored
		// around it.
		switch (e.expr) {
			case EConst(CIdent(s)) if (Typer.atDisplayPos(e.pos)):
				Typer.raiseToplevelInPattern(ctx, t, s);
			// Inside a pattern, an `if (cond)` whose body is the recovery's null stand-in is the display
			// subject. `case <cursor> if (guard):` parses the guard as the pattern, because the pattern
			// itself has not been written yet.
			case EIf(_, {expr: EConst(CIdent("null"))}, null) if (hxc.parser.Parser.displayCompletionMode):
				Typer.raiseToplevelInPattern(ctx, t, "null");
			case _:
		}

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
			case EConst(CString(s, SSingleQuotes)) if (hasStringInterpolation(s)):
				var stringPos = p.max > p.min + 1 ? new Position(p.file, p.min + 1, p.max - 1) : p;
				throw new TypingError("String interpolation is not allowed in case patterns", stringPos);
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
				switch (e1.expr) {
					case EBinop(OpEq, {expr: EConst(CIdent(name))}, _) if (pctx.currentLocals.exists(name)):
						var ep = switch (e1.expr) { case EBinop(_, left, _): left.pos; case _: e1.pos; };
						throw new TypingError("Unknown identifier : " + name, ep);
					case _:
				}
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
				var fieldTypes = objectPatternFieldTypes(ctx, t);
				var mentioned = new Map<String, Expr>();
				for (f in fields) mentioned.set(f.name, f.expr);
				// The field order is the collect_fields visit order (already correct per type kind);
				// a type with no known field set falls back to the names the pattern lists, sorted so
				// two such patterns still share one constructor.
				var allNames = if (fieldTypes != null) fieldTypes.order else {
					var ns = [for (f in fields) f.name];
					ns.sort(function(a2, b2) return a2 < b2 ? -1 : (a2 > b2 ? 1 : 0));
					ns;
				};
				var pairs = [];
				for (name in allNames) {
					var cf = fieldTypes == null ? null : fieldTypes.types.get(name);
					var fe = mentioned.get(name);
					// An omitted field, or a reification position field (carries no matchable info), is a wildcard.
					var omitted = fe == null || (pctx.inReification && (name == "pos" || name == "posPath" || name == "namePos"));
					// Only a NON-method field is filled in with a wildcard. A method carries no matchable
					// information, so it is dropped from the constructor entirely and never becomes a sub-subject
					// to extract.
					if (omitted && fieldTypes != null && fieldTypes.methods.exists(name)) continue;
					var sub = if (omitted)
						({pat: PatAny, pos: fe == null ? p : fe.pos} : Pattern)
						else make(pctx, false, cf != null ? cf : TypeFunctions.tDynamic, fe);
					pairs.push({name: name, sub: sub});
				}
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
								PatConstructor(Constructor.make(ConEnum(en, ef), ec.pos), subs);
							case _: throw new TypingError("This pattern is not yet ported", p);
						}
					case _: throw new TypingError("This pattern is not yet ported", p);
				}
			case EField(_, field, _):
				// A qualified value pattern (Type.Const / Type.EnumCtor / static const) matches by value.
				// It is typed in untyped mode so private constants match.
				var oldUntyped = ctx.untypedMode;
				ctx.untypedMode = true;
				var te = try Typer.typeExpr(ctx, e, WithTypeTools.withType(t)) catch (_:TypingError) null;
				ctx.untypedMode = oldUntyped;
				if (te == null) {
					reportPatternTypo(t, field, pctx, p);
					throw new TypingError("Only inline or read-only (default, never) fields can be used as a pattern", p);
				}
				switch (skipValue(te).expr) {
					case TConst(ct): unifyExpected(te.type); PatConstructor(Constructor.make(ConConst(ct), p), []);
					case TField(_, FEnum(en, ef)): unifyExpected(te.type); PatConstructor(Constructor.make(ConEnum(en, ef), p), []);
					case TField(_, FStatic(c, cf)):
						switch (cf.kind) {
							case Var(v) if (v.read == AccInline || (v.read == AccNormal && v.write == AccNever)):
							case _: throw new TypingError("Only inline or read-only (default, never) fields can be used as a pattern", p);
						}
						unifyExpected(te.type);
						PatConstructor(Constructor.make(ConStatic(c, cf), p), []);
					case TTypeExpr(mt): unifyTypePattern(ctx, mt, t, p); PatConstructor(Constructor.make(ConTypeExpr(mt), p), []);
					case TField(_, fa):
						// Any other field shape (an untyped-mode dynamic access, a method) is not a
						// matchable constant; suggest near-miss values first.
						reportPatternTypo(t, TypeFunctions.fieldName(fa), pctx, p);
						throw new TypingError("Only inline or read-only (default, never) fields can be used as a pattern", p);
					case _: throw new TypingError("This pattern is not yet ported", p);
				}
			case EMeta(m, e1) if (m.name == ":storedTypedExpr"):
				// A stored typed expression re-enters the pattern as its syntax.
				var id = switch (e1.expr) { case EConst(CInt(s, _)): Std.parseInt(s); case _: null; };
				if (id == null || !ctx.com.storedTypedExprs.exists(id)) throw new TypingError("Unknown stored typed expression", p);
				var te = TexprTools.duplicateTvars(function(te2) {
					return Typer.getThis(ctx, te2.pos);
				}, ctx.com.storedTypedExprs.get(id));
				return make(pctx, toplevel, t, Calls.texprToSyntax(ctx, te));
			case _:
				throw new TypingError("This pattern is not yet ported", p);
		};
		return {pat: kind, pos: p};
	}

	public static function clone(pctx:PatternContext):PatternContext {
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
		// A display position inside a pattern is a pattern display (a POSTFIX match is a marked display
		// instead), which is what floats the enum constructors to the front of a completion. hxc does not
		// thread the display kind through the matcher.
		var savedPatternDisplay = Typer.patternDisplay;
		Typer.patternDisplay = !postfixMatch;
		try {
			pat = PatternMaker.make(pctx, true, map(t), e);
			TypeParameterFrame.unapply(ctx.typeParams, monos);
			Typer.patternDisplay = savedPatternDisplay;
		} catch (ex:Dynamic) {
			Typer.patternDisplay = savedPatternDisplay;
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
		// Multiple case values fold into one OpOr chain so the whole case stays one pattern.
		var caseE = el[el.length - 1];
		var i = el.length - 2;
		while (i >= 0) {
			caseE = new Expr(EBinop(OpOr, el[i], caseE), Position.union(el[i].pos, caseE.pos));
			i--;
		}
		el = [caseE];
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
		// The case keeps one pattern: a [..] case is a single PatTuple (compile expands it after the
		// all-wildcard leaf shortcut, so a tuple of plain binders still reaches compileSwitch and its
		// explicit-Null guard), and `[..]|[..]` is a PatOr of tuples inside the same case, so both switch
		// branches share one hashconsed leaf and the conversion merges their case values.
		function mkTuplePat(pc:PatternContext, ex:Expr):Pattern {
			return switch (ex.expr) {
				case EParenthesis(e1):
					mkTuplePat(pc, e1);
				case EBinop(OpOr, e1, e2):
					// Both alternatives must bind the same variables; the second reuses the first's vars
					// through orLocals.
					var pctx1 = PatternMaker.clone(pc);
					pctx1.currentLocals = new Map();
					var pat1 = mkTuplePat(pctx1, e1);
					var pctx2 = PatternMaker.clone(pc);
					pctx2.currentLocals = new Map();
					pctx2.orLocals = pctx1.currentLocals;
					var pat2 = mkTuplePat(pctx2, e2);
					for (name in pctx1.currentLocals.keys()) {
						var entry = pctx1.currentLocals.get(name);
						if (!pctx2.currentLocals.exists(name) && name != "_") throw new TypingError("Variable " + name + " must appear exactly once in each sub-pattern", entry.p);
						pc.currentLocals.set(name, entry);
					}
					{pat: PatOr(pat1, pat2), pos: ex.pos};
				case EArrayDecl(elems) if (elems.length == mappedTypes.length):
					{pat: PatTuple([for (i in 0...mappedTypes.length) PatternMaker.make(pc, true, mappedTypes[i], elems[i])]), pos: ex.pos};
				case EConst(CIdent("_")):
					// `_` over a tuple is a tuple of anys, keeping every row the same width.
					{pat: PatTuple([for (_ in 0...mappedTypes.length) ({pat: PatAny, pos: ex.pos} : Pattern)]), pos: ex.pos};
				case EConst(CIdent(_)):
					throw new TypingError("Cannot bind matched tuple to variable, use _ instead", ex.pos);
				case _:
					throw new TypingError("tuple switch case must be a [..] pattern of arity " + mappedTypes.length, p);
			};
		}
		var pats:Array<Pattern>;
		try {
			pats = [mkTuplePat(pctx, el[0])];
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
	// Table: decision nodes are hashconsed so equal decisions share one node (the converter groups
	// switch cases by node identity)
	public var table:Array<Dt>;
	public function new(ctx:TyperContext, p:Position) {
		this.ctx = ctx;
		this.matchPos = p;
		this.matchDebug = false;
		this.count = 0;
		this.table = [];
	}
}

// Decision-tree equality over dt kinds (child nodes compare by dt index)
class DtEquality {
	public static function kindEquals(k1:DtKind, k2:DtKind):Bool {
		inline function eqDt(a:Dt, b:Dt):Bool return a.i == b.i;
		return switch ([k1, k2]) {
			case [Leaf(c1), Leaf(c2)]:
				c1 == c2;
			case [Switch(s1, cases1, def1), Switch(s2, cases2, def2)]:
				if (cases1.length != cases2.length) false
				else {
					var ok = TexprTools.equal(s1, s2) && eqDt(def1, def2);
					if (ok) for (i in 0...cases1.length) {
						var a = cases1[i], b = cases2[i];
						if (!(Constructor.equal(a.con, b.con) && a.unguarded == b.unguarded && eqDt(a.dt, b.dt))) { ok = false; break; }
					}
					ok;
				}
			case [Bind(l1, b1), Bind(l2, b2)]:
				if (l1.length != l2.length) false
				else {
					var ok = eqDt(b1, b2);
					if (ok) for (i in 0...l1.length)
						if (!(l1[i].v == l2[i].v && TexprTools.equal(l1[i].e, l2[i].e))) { ok = false; break; }
					ok;
				}
			case [Fail, Fail]:
				true;
			case [Guard(e1, d11, d12), Guard(e2, d21, d22)] | [GuardNull(e1, d11, d12), GuardNull(e2, d21, d22)]:
				e1 == e2 && eqDt(d11, d21) && eqDt(d12, d22);
			case _:
				false;
		};
	}
}

class DtCompile {
	static function makeList<A>(n:Int, x:A):Array<A> {
		return [for (_ in 0...n) x];
	}

	static function mkDt(mctx:MatcherContext, t:DtKind, p:Position):Dt {
		for (d in mctx.table) if (DtEquality.kindEquals(t, d.t)) return d;
		var d = new Dt(t, mctx.count, p);
		mctx.table.push(d);
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

	// A fresh generated local: a bare escape-char name that RenameVars turns into _g, not a distinct _hx_g
	// prefix.
	static function genLocal(ctx:TyperContext, t:T, p:Position):TVar {
		return TypeFunctions.allocVar(VGenerated, "`", t, p);
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
						// The SUBJECT is repositioned onto the argument's pattern position as well as the
						// extraction itself, so the two share one position and only one source-map segment
						// survives the dedup; leaving the subject where it was declared would emit a second
						// segment at every extraction.
						// When a constructor takes more arguments than the pattern named, the extra ones
						// use the SUBJECT's position, not the constructor's.
						[for (i in 0...sig.args.length) {
							var ap = i < argPositions.length ? argPositions[i] : e.pos;
							TypeFunctions.mk(TEnumParameter(TypeFunctions.mk(subject.expr, subject.type, ap), ef, i),
								TypeFunctions.applyParams(en.params, pl, TypeFunctions.monomorphs(ef.params, sig.args[i].t)), ap);
						}];
					case _: [];
				}
			case ConArray(n):
				// Builds each array-element access at the subject position (e.pos), not the per-element pattern
				// position, so an element read shared across cases takes the array subject's line rather than
				// the first pattern's.
				var et = switch (TypeFunctions.follow(e.type)) { case TInst(_, [t]): t; case _: TypeFunctions.tDynamic; };
				[for (i in 0...n) TypeFunctions.mk(TArray(e, TexprTools.makeInt(mctx.ctx.com.basic, i, e.pos)), et, e.pos)];
			case ConFields(fields):
				// Each field extraction is positioned at the SUBJECT position (e.pos), not the per-field
				// pattern position, so a field shared across cases takes the object subject's line rather
				// than the first pattern's.
				[for (name in fields)
					Typer.accGet(mctx.ctx, Fields.typeField(mctx.ctx, e, name, e.pos, MGet, WithTypeTools.value))];
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
		// A plain (non-GADT) constructor return carries the enum's open type parameter, which
		// unifies with any subject parameter (unifyConstructor spawns it as a mono); only a
		// concrete constructor-side parameter filters GADT-style.
		switch (TypeFunctions.follow(constructor)) {
			case TMono(_): return true;
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))): return true;
			case _:
		}
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

	// True when `t` is one of the enum's own declaration type parameters, i.e. the constructor leaves
	// that position unconstrained.
	static function isTypeParamOf(en:TEnum, t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _): c.kind.match(KTypeParameter(_));
			case _: false;
		}
	}

	static function refineSubjects(subject:TExpr, con:Con, rest:Array<TExpr>):Array<TExpr> {
		var subst:Array<{from:T, to:T}> = switch (con.kind) {
			case ConEnum(en, ef):
				switch [TypeFunctions.follow(subject.type), TypeFunctions.follow(enumConstructorReturn(ef))] {
					case [TEnum(se, stl), TEnum(re, rtl)] if (se == en && re == en && stl.length == rtl.length):
						// Only a GADT constructor genuinely constrains the parameter: BoolLit(b:Bool):E<Bool> returns
						// E<Bool>, so matching it refines the sibling subject's E<S> to E<Bool>. An ordinary
						// constructor returns the enum's own generic form (Some : Option<T>), and substituting
						// towards that rewrites a concrete Option<String> back into Option<T>, leaving the sibling's
						// extraction typed as a bare type parameter.
						[for (i in 0...stl.length) if (!isTypeParamOf(en, rtl[i])) {from: stl[i], to: rtl[i]}];
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

	static function getColumnSigma(subject:TExpr, cases:Array<MatchCase>):{sigma:Array<{con:Con, unguarded:Bool, argPositions:Array<Position>, casePos:Position}>, nullCases:Array<MatchCase>} {
		var sigma:Array<{con:Con, unguarded:Bool, argPositions:Array<Position>, casePos:Position}> = [];
		var unguarded:Array<Con> = [];
		var nullCases:Array<MatchCase> = [];
		function addSigma(con:Con, argPositions:Array<Position>, casePos:Position) {
			for (s in sigma) if (Constructor.equal(s.con, con)) {
				s.argPositions = argPositions;
				s.casePos = casePos;
				// Replacing a constructor table entry stores a new key; it never mutates the one already there.
				// `s.con` is the very Con object the PATTERN still holds, so assigning into it would rewrite
				// the position recorded in every other sub-matrix that shares it. Replace the entry with a
				// fresh Con.
				s.con = {kind: s.con.kind, pos: con.pos, subPos: argPositions.length == 0 ? null : argPositions[0]};
				return;
			}
			// Same aliasing: `con` belongs to the pattern, so store a copy rather than writing
			// subPos into it.
			sigma.push({con: {kind: con.kind, pos: con.pos, subPos: argPositions.length == 0 ? null : argPositions[0]},
				unguarded: false, argPositions: argPositions, casePos: casePos});
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
						addSigma(con, [for (pp in patterns) pp.pos], mc.c.pos);
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

	static function checkCompatiblePatterns(subject:TExpr, sigma:Array<{con:Con, unguarded:Bool, argPositions:Array<Position>, casePos:Position}>):Void {
		if (sigma.length == 0) return;
		var kind = switch (TypeFunctions.follow(subject.type)) {
			case TInst(c, _) if (c.path.pack.length == 0 && c.path.name == "Array"): "length";
			case TEnum(_, _): "enum";
			case TDynamic(_) | TMono(_): switch (sigma[0].con.kind) { case ConArray(_): "length"; case ConEnum(_, _): "enum"; case _: "value"; };
			case TAbstract(a, _) if (a.impl != null && a.isEnum): "value";
			case _: "value";
		};
		for (s in sigma) switch [kind, s.con.kind] {
			case ["length", ConArray(_)]:
			case ["enum", ConEnum(_, _)]:
			case ["value", ConArray(_)] | ["length", _] | ["enum", _]:
				throw new TypingError("Incompatible pattern", s.casePos);
			case _:
		}
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
		checkCompatiblePatterns(subject, sig.sigma);
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
		// A single structure-pattern case is irrefutable and emits no runtime test, but the Switch node
		// is still built: only the converter skips it, and the node it leaves behind carries subject.pos,
		// which the enclosing Bind block takes as its position.
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
		// Identical extractor expressions (after substituting the `_` binder with the subject) SHARE one
		// _hx_tmp binding; the reused case's pattern targets the ORIGINAL extractor's column offsets while
		// still occupying its own subject column.
		var exBindings:Array<{v:TVar, p:Position, e:TExpr, left:Int, right:Int}> = [];
		var newCases:Array<MatchCase> = [];
		var left = 0;
		var right = numEx;
		for (i in 0...cases.length) {
			var mc = cases[i];
			var info = infos[i];
			var restPatterns = mc.patterns.slice(1);
			if (info != null) {
				// Occurrences of the `_` binder inside the extractor expression are replaced by the subject
				// itself; no binding is emitted for it.
				function substSubject(e:TExpr):TExpr {
					return switch (e.expr) {
						case TLocal(v2) if (v2 == info.v): subject;
						case _: TexprTools.mapExpr(substSubject, e);
					}
				}
				var e1 = substSubject(info.e1);
				var found:Null<{v:TVar, p:Position, e:TExpr, left:Int, right:Int}> = null;
				for (b in exBindings) if (TexprTools.equal(e1, b.e)) { found = b; break; }
				if (found == null) {
					var ev = TypeFunctions.allocVar(VExtractorVariable, "_hx_tmp", e1.type, e1.pos);
					found = {v: ev, p: e1.pos, e: e1, left: left, right: right};
					exBindings.push(found);
				}
				exSubjects.push(TexprTools.makeLocal(found.v, e1.pos));
				var patterns = makeOffsetList(found.left + 1, found.right - 1, info.pat, patAny).concat(restPatterns);
				newCases.push({c: mc.c, bindings: info.binds.concat(mc.bindings), patterns: patterns});
				left++;
				right--;
			} else {
				var patterns = makeOffsetList(0, numEx, mc.patterns[0], patAny).concat(restPatterns);
				newCases.push({c: mc.c, bindings: mc.bindings, patterns: patterns});
			}
		}
		var recompSubjects = [subject].concat(exSubjects).concat(rest);
		var dt = compile(mctx, recompSubjects, newCases);
		// The extractor bindings accumulate by PREPENDING, so bind receives the extractor temps
		// newest-first; the declaration order drives RenameVars numbering.
		var bindList = [for (b in exBindings) {v: b.v, p: b.p, e: b.e}];
		bindList.reverse();
		return exBindings.length == 0 ? dt : bind(mctx, bindList, dt);
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

	// The unmatched constructor names of a finite subject (empty when fully covered), or null when the
	// subject's constructor universe is not finite. The names feed the non-exhaustiveness error: constants
	// of an enum abstract render as the declaring static's name; the list is sorted and joined with " | ".
	static function unmatchedFiniteCoverage(com:hxc.context.Context, subjT:T, cases:Array<{con:Con, unguarded:Bool, dt:Dt}>):Null<Array<String>> {
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
		switch (TypeFunctions.follow(subjT)) {
			case TEnum(en, _):
				var found = new Map<String, Bool>();
				for (sc in cases) if (sc.unguarded) switch (sc.con.kind) {
					case ConEnum(en2, ef) if (en2 == en): found.set(ef.name, true);
					case _:
				}
				var missing:Array<String> = [];
				for (name in en.constrs.keys()) {
					var ef = en.constrs.get(name);
					if (DtCompile.enumConstructorCompatible(subjT, en, ef) && !found.exists(name)) missing.push(name);
				}
				return missing;
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
				var missing:Array<String> = [];
				for (cf in a.impl.statics) if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) {
					total++;
					// Force the member so its inline value is present before extraction.
					TypeFunctions.follow(cf.type);
					if (cf.expr == null) hxc.typing.TypeFields.forceFieldBody(com, a.impl, cf);
					var ct = fieldConst(cf);
					if (!found.exists(cf.name) && (ct == null || !foundConst.exists(constKey(ct))))
						// A member without an extractable value (an extern enum abstract) is a static
						// constructor and prints qualified; a constant maps back to the bare field name.
						missing.push(ct == null ? hxc.core.Globals.sTypePath(a.path) + "." + cf.name : cf.name);
				}
				return total > 0 ? missing : null;
			case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Bool"):
				var hasTrue = false;
				var hasFalse = false;
				for (sc in cases) if (sc.unguarded) switch (sc.con.kind) {
					case ConConst(TBool(true)): hasTrue = true;
					case ConConst(TBool(false)): hasFalse = true;
					case _:
				}
				var missing:Array<String> = [];
				if (!hasTrue) missing.push("true");
				if (!hasFalse) missing.push("false");
				return missing;
			case _:
				return null;
		}
	}

	// Subject-local bindings recorded during conversion so a nested counter-example can resolve a bound
	// temp back to the enum parameter it reads.
	static var vLookup:Map<Int, TExpr> = new Map();

	public static function toTexpr(ctx:TyperContext, tSwitch:T, withType:WithType, dt:Dt):Null<TExpr> {
		vLookup = new Map();
		return toTexprRec(ctx, tSwitch, withType, dt, DRToplevel, false);
	}

	static function fieldAccessNameOf(fa:TFieldAccess):String {
		return switch (fa) {
			case FInstance(_, _, cf) | FStatic(_, cf) | FAnon(cf) | FClosure(_, cf): cf.name;
			case FDynamic(s): s;
			case FEnum(_, ef): ef.name;
		};
	}

	// A nested sub-subject (an enum parameter or field read, possibly through a bound temp) wraps the
	// counter-example in its constructor context, e.g. Node(Node, _).
	static function sSubject(s:String, e:TExpr):String {
		function loop(top:Bool, s:String, e:TExpr):String {
			return switch (e.expr) {
				case TField(_, FEnum(_, _)): s;
				case TField(e1, fa): top ? loop(false, s, e1) : loop(false, "{ " + fieldAccessNameOf(fa) + ": " + s + " }", e1);
				case TEnumParameter(e1, ef, i):
					var arity = switch (TypeFunctions.follow(ef.type)) { case TFun(sig): sig.args.length; case _: 0; };
					var parts:Array<String> = [];
					for (k in 0...arity) parts.push(k == i ? s : "_");
					loop(false, ef.name + "(" + parts.join(", ") + ")", e1);
				case TLocal(v):
					var bound = vLookup.get(v.id);
					bound != null ? loop(top, s, bound) : s;
				case _: s;
			};
		}
		return loop(true, s, e);
	}

	// Decision-tree equality; nodes are hashconsed so identity usually decides
	static function dtEquals(d1:Dt, d2:Dt):Bool {
		return d1 == d2 || DtEquality.kindEquals(d1.t, d2.t);
	}

	// A Dynamic or monomorph subject takes its switch type from the first constructor, so an enum match
	// behind a Dynamic still counts as run-time finite.
	static function effectiveSubjectType(subject:TExpr, cases:Array<{con:Con, unguarded:Bool, dt:Dt}>):T {
		return switch (TypeFunctions.follow(subject.type)) {
			case TDynamic(_) | TMono(_) if (cases.length > 0):
				switch (cases[0].con.kind) {
					case ConEnum(en, _): TEnum(en, TypeFunctions.extractParamTypes(en.params));
					case ConStatic(c, _): switch (c.kind) {
						case KAbstractImpl(a): TAbstract(a, TypeFunctions.extractParamTypes(a.params));
						case _: subject.type;
					};
					case _: subject.type;
				};
			case _: subject.type;
		};
	}

	static function toTexprRec(ctx:TyperContext, tSwitch:T, withType:WithType, dt:Dt, rec:DtRecursion, hasDefault:Bool):Null<TExpr> {
		if (dt.texpr != null) return dt.texpr;
		var basic = ctx.com.basic;
		var e:Null<TExpr> = switch (dt.t) {
			case Leaf(c):
				c.expr != null ? c.expr : TypeFunctions.mk(TBlock([]), basic.tvoid, c.pos);
			case Switch(subject, cases, def):
				var branchHasDefault = switch (def.t) { case Fail: false; case _: true; };
				var inheritedDefault = hasDefault || branchHasDefault;
				if (cases.length == 1) {
					switch (cases[0].con.kind) {
						case ConFields(_):
							return toTexprRec(ctx, tSwitch, withType, cases[0].dt, rec == DRToplevel ? DRAfterSwitch : rec, inheritedDefault);
						case _:
					}
				}
				var topLevel = rec.match(DRToplevel);
				var nextRec = topLevel ? DRAfterSwitch : DRDeep;
				var effT = effectiveSubjectType(subject, cases);
				var unmatched = unmatchedFiniteCoverage(ctx.com, effT, cases);
				var complete = unmatched != null && unmatched.length == 0;
				// Only a run-time-finite subject (a true enum or Bool) can drop its default branch; an enum
				// abstract is compile-time finite, so a runtime value can be out of range and a user
				// default must be kept.
				var runtimeFinite = switch (TypeFunctions.follow(effT)) {
					case TEnum(_, _): true;
					case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Bool"): true;
					case _: false;
				};
				function reportUnmatched():Void {
					var s = if (unmatched == null || unmatched.length == 0) "_" else {
						unmatched.sort(Reflect.compare);
						unmatched.join(" | ");
					};
					var errorPos = switch (subject.expr) {
						case TField(_, FEnum(_, _)): dt.pos;
						case _: subject.pos;
					};
					throw new TypingError("Unmatched patterns: " + sSubject(s, subject), errorPos);
				}
				function hasFail(d:Dt):Bool return switch (d.t) {
					case Fail: true;
					case Bind(_, d1): hasFail(d1);
					case Guard(_, _, d2) | GuardNull(_, _, d2): hasFail(d2);
					case Switch(sub, subCases, dflt):
						// A complete run-time-finite sub-switch (its cases cover every constructor of a
						// true enum or Bool) drops its default at texpr time, exactly as
						// droppedCompleteDefault does below, so the Fail there is dead and does not make
						// the enclosing constructor a partial match. Otherwise `case C(Prefix): ..; case
						// C(Postfix): ..;` would read as leaving C(_) unmatched even though {Prefix,
						// Postfix} exhausts the argument.
						var subT = effectiveSubjectType(sub, subCases);
						var subUnmatched = unmatchedFiniteCoverage(ctx.com, subT, subCases);
						var subComplete = subUnmatched != null && subUnmatched.length == 0;
						var subRuntimeFinite = switch (TypeFunctions.follow(subT)) {
							case TEnum(_, _): true;
							case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Bool"): true;
							case _: false;
						};
						(subComplete && subRuntimeFinite) ? false : hasFail(dflt);
					case Leaf(_): false;
				};
				var enumParamRoot = switch (subject.expr) {
					case TEnumParameter(e1, _, _): switch (e1.expr) { case TField(_, _): false; case _: true; };
					case _: false;
				};
				var constructorBound = switch (subject.expr) {
					case TLocal(v): switch (vLookup.get(v.id)) { case {expr: TCall(_, _)}: true; case _: false; };
					case _: false;
				};
				var reportPartial = withType.match(NoValue) && !branchHasDefault && !hasDefault
					&& (enumParamRoot || (topLevel && (constructorBound || cases.length > 1)));
				if (reportPartial && def.t.match(Fail)) switch (TypeFunctions.follow(subject.type)) {
					case TEnum(_, _):
						for (sc in cases) {
							switch (sc.con.kind) {
							case ConEnum(_, ef) if (Constructor.arity(sc.con) > 0 && hasFail(sc.dt)):
								throw new TypingError("Unmatched patterns: " + ef.name + "(_)", sc.con.subPos == null ? sc.con.pos : sc.con.subPos);
							case _:
							}
						}
					case _:
				}
				// The default converts and reports first so a missing constructor at this switch is the
				// counter-example, not a deeper unmatched constant inside a case branch. A case branch that
				// fails to convert (a guard whose fall-through is unmatched) reports like a missing default. A
				// run-time-finite subject (enum/Bool) whose cases cover every constructor drops its default at
				// any nesting level, not only at top level; the toplevel condition governs only the Infinite
				// no-value exhaustiveness error.
				var droppedCompleteDefault = complete && runtimeFinite;
				var defE = droppedCompleteDefault ? null : toTexprRec(ctx, tSwitch, withType, def, nextRec, inheritedDefault);
				var nullaryMissing = switch (TypeFunctions.follow(effT)) {
					case TEnum(en, _) if (unmatched != null):
						var ok = true;
						var missingNames = unmatched == null ? [] : unmatched;
						for (name in missingNames) {
							var ef = en.constrs.get(name);
							if (ef == null) ok = false;
							switch (ef == null ? null : TypeFunctions.follow(ef.type)) {
								case TFun(sig) if (sig.args.length > 0): ok = false;
								case _:
							}
						}
						ok;
					case _: false;
				};
				var reportFiniteNoValue = topLevel && runtimeFinite && !branchHasDefault && nullaryMissing;
				// An enum abstract is compile-time finite: a missing member reports even for a statement
				// switch. (only NoValue+Infinite stays silent; CompileTimeFinite is silent only when
				// unmatched is empty).
				var compileTimeFiniteUnmatched = unmatched != null && unmatched.length > 0 && switch (TypeFunctions.follow(effT)) {
					case TAbstract(a, _) if (a.isEnum && a.impl != null): true;
					case _: false;
				};
				if (defE == null && !complete && (!withType.match(NoValue) || reportFiniteNoValue || compileTimeFiniteUnmatched)) reportUnmatched();
				// Group: cases that share a decision emit one case with several values, sorted by constructor
				// order
				var groups:Array<{cons:Array<Con>, dt:Dt}> = [];
				for (sc in cases) {
					var found = null;
					for (g in groups) if (dtEquals(g.dt, sc.dt)) { found = g; break; }
					if (found == null) groups.push({cons: [sc.con], dt: sc.dt});
					else found.cons.unshift(sc.con);
				}
				groups.sort(function(g1, g2) return Constructor.compare(g1.cons[0], g2.cons[0]));
				var caseFailed = false;
				var swCases:Array<TSwitchCase> = [];
				for (g in groups) {
					var ce = toTexprRec(ctx, tSwitch, withType, g.dt, nextRec, inheritedDefault);
					if (ce != null) {
						g.cons.sort(Constructor.compare);
						swCases.push({values: [for (c in g.cons) Constructor.toTexpr(ctx, false, c)], expr: ce});
					} else caseFailed = true;
				}
				if (caseFailed && !(unmatched != null && unmatched.length == 0 && !runtimeFinite)
					&& !withType.match(NoValue))
					reportUnmatched();
				// An enum switch dispatches on the constructor index.
				var isNullableSubject = TypeFunctions.isExplicitNull(subject.type);
				var swSubject = if (cases.length == 0) subject else switch (cases[0].con.kind) {
					case ConEnum(_, _): TypeFunctions.mk(TEnumIndex(subject), basic.tint, subject.pos);
					case ConArray(_): arrayLengthExpr(ctx, subject);
					case _: subject;
				};
				// A small switch is reduced before emitting TSwitch: a single unconditional finite case
				// becomes its own body; a single case with a default (or in a no-value context) becomes an
				// if, fusing a nested if that shares the default with &&; two bool cases become an if on
				// the subject.
				var single = swCases.length == 1 && swCases[0].values.length == 1;
				var reduced:Null<TExpr> = null;
				if (swCases.length == 1 && defE == null && complete && runtimeFinite && !isNullableSubject) {
					var b = swCases[0].expr;
					reduced = TypeFunctions.mk(b.expr, tSwitch, b.pos);
				} else if (single && (defE != null || withType.match(NoValue))) {
					var e1 = swCases[0].values[0];
					var e2 = swCases[0].expr;
					var eOp = TypeFunctions.mk(TBinop(OpEq, swSubject, e1), basic.tbool, swSubject.pos);
					reduced = switch (e2.expr) {
						case TIf(eOp2, e3, edef2) if (defE != null && edef2 != null && edef2 == defE):
							var eand = TypeFunctions.mk(TBinop(OpBoolAnd, eOp, eOp2), basic.tbool, Position.union(eOp.pos, eOp2.pos));
							TypeFunctions.mk(TIf(eand, e3, defE), tSwitch, dt.pos);
						case _:
							TypeFunctions.mk(TIf(eOp, e2, defE), tSwitch, dt.pos);
					};
				} else if (defE == null && swCases.length == 2 && swCases[0].values.length == 1 && swCases[1].values.length == 1) {
					inline function boolOf(e:TExpr):Null<Bool> return switch (e.expr) { case TConst(TBool(b)): b; case _: null; };
					var b0 = boolOf(swCases[0].values[0]), b1 = boolOf(swCases[1].values[0]);
					if (b0 == true && b1 == false)
						reduced = TypeFunctions.mk(TIf(swSubject, swCases[0].expr, swCases[1].expr), tSwitch, dt.pos);
					else if (b0 == false && b1 == true)
						reduced = TypeFunctions.mk(TIf(swSubject, swCases[1].expr, swCases[0].expr), tSwitch, dt.pos);
				}
				if (reduced != null) reduced else {
					// A FINITE COMPLETE switch whose default was dropped marks its subject @:exhaustive so the
					// init checker credits assignments made in every branch. This covers RunTimeFinite (enums,
					// Bool) and CompileTimeFinite (a complete enum-abstract switch, whose default the conversion
					// drops the same way). A merely default-less switch (a String subject falling through) must
					// not be marked: downstream analysis would treat it as always-terminating and drop the
					// fall-through code.
					var compileTimeFinite = complete && switch (TypeFunctions.follow(effT)) {
						case TAbstract(a, _): a.impl != null && a.isEnum;
						case _: false;
					};
					if ((droppedCompleteDefault || compileTimeFinite) && defE == null)
						swSubject = TypeFunctions.mk(TMeta({name: ":exhaustive", params: [], pos: dt.pos}, swSubject), swSubject.type, swSubject.pos);
					TypeFunctions.mk(TSwitch(swSubject, swCases, defE), tSwitch, dt.pos);
				}
			case Guard(e, dt1, dt2):
				var eThen = toTexprRec(ctx, tSwitch, withType, dt1, rec, hasDefault);
				if (eThen == null) null else {
					var eElse = toTexprRec(ctx, tSwitch, withType, dt2, rec, hasDefault);
					if (eElse != null) TypeFunctions.mk(TIf(e, eThen, eElse), tSwitch, Position.union(eThen.pos, eElse.pos));
					else if (withType.match(NoValue) && (rec.match(DRToplevel) || rec.match(DRAfterSwitch)))
						TypeFunctions.mk(TIf(e, eThen, null), basic.tvoid, Position.union(e.pos, eThen.pos));
					else null;
				}
			case GuardNull(e, dt1, dt2):
				var topLevel = rec.match(DRToplevel);
				var eThen = toTexprRec(ctx, tSwitch, withType, dt1, rec, hasDefault);
				var eElse = toTexprRec(ctx, tSwitch, withType, dt2, rec, hasDefault);
				if (eThen == null) {
					if (topLevel || withType.match(NoValue)) eElse else throw new TypingError("Unmatched patterns: null", e.pos);
				} else if (eElse == null) {
					if (topLevel || withType.match(NoValue)) {
						var eNull = TypeFunctions.mk(TConst(TNull), e.type, e.pos);
						var cond = TypeFunctions.mk(TBinop(OpEq, e, eNull), basic.tbool, e.pos);
						// GuardNull without an else: the TIf is positioned at eThen.pos alone
						TypeFunctions.mk(TIf(cond, eThen, null), basic.tvoid, eThen.pos);
					} else throw new TypingError("Unmatched patterns: _", e.pos);
				} else {
					var eNull = TypeFunctions.mk(TConst(TNull), e.type, e.pos);
					var cond = TypeFunctions.mk(TBinop(OpEq, e, eNull), basic.tbool, e.pos);
					// GuardNull with both branches: the union of eThen.pos and eElse.pos (the branch
					// EXPRESSIONS, i.e. the case bodies), not the dt span
					TypeFunctions.mk(TIf(cond, eThen, eElse), tSwitch, Position.union(eThen.pos, eElse.pos));
				}
			case Bind(bl, dt2):
				if (Sys.getEnv("HXC_DBG_MATCH") != null)
					for (b in bl) Sys.println("[match-bind] " + b.v.name + " kind=" + Std.string(b.v.kind) + " at " + b.p.file + ":" + hxc.ast.Position.lineNumber(b.p));
				for (b in bl) vLookup.set(b.v.id, b.e);
				var inner = toTexprRec(ctx, tSwitch, withType, dt2, rec, hasDefault);
				if (inner == null) null else {
					var el = [for (b in bl) TypeFunctions.mk(TVarExpr(b.v, b.e), basic.tvoid, b.p)];
					el.push(inner);
					// The arm binds as Bind(bl, dt) over the inner node, so the block takes the INNER
					// node's position. The two differ whenever hashcons handed back an existing Bind:
					// bind() proposes dt.pos but a dedup keeps the first one's.
					TypeFunctions.mk(TBlock(el), inner.type, dt2.pos);
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

	static function inferSwitchType(ctx:TyperContext, withType:WithType, cases:Array<MatchCase>, allowMinVoid:Bool):T {
		return switch (withType) {
			case NoValue: ctx.com.basic.tvoid;
			case Value(_):
				if (cases.length == 0) ctx.com.basic.tvoid
				// In an implicit-return context a Void branch collapses the whole switch to Void so a
				// sibling value branch is discarded rather than fought over.
				else if (allowMinVoid) Typer.unifyMinForTypeSource(ctx, [for (mc in cases) bodyExpr(ctx, mc.c)], ImplicitReturn);
				else Typer.unifyMin(ctx, [for (mc in cases) bodyExpr(ctx, mc.c)]);
			case WithType(t, _): t;
		};
	}


	public static function matchExpr(ctx:TyperContext, e:Expr, cases:Array<SwitchCase>, def:Null<{e:Null<Expr>, pos:Position}>, withType:WithType, postfix:Bool, p:Position):TExpr {
		// An empty switch types only its subject: as a statement it is the subject's evaluation, as a value
		// it is Void (no exhaustiveness runs, the reader of the value reports).
		if (cases.length == 0 && def == null) {
			var te = Typer.typeExpr(ctx, e, WithTypeTools.value);
			if (withType.match(NoValue)) return te;
			return TypeFunctions.mk(TBlock([te]), ctx.com.basic.tvoid, p);
		}
		// `switch [a, b]` (a bracket literal, possibly parenthesized) is a tuple match: each element is its
		// own subject with its own type, and the case patterns match column by column. A single
		// comprehension element is a real array, not a tuple.
		function tupleOf(ex:Expr):Null<Array<Expr>> {
			return switch (ex.expr) {
				case EParenthesis(e1): tupleOf(e1);
				case EArrayDecl([{expr: EFor(_, _) | EWhile(_, _, _)}]): null;
				case EArrayDecl(l): l;
				case _: null;
			}
		}
		var tupleEls:Null<Array<Expr>> = tupleOf(e);
		var subjects:Array<TExpr>;
		var subjectTypes:Array<T>;
		if (tupleEls != null) {
			subjects = [for (se in tupleEls) Typer.typeExpr(ctx, se, WithTypeTools.value)];
			subjectTypes = [for (s in subjects) s.type];
		} else {
			// The subject's parentheses strip syntactically so a plain local subject stays a TLocal and
			// needs no generated temp.
			var unwrapped = e;
			var stripping = true;
			while (stripping) switch (unwrapped.expr) {
				case EParenthesis(e1): unwrapped = e1;
				case _: stripping = false;
			}
			var subjectE = Typer.typeExpr(ctx, unwrapped, WithTypeTools.value);
			subjects = [subjectE];
			subjectTypes = [subjectE.type];
		}
		PatternMaker.matchSubjectPos = subjects.length > 0 ? subjects[0].pos : p;
		// An unbound monomorph expected type gives the case bodies nothing to check against; the first body
		// would bind it and every sibling branch would then have to unify with that one type. Type the
		// bodies as plain values, infer the common type, and unify it back into the monomorph. An
		// implicit-return Void keeps its source and skips the final unification.
		var tmono:Null<T> = null;
		var allowMinVoid = false;
		switch (withType) {
			case WithType(t, src):
				var isImplicitReturn = src != null && src.match(ImplicitReturn);
				switch (TypeFunctions.follow(t)) {
					case TMono(m) if (m.type == null):
						tmono = t;
						allowMinVoid = isImplicitReturn;
						withType = isImplicitReturn ? Value(src) : WithTypeTools.value;
					case TAbstract(a, _) if (isImplicitReturn && a.path.pack.length == 0 && a.path.name == "Void"):
						tmono = t;
						allowMinVoid = true;
						withType = Value(src);
					case _:
				}
			case _:
		}
		var allCases = cases.copy();
		if (def != null) allCases.push({values: [new Expr(EConst(CIdent("_")), def.pos)], guard: null, expr: def.e, pos: def.pos});
		var matchCases:Array<MatchCase> = [];
		for (cas in allCases) {
			// A case decoded without a position (Position.nullPos) takes its body's position
			if (cas.pos == Position.nullPos && cas.expr != null) cas = {values: cas.values, guard: cas.guard, expr: cas.expr, pos: cas.expr.pos};
			if (tupleEls != null) {
				// `case [p..]|[q..]:` over a tuple stays one case whose pattern is a PatOr of tuples, so
				// both branches share one leaf and merge at conversion.
				var r = CaseMaker.makeTuple(ctx, subjectTypes, cas.values, cas.guard, cas.expr, withType, postfix, cas.pos);
				matchCases.push({c: r.c, bindings: [], patterns: r.pats});
			} else {
				var r = CaseMaker.make(ctx, subjectTypes[0], cas.values, cas.guard, cas.expr, withType, postfix, cas.pos);
				matchCases.push({c: r.c, bindings: [], patterns: [r.pat]});
			}
		}
		UnusedPatternCheck.check(ctx, matchCases);
		var tSwitch = inferSwitchType(ctx, withType, matchCases, allowMinVoid);
		if (tmono != null) {
			var skip = allowMinVoid && switch (TypeFunctions.follow(tmono)) {
				case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
				case _: false;
			};
			if (!skip) try hxc.core.TypeUnification.unifyDefault(tSwitch, tmono)
				catch (err:hxc.core.TypeUnification.UnifyError) throw new TypingError(hxc.core.TPrinting.betterErrorMessage(err.errors), p);
		}
		var dt = DtCompile.compileEntry(ctx, false, subjects, matchCases, p);
		var te = TexprConverter.toTexpr(ctx, tSwitch, withType, dt);
		if (te == null) throw new TypingError("Unmatched patterns: _", p);
		// The decision tree shares a subtree reached from several branches, so the converted expression can
		// contain the same node twice. Duplicate the variables so every declaration site is its own var and
		// no subtree is shared.
		te = TexprTools.duplicateTvars(function(x) return x, te);
		te = varLazify(te);
		// The converted match is repositioned to the whole switch expression's position
		return TypeFunctions.mk(te.expr, te.type, p);
	}

	// An extractor variable's initialization moves from its declaration to its first use, so a guard (e.g.
	// the null check before an extractor) runs before the extractor expression evaluates. It is applied per
	// match expression since extractor variables are declared and used only inside the match's own tree.
	static function varLazify(e:TExpr):TExpr {
		var inits = new Map<Int, TExpr>();
		function copyInits(src:Map<Int, TExpr>):Map<Int, TExpr> {
			var r = new Map<Int, TExpr>();
			for (k in src.keys()) r.set(k, src.get(k));
			return r;
		}
		function loop(e:TExpr):TExpr {
			function sub(x:TExpr):TExpr return loop(x);
			return switch (e.expr) {
				case TVarExpr(v, e1) if (e1 != null && v.kind.match(VExtractorVariable)):
					inits.set(v.id, e1);
					TypeFunctions.mk(TVarExpr(v, null), e.type, e.pos);
				case TLocal(v) if (inits.exists(v.id)):
					var einit = inits.get(v.id);
					inits.remove(v.id);
					einit = loop(einit);
					TypeFunctions.mk(TParenthesis(TypeFunctions.mk(TBinop(OpAssign, e, einit), e.type, e.pos)), e.type, e.pos);
				case TIf(e1, e2, eo):
					var e1b = sub(e1);
					var saved = copyInits(inits);
					var e2b = sub(e2);
					inits = copyInits(saved);
					var eob = eo == null ? null : sub(eo);
					inits = saved;
					TypeFunctions.mk(TIf(e1b, e2b, eob), e.type, e.pos);
				case TWhile(e1, e2, flag):
					var e1b = sub(e1);
					var saved = copyInits(inits);
					var e2b = sub(e2);
					inits = saved;
					TypeFunctions.mk(TWhile(e1b, e2b, flag), e.type, e.pos);
				case TSwitch(e1, cases, edef):
					var e1b = sub(e1);
					var saved = copyInits(inits);
					var cs:Array<TSwitchCase> = [];
					for (c in cases) {
						var ce = sub(c.expr);
						inits = copyInits(saved);
						cs.push({values: c.values, expr: ce});
					}
					var db = edef == null ? null : sub(edef);
					inits = saved;
					TypeFunctions.mk(TSwitch(e1b, cs, db), e.type, e.pos);
				case TTry(e1, catches):
					var saved = copyInits(inits);
					var e1b = sub(e1);
					inits = copyInits(saved);
					var cts:Array<TCatch> = [];
					for (c in catches) {
						var ce = sub(c.expr);
						inits = copyInits(saved);
						cts.push({v: c.v, expr: ce});
					}
					inits = saved;
					TypeFunctions.mk(TTry(e1b, cts), e.type, e.pos);
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_):
					e;
				case TArray(e1, e2): TypeFunctions.mk(TArray(sub(e1), sub(e2)), e.type, e.pos);
				case TBinop(op, e1, e2): TypeFunctions.mk(TBinop(op, sub(e1), sub(e2)), e.type, e.pos);
				case TField(e1, fa): TypeFunctions.mk(TField(sub(e1), fa), e.type, e.pos);
				case TParenthesis(e1): TypeFunctions.mk(TParenthesis(sub(e1)), e.type, e.pos);
				case TObjectDecl(fields): TypeFunctions.mk(TObjectDecl([for (f in fields) {key: f.key, expr: sub(f.expr)}]), e.type, e.pos);
				case TArrayDecl(values): TypeFunctions.mk(TArrayDecl([for (x in values) sub(x)]), e.type, e.pos);
				case TCall(e1, params): TypeFunctions.mk(TCall(sub(e1), [for (x in params) sub(x)]), e.type, e.pos);
				case TNew(c, params, args): TypeFunctions.mk(TNew(c, params, [for (x in args) sub(x)]), e.type, e.pos);
				case TUnop(op, flag, e1): TypeFunctions.mk(TUnop(op, flag, sub(e1)), e.type, e.pos);
				case TFunction(f): TypeFunctions.mk(TFunction(new TFunc(f.args, f.type, sub(f.expr))), e.type, e.pos);
				case TVarExpr(v, e1): TypeFunctions.mk(TVarExpr(v, e1 == null ? null : sub(e1)), e.type, e.pos);
				case TBlock(exprs): TypeFunctions.mk(TBlock([for (x in exprs) sub(x)]), e.type, e.pos);
				case TFor(v, e1, e2): TypeFunctions.mk(TFor(v, sub(e1), sub(e2)), e.type, e.pos);
				case TReturn(e1): TypeFunctions.mk(TReturn(e1 == null ? null : sub(e1)), e.type, e.pos);
				case TThrow(e1): TypeFunctions.mk(TThrow(sub(e1)), e.type, e.pos);
				case TCast(e1, mt): TypeFunctions.mk(TCast(sub(e1), mt), e.type, e.pos);
				case TMeta(m, e1): TypeFunctions.mk(TMeta(m, sub(e1)), e.type, e.pos);
				case TEnumParameter(e1, ef, idx): TypeFunctions.mk(TEnumParameter(sub(e1), ef, idx), e.type, e.pos);
				case TEnumIndex(e1): TypeFunctions.mk(TEnumIndex(sub(e1)), e.type, e.pos);
			}
		}
		return loop(e);
	}
}
