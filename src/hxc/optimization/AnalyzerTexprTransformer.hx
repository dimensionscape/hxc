package hxc.optimization;

// hxc.optimization.AnalyzerTexprTransformer: builds the control flow graph from an expression (after
// TexprFilter) and turns a graph back into an expression.

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.context.Context;
import hxc.optimization.AnalyzerTypes;
import hxc.optimization.OptimizerTexpr;

private class Exit extends haxe.Exception {
	public function new() super("exit");
}

class AnalyzerTexprTransformer {
	static function isVoidT(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	static function isNumericT(t:T):Bool {
		return switch (TypeFunctions.followWithAbstracts(t)) {
			case TAbstract(a, _): a.path.pack.length == 0 && (a.path.name == "Int" || a.path.name == "Float");
			case _: false;
		};
	}

	static function isExhaustive(e1:TExpr, def:Null<TExpr>):Bool {
		if (def != null) return true;
		return switch (e1.expr) {
			case TMeta(m, e2): m.name == ":exhaustive" || isExhaustive(e2, def);
			case TParenthesis(e2): isExhaustive(e2, def);
			case _: false;
		};
	}

	// Apply f to each argument with its declared type
	static function unificationCheckCall(f:(TExpr, T)->TExpr, el:Array<TExpr>, t:T):Array<TExpr> {
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig):
				[for (i in 0...el.length) i < sig.args.length ? f(el[i], sig.args[i].t) : f(el[i], el[i].type)];
			case _:
				el;
		};
	}

	static function funcToGraph(ctx:AnalyzerContext, bb:BasicBlock, tf:TFunc, t:T, p:Position):{root:BasicBlock, exit:BasicBlock} {
		var g = ctx.graph;
		function createNode(kind:BlockKind, t:T, p:Position):BasicBlock {
			var bb = g.createNode(kind, t, p);
			bb.loopGroups = ctx.loopStack.copy();
			return bb;
		}
		var bbRoot = createNode(BKFunctionBegin(tf), tf.expr.type, tf.expr.pos);
		var bbExit = createNode(BKFunctionEnd, tf.expr.type, tf.expr.pos);
		g.addFunction(tf, t, p, bbRoot);
		BasicBlock.addCfgEdge(bb, bbRoot, CFGFunction);
		var bbBreaks:Array<BasicBlock> = [];
		var bbContinue:Null<BasicBlock> = null;
		var bTryStack:Array<BasicBlock> = [];
		function beginLoop(bbLoopPre:BasicBlock, bbContinue2:BasicBlock):Void->Array<BasicBlock> {
			var oldBreaks = bbBreaks;
			var oldContinue = bbContinue;
			bbBreaks = [];
			bbContinue = bbContinue2;
			var id = ctx.loopCounter;
			g.loops.set(id, bbLoopPre);
			ctx.loopStack.unshift(id);
			bbContinue2.loopGroups.unshift(id);
			ctx.loopCounter = id + 1;
			return function() {
				var breaks = bbBreaks;
				bbBreaks = oldBreaks;
				bbContinue = oldContinue;
				ctx.loopStack.shift();
				return breaks;
			};
		}
		function beginTry(b:BasicBlock):Void->Void {
			bTryStack.unshift(b);
			return function() bTryStack.shift();
		}
		function addTerminator(bb:BasicBlock, term:TerminatorKind):BasicBlock {
			bb.terminator = term;
			Graph.closeNode(bb);
			return g.unreachable;
		}
		function checkUnboundCall(s:String, el:Array<TExpr>):Void {
			if (s == "$ref") switch (el) {
				case [{expr: TLocal(v)}]: TypeFunctions.addVarFlag(v, VCaptured);
				case _:
			}
			if (AnalyzerTexpr.isUnboundCallThatMightHaveSideEffects(s, el)) ctx.hasUnbound = true;
		}
		function noVoid(t:T, p:Position):Void {
			if (isVoidT(TypeFunctions.follow(t))) throw new TypingError("Cannot use Void as value", p);
		}
		function pushName(s:String):Void->Void {
			ctx.nameStack.unshift(s);
			return function() ctx.nameStack.shift();
		}
		function checkRef(v:TVar, e:TExpr):Void {
			if (AnalyzerFusion.ExtTypeSemantics.hasReferenceSemantics(v.type)) switch (TexprTools.skip(e).expr) {
				case TLocal(v2): TypeFunctions.addVarFlag(v2, VCaptured);
				case _:
			}
		}

		var value:(BasicBlock, TExpr)->{bb:BasicBlock, e:TExpr} = null;
		var blockElement:(BasicBlock, TExpr)->BasicBlock = null;
		var blockEl:(BasicBlock, Array<TExpr>)->BasicBlock = null;
		var block:(BasicBlock, TExpr)->BasicBlock = null;
		var bindToTemp:(BasicBlock, TExpr, ?TVar)->{bb:BasicBlock, e:TExpr} = null;
		var declareVarAndAssign:(BasicBlock, TVar, TExpr, Position)->BasicBlock = null;
		var callGraph:(BasicBlock, TExpr, TExpr, Array<TExpr>)->{bb:BasicBlock, e:TExpr} = null;
		var arrayAssignOp:(BasicBlock, Binop, TExpr, TExpr, TExpr, TExpr, TExpr)->{bb:BasicBlock, e:TExpr} = null;
		var fieldAssignOp:(BasicBlock, Binop, TExpr, TExpr, TExpr, TFieldAccess, TExpr)->{bb:BasicBlock, e:TExpr} = null;
		var orderedValueList:(BasicBlock, Array<TExpr>)->{bb:BasicBlock, el:Array<TExpr>} = null;

		function value2(bb:BasicBlock, e:TExpr):{bb:BasicBlock, e:TExpr} {
			inline function remk(x:TExprExpr):TExpr return TypeFunctions.mk(x, e.type, e.pos);
			return switch (e.expr) {
				case TLocal(_) | TIdent(_):
					{bb: bb, e: e};
				case TBinop(OpAssign, e1 = {expr: TLocal(_)}, _):
					{bb: blockElement(bb, e), e: e1};
				case TBlock([e1]):
					value(bb, e1);
				case TBlock(_) | TIf(_, _, _) | TSwitch(_, _, _) | TTry(_, _):
					bindToTemp(bb, e);
				case TCall({expr: TIdent(s)}, el) if (AnalyzerTexpr.isReallyUnbound(s)):
					checkUnboundCall(s, el);
					{bb: bb, e: e};
				case TCall(e1, el):
					callGraph(bb, e, e1, el);
				case TBinop(OpAssignOp(op), ea = {expr: TArray(e1, e2)}, e3):
					arrayAssignOp(bb, op, e, ea, e1, e2, e3);
				case TBinop(OpAssignOp(op), ef = {expr: TField(e1, fa)}, e2):
					fieldAssignOp(bb, op, e, ef, e1, fa, e2);
				case TBinop(op = OpAssign | OpAssignOp(_), e1, e2):
					var r1 = value(bb, e1);
					var r2 = value(r1.bb, e2);
					{bb: r2.bb, e: remk(TBinop(op, r1.e, r2.e))};
				case TBinop(op, e1, e2):
					var r = orderedValueList(bb, [e1, e2]);
					switch (r.el) {
						case [x1, x2]: {bb: r.bb, e: remk(TBinop(op, x1, x2))};
						case [x]: {bb: r.bb, e: x};
						case _: throw new TypingError("Unexpected value list", e.pos);
					}
				case TUnop(op, flag, e1):
					var r = value(bb, e1);
					{bb: r.bb, e: remk(TUnop(op, flag, r.e))};
				case TArrayDecl(el):
					var r = orderedValueList(bb, el);
					{bb: r.bb, e: remk(TArrayDecl(r.el))};
				case TObjectDecl(fl):
					var r = orderedValueList(bb, [for (f in fl) f.expr]);
					{bb: r.bb, e: remk(TObjectDecl([for (i in 0...fl.length) {key: fl[i].key, expr: r.el[i]}]))};
				case TField({expr: TTypeExpr(_)}, _):
					{bb: bb, e: e};
				case TField(e1, fa):
					var r = value(bb, e1);
					{bb: r.bb, e: remk(TField(r.e, fa))};
				case TArray(e1, e2):
					var r = orderedValueList(bb, [e1, e2]);
					switch (r.el) {
						case [x1, x2]: {bb: r.bb, e: remk(TArray(x1, x2))};
						case [x]: {bb: r.bb, e: x};
						case _: throw new TypingError("Unexpected value list", e.pos);
					}
				case TMeta(m, e1):
					var r = value(bb, e1);
					{bb: r.bb, e: remk(TMeta(m, r.e))};
				case TParenthesis(e1):
					var r = value(bb, e1);
					{bb: r.bb, e: remk(TParenthesis(r.e))};
				case TCast(e1, mto):
					var r = value(bb, e1);
					{bb: r.bb, e: remk(TCast(r.e, mto))};
				case TNew(c, tl, el):
					var r = orderedValueList(bb, el);
					{bb: r.bb, e: remk(TNew(c, tl, r.el))};
				case TEnumParameter(e1, ef, ei):
					var r = value(bb, e1);
					{bb: r.bb, e: remk(TEnumParameter(r.e, ef, ei))};
				case TEnumIndex(e1):
					var r = value(bb, e1);
					{bb: r.bb, e: remk(TEnumIndex(r.e))};
				case TFunction(tf2):
					var f = funcToGraph(ctx, bb, tf2, e.type, e.pos);
					var eFun = TypeFunctions.mk(TConst(TString("fun")), TypeFunctions.tDynamic, p);
					var econst = TypeFunctions.mk(TConst(TInt(f.root.id)), ctx.com.basic.tint, e.pos);
					var ec = TypeFunctions.mk(TCall(eFun, [econst]), TypeFunctions.tDynamic, p);
					var bbNext = createNode(BKNormal, bb.type, bb.pos);
					BasicBlock.addCfgEdge(bb, bbNext, CFGGoto);
					bb.setSyntaxEdge(SEMerge(bbNext));
					Graph.closeNode(bb);
					BasicBlock.addCfgEdge(f.exit, bbNext, CFGGoto);
					{bb: bbNext, e: ec};
				case TConst(_) | TTypeExpr(_):
					{bb: bb, e: e};
				case TThrow(_) | TReturn(_) | TBreak | TContinue:
					var bb = blockElement(bb, e);
					{bb: bb, e: TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, e.pos)};
				case TVarExpr(_, _) | TFor(_, _, _) | TWhile(_, _, _):
					throw new TypingError("Cannot use this expression as value", e.pos);
			};
		}
		value = function(bb, e) {
			var r = value2(bb, e);
			noVoid(r.e.type, r.e.pos);
			return r;
		}

		orderedValueList = function(bb:BasicBlock, el:Array<TExpr>):{bb:BasicBlock, el:Array<TExpr>} {
			var checker = OptimizerTexpr.createAffectionChecker();
			function canBeOptimized(e:TExpr):Bool {
				return switch (e.expr) {
					case TBinop(_, _, _) | TArray(_, _) | TCall(_, _): true;
					case TParenthesis(e1): canBeOptimized(e1);
					case _: false;
				};
			}
			// Walk in reverse to know whether anything after an element has side effects
			var annotated:Array<{aff:Bool, opt:Bool, e:TExpr}> = [];
			var hadSideEffect = false;
			var i = el.length - 1;
			while (i >= 0) {
				var e = el[i];
				if (hadSideEffect) {
					annotated.unshift({aff: checker.mightBeAffected(e) || OptimizerTexpr.hasSideEffect(e), opt: canBeOptimized(e), e: e});
				} else {
					var se = OptimizerTexpr.hasSideEffect(e);
					if (se) checker.collectModifiedLocals(e);
					var opt = canBeOptimized(e);
					hadSideEffect = se || opt;
					annotated.unshift({aff: false, opt: opt, e: e});
				}
				i--;
			}
			// Note it folds over the REVERSED-then-annotated list; net effect: right-to-left annotation,
			// left-to-right evaluation.
			var out:Array<TExpr> = [];
			var bb = bb;
			var j = annotated.length - 1;
			// fold_left over `el` (the annotated list built by prepending from a reversed
			// walk) visits elements right-to-left of source order; unshift restores order
			while (j >= 0) {
				var a = annotated[j];
				if (bb != g.unreachable) {
					var r = (a.aff || a.opt) ? bindToTemp(bb, a.e) : value(bb, a.e);
					bb = r.bb;
					out.unshift(r.e);
				}
				j--;
			}
			return {bb: bb, el: out};
		}

		bindToTemp = function(bb:BasicBlock, e:TExpr, ?v:TVar):{bb:BasicBlock, e:TExpr} {
			function isProbablyNotAffected(e:TExpr, e1:TExpr, fa:TFieldAccess):Bool {
				return switch (fa) {
					case FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf) if (cf.kind.match(Method(MethNormal))): true;
					case FStatic(_, {kind: Method(MethDynamic)}): false;
					case FEnum(_, _): true;
					case FDynamic("cca" | "__Index" | "__s"): true;
					case _:
						switch [TypeFunctions.follow(e.type), TypeFunctions.follow(e1.type)] {
							case [TFun(_), TInst(_, _)]: false;
							case [TFun(_), _]: true; // See #5082
							case _: false;
						}
				};
			}
			var fl:Array<TExpr->TExpr> = [];
			function unwrap(e:TExpr):TExpr {
				return switch (e.expr) {
					case TField(e1, fa) if (isProbablyNotAffected(e, e1, fa)):
						fl.unshift(function(e2) return TypeFunctions.mk(TField(e2, fa), e.type, e.pos));
						unwrap(e1);
					case TField(e1, fa):
						var fa = switch (fa) {
							case FInstance(c, tl, cf) if (cf.kind.match(Method(_))): FClosure({c: c, params: tl}, cf);
							case _: fa;
						};
						TypeFunctions.mk(TField(e1, fa), e.type, e.pos);
					case _:
						e;
				};
			}
			var e = unwrap(e);
			function baseName(e:TExpr):String {
				return switch (e.expr) {
					case TLocal(v): v.name;
					case TArray(e1, _) | TField(e1, _) | TParenthesis(e1) | TCast(e1, null) | TMeta(_, e1): baseName(e1);
					case _: ctx.nameStack.length > 0 ? ctx.nameStack[0] : ctx.tempVarName;
				};
			}
			var v = v != null ? v : TypeFunctions.allocVar(VGenerated, baseName(e), e.type, e.pos);
			var bb = declareVarAndAssign(bb, v, e, e.pos);
			var e2 = TypeFunctions.mk(TLocal(v), v.type, e.pos);
			// Fl was unshifted while unwrapping outside-in, so apply in order
			for (f in fl) e2 = f(e2);
			return {bb: bb, e: e2};
		}

		function blockElementPlus(bb:BasicBlock, r:{e:TExpr, efinal:Null<TExpr>}, f:TExpr->TExpr):BasicBlock {
			var bb = blockElement(bb, r.e);
			if (r.efinal != null && bb != g.unreachable) bb = blockElement(bb, f(r.efinal));
			return bb;
		}

		function blockElementValue(bb:BasicBlock, e:TExpr, f:TExpr->TExpr):BasicBlock {
			var r = AnalyzerTexpr.mapValues(f, e);
			return blockElementPlus(bb, r, f);
		}

		declareVarAndAssign = function(bb:BasicBlock, v:TVar, e:TExpr, p:Position):BasicBlock {
			noVoid(v.type, p);
			function unwrapBlocks(bb:BasicBlock, e:TExpr):{bb:BasicBlock, e:TExpr} {
				return switch (e.expr) {
					case TParenthesis(e1):
						unwrapBlocks(bb, e1);
					case TBlock(el):
						if (el.length == 0) throw new TypingError("Malformed block", p);
						var bb = bb;
						for (i in 0...el.length - 1) {
							bb = blockElement(bb, el[i]);
							if (bb == g.unreachable) throw new Exit();
						}
						unwrapBlocks(bb, el[el.length - 1]);
					case _:
						{bb: bb, e: e};
				};
			}
			function generate(bb:BasicBlock, e:TExpr):BasicBlock {
				var ev = TypeFunctions.mk(TLocal(v), v.type, p);
				var wasAssigned = false;
				function assign(e:TExpr):TExpr {
					if (!wasAssigned) {
						wasAssigned = true;
						bb.addTexpr(TypeFunctions.mk(TVarExpr(v, null), ctx.com.basic.tvoid, ev.pos));
					}
					return TypeFunctions.mk(TBinop(OpAssign, ev, e), ev.type, ev.pos);
				}
				var close = pushName(v.name);
				var bbOut = try {
					blockElementPlus(bb, AnalyzerTexpr.mapValues(assign, e), function(e) return TypeFunctions.mk(TVarExpr(v, e), ctx.com.basic.tvoid, ev.pos));
				} catch (_:Exit) {
					var r = value(bb, e);
					r.bb.addTexpr(TypeFunctions.mk(TVarExpr(v, r.e), ctx.com.basic.tvoid, ev.pos));
					r.bb;
				}
				close();
				return bbOut;
			}
			return try {
				var r = unwrapBlocks(bb, e);
				generate(r.bb, r.e);
			} catch (_:Exit) g.unreachable;
		}

		callGraph = function(bb:BasicBlock, e:TExpr, e1:TExpr, el:Array<TExpr>):{bb:BasicBlock, e:TExpr} {
			var bbRef = bb;
			function check(e:TExpr, t:T):TExpr {
				return switch (e.expr) {
					case TLocal(v) if (AnalyzerFusion.ExtTypeSemantics.hasReferenceSemantics(t)):
						TypeFunctions.addVarFlag(v, VCaptured);
						e;
					case _:
						if (AnalyzerFusion.ExtTypeSemantics.hasVariableSemantics(t)) {
							var v = TypeFunctions.allocVar(VGenerated, "tmp", t, e.pos);
							var r = bindToTemp(bbRef, e, v);
							bbRef = r.bb;
							r.e;
						} else e;
				};
			}
			var el = unificationCheckCall(check, el, e1.type);
			var r = orderedValueList(bbRef, [e1].concat(el));
			return switch (r.el) {
				case el2 if (el2.length >= 1):
					{bb: r.bb, e: TypeFunctions.mk(TCall(el2[0], el2.slice(1)), e.type, e.pos)};
				case _:
					throw new TypingError("Malformed call", e.pos);
			};
		}

		arrayAssignOp = function(bb, op, e, ea, e1, e2, e3) {
			var r1 = bindToTemp(bb, e1);
			var r2 = bindToTemp(r1.bb, e2);
			var ea2 = TypeFunctions.mk(TArray(r1.e, r2.e), ea.type, ea.pos);
			var r4 = bindToTemp(r2.bb, ea2);
			var r3 = bindToTemp(r4.bb, e3);
			var eop = TypeFunctions.mk(TBinop(op, r4.e, r3.e), e.type, e.pos);
			r3.bb.addTexpr(TypeFunctions.mk(TBinop(OpAssign, ea2, eop), e.type, e.pos));
			return {bb: r3.bb, e: ea2};
		}

		fieldAssignOp = function(bb, op, e, ef, e1, fa, e2) {
			var r1 = switch (fa) {
				case FInstance(c, _, _) | FClosure({c: c}, _) if (TypeFunctions.hasMeta(":structAccess", c.meta)): {bb: bb, e: e1};
				case _: bindToTemp(bb, e1);
			};
			var ef2 = TypeFunctions.mk(TField(r1.e, fa), ef.type, ef.pos);
			var r3 = bindToTemp(r1.bb, ef2);
			var r2 = bindToTemp(r3.bb, e2);
			var eop = TypeFunctions.mk(TBinop(op, r3.e, r2.e), e.type, e.pos);
			r2.bb.addTexpr(TypeFunctions.mk(TBinop(OpAssign, ef2, eop), e.type, e.pos));
			return {bb: r2.bb, e: ef2};
		}

		blockElement = function(bb:BasicBlock, e:TExpr):BasicBlock {
			return switch (e.expr) {
				// Variables
				case TVarExpr(v, null):
					bb.addTexpr(e);
					bb;
				case TVarExpr(v, e1):
					checkRef(v, e1);
					declareVarAndAssign(bb, v, e1, e.pos);
				case TBinop(OpAssign, e1 = {expr: TLocal(v)}, e2):
					checkRef(v, e2);
					function assign(e3:TExpr):TExpr {
						return TypeFunctions.mk(TBinop(OpAssign, e1, e3), e3.type, e3.pos);
					}
					var close = pushName(v.name);
					var bbOut = try {
						blockElementValue(bb, e2, assign);
					} catch (_:Exit) {
						var r = value(bb, e2);
						r.bb.addTexpr(TypeFunctions.mk(TBinop(OpAssign, e1, r.e), e.type, e.pos));
						r.bb;
					}
					close();
					bbOut;
				// Branching
				case TMeta(m, {expr: TBlock(el)}) if (m.name == ":mergeBlock"):
					blockEl(bb, el);
				case TBlock([]) if (isVoidT(TypeFunctions.follow(e.type))):
					bb;
				case TBlock(el):
					var bbSub = createNode(BKSub, e.type, e.pos);
					BasicBlock.addCfgEdge(bb, bbSub, CFGGoto);
					Graph.closeNode(bb);
					var bbSubNext = blockEl(bbSub, el);
					if (bbSubNext != g.unreachable) {
						var bbNext = createNode(BKNormal, bb.type, bb.pos);
						bb.setSyntaxEdge(SESubBlock(bbSub, bbNext));
						BasicBlock.addCfgEdge(bbSubNext, bbNext, CFGGoto);
						Graph.closeNode(bbSubNext);
						bbNext;
					} else {
						bb.setSyntaxEdge(SEMerge(bbSub));
						Graph.closeNode(bbSubNext);
						bbSubNext;
					}
				case TIf(e1, e2, null):
					var r = bindToTemp(bb, e1);
					if (r.bb == g.unreachable) r.bb
					else {
						var bb = r.bb;
						var bbThen = createNode(BKConditional, e2.type, e2.pos);
						bb.terminator = TermCondBranch(r.e);
						BasicBlock.addCfgEdge(bb, bbThen, CFGCondBranch(TypeFunctions.mk(TConst(TBool(true)), ctx.com.basic.tbool, e2.pos)));
						var bbThenNext = block(bbThen, e2);
						var bbNext = createNode(BKNormal, bb.type, bb.pos);
						bb.setSyntaxEdge(SEIfThen(bbThen, bbNext, e.pos));
						BasicBlock.addCfgEdge(bb, bbNext, CFGCondElse);
						Graph.closeNode(bb);
						BasicBlock.addCfgEdge(bbThenNext, bbNext, CFGGoto);
						Graph.closeNode(bbThenNext);
						bbNext;
					}
				case TIf(e1, e2, e3):
					var r = bindToTemp(bb, e1);
					if (r.bb == g.unreachable) r.bb
					else {
						var bb = r.bb;
						var bbThen = createNode(BKConditional, e2.type, e2.pos);
						var bbElse = createNode(BKConditional, e3.type, e3.pos);
						bb.terminator = TermCondBranch(r.e);
						BasicBlock.addCfgEdge(bb, bbThen, CFGCondBranch(TypeFunctions.mk(TConst(TBool(true)), ctx.com.basic.tbool, e2.pos)));
						BasicBlock.addCfgEdge(bb, bbElse, CFGCondElse);
						Graph.closeNode(bb);
						var bbThenNext = block(bbThen, e2);
						var bbElseNext = block(bbElse, e3);
						if (bbThenNext == g.unreachable && bbElseNext == g.unreachable) {
							bb.setSyntaxEdge(SEIfThenElse(bbThen, bbElse, g.unreachable, e.type, e.pos));
							g.unreachable;
						} else {
							var bbNext = createNode(BKNormal, bb.type, bb.pos);
							bb.setSyntaxEdge(SEIfThenElse(bbThen, bbElse, bbNext, e.type, e.pos));
							BasicBlock.addCfgEdge(bbThenNext, bbNext, CFGGoto);
							BasicBlock.addCfgEdge(bbElseNext, bbNext, CFGGoto);
							Graph.closeNode(bbThenNext);
							Graph.closeNode(bbElseNext);
							bbNext;
						}
					}
				case TSwitch(e1, cases, edef):
					var exhaustive = isExhaustive(e1, edef);
					var r = bindToTemp(bb, e1);
					var bb = r.bb;
					bb.terminator = TermCondBranch(r.e);
					var reachable:Array<BasicBlock> = [];
					function makeCase(e2:TExpr):BasicBlock {
						var bbCase = createNode(BKConditional, e2.type, e2.pos);
						var bbCaseNext = block(bbCase, e2);
						if (bbCaseNext != g.unreachable) reachable.unshift(bbCaseNext);
						Graph.closeNode(bbCaseNext);
						return bbCase;
					}
					var cases2 = [for (c in cases) {
						var bbCase = makeCase(c.expr);
						for (e2 in c.values) BasicBlock.addCfgEdge(bb, bbCase, CFGCondBranch(e2));
						{el: c.values, bb: bbCase};
					}];
					var def = if (edef == null) null else {
						var bbCase = makeCase(edef);
						BasicBlock.addCfgEdge(bb, bbCase, CFGCondElse);
						bbCase;
					};
					if (exhaustive && reachable.length == 0) {
						bb.setSyntaxEdge(SESwitch(cases2, def, g.unreachable, e.pos));
						Graph.closeNode(bb);
						g.unreachable;
					} else {
						var bbNext = createNode(BKNormal, bb.type, bb.pos);
						if (!exhaustive) BasicBlock.addCfgEdge(bb, bbNext, CFGGoto);
						for (bbr in reachable) BasicBlock.addCfgEdge(bbr, bbNext, CFGGoto);
						bb.setSyntaxEdge(SESwitch(cases2, def, bbNext, e.pos));
						Graph.closeNode(bb);
						bbNext;
					}
				case TWhile(e1, e2, NormalWhile):
					var bbLoopPre = createNode(BKLoopHead, e1.type, e1.pos);
					BasicBlock.addCfgEdge(bb, bbLoopPre, CFGGoto);
					bb.setSyntaxEdge(SEMerge(bbLoopPre));
					Graph.closeNode(bb);
					var close = beginLoop(bb, bbLoopPre);
					var bbLoopBody = createNode(BKNormal, e2.type, e2.pos);
					var bbLoopBodyNext = block(bbLoopBody, e2);
					var breaks = close();
					var bbNext = if (breaks.length == 0) {
						// The loop appears infinite; assume it may throw so DCE keeps the body
						BasicBlock.addCfgEdge(bbLoopBody, bbExit, CFGMaybeThrow);
						g.unreachable;
					} else createNode(BKNormal, bb.type, bb.pos);
					for (bbb in breaks) BasicBlock.addCfgEdge(bbb, bbNext, CFGGoto);
					bbLoopPre.setSyntaxEdge(SEWhile(bbLoopBody, bbNext, e.pos));
					bbLoopPre.terminator = TermCondBranch(e1);
					if (bbLoopBodyNext != g.unreachable) BasicBlock.addCfgEdge(bbLoopBodyNext, bbLoopPre, CFGGoto);
					BasicBlock.addCfgEdge(bbLoopPre, bbLoopBody, CFGGoto);
					Graph.closeNode(bbLoopBodyNext);
					Graph.closeNode(bbLoopPre);
					bbNext;
				case TTry(e1, catches):
					var bbTry = createNode(BKNormal, e1.type, e1.pos);
					var bbExc = createNode(BKException, TypeFunctions.tDynamic, e.pos);
					BasicBlock.addCfgEdge(bb, bbTry, CFGGoto);
					var close = beginTry(bbExc);
					var bbTryNext = block(bbTry, e1);
					close();
					// Keep catch blocks alive with a pseudo edge when nothing can throw
					if (bbExc.incoming.length == 0)
						BasicBlock.addCfgEdge(bbTryNext == g.unreachable ? bbTry : bbTryNext, bbExc, CFGMaybeThrow);
					var isReachable = bbTryNext != g.unreachable;
					var catches2 = [for (c in catches) {
						var bbCatch = createNode(BKCatch(c.v), c.expr.type, c.expr.pos);
						BasicBlock.addCfgEdge(bbExc, bbCatch, CFGGoto);
						var bbCatchNext = block(bbCatch, c.expr);
						isReachable = isReachable || (bbCatchNext != g.unreachable);
						{v: c.v, bb: bbCatch, next: bbCatchNext};
					}];
					var bbNext = isReachable ? createNode(BKNormal, bb.type, bb.pos) : g.unreachable;
					var catches3 = [for (c in catches2) {
						if (c.next != g.unreachable) BasicBlock.addCfgEdge(c.next, bbNext, CFGGoto);
						Graph.closeNode(c.next);
						{v: c.v, bb: c.bb};
					}];
					bb.setSyntaxEdge(SETry(bbTry, bbExc, catches3, bbNext, e.pos));
					if (bbTryNext != g.unreachable) BasicBlock.addCfgEdge(bbTryNext, bbNext, CFGGoto);
					Graph.closeNode(bbTryNext);
					Graph.closeNode(bbExc);
					Graph.closeNode(bb);
					bbNext;
				// Control flow
				case TReturn(null):
					BasicBlock.addCfgEdge(bb, bbExit, CFGGoto);
					addTerminator(bb, TermReturn(e.pos));
				case TReturn(e1) if (e1 != null && isVoidT(TypeFunctions.follow(e1.type))):
					var bb = blockElement(bb, e1);
					blockElement(bb, TypeFunctions.mk(TReturn(null), TypeFunctions.tDynamic, e.pos));
				case TReturn(e1):
					try {
						function mkReturn(e2:TExpr):TExpr return TypeFunctions.mk(TReturn(e2), TypeFunctions.tDynamic, e2.pos);
						blockElementValue(bb, e1, mkReturn);
					} catch (_:Exit) {
						var r = value(bb, e1);
						BasicBlock.addCfgEdge(r.bb, bbExit, CFGGoto);
						addTerminator(r.bb, TermReturnValue(r.e, e.pos));
					}
				case TBreak:
					bbBreaks.unshift(bb);
					addTerminator(bb, TermBreak(e.pos));
				case TContinue:
					if (bbContinue == null) throw new TypingError("Continue outside loop", e.pos);
					BasicBlock.addCfgEdge(bb, bbContinue, CFGGoto);
					addTerminator(bb, TermContinue(e.pos));
				case TThrow(e1):
					try {
						function mkThrow(e2:TExpr):TExpr return TypeFunctions.mk(TThrow(e2), TypeFunctions.tDynamic, e.pos);
						blockElementValue(bb, e1, mkThrow);
					} catch (_:Exit) {
						var r = value(bb, e1);
						if (bTryStack.length == 0) BasicBlock.addCfgEdge(r.bb, bbExit, CFGGoto)
						else for (bbExc2 in bTryStack) BasicBlock.addCfgEdge(r.bb, bbExc2, CFGGoto);
						addTerminator(r.bb, TermThrow(r.e, e.pos));
					}
				// Side effects
				case TCall({expr: TIdent(s)}, el) if (AnalyzerTexpr.isReallyUnbound(s)):
					checkUnboundCall(s, el);
					bb.addTexpr(e);
					bb;
				case TCall(e1, el):
					var r = callGraph(bb, e, e1, el);
					r.bb.addTexpr(r.e);
					r.bb;
				case TNew(c, tl, el):
					var r = orderedValueList(bb, el);
					r.bb.addTexpr(TypeFunctions.mk(TNew(c, tl, r.el), e.type, e.pos));
					r.bb;
				case TCast(e1, mt) if (mt != null):
					var r = value(bb, e1);
					r.bb.addTexpr(TypeFunctions.mk(TCast(r.e, mt), e.type, e.pos));
					r.bb;
				case TBinop(OpAssignOp(op), ea = {expr: TArray(e1, e2)}, e3):
					arrayAssignOp(bb, op, e, ea, e1, e2, e3).bb;
				case TBinop(OpAssignOp(op), ef = {expr: TField(e1, fa)}, e2):
					fieldAssignOp(bb, op, e, ef, e1, fa, e2).bb;
				case TBinop(OpAssign, ea = {expr: TArray(e1, e2)}, e3):
					var r = orderedValueList(bb, [e1, e2, e3]);
					switch (r.el) {
						case [x1, x2, x3]:
							r.bb.addTexpr(TypeFunctions.mk(TBinop(OpAssign, TypeFunctions.mk(TArray(x1, x2), ea.type, ea.pos), x3), e.type, e.pos));
							r.bb;
						case _:
							throw new TypingError("Malformed array assign", e.pos);
					}
				case TBinop(op = OpAssign | OpAssignOp(_), e1, e2):
					var r1 = value(bb, e1);
					var r2 = value(r1.bb, e2);
					r2.bb.addTexpr(TypeFunctions.mk(TBinop(op, r1.e, r2.e), e.type, e.pos));
					r2.bb;
				case TUnop(op = Increment | Decrement, flag, e1):
					var r = value(bb, e1);
					r.bb.addTexpr(TypeFunctions.mk(TUnop(op, flag, r.e), e.type, e.pos));
					r.bb;
				case TLocal(_) if (!ctx.config.localDce):
					bb.addTexpr(e);
					bb;
				case TField(e1, fa) if (OptimizerTexpr.hasSideEffect(e)):
					var r = value(bb, e1);
					r.bb.addTexpr(TypeFunctions.mk(TField(r.e, fa), e.type, e.pos));
					r.bb;
				// No side effect
				case TEnumParameter(_, _, _) | TEnumIndex(_) | TFunction(_) | TConst(_) | TTypeExpr(_) | TLocal(_) | TIdent(_):
					bb;
				// No-side-effect composites TCast with a module type was handled above; only TCast(e1, null)
				// reaches here
				case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, _) | TField(e1, _) | TUnop(_, _, e1):
					blockElement(bb, e1);
				case TArray(e1, e2) | TBinop(_, e1, e2):
					var bb = blockElement(bb, e1);
					blockElement(bb, e2);
				case TArrayDecl(el):
					blockEl(bb, el);
				case TObjectDecl(fl):
					blockEl(bb, [for (f in fl) f.expr]);
				case TFor(_, _, _) | TWhile(_, _, DoWhile):
					throw new TypingError("Unexpected loop form in analyzer", e.pos);
			};
		}

		blockEl = function(bb:BasicBlock, el:Array<TExpr>):BasicBlock {
			if (bTryStack.length == 0) {
				var bb = bb;
				for (e in el) {
					bb = blockElement(bb, e);
					if (bb == g.unreachable) return bb;
				}
				return bb;
			} else {
				var bb = bb;
				for (e in el) {
					if (!AnalyzerTexpr.canThrow(e)) {
						bb = blockElement(bb, e);
					} else {
						var bb2 = createNode(BKNormal, e.type, e.pos);
						BasicBlock.addCfgEdge(bb, bb2, CFGGoto);
						for (bbExc2 in bTryStack) BasicBlock.addCfgEdge(bb, bbExc2, CFGMaybeThrow);
						bb.setSyntaxEdge(SEMerge(bb2));
						Graph.closeNode(bb);
						bb = blockElement(bb2, e);
					}
					if (bb == g.unreachable) return bb;
				}
				return bb;
			}
		}

		block = function(bb:BasicBlock, e:TExpr):BasicBlock {
			var el = switch (e.expr) {
				case TBlock(el): el;
				case _: [e];
			};
			return blockEl(bb, el);
		}

		var bbLast = block(bbRoot, tf.expr);
		Graph.closeNode(bbLast);
		BasicBlock.addCfgEdge(bbLast, bbExit, CFGGoto); // Implied return
		Graph.closeNode(bbExit);
		return {root: bbRoot, exit: bbExit};
	}

	public static function fromTfunction(ctx:AnalyzerContext, tf:TFunc, t:T, p:Position):Void {
		var g = ctx.graph;
		var r = funcToGraph(ctx, g.root, tf, t, p);
		ctx.entry = r.root;
		Graph.closeNode(g.root);
		g.exit = r.exit;
	}

	static function terminatorToTexprMaybe(term:TerminatorKind):Null<TExpr> {
		return switch (term) {
			case TermReturn(p): TypeFunctions.mk(TReturn(null), TypeFunctions.tDynamic, p);
			case TermBreak(p): TypeFunctions.mk(TBreak, TypeFunctions.tDynamic, p);
			case TermContinue(p): TypeFunctions.mk(TContinue, TypeFunctions.tDynamic, p);
			case TermReturnValue(e1, p): TypeFunctions.mk(TReturn(e1), TypeFunctions.tDynamic, p);
			case TermThrow(e1, p): TypeFunctions.mk(TThrow(e1), TypeFunctions.tDynamic, p);
			case TermCondBranch(e1): e1;
			case _: null;
		};
	}

	static function blockToTexprEl(ctx:AnalyzerContext, bb:BasicBlock):Array<TExpr> {
		if (bb.dominator == ctx.graph.unreachable) return [];
		inline function blockOf(bb:BasicBlock):TExpr return blockToTexpr(ctx, bb);
		function live(bb:BasicBlock):Bool return !ctx.didOptimize || !ctx.config.localDce || bb.hasBlockFlag(BlockDce);
		inline function ifLive(bb:BasicBlock):Null<BasicBlock> return live(bb) ? bb : null;
		function getTerminator():TExpr {
			return switch (bb.terminator) {
				case TermCondBranch(e1): e1;
				case _: throw new TypingError("Missing terminator", bb.pos);
			};
		}
		var bbNext:Null<BasicBlock>;
		var eTerm:Null<TExpr>;
		switch (bb.syntaxEdge) {
			case SESubBlock(bbSub, bbNext2):
				bbNext = bbNext2;
				eTerm = blockOf(bbSub);
			case SEMerge(bbNext2):
				bbNext = bbNext2;
				eTerm = null;
			case SENone:
				bbNext = null;
				eTerm = terminatorToTexprMaybe(bb.terminator);
			case SETry(bbTry, _, bbl, bbNext2, p):
				bbNext = ifLive(bbNext2);
				eTerm = TypeFunctions.mk(TTry(blockOf(bbTry), [for (c in bbl) {v: c.v, expr: blockOf(c.bb)}]), ctx.com.basic.tvoid, p);
			case SEIfThen(bbThen, bbNext2, p):
				bbNext = ifLive(bbNext2);
				eTerm = TypeFunctions.mk(TIf(getTerminator(), blockOf(bbThen), null), ctx.com.basic.tvoid, p);
			case SEIfThenElse(bbThen, bbElse, bbNext2, t, p):
				bbNext = ifLive(bbNext2);
				eTerm = TypeFunctions.mk(TIf(getTerminator(), blockOf(bbThen), blockOf(bbElse)), t, p);
			case SEWhile(bbBody, bbNext2, p):
				var e2 = blockOf(bbBody);
				bbNext = ifLive(bbNext2);
				eTerm = TypeFunctions.mk(TWhile(getTerminator(), e2, NormalWhile), ctx.com.basic.tvoid, p);
			case SESwitch(bbl, bo, bbNext2, p):
				bbNext = bbNext2;
				eTerm = TypeFunctions.mk(TSwitch(getTerminator(), [for (c in bbl) {values: c.el, expr: blockOf(c.bb)}], bo == null ? null : blockOf(bo)), ctx.com.basic.tvoid, p);
		}
		var el = bb.el.copy();
		if (eTerm != null) el.push(eTerm);
		if (bbNext != null) el = el.concat(blockToTexprEl(ctx, bbNext));
		return el;
	}

	static function blockToTexpr(ctx:AnalyzerContext, bb:BasicBlock):TExpr {
		if (!bb.closed) throw new TypingError("Block not closed", bb.pos);
		var el = blockToTexprEl(ctx, bb);
		return TypeFunctions.mk(TBlock(el), bb.type, bb.pos);
	}

	// Rebuild one function from its block id
	static function funcFromGraph(ctx:AnalyzerContext, i:Int):TExpr {
		var fi = ctx.graph.functions.get(i);
		if (fi == null) throw new TypingError("Unknown function block " + i, Position.nullPos);
		var e = blockToTexpr(ctx, fi.bb);
		var loop:TExpr->TExpr = null;
		loop = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TLocal(v):
					TypeFunctions.mk(TLocal(ctx.graph.getVarOrigin(v)), e.type, e.pos);
				case TVarExpr(v, eo):
					var eo = eo == null ? null : loop(eo);
					TypeFunctions.mk(TVarExpr(ctx.graph.getVarOrigin(v), eo), e.type, e.pos);
				case TBinop(OpAssign, e1, e4 = {expr: TBinop(op, e2, e3)}) if (AnalyzerTexpr.targetHandlesAssignOps(ctx.com, e3)):
					var e1 = loop(e1);
					var e2 = loop(e2);
					var e3 = loop(e3);
					function isValidAssignOp(op:Binop):Bool {
						return switch (op) {
							case OpAdd | OpMult | OpDiv | OpSub | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr | OpMod: true;
							case _: false;
						};
					}
					switch [e1.expr, e2.expr] {
						case [TLocal(v1), TLocal(v2)] if (v1 == v2 && !TypeFunctions.hasVarFlag(v1, VCaptured) && isValidAssignOp(op)):
							switch [op, e3.expr] {
								case [OpAdd | OpSub, TConst(TInt(one))] if (one == 1 && isNumericT(v1.type)):
									var uop:Unop = op.match(OpAdd) ? Increment : Decrement;
									TypeFunctions.mk(TUnop(uop, Prefix, e1), e.type, e.pos);
								case _:
									TypeFunctions.mk(TBinop(OpAssignOp(op), e1, e3), e.type, e.pos);
							}
						case _:
							TypeFunctions.mk(TBinop(OpAssign, e1, TypeFunctions.mk(TBinop(op, e2, e3), e4.type, e4.pos)), e.type, e.pos);
					}
				case TCall({expr: TConst(TString("fun"))}, [{expr: TConst(TInt(i2))}]):
					funcFromGraph(ctx, i2);
				case TCall({expr: TIdent(s)}, _) if (AnalyzerTexpr.isReallyUnbound(s)):
					e;
				case _:
					TexprTools.mapExpr(loop, e);
			};
		}
		var e = loop(e);
		return TypeFunctions.mk(TFunction(new TFunc(fi.tf.args, fi.tf.type, e)), fi.t, fi.p);
	}

	public static function toTexpr(ctx:AnalyzerContext):TExpr {
		return funcFromGraph(ctx, ctx.entry.id);
	}
}
