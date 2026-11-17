import haxe.macro.Context;

class JsDigest {
	// Prints "== <path> <length> <md5>" once the .js is written: the length and MD5 of its bytes. With a
	// source map beside it (-debug), also "== <path>.map mappings <length> <md5>" for the map's mappings
	// string alone: its sources are absolute paths.
	public static function after(path:String):Void {
		Context.onAfterGenerate(function() {
			var out = sys.io.File.getBytes(path);
			Sys.println("== " + path + " " + out.length + " " + haxe.crypto.Md5.make(out).toHex());
			if (sys.FileSystem.exists(path + ".map")) {
				var mappings:String = haxe.Json.parse(sys.io.File.getContent(path + ".map")).mappings;
				Sys.println("== " + path + ".map mappings " + mappings.length + " " + haxe.crypto.Md5.encode(mappings));
			}
		});
	}
}
