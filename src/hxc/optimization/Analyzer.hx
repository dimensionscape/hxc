package hxc.optimization;

// hxc.optimization.Analyzer: the controlling
// module with all graph based optimizations: Ssa construction, the DataFlow framework,
// ConstPropagation, CopyPropagation, LocalDce and the Run driver.

import haxe.ds.IntMap;
import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.NotFound;
import hxc.context.Context;
import hxc.context.PurityState;
import hxc.filters.FiltersCommon;
import hxc.optimization.AnalyzerConfig;
import hxc.optimization.AnalyzerTypes;

private typedef Exit = hxc.core.ExitException;

private class AnalyzerHelper {
	public static function isVoidT(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	public static function mapArrayInPlace(a:Array<TExpr>, f:TExpr->TExpr):Void {
		for (i in 0...a.length) a[i] = f(a[i]);
	}
}

class Ssa {
	static function addPhi(g:Graph, bb:BasicBlock, v:TVar):Void {
		var p = bb.pos;
		var ev = TypeFunctions.mk(TLocal(v), v.type, p);
		var el = [for (_ in bb.incoming) ev];
		var ePhi = TypeFunctions.mk(TConst(TString("phi")), TypeFunctions.tDynamic, p);
		var ec = TypeFunctions.mk(TCall(ePhi, el), TypeFunctions.tDynamic, p);
		var e = TypeFunctions.mk(TBinop(OpAssign, ev, ec), TypeFunctions.tDynamic, p);
		bb.phi.push(e);
	}

	static function insertPhi(ctx:AnalyzerContext):Void {
		for (vi in ctx.graph.varInfos) {
			var v = vi.variable;
			if (vi.bbDeclare == ctx.graph.unreachable) continue;
			var doneList = new IntMap<Bool>();
			var w = vi.writes.copy();
			while (w.length > 0) {
				var x = w.shift();
				for (y in x.df) {
					if (!doneList.exists(y.id)) {
						doneList.set(y.id, true);
						if (BasicBlock.inScope(y, vi.bbDeclare)) {
							addPhi(ctx.graph, y, v);
							if (vi.writes.indexOf(y) < 0) w.unshift(y);
						}
					}
				}
			}
		}
	}

	public static function setReachingDef(g:Graph, v:TVar, vo:Null<TVar>):Void {
		g.getVarInfo(v).reachingDef = vo;
	}

	public static function getReachingDef(g:Graph, v:TVar):Null<TVar> {
		return g.getVarInfo(v).reachingDef;
	}

	static function blockDominates(bbDom:BasicBlock, bb:BasicBlock):Bool {
		return bbDom == bb || bb.dominator == bbDom || (bb.dominator != bb && blockDominates(bbDom, bb.dominator));
	}

	// A write of r dominates bb
	static function dominates(ctx:AnalyzerContext, r:TVar, bb:BasicBlock):Bool {
		var l = ctx.graph.getVarInfo(r).writes;
		for (bb2 in l) if (blockDominates(bb2, bb)) return true;
		return false;
	}

	static function updateReachingDef(ctx:AnalyzerContext, v:TVar, bb:BasicBlock):Void {
		function loop(r:Null<TVar>):Null<TVar> {
			return if (r == null) null
			else if (dominates(ctx, r, bb)) r
			else loop(getReachingDef(ctx.graph, r));
		}
		var v2 = loop(getReachingDef(ctx.graph, v));
		setReachingDef(ctx.graph, v, v2);
	}

	static function local(ctx:AnalyzerContext, e:TExpr, v:TVar, bb:BasicBlock):TVar {
		updateReachingDef(ctx, v, bb);
		var r = getReachingDef(ctx.graph, v);
		return r != null ? r : v;
	}

	static function updatePhi(ctx:AnalyzerContext, edge:CfgEdge):Void {
		var bb = edge.to;
		var loop:(Int, TExpr)->TExpr = null;
		loop = function(i:Int, e:TExpr):TExpr {
			return switch (e.expr) {
				case TBinop(OpAssign, e1 = {expr: TLocal(v0)}, ecall = {expr: TCall(ephi = {expr: TConst(TString("phi"))}, el)}):
					var el2 = [for (j in 0...el.length) {
						var einc = bb.incoming[j];
						var e2 = el[j];
						var bbPred = einc.from;
						if (bbPred != edge.from) e2
						else switch (e2.expr) {
							case TLocal(v):
								var v2 = local(ctx, e2, v, edge.from);
								ctx.graph.addSsaEdge(v2, bb, LUPhi(i));
								TypeFunctions.mk(TLocal(v2), e2.type, e2.pos);
							case _:
								throw new TypingError("Malformed phi node", e2.pos);
						}
					}];
					var ephi2 = TypeFunctions.mk(TCall(ephi, el2), ecall.type, ecall.pos);
					ctx.graph.setVarValue(v0, bb, LUPhi(i));
					TypeFunctions.mk(TBinop(OpAssign, e1, ephi2), e.type, e.pos);
				case _:
					TexprTools.mapExpr(loop.bind(i), e);
			};
		}
		for (i in 0...bb.phi.length) bb.phi[i] = loop(i, bb.phi[i]);
	}

