package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.StringError;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.context.ModuleLoader;

// What an import declaration does when its module's types initialize.
// The statics it names are looked up later, in the module's context init (ModuleLoader.recordImport).
class ImportCheck {
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
			// rawImports is built by unshifting, so it runs newest-first; declarations are walked in the
			// order they were written, and with an import.hx in play that is the difference between
			// reporting its first entry and its last. The usings interleave by their importPositions index,
			// because imports and usings make one declaration list.
			// The declarations a macro defines share one position (Context.defineModule's), so equal
			// indices keep the order they were written in.
			var work:Array<{i:Int, seq:Int, imp:Null<Import>, us:Null<{path:Array<PlacedName>, pos:Position, idx:Int}>}> = [];
			var k = imports.rawImports.length;
			while (k-- > 0) {
				var imp0 = imports.rawImports[k];
				if (imp0.pos == null) continue;
				work.push({i: imports.importPositionIndex(imp0.pos), seq: work.length, imp: imp0, us: null});
			}
			for (u in imports.rawUsings) work.push({i: u.idx, seq: work.length, imp: null, us: u});
			work.sort(function(a, b) return a.i != b.i ? a.i - b.i : a.seq - b.seq);
			// The path-display checks of the declarations up to this one.
			function runPathDisplay(upTo:Int):Void {
				while (imports.pathDisplay.length > 0 && imports.pathDisplay[0].seq <= upTo) {
					var d = imports.pathDisplay.shift();
					imports.pathDisplayAt = d.seq;
					try d.run() catch (e:Dynamic) { imports.answeredAt = d.seq; imports.pathDisplayAt = -1; throw e; }
					imports.pathDisplayAt = -1;
				}
			}
			var aborted = false;
			for (w in work) {
				// An import's check runs inside the handler that records its init's errors, and a failure
				// skips
				// that init; a using's has no handler, so its failure abandons the module as any failed
				// using does.
				try runPathDisplay(w.i) catch (e:hxc.context.Context.ContextError) {
					ctx.addDiagnostic(e.message, e.pos, e.depth);
					if (w.imp == null) {
						ctx.moduleAborted.set(Context.pathKey(m.path), true);
						aborted = true;
						break;
					}
					imports.markImportFailed(w.imp.pos);
					continue;
				}
				if (w.imp == null) {
					// A using that cannot be resolved ABANDONS the module: an import's error is caught and
					// recorded, a using's is not, so the error raises and no later declaration of the
					// module is reached. Two bad usings print one message, and a bad using before a bad
					// import prints only the using.
					if (loadUsing(ctx, m, imports, w.us)) {
						ctx.moduleAborted.set(Context.pathKey(m.path), true);
						aborted = true;
						break;
					}
					continue;
				}
				var imp = w.imp;
				var parts = imp.path;
				var mi = -1;
				for (k in 0...parts.length) if (!hxc.ast.Ast.isLowerIdent(parts[k].name)) { mi = k; break; }
				// Only a PACKAGE wildcard (no module segment) skips the load; `import a.Module.*` loads its
				// module like a plain import and reports the same way when the module does not exist.
				if (mi < 0 && (imp.mode.match(IAll) || parts.length == 0)) continue;
				// Each import declaration runs and reports: a second `import` of a module that failed to load
				// fails again and is reported again. The sweep visits a module more than once, so its own
				// revisits dedup on the declaration.
				var key = if (mi < 0) {
					var lp = parts[parts.length - 1].pos;
					"lower!" + m.id + "!" + lp.file + "!" + lp.min + "!" + lp.max;
				} else "import!" + m.id + "!" + imp.pos.file + "!" + imp.pos.min + "!" + imp.pos.max + "!" + [for (pn in parts) pn.name].join(".");
				if (ctx.plainImportsTried.exists(key)) continue;
				ctx.plainImportsTried.set(key, true);
				// An import's report is recorded, not raised; only the host context raises it, under a
				// macro API call. In the macro context, raising (set while EvalMacro.loadMacroClass loads a
				// module) stands for the typing errors of that module's declarations, which this handler is
				// not.
				function record(msg:String, p:Position, depth:Int = 0):Void {
					var savedRaise = ctx.raiseTypingErrors;
					if (ctx.isMacro) ctx.raiseTypingErrors = false;
					ctx.addDiagnostic(msg, p, depth);
					ctx.raiseTypingErrors = savedRaise;
					imports.markImportFailed(imp.pos);
				}
				// An import's typing error is caught and recorded. A PARSE failure is a different exception
				// and passes straight through, aborting the compile on the spot.
				// sys/thread/Thread.hx is nothing but
				// `#if (!target.threaded) #error "This class is not available on this target"`,
				// and that one message, with nothing after it, is all that is printed - even when import.hx
				// names five such modules.
				try checkImport(ctx, parts, imp.mode)
				catch (e:hxc.context.Context.ContextError) {
					record(e.message, e.pos, e.depth);
				}
				catch (pe:hxc.parser.ParserError) { throw pe; }
				// ForbidPackage is not a typing error either: it passes the declaration handler and ends
				// the compile.
				catch (fp:hxc.core.TypingError.ForbidPackage) { throw fp; }
				catch (_:Dynamic) { imports.markImportFailed(imp.pos); }
			}
			// An `import |` or `using |` after the last recorded declaration; an abandoned module
			// reaches none of them.
			if (aborted) imports.pathDisplay = [] else runPathDisplay(0x7fffffff);
		} catch (e:haxe.Exception) { ctx.currentModule = savedMod; throw e; }
		ctx.currentModule = savedMod;
	}

	/**
	    The module load and what the declaration raises, in that order.
	    What it binds is ModuleLoader.bindImport's.
	**/
	public static function checkImport(ctx:Context, parts:Array<PlacedName>, mode:ImportMode):Void {
		// The module is the first segment that is not a lowercase identifier.
		var mi = -1;
		for (k in 0...parts.length) if (!hxc.ast.Ast.isLowerIdent(parts[k].name)) { mi = k; break; }
		if (mi < 0) {
			// A package wildcard; anything else is an error at the last element.
			if (mode.match(IAll) || parts.length == 0) return;
			throw new hxc.context.Context.ContextError("Module name must start with an uppercase letter", parts[parts.length - 1].pos);
		}
		// The module named by that segment loads at the type path, the first pack segment through the
		// module name. A sub-type or a static-field import loads its module exactly like a plain one:
		// haxe.macro.PositionTools imports haxe.display.Position.Location for a `#if macro` signature, and
		// that module still loads and, through the typedef, so does haxe.display.FsPath - so under -dce no
		// the FsPath abstract is generated.
		var pType = Position.union(parts[0].pos, parts[mi].pos);
		var md = ModuleLoader.loadModule(ctx, {pack: [for (k in 0...mi) parts[k].name], name: parts[mi].name}, pType);
		// getType: failUsefully's message for a type the module does not have, the private-import error for
		// another module's private one, both over the type path.
		function getType(name:String):Void {
			var t = namedType(md, name);
			if (t == null) throw new hxc.context.Context.ContextError(failUsefully(md, name), pType);
			if (isPrivateElsewhere(ctx, t)) throw new hxc.context.Context.ContextError("Importing private declarations from a module is not allowed", pType);
		}
		// Rebind: a type alias starts uppercase.
		function rebind(alias:PlacedName):Void {
			var c = alias.name.charCodeAt(0);
			if (!(c >= "A".code && c <= "Z".code))
				throw new hxc.context.Context.ContextError("Type aliases must start with an uppercase letter", alias.pos);
		}
		var after = parts.slice(mi + 1);
		switch (mode) {
			case IAll:
				if (after.length >= 2) throw new hxc.context.Context.ContextError("Unexpected " + after[1].name, after[1].pos);
				getType(after.length == 1 ? after[0].name : parts[mi].name);
			case INormal | IAsName(_):
				var alias = switch (mode) { case IAsName(n): n; case _: null; };
				switch (after.length) {
					case 0:
						if (alias != null) { getType(parts[mi].name); rebind(alias); }
					case 1:
						// A type of that name, unless it is another module's private one; any other name is
						// a static,
						// looked up in the module's context init.
						var t = namedType(md, after[0].name);
						if (t != null) {
							if (isPrivateElsewhere(ctx, t))
								throw new hxc.context.Context.ContextError("Importing private declarations from a module is not allowed",
									Position.union(parts[0].pos, after[0].pos));
							if (alias != null) rebind(alias);
						}
					case _:
						if (after.length > 2) throw new hxc.context.Context.ContextError("Unexpected " + after[2].name, after[2].pos);
						getType(after[0].name);
				}
		}
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
		// The sweep visits a module more than once (typeModule, then loadPlainImports), so the report
		// dedups on the declaration exactly as the plain imports do. A declaration runs once per typing
		// of the module, so the key is the module instance's: the macro context outlives a request, and a
		// module it types again (the display file's) is a new one.
		var dkey = "using!" + m.id + "!" + us.pos.file + "!" + us.pos.min + "!" + us.pos.max;
		if (ctx.plainImportsTried.exists(dkey)) return false;
		ctx.plainImportsTried.set(dkey, true);
		// The two forms take DIFFERENT loaders, and the difference is not cosmetic: the bare form loads a
		// module, the sub form loads a type. A module load resolves the literal path only, so `using
		// Helper` inside `package foo` does not find foo/Helper.hx and is an error; a type load with an
		// empty package walks OUT from the current package (loadUnqualifiedSub), which makes `using
		// MyClass.UsingBase` inside `package unit` resolve unit.MyClass. The report covers the whole
		// using declaration, where an import narrows to the type path.
		var failed:Null<{msg:String, pos:Position, depth:Int}> = null;
		var types:Null<Array<hxc.core.Type.ModuleType>> = null;
		try {
			if (tsub == null) {
				types = usingModuleTypes(ModuleLoader.loadModule(ctx, {pack: tpack, name: tname}, us.pos));
			} else if (tpack.length > 0) {
				// A qualified sub-type: one module, and a missing sub-type raises.
				var md = ModuleLoader.loadModule(ctx, {pack: tpack, name: tname}, us.pos);
				if (md != null) {
					failed = subTypeError(ctx, md, tsub, us.pos);
					if (failed == null) types = [namedType(md, tsub)];
				}
			} else {
				var found:Array<hxc.core.Type.ModuleType> = [];
				failed = loadUnqualifiedSub(ctx, tname, tsub, us.pos, found);
				if (failed == null && found.length > 0) types = [found[0]];
			}
		} catch (e:hxc.context.Context.ContextError) {
			failed = {msg: e.message, pos: e.pos, depth: e.depth};
		}
		// A parse failure is not a load error: it passes straight through and aborts the compile.
		catch (pe:hxc.parser.ParserError) { throw pe; }
		catch (_:Dynamic) { imports.markImportFailed(us.pos); return false; }
		if (failed == null) {
			if (types != null) {
				var usingTypes = types, idx = us.idx;
				// The classes join the module's usings once the module's context initializes (delayed
				// because typedefs must resolve first).
				ctx.contextInitAdd(m, function() imports.usingClasses = usingClassesOf(usingTypes, idx).concat(imports.usingClasses));
			}
			return false;
		}
		ctx.addDiagnostic(failed.msg, failed.pos, failed.depth);
		imports.markImportFailed(us.pos);
		return true;
	}

	/**
	 * A `using` sub-type with no package: the wildcard-imported packages first, then the current
	 * package outward to the root. Every candidate but the last looks the sub-type up without raising
	 * and moves on; only the root-package attempt reports. Returns null on success.
	 */
	static function loadUnqualifiedSub(ctx:Context, tname:String, tsub:String, p:Position, ?found:Array<hxc.core.Type.ModuleType>):Null<{msg:String, pos:Position, depth:Int}> {
		function tryPack(pack:Array<String>):Bool {
			var md = try ModuleLoader.loadModule(ctx, {pack: pack, name: tname}, p) catch (_:Dynamic) null;
			var t = md == null ? null : ModuleLoader.findTypeInModuleOpt(md, tsub);
			if (t != null && found != null) found.push(t);
			return t != null;
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
		var err = subTypeError(ctx, md, tsub, p);
		if (err == null && found != null) found.push(namedType(md, tsub));
		return err;
	}

	// The type of that name, once subTypeError has let it through, private or not (a module reaches its own
	// private types).
	public static function namedType(md:hxc.core.Type.ModuleDef, tname:String):Null<hxc.core.Type.ModuleType> {
		for (mt in md.types) if (TypeFunctions.tPath(mt).name == tname) return mt;
		return null;
	}

	// `using pack.Module` brings the module's statics class first, then every non-private type of the
	// module.
	static function usingModuleTypes(md:hxc.core.Type.ModuleDef):Array<hxc.core.Type.ModuleType> {
		var types = [for (t in md.types) if (!TypeFunctions.tInfos(t).isPrivate) t];
		if (md.statics != null) types.unshift(TClassDecl(md.statics));
		return types;
	}

	// Each type resolved past its typedefs, a class itself and an abstract its implementation, prepended -
	// so the last type comes first.
	public static function usingClassesOf(types:Array<hxc.core.Type.ModuleType>, idx:Int):Array<{c:hxc.core.Type.TClass, idx:Int}> {
		var acc:Array<{c:hxc.core.Type.TClass, idx:Int}> = [];
		for (t in types) if (t != null) switch (TypeFunctions.resolveTypedef(t)) {
			case TClassDecl(c): acc.unshift({c: c, idx: idx});
			case TAbstractDecl(a) if (a.impl != null): acc.unshift({c: a.impl, idx: idx});
			case _:
		}
		return acc;
	}

	// The using lookup for Context.withImports: the same two loaders, raising as they do.
	public static function usingTypes(ctx:Context, parts:Array<String>, p:Position):Array<hxc.core.Type.ModuleType> {
		if (parts.length == 0) return [];
		var s1 = parts[parts.length - 1];
		if (parts.length >= 2 && !hxc.ast.Ast.isLowerIdent(parts[parts.length - 2])) {
			var tname = parts[parts.length - 2], tpack = parts.slice(0, parts.length - 2);
			if (tpack.length > 0) {
				var md = ModuleLoader.loadModule(ctx, {pack: tpack, name: tname}, p);
				var err = subTypeError(ctx, md, s1, p);
				if (err != null) throw new hxc.context.Context.ContextError(err.msg, err.pos);
				return [namedType(md, s1)];
			}
			var found:Array<hxc.core.Type.ModuleType> = [];
			var err = loadUnqualifiedSub(ctx, tname, s1, p, found);
			if (err != null) throw new hxc.context.Context.ContextError(err.msg, err.pos);
			return found.length > 0 ? [found[0]] : [];
		}
		return usingModuleTypes(ModuleLoader.loadModule(ctx, {pack: parts.slice(0, parts.length - 1), name: s1}, p));
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

	// Another module's private type.
	static function isPrivateElsewhere(ctx:Context, t:hxc.core.Type.ModuleType):Bool {
		var ti = TypeFunctions.tInfos(t);
		return ti.isPrivate && ctx.currentModule != ti.module;
	}

	// The message for a missing name: a name starting lowercase was meant as a field of the module, any
	// other as one of its types, and the suggestions come from that list.
	public static function failUsefully(md:ModuleDef, name:String):String {
		var c = name.charCodeAt(0);
		var field = c >= "a".code && c <= "z".code;
		var candidates = if (!field) [for (mt in md.types) TypeFunctions.tPath(mt).name]
			else md.statics == null ? [] : foldiNames([for (k in md.statics.statics.keys()) k]);
		return StringError.stringError(name, candidates,
			"Module " + Context.sTypePath(md.path) + " does not define " + (field ? "field " : "type ") + name);
	}

	// The keys, in decreasing order.
	public static function foldiNames(keys:Array<String>):Array<String> {
		hxc.core.StringSort.sortDescending(keys);
		return keys;
	}
}
