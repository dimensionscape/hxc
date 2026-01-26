package hxc.context;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals.Path;
import hxc.core.Globals.Platform;
import hxc.core.Globals.MessageSeverity;
import hxc.core.WarningList.WarningMode;
import hxc.core.WarningList.WarningOption;
import hxc.core.Define;
import haxe.ds.StringMap;

class Context {
	/**
	 * Bundled standard library and target overlays used by class-path setup, from HAXE_STD_PATH.
	 */
	public var stdPath:Array<String>;

	/** The compiler arguments after hxml expansion, for Compiler.getConfiguration(). */
	public var args:Array<String> = [];

	/**
	 * Display-request files and their unsaved contents; null reads from disk. Diagnostics requests
	 * supply the complete file set.
	 */
	public var fileContents:Array<{file:String, contents:Null<String>}> = [];
	// Context.onTypeNotFound loaders for modules absent from the class path.
	public var loadExternType:Array<{name:String, load:hxc.core.Globals.Path->hxc.ast.Position->Null<Array<hxc.ast.Ast.TypeDecl>>}> = [];

	/**
	 * Global metadata registrations: dot-path filter and recursive, type and field flags.
	 */
	public var globalMetadata:Array<{filter:Array<String>, meta:hxc.ast.Ast.MetadataEntry, recursive:Bool, toTypes:Bool, toFields:Bool}> = [];

	/**
	 * Module-check policies and their dot-path filters, including recursive matching.
	 */
	public var moduleCheckPolicies:Array<{filter:Array<String>, policy:Array<hxc.core.Type.ModuleCheckPolicy>, recursive:Bool}> = [];

	/**
	 * Deprecated Compiler type patches, keyed by type and optional field, applied during module
	 * loading.
	 */
	public var typePatches:Array<{path:Path, field:Null<String>, isStatic:Bool, meta:hxc.ast.Ast.Metadata, remove:Bool, typeHint:Null<hxc.ast.Ast.TypeHint>}> = [];

	/**
	 * Registered null-safety callbacks receive errors instead of failing compilation.
	 */
	public var nullSafetyReportCallbacks:Array<Array<{msg:String, pos:hxc.ast.Position}>->Void> = [];

	public var classPath:Array<String>;

	/** Command-line package remaps, keyed by the first package segment. */
	public var packageRemaps:StringMap<String>;
	// Forbidden target packages, excluding those allowed by Compiler.allowPackage. Remaps are stored
	// separately.
	public var forbiddenPackages:StringMap<Bool>;
	// Compiler.includeFile entries: resolved path and top, inline or closure placement.
	public var includeFiles:Array<{file:String, position:String}> = [];

	/**
	 * Compile-time defines populated by command-line flags and platform setup.
	 */
	public var defines:Define;

	public var platform:Platform = Cross;
	public var platformConfig:PlatformConfig = PlatformConfig.defaults();
	// --c-arg values and Compiler.addNativeArg, newest first.
	public var cArgs:Array<String> = [];

	// True only in the macro-world context, including when macro is temporarily defined during host
	// build-macro parsing.
	public var isMacro:Bool = false;
	// The macro com's error hook; the interpreter marks itself as having had an error.
	public static var onMacroWorldError:Null<Void->Void> = null;

	public var mainClass:Null<Path>;

	public var displaySpec:Null<String>;

	/**
	 * Position-specific display modes type only the cursor's field and bodies demanded by it.
	 */
	public var displayFullTyping:Bool = true;
	// Suppress errors that would prevent an answer to a position-specific display request.
	public var ignoreErrors:Bool = false;

	// Serialized JSON-RPC request ID used when reporting the display response.
	public var jsonRpcId:Null<String>;

	/** Key = `pathKey`. */
	public var moduleLut:StringMap<ModuleDef>;

	/**
	 * Type path to defining module path; one module may define several types.
	 */
	public var typeToModule:StringMap<Path>;

	/**
	 * Track registration epochs to distinguish redefinitions from entries retained by a reused macro
	 * context. Keep the map for generic module lookup.
	 */
	public var typeToModuleEpoch:StringMap<Int>;

	public var compilationEpoch:Int = 0;

