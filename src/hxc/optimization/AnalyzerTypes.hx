package hxc.optimization;


import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypingError;
import hxc.context.Context;
import haxe.ds.IntMap;

enum BlockKind {
	BKRoot;
	BKNormal;
	BKFunctionBegin(tf:TFunc);
	BKFunctionEnd;
	BKSub;
	BKConditional;
	BKLoopHead;
	BKException;
	BKUnreachable;
	BKCatch(v:TVar);
}

enum FlagBlock {
	BlockDce;
}

enum CfgEdgeFlag {
	FlagExecutable;
	FlagDce;
	FlagCopyPropagation;
}

enum CfgEdgeKind {
	CFGGoto;
	CFGFunction;
	CFGMaybeThrow;
	CFGCondBranch(e:TExpr);
	CFGCondElse;
}

// A class for identity (edges are compared by identity)
class CfgEdge {
	public var from:BasicBlock;
	public var to:BasicBlock;
	public var kind:CfgEdgeKind;
	public var flags:Array<CfgEdgeFlag>;

	public function new(from:BasicBlock, to:BasicBlock, kind:CfgEdgeKind) {
		this.from = from;
		this.to = to;
		this.kind = kind;
		this.flags = [];
	}
}

enum SyntaxEdge {
	SEIfThen(bbThen:BasicBlock, bbNext:BasicBlock, p:Position);
	SEIfThenElse(bbThen:BasicBlock, bbElse:BasicBlock, bbNext:BasicBlock, t:T, p:Position);
	SESwitch(cases:Array<{el:Array<TExpr>, bb:BasicBlock}>, bbDefault:Null<BasicBlock>, bbNext:BasicBlock, p:Position);
	SETry(bbTry:BasicBlock, bbExc:BasicBlock, catches:Array<{v:TVar, bb:BasicBlock}>, bbNext:BasicBlock, p:Position);
	SEWhile(bbBody:BasicBlock, bbNext:BasicBlock, p:Position);
	SESubBlock(bbSub:BasicBlock, bbNext:BasicBlock);
	SEMerge(bb:BasicBlock);
	SENone;
}

enum TerminatorKind {
	TermNone;
	TermCondBranch(e:TExpr);
	TermReturn(p:Position);
	TermReturnValue(e:TExpr, p:Position);
	TermBreak(p:Position);
	TermContinue(p:Position);
	TermThrow(e:TExpr, p:Position);
}

enum TexprLookupTarget {
	LUPhi(i:Int);
	LUEl(i:Int);
	LUTerm;
}

class BasicBlock {
	public var id:Int;
	public var type:T;
	public var pos:Position;
	public var kind:BlockKind;
	public var closed:Bool;
	public var flags:Int;
	public var el:Array<TExpr>;
	public var phi:Array<TExpr>;
	public var terminator:TerminatorKind;
	public var outgoing:Array<CfgEdge>;
	public var incoming:Array<CfgEdge>;
	public var dominator:BasicBlock;
	public var dominated:Array<BasicBlock>;
	public var df:Array<BasicBlock>;
	public var syntaxEdge:SyntaxEdge;
	public var loopGroups:Array<Int>;
	public var scopes:Array<Int>;
	public var varWrites:Array<TVar>;

	public function new(id:Int, kind:BlockKind, t:T, p:Position) {
		this.kind = kind;
		this.id = id;
		this.type = t;
		this.pos = p;
		this.closed = false;
		this.flags = 0;
		this.el = [];
		this.phi = [];
		this.terminator = TermNone;
		this.outgoing = [];
		this.incoming = [];
		this.dominator = this;
		this.dominated = [];
		this.df = [];
		this.syntaxEdge = SENone;
		this.loopGroups = [];
		this.varWrites = [];
		this.scopes = [];
	}

	public function addBlockFlag(flag:FlagBlock):Void flags = hxc.core.Type.Flags.setFlag(flags, flag.getIndex());
	public function removeBlockFlag(flag:FlagBlock):Void flags = hxc.core.Type.Flags.unsetFlag(flags, flag.getIndex());
	public function hasBlockFlag(flag:FlagBlock):Bool return hxc.core.Type.Flags.hasFlag(flags, flag.getIndex());

