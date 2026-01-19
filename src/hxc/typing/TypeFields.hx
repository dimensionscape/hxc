package hxc.typing;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.Ref;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TexprTools;
import hxc.core.WithType;
import hxc.core.TypingError;
import hxc.context.Context;
import hxc.context.Context.ContextError;
import hxc.eval.EvalExceptions.EvalRunTimeException;
import hxc.eval.EvalStdLib;
import hxc.typing.TyperContext.CurrentFun;

// Types class field bodies into expr. Field types are installed as TLazy so the first access to a
// field forces its body to type, resolving an inferred (unannotated) type before any consumer in
// another module can bind it. A final flush forces every remaining field.
class TypeFields {
	static var lazyFieldTypes:haxe.ds.ObjectMap<TClassField, T> = new haxe.ds.ObjectMap();
	// Field bodies whose typing has been attempted. A body that errors leaves expr null, so the
	// expr idempotency guard alone would let a later installAndForce pass (re-run when a body loads
	// modules on demand) re-type it and re-report its errors. Each body is typed at most once.
	static var bodyTyped:haxe.ds.ObjectMap<TClassField, Bool> = new haxe.ds.ObjectMap();
	// A field's typing is queued once, when its class is built, so a finalize (Finalization.finalize,
	// the flush of that queue) costs what is new. Re-walking every module on every call is too costly
	// with the MACRO world finalizing at each macro module load and each interpreter build over a
	// closure of a few hundred modules. HOST-EXEMPT: the host finalizes a bounded number of times and
	// skipping a host module drops its coreApi doc-copy push (which --xml output shows).
	static var finalizedModules:haxe.ds.ObjectMap<ModuleDef, Bool> = new haxe.ds.ObjectMap();
	// The extern fields whose default values have been checked (the extern check runs once per field).
	static var externDefaultsChecked:haxe.ds.ObjectMap<TClassField, Bool> = new haxe.ds.ObjectMap();

	// Per-request reset for the wait server (a fresh request re-types loaded bodies). The class
	// context's `this` is the class instance only when the class is not an abstract implementation.
	// For an abstract, `this` is the abstract's UNDERLYING type - that is what a member
	// function sees - and the impl class never appears. The one exception is an underlying type that
	// is
	// still an unbound monomorph, where the abstract itself stands in. With TInst(impl), anything
	// reading ctx.tthis for an abstract member would see `_MyAbstract.MyAbstract_Impl_` instead of
	// `Int`, and the missing-fields diagnostic, which asks about `this`, would report it verbatim.
	static function classContextThis(c:TClass):T {
		return switch (c.kind) {
			case KAbstractImpl(a):
				switch (a.thisType) {
					case TMono(r) if (r.type == null): TAbstract(a, TypeFunctions.extractParamTypes(c.params));
					case t: t;
				}
			case _: TInst(c, TypeFunctions.extractParamTypes(c.params));
		};
	}

	public static function resetPerRequest():Void {
		lazyFieldTypes = new haxe.ds.ObjectMap();
		bodyTyped = new haxe.ds.ObjectMap();
		finalizedModules = new haxe.ds.ObjectMap();
		externDefaultsChecked = new haxe.ds.ObjectMap();
		macroForced = new haxe.ds.ObjectMap();
		_forcing = [];
	}

	// The macro context inherits the display settings but requires normal typing: nothing the macro world
	// types answers a display request; the host does. hxc's display position is the pair of parser statics
	// every answer site reads (Typer, TypeFields, Typeload, ModuleLoader), so typing in the macro world
	// runs with them withdrawn, under a depth so nested entries are one scope.
	static var macroWorldDepth = 0;
	static var savedDisplayFile:Null<String> = null;
	static var savedDisplayOffset = -1;
	// While a macro module loads for a DISPLAY request (a display-mode macro load, which only forcing a
	// macro field asks for) the macro context carries the host's display settings through the load and the
	// finalize, and the restore afterwards closes the window. That is how a request inside a macro body,
	// which only the macro world types, is answered.
	public static var macroDisplayWindow = false;
	public static function enterMacroWorld(ctx:Context):Bool {
		if (!ctx.isMacro || macroDisplayWindow) return false;
		if (macroWorldDepth++ == 0) {
			savedDisplayFile = hxc.parser.Parser.displayFile;
			savedDisplayOffset = hxc.parser.Parser.displayOffset;
			hxc.parser.Parser.displayFile = null;
			hxc.parser.Parser.displayOffset = -1;
		}
		return true;
	}
	public static function leaveMacroWorld(entered:Bool):Void {
		if (!entered) return;
		if (--macroWorldDepth == 0) {
			hxc.parser.Parser.displayFile = savedDisplayFile;
			hxc.parser.Parser.displayOffset = savedDisplayOffset;
		}
	}

	public static function typeAllModules(ctx:Context):Void {
		var mw = enterMacroWorld(ctx);
		try typeAllModulesInner(ctx) catch (e:Dynamic) { leaveMacroWorld(mw); throw e; }
		leaveMacroWorld(mw);
	}

	static function typeAllModulesInner(ctx:Context):Void {
		// The raise that ended a module's build leaves the compile, and a @:build runs inside a class's own
		// PBuildClass build - never reached after it. Running every class's build macros here, after
		// resolveAll has already recorded that raise, would make a macro path that did not resolve print a
		// second error after the heritage one.
		if (ctx.declAborted) return;
		// The macro world runs them too: a @:build met there a hard error ("You cannot use @:build inside a
		// macro"). Skipping them accepted the class and let the host call a macro whose result then failed
		// to decode.
		hxc.eval.EvalMacro.runBuildMacros(ctx);
		// installAndForce is single-pass; a body it types can load more modules on demand. Repeat
		// at the top level until the module set is closed (installAndForce stays re-entrancy-safe
		// for the nested call build macros make).
		var n = -1;
		while (ctx.modules.length != n) {
			n = ctx.modules.length;
			installAndForce(ctx);
		}
		// PCheckConstraint delays run after fields are typed; a check can itself type a KExpr argument and
		// queue more checks, so drain to a fixed point.
		var guard = 0;
		while (ctx.pendingConstraintChecks.length > 0 && guard++ < 100) {
			var checks = ctx.pendingConstraintChecks;
			ctx.pendingConstraintChecks = [];
			for (f in checks) f();
		}
	}

	// Install lazy field typers for every loaded module and force them. Separate from the build
	// pre-pass so the macro interpreter can re-run this without recursing into build macros.
	// HXC_DBG_TYPETIMES: coarse split of the typing/fields bucket, which --times reports as one
	// number. Same idea as HXC_DBG_FILTERTIMES for the filter pipeline.
	public static var typeTimes:haxe.ds.StringMap<Float> = new haxe.ds.StringMap();
	public static var fieldTimes:Array<{n:String, t:Float}> = [];
	static var childStack:Array<Float> = [];
	public static var timeTyping:Bool = Sys.getEnv("HXC_DBG_TYPETIMES") != null;

	public static inline function tt<T>(name:String, f:Void->T):T {
		if (!timeTyping) return f();
		var t0 = haxe.Timer.stamp();
		var r = f();
		var prev = typeTimes.get(name);
		typeTimes.set(name, (prev == null ? 0.0 : prev) + (haxe.Timer.stamp() - t0));
		return r;
	}

