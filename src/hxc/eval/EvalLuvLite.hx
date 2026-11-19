package hxc.eval;

#if !cpp
import hxc.eval.EvalValue;

/**
	eval.luv on a host with no libuv (hxc.eval.EvalLuv is the C++ host's, over the real library).

	Written here, in Haxe: what sys.thread.EventLoop, Condition and Semaphore run on, which is Loop, Timer,
	Async and the Handle calls on them, and Mutex, Condition and Semaphore. A loop iteration goes as
	libuv's does: the clock is read, the timers that are due run, the loop waits for an Async to be sent
	(no longer than the next timer), the sent ones run, the close callbacks run, and the timers run again.
	A loop is alive while it has a handle that is active and referenced, or a close still to report.

	Every other eval.luv native is registered too, so the modules load, and fails when it is called.
**/
@:access(hxc.eval.EvalStdLib)
class EvalLuvLite {
	static inline var EBUSY = 22;
	static inline var EINVAL = 34;

	static inline function vfn(f:VFunc):EvalValue return VFunction(f, true);

	static inline function arg(a:Array<EvalValue>, i:Int):EvalValue return i < a.length ? a[i] : VNull;

	static final resultPath = EvalHash.hash("eval.luv.Result");

	static function ok(v:EvalValue):EvalValue return VEnumValue(new VEnumValue(0, [v], resultPath, null));

	static function error(index:Int):EvalValue return VEnumValue(new VEnumValue(1, [EvalValueTools.vint(index)], resultPath, null));

	static function unit(code:Int):EvalValue return code == 0 ? ok(VNull) : error(code);

	static function callback(v:EvalValue):EvalValue {
		switch (v) {
			case VFunction(_, _) | VFieldClosure(_, _):
			case _: throw new EvalExceptions.HostException("MacroApi.Invalid_expr", false);
		}
		return v;
	}

	static function decodeLoop(ctx:EvalContext, v:EvalValue):LiteLoop {
		return switch (v) {
			case VHandle(h) if (h.kind == HLoop): h.native;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Loop");
		};
	}

	static function decodeHandle(ctx:EvalContext, v:EvalValue):LiteHandle {
		return switch (v) {
			case VHandle(h) if (h.kind == HTimer || h.kind == HAsync): h.native;
			case _: EvalExceptions.unexpectedValue(ctx, v, "handle");
		};
	}

	static function decodeKind<T>(ctx:EvalContext, v:EvalValue, kind:EvalHandleKind, name:String):T {
		return switch (v) {
			case VHandle(h) if (h.kind == kind): h.native;
			case _: EvalExceptions.unexpectedValue(ctx, v, name);
		};
	}

	static var defaultLoop:Null<LiteLoop> = null;

