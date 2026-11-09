import haxe.macro.Context;
import haxe.macro.Compiler;

class Probe {
	// Prints the target's defines and the platform config the generator and filters read.
	public static function print():Void {
		Sys.println("hl-ver=" + Context.definedValue("hl-ver"));
		Sys.println("hlc=" + Context.defined("hlc"));
		Sys.println("static=" + Context.defined("static"));
		Sys.println("sys=" + Context.defined("sys"));
		Sys.println("target.threaded=" + Context.defined("target.threaded"));
		Sys.println("target.atomics=" + Context.defined("target.atomics"));
		Sys.println("target.utf16=" + Context.defined("target.utf16"));
		var pc = Compiler.getConfiguration().platformConfig;
		Sys.println("padNulls=" + pc.padNulls);
		Sys.println("scoping.scope=" + pc.scoping.scope);
		Sys.println("scoping.flags=" + pc.scoping.flags);
		Sys.println("exceptions.nativeThrows=" + pc.exceptions.nativeThrows);
	}

	// Prints "== <path>" then the file's content (CRLF -> LF) once the output is generated.
	public static function after(path:String):Void {
		Context.onAfterGenerate(function() {
			Sys.println("== " + path);
			Sys.print(StringTools.replace(sys.io.File.getContent(path), "\r\n", "\n"));
		});
	}
}
