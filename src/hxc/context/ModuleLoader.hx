package hxc.context;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypingError;
import hxc.context.Context;
import hxc.core.Globals.Path;
import hxc.core.Globals.Platform;
import haxe.ds.StringMap;
import sys.FileSystem;

class ModuleLoader {
	public static function attach(ctx:Context):Void {
		// Resolve a @:multiType abstract's concrete specialization through the typer first.
		hxc.core.TypeFunctions.multiTypeResolver = function(a, pl)
			return try hxc.typing.Typer.resolveMultiTypeConcrete(a, pl, Position.nullPos) catch (_:Dynamic) null;
		ctx.getType = function(path:Path, p:Position, ?sub:String):ModuleType {
			// An empty package and type name marks cursor type completion; answer before rejecting empty
			// module names.
			if (path.pack.length == 0 && path.name == "" && sub == null && hxc.parser.Parser.displayFile != null)
				hxc.typing.TypeResolve.answerTypeHintCompletion(ctx, p);
			if (path.name == "") throw new ContextError("Empty module name is not allowed", p);
			return loadTypeDef(ctx, path, p, sub);
		};
		ctx.defineType = function(mt:ModuleType):Void {
			var m = TypeFunctions.tInfos(mt).module;
			addModule(ctx, m);
		};
	}

	public static function isAbsolutePath(f:String):Bool {
		if (f.length == 0) return false;
		var c = f.charCodeAt(0);
		if (c == "/".code) return true;
		if ((c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code))
			return hxc.core.Globals.isWindows && f.length > 1 && f.charCodeAt(1) == ":".code;
		if (c == 92) return hxc.core.Globals.isWindows;               
		return false;
	}

	public static function findFile(ctx:Context, relPath:String, m:Path, p:Position):String {
		// Return absolute paths unchecked; opening an absent file must report Could not open rather than
		// Type not found.
		if (isAbsolutePath(relPath)) return relPath;
		for (dir in ctx.classPath) {
			var full = (dir == "" ? "" : (StringTools.endsWith(dir, "/") || StringTools.endsWith(dir, "\\") ? dir : dir + "/")) + relPath;
			if (skipEvalOverlayFile(ctx, dir, relPath)) continue;
			// Allow directory entries to resolve as modules; opening them produces Could not open rather
			// than Type not found.
			if (FileSystem.exists(full)) {
				// Require exact spelling from the directory listing even on case-insensitive filesystems.
				var canon = canonicalFileName(ctx, full);
				var reqBase = { var i = relPath.lastIndexOf("/"); relPath.substr(i + 1); };
				var gotBase = {
					var i = canon.lastIndexOf("/");
					var j = canon.lastIndexOf("\\");
					canon.substr((j > i ? j : i) + 1);
				};
				if (gotBase == reqBase) {
					// Cache files from the current directory by bare name so -cp . reports Main.hx, not ./Main.hx.
					var k = { var i = canon.lastIndexOf("/"); var j = canon.lastIndexOf("\\"); j > i ? j : i; };
					var dirPart = k < 0 ? "." : canon.substr(0, k);
					return dirPart == "." ? gotBase : canon;
				}
			}
		}
		throw new ContextError("Type not found : " + Context.sTypePath(m), p, ModuleNotFound(m));
	}

	// Cache each directory listing once, including lowercase-to-actual-name mappings, for later module
	// lookups.
	static function dirListing(ctx:Context, dir:String):Null<StringMap<String>> {
		if (ctx.readdirCache.exists(dir)) return ctx.readdirCache.get(dir);
		var m:Null<StringMap<String>> = null;
		try {
			m = new StringMap<String>();
			for (entry in FileSystem.readDirectory(dir)) m.set(entry.toLowerCase(), entry);
		} catch (_:Dynamic) m = null;
		ctx.readdirCache.set(dir, m);
		return m;
	}

	static function canonicalFileName(ctx:Context, file:String):String {
		var slash = file.lastIndexOf("/");
		var backslash = file.lastIndexOf("\\");
		if (backslash > slash) slash = backslash;
		if (slash < 0) {
			var cwd = dirListing(ctx, ".");
			if (cwd != null) { var e = cwd.get(file.toLowerCase()); if (e != null) return e; }
			return file;
		}
		var dir = file.substr(0, slash + 1);
		var name = file.substr(slash + 1);
		var listing = dirListing(ctx, dir);
		if (listing != null) { var e = listing.get(name.toLowerCase()); if (e != null) return dir + e; }
		return file;
	}

	static function skipEvalOverlayFile(ctx:Context, dir:String, relPath:String):Bool {
		if (ctx.platform != Platform.Eval) return false;
		var d = StringTools.replace(dir, "\\", "/");
		if (!StringTools.endsWith(d, "/")) d += "/";
		if (!StringTools.endsWith(d, "/eval/_std/")) return false;
		return relPath == "sys/thread/EventLoop.hx"
			|| relPath == "sys/thread/Condition.hx"
			|| relPath == "sys/thread/Semaphore.hx";
	}

	// Read display-stdin once and register its contents for diagnostics as well as parsing.
	static var stdinConsumed = false;
	static var stdinContent:Null<String> = null;

	// Server display source follows a request's 0x01 byte. Prefer it over stdin so parsing cannot
	// consume the next frame header.
	public static var currentStdin:Null<String> = null;

	public static function resetPerRequest():Void {
		stdinConsumed = false;
		stdinContent = null;
	}

	public static function moduleFileContent(ctx:Context, file:String):String {
		if (ctx.fileContents.length > 0) {
			var f = StringTools.replace(file, "\\", "/").toLowerCase();
			for (fc in ctx.fileContents) {
				if (fc.contents == null) continue;
				var k = StringTools.replace(fc.file, "\\", "/").toLowerCase();
				if (k == f || StringTools.endsWith(k, "/" + f) || StringTools.endsWith(f, "/" + k))
					return Position.registerFileContent(file, fc.contents);
			}
		}
		var df = hxc.parser.Parser.displayFile;
		if (df != null && ctx.defines.rawDefined("display_stdin")) {
			var f = StringTools.replace(file, "\\", "/");
			var d = StringTools.replace(df, "\\", "/");
			if (f == d || StringTools.endsWith(f, "/" + d) || StringTools.endsWith(d, "/" + f)) {
				if (!stdinConsumed) {
					stdinConsumed = true;
					stdinContent = currentStdin != null
						? currentStdin
						: (try Sys.stdin().readAll().toString() catch (_:Dynamic) null);
				}
				if (stdinContent != null) return Position.registerFileContent(file, stdinContent);
			}
		}
		return Position.getFileContent(file);
	}

	public static function resolveModuleFile(ctx:Context, m:Path, p:Position):String {
		var prefix = m.pack.length == 0 ? m.name : m.pack.join("/") + "/" + m.name;
		if (ctx.isMacro) {
			try return findFile(ctx, prefix + ".macro.hx", m, p) catch (_:ContextError) {}
		}
		// A target suffixed file (Name.<target>.hx) shadows the plain one for its platform.
		if (ctx.platform != Cross) {
			try return findFile(ctx, prefix + "." + hxc.core.Globals.platformName(ctx.platform) + ".hx", m, p) catch (_:ContextError) {}
		}
		return findFile(ctx, prefix + ".hx", m, p);
	}

	static function makeModule(ctx:Context, mpath:Path, file:String):ModuleDef {
		// Store full native path, signature and mtime for server/module reporting.
		var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
		var time = try sys.FileSystem.stat(full).mtime.getTime() / 1000.0 catch (_:Dynamic) 0.0;
		return {
			id: TypeFunctions.allocMid(),
			path: mpath,
			types: [],
			statics: null,
			extra: TypeFunctions.moduleExtra(full, ctx.defines.getSignature(), time, ctx.isMacro ? MMacro : MCode, getPolicy(ctx, mpath))
		};
	}

	// Accumulate matching module policies in reverse registration order.
	public static function getPolicy(ctx:Context, mpath:Path):Array<hxc.core.Type.ModuleCheckPolicy> {
		if (ctx.moduleCheckPolicies.length == 0) return [];
		var sl1 = hxc.ast.Ast.fullDotPath2(mpath, mpath);
		var acc:Array<hxc.core.Type.ModuleCheckPolicy> = [];
		for (e in ctx.moduleCheckPolicies)
			if (hxc.ast.Ast.matchPath(e.recursive, sl1, e.filter)) acc = e.policy.concat(acc);
		return acc;
	}

	static function applyTypePatches(ctx:Context, path:Path, meta:Metadata, ?fields:Array<ClassField>):{meta:Metadata, fields:Array<ClassField>} {
		if (ctx.typePatches.length == 0) return {meta: meta, fields: fields};
		function samePath(a:Path, b:Path):Bool return a.name == b.name && sameArray(a.pack, b.pack);
		var classMeta = meta;
		var result = fields;
		for (patch in ctx.typePatches) {
			if (!samePath(path, patch.path)) continue;
			if (patch.field == null) {
				classMeta = classMeta.concat(patch.meta);
				continue;
			}
			if (result == null) continue;
			var next:Array<ClassField> = [];
			for (field in result) {
				var isStatic = false;
				for (access in field.cffAccess) if (access.access == AStatic) isStatic = true;
				if (field.cffName.name != patch.field || isStatic != patch.isStatic) {
					next.push(field);
					continue;
				}
				field.cffMeta = field.cffMeta.concat(patch.meta);
				if (patch.typeHint != null) switch (field.cffKind) {
					case FVar(_, e): field.cffKind = FVar(patch.typeHint, e);
					case FProp(get, set, _, e): field.cffKind = FProp(get, set, patch.typeHint, e);
					case FFun(f): field.cffKind = FFun({fParams: f.fParams, fArgs: f.fArgs, fType: patch.typeHint, fExpr: f.fExpr});
				}
				if (!patch.remove) next.push(field);
			}
			result = next;
		}
		return {meta: classMeta, fields: result};
	}

	// Restore cached module imports without replacing existing types; import-only declarations append
	// no types.
	public static function typeImportsIntoModule(ctx:Context, m:ModuleDef, imports:Array<TypeDecl>):Void {
		createModuleTypes(ctx, m, handleImportHx(ctx, m, imports), true);
	}

