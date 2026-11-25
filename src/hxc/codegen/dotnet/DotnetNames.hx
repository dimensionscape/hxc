package hxc.codegen.dotnet;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.IlData;

// The CLR names Haxe types and members get, as gencs gives them (change_ns_params, change_class_field).

class DotnetNames {
	// Set by GenerateDotnet from -D no-root.
	public static var noRoot = false;

	// A top-level type has no namespace; with -D no-root, top-level non-extern types, Std and Math go
	// to haxe.root. @:native replaces the path, and a generic class's name ends in `N (an enum's type
	// parameters are erased).
	public static function typePath(mt:ModuleType):IlPath {
		var infos = TypeFunctions.tInfos(mt);
		var ns = infos.path.pack.copy();
		var name = infos.path.name;
		var native = nativeName(infos.meta);
		if (native != null) {
			var parts = native.split(".");
			name = parts.pop();
			ns = parts;
		}
		if (noRoot && ns.length == 0) {
			var isExtern = switch (mt) {
				case TClassDecl(c): TypeFunctions.hasClassFlag(c, CExtern);
				case TEnumDecl(e): e.isExtern;
				case _: true;
			}
			if (!isExtern || name == "Std" || name == "Math") ns = ["haxe", "root"];
		}
		if (infos.params.length > 0 && !mt.match(TEnumDecl(_))) name += "`" + infos.params.length;
		return {ns: ns, nested: [], name: name};
	}

	// A member named like its class becomes Name_Name, repeated while that collides.
	public static function fieldName(c:TClass, name:String):String {
		if (name != c.path.name) return name;
		var n = name + "_" + name;
		while (c.fields.exists(n) || c.statics.exists(n)) n = n + "_" + n;
		return n;
	}

	public static function nativeName(meta:hxc.ast.Ast.Metadata):Null<String> {
		for (m in meta)
			if (m.name == ":native" && m.params.length == 1) switch (m.params[0].expr) {
				case EConst(CString(s, _)): return s;
				case _:
			}
		return null;
	}
}
