package hxc.eval;

#if (cpp && !emscripten)
import hxc.eval.EvalValue;

/**
 * Libuv 1.48.0, bound for eval's eval.luv API: loops, handles, timers, async handles, loop watchers
 * (Idle, Prepare, Check), mutexes, rwlocks, semaphores, conditions, barriers, once, errors and
 * versions, over C trampolines. A result is libuv's own int (0 or more is success); errorIndex maps
 * a failure to eval's UVError index.
 *
 * Every blocking call and uv_run releases the interpreter lock, and each trampoline takes it back
 * around the callback. The thread also leaves and re-enters hxcpp's GC-free zone at the same
 * points.
 */
@:build(hxc.eval.LuvBuild.build())
@:cppFileCode('
#include <uv.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifndef SIGPROF
#define SIGPROF 0
#endif

// A libuv error code as the index of its error constant; any other code is UNKNOWN.
static int hxc_luv_error_index(int e) {
	switch (e) {
		case UV_E2BIG: return 0;
		case UV_EACCES: return 1;
		case UV_EADDRINUSE: return 2;
		case UV_EADDRNOTAVAIL: return 3;
		case UV_EAFNOSUPPORT: return 4;
		case UV_EAGAIN: return 5;
		case UV_EAI_ADDRFAMILY: return 6;
		case UV_EAI_AGAIN: return 7;
		case UV_EAI_BADFLAGS: return 8;
		case UV_EAI_BADHINTS: return 9;
		case UV_EAI_CANCELED: return 10;
		case UV_EAI_FAIL: return 11;
		case UV_EAI_FAMILY: return 12;
		case UV_EAI_MEMORY: return 13;
		case UV_EAI_NODATA: return 14;
		case UV_EAI_NONAME: return 15;
		case UV_EAI_OVERFLOW: return 16;
		case UV_EAI_PROTOCOL: return 17;
		case UV_EAI_SERVICE: return 18;
		case UV_EAI_SOCKTYPE: return 19;
		case UV_EALREADY: return 20;
		case UV_EBADF: return 21;
		case UV_EBUSY: return 22;
		case UV_ECANCELED: return 23;
		case UV_ECONNABORTED: return 25;
		case UV_ECONNREFUSED: return 26;
		case UV_ECONNRESET: return 27;
		case UV_EDESTADDRREQ: return 28;
		case UV_EEXIST: return 29;
		case UV_EFAULT: return 30;
		case UV_EFBIG: return 31;
		case UV_EFTYPE: return 76;
		case UV_EHOSTUNREACH: return 32;
		case UV_EILSEQ: return 77;
		case UV_EINTR: return 33;
		case UV_EINVAL: return 34;
		case UV_EIO: return 35;
		case UV_EISCONN: return 36;
		case UV_EISDIR: return 37;
		case UV_ELOOP: return 38;
		case UV_EMFILE: return 39;
		case UV_EMLINK: return 74;
		case UV_EMSGSIZE: return 40;
		case UV_ENAMETOOLONG: return 41;
		case UV_ENETDOWN: return 42;
		case UV_ENETUNREACH: return 43;
		case UV_ENFILE: return 44;
		case UV_ENOBUFS: return 45;
		case UV_ENODEV: return 46;
		case UV_ENOENT: return 47;
		case UV_ENOMEM: return 48;
		case UV_ENONET: return 49;
		case UV_ENOPROTOOPT: return 50;
		case UV_ENOSPC: return 51;
		case UV_ENOSYS: return 52;
		case UV_ENOTCONN: return 53;
		case UV_ENOTDIR: return 54;
		case UV_ENOTEMPTY: return 55;
		case UV_ENOTSOCK: return 56;
		case UV_ENOTSUP: return 57;
		case UV_ENOTTY: return 75;
		case UV_ENXIO: return 73;
		case UV_EOF: return 72;
		case UV_EOVERFLOW: return 78;
		case UV_EPERM: return 58;
		case UV_EPIPE: return 59;
		case UV_EPROTO: return 60;
		case UV_EPROTONOSUPPORT: return 61;
		case UV_EPROTOTYPE: return 62;
		case UV_ERANGE: return 63;
		case UV_EROFS: return 64;
		case UV_ESHUTDOWN: return 65;
		case UV_ESOCKTNOSUPPORT: return 79;
		case UV_ESPIPE: return 66;
		case UV_ESRCH: return 67;
		case UV_ETIMEDOUT: return 68;
		case UV_ETXTBSY: return 69;
		case UV_EXDEV: return 70;
		case UV_UNKNOWN: return 71;
		default: return 71;
	}
}

// An error constant index back to its libuv code; any other index has already been refused.
static int hxc_luv_error_code(int i) {
	switch (i) {
		case 0: return UV_E2BIG;
		case 1: return UV_EACCES;
		case 2: return UV_EADDRINUSE;
		case 3: return UV_EADDRNOTAVAIL;
		case 4: return UV_EAFNOSUPPORT;
		case 5: return UV_EAGAIN;
		case 6: return UV_EAI_ADDRFAMILY;
		case 7: return UV_EAI_AGAIN;
		case 8: return UV_EAI_BADFLAGS;
		case 9: return UV_EAI_BADHINTS;
		case 10: return UV_EAI_CANCELED;
		case 11: return UV_EAI_FAIL;
		case 12: return UV_EAI_FAMILY;
		case 13: return UV_EAI_MEMORY;
		case 14: return UV_EAI_NODATA;
		case 15: return UV_EAI_NONAME;
		case 16: return UV_EAI_OVERFLOW;
		case 17: return UV_EAI_PROTOCOL;
		case 18: return UV_EAI_SERVICE;
		case 19: return UV_EAI_SOCKTYPE;
		case 20: return UV_EALREADY;
		case 21: return UV_EBADF;
		case 22: return UV_EBUSY;
		case 23: return UV_ECANCELED;
		case 25: return UV_ECONNABORTED;
		case 26: return UV_ECONNREFUSED;
		case 27: return UV_ECONNRESET;
		case 28: return UV_EDESTADDRREQ;
		case 29: return UV_EEXIST;
		case 30: return UV_EFAULT;
		case 31: return UV_EFBIG;
		case 32: return UV_EHOSTUNREACH;
		case 33: return UV_EINTR;
		case 34: return UV_EINVAL;
		case 35: return UV_EIO;
		case 36: return UV_EISCONN;
		case 37: return UV_EISDIR;
		case 38: return UV_ELOOP;
		case 39: return UV_EMFILE;
		case 40: return UV_EMSGSIZE;
		case 41: return UV_ENAMETOOLONG;
		case 42: return UV_ENETDOWN;
		case 43: return UV_ENETUNREACH;
		case 44: return UV_ENFILE;
		case 45: return UV_ENOBUFS;
		case 46: return UV_ENODEV;
		case 47: return UV_ENOENT;
		case 48: return UV_ENOMEM;
		case 49: return UV_ENONET;
		case 50: return UV_ENOPROTOOPT;
		case 51: return UV_ENOSPC;
		case 52: return UV_ENOSYS;
		case 53: return UV_ENOTCONN;
		case 54: return UV_ENOTDIR;
		case 55: return UV_ENOTEMPTY;
		case 56: return UV_ENOTSOCK;
		case 57: return UV_ENOTSUP;
		case 58: return UV_EPERM;
		case 59: return UV_EPIPE;
		case 60: return UV_EPROTO;
		case 61: return UV_EPROTONOSUPPORT;
		case 62: return UV_EPROTOTYPE;
		case 63: return UV_ERANGE;
		case 64: return UV_EROFS;
		case 65: return UV_ESHUTDOWN;
		case 66: return UV_ESPIPE;
		case 67: return UV_ESRCH;
		case 68: return UV_ETIMEDOUT;
		case 69: return UV_ETXTBSY;
		case 70: return UV_EXDEV;
		case 71: return UV_UNKNOWN;
		case 72: return UV_EOF;
		case 73: return UV_ENXIO;
		case 74: return UV_EMLINK;
		case 75: return UV_ENOTTY;
		case 76: return UV_EFTYPE;
		case 77: return UV_EILSEQ;
		case 78: return UV_EOVERFLOW;
		case 79: return UV_ESOCKTNOSUPPORT;
		case 80: return UV_ENODATA;
		case 81: return UV_EUNATCH;
		default: return UV_UNKNOWN;
	}
}

// Run handle callbacks outside uv_run\'s GC-free zone. An exception leaves that zone, as the uv_run
// caller expects.
static void hxc_luv_call(void *data, int index) {
	hx::ExitGCFreeZone();
	::hxc::eval::Luv_obj::dispatch((int)(intptr_t)data, index);
	hx::EnterGCFreeZone();
}
static void hxc_luv_close(uv_handle_t *h) { hxc_luv_call(uv_handle_get_data(h), 1); }
static void hxc_luv_timer(uv_timer_t *h) { hxc_luv_call(uv_handle_get_data((uv_handle_t*)h), 0); }
static void hxc_luv_async(uv_async_t *h) { hxc_luv_call(uv_handle_get_data((uv_handle_t*)h), 0); }
static void hxc_luv_idle(uv_idle_t *h) { hxc_luv_call(uv_handle_get_data((uv_handle_t*)h), 0); }
static void hxc_luv_prepare(uv_prepare_t *h) { hxc_luv_call(uv_handle_get_data((uv_handle_t*)h), 0); }
static void hxc_luv_check(uv_check_t *h) { hxc_luv_call(uv_handle_get_data((uv_handle_t*)h), 0); }
// uv_once runs it synchronously on the calling thread, which holds the lock.
static void hxc_luv_once(void) { ::hxc::eval::Luv_obj::dispatchOnce(); }
')
class Luv {
	// A handle's references stay rooted from its allocation until close releases them; the handle's
	// data field names its entry here.
	static var retained = new Map<Int, LuvObject>();
	static var retainedLock = new sys.thread.Mutex();
	static var nextId = 1;
	// Whether each uv_run on this thread let go of the interpreter lock, innermost last.
	static var runReleased = new sys.thread.Tls<Array<Bool>>();
	static var onceCallback = new sys.thread.Tls<Void->Void>();

	// The handler for an exception escaping a callback; each eval context replaces it.
	public static var exceptionHandler:Dynamic->Void = function(e:Dynamic) {
		Sys.stderr().writeString(Std.string(e) + "\n");
		Sys.exit(2);
	};

	public static function catchExceptions(f:Void->Void):Void->Void {
		return function() {
			try f() catch (e:Dynamic) exceptionHandler(e);
		};
	}

	@:keep public static function dispatch(id:Int, index:Int):Void {
		var s = runStack();
		var reacquire = s.length > 0 && s[s.length - 1];
		if (reacquire) EvalStdLib.gilReacquire();
		retainedLock.acquire();
		var o = retained.get(id);
		retainedLock.release();
		var f = o == null ? null : o.refs[index];
		if (f != null) f();
		if (reacquire) EvalStdLib.gilRelease();
	}

	@:keep public static function dispatchOnce():Void {
		var f = onceCallback.value;
		if (f != null) f();
	}

	static function runStack():Array<Bool> {
		var s = runReleased.value;
		if (s == null) {
			s = [];
			runReleased.value = s;
		}
		return s;
	}

	static inline function blockingEnter():Bool {
		var released = EvalStdLib.gilRelease();
		untyped __cpp__("hx::EnterGCFreeZone()");
		return released;
	}

	static inline function blockingLeave(released:Bool):Void {
		untyped __cpp__("hx::ExitGCFreeZone()");
		if (released) EvalStdLib.gilReacquire();
	}

	static function own(ptr:cpp.RawPointer<cpp.Void>):LuvObject {
		var o = new LuvObject(ptr, true);
		cpp.vm.Gc.setFinalizer(o, cpp.Function.fromStaticFunction(finalize));
		return o;
	}

	// The memory goes with the last reference to it; nothing is closed or destroyed.
	@:keep static function finalize(o:LuvObject):Void {
		if (o.owned && o.ptr != null) untyped __cpp__("free({0})", o.ptr);
	}


	public static function newLoop():LuvObject {
		return own(untyped __cpp__("malloc(sizeof(uv_loop_t))"));
	}

	public static function loopInit(l:LuvObject):Int
		return untyped __cpp__("uv_loop_init((uv_loop_t*){0})", l.ptr);

	public static function loopClose(l:LuvObject):Int
		return untyped __cpp__("uv_loop_close((uv_loop_t*){0})", l.ptr);

	// Run always lets go of the lock, whatever the mode, so a callback can take it.
	public static function loopRun(l:LuvObject, mode:Int):Bool {
		var p = l.ptr;
		var s = runStack();
		var released = EvalStdLib.gilRelease();
		s.push(released);
		var r = 0;
		try {
			untyped __cpp__("hx::EnterGCFreeZone()");
			r = untyped __cpp__("uv_run((uv_loop_t*){0}, (uv_run_mode){1})", p, mode);
			untyped __cpp__("hx::ExitGCFreeZone()");
		} catch (e:Dynamic) {
			// A callback's exception: its trampoline already left the zone and holds the lock
			s.pop();
			throw e;
		}
		s.pop();
		if (released) EvalStdLib.gilReacquire();
		return r != 0;
	}

	public static function loopStop(l:LuvObject):Void
		untyped __cpp__("uv_stop((uv_loop_t*){0})", l.ptr);

	public static function loopAlive(l:LuvObject):Bool
		return (untyped __cpp__("uv_loop_alive((uv_loop_t*){0})", l.ptr) : Int) != 0;

	// A fresh value around the same loop on every call, as ctypes wraps the returned pointer anew.
	public static function loopDefault():LuvObject
		return new LuvObject(untyped __cpp__("(void*)uv_default_loop()"), false);

	public static function libraryShutdown():Void
		untyped __cpp__("uv_library_shutdown()");

	public static function loopUpdateTime(l:LuvObject):Void
		untyped __cpp__("uv_update_time((uv_loop_t*){0})", l.ptr);

	// The sigprof loop option
	public static function sigprof():Int
		return untyped __cpp__("SIGPROF");


	// The handle is rooted from the start.
	public static function newHandle(kind:EvalHandleKind):LuvObject {
		var ptr:cpp.RawPointer<cpp.Void> = switch (kind) {
			case HTimer: untyped __cpp__("malloc(sizeof(uv_timer_t))");
			case HAsync: untyped __cpp__("malloc(sizeof(uv_async_t))");
			case HIdle: untyped __cpp__("malloc(sizeof(uv_idle_t))");
			case HPrepare: untyped __cpp__("malloc(sizeof(uv_prepare_t))");
			case HCheck: untyped __cpp__("malloc(sizeof(uv_check_t))");
			case _: throw "not a handle kind: " + kind;
		};
		var o = own(ptr);
		retainedLock.acquire();
		o.id = nextId++;
		retained.set(o.id, o);
		retainedLock.release();
		untyped __cpp__("uv_handle_set_data((uv_handle_t*){0}, (void*)(intptr_t){1})", ptr, o.id);
		return o;
	}

	static function release(o:LuvObject):Void {
		retainedLock.acquire();
		retained.remove(o.id);
		retainedLock.release();
	}

	public static function isClosing(h:LuvObject):Bool
		return (untyped __cpp__("uv_is_closing((uv_handle_t*){0})", h.ptr) : Int) != 0;

	// A handle already closing is left alone; otherwise the close callback releases
	// the handle's references before it runs.
	public static function close(h:LuvObject, callback:Void->Void):Void {
		if (isClosing(h)) return;
		h.refs[1] = function() {
			release(h);
			callback();
		};
		untyped __cpp__("uv_close((uv_handle_t*){0}, hxc_luv_close)", h.ptr);
	}

	public static function isActive(h:LuvObject):Bool
		return (untyped __cpp__("uv_is_active((uv_handle_t*){0})", h.ptr) : Int) != 0;

	public static function ref(h:LuvObject):Void
		untyped __cpp__("uv_ref((uv_handle_t*){0})", h.ptr);

	public static function unref(h:LuvObject):Void
		untyped __cpp__("uv_unref((uv_handle_t*){0})", h.ptr);

	public static function hasRef(h:LuvObject):Bool
		return (untyped __cpp__("uv_has_ref((uv_handle_t*){0})", h.ptr) : Int) != 0;


	public static function timerInit(l:LuvObject, t:LuvObject):Int
		return untyped __cpp__("uv_timer_init((uv_loop_t*){0}, (uv_timer_t*){1})", l.ptr, t.ptr);

	// The callback is set first and the loop's time updated before the timer starts.
	public static function timerStart(t:LuvObject, callback:Void->Void, timeout:Int, repeat:Int):Int {
		t.refs[0] = catchExceptions(callback);
		untyped __cpp__("uv_update_time(uv_handle_get_loop((uv_handle_t*){0}))", t.ptr);
		return untyped __cpp__("uv_timer_start((uv_timer_t*){0}, hxc_luv_timer, (uint64_t)(int64_t){1}, (uint64_t)(int64_t){2})",
			t.ptr, timeout, repeat);
	}

	public static function timerStop(t:LuvObject):Int
		return untyped __cpp__("uv_timer_stop((uv_timer_t*){0})", t.ptr);

	public static function timerAgain(t:LuvObject):Int
		return untyped __cpp__("uv_timer_again((uv_timer_t*){0})", t.ptr);

	public static function timerSetRepeat(t:LuvObject, repeat:Int):Void
		untyped __cpp__("uv_timer_set_repeat((uv_timer_t*){0}, (uint64_t)(int64_t){1})", t.ptr, repeat);

	public static function timerGetRepeat(t:LuvObject):Int
		return untyped __cpp__("(int)uv_timer_get_repeat((uv_timer_t*){0})", t.ptr);

	public static function timerGetDueIn(t:LuvObject):Int
		return untyped __cpp__("(int)uv_timer_get_due_in((uv_timer_t*){0})", t.ptr);


	public static function asyncInit(l:LuvObject, a:LuvObject, callback:Void->Void):Int {
		a.refs[0] = catchExceptions(callback);
		return untyped __cpp__("uv_async_init((uv_loop_t*){0}, (uv_async_t*){1}, hxc_luv_async)", l.ptr, a.ptr);
	}

	public static function asyncSend(a:LuvObject):Int
		return untyped __cpp__("uv_async_send((uv_async_t*){0})", a.ptr);


	public static function watcherInit(kind:EvalHandleKind, l:LuvObject, w:LuvObject):Int {
		return switch (kind) {
			case HIdle: untyped __cpp__("uv_idle_init((uv_loop_t*){0}, (uv_idle_t*){1})", l.ptr, w.ptr);
			case HPrepare: untyped __cpp__("uv_prepare_init((uv_loop_t*){0}, (uv_prepare_t*){1})", l.ptr, w.ptr);
			case _: untyped __cpp__("uv_check_init((uv_loop_t*){0}, (uv_check_t*){1})", l.ptr, w.ptr);
		};
	}

	// uv_*_start keeps an active handle's callback, so an active watcher succeeds as it is.
	public static function watcherStart(kind:EvalHandleKind, w:LuvObject, callback:Void->Void):Int {
		if (isActive(w)) return 0;
		w.refs[0] = catchExceptions(callback);
		return switch (kind) {
			case HIdle: untyped __cpp__("uv_idle_start((uv_idle_t*){0}, hxc_luv_idle)", w.ptr);
			case HPrepare: untyped __cpp__("uv_prepare_start((uv_prepare_t*){0}, hxc_luv_prepare)", w.ptr);
			case _: untyped __cpp__("uv_check_start((uv_check_t*){0}, hxc_luv_check)", w.ptr);
		};
	}

	public static function watcherStop(kind:EvalHandleKind, w:LuvObject):Int {
		return switch (kind) {
			case HIdle: untyped __cpp__("uv_idle_stop((uv_idle_t*){0})", w.ptr);
			case HPrepare: untyped __cpp__("uv_prepare_stop((uv_prepare_t*){0})", w.ptr);
			case _: untyped __cpp__("uv_check_stop((uv_check_t*){0})", w.ptr);
		};
	}


	public static function newSync(kind:EvalHandleKind):LuvObject {
		var ptr:cpp.RawPointer<cpp.Void> = switch (kind) {
			case HMutex: untyped __cpp__("malloc(sizeof(uv_mutex_t))");
			case HRwLock: untyped __cpp__("malloc(sizeof(uv_rwlock_t))");
			case HSemaphore: untyped __cpp__("malloc(sizeof(uv_sem_t))");
			case HCondition: untyped __cpp__("malloc(sizeof(uv_cond_t))");
			case HBarrier: untyped __cpp__("malloc(sizeof(uv_barrier_t))");
			case HOnce: untyped __cpp__("malloc(sizeof(uv_once_t))");
			case _: throw "not a synchronisation kind: " + kind;
		};
		return own(ptr);
	}

	public static function mutexInit(m:LuvObject, recursive:Bool):Int {
		return recursive ? untyped __cpp__("uv_mutex_init_recursive((uv_mutex_t*){0})", m.ptr)
			: untyped __cpp__("uv_mutex_init((uv_mutex_t*){0})", m.ptr);
	}

	public static function mutexDestroy(m:LuvObject):Void
		untyped __cpp__("uv_mutex_destroy((uv_mutex_t*){0})", m.ptr);

	public static function mutexLock(m:LuvObject):Void {
		var p = m.ptr;
		var r = blockingEnter();
		untyped __cpp__("uv_mutex_lock((uv_mutex_t*){0})", p);
		blockingLeave(r);
	}

	public static function mutexTryLock(m:LuvObject):Int
		return untyped __cpp__("uv_mutex_trylock((uv_mutex_t*){0})", m.ptr);

	public static function mutexUnlock(m:LuvObject):Void
		untyped __cpp__("uv_mutex_unlock((uv_mutex_t*){0})", m.ptr);

	public static function rwlockInit(l:LuvObject):Int
		return untyped __cpp__("uv_rwlock_init((uv_rwlock_t*){0})", l.ptr);

	public static function rwlockDestroy(l:LuvObject):Void
		untyped __cpp__("uv_rwlock_destroy((uv_rwlock_t*){0})", l.ptr);

	public static function rwlockRdLock(l:LuvObject):Void {
		var p = l.ptr;
		var r = blockingEnter();
		untyped __cpp__("uv_rwlock_rdlock((uv_rwlock_t*){0})", p);
		blockingLeave(r);
	}

	public static function rwlockTryRdLock(l:LuvObject):Int
		return untyped __cpp__("uv_rwlock_tryrdlock((uv_rwlock_t*){0})", l.ptr);

	public static function rwlockRdUnlock(l:LuvObject):Void
		untyped __cpp__("uv_rwlock_rdunlock((uv_rwlock_t*){0})", l.ptr);

	public static function rwlockWrLock(l:LuvObject):Void {
		var p = l.ptr;
		var r = blockingEnter();
		untyped __cpp__("uv_rwlock_wrlock((uv_rwlock_t*){0})", p);
		blockingLeave(r);
	}

	public static function rwlockTryWrLock(l:LuvObject):Int
		return untyped __cpp__("uv_rwlock_trywrlock((uv_rwlock_t*){0})", l.ptr);

	public static function rwlockWrUnlock(l:LuvObject):Void
		untyped __cpp__("uv_rwlock_wrunlock((uv_rwlock_t*){0})", l.ptr);

	public static function semaphoreInit(s:LuvObject, count:Int):Int
		return untyped __cpp__("uv_sem_init((uv_sem_t*){0}, (unsigned int){1})", s.ptr, count);

	public static function semaphoreDestroy(s:LuvObject):Void
		untyped __cpp__("uv_sem_destroy((uv_sem_t*){0})", s.ptr);

	public static function semaphorePost(s:LuvObject):Void
		untyped __cpp__("uv_sem_post((uv_sem_t*){0})", s.ptr);

	public static function semaphoreWait(s:LuvObject):Void {
		var p = s.ptr;
		var r = blockingEnter();
		untyped __cpp__("uv_sem_wait((uv_sem_t*){0})", p);
		blockingLeave(r);
	}

	public static function semaphoreTryWait(s:LuvObject):Int
		return untyped __cpp__("uv_sem_trywait((uv_sem_t*){0})", s.ptr);

	public static function conditionInit(c:LuvObject):Int
		return untyped __cpp__("uv_cond_init((uv_cond_t*){0})", c.ptr);

	public static function conditionDestroy(c:LuvObject):Void
		untyped __cpp__("uv_cond_destroy((uv_cond_t*){0})", c.ptr);

	public static function conditionSignal(c:LuvObject):Void
		untyped __cpp__("uv_cond_signal((uv_cond_t*){0})", c.ptr);

	public static function conditionBroadcast(c:LuvObject):Void
		untyped __cpp__("uv_cond_broadcast((uv_cond_t*){0})", c.ptr);

	public static function conditionWait(c:LuvObject, m:LuvObject):Void {
		var cp = c.ptr;
		var mp = m.ptr;
		var r = blockingEnter();
		untyped __cpp__("uv_cond_wait((uv_cond_t*){0}, (uv_mutex_t*){1})", cp, mp);
		blockingLeave(r);
	}

	public static function conditionTimedWait(c:LuvObject, m:LuvObject, timeout:Int):Int {
		var cp = c.ptr;
		var mp = m.ptr;
		var r = blockingEnter();
		var code:Int = untyped __cpp__("uv_cond_timedwait((uv_cond_t*){0}, (uv_mutex_t*){1}, (uint64_t)(int64_t){2})", cp, mp, timeout);
		blockingLeave(r);
		return code;
	}

	public static function barrierInit(b:LuvObject, count:Int):Int
		return untyped __cpp__("uv_barrier_init((uv_barrier_t*){0}, (unsigned int){1})", b.ptr, count);

	public static function barrierDestroy(b:LuvObject):Void
		untyped __cpp__("uv_barrier_destroy((uv_barrier_t*){0})", b.ptr);

	public static function barrierWait(b:LuvObject):Bool {
		var p = b.ptr;
		var r = blockingEnter();
		var serial:Int = untyped __cpp__("uv_barrier_wait((uv_barrier_t*){0})", p);
		blockingLeave(r);
		return serial != 0;
	}

	// The guard starts as UV_ONCE_INIT (the callback travels in a thread-local, created once).
	public static function onceInit(o:LuvObject):Int {
		untyped __cpp__("{ static uv_once_t hxc_initial = UV_ONCE_INIT; memcpy({0}, &hxc_initial, sizeof(uv_once_t)); }", o.ptr);
		return 0;
	}

	// No catchExceptions around it; an exception leaves through uv_once.
	public static function once(o:LuvObject, f:Void->Void):Void {
		onceCallback.value = f;
		untyped __cpp__("uv_once((uv_once_t*){0}, hxc_luv_once)", o.ptr);
	}


	public static function errorIndex(code:Int):Int
		return untyped __cpp__("hxc_luv_error_index({0})", code);

	public static function errorCode(index:Int):Int
		return untyped __cpp__("hxc_luv_error_code({0})", index);

	// A 256-byte buffer, cut at its first NUL.
	public static function strerror(code:Int):String {
		var s:String = null;
		untyped __cpp__("{ char hxc_buf[256]; uv_strerror_r({1}, hxc_buf, 256); {0} = ::String(hxc_buf); }", s, code);
		return s;
	}

	public static function errName(code:Int):String {
		var s:String = null;
		untyped __cpp__("{ char hxc_buf[256]; uv_err_name_r({1}, hxc_buf, 256); {0} = ::String(hxc_buf); }", s, code);
		return s;
	}

	public static function translateSysError(sysError:Int):Int
		return untyped __cpp__("uv_translate_sys_error({0})", sysError);


	public static function versionString():String {
		var s:String = null;
		untyped __cpp__("{0} = ::String(uv_version_string())", s);
		return s;
	}

	public static function versionMajor():Int
		return untyped __cpp__("UV_VERSION_MAJOR");

	public static function versionMinor():Int
		return untyped __cpp__("UV_VERSION_MINOR");

	public static function versionPatch():Int
		return untyped __cpp__("UV_VERSION_PATCH");

	public static function versionIsRelease():Bool
		return (untyped __cpp__("UV_VERSION_IS_RELEASE") : Int) != 0;

	public static function versionSuffix():String {
		var s:String = null;
		untyped __cpp__("{0} = ::String(UV_VERSION_SUFFIX)", s);
		return s;
	}

	public static function versionHex():Int
		return untyped __cpp__("UV_VERSION_HEX");
}

/**
 * A libuv object: a timer, a loop, a mutex... `refs` holds a handle's callbacks, generic first and
 * close second (luv's reference array, .
 */
class LuvObject {
	public var ptr:cpp.RawPointer<cpp.Void>;
	public final owned:Bool;
	public var id:Int = 0;
	public var refs:Array<Null<Void->Void>> = [null, null];

	public function new(ptr:cpp.RawPointer<cpp.Void>, owned:Bool) {
		this.ptr = ptr;
		this.owned = owned;
	}
}
#end
