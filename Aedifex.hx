package;

import aedifex.build.Project;
import aedifex.build.ProjectSpec;

class Aedifex {
	public static final project:ProjectSpec = Project
		.named("hxc")
		.source("src")
		.mainClass("hxc.Compiler")
		.haxeCompiler("C:/HaxeToolkit/haxe/haxe.exe")
		.identity("hxc", "hxc")
		.version("0.0.0")
		.description("A Haxe 4+ compiler written in Haxe.")
		.license("GPL2")
		.done();
}
