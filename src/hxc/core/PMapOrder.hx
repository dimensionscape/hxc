package hxc.core;

import haxe.ds.StringMap;
import hxc.core.Type;

// A persistent map is an AVL tree keyed by structural `compare`. Its iter and fold visit the keys in
// increasing order, but map and mapi apply their function in POST-ORDER (left subtree, right subtree, then
// the node), so the order a map visits its values depends on the tree's SHAPE, which depends on the order
// the keys were added. This rebuilds that shape from the insertion order, with the map's own add and
// rebalance (an AVL that tolerates a height difference of two).
class PMapOrder {
	// Map: the post-order of the tree built by adding `keys` in this order.
	public static function mapOrder(keys:Array<String>):Array<String> {
		var root:Null<PNode> = null;
		for (k in keys) root = add(k, root);
		var out = [];
		post(root, out);
		return out;
	}

	// Mapping a type or applying params rebuilds an anon by mapping its field map. A class's statics
	// anon is statics, whose keys were added in declaration order, the order orderedStatics keeps. hxc
	// keeps no insertion order for any other anon, and those visit their keys in increasing order.
	public static function anonMapOrder(a:TAnon):Array<String> {
		var keys = MapKeys.ofString(a.fields);
		StringSort.sort(keys);
		switch (a.status.get()) {
			case Statics(c):
				var seen = new StringMap<Bool>();
				var ordered = [];
				for (cf in c.orderedStatics)
					if (a.fields.exists(cf.name) && !seen.exists(cf.name)) {
						seen.set(cf.name, true);
						ordered.push(cf.name);
					}
				for (k in keys) if (!seen.exists(k)) ordered.push(k);
				return mapOrder(ordered);
			case _:
				return keys;
		}
	}

	// Iterating or folding over an anon's fields: increasing key order.
	public static function sortedKeys(m:StringMap<TClassField>):Array<String> {
		var keys = MapKeys.ofString(m);
		StringSort.sort(keys);
		return keys;
	}

	static inline function height(n:Null<PNode>):Int {
		return n == null ? 0 : n.h;
	}

	static function make(l:Null<PNode>, k:String, r:Null<PNode>):PNode {
		var hl = height(l), hr = height(r);
		return new PNode(l, k, r, (hl > hr ? hl : hr) + 1);
	}

	static function bal(l:Null<PNode>, k:String, r:Null<PNode>):PNode {
		var hl = height(l);
		var hr = height(r);
		if (hl > hr + 2) {
			if (height(l.l) >= height(l.r)) return make(l.l, l.k, make(l.r, k, r));
			var lr = l.r;
			return make(make(l.l, l.k, lr.l), lr.k, make(lr.r, k, r));
		} else if (hr > hl + 2) {
			if (height(r.r) >= height(r.l)) return make(make(l, k, r.l), r.k, r.r);
			var rl = r.l;
			return make(make(l, k, rl.l), rl.k, make(rl.r, r.k, r.r));
		}
		return new PNode(l, k, r, (hl > hr ? hl : hr) + 1);
	}

	static function add(x:String, n:Null<PNode>):PNode {
		if (n == null) return new PNode(null, x, null, 1);
		var c = StringSort.compare(x, n.k);
		if (c == 0) return new PNode(n.l, x, n.r, n.h);
		if (c < 0) return bal(add(x, n.l), n.k, n.r);
		return bal(n.l, n.k, add(x, n.r));
	}

	static function post(n:Null<PNode>, out:Array<String>):Void {
		if (n == null) return;
		post(n.l, out);
		post(n.r, out);
		out.push(n.k);
	}
}

private class PNode {
	public var l:Null<PNode>;
	public var k:String;
	public var r:Null<PNode>;
	public var h:Int;

	public function new(l:Null<PNode>, k:String, r:Null<PNode>, h:Int) {
		this.l = l;
		this.k = k;
		this.r = r;
		this.h = h;
	}
}
