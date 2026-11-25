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

import cs.NativeArray;
import cs.internal.Runtime;
import haxe.iterators.ArrayKeyValueIterator;

// hxc: hxcs's Array with Haxe issue 8314's forward (casts notes §2). An untyped Array`1<object> cast to
// a basic-element array whose every element converts losslessly is reinterpreted once: __hx_castTo
// builds the typed array and installs it as `__hx_fwd`, and from then on every member that reaches the
// storage does so through the typed array (`__hx_resolve()`), so a write through either reference shows
// through the other, converting as Runtime.genericCast does. The typed array keeps `__hx_from`, and
// writes the forwarder's `length` wherever it writes its own, so `length` stays a field that callers,
// ArrayIterator, reflection and C# read directly. map and filter are inline, as in hxcs, except on an Array<Dynamic>
// or an array of a type parameter (`@:inlineUnlessDynamic`, typing/Inline.hx); iterator, keyValueIterator, __unsafe_get
// and __unsafe_set are not inline, as gencs emits them as methods too, so no caller reads `__a`
// itself. The members this adds never show in reflection: the vars and the bodies of the Equals
// and GetHashCode overrides skip it, the helpers are extern inline, so no method exists for them, and the
// methods holding the rare paths of map, filter, push and the element accessors are `@:skipReflection`;
// none of them is a member of the `Array` companion interface. Equality sees an array and its forward as
// one array.
#if core_api_serialize
@:meta(System.Serializable)
#end
final class Array<T> implements ArrayAccess<T> {
	public var length(default, null):Int;

	private var __a:NativeArray<T>;

	// hxc: the typed array this one forwards to, set once; only an Array`1<object> has one.
	@:skipReflection private var __hx_fwd:Dynamic;

	// hxc: the array forwarding to this one, whose `length` this one keeps in step: an Array`1<object>,
	// so the write is a plain store.
	@:skipReflection private var __hx_from:Array<Any>;

	@:skipReflection static var __hx_toString_depth = 0;
	@:skipReflection static inline final __hx_defaultCapacity = 4;

	#if erase_generics
	inline private static function ofNative<X>(native:NativeArray<Dynamic>):Array<X> {
		return new Array(native);
	}
	#else
	inline private static function ofNative<X>(native:NativeArray<X>):Array<X> {
		return new Array(native);
	}
	#end

	inline private static function alloc<Y>(size:Int):Array<Y> {
		return new Array(new NativeArray(size));
	}

	@:overload public function new():Void {
		this.length = 0;
		this.__a = new NativeArray(0);
	}

	#if erase_generics
	@:overload private function new(native:NativeArray<Dynamic>) {
		this.length = native.Length;
		this.__a = untyped native;
	}
	#else
	@:overload private function new(native:NativeArray<T>) {
		this.length = native.Length;
		this.__a = native;
	}
	#end

	// hxc: the array whose storage this one uses: its forward target, or itself.
	extern inline function __hx_resolve():Array<Dynamic> {
		return __hx_fwd != null ? __hx_fwd : this;
	}

	// hxc: the storage of `__hx_resolve()`, for the members that only copy out of it. A forward target's
	// `__a` has another element type, which System.Array.Copy and GetValue box.
	extern inline function __hx_store():cs.system.Array {
		var fwd:Dynamic = __hx_fwd;
		return fwd == null ? __a : fwd.__a;
	}

	// hxc: after a write of `length`, the same write on the array forwarding to this one.
	extern inline function __hx_syncLength():Void {
		if (__hx_from != null)
			__hx_from.length = length;
	}

	// hxc: `o` resolved as __hx_resolve() resolves an array: the forward target of an Array`1<object> that has
	// one, else `o` itself, whatever it is (only an Array`1<object> forwards). Runtime.eq and refEq use it too.
	extern inline static function __hx_resolveOf(o:Dynamic):Dynamic {
		var u:Array<Any> = untyped __as__(o);
		return u != null && u.__hx_fwd != null ? u.__hx_fwd : o;
	}

