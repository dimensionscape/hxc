package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.Texpr;
import hxc.core.WithType;
import hxc.core.Globals;
import hxc.core.TypingError;

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
				matchDebug ? Texpr.makeString(basic, ef.name, p) : Texpr.makeInt(basic, ef.index, p);
			case ConConst(ct): Texpr.makeConstTexpr(basic, ct, p);
			case ConArray(i): Texpr.makeInt(basic, i, p);
			case ConStatic(c, cf): Texpr.makeStaticField(c, cf, p);
			case ConTypeExpr(_): throw new TypingError("Constructor.to_texpr for a type expression is not yet ported", p);
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

class PatternContext {
	public var ctx:TyperContext;
	public var orLocals:Null<Map<String, {v:TVar, p:Position}>>;
	public var ctxLocals:Map<String, TVar>;
	public var currentLocals:Map<String, {v:TVar, p:Position}>;
	public var inReification:Bool;
	public var isPostfixMatch:Bool;

	public function new(ctx:TyperContext, ctxLocals:Map<String, TVar>) {
		this.ctx = ctx;
		this.orLocals = null;
		this.ctxLocals = ctxLocals;
		this.currentLocals = new Map();
		this.inReification = false;
		this.isPostfixMatch = false;
	}
}

class PatternMaker {
	static function unify(ctx:TyperContext, a:T, b:T, p:Position):Void {
		try TypeUnification.unifyDefault(a, b) catch (_:UnifyError) throw new TypingError("Cannot unify types in pattern", p);
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

	static function handleIdent(pctx:PatternContext, t:T, i:String, p:Position):PatKind {
		try {
			var e = Typer.typeExpr(pctx.ctx, new Expr(EConst(CIdent(i)), p), WithTypeTools.withType(t));
			switch (e.expr) {
				case TConst(ct): unify(pctx.ctx, e.type, t, p); return PatConstructor(Constructor.make(ConConst(ct), p), []);
				case TField(_, FEnum(en, ef)): unify(pctx.ctx, e.type, t, p); return PatConstructor(Constructor.make(ConEnum(en, ef), p), []);
				case TField(_, FStatic(c, cf)): unify(pctx.ctx, e.type, t, p); return PatConstructor(Constructor.make(ConStatic(c, cf), p), []);
				case _:
			}
		} catch (_:TypingError) {}
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
			case EConst(CInt(_, _)) | EConst(CFloat(_, _)) | EConst(CString(_, _)) | EConst(CIdent("true")) | EConst(CIdent("false")):
				var ce = Texpr.typeConstant(basic, switch (e.expr) { case EConst(c): c; case _: throw "unreachable"; }, p);
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
		try TypeUnification.unifyDefault(a, b) catch (_:UnifyError) throw new TypingError("Cannot unify types", p);
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
		var pctx = new PatternContext(ctx, ctx.locals);
		pctx.isPostfixMatch = postfixMatch;
		var pat = PatternMaker.make(pctx, true, t, e);
		var egT:Null<TExpr> = if (eg == null) null else {
			var ge = Typer.typeExpr(ctx, eg, WithTypeTools.value);
			Typer.castOrUnify(ctx, ctx.com.basic.tbool, ge, ge.pos);
		};
		var eoT:Null<TExpr> = switch ([eoAst, withType]) {
			case [null, WithType(wt, _)]:
				unify(ctx, ctx.com.basic.tvoid, wt, e.pos);
				null;
			case [null, _]:
				null;
			case [body, WithType(wt, _)]:
				var be = Typer.typeExpr(ctx, body, WithTypeTools.withType(wt));
				Typer.castOrUnify(ctx, wt, be, be.pos);
			case [body, _]:
				Typer.typeExpr(ctx, body, withType);
		};
		save();
		return {c: {guard: egT, expr: eoT, pos: p}, pat: pat};
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
}
