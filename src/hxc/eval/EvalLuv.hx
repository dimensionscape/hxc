package hxc.eval;

#if (cpp && !emscripten)
import hxc.ast.Position;
import hxc.eval.EvalString.ByteString;
import hxc.eval.EvalString.EvalString;
import hxc.eval.EvalValue;
import hxc.eval.Luv.LuvObject;
import hxc.eval.Luv.FsResult;
import hxc.eval.Luv.FsPathFile;
import hxc.eval.Luv.FsDirent;
import hxc.eval.Luv.AddrInfo;
import hxc.eval.Luv.Redirection;

/**
	The eval.luv natives, over libuv (hxc.eval.Luv, hxc.eval.LuvSys). sys.thread.EventLoop runs on Loop,
	Async, Timer and Handle, Condition and Semaphore on Mutex, Condition and Semaphore; beside them are the
	other synchronisation types and loop watchers, UVError, Version, Buffer, SockAddr and the system modules
	(Env, Time, Path, RandomSync, Network, Resource, SystemInfo, Pid, Passwd, Metrics).
**/
@:access(hxc.eval.EvalStdLib)
@:access(hxc.Compiler)
class EvalLuv {
	static inline function vfn(f:VFunc):EvalValue return VFunction(f, true);

	static inline function arg(a:Array<EvalValue>, i:Int):EvalValue return i < a.length ? a[i] : VNull;

	static final resultPath = EvalHash.hash("eval.luv.Result");

	static function encodeResult(code:Int, ok:Void->EvalValue):EvalValue {
		return code >= 0 ? VEnumValue(new VEnumValue(0, [ok()], resultPath, null))
			: VEnumValue(new VEnumValue(1, [VInt(Luv.errorIndex(code))], resultPath, null));
	}

	static function encodeUnitResult(code:Int):EvalValue return encodeResult(code, () -> VNull);

	static function handle(kind:EvalHandleKind, o:LuvObject):EvalValue return VHandle(new EvalHandle(kind, o));

	// Decodes a handle of a single kind.
	static function decodeKind(ctx:EvalContext, v:EvalValue, kind:EvalHandleKind, name:String):LuvObject {
		return switch (v) {
			case VHandle(h) if (h.kind == kind): h.native;
			case _: EvalExceptions.unexpectedValue(ctx, v, name);
		};
	}

	static function decodeLuvHandle(ctx:EvalContext, v:EvalValue):LuvObject {
		return switch (v) {
			case VHandle(h): switch (h.kind) {
				case HIdle | HTimer | HAsync | HPrepare | HCheck | HTcp | HUdp | HPipe | HTty | HSignal | HFsEvent | HFsPoll | HProcess: h.native;
				case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Handle");
			}
			case _: EvalExceptions.unexpectedValue(ctx, v, "handle");
		};
	}

	// A TCP, UDP or pipe handle.
	static function decodeSocketHandle(ctx:EvalContext, v:EvalValue):LuvObject {
		return switch (v) {
			case VHandle(h): switch (h.kind) {
				case HTcp | HUdp | HPipe: h.native;
				case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Handle.SocketHandle");
			}
			case _: EvalExceptions.unexpectedValue(ctx, v, "handle");
		};
	}

	// Every index the error encoding writes, and nothing else.
	static function decodeUvError(ctx:EvalContext, v:EvalValue):Int {
		var i = EvalStdLib.decodeInt(ctx, v);
		if (i < 0 || i > 81 || i == 24) EvalExceptions.unexpectedValue(ctx, v, "eval.luv.UVError");
		return i;
	}

	static function decodeOptionalBool(ctx:EvalContext, v:EvalValue, d:Bool):Bool {
		return v == VNull ? d : EvalStdLib.decodeBool(ctx, v);
	}

	// Anything but a function is MacroApi.Invalid_expr, which no handler turns into a Haxe exception here.
	static function prepareCallback(ctx:EvalContext, v:EvalValue):Array<EvalValue>->EvalValue {
		switch (v) {
			case VFunction(_, _) | VFieldClosure(_, _):
			case _: throw new EvalExceptions.HostException("MacroApi.Invalid_expr", false);
		}
		return function(args:Array<EvalValue>):EvalValue return catchExceptions(ctx, () -> EvalStdLib.callValue(ctx, v, args));
	}

	// At the null position, a Haxe exception becomes the Error the compiler would print, "Uncaught
	// exception <value>" and each frame's "Called from here".
	static function catchExceptions(ctx:EvalContext, f:Void->EvalValue):EvalValue {
		var prev = try EvalContext.getCtx() catch (_:Dynamic) null;
		EvalContext.setCtx(ctx);
		var eval = EvalContext.getEval(ctx);
		var env = eval.env;
		try {
			var v = f();
			if (prev != null) EvalContext.setCtx(prev);
			return v;
		} catch (ex:EvalExceptions.EvalRunTimeException) {
			eval.exceptionStack = EvalExceptions.buildExceptionStack(ex, env);
			eval.env = env;
			var frames = [for (e in ex.envStack) EvalExceptions.envPosition(e)];
			frames = [for (p in frames) if (p != null && !EvalExceptions.isNullPos(p)) p];
			var explicit = ex.pos != null && !EvalExceptions.isNullPos(ex.pos);
			if (explicit && frames.length > 0) frames.shift();
			var message = "Uncaught exception " + EvalStdLib.stringOf(ex.value);
			var head = explicit ? ex.pos : Position.nullPos;
			var stack:Array<{message:String, pos:Position, ?depth:Int}> = [{message: message, pos: head}];
			for (p in frames) stack.push({message: "Called from here", pos: p});
			if (prev != null) EvalContext.setCtx(prev);
			var err = new hxc.core.TypingError(message, head);
			err.callChain = stack;
			throw err;
		} catch (a:EvalExceptions.MacroAbort) {
			if (prev != null) EvalContext.setCtx(prev);
			return VNull;
		}
	}

	static function com(ctx:EvalContext):Null<hxc.context.Context> {
		return ctx.com != null ? ctx.com : EvalMacro.hostCom;
	}

	// An error position, printed as "%s:%d: ".
	static function errorPos(ctx:EvalContext, p:Position):String {
		if (p.min == -1) return "(unknown)";
		var c = com(ctx);
		if (c != null) p = hxc.Compiler.qualifyStdPosition(c, p);
		var info = Position.getInfos(p);
		var prefix = info.file + ":" + info.line + ": ";
		if (info.line == info.endLine) {
			var c1 = info.column + 1;
			var c2 = info.endColumn + 1;
			return prefix + (c1 == c2 ? " character " + c1 : " characters " + c1 + "-" + c2);
		}
		return prefix + " lines " + info.line + "-" + info.endLine;
	}

	// An Error's message lines, one per located message.
	static function located(e:hxc.core.TypingError):Array<{message:String, pos:Position}> {
		if (e.callChain != null) return [for (m in e.callChain) {message: m.message, pos: m.pos}];
		return [{message: e.message, pos: e.pos}];
	}

	// The first message, then the position of every one after it.
	static function locatedText(ctx:EvalContext, e:hxc.core.TypingError):String {
		var l = located(e);
		if (l.length == 0) return "";
		if (l.length == 1) return l[0].message;
		var acc = l[0].message + "\n";
		for (i in 1...l.length) acc += errorPos(ctx, l[i].pos) + "\n";
		return acc;
	}

	// The printed form of an exception with no Error of its own.
	static function errorText(e:Dynamic):String {
		if (Std.isOfType(e, EvalExceptions.EvalSysExit)) return "EvalExceptions.Sys_exit(" + (e : EvalExceptions.EvalSysExit).code + ")";
		if (Std.isOfType(e, EvalExceptions.HostException)) return (e : EvalExceptions.HostException).message;
		return Std.string(e);
	}

	// With no handler of the program's own, an exception out of a callback prints and ends the program with
	// code 2, as libuv's own would; Sys.exit still exits.
	static function defaultHandler(ctx:EvalContext):Dynamic->Void {
		return function(e:Dynamic) {
			if (Std.isOfType(e, EvalExceptions.EvalSysExit)) throw e;
			var msg = Std.isOfType(e, hxc.core.TypingError) ? locatedText(ctx, e) : errorText(e);
			EvalStdLib.flushStdout();
			Sys.stderr().writeString(msg + "\n");
			Sys.stderr().flush();
			throw new EvalExceptions.EvalSysExit(2);
		};
	}

	static function createHaxeException(ctx:EvalContext, msg:String):EvalValue {
		var proto = ctx.instancePrototypes.get(EvalNames.hHaxeException());
		var vi = new VInstance(proto.pinstanceFields.copy(), proto);
		var vmsg = EvalString.createUnknown(ByteString.ofText(msg));
		setField(vi, EvalHash.keyExceptionMessage, vmsg);
		setField(vi, EvalHash.keyNativeException, vmsg);
		setField(vi, EvalHash.keyNativeStack, EvalStdLib.stackItems(ctx, EvalContext.getEval(ctx).exceptionStack));
		return VInstance(vi);
	}

	static function setField(vi:VInstance, key:Int, v:EvalValue):Void {
		var idx = vi.iproto.pinstanceNames.get(key);
		if (idx == null) throw new EvalExceptions.HostException("Not_found", false);
		vi.ifields[idx] = v;
	}

	static function decodeBuffer(ctx:EvalContext, v:EvalValue):LuvSys.LuvBuffer {
		return switch (v) {
			case VHandle(h) if (h.kind == HBuffer): h.native;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Buffer");
		};
	}

	static function encodeBuffer(b:LuvSys.LuvBuffer):EvalValue return VHandle(new EvalHandle(HBuffer, b));

	// A socket address, decoded as a handle.
	static function decodeSockaddr(ctx:EvalContext, v:EvalValue):haxe.io.Bytes {
		return switch (v) {
			case VHandle(h) if (h.kind == HSockAddr): h.native;
			case VHandle(_): EvalExceptions.unexpectedValue(ctx, v, "eval.luv.SockAddr");
			case _: EvalExceptions.unexpectedValue(ctx, v, "handle");
		};
	}

	static function encodeSockaddr(storage:haxe.io.Bytes):EvalValue return VHandle(new EvalHandle(HSockAddr, storage));

	static inline function invalidArgument(msg:String):Dynamic
		throw new EvalExceptions.HostException("Invalid_argument(\"" + msg + "\")", false);

	// Stdlib.char_of_int
	static function charOfInt(i:Int):Int {
		if (i < 0 || i > 255) invalidArgument("char_of_int");
		return i;
	}

	static function nativeString(b:haxe.io.Bytes):EvalValue return VNativeString(ByteString.ofBytes(b, 0, b.length));

	static function encodeString(b:haxe.io.Bytes):EvalValue return EvalString.createUnknown(ByteString.ofBytes(b, 0, b.length));

	static function obj(fields:Array<{name:String, value:EvalValue}>):EvalValue return EvalStdLib.mkObject(fields);

	static function u64(v:haxe.Int64):EvalValue return VUInt64(new EvalInt64(v));

	static function i64(v:haxe.Int64):EvalValue return VInt64(new EvalInt64(v));

	static function array(values:Array<EvalValue>):EvalValue return VArray(new VArray(values, values.length));

	static function decodeEnum(ctx:EvalContext, v:EvalValue):{index:Int, args:Array<EvalValue>} {
		return switch (v) {
			case VEnumValue(ev): {index: ev.eindex, args: ev.eargs};
			case _: EvalExceptions.unexpectedValue(ctx, v, "enum");
		};
	}

	static function decodeOption<T>(ctx:EvalContext, v:EvalValue, decode:EvalValue->T):Null<T> {
		var e = decodeEnum(ctx, v);
		if (e.index == 0 && e.args.length == 1) return decode(e.args[0]);
		if (e.index == 1 && e.args.length == 0) return null;
		return EvalExceptions.unexpectedValue(ctx, v, "haxe.ds.Option");
	}

	// The AF_ value.
	static function decodeAddressFamily(ctx:EvalContext, v:EvalValue):Int {
		var e = decodeEnum(ctx, v);
		return switch [e.index, e.args.length] {
			case [0, 0]: LuvSys.addressFamilyToC(0);
			case [1, 0]: LuvSys.addressFamilyToC(1);
			case [2, 0]: LuvSys.addressFamilyToC(2);
			case [3, 1]: EvalStdLib.decodeInt(ctx, e.args[0]);
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.SockAddr.AddressType");
		};
	}

	// A stream, decoded as a handle.
	static function decodeStream(ctx:EvalContext, v:EvalValue):LuvObject {
		return switch (v) {
			case VHandle(h): switch (h.kind) {
				case HTcp | HTty | HPipe: h.native;
				case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Stream");
			}
			case _: EvalExceptions.unexpectedValue(ctx, v, "handle");
		};
	}

	// prepareCallback runs when the result arrives.
	static function unitCallback(ctx:EvalContext, v:EvalValue):Int->Void {
		return function(code:Int) {
			var cb = prepareCallback(ctx, v);
			cb([encodeUnitResult(code)]);
		};
	}

