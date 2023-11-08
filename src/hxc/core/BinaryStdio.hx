package hxc.core;

// Windows opens stdout/stderr in text mode, translating \n to \r\n; both are set to binary at startup so
// output is byte-identical across platforms.
#if (cpp && windows)
@:headerCode("
#include <io.h>
#include <fcntl.h>
#include <stdio.h>
")
#end
class BinaryStdio {
	public static function set():Void {
		#if (cpp && windows)
		untyped __cpp__("_setmode(_fileno(stdout), _O_BINARY)");
		untyped __cpp__("_setmode(_fileno(stderr), _O_BINARY)");
		#end
	}
}
