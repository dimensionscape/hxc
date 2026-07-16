package hxc.compiler;

/**
 * A byte-preserving, length-prefixed request buffer. Two relay threads may append concurrently.
 */
class RequestOutput {
	var buf:haxe.io.BytesBuffer;
	var lock:sys.thread.Mutex;

	public function new() {
		buf = new haxe.io.BytesBuffer();
		lock = new sys.thread.Mutex();
	}

	public function add(s:String):Void {
		var b = haxe.io.Bytes.ofString(s);
		addBytes(b, 0, b.length);
	}

	public function addBytes(b:haxe.io.Bytes, pos:Int, len:Int):Void {
		lock.acquire();
		buf.addBytes(b, pos, len);
		lock.release();
	}

	// "\x01", then the text with every "\n" replaced by "\x01", then "\n".
	public function writeOut(b:haxe.io.Bytes, pos:Int, len:Int):Void {
		var e = haxe.io.Bytes.alloc(len + 2);
		e.set(0, 1);
		for (i in 0...len) {
			var c = b.get(pos + i);
			e.set(i + 1, c == "\n".code ? 1 : c);
		}
		e.set(len + 1, "\n".code);
		addBytes(e, 0, e.length);
	}

	public function getBytes():haxe.io.Bytes {
		lock.acquire();
		var b = buf.getBytes();
		lock.release();
		return b;
	}
}