	// hxc: an Array and its forward are one array (casts notes §2.6). The body of Array`1's Equals override,
	// which TclassToIl adds to call it (arrayIdentity), so Haxe code sees no Equals field, as in gencs's
	// Array, which overrides neither Equals nor GetHashCode. It compares the arrays whose storage the two
	// use, so System.Array.IndexOf (indexOf, lastIndexOf) finds one through the other; an array that
	// neither forwards nor is a forward target keeps reference identity. Neither this nor __hx_hashCode is
	// reflected, nor a member of the companion interface.
	@:keep @:skipReflection private function __hx_equals(other:Dynamic):Bool {
		return cs.system.Object.ReferenceEquals(__hx_resolve(), __hx_resolveOf(other));
	}

	// hxc: the body of Array`1's GetHashCode override, as __hx_equals is Equals's: the identity hash of the
	// forwarder, for the forwarder and its target alike, so arrays Equals finds equal hash equal (ObjectMap
	// keys). The forwarder is there before its forward is installed, so an array already used as a key
	// keeps its hash.
	@:keep @:skipReflection private function __hx_hashCode():Int {
		var self:Dynamic = __hx_from != null ? (__hx_from : Dynamic) : this;
		return ArrayIdentity.GetHashCode(self);
	}

	// hxc: the body of Array_cast<T_c> after gencs's check for the same type arguments, which CompanionToIl
	// emits before calling this (casts notes §2.4). A cast of an Array`1<object> that does not forward yet
	// to a basic-element array (String or a value type) whose every element survives the conversion
	// reinterprets it: under `lock (this)`, and only if no forward is there yet, the elements are checked
	// and converted and the typed array is installed as the forward; a thread that loses the race returns
	// the winner's. A forwarding array returns its target for the target's type and
	// a copy of it for another type. Anything else copies as gencs's X_cast does: `length` as it is, and
	// each element of `__a` that is not null through Runtime.genericCast.
	@:keep @:skipReflection private function __hx_castTo<T_c>():Array<T_c> {
		var from:cs.system.Type = untyped __typeof__(T);
		var to:cs.system.Type = untyped __typeof__(T_c);
		var object:cs.system.Type = untyped __typeof__(Dynamic);
		var string:cs.system.Type = untyped __typeof__(String);
		// Read here for a typed source, which never forwards; an Array`1<object> reads them again under the lock.
		var len = length, a = __a;
		if (__hx_fwd == null && from == object) {
			// The scan runs under the lock too: once a winner has installed, pushes through its target grow
			// the target's storage and this array's `length`, not this array's `__a`. For the same reason a
			// copy takes `length` and `__a` together under the lock, while no forward is there: a forward to
			// another type installed after a failed scan here would otherwise let the copy pair the grown
			// `length` with the stale `__a`.
			cs.Lib.lock(this, {
				if (__hx_fwd == null) {
					len = length;
					a = __a;
					if (to == string || to.IsValueType) {
						var lossless = true, i = 0;
						var typed = new NativeArray<T_c>(len);
						while (lossless && i < len) {
							var o:Dynamic = a[i];
							if (__hx_lossless(o, to))
								typed[i] = Runtime.genericCast(o);
							else
								lossless = false;
							i++;
						}
						if (lossless) {
							var target = new Array<T_c>(typed);
							target.__hx_from = cast this;
							__hx_fwd = target;
							// No fast path of a member can use it now (__unsafe_get).
							__a = new NativeArray(0);
						}
					}
				}
			});
		}
		var fwd:Dynamic = __hx_fwd;
		if (fwd != null) {
			var same:Array<T_c> = untyped __as__(fwd);
			if (same != null)
				return same;
			// The target's own cast copies it.
			var other:Array<T_c> = fwd;
			return other;
		}
		var copy = new Array<T_c>();
		copy.length = len;
		if (a == null) {
			copy.__a = null;
		} else {
			var n = new NativeArray<T_c>(a.Length);
			for (i in 0...a.Length) {
				var o:Dynamic = a[i];
				if (o != null)
					n[i] = Runtime.genericCast(o);
			}
			copy.__a = n;
		}
		return copy;
	}

