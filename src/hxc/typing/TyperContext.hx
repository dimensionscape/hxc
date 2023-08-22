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
	/** Newest first. */
	public var monomorphs:Array<{m:TMono, p:Position}>;
	/** Expected return type of the function being typed. */
	public var ret:T;
	public var curfun:CurrentFun;
	public var curclass:TClass;
	public var tthis:T;
	public var curfield:TClassField;
	public var vthis:Null<TVar>;
	// @:bypassAccessor nesting counter: each field access consumes one, forcing a raw field access.
	public var bypassAccessor:Int;

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