	public static function sBlockKind(k:BlockKind):String {
		return switch (k) {
			case BKRoot: "BKRoot";
			case BKNormal: "BKNormal";
			case BKFunctionBegin(_): "BKFunctionBegin";
			case BKFunctionEnd: "BKFunctionEnd";
			case BKSub: "BKSub";
			case BKConditional: "BKConditional";
			case BKLoopHead: "BKLoopHead";
			case BKException: "BKException";
			case BKUnreachable: "BKUnreachable";
			case BKCatch(_): "BKCatch";
		};
	}

	public static function edgeHasFlag(edge:CfgEdge, flag:CfgEdgeFlag):Bool {
		return edge.flags.indexOf(flag) >= 0;
	}

	public inline function addTexpr(e:TExpr):Void {
		el.push(e);
	}

	public function getTexpr(luk:TexprLookupTarget):TExpr {
		return switch (luk) {
			case LUPhi(i): phi[i];
			case LUEl(i): el[i];
			case LUTerm: switch (terminator) {
				case TermCondBranch(e1) | TermReturnValue(e1, _) | TermThrow(e1, _): e1;
				case TermNone | TermReturn(_) | TermBreak(_) | TermContinue(_):
					throw new TypingError("No terminator expression", pos);
			}
		};
	}

	public inline function setSyntaxEdge(se:SyntaxEdge):Void {
		syntaxEdge = se;
	}

	public static function addCfgEdge(bbFrom:BasicBlock, bbTo:BasicBlock, kind:CfgEdgeKind):Void {
		if (!bbFrom.kind.match(BKUnreachable)) {
			var edge = new CfgEdge(bbFrom, bbTo, kind);
			bbFrom.outgoing.unshift(edge);
			bbTo.incoming.unshift(edge);
		}
	}

	public static function inScope(bb:BasicBlock, bb2:BasicBlock):Bool {
		if (bb2.scopes.length == 0)
			throw new TypingError("Scope-less block (kind: " + sBlockKind(bb2.kind) + ")", bb2.pos);
		return bb.scopes.indexOf(bb2.scopes[0]) >= 0;
	}

	public static function terminatorMap(f:TExpr->TExpr, term:TerminatorKind):TerminatorKind {
		return switch (term) {
			case TermCondBranch(e1): TermCondBranch(f(e1));
			case TermReturnValue(e1, p): TermReturnValue(f(e1), p);
			case TermThrow(e1, p): TermThrow(f(e1), p);
			case TermNone | TermReturn(_) | TermBreak(_) | TermContinue(_): term;
		};
	}

	public static function terminatorIter(f:TExpr->Void, term:TerminatorKind):Void {
		switch (term) {
			case TermCondBranch(e1) | TermReturnValue(e1, _) | TermThrow(e1, _): f(e1);
			case TermNone | TermReturn(_) | TermBreak(_) | TermContinue(_):
		}
	}
}

typedef TFuncInfo = {bb:BasicBlock, t:T, p:Position, tf:TFunc};
typedef TexprLookup = {bb:BasicBlock, luk:TexprLookupTarget};

class VarInfo {
	public var variable:TVar;
	public var extra:Null<TVarExtra>;
	public var bbDeclare:BasicBlock;
	public var origin:TVar;
	public var writes:Array<BasicBlock>;
	public var value:Null<TexprLookup>;
	public var ssaEdges:Array<TexprLookup>;
	public var reachingDef:Null<TVar>;

	public function new(v:TVar, bb:BasicBlock) {
		this.variable = v;
		this.extra = v.extra;
		this.bbDeclare = bb;
		this.origin = v;
		this.writes = [];
		this.value = null;
		this.ssaEdges = [];
		this.reachingDef = null;
	}
}

