package hxc.eval;

#if (cpp && !emscripten)
import haxe.io.Bytes;
import hxc.eval.Luv.LuvObject;

/**
 * Libuv's system functions (hxc.eval.Luv carries the build): environment, time, paths, network,
 * socket addresses, resources, system info, pid, passwd and metrics. A string goes to C as its
 * bytes before the first NUL, and a result read out of a buffer is cut at its first NUL (an error
 * when there is none). Each call answers libuv's own result; what it produced goes into `out`.
 */
@:cppFileCode('
#include <uv.h>
#include <string.h>
#include <stdlib.h>
')
class LuvSys {
	// C reads up to the first NUL
	static function cString(b:Bytes):Bytes {
		var n = 0;
		while (n < b.length && b.get(n) != 0) n++;
		var c = Bytes.alloc(n + 1);
		c.blit(0, b, 0, n);
		c.set(n, 0);
		return c;
	}

	// The bytes before the first NUL; NotFound when there is none.
	static function untilNul(b:Bytes):Bytes {
		var n = 0;
		while (n < b.length && b.get(n) != 0) n++;
		if (n == b.length) throw new EvalExceptions.HostException("Not_found");
		return b.sub(0, n);
	}

	// A C string libuv returned, as its bytes
	static function fromC(p:cpp.RawPointer<cpp.Void>):Null<Bytes> {
		if (p == null) return null;
		var n:Int = untyped __cpp__("(int)strlen((const char*){0})", p);
		var b = Bytes.alloc(n);
		if (n > 0) untyped __cpp__("memcpy({0}->b->GetBase(), {1}, {2})", b, p, n);
		return b;
	}


	public static function getenv(name:Bytes, out:Array<Bytes>):Int {
		var c = cString(name);
		var buf = Bytes.alloc(1024);
		var r = 0;
		untyped __cpp__("{ size_t hxc_len = 1024; {0} = uv_os_getenv((const char*){1}->b->GetBase(), (char*){2}->b->GetBase(), &hxc_len); }", r, c, buf);
		if (r >= 0) out[0] = untilNul(buf);
		return r;
	}

	public static function setenv(name:Bytes, value:Bytes):Int {
		var n = cString(name), v = cString(value);
		return untyped __cpp__("uv_os_setenv((const char*){0}->b->GetBase(), (const char*){1}->b->GetBase())", n, v);
	}

	public static function unsetenv(name:Bytes):Int {
		var n = cString(name);
		return untyped __cpp__("uv_os_unsetenv((const char*){0}->b->GetBase())", n);
	}

	public static function osEnviron(out:Array<{name:Bytes, value:Bytes}>):Int {
		var r = 0;
		var count = 0;
		var items:cpp.RawPointer<cpp.Void> = null;
		untyped __cpp__("{ uv_env_item_t *hxc_items = NULL; int hxc_count = 0; {0} = uv_os_environ(&hxc_items, &hxc_count); {1} = (void*)hxc_items; {2} = hxc_count; }", r, items, count);
		if (r < 0) return r;
		for (i in 0...count) {
			var np:cpp.RawPointer<cpp.Void> = untyped __cpp__("(void*)((uv_env_item_t*){0})[{1}].name", items, i);
			var vp:cpp.RawPointer<cpp.Void> = untyped __cpp__("(void*)((uv_env_item_t*){0})[{1}].value", items, i);
			out.push({name: fromC(np), value: fromC(vp)});
		}
		untyped __cpp__("uv_os_free_environ((uv_env_item_t*){0}, {1})", items, count);
		return r;
	}


	public static function gettimeofday(out:Array<Dynamic>):Int {
		var r = 0;
		var sec:haxe.Int64 = 0;
		var usec = 0;
		untyped __cpp__("{ uv_timeval64_t hxc_tv; memset(&hxc_tv, 0, sizeof(hxc_tv)); {0} = uv_gettimeofday(&hxc_tv); {1} = (::cpp::Int64)hxc_tv.tv_sec; {2} = (int)hxc_tv.tv_usec; }", r, sec, usec);
		out[0] = sec;
		out[1] = usec;
		return r;
	}

	public static function hrtime():haxe.Int64
		return untyped __cpp__("(::cpp::Int64)uv_hrtime()");

	// Sleep is a blocking call
	public static function sleep(ms:Int):Void {
		var released = EvalStdLib.gilRelease();
		untyped __cpp__("hx::EnterGCFreeZone()");
		untyped __cpp__("uv_sleep((unsigned int){0})", ms);
		untyped __cpp__("hx::ExitGCFreeZone()");
		if (released) EvalStdLib.gilReacquire();
	}

	// ---- paths: a fixed buffer, the size in and out ----

	public static function path(kind:Int, out:Array<Bytes>):Int {
		var size = kind <= 1 ? 4096 : 1024;
		var buf = Bytes.alloc(size);
		var r = 0;
		untyped __cpp__("{ size_t hxc_len = (size_t){2}; char *hxc_b = (char*){1}->b->GetBase();
			switch ({3}) {
				case 0: {0} = uv_exepath(hxc_b, &hxc_len); break;
				case 1: {0} = uv_cwd(hxc_b, &hxc_len); break;
				case 2: {0} = uv_os_homedir(hxc_b, &hxc_len); break;
				default: {0} = uv_os_tmpdir(hxc_b, &hxc_len); break;
			} }", r, buf, size, kind);
		if (r >= 0) out[0] = untilNul(buf);
		return r;
	}

	public static function chdir(dir:Bytes):Int {
		var c = cString(dir);
		hxc.core.Cwd.generation++;
		return untyped __cpp__("uv_chdir((const char*){0}->b->GetBase())", c);
	}

	// ---- socket addresses: a sockaddr_storage, zeroed ----

	public static function newSockaddr():Bytes {
		return Bytes.alloc(untyped __cpp__("(int)sizeof(struct sockaddr_storage)"));
	}

	public static function ipv4(host:Bytes, port:Int, storage:Bytes):Int {
		var c = cString(host);
		return untyped __cpp__("uv_ip4_addr((const char*){0}->b->GetBase(), {1}, (struct sockaddr_in*){2}->b->GetBase())", c, port, storage);
	}

	public static function ipv6(host:Bytes, port:Int, storage:Bytes):Int {
		var c = cString(host);
		return untyped __cpp__("uv_ip6_addr((const char*){0}->b->GetBase(), {1}, (struct sockaddr_in6*){2}->b->GetBase())", c, port, storage);
	}

	// Address families, to C: 0 unspecified, 1 INET, 2 INET6
	public static function addressFamilyToC(index:Int):Int {
		return switch (index) {
			case 0: untyped __cpp__("AF_UNSPEC");
			case 1: untyped __cpp__("AF_INET");
			case _: untyped __cpp__("AF_INET6");
		};
	}

	// 0 unspecified, 1 INET, 2 INET6, 3 anything else
	static function family(storage:Bytes):Int {
		return untyped __cpp__("(((struct sockaddr_storage*){0}->b->GetBase())->ss_family == AF_INET ? 1 : ((struct sockaddr_storage*){0}->b->GetBase())->ss_family == AF_INET6 ? 2 : ((struct sockaddr_storage*){0}->b->GetBase())->ss_family == AF_UNSPEC ? 0 : 3)", storage);
	}

	// A 64-byte buffer, the conversion's result ignored
	public static function sockaddrToString(storage:Bytes):Null<Bytes> {
		var f = family(storage);
		if (f != 1 && f != 2) return null;
		var buf = Bytes.alloc(64);
		if (f == 1) untyped __cpp__("uv_ip4_name((const struct sockaddr_in*){0}->b->GetBase(), (char*){1}->b->GetBase(), 64)", storage, buf);
		else untyped __cpp__("uv_ip6_name((const struct sockaddr_in6*){0}->b->GetBase(), (char*){1}->b->GetBase(), 64)", storage, buf);
		return untilNul(buf);
	}

	public static function sockaddrPort(storage:Bytes):Null<Int> {
		var f = family(storage);
		if (f == 1) return untyped __cpp__("(int)ntohs(((struct sockaddr_in*){0}->b->GetBase())->sin_port)", storage);
		if (f == 2) return untyped __cpp__("(int)ntohs(((struct sockaddr_in6*){0}->b->GetBase())->sin6_port)", storage);
		return null;
	}


	public static function interfaceAddresses(out:Array<{name:Bytes, internal:Bool, physical:Bytes, address:Bytes, netmask:Bytes}>):Int {
		var r = 0;
		var count = 0;
		var list:cpp.RawPointer<cpp.Void> = null;
		untyped __cpp__("{ uv_interface_address_t *hxc_a = NULL; int hxc_n = 0; {0} = uv_interface_addresses(&hxc_a, &hxc_n); {1} = (void*)hxc_a; {2} = hxc_n; }", r, list, count);
		if (r < 0) return r;
		// The address length: the larger of sockaddr_in and sockaddr_in6
		var len:Int = untyped __cpp__("(int)(sizeof(struct sockaddr_in) > sizeof(struct sockaddr_in6) ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6))");
		for (i in 0...count) {
			var np:cpp.RawPointer<cpp.Void> = untyped __cpp__("(void*)((uv_interface_address_t*){0})[{1}].name", list, i);
			var internal:Int = untyped __cpp__("((uv_interface_address_t*){0})[{1}].is_internal", list, i);
			var physical = Bytes.alloc(6);
			untyped __cpp__("memcpy({0}->b->GetBase(), ((uv_interface_address_t*){1})[{2}].phys_addr, 6)", physical, list, i);
			var address = newSockaddr(), netmask = newSockaddr();
			untyped __cpp__("memcpy({0}->b->GetBase(), &((uv_interface_address_t*){1})[{2}].address, {3})", address, list, i, len);
			untyped __cpp__("memcpy({0}->b->GetBase(), &((uv_interface_address_t*){1})[{2}].netmask, {3})", netmask, list, i, len);
			out.push({name: fromC(np), internal: internal != 0, physical: physical, address: address, netmask: netmask});
		}
		untyped __cpp__("uv_free_interface_addresses((uv_interface_address_t*){0}, {1})", list, count);
		return r;
	}

	// A buffer of UV_IF_NAMESIZE
	public static function ifIndexTo(iid:Bool, index:Int, out:Array<Bytes>):Int {
		var size:Int = untyped __cpp__("UV_IF_NAMESIZE");
		var buf = Bytes.alloc(size);
		var r = 0;
		untyped __cpp__("{ size_t hxc_len = (size_t){2}; {0} = {3} ? uv_if_indextoiid((unsigned int){4}, (char*){1}->b->GetBase(), &hxc_len) : uv_if_indextoname((unsigned int){4}, (char*){1}->b->GetBase(), &hxc_len); }",
			r, buf, size, iid, index);
		if (r >= 0) out[0] = untilNul(buf);
		return r;
	}

	// A buffer of UV_MAXHOSTNAMESIZE
	public static function gethostname(out:Array<Bytes>):Int {
		var size:Int = untyped __cpp__("UV_MAXHOSTNAMESIZE");
		var buf = Bytes.alloc(size);
		var r = 0;
		untyped __cpp__("{ size_t hxc_len = (size_t){2}; {0} = uv_os_gethostname((char*){1}->b->GetBase(), &hxc_len); }", r, buf, size);
		if (r >= 0) out[0] = untilNul(buf);
		return r;
	}


	public static function uptime(out:Array<Float>):Int {
		var r = 0;
		var t = 0.0;
		untyped __cpp__("{ double hxc_t = 0.0; {0} = uv_uptime(&hxc_t); {1} = hxc_t; }", r, t);
		out[0] = t;
		return r;
	}

	public static function loadavg():Array<Float> {
		var a = 0.0, b = 0.0, c = 0.0;
		untyped __cpp__("{ double hxc_l[3] = {0.0, 0.0, 0.0}; uv_loadavg(hxc_l); {0} = hxc_l[0]; {1} = hxc_l[1]; {2} = hxc_l[2]; }", a, b, c);
		return [a, b, c];
	}

	// 0 free, 1 total, 2 constrained
	public static function memory(kind:Int):haxe.Int64 {
		return switch (kind) {
			case 0: untyped __cpp__("(::cpp::Int64)uv_get_free_memory()");
			case 1: untyped __cpp__("(::cpp::Int64)uv_get_total_memory()");
			case _: untyped __cpp__("(::cpp::Int64)uv_get_constrained_memory()");
		};
	}

	public static function getpriority(pid:Int, out:Array<Int>):Int {
		var r = 0;
		var p = 0;
		untyped __cpp__("{ int hxc_p = 0; {0} = uv_os_getpriority((uv_pid_t){2}, &hxc_p); {1} = hxc_p; }", r, p, pid);
		out[0] = p;
		return r;
	}

	public static function setpriority(pid:Int, priority:Int):Int
		return untyped __cpp__("uv_os_setpriority((uv_pid_t){0}, {1})", pid, priority);

	public static function residentSetMemory(out:Array<haxe.Int64>):Int {
		var r = 0;
		var size:haxe.Int64 = 0;
		untyped __cpp__("{ size_t hxc_s = 0; {0} = uv_resident_set_memory(&hxc_s); {1} = (::cpp::Int64)hxc_s; }", r, size);
		out[0] = size;
		return r;
	}

	// Utime sec/usec, stime sec/usec, then maxrss .. nivcsw in uv_rusage_t order
	public static function getrusage(out:Array<haxe.Int64>):Int {
		var r = 0;
		var v:Array<haxe.Int64> = [for (_ in 0...18) 0];
		untyped __cpp__("{ uv_rusage_t hxc_u; memset(&hxc_u, 0, sizeof(hxc_u)); {0} = uv_getrusage(&hxc_u);
			::cpp::Int64 hxc_f[18] = {
				(::cpp::Int64)hxc_u.ru_utime.tv_sec, (::cpp::Int64)hxc_u.ru_utime.tv_usec,
				(::cpp::Int64)hxc_u.ru_stime.tv_sec, (::cpp::Int64)hxc_u.ru_stime.tv_usec,
				(::cpp::Int64)hxc_u.ru_maxrss, (::cpp::Int64)hxc_u.ru_ixrss, (::cpp::Int64)hxc_u.ru_idrss,
				(::cpp::Int64)hxc_u.ru_isrss, (::cpp::Int64)hxc_u.ru_minflt, (::cpp::Int64)hxc_u.ru_majflt,
				(::cpp::Int64)hxc_u.ru_nswap, (::cpp::Int64)hxc_u.ru_inblock, (::cpp::Int64)hxc_u.ru_oublock,
				(::cpp::Int64)hxc_u.ru_msgsnd, (::cpp::Int64)hxc_u.ru_msgrcv, (::cpp::Int64)hxc_u.ru_nsignals,
				(::cpp::Int64)hxc_u.ru_nvcsw, (::cpp::Int64)hxc_u.ru_nivcsw };
			for (int hxc_i = 0; hxc_i < 18; hxc_i++) {1}[hxc_i] = hxc_f[hxc_i]; }", r, v);
		for (x in v) out.push(x);
		return r;
	}


	public static function cpuInfo(out:Array<{model:Bytes, speed:Int, times:Array<haxe.Int64>}>):Int {
		var r = 0;
		var count = 0;
		var info:cpp.RawPointer<cpp.Void> = null;
		untyped __cpp__("{ uv_cpu_info_t *hxc_i = NULL; int hxc_n = 0; {0} = uv_cpu_info(&hxc_i, &hxc_n); {1} = (void*)hxc_i; {2} = hxc_n; }", r, info, count);
		if (r < 0) return r;
		for (i in 0...count) {
			var mp:cpp.RawPointer<cpp.Void> = untyped __cpp__("(void*)((uv_cpu_info_t*){0})[{1}].model", info, i);
			var speed:Int = untyped __cpp__("((uv_cpu_info_t*){0})[{1}].speed", info, i);
			var times:Array<haxe.Int64> = [];
			for (k in 0...5) {
				var t:haxe.Int64 = untyped __cpp__("(::cpp::Int64)(({2} == 0) ? ((uv_cpu_info_t*){0})[{1}].cpu_times.user : ({2} == 1) ? ((uv_cpu_info_t*){0})[{1}].cpu_times.nice : ({2} == 2) ? ((uv_cpu_info_t*){0})[{1}].cpu_times.sys : ({2} == 3) ? ((uv_cpu_info_t*){0})[{1}].cpu_times.idle : ((uv_cpu_info_t*){0})[{1}].cpu_times.irq)", info, i, k);
				times.push(t);
			}
			out.push({model: fromC(mp), speed: speed, times: times});
		}
		untyped __cpp__("uv_free_cpu_info((uv_cpu_info_t*){0}, {1})", info, count);
		return r;
	}

	// uv_os_uname into four 256-byte fields
	public static function uname(out:Array<Bytes>):Int {
		var buf = Bytes.alloc(256 * 4);
		var r:Int = untyped __cpp__("uv_os_uname((uv_utsname_t*){0}->b->GetBase())", buf);
		if (r >= 0) for (i in 0...4) {
			// Each field up to its NUL, or all 256 bytes
			var off = i * 256;
			var n = 0;
			while (n < 256 && buf.get(off + n) != 0) n++;
			out.push(buf.sub(off, n));
		}
		#if windows
		// A mingw-built libuv reports the sysname "MINGW32_NT-<major>.<minor>" (the release field is
		// "<major>.<minor>.<build>"), and that is the answer on Windows
		if (r >= 0 && out[0].toString() == "Windows_NT") {
			var parts = out[1].toString().split(".");
			if (parts.length >= 2) out[0] = Bytes.ofString("MINGW32_NT-" + parts[0] + "." + parts[1]);
		}
		#end
		return r;
	}


	public static function getpid():Int
		return untyped __cpp__("(int)uv_os_getpid()");

	public static function getppid():Int
		return untyped __cpp__("(int)uv_os_getppid()");

	public static function getPasswd(out:Array<Dynamic>):Int {
		var r = 0;
		var user:cpp.RawPointer<cpp.Void> = null, shell:cpp.RawPointer<cpp.Void> = null, home:cpp.RawPointer<cpp.Void> = null;
		var uid = 0, gid = 0;
		var pw:cpp.RawPointer<cpp.Void> = untyped __cpp__("calloc(1, sizeof(uv_passwd_t))");
		r = untyped __cpp__("uv_os_get_passwd((uv_passwd_t*){0})", pw);
		if (r >= 0) {
			user = untyped __cpp__("(void*)((uv_passwd_t*){0})->username", pw);
			shell = untyped __cpp__("(void*)((uv_passwd_t*){0})->shell", pw);
			home = untyped __cpp__("(void*)((uv_passwd_t*){0})->homedir", pw);
			// uv_passwd_t's uid and gid are longs; they are read as unsigned long and made an Int
			uid = untyped __cpp__("(int)(unsigned long)((uv_passwd_t*){0})->uid", pw);
			gid = untyped __cpp__("(int)(unsigned long)((uv_passwd_t*){0})->gid", pw);
			out.push(fromC(user));
			out.push(uid);
			out.push(gid);
			out.push(fromC(shell));
			out.push(fromC(home));
			untyped __cpp__("uv_os_free_passwd((uv_passwd_t*){0})", pw);
		}
		untyped __cpp__("free({0})", pw);
		return r;
	}

	public static function idleTime(l:LuvObject):haxe.Int64
		return untyped __cpp__("(::cpp::Int64)uv_metrics_idle_time((uv_loop_t*){0})", l.ptr);

	// uv_random with no loop and no callback, which blocks
	public static function randomSync(b:LuvBuffer):Int {
		var base = b.bytes;
		var off = b.offset;
		var len = b.length;
		var released = EvalStdLib.gilRelease();
		var r:Int = untyped __cpp__("uv_random(NULL, NULL, (char*){0}->b->GetBase() + {1}, (size_t){2}, 0, NULL)", base, off, len);
		if (released) EvalStdLib.gilReacquire();
		return r;
	}
}

/**
	A byte buffer. `sub` is a view on the same memory, so a buffer is a window (offset, length) on
	bytes it may share.
**/
class LuvBuffer {
	public final bytes:Bytes;
	public final offset:Int;
	public final length:Int;

	public function new(bytes:Bytes, offset:Int, length:Int) {
		this.bytes = bytes;
		this.offset = offset;
		this.length = length;
	}
}
#end