	public static function init(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		var done = new Map<String, Bool>();
		function reg(typeName:String, fieldName:String, v:EvalValue) {
			done.set(typeName + "." + fieldName, true);
			EvalStdLib.reg(s, typeName, fieldName, v);
		}
		function call(f:EvalValue, args:Array<EvalValue>):Void EvalStdLib.callValue(ctx, f, args);

		var loop = "eval.luv._Loop.Loop_Impl_";
		reg(loop, "init", vfn(a -> ok(VHandle(new EvalHandle(HLoop, new LiteLoop())))));
		reg(loop, "defaultLoop", vfn(a -> {
			if (defaultLoop == null) defaultLoop = new LiteLoop();
			VHandle(new EvalHandle(HLoop, defaultLoop));
		}));
		reg(loop, "libraryShutdown", vfn(a -> VNull));
		reg(loop, "run", vfn(a -> {
			var l = decodeLoop(ctx, arg(a, 0));
			var mode = EvalStdLib.decodeInt(ctx, arg(a, 1));
			if (mode < 0 || mode > 2) EvalExceptions.unexpectedValue(ctx, arg(a, 1), "valid loop run mode");
			EvalValueTools.vbool(l.run(mode, call));
		}));
		reg(loop, "stop", vfn(a -> { decodeLoop(ctx, arg(a, 0)).stop(); VNull; }));
		reg(loop, "close", vfn(a -> unit(decodeLoop(ctx, arg(a, 0)).handles.length > 0 ? EBUSY : 0)));
		reg(loop, "alive", vfn(a -> EvalValueTools.vbool(decodeLoop(ctx, arg(a, 0)).alive())));
		reg(loop, "now", vfn(a -> VUInt64(new EvalInt64(haxe.Int64.fromFloat(decodeLoop(ctx, arg(a, 0)).now)))));
		reg(loop, "updateTime", vfn(a -> { decodeLoop(ctx, arg(a, 0)).updateTime(); VNull; }));

		var h = "eval.luv._Handle.Handle_Impl_";
		reg(h, "close", vfn(a -> {
			var o = decodeHandle(ctx, arg(a, 0));
			var cb = callback(arg(a, 1));
			o.loop.close(o, cb);
			VNull;
		}));
		reg(h, "isActive", vfn(a -> EvalValueTools.vbool(decodeHandle(ctx, arg(a, 0)).active)));
		reg(h, "isClosing", vfn(a -> { var o = decodeHandle(ctx, arg(a, 0)); EvalValueTools.vbool(o.closing || o.closed); }));
		reg(h, "ref", vfn(a -> { decodeHandle(ctx, arg(a, 0)).referenced = true; VNull; }));
		reg(h, "unref", vfn(a -> { decodeHandle(ctx, arg(a, 0)).referenced = false; VNull; }));
		reg(h, "hasRef", vfn(a -> EvalValueTools.vbool(decodeHandle(ctx, arg(a, 0)).referenced)));

		var timer = "eval.luv._Timer.Timer_Impl_";
		inline function decodeTimer(v:EvalValue):LiteHandle return decodeKind(ctx, v, HTimer, "eval.luv.Timer");
		reg(timer, "init", vfn(a -> {
			var l = decodeLoop(ctx, arg(a, 0));
			var t = new LiteHandle(l, HTimer);
			l.handles.push(t);
			ok(VHandle(new EvalHandle(HTimer, t)));
		}));
		reg(timer, "start", vfn(a -> {
			var t = decodeTimer(arg(a, 0));
			var cb = callback(arg(a, 1));
			var timeout = EvalStdLib.decodeInt(ctx, arg(a, 2));
			var repeat = EvalStdLib.defaultInt(ctx, arg(a, 3), 0);
			unit(t.loop.timerStart(t, cb, timeout, repeat));
		}));
		reg(timer, "stop", vfn(a -> { decodeTimer(arg(a, 0)).active = false; ok(VNull); }));
		reg(timer, "again", vfn(a -> {
			var t = decodeTimer(arg(a, 0));
			if (t.cb == null) return error(EINVAL);
			if (t.repeat > 0) t.loop.timerStart(t, t.cb, Std.int(t.repeat), Std.int(t.repeat));
			ok(VNull);
		}));
		reg(timer, "set_repeat", vfn(a -> {
			var t = decodeTimer(arg(a, 0));
			var repeat = EvalStdLib.decodeInt(ctx, arg(a, 1));
			t.repeat = repeat;
			EvalValueTools.vint(repeat);
		}));
		reg(timer, "get_repeat", vfn(a -> EvalValueTools.vint(Std.int(decodeTimer(arg(a, 0)).repeat))));
		reg(timer, "get_dueIn", vfn(a -> {
			var t = decodeTimer(arg(a, 0));
			var d = t.active ? t.due - t.loop.now : 0;
			EvalValueTools.vint(d > 0 ? Std.int(d) : 0);
		}));

		var async = "eval.luv._Async.Async_Impl_";
		reg(async, "init", vfn(a -> {
			var l = decodeLoop(ctx, arg(a, 0));
			var o = new LiteHandle(l, HAsync);
			o.cb = callback(arg(a, 1));
			o.active = true;
			l.handles.push(o);
			var v = VHandle(new EvalHandle(HAsync, o));
			o.self = v;
			ok(v);
		}));
		reg(async, "send", vfn(a -> {
			var o:LiteHandle = decodeKind(ctx, arg(a, 0), HAsync, "eval.luv.Async");
			o.loop.send(o);
			ok(VNull);
		}));

		// Mutex, Condition and Semaphore are the host's own.
		var mutex = "eval.luv._Mutex.Mutex_Impl_";
		inline function decodeMutex(v:EvalValue):sys.thread.Mutex return decodeKind(ctx, v, HMutex, "eval.luv.Mutex");
		reg(mutex, "init", vfn(a -> ok(VHandle(new EvalHandle(HMutex, new sys.thread.Mutex())))));
		reg(mutex, "destroy", vfn(a -> { decodeMutex(arg(a, 0)); VNull; }));
		reg(mutex, "lock", vfn(a -> { var m = decodeMutex(arg(a, 0)); EvalStdLib.gilBlocking(() -> { m.acquire(); VNull; }); }));
		reg(mutex, "tryLock", vfn(a -> unit(decodeMutex(arg(a, 0)).tryAcquire() ? 0 : EBUSY)));
		reg(mutex, "unlock", vfn(a -> { decodeMutex(arg(a, 0)).release(); VNull; }));

		var cond = "eval.luv._Condition.Condition_Impl_";
		inline function decodeCond(v:EvalValue):sys.thread.Condition return decodeKind(ctx, v, HCondition, "eval.luv.Condition");
		reg(cond, "init", vfn(a -> ok(VHandle(new EvalHandle(HCondition, new sys.thread.Condition())))));
		reg(cond, "destroy", vfn(a -> { decodeCond(arg(a, 0)); VNull; }));
		reg(cond, "signal", vfn(a -> { var c = decodeCond(arg(a, 0)); c.acquire(); c.signal(); c.release(); VNull; }));
		reg(cond, "broadcast", vfn(a -> { var c = decodeCond(arg(a, 0)); c.acquire(); c.broadcast(); c.release(); VNull; }));
		// The condition's own lock is taken before the caller's mutex is let go, so a signal sent in between
		// waits for this thread to be waiting.
		reg(cond, "wait", vfn(a -> {
			var c = decodeCond(arg(a, 0));
			var m = decodeMutex(arg(a, 1));
			EvalStdLib.gilBlocking(() -> {
				c.acquire();
				m.release();
				c.wait();
				c.release();
				m.acquire();
				VNull;
			});
		}));
		// The host's condition has no timed wait: the mutex is let go for the time asked (in nanoseconds).
		reg(cond, "timedWait", vfn(a -> {
			decodeCond(arg(a, 0));
			var m = decodeMutex(arg(a, 1));
			var ns = EvalStdLib.decodeInt(ctx, arg(a, 2));
			EvalStdLib.gilBlocking(() -> {
				m.release();
				Sys.sleep(ns / 1e9);
				m.acquire();
				VNull;
			});
		}));

		var sem = "eval.luv._Semaphore.Semaphore_Impl_";
		inline function decodeSem(v:EvalValue):sys.thread.Semaphore return decodeKind(ctx, v, HSemaphore, "eval.luv.Semaphore");
		reg(sem, "init", vfn(a -> ok(VHandle(new EvalHandle(HSemaphore, new sys.thread.Semaphore(EvalStdLib.decodeInt(ctx, arg(a, 0))))))));
		reg(sem, "destroy", vfn(a -> { decodeSem(arg(a, 0)); VNull; }));
		reg(sem, "post", vfn(a -> { decodeSem(arg(a, 0)).release(); VNull; }));
		reg(sem, "wait", vfn(a -> { var m = decodeSem(arg(a, 0)); EvalStdLib.gilBlocking(() -> { m.acquire(); VNull; }); }));
		reg(sem, "tryWait", vfn(a -> unit(decodeSem(arg(a, 0)).tryAcquire() ? 0 : 5)));

		// The rest of eval.luv: there for a module to load, an error when called.
		for (key in EvalNativeArity.table.keys()) {
			if (!StringTools.startsWith(key, "eval.luv.") || done.exists(key)) continue;
			var dot = key.lastIndexOf(".");
			var name = key;
			EvalStdLib.reg(s, key.substr(0, dot), key.substr(dot + 1), vfn(a -> throw new EvalExceptions.HostException(name + " is not available on this host", false)));
		}
	}
}

