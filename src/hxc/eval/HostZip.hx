package hxc.eval;

/**
	The zlib streams a macro's haxe.zip.Compress and haxe.zip.Uncompress run on.

	On C++ they are the standard library's own classes. The C# standard library has none, so a .NET-hosted
	hxc built with -D hxc_zlib_netlib has these, over tools/dotnet-host's HxcHostNative.dll (--net-lib)
	and the zlib it loads: the same zlib, with the same calls in the same order as the C++ classes make,
	so that a macro gets the same bytes and the same errors from either compiler. Anywhere else there is
	none, and the standard library's classes say so.
**/
#if (cs && hxc_zlib_netlib)
class HostCompress {
	var z:hxchost.Zlib;

	public function new(level:Int) {
		var error = new cs.NativeArray<Int>(1);
		z = hxchost.Zlib.Deflate(level, error);
		if (z == null) throw "ZLib Error " + error[0];
	}

	public function execute(src:haxe.io.Bytes, srcPos:Int, dst:haxe.io.Bytes, dstPos:Int):{done:Bool, read:Int, write:Int} {
		if (z.Closed) throw "Compress closed";
		var counts = new cs.NativeArray<Int>(2);
		var code = z.Run(src.getData(), srcPos, dst.getData(), dstPos, counts);
		if (code < 0) throw HostZip.error(z, code);
		return {done: code == HostZip.STREAM_END, read: counts[0], write: counts[1]};
	}

	public function setFlushMode(f:haxe.zip.FlushMode):Void {
		if (z.Closed) throw "Compress closed";
		z.Flush = HostZip.flush(f);
	}

	public function close():Void {
		z.Close();
	}

	// As the C++ class runs it: one finishing call into a buffer of the size deflateBound gives.
	public static function run(s:haxe.io.Bytes, level:Int):haxe.io.Bytes {
		var c = new HostCompress(level);
		c.setFlushMode(haxe.zip.FlushMode.FINISH);
		var bound = c.z.Bound(s.length);
		if (bound < 0) {
			c.close();
			throw "Size Error";
		}
		var out = haxe.io.Bytes.alloc(bound);
		var r = c.execute(s, 0, out, 0);
		c.close();
		if (!r.done || r.read != s.length) throw "Compression failed";
		return out.sub(0, r.write);
	}
}

class HostUncompress {
	var z:hxchost.Zlib;

	public function new(?windowBits:Int) {
		var error = new cs.NativeArray<Int>(1);
		z = hxchost.Zlib.Inflate(windowBits == null ? 15 : windowBits, error);
		if (z == null) throw "ZLib Error " + error[0];
	}

	public function execute(src:haxe.io.Bytes, srcPos:Int, dst:haxe.io.Bytes, dstPos:Int):{done:Bool, read:Int, write:Int} {
		if (z.Closed) throw "Uncompress closed";
		var counts = new cs.NativeArray<Int>(2);
		var code = z.Run(src.getData(), srcPos, dst.getData(), dstPos, counts);
		// A stream that wants a preset dictionary repeats that answer without reading anything.
		if (code < 0 || code == HostZip.NEED_DICT) throw HostZip.error(z, code);
		return {done: code == HostZip.STREAM_END, read: counts[0], write: counts[1]};
	}

	public function setFlushMode(f:haxe.zip.FlushMode):Void {
		if (z.Closed) throw "Uncompress closed";
		z.Flush = HostZip.flush(f);
	}

	public function close():Void {
		z.Close();
	}

	// As the C++ class runs it: sync-flushed calls into a buffer of `bufsize`, until the stream ends.
	public static function run(src:haxe.io.Bytes, ?bufsize:Int):haxe.io.Bytes {
		var u = new HostUncompress(null);
		if (bufsize == null) bufsize = 1 << 16;
		var tmp = haxe.io.Bytes.alloc(bufsize);
		var b = new haxe.io.BytesBuffer();
		var pos = 0;
		u.setFlushMode(haxe.zip.FlushMode.SYNC);
		while (true) {
			var r = try u.execute(src, pos, tmp, 0) catch (e:Dynamic) {
				u.close();
				throw e;
			};
			b.addBytes(tmp, 0, r.write);
			pos += r.read;
			if (r.done) break;
		}
		u.close();
		return b.getBytes();
	}
}

class HostZip {
	public static inline var STREAM_END = 1;
	public static inline var NEED_DICT = 2;

	// zlib's flush values.
	public static function flush(f:haxe.zip.FlushMode):Int {
		return switch (f) {
			case NO: 0;
			case SYNC: 2;
			case FULL: 3;
			case FINISH: 4;
			case BLOCK: 5;
		};
	}

	// zlib's code and, when it has one, its message.
	public static function error(z:hxchost.Zlib, code:Int):String {
		var msg = haxe.io.Bytes.ofData(z.Message()).toString();
		return "ZLib Error " + code + (msg == "" ? "" : " (" + msg + ")");
	}
}
#else
typedef HostCompress = haxe.zip.Compress;
typedef HostUncompress = haxe.zip.Uncompress;
#end
