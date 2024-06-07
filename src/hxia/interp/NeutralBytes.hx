package hxia.interp;

// The cppia Bytes: cpp inlines get/set into direct integer indexing on the internal buffer
// `b` (std/haxe/io/Bytes.hx get/set are `inline`), while getString/toHex/blit/sub/compare/fill
// stay real method calls. A host Bytes has a target-specific buffer that the inlined indexing
// would not match, so this shim reproduces the representation the cppia targets: `b` is an
// integer-indexed byte array and `length` is a field, both reached directly by the inlined
// ops. String and hex conversions defer to a host Bytes so encoding stays correct on every
// target.
class NeutralBytes {
	public var length:Int;
	public var b:Array<Int>;

	public function new(length:Int, b:Array<Int>) {
		this.length = length;
		this.b = b;
	}

	public static function alloc(length:Int):NeutralBytes {
		return new NeutralBytes(length, [for (_ in 0...length) 0]);
	}

	public static function ofString(s:String):NeutralBytes {
		var hb = haxe.io.Bytes.ofString(s);
		return fromHost(hb);
	}

	public static function ofHex(s:String):NeutralBytes {
		return fromHost(haxe.io.Bytes.ofHex(s));
	}

	public static function fromHost(hb:haxe.io.Bytes):NeutralBytes {
		return new NeutralBytes(hb.length, [for (i in 0...hb.length) hb.get(i)]);
	}

	// getData/ofData expose the LIVE integer buffer (BytesData on this shim): the cppia inlines
	// Bytes.fastGet into direct indexing on it, and TestBytes mutates a Bytes through data read
	// back with getData, so the two must share the array, not copy it.
	public function getData():Array<Int>
		return b;

	public static function ofData(x:Array<Int>):NeutralBytes
		return new NeutralBytes(x.length, x);

	public function toHost():haxe.io.Bytes {
		var hb = haxe.io.Bytes.alloc(length);
		for (i in 0...length)
			hb.set(i, b[i] & 0xFF);
		return hb;
	}

	// Get/set are inlined into `b` indexing by the cpp writer in most positions, but the writer still
	// emits real calls in some (e.g. through Dynamic), so expose them too.
	public function get(pos:Int):Int
		return b[pos] & 0xFF;

	public function set(pos:Int, v:Int):Void
		b[pos] = v & 0xFF;

	public function getString(pos:Int, len:Int):String
		return toHost().getString(pos, len);

	public function toHex():String
		return toHost().toHex();

	public function toString():String
		return toHost().toString();

	public function blit(pos:Int, src:NeutralBytes, srcpos:Int, len:Int):Void {
		// haxe.io.Bytes.blit throws OutsideBounds on an out-of-range request; TestBytes relies on the
		// throw (exc(...)) and, without it, a silent over-copy corrupts the buffer for later asserts.
		if (pos < 0 || srcpos < 0 || len < 0 || pos + len > length || srcpos + len > src.length)
			throw haxe.io.Error.OutsideBounds;
		// haxe.io.Bytes.blit is memmove-safe: an overlapping copy within the same buffer where the
		// destination is above the source must run backward, or a naive forward copy propagates the
		// first bytes over the rest (TestBytes' `b.blit(4, b, 3, 3)`).
		if (src == this && pos > srcpos) {
			var i = len;
			while (i-- > 0)
				b[pos + i] = src.b[srcpos + i];
		} else {
			for (i in 0...len)
				b[pos + i] = src.b[srcpos + i];
		}
	}

	public function fill(pos:Int, len:Int, value:Int):Void {
		for (i in 0...len)
			b[pos + i] = value & 0xFF;
	}

	public function sub(pos:Int, len:Int):NeutralBytes {
		return new NeutralBytes(len, [for (i in 0...len) b[pos + i]]);
	}

	public function compare(other:NeutralBytes):Int {
		var len = length < other.length ? length : other.length;
		for (i in 0...len) {
			var d = b[i] - other.b[i];
			if (d != 0)
				return d;
		}
		return length - other.length;
	}
}