	// hxc: whether the element `o` survives Runtime.genericCast into the basic type `to` (casts notes §1.3,
	// §2.4): a value of that type; null into String; a number into Float; and into Int, Single or Int64 a
	// number the conversion gives back as the same number (-0.0 into Int too, as 0 serializes alike).
	@:skipReflection static function __hx_lossless(o:Dynamic, to:cs.system.Type):Bool {
		if (o == null)
			return to == untyped __typeof__(String);
		if (to.IsInstanceOfType(o))
			return true;
		if (!(untyped __is__(o, Int)) && !(untyped __is__(o, Float)))
			return false;
		var d = Runtime.toDouble(o);
		if (to == untyped __typeof__(Float))
			return true;
		if (to == untyped __typeof__(Int)) {
			if (!(d >= -2147483648.0 && d <= 2147483647.0))
				return false;
			var i:Int = Runtime.genericCast(o);
			return i == d;
		}
		if (to == untyped __typeof__(Single)) {
			var f:Single = Runtime.genericCast(o);
			return Runtime.toDouble(f) == d;
		}
		if (to == untyped __typeof__(cs.StdTypes.Int64)) {
			// Within Int64's range: (long) of 2^63 saturates to 2^63 - 1, which reads back as 2^63.
			if (!(d >= -9.2e18 && d <= 9.2e18))
				return false;
			var l:cs.StdTypes.Int64 = Runtime.genericCast(o);
			return Runtime.toDouble(l) == d;
		}
		return false;
	}

	public function concat(a:Array<T>):Array<T> {
		var len = length + a.length;
		var retarr = new NativeArray(len);
		cs.system.Array.Copy(__hx_store(), 0, retarr, 0, length);
		cs.system.Array.Copy(a.__hx_store(), 0, retarr, length, a.length);

		return ofNative(retarr);
	}

	private function concatNative(a:NativeArray<T>):Void {
		if (__hx_fwd != null) {
			var target = __hx_resolve();
			for (i in 0...a.Length)
				target.push(a[i]);
			return;
		}
		var __a = __a;
		var len = length + a.Length;
		if (__a.Length >= len) {
			cs.system.Array.Copy(a, 0, __a, length, length);
		} else {
			var newarr = new NativeArray(len);
			cs.system.Array.Copy(__a, 0, newarr, 0, length);
			cs.system.Array.Copy(a, 0, newarr, length, a.Length);

			this.__a = newarr;
		}

		this.length = len;
		__hx_syncLength();
	}

	public function indexOf(x:T, ?fromIndex:Int):Int {
		var len = length, i:Int = (fromIndex == null) ? 0 : fromIndex;
		if (i < 0) {
			i += len;
			if (i < 0)
				i = 0;
		} else if (i >= len) {
			return -1;
		}
		// hxc: over the boxed elements of a forward target, as over this array's own objects.
		if (__hx_fwd != null)
			return cs.system.Array.IndexOf(__hx_store(), (x : Dynamic), i, len - i);
		return cs.system.Array.IndexOf(__a, x, i, len - i);
	}

	public function lastIndexOf(x:T, ?fromIndex:Int):Int {
		var len = length, i:Int = (fromIndex == null) ? len - 1 : fromIndex;
		if (i >= len) {
			i = len - 1;
		} else if (i < 0) {
			i += len;
			if (i < 0)
				return -1;
		}
		if (__hx_fwd != null)
			return cs.system.Array.LastIndexOf(__hx_store(), (x : Dynamic), i, i + 1);
		return cs.system.Array.LastIndexOf(__a, x, i, i + 1);
	}

	public function join(sep:String):String {
		if (__hx_fwd != null)
			return __hx_resolve().join(sep);
		var buf = new StringBuf();
		var i = -1;

		var first = true;
		var length = length;
		while (++i < length) {
			if (first)
				first = false;
			else
				buf.add(sep);
			buf.add(__a[i]);
		}

		return buf.toString();
	}

	public function pop():Null<T> {
		if (__hx_fwd != null)
			return __hx_resolve().pop();
		var __a = __a;
		var length = length;
		if (length > 0) {
			var val = __a[--length];
			__a[length] = null;
			this.length = length;
			__hx_syncLength();

			return val;
		} else {
			return null;
		}
	}

	public function push(x:T):Int {
		if (__hx_from != null || length >= __a.Length)
			return __hx_pushSlow(x);
		__a[length] = x;
		return ++length;
	}

