package hxc.eval;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
	Links the mbedtls hxcpp builds for its own sys.ssl (src/hx/libs/ssl/Build.xml: mbedtls 2.28.2 under
	hxcpp's mbedtls_config.h) and compiles the binding's stubs, mbedtls_stubs.c beside this file, with
	the same flags, so the structures they allocate are the library's. Build.xml is written far from the
	source tree, so the path is absolute, taken from where this class's source file lives. Nothing of it
	is built for emscripten, which has no sockets.
**/
class MbedtlsBuild {
	public static function build():Array<Field> {
		var file = Context.getPosInfos(Context.currentPos()).file;
		var here = haxe.io.Path.directory(sys.FileSystem.fullPath(file));
		var stubs = haxe.io.Path.normalize(here + "/mbedtls_stubs.c");
		var b = new StringBuf();
		b.add('<include name="$${HXCPP}/src/hx/libs/ssl/Build.xml" unless="emscripten"/>\n');
		b.add('<files id="hxc-mbedtls" unless="emscripten">\n');
		b.add('\t<include name="$${HXCPP}/project/thirdparty/mbedtls-flags.xml"/>\n');
		b.add('\t<file name="$stubs"/>\n');
		b.add('</files>\n');
		b.add('<target id="haxe" unless="emscripten">\n');
		b.add('\t<files id="hxc-mbedtls"/>\n');
		b.add('</target>\n');
		Context.getLocalClass().get().meta.add(":buildXml", [macro $v{b.toString()}], Context.currentPos());
		return null;
	}
}
#end
