package hxia.harness;

// Target-portable stdout + argv for the harness. Plain `-js` is treated as non-sys
// by Haxe, but the harness runs under node, so js routes through node's process.
// Output is written raw (no added newlines); the driver normalizes CRLF once.
class Io {
	public static function write(s:String):Void {
		#if sys
		Sys.stdout().writeString(s);
		#elseif js
		untyped __js__("process.stdout.write({0})", s);
		#else
		throw "hxia.harness.Io: unsupported target";
		#end
	}

	public static function args():Array<String> {
		#if sys
		return Sys.args();
		#elseif js
		return (untyped __js__("process.argv.slice(2)") : Array<String>);
		#else
		return [];
		#end
	}
}
