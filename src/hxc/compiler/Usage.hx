package hxc.compiler;

/**
 * Argument rows supply usage, help and near-miss suggestions. Each view selects different rows,
 * which affects description-column padding.
 */
class Usage {
	static final ROWS:Array<{cat:String, names:Array<String>, deps:Array<String>, hint:String, doc:String, basic:Bool}> = [
		{cat: "Target", names: ["--js"], deps: ["-js"], hint: "<file>", doc: "generate JavaScript code into target file", basic: true},
		{cat: "Target", names: ["--lua"], deps: ["-lua"], hint: "<file>", doc: "generate Lua code into target file", basic: true},
		{cat: "Target", names: ["--swf"], deps: ["-swf"], hint: "<file>", doc: "generate Flash SWF bytecode into target file", basic: true},
		{cat: "Target", names: ["--neko"], deps: ["-neko"], hint: "<file>", doc: "generate Neko bytecode into target file", basic: true},
		{cat: "Target", names: ["--php"], deps: ["-php"], hint: "<directory>", doc: "generate PHP code into target directory", basic: true},
		{cat: "Target", names: ["--cpp"], deps: ["-cpp"], hint: "<directory>", doc: "generate C++ code into target directory", basic: true},
		{cat: "Target", names: ["--cppia"], deps: ["-cppia"], hint: "<file>", doc: "generate Cppia bytecode into target file", basic: true},
		{cat: "Target", names: ["--cs"], deps: ["-cs"], hint: "<directory>", doc: "generate C# code into target directory", basic: true},
		{cat: "Target", names: ["--java"], deps: ["-java"], hint: "<directory>", doc: "generate Java code into target directory", basic: true},
		{cat: "Target", names: ["--jvm"], deps: [], hint: "<file>", doc: "generate JVM bytecode into target file", basic: true},
		{cat: "Target", names: ["--python"], deps: ["-python"], hint: "<file>", doc: "generate Python code into target file", basic: true},
		{cat: "Target", names: ["--hl"], deps: ["-hl"], hint: "<file>", doc: "generate HashLink .hl bytecode or .c code into target file", basic: true},
		{cat: "Target", names: [], deps: ["-x"], hint: "<class>", doc: "interpret the program using internal macro system", basic: true},
		{cat: "Target", names: ["--interp"], deps: [], hint: "", doc: "interpret the program using internal macro system", basic: true},
		{cat: "Target", names: ["--run"], deps: [], hint: "<module> [args...]", doc: "interpret a Haxe module with command line arguments", basic: true},
		{cat: "Compilation", names: ["-p", "--class-path"], deps: ["-cp"], hint: "<path>", doc: "add a directory to find source files", basic: true},
		{cat: "Compilation", names: ["-m", "--main"], deps: ["-main"], hint: "<class>", doc: "select startup class", basic: true},
		{cat: "Compilation", names: ["-L", "--library"], deps: ["-lib"], hint: "<name[:ver]>", doc: "use a haxelib library", basic: true},
		{cat: "Compilation", names: ["-D", "--define"], deps: [], hint: "<var[=value]>", doc: "define a conditional compilation flag", basic: true},
		{cat: "Debug", names: ["-v", "--verbose"], deps: [], hint: "", doc: "turn on verbose mode", basic: true},
		{cat: "Debug", names: ["--debug"], deps: ["-debug"], hint: "", doc: "add debug information to the compiled code", basic: true},
		{cat: "Miscellaneous", names: ["--version"], deps: ["-version"], hint: "", doc: "print version and exit", basic: true},
		{cat: "Miscellaneous", names: ["-h", "--help"], deps: ["-help"], hint: "", doc: "show extended help information", basic: true},
		{cat: "Miscellaneous", names: ["--help-defines"], deps: [], hint: "", doc: "print help for all compiler specific defines", basic: true},
		{cat: "Miscellaneous", names: ["--help-user-defines"], deps: [], hint: "", doc: "print help for all user defines", basic: true},
		{cat: "Miscellaneous", names: ["--help-metas"], deps: [], hint: "", doc: "print help for all compiler metadatas", basic: true},
		{cat: "Miscellaneous", names: ["--help-user-metas"], deps: [], hint: "", doc: "print help for all user metadatas", basic: true},
		{cat: "Optimization", names: ["--dce"], deps: ["-dce"], hint: "[std|full|no]", doc: "set the dead code elimination mode (default std)", basic: false},
		{cat: "Target-specific", names: ["--swf-version"], deps: ["-swf-version"], hint: "<version>", doc: "change the SWF version", basic: false},
		{cat: "Target-specific", names: ["--swf-header"], deps: ["-swf-header"], hint: "<header>", doc: "define SWF header (width:height:fps:color)", basic: false},
		{cat: "Target-specific", names: ["--flash-strict"], deps: [], hint: "", doc: "more type strict flash API", basic: false},
		{cat: "Target-specific", names: ["--swf-lib"], deps: ["-swf-lib"], hint: "<file>", doc: "add the SWF library to the compiled SWF", basic: false},
		{cat: "Target-specific", names: [], deps: ["--neko-lib-path"], hint: "<directory>", doc: "add the neko library path", basic: false},
		{cat: "Target-specific", names: ["--swf-lib-extern"], deps: ["-swf-lib-extern"], hint: "<file>", doc: "use the SWF library for type checking", basic: false},
		{cat: "Target-specific", names: ["--java-lib"], deps: ["-java-lib"], hint: "<file>", doc: "add an external JAR or directory of JAR files", basic: false},
		{cat: "Target-specific", names: ["--java-lib-extern"], deps: [], hint: "<file>", doc: "use an external JAR or directory of JAR files for type checking", basic: false},
		{cat: "Target-specific", names: ["--net-lib"], deps: ["-net-lib"], hint: "<file>[@std]", doc: "add an external .NET DLL file", basic: false},
		{cat: "Target-specific", names: ["--net-std"], deps: ["-net-std"], hint: "<file>", doc: "add a root std .NET DLL search path", basic: false},
		{cat: "Target-specific", names: ["--c-arg"], deps: ["-c-arg"], hint: "<arg>", doc: "pass option <arg> to the native Java/C# compiler", basic: false},
		{cat: "Compilation", names: ["-r", "--resource"], deps: ["-resource"], hint: "<file>[@name]", doc: "add a named resource file", basic: false},
		{cat: "Debug", names: ["--prompt"], deps: ["-prompt"], hint: "", doc: "prompt on error", basic: false},
		{cat: "Compilation", names: ["--cmd"], deps: ["-cmd"], hint: "<command>", doc: "run the specified command after successful compilation", basic: false},
		{cat: "Optimization", names: ["--no-traces"], deps: [], hint: "", doc: "don't compile trace calls in the program", basic: false},
		{cat: "Batch", names: ["--next"], deps: [], hint: "", doc: "separate several haxe compilations", basic: false},
		{cat: "Batch", names: ["--each"], deps: [], hint: "", doc: "append preceding parameters to all Haxe compilations separated by --next", basic: false},
		{cat: "Services", names: ["--display"], deps: [], hint: "", doc: "display code tips", basic: false},
		{cat: "Services", names: ["--xml"], deps: ["-xml"], hint: "<file>", doc: "generate XML types description", basic: false},
		{cat: "Services", names: ["--json"], deps: [], hint: "<file>", doc: "generate JSON types description", basic: false},
		{cat: "Optimization", names: ["--no-output"], deps: [], hint: "", doc: "compiles but does not generate any file", basic: false},
		{cat: "Debug", names: ["--times"], deps: [], hint: "", doc: "measure compilation times", basic: false},
		{cat: "Optimization", names: ["--no-inline"], deps: [], hint: "", doc: "disable inlining", basic: false},
		{cat: "Optimization", names: ["--no-opt"], deps: [], hint: "", doc: "disable code optimizations", basic: false},
		{cat: "Compilation", names: ["--remap"], deps: [], hint: "<package:target>", doc: "remap a package to another one", basic: false},
		{cat: "Compilation", names: ["--macro"], deps: [], hint: "<macro>", doc: "call the given macro before typing anything else", basic: false},
		{cat: "Compilation Server", names: ["--server-listen"], deps: ["--wait"], hint: "[[host:]port]|stdio]", doc: "wait on the given port (or use standard i/o) for commands to run", basic: false},
		{cat: "Compilation Server", names: ["--server-connect"], deps: [], hint: "[host:]port]", doc: "connect to the given port and wait for commands to run", basic: false},
		{cat: "Compilation Server", names: ["--connect"], deps: [], hint: "<[host:]port>", doc: "connect on the given port and run commands there", basic: false},
		{cat: "Compilation", names: ["-C", "--cwd"], deps: [], hint: "<directory>", doc: "set current working directory", basic: false},
		{cat: "Compilation", names: ["--haxelib-global"], deps: [], hint: "", doc: "pass --global argument to haxelib", basic: false},
		{cat: "Compilation", names: ["-w"], deps: [], hint: "<warning list>", doc: "enable or disable specific warnings", basic: false},
	];

