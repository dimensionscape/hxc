package hxc.ast;

@:structInit
class Position {
	public var file:String;
	public var min:Int;
	public var max:Int;

	public function new(file:String, min:Int, max:Int) {
		this.file = file;
		this.min = min;
		this.max = max;
	}

	public static final nullPos:Position = new Position("?", -1, -1);

	/** The smallest position spanning both `p1` and `p2`: the file of `p1`, the lower start and the higher end. */
	public static inline function union(p1:Position, p2:Position):Position {
		return new Position(p1.file, p1.min < p2.min ? p1.min : p2.min, p1.max > p2.max ? p1.max : p2.max);
	}

	public function toString():String {
		return '$file:$min-$max';
	}
}
