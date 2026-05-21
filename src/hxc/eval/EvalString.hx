package hxc.eval;

import hxc.eval.EvalValue;
import hxc.eval.EvalExceptions.HostException;

/**
 * A byte string: a sequence of bytes. A string's content is kept as its UTF-8 bytes, which is what
 * lets it hold what no Unicode text can - a code past U+10FFFF or a surrogate (any char code below
 * 2^31 is encoded), and the raw bytes Bytes.getString hands over.
 *
 * The host String underneath holds one char per byte (0-255), which hxcpp keeps as an 8-bit string,
 * so concatenation, substrings, equality, ordering and map keys all act on the bytes. A host TEXT
 * string with a Latin-1 char is stored exactly like the byte string of that char's value, so there
 * is deliberately no implicit conversion either way: text crosses with ofText / toText (UTF-8), and
 * ofRaw / raw are for strings already known to be one char per byte.
 */
abstract ByteString(String) {
	inline function new(s:String) this = s;

	public static var empty(get, never):ByteString;

	static inline function get_empty():ByteString return new ByteString("");

	public var length(get, never):Int;

	inline function get_length():Int return this.length;

	/** A host string already holding one char per byte - an ASCII literal, or what a ByteBuffer built. */
	public static inline function ofRaw(s:String):ByteString return new ByteString(s);

	/** The host string underneath, one char per byte: for hashing, map keys and ASCII-only tests. */
	public inline function raw():String return this;

	/** The byte at i: an "index out of bounds" error past either end. */
	public inline function get(i:Int):Int {
		if (i < 0 || i >= this.length) throw new HostException('Invalid_argument("index out of bounds")');
		return StringTools.fastCodeAt(this, i);
	}

	/** The byte at i, unchecked. Only used within the string; hxcpp answers 0 outside. */
	public inline function unsafeGet(i:Int):Int return StringTools.fastCodeAt(this, i);

	/**
	 * Sub: Invalid_argument "String.sub / Bytes.sub" when the range leaves the string.
	 */
	public function sub(pos:Int, len:Int):ByteString {
		if (pos < 0 || len < 0 || pos > this.length - len)
			throw new HostException('Invalid_argument("String.sub / Bytes.sub")');
		return new ByteString(this.substr(pos, len));
	}

	@:op(A + B) static inline function concat(a:ByteString, b:ByteString):ByteString
		return new ByteString(a.raw() + b.raw());

	// Text and bytes do not concatenate: Haxe would stringify the other side silently. These make the
	// mix a type that nothing accepts, so it is caught where it is written.
	@:op(A + B) static inline function mixTextRight(a:ByteString, b:String):TextByteMix return null;

	@:op(A + B) static inline function mixTextLeft(a:String, b:ByteString):TextByteMix return null;

	/** Stdlib.compare on two strings: bytewise and unsigned, a proper prefix first. */
	public static function compare(a:ByteString, b:ByteString):Int {
		var la = a.length, lb = b.length;
		var n = la < lb ? la : lb;
		for (i in 0...n) {
			var x = a.unsafeGet(i), y = b.unsafeGet(i);
			if (x != y) return x < y ? -1 : 1;
		}
		return la == lb ? 0 : (la < lb ? -1 : 1);
	}

	public function isAscii():Bool {
		for (i in 0...this.length) if (StringTools.fastCodeAt(this, i) >= 0x80) return false;
		return true;
	}

	/**
		Host text as UTF-8 bytes: what every string the compiler hands the interpreter holds (the lexer
		keeps a literal as UTF-8, and a `\u` escape is encoded as UTF-8, a lone surrogate included).
	**/
	public static function ofText(t:String):ByteString {
		var i = 0, n = t.length;
		while (i < n && StringTools.fastCodeAt(t, i) < 0x80) i++;
		if (i == n) return new ByteString(t);
		var buf = new ByteBuffer();
		buf.addString(new ByteString(t.substr(0, i)));
		while (i < n) {
			var c = StringTools.fastCodeAt(t, i++);
			if (c >= 0xD800 && c <= 0xDBFF && i < n) {
				var c2 = StringTools.fastCodeAt(t, i);
				if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
					i++;
					c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
				}
			}
			Utf8.addUchar(buf, c);
		}
		return buf.contents();
	}

	/**
		The bytes as host text, for a string leaving the interpreter for the compiler or the host (a
		path, a define, a message). A sequence that is not UTF-8 of a Unicode scalar value becomes
		U+FFFD, byte by byte.
	**/
	public function toText():String {
		var n = this.length, i = 0;
		while (i < n && StringTools.fastCodeAt(this, i) < 0x80) i++;
		if (i == n) return this;
		var buf = new StringBuf();
		buf.add(this.substr(0, i));
		while (i < n) {
			var c = StringTools.fastCodeAt(this, i);
			var k = c < 0x80 ? 1 : (c >= 0xC2 && c <= 0xDF ? 2 : (c >= 0xE0 && c <= 0xEF ? 3 : (c >= 0xF0 && c <= 0xF4 ? 4 : 0)));
			var code = -1;
			if (k == 1) code = c;
			else if (k > 1 && i + k <= n) {
				code = c & (0xFF >> (k + 1));
				for (j in 1...k) {
					var m = StringTools.fastCodeAt(this, i + j);
					if (m < 0x80 || m > 0xBF) { code = -1; break; }
					code = (code << 6) | (m & 0x3F);
				}
				var min = k == 2 ? 0x80 : (k == 3 ? 0x800 : 0x10000);
				if (code < min || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) code = -1;
			}
			if (code < 0) {
				buf.addChar(0xFFFD);
				i++;
			} else {
				buf.addChar(code);
				i += k;
			}
		}
		return buf.toString();
	}

	public static function ofBytes(b:haxe.io.Bytes, pos:Int, len:Int):ByteString {
		var buf = new ByteBuffer();
		for (i in pos...pos + len) buf.addByte(b.get(i));
		return buf.contents();
	}

	public function toBytes():haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(this.length);
		for (i in 0...this.length) b.set(i, StringTools.fastCodeAt(this, i));
		return b;
	}
}

