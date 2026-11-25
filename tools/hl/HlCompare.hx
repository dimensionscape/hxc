import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Compares the -D dump output of two HashLink compiles: dump/hlcode.txt table by table, then the functions
// (matched by their `; file:line (Class.method)` label, not their index, with table references resolved to
// what they refer to), then the typed AST in dump/hl/*.dump.
// Usage: haxe -cp tools/hl --run HlCompare [--all] <expected dir> <actual dir>   (each holds a dump/ directory)
// --all prints a line `differs: <label>` for every function whose body differs, before the first-difference block.
// Exits 1 when anything differs. "first" is the expected side (Haxe), "second" the actual one (hxc).
class HlCompare {
	static var tables = ["strings", "bytes", "ints", "floats", "globals", "natives"];
	static var differs = false;
	static var all = false;

	static function main() {
		var args = Sys.args();
		all = args.remove("--all");
		if (args.length != 2) {
			Sys.println("usage: HlCompare [--all] <expected dir> <actual dir>");
			Sys.exit(2);
		}
		var a = args[0], b = args[1];
		var fa = Path.join([a, "dump", "hlcode.txt"]), fb = Path.join([b, "dump", "hlcode.txt"]);
		if (!FileSystem.exists(fa) || !FileSystem.exists(fb)) {
			differs = true;
			Sys.println("no dump/hlcode.txt in " + (FileSystem.exists(fa) ? b : a));
		} else {
			compareCode(parse(File.getContent(fa)), parse(File.getContent(fb)));
		}
		compareAst(a, b);
		Sys.exit(differs ? 1 : 0);
	}

	// A dump split in sections: the lines before the first table (header) and each `N <name>` table's lines.
	static function parse(text:String):Dump {
		var d:Dump = {header: [], sections: new Map()};
		var cur = d.header;
		var re = ~/^(\d+) (strings|bytes|ints|floats|globals|natives|functions|objects protos|constant values)$/;
		for (line in text.split("\n")) {
			line = line.rtrim();
			if (re.match(line)) {
				cur = [];
				d.sections.set(re.matched(2), cur);
			} else if (line != "") cur.push(line);
		}
		return d;
	}

	static function compareCode(a:Dump, b:Dump) {
		var na = new Names(a), nb = new Names(b);
		if (a.header[0] != b.header[0]) report("header", 0, a.header[0], b.header[0]);
		if (na.entryLabel != nb.entryLabel) report("entry point", 0, na.entryLabel, nb.entryLabel);
		for (t in tables) {
			var la = a.sections.get(t), lb = b.sections.get(t);
			if (la == null || lb == null) {
				differs = true;
				Sys.println(t + ": missing from the " + (la == null ? "first" : "second"));
				continue;
			}
			var bad = firstDifference(la, lb);
			var same = 0;
			for (i in 0...Std.int(Math.min(la.length, lb.length))) if (la[i] == lb[i]) same++;
			if (bad < 0) Sys.println(t + ": " + la.length + " identical");
			else {
				Sys.println(t + ": " + same + "/" + la.length + " identical (" + lb.length + " in the second)");
				report(t, bad, la[bad], lb[bad]);
			}
		}
		var fa = na.functions, fb = nb.functions;
		var total = 0, same = 0;
		var firstBad:String = null;
		for (label in fa.keys()) {
			total++;
			var x = fa.get(label), y = fb.get(label);
			if (y != null && x.join("\n") == y.join("\n")) same++;
			else if (y != null) {
				if (firstBad == null) firstBad = label;
				if (all) Sys.println("differs: " + label);
			}
		}
		var missing = [for (k in fa.keys()) if (!fb.exists(k)) k];
		var extra = [for (k in fb.keys()) if (!fa.exists(k)) k];
		Sys.println("functions: " + same + "/" + total + " identical");
		if (same != total || extra.length > 0) differs = true;
		if (missing.length > 0) Sys.println("  only in the first (" + missing.length + "): " + missing.slice(0, 5).join(", ") + (missing.length > 5 ? ", ..." : ""));
		if (extra.length > 0) Sys.println("  only in the second (" + extra.length + "): " + extra.slice(0, 5).join(", ") + (extra.length > 5 ? ", ..." : ""));
		if (firstBad != null) {
			Sys.println("first differing function: " + firstBad);
			twoColumns(fa.get(firstBad), fb.get(firstBad));
		}
		for (t in ["objects protos", "constant values"]) {
			var la = na.resolveAll(a.sections.get(t)), lb = nb.resolveAll(b.sections.get(t));
			if (la == null || lb == null) {
				differs = true;
				Sys.println(t + ": missing from the " + (la == null ? "first" : "second"));
				continue;
			}
			var bad = firstDifference(la, lb);
			if (bad < 0) Sys.println(t + ": " + la.length + " lines identical");
			else {
				Sys.println(t + ": differ");
				report(t, bad, la[bad], lb[bad]);
			}
		}
	}