	public var moduleNonexistentLut:StringMap<Bool>;

	/** Registration order. */
	public var modules:Array<ModuleDef>;

	/** All loaded types, registration order. */
	public var types:Array<ModuleType>;
	// The macro API sees no module types until Finalization.run fills com.types.
	public var typesGenerated:Bool = false;

	/** Embedded resources from `--resource file@name`. */
	public var resources:StringMap<haxe.io.Bytes>;

	/**
	 * Resource insertion order used to reconstruct generator hash-table traversal.
	 */
	public var resourceOrder:Array<String>;

	public function addResource(name:String, data:haxe.io.Bytes):Void {
		if (!resources.exists(name)) resourceOrder.push(name);
		resources.set(name, data);
	}

	public var debug:Bool = false;

	/** False under --no-opt: expression reduction is skipped. */
	public var foptimize:Bool = true;

	/** Target output file or directory (-js file, -cpp dir). */
	public var file:String = "";

	/**
	    Feature flags read by the generators, committed from module features after DCE.
	*/
	public var features:StringMap<Bool>;

	/**
	 * Finalization's entry expression: main() call plus entry-point or event-loop tail.
	 */
	public var main:Null<TExpr> = null;
	public var jsGen:Null<Void->Void> = null;

	public var initMacros:Array<String>;

	// Set after init macros complete; init-only Compiler APIs warn beyond this stage.
	public var initMacrosDone:Bool = false;

	public var declOfType:StringMap<{decl:TypeDef, pos:Position}>;

	/**
	 * Types whose declarations failed resolution. Skip their unbound fields and bodies to avoid
	 * cascading inherited-member errors.
	 */
	public var declErrored:StringMap<Bool> = new StringMap();

	/**
	 * Modules with incomplete declaration initialization, keyed by path. An unresolved using prevents
	 * initialization of every declaration in the module.
	 */
	public var moduleAborted:StringMap<Bool> = new StringMap();

	/**
	 * Count unresolved field annotations; each retains a placeholder monomorph while resolution
	 * continues.
	 */
	public var unresolvedFields:Int = 0;

	// A declaration failure aborts remaining field typing, parameter following and PForce work; retain
	// diagnostics already recorded.
	public var declAborted:Bool = false;

	// Release field diagnostics only after heritage succeeds. Keep warnings and errors in the same
	// insertion-ordered queue so neither overtakes the other.
	final pendingFieldDiagnostics = new haxe.ds.ObjectMap<hxc.core.Type.TClass, Array<{msg:String, pos:hxc.ast.Position,
		?warn:hxc.core.WarningList.Warning, ?warnOptions:Array<Array<hxc.core.WarningList.WarningOption>>}>>();

	public function deferFieldDiagnostic(c:hxc.core.Type.TClass, msg:String, pos:hxc.ast.Position):Void {
		var l = pendingFieldDiagnostics.get(c);
		if (l == null) { l = []; pendingFieldDiagnostics.set(c, l); }
		l.push({msg: msg, pos: pos});
	}

	// Unbound abstract fields tagged @:noExpr never trigger macro forcing, including host-side macro
	// fields without bodies.
	public final abstractNoExprFields = new haxe.ds.ObjectMap<hxc.core.Type.TClassField, Bool>();

	// Record @:to arity results against syntax before the implementation class exists, then transfer
	// them to typed fields in the same pass.
	public final abstractToArityFailed = new haxe.ds.ObjectMap<hxc.ast.Ast.ClassField, Bool>();

	public function deferFieldWarning(c:hxc.core.Type.TClass, w:hxc.core.WarningList.Warning,
			options:Array<Array<hxc.core.WarningList.WarningOption>>, msg:String, pos:hxc.ast.Position):Void {
		var l = pendingFieldDiagnostics.get(c);
		if (l == null) { l = []; pendingFieldDiagnostics.set(c, l); }
		l.push({msg: msg, pos: pos, warn: w, warnOptions: options});
	}

	// Discard old declaration diagnostics when a build macro replaces the class fields.
	public function dropFieldDiagnostics(c:hxc.core.Type.TClass):Void {
		pendingFieldDiagnostics.remove(c);
	}

