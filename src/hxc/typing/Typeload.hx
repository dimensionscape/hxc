package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.NotFound;
import hxc.core.Ref;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.context.Context.ContextError;
import haxe.ds.StringMap;

class Typeload {
	static final pNull = Position.nullPos;
	static var genericInstanceId:Int = 0;
	static var genericInstances:Map<String, TClass> = new Map();

	public static function typeTypeParam(ctx:Context, declPath:Path, getParams:Void->TypeParams, tp:TypeParam):TypedTypeParam {
		var n = tp.tpName.name;
		var c = TypeFunctions.mkClass(TypeFunctions.nullModule, {pack: declPath.pack.concat([declPath.name]), name: n}, tp.tpName.pos, tp.tpName.pos);
		c.kind = KTypeParameter([]);
		c.meta = tp.tpMeta;
		var t = TInst(c, []);
		var p = tp.tpName.pos;
		var declModulePath:Path = {pack: declPath.pack, name: declPath.name};
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

	public static function typeTypeParams(ctx:Context, declPath:Path, tps:Array<TypeParam>):TypeParams {
		// Returns the sibling params so a
		// first, then hand each param a thunk closing over it.
		var params:TypeParams = [];
		var getParams = function():TypeParams return params;
		for (tp in tps) params.push(typeTypeParam(ctx, declPath, getParams, tp));
		return params;
	}

	public static function loadTypeHint(ctx:Context, typeParams:TypeParams, t:Null<TypeHint>, opt:Bool = false):T {
		var ty = (t == null)
			? spawnMonomorph()
			: loadComplexType(ctx, typeParams, t);
		return opt ? ctx.basic.tnull(ty) : ty;
	}

	static function spawnMonomorph():T {
		return TypeFunctions.mkMono();
	}

	// Ctx allow_display (t,pn)
	// display/diagnostics mode only; batch mode re-raises, which is our behaviour.)
	public static function loadComplexType(ctx:Context, typeParams:TypeParams, th:TypeHint):T {
		return loadComplexTypePrime(ctx, typeParams, th.ct, th.pos);
	}

	static function loadComplexTypePrime(ctx:Context, typeParams:TypeParams, t:ComplexType, p:Position):T {
		return switch (t) {
			case CTParent(th):
				loadComplexType(ctx, typeParams, th);

			// The path `$._hx_mono` spawns a monomorph.
			case CTPath(tp) if (tp.tpackage.length == 1 && tp.tpackage[0] == "$" && tp.tname == "_hx_mono"):
				spawnMonomorph();

			case CTPath(tp):
				loadInstance(ctx, typeParams, tp, p, false);

			case CTOptional(_):
				throw new ContextError("Optional type not allowed here", p);

			case CTNamed(_, _):
				throw new ContextError("Named type not allowed here", p);

			case CTIntersection(tl):
				var resolved = [for (th in tl) loadComplexType(ctx, typeParams, th)];
				makeExtensionType(resolved, p);

			case CTExtend(paths, fields):
				var anonT = loadComplexTypePrime(ctx, typeParams, CTAnonymous(fields), p);
				switch (anonT) {
					case TAnon(a):
						var il = [for (pt in paths) loadInstance(ctx, typeParams, pt.path, pt.pos, false)];
						if (il.length == 1) {
							mkExtension(a, il[0], p);
						} else {
							for (it in il) extendLoop(a, it, p);
							a.status.set(Extend(il));
							anonT;
						}
					case _:
						throw new ContextError("Cannot structurally extend", p);
				}

			case CTAnonymous(l):
				loadAnonymous(ctx, typeParams, l, p);

			case CTFunction(args, ret):
				loadFunctionType(ctx, typeParams, args, ret, p);
		}
	}

	// CTExtend helpers do not check is_redefined.
	static function mkExtension(a:TAnon, it:T, p:Position):T {
		return switch (TypeFunctions.follow(it)) {
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

	static function extendLoop(a:TAnon, it:T, p:Position):Void {
		switch (TypeFunctions.follow(it)) {
			case TAnon(a2):
				for (k in a2.fields.keys()) if (!a.fields.exists(k)) a.fields.set(k, a2.fields.get(k));
			case _:
				throw new ContextError("Can only extend structures", p);
		}
	}

	static function makeExtensionType(tl:Array<T>, p:Position):T {
		// Minimal subset equivalent of make_extension_type: merge the resolved anons.
		var merged = new StringMap<TClassField>();
		for (t in tl) switch (TypeFunctions.follow(t)) {
			case TAnon(a2):
				for (k in a2.fields.keys()) merged.set(k, a2.fields.get(k));
			case _:
				throw new ContextError("Can only extend structures", p);
		}
		return TypeFunctions.mkAnon(new Ref<AnonStatus>(Extend(tl)), merged);
	}

	static function isTypeParameter(c:TClass):Bool {
		return switch (c.kind) { case KTypeParameter(_): true; case _: false; };
	}

	static function loadFunctionType(ctx:Context, typeParams:TypeParams, args:Array<TypeHint>, ret:TypeHint, p:Position):T {
		if (args.length == 1) {
			switch (args[0].ct) {
				case CTPath(tp) if (tp.tpackage.length == 0 && tp.tparams.length == 0 && tp.tname == "Void"):
					return TFun({args: [], ret: loadComplexType(ctx, typeParams, ret)});
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
			sigArgs.push({name: name, opt: opt, t: loadComplexType(ctx, typeParams, inner)});
		}
		return TFun({args: sigArgs, ret: loadComplexType(ctx, typeParams, ret)});
	}

	// CTAnonymous l -> TAnon (subset of/`topt` machinery)
	static function loadAnonymous(ctx:Context, typeParams:TypeParams, l:Array<ClassField>, p:Position):T {
		var fields = new StringMap<TClassField>();
		for (f in l) {
			var n = f.cffName.name;
			var pf = f.cffName.pos;
			if (fields.exists(n)) throw new ContextError("Duplicate field declaration : " + n, pf);

			function topt(t:Null<TypeHint>):T {
				if (t == null) throw new ContextError("Explicit type required for field " + n, p);
				return loadComplexType(ctx, typeParams, t);
			}

			var pub = true;
			var dyn = false;
			var isFinal = false;
			for (a in f.cffAccess) switch (a.access) {
				case APublic:
				case APrivate: pub = false;
				case ADynamic if (switch (f.cffKind) { case FFun(_): true; case _: false; }): dyn = true;
				case AFinal: isFinal = true;
				case other: throw new ContextError("Invalid access " + Std.string(other), p);
			}

			var t:T;
			var access:FieldKind;
			var params:TypeParams = [];
			switch (f.cffKind) {
				case FVar(th, _) if (isFinal):
					if (th == null) throw new ContextError("Type required for structure property", p);
					t = loadComplexType(ctx, typeParams, th);
					access = Var({read: AccNormal, write: AccNever});
				case FVar(th, _):
					// Reject an explicit Void field type.
					switch (th) {
						case {ct: CTPath(tp)} if (tp.tpackage.length == 0 && tp.tname == "Void"):
							throw new ContextError("Fields of type Void are not allowed in structures", p);
						case _:
					}
					t = topt(th);
					access = Var({read: AccNormal, write: AccNormal});
				case FFun(fd):
					// Function field: TFun(args, ret) from hints (subset: no type-param scope
					// extension for method-local params, annotations only).
					if (fd.fParams.length > 0) params = typeTypeParams(ctx, {pack: [], name: n}, fd.fParams);
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
				case FProp(get, set, th, _):
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
					t = loadComplexType(ctx, typeParams, th);
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
		if (sub == null && path.pack.length == 0 && ctx.defines.rawDefined("macro")) {
			switch (path.name) {
				case "Expr" | "Context" | "Compiler" | "Type" | "Tools" | "ExprTools" | "TypeTools" | "ComplexTypeTools" | "MacroStringTools":
					try return ctx.getType({pack: ["haxe", "macro"], name: path.name}, p, null) catch (_:Dynamic) {}
				case _:
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
		if (m == null || m.extra.processed >= 1) return;
		var saved = ctx.currentModule;
		try {
			TypeResolve.resolveModule(ctx, m);
		} catch (_:Dynamic) {}
		ctx.currentModule = saved;
	}

	public static function loadInstance(ctx:Context, typeParams:TypeParams, t:TypePath, p:Position, allowNoParams:Bool, ?specializeGeneric:Bool = true):T {
		// Look up a bare type-parameter name before resolving a module.
		if (t.tpackage.length == 0 && t.tsub == null) {
			var pt:Null<T> = null;
			try {
				pt = TypeFunctions.lookupParam(t.tname, typeParams);
			} catch (_:NotFound) {
				pt = null;
			}
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
		var build = function(params:TParams):T return buildInstance(ctx, mt, params, p, specializeGeneric);
		var isGenericBuild = switch (mt) {
			case TClassDecl(c): switch (c.kind) { case KGenericBuild(_): true; case _: false; }
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
						case _: "Expr";
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
		var i1 = 0, i2 = 0;
		while (true) {
			if (i1 < t.tparams.length && i2 < types.length) {
				params.push(loadParam(t.tparams[i1]));
				i1++; i2++;
			} else if (i1 >= t.tparams.length && i2 >= types.length) {
				break;
			} else if (i1 >= t.tparams.length) {
				// A parameter past the given ones: its default, if it has one.
				var def = types[i2].defaultType;
				if (def == null)
					throw new ContextError("Not enough type parameters for " + Context.sTypePath(declPath), p);
				params.push(def);
				i2++;
			} else {
				// T:: tl, [] -> too many
				throw new ContextError("Too many type parameters for " + Context.sTypePath(declPath), p);
			}
		}
		return build(params);
	}

	// Do_build_instance (subset): for the non-generic case it is just
	// `apply_params decl_params actual_params (type_of_module_type mt)`-style construction.
	// TInst/TEnum/TType/TAbstract with the given params. We build directly.
	static function buildInstance(ctx:Context, mt:ModuleType, params:TParams, p:Position, specializeGeneric:Bool):T {
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
					case _:
						TInst(c, params);
				}
			case TEnumDecl(e): TEnum(e, params);
			case TTypeDecl(td): TType(td, params);
			case TAbstractDecl(a): TAbstract(a, params);
		}
	}

	static function hasOpenMono(params:TParams):Bool {
		for (t in params) if (TypeFunctions.hasMono(t)) return true;
		return false;
	}

	static function hasTypeParameter(t:T):Bool {
		return switch (t) {
			case TInst(c, tl):
				switch (c.kind) {
					case KTypeParameter(_): true;
					case _: hasTypeParameterParams(tl);
				}
			case TEnum(_, tl) | TType(_, tl) | TAbstract(_, tl):
				hasTypeParameterParams(tl);
			case TFun(sig):
				if (hasTypeParameter(sig.ret)) true
				else {
					var found = false;
					for (a in sig.args) if (hasTypeParameter(a.t)) {
						found = true;
						break;
					}
					found;
				}
			case TAnon(a):
				var found = false;
				for (f in a.fields) if (hasTypeParameter(f.type)) {
					found = true;
					break;
				}
				found;
			case TDynamic(t):
				t != null && hasTypeParameter(t);
			case TLazy(f):
				false;
			case TMono(_):
				false;
		}
	}

	static function hasTypeParameterParams(params:TParams):Bool {
		for (t in params) if (hasTypeParameter(t)) return true;
		return false;
	}

	static function canSpecializeGeneric(params:TParams):Bool {
		return !hasOpenMono(params) && !hasTypeParameterParams(params);
	}

	static function genericKey(c:TClass, params:TParams):String {
		return Context.pathKey(c.path) + "_" + genericSuffix(params);
	}

	static function genericSuffix(params:TParams):String {
		return [for (p in params) sanitizeGenericName(genericParamName(p))].join("_");
	}

	static function genericParamName(t:T):String {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, []): c.path.name;
			case TInst(c, params): c.path.name + "_" + genericSuffix(params);
			case TEnum(e, []): e.path.name;
			case TEnum(e, params): e.path.name + "_" + genericSuffix(params);
			case TAbstract(a, []): a.path.name;
			case TAbstract(a, params): a.path.name + "_" + genericSuffix(params);
			case TType(td, []): td.path.name;
			case TType(td, params): td.path.name + "_" + genericSuffix(params);
			case TDynamic(_): "Dynamic";
			case TFun(_): "Function";
			case TAnon(_): "Anon";
			case TLazy(f): genericParamName(TypeFunctions.lazyType(f));
			case TMono(_): "Unknown";
		}
	}

	static function sanitizeGenericName(s:String):String {
		var out = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			var ok = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code) || c == "_".code;
			out.addChar(ok ? c : "_".code);
		}
		return out.toString();
	}

	static function cloneVar(v:TVar, subst:T->T, vars:Map<Int, TVar>):TVar {
		var found = vars.get(v.id);
		if (found != null) return found;
		var nv = TypeFunctions.allocVar(v.kind, v.name, subst(v.type), v.pos);
		nv.extra = v.extra;
		nv.meta = v.meta;
		nv.flags = v.flags;
		vars.set(v.id, nv);
		return nv;
	}

	public static function cloneExpr(e:TExpr, subst:T->T, vars:Map<Int, TVar>):TExpr {
		function opt(eo:Null<TExpr>):Null<TExpr> return eo == null ? null : cloneExpr(eo, subst, vars);
		function arr(el:Array<TExpr>):Array<TExpr> return [for (x in el) cloneExpr(x, subst, vars)];
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
		var et = subst(e.type);
		return TypeFunctions.mk(switch (e.expr) {
			case TConst(c): TConst(c);
			case TLocal(v): TLocal(cloneVar(v, subst, vars));
			case TArray(e1, e2): TArray(cloneExpr(e1, subst, vars), cloneExpr(e2, subst, vars));
			case TBinop(op, e1, e2): TBinop(op, cloneExpr(e1, subst, vars), cloneExpr(e2, subst, vars));
			case TField(e1, fa): TField(cloneExpr(e1, subst, vars), fieldAccess(fa));
			case TTypeExpr(mt): TTypeExpr(mt);
			case TParenthesis(e1): TParenthesis(cloneExpr(e1, subst, vars));
			case TObjectDecl(fields): TObjectDecl([for (f in fields) {key: f.key, expr: cloneExpr(f.expr, subst, vars)}]);
			case TArrayDecl(values): TArrayDecl(arr(values));
			case TCall(e1, params): TCall(cloneExpr(e1, subst, vars), arr(params));
			case TNew(c, params, args): TNew(c, [for (t in params) subst(t)], arr(args));
			case TUnop(op, flag, e1): TUnop(op, flag, cloneExpr(e1, subst, vars));
			case TFunction(f):
				var fvars = new Map<Int, TVar>();
				for (id in vars.keys()) fvars.set(id, vars.get(id));
				var args = [for (a in f.args) {v: cloneVar(a.v, subst, fvars), c: opt(a.c)}];
				TFunction(new TFunc(args, subst(f.type), cloneExpr(f.expr, subst, fvars)));
			case TVarExpr(v, eo): TVarExpr(cloneVar(v, subst, vars), opt(eo));
			case TBlock(exprs): TBlock(arr(exprs));
			case TFor(v, e1, e2): TFor(cloneVar(v, subst, vars), cloneExpr(e1, subst, vars), cloneExpr(e2, subst, vars));
			case TIf(econd, eif, eelse): TIf(cloneExpr(econd, subst, vars), cloneExpr(eif, subst, vars), opt(eelse));
			case TWhile(econd, e1, flag): TWhile(cloneExpr(econd, subst, vars), cloneExpr(e1, subst, vars), flag);
			case TSwitch(e1, cases, edef): TSwitch(cloneExpr(e1, subst, vars), [for (c in cases) {values: arr(c.values), expr: cloneExpr(c.expr, subst, vars)}], opt(edef));
			case TTry(e1, catches): TTry(cloneExpr(e1, subst, vars), [for (c in catches) {v: cloneVar(c.v, subst, vars), expr: cloneExpr(c.expr, subst, vars)}]);
			case TReturn(eo): TReturn(opt(eo));
			case TBreak: TBreak;
			case TContinue: TContinue;
			case TThrow(e1): TThrow(cloneExpr(e1, subst, vars));
			case TCast(e1, mt): TCast(cloneExpr(e1, subst, vars), mt);
			case TMeta(entry, e1): TMeta(entry, cloneExpr(e1, subst, vars));
			case TEnumParameter(e1, ef, index): TEnumParameter(cloneExpr(e1, subst, vars), ef, index);
			case TEnumIndex(e1): TEnumIndex(cloneExpr(e1, subst, vars));
			case TIdent(s): TIdent(s);
		}, et, e.pos);
	}

	static function genericSubstituteType(ctx:Context, c:TClass, params:TParams, p:Position, t:T):T {
		var applied = TypeFunctions.applyParams(c.params, params, t);
		function loop(t:T):T {
			return switch (t) {
				case TInst(gc, tl):
					var tl2 = [for (x in tl) loop(x)];
					switch (gc.kind) {
						case KGeneric if (gc != c && canSpecializeGeneric(tl2)):
							TInst(specializeGenericClass(ctx, gc, tl2, p), []);
						case _:
							TInst(gc, tl2);
					}
				case TEnum(e, tl):
					TEnum(e, [for (x in tl) loop(x)]);
				case TType(td, tl):
					TType(td, [for (x in tl) loop(x)]);
				case TAbstract(a, tl):
					TAbstract(a, [for (x in tl) loop(x)]);
				case TFun(sig):
					TFun({args: [for (a in sig.args) {name: a.name, opt: a.opt, t: loop(a.t)}], ret: loop(sig.ret)});
				case TAnon(a):
					var fields = new StringMap<TClassField>();
					for (k in a.fields.keys()) {
						var nf = TypeFunctions.copyField(a.fields.get(k));
						nf.type = loop(nf.type);
						fields.set(k, nf);
					}
					TAnon({fields: fields, status: a.status});
				case TLazy(f):
					loop(TypeFunctions.lazyType(f));
				case TMono(r):
					switch (r.type) {
						case null: t;
						case some: loop(some);
					}
				case TDynamic(t):
					TDynamic(t == null ? null : loop(t));
			}
		}
		return loop(applied);
	}

	static function cloneField(ctx:Context, c:TClass, params:TParams, f:TClassField):TClassField {
		var subst = function(t:T) return genericSubstituteType(ctx, c, params, f.pos, t);
		if (f.expr == null) TypeFields.forceFieldBody(ctx, c, f);
		var cf = TypeFunctions.copyField(f);
		cf.type = subst(f.type);
		cf.expr = f.expr == null ? null : cloneExpr(f.expr, subst, new Map());
		cf.exprUnoptimized = f.exprUnoptimized == null ? null : cloneExpr(f.exprUnoptimized, subst, new Map());
		cf.overloads = [for (o in f.overloads) cloneField(ctx, c, params, o)];
		return cf;
	}

	public static function specializeGenericClass(ctx:Context, c:TClass, params:TParams, p:Position):TClass {
		var key = genericKey(c, params);
		var cached = genericInstances.get(key);
		if (cached != null) return cached;
		var suffix = "_" + genericSuffix(params);
		if (suffix == "_") suffix = "_Generic" + (++genericInstanceId);
		var path = {pack: c.path.pack, name: c.path.name + suffix};
		var mg = new ModuleDef(TypeFunctions.allocMid(), path, [], null, TypeFunctions.moduleExtra("", "", 0.0, MFake, []));
		mg.extra.processed = 2;
		var cg = TypeFunctions.mkClass(mg, path, c.pos, c.namePos);
		cg.doc = c.doc;
		cg.meta = c.meta;
		cg.isPrivate = true;
		cg.kind = KGenericInstance(c, params);
		cg.flags = c.flags;
		cg.usings = c.usings;
		genericInstances.set(key, cg);
		cg.superClass = c.superClass == null ? null : switch (genericSubstituteType(ctx, c, params, p, TInst(c.superClass.c, c.superClass.params))) {
			case TInst(cs, pl): {c: cs, params: pl};
			case _: null;
		};
		cg.interfaces = [for (i in c.interfaces) switch (genericSubstituteType(ctx, c, params, p, TInst(i.c, i.params))) {
			case TInst(ci, pl): {c: ci, params: pl};
			case _: throw "generic interface substitution failed";
		}];
		cg.dynamicType = c.dynamicType == null ? null : genericSubstituteType(ctx, c, params, p, c.dynamicType);
		cg.arrayAccess = c.arrayAccess == null ? null : genericSubstituteType(ctx, c, params, p, c.arrayAccess);
		if (c.constructor != null) cg.constructor = cloneField(ctx, c, params, c.constructor);
		for (f in c.orderedFields) {
			var cf = cloneField(ctx, c, params, f);
			cg.fields.set(cf.name, cf);
			cg.orderedFields.push(cf);
		}
		mg.types = [TClassDecl(cg)];
		ctx.modules.push(mg);
		ctx.types.push(TClassDecl(cg));
		ctx.moduleLut.set(Context.pathKey(path), mg);
		ctx.typeToModule.set(Context.pathKey(path), path);
		TypeFunctions.addDependency(mg, c.module);
		return cg;
	}
}