// Dominator inference bookkeeping
private class DomBBInfo {
	public var bb:BasicBlock;
	public var parent:DomBBInfo;
	public var idom:DomBBInfo;
	public var semi:Int;
	public var label:DomBBInfo;
	public var ancestor:DomBBInfo;
	public var bucket:Array<DomBBInfo>;

	public function new(bb:BasicBlock, semi:Int) {
		this.bb = bb;
		this.parent = this;
		this.idom = this;
		this.semi = semi;
		this.label = this;
		this.ancestor = this;
		this.bucket = [];
	}

	// A copy with a new parent: the copy's self-referencing fields still point at the original record
	public function copyWithParent(p:DomBBInfo):DomBBInfo {
		var c = new DomBBInfo(bb, semi);
		c.parent = p;
		c.idom = this.idom;
		c.label = this.label;
		c.ancestor = this.ancestor;
		c.bucket = this.bucket;
		return c;
	}
}

class Graph {
	public var root:BasicBlock;
	public var exit:BasicBlock;
	public var unreachable:BasicBlock;
	public var functions:IntMap<TFuncInfo>;
	public var nodes:Array<BasicBlock>;
	public var varInfos:Array<VarInfo>;
	public var loops:IntMap<BasicBlock>;

	static var nextId = 1;

	function new() {}

	public static function create(t:T, p:Position):Graph {
		var bbRoot = new BasicBlock(1, BKRoot, t, p);
		var bbUnreachable = new BasicBlock(0, BKUnreachable, TypeFunctions.tDynamic, Position.nullPos);
		var g = new Graph();
		g.root = bbRoot;
		g.exit = bbUnreachable;
		g.unreachable = bbUnreachable;
		g.functions = new IntMap();
		g.nodes = [bbRoot];
		g.varInfos = [];
		g.loops = new IntMap();
		return g;
	}

	// The info index rides in extra's expr
	public function createVarInfo(bb:BasicBlock, v:TVar):VarInfo {
		var vi = new VarInfo(v, bb);
		varInfos.push(vi);
		var i = varInfos.length - 1;
		v.extra = new TVarExtra([], TypeFunctions.mk(TConst(TInt(i)), TypeFunctions.tDynamic, Position.nullPos));
		return vi;
	}

	public function getVarInfo(v:TVar):VarInfo {
		if (v.extra != null && v.extra.expr != null) {
			switch (v.extra.expr.expr) {
				case TConst(TInt(i)): return varInfos[i];
				case _:
			}
		}
		Sys.println("Unbound variable, please report this");
		Sys.println(v.name);
		return createVarInfo(unreachable, v);
	}

	public inline function declareVar(v:TVar, bb:BasicBlock):Void {
		createVarInfo(bb, v);
	}

	public function addVarDef(bb:BasicBlock, v:TVar):Void {
		if (bb.id > 0) {
			bb.varWrites.unshift(v);
			var vi = getVarInfo(v);
			vi.writes.unshift(bb);
		}
	}

	public function setVarValue(v:TVar, bb:BasicBlock, luk:TexprLookupTarget):Void {
		getVarInfo(v).value = {bb: bb, luk: luk};
	}

	// Throws when no value is recorded
	public function getVarValue(v:TVar):TExpr {
		var value = getVarInfo(v).value;
		if (value == null) throw new hxc.core.NotFound();
		return switch (value.bb.getTexpr(value.luk).expr) {
			case TVarExpr(_, e) if (e != null): e;
			case TBinop(OpAssign, _, e): e;
			case _: throw new TypingError("Invalid var value", value.bb.pos);
		};
	}

	public function addVarOrigin(v:TVar, vOrigin:TVar):Void {
		getVarInfo(v).origin = vOrigin;
	}

	public function getVarOrigin(v:TVar):TVar {
		return getVarInfo(v).origin;
	}

	public function addSsaEdge(v:TVar, bb:BasicBlock, luk:TexprLookupTarget):Void {
		getVarInfo(v).ssaEdges.unshift({bb: bb, luk: luk});
	}

