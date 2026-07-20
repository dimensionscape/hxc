package hxc.core;

import hxc.core.Type.TExpr;

// The frame slots an interpreted function's locals occupy (hxc.eval.EvalEmitter.frameLayout), made
// once for a function body. A local the walk did not see is added on its first use.
class FrameLayout {
	public final id:Int;
	public final body:TExpr;
	public final slots:haxe.ds.IntMap<Int>;
	public var size:Int;

	public function new(id:Int, body:TExpr) {
		this.id = id;
		this.body = body;
		this.slots = new haxe.ds.IntMap();
		this.size = 0;
	}
}
