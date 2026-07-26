package hxc.eval;

import hxc.core.Type;
import hxc.core.Define;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.eval.EvalValue;
import hxc.eval.EvalContext;
import hxc.eval.EvalPrototype;
import hxc.eval.EvalHash;
import haxe.ds.StringMap;

// Interpreter entry: registers prototypes for the loaded types, then runs an entry point.
class EvalMain {
	public static function create(isMacro:Bool, ?resources:StringMap<haxe.io.Bytes>, ?defines:Define, ?classPath:Array<String>, ?com:Context):EvalContext {
		var ctx = new EvalContext(0, isMacro, defines, classPath, com);
		if (resources != null) {
			for (name in resources.keys()) ctx.resources.set(name, resources.get(name));
		}
		EvalContext.setCtx(ctx);
		EvalStdLib.init(ctx);
		installInterfaceIsOfType(ctx);
		return ctx;
	}

	// Std.isOfType must accept interfaces (the runtime prototype chain only records superclasses), so
	// layer an interface-aware check over the base native: match walks superClass + interfaces via the
	// type cache, and any other case falls through to the original isOfType.
	static function installInterfaceIsOfType(ctx:EvalContext):Void {
		var stdKey = EvalNames.hStd();
		var list = ctx.builtins.staticBuiltins.get(stdKey);
		if (list == null) return;
		var iofHash = EvalNames.hIsOfType();
		var orig:Null<EvalValue->Array<EvalValue>->EvalValue> = null;
		var base:Null<Array<EvalValue>->EvalValue> = null;
		for (b in list) if (b.name == iofHash) switch (b.v) { case VFunction(f, _): base = f; case _: };
		if (base == null) return;
		var baseFn = base;
		list.push({name: iofHash, v: VFunction(function(a:Array<EvalValue>):EvalValue {
			var v = a.length > 0 ? a[0] : VNull;
			var t = a.length > 1 ? a[1] : VNull;
			switch ([v, t]) {
				case [VInstance(vi), VPrototype(proto)]:
					if (classHierarchyHas(ctx, vi.iproto.ppath, proto.ppath)) return VTrue;
				case _:
			}
			return baseFn(a);
		}, true)});
	}

	// True when the class at `classPath` is, extends, or implements the type at `targetPath` (walks the
	// superclass and interface graph via the type cache).
	static function classHierarchyHas(ctx:EvalContext, classPath:Int, targetPath:Int):Bool {
		if (classPath == targetPath) return true;
		return switch (ctx.typeCache.get(classPath)) {
			case TClassDecl(c):
				if (c.superClass != null && classHierarchyHas(ctx, EvalHash.pathHash(c.superClass.c.path), targetPath)) true
				else {
					var found = false;
					for (i in c.interfaces) if (classHierarchyHas(ctx, EvalHash.pathHash(i.c.path), targetPath)) { found = true; break; }
					found;
				}
			case _: false;
		};
	}

	// Enum half of applying @:native paths: rewrite each @:native constructor's name, rebuild
	// constrs/names under the new names (declaration order kept so index still matches position),
	// and rewrite path to the enum's @:native path. There is no separate filter pass, so this runs just
	// before the enum prototype is built.
	static function nativeNameOf(meta:hxc.ast.Ast.Metadata):Null<String> {
		var m = hxc.core.TypeFunctions.getMetaOpt(":native", meta);
		if (m == null) return null;
		return switch (m.params.length > 0 ? m.params[0].expr : null) {
			case EConst(CString(s, _)): s;
			case _: null;
		}
	}

	static function applyNativePathsEnum(en:TEnum):Void {
		var didChange = false;
		for (name in en.names) {
			var ef = en.constrs.get(name);
			if (ef == null) continue;
			var nn = nativeNameOf(ef.meta);
			if (nn != null) {
				ef.name = nn;
				didChange = true;
			}
		}
		if (didChange) {
			var oldNames = en.names;
			var newConstrs = new haxe.ds.StringMap<TEnumField>();
			var newNames:Array<String> = [];
			for (name in oldNames) {
				var ef = en.constrs.get(name);
				if (ef == null) continue;
				newConstrs.set(ef.name, ef);
				newNames.push(ef.name);
			}
			en.constrs = newConstrs;
			en.names = newNames;
		}
		var np = nativeNameOf(en.meta);
		if (np != null) en.path = hxc.ast.Ast.parsePath(np);
	}

	// Class half of applying @:native paths: rewrite path from @:native. Two classes may then
	// share a path (an extern and its non-extern twin); only the first is registered, so registration
	// below is first-wins per key.
	static function applyNativePathsClass(c:TClass):Void {
		var np = nativeNameOf(c.meta);
		if (np != null) c.path = hxc.ast.Ast.parsePath(np);
	}

