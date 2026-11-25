package hxc.codegen.dotnet;

import haxe.io.Bytes;

// The four metadata heaps (ECMA-335 II.24.2.2-4). Entries are deduped and kept in first-added order,
// so the same adds always give the same heap.

class MetaHeaps {
	public final strings = new StringHeap();
	public final userStrings = new UserStringHeap();
	public final blobs = new BlobHeap();
	public final guids = new GuidHeap();

	public function new() {}

	// An index into a heap needs 4 bytes once the heap reaches 64K.
	public static inline function large(b:IlBytes):Bool {
		return b.length >= 0x10000;
	}

	public static function padded(b:IlBytes):Bytes {
		var out = new IlBytes();
		out.bytes(b.getBytes());
		out.align(4);
		return out.getBytes();
	}
}

// #Strings: null-terminated UTF-8, starting with the empty string at 0.
class StringHeap {
	final data = new IlBytes();
	final index = new Map<String, Int>();

	public function new() {
		data.u8(0);
	}

	public function add(s:String):Int {
		if (s == "") return 0;
		var i = index.get(s);
		if (i != null) return i;
		i = data.length;
		data.bytes(Bytes.ofString(s));
		data.u8(0);
		index.set(s, i);
		return i;
	}

	public function bytes():Bytes return MetaHeaps.padded(data);

	public function isLarge():Bool return MetaHeaps.large(data);
}

// #US: the strings ldstr loads, as UTF-16LE with a compressed length and a final flag byte.
class UserStringHeap {
	final data = new IlBytes();
	final index = new Map<String, Int>();

	public function new() {
		data.u8(0);
	}

	public function add(s:String):Int {
		var i = index.get(s);
		if (i != null) return i;
		i = data.length;
		var units = [];
		for (c in new haxe.iterators.StringIteratorUnicode(s)) {
			if (c >= 0x10000) {
				units.push(0xD800 | ((c - 0x10000) >> 10));
				units.push(0xDC00 | ((c - 0x10000) & 0x3FF));
			} else {
				units.push(c);
			}
		}
		// The flag is 1 when some char needs more than 8-bit handling when compared.
		var special = 0;
		for (u in units)
			if (u >= 0x7F || (u >= 0x01 && u <= 0x08) || (u >= 0x0E && u <= 0x1F) || u == 0x27 || u == 0x2D) special = 1;
		data.compressedU32(units.length * 2 + 1);
		for (u in units) data.u16(u);
		data.u8(special);
		index.set(s, i);
		return i;
	}

	public function bytes():Bytes return MetaHeaps.padded(data);

	public function isLarge():Bool return MetaHeaps.large(data);
}

// #Blob: length-prefixed byte runs, starting with the empty blob at 0.
class BlobHeap {
	final data = new IlBytes();
	final index = new Map<String, Int>();

	public function new() {
		data.u8(0);
	}

	public function add(b:Bytes):Int {
		if (b.length == 0) return 0;
		var key = b.toHex();
		var i = index.get(key);
		if (i != null) return i;
		i = data.length;
		data.compressedU32(b.length);
		data.bytes(b);
		index.set(key, i);
		return i;
	}

	public function bytes():Bytes return MetaHeaps.padded(data);

	public function isLarge():Bool return MetaHeaps.large(data);
}

// #GUID: 16-byte entries, indexed from 1.
class GuidHeap {
	final data = new IlBytes();

	public function new() {}

	public function add(g:Bytes):Int {
		if (g.length != 16) throw "a GUID is 16 bytes";
		data.bytes(g);
		return data.length >> 4;
	}

	public function bytes():Bytes return data.getBytes();

	public function isLarge():Bool return MetaHeaps.large(data);
}
