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
		var printer = new haxe.macro.Printer();

		// DCE pin: a scriptable class is reachable only through the registry, so DCE must
		// not drop it or its public methods.
		if (!cls.meta.has(":keep"))
			cls.meta.add(":keep", [], cls.pos);

		var surface:hxia.macro.Registry.ClassSurface = {
			pack: cls.pack,
			name: cls.name,
			isInterface: cls.isInterface,
			fields: []
		};

		for (f in fields) {
			var atoms = [];
			for (m in f.meta) {
				if (m.name != ":requires")
					continue;
				var atom = atomArg(m);
				if (atom == null)
					Context.error("@:requires expects one capability atom, e.g. @:requires(fs.write)", m.pos);
				else if (!Atoms.isKnown(atom))
					Context.error("@:requires: unknown capability atom '" + atom + "' (known: " + Atoms.all().join(", ") + ")", m.pos);
				else
					atoms.push(atom);
			}
			// Keep public members reachable for the registry, and record them for the SDK
			if (isPublic(f) && !isCtor(f)) {
				if (!hasKeep(f))
					f.meta.push({name: ":keep", params: [], pos: f.pos});
				var sig = fieldSignature(printer, f);
				if (sig != null)
					surface.fields.push({name: f.name, sig: sig, atoms: atoms});
			}
		}
		Registry.add(surface);
		return fields;
	}

	// A method's extern signature line: `function name(args):Ret;`, or a var's `var name:T;`.
	static function fieldSignature(printer:haxe.macro.Printer, f:Field):Null<String> {
		return switch (f.kind) {
			case FFun(fn):
				var args = [for (a in fn.args) a.name + (a.opt ? ":" : ":") + printer.printComplexType(a.type)];
				var ret = fn.ret == null ? "Void" : printer.printComplexType(fn.ret);
				"function " + f.name + "(" + args.join(", ") + "):" + ret + ";";
			case FVar(t, _) if (t != null):
				"var " + f.name + ":" + printer.printComplexType(t) + ";";
			case FProp(get, set, t, _) if (t != null):
				"var " + f.name + "(" + get + ", " + set + "):" + printer.printComplexType(t) + ";";
			case _:
				null;
		};
	}

	static function isCtor(f:Field):Bool
		return f.name == "new";

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
