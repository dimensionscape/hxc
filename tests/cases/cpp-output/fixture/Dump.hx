import haxe.macro.Context;

class Dump {
	// Prints "== <path>" then the file's content (CRLF -> LF) once the output is generated. May be called
	// several times in one compile; path is relative to the case dir.
	public static function after(path:String):Void {
		Context.onAfterGenerate(function() {
			Sys.println("== " + path);
			Sys.print(StringTools.replace(sys.io.File.getContent(path), "\r\n", "\n"));
		});
	}
}
