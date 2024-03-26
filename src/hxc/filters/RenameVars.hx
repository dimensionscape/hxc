package hxc.filters;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals.Path;
import haxe.ds.StringMap;

/**
	FAITHFUL PORT of (337 lines), INIT half.

	Scope-aware local-variable renaming. That produces `var X = X` self-shadows for generated locals that
	share an enclosing-scope var's name (e.g. the `.bind()` desugar in Typer.typeBind, whose generated
	locals are named after the bound args). JS hoisting then makes the inner `X` undefined, capturing the
	wrong value. This filter renames the colliding local (e.g. `uctx` -> `uctx1`) so the closure reads the
	real outer value, fixing the cast/macro Heisenbugs.

	The collect/rename half lives in filters.RenameVarsRun (run()).
**/
class RenameVars {

	// Built once per compile; carries reserved names + the resolved flag set.
	public var hoisting:Bool;
	public var noShadowing:Bool;
	public var noCatchVarShadowing:Bool;
	public var switchCasesNoBlocks:Bool;
	public var blockScope:Bool;
	public var reserved:StringMap<Bool>;

	function new() {
		this.hoisting = false;
		this.noShadowing = false;
		this.noCatchVarShadowing = false;
		this.switchCasesNoBlocks = false;
		this.blockScope = false;
		this.reserved = new StringMap<Bool>();
	}

	inline function reserveInit(name:String):Void {
		reserved.set(name, true);
	}

	/**
		Initialization for hxc's ES5 JS target.
		`types` = com.types, every module-type name is reserved (ReserveAllTypesFlat) so a local can never
		shadow a type/global.
	**/
	public static function init(types:Array<ModuleType>, ?cpp:Bool = false, ?es6:Bool = false):RenameVars {
		var ri = new RenameVars();
		ri.reserveInit("this"); // Init reserves "this" first.
		if (cpp) {
			// Cpp scoping: NoShadowing, FunctionScope. No ReserveAllTypes (types live in ::pack::Name
			// namespaces, so a local cannot collide) and no hoisting; C++ keyword collisions are remapped
			// by the emitter (CppTypeText's keyword remap), not here.
			ri.noShadowing = true;
			ri.hoisting = false;
			ri.noCatchVarShadowing = false;
			ri.switchCasesNoBlocks = false;
			return ri;
		}
		if (es6) {
			// ES6 config: block scope, with the flags NoShadowing and SwitchCasesNoBlocks.
			ri.hoisting = false;
			ri.noCatchVarShadowing = false;
			ri.noShadowing = true;
			ri.switchCasesNoBlocks = true;
			ri.blockScope = true;
			ri.reserveAllTypes(types);
			return ri;
		}
		// JS Function/Block scope flags for the non-es6 path.
		ri.hoisting = true;                             
		ri.noCatchVarShadowing = true;                       
		ri.noShadowing = false;
		ri.switchCasesNoBlocks = false;
		// JS keywords are not reserved here: the generator escapes them at print time.
		// ReserveAllTypesFlat reserves every type by its flat path.
		ri.reserveAllTypes(types);
		return ri;
	}

	// Flat path: pack joined by "_" then "_" then name, e.g. (["js"],"Boot") -> "js_Boot"; ([],"Main") ->
	// "Main".
	static function flatPath(path:Path):String {
		return path.pack.length == 0 ? path.name : path.pack.join("_") + "_" + path.name;
	}

	/**
	 * ReserveAllTypesFlat: reserve every module-type's name so no local shadows a type/global.
	 *
	 * hxc emits packaged types DOTTED (`pack.Name`), not flat, so a local can only actually collide
	 * with a BARE (empty-pack) top-level type name (`Main`, `Std`, `Array`, `Math`, ...) or the
	 * special-cased
	 * `js_Boot`. Both the flat path and the bare name of empty-pack types (what GenJS emits as a
	 * top-level
	 * `var`) are reserved. Reserving a few extra names is harmless. The native-name / KModuleFields /
	 * per-static reservation belongs to ReserveAllTopLevelSymbols (js-unflatten), which hxc does not
	 * use.
	 */
	function reserveAllTypes(types:Array<ModuleType>):Void {
		for (mt in types) {
			var info = TypeFunctions.tInfos(mt);
			reserveInit(flatPath(info.path));
			if (info.path.pack.length == 0) reserveInit(info.path.name);
			// @:native("X") renames the emitted global; applyNativePaths runs after this, so the type still
			// carries its original path here. Reserve the native name too so a local cannot shadow it.
			function reserveNative(meta:hxc.ast.Ast.Metadata):Void {
				for (m in meta) if (m.name == ":native" && m.params.length == 1) switch (m.params[0].expr) {
					case EConst(CString(nn, _)) if (nn != ""):
						var parts = nn.split(".");
						var np:Path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
						reserveInit(flatPath(np));
						if (np.pack.length == 0) reserveInit(np.name);
					case _:
				}
			}
			reserveNative(info.meta);
			// A @:native static field emits a global too (an extern binding), so reserve it as well.
			switch (mt) {
				case TClassDecl(c): for (cf in c.orderedStatics) reserveNative(cf.meta);
				case _:
			}
		}
	}
}
