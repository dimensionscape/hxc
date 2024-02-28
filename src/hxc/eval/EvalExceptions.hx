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

	public static function throwValue(ctx:EvalContext, v:EvalValue, p:Position):Dynamic {
		var eval = EvalContext.getEval(ctx);
		if (eval.env != null) setLeavePosition(eval.env, p);
		throw new EvalRunTimeException(v, callStack(eval), p);
	}

	public static function addCallSite(ex:EvalRunTimeException, p:Position):Void {
		if (p == null || p.min < 0) return;
		var env = ex.envStack.length > 1 ? ex.envStack[1] : (ex.envStack.length == 0 ? null : ex.envStack[0]);
		if (env != null) setLeavePosition(env, p);
	}

	public static function setLeavePosition(env:EvalEnv, p:Position):Void {
		if (p != null && p.min >= 0) env.leavePos = p;
	}

	public static function envPosition(env:EvalEnv):Position {
		if (env.leavePos != null && env.leavePos.min >= 0) return env.leavePos;
		var file = env.info.file == 0 ? "?" : EvalHash.revHash(env.info.file);
		if (file == null) file = "?";
		return new Position(file, env.info.min, env.info.max);
	}

	public static function exceptionStack(ex:EvalRunTimeException):Array<{pos:Position, kind:EvalEnvKind}> {
		var out:Array<{pos:Position, kind:EvalEnvKind}> = [];
		for (env in ex.envStack) {
			var p = envPosition(env);
			if (p != null && p.min >= 0) out.push({pos: p, kind: env.info.kind});
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
			case VInt(_): "VInt";
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
			case _: "Unexpected value " + sValueKind(v) + ", expected " + expected;
		};
		return excString(ctx, str, p);
	}

	public static function invalidCallArgNumber(ctx:EvalContext, expected:Int, got:Int, ?p:Position):Dynamic {
		return excString(ctx, "Invalid number of call arguments: Expected " + expected + ", got " + got, p);
	}
}
