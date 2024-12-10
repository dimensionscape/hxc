package hxc.core;

import hxc.ast.Position;

class TypingError extends haxe.Exception {
	public final pos:Position;
	public final depth:Int;

	public function new(message:String, pos:Position, depth:Int = 0) {
		super(message);
		this.pos = pos;
		this.depth = depth;
	}
}

// unifyMin catches exactly the unification failure it produced itself and reports it; anything else
// propagates. The kind is carried by type so the report does not have to recognise it from the
// message text.
class MinUnifyError extends TypingError {}
