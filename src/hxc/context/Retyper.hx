package hxc.context;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals.Path;

// hxc.context.Retyper: a module the server would otherwise SKIP because one of its dependencies went dirty
// is re-paired with its own source instead: every declaration is matched back to the cached type it
// produced, and every field's SIGNATURE is loaded again with module loading restricted to what is already
// cached (disableTypeloading). A signature that needs the dirty module cannot load and the whole attempt
// fails, which is the answer the check wanted anyway; a signature that does not means only the BODIES have
// to be typed again, and the module keeps its identity.
//
// This runs only under the Retype module-check policy (CompilationServer.setModuleCheckPolicy), which is
// experimental.
class Retyper {
	static var failMessage:Null<String> = null;

	// The message carries the print stack, outermost first; the list is built in order, so it already reads
	// outermost-first.
	static function fail(stack:Array<String>, s:String):Dynamic {
		failMessage = stack.join(" ") + ": " + s;
		throw new RetyperFail();
	}

	// The field's own hint when it has one, else the cached type converted back to syntax.
	static function pairType(th:Null<TypeHint>, t:T):TypeHint {
		if (th != null) return th;
		return {ct: hxc.core.TexprToExpr.convertType(t), pos: Position.nullPos};
	}

	// Everything the pairing loads is restricted to modules the compilation already holds; a module
	// that is not found from in here is the failure.
	static function disableTypeloading<T2>(stack:Array<String>, f:Void->T2):T2 {
		var old = ModuleLoader.loadOnlyCachedModules;
		ModuleLoader.loadOnlyCachedModules = true;
		try {
			var r = f();
			ModuleLoader.loadOnlyCachedModules = old;
			return r;
		} catch (e:Context.ContextError) {
			ModuleLoader.loadOnlyCachedModules = old;
			switch (e.kind) {
				case ModuleNotFound(path):
					return fail(stack, "Could not load [Module " + Context.sTypePath(path) + "]");
				case _:
					throw e;
			}
		} catch (e:Dynamic) {
			ModuleLoader.loadOnlyCachedModules = old;
			throw e;
		}
	}

	// A method pairs each argument and its return, a var pairs its declared type. Only the LOADING happens
	// here.
	static function pairClassField(ctx:Context, stack:Array<String>, c:TClass, cf:TClassField, cff:ClassField):Void {
		switch (cff.cffKind) {
			case FFun(fd):
				var sig = switch (TypeFunctions.follow(cf.type)) {
					case TFun(s): s;
					case _: fail(stack, "Type change");
				};
				if (fd.fArgs.length != sig.args.length) fail(stack, "Type change");
				var hints:Array<TypeHint> = [];
				for (i in 0...fd.fArgs.length) hints.push(pairType(fd.fArgs[i].type, sig.args[i].t));
				hints.push(pairType(fd.fType, sig.ret));
				disableTypeloading(stack, function() {
					for (h in hints) hxc.typing.Typeload.loadComplexType(ctx, c.params, h);
					return 0;
				});
			case FVar(th, _) | FProp(_, _, th, _):
				var h = pairType(th, cf.type);
				disableTypeloading(stack, function() return hxc.typing.Typeload.loadComplexType(ctx, c.params, h));
		}
	}

