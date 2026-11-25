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
	hxc: std's class without `@:keep`. cs.Boot imports it under `-D unsafe`, and a kept class with a
	pointer parameter is unverifiable, so every `-D unsafe` assembly failed ILVerify. DCE drops it
	unless the program keeps it, as the server app's build keeps gencs's out by deleting its BoxedPointer.cs.
	When kept, `value` is `void*`, as gencs writes it.
**/

@:unsafe @:native('haxe.lang.BoxedPointer') @:nativeGen class BoxedPointer {
	@:readonly public var value(default, null):Pointer<Dynamic>;

	public function new(val) {
		this.value = val;
	}
}
