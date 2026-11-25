import haxe.macro.Context;
import haxe.macro.Expr;

class M {
	// Adds two resources.
	macro public static function addTwo():Expr {
		Context.addResource("m1", haxe.io.Bytes.ofString("one"));
		Context.addResource("m2", haxe.io.Bytes.ofString("two"));
		return macro null;
	}

	// Adds one resource under the name and bytes given.
	macro public static function add(name:String, text:String):Expr {
		Context.addResource(name, haxe.io.Bytes.ofString(text));
		return macro null;
	}

	// Replaces `a` with other bytes, then adds `b`.
	macro public static function replaceA():Expr {
		Context.addResource("a", haxe.io.Bytes.ofString("from macro"));
		Context.addResource("b", haxe.io.Bytes.ofString("bee"));
		return macro null;
	}

	// What Context.getResources holds, name by name in sorted order.
	macro public static function report():Expr {
		var all = Context.getResources();
		var names = [for (n in all.keys()) n];
		names.sort(Reflect.compare);
		for (n in names) Sys.println("macro sees " + n + "=" + all.get(n).toString());
		return macro null;
	}
}