	public function flushFieldDiagnostics(c:hxc.core.Type.TClass):Void {
		var l = pendingFieldDiagnostics.get(c);
		if (l == null) return;
		pendingFieldDiagnostics.remove(c);
		for (d in l) if (d.warn != null) warning(d.warn, d.warnOptions, d.msg, d.pos) else addDiagnostic(d.msg, d.pos);
	}

	public var diagnostics:Array<CompilerDiagnostic>;
	// Capture unresolved-identifier candidates when typing fails; the typer context is gone by
	// diagnostics reporting.
	public var unresolvedIdentifiers:Array<{name:String, pos:Position, suggestions:Array<{kind:Int, name:String}>}> = [];
	// Group missing-field diagnostics by position and emit one DKMissingFields with its owning module
	// type.
	public var missingFields:Array<{pos:Position, on:ModuleType, scope:hxc.core.Type.ClassFieldScope,
		fields:Array<{cf:hxc.core.Type.TClassField, t:T,
			// Serialize completion types when recording the diagnostic, before filters bind open monomorphs
			// to Dynamic.
			ct:hxc.core.CompletionItem.CompletionType}>, cause:String}> = [];

	public var warningOptions:Array<Array<hxc.core.WarningList.WarningOption>>;

	// Track imported modules per context; macro-world loads must not suppress host-world loads.
	public var plainImportsTried:StringMap<Bool> = new StringMap();

	// Cache directory listings per context and clone, preventing stale filesystem views across
	// requests. Map lowercase names to actual entries; null means listing failed.
	public var readdirCache:StringMap<Null<StringMap<String>>> = new StringMap();

	/**
	 * Per-context declared-field fingerprints let installLazy skip unchanged modules. Host and macro
	 * worlds sweep independently.
	 */
	public var lazyInstalled:StringMap<Int> = new StringMap();

	/**
	 * Key syntax declarations by typed field identity; rebuildFields creates new fields and
	 * invalidates old entries.
	 */
	public var fieldDeclCache:haxe.ds.ObjectMap<TClassField, {d:Null<hxc.ast.Ast.ClassField>}> = new haxe.ds.ObjectMap();
	// Exclude rejected same-name declarations from later syntax-to-field pairing so their hints cannot
	// retype the accepted field.
	public var droppedFieldDecls:haxe.ds.ObjectMap<hxc.ast.Ast.ClassField, Bool> = new haxe.ds.ObjectMap();

	public var moduleImports:StringMap<ModuleImports>;

	public var currentModule:Null<ModuleDef> = null;
	// Current signature-resolution class, used to resolve a bare static identifier in
	// MacroType<[f()]>.
	public var resolvingClass:Null<hxc.core.Type.TClass> = null;

	public var callArgumentStack:Array<Array<Expr>>;

	// Custom define and metadata documentation is registered by init macros. Run display/metadata and
	// display/defines callbacks after those registrations finish.
	public var afterInitMacros:Array<Void->Void> = [];
	public var userDefines:StringMap<UserDocEntry>;
	public var userMetas:StringMap<UserDocEntry>;

	public var storedTypedExprs:Map<Int, TExpr>;

	// One id sequence across every context, host and macro alike.
	public static var nextStoredTypedExprId:Int = 0;

	// Increment before allocating a stored-expression ID. HXC_STE_DBG traces the allocation site.
	public static function allocStoredTypedExprId(tag:String):Int {
		var id = ++nextStoredTypedExprId;
		if (Sys.getEnv("HXC_STE_DBG") != null) Sys.stderr().writeString("[STE] " + id + " " + tag + "\n");
		return id;
	}

	// Constraint checks deferred by loadInstance until all module fields are typed, at
	// PCheckConstraint.
	public var pendingConstraintChecks:Array<Void->Void> = [];

	public static inline var PBuildModule = 0;
	public static inline var PBuildClass = 1;
	public static inline var PConnectField = 2;
	public static inline var PTypeField = 3;
	public static inline var PCheckConstraint = 4;
	public static inline var PForce = 5;
	public static inline var PFinal = 6;

	// Ascending pass order, LIFO within each pass; class finalization relies on reversed field
	// insertion.
	public var delayed:Array<{pass:Int, fns:Array<Void->Void>}> = [];