	static function renameInBlock(ctx:AnalyzerContext, bb:BasicBlock):Void {
		function writeVar(v:TVar, luk:TexprLookupTarget):TVar {
			updateReachingDef(ctx, v, bb);
			var v2 = TypeFunctions.allocVar(v.kind, v.name, v.type, v.pos);
			ctx.graph.declareVar(v2, bb);
			v2.meta = v.meta;
			if (TypeFunctions.hasVarFlag(v, VCaptured)) TypeFunctions.addVarFlag(v2, VCaptured);
			ctx.graph.addVarDef(bb, v2);
			setReachingDef(ctx.graph, v2, getReachingDef(ctx.graph, v));
			setReachingDef(ctx.graph, v, v2);
			ctx.graph.setVarValue(v2, bb, luk);
			ctx.graph.addVarOrigin(v2, v);
			return v2;
		}
		var loop:(TexprLookupTarget, TExpr)->TExpr = null;
		loop = function(luk:TexprLookupTarget, e:TExpr):TExpr {
			return switch (e.expr) {
				case TLocal(v):
					var v2 = local(ctx, e, v, bb);
					ctx.graph.addSsaEdge(v2, bb, luk);
					TypeFunctions.mk(TLocal(v2), e.type, e.pos);
				case TVarExpr(v, e1) if (e1 != null):
					var e1 = loop(luk, e1);
					var v2 = writeVar(v, luk);
					TypeFunctions.mk(TVarExpr(v2, e1), e.type, e.pos);
				case TBinop(OpAssign, e1 = {expr: TLocal(v)}, e2):
					var e2 = loop(luk, e2);
					var v2 = writeVar(v, luk);
					TypeFunctions.mk(TBinop(OpAssign, TypeFunctions.mk(TLocal(v2), e1.type, e1.pos), e2), e.type, e.pos);
				case TCall({expr: TConst(TString("phi"))}, _):
					e;
				case _:
					TexprTools.mapExpr(loop.bind(luk), e);
			};
		}
		for (i in 0...bb.phi.length) bb.phi[i] = loop(LUPhi(i), bb.phi[i]);
		for (i in 0...bb.el.length) bb.el[i] = loop(LUEl(i), bb.el[i]);
		bb.terminator = BasicBlock.terminatorMap(loop.bind(LUTerm), bb.terminator);
		for (edge in bb.outgoing) updatePhi(ctx, edge);
		for (d in bb.dominated) renameInBlock(ctx, d);
	}

	public static function apply(ctx:AnalyzerContext):Void {
		ctx.graph.inferDominanceFrontier();
		insertPhi(ctx);
		renameInBlock(ctx, ctx.graph.root);
	}
}

typedef DataFlowApi<TL> = {
	var flag:CfgEdgeFlag;
	var transfer:(AnalyzerContext, BasicBlock, TExpr)->TL;
	var equals:(TL, TL)->Bool;
	var bottom:TL;
	var top:TL;
	var getCell:Int->TL;
	var setCell:(Int, TL)->Void;
	var init:AnalyzerContext->Void;
	var commit:AnalyzerContext->Void;
	var conditional:Bool;
}

class DataFlow {
	static function run<TL>(ctx:AnalyzerContext, M:DataFlowApi<TL>):Void {
		var g = ctx.graph;
		var ssaWorkList:Array<TexprLookup> = [];
		var cfgWorkList:Array<CfgEdge> = g.root.outgoing.copy();
		function addSsaEdge(edge:TexprLookup):Void ssaWorkList.unshift(edge);
		function addCfgEdge(edge:CfgEdge):Void cfgWorkList.unshift(edge);
		function visitPhi(bb:BasicBlock, v:TVar, el:Array<TExpr>):TL {
			// Collect the args of executable edges (reversed), then transfer each
			var el2:Array<TExpr> = [];
			for (j in 0...el.length) {
				if (BasicBlock.edgeHasFlag(bb.incoming[j], M.flag)) el2.unshift(el[j]);
			}
			var lats = [for (e in el2) M.transfer(ctx, bb, e)];
			if (lats.length > 0) {
				var e1 = lats[0];
				var allEqual = true;
				for (i in 1...lats.length) if (!M.equals(e1, lats[i])) { allEqual = false; break; }
				if (allEqual) return e1;
			}
			return M.bottom;
		}
		function setLatticeCell(v:TVar, e:TL):Void {
			var e2 = M.getCell(v.id);
			M.setCell(v.id, e);
			if (!M.equals(e, e2))
				for (edge in g.getVarInfo(v).ssaEdges) addSsaEdge(edge);
		}
		function visitAssignment(bb:BasicBlock, v:TVar, e:TExpr):Void {
			switch (e.expr) {
				case TCall({expr: TConst(TString("phi"))}, el):
					setLatticeCell(v, visitPhi(bb, v, el));
				case _:
					for (edge in bb.incoming) if (BasicBlock.edgeHasFlag(edge, M.flag)) {
						setLatticeCell(v, M.transfer(ctx, bb, e));
						break;
					}
			}
		}
		function visitExpression(bb:BasicBlock, condBranch:Bool, e:TExpr):Bool {
			return switch (e.expr) {
				case TBinop(OpAssign, {expr: TLocal(v)}, e2) | TVarExpr(v, e2) if (e2 != null):
					visitAssignment(bb, v, e2);
					false;
				case _ if (M.conditional && condBranch):
					var e1 = M.transfer(ctx, bb, e);
					var edges = if (M.equals(e1, M.bottom) || M.equals(e1, M.top)) {
						bb.outgoing;
					} else {
						var yes:Array<CfgEdge> = [];
						var maybe:Array<CfgEdge> = [];
						var also:Array<CfgEdge> = [];
						for (edge in bb.outgoing) switch (edge.kind) {
							case CFGCondBranch(e2):
								var e2 = M.transfer(ctx, bb, e2);
								if (M.equals(e2, e1)) yes.unshift(edge);
							case CFGCondElse:
								maybe.unshift(edge);
							case CFGGoto | CFGFunction | CFGMaybeThrow:
								also.unshift(edge);
						}
						if (yes.length == 0 && maybe.length == 0) bb.outgoing
						else if (yes.length == 0) maybe.concat(also)
						else yes.concat(also);
					}
					for (edge in edges) addCfgEdge(edge);
					true;
				case _:
					false;
			};
		}
		function visitExpressions(bb:BasicBlock):Void {
			var b = false;
			for (e in bb.el) b = visitExpression(bb, false, e) || b;
			b = switch (bb.terminator) {
				case TermCondBranch(e1): visitExpression(bb, true, e1) || b;
				case TermReturnValue(e1, _) | TermThrow(e1, _): visitExpression(bb, false, e1);
				case _: b;
			};
			if (!b) for (edge in bb.outgoing) addCfgEdge(edge);
		}
		function visitPhis(bb:BasicBlock):Void {
			for (e in bb.phi) switch (e.expr) {
				case TBinop(OpAssign, {expr: TLocal(v)}, {expr: TCall({expr: TConst(TString("phi"))}, el)}):
					setLatticeCell(v, visitPhi(bb, v, el));
				case _:
					throw new TypingError("Malformed phi expression", e.pos);
			}
		}
		while (true) {
			if (cfgWorkList.length > 0) {
				var edge = cfgWorkList.shift();
				if (!BasicBlock.edgeHasFlag(edge, M.flag)) {
					edge.flags.unshift(M.flag);
					visitPhis(edge.to);
					var i = 0;
					for (edge2 in edge.to.incoming) if (BasicBlock.edgeHasFlag(edge2, M.flag)) i++;
					if (i == 1 || edge.to == g.root)
						visitExpressions(edge.to);
					if (edge.to.outgoing.length == 1)
						addCfgEdge(edge.to.outgoing[0]);
				}
			} else if (ssaWorkList.length > 0) {
				var item = ssaWorkList.shift();
				var e = item.bb.getTexpr(item.luk);
				visitExpression(item.bb, item.luk.match(LUTerm), e);
			} else {
				break;
			}
		}
	}