	public static function dumpTypeTimes():Void {
		if (!timeTyping) return;
		var rows = [for (k in typeTimes.keys()) {name: k, t: typeTimes.get(k)}];
		rows.sort(function(a, b) return a.t < b.t ? 1 : -1);
		var o = Sys.stderr();
		hxc.eval.EvalMacro.dumpRefStats();
		hxc.core.PerfCount.dump();
		hxc.core.PerfCount.dumpExn();
		hxc.core.NotFound.dumpSites();
		fieldTimes.sort(function(a, b) return a.t < b.t ? 1 : -1);
		var tot = 0.0; for (x in fieldTimes) tot += x.t;
		o.writeString("[ttime] FIELDS n=" + fieldTimes.length + " total=" + Math.round(tot * 1000) + "ms
");
		for (i in 0...(fieldTimes.length < 12 ? fieldTimes.length : 12))
			o.writeString("[ttime]   top " + StringTools.lpad(Std.string(Math.round(fieldTimes[i].t * 1000)), " ", 6) + "ms  " + fieldTimes[i].n + "
");
		for (r in rows) o.writeString("[ttime] " + StringTools.lpad(Std.string(Math.round(r.t * 1000)), " ", 7) + "ms  " + r.name + "
");
		o.flush();
	}

	public static function installAndForce(ctx:Context):Void {
		var pending:Array<TClassField> = [];
		var i = 0;
		while (i < ctx.modules.length) {
			// A module loaded on demand after the initial resolveAll pass (e.g. through an import inside a
			// lazily loaded class) has no heritage yet; resolve it before installing and forcing bodies, or
			// a `super(...)` in one of its constructors types against a null superClass. resolveModule is
			// idempotent (processed gate).
			var mres = ctx.modules[i];
			if (ctx.isMacro && finalizedModules.exists(mres)) { i++; continue; }
			tt("resolveModule", function() { hxc.typing.TypeResolve.resolveModule(ctx, mres); return 0; });
			tt("installModuleFields", function() { installModuleFields(ctx, mres, pending); return 0; });
			i++;
		}
		// A module's context init runs BEFORE its fields type, which is what puts a wildcard import's
		// statics into the module globals in time for anything that reads them. hxc queues that work as a
		// PBuildModule delay, so the bucket is drained here, ahead of the bodies rather than with them.
		// The raise that ended a module's build leaves the compile. Recovery records it and stops that
		// module; the passes below must not run either, or PForce would force a type-parameter constraint
		// that is only followed at the end of a build that got that far, and `class M<T:C> extends Nope`
		// would print a second error after the heritage one.
		if (ctx.declAborted) return;
		tt("flush:PBuildModule", function() { ctx.flushPass(hxc.context.Context.PBuildModule); return 0; });
		// Force any field not reached on demand, then unwrap the lazy back to its concrete
		// signature so downstream consumers never see a TLazy.
		tt("forcePendingSignatures", function() {
		for (cf in pending) {
			// Under a display request a field that is not the one the cursor is in keeps its lazy, so its
			// body is typed only if something demands the type. Forcing every signature here types every
			// body, which is what dms_full_typing switches off.
			if (!ctx.displayFullTyping && !isDisplayField(cf)) continue;
			switch (cf.type) {
				case TLazy(r):
					try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e);
				case _:
			}
		}
		return 0; });
		// Bodies route through the queue here (lazy-schedule step b): registration runs newest-module-first
		// so the PREPENDING delay bucket flushes in the established module x declaration order; a body
		// typed during the flush can load more modules, which typeAllModules' outer stability loop reaches
		// on the next pass (bodyTyped/expr keep this idempotent).
		var mi = ctx.modules.length - 1;
		while (mi >= 0) {
			var m = ctx.modules[mi];
			if (ctx.isMacro) {
				if (finalizedModules.exists(m)) { mi--; continue; }
				finalizedModules.set(m, true);
			}
			ctx.delay(hxc.context.Context.PTypeField, function() {
				// Heritage must resolve before bodies force, or a `super(...)` types
				// against a null superClass. resolveModule is idempotent.
				hxc.typing.TypeResolve.resolveModule(ctx, m);
				for (mt in m.types) switch (mt) {
					// Extern classes stay in the walk: forceFieldBody itself types an
					// extern INLINE body (haxe.EnumTools) and skips true externs.
					case TClassDecl(c):
						// This bucket is the dms_full_typing branch. A display request takes instead, where only the
						// display field gets a body.
						var full = ctx.displayFullTyping;
						for (cf in c.orderedFields) if (cf.expr == null && (full || isDisplayField(cf))) forceFieldBody(ctx, c, cf);
						for (cf in c.orderedStatics) if (cf.expr == null && (full || isDisplayField(cf))) forceFieldBody(ctx, c, cf);
						if (c.constructor != null && c.constructor.expr == null
							&& (full || isDisplayField(c.constructor))) forceFieldBody(ctx, c, c.constructor);
					case _:
				}
			});
			mi--;
		}
		tt("flush:PTypeField(bodies)", function() { ctx.flushPass(hxc.context.Context.PTypeField); return 0; });
		// A field with no body never reaches typeFieldBody, so its modifier completion is checked here.
		// It runs after every body so a body's own answer wins, and after every module so a supertype
		// declared elsewhere already has its field list.
		if (hxc.parser.Parser.displayFile != null)
			for (m in ctx.modules) for (mt in m.types) switch (mt) {
				case TClassDecl(c): checkModifierDisplayForClass(ctx, c);
				case _:
			}
		// Cast-signature resolution is scheduled at PForce, so bucket must be drained here, or
		// PForce/PCheckConstraint/PFinal delays never run at all.
		tt("flush:PForce", function() { ctx.flushPass(hxc.context.Context.PForce); return 0; });
	}

	// An error that escapes the closure typing a field's body or initializer is raised again as a
	// FatalError, and that closure is forced under a delay with no handler of its own, so the error ends
	// the compile. Everything recoverable on the way - a statement, a return, a throw, a variable - was
	// caught before it could get here. A bare `static function a() new Nope();` is what escapes: it is
	// reported and the compile stops.
	static function fatalFieldError(ctx:Context, e:Dynamic):Void {
		if (Std.isOfType(e, haxe.ValueException)) {
			var inner = (cast e : haxe.ValueException).value;
			if (inner != null && inner != e) return fatalFieldError(ctx, inner);
		}
		if (Std.isOfType(e, TypingError)) {
			var te:TypingError = cast e;
			// An error escaping the field's lazy closure is re-raised as a FatalError, which is the kind
			// the diagnostics runner does not catch.
			var fe = new hxc.core.TypingError.FatalError(te.message, te.pos, te.depth, true);
			fe.callChain = te.callChain;
			throw fe;
		}
		if (Std.isOfType(e, ContextError)) {
			var ce:ContextError = cast e;
			throw new hxc.core.TypingError.FatalError(ce.message, ce.pos, ce.depth, true);
		}
		recordFieldError(ctx, e);
	}

	static function recordFieldError(ctx:Context, e:Dynamic):Void {
		// A display result is the compile's answer, not a field error.
		if (Std.isOfType(e, hxc.compiler.DisplayXml.DisplayPositions)) throw e;
		if (Std.isOfType(e, hxc.typing.Typer.JsonToplevelCompletion)) throw e;
		// A fatal error is on its way to the driver; recording it here would swallow the abort.
		if (Std.isOfType(e, hxc.core.TypingError.FatalError)) throw e;
		if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null) Sys.println("[fielderr] at " + hxc.eval.EvalMacro.debugCurPos() + " " + Std.string(e)
			+ (Std.isOfType(e, EvalRunTimeException) ? " value=" + EvalStdLib.stringOf((cast e : EvalRunTimeException).value) : "")
			+ (Std.isOfType(e, hxc.parser.ParserError) ? " " + hxc.parser.ParserError.errorMsg((cast e : hxc.parser.ParserError).msg) + " at " + Std.string((cast e : hxc.parser.ParserError).pos) : ""));
		// An intermediate `catch (e:haxe.Exception)` re-throw wraps a plain error object in a
		// ValueException; classify by the carried value or the error is silently dropped.
		if (Std.isOfType(e, haxe.ValueException)) {
			var inner = (cast e : haxe.ValueException).value;
			if (inner != null && inner != e) return recordFieldError(ctx, inner);
		}
		if (Std.isOfType(e, TypingError)) {
			var te:TypingError = cast e;
			if (te.callChain != null) ctx.addDiagnosticStack(te.callChain, te.depth)
			else addDiagnosticOnce(ctx, te.message, te.pos, te.depth);
		} else if (Std.isOfType(e, ContextError)) {
			var ce:ContextError = cast e;
			addDiagnosticOnce(ctx, ce.message, ce.pos, ce.depth);
		} else if (Std.isOfType(e, EvalRunTimeException)) {
			// A macro-time uncaught exception reports with its eval call stack, the same shape the
			// interpreter prints. A Context.error abort carries its own message and position and prints
			// plain.
			var re:EvalRunTimeException = cast e;
			var info = hxc.eval.EvalMacro.runtimeMacroError(re);
			if (info != null) {
				addDiagnosticOnce(ctx, info.message, info.pos);
				return;
			}
			ctx.addDiagnosticStack(hxc.eval.EvalMacro.uncaughtExceptionStack(re));
		} else if (Std.isOfType(e, hxc.parser.ParserError) || Std.isOfType(e, hxc.parser.LexerError)) {
			// A PARSE failure in a module this field reached is not a field error: an `Error` is recorded
			// and typing carries on, and anything else passes straight through and ends the compile where
			// it happened (the same rule the import arm in ImportCheck follows). Counting it as an
			// unresolved field would drop the message and leave the consequential "found Unknown<0>" as the
			// only thing reported.
			throw e;
		} else if (Std.isOfType(e, haxe.Exception)) {
			ctx.unresolvedFields++;
		} else {
			throw e;
		}
	}

	// Cheap stand-in for "has this module's declared field set changed since it was last swept".
	// installClassFields reads the SYNTAX field list, and a build macro edits that list, so a
	// module whose type count and declared field counts are both unchanged has nothing new to
	// install.
	static function declaredFieldShape(ctx:Context, m:ModuleDef):Int {
		var n = m.types.length;
		for (mt in m.types) switch (mt) {
			case TClassDecl(c):
				var entry = ctx.declOfType.get(Context.pathKey(c.path));
				if (entry != null) switch (entry.decl) {
					case EClass(d): n = n * 31 + d.dData.length;
					case _:
				}
			case _:
		}
		return n;
	}

	// A module's field typers belong to the module type and are installed once. hxc sweeps the whole
	// context instead, and loadMacroClass runs that sweep on every macro invocation, so every
	// already-installed module would pay for a fresh TyperContext and a full pass over its declared
	// fields again. Skipping unchanged modules keeps the sweep but drops the repeat.
	public static function installLazy(ctx:Context):Void {
		var pending:Array<TClassField> = [];
		var i = 0;
		while (i < ctx.modules.length) {
			var m = ctx.modules[i];
			var key = Context.pathKey(m.path);
			var shape = declaredFieldShape(ctx, m);
			var seen = ctx.lazyInstalled.get(key);
			if (seen == null || seen != shape) {
				installModuleFields(ctx, m, pending);
				ctx.lazyInstalled.set(key, declaredFieldShape(ctx, m));
			}
			i++;
		}
	}

	static function installModuleFields(ctx:Context, m:ModuleDef, pending:Array<TClassField>):Void {
		var mw = enterMacroWorld(ctx);
		try installModuleFieldsInner(ctx, m, pending) catch (e:Dynamic) { leaveMacroWorld(mw); throw e; }
		leaveMacroWorld(mw);
	}

	static function installModuleFieldsInner(ctx:Context, m:ModuleDef, pending:Array<TClassField>):Void {
		TypeResolve.resolveModule(ctx, m);
		for (mt in m.types) {
			switch (mt) {
				case TClassDecl(c):
					addImplicitInterfaceFields(c);
					var entry = ctx.declOfType.get(Context.pathKey(c.path));
					if (entry == null) continue;
					switch (entry.decl) {
						case EClass(d): installClassFields(ctx, c, d, m, pending);
						case _:
					}
				case _:
			}
		}
	}

	// An abstract class implementing an interface gets an implicit abstract field for each interface method
	// it does not implement, so instances resolve the field through the class type.
	public static function addImplicitInterfaceFields(c:TClass):Void {
		if (!TypeFunctions.hasClassFlag(c, CAbstract) || TypeFunctions.hasClassFlag(c, CInterface)) return;
		function classHasField(c2:TClass, name:String):Bool {
			if (c2.fields.exists(name)) return true;
			return c2.superClass != null && classHasField(c2.superClass.c, name);
		}
		function walk(intf:TClass, params:TParams):Void {
			for (imp in intf.interfaces)
				walk(imp.c, [for (x in imp.params) TypeFunctions.applyParams(intf.params, params, x)]);
			for (f in intf.orderedFields) {
				switch (f.kind) { case Method(_): case _: continue; }
				if (classHasField(c, f.name)) continue;
				var cf = TypeFunctions.copyField(f);
				cf.overloads = [];
				cf.type = TypeFunctions.applyParams(intf.params, params, f.type);
				TypeFunctions.addClassFieldFlag(cf, CfAbstract);
				c.fields.set(cf.name, cf);
				c.orderedFields.push(cf);
			}
		}
		for (imp in c.interfaces) walk(imp.c, imp.params);
	}

	static function addDiagnosticOnce(ctx:Context, message:String, pos:Position, depth:Int = 0):Void {
		for (d in ctx.diagnostics)
			if (d.message == message && d.depth == depth && d.pos.file == pos.file && d.pos.min == pos.min && d.pos.max == pos.max) return;
		ctx.addDiagnostic(message, pos, depth);
	}

	static function installClassFields(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, m:ModuleDef, pending:Array<TClassField>):Void {
		// The declaration itself did not resolve, so these fields are never bound (the class init raised
		// inside the heritage). Typing them anyway would report every member inherited from the type that
		// failed to load. See Context.declErrored.
		if (ctx.declErrored.exists(Context.pathKey(c.path))) return;
		// A @:coreApi class outside a -D core_api build queues its validation against the pristine core
		// definition (delayed to PForce; display requests skip it).
		if (Sys.getEnv("HXC_DBG_CORE") != null && TypeFunctions.hasMeta(":coreApi", c.meta)) Sys.println("[core] hook-check " + c.path.name + " core_api=" + ctx.defines.rawDefined("core_api") + " disp=" + (ctx.displaySpec != null));
		if (TypeFunctions.hasMeta(":coreApi", c.meta) && !ctx.defines.rawDefined("core_api") && ctx.displaySpec == null)
			ctx.pendingConstraintChecks.push(function() try hxc.typing.CoreApi.initCoreApi(ctx, c) catch (e:Dynamic) recordFieldError(ctx, e));
		if (TypeFunctions.hasClassFlag(c, CAbstract) && TypeFunctions.hasClassFlag(c, CFinal))
			addDiagnosticOnce(ctx, "An abstract class may not be final", c.namePos);
		if (TypeFunctions.hasClassFlag(c, CInterface) && TypeFunctions.hasClassFlag(c, CAbstract))
			addDiagnosticOnce(ctx, "An interface may not be abstract", c.namePos);
		var tctx = new TyperContext(ctx);
		tctx.curclass = c;
		tctx.typeParams = c.params;
		tctx.tthis = classContextThis(c);
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var overloadSeen = new haxe.ds.StringMap<ClassField>();
		var externChecks:Array<{cf:TClassField, fd:Func, isStatic:Bool}> = [];
		for (cff in d.dData) {
			// A field name validates like any identifier; "new" is the one allowed keyword. Runs here so
			// build-macro fields are covered. The check is skipped entirely on an extern class or an
			// @:native field - the Haxe-side name is not what gets emitted there - and reports at the whole
			// field, not at its name.
			if (cff.cffName.name != "new"
				&& !TypeFunctions.hasClassFlag(c, CExtern) && !TypeFunctions.hasMeta(":native", cff.cffMeta)) {
				var fname = cff.cffName.name;
				if (StringTools.startsWith(fname, "$"))
					addDiagnosticOnce(ctx, "Field names starting with a dollar are not allowed: \"" + fname + "\"", cff.cffPos);
				else if (!hxc.core.StringHelper.isValidIdentifier(fname))
					addDiagnosticOnce(ctx, "\"" + hxc.core.StringHelper.sEscape(fname) + "\" is not a valid field name.", cff.cffPos);
			}
			var hasStatic = false, hasOverride = false, hasDynamic = false, hasInline = false, hasAbstract = false, hasFinal = false;
			for (a in cff.cffAccess) switch (a.access) {
				case AStatic: hasStatic = true;
				case AOverride: hasOverride = true;
				case ADynamic: hasDynamic = true;
				case AInline: hasInline = true;
				case AAbstract: hasAbstract = true;
				case AFinal: hasFinal = true;
				case _:
			}
			if (hasOverride && hasStatic) addDiagnosticOnce(ctx, "Invalid modifier combination: override + static", cff.cffPos);
			if (hasDynamic && hasInline) addDiagnosticOnce(ctx, "Invalid modifier combination: dynamic + inline", cff.cffPos);
			if (hasAbstract && hasDynamic) addDiagnosticOnce(ctx, "Invalid modifier combination: abstract + dynamic", cff.cffPos);
			if (hasAbstract && hasFinal) addDiagnosticOnce(ctx, "Invalid modifier combination: abstract + final", cff.cffName.pos);
			if (hasAbstract && hasInline) addDiagnosticOnce(ctx, "Invalid modifier combination: abstract + inline", cff.cffName.pos);
			if (hasAbstract && hasStatic) addDiagnosticOnce(ctx, "Invalid modifier combination: abstract + static", cff.cffName.pos);
			if (hasAbstract) switch (cff.cffKind) {
				case FFun(fd) if (fd.fExpr != null): addDiagnosticOnce(ctx, "Abstract methods may not have an expression", cff.cffPos);
				case _:
			}
			// The final-static-method check, made from the field init's FFun arm. Three parts of it are not
			// in the access list:
			// - `@:final` metadata also makes the field final, and warns when the meta has a real position
			//   (a build macro can add one with none).
			// - an abstract's members are all static, its constructor included.
			// - the position is the `final` access, else the @:final meta, else `static`, else the whole
			//   field.
			var finalMetaPos:Null<Position> = null;
			for (m in cff.cffMeta) if (m.name == ":final" && finalMetaPos == null) finalMetaPos = m.pos;
			if ((hasFinal || finalMetaPos != null) && (hasStatic || isAbsImpl)
					&& !TypeFunctions.hasClassFlag(c, CExtern)) switch (cff.cffKind) {
				case FFun(_):
					var fp = cff.cffPos;
					var finalAcc:Null<Position> = null, staticAcc:Null<Position> = null;
					for (a in cff.cffAccess) switch (a.access) {
						case AFinal: if (finalAcc == null) finalAcc = a.pos;
						case AStatic: if (staticAcc == null) staticAcc = a.pos;
						case _:
					}
					if (finalAcc != null) fp = finalAcc;
					else if (finalMetaPos != null) fp = finalMetaPos;
					else if (staticAcc != null) fp = staticAcc;
					addDiagnosticOnce(ctx, "Invalid modifier combination: final + static", fp);
				case _:
			}
			// Binding a variable's expression opens with this, ahead of the @:value meta and of typing the
			// initializer: an interface field may not carry one at all. It is EAGER, so the bind rule
			// (which excludes every interface) does not reach it, and it reports at the INITIALIZER rather
			// than at the field.
			switch (cff.cffKind) {
				case FVar(_, eo) | FProp(_, _, _, eo) if (eo != null
						&& TypeFunctions.hasClassFlag(c, CInterface)):
					addDiagnosticOnce(ctx, "Initialization on field of interface", eo.pos);
				case _:
			}
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			if (isAbsImpl && !isStatic && cff.cffName.name != "new") isStatic = true;
			var isOverload = false;
			for (a in cff.cffAccess) if (a.access == AOverload) isOverload = true;
			if (isOverload) switch (cff.cffKind) {
				case FFun(fd):
					var key = (isStatic ? "s:" : "i:") + cff.cffName.name + ":" + [for (a in fd.fArgs) a.type == null ? "" : hxc.ast.Ast.Printer.sComplexType("", a.type.ct)].join(",");
					var previous = overloadSeen.get(key);
					if (previous != null) {
						addDiagnosticOnce(ctx, "Another overloaded field of same signature was already declared : " + cff.cffName.name, previous.cffPos);
						addDiagnosticOnce(ctx, "... The second field is declared here", cff.cffPos, 1);
					} else overloadSeen.set(key, cff);
				case _:
			}
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(cff.cffName.name);
			if (cf == null) continue;
			// A duplicate declaration was reported and never added, so it declares no field; pairing it by
			// name hands it the field it merely collided with.
			if (ctx.droppedFieldDecls.exists(cff)) continue;
			if (hasAbstract && !TypeFunctions.hasClassFlag(c, CAbstract)
				&& !TypeFunctions.hasClassFlag(c, CInterface) && !hasStatic && !hasFinal && !hasInline) {
				addDiagnosticOnce(ctx, "This class should be declared abstract because it has at least one abstract field", c.namePos);
				addDiagnosticOnce(ctx, "First abstract field was here", cff.cffName.pos, 1);
				TypeFunctions.addClassFlag(c, CAbstract);
			}
			switch (cff.cffKind) {
				case FVar(_, null) if (isStatic && TypeFunctions.hasClassFieldFlag(cf, CfFinal)
					&& !TypeFunctions.hasClassFlag(c, CExtern)
					&& !TypeFunctions.hasClassFieldFlag(cf, CfExtern)):
					addDiagnosticOnce(ctx, "Static final variable must be initialized", cff.cffPos);
				case _:
			}
			if ((TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) && cff.cffName.name != "__init__") {
				switch (cff.cffKind) {
					case FFun(fd): externChecks.push({cf: cf, fd: fd, isStatic: isStatic});
					case _:
				}
				continue;
			}
			if (!hasFieldBody(cff)) continue;
			installField(ctx, tctx, m, cf, cff, isStatic);
			pending.push(cf);
		}
		// Each extern function's verify_extern into PTypeField, and drains a bucket last-in first-out:
		// the field declared last reports its default-value verdict first.
		externChecks.reverse();
		for (x in externChecks) checkExternDefaults(ctx, tctx, x.cf, x.fd, x.isStatic);
	}

	/**
	    Every field of a @:coreType abstract may go without an expression: each is a declaration the target
	    implements natively.
	*/
	static function isCoreTypeAbstractField(c:TClass):Bool {
		return switch (c.kind) {
			case KAbstractImpl(a): TypeFunctions.hasMeta(":coreType", a.meta);
			case _: false;
		};
	}

	static function hasFieldBody(cff:ClassField):Bool {
		return switch (cff.cffKind) {
			case FVar(_, eo) | FProp(_, _, _, eo): eo != null;
			case FFun(fd): fd.fExpr != null;
		};
	}

	public static function fieldHasSyntaxBody(ctx:Context, c:TClass, cf:TClassField):Bool {
		var cff = findFieldDecl(ctx, c, cf);
		return cff != null && hasFieldBody(cff);
	}

	// A macro function is typed only in the macro world; in the host (non-macro) context its body is
	// discarded and it is invoked through the macro interpreter. Its body must not be host-typed (it
	// references haxe.macro.* identifiers that resolve only under `macro`).
	static function skipMacroBodyInHost(ctx:Context, cf:TClassField):Bool {
		return !ctx.isMacro && cf.kind.match(Method(MethMacro));
	}

	// Fields already put through the macro world by the rule above. The host reaches a given macro
	// field several times (once per pass that forces it), and the load is not free.
	static var macroForced:haxe.ds.ObjectMap<TClassField, Bool> = new haxe.ds.ObjectMap();

	// Forcing a macro field. The error it raises is swallowed only in a DISPLAY run, where answering the
	// request is the point.
	static function forceMacroFieldInMacroWorld(ctx:Context, c:TClass, cf:TClassField):Void {
		if (macroForced.exists(cf)) return;
		macroForced.set(cf, true);
		if (c.module == null) return;
		var isDisplay = hxc.parser.Parser.displayFile != null;
		// The declaring module's path, not the class's: a class whose name differs from its module file
		// (common in display requests) is not loadable by its own path.
		try hxc.eval.EvalMacro.loadMacroClass(ctx, c.path, cf.name, false, c.module.path, null, cf.pos, true)
		catch (e:hxc.core.TypingError) { if (!isDisplay) throw e; }
		catch (e:hxc.context.Context.ContextError) { if (!isDisplay) throw e; }
	}

	static function installField(ctx:Context, tctx:TyperContext, m:ModuleDef, cf:TClassField, cff:ClassField, isStatic:Bool):Void {
		// Idempotent: a field already lazy or already typed is left alone so typeAllModules can
		// be re-run to pick up modules loaded on demand.
		switch (cf.type) { case TLazy(_): return; case _: }
		if (cf.expr != null) return;
		// A body that already ran (successfully or with an error) is not re-typed on later passes.
		if (bodyTyped.exists(cf)) return;
		if (skipMacroBodyInHost(ctx, cf)) {
			// A macro field holding the display position is FORCED through the macro world, which is the
			// only place its body can type (a display-mode macro load). A typing error there is swallowed;
			// a display answer is not.
			if (hxc.parser.Parser.displayFile != null && cff != null && Typer.atDisplayPos(cff.cffPos)
					&& tctx.curclass != null) {
				// The declaring module's path, not the class's: a class whose name differs from its module file
				// (common in display requests) is not loadable by its own path.
				try hxc.eval.EvalMacro.loadMacroClass(ctx, tctx.curclass.path, cf.name, false, m.path, null, null, true)
				catch (_:hxc.core.TypingError) {}
				catch (_:hxc.context.Context.ContextError) {}
			}
			return;
		}
		var sigType = cf.type;
		lazyFieldTypes.set(cf, sigType);
		var r = new Ref(LAvailable(sigType));
		var force = function():T {
			for (f in _forcing) if (f == cf) return sigType;
			// Re-entry while typing returns the resolved signature, breaking cycles.
			r.set(LProcessing(function() return sigType));
			cf.type = sigType;
			_forcing.push(cf);
			var savedMod = ctx.currentModule;
			ctx.currentModule = m;
			try {
				if (timeTyping) {
					// EXCLUSIVE time: forcing one body can force others, and charging that nested work
					// to the outer field makes whichever field happens to be first look like the whole
					// compile. Each frame accumulates its children, and subtracts them on the way out.
					var _nm = (tctx.curclass != null ? tctx.curclass.path.name : "?") + "." + cf.name;
					childStack.push(0.0);
					var _t0 = haxe.Timer.stamp();
					typeFieldBody(tctx, cf, cff, isStatic, sigType);
					var _el = haxe.Timer.stamp() - _t0;
					var _kids = childStack.pop();
					if (childStack.length > 0) childStack[childStack.length - 1] += _el;
					fieldTimes.push({n: _nm, t: _el - _kids});
				} else typeFieldBody(tctx, cf, cff, isStatic, sigType);
			} catch (e:Dynamic) fatalFieldError(ctx, e);
			ctx.currentModule = savedMod;
			_forcing.remove(cf);
			r.set(LAvailable(sigType));
			return sigType;
		};
		r.set(LWait(force));
		cf.type = TLazy(r);
	}

	public static function fieldCallType(cf:TClassField):T {
		return switch (cf.type) {
			case TLazy(_):
				var t = lazyFieldTypes.get(cf);
				t == null ? cf.type : t;
			case _:
				cf.type;
		}
	}

	// Force the field bodies of a single class whose fields were just rewritten by a @:build macro.
	// A full installAndForce per build is O(builds x modules) and re-enters through lazy typing; this
	// types only the rewritten class, so the cost stays proportional to the fields actually added.
	public static function forceClassFields(ctx:Context, c:TClass, skipMemberVars:Bool = false):Void {
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return;
		var d = switch (entry.decl) { case EClass(dd): dd; case _: return; };
		var tctx = new TyperContext(ctx);
		tctx.curclass = c;
		tctx.typeParams = c.params;
		tctx.tthis = classContextThis(c);
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var savedMod = ctx.currentModule;
		ctx.currentModule = c.module;
		for (cff in d.dData) {
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			if (isAbsImpl && !isStatic && cff.cffName.name != "new") isStatic = true;
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(cff.cffName.name);
			if (cf == null || cf.expr != null) continue;
			// A duplicate declaration was reported and never added, so it declares no field; pairing it by
			// name hands it the field it merely collided with.
			if (ctx.droppedFieldDecls.exists(cff)) continue;
			// A member var with a null expr after filters had its initializer moved into
			// the constructor by patch_constructors; re-typing it would rebuild the raw init
			// without the filter pipeline.
			if (skipMemberVars && !isStatic && cf.kind.match(Var(_))) continue;
			if (!hasFieldBody(cff)) continue;
			if ((TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) && cff.cffName.name != "__init__") continue;
			if (skipMacroBodyInHost(ctx, cf)) continue;
			switch (cf.type) { case TLazy(r): try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e); case _: }
			try {
				typeFieldBody(tctx, cf, cff, isStatic, cf.type);
			} catch (e:Dynamic) fatalFieldError(ctx, e);
		}
		ctx.currentModule = savedMod;
	}

