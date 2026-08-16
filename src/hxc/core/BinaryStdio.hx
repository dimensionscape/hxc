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

	// The request channel is binary too. In text mode a length byte of 0x1A (a 26-byte request) reads as
	// end of file, and a display file's CR LF loses its CR.
	public static function setStdin():Void {
		#if (cpp && windows)
		untyped __cpp__("_setmode(_fileno(stdin), _O_BINARY)");
		#end
	}
}
