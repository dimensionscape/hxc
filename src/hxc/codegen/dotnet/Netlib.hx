package hxc.codegen.dotnet;

import haxe.io.Bytes;

// The .NET reference assemblies hxc carries itself (netlib/ beside this file, embedded when hxc is
// built): the default std for -D net-ver=20, 40 and 45 when no class path has a netlib/<digraph> directory, as when
// hxcs is not installed. They are served from ROOT, a path that is no directory, so a message about one
// reads `<hxc-netlib>/net-20/mscorlib.dll`.
#if !macro
@:build(hxc.codegen.dotnet.NetlibBuild.build())
#end
class Netlib {
	public static inline final ROOT = "<hxc-netlib>/";

	// The decompressed files, by path under ROOT; a compile server keeps them between compiles.
	static final cache = new Map<String, Bytes>();
	static final lock = new sys.thread.Mutex();

	public static function isVirtual(path:String):Bool {
		return StringTools.startsWith(path, ROOT);
	}

	// The embedded files in `dir` (a digraph such as `net-20`) as paths under ROOT, sorted; empty when hxc
	// carries none for it.
	public static function files(dir:String):Array<String> {
		var prefix = dir + "/";
		return [for (p in paths) if (StringTools.startsWith(p, prefix) && p.indexOf("/", prefix.length) < 0) ROOT + p];
	}

	// A library file's bytes: an embedded one's under ROOT, else the file's.
	public static function getBytes(file:String):Bytes {
		if (!isVirtual(file)) return sys.io.File.getBytes(file);
		lock.acquire();
		try {
			var b = cache.get(file);
			if (b == null) {
				#if cs
				var zipped = haxe.Resource.getBytes("hxc-netlib/" + file.substr(ROOT.length));
				#else
				var text = packed(file.substr(ROOT.length));
				var zipped = text == null ? null : haxe.crypto.Base64.decode(text);
				#end
				if (zipped == null) throw file + " is not embedded in hxc";
				b = hxc.eval.HostZip.HostUncompress.run(zipped);
				cache.set(file, b);
			}
			lock.release();
			return b;
		} catch (e:Dynamic) {
			lock.release();
			throw e;
		}
	}
}
