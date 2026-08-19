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

	public static function typeTypeParam(ctx:Context, declPath:Path, getParams:Void->TypeParams, tp:TypeParam, host:TypeParamHost = TPHType, ?declModule:ModuleDef, ?scopeParams:TypeParams):TypedTypeParam {
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
		if (host == TPHEnumConstructor) c.meta = [{name: ":enumConstructorParam", params: [], pos: pNull}].concat(c.meta);
		var t = TInst(c, []);
		var p = tp.tpName.pos;
		// A parameter whose name holds the cursor in the display file answers with its type. A type's
		// parameters are typed once every type of the module exists; hxc creates them with the types, so
		// that answer waits for typeModule to reach the same point. The collection it raises lists the
		// parameters in scope where this one is declared, not the list being declared.
		if (hxc.typing.ExprPreprocessing.inDisplayFile(p) && hxc.typing.Typer.atDisplayPos(p)) {
			var scope = scopeParams == null ? [] : scopeParams;
			if (hxc.context.ModuleLoader.creatingModuleTypes > 0) hxc.context.ModuleLoader.typeParamDisplay = {t: t, p: p, scope: scope};
			else displayTypeInScope(ctx, t, p, scope);
		}
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
				// Same recovery the constraint lazy below does, and for the same reason: declModulePath is the
				// declaring type's path, which names a module only for a module's PRIMARY type. A second or
				// private type in the module misses, and the default then resolves without that module's
				// imports - `T = Option<String>` under `import haxe.ds.Option` reported Type not found. Only
				// --json with -dce no forces it, which is why no compile lane saw it.
				var declMod = ctx.moduleLut.get(Context.pathKey(declModulePath));
				if (declMod == null) {
					var mp = ctx.typeToModule.get(Context.pathKey(declModulePath));
					if (mp != null) declMod = ctx.moduleLut.get(Context.pathKey(mp));
				}
				// Pmod is the module this parameter was declared in, captured above while it was current;
				// declaringModule is null for a TYPE-level param, which is exactly the
				// case that misses.
				if (declMod == null) declMod = declaringModule != null ? declaringModule : pmod;
				if (declMod != null) ctx.currentModule = declMod;
				try {
					// A display-allowed load.
					var def = loadComplexType(ctx, getParams(), tp.tpDefault, true);
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
						// Each constraint is a display-allowed load.
						case CTIntersection(tl): [for (ct in tl) loadComplexType(ctx, typeParams, ct, true)];
						case CTParent(ct): loop(ct);
						case _: [loadComplexType(ctx, typeParams, h, true)];
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
			} catch (e:Dynamic) {
				ctx.currentModule = savedMod;
				throw e;
			}
		}));
		// A protected lazy is forced at PForce by default, so the constraint load is scheduled whether or
		// not anything ever uses the parameter. Without that a constraint naming a type that does not
		// resolve is never forced, and the declaration compiles clean.
		ctx.delay(Context.PForce, function() TypeFunctions.lazyType(r));
		return TypeFunctions.mkTypeParam(n, TLazy(r), def);
	}

	// Typer.displayType with `scope` as the type parameters in scope: the collection a type
	// parameter's own name raises.
	public static function displayTypeInScope(ctx:Context, t:T, p:Position, scope:TypeParams):Void {
		var saved = currentTypeParams;
		currentTypeParams = scope;
		try hxc.typing.Typer.displayType(ctx, t, p) catch (e:Dynamic) { currentTypeParams = saved; throw e; }
		currentTypeParams = saved;
	}

	// scopeParams: ctx.typeParams where the list is declared - the enclosing type's for a method or
	// a local function (baseParams, the default), the enum's for a constructor.
	public static function typeTypeParams(ctx:Context, declPath:Path, tps:Array<TypeParam>, ?baseParams:TypeParams, host:TypeParamHost = TPHType, ?declModule:ModuleDef, ?scopeParams:TypeParams):TypeParams {
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
			params.push(typeTypeParam(ctx, declPath, getParams, tp, host, declModule, scopeParams != null ? scopeParams : baseParams));
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

	// The defaults are gathered by a prepending fold, so the object lists them in reverse declaration
	// order.
	public static function generateArgsMeta(args:Array<FunctionArg>, addMeta:MetadataEntry->Void):Void {
		var values:Array<ObjectField> = [];
		for (a in args) if (a.value != null)
			values.unshift({name: a.name.name, pos: a.name.pos, quotes: NoQuotes, expr: a.value});
		if (values.length > 0)
			addMeta({name: ":value", params: [new Expr(EObjectDecl(values), pNull)], pos: pNull});
		var withMeta = false;
		for (a in args) if (a.meta != null && a.meta.length > 0) withMeta = true;
		if (withMeta) {
			var fn:Func = {fParams: [], fArgs: args, fType: null, fExpr: null};
			addMeta({name: ":haxe.arguments", params: [new Expr(EFunction(FKAnonymous, fn), pNull)], pos: pNull});
		}
	}

	static function spawnMonomorph():T {
		return TypeFunctions.mkMono();
	}

	/**
	 * Type hints hxc SYNTHESISES rather than reads from syntax: an abstract's own self-type and the
	 * parameter paths inside it, built with the declaration's position. They are never displayed:
	 * display is allowed for a type the user WROTE and not for one built internally. The hook is
	 * reached through a call shape that cannot tell the two apart, so the verdict rides on the hint
	 * itself, the way Typer.synthesized carries it for an expression.
	 *
	 * Keyed by identity and not drained on use, since one hint is loaded once per field that carries
	 * it. Cleared per compilation: the server reuses this context, and a registry that only grows
	 * leaks across requests.
	 */
	public static var synthesizedHints:haxe.ds.ObjectMap<TypeHint, Bool> = new haxe.ds.ObjectMap();

	public static function synthesizedHint(th:TypeHint):TypeHint {
		synthesizedHints.set(th, true);
		return th;
	}

	public static function resetSynthesizedHints():Void {
		synthesizedHints = new haxe.ds.ObjectMap();
	}


	// A PACKAGE-LESS path that does not resolve recovers to Dynamic wherever the run tolerates errors,
	// so the rest of the declaration still types and the report can describe the name rather than stop
	// at it. A PACKAGED path keeps its error, and so does a bare one with the cursor inside the hint,
	// where the name is the subject of the request. In a diagnostics run the name is recorded as an
	// unresolved identifier instead, which is what turns it into DKUnresolvedIdentifier rather than a
	// compiler error.
	public static function loadComplexType(ctx:Context, typeParams:TypeParams, th:TypeHint, allowDisplay:Bool = false):T {
		if (th != null && synthesizedHints.exists(th)) {
			var saved = hxc.parser.Parser.displaySuppressed;
			hxc.parser.Parser.displaySuppressed = true;
			var r = try loadComplexTypePrime(ctx, typeParams, th.ct, th.pos, allowDisplay)
				catch (e:Dynamic) { hxc.parser.Parser.displaySuppressed = saved; throw e; };
			hxc.parser.Parser.displaySuppressed = saved;
			return r;
		}
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
				// The extension is not built here: a monomorph is made, and the extension is built inside a
				// protected lazy that binds it on first force. The members of an intersection can name the
				// typedef being defined, so building eagerly follows one that has not been resolved yet and
				// reports "Can only extend structures" for a valid recursive structure.
				var tr = TypeFunctions.monomorphCreateRef();
				var t = TMono(tr);
				var r = excProtect(ctx, function(r) {
					r.set(TypeFunctions.lazyProcessing(function():T return t));
					var ta = makeExtensionType(ctx, resolved);
					TypeFunctions.monomorphBindRef(tr, ta);
					return ta;
				});
				TLazy(r);

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
						// A monomorph bound inside a protected lazy, so the extended typedefs are followed
						// when the lazy is
						// forced (at PForce at the latest), by which time the module's own typedefs are
						// initialised.
						var tr = TypeFunctions.monomorphCreateRef();
						var t = TMono(tr);
						var r = excProtect(ctx, function(r) {
							r.set(TypeFunctions.lazyProcessing(function():T return t));
							TypeFunctions.monomorphBindRef(tr, if (il.length == 1) mkExtension(ctx, a, il[0].t, il[0].pos) else {
								for (e in il) extendLoop(ctx, a, e.t, e.pos);
								a.status.set(Extend([for (e in il) e.t]));
								anonT;
							});
							return t;
						});
						TLazy(r);
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
		out.jsonEntries = tc.jsonEntries;
		out.jsonFilter = function(info) {
			var cm = info.kind == "type" ? hxc.typing.Typer.completionModuleType(info) : null;
			return cm != null && cm.kind == 6;
		};
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
		inline function pathOf(mt:ModuleType):String return hxc.core.Globals.sTypePath(TypeFunctions.tPath(mt));
		if (ctx.currentModule != null)
			for (mt in ctx.currentModule.types) if (pathOf(mt) == it.path) return isStruct(mt);
		for (key in ctx.moduleLut.keys())
			for (mt in ctx.moduleLut.get(key).types) if (pathOf(mt) == it.path) return isStruct(mt);
		return false;
	}

	// An Error escaping the lazy is fatal, and by default the lazy is forced at PForce.
	static function excProtect(ctx:Context, f:Ref<TLazy>->T):Ref<TLazy> {
		var r:Ref<TLazy> = new Ref(TypeFunctions.lazyAvailable(TypeFunctions.tDynamic));
		r.set(TypeFunctions.lazyWait(function():T {
			var t = try f(r) catch (e:ContextError) {
				var fe = new FatalError(e.message, e.pos, e.depth, true);
				fe.callChain = e.callChain;
				throw fe;
			} catch (e:TypingError) {
				var fe = new FatalError(e.message, e.pos, e.depth, true);
				fe.callChain = e.callChain;
				throw fe;
			};
			r.set(TypeFunctions.lazyAvailable(t));
			return t;
		}));
		ctx.delay(Context.PForce, function() TypeFunctions.lazyType(r));
		return r;
	}

	// The keys in increasing order.
	static function sortedKeys(m:StringMap<TClassField>):Array<String> {
		var keys = hxc.core.MapKeys.ofString(m);
		hxc.core.StringSort.sort(keys);
		return keys;
	}

	// A field already in `fields` is a redefinition, fine when the types are the same and an error when
	// they are not.
	static function isRedefined(ctx:Context, cf1:TClassField, fields:StringMap<TClassField>, p:Position):Bool {
		var cf2 = fields.get(cf1.name);
		if (cf2 == null) return false;
		if (!TypeUnification.typeIseqDefault(cf1.type, cf2.type)) {
			var pctx = hxc.core.TPrinting.printContext();
			ctx.addDiagnostic("Cannot redefine field " + cf1.name + " with different type", p);
			ctx.addDiagnostic("First type was " + hxc.core.TPrinting.sType(pctx, cf1.type), cf1.pos);
			throw new ContextError("Second type was " + hxc.core.TPrinting.sType(pctx, cf2.type), cf2.pos);
		}
		return true;
	}

	// One extended type.
	static function mkExtension(ctx:Context, a:TAnon, it:T, p:Position):T {
		return switch (TypeFunctions.follow(it)) {
			case TInst(c, _) if (isTypeParameter(c)):
				throw new ContextError("Cannot structurally extend type parameters", p);
			case TMono(_):
				throw new ContextError("Loop found in cascading signatures definitions. Please change order/import", p);
			case TAnon(a2):
				for (k in sortedKeys(a.fields)) isRedefined(ctx, a.fields.get(k), a2.fields, p);
				var merged = new StringMap<TClassField>();
				for (k in a2.fields.keys()) merged.set(k, a2.fields.get(k));
				for (k in a.fields.keys()) merged.set(k, a.fields.get(k));
				TypeFunctions.mkAnon(new Ref<AnonStatus>(Extend([it])), merged);
			case _:
				throw new ContextError("Can only extend structures", p);
		}
	}

	// Several extended types: a field the structure has already is kept.
	static function extendLoop(ctx:Context, a:TAnon, it:T, p:Position):Void {
		switch (TypeFunctions.follow(it)) {
			case TAnon(a2):
				for (k in sortedKeys(a2.fields)) {
					var cf = a2.fields.get(k);
					if (!isRedefined(ctx, cf, a.fields, p)) a.fields.set(k, cf);
				}
			case _:
				throw new ContextError("Can only extend structures", p);
		}
	}

	// The first declaration of a field is kept.
	static function makeExtensionType(ctx:Context, tl:Array<{t:T, pos:Position}>):T {
		var fields = new StringMap<TClassField>();
		for (e in tl) switch (TypeFunctions.follow(e.t)) {
			case TAnon(a):
				for (k in sortedKeys(a.fields)) {
					var cf = a.fields.get(k);
					if (!isRedefined(ctx, cf, fields, e.pos)) fields.set(cf.name, cf);
				}
			case _:
				throw new ContextError("Can only extend structures", e.pos);
		}
		return TypeFunctions.mkAnon(new Ref<AnonStatus>(Extend([for (e in tl) e.t])), fields);
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
		var displayedField:Null<TClassField> = null;
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
			// The cursor on a structure field's name answers with that field.
			if (hxc.typing.Typer.atDisplayPos(cf.namePos)) displayedField = cf;
			fields.set(n, cf);
		}
		var anon = TypeFunctions.mkAnon(new Ref<AnonStatus>(Closed), fields);
		// The answer is a PBuildClass delay, so a type the field names (an intersection over a
		// typedef the module declares later) is forced once the module is initialised.
		if (displayedField != null) {
			var dcf = displayedField;
			ctx.delay(Context.PBuildClass, function() hxc.typing.Typer.displayAnonField(dcf));
		}
		return anon;
	}

	// Resolve a type path to its module type (part of loading a type instance: no generics,
	// display or expression parameters).
	public static function resolveTypePath(ctx:Context, path:Path, sub:Null<String>, p:Position):ModuleType {
		if (path.pack.length > 0 && path.pack[0] == "std") {
			// `std.x.Y` loads the module std.x.Y, and only when that module does not exist the module x.Y -
			// a QUALIFIED load, so std.Type from inside package `cases` is the top-level Type, never a
			// cases.Type beside the caller.
			var m = hxc.context.ModuleLoader.loadModuleOpt(ctx, path, p);
			if (m == null) m = hxc.context.ModuleLoader.loadModule(ctx, {pack: path.pack.slice(1), name: path.name}, p);
			return hxc.context.ModuleLoader.findTypeInModule(ctx, m, sub != null ? sub : path.name, p);
		}
		if (sub == null && path.pack.length == 0 && ctx.currentModule != null) {
			for (mt in ctx.currentModule.types) {
				if (TypeFunctions.tPath(mt).name == path.name) return mt;
			}
		}
		// A path matches by its full path as well as by the bare name, so a path written in full - or
		// qualified by the heritage's import resolution - is found among the module's own types and then
		// its
		// imports before any module is loaded. A sub-type of the current module has no module of its own
		// path.
		if (sub == null && path.pack.length > 0 && ctx.currentModule != null) {
			for (mt in ctx.currentModule.types) {
				var tp = TypeFunctions.tPath(mt);
				if (tp.name == path.name && tp.pack.join(".") == path.pack.join(".")) return mt;
			}
			var imp = hxc.context.ModuleLoader.resolveImportTypeByPath(ctx, ctx.currentModule, path, p);
			if (imp != null) return imp;
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
			// Every module's imports are seeded with the StdTypes types: a lookup there, not a module load.
			var std = try hxc.context.ModuleLoader.loadImportedModule(ctx, {pack: [], name: "StdTypes"}, p) catch (_:Dynamic) null;
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
			// Only a miss tries the other routes: an Error the load raised (a build that failed at the
			// load's
			// flush) is the answer.
			if (Std.isOfType(e, ContextError) && (cast e : ContextError).kind.match(Other)) throw e;
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

	/**
		The type loaded the way StdTypes would load it - with the std module current, no imports and no
		type parameters - so a core name never walks the requesting module's package (and never asks
		onTypeNotFound about `<package>.<name>`). The requester then depends on the type's module.
	**/
	public static function loadCoreType(ctx:Context, name:String):T {
		var std = ctx.moduleLut.get(Context.pathKey({pack: [], name: "StdTypes"}));
		var old = ctx.currentModule;
		ctx.currentModule = std;
		var t = try loadInstance(ctx, [], {tpackage: [], tname: name, tparams: [], tsub: null}, Position.nullPos, false) catch (e:Dynamic) {
			ctx.currentModule = old;
			throw e;
		};
		ctx.currentModule = old;
		var m = switch (t) {
			case TInst(c, _): c.module;
			case TType(td, _): td.module;
			case TAbstract(a, _): a.module;
			case TEnum(e, _): e.module;
			case _: throw "load_core_type";
		};
		if (old != null && m != null) hxc.context.ModuleLoader.addDependency(old, m);
		return t;
	}

	public static function loadInstance(ctx:Context, typeParams:TypeParams, t:TypePath, p:Position, allowNoParams:Bool, ?specializeGeneric:Bool = true, allowDisplay:Bool = false, ?tctx:hxc.typing.TyperContext):T {
		var savedTp = currentTypeParams;
		currentTypeParams = typeParams;
		try {
			var res = loadInstanceInner(ctx, typeParams, t, p, allowNoParams, specializeGeneric, allowDisplay, tctx);
			currentTypeParams = savedTp;
			return res;
		} catch (e:Dynamic) {
			currentTypeParams = savedTp;
			throw e;
		}
	}

	static function loadInstanceInner(ctx:Context, typeParams:TypeParams, t:TypePath, p:Position, allowNoParams:Bool, ?specializeGeneric:Bool = true, allowDisplay:Bool = false, ?tctx:hxc.typing.TyperContext):T {
		// A type path that does not resolve, with the cursor on it, is a completion request rather than
		// an error - the name is what the user is still typing.
		var r = if (hxc.parser.Parser.displayCompletionMode && hxc.typing.Typer.atDisplayPos(p))
			try loadInstance_(ctx, typeParams, t, p, allowNoParams, specializeGeneric, tctx)
			catch (e:ContextError) {
				if (e.message.indexOf("Type not found") != 0) throw e;
				// The subject is the path the user wrote, and the range it replaces is that path's own span.
				var sname = t.tsub != null ? t.tsub : t.tname;
				var sfull = (t.tpackage.length == 0 ? "" : t.tpackage.join(".") + ".") + t.tname + (t.tsub != null ? "." + t.tsub : "");
				var sp = new Position(p.file, p.min, p.min + sfull.length);
				hxc.typing.TypeResolve.answerTypeHintCompletion(ctx, sp, sfull);
				throw e;
			}
		else loadInstance_(ctx, typeParams, t, p, allowNoParams, specializeGeneric, tctx);
		// Records every hint, whatever the request. The list only feeds the reference searches, so hxc
		// keeps it for display requests - decided from the argument, since the core types' own hints
		// resolve before the display mode is installed.
		if (ctx.displaySpec != null)
			typeHints.push({m: ctx.currentModule, p: p, t: r});
		if (hxc.parser.Parser.displayFile != null) {
			// The path's range is narrowed to the dotted name itself, so `Array<Foo>` with the cursor on
			// Foo
			// answers Foo and not Array.
			var strings = t.tsub != null ? [t.tsub, t.tname].concat(t.tpackage) : [t.tname].concat(t.tpackage);
			var pName = new Position(p.file, p.min, p.min + strings.join(".").length);
			// The cursor test covers the whole path, parameters included, and narrows to the dotted name
			// only for the answer, so `new H<Int>()` asked on the `(` answers `H`, not the whole new
			// expression.
			if (hxc.typing.Typer.atDisplayPos(p)) hxc.typing.Typer.displayType(ctx, r, pName, allowDisplay);
		}
		return r;
	}

	static function loadInstance_(ctx:Context, typeParams:TypeParams, t:TypePath, p:Position, allowNoParams:Bool, ?specializeGeneric:Bool = true, ?tctx:hxc.typing.TyperContext):T {
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
		ensureResolved(ctx, TypeFunctions.tModule(mt));
		var types = TypeFunctions.tInfos(mt).params;
		var declPath = TypeFunctions.tPath(mt);
		var build = function(params:TParams):T return buildInstance(ctx, mt, params, p, specializeGeneric, typeParams, tctx);
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
					// The synthetic const-parameter class is named from the CONSTANT only: "S" + s, "I" + const,
					// "F" + const, and the literal "Expr" for everything else, the display marker included, so
					// `Gen<true>`'s parameter is named `Expr`; --xml/--json print it and a generic
					// specialization's path is built from it. The marked expression (a display marker, which
					// matches none of the constant arms) is typed as a value, which is what answers the display
					// request, and names its class "Expr".
					var name = if (e == hxc.typing.ExprPreprocessing.markedNode) {
						if (tctx != null) hxc.typing.Typer.typeExpr(tctx, e, hxc.core.WithType.WithTypeTools.value);
						"Expr";
					} else switch (e.expr) {
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
		var checks:Array<{t:T, c:TClass, p:Position}> = [];
		var i1 = 0, i2 = 0;
		while (true) {
			if (i1 < t.tparams.length && i2 < types.length) {
				var loaded = loadParam(t.tparams[i1]);
				var pt = switch (t.tparams[i1]) {
					case TPType(th): th.pos;
					case TPExpr(e): e.pos;
				};
				// A CONSTANT is accepted only where the declaration asks for one (a parameter named Const,
				// or one
				// carrying @:const) or tolerates one (a parameter named Rest), and a parameter that asks
				// for one
				// takes nothing else. Both report over the whole path, not the parameter.
				var declName = types[i2].name;
				var checkConst = function(c2:TClass):Void {
					var isExpression = switch (loaded) { case TInst({kind: KExpr(_)}, _): true; case _: false; };
					var expectsExpression = declName == "Const" || TypeFunctions.hasMeta(":const", c2.meta);
					if (isExpression) {
						if (!expectsExpression && declName != "Rest")
							throw new ContextError("Constant value unexpected here", p);
					} else if (expectsExpression)
						throw new ContextError("Type parameter is expected to be a constant value", p);
				};
				// Following the declaration param forces its constraint lazy; an unconstrained param of a
				// non-generic type needs no check.
				switch (TypeFunctions.follow(types[i2].type)) {
					case TInst(c2 = {kind: KTypeParameter([])}, []) if (!isGeneric):
						checkConst(c2);
					case TInst(c2, []):
						checkConst(c2);
						checks.push({t: loaded, c: c2, p: pt});
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

	// Instance building (subset): for the non-generic case it is just the declared type with the
	// actual params applied: TInst/TEnum/TType/TAbstract with the given params. We build directly. A
	// type argument that is a type parameter of something other than the caller's own generic class or
	// field, and carries a constructor constraint, cannot be used at a @:generic build. A type
	// parameter among the arguments - which may carry a constructor constraint only when it is generic
	// itself - or a display request that types selectively gives a normal instance. Otherwise the
	// arguments are named, raising on one that cannot be named, and the class is specialized.
	public static function buildGenericClass(ctx:Context, c:TClass, tl:TParams, p:Position, ?tctx:hxc.typing.TyperContext):T {
		var recurse = false;
		function checkRecursive(t:T):Void {
			switch (TypeFunctions.follow(t)) {
				case TInst(c2, tl2):
					switch (c2.kind) {
						case KTypeParameter(_):
							// Typer.isGenericParameter needs the typer's current class and field, which
							// only
							// the typer's own loads carry.
							if (tctx != null && !hxc.typing.Typer.isGenericParameter(tctx, c2) && TypeFunctions.hasCtorConstraint(c2))
								throw new TypingError("Type parameters with a constructor cannot be used non-generically", p);
							recurse = true;
						case _:
					}
					for (t2 in tl2) checkRecursive(t2);
				case _:
			}
		}
		for (t in tl) checkRecursive(t);
		if (recurse || !ctx.displayFullTyping) return TInst(c, tl);
		makeGenericName(c.params, tl, p);
		return TInst(specializeGenericClass(ctx, c, tl, p), []);
	}

	// An Error out of a class build is an Error, not the miss a resolution failure raises: the
	// identifier and dot-path fallbacks let it pass and the statement records it. hxc signals a miss
	// with a TypingError, so a build's failure travels as a ContextError instead, which those fallbacks
	// do not catch and typeBlock records; taken for a miss, the fallback re-resolves the now fieldless
	// class and reports its missing field.
	public static function forceBuildInBody(ctx:Context, c:TClass):Void {
		// A build carries its own heritage; hxc sets a class's heritage in resolveModule, and ensureBuilt
		// reads it for the inherited @:autoBuild. A class forced before its module resolved is marked built
		// with the parent's autoBuild unseen, so the module resolves first, and a module whose resolution
		// is
		// still open is left to the install path that builds it on the way.
		var m = c.module;
		if (m != null && m.extra.resolved == 0) hxc.typing.TypeResolve.resolveModule(ctx, m);
		if (m != null && hxc.typing.TypeResolve.resolving.exists(m)) return;
		try hxc.eval.EvalMacro.ensureBuilt(ctx, c)
		catch (e:hxc.core.TypingError) {
			// The kind survives the change of class: a macro module that did not load is
			// Module_not_found, which the argument annotation leaves alone.
			var kind = Std.isOfType(e, hxc.core.TypingError.ModuleNotFoundError) ? ModuleNotFound(c.path) : Other;
			var ce = new hxc.context.Context.ContextError(e.message, e.pos, kind, e.depth);
			ce.callChain = e.callChain;
			throw ce;
		}
	}

	// A specialization, a MacroType or a @:genericBuild is a protected lazy (forced at PForce, an Error
	// escaping it fatal) over a monomorph the built type unifies into and, when it is Dynamic, is bound
	// to (unify leaves a monomorph unbound against Dynamic); the built class or abstract is then built
	// itself.
	static function instanceLazy(ctx:Context, p:Position, f:Void->T):T {
		var r:Ref<TLazy> = new Ref(TypeFunctions.lazyAvailable(TypeFunctions.tDynamic));
		r.set(TypeFunctions.lazyWait(function():T {
			var t = TypeFunctions.mkMono();
			r.set(TypeFunctions.lazyProcessing(function():T return t));
			try {
				var tf = f();
				TypeUnification.unifyDefault(tf, t);
				TypeUnification.linkDynamic(t, tf);
				switch (tf) {
					case TInst(c2, _): hxc.typing.TypeResolve.forceBuild(ctx, c2);
					case TAbstract(a2, _): if (a2.impl != null) hxc.typing.TypeResolve.forceBuild(ctx, a2.impl);
					case _:
				}
			} catch (e:ContextError) {
				var fe = new FatalError(e.message, e.pos, e.depth, true);
				fe.callChain = e.callChain;
				throw fe;
			} catch (e:hxc.core.TypeUnification.UnifyError) {
				throw new FatalError(hxc.core.TPrinting.betterErrorMessage(e.errors), p, 0, true);
			} catch (e:TypingError) {
				var fe = new FatalError(e.message, e.pos, e.depth, true);
				fe.callChain = e.callChain;
				throw fe;
			}
			r.set(TypeFunctions.lazyAvailable(t));
			return t;
		}));
		ctx.delay(Context.PForce, function() TypeFunctions.lazyType(r));
		return TLazy(r);
	}

	static function buildInstance(ctx:Context, mt:ModuleType, params:TParams, p:Position, specializeGeneric:Bool, ?callerTypeParams:TypeParams, ?tctx:hxc.typing.TyperContext):T {
		return switch (mt) {
			case TClassDecl(c):
				// Past PBuildClass every class is built before its kind is looked at. A class named while a
				// body is
				// being typed builds right there, and its build's failure is that expression's error.
				if (hxc.typing.TypeFields.bodyDepth > 0) forceBuildInBody(ctx, c);
				switch (c.kind) {
					// The generic class build runs behind the instance's lazy and decides there between a
					// normal
					// instance and a specialization.
					case KGeneric if (specializeGeneric):
						instanceLazy(ctx, p, function() return buildGenericClass(ctx, c, params, p, tctx));
					case KGenericBuild(fields):
						instanceLazy(ctx, p, function() return hxc.eval.EvalMacro.runGenericBuild(ctx, c, params, fields, p, callerTypeParams));
					case KMacroType:
						// The instance is the macro's result, and the single parameter carries the call. The lazy
						// keeps the typer it was made in (it reads its current class for a bare ident), so the class
						// being resolved is captured now.
						var resolving = ctx.resolvingClass;
						instanceLazy(ctx, p, function() return hxc.eval.EvalMacro.runMacroType(ctx, params, p, callerTypeParams, resolving));
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
	// The instance is attached to the module current when the generic build STARTED. hxc has one
	// Context whose currentModule moves on, and a cascaded instance is built from a lazy that fires once
	// it is null, so the module travels alongside genericBuildCtx.
	static var genericBuildModule:Null<hxc.core.Type.ModuleDef> = null;
	// The module of the instance CURRENTLY being built, which differs from the module that asked for
	// it. Each cascading instance hangs off this one.
	static var genericInstanceModule:Null<hxc.core.Type.ModuleDef> = null;

	public static function canSpecializeGeneric(params:TParams):Bool {
		return !hasOpenMono(params) && !hasTypeParameterParams(params);
	}

	static function genericKey(c:TClass, params:TParams, ?p:Position):String {
		// The module id separates the host and macro worlds: each types its own copy of the class,
		// and a specialization from the other world has no prototypes in this one.
		var world = c.module != null ? Std.string(c.module.id) : "";
		return Context.pathKey(c.path) + "#" + world + "_" + makeGenericName(c.params, params, p == null ? Position.nullPos : p);
	}

	// The generic's name: each type parameter names its argument, and an argument it cannot name at the
	// top raises, at the position given and naming the parameter.
	public static function makeGenericName(ps:TypeParams, pt:TParams, p:Position):String {
		return [for (i in 0...ps.length) genericNamePart(ps[i].name, true, pt[i], p)].join("_");
	}

	// The type path with its package joined by underscores.
	static function genericTypePath(path:Path):String {
		return path.pack.length == 0 ? path.name : path.pack.join("_") + "_" + path.name;
	}

	// The name parts are evaluated right to left, so a tail names before its head and a function's
	// return type before its arguments.
	static function genericNamePart(s:String, top:Bool, t:T, p:Position):String {
		return switch (t) {
			case TInst(c, tl):
				switch (c.kind) {
					case KExpr(e): genericIdentSafe(hxc.ast.Printer.sExpr(e));
					case _:
						var tail = genericNameTail(s, top, tl, p);
						genericIdentSafe(genericTypePath(c.path)) + tail;
				}
			case TType(td, tl): var tail = genericNameTail(s, top, tl, p); genericTypePath(td.path) + tail;
			case TEnum(en, tl): var tail = genericNameTail(s, top, tl, p); genericTypePath(en.path) + tail;
			case TAnon(a):
				// The names are visited in increasing order and prepended, so they spell decreasing.
				var parts = [];
				for (n in hxc.core.PMapOrder.sortedKeys(a.fields))
					parts.unshift(n + "_" + genericNamePart(s, false, TypeFunctions.follow(a.fields.get(n).type), p));
				"anon_" + parts.join("_");
			case TFun(sig):
				var ret = genericNamePart(s, false, sig.ret, p);
				var args = [for (a in sig.args) genericNamePart(s, false, a.t, p)];
				"func_" + args.join("_") + "_" + ret;
			case TAbstract(a, tl): var tail = genericNameTail(s, top, tl, p); genericTypePath(a.path) + tail;
			case _ if (!top):
				// Allow unknown/incompatible types as type parameters to retain old behavior
				genericFollowOr(s, t, top, p, function() return "_");
			case TMono(r) if (r.type == null):
				throw new GenericException("Could not determine type for parameter " + s, p);
			case TDynamic(_):
				"Dynamic";
			case _:
				genericFollowOr(s, t, top, p, function():String
					throw new GenericException("Unsupported type parameter: " + hxc.core.TPrinting.sTypeStr(t) + ")", p));
		};
	}

	static function genericNameTail(s:String, top:Bool, tl:TParams, p:Position):String {
		return tl.length == 0 ? "" : "_" + [for (t in tl) genericNamePart(s, top, t, p)].join("_");
	}

	// One step of followOnce, or the fallback when that changes nothing.
	static function genericFollowOr(s:String, t:T, top:Bool, p:Position, orFn:Void->String):String {
		var ft = TypeFunctions.followOnce(t);
		return ft == t ? orFn() : genericNamePart(s, top, ft, p);
	}

	// Matching is on bytes, so a character outside the safe set spells each of its UTF-8 bytes as
	// _<code>_.
	static function genericIdentSafe(s:String):String {
		var out = new StringBuf();
		var b = haxe.io.Bytes.ofString(s);
		for (i in 0...b.length) {
			var c = b.get(i);
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
			// The tfunc record is built right to left in its declared field order (args, type, expr): the
			// body first, then the arguments, whose defaults stay as they were. one variable table is kept
			// for the whole expression.
			case TFunction(f):
				var body = cloneExpr(f.expr, subst, vars, gsubst);
				var ft = subst(f.type);
				var args = [for (a in f.args) {v: cloneVar(a.v, subst, vars), c: a.c}];
				TFunction(new TFunc(args, ft, body));
			// The TVar: the initializer before the variable.
			case TVarExpr(v, eo):
				var ce = opt(eo);
				TVarExpr(cloneVar(v, subst, vars), ce);
			case TBlock(exprs): TBlock(arr(exprs));
			case TFor(v, e1, e2): TFor(cloneVar(v, subst, vars), cloneExpr(e1, subst, vars, gsubst), cloneExpr(e2, subst, vars, gsubst));
			case TIf(econd, eif, eelse): TIf(cloneExpr(econd, subst, vars, gsubst), cloneExpr(eif, subst, vars, gsubst), opt(eelse));
			case TWhile(econd, e1, flag): TWhile(cloneExpr(econd, subst, vars, gsubst), cloneExpr(e1, subst, vars, gsubst), flag);
			// A case's body before its values, a catch's body before its variable.
			case TSwitch(e1, cases, edef):
				var c1 = cloneExpr(e1, subst, vars, gsubst);
				var cc = [for (c in cases) { var body = cloneExpr(c.expr, subst, vars, gsubst); {values: arr(c.values), expr: body}; }];
				TSwitch(c1, cc, opt(edef));
			case TTry(e1, catches):
				var c1 = cloneExpr(e1, subst, vars, gsubst);
				TTry(c1, [for (c in catches) { var body = cloneExpr(c.expr, subst, vars, gsubst); {v: cloneVar(c.v, subst, vars), expr: body}; }]);
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
							var inst = specializeGenericClass(ctx, gc, tl2 != null ? tl2 : tl, p);
							// The instance being built DEPENDS on every cascading instance its substitution
							// created, so reusing
							// it from the cache brings them back with it.
							if (genericInstanceModule != null)
								hxc.context.ModuleLoader.addDependency(genericInstanceModule, inst.module);
							TInst(inst, []);
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
						// A copy of the parameter's class that belongs to the instance's module.
						var pc2 = new TClass(pc.path, genericInstanceModule != null ? genericInstanceModule : pc.module,
							pc.pos, pc.namePos, pc.isPrivate, pc.doc, pc.meta, pc.params, pc.usings,
							pc.restore, pc.kind, pc.flags, pc.superClass, pc.interfaces, pc.fields, pc.statics,
							pc.orderedStatics, pc.orderedFields, pc.dynamicType, pc.arrayAccess, pc.constructor,
							pc.init, pc.build, pc.descendants);
						pc2.initField = pc.initField;
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
		var declModule = ctx.currentModule;
		var declInstModule = genericInstanceModule;
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
				var savedGMod = genericBuildModule;
				var savedIMod = genericInstanceModule;
				genericBuildCtx = ctx;
				genericBuildModule = declModule;
				genericInstanceModule = declInstModule;
				cf.expr = cloneExpr(f.expr, subst, new Map(), gsubst2);
				cf.exprUnoptimized = f.exprUnoptimized == null ? null : cloneExpr(f.exprUnoptimized, subst, new Map(), gsubst2);
				genericBuildCtx = savedGCtx;
				genericBuildModule = savedGMod;
				genericInstanceModule = savedIMod;
			}
			lr.set(LAvailable(t));
			return t;
		}));
		cf.type = TLazy(lr);
		// Each field's lazy is forced at PForce, one delay per field as it is built - the constructor, then
		// the fields in order - so the pass, LIFO, clones the last field first. A read before then clones
		// it
		// on demand.
		ctx.delay(hxc.context.Context.PForce, function() TypeFunctions.lazyType(lr));
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
		var savedGenericMod = genericBuildModule;
		if (ctx.currentModule != null) genericBuildModule = ctx.currentModule;
		var key = genericKey(c, params, p);
		var cached = genericInstances.get(key);
		if (cached != null) { genericBuildCtx = savedGenericCtx; genericBuildModule = savedGenericMod; return cached; }
		var suffix = "_" + makeGenericName(c.params, params, p);
		if (suffix == "_") suffix = "_Generic" + (++genericInstanceId);
		var path:hxc.core.Globals.Path = {pack: c.path.pack, name: c.path.name + suffix};
		// The generated path is looked up first and an instance of the same base class is handed back;
		// only something else under that name is the error below. Without it, a warm rebuild
		// re-specializes from a base class whose body has since been through the filters, and
		// GenericStack_Int's `null` comes out typed Dynamic (`null()`) instead of `0`. The lookup checks
		// the whole subgraph, so a dirty base
		// class or type parameter still rebuilds, and the cascading-instance dependency brings those
		// instances back along with it.
		if (hxc.context.ServerCache.enabled) {
			var cachedM = try hxc.context.ServerCache.typeModule(ctx, path, p) catch (_:Dynamic) null;
			if (cachedM != null) {
				for (mt in cachedM.types) switch (mt) {
					case TClassDecl(cgOld):
						switch (cgOld.kind) {
							case KGenericInstance(base, _) if (base == c):
								genericInstances.set(key, cgOld);
								hxc.context.ModuleLoader.addDependency(ctx.currentModule != null ? ctx.currentModule : genericBuildModule, cachedM);
								if (genericInstanceModule != null)
									hxc.context.ModuleLoader.addDependency(genericInstanceModule, cachedM);
								genericBuildCtx = savedGenericCtx;
								genericBuildModule = savedGenericMod;
								return cgOld;
							case _:
						}
					case _:
				}
			}
		}
		// Before anything is built the instance's path is looked up - the qualified module, or for a
		// top-level class the unqualified walk. A miss of that very path is what builds it, and the lookup
		// is what reaches Context.onTypeNotFound the first time each specialization is asked for. A path
		// the
		// module table already holds is the epoch question below.
		if (!ctx.moduleLut.exists(Context.pathKey(path))) {
			var found:Null<ModuleType> = null;
			if (path.pack.length > 0) {
				var mfound = hxc.context.ModuleLoader.loadModuleOpt(ctx, path, p);
				if (mfound != null) {
					found = hxc.context.ModuleLoader.findTypeInModuleOpt(mfound, path.name);
					if (found == null) {
						genericBuildCtx = savedGenericCtx;
						genericBuildModule = savedGenericMod;
						throw new TypingError("Module " + Context.sTypePath(mfound.path) + " does not define type " + path.name, p);
					}
				}
			} else if (ctx.currentModule != null) {
				found = hxc.context.ModuleLoader.resolveBareType(ctx, ctx.currentModule, path.name, p);
			}
			if (found != null) {
				genericBuildCtx = savedGenericCtx;
				genericBuildModule = savedGenericMod;
				switch (found) {
					case TClassDecl(cgOld):
						switch (cgOld.kind) {
							case KGenericInstance(base, _) if (base == c):
								genericInstances.set(key, cgOld);
								return cgOld;
							case _:
						}
					case _:
				}
				throw new TypingError("Cannot specialize @:generic because the generated type name is already used: " + path.name, p);
			}
		}
		// Make sure the super class is already set up before its signatures are substituted, once the
		// lookup has missed. A @:generic reached from a HERITAGE clause specializes before the base class
		// has had its field types resolved, and substituting an open monomorph only yields another one.
		// build is the whole build - heritage then fields - so this has to force both: with the field
		// half only, the specialised copy has no superClass and `super()` in the generic's constructor
		// reports "Current class does not have a super".
		hxc.typing.TypeResolve.forceBuild(ctx, c);
		// A user type already claiming the generated name blocks specialization; our own instances hit
		// the cache above and never reach here. The name is looked up in the state of this compilation;
		// the reused macro context still maps the instance it generated for the previous one, which
		// claims nothing (the epoch rule ModuleLoader.checkModuleTypes uses).
		if (ctx.typeToModule.exists(Context.pathKey(path))
			&& ctx.typeToModuleEpoch.get(Context.pathKey(path)) == ctx.compilationEpoch)
			throw new TypingError("Cannot specialize @:generic because the generated type name is already used: " + path.name, p);
		var mg = new ModuleDef(TypeFunctions.allocMid(), path, [], null, TypeFunctions.moduleExtra("", "", 0.0, MFake, []));
		mg.extra.resolved = 2;
		var savedInstMod = genericInstanceModule;
		genericInstanceModule = mg;
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
		// The instance gets the forwarder over its super's constructor like any class without one, before
		// its own is cloned below. When the base declares one the forwarder is replaced, but the PForce
		// delay that builds it has already been queued.
		hxc.typing.Typer.addConstructor(new hxc.typing.TyperContext(ctx), cg, false);
		var lazyFields:Array<TClassField> = [];
		// The base's constructor is cloned; otherwise the forwarder stands; a class with neither, over a
		// base class, is an error.
		if (c.constructor != null) cg.constructor = cloneField(ctx, c, gsubst, c.constructor, lazyFields);
		else if (cg.constructor == null && c.superClass != null)
			throw new TypingError("Please define a constructor for this class in order to use it as generic", c.pos);
		cg.interfaces = [for (i in c.interfaces) switch (genericSubstituteType(ctx, c, gsubst, p, TInst(i.c, i.params))) {
			case TInst(ci, pl): {c: ci, params: pl};
			case _: throw "generic interface substitution failed";
		}];
		for (f in c.orderedFields) {
			var cf = cloneField(ctx, c, gsubst, f, lazyFields);
			cg.fields.set(cf.name, cf);
			cg.orderedFields.push(cf);
		}
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
		ctx.typeToModuleEpoch.set(Context.pathKey(path), ctx.compilationEpoch);
		TypeFunctions.addDependency(mg, c.module);
		// The module USING the instance depends on it. Without that edge nothing re-registers the instance
		// on a warm rebuild - the using module is served from the cache and the walk over its deps never
		// reaches the instance's module - so the class is still REFERENCED by the generated code but never
		// EMITTED, and the output fails at runtime with no error reported. A one-shot compile cannot see
		// this: the instance is created fresh every time and pushed onto ctx.modules right here.
		// ModuleLoader.addDependency, not the TypeFunctions one: a dependency clears only the
		// POST-PROCESSING mark, and the using module is mid-typing here. Clearing hxc's own resolve gate as
		// well re-derives signatures the bodies have already bound, which reports a duplicate
		// constructor.
		hxc.context.ModuleLoader.addDependency(ctx.currentModule != null ? ctx.currentModule : genericBuildModule, mg);
		// The instance also depends on the modules of the types it was specialized for, so one of those
		// changing marks it dirty. Without it a cached instance can be handed back after its parameter's
		// module was re-typed.
		hxc.typing.Calls.setTypeParameterDependencies(mg, params);
		genericInstanceModule = savedInstMod;
		genericBuildCtx = savedGenericCtx;
		genericBuildModule = savedGenericMod;
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
