/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package cs.internal;

@:native('haxe.lang.FieldHashConflict')
@:nativeGen @:keep
final class FieldHashConflict {
	@:readOnly public var hash(default, never):Int;
	@:readOnly public var name(default, never):String;
	public var value:Dynamic;
	public var next:FieldHashConflict;

	public function new(hash, name, value:Dynamic, next) {
		untyped this.hash = hash;
		untyped this.name = name;
		this.value = value;
		this.next = next;
	}
}

/**
	hxc: the field hashes FieldLookup knows, sorted, and their names, as one snapshot that is never
	changed once published, so a reader always sees ids and names that belong together.
**/
@:native('haxe.lang.FieldTable')
@:nativeGen @:keep
final class FieldTable {
	public var ids:cs.NativeArray<Int>;
	public var names:cs.NativeArray<String>;

	public function new(ids:cs.NativeArray<Int>, names:cs.NativeArray<String>) {
		this.ids = ids;
		this.names = names;
	}
}

/**
	hxc: thread-safe by design. Readers load the current snapshot once, with a volatile read, and use
	only that one; an insert copies the arrays under `lock(typeof(FieldLookup))` and publishes the new
	snapshot with one volatile write. hxcs's version grew its arrays in place, so a reader running
	beside an insert could see a name that did not belong to its hash (server app issue 6551).
**/
@:native('haxe.lang.FieldLookup')
@:nativeGen @:keep @:static
final class FieldLookup {
	@:volatile private static var table:FieldTable = new FieldTable(new cs.NativeArray(0), new cs.NativeArray(0));

	// s cannot be null here
	private static inline function doHash(s:String):Int {
		var acc = 0; // alloc_int
		var i = 0, len = s.length;
		while (i < len) {
			var c:Int = cast s[i];
			acc = ((223 * (acc >> 1) + c) << 1);
			i++;
		}

		return acc >>> 1; // always positive
	}

	public static function lookupHash(key:Int):String {
		var t = table;
		var i = findHash(key, t.ids, t.ids.Length);
		if (i >= 0)
			return t.names[i];
		// if not found, it's definitely an error
		throw "Field not found for hash " + key;
	}

	public static function hash(s:String):Int {
		if (s == null)
			return 0;

		var key = doHash(s);
		var t = table;
		var i = findHash(key, t.ids, t.ids.Length);
		if (i >= 0)
			return t.names[i] == s ? key : ~key; // special case

		cs.Lib.lock(FieldLookup, {
			// another thread may have inserted it since: look in the newest snapshot
			t = table;
			i = findHash(key, t.ids, t.ids.Length);
			if (i >= 0)
				return t.names[i] == s ? key : ~key;
			table = insertField(t, ~i, key, s);
		});
		return key;
	}

	// A copy of `t` with the hash and its name at `pos`.
	private static function insertField(t:FieldTable, pos:Int, key:Int, name:String):FieldTable {
		var len = t.ids.Length;
		var ids = new cs.NativeArray<Int>(len + 1), names = new cs.NativeArray<String>(len + 1);
		cs.system.Array.Copy(t.ids, 0, ids, 0, pos);
		cs.system.Array.Copy(t.names, 0, names, 0, pos);
		ids[pos] = key;
		names[pos] = name;
		cs.system.Array.Copy(t.ids, pos, ids, pos + 1, len - pos);
		cs.system.Array.Copy(t.names, pos, names, pos + 1, len - pos);
		return new FieldTable(ids, names);
	}

	public static function findHash(hash:Int, hashs:cs.NativeArray<Int>, length:Int):Int {
		var min = 0;
		var max = length;

		while (min < max) {
			var mid = Std.int((max + min) / 2);
			var imid = hashs[mid];
			if (hash < imid) {
				max = mid;
			} else if (hash > imid) {
				min = mid + 1;
			} else {
				return mid;
			}
		}
		// if not found, return a negative value of where it should be inserted
		return ~min;
	}

