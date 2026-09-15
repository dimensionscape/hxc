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
	// __init__ fields whose typed body was trivially empty, per field object.

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

	// The classes whose build is queued (or has run), and the classes whose build has run through
	// finalizeClass.
	static var buildQueued:haxe.ds.ObjectMap<TClass, Bool> = new haxe.ds.ObjectMap();
	static var classBuilt:haxe.ds.ObjectMap<TClass, Bool> = new haxe.ds.ObjectMap();

	/**
	 * Whether the class's build has begun.
	 */
	public static function buildStarted(c:TClass):Bool return classBuilt.exists(c);
	// The fields a build bound with a lazy signature, per world; unwrapped once that world's bodies
	// have typed. The macro world finalizes in the middle of a host flush, and the host's lazies are
	// not its to force.
	static var boundSignatures:haxe.ds.ObjectMap<Context, Array<TClassField>> = new haxe.ds.ObjectMap();
	// HXC_DBG_BUILDS: trace each class build and finalizeClass to stderr.
	static var traceBuilds:Bool = Sys.getEnv("HXC_DBG_BUILDS") != null;

	public static function resetPerRequest():Void {
		buildQueued = new haxe.ds.ObjectMap();
		classBuilt = new haxe.ds.ObjectMap();
		boundSignatures = new haxe.ds.ObjectMap();
		lazyFieldTypes = new haxe.ds.ObjectMap();
		bodyTyped = new haxe.ds.ObjectMap();
		finalizedModules = new haxe.ds.ObjectMap();
		externDefaultsChecked = new haxe.ds.ObjectMap();
		macroForced = new haxe.ds.ObjectMap();
		inheritDocQueued = new haxe.ds.ObjectMap();
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
		// installAndForce is single-pass; a body it types can load more modules on demand. Repeat at the
		// top level until the module set is closed (installAndForce stays re-entrancy-safe for the nested
		// call build macros make).
		// Flushing a pass drains every pass up to the one asked for, and a module a body loads queues its
		// class builds and bodies BELOW PForce, so the same flush reaches them: no PForce delay runs until
		// every body of every module loaded on the way has typed. The rounds hold PForce back until the
		// module set is closed, and a forced lazy that loads more modules starts another.
		var n = -1;
		while (true) {
			while (ctx.modules.length != n) {
				n = ctx.modules.length;
				installAndForce(ctx, false);
			}
			if (ctx.declAborted) break;
			tt("flush:PForce", function() { ctx.flushPass(hxc.context.Context.PForce); return 0; });
			if (ctx.modules.length == n) break;
		}
		unwrapBoundSignatures(ctx);
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

	public static function installAndForce(ctx:Context, flushForce:Bool = true):Void {
		var i = 0;
		while (i < ctx.modules.length) {
			// A module loaded on demand after the initial resolveAll pass (e.g. through an import inside a
			// lazily loaded class) has no heritage yet; resolve it before installing and forcing bodies, or
			// a `super(...)` in one of its constructors types against a null superClass. resolveModule is
			// idempotent (processed gate).
			var mres = ctx.modules[i];
			if (ctx.isMacro && finalizedModules.exists(mres)) { i++; continue; }
			tt("resolveModule", function() { hxc.typing.TypeResolve.resolveModule(ctx, mres); return 0; });
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
		// Every class is queued when its module is typed. One that reached the module list another way (a
		// cached module re-added, a generic instance) is queued now, in load order, so it too builds
		// last-loaded first.
		for (m in ctx.modules) {
			if (ctx.isMacro) {
				if (finalizedModules.exists(m)) continue;
				finalizedModules.set(m, true);
			}
			for (mt in m.types) switch (mt) {
				case TClassDecl(c): queueClassBuild(ctx, c);
				case _:
			}
		}
		// The passes flush in finalization order: the class builds (PBuildClass, each pushing its
		// bodies), PConnectField, then the bodies (PTypeField), last-built class first.
		tt("flush:PTypeField(bodies)", function() { ctx.flushPass(hxc.context.Context.PTypeField); return 0; });
		unwrapBoundSignatures(ctx);
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
		if (flushForce) tt("flush:PForce", function() { ctx.flushPass(hxc.context.Context.PForce); return 0; });
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
			var fe = new hxc.core.TypingError.FatalError(ce.message, ce.pos, ce.depth, true);
			fe.callChain = ce.callChain;
			throw fe;
		}
		recordFieldError(ctx, e);
	}

	static function recordFieldError(ctx:Context, e:Dynamic):Void {
		// A display result is the compile's answer, not a field error.
		if (Std.isOfType(e, hxc.compiler.DisplayXml.DisplayPositions)) throw e;
		if (Std.isOfType(e, hxc.typing.Typer.JsonToplevelCompletion)) throw e;
		if (Std.isOfType(e, hxc.compiler.DisplayXml.DisplayRaised)) throw e;
		// A fatal error is on its way to the driver; recording it here would swallow the abort. So is a
		// runtime exception a native let escape (the driver reports it), and a macro's Sys.exit (re-raised,
		// as EvalMacro's load path already does).
		if (Std.isOfType(e, hxc.core.TypingError.FatalError) || Std.isOfType(e, hxc.eval.EvalExceptions.HostException)
			|| Std.isOfType(e, hxc.eval.EvalExceptions.EvalSysExit)) throw e;
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
			if (ce.callChain != null) ctx.addDiagnosticStack(ce.callChain, ce.depth)
			else addDiagnosticOnce(ctx, ce.message, ce.pos, ce.depth);
		} else if (Std.isOfType(e, EvalRunTimeException)) {
			// A macro-time uncaught exception reports with its eval call stack, the same shape the
			// interpreter prints. A Context.error abort carries its own message and position and prints
			// plain.
			var re:EvalRunTimeException = cast e;
			var info = hxc.eval.EvalMacro.runtimeMacroError(re);
			if (info != null) {
				if (info.stack != null) ctx.addDiagnosticStack(info.stack)
				else addDiagnosticOnce(ctx, info.message, info.pos);
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

	public static function queueClassBuild(ctx:Context, c:TClass):Void {
		if (buildQueued.exists(c)) return;
		buildQueued.set(c, true);
		if (traceBuilds) Sys.stderr().writeString("[qbuild] " + Context.sTypePath(c.path) + "
");
		ctx.delay(Context.PBuildClass, function() {
			// Flushing a pass has no handler: a build macro's failure raised out of a queued build goes to
			// whoever flushed. The finalize's flush is the pass runner, so the compile ends; the macro
			// world's finalize hands it to the caller of the macro load. A flush made by a load inside a
			// field body raises it out of that load, an Error the expression's statement records - which
			// hxc carries as a ContextError, as forceBuildInBody does.
			var flushedFromBody = ctx.currentPass == Context.PTypeField;
			try buildClass(ctx, c) catch (e:TypingError) {
				if (ctx.isMacro || Std.isOfType(e, hxc.core.TypingError.FatalError)) throw e;
				if (flushedFromBody) {
					// A macro module that did not load is a module-not-found of that module (printed "Type not
					// found : <path>"), never of the class being built.
					var kind = hxc.context.Context.ContextErrorKind.Other;
					var tnf = "Type not found : ";
					if (Std.isOfType(e, hxc.core.TypingError.ModuleNotFoundError) && StringTools.startsWith(e.message, tnf)) {
						var parts = e.message.substr(tnf.length).split(".");
						var name = parts.pop();
						kind = hxc.context.Context.ContextErrorKind.ModuleNotFound({pack: parts, name: name});
					}
					var ce = new hxc.context.Context.ContextError(e.message, e.pos, kind, e.depth);
					ce.callChain = e.callChain;
					throw ce;
				}
				var fe = new hxc.core.TypingError.FatalError(e.message, e.pos, e.depth);
				fe.callChain = e.callChain;
				throw fe;
			}
		});
	}

	// The build: heritage resolution forces the super's and each interface's build, then the class init
	// runs the build macros, binds the fields and schedules their bodies (finalizeClass).
	public static function buildClass(ctx:Context, c:TClass):Void {
		if (classBuilt.exists(c)) return;
		// A class nothing declares keeps the default build state, which is built at once - a type
		// parameter's class among them.
		if (c.kind.match(KTypeParameter(_))) return;
		var m = c.module;
		if (m == null) return;
		classBuilt.set(c, true);
		buildQueued.set(c, true);
		if (traceBuilds) Sys.stderr().writeString("[build] " + Context.sTypePath(c.path) + "\n");
		var mw = enterMacroWorld(ctx);
		var savedPass = ctx.currentPass;
		// The build runs in the class's own typer context, so nothing it does moves the requester's current
		// module.
		var savedModule = ctx.currentModule;
		ctx.currentPass = Context.PBuildClass;
		ctx.currentModule = m;
		try {
			TypeResolve.resolveModule(ctx, m);
			TypeResolve.forceQueuedBuild(c);
			if (c.superClass != null) buildClass(ctx, c.superClass.c);
			for (i in c.interfaces) buildClass(ctx, i.c);
			if (!ctx.declAborted) {
				hxc.eval.EvalMacro.runClassBuildMacros(ctx, c);
				var entry = ctx.declOfType.get(Context.pathKey(c.path));
				if (entry != null) switch (entry.decl) {
					case EClass(d):
						addImplicitInterfaceFields(c);
						var bound = boundSignatures.get(ctx);
						if (bound == null) boundSignatures.set(ctx, bound = []);
						installClassFields(ctx, c, d, m, bound);
						finalizeClass(ctx, c, d);
					case _:
				}
			}
		} catch (e:Dynamic) {
			ctx.currentPass = savedPass;
			ctx.currentModule = savedModule;
			leaveMacroWorld(mw);
			throw e;
		}
		ctx.currentPass = savedPass;
		ctx.currentModule = savedModule;
		leaveMacroWorld(mw);
	}

	// finalizeClass: one PTypeField delay per bound field, pushed in reverse so the bucket runs them in
	// declaration order. A macro field in the host was pushed earlier, by the binding itself (forcing the
	// macro) while the fields bound. What the declarations do not name (a synthesized field) is forced
	// last.
	static function finalizeClass(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>):Void {
		if (traceBuilds) Sys.stderr().writeString("[fin] " + Context.sTypePath(c.path) + "\n");
		pushRemainingBodies(ctx, c);
		var full = ctx.displayFullTyping;
		var byDecl = new haxe.ds.ObjectMap<ClassField, TClassField>();
		function note(cf:Null<TClassField>):Void {
			if (cf == null) return;
			var cff = findFieldDecl(ctx, c, cf);
			if (cff != null && !byDecl.exists(cff)) byDecl.set(cff, cf);
		}
		for (cf in c.orderedFields) { note(cf); for (o in cf.overloads) note(o); }
		for (cf in c.orderedStatics) { note(cf); for (o in cf.overloads) note(o); }
		if (c.constructor != null) { note(c.constructor); for (o in c.constructor.overloads) note(o); }
		note(c.initField);
		var delayed:Array<TClassField> = [];
		for (cff in d.dData) {
			var cf = byDecl.get(cff);
			if (cf == null || !(full || isDisplayField(cf))) continue;
			switch (cff.cffKind) {
				case FVar(_, null) | FProp(_, _, _, null): continue;
				case _:
			}
			if (skipMacroBodyInHost(ctx, cf)) pushFieldBody(ctx, c, cf);
			else delayed.push(cf);
		}
		var i = delayed.length - 1;
		while (i >= 0) pushFieldBody(ctx, c, delayed[i--]);
	}

	static function pushFieldBody(ctx:Context, c:TClass, cf:TClassField):Void {
		ctx.delay(Context.PTypeField, function() forceFieldBody(ctx, c, cf));
	}

	static function pushRemainingBodies(ctx:Context, c:TClass):Void {
		ctx.delay(Context.PTypeField, function() {
			var full = ctx.displayFullTyping;
			for (cf in c.orderedFields) if (cf.expr == null && (full || isDisplayField(cf))) forceFieldBody(ctx, c, cf);
			for (cf in c.orderedStatics) if (cf.expr == null && (full || isDisplayField(cf))) forceFieldBody(ctx, c, cf);
			// An __init__ binds like any field, though it is not one.
			var initField = c.initField;
			if (initField != null && initField.expr == null && (full || isDisplayField(initField))) forceFieldBody(ctx, c, initField);
			// The inherited forwarding constructor is no declared field and is not in finalizeClass's list:
			// its lazy is forced at PForce.
			if (c.constructor != null && c.constructor.expr == null
				&& findFieldDecl(ctx, c, c.constructor) != null
				&& (full || isDisplayField(c.constructor))) forceFieldBody(ctx, c, c.constructor);
		});
	}

	// A lazy signature the bodies did not force is forced now and unwrapped to its concrete type, so
	// downstream consumers never see a TLazy. Under a display request a field that is not the one the
	// cursor is in keeps its lazy.
	static function unwrapBoundSignatures(ctx:Context):Void {
		var bound = boundSignatures.get(ctx);
		if (bound == null) return;
		boundSignatures.remove(ctx);
		for (cf in bound) {
			if (!ctx.displayFullTyping && !isDisplayField(cf)) continue;
			switch (cf.type) {
				case TLazy(r):
					try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e);
				case _:
			}
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
					TypeResolve.forceQueuedBuild(c);
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

	public static function addDiagnosticOnce(ctx:Context, message:String, pos:Position, depth:Int = 0):Void {
		for (d in ctx.diagnostics)
			if (d.message == message && d.depth == depth && d.pos.file == pos.file && d.pos.min == pos.min && d.pos.max == pos.max) return;
		ctx.addDiagnostic(message, pos, depth);
	}

	// Every class whose install has begun. installClassOnDemand reads it.
	public static function hasInstallStarted(c:TClass):Bool return c.hxcInstallStarted;

	// A @:structInit class's constructor is built where the class init ENDS, and every class of a module is
	// initialized (PBuildClass) before any body types. hxc installs a module class by class, so a body
	// forced while an earlier class installs can reach a later class that has not: install that one first,
	// which also builds its constructor.
	public static function installClassOnDemand(ctx:Context, c:TClass):Void {
		if (c.hxcInstallStarted || c.module == null || c.module.extra.resolved < 1) return;
		TypeResolve.forceQueuedBuild(c);
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return;
		switch (entry.decl) {
			case EClass(d):
				var mw = enterMacroWorld(ctx);
				var savedPass = ctx.currentPass;
				ctx.currentPass = Context.PBuildClass;
				try {
					addImplicitInterfaceFields(c);
					installClassFields(ctx, c, d, c.module, []);
				} catch (e:Dynamic) { ctx.currentPass = savedPass; leaveMacroWorld(mw); throw e; }
				ctx.currentPass = savedPass;
				leaveMacroWorld(mw);
			case _:
		}
	}

	static function installClassFields(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, m:ModuleDef, pending:Array<TClassField>):Void {
		c.hxcInstallStarted = true;
		// The declaration itself did not resolve, so these fields are never bound (the class init raised
		// inside the heritage). Typing them anyway would report every member inherited from the type that
		// failed to load. See Context.declErrored.
		if (ctx.declErrored.exists(Context.pathKey(c.path))) return;
		// A @:coreApi class outside a -D core_api build queues its validation against the pristine core
		// definition (delayed to PForce; display requests skip it).
		if (Sys.getEnv("HXC_DBG_CORE") != null && TypeFunctions.hasMeta(":coreApi", c.meta)) Sys.println("[core] hook-check " + c.path.name + " core_api=" + ctx.defines.rawDefined("core_api") + " disp=" + (ctx.displaySpec != null));
		if (TypeFunctions.hasMeta(":coreApi", c.meta) && !ctx.defines.rawDefined("core_api") && ctx.checkCoreApi())
			ctx.delay(Context.PForce, function() try hxc.typing.CoreApi.initCoreApi(ctx, c) catch (e:Dynamic) recordFieldError(ctx, e));
		// Unless the class is a lib type, its overloads are checked for duplicate signatures once the pass
		// reaches PForce, and a concrete class extending an abstract one for the methods it leaves
		// unimplemented. Both are queued once per class; hxc may install a class's fields again.
		if (!TypeFunctions.hasMeta(":libType", c.meta) && !c.hxcClassChecksQueued) {
			c.hxcClassChecksQueued = true;
			ctx.delay(Context.PForce, function() checkOverloads(ctx, c));
			var sup = c.superClass;
			if (sup != null && TypeFunctions.hasClassFlag(sup.c, CAbstract) && !TypeFunctions.hasClassFlag(c, CAbstract))
				ctx.delay(Context.PForce, function() checkAbstractClass(ctx, c, sup.c, sup.params));
		}
		if (TypeFunctions.hasClassFlag(c, CAbstract) && TypeFunctions.hasClassFlag(c, CFinal))
			addDiagnosticOnce(ctx, "An abstract class may not be final", c.namePos);
		if (TypeFunctions.hasClassFlag(c, CInterface) && TypeFunctions.hasClassFlag(c, CAbstract))
			addDiagnosticOnce(ctx, "An interface may not be abstract", c.namePos);
		var tctx = new TyperContext(ctx);
		tctx.curclass = c;
		tctx.typeParams = c.params;
		tctx.tthis = classContextThis(c);
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var nameSeen = new haxe.ds.StringMap<Int>();
		// The fields the class init has added so far.
		var added:Array<{cf:TClassField, isStatic:Bool}> = [];
		var externChecks:Array<{cf:TClassField, fd:Func, isStatic:Bool, abstractMember:Bool}> = [];
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
			// The static flag every modifier check reads counts an abstract member too.
			if (isAbsImpl && cff.cffName.name != "new") hasStatic = true;
			// At most one of these is reported per field: the first latches the field's error flag, which
			// every FieldError function goes through. So the order decides which one survives, and it is the
			// call order, not a reading order: abstract+static, abstract+final and abstract+inline run while
			// the field context is created, ahead of everything else in the field init, while
			// abstract+dynamic, dynamic+inline and override+static are late, inside method creation.
			var slotTaken = false;
			function modError(msg:String, mp:Position):Void {
				if (slotTaken) return;
				slotTaken = true;
				ctx.fieldErrorReported.set(cff, true);
				addDiagnosticOnce(ctx, msg, mp);
			}
			if (hasAbstract && hasStatic) modError("Invalid modifier combination: abstract + static", cff.cffName.pos);
			if (hasAbstract && hasFinal) modError("Invalid modifier combination: abstract + final", cff.cffName.pos);
			if (hasAbstract && hasInline) modError("Invalid modifier combination: abstract + inline", cff.cffName.pos);
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
					modError("Invalid modifier combination: final + static", fp);
				case _:
			}
			if (hasAbstract && hasDynamic) modError("Invalid modifier combination: abstract + dynamic", cff.cffPos);
			if (hasDynamic && hasInline) modError("Invalid modifier combination: dynamic + inline", cff.cffPos);
			if (hasOverride && hasStatic) modError("Invalid modifier combination: override + static", cff.cffPos);
			// The last of the checks a method field gets.
			if (hasAbstract) switch (cff.cffKind) {
				case FFun(fd) if (fd.fExpr != null): modError("Abstract methods may not have an expression", cff.cffPos);
				case _:
			}
			// Binding a variable's expression opens with this, ahead of the @:value meta and of typing the
			// initializer: an interface field may not carry one at all. It is EAGER, so the bind rule
			// (which excludes every interface) does not reach it, and it reports at the INITIALIZER rather
			// than at the field.
			switch (cff.cffKind) {
				case FVar(_, eo) | FProp(_, _, _, eo) if (eo != null
						&& TypeFunctions.hasClassFlag(c, CInterface)):
					modError("Initialization on field of interface", eo.pos);
				case _:
			}
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			if (isAbsImpl && !isStatic && cff.cffName.name != "new") isStatic = true;
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else TypeFunctions.declaredField(c, cff.cffName.name, isStatic);
			if (cf == null) continue;
			// Every declaration is a field of its own and binds its own body: the k-th of one name is its
			// overload sibling, or the k-th registered field of that name, as
			// TypeResolve.resolveClassFieldsInner pairs them. Pairing by name alone would leave every later
			// overload unbound, so an overload candidate would never run its body as it was tried.
			var nameKey = (isStatic ? "s:" : "i:") + cff.cffName.name;
			var occ = nameSeen.exists(nameKey) ? nameSeen.get(nameKey) : 0;
			nameSeen.set(nameKey, occ + 1);
			if (occ > 0) {
				if (cff.cffName.name == "new" && cf.overloads.length < occ) continue;
				cf = cf.overloads.length >= occ ? cf.overloads[cf.overloads.length - occ]
					: TypeResolve.nthFieldNamed(isStatic ? c.orderedStatics : c.orderedFields, cff.cffName.name, occ, cf);
			}
			// A duplicate declaration was reported and never added, so it declares no field; pairing it by
			// name hands it the field it merely collided with.
			if (ctx.droppedFieldDecls.exists(cff)) continue;
			// An overload merges into the field of its name, and a static `__init__` is not added.
			if (occ == 0 && !(isStatic && cff.cffName.name == "__init__")) added.push({cf: cf, isStatic: isStatic});
			// The field init ends by queueing the docs a field carrying @:inheritDoc collects, once the
			// supertypes' fields exist.
			if (TypeFunctions.hasMeta(":inheritDoc", cf.meta) && !inheritDocQueued.exists(cf)) {
				inheritDocQueued.set(cf, true);
				var cfDoc = cf;
				ctx.delay(Context.PTypeField, function() hxc.typing.InheritDoc.buildClassFieldDoc(ctx, c, cfDoc));
			}
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
				var externBinds = false;
				switch (cff.cffKind) {
					// The bind rule holds for an extern INLINE method, which binds like any other; only the
					// rest take the extern-check delay.
					case FFun(_) if (Lambda.exists(cff.cffAccess, a -> a.access == AInline)):
						externBinds = true;
					// A variable or property always binds, and an extern one's initializer is typed before
					// the
					// checks on the variable's expression complain about it.
					case FVar(_, _) | FProp(_, _, _, _):
						externBinds = true;
					case FFun(fd): externChecks.push({cf: cf, fd: fd, isStatic: isStatic,
						abstractMember: isAbsImpl && cff.cffName.name != "new" && !Lambda.exists(cff.cffAccess, a -> a.access == AStatic)});
					case _:
				}
				if (!externBinds) {
					initFieldDisplay(c, cf, isStatic, added);
					continue;
				}
			}
			if (!hasFieldBody(cff)) {
				initFieldDisplay(c, cf, isStatic, added);
				continue;
			}
			installField(ctx, tctx, m, cf, cff, isStatic);
			pending.push(cf);
		}
		// The class init ends by giving a @:structInit class its constructor.
		if (TypeFunctions.hasMeta(":structInit", c.meta) && !TypeFunctions.hasClassFlag(c, CInterface))
			Typer.ensureStructInitCtorFor(tctx, c);
		// Each extern function's default-value check is delayed into PTypeField, where the classes it
		// names have built; the bucket drains last-in first-out, so the field declared last reports its
		// default-value verdict first.
		for (x in externChecks) {
			var xx = x;
			ctx.delay(Context.PTypeField, () -> checkExternDefaults(ctx, tctx, xx.cf, xx.fd, xx.isStatic, xx.abstractMember));
		}
	}

	// A class's fields may be installed again; the field init runs once per field.
	static var inheritDocQueued:haxe.ds.ObjectMap<TClassField, Bool> = new haxe.ds.ObjectMap();

	// A variable with no expression, or a method that does not bind, checks field display inside the field
	// init, before the field is added: the class it shows holds the fields declared above it, newest first,
	// as adding a field prepends it. hxc registered every field at load, so the answer is made over that
	// state.
	static function initFieldDisplay(c:TClass, cf:TClassField, isStatic:Bool, added:Array<{cf:TClassField, isStatic:Bool}>):Void {
		if (!Typer.atDisplayPos(cf.namePos)) return;
		var sFields = c.fields, sStatics = c.statics, sOrdered = c.orderedFields;
		var sOrderedStatics = c.orderedStatics, sCtor = c.constructor;
		var fields = new haxe.ds.StringMap<TClassField>(), statics = new haxe.ds.StringMap<TClassField>();
		var ordered:Array<TClassField> = [], orderedStatics:Array<TClassField> = [], ctor:Null<TClassField> = null;
		for (i in 0...added.length) {
			var a = added[i];
			if (a.cf == cf) continue;
			if (!a.isStatic && a.cf == sCtor) ctor = a.cf;
			else if (a.isStatic) { statics.set(a.cf.name, a.cf); orderedStatics.unshift(a.cf); }
			else { fields.set(a.cf.name, a.cf); ordered.unshift(a.cf); }
		}
		// An abstract's operator and cast lists are built the same way (each prepended as its field
		// initializes, the displayed one included) and only reversed once the loop is over.
		var a = switch (c.kind) { case KAbstractImpl(a): a; case _: null; };
		var sOps = a == null ? null : a.ops, sUnops = a == null ? null : a.unops;
		var sFrom = a == null ? null : a.fromField, sTo = a == null ? null : a.toField;
		var sArray = a == null ? null : a.array;
		function restore():Void {
			c.fields = sFields; c.statics = sStatics; c.orderedFields = sOrdered;
			c.orderedStatics = sOrderedStatics; c.constructor = sCtor;
			if (a != null) {
				a.ops = sOps; a.unops = sUnops; a.fromField = sFrom; a.toField = sTo; a.array = sArray;
			}
		}
		c.fields = fields; c.statics = statics; c.orderedFields = ordered;
		c.orderedStatics = orderedStatics; c.constructor = ctor;
		if (a != null) {
			var seen = new haxe.ds.ObjectMap<TClassField, Bool>();
			for (x in added) seen.set(x.cf, true);
			a.ops = [for (o in sOps) if (seen.exists(o.cf)) o];
			a.ops.reverse();
			a.unops = [for (o in sUnops) if (seen.exists(o.cf)) o];
			a.unops.reverse();
			a.fromField = [for (o in sFrom) if (seen.exists(o.cf)) o];
			a.fromField.reverse();
			a.toField = [for (o in sTo) if (seen.exists(o.cf)) o];
			a.toField.reverse();
			a.array = [for (f in sArray) if (seen.exists(f)) f];
			a.array.reverse();
		}
		try Typer.displayClassField(c, !isStatic && cf == sCtor, cf, cf.namePos, isStatic) catch (e:Dynamic) {
			restore();
			throw e;
		}
		restore();
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
		// A macro field is forced for every macro field under full typing, and otherwise only for the
		// display field; forced macro typing is off for every display kind that types selectively.
		// `display` is which of the two arms it came from.
		if (!ctx.displayFullTyping && !isDisplayField(cf)) return;
		if (macroForced.exists(cf)) return;
		macroForced.set(cf, true);
		if (c.module == null) return;
		var isDisplay = !ctx.displayFullTyping;
		// The load itself is a PTypeField delay, so every class build queued so far
		// (PBuildClass) runs before it.
		ctx.delay(Context.PTypeField, function() {
			// The declaring module's path, not the class's: a class whose name differs from its module file
			// (common in display requests) is not loadable by its own path.
			try hxc.eval.EvalMacro.loadMacro(ctx, c.path, cf.name, c.module.path, c.module, cf.pos, true)
			catch (e:hxc.core.TypingError) { if (!isDisplay) throw e; }
			catch (e:hxc.context.Context.ContextError) { if (!isDisplay) throw e; }
		});
	}

	static function installField(ctx:Context, tctx:TyperContext, m:ModuleDef, cf:TClassField, cff:ClassField, isStatic:Bool):Void {
		// Idempotent: a field already bound or already typed is left alone so typeAllModules can be re-run
		// to pick up modules loaded on demand. A signature that is a lazy of its own - a @:generic hint's
		// instance - is not a bound body: the body still goes behind a lazy over it, so `localVars.name`
		// types localVars first.
		if (lazyFieldTypes.exists(cf)) return;
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
				// is not loadable by its own path. Forcing the macro is a PTypeField delay, so every class
				// build queued so far (PBuildClass) runs first.
				var cpath = tctx.curclass.path, mpath = m.path, name = cf.name;
				ctx.delay(Context.PTypeField, function() {
					try hxc.eval.EvalMacro.loadMacro(ctx, cpath, name, mpath, null, null, true)
					catch (_:hxc.core.TypingError) {}
					catch (_:hxc.context.Context.ContextError) {}
				});
			}
			return;
		}
		// A display request that types selectively puts the body behind a lazy only for the display field
		// or a signature that is not a full type; any other field keeps its declared signature, and nothing
		// that reads its type ever types its body.
		if (!bodyBehindLazy(ctx, cf, cf.type)) return;
		var sigType = cf.type;
		lazyFieldTypes.set(cf, sigType);
		var r = new Ref(LAvailable(sigType));
		var force = function():T {
			for (f in _forcing) if (f == cf) return sigType;
			// While returnPartialType is set, a forced field answers its signature without typing its body
			// - a method never, a variable unless its initializer is a constant - and the lazy keeps that
			// answer.
			if (returnPartialType && !(switch (cff == null ? null : cff.cffKind) {
				case FVar(_, {expr: EConst(_)}) | FProp(_, _, _, {expr: EConst(_)}): true;
				case _: false;
			})) {
				r.set(LAvailable(sigType));
				return sigType;
			}
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

	// isFullType: only a signature that is not full is left behind the lazy that types the body when
	// it is forced. hxc puts every field behind one, so a site that forces a field for its type has to
	// ask this first.
	public static function isFullType(t:T):Bool {
		return switch (t) {
			case TFun(sig):
				if (!isFullType(sig.ret)) return false;
				for (a in sig.args) if (!isFullType(a.t)) return false;
				true;
			case TMono(r): r.type != null && isFullType(r.type);
			case TAbstract(_, _) | TInst(_, _) | TEnum(_, _) | TLazy(_) | TDynamic(_) | TAnon(_) | TType(_, _): true;
		}
	}

	// Whether this field's body goes behind the lazy its type forces: always under full typing, otherwise
	// for the display field and for a signature that is not a full type.
	public static function bodyBehindLazy(ctx:Context, cf:TClassField, sig:T):Bool {
		return ctx.displayFullTyping || isDisplayField(cf) || !isFullType(sig);
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
	public static function forceClassFields(ctx:Context, c:TClass):Void {
		TypeResolve.forceQueuedBuild(c);
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
				else TypeFunctions.declaredField(c, cff.cffName.name, isStatic);
			if (cf == null || cf.expr != null) continue;
			// A duplicate declaration was reported and never added, so it declares no field; pairing it by
			// name hands it the field it merely collided with.
			if (ctx.droppedFieldDecls.exists(cff)) continue;
			// A body that already ran is not typed again: a member var whose initializer the field-init
			// filter moved into the constructor has a null expr, and re-typing it would put back the raw
			// initializer the filters took away.
			if (bodyTyped.exists(cf)) continue;
			if (!hasFieldBody(cff)) continue;
			if ((TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) && cff.cffName.name != "__init__"
				&& (switch (cff.cffKind) { case FFun(_): !Lambda.exists(cff.cffAccess, a -> a.access == AInline); case _: false; })) continue;
			if (skipMacroBodyInHost(ctx, cf)) continue;
			switch (cf.type) { case TLazy(r): try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e); case _: }
			// Forcing the lazy is typing the body; it runs once.
			if (bodyTyped.exists(cf)) continue;
			try {
				typeFieldBody(tctx, cf, cff, isStatic, cf.type);
			} catch (e:Dynamic) fatalFieldError(ctx, e);
		}
		ctx.currentModule = savedMod;
	}

	static var _forcing:Array<TClassField> = [];

	// Set while display collects static extensions, so a forced field answers its partial type.
	public static var returnPartialType = false;

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
		// A field's lazies (its signature, its class's build, its body) carry the context of the
		// module that declares it, so what they load is that module's dependency - never the
		// dependency of whichever module happened to be current when something forced them.
		var savedModule = ctx.currentModule;
		ctx.currentModule = c.module;
		try forceFieldBodyInner(ctx, c, cf) catch (e:Dynamic) { ctx.currentModule = savedModule; leaveMacroWorld(mw); throw e; }
		ctx.currentModule = savedModule;
		leaveMacroWorld(mw);
	}

	static function forceFieldBodyInner(ctx:Context, c:TClass, cf:TClassField):Void {
		if (cf.expr != null) return;
		TypeResolve.forceQueuedBuild(c);
		// Same reason as installClassFields: the declaration never resolved, so there is no body to type
		// here. The filters reach this path directly, so guarding the install site alone is not enough.
		if (ctx.declErrored.exists(Context.pathKey(c.path))) return;
		if (bodyTyped.exists(cf)) return;
		switch (cf.type) {
			case TLazy(r):
				try cf.type = TypeFunctions.lazyType(r) catch (e:Dynamic) recordFieldError(ctx, e);
				if (cf.expr != null || bodyTyped.exists(cf)) return;
			case _:
		}
		// A display request that types selectively gives a body only to the display field and to a
		// signature that is not a full type, and only forcing that lazy types it; any other field has no
		// body to type, whoever asks for one.
		if (!bodyBehindLazy(ctx, cf, cf.type)) return;
		// Re-entry on the same field returns its current (still-open) signature, as a lazy type still in
		// progress does. A different field is forced normally even when nested, so an inline callee's
		// return type is inferred before its result is consumed by the caller.
		for (f in _forcing) if (f == cf) return;
		var cff = findFieldDecl(ctx, c, cf);
		if (cff == null) {
			if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null) Sys.println("[fforce] no decl for " + c.path.name + "." + cf.name);
			return;
		}
		// Inline-ness comes from the declaration's access list: a @:require has already rewritten kind to
		// AccRequire, and the initializer still binds.
		var isInlineField = false;
		for (a in cff.cffAccess) if (a.access == AInline) isInlineField = true;
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
			// Binding a method is gated on the bind rule and the macro forcing lives inside it, so an
			// abstract field whose arm allowed no expr is never loaded into the macro world. Forcing it
			// anyway would run the abstract check a second time there and report its verdict twice.
			if (!ctx.abstractNoExprFields.exists(cf)) forceMacroFieldInMacroWorld(ctx, c, cf);
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
		var nameSeen:Null<haxe.ds.StringMap<Int>> = null;
		for (f in d.dData) {
			var fStatic = false;
			for (a in f.cffAccess) if (a.access == AStatic) fStatic = true;
			if (isAbsImpl && !fStatic && f.cffName.name != "new") fStatic = true;
			var base = if (!fStatic && f.cffName.name == "new") c.constructor
				else TypeFunctions.declaredField(c, f.cffName.name, fStatic);
			if (base == null) continue;
			// Occurrences only pick an overload or drop a second constructor: a name whose field has no
			// overloads is that field at every occurrence.
			if (base.overloads.length == 0 && f.cffName.name != "new") {
				if (base == cf) return f;
				continue;
			}
			if (nameSeen == null) nameSeen = new haxe.ds.StringMap<Int>();
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
		var com = tctx.com;
		var savedPass = com.currentPass;
		com.currentPass = Context.PTypeField;
		// A field types in a context of its own, whose call-argument stack starts as its class's - empty,
		// since only typing a `new` pushes and it pushes onto a field's context.
		var savedArgs = com.callArgumentStack;
		com.callArgumentStack = [];
		try typeFieldBodyInner(tctx, cf, cff, isStatic, sigType) catch (e:Dynamic) {
			bodyDepth--;
			com.currentPass = savedPass;
			com.callArgumentStack = savedArgs;
			throw e;
		}
		com.currentPass = savedPass;
		com.callArgumentStack = savedArgs;
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
		// An abstract member is declared without static in the impl class. A static @:to is CfImpl as well
		// but typed FunStatic.
		var isAbstractMember = isAbsImpl && cff.cffName.name != "new"
			&& !Lambda.exists(cff.cffAccess, a -> a.access == AStatic);
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
		// The module's context init runs as a body starts typing.
		if (tctx.curclass != null) tctx.com.contextInitRun(tctx.curclass.module);
		// -v logs the body (a variable's initializer or a method) as it starts typing, "macro " marking the
		// macro context's copy.
		if (tctx.com.verbose && switch (cff.cffKind) { case FFun(_): true; case FVar(_, eo) | FProp(_, _, _, eo): eo != null; })
			tctx.com.log("Typing " + (tctx.com.isMacro ? "macro " : "") + Context.sTypePath(tctx.curclass.path) + "." + cf.name);
		try {
			switch (cff.cffKind) {
				case FVar(_, eo):
					if (eo != null) bindVarExpression(tctx, cf, cff, sigType, eo, isStatic);
				case FFun(fd):
					var sig = switch (TypeFunctions.follow(sigType)) { case TFun(s): s; case _: null; };
					// A constructor never returns a value: its body types in void context (FunConstructor).
					// Otherwise its inferred return monomorph can stay open (a bare `return;` keeps it
					// non-Void), and the final-return insertion then appends a value return to a void C++
					// constructor.
					var ret = tctx.curfun.match(FunConstructor) ? tctx.t.tvoid : (sig != null ? sig.ret : tctx.t.tvoid);
					var args = buildArgs(tctx, sig, fd, cff.cffPos);
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
					// The TFunction node itself also carries the body position; genxml's line attribute
					// reads it.
					cf.expr = TypeFunctions.mk(TFunction(tf), sigType, funcPos);
					// An __init__'s typed body is the class init, unless it is trivially empty.
					if (isStatic && cf.name == "__init__") switch (tf.expr.expr) {
						case TBlock([]) | TBlock([{expr: TConst(_)}]) | TConst(_) | TObjectDecl([]):
						case _: tctx.curclass.init = tf.expr;
					}
				case FProp(_, _, _, eo):
					// A physical property (e.g. (default,null)) can carry an initializer, bound to expr
					// exactly like a variable; the accessors are typed as their own get_/set_ methods.
					if (eo != null) bindVarExpression(tctx, cf, cff, sigType, eo, isStatic);
			}
		} catch (e:haxe.Exception) {
			cleanup();
			throw e;
		}
		cleanup();
		// Field display, once this field's body has bound: a cursor on its name is answered first, then
		// the modifier check.
		if (hxc.parser.Parser.displayFile != null && Typer.atDisplayPos(cf.namePos))
			Typer.displayClassField(tctx.curclass, !isStatic && cff.cffName.name == "new", cf, cf.namePos, isStatic);
		checkFieldDisplay(tctx.com, tctx.curclass, cff);
	}

	// A body-less field (a plain `var`) never reaches typeFieldBody, so its declaration is
	// checked once the class's bodies have all run.
	static function checkModifierDisplayForClass(ctx:Context, c:TClass):Void {
		if (hxc.parser.Parser.displayFile == null) return;
		// Field display for a field whose body binds; one with no expression to bind answered from the
		// field init (initFieldDisplay). The name answer only fires when the cursor is on the name.
		inline function nameDisplay(cf:TClassField, isCtor:Bool):Void {
			if (Typer.atDisplayPos(cf.namePos) && fieldHasSyntaxBody(ctx, c, cf)) Typer.displayClassField(c, isCtor, cf, cf.namePos);
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

	// A member variable initializer cannot reach this; the first occurrence reports and the walk stops.
	// bindVarExpression, inside its lazy: the initializer types (typeVarInitializer), then the arm for what
	// the field is, then checkCast keeps the field's type.
	static function bindVarExpression(tctx:TyperContext, cf:TClassField, cff:ClassField, sigType:T, eo:Expr, isStatic:Bool):Void {
		// A field initializer is outside any function (a return in it reports).
		tctx.inFunction = false;
		var externVar = TypeFunctions.hasClassFlag(tctx.curclass, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern);
		// Inline-ness is the declaration's modifier, not kind, which a @:require has already turned into
		// AccRequire.
		var isInlineVar = false;
		for (a in cff.cffAccess) if (a.access == AInline) isInlineVar = true;
		hxc.typing.ExprPreprocessing.processDisplayFieldExpr(cff.cffPos, eo);
		// The initializer types as a static's or a member's (FunStatic or FunMember), with the field state
		// saved - an abstract's `var` is static there.
		var oldFun = tctx.curfun;
		tctx.curfun = isStatic ? FunStatic : FunMember;
		var te = try typeVarInitializer(tctx, sigType, eo, hasVarHint(cff.cffKind), cff.cffPos) catch (e:Dynamic) {
			tctx.curfun = oldFun;
			throw e;
		};
		tctx.curfun = oldFun;
		tctx.inFunction = true;
		// Run the analyzer, then require a constant expression: the analyzer (always optimizing) runs
		// over anything but a constant, a local or a function, and what constant folding makes of that is
		// the value; otherwise the error, and the initializer as it was typed.
		function requireConstantExpression(e:TExpr, msg:String):TExpr {
			var ea = switch (e.expr) {
				case TConst(_) | TLocal(_) | TFunction(_): e;
				case _: hxc.optimization.Analyzer.Run.runOnExprStandalone(tctx.com, Context.sTypePath(tctx.curclass.path) + "." + cf.name, e);
			};
			var folded = hxc.optimization.Optimizer.makeConstantExpression(tctx, ea);
			if (folded != null) return folded;
			tctx.com.addDiagnostic(msg, cf.pos);
			return e;
		}
		// An unexpected expression is reported once per field.
		function unexpected(msg:String):Void {
			if (tctx.com.fieldErrorReported.exists(cff)) return;
			tctx.com.fieldErrorReported.set(cff, true);
			tctx.com.addDiagnostic(msg, cff.cffPos);
		}
		// The checks, in order.
		if (externVar) {
			if (!isStatic) unexpected("on extern non-static variable");
			else if (!isInlineVar) unexpected("on extern non-inline variable");
			else te = requireConstantExpression(te, "Extern variable initialization must be a constant value");
		} else if (!TypeFunctions.isPhysicalField(cf)) {
			unexpected("on field that is not a real variable");
		} else if (!isStatic) {
			checkThisInVarInit(tctx, te);
		} else if (cf.kind.match(Var({read: AccInline}))
				&& (tctx.com.doInline() || hxc.typing.Inline.isForcedInline(tctx.curclass, cf))) {
			te = requireConstantExpression(te, "Inline variable initialization must be a constant value");
			// An enum abstract member's value: the member's declared type unifies with the
			// abstract, at the field, then the value (a typeless cast unwrapped) with the
			// underlying type, at the value.
			switch (tctx.curclass.kind) {
				case KAbstractImpl(a) if (a.isEnum && TypeFunctions.hasClassFieldFlag(cf, CfEnum)):
					try hxc.core.TypeUnification.unifyDefault(sigType, TAbstract(a, [for (_ in a.params) TypeFunctions.mkMono()]))
					catch (ue:hxc.core.TypeUnification.UnifyError)
						tctx.com.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(ue.errors), cf.pos);
					var e1 = switch (te.expr) { case TCast(inner, null): inner; case _: te; };
					try hxc.core.TypeUnification.unifyDefault(e1.type, a.thisType)
					catch (ue:hxc.core.TypeUnification.UnifyError)
						tctx.com.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(ue.errors), e1.pos);
				case _:
			}
		}
		cf.expr = checkCast(te, sigType);
	}

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
								hxc.core.StringSort.sort(names);
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

	static function hasVarHint(k:ClassFieldKind):Bool {
		return switch (k) {
			case FVar(th, _) | FProp(_, _, th, _): th != null;
			case _: true;
		};
	}

	// The initializer types against the field's own type - its monomorph when there is no hint, which is
	// what a display inside it reports as expected - and is cast or unified to it.
	static function typeVarInitializer(tctx:TyperContext, sigType:T, eo:Expr, hasHint:Bool, p:Position):TExpr {
		return Typer.castOrUnify(tctx, sigType, Typer.typeExpr(tctx, eo, WithTypeTools.withType(sigType)), p);
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

	// The typed arguments of an abstract member other than `_new` and a macro start with the underlying
	// `this`, which no syntax declares.
	static function abstractThisOffset(tctx:TyperContext):Int {
		return tctx.curfun.match(FunMemberAbstract) && tctx.curfield.name != "_new"
			&& !tctx.curfield.kind.match(Method(MethMacro)) ? 1 : 0;
	}

	static function buildArgs(tctx:TyperContext, sig:Null<TSignature>, fd:Func, fieldPos:Position):Array<TFuncArg> {
		var result:Array<TFuncArg> = [];
		var off = abstractThisOffset(tctx);
		if (off == 1) {
			// VAbstractThis at Position.nullPos, tagged @:this and nothing else.
			var at = (sig != null && sig.args.length > 0) ? sig.args[0].t : TypeFunctions.mkMono();
			var v = TypeFunctions.allocVar(VAbstractThis, sig != null && sig.args.length > 0 ? sig.args[0].name : "this", at, hxc.ast.Position.nullPos);
			// @:this is prepended to the abstract this argument. LocalDce's `keep` tests exactly that meta,
			// so without it a store to the abstract this in an impl body reads as a dead store and is
			// removed.
			v.meta = [{name: ":this", params: [], pos: hxc.ast.Position.nullPos}].concat(v.meta);
			result.push({v: v, c: null});
		}
		// Per argument the name is checked, the default value types and then the variable is allocated.
		for (i in 0...fd.fArgs.length) {
			var fa = fd.fArgs[i];
			var at = (sig != null && i + off < sig.args.length) ? sig.args[i + off].t : TypeFunctions.mkMono();
			Typer.checkLocalVariableName(tctx, fa.name.name, TVOArgument, fa.name.pos);
			var def = typeFunctionArgValue(tctx, at, functionArgDefault(fa), fieldPos);
			var v = TypeFunctions.allocVar(VUser(TVOArgument), fa.name.name, at, fa.name.pos);
			// An argument's metadata lives on its variable.
			if (fa.meta.length > 0) v.meta = v.meta.concat(fa.meta);
			// The display is answered from the argument's own name range.
			if (Typer.atDisplayPos(fa.name.pos)) Typer.displayVariable(tctx, v, fa.name.pos);
			result.push({v: v, c: def});
		}
		return result;
	}

	// An optional argument without a default gets `null`, at Position.nullPos.
	public static function functionArgDefault(fa:FunctionArg):Null<Expr> {
		return fa.value != null ? fa.value : fa.opt ? new Expr(EConst(CIdent("null")), Position.nullPos) : null;
	}

	// typeFunctionArgValue: the default types against the argument's type and is reduced, the
	// unification is recorded, and what is kept is the constant it comes to (a typeless cast
	// unwrapped) - anything else is "Default argument value should be constant" outside a display
	// request, and no default.
	public static function typeFunctionArgValue(tctx:TyperContext, t:T, eo:Null<Expr>, ?displayFieldPos:Position):Null<TExpr> {
		if (eo == null) return null;
		var p = eo.pos;
		if (displayFieldPos != null) hxc.typing.ExprPreprocessing.processDisplayFieldExpr(displayFieldPos, eo);
		var e = hxc.optimization.Optimizer.reduceExpression(tctx, Typer.typeExpr(tctx, eo, WithTypeTools.withType(t)));
		try TypeUnification.unifyDefault(e.type, t)
		catch (ue:hxc.core.TypeUnification.UnifyError) TyperContext.raiseOrDisplay(tctx, hxc.core.TPrinting.betterErrorMessage(ue.errors), p);
		function loop(e:TExpr):Null<TExpr> {
			return switch (e.expr) {
				case TConst(_): e;
				case TField({expr: TTypeExpr(_)}, FEnum(_, _)): e;
				case TField({expr: TTypeExpr(_)}, FStatic(c2, cf2)) if (switch (c2.kind) {
						case KAbstractImpl(ab): ab.isEnum && TypeFunctions.hasClassFieldFlag(cf2, CfEnum);
						case _: false;
					}): e;
				case TCast(e1, null): loop(e1);
				case _:
					if (!tctx.com.ignoreErrors || tctx.com.isDiagnosticsRun())
						tctx.com.addDiagnostic("Default argument value should be constant", p);
					null;
			};
		}
		return loop(e);
	}

	// checkOverload: a field of an `overload` set whose signature another of the set already has (on the
	// Java target also one the JVM cannot tell apart).
	static function checkOverload(ctx:Context, f:TClassField, fs:Array<TClassField>, isExternClass:Bool):Bool {
		for (f2 in fs) if (f != f2 && Overloads.sameOverloadArgs(f.type, f2.type, f, f2)) {
			ctx.addDiagnostic("Another overloaded field of same signature was already declared : " + f.name, f.pos);
			ctx.addDiagnostic("... The second field is declared here", f2.pos, 1);
			return false;
		}
		if (ctx.platform != hxc.core.Globals.Platform.Java || isExternClass) return true;
		for (f2 in fs) if (f != f2 && Overloads.sameOverloadArgs(f.type, f2.type, f, f2, Overloads.ambiguateFuns)) {
			// Don't bother checking this on externs and assume the users know what they're doing (issue #11131)
			if (TypeFunctions.hasClassFieldFlag(f, CfExtern) && TypeFunctions.hasClassFieldFlag(f2, CfExtern)) return true;
			ctx.addDiagnostic("Another overloaded field of similar signature was already declared : " + f.name
				+ "\nThe signatures are different in Haxe, but not in the target language", f.pos);
			ctx.addDiagnostic("... The second field is declared here", f2.pos, 1);
			return false;
		}
		return true;
	}

	// checkOverloads: each `overload` set is checked field by field until one fails.
	static function checkOverloads(ctx:Context, c:TClass):Void {
		var isExtern = TypeFunctions.hasClassFlag(c, CExtern);
		function checkField(f:TClassField):Void {
			if (!TypeFunctions.hasClassFieldFlag(f, CfOverload)) return;
			var all = [f].concat(f.overloads);
			for (f in all) if (!checkOverload(ctx, f, all, isExtern)) break;
		}
		for (f in c.orderedFields) checkField(f);
		for (f in c.orderedStatics) checkField(f);
		if (c.constructor != null) checkField(c.constructor);
	}

	// checkAbstractClass: every abstract method the abstract superclass has (through its own ancestors too,
	// overloads included) needs a field of the same signature in the class itself.
	static function checkAbstractClass(ctx:Context, c:TClass, csup:TClass, params:TParams):Void {
		var missing:Array<{cf:TClassField, t:T}> = [];
		var map = function(t:T) return TypeFunctions.applyParams(csup.params, params, t);
		function checkAbstractClassField(cf1:TClassField, t1:T):Void {
			var cf2 = c.fields.get(cf1.name);
			if (cf2 == null) {
				missing.unshift({cf: cf1, t: t1});
				return;
			}
			for (o in [cf2].concat(cf2.overloads)) if (Overloads.sameOverloadArgs(t1, o.type, cf1, o)) return;
			missing.unshift({cf: cf1, t: t1});
		}
		// Every field of the superclass under its params: its fields and its ancestors', the nearest
		// declaration of each name, walked in key order.
		var cfl = new Map<String, TClassField>();
		function loop(c2:TClass):Void {
			for (cf in c2.orderedFields) if (!cfl.exists(cf.name)) cfl.set(cf.name, cf);
			if (TypeFunctions.hasClassFlag(c2, CInterface)) {
				for (i in c2.interfaces) loop(i.c);
			} else if (c2.superClass != null) loop(c2.superClass.c);
		}
		loop(csup);
		var keys = [for (k in cfl.keys()) k];
		hxc.core.StringSort.sort(keys);
		for (k in keys) {
			for (o in Overloads.collectOverloads(map, csup, cfl.get(k).name))
				if (TypeFunctions.hasClassFieldFlag(o.cf, CfAbstract)) checkAbstractClassField(o.cf, o.t);
		}
		if (missing.length == 0) return;
		var singular = missing.length == 1;
		ctx.addDiagnostic("This class extends abstract class " + Context.sTypePath(csup.path) + " but doesn't implement the following method" + (singular ? "" : "s"), c.namePos);
		ctx.addDiagnostic("Implement " + (singular ? "it" : "them") + " or make " + Context.sTypePath(c.path) + " abstract as well", c.namePos);
		var pctx = hxc.core.TPrinting.printContext();
		var l = missing.copy();
		l.reverse();
		for (m in l) {
			var s = switch (TypeFunctions.follow(m.cf.type)) {
				case TFun(sig): [for (a in sig.args) a.name + ":" + hxc.core.TPrinting.sType(pctx, a.t)].join(", ");
				case t: hxc.core.TPrinting.sType(pctx, t);
			};
			ctx.addDiagnostic("... " + m.cf.name + "(" + s + ")", m.cf.namePos, 1);
		}
	}

	static function checkExternDefaults(ctx:Context, tctx:TyperContext, cf:TClassField, fd:Func, isStatic:Bool, abstractMember:Bool):Void {
		// The extern default check runs once per field, when the field is created. The install loop
		// re-visits a module whenever its declared shape changes, and re-checking the defaults on every
		// visit would report one verdict several times.
		if (externDefaultsChecked.exists(cf)) return;
		externDefaultsChecked.set(cf, true);
		var sig = switch (TypeFunctions.follow(cf.type)) { case TFun(s): s; case _: null; };
		if (sig == null) return;
		var oldFun = tctx.curfun;
		tctx.curfun = isStatic ? FunStatic : FunMember;
		// The delay runs in the field's own typer context, whose module is the class's - what an
		// unqualified name in a default value resolves against.
		var oldModule = ctx.currentModule;
		if (tctx.curclass != null && tctx.curclass.module != null) ctx.currentModule = tctx.curclass.module;
		// The signature starts with the abstract member's `this`, which the declared arguments do not.
		var off = abstractMember && cf.name != "_new" && !cf.kind.match(Method(MethMacro)) ? 1 : 0;
		for (i in 0...fd.fArgs.length) {
			var value = fd.fArgs[i].value;
			if (value == null || i + off >= sig.args.length) continue;
			try Typer.castOrUnify(tctx, sig.args[i + off].t, Typer.typeExpr(tctx, value, WithTypeTools.withType(sig.args[i + off].t)), value.pos)
			catch (e:Dynamic) recordFieldError(ctx, e);
		}
		ctx.currentModule = oldModule;
		tctx.curfun = oldFun;
	}
}
