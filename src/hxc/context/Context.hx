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
	// Compiler.includeFile entries: resolved path and top, inline or closure placement.
	public var includeFiles:Array<{file:String, position:String}> = [];

	/**
	 * Compile-time defines populated by command-line flags and platform setup.
	 */
	public var defines:Define;

	public var platform:Platform = Cross;
	public var platformConfig:PlatformConfig = PlatformConfig.defaults();

	// True only in the macro-world context, including when macro is temporarily defined during host
	// build-macro parsing.
	public var isMacro:Bool = false;

	public var mainClass:Null<Path>;

	public var displaySpec:Null<String>;
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

	public var moduleNonexistentLut:StringMap<Bool>;

	/** Registration order. */
	public var modules:Array<ModuleDef>;

	/** All loaded types, registration order. */
	public var types:Array<ModuleType>;

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
	 * Count unresolved field annotations; each retains a placeholder monomorph while resolution
	 * continues.
	 */
	public var unresolvedFields:Int = 0;

	public var diagnostics:Array<CompilerDiagnostic>;
	// Capture unresolved-identifier candidates when typing fails; the typer context is gone by
	// diagnostics reporting.
	public var unresolvedIdentifiers:Array<{name:String, pos:Position, suggestions:Array<{kind:Int, name:String}>}> = [];
	public var warningOptions:Array<Array<hxc.core.WarningList.WarningOption>>;

	public var moduleImports:StringMap<ModuleImports>;

	public var currentModule:Null<ModuleDef> = null;

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
		this.defines = defines == null ? new Define() : defines;
		this.mainClass = null;
		this.displaySpec = null;
		this.moduleLut = new StringMap();
		this.typeToModule = new StringMap();
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
		// Replace target overlays with eval/_std before loading macro modules; target-specific bodies may
		// use unavailable syntax.
		var macroCp = [for (s in this.classPath)
			if (this.stdPath.indexOf(s) < 0 && !StringTools.endsWith(StringTools.replace(s, "\\", "/"), "/_std/")) s];
		macroCp = macroCp.concat([for (p in this.stdPath) p + "eval/_std/"]).concat(this.stdPath);
		var c = new Context(macroCp, Define.adaptToMacroContext(this.defines));
		c.stdPath = this.stdPath.copy();
		for (source in this.packageRemaps.keys()) c.packageRemaps.set(source, this.packageRemaps.get(source));
		// Initialize eval platform defines in the macro world so sys-dependent APIs remain available even
		// with a non-sys host target.
		hxc.context.Setup.initPlatform(c, Eval);
		c.isMacro = true;
		// Forward macro-world warnings to the main context; keep macro recovery diagnostics local.
		c.forwardWarningsTo = this;
		// Copy debug settings while starting a fresh feature table.
		c.debug = this.debug;
		for (name in this.resourceOrder) c.addResource(name, this.resources.get(name));
		c.initMacros = this.initMacros.copy();
		// Copy unsaved display contents into the macro world.
		c.fileContents = this.fileContents.copy();
		// Cloning preserves display error recovery, so unresolved macro-argument types recover to Dynamic
		// in both worlds.
		c.ignoreErrors = this.ignoreErrors;
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
	// Forward diagnostics to this context, normally from the macro world to its host.
	public var forwardWarningsTo:Null<Context> = null;

	public function addDiagnostic(message:String, pos:Position, depth:Int = 0, ?severity:MessageSeverity):Void {
		if (raiseTypingErrors && (severity == null || severity == Error))
			throw new hxc.core.TypingError(message, pos, depth);
		if (forwardWarningsTo != null && severity != null && severity != Error) {
			forwardWarningsTo.addDiagnostic(message, pos, depth, severity);
			return;
		}
		diagnostics.push({message: message, pos: pos, depth: depth, severity: severity == null ? Error : severity});
	}

	public function remapPath(path:Path):Path {
		if (path.pack.length == 0) return path;
		var target = packageRemaps.get(path.pack[0]);
		if (target == null) return path;
		var pack = path.pack.copy();
		pack[0] = target;
		return {pack: pack, name: path.name};
	}

	public function addDiagnosticStack(stack:Array<{message:String, pos:Position}>, depth:Int = 0, ?severity:MessageSeverity):Void {
		if (stack.length == 0) return;
		var sev = severity == null ? Error : severity;
		addDiagnostic(stack[0].message, stack[0].pos, depth, sev);
		for (i in 1...stack.length) addDiagnostic(stack[i].message, stack[i].pos, depth + 1, sev);
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
};

class ContextError {
	public var message:String;
	public var pos:Position;
	public var kind:ContextErrorKind;
	public var depth:Int;

	public function new(message:String, pos:Position, ?kind:ContextErrorKind, depth:Int = 0) {
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