// A timer or an async handle.
class LiteHandle {
	public final loop:LiteLoop;
	public final kind:EvalHandleKind;
	public var active = false;
	public var referenced = true;
	public var closing = false;
	public var closed = false;
	// The callback: the timer's, the async's, and from close on the close callback.
	public var cb:Null<EvalValue> = null;
	// An async is handed to its own callback.
	public var self:EvalValue = VNull;
	// A timer: when it is due on the loop's clock, its repeat interval, and its place among timers due at once.
	public var due:Float = 0;
	public var repeat:Float = 0;
	public var startId = 0;
	// An async that was sent and has not run yet.
	public var sent = false;

	public function new(loop:LiteLoop, kind:EvalHandleKind) {
		this.loop = loop;
		this.kind = kind;
	}
}

@:access(hxc.eval.EvalStdLib)
class LiteLoop {
	public final handles:Array<LiteHandle> = [];
	// The loop's clock, in milliseconds; it moves only when the loop reads the time.
	public var now:Float = 0;
	final closing:Array<LiteHandle> = [];
	// send comes from any thread: the flags it sets are kept under `lock`, and `wake` ends the loop's wait.
	final lock = new sys.thread.Mutex();
	final wake = new sys.thread.Lock();
	var signalled = false;
	var stopped = false;
	var timerCounter = 0;

