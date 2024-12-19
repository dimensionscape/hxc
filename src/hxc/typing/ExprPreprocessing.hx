package hxc.typing;

import hxc.ast.Ast;
import hxc.ast.Ast.Expr;
import hxc.ast.Ast.EVar;
import hxc.ast.Ast.SwitchCase;
import hxc.ast.Position;

// Before a field body in the display file is typed, exactly one node in it is marked as the display
// SUBJECT, bottom-up, and the request is answered from that node alone. Several arms instead give
// up outright, which is how "No completion point was found" is answered at a position later stages
// would happily complete.
class ExprPreprocessing {
	// Exactly one node can claim the position, and everything enclosing it declines.
	static var wasAnnotated:Bool = false;
	static var isCompletion:Bool = false;
	static var isHover:Bool = false;
	static var inPattern:Bool = false;
	static var dpos:Int = -1;

	// The pass gave up: the expression comes back unmarked, so nothing in it carries an EDisplay and
	// no expression-level answer is produced.
	static var gaveUp:Bool = false;

	/**
		Returns null when the pass gave up, which is hxc's signal that no expression in this body may
		answer the request; otherwise the annotated expression.
	**/
	public static function process(e:Expr):Null<Expr> {
		// Runs find_before_pos for the modes that ask about an expression, and find_display_call (hxc:
		// the parser's signature mark) for DMSignature.
		if (!hxc.parser.Parser.displayCompletionMode && !hxc.parser.Parser.displayHoverMode) return e;
		dpos = hxc.parser.Parser.displayOffset;
		if (dpos < 0) return e;
		// DMDefault encloses inclusively and is a completion; DMHover's upper bound is strict; every
		// other mode encloses inclusively and is not a completion.
		isHover = hxc.parser.Parser.displayHoverMode;
		isCompletion = !isHover && hxc.parser.Parser.displayCompletionMode;
		wasAnnotated = false;
		inPattern = false;
		gaveUp = false;
		var r = map(e);
		return gaveUp ? null : r;
	}

	public static function inDisplayFile(p:Position):Bool {
		var df = hxc.parser.Parser.displayFile;
		if (df == null || p.file == null) return false;
		var f = StringTools.replace(p.file, "\\", "/");
		var d = StringTools.replace(df, "\\", "/");
		return f == d || StringTools.endsWith(f, "/" + d) || StringTools.endsWith(d, "/" + f);
	}

	static function isAnnotated(p:Position):Bool {
		if (wasAnnotated || dpos < 0 || !inDisplayFile(p)) return false;
		return isHover ? (p.min <= dpos && dpos < p.max) : (p.min <= dpos && dpos <= p.max);
	}

	// Cleared per request, not per field: only one field can hold the cursor, and the macro world
	// types its own fields through the same entry point while a macro call is running.
	public static var markedNode:Null<Expr> = null;
	public static var markedKind:hxc.ast.Ast.DisplayKind = DKMarked;

	static function annotate(e:Expr, dk:hxc.ast.Ast.DisplayKind):Expr {
		wasAnnotated = true;
		markedNode = e;
		markedKind = dk;
		return new Expr(EDisplay(e, dk), e.pos);
	}

	static inline function annotateMarked(e:Expr):Expr return annotate(e, DKMarked);

	static function mkNull(p:Position):Expr {
		return annotateMarked(new Expr(EConst(CIdent("null")), p));
	}

	// The marker goes before the first element that STARTS at or after the cursor, and at the end of
	// the list when there is none. It never asks whether the cursor is inside an earlier element -
	// an element that encloses it has already annotated itself, which is what wasAnnotated above
	// records.
	static function loopEl(el:Array<Expr>, pe:Position):Array<Expr> {
		var pr = new Position(pe.file, dpos, dpos);
		var out:Array<Expr> = [];
		var i = 0;
		while (i < el.length) {
			if (el[i].pos.min >= pr.max) {
				out.push(mkNull(pr));
				while (i < el.length) { out.push(el[i]); i++; }
				return out;
			}
			out.push(el[i]);
			i++;
		}
		out.push(mkNull(pr));
		return out;
	}