	// Print categories in this order; unknown categories fall under Miscellaneous.
	static final CATEGORIES = [
		"Target", "Compilation", "Optimization", "Debug", "Batch", "Services",
		"Compilation Server", "Target-specific", "Miscellaneous"
	];

	/**
	 * Usage screen containing basic arguments only.
	 */
	public static function text():String return render([for (r in ROWS) if (r.basic) r], true, true);

	/**
	 * Help screen containing every argument.
	 */
	public static function help():String return render(ROWS, true, true);

	/**
	 * Return near-miss options or null. Extract the option with [-A-Za-z]+, stopping at its first
	 * digit.
	 */
	public static function suggest(unknown:String):Null<String> {
		var cands:Array<String> = [];
		for (r in ROWS) for (n in r.names.concat(r.deps)) cands.push(n);
		// Sort by edit distance, then take only the prefix within one third of the shorter name's length.
		var scored = [for (c in cands) {name: c, d: levenshtein(unknown, c)}];
		// Preserve input order for equal distances so equally close suggestions stay deterministic.
		var idx = new Map<String, Int>();
		for (i in 0...scored.length) if (!idx.exists(scored[i].name)) idx.set(scored[i].name, i);
		scored.sort(function(a, b) return a.d != b.d ? a.d - b.d : idx.get(a.name) - idx.get(b.name));
		var similar:Array<String> = [];
		for (s in scored) {
			var lim = Std.int((unknown.length < s.name.length ? unknown.length : s.name.length) / 3);
			if (s.d > lim) break;
			similar.push(s.name);
		}
		if (similar.length == 0) return null;
		var rows = [for (r in ROWS) if (Lambda.exists(r.names.concat(r.deps), function(n) return similar.indexOf(n) >= 0)) r];
		if (rows.length == 0) return null;
		// Print the heading even when filtering unnamed rows leaves an empty result.
		return render(rows, false, false);
	}