	static function createModuleTypes(ctx:Context, m:ModuleDef, tdecls:Array<TypeDecl>, keepTypes:Bool = false):Void {
		var decls:Array<ModuleType> = [];
		var statics:Array<{d:Definition<PlacedAccess, ClassFieldKind>, p:Position}> = [];
		var hasDeclaration = false;

		var imports = new hxc.context.Context.ModuleImports(new StringMap(), [], []);

		// The first uppercase segment is the module, the second a subtype. Return null for empty or
		// package-wildcard paths.
		function splitImportPath(parts:Array<String>):{modulePath:Path, sub:Null<String>, field:Null<String>} {
			var pack:Array<String> = [];
			var i = 0;
			while (i < parts.length) {
				var c = parts[i].charCodeAt(0);
				if (c >= "A".code && c <= "Z".code) break;
				pack.push(parts[i]);
				i++;
			}
			if (i >= parts.length) return null;                                                    
			var moduleName = parts[i];
			i++;
			var sub:Null<String> = null;
			var field:Null<String> = null;
			if (i < parts.length) {
				// After the module, an uppercase segment names a subtype and a lowercase one a static; a
				// subtype may be followed by a static.
				var c2 = parts[i].charCodeAt(0);
				if (c2 >= "A".code && c2 <= "Z".code) {
					sub = parts[i];
					i++;
					if (i < parts.length) {
						var c3 = parts[i].charCodeAt(0);
						if (c3 >= "a".code && c3 <= "z".code) field = parts[i];
					}
				} else {
					field = parts[i];
				}
			}
			return {modulePath: {pack: pack, name: moduleName}, sub: sub, field: field};
		}

		// Answer the segment containing the display position, including cursors inside a segment rather
		// than at its dot.
		function checkPathDisplay(path:Array<PlacedName>):Void {
			// Hovering a module or subtype path segment returns its type, as an expression type path does.
			if (hxc.typing.Typer.displayHover || hxc.typing.Typer.displayTypeDefinition
					|| hxc.typing.Typer.displayDefinition) {
				var pack:Array<String> = [];
				var mod:Null<String> = null;
				var sub:Null<String> = null;
				// Display a trailing static segment as an ordinary access on its module type or subtype.
				function staticField(typeName:String, field:String, fp:Position):Void {
					var m2 = try loadModuleOpt(ctx, {pack: pack, name: mod}, fp) catch (_:Dynamic) null;
					if (m2 == null) return;
					// Build the class before display; merely loaded field signatures still contain open
					// monomorphs.
					try hxc.typing.TypeResolve.resolveModule(ctx, m2) catch (e:Dynamic) hxc.core.TypingError.FatalError.pass(e);
					try hxc.typing.TypeFields.installLazy(ctx) catch (e:Dynamic) hxc.core.TypingError.FatalError.pass(e);
					for (mt in m2.types) {
						var c:Null<TClass> = switch (mt) {
							case TClassDecl(c2) if (c2.path.name == typeName): c2;
							case TAbstractDecl(a) if (a.impl != null && a.path.name == typeName): a.impl;
							case _: null;
						};
						if (c == null) continue;
						var cf = c.statics.get(field);
						if (cf != null) {
							try hxc.typing.TypeFields.forceFieldBody(ctx, c, cf) catch (e:Dynamic) hxc.core.TypingError.FatalError.pass(e);
							hxc.typing.Typer.displayClassField(c, false, cf, fp);
						}
					}
				}
				for (part in path) {
					var isLower = part.name.length > 0 && part.name.charCodeAt(0) >= "a".code && part.name.charCodeAt(0) <= "z".code;
					if (mod != null && sub != null) {
						if (hxc.typing.Typer.atDisplayPos(part.pos)) staticField(sub, part.name, part.pos);
						return;
					}
					if (mod != null) {
						if (hxc.typing.Typer.atDisplayPos(part.pos)) {
							// A lowercase segment following the module names a static of its main type, not a subtype.
							if (isLower) staticField(mod, part.name, part.pos);
							else {
								var m2 = try loadModuleOpt(ctx, {pack: pack, name: mod}, part.pos) catch (_:Dynamic) null;
								if (m2 != null) for (mt in m2.types)
									if (TypeFunctions.tInfos(mt).path.name == part.name)
										hxc.typing.Typer.displayModuleType(ctx, mt, part.pos);
							}
							return;
						}
						if (isLower) return;
						sub = part.name;
						continue;
					}
					if (isLower) { pack.push(part.name); continue; }
					if (hxc.typing.Typer.atDisplayPos(part.pos)) {
						var m2 = try loadModuleOpt(ctx, {pack: pack, name: part.name}, part.pos) catch (_:Dynamic) null;
						if (m2 != null) for (mt in m2.types)
							if (TypeFunctions.tInfos(mt).path.name == part.name)
								hxc.typing.Typer.displayModuleType(ctx, mt, part.pos);
						return;
					}
					mod = part.name;
				}
				return;
			}
			if (!hxc.typing.Typer.displayToplevel && !hxc.typing.Typer.displayToplevelJson) return;
			var pack:Array<String> = [];
			var mod:Null<String> = null;
			var sub:Null<String> = null;
			for (part in path) {
				var isLower = part.name.length > 0 && part.name.charCodeAt(0) >= "a".code && part.name.charCodeAt(0) <= "z".code;
				var here = hxc.typing.Typer.atDisplayPos(part.pos);
				if (mod != null && sub != null) {
					if (here) throw new hxc.parser.Parser.TypePathCompletion(pack.concat([mod]), sub, true, part.pos);
					return;
				}
				if (mod != null && isLower) {
					if (here) throw new hxc.parser.Parser.TypePathCompletion(pack.concat([mod]), mod, true, part.pos);
					return;
				}
				if (mod != null) {
					if (here) throw new hxc.parser.Parser.TypePathCompletion(pack.copy(), mod, true, part.pos);
					sub = part.name;
					continue;
				}
				if (isLower) {
					// A single package segment completes all in-scope types; longer paths complete their parent
					// package.
					if (here) {
						if (pack.length == 0) hxc.typing.TypeResolve.answerTypeHintCompletion(ctx, part.pos);
						throw new hxc.parser.Parser.TypePathCompletion(pack.copy(), null, true, part.pos);
					}
					pack.push(part.name);
					continue;
				}
				if (here) throw new hxc.parser.Parser.TypePathCompletion(pack.copy(), null, true, part.pos);
				mod = part.name;
			}
		}

		function recordImport(imp:Import, declPos:Position):Void {
			// An empty import path completes the same in-scope type set as a type hint.
			if (imp.path.length == 0 && imp.mode.match(INormal)) {
				// Use an empty subject at the declaration end so CRImport inserts without replacing text.
				hxc.typing.TypeResolve.answerTypeHintCompletion(ctx,
					new Position(declPos.file, declPos.max, declPos.max), null, 8);
				return;
			}
			checkPathDisplay(imp.path);
			imports.rawImports.unshift(imp);
			var impIdx = imports.addImportPosition(declPos);
			var parts = [for (pn in imp.path) pn.name];
			switch (imp.mode) {
				case IAll:
					var split = splitImportPath(parts);
					if (split != null) imports.wildcards.unshift(split.modulePath);
					else if (parts.length > 0) imports.wildcards.unshift({pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]});
					imports.wildcardImp.unshift(impIdx);
					// Defer wildcard global imports until the type builds, skipping @:noImportGlobal. Package
					// wildcards contribute no globals.
					if (split != null && split.field == null) {
						var wpath = split.modulePath, wsub = split.sub, wIdx = impIdx;
						ctx.delay(hxc.context.Context.PBuildModule, function() {
							var mt = try ctx.getType(wpath, declPos, wsub) catch (_:Dynamic) return;
							// Follow typedefs before static lookup; report types that still offer no statics.
							switch (mt) {
								case TTypeDecl(td):
									try mt = TypeFunctions.moduleTypeOfType(TypeFunctions.follow(td.type)) catch (_:Dynamic) {}
								case _:
							}
							inline function put(name:String) imports.globals.set(name,
								{ownerPath: wpath, ownerSub: wsub, field: name, impIdx: wIdx});
							switch (mt) {
								case TClassDecl(cl) | TAbstractDecl({impl: cl}) if (cl != null):
									try hxc.typing.TypeResolve.resolveModule(ctx, cl.module) catch (e:Dynamic) hxc.core.TypingError.FatalError.pass(e);
									for (cf in cl.orderedStatics)
										if (!TypeFunctions.hasMeta(":noImportGlobal", cf.meta)) put(cf.name);
								case TEnumDecl(en):
									try hxc.typing.TypeResolve.resolveModule(ctx, en.module) catch (e:Dynamic) hxc.core.TypingError.FatalError.pass(e);
									for (name in en.names)
										if (!TypeFunctions.hasMeta(":noImportGlobal", en.constrs.get(name).meta)) put(name);
								case _:
									ctx.addDiagnostic("No statics to import from this type", declPos);
							}
						});
					}
				case INormal:
					var split = splitImportPath(parts);
					if (split == null) return;
					if (split.field != null) {
						imports.globals.set(split.field, {ownerPath: split.modulePath, ownerSub: split.sub, field: split.field, impIdx: impIdx});
						return;
					}
					var short = split.sub != null ? split.sub : split.modulePath.name;
					var ni:hxc.context.Context.ImportedName = {modulePath: split.modulePath, sub: split.sub, impIdx: impIdx};
					imports.names.set(short, ni);
					imports.order.push(ni);
				case IAsName(alias):
					var split = splitImportPath(parts);
					if (split == null) return;
					if (split.field != null) {
						imports.globals.set(alias.name, {ownerPath: split.modulePath, ownerSub: split.sub, field: split.field, impIdx: impIdx});
						return;
					}
					if (!(alias.name.charCodeAt(0) >= "A".code && alias.name.charCodeAt(0) <= "Z".code))
						ctx.addDiagnostic("Type aliases must start with an uppercase letter", alias.pos);
					var ni:hxc.context.Context.ImportedName = {modulePath: split.modulePath, sub: split.sub, aliased: true, aliasName: alias.name, aliasPos: alias.pos, impIdx: impIdx};
					imports.names.set(alias.name, ni);
					imports.order.push(ni);
			}
		}

		function recordUsing(path:Array<PlacedName>, declPos:Position):Void {
			if (path.length == 0) {
				// An empty using path inserts at the declaration end with CRUsing.
				hxc.typing.TypeResolve.answerTypeHintCompletion(ctx,
					new Position(declPos.file, declPos.max, declPos.max), null, 9);
				return;
			}
			checkPathDisplay(path);
			var impIdx = imports.addImportPosition(declPos);
			// Load using modules in declaration order alongside imports so unresolved usings report at their
			// declared position.
			imports.rawUsings.push({path: path, pos: declPos, idx: impIdx});
			var parts = [for (pn in path) pn.name];
			var split = splitImportPath(parts);
			if (split == null) return;
			var short = split.sub != null ? split.sub : split.modulePath.name;
			var namedModulePath = split.modulePath;
			if (split.sub != null && split.modulePath.pack.length == 0 && m.path.pack.length > 0)
				namedModulePath = {pack: m.path.pack, name: split.modulePath.name};
			var ni:hxc.context.Context.ImportedName = {modulePath: namedModulePath, sub: split.sub, impIdx: impIdx};
			imports.names.set(short, ni);
			imports.order.push(ni);
			function usingPath(modulePath:Path):Path {
				return split.sub != null ? {pack: modulePath.pack.concat([modulePath.name]), name: split.sub} : modulePath;
			}
			if (split.modulePath.pack.length == 0 && m.path.pack.length > 0) {
				var localModulePath:hxc.core.Globals.Path = {pack: m.path.pack, name: split.modulePath.name};
				imports.usings.push(usingPath(localModulePath));
				imports.usingImp.push(impIdx);
			}
			imports.usings.push(usingPath(split.modulePath));
			imports.usingImp.push(impIdx);
		}

		// Record the duplicate-name error, then raise Previous declaration here one level deeper at the
		// original declaration.
		function checkName(name:String, p:Position):Void {
			function err(prevPos:Position):Void {
				ctx.addDiagnostic("Name " + name + " is already defined in this module", p);
				throw new ContextError("... Previous declaration here", prevPos, 1);
			}
			for (t2 in decls) {
				if (TypeFunctions.tPath(t2).name == name)
					err(TypeFunctions.tInfos(t2).namePos);
			}
			for (s in statics) {
				if (s.d.dName.name == name)
					err(s.d.dName.pos);
			}
		}

		function hasAccess(flags:Array<PlacedAccess>, a:Access):Bool {
			for (f in flags) if (f.access == a) return true;
			return false;
		}

		function isOverloadExternFunction(d:Definition<PlacedAccess, ClassFieldKind>):Bool {
			return hasAccess(d.dFlags, AOverload) && hasAccess(d.dFlags, AExtern) && (switch (d.dData) {
				case FFun(_): true;
				case _: false;
			});
		}

		function hasOverloadExternStatic(name:String):Bool {
			for (s in statics) if (s.d.dName.name == name && isOverloadExternFunction(s.d)) return true;
			return false;
		}

		function checkStaticName(d:Definition<PlacedAccess, ClassFieldKind>):Void {
			if (isOverloadExternFunction(d) && hasOverloadExternStatic(d.dName.name)) {
				for (t2 in decls) {
					if (TypeFunctions.tPath(t2).name == d.dName.name)
						throw new ContextError("Name " + d.dName.name + " is already defined in this module", d.dName.pos);
				}
			} else {
				// Duplicate module fields use the field-duplicate error; collisions with module types use the
				// module-name error.
				for (s in statics) if (s.d.dName.name == d.dName.name)
					throw new ContextError("Duplicate module field declaration : "
						+ Context.sTypePath(m.path) + "." + d.dName.name, d.dName.pos);
				checkName(d.dName.name, d.dName.pos);
			}
		}

		// Private types live under the module's package plus `_<Module>`.
		function makePath(name:String, priv:Bool, p:Position):Path {
			checkName(name, p);
			if (name != m.path.name) {
				if (name.length == 0) ctx.addDiagnostic("Type name must not be empty.", p);
				else if (hxc.ast.Ast.isLowerIdent(name)) ctx.addDiagnostic("Type name should start with an uppercase letter: \"" + name + "\"", p);
				else if (StringTools.startsWith(name, "$")) ctx.addDiagnostic("Type names starting with a dollar are not allowed: \"" + name + "\"", p);
				else if (!hxc.core.StringHelper.isValidIdentifier(name)) ctx.addDiagnostic("\"" + hxc.core.StringHelper.sEscape(name) + "\" is not a valid type name.", p);
			}
			return priv ? {pack: m.path.pack.concat(["_" + m.path.name]), name: name}
			            : {pack: m.path.pack, name: name};
		}

