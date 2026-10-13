package hxc.codegen.jvm;

import haxe.io.Bytes;
import hxc.core.Zip;

// Where the generated classes go: into a jar, or as loose files under a directory.

interface JvmOutput {
	public function addEntry(content:Bytes, name:String):Void;
	public function close():Void;
}

class JarOutput implements JvmOutput {
	var jarPath:String;
	var compressionLevel:Int;
	var zip:Zip;

	public function new(jarPath:String, compressionLevel:Int) {
		this.jarPath = jarPath;
		this.compressionLevel = compressionLevel;
		zip = new Zip(jarPath);
	}

	public function addEntry(content:Bytes, name:String):Void {
		zip.addEntry(content, name, compressionLevel, Date.now());
	}

	public function close():Void {
		sys.io.File.saveBytes(jarPath, zip.close());
	}
}

class FileOutput implements JvmOutput {
	var basePath:String;

	public function new(basePath:String) {
		this.basePath = basePath;
	}

	public function addEntry(content:Bytes, name:String):Void {
		var path = basePath + name;
		mkdirFromPath(path);
		sys.io.File.saveBytes(path, content);
	}

	static function mkdirFromPath(file:String):Void {
		var norm = file.split("\\").join("/");
		var idx = norm.lastIndexOf("/");
		if (idx <= 0) return;
		var dir = norm.substr(0, idx);
		if (dir != "" && !sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
	}

	public function close():Void {}
}