/** What `text + bytes` types as: no String, ByteString or other value accepts it. */
class TextByteMix {}

/** A byte buffer (also the UTF-8 buffer). */
class ByteBuffer {
	var buf:StringBuf;

	/** Buffer.length: the byte count so far. */
	public var length(default, null):Int = 0;

	public function new() {
		buf = new StringBuf();
	}

	/**
	 * C is a byte, 0-255.
	 */
	public inline function addByte(c:Int):Void {
		buf.addChar(c);
		length++;
	}

	public inline function addString(s:ByteString):Void {
		buf.add(s.raw());
		length += s.length;
	}

	/** A substring append: Invalid_argument "Buffer.add_substring/add_subbytes" out of range. */
	public function addSub(s:ByteString, pos:Int, len:Int):Void {
		if (pos < 0 || len < 0 || pos > s.length - len)
			throw new HostException('Invalid_argument("Buffer.add_substring/add_subbytes")');
		buf.addSub(s.raw(), pos, len);
		length += len;
	}

	public inline function contents():ByteString return ByteString.ofRaw(buf.toString());
}

/** The UTF-8 walk strings are read with, lenient as it is. */
class Utf8 {
	/**
		The code at byte i.
	*/
	public static function look(s:ByteString, i:Int):Int {
		var n = s.get(i);
		if (n < 0x80) return n;
		if (n <= 0xdf) return ((n - 0xc0) << 6) | (0x7f & s.get(i + 1));
		if (n <= 0xef) {
			var n1 = n - 0xe0;
			var m0 = s.get(i + 2);
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 1));
			return (n1 << 6) | (0x7f & m0);
		}
		if (n <= 0xf7) {
			var n1 = n - 0xf0;
			var m0 = s.get(i + 3);
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 1));
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 2));
			return (n1 << 6) | (0x7f & m0);
		}
		if (n <= 0xfb) {
			var n1 = n - 0xf8;
			var m0 = s.get(i + 4);
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 1));
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 2));
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 3));
			return (n1 << 6) | (0x7f & m0);
		}
		if (n <= 0xfd) {
			var n1 = n - 0xfc;
			var m0 = s.get(i + 5);
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 1));
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 2));
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 3));
			n1 = (n1 << 6) | (0x7f & s.unsafeGet(i + 4));
			return (n1 << 6) | (0x7f & m0);
		}
		throw new HostException('Invalid_argument("UTF8.look")');
	}

	static function searchHead(s:ByteString, i:Int):Int {
		while (true) {
			if (i >= s.length) return i;
			var n = s.unsafeGet(i);
			if (n < 0x80 || n >= 0xc2) return i;
			i++;
		}
	}

	public static function next(s:ByteString, i:Int):Int {
		var n = s.get(i);
		if (n < 0x80) return i + 1;
		if (n < 0xc0) return searchHead(s, i + 1);
		if (n <= 0xdf) return i + 2;
		if (n <= 0xef) return i + 3;
		if (n <= 0xf7) return i + 4;
		if (n <= 0xfb) return i + 5;
		if (n <= 0xfd) return i + 6;
		throw new HostException('Invalid_argument("UTF8.next")');
	}

	static function searchHeadBackward(s:ByteString, i:Int):Int {
		while (true) {
			if (i < 0) return -1;
			var n = s.get(i);
			if (n < 0x80 || n >= 0xc2) return i;
			i--;
		}
	}

	public static inline function prev(s:ByteString, i:Int):Int return searchHeadBackward(s, i - 1);

	public static function move(s:ByteString, i:Int, n:Int):Int {
		if (n >= 0) {
			while (n > 0) { i = next(s, i); n--; }
		} else {
			while (n < 0) { i = prev(s, i); n++; }
		}
		return i;
	}

	public static function length(s:ByteString):Int {
		var c = 0, i = 0, n = s.length;
		while (i < n) {
			var b = s.unsafeGet(i);
			var k = if (b < 0x80) 1
				else if (b < 0xc0) throw new HostException('Invalid_argument("UTF8.length")')
				else if (b < 0xe0) 2
				else if (b < 0xf0) 3
				else if (b < 0xf8) 4
				else if (b < 0xfc) 5
				else if (b < 0xfe) 6
				else throw new HostException('Invalid_argument("UTF8.length")');
			c++;
			i += k;
		}
		return c;
	}

	/** The UTF-8 length, or the byte count when the string is not valid UTF-8. */
	public static function lengthOrBytes(s:ByteString):Int {
		return try length(s) catch (_:HostException) s.length;
	}

	public static function iter(s:ByteString, f:Int->Void):Void {
		var i = 0;
		while (i < s.length) {
			f(look(s, i));
			i = next(s, i);
		}
	}

	public static function validate(s:ByteString):Bool {
		var n = s.length, i = 0;
		function trail(c:Int, i:Int, a:Int):Int {
			while (c > 0) {
				if (i >= n) return -1;
				var b = s.unsafeGet(i);
				if (b < 0x80 || b >= 0xc0) return -1;
				a = (a << 6) | (b - 0x80);
				c--;
				i++;
			}
			return a;
		}
		while (i < n) {
			var b = s.unsafeGet(i);
			if (b < 0x80) { i++; continue; }
			if (b < 0xc2) return false;
			if (b <= 0xdf) {
				var t = trail(1, i + 1, b - 0xc0);
				if (t < 0 || t < 0x80) return false;
				i += 2;
			} else if (b <= 0xef) {
				var t = trail(2, i + 1, b - 0xe0);
				if (t < 0 || t < 0x800) return false;
				i += 3;
			} else if (b <= 0xf7) {
				var t = trail(3, i + 1, b - 0xf0);
				if (t < 0 || t < 0x10000) return false;
				i += 4;
			} else if (b <= 0xfb) {
				var t = trail(4, i + 1, b - 0xf8);
				if (t < 0 || t < 0x200000) return false;
				i += 5;
			} else if (b <= 0xfd) {
				var t = trail(5, i + 1, b - 0xfc);
				if (t < 0 || (t >>> 16) < 0x400) return false;
				i += 6;
			} else return false;
		}
		return true;
	}

	/**
		Append a code as UTF-8. A negative code - what look reads from a continuation byte in lead
		position, which case mapping passes straight back - takes the six-byte arm, where a 63-bit right
		shift by 30 is far past a byte and the char conversion raises.
	*/
	public static function addUchar(buf:ByteBuffer, k:Int):Void {
		var masq = 0x3f;
		if (k < 0) throw new HostException('Invalid_argument("Char.chr")');
		if (k >= 0x4000000) {
			buf.addByte(0xfc + (k >>> 30));
			buf.addByte(0x80 | ((k >>> 24) & masq));
			buf.addByte(0x80 | ((k >>> 18) & masq));
			buf.addByte(0x80 | ((k >>> 12) & masq));
			buf.addByte(0x80 | ((k >>> 6) & masq));
			buf.addByte(0x80 | (k & masq));
		} else if (k <= 0x7f) {
			buf.addByte(k);
		} else if (k <= 0x7ff) {
			buf.addByte(0xc0 | (k >> 6));
			buf.addByte(0x80 | (k & masq));
		} else if (k <= 0xffff) {
			buf.addByte(0xe0 | (k >> 12));
			buf.addByte(0x80 | ((k >> 6) & masq));
			buf.addByte(0x80 | (k & masq));
		} else if (k <= 0x1fffff) {
			buf.addByte(0xf0 + (k >> 18));
			buf.addByte(0x80 | ((k >> 12) & masq));
			buf.addByte(0x80 | ((k >> 6) & masq));
			buf.addByte(0x80 | (k & masq));
		} else {
			buf.addByte(0xf8 + (k >> 24));
			buf.addByte(0x80 | ((k >> 18) & masq));
			buf.addByte(0x80 | ((k >> 12) & masq));
			buf.addByte(0x80 | ((k >> 6) & masq));
			buf.addByte(0x80 | (k & masq));
		}
	}

	/** A code outside 0 to 2^31-1 is Invalid_argument. */
	public static function ucharOfInt(n:Int):Int {
		if (n < 0) throw new HostException('Invalid_argument("UChar.uint_chr")');
		return n;
	}

	/** The UTF-8 encoding of one code point. */
	public static function encode(k:Int):ByteString {
		var buf = new ByteBuffer();
		addUchar(buf, k);
		return buf.contents();
	}
}

