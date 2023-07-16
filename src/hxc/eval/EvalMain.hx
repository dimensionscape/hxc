package hxc.eval;

import hxc.core.Type;
import hxc.core.Globals.Path;
import hxc.eval.EvalValue;
import hxc.eval.EvalContext;
import hxc.eval.EvalPrototype;
import hxc.eval.EvalHash;

// Interpreter entry: registers prototypes for the loaded types, then runs an entry point.
class EvalMain {
	public static function create(isMacro:Bool):EvalContext {
		var ctx = new EvalContext(0, isMacro);
		EvalContext.setCtx(ctx);
		EvalStdLib.init(ctx);
		return ctx;
	}

	public static function addTypes(ctx:EvalContext, types:Array<ModuleType>):Void {
		var delays:Array<{proto:VPrototype, fn:VPrototype->Void}> = [];
		for (mt in types) {
			switch (mt) {
				case TClassDecl(c):
					ctx.typeCache.set(EvalHash.pathHash(c.path), mt);
					var iproto = EvalPrototype.buildInstance(ctx, c);
					ctx.instancePrototypes.set(EvalHash.pathHash(c.path), iproto);
					if (c.path.pack.length == 0) switch (c.path.name) {
						case "String": ctx.stringPrototype = iproto;
						case "Array": ctx.arrayPrototype = iproto;
						case _:
					}
					var r = EvalPrototype.buildStatic(ctx, c);
					ctx.staticPrototypes.set(r.proto.ppath, r.proto);
					for (d in r.delays) delays.push({proto: r.proto, fn: d});
					var ctor = EvalPrototype.makeConstructor(ctx, c);
					if (ctor != null) ctx.constructors.set(EvalHash.pathHash(c.path), ctor);
				case TEnumDecl(en):
					ctx.typeCache.set(EvalHash.pathHash(en.path), mt);
					ctx.staticPrototypes.set(EvalHash.pathHash(en.path), EvalPrototype.buildEnum(ctx, en));
				case _:
			}
		}
		// Static field initializers run after every prototype is registered.
		for (d in delays) d.fn(d.proto);
	}

	public static function addModules(ctx:EvalContext, modules:Array<ModuleDef>):Void {
		var types:Array<ModuleType> = [];
		for (m in modules) for (mt in m.types) types.push(mt);
		addTypes(ctx, types);
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

	public static function runMain(ctx:EvalContext, mainPath:Path):EvalValue {
		// A module-level `function main` has no class named after the module; it lives in the
		// synthetic <Module>_Fields_ class. Fall back to it when the module type is absent.
		if (ctx.staticPrototypes.get(EvalHash.pathHash(mainPath)) == null) {
			var fieldsPath:Path = {pack: mainPath.pack.concat(["_" + mainPath.name]), name: mainPath.name + "_Fields_"};
			if (ctx.staticPrototypes.get(EvalHash.pathHash(fieldsPath)) != null)
				return callStaticNoArgs(ctx, fieldsPath, "main");
		}
		return callStaticNoArgs(ctx, mainPath, "main");
	}
}
