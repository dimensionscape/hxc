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
		var stdKey = EvalHash.hash("Std");
		var list = ctx.builtins.staticBuiltins.get(stdKey);
		if (list == null) return;
		var iofHash = EvalHash.hash("isOfType");
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
		return try {
			var m = hxc.core.TypeFunctions.getMeta(":native", meta);
			switch (m.params.length > 0 ? m.params[0].expr : null) {
				case EConst(CString(s, _)): s;
				case _: null;
			}
		} catch (_:Dynamic) null;
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

	// The reference always runs the analyzer for eval forces optimize=true), so LocalDce removes
	// statement-position expressions with no side effects before execution. hxc has no analyzer; this
	// walker reproduces the observable part: drop non-final block statements that cannot cause a side
	// effect. Var declarations stay (later statements may use them).
	static function dropPureStatements(e:TExpr):Void {
		switch (e.expr) {
			case TBlock(el):
				var out:Array<TExpr> = [];
				for (i in 0...el.length) {
					var x = el[i];
					dropPureStatements(x);
					var keep = i == el.length - 1 || x.expr.match(TVarExpr(_, _)) || hxc.typing.Typer.hasSideEffect(x);
					if (keep) out.push(x);
				}
				if (out.length != el.length) e.expr = TBlock(out);
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2) | TWhile(e1, e2, _):
				dropPureStatements(e1); dropPureStatements(e2);
			case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1) | TCast(e1, _) | TThrow(e1):
				dropPureStatements(e1);
			case TVarExpr(_, eo): if (eo != null) dropPureStatements(eo);
			case TReturn(eo): if (eo != null) dropPureStatements(eo);
			case TObjectDecl(fields): for (f in fields) dropPureStatements(f.expr);
			case TArrayDecl(el): for (x in el) dropPureStatements(x);
			case TCall(e1, el): dropPureStatements(e1); for (x in el) dropPureStatements(x);
			case TNew(_, _, el): for (x in el) dropPureStatements(x);
			case TFunction(f): dropPureStatements(f.expr);
			case TIf(e1, e2, e3): dropPureStatements(e1); dropPureStatements(e2); if (e3 != null) dropPureStatements(e3);
			case TSwitch(e1, cases, edef):
				dropPureStatements(e1);
				for (c in cases) { for (v in c.values) dropPureStatements(v); dropPureStatements(c.expr); }
				if (edef != null) dropPureStatements(edef);
			case TTry(e1, catches): dropPureStatements(e1); for (c in catches) dropPureStatements(c.expr);
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TIdent(_) | TBreak | TContinue:
		}
	}

	static function dropPureStatementsClass(c:TClass):Void {
		inline function field(cf:TClassField) if (cf.expr != null) dropPureStatements(cf.expr);
		for (cf in c.orderedFields) field(cf);
		for (cf in c.orderedStatics) field(cf);
		if (c.constructor != null) field(c.constructor);
		if (c.init != null) dropPureStatements(c.init);
	}

	public static function addTypes(ctx:EvalContext, types:Array<ModuleType>, runDce:Bool = false):Void {
		var delays:Array<{proto:VPrototype, fn:VPrototype->Void}> = [];
		// Register type-cache entries and enum prototypes up front.
		for (mt in types) switch (mt) {
			case TClassDecl(c):
				applyNativePathsClass(c);
				if (runDce) dropPureStatementsClass(c);
				var key = EvalHash.pathHash(c.path);
				if (!ctx.typeCache.exists(key)) ctx.typeCache.set(key, mt);
			case TEnumDecl(en):
				applyNativePathsEnum(en);
				ctx.typeCache.set(EvalHash.pathHash(en.path), mt);
				ctx.staticPrototypes.set(EvalHash.pathHash(en.path), EvalPrototype.buildEnum(ctx, en));
			case _:
		}
		// Build a class prototype, its superclass first, so a subclass inherits the parent field layout
		// regardless of module registration order.
		function buildClass(c:TClass):Void {
			var key = EvalHash.pathHash(c.path);
			if (ctx.instancePrototypes.exists(key)) return;
			if (c.superClass != null) buildClass(c.superClass.c);
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
			var ctor = EvalPrototype.makeConstructor(ctx, c);
			if (ctor != null) ctx.constructors.set(key, ctor);
		}
		for (mt in types) switch (mt) {
			case TClassDecl(c): buildClass(c);
			case _:
		}
		// Static field initializers run after every prototype is registered.
		for (d in delays) d.fn(d.proto);
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

	// Run every class's static __init__ before main. A static __init__ becomes the class init expression
	// which the evaluator runs at startup.
	public static function runStaticInits(ctx:EvalContext):Void {
		for (proto in ctx.staticPrototypes) {
			switch (proto.pkind) {
				case PClass(_):
					var idx = proto.pnames.get(EvalHash.key___init__);
					if (idx != null) switch (proto.pfields[idx]) {
						case VFunction(f, _): f([]);
						case _:
					}
				case _:
			}
		}
	}

	public static function runMain(ctx:EvalContext, mainPath:Path):EvalValue {
		runStaticInits(ctx);
		// A module-level `function main` has no class named after the module; it lives in the
		// synthetic <Module>_Fields_ class. Fall back to it when the module type is absent.
		var result;
		if (ctx.staticPrototypes.get(EvalHash.pathHash(mainPath)) == null) {
			var fieldsPath:Path = {pack: mainPath.pack.concat(["_" + mainPath.name]), name: mainPath.name + "_Fields_"};
			if (ctx.staticPrototypes.get(EvalHash.pathHash(fieldsPath)) != null)
				result = callStaticNoArgs(ctx, fieldsPath, "main");
			else
				result = callStaticNoArgs(ctx, mainPath, "main");
		} else {
			result = callStaticNoArgs(ctx, mainPath, "main");
		}
		EvalStdLib.processEvents();
		return result;
	}
}
