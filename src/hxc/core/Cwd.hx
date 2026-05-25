package hxc.core;

/**
	The C library's chdir. On Windows that also records the drive's current directory in the process
	environment as the variable "=X:", which Sys.getEnv and Sys.environment then show; hxcpp's Sys.setCwd
	(SetCurrentDirectoryW) does not.
**/
#if cpp
@:cppFileCode('#ifdef _WIN32\n#include <direct.h>\n#include <wchar.h>\n#else\n#include <unistd.h>\n#endif\nstatic int hxc_chdir(::String d) {\n#ifdef _WIN32\n\treturn _wchdir(d.wchar_str());\n#else\n\treturn chdir(d.utf8_str());\n#endif\n}\n')
#end
class Cwd {
	public static function set(dir:String):Bool {
		#if cpp
		var r:Int = untyped __cpp__("hxc_chdir({0})", dir);
		return r == 0;
		#else
		Sys.setCwd(dir);
		return true;
		#end
	}
}
