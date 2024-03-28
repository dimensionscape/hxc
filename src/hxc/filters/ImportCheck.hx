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
	public static function run(ctx:Context):Bool {
		var fatal = false;
		for (m in ctx.modules) {
			var imports = ctx.moduleImports.get(Context.pathKey(m.path));
			if (imports == null) continue;
			for (imp in imports.rawImports) if (checkImport(ctx, m, imp)) fatal = true;
		}
		return fatal;
	}

	// A PLAIN module import loads eagerly (after build macros are ready) so declaration errors in the
	// imported module surface even when nothing uses it. .
	static var plainImportsTried:haxe.ds.StringMap<Bool> = new haxe.ds.StringMap();

	public static function loadPlainImports(ctx:Context):Void {
		var i = 0;
		while (i < ctx.modules.length) {
			var m = ctx.modules[i++];
			var imports = ctx.moduleImports.get(Context.pathKey(m.path));
			if (imports == null) continue;
			for (imp in imports.rawImports) {
				switch (imp.mode) { case IAll: continue; case _: }
				if (imp.pos == null) continue;
				var parts = imp.path;
				var mi = -1;
				for (k in 0...parts.length) if (isUpper(parts[k].name)) { mi = k; break; }
				if (mi < 0 || parts.length - mi != 1) continue;
				var pack = [for (k in 0...mi) parts[k].name];
				var key = pack.join(".") + "." + parts[mi].name;
				if (plainImportsTried.exists(key)) continue;
				plainImportsTried.set(key, true);
				try ModuleLoader.loadModule(ctx, {pack: pack, name: parts[mi].name}, imp.pos)
				catch (e:hxc.context.Context.ContextError) ctx.addDiagnostic(e.message, e.pos, e.depth)
				catch (_:Dynamic) {}
			}
		}
	}

	static function isUpper(s:String):Bool {
		var c = s.charCodeAt(0);
		return c >= "A".code && c <= "Z".code;
	}

	static function checkImport(ctx:Context, importer:ModuleDef, imp:Import):Bool {
		// Only a normal / aliased import addresses a specific member (a wildcard cannot be wrong).
		switch (imp.mode) { case IAll: return false; case _: }
		if (imp.pos == null) return false;
		var parts = imp.path;
		// Pack = leading lowercase segments; the first uppercase segment is the module name.
		var mi = -1;
		for (i in 0...parts.length) if (isUpper(parts[i].name)) { mi = i; break; }
		if (mi < 0) return false;
		var pack = [for (i in 0...mi) parts[i].name];
		var moduleName = parts[mi].name;
		// Exactly one trailing segment after the module name is validated here (`import M.X`); a
		// deeper path is left alone (plain module imports load via loadPlainImports).
		if (parts.length - mi != 2) return false;
		var x = parts[mi + 1].name;

		var md = try ModuleLoader.loadModule(ctx, {pack: pack, name: moduleName}, imp.pos) catch (_:Dynamic) return false;
		if (md == null) return false;
		// The module may have been loaded but not resolved (an enum's constructors, for one, are
		// filled at resolution); resolving is idempotent.
		try hxc.typing.TypeResolve.resolveModule(ctx, md) catch (_:Dynamic) {}
		// A subtype of the module. Importing a PRIVATE one from another module reports at the path span
		// /error_private at punion p1 p2).
		for (mt in md.types) {
			var ti = TypeFunctions.tInfos(mt);
			if (ti.path.name != x) continue;
			if (ti.isPrivate && md != importer) {
				var pathPos = new Position(imp.pos.file, parts[mi].pos.min, parts[mi + 1].pos.max);
				ctx.addDiagnostic("Importing private declarations from a module is not allowed", pathPos);
			}
			return false;
		}
		// A module-level static; a private one reports at the whole import error_private p).
		if (md.statics != null && md.statics.statics.exists(x)) {
			var cf = md.statics.statics.get(x);
			if (!TypeFunctions.hasClassFieldFlag(cf, CfPublic) && md != importer) {
				ctx.addDiagnostic("Importing private declarations from a module is not allowed", imp.pos);
				return true;
			}
			return false;
		}

		var main = ModuleLoader.findTypeInModuleOpt(md, moduleName);
		if (main != null) {
			switch (main) {
				case TClassDecl(c):
					if (c.statics.exists(x)) return false;
					fail(ctx, imp.pos, x, statNames(c), "Class<" + Context.sTypePath(c.path) + "> has no field " + x);
					return false;
				case TAbstractDecl(a) if (a.impl != null):
					if (a.impl.statics.exists(x)) return false;
					fail(ctx, imp.pos, x, statNames(a.impl), "Abstract<" + Context.sTypePath(md.path) + "> has no field " + x);
					return false;
				case TEnumDecl(e):
					if (e.constrs.exists(x)) return false;
					fail(ctx, imp.pos, x, [for (k in e.constrs.keys()) k], "Enum<" + Context.sTypePath(md.path) + "> has no field " + x);
					return false;
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
		return false;
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