	// The heritage pairs first, then every field by name.
	static function pairClass(ctx:Context, stack:Array<String>, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		var stack = stack.concat(["[Class " + Context.sTypePath(c.path) + "]"]);
		c.restore();
		var relStack = stack.concat(["[Relations]"]);
		var hasExtends = false;
		var implementsLeft = c.interfaces.copy();
		for (fl in d.dFlags) switch (fl) {
			case HExtends(t):
				hasExtends = true;
				if (c.superClass == null) fail(relStack, "parent " + Context.sTypePath({pack: t.path.tpackage, name: t.path.tname}) + " appeared");
				disableTypeloading(relStack, function() return hxc.typing.Typeload.loadInstance(ctx, c.params, t.path, t.pos, false));
			case HImplements(t):
				if (implementsLeft.length == 0)
					fail(relStack, "interface " + Context.sTypePath({pack: t.path.tpackage, name: t.path.tname}) + " appeared");
				implementsLeft.shift();
				disableTypeloading(relStack, function() return hxc.typing.Typeload.loadInstance(ctx, c.params, t.path, t.pos, false));
			case _:
		}
		if (!hasExtends && c.superClass != null)
			fail(relStack, "parent " + Context.sTypePath(c.superClass.c.path) + " disappeared");
		if (implementsLeft.length > 0)
			fail(relStack, "interface " + Context.sTypePath(implementsLeft[0].c.path) + " disappeared");
		for (cff in d.dData) {
			var name = cff.cffName.name;
			var fstack = stack.concat(["[Field " + name + "]"]);
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			var cf = if (!isStatic && name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(name);
			if (cf == null) fail(fstack, name == "new" ? "Constructor not found" : "Field not found");
			pairClassField(ctx, fstack, c, cf, cff);
		}
	}

	// Every enum constructor's declared type is loaded again.
	static function pairEnum(ctx:Context, stack:Array<String>, en:TEnum, d:Definition<EnumFlag, Array<EnumConstructor>>):Void {
		var stack = stack.concat(["[Enum " + Context.sTypePath(en.path) + "]"]);
		for (eff in d.dData) {
			var name = eff.ecName.name;
			var fstack = stack.concat(["[Field " + name + "]"]);
			var ef = en.constrs.get(name);
			if (ef == null) fail(fstack, "Field not found");
			var h = pairType(eff.ecType, ef.type);
			disableTypeloading(fstack, function() return hxc.typing.Typeload.loadComplexType(ctx, en.params, h));
		}
	}

	static function pairTypedef(ctx:Context, stack:Array<String>, td:TDef, d:Definition<EnumFlag, TypeHint>):Void {
		var stack = stack.concat(["[Typedef " + Context.sTypePath(td.path) + "]"]);
		disableTypeloading(stack, function() return hxc.typing.Typeload.loadComplexType(ctx, td.params, d.dData));
	}

	// An abstract pairs through its IMPL class, whose fields are the abstract's own transformed the way the
	// module load transforms them.
	static function pairAbstract(ctx:Context, stack:Array<String>, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>, p:Position):Void {
		var stack = stack.concat(["[Abstract " + Context.sTypePath(a.path) + "]"]);
		var c = a.impl;
		if (c == null) return;
		c.restore();
		for (cff in ModuleLoader.abstractImplFields(ctx, c, a, d)) {
			var name = cff.cffName.name;
			var fstack = stack.concat(["[Field " + name + "]"]);
			var cf = c.statics.get(name);
			if (cf == null) fail(fstack, "Field not found");
			pairClassField(ctx, fstack, c, cf, cff);
		}
	}

	// Null when the module was successfully re-paired, else the reason it could not be.
	public static function attemptRetyping(ctx:Context, m:ModuleDef, p:Position):Null<String> {
		var stack = ["[Module " + Context.sTypePath(m.path) + "]"];
		failMessage = null;
		var savedMod = ctx.currentModule;
		var savedState = m.extra.cacheState;
		try {
			var src = ModuleLoader.moduleFileContent(ctx, m.extra.file);
			var pkg = hxc.parser.Parser.parseModuleString(src, m.extra.file, ctx.defines);
			m.extra.cacheState = MSUnknown;
			ctx.currentModule = m;
			// findType: every declaration must still name a type the module produced.
			function findType(name:String):ModuleType {
				for (mt in m.types) if (TypeFunctions.tInfos(mt).path.name == name) return mt;
				return fail(stack, "Type " + name + " not found");
			}
			for (decl in pkg.decls) switch (decl.decl) {
				case EClass(d):
					switch (findType(d.dName.name)) {
						case TClassDecl(c): pairClass(ctx, stack, c, d, p);
						case _: fail(stack, "?");
					}
					case EEnum(d):
						switch (findType(d.dName.name)) {
							case TEnumDecl(en): pairEnum(ctx, stack, en, d);
							case _: fail(stack, "?");
						}
					case ETypedef(d):
						switch (findType(d.dName.name)) {
							case TTypeDecl(td): pairTypedef(ctx, stack, td, d);
							case _: fail(stack, "?");
						}
					case EAbstract(d):
						switch (findType(d.dName.name)) {
							case TAbstractDecl(a): pairAbstract(ctx, stack, a, d, p);
							case _: fail(stack, "?");
						}
					// EImport/EUsing re-run the module's imports; anything else is skipped.
					case EImport(_) | EUsing(_) | EStatic(_):
			}
			m.extra.cacheState = MSGood;
			m.extra.time = try sys.FileSystem.stat(m.extra.file).mtime.getTime() / 1000.0 catch (_:Dynamic) m.extra.time;
			ctx.currentModule = savedMod;
			return null;
		} catch (e:RetyperFail) {
			ctx.currentModule = savedMod;
			m.extra.cacheState = savedState;
			return failMessage;
		} catch (e:Dynamic) {
			ctx.currentModule = savedMod;
			m.extra.cacheState = savedState;
			return failMessage != null ? failMessage : Std.string(e);
		}
	}
}

private class RetyperFail extends haxe.Exception {
	public function new() super("retyper fail");
}
