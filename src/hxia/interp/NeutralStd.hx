package hxia.interp;

// Seeds a HostRegistry with the neutral std surface (ABI.md): constructors and the static
// functions scripts reach for. Member calls on host values (Array/String/Map methods) are
// dispatched reflectively by the interpreter, so only constructors and statics need
// explicit bindings here. The `logSink` receives Sys.println / trace output.
class NeutralStd {
	public static function install(reg:HostRegistry, logSink:String->Void):Void {
		// Constructors
		reg.bindNew("Array", function(_) return []);
		reg.bindNew("haxe.ds.StringMap", function(_) return new haxe.ds.StringMap<Dynamic>());
		reg.bindNew("haxe.ds.IntMap", function(_) return new haxe.ds.IntMap<Dynamic>());
		reg.bindNew("haxe.ds.ObjectMap", function(_) return new haxe.ds.ObjectMap<Dynamic, Dynamic>());
		reg.bindNew("StringBuf", function(_) return new StringBuf());

		// Statics: the owned sinks + pure compute
		reg.bindStatic("Sys", "println", function(a) { logSink(Std.string(a[0])); return null; });
		reg.bindStatic("Std", "string", function(a) return Std.string(a[0]));
		reg.bindStatic("Std", "int", function(a) return Std.int(a[0]));
		reg.bindStatic("Std", "parseInt", function(a) return Std.parseInt(a[0]));
		reg.bindStatic("Std", "parseFloat", function(a) return Std.parseFloat(a[0]));
		reg.bindStatic("Math", "abs", function(a) return Math.abs(a[0]));
		reg.bindStatic("Math", "floor", function(a) return Math.floor(a[0]));
		reg.bindStatic("Math", "max", function(a) return Math.max(a[0], a[1]));
		reg.bindStatic("Math", "min", function(a) return Math.min(a[0], a[1]));
	}
}