	static function firstDifference(x:Array<String>, y:Array<String>):Int {
		for (i in 0...Std.int(Math.max(x.length, y.length))) if (x[i] != y[i]) return i;
		return -1;
	}

	static function report(what:String, idx:Int, x:String, y:String) {
		differs = true;
		Sys.println("  first difference in " + what + " at entry " + idx + ":");
		Sys.println("    first : " + (x == null ? "(none)" : x.trim()));
		Sys.println("    second: " + (y == null ? "(none)" : y.trim()));
	}

	// Lines of both functions side by side, from a few lines before the first difference; `#` marks lines that differ.
	static function twoColumns(x:Array<String>, y:Array<String>) {
		var n = Std.int(Math.max(x.length, y.length));
		var bad = firstDifference(x, y);
		var from = Std.int(Math.max(0, bad - 3)), to = Std.int(Math.min(n, bad + 12));
		var w = 0;
		for (i in from...to) if (x[i] != null && x[i].length > w) w = x[i].length;
		if (w > 70) w = 70;
		for (i in from...to) {
			var l = x[i] == null ? "" : x[i].replace("\t", "  ");
			var r = y[i] == null ? "" : y[i].replace("\t", "  ");
			Sys.println("  " + l.rpad(" ", w).substr(0, w) + (x[i] == y[i] ? " | " : " # ") + r);
		}
		if (x.length != y.length) Sys.println("  (" + x.length + " lines against " + y.length + ")");
	}

	static function compareAst(a:String, b:String) {
		var da = Path.join([a, "dump", "hl"]), db = Path.join([b, "dump", "hl"]);
		if (!FileSystem.exists(da) || !FileSystem.exists(db)) {
			differs = true;
			Sys.println("typed AST: no dump/hl in " + (FileSystem.exists(da) ? b : a));
			return;
		}
		var fa = FileSystem.readDirectory(da).filter(f -> f.endsWith(".dump"));
		var fb = FileSystem.readDirectory(db).filter(f -> f.endsWith(".dump"));
		fa.sort(Reflect.compare);
		var only1 = fa.filter(f -> fb.indexOf(f) < 0), only2 = fb.filter(f -> fa.indexOf(f) < 0);
		only2.sort(Reflect.compare);
		var same = 0, first:String = null;
		for (f in fa) {
			if (fb.indexOf(f) < 0) continue;
			if (File.getContent(Path.join([da, f])) == File.getContent(Path.join([db, f]))) same++;
			else if (first == null) first = f;
		}
		Sys.println("typed AST: " + same + "/" + fa.length + " types identical");
		if (only1.length > 0) {
			differs = true;
			Sys.println("  only in the first: " + only1.slice(0, 5).join(", "));
		}
		if (only2.length > 0) {
			differs = true;
			Sys.println("  only in the second: " + only2.slice(0, 5).join(", "));
		}
		if (first != null) {
			differs = true;
			var x = File.getContent(Path.join([da, first])).split("\n"), y = File.getContent(Path.join([db, first])).split("\n");
			var bad = firstDifference(x, y);
			Sys.println("  first differing type: " + first.substr(0, first.length - 5) + ", line " + (bad + 1)
				+ " (a difference here is a typer or filter bug, not the generator's):");
			Sys.println("    first : " + (x[bad] == null ? "(none)" : x[bad].trim()));
			Sys.println("    second: " + (y[bad] == null ? "(none)" : y[bad].trim()));
		}
	}
}

typedef Dump = {
	var header:Array<String>;
	var sections:Map<String, Array<String>>;
}

// A dump's functions by label, with every table reference resolved to what it refers to.
class Names {
	public var functions = new Map<String, Array<String>>();
	public var entryLabel = "";
	var d:Dump;
	var names = new Map<String, String>(); // function index -> name, natives and functions
	var strings:Array<String>;
	var ints:Array<String>;
	var floats:Array<String>;
	var bytes:Array<String>;
	var globals:Array<String>;

