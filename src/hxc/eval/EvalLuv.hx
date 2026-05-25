package hxc.eval;

#if (cpp && !emscripten)
import hxc.ast.Position;
import hxc.eval.EvalString.ByteString;
import hxc.eval.EvalString.EvalString;
import hxc.eval.EvalValue;
import hxc.eval.Luv.LuvObject;

/**
 * The eval.luv natives, over libuv bound as luv binds it (hxc.eval.Luv). This is the part the
 * standard library reaches - sys.thread.EventLoop runs on Loop, Async, Timer and Handle, Condition
 * and Semaphore on Mutex, Condition and Semaphore - with the rest of the synchronisation types, the
 * other loop watchers, UVError and Version.
 */
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
				case HIdle | HTimer | HAsync | HPrepare | HCheck: h.native;
				case _: EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Handle");
			}
			case _: EvalExceptions.unexpectedValue(ctx, v, "handle");
		};
	}

	// TCP, UDP and pipe handles, none of which exists here yet.
	static function decodeSocketHandle(ctx:EvalContext, v:EvalValue):LuvObject {
		return switch (v) {
			case VHandle(_): EvalExceptions.unexpectedValue(ctx, v, "eval.luv.Handle.SocketHandle");
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
		var proto = ctx.instancePrototypes.get(EvalHash.hash("haxe.Exception"));
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
		reg(h, "sendBufferSize", vfn(a -> { decodeSocketHandle(ctx, arg(a, 0)); VNull; }));
		reg(h, "setSendBufferSize", vfn(a -> { decodeSocketHandle(ctx, arg(a, 0)); VNull; }));
		reg(h, "recvBufferSize", vfn(a -> { decodeSocketHandle(ctx, arg(a, 0)); VNull; }));
		reg(h, "setRendBufferSize", vfn(a -> { decodeSocketHandle(ctx, arg(a, 0)); VNull; }));

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
	}
}
#end
