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
// read, connect, connection, shutdown, write, signal: one int each
static void hxc_luv_call_int(void *data, int index, int a) {
	hx::ExitGCFreeZone();
	::hxc::eval::Luv_obj::dispatchInt((int)(intptr_t)data, index, a);
	hx::EnterGCFreeZone();
}
static void hxc_luv_read(uv_stream_t *h, ssize_t nread, const uv_buf_t *buf) { hxc_luv_call_int(uv_handle_get_data((uv_handle_t*)h), 0, (int)nread); }
static void hxc_luv_connection(uv_stream_t *h, int status) { hxc_luv_call_int(uv_handle_get_data((uv_handle_t*)h), 3, status); }
static void hxc_luv_connect(uv_connect_t *r, int status) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, status); }
static void hxc_luv_shutdown(uv_shutdown_t *r, int status) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, status); }
static void hxc_luv_write(uv_write_t *r, int status) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, status); }
static void hxc_luv_signal(uv_signal_t *h, int signum) { hxc_luv_call(uv_handle_get_data((uv_handle_t*)h), 0); }
static void hxc_luv_udp_send(uv_udp_send_t *r, int status) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, status); }
// The recv trampoline: the count, the sender (or none) and the flags
static void hxc_luv_recv(uv_udp_t *h, ssize_t nread, const uv_buf_t *buf, const struct sockaddr *addr, unsigned flags) {
	hx::ExitGCFreeZone();
	::hxc::eval::Luv_obj::dispatchRecv((int)(intptr_t)uv_handle_get_data((uv_handle_t*)h), (int)nread, (void*)addr, (int)flags);
	hx::EnterGCFreeZone();
}
// The fs_event trampoline: the file name (or none), the events and the status
static void hxc_luv_fs_event(uv_fs_event_t *h, const char *filename, int events, int status) {
	hx::ExitGCFreeZone();
	::hxc::eval::Luv_obj::dispatchFsEvent((int)(intptr_t)uv_handle_get_data((uv_handle_t*)h), (void*)filename, events, status);
	hx::EnterGCFreeZone();
}
// The alloc trampoline: libuv reads into the buffer the allocate callback answers
static void hxc_luv_alloc(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
	hx::ExitGCFreeZone();
	::hxc::eval::LuvBuffer b = ::hxc::eval::Luv_obj::dispatchAlloc((int)(intptr_t)uv_handle_get_data(h), (int)suggested);
	buf->base = (char*)b->bytes->b->GetBase() + b->offset;
	buf->len = b->length;
	hx::EnterGCFreeZone();
}
')
@:access(hxc.eval.LuvSys)
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

	public static function loopNow(l:LuvObject):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)uv_now((uv_loop_t*){0})", l.ptr);

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
			case HTcp: untyped __cpp__("malloc(sizeof(uv_tcp_t))");
			case HUdp: untyped __cpp__("malloc(sizeof(uv_udp_t))");
			case HPipe: untyped __cpp__("malloc(sizeof(uv_pipe_t))");
			case HTty: untyped __cpp__("malloc(sizeof(uv_tty_t))");
			case HSignal: untyped __cpp__("malloc(sizeof(uv_signal_t))");
			case HFsEvent: untyped __cpp__("malloc(sizeof(uv_fs_event_t))");
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

	// ---- requests: a request is retained like a handle until its callback runs ----

	static function newRequest(size:Int):LuvObject {
		var o = own(untyped __cpp__("calloc(1, (size_t){0})", size));
		retainedLock.acquire();
		o.id = nextId++;
		retained.set(o.id, o);
		retainedLock.release();
		untyped __cpp__("uv_req_set_data((uv_req_t*){0}, (void*)(intptr_t){1})", o.ptr, o.id);
		return o;
	}

	// The request is released before its callback runs.
	static function setRequestCallback(r:LuvObject, callback:Int->Void):Void {
		r.refs[0] = function(status:Int) {
			release(r);
			callback(status);
		};
	}

	@:keep public static function dispatchInt(id:Int, index:Int, a:Int):Void {
		var s = runStack();
		var reacquire = s.length > 0 && s[s.length - 1];
		if (reacquire) EvalStdLib.gilReacquire();
		retainedLock.acquire();
		var o = retained.get(id);
		retainedLock.release();
		var f:Dynamic = o == null ? null : o.refs[index];
		if (f != null) f(a);
		if (reacquire) EvalStdLib.gilRelease();
	}

	// The alloc trampoline: the allocate callback's buffer is where libuv reads into
	@:keep public static function dispatchAlloc(id:Int, suggested:Int):LuvSys.LuvBuffer {
		var s = runStack();
		var reacquire = s.length > 0 && s[s.length - 1];
		if (reacquire) EvalStdLib.gilReacquire();
		retainedLock.acquire();
		var o = retained.get(id);
		retainedLock.release();
		var f:Dynamic = o == null ? null : o.refs[2];
		var b:LuvSys.LuvBuffer = f(suggested);
		if (reacquire) EvalStdLib.gilRelease();
		return b;
	}

	// The recv trampoline: nread, the sender's address (or none) and the flags
	@:keep public static function dispatchRecv(id:Int, nread:Int, addr:cpp.RawPointer<cpp.Void>, flags:Int):Void {
		var s = runStack();
		var reacquire = s.length > 0 && s[s.length - 1];
		if (reacquire) EvalStdLib.gilReacquire();
		retainedLock.acquire();
		var o = retained.get(id);
		retainedLock.release();
		var storage:Null<haxe.io.Bytes> = null;
		if (addr != null) {
			storage = LuvSys.newSockaddr();
			untyped __cpp__("memcpy({0}->b->GetBase(), {1}, sizeof(struct sockaddr_storage))", storage, addr);
		}
		var f:Dynamic = o == null ? null : o.refs[0];
		if (f != null) f(nread, storage, flags);
		if (reacquire) EvalStdLib.gilRelease();
	}

	static function bufs(buffers:Array<LuvSys.LuvBuffer>):cpp.RawPointer<cpp.Void> {
		var n = buffers.length;
		var arr:cpp.RawPointer<cpp.Void> = untyped __cpp__("calloc((size_t)({0} > 0 ? {0} : 1), sizeof(uv_buf_t))", n);
		for (i in 0...n) {
			var b = buffers[i];
			var base = b.bytes;
			var off = b.offset;
			var len = b.length;
			untyped __cpp__("((uv_buf_t*){0})[{1}] = uv_buf_init((char*){2}->b->GetBase() + {3}, (unsigned int){4})", arr, i, base, off, len);
		}
		return arr;
	}


	public static function newStream(kind:EvalHandleKind):LuvObject return newHandle(kind);

	public static function shutdown(stream:LuvObject, callback:Int->Void):Void {
		var r = newRequest(untyped __cpp__("(int)sizeof(uv_shutdown_t)"));
		var wrapped = catchExceptions1(callback);
		setRequestCallback(r, wrapped);
		var immediate:Int = untyped __cpp__("uv_shutdown((uv_shutdown_t*){0}, (uv_stream_t*){1}, hxc_luv_shutdown)", r.ptr, stream.ptr);
		if (immediate < 0) {
			release(r);
			callback(immediate);
		}
	}

	public static function listen(server:LuvObject, backlog:Int, callback:Int->Void):Void {
		server.refs[3] = catchExceptions1(callback);
		var immediate:Int = untyped __cpp__("uv_listen((uv_stream_t*){0}, {1}, hxc_luv_connection)", server.ptr, backlog);
		if (immediate < 0) callback(immediate);
	}

	// Somaxconn, clamped to an int
	public static function somaxconn():Int
		return untyped __cpp__("(int)(SOMAXCONN > 0x7fffffff ? 0x7fffffff : SOMAXCONN)");

	public static function accept(server:LuvObject, client:LuvObject):Int
		return untyped __cpp__("uv_accept((uv_stream_t*){0}, (uv_stream_t*){1})", server.ptr, client.ptr);

	// The buffer last allocated is the one read into, cut to what was read when it is longer; a read
	// of 0 or less is an error, 0 included (0 maps to UNKNOWN)
	public static function readStart(stream:LuvObject, allocate:Int->LuvSys.LuvBuffer, callback:Int->Null<LuvSys.LuvBuffer>->Void):Void {
		var last:Null<LuvSys.LuvBuffer> = null;
		var wrapped = catchExceptions2(callback);
		stream.refs[0] = function(nread:Int) {
			if (nread > 0) {
				var b = last;
				last = null;
				if (b.length > nread) b = new LuvSys.LuvBuffer(b.bytes, b.offset, nread);
				wrapped(0, b);
			} else {
				last = null;
				wrapped(nread, null);
			}
		};
		stream.refs[2] = function(suggested:Int) {
			var b = allocate(suggested);
			last = b;
			return b;
		};
		var immediate:Int = untyped __cpp__("uv_read_start((uv_stream_t*){0}, hxc_luv_alloc, hxc_luv_read)", stream.ptr);
		if (immediate < 0) callback(immediate, null);
	}

	public static function readStop(stream:LuvObject):Int
		return untyped __cpp__("uv_read_stop((uv_stream_t*){0})", stream.ptr);

	// The callback is told how much of the data left the queue
	public static function write(stream:LuvObject, buffers:Array<LuvSys.LuvBuffer>, sendHandle:Null<LuvObject>, callback:Int->Int->Void):Void {
		var count = buffers.length;
		var total = 0;
		for (b in buffers) total += b.length;
		var iov = bufs(buffers);
		var r = newRequest(untyped __cpp__("(int)sizeof(uv_write_t)"));
		// The buffers and their iovecs live until the callback; the retained request holds them
		r.refs[1] = buffers;
		var wrapped = catchExceptions2(function(status:Int, _:Null<Int>) {
			untyped __cpp__("free({0})", iov);
			var unwritten:Int = untyped __cpp__("(int)uv_stream_get_write_queue_size((uv_stream_t*){0})", stream.ptr);
			callback(status, total - unwritten);
		});
		setRequestCallback(r, status -> wrapped(status, null));
		var sh:cpp.RawPointer<cpp.Void> = sendHandle == null ? null : sendHandle.ptr;
		var immediate:Int = untyped __cpp__("uv_write2((uv_write_t*){0}, (uv_stream_t*){1}, (const uv_buf_t*){2}, (unsigned int){3}, (uv_stream_t*){4}, hxc_luv_write)",
			r.ptr, stream.ptr, iov, count, sh);
		if (immediate < 0) {
			release(r);
			untyped __cpp__("free({0})", iov);
			callback(immediate, 0);
		}
	}

	public static function tryWrite(stream:LuvObject, buffers:Array<LuvSys.LuvBuffer>):Int {
		var iov = bufs(buffers);
		var r:Int = untyped __cpp__("uv_try_write((uv_stream_t*){0}, (const uv_buf_t*){1}, (unsigned int){2})", stream.ptr, iov, buffers.length);
		untyped __cpp__("free({0})", iov);
		return r;
	}

	public static function isReadable(stream:LuvObject):Bool
		return (untyped __cpp__("uv_is_readable((const uv_stream_t*){0})", stream.ptr) : Int) != 0;

	public static function isWritable(stream:LuvObject):Bool
		return (untyped __cpp__("uv_is_writable((const uv_stream_t*){0})", stream.ptr) : Int) != 0;

	public static function setBlocking(stream:LuvObject, blocking:Bool):Int
		return untyped __cpp__("uv_stream_set_blocking((uv_stream_t*){0}, {1} ? 1 : 0)", stream.ptr, blocking);

	// The send and receive buffer sizes: libuv reads the size, and for 0 writes it back
	public static function bufferSize(h:LuvObject, send:Bool, value:Array<Int>):Int {
		var r = 0;
		var v = value[0];
		untyped __cpp__("{ int hxc_v = {0}; {1} = {2} ? uv_send_buffer_size((uv_handle_t*){3}, &hxc_v) : uv_recv_buffer_size((uv_handle_t*){3}, &hxc_v); {0} = hxc_v; }",
			v, r, send, h.ptr);
		value[0] = v;
		return r;
	}


	// Domain: -1 none, else the AF_ value
	public static function tcpInit(l:LuvObject, t:LuvObject, domain:Int):Int {
		return domain < 0 ? untyped __cpp__("uv_tcp_init((uv_loop_t*){0}, (uv_tcp_t*){1})", l.ptr, t.ptr)
			: untyped __cpp__("uv_tcp_init_ex((uv_loop_t*){0}, (uv_tcp_t*){1}, (unsigned int){2})", l.ptr, t.ptr, domain);
	}

	public static function tcpNoDelay(t:LuvObject, enable:Bool):Int
		return untyped __cpp__("uv_tcp_nodelay((uv_tcp_t*){0}, {1} ? 1 : 0)", t.ptr, enable);

	// A null `seconds` turns keepalive off, with 0 seconds
	public static function tcpKeepAlive(t:LuvObject, seconds:Null<Int>):Int {
		var on = seconds != null;
		var d = on ? seconds : 0;
		return untyped __cpp__("uv_tcp_keepalive((uv_tcp_t*){0}, {1} ? 1 : 0, (unsigned int){2})", t.ptr, on, d);
	}

	public static function tcpSimultaneousAccepts(t:LuvObject, enable:Bool):Int
		return untyped __cpp__("uv_tcp_simultaneous_accepts((uv_tcp_t*){0}, {1} ? 1 : 0)", t.ptr, enable);

	public static function tcpBind(t:LuvObject, addr:haxe.io.Bytes, ipv6only:Bool):Int
		return untyped __cpp__("uv_tcp_bind((uv_tcp_t*){0}, (const struct sockaddr*){1}->b->GetBase(), {2} ? UV_TCP_IPV6ONLY : 0)", t.ptr, addr, ipv6only);

	// A fresh sockaddr storage and its size
	public static function tcpName(t:LuvObject, peer:Bool, storage:haxe.io.Bytes):Int {
		var r = 0;
		untyped __cpp__("{ int hxc_len = (int)sizeof(struct sockaddr_storage); {0} = {1} ? uv_tcp_getpeername((const uv_tcp_t*){2}, (struct sockaddr*){3}->b->GetBase(), &hxc_len) : uv_tcp_getsockname((const uv_tcp_t*){2}, (struct sockaddr*){3}->b->GetBase(), &hxc_len); }",
			r, peer, t.ptr, storage);
		return r;
	}

	public static function tcpConnect(t:LuvObject, addr:haxe.io.Bytes, callback:Int->Void):Void {
		var r = newRequest(untyped __cpp__("(int)sizeof(uv_connect_t)"));
		setRequestCallback(r, catchExceptions1(callback));
		var immediate:Int = untyped __cpp__("uv_tcp_connect((uv_connect_t*){0}, (uv_tcp_t*){1}, (const struct sockaddr*){2}->b->GetBase(), hxc_luv_connect)", r.ptr, t.ptr, addr);
		if (immediate < 0) {
			release(r);
			callback(immediate);
		}
	}

	public static function tcpCloseReset(t:LuvObject, callback:Int->Void):Void {
		if (isClosing(t)) {
			callback(0);
			return;
		}
		var wrapped = catchExceptions1(callback);
		t.refs[1] = function() {
			release(t);
			wrapped(0);
		};
		var immediate:Int = untyped __cpp__("uv_tcp_close_reset((uv_tcp_t*){0}, hxc_luv_close)", t.ptr);
		if (immediate < 0) callback(immediate);
	}


	// The domain's AF_ value or'ed with UV_UDP_RECVMMSG
	public static function udpInit(l:LuvObject, u:LuvObject, domain:Int, recvmmsg:Bool):Int {
		var flags:Int = recvmmsg ? domain | (untyped __cpp__("UV_UDP_RECVMMSG") : Int) : domain;
		return untyped __cpp__("uv_udp_init_ex((uv_loop_t*){0}, (uv_udp_t*){1}, (unsigned int){2})", l.ptr, u.ptr, flags);
	}

	public static function udpBind(u:LuvObject, addr:haxe.io.Bytes, ipv6only:Bool, reuseaddr:Bool):Int {
		var flags = 0;
		if (ipv6only) flags |= (untyped __cpp__("UV_UDP_IPV6ONLY") : Int);
		if (reuseaddr) flags |= (untyped __cpp__("UV_UDP_REUSEADDR") : Int);
		return untyped __cpp__("uv_udp_bind((uv_udp_t*){0}, (const struct sockaddr*){1}->b->GetBase(), (unsigned int){2})", u.ptr, addr, flags);
	}

	// The socket's own name, or a connected socket's peer name
	public static function udpName(u:LuvObject, peer:Bool, storage:haxe.io.Bytes):Int {
		var r = 0;
		untyped __cpp__("{ int hxc_len = (int)sizeof(struct sockaddr_storage); {0} = {1} ? uv_udp_getpeername((const uv_udp_t*){2}, (struct sockaddr*){3}->b->GetBase(), &hxc_len) : uv_udp_getsockname((const uv_udp_t*){2}, (struct sockaddr*){3}->b->GetBase(), &hxc_len); }",
			r, peer, u.ptr, storage);
		return r;
	}

	// Membership: 0 UV_LEAVE_GROUP, 1 UV_JOIN_GROUP
	public static function udpSetMembership(u:LuvObject, group:haxe.io.Bytes, iface:haxe.io.Bytes, join:Bool):Int {
		var g = LuvSys.cString(group);
		var i = LuvSys.cString(iface);
		return untyped __cpp__("uv_udp_set_membership((uv_udp_t*){0}, (const char*){1}->b->GetBase(), (const char*){2}->b->GetBase(), {3} ? UV_JOIN_GROUP : UV_LEAVE_GROUP)", u.ptr, g, i, join);
	}

	public static function udpSetSourceMembership(u:LuvObject, group:haxe.io.Bytes, iface:haxe.io.Bytes, source:haxe.io.Bytes, join:Bool):Int {
		var g = LuvSys.cString(group);
		var i = LuvSys.cString(iface);
		var s = LuvSys.cString(source);
		return untyped __cpp__("uv_udp_set_source_membership((uv_udp_t*){0}, (const char*){1}->b->GetBase(), (const char*){2}->b->GetBase(), (const char*){3}->b->GetBase(), {4} ? UV_JOIN_GROUP : UV_LEAVE_GROUP)", u.ptr, g, i, s, join);
	}

	public static function udpSetMulticastLoop(u:LuvObject, on:Bool):Int
		return untyped __cpp__("uv_udp_set_multicast_loop((uv_udp_t*){0}, {1} ? 1 : 0)", u.ptr, on);

	public static function udpSetMulticastTtl(u:LuvObject, ttl:Int):Int
		return untyped __cpp__("uv_udp_set_multicast_ttl((uv_udp_t*){0}, {1})", u.ptr, ttl);

	public static function udpSetMulticastInterface(u:LuvObject, iface:haxe.io.Bytes):Int {
		var i = LuvSys.cString(iface);
		return untyped __cpp__("uv_udp_set_multicast_interface((uv_udp_t*){0}, (const char*){1}->b->GetBase())", u.ptr, i);
	}

	public static function udpSetBroadcast(u:LuvObject, on:Bool):Int
		return untyped __cpp__("uv_udp_set_broadcast((uv_udp_t*){0}, {1} ? 1 : 0)", u.ptr, on);

	public static function udpSetTtl(u:LuvObject, ttl:Int):Int
		return untyped __cpp__("uv_udp_set_ttl((uv_udp_t*){0}, {1})", u.ptr, ttl);

	// A null address sends to the connected peer
	public static function udpSend(u:LuvObject, buffers:Array<LuvSys.LuvBuffer>, addr:Null<haxe.io.Bytes>, callback:Int->Void):Void {
		var count = buffers.length;
		var iov = bufs(buffers);
		var r = newRequest(untyped __cpp__("(int)sizeof(uv_udp_send_t)"));
		// The buffers and their iovecs live until the callback
		r.refs[1] = buffers;
		var wrapped = catchExceptions1(callback);
		setRequestCallback(r, function(status:Int) {
			untyped __cpp__("free({0})", iov);
			wrapped(status);
		});
		var sa:cpp.RawPointer<cpp.Void> = addr == null ? null : untyped __cpp__("(void*){0}->b->GetBase()", addr);
		var immediate:Int = untyped __cpp__("uv_udp_send((uv_udp_send_t*){0}, (uv_udp_t*){1}, (const uv_buf_t*){2}, (unsigned int){3}, (const struct sockaddr*){4}, hxc_luv_udp_send)",
			r.ptr, u.ptr, iov, count, sa);
		if (immediate < 0) {
			release(r);
			untyped __cpp__("free({0})", iov);
			callback(immediate);
		}
	}

	public static function udpTrySend(u:LuvObject, buffers:Array<LuvSys.LuvBuffer>, addr:Null<haxe.io.Bytes>):Int {
		var iov = bufs(buffers);
		var sa:cpp.RawPointer<cpp.Void> = addr == null ? null : untyped __cpp__("(void*){0}->b->GetBase()", addr);
		var r:Int = untyped __cpp__("uv_udp_try_send((uv_udp_t*){0}, (const uv_buf_t*){1}, (unsigned int){2}, (const struct sockaddr*){3})", u.ptr, iov, buffers.length, sa);
		untyped __cpp__("free({0})", iov);
		return r;
	}

	// An error goes to the callback as it is; a datagram (0 bytes included) goes under
	// catchExceptions, with its buffer cut to what was read, the sender (none for a null address) and
	// the flags, newest first
	public static function udpRecvStart(u:LuvObject, allocate:Int->LuvSys.LuvBuffer, callback:Int->Null<LuvSys.LuvBuffer>->Null<haxe.io.Bytes>->Array<Int>->Void):Void {
		var last:Null<LuvSys.LuvBuffer> = null;
		var partial:Int = untyped __cpp__("UV_UDP_PARTIAL");
		var mmsgChunk:Int = untyped __cpp__("UV_UDP_MMSG_CHUNK");
		var mmsgFree:Int = untyped __cpp__("UV_UDP_MMSG_FREE");
		u.refs[0] = function(nread:Int, sockaddr:Null<haxe.io.Bytes>, flags:Int) {
			var b = last;
			last = null;
			if (nread < 0) {
				callback(nread, null, null, null);
			} else {
				if (b.length > nread) b = new LuvSys.LuvBuffer(b.bytes, b.offset, nread);
				var list = [];
				if (flags & partial != 0) list.unshift(0);
				if (flags & mmsgChunk != 0) list.unshift(1);
				if (flags & mmsgFree != 0) list.unshift(2);
				try callback(0, b, sockaddr, list) catch (e:Dynamic) exceptionHandler(e);
			}
		};
		u.refs[2] = function(suggested:Int) {
			var b = allocate(suggested);
			last = b;
			return b;
		};
		var immediate:Int = untyped __cpp__("uv_udp_recv_start((uv_udp_t*){0}, hxc_luv_alloc, hxc_luv_recv)", u.ptr);
		if (immediate < 0) callback(immediate, null, null, null);
	}

	public static function udpRecvStop(u:LuvObject):Int
		return untyped __cpp__("uv_udp_recv_stop((uv_udp_t*){0})", u.ptr);

	public static function udpSendQueueSize(u:LuvObject):Int
		return untyped __cpp__("(int)uv_udp_get_send_queue_size((const uv_udp_t*){0})", u.ptr);

	public static function udpSendQueueCount(u:LuvObject):Int
		return untyped __cpp__("(int)uv_udp_get_send_queue_count((const uv_udp_t*){0})", u.ptr);

	// Connect, or disconnect for a null address
	public static function udpConnect(u:LuvObject, addr:Null<haxe.io.Bytes>):Int {
		var sa:cpp.RawPointer<cpp.Void> = addr == null ? null : untyped __cpp__("(void*){0}->b->GetBase()", addr);
		return untyped __cpp__("uv_udp_connect((uv_udp_t*){0}, (const struct sockaddr*){1})", u.ptr, sa);
	}


	public static function pipeInit(l:LuvObject, p:LuvObject, ipc:Bool):Int
		return untyped __cpp__("uv_pipe_init((uv_loop_t*){0}, (uv_pipe_t*){1}, {2} ? 1 : 0)", l.ptr, p.ptr, ipc);

	// A name starting with NUL (an abstract socket) goes to bind2 whole; a blocking call
	public static function pipeBind(p:LuvObject, name:haxe.io.Bytes):Int {
		var r = 0;
		var released = blockingEnter();
		if (name.length > 0 && name.get(0) == 0)
			r = untyped __cpp__("uv_pipe_bind2((uv_pipe_t*){0}, (const char*){1}->b->GetBase(), (size_t){2}, 0)", p.ptr, name, name.length);
		else {
			var c = LuvSys.cString(name);
			r = untyped __cpp__("uv_pipe_bind((uv_pipe_t*){0}, (const char*){1}->b->GetBase())", p.ptr, c);
		}
		blockingLeave(released);
		return r;
	}

	// Whatever connect2 answers is dropped, and uv_pipe_connect reports through the callback
	public static function pipeConnect(p:LuvObject, name:haxe.io.Bytes, callback:Int->Void):Void {
		var r = newRequest(untyped __cpp__("(int)sizeof(uv_connect_t)"));
		setRequestCallback(r, catchExceptions1(callback));
		if (name.length > 0 && name.get(0) == 0)
			untyped __cpp__("uv_pipe_connect2((uv_connect_t*){0}, (uv_pipe_t*){1}, (const char*){2}->b->GetBase(), (size_t){3}, 0, hxc_luv_connect)", r.ptr, p.ptr, name, name.length);
		else {
			var c = LuvSys.cString(name);
			untyped __cpp__("uv_pipe_connect((uv_connect_t*){0}, (uv_pipe_t*){1}, (const char*){2}->b->GetBase(), hxc_luv_connect)", r.ptr, p.ptr, c);
		}
	}

	// 128 bytes, then again at the size UV_ENOBUFS asks for
	public static function pipeName(p:LuvObject, peer:Bool, out:Array<haxe.io.Bytes>):Int {
		var size = 128;
		while (true) {
			var buffer = haxe.io.Bytes.alloc(size);
			var r = 0;
			var len = size;
			untyped __cpp__("{ size_t hxc_len = (size_t){0}; {1} = {2} ? uv_pipe_getpeername((const uv_pipe_t*){3}, (char*){4}->b->GetBase(), &hxc_len) : uv_pipe_getsockname((const uv_pipe_t*){3}, (char*){4}->b->GetBase(), &hxc_len); {0} = (int)hxc_len; }",
				len, r, peer, p.ptr, buffer);
			if (r >= 0) {
				out[0] = buffer.sub(0, len);
				return r;
			}
			if (r != (untyped __cpp__("UV_ENOBUFS") : Int)) return r;
			size = len;
		}
	}

	public static function pipePendingInstances(p:LuvObject, count:Int):Void
		untyped __cpp__("uv_pipe_pending_instances((uv_pipe_t*){0}, {1})", p.ptr, count);

	public static function pipePendingCount(p:LuvObject):Int
		return untyped __cpp__("uv_pipe_pending_count((uv_pipe_t*){0})", p.ptr);

	// The pending handle: 1 a TCP handle, 2 a pipe, 0 anything else
	public static function pipePendingKind(p:LuvObject):Int {
		return untyped __cpp__("(uv_pipe_pending_type((uv_pipe_t*){0}) == UV_TCP ? 1 : uv_pipe_pending_type((uv_pipe_t*){0}) == UV_NAMED_PIPE ? 2 : 0)", p.ptr);
	}

	// The modes or'ed
	public static function pipeChmod(p:LuvObject, readable:Bool, writable:Bool):Int {
		var flags = 0;
		if (readable) flags |= (untyped __cpp__("UV_READABLE") : Int);
		if (writable) flags |= (untyped __cpp__("UV_WRITABLE") : Int);
		return untyped __cpp__("uv_pipe_chmod((uv_pipe_t*){0}, {1})", p.ptr, flags);
	}


	public static function fsEventInit(l:LuvObject, e:LuvObject):Int
		return untyped __cpp__("uv_fs_event_init((uv_loop_t*){0}, (uv_fs_event_t*){1})", l.ptr, e.ptr);

	// The result and the events newest first, under catchExceptions; an immediate error goes to the
	// callback as it is
	public static function fsEventStart(e:LuvObject, path:haxe.io.Bytes, watchEntry:Bool, stat:Bool, recursive:Bool, callback:Int->Null<haxe.io.Bytes>->Array<Int>->Void):Void {
		var flags = 0;
		if (watchEntry) flags |= (untyped __cpp__("UV_FS_EVENT_WATCH_ENTRY") : Int);
		if (stat) flags |= (untyped __cpp__("UV_FS_EVENT_STAT") : Int);
		if (recursive) flags |= (untyped __cpp__("UV_FS_EVENT_RECURSIVE") : Int);
		var rename:Int = untyped __cpp__("UV_RENAME");
		var change:Int = untyped __cpp__("UV_CHANGE");
		e.refs[0] = function(filename:Null<haxe.io.Bytes>, events:Int, status:Int) {
			var list = [];
			if (status >= 0) {
				if (events & rename != 0) list.unshift(0);
				if (events & change != 0) list.unshift(1);
			}
			try callback(status, filename, list) catch (x:Dynamic) exceptionHandler(x);
		};
		var c = LuvSys.cString(path);
		var immediate:Int = untyped __cpp__("uv_fs_event_start((uv_fs_event_t*){0}, hxc_luv_fs_event, (const char*){1}->b->GetBase(), (unsigned int){2})", e.ptr, c, flags);
		if (immediate < 0) callback(immediate, null, null);
	}

	public static function fsEventStop(e:LuvObject):Int
		return untyped __cpp__("uv_fs_event_stop((uv_fs_event_t*){0})", e.ptr);

	@:keep public static function dispatchFsEvent(id:Int, filename:cpp.RawPointer<cpp.Void>, events:Int, status:Int):Void {
		var s = runStack();
		var reacquire = s.length > 0 && s[s.length - 1];
		if (reacquire) EvalStdLib.gilReacquire();
		retainedLock.acquire();
		var o = retained.get(id);
		retainedLock.release();
		var name = LuvSys.fromC(filename);
		var f:Dynamic = o == null ? null : o.refs[0];
		if (f != null) f(name, events, status);
		if (reacquire) EvalStdLib.gilRelease();
	}


	public static function signalInit(l:LuvObject, s:LuvObject):Int
		return untyped __cpp__("uv_signal_init((uv_loop_t*){0}, (uv_signal_t*){1})", l.ptr, s.ptr);

	public static function signalStart(s:LuvObject, signum:Int, oneshot:Bool, callback:Void->Void):Int {
		s.refs[0] = catchExceptions(callback);
		return oneshot ? untyped __cpp__("uv_signal_start_oneshot((uv_signal_t*){0}, hxc_luv_signal, {1})", s.ptr, signum)
			: untyped __cpp__("uv_signal_start((uv_signal_t*){0}, hxc_luv_signal, {1})", s.ptr, signum);
	}

	public static function signalStop(s:LuvObject):Int
		return untyped __cpp__("uv_signal_stop((uv_signal_t*){0})", s.ptr);

	public static function signalSignum(s:LuvObject):Int
		return untyped __cpp__("((uv_signal_t*){0})->signum", s.ptr);

	public static function signum(name:String):Int {
		return switch (name) {
			case "SIGABRT": untyped __cpp__("SIGABRT");
			case "SIGFPE": untyped __cpp__("SIGFPE");
			case "SIGHUP": untyped __cpp__("SIGHUP");
			case "SIGILL": untyped __cpp__("SIGILL");
			case "SIGINT": untyped __cpp__("SIGINT");
			case "SIGKILL": untyped __cpp__("SIGKILL");
			case "SIGSEGV": untyped __cpp__("SIGSEGV");
			case "SIGTERM": untyped __cpp__("SIGTERM");
			case _: untyped __cpp__("SIGWINCH");
		};
	}

	// catchExceptions for callbacks with arguments
	public static function catchExceptions1<A>(f:A->Void):A->Void {
		return function(a:A) {
			try f(a) catch (e:Dynamic) exceptionHandler(e);
		};
	}

	public static function catchExceptions2<A, B>(f:A->B->Void):A->B->Void {
		return function(a:A, b:B) {
			try f(a, b) catch (e:Dynamic) exceptionHandler(e);
		};
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
	A libuv object: a timer, a loop, a mutex, a request... `refs` holds a handle's or request's
	callbacks.
**/
class LuvObject {
	public var ptr:cpp.RawPointer<cpp.Void>;
	public final owned:Bool;
	public var id:Int = 0;
	// Generic, close, allocate, connection (helpers.h LUV_*_CALLBACK)
	public var refs:Array<Dynamic> = [null, null, null, null];

	public function new(ptr:cpp.RawPointer<cpp.Void>, owned:Bool) {
		this.ptr = ptr;
		this.owned = owned;
	}
}
#end