	public static function removeInt(a:cs.NativeArray<Int>, length:Int, pos:Int) {
		cs.system.Array.Copy(a, pos + 1, a, pos, length - pos - 1);
		a[length - 1] = 0;
	}

	public static function removeFloat(a:cs.NativeArray<Float>, length:Int, pos:Int) {
		cs.system.Array.Copy(a, pos + 1, a, pos, length - pos - 1);
		a[length - 1] = 0;
	}

	public static function removeDynamic(a:cs.NativeArray<Dynamic>, length:Int, pos:Int) {
		cs.system.Array.Copy(a, pos + 1, a, pos, length - pos - 1);
		a[length - 1] = null;
	}

	extern static inline function __insert<T>(a:cs.NativeArray<T>, length:Int, pos:Int, x:T):cs.NativeArray<T> {
		var capacity = a.Length;
		if (pos == length) {
			if (capacity == length) {
				var newarr = new NativeArray((length << 1) + 1);
				a.CopyTo(newarr, 0);
				a = newarr;
			}
		} else if (pos == 0) {
			if (capacity == length) {
				var newarr = new NativeArray((length << 1) + 1);
				cs.system.Array.Copy(a, 0, newarr, 1, length);
				a = newarr;
			} else {
				cs.system.Array.Copy(a, 0, a, 1, length);
			}
		} else {
			if (capacity == length) {
				var newarr = new NativeArray((length << 1) + 1);
				cs.system.Array.Copy(a, 0, newarr, 0, pos);
				cs.system.Array.Copy(a, pos, newarr, pos + 1, length - pos);
				a = newarr;
			} else {
				cs.system.Array.Copy(a, pos, a, pos + 1, length - pos);
				cs.system.Array.Copy(a, 0, a, 0, pos);
			}
		}
		a[pos] = x;
		return a;
	}

	public static function insertInt(a:cs.NativeArray<Int>, length:Int, pos:Int, x:Int):cs.NativeArray<Int>
		return __insert(a, length, pos, x);

	public static function insertFloat(a:cs.NativeArray<Float>, length:Int, pos:Int, x:Float):cs.NativeArray<Float>
		return __insert(a, length, pos, x);

	public static function insertDynamic(a:cs.NativeArray<Dynamic>, length:Int, pos:Int, x:Dynamic):cs.NativeArray<Dynamic>
		return __insert(a, length, pos, x);

	public static function insertString(a:cs.NativeArray<String>, length:Int, pos:Int, x:String):cs.NativeArray<String>
		return __insert(a, length, pos, x);

	public static function getHashConflict(head:FieldHashConflict, hash:Int, name:String):FieldHashConflict {
		while (head != null) {
			if (head.hash == hash && head.name == name) {
				return head;
			}
			head = head.next;
		}
		return null;
	}

	public static function setHashConflict(head:cs.Ref<FieldHashConflict>, hash:Int, name:String, value:Dynamic):Void {
		var node = head;
		while (node != null) {
			if (node.hash == hash && node.name == name) {
				node.value = value;
				return;
			}
			node = node.next;
		}
		head = new FieldHashConflict(hash, name, value, head);
	}

	public static function deleteHashConflict(head:cs.Ref<FieldHashConflict>, hash:Int, name:String):Bool {
		// no conflicting fields at all
		if (head == null) {
			return false;
		}

		// list head is conflicting - just point it to the next one
		if (head.hash == hash && head.name == name) {
			head = head.next;
			return true;
		}

		// loop through the list, removing node if there's one
		var prev = head, node = head.next;
		while (node != null) {
			if (node.hash == hash && node.name == name) {
				prev.next = node.next;
				return true;
			}
			node = node.next;
		}

		// not found
		return false;
	}

	public static function addHashConflictNames(head:FieldHashConflict, arr:Array<String>):Void {
		while (head != null) {
			arr.push(head.name);
			head = head.next;
		}
	}
}
