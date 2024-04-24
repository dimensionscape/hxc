package hxia.interp;

// One activation frame: script locals keyed by cppia var id, plus `this` for member bodies. Script
// values are host values (shared heap, no marshalling), so a value is plain Dynamic. A closure's
// call frame links to the frame it captured (`parent`); local reads and writes fall through the
// chain so a nested function sees and mutates the enclosing scope. cppia var ids are unique per
// top-level function, so fall-through is unambiguous (no shadowing across the chain).
class Frame {
	public var locals:Map<Int, Dynamic>;
	public var thisv:Dynamic;
	public var parent:Null<Frame>;

	public function new(?thisv:Dynamic, ?parent:Frame) {
		this.locals = new Map();
		this.thisv = thisv;
		this.parent = parent;
		if (parent != null && thisv == null)
			this.thisv = parent.thisv;
	}

	public function get(vId:Int):Dynamic {
		var f = this;
		while (f != null) {
			if (f.locals.exists(vId))
				return f.locals.get(vId);
			f = f.parent;
		}
		return null;
	}

	// A fresh binding (VARDECL/VARDECLI, function arg): always in this frame.
	public inline function declare(vId:Int, v:Dynamic):Void
		locals.set(vId, v);

	// An assignment to an existing var: write where it lives in the chain (so a closure
	// mutates a captured local), else this frame.
	public function assign(vId:Int, v:Dynamic):Void {
		var f = this;
		while (f != null) {
			if (f.locals.exists(vId)) { f.locals.set(vId, v); return; }
			f = f.parent;
		}
		locals.set(vId, v);
	}
}
