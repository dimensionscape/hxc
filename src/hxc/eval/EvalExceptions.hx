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

	public static function exc(ctx:EvalContext, v:EvalValue, ?p:Position):Dynamic {
		// A builtin throw keeps the null position: the reporting then renders the exception at the catch
		// position and keeps every stack frame.
		return throwValue(ctx, v, p == null ? Position.nullPos : p);
	}

	public static function excString(ctx:EvalContext, str:String, ?p:Position):Dynamic {
		return exc(ctx, VString(hxc.eval.EvalValue.VString.createUnknown(str)), p);
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
		};
	}

	public static function unexpectedValue(ctx:EvalContext, v:EvalValue, expected:String, ?p:Position):Dynamic {
		var str = switch (v) {
			case VNull: "Null Access";
			// The kind and the value.
			case _: "Unexpected value " + sValueKind(v) + "(" + EvalStdLib.stringOf(v) + "), expected " + expected;
		};
		return excString(ctx, str, p);
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