	public function delay(pass:Int, f:Void->Void):Void {
		var idx = 0;
		while (idx < delayed.length && delayed[idx].pass < pass) idx++;
		if (idx < delayed.length && delayed[idx].pass == pass) delayed[idx].fns.unshift(f);
		else delayed.insert(idx, {pass: pass, fns: [f]});
	}

	public function flushPass(pass:Int):Void {
		while (delayed.length > 0 && delayed[0].pass <= pass) {
			var bucket = delayed[0];
			if (bucket.fns.length == 0) delayed.shift();
			else bucket.fns.shift()();
		}
	}

	/**
	 * Initialize from loaded StdTypes, String and Array declarations; retain safe placeholders until
	 * loading completes.
	 */
	public var basic:BasicTypes;

	// Settable compilation callbacks let the typer and macro interpreter reenter module loading,
	// output and diagnostics.

	/**
	 * Macro getType callback, attached by ModuleLoader. sub selects an in-module type.
	 */
	public var getType:Path->Position->?String->ModuleType;

	/**
	 * Macro parse callback: source string to expression AST.
	 */
	public var parse:String->Position->Expr;

	/**
	 * Macro defineType callback for build-macro type registration; the default raises.
	 */
	public var defineType:ModuleType->Void;

	public var follow:T->T;

	public var print:String->Void;

	/**
	 * The default error callback raises.
	 */
	public var error:String->Position->Void;

	public function new(?classPath:Array<String>, ?defines:Define) {
		this.stdPath = [];
		this.classPath = classPath == null ? [] : classPath;
		this.packageRemaps = new StringMap();
		this.forbiddenPackages = new StringMap();
		this.defines = defines == null ? new Define() : defines;
		this.mainClass = null;
		this.displaySpec = null;
		this.displayFullTyping = true;
		this.moduleLut = new StringMap();
		this.typeToModule = new StringMap();
		this.typeToModuleEpoch = new StringMap();
		this.moduleNonexistentLut = new StringMap();
		this.modules = [];
		this.types = [];
		this.resources = new StringMap();
		this.resourceOrder = [];
		this.features = new StringMap();
		this.initMacros = [];
		this.declOfType = new StringMap();
		this.diagnostics = [];
		// Initialize default-disabled warnings with WMDisable options.
		this.warningOptions = [[for (w in hxc.core.WarningList.disabledWarnings) {warning: w, mode: WMDisable}]];
		this.moduleImports = new StringMap();
		this.callArgumentStack = [];
		this.userDefines = new StringMap();
		this.userMetas = new StringMap();
		this.storedTypedExprs = new Map();
		// Keep basic types non-null until ModuleLoader.initBasicTypes loads their declarations.
		this.basic = TypeFunctions.makeStubBasicTypes();

		this.getType = function(p:Path, pos:Position, ?sub:String):ModuleType {
			// Keep the throw in a Void helper so Haxe retains the return required by hxcpp/MSVC (C4716).
			Context.seamNotAttached("getType seam not attached (call ModuleLoader.attach)", pos);
			return null;
		};
		this.parse = function(s:String, pos:Position):Expr {
			return hxc.parser.Parser.parseExprString(s, pos.file, this.defines);
		};
		this.defineType = function(mt:ModuleType):Void {
			throw new ContextError("defineType seam not attached", Position.nullPos);
		};
		this.follow = function(t:T):T return TypeFunctions.follow(t);
		this.print = function(s:String):Void {};
		this.error = function(msg:String, pos:Position):Void {
			throw new ContextError(msg, pos);
		};
	}

