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
		ctx.getType = function(path:Path, p:Position, ?sub:String):ModuleType {
			return loadTypeDef(ctx, path, p, sub);
		};
		ctx.defineType = function(mt:ModuleType):Void {
			var m = TypeFunctions.tInfos(mt).module;
			addModule(ctx, m);
		};
	}

	public static function findFile(ctx:Context, relPath:String, m:Path, p:Position):String {
		for (dir in ctx.classPath) {
			var full = (dir == "" ? "" : (StringTools.endsWith(dir, "/") || StringTools.endsWith(dir, "\\") ? dir : dir + "/")) + relPath;
			if (skipEvalOverlayFile(ctx, dir, relPath)) continue;
			if (FileSystem.exists(full) && !FileSystem.isDirectory(full)) return canonicalFileName(full);
		}
		throw new ContextError("Type not found : " + Context.sTypePath(m), p, ModuleNotFound(m));
	}

	static function canonicalFileName(file:String):String {
		var slash = file.lastIndexOf("/");
		var backslash = file.lastIndexOf("\\");
		if (backslash > slash) slash = backslash;
		if (slash < 0) return file;
		var dir = file.substr(0, slash + 1);
		var name = file.substr(slash + 1);
		try {
			for (entry in FileSystem.readDirectory(dir))
				if (entry.toLowerCase() == name.toLowerCase()) return dir + entry;
		} catch (_:Dynamic) {}
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

	public static function resolveModuleFile(ctx:Context, m:Path, p:Position):String {
		var prefix = m.pack.length == 0 ? m.name : m.pack.join("/") + "/" + m.name;
		if (ctx.isMacro) {
			try return findFile(ctx, prefix + ".macro.hx", m, p) catch (_:ContextError) {}
		}
		return findFile(ctx, prefix + ".hx", m, p);
	}

	static function makeModule(ctx:Context, mpath:Path, file:String):ModuleDef {
		return {
			id: TypeFunctions.allocMid(),
			path: mpath,
			types: [],
			statics: null,
			extra: TypeFunctions.moduleExtra(file, "", 0.0, MCode, [])
		};
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

	static function createModuleTypes(ctx:Context, m:ModuleDef, tdecls:Array<TypeDecl>):Void {
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

		function recordImport(imp:Import):Void {
			imports.rawImports.unshift(imp);
			var parts = [for (pn in imp.path) pn.name];
			switch (imp.mode) {
				case IAll:
					var split = splitImportPath(parts);
					if (split != null) imports.wildcards.unshift(split.modulePath);
					else if (parts.length > 0) imports.wildcards.unshift({pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]});
				case INormal:
					var split = splitImportPath(parts);
					if (split == null) return;
					if (split.field != null) {
						imports.globals.set(split.field, {ownerPath: split.modulePath, ownerSub: split.sub, field: split.field});
						return;
					}
					var short = split.sub != null ? split.sub : split.modulePath.name;
					imports.names.set(short, {modulePath: split.modulePath, sub: split.sub});
				case IAsName(alias):
					var split = splitImportPath(parts);
					if (split == null) return;
					if (split.field != null) {
						imports.globals.set(alias.name, {ownerPath: split.modulePath, ownerSub: split.sub, field: split.field});
						return;
					}
					imports.names.set(alias.name, {modulePath: split.modulePath, sub: split.sub, aliased: true});
			}
		}

		function recordUsing(path:Array<PlacedName>):Void {
			var parts = [for (pn in path) pn.name];
			var split = splitImportPath(parts);
			if (split == null) return;
			var short = split.sub != null ? split.sub : split.modulePath.name;
			var namedModulePath = split.modulePath;
			if (split.sub != null && split.modulePath.pack.length == 0 && m.path.pack.length > 0)
				namedModulePath = {pack: m.path.pack, name: split.modulePath.name};
			imports.names.set(short, {modulePath: namedModulePath, sub: split.sub});
			function usingPath(modulePath:Path):Path {
				return split.sub != null ? {pack: modulePath.pack.concat([modulePath.name]), name: split.sub} : modulePath;
			}
			if (split.modulePath.pack.length == 0 && m.path.pack.length > 0) {
				var localModulePath = {pack: m.path.pack, name: split.modulePath.name};
				imports.usings.push(usingPath(localModulePath));
			}
			imports.usings.push(usingPath(split.modulePath));
		}

		// Record the duplicate-name error, then raise Previous declaration here one level deeper at the
		// original declaration.
		function checkName(name:String, p:Position):Void {
			function err(prevPos:Position):Void {
				ctx.addDiagnostic("Name " + name + " is already defined in this module", p);
				throw new ContextError("... Previous declaration here", prevPos);
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
				checkName(d.dName.name, d.dName.pos);
			}
		}

		// Private types live under the module's package plus `_<Module>`.
		function makePath(name:String, priv:Bool, p:Position):Path {
			checkName(name, p);
			return priv ? {pack: m.path.pack.concat(["_" + m.path.name]), name: name}
			            : {pack: m.path.pack, name: name};
		}

		for (decl in tdecls) {
			var p = decl.pos;
			switch (decl.decl) {
				case EImport(imp):
					if (hasDeclaration)
						throw new ContextError("import and using may not appear after a declaration", p);
					recordImport(imp);

				case EUsing(path):
					if (hasDeclaration)
						throw new ContextError("import and using may not appear after a declaration", p);
					recordUsing(path);

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
					// Classes are built eagerly during module resolution; structural unification must not trigger
					// a placeholder build failure.
					c.build = function():BuildState return Built;
					c.module = m;
					c.isPrivate = priv;
					c.doc = d.dDoc;
					c.meta = d.dMeta;
					// Register type parameters before resolving other modules so their arity is already available.
					c.params = hxc.typing.Typeload.typeTypeParams(ctx, path, d.dParams);
					if (hasClassFlag(d.dFlags, HAbstract)) TypeFunctions.addClassFlag(c, CAbstract);
					for (f in d.dFlags) switch (f) {
						case HExtern: TypeFunctions.addClassFlag(c, CExtern);
						case HInterface: TypeFunctions.addClassFlag(c, CInterface);
						case HFinal: TypeFunctions.addClassFlag(c, CFinal);
						case _:
					}
					if (TypeFunctions.hasMeta(":final", c.meta)) TypeFunctions.addClassFlag(c, CFinal);
					// KGenericBuild retains syntax fields for getBuildFields; ordinary @:generic classes use
					// KGeneric.
					if (TypeFunctions.hasMeta(":genericBuild", c.meta)) {
						if (ctx.isMacro)
							throw new ContextError("@:genericBuild cannot be used in macros", d.dName.pos);
						c.kind = KGenericBuild(d.dData);
					} else if (TypeFunctions.hasMeta(":generic", c.meta) && c.params.length > 0)
						c.kind = KGeneric;
					// Register field shells before resolving their types and bodies.
					registerFields(c, d.dData);
					decls.push(TClassDecl(c));
					ctx.declOfType.set(Context.pathKey(path), {decl: decl.decl, pos: p});

				case EEnum(d):
					var name = d.dName.name;
					hasDeclaration = true;
					var priv = hasEnumFlag(d.dFlags, EPrivate);
					var path = makePath(name, priv, p);
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
						params: hxc.typing.Typeload.typeTypeParams(ctx, path, d.dParams),
						usings: [],
						restore: function() {},
						isPrivate: priv,
						isExtern: hasEnumFlag(d.dFlags, EExtern),
						constrs: new StringMap<TEnumField>(),
						names: [],
						type: enumModuleType(m, path, p)
					};
					decls.push(TEnumDecl(e));
					ctx.declOfType.set(Context.pathKey(path), {decl: decl.decl, pos: p});

				case ETypedef(d):
					var name = d.dName.name;
					checkName(name, d.dName.pos);
					hasDeclaration = true;
					var priv = hasEnumFlag(d.dFlags, EPrivate); // ETypedef uses EnumFlag in the AST
					var path = makePath(name, priv, p);
					var patch = applyTypePatches(ctx, path, d.dMeta);
					d.dMeta = patch.meta;
					var t = TypeFunctions.mkTypedef(m, path, p, d.dName.pos, TypeFunctions.mkMono());
					t.doc = d.dDoc;
					t.isPrivate = priv;
					t.meta = d.dMeta;
					t.params = hxc.typing.Typeload.typeTypeParams(ctx, path, d.dParams);
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
						isPrivate: priv, doc: d.dDoc, meta: d.dMeta, params: hxc.typing.Typeload.typeTypeParams(ctx, path, d.dParams), usings: [],
						restore: function() {}, ops: [], unops: [], impl: null,
						thisType: TypeFunctions.mkMono(), from: [], fromField: [], to: [],
						toField: [], array: [], read: null, write: null, call: null,
						isEnum: hasAbstractFlag(d.dFlags, AbEnum) || TypeFunctions.hasMeta(":enum", d.dMeta)
					};
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
						var implFields:Array<ClassField> = [for (f in d.dData) transformAbstractField(thisT, aT, a, f)];
						// Process the synthetic private implementation through the ordinary class pipeline, including
						// structural registration, type resolution and body typing.
						var implName = d.dName.name + "_Impl_";
						var implPath:Path = {pack: m.path.pack.concat(["_" + m.path.name]), name: implName};
						var implDef:Definition<ClassFlag, Array<ClassField>> = {
							dName: {name: implName, pos: p}, dDoc: null, dParams: [], dMeta: d.dMeta,
							dFlags: [HPrivate], dData: implFields
						};
						var implDecl:TypeDef = EClass(implDef);
						var c = TypeFunctions.mkClass(m, implPath, p, p);
						c.build = function():BuildState return Built;
						c.module = m;
						c.meta = d.dMeta;
						c.isPrivate = true;
						c.kind = KAbstractImpl(a);
						TypeFunctions.addClassFlag(c, CFinal);
						registerFields(c, implFields);
						decls.push(TClassDecl(c));
						ctx.declOfType.set(Context.pathKey(implPath), {decl: implDecl, pos: p});
						a.impl = c;
					}
			}
		}

		if (statics.length > 0) {
			var firstPos = statics[0].p;
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

		m.types = decls;
		applyGlobalMetadata(ctx, m, decls);
		ctx.moduleImports.set(Context.pathKey(m.path), imports);
	}

	static function applyGlobalMetadata(ctx:Context, m:ModuleDef, decls:Array<ModuleType>):Void {
		if (ctx.globalMetadata.length == 0) return;
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

	public static function rebuildFields(c:TClass, fields:Array<ClassField>):Void {
		c.fields = new StringMap<TClassField>();
		c.statics = new StringMap<TClassField>();
		c.orderedFields = [];
		c.orderedStatics = [];
		c.constructor = null;
		registerFields(c, fields);
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

	public static function registerFields(c:TClass, fields:Array<ClassField>):Void {
		function checkIfFeature(meta:Metadata):Array<String> {
			for (m in meta) if (m.name == ":ifFeature")
				return [for (p in m.params) switch (p.expr) {
					case EConst(CString(s, _)): s;
					case _: throw new ContextError("String expected", p.pos);
				}];
			return [];
		}
		var clIfFeature = checkIfFeature(c.meta);
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
			// Tag abstract implementation members so calls prepend the receiver as this.
			if (TypeFunctions.hasMeta(":impl", cff.cffMeta)) TypeFunctions.addClassFieldFlag(cf, CfImpl);
			// Abstract members carry CfImpl, including enum-abstract variables, whose CfEnum flag enables
			// inline folding.
			if (isAbstractImplMember) TypeFunctions.addClassFieldFlag(cf, CfImpl);
			// Set CfEnum on synthesized :enum fields so reads inline-fold and patterns participate in
			// exhaustiveness checks.
			if (TypeFunctions.hasMeta(":enum", cff.cffMeta)) TypeFunctions.addClassFieldFlag(cf, CfEnum);
			if (TypeFunctions.hasMeta(":generic", cff.cffMeta)) TypeFunctions.addClassFieldFlag(cf, CfGeneric);
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
					// Property accessors use AccCall for get/set or dynamic, AccNo for null, AccNever for never
					// and AccNormal for default. This makes reads invoke getters rather than uninitialized backing
					// fields.
					Var({read: propAccess(get.name, true), write: propAccess(set.name, false)});
			}
			var isMethod = switch (cf.kind) { case Method(_): true; case _: false; };
			if (overloadPos != null) {
				TypeFunctions.addClassFieldFlag(cf, CfOverload);
				if (cf.name == "new") {
					throw new ContextError("Invalid modifier: overload on constructor", overloadPos);
				} else if (!TypeFunctions.hasClassFlag(c, CExtern) && !isExtern) {
					throw new ContextError("Invalid modifier: overload is only supported on extern functions", overloadPos);
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
				mainf.overloads = [cf].concat(cf.overloads).concat(mainf.overloads);
				continue;
			}
			if (isStatic) {
				c.statics.set(cf.name, cf);
				c.orderedStatics.push(cf);
			} else if (cf.name == "new") {
				c.constructor = cf;
			} else {
				c.fields.set(cf.name, cf);
				c.orderedFields.push(cf);
			}
		}
	}

	// Map property accessor names to VarAccess. Unknown custom accessors retain AccCall behavior after
	// reporting an error.
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

	static function addModule(ctx:Context, m:ModuleDef):Void {
		ctx.moduleLut.set(Context.pathKey(m.path), m);
		ctx.modules.push(m);
		for (mt in m.types) {
			ctx.types.push(mt);
			ctx.typeToModule.set(Context.pathKey(TypeFunctions.tPath(mt)), m.path);
		}
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
		return m;
	}

	/** Register a macro-created type definition (`Context.defineType`) as a fake module. */
	public static function defineTypeDecl(ctx:Context, mpath:Path, decl:TypeDef, pos:Position):ModuleDef {
		var m = typeModule(ctx, mpath, "<macro>", [{decl: decl, pos: pos}]);
		m.extra.kind = MFake;
		ctx.moduleNonexistentLut = new StringMap();
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
			ctx.typeToModule.set(Context.pathKey(TypeFunctions.tPath(mt)), m.path);
		}
		return added;
	}

	/** Register a macro-created module (`Context.defineModule`) from decoded AST declarations. */
	public static function defineModuleDecls(ctx:Context, mpath:Path, types:Array<TypeDecl>, imports:Array<Import>, usings:Array<PlacedTypePath>, pos:Position):ModuleDef {
		var decls:Array<TypeDecl> = [];
		for (imp in imports) decls.push({decl: EImport(imp), pos: pos});
		for (u in usings) {
			var names = u.path.tpackage.concat([u.path.tname]);
			if (u.path.tsub != null) names.push(u.path.tsub);
			decls.push({decl: EUsing([for (n in names) ({name: n, pos: u.pos} : PlacedName)]), pos: u.pos});
		}
		decls = decls.concat(types);
		var m = typeModule(ctx, mpath, "<macro>", decls);
		m.extra.kind = MFake;
		ctx.moduleNonexistentLut = new StringMap();
		return m;
	}

	/**
	 * Return the already-loaded module, else find its source on the class path, parse it, and register
	 * all its declarations. Raises
	 * `ContextError(ModuleNotFound)` when no source file exists.
	 */
	public static function loadModule(ctx:Context, m:Path, p:Position):ModuleDef {
		m = ctx.remapPath(m);
		var key = Context.pathKey(m);
		var existing = ctx.moduleLut.get(key);
		if (existing != null) return existing;
		if (ctx.moduleNonexistentLut.exists(key))
			throw new ContextError("Type not found : " + Context.sTypePath(m), p, ModuleNotFound(m));

		var file:String;
		try {
			file = resolveModuleFile(ctx, m, p);
		} catch (e:ContextError) {
			ctx.moduleNonexistentLut.set(key, true);
			throw new ContextError("Type not found : " + Context.sTypePath(m), p, ModuleNotFound(m));
		}

		var src = Position.getFileContent(file);
		var pkg:Package = hxc.parser.Parser.parseModuleString(src, file, ctx.defines);
		// Checks the declared `package` matches the requested pack.
		if (!sameArray(pkg.pack, m.pack)) {
			var spack = function(l:Array<String>) return l.length == 0 ? "(root)" : l.join(".");
			throw new ContextError("Invalid package : " + file + " declares package "
				+ spack(pkg.pack) + " but module path is " + spack(m.pack), p);
		}
		return typeModule(ctx, m, file, pkg.decls);
	}

	public static function loadTypeDef(ctx:Context, path:Path, p:Position, ?sub:String):ModuleType {
		var tname = sub != null ? sub : path.name;
		// In-module sibling type: a bare unqualified name (no pack, no sub) is resolved
		// `ctx.m.curmod` before the filesystem). This makes a module-level `enum`/class/etc.
		// Declared alongside the main class resolvable without a same-named `.hx` file.
		if (sub == null && path.pack.length == 0 && ctx.currentModule != null) {
			for (mt in ctx.currentModule.types) {
				if (TypeFunctions.tInfos(mt).path.name == tname) return mt;
			}
		}
		try {
			var m = loadModule(ctx, path, p);
			return findTypeInModule(m, tname, p);
		} catch (e:ContextError) {
			// Bare unqualified type (empty pack, no sub) with no own `Name.hx`: it may be a sub-type of an
			// implicitly-imported module. The core types in StdTypes (Void/Int/Float/Bool/Null/Dynamic/...)
			// are accessible by bare name via the implicit `import StdTypes`.
			switch (e.kind) {
				case ModuleNotFound(_) | TypeNotFound(_) if (sub == null && path.pack.length == 0 && path.name != "StdTypes"):
					// A bare unqualified module name may be a sibling module in the current package (e.g.
					// `ModA` inside `mp.Main` meaning `mp.ModA`). The reference resolves an unqualified
					// name against the current package before the implicit StdTypes import . Without this a
					// `Module.SubType.staticField` chain whose leading package was already consumed cannot
					// re-resolve.
					if (ctx.currentModule != null) {
						var cpack = ctx.currentModule.path.pack;
						var i = cpack.length;
						while (i >= 1) {
							var tryPack = cpack.slice(0, i);
							var m = try loadModule(ctx, {pack: tryPack, name: path.name}, p) catch (_:ContextError) null;
							if (m != null) {
								try { return findTypeInModule(m, tname, p); } catch (_:ContextError) {}
							}
							i--;
						}
					}
					var std = loadModule(ctx, {pack: [], name: "StdTypes"}, p);
					try {
						return findTypeInModule(std, tname, p);
					} catch (_:ContextError) {
						throw e; // Surface the original (more specific) error
					}
				case ModuleNotFound(_) if (sub != null && path.pack.length == 0 && ctx.currentModule != null):
					var pack = ctx.currentModule.path.pack;
					var i = pack.length;
					while (i >= 1) {
						var tryPack = pack.slice(0, i);
						var m = try loadModule(ctx, {pack: tryPack, name: path.name}, p) catch (_:ContextError) null;
						if (m != null) {
							try { return findTypeInModule(m, tname, p); } catch (_:ContextError) {}
						}
						i--;
					}
					throw e;
				case ModuleNotFound(_) if (sub == null && path.pack.length >= 1):
					// A flattened sub-type path (pack ends in the module name, `name` is the sub-type, e.g.
					// `pack.Module.Sub` stored as {pack: [pack, Module], name: Sub}) has no module file of its
					// own; resolve the module from the last pack segment and find the sub-type in it.
					var mname = path.pack[path.pack.length - 1];
					var mpack = path.pack.slice(0, path.pack.length - 1);
					var m = try loadModule(ctx, {pack: mpack, name: mname}, p) catch (_:ContextError) null;
					if (m != null) {
						try { return findTypeInModule(m, path.name, p); } catch (_:ContextError) {}
					}
					throw e;
				case _:
					throw e;
			}
		}
	}

	public static function findTypeInModule(m:ModuleDef, tname:String, p:Position):ModuleType {
		for (mt in m.types) {
			var info = TypeFunctions.tInfos(mt);
			if (info.path.name == tname && !info.isPrivate) return mt;
		}
		for (mt in m.types) {
			if (TypeFunctions.tPath(mt).name == tname) return mt;
		}
		throw new ContextError("Type not found : " + tname + " in module " + Context.sTypePath(m.path),
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
					if (r != null) return r;
					continue;
				}
				var m = try loadModule(ctx, ni.modulePath, p) catch (_:ContextError) continue;
				for (mt in m.types) if (!TypeFunctions.tInfos(mt).isPrivate && fullMatch(mt)) return mt;
			}
			for (wp in imports.wildcards) {
				var m = try loadModule(ctx, wp, p) catch (_:ContextError) continue;
				for (mt in m.types) if (!TypeFunctions.tInfos(mt).isPrivate && fullMatch(mt)) return mt;
			}
		}
		return null;
	}

	// Load module `mp`, return its sub-type whose full path == `want` (or null). Used by the
	// qualified-path-via-imports resolver above.
	static function tryLoadSubFull(ctx:Context, mp:Path, want:Path, p:Position):Null<ModuleType> {
		var m = try loadModule(ctx, mp, p) catch (_:ContextError) return null;
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
		var named = imports.names.get(name);
		if (named != null) {
			// Alias/sub or module-name exact binding. An aliased module import binds the module's
			// main type, not a type named after the alias.
			var sub = named.sub != null ? named.sub : named.modulePath.name;
			var r = visible(tryLoadSub(ctx, named.modulePath, sub, p));
			if (r != null) return r;
		}
		for (key in imports.names.keys()) {
			var ni = imports.names.get(key);
			if (ni.sub != null || ni.aliased == true) continue; // Sub-imports only bind their own short name (handled above)
			var r = visible(tryLoadSub(ctx, ni.modulePath, name, p));
			if (r != null) return r;
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
			if (r != null) return r;
			r = tryLoadModuleMain(ctx, {pack: wp.pack.concat([wp.name]), name: name}, p);
			if (r != null) return r;
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
				var m = try loadModule(ctx, {pack: tryPack, name: name}, p) catch (_:ContextError) null;
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
		var m = try loadModule(ctx, mp, p) catch (_:ContextError) return null;
		return findTypeInModuleOpt(m, sub);
	}

	static function tryLoadModuleMain(ctx:Context, mp:Path, p:Position):Null<ModuleType> {
		var m = try loadModule(ctx, mp, p) catch (_:ContextError) return null;
		var byName = findTypeInModuleOpt(m, mp.name);
		if (byName != null) return byName;
		// "the type name is the module name" semantics being relaxed for a sub-named module).
		for (mt in m.types) if (!TypeFunctions.tInfos(mt).isPrivate) return mt;
		return null;
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
		var stdTypes = loadModule(ctx, {pack: [], name: "StdTypes"}, p);
		var stringMod = loadModule(ctx, {pack: [], name: "String"}, p);
		var arrayMod = loadModule(ctx, {pack: [], name: "Array"}, p);

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
			tnull: function(t:T) return (TypeFunctions.isNull(t) || TypeFunctions.isExplicitNull(t)) ? t : TAbstract(aNull, [t]),
			tstring: TInst(cString, []),
			tarray: function(t:T) return TInst(cArray, [t])
		};
		ctx.basic = basic;
		// haxe.Exception is always loaded at typer creation (its closure pulls CallStack/ReadOnlyArray,
		// whose `to Iterable` unify marks Array.iterator)
		loadModule(ctx, {pack: ["haxe"], name: "Exception"}, p);
		return basic;
	}

	static function transformAbstractField(thisT:TypeHint, aT:TypeHint, a:TAbstract, f:ClassField):ClassField {
		var stat = false;
		for (acc in f.cffAccess) if (acc.access == AStatic) stat = true;
		var p = f.cffPos;
		switch (f.cffKind) {
			case FFun(fu) if (f.cffName.name == "new" && !stat):
				var thisVar:EVar = {
					evName: {name: "this", pos: p}, evFinal: false, evStatic: false,
					evType: thisT, evExpr: null, evMeta: [{name: ":this", params: [], pos: p}]
				};
				var initE = new Expr(EVars([thisVar]), p);
				var retE = new Expr(EReturn(new Expr(ECast(new Expr(EConst(CIdent("this")), p), null), p)), p);
				// The body becomes one block: the init, the original statements (or the single expression),
				// then the
				// return.
				var newExpr:Null<Expr> = switch (fu.fExpr) {
					case null: null;
					case e: switch (e.expr) {
						case EBlock(el): new Expr(EBlock([initE].concat(el).concat([retE])), p);
						case _: new Expr(EBlock([initE, e, retE]), p);
					}
				};
				var fu2:Func = {fParams: fu.fParams, fArgs: fu.fArgs, fType: aT, fExpr: newExpr};
				// Resolve this through get_this; member calls inject their receiver through AKUsingField, so
				// CfImpl here affects only fmode.
				var meta = [{name: ":noCompletion", params: [], pos: p}, {name: ":impl", params: [], pos: p}].concat(f.cffMeta);
				// Rename to `_new` and force static (the impl `_new` is a static factory).
				return {
					cffName: {name: "_new", pos: f.cffName.pos}, cffDoc: f.cffDoc, cffPos: f.cffPos,
					cffMeta: meta, cffAccess: withStatic(f.cffAccess, p), cffKind: FFun(fu2)
				};
			case FFun(fu) if (!stat):
				// A member (non-static) method. For a member impl method only when `not fctx.is_macro`. A macro
				// member abstract method does not get the underlying `this` prepended, instead its first
				// DECLARED arg first argument which will contain the this expression"). So for a macro member
				// we by macro_call (Typer.typeMacro), not prepended here.
				var isMacroField = false;
				for (acc in f.cffAccess) if (acc.access == AMacro) isMacroField = true;
				var newArgs = isMacroField
					? fu.fArgs
					: [({name: {name: "this", pos: p}, opt: false, meta: [], type: thisT, value: null} : FunctionArg)].concat(fu.fArgs);
				var fu2:Func = {fParams: fu.fParams, fArgs: newArgs, fType: fu.fType, fExpr: fu.fExpr};
				// Is_abstract_member): tells registerFields to flag this static as an abstract member impl so
				// the typer prepends the receiver as `this` (`v.m(a)` ->
				// `Abstract_Impl_.m(v,a)`) via the AKUsingField static-extension rewrite.
				var meta = [{name: ":impl", params: [], pos: p}].concat(f.cffMeta);
				return {
					cffName: f.cffName, cffDoc: f.cffDoc, cffPos: f.cffPos, cffMeta: meta,
					cffAccess: withStatic(f.cffAccess, p), cffKind: FFun(fu2)
				};
			case _:
				return f;
		}
	}

	public static function buildEnumAbstract(basic:BasicTypes, a:TAbstract, aT:TypeHint, fields:Array<ClassField>):Void {
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
					var conflict = false;
					for (acc in field.cffAccess) switch (acc.access) {
						case AExtern:
							throw new ContextError("Invalid modifier: extern on field of enum abstract", acc.pos);
						case APrivate | APublic:
							if (visibility != null) conflict = true;
							visibility = acc;
						case _:
					}
					if (conflict) throw new ContextError("Conflicting access modifier", field.cffPos);
					field.cffAccess = [visibility != null ? visibility : {access: APublic, pos: Position.nullPos}];
					field.cffMeta = [{name: ":enum", params: [], pos: Position.nullPos}].concat(field.cffMeta);
					var effCt:TypeHint = ct != null ? ct : aT;

					switch (eo) {
						case null:
							// On an extern implementation a value-less member keeps no synthesized value:
							// it stays a real extern property so it compiles to a native field access (its
							// value comes from the platform), rather than getting an inline ordinal/string.
							if (TypeFunctions.hasClassFlag(c, CExtern)) {
								field.cffKind = FProp({name: "default", pos: Position.nullPos}, {name: "never", pos: Position.nullPos}, effCt, null);
							} else if (modeString) {
								setField(field, effCt, new Expr(EConst(CString(field.cffName.name, SDoubleQuotes)), field.cffPos));
							} else if (modeInt) {
								setField(field, effCt, new Expr(EConst(CInt(Std.string(intCounter), null)), field.cffPos));
								intCounter++;
							} else {
								throw new ContextError("Value required", field.cffPos);
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
