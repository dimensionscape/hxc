package hxia.interp;

// One activation frame: script locals keyed by cppia var id, plus `this` for member bodies. Script
// values are host values (shared heap, no marshalling), so a value is plain Dynamic.
class Frame {
	public var locals:Map<Int, Dynamic>;
	public var thisv:Dynamic;

	public function new(?thisv:Dynamic) {
		this.locals = new Map();
		this.thisv = thisv;
	}
}