	// Clone configuration with separate module tables and macro defines so host modules remain
	// unchanged.
	public function cloneForMacro():Context {
		// Remove target overlays and prepend eval/_std before user and library paths. Otherwise libraries
		// such as hxnodejs can supply incompatible macro-world sys modules.
		var macroCp = [for (s in this.classPath) if (StringTools.replace(s, "\\", "/").indexOf("/_std/") < 0) s];
		macroCp = [for (p in this.stdPath) p + "eval/_std/"].concat(macroCp);
		var c = new Context(macroCp, Define.adaptToMacroContext(this.defines));
		c.stdPath = this.stdPath.copy();
		for (source in this.packageRemaps.keys()) c.packageRemaps.set(source, this.packageRemaps.get(source));
		// Initialize eval platform defines in the macro world so sys-dependent APIs remain available even
		// with a non-sys host target.
		hxc.context.Setup.initPlatform(c, Eval);
		c.isMacro = true;
		// Share missing-path results with the host so later extern-loader hooks are not called again for
		// known misses.
		c.moduleNonexistentLut = this.moduleNonexistentLut;
		// Forward macro-world warnings to the main context; keep macro recovery diagnostics local.
		c.forwardWarningsTo = this;
		// Copy debug settings while starting a fresh feature table.
		c.debug = this.debug;
		for (name in this.resourceOrder) c.addResource(name, this.resources.get(name));
		c.initMacros = this.initMacros.copy();
		// Copy unsaved display contents into the macro world.
		c.fileContents = this.fileContents.copy();
		// Preserve the host's display error policy and diagnostics file set in the clone.
		c.moduleNonexistentLut = this.moduleNonexistentLut;
		c.ignoreErrors = this.ignoreErrors;
		c.diagnosticsFileFilter = this.diagnosticsFileFilter;
		return c;
	}

	public function addFeature(f:String):Void {
		features.set(f, true);
	}

	public function hasDce():Bool {
		return defines.rawDefinedValueSafe("dce", "no") != "no";
	}

	public function isDirectlyUsed(meta:Metadata):Bool {
		return !hasDce() || TypeFunctions.hasMeta(":directlyUsed", meta);
	}

	// Memoize feature lookups against loaded types and DCE metadata; a bare name checks name.*.
	public function hasFeature(f:String):Bool {
		var cached = features.get(f);
		if (cached != null) return cached;
		if (types.length == 0) return !hasDce();
		var parts = f.split(".");
		if (parts.length == 0) throw new ContextError("empty feature name", Position.nullPos);
		if (parts.length == 1) return hasFeature(parts[0] + ".*");
		var field = parts[parts.length - 1];
		var cl = parts[parts.length - 2];
		var pack = parts.slice(0, parts.length - 2);
		var found:Null<ModuleType> = null;
		for (t in types) {
			var tp = TypeFunctions.tPath(t);
			if (tp.name == cl && tp.pack.length == pack.length && !TypeFunctions.hasMeta(":realPath", TypeFunctions.tInfos(t).meta)) {
				var same = true;
				for (i in 0...pack.length) if (tp.pack[i] != pack[i]) { same = false; break; }
				if (same) { found = t; break; }
			}
		}
		var r = if (found == null) {
			false;
		} else if (field == "*") {
			!hasDce() || switch (found) {
				case TAbstractDecl(a): TypeFunctions.hasMeta(":valueUsed", a.meta);
				case _: TypeFunctions.hasMeta(":used", TypeFunctions.tInfos(found).meta);
			};
		} else switch (found) {
			case TClassDecl(c) if (TypeFunctions.hasClassFlag(c, CExtern) && (platform != Js || (cl != "Array" && cl != "Math"))):
				if (!hasDce()) true else {
					var cf = c.statics.get(field);
					if (cf == null) cf = c.fields.get(field);
					cf != null && TypeFunctions.hasMeta(":used", cf.meta);
				}
			case TClassDecl(c):
				c.statics.exists(field) || c.fields.exists(field);
			case _:
				false;
		}
		features.set(f, r);
		return r;
	}

	public function commitFeatures(t:ModuleType):Void {
		var m = TypeFunctions.tInfos(t).module;
		for (k in m.extra.features.keys()) addFeature(k);
	}

	public function getEsVersion():Int {
		var v = Std.parseInt(defines.rawDefinedValueSafe("js_es", ""));
		return v == null ? 0 : v;
	}

	public static function pathKey(path:Path):String {
		return path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name;
	}

	public static function sTypePath(path:Path):String return pathKey(path);

	/**
	 * Void throw helper that keeps the trailing return reachable for hxcpp/MSVC.
	 */
	public static function seamNotAttached(msg:String, pos:Position):Void {
		throw new ContextError(msg, pos);
	}