	public function new() {
		updateTime();
	}

	public function updateTime():Void {
		now = Math.ffloor(haxe.Timer.stamp() * 1000);
	}

	public function stop():Void {
		stopped = true;
	}

	public function alive():Bool {
		if (closing.length > 0) return true;
		for (h in handles) if (h.active && h.referenced) return true;
		return false;
	}

	public function timerStart(t:LiteHandle, cb:EvalValue, timeout:Int, repeat:Int):Int {
		if (t.closing || t.closed) return 34;
		t.cb = cb;
		t.due = now + (timeout < 0 ? 0 : timeout);
		t.repeat = repeat < 0 ? 0 : repeat;
		t.startId = timerCounter++;
		t.active = true;
		return 0;
	}

	public function send(o:LiteHandle):Void {
		lock.acquire();
		o.sent = true;
		var first = !signalled;
		signalled = true;
		lock.release();
		if (first) wake.release();
	}

	public function close(o:LiteHandle, cb:EvalValue):Void {
		if (o.closing || o.closed) return;
		o.active = false;
		o.closing = true;
		o.cb = cb;
		closing.push(o);
	}

	// The timer that is due first, the one started first among equals.
	function nextTimer():Null<LiteHandle> {
		var best:Null<LiteHandle> = null;
		for (h in handles) {
			if (h.kind != HTimer || !h.active) continue;
			if (best == null || h.due < best.due || (h.due == best.due && h.startId < best.startId)) best = h;
		}
		return best;
	}

	function runTimers(call:(EvalValue, Array<EvalValue>) -> Void):Void {
		while (true) {
			var t = nextTimer();
			if (t == null || t.due > now) return;
			t.active = false;
			if (t.repeat > 0) {
				t.due = now + t.repeat;
				t.startId = timerCounter++;
				t.active = true;
			}
			call(t.cb, []);
		}
	}

	// How long the loop may wait, in milliseconds: 0 for not at all, -1 for until it is woken.
	function waitTime():Float {
		if (stopped || closing.length > 0) return 0;
		var any = false;
		for (h in handles) if (h.active && h.referenced) any = true;
		if (!any) return 0;
		var t = nextTimer();
		if (t == null) return -1;
		return t.due > now ? t.due - now : 0;
	}

	function poll(timeout:Float, call:(EvalValue, Array<EvalValue>) -> Void):Void {
		lock.acquire();
		var ready = signalled;
		lock.release();
		if (!ready && timeout != 0)
			EvalStdLib.gilBlocking(() -> { if (timeout < 0) wake.wait() else wake.wait(timeout / 1000); VNull; });
		else if (ready)
			wake.wait(0);
		lock.acquire();
		signalled = false;
		var sent = [for (h in handles) if (h.kind == HAsync && h.sent) h];
		for (h in sent) h.sent = false;
		lock.release();
		for (h in sent) if (h.active) call(h.cb, [h.self]);
	}

	function runClosing(call:(EvalValue, Array<EvalValue>) -> Void):Void {
		while (closing.length > 0) {
			var o = closing.shift();
			o.closing = false;
			o.closed = true;
			handles.remove(o);
			call(o.cb, []);
		}
	}

	// uv_run: 0 runs until nothing is alive or the loop is stopped, 1 runs one iteration that may wait, 2
	// one that does not. True when the loop is still alive.
	public function run(mode:Int, call:(EvalValue, Array<EvalValue>) -> Void):Bool {
		var r = alive();
		if (!r) updateTime();
		// Only a full run looks at the timers before its first wait; the other two reach them after it.
		if (mode == 0 && r && !stopped) {
			updateTime();
			runTimers(call);
		}
		while (r && !stopped) {
			poll(mode == 2 ? 0 : waitTime(), call);
			runClosing(call);
			updateTime();
			runTimers(call);
			r = alive();
			if (mode != 0) break;
		}
		stopped = false;
		return r;
	}
}
#end
