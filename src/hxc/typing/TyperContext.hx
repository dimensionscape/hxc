package hxc.typing;

import hxc.core.Type;
import hxc.context.Context;
import hxc.ast.Position;
import haxe.ds.StringMap;

@:structInit
class TyperContext {
	public var com:Context;
	public var t:BasicTypes;
	public var locals:StringMap<TVar>;
	public var typeParams:TypeParams;
	public var inLoop:Bool;
	public var inFunction:Bool;
	public var untypedMode:Bool;
	// True while call arguments type; a structure mismatch then raises (annotated with the
	// parameter name by the caller) instead of recording.
	public var inCallArgs:Bool = false;
	/** Newest first. */
	public var monomorphs:Array<{m:TMono, p:Position}>;
	/** Expected return type of the function being typed. */
	public var ret:T;
	public var curfun:CurrentFun;
	// Every object-declaration anon is created with a Const status ref that is REGISTERED here,
	// and all of them flip to Closed when the enclosing function finishes typing. Without the list
	// they stay Const for good, which --json prints.
	public var opened:Array<hxc.core.Ref<hxc.core.Type.AnonStatus>> = [];
	public var curclass:TClass;
	public var tthis:T;
	public var curfield:TClassField;
	public var vthis:Null<TVar>;
	// @:bypassAccessor nesting counter: each field access consumes one, forcing a raw field access.
	public var bypassAccessor:Int;
	// Context.withOptions turns these off for one callback; field access, calls, call-argument
	// unification and for-loop typing read them.
	public var allowInline:Bool = true;
	public var allowTransform:Bool = true;
	public var privateAccess:Int;

	public function new(com:Context) {
		this.com = com;
		this.t = com.basic;
		this.locals = new StringMap();
		this.typeParams = [];
		this.inLoop = false;
		this.inFunction = true; // Core-subset exprs are typed as if inside a function body
		this.untypedMode = false;
		this.monomorphs = [];
		// Fresh monomorph: an open return type at the top level, since a not-yet-constrained
		// Dynamic/inferred function return is a TMono.
		this.ret = hxc.core.TypeFunctions.mkMono();
		this.curfun = FunStatic;
		// No enclosing class at top level: a fresh typer has a monomorph for `this` and the null
		// field as its current field.
		this.curclass = hxc.core.TypeFunctions.nullClass;
		this.tthis = hxc.core.TypeFunctions.mkMono();
		this.curfield = hxc.core.TypeFunctions.nullField;
		this.vthis = null;
		this.bypassAccessor = 0;
		this.privateAccess = 0;
	}

	// A unification failure while typing is recorded, not raised, unless we are inside call arguments
	// (where the caller retries another overload). Recording is what lets a second, later error on the
	// same expression be reported.
	public static function raiseOrDisplay(ctx:TyperContext, msg:String, p:hxc.ast.Position, depth:Int = 0):Void {
		if (ctx.untypedMode) return;
		if (ctx.inCallArgs) throw new hxc.core.TypingError(msg, p, depth);
		ctx.com.addDiagnostic(msg, p, depth);
	}
}

// The kinds of current function that typing a local function or a return distinguishes.
enum CurrentFun {
	FunMember;
	FunStatic;
	FunConstructor;
	FunMemberAbstract;
	FunMemberAbstractLocal;
	FunMemberClassLocal;
}