	public function addFunction(tf:TFunc, t:T, p:Position, bb:BasicBlock):Void {
		functions.set(bb.id, {bb: bb, t: t, p: p, tf: tf});
	}

	// First call yields 2; the root took 1
	public static function allocId():Int {
		nextId++;
		return nextId;
	}

	public static function resetIds():Void {
		nextId = 1;
	}

	public function createNode(kind:BlockKind, t:T, p:Position):BasicBlock {
		var bb = new BasicBlock(allocId(), kind, t, p);
		nodes.unshift(bb);
		return bb;
	}

	public static function closeNode(bb:BasicBlock):Void {
		if (bb.id > 0) {
			if (bb.closed) throw new TypingError("Block closed twice", bb.pos);
			bb.closed = true;
		}
	}

	public function iterDomTreeFrom(bb:BasicBlock, f:BasicBlock->Void):Void {
		f(bb);
		for (d in bb.dominated) iterDomTreeFrom(d, f);
	}

	public function iterDomTree(f:BasicBlock->Void):Void {
		iterDomTreeFrom(root, f);
	}

	public function iterEdgesFrom(bb:BasicBlock, f:CfgEdge->Void):Void {
		iterDomTreeFrom(bb, function(bb) for (e in bb.outgoing) f(e));
	}

	public function iterEdges(f:CfgEdge->Void):Void {
		iterDomTree(function(bb) for (e in bb.outgoing) f(e));
	}

	public function inferImmediateDominators():Void {
		var info = new IntMap<DomBBInfo>();
		var nodes:Array<DomBBInfo> = [];
		inline function getInfo(i:Int):DomBBInfo return info.get(i);
		function addInfo(bb:BasicBlock, bbParent:BasicBlock):Void {
			var bbi = new DomBBInfo(bb, nodes.length);
			if (bb != bbParent) bbi = bbi.copyWithParent(getInfo(bbParent.id));
			info.set(bb.id, bbi);
			nodes.push(bbi);
		}
		function walk(bbParent:BasicBlock, bb:BasicBlock):Void {
			bb.dominated = [];
			addInfo(bb, bbParent);
			for (edge in bb.outgoing) {
				var bbTo = edge.to;
				if (!info.exists(bbTo.id)) walk(bb, bbTo);
			}
		}
		walk(root, root);
		function compress(bbi:DomBBInfo):Void {
			// Collect the ancestor chain up to the tree root
			var worklist = [bbi];
			var a = bbi.ancestor;
			while (a.ancestor != a) {
				worklist.unshift(a);
				a = a.ancestor;
			}
			if (worklist.length > 0) {
				var head = worklist[0];
				var minSemi = head.label.semi;
				var cur = head;
				for (i in 1...worklist.length) {
					var bbiDesc = worklist[i];
					var lbl = bbiDesc.label;
					if (lbl.semi > minSemi) {
						bbiDesc.label = cur.label;
					} else {
						minSemi = lbl.semi;
					}
					cur = bbiDesc;
				}
			}
		}
		function eval(v:Int):DomBBInfo {
			var bbi = getInfo(v);
			if (bbi.ancestor != bbi) {
				compress(bbi);
				return bbi.label;
			}
			return bbi;
		}
		// Process in reverse discovery order, skipping the root
		var i = nodes.length - 1;
		while (i > 0) {
			var w = nodes[i];
			var semi = w.semi;
			for (v in w.bb.incoming) {
				var s = eval(v.from.id).semi;
				if (s < semi) semi = s;
			}
			w.semi = semi;
			var bbi = nodes[semi];
			bbi.bucket.unshift(w);
			var bbiP = w.parent;
			w.ancestor = bbiP;
			for (v in bbiP.bucket) {
				var u = eval(v.bb.id);
				v.idom = u.semi < v.semi ? u : bbiP;
			}
			bbiP.bucket = [];
			i--;
		}
		for (j in 1...nodes.length) {
			var w = nodes[j];
			if (w.idom != nodes[w.semi]) w.idom = w.idom.idom;
		}
		for (bbi in nodes) {
			if (bbi.idom != bbi) {
				var bb = bbi.bb;
				var bb2 = bbi.idom.bb;
				if (bb != bb2) {
					bb.dominator = bb2;
					bb2.dominated.unshift(bb);
				}
			}
		}
	}

