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
static void hxc_luv_fs(uv_fs_t *r) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, 0); }
static void hxc_luv_random(uv_random_t *r, int status, void *buf, size_t len) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, status); }
static void hxc_luv_getaddrinfo(uv_getaddrinfo_t *r, int status, struct addrinfo *res) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, status); }
static void hxc_luv_getnameinfo(uv_getnameinfo_t *r, int status, const char *host, const char *service) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, status); }
static void hxc_luv_after_work(uv_work_t *r, int status) { hxc_luv_call_int(uv_req_get_data((uv_req_t*)r), 0, status); }
// The exit trampoline: the exit status and the terminating signal
static void hxc_luv_exit(uv_process_t *h, int64_t status, int signal) {
	hx::ExitGCFreeZone();
	::hxc::eval::Luv_obj::dispatchExit((int)(intptr_t)uv_handle_get_data((uv_handle_t*)h), (::cpp::Int64)status, signal);
	hx::EnterGCFreeZone();
}
// Register libuv worker threads with the collector for each callback.
static void hxc_luv_work(uv_work_t *r) {
	int hxc_top = 0;
	hx::SetTopOfStack(&hxc_top, true);
	::hxc::eval::Luv_obj::dispatchWork((int)(intptr_t)uv_req_get_data((uv_req_t*)r));
	hx::UnregisterCurrentThread();
}
static void hxc_luv_thread(void *arg) {
	int hxc_top = 0;
	hx::SetTopOfStack(&hxc_top, true);
	::hxc::eval::Luv_obj::dispatchThread((int)(intptr_t)arg);
	hx::UnregisterCurrentThread();
}
// The fs_poll trampoline: the status and both stats
static void hxc_luv_fs_poll(uv_fs_poll_t *h, int status, const uv_stat_t *prev, const uv_stat_t *curr) {
	hx::ExitGCFreeZone();
	::hxc::eval::Luv_obj::dispatchFsPoll((int)(intptr_t)uv_handle_get_data((uv_handle_t*)h), status, (void*)prev, (void*)curr);
	hx::EnterGCFreeZone();
}
// Use the mingw-w64 File.Mode values: POSIX sys/stat.h bits, S_IFLNK from uv/win.h, and zero
// set-id/sticky bits.
#ifdef _WIN32
#define HXC_S_IRWXU 0700
#define HXC_S_IRUSR 0400
#define HXC_S_IWUSR 0200
#define HXC_S_IXUSR 0100
#define HXC_S_IRWXG 0070
#define HXC_S_IRGRP 0040
#define HXC_S_IWGRP 0020
#define HXC_S_IXGRP 0010
#define HXC_S_IRWXO 0007
#define HXC_S_IROTH 0004
#define HXC_S_IWOTH 0002
#define HXC_S_IXOTH 0001
#define HXC_S_ISUID 0
#define HXC_S_ISGID 0
#define HXC_S_ISVTX 0
#define HXC_S_IFMT 0xF000
#define HXC_S_IFREG 0x8000
#define HXC_S_IFDIR 0x4000
#define HXC_S_IFBLK 0x3000
#define HXC_S_IFCHR 0x2000
#define HXC_S_IFLNK 0xA000
#define HXC_S_IFIFO 0x1000
#else
#include <sys/stat.h>
#define HXC_S_IRWXU S_IRWXU
#define HXC_S_IRUSR S_IRUSR
#define HXC_S_IWUSR S_IWUSR
#define HXC_S_IXUSR S_IXUSR
#define HXC_S_IRWXG S_IRWXG
#define HXC_S_IRGRP S_IRGRP
#define HXC_S_IWGRP S_IWGRP
#define HXC_S_IXGRP S_IXGRP
#define HXC_S_IRWXO S_IRWXO
#define HXC_S_IROTH S_IROTH
#define HXC_S_IWOTH S_IWOTH
#define HXC_S_IXOTH S_IXOTH
#define HXC_S_ISUID S_ISUID
#define HXC_S_ISGID S_ISGID
#define HXC_S_ISVTX S_ISVTX
#define HXC_S_IFMT S_IFMT
#define HXC_S_IFREG S_IFREG
#define HXC_S_IFDIR S_IFDIR
#define HXC_S_IFBLK S_IFBLK
#define HXC_S_IFCHR S_IFCHR
#define HXC_S_IFLNK S_IFLNK
#define HXC_S_IFIFO S_IFIFO
#endif
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
		hxc.compiler.HostRuntime.exit(2);
	};

	// Sends a callback's exception to exceptionHandler. A thread exit passes through it.
	public static function catchExceptions(f:Void->Void):Void->Void {
		return function() {
			try f() catch (e:EvalExceptions.EvalThreadExit) throw e catch (e:Dynamic) exceptionHandler(e);
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
			case HFsPoll: untyped __cpp__("malloc(sizeof(uv_fs_poll_t))");
			case HProcess: untyped __cpp__("malloc(sizeof(uv_process_t))");
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


	// What a finished request answers, by kind. Only a directory scan keeps its request past success.
	public static inline var FS_ERROR = 0;
	public static inline var FS_FILE = 1;
	public static inline var FS_BYTES = 2;
	public static inline var FS_PATH = 3;
	public static inline var FS_PATH_FILE = 4;
	public static inline var FS_DIR = 5;
	public static inline var FS_DIRENTS = 6;
	public static inline var FS_SCAN = 7;
	public static inline var FS_STAT = 8;
	public static inline var FS_STATFS = 9;
	public static inline var FS_STRING = 10;

	public static function newFsRequest():LuvObject
		return newRequest(untyped __cpp__("(int)sizeof(uv_fs_t)"));

	static function fsIntResult(req:LuvObject):Int
		return untyped __cpp__("(int)uv_fs_get_result((uv_fs_t*){0})", req.ptr);

	static function fsCleanup(req:LuvObject):Void {
		var released = blockingEnter();
		untyped __cpp__("uv_fs_req_cleanup((uv_fs_t*){0})", req.ptr);
		blockingLeave(released);
	}

	// Each kind's result from a finished request; the value is read only on success
	static function fsFromRequest(kind:Int, req:LuvObject):FsResult {
		var result = fsIntResult(req);
		var code = result < 0 ? result : 0;
		switch (kind) {
			case FS_ERROR:
				return new FsResult(code, null);
			case FS_FILE:
				return new FsResult(result, result);
			case FS_BYTES:
				var n:haxe.Int64 = untyped __cpp__("(::cpp::Int64)uv_fs_get_result((uv_fs_t*){0})", req.ptr);
				return n >= 0 ? new FsResult(0, n) : new FsResult(haxe.Int64.toInt(n), null);
			case _:
		}
		if (code < 0) return new FsResult(code, null);
		var value:Dynamic = switch (kind) {
			case FS_PATH: LuvSys.fromC(untyped __cpp__("(void*)uv_fs_get_path((uv_fs_t*){0})", req.ptr));
			case FS_PATH_FILE: new FsPathFile(LuvSys.fromC(untyped __cpp__("(void*)uv_fs_get_path((uv_fs_t*){0})", req.ptr)), result);
			case FS_DIR: new LuvObject(untyped __cpp__("uv_fs_get_ptr((uv_fs_t*){0})", req.ptr), false);
			case FS_DIRENTS:
				var dir:cpp.RawPointer<cpp.Void> = untyped __cpp__("uv_fs_get_ptr((uv_fs_t*){0})", req.ptr);
				[for (i in 0...result) new FsDirent(untyped __cpp__("(int)((uv_dir_t*){0})->dirents[{1}].type", dir, i),
					LuvSys.fromC(untyped __cpp__("(void*)((uv_dir_t*){0})->dirents[{1}].name", dir, i)))];
			case FS_SCAN: req;
			case FS_STAT: statCopy(untyped __cpp__("(void*)uv_fs_get_statbuf((uv_fs_t*){0})", req.ptr));
			case FS_STATFS:
				var b = haxe.io.Bytes.alloc(untyped __cpp__("(int)sizeof(uv_statfs_t)"));
				untyped __cpp__("memcpy({0}->b->GetBase(), uv_fs_get_ptr((uv_fs_t*){1}), sizeof(uv_statfs_t))", b, req.ptr);
				b;
			case _: LuvSys.fromC(untyped __cpp__("uv_fs_get_ptr((uv_fs_t*){0})", req.ptr));
		};
		return new FsResult(0, value);
	}

	// The callback runs under catchExceptions, the immediate error included, after the request's
	// clean-up and the call's own
	public static function fsAsync(request:Null<LuvObject>, kind:Int, run:(req:LuvObject) -> Int, cleanup:Void->Void, callback:FsResult->Void):Void {
		var req = request != null ? request : newFsRequest();
		var wrapped = catchExceptions1(callback);
		setRequestCallback(req, function(_:Int) {
			var result = fsFromRequest(kind, req);
			if (kind != FS_SCAN || fsIntResult(req) < 0) fsCleanup(req);
			cleanup();
			wrapped(result);
		});
		var immediate = run(req);
		if (immediate < 0) {
			release(req);
			fsCleanup(req);
			cleanup();
			wrapped(new FsResult(immediate, null));
		}
	}

	// A request of its own, released at once, on the default loop without a callback. The call's
	// clean-up runs only after the result is read and the request cleaned up (uv_fs_req_cleanup reads a
	// readdir's entries).
	public static function fsSync(kind:Int, run:(req:LuvObject) -> Int, cleanup:Void->Void):FsResult {
		var req = newFsRequest();
		release(req);
		var immediate = run(req);
		var result = immediate < 0 ? new FsResult(immediate, null) : fsFromRequest(kind, req);
		if (kind != FS_SCAN || immediate < 0) fsCleanup(req);
		cleanup();
		return result;
	}

	@:keep static function fsLoop(l:Null<LuvObject>):cpp.RawPointer<cpp.Void>
		return l != null ? l.ptr : untyped __cpp__("(void*)uv_default_loop()");

	// The operations, each C.Blocking: l is null for a synchronous call.
	public static function fsOpen(l:Null<LuvObject>, req:LuvObject, path:haxe.io.Bytes, flags:Int, mode:Int):Int {
		var c = LuvSys.cString(path);
		var lp = fsLoop(l);
		var released = blockingEnter();
		var r:Int = untyped __cpp__("uv_fs_open((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3}, {4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, c, flags, mode, l != null);
		blockingLeave(released);
		return r;
	}

	// Close, unlink, rmdir, fsync/fdatasync
	public static function fsFileOp(l:Null<LuvObject>, req:LuvObject, op:Int, file:Int):Int {
		var lp = fsLoop(l);
		var async = l != null;
		var released = blockingEnter();
		var r:Int = switch (op) {
			case 0: untyped __cpp__("uv_fs_close((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, {3} ? hxc_luv_fs : NULL)", lp, req.ptr, file, async);
			case 1: untyped __cpp__("uv_fs_fsync((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, {3} ? hxc_luv_fs : NULL)", lp, req.ptr, file, async);
			case 2: untyped __cpp__("uv_fs_fdatasync((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, {3} ? hxc_luv_fs : NULL)", lp, req.ptr, file, async);
			case _: untyped __cpp__("uv_fs_fstat((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, {3} ? hxc_luv_fs : NULL)", lp, req.ptr, file, async);
		};
		blockingLeave(released);
		return r;
	}

	// The operations on one path: unlink, rmdir, mkdtemp, mkstemp, opendir, stat, lstat, statfs,
	// readlink, realpath, scandir (flags 0)
	public static function fsPathOp(l:Null<LuvObject>, req:LuvObject, op:Int, path:haxe.io.Bytes):Int {
		var c = LuvSys.cString(path);
		var lp = fsLoop(l);
		var async = l != null;
		var released = blockingEnter();
		var r:Int = switch (op) {
			case 0: untyped __cpp__("uv_fs_unlink((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 1: untyped __cpp__("uv_fs_rmdir((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 2: untyped __cpp__("uv_fs_mkdtemp((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 3: untyped __cpp__("uv_fs_mkstemp((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 4: untyped __cpp__("uv_fs_opendir((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 5: untyped __cpp__("uv_fs_stat((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 6: untyped __cpp__("uv_fs_lstat((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 7: untyped __cpp__("uv_fs_statfs((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 8: untyped __cpp__("uv_fs_readlink((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case 9: untyped __cpp__("uv_fs_realpath((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
			case _: untyped __cpp__("uv_fs_scandir((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), 0, {3} ? hxc_luv_fs : NULL)", lp, req.ptr, c, async);
		};
		blockingLeave(released);
		return r;
	}

	// Read or write: the iovecs live until the call's clean-up
	public static function fsReadWrite(l:Null<LuvObject>, req:LuvObject, write:Bool, file:Int, iov:cpp.RawPointer<cpp.Void>, count:Int, offset:haxe.Int64):Int {
		var lp = fsLoop(l);
		var async = l != null;
		var released = blockingEnter();
		var r:Int = write
			? untyped __cpp__("uv_fs_write((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, (const uv_buf_t*){3}, (unsigned int){4}, (int64_t){5}, {6} ? hxc_luv_fs : NULL)", lp, req.ptr, file, iov, count, offset, async)
			: untyped __cpp__("uv_fs_read((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, (const uv_buf_t*){3}, (unsigned int){4}, (int64_t){5}, {6} ? hxc_luv_fs : NULL)", lp, req.ptr, file, iov, count, offset, async);
		blockingLeave(released);
		return r;
	}

	public static function fsBufs(buffers:Array<LuvSys.LuvBuffer>):cpp.RawPointer<cpp.Void>
		return bufs(buffers);

	public static function fsFree(p:cpp.RawPointer<cpp.Void>):Void
		untyped __cpp__("free({0})", p);

	// Mkdir, chmod (the path's; fchmod the file's)
	public static function fsMkdir(l:Null<LuvObject>, req:LuvObject, path:haxe.io.Bytes, mode:Int):Int {
		var c = LuvSys.cString(path);
		var lp = fsLoop(l);
		var released = blockingEnter();
		var r:Int = untyped __cpp__("uv_fs_mkdir((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3}, {4} ? hxc_luv_fs : NULL)", lp, req.ptr, c, mode, l != null);
		blockingLeave(released);
		return r;
	}

	public static function fsChmod(l:Null<LuvObject>, req:LuvObject, path:Null<haxe.io.Bytes>, file:Int, mode:Int):Int {
		var c = path == null ? null : LuvSys.cString(path);
		var lp = fsLoop(l);
		var async = l != null;
		var released = blockingEnter();
		var r:Int = c != null
			? untyped __cpp__("uv_fs_chmod((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3}, {4} ? hxc_luv_fs : NULL)", lp, req.ptr, c, mode, async)
			: untyped __cpp__("uv_fs_fchmod((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, {3}, {4} ? hxc_luv_fs : NULL)", lp, req.ptr, file, mode, async);
		blockingLeave(released);
		return r;
	}

	// Rename, link, symlink, copyfile: two paths and flags
	public static function fsTwoPaths(l:Null<LuvObject>, req:LuvObject, op:Int, from:haxe.io.Bytes, to:haxe.io.Bytes, flags:Int):Int {
		var a = LuvSys.cString(from);
		var b = LuvSys.cString(to);
		var lp = fsLoop(l);
		var async = l != null;
		var released = blockingEnter();
		var r:Int = switch (op) {
			case 0: untyped __cpp__("uv_fs_rename((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), (const char*){3}->b->GetBase(), {4} ? hxc_luv_fs : NULL)", lp, req.ptr, a, b, async);
			case 1: untyped __cpp__("uv_fs_link((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), (const char*){3}->b->GetBase(), {4} ? hxc_luv_fs : NULL)", lp, req.ptr, a, b, async);
			case 2: untyped __cpp__("uv_fs_symlink((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), (const char*){3}->b->GetBase(), {4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, a, b, flags, async);
			case _: untyped __cpp__("uv_fs_copyfile((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), (const char*){3}->b->GetBase(), {4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, a, b, flags, async);
		};
		blockingLeave(released);
		return r;
	}

	public static function fsFtruncate(l:Null<LuvObject>, req:LuvObject, file:Int, length:haxe.Int64):Int {
		var lp = fsLoop(l);
		var released = blockingEnter();
		var r:Int = untyped __cpp__("uv_fs_ftruncate((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, (int64_t){3}, {4} ? hxc_luv_fs : NULL)", lp, req.ptr, file, length, l != null);
		blockingLeave(released);
		return r;
	}

	// sendfile: to, from, offset, length
	public static function fsSendfile(l:Null<LuvObject>, req:LuvObject, to:Int, from:Int, offset:haxe.Int64, length:haxe.Int64):Int {
		var lp = fsLoop(l);
		var released = blockingEnter();
		var r:Int = untyped __cpp__("uv_fs_sendfile((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, (uv_file){3}, (int64_t){4}, (size_t)(uint64_t){5}, {6} ? hxc_luv_fs : NULL)", lp, req.ptr, to, from, offset, length, l != null);
		blockingLeave(released);
		return r;
	}

	public static function fsAccess(l:Null<LuvObject>, req:LuvObject, path:haxe.io.Bytes, mode:Int):Int {
		var c = LuvSys.cString(path);
		var lp = fsLoop(l);
		var released = blockingEnter();
		var r:Int = untyped __cpp__("uv_fs_access((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3}, {4} ? hxc_luv_fs : NULL)", lp, req.ptr, c, mode, l != null);
		blockingLeave(released);
		return r;
	}

	// Utime, futime, lutime: op 0 the path's, 1 the file's, 2 the link's
	public static function fsUtime(l:Null<LuvObject>, req:LuvObject, op:Int, path:Null<haxe.io.Bytes>, file:Int, atime:Float, mtime:Float):Int {
		var c = path == null ? null : LuvSys.cString(path);
		var lp = fsLoop(l);
		var async = l != null;
		var released = blockingEnter();
		var r:Int = switch (op) {
			case 0: untyped __cpp__("uv_fs_utime((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3}, {4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, c, atime, mtime, async);
			case 1: untyped __cpp__("uv_fs_futime((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, {3}, {4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, file, atime, mtime, async);
			case _: untyped __cpp__("uv_fs_lutime((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), {3}, {4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, c, atime, mtime, async);
		};
		blockingLeave(released);
		return r;
	}

	// Chown, fchown, lchown
	public static function fsChown(l:Null<LuvObject>, req:LuvObject, op:Int, path:Null<haxe.io.Bytes>, file:Int, uid:Int, gid:Int):Int {
		var c = path == null ? null : LuvSys.cString(path);
		var lp = fsLoop(l);
		var async = l != null;
		var released = blockingEnter();
		var r:Int = switch (op) {
			case 0: untyped __cpp__("uv_fs_chown((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), (uv_uid_t){3}, (uv_gid_t){4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, c, uid, gid, async);
			case 1: untyped __cpp__("uv_fs_fchown((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_file){2}, (uv_uid_t){3}, (uv_gid_t){4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, file, uid, gid, async);
			case _: untyped __cpp__("uv_fs_lchown((uv_loop_t*){0}, (uv_fs_t*){1}, (const char*){2}->b->GetBase(), (uv_uid_t){3}, (uv_gid_t){4}, {5} ? hxc_luv_fs : NULL)", lp, req.ptr, c, uid, gid, async);
		};
		blockingLeave(released);
		return r;
	}

	public static function fsClosedir(l:Null<LuvObject>, req:LuvObject, dir:LuvObject):Int {
		var lp = fsLoop(l);
		var released = blockingEnter();
		var r:Int = untyped __cpp__("uv_fs_closedir((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_dir_t*){2}, {3} ? hxc_luv_fs : NULL)", lp, req.ptr, dir.ptr, l != null);
		blockingLeave(released);
		return r;
	}

	// The entries array the call fills, which the caller frees
	public static function fsDirents(dir:LuvObject, count:Int):cpp.RawPointer<cpp.Void> {
		var a:cpp.RawPointer<cpp.Void> = untyped __cpp__("calloc((size_t)({0} > 0 ? {0} : 1), sizeof(uv_dirent_t))", count);
		untyped __cpp__("((uv_dir_t*){0})->dirents = (uv_dirent_t*){1}; ((uv_dir_t*){0})->nentries = (size_t){2}", dir.ptr, a, count);
		return a;
	}

	public static function fsReaddir(l:Null<LuvObject>, req:LuvObject, dir:LuvObject):Int {
		var lp = fsLoop(l);
		var released = blockingEnter();
		var r:Int = untyped __cpp__("uv_fs_readdir((uv_loop_t*){0}, (uv_fs_t*){1}, (uv_dir_t*){2}, {3} ? hxc_luv_fs : NULL)", lp, req.ptr, dir.ptr, l != null);
		blockingLeave(released);
		return r;
	}

	// The next directory entry: none at the end, which also stops the scan
	public static function scandirNext(req:LuvObject):Null<FsDirent> {
		var kind = 0;
		var name:cpp.RawPointer<cpp.Void> = null;
		var released = blockingEnter();
		var r = 0;
		untyped __cpp__("{ uv_dirent_t hxc_d; memset(&hxc_d, 0, sizeof(hxc_d)); {0} = uv_fs_scandir_next((uv_fs_t*){1}, &hxc_d); {2} = (int)hxc_d.type; {3} = (void*)hxc_d.name; }",
			r, req.ptr, kind, name);
		blockingLeave(released);
		if (r < 0) {
			fsCleanup(req);
			return null;
		}
		return new FsDirent(kind, LuvSys.fromC(name));
	}

	public static function scandirEnd(req:LuvObject):Void
		fsCleanup(req);

	// A copy of the uv_stat_t
	static function statCopy(p:cpp.RawPointer<cpp.Void>):haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(untyped __cpp__("(int)sizeof(uv_stat_t)"));
		untyped __cpp__("memcpy({0}->b->GetBase(), {1}, sizeof(uv_stat_t))", b, p);
		return b;
	}

	// 0 dev, 1 mode, 2 nlink, 3 uid, 4 gid, 5 rdev, 6 ino, 7 size, 8 blksize, 9 blocks, 10 flags, 11 gen
	public static function statField(s:haxe.io.Bytes, i:Int):haxe.Int64 {
		return switch (i) {
			case 0: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_dev", s);
			case 1: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_mode", s);
			case 2: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_nlink", s);
			case 3: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_uid", s);
			case 4: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_gid", s);
			case 5: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_rdev", s);
			case 6: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_ino", s);
			case 7: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_size", s);
			case 8: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_blksize", s);
			case 9: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_blocks", s);
			case 10: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_flags", s);
			case _: untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_gen", s);
		};
	}

	// The four timespecs, atim mtim ctim birthtim, each a C long pair
	public static function statTime(s:haxe.io.Bytes, which:Int, nsec:Bool):haxe.Int64 {
		return switch (which) {
			case 0: nsec ? untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_atim.tv_nsec", s) : untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_atim.tv_sec", s);
			case 1: nsec ? untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_mtim.tv_nsec", s) : untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_mtim.tv_sec", s);
			case 2: nsec ? untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_ctim.tv_nsec", s) : untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_ctim.tv_sec", s);
			case _: nsec ? untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_birthtim.tv_nsec", s) : untyped __cpp__("(::cpp::Int64)((uv_stat_t*){0}->b->GetBase())->st_birthtim.tv_sec", s);
		};
	}

	// 0 type, 1 bsize, 2 blocks, 3 bfree, 4 bavail, 5 files, 6 ffree, 7-10 f_spare
	public static function statfsField(s:haxe.io.Bytes, i:Int):haxe.Int64 {
		return switch (i) {
			case 0: untyped __cpp__("(::cpp::Int64)((uv_statfs_t*){0}->b->GetBase())->f_type", s);
			case 1: untyped __cpp__("(::cpp::Int64)((uv_statfs_t*){0}->b->GetBase())->f_bsize", s);
			case 2: untyped __cpp__("(::cpp::Int64)((uv_statfs_t*){0}->b->GetBase())->f_blocks", s);
			case 3: untyped __cpp__("(::cpp::Int64)((uv_statfs_t*){0}->b->GetBase())->f_bfree", s);
			case 4: untyped __cpp__("(::cpp::Int64)((uv_statfs_t*){0}->b->GetBase())->f_bavail", s);
			case 5: untyped __cpp__("(::cpp::Int64)((uv_statfs_t*){0}->b->GetBase())->f_files", s);
			case 6: untyped __cpp__("(::cpp::Int64)((uv_statfs_t*){0}->b->GetBase())->f_ffree", s);
			case _: untyped __cpp__("(::cpp::Int64)((uv_statfs_t*){0}->b->GetBase())->f_spare[{1} - 7]", s, i);
		};
	}

	// File modes. On Windows they are the POSIX values a mingw-w64 sys/stat.h gives, S_IFLNK is
	// libuv's uv/win.h value, and the set-id and sticky bits are 0
	public static function fileMode(index:Int):Int {
		return switch (index) {
			case 0: untyped __cpp__("HXC_S_IRWXU");
			case 1: untyped __cpp__("HXC_S_IRUSR");
			case 2: untyped __cpp__("HXC_S_IWUSR");
			case 3: untyped __cpp__("HXC_S_IXUSR");
			case 4: untyped __cpp__("HXC_S_IRWXG");
			case 5: untyped __cpp__("HXC_S_IRGRP");
			case 6: untyped __cpp__("HXC_S_IWGRP");
			case 7: untyped __cpp__("HXC_S_IXGRP");
			case 8: untyped __cpp__("HXC_S_IRWXO");
			case 9: untyped __cpp__("HXC_S_IROTH");
			case 10: untyped __cpp__("HXC_S_IWOTH");
			case 11: untyped __cpp__("HXC_S_IXOTH");
			case 12: untyped __cpp__("HXC_S_ISUID");
			case 13: untyped __cpp__("HXC_S_ISGID");
			case 14: untyped __cpp__("HXC_S_ISVTX");
			case 15: untyped __cpp__("HXC_S_IFMT");
			case 16: untyped __cpp__("HXC_S_IFREG");
			case 17: untyped __cpp__("HXC_S_IFDIR");
			case 18: untyped __cpp__("HXC_S_IFBLK");
			case 19: untyped __cpp__("HXC_S_IFCHR");
			case 20: untyped __cpp__("HXC_S_IFLNK");
			case _: untyped __cpp__("HXC_S_IFIFO");
		};
	}

	// Open flags, in eval's index order
	public static function openFlag(index:Int):Int {
		return switch (index) {
			case 0: untyped __cpp__("UV_FS_O_RDONLY");
			case 1: untyped __cpp__("UV_FS_O_WRONLY");
			case 2: untyped __cpp__("UV_FS_O_RDWR");
			case 3: untyped __cpp__("UV_FS_O_CREAT");
			case 4: untyped __cpp__("UV_FS_O_EXCL");
			case 5: untyped __cpp__("UV_FS_O_EXLOCK");
			case 6: untyped __cpp__("UV_FS_O_NOCTTY");
			case 7: untyped __cpp__("UV_FS_O_NOFOLLOW");
			case 8: untyped __cpp__("UV_FS_O_TEMPORARY");
			case 9: untyped __cpp__("UV_FS_O_TRUNC");
			case 10: untyped __cpp__("UV_FS_O_APPEND");
			case 11: untyped __cpp__("UV_FS_O_DIRECT");
			case 12: untyped __cpp__("UV_FS_O_DSYNC");
			case 13: untyped __cpp__("UV_FS_O_FILEMAP");
			case 14: untyped __cpp__("UV_FS_O_NOATIME");
			case 15: untyped __cpp__("UV_FS_O_NONBLOCK");
			case 16: untyped __cpp__("UV_FS_O_RANDOM");
			case 17: untyped __cpp__("UV_FS_O_SEQUENTIAL");
			case 18: untyped __cpp__("UV_FS_O_SHORT_LIVED");
			case 19: untyped __cpp__("UV_FS_O_SYMLINK");
			case _: untyped __cpp__("UV_FS_O_SYNC");
		};
	}

	// Access flags: F_OK R_OK W_OK X_OK
	public static function accessFlag(index:Int):Int {
		return switch (index) {
			case 0: untyped __cpp__("F_OK");
			case 1: untyped __cpp__("R_OK");
			case 2: untyped __cpp__("W_OK");
			case _: untyped __cpp__("X_OK");
		};
	}

	// Copy flags and symlink flags
	public static function copyFlags(excl:Bool, ficlone:Bool, force:Bool):Int {
		var f = 0;
		if (excl) f |= (untyped __cpp__("UV_FS_COPYFILE_EXCL") : Int);
		if (ficlone) f |= (untyped __cpp__("UV_FS_COPYFILE_FICLONE") : Int);
		if (force) f |= (untyped __cpp__("UV_FS_COPYFILE_FICLONE_FORCE") : Int);
		return f;
	}

	public static function symlinkFlags(dir:Bool, junction:Bool):Int {
		var f = 0;
		if (dir) f |= (untyped __cpp__("UV_FS_SYMLINK_DIR") : Int);
		if (junction) f |= (untyped __cpp__("UV_FS_SYMLINK_JUNCTION") : Int);
		return f;
	}


	public static function fsPollInit(l:LuvObject, p:LuvObject):Int
		return untyped __cpp__("uv_fs_poll_init((uv_loop_t*){0}, (uv_fs_poll_t*){1})", l.ptr, p.ptr);

	// Every call of the callback goes to the exception handler on failure, the immediate error's too
	public static function fsPollStart(p:LuvObject, path:haxe.io.Bytes, interval:Int, callback:Int->Null<haxe.io.Bytes>->Null<haxe.io.Bytes>->Void):Void {
		var wrapped = function(status:Int, prev:Null<haxe.io.Bytes>, curr:Null<haxe.io.Bytes>) {
			try callback(status, prev, curr) catch (e:Dynamic) exceptionHandler(e);
		};
		p.refs[0] = wrapped;
		var c = LuvSys.cString(path);
		var immediate:Int = untyped __cpp__("uv_fs_poll_start((uv_fs_poll_t*){0}, hxc_luv_fs_poll, (const char*){1}->b->GetBase(), (unsigned int){2})", p.ptr, c, interval);
		if (immediate < 0) wrapped(immediate, null, null);
	}

	public static function fsPollStop(p:LuvObject):Int
		return untyped __cpp__("uv_fs_poll_stop((uv_fs_poll_t*){0})", p.ptr);

	@:keep public static function dispatchFsPoll(id:Int, status:Int, prev:cpp.RawPointer<cpp.Void>, curr:cpp.RawPointer<cpp.Void>):Void {
		var s = runStack();
		var reacquire = s.length > 0 && s[s.length - 1];
		if (reacquire) EvalStdLib.gilReacquire();
		retainedLock.acquire();
		var o = retained.get(id);
		retainedLock.release();
		var f:Dynamic = o == null ? null : o.refs[0];
		if (f != null) {
			if (status >= 0) f(status, statCopy(prev), statCopy(curr)) else f(status, null, null);
		}
		if (reacquire) EvalStdLib.gilRelease();
	}


	public static function ttyInit(l:LuvObject, t:LuvObject, file:Int):Int
		return untyped __cpp__("uv_tty_init((uv_loop_t*){0}, (uv_tty_t*){1}, (uv_file){2}, 0)", l.ptr, t.ptr, file);

	// 0 UV_TTY_MODE_NORMAL, 1 raw, 2 IO
	public static function ttySetMode(t:LuvObject, mode:Int):Int {
		return untyped __cpp__("uv_tty_set_mode((uv_tty_t*){0}, {1} == 0 ? UV_TTY_MODE_NORMAL : {1} == 1 ? UV_TTY_MODE_RAW : UV_TTY_MODE_IO)", t.ptr, mode);
	}

	public static function ttyResetMode():Int
		return untyped __cpp__("uv_tty_reset_mode()");

	public static function ttyWinSize(t:LuvObject, out:Array<Int>):Int {
		var r = 0;
		var w = 0;
		var h = 0;
		untyped __cpp__("{ int hxc_w = 0, hxc_h = 0; {0} = uv_tty_get_winsize((uv_tty_t*){1}, &hxc_w, &hxc_h); {2} = hxc_w; {3} = hxc_h; }", r, t.ptr, w, h);
		out[0] = w;
		out[1] = h;
		return r;
	}

	// 0 UV_TTY_SUPPORTED, 1 UV_TTY_UNSUPPORTED
	public static function ttySetVtermState(supported:Bool):Void
		untyped __cpp__("uv_tty_set_vterm_state({0} ? UV_TTY_SUPPORTED : UV_TTY_UNSUPPORTED)", supported);

	public static function ttyGetVtermState(out:Array<Int>):Int {
		var r = 0;
		var s = 0;
		untyped __cpp__("{ uv_tty_vtermstate_t hxc_s = UV_TTY_UNSUPPORTED; {0} = uv_tty_get_vterm_state(&hxc_s); {1} = hxc_s == UV_TTY_SUPPORTED ? 0 : 1; }", r, s);
		out[0] = s;
		return r;
	}


	public static function requestCancel(r:LuvObject):Int
		return untyped __cpp__("uv_cancel((uv_req_t*){0})", r.ptr);


	public static function newRandomRequest():LuvObject
		return newRequest(untyped __cpp__("(int)sizeof(uv_random_t)"));

	// The buffer lives until the callback; an immediate error goes to the callback as it is
	public static function randomAsync(l:LuvObject, request:Null<LuvObject>, b:LuvSys.LuvBuffer, callback:Int->Void):Void {
		var r = request != null ? request : newRandomRequest();
		r.refs[1] = b;
		setRequestCallback(r, catchExceptions1(callback));
		var base = b.bytes;
		var immediate:Int = untyped __cpp__("uv_random((uv_loop_t*){0}, (uv_random_t*){1}, (char*){2}->b->GetBase() + {3}, (size_t){4}, 0, hxc_luv_random)",
			l.ptr, r.ptr, base, b.offset, b.length);
		if (immediate < 0) {
			release(r);
			callback(immediate);
		}
	}


	public static function newAddrRequest():LuvObject
		return newRequest(untyped __cpp__("(int)sizeof(uv_getaddrinfo_t)"));

	public static function newNameRequest():LuvObject
		return newRequest(untyped __cpp__("(int)sizeof(uv_getnameinfo_t)"));

	// Address-info flags, in eval's index order
	public static function addrInfoFlag(index:Int):Int {
		return switch (index) {
			case 0: untyped __cpp__("AI_PASSIVE");
			case 1: untyped __cpp__("AI_CANONNAME");
			case 2: untyped __cpp__("AI_NUMERICHOST");
			case 3: untyped __cpp__("AI_NUMERICSERV");
			case 4: untyped __cpp__("AI_V4MAPPED");
			case 5: untyped __cpp__("AI_ALL");
			case _: untyped __cpp__("AI_ADDRCONFIG");
		};
	}

	// Name-info flags
	public static function nameInfoFlag(index:Int):Int {
		return switch (index) {
			case 0: untyped __cpp__("NI_NAMEREQD");
			case 1: untyped __cpp__("NI_DGRAM");
			case 2: untyped __cpp__("NI_NOFQDN");
			case 3: untyped __cpp__("NI_NUMERICHOST");
			case _: untyped __cpp__("NI_NUMERICSERV");
		};
	}

	// Socket types, to C
	public static function socketTypeToC(index:Int):Int {
		return switch (index) {
			case 0: untyped __cpp__("SOCK_STREAM");
			case 1: untyped __cpp__("SOCK_DGRAM");
			case _: untyped __cpp__("SOCK_RAW");
		};
	}

	// Hints only when any of family, socktype, protocol or flags is given (family defaulting to
	// UNSPEC); the list is read and freed on success, and the callback runs under catchExceptions, the
	// immediate error's included
	public static function getaddrinfo(l:LuvObject, request:Null<LuvObject>, hints:Null<Array<Int>>, node:Null<haxe.io.Bytes>,
			service:Null<haxe.io.Bytes>, callback:Int->Null<Array<AddrInfo>>->Void):Void {
		var r = request != null ? request : newAddrRequest();
		var h:cpp.RawPointer<cpp.Void> = null;
		if (hints != null) {
			h = untyped __cpp__("calloc(1, sizeof(struct addrinfo))");
			untyped __cpp__("((struct addrinfo*){0})->ai_family = {1}; ((struct addrinfo*){0})->ai_socktype = {2}; ((struct addrinfo*){0})->ai_protocol = {3}; ((struct addrinfo*){0})->ai_flags = {4}",
				h, hints[0], hints[1], hints[2], hints[3]);
		}
		var wrapped = catchExceptions2(callback);
		setRequestCallback(r, function(status:Int) {
			if (status < 0) {
				wrapped(status, null);
				return;
			}
			var list = [];
			var ai:cpp.RawPointer<cpp.Void> = untyped __cpp__("(void*)((uv_getaddrinfo_t*){0})->addrinfo", r.ptr);
			while (ai != null) {
				var storage = LuvSys.newSockaddr();
				untyped __cpp__("memcpy({0}->b->GetBase(), ((struct addrinfo*){1})->ai_addr, ((struct addrinfo*){1})->ai_addrlen)", storage, ai);
				var canon:cpp.RawPointer<cpp.Void> = untyped __cpp__("(void*)((struct addrinfo*){0})->ai_canonname", ai);
				list.push(new AddrInfo(untyped __cpp__("((struct addrinfo*){0})->ai_family", ai), untyped __cpp__("((struct addrinfo*){0})->ai_socktype", ai),
					untyped __cpp__("((struct addrinfo*){0})->ai_protocol", ai), storage, LuvSys.fromC(canon)));
				ai = untyped __cpp__("(void*)((struct addrinfo*){0})->ai_next", ai);
			}
			untyped __cpp__("uv_freeaddrinfo(((uv_getaddrinfo_t*){0})->addrinfo)", r.ptr);
			wrapped(0, list);
		});
		var n = node == null ? null : LuvSys.cString(node);
		var s = service == null ? null : LuvSys.cString(service);
		var np:cpp.RawPointer<cpp.Void> = n == null ? null : untyped __cpp__("(void*){0}->b->GetBase()", n);
		var sp:cpp.RawPointer<cpp.Void> = s == null ? null : untyped __cpp__("(void*){0}->b->GetBase()", s);
		var immediate:Int = untyped __cpp__("uv_getaddrinfo((uv_loop_t*){0}, (uv_getaddrinfo_t*){1}, hxc_luv_getaddrinfo, (const char*){2}, (const char*){3}, (const struct addrinfo*){4})",
			l.ptr, r.ptr, np, sp, h);
		if (h != null) untyped __cpp__("free({0})", h);
		if (immediate < 0) {
			release(r);
			wrapped(immediate, null);
		}
	}

	// Address families, from C: 0 UNSPEC, 1 INET, 2 INET6, 3 another (with its number)
	public static function addressFamilyFromC(af:Int):Int {
		return af == (untyped __cpp__("AF_UNSPEC") : Int) ? 0 : af == (untyped __cpp__("AF_INET") : Int) ? 1 : af == (untyped __cpp__("AF_INET6") : Int) ? 2 : 3;
	}

	// Socket types, from C: 0 STREAM, 1 DGRAM, 2 raw, 3 another
	public static function socketTypeFromC(st:Int):Int {
		return st == (untyped __cpp__("SOCK_STREAM") : Int) ? 0 : st == (untyped __cpp__("SOCK_DGRAM") : Int) ? 1 : st == (untyped __cpp__("SOCK_RAW") : Int) ? 2 : 3;
	}

	// The host and the service up to their NULs
	public static function getnameinfo(l:LuvObject, request:Null<LuvObject>, addr:haxe.io.Bytes, flags:Int, callback:Int->Null<haxe.io.Bytes>->Null<haxe.io.Bytes>->Void):Void {
		var r = request != null ? request : newNameRequest();
		var wrapped = function(status:Int, host:Null<haxe.io.Bytes>, service:Null<haxe.io.Bytes>) {
			try callback(status, host, service) catch (e:Dynamic) exceptionHandler(e);
		};
		setRequestCallback(r, function(status:Int) {
			if (status < 0) wrapped(status, null, null);
			else wrapped(0, LuvSys.fromC(untyped __cpp__("(void*)((uv_getnameinfo_t*){0})->host", r.ptr)),
				LuvSys.fromC(untyped __cpp__("(void*)((uv_getnameinfo_t*){0})->service", r.ptr)));
		});
		var immediate:Int = untyped __cpp__("uv_getnameinfo((uv_loop_t*){0}, (uv_getnameinfo_t*){1}, hxc_luv_getnameinfo, (const struct sockaddr*){2}->b->GetBase(), {3})",
			l.ptr, r.ptr, addr, flags);
		if (immediate < 0) {
			release(r);
			wrapped(immediate, null, null);
		}
	}


	// Redirections: a pipe to the parent, an inherited fd, an inherited stream
	public static function redirectPipe(fd:Int, pipe:LuvObject, readable:Bool, writable:Bool, overlapped:Bool):Redirection {
		var flags:Int = untyped __cpp__("UV_CREATE_PIPE");
		if (readable) flags |= (untyped __cpp__("UV_READABLE_PIPE") : Int);
		if (writable) flags |= (untyped __cpp__("UV_WRITABLE_PIPE") : Int);
		if (overlapped) flags |= (untyped __cpp__("UV_OVERLAPPED_PIPE") : Int);
		return new Redirection(fd, flags, pipe, 0);
	}

	public static function redirectFd(fd:Int, fromParent:Int):Redirection
		return new Redirection(fd, untyped __cpp__("UV_INHERIT_FD"), null, fromParent);

	public static function redirectStream(fd:Int, stream:LuvObject):Redirection
		return new Redirection(fd, untyped __cpp__("UV_INHERIT_STREAM"), stream, 0);

	// EINVAL before anything when a variable's name holds '='; the stdio array is as long as the
	// largest redirected fd, at least 3, each slot the first redirection for it or UV_IGNORE; a failed
	// spawn closes the handle
	public static function spawn(l:LuvObject, p:LuvObject, onExit:Null<haxe.Int64->Int->Void>, path:haxe.io.Bytes, args:Array<haxe.io.Bytes>,
			env:Null<Array<{name:haxe.io.Bytes, value:haxe.io.Bytes}>>, cwd:Null<haxe.io.Bytes>, uid:Null<Int>, gid:Null<Int>,
			flagSet:Array<Bool>, redirect:Array<Redirection>):Int {
		if (onExit != null) p.refs[0] = function(status:haxe.Int64, signal:Int) {
			try onExit(status, signal) catch (e:Dynamic) exceptionHandler(e);
		};
		if (env != null) for (e in env) for (i in 0...e.name.length) if (e.name.get(i) == "=".code) return untyped __cpp__("UV_EINVAL");
		var flags = 0;
		if (uid != null) flags |= (untyped __cpp__("UV_PROCESS_SETUID") : Int);
		if (gid != null) flags |= (untyped __cpp__("UV_PROCESS_SETGID") : Int);
		var named:Array<Int> = [untyped __cpp__("UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS"), untyped __cpp__("UV_PROCESS_DETACHED"),
			untyped __cpp__("UV_PROCESS_WINDOWS_HIDE"), untyped __cpp__("UV_PROCESS_WINDOWS_HIDE_CONSOLE"), untyped __cpp__("UV_PROCESS_WINDOWS_HIDE_GUI")];
		for (i in 0...5) if (flagSet[i]) flags |= named[i];
		var count = 3;
		for (r in redirect) if (r.fd > count) count = r.fd;
		var stdio:cpp.RawPointer<cpp.Void> = untyped __cpp__("calloc((size_t){0}, sizeof(uv_stdio_container_t))", count);
		for (i in 0...count) {
			var found:Null<Redirection> = null;
			for (r in redirect) if (r.fd == i) { found = r; break; }
			if (found == null) untyped __cpp__("((uv_stdio_container_t*){0})[{1}].flags = UV_IGNORE", stdio, i);
			else if (found.stream != null)
				untyped __cpp__("((uv_stdio_container_t*){0})[{1}].flags = (uv_stdio_flags){2}; ((uv_stdio_container_t*){0})[{1}].data.stream = (uv_stream_t*){3}", stdio, i, found.flags, found.stream.ptr);
			else
				untyped __cpp__("((uv_stdio_container_t*){0})[{1}].flags = (uv_stdio_flags){2}; ((uv_stdio_container_t*){0})[{1}].data.fd = {3}", stdio, i, found.flags, found.parentFd);
		}
		var cArgs = [for (a in args) LuvSys.cString(a)];
		var argv:cpp.RawPointer<cpp.Void> = untyped __cpp__("calloc((size_t){0} + 1, sizeof(char*))", cArgs.length);
		for (i in 0...cArgs.length) untyped __cpp__("((char**){0})[{1}] = (char*){2}->b->GetBase()", argv, i, cArgs[i]);
		var cEnv = env == null ? null : [for (e in env) {
			var b = haxe.io.Bytes.alloc(e.name.length + 1 + e.value.length);
			b.blit(0, e.name, 0, e.name.length);
			b.set(e.name.length, "=".code);
			b.blit(e.name.length + 1, e.value, 0, e.value.length);
			LuvSys.cString(b);
		}];
		var envp:cpp.RawPointer<cpp.Void> = null;
		if (cEnv != null) {
			envp = untyped __cpp__("calloc((size_t){0} + 1, sizeof(char*))", cEnv.length);
			for (i in 0...cEnv.length) untyped __cpp__("((char**){0})[{1}] = (char*){2}->b->GetBase()", envp, i, cEnv[i]);
		}
		var cPath = LuvSys.cString(path);
		var cCwd = cwd == null ? null : LuvSys.cString(cwd);
		var cwdp:cpp.RawPointer<cpp.Void> = cCwd == null ? null : untyped __cpp__("(void*){0}->b->GetBase()", cCwd);
		var u:Int = uid == null ? 0 : uid;
		var g:Int = gid == null ? 0 : gid;
		var hasExit = onExit != null;
		var released = blockingEnter();
		var result = 0;
		untyped __cpp__("{ uv_process_options_t hxc_o; memset(&hxc_o, 0, sizeof(hxc_o)); hxc_o.exit_cb = {0} ? hxc_luv_exit : NULL; hxc_o.file = (const char*){1}->b->GetBase(); hxc_o.args = (char**){2}; hxc_o.env = (char**){3}; hxc_o.cwd = (const char*){4}; hxc_o.flags = (unsigned int){5}; hxc_o.stdio_count = {6}; hxc_o.stdio = (uv_stdio_container_t*){7}; hxc_o.uid = (uv_uid_t){8}; hxc_o.gid = (uv_gid_t){9}; {10} = uv_spawn((uv_loop_t*){11}, (uv_process_t*){12}, &hxc_o); }",
			hasExit, cPath, argv, envp, cwdp, flags, count, stdio, u, g, result, l.ptr, p.ptr);
		blockingLeave(released);
		untyped __cpp__("free({0}); free({1}); free({2})", stdio, argv, envp);
		if (result < 0) close(p, () -> {});
		return result;
	}

	@:keep public static function dispatchExit(id:Int, status:haxe.Int64, signal:Int):Void {
		var s = runStack();
		var reacquire = s.length > 0 && s[s.length - 1];
		if (reacquire) EvalStdLib.gilReacquire();
		retainedLock.acquire();
		var o = retained.get(id);
		retainedLock.release();
		var f:Dynamic = o == null ? null : o.refs[0];
		if (f != null) f(status, signal);
		if (reacquire) EvalStdLib.gilRelease();
	}

	public static function disableStdioInheritance():Void
		untyped __cpp__("uv_disable_stdio_inheritance()");

	public static function killPid(pid:Int, signal:Int):Int
		return untyped __cpp__("uv_kill({0}, {1})", pid, signal);

	public static function processPid(p:LuvObject):Int
		return untyped __cpp__("(int)uv_process_get_pid((const uv_process_t*){0})", p.ptr);


	public static function newWorkRequest():LuvObject
		return newRequest(untyped __cpp__("(int)sizeof(uv_work_t)"));

	// The work runs under catchExceptions on a pool thread, the callback under it on the loop's; an
	// immediate error goes to the callback as it is
	public static function queueWork(l:LuvObject, request:Null<LuvObject>, work:Void->Void, callback:Int->Void):Void {
		var r = request != null ? request : newWorkRequest();
		r.refs[1] = catchExceptions(work);
		setRequestCallback(r, catchExceptions1(callback));
		var immediate:Int = untyped __cpp__("uv_queue_work((uv_loop_t*){0}, (uv_work_t*){1}, hxc_luv_work, hxc_luv_after_work)", l.ptr, r.ptr);
		if (immediate < 0) {
			release(r);
			callback(immediate);
		}
	}

	// The work trampoline, from a thread the runtime registers for the call
	@:keep public static function dispatchWork(id:Int):Void {
		// The thread registers itself: it takes the next ident (and starts the tick if nothing has).
		hxc.compiler.HostRuntime.threadStarted(hxc.compiler.HostRuntime.threadCreated());
		EvalStdLib.gilEnter();
		retainedLock.acquire();
		var o = retained.get(id);
		retainedLock.release();
		var f:Dynamic = o == null ? null : o.refs[1];
		// The exception handler's exit ends the process from any thread
		var exited = false;
		try if (f != null) f() catch (e:EvalExceptions.EvalSysExit) hxc.compiler.HostRuntime.exit(e.code) catch (e:EvalExceptions.EvalThreadExit) exited = true;
		EvalStdLib.gilLeave();
		hxc.compiler.HostRuntime.threadEnded();
		// Thread.exit ends the pool's thread itself, and libuv never hears back: the work's after-work
		// callback does not run.
		if (exited) hxc.compiler.HostRuntime.cThreadExit();
	}


	// A copy of the running thread's uv_thread_t
	public static function threadSelf():LuvObject {
		var t = own(untyped __cpp__("malloc(sizeof(uv_thread_t))"));
		untyped __cpp__("*(uv_thread_t*){0} = uv_thread_self()", t.ptr);
		return t;
	}

	// The function under catchExceptions, rooted until the new thread takes it
	public static function threadCreate(stackSize:Null<Int>, f:Void->Void, out:Array<LuvObject>):Int {
		var t = own(untyped __cpp__("malloc(sizeof(uv_thread_t))"));
		var root = new LuvObject(null, false);
		root.refs[0] = catchExceptions(f);
		retainedLock.acquire();
		root.id = nextId++;
		retained.set(root.id, root);
		retainedLock.release();
		var hasSize = stackSize != null;
		var size:Int = hasSize ? stackSize : 0;
		var r = 0;
		untyped __cpp__("{ uv_thread_options_t hxc_o; hxc_o.flags = {0} ? UV_THREAD_HAS_STACK_SIZE : UV_THREAD_NO_FLAGS; hxc_o.stack_size = (size_t){1}; {2} = uv_thread_create_ex((uv_thread_t*){3}, &hxc_o, hxc_luv_thread, (void*)(intptr_t){4}); }",
			hasSize, size, r, t.ptr, root.id);
		if (r < 0) release(root);
		out[0] = t;
		return r;
	}

	// The thread trampoline: the root is released before the function runs
	@:keep public static function dispatchThread(id:Int):Void {
		// The thread registers itself: it takes the next ident (and starts the tick if nothing has).
		hxc.compiler.HostRuntime.threadStarted(hxc.compiler.HostRuntime.threadCreated());
		EvalStdLib.gilEnter();
		retainedLock.acquire();
		var o = retained.get(id);
		retained.remove(id);
		retainedLock.release();
		var f:Dynamic = o == null ? null : o.refs[0];
		var exited = false;
		try if (f != null) f() catch (e:EvalExceptions.EvalSysExit) hxc.compiler.HostRuntime.exit(e.code) catch (e:EvalExceptions.EvalThreadExit) exited = true;
		EvalStdLib.gilLeave();
		hxc.compiler.HostRuntime.threadEnded();
		if (exited) hxc.compiler.HostRuntime.cThreadExit();
	}

	// A blocking call
	public static function threadJoin(t:LuvObject):Int {
		var released = blockingEnter();
		var r:Int = untyped __cpp__("uv_thread_join((uv_thread_t*){0})", t.ptr);
		blockingLeave(released);
		return r;
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
	An addrinfo entry: the family, socket type and protocol as C gives them, a copy of the
	address and the canonical name if any.
**/
class AddrInfo {
	public final family:Int;
	public final socktype:Int;
	public final protocol:Int;
	public final addr:haxe.io.Bytes;
	public final canonname:Null<haxe.io.Bytes>;

	public function new(family:Int, socktype:Int, protocol:Int, addr:haxe.io.Bytes, canonname:Null<haxe.io.Bytes>) {
		this.family = family;
		this.socktype = socktype;
		this.protocol = protocol;
		this.addr = addr;
		this.canonname = canonname;
	}
}

/**
 * A redirection: the child's fd and a uv_stdio_container_t's flags and stream or fd.
 */
class Redirection {
	public final fd:Int;
	public final flags:Int;
	public final stream:Null<LuvObject>;
	public final parentFd:Int;

	public function new(fd:Int, flags:Int, stream:Null<LuvObject>, parentFd:Int) {
		this.fd = fd;
		this.flags = flags;
		this.stream = stream;
		this.parentFd = parentFd;
	}
}

/**
 * A file operation's result: a result code and, on success, what the request answered.
 */
class FsResult {
	public final code:Int;
	public final value:Dynamic;

	public function new(code:Int, value:Dynamic) {
		this.code = code;
		this.value = value;
	}
}

/**
 * Mkstemp's answer: the path and the file.
 */
class FsPathFile {
	public final path:haxe.io.Bytes;
	public final file:Int;

	public function new(path:haxe.io.Bytes, file:Int) {
		this.path = path;
		this.file = file;
	}
}

/**
 * A directory entry: the uv_dirent_type_t and the name.
 */
class FsDirent {
	public final kind:Int;
	public final name:haxe.io.Bytes;

	public function new(kind:Int, name:haxe.io.Bytes) {
		this.kind = kind;
		this.name = name;
	}
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
