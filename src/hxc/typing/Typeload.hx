package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypingError;
import hxc.core.TypeUnification;
import hxc.core.WithType.WithTypeTools;
import hxc.core.NotFound;
import hxc.core.Ref;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.context.Context.ContextError;
import haxe.ds.StringMap;

private typedef GenericSubstEntry = {from:T, to:T, expr:Null<TExpr>};

class Typeload {
	static final pNull = Position.nullPos;
	static var genericInstanceId:Int = 0;
	static var genericInstances:Map<String, TClass> = new Map();

	// Per-request reset for the wait server (specializations belong to the request module set).
	public static function resetPerRequest():Void {
		genericInstanceId = 0;
		genericInstances = new Map();
	}

	public static function typeTypeParam(ctx:Context, declPath:Path, getParams:Void->TypeParams, tp:TypeParam, host:TypeParamHost = TPHType, ?declModule:ModuleDef):TypedTypeParam {
		var n = tp.tpName.name;
		// A default type parameter is only allowed on a type declaration, not on a constructor, method, or
		// enum constructor.
		if (tp.tpDefault != null && host != TPHType)
			ctx.addDiagnostic("Default type parameters are only supported on types", tp.tpDefault.pos);
		// The parameter's class path is the declaring path with the parameter's name: it lives under
		// <module>.<Type>.<N>.
		// The parameter's class belongs to the module declaring it. A null module leaves its moduleName
		// empty
		// everywhere the path is serialized, and currentModule is not it for a macro-defined type, whose
		// declarations are typed while the module that TRIGGERED the macro is still current.
		var pmod = declModule != null ? declModule : (ctx.currentModule != null ? ctx.currentModule : TypeFunctions.nullModule);
		var c = TypeFunctions.mkClass(pmod, {pack: declPath.pack.concat([declPath.name]), name: n}, tp.tpName.pos, tp.tpName.pos);
		c.kind = KTypeParameter([]);
		c.meta = tp.tpMeta;
		var t = TInst(c, []);
		var p = tp.tpName.pos;
		var declModulePath:Path = {pack: declPath.pack, name: declPath.name};
		// A method/constructor/enum-constructor type param has a synthetic declPath ({[], name}) that
		// names no module, so moduleLut cannot recover its declaring module when the constraint is forced
		// later from another module. Capture the module being processed now (field resolution runs with
		// currentModule set to the owning module) so a constraint that resolves through the declaring
		// module's imports still resolves. Only used for non-type params: a type param recovers its
		// module through moduleLut or typeToModule at force time.
		var declaringModule = host != TPHType ? ctx.currentModule : null;
		function defaultType():Null<T> {
			if (tp.tpDefault == null) return null;
			var r:Ref<TLazy> = new Ref(TypeFunctions.lazyWait(function():T {
				var savedMod = ctx.currentModule;
				var declMod = ctx.moduleLut.get(Context.pathKey(declModulePath));
				if (declMod != null) ctx.currentModule = declMod;
				try {
					var def = loadComplexType(ctx, getParams(), tp.tpDefault);
					ctx.currentModule = savedMod;
					return def;
				} catch (e:Dynamic) {
					ctx.currentModule = savedMod;
					throw e;
				}
			}));
			return TLazy(r);
		}
		var def = defaultType();
		if (tp.tpConstraints == null) {
			return TypeFunctions.mkTypeParam(n, t, def);
		}
		var th = tp.tpConstraints;
		// The constraint may reference a type IMPORTED by the declaring module (e.g. `pipe<T:IWritable>`
		// in js.node.stream.Readable, where `IWritable` is a named import). Lazy force happens later,
		// while typing some other module, so currentModule is wrong by then. For a TYPE-level param
		// (declPath is a real module path registered in moduleLut) restore currentModule to the declaring
		// module for the duration of constraint loading. For a method-local param (declPath is a
		// synthetic
		// {[],methodName}) no module is registered, so we keep the current context, which is the right
		// module at force time (field typing). Protected lazy: a Ref<TLazy> whose LProcessing/LWait thunk
		// loads the constraints on first force, then caches as LAvailable.
		var r:Ref<TLazy> = new Ref(TypeFunctions.lazyAvailable(t));
		r.set(TypeFunctions.lazyWait(function():T {
			r.set(TypeFunctions.lazyProcessing(function():T return t));
			var savedMod = ctx.currentModule;
			var declMod = ctx.moduleLut.get(Context.pathKey(declModulePath));
			if (declMod == null) {
				// A SUB-TYPE decl (typedef T2 inside module M) has no module of its own path;
				// typeToModule recovers the defining module so its sibling types stay visible.
				var mp = ctx.typeToModule.get(Context.pathKey(declModulePath));
				if (mp != null) declMod = ctx.moduleLut.get(Context.pathKey(mp));
			}
			if (declMod == null) declMod = declaringModule;
			if (declMod != null) ctx.currentModule = declMod;
			try {
				// The type parameters in scope, extended with the declaration's own (getParams).
				var typeParams = getParams();
				function loop(h:TypeHint):Array<T> {
					return switch (h.ct) {
						case CTIntersection(tl): [for (ct in tl) loadComplexType(ctx, typeParams, ct)];
						case CTParent(ct): loop(ct);
						case _: [loadComplexType(ctx, typeParams, h)];
					}
				}
				var constr = loop(th);
				// Check against direct recursion
				function checkRec(ty:T):Void {
					switch (TypeFunctions.follow(ty)) {
						case TInst(c2, _) if (c2 == c):
							throw new ContextError("Recursive constraint parameter is not allowed", p);
						case TInst(c2, _):
							switch (c2.kind) {
								case KTypeParameter(cl): for (ct in cl) checkRec(ct);
								case _:
							}
						case _:
					}
				}
				for (ct in constr) checkRec(ct);
				// The class becomes a KTypeParameter carrying its constraints.
				c.kind = KTypeParameter(constr);
				r.set(TypeFunctions.lazyAvailable(t));                     
				ctx.currentModule = savedMod;
				return t;
			} catch (e:ContextError) {
				// DEFER-WITH-NOTE: a constraint type that hxc cannot RESOLVE (a pre-existing import
				// gap unrelated to Gap #8, notably SUB-TYPE imports like
				// `import js.node.stream.Writable.IWritable;` used by hxnodejs `Readable.pipe<T:IWritable>`,
				// regress the bootstrap on stdlib type params whose constraint type is unresolvable.
				// Degrade gracefully to the prior behaviour (no constraint) so field access through
				// extra constraint-driven lookups). Resolution-class errors only, real constraint
				// problems (recursion, genuine unify failures) still propagate.
				if (StringTools.startsWith(e.message, "Module not found")
					|| StringTools.startsWith(e.message, "Type not found")) {
					if (Sys.getEnv("HXC_DEBUG_CONSTRAINT") != null)
						Sys.println("[cdegrade] " + n + " on " + Context.sTypePath(c.path) + ": " + e.message);
					c.kind = KTypeParameter([]);
					r.set(TypeFunctions.lazyAvailable(t));
					ctx.currentModule = savedMod;
					return t;
				}
				ctx.currentModule = savedMod;
				throw e;
			} catch (e:Dynamic) {
				ctx.currentModule = savedMod;
				throw e;
			}
		}));
		return TypeFunctions.mkTypeParam(n, TLazy(r), def);
	}

	public static function typeTypeParams(ctx:Context, declPath:Path, tps:Array<TypeParam>, ?baseParams:TypeParams, host:TypeParamHost = TPHType, ?declModule:ModuleDef):TypeParams {
		// Returns the sibling params so a
		// first, then hand each param a thunk closing over it.
		var params:TypeParams = [];
		if (baseParams == null) baseParams = [];
		var getParams = function():TypeParams return params.concat(baseParams);
		var names:Array<String> = [];
		for (tp in tps) {
			// A repeated type-parameter name is reported and typing continues.
			if (names.indexOf(tp.tpName.name) >= 0)
				ctx.addDiagnostic("Duplicate type parameter name: " + tp.tpName.name, tp.tpName.pos);
			names.push(tp.tpName.name);
			params.push(typeTypeParam(ctx, declPath, getParams, tp, host, declModule));
		}
		return params;
	}

	public static function loadTypeHint(ctx:Context, typeParams:TypeParams, t:Null<TypeHint>, opt:Bool = false):T {
		var ty = (t == null)
			? spawnMonomorph()
			// A type HINT is a display-allowed load, so a resolvable path under the cursor reports through
			// the
			// display type check.
			: loadComplexType(ctx, typeParams, t, true);
		return opt ? ctx.basic.tnull(ty) : ty;
	}