	public static function apply<TL>(ctx:AnalyzerContext, M:DataFlowApi<TL>):Void {
		M.init(ctx);
		run(ctx, M);
		M.commit(ctx);
	}
}

enum ConstLattice {
	Top;
	Bottom;
	LNull(t:T);
	LConst(ct:TConstant);
	LEnumValue(i:Int, tl:Array<ConstLattice>);
	LModuleType(mt:ModuleType, t:T);
}

class ConstPropagation {
	static var lattice:IntMap<ConstLattice> = new IntMap();

	static function getCell(i:Int):ConstLattice {
		var r = lattice.get(i);
		return r == null ? Top : r;
	}

	static function setCell(i:Int, ct:ConstLattice):Void {
		lattice.set(i, ct);
	}

	// Physical equality of the module type payload
	static function moduleTypeEq(mt1:ModuleType, mt2:ModuleType):Bool {
		return switch [mt1, mt2] {
			case [TClassDecl(c1), TClassDecl(c2)]: c1 == c2;
			case [TEnumDecl(e1), TEnumDecl(e2)]: e1 == e2;
			case [TTypeDecl(t1), TTypeDecl(t2)]: t1 == t2;
			case [TAbstractDecl(a1), TAbstractDecl(a2)]: a1 == a2;
			case _: false;
		};
	}

	static function latEquals(lat1:ConstLattice, lat2:ConstLattice):Bool {
		return switch [lat1, lat2] {
			case [Top, Top] | [Bottom, Bottom]: true;
			case [LConst(ct1), LConst(ct2)]: std.Type.enumEq(ct1, ct2);
			case [LNull(t1), LNull(t2)]: t1 == t2;
			case [LEnumValue(i1, []), LEnumValue(i2, [])]: i1 == i2;
			case [LModuleType(mt1, _), LModuleType(mt2, _)]: moduleTypeEq(mt1, mt2);
			case _: false;
		};
	}

