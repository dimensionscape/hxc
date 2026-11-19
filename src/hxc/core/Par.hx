package hxc.core;

/**
	Worker threads for a phase whose units of work do not depend on each other.

	Each thread has a slot: 0 for the main thread, 1 and up for a worker. State that the type functions keep
	across a call (their recursion stacks) is held once per slot, so a worker never sees another thread's.
	What a worker must not do at all (force a lazy type, make or bind a monomorph, report a message) it gives
	up on with `bail`, and the phase then redoes that unit on the main thread.

	On .NET the workers read maps together, so the compiler must be built with -D no_map_cache: the C#
	maps otherwise keep the last key looked up, and a read writes it.
**/
#if cpp
@:headerCode('extern thread_local int hxc_par_tid;')
@:cppFileCode('thread_local int hxc_par_tid = 0;')
#end
class Par {
	public static inline var MAX_THREADS = 16;

	// HXC_DBG_PAR: a line per parallel phase on stderr (threads, units, units redone).
	public static final debug:Bool = Sys.getEnv("HXC_DBG_PAR") != null;

	// HXC_DBG_PAR_BAIL=N: a worker gives up on about one unit in N once the unit's work is done, to exercise
	// the main thread's redo. 0 (the default) never does.
	public static final bailTest:Int = {
		var v = Sys.getEnv("HXC_DBG_PAR_BAIL");
		var n = v == null ? null : Std.parseInt(v);
		n == null || n < 1 ? 0 : n;
	};

	static final bailValue = new ParBail();

	#if cs
	// A worker's stack. The type functions recurse deeply, and .NET gives a new thread 1 MB otherwise.
	static inline var WORKER_STACK = 64 * 1024 * 1024;

	@:meta(System.ThreadStaticAttribute) static var slot:Int;
	#end

	/** This thread's slot. **/
	public static function tid():Int {
		#if cpp
		return untyped __cpp__("hxc_par_tid");
		#elseif cs
		return slot;
		#else
		return 0;
		#end
	}

	static function setTid(i:Int):Void {
		#if cpp
		untyped __cpp__("hxc_par_tid = {0}", i);
		#elseif cs
		slot = i;
		#end
	}

	/** Leaves the unit a worker is on: the phase redoes it on the main thread. **/
	public static function bail():Dynamic {
		throw bailValue;
	}

	/** In a worker, leaves its unit. A no-op on the main thread. **/
	public static inline function mainOnly():Void {
		if (tid() != 0) bail();
	}

	/**
		How many threads a parallel phase uses: HXC_THREADS when set (1 keeps everything on the main thread),
		otherwise up to 4, and never more than the machine's processors.
	**/
	public static function threadCount():Int {
		#if (cpp || cs)
		var env = Sys.getEnv("HXC_THREADS");
		var n = env == null ? 4 : Std.parseInt(env);
		if (n == null || n < 1) n = 1;
		var procs = Sys.getEnv("NUMBER_OF_PROCESSORS");
		if (env == null && procs != null) {
			var p = Std.parseInt(procs);
			if (p != null && p >= 1 && p < n) n = p;
		}
		if (n > MAX_THREADS - 1) n = MAX_THREADS - 1;
		return n;
		#else
		return 1;
		#end
	}

	/**
		Calls `fn(i)` for every i in 0...count from `threads` worker threads, each taking the next free index,
		and returns when all are done. `fn` must not throw.
	**/
	public static function forEach(threads:Int, count:Int, fn:Int->Void):Void {
		#if (cpp || cs)
		var next = 0;
		var mutex = new sys.thread.Mutex();
		var done = new sys.thread.Lock();
		for (t in 0...threads) {
			var work = function() {
				setTid(t + 1);
				while (true) {
					mutex.acquire();
					var i = next++;
					mutex.release();
					if (i >= count) break;
					fn(i);
				}
				done.release();
			};
			#if cs
			var thread = new cs.system.threading.Thread(new cs.system.threading.ThreadStart(work), WORKER_STACK);
			thread.IsBackground = true;
			thread.Start();
			#else
			sys.thread.Thread.create(work);
			#end
		}
		for (_ in 0...threads) done.wait();
		#else
		for (i in 0...count) fn(i);
		#end
	}
}

class ParBail {
	public function new() {}
}
