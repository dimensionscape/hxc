package hxia.interp;

// A fault in interpreting a module: an unbound host reference, an unimplemented op, or a
// malformed tree. Distinct from a script-thrown value (which surfaces as ScriptError).
class InterpError extends haxe.Exception {
	public function new(message:String) super(message);
}