	static function spawnMonomorph():T {
		return TypeFunctions.mkMono();
	}

	// A PACKAGE-LESS path that does not resolve recovers to Dynamic wherever the run tolerates errors,
	// so the rest of the declaration still types and the report can describe the name rather than stop
	// at it. A PACKAGED path keeps its error, and so does a bare one with the cursor inside the hint,
	// where the name is the subject of the request. In a diagnostics run the name is recorded as an
	// unresolved identifier instead, which is what turns it into DKUnresolvedIdentifier rather than a
	// compiler error.
	public static function loadComplexType(ctx:Context, typeParams:TypeParams, th:TypeHint, allowDisplay:Bool = false):T {
		return try loadComplexTypePrime(ctx, typeParams, th.ct, th.pos, allowDisplay)
		catch (exc:ContextError) {
			var name = switch (exc.kind) {
				case ModuleNotFound(m) if (m.pack.length == 0): m.name;
				case _: throw exc;
			};
			if (ctx.errorInDiagnosticsRun(exc.pos)) {
				var p = exc.pos;
				ctx.delay(Context.PForce, function() hxc.typing.Typer.handleUnresolvedIdentifier(ctx, name, p));
				TypeFunctions.tDynamic;
			} else if (ctx.ignoreError() && !hxc.typing.Typer.atDisplayPos(th.pos)) {
				TypeFunctions.tDynamic;
			} else throw exc;
		}
	}

	static function loadComplexTypePrime(ctx:Context, typeParams:TypeParams, t:ComplexType, p:Position, allowDisplay:Bool = false):T {
		return switch (t) {
			case CTParent(th):
				loadComplexType(ctx, typeParams, th, allowDisplay);

			// The path `$._hx_mono` spawns a monomorph.
			case CTPath(tp) if (tp.tpackage.length == 1 && tp.tpackage[0] == "$" && tp.tname == "_hx_mono"):
				spawnMonomorph();

			case CTPath(tp):
				loadInstance(ctx, typeParams, tp, p, false, true, allowDisplay);

			case CTOptional(_):
				throw new ContextError("Optional type not allowed here", p);

			case CTNamed(_, _):
				throw new ContextError("Named type not allowed here", p);

			case CTIntersection(tl):
				// The type list an intersection member raises is re-raised filtered to STRUCTURES, as
				// CRStructExtension over an intersection type.
				var resolved = [for (th in tl) {t: try loadComplexType(ctx, typeParams, th, allowDisplay)
						catch (tc:hxc.compiler.DisplayXml.ToplevelCompletion) throw structExtensionCompletion(ctx, tc, true),
					pos: th.pos}];
				makeExtensionType(ctx, resolved, p);

			case CTExtend(paths, fields):
				var anonT = loadComplexTypePrime(ctx, typeParams, CTAnonymous(fields), p, allowDisplay);
				switch (anonT) {
					case TAnon(a):
						// The type list a `> <cursor>` raises is re-raised filtered to STRUCTURES, since
						// only a structure
						// can extend one.
						var il = [for (pt in paths) {
							t: try loadInstance(ctx, typeParams, pt.path, pt.pos, false, true, allowDisplay)
								catch (tc:hxc.compiler.DisplayXml.ToplevelCompletion) throw structExtensionCompletion(ctx, tc, false),
							pos: pt.pos}];
						if (il.length == 1) {
							mkExtension(ctx, a, il[0].t, il[0].pos);
						} else {
							for (e in il) extendLoop(ctx, a, e.t, e.pos);
							a.status.set(Extend([for (e in il) e.t]));
							anonT;
						}
					case _:
						throw new ContextError("Cannot structurally extend", p);
				}

			case CTAnonymous(l):
				loadAnonymous(ctx, typeParams, l, p, allowDisplay);

			case CTFunction(args, ret):
				loadFunctionType(ctx, typeParams, args, ret, p, allowDisplay);
		}
	}

	// Only a STRUCTURE can extend one, so the type-hint collection raised from inside an extension is
	// re-raised filtered to those, as CRStructExtension (7). The flag records whether the extension was
	// written as an intersection.
	static function structExtensionCompletion(ctx:Context, tc:hxc.compiler.DisplayXml.ToplevelCompletion,
			isIntersection:Bool):hxc.compiler.DisplayXml.ToplevelCompletion {
		var items = [for (it in tc.items) if (it.kind == "type" && isStructureTypeItem(ctx, it)) it];
		var mts:Null<Array<ModuleType>> = tc.moduleTypes == null ? null
			: [for (mt in tc.moduleTypes) if (TypeFunctions.follow(TypeFunctions.typeOfModuleType(mt)).match(TAnon(_))) mt];
		var out = new hxc.compiler.DisplayXml.ToplevelCompletion(items, mts);
		out.kind = 7;
		out.structExtensionIsIntersection = isIntersection;
		out.subjectPos = tc.subjectPos;
		out.subjectName = tc.subjectName;
		return out;
	}

	// CompletionModuleKind.Struct: a typedef whose right-hand side is an anonymous structure. That is
	// the only kind an extension keeps.
	static function isStructureTypeItem(ctx:Context, it:hxc.compiler.DisplayXml.ToplevelItem):Bool {
		if (it.path == null) return false;
		// Resolve against what is already loaded rather than through getType: the module the hint is
		// written in is mid-load, and asking the loader for one of its own types while it is loading
		// answers nothing.
		function isStruct(mt:ModuleType):Bool return switch (mt) {
			case TTypeDecl(td): TypeFunctions.follow(td.type).match(TAnon(_));
			case _: false;
		};
		inline function pathOf(mt:ModuleType):String return hxc.core.Globals.sTypePath(TypeFunctions.tInfos(mt).path);
		if (ctx.currentModule != null)
			for (mt in ctx.currentModule.types) if (pathOf(mt) == it.path) return isStruct(mt);
		for (key in ctx.moduleLut.keys())
			for (mt in ctx.moduleLut.get(key).types) if (pathOf(mt) == it.path) return isStruct(mt);
		return false;
	}

	// CTExtend helpers do not check is_redefined.

	// A forward-referenced typedef in the same module resolves on demand before its follow.
	static function followOnDemand(ctx:Context, it:T):T {
		var ft = TypeFunctions.follow(it);
		if (!ft.match(TAnon(_))) switch (it) {
			case TType(td, _):
				hxc.typing.TypeResolve.resolveTypeOnDemand(ctx, TTypeDecl(td));
				ft = TypeFunctions.follow(it);
			case _:
		}
		return ft;
	}

	static function mkExtension(ctx:Context, a:TAnon, it:T, p:Position):T {
		return switch (followOnDemand(ctx, it)) {
			case TInst(c, _) if (isTypeParameter(c)):
				throw new ContextError("Cannot structurally extend type parameters", p);
			case TMono(_):
				throw new ContextError("Loop found in cascading signatures definitions. Please change order/import", p);
			case TAnon(a2):
				var merged = new StringMap<TClassField>();
				for (k in a2.fields.keys()) merged.set(k, a2.fields.get(k));
				for (k in a.fields.keys()) merged.set(k, a.fields.get(k));
				TypeFunctions.mkAnon(new Ref<AnonStatus>(Extend([it])), merged);
			case _:
				throw new ContextError("Can only extend structures", p);
		}
	}

	static function extendLoop(ctx:Context, a:TAnon, it:T, p:Position):Void {
		switch (followOnDemand(ctx, it)) {
			case TAnon(a2):
				for (k in a2.fields.keys()) if (!a.fields.exists(k)) a.fields.set(k, a2.fields.get(k));
			case _:
				throw new ContextError("Can only extend structures", p);
		}
	}

	static function makeExtensionType(ctx:Context, tl:Array<{t:T, pos:Position}>, p:Position):T {
		// Minimal subset equivalent of make_extension_type: merge the resolved anons. A forward-referenced
		// typedef in the same module resolves on demand first. A non-structure component errors at its own
		// hint keeps per-component pos).
		var merged = new StringMap<TClassField>();
		for (e in tl) {
			var ft = TypeFunctions.follow(e.t);
			if (!ft.match(TAnon(_))) switch (e.t) {
				case TType(td, _):
					hxc.typing.TypeResolve.resolveTypeOnDemand(ctx, TTypeDecl(td));
					ft = TypeFunctions.follow(e.t);
				case _:
			}
			switch (ft) {
				case TAnon(a2):
					for (k in a2.fields.keys()) merged.set(k, a2.fields.get(k));
				case _:
					throw new ContextError("Can only extend structures", e.pos);
			}
		}
		return TypeFunctions.mkAnon(new Ref<AnonStatus>(Extend([for (e in tl) e.t])), merged);
	}

