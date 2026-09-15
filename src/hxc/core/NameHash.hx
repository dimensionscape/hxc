package hxc.core;

import hxc.core.Globals.Path;

// The generic structural hash for the value shapes hxc needs, plus a hash table's bucket-order model.
// Blocks mix (size << 10) | tag, the empty list mixes its immediate representation (raw 1), strings mix
// 4-byte LE words with the 3/2/1-byte tail and a length XOR, traversal is breadth-first over at most 10
// meaningful nodes, and the final avalanche masks to 30 bits.
class NameHash {
	static inline function rotl(x:Int, n:Int):Int return ((x << n) | (x >>> (32 - n)));

	static function mix(h:Int, d:Int):Int {
		d = mul32(d, 0xcc9e2d51);
		d = rotl(d, 15);
		d = mul32(d, 0x1b873593);
		h ^= d;
		h = rotl(h, 13);
		h = mul32(h, 5) + 0xe6546b64;
		return h | 0;
	}

	// 32-bit overflow-safe multiply (hxcpp Int is 32-bit; keep explicit for clarity)
	static inline function mul32(a:Int, b:Int):Int {
		var aLo = a & 0xFFFF, aHi = a >>> 16;
		return ((aLo * b) + (((aHi * b) & 0xFFFF) << 16)) | 0;
	}

	static function mixString(h:Int, s:String):Int {
		var b = haxe.io.Bytes.ofString(s);
		var n = b.length;
		var i = 0;
		while (i + 4 <= n) {
			h = mix(h, b.get(i) | (b.get(i + 1) << 8) | (b.get(i + 2) << 16) | (b.get(i + 3) << 24));
			i += 4;
		}
		var r = n & 3;
		if (r != 0) {
			var w = 0;
			if (r == 3) w = b.get(i + 2) << 16;
			if (r >= 2) w |= b.get(i + 1) << 8;
			w |= b.get(i);
			h = mix(h, w);
		}
		return h ^ n;
	}

	static function finalMix(h:Int):Int {
		h ^= h >>> 16;
		h = mul32(h, 0x85ebca6b);
		h ^= h >>> 13;
		h = mul32(h, 0xc2b2ae35);
		h ^= h >>> 16;
		return h & 0x3FFFFFFF;
	}

	// The hash of a plain string (one string mix from seed 0, then the final avalanche) - the hash of a
	// Path.UniqueKey file key.
	public static function stringHash(s:String):Int {
		return finalMix(mixString(0, s));
	}

	public static function pathHash(pack:Array<String>, name:String):Int {
		// Breadth-first queue: 0 = tuple, 1 = list suffix (index into pack), 2 = string
		var kinds:Array<Int> = [0];
		var listIdx:Array<Int> = [0];
		var strs:Array<String> = [null];
		var h = 0, num = 10, rd = 0;
		inline function push(kind:Int, li:Int, s:String):Void {
			if (kinds.length < 100) { kinds.push(kind); listIdx.push(li); strs.push(s); }
		}
		while (rd < kinds.length && num > 0) {
			var kind = kinds[rd], li = listIdx[rd], s = strs[rd];
			rd++;
			switch (kind) {
				case 0:
					h = mix(h, (2 << 10) | 0);
					num--;
					push(1, 0, null);
					push(2, 0, name);
				case 1:
					if (li >= pack.length) {
						// [] is the immediate 0, whose tagged representation hashes as 1
						h = mix(h, 1);
						num--;
					} else {
						h = mix(h, (2 << 10) | 0);
						num--;
						push(2, 0, pack[li]);
						push(1, li + 1, null);
					}
				case _:
					h = mixString(h, s);
					num--;
			}
		}
		return finalMix(h);
	}
}

// The hash table insertion/bucket model: create 0 rounds the capacity to 16, add prepends into hash
// & (cap-1) buckets and doubles when size exceeds twice the capacity, resize keeps per-bucket
// relative order (tail-append), replace of an existing key keeps its position, and fold visits
// buckets ascending, each front to back.
class HashTableOrder {
	var cap = 16;
	var size = 0;
	var buckets:Array<Array<{hash:Int, key:String}>> = [for (_ in 0...16) []];
	var known = new haxe.ds.StringMap<Bool>();

	public function new() {}

	public function add(key:String, hash:Int):Void {
		if (known.exists(key)) return; // Replacing a key keeps its position
		known.set(key, true);
		buckets[hash & (cap - 1)].unshift({hash: hash, key: key});
		size++;
		if (size > cap << 1) resize();
	}

	// Remove: out of its bucket; the table never shrinks.
	public function remove(key:String):Void {
		if (!known.exists(key)) return;
		known.remove(key);
		for (b in buckets) for (i in 0...b.length) if (b[i].key == key) {
			b.splice(i, 1);
			size--;
			return;
		}
	}

	function resize():Void {
		var ncap = cap << 1;
		var nb:Array<Array<{hash:Int, key:String}>> = [for (_ in 0...ncap) []];
		for (b in buckets) for (e in b) nb[e.hash & (ncap - 1)].push(e);
		cap = ncap;
		buckets = nb;
	}

	// Bucket visit order (fold argument order); a prepending fold REVERSES this.
	public function visitOrder():Array<String> {
		var out:Array<String> = [];
		for (b in buckets) for (e in b) out.push(e.key);
		return out;
	}
}