	static function initStreams(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		inline function reg(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);
		function decodeBuffers(v:EvalValue) return [for (x in EvalStdLib.decodeArray(ctx, v)) decodeBuffer(ctx, x)];

		var st = "eval.luv._Stream.Stream_Impl_";
		reg(st, "shutdown", vfn(a -> {
			var stream = decodeStream(ctx, arg(a, 0));
			Luv.shutdown(stream, unitCallback(ctx, arg(a, 1)));
			VNull;
		}));
		reg(st, "listen", vfn(a -> {
			var stream = decodeStream(ctx, arg(a, 0));
			var backlog = arg(a, 2) == VNull ? Luv.somaxconn() : EvalStdLib.decodeInt(ctx, arg(a, 2));
			Luv.listen(stream, backlog, unitCallback(ctx, arg(a, 1)));
			VNull;
		}));
		reg(st, "accept", vfn(a -> {
			var server = decodeStream(ctx, arg(a, 0));
			var client = decodeStream(ctx, arg(a, 1));
			encodeUnitResult(Luv.accept(server, client));
		}));
		reg(st, "readStart", vfn(a -> {
			var stream = decodeStream(ctx, arg(a, 0));
			var v2 = arg(a, 1);
			var callback = function(code:Int, b:Null<LuvSys.LuvBuffer>) {
				var cb = prepareCallback(ctx, v2);
				cb([encodeResult(code, () -> encodeBuffer(b))]);
			};
			var allocate:Int->LuvSys.LuvBuffer = if (arg(a, 2) == VNull) {
				size -> new LuvSys.LuvBuffer(haxe.io.Bytes.alloc(size), 0, size);
			} else {
				var cb = prepareCallback(ctx, arg(a, 2));
				size -> decodeBuffer(ctx, cb([VInt(size)]));
			};
			Luv.readStart(stream, allocate, callback);
			VNull;
		}));
		reg(st, "readStop", vfn(a -> encodeUnitResult(Luv.readStop(decodeStream(ctx, arg(a, 0))))));
		function writeCallback(v:EvalValue) {
			var cb = prepareCallback(ctx, v);
			return function(code:Int, written:Int) cb([encodeUnitResult(code), VInt(written)]);
		}
		reg(st, "write", vfn(a -> {
			var stream = decodeStream(ctx, arg(a, 0));
			var data = decodeBuffers(arg(a, 1));
			var callback = writeCallback(arg(a, 2));
			Luv.write(stream, data, null, callback);
			VNull;
		}));
		reg(st, "write2", vfn(a -> {
			var stream = decodeKind(ctx, arg(a, 0), HPipe, "eval.luv.Pipe");
			var data = decodeBuffers(arg(a, 1));
			var callback = writeCallback(arg(a, 3));
			var e = decodeEnum(ctx, arg(a, 2));
			var send = switch [e.index, e.args.length] {
				case [0, 1]: decodeKind(ctx, e.args[0], HTcp, "eval.luv.Tcp");
				case [1, 1]: decodeKind(ctx, e.args[0], HPipe, "eval.luv.Pipe");
				case _: EvalExceptions.unexpectedValue(ctx, arg(a, 2), "eval.luv.Stream.SendHandle");
			};
			Luv.write(stream, data, send, callback);
			VNull;
		}));
		reg(st, "tryWrite", vfn(a -> {
			var stream = decodeStream(ctx, arg(a, 0));
			var data = decodeBuffers(arg(a, 1));
			var r = Luv.tryWrite(stream, data);
			encodeResult(r, () -> VInt(r));
		}));
		reg(st, "isReadable", vfn(a -> EvalValueTools.vbool(Luv.isReadable(decodeStream(ctx, arg(a, 0))))));
		reg(st, "isWritable", vfn(a -> EvalValueTools.vbool(Luv.isWritable(decodeStream(ctx, arg(a, 0))))));
		reg(st, "setBlocking", vfn(a -> {
			var stream = decodeStream(ctx, arg(a, 0));
			var block = EvalStdLib.decodeBool(ctx, arg(a, 1));
			encodeUnitResult(Luv.setBlocking(stream, block));
		}));

		var tcp = "eval.luv._Tcp.Tcp_Impl_";
		inline function decodeTcp(v:EvalValue) return decodeKind(ctx, v, HTcp, "eval.luv.Tcp");
		reg(tcp, "init", vfn(a -> {
			var l = decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop");
			var domain = arg(a, 1) == VNull ? -1 : decodeAddressFamily(ctx, arg(a, 1));
			var t = Luv.newHandle(HTcp);
			encodeResult(Luv.tcpInit(l, t, domain), () -> handle(HTcp, t));
		}));
		reg(tcp, "noDelay", vfn(a -> {
			var t = decodeTcp(arg(a, 0));
			var value = EvalStdLib.decodeBool(ctx, arg(a, 1));
			encodeUnitResult(Luv.tcpNoDelay(t, value));
		}));
		reg(tcp, "keepAlive", vfn(a -> {
			var t = decodeTcp(arg(a, 0));
			var value = decodeOption(ctx, arg(a, 1), v -> EvalStdLib.decodeInt(ctx, v));
			encodeUnitResult(Luv.tcpKeepAlive(t, value));
		}));
		reg(tcp, "simultaneousAccepts", vfn(a -> {
			var t = decodeTcp(arg(a, 0));
			var value = EvalStdLib.decodeBool(ctx, arg(a, 1));
			encodeUnitResult(Luv.tcpSimultaneousAccepts(t, value));
		}));
		reg(tcp, "bind", vfn(a -> {
			var t = decodeTcp(arg(a, 0));
			var addr = decodeSockaddr(ctx, arg(a, 1));
			var ipv6only = decodeOptionalBool(ctx, arg(a, 2), false);
			encodeUnitResult(Luv.tcpBind(t, addr, ipv6only));
		}));
		for (n in [{name: "getSockName", peer: false}, {name: "getPeerName", peer: true}]) {
			var peer = n.peer;
			reg(tcp, n.name, vfn(a -> {
				var t = decodeTcp(arg(a, 0));
				var storage = LuvSys.newSockaddr();
				encodeResult(Luv.tcpName(t, peer, storage), () -> encodeSockaddr(storage));
			}));
		}
		reg(tcp, "connect", vfn(a -> {
			var t = decodeTcp(arg(a, 0));
			var addr = decodeSockaddr(ctx, arg(a, 1));
			Luv.tcpConnect(t, addr, unitCallback(ctx, arg(a, 2)));
			VNull;
		}));
		reg(tcp, "closeReset", vfn(a -> {
			var t = decodeTcp(arg(a, 0));
			Luv.tcpCloseReset(t, unitCallback(ctx, arg(a, 1)));
			VNull;
		}));

		for (n in ["SIGABRT", "SIGFPE", "SIGHUP", "SIGILL", "SIGINT", "SIGKILL", "SIGSEGV", "SIGTERM", "SIGWINCH"])
			reg("eval.luv._Signal.SigNum_Impl_", n, VInt(Luv.signum(n)));
		var sig = "eval.luv._Signal.Signal_Impl_";
		inline function decodeSignal(v:EvalValue) return decodeKind(ctx, v, HSignal, "eval.luv.Signal");
		reg(sig, "init", vfn(a -> {
			var l = decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop");
			var o = Luv.newHandle(HSignal);
			encodeResult(Luv.signalInit(l, o), () -> handle(HSignal, o));
		}));
		for (n in [{name: "start", oneshot: false}, {name: "startOneshot", oneshot: true}]) {
			var oneshot = n.oneshot;
			reg(sig, n.name, vfn(a -> {
				var o = decodeSignal(arg(a, 0));
				var signum = EvalStdLib.decodeInt(ctx, arg(a, 1));
				var cb = prepareCallback(ctx, arg(a, 2));
				encodeUnitResult(Luv.signalStart(o, signum, oneshot, () -> { cb([]); }));
			}));
		}
		reg(sig, "stop", vfn(a -> encodeUnitResult(Luv.signalStop(decodeSignal(arg(a, 0))))));
		reg(sig, "signum", vfn(a -> VInt(Luv.signalSignum(decodeSignal(arg(a, 0))))));
	}

	static function encodeOption(v:Null<EvalValue>):EvalValue {
		return v != null ? VEnumValue(new VEnumValue(0, [v], EvalHash.keyHaxeDsOption, null))
			: VEnumValue(new VEnumValue(1, [], EvalHash.keyHaxeDsOption, null));
	}

