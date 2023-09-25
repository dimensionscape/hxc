package hxc.ast;

import haxe.ds.StringMap;
import sys.io.File;

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

	static var fileCache:StringMap<PositionFile> = new StringMap();

	public static function registerFileContent(file:String, content:String):String {
		fileCache.set(file, new PositionFile(content));
		return content;
	}

	public static function getFileContent(file:String):String {
		var cached = fileCache.get(file);
		if (cached != null) return cached.content;
		return registerFileContent(file, File.getContent(file));
	}

	public static function lineNumber(p:Position):Int {
		return getInfos(p).line;
	}

	public static function getInfos(p:Position):PositionInfos {
		if (p.min < 0 || p.max < 0)
			return {file: p.file, min: p.min, max: p.max, line: 0, column: p.min, endLine: 0, endColumn: p.max};
		var cached = fileCache.get(p.file);
		if (cached == null) {
			if (p.file != "?" && sys.FileSystem.exists(p.file) && !sys.FileSystem.isDirectory(p.file)) {
				getFileContent(p.file);
				cached = fileCache.get(p.file);
			} else {
				return {file: p.file, min: p.min, max: p.max, line: 0, column: p.min, endLine: 0, endColumn: p.max};
			}
		}
		return cached.info(p);
	}

	/** The smallest position spanning both `p1` and `p2`: the file of `p1`, the lower start and the higher end. */
	public static inline function union(p1:Position, p2:Position):Position {
		return new Position(p1.file, p1.min < p2.min ? p1.min : p2.min, p1.max > p2.max ? p1.max : p2.max);
	}

	public function toString():String {
		return '$file:$min-$max';
	}
}

typedef PositionInfos = {
	file:String,
	min:Int,
	max:Int,
	line:Int,
	column:Int,
	endLine:Int,
	endColumn:Int,
};

private class PositionFile {
	public final content:String;
	final lineStarts:Array<Int>;

	public function new(content:String) {
		this.content = content;
		this.lineStarts = [0];
		var i = 0;
		while (i < content.length) {
			var c = content.charCodeAt(i);
			if (c == "\n".code) {
				lineStarts.push(i + 1);
			} else if (c == "\r".code) {
				if (i + 1 >= content.length || content.charCodeAt(i + 1) != "\n".code)
					lineStarts.push(i + 1);
			}
			i++;
		}
	}

	public function info(p:Position):PositionInfos {
		var min = clamp(p.min);
		var max = clamp(p.max);
		var startIndex = lineIndex(min);
		var endIndex = lineIndex(max);
		return {
			file: p.file,
			min: p.min,
			max: p.max,
			line: startIndex + 1,
			column: min - lineStarts[startIndex],
			endLine: endIndex + 1,
			endColumn: max - lineStarts[endIndex],
		};
	}

	function clamp(v:Int):Int {
		if (v < 0) return 0;
		if (v > content.length) return content.length;
		return v;
	}

	function lineIndex(offset:Int):Int {
		var lo = 0;
		var hi = lineStarts.length;
		while (lo + 1 < hi) {
			var mid = (lo + hi) >> 1;
			if (lineStarts[mid] <= offset)
				lo = mid;
			else
				hi = mid;
		}
		return lo;
	}
}