	static function isTypeParameter(c:TClass):Bool {
		return switch (c.kind) { case KTypeParameter(_): true; case _: false; };
	}

	static function loadFunctionType(ctx:Context, typeParams:TypeParams, args:Array<TypeHint>, ret:TypeHint, p:Position, allowDisplay:Bool = false):T {
		if (args.length == 1) {
			switch (args[0].ct) {
				case CTPath(tp) if (tp.tpackage.length == 0 && tp.tparams.length == 0 && tp.tname == "Void"):
					return TFun({args: [], ret: loadComplexType(ctx, typeParams, ret, allowDisplay)});
				case _:
			}
		}
		var sigArgs:Array<TSignatureArg> = [];
		for (th in args) {
			var inner = th;
			var opt = false;
			switch (th.ct) {
				case CTOptional(t2): inner = t2; opt = true;
				case CTParent(t2):
					switch (t2.ct) {
						case CTOptional(t3): inner = t3; opt = true;
						case _:
					}
				case _:
			}
			// CTNamed (n,t) -> name=n, t; else name=""
			var name = "";
			switch (inner.ct) {
				case CTNamed(n, t3): name = n.name; inner = t3;
				case _:
			}
			sigArgs.push({name: name, opt: opt, t: loadComplexType(ctx, typeParams, inner, allowDisplay)});
		}
		return TFun({args: sigArgs, ret: loadComplexType(ctx, typeParams, ret, allowDisplay)});
	}

	// CTAnonymous l -> TAnon (subset of/`topt` machinery)
	static function loadAnonymous(ctx:Context, typeParams:TypeParams, l:Array<ClassField>, p:Position, allowDisplay:Bool = false):T {
		var fields = new StringMap<TClassField>();
		for (f in l) {
			var n = f.cffName.name;
			var pf = f.cffName.pos;
			if (fields.exists(n)) throw new ContextError("Duplicate field declaration : " + n, pf);

			// A structure field called `new` predates haxe.Constraints.Constructible and is on its way out.
			if (n == "new")
				ctx.warning(hxc.core.WarningList.Warning.WDeprecated, hxc.core.WarningList.fromMeta(f.cffMeta),
					"Structures with new are deprecated, use haxe.Constraints.Constructible instead", f.cffPos);
			// `p` is the field's position for the whole body of this loop, so a complaint points at the
			// field, not at the enclosing structure.
			var p = f.cffPos;

			function topt(t:Null<TypeHint>):T {
				if (t == null) throw new ContextError("Explicit type required for field " + n, p);
				return loadComplexType(ctx, typeParams, t, allowDisplay);
			}
			// noExpr: a structure describes a SHAPE, so nothing in it may carry a value:
			// not a field initialiser, not a method body, not an argument default.
			function noExpr(e:Null<Expr>):Void {
				if (e != null) throw new ContextError("Expression not allowed here", e.pos);
			}

			var pub = true;
			var dyn = false;
			var isFinal = false;
			for (a in f.cffAccess) switch (a.access) {
				case APublic:
				case APrivate: pub = false;
				case ADynamic if (switch (f.cffKind) { case FFun(_): true; case _: false; }): dyn = true;
				case AFinal: isFinal = true;
				// The message prints the ACCESS KEYWORD (Ast.sAccess), not the enum constructor name.
				case other: throw new ContextError("Invalid access " + hxc.ast.Ast.sAccess(other), p);
			}

			var t:T;
			var access:FieldKind;
			var params:TypeParams = [];
			switch (f.cffKind) {
				// The FINAL arm comes first, so `final a:Void` is never reached by the Void
				// check below.
				case FVar(th, e) if (isFinal):
					noExpr(e);
					if (th == null) throw new ContextError("Type required for structure property", p);
					t = loadComplexType(ctx, typeParams, th, allowDisplay);
					access = Var({read: AccNormal, write: AccNever});
				// One arm covers both a Void variable and a Void property.
				case FVar({ct: CTPath(tp)}, _) | FProp(_, _, {ct: CTPath(tp)}, _)
					if (tp.tpackage.length == 0 && tp.tname == "Void"):
					throw new ContextError("Fields of type Void are not allowed in structures", p);
				case FVar(th, e):
					noExpr(e);
					t = topt(th);
					access = Var({read: AccNormal, write: AccNormal});
				case FFun(fd):
					// Function field: TFun(args, ret) from hints (subset: no type-param scope
					// extension for method-local params, annotations only).
					if (fd.fParams.length > 0) params = typeTypeParams(ctx, {pack: [], name: n}, fd.fParams, typeParams);
					noExpr(fd.fExpr);
					for (fa in fd.fArgs) noExpr(fa.value);
					var localTypeParams = params.length > 0 ? params.concat(typeParams) : typeParams;
					function ftopt(th:Null<TypeHint>):T {
						if (th != null) return loadComplexType(ctx, localTypeParams, th);
						// An unannotated arg or return on a method with a body is inferred when the body
						// is typed; only a body-less (extern) field must state its type explicitly.
						if (fd.fExpr != null) return TypeFunctions.mkMono();
						throw new ContextError("Explicit type required for field " + n, p);
					}
					var fargs:Array<TSignatureArg> = [for (fa in fd.fArgs) {name: fa.name.name, opt: fa.opt, t: ftopt(fa.type)}];
					t = TFun({args: fargs, ret: ftopt(fd.fType)});
					access = Method(dyn ? MethDynamic : MethNormal);
				case FProp(get, set, th, e):
					noExpr(e);
					function acc(m:PlacedName, isGet:Bool):VarAccess {
						return switch (m.name) {
							case "null": AccNo;
							case "never": AccNever;
							case "default": AccNormal;
							case "dynamic": AccCall;
							case "get" if (isGet): AccCall;
							case "set" if (!isGet): AccCall;
							case x if (isGet && x == "get_" + n): AccCall;
							case x if (!isGet && x == "set_" + n): AccCall;
							case _: throw new ContextError("Custom property access is no longer supported in Haxe 3", f.cffPos);
						}
					}
					if (th == null) throw new ContextError("Type required for structure property", p);
					t = loadComplexType(ctx, typeParams, th, allowDisplay);
					access = Var({read: acc(get, true), write: acc(set, false)});
			}

			// @:optional -> Null<t>
			if (TypeFunctions.hasMeta(":optional", f.cffMeta)) t = ctx.basic.tnull(t);

			var cf = TypeFunctions.mkField(n, t, f.cffPos, f.cffName.pos, pub, false);
			cf.kind = access;
			cf.doc = f.cffDoc;
			cf.meta = f.cffMeta;
			cf.params = params;
			if (isFinal) cf.flags = Flags.setFlag(cf.flags, TypeFunctions.intOfClassFieldFlag(CfFinal));
			// The cursor on a structure field's name answers with that field. The reference delays it to
			// PBuildClass so the whole anon exists first; here the field's own type is already built, which
			// is all the answer needs.
			if (hxc.typing.Typer.atDisplayPos(cf.namePos)) hxc.typing.Typer.displayAnonField(cf);
			fields.set(n, cf);
		}
		return TypeFunctions.mkAnon(new Ref<AnonStatus>(Closed), fields);
	}