	// During macro expression typing, raise errors immediately so the macro can catch and annotate
	// them.
	public var raiseTypingErrors:Bool = false;
	// An error overlapping the pattern-probe span aborts that probe; errors outside it remain
	// reportable.
	public var catchErrorsSpan:Null<Position> = null;
	// Forward diagnostics to this context, normally from the macro world to its host.
	public var forwardWarningsTo:Null<Context> = null;

	// During macro-result typing, relocate positionless diagnostics to the macro call.
	public var relocateNullPosTo:Null<Position> = null;

	public function addDiagnostic(message:String, pos:Position, depth:Int = 0, ?severity:MessageSeverity):Void {
		// Relocate null positions only in diagnostics. Keep AST positions unchanged for generated code.
		if (relocateNullPosTo != null && pos != null && pos.min < 0 && pos.max < 0 && pos.file == Position.nullPos.file)
			pos = relocateNullPosTo;
		if (catchErrorsSpan != null && pos != null && (severity == null || severity == Error)
			&& pos.file == catchErrorsSpan.file && pos.max >= catchErrorsSpan.min && pos.min <= catchErrorsSpan.max)
			throw new hxc.core.TypingError(message, pos, depth);
		if (raiseTypingErrors && (severity == null || severity == Error))
			throw new hxc.core.TypingError(message, pos, depth);
		// Forward macro-world diagnostics to the host. Mark interpreter errors so later macro calls are
		// skipped for this compilation.
		if (isMacro && (severity == null || severity == Error) && onMacroWorldError != null) onMacroWorldError();
		if (forwardWarningsTo != null)
			forwardWarningsTo.addDiagnostic(message, pos, depth, severity);
		// Keep a local diagnostic copy for report-once checks even when forwarding it to the host.
		if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null)
			Sys.println("[diag" + (isMacro ? ":macro" : "") + " #" + diagnostics.length + (forwardWarningsTo != null ? " fwd" : "") + "] " + message.split("
")[0]);
		diagnostics.push({message: message, pos: pos, depth: depth, severity: severity == null ? Error : severity});
		// Errors outside a macro call's span gain a Called from macro here entry one level deeper.
		// Relocated errors inside the call do not.
		var span = relocateNullPosTo;
		if (span != null && (severity == null || severity == Error) && pos != null
				&& (pos.file != span.file || pos.max < span.min || pos.min > span.max))
			diagnostics.push({message: "... Called from macro here", pos: span, depth: depth + 1, severity: Error});
	}

	// Printed errors use ordinary diagnostic routing but are excluded from diagnostics-report
	// findings.
	public function addPrintedError(message:String, pos:Position, depth:Int = 0):Void {
		addDiagnostic(message, pos, depth);
		var last = diagnostics[diagnostics.length - 1];
		if (last != null && last.message == message) last.printedOnly = true;
	}

	public function remapPath(path:Path):Path {
		if (path.pack.length == 0) return path;
		var target = packageRemaps.get(path.pack[0]);
		if (target == null) return path;
		var pack = path.pack.copy();
		pack[0] = target;
		return {pack: pack, name: path.name};
	}

	// Record a caught typing error with its call chain when present.
	public function addTypingError(message:String, pos:Position, depth:Int, stack:Null<Array<{message:String, pos:Position, ?depth:Int}>>):Void {
		if (stack != null) addDiagnosticStack(stack, depth) else addDiagnostic(message, pos, depth);
	}

	public function addDiagnosticStack(stack:Array<{message:String, pos:Position, ?depth:Int}>, depth:Int = 0, ?severity:MessageSeverity):Void {
		if (stack.length == 0) return;
		var sev = severity == null ? Error : severity;
		addDiagnostic(stack[0].message, stack[0].pos, depth, sev);
		// Entries with explicit depths keep them; remaining entries are nested under the stack head.
		for (i in 1...stack.length) addDiagnostic(stack[i].message, stack[i].pos, stack[i].depth != null ? stack[i].depth : depth + 1, sev);
	}

	// Drop disabled warnings; prefix enabled non-generic warnings with (WName).
	public function warning(w:hxc.core.WarningList.Warning, options:Array<Array<hxc.core.WarningList.WarningOption>>, message:String, pos:Position, depth:Int = 0):Void {
		switch (hxc.core.WarningList.getMode(w, options.concat(warningOptions))) {
			case WMEnable:
				var obj = hxc.core.WarningList.warningObj(w);
				var msg = obj.generic ? message : "(" + obj.name + ") " + message;
				if (forwardWarningsTo != null) forwardWarningsTo.diagnostics.push({message: msg, pos: pos, depth: depth, severity: MessageSeverity.Warning});
				else diagnostics.push({message: msg, pos: pos, depth: depth, severity: MessageSeverity.Warning});
			case WMDisable:
		}
	}

	public function info(message:String, pos:Position, depth:Int = 0):Void {
		diagnostics.push({message: message, pos: pos, depth: depth, severity: Information});
	}

	public function hasDiagnostics():Bool {
		return diagnostics.length > 0;
	}

	// Distinguish reported diagnostics from the context's error flag; ignored or parse errors can set
	// the flag without a message.
	public function hasReportedError():Bool {
		for (d in diagnostics) if (d.severity == Error) return true;
		return false;
	}

	// Only addPrintedError sets this flag; ordinary diagnostics do not. Display processing
	// distinguishes the two.
	public function hasPrintedError():Bool {
		for (d in diagnostics) if (d.printedOnly == true && d.severity == Error) return true;
		return false;
	}

	public function hasError():Bool {
		if (forcedError) return true;
		for (d in diagnostics) if (d.severity == Error) return true;
		return false;
	}

	// Swallowed errors still mark the compilation as errored so the server cannot cache its modules.
	public var forcedError:Bool = false;

	// Position-specific display modes use EPIgnore; compilation-reporting modes do not.
	public function ignoreError():Bool {
		if (!ignoreErrors) return false;
		forcedError = true;
		return true;
	}

	// In diagnostics mode, errors in the requested file set are findings rather than failures.
	public var diagnosticsFileFilter:Null<String->Bool> = null;

	// Temporarily disable diagnostics collection for internal typing, such as macro APIs and pattern
	// probes, so callers can catch errors.
	public function disableReportMode():Void->Void {
		var old = diagnosticsFileFilter;
		diagnosticsFileFilter = null;
		return function() diagnosticsFileFilter = old;
	}

	// The diagnostics file filter is set only for diagnostics report modes.
	public function isDiagnosticsRun():Bool {
		return diagnosticsFileFilter != null;
	}

	public function errorInDiagnosticsRun(p:Position):Bool {
		if (diagnosticsFileFilter == null) return false;
		if (!diagnosticsFileFilter(p.file)) return false;
		forcedError = true;
		return true;
	}

	public function errorCount():Int {
		var n = 0;
		for (d in diagnostics) if (d.severity == Error) n++;
		return n;
	}
}

// Custom define or metadata registration: documentation, parameters, platforms and source library.
typedef UserDocEntry = {
	var doc:String;
	var params:Array<String>;
	var platforms:Array<String>;
	// UsedOn restricts metadata declarations; Link supplies documentation URLs.
	var targets:Array<String>;
	var links:Array<String>;
	var source:Null<String>;
}

typedef CompilerDiagnostic = {
	var message:String;
	var pos:Position;
	var depth:Int;
	var severity:MessageSeverity;
	// MessageKind for diagnostics-mode JSON output; null reads as DKCompilerMessage.
	var ?kind:Int;
	/**
	 * Exclude printed-only errors from JSON diagnostics while retaining them for ordinary compiler
	 * output.
	 */
	var ?printedOnly:Bool;
};

class ContextError {
	public var message:String;
	public var pos:Position;
	public var kind:ContextErrorKind;
	public var depth:Int;

