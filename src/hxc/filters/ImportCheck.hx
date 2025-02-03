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

	public static function loadPlainImports(ctx:Context):Void {
		var i = 0;
		while (i < ctx.modules.length) loadModuleImports(ctx, ctx.modules[i++]);
	}

	// A module is registered first and only then are its declarations initialized, so the imports of a
	// module load right after it is registered - which keeps a pair of mutually importing modules from
	// recursing, and what puts an imported module's declaration errors AHEAD of the importing module's
	// own. An `import.hx` naming sys.thread.Thread therefore reports its `#if (!target.threaded)
	// #error` before anything in Main.
	public static function loadModuleImports(ctx:Context, m:hxc.core.Type.ModuleDef):Void {
		var savedMod = ctx.currentModule;
		ctx.currentModule = m; // The load records its dependency on the IMPORTING module
		try {
			var imports = ctx.moduleImports.get(Context.pathKey(m.path));
			if (imports == null) { ctx.currentModule = savedMod; return; }
			// rawImports is built by unshifting, so it runs newest-first; init_module_type walks the
			// declarations in the order they were written, and with an import.hx in play that is the
			// difference between reporting its first entry and its last.
			var k = imports.rawImports.length;
			while (k-- > 0) {
				var imp = imports.rawImports[k];
				switch (imp.mode) { case IAll: continue; case _: }
				if (imp.pos == null) continue;
				var parts = imp.path;
				var mi = -1;
				for (k in 0...parts.length) if (isUpper(parts[k].name)) { mi = k; break; }
				// The module named by the first uppercase segment and leaves everything after it to the mode
				// switch, so a sub-type or a static-field import loads its module exactly like a plain one
				// does. Requiring the module name to be the last segment meant an import of a sub-type nobody
				// used never pulled its module in: haxe.macro.PositionTools imports
				// haxe.display.Position.Location for a `#if macro` signature, and the reference still loads
				// that module and, through the typedef, haxe.display.FsPath - so under -dce no the FsPath
				// abstract is generated.
				if (mi < 0) {
					// A path with no uppercase segment reaches the mode switch with rest = [], and anything but a
					// wildcard is an error at the last element; init_module_type catches and records it, so the
					// sweep continues. The sweep visits a module more than once, so the report dedups the same way
					// a load does (plainImportsTried).
					if (parts.length > 0) {
						var lp = parts[parts.length - 1].pos;
						var dkey = "lower!" + lp.file + "!" + lp.min + "!" + lp.max;
						if (!ctx.plainImportsTried.exists(dkey)) {
							ctx.plainImportsTried.set(dkey, true);
							ctx.addDiagnostic("Module name must start with an uppercase letter", lp);
							imports.markImportFailed(imp.pos);
						}
					}
					continue;
				}
				var pack = [for (k in 0...mi) parts[k].name];
				var key = pack.join(".") + "." + parts[mi].name;
				if (ctx.plainImportsTried.exists(key)) continue;
				ctx.plainImportsTried.set(key, true);
				// The module load reports at the type path - the first pack segment through the module name
				// - not over the whole import declaration.
				var pType = new Position(imp.pos.file, parts[0].pos.min, parts[mi].pos.max);
				try ModuleLoader.loadModule(ctx, {pack: pack, name: parts[mi].name}, pType)
				catch (e:hxc.context.Context.ContextError) {
					ctx.addDiagnostic(e.message, e.pos, e.depth);
					imports.markImportFailed(imp.pos);
				}
				// init_module_type wraps init_import in `with Error(err,p,depth) -> display_error_ext`,
				// which catches a LOAD error and records it.
				catch (pe:hxc.parser.ParserError) { throw pe; }
				catch (_:Dynamic) { imports.markImportFailed(imp.pos); }
			}
		} catch (e:haxe.Exception) { ctx.currentModule = savedMod; throw e; }
		ctx.currentModule = savedMod;
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