	static var _forcing:Array<TClassField> = [];

	// A field whose body is currently being forced/typed: reading it returns the in-progress signature (its
	// real, still-inferred return mono), as a lazy type still in progress does.
	public static function isForcing(cf:TClassField):Bool {
		for (f in _forcing) if (f == cf) return true;
		return false;
	}

	// Type a single field body on demand. Inline expansion needs a callee body that may not be
	// installed yet (its module is processed later, or loaded on demand); the owning class is known
	// from the call site, so locate the syntactic field and run its body typing here. isDisplayField:
	// the field whose declaration range holds the cursor, in the display file. pos is the whole
	// declaration, so the range test is an enclosed-in check.
	static function isDisplayField(cf:TClassField):Bool {
		var off = hxc.parser.Parser.displayOffset;
		if (hxc.parser.Parser.displayFile == null || off < 0) return false;
		var p = cf.pos;
		if (p == null || !hxc.parser.Parser.matchesDisplayFile(p.file)) return false;
		return p.min <= off && p.max >= off;
	}

	public static function forceFieldBody(ctx:Context, c:TClass, cf:TClassField):Void {
		var mw = enterMacroWorld(ctx);
		try forceFieldBodyInner(ctx, c, cf) catch (e:Dynamic) { leaveMacroWorld(mw); throw e; }
		leaveMacroWorld(mw);
	}