/** A character index and the byte offset it starts at. */
class OffsetCursor {
	public var cIndex:Int;
	public var bOffset:Int;

	public function new(cIndex:Int, bOffset:Int) {
		this.cIndex = cIndex;
		this.bOffset = bOffset;
	}
}

/** What the substring search loop (findSubstring) answers on a hit: the match's char index, byte offset and end. */
typedef SubstringHit = {c:Int, b:Int, next:Int};

class EvalString {
	public static inline function createAscii(s:ByteString):VString return new VString(s, s.length);

	public static inline function createWithLength(s:ByteString, length:Int):VString return new VString(s, length);

	public static function emptyString():VString return createAscii(ByteString.empty);

	public static inline function vEmptyString():EvalValue return VString(emptyString());

	/** createUnknownVString: the length in UTF-8 characters, or the byte count when that fails. */
	public static function createUnknownVString(s:ByteString):VString return createWithLength(s, Utf8.lengthOrBytes(s));

	/** How every string is encoded. */
	public static inline function createUnknown(s:ByteString):EvalValue return VString(createUnknownVString(s));

	/** A string the compiler or the host hands the interpreter: its UTF-8 bytes (createUnknownVString). */
	public static inline function ofText(t:String):VString return createUnknownVString(ByteString.ofText(t));