	public static var msgCounts:haxe.ds.StringMap<Int> = new haxe.ds.StringMap();
	public function new(message:String, pos:Position, ?kind:ContextErrorKind, depth:Int = 0) {
		hxc.core.PerfCount.exn("ContextError");
		if (hxc.core.PerfCount.exnDbg) {
			// Group construction counts by message prefix.
			var k = message.length > 24 ? message.substr(0, 24) : message;
			var c = msgCounts.get(k);
			msgCounts.set(k, c == null ? 1 : c + 1);
		}
		this.message = message;
		this.pos = pos;
		this.kind = kind == null ? Other : kind;
		this.depth = depth;
	}

	public function toString():String {
		return 'ContextError($message @ ${pos})';
	}
}

enum ContextErrorKind {
	ModuleNotFound(path:Path);
	TypeNotFound(path:Path);
	Other;
}

@:structInit
class ModuleImports {
	public var names:StringMap<ImportedName>;
	// Import bindings resolve in reverse declaration order, so the last import wins. Do not use
	// StringMap hash order.
	public var order:Array<ImportedName>;
	public var wildcards:Array<Path>;
	public var usings:Array<Path>;
	public var globals:StringMap<ImportedGlobal>;
	public var rawImports:Array<Import>;
	// Load using modules eagerly in declaration order, with importPositions indices, so resolution
	// errors retain their place among imports.
	public var rawUsings:Array<{path:Array<PlacedName>, pos:Position, idx:Int}> = [];
	// Track usage per import declaration. Unset flags become unused-import diagnostics; wildcardImp
	// and usingImp index these flags.
	public var importPositions:Array<{p:Position, used:Bool, ?failed:Bool}> = [];
	public var wildcardImp:Array<Int> = [];
	public var usingImp:Array<Int> = [];