	static function initSockets(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		inline function reg(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);
		inline function bytesOf(v:EvalValue) return EvalStdLib.decodeString(ctx, v).toBytes();
		inline function nativeBytesOf(v:EvalValue) return EvalStdLib.decodeNativeString(ctx, v).toBytes();
		function decodeBuffers(v:EvalValue) return [for (x in EvalStdLib.decodeArray(ctx, v)) decodeBuffer(ctx, x)];
		inline function decodeUdp(v:EvalValue) return decodeKind(ctx, v, HUdp, "eval.luv.Udp");
		inline function decodePipe(v:EvalValue) return decodeKind(ctx, v, HPipe, "eval.luv.Pipe");
		inline function decodeLoop(v:EvalValue) return decodeKind(ctx, v, HLoop, "eval.luv.Loop");
		// 0 is LEAVE_GROUP, 1 JOIN_GROUP.
		function decodeMembership(v:EvalValue):Bool {
			return switch (EvalStdLib.decodeInt(ctx, v)) {
				case 0: false;
				case 1: true;
				case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Udp.UdpMembership");
			};
		}

		var udp = "eval.luv._Udp.Udp_Impl_";
		reg(udp, "init", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var domain = arg(a, 1) == VNull ? LuvSys.addressFamilyToC(0) : decodeAddressFamily(ctx, arg(a, 1));
			var recvmmsg = decodeOptionalBool(ctx, arg(a, 2), false);
			var u = Luv.newHandle(HUdp);
			encodeResult(Luv.udpInit(l, u, domain, recvmmsg), () -> handle(HUdp, u));
		}));
		reg(udp, "bind", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var addr = decodeSockaddr(ctx, arg(a, 1));
			var ipv6only = decodeOptionalBool(ctx, arg(a, 2), false);
			var reuseaddr = decodeOptionalBool(ctx, arg(a, 3), false);
			encodeUnitResult(Luv.udpBind(u, addr, ipv6only, reuseaddr));
		}));
		// The connected socket is the same handle
		reg(udp, "connect", vfn(a -> {
			var v = arg(a, 0);
			var u = decodeUdp(v);
			var addr = decodeSockaddr(ctx, arg(a, 1));
			encodeResult(Luv.udpConnect(u, addr), () -> handle(HUdp, u));
		}));
		reg(udp, "getSockName", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var storage = LuvSys.newSockaddr();
			encodeResult(Luv.udpName(u, false, storage), () -> encodeSockaddr(storage));
		}));
		reg(udp, "setMembership", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var group = bytesOf(arg(a, 1));
			var iface = bytesOf(arg(a, 2));
			var join = decodeMembership(arg(a, 3));
			encodeUnitResult(Luv.udpSetMembership(u, group, iface, join));
		}));
		reg(udp, "setSourceMembership", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var group = bytesOf(arg(a, 1));
			var iface = bytesOf(arg(a, 2));
			var source = bytesOf(arg(a, 3));
			var join = decodeMembership(arg(a, 4));
			encodeUnitResult(Luv.udpSetSourceMembership(u, group, iface, source, join));
		}));
		reg(udp, "setMulticastLoop", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var value = EvalStdLib.decodeBool(ctx, arg(a, 1));
			encodeUnitResult(Luv.udpSetMulticastLoop(u, value));
		}));
		reg(udp, "setMulticastTtl", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var value = EvalStdLib.decodeInt(ctx, arg(a, 1));
			encodeUnitResult(Luv.udpSetMulticastTtl(u, value));
		}));
		reg(udp, "setMulticastInterface", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var value = bytesOf(arg(a, 1));
			encodeUnitResult(Luv.udpSetMulticastInterface(u, value));
		}));
		reg(udp, "setBroadcast", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var value = EvalStdLib.decodeBool(ctx, arg(a, 1));
			encodeUnitResult(Luv.udpSetBroadcast(u, value));
		}));
		reg(udp, "setTtl", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var value = EvalStdLib.decodeInt(ctx, arg(a, 1));
			encodeUnitResult(Luv.udpSetTtl(u, value));
		}));
		reg(udp, "send", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var l = decodeBuffers(arg(a, 1));
			var addr = decodeSockaddr(ctx, arg(a, 2));
			Luv.udpSend(u, l, addr, unitCallback(ctx, arg(a, 3)));
			VNull;
		}));
		// A count is success.
		reg(udp, "trySend", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var l = decodeBuffers(arg(a, 1));
			var addr = decodeSockaddr(ctx, arg(a, 2));
			encodeUnitResult(Luv.udpTrySend(u, l, addr));
		}));
		reg(udp, "recvStart", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var v2 = arg(a, 1);
			var callback = function(code:Int, b:Null<LuvSys.LuvBuffer>, addr:Null<haxe.io.Bytes>, flags:Array<Int>) {
				var cb = prepareCallback(ctx, v2);
				cb([encodeResult(code, () -> obj([
					{name: "data", value: encodeBuffer(b)},
					{name: "addr", value: encodeOption(addr == null ? null : encodeSockaddr(addr))},
					{name: "flags", value: array([for (f in flags) VInt(f)])}
				]))]);
			};
			var allocate:Int->LuvSys.LuvBuffer = if (arg(a, 2) == VNull) {
				size -> new LuvSys.LuvBuffer(haxe.io.Bytes.alloc(size), 0, size);
			} else {
				var cb = prepareCallback(ctx, arg(a, 2));
				size -> decodeBuffer(ctx, cb([VInt(size)]));
			};
			Luv.udpRecvStart(u, allocate, callback);
			VNull;
		}));
		reg(udp, "recvStop", vfn(a -> encodeUnitResult(Luv.udpRecvStop(decodeUdp(arg(a, 0))))));
		reg(udp, "getSendQueueSize", vfn(a -> VInt(Luv.udpSendQueueSize(decodeUdp(arg(a, 0))))));
		reg(udp, "getSendQueueCount", vfn(a -> VInt(Luv.udpSendQueueCount(decodeUdp(arg(a, 0))))));

		// "send" is registered twice and the prototype keeps the second, the try-send; there is no trySend.
		var cudp = "eval.luv._ConnectedUdp.ConnectedUdp_Impl_";
		reg(cudp, "disconnect", vfn(a -> encodeUnitResult(Luv.udpConnect(decodeUdp(arg(a, 0)), null))));
		reg(cudp, "getPeerName", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var storage = LuvSys.newSockaddr();
			encodeResult(Luv.udpName(u, true, storage), () -> encodeSockaddr(storage));
		}));
		reg(cudp, "send", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var l = decodeBuffers(arg(a, 1));
			Luv.udpSend(u, l, null, unitCallback(ctx, arg(a, 2)));
			VNull;
		}));
		reg(cudp, "send", vfn(a -> {
			var u = decodeUdp(arg(a, 0));
			var l = decodeBuffers(arg(a, 1));
			encodeUnitResult(Luv.udpTrySend(u, l, null));
		}));

		var pipe = "eval.luv._Pipe.Pipe_Impl_";
		reg(pipe, "init", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var ipc = decodeOptionalBool(ctx, arg(a, 1), false);
			var p = Luv.newHandle(HPipe);
			encodeResult(Luv.pipeInit(l, p, ipc), () -> handle(HPipe, p));
		}));
		reg(pipe, "bind", vfn(a -> {
			var p = decodePipe(arg(a, 0));
			var name = nativeBytesOf(arg(a, 1));
			encodeUnitResult(Luv.pipeBind(p, name));
		}));
		reg(pipe, "connect", vfn(a -> {
			var p = decodePipe(arg(a, 0));
			var target = nativeBytesOf(arg(a, 1));
			Luv.pipeConnect(p, target, unitCallback(ctx, arg(a, 2)));
			VNull;
		}));
		for (n in [{name: "getSockName", peer: false}, {name: "getPeerName", peer: true}]) {
			var peer = n.peer;
			reg(pipe, n.name, vfn(a -> {
				var p = decodePipe(arg(a, 0));
				var out = [null];
				encodeResult(Luv.pipeName(p, peer, out), () -> nativeString(out[0]));
			}));
		}
		reg(pipe, "pendingInstances", vfn(a -> {
			var p = decodePipe(arg(a, 0));
			var amount = EvalStdLib.decodeInt(ctx, arg(a, 1));
			Luv.pipePendingInstances(p, amount);
			VNull;
		}));
		// Receives a handle; the associate function accepts into the handle it is given.
		var receiveHandlePath = EvalNames.hEvalLuvReceiveHandle();
		reg(pipe, "receiveHandle", vfn(a -> {
			var p = decodePipe(arg(a, 0));
			var kind = Luv.pipePendingCount(p) == 0 ? 0 : Luv.pipePendingKind(p);
			switch (kind) {
				case 1:
					VEnumValue(new VEnumValue(1, [vfn(b -> encodeUnitResult(Luv.accept(p, decodeKind(ctx, arg(b, 0), HTcp, "eval.luv.Tcp"))))], receiveHandlePath, null));
				case 2:
					VEnumValue(new VEnumValue(2, [vfn(b -> encodeUnitResult(Luv.accept(p, decodePipe(arg(b, 0)))))], receiveHandlePath, null));
				case _:
					VEnumValue(new VEnumValue(0, [], receiveHandlePath, null));
			}
		}));
		reg(pipe, "chmod", vfn(a -> {
			var p = decodePipe(arg(a, 0));
			var v2 = arg(a, 1);
			var mode = switch (EvalStdLib.decodeInt(ctx, v2)) {
				case 0: [true, false];
				case 1: [false, true];
				case 2: [true, true];
				case _: EvalExceptions.unexpectedValue(ctx, v2, "eval.luv.Pipe.PipeMode");
			};
			encodeUnitResult(Luv.pipeChmod(p, mode[0], mode[1]));
		}));

		var fse = "eval.luv._FsEvent.FsEvent_Impl_";
		inline function decodeFsEvent(v:EvalValue) return decodeKind(ctx, v, HFsEvent, "eval.luv.FsEvent");
		reg(fse, "init", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var e = Luv.newHandle(HFsEvent);
			encodeResult(Luv.fsEventInit(l, e), () -> handle(HFsEvent, e));
		}));
		reg(fse, "start", vfn(a -> {
			var e = decodeFsEvent(arg(a, 0));
			var path = nativeBytesOf(arg(a, 1));
			var v4 = arg(a, 3);
			var callback = function(code:Int, file:Null<haxe.io.Bytes>, events:Array<Int>) {
				var cb = prepareCallback(ctx, v4);
				cb([encodeResult(code, () -> obj([
					{name: "file", value: file == null ? VNull : nativeString(file)},
					{name: "events", value: array([for (x in events) VInt(x)])}
				]))]);
			};
			var flags = arg(a, 2) == VNull ? [] : [for (x in EvalStdLib.decodeArray(ctx, arg(a, 2))) EvalStdLib.decodeInt(ctx, x)];
			Luv.fsEventStart(e, path, flags.contains(0), flags.contains(1), flags.contains(2), callback);
			VNull;
		}));
		reg(fse, "stop", vfn(a -> encodeUnitResult(Luv.fsEventStop(decodeFsEvent(arg(a, 0))))));
	}

	static function decodeI64(ctx:EvalContext, v:EvalValue):haxe.Int64 {
		return switch (v) {
			case VInt64(b): b.v;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.integers.Int64");
		};
	}

	static function decodeSizeT(ctx:EvalContext, v:EvalValue):haxe.Int64 {
		return switch (v) {
			case VUInt64(b): b.v;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.integers.UInt64");
		};
	}

	static function num(ctx:EvalContext, v:EvalValue):Float {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f): f;
			case _: EvalExceptions.unexpectedValue(ctx, v, "number");
		};
	}

	// A file is its descriptor.
	static function decodeFile(ctx:EvalContext, v:EvalValue):Int {
		return switch (v) {
			case VHandle(h) if (h.kind == HFile): h.native;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.File");
		};
	}

	static function encodeFile(fd:Int):EvalValue return VHandle(new EvalHandle(HFile, fd));

	// Each mode as its C value, the list or'ed.
	static function decodeFileModeList(ctx:EvalContext, v:EvalValue):Int {
		var mode = 0;
		for (x in EvalStdLib.decodeArray(ctx, v)) {
			var e = decodeEnum(ctx, x);
			mode |= switch [e.index, e.args.length] {
				case [i, 0] if (i >= 0 && i <= 21): Luv.fileMode(i);
				case [22, 1]: EvalStdLib.decodeInt(ctx, e.args[0]);
				case _: EvalExceptions.unexpectedValue(ctx, x, "eval.luv.File.FileMode");
			};
		}
		return mode;
	}

	static function decodeFileRequest(ctx:EvalContext, v:EvalValue):LuvObject {
		return switch (v) {
			case VHandle(h) if (h.kind == HFileRequest): h.native;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.File.FileRequest");
		};
	}

	static function decodeDir(ctx:EvalContext, v:EvalValue):LuvObject {
		return switch (v) {
			case VHandle(h) if (h.kind == HDir): h.native;
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Dir");
		};
	}

	static function encodeTimespec(s:haxe.io.Bytes, which:Int):EvalValue {
		return obj([
			{name: "sec", value: i64(Luv.statTime(s, which, false))},
			{name: "nsec", value: i64(Luv.statTime(s, which, true))}
		]);
	}

	static function encodeFileStat(s:haxe.io.Bytes):EvalValue {
		return obj([
			{name: "dev", value: u64(Luv.statField(s, 0))},
			{name: "mode", value: VHandle(new EvalHandle(HFileModeNumeric, haxe.Int64.toInt(Luv.statField(s, 1))))},
			{name: "nlink", value: u64(Luv.statField(s, 2))},
			{name: "uid", value: u64(Luv.statField(s, 3))},
			{name: "gid", value: u64(Luv.statField(s, 4))},
			{name: "rdev", value: u64(Luv.statField(s, 5))},
			{name: "ino", value: u64(Luv.statField(s, 6))},
			{name: "size", value: u64(Luv.statField(s, 7))},
			{name: "blksize", value: u64(Luv.statField(s, 8))},
			{name: "blocks", value: u64(Luv.statField(s, 9))},
			{name: "flags", value: u64(Luv.statField(s, 10))},
			{name: "gen", value: u64(Luv.statField(s, 11))},
			{name: "atim", value: encodeTimespec(s, 0)},
			{name: "mtim", value: encodeTimespec(s, 1)},
			{name: "ctim", value: encodeTimespec(s, 2)},
			{name: "birthtim", value: encodeTimespec(s, 3)}
		]);
	}

	static function encodeFileStatfs(s:haxe.io.Bytes):EvalValue {
		return obj([
			{name: "type", value: u64(Luv.statfsField(s, 0))},
			{name: "bsize", value: u64(Luv.statfsField(s, 1))},
			{name: "blocks", value: u64(Luv.statfsField(s, 2))},
			{name: "bfree", value: u64(Luv.statfsField(s, 3))},
			{name: "bavail", value: u64(Luv.statfsField(s, 4))},
			{name: "files", value: u64(Luv.statfsField(s, 5))},
			{name: "ffree", value: u64(Luv.statfsField(s, 6))},
			{name: "fspare", value: array([for (i in 7...11) u64(Luv.statfsField(s, i))])}
		]);
	}

	static function encodeDirent(d:FsDirent):EvalValue {
		return obj([{name: "kind", value: VInt(d.kind)}, {name: "name", value: nativeString(d.name)}]);
	}

	static function encodeScandir(req:LuvObject):EvalValue {
		return obj([
			{name: "next", value: vfn(_ -> {
				var d = Luv.scandirNext(req);
				d == null ? VNull : encodeDirent(d);
			})},
			{name: "end", value: vfn(_ -> {
				Luv.scandirEnd(req);
				VNull;
			})}
		]);
	}

	static function encodeFsResult(r:FsResult, ok:Dynamic->EvalValue):EvalValue
		return encodeResult(r.code, () -> ok(r.value));

	static function initFiles(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		inline function reg(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);
		inline function nativeBytesOf(v:EvalValue) return EvalStdLib.decodeNativeString(ctx, v).toBytes();
		function decodeBuffers(v:EvalValue) return [for (x in EvalStdLib.decodeArray(ctx, v)) decodeBuffer(ctx, x)];
		inline function decodeLoop(v:EvalValue) return decodeKind(ctx, v, HLoop, "eval.luv.Loop");
		// The loop, then the request.
		function async(vloop:EvalValue, vrequest:EvalValue):{loop:LuvObject, request:Null<LuvObject>} {
			var l = decodeLoop(vloop);
			var r = vrequest == VNull ? null : decodeFileRequest(ctx, vrequest);
			return {loop: l, request: r};
		}
		// Prepared when the result arrives.
		function callback(v:EvalValue, ok:Dynamic->EvalValue):FsResult->Void {
			return function(r:FsResult) {
				var cb = prepareCallback(ctx, v);
				cb([encodeFsResult(r, ok)]);
			};
		}
		function unit(_:Dynamic):EvalValue return VNull;
		function sizeT(n:Dynamic):EvalValue return u64(n);
		function none() {}
		// The default mode: 0o644 for a file, 0o755 for a directory.
		function modeOpt(v:EvalValue, d:Int):Int return v == VNull ? d : decodeFileModeList(ctx, v);
		// F.open_: the flags, then the mode, then the path
		function openArgs(vpath:EvalValue, vflags:EvalValue, vmode:EvalValue) {
			var flags = 0;
			for (x in EvalStdLib.decodeArray(ctx, vflags)) {
				var i = EvalStdLib.decodeInt(ctx, x);
				if (i < 0 || i > 20) EvalExceptions.unexpectedValue(ctx, x, "eval.luv.File.FileOpenFlag");
				flags |= Luv.openFlag(i);
			}
			var mode = modeOpt(vmode, 420);
			var path = nativeBytesOf(vpath);
			return {flags: flags, mode: mode, path: path};
		}
		// F.data: the file, the offset, the buffers; the iovecs and buffers live to the clean-up
		function dataArgs(vfile:EvalValue, voffset:EvalValue, vbuffers:EvalValue) {
			var file = decodeFile(ctx, vfile);
			var offset = decodeI64(ctx, voffset);
			var buffers = decodeBuffers(vbuffers);
			return {file: file, offset: offset, buffers: buffers};
		}
		function readWrite(write:Bool, l:Null<LuvObject>, d:{file:Int, offset:haxe.Int64, buffers:Array<LuvSys.LuvBuffer>}) {
			var iov = Luv.fsBufs(d.buffers);
			var keep:Array<Dynamic> = [d.buffers];
			return {
				run: (r:LuvObject) -> Luv.fsReadWrite(l, r, write, d.file, iov, d.buffers.length, d.offset),
				cleanup: () -> {
					keep[0] = null;
					Luv.fsFree(iov);
				}
			};
		}
		// F.copyFile: the flags, then the paths
		function copyFlags(v:EvalValue):Int {
			var flags = decodeIntFlags(ctx, v);
			return Luv.copyFlags(flags.contains(0), flags.contains(1), flags.contains(2));
		}
		// F.access: the flags, then the path
		function accessFlags(v:EvalValue):Int {
			var mode = 0;
			for (x in EvalStdLib.decodeArray(ctx, v)) {
				var i = EvalStdLib.decodeInt(ctx, x);
				if (i < 0 || i > 3) EvalExceptions.unexpectedValue(ctx, x, "eval.luv.File.FileAccessFlag");
				mode |= Luv.accessFlag(i);
			}
			return mode;
		}
		function symlinkFlags(v:EvalValue):Int {
			var flags = decodeIntFlags(ctx, v);
			return Luv.symlinkFlags(flags.contains(0), flags.contains(1));
		}
		function mkstemp(v:Dynamic):EvalValue {
			var pf:FsPathFile = v;
			return obj([{name: "name", value: nativeString(pf.path)}, {name: "file", value: encodeFile(pf.file)}]);
		}
		function dirents(v:Dynamic):EvalValue {
			var a:Array<FsDirent> = v;
			return array([for (d in a) encodeDirent(d)]);
		}

		var file = "eval.luv._File.File_Impl_";
		reg(file, "stdin", encodeFile(0));
		reg(file, "stdout", encodeFile(1));
		reg(file, "stderr", encodeFile(2));
		reg(file, "createRequest", vfn(_ -> VHandle(new EvalHandle(HFileRequest, Luv.newFsRequest()))));
		// Every bit of the mask is set.
		reg(file, "testMode", vfn(a -> {
			var mask = decodeFileModeList(ctx, arg(a, 0));
			var v2 = arg(a, 1);
			var bits:Int = switch (v2) {
				case VHandle(h) if (h.kind == HFileModeNumeric): h.native;
				case _: EvalExceptions.unexpectedValue(ctx, v2, "eval.luv.File.FileModeNumeric");
			};
			EvalValueTools.vbool((mask & bits) == mask);
		}));
		reg(file, "open", vfn(a -> {
			var cb = callback(arg(a, 5), fd -> encodeFile(fd));
			var x = async(arg(a, 0), arg(a, 4));
			var o = openArgs(arg(a, 1), arg(a, 2), arg(a, 3));
			Luv.fsAsync(x.request, Luv.FS_FILE, r -> Luv.fsOpen(x.loop, r, o.path, o.flags, o.mode), none, cb);
			VNull;
		}));
		// Op: 0 close, 1 fsync, 2 fdatasync, 3 fstat
		for (n in [{name: "close", op: 0, kind: Luv.FS_ERROR}, {name: "fsync", op: 1, kind: Luv.FS_ERROR},
				{name: "fdataSync", op: 2, kind: Luv.FS_ERROR}, {name: "fstat", op: 3, kind: Luv.FS_STAT}]) {
			var op = n.op;
			var kind = n.kind;
			reg(file, n.name, vfn(a -> {
				var cb = callback(arg(a, 3), kind == Luv.FS_STAT ? v -> encodeFileStat(v) : unit);
				var x = async(arg(a, 1), arg(a, 2));
				var fd = decodeFile(ctx, arg(a, 0));
				Luv.fsAsync(x.request, kind, r -> Luv.fsFileOp(x.loop, r, op, fd), none, cb);
				VNull;
			}));
		}
		for (n in [{name: "read", write: false}, {name: "write", write: true}]) {
			var write = n.write;
			reg(file, n.name, vfn(a -> {
				var cb = callback(arg(a, 5), sizeT);
				var x = async(arg(a, 1), arg(a, 4));
				var d = dataArgs(arg(a, 0), arg(a, 2), arg(a, 3));
				var rw = readWrite(write, x.loop, d);
				Luv.fsAsync(x.request, Luv.FS_BYTES, rw.run, rw.cleanup, cb);
				VNull;
			}));
		}
		// Op: 0 unlink, 1 rmdir, 2 mkdtemp, 3 mkstemp, 5 stat, 6 lstat, 7 statfs, 8 readlink, 9 realpath
		for (n in [{name: "unlink", op: 0, kind: Luv.FS_ERROR}, {name: "rmdir", op: 1, kind: Luv.FS_ERROR},
				{name: "mkdtemp", op: 2, kind: Luv.FS_PATH}, {name: "mkstemp", op: 3, kind: Luv.FS_PATH_FILE},
				{name: "stat", op: 5, kind: Luv.FS_STAT}, {name: "lstat", op: 6, kind: Luv.FS_STAT},
				{name: "statFs", op: 7, kind: Luv.FS_STATFS}, {name: "readLink", op: 8, kind: Luv.FS_STRING},
				{name: "realPath", op: 9, kind: Luv.FS_STRING}]) {
			var op = n.op;
			var kind = n.kind;
			var ok:Dynamic->EvalValue = switch (kind) {
				case Luv.FS_PATH | Luv.FS_STRING: v -> nativeString(v);
				case Luv.FS_PATH_FILE: mkstemp;
				case Luv.FS_STAT: v -> encodeFileStat(v);
				case Luv.FS_STATFS: v -> encodeFileStatfs(v);
				case _: unit;
			};
			reg(file, n.name, vfn(a -> {
				var cb = callback(arg(a, 3), ok);
				var x = async(arg(a, 0), arg(a, 2));
				var path = nativeBytesOf(arg(a, 1));
				Luv.fsAsync(x.request, kind, r -> Luv.fsPathOp(x.loop, r, op, path), none, cb);
				VNull;
			}));
		}
		reg(file, "rename", vfn(a -> {
			var cb = callback(arg(a, 4), unit);
			var x = async(arg(a, 0), arg(a, 3));
			var path = nativeBytesOf(arg(a, 1));
			var to = nativeBytesOf(arg(a, 2));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsTwoPaths(x.loop, r, 0, path, to, 0), none, cb);
			VNull;
		}));
		reg(file, "mkdir", vfn(a -> {
			var cb = callback(arg(a, 4), unit);
			var x = async(arg(a, 0), arg(a, 3));
			var mode = modeOpt(arg(a, 2), 493);
			var path = nativeBytesOf(arg(a, 1));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsMkdir(x.loop, r, path, mode), none, cb);
			VNull;
		}));
		reg(file, "ftruncate", vfn(a -> {
			var cb = callback(arg(a, 4), unit);
			var x = async(arg(a, 1), arg(a, 3));
			var fd = decodeFile(ctx, arg(a, 0));
			var length = decodeI64(ctx, arg(a, 2));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsFtruncate(x.loop, r, fd, length), none, cb);
			VNull;
		}));
		reg(file, "copyFile", vfn(a -> {
			var cb = callback(arg(a, 5), unit);
			var x = async(arg(a, 0), arg(a, 4));
			var flags = copyFlags(arg(a, 3));
			var path = nativeBytesOf(arg(a, 1));
			var to = nativeBytesOf(arg(a, 2));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsTwoPaths(x.loop, r, 3, path, to, flags), none, cb);
			VNull;
		}));
		// F.sendFile: to, offset, length, then the file
		reg(file, "sendFile", vfn(a -> {
			var cb = callback(arg(a, 6), sizeT);
			var x = async(arg(a, 1), arg(a, 5));
			var to = decodeFile(ctx, arg(a, 2));
			var offset = decodeI64(ctx, arg(a, 3));
			var length = decodeSizeT(ctx, arg(a, 4));
			var fd = decodeFile(ctx, arg(a, 0));
			Luv.fsAsync(x.request, Luv.FS_BYTES, r -> Luv.fsSendfile(x.loop, r, to, fd, offset, length), none, cb);
			VNull;
		}));
		reg(file, "access", vfn(a -> {
			var cb = callback(arg(a, 4), unit);
			var x = async(arg(a, 0), arg(a, 3));
			var mode = accessFlags(arg(a, 2));
			var path = nativeBytesOf(arg(a, 1));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsAccess(x.loop, r, path, mode), none, cb);
			VNull;
		}));
		reg(file, "chmod", vfn(a -> {
			var cb = callback(arg(a, 4), unit);
			var x = async(arg(a, 0), arg(a, 3));
			var path = nativeBytesOf(arg(a, 1));
			var mode = decodeFileModeList(ctx, arg(a, 2));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsChmod(x.loop, r, path, 0, mode), none, cb);
			VNull;
		}));
		reg(file, "fchmod", vfn(a -> {
			var cb = callback(arg(a, 4), unit);
			var x = async(arg(a, 1), arg(a, 3));
			var fd = decodeFile(ctx, arg(a, 0));
			var mode = decodeFileModeList(ctx, arg(a, 2));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsChmod(x.loop, r, null, fd, mode), none, cb);
			VNull;
		}));
		// Op: 0 utime (a path), 2 lutime (a path), 1 futime (a file); F.utime: atime, then mtime
		for (n in [{name: "utime", op: 0}, {name: "lutime", op: 2}]) {
			var op = n.op;
			reg(file, n.name, vfn(a -> {
				var cb = callback(arg(a, 5), unit);
				var x = async(arg(a, 0), arg(a, 4));
				var path = nativeBytesOf(arg(a, 1));
				var atime = num(ctx, arg(a, 2));
				var mtime = num(ctx, arg(a, 3));
				Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsUtime(x.loop, r, op, path, 0, atime, mtime), none, cb);
				VNull;
			}));
		}
		reg(file, "futime", vfn(a -> {
			var cb = callback(arg(a, 5), unit);
			var x = async(arg(a, 1), arg(a, 4));
			var fd = decodeFile(ctx, arg(a, 0));
			var atime = num(ctx, arg(a, 2));
			var mtime = num(ctx, arg(a, 3));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsUtime(x.loop, r, 1, null, fd, atime, mtime), none, cb);
			VNull;
		}));
		reg(file, "link", vfn(a -> {
			var cb = callback(arg(a, 4), unit);
			var x = async(arg(a, 0), arg(a, 3));
			var path = nativeBytesOf(arg(a, 1));
			var link = nativeBytesOf(arg(a, 2));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsTwoPaths(x.loop, r, 1, path, link, 0), none, cb);
			VNull;
		}));
		// The flags, the path, the link
		reg(file, "symlink", vfn(a -> {
			var cb = callback(arg(a, 5), unit);
			var x = async(arg(a, 0), arg(a, 4));
			var flags = symlinkFlags(arg(a, 3));
			var path = nativeBytesOf(arg(a, 1));
			var link = nativeBytesOf(arg(a, 2));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsTwoPaths(x.loop, r, 2, path, link, flags), none, cb);
			VNull;
		}));
		// Op: 0 chown, 2 lchown (a path), 1 fchown (a file); F.chown: uid, then gid
		for (n in [{name: "chown", op: 0}, {name: "lchown", op: 2}]) {
			var op = n.op;
			reg(file, n.name, vfn(a -> {
				var cb = callback(arg(a, 5), unit);
				var x = async(arg(a, 0), arg(a, 4));
				var path = nativeBytesOf(arg(a, 1));
				var uid = EvalStdLib.decodeInt(ctx, arg(a, 2));
				var gid = EvalStdLib.decodeInt(ctx, arg(a, 3));
				Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsChown(x.loop, r, op, path, 0, uid, gid), none, cb);
				VNull;
			}));
		}
		reg(file, "fchown", vfn(a -> {
			var cb = callback(arg(a, 5), unit);
			var x = async(arg(a, 1), arg(a, 4));
			var fd = decodeFile(ctx, arg(a, 0));
			var uid = EvalStdLib.decodeInt(ctx, arg(a, 2));
			var gid = EvalStdLib.decodeInt(ctx, arg(a, 3));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsChown(x.loop, r, 1, null, fd, uid, gid), none, cb);
			VNull;
		}));
		reg(file, "toInt", vfn(a -> VInt(decodeFile(ctx, arg(a, 0)))));

		var fsync = "eval.luv.FileSync";
		function sync(kind:Int, run:LuvObject->Int, ok:Dynamic->EvalValue, ?cleanup:Void->Void):EvalValue
			return encodeFsResult(Luv.fsSync(kind, run, cleanup == null ? none : cleanup), ok);
		reg(fsync, "open", vfn(a -> {
			var o = openArgs(arg(a, 0), arg(a, 1), arg(a, 2));
			sync(Luv.FS_FILE, r -> Luv.fsOpen(null, r, o.path, o.flags, o.mode), fd -> encodeFile(fd));
		}));
		for (n in [{name: "close", op: 0, kind: Luv.FS_ERROR}, {name: "fsync", op: 1, kind: Luv.FS_ERROR},
				{name: "fdataSync", op: 2, kind: Luv.FS_ERROR}, {name: "fstat", op: 3, kind: Luv.FS_STAT}]) {
			var op = n.op;
			var kind = n.kind;
			reg(fsync, n.name, vfn(a -> {
				var fd = decodeFile(ctx, arg(a, 0));
				sync(kind, r -> Luv.fsFileOp(null, r, op, fd), kind == Luv.FS_STAT ? v -> encodeFileStat(v) : unit);
			}));
		}
		for (n in [{name: "read", write: false}, {name: "write", write: true}]) {
			var write = n.write;
			reg(fsync, n.name, vfn(a -> {
				var d = dataArgs(arg(a, 0), arg(a, 1), arg(a, 2));
				var rw = readWrite(write, null, d);
				sync(Luv.FS_BYTES, rw.run, sizeT, rw.cleanup);
			}));
		}
		for (n in [{name: "unlink", op: 0, kind: Luv.FS_ERROR}, {name: "rmdir", op: 1, kind: Luv.FS_ERROR},
				{name: "mkdtemp", op: 2, kind: Luv.FS_PATH}, {name: "mkstemp", op: 3, kind: Luv.FS_PATH_FILE},
				{name: "stat", op: 5, kind: Luv.FS_STAT}, {name: "lstat", op: 6, kind: Luv.FS_STAT},
				{name: "statFs", op: 7, kind: Luv.FS_STATFS}, {name: "readLink", op: 8, kind: Luv.FS_STRING},
				{name: "realPath", op: 9, kind: Luv.FS_STRING}]) {
			var op = n.op;
			var kind = n.kind;
			var ok:Dynamic->EvalValue = switch (kind) {
				case Luv.FS_PATH | Luv.FS_STRING: v -> nativeString(v);
				case Luv.FS_PATH_FILE: mkstemp;
				case Luv.FS_STAT: v -> encodeFileStat(v);
				case Luv.FS_STATFS: v -> encodeFileStatfs(v);
				case _: unit;
			};
			reg(fsync, n.name, vfn(a -> {
				var path = nativeBytesOf(arg(a, 0));
				sync(kind, r -> Luv.fsPathOp(null, r, op, path), ok);
			}));
		}
		reg(fsync, "rename", vfn(a -> {
			var path = nativeBytesOf(arg(a, 0));
			var to = nativeBytesOf(arg(a, 1));
			sync(Luv.FS_ERROR, r -> Luv.fsTwoPaths(null, r, 0, path, to, 0), unit);
		}));
		reg(fsync, "mkdir", vfn(a -> {
			var mode = modeOpt(arg(a, 1), 493);
			var path = nativeBytesOf(arg(a, 0));
			sync(Luv.FS_ERROR, r -> Luv.fsMkdir(null, r, path, mode), unit);
		}));
		reg(fsync, "ftruncate", vfn(a -> {
			var fd = decodeFile(ctx, arg(a, 0));
			var length = decodeI64(ctx, arg(a, 1));
			sync(Luv.FS_ERROR, r -> Luv.fsFtruncate(null, r, fd, length), unit);
		}));
		reg(fsync, "copyFile", vfn(a -> {
			var flags = copyFlags(arg(a, 2));
			var path = nativeBytesOf(arg(a, 0));
			var to = nativeBytesOf(arg(a, 1));
			sync(Luv.FS_ERROR, r -> Luv.fsTwoPaths(null, r, 3, path, to, flags), unit);
		}));
		reg(fsync, "sendFile", vfn(a -> {
			var to = decodeFile(ctx, arg(a, 1));
			var offset = decodeI64(ctx, arg(a, 2));
			var length = decodeSizeT(ctx, arg(a, 3));
			var fd = decodeFile(ctx, arg(a, 0));
			sync(Luv.FS_BYTES, r -> Luv.fsSendfile(null, r, to, fd, offset, length), sizeT);
		}));
		reg(fsync, "access", vfn(a -> {
			var mode = accessFlags(arg(a, 1));
			var path = nativeBytesOf(arg(a, 0));
			sync(Luv.FS_ERROR, r -> Luv.fsAccess(null, r, path, mode), unit);
		}));
		reg(fsync, "chmod", vfn(a -> {
			var path = nativeBytesOf(arg(a, 0));
			var mode = decodeFileModeList(ctx, arg(a, 1));
			sync(Luv.FS_ERROR, r -> Luv.fsChmod(null, r, path, 0, mode), unit);
		}));
		reg(fsync, "fchmod", vfn(a -> {
			var fd = decodeFile(ctx, arg(a, 0));
			var mode = decodeFileModeList(ctx, arg(a, 1));
			sync(Luv.FS_ERROR, r -> Luv.fsChmod(null, r, null, fd, mode), unit);
		}));
		for (n in [{name: "utime", op: 0}, {name: "lutime", op: 2}]) {
			var op = n.op;
			reg(fsync, n.name, vfn(a -> {
				var path = nativeBytesOf(arg(a, 0));
				var atime = num(ctx, arg(a, 1));
				var mtime = num(ctx, arg(a, 2));
				sync(Luv.FS_ERROR, r -> Luv.fsUtime(null, r, op, path, 0, atime, mtime), unit);
			}));
		}
		reg(fsync, "futime", vfn(a -> {
			var fd = decodeFile(ctx, arg(a, 0));
			var atime = num(ctx, arg(a, 1));
			var mtime = num(ctx, arg(a, 2));
			sync(Luv.FS_ERROR, r -> Luv.fsUtime(null, r, 1, null, fd, atime, mtime), unit);
		}));
		reg(fsync, "link", vfn(a -> {
			var path = nativeBytesOf(arg(a, 0));
			var link = nativeBytesOf(arg(a, 1));
			sync(Luv.FS_ERROR, r -> Luv.fsTwoPaths(null, r, 1, path, link, 0), unit);
		}));
		reg(fsync, "symlink", vfn(a -> {
			var flags = symlinkFlags(arg(a, 2));
			var path = nativeBytesOf(arg(a, 0));
			var link = nativeBytesOf(arg(a, 1));
			sync(Luv.FS_ERROR, r -> Luv.fsTwoPaths(null, r, 2, path, link, flags), unit);
		}));
		for (n in [{name: "chown", op: 0}, {name: "lchown", op: 2}]) {
			var op = n.op;
			reg(fsync, n.name, vfn(a -> {
				var path = nativeBytesOf(arg(a, 0));
				var uid = EvalStdLib.decodeInt(ctx, arg(a, 1));
				var gid = EvalStdLib.decodeInt(ctx, arg(a, 2));
				sync(Luv.FS_ERROR, r -> Luv.fsChown(null, r, op, path, 0, uid, gid), unit);
			}));
		}
		reg(fsync, "fchown", vfn(a -> {
			var fd = decodeFile(ctx, arg(a, 0));
			var uid = EvalStdLib.decodeInt(ctx, arg(a, 1));
			var gid = EvalStdLib.decodeInt(ctx, arg(a, 2));
			sync(Luv.FS_ERROR, r -> Luv.fsChown(null, r, 1, null, fd, uid, gid), unit);
		}));

		var dir = "eval.luv._Dir.Dir_Impl_";
		function encodeDir(v:Dynamic):EvalValue return VHandle(new EvalHandle(HDir, v));
		// F.readdir: the count (1024 by default), then the directory; its entries live to the clean-up
		function readdir(vcount:EvalValue, vdir:EvalValue, l:Null<LuvObject>) {
			var count = vcount == VNull ? 1024 : EvalStdLib.decodeInt(ctx, vcount);
			var d = decodeDir(ctx, vdir);
			var ents = Luv.fsDirents(d, count);
			return {run: (r:LuvObject) -> Luv.fsReaddir(l, r, d), cleanup: () -> Luv.fsFree(ents)};
		}
		reg(dir, "open", vfn(a -> {
			var cb = callback(arg(a, 3), encodeDir);
			var x = async(arg(a, 0), arg(a, 2));
			var path = nativeBytesOf(arg(a, 1));
			Luv.fsAsync(x.request, Luv.FS_DIR, r -> Luv.fsPathOp(x.loop, r, 4, path), none, cb);
			VNull;
		}));
		reg(dir, "close", vfn(a -> {
			var cb = callback(arg(a, 3), unit);
			var x = async(arg(a, 1), arg(a, 2));
			var d = decodeDir(ctx, arg(a, 0));
			Luv.fsAsync(x.request, Luv.FS_ERROR, r -> Luv.fsClosedir(x.loop, r, d), none, cb);
			VNull;
		}));
		reg(dir, "read", vfn(a -> {
			var cb = callback(arg(a, 4), dirents);
			var x = async(arg(a, 1), arg(a, 3));
			var rd = readdir(arg(a, 2), arg(a, 0), x.loop);
			Luv.fsAsync(x.request, Luv.FS_DIRENTS, rd.run, rd.cleanup, cb);
			VNull;
		}));
		reg(dir, "scan", vfn(a -> {
			var cb = callback(arg(a, 3), v -> encodeScandir(v));
			var x = async(arg(a, 0), arg(a, 2));
			var path = nativeBytesOf(arg(a, 1));
			Luv.fsAsync(x.request, Luv.FS_SCAN, r -> Luv.fsPathOp(x.loop, r, 10, path), none, cb);
			VNull;
		}));
		var dsync = "eval.luv.DirSync";
		reg(dsync, "open", vfn(a -> {
			var path = nativeBytesOf(arg(a, 0));
			sync(Luv.FS_DIR, r -> Luv.fsPathOp(null, r, 4, path), encodeDir);
		}));
		reg(dsync, "close", vfn(a -> {
			var d = decodeDir(ctx, arg(a, 0));
			sync(Luv.FS_ERROR, r -> Luv.fsClosedir(null, r, d), unit);
		}));
		reg(dsync, "read", vfn(a -> {
			var rd = readdir(arg(a, 1), arg(a, 0), null);
			sync(Luv.FS_DIRENTS, rd.run, dirents, rd.cleanup);
		}));
		reg(dsync, "scan", vfn(a -> {
			var path = nativeBytesOf(arg(a, 0));
			sync(Luv.FS_SCAN, r -> Luv.fsPathOp(null, r, 10, path), v -> encodeScandir(v));
		}));

		var fsp = "eval.luv._FsPoll.FsPoll_Impl_";
		reg(fsp, "init", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var p = Luv.newHandle(HFsPoll);
			encodeResult(Luv.fsPollInit(l, p), () -> handle(HFsPoll, p));
		}));
		reg(fsp, "start", vfn(a -> {
			var p = decodeKind(ctx, arg(a, 0), HFsPoll, "eval.luv.FsPoll");
			var path = nativeBytesOf(arg(a, 1));
			var interval = arg(a, 2) == VNull ? 2000 : EvalStdLib.decodeInt(ctx, arg(a, 2));
			var v4 = arg(a, 3);
			Luv.fsPollStart(p, path, interval, function(code:Int, prev:Null<haxe.io.Bytes>, curr:Null<haxe.io.Bytes>) {
				var cb = prepareCallback(ctx, v4);
				cb([encodeResult(code, () -> obj([
					{name: "previous", value: encodeFileStat(prev)},
					{name: "current", value: encodeFileStat(curr)}
				]))]);
			});
			VNull;
		}));
		reg(fsp, "stop", vfn(a -> encodeUnitResult(Luv.fsPollStop(decodeKind(ctx, arg(a, 0), HFsPoll, "eval.luv.FsPoll")))));

		var tty = "eval.luv._Tty.Tty_Impl_";
		reg(tty, "init", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var fd = decodeFile(ctx, arg(a, 1));
			var t = Luv.newHandle(HTty);
			encodeResult(Luv.ttyInit(l, t, fd), () -> handle(HTty, t));
		}));
		reg(tty, "setMode", vfn(a -> {
			var t = decodeKind(ctx, arg(a, 0), HTty, "eval.luv.Tty");
			var v2 = arg(a, 1);
			var mode = EvalStdLib.decodeInt(ctx, v2);
			if (mode < 0 || mode > 2) EvalExceptions.unexpectedValue(ctx, v2, "eval.luv.Tty.TtyMode");
			encodeUnitResult(Luv.ttySetMode(t, mode));
		}));
		reg(tty, "resetMode", vfn(_ -> encodeUnitResult(Luv.ttyResetMode())));
		reg(tty, "getWinSize", vfn(a -> {
			var t = decodeKind(ctx, arg(a, 0), HTty, "eval.luv.Tty");
			var out = [0, 0];
			var r = Luv.ttyWinSize(t, out);
			encodeResult(r, () -> obj([{name: "width", value: VInt(out[0])}, {name: "height", value: VInt(out[1])}]));
		}));
		reg(tty, "setVTermState", vfn(a -> {
			var v = arg(a, 0);
			var state = EvalStdLib.decodeInt(ctx, v);
			if (state < 0 || state > 1) EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Tty.VTermState");
			Luv.ttySetVtermState(state == 0);
			VNull;
		}));
		reg(tty, "getVTermState", vfn(_ -> {
			var out = [0];
			var r = Luv.ttyGetVtermState(out);
			encodeResult(r, () -> VInt(out[0]));
		}));

	}

	static function decodeIntFlags(ctx:EvalContext, v:EvalValue):Array<Int>
		return v == VNull ? [] : [for (x in EvalStdLib.decodeArray(ctx, v)) EvalStdLib.decodeInt(ctx, x)];

	static function decodeSocketType(ctx:EvalContext, v:EvalValue):Int {
		var e = decodeEnum(ctx, v);
		return switch [e.index, e.args.length] {
			case [0, 0] | [1, 0] | [2, 0]: Luv.socketTypeToC(e.index);
			case [3, 1]: EvalStdLib.decodeInt(ctx, e.args[0]);
			case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.SockAddr.SocketType");
		};
	}

	static function encodeAddressFamily(af:Int):EvalValue {
		var i = Luv.addressFamilyFromC(af);
		return VEnumValue(new VEnumValue(i, i == 3 ? [VInt(af)] : [], EvalNames.hEvalLuvAddressFamily(), null));
	}

	static function encodeSocketType(st:Int):EvalValue {
		var i = Luv.socketTypeFromC(st);
		return VEnumValue(new VEnumValue(i, i == 3 ? [VInt(st)] : [], EvalNames.hEvalLuvSocketType(), null));
	}

	// A missing field reads as null.
	static function optionField(ctx:EvalContext, o:EvalValue, name:String):EvalValue {
		return switch (o) {
			case VObject(_): EvalField.dynamicField(ctx, o, EvalHash.hash(name));
			case _: EvalExceptions.unexpectedValue(ctx, o, "object");
		};
	}

	static function initRequests(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		inline function reg(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);
		inline function bytesOf(v:EvalValue) return EvalStdLib.decodeString(ctx, v).toBytes();
		inline function nativeBytesOf(v:EvalValue) return EvalStdLib.decodeNativeString(ctx, v).toBytes();
		inline function decodeLoop(v:EvalValue) return decodeKind(ctx, v, HLoop, "eval.luv.Loop");

		reg("eval.luv.Random", "createRequest", vfn(_ -> VHandle(new EvalHandle(HRandomRequest, Luv.newRandomRequest()))));
		reg("eval.luv.Random", "random", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var b = decodeBuffer(ctx, arg(a, 1));
			var v3 = arg(a, 2);
			var request = v3 == VNull ? null : switch (v3) {
				case VHandle(h) if (h.kind == HRandomRequest): (h.native : LuvObject);
				case _: EvalExceptions.unexpectedValue(ctx, v3, "eval.luv.Random.RandomRequest");
			};
			Luv.randomAsync(l, request, b, unitCallback(ctx, arg(a, 3)));
			VNull;
		}));

		reg("eval.luv._Request.Request_Impl_", "cancel", vfn(a -> {
			var v = arg(a, 0);
			encodeUnitResult(switch (v) {
				case VHandle(h) if (h.kind == HFileRequest || h.kind == HAddrRequest || h.kind == HNameRequest
					|| h.kind == HRandomRequest || h.kind == HThreadPoolRequest): Luv.requestCancel(h.native);
				case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Request");
			});
		}));

		var dns = "eval.luv.Dns";
		reg(dns, "createAddrRequest", vfn(_ -> VHandle(new EvalHandle(HAddrRequest, Luv.newAddrRequest()))));
		reg(dns, "createInfoRequest", vfn(_ -> VHandle(new EvalHandle(HNameRequest, Luv.newNameRequest()))));
		reg(dns, "getAddrInfo", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var node = arg(a, 1) == VNull ? null : bytesOf(arg(a, 1));
			var service = arg(a, 2) == VNull ? null : bytesOf(arg(a, 2));
			if (node == null && service == null)
				EvalExceptions.exc(ctx, createHaxeException(ctx, "Either node or service has to be not null"));
			var cb = prepareCallback(ctx, arg(a, 4));
			var callback = function(code:Int, infos:Null<Array<AddrInfo>>) {
				cb([encodeResult(code, () -> array([for (info in infos) {
					var fields = [
						{name: "family", value: encodeAddressFamily(info.family)},
						{name: "sockType", value: encodeSocketType(info.socktype)},
						{name: "protocol", value: VInt(info.protocol)},
						{name: "addr", value: encodeSockaddr(info.addr)}
					];
					if (info.canonname != null) fields.unshift({name: "canonName", value: encodeString(info.canonname)});
					obj(fields);
				}]))]);
			};
			var v4 = arg(a, 3);
			if (v4 == VNull) Luv.getaddrinfo(l, null, null, node, service, callback);
			else {
				var request = switch (optionField(ctx, v4, "request")) {
					case VNull: null;
					case VHandle(h) if (h.kind == HAddrRequest): (h.native : LuvObject);
					case v: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Dns.AddrInfoRequest");
				};
				var family = switch (optionField(ctx, v4, "family")) { case VNull: null; case v: decodeAddressFamily(ctx, v); };
				var socktype = switch (optionField(ctx, v4, "sockType")) { case VNull: null; case v: decodeSocketType(ctx, v); };
				var protocol = switch (optionField(ctx, v4, "protocol")) { case VNull: null; case v: EvalStdLib.decodeInt(ctx, v); };
				var flags:Null<Int> = switch (optionField(ctx, v4, "flags")) {
					case VNull: null;
					case v:
						var f = 0;
						for (x in EvalStdLib.decodeArray(ctx, v)) {
							var i = EvalStdLib.decodeInt(ctx, x);
							if (i < 0 || i > 6) EvalExceptions.unexpectedValue(ctx, x, "eval.luv.Dns.AddrInfoFlag");
							f |= Luv.addrInfoFlag(i);
						}
						f;
				};
				// Hints when any is given, the family then UNSPEC by default.
				var hints = family == null && socktype == null && protocol == null && flags == null ? null
					: [family == null ? LuvSys.addressFamilyToC(0) : family, socktype == null ? 0 : socktype, protocol == null ? 0 : protocol, flags == null ? 0 : flags];
				Luv.getaddrinfo(l, request, hints, node, service, callback);
			}
			VNull;
		}));
		reg(dns, "getNameInfo", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var addr = decodeSockaddr(ctx, arg(a, 1));
			var cb = prepareCallback(ctx, arg(a, 3));
			var callback = function(code:Int, host:Null<haxe.io.Bytes>, service:Null<haxe.io.Bytes>) {
				cb([encodeResult(code, () -> obj([{name: "node", value: encodeString(host)}, {name: "service", value: encodeString(service)}]))]);
			};
			var v3 = arg(a, 2);
			if (v3 == VNull) Luv.getnameinfo(l, null, addr, 0, callback);
			else {
				var request = switch (optionField(ctx, v3, "request")) {
					case VNull: null;
					case VHandle(h) if (h.kind == HNameRequest): (h.native : LuvObject);
					case v: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Dns.NameInfoRequest");
				};
				var flags = switch (optionField(ctx, v3, "flags")) {
					case VNull: 0;
					case v:
						var f = 0;
						for (x in EvalStdLib.decodeArray(ctx, v)) {
							var i = EvalStdLib.decodeInt(ctx, x);
							if (i < 0 || i > 4) EvalExceptions.unexpectedValue(ctx, x, "eval.luv.Dns.NameInfoFlag");
							f |= Luv.nameInfoFlag(i);
						}
						f;
				};
				Luv.getnameinfo(l, request, addr, flags, callback);
			}
			VNull;
		}));

		var proc = "eval.luv._Process.Process_Impl_";
		reg(proc, "stdin", VInt(0));
		reg(proc, "stdout", VInt(1));
		reg(proc, "stderr", VInt(2));
		function encodeRedirection(r:Redirection):EvalValue return VHandle(new EvalHandle(HRedirection, r));
		reg(proc, "toParentPipe", vfn(a -> {
			var fd = EvalStdLib.decodeInt(ctx, arg(a, 0));
			var pipe = decodeKind(ctx, arg(a, 1), HPipe, "eval.luv.Pipe");
			var readable = EvalStdLib.decodeBool(ctx, arg(a, 2));
			var writable = EvalStdLib.decodeBool(ctx, arg(a, 3));
			var overlapped = EvalStdLib.decodeBool(ctx, arg(a, 4));
			encodeRedirection(Luv.redirectPipe(fd, pipe, readable, writable, overlapped));
		}));
		reg(proc, "inheritFd", vfn(a -> {
			var fd = EvalStdLib.decodeInt(ctx, arg(a, 0));
			var from = EvalStdLib.decodeInt(ctx, arg(a, 1));
			encodeRedirection(Luv.redirectFd(fd, from));
		}));
		reg(proc, "inheritStream", vfn(a -> {
			var fd = EvalStdLib.decodeInt(ctx, arg(a, 0));
			var stream = decodeStream(ctx, arg(a, 1));
			encodeRedirection(Luv.redirectStream(fd, stream));
		}));
		reg(proc, "spawn", vfn(a -> {
			var l = decodeLoop(arg(a, 0));
			var cmd = nativeBytesOf(arg(a, 1));
			var args = [for (x in EvalStdLib.decodeArray(ctx, arg(a, 2))) nativeBytesOf(x)];
			var v4 = arg(a, 3);
			// The handle is allocated after the options are decoded.
			var p:Null<LuvObject> = null;
			var onExit:Null<haxe.Int64->Int->Void> = null;
			var env:Null<Array<{name:haxe.io.Bytes, value:haxe.io.Bytes}>> = null;
			var redirect:Array<Redirection> = [];
			var cwd:Null<haxe.io.Bytes> = null;
			var uid:Null<Int> = null;
			var gid:Null<Int> = null;
			var flagSet = [false, false, false, false, false];
			if (v4 != VNull) {
				switch (v4) {
					case VObject(_):
					case _: EvalExceptions.unexpectedValue(ctx, v4, "object");
				}
				switch (optionField(ctx, v4, "onExit")) {
					case VNull:
					case v:
						var cb = prepareCallback(ctx, v);
						onExit = (status, signal) -> { cb([handle(HProcess, p), i64(status), VInt(signal)]); };
				}
				// A StringMap's entries folded, each pair prepended.
				switch (optionField(ctx, v4, "environment")) {
					case VNull:
					case v:
						switch (v) {
							case VInstance(vi):
								switch (vi.ikind) {
									case IMap(_) if (vi.iproto.ppath == EvalHash.keyHaxeDsStringMap):
										env = [];
										for (entry in EvalStdLib.orderedMapEntries(v))
											env.unshift({name: bytesOf(entry.key), value: nativeBytesOf(entry.value)});
									case _: EvalExceptions.unexpectedValue(ctx, v, "haxe.ds.Map<String,String>");
								}
							case _: EvalExceptions.unexpectedValue(ctx, v, "instance");
						}
				}
				switch (optionField(ctx, v4, "redirect")) {
					case VNull:
					case v:
						redirect = [for (x in EvalStdLib.decodeArray(ctx, v)) switch (x) {
							case VHandle(h) if (h.kind == HRedirection): (h.native : Redirection);
							case _: EvalExceptions.unexpectedValue(ctx, x, "eval.luv.Process.Redirection");
						}];
				}
				switch (optionField(ctx, v4, "workingDirectory")) { case VNull: case v: cwd = nativeBytesOf(v); }
				switch (optionField(ctx, v4, "uid")) { case VNull: case v: uid = EvalStdLib.decodeInt(ctx, v); }
				switch (optionField(ctx, v4, "gid")) { case VNull: case v: gid = EvalStdLib.decodeInt(ctx, v); }
				var names = ["windowsVerbatimArguments", "detached", "windowsHide", "windowsHideConsole", "windowsHideGui"];
				for (i in 0...5) switch (optionField(ctx, v4, names[i])) { case VNull: case v: flagSet[i] = EvalStdLib.decodeBool(ctx, v); }
			}
			p = Luv.newHandle(HProcess);
			var process:LuvObject = p;
			encodeResult(Luv.spawn(l, process, onExit, cmd, args, env, cwd, uid, gid, flagSet, redirect), () -> handle(HProcess, process));
		}));
		reg(proc, "disableStdioInheritance", vfn(_ -> {
			Luv.disableStdioInheritance();
			VNull;
		}));
		reg(proc, "killPid", vfn(a -> {
			var pid = EvalStdLib.decodeInt(ctx, arg(a, 0));
			var sig = EvalStdLib.decodeInt(ctx, arg(a, 1));
			encodeUnitResult(Luv.killPid(pid, sig));
		}));
		reg(proc, "pid", vfn(a -> VInt(Luv.processPid(decodeKind(ctx, arg(a, 0), HProcess, "eval.luv.Process")))));
	}

	// A thread the interpreter has no eval for gets one for the call, and loses it after; a Sys.exit ends
	// the process. (A Haxe exception cannot reach here: prepareCallback's exception catch has already made
	// it an Error, which goes on up.)
	static function runOnThread(ctx:EvalContext, f:Void->Void):Void {
		if (hxc.eval.EvalContext.threadEval(ctx) != null) {
			f();
			return;
		}
		ctx.evalTls.value = new hxc.eval.EvalContext.Eval();
		try {
			f();
		} catch (e:EvalExceptions.EvalSysExit) {
			ctx.evalTls.value = null;
			hxc.compiler.HostRuntime.exit(e.code);
		} catch (e:Dynamic) {
			ctx.evalTls.value = null;
			throw e;
		}
		ctx.evalTls.value = null;
	}

	static function initThreads(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		inline function reg(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);

		var pool = "eval.luv.ThreadPool";
		reg(pool, "createRequest", vfn(_ -> VHandle(new EvalHandle(HThreadPoolRequest, Luv.newWorkRequest()))));
		reg(pool, "queueWork", vfn(a -> {
			var l = decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop");
			var v2 = arg(a, 1);
			var request = v2 == VNull ? null : switch (v2) {
				case VHandle(h) if (h.kind == HThreadPoolRequest): (h.native : LuvObject);
				case _: EvalExceptions.unexpectedValue(ctx, v2, "eval.luv.ThreadPool.ThreadPoolRequest");
			};
			var cb = prepareCallback(ctx, arg(a, 2));
			var work = () -> runOnThread(ctx, () -> { cb([]); });
			Luv.queueWork(l, request, work, unitCallback(ctx, arg(a, 3)));
			VNull;
		}));
		// Through UV_THREADPOOL_SIZE, unless it is set and asked not to.
		reg(pool, "setSize", vfn(a -> {
			var size = EvalStdLib.decodeInt(ctx, arg(a, 0));
			var ifNotSet = decodeOptionalBool(ctx, arg(a, 1), false);
			var name = haxe.io.Bytes.ofString("UV_THREADPOOL_SIZE");
			var alreadySet = LuvSys.getenv(name, [null]) >= 0;
			if (!(alreadySet && ifNotSet)) LuvSys.setenv(name, haxe.io.Bytes.ofString(Std.string(size)));
			VNull;
		}));

		var thread = "eval.luv._Thread.Thread_Impl_";
		reg(thread, "self", vfn(_ -> VHandle(new EvalHandle(HThread, Luv.threadSelf()))));
		reg(thread, "create", vfn(a -> {
			var cb = prepareCallback(ctx, arg(a, 0));
			var fn = () -> runOnThread(ctx, () -> { cb([]); });
			var stackSize:Null<Int> = arg(a, 1) == VNull ? null : EvalStdLib.decodeInt(ctx, arg(a, 1));
			var out:Array<LuvObject> = [null];
			var r = Luv.threadCreate(stackSize, fn, out);
			encodeResult(r, () -> VHandle(new EvalHandle(HThread, out[0])));
		}));
		reg(thread, "join", vfn(a -> {
			var v = arg(a, 0);
			var t:LuvObject = switch (v) {
				case VHandle(h) if (h.kind == HThread): h.native;
				case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Thread");
			};
			encodeUnitResult(Luv.threadJoin(t));
		}));
	}

	static function initSystem(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		inline function reg(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);
		inline function bytesOf(v:EvalValue) return EvalStdLib.decodeString(ctx, v).toBytes();
		inline function nativeBytesOf(v:EvalValue) return EvalStdLib.decodeNativeString(ctx, v).toBytes();

		var buf = "eval.luv._Buffer.Buffer_Impl_";
		reg(buf, "create", vfn(a -> {
			var size = EvalStdLib.decodeInt(ctx, arg(a, 0));
			if (size < 0) invalidArgument("Bigarray.create: negative dimension");
			encodeBuffer(new LuvSys.LuvBuffer(haxe.io.Bytes.alloc(size), 0, size));
		}));
		function fromBytes(b:haxe.io.Bytes) return encodeBuffer(new LuvSys.LuvBuffer(b.sub(0, b.length), 0, b.length));
		reg(buf, "fromNativeString", vfn(a -> fromBytes(nativeBytesOf(arg(a, 0)))));
		reg(buf, "fromString", vfn(a -> fromBytes(bytesOf(arg(a, 0)))));
		reg(buf, "fromBytes", vfn(a -> fromBytes(EvalStdLib.decodeBytes(arg(a, 0)))));
		function decodeBuffers(v:EvalValue) return [for (x in EvalStdLib.decodeArray(ctx, v)) decodeBuffer(ctx, x)];
		reg(buf, "totalSize", vfn(a -> {
			var total = 0;
			for (b in decodeBuffers(arg(a, 0))) total += b.length;
			VInt(total);
		}));
		reg(buf, "drop", vfn(a -> {
			var l = decodeBuffers(arg(a, 0));
			var count = EvalStdLib.decodeInt(ctx, arg(a, 1));
			var i = 0;
			var out:Array<LuvSys.LuvBuffer> = null;
			while (out == null) {
				if (count <= 0 || i >= l.length) out = l.slice(i);
				else {
					var first = l[i];
					if (count < first.length)
						out = [new LuvSys.LuvBuffer(first.bytes, first.offset + count, first.length - count)].concat(l.slice(i + 1));
					else {
						count -= first.length;
						i++;
					}
				}
			}
			array([for (b in out) encodeBuffer(b)]);
		}));
		reg(buf, "size", vfn(a -> VInt(decodeBuffer(ctx, arg(a, 0)).length)));
		// Get and set are bounds-checked.
		function get(checked:Bool) return vfn(a -> {
			var b = decodeBuffer(ctx, arg(a, 0));
			var i = EvalStdLib.decodeInt(ctx, arg(a, 1));
			if (i < 0 || i >= b.length) {
				if (checked) invalidArgument("index out of bounds");
				VInt(0);
			} else VInt(b.bytes.get(b.offset + i));
		});
		function set(checked:Bool) return vfn(a -> {
			var b = decodeBuffer(ctx, arg(a, 0));
			var i = EvalStdLib.decodeInt(ctx, arg(a, 1));
			var byte = EvalStdLib.decodeInt(ctx, arg(a, 2));
			// The application's arguments are evaluated right to left: char_of_int first
			var c = charOfInt(byte);
			if (i < 0 || i >= b.length) {
				if (checked) invalidArgument("index out of bounds");
			} else b.bytes.set(b.offset + i, c);
			arg(a, 2);
		});
		reg(buf, "get", get(true));
		reg(buf, "unsafeGet", get(false));
		reg(buf, "set", set(true));
		reg(buf, "unsafeSet", set(false));
		reg(buf, "sub", vfn(a -> {
			var b = decodeBuffer(ctx, arg(a, 0));
			var offset = EvalStdLib.decodeInt(ctx, arg(a, 1));
			var length = EvalStdLib.decodeInt(ctx, arg(a, 2));
			if (offset < 0 || length < 0 || offset + length > b.length) invalidArgument("Bigarray.sub: bad sub-array");
			encodeBuffer(new LuvSys.LuvBuffer(b.bytes, b.offset + offset, length));
		}));
		reg(buf, "blit", vfn(a -> {
			var src = decodeBuffer(ctx, arg(a, 0));
			var dst = decodeBuffer(ctx, arg(a, 1));
			if (src.length != dst.length) invalidArgument("Bigarray.blit: dimension mismatch");
			dst.bytes.blit(dst.offset, src.bytes, src.offset, src.length);
			VNull;
		}));
		reg(buf, "fill", vfn(a -> {
			var b = decodeBuffer(ctx, arg(a, 0));
			var c = charOfInt(EvalStdLib.decodeInt(ctx, arg(a, 1)));
			b.bytes.fill(b.offset, b.length, c);
			VNull;
		}));
		function contents(b:LuvSys.LuvBuffer) return b.bytes.sub(b.offset, b.length);
		reg(buf, "toString", vfn(a -> encodeString(contents(decodeBuffer(ctx, arg(a, 0))))));
		reg(buf, "toNativeString", vfn(a -> nativeString(contents(decodeBuffer(ctx, arg(a, 0))))));
		reg(buf, "toBytes", vfn(a -> EvalStdLib.mkBytes(ctx, contents(decodeBuffer(ctx, arg(a, 0))))));
		// No bounds error: what fits is copied.
		reg(buf, "blitToBytes", vfn(a -> {
			var b = decodeBuffer(ctx, arg(a, 0));
			var dest = EvalStdLib.decodeBytes(arg(a, 1));
			var offset = EvalStdLib.decodeInt(ctx, arg(a, 2));
			var n = offset < 0 || offset > dest.length ? 0 : (b.length < dest.length - offset ? b.length : dest.length - offset);
			if (n > 0) dest.blit(offset, b.bytes, b.offset, n);
			VNull;
		}));
		function blitFrom(b:LuvSys.LuvBuffer, source:haxe.io.Bytes, offset:Int) {
			var n = offset < 0 || offset > source.length ? 0 : source.length - offset;
			if (n > b.length) n = b.length;
			if (n > 0) b.bytes.blit(b.offset, source, offset, n);
		}
		reg(buf, "blitFromBytes", vfn(a -> {
			var b = decodeBuffer(ctx, arg(a, 0));
			var source = EvalStdLib.decodeBytes(arg(a, 1));
			blitFrom(b, source, EvalStdLib.decodeInt(ctx, arg(a, 2)));
			VNull;
		}));
		reg(buf, "blitFromString", vfn(a -> {
			var b = decodeBuffer(ctx, arg(a, 0));
			var source = nativeBytesOf(arg(a, 1));
			blitFrom(b, source, EvalStdLib.decodeInt(ctx, arg(a, 2)));
			VNull;
		}));

		var sa = "eval.luv._SockAddr.SockAddr_Impl_";
		reg(sa, "get_port", vfn(a -> {
			var p = LuvSys.sockaddrPort(decodeSockaddr(ctx, arg(a, 0)));
			p == null ? VNull : VInt(p);
		}));
		reg(sa, "ipv4", vfn(a -> {
			var host = bytesOf(arg(a, 0));
			var port = EvalStdLib.decodeInt(ctx, arg(a, 1));
			var storage = LuvSys.newSockaddr();
			encodeResult(LuvSys.ipv4(host, port, storage), () -> encodeSockaddr(storage));
		}));
		reg(sa, "ipv6", vfn(a -> {
			var host = bytesOf(arg(a, 0));
			var port = EvalStdLib.decodeInt(ctx, arg(a, 1));
			var storage = LuvSys.newSockaddr();
			encodeResult(LuvSys.ipv6(host, port, storage), () -> encodeSockaddr(storage));
		}));
		reg(sa, "toString", vfn(a -> {
			var str = LuvSys.sockaddrToString(decodeSockaddr(ctx, arg(a, 0)));
			str == null ? VString(EvalString.createAscii(ByteString.ofText(""))) : encodeString(str);
		}));

		var env = "eval.luv.Env";
		reg(env, "getEnv", vfn(a -> {
			var out = [];
			var r = LuvSys.getenv(bytesOf(arg(a, 0)), out);
			encodeResult(r, () -> nativeString(out[0]));
		}));
		reg(env, "setEnv", vfn(a -> {
			var name = bytesOf(arg(a, 0));
			var value = nativeBytesOf(arg(a, 1));
			encodeUnitResult(LuvSys.setenv(name, value));
		}));
		reg(env, "unsetEnv", vfn(a -> encodeUnitResult(LuvSys.unsetenv(bytesOf(arg(a, 0))))));
		reg(env, "environ", vfn(a -> {
			var out = [];
			var r = LuvSys.osEnviron(out);
			encodeResult(r, () -> {
				var m = new Map<String, EvalValue>();
				for (item in out) m.set(ByteString.ofBytes(item.name, 0, item.name.length).toText(), nativeString(item.value));
				EvalStdLib.mkStringMapValues(ctx, m);
			});
		}));

		var time = "eval.luv.Time";
		reg(time, "getTimeOfDay", vfn(a -> {
			var out:Array<Dynamic> = [];
			var r = LuvSys.gettimeofday(out);
			encodeResult(r, () -> obj([{name: "sec", value: i64(out[0])}, {name: "usec", value: VInt(out[1])}]));
		}));
		reg(time, "hrTime", vfn(a -> u64(LuvSys.hrtime())));
		reg(time, "sleep", vfn(a -> { LuvSys.sleep(EvalStdLib.decodeInt(ctx, arg(a, 0))); VNull; }));

		var path = "eval.luv.Path";
		for (p in [{name: "exePath", kind: 0}, {name: "cwd", kind: 1}, {name: "homedir", kind: 2}, {name: "tmpdir", kind: 3}]) {
			var kind = p.kind;
			reg(path, p.name, vfn(a -> {
				var out = [];
				var r = LuvSys.path(kind, out);
				encodeResult(r, () -> nativeString(out[0]));
			}));
		}
		reg(path, "chdir", vfn(a -> encodeUnitResult(LuvSys.chdir(nativeBytesOf(arg(a, 0))))));

		reg("eval.luv.RandomSync", "random", vfn(a -> encodeUnitResult(LuvSys.randomSync(decodeBuffer(ctx, arg(a, 0))))));

		var net = "eval.luv.Network";
		reg(net, "interfaceAddresses", vfn(a -> {
			var out = [];
			var r = LuvSys.interfaceAddresses(out);
			encodeResult(r, () -> array([for (i in out) obj([
				{name: "name", value: encodeString(i.name)},
				{name: "isInternal", value: EvalValueTools.vbool(i.internal)},
				{name: "physical", value: nativeString(i.physical)},
				{name: "address", value: encodeSockaddr(i.address)},
				{name: "netmask", value: encodeSockaddr(i.netmask)},
			])]));
		}));
		for (n in [{name: "ifIndexToName", iid: false}, {name: "ifIndexToIid", iid: true}]) {
			var iid = n.iid;
			reg(net, n.name, vfn(a -> {
				var out = [];
				var r = LuvSys.ifIndexTo(iid, EvalStdLib.decodeInt(ctx, arg(a, 0)), out);
				encodeResult(r, () -> encodeString(out[0]));
			}));
		}
		reg(net, "getHostName", vfn(a -> {
			var out = [];
			var r = LuvSys.gethostname(out);
			encodeResult(r, () -> encodeString(out[0]));
		}));

		var res = "eval.luv.Resource";
		reg(res, "uptime", vfn(a -> {
			var out = [0.0];
			var r = LuvSys.uptime(out);
			encodeResult(r, () -> VFloat(out[0]));
		}));
		reg(res, "loadAvg", vfn(a -> array([for (f in LuvSys.loadavg()) VFloat(f)])));
		// Zero is no answer.
		for (m in [{name: "freeMemory", kind: 0}, {name: "totalMemory", kind: 1}, {name: "constrainedMemory", kind: 2}]) {
			var kind = m.kind;
			reg(res, m.name, vfn(a -> {
				var v = LuvSys.memory(kind);
				v == 0 ? VNull : u64(v);
			}));
		}
		reg(res, "getPriority", vfn(a -> {
			var out = [0];
			var r = LuvSys.getpriority(EvalStdLib.decodeInt(ctx, arg(a, 0)), out);
			encodeResult(r, () -> VInt(out[0]));
		}));
		reg(res, "setPriority", vfn(a -> {
			var pid = EvalStdLib.decodeInt(ctx, arg(a, 0));
			var priority = EvalStdLib.decodeInt(ctx, arg(a, 1));
			encodeUnitResult(LuvSys.setpriority(pid, priority));
		}));
		reg(res, "residentSetMemory", vfn(a -> {
			var out:Array<haxe.Int64> = [0];
			var r = LuvSys.residentSetMemory(out);
			encodeResult(r, () -> u64(out[0]));
		}));
		reg(res, "getRUsage", vfn(a -> {
			var f:Array<haxe.Int64> = [];
			var r = LuvSys.getrusage(f);
			encodeResult(r, () -> {
				var names = ["maxrss", "ixrss", "idrss", "isrss", "minflt", "majflt", "nswap", "inblock", "oublock", "msgsnd",
					"msgrcv", "nsignals", "nvcsw", "nivcsw"];
				var fields = [
					{name: "utime", value: obj([{name: "sec", value: i64(f[0])}, {name: "usec", value: i64(f[1])}])},
					{name: "stime", value: obj([{name: "sec", value: i64(f[2])}, {name: "usec", value: i64(f[3])}])},
				];
				for (i in 0...names.length) fields.push({name: names[i], value: u64(f[4 + i])});
				obj(fields);
			});
		}));

		var si = "eval.luv.SystemInfo";
		reg(si, "cpuInfo", vfn(a -> {
			var out = [];
			var r = LuvSys.cpuInfo(out);
			encodeResult(r, () -> array([for (i in out) obj([
				{name: "model", value: encodeString(i.model)},
				{name: "speed", value: VInt(i.speed)},
				{name: "times", value: obj([
					{name: "user", value: u64(i.times[0])},
					{name: "nice", value: u64(i.times[1])},
					{name: "sys", value: u64(i.times[2])},
					{name: "idle", value: u64(i.times[3])},
					{name: "irq", value: u64(i.times[4])},
				])},
			])]));
		}));
		reg(si, "uname", vfn(a -> {
			var out = [];
			var r = LuvSys.uname(out);
			encodeResult(r, () -> obj([
				{name: "sysname", value: encodeString(out[0])},
				{name: "release", value: encodeString(out[1])},
				{name: "version", value: encodeString(out[2])},
				{name: "machine", value: encodeString(out[3])},
			]));
		}));

		reg("eval.luv.Pid", "getPid", vfn(a -> VInt(LuvSys.getpid())));
		reg("eval.luv.Pid", "getPPid", vfn(a -> VInt(LuvSys.getppid())));
		reg("eval.luv.Passwd", "getPasswd", vfn(a -> {
			var out:Array<Dynamic> = [];
			var r = LuvSys.getPasswd(out);
			encodeResult(r, () -> obj([
				{name: "username", value: encodeString(out[0])},
				{name: "uid", value: VInt(out[1])},
				{name: "gid", value: VInt(out[2])},
				{name: "shell", value: out[3] == null ? VNull : encodeString(out[3])},
				{name: "homedir", value: nativeString(out[4])},
			]));
		}));
		reg("eval.luv.Metrics", "idleTime", vfn(a -> u64(LuvSys.idleTime(decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop")))));
	}

	public static function init(ctx:EvalContext, s:Map<Int, Array<hxc.eval.EvalContext.BuiltinField>>):Void {
		Luv.exceptionHandler = defaultHandler(ctx);
		inline function reg(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);

		var uvError = "eval.luv._UVError.UVError_Impl_";
		reg(uvError, "toString", vfn(a -> EvalString.createUnknown(ByteString.ofText(Luv.strerror(Luv.errorCode(decodeUvError(ctx, arg(a, 0))))))));
		reg(uvError, "errName", vfn(a -> EvalString.createUnknown(ByteString.ofText(Luv.errName(Luv.errorCode(decodeUvError(ctx, arg(a, 0))))))));
		reg(uvError, "translateSysError", vfn(a -> VInt(Luv.errorIndex(Luv.translateSysError(EvalStdLib.decodeInt(ctx, arg(a, 0)))))));
		reg(uvError, "setOnUnhandledException", vfn(a -> {
			var cb = prepareCallback(ctx, arg(a, 0));
			Luv.exceptionHandler = function(ex:Dynamic) {
				var msg = if (Std.isOfType(ex, hxc.core.TypingError)) {
					var te:hxc.core.TypingError = ex;
					// The interpreter rethrows a runtime exception as a Custom "message\nstack"
					te.callChain == null ? te.message.split("\n")[0] : locatedText(ctx, te);
				} else errorText(ex);
				cb([createHaxeException(ctx, msg)]);
			};
			VNull;
		}));

		var loop = "eval.luv._Loop.Loop_Impl_";
		reg(loop, "run", vfn(a -> {
			var l = decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop");
			var mode = switch (EvalStdLib.decodeInt(ctx, arg(a, 1))) {
				case 0: 0; // UV_RUN_DEFAULT
				case 1: 1; // UV_RUN_ONCE
				case 2: 2; // UV_RUN_NOWAIT
				case _: EvalExceptions.unexpectedValue(ctx, arg(a, 1), "valid loop run mode");
			};
			EvalValueTools.vbool(Luv.loopRun(l, mode));
		}));
		reg(loop, "stop", vfn(a -> { Luv.loopStop(decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop")); VNull; }));
		reg(loop, "init", vfn(a -> {
			var l = Luv.newLoop();
			encodeResult(Luv.loopInit(l), () -> handle(HLoop, l));
		}));
		reg(loop, "close", vfn(a -> encodeUnitResult(Luv.loopClose(decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop")))));
		reg(loop, "alive", vfn(a -> EvalValueTools.vbool(Luv.loopAlive(decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop")))));
		reg(loop, "defaultLoop", vfn(a -> handle(HLoop, Luv.loopDefault())));
		reg(loop, "libraryShutdown", vfn(a -> { Luv.libraryShutdown(); VNull; }));
		reg(loop, "now", vfn(a -> VUInt64(new EvalInt64(Luv.loopNow(decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop"))))));
		reg(loop, "updateTime", vfn(a -> { Luv.loopUpdateTime(decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop")); VNull; }));
		reg("eval.luv._Loop.LoopOption_Impl_", "sigprof", VInt(Luv.sigprof()));

		var h = "eval.luv._Handle.Handle_Impl_";
		reg(h, "close", vfn(a -> {
			var o = decodeLuvHandle(ctx, arg(a, 0));
			var cb = prepareCallback(ctx, arg(a, 1));
			Luv.close(o, () -> { cb([]); });
			VNull;
		}));
		reg(h, "isActive", vfn(a -> EvalValueTools.vbool(Luv.isActive(decodeLuvHandle(ctx, arg(a, 0))))));
		reg(h, "isClosing", vfn(a -> EvalValueTools.vbool(Luv.isClosing(decodeLuvHandle(ctx, arg(a, 0))))));
		reg(h, "ref", vfn(a -> { Luv.ref(decodeLuvHandle(ctx, arg(a, 0))); VNull; }));
		reg(h, "unref", vfn(a -> { Luv.unref(decodeLuvHandle(ctx, arg(a, 0))); VNull; }));
		reg(h, "hasRef", vfn(a -> EvalValueTools.vbool(Luv.hasRef(decodeLuvHandle(ctx, arg(a, 0))))));
		// 0 asks for the size, anything else sets it.
		reg(h, "sendBufferSize", vfn(a -> {
			var out = [0];
			var r = Luv.bufferSize(decodeSocketHandle(ctx, arg(a, 0)), true, out);
			encodeResult(r, () -> VInt(out[0]));
		}));
		reg(h, "setSendBufferSize", vfn(a -> {
			var o = decodeSocketHandle(ctx, arg(a, 0));
			var out = [EvalStdLib.decodeInt(ctx, arg(a, 1))];
			encodeUnitResult(Luv.bufferSize(o, true, out));
		}));
		reg(h, "recvBufferSize", vfn(a -> {
			var out = [0];
			var r = Luv.bufferSize(decodeSocketHandle(ctx, arg(a, 0)), false, out);
			encodeResult(r, () -> VInt(out[0]));
		}));
		// Misspelt on purpose: the eval natives register it under this name.
		reg(h, "setRendBufferSize", vfn(a -> {
			var o = decodeSocketHandle(ctx, arg(a, 0));
			var out = [EvalStdLib.decodeInt(ctx, arg(a, 1))];
			encodeUnitResult(Luv.bufferSize(o, false, out));
		}));

		for (w in [{kind: HIdle, path: "eval.luv._Idle.Idle_Impl_", name: "eval.luv.Idle"},
				{kind: HPrepare, path: "eval.luv._Prepare.Prepare_Impl_", name: "eval.luv.Prepare"},
				{kind: HCheck, path: "eval.luv._Check.Check_Impl_", name: "eval.luv.Check"}]) {
			var kind = w.kind, name = w.name;
			reg(w.path, "init", vfn(a -> {
				var l = decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop");
				var o = Luv.newHandle(kind);
				encodeResult(Luv.watcherInit(kind, l, o), () -> handle(kind, o));
			}));
			reg(w.path, "start", vfn(a -> {
				var o = decodeKind(ctx, arg(a, 0), kind, name);
				var cb = prepareCallback(ctx, arg(a, 1));
				encodeUnitResult(Luv.watcherStart(kind, o, () -> { cb([]); }));
			}));
			reg(w.path, "stop", vfn(a -> encodeUnitResult(Luv.watcherStop(kind, decodeKind(ctx, arg(a, 0), kind, name)))));
		}

		var timer = "eval.luv._Timer.Timer_Impl_";
		inline function decodeTimer(v:EvalValue) return decodeKind(ctx, v, HTimer, "eval.luv.Timer");
		reg(timer, "init", vfn(a -> {
			var l = decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop");
			var t = Luv.newHandle(HTimer);
			encodeResult(Luv.timerInit(l, t), () -> handle(HTimer, t));
		}));
		reg(timer, "start", vfn(a -> {
			var t = decodeTimer(arg(a, 0));
			var cb = prepareCallback(ctx, arg(a, 1));
			var timeout = EvalStdLib.decodeInt(ctx, arg(a, 2));
			var repeat = EvalStdLib.defaultInt(ctx, arg(a, 3), 0);
			encodeUnitResult(Luv.timerStart(t, () -> { cb([]); }, timeout, repeat));
		}));
		reg(timer, "stop", vfn(a -> encodeUnitResult(Luv.timerStop(decodeTimer(arg(a, 0))))));
		reg(timer, "again", vfn(a -> encodeUnitResult(Luv.timerAgain(decodeTimer(arg(a, 0))))));
		reg(timer, "set_repeat", vfn(a -> {
			var t = decodeTimer(arg(a, 0));
			var repeat = EvalStdLib.decodeInt(ctx, arg(a, 1));
			Luv.timerSetRepeat(t, repeat);
			VInt(repeat);
		}));
		reg(timer, "get_repeat", vfn(a -> VInt(Luv.timerGetRepeat(decodeTimer(arg(a, 0))))));
		reg(timer, "get_dueIn", vfn(a -> VInt(Luv.timerGetDueIn(decodeTimer(arg(a, 0))))));

		var async = "eval.luv._Async.Async_Impl_";
		reg(async, "init", vfn(a -> {
			var l = decodeKind(ctx, arg(a, 0), HLoop, "eval.luv.Loop");
			var cb = prepareCallback(ctx, arg(a, 1));
			var o = Luv.newHandle(HAsync);
			encodeResult(Luv.asyncInit(l, o, () -> { cb([handle(HAsync, o)]); }), () -> handle(HAsync, o));
		}));
		reg(async, "send", vfn(a -> encodeUnitResult(Luv.asyncSend(decodeKind(ctx, arg(a, 0), HAsync, "eval.luv.Async")))));

		var once = "eval.luv._Once.Once_Impl_";
		reg(once, "init", vfn(a -> {
			var o = Luv.newSync(HOnce);
			encodeResult(Luv.onceInit(o), () -> handle(HOnce, o));
		}));
		reg(once, "once", vfn(a -> {
			var o = decodeKind(ctx, arg(a, 0), HOnce, "eval.luv.Once");
			var cb = prepareCallback(ctx, arg(a, 1));
			Luv.once(o, () -> { cb([]); });
			VNull;
		}));

		var mutex = "eval.luv._Mutex.Mutex_Impl_";
		inline function decodeMutex(v:EvalValue) return decodeKind(ctx, v, HMutex, "eval.luv.Mutex");
		reg(mutex, "init", vfn(a -> {
			var recursive = decodeOptionalBool(ctx, arg(a, 0), false);
			var m = Luv.newSync(HMutex);
			encodeResult(Luv.mutexInit(m, recursive), () -> handle(HMutex, m));
		}));
		reg(mutex, "destroy", vfn(a -> { Luv.mutexDestroy(decodeMutex(arg(a, 0))); VNull; }));
		reg(mutex, "lock", vfn(a -> { Luv.mutexLock(decodeMutex(arg(a, 0))); VNull; }));
		reg(mutex, "tryLock", vfn(a -> encodeUnitResult(Luv.mutexTryLock(decodeMutex(arg(a, 0))))));
		reg(mutex, "unlock", vfn(a -> { Luv.mutexUnlock(decodeMutex(arg(a, 0))); VNull; }));

		var rw = "eval.luv._RwLock.RwLock_Impl_";
		inline function decodeRwLock(v:EvalValue) return decodeKind(ctx, v, HRwLock, "eval.luv.RwLock");
		reg(rw, "init", vfn(a -> {
			var l = Luv.newSync(HRwLock);
			encodeResult(Luv.rwlockInit(l), () -> handle(HRwLock, l));
		}));
		reg(rw, "destroy", vfn(a -> { Luv.rwlockDestroy(decodeRwLock(arg(a, 0))); VNull; }));
		reg(rw, "rdLock", vfn(a -> { Luv.rwlockRdLock(decodeRwLock(arg(a, 0))); VNull; }));
		reg(rw, "rdTryLock", vfn(a -> encodeUnitResult(Luv.rwlockTryRdLock(decodeRwLock(arg(a, 0))))));
		reg(rw, "rdUnlock", vfn(a -> { Luv.rwlockRdUnlock(decodeRwLock(arg(a, 0))); VNull; }));
		reg(rw, "wrLock", vfn(a -> { Luv.rwlockWrLock(decodeRwLock(arg(a, 0))); VNull; }));
		reg(rw, "wrTryLock", vfn(a -> encodeUnitResult(Luv.rwlockTryWrLock(decodeRwLock(arg(a, 0))))));
		reg(rw, "wrUnlock", vfn(a -> { Luv.rwlockWrUnlock(decodeRwLock(arg(a, 0))); VNull; }));

		var sem = "eval.luv._Semaphore.Semaphore_Impl_";
		inline function decodeSemaphore(v:EvalValue) return decodeKind(ctx, v, HSemaphore, "eval.luv.Semaphore");
		reg(sem, "init", vfn(a -> {
			var count = EvalStdLib.decodeInt(ctx, arg(a, 0));
			var o = Luv.newSync(HSemaphore);
			encodeResult(Luv.semaphoreInit(o, count), () -> handle(HSemaphore, o));
		}));
		reg(sem, "destroy", vfn(a -> { Luv.semaphoreDestroy(decodeSemaphore(arg(a, 0))); VNull; }));
		reg(sem, "post", vfn(a -> { Luv.semaphorePost(decodeSemaphore(arg(a, 0))); VNull; }));
		reg(sem, "wait", vfn(a -> { Luv.semaphoreWait(decodeSemaphore(arg(a, 0))); VNull; }));
		reg(sem, "tryWait", vfn(a -> encodeUnitResult(Luv.semaphoreTryWait(decodeSemaphore(arg(a, 0))))));

		var cond = "eval.luv._Condition.Condition_Impl_";
		inline function decodeCondition(v:EvalValue) return decodeKind(ctx, v, HCondition, "eval.luv.Condition");
		reg(cond, "init", vfn(a -> {
			var o = Luv.newSync(HCondition);
			encodeResult(Luv.conditionInit(o), () -> handle(HCondition, o));
		}));
		reg(cond, "destroy", vfn(a -> { Luv.conditionDestroy(decodeCondition(arg(a, 0))); VNull; }));
		reg(cond, "signal", vfn(a -> { Luv.conditionSignal(decodeCondition(arg(a, 0))); VNull; }));
		reg(cond, "broadcast", vfn(a -> { Luv.conditionBroadcast(decodeCondition(arg(a, 0))); VNull; }));
		reg(cond, "wait", vfn(a -> {
			var c = decodeCondition(arg(a, 0));
			var m = decodeMutex(arg(a, 1));
			Luv.conditionWait(c, m);
			VNull;
		}));
		reg(cond, "timedWait", vfn(a -> {
			var c = decodeCondition(arg(a, 0));
			var m = decodeMutex(arg(a, 1));
			var timeout = EvalStdLib.decodeInt(ctx, arg(a, 2));
			encodeUnitResult(Luv.conditionTimedWait(c, m, timeout));
		}));

		var barrier = "eval.luv._Barrier.Barrier_Impl_";
		inline function decodeBarrier(v:EvalValue) return decodeKind(ctx, v, HBarrier, "eval.luv.Barrier");
		reg(barrier, "init", vfn(a -> {
			var count = EvalStdLib.decodeInt(ctx, arg(a, 0));
			var o = Luv.newSync(HBarrier);
			encodeResult(Luv.barrierInit(o, count), () -> handle(HBarrier, o));
		}));
		reg(barrier, "destroy", vfn(a -> { Luv.barrierDestroy(decodeBarrier(arg(a, 0))); VNull; }));
		reg(barrier, "wait", vfn(a -> EvalValueTools.vbool(Luv.barrierWait(decodeBarrier(arg(a, 0))))));

		var version = "eval.luv.Version";
		reg(version, "string", vfn(a -> EvalString.createUnknown(ByteString.ofText(Luv.versionString()))));
		reg(version, "major", VInt(Luv.versionMajor()));
		reg(version, "minor", VInt(Luv.versionMinor()));
		reg(version, "patch", VInt(Luv.versionPatch()));
		reg(version, "isRelease", EvalValueTools.vbool(Luv.versionIsRelease()));
		reg(version, "suffix", EvalString.createUnknown(ByteString.ofText(Luv.versionSuffix())));
		reg(version, "hex", VInt(Luv.versionHex()));

		initSystem(ctx, s);
		initStreams(ctx, s);
		initSockets(ctx, s);
		initFiles(ctx, s);
		initRequests(ctx, s);
		initThreads(ctx, s);
	}
}
#end