	public static inline function vOfText(t:String):EvalValue return VString(ofText(t));

	public static function concat(s1:VString, s2:VString):VString
		return createWithLength(s1.sstring + s2.sstring, s1.slength + s2.slength);

	public static function join(sep:VString, sl:Array<VString>):VString {
		var buf = new ByteBuffer();
		var length = 0;
		var first = true;
		for (s in sl) {
			if (!first) {
				length += sep.slength;
				buf.addString(sep.sstring);
			}
			length += s.slength;
			buf.addString(s.sstring);
			first = false;
		}
		return createWithLength(buf.contents(), length);
	}

	/**
		getOffsetPrime: the byte offset of character cIndex, walked from the nearer of the string's
		(at most two) cached cursors, and the cursor the caller then moves there.
	*/
	static function getOffsetPrime(s:VString, cIndex:Int):{b:Int, r:OffsetCursor} {
		var str = s.sstring;
		function getBOffset(cLen:Int, bOffset:Int):Int {
			while (cLen != 0) { bOffset = Utf8.next(str, bOffset); cLen--; }
			return bOffset;
		}
		function rgetBOffset(cLen:Int, bOffset:Int):Int {
			while (cLen != 0) { bOffset = Utf8.prev(str, bOffset); cLen++; }
			return bOffset;
		}
		if (s.soffsets == null) s.soffsets = [];
		var offs = s.soffsets;
		switch (offs.length) {
			case 0:
				var b = getBOffset(cIndex, 0);
				var r = new OffsetCursor(cIndex, b);
				offs.unshift(r);
				return {b: b, r: r};
			case 1:
				var r1 = offs[0];
				var cIndex1 = r1.cIndex;
				var bOffset1 = r1.bOffset;
				var diff = cIndex - cIndex1;
				var b = switch (diff) {
					case 0: bOffset1;
					case 1: Utf8.next(str, bOffset1);
					case -1: Utf8.prev(str, bOffset1);
					case _:
						if (diff > 0) getBOffset(diff, bOffset1)
						else if (cIndex + diff < 0) getBOffset(cIndex, 0)
						else rgetBOffset(diff, bOffset1);
				};
				// "If our jump is larger than the scientifically determined value 20, upgrade to two
				// offset pointers."
				var r = if (diff > 20 || diff < -20) {
					var r2 = new OffsetCursor(cIndex, b);
					offs.unshift(r2);
					r2;
				} else r1;
				return {b: b, r: r};
			case 2:
				var r1 = offs[0], r2 = offs[1];
				var cIndex1 = r1.cIndex, bOffset1 = r1.bOffset;
				var cIndex2 = r2.cIndex, bOffset2 = r2.bOffset;
				var diff1 = cIndex - cIndex1;
				var diff2 = cIndex - cIndex2;
				if (diff1 == 0) return {b: bOffset1, r: r1};
				if (diff2 == 0) return {b: bOffset2, r: r2};
				if (diff1 == 1) return {b: Utf8.next(str, bOffset1), r: r1};
				if (diff2 == 1) return {b: Utf8.next(str, bOffset2), r: r2};
				if (diff1 == -1) return {b: Utf8.prev(str, bOffset1), r: r1};
				if (diff2 == -1) return {b: Utf8.prev(str, bOffset2), r: r2};
				var r:OffsetCursor, diff:Int, bOffset0:Int;
				if (Std.int(Math.abs(diff1)) > Std.int(Math.abs(diff2))) {
					r = r2; diff = diff2; bOffset0 = bOffset2;
				} else {
					r = r1; diff = diff1; bOffset0 = bOffset1;
				}
				var b = if (diff > 0) getBOffset(diff, bOffset0)
					else if (cIndex + diff < 0) getBOffset(cIndex, 0)
					else rgetBOffset(diff, bOffset0);
				return {b: b, r: r};
			case _:
				throw new HostException("Globals.die");
		}
	}

