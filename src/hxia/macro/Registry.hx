package hxia.macro;

#if macro
// Accumulates the exposed @:scriptable surface during a compilation so hxia.macro.Sdk can
// emit a typed SDK from it. The build macro appends one entry per scriptable class.
typedef FieldSurface = {name:String, sig:String, atoms:Array<String>};
typedef ClassSurface = {pack:Array<String>, name:String, isInterface:Bool, fields:Array<FieldSurface>};

class Registry {
	public static var classes:Array<ClassSurface> = [];

	public static function add(c:ClassSurface):Void {
		classes.push(c);
	}
}
#end
