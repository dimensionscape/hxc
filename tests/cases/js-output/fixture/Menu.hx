class Menu {
	public inline static function menu(o:Dynamic, ?a:Dynamic, b:Int = 5, ?c:Dynamic):Dynamic {
		return untyped o.menu(a, b, c);
	}
}

abstract Wrapped(Dynamic) from Dynamic {
	public inline function call(x:Int, b:Int = 5, ?c:String):Dynamic return untyped this.h(x, b, c);
}
