package hxc.codegen.dotnet;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
	Embeds every .hx file under runtime/, beside RuntimeSources.hx, into RuntimeSources: a static
	`paths` array of their paths relative to runtime/, sorted, and a static `embedded(path)` that
	returns a file's content or null. Line endings become \n, so the content does not depend on how
	the source was checked out. Each file is a run of short string literals joined at run time, as a
	C++ compiler limits the length of one literal. Uses only the macro and sys APIs that both Haxe and
	hxc's own macro interpreter provide, so it runs when hxc builds itself.
**/
class RuntimeSourcesBuild {
	static inline final PIECE = 4000;

	public static function build():Array<Field> {
		var pos = Context.currentPos();
		var here = haxe.io.Path.directory(sys.FileSystem.fullPath(Context.getPosInfos(pos).file));
		var root = haxe.io.Path.normalize(here + "/runtime");
		var paths:Array<String> = [];
		function walk(rel:String):Void {
			var names = sys.FileSystem.readDirectory(rel == "" ? root : root + "/" + rel);
			names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			for (name in names) {
				var r = rel == "" ? name : rel + "/" + name;
				if (sys.FileSystem.isDirectory(root + "/" + r)) walk(r) else if (StringTools.endsWith(name, ".hx")) paths.push(r);
			}
		}
		walk("");
		var cases:Array<Case> = [];
		for (p in paths) {
			var content = StringTools.replace(sys.io.File.getContent(root + "/" + p), "\r\n", "\n");
			var pieces:Array<Expr> = [];
			var i = 0;
			while (i < content.length) {
				pieces.push(macro $v{content.substr(i, PIECE)});
				i += PIECE;
			}
			cases.push({values: [macro $v{p}], expr: macro $a{pieces}.join("")});
		}
		var lookup:Expr = {expr: ESwitch(macro path, cases, macro null), pos: pos};
		var fields = Context.getBuildFields();
		fields.push({
			name: "paths",
			access: [AStatic, AFinal],
			kind: FVar(macro :Array<String>, macro $v{paths}),
			pos: pos
		});
		fields.push({
			name: "embedded",
			access: [AStatic],
			kind: FFun({args: [{name: "path", type: macro :String}], ret: macro :Null<String>, expr: macro return $lookup}),
			pos: pos
		});
		return fields;
	}
}
#end