	// Resolve a type path to its module type (part of loading a type instance: no generics,
	// display or expression parameters).
	public static function resolveTypePath(ctx:Context, path:Path, sub:Null<String>, p:Position):ModuleType {
		if (path.pack.length > 0 && path.pack[0] == "std") {
			path = {pack: path.pack.slice(1), name: path.name};
		}
		if (sub == null && path.pack.length == 0 && ctx.currentModule != null) {
			for (mt in ctx.currentModule.types) {
				if (TypeFunctions.tInfos(mt).path.name == path.name) return mt;
			}
		}
		// Unqualified resolution order: current module, then explicit imports (latest first), then the
		// implicit StdTypes import at the tail of that list, then wildcard imports, then modules from the
		// current package up to the root. A plain `import lime.app.Application` therefore shadows a
		// same-package Application, and a core type (Void/Int/...) is never shadowed by a same-package type
		// of the same name.
		if (sub == null && path.pack.length == 0 && ctx.currentModule != null) {
			var imp = hxc.context.ModuleLoader.resolveNamedImportType(ctx, ctx.currentModule, path.name, p);
			if (imp != null) return imp;
		}
		if (sub == null && path.pack.length == 0) {
			var std = try hxc.context.ModuleLoader.loadModule(ctx, {pack: [], name: "StdTypes"}, p) catch (_:Dynamic) null;
			if (std != null) {
				var stdT = hxc.context.ModuleLoader.findTypeInModuleOpt(std, path.name);
				if (stdT != null) return stdT;
			}
		}
		if (sub == null && path.pack.length == 0 && ctx.currentModule != null) {
			var imp = hxc.context.ModuleLoader.resolveWildcardImportType(ctx, ctx.currentModule, path.name, p);
			if (imp != null) return imp;
		}
		if (sub == null && path.pack.length == 0 && ctx.currentModule != null
				&& ctx.currentModule.path.pack.length > 0) {
			var sib = hxc.context.ModuleLoader.resolveSamePackageSibling(ctx, ctx.currentModule, path.name, p);
			if (sib != null) return sib;
		}
		if (sub != null && path.pack.length == 0 && ctx.currentModule != null
				&& ctx.currentModule.path.pack.length > 0) {
			var pack = ctx.currentModule.path.pack;
			var i = pack.length;
			while (i >= 1) {
				var tryPack = pack.slice(0, i);
				var m = try hxc.context.ModuleLoader.loadModule(ctx, {pack: tryPack, name: path.name}, p) catch (_:Dynamic) null;
				if (m != null) {
					var mt = hxc.context.ModuleLoader.findTypeInModuleOpt(m, sub);
					if (mt != null) return mt;
				}
				i--;
			}
		}
		if (sub != null && path.pack.length == 0) {
			for (m in ctx.modules) {
				if (m.path.name != path.name) continue;
				var mt = hxc.context.ModuleLoader.findTypeInModuleOpt(m, sub);
				if (mt != null) return mt;
			}
		}
		try {
			return ctx.getType(path, p, sub);
		} catch (e:Dynamic) {
			if (path.pack.length == 0 && sub == null && ctx.currentModule != null) {
				var r = hxc.context.ModuleLoader.resolveBareType(ctx, ctx.currentModule, path.name, p);
				if (r != null) return r;
			}
			if (path.pack.length > 0 && sub == null && ctx.currentModule != null) {
				var r = hxc.context.ModuleLoader.resolveQualifiedType(ctx, ctx.currentModule, path, p);
				if (r != null) return r;
			}
			throw e;
		}
	}

	// Lazily run the annotation-resolution pass on a referenced module so its abstract from/to (and
	// field/heritage) data is populated before use. Idempotent, re-entrant-safe (skips the
	// currently-resolving module). Saves/restores currentModule. Guard is `>= 1` (already at/past
	// annotation-resolution), not `== 1`: a module that has advanced to stage 2 (field bodies typed)
	// must not be re-resolved here, re-resolving rebuilds field `type`s with fresh unbound monos and
	// discards inferred return types
	static function ensureResolved(ctx:Context, m:ModuleDef):Void {
		if (m == null || m.extra.resolved >= 1) return;
		var saved = ctx.currentModule;
		try {
			TypeResolve.resolveModule(ctx, m);
		} catch (_:Dynamic) {}
		ctx.currentModule = saved;
	}

	// Every type path loaded records (module, occurrence, resolved type). Each is later resolved to the
	// declaration's name position and turned into a Referenced relation. Without it a type is only ever
	// found through an EXPRESSION, so a reference from a type hint (an extends clause, an argument hint,
	// an abstract's underlying type) is invisible to @usage.
	public static var typeHints:Array<{m:Null<ModuleDef>, p:Position, t:T}> = [];

	// The toplevel collection a type position answers includes the type PARAMETERS in scope. hxc
	// reaches that collection through ctx.getType, which is a Context closure with no typer state, so
	// the parameters the load was given are recorded here.
	public static var currentTypeParams:TypeParams = [];

	public static function loadInstance(ctx:Context, typeParams:TypeParams, t:TypePath, p:Position, allowNoParams:Bool, ?specializeGeneric:Bool = true, allowDisplay:Bool = false):T {
		var savedTp = currentTypeParams;
		currentTypeParams = typeParams;
		try {
			var res = loadInstanceInner(ctx, typeParams, t, p, allowNoParams, specializeGeneric, allowDisplay);
			currentTypeParams = savedTp;
			return res;
		} catch (e:Dynamic) {
			currentTypeParams = savedTp;
			throw e;
		}
	}

	static function loadInstanceInner(ctx:Context, typeParams:TypeParams, t:TypePath, p:Position, allowNoParams:Bool, ?specializeGeneric:Bool = true, allowDisplay:Bool = false):T {
		// A type path that does not resolve, with the cursor on it, is a completion request rather than
		// an error - the name is what the user is still typing.
		var r = if (hxc.parser.Parser.displayCompletionMode && hxc.typing.Typer.atDisplayPos(p))
			try loadInstance_(ctx, typeParams, t, p, allowNoParams, specializeGeneric)
			catch (e:ContextError) {
				if (e.message.indexOf("Type not found") != 0) throw e;
				// The subject is the path the user wrote, and the range it replaces is that path's own span.
				var sname = t.tsub != null ? t.tsub : t.tname;
				var sfull = (t.tpackage.length == 0 ? "" : t.tpackage.join(".") + ".") + t.tname + (t.tsub != null ? "." + t.tsub : "");
				var sp = new Position(p.file, p.min, p.min + sfull.length);
				hxc.typing.TypeResolve.answerTypeHintCompletion(ctx, sp, sfull);
				throw e;
			}
		else loadInstance_(ctx, typeParams, t, p, allowNoParams, specializeGeneric);
		// The hint list only feeds the reference searches, so it is collected only for them.
		if (hxc.typing.Typer.displayUsage || hxc.typing.Typer.displayImplementation)
			typeHints.push({m: ctx.currentModule, p: p, t: r});
		if (hxc.parser.Parser.displayFile != null) {
			// The path's range is narrowed to the dotted name itself, so `Array<Foo>` with the cursor on
			// Foo
			// answers Foo and not Array.
			var strings = t.tsub != null ? [t.tsub, t.tname].concat(t.tpackage) : [t.tname].concat(t.tpackage);
			var pName = new Position(p.file, p.min, p.min + strings.join(".").length);
			if (hxc.typing.Typer.atDisplayPos(pName)) {
				var mt = try TypeFunctions.moduleTypeOfType(r) catch (_:hxc.core.ExitException) null;
				if (mt != null) hxc.typing.Typer.displayModuleType(ctx, mt, pName, allowDisplay);
			}
		}
		return r;
	}

