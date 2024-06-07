package hxia.interp;

// The cppia StringBuf: cpp inlines `add` into direct field ops on `b` (the chunk array) and
// `charBuf` (pending char codes), while toString/flush/addChar/addSub stay real method calls
// (std/cpp/_std/StringBuf.hx marks them `#if !cppia inline`). The interpreter runs on hosts
// whose own StringBuf has a different internal layout, so a real host StringBuf would not
// match the inlined field access. This shim reproduces the exact representation the cppia
// targets: `b` and `charBuf` are public so the inlined field ops reach them, and the methods
// mirror cpp semantics (the cpp-native char pointer flush is expressed portably here).
class NeutralStringBuf {
	public var b:Array<String>;
	public var charBuf:Array<Int>;

	public function new() {}

	function charBufAsString():String {
		var out = new StringBuf();
		for (c in charBuf)
			out.addChar(c);
		return out.toString();
	}

	public function flush():Void {
		if (b == null)
			b = [charBufAsString()];
		else
			b.push(charBufAsString());
		charBuf = null;
	}

	public function addChar(c:Int):Void {
		if (charBuf == null)
			charBuf = [];
		charBuf.push(c);
	}

	public function addSub(s:String, pos:Int, ?len:Int):Void {
		if (charBuf != null)
			flush();
		var sub = len == null ? s.substr(pos) : s.substr(pos, len);
		if (b == null)
			b = [sub];
		else
			b.push(sub);
	}

	// StringBuf exposes `var length(get, never)`; the cppia reads it as a get_length call. The shim
	// keeps content in b/charBuf rather than a running counter, so derive it from the assembled string.
	public function get_length():Int
		return toString().length;

	public function toString():String {
		if (charBuf != null)
			flush();
		if (b == null || b.length == 0)
			return "";
		if (b.length == 1)
			return b[0];
		return b.join("");
	}
}
