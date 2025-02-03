package hxia;

import hxia.cppia.ModuleIR;
import hxia.cppia.Decoder;
import hxia.cppia.OpTree;

// Load-time link check: every type a module actually REACHES OUT to - a static call, a
// static field, or a `new` - must be resolvable, either as one of the module's own decls or
// through the host surface. Unresolved names are collected and reported together, so one
// load names every missing type instead of failing at the first call long into a run.
//
// Deliberately driven by call SITES rather than the artifact's type table: the table also
// holds signature-only names (argument and return types, generic expansions) that never
// need to resolve at runtime, and failing a load over one of those would be wrong.
class Linker {
	public static function unresolvedTypes(ir:ModuleIR, tree:ModuleTree, known:String->Bool):Array<String> {
		var types = [for (b in ir.types) b.getString(0, b.length)];
		var declared = new Map<String, Bool>();
		for (d in tree.decls)
			declared.set(types[d.ints[0]], true);

		var missing:Array<String> = [];
		var seen = new Map<String, Bool>();
		function need(id:Int):Void {
			if (id < 0 || id >= types.length)
				return;
			var t = types[id];
			if (t == "" || declared.exists(t) || seen.exists(t))
				return;
			seen.set(t, true);
			if (!known(t))
				missing.push(t);
		}
		function walk(n:Null<OpNode>):Void {
			if (n == null)
				return;
			switch (n.op) {
				case "CALLSTATIC", "FSTATIC", "NEW", "CLASSOF": need(n.ints[0]);
				case _:
			}
			for (k in n.kids)
				walk(k);
		}
		for (d in tree.decls) {
			for (f in d.fields)
				walk(f.body);
			walk(d.enumMeta);
		}
		walk(tree.main);
		return missing;
	}
}