	public static function addTypes(ctx:EvalContext, types:Array<ModuleType>, runDce:Bool = false):Void {
		// A type already cached under this path hash is skipped only when it comes from the same module.
		// One from a DIFFERENT module replaces it, and its prototypes are dropped first so they are
		// rebuilt rather than kept. Otherwise two display requests over files that both declare the same
		// type path would leave the second one running the first one's macros ("Macro not found").
		types = types.filter(function(mt) {
			var key = EvalHash.pathHash(hxc.core.TypeFunctions.tPath(mt));
			var cached = ctx.typeCache.get(key);
			if (cached != null) {
				var m1 = hxc.core.TypeFunctions.tModule(mt);
				var m2 = hxc.core.TypeFunctions.tModule(cached);
				if (m2 != null && m1 != null && m2.id == m1.id)
					return false;
			}
			ctx.instancePrototypes.remove(key);
			ctx.staticPrototypes.remove(key);
			ctx.constructors.remove(key);
			ctx.typeCache.set(key, mt);
			return true;
		});
		var delays:Array<{proto:VPrototype, fn:VPrototype->Void}> = [];
		// Register type-cache entries and enum prototypes up front.
		for (mt in types) switch (mt) {
			case TClassDecl(c):
				// An override marks each superclass from the parent up to the one declaring the field.
				for (f in c.orderedFields) if (hxc.core.TypeFunctions.hasClassFieldFlag(f, CfOverride))
					markOverride(ctx, c.superClass == null ? null : c.superClass.c, f.name);
				applyNativePathsClass(c);
				// A method only referenced as a closure never had its lazy body forced during typing;
				// type any remaining bodies now so the prototype does not hold a bodyless method (every
				// field body
				// is typed before generation).
				if (runDce && ctx.com != null) hxc.typing.TypeFields.forceClassFields(ctx.com, c);
				var key = EvalHash.pathHash(c.path);
				if (!ctx.typeCache.exists(key)) ctx.typeCache.set(key, mt);
			case TEnumDecl(en):
				applyNativePathsEnum(en);
				ctx.typeCache.set(EvalHash.pathHash(en.path), mt);
				ctx.staticPrototypes.set(EvalHash.pathHash(en.path), EvalPrototype.buildEnum(ctx, en));
			case _:
		}
		// Build a class prototype, its superclass first, so a subclass inherits the parent field layout
		// regardless of module registration order. A prototype is built for every type the filter above
		// accepted, so two same-path types in one batch end with the last one registered. The existence
		// test is only for the superclass recursion, which must not rebuild a parent that is already
		// there.
		function buildClass(c:TClass, isNew:Bool):Void {
			var key = EvalHash.pathHash(c.path);
			if (!isNew && ctx.instancePrototypes.exists(key)) return;
			if (c.superClass != null) buildClass(c.superClass.c, false);
			var iproto = EvalPrototype.buildInstance(ctx, c);
			ctx.instancePrototypes.set(key, iproto);
			if (c.path.pack.length == 0) switch (c.path.name) {
				case "String": ctx.stringPrototype = iproto;
				case "Array": ctx.arrayPrototype = iproto;
				case _:
			}
			if (c.path.pack.length == 1 && c.path.pack[0] == "eval" && c.path.name == "Vector")
				ctx.vectorPrototype = iproto;
			var r = EvalPrototype.buildStatic(ctx, c);
			ctx.staticPrototypes.set(r.proto.ppath, r.proto);
			for (d in r.delays) delays.push({proto: r.proto, fn: d});
			// Record the non-persistent initializers, which re-run when the interpreter is reused.
			if (r.nonPersistent.length > 0) ctx.staticInits.set(r.proto.ppath, {proto: r.proto, delays: r.nonPersistent});
			var ctor = EvalPrototype.makeConstructor(ctx, c);
			if (ctor != null) ctx.constructors.set(key, ctor);
		}
		for (mt in types) switch (mt) {
			case TClassDecl(c): buildClass(c, true);
			case _:
		}
		EvalPrototype.jitTypes(ctx, types);
		// Static field initializers run after every prototype is registered.
		for (d in delays) d.fn(d.proto);
	}

	static function markOverride(ctx:EvalContext, p:Null<TClass>, name:String):Bool {
		if (p == null) return false;
		if (p.fields.exists(name) || markOverride(ctx, p.superClass == null ? null : p.superClass.c, name)) {
			var key = EvalHash.pathHash(p.path);
			var names = ctx.overrides.get(key);
			if (names == null) {
				names = new Map();
				ctx.overrides.set(key, names);
			}
			names.set(name, true);
			return true;
		}
		return false;
	}

	public static function addModules(ctx:EvalContext, modules:Array<ModuleDef>, runDce:Bool = false):Void {
		var types:Array<ModuleType> = [];
		for (m in modules) for (mt in m.types) types.push(mt);
		addTypes(ctx, types, runDce);
	}

	public static function callStaticNoArgs(ctx:EvalContext, path:Path, field:String):EvalValue {
		var proto = ctx.staticPrototypes.get(EvalHash.pathHash(path));
		if (proto == null) throw "Type not found: " + path.name;
		var idx = proto.pnames.get(EvalHash.hash(field));
		if (idx == null) throw "Field not found: " + field;
		return switch (proto.pfields[idx]) {
			case VFunction(f, _): f([]);
			case v: v;
		};
	}

	// Evaluate the finalized entry expression: the call to main() plus the entry-point or
	// event-loop tail built by Finalization.getMain.
	public static function runMain(ctx:EvalContext, mainPath:Path):EvalValue {
		// It runs under the runtime lock the main thread has held since it started (Compiler.main).
		if (ctx.com == null || ctx.com.main == null)
			throw "No entry expression: Finalization.run must populate com.main before runMain";
		// The entry expression runs inside an EKEntrypoint environment, the depth the recursion limit
		// counts from; its leave position, the main call's null position, never prints.
		var entryEval = EvalContext.getEval(ctx);
		var entryEnv = EvalContext.pushEnvironment(ctx, EvalContext.createEnvInfo(true, ctx.com.main.pos, EKEntrypoint, 0, 0));
		// The expression is compiled before it runs.
		var r = try { EvalPrototype.jitWalk(ctx, ctx.com.main); EvalEmitter.eval(ctx, ctx.com.main); } catch (e:Dynamic) { entryEval.env = entryEnv.parent; throw e; };
		EvalContext.popEnvironment(ctx, entryEnv);
		return r;
	}
}
