package hxc.eval;

import hxc.ast.Position;
import hxc.core.Define;
import hxc.core.Type.ModuleType;
import hxc.core.NotFound;
import hxc.core.TypingError;
import hxc.context.Context;
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
	public var min:Int;
	public var max:Int;
	public var kind:EvalEnvKind;
	public var numLocals:Int;
	public var numCaptures:Int;
	public function new(isStatic:Bool, file:Int, min:Int, max:Int, kind:EvalEnvKind, numLocals:Int, numCaptures:Int) {
		this.isStatic = isStatic;
		this.file = file;
		this.min = min;
		this.max = max;
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
	public var leavePos:Position;
	// Maps a variable id to its local slot, filled as variables are first seen. A frame made from a
	// layout shares the layout's map.
	public var slots:Map<Int, Int>;
	// The receiver for an instance method or constructor body.
	public var vthis:Null<EvalValue>;
	// The defining scope for a closure; locals not in this frame are looked up along this chain.
	public var lexicalParent:Null<EvalEnv>;
	// The layout the frame was made from (null and 0 for none): a TVar whose evalLayoutId is this id
	// sits at its evalSlot.
	public var layout:Null<hxc.core.FrameLayout>;
	public var layoutId:Int;
	public function new(info:EvalEnvInfo, locals:Array<EvalValue>, captures:Array<EvalValue>, parent:Null<EvalEnv>, stackDepth:Int, eval:Eval,
			?layout:hxc.core.FrameLayout) {
		this.info = info;
		this.locals = locals;
		this.captures = captures;
		this.parent = parent;
		this.stackDepth = stackDepth;
		this.eval = eval;
		// A fresh environment's leave position is the file start, (0,0); a call site moves it before the
		// call and a positioned throw to the throw. An environment that raises before its first call
		// reports at line 1. Null stands for that start until EvalExceptions.envPosition reads it.
		this.leavePos = null;
		this.vthis = null;
		this.layout = layout;
		if (layout != null) {
			this.slots = layout.slots;
			this.layoutId = layout.id;
		} else {
			this.slots = new Map();
			this.layoutId = 0;
		}
	}
}