		for (decl in tdecls) {
			var p = decl.pos;
			switch (decl.decl) {
				case EImport(imp):
					if (hasDeclaration)
						throw new ContextError("import and using may not appear after a declaration", p);
					recordImport(imp, p);

				case EUsing(path):
					if (hasDeclaration)
						throw new ContextError("import and using may not appear after a declaration", p);
					recordUsing(path, p);

				case EStatic(d):
					checkStaticName(d);
					hasDeclaration = true;
					statics.push({d: d, p: p});

				case EClass(d):
					var name = d.dName.name;
					hasDeclaration = true;
					var priv = hasClassFlag(d.dFlags, HPrivate);
					var path = makePath(name, priv, d.dName.pos);
					var patch = applyTypePatches(ctx, path, d.dMeta, d.dData);
					d.dMeta = patch.meta;
					d.dData = patch.fields;
					var c = TypeFunctions.mkClass(m, path, p, d.dName.pos);
					// forceBuild initializes heritage and fields once, returning Building on reentry. Synthetic
					// shells remain Built.
					c.build = function():BuildState return hxc.typing.TypeResolve.forceBuild(ctx, c);
					c.module = m;
					c.isPrivate = priv;
					c.doc = d.dDoc;
					c.meta = d.dMeta;
					if (TypeFunctions.hasMeta(":inheritDoc", d.dMeta)) {
						var cDoc = c;
						ctx.delay(Context.PConnectField, function() hxc.typing.InheritDoc.buildClassDoc(ctx, cDoc));
					}
					// Register type parameters before resolving other modules so their arity is already available.
					c.params = hxc.typing.Typeload.typeTypeParams(ctx, path, d.dParams, null, TPHType, m);
					if (hasClassFlag(d.dFlags, HAbstract)) TypeFunctions.addClassFlag(c, CAbstract);
					for (f in d.dFlags) switch (f) {
						case HExtern: TypeFunctions.addClassFlag(c, CExtern);
						case HInterface: TypeFunctions.addClassFlag(c, CInterface);
						case HFinal: TypeFunctions.addClassFlag(c, CFinal);
						case _:
					}
					if (TypeFunctions.hasMeta(":final", c.meta)) TypeFunctions.addClassFlag(c, CFinal);
					if (TypeFunctions.hasClassFlag(c, CInterface) && TypeFunctions.hasMeta(":structInit", c.meta))
						ctx.addDiagnostic("@:structInit is not allowed on interfaces", TypeFunctions.getMeta(":structInit", c.meta).pos);
					// KGenericBuild retains syntax fields for getBuildFields; ordinary @:generic classes use
					// KGeneric.
					if (TypeFunctions.hasMeta(":genericBuild", c.meta)) {
						if (ctx.isMacro)
							throw new ContextError("@:genericBuild cannot be used in macros", d.dName.pos);
						c.kind = KGenericBuild(d.dData);
					} else if (TypeFunctions.hasMeta(":generic", c.meta) && c.params.length > 0)
						c.kind = KGeneric;
					// Identify haxe.macro.MacroType by path after metadata kinds so KMacroType takes precedence.
					if (path.name == "MacroType" && path.pack.length == 2 && path.pack[0] == "haxe" && path.pack[1] == "macro")
						c.kind = KMacroType;
					// Register field shells before resolving their types and bodies.
					registerFields(c, d.dData, ctx);
					decls.push(TClassDecl(c));
					ctx.declOfType.set(Context.pathKey(path), {decl: decl.decl, pos: p});

				case EEnum(d):
					var name = d.dName.name;
					hasDeclaration = true;
					var priv = hasEnumFlag(d.dFlags, EPrivate);
					var path = makePath(name, priv, p);
					// Reject @:fakeEnum at the enum declaration position, excluding metadata.
					if (TypeFunctions.hasMeta(":fakeEnum", d.dMeta))
						throw new ContextError("@:fakeEnum enums is no longer supported in Haxe 4, use extern enum abstract instead", p);
					var patch = applyTypePatches(ctx, path, d.dMeta);
					for (p in ctx.typePatches) if (p.path.name == path.name && sameArray(p.path.pack, path.pack) && p.field != null)
						throw new ContextError("Field type patch not supported for enums", d.dName.pos);
					d.dMeta = patch.meta;
					var e:TEnum = {
						path: path,
						module: m,
						pos: p,
						namePos: d.dName.pos,
						doc: d.dDoc,
						meta: d.dMeta,
						params: hxc.typing.Typeload.typeTypeParams(ctx, path, d.dParams, null, TPHType, m),
						usings: [],
						restore: function() {},
						isPrivate: priv,
						isExtern: hasEnumFlag(d.dFlags, EExtern),
						constrs: new StringMap<TEnumField>(),
						names: [],
						type: enumModuleType(m, path, p)
					};
					if (TypeFunctions.hasMeta(":inheritDoc", d.dMeta)) {
						var eDoc = e;
						ctx.delay(Context.PConnectField, function() hxc.typing.InheritDoc.buildEnumDoc(ctx, eDoc));
					}
					decls.push(TEnumDecl(e));
					ctx.declOfType.set(Context.pathKey(path), {decl: decl.decl, pos: p});

				case ETypedef(d):
					var name = d.dName.name;
					checkName(name, p);
					hasDeclaration = true;
					var priv = hasEnumFlag(d.dFlags, EPrivate); // ETypedef uses EnumFlag in the AST
					var path = makePath(name, priv, p);
					var patch = applyTypePatches(ctx, path, d.dMeta);
					d.dMeta = patch.meta;
					var t = TypeFunctions.mkTypedef(m, path, p, d.dName.pos, TypeFunctions.mkMono());
					t.doc = d.dDoc;
					t.isPrivate = priv;
					t.meta = d.dMeta;
					t.params = hxc.typing.Typeload.typeTypeParams(ctx, path, d.dParams, null, TPHType, m);
					decls.push(TTypeDecl(t));
					ctx.declOfType.set(Context.pathKey(path), {decl: decl.decl, pos: p});

				case EAbstract(d):
					var name = d.dName.name;
					checkName(name, d.dName.pos);
					var priv = hasAbstractFlag(d.dFlags, AbPrivate);
					var path = makePath(name, priv, p);
					var patch = applyTypePatches(ctx, path, d.dMeta, d.dData);
					d.dMeta = patch.meta;
					d.dData = patch.fields;
					var a:TAbstract = {
						path: path, module: m, pos: p, namePos: d.dName.pos,
						isPrivate: priv, doc: d.dDoc, meta: d.dMeta, params: hxc.typing.Typeload.typeTypeParams(ctx, path, d.dParams, null, TPHType, m), usings: [],
						restore: function() {}, ops: [], unops: [], impl: null,
						thisType: TypeFunctions.mkMono(), from: [], fromField: [], to: [],
						toField: [], array: [], read: null, write: null, call: null,
						isEnum: hasAbstractFlag(d.dFlags, AbEnum) || TypeFunctions.hasMeta(":enum", d.dMeta)
					};
					// Inject :enum for enum abstracts lacking it; explicit @:enum instead reports deprecation.
					if (a.isEnum && !TypeFunctions.hasMeta(":enum", a.meta))
						a.meta = ([{name: ":enum", params: [], pos: Position.nullPos}] : Metadata).concat(a.meta)
					else if (TypeFunctions.hasMeta(":enum", d.dMeta))
						ctx.warning(hxc.core.WarningList.Warning.WDeprecatedEnumAbstract, hxc.core.WarningList.fromMeta(d.dMeta),
							"`@:enum abstract` is deprecated in favor of `enum abstract`", TypeFunctions.getMeta(":enum", d.dMeta).pos);
					if (TypeFunctions.hasMeta(":inheritDoc", a.meta)) {
						var aDoc = a;
						ctx.delay(Context.PConnectField, function() hxc.typing.InheritDoc.buildAbstractDoc(ctx, aDoc));
					}
					decls.push(TAbstractDecl(a));
					ctx.declOfType.set(Context.pathKey(path), {decl: decl.decl, pos: p});

					var isCore = TypeFunctions.hasMeta(":coreType", a.meta);
					if (!(d.dData.length == 0 && isCore)) {
						var aTParams:Array<TypeParamOrConst> = [
							for (tp in d.dParams) TPType({ct: CTPath({tpackage: [], tname: tp.tpName.name, tparams: [], tsub: null}), pos: p})
						];
						var aT:TypeHint = {ct: CTPath({tpackage: [], tname: d.dName.name, tparams: aTParams, tsub: null}), pos: p};
						var thisT:TypeHint = aT;
						for (fl in d.dFlags) switch (fl) { case AbOver(t): thisT = t; break; case _: }
						var implFields:Array<ClassField> = [for (f in d.dData) transformAbstractField(thisT, aT, a, f, ctx)];
						// Process the synthetic private implementation through the ordinary class pipeline, including
						// structural registration, type resolution and body typing.
						var implName = d.dName.name + "_Impl_";
						if (!hxc.core.StringHelper.isValidIdentifier(implName) && !StringTools.startsWith(implName, "$") && implName.length > 0 && !hxc.ast.Ast.isLowerIdent(implName))
							ctx.addDiagnostic("\"" + hxc.core.StringHelper.sEscape(implName) + "\" is not a valid type name.", p);
						var implPath:Path = {pack: m.path.pack.concat(["_" + m.path.name]), name: implName};
						// Copy whitelisted metadata in reverse order, including injected :enum. Keep @:keep on the
						// abstract so unused implementation classes can be removed.
						var implMeta:Metadata = [for (mm in a.meta)
							if (mm.name == ":using" || mm.name == ":build" || mm.name == ":coreApi"
								|| mm.name == ":allow" || mm.name == ":access" || mm.name == ":enum"
								|| mm.name == ":dce" || mm.name == ":native" || mm.name == ":hlNative"
								|| mm.name == ":jsRequire" || mm.name == ":pythonImport" || mm.name == ":expose"
								|| mm.name == ":deprecated" || mm.name == ":phpGlobal" || mm.name == ":publicFields") mm];
						implMeta.reverse();
						var implDef:Definition<ClassFlag, Array<ClassField>> = {
							// Use the abstract name's position for the implementation class; a declaration-wide span
							// would create false display matches on keywords and braces.
							dName: {name: implName, pos: d.dName.pos}, dDoc: null, dParams: [], dMeta: implMeta,
							dFlags: [HPrivate], dData: implFields
						};
						var implDecl:TypeDef = EClass(implDef);
						var c = TypeFunctions.mkClass(m, implPath, p, d.dName.pos);
						c.build = function():BuildState return Built;
						c.module = m;
						c.meta = implMeta;
						c.isPrivate = true;
						c.kind = KAbstractImpl(a);
						TypeFunctions.addClassFlag(c, CFinal);
						registerFields(c, implFields, ctx);
						decls.push(TClassDecl(c));
						ctx.declOfType.set(Context.pathKey(implPath), {decl: implDecl, pos: p});
						a.impl = c;
					}
			}
		}

		if (statics.length > 0) {
			// Use a zero-width position to mark the start of module statics.
			var firstPos = hxc.core.Globals.mkZeroRangePos(statics[0].p);
			var fieldsPath = makePath(m.path.name + "_Fields_", true, firstPos);
			var fields:Array<ClassField> = [
				for (s in statics) {
					cffName: s.d.dName,
					cffDoc: s.d.dDoc,
					cffPos: s.p,
					cffMeta: s.d.dMeta,
					cffAccess: [{access: AStatic, pos: Position.nullPos}].concat(s.d.dFlags),
					cffKind: s.d.dData
				}
			];
			var c = TypeFunctions.mkClass(m, fieldsPath, firstPos, firstPos);
			c.isPrivate = true;
			// Set CFinal before registerFields so visibility checks see it.
			c.kind = KModuleFields(m);
			TypeFunctions.addClassFlag(c, CFinal);
			// The eagerly built module-fields shell is loadable; its build hook returns Built.
			c.build = function():BuildState return Built;
			registerFields(c, fields);
			decls.push(TClassDecl(c));
			ctx.declOfType.set(Context.pathKey(fieldsPath), {decl: EClass({
				dName: {name: fieldsPath.name, pos: firstPos}, dDoc: null, dParams: [], dMeta: [],
				dFlags: [HPrivate], dData: fields
			}), pos: firstPos});
			m.statics = c;
		}

