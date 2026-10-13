package hxc.eval;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
	Adds libuv (the thirdparty/libuv submodule, pinned at v1.48.0) to the hxcpp build of the class it is on.
	Build.xml is written far from the source tree, so the paths are absolute, taken from where this
	class's source file lives.

	The source lists, defines and libraries are libuv's own CMakeLists.txt: the common sources, the
	Windows ones, the unix core, Linux and macOS. Nothing of it is built for emscripten, which libuv
	does not support.
**/
class LuvBuild {
	static final COMMON = [
		"fs-poll.c", "idna.c", "inet.c", "random.c", "strscpy.c", "strtok.c", "thread-common.c", "threadpool.c",
		"timer.c", "uv-common.c", "uv-data-getter-setters.c", "version.c"
	];
	static final WINDOWS = [
		"async.c", "core.c", "detect-wakeup.c", "dl.c", "error.c", "fs.c", "fs-event.c", "getaddrinfo.c",
		"getnameinfo.c", "handle.c", "loop-watcher.c", "pipe.c", "thread.c", "poll.c", "process.c",
		"process-stdio.c", "signal.c", "snprintf.c", "stream.c", "tcp.c", "tty.c", "udp.c", "util.c", "winapi.c",
		"winsock.c"
	];
	static final WINDOWS_LIBS = ["psapi", "user32", "advapi32", "iphlpapi", "userenv", "ws2_32", "dbghelp", "ole32", "shell32"];
	static final UNIX = [
		"async.c", "core.c", "dl.c", "fs.c", "getaddrinfo.c", "getnameinfo.c", "loop-watcher.c", "loop.c", "pipe.c",
		"poll.c", "process.c", "random-devurandom.c", "signal.c", "stream.c", "tcp.c", "thread.c", "tty.c", "udp.c"
	];
	static final LINUX = ["linux.c", "procfs-exepath.c", "random-getrandom.c", "random-sysctl-linux.c", "proctitle.c"];
	static final MACOS = [
		"proctitle.c", "bsd-ifaddrs.c", "kqueue.c", "random-getentropy.c", "darwin-proctitle.c", "darwin.c",
		"fsevents.c"
	];

	public static function build():Array<Field> {
		var file = Context.getPosInfos(Context.currentPos()).file;
		var here = haxe.io.Path.directory(sys.FileSystem.fullPath(file));
		var root = haxe.io.Path.normalize(here + "/../../../thirdparty/libuv");
		if (!Context.defined("emscripten") && !sys.FileSystem.exists(root + "/include/uv.h"))
			Context.fatalError("libuv is missing from thirdparty/libuv: run `git submodule update --init`", Context.currentPos());
		var b = new StringBuf();
		b.add('<files id="haxe" unless="emscripten">\n');
		b.add('\t<compilerflag value="-I$root/include"/>\n');
		b.add('</files>\n');
		b.add('<files id="hxc-libuv" unless="emscripten">\n');
		b.add('\t<compilerflag value="-I$root/include"/>\n');
		b.add('\t<compilerflag value="-I$root/src"/>\n');
		for (d in ["WIN32_LEAN_AND_MEAN", "_WIN32_WINNT=0x0602", "_CRT_DECLARE_NONSTDC_NAMES=0"])
			b.add('\t<compilerflag value="-D$d" if="windows"/>\n');
		b.add('\t<compilerflag value="/utf-8" if="windows"/>\n');
		for (d in ["_FILE_OFFSET_BITS=64", "_LARGEFILE_SOURCE"])
			b.add('\t<compilerflag value="-D$d" unless="windows"/>\n');
		b.add('\t<compilerflag value="-fno-strict-aliasing" unless="windows"/>\n');
		for (d in ["_GNU_SOURCE", "_POSIX_C_SOURCE=200112"])
			b.add('\t<compilerflag value="-D$d" if="linux"/>\n');
		for (d in ["_DARWIN_UNLIMITED_SELECT=1", "_DARWIN_USE_64_BIT_INODE=1"])
			b.add('\t<compilerflag value="-D$d" if="macos"/>\n');
		for (f in COMMON) b.add('\t<file name="$root/src/$f"/>\n');
		for (f in WINDOWS) b.add('\t<file name="$root/src/win/$f" if="windows"/>\n');
		for (f in UNIX) b.add('\t<file name="$root/src/unix/$f" unless="windows"/>\n');
		for (f in LINUX) b.add('\t<file name="$root/src/unix/$f" if="linux"/>\n');
		for (f in MACOS) b.add('\t<file name="$root/src/unix/$f" if="macos"/>\n');
		b.add('</files>\n');
		b.add('<target id="haxe" unless="emscripten">\n');
		b.add('\t<files id="hxc-libuv"/>\n');
		for (l in WINDOWS_LIBS) b.add('\t<lib name="$l.lib" if="windows"/>\n');
		for (l in ["-lpthread", "-ldl", "-lrt"]) b.add('\t<lib name="$l" if="linux"/>\n');
		b.add('</target>\n');
		Context.getLocalClass().get().meta.add(":buildXml", [macro $v{b.toString()}], Context.currentPos());
		return null;
	}
}
#end