	// hxc: what push does when it has to forward, grow or keep a forwarder's length in step, apart so that
	// push stays small enough to inline.
	@:keep @:skipReflection @:hxcCold private function __hx_pushSlow(x:T):Int {
		if (__hx_fwd != null)
			return __hx_resolve().push(x);
		if (length >= __a.Length) {
			var newLen = length == 0 ? __hx_defaultCapacity : (length << 1);
			var newarr = new NativeArray(newLen);
			__a.CopyTo(newarr, 0);

			this.__a = newarr;
		}

		__a[length] = x;
		++length;
		__hx_syncLength();
		return length;
	}

	public function reverse():Void {
		if (__hx_fwd != null) {
			__hx_resolve().reverse();
			return;
		}
		var i = 0;
		var l = this.length;
		var a = this.__a;
		var half = l >> 1;
		l -= 1;
		while (i < half) {
			var tmp = a[i];
			a[i] = a[l - i];
			a[l - i] = tmp;
			i += 1;
		}
	}

	public function shift():Null<T> {
		if (__hx_fwd != null)
			return __hx_resolve().shift();
		var l = this.length;
		if (l == 0)
			return null;

		var a = this.__a;
		var x = a[0];
		l -= 1;
		cs.system.Array.Copy(a, 1, a, 0, length - 1);
		a[l] = null;
		this.length = l;
		__hx_syncLength();

		return x;
	}

	public function slice(pos:Int, ?end:Int):Array<T> {
		if (pos < 0) {
			pos = this.length + pos;
			if (pos < 0)
				pos = 0;
		}
		if (end == null)
			end = this.length;
		else if (end < 0)
			end = this.length + end;
		if (end > this.length)
			end = this.length;
		var len = end - pos;
		if (len < 0)
			return new Array();

		var newarr = new NativeArray(len);
		cs.system.Array.Copy(__hx_store(), pos, newarr, 0, len);

		return ofNative(newarr);
	}

	public function sort(f:T->T->Int):Void {
		if (__hx_fwd != null) {
			__hx_resolve().sort(f);
			return;
		}
		if (length == 0)
			return;
		quicksort(0, length - 1, f);
	}

	private function quicksort(lo:Int, hi:Int, f:T->T->Int):Void {
		if (__hx_fwd != null) {
			__hx_resolve().quicksort(lo, hi, f);
			return;
		}
		var buf = __a;
		var i = lo, j = hi;
		var p = buf[(i + j) >> 1];
		while (i <= j) {
			while (i < hi && f(buf[i], p) < 0)
				i++;
			while (j > lo && f(buf[j], p) > 0)
				j--;
			if (i <= j) {
				var t = buf[i];
				buf[i++] = buf[j];
				buf[j--] = t;
			}
		}

		if (lo < j)
			quicksort(lo, j, f);
		if (i < hi)
			quicksort(i, hi, f);
	}

	public function splice(pos:Int, len:Int):Array<T> {
		if (__hx_fwd != null)
			return cast __hx_resolve().splice(pos, len);
		if (len < 0)
			return new Array();
		if (pos < 0) {
			pos = this.length + pos;
			if (pos < 0)
				pos = 0;
		}
		if (pos > this.length) {
			pos = 0;
			len = 0;
		} else if (pos + len > this.length) {
			len = this.length - pos;
			if (len < 0)
				len = 0;
		}
		var a = this.__a;

		var ret = new NativeArray(len);
		cs.system.Array.Copy(a, pos, ret, 0, len);
		var ret = ofNative(ret);

		var end = pos + len;
		cs.system.Array.Copy(a, end, a, pos, this.length - end);
		this.length -= len;
		__hx_syncLength();
		while (--len >= 0)
			a[this.length + len] = null;
		return ret;
	}

	private function spliceVoid(pos:Int, len:Int):Void {
		if (__hx_fwd != null) {
			__hx_resolve().spliceVoid(pos, len);
			return;
		}
		if (len < 0)
			return;
		if (pos < 0) {
			pos = this.length + pos;
			if (pos < 0)
				pos = 0;
		}
		if (pos > this.length) {
			pos = 0;
			len = 0;
		} else if (pos + len > this.length) {
			len = this.length - pos;
			if (len < 0)
				len = 0;
		}
		var a = this.__a;

		var end = pos + len;
		cs.system.Array.Copy(a, end, a, pos, this.length - end);
		this.length -= len;
		__hx_syncLength();
		while (--len >= 0)
			a[this.length + len] = null;
	}

