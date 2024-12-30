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
