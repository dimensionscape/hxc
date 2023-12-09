package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.StringError;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.context.ModuleLoader;

// An `import M.X` that names neither a subtype, a module-level static, nor a static of the module's main
// type is an error, suggesting the closest existing name.
class ImportCheck {
	public static function run(ctx:Context):Void {
		for (m in ctx.modules) {
			var imports = ctx.moduleImports.get(Context.pathKey(m.path));
			if (imports == null) continue;
			for (imp in imports.rawImports) checkImport(ctx, imp);
		}
	}

	static function isUpper(s:String):Bool {
		var c = s.charCodeAt(0);
		return c >= "A".code && c <= "Z".code;
	}

	static function checkImport(ctx:Context, imp:Import):Void {
		// Only a normal / aliased import addresses a specific member (a wildcard cannot be wrong).
		switch (imp.mode) { case IAll: return; case _: }
		if (imp.pos == null) return;
		var parts = imp.path;
		// Pack = leading lowercase segments; the first uppercase segment is the module name.
		var mi = -1;
		for (i in 0...parts.length) if (isUpper(parts[i].name)) { mi = i; break; }
		if (mi < 0) return;
		var pack = [for (i in 0...mi) parts[i].name];
		var moduleName = parts[mi].name;
		// Exactly one trailing segment after the module name is validated here (`import M.X`); a plain
		// module import or a deeper path is left alone.
		if (parts.length - mi != 2) return;
		var x = parts[mi + 1].name;

		var md = try ModuleLoader.loadModule(ctx, {pack: pack, name: moduleName}, imp.pos) catch (_:Dynamic) return;
		if (md == null) return;
		// The module may have been loaded but not resolved (an enum's constructors, for one, are
		// filled at resolution); resolving is idempotent.
		try hxc.typing.TypeResolve.resolveModule(ctx, md) catch (_:Dynamic) {}
		// A subtype of the module (private types count: they exist, so the import is not "missing"; a
		// private-access error is a separate check). / chk_private.
		if (hasTypeNamed(md, x)) return;
		// A module-level static.
		if (md.statics != null && md.statics.statics.exists(x)) return;

		var main = ModuleLoader.findTypeInModuleOpt(md, moduleName);
		if (main != null) {
			switch (main) {
				case TClassDecl(c):
					if (c.statics.exists(x)) return;
					fail(ctx, imp.pos, x, statNames(c), "Class<" + Context.sTypePath(c.path) + "> has no field " + x);
					return;
				case TAbstractDecl(a) if (a.impl != null):
					if (a.impl.statics.exists(x)) return;
					fail(ctx, imp.pos, x, statNames(a.impl), "Abstract<" + Context.sTypePath(md.path) + "> has no field " + x);
					return;
				case TEnumDecl(e):
					if (e.constrs.exists(x)) return;
					fail(ctx, imp.pos, x, [for (k in e.constrs.keys()) k], "Enum<" + Context.sTypePath(md.path) + "> has no field " + x);
					return;
				case _:
			}
		}
		// No main type addresses this name: the module simply does not define it. A lowercase name is
		// a field (candidates are the module-level statics), an uppercase one a type.
		if (isUpper(x)) {
			fail(ctx, imp.pos, x, [for (mt in md.types) TypeFunctions.tInfos(mt).path.name], "Module " + Context.sTypePath(md.path) + " does not define type " + x);
		} else {
			var cands = md.statics != null ? statNames(md.statics) : [];
			fail(ctx, imp.pos, x, cands, "Module " + Context.sTypePath(md.path) + " does not define field " + x);
		}
	}

	// Whether the module declares this type, including private declarations.
	static function hasTypeNamed(md:ModuleDef, name:String):Bool {
		for (mt in md.types) if (TypeFunctions.tInfos(mt).path.name == name) return true;
		return false;
	}

	static function statNames(c:TClass):Array<String> {
		return [for (k in c.statics.keys()) k];
	}

	static function fail(ctx:Context, p:Position, name:String, candidates:Array<String>, msg:String):Void {
		ctx.addDiagnostic(StringError.stringError(name, candidates, msg), p);
	}
}
