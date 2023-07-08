package hxc.core;

// Single mutable cell, used where shared in-place identity matters
// (TLazy, anon status). get/set or.value.
@:structInit
class Ref<T> {
	public var value:T;

	public function new(value:T) {
		this.value = value;
	}

	public inline function get():T return value;

	public inline function set(v:T):T return value = v;
}
