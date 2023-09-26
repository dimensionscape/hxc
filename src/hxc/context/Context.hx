package hxc.context;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals.Path;
import hxc.core.Globals.Platform;
import hxc.core.Define;
import haxe.ds.StringMap;

class Context {
	/**
	 * Bundled standard library and target overlays used by class-path setup, from HAXE_STD_PATH.
	 */
	public var stdPath:Array<String>;

	public var classPath:Array<String>;

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

	public var initMacros:Array<String>;

	public var declOfType:StringMap<{decl:TypeDef, pos:Position}>;

	/**
	 * Count unresolved field annotations; each retains a placeholder monomorph while resolution
	 * continues.
	 */
	public var unresolvedFields:Int = 0;

	public var diagnostics:Array<CompilerDiagnostic>;

	public var moduleImports:StringMap<ModuleImports>;

	public var currentModule:Null<ModuleDef> = null;

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
		this.defines = defines == null ? new Define() : defines;
		this.mainClass = null;
		this.moduleLut = new StringMap();
		this.typeToModule = new StringMap();
		this.moduleNonexistentLut = new StringMap();
		this.modules = [];
		this.types = [];
		this.resources = new StringMap();
		this.initMacros = [];
		this.declOfType = new StringMap();
		this.diagnostics = [];
		this.moduleImports = new StringMap();
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
		var c = new Context(this.classPath.copy(), Define.adaptToMacroContext(this.defines));
		c.stdPath = this.stdPath.copy();
		c.platform = Eval;
		c.platformConfig = PlatformConfig.eval();
		c.isMacro = true;
		for (name in this.resources.keys()) c.resources.set(name, this.resources.get(name));
		c.initMacros = this.initMacros.copy();
		return c;
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

	public function addDiagnostic(message:String, pos:Position):Void {
		diagnostics.push({message: message, pos: pos});
	}

	public function hasDiagnostics():Bool {
		return diagnostics.length > 0;
	}
}

typedef CompilerDiagnostic = {
	var message:String;
	var pos:Position;
};

class ContextError {
	public var message:String;
	public var pos:Position;
	public var kind:ContextErrorKind;

	public function new(message:String, pos:Position, ?kind:ContextErrorKind) {
		this.message = message;
		this.pos = pos;
		this.kind = kind == null ? Other : kind;
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
	public var wildcards:Array<Path>;
	public var usings:Array<Path>;
	public var globals:StringMap<ImportedGlobal>;
	public function new(names:StringMap<ImportedName>, wildcards:Array<Path>, usings:Array<Path>, ?globals:StringMap<ImportedGlobal>) {
		this.names = names;
		this.wildcards = wildcards;
		this.usings = usings;
		this.globals = globals != null ? globals : new StringMap();
	}
}

/**
 * Short-name binding to a module and optional subtype. The map key is the referenced alias, subtype
 * or module name.
 */
typedef ImportedName = {modulePath:Path, sub:Null<String>};

/**
 * Resolved static-field import: owning module, optional subtype and static field or enum
 * constructor.
 */
typedef ImportedGlobal = {ownerPath:Path, ownerSub:Null<String>, field:String};
