import haxe.macro.Expr;

class M {
	macro static function str(a:String, ?b:String) {
		Sys.println('str ${a.split("-")} ${b == null ? "null" : b.toUpperCase()}');
		return null;
	}

	macro static function kinds(i:Int, f:Float, t:Bool, list:Array<String>, o:{name:String}) {
		Sys.println('kinds ${i + 1} ${f * 2} ${!t} ${list.join("+")} ${o.name.length}');
		return null;
	}

	macro static function dyn(d:Dynamic) {
		Sys.println('dyn ${Std.isOfType(d, String)} $d');
		return null;
	}

	macro static function expr(e:Expr) {
		Sys.println("expr");
		return null;
	}

	macro static function exprOf(e:ExprOf<String>) {
		Sys.println("exprOf");
		return null;
	}

	macro static function exprs(a:String, more:Array<Expr>) {
		Sys.println("exprs");
		return null;
	}

	macro static function rest(a:String, ...more:Expr) {
		Sys.println("rest");
		return null;
	}

	public static function plain(a:String) {
		Sys.println('plain ${a.split("-")}');
	}
}
