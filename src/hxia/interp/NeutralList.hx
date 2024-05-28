package hxia.interp;

// The cppia List: `for (x in list)` and `list.iterator()` are inlined by the compiler into
// direct field walks over the internal head node (`list.h`, `node.item`, `node.next` -
// std/haxe/ds/List.hx). Those fields are private on the host List, so reflection cannot read
// them and iteration yields nothing. This shim reproduces the same representation with PUBLIC
// fields, so the inlined field access works; the non-inline methods are bound in NeutralStd.
class NeutralList {
	public var h:NeutralListNode;
	public var q:NeutralListNode;
	public var length:Int = 0;

	public function new() {}

	public function add(item:Dynamic):Void {
		var x = new NeutralListNode(item, null);
		if (h == null)
			h = x;
		else
			q.next = x;
		q = x;
		length++;
	}

	public function push(item:Dynamic):Void {
		var x = new NeutralListNode(item, h);
		h = x;
		if (q == null)
			q = x;
		length++;
	}

	public function first():Dynamic
		return h == null ? null : h.item;

	public function last():Dynamic
		return q == null ? null : q.item;

	public function pop():Dynamic {
		if (h == null)
			return null;
		var x = h.item;
		h = h.next;
		if (h == null)
			q = null;
		length--;
		return x;
	}

	public function isEmpty():Bool
		return h == null;

	public function clear():Void {
		h = null;
		q = null;
		length = 0;
	}

	public function remove(v:Dynamic):Bool {
		var prev:NeutralListNode = null;
		var l = h;
		while (l != null) {
			if (l.item == v) {
				if (prev == null)
					h = l.next;
				else
					prev.next = l.next;
				if (q == l)
					q = prev;
				length--;
				return true;
			}
			prev = l;
			l = l.next;
		}
		return false;
	}

	public function iterator():Iterator<Dynamic> {
		var out:Array<Dynamic> = [];
		var l = h;
		while (l != null) {
			out.push(l.item);
			l = l.next;
		}
		return out.iterator();
	}

	public function toString():String {
		var s = new StringBuf();
		s.add("{");
		var first = true;
		var l = h;
		while (l != null) {
			if (!first)
				s.add(", ");
			first = false;
			s.add(Std.string(l.item));
			l = l.next;
		}
		s.add("}");
		return s.toString();
	}
}

class NeutralListNode {
	public var item:Dynamic;
	public var next:NeutralListNode;

	public function new(item:Dynamic, next:NeutralListNode) {
		this.item = item;
		this.next = next;
	}
}