	public function new(d:Dump) {
		this.d = d;
		strings = values("strings");
		ints = values("ints");
		floats = values("floats");
		bytes = values("bytes");
		globals = values("globals");
		var nat = ~/^\t@(\d+) native (\S+)/;
		for (l in sect("natives")) if (nat.match(l)) names.set(nat.matched(1), nat.matched(2));
		// a function's label is its `; file:line (Name)` line; a repeated label gets a count
		var lines = sect("functions");
		var hdr = ~/^\tfun@(\d+)\(/;
		var lab = ~/^\t; (.*) \(([^)]*)\)$/;
		var starts:Array<{idx:String, at:Int, label:String}> = [];
		var seen = new Map<String, Int>();
		for (i in 0...lines.length) {
			if (!hdr.match(lines[i])) continue;
			var idx = hdr.matched(1);
			var label = "fun$" + idx;
			if (i + 1 < lines.length && lab.match(lines[i + 1])) {
				names.set(idx, normName(lab.matched(2)));
				label = lab.matched(1) + " (" + normName(lab.matched(2)) + ")";
			} else names.set(idx, "fun$#");
			var n = seen.exists(label) ? seen.get(label) + 1 : 1;
			seen.set(label, n);
			starts.push({idx: idx, at: i, label: n > 1 ? label + " #" + n : label});
		}
		for (h in d.header) if (h.startsWith("entry @")) {
			for (s in starts) if (s.idx == h.substr(7)) entryLabel = s.label;
		}
		for (k in 0...starts.length) {
			var to = k + 1 < starts.length ? starts[k + 1].at : lines.length;
			var body = [];
			for (i in starts[k].at...to) body.push(i == starts[k].at ? ~/^\tfun@\d+\(\w+h\)/.replace(lines[i], "\tfun") : resolve(lines[i]));
			functions.set(starts[k].label, body);
		}
	}

	// `fun$123` is a function without a name: the number is only an index.
	static function normName(s:String):String {
		return ~/fun\$\d+/g.replace(s, "fun$#");
	}

	function sect(n:String):Array<String> {
		var s = d.sections.get(n);
		return s == null ? [] : s;
	}

	function values(n:String):Array<String> {
		var out = [];
		var r = ~/^\t@(\d+) : (.*)$/;
		for (l in sect(n)) if (r.match(l)) out[Std.parseInt(r.matched(1))] = r.matched(2);
		return out;
	}

	public function resolveAll(lines:Array<String>):Array<String> {
		return lines == null ? null : [for (l in lines) resolve(l)];
	}

	function resolve(l:String):String {
		var r = ~/^(.* )(int|float|string|bytes) (\d+),@(\d+)$/;
		if (r.match(l)) {
			var i = Std.parseInt(r.matched(4));
			var v = switch r.matched(2) {
				case "int": ints[i];
				case "float": floats[i];
				case "string": "\"" + strings[i] + "\"";
				default: "bytes[" + bytes[i] + "]";
			}
			return r.matched(1) + r.matched(2) + " " + r.matched(3) + "," + v;
		}
		r = ~/^(.* )global (\d+), (\d+)$/;
		if (r.match(l)) return r.matched(1) + "global " + r.matched(2) + ", " + globals[Std.parseInt(r.matched(3))];
		r = ~/^(.* )setglobal (\d+), (\d+)$/;
		if (r.match(l)) return r.matched(1) + "setglobal " + globals[Std.parseInt(r.matched(2))] + ", " + r.matched(3);
		r = ~/^(.* )(dynget|dynset) (.*)\[@(\d+)\](.*)$/;
		if (r.match(l)) return r.matched(1) + r.matched(2) + " " + r.matched(3) + "[\"" + strings[Std.parseInt(r.matched(4))] + "\"]" + r.matched(5);
		// protos and bindings: `fun@N` is a function index; a proto's class global and a constant's global are
		// indexes too, and the type after them says what they are
		r = ~/^(\t\S+) @\d+$/;
		if (r.match(l)) l = r.matched(1) + " @global";
		r = ~/^(    )@\d+ (.*)$/;
		if (r.match(l)) l = r.matched(1) + "@global " + r.matched(2);
		return normName(~/fun@(\d+)/g.map(l, e -> {
			var n = names.get(e.matched(1));
			"fun@" + (n == null ? e.matched(1) : n);
		}));
	}
}
