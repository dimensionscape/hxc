package hxc.generators;

// The cpp target lowers the typed AST into a cpp-specific IR (the retype pass, CppRetype) and emits a C++
// project tree (CppGen / CppGenClass / CppEmit) that hxcpp builds. generate() drives source generation.
import hxc.context.Context;

class GenCpp {
	// Dispatch generate_cppia vs generate_source (cppia is M4, deferred).
	public static function generate(com:Context):Void {
		hxc.generators.cpp.CppGen.generate(com);
	}
}