	public function addImportPosition(p:Position):Int {
		for (i in 0...importPositions.length) {
			var e = importPositions[i];
			if (e.p.min == p.min && e.p.max == p.max && e.p.file == p.file) return i;
		}
		importPositions.push({p: p, used: false});
		return importPositions.length - 1;
	}

	/**
	 * Declaration-order index across imports and usings, assigned by addImportPosition.
	 */
	public function importPositionIndex(p:Position):Int {
		for (i in 0...importPositions.length) {
			var e = importPositions[i];
			if (e.p.min == p.min && e.p.max == p.max && e.p.file == p.file) return i;
		}
		return -1;
	}

	public function markImport(idx:Null<Int>):Void {
		if (idx != null && idx >= 0 && idx < importPositions.length) importPositions[idx].used = true;
	}

	// Failed imports must not produce unused-import diagnostics. Mark their preregistered positions as
	// failed.
	public function markImportFailed(p:Position):Void {
		for (e in importPositions)
			if (e.p.min == p.min && e.p.max == p.max && e.p.file == p.file) { e.failed = true; return; }
	}

	static function samePath(a:Path, b:Path):Bool {
		if (a.name != b.name || a.pack.length != b.pack.length) return false;
		for (i in 0...a.pack.length) if (a.pack[i] != b.pack[i]) return false;
		return true;
	}

	public function markWildcard(w:Path):Void {
		for (i in 0...wildcards.length) if (i < wildcardImp.length && samePath(wildcards[i], w)) { markImport(wildcardImp[i]); return; }
	}

	public function markUsing(u:Path):Void {
		for (i in 0...usings.length) if (i < usingImp.length && samePath(usings[i], u)) { markImport(usingImp[i]); return; }
	}

	public function new(names:StringMap<ImportedName>, wildcards:Array<Path>, usings:Array<Path>, ?globals:StringMap<ImportedGlobal>, ?rawImports:Array<Import>, ?order:Array<ImportedName>) {
		this.names = names;
		this.order = order != null ? order : [];
		this.wildcards = wildcards;
		this.usings = usings;
		this.globals = globals != null ? globals : new StringMap();
		this.rawImports = rawImports != null ? rawImports : [];
	}
}

/**
 * Short-name binding to a module and optional subtype. The map key is the referenced alias, subtype
 * or module name.
 */
typedef ImportedName = {modulePath:Path, sub:Null<String>, ?aliased:Bool, ?aliasName:String, ?aliasPos:Position, ?aliasTypedef:ModuleType, ?impIdx:Int};

/**
 * Resolved static-field import: owning module, optional subtype and static field or enum
 * constructor.
 */
typedef ImportedGlobal = {ownerPath:Path, ownerSub:Null<String>, field:String, ?impIdx:Int};
