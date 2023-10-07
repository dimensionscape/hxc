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
		throw new EvalRunTimeException(v, callStack(EvalContext.getEval(ctx)), p);
	}

	public static function addCallSite(ex:EvalRunTimeException, p:Position):Void {
		if (p != null && p.min >= 0) ex.callPositions.push(p);
	}

	public static function envPosition(env:EvalEnv):Position {
		var file = env.info.file == 0 ? "?" : EvalHash.revHash(env.info.file);
		if (file == null) file = "?";
		return new Position(file, env.info.min, env.info.max);
	}

	public static function exceptionStack(ex:EvalRunTimeException):Array<{pos:Position, kind:EvalEnvKind}> {
		var out:Array<{pos:Position, kind:EvalEnvKind}> = [];
		var first = true;
		for (env in ex.envStack) {
			var p = first && ex.pos != null && ex.pos.min >= 0 ? ex.pos : envPosition(env);
			if (p != null && p.min >= 0) out.push({pos: p, kind: env.info.kind});
			first = false;
		}
		for (p in ex.callPositions) {
			if (p != null && p.min >= 0) out.push({pos: p, kind: EKEntrypoint});
		}
		return out;
	}

	public static function exc(ctx:EvalContext, v:EvalValue):Dynamic {
		return throwValue(ctx, v, Position.nullPos);
	}

	public static function excString(ctx:EvalContext, str:String):Dynamic {
		return exc(ctx, VString(new VString(str, str.length)));
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

	public static function unexpectedValue(ctx:EvalContext, v:EvalValue, expected:String):Dynamic {
		var str = switch (v) {
			case VNull: "Null Access";
			case _: "Unexpected value " + sValueKind(v) + ", expected " + expected;
		};
		return excString(ctx, str);
	}

	public static function invalidCallArgNumber(ctx:EvalContext, expected:Int, got:Int):Dynamic {
		return excString(ctx, "Invalid number of call arguments: Expected " + expected + ", got " + got);
	}
}
