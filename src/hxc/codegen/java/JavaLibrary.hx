package hxc.codegen.java;

import haxe.zip.Entry;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals.Path;
import hxc.codegen.java.JClassReader.JClassReader as CR;
import hxc.codegen.java.JavaConverter;

// a jar indexed by module path, whose classes are read and converted only when a module is actually asked
// for.
class JavaLibrary {
	public var filePath(default, null):String;
	public var isStd(default, null):Bool;
	// an extern lib is only read, never copied next to the jar
	public var isExtern:Bool = false;

	var entries:Null<List<Entry>> = null;
	var modules:Map<String, Array<{filename:String, entry:Entry}>> = new Map();
	var cachedFiles:Array<Path> = [];
	var loaded = false;

	public function new(filePath:String, isStd:Bool) {
		this.filePath = filePath;
		this.isStd = isStd;
	}

	function zip():List<Entry> {
		if (entries == null) {
			var input = sys.io.File.read(filePath, true);
			entries = haxe.zip.Reader.readZip(input);
			input.close();
		}
		return entries;
	}

	public function load():Void {
		if (loaded) return;
		loaded = true;
		for (entry in zip()) {
			var filename = entry.fileName;
			if (!StringTools.endsWith(filename, ".class")) continue;
			var pack = filename.split("/");
			if (pack.length == 0) continue;
			var name = pack.pop();
			name = name.substr(0, name.length - 6); // .class
			var hx = PathConverter.jpathToHx(new Path(pack, name));
			var path = PathConverter.jpathToPath(hx.pack, hx.name);
			var mname = if (hx.name.mname == null) {
				cachedFiles.push(path);
				hx.name.name;
			} else hx.name.mname;
			var key = moduleKey(hx.pack, mname);
			var l = modules.get(key);
			if (l == null) { l = []; modules.set(key, l); }
			l.unshift({filename: filename, entry: entry});
		}
	}

	static inline function moduleKey(pack:Array<String>, name:String):String {
		return pack.join(".") + "|" + name;
	}

	public function listModules():Array<Path> {
		return cachedFiles;
	}

	// java.lang.String is not built: it is haxe's own String.
	public function build(path:Path, p:Position):Null<Array<TypeDecl>> {
		if (path.name == "String" && path.pack.length == 2 && path.pack[0] == "java" && path.pack[1] == "lang")
			return null;
		var found = modules.get(moduleKey(path.pack, path.name));
		if (found == null || found.length == 0) return null;
		var jcs = [
			for (e in found) {
				jc: CR.parseClass(new haxe.io.BytesInput(haxe.zip.Reader.unzip(e.entry))),
				file: filePath + "@" + e.filename
			}
		];
		return Converter.convertModule(path.pack, jcs).decls;
	}
}
