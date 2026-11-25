package hxc.codegen.dotnet;

import haxe.Int64;
import haxe.io.Bytes;

// A growable little-endian byte buffer for metadata, signatures, IL and the PE image, with the
// ECMA-335 II.23.2 compressed integers and II.23.3's SerString.

class IlBytes {
	var buf:Bytes;

	public var length(default, null):Int = 0;

	public function new() {
		buf = Bytes.alloc(256);
	}

	inline function ensure(n:Int):Void {
		if (length + n > buf.length) {
			var size = buf.length * 2;
			while (size < length + n) size *= 2;
			var nb = Bytes.alloc(size);
			nb.blit(0, buf, 0, length);
			buf = nb;
		}
	}

	public function u8(v:Int):Void {
		ensure(1);
		buf.set(length++, v);
	}

	public function u16(v:Int):Void {
		ensure(2);
		buf.set(length++, v);
		buf.set(length++, v >> 8);
	}

	public function u32(v:Int):Void {
		ensure(4);
		buf.setInt32(length, v);
		length += 4;
	}

	public function i64(v:Int64):Void {
		u32(v.low);
		u32(v.high);
	}

	public function f32(v:Float):Void {
		ensure(4);
		buf.setFloat(length, v);
		length += 4;
	}

	public function f64(v:Float):Void {
		ensure(8);
		buf.setDouble(length, v);
		length += 8;
	}

	public function bytes(b:Bytes):Void {
		ensure(b.length);
		buf.blit(length, b, 0, b.length);
		length += b.length;
	}

	// 1, 2 or 4 bytes, big-endian, for 0 to 0x1FFFFFFF.
	public function compressedU32(v:Int):Void {
		if (v < 0 || v > 0x1FFFFFFF) throw "compressed integer out of range: " + v;
		if (v < 0x80) {
			u8(v);
		} else if (v < 0x4000) {
			u8(0x80 | (v >> 8));
			u8(v & 0xFF);
		} else {
			u8(0xC0 | (v >> 24));
			u8((v >> 16) & 0xFF);
			u8((v >> 8) & 0xFF);
			u8(v & 0xFF);
		}
	}

	// A SerString (II.23.3): the UTF-8 bytes after their compressed length; 0xFF for null.
	public function serString(s:Null<String>):Void {
		if (s == null) {
			u8(0xFF);
			return;
		}
		var b = haxe.io.Bytes.ofString(s);
		compressedU32(b.length);
		bytes(b);
	}

	// The value's bits rotated left by one within the width, so the sign bit comes last.
	public function compressedI32(v:Int):Void {
		var sign = v >> 31;
		if ((v & ~0x3F) == (sign & ~0x3F)) {
			u8(((v & 0x3F) << 1) | (sign & 1));
		} else if ((v & ~0x1FFF) == (sign & ~0x1FFF)) {
			var n = ((v & 0x1FFF) << 1) | (sign & 1);
			u8(0x80 | (n >> 8));
			u8(n & 0xFF);
		} else if ((v & ~0xFFFFFFF) == (sign & ~0xFFFFFFF)) {
			var n = ((v & 0xFFFFFFF) << 1) | (sign & 1);
			u8(0xC0 | (n >>> 24));
			u8((n >> 16) & 0xFF);
			u8((n >> 8) & 0xFF);
			u8(n & 0xFF);
		} else {
			throw "compressed integer out of range: " + v;
		}
	}

	// Zero fill up to a multiple of n.
	public function align(n:Int):Void {
		while (length % n != 0) u8(0);
	}

	// Drops everything from `to` on.
	public function truncate(to:Int):Void {
		length = to;
	}

	public function patchU32(pos:Int, v:Int):Void {
		buf.setInt32(pos, v);
	}

	public function getBytes():Bytes {
		return buf.sub(0, length);
	}
}
