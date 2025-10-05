package hxc.core;

// Compilation phase timers with a nested stats tree. Enabled by --times; each timer() opens a scope and
// returns a close function, nested scopes subtract their time from the parent so the tree columns sum
// correctly.
class TimerInfo {
	public var id:Array<String>;
	public var start:Array<Float>;
	public var pauses:Array<Float>;
	public var total:Float;
	public var calls:Int;
	public function new(id:Array<String>, now:Float) {
		this.id = id;
		this.start = [now];
		this.pauses = [0.0];
		this.total = 0.0;
		this.calls = 1;
	}
}

class TimerNode {
	public var name:String;
	public var path:String;
	public var parent:TimerNode;
	public var info:String;
	public var time:Float;
	public var numCalls:Int;
	public var children:Array<TimerNode>;
	public function new(name:String, path:String, parent:TimerNode, info:String, time:Float, numCalls:Int) {
		this.name = name;
		this.path = path;
		this.parent = parent == null ? this : parent;
		this.info = info;
		this.time = time;
		this.numCalls = numCalls;
		this.children = [];
	}
}

class Timer {
	public static var measureTimes:Bool = false;
	static var htimers:Map<String, TimerInfo> = new Map();
	static var curtime:Array<TimerInfo> = [];

	static inline function getTime():Float return haxe.Timer.stamp();

	static function newTimer(id:Array<String>):TimerInfo {
		var now = getTime();
		var key = id.join(".");
		var t = htimers.get(key);
		if (t != null) {
			t.start.unshift(now);
			t.pauses.unshift(0.0);
			t.calls++;
			return t;
		}
		t = new TimerInfo(id, now);
		htimers.set(key, t);
		return t;
	}

	static function close(now:Float, t:TimerInfo):Void {
		if (curtime.length == 0) throw "Timer " + t.id.join(".") + " closed while not active";
		var tt = curtime[0];
		if (tt != t) { close(now, tt); return; }
		var start = t.start.shift();
		var pauses = t.pauses.shift();
		var dt = now - start;
		t.total += dt - pauses;
		curtime.shift();
		if (curtime.length > 0) {
			var current = curtime[0];
			current.pauses[0] = dt + current.pauses[0];
		}
	}

	public static function timer(id:Array<String>):Void->Void {
		if (!measureTimes) return function() {};
		var t = newTimer(id);
		curtime.unshift(t);
		return function() close(getTime(), t);
	}

	public static function currentId():Null<Array<String>> {
		return curtime.length == 0 ? null : curtime[0].id;
	}

	public static function closeTimes():Void {
		while (curtime.length > 0) close(getTime(), curtime[0]);
	}

	static function buildTimesTree():{maxName:Int, maxCalls:Int, root:TimerNode} {
		var nodes = new Map<String, TimerNode>();
		var root = new TimerNode("", "", null, "", 0.0, 0);
		for (timer in htimers) {
			function loop(parent:TimerNode, sl:Array<String>):TimerNode {
				var s = sl[0];
				var path = (parent.path == "" ? "" : parent.path + ".") + s;
				var node = nodes.get(path);
				if (node != null) {
					node.numCalls += timer.calls;
					node.time += timer.total;
				} else {
					var name = s, info = "";
					var i = s.lastIndexOf(".");
					if (i >= 0) { name = s.substr(i + 1); info = s.substr(0, i); }
					node = new TimerNode(name, path, parent, info, timer.total, timer.calls);
					nodes.set(path, node);
				}
				var rest = sl.slice(1);
				if (rest.length > 0) {
					var child = loop(node, rest);
					if (node.children.indexOf(child) < 0) node.children.push(child);
				}
				return node;
			}
			var node = loop(root, timer.id);
			if (root.children.indexOf(node) < 0) root.children.push(node);
		}
		var maxName = 0, maxCalls = 0;
		function measure(depth:Int, node:TimerNode):Void {
			var l = node.name.length + 2 * depth;
			for (child in node.children) {
				if (depth == 0) { node.numCalls += child.numCalls; node.time += child.time; }
				measure(depth + 1, child);
			}
			node.children.sort(function(a, b) return a.time > b.time ? -1 : (a.time < b.time ? 1 : 0));
			if (node.numCalls > maxCalls) maxCalls = node.numCalls;
			if (node.time > 0.0009 && l > maxName) maxName = l;
		}
		measure(0, root);
		return {maxName: maxName, maxCalls: maxCalls, root: root};
	}

	static function pad(s:String, w:Int, left:Bool):String {
		while (s.length < w) s = left ? s + " " : " " + s;
		return s;
	}

	static function fmt3(f:Float):String {
		var v = Math.round(f * 1000) / 1000;
		var s = Std.string(v);
		var dot = s.indexOf(".");
		if (dot < 0) { s += "."; dot = s.length - 1; }
		while (s.length - dot - 1 < 3) s += "0";
		return s;
	}

	public static function reportTimes(print:String->Void):Void {
		var built = buildTimesTree();
		var maxName = built.maxName, root = built.root;
		var maxCalls = Std.string(built.maxCalls).length;
		print(pad("name", maxName, true) + " | " + pad("time(s)", 7, false) + " |   % |  p% | " + pad("#", maxCalls, false) + " | info");
		var sep = "";
		for (i in 0...(maxName + maxCalls + 27)) sep += "-";
		print(sep);
		function printTime(name:String, node:TimerNode):Void {
			if (node.time > 0.0009) {
				print(pad(name, maxName, true) + " | " + pad(fmt3(node.time), 7, false) + " | "
					+ pad(Std.string(Math.round(node.time * 100.0 / root.time)), 3, false) + " | "
					+ pad(Std.string(Math.round(node.time * 100.0 / node.parent.time)), 3, false) + " | "
					+ pad(Std.string(node.numCalls), maxCalls, false) + " | " + node.info);
			}
		}
		function loop(depth:Int, node:TimerNode):Void {
			var indent = "";
			for (i in 0...(depth * 2)) indent += " ";
			printTime(indent + node.name, node);
			for (child in node.children) loop(depth + 1, child);
		}
		for (child in root.children) loop(0, child);
		print(sep);
		printTime("total", root);
	}
}
