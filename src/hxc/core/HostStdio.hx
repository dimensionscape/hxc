package hxc.core;

/**
	The process's standard output and error streams, as the compiler writes to them.

	Sys.stdout() and Sys.stderr() everywhere but on .NET. There the std's stream writes a byte at a time, one
	system call each, and opens the handle again on every call: a build that prints tens of thousands of
	lines (-D dce-debug) spent minutes in it. Here each stream is opened once and takes whole buffers.
**/
class HostStdio {
	#if cs
	static var outStream:Null<haxe.io.Output> = null;
	static var errStream:Null<haxe.io.Output> = null;
	#end

	public static inline function out():haxe.io.Output {
		#if cs
		if (outStream == null) outStream = new NetStreamOutput(cs.system.Console.OpenStandardOutput());
		return outStream;
		#else
		return Sys.stdout();
		#end
	}

	public static inline function err():haxe.io.Output {
		#if cs
		if (errStream == null) errStream = new NetStreamOutput(cs.system.Console.OpenStandardError());
		return errStream;
		#else
		return Sys.stderr();
		#end
	}
}

#if cs
private class NetStreamOutput extends haxe.io.Output {
	final stream:cs.system.io.Stream;

	public function new(stream:cs.system.io.Stream) {
		this.stream = stream;
	}

	override public function writeByte(c:Int):Void {
		stream.WriteByte(cast c);
	}

	override public function writeBytes(s:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length) throw haxe.io.Error.OutsideBounds;
		stream.Write(s.getData(), pos, len);
		return len;
	}

	override public function flush():Void {
		stream.Flush();
	}

	override public function close():Void {
		stream.Close();
	}
}
#end
