package hxc.core;

// Suggests the closest candidate names for a mistyped identifier.
class StringError {
	public static function levenshtein(a:String, b:String):Int {
		var m = a.length, n = b.length;
		if (m == 0) return n;
		if (n == 0) return m;
		// Matrix[i][j]; row i-1 kept as `prev`, row i as `cur`.
		var prev = [for (j in 0...n + 1) j];
		var cur = [for (_ in 0...n + 1) 0];
		for (i in 1...m + 1) {
			cur[0] = i;
			for (j in 1...n + 1) {
				var cost = a.charCodeAt(i - 1) == b.charCodeAt(j - 1) ? 0 : 1;
				var del = prev[j] + 1;
				var ins = cur[j - 1] + 1;
				var sub = prev[j - 1] + cost;
				cur[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
			}
			var tmp = prev; prev = cur; cur = tmp;
		}
		return prev[n];
	}

	// Candidates sorted by edit distance, keeping the leading run within one-third of the shorter length
	// (the filter stops at the first that fails).
	public static function getSimilar(s:String, sl:Array<String>):Array<String> {
		if (sl.length == 0) return [];
		var scored = [for (s2 in sl) {name: s2, d: levenshtein(s, s2)}];
		scored.sort(function(a, b) return a.d - b.d);
		var out:Array<String> = [];
		for (e in scored) {
			var limit = Std.int((s.length < e.name.length ? s.length : e.name.length) / 3);
			if (e.d <= limit) out.push(e.name) else break;
		}
		return out;
	}

	// The message with a "(Suggestion: X)" / "(Suggestions: X, Y)" tail when a close candidate exists, else
	// the message unchanged.
	public static function stringError(s:String, sl:Array<String>, msg:String):String {
		if (sl.length == 0) return msg;
		var cl = getSimilar(s, sl);
		return switch (cl.length) {
			case 0: msg;
			case 1: msg + " (Suggestion: " + cl[0] + ")";
			case _: msg + " (Suggestions: " + cl.join(", ") + ")";
		};
	}
}
