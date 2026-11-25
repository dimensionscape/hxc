package;

import aedifex.build.BuildCondition;
import aedifex.build.Project;
import aedifex.build.ProjectSpec;

class Aedifex {
	public static final project:ProjectSpec = Project
		.named("hxc")
		.source("src")
		.mainClass("hxc.Compiler")
		.identity("hxc", "hxc")
		.version("0.7.0")
		.description("A Haxe 4+ compiler written in Haxe.")
		.license("MPL-2.0")
		.defineToken("HXCPP_GC_BIG_BLOCKS")
		// `haxelib run hxc` falls back to this file when there is no bin/hxc.exe: keep it current.
		.hook(BuildCommand.postbuild("cmd", ["/c", "copy", "/y", "bin\\cpp\\windows\\x64\\release\\bin\\hxc.exe", "bin\\hxc-windows-x64.exe"], null,
			BuildCondition.whenAll(["cpp", "windows", "x64", "release"])))
		.done();
}