	static function transfer(ctx:AnalyzerContext, bb:BasicBlock, e:TExpr):ConstLattice {
		// Transfer answers Bottom for a value that is no known constant. Null stands for that
		// early exit here, checked after each step in the order the steps run.
		function wrap(lat:ConstLattice, e:TExpr):Null<TExpr> {
			return switch (lat) {
				case LConst(ct): TypeFunctions.mk(TConst(ct), TypeFunctions.tDynamic, Position.nullPos);
				case LNull(t): TypeFunctions.mk(TConst(TNull), t, e.pos);
				case _: null;
			};
		}
		function unwrap(e:TExpr):Null<ConstLattice> {
			return switch (e.expr) {
				case TConst(ct): LConst(ct);
				case _: null;
			};
		}
		var eval:(BasicBlock, TExpr)->Null<ConstLattice> = null;
		eval = function(bb:BasicBlock, e:TExpr):Null<ConstLattice> {
			switch (e.expr) {
				case TConst(TSuper | TThis):
					return Bottom;
				case TConst(TNull):
					return LNull(e.type);
				case TConst(ct):
					return LConst(ct);
				case TTypeExpr(mt):
					return LModuleType(mt, e.type);
				case TLocal(v):
					if (TypeFunctions.follow(v.type).match(TDynamic(_)) || TypeFunctions.hasVarFlag(v, VCaptured))
						return Bottom;
					else
						return getCell(v.id);
				case TBinop(OpAssign, _, e2):
					return eval(bb, e2);
				case TBinop(op, e1, e2):
					var cl1 = eval(bb, e1);
					if (cl1 == null) return null;
					var cl2 = eval(bb, e2);
					if (cl2 == null) return null;
					var e1 = wrap(cl1, e);
					if (e1 == null) return null;
					var e2 = wrap(cl2, e);
					if (e2 == null) return null;
					var e3 = TypeFunctions.mk(TBinop(op, e1, e2), e.type, e.pos);
					var e4 = OptimizerTexpr.optimizeBinop(e3, op, e1, e2);
					return if (e3 != e4) eval(bb, e4) else unwrap(e4);
				case TUnop(op, flag, e1):
					var cl1 = eval(bb, e1);
					if (cl1 == null) return null;
					var e1 = wrap(cl1, e);
					if (e1 == null) return null;
					var e2 = TypeFunctions.mk(TUnop(op, flag, e1), e.type, e.pos);
					var e3 = OptimizerTexpr.optimizeUnop(e2, op, flag, e1);
					return if (e2 != e3) eval(bb, e3) else unwrap(e3);
				case TField(_, FEnum(_, ef)):
					return LEnumValue(ef.index, []);
				case TCall({expr: TField(_, FEnum(_, ef))}, el):
					var cll:Array<ConstLattice> = [];
					for (e2 in el) {
						var lat = eval(bb, e2);
						cll.push(lat == null ? Bottom : lat);
					}
					return LEnumValue(ef.index, cll);
				case TEnumParameter(e1, _, i):
					var lat = eval(bb, e1);
					if (lat == null) return null;
					return switch (lat) {
						case LEnumValue(_, el): i >= el.length ? null : el[i];
						case _: null;
					}
				case TEnumIndex(e1):
					var lat = eval(bb, e1);
					if (lat == null) return null;
					return switch (lat) {
						case LEnumValue(i, _): LConst(TInt(i));
						case _: null;
					}
				case TCall({expr: TField(_, FStatic(c = {path: {pack: [], name: "Type"}}, cf = {name: "enumIndex"}))}, [e1]) if (ctx.com.platform.match(Eval)):
					var t1 = TypeFunctions.follow(e1.type);
					var lat = eval(bb, e1);
					if (lat == null) return null;
					switch [t1, lat] {
						case [TEnum(_, _), LEnumValue(i, _)]:
							return LConst(TInt(i));
						case [_, lat1]:
							var w = wrap(lat1, e);
							if (w == null) return null;
							var e2 = Optimizer.apiInline2(ctx.com, c, cf.name, [w], e.pos);
							if (e2 == null) return null;
							return eval(bb, e2);
					}
				case TCall({expr: TField(_, FStatic(c, cf))}, el):
					var el2:Array<TExpr> = [];
					for (e2 in el) {
						var lat = eval(bb, e2);
						if (lat == null) return null;
						var w = wrap(lat, e);
						if (w == null) return null;
						el2.push(w);
					}
					var e2 = Optimizer.apiInline2(ctx.com, c, cf.name, el2, e.pos);
					if (e2 == null) return null;
					return eval(bb, e2);
				case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null):
					return eval(bb, e1);
				case _:
					var e1 = switch [ctx.com.platform, e.expr] {
						case [Js, TArray(e1, {expr: TConst(TInt(i))})] if (i == 1 && ctx.com.defines.rawDefined("js_enums_as_arrays")): e1;
						case [Js, TField(e1, FDynamic("_hx_index"))] if (!ctx.com.defines.rawDefined("js_enums_as_arrays")): e1;
						case [Cpp, TCall({expr: TField(e1, FDynamic("__Index"))}, [])]: e1;
						case [Neko, TField(e1, FDynamic("index"))]: e1;
						case _: null;
					};
					if (e1 == null) return null;
					var t1 = TypeFunctions.follow(e1.type);
					var lat = eval(bb, e1);
					if (lat == null) return null;
					return switch [t1, lat] {
						case [TEnum(_, _), LEnumValue(i, _)]: LConst(TInt(i));
						case _: null;
					}
			}
		}
		var r = eval(bb, e);
		return r == null ? Bottom : r;
	}

	static function init(ctx:AnalyzerContext):Void {
		lattice = new IntMap();
	}

