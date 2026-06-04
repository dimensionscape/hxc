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

// A unification error, as a cast-or-unify raises it. Context.unify answers false on exactly this kind and
// lets anything else out of the macro.
class CastUnifyError extends TypingError {}

// An unknown identifier, which typing an identifier against an expected enum catches (and no other failure
// of identifier typing). The message is the printed form, so a reader of the text sees no difference.
class UnknownIdentError extends TypingError {
	public final ident:String;

	public function new(ident:String, pos:Position) {
		super("Unknown identifier : " + ident, pos);
		this.ident = ident;
	}
}

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
 * WithTypeError: what a raise-or-display inside call arguments raises. Its own class, not a
 * TypingError, so the recovery arms an Error meets on the way up (the per-statement recovery among
 * them) let it pass; only the argument loop catches it and annotates it with the parameter.
 */
class WithTypeError extends haxe.Exception {
	public final pos:Position;
	public final depth:Int;

	public function new(message:String, pos:Position, depth:Int = 0) {
		super(message);
		this.pos = pos;
		this.depth = depth;
	}
}

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

	/**
	 * A true fatal error is raised here, rather than an Error the driver simply meets uncaught. The
	 * diagnostics driver catches typing, parser and lexer errors and not a fatal error, so only a true
	 * fatal error travels past the diagnostics machinery and is printed plainly - a diagnostics
	 * request that meets one gets no json report at all. hxc's FatalError does double duty: it also
	 * stands for an ordinary Error that nothing between the raise and the driver catches (flushing a
	 * typing pass catches nothing, so a build's error ends the compile). That second kind is still an
	 * ordinary Error to the diagnostics driver and must still be REPORTED - `Build failure` from a
	 * @:build macro is one, and it belongs inside the json report.
	 */
	public final bypassesDiagnostics:Bool;

	public function new(message:String, pos:Position, depth:Int = 0, bypassesDiagnostics:Bool = false) {
		super(message);
		this.pos = pos;
		this.depth = depth;
		this.bypassesDiagnostics = bypassesDiagnostics;
	}

	/** For a catch-all: a fatal error is on its way to the driver and is never swallowed. */
	public static function pass(e:Dynamic):Void {
		if (Std.isOfType(e, FatalError)) throw e;
	}
}

// A forbidden package access: the refused package, module and position, the positions the module was
// referenced through (each module load adds its own) and the platform name. The driver prints "You cannot
// access the %s package while %s (for %s)" and a "... referenced here" per referencing position at depth 1,
// and the compile ends; a FatalError so every recovery arm lets it pass. (The display-mode handling, which
// clears the messages when the request has a next one, is not implemented.)
class ForbidPackage extends FatalError {
	public final pack:String;
	public final path:hxc.core.Globals.Path;
	public final platform:String;
	public final referenced:Array<Position> = [];

	public function new(pack:String, path:hxc.core.Globals.Path, pos:Position, platform:String) {
		super("You cannot access the " + pack + " package while " + (platform == "macro" ? "in a macro" : "targeting " + platform) + " (for " + hxc.core.Globals.sTypePath(path) + ")", pos);
		this.pack = pack;
		this.path = path;
		this.platform = platform;
		refreshChain();
	}

	public function addReference(p:Position):Void {
		referenced.push(p);
		refreshChain();
	}

	function refreshChain():Void {
		callChain = [{message: message, pos: pos}];
		for (r in referenced) callChain.push({message: "... referenced here", pos: r, depth: 1});
	}
}