	public function inferDominanceFrontier():Void {
		iterEdges(function(edge) {
			var bb = edge.from;
			while (bb != unreachable && bb != edge.to && bb != edge.to.dominator) {
				if (edge.to != exit) bb.df.unshift(edge.to);
				if (bb.dominator == bb) break;
				bb = bb.dominator;
			}
		});
	}

	public function inferVarWrites():Void {
		iterDomTree(function(bb) {
			switch (bb.kind) {
				case BKCatch(v):
					declareVar(v, bb);
					addVarDef(bb, v);
				case BKFunctionBegin(tf):
					for (a in tf.args) {
						declareVar(a.v, bb);
						addVarDef(bb, a.v);
					}
				case _:
			}
			function infer(e:TExpr):Void {
				switch (e.expr) {
					case TVarExpr(v, eo):
						declareVar(v, bb);
						if (eo != null) addVarDef(bb, v);
					case TBinop(OpAssign, {expr: TLocal(v)}, _):
						addVarDef(bb, v);
					case _:
				}
			}
			for (e in bb.el) infer(e);
			BasicBlock.terminatorIter(infer, bb.terminator);
		});
	}

	public function inferScopes():Void {
		var nextScopeId = 0;
		inline function nextScope(scopes:Array<Int>):Array<Int> {
			nextScopeId++;
			return [nextScopeId].concat(scopes);
		}
		function walk(scopes:Array<Int>, bb:BasicBlock):Void {
			bb.scopes = scopes;
			switch (bb.syntaxEdge) {
				case SEIfThen(bbThen, bbNext, _):
					walk(nextScope(scopes), bbThen);
					walk(scopes, bbNext);
				case SEIfThenElse(bbThen, bbElse, bbNext, _, _):
					walk(nextScope(scopes), bbThen);
					walk(nextScope(scopes), bbElse);
					walk(scopes, bbNext);
				case SESwitch(cases, bbo, bbNext, _):
					for (c in cases) walk(nextScope(scopes), c.bb);
					if (bbo != null) walk(nextScope(scopes), bbo);
					walk(scopes, bbNext);
				case SETry(bbTry, bbExc, catches, bbNext, _):
					var scopes2 = nextScope(scopes);
					walk(scopes2, bbTry);
					walk(scopes2, bbExc);
					for (c in catches) walk(nextScope(scopes), c.bb);
					walk(scopes, bbNext);
				case SEWhile(bbBody, bbNext, _):
					walk(nextScope(scopes), bbBody);
					walk(scopes, bbNext);
				case SESubBlock(bbSub, bbNext):
					walk(nextScope(scopes), bbSub);
					walk(scopes, bbNext);
				case SEMerge(bb2):
					walk(scopes, bb2);
				case SENone:
			}
		}
		for (fi in functions) walk([0], fi.bb);
	}
}

class AnalyzerContext {
	public var com:Context;
	public var config:AnalyzerConfig;
	public var graph:Graph;
	public var tempVarName:String;
	public var identifier:String;
	public var entry:BasicBlock;
	public var hasUnbound:Bool;
	public var loopCounter:Int;
	public var loopStack:Array<Int>;
	public var debugExprs:Array<{s:String, e:TExpr}>;
	public var nameStack:Array<String>;
	public var didOptimize:Bool;

	public function new(com:Context, config:AnalyzerConfig, graph:Graph, identifier:String) {
		this.com = com;
		this.config = config;
		this.graph = graph;
		this.tempVarName = "tmp";
		this.identifier = identifier;
		this.entry = graph.root;
		this.hasUnbound = false;
		this.loopCounter = 0;
		this.loopStack = [];
		this.debugExprs = [];
		this.nameStack = [];
		this.didOptimize = false;
	}
}
