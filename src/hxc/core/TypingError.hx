package hxc.core;

import hxc.ast.Position;

class TypingError extends haxe.Exception {
	public final pos:Position;
	public final depth:Int;
	// An uncaught macro exception reports as the interpreter prints it: its head line and the "Called from
	// here" chain. The error travels with the whole report so whoever records it - a block per statement,
	// the field, the driver - prints all of it.
	public var callChain:Null<Array<{message:String, pos:Position, ?depth:Int}>> = null;

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

/**
 * A fatal error. An Error that escapes the closure typing a field - the body of a method, the
 * initializer of a variable - is raised again as this, and nothing between that closure and the
 * driver handles it: the error is reported and the compile ends. Its own class rather than a
 * TypingError so the recovery arms an Error meets on the way up (the per-statement recovery and its
 * kin) let it pass.
 */
class FatalError extends haxe.Exception {
	public final pos:Position;
	public final depth:Int;
	public var callChain:Null<Array<{message:String, pos:Position, ?depth:Int}>> = null;

	public function new(message:String, pos:Position, depth:Int = 0) {
		super(message);
		this.pos = pos;
		this.depth = depth;
	}

	/** For a catch-all: a fatal error is on its way to the driver and is never swallowed. */
	public static function pass(e:Dynamic):Void {
		if (Std.isOfType(e, FatalError)) throw e;
	}
}
