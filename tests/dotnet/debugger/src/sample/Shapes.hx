package sample;

class Shapes {
	var scale:Int;

	public function new(scale:Int) {
		this.scale = scale;
	}

	public function area(side:Int):Int {
		var squared = side * side;
		var result = squared * scale;
		return result;
	}

	public function fail(side:Int):Int {
		if (side > 2)
			throw "side too large: " + side;
		return side;
	}

	public function grow(side:Int):Int {
		var grown = side + scale;
		return grown;
	}
}
