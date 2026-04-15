package hxc.debug;

// Reflectively count objects reachable from a root, grouped by class. Keep this outside hxc.core,
// where Type resolves to the compiler's Type module and reflective calls can crash. Removing roots
// and collecting is unreliable because conservative stack scanning can retain dead local slots.
// Gc.trace returns zero without HXCPP_DEBUG; Gc.compact measures fragmentation rather than heap
// composition. Debug only: the identity set roughly doubles peak memory. Use a medium workload.
class HeapCensus {
	static var visited:haxe.ds.ObjectMap<Dynamic, Bool>;
	static var counts:haxe.ds.StringMap<Int>;
	static var bytes:haxe.ds.StringMap<Float>;
	static var stack:Array<Dynamic>;

	static inline function tally(k:String, b:Float):Void {
		var c = counts.get(k);
		counts.set(k, c == null ? 1 : c + 1);
		var t = bytes.get(k);
		bytes.set(k, (t == null ? 0.0 : t) + b);
	}

	static function push(v:Dynamic):Void {
		if (v == null) return;
		switch (Type.typeof(v)) {
			// Closures are objects too and hxc retains a lot of them (every lazy field type is
			// one). They cannot be descended into - captured variables are not reflectable - but
			// counting them is what says whether the unwalked remainder is closures or not.
			case TFunction:
				if (visited.exists(v)) return;
				visited.set(v, true);
				tally("<closure>", 32);
			case TObject | TClass(_) | TEnum(_):
				if (visited.exists(v)) return;
				visited.set(v, true);
				stack.push(v);
			case _:
		}
	}

	// Hxcpp: object header plus one machine word per field.
	static inline function objBytes(nfields:Int):Float {
		return 16 + nfields * 8;
	}

	// HXC_DBG_STATICCENSUS: what every static field of the classes that declare one keeps
	// reachable, one walk per field (so overlapping roots count twice), for finding what a
	// long-lived server keeps from one request to the next.
	static final staticClasses:Array<String> = [
		"hxc.Compiler",
		"hxc.ast.Position",
		"hxc.compiler.Diagnostics",
		"hxc.compiler.ServerMessage",
		"hxc.compiler.ToplevelScan",
		"hxc.context.Context",
		"hxc.context.ContextError",
		"hxc.context.DisplayJson",
		"hxc.context.MetaRegistry",
		"hxc.context.ModuleLoader",
		"hxc.context.Retyper",
		"hxc.context.ServerCache",
		"hxc.core.Genjson",
		"hxc.core.Globals",
		"hxc.core.JsonRpc",
		"hxc.core.NotFound",
		"hxc.core.PathKey",
		"hxc.core.PerfCount",
		"hxc.core.StringHelper",
		"hxc.core.TPrinting",
		"hxc.core.Timer",
		"hxc.core.TypeFunctions",
		"hxc.core.TypeUnification",
		"hxc.core.UnifyError",
		"hxc.core.WarningList",
		"hxc.core.WithTypeTools",
		"hxc.debug.DebugDump",
		"hxc.eval.EvalContext",
		"hxc.eval.EvalEmitter",
		"hxc.eval.EvalHash",
		"hxc.eval.EvalMacro",
		"hxc.eval.EvalNativeArity",
		"hxc.eval.EvalStdLib",
		"hxc.filters.DeprecationCheck",
		"hxc.filters.Filters",
		"hxc.filters.FiltersCommon",
		"hxc.filters.SafetyScope",
		"hxc.generators.GenJS",
		"hxc.generators.JsSourceMap",
		"hxc.generators.cpp.CppGenClass",
		"hxc.generators.cpp.CppScriptable",
		"hxc.generators.cpp.CppiaGen",
		"hxc.hxia.CapabilityMask",
		"hxc.optimization.ConstPropagation",
		"hxc.optimization.CopyPropagation",
		"hxc.optimization.Dce",
		"hxc.optimization.Graph",
		"hxc.optimization.PurityInference",
		"hxc.parser.Lexer",
		"hxc.parser.Parser",
		"hxc.typing.Calls",
		"hxc.typing.CoreApi",
		"hxc.typing.ExprPreprocessing",
		"hxc.typing.Fields",
		"hxc.typing.Inline",
		"hxc.typing.PatternMaker",
		"hxc.typing.TexprConverter",
		"hxc.typing.TypeFields",
		"hxc.typing.TypeResolve",
		"hxc.typing.Typeload",
		"hxc.typing.Typer"
	];

	public static function staticCensus(label:String, maxObjects:Int):Void {
		// Written to a file: under the compilation server stderr is the response channel.
		var out = sys.io.File.append(Sys.getEnv("HXC_DBG_STATICCENSUS_FILE"), false);
		out.writeString("[statics " + label + "]\n");
		for (cn in staticClasses) {
			var c = Type.resolveClass(cn);
			if (c == null) { out.writeString("  ? " + cn + "\n"); continue; }
			for (f in Type.getClassFields(c)) {
				var v:Dynamic = null;
				try v = Reflect.field(c, f) catch (_:Dynamic) continue;
				if (v == null || Reflect.isFunction(v)) continue;
				switch (Type.typeof(v)) {
					case TObject | TClass(_) | TEnum(_):
					case _: continue;
				}
				var r = run(v, cn + "." + f, maxObjects, true);
				if (r.n > 1000) out.writeString("  " + StringTools.lpad(Std.string(r.n), " ", 9) + " objs "
					+ StringTools.lpad(Std.string(Std.int(r.b / 1048576)), " ", 6) + "MB  " + cn + "." + f + "\n");
			}
		}
		out.close();
	}

