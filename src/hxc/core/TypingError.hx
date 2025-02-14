package hxc.core;

import hxc.ast.Position;

class TypingError extends haxe.Exception {
	public final pos:Position;
	public final depth:Int;

	public function new(message:String, pos:Position, depth:Int = 0) {
		hxc.core.PerfCount.exn("TypingError");
		super(message);
		this.pos = pos;
		this.depth = depth;
	}
}

// unifyMin catches exactly the unification failure it produced itself and reports it; anything else
// propagates. The kind is carried by type so the report does not have to recognise it from the
// message text.
class MinUnifyError extends TypingError {}

/**
 * Module not found. Kept OUT of WithTypeError (as a call error is), so it never picks up the "For
 * function argument 'x'" annotation - a path that does not resolve is not an argument-unification
 * failure and reads wrong when described as one. Carried by type for the same reason as
 * MinUnifyError: the message text is not a reliable way to recognise it.
 */
class ModuleNotFoundError extends TypingError {}

/**
    A call error - not enough arguments, too many arguments, a non-nullable argument that cannot be skipped,
    or a failed unification. Also exempt from the argument annotation: the call itself is what went wrong,
    not the argument being placed.
*/
class CallError extends TypingError {}
