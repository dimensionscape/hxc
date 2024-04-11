package hxia.harness;

// A conformance case: an id plus a body that calls Guard.* . Explicit registration
// (no reflection-based discovery, which varies per target).
interface Case {
	function id():String;
	function run():Void;
}
