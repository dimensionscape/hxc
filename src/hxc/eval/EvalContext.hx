package hxc.eval;

import hxc.ast.Position;
import hxc.core.Define;
import hxc.core.Type.ModuleType;
import hxc.core.NotFound;
import hxc.core.TypingError;
import hxc.eval.EvalValue;
import hxc.eval.EvalHash;
import haxe.ds.StringMap;

enum EvalEnvKind {
	EKLocalFunction(index:Int);
	EKMethod(typeKey:Int, fieldKey:Int);
	EKEntrypoint;
}

// Compile-time information shared by all environments of the same function.
@:structInit
class EvalEnvInfo {
	public var isStatic:Bool;
	public var file:Int;
	public var kind:EvalEnvKind;
	public var numLocals:Int;
	public var numCaptures:Int;
	public function new(isStatic:Bool, file:Int, kind:EvalEnvKind, numLocals:Int, numCaptures:Int) {
		this.isStatic = isStatic;
		this.file = file;
		this.kind = kind;
		this.numLocals = numLocals;
		this.numCaptures = numCaptures;
	}
}

// A call frame. Locals and captures are slot-indexed arrays sized at compile time.
@:structInit
class EvalEnv {
	public var info:EvalEnvInfo;
	public var locals:Array<EvalValue>;
	public var captures:Array<EvalValue>;
	public var parent:Null<EvalEnv>;
	public var stackDepth:Int;
	public var eval:Eval;
	// Maps a variable id to its local slot, filled as variables are first seen.
	public var slots:Map<Int, Int>;
	// The receiver for an instance method or constructor body.
	public var vthis:Null<EvalValue>;
	// The defining scope for a closure; locals not in this frame are looked up along this chain.
	public var lexicalParent:Null<EvalEnv>;
	public function new(info:EvalEnvInfo, locals:Array<EvalValue>, captures:Array<EvalValue>, parent:Null<EvalEnv>, stackDepth:Int, eval:Eval) {
		this.info = info;
		this.locals = locals;
		this.captures = captures;
		this.parent = parent;
		this.stackDepth = stackDepth;
		this.eval = eval;
		this.slots = new Map();
		this.vthis = null;
	}
}

// Per-thread execution state. The single-threaded interpreter uses one of these.
@:structInit
class Eval {
	public var env:Null<EvalEnv>;
	public var lastReturn:Null<EvalValue>;
	public var caughtTypes:Map<Int, Bool>;
	public function new() {
		this.env = null;
		this.lastReturn = null;
		this.caughtTypes = new Map();
	}
}

typedef BuiltinField = {name:Int, v:EvalValue};

@:structInit
class Builtins {
	public var instanceBuiltins:Map<Int, Array<BuiltinField>>;
	public var staticBuiltins:Map<Int, Array<BuiltinField>>;
	public var constructorBuiltins:Map<Int, VFunc>;
	public var emptyConstructorBuiltins:Map<Int, Void->EvalValue>;
	public function new() {
		this.instanceBuiltins = new Map();
		this.staticBuiltins = new Map();
		this.constructorBuiltins = new Map();
		this.emptyConstructorBuiltins = new Map();
	}
}

class EvalContext {
	public var ctxId:Int;
	public var isMacro:Bool;
	public var builtins:Builtins;
	public var hadError:Bool;
	public var typeCache:Map<Int, ModuleType>;
	public var instancePrototypes:Map<Int, VPrototype>;
	public var staticPrototypes:Map<Int, VPrototype>;
	public var constructors:Map<Int, VFunc>;
	public var arrayPrototype:Null<VPrototype>;
	public var stringPrototype:Null<VPrototype>;
	public var vectorPrototype:Null<VPrototype>;
	public var toplevel:EvalValue;
	public var eval:Eval;
	public var maxStackDepth:Int;
	public var maxPrintDepth:Int;
	public var resources:StringMap<haxe.io.Bytes>;
	public var defines:Define;

