package hxc.core;

import hxc.ast.Position;

typedef Path = {pack:Array<String>, name:String};

enum Located {
	Message(msg:String, p:Position);
	Stack(stack:Array<Located>);
}

// Preserve platform order; numeric indices depend on it.
enum Platform {
	Cross;
	Js;
	Lua;
	Neko;
	Flash;
	Php;
	Cpp;
	Cs;
	Java;
	Python;
	Hl;
	Eval;
}

enum MessageSeverity {
	Error;
	Warning;
	Information;
	Hint;
}

enum MessageKind {
	DKUnusedImport;
	DKUnresolvedIdentifier;
	DKCompilerMessage;
	DKRemovableCode;
	DKParserError;
	DKDeprecationWarning;
	DKInactiveBlock;
	DKMissingFields;
}

typedef CompilerMessage = {
	message:String,
	pos:Position,
	depth:Int,
	kind:MessageKind,
	severity:MessageSeverity,
};

class Globals {
	// Version components use integer division and remainder.
	public static final version:Int = 4300;
	public static final versionMajor:Int = Std.int(version / 1000); // Version / 1000
	public static final versionMinor:Int = Std.int((version % 1000) / 100); // (version mod 1000) / 100
	public static final versionRevision:Int = version % 100; // Version mod 100
	public static final versionPre:Null<String> = null;

	// Canonical home is Position.nullPos; forwarded here for call sites that read it from Globals.
	public static final nullPos:Position = Position.nullPos;

	public static function located(msg:String, p:Position):Located {
		return Message(msg, p);
	}

	public static function locatedStack(stack:Array<Located>):Located {
		return Stack(stack);
	}

	public static function extractLocated(l:Located):Array<{msg:String, p:Position}> {
		return switch l {
			case Message(msg, p): [{msg: msg, p: p}];
			case Stack(stack):
				var acc:Array<{msg:String, p:Position}> = [];
				for (s in stack)
					acc = acc.concat(extractLocated(s));
				acc;
		}
	}

	public static function relocate(msg:Located, p:Position):Located {
		return switch msg {
			case Message(m, _): Message(m, p);
			case Stack(stack) if (stack.length == 0): Stack([]);
			case Stack(stack):
				var hd = stack[0];
				var tl = stack.slice(1);
				Stack([relocate(hd, p)].concat(tl));
		}
	}

	public static function extractLocatedPos(l:Located):Position {
		return switch l {
			case Message(_, p): p;
			case Stack(stack) if (stack.length == 0): Position.nullPos;
			case Stack(stack): extractLocatedPos(stack[0]);
		}
	}

	// Macros run in the eval interpreter, so the macro context compiles for the eval platform.
	public static var macroPlatform:Platform = Eval;

	public static var returnPartialType:Bool = false;

	public static final isWindows:Bool = Sys.systemName() == "Windows";

	public static final platforms:Array<Platform> = [Js, Lua, Neko, Flash, Php, Cpp, Cs, Java, Python, Hl, Eval];

	public static function platformName(p:Platform):String {
		return switch p {
			case Cross: "cross";
			case Js: "js";
			case Lua: "lua";
			case Neko: "neko";
			case Flash: "flash";
			case Php: "php";
			case Cpp: "cpp";
			case Cs: "cs";
			case Java: "java";
			case Python: "python";
			case Hl: "hl";
			case Eval: "eval";
		}
	}

	public static function parsePlatform(s:String):Platform {
		return switch s {
			case "cross": Cross;
			case "js": Js;
			case "lua": Lua;
			case "neko": Neko;
			case "flash": Flash;
			case "php": Php;
			case "cpp": Cpp;
			case "cs": Cs;
			case "java": Java;
			case "python": Python;
			case "hl": Hl;
			case "eval": Eval;
			case p: throw new haxe.Exception("invalid platform " + p);
		}
	}

	public static function platformListHelp(pl:Array<Platform>):String {
		return switch pl.length {
			case 0: "";
			case 1: " (" + platformName(pl[0]) + " only)";
			case _: " (for " + [for (p in pl) platformName(p)].join(",") + ")";
		}
	}

	public static function mkZeroRangePos(p:Position):Position {
		return new Position(p.file, p.min, p.min);
	}

	public static function sTypePath(path:Path):String {
		return path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name;
	}

	// Is a code point
	public static function startsWith(s:String, c:Int):Bool {
		return s.length > 0 && s.charCodeAt(0) == c;
	}

	public static var getErrorPosRef:(String->Int->String)->Position->String = function(printer, p) {
		var info = Position.getInfos(p);
		if (info.line <= 0) return '${p.file}: (unknown)';
		if (info.line != info.endLine) return printer(p.file, info.line) + ' lines ${info.line}-${info.endLine}';
		var c1 = info.column + 1;
		var c2 = info.endColumn + 1;
		if (c1 == c2) return printer(p.file, info.line) + ' character $c1';
		return printer(p.file, info.line) + ' characters $c1-$c2';
	};

	public static final sVersion:String = {
		var pre = versionPre == null ? "" : "-" + versionPre;
		'$versionMajor.$versionMinor.$versionRevision$pre';
	};

	public static final versionExtra:Null<{commit:String, build:String}> = null;

	public static final sVersionFull:String = versionExtra == null ? sVersion : sVersion + "+" + versionExtra.build;

	public static function patchStringPos(p:Position, s:String):Position {
		return new Position(p.file, p.max - s.length, p.max);
	}

	public static function die(msg:String, mlLoc:String, ?p:Position):Dynamic {
		var strPos = "";
		var exprMsg = "";
		if (p != null) {
			strPos = getErrorPosRef(function(file, line) return '$file:$line:', p) + " ";
			exprMsg = "the expression example and ";
		}
		var full = strPos + "Compiler failure" + (msg == "" ? "" : ": " + msg) + "\n"
			+ strPos + "Please submit an issue at https://github.com/HaxeFoundation/haxe/issues/new\n"
			+ strPos + "Attach " + exprMsg + "the following information:";
		var ver = sVersionFull;
		var osType = Sys.systemName() != "Windows" ? "unix" : "windows";
		var backtrace = haxe.CallStack.toString(haxe.CallStack.callStack());
		// The format string ends with the backtrace (no trailing newline).
		Sys.stderr().writeString('$full\nHaxe: $ver; OS type: $osType;\n$mlLoc\n$backtrace');
		throw false; // Assert false
	}

	public static function severityToInt(s:MessageSeverity):Int {
		return switch s {
			case Error: 1;
			case Warning: 2;
			case Information: 3;
			case Hint: 4;
		}
	}

	public static function messageKindToInt(k:MessageKind):Int {
		return switch k {
			case DKUnusedImport: 0;
			case DKUnresolvedIdentifier: 1;
			case DKCompilerMessage: 2;
			case DKRemovableCode: 3;
			case DKParserError: 4;
			case DKDeprecationWarning: 5;
			case DKInactiveBlock: 6;
			case DKMissingFields: 7;
		}
	}

	public static function makeCompilerMessage(msg:String, p:Position, depth:Int, kind:MessageKind, sev:MessageSeverity):CompilerMessage {
		return {
			message: msg,
			pos: p,
			depth: depth,
			kind: kind,
			severity: sev,
		};
	}

	public static final int32Of31:haxe.Int32 = 31;
}
