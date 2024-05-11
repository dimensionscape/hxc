package hxc.typing;

// hxc.typing.CoreApi: a @:coreApi class outside a -D core_api build validates against the pristine
// core definition, loaded in a SEPARATE context whose defines are exactly core_api + sys +
// target.threaded (+ macro in the macro world) over the std path.

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypingError;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.context.ModuleLoader;

class CoreApi {
	// One core context per compilation process
	static var coreCtx:Null<Context> = null;

	public static function reset():Void coreCtx = null;

	static function coreContext(ctx:Context):Context {
		if (coreCtx != null) return coreCtx;
		// Cloned com, empty defines then CoreApi/Sys/target.threaded (+Macro in the macro context), class
		// path = std path, signature locked.
		var defines = new hxc.core.Define();
		defines.rawDefineValue("core_api", "1");
		defines.rawDefineValue("sys", "1");
		defines.rawDefineValue("target.threaded", "true");
		if (ctx.isMacro) defines.rawDefineValue("macro", "1");
		var c = new Context(ctx.stdPath.copy(), defines);
		c.stdPath = ctx.stdPath.copy();
		c.platform = ctx.platform;
		c.platformConfig = ctx.platformConfig;
		c.isMacro = ctx.isMacro;
		ModuleLoader.attach(c);
		ModuleLoader.initBasicTypes(c);
		hxc.context.DisplayJson.cache.maybeAddContextSign(c, "load_core_class");
		coreCtx = c;
		return c;
	}

	// The class path resolves in the core context (a @:native class keeps its source path).
	static function loadCoreClass(ctx:Context, c:TClass):Null<TClass> {
		var ctx2 = coreContext(ctx);
		var mt = try ctx2.getType(c.path, c.pos) catch (_:Dynamic) return null;
		return switch (mt) {
			case TClassDecl(cc):
				// The core class types fully in its own context (loading answers a typed class)
				hxc.typing.TypeFields.installAndForce(ctx2);
				cc;
			case _: null;
		};
	}

	// Structural inequality on kind: the Var payload compares field-wise (Type.enumEq on an
	// anonymous payload compares by reference on hxcpp).
	static function kindEq(k1:hxc.core.Type.FieldKind, k2:hxc.core.Type.FieldKind):Bool {
		return switch [k1, k2] {
			case [Var(v1), Var(v2)]: Type.enumEq(v1.read, v2.read) && Type.enumEq(v1.write, v2.write);
			case [Method(m1), Method(m2)]: Type.enumEq(m1, m2);
			case _: false;
		};
	}