	static function loadInstance_(ctx:Context, typeParams:TypeParams, t:TypePath, p:Position, allowNoParams:Bool, ?specializeGeneric:Bool = true):T {
		// Look up a bare type-parameter name before resolving a module.
		if (t.tpackage.length == 0 && t.tsub == null) {
			var pt:Null<T> = TypeFunctions.lookupParam(t.tname, typeParams);
			if (pt != null) {
				if (t.tparams.length > 0)
					throw new ContextError("Class type parameter " + t.tname + " can't have parameters", p);
				return pt;
			}
		}

		// Resolve the type definition through the context.
		var path:Path = {pack: t.tpackage, name: t.tname};
		var mt = resolveTypePath(ctx, path, t.tsub, p);
		ensureResolved(ctx, TypeFunctions.tInfos(mt).module);
		var types = TypeFunctions.tInfos(mt).params;
		var declPath = TypeFunctions.tPath(mt);
		var build = function(params:TParams):T return buildInstance(ctx, mt, params, p, specializeGeneric, typeParams);
		var isGenericBuild = switch (mt) {
			case TClassDecl(c): switch (c.kind) { case KGenericBuild(_): true; case _: false; }
			case _: false;
		};
		var isGeneric = switch (mt) {
			case TClassDecl(c): c.kind.match(KGeneric);
			case _: false;
		};
		var isRestGenericBuild = isGenericBuild && types.length == 1 && types[0].name == "Rest";

		// Allow_no_params && no syntactic params -> spawn constrained monos for each param.
		if (allowNoParams && t.tparams.length == 0 && !isRestGenericBuild) {
			var monos = hxc.core.TypeUnification.spawnConstrainedMonos(function(t) return t, types);
			return build(monos);
		}

		if (declPath.pack.length == 0 && declPath.name == "Dynamic") {
			return switch (t.tparams) {
				case []: TypeFunctions.tDynamic;
				case [TPType(th)]: TDynamic(loadComplexType(ctx, typeParams, th));
				case _: throw new ContextError("Too many parameters for Dynamic", p);
			}
		}

		var loadParam = function(tp:TypeParamOrConst):T {
			return switch (tp) {
				case TPType(th): loadComplexType(ctx, typeParams, th);
				case TPExpr(e):
					var name = switch (e.expr) {
						case EConst(CString(s, _)): "S" + s;
						case EConst(CInt(v, _)): "I" + v;
						case EConst(CFloat(f, _)): "F" + f;
						case _: hxc.ast.Printer.sExprInner("", e);
					};
					var m = ctx.currentModule != null ? ctx.currentModule : TypeFunctions.nullModule;
					var c = TypeFunctions.mkClass(m, {pack: [], name: name}, p, e.pos);
					c.kind = KExpr(e);
					TInst(c, []);
			}
		};

		// Loop tl1 tl2, pair syntactic params with declaration params (subset: no Rest,
		// no java-rest, no generic-build). Faithful arity behaviour: too few -> default or
		// error; too many -> error.
		if (isRestGenericBuild)
			return build([for (tp in t.tparams) loadParam(tp)]);

		var params:TParams = [];
		var checks:Array<{t:T, c:TClass, p:Position}> = [];
		var i1 = 0, i2 = 0;
		while (true) {
			if (i1 < t.tparams.length && i2 < types.length) {
				var loaded = loadParam(t.tparams[i1]);
				var pt = switch (t.tparams[i1]) {
					case TPType(th): th.pos;
					case TPExpr(e): e.pos;
				};
				// Following the declaration param forces its constraint lazy; an unconstrained param of a
				// non-generic type needs no check.
				switch (TypeFunctions.follow(types[i2].type)) {
					case TInst({kind: KTypeParameter([])}, []) if (!isGeneric):
					case TInst(c2, []): checks.push({t: loaded, c: c2, p: pt});
					case _:
				}
				params.push(loaded);
				i1++; i2++;
			} else if (i1 >= t.tparams.length && i2 >= types.length) {
				break;
			} else if (i1 >= t.tparams.length) {
				// A parameter past the given ones: its default, if it has one.
				var def = types[i2].defaultType;
				if (def == null) {
					// A display request fills the missing parameter with the declaration's own, so the path
					// still LOADS
					// and the type it names can be reported instead of the request failing over an arity
					// the user is
					// mid-typing.
					if (!ctx.ignoreErrors)
						throw new ContextError("Not enough type parameters for " + Context.sTypePath(declPath), p);
					params.push(types[i2].type);
					i2++;
					continue;
				}
				params.push(def);
				i2++;
			} else {
				// Too many arguments: reported at the first EXCESS argument.
				var pt = switch (t.tparams[i1]) { case TPType(th): th.pos; case TPExpr(e): e.pos; };
				// A display request DROPS the excess ones for the same reason.
				if (ctx.ignoreErrors) break;
				throw new ContextError("Too many type parameters for " + Context.sTypePath(declPath), pt);
			}
		}
		if (checks.length > 0) {
			// Substitute the declaration params with the applied ones; a KGeneric constraint is replaced by
			// its
			// actual generic instance before unifying.
			var map = function(tt:T):T {
				var t2 = TypeFunctions.applyParams(types, params, tt);
				return switch (TypeFunctions.follow(t2)) {
					case TInst(c2 = {kind: KGeneric}, pl): buildInstance(ctx, TClassDecl(c2), pl, p, true, typeParams);
					case _: t2;
				};
			};
			for (chk in checks)
				ctx.pendingConstraintChecks.push(function() checkParamConstraints(ctx, chk.t, map, chk.c, chk.p));
		}
		return build(params);
	}

	static function checkParamConstraints(ctx:Context, t:T, map:T->T, c:TClass, p:Position):Void {
		switch (TypeFunctions.follow(t)) {
			case TMono(_): return;
			case _:
		}
		var ctl = switch (c.kind) { case KTypeParameter(l): l; case _: []; };
		if (Sys.getEnv("HXC_DEBUG_CONSTRAINT") != null) {
			var info = switch (TypeFunctions.follow(t)) {
				case TInst(ca, _): "applied=" + Context.sTypePath(ca.path) + " kind=" + Std.string(ca.kind);
				case other: "applied follow=" + Std.string(other);
			};
			Sys.println("[cchk] decl=" + Context.sTypePath(c.path) + " ctl=" + ctl.length + " " + info);
		}
		for (ti0 in ctl) {
			var ti = map(ti0);
			var err:Null<hxc.core.TypeUnification.UnifyError> = null;
			try TypeUnification.unifyDefault(t, ti) catch (e:hxc.core.TypeUnification.UnifyError) err = e;
			if (err == null) continue;
			var errors = err.errors;
			function fail():Void {
				var msg = hxc.core.TPrinting.betterErrorMessage(
					([hxc.core.TypeUnification.UnifyErrorKind.Constraint_failure(Context.sTypePath(c.path))]).concat(errors));
				// A failed eager generic build has already been reported and typing continues, so a check
				// that
				// repeats that failure at the same site (the eager report anchors inside the same hint)
				// stays
				// silent.
				for (d in ctx.diagnostics)
					if (d.message == msg && d.pos != null && d.pos.file == p.file
						&& d.pos.min <= p.max && d.pos.max >= p.min) return;
				ctx.addDiagnostic(msg, p);
			}
			switch (TypeFunctions.follow(t)) {
				case TInst({kind: KExpr(e)}, _):
					// A constant argument is typed against the constraint.
					var tctx = new TyperContext(ctx);
					var te = Typer.typeExpr(tctx, e, WithTypeTools.withType(ti));
					try TypeUnification.unifyDefault(te.type, ti) catch (_:hxc.core.TypeUnification.UnifyError) fail();
				case _: fail();
			}
		}
	}

	// Do_build_instance (subset): for the non-generic case it is just
	// `apply_params decl_params actual_params (type_of_module_type mt)`-style construction.
	// TInst/TEnum/TType/TAbstract with the given params. We build directly.
	static function buildInstance(ctx:Context, mt:ModuleType, params:TParams, p:Position, specializeGeneric:Bool, ?callerTypeParams:TypeParams):T {
		return switch (mt) {
			case TClassDecl(c):
				switch (c.kind) {
					case KGeneric if (specializeGeneric && canSpecializeGeneric(params)):
						var fallback = TInst(c, params);
						var r:Ref<TLazy> = new Ref(TypeFunctions.lazyAvailable(fallback));
						r.set(TypeFunctions.lazyWait(function():T {
							r.set(TypeFunctions.lazyProcessing(function():T return fallback));
							var t = TInst(specializeGenericClass(ctx, c, params, p), []);
							r.set(TypeFunctions.lazyAvailable(t));
							return t;
						}));
						TLazy(r);
					case KGenericBuild(fields):
						hxc.eval.EvalMacro.runGenericBuild(ctx, c, params, fields, p, callerTypeParams);
					case KMacroType:
						// The instance is the macro's result, and the single parameter carries the call. .
						hxc.eval.EvalMacro.runMacroType(ctx, params, p, callerTypeParams);
					case _:
						TInst(c, params);
				}
			case TEnumDecl(e): TEnum(e, params);
			case TTypeDecl(td):
				// Loading a deprecated typedef warns at the load position, in any context including macro
				// typing.
				hxc.filters.DeprecationCheck.checkTypedefConstruction(ctx, td, p);
				TType(td, params);
			case TAbstractDecl(a): TAbstract(a, params);
		}
	}

	static function hasOpenMono(params:TParams):Bool {
		for (t in params) if (TypeFunctions.hasMono(t)) return true;
		return false;
	}

