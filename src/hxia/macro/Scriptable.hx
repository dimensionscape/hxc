package hxia.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

// The @:scriptable build macro. It DCE-pins the exposed class (@:keep), validates every
// @:requires(atom) on its methods against the single-source atom vocabulary (hxia.macro
// .Atoms), and records the exposed surface (name + methods + required atoms) so the SDK
// extractor and the runtime registry can consume it.
//
// Applied via @:build(hxia.macro.Scriptable.build()); the bare @:scriptable spelling in
// the manual is sugar for this, for an init macro to add.
class Scriptable {
	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var cls = Context.getLocalClass().get();

		// DCE pin: a scriptable class is reachable only through the registry, so DCE must
		// not drop it or its public methods.
		if (!cls.meta.has(":keep"))
			cls.meta.add(":keep", [], cls.pos);

		for (f in fields) {
			for (m in f.meta) {
				if (m.name != ":requires")
					continue;
				var atom = atomArg(m);
				if (atom == null)
					Context.error("@:requires expects one capability atom, e.g. @:requires(fs.write)", m.pos);
				else if (!Atoms.isKnown(atom))
					Context.error("@:requires: unknown capability atom '" + atom + "' (known: " + Atoms.all().join(", ") + ")", m.pos);
			}
			// Keep public members reachable for the registry
			if (isPublic(f) && !hasKeep(f))
				f.meta.push({name: ":keep", params: [], pos: f.pos});
		}
		return fields;
	}

	// @:requires(fs.write) -> "fs.write"; accepts an identifier-path or a string.
	static function atomArg(m:MetadataEntry):Null<String> {
		return switch (m.params) {
			case [{expr: EConst(CString(s))}]: s;
			case [e]: dottedPath(e);
			case _: null;
		};
	}

	static function dottedPath(e:Expr):Null<String> {
		return switch (e.expr) {
			case EConst(CIdent(s)): s;
			case EField(sub, f):
				var p = dottedPath(sub);
				p == null ? null : p + "." + f;
			case _: null;
		};
	}

	static function isPublic(f:Field):Bool {
		for (a in f.access)
			if (a == APublic)
				return true;
		return false;
	}

	static function hasKeep(f:Field):Bool {
		for (m in f.meta)
			if (m.name == ":keep")
				return true;
		return false;
	}
}
#end
