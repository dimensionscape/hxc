// A package-less class outside the case directory's root: only the debug-classpath case (`-cp sub`) finds it,
// so its debug file name is the one with a class path other than `./` stripped.
class Greeter {
	public static function greet(n:String):String {
		return "hello " + n;
	}
}