	static function hasTypeParameter(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, tl):
				switch (c.kind) {
					case KTypeParameter(_): true;
					case _: hasTypeParameterParams(tl);
				}
			case _:
				false;
		}
	}

	static function hasTypeParameterParams(params:TParams):Bool {
		for (t in params) if (hasTypeParameter(t)) return true;
		return false;
	}

	// Substituting into a generic needs the typer, to build instances while rewriting a field access.
	// hxc's substitution state is a bare gsubst array, so hold the typer here for the duration of a
	// specialization instead.
	static var genericBuildCtx:Null<Context> = null;

	public static function canSpecializeGeneric(params:TParams):Bool {
		return !hasOpenMono(params) && !hasTypeParameterParams(params);
	}

	static function genericKey(c:TClass, params:TParams):String {
		// The module id separates the host and macro worlds: each types its own copy of the class,
		// and a specialization from the other world has no prototypes in this one.
		var world = c.module != null ? Std.string(c.module.id) : "";
		return Context.pathKey(c.path) + "#" + world + "_" + genericSuffix(params);
	}

	static function genericSuffix(params:TParams):String {
		return [for (p in params) genericParamName(p)].join("_");
	}

	static function genericParamName(t:T):String {
		return genericTypeName(t, true);
	}

	static function genericTypePath(path:Path):String {
		return path.pack.length == 0 ? path.name : path.pack.join("_") + "_" + path.name;
	}

	static function genericTypeTail(params:TParams, top:Bool):String {
		return params.length == 0 ? "" : "_" + [for (p in params) genericTypeName(p, top)].join("_");
	}

	static function genericTypeName(t:T, top:Bool):String {
		return switch (t) {
			case TInst(c, params): switch (c.kind) {
				case KExpr(e): genericIdentSafe(hxc.ast.Printer.sExpr(e));
				case _: genericTypePath(c.path) + genericTypeTail(params, top);
			}
			case TEnum(e, params): genericTypePath(e.path) + genericTypeTail(params, top);
			case TAbstract(a, params): genericTypePath(a.path) + genericTypeTail(params, top);
			case TType(td, params): genericTypePath(td.path) + genericTypeTail(params, top);
			case TAnon(a):
				var fields = [for (name in a.fields.keys()) name + "_" + genericTypeName(a.fields.get(name).type, false)];
				"anon_" + fields.join("_");
			case TFun(sig): "func_" + [for (arg in sig.args) genericTypeName(arg.t, false)].concat([genericTypeName(sig.ret, false)]).join("_");
			case TDynamic(_): "Dynamic";
			case TLazy(f): genericTypeName(TypeFunctions.lazyType(f), top);
			case TMono(r): r.type == null ? "Unknown" : genericTypeName(r.type, top);
		};
	}

	static function genericIdentSafe(s:String):String {
		var out = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			var ok = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code) || c == "_".code;
			if (ok) out.addChar(c) else out.add("_" + c + "_");
		}
		return out.toString();
	}

	static function cloneVar(v:TVar, subst:T->T, vars:Map<Int, TVar>):TVar {
		var found = vars.get(v.id);
		if (found != null) return found;
		// Only meta is copied; extra is dropped, which keeps handle_abstract_casts from seeing through
		// inliner temps in generic clones
		var nv = TypeFunctions.allocVar(v.kind, v.name, subst(v.type), v.pos);
		nv.meta = v.meta;
		vars.set(v.id, nv);
		return nv;
	}

	public static function cloneExpr(e:TExpr, subst:T->T, vars:Map<Int, TVar>, ?gsubst:Array<GenericSubstEntry>):TExpr {
		if (gsubst != null) switch (e.expr) {
			case TTypeExpr(TClassDecl(c)):
				var hit = findGenericSubst(gsubst, TInst(c, []));
				if (hit != null && hit.expr != null) return cloneExpr(hit.expr, subst, vars, gsubst);
			case _:
		}
		function opt(eo:Null<TExpr>):Null<TExpr> return eo == null ? null : cloneExpr(eo, subst, vars, gsubst);
		function arr(el:Array<TExpr>):Array<TExpr> return [for (x in el) cloneExpr(x, subst, vars, gsubst)];
		function fieldAccess(fa:TFieldAccess):TFieldAccess {
			return switch (fa) {
				case FAnon(cf): FAnon(cf);
				case FInstance(c, tl, cf): FInstance(c, [for (t in tl) subst(t)], cf);
				case FStatic(c, cf): FStatic(c, cf);
				case FClosure(c, cf): FClosure(c == null ? null : {c: c.c, params: [for (t in c.params) subst(t)]}, cf);
				case FEnum(en, ef): FEnum(en, ef);
				case FDynamic(s): FDynamic(s);
			}
		}
		function fieldAccessForReceiver(fa:TFieldAccess, recv:TExpr):TFieldAccess {
			return switch (fa) {
				case FAnon(cf):
					switch (TypeFunctions.follow(recv.type)) {
						case TInst(c, tl):
							try {
								var r = TypeFunctions.rawClassField(function(f) return f.type, c, tl, cf.name);
								switch (r.c2) {
									case null: FAnon(r.f);
									case cwp: FInstance(cwp.c, cwp.params, r.f);
								}
							} catch (_:NotFound) {
								FAnon(cf);
							}
						case _:
							FAnon(cf);
					}
				case _:
					fieldAccess(fa);
			}
		}
		var et = subst(e.type);
		return TypeFunctions.mk(switch (e.expr) {
			case TConst(c): TConst(c);
			case TLocal(v): TLocal(cloneVar(v, subst, vars));
			case TArray(e1, e2): TArray(cloneExpr(e1, subst, vars, gsubst), cloneExpr(e2, subst, vars, gsubst));
			case TBinop(op, e1, e2): TBinop(op, cloneExpr(e1, subst, vars, gsubst), cloneExpr(e2, subst, vars, gsubst));
			case TField(e1, FInstance(fc, ftl, fcf)) if (gsubst != null && fc.kind.match(KGeneric)):
				// A field access on the @:generic base is re-resolved against the specialized instance, so it
				// points at the specialized class's own field (which DCE then marks; the base field is swept
				// with the base). The base-not-expanded case keeps the default remap (avoids a recursion).
				var ce1 = cloneExpr(e1, subst, vars, gsubst);
				var stl = [for (t in ftl) subst(t)];
				var cg2 = switch (TypeFunctions.follow(ce1.type)) {
					case TInst(c2, _): switch (c2.kind) {
						case KGenericInstance(base, _) if (base == fc): c2;
						case _:
							// Building the instance here CREATES a cascading instance as a side effect. It does not
							// follow that the access is redirected to it: this field stays on the unspecialized owner,
							// since redirecting makes the instance reachable and --dce full would keep a class that
							// should be discarded.
							if (!canSpecializeGeneric(stl)) null;
							else {
								var known = genericInstances.get(genericKey(fc, stl));
								if (known != null) known;
								else {
									if (genericBuildCtx != null) specializeGenericClass(genericBuildCtx, fc, stl, e.pos);
									null;
								}
							}
					}
					case _:
						// Building the instance here CREATES a cascading instance as a side effect. It does not
						// follow that the access is redirected to it: this field stays on the unspecialized owner,
						// since redirecting makes the instance reachable and --dce full would keep a class that
						// should be discarded.
						if (!canSpecializeGeneric(stl)) null;
						else {
							var known = genericInstances.get(genericKey(fc, stl));
							if (known != null) known;
							else {
								if (genericBuildCtx != null) specializeGenericClass(genericBuildCtx, fc, stl, e.pos);
								null;
							}
						}
				};
				if (cg2 == null || cg2 == fc) {
					TField(ce1, fieldAccessForReceiver(FInstance(fc, ftl, fcf), ce1));
				} else {
					var fa2 = try TypeFunctions.quickField(TInst(cg2, []), fcf.name)
						catch (_:hxc.core.NotFound) fieldAccessForReceiver(FInstance(fc, ftl, fcf), ce1);
					TField(ce1, fa2);
				}
			case TField(e1, fa):
				var ce1 = cloneExpr(e1, subst, vars, gsubst);
				TField(ce1, fieldAccessForReceiver(fa, ce1));
			case TTypeExpr(mt): TTypeExpr(mt);
			case TParenthesis(e1): TParenthesis(cloneExpr(e1, subst, vars, gsubst));
			case TObjectDecl(fields): TObjectDecl([for (f in fields) {key: f.key, expr: cloneExpr(f.expr, subst, vars, gsubst)}]);
			case TArrayDecl(values): TArrayDecl(arr(values));
			case TCall(e1, params): TCall(cloneExpr(e1, subst, vars, gsubst), arr(params));
			case TNew(c, params, args):
				// A constructed type parameter (new T()) rebuilds its class from the substituted type.
				switch (c.kind) {
					case KTypeParameter(_) | KGeneric:
						// The node's own type is the physical parameter type the substitution knows;
						// a freshly built TInst never matches its identity-keyed table.
						if (Sys.getEnv("HXC_DEBUG_TNEW") != null) Sys.println("[tnew] c=" + c.path.pack.join(".") + "." + c.path.name + " etype=" + hxc.core.TPrinting.sTypeStr(e.type) + " subst=" + hxc.core.TPrinting.sTypeStr(TypeFunctions.follow(subst(e.type))));
						 switch (TypeFunctions.follow(subst(e.type))) {
							case TInst(c2, pl2): TNew(c2, pl2, arr(args));
							case TAbstract(a, pl2) if (a.impl != null && !TypeFunctions.hasMeta(":multiType", a.meta)):
								// A @:generic expansion with a { new } constraint constructs the underlying
								// type.
								switch (TypeFunctions.follow(TypeFunctions.getUnderlyingType(a, pl2))) {
									case TInst(cu, tlu): TNew(cu, tlu, arr(args));
									case _: throw new TypingError("Cannot construct " + hxc.core.TPrinting.sTypeStr(TAbstract(a, pl2)), e.pos);
								}
							case TAbstract(a, pl2) if (a.impl != null): TNew(a.impl, pl2, arr(args));
							case mapped: throw new TypingError("Cannot construct " + hxc.core.TPrinting.sTypeStr(mapped), e.pos);
						 }
					case _: TNew(c, [for (t in params) subst(t)], arr(args));
				}
			case TUnop(op, flag, e1): TUnop(op, flag, cloneExpr(e1, subst, vars, gsubst));
			case TFunction(f):
				var fvars = new Map<Int, TVar>();
				for (id in vars.keys()) fvars.set(id, vars.get(id));
				var args = [for (a in f.args) {v: cloneVar(a.v, subst, fvars), c: opt(a.c)}];
				TFunction(new TFunc(args, subst(f.type), cloneExpr(f.expr, subst, fvars, gsubst)));
			case TVarExpr(v, eo): TVarExpr(cloneVar(v, subst, vars), opt(eo));
			case TBlock(exprs): TBlock(arr(exprs));
			case TFor(v, e1, e2): TFor(cloneVar(v, subst, vars), cloneExpr(e1, subst, vars, gsubst), cloneExpr(e2, subst, vars, gsubst));
			case TIf(econd, eif, eelse): TIf(cloneExpr(econd, subst, vars, gsubst), cloneExpr(eif, subst, vars, gsubst), opt(eelse));
			case TWhile(econd, e1, flag): TWhile(cloneExpr(econd, subst, vars, gsubst), cloneExpr(e1, subst, vars, gsubst), flag);
			case TSwitch(e1, cases, edef): TSwitch(cloneExpr(e1, subst, vars, gsubst), [for (c in cases) {values: arr(c.values), expr: cloneExpr(c.expr, subst, vars, gsubst)}], opt(edef));
			case TTry(e1, catches): TTry(cloneExpr(e1, subst, vars, gsubst), [for (c in catches) {v: cloneVar(c.v, subst, vars), expr: cloneExpr(c.expr, subst, vars, gsubst)}]);
			case TReturn(eo): TReturn(opt(eo));
			case TBreak: TBreak;
			case TContinue: TContinue;
			case TThrow(e1): TThrow(cloneExpr(e1, subst, vars, gsubst));
			case TCast(e1, mt): TCast(cloneExpr(e1, subst, vars, gsubst), mt);
			case TMeta(entry, e1): TMeta(entry, cloneExpr(e1, subst, vars, gsubst));
			case TEnumParameter(e1, ef, index): TEnumParameter(cloneExpr(e1, subst, vars, gsubst), ef, index);
			case TEnumIndex(e1): TEnumIndex(cloneExpr(e1, subst, vars, gsubst));
			case TIdent(s): TIdent(s);
		}, et, e.pos);
	}

	static function genericCheckConstExpr(ctx:Context, t:T):GenericSubstEntry {
		return switch (TypeFunctions.follow(t)) {
			case TInst({kind: KExpr(e)}, _):
				var tctx = new TyperContext(ctx);
				var te = Typer.typeExpr(tctx, e, WithTypeTools.value);
				{from: t, to: te.type, expr: te};
			case _:
				{from: t, to: t, expr: null};
		}
	}

	// A type parameter is matched by identity, not through follow: the substitution is keyed on the
	// physical type-param node and otherwise recurses structurally. Only transparent indirections (a
	// resolved monomorph or a lazy type) are chased; a type-changing wrapper like Null<T> is not,
	// since follow would collapse it to its inner T and replace the whole Null<T>, dropping the
	// nullable wrapper (the structural TAbstract case then handles Null<T> by recursing into its
	// parameter).
	static function typeParamClass(t:T):Null<TClass> {
		return switch (t) {
			case TMono(r) if (r.type != null): typeParamClass(r.type);
			case TLazy(f): typeParamClass(TypeFunctions.lazyType(f));
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))): c;
			case _: null;
		}
	}

	static function findGenericSubst(gsubst:Array<GenericSubstEntry>, t:T):Null<GenericSubstEntry> {
		var c = typeParamClass(t);
		if (c == null) return null;
		for (s in gsubst) {
			var c2 = typeParamClass(s.from);
			if (c2 == c) return s;
		}
		return null;
	}

	static function makeGenericSubst(ctx:Context, c:TClass, params:TParams, p:Position):Array<GenericSubstEntry> {
		var out:Array<GenericSubstEntry> = [];
		for (i in 0...c.params.length) {
			var from = switch (c.params[i].type) {
				case TLazy(f): TypeFunctions.lazyType(f);
				case t: t;
			}
			var checked = genericCheckConstExpr(ctx, params[i]);
			out.push({from: from, to: checked.to, expr: checked.expr});
		}
		// No constraint check here: the delayed PCheckConstraint queued by loadInstance is the only
		// enforcement point.
		return out;
	}

	static function genericSubstituteType(ctx:Context, c:TClass, gsubst:Array<GenericSubstEntry>, p:Position, t:T):T {
		// An untouched subtree keeps its PHYSICAL node: a cloned signature's own method type parameters
		// must stay identical to their type so a call site's applyParams still matches them (it
		// compares
		// by identity).
		function loopList(tl:Array<T>, loop:T->T):Null<Array<T>> {
			var changed = false;
			var out = [for (x in tl) { var y = loop(x); if (y != x) changed = true; y; }];
			return changed ? out : null;
		}
		function loop(t:T):T {
			var hit = findGenericSubst(gsubst, t);
			if (hit != null) return loop(hit.to);
			return switch (t) {
				case TInst(gc, tl):
					var tl2 = loopList(tl, loop);
					switch (gc.kind) {
						case KGeneric if (canSpecializeGeneric(tl2 != null ? tl2 : tl)):
							// The instance is built for any KGeneric reference, including a self-reference (a field like
							// `next:GenericCell<T>` inside GenericCell<T>): the specialized class is
							// registered in the cache before its fields are substituted, so specializeGenericClass
							// returns the cached instance instead of recursing, and the field points at GenericCell_Int
							// rather than the base GenericCell.
							TInst(specializeGenericClass(ctx, gc, tl2 != null ? tl2 : tl, p), []);
						case _:
							tl2 == null ? t : TInst(gc, tl2);
					}
				case TEnum(e, tl):
					var tl2 = loopList(tl, loop);
					tl2 == null ? t : TEnum(e, tl2);
				case TType(td, tl):
					var tl2 = loopList(tl, loop);
					tl2 == null ? t : TType(td, tl2);
				case TAbstract(a, tl):
					var tl2 = loopList(tl, loop);
					tl2 == null ? t : TAbstract(a, tl2);
				case TFun(sig):
					var changed = false;
					var args:Array<hxc.core.Type.TSignatureArg> = [for (a in sig.args) { var y = loop(a.t); if (y != a.t) changed = true; ({name: a.name, opt: a.opt, t: y} : hxc.core.Type.TSignatureArg); }];
					var ret = loop(sig.ret);
					if (ret != sig.ret) changed = true;
					changed ? TFun({args: args, ret: ret}) : t;
				case TAnon(a):
					var changed = false;
					var fields = new StringMap<TClassField>();
					for (k in a.fields.keys()) {
						var of = a.fields.get(k);
						var nt = loop(of.type);
						if (nt != of.type) {
							changed = true;
							var nf = TypeFunctions.copyField(of);
							nf.type = nt;
							fields.set(k, nf);
						} else {
							fields.set(k, of);
						}
					}
					changed ? TAnon({fields: fields, status: a.status}) : t;
				case TLazy(f):
					loop(TypeFunctions.lazyType(f));
				case TMono(r):
					switch (r.type) {
						case null: t;
						case some: loop(some);
					}
				case TDynamic(t1):
					if (t1 == null) t else {
						var y = loop(t1);
						y == t1 ? t : TDynamic(y);
					}
			}
		}
		return loop(t);
	}

	static function cloneField(ctx:Context, c:TClass, gsubst:Array<GenericSubstEntry>, f:TClassField,
			lazyFields:Array<TClassField>):TClassField {
		// The method's own type parameters are cloned so their constraints can be substituted without
		// touching the originals; the clone maps into the substitution so occurrences in the signature and
		// body follow.
		var gsubst2 = gsubst;
		var newParams:TypeParams = [];
		if (f.params.length > 0) {
			gsubst2 = gsubst.copy();
			for (tp in f.params) {
				switch (TypeFunctions.follow(tp.type)) {
					case TInst(pc, tl):
						var pc2 = TypeFunctions.mkClass(pc.module, pc.path, pc.pos, pc.namePos);
						pc2.kind = pc.kind;
						var t2 = TInst(pc2, tl);
						gsubst2.push({from: tp.type, to: t2, expr: null});
						newParams.push(new TypedTypeParam(tp.name, t2, tp.defaultType));
					case _:
						newParams.push(tp);
				}
			}
		}
		var subst = function(t:T) return genericSubstituteType(ctx, c, gsubst2, f.pos, t);
		// Constraints substitute only after the full substitution list is built.
		for (tp in newParams) switch (TypeFunctions.follow(tp.type)) {
			case TInst(pc2, _):
				switch (pc2.kind) {
					case KTypeParameter(tl1): pc2.kind = KTypeParameter([for (x in tl1) subst(x)]);
					case _:
				}
			case _:
		}
		var cf = TypeFunctions.copyField(f);
		if (f.params.length > 0) cf.params = newParams;
		cf.expr = null;
		cf.exprUnoptimized = null;
		// The specialized field's TLazy substitutes its type and expression together on first read.
		// Eagerly forcing the base body during heritage resolution reports errors that a later failing
		// declaration should preempt. Inside the lazy callback, force the base body with forceFieldBody,
		// substitute the type after the lazy signature resolves, and restore genericBuildCtx. The context
		// is required for cascading instances created by cloneExpr, including classes reached by
		// re-resolving a super from a nested cloned body.
		var baseCls = c;
		var computed:Null<T> = null;
		var lr = new Ref(LAvailable(TypeFunctions.tDynamic));
		lr.set(LWait(function():T {
			if (computed != null) return computed;
			if (f.expr == null) TypeFields.forceFieldBody(ctx, baseCls, f);
			var t = subst(f.type);
			computed = t;
			lr.set(LProcessing(function() return t));
			cf.type = t;
			if (f.expr != null) {
				var savedGCtx = genericBuildCtx;
				genericBuildCtx = ctx;
				cf.expr = cloneExpr(f.expr, subst, new Map(), gsubst2);
				cf.exprUnoptimized = f.exprUnoptimized == null ? null : cloneExpr(f.exprUnoptimized, subst, new Map(), gsubst2);
				genericBuildCtx = savedGCtx;
			}
			lr.set(LAvailable(t));
			return t;
		}));
		cf.type = TLazy(lr);
		lazyFields.push(cf);
		cf.overloads = [for (o in f.overloads) cloneField(ctx, c, gsubst, o, lazyFields)];
		return cf;
	}

	// A process-wide counter, so the first generated name is Hx___short___hx_type_0.
	static var shortNameCounter = -1;

	static function getShortName():String {
		shortNameCounter++;
		return "Hx___short___hx_type_" + shortNameCounter;
	}

	public static function specializeGenericClass(ctx:Context, c:TClass, params:TParams, p:Position):TClass {
		var savedGenericCtx = genericBuildCtx; genericBuildCtx = ctx;
		// `ignore(c.build())` - 'make sure the super class is already setup' before build_field
		// substitutes over its signatures. A @:generic reached from a HERITAGE clause specializes before
		// the base class has had its field types resolved, and substituting an open monomorph only yields
		// another one.
		hxc.typing.TypeResolve.buildClassFields(ctx, c, p);
		var key = genericKey(c, params);
		var cached = genericInstances.get(key);
		if (cached != null) { genericBuildCtx = savedGenericCtx; return cached; }
		var suffix = "_" + genericSuffix(params);
		if (suffix == "_") suffix = "_Generic" + (++genericInstanceId);
		var path:hxc.core.Globals.Path = {pack: c.path.pack, name: c.path.name + suffix};
		// A user type already claiming the generated name blocks specialization; our own instances hit the
		// cache above and never reach here. .
		if (ctx.typeToModule.exists(Context.pathKey(path)))
			throw new TypingError("Cannot specialize @:generic because the generated type name is already used: " + path.name, p);
		var mg = new ModuleDef(TypeFunctions.allocMid(), path, [], null, TypeFunctions.moduleExtra("", "", 0.0, MFake, []));
		mg.extra.resolved = 2;
		var cg = TypeFunctions.mkClass(mg, path, c.pos, c.namePos);
		cg.doc = c.doc;
		// Only a whitelist of the source class's metadata carries over to the instance, and @:noDoc leads
		// it. isPrivate is not set.
		var carried = [
			":access", ":allow", ":final", ":hack", ":internal", ":keep", ":keepSub",
			":noClosure", ":nullSafety", ":pure", ":struct", ":structInit", ":using", ":unreflective"
		];
		cg.meta = [{name: ":noDoc", params: [], pos: Position.nullPos}]
			.concat([for (m in c.meta) if (carried.indexOf(m.name) >= 0) m]);
		// A generic class is copied per type argument, so anything that exists once cannot come along: an
		// __init__ block, or any static field. A macro method is the one exception, and only outside the
		// macro context, where it is never called.
		if (c.init != null) throw new TypingError("This class can't be generic", p);
		for (cf in c.orderedStatics) {
			// The reference lifts __init__ out of the statics into init, so its list never
			// contains one; hxc keeps it as a static, and it is covered by the check above.
			if (cf.name == "__init__") continue;
			if (cf.kind.match(Method(MethMacro)) && !ctx.isMacro) continue;
			throw new TypingError("A generic class can't have static fields", cf.pos);
		}
		cg.kind = KGenericInstance(c, params);
		cg.flags = c.flags;
		cg.usings = c.usings;
		genericInstances.set(key, cg);
		var gsubst = makeGenericSubst(ctx, c, params, p);
		cg.superClass = c.superClass == null ? null : switch (genericSubstituteType(ctx, c, gsubst, p, TInst(c.superClass.c, c.superClass.params))) {
			case TInst(cs, pl): {c: cs, params: pl};
			case _: null;
		};
		cg.interfaces = [for (i in c.interfaces) switch (genericSubstituteType(ctx, c, gsubst, p, TInst(i.c, i.params))) {
			case TInst(ci, pl): {c: ci, params: pl};
			case _: throw "generic interface substitution failed";
		}];
		cg.dynamicType = c.dynamicType == null ? null : genericSubstituteType(ctx, c, gsubst, p, c.dynamicType);
		cg.arrayAccess = c.arrayAccess == null ? null : genericSubstituteType(ctx, c, gsubst, p, c.arrayAccess);
		var lazyFields:Array<TClassField> = [];
		if (c.constructor != null) cg.constructor = cloneField(ctx, c, gsubst, c.constructor, lazyFields);
		for (f in c.orderedFields) {
			var cf = cloneField(ctx, c, gsubst, f, lazyFields);
			cg.fields.set(cf.name, cf);
			cg.orderedFields.push(cf);
		}
		// The lazies fire on first read, which keeps the base's bodies out of declaration resolution;
		// forcing them here would put the force back exactly where it was. They are also queued at
		// PTypeField so an instance nobody reads by type still materializes - hxc's back end reads expr
		// directly - and PTypeField is the pass inside typeAllModules' stability loop, which reaches the
		// modules a flush creates.
		ctx.delay(hxc.context.Context.PTypeField, function() {
			for (cf in lazyFields) TypeFunctions.follow(cf.type);
		});
		// In rare cases the specialized name gets too long, so it is replaced by a generated @:native.
		// Without this a target that derives file names from the type name can exceed the platform path
		// limit.
		if (cg.path.name.length > 254)
			cg.meta = [{name: ":native", params: [new Expr(EConst(CString(getShortName(), SDoubleQuotes)), p)], pos: Position.nullPos}].concat(cg.meta);
		mg.types = [TClassDecl(cg)];
		ctx.modules.push(mg);
		ctx.types.push(TClassDecl(cg));
		ctx.moduleLut.set(Context.pathKey(path), mg);
		ctx.typeToModule.set(Context.pathKey(path), path);
		TypeFunctions.addDependency(mg, c.module);
		genericBuildCtx = savedGenericCtx;
		return cg;
	}
}

// Where a set of type parameters is declared, distinguishing a type declaration (defaults allowed)
// from a constructor, method, or enum constructor (defaults rejected).
enum TypeParamHost {
	TPHType;
	TPHConstructor;
	TPHMethod;
	TPHEnumConstructor;
}