	static function forceFieldBodyInner(ctx:Context, c:TClass, cf:TClassField):Void {
		if (cf.expr != null) return;
		// Same reason as installClassFields: the declaration never resolved, so there is no body to type
		// here. The filters reach this path directly, so guarding the install site alone is not enough.
		if (ctx.declErrored.exists(Context.pathKey(c.path))) return;
		if (bodyTyped.exists(cf)) return;
		switch (cf.type) {
			case TLazy(r):
				try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e);
				if (cf.expr != null) return;
			case _:
		}
		// Re-entry on the same field returns its current (still-open) signature, as a lazy type still in
		// progress does. A different field is forced normally even when nested, so an inline callee's
		// return type is inferred before its result is consumed by the caller.
		for (f in _forcing) if (f == cf) return;
		var cff = findFieldDecl(ctx, c, cf);
		if (cff == null) {
			if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null) Sys.println("[fforce] no decl for " + c.path.name + "." + cf.name);
			return;
		}
		var isInlineField = switch (cf.kind) { case Method(MethInline) | Var({read: AccInline}): true; case _: false; };
		// The bind rule - whether this field's body is typed at all:
		// ((not (class extern || field extern) || inline) && not abstract-method && not interface)
		// || it is __init__
		var isExternish = TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern);
		var isAbstractMethod = false;
		for (a in cff.cffAccess) if (a.access == AAbstract) isAbstractMethod = true;
		var doBind = (((!isExternish || isInlineField) && !isAbstractMethod && !TypeFunctions.hasClassFlag(c, CInterface))
			|| cf.name == "__init__");
		// A macro field in the host is not simply left untyped, it is DIVERTED to the macro world, which
		// loads it there - the only place its body can type. That load is where a macro nothing calls still
		// reports a broken body, and where a macro with no body at all reports having none. Returning early
		// would mean neither is ever seen: the guard below suppresses the host's own complaint (correctly,
		// the host does not type this body), so nothing would be left to report it.
		if (skipMacroBodyInHost(ctx, cf)) {
			forceMacroFieldInMacroWorld(ctx, c, cf);
			return;
		}
		if (!hasFieldBody(cff)) {
			// A method that requires binding but has no body is an error. The check must follow all binding
			// exclusions:
			// - Externs, interface methods, and abstract methods are not bound.
			// - Abstract checks exempt a @:multiType _new and bodyless fields allowed by allowsNoExpr.
			// @:coreType defaults to allowing them; its later @:noExpr tag is not yet available here.
			// Non-coreType bodyless fields are removed before this pass.
			// - Host-context macro fields bind in the macro world, whose #if macro branch contains their
			// bodies.
			// For display requests, treat the missing body as an empty block so typing can answer.
			if (doBind && cff.cffKind.match(FFun(_))
				&& !isCoreTypeAbstractField(c)
				&& !skipMacroBodyInHost(ctx, cf)
				&& !ctx.ignoreError()) {
				var isMemberOfAbstractClass = TypeFunctions.hasClassFlag(c, CAbstract)
					&& !TypeFunctions.hasClassFieldFlag(cf, CfStatic) && cf.name != "__init__";
				// This is raised from inside function typing, which is what the field's lazy closure holds, so
				// it is re-raised as a FatalError - the one error class the diagnostics runner does not catch.
				// A diagnostics request that meets it gets a plain message at exit 1 and no report.
				throw new hxc.core.TypingError.FatalError(isMemberOfAbstractClass
					? "Function body or abstract modifier required" : "Function body required", cff.cffPos, 0, true);
			}
			return;
		}
		if (!doBind) return;
		if (skipMacroBodyInHost(ctx, cf)) return;
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var isStatic = false;
		for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
		if (isAbsImpl && !isStatic && cff.cffName.name != "new") isStatic = true;
		var tctx = new TyperContext(ctx);
		tctx.curclass = c;
		tctx.typeParams = c.params;
		tctx.tthis = classContextThis(c);
		_forcing.push(cf);
		var savedMod = ctx.currentModule;
		ctx.currentModule = c.module;
		try {
			typeFieldBody(tctx, cf, cff, isStatic, cf.type);
		} catch (e:Dynamic) fatalFieldError(ctx, e);
		ctx.currentModule = savedMod;
		_forcing.remove(cf);
	}

	// The scan below is O(declared fields of the class) and runs once per FORCE attempt, not once
	// per field: a field with no body is re-scanned every time something asks for it, only to
	// rediscover it has none. 58747 calls and 3.15M iterations on the unit suite. The result
	// depends on the class's syntax field list, and a build macro that edits that list goes
	// through rebuildFields, which registers new TClassField instances, so keying the memo on the
	// field object invalidates exactly the entries that could have changed.
	static function findFieldDecl(ctx:Context, c:TClass, cf:TClassField):Null<ClassField> {
		var hit = ctx.fieldDeclCache.get(cf);
		if (hit != null) return hit.d;
		var d = findFieldDeclUncached(ctx, c, cf);
		ctx.fieldDeclCache.set(cf, {d: d});
		return d;
	}

	static function findFieldDeclUncached(ctx:Context, c:TClass, cf:TClassField):Null<ClassField> {
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return null;
		var d = switch (entry.decl) { case EClass(dd): dd; case _: return null; };
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var nameSeen = new haxe.ds.StringMap<Int>();
		for (f in d.dData) {
			var fStatic = false;
			for (a in f.cffAccess) if (a.access == AStatic) fStatic = true;
			if (isAbsImpl && !fStatic && f.cffName.name != "new") fStatic = true;
			var base = if (!fStatic && f.cffName.name == "new") c.constructor
				else (fStatic ? c.statics : c.fields).get(f.cffName.name);
			if (base == null) continue;
			var key = (fStatic ? "s:" : "i:") + f.cffName.name;
			var occ = nameSeen.exists(key) ? nameSeen.get(key) : 0;
			nameSeen.set(key, occ + 1);
			// A second constructor with no overload slot was reported as a duplicate and dropped,
			// so it is not the declaration of any field.
			if (f.cffName.name == "new" && occ > 0 && base.overloads.length < occ) continue;
			var target = if (occ > 0 && base.overloads.length >= occ) base.overloads[base.overloads.length - occ] else base;
			if (target == cf) return f;
		}
		return null;
	}

	// The typer pass, as far as instance building needs it: being past PBuildClass is true while a body is
	// being typed, and that is when a class named by an instance builds on the spot. hxc has no pass
	// counter; this counts the open bodies instead.
	public static var bodyDepth:Int = 0;

	static function typeFieldBody(tctx:TyperContext, cf:TClassField, cff:ClassField, isStatic:Bool, sigType:T):Void {
		bodyDepth++;
		try typeFieldBodyInner(tctx, cf, cff, isStatic, sigType) catch (e:Dynamic) { bodyDepth--; throw e; }
		bodyDepth--;
	}

	static function typeFieldBodyInner(tctx:TyperContext, cf:TClassField, cff:ClassField, isStatic:Bool, sigType:T):Void {
		bodyTyped.set(cf, true);
		var restore = Typer.saveLocals(tctx);
		// A field body starts with no locals in scope. Lazy typing can force one body while another is
		// still open (its type is queried from the first body), so start clean and let restore() give
		// the caller its locals back; otherwise a stale local shadows a same-named member.
		tctx.locals = new haxe.ds.StringMap();
		var oldField = tctx.curfield;
		var oldFun = tctx.curfun;
		var oldParams = tctx.typeParams;
		// A static field sees only its own type params; the class params are out of scope. The exception is
		// an abstract member (CfImpl): its body references the abstract's own type params (via the
		// underlying `this` type), so put those in scope.
		var abstractParams = switch (tctx.curclass.kind) { case KAbstractImpl(a): a.params; case _: null; };
		var isAbsImpl = abstractParams != null;
		var isAbstractMember = isAbsImpl && TypeFunctions.hasClassFieldFlag(cf, CfImpl);
		tctx.curfield = cf;
		tctx.curfun = isAbstractMember ? FunMemberAbstract : (isStatic ? FunStatic : (cff.cffName.name == "new" ? FunConstructor : FunMember));
		if (isAbstractMember) tctx.typeParams = abstractParams;
		else if (isStatic && !isAbsImpl) tctx.typeParams = [];
		// A member body sees its class's params regardless of what the shared context currently holds: a
		// lazy force fired from inside a static body would otherwise type this member with the static's
		// empty params (type params are derived per field from the class).
		else tctx.typeParams = tctx.curclass.params;
		// The method's own type parameters are in scope within its body, PREPENDED so a method parameter
		// shadowing a class parameter of the same name wins the first-match lookup (Vector.copy<T> on
		// Vector<T>).
		if (cf.params.length > 0) tctx.typeParams = cf.params.concat(tctx.typeParams);
		function cleanup() {
			tctx.curfield = oldField;
			tctx.curfun = oldFun;
			tctx.typeParams = oldParams;
			restore();
		}
		try {
			switch (cff.cffKind) {
				case FVar(_, eo):
					if (eo != null) {
						setValueMeta(cf, [eo]);
						// A field initializer is outside any function (a return in it reports).
						tctx.inFunction = false;
						// An initializer on an extern variable (non-static, non-inline, or not a constant) or on a
						// property that is no physical variable is reported at the field, once (maybe_display_error),
						// before the initializer is typed.
						var externVar = TypeFunctions.hasClassFlag(tctx.curclass, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern);
						var isInlineVar = cf.kind.match(Var({read: AccInline}));
						var initComplaint:Null<String> = if (externVar && !isStatic) "on extern non-static variable"
							else if (externVar && !isInlineVar) "on extern non-inline variable"
							else if (!externVar && !TypeFunctions.isPhysicalField(cf)) "on field that is not a real variable"
							else null;
						if (initComplaint != null) tctx.com.addDiagnostic(initComplaint, cff.cffPos);
						var te = typeVarInitializer(tctx, sigType, eo, hasVarHint(cff.cffKind), cff.cffPos);
						// require_constant_expression, the extern inline variable's arm, at the field.
						if (externVar && isStatic && isInlineVar && initComplaint == null
								&& hxc.optimization.Optimizer.makeConstantExpression(tctx, te) == null)
							tctx.com.addDiagnostic("Extern variable initialization must be a constant value", cff.cffPos);
						tctx.inFunction = true;
						if (!isStatic) checkThisInVarInit(tctx, te);
						var checked = checkCast(te, sigType);
						// An inline var stores its FOLDED constant (224 | (1<<30) becomes the int) so an
						// inline read substitutes a matchable constant. (require_constant_expression on
						// inline vars).
						if (cf.kind.match(Var({read: AccInline}))) {
							var folded = hxc.optimization.Optimizer.makeConstantExpression(tctx, checked);
							if (folded != null) checked = folded;
							// An enum abstract member's value must be of the underlying type: the
							// synthesized cast unwraps and the value unifies against thisType, reported over
							// the initializer's own extent (the synthesized cast carries the value's
							// position). (KAbstractImpl, CfEnum).
							switch (tctx.curclass != null ? tctx.curclass.kind : KNormal) {
								case KAbstractImpl(a) if (a.isEnum && TypeFunctions.hasClassFieldFlag(cf, CfEnum)):
									// Unifies the member's DECLARED type with the abstract itself, at the field: `var A:Int =
									// 1` in `enum abstract E(Int)` is `Int should be E`. It was trivially true while every
									// member's type was overwritten with the abstract; it speaks now that a hint is kept.
									try hxc.core.TypeUnification.unifyDefault(sigType, TAbstract(a, [for (_ in a.params) TypeFunctions.mkMono()]))
									catch (ue:hxc.core.TypeUnification.UnifyError)
										tctx.com.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(ue.errors), cf.pos);
									var e1 = switch (checked.expr) { case TCast(inner, null): inner; case _: checked; };
									try hxc.core.TypeUnification.unifyDefault(e1.type, a.thisType)
									catch (ue:hxc.core.TypeUnification.UnifyError)
										tctx.com.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(ue.errors), eo.pos);
								case _:
							}
						}
						cf.expr = checked;
					}
				case FFun(fd):
					var sig = switch (TypeFunctions.follow(sigType)) { case TFun(s): s; case _: null; };
					// A constructor never returns a value: its body types in void context (FunConstructor).
					// Otherwise its inferred return monomorph can stay open (a bare `return;` keeps it
					// non-Void), and the final-return insertion then appends a value return to a void C++
					// constructor.
					var ret = tctx.curfun.match(FunConstructor) ? tctx.t.tvoid : (sig != null ? sig.ret : tctx.t.tvoid);
					var args = buildArgs(tctx, sig, fd);
					// Binding a method takes the function body position, falling back to the field position
					// (cffPos) only for an abstract/no-body method. Function typing uses it for the synthesized
					// `var this = this` so a macro-built method's _gthis capture lands on the body line,
					// not the decl.
					var funcPos = fd.fExpr != null ? fd.fExpr.pos : cff.cffPos;
					// ExprPreprocessing runs over the body of a field in the DISPLAY file, unless the parser
					// already resumed (hadResume). It runs once per field - a local function is not in display
					// mode outside the display subject - so the verdict belongs here rather than in typeFunction,
					// where a display answer thrown out of a nested body would leave it behind. The pass's VERDICT
					// and its marked NODE are consumed; the annotated TREE is not. Feeding the typer that tree
					// would mean every arm that inspects its children structurally has to read through the wrapper
					// the way the for-loop and matcher handling do, and hxc has a long tail of those.
					if (fd.fExpr != null && hxc.parser.Parser.displayFile != null && !hxc.parser.Parser.hadResume
						&& hxc.typing.ExprPreprocessing.inDisplayFile(fd.fExpr.pos))
						Typer.exprDisplayOff = hxc.typing.ExprPreprocessing.process(fd.fExpr) == null;
					var tf = Typer.typeFunction(tctx, args, ret, tctx.curfun, fd.fExpr, funcPos);
					if (!isStatic && cff.cffName.name != "new") TypeloadCheck.checkOverriding(tctx.com, tctx.curclass, cf);
					if (cf.kind.match(Method(MethInline))) {
						function staticLocalPos(e:TExpr):Null<Position> {
							return switch (e.expr) {
								case TVarExpr(v, _) if (TypeFunctions.hasVarFlag(v, VStatic)): v.pos;
								case _:
									var found:Null<Position> = null;
									TexprTools.iter(function(child) if (found == null) found = staticLocalPos(child), e);
									found;
							};
						}
						var staticPos = staticLocalPos(tf.expr);
						if (staticPos != null) throw new TypingError("Inline functions cannot have static locals", staticPos);
					}
					tf.expr = localStatics(tctx, tf.expr);
					// The TFunction node itself also carries the body position; genxml's line attribute
					// reads it.
					cf.expr = TypeFunctions.mk(TFunction(tf), sigType, funcPos);
				case FProp(_, _, _, eo):
					// A physical property (e.g. (default,null)) can carry an initializer, bound to expr
					// exactly like a variable; the accessors are typed as their own get_/set_ methods.
					if (eo != null) {
						setValueMeta(cf, [eo]);
						// An initializer on an extern variable (non-static, non-inline, or not a constant) or on a
						// property that is no physical variable is reported at the field, once (maybe_display_error),
						// before the initializer is typed.
						var externVar = TypeFunctions.hasClassFlag(tctx.curclass, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern);
						var isInlineVar = cf.kind.match(Var({read: AccInline}));
						var initComplaint:Null<String> = if (externVar && !isStatic) "on extern non-static variable"
							else if (externVar && !isInlineVar) "on extern non-inline variable"
							else if (!externVar && !TypeFunctions.isPhysicalField(cf)) "on field that is not a real variable"
							else null;
						if (initComplaint != null) tctx.com.addDiagnostic(initComplaint, cff.cffPos);
						var te = typeVarInitializer(tctx, sigType, eo, hasVarHint(cff.cffKind), cff.cffPos);
						// require_constant_expression, the extern inline variable's arm, at the field.
						if (externVar && isStatic && isInlineVar && initComplaint == null
								&& hxc.optimization.Optimizer.makeConstantExpression(tctx, te) == null)
							tctx.com.addDiagnostic("Extern variable initialization must be a constant value", cff.cffPos);
						if (!isStatic) checkThisInVarInit(tctx, te);
						cf.expr = checkCast(te, sigType);
					}
			}
		} catch (e:haxe.Exception) {
			cleanup();
			throw e;
		}
		cleanup();
		checkFieldDisplay(tctx.com, tctx.curclass, cff);
	}

	// A body-less field (a plain `var`) never reaches typeFieldBody, so its declaration is
	// checked once the class's bodies have all run.
	static function checkModifierDisplayForClass(ctx:Context, c:TClass):Void {
		if (hxc.parser.Parser.displayFile == null) return;
		// A field with no expression to bind (an extern or interface method, an abstract declaration)
		// still answers the display from its own name. maybe_display_field only fires when the cursor is
		// on that name.
		inline function nameDisplay(cf:TClassField, isCtor:Bool):Void {
			if (Typer.atDisplayPos(cf.namePos)) Typer.displayClassField(c, isCtor, cf, cf.namePos);
		}
		for (cf in c.orderedFields) nameDisplay(cf, false);
		for (cf in c.orderedStatics) nameDisplay(cf, false);
		if (c.constructor != null) nameDisplay(c.constructor, true);
		if (Typer.fieldCompletionFound != null) return;
		var entry = ctx.declOfType.get(hxc.context.Context.pathKey(c.path));
		if (entry == null) return;
		switch (entry.decl) {
			case EClass(d):
				for (cff in d.dData) checkFieldDisplay(ctx, c, cff);
			case _:
		}
	}

	// checkFieldDisplay runs after the body binds, so anything the body itself answered wins. A cursor
	// anywhere in an `override` field then completes on the fields this class could still override,
	// which is every member field of a supertype it does not already declare.
	static function checkFieldDisplay(ctx:Context, c:TClass, cff:ClassField):Void {
		if (hxc.parser.Parser.displayFile == null || !Typer.displayToplevel && !hxc.parser.Parser.displayCompletionMode) return;
		if (Typer.fieldCompletionFound != null) return;
		if (!Typer.atDisplayPos(cff.cffPos)) return;
		var isOverride = false;
		for (a in cff.cffAccess) if (a.access == AOverride) isOverride = true;
		if (!isOverride) return;
		var own = new haxe.ds.StringMap<Bool>();
		for (f in c.orderedFields) own.set(f.name, true);
		var items:Array<hxc.compiler.DisplayXml.DisplayField> = [];
		var entries = [];
		var seen = new haxe.ds.StringMap<Bool>();
		var sup = c.superClass;
		while (sup != null) {
			for (f in sup.c.orderedFields) {
				if (own.exists(f.name) || seen.exists(f.name)) continue;
				seen.set(f.name, true);
				var t = TypeFunctions.applyParams(sup.c.params, sup.params, f.type);
				items.push({
					kind: f.kind.match(Method(_)) ? "method" : "var",
					name: f.name,
					type: hxc.core.TPrinting.sTypeStr(t),
					doc: Ast.genDocTextOpt(f.doc)
				});
				// The origin is the PARENT that declares the field.
				entries.push({cf: f, scope: hxc.core.Type.ClassFieldScope.CFSMember, originClass: sup.c,
					originAnon: null, builtIn: false, fromParent: true});
			}
			sup = sup.c.superClass;
		}
		Typer.fieldCompletionFound = items;
		// The JSON answer is CROverride over the same list, with the field name being written as its
		// subject.
		Typer.jsonFieldCompletion = {entries: entries, receiver: null, insertPos: cff.cffName.pos,
			kind: 12, subjectName: cff.cffName.name, subjectPos: cff.cffName.pos};
	}

	// A member variable initializer cannot reach this (issue #1958); the first occurrence reports and the
	// walk stops. .
	static function checkThisInVarInit(tctx:TyperContext, e:TExpr):Void {
		var found = false;
		function check(e2:TExpr):Void {
			if (found) return;
			switch (e2.expr) {
				case TConst(TThis):
					tctx.com.addDiagnostic("Cannot access this or other member field in variable initialization", e2.pos);
					found = true;
				case TLocal(v) if (tctx.vthis != null && v == tctx.vthis):
					tctx.com.addDiagnostic("Cannot access this or other member field in variable initialization", e2.pos);
					found = true;
				case _:
					hxc.core.TexprTools.iter(check, e2);
			}
		}
		check(e);
	}

	// An abstract's underlying type must not cycle back through other abstracts. Runs after resolution so
	// every thisType is loaded (delayed to PForce).
	public static function checkRecursiveAbstracts(ctx:Context):Void {
		var reported = new Map<String, Bool>();
		for (mt in ctx.types) switch (mt) {
			case TAbstractDecl(a) if (a.thisType != null && !TypeFunctions.hasMeta(":coreType", a.meta)):
				var stack:Array<TAbstract> = [a];
				var t = a.thisType;
				var guard = 0;
				while (guard++ < 100) {
					switch (TypeFunctions.follow(t)) {
						case TAbstract(a2, _) if (!TypeFunctions.hasMeta(":coreType", a2.meta)):
							if (stack.indexOf(a2) >= 0) {
								var names = [for (x in stack) x.path.pack.concat([x.path.name]).join(".")];
								names.sort(Reflect.compare);
								var key = names.join("|");
								if (!reported.exists(key)) {
									reported.set(key, true);
									ctx.addDiagnostic("Abstract underlying type cannot be recursive", a2.pos);
								}
								break;
							}
							stack.push(a2);
							if (a2.thisType == null) break;
							t = a2.thisType;
						case _:
							break;
					}
				}
			case _:
		}
	}

	// Every final var (of the class and of constructor-less abstract supers) must be assigned in the
	// constructor. Runs after all fields typed, so sibling initializers are visible. .
	public static function checkFinalVars(ctx:Context):Void {
		// A declared constructor whose immediate super constructor is final is rejected. (FKConstructor).
		// Runs before the error gate below so it still reports alongside other modifier diagnostics.
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (c.superClass != null && c.constructor != null):
				var sup = c.superClass.c;
				if (!TypeFunctions.hasClassFlag(sup, CExtern) && sup.constructor != null
					&& sup.constructor != c.constructor
					&& TypeFunctions.hasClassFieldFlag(sup.constructor, CfFinal))
					ctx.addPrintedError("Cannot override final constructor", c.constructor.pos);
			case _:
		}
		if (ctx.hasError()) return;
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern)
				&& !TypeFunctions.hasClassFlag(c, CInterface)
				&& !TypeFunctions.hasClassFlag(c, CAbstract)):
				var body:Null<TExpr> = c.constructor == null || c.constructor.expr == null ? null : switch (c.constructor.expr.expr) {
					case TFunction(tf): tf.expr;
					case _: null;
				};
				// Reached only which creates the check from the constructor body as it is typed. A constructor
				// whose body was never typed therefore never reaches it; only 's no-constructor branch runs on
				// its own.
				if (c.constructor != null && body == null) continue;
				var finalVars:Map<String, Bool> = new Map();
				var ordered:Array<TClassField> = [];
				function collect(c2:TClass):Void {
					for (cf in c2.orderedFields)
						if (cf.kind.match(Var(_)) && TypeFunctions.hasClassFieldFlag(cf, CfFinal) && cf.expr == null && !finalVars.exists(cf.name)) {
							finalVars.set(cf.name, false);
							ordered.push(cf);
						}
					if (c2.superClass != null && TypeFunctions.hasClassFlag(c2.superClass.c, CAbstract) && c2.superClass.c.constructor == null)
						collect(c2.superClass.c);
				}
				collect(c);
				if (!finalVars.keys().hasNext()) continue;
				function findInits(e:TExpr):Void {
					switch (e.expr) {
						case TBinop(OpAssign, {expr: TField({expr: TConst(TThis)}, fa)}, rhs):
							finalVars.remove(TypeFunctions.fieldName(fa));
							findInits(rhs);
						case _:
							hxc.core.TexprTools.iter(findInits, e);
					}
				}
				if (body != null) findInits(body);
				var remaining = [for (cf in ordered) if (finalVars.exists(cf.name)) cf];
				if (remaining.length > 0) {
					if (c.constructor == null) {
						ctx.addDiagnostic("This class has uninitialized final vars, which requires a constructor", c.pos);
						// Report a separate error rather than a sub-message.
						ctx.addDiagnostic("Example of an uninitialized final var", remaining[0].namePos);
					} else {
						ctx.addDiagnostic("Some final fields are uninitialized in this class", c.namePos);
						for (cf in remaining) ctx.addDiagnostic("Uninitialized field", cf.namePos, 1);
					}
				}
			case _:
		}
	}

	static function setValueMeta(cf:TClassField, params:Array<Expr>):Void {
		cf.meta = [{name: ":value", params: params, pos: cf.pos}].concat([for (m in cf.meta) if (m.name != ":value") m]);
	}

	public static function setFunctionValueMeta(cf:TClassField, fd:Func):Void {
		// The values accumulate through a prepending fold, so the object lists the defaulted arguments in
		// REVERSE declaration order.
		var fields:Array<ObjectField> = [];
		for (arg in fd.fArgs) if (arg.value != null)
			fields.unshift({name: arg.name.name, pos: arg.name.pos, quotes: NoQuotes, expr: arg.value});
		if (fields.length > 0)
			setValueMeta(cf, [new Expr(EObjectDecl(fields), cf.pos)]);
	}

	static function hasVarHint(k:ClassFieldKind):Bool {
		return switch (k) {
			case FVar(th, _) | FProp(_, _, th, _): th != null;
			case _: true;
		};
	}

	static function typeVarInitializer(tctx:TyperContext, sigType:T, eo:Expr, hasHint:Bool, p:Position):TExpr {
		if (hasHint) return Typer.castOrUnify(tctx, sigType, Typer.typeExpr(tctx, eo, WithTypeTools.withType(sigType)), p);
		var te = Typer.typeExpr(tctx, eo, WithTypeTools.value);
		TypeUnification.unifyDefault(te.type, sigType);
		return te;
	}

	static function promoteLocalStatic(tctx:TyperContext, lut:Map<Int, TClassField>, v:TVar, eo:Null<TExpr>):Void {
		var name = tctx.curfield.name + "_" + v.name;
		if (tctx.curclass.statics.exists(name)) {
			var other = tctx.curclass.statics.get(name);
			// A repeat typing pass of the same body finds its own promoted static (same declaration
			// position): reuse it. A different local expanding to the same name is a real conflict.
			if (TypeFunctions.hasClassFieldFlag(other, CfNoLookup)
					&& other.namePos.file == v.pos.file && other.namePos.min == v.pos.min) {
				lut.set(v.id, other);
				return;
			}
			tctx.com.addDiagnostic("The expanded name of this local (" + name + ") conflicts with another static field", v.pos);
			tctx.com.addDiagnostic("Conflicting field was found here", other.namePos, 1);
			return;
		}
		if (eo != null) checkLocalStaticInit(eo);
		// ~static:true passes no ~public, and it to true: the promoted static is public, so naming it
		// reports only the no-lookup error.
		var cf = TypeFunctions.mkField(name, v.type, v.pos, v.pos, true, true);
		cf.meta = [{name: ":noCompletion", params: [], pos: Position.nullPos}].concat(v.meta);
		TypeFunctions.addClassFieldFlag(cf, CfNoLookup);
		cf.expr = eo;
		tctx.curclass.statics.set(name, cf);
		// The promoted local static is PREPENDED to the ordered statics.
		tctx.curclass.orderedStatics.unshift(cf);
		lut.set(v.id, cf);
	}

	static function checkLocalStaticInit(e:TExpr):Void {
		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TLocal(_) | TFunction(_):
					throw new TypingError("Accessing local variables in static initialization is not allowed", e.pos);
				case TConst(TThis) | TConst(TSuper):
					throw new TypingError("Accessing `this` in static initialization is not allowed", e.pos);
				case TReturn(_) | TBreak | TContinue:
					throw new TypingError("This kind of control flow in static initialization is not allowed", e.pos);
				case TArray(e1, e2) | TBinop(_, e1, e2):
					loop(e1); loop(e2);
				case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TThrow(e1) | TCast(e1, _) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1):
					loop(e1);
				case TObjectDecl(fields):
					for (f in fields) loop(f.expr);
				case TArrayDecl(el) | TBlock(el):
					for (x in el) loop(x);
				case TCall(e1, el):
					loop(e1);
					for (x in el) loop(x);
				case TNew(_, _, el):
					for (x in el) loop(x);
				case TVarExpr(_, eo):
					if (eo != null) loop(eo);
				case TFor(_, e1, e2):
					loop(e1); loop(e2);
				case TIf(e1, e2, e3):
					loop(e1); loop(e2); if (e3 != null) loop(e3);
				case TWhile(e1, e2, _):
					loop(e1); loop(e2);
				case TSwitch(e1, cases, edef):
					loop(e1);
					for (c in cases) {
						for (v in c.values) loop(v);
						loop(c.expr);
					}
					if (edef != null) loop(edef);
				case TTry(e1, catches):
					loop(e1);
					for (c in catches) loop(c.expr);
				case TConst(_) | TTypeExpr(_) | TIdent(_):
			}
		}
		loop(e);
	}

	static function localStatics(tctx:TyperContext, e:TExpr):TExpr {
		var lut:Map<Int, TClassField> = new Map();
		var loop:TExpr->TExpr = null;
		function opt(e:Null<TExpr>):Null<TExpr> return e == null ? null : loop(e);
		function arr(el:Array<TExpr>):Array<TExpr> return [for (x in el) loop(x)];
		loop = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TBlock(el):
					var out:Array<TExpr> = [];
					for (x in el) switch (x.expr) {
						case TVarExpr(v, eo) if (TypeFunctions.hasVarFlag(v, VStatic)):
							promoteLocalStatic(tctx, lut, v, eo);
						case _:
							out.push(loop(x));
					}
					e.expr = TBlock(out);
					e;
				case TLocal(v) if (TypeFunctions.hasVarFlag(v, VStatic)):
					var cf = lut.get(v.id);
					if (cf == null) throw new TypingError("Could not find local static " + v.name + " (id " + v.id + ")", e.pos);
					TexprTools.makeStaticField(tctx.curclass, cf, e.pos);
				case TArray(e1, e2): e.expr = TArray(loop(e1), loop(e2)); e;
				case TBinop(op, e1, e2): e.expr = TBinop(op, loop(e1), loop(e2)); e;
				case TField(e1, fa): e.expr = TField(loop(e1), fa); e;
				case TParenthesis(e1): e.expr = TParenthesis(loop(e1)); e;
				case TObjectDecl(fields): e.expr = TObjectDecl([for (f in fields) {key: f.key, expr: loop(f.expr)}]); e;
				case TArrayDecl(values): e.expr = TArrayDecl(arr(values)); e;
				case TCall(e1, params): e.expr = TCall(loop(e1), arr(params)); e;
				case TNew(c, params, args): e.expr = TNew(c, params, arr(args)); e;
				case TUnop(op, flag, e1): e.expr = TUnop(op, flag, loop(e1)); e;
				case TFunction(f): f.expr = loop(f.expr); e;
				case TVarExpr(v, eo): e.expr = TVarExpr(v, opt(eo)); e;
				case TFor(v, e1, e2): e.expr = TFor(v, loop(e1), loop(e2)); e;
				case TIf(econd, eif, eelse): e.expr = TIf(loop(econd), loop(eif), opt(eelse)); e;
				case TWhile(econd, body, flag): e.expr = TWhile(loop(econd), loop(body), flag); e;
				case TSwitch(subject, cases, edef):
					e.expr = TSwitch(loop(subject), [for (c in cases) {values: arr(c.values), expr: loop(c.expr)}], opt(edef));
					e;
				case TTry(e1, catches): e.expr = TTry(loop(e1), [for (c in catches) {v: c.v, expr: loop(c.expr)}]); e;
				case TReturn(eo): e.expr = TReturn(opt(eo)); e;
				case TThrow(e1): e.expr = TThrow(loop(e1)); e;
				case TCast(e1, mt): e.expr = TCast(loop(e1), mt); e;
				case TMeta(entry, e1): e.expr = TMeta(entry, loop(e1)); e;
				case TEnumParameter(e1, ef, index): e.expr = TEnumParameter(loop(e1), ef, index); e;
				case TEnumIndex(e1): e.expr = TEnumIndex(loop(e1)); e;
				case TConst(_) | TTypeExpr(_) | TIdent(_) | TBreak | TContinue | TLocal(_): e;
			}
		};
		return loop(e);
	}

	// An Int literal bound to a Float field is rewritten to a Float literal; any other init whose type
	// differs from the explicit field type wraps in a cast so the field keeps its declared type (a
	// function literal behind a Dynamic field is then not a bare TFunction, which genjs uses to defer
	// the init to the statics section).
	static function checkCast(te:TExpr, t:T):TExpr {
		if (TypeUnification.typeIseqDefault(te.type, t)) return te;
		return switch ([te.expr, TypeFunctions.follow(t)]) {
			case [TConst(TInt(i)), TAbstract(a, _)] if (a.path.pack.length == 0 && a.path.name == "Float"):
				TypeFunctions.mk(TConst(TFloat(Std.string(i))), t, te.pos);
			case _:
				TypeFunctions.mk(TCast(te, null), t, te.pos);
		};
	}

	static function buildArgs(tctx:TyperContext, sig:Null<TSignature>, fd:Func):Array<TFuncArg> {
		var result:Array<TFuncArg> = [];
		for (i in 0...fd.fArgs.length) {
			var fa = fd.fArgs[i];
			var at = (sig != null && i < sig.args.length) ? sig.args[i].t : TypeFunctions.mkMono();
			var kind = if (tctx.curfun.match(FunMemberAbstract) && i == 0 && fa.name.name == "this") VAbstractThis else VUser(TVOArgument);
			if (!kind.match(VAbstractThis)) Typer.checkLocalVariableName(tctx, fa.name.name, TVOArgument, fa.name.pos);
			var v = TypeFunctions.allocVar(kind, fa.name.name, at, fa.name.pos);
			// The display is answered from the argument's own name range.
			if (Typer.atDisplayPos(fa.name.pos)) Typer.displayVariable(tctx, v, fa.name.pos);
			// An argument's metadata lives on its variable.
			if (fa.meta.length > 0) v.meta = v.meta.concat(fa.meta);
			// @:this is prepended to the abstract this argument. LocalDce's `keep` tests exactly that meta,
			// so without it a store to the abstract this in an impl body reads as a dead store and is
			// removed.
			if (kind.match(VAbstractThis)) v.meta = [{name: ":this", params: [], pos: hxc.ast.Position.nullPos}].concat(v.meta);
			// The default value unifies into the argument type so an inferred argument settles from its
			// default (x = 1 gives x:Int).
			var def:Null<TExpr> = if (fa.value != null) {
					var te0 = Typer.typeExpr(tctx, fa.value, WithTypeTools.withType(at));
					// The verdict and keeps the typed expression, so a bad default does not stop the rest of the
					// function being checked.
					try Typer.castOrUnify(tctx, at, te0, fa.value.pos) catch (err:TypingError) {
						TyperContext.raiseOrDisplay(tctx, err.message, err.pos, err.depth);
						te0;
					}
				}
				else if (fa.opt) TypeFunctions.mk(TConst(TNull), at, fa.name.pos)
				else null;
			// The STORED default is the reduced constant: a cast unwraps to its inner expr, so an
			// enum-abstract default (m:M = AUTO) reaches the generators as TConst/TField rather than TCast
			// loop).
			if (def != null) {
				function constDef(e:TExpr):Null<TExpr> return switch (e.expr) {
					case TConst(_): e;
					case TField(_, FEnum(_, _)): e;
					case TField(_, FStatic(c2, cf2)) if (switch (c2.kind) {
						case KAbstractImpl(ab): ab.isEnum && TypeFunctions.hasClassFieldFlag(cf2, CfEnum);
						case _: false;
					}): e;
					case TCast(e1, null): constDef(e1);
					case _: null;
				}
				var reduced = constDef(def);
				if (reduced != null) def = reduced;
			}
			result.push({v: v, c: def});
		}
		return result;
	}

	// Check concrete subclasses for abstract methods inherited from an abstract superclass.
	public static function checkAbstractInheritance(ctx:Context):Void {
		function fieldSignature(cf:TClassField):String {
			return switch (TypeFunctions.follow(cf.type)) {
				case TFun(sig): cf.name + "(" + [for (a in sig.args) a.name + ":" + hxc.core.TPrinting.sTypeStr(a.t)].join(", ") + ")";
				case _: cf.name;
			};
		}
		function implemented(c:TClass, name:String):Bool {
			return c.fields.exists(name);
		}
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CAbstract) && !TypeFunctions.hasClassFlag(c, CInterface)):
				var missing:Array<TClassField> = [];
				var sup = c.superClass;
				while (sup != null) {
					for (name in sup.c.fields.keys()) {
						var cf = sup.c.fields.get(name);
						if (cf != null && TypeFunctions.hasClassFieldFlag(cf, CfAbstract) && !implemented(c, name)) missing.push(cf);
					}
					sup = sup.c.superClass;
				}
				if (missing.length > 0) {
					var parent = c.superClass == null ? "" : Context.sTypePath(c.superClass.c.path);
					ctx.addDiagnostic("This class extends abstract class " + parent + " but doesn't implement the following method" + (missing.length == 1 ? "" : "s"), c.namePos);
					ctx.addDiagnostic("Implement " + (missing.length == 1 ? "it" : "them") + " or make " + Context.sTypePath(c.path) + " abstract as well", c.namePos);
					for (cf in missing) ctx.addDiagnostic("... " + fieldSignature(cf), cf.namePos, 1);
				}
			case _:
		}
	}

	static function checkExternDefaults(ctx:Context, tctx:TyperContext, cf:TClassField, fd:Func, isStatic:Bool):Void {
		// The extern default check runs once per field, when the field is created. The install loop
		// re-visits a module whenever its declared shape changes, and re-checking the defaults on every
		// visit would report one verdict several times.
		if (externDefaultsChecked.exists(cf)) return;
		externDefaultsChecked.set(cf, true);
		var sig = switch (TypeFunctions.follow(cf.type)) { case TFun(s): s; case _: null; };
		if (sig == null) return;
		var oldFun = tctx.curfun;
		tctx.curfun = isStatic ? FunStatic : FunMember;
		for (i in 0...fd.fArgs.length) {
			var value = fd.fArgs[i].value;
			if (value == null || i >= sig.args.length) continue;
			try Typer.castOrUnify(tctx, sig.args[i].t, Typer.typeExpr(tctx, value, WithTypeTools.withType(sig.args[i].t)), value.pos)
			catch (e:Dynamic) recordFieldError(ctx, e);
		}
		tctx.curfun = oldFun;
	}
}