	static function commitAll(ctx:AnalyzerContext):Void {
		// Null means "cannot inline this cell". A nullable return instead of a throw: on hxcpp a
		// throw+catch is expensive and this is a hot site. The result is consumed immediately at three
		// local call sites below, so a nullable return is observationally identical.
		function inlineCell(e:TExpr, i:Int):Null<TExpr> {
			return switch (getCell(i)) {
				case Top | Bottom | LEnumValue(_, _) | LNull(_):
					null;
				case LConst(ct):
					var e2 = TexprTools.typeConstant(ctx.com.basic, TypeFunctions.tconstToConst(ct), e.pos);
					if (!AnalyzerTexpr.typeChangeOk(ctx.com, e2.type, e.type)) null else e2;
				case LModuleType(mt, t):
					if (!AnalyzerTexpr.typeChangeOk(ctx.com, t, e.type)) null
					else TypeFunctions.mk(TTypeExpr(mt), t, e.pos);
			};
		}
		function isSpecialVar(v:TVar):Bool {
			return TypeFunctions.hasVarFlag(v, VCaptured) || AnalyzerFusion.ExtTypeSemantics.hasVariableSemantics(v.type);
		}
		// A local passed to an untyped __global__ call may be mutated by reference (a cpp out-param such
		// as __hxcpp_string_of_bytes(b, result, pos, len)). Such a local must never be const-inlined
		// (neither at the call arg nor at a later read), or the pre-call value replaces the mutated one.
		// Collecting these escaped locals keeps them multi-use, so fusion also leaves them alone.
		var escaped = new IntMap<Bool>();
		function scanEscaped(e:TExpr):Void {
			switch (e.expr) {
				case TCall(callee, args) if (switch (callee.expr) { case TField(o, _): o.expr.match(TIdent("__global__")); case _: false; }):
					for (a in args) switch (a.expr) { case TLocal(v): escaped.set(v.id, true); case _: }
				case _:
			}
			TexprTools.iter(scanEscaped, e);
		}
		ctx.graph.iterDomTree(function(bb) {
			for (e in bb.el) scanEscaped(e);
			BasicBlock.terminatorMap(function(e) { scanEscaped(e); return e; }, bb.terminator);
		});
		var commit:TExpr->TExpr = null;
		commit = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TLocal(v) if (!isSpecialVar(v) && !escaped.exists(v.id)):
					var r = inlineCell(e, v.id);
					r == null ? e : r;
				case TBinop(op = OpAssign | OpAssignOp(_), e1 = {expr: TLocal(v)}, e2):
					var r = OptimizerTexpr.hasSideEffect(e2) ? null : inlineCell(e2, v.id);
					var e2 = r == null ? commit(e2) : r;
					TypeFunctions.mk(TBinop(op, e1, e2), e.type, e.pos);
				case TVarExpr(v, e1) if (e1 != null && !OptimizerTexpr.hasSideEffect(e1)):
					var r = inlineCell(e1, v.id);
					var e1 = r == null ? commit(e1) : r;
					TypeFunctions.mk(TVarExpr(v, e1), e.type, e.pos);
				case _:
					TexprTools.mapExpr(commit, e);
			};
		}
		ctx.graph.iterDomTree(function(bb) {
			var anyExecutable = false;
			for (edge in bb.incoming) if (BasicBlock.edgeHasFlag(edge, FlagExecutable)) { anyExecutable = true; break; }
			if (!anyExecutable) bb.dominator = ctx.graph.unreachable;
			AnalyzerHelper.mapArrayInPlace(bb.el, commit);
			bb.terminator = BasicBlock.terminatorMap(commit, bb.terminator);
		});
	}

	public static function apply(ctx:AnalyzerContext):Void {
		DataFlow.apply(ctx, ({
			flag: FlagExecutable,
			transfer: transfer,
			equals: latEquals,
			bottom: Bottom,
			top: Top,
			getCell: getCell,
			setCell: setCell,
			init: init,
			commit: commitAll,
			conditional: true
		} : DataFlowApi<ConstLattice>));
	}
}

enum CopyLattice {
	CopyTop;
	CopyBottom;
	CopyLocal(v:TVar);
	CopyThis(t:T);
}

class CopyPropagation {
	static var lattice:IntMap<CopyLattice> = new IntMap();

	static function getCell(i:Int):CopyLattice {
		var r = lattice.get(i);
		return r == null ? CopyTop : r;
	}

	static function setCell(i:Int, ct:CopyLattice):Void {
		lattice.set(i, ct);
	}

	static function latEquals(t1:CopyLattice, t2:CopyLattice):Bool {
		return switch [t1, t2] {
			case [CopyTop, CopyTop]: true;
			case [CopyBottom, CopyBottom]: true;
			case [CopyLocal(v1), CopyLocal(v2)]: v1.id == v2.id;
			case [CopyThis(t1), CopyThis(t2)]: t1 == t2;
			case _: false;
		};
	}

