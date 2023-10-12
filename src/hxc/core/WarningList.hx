package hxc.core;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.TypeUnification.Meta;

// The warning kinds and the -w / @:haxe.warning machinery. The enum order and docs follow the entries of
// warning.json.
enum Warning {
	WAll;
	WInternal;
	WTemp;
	WInfo;
	WUser;
	WCompiler;
	WParser;
	WTyper;
	WMacro;
	WOptimizer;
	WGenerator;
	WDeprecated;
	WDeprecatedDefine;
	WDeprecatedEnumAbstract;
	WVarInit;
	WVarShadow;
	WExternWithExpr;
	WStaticInitOrder;
	WClosureCompare;
	WReservedTypePath;
	WPatternMatcher;
	WUnusedPattern;
	WConstructorInliningCancelled;
	WUnsafeEnumEquality;
}

typedef WarningObj = {name:String, doc:String, generic:Bool, parent:Null<Warning>};

enum WarningMode {
	WMEnable;
	WMDisable;
}

typedef WarningOption = {warning:Warning, mode:WarningMode};

class WarningList {
	// Parent is the json "parent", or WAll for a top-level warning (WAll itself has none); generic is
	// the json "generic" flag (default false).
	public static function warningObj(w:Warning):WarningObj {
		return switch (w) {
			case WAll: {name: "WAll", doc: "The mother of all warnings", generic: true, parent: null};
			case WInternal: {name: "WInternal", doc: "Reserved for internal use", generic: true, parent: WAll};
			case WTemp: {name: "WTemp", doc: "Reserved for internal use", generic: true, parent: WAll};
			case WInfo: {name: "WInfo", doc: "Generic information like $type", generic: true, parent: WAll};
			case WUser: {name: "WUser", doc: "Custom user warnings, e.g. from Context.warning", generic: true, parent: WAll};
			case WCompiler: {name: "WCompiler", doc: "Warnings from the compiler frontend, e.g. argument parsing", generic: true, parent: WAll};
			case WParser: {name: "WParser", doc: "Warnings related to lexing and parsing", generic: true, parent: WAll};
			case WTyper: {name: "WTyper", doc: "Warnings from the typer", generic: true, parent: WAll};
			case WMacro: {name: "WMacro", doc: "Warning related to macros", generic: true, parent: WAll};
			case WOptimizer: {name: "WOptimizer", doc: "Warnings related to optimization", generic: true, parent: WAll};
			case WGenerator: {name: "WGenerator", doc: "Warnings related to code generation", generic: true, parent: WAll};
			case WDeprecated: {name: "WDeprecated", doc: "This is deprecated and should no longer be used", generic: false, parent: WAll};
			case WDeprecatedDefine: {name: "WDeprecatedDefine", doc: "This define is deprecated and should no longer be used", generic: false, parent: WDeprecated};
			case WDeprecatedEnumAbstract: {name: "WDeprecatedEnumAbstract", doc: "`@:enum abstract` is deprecated, `enum abstract` should be used instead", generic: false, parent: WDeprecated};
			case WVarInit: {name: "WVarInit", doc: "A local variable might be used before being assigned a value", generic: false, parent: WTyper};
			case WVarShadow: {name: "WVarShadow", doc: "A local variable hides another by using the same name", generic: false, parent: WTyper};
			case WExternWithExpr: {name: "WExternWithExpr", doc: "A non-inline field marked as extern has an expression", generic: false, parent: WTyper};
			case WStaticInitOrder: {name: "WStaticInitOrder", doc: "The compiler could not determine a type order due to mutually dependent static initializations", generic: false, parent: WTyper};
			case WClosureCompare: {name: "WClosureCompare", doc: "Closures are being compared, which might be undefined", generic: false, parent: WTyper};
			case WReservedTypePath: {name: "WReservedTypePath", doc: "A type path is being used that is supposed to be reserved on the current target", generic: false, parent: WTyper};
			case WPatternMatcher: {name: "WPatternMatcher", doc: "Warnings related to the pattern matcher", generic: false, parent: WTyper};
			case WUnusedPattern: {name: "WUnusedPattern", doc: "The pattern is not used because previous cases cover", generic: false, parent: WPatternMatcher};
			case WConstructorInliningCancelled: {name: "WConstructorInliningCancelled", doc: "Constructor call could not be inlined because a field is uninitialized", generic: false, parent: WTyper};
			case WUnsafeEnumEquality: {name: "WUnsafeEnumEquality", doc: "Equality operations on enums with parameters might not work as expected", generic: false, parent: WTyper};
		}
	}