	static function label(r:{names:Array<String>, hint:String}):String {
		// Include the separating space even with an empty hint; it contributes to padding width.
		return r.names.join(", ") + " " + r.hint;
	}

	static function render(rows:Array<{cat:String, names:Array<String>, deps:Array<String>, hint:String, doc:String, basic:Bool}>,
			header:Bool, printCat:Bool):String {
		var rows = [for (r in rows) if (r.names.length > 0) r];
		var maxLabel = 0;
		for (r in rows) {
			var n = label(r).length;
			if (n > maxLabel) maxLabel = n;
		}
		var buf = new StringBuf();
		if (header) {
			buf.add("Haxe Compiler " + hxc.core.Globals.sVersionFull + " - (C)2026 Dimensionscape\n");
			buf.add("Usage: haxe" + (Sys.systemName() == "Windows" ? ".exe" : "") + " <target> [options] [hxml files and dot paths...]\n");
		}
		for (cat in CATEGORIES) {
			var first = true;
			for (r in rows) {
				var c = CATEGORIES.indexOf(r.cat) < 0 ? "Miscellaneous" : r.cat;
				if (c != cat) continue;
				if (first) {
					if (printCat) buf.add("\n" + cat + ":\n");
					first = false;
				}
				var lb = label(r);
				buf.add("  " + lb + StringTools.rpad("", " ", maxLabel - lb.length) + "  " + r.doc + "\n");
			}
		}
		return buf.toString();
	}

	static function levenshtein(a:String, b:String):Int {
		var m = a.length, n = b.length;
		if (m == 0) return n;
		if (n == 0) return m;
		var prev = [for (j in 0...n + 1) j];
		for (i in 1...m + 1) {
			var cur = [for (j in 0...n + 1) 0];
			cur[0] = i;
			for (j in 1...n + 1) {
				var cost = a.charCodeAt(i - 1) == b.charCodeAt(j - 1) ? 0 : 1;
				var d = prev[j] + 1;
				var l = cur[j - 1] + 1;
				var dg = prev[j - 1] + cost;
				cur[j] = d < l ? (d < dg ? d : dg) : (l < dg ? l : dg);
			}
			prev = cur;
		}
		return prev[n];
	}
}
