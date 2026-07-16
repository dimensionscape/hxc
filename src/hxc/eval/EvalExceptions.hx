package hxc.eval;

import hxc.ast.Position;
import hxc.eval.EvalValue;
import hxc.eval.EvalContext;

// Non-local control flow used by the evaluator.
class EvalBreak extends haxe.Exception {
	public function new() super("break");
}

class EvalContinue extends haxe.Exception {
	public function new() super("continue");
}

class EvalReturn extends haxe.Exception {
	public var value:EvalValue;
	public function new(value:EvalValue) {
		super("return");
		this.value = value;
	}
}

class EvalSysExit extends haxe.Exception {
	public var code:Int;
	public function new(code:Int) {
		super("sysexit");
		this.code = code;
	}
}

// Only the thread's start catches this.
class EvalThreadExit extends haxe.Exception {
	public function new() {
		super("threadexit");
	}
}

// A thrown Haxe value, carrying the call stack and the throw position.
class EvalRunTimeException extends haxe.Exception {
	public var value:EvalValue;
	public var envStack:Array<EvalEnv>;
	public var callPositions:Array<Position>;
	public var pos:Position;
	public function new(value:EvalValue, envStack:Array<EvalEnv>, pos:Position) {
		super("runtime exception");
		this.value = value;
		this.envStack = envStack;
		this.callPositions = [];
		this.pos = pos;
	}
}

class EvalExceptions {
	public static function callStack(eval:Eval):Array<EvalEnv> {
		var acc:Array<EvalEnv> = [];
		var e = eval.env;
		while (e != null) {
			acc.push(e);
			e = e.parent;
		}
		return acc;
	}

	// A positioned raise moves the current environment's leave position to the throw; a raise at the null
	// position (a native's failure, the depth check, a decode) leaves it where the last call left it.
	public static function throwValue(ctx:EvalContext, v:EvalValue, p:Position):Dynamic {
		var eval = EvalContext.getEval(ctx);
		if (eval.env != null && p != null && !isNullPos(p)) eval.env.leavePos = p;
		throw new EvalRunTimeException(v, callStack(eval), p);
	}

	public static inline function isNullPos(p:Position):Bool {
		return p.file == "?" && p.min == -1 && p.max == -1;
	}

	// A call site records itself as the environment's leave position, whatever the position is.
	public static function setLeavePosition(env:EvalEnv, p:Position):Void {
		if (p != null) env.leavePos = p;
	}

	// A frame is its environment's leave position.
	public static function envPosition(env:EvalEnv):Position {
		return env.leavePos;
	}

	// Only a frame at the null position is dropped; one at the file start (a fresh environment) prints
	// as line 1.
	public static function exceptionStack(ex:EvalRunTimeException):Array<{pos:Position, kind:EvalEnvKind}> {
		var out:Array<{pos:Position, kind:EvalEnvKind}> = [];
		for (env in ex.envStack) {
			var p = envPosition(env);
			if (p != null && !isNullPos(p)) out.push({pos: p, kind: env.info.kind});
		}
		return out;
	}

	// The frames from the throwing environment up to the one whose try caught it, that one included, each
	// at its leave position. No frame is dropped here; building the stack drops only an entry point.
	public static function buildExceptionStack(ex:EvalRunTimeException, catchEnv:Null<EvalEnv>):Array<{pos:Position, kind:EvalEnvKind}> {
		var out:Array<{pos:Position, kind:EvalEnvKind}> = [];
		for (env in ex.envStack) {
			out.push({pos: envPosition(env), kind: env.info.kind});
			if (env == catchEnv) break;
		}
		return out;
	}

	// An error position, printed as "%s:%d:".
	public static function formatPos(p:Position):String {
		return hxc.core.Globals.getErrorPosRef(function(file, line) return file + ":" + line + ":", p);
	}

	public static function uncaughtExceptionString(v:EvalValue, p:Position, extra:String):String {
		return formatPos(p) + " : Uncaught exception " + EvalStdLib.stringOf(v) + extra;
	}