	public static function initCoreApi(ctx:Context, c:TClass):Void {
		var ccore = loadCoreClass(ctx, c);
		if (ccore == null) return;
		if (ccore.params.length != c.params.length)
			throw new TypingError("Class must have the same number of type parameters as core type", c.pos);
		if (c.doc == null) c.doc = ccore.doc;
		function compareFields(f:TClassField, f2:TClassField):Void {
			// A constructor signature return stays an unbound monomorph until its body types; the
			// comparison holds post-typing, where both are Void, and EqCoreType refuses to bind monos, so
			// bind a loose ctor return to Void first.
			inline function bindCtorRet(cf:TClassField):Void {
				if (cf.name == "new") switch (TypeFunctions.follow(cf.type)) {
					case TFun(sig): switch (TypeFunctions.follow(sig.ret)) {
						case TMono(m) if (m.type == null): TypeUnification.doBind(m, ctx.basic.tvoid);
						case _:
					}
					case _:
				}
			}
			bindCtorRet(f);
			bindCtorRet(f2);
			var p = f2.expr == null ? c.pos : f2.expr.pos;
			try {
				TypeUnification.typeEqKind(EqCoreType,
					TypeFunctions.applyParams(ccore.params, TypeFunctions.extractParamTypes(c.params), f.type), f2.type);
			} catch (ue:hxc.core.TypeUnification.UnifyError) {
				if (Sys.getEnv("HXC_DBG_CORE") != null)
					Sys.println("[core] type-mismatch " + f.name + " core=" + hxc.core.TPrinting.sTypeStr(f.type) + " impl=" + hxc.core.TPrinting.sTypeStr(f2.type));
				ctx.addDiagnostic("Field " + f.name + " has different type than in core type", p);
			}
			if (TypeFunctions.hasClassFieldFlag(f2, CfPublic) != TypeFunctions.hasClassFieldFlag(f, CfPublic))
				throw new TypingError("Field " + f.name + " has different visibility than core type", p);
			if (f2.doc == null) f2.doc = f.doc;
			if (Sys.getEnv("HXC_DBG_CORE") != null && !kindEq(f2.kind, f.kind))
				Sys.println("[core] kind-mismatch " + f.name + " core=" + Std.string(f.kind) + " impl=" + Std.string(f2.kind));
			if (!kindEq(f2.kind, f.kind)) switch [f2.kind, f.kind] {
				case [Method(MethInline), Method(MethNormal)] | [Method(MethNormal), Method(MethInline)]:
				case _:
					throw new TypingError("Field " + f.name + " has different property access than core type", p);
			}
			switch [TypeFunctions.follow(f.type), TypeFunctions.follow(f2.type)] {
				case [TFun(s1), TFun(s2)]:
					if (s1.args.length != s2.args.length) throw new TypingError("Argument count mismatch", p);
					for (i in 0...s1.args.length)
						if (s1.args[i].name != s2.args[i].name)
							throw new TypingError("Method parameter name '" + s2.args[i].name + "' should be '" + s1.args[i].name + "'", p);
				case _:
			}
		}
		function checkFields(fcore:haxe.ds.StringMap<TClassField>, fl:haxe.ds.StringMap<TClassField>):Void {
			for (name in fcore.keys()) {
				var f = fcore.get(name);
				if (!TypeFunctions.hasClassFieldFlag(f, CfPublic)) continue;
				var f2 = fl.get(f.name);
				if (f2 == null) throw new TypingError("Missing field " + name + " required by core type", c.pos);
				compareFields(f, f2);
			}
			for (name in fl.keys()) {
				var f = fl.get(name);
				var p = f.expr == null ? c.pos : f.expr.pos;
				if (name == "__init__") continue; // Moved to init at load in the reference
				if (TypeFunctions.hasClassFieldFlag(f, CfPublic) && !TypeFunctions.hasMeta(":hack", f.meta)
					&& !fcore.exists(f.name) && !TypeFunctions.hasClassFieldFlag(f, CfOverride))
					throw new TypingError("Public field " + name + " is not part of core type", p);
			}
		}
		checkFields(ccore.fields, c.fields);
		checkFields(ccore.statics, c.statics);
		if (Sys.getEnv("HXC_DBG_CORE") != null)
			Sys.println("[core] ctor-check " + c.path.name + " core=" + (ccore.constructor == null ? "null" : (TypeFunctions.hasClassFieldFlag(ccore.constructor, CfPublic) ? "pub" : "priv")) + " impl=" + (c.constructor == null ? "null" : (TypeFunctions.hasClassFieldFlag(c.constructor, CfPublic) ? "pub" : "priv")));
		// An inherited constructor exists from class build on, so the impl side of the comparison must
		// see the super ctor; hxc synthesizes it later, so resolve through the chain.
		var implCtor = c.constructor;
		{
			var cur = c;
			while (implCtor == null && cur.superClass != null) { cur = cur.superClass.c; implCtor = cur.constructor; }
		}
		switch [ccore.constructor, implCtor] {
			case [null, null]:
			case [cf, _] if (cf != null && !TypeFunctions.hasClassFieldFlag(cf, CfPublic)):
			case [f, f2] if (f != null && f2 != null): compareFields(f, f2);
			case [null, cf] if (cf != null && !TypeFunctions.hasClassFieldFlag(cf, CfPublic)):
			case _: throw new TypingError("Constructor differs from core type", c.pos);
		}
	}
}