	public static function run(root:Dynamic, label:String, maxObjects:Int, quiet:Bool = false):{n:Int, b:Float} {
		visited = new haxe.ds.ObjectMap();
		counts = new haxe.ds.StringMap();
		bytes = new haxe.ds.StringMap();
		stack = [];
		var trace_ = Sys.getEnv("HXC_DBG_HEAPCENSUS_TRACE") != null;
		var t0 = haxe.Timer.stamp();
		push(root);
		var n = 0;
		while (stack.length > 0 && n < maxObjects) {
			var o = stack.pop();
			n++;
			if (Std.isOfType(o, String)) {
				var s:String = cast o;
				tally("String", 16 + s.length * 2);
				continue;
			}
			if (Std.isOfType(o, Array)) {
				var a:Array<Dynamic> = cast o;
				tally("Array", 32 + a.length * 8);
				for (v in a) push(v);
				continue;
			}
			// Type.typeof is the only SAFE discriminator: Type.getEnum applied to a plain
			// anonymous structure segfaults rather than returning null, so the kind has to be
			// established before any kind-specific reflection runs.
			var cl:Class<Dynamic> = null;
			switch (Type.typeof(o)) {
				case TEnum(en):
					var ps = Type.enumParameters(o);
					tally("enum " + Type.getEnumName(en), objBytes(ps.length + 1));
					for (p in ps) push(p);
					continue;
				case TClass(c):
					cl = c;
				case _:
					var nf = 0;
					for (f in Reflect.fields(o)) {
						nf++;
						push(Reflect.field(o, f));
					}
					tally("{anon}", objBytes(nf));
					continue;
			}
			var name = Type.getClassName(cl);
			if (trace_) { var e = Sys.stderr(); e.writeString("  #" + n + " " + name + "
"); e.flush(); }
			// Each map kind is handled through its own typed iterator. Casting to the abstract
			// Map<Dynamic,Dynamic> and calling get(key) hands an IntMap a boxed key and segfaults; iterating
			// values never performs a lookup.
			switch (name) {
				case "haxe.ds.StringMap":
					var m:haxe.ds.StringMap<Dynamic> = cast o;
					var k = 0;
					for (key in m.keys()) push(key);
					for (v in m) {
						k++;
						push(v);
					}
					tally(name, 48 + k * 48);
					continue;
				case "haxe.ds.IntMap":
					var m:haxe.ds.IntMap<Dynamic> = cast o;
					var k = 0;
					for (v in m) {
						k++;
						push(v);
					}
					tally(name, 48 + k * 32);
					continue;
				case "haxe.ds.ObjectMap":
					var m:haxe.ds.ObjectMap<Dynamic, Dynamic> = cast o;
					var k = 0;
					for (key in m.keys()) push(key);
					for (v in m) {
						k++;
						push(v);
					}
					tally(name, 48 + k * 48);
					continue;
				case _:
			}
			if (!(StringTools.startsWith(name, "hxc.") || StringTools.startsWith(name, "haxe."))) {
				tally("<opaque> " + name, 32);
				continue;
			}
			// Reflect.fields lists the fields the instance actually STORES. Type.getInstanceFields
			// would also name properties, and reading one runs its getter, which segfaults rather
			// than throwing when it dereferences an uninitialised field.
			var nf = 0;
			for (f in Reflect.fields(o)) {
				var v:Dynamic = null;
				try v = Reflect.field(o, f) catch (_:Dynamic) continue;
				if (Reflect.isFunction(v)) {
					push(v);
					continue;
				}
				nf++;
				push(v);
			}
			tally(name, objBytes(nf));
		}
		var rows = [for (k in counts.keys()) {n: k, c: counts.get(k), b: bytes.get(k)}];
		rows.sort(function(a, b) return a.b < b.b ? 1 : -1);
		var out = Sys.stderr();
		var tot = 0.0;
		for (r in rows) tot += r.b;
		if (quiet) {
			visited = null;
			counts = null;
			bytes = null;
			stack = null;
			return {n: n, b: tot};
		}
		out.writeString("[census " + label + "] objects=" + n + " accounted=" + Std.int(tot / 1048576) + "MB"
			+ (stack.length > 0 ? " TRUNCATED(budget)" : "") + " in " + Std.int(haxe.Timer.stamp() - t0) + "s\n");
		var shown = 0;
		for (r in rows) {
			if (shown++ >= 26) break;
			out.writeString("  " + StringTools.lpad(Std.string(Std.int(r.b / 1048576)), " ", 6) + "MB "
				+ StringTools.lpad(Std.string(r.c), " ", 10) + "x  " + r.n + "\n");
		}
		out.flush();
		visited = null;
		counts = null;
		bytes = null;
		stack = null;
		return {n: n, b: tot};
	}
}