	static function transfer(ctx:AnalyzerContext, bb:BasicBlock, e:TExpr):CopyLattice {
		var loop:TExpr->CopyLattice = null;
		loop = function(e:TExpr):CopyLattice {
			return switch (e.expr) {
				case TLocal(v) if (!TypeFunctions.hasVarFlag(v, VCaptured)):
					CopyLocal(v);
				case TConst(TThis):
					CopyThis(e.type);
				case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null):
					loop(e1);
				case _:
					CopyBottom;
			};
		}
		return loop(e);
	}

	static function init(ctx:AnalyzerContext):Void {
		lattice = new IntMap();
	}

	static function commitAll(ctx:AnalyzerContext):Void {
		var commit:(BasicBlock, TExpr)->TExpr = null;
		commit = function(bb:BasicBlock, e:TExpr):TExpr {
			return switch (e.expr) {
				case TLocal(v) if (!TypeFunctions.hasVarFlag(v, VCaptured)):
					// Null means "keep the original local". A nullable return avoids a hot throw+catch on
					// hxcpp. leave() clears the lattice cell - the side effect is the point, the null is
					// only
					// the exit.
					var lat = getCell(v.id);
					inline function leave():Null<TExpr> {
						lattice.remove(v.id);
						return null;
					}
					var r:Null<TExpr> = switch (lat) {
						case CopyLocal(v2):
							if (!AnalyzerTexpr.typeChangeOk(ctx.com, v2.type, v.type)) leave();
							else {
								var v3 = ctx.graph.getVarOrigin(v2);
								// Only consider variables whose origin variables are assigned to at
								// most once; multiple SSA vars may map back to the same origin var,
								// creating interference the analysis does not track.
								var writes = ctx.graph.getVarInfo(v3).writes;
								var inScope = switch (writes) {
									case [bb2] if (BasicBlock.inScope(bb, bb2)): true;
									case _: false;
								};
								if (!inScope) leave()
								else commit(bb, TypeFunctions.mk(TLocal(v2), e.type, e.pos));
							}
						case CopyThis(t):
							if (!AnalyzerTexpr.typeChangeOk(ctx.com, t, v.type)) leave();
							else TypeFunctions.mk(TConst(TThis), t, e.pos);
						case CopyTop | CopyBottom:
							leave();
					};
					r == null ? e : r;
				case TBinop(op = OpAssign | OpAssignOp(_), e1 = {expr: TLocal(_)}, e2):
					var e2 = commit(bb, e2);
					TypeFunctions.mk(TBinop(op, e1, e2), e.type, e.pos);
				case _:
					TexprTools.mapExpr(commit.bind(bb), e);
			};
		}
		ctx.graph.iterDomTree(function(bb) {
			AnalyzerHelper.mapArrayInPlace(bb.el, commit.bind(bb));
			bb.terminator = BasicBlock.terminatorMap(commit.bind(bb), bb.terminator);
		});
	}

	public static function apply(ctx:AnalyzerContext):Void {
		DataFlow.apply(ctx, ({
			flag: FlagCopyPropagation,
			transfer: transfer,
			equals: latEquals,
			bottom: CopyBottom,
			top: CopyTop,
			getCell: getCell,
			setCell: setCell,
			init: init,
			commit: commitAll,
			conditional: false
		} : DataFlowApi<CopyLattice>));
	}
}

class LocalDce {
	// Like the optimizer's side-effect check but phi/fun markers are pure
	static function hasSideEffect(e:TExpr):Bool {
		// Finding a side effect answers true at once.
		function loop(e:TExpr):Bool {
			return switch (e.expr) {
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TIdent(_): false;
				case TCall({expr: TField(_, FStatic({path: {pack: [], name: "Std"}}, {name: "string"}))}, _):
					TexprTools.checkExpr(loop, e);
				case TCall({expr: TField(_, FEnum(_, _))}, _):
					TexprTools.checkExpr(loop, e);
				case TCall({expr: TConst(TString("phi" | "fun"))}, _): false;
				case TCall({expr: TField(e1, fa)}, el) if (PurityState.isPureFieldAccess(fa)):
					loop(e1) || TexprTools.existsIn(loop, el);
				case TField(_, fa) if (PurityState.isExplicitlyImpure(fa)): true;
				case TNew(_, _, _) | TCall(_, _) | TBinop(OpAssignOp(_) | OpAssign, _, _) | TUnop(Increment | Decrement, _, _): true;
				case TReturn(_) | TBreak | TContinue | TThrow(_): true;
				case TCast(_, mt) if (mt != null): true;
				case TFor(_, _, _): true;
				case _: TexprTools.checkExpr(loop, e);
			};
		}
		return loop(e);
	}