	// Json entries with "enabled": false.
	public static var disabledWarnings(default, null):Array<Warning> = [WVarShadow, WUnsafeEnumEquality];

	// Name -> warning; an unknown name returns null.
	public static function fromString(s:String):Null<Warning> {
		return switch (s) {
			case "WAll": WAll;
			case "WInternal": WInternal;
			case "WTemp": WTemp;
			case "WInfo": WInfo;
			case "WUser": WUser;
			case "WCompiler": WCompiler;
			case "WParser": WParser;
			case "WTyper": WTyper;
			case "WMacro": WMacro;
			case "WOptimizer": WOptimizer;
			case "WGenerator": WGenerator;
			case "WDeprecated": WDeprecated;
			case "WDeprecatedDefine": WDeprecatedDefine;
			case "WDeprecatedEnumAbstract": WDeprecatedEnumAbstract;
			case "WVarInit": WVarInit;
			case "WVarShadow": WVarShadow;
			case "WExternWithExpr": WExternWithExpr;
			case "WStaticInitOrder": WStaticInitOrder;
			case "WClosureCompare": WClosureCompare;
			case "WReservedTypePath": WReservedTypePath;
			case "WPatternMatcher": WPatternMatcher;
			case "WUnusedPattern": WUnusedPattern;
			case "WConstructorInliningCancelled": WConstructorInliningCancelled;
			case "WUnsafeEnumEquality": WUnsafeEnumEquality;
			case _: null;
		}
	}

	// The first option (scanning the option lists in order) whose warning is w or an ancestor of w decides
	// the mode; default enabled.
	public static function getMode(w:Warning, l:Array<Array<WarningOption>>):WarningMode {
		function matches(ww:Warning, id:Warning):Bool {
			if (ww == id) return true;
			var p = warningObj(ww).parent;
			return p == null ? false : matches(p, id);
		}
		for (l2 in l) {
			var found:Null<WarningMode> = null;
			for (opt in l2) if (matches(w, opt.warning)) { found = opt.mode; break; }
			if (found != null) return found;
		}
		return WMEnable;
	}

	// A sequence of `+Warning` / `-Warning` tokens.
	public static function parseOptions(s:String, ps:Position):Array<WarningOption> {
		var acc:Array<WarningOption> = [];
		var i = 0;
		inline function isIdent(c:Int):Bool
			return (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code) || c == "_".code;
		inline function skipWs():Void
			while (i < s.length && (s.charCodeAt(i) == " ".code || s.charCodeAt(i) == "\t".code)) i++;
		function readWarning():Warning {
			skipWs();
			var start = i;
			while (i < s.length && isIdent(s.charCodeAt(i))) i++;
			if (i == start) throw new TypingError("Expected identifier", ps);
			var name = s.substr(start, i - start);
			var w = fromString(name);
			if (w == null) throw new TypingError("Unknown warning: " + name, ps);
			return w;
		}
		while (true) {
			skipWs();
			if (i >= s.length) break;
			var c = s.charCodeAt(i);
			if (c == "+".code) { i++; acc.push({warning: readWarning(), mode: WMEnable}); }
			else if (c == "-".code) { i++; acc.push({warning: readWarning(), mode: WMDisable}); }
			else throw new TypingError("Expected + or -", ps);
		}
		return acc;
	}

	// Collect the -w option lists from every @:haxe.warning on the metadata.
	public static function fromMeta(ml:Metadata):Array<Array<WarningOption>> {
		var acc:Array<Array<WarningOption>> = [];
		for (m in ml) if (m.name == Meta.HaxeWarning) {
			for (arg in m.params) switch (arg.expr) {
				case EConst(CString(str, _)): acc.push(parseOptions(str, arg.pos));
				case _: throw new TypingError("String expected", arg.pos);
			}
		}
		return acc;
	}
}