	public function toString():String {
		if (__hx_fwd != null)
			return __hx_resolve().toString();
		if (__hx_toString_depth >= 5) {
			return "...";
		}
		++__hx_toString_depth;
		try {
			var s = __hx_toString();
			--__hx_toString_depth;
			return s;
		} catch (e:Dynamic) {
			--__hx_toString_depth;
			throw(e);
		}
	}

	@:skipReflection
	function __hx_toString():String {
		if (__hx_fwd != null)
			return __hx_resolve().__hx_toString();
		var ret = new StringBuf();
		var a = __a;
		ret.add("[");
		var first = true;
		for (i in 0...length) {
			if (first)
				first = false;
			else
				ret.add(",");
			ret.add(a[i]);
		}

		ret.add("]");
		return ret.toString();
	}

	public function unshift(x:T):Void {
		if (__hx_fwd != null) {
			__hx_resolve().unshift(x);
			return;
		}
		var __a = __a;
		var length = length;
		if (length >= __a.Length) {
			var newLen = (length << 1) + 1;
			var newarr = new NativeArray(newLen);
			cs.system.Array.Copy(__a, 0, newarr, 1, length);

			this.__a = newarr;
		} else {
			cs.system.Array.Copy(__a, 0, __a, 1, length);
		}

		this.__a[0] = x;
		++this.length;
		__hx_syncLength();
	}

	public function insert(pos:Int, x:T):Void {
		if (__hx_fwd != null) {
			__hx_resolve().insert(pos, x);
			return;
		}
		var l = this.length;
		if (pos < 0) {
			pos = l + pos;
			if (pos < 0)
				pos = 0;
		}
		if (pos >= l) {
			this.push(x);
			return;
		} else if (pos == 0) {
			this.unshift(x);
			return;
		}

		if (l >= __a.Length) {
			var newLen = (length << 1) + 1;
			var newarr = new NativeArray(newLen);
			cs.system.Array.Copy(__a, 0, newarr, 0, pos);
			newarr[pos] = x;
			cs.system.Array.Copy(__a, pos, newarr, pos + 1, l - pos);

			this.__a = newarr;
			++this.length;
		} else {
			var __a = __a;
			cs.system.Array.Copy(__a, pos, __a, pos + 1, l - pos);
			cs.system.Array.Copy(__a, 0, __a, 0, pos);
			__a[pos] = x;
			++this.length;
		}
		__hx_syncLength();
	}

	public function remove(x:T):Bool {
		// hxc: found among the boxed elements of a forward target, as among this array's own objects, and
		// taken out of the target.
		if (__hx_fwd != null) {
			var store = __hx_store();
			for (i in 0...length) {
				if ((store.GetValue(i) : T) == x) {
					__hx_resolve().spliceVoid(i, 1);
					return true;
				}
			}
			return false;
		}
		var __a = __a;
		var i = -1;
		var length = length;
		while (++i < length) {
			if (__a[i] == x) {
				cs.system.Array.Copy(__a, i + 1, __a, i, length - i - 1);
				__a[--this.length] = null;
				__hx_syncLength();

				return true;
			}
		}

		return false;
	}

	// hxc: inline as in hxcs, so a function literal passed in is substituted into the caller's loop; the
	// forward branch is a method of its own, as an inline body cannot call itself.
	@:inlineUnlessDynamic public inline function map<S>(f:T->S):Array<S> {
		return if (__hx_fwd != null) __hx_mapForward(f) else {
			var ret = alloc(length);
			for (i in 0...length)
				ret.__unsafe_set(i, f(__unsafe_get(i)));
			ret;
		}
	}

	@:keep @:skipReflection @:hxcCold private function __hx_mapForward<S>(f:T->S):Array<S> return __hx_resolve().map(f);

	public function contains(x:T):Bool {
		if (__hx_fwd != null) {
			var store = __hx_store();
			for (i in 0...length) {
				if ((store.GetValue(i) : T) == x)
					return true;
			}
			return false;
		}
		var __a = __a;
		var i = -1;
		var length = length;
		while (++i < length) {
			if (__a[i] == x)
				return true;
		}
		return false;
	}

	@:inlineUnlessDynamic public inline function filter(f:T->Bool):Array<T> {
		return if (__hx_fwd != null) __hx_filterForward(f) else {
			var ret = [];
			for (i in 0...length) {
				var elt = __unsafe_get(i);
				if (f(elt))
					ret.push(elt);
			}
			ret;
		}
	}

