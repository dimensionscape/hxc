package hxc.generators;

// The cpp target lowers the typed AST into a cpp-specific IR (the retype pass, CppRetype) and emits a C++
// project tree (CppGen / CppGenClass / CppEmit) that hxcpp builds. generate() drives source generation.
import hxc.context.Context;

class GenCpp {
	public static function generate(com:Context):Void {
		if (com.defines.rawDefined("cppia"))
			hxc.generators.cpp.CppiaGen.generate(com);
		else
			hxc.generators.cpp.CppGen.generate(com);
	}
}