		if (keepTypes) m.types = m.types.concat(decls) else m.types = decls;
		applyGlobalMetadata(ctx, m, decls);
		ctx.moduleImports.set(Context.pathKey(m.path), imports);
		// Build import alias typedefs before their first use so display requests on the alias name have
		// an answer.
		for (ni in imports.order)
			if (ni.aliased == true && ni.aliasName != null && ni.aliasPos != null
					&& hxc.typing.Typer.atDisplayPos(ni.aliasPos))
				try resolveNamedImportType(ctx, m, ni.aliasName, ni.aliasPos) catch (_:Dynamic) {}
		// Share import records so later usage marks remain visible on the module.
		m.extra.display.importPositions = imports.importPositions;
	}

	static function applyGlobalMetadata(ctx:Context, m:ModuleDef, decls:Array<ModuleType>):Void {
		if (ctx.globalMetadata.length == 0) return;
		// Apply global metadata only to the host world; macro-world copies must not run host metadata
		// builds again.
		if (ctx.isMacro) return;
		function isLower(s:String):Bool {
			var c = s.charCodeAt(0);
			return !(c >= "A".code && c <= "Z".code);
		}
		function matchPath(recursive:Bool, sl:Array<String>, pattern:Array<String>):Bool {
			function loop(top:Bool, i1:Int, i2:Int):Bool {
				var r1 = sl.length - i1, r2 = pattern.length - i2;
				if (r1 == 0 && r2 == 0) return true;
				// Package-path patterns also match types within that package.
				if (r1 >= 2 && r2 == 1 && isLower(pattern[i2]) && !isLower(sl[i1 + 1]))
					return sl[i1] == pattern[i2];
				if (r1 == 1 && r2 == 0 && top) return true;
				if (r2 == 0) return recursive;
				if (r1 == 0) return false;
				return sl[i1] == pattern[i2] && loop(false, i1 + 1, i2 + 1);
			}
			return loop(true, 0, 0);
		}
		function fullDotPath(tpath:Path):Array<String> {
			return (m.path.pack.join(".") == tpath.pack.join(".") && m.path.name == tpath.name)
				? tpath.pack.concat([tpath.name])
				: m.path.pack.concat([m.path.name, tpath.name]);
		}
		for (mt in decls) {
			var info = TypeFunctions.tInfos(mt);
			var sl1 = fullDotPath(info.path);
			for (g in ctx.globalMetadata)
				if (g.toTypes && matchPath(g.recursive, sl1, g.filter)) info.meta.unshift(g.meta);
			switch (mt) {
				case TClassDecl(c):
					function applyField(cf:TClassField):Void {
						for (g in ctx.globalMetadata)
							if (g.toFields && matchPath(g.recursive, sl1.concat([cf.name]), g.filter)) cf.meta.unshift(g.meta);
					}
					for (cf in c.orderedFields) applyField(cf);
					for (cf in c.orderedStatics) applyField(cf);
					if (c.constructor != null) applyField(c.constructor);
				case _:
			}
		}
	}

	public static function rebuildFields(c:TClass, fields:Array<ClassField>, ?ctx:Context):Void {
		c.fields = new StringMap<TClassField>();
		c.statics = new StringMap<TClassField>();
		c.orderedFields = [];
		c.orderedStatics = [];
		c.constructor = null;
		// Drop diagnostics from the replaced field list; check the new fields during resolution.
		if (ctx != null) ctx.dropFieldDiagnostics(c);
		registerFields(c, fields, ctx);
	}

	static function classFieldIsStatic(c:TClass, cff:ClassField):Bool {
		var isStatic = false;
		for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
		if (!isStatic) switch (c.kind) {
			case KAbstractImpl(_) if (cff.cffName.name != "new"): isStatic = true;
			case _:
		}
		return isStatic;
	}

	static function classHasFieldDeclaration(c:TClass, cff:ClassField):Bool {
		var name = cff.cffName.name;
		if (!classFieldIsStatic(c, cff) && name == "new")
			return c.constructor != null;
		var table = classFieldIsStatic(c, cff) ? c.statics : c.fields;
		return table.exists(name);
	}

	static function sameClassPath(a:Path, b:Path):Bool {
		return a.name == b.name && sameArray(a.pack, b.pack);
	}

	// Bodyless native abstract operations are declarations only and do not register fields, allowing
	// repeated names.
	static function isAbsImplDeclOnly(c:TClass, cff:ClassField):Bool {
		var a = switch (c.kind) { case KAbstractImpl(ab): ab; case _: return false; };
		if (!cff.cffKind.match(FFun(_))) return false;
		switch (cff.cffKind) {
			case FFun(fd) if (fd.fExpr == null):
			case _: return false;
		}
		return TypeFunctions.hasMeta(":coreType", a.meta)
			|| TypeFunctions.hasMeta(":op", cff.cffMeta)
			|| TypeFunctions.hasMeta(":arrayAccess", cff.cffMeta)
			|| TypeFunctions.hasMeta(":resolve", cff.cffMeta);
	}

	// Unbuilt superclass instance fields are absent from lookup until their class builds.
	static function superHasInstanceField(sup:Null<{c:TClass, params:Array<T>}>, name:String):Bool {
		var cur = sup;
		while (cur != null) {
			if (cur.c.fields.exists(name)) return true;
			cur = cur.c.superClass;
		}
		return false;
	}

	static function classFieldHasBody(cff:ClassField):Bool {
		return switch (cff.cffKind) {
			case FFun(f): f.fExpr != null;
			case FVar(_, e) | FProp(_, _, _, e): e != null;
		}
	}

	public static function refreshClassFieldsFromCurrentDefines(ctx:Context, c:TClass):Array<ClassField> {
		var file = c.module != null && c.module.extra != null ? c.module.extra.file : null;
		if (file == null || file == "" || !FileSystem.exists(file)) return [];
		var src = Position.getFileContent(file);
		var pkg:Package = hxc.parser.Parser.parseModuleString(src, file, ctx.defines);
		reportDisplayParseError(ctx, file);
		if (!sameArray(pkg.pack, c.module.path.pack)) return [];
		for (td in pkg.decls) switch (td.decl) {
			case EClass(d):
				var priv = hasClassFlag(d.dFlags, HPrivate);
				var path:Path = priv
					? {pack: c.module.path.pack.concat(["_" + c.module.path.name]), name: d.dName.name}
					: {pack: c.module.path.pack, name: d.dName.name};
				if (!sameClassPath(path, c.path)) continue;
				var changed:Array<ClassField> = [];
				var missing:Array<ClassField> = [];
				var entry = ctx.declOfType.get(Context.pathKey(c.path));
				var oldD:Null<Definition<ClassFlag, Array<ClassField>>> = null;
				if (entry != null) switch (entry.decl) {
					case EClass(od): oldD = od;
					case _:
				}
				for (cff in d.dData) {
					if (!classHasFieldDeclaration(c, cff)) {
						missing.push(cff);
						changed.push(cff);
					} else if (oldD != null && classFieldHasBody(cff)) {
						for (i in 0...oldD.dData.length) {
							var old = oldD.dData[i];
							if (old.cffName.name == cff.cffName.name && classFieldIsStatic(c, old) == classFieldIsStatic(c, cff) && !classFieldHasBody(old)) {
								oldD.dData[i] = cff;
								changed.push(cff);
								break;
							}
						}
					}
				}
				if (missing.length > 0) {
					registerFields(c, missing);
					if (oldD != null)
						for (cff in missing) oldD.dData.push(cff);
				}
				return changed;
			case _:
		}
		return [];
	}

	public static function registerFields(c:TClass, fields:Array<ClassField>, ?ctx:Context):Void {
		function checkIfFeature(meta:Metadata):Array<String> {
			for (m in meta) if (m.name == ":ifFeature")
				return [for (p in m.params) switch (p.expr) {
					case EConst(CString(s, _)): s;
					case _: throw new ContextError("String expected", p.pos);
				}];
			return [];
		}
		var clIfFeature = checkIfFeature(c.meta);
		// Detect duplicate constructors within this declaration list only; build macros and abstract
		// implementations may register fresh lists on an existing class.
		var ctorRegistered = false;
		for (cff in fields) {
			var isStatic = false;
			var isExtern = false;
			var isFinalField = false;
			var explicitPublic = false, explicitPrivate = false;
			var overloadPos:Null<Position> = null;
			var abstractPos:Null<Position> = null;
			for (a in cff.cffAccess) switch (a.access) {
				case AStatic: isStatic = true;
				case AExtern: isExtern = true;
				case AFinal: isFinalField = true;
				case APublic: explicitPublic = true;
				case APrivate: explicitPrivate = true;
				case AOverload: overloadPos = a.pos;
				case AAbstract: abstractPos = a.pos;
				case _:
			}
			if (TypeFunctions.hasMeta(":final", cff.cffMeta)) isFinalField = true;
			if (TypeFunctions.hasMeta(":extern", cff.cffMeta)) isExtern = true;
			var isAbstractImplMember = false;
			if (!isStatic) switch (c.kind) {
				case KAbstractImpl(_): isStatic = true; isAbstractImplMember = true;
				case _:
			}
			var isPublic = explicitPrivate ? false
				: (explicitPublic
					|| TypeFunctions.hasClassFlag(c, CExtern)
					|| TypeFunctions.hasClassFlag(c, CInterface)
					|| TypeFunctions.hasMeta(":publicFields", c.meta)
					|| (switch (c.kind) { case KModuleFields(_): true; case _: false; }));
			var cf = TypeFunctions.mkField(cff.cffName.name, TypeFunctions.mkMono(), cff.cffPos, cff.cffName.pos, isPublic, isStatic);
			cf.doc = cff.cffDoc;
			cf.meta = cff.cffMeta;
			if (TypeFunctions.hasMeta(":inheritDoc", cff.cffMeta)) {
				var cDoc = c, cfDoc = cf;
				ctx.delay(Context.PTypeField, function() hxc.typing.InheritDoc.buildClassFieldDoc(ctx, cDoc, cfDoc));
			}
			// Abstract members carry CfImpl for receiver injection; only variables also carry :impl
			// metadata.
			if (TypeFunctions.hasMeta(":hxcImpl", cff.cffMeta) || TypeFunctions.hasMeta(":impl", cff.cffMeta))
				TypeFunctions.addClassFieldFlag(cf, CfImpl);
			// Abstract members carry CfImpl, including enum-abstract variables, whose CfEnum flag enables
			// inline folding.
			if (isAbstractImplMember) TypeFunctions.addClassFieldFlag(cf, CfImpl);
			// Set CfEnum on synthesized :enum fields so reads inline-fold and patterns participate in
			// exhaustiveness checks.
			if (TypeFunctions.hasMeta(":enum", cff.cffMeta)) TypeFunctions.addClassFieldFlag(cf, CfEnum);
			if (TypeFunctions.hasMeta(":generic", cff.cffMeta)) {
				TypeFunctions.addClassFieldFlag(cf, CfGeneric);
			}
			if (isExtern) TypeFunctions.addClassFieldFlag(cf, CfExtern);
			if (isFinalField) TypeFunctions.addClassFieldFlag(cf, CfFinal);
			if (c.module != null) {
				for (s in clIfFeature) c.module.extra.ifFeature.unshift({name: s, cls: c, cf: cf, b: isStatic});
				for (s in checkIfFeature(cff.cffMeta)) c.module.extra.ifFeature.unshift({name: s, cls: c, cf: cf, b: isStatic});
			}
			cf.kind = switch (cff.cffKind) {
				case FFun(_):
					var isInline = false, isDynamic = false, isMacro = false;
					for (a in cff.cffAccess) switch (a.access) {
						case AInline: isInline = true;
						case ADynamic: isDynamic = true;
						case AMacro: isMacro = true;
						case _:
					}
					Method(isMacro ? MethMacro : isInline ? MethInline : isDynamic ? MethDynamic : MethNormal);
				case FVar(_, _):
					// Inline variables are read-inline and write-never. Final instance fields permit constructor
					// writes; final statics permit none, and both carry CfFinal.
					var varInline = false;
					for (a in cff.cffAccess) if (a.access == AInline) varInline = true;
					varInline ? Var({read: AccInline, write: AccNever}) : isFinalField ? Var({read: AccNormal, write: isStatic ? AccNever : AccCtor}) : Var({read: AccNormal, write: AccNormal});
				case FProp(get, set, _, _):
					// Property reads and writes invoke get/set methods for AccCall. Defer display on accessor
					// names to PConnectField so sibling accessor methods exist.
					if (hxc.typing.Typer.atDisplayPos(get.pos) && get.name == "get")
						delayAccessorDisplay(ctx, c, "get_" + cff.cffName.name, get.pos, isStatic);
					if (hxc.typing.Typer.atDisplayPos(set.pos) && set.name == "set")
						delayAccessorDisplay(ctx, c, "set_" + cff.cffName.name, set.pos, isStatic);
					var vread = propAccess(get.name, true);
					var vwrite = propAccess(set.name, false);
					if (ctx != null) {
						// Report obsolete accessors after heritage resolves, retaining AccCall behavior.
						if (!knownPropAccess(get.name, true))
							ctx.deferFieldDiagnostic(c, cff.cffName.name + ": Custom property accessor is no longer supported, please use `get`", get.pos);
						if (!knownPropAccess(set.name, false))
							ctx.deferFieldDiagnostic(c, cff.cffName.name + ": Custom property accessor is no longer supported, please use `set`", set.pos);
						// Unlike recoverable accessor errors, a property with neither readable nor writable access
						// raises.
						if (vread == AccNever && vwrite == AccNever)
							throw new ContextError(cff.cffName.name + ": Unsupported property combination", cff.cffPos);
					}
					Var({read: vread, write: vwrite});
			}
			var isMethod = switch (cf.kind) { case Method(_): true; case _: false; };
			// Without native overload support, do not flag constructors as CfOverload; merging duplicate
			// constructors would create an unsupported shape. Record both errors without dropping the field.
			if (overloadPos != null) {
				if (ctx != null && ctx.platformConfig.supportsOverload) {
					TypeFunctions.addClassFieldFlag(cf, CfOverload);
				} else if (cf.name == "new") {
					if (ctx != null) ctx.addDiagnostic("Invalid modifier: overload on constructor", overloadPos);
					else throw new ContextError("Invalid modifier: overload on constructor", overloadPos);
				} else {
					TypeFunctions.addClassFieldFlag(cf, CfOverload);
					if (!TypeFunctions.hasClassFlag(c, CExtern) && !isExtern) {
						if (ctx != null) ctx.addDiagnostic("Invalid modifier: overload is only supported on extern functions", overloadPos);
						else throw new ContextError("Invalid modifier: overload is only supported on extern functions", overloadPos);
					}
				}
			}
				if (abstractPos != null) {
					if (cf.name == "new")
						throw new ContextError("Invalid modifier: abstract on constructor", abstractPos);
					// CfAbstract makes the C++ method virtual with a default body; without it, calls can target a
					// null function field.
					if (cf.kind.match(Method(_))) TypeFunctions.addClassFieldFlag(cf, CfAbstract);
				}
				if (TypeFunctions.hasClassFieldFlag(cf, CfImpl) && cf.kind.match(Method(MethDynamic)))
					throw new ContextError("Invalid modifier: dynamic on method of abstract", cff.cffPos);
			// Keep the first overload method as primary and prepend subsequent methods and their overloads.
			// Both primary and incoming methods must carry CfOverload.
			var dupTable = isStatic ? c.statics : c.fields;
			if (cf.name != "new" && TypeFunctions.hasClassFieldFlag(cf, CfOverload) && isMethod
					&& dupTable.exists(cf.name)) {
				var mainf = dupTable.get(cf.name);
				// The existing overload must also be a method with the modifier; report both conflicts at that
				// existing field.
				if (ctx != null) {
					if (mainf.kind.match(Var(_)))
						ctx.addDiagnostic("Cannot declare a variable with same name as a method", mainf.pos);
					if (!TypeFunctions.hasClassFieldFlag(mainf, CfOverload))
						ctx.addDiagnostic("Overloaded methods must have 'overload' accessor", mainf.pos);
				}
				mainf.overloads = [cf].concat(cf.overloads).concat(mainf.overloads);
				continue;
			}
			// Report at most one invalid-modifier or unexpected-expression error per field. For interface
			// methods with bodies, the body error takes precedence.
			var hadFieldError = false;
			function fieldError(msg:String, ep:Position):Void {
				if (hadFieldError || ctx == null) return;
				hadFieldError = true;
				// Choose the field's first error here, but defer reporting until the class build creates it.
				ctx.deferFieldDiagnostic(c, msg, ep);
			}
			var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
			var inlineAcc:Null<PlacedAccess> = null;
			var isMacroAcc = false;
			for (acc in cff.cffAccess) switch (acc.access) {
				case AInline: inlineAcc = acc;
				case AMacro: isMacroAcc = true;
				case _:
			}
			var bodyless = switch (cff.cffKind) {
				case FFun(fd): fd.fExpr == null;
				case _: true;
			};
			if (cff.cffName.name == "new" && isStatic) {
				fieldError("Invalid modifier: static on constructor", cff.cffPos);
				continue;
			}
			// Record an invalid constructor return type at the whole field, then drop the constructor; use
			// sites can also report that none exists.
			if (cff.cffName.name == "new") {
				var badRet = switch (cff.cffKind) {
					case FFun(fd) if (fd.fType != null):
						switch (fd.fType.ct) {
							case CTPath(tp) if (tp.tpackage.length == 0 && tp.tname == "Void"): false;
							case _: true;
						}
					case _: false;
				};
				if (badRet) {
					fieldError("A class constructor can't have a return type", cff.cffPos);
					continue;
				}
			}
			if (isInterface) {
				if (cff.cffName.name == "new" && !isStatic)
					throw new ContextError("An interface cannot have a constructor", cff.cffPos);
				if (!isStatic && cff.cffKind.match(FFun(_)) && !bodyless)
					fieldError("An interface method cannot have a body", cff.cffPos);
				if (inlineAcc != null) fieldError("Invalid modifier: inline on method of interface", cff.cffPos);
			}
			// Extern and interface bodies warn unless inline or macro. Require normally optional hints when
			// no body can infer their types; inline extern expressions are exempt.
			if (ctx != null) {
				var fieldIsExtern = false;
				for (acc in cff.cffAccess) if (acc.access == AExtern) fieldIsExtern = true;
				var trulyExtern = (TypeFunctions.hasClassFlag(c, CExtern) || fieldIsExtern) && inlineAcc == null;
				var needsHint = trulyExtern || isInterface;
				var coreApi = TypeFunctions.hasMeta(":coreApi", c.meta);
				var isFinalField = false;
				for (acc in cff.cffAccess) if (acc.access == AFinal) isFinalField = true;
				var isEnumAbstractMember = switch (c.kind) {
					case KAbstractImpl(ab): ab.isEnum;
					case _: false;
				};
				var isAbstractFn = false;
				for (acc in cff.cffAccess) if (acc.access == AAbstract) isAbstractFn = true;
				function requireHint(th:Null<TypeHint>, hp:Position):Void {
					if (th != null) return;
					if (needsHint) ctx.addDiagnostic("Type required for extern classes and interfaces", hp);
					else if (coreApi) ctx.addDiagnostic("Type required for core api classes", hp);
					else if (isAbstractFn) ctx.addDiagnostic("Type required for abstract functions", hp);
				}
				if (cff.cffName.name != "__init__") switch (cff.cffKind) {
					case FFun(fd):
						// Constructor returns are implicitly Void and need no hint.
						if (cff.cffName.name != "new") requireHint(fd.fType, cff.cffPos);
						for (fa in fd.fArgs) requireHint(fa.type, fa.name.pos);
					// Missing variable hints and initializers report at the name before extern checks. Bare
					// enum-abstract variables are exempt because the abstract supplies their type and value.
					case FVar(th, e) if (th == null && e == null && isEnumAbstractMember):
					// Leave uninitialized finals to their earlier-priority check in the later phase.
					case FVar(th, e) if (th == null && e == null && isFinalField):
					// Report a missing inline initializer before checking its type hint, at the whole field.
					case FVar(_, null) if (inlineAcc != null):
						fieldError("Inline variable must be initialized", cff.cffPos);
					case FVar(th, e) if (th == null && e == null):
						fieldError("Variable requires type-hint or initialization", cff.cffName.pos);
					case FProp(_, _, th, e) if (th == null && e == null):
						throw new ContextError("Property requires type-hint or initialization", cff.cffPos);
					// Extern variables cannot have initializers. Enum-abstract modifier checks take the
					// one-error-per-field slot first.
					case FVar(_, _) if (isEnumAbstractMember):
					case FVar(_, e) if (e != null && (TypeFunctions.hasClassFlag(c, CExtern) || fieldIsExtern)):
						if (!isStatic) fieldError("on extern non-static variable", cff.cffPos);
						else if (inlineAcc == null) fieldError("on extern non-inline variable", cff.cffPos);
					// Variable initializers infer their types; only functions and properties require explicit
					// hints here.
					case FVar(_, _):
					case FProp(_, _, th, _): requireHint(th, cff.cffPos);
				}
			}
			// Handle __init__ separately from ordinary extern-expression warnings.
			if (ctx != null && !bodyless && inlineAcc == null && !isMacroAcc
					&& cff.cffName.name != "__init__"
					// Include a field's own extern modifier and the AExtern added to @:multiType constructors.
					&& (isInterface || TypeFunctions.hasClassFlag(c, CExtern)
						|| [for (acc in cff.cffAccess) if (acc.access == AExtern) true].length > 0))
				ctx.warning(hxc.core.WarningList.Warning.WExternWithExpr, [],
					"Extern non-inline function may not have an expression", cff.cffPos);
			// Static interface fields warn before this error; instance interface fields report their body
			// error before warning.
			if (isInterface && isStatic && cff.cffName.name != "__init__"
					&& !TypeFunctions.hasClassFlag(c, CExtern) && !TypeFunctions.hasMeta(":libType", c.meta))
				throw new ContextError("You can only declare static fields in extern interfaces", cff.cffPos);
			// Inline variables must be static because their values are substituted without an instance.
			if (inlineAcc != null && !isStatic && cff.cffKind.match(FVar(_, _)))
				fieldError("Invalid modifier: inline on non-static variable", cff.cffPos);
			if (ctx != null && !TypeFunctions.hasClassFlag(c, CExtern) && cff.cffKind.match(FFun(_))) {
				var finalAcc:Null<PlacedAccess> = null;
				var staticAcc = false;
				for (acc in cff.cffAccess) switch (acc.access) {
					case AFinal: finalAcc = acc;
					case AStatic: staticAcc = true;
					case _:
				}
				if (finalAcc != null && staticAcc)
					ctx.addDiagnostic("Invalid modifier combination: final + static", finalAcc.pos);
			}
			if (ctx != null && !TypeFunctions.hasClassFlag(c, CExtern)) for (acc in cff.cffAccess) {
				var bad = switch [acc.access, cff.cffKind] {
					case [APublic | APrivate | AStatic | AFinal | AExtern, _]: null;
					case [ADynamic | AOverride | AMacro | AInline | AAbstract | AOverload, FFun(_)]: null;
					case [AInline, FVar(_, _)]: null;
					case [a, FVar(_, _)]: {name: accessName(a), kind: "variable"};
					case [a, FProp(_, _, _, _)]: {name: accessName(a), kind: "property"};
					case _: null;
				};
				if (bad != null)
					ctx.addDiagnostic("Invalid accessor '" + bad.name + "' for " + bad.kind + " " + cff.cffName.name, acc.pos);
			}
			// Check static/instance collisions after heritage resolves, in declaration order. Failed
			// heritage suppresses field diagnostics. Reject duplicate declarations except valid overloads
			// and declaration-only abstract operations.
			var declOnly = isAbsImplDeclOnly(c, cff);
			if (ctx != null && !declOnly && cf.name != "new" && dupTable.exists(cf.name)) {
				var kindPath = switch (c.kind) {
					case KAbstractImpl(a): {kind: "abstract", path: a.path};
					case _: {kind: "class", path: c.path};
				};
				// Drop duplicate declarations during registration but defer their diagnostics until class
				// build.
				ctx.deferFieldDiagnostic(c, "Duplicate " + kindPath.kind + " field declaration : "
					+ hxc.core.Globals.sTypePath(kindPath.path) + "." + cf.name, cf.namePos);
				ctx.droppedFieldDecls.set(cff, true);
				continue;
			}
			if (isStatic) {
				c.statics.set(cf.name, cf);
				c.orderedStatics.push(cf);
			} else if (cf.name == "new") {
				// A second constructor merges onto the first only where the target does native overload
				// resolution and both carry the flag; otherwise it is reported and the first one stands.
				if (!ctorRegistered || c.constructor == null) {
					c.constructor = cf;
					ctorRegistered = true;
				} else if (ctx != null && ctx.platformConfig.supportsOverload) {
					if (TypeFunctions.hasClassFieldFlag(cf, CfOverload) && TypeFunctions.hasClassFieldFlag(c.constructor, CfOverload))
						c.constructor.overloads.unshift(cf);
					else if (ctx != null)
						ctx.addDiagnostic("If using overloaded constructors, all constructors must be declared with 'overload'",
							TypeFunctions.hasClassFieldFlag(cf, CfOverload) ? c.constructor.pos : cf.pos);
				} else if (ctx != null) {
					ctx.addDiagnostic("Duplicate constructor", cff.cffPos);
				}
			} else {
				c.fields.set(cf.name, cf);
				c.orderedFields.push(cf);
			}
		}
	}

	static function accessName(a:Access):String {
		return switch (a) {
			case APublic: "public"; case APrivate: "private"; case AStatic: "static";
			case AOverride: "override"; case ADynamic: "dynamic"; case AInline: "inline";
			case AMacro: "macro"; case AFinal: "final"; case AExtern: "extern";
			case AAbstract: "abstract"; case AOverload: "overload";
		};
	}

	// Report the accessor field the identifier names, exactly as a field access to it would.
	static function delayAccessorDisplay(ctx:Context, c:TClass, name:String, p:Position, isStatic:Bool):Void {
		if (ctx == null) return;
		ctx.delay(Context.PConnectField, function() {
			var cf = isStatic ? c.statics.get(name) : c.fields.get(name);
			if (cf == null) return;
			var t = switch (cf.type) { case TLazy(r): TypeFunctions.lazyType(r); case t2: t2; };
			if (hxc.typing.Typer.displayDefinition && hxc.typing.Typer.displayFound == null)
				hxc.typing.Typer.displayFound = [cf.namePos];
			if ((hxc.typing.Typer.displayHover || hxc.typing.Typer.displayTypeDefinition)
					&& hxc.typing.Typer.hoverFound == null)
				hxc.typing.Typer.hoverFound = {t: t, p: p};
			if (hxc.typing.Typer.displayUsage && hxc.typing.Typer.usageTargetField == null)
				hxc.typing.Typer.usageTargetField = cf;
		});
	}

	// Map an `FProp` accessor identifier to a VarAccess. `isRead` selects the read-side vs write-side
	// defaults (only `get`/`set` differ: a custom `get`/`set` means "call `get_<name>`/`set_<name>`" =
	// AccCall). An unrecognized accessor (a custom method name) is no longer supported in Haxe -> AccCall.
	// The accessor identifiers each side accepts: `get` reads and `set` writes, so naming the wrong one is
	// as unsupported as inventing a name.
	static function knownPropAccess(id:String, isRead:Bool):Bool {
		return switch (id) {
			case "null" | "never" | "dynamic" | "default": true;
			case "get": isRead;
			case "set": !isRead;
			case _: false;
		};
	}

	static function propAccess(id:String, isRead:Bool):VarAccess {
		return switch (id) {
			case "null": AccNo;
			case "never": AccNever;
			case "dynamic": AccCall;
			case "default": AccNormal;
			case "get" if (isRead): AccCall;
			case "set" if (!isRead): AccCall;
			case _: AccCall;
		};
	}

	/** Inline equivalent: a private typedef `Enum<pack.Name>` whose type is a fresh mono. */
	static function enumModuleType(m:ModuleDef, path:Path, p:Position):TDef {
		var tpath:Path = {pack: [], name: "Enum<" + Context.sTypePath(path) + ">"};
		var t = TypeFunctions.mkTypedef(m, tpath, p, Position.nullPos, TypeFunctions.mkMono());
		t.isPrivate = true;
		return t;
	}

	// A type name belongs to one module per compilation. hxc reuses the macro context, so each entry
	// carries the epoch that made it and only the current one can be a redefinition. Clearing the map
	// instead would break @:generic instantiation, which looks modules up through it and needs the
	// entries the reused context still refers to. Reported at the module's position - for
	// Context.defineModule its first definition's.
	static function checkModuleTypes(ctx:Context, m:ModuleDef, mt:ModuleType, ?pos:Position):Void {
		if (pos == null) pos = Position.nullPos;
		var key = Context.pathKey(TypeFunctions.tPath(mt));
		var prev = ctx.typeToModule.get(key);
		if (prev == null || ctx.typeToModuleEpoch.get(key) != ctx.compilationEpoch) return;
		// There is no same-module exemption: `Context.defineType` of a name already defined this
		// compilation - the same module path included - is "Type name X is redefined from module X
		// (<sign>)". The lookup below reads the module the name was registered by, so the caller
		// registers after this check.
		var mPrev = ctx.moduleLut.get(Context.pathKey(prev));
		var hex1 = m.extra != null && m.extra.sign != null ? m.extra.sign : "";
		var hex2 = mPrev != null && mPrev.extra != null && mPrev.extra.sign != null ? mPrev.extra.sign : "";
		if (Context.pathKey(prev) != Context.pathKey(m.path)
				&& Context.sTypePath(prev).toLowerCase() == Context.sTypePath(m.path).toLowerCase())
			throw new ContextError("Module " + Context.sTypePath(prev) + " is loaded with a different case than "
				+ Context.sTypePath(m.path), pos);
		var s = hex1 == hex2 ? hex1 : "was " + hex2 + ", is " + hex1;
		throw new ContextError("Type name " + Context.sTypePath(TypeFunctions.tPath(mt))
			+ " is redefined from module " + Context.sTypePath(prev) + " (" + s + ")", pos);
	}

	static function addModule(ctx:Context, m:ModuleDef, ?pos:Position):Void {
		// The names are checked against what the tables hold before this module replaces it.
		for (mt in m.types) checkModuleTypes(ctx, m, mt, pos);
		ctx.moduleLut.set(Context.pathKey(m.path), m);
		ctx.modules.push(m);
		for (mt in m.types) {
			ctx.types.push(mt);
			ctx.typeToModule.set(Context.pathKey(TypeFunctions.tPath(mt)), m.path);
			ctx.typeToModuleEpoch.set(Context.pathKey(TypeFunctions.tPath(mt)), ctx.compilationEpoch);
		}
	}

	// A cache-reused module registers with the current compilation exactly like a freshly typed one (the
	// module lookup table + com.modules/types).
	public static function registerReusedModule(ctx:Context, m:ModuleDef):Void {
		addModule(ctx, m);
	}

	static function handleImportHx(ctx:Context, m:ModuleDef, decls:Array<TypeDecl>):Array<TypeDecl> {
		var file = m.extra.file;
		if (file == null || file == "" || !FileSystem.exists(file)) return decls;
		var dir = StringTools.replace(file, "\\", "/");
		var slash = dir.lastIndexOf("/");
		dir = slash < 0 ? "" : dir.substr(0, slash);
		var imports:Array<TypeDecl> = [];
		var count = m.path.pack.length + 1;
		for (_ in 0...count) {
			var candidate = dir == "" ? "import.hx" : dir + "/import.hx";
			if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) {
				var absoluteCandidate = FileSystem.fullPath(candidate);
				var pkg = hxc.parser.Parser.parseModuleString(Position.getFileContent(absoluteCandidate), absoluteCandidate, ctx.defines);
				for (decl in pkg.decls) switch (decl.decl) {
					case EImport(_) | EUsing(_):
					case _: throw new TypingError("Only import and using is allowed in import.hx files", decl.pos);
				}
				imports = pkg.decls.concat(imports);
			}
			var parent = dir.lastIndexOf("/");
			dir = parent < 0 ? "" : dir.substr(0, parent);
		}
		return imports.concat(decls);
	}

	static function typeModule(ctx:Context, mpath:Path, file:String, tdecls:Array<TypeDecl>):ModuleDef {
		var m = makeModule(ctx, mpath, file);
		// Register the module before creating its types; register those types after building.
		createModuleTypes(ctx, m, handleImportHx(ctx, m, tdecls));
		addModule(ctx, m);
		// Add the module, then initialize each declaration's type - which is where each imported module
		// loads. Registering first is what stops a pair of mutually importing modules from recursing.
		hxc.filters.ImportCheck.loadModuleImports(ctx, m);
		// Every module depends on StdTypes, and the per-module load_core_type "String" records a String
		// dependency too. .
		var std = ctx.moduleLut.get(Context.pathKey({pack: [], name: "StdTypes"}));
		if (std != null) {
			addDependency(m, std);
			var str = ctx.moduleLut.get(Context.pathKey({pack: [], name: "String"}));
			if (str != null) addDependency(m, str);
		}
		return m;
	}

	// The file a macro-created module is attributed to: the defining module's, falling back to
	// the one being typed. Only a module with no file at all keeps the placeholder.
	static function macroDefFile(ctx:Context, mdep:Null<ModuleDef>):String {
		var src = mdep != null ? mdep : ctx.currentModule;
		if (src == null || src.extra == null) return "<macro>";
		var f = src.extra.file;
		return (f == null || f == "") ? "<macro>" : f;
	}

	/** Register a macro-created type definition (`Context.defineType`) as a fake module. */
	public static function defineTypeDecl(ctx:Context, mpath:Path, decl:TypeDef, pos:Position, ?mdep:ModuleDef):ModuleDef {
		// A definition types against the file of the module named by the moduleDependency argument, or of
		// the CALLING module when there is none. That file is what the server's file check then watches, so
		// the fake module goes dirty when its definer is edited. A placeholder name cannot be stat-ed, and
		// hxcpp reports a failed stat as mtime 0 rather than raising, so it would compare equal to the 0
		// recorded at creation and the module would read as reusable on every request forever.
		var m = typeModule(ctx, mpath, macroDefFile(ctx, mdep), [{decl: decl, pos: pos}]);
		// The path check applies to Context.defineType too.
		checkModulePath(ctx, mpath, pos);
		m.extra.kind = MFake;
		if (Sys.getEnv("HXC_DEBUG_TNF") != null) Sys.println("[tnf] CLEAR " + (ctx.isMacro ? "macro" : "host") + " define");
		ctx.moduleNonexistentLut.clear(); // Clear the host and macro worlds' shared memo in place.
		return m;
	}

	/** Add macro-created declarations to an existing module without replacing its types. */
	public static function addTypeDeclsToModule(ctx:Context, m:ModuleDef, types:Array<TypeDecl>, imports:Array<Import>, usings:Array<PlacedTypePath>, pos:Position):Array<ModuleType> {
		var decls:Array<TypeDecl> = [];
		for (imp in imports) decls.push({decl: EImport(imp), pos: pos});
		for (u in usings) {
			var names = u.path.tpackage.concat([u.path.tname]);
			if (u.path.tsub != null) names.push(u.path.tsub);
			decls.push({decl: EUsing([for (n in names) ({name: n, pos: u.pos} : PlacedName)]), pos: u.pos});
		}
		decls = decls.concat(types);
		var old = m.types;
		createModuleTypes(ctx, m, handleImportHx(ctx, m, decls));
		var added = m.types;
		m.types = old.concat(added);
		for (mt in added) {
			m.types.push(mt);
			ctx.types.push(mt);
			checkModuleTypes(ctx, m, mt, pos);
			ctx.typeToModule.set(Context.pathKey(TypeFunctions.tPath(mt)), m.path);
			ctx.typeToModuleEpoch.set(Context.pathKey(TypeFunctions.tPath(mt)), ctx.compilationEpoch);
		}
		return added;
	}

	/** Register a macro-created module (`Context.defineModule`) from decoded AST declarations. */
	public static function defineModuleDecls(ctx:Context, mpath:Path, types:Array<TypeDecl>, imports:Array<Import>, usings:Array<PlacedTypePath>, pos:Position, ?mdep:ModuleDef):ModuleDef {
		var decls:Array<TypeDecl> = [];
		for (imp in imports) decls.push({decl: EImport(imp), pos: pos});
		for (u in usings) {
			var names = u.path.tpackage.concat([u.path.tname]);
			if (u.path.tsub != null) names.push(u.path.tsub);
			decls.push({decl: EUsing([for (n in names) ({name: n, pos: u.pos} : PlacedName)]), pos: u.pos});
		}
		decls = decls.concat(types);
		// Use the calling module's file, as defineTypeDecl does.
		var m = typeModule(ctx, mpath, macroDefFile(ctx, mdep), decls);
		// The path check reports at the first decoded type's position.
		checkModulePath(ctx, mpath, types.length > 0 ? types[0].pos : pos);
		m.extra.kind = MFake;
		if (Sys.getEnv("HXC_DEBUG_TNF") != null) Sys.println("[tnf] CLEAR " + (ctx.isMacro ? "macro" : "host") + " define");
		ctx.moduleNonexistentLut.clear(); // Clear the host and macro worlds' shared memo in place.
		return m;
	}

	// A created module validates its name after its declarations type.
	static function checkModulePath(ctx:Context, mpath:Path, p:Position):Void {
		var name = mpath.name;
		var full = hxc.core.StringHelper.sEscape(mpath.pack.length == 0 ? name : mpath.pack.join(".") + "." + name);
		var prepend = "Module \"" + full + "\" does not have a valid name. ";
		if (name.length == 0)
			ctx.addDiagnostic(prepend + "Module name must not be empty.", p);
		else if (hxc.ast.Ast.isLowerIdent(name))
			ctx.addDiagnostic(prepend + "Module name should start with an uppercase letter: \"" + name + "\"", p);
		else if (StringTools.startsWith(name, "$"))
			ctx.addDiagnostic(prepend + "Module names starting with a dollar are not allowed: \"" + name + "\"", p);
		else if (!isValidIdentName(name))
			ctx.addDiagnostic(prepend + "\"" + hxc.core.StringHelper.sEscape(name) + "\" is not a valid module name.", p);
		// Each package part validates; the first failure reports as a pair.
		for (part in mpath.pack) {
			var err = packagePartError(part);
			if (err != null) {
				ctx.addDiagnostic("\"" + hxc.core.StringHelper.sEscape(mpath.pack.join(".")) + "\" is not a valid package name:", p);
				ctx.addDiagnostic(err, p);
				break;
			}
		}
	}

	// The package name check, invalid characters included.
	static function packagePartError(x:String):Null<String> {
		if (x.length == 0) return "Package name must not be empty";
		var c0 = x.charCodeAt(0);
		if ((c0 < "a".code || c0 > "z".code) && c0 != "_".code) return "Package name must start with a lowercase letter";
		for (i in 1...x.length) {
			var c = x.charCodeAt(i);
			var ok = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code)
				|| (c >= "0".code && c <= "9".code) || c == "_".code || c == ".".code;
			if (!ok) return "Invalid character: " + hxc.core.StringHelper.sEscape(x.charAt(i));
		}
		return null;
	}

	// Identifier validity by character shape only; keyword names cannot reach a module path.
	static function isValidIdentName(s:String):Bool {
		if (s.length == 0) return false;
		inline function isAlphaUnderscore(c:Int) return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code;
		if (!isAlphaUnderscore(s.charCodeAt(0))) return false;
		for (i in 1...s.length) {
			var c = s.charCodeAt(i);
			if (!isAlphaUnderscore(c) && !(c >= "0".code && c <= "9".code)) return false;
		}
		return true;
	}

	/**
	 * Return the already-loaded module, else find its source on the class path, parse it, and register
	 * all its declarations. Raises
	 * `ContextError(ModuleNotFound)` when no source file exists.
	 */
	// Record mdep in m's deps (self and null-module loads record nothing).
	public static function addDependency(m:Null<ModuleDef>, mdep:ModuleDef):Void {
		if (m == null || m == mdep) return;
		if (Sys.getEnv("HXC_TRACE_DEPS") != null)
			Sys.println("[dep] " + m.path.pack.concat([m.path.name]).join(".") + " -> " + mdep.path.pack.concat([mdep.path.name]).join("."));
		m.extra.deps.set(mdep.id, mdep);
		// Adding a dependency also clears the POST-PROCESSING mark: a module whose dependency set changed
		// runs the filters again, which retakes its class state snapshot - so a @:generic specialization
		// another module adds to it is IN that snapshot. hxc's own resolve gate is deliberately left alone;
		// clearing it mid-typing re-derives signatures the bodies have already bound.
		m.extra.processed = 0;
	}

	// While a module is retyped, only modules already cached may load.
	public static var loadOnlyCachedModules:Bool = false;

	// Null for "no such module". The three not-found exits below each built a "Type not found : <path>"
	// ContextError (a string concatenation per probe) and threw it ~39.5k times per unit-suite compile,
	// almost all consumed by the unqualified-resolution walk probing package prefixes that do not exist.
	// Genuine errors (parse failures, duplicate declarations) still raise from inside typeModule and
	// propagate unchanged. the first type declared (imports and usings skipped) and its metadata.
	static function hasNoPackageRestrict(decls:Array<hxc.ast.Ast.TypeDecl>):Bool {
		for (d in decls) {
			var meta:Array<hxc.ast.Ast.MetadataEntry> = switch (d.decl) {
				case EClass(def): def.dMeta;
				case EEnum(def): def.dMeta;
				case EAbstract(def): def.dMeta;
				case ETypedef(def): def.dMeta;
				case EStatic(def): def.dMeta;
				case EImport(_) | EUsing(_): continue;
			};
			for (mm in meta) if (mm.name == ":noPackageRestrict") return true;
			return false;
		}
		return false;
	}

	static function addForbidReference(fp:hxc.core.TypingError.ForbidPackage, p:Position):Void {
		if (p != null && !(p.file == Position.nullPos.file && p.min < 0 && p.max < 0)) fp.addReference(p);
	}

	public static function loadModule(ctx:Context, m:Path, p:Position):ModuleDef {
		var r = loadModuleOpt(ctx, m, p);
		if (r == null) {
			m = ctx.remapPath(m);
			throw new ContextError("Type not found : " + Context.sTypePath(m), p, ModuleNotFound(m));
		}
		return r;
	}

	public static function loadModuleOpt(ctx:Context, m:Path, p:Position):Null<ModuleDef> {
		m = ctx.remapPath(m);
		var key = Context.pathKey(m);
		var existing = ctx.moduleLut.get(key);
		// Every module load records the loaded module as a dependency of the requesting module.
		if (existing != null) { addDependency(ctx.currentModule, existing); return existing; }
		// While a compilation server request runs, a cache-valid module is reused instead of parsed.
		if (hxc.context.ServerCache.enabled) {
			var cached = hxc.context.ServerCache.typeModule(ctx, m, p);
			if (cached != null) { addDependency(ctx.currentModule, cached); return cached; }
		}
		// While a module is being RETYPED nothing new may be loaded - a path that is not already cached is
		// what tells the retyper its signature depends on something the compilation no longer has (Could
		// not load).
		if (loadOnlyCachedModules)
			return null;
		if (ctx.moduleNonexistentLut.exists(key)) {
			if (Sys.getEnv("HXC_DEBUG_TNF") != null) Sys.println("[tnf] memo-hit " + (ctx.isMacro ? "macro" : "host") + " " + key + " n=" + Lambda.count(ctx.moduleNonexistentLut) + " from=" + (ctx.currentModule == null ? "null" : hxc.core.Globals.sTypePath(ctx.currentModule.path)));
			return null;
		}

		var file:String;
		var externDecls:Null<Array<hxc.ast.Ast.TypeDecl>> = null;
		try {
			file = resolveModuleFile(ctx, m, p);
		} catch (e:ContextError) {
			// Nothing to parse, so the extern-type loaders get a turn. The first one that answers names the
			// module's file; only an exhausted list is not-found.
			file = null;
			if (Sys.getEnv("HXC_DEBUG_TNF") != null) Sys.println("[tnf] miss " + (ctx.isMacro ? "macro" : "host") + " " + key + " hooks=" + ctx.loadExternType.length + " n=" + Lambda.count(ctx.moduleNonexistentLut) + " from=" + (ctx.currentModule == null ? "null" : hxc.core.Globals.sTypePath(ctx.currentModule.path)));
			for (h in ctx.loadExternType) {
				var r = h.load(m, p);
				if (r != null) { file = h.name; externDecls = r; break; }
			}
			if (externDecls == null) {
				ctx.moduleNonexistentLut.set(key, true);
				return null;
			}
		}

		// The decls the loader produced are typed as an extern module.
		if (externDecls != null) {
			var requester0 = ctx.currentModule;
			var loaded0 = try typeModule(ctx, m, file, externDecls) catch (fp:hxc.core.TypingError.ForbidPackage) { addForbidReference(fp, p); throw fp; };
			loaded0.extra.kind = MExtern;
			addDependency(requester0, loaded0);
			return loaded0;
		}

		// The file resolved, but open_in_bin failed - a directory named like a module, an unreadable
		// file. Not a missing type.
		var src = try moduleFileContent(ctx, file) catch (_:Dynamic) throw new ContextError("Could not open " + file, p);
		var pkg:Package = hxc.parser.Parser.parseModuleString(src, file, ctx.defines);
		reportDisplayParseError(ctx, file);
		hxc.context.ServerCache.cacheParsedFile(ctx, file, pkg.pack, pkg.decls);
		// A module whose first package segment another platform owns is refused once its file resolves,
		// unless the first type declared carries @:noPackageRestrict; the platform named is the macro
		// world's "macro" .
		if (m.pack.length > 0 && ctx.forbiddenPackages.exists(m.pack[0]) && !hasNoPackageRestrict(pkg.decls))
			throw new hxc.core.TypingError.ForbidPackage(m.pack[0], m, p, ctx.isMacro ? "macro" : hxc.core.Globals.platformName(ctx.platform));
		// Checks the declared `package` matches the requested pack.
		if (!sameArray(pkg.pack, m.pack)) {
			// Two messages, chosen by whether the module was asked for by position or from the command line
			// (a null position), and both are recorded and let typing continue rather than aborting - the
			// compile goes on to report what the mismatched module could not resolve.
			if (p == null || (p.min < 0 && p.max < 0 && p.file == Position.nullPos.file)) {
				ctx.addDiagnostic("Invalid commandline class : " + Context.sTypePath(m)
					+ " should be " + Context.sTypePath({pack: pkg.pack, name: m.name}), p);
			} else {
				var spack = function(l:Array<String>)
					return l.length == 0 ? "`package;`" : "`package " + l.join(".") + ";`";
				ctx.addDiagnostic(spack(pkg.pack) + " in " + file + " should be " + spack(m.pack),
					new Position(p.file, p.min, p.min));
			}
		}
		var requester = ctx.currentModule;
		// A forbidden package met while typing this module adds the position this module was requested at
		// ("referenced here"), unless that is the null position.
		var loaded = try typeModule(ctx, m, file, pkg.decls) catch (fp:hxc.core.TypingError.ForbidPackage) { addForbidReference(fp, p); throw fp; };
		addDependency(requester, loaded);
		return loaded;
	}

	// The first syntax error a DISPLAY file parse recorded is reported. A diagnostics run reports it
	// as a parser-error diagnostic instead of aborting, which is how a file with a syntax error still
	// gets a report.
	static function reportDisplayParseError(ctx:Context, file:String):Void {
		if (hxc.parser.Parser.syntaxErrors.length == 0) return;
		if (!hxc.parser.Parser.matchesDisplayFile(file)) return;
		if (ctx.displaySpec == null || ctx.displaySpec.indexOf("@diagnostics") < 0) return;
		var e = hxc.parser.Parser.syntaxErrors[0];
		ctx.diagnostics.push({message: hxc.parser.ParserError.errorMsg(e.msg), pos: e.pos, depth: 0,
			severity: hxc.core.Globals.MessageSeverity.Error, kind: 4});
	}

	public static function loadTypeDef(ctx:Context, path:Path, p:Position, ?sub:String):ModuleType {
		if (hxc.core.PerfCount.on) hxc.core.PerfCount.bump("loadTypeDef");
		var tname = sub != null ? sub : path.name;
		// In-module sibling type: a bare unqualified name (no pack, no sub) is resolved
		// `ctx.m.curmod` before the filesystem). This makes a module-level `enum`/class/etc.
		// Declared alongside the main class resolvable without a same-named `.hx` file.
		if (sub == null && path.pack.length == 0 && ctx.currentModule != null) {
			for (mt in ctx.currentModule.types) {
				if (TypeFunctions.tInfos(mt).path.name == tname) return mt;
			}
			// The module's own types and then its local IMPORTS are checked, both before any filesystem
			// lookup. Going to disk first would make an imported name that also names a root module load
			// that module too: `import haxe.ds.List` in Lambda would pull in the root List typedef as well.
			var imported = resolveNamedImportType(ctx, ctx.currentModule, tname, p);
			if (imported != null) return imported;
		}
		// An unqualified path, with or without a sub-type, walks the current PACKAGE up to the root, the
		// root last. Trying the root first would let a root `Printer.hx` shadow haxe.macro.Printer inside
		// package haxe.macro, and make the root miss one more path for the extern-type loaders.
		// resolveBareType is that walk, with the wildcard imports and the implicit StdTypes import ahead
		// of it.
		if (path.pack.length == 0 && ctx.currentModule != null) {
			if (sub == null) {
				var r = resolveBareType(ctx, ctx.currentModule, tname, p);
				if (r != null) return r;
			} else {
				var cpack = ctx.currentModule.path.pack;
				var i = cpack.length;
				while (i >= 1) {
					var r = tryLoadSub(ctx, {pack: cpack.slice(0, i), name: path.name}, sub, p);
					if (r != null) return r;
					i--;
				}
			}
		}
		try {
			var m = loadModule(ctx, path, p);
			return findTypeInModule(ctx, m, tname, p);
		} catch (e:ContextError) {
			// Bare unqualified type (empty pack, no sub) with no own `Name.hx`: it may be a sub-type of an
			// implicitly-imported module. The core types in StdTypes (Void/Int/Float/Bool/Null/Dynamic/...)
			// are accessible by bare name via the implicit `import StdTypes`.
			switch (e.kind) {
				case ModuleNotFound(_) | TypeNotFound(_) if (sub == null && path.pack.length == 0 && path.name != "StdTypes"):
					// The walk above found nothing (or there is no current module yet): the one
					// implicit import left is StdTypes itself, read here while it is still being
					// bootstrapped and resolveBareType cannot see it in the LUT.
					var std = loadModule(ctx, {pack: [], name: "StdTypes"}, p);
					try {
						return findTypeInModule(ctx, std, tname, p);
					} catch (_:ContextError) {
						throw e; // Surface the original (more specific) error
					}
				case ModuleNotFound(_) if (sub == null && path.pack.length >= 1 && isModuleName(path.pack[path.pack.length - 1])):
					// A flattened sub-type path (pack ends in the module name, `name` is the sub-type, e.g.
					// `pack.Module.Sub` stored as {pack: [pack, Module], name: Sub}) has no module file of
					// its own; resolve the module from the last pack segment and find the sub-type in it.
					// Only a CAPITALISED segment can be that module: the grammar ends the package at the
					// first one, and a qualified type loads (pack, name) alone, so `nope.Missing` never
					// asks the not-found hook about a module `nope`.
					var mname = path.pack[path.pack.length - 1];
					var mpack = path.pack.slice(0, path.pack.length - 1);
					var m = try loadModuleOpt(ctx, {pack: mpack, name: mname}, p) catch (_:ContextError) null;
					if (m != null) {
						try { return findTypeInModule(ctx, m, path.name, p); } catch (_:ContextError) {}
					}
					throw e;
				case _:
					throw e;
			}
		}
	}

	static function isModuleName(seg:String):Bool {
		if (seg.length == 0) return false;
		var c = seg.charCodeAt(0);
		return c >= "A".code && c <= "Z".code;
	}

	// The first type of that name decides. Reaching a private one from outside its own module and
	// finding none at all are two different errors, with two different wordings.
	public static function findTypeInModule(ctx:Context, m:ModuleDef, tname:String, p:Position):ModuleType {
		for (mt in m.types) {
			var info = TypeFunctions.tInfos(mt);
			if (info.path.name != tname) continue;
			if (ctx.currentModule != info.module && info.isPrivate)
				throw new ContextError("Cannot access private type " + tname + " in module " + Context.sTypePath(m.path),
					p, TypeNotFound({pack: m.path.pack, name: tname}));
			return mt;
		}
		throw new ContextError("Module " + Context.sTypePath(m.path) + " does not define type " + tname,
			p, TypeNotFound({pack: m.path.pack, name: tname}));
	}

	/** (non-raising): the public sub-type named `tname` in `m`, or null. */
	public static function findTypeInModuleOpt(m:ModuleDef, tname:String):Null<ModuleType> {
		for (mt in m.types) {
			var info = TypeFunctions.tInfos(mt);
			if (!info.isPrivate && info.path.name == tname) return mt;
		}
		return null;
	}

	public static function resolveQualifiedType(ctx:Context, cur:ModuleDef, path:Path, p:Position):Null<ModuleType> {
		if (cur == null) return null;

		function fullMatch(mt:ModuleType):Bool {
			var tp = TypeFunctions.tInfos(mt).path;
			return tp.name == path.name && samePack(tp.pack, path.pack);
		}

		for (mt in cur.types) {
			if (!TypeFunctions.tInfos(mt).isPrivate && fullMatch(mt)) return mt;
		}

		var imports = ctx.moduleImports.get(Context.pathKey(cur.path));
		if (imports != null) {
			// Named imports: a `import M;` (sub == null) exposes every sub-type of M by its full path. Load
			// each such module and search its types for a full-path match.
			for (key in imports.names.keys()) {
				var ni = imports.names.get(key);
				if (ni.sub != null) {
					// `import M.Sub;` binds only that sub-type, match its full path directly.
					var r = tryLoadSubFull(ctx, ni.modulePath, path, p);
					if (r != null) { imports.markImport(ni.impIdx); return r; }
					continue;
				}
				var m = { var _m = try loadModuleOpt(ctx, ni.modulePath, p) catch (_:ContextError) null; if (_m == null) continue; _m; };
				for (mt in m.types) if (!TypeFunctions.tInfos(mt).isPrivate && fullMatch(mt)) { imports.markImport(ni.impIdx); return mt; }
			}
			for (wp in imports.wildcards) {
				var m = { var _m = try loadModuleOpt(ctx, wp, p) catch (_:ContextError) null; if (_m == null) continue; _m; };
				for (mt in m.types) if (!TypeFunctions.tInfos(mt).isPrivate && fullMatch(mt)) { imports.markWildcard(wp); return mt; }
			}
		}
		return null;
	}

	// Load module `mp`, return its sub-type whose full path == `want` (or null). Used by the
	// qualified-path-via-imports resolver above.
	static function tryLoadSubFull(ctx:Context, mp:Path, want:Path, p:Position):Null<ModuleType> {
		var m = try loadModuleOpt(ctx, mp, p) catch (_:ContextError) return null;
		if (m == null) return null;
		for (mt in m.types) {
			var tp = TypeFunctions.tInfos(mt).path;
			if (tp.name == want.name && samePack(tp.pack, want.pack)) return mt;
		}
		return null;
	}

	// Named imports: `import M.Sub` / `import M as X` bind their short name; `import M` also exposes every
	// sub-type of M by its own name. An aliased import binds only its alias, never the module's own type
	// names.
	public static function resolveNamedImportType(ctx:Context, cur:ModuleDef, name:String, p:Position):Null<ModuleType> {
		var imports = ctx.moduleImports.get(Context.pathKey(cur.path));
		if (imports == null) return null;
		// A PRIVATE type never binds through an import from another module: the import itself is the error,
		// and the name stays unbound.
		inline function visible(r:Null<ModuleType>):Null<ModuleType>
			return r == null ? null : (TypeFunctions.tInfos(r).isPrivate && TypeFunctions.tInfos(r).module != cur ? null : r);
		// A module import with no sub exposes every non-private type of that module by its own name,
		// prepended at that import's position. So which import wins is decided by declaration order alone
		// - it makes no difference whether the name is the module's own or one of its sub-types. Looking
		// the exact name up first instead would let an earlier import beat a later one: `import.hx`
		// bringing in haxe.io.Path would shadow the module's own `import haxe.rtti.CType`, whose Path is
		// the one that binds.
		var named:Null<hxc.context.Context.ImportedName> = null;
		var k = imports.order.length - 1;
		while (k >= 0) {
			var ni = imports.order[k--];
			// An ALIAS binds its alias name and nothing else; a SUB-import binds that sub name.
			if (ni.aliased == true && ni.aliasName != null) {
				if (ni.aliasName == name) { named = ni; break; }
				continue;
			}
			if (ni.sub != null) {
				if (ni.sub == name) { named = ni; break; }
				continue;
			}
			// A plain module import exposes the module's TYPES by their own names - it does not bind the
			// module name. Treating the module name as a short name here claimed `FieldAccess` for
			// `import hxc.typing.FieldAccess`, a module whose types are FieldAccessMode/AccessorResolution/
			// FieldAccessTools and which has no type of that name at all, and the break then hid the earlier
			// `import hxc.typing.AccessKind` that really does declare `typedef FieldAccess`. A module that
			// does have a same-named type still resolves, through this same probe.
			var rsub = visible(tryLoadSub(ctx, ni.modulePath, name, p));
			if (rsub != null) { imports.markImport(ni.impIdx); return rsub; }
		}
		if (named == null) named = imports.names.get(name);
		if (named != null) {
			// Alias/sub or module-name exact binding. An aliased module import binds the module's
			// main type, not a type named after the alias.
			var sub = named.sub != null ? named.sub : named.modulePath.name;
			var r = visible(tryLoadSub(ctx, named.modulePath, sub, p));
			// `import X in Y` binds Y to a TEMP PRIVATE typedef at (pack + ["_" + module], Y) over the
			// built instance, not to X directly, so signatures resolved through the alias print the typedef.
			// It is never registered in the module.
			if (r != null && named.aliased == true && named.aliasName != null) {
				if (named.aliasTypedef == null) {
					var mi = TypeFunctions.tInfos(r);
					// The instance snapshot needs the heritage linked first. Here that means resolving the
					// target module (idempotent, gated by resolved): an alias used before that module was
					// resolved would otherwise capture the class with superClass still unset, and the alias
					// then fails to unify with its own supertypes.
					try hxc.typing.TypeResolve.resolveModule(ctx, mi.module) catch (e:Dynamic) hxc.core.TypingError.FatalError.pass(e);
					var tPath:Path = {pack: mi.module.path.pack.concat(["_" + mi.module.path.name]), name: named.aliasName};
					// The typedef sits at the ALIAS's own position, which is the declaration every request
					// through the alias reports.
					var tp = named.aliasPos != null ? named.aliasPos : p;
					var td = TypeFunctions.mkTypedef(cur, tPath, tp, tp, TypeFunctions.typeOfModuleType(r));
					td.isPrivate = true;
					td.params = mi.params;
					named.aliasTypedef = TTypeDecl(td);
					// The typedef just built answers when the cursor is on the alias.
					if (hxc.typing.Typer.atDisplayPos(tp))
						hxc.typing.Typer.displayModuleType(ctx, named.aliasTypedef, tp);
				}
				imports.markImport(named.impIdx);
				return named.aliasTypedef;
			}
			if (r != null) { imports.markImport(named.impIdx); return r; }
		}
		return null;
	}

	// Wildcard imports: `import pack.*` resolves `name` as pack.name's type or pack.name module's main
	// type.
	public static function resolveWildcardImportType(ctx:Context, cur:ModuleDef, name:String, p:Position):Null<ModuleType> {
		var imports = ctx.moduleImports.get(Context.pathKey(cur.path));
		if (imports == null) return null;
		for (wp in imports.wildcards) {
			var r = tryLoadSub(ctx, wp, name, p);
			if (r != null) { imports.markWildcard(wp); return r; }
			r = tryLoadModuleMain(ctx, {pack: wp.pack.concat([wp.name]), name: name}, p);
			if (r != null) { imports.markWildcard(wp); return r; }
		}
		return null;
	}

	public static function resolveBareType(ctx:Context, cur:ModuleDef, name:String, p:Position):Null<ModuleType> {
		if (cur == null) return null;

		for (mt in cur.types) {
			if (TypeFunctions.tInfos(mt).path.name == name) return mt;
		}

		{
			var r = resolveNamedImportType(ctx, cur, name, p);
			if (r != null) return r;
			r = resolveWildcardImportType(ctx, cur, name, p);
			if (r != null) return r;
		}

		// Seeds every module's module_imports with ctx.g.std.types - "We always want core types to be
		// available so we add them as default imports". those imports before walks the package prefixes,
		// so a core type never reaches the walk. hxc had the StdTypes lookup only as a fallback after the
		// walk, which meant every use of one first probed - and missed - `<currentPackage>.<Name>` for
		// each prefix, each miss consulting com.load_extern_type. The module is read from the LUT, never
		// loaded from here: an unloaded StdTypes means we are bootstrapping it and there is nothing to
		// seed with.
		{
			var std = ctx.moduleLut.get(Context.pathKey({pack: [], name: "StdTypes"}));
			if (std != null && std != cur) {
				for (mt in std.types)
					if (TypeFunctions.tInfos(mt).path.name == name) return mt;
			}
		}

		var pack = cur.path.pack;
		var i = pack.length;
		while (i >= 0) {
			var tryPack = pack.slice(0, i);
			// Skip re-loading the current module itself (already searched in (A)).
			if (!(tryPack.length == cur.path.pack.length && name == cur.path.name && samePack(tryPack, cur.path.pack))) {
				var r = tryLoadModuleMain(ctx, {pack: tryPack, name: name}, p);
				if (r != null) return r;
			}
			i--;
		}
		return null;
	}

	public static function resolveSamePackageSibling(ctx:Context, cur:ModuleDef, name:String, p:Position):Null<ModuleType> {
		if (cur == null) return null;
		var pack = cur.path.pack;
		var i = pack.length;
		while (i >= 1) { // I >= 1: never reach the root level (handled by the top-level lookup)
			var tryPack = pack.slice(0, i);
			// Skip the current module itself.
			if (!(tryPack.length == cur.path.pack.length && name == cur.path.name && samePack(tryPack, cur.path.pack))) {
				// EXACT match only: the sibling module must contain a type whose name == `name` the
				// named-import path does, a module like `hxc.core.Type` (whose main enum is `T`, with no `Type`
				// sub-type) would otherwise wrongly bind a bare `Type` to its first public type (`Path`),
				// shadowing the top-level std `Type` class (`Type.enumEq` -> crash). Matches the module name,
				// so a module
				// `pack/Name.hx` is only a hit when it actually declares the type `Name`.
				var m = try loadModuleOpt(ctx, {pack: tryPack, name: name}, p) catch (_:ContextError) null;
				if (m != null) {
					var r = findTypeInModuleOpt(m, name);
					if (r != null) return r;
				}
			}
			i--;
		}
		return null;
	}

	// Load module `mp` and return its sub-type `sub` (or null on any failure). Idempotent /
	// non-throwing, used by the speculative bare-name resolution above.
	static function tryLoadSub(ctx:Context, mp:Path, sub:String, p:Position):Null<ModuleType> {
		var m = try loadModuleOpt(ctx, mp, p) catch (_:ContextError) return null;
		if (m == null) return null;
		return findTypeInModuleOpt(m, sub);
	}

	// Resolves through find_type_in_module, which at requires `snd infos.path = tname` - an EXACT
	// type-name match. A module that declares no type of the requested name does not answer here at
	// all; it fails and the unqualified walk carries on outward, which is how a name that also happens
	// to be a module file name still reaches the standard library. There is no first-declared-type
	// fallback anywhere in the reference. Having one meant `pack/Type.hx`, declaring only `Foo` and
	// `Bar`, claimed the name `Type` for `Foo` and made the stdlib Type unreachable from anywhere
	// inside `pack`.
	static function tryLoadModuleMain(ctx:Context, mp:Path, p:Position):Null<ModuleType> {
		var m = try loadModuleOpt(ctx, mp, p) catch (_:ContextError) return null;
		if (m == null) return null;
		return findTypeInModuleOpt(m, mp.name);
	}

	static function samePack(a:Array<String>, b:Array<String>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	/**
	 * Replace `ctx.basic` (currently the stub) with the basic types built from the real loaded
	 * StdTypes/String/Array declarations. Returns the new BasicTypes (also stored on the Context).
	 * Raises if a core type is missing from the loaded modules.
	 */
	public static function initBasicTypes(ctx:Context):BasicTypes {
		var p = Position.nullPos;
		// StdTypes not loading means the standard library itself was not found, and the message says where
		// the compiler looked.
		var stdTypes = try loadModule(ctx, {pack: [], name: "StdTypes"}, p) catch (_:ContextError) {
			var env = Sys.getEnv("HAXE_STD_PATH");
			throw new hxc.core.TypingError(env != null
				? "Standard library not found. Please check your `HAXE_STD_PATH` environment variable (current value: \"" + env + "\")"
				: "Standard library not found. You may need to set your `HAXE_STD_PATH` environment variable", Position.nullPos);
		};
		var stringMod = loadModule(ctx, {pack: [], name: "String"}, p);
		var arrayMod = loadModule(ctx, {pack: [], name: "Array"}, p);
		// haxe.EnumTools (the global `using`) loads at typer creation, before any init macro runs, so
		// global metadata registered by one never reaches it: `addGlobalMetadata("", "@:build(...)")`
		// does not build it.
		loadModule(ctx, {pack: ["haxe"], name: "EnumTools"}, p);

		function abstractOf(m:ModuleDef, name:String):TAbstract {
			for (mt in m.types) switch (mt) {
				case TAbstractDecl(a) if (a.path.name == name): return a;
				case _:
			}
			throw new ContextError("core abstract " + name + " not found in " + Context.sTypePath(m.path), p);
		}
		function classOf(m:ModuleDef, name:String):TClass {
			for (mt in m.types) switch (mt) {
				case TClassDecl(c) if (c.path.name == name): return c;
				case _:
			}
			throw new ContextError("core class " + name + " not found in " + Context.sTypePath(m.path), p);
		}

		var aVoid = abstractOf(stdTypes, "Void");
		var aInt = abstractOf(stdTypes, "Int");
		var aFloat = abstractOf(stdTypes, "Float");
		var aBool = abstractOf(stdTypes, "Bool");
		var aNull = abstractOf(stdTypes, "Null");
		var cString = classOf(stringMod, "String");
		var cArray = classOf(arrayMod, "Array");

		var basic:BasicTypes = {
			tvoid: TAbstract(aVoid, []),
			tint: TAbstract(aInt, []),
			tfloat: TAbstract(aFloat, []),
			tbool: TAbstract(aBool, []),
			tnull: TypeFunctions.mkNull.bind(aNull),
			tstring: TInst(cString, []),
			tarray: function(t:T) return TInst(cArray, [t])
		};
		ctx.basic = basic;
		// haxe.Exception is always loaded at typer creation (its closure pulls CallStack/ReadOnlyArray,
		// whose `to Iterable` unify marks Array.iterator)
		loadModule(ctx, {pack: ["haxe"], name: "Exception"}, p);
		return basic;
	}

	// The abstract's synthetic `<Name>_Impl_` EClass is built from the abstract's own declaration, and
	// everything downstream that wants the SYNTAX of an impl field looks it up under the impl's path.
	// Rebuilding it is what lets a module served back from the cache be re-inspected field by field (the
	// display check of a KAbstractImpl class).
	public static function registerAbstractImplDecl(ctx:Context, c:TClass, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>):Void {
		var implDef:Definition<ClassFlag, Array<ClassField>> = {
			dName: {name: c.path.name, pos: c.pos}, dDoc: null, dParams: [], dMeta: c.meta,
			dFlags: [HPrivate], dData: abstractImplFields(ctx, c, a, d)
		};
		ctx.declOfType.set(Context.pathKey(c.path), {decl: EClass(implDef), pos: c.pos});
	}

	// The abstract's own fields as the IMPL class declares them (the `this` argument injected, `new`
	// renamed).
	public static function abstractImplFields(ctx:Context, c:TClass, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>):Array<ClassField> {
		var p = c.pos;
		var aTParams:Array<TypeParamOrConst> = [
			for (tp in d.dParams) TPType({ct: CTPath({tpackage: [], tname: tp.tpName.name, tparams: [], tsub: null}), pos: p})
		];
		var aT:TypeHint = {ct: CTPath({tpackage: [], tname: d.dName.name, tparams: aTParams, tsub: null}), pos: p};
		var thisT:TypeHint = aT;
		for (fl in d.dFlags) switch (fl) { case AbOver(t): thisT = t; break; case _: }
		return [for (f in d.dData) transformAbstractField(thisT, aT, a, f, ctx)];
	}

	static function transformAbstractField(thisT:TypeHint, aT:TypeHint, a:TAbstract, f:ClassField, ?com:Context):ClassField {
		var stat = false;
		for (acc in f.cffAccess) if (acc.access == AStatic) stat = true;
		var p = f.cffPos;
		switch (f.cffKind) {
			// A non-static abstract property may only read through get or never and write through set or
			// never. An abstract has no storage to back anything else, and an @:enum field is exempt
			// because it is a constant, not a property.
			case FProp(get, set, _, _) if (!stat
				&& !((get.name == "get" || get.name == "never") && (set.name == "set" || set.name == "never"))
				&& !TypeFunctions.hasMeta(":enum", f.cffMeta)):
				throw new ContextError("Member property accessors must be get/set or never", p);
			// @:isVar asks for exactly the storage an abstract does not have. Reporting it here keeps its
			// order relative to the accessor check above, which runs first either way.
			case FProp(_, _, _, _) if (!stat && TypeFunctions.hasMeta(":isVar", f.cffMeta)):
				throw new ContextError("Abstract properties cannot be real variables", p);
			case FVar(_, _) if (!stat && !a.isEnum):
				// A plain member var has no storage on an abstract; enum abstract constants stay legal.
				throw new ContextError("Cannot declare member variable in abstract", p);
			case FFun(fu) if (f.cffName.name == "new" && !stat):
				// A @:multiType constructor is a declaration only (the concrete map is picked by the
				// multi-type cast), so it is marked extern and later dropped with the extern fields - no
				// storage or reflection is generated for it.
				var access = f.cffAccess;
				if (TypeFunctions.hasMeta(":multiType", a.meta)) {
					for (acc in access) if (acc.access == AInline)
						throw new ContextError("inline on MultiType constructor", f.cffPos);
					if (fu.fExpr != null && com != null)
						com.addDiagnostic("MultiType constructors cannot have a body", f.cffPos);
					access = [{access: AExtern, pos: Position.nullPos}].concat(access);
				}
				for (acc in f.cffAccess) if (acc.access == AMacro)
					throw new ContextError("Invalid modifier: macro on abstract constructor", acc.pos);
				// The synthetic `this` var has no position of its own. Giving it the field's would make it
				// enclose the whole constructor body, and a display question anywhere inside would be answered
				// by it instead.
				var thisVar:EVar = {
					evName: {name: "this", pos: Position.nullPos}, evFinal: false, evStatic: false,
					evType: thisT, evExpr: null, evMeta: [{name: ":this", params: [], pos: Position.nullPos}]
				};
				// The generated expression positions must not shadow the real code: every node this rewrite
				// injects, and the block it wraps them in, is built at a ZERO-WIDTH position. With the
				// field's own span they would enclose the whole constructor, and a display question
				// anywhere inside would be answered by them.
				var pgen = new Position(p.file, p.min, p.min);
				var initE = new Expr(EVars([thisVar]), pgen);
				var retE = new Expr(EReturn(new Expr(ECast(new Expr(EConst(CIdent("this")), pgen), null), pgen)), pgen);
				// The body becomes one block: the init, the original statements (or the single expression),
				// then the
				// return.
				var newExpr:Null<Expr> = switch (fu.fExpr) {
					case null: null;
					case e: switch (e.expr) {
						case EBlock(el): new Expr(EBlock([initE].concat(el).concat([retE])), pgen);
						case _: new Expr(EBlock([initE, e, retE]), pgen);
					}
				};
				var fu2:Func = {fParams: fu.fParams, fArgs: fu.fArgs, fType: aT, fExpr: newExpr};
				// Local is the `this` resolved by get_this. AKUsingField member-call rewrite, so the CfImpl
				// flag here only affects fmode. the injected entry null_pos, not the field's own.
				var meta = [{name: ":noCompletion", params: [], pos: Position.nullPos}, {name: ":hxcImpl", params: [], pos: p}].concat(f.cffMeta);
				// Rename to `_new` and force static (the impl `_new` is a static factory).
				return {
					cffName: {name: "_new", pos: f.cffName.pos}, cffDoc: f.cffDoc, cffPos: f.cffPos,
					cffMeta: meta, cffAccess: withStatic(access, p), cffKind: FFun(fu2)
				};
			case FFun(fu) if (!stat):
				// A cast function is called with no receiver, so it has to be static; the member form would
				// never be reachable.
				if (TypeFunctions.hasMeta(":from", f.cffMeta))
					throw new ContextError("@:from cast functions must be static", f.cffPos);
				// A member (non-static) method. For a member impl method only when `not fctx.is_macro`. A macro
				// member abstract method does not get the underlying `this` prepended, instead its first
				// DECLARED arg first argument which will contain the this expression"). So for a macro member
				// we by macro_call (Typer.typeMacro), not prepended here.
				var isMacroField = false;
				for (acc in f.cffAccess) if (acc.access == AMacro) isMacroField = true;
				var newArgs = isMacroField
					? fu.fArgs
					: [({name: {name: "this", pos: Position.nullPos}, opt: false, meta: [{name: ":implicitThis", params: [], pos: Position.nullPos}], type: thisT, value: null} : FunctionArg)].concat(fu.fArgs);
				var fu2:Func = {fParams: fu.fParams, fArgs: newArgs, fType: fu.fType, fExpr: fu.fExpr};
				// Is_abstract_member): tells registerFields to flag this static as an abstract member impl so
				// the typer prepends the receiver as `this` (`v.m(a)` ->
				// `Abstract_Impl_.m(v,a)`) via the AKUsingField static-extension rewrite.
				var meta = [{name: ":hxcImpl", params: [], pos: p}].concat(f.cffMeta);
				return {
					cffName: f.cffName, cffDoc: f.cffDoc, cffPos: f.cffPos, cffMeta: meta,
					cffAccess: withStatic(f.cffAccess, p), cffKind: FFun(fu2)
				};
			case _:
				return f;
		}
	}

	public static function buildEnumAbstract(basic:BasicTypes, a:TAbstract, aT:TypeHint, fields:Array<ClassField>, ?com:Context):Void {
		// The implementation class (extern for an extern abstract) decides whether value-less members
		// keep a synthesized value.
		var c = a.impl;
		var modeInt = hxc.core.TypeUnification.doesUnify(a.thisType, basic.tint);
		var modeString = !modeInt && hxc.core.TypeUnification.doesUnify(a.thisType, basic.tstring);
		var intCounter = 0;                  

		inline function fieldIsSet(field:ClassField):Bool {
			return switch (field.cffKind) {
				case FVar(t, e) if (t != null && e != null && (switch (e.expr) { case ECast(_, _): true; case _: false; })):
					var hasInline = false;
					for (acc in field.cffAccess) if (acc.access == AInline) hasInline = true;
					hasInline;
				case _: false;
			};
		}
		inline function setField(field:ClassField, ct:Null<TypeHint>, e:Expr):Void {
			field.cffAccess = [{access: AInline, pos: Position.nullPos}].concat(field.cffAccess);
			var castE = new Expr(ECast(e, null), e.pos);
			field.cffKind = FVar(ct, castE);
		}

		for (field in fields) {
			switch (field.cffKind) {
				case FVar(ct, eo):
					var isStatic = false;
					for (acc in field.cffAccess) if (acc.access == AStatic) isStatic = true;
					if (isStatic || fieldIsSet(field)) continue;

					// APrivate / APublic (recorded; conflict -> error). Result drives cffAccess.
					// VUnknown -> default APublic.
					var visibility:Null<PlacedAccess> = null; // Null => VUnknown
					for (acc in field.cffAccess) switch (acc.access) {
						case AExtern:
							// The error is recorded and the access loop continues, so a second extern member reports
							// too; raising would end the module at the first one. Same shape as the Value required arm
							// below.
							if (com != null) com.addDiagnostic("Invalid modifier: extern on field of enum abstract", acc.pos);
						case APrivate | APublic:
							// A second visibility reports against the previous one, then becomes the
							// tracked visibility itself.
							if (visibility != null && com != null) {
								var name = switch (visibility.access) { case APublic: "public"; case _: "private"; };
								com.addDiagnostic("Conflicting access modifier " + name, acc.pos);
								com.addDiagnostic("Conflicts with this", visibility.pos, 1);
							}
							visibility = acc;
						case _:
					}
					field.cffAccess = [visibility != null ? visibility : {access: APublic, pos: Position.nullPos}];
					// create_variable prepends `:impl` to an abstract member var, which is what an enum abstract
					// value is (it is not declared static).
					field.cffMeta = [{name: ":impl", params: [], pos: Position.nullPos},
						{name: ":enum", params: [], pos: Position.nullPos}].concat(field.cffMeta);
					var effCt:TypeHint = ct != null ? ct : aT;

					switch (eo) {
						case null:
							// On an extern implementation a value-less member keeps no synthesized value:
							// it stays a real extern property so it compiles to a native field access (its
							// value comes from the platform), rather than getting an inline ordinal/string.
							if (TypeFunctions.hasClassFlag(c, CExtern)) {
								field.cffKind = FProp({name: "default", pos: Position.nullPos}, {name: "never", pos: Position.nullPos}, effCt, null);
							} else if (modeString) {
								// The enum abstract build synthesizes both the String and the Int value at
								// the null position, and the cast that wraps them sits at that position
								// too. The field position would give the generated boot assignments a real
								// file and line, so a target that emits position info per statement would
								// print the declaration line instead of "?" and line 1.
								setField(field, effCt, new Expr(EConst(CString(field.cffName.name, SDoubleQuotes)), Position.nullPos));
							} else if (modeInt) {
								setField(field, effCt, new Expr(EConst(CInt(Std.string(intCounter), null)), Position.nullPos));
								intCounter++;
							} else {
								// "Value required" is recorded and the build carries on to the next member. Raising would
								// reach resolveModule's ContextError arm, mark the whole module errored and abandon every
								// declaration after it; on an abstract whose underlying type is not resolved yet, that one
								// raise would cascade into every sibling enum abstract reading as "Cannot access private
								// field", because their impls were never built. The member simply gets no synthesised
								// value.
								if (com != null) com.addDiagnostic("Value required", field.cffPos);
							}
						case e:
							// Re-syncs the counter to that+1.
							if (modeInt) switch (e.expr) {
								case EConst(CInt(s, null)):
									var iv = Std.parseInt(s);
									if (iv != null) intCounter = iv + 1;
								case _:
							}
							setField(field, effCt, e);
					}
				case _:
			}
		}
	}

	// Return the access list with `static` added if not already present (used to mark the
	// transformed member methods / `_new` as statics on the `_Impl_` class).
	static function withStatic(access:Array<PlacedAccess>, p:Position):Array<PlacedAccess> {
		for (acc in access) if (acc.access == AStatic) return access;
		return [{access: AStatic, pos: p}].concat(access);
	}

	static function hasClassFlag(flags:Array<ClassFlag>, f:ClassFlag):Bool {
		for (x in flags) if (Type.enumEq(x, f)) return true;
		return false;
	}
	static function hasEnumFlag(flags:Array<EnumFlag>, f:EnumFlag):Bool {
		for (x in flags) if (Type.enumEq(x, f)) return true;
		return false;
	}
	static function hasAbstractFlag(flags:Array<AbstractFlag>, f:AbstractFlag):Bool {
		// AbFrom/AbTo/AbOver carry args; we only test the niladic AbPrivate/AbEnum/AbExtern.
		for (x in flags) if (Type.enumEq(x, f)) return true;
		return false;
	}
	static function sameArray(a:Array<String>, b:Array<String>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}
}
