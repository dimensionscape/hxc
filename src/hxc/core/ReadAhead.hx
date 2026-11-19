package hxc.core;

/**
	Source files read by worker threads before the compiler asks for them.

	The compiler reads its modules one at a time as typing reaches them, and on Windows opening a file
	costs far more than reading it. When a directory of a class path is listed, its `.hx` files are
	offered here; a worker reads each one's bytes, and the read that typing makes later takes them instead
	of opening the file. A worker touches nothing of the compiler's: a path in, bytes out.

	The bytes are only taken while the file still has the write time it had when the worker read it, so
	a file a macro rewrites in between is read again. What is never asked for is dropped by `stop`.

	Off in a compilation server and in a display request, where files change under the compiler, and on
	a host without threads.
**/
class ReadAhead {
	/** Set where a process serves many requests: nothing is read ahead in it. **/
	public static var never = false;

	// At most this much read and not yet taken; past it the workers leave files alone.
	static inline var BUDGET = 256 * 1024 * 1024;

	#if ((cpp || cs) && !emscripten)
	static var running = false;
	static var workers = 0;
	static var queue:sys.thread.Deque<Null<String>>;
	static var mutex:sys.thread.Mutex;
	// Every path offered or asked for. A path asked for before its bytes were ready is the compiler's
	// to read, and stays so.
	static var entries:haxe.ds.StringMap<ReadAheadEntry>;
	static var held = 0;
	// HXC_DBG_READAHEAD: a line on stderr when the workers stop (files offered, taken read, read by the
	// compiler itself, read and then found rewritten).
	static final debug = Sys.getEnv("HXC_DBG_READAHEAD") != null;
	static var nOffered = 0;
	static var nHit = 0;
	static var nMiss = 0;
	static var nStale = 0;
	#end

	/** Starts the workers. Until `stop`, `offer` queues files and `take` hands their bytes over. **/
	public static function start():Void {
		#if ((cpp || cs) && !emscripten)
		if (never || running) return;
		var n = Par.threadCount() - 1;
		if (n < 1) return;
		if (n > 4) n = 4;
		queue = new sys.thread.Deque();
		mutex = new sys.thread.Mutex();
		entries = new haxe.ds.StringMap();
		held = 0;
		workers = n;
		running = true;
		for (_ in 0...n) {
			#if cs
			var thread = new cs.system.threading.Thread(new cs.system.threading.ThreadStart(work));
			thread.IsBackground = true;
			thread.Start();
			#else
			sys.thread.Thread.create(work);
			#end
		}
		#end
	}

	/** Ends the workers and drops what was read and not taken. **/
	public static function stop():Void {
		#if ((cpp || cs) && !emscripten)
		if (!running) return;
		running = false;
		for (_ in 0...workers) queue.add(null);
		if (debug) HostStdio.err().writeString("[readahead] offered " + nOffered + ", taken " + nHit + ", read by the compiler " + nMiss + ", rewritten " + nStale + "
");
		mutex.acquire();
		entries = new haxe.ds.StringMap();
		held = 0;
		mutex.release();
		#end
	}

	/** A file the compiler may read soon. **/
	public static function offer(file:String):Void {
		#if ((cpp || cs) && !emscripten)
		if (!running) return;
		mutex.acquire();
		var fresh = !entries.exists(file);
		if (fresh) {
			entries.set(file, new ReadAheadEntry());
			nOffered++;
		}
		mutex.release();
		if (fresh) queue.add(file);
		#end
	}

	/**
		The file's bytes if a worker has read them and the file has not been written since; null when the
		caller is to read it, which it then always is for this file.
	**/
	public static function take(file:String):Null<haxe.io.Bytes> {
		#if ((cpp || cs) && !emscripten)
		if (!running) return null;
		mutex.acquire();
		var e = entries.get(file);
		var bytes:Null<haxe.io.Bytes> = null;
		var time = 0.0;
		if (e == null) {
			e = new ReadAheadEntry();
			entries.set(file, e);
		} else if (e.bytes != null) {
			bytes = e.bytes;
			time = e.time;
			held -= bytes.length;
			e.bytes = null;
		}
		e.taken = true;
		mutex.release();
		if (bytes == null) nMiss++;
		else if (writeTime(file) != time) {
			bytes = null;
			nStale++;
		} else nHit++;
		return bytes;
		#else
		return null;
		#end
	}

	#if ((cpp || cs) && !emscripten)
	static function work():Void {
		while (true) {
			var file = queue.pop(true);
			if (file == null) return;
			mutex.acquire();
			var e = running ? entries.get(file) : null;
			var skip = e == null || e.taken || held > BUDGET;
			mutex.release();
			if (skip) continue;
			var time = writeTime(file);
			var bytes = try sys.io.File.getBytes(file) catch (_:Dynamic) null;
			// written while it was read: not a copy to hand over
			if (bytes == null || writeTime(file) != time) continue;
			mutex.acquire();
			if (running && entries.get(file) == e && !e.taken) {
				e.bytes = bytes;
				e.time = time;
				held += bytes.length;
			}
			mutex.release();
		}
	}

	// When the file was last written, 0 for a file that is not there.
	static function writeTime(file:String):Float {
		#if cs
		return try cs.system.io.File.GetLastWriteTimeUtc(file).ToOADate() catch (_:Dynamic) 0.0;
		#else
		return FileTime.fileTime(file);
		#end
	}
	#end
}

#if ((cpp || cs) && !emscripten)
private class ReadAheadEntry {
	public var bytes:Null<haxe.io.Bytes> = null;
	public var time = 0.0;
	public var taken = false;

	public function new() {}
}
#end