// Per-thread execution state. The single-threaded interpreter uses one of these.
@:structInit
class Eval {
	public var env:Null<EvalEnv>;
	public var lastReturn:Null<EvalValue>;
	public var caughtTypes:Map<Int, Bool>;
	public var exceptionStack:Array<{pos:Position, kind:EvalEnvKind}>;
	public var currentPos:Position;
	public var lastExceptionPos:Position;
	// The record of the thread this eval runs on.
	public var thread:EvalThreadRecord;
	// A return, break or continue run in statement position (EvalEmitter.evalStmt): which one, and a
	// return's value, until the call or loop it ends takes it.
	public var ctrl:Int;
	public var ctrlValue:EvalValue;
	public function new(?thread:EvalThreadRecord) {
		this.env = null;
		this.lastReturn = null;
		this.ctrl = 0;
		this.ctrlValue = VNull;
		this.caughtTypes = new Map();
		this.exceptionStack = [];
		this.currentPos = Position.nullPos;
		this.lastExceptionPos = Position.nullPos;
		// A thread the interpreter did not start gets a record for Thread.self().
		this.thread = thread != null ? thread : new EvalThreadRecord(hxc.compiler.HostRuntime.currentIdent());
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
	// The non-persistent static initializers of every registered prototype, re-run when the interpreter is
	// reused for a new compilation.
	public var staticInits:Map<Int, {proto:VPrototype, delays:Array<hxc.eval.EvalPrototype.ProtoDelay>}>;
	public var constructors:Map<Int, VFunc>;
	// (class path, field) for every class method a subclass overrides, keyed by the path's hash and then
	// the field's name.
	public var overrides:Map<Int, Map<String, Bool>> = new Map();
	public var arrayPrototype:Null<VPrototype>;
	public var stringPrototype:Null<VPrototype>;
	public var vectorPrototype:Null<VPrototype>;
	public var toplevel:EvalValue;
	public var eval:Eval;
	public var evalTls:sys.thread.Tls<Eval>;
	// The OS thread that made this context (its thread serial), whose eval is `eval`.
	public var creatorThread:Int;
	public var maxStackDepth:Int;
	public var maxPrintDepth:Int;
	public var resources:StringMap<haxe.io.Bytes>;
	public var defines:Define;
	public var classPath:Array<String>;
	public var com:Null<Context>;

	public function new(ctxId:Int, isMacro:Bool, ?defines:Define, ?classPath:Array<String>, ?com:Context) {
		this.ctxId = ctxId;
		this.isMacro = isMacro;
		this.builtins = new Builtins();
		this.hadError = false;
		this.typeCache = new Map();
		this.instancePrototypes = new Map();
		this.staticPrototypes = new Map();
		this.staticInits = new Map();
		this.constructors = new Map();
		this.arrayPrototype = null;
		this.stringPrototype = null;
		this.vectorPrototype = null;
		this.toplevel = VNull;
		this.eval = new Eval();
		// One eval per thread; the thread-local holds every thread's but the creating one, whose eval is
		// `eval` (threadEval). The creating thread outlives the context, and its thread-local would keep
		// the whole compilation reachable after it ends.
		this.evalTls = new sys.thread.Tls();
		this.creatorThread = hxc.compiler.HostRuntime.threadSerial();
		this.defines = defines == null ? new Define() : defines;
		// The interpreter's call depth limit, `-D eval-call-stack-depth` with a default of 1000; past it
		// a call raises "Stack overflow", a catchable exception, in every world, so a runaway macro
		// reports instead of exhausting the native stack.
		var depthText = this.defines.rawDefinedValueSafe("eval_call_stack_depth", "1000");
		var parsedDepth = Std.parseInt(depthText);
		this.maxStackDepth = parsedDepth == null ? 1000 : parsedDepth;
		// Value printing truncates to <...> past this depth (default 5, overridable with -D
		// eval.print.depth).
		var printDepth = Std.parseInt(this.defines.rawDefinedValueSafe("eval_print_depth", "5"));
		this.maxPrintDepth = printDepth == null ? 5 : printDepth;
		this.resources = new StringMap();
		this.classPath = classPath == null ? [] : classPath.copy();
		this.com = com;
	}

	static var current:Null<EvalContext> = null;

	public static function getCtx():EvalContext {
		if (current == null) throw "EvalContext accessed before initialization";
		return current;
	}

	public static function setCtx(ctx:EvalContext):Void {
		current = ctx;
	}

	// The running thread's eval: `eval` on the thread that made the context, the thread-local elsewhere
	// (null for a thread with none).
	public static function threadEval(ctx:EvalContext):Null<Eval> {
		if (hxc.compiler.HostRuntime.threadSerial() == ctx.creatorThread) return ctx.eval;
		return ctx.evalTls.value;
	}

	public static function getEval(ctx:EvalContext):Eval {
		if (hxc.compiler.HostRuntime.threadSerial() == ctx.creatorThread) return ctx.eval;
		// Each new thread gets a fresh eval; a thread touching the interpreter for the first time gets its
		// own environment stack.
		var e = ctx.evalTls.value;
		if (e == null) {
			e = new Eval();
			ctx.evalTls.value = e;
		}
		return e;
	}

	public static function createEnvInfo(isStatic:Bool, pos:Position, kind:EvalEnvKind, numLocals:Int, numCaptures:Int):EvalEnvInfo {
		return {
			isStatic: isStatic,
			file: pos == null ? 0 : EvalHash.hash(pos.file),
			min: pos == null ? -1 : pos.min,
			max: pos == null ? -1 : pos.max,
			kind: kind,
			numLocals: numLocals,
			numCaptures: numCaptures
		};
	}

	static final noCaptures:Array<EvalValue> = [];

	public static function pushEnvironment(ctx:EvalContext, info:EvalEnvInfo, ?layout:hxc.core.FrameLayout):EvalEnv {
		// A function's entry is one of the polls where the tick's preemption is taken.
		if (hxc.compiler.HostRuntime.preemptPending()) EvalStdLib.preemptPoll();
		var eval = getEval(ctx);
		var locals:Array<EvalValue>;
		if (layout != null) {
			var template:Array<EvalValue> = cast layout.evalLocals;
			if (template == null || template.length != layout.size) {
				template = [for (_ in 0...layout.size) VNull];
				layout.evalLocals = cast template;
			}
			locals = template.copy();
		} else locals = info.numLocals == 0 ? [] : [for (_ in 0...info.numLocals) VNull];
		// No frame reads or writes its captures (a closure keeps its own snapshot), so the empty ones are
		// shared.
		var captures = info.numCaptures == 0 ? noCaptures : [for (_ in 0...info.numCaptures) VNull];
		var stackDepth = eval.env == null ? 1 : eval.env.stackDepth + 1;
		var env = new EvalEnv(info, locals, captures, eval.env, stackDepth, eval, layout);
		eval.env = env;
		if (profOn) profPush(env);
		return env;
	}

	public static function popEnvironment(ctx:EvalContext, env:EvalEnv):Void {
		if (profOn) profPop(env);
		env.eval.env = env.parent;
	}

	// HXC_DBG_EVALPROF: calls, inclusive and self time per interpreted function, printed with
	// HXC_DBG_TYPETIMES' report. A frame an exception unwinds is dropped when an outer frame pops.
	public static var profOn:Bool = Sys.getEnv("HXC_DBG_EVALPROF") != null;
	static var profEnvs:Array<EvalEnv> = [];
	static var profStarts:Array<Float> = [];
	static var profChild:Array<Float> = [];
	static var profNames:haxe.ds.ObjectMap<EvalEnvInfo, String> = new haxe.ds.ObjectMap();
	static var profStats:Map<String, Array<Float>> = new Map();

	static function profPush(env:EvalEnv):Void {
		profEnvs.push(env);
		profChild.push(0.0);
		profStarts.push(haxe.Timer.stamp());
	}

	static function profPop(env:EvalEnv):Void {
		var now = haxe.Timer.stamp();
		var i = profEnvs.lastIndexOf(env);
		if (i < 0) return;
		while (profEnvs.length > i + 1) { profEnvs.pop(); profStarts.pop(); profChild.pop(); }
		profEnvs.pop();
		var dt = now - profStarts.pop();
		var child = profChild.pop();
		if (profChild.length > 0) profChild[profChild.length - 1] += dt;
		var info = env.info;
		var name = profNames.get(info);
		if (name == null) {
			name = switch (info.kind) {
				case EKMethod(t, f): EvalHash.revHash(t) + "." + EvalHash.revHash(f);
				case EKLocalFunction(n): "local#" + n + " " + EvalHash.revHash(info.file) + ":" + info.min;
				case EKEntrypoint: "entry " + EvalHash.revHash(info.file) + ":" + info.min;
			};
			profNames.set(info, name);
		}
		var st = profStats.get(name);
		if (st == null) { st = [0.0, 0.0, 0.0]; profStats.set(name, st); }
		st[0] += 1;
		st[1] += dt;
		st[2] += dt - child;
	}

	public static function dumpProf():Void {
		if (!profOn) return;
		var rows = [for (k in profStats.keys()) {name: k, s: profStats.get(k)}];
		var o = Sys.stderr();
		rows.sort(function(a, b) return a.s[2] < b.s[2] ? 1 : (a.s[2] > b.s[2] ? -1 : 0));
		for (i in 0...(rows.length < 60 ? rows.length : 60)) { var r = rows[i];
			o.writeString("[eprof self] " + StringTools.lpad(Std.string(Math.round(r.s[2] * 1000)), " ", 7) + "ms incl "
			+ StringTools.lpad(Std.string(Math.round(r.s[1] * 1000)), " ", 7) + "ms "
			+ StringTools.lpad(Std.string(Std.int(r.s[0])), " ", 9) + "x  " + r.name + "
"); }
		rows.sort(function(a, b) return a.s[1] < b.s[1] ? 1 : (a.s[1] > b.s[1] ? -1 : 0));
		for (i in 0...(rows.length < 60 ? rows.length : 60)) { var r = rows[i];
			o.writeString("[eprof incl] " + StringTools.lpad(Std.string(Math.round(r.s[1] * 1000)), " ", 7) + "ms self "
			+ StringTools.lpad(Std.string(Math.round(r.s[2] * 1000)), " ", 7) + "ms "
			+ StringTools.lpad(Std.string(Std.int(r.s[0])), " ", 9) + "x  " + r.name + "
"); }
		o.flush();
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