	static function map(e:Expr):Expr {
		// A switch recurses by hand so its PATTERNS are mapped with inPattern set.
		return switch (e.expr) {
			case ESwitch(e1, cases, def) if (isAnnotated(e.pos)):
				var me1 = map(e1);
				var mcases:Array<SwitchCase> = [
					for (c in cases) {
						var old = inPattern;
						inPattern = true;
						var vals = [for (v in c.values) map(v)];
						inPattern = old;
						{
							values: vals,
							guard: c.guard == null ? null : map(c.guard),
							expr: c.expr == null ? null : map(c.expr),
							pos: c.pos
						};
					}
				];
				var mdef = def == null ? null : {e: def.e == null ? null : map(def.e), pos: def.pos};
				loop(new Expr(ESwitch(me1, mcases, mdef), e.pos));
			case _:
				// Rebuild only along the path that actually changed. hxc keys several display
				// mechanisms on node IDENTITY (Typer.markedDisplay, Typer.synthesizedNodes), so a
				// wholesale copy of the body silently defeats all of them.
				var changed = false;
				var mapped = Ast.mapExpr(function(c) {
					var m = map(c);
					if (m != c) changed = true;
					return m;
				}, e);
				loop(changed ? mapped : e);
		}
	}

	static function loop(e:Expr):Expr {
		switch (e.expr) {
			// The cursor on a local function's name answers nothing at all.
			case EFunction(FKNamed(name, _), _) if (isAnnotated(name.pos) && isCompletion):
				gaveUp = true;
				return e;

			// The cursor on a var name marks nothing (the declaration answers it, and every var after it is
			// left alone); otherwise the first initializer whose LEADING GAP holds the cursor becomes the
			// subject.
			case EVars(vl) if (isAnnotated(e.pos) && isCompletion):
				var acc:Array<EVar> = [];
				var mark = false;
				for (v in vl) {
					if (mark) {
						acc.push(v);
					} else if (isAnnotated(v.evName.pos)) {
						acc.push(v);
						mark = true;
					} else if (v.evExpr == null) {
						// No initializer: nothing to do here. A cursor on the type hint is picked
						// up while the hint loads.
						acc.push(v);
					} else {
						var p0 = v.evType != null ? v.evType.pos : v.evName.pos;
						var p = new Position(p0.file, p0.min, v.evExpr.pos.min);
						var ve = isAnnotated(p) ? annotateMarked(v.evExpr) : v.evExpr;
						acc.push({
							evName: v.evName,
							evFinal: v.evFinal,
							evStatic: v.evStatic,
							evType: v.evType,
							evExpr: ve,
							evMeta: v.evMeta
						});
					}
				}
				// The declarations come back out in reverse order.
				acc.reverse();
				if (!wasAnnotated) {
					gaveUp = true;
					return e;
				}
				return new Expr(EVars(acc), e.pos);

			// An assignment whose operands are not themselves the subject is "probably" a question about
			// the
			// right-hand side.
			case EBinop(op = OpAssign | OpAssignOp(_), e1, e2) if (isAnnotated(e.pos) && isCompletion):
				return new Expr(EBinop(op, e1, annotateMarked(e2)), e.pos);

			// This has to come from an attempted `case pattern | guard:` completion.
			case EBinop(OpOr, e1, e2 = {expr: EIf(_, {expr: EConst(CIdent("null"))}, null)})
				if (isAnnotated(e.pos) && isCompletion && inPattern):
				var p = new Position(e2.pos.file, e1.pos.max, e2.pos.min);
				return new Expr(EBinop(OpOr, e1, mkNull(p)), e.pos);

			case EIf(_, {expr: EConst(CIdent("null"))}, null) if (isCompletion && inPattern):
				return mkNull(e.pos);

			case EBlock([]) if (isAnnotated(e.pos)):
				return annotate(e, DKStructure);

			// A block holding exactly the marked identifier is a structure literal.
			case EBlock([{expr: EDisplay({expr: EConst(CIdent(s)), pos: pn}, DKMarked)}]):
				if (!isCompletion) {}
				else {
					var od = new Expr(EObjectDecl([
						{name: s, pos: pn, quotes: NoQuotes, expr: new Expr(EConst(CIdent("null")), Position.nullPos)}
					]), e.pos);
					return annotate(od, DKStructure);
				}

			case EBlock(el) if (isAnnotated(e.pos) && isCompletion):
				return new Expr(EBlock(loopEl(el, e.pos)), e.pos);

			case ECall(e1, el) if (isAnnotated(e.pos) && isCompletion):
				return new Expr(ECall(e1, loopEl(el, e.pos)), e.pos);

			case ENew(tp, el) if (isAnnotated(e.pos) && isCompletion):
				if (isAnnotated(tp.pos) || tp.pos.max >= dpos) return annotateMarked(e);
				return new Expr(ENew(tp, loopEl(el, e.pos)), e.pos);

			case EArrayDecl(el) if (isAnnotated(e.pos) && isCompletion):
				return new Expr(EArrayDecl(loopEl(el, e.pos)), e.pos);

			case EObjectDecl(_) if (isAnnotated(e.pos) && isCompletion):
				return annotate(e, DKStructure);

			// The cursor is BETWEEN two cases, or at the end of the last one. Mark the last case whose
			// position is before it. This is the one arm that may DECLINE a position it encloses - the
			// case's end lying past the cursor is what keeps it from firing on the `}`.
			case ESwitch(e1, cases, def) if (isAnnotated(e.pos)):
				var didMark = false;
				function markCase(ec:Null<Expr>, p:Position):Expr {
					didMark = true;
					var ep = mkNull(p);
					if (ec == null) return mkNull(p);
					return switch (ec.expr) {
						case EBlock(el): new Expr(EBlock(el.concat([ep])), p);
						case _: new Expr(EBlock([ec, ep]), p);
					}
				}
				var out = cases.copy();
				var i = 0;
				var done = false;
				while (i < out.length && !done) {
					var c = out[i];
					if (i == out.length - 1) {
						if (def == null) {
							if (e.pos.max > dpos)
								out[i] = {values: c.values, guard: c.guard, expr: markCase(c.expr, c.pos), pos: c.pos};
						} else if (c.pos.max <= dpos && def.pos.min >= dpos) {
							out[i] = {values: c.values, guard: c.guard, expr: markCase(c.expr, c.pos), pos: c.pos};
						}
						done = true;
					} else {
						var c2 = out[i + 1];
						if (c.pos.max <= dpos && c2.pos.min >= dpos) {
							out[i] = {values: c.values, guard: c.guard, expr: markCase(c.expr, c.pos), pos: c.pos};
							done = true;
						} else {
							i++;
						}
					}
				}
				var ndef = def;
				if (!didMark && def != null && e.pos.max > dpos)
					ndef = {e: markCase(def.e, def.pos), pos: def.pos};
				return new Expr(ESwitch(e1, out, ndef), e.pos);

			// The parser already produced a display node, so there is nothing left to decide.
			case EDisplay(_, _):
				gaveUp = true;
				return e;

			case EMeta(m, {expr: EConst(CString(_, _)), pos: pm}) if (m.name == ":markup" && isAnnotated(pm)):
				return annotateMarked(e);

			// A completion on a string or a regexp literal aborts the whole pass. hxc's lexer already sets
			// Parser.displaySuppressed for both; kept here so the pass gives the same verdict on its own.
			case EConst(CString(_, q)) if (isAnnotated(e.pos) && isCompletion
				&& (q != SSingleQuotes || hxc.parser.Parser.wasAutoTriggered)):
				gaveUp = true;
				return e;

			case EConst(CRegexp(_, _)) if (isAnnotated(e.pos) && isCompletion):
				gaveUp = true;
				return e;

			// Outside a completion, a var declaration answers only from a var name. Anywhere else in it -
			// the
			// `var` keyword, past the name, the type hint, the `;` - the pass gives up, and the hint's own
			// answer (if the cursor is in one) comes from loadComplexType instead.
			case EVars(vl) if (isAnnotated(e.pos)):
				for (v in vl) if (isAnnotated(v.evName.pos)) return annotateMarked(e);
				gaveUp = true;
				return e;

			case _:
		}
		return isAnnotated(e.pos) ? annotateMarked(e) : e;
	}
}
