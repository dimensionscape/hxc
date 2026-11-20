package hxc.codegen.dotnet;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
	Embeds every .dll under netlib/, beside Netlib.hx, into Netlib: a static `paths` array of their paths
	relative to netlib/, sorted ignoring case, and a static `packed(path)` that returns a file's bytes,
	zlib-compressed and Base64-encoded, or null. Each file is a run of short string literals joined at
	run time, as RuntimeSourcesBuild embeds its files: a C++ compiler takes a long run of literals in its
	stride, where a resource's byte array of a megabyte or more can exhaust its heap. When hxc is built
	for .NET (`cs`), each compressed file is a resource `hxc-netlib/<path>` instead, and there is no
	`packed`. Uses only the macro
	and sys APIs that both Haxe and hxc's own macro interpreter provide, so it runs when hxc builds itself.
**/
class NetlibBuild {
	static inline final PIECE = 4000;
	// the resource name of an embedded file on .NET, before its path under netlib/ (Netlib spells it out too)
	static inline final RESOURCE_PREFIX = "hxc-netlib/";

	public static function build():Array<Field> {
		var pos = Context.currentPos();
		var here = haxe.io.Path.directory(sys.FileSystem.fullPath(Context.getPosInfos(pos).file));
		var root = haxe.io.Path.normalize(here + "/netlib");
		var paths:Array<String> = [];
		function walk(rel:String):Void {
			var names = sys.FileSystem.readDirectory(rel == "" ? root : root + "/" + rel);
			// ignoring case, as Windows lists a directory: mscorlib.dll before System.dll, the order the std
			// libraries are registered in when they come from hxcs's own netlib
			names.sort((a, b) -> {
				var x = a.toLowerCase(), y = b.toLowerCase();
				x < y ? -1 : x > y ? 1 : 0;
			});
			for (name in names) {
				var r = rel == "" ? name : rel + "/" + name;
				if (sys.FileSystem.isDirectory(root + "/" + r)) walk(r) else if (StringTools.endsWith(name.toLowerCase(), ".dll")) paths.push(r);
			}
		}
		walk("");
		var fields = Context.getBuildFields();
		fields.push({
			name: "paths",
			access: [AStatic, AFinal],
			kind: FVar(macro :Array<String>, macro $v{paths}),
			pos: pos
		});
		// On .NET a string literal is stored as UTF-16, twice the Base64; a manifest resource holds the
		// compressed bytes as they are, and no C++ compiler reads it.
		if (Context.defined("cs")) {
			for (p in paths) Context.addResource(RESOURCE_PREFIX + p, haxe.zip.Compress.run(sys.io.File.getBytes(root + "/" + p), 9));
			return fields;
		}
		var cases:Array<Case> = [];
		for (p in paths) {
			var text = haxe.crypto.Base64.encode(haxe.zip.Compress.run(sys.io.File.getBytes(root + "/" + p), 9));
			var pieces:Array<Expr> = [];
			var i = 0;
			while (i < text.length) {
				pieces.push(macro $v{text.substr(i, PIECE)});
				i += PIECE;
			}
			cases.push({values: [macro $v{p}], expr: macro $a{pieces}.join("")});
		}
		var lookup:Expr = {expr: ESwitch(macro path, cases, macro null), pos: pos};
		fields.push({
			name: "packed",
			access: [AStatic],
			kind: FFun({args: [{name: "path", type: macro :String}], ret: macro :Null<String>, expr: macro return $lookup}),
			pos: pos
		});
		return fields;
	}
}
#end
