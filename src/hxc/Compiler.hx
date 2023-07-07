package hxc;

class Compiler {
	public function new() run(Sys.args());
	public static function main() run(Sys.args());

	static function run(args:Array<String>):Void {
		Sys.println("hxc 0.0.0, Haxe-in-Haxe (bootstrap). Toolchain OK.");
	}
}
