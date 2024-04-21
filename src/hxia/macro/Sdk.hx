package hxia.macro;

#if macro
import haxe.macro.Context;
import haxe.crypto.Sha256;
import hxia.macro.Registry;

using StringTools;

// Emits the host SDK from the @:scriptable surface the build macro recorded: one typed
// extern per exposed class (the exact API a mod may name, and nothing else) plus a stable
// surface hash stamped into hxia-sdk.hash. Run after typing:
//   --macro hxia.macro.Sdk.emit('out/dir')
// A mod compiled against the emitted externs sees the exposed surface only; the hash lets
// a host refuse mods built against a stale SDK.
class Sdk {
	public static function emit(outDir:String):Void {
		Context.onAfterTyping(function(_) {
			var classes = Registry.classes.copy();
			// Deterministic order: by dotted path
			classes.sort(function(a, b) {
				var pa = dotted(a.pack, a.name), pb = dotted(b.pack, b.name);
				return pa < pb ? -1 : (pa > pb ? 1 : 0);
			});
			if (!sys.FileSystem.exists(outDir))
				sys.FileSystem.createDirectory(outDir);

			var canon = new StringBuf();
			for (c in classes) {
				writeExtern(outDir, c);
				canon.add(canonical(c));
			}
			var hash = Sha256.encode(canon.toString());
			sys.io.File.saveContent(outDir + "/hxia-sdk.hash", hash + "\n");
		});
	}

	static function dotted(pack:Array<String>, name:String):String
		return pack.length == 0 ? name : pack.join(".") + "." + name;

	// The canonical surface text feeding the hash: stable field order, no positions.
	static function canonical(c:ClassSurface):String {
		var fields = c.fields.copy();
		fields.sort(function(a, b) return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
		var sb = new StringBuf();
		sb.add((c.isInterface ? "interface " : "class ") + dotted(c.pack, c.name) + "\n");
		for (f in fields)
			sb.add("  " + (f.atoms.length > 0 ? "@:requires(" + f.atoms.join(",") + ") " : "") + f.sig + "\n");
		return sb.toString();
	}

	static function writeExtern(outDir:String, c:ClassSurface):Void {
		var dir = outDir;
		for (p in c.pack) {
			dir += "/" + p;
			if (!sys.FileSystem.exists(dir))
				sys.FileSystem.createDirectory(dir);
		}
		var sb = new StringBuf();
		if (c.pack.length > 0)
			sb.add("package " + c.pack.join(".") + ";\n\n");
		sb.add((c.isInterface ? "extern interface " : "extern class ") + c.name + " {\n");
		for (f in c.fields) {
			if (f.atoms.length > 0)
				sb.add("\t@:requires(" + f.atoms.join(",") + ")\n");
			sb.add("\t" + f.sig + "\n");
		}
		sb.add("}\n");
		sys.io.File.saveContent(dir + "/" + c.name + ".hx", sb.toString());
	}
}
#end
