package hxc.compiler;

import hxc.context.Context;
import hxc.core.Type;

// Verbose server messages are disabled by default. Enable them with -v or server/configure's print
// object; send them to stdout.
class ServerMessage {
	public static var printAddedDirectory = false;
	public static var printFoundDirectories = false;
	public static var printChangedDirectories = false;
	public static var printModulePathChanged = false;
	public static var printNotCached = false;
	public static var printParsed = false;
	public static var printRemovedDirectory = false;
	public static var printReusing = false;
	public static var printRetyping = false;
	public static var printSkippingDep = false;
	public static var printUnchangedContent = false;
	public static var printCachedModules = false;
	public static var printClassPathsChanged = false;
	public static var printArguments = false;
	public static var printCompletion = false;
	public static var printDefines = false;
	public static var printSignature = false;
	public static var printDisplayPosition = false;
	public static var printStats = false;
	public static var printMessage = false;
	public static var printSocketMessage = false;
	public static var printUncaughtError = false;
	public static var printNewContext = false;

	static function shortPlatformName(p:hxc.core.Globals.Platform):String {
		return switch (p) {
			case Cross: "x";
			case Js: "js";
			case Lua: "lua";
			case Neko: "n";
			case Flash: "swf";
			case Php: "php";
			case Cpp: "cpp";
			case Cs: "cs";
			case Java: "jav";
			case Python: "py";
			case Hl: "hl";
			case Eval: "evl";
		}
	}

	static function pad(s:String, w:Int):String {
		while (s.length < w) s = " " + s;
		return s;
	}

	// "%2i,%3s: " over the context index and platform
	static function signString(com:Context):String {
		var cc = hxc.context.DisplayJson.cache.getContext(com.defines.getSignature());
		return pad(Std.string(cc.index), 2) + "," + pad(shortPlatformName(com.platform), 3) + ": ";
	}

	// Flush real stdout immediately; it is separate from the length-prefixed stderr response and the
	// server outlives each request.
	static function out(s:String):Void {
		var o = Sys.stdout();
		o.writeString(s + "\n");
		o.flush();
	}

	public static function addedDirectory(com:Context, tabs:String, dir:String):Void {
		if (printAddedDirectory) out(signString(com) + "added directory " + dir);
	}

	public static function foundDirectories(com:Context, tabs:String, count:Int):Void {
		if (printFoundDirectories) out(signString(com) + "found " + count + " directories");
	}

	public static function changedDirectories(com:Context, tabs:String, dirs:Array<String>):Void {
		if (printChangedDirectories)
			out(signString(com) + "changed directories: [" + [for (d in dirs) '"' + d + '"'].join(", ") + "]");
	}

	public static function notCached(com:Context, tabs:String, m:ModuleDef):Void {
		if (printNotCached) out(signString(com) + Context.sTypePath(m.path) + " not cached (modified)");
	}

	public static function parsed(com:Context, tabs:String, ffile:String, info:String):Void {
		if (printParsed) out(signString(com) + "parsed " + ffile + " (" + info + ")");
	}

	public static function removedDirectory(com:Context, tabs:String, dir:String):Void {
		if (printRemovedDirectory) out(signString(com) + "removed directory " + dir);
	}

	public static function reusing(com:Context, tabs:String, m:ModuleDef):Void {
		if (printReusing) out(signString(com) + tabs + "reusing " + Context.sTypePath(m.path));
	}

	public static function retyperOk(com:Context, tabs:String, m:ModuleDef):Void {
		if (printRetyping) out(signString(com) + tabs + "retyped " + Context.sTypePath(m.path));
	}

	public static function retyperFail(com:Context, tabs:String, m:ModuleDef, reason:String):Void {
		if (printRetyping) {
			out(signString(com) + tabs + "failed retyping " + Context.sTypePath(m.path));
			out(signString(com) + tabs + "  " + reason);
		}
	}

	public static function skippingDep(com:Context, tabs:String, m:ModuleDef, reason:String):Void {
		if (printSkippingDep) out(signString(com) + "skipping " + Context.sTypePath(m.path) + " (" + reason + ")");
	}

	public static function unchangedContent(com:Context, tabs:String, file:String):Void {
		if (printUnchangedContent) out(signString(com) + file + " changed time not but content, reusing");
	}

	public static function cachedModules(com:Context, tabs:String, i:Int):Void {
		if (printCachedModules) out(signString(com) + "Cached " + i + " modules");
	}

	public static function classPathsChanged(com:Context, tabs:String):Void {
		if (printClassPathsChanged) out(signString(com) + "class paths changed, resetting directories");
	}

	public static function arguments(data:Array<String>):Void {
		if (printArguments) out("Processing Arguments [" + data.join(",") + "]");
	}

	public static function completion(str:String):Void {
		if (printCompletion) out("Completion Response =\n" + str);
	}

	public static function signature(com:Context, tabs:String, sign:String):Void {
		if (printSignature) out("Using signature " + sign);
	}

	public static function displayPosition(com:Context, tabs:String, p:String):Void {
		if (printDisplayPosition) out("Display position: " + p);
	}

	public static function message(s:String):Void {
		if (printMessage) out("> " + s);
	}

	public static function socketMessage(s:String):Void {
		if (printSocketMessage) out(s);
	}

	public static function uncaughtError(s:String):Void {
		if (printUncaughtError) out("Uncaught Error : " + s);
	}

	public static function enableAll():Void {
		printAddedDirectory = true;
		printFoundDirectories = true;
		printChangedDirectories = true;
		printModulePathChanged = true;
		printNotCached = true;
		printParsed = true;
		printRemovedDirectory = true;
		printReusing = true;
		printRetyping = true;
		printSkippingDep = true;
		printUnchangedContent = true;
		printCachedModules = true;
		printArguments = true;
		printCompletion = true;
		printDefines = true;
		printSignature = true;
		printDisplayPosition = true;
		printStats = true;
		printMessage = true;
		printSocketMessage = true;
		printUncaughtError = true;
		printNewContext = true;
	}

	public static function setByName(name:String, value:Bool):Void {
		switch (name) {
			case "addedDirectory": printAddedDirectory = value;
			case "foundDirectories": printFoundDirectories = value;
			case "changedDirectories": printChangedDirectories = value;
			case "modulePathChanged": printModulePathChanged = value;
			case "notCached": printNotCached = value;
			case "parsed": printParsed = value;
			case "removedDirectory": printRemovedDirectory = value;
			case "reusing": printReusing = value;
			case "retyping": printRetyping = value;
			case "skippingDep": printSkippingDep = value;
			case "unchangedContent": printUnchangedContent = value;
			case "cachedModules": printCachedModules = value;
			case "arguments": printArguments = value;
			case "completion": printCompletion = value;
			case "defines": printDefines = value;
			case "signature": printSignature = value;
			case "displayPosition": printDisplayPosition = value;
			case "stats": printStats = value;
			case "message": printMessage = value;
			case "socketMessage": printSocketMessage = value;
			case "uncaughtError": printUncaughtError = value;
			case "newContext": printNewContext = value;
			case _:
		}
	}
}
