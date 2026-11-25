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

/**
	hxc: hxcs adds C# to this struct that Haxe cannot say: `_ofDynamic`, a static method of the
	instantiation (Runtime.mkNullable uses `ofDynamic` instead), and the implicit conversions from `T`
	and from `__NoValue__`. TclassToIl writes `_ofDynamic` and `op_Implicit(T)` (nullSurface) and gives
	`value` and `hasValue` initonly; the nested `__NoValue__` and its conversion stay out, since nothing
	converts a C# `null` to a Null<T>. Its `ToString` comes from `toString`.
**/
#if core_api_serialize
@:meta(System.Serializable)
#end
@:keep @:struct @:nativeGen @:native("haxe.lang.Null") private class Nullable<T> {
	@:readOnly public var value(default, never):T;
	@:readOnly public var hasValue(default, never):Bool;

	public function new(v:T, hasValue:Bool) {
		if (hasValue && cs.system.Object.ReferenceEquals(v, null)) {
			hasValue = false;
		}
		untyped this.value = v;
		untyped this.hasValue = hasValue;
	}

	public static function ofDynamic<D>(obj:Dynamic):Nullable<D> {
		if (obj == null) {
			return new Nullable<D>(cast null, false);
		}
		var d:cs.system.Type = untyped __typeof__(D);
		var tDouble:cs.system.Type = untyped __typeof__(Float), tInt:cs.system.Type = untyped __typeof__(Int);
		if (d == tDouble) {
			return new Nullable<D>(cast Runtime.toDouble(obj), true);
		} else if (d == tInt) {
			return new Nullable<D>(cast Runtime.toInt(obj), true);
		} else {
			return new Nullable<D>(cast obj, true);
		}
	}

	public function toDynamic():Dynamic {
		if (this.hasValue)
			return value;
		return null;
	}

	public function toString():String {
		if (!hasValue)
			return "null";
		else
			return (cast value : cs.system.Object).ToString();
	}
}
