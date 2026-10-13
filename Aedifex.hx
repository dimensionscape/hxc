package;

import aedifex.build.Project;
import aedifex.build.ProjectSpec;

class Aedifex {
	public static final project:ProjectSpec = Project
		.named("hxc")
		.source("src")
		.mainClass("hxc.Compiler")
		.identity("hxc", "hxc")
		.version("0.6.6")
		.description("A Haxe 4+ compiler written in Haxe.")
		.license("MPL-2.0")
		.defineToken("HXCPP_GC_BIG_BLOCKS")
		.done();
}
