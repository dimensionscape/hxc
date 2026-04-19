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
			// The sweep runs again from loadPlainImports. A module whose declaration walk was already
			// abandoned has no further declarations to reach, so the second visit must not pick up where
			// the abort left off and report the ones never reached.
			if (ctx.moduleAborted.exists(Context.pathKey(m.path))) { ctx.currentModule = savedMod; return; }
			// rawImports is built by unshifting, so it runs newest-first; init_module_type walks the
			// declarations in the order they were written, and with an import.hx in play that is the
			// difference between reporting its first entry and its last. The usings interleave by
			// their importPositions index, because init_module_type makes no distinction between the
			// two kinds - it walks one declaration list.
			var work:Array<{i:Int, imp:Null<Import>, us:Null<{path:Array<PlacedName>, pos:Position, idx:Int}>}> = [];
			var k = imports.rawImports.length;
			while (k-- > 0) {
				var imp0 = imports.rawImports[k];
				if (imp0.pos == null) continue;
				work.push({i: imports.importPositionIndex(imp0.pos), imp: imp0, us: null});
			}
			for (u in imports.rawUsings) work.push({i: u.idx, imp: null, us: u});
			work.sort(function(a, b) return a.i - b.i);
			for (w in work) {
				if (w.imp == null) {
					// A using that cannot be resolved ABANDONS the module: an import's error is caught and
					// recorded, a using's is not, so the error raises and no later declaration of the
					// module is reached. Two bad usings print one message, and a bad using before a bad
					// import prints only the using.
					if (loadUsing(ctx, m, imports, w.us)) {
						ctx.moduleAborted.set(Context.pathKey(m.path), true);
						break;
					}
					continue;
				}
				var imp = w.imp;
				var parts = imp.path;
				var mi = -1;
				for (k in 0...parts.length) if (isUpper(parts[k].name)) { mi = k; break; }
				// Only a PACKAGE wildcard (no uppercase segment) skips the load; `import a.Module.*` reaches
				// do_load_module like a plain import and reports the same way when the module does not exist.
				if (mi < 0 && imp.mode.match(IAll)) continue;
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
				// And reports each import declaration: a second `import` of a module that failed to load fails
				// again and is reported again. The sweep's own revisits dedup on the declaration, as the
				// lowercase and using arms do.
				var key = "import!" + imp.pos.file + "!" + imp.pos.min + "!" + imp.pos.max;
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
				// ForbidPackage is not a typing error either: it passes the declaration handler and ends
				// the compile.
				catch (fp:hxc.core.TypingError.ForbidPackage) { throw fp; }
				catch (_:Dynamic) { imports.markImportFailed(imp.pos); }
			}
		} catch (e:haxe.Exception) { ctx.currentModule = savedMod; throw e; }
		ctx.currentModule = savedMod;
	}

	/**
	    Loads a `using` declaration and queues its classes. Returns true when the load failed and the module
	    has to be abandoned.
	**/
	static function loadUsing(ctx:Context, m:hxc.core.Type.ModuleDef, imports:hxc.context.Context.ModuleImports,
			us:{path:Array<PlacedName>, pos:Position, idx:Int}):Bool {
		var parts = [for (pn in us.path) pn.name];
		if (parts.length == 0) return false;
		// The path is read POSITIONALLY off its tail, not by hunting the first uppercase segment the way
		// an import is: the last element is the type, and the one before it decides whether it names a
		// package (so the module is the last element) or a module (so the last element is a sub-type of
		// it).
		var tpack:Array<String>;
		var tname:String;
		var tsub:Null<String> = null;
		if (parts.length >= 2) {
			var s1 = parts[parts.length - 1];
			var s2 = parts[parts.length - 2];
			if (hxc.ast.Ast.isLowerIdent(s2)) {
				tpack = parts.slice(0, parts.length - 1);
				tname = s1;
			} else {
				tsub = s1;
				tname = s2;
				tpack = parts.slice(0, parts.length - 2);
			}
		} else {
			tpack = [];
			tname = parts[0];
		}
		// The sweep visits a module more than once (typeModule, then loadPlainImports), so the
		// report dedups on the declaration exactly as the plain imports do.
		var dkey = "using!" + us.pos.file + "!" + us.pos.min + "!" + us.pos.max;
		if (ctx.plainImportsTried.exists(dkey)) return false;
		ctx.plainImportsTried.set(dkey, true);
		// The two forms take DIFFERENT loaders, and the difference is not cosmetic: the bare form loads a
		// module, the sub form loads a type. A module load resolves the literal path only, so `using
		// Helper` inside `package foo` does not find foo/Helper.hx and is an error; a type load with an
		// empty package walks OUT from the current package (loadUnqualifiedSub), which makes `using
		// MyClass.UsingBase` inside `package unit` resolve unit.MyClass. The report covers the whole
		// using declaration, where an import narrows to the type path.
		var failed:Null<{msg:String, pos:Position, depth:Int}> = null;
		try {
			if (tsub == null) {
				ModuleLoader.loadModule(ctx, {pack: tpack, name: tname}, us.pos);
			} else if (tpack.length > 0) {
				// A qualified sub-type: one module, and a missing sub-type raises.
				var md = ModuleLoader.loadModule(ctx, {pack: tpack, name: tname}, us.pos);
				if (md != null) failed = subTypeError(ctx, md, tsub, us.pos);
			} else {
				failed = loadUnqualifiedSub(ctx, tname, tsub, us.pos);
			}
		} catch (e:hxc.context.Context.ContextError) {
			failed = {msg: e.message, pos: e.pos, depth: e.depth};
		}
		// A parse failure is not a load error: it passes straight through and aborts the compile.
		catch (pe:hxc.parser.ParserError) { throw pe; }
		catch (_:Dynamic) { imports.markImportFailed(us.pos); return false; }
		if (failed == null) return false;
		ctx.addDiagnostic(failed.msg, failed.pos, failed.depth);
		imports.markImportFailed(us.pos);
		return true;
	}

	/**
	 * A `using` sub-type with no package: the wildcard-imported packages first, then the current
	 * package outward to the root. Every candidate but the last looks the sub-type up without raising
	 * and moves on; only the root-package attempt reports. Returns null on success.
	 */
	static function loadUnqualifiedSub(ctx:Context, tname:String, tsub:String, p:Position):Null<{msg:String, pos:Position, depth:Int}> {
		function tryPack(pack:Array<String>):Bool {
			var md = try ModuleLoader.loadModule(ctx, {pack: pack, name: tname}, p) catch (_:Dynamic) null;
			return md != null && ModuleLoader.findTypeInModuleOpt(md, tsub) != null;
		}
		var m = ctx.currentModule;
		var imports = m == null ? null : ctx.moduleImports.get(Context.pathKey(m.path));
		if (imports != null)
			for (w in imports.wildcards)
				if (tryPack(w.pack.concat([w.name]))) return null;
		if (m != null) {
			var cp = m.path.pack;
			var i = cp.length;
			while (i >= 1) {
				if (tryPack(cp.slice(0, i))) return null;
				i--;
			}
		}
		// The root attempt is the one that reports: a module that will not load is
		// "Type not found", one that loads without the sub-type is "does not define type".
		var md:Null<hxc.core.Type.ModuleDef> = null;
		try md = ModuleLoader.loadModule(ctx, {pack: [], name: tname}, p)
		catch (e:hxc.context.Context.ContextError) return {msg: e.message, pos: e.pos, depth: e.depth};
		if (md == null)
			return {msg: "Module " + tname + " does not define type " + tsub, pos: p, depth: 0};
		return subTypeError(ctx, md, tsub, p);
	}

	/**
	    A PRIVATE sub-type is reachable from its own module - which is what a `using pack.Mod.Helper` inside
	    Mod.hx relies on - and the two ways to miss have different messages. Returns null when the type is
	    there.
	**/
	static function subTypeError(ctx:Context, md:hxc.core.Type.ModuleDef, tname:String,
			p:Position):Null<{msg:String, pos:Position, depth:Int}> {
		for (mt in md.types) {
			var ti = TypeFunctions.tInfos(mt);
			if (ti.path.name != tname) continue;
			if (ti.isPrivate && ctx.currentModule != ti.module)
				return {msg: "Cannot access private type " + tname + " in module " + Context.sTypePath(md.path),
					pos: p, depth: 0};
			return null;
		}
		return {msg: "Module " + Context.sTypePath(md.path) + " does not define type " + tname, pos: p, depth: 0};
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
