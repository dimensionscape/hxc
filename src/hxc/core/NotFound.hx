package hxc.core;

class NotFound extends haxe.Exception {
	public function new() {
		hxc.core.PerfCount.exn("NotFound");
		super("Not_found");
	}
}
