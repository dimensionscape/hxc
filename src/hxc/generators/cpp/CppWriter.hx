package hxc.generators.cpp;

// hxc.generators.cpp.CppWriter: the indented C++ text writer.
// Header lines (deduped) and the body accumulate in separate buffers; the file generators flush
// them to the .h and .cpp. Used by the expression emitter (CppEmit).
class CppWriter {
	static inline var indentStr = "\t";
	var indent = "";
	final indents:Array<String> = [];
	public var justFinishedBlock = false;
	final headerLines = new Map<String, Bool>();
	final body = new StringBuf();
	final header = new StringBuf();

	public function new() {}

	public function write(x:String):Void {
		body.add(x);
		justFinishedBlock = false;
	}

	public function writeH(x:String):Void {
		header.add(x);
	}

	public function writeHUnique(x:String):Void {
		if (!headerLines.exists(x)) {
			headerLines.set(x, true);
			writeH(x);
		}
	}

	// A closure with many captures/args needs the jumbo macro variants.
	public function addBigClosures():Void {
		writeHUnique("#include <hx/MacrosJumbo.h>\n");
	}

	public function pushIndent():Void {
		indents.push(indentStr);
		indent += indentStr;
	}

	public function popIndent():Void {
		if (indents.length > 0) {
			indents.pop();
			indent = indent.substr(0, indent.length - indentStr.length);
		} else {
			indent = "/*?*/";
		}
	}

	public inline function writeI(x:String):Void {
		write(indent + x);
	}

	public inline function getIndent():String {
		return indent;
	}

	public function beginBlock():Void {
		write("{\n");
		pushIndent();
	}

	public function endBlock():Void {
		popIndent();
		writeI("}\n");
		justFinishedBlock = true;
	}

	public function endBlockLine():Void {
		popIndent();
		writeI("}");
		justFinishedBlock = true;
	}

	public function terminateLine():Void {
		write(justFinishedBlock ? "" : ";\n");
	}

	public function getBody():String {
		return body.toString();
	}

	public function getHeader():String {
		return header.toString();
	}
}
