class M {
	// The module as it is when the compiler starts says 1.
	public static function rewrite() {
		sys.io.File.saveContent("Gen.hx", "class Gen {\n\tpublic static inline var v = 2;\n}\n");
	}

	public static macro function build():Array<haxe.macro.Expr.Field> {
		sys.io.File.saveContent("Gen.hx", "class Gen {\n\tpublic static inline var v = 3;\n}\n");
		return null;
	}
}