	public static function apply(ctx:AnalyzerContext):Void {
		function isUsed(v:TVar):Bool {
			return TypeFunctions.hasVarFlag(v, VAnalyzed);
		}
		function keep(v:TVar):Bool {
			return isUsed(v)
				|| ((v.kind.match(VUser(_)) || v.kind.match(VInlined)) && !ctx.config.localDce)
				|| AnalyzerFusion.ExtTypeSemantics.hasReferenceSemantics(v.type)
				|| TypeFunctions.hasVarFlag(v, VCaptured)
				|| TypeFunctions.hasMeta(":this", v.meta);
		}
		var expr:TExpr->Void = null;
		function use(v:TVar):Void {
			if (!isUsed(v)) {
				TypeFunctions.addVarFlag(v, VAnalyzed);
				try expr(ctx.graph.getVarValue(v)) catch (_:NotFound) {};
				var rd = Ssa.getReachingDef(ctx.graph, v);
				if (rd == null) {
					// Don't fully recurse into the origin variable; marking it used suffices (issue #10972)
					var v2 = ctx.graph.getVarOrigin(v);
					if (!isUsed(v2)) TypeFunctions.addVarFlag(v2, VAnalyzed);
				} else {
					use(rd);
				}
			}
		}
		expr = function(e:TExpr):Void {
			switch (e.expr) {
				case TLocal(v):
					use(v);
				case TBinop(OpAssign, {expr: TLocal(v)}, e1) | TVarExpr(v, e1) if (e1 != null):
					if (hasSideEffect(e1) || keep(v)) expr(e1);
				case _:
					TexprTools.iter(expr, e);
			}
		}
		function mark(bb:BasicBlock):Void {
			bb.addBlockFlag(BlockDce);
			for (e in bb.el) expr(e);
			for (e in bb.phi) expr(e);
			BasicBlock.terminatorIter(expr, bb.terminator);
			for (edge in bb.outgoing) {
				if (!BasicBlock.edgeHasFlag(edge, FlagDce)) {
					edge.flags.unshift(FlagDce);
					if (!ctx.config.constPropagation || BasicBlock.edgeHasFlag(edge, FlagExecutable))
						mark(edge.to);
				}
			}
		}
		mark(ctx.graph.root);
		var sweep:TExpr->TExpr = null;
		sweep = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TBinop(OpAssign, {expr: TLocal(v)}, e2) | TVarExpr(v, e2) if (e2 != null && !keep(v)):
					if (hasSideEffect(e2))
						e2;
					else
						TypeFunctions.mk(TConst(TNull), e.type, e.pos);
				case TVarExpr(v, null) if (!keep(v)):
					TypeFunctions.mk(TConst(TNull), e.type, e.pos);
				case _:
					TexprTools.mapExpr(sweep, e);
			};
		}
		ctx.graph.iterDomTree(function(bb) {
			if (bb.hasBlockFlag(BlockDce)) {
				AnalyzerHelper.mapArrayInPlace(bb.el, sweep);
				bb.terminator = BasicBlock.terminatorMap(sweep, bb.terminator);
			}
		});
	}
}

class Run {
	// Timers are not implemented.
	public static function createAnalyzerContext(com:Context, config:AnalyzerConfig, identifier:String, e:TExpr):AnalyzerContext {
		var g = Graph.create(e.type, e.pos);
		var ctx = new AnalyzerContext(com, config, g, identifier);
		// For cpp, prefer variable names the debugger will not collide with (hxcpp#365)
		ctx.tempVarName = com.platform.match(Cpp) ? "_hx_tmp" : "tmp";
		ctx.entry = g.unreachable;
		return ctx;
	}

	static function addDebugExpr(ctx:AnalyzerContext, s:String, e:TExpr):Void {
		ctx.debugExprs.unshift({s: s, e: e});
	}

	static function there(actx:AnalyzerContext, e:TExpr):Bool {
		if (actx.com.debug) addDebugExpr(actx, "initial", e);
		var e = AnalyzerTexpr.TexprFilter.apply(actx.com, e);
		if (actx.com.debug) addDebugExpr(actx, "after filter-apply", e);
		var tf:TFunc;
		var t:T;
		var isRealFunction:Bool;
		switch (e.expr) {
			case TFunction(tf2):
				tf = tf2;
				t = e.type;
				isRealFunction = true;
			case _:
				// Wrap the expression in a function so it needs no special casing
				var t2 = e.type;
				var eRet = TypeFunctions.mk(TReturn(e), TypeFunctions.tDynamic, e.pos);
				tf = new TFunc([], t2, eRet);
				t = TypeFunctions.tfun([], t2);
				isRealFunction = false;
		}
		AnalyzerTexprTransformer.fromTfunction(actx, tf, t, e.pos);
		return isRealFunction;
	}

	static function backAgain(actx:AnalyzerContext, isRealFunction:Bool):TExpr {
		var e = AnalyzerTexprTransformer.toTexpr(actx);
		if (actx.com.debug) addDebugExpr(actx, "after to-texpr", e);
		for (vi in actx.graph.varInfos)
			vi.variable.extra = vi.extra;
		if (actx.config.fusion) e = AnalyzerFusion.Fusion.apply(actx, e);
		if (actx.com.debug) addDebugExpr(actx, "after fusion", e);
		e = AnalyzerFusion.Cleanup.apply(actx.com, e);
		if (actx.com.debug) addDebugExpr(actx, "after cleanup", e);
		if (!isRealFunction) {
			// Remove the wrapping function and its return expressions
			switch (e.expr) {
				case TFunction(tf):
					function getT(t:T):T return AnalyzerHelper.isVoidT(t) ? tf.type : t;
					var loop:TExpr->TExpr = null;
					loop = function(e:TExpr):TExpr {
						return switch (e.expr) {
							case TBlock([e1]):
								loop(e1);
							// A complex expression keeps the function; generate a call to it
							case TBlock(_) | TIf(_, _, _) | TSwitch(_, _, _) | TTry(_, _) if (actx.com.platform.match(Cpp) || actx.com.platform.match(Hl)):
								throw new Exit();
							case TReturn(e1) if (e1 != null):
								e1;
							case TBlock(el):
								if (el.length > 0) {
									var e1 = loop(el[el.length - 1]);
									var el2 = el.slice(0, el.length - 1);
									el2.push(e1);
									TypeFunctions.mk(TBlock(el2), e.type, e.pos);
								} else e;
							case TIf(e1, e2, e3) if (e3 != null):
								var e2 = loop(e2);
								var e3 = loop(e3);
								TypeFunctions.mk(TIf(e1, e2, e3), getT(e.type), e.pos);
							case TSwitch(e1, cases, edef):
								var cases = [for (c in cases) {values: c.values, expr: loop(c.expr)}];
								var edef = edef == null ? null : loop(edef);
								TypeFunctions.mk(TSwitch(e1, cases, edef), getT(e.type), e.pos);
							case TTry(e1, catches):
								var e1 = loop(e1);
								var catches = [for (c in catches) {v: c.v, expr: loop(c.expr)}];
								TypeFunctions.mk(TTry(e1, catches), getT(e.type), e.pos);
							case TMeta(m, e1):
								TypeFunctions.mk(TMeta(m, loop(e1)), e.type, e.pos);
							case TParenthesis(e1):
								TypeFunctions.mk(TParenthesis(loop(e1)), e.type, e.pos);
							case _:
								e;
						};
					}
					e = try loop(tf.expr) catch (_:Exit) TypeFunctions.mk(TCall(e, []), tf.type, e.pos);
				case _:
					throw new TypingError("Malformed analyzer wrapper function", e.pos);
			}
		}
		return e;
	}