	public function new(ctxId:Int, isMacro:Bool, ?defines:Define) {
		this.ctxId = ctxId;
		this.isMacro = isMacro;
		this.builtins = new Builtins();
		this.hadError = false;
		this.typeCache = new Map();
		this.instancePrototypes = new Map();
		this.staticPrototypes = new Map();
		this.constructors = new Map();
		this.arrayPrototype = null;
		this.stringPrototype = null;
		this.vectorPrototype = null;
		this.toplevel = VNull;
		this.eval = new Eval();
		this.maxStackDepth = 1000;
		this.maxPrintDepth = 100;
		this.resources = new StringMap();
		this.defines = defines == null ? new Define() : defines;
	}

	static var current:Null<EvalContext> = null;

	public static function getCtx():EvalContext {
		if (current == null) throw "EvalContext accessed before initialization";
		return current;
	}

	public static function setCtx(ctx:EvalContext):Void {
		current = ctx;
	}

	public static inline function getEval(ctx:EvalContext):Eval {
		return ctx.eval;
	}

	public static function createEnvInfo(isStatic:Bool, pfile:String, kind:EvalEnvKind, numLocals:Int, numCaptures:Int):EvalEnvInfo {
		return {isStatic: isStatic, file: EvalHash.hash(pfile), kind: kind, numLocals: numLocals, numCaptures: numCaptures};
	}

	public static function pushEnvironment(ctx:EvalContext, info:EvalEnvInfo):EvalEnv {
		var eval = getEval(ctx);
		var locals = info.numLocals == 0 ? [] : [for (_ in 0...info.numLocals) VNull];
		var captures = info.numCaptures == 0 ? [] : [for (_ in 0...info.numCaptures) VNull];
		var stackDepth = eval.env == null ? 1 : eval.env.stackDepth + 1;
		var env = new EvalEnv(info, locals, captures, eval.env, stackDepth, eval);
		eval.env = env;
		return env;
	}

	public static function popEnvironment(ctx:EvalContext, env:EvalEnv):Void {
		env.eval.env = env.parent;
	}

	public static function getStaticPrototypeRaise(ctx:EvalContext, path:Int):VPrototype {
		var p = ctx.staticPrototypes.get(path);
		if (p == null) throw new NotFound();
		return p;
	}

	public static function getStaticPrototype(ctx:EvalContext, path:Int, p:Position):VPrototype {
		var proto = ctx.staticPrototypes.get(path);
		if (proto == null) throw new TypingError("[" + ctx.ctxId + "] Type not found: " + EvalHash.revHash(path), p);
		return proto;
	}

	public static function getInstancePrototypeRaise(ctx:EvalContext, path:Int):VPrototype {
		var p = ctx.instancePrototypes.get(path);
		if (p == null) throw new NotFound();
		return p;
	}

	public static function getInstancePrototype(ctx:EvalContext, path:Int, p:Position):VPrototype {
		var proto = ctx.instancePrototypes.get(path);
		if (proto == null) throw new TypingError("[" + ctx.ctxId + "] Instance prototype not found: " + EvalHash.revHash(path), p);
		return proto;
	}

	public static function getInstanceConstructorRaise(ctx:EvalContext, path:Int):VFunc {
		var c = ctx.constructors.get(path);
		if (c == null) throw new NotFound();
		return c;
	}

	public static function getProtoFieldIndexRaise(proto:VPrototype, name:Int):Int {
		var i = proto.pnames.get(name);
		if (i == null) throw new NotFound();
		return i;
	}

	public static function getProtoFieldIndex(proto:VPrototype, name:Int, p:Position):Int {
		var i = proto.pnames.get(name);
		if (i == null) throw new TypingError("Field index for " + EvalHash.revHash(name) + " not found on prototype " + EvalHash.revHash(proto.ppath), p);
		return i;
	}

	public static function getInstanceFieldIndexRaise(proto:VPrototype, name:Int):Int {
		var i = proto.pinstanceNames.get(name);
		if (i == null) throw new NotFound();
		return i;
	}

	public static function getInstanceFieldIndex(proto:VPrototype, name:Int, p:Position):Int {
		var i = proto.pinstanceNames.get(name);
		if (i == null) throw new TypingError("Field index for " + EvalHash.revHash(name) + " not found on prototype " + EvalHash.revHash(proto.ppath), p);
		return i;
	}
}