	// The uncaught-exception message, over the stack's frames (exceptionStack). A std file is named by its
	// path on the class path, as the typer read it.
	public static function getExcErrorMessage(ctx:EvalContext, ex:EvalRunTimeException):String {
		var com = ctx.com != null ? ctx.com : EvalMacro.hostCom;
		function qualify(p:Position):Position return com == null ? p : @:privateAccess hxc.Compiler.qualifyStdPosition(com, p);
		var p = ex.pos == null ? Position.nullPos : ex.pos;
		var pl = [for (f in exceptionStack(ex)) qualify(f.pos)];
		if (pl.length == 0) return uncaughtExceptionString(ex.value, qualify(p), "");
		var sstack = [for (q in pl) formatPos(q) + " : Called from here"].join("\n");
		return (isNullPos(p) ? "" : formatPos(qualify(p)) + " : ") + "Uncaught exception " + EvalStdLib.stringOf(ex.value) + "\n" + sstack;
	}

	// An internal exception as a thread's uncaught report prints it.
	public static function formatException(e:Dynamic):String {
		if (Std.isOfType(e, HostException)) {
			var oe:HostException = e;
			return oe.failure ? "Failure(\"" + oe.message + "\")" : oe.message;
		}
		return Std.string(e);
	}

	public static function exc(ctx:EvalContext, v:EvalValue, ?p:Position):Dynamic {
		// A builtin throw keeps the null position: the reporting then renders the exception at the catch
		// position and keeps every stack frame.
		return throwValue(ctx, v, p == null ? Position.nullPos : p);
	}

	public static function excString(ctx:EvalContext, str:String, ?p:Position):Dynamic {
		return exc(ctx, hxc.eval.EvalString.EvalString.vOfText(str), p);
	}

	/**
		excString of a message that prints values: the text parts around each value's own bytes
		(valueString), so a string that is not UTF-8 text reaches the message as it is. texts has one
		more entry than values.
	*/
	public static function excValues(ctx:EvalContext, texts:Array<String>, values:Array<EvalValue>, ?p:Position):Dynamic {
		var buf = new hxc.eval.EvalString.ByteBuffer();
		for (i in 0...texts.length) {
			buf.addString(hxc.eval.EvalString.ByteString.ofText(texts[i]));
			if (i < values.length) buf.addString(EvalStdLib.valueString(values[i]));
		}
		return exc(ctx, hxc.eval.EvalString.EvalString.createUnknown(buf.contents()), p);
	}

	public static function sValueKind(v:EvalValue):String {
		return switch (v) {
			case VNull: "VNull";
			case VTrue: "VTrue";
			case VFalse: "VFalse";
			case VInt(_): "VInt32";
			case VFloat(_): "VFloat";
			case VEnumValue(_): "VEnumValue";
			case VObject(_): "VObject";
			case VInstance(_): "VInstance";
			case VString(_): "VString";
			case VArray(_): "VArray";
			case VVector(_): "VVector";
			case VPrototype(_): "VPrototype";
			case VFunction(_, _): "VFunction";
			case VFieldClosure(_, _): "VFieldClosure";
			case VLazy(_): "VLazy";
			case VNativeString(_): "VNativeString";
			case VHandle(_): "VHandle";
			case VInt64(_): "VInt64";
			case VUInt64(_): "VUInt64";
		};
	}

	public static function unexpectedValue(ctx:EvalContext, v:EvalValue, expected:String, ?p:Position):Dynamic {
		return switch (v) {
			case VNull: excString(ctx, "Null Access", p);
			// The kind and the value.
			case _: excValues(ctx, ["Unexpected value " + sValueKind(v) + "(", "), expected " + expected], [v], p);
		};
	}

	public static function invalidCallArgNumber(ctx:EvalContext, expected:Int, got:Int, ?p:Position):Dynamic {
		return excString(ctx, "Invalid number of call arguments: Expected " + expected + ", got " + got, p);
	}
}

// Context.error ends with an abort: the macro's own error is reported and its call answers nothing (typed
// as null). An internal exception, so no macro try/catch sees it and no build failure routing converts it.
class MacroAbort extends haxe.Exception {
	public function new() super("Macro abort");
}

// An internal exception escaping a native (an invalid argument, a missing key, a system error, a failure):
// no program try/catch sees it (a try catches runtime exceptions alone), and the driver reports it: a
// failure as "Error: <message>", any other as the runtime prints it.
class HostException extends haxe.Exception {
	public var failure:Bool;

	public function new(text:String, failure:Bool = false) {
		super(text);
		this.failure = failure;
	}
}