	public static function runOnExpr(actx:AnalyzerContext, e:TExpr):TExpr {
		var isRealFunction = there(actx, e);
		actx.graph.inferImmediateDominators();
		actx.graph.inferScopes();
		actx.graph.inferVarWrites();
		if (actx.config.optimize && !actx.hasUnbound) {
			actx.didOptimize = true;
			Ssa.apply(actx);
			if (actx.config.constPropagation) ConstPropagation.apply(actx);
			if (actx.config.copyPropagation) CopyPropagation.apply(actx);
			LocalDce.apply(actx);
		}
		return backAgain(actx, isRealFunction);
	}

	public static function reduceControlFlow(com:Context, e:TExpr):TExpr {
		var e = TexprTools.mapExpr(reduceControlFlow.bind(com), e);
		return Optimizer.reduceControlFlow(com, e);
	}

	// The dot debug output is not implemented.
	static function runOnFieldSingle(com:Context, config:AnalyzerConfig, c:TClass, cf:TClassField):Void {
		var e = cf.expr;
		if (e == null || AnalyzerConfig.isIgnored(cf.meta) || FiltersCommon.isRemovableField(com, cf)
				|| TypeFunctions.hasClassFieldFlag(cf, CfPostProcessed))
			return;
		var config = AnalyzerConfig.updateConfigFromMeta(com, config, cf.meta);
		var identifier = hxc.core.Globals.sTypePath(c.path) + "." + cf.name;
		var actx = createAnalyzerContext(com, config, identifier, e);
		var e = runOnExpr(actx, e);
		e = reduceControlFlow(com, e);
		cf.expr = e;
		// @:analyzer(full_debug) prints every collected stage AST.
		if (config.debugKind.match(DebugFull)) {
			Sys.println("While analyzing " + identifier);
			var stages = actx.debugExprs.copy();
			stages.reverse();
			for (st in stages) {
				Sys.println("<" + st.s + ">");
				Sys.println(hxc.core.TPrinting.sExprPretty(true, "", false, hxc.core.TPrinting.sTypeStr, st.e));
				Sys.println("</" + st.s + ">");
			}
		}
	}

	public static function runOnField(com:Context, config:AnalyzerConfig, c:TClass, cf:TClassField):Void {
		runOnFieldSingle(com, config, c, cf);
		for (cf2 in cf.overloads) runOnField(com, config, c, cf2);
	}

	static function runOnClass(com:Context, config:AnalyzerConfig, c:TClass):Void {
		var config = AnalyzerConfig.updateConfigFromMeta(com, config, c.meta);
		function processField(stat:Bool, cf:TClassField):Void {
			switch (cf.kind) {
				case Var(_) if (!stat):
				case _: runOnField(com, config, c, cf);
			}
		}
		for (cf in c.orderedFields) processField(false, cf);
		for (cf in c.orderedStatics) processField(true, cf);
		if (c.constructor != null) processField(false, c.constructor);
		if (c.init != null) {
			var einit = c.init;
			var tf = new TFunc([], einit.type, einit);
			var e = TypeFunctions.mk(TFunction(tf), TypeFunctions.tfun([], einit.type), einit.pos);
			var config2 = config.copy();
			config2.optimize = false;
			var actx = createAnalyzerContext(com, config2, hxc.core.Globals.sTypePath(c.path) + ".__init__", e);
			var e = runOnExpr(actx, e);
			switch (e.expr) {
				case TFunction(tf): c.init = tf.expr;
				case _: throw new TypingError("Malformed __init__ analyzer result", e.pos);
			}
		}
	}

	static function runOnType(com:Context, config:AnalyzerConfig, t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c) if (AnalyzerConfig.isIgnored(c.meta)):
			case TClassDecl(c): runOnClass(com, config, c);
			case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
		}
	}

	public static function runOnTypes(com:Context, types:Array<ModuleType>):Void {
		var config = AnalyzerConfig.getBaseConfig(com);
		if (config.optimize && config.purityInference)
			AnalyzerFusion.PurityInference.infer(com);
		for (t in types) runOnType(com, config, t);
	}

	// Always optimize so const
	// propagation can produce constant inline field initializations.
	public static function runOnExprStandalone(com:Context, identifier:String, e:TExpr):TExpr {
		var config = AnalyzerConfig.getBaseConfig(com);
		config.optimize = true;
		var actx = createAnalyzerContext(com, config, identifier, e);
		return runOnExpr(actx, e);
	}
}
