package hxc.compiler;

/**
 * Buffer stderr until a line-ending write, flush, capacity limit or exit. Track interpreter thread
 * identities and preemption ticks; when threads remain, exit without hxcpp's static teardown.
 */
#if cpp
@:cppFileCode('
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <vector>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <io.h>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <unistd.h>
#include <sched.h>
#endif
static std::mutex hxc_err_mutex;
static std::vector<char> hxc_err_buf;
static bool hxc_err_atexit_set = false;
static std::atomic<int> hxc_threads_alive(0);
static std::atomic<int> hxc_exit_code(0);
static std::once_flag hxc_threads_atexit_once;
// Thread identifiers start at 1; the main thread uses 0.
static std::atomic<int> hxc_next_ident(1);
static thread_local int hxc_thread_ident = 0;
static std::atomic<bool> hxc_tick_running(false);
static std::atomic<int> hxc_preempt_pending(0);
static void hxc_err_flush_locked() {
	if (!hxc_err_buf.empty()) {
		fwrite(hxc_err_buf.data(), 1, hxc_err_buf.size(), stderr);
		hxc_err_buf.clear();
	}
	fflush(stderr);
}
static void hxc_err_atexit() {
	std::lock_guard<std::mutex> g(hxc_err_mutex);
	hxc_err_flush_locked();
}
static void hxc_err_write(const unsigned char* p, int n) {
	std::lock_guard<std::mutex> g(hxc_err_mutex);
	if (!hxc_err_atexit_set) {
		hxc_err_atexit_set = true;
		atexit(hxc_err_atexit);
	}
	hxc_err_buf.insert(hxc_err_buf.end(), p, p + n);
	// Flush full 65536-byte chunks; retain the remainder in the buffer.
	while (hxc_err_buf.size() >= 65536) {
		fwrite(hxc_err_buf.data(), 1, 65536, stderr);
		fflush(stderr);
		hxc_err_buf.erase(hxc_err_buf.begin(), hxc_err_buf.begin() + 65536);
	}
}
static void hxc_err_flush() {
	std::lock_guard<std::mutex> g(hxc_err_mutex);
	hxc_err_flush_locked();
}
// Register after static destructors so this runs before them (atexit is LIFO). Flush stdout and
// stderr before terminating.
static void hxc_threads_atexit() {
	if (hxc_threads_alive.load() > 0) {
		fflush(stdout);
		hxc_err_flush();
		_exit(hxc_exit_code.load());
	}
}
static void hxc_thread_started(int ident) {
	std::call_once(hxc_threads_atexit_once, []() { atexit(hxc_threads_atexit); });
	hxc_thread_ident = ident;
	hxc_threads_alive++;
}
static void hxc_thread_ended() {
	hxc_threads_alive--;
}
static void hxc_tick_loop() {
	for (;;) {
		std::this_thread::sleep_for(std::chrono::milliseconds(50));
		hxc_preempt_pending.store(1);
	}
}
static int hxc_thread_created() {
	int ident = hxc_next_ident++;
#ifndef __EMSCRIPTEN__
	bool expected = false;
	if (hxc_tick_running.compare_exchange_strong(expected, true)) std::thread(hxc_tick_loop).detach();
#endif
	return ident;
}
// A yield: between LeaveCriticalSection and EnterCriticalSection, a Sleep(0).
static void hxc_sleep_zero() {
#ifdef _WIN32
	Sleep(0);
#else
	sched_yield();
#endif
}
// Exit only the main thread, without running at_exit handlers. The process remains alive while
// other threads run. On Windows, libuv console initialization starts two persistent threads for
// CONOUT$; without them, the last thread ends the process with code 0.
static void hxc_main_thread_exit() {
	hx::EnterGCFreeZone();
#ifdef _WIN32
	HANDLE con = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
	if (con != INVALID_HANDLE_VALUE) for (;;) Sleep(INFINITE);
#endif
	while (hxc_threads_alive.load() > 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
	_exit(0);
}
// Flush stdout and buffered stderr before reporting the uncaught thread exception directly to C
// stderr.
static void hxc_thread_uncaught(const char* msg) {
	fflush(stdout);
	hxc_err_flush();
	fprintf(stderr, "Thread %d killed on uncaught exception %s\\n", hxc_thread_ident, msg);
	fflush(stderr);
}
')
#end
class HostRuntime {
	public static function stderrWrite(b:haxe.io.Bytes, pos:Int, len:Int):Void {
		if (len <= 0) return;
		#if cpp
		untyped __cpp__("hxc_err_write((const unsigned char*){0}->b->GetBase() + {1}, {2})", b, pos, len);
		#else
		Sys.stderr().writeBytes(b, pos, len);
		#end
	}

	public static function stderrWriteString(s:String):Void {
		var b = haxe.io.Bytes.ofString(s);
		stderrWrite(b, 0, b.length);
	}

	public static function stderrFlush():Void {
		#if cpp
		untyped __cpp__("hxc_err_flush()");
		#else
		Sys.stderr().flush();
		#end
	}

	// Flush the line together with previously buffered stderr.
	public static function stderrLine(s:String):Void {
		stderrWriteString(s + "\n");
		stderrFlush();
	}

	// Assign the thread identity; the first registered thread starts the preemption tick.
	public static function threadCreated():Int {
		#if cpp
		return untyped __cpp__("hxc_thread_created()");
		#else
		return 0;
		#end
	}

	// Interpreter thread identity; the main thread is 0.
	public static function currentIdent():Int {
		#if cpp
		return untyped __cpp__("hxc_thread_ident");
		#else
		return 0;
		#end
	}

	public static function threadStarted(ident:Int):Void {
		#if cpp
		untyped __cpp__("hxc_thread_started({0})", ident);
		#end
	}

	public static function threadEnded():Void {
		#if cpp
		untyped __cpp__("hxc_thread_ended()");
		#end
	}

	public static function preemptPending():Bool {
		#if cpp
		return untyped __cpp__("hxc_preempt_pending.load(std::memory_order_relaxed) != 0");
		#else
		return false;
		#end
	}

	public static function preemptClear():Void {
		#if cpp
		untyped __cpp__("hxc_preempt_pending.store(0)");
		#end
	}

	public static function sleepZero():Void {
		#if cpp
		untyped __cpp__("hxc_sleep_zero()");
		#end
	}

	public static function mainThreadExit():Void {
		#if cpp
		untyped __cpp__("hxc_main_thread_exit()");
		#else
		Sys.exit(0);
		#end
	}

	// Report an uncaught thread exception using the runtime's standard wording.
	public static function threadUncaughtException(text:String):Void {
		#if cpp
		untyped __cpp__("hxc_thread_uncaught({0}.utf8_str())", text);
		#else
		Sys.stderr().writeString("Thread " + currentIdent() + " killed on uncaught exception " + text + "\n");
		#end
	}

	public static function exit(code:Int):Void {
		#if cpp
		untyped __cpp__("hxc_exit_code = {0}", code);
		#end
		Sys.exit(code);
	}
}

/**
 * Interpreter stderr channel backed by the runtime buffer.
 */
class HostStderrOutput extends haxe.io.Output {
	public function new() {}

	override public function writeByte(c:Int):Void {
		var b = haxe.io.Bytes.alloc(1);
		b.set(0, c);
		HostRuntime.stderrWrite(b, 0, 1);
	}

	override public function writeBytes(s:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length) throw haxe.io.Error.OutsideBounds;
		HostRuntime.stderrWrite(s, pos, len);
		return len;
	}

	override public function flush():Void {
		HostRuntime.stderrFlush();
	}
}