	@:keep @:skipReflection @:hxcCold private function __hx_filterForward(f:T->Bool):Array<T> return cast __hx_resolve().filter(f);

	public function copy():Array<T> {
		var len = length;
		var newarr = new NativeArray(len);
		cs.system.Array.Copy(__hx_store(), 0, newarr, 0, len);
		return ofNative(newarr);
	}

	public function iterator():haxe.iterators.ArrayIterator<T> {
		return new haxe.iterators.ArrayIterator(this);
	}

	public function keyValueIterator() : ArrayKeyValueIterator<T>
	{
		return new ArrayKeyValueIterator(this);
	}

	public function resize(len:Int):Void {
		if (__hx_fwd != null) {
			__hx_resolve().resize(len);
			return;
		}
		if (length < len) {
			if (__a.length < len) {
				cs.system.Array.Resize(__a, len);
			}
			this.length = len;
			__hx_syncLength();
		} else if (length > len) {
			spliceVoid(len, length - len);
		}
	}

	@:keep private function __get(idx:Int):T {
		if ((cast idx : UInt) >= (cast __a.Length : UInt))
			return __hx_getSlow(idx);
		return if ((cast idx : UInt) >= (cast length : UInt)) null else __a[idx];
	}

	// hxc: what __get, __unsafe_get and __unsafe_set do outside `__a`: forward, or do what the store does with an
	// index outside it. Apart so that those stay small enough to inline, and not inlined themselves (@:hxcCold), as
	// the dynamic calls of the forwarding would come with them.
	@:keep @:skipReflection @:hxcCold private function __hx_getSlow(idx:Int):T
		return __hx_fwd != null ? __hx_resolve().__get(idx) : null;

	@:keep @:skipReflection @:hxcCold private function __hx_unsafeGetSlow(idx:Int):T
		return __hx_fwd != null ? __hx_resolve().__unsafe_get(idx) : __a[idx];

	@:keep @:skipReflection @:hxcCold private function __hx_unsafeSetSlow(idx:Int, val:T):T
		return __hx_fwd != null ? __hx_resolve().__unsafe_set(idx, val) : __a[idx] = val;

	@:keep private function __set(idx:Int, v:T):T {
		if ((cast idx : UInt) < (cast length : UInt) && (cast idx : UInt) < (cast __a.Length : UInt))
			return __a[idx] = v;
		return __hx_setSlow(idx, v);
	}

	// hxc: what __set does when it has to forward, grow or move `length`, apart so that __set stays small enough
	// to inline.
	@:keep @:skipReflection @:hxcCold private function __hx_setSlow(idx:Int, v:T):T {
		if (__hx_fwd != null)
			return __hx_resolve().__set(idx, v);
		var idx:UInt = idx;
		var __a = __a;
		if (idx >= __a.Length) {
			var len = idx + 1;
			if (idx == __a.Length)
				len = (idx << 1) + 1;
			var newArr = new NativeArray<T>(len);
			__a.CopyTo(newArr, 0);
			this.__a = __a = newArr;
		}

		if (idx >= length) {
			this.length = idx + 1;
			__hx_syncLength();
		}

		return __a[idx] = v;
	}

	// hxc: a forwarder's `__a` is empty, so its forward needs no test of its own here, nor in __get, __set and push: the
	// test of the index against `__a`, which the JIT then leaves out of the access, sends a forwarder to the rare path.
	private function __unsafe_get(idx:Int):T {
		return if ((cast idx : UInt) < (cast __a.Length : UInt)) __a[idx] else __hx_unsafeGetSlow(idx);
	}

	private function __unsafe_set(idx:Int, val:T):T {
		return if ((cast idx : UInt) < (cast __a.Length : UInt)) __a[idx] = val else __hx_unsafeSetSlow(idx, val);
	}
}

// hxc: Object.GetHashCode's identity hash, which Array's own GetHashCode override can't reach through
// `super`. The cs.system externs leave out every GetHashCode.
@:native("System.Runtime.CompilerServices.RuntimeHelpers") private extern class ArrayIdentity {
	static function GetHashCode(o:Dynamic):Int;
}
