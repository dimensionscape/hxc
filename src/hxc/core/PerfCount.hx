package hxc.core;

// Env-gated call counters (HXC_DBG_COUNT). Counting is how a SUPERLINEAR term is found: run
// the same workload at two input sizes and look for the counter that grows ~4x when the
// input grows 2x. Timing alone cannot distinguish "slow" from "called too often".
class PerfCount {
	public static var on:Bool = Sys.getEnv("HXC_DBG_COUNT") != null;
	static var counts:haxe.ds.StringMap<Int> = new haxe.ds.StringMap();

	public static inline function bump(k:String):Void {
		var c = counts.get(k);
		counts.set(k, c == null ? 1 : c + 1);
	}

	// HXC_DBG_WALK: count the nodes actually REACHABLE from the compiler's own roots.
	// Unlike attribution-by-removal this cannot be confounded by the conservative stack
	// scan, and unlike Gc.trace it needs no debug runtime. Answers one question: is the
	// typed AST the live set, or is the live set somewhere else entirely?
	static var wTExpr = 0;
	static var wDepth = 0;
	static var wMaxDepth = 0;
	static var wPos:haxe.ds.ObjectMap<Dynamic, Bool> = new haxe.ds.ObjectMap();
	static var wPosN = 0;
	static function walkE(e:hxc.core.Type.TExpr):Void {
		wTExpr++;
		wDepth++;
		if (wDepth > wMaxDepth) wMaxDepth = wDepth;
		if (e.pos != null && !wPos.exists(e.pos)) { wPos.set(e.pos, true); wPosN++; }
		hxc.core.TexprTools.iter(walkE, e);
		wDepth--;
	}
	public static function walk(com:hxc.context.Context):Void {
		if (Sys.getEnv("HXC_DBG_WALK") == null) return;
		var nFields = 0, nTypes = 0;
		for (t in com.types) {
			nTypes++;
			switch (t) {
				case TClassDecl(c):
					function f(cf:hxc.core.Type.TClassField) {
						nFields++;
						if (cf.expr != null) walkE(cf.expr);
					}
					for (cf in c.orderedFields) f(cf);
					for (cf in c.orderedStatics) f(cf);
					if (c.constructor != null) f(c.constructor);
					if (c.init != null) walkE(c.init);
				case _:
			}
		}
		if (com.main != null) walkE(com.main);
		var o = Sys.stderr();
		o.writeString("[walk] types=" + nTypes + " fields=" + nFields + " reachableTExpr=" + wTExpr
			+ " distinctPos=" + wPosN + " maxDepth=" + wMaxDepth + "\n");
		// TExpr is header+3 fields; each carries one TExprExpr enum object of similar size.
		o.writeString("[walk] typed AST approx = " + Std.int(wTExpr * 80 / 1048576) + "MB (at 80B/node)\n");
		o.flush();
	}

	// Exception-construction counters (HXC_DBG_EXN). The class-total bumps are always on (an int increment
	// costs nothing next to the throw itself); the per-site StringMap counting in each exception
	// constructor checks exnDbg first, and the dump is env-gated. hxcpp throws are expensive, and the typer
	// uses exceptions for CONTROL FLOW.
	public static var exnDbg:Bool = Sys.getEnv("HXC_DBG_EXN") != null;
	public static var exnNotFound = 0;
	public static var exnUnify = 0;
	public static var exnTyping = 0;
	public static var exnContext = 0;
	public static inline function exn(k:String):Void {
		switch (k) {
			case "NotFound": exnNotFound++;
			case "UnifyError": exnUnify++;
			case "TypingError": exnTyping++;
			case _: exnContext++;
		}
	}
	public static function dumpExn():Void {
		if (Sys.getEnv("HXC_DBG_EXN") == null) return;
		Sys.stderr().writeString("[exn] NotFound=" + exnNotFound + " UnifyError=" + exnUnify
			+ " TypingError=" + exnTyping + " ContextError=" + exnContext + "
");
	}

	public static function dump():Void {
		if (!on) return;
		var rows = [for (k in counts.keys()) {n: k, c: counts.get(k)}];
		rows.sort(function(a, b) return a.c < b.c ? 1 : -1);
		var o = Sys.stderr();
		for (r in rows) o.writeString("[count] " + StringTools.lpad(Std.string(r.c), " ", 10) + "  " + r.n + "
");
		o.flush();
	}
}
