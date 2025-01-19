package hxc.core;

class NotFound extends haxe.Exception {
	// Per-site throw counters (HXC_DBG_EXN to dump). The tag is a literal at each throw
	// site; counting is an int bump, nothing next to the ~1.3us the throw itself costs.
	public static var siteCounts:haxe.ds.StringMap<Int> = new haxe.ds.StringMap();

	public function new(?site:String) {
		hxc.core.PerfCount.exn("NotFound");
		if (site != null) {
			var c = siteCounts.get(site);
			siteCounts.set(site, c == null ? 1 : c + 1);
		}
		super("Not_found");
	}

	public static function dumpSites():Void {
		if (Sys.getEnv("HXC_DBG_EXN") == null) return;
		var rows = [for (k in siteCounts.keys()) {n: k, c: siteCounts.get(k)}];
		rows.sort(function(a, b) return a.c < b.c ? 1 : -1);
		var o = Sys.stderr();
		for (i in 0...(rows.length < 10 ? rows.length : 10))
			o.writeString("[exnsite] " + StringTools.lpad(Std.string(rows[i].c), " ", 9) + "  " + rows[i].n + "
");
		o.flush();
	}
}