	public static function getOffset(s:VString, cIndex:Int):Int {
		var o = getOffsetPrime(s, cIndex);
		o.r.cIndex = cIndex;
		o.r.bOffset = o.b;
		return o.b;
	}

	/** charAt: the code at character cIndex, decoded from its UTF-8 bytes, and the cursor moved past it. */
	public static function charAt(s:VString, cIndex:Int):Int {
		var o = getOffsetPrime(s, cIndex);
		var i = o.b;
		var str = s.sstring;
		var n = str.get(i);
		var char:Int, diff:Int;
		if (n < 0x80) {
			char = n; diff = 1;
		} else if (n <= 0xdf) {
			char = ((n - 0xc0) << 6) | (0x7f & str.get(i + 1)); diff = 2;
		} else if (n <= 0xef) {
			var n1 = n - 0xe0;
			var m0 = str.get(i + 2);
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 1));
			char = (n1 << 6) | (0x7f & m0); diff = 3;
		} else if (n <= 0xf7) {
			var n1 = n - 0xf0;
			var m0 = str.get(i + 3);
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 1));
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 2));
			char = (n1 << 6) | (0x7f & m0); diff = 4;
		} else if (n <= 0xfb) {
			var n1 = n - 0xf8;
			var m0 = str.get(i + 4);
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 1));
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 2));
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 3));
			char = (n1 << 6) | (0x7f & m0); diff = 5;
		} else if (n <= 0xfd) {
			var n1 = n - 0xfc;
			var m0 = str.get(i + 5);
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 1));
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 2));
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 3));
			n1 = (n1 << 6) | (0x7f & str.unsafeGet(i + 4));
			char = (n1 << 6) | (0x7f & m0); diff = 6;
		} else throw new HostException('Invalid_argument("UTF8.look")');
		o.r.cIndex = cIndex + 1;
		o.r.bOffset = o.b + diff;
		return char;
	}

	/** stringOfCharCode: the UTF-8 encoding of one code, range-checked by ucharOfInt. */
	public static function stringOfCharCode(i:Int):ByteString return Utf8.encode(Utf8.ucharOfInt(i));

	public static function fromCharCode(i:Int):VString return createWithLength(stringOfCharCode(i), 1);

	/** Find sub in this (from the end when reverse): the loop, answering null when it is not found. */
	public static function findSubstring(self:VString, sub:VString, reverse:Bool):(cIndex:Int, bIndex:Int) -> Null<SubstringHit> {
		var clThis = self.slength;
		var clSub = sub.slength;
		var blThis = self.sstring.length;
		var blSub = sub.sstring.length;
		var sThis = self.sstring;
		var sSub = sub.sstring;
		// 0 ScanHit, 1 ScanAscii, 2 ScanOther
		function scan(bIndex:Int, bLen:Int):Int {
			while (true) {
				var c = sThis.unsafeGet(bIndex + bLen);
				if (c == sSub.unsafeGet(bLen)) {
					if (bLen + 1 == blSub) return 0;
					bLen++;
				} else if (c <= 127) return 1;
				else return 2;
			}
		}
		if (!reverse) {
			return function(cIndex:Int, bIndex:Int):Null<SubstringHit> {
				while (true) {
					if (cIndex > clThis - clSub || bIndex >= blThis) return null;
					switch (scan(bIndex, 0)) {
						case 0: return {c: cIndex, b: bIndex, next: bIndex + blSub};
						case 1: cIndex++; bIndex++;
						case _: cIndex++; bIndex = Utf8.next(sThis, bIndex);
					}
				}
			};
		} else {
			return function(cIndex:Int, bIndex:Int):Null<SubstringHit> {
				while (true) {
					if (cIndex > clThis - clSub || bIndex < 0) return null;
					if (scan(bIndex, 0) == 0) return {c: cIndex, b: bIndex, next: bIndex + blSub};
					cIndex--;
					bIndex = Utf8.prev(sThis, bIndex);
				}
			};
		}
	}

	/** caseMap: each code through the case tables (EvalUnicase), the length kept. */
	public static function caseMap(self:VString, upper:Bool):VString {
		var buf = new ByteBuffer();
		var m = upper ? EvalUnicase.UPPER_BLOCKS : EvalUnicase.LOWER_BLOCKS;
		Utf8.iter(self.sstring, function(c:Int) {
			var up = c >>> 6;
			var uc = c;
			if (up < m && up >= 0) {
				var c2 = EvalUnicase.get(upper, up, c & ((1 << 6) - 1));
				if (c2 != 0) uc = Utf8.ucharOfInt(c2);
			}
			Utf8.addUchar(buf, uc);
		});
		return createWithLength(buf.contents(), self.slength);
	}

	public static function substr(self:VString, cIndex:Int, cLength:Int):VString {
		if (cLength < 0) return createWithLength(ByteString.empty, 0);
		var bOffset1 = getOffset(self, cIndex);
		var bOffset2 = Utf8.move(self.sstring, bOffset1, cLength);
		return createWithLength(self.sstring.sub(bOffset1, bOffset2 - bOffset1), cLength);
	}
}

class VStringBuffer {
	public var bbuffer:ByteBuffer;
	public var blength:Int;

	public function new() {
		bbuffer = new ByteBuffer();
		blength = 0;
	}

	public function addString(s:VString):Void {
		bbuffer.addString(s.sstring);
		blength += s.slength;
	}

	public function addSubstring(s:VString, bPos:Int, bLen:Int, cLen:Int):Void {
		bbuffer.addSub(s.sstring, bPos, bLen);
		blength += cLen;
	}

	public function contents():VString return EvalString.createWithLength(bbuffer.contents(), blength);
}
