package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.OverloadResolution;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.ExternMembers;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.TclassToIl.ClassPlan;
import hxc.codegen.dotnet.TclassToIl.MethodPlan;
import hxc.codegen.dotnet.TexprCalls.arrayOf;
import hxc.codegen.dotnet.TexprCalls.isNativeArray;
import hxc.codegen.dotnet.TexprCalls.vectorElement;

// Where an expression's value goes: onto the stack as a slot of the given type (null: its own),
// nowhere, or out of the function (a function body, whose value is not used, and the expressions
// that end it: the last of a block, the branches of an if, switch or try).
enum Ret {
	RValue(t:Null<IlSigNorm>);
	RVoid;
	RReturn;
}

// A catch body or a finally handler that encloses the code being lowered. `v` and `body` are the catch
// variable and the catch's body, for the rethrow of the variable; a finally handler has neither.
typedef HandlerFrame = {isCatch:Bool, v:Null<TVar>, body:Null<TExpr>};

// A local or argument slot.
typedef Slot = {arg:Bool, index:Int, sig:IlSigNorm};

// Something that can be loaded and stored. `prepare` pushes the receiver, if there is one; `load` keeps
// it under the value and `store` takes both.
typedef Place = {sig:IlSigNorm, receiver:Bool, prepare:Void->Void, load:Void->Void, store:Void->Void};

// How an operand is treated when operands are spilled before a try: evaluated into a temporary, left
// where it is, or refused.
enum SpillMode {
	Spill;
	Keep;
	Refuse;
}

// One method body's expressions as IL. Anything outside the subset this milestone compiles throws
// Unsupported naming it.

@:allow(hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprFlow, hxc.codegen.dotnet.TexprCalls, hxc.codegen.dotnet.TexprDynamic,
	hxc.codegen.dotnet.CsToIl, hxc.codegen.dotnet.CsNames)
class TexprToIl {
	final g:DotnetCtx;
	final code:IlCode;
	final ret:IlSigNorm;
	final slots = new Map<Int, Slot>();
	// Variables whose declaration failed to lower; a failing statement that uses one is not reported
	// again.
	final poisoned = new Map<Int, Bool>();
	// Where break and continue go, innermost loop last, with the try depth each loop was entered at.
	final loops:Array<{brk:Label, cont:Label, tries:Int}> = [];
	// How many try blocks and handlers enclose the code being lowered. A jump out of one is a `leave`.
	var tryDepth = 0;
	// The catch bodies and finally handlers being lowered, innermost last. IL `rethrow` is valid exactly
	// when the last one is a catch; a local function is lowered by a TexprToIl of its own, so it starts
	// with none.
	final handlers:Array<HandlerFrame> = [];
	// Where a `return` inside a try goes: a label after the outermost try, which returns the value
	// stored in `retLocal` (-1 until needed).
	var retLabel:Label = -1;
	var retLocal = -1;
	// Temporaries that operands were spilled to; they are never spilled again.
	final temps = new Map<Int, Bool>();

	// The rest of the lowering, which reaches this class's state through it.
	final ops:TexprOps;
	final flow:TexprFlow;
	final calls:TexprCalls;
	final dyn:TexprDynamic;
	final inlineCs:CsToIl;

	// The expressions nullOperand marked (stripped): a Null<T> read through Runtime among them keeps its
	// ofDynamic step.
	final keepNull:Array<TExpr> = [];

	// Set for user code: a statement that fails to lower is reported here and lowering goes on with
	// the next one. Unset, the Unsupported propagates.
	public var onError:Null<Unsupported->Void> = null;

	// The class whose method this is, and its own type as `this` has it (null in a static method).
	public var cls:Null<TClass> = null;
	public var thisSig:Null<IlSigNorm> = null;
	// Set in a static __hx_ctor_* method: `this` is its first argument, and super(...) calls the base
	// class's static constructor.
	public var splitCtor = false;

	// The method's Haxe return type where it has one: `return e` casts into it as a store does (texprTo).
	public var retType:Null<T> = null;

	// Whether lowering records sequence points: under -debug, in the methods that hold the user's
	// expressions (TclassToIl.emitMethod).
	public var points = false;
	// The position of the statement, condition or catch whose point was recorded last.
	var statementPos:Null<Position> = null;

	public function new(g:DotnetCtx, code:IlCode, ret:IlSigNorm) {
		this.g = g;
		this.code = code;
		this.ret = ret;
		ops = new TexprOps(this);
		flow = new TexprFlow(this);
		calls = new TexprCalls(this);
		dyn = new TexprDynamic(this);
		inlineCs = new CsToIl(this);
	}

	public function bindArg(v:TVar, index:Int, sig:IlSigNorm):Void {
		slots.set(v.id, {arg: true, index: index, sig: sig});
	}

	// Binds a method's arguments, the first at `first`, and applies their default values at the top of the
	// body, the last argument first, as gencommon's default arguments do: a reference argument gets
	// `if (a == null) a = v`; a haxe.lang.Null<T> one leaves the variable to a new local of its own type,
	// `!a.hasValue ? v : a.value`. An argument whose default is null needs nothing.
	public function bindArgs(tf:TFunc, first:Int, sigs:Array<IlSigNorm>):Void {
		for (i in 0...tf.args.length) bindArg(tf.args[i].v, first + i, sigs[i]);
		defaultArgs(tf);
	}

	// Binds the arguments of an override that takes its slot's signature `sigs` (TclassToIl.OverrideShape):
	// each one whose own type `own` differs goes into a new local of that type, converted, the last first,
	// as gencs's FixOverrides declares them at the top of the body; then the default values.
	public function bindOwnArgs(tf:TFunc, sigs:Array<IlSigNorm>, own:Array<IlSigNorm>):Void {
		var i = tf.args.length;
		while (i-- > 0) {
			var v = tf.args[i].v;
			if (IlPaths.sigEq(sigs[i], own[i])) {
				bindArg(v, 1 + i, sigs[i]);
				continue;
			}
			var local = {arg: false, index: code.addLocal(own[i]), sig: own[i]};
			code.ldarg(1 + i);
			convert(sigs[i], own[i]);
			store(local);
			slots.set(v.id, local);
		}
		defaultArgs(tf);
	}

	function defaultArgs(tf:TFunc):Void {
		var i = tf.args.length;
		while (i-- > 0) {
			var a = tf.args[i];
			if (a.c == null || isNullConst(a.c)) continue;
			var arg = slots.get(a.v.id);
			if (isHaxeNull(arg.sig)) {
				var own = sig(a.v.type);
				var local = {arg: false, index: code.addLocal(own), sig: own};
				var has = code.newLabel(), end = code.newLabel();
				load(arg);
				loadNullField(arg.sig, "hasValue");
				code.branch(IlOps.BRTRUE, has);
				texpr(RValue(own), a.c);
				code.branch(IlOps.BR, end);
				code.mark(has);
				load(arg);
				convert(arg.sig, own);
				code.mark(end);
				store(local);
				slots.set(a.v.id, local);
			} else if (isReference(arg.sig)) {
				var set = code.newLabel();
				load(arg);
				code.branch(IlOps.BRTRUE, set);
				texpr(RValue(arg.sig), a.c);
				store(arg);
				code.mark(set);
			} else {
				throw new Unsupported("default argument values of this type", true, a.c.pos);
			}
		}
	}

	// Lowers `e` as an operand that gencs's HardNullableSynf unwraps itself. Everywhere else a Null<T>
	// field read through Runtime meets a cast CastDetect put there, and HardNullableSynf drops the
	// Nullable step under it (an outer cast of a Null<T>-typed cast reruns with the outer type), so the
	// object goes straight to the cast's type (TexprDynamic.fieldGet); a marked read goes through
	// `ofDynamic<T>` and `.value` or `toDynamic()`.
	// `self`: `e` itself is marked, as an operand of `+`, of an ordering comparison or of a string
	// concatenation is. Otherwise only the value tails of a Null<T>-typed conditional, switch or block
	// are, as for the operands of the other operators, `==`, an index or `op=`: there a field read
	// itself was cast first (by DynamicOperators or CastDetect), but a conditional typed Null<T> is
	// unwrapped as a whole and its branches, typed Null<T> as well, keep ofDynamic.
	function nullOperand(ret:Ret, e:TExpr, self = true):Void {
		var n = keepNull.length;
		markTails(e, self);
		try {
			texpr(ret, e);
		} catch (x:Dynamic) {
			keepNull.resize(n);
			throw x;
		}
		keepNull.resize(n);
	}

	function markTails(e:TExpr, self:Bool):Void {
		var s = strip(e);
		if (self) keepNull.push(s);
		if (!TexprDynamic.isNullType(s.type)) return;
		switch (s.expr) {
			case TIf(_, e1, e2):
				markTails(e1, true);
				if (e2 != null) markTails(e2, true);
			case TSwitch(_, cases, def):
				for (c in cases) markTails(c.expr, true);
				if (def != null) markTails(def, true);
			case TBlock(el) if (el.length > 0):
				markTails(el[el.length - 1], true);
			case _:
		}
	}

	// A local the caller added and fills itself.
	public function bindLocal(v:TVar, index:Int, sig:IlSigNorm):Void {
		slots.set(v.id, {arg: false, index: index, sig: sig});
	}

	// haxe.lang.Runtime, whose code gencs lowers as plain C#: a Dynamic converts to Int, Float or a
	// String with a C# cast (unbox.any, castclass), not through Runtime's own toInt, toDouble, toString.
	function inRuntimeClass():Bool {
		return cls != null && DotnetTypes.haxePath(TClassDecl(cls)) == "cs.internal.Runtime";
	}

	// A sequence point at statement `e`, unless it is a block, whose statements have their own, or a `var`
	// without a value.
	public function statementPoint(e:TExpr):Void {
		if (!points) return;
		switch (e.expr) {
			case TBlock(_) | TVarExpr(_, null):
			case _:
				statementPos = e.pos;
				code.point(e.pos);
		}
	}

	// A sequence point at a condition or a switch's subject, inside its parentheses.
	function conditionPoint(e:TExpr):Void {
		if (!points) return;
		statementPos = strip(e).pos;
		code.point(statementPos);
	}

	// A sequence point at a catch's variable, where its handler starts with the exception on the stack.
	function catchPoint(v:TVar):Void {
		if (!points) return;
		statementPos = v.pos;
		code.point(v.pos, true);
	}

	// Under -debug, the name of the local that holds `v`, for a debugger: the user's variables, inlined
	// ones and an abstract's `this`; the typer's and hxc's temporaries stay unnamed.
	function nameLocal(v:TVar, index:Int):Void {
		switch (v.kind) {
			case VUser(_) | VInlined: code.nameLocal(index, v.name);
			case VAbstractThis: code.nameLocal(index, "this");
			case VGenerated | VInlinedConstructorVariable | VExtractorVariable:
		}
	}

	// Before a part of the current statement that may record points of its own (a value block's
	// statements, a value `try`'s catches): what resumePoint needs, or -1 without points.
	function pointMark():Int {
		return points ? code.pointEdits : -1;
	}

	// After that part, where the stack is empty again (a value block's last expression, the end of a
	// value `try`): if it recorded points, the statement's again, so that the rest of the statement, and
	// a throw in it, has the statement's line. The JIT maps a stack frame back to the last IL offset where
	// the stack was empty, so a point anywhere later would not count.
	function resumePoint(mark:Int, outer:Null<Position>):Void {
		if (mark < 0) return;
		statementPos = outer;
		if (code.pointEdits != mark && outer != null) code.point(outer);
	}

	public function texpr(ret:Ret, e:TExpr):Void {
		if (!code.reachable()) return;
		try {
			expr(ret, e);
		} catch (u:Unsupported) {
			if (u.pos == null) u.pos = e.pos;
			throw u;
		}
	}

	// The end of the body: a void method returns. The typer has checked that a method with a value
	// never reaches its end, so reaching it here is a reachability rule TexprFlow lacks.
	public function finish():Void {
		if (!code.reachable()) return;
		if (!ret.match(LVoid)) throw Unsupported.bug(code.what + " falls off its end without a return (an hxc reachability bug)");
		// No Haxe line wrote the implicit return.
		if (points) code.point(null);
		code.op(IlOps.RET, 0, 0);
	}

	// The default value of `s`: C#'s default(T).
	function pushDefault(s:IlSigNorm):Void {
		if (DotnetTypes.isValueType(s) || isTypeParam(s)) defaultValue(s) else code.op(IlOps.LDNULL, 0, 1);
	}

	static inline function needVal(ret:Ret):Bool return ret.match(RValue(_));

	// The type of a value of type `t`. A cs.Ref or cs.Out is a parameter's own type only: a variable or
	// value of that type, such as `var node = head` for a cs.Ref parameter `head`, has the referenced type,
	// as in C#.
	function sig(t:T):IlSigNorm {
		return switch (g.types.toSig(t)) {
			case LManagedPointer(s): s;
			case s: s;
		}
	}

	static function isTypeParam(s:IlSigNorm):Bool return s.match(LTypeParam(_) | LMethodTypeParam(_));

	// Moves a value of type `from` (null: the null reference, LVoid: nothing) to where `ret` wants it.
	function coerce(from:Null<IlSigNorm>, ret:Ret):Void {
		switch (ret) {
			case RVoid | RReturn:
				if (from == null || !from.match(LVoid)) code.op(IlOps.POP, 1, 0);
			case RValue(null):
				if (from != null && from.match(LVoid)) throw new Unsupported("Void values", true);
			case RValue(to):
				if (from != null && from.match(LVoid)) throw new Unsupported("Void values", true);
				convert(from, to);
		}
	}

	function convert(from:Null<IlSigNorm>, to:IlSigNorm):Void {
		if (from == null) {
			// null as a type parameter is C#'s default(T).
			if (isTypeParam(to)) {
				code.op(IlOps.POP, 1, 0);
				defaultValue(to);
				return;
			}
			// null as a haxe.lang.Null<T> is C#'s default(Null<T>), which has no value.
			if (isHaxeNull(to)) {
				code.op(IlOps.POP, 1, 0);
				defaultValue(to);
				return;
			}
			// null as a .NET value type (Nullable<T>, a struct, an enum, IntPtr) is C#'s default(T), as gencs writes it.
			if (to.match(LValueType(_, _) | LIntPtr | LUIntPtr)) {
				code.op(IlOps.POP, 1, 0);
				defaultValue(to);
				return;
			}
			if (DotnetTypes.isValueType(to)) throw new Unsupported("null as a value type", false);
			return;
		}
		if (IlPaths.sigEq(from, to)) return;
		if (isHaxeNull(from) || isHaxeNull(to)) {
			nullConvert(from, to);
			return;
		}
		// Int and UInt are both an int32 on the stack, Int64 and UInt64 both an int64.
		if (isIntLike(from) && isIntLike(to) || is64(from) && is64(to)) return;
		// A .NET enum and its underlying integer are the same value on the stack, as C#'s casts between
		// them.
		if (sameAsEnum(from, to) || sameAsEnum(to, from)) return;
		// So is a smaller integer, widened as C# does implicitly.
		if (from.match(LChar | LInt8 | LUInt8 | LInt16 | LUInt16) && to.match(LInt32)) return;
		// And so are C#'s other implicit widenings between the small integers, Char and UInt.
		if (from.match(LInt8) && to.match(LInt16) || from.match(LUInt8) && to.match(LInt16 | LUInt16 | LUInt32)
			|| from.match(LUInt16 | LChar) && to.match(LUInt32) || from.match(LChar) && to.match(LUInt16))
			return;
		// A value into a System.Nullable of its type, which C# wraps implicitly.
		switch (to) {
			case LValueType(_, [a]) if (DotnetTypes.isSystemNullable(to) && IlPaths.sigEq(from, a)):
				code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(to), ".ctor", g.sigs.method(true, LVoid, [LTypeParam(0)], 0)), 1, 1);
				return;
			case _:
		}
		var fromValue = DotnetTypes.isValueType(from) || isTypeParam(from);
		var toValue = DotnetTypes.isValueType(to) || isTypeParam(to);
		if (to.match(LString) && !inRuntimeClass()) {
			// Runtime.toString, as gencs converts anything that is not a String to one (outside
			// haxe.lang.Runtime, whose code casts).
			if (fromValue) code.opToken(IlOps.BOX, g.typeTokenOf(from), 1, 1);
			dyn.toSig(to);
		} else if (fromValue && !toValue) {
			code.opToken(IlOps.BOX, g.typeTokenOf(from), 1, 1);
			// A boxed type parameter is an object, which may not be the reference type wanted; nor is a
			// boxed struct an instantiation of a generic Haxe interface it does not implement.
			if (isTypeParam(from) && !to.match(LObject)) castTo(to);
			// A generic struct goes to another generic interface's instantiation as itself (instanceCast).
			else if (g.isGenericHaxeClass(to) && !g.isUpcast(from, to)) instanceCast(g.isGenericHaxeClass(from) ? from : LObject, to);
		} else if (!fromValue && toValue) {
			// gencs converts Dynamic through Runtime.toInt, toDouble, toBool and genericCast, which accept
			// null and boxed numbers of another type; an unbox.any would throw on them.
			if (from.match(LObject)) {
				dyn.toSig(to);
				return;
			}
			code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
		} else if (fromValue) {
			if (from.match(LInt32) && to.match(LFloat64)) code.op(IlOps.CONV_R8, 1, 1);
			else if (from.match(LUInt32) && to.match(LFloat64)) {
				code.op(IlOps.CONV_R_UN, 1, 1);
				code.op(IlOps.CONV_R8, 1, 1);
			} else if (from.match(LFloat64 | LInt64 | LUInt64) && to.match(LInt32)) code.op(IlOps.CONV_I4, 1, 1);
			// To Single and Int64 as C#'s casts, and Int's implicit widening, convert.
			else if (from.match(LFloat64 | LInt32 | LInt64 | LInt8 | LInt16 | LUInt8 | LUInt16 | LChar) && to.match(LFloat32)) code.op(IlOps.CONV_R4, 1, 1);
			else if (from.match(LUInt32 | LUInt64) && to.match(LFloat32)) {
				code.op(IlOps.CONV_R_UN, 1, 1);
				code.op(IlOps.CONV_R4, 1, 1);
			} else if (from.match(LFloat64 | LInt32 | LInt8 | LInt16) && to.match(LInt64)) code.op(IlOps.CONV_I8, 1, 1);
			// Int64 widens to Float, as C# does implicitly, and so do Single and the small integers.
			else if (from.match(LFloat32 | LInt8 | LInt16 | LInt64) && to.match(LFloat64)) code.op(IlOps.CONV_R8, 1, 1);
			else if (from.match(LUInt8 | LUInt16 | LChar | LUInt64) && to.match(LFloat64)) {
				code.op(IlOps.CONV_R_UN, 1, 1);
				code.op(IlOps.CONV_R8, 1, 1);
			}
			else if (from.match(LUInt32 | LUInt8 | LUInt16 | LChar) && is64(to)) code.op(IlOps.CONV_U8, 1, 1);
			// C#'s (ulong) of an int sign-extends, and of a double converts unsigned.
			else if (from.match(LInt32 | LInt8 | LInt16) && to.match(LUInt64)) code.op(IlOps.CONV_I8, 1, 1);
			else if (from.match(LFloat64) && to.match(LUInt64)) code.op(IlOps.CONV_U8, 1, 1);
			// To the small integers and Char, as C#'s unchecked casts truncate.
			else if (from.match(LInt32 | LUInt32 | LInt64 | LUInt64 | LChar | LInt8 | LUInt8 | LInt16 | LUInt16) && to.match(LChar | LUInt16)) code.op(IlOps.CONV_U2, 1, 1);
			else if (from.match(LInt32 | LUInt32 | LInt64 | LUInt64 | LChar | LInt8 | LUInt8 | LInt16 | LUInt16) && to.match(LInt16)) code.op(IlOps.CONV_I2, 1, 1);
			else if (from.match(LInt32 | LUInt32 | LInt64 | LUInt64 | LChar | LInt8 | LUInt8 | LInt16 | LUInt16) && to.match(LUInt8)) code.op(IlOps.CONV_U1, 1, 1);
			else if (from.match(LInt32 | LUInt32 | LInt64 | LUInt64 | LChar | LInt8 | LUInt8 | LInt16 | LUInt16) && to.match(LInt8)) code.op(IlOps.CONV_I1, 1, 1);
			else if (from.match(LFloat64 | LInt64 | LUInt64) && to.match(LUInt32)) code.op(IlOps.CONV_U4, 1, 1);
			else if (isTypeParam(from) || isTypeParam(to)) {
				// Between a type parameter and another type that is one at run time, as C# casts through object.
				code.opToken(IlOps.BOX, g.typeTokenOf(from), 1, 1);
				code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
			} else if (g.isGenericHaxeClass(from) && g.isGenericHaxeClass(to)) {
				// Two instantiations of a generic struct, which has no companion interface (CompanionToIl).
				throw new Unsupported("a cast between instantiations of " + g.haxePathOf(to), false);
			} else throw new Unsupported("conversions between value types", true);
		} else if (isReference(from) && isReference(to) && !to.match(LObject)) {
			// An upcast needs nothing; anything else may narrow.
			if (g.isUpcast(from, to) || from.match(LVector(_)) && isSystemArray(to)) return;
			if (g.isGenericHaxeClass(to)) instanceCast(from, to) else castTo(to);
		}
	}

	// True when `a` is a .NET enum whose values are stored as `b`.
	function sameAsEnum(a:IlSigNorm, b:IlSigNorm):Bool {
		return switch (a) {
			case LValueType(p, []):
				var u = g.externs.enumUnderlying(p);
				u != null && (IlPaths.sigEq(u, b) || isIntLike(u) && isIntLike(b));
			case _: false;
		}
	}

	static function isSystemArray(s:IlSigNorm):Bool {
		return switch (s) {
			case LClass(p, []): p.ns.length == 1 && p.ns[0] == "System" && p.nested.length == 0 && p.name == "Array";
			case _: false;
		}
	}

	static function isIntLike(s:IlSigNorm):Bool return s.match(LInt32 | LUInt32);

	static function is64(s:IlSigNorm):Bool return s.match(LInt64 | LUInt64);

	// gencs's haxe.lang.Null<T>, which Null<T> of a value type maps to.
	function isHaxeNull(s:IlSigNorm):Bool {
		return s.match(LValueType(_, [_])) && g.haxePathOf(s) == "cs.internal._Null.Nullable";
	}

	// The T of a haxe.lang.Null<T>, or null for any other type.
	function nullArg(s:IlSigNorm):Null<IlSigNorm> {
		return switch (s) {
			case LValueType(_, [a]) if (isHaxeNull(s)): a;
			case _: null;
		}
	}

	// A haxe.lang.Null<T>'s T, any other type itself: the type a Null<T> operand is computed in.
	function unNull(s:IlSigNorm):IlSigNorm {
		var a = nullArg(s);
		return a == null ? s : a;
	}

	// Reads the field `value` (a T) or `hasValue` of the haxe.lang.Null<T> `s` on the stack.
	function loadNullField(s:IlSigNorm, name:String):Void {
		var token = g.mb.memberRef(g.typeTokenOf(s), name, g.sigs.field(name == "value" ? LTypeParam(0) : LBool));
		code.opToken(IlOps.LDFLD, token, 1, 1);
	}

	// `new Null<T>(v, true)` with v on the stack: the constructor, which also checks a reference for null.
	function newNull(s:IlSigNorm):Void {
		code.ldcI4(1);
		var token = g.mb.memberRef(g.typeTokenOf(s), ".ctor", g.sigs.method(true, LVoid, [LTypeParam(0), LBool], 0));
		code.opToken(IlOps.NEWOBJ, token, 2, 1);
	}

	// `x.toDynamic()` on the haxe.lang.Null<T> `s` on the stack: its value boxed, or null.
	function nullToDynamic(s:IlSigNorm):Void {
		var tmp = code.addLocal(s);
		code.stloc(tmp);
		code.ldloca(tmp);
		code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(s), "toDynamic", g.sigs.method(true, LObject, [], 0)), 1, 1);
	}

	// `Null<object>.ofDynamic<T>(d)` for the object on the stack, as gencs converts a Dynamic to the
	// haxe.lang.Null<T> `s`.
	function ofDynamic(s:IlSigNorm):Void {
		switch (s) {
			case LValueType(p, [arg]):
				var token = g.mb.memberRef(g.typeTokenOf(LValueType(p, [LObject])), "ofDynamic",
					g.sigs.method(false, LValueType(p, [LMethodTypeParam(0)]), [LObject], 1));
				code.opToken(IlOps.CALL, g.mb.methodSpec(token, g.sigs.methodSpec([arg])), 1, 1);
			case _:
				throw "internal error: not a haxe.lang.Null: " + s;
		}
	}

	// A conversion to or from haxe.lang.Null<T>, as gencs's HardNullableSynf writes it: a T wraps with
	// `new Null<T>(v, true)` and a Dynamic with `ofDynamic`; a Null<T> reads its `value` (T's default
	// when it has none), or goes to Dynamic, a String or another reference type through `toDynamic()`;
	// between two instantiations, `x.hasValue ? new Null<B>((B)x.value, true) : default(Null<B>)`.
	function nullConvert(from:IlSigNorm, to:IlSigNorm):Void {
		var fa = nullArg(from), ta = nullArg(to);
		if (fa != null && ta != null) {
			var tmp = code.addLocal(from);
			code.stloc(tmp);
			var none = code.newLabel(), end = code.newLabel();
			code.ldloc(tmp);
			loadNullField(from, "hasValue");
			code.branch(IlOps.BRFALSE, none);
			code.ldloc(tmp);
			loadNullField(from, "value");
			convert(fa, ta);
			newNull(to);
			code.branch(IlOps.BR, end);
			code.mark(none);
			defaultValue(to);
			code.mark(end);
		} else if (ta != null) {
			if (from.match(LObject)) {
				ofDynamic(to);
			} else {
				convert(from, ta);
				newNull(to);
			}
		} else if (isReference(to)) {
			nullToDynamic(from);
			convert(LObject, to);
		} else {
			loadNullField(from, "value");
			convert(fa, to);
		}
	}


	// C#'s default(T): a zeroed temporary.
	function defaultValue(t:IlSigNorm):Void {
		var tmp = code.addLocal(t);
		code.ldloca(tmp);
		code.opToken(IlOps.INITOBJ, g.typeTokenOf(t), 1, 0);
		code.ldloc(tmp);
	}

	// A null typed Dynamic going where `ret` wants a value type, as gencs converts it: that type's
	// default, as Runtime.toInt(null) and the like give. False, and nothing pushed, when `ret` wants no
	// value type.
	function nullDefault(ret:Ret, t:T):Bool {
		var to = switch (ret) {
			case RValue(null): sig(t);
			case RValue(s): s;
			case _: return false;
		}
		if (!DotnetTypes.isValueType(to) || isHaxeNull(to)) return false;
		defaultValue(to);
		return true;
	}

	// The reference `from` on the stack as `to`, an instantiation of a generic Haxe class that `from` is not
	// already: what gencs's RealTypeParams makes of a cast to `to` (InstantiationCasts), or castclass for a
	// downcast to the one instantiation the source's type allows, as the Map abstract's downcast of an
	// IMap<String, V> to its StringMap<V> is (DotnetCtx.isExactDowncast). A value typed as a companion
	// interface (an X<Dynamic>) goes through __hx_cast like any other; a typed value going to one needs no
	// cast at all, since every instantiation is its class's companion (decision 1 of plan 3c).
	public function instanceCast(from:IlSigNorm, to:IlSigNorm):Void {
		if (g.isExactDowncast(from, to)) {
			code.opToken(IlOps.CASTCLASS, g.typeTokenOf(to), 1, 1);
			return;
		}
		InstantiationCasts.emit(g, code, from, to);
	}

	// Whether a value of type `from` going to `to` needs a cast between instantiations (instanceCast): `to`
	// an instantiation of a generic Haxe class, `from` a reference that is not already one.
	function needsInstanceCast(from:IlSigNorm, to:IlSigNorm):Bool {
		return to.match(LClass(_, _)) && g.isGenericHaxeClass(to) && from.match(LObject | LClass(_, _)) && !IlPaths.sigEq(from, to)
			&& !g.isUpcast(from, to);
	}

	// `e` where a `to` is wanted, `target` the Haxe type of where it goes, null when the caller does not know
	// it: as texpr(RValue(to), e), but where the target is known and the value's own type needs a cast between
	// instantiations, the value is lowered as its own type and cast (instanceCast), as gencs casts into it.
	public function texprTo(to:IlSigNorm, target:Null<T>, e:TExpr):Void {
		var own = target == null || isNullConst(e) ? null : try sig(e.type) catch (_:Unsupported) null;
		if (own != null && needsInstanceCast(own, to)) {
			texpr(RValue(own), e);
			instanceCast(own, to);
			return;
		}
		texpr(RValue(to), e);
	}

	// `e` stored where a `to` is kept, `target` the Haxe type of the place: as texprTo, but a place whose type
	// is erased to object (an Array<Array<Int>>'s element, a T field of a G<Array<Int>>) takes the value as
	// an instantiation of its Haxe type first, as gencs casts into it. An X<Dynamic> place keeps the value as
	// it is: its type is the companion, which every instantiation is.
	public function texprStore(to:IlSigNorm, target:T, e:TExpr):Void {
		if (to.match(LObject) && !isNullConst(e)) {
			var want = try sig(target) catch (_:Unsupported) null;
			if (want != null && want.match(LClass(_, _)) && g.isGenericHaxeClass(want)) {
				texprTo(want, target, e);
				return;
			}
		}
		texprTo(to, target, e);
	}

	function castTo(to:IlSigNorm):Void {
		if (g.isGenericHaxeClass(to)) instanceCast(LObject, to) else code.opToken(IlOps.CASTCLASS, g.typeTokenOf(to), 1, 1);
	}

	static function isReference(s:IlSigNorm):Bool return s.match(LObject | LString | LClass(_, _) | LVector(_) | LArray(_, _));

	function slot(v:TVar):Slot {
		var s = anySlot(v);
		if (s.sig.match(LManagedPointer(_))) throw new Unsupported("cs.Ref and cs.Out parameters", true);
		return s;
	}

	// The slot of a variable, a cs.Ref or cs.Out parameter's too.
	function anySlot(v:TVar):Slot {
		var s = slots.get(v.id);
		// The statement using it is not reported again: the declaration already was.
		if (s == null && poisoned.exists(v.id)) throw new Unsupported("a variable whose declaration failed", false);
		if (s == null) throw "internal error: unbound variable " + v.name;
		return s;
	}

	// The type of the variable a cs.Ref or cs.Out parameter's slot holds the address of, else null.
	static function refTarget(s:Slot):Null<IlSigNorm> {
		return switch (s.sig) {
			case LManagedPointer(t): t;
			case _: null;
		}
	}

	// Through the address on the stack, as C# reads and writes a ref parameter.
	function loadIndirect(t:IlSigNorm):Void {
		var short = IlCode.ldindOf(t);
		if (short >= 0) code.op(short, 1, 1)
		else if (DotnetTypes.isValueType(t) || isTypeParam(t)) code.opToken(IlOps.LDOBJ, g.typeTokenOf(t), 1, 1)
		else code.op(IlOps.LDIND_REF, 1, 1);
	}

	function storeIndirect(t:IlSigNorm):Void {
		var short = IlCode.stindOf(t);
		if (short >= 0) code.op(short, 2, 0)
		else if (DotnetTypes.isValueType(t) || isTypeParam(t)) code.opToken(IlOps.STOBJ, g.typeTokenOf(t), 2, 0)
		else code.op(IlOps.STIND_REF, 2, 0);
	}

	// The prefix a load or store of a @:volatile field takes, as C# compiles a volatile field's.
	function volatilePrefix(cf:TClassField):Void {
		if (TypeFunctions.hasMeta(":volatile", cf.meta)) code.op(IlOps.VOLATILE, 0, 0);
	}

	function load(s:Slot):Void {
		if (s.arg) code.ldarg(s.index) else code.ldloc(s.index);
	}

	function store(s:Slot):Void {
		if (s.arg) code.starg(s.index) else code.stloc(s.index);
	}

	function expr(ret:Ret, e:TExpr):Void {
		var spilled = flow.spillForTry(e);
		if (spilled != null) {
			expr(ret, spilled);
			return;
		}
		switch (e.expr) {
			case TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_) | TNull) | TLocal(_) if (!needVal(ret)):
			case TConst(TInt(v)):
				code.ldcI4(v);
				coerce(LInt32, ret);
			case TConst(TFloat(s)):
				code.opR8(IlOps.LDC_R8, Std.parseFloat(s), 0, 1);
				coerce(LFloat64, ret);
			case TConst(TString(s)):
				code.opToken(IlOps.LDSTR, g.mb.userString(s), 0, 1);
				coerce(LString, ret);
			case TConst(TBool(b)):
				code.ldcI4(b ? 1 : 0);
				coerce(LBool, ret);
			case TConst(TNull):
				if (TexprDynamic.isTDynamic(e.type) && nullDefault(ret, e.type)) return;
				code.op(IlOps.LDNULL, 0, 1);
				coerce(null, ret);
			case TConst(TThis):
				if (thisSig == null) throw new Unsupported("`this`", false);
				code.ldarg(0);
				// A struct's `this` is its address.
				if (DotnetTypes.isValueType(thisSig)) code.opToken(IlOps.LDOBJ, g.typeTokenOf(thisSig), 1, 1);
				coerce(thisSig, ret);
			case TConst(TSuper):
				throw new Unsupported("`super`", false);
			case TLocal(v):
				var s = anySlot(v);
				var target = refTarget(s);
				load(s);
				if (target != null) loadIndirect(target);
				coerce(target != null ? target : s.sig, ret);
			case TVarExpr(v, init):
				// A variable of a type not supported yet is reported after what its initializer uses.
				var s = try sig(v.type) catch (u:Unsupported) {
					if (init != null) texpr(RValue(null), init);
					throw u;
				}
				var local = {arg: false, index: code.addLocal(s), sig: s};
				if (init != null) {
					texprStore(s, v.type, init);
					store(local);
				}
				slots.set(v.id, local);
				nameLocal(v, local.index);
				coerce(LVoid, ret);
			case TBlock(el):
				block(ret, el);
			case TReturn(null):
				// A branch out of an expression would leave its operands on the stack.
				if (code.depth != 0) throw new Unsupported("`return` inside expressions", false);
				flow.exitMethod(false);
			case TReturn(e1):
				if (code.depth != 0) throw new Unsupported("`return` inside expressions", false);
				if (this.ret.match(LVoid)) {
					// `return f()` with a Void f.
					texpr(RVoid, e1);
					if (code.reachable()) flow.exitMethod(false);
				} else {
					texprTo(this.ret, retType, e1);
					if (code.reachable()) flow.exitMethod(true);
				}
			case TParenthesis(e1) | TMeta(_, e1):
				texpr(ret, e1);
			case TCast(_, _):
				var c = collapseCast(e);
				var delegateCall = ClosuresToClass.delegateCall(c);
				if (delegateCall != null) {
					calls.delegate(ret, c, delegateCall);
					return;
				}
				switch (c.expr) {
					case TCast(e1, md): castExpr(ret, c, e1, md != null);
					case _: throw "internal error: not a cast";
				}
			case TBinop(OpAssign, lhs, rhs):
				assign(ret, lhs, rhs);
			case TBinop(OpAssignOp(op), lhs, rhs):
				ops.compound(ret, e, op, lhs, rhs);
			case TBinop(op, e1, e2):
				ops.binary(ret, e, op, e1, e2);
			case TUnop(op, flag, e1):
				ops.unary(ret, e, op, flag, e1);
			case TIf(cond, eif, eelse):
				flow.ifExpr(ret, e, cond, eif, eelse);
			case TWhile(cond, body, flag):
				flow.whileLoop(ret, cond, body, flag);
			case TSwitch(subject, cases, def):
				flow.switchExpr(ret, e, subject, cases, def);
			case TBreak:
				if (loops.length == 0) throw new Unsupported("`break` outside a loop", false);
				// The loop's labels are reached with an empty stack.
				if (code.depth != 0) throw new Unsupported("`break` inside expressions", false);
				var loop = loops[loops.length - 1];
				code.branch(tryDepth > loop.tries ? IlOps.LEAVE : IlOps.BR, loop.brk);
			case TContinue:
				if (loops.length == 0) throw new Unsupported("`continue` outside a loop", false);
				if (code.depth != 0) throw new Unsupported("`continue` inside expressions", false);
				var loop = loops[loops.length - 1];
				code.branch(tryDepth > loop.tries ? IlOps.LEAVE : IlOps.BR, loop.cont);
			case TField(obj, fa):
				calls.fieldRead(ret, e, obj, fa);
			case TCall(callee, args):
				calls.call(ret, e, callee, args);
			case TNew(c, params, args):
				calls.construct(ret, c, params, args);
			case TFunction(_):
				throw "internal error: a local function that ClosuresToClass left";
			case TTypeExpr(_):
				// A type as a value is its System.Type, C#'s typeof(T) as gencs writes it.
				var t = calls.typeArg(e);
				if (!needVal(ret)) return;
				calls.pushTypeOf(t);
				coerce(TexprCalls.systemType, ret);
			case TArray(e1, e2):
				calls.arrayRead(ret, e, e1, e2);
			case TObjectDecl(fields):
				dyn.objectDecl(ret, fields);
			case TArrayDecl(el):
				calls.arrayLiteral(ret, e, el);
			case TFor(v, e1, e2):
				// The ForRemap filter removes these first; as in the JVM generator, lowered as it would.
				texpr(ret, hxc.optimization.AnalyzerTexpr.TexprFilter.forRemap(g.ctx.basic, v, e1, e2, e.pos));
			case TTry(body, catches):
				flow.tryExpr(ret, e, body, catches);
			case TThrow(e1):
				flow.throwExpr(e1, e.pos);
			case TEnumIndex(e1) if (clrEnum(e1.type) != null):
				// A CLR enum's value is its index.
				texpr(RValue(sig(e1.type)), e1);
				coerce(LInt32, ret);
			case TEnumIndex(e1) if (EnumToIl.enumOfType(e1.type) != null):
				// An enum class's value is a haxe.lang.Enum, whose _hx_index is its constructor's index.
				texpr(RValue(sig(e1.type)), e1);
				code.opToken(IlOps.LDFLD, g.enumPlans.get(EnumToIl.enumOfType(e1.type)).hxIndex, 1, 1);
				coerce(LInt32, ret);
			case TEnumIndex(e1) if (TexprDynamic.isDynamic(e1.type)):
				// A switch on a Dynamic with enum patterns: gencs's Type.enumIndex(d), which casts it to
				// haxe.lang.Enum (or finds a .NET enum's value among its type's).
				texpr(RValue(LObject), e1);
				var type = g.runtimeClass("Type");
				var cf = type == null ? null : type.statics.get("enumIndex");
				var token = cf == null ? null : g.methodTokens.get(cf);
				if (token == null) throw new Unsupported("enum patterns on a Dynamic without Type.enumIndex", false);
				g.types.checkKept(TClassDecl(type));
				code.opToken(IlOps.CALL, token, 1, 1);
				coerce(LInt32, ret);
			case TEnumParameter(e1, ef, i) if (EnumToIl.isHxGenEnum(EnumToIl.enumOf(ef))):
				// `(e as <Enum>_<Ctor>).<arg>`, converted from the argument's erased type to the expression's,
				// as gencs reads an Opt<Int>'s Some(v) with Runtime.toInt; a Dynamic is first cast to the
				// enum's class, `((<Enum>) d as <Enum>_<Ctor>).<arg>`.
				texpr(RValue(sig(e1.type)), e1);
				var plan = g.enumPlans.get(EnumToIl.enumOf(ef));
				if (EnumToIl.enumOfType(e1.type) == null) code.opToken(IlOps.CASTCLASS, plan.baseToken(), 1, 1);
				code.opToken(IlOps.ISINST, plan.ctorToken(ef), 1, 1);
				code.opToken(IlOps.LDFLD, plan.param(ef, i), 1, 1);
				var t = sig(e.type);
				convert(plan.argSigs[ef.index][i], t);
				coerce(t, ret);
			case TEnumParameter(_, _, _) | TEnumIndex(_):
				throw new Unsupported("enum values", true);
			case TIdent(_):
				throw new Unsupported("untyped code", false);
		}
	}

	// A cast; `checked` for cast(e, T). gencs writes both as C#'s cast to the expression's type, so a cast
	// that changes the type converts or checks through that type even when the value goes on somewhere
	// else, as C#'s `(object)(int)d` does: to a String (Runtime.toString), between value types, from
	// Dynamic to a value type, a type parameter or a class, and every checked cast.
	function castExpr(ret:Ret, e:TExpr, e1:TExpr, checked:Bool):Void {
		var from = null, to = null;
		if (!isNullConst(e1)) {
			from = try sig(e1.type) catch (_:Unsupported) null;
			to = try sig(e.type) catch (_:Unsupported) null;
		}
		// A Map-typed read of an anonymous field or a Dynamic, cast to IMap<K, V> for a Map member: gencs's
		// RealTypeParams does not see through the Map abstract, so this is C#'s cast, not __hx_cast, and a map of
		// another instantiation throws InvalidCastException (casts notes fact 5).
		if (from != null && to != null && from.match(LClass(_, _)) && to.match(LClass(_, _)) && InstantiationCasts.isMultiType(e1.type)
			&& isDynamicRead(e1)) {
			texpr(RValue(LObject), new TExpr(strip(e1).expr, TDynamic(null), e1.pos));
			code.opToken(IlOps.CASTCLASS, g.typeTokenOf(from), 1, 1);
			if (needsInstanceCast(from, to)) instanceCast(from, to);
			coerce(to, ret);
			return;
		}
		// A cast between instantiations of a generic Haxe class (instanceCast), decided by the cast's own type:
		// a value type or a type parameter goes as an object.
		if (from != null && to != null && !g.isUpcast(from, to)) {
			var src = from.match(LObject | LClass(_, _)) ? from : LObject;
			if (needsInstanceCast(src, to)) {
				texpr(RValue(src), e1);
				instanceCast(src, to);
				coerce(to, ret);
				return;
			}
		}
		if (isNullConst(e1) && externEnum(e.type) != null) {
			// cast null to a .NET enum is C#'s default(T), as gencs writes it, boxed where it goes as an object.
			if (!needVal(ret)) return;
			var s = sig(e.type);
			defaultValue(s);
			coerce(s, ret);
			return;
		}
		if (isNullConst(e1) && TexprDynamic.isTDynamic(e.type) && nullDefault(ret, e.type)) return;
		var want = switch (ret) {
			case RValue(w): w;
			case _: null;
		}
		// A cast to haxe.lang.Null<T> that meets a conversion to another type (not String), which
		// HardNullableSynf gives the outer type (nullCastUnwrapped): e1 goes straight to that type.
		if (from != null && to != null && want != null && isHaxeNull(to) && !isHaxeNull(from) && !isHaxeNull(want) && !want.match(LString)
			&& keepNull.indexOf(strip(e)) < 0 && keepNull.indexOf(e) < 0) {
			texpr(RValue(want), e1);
			return;
		}
		// A value type or a String cast to a class or interface, which C# can't write directly: gencs goes
		// through object, `(Base)(object)i`, so the cast still checks wherever the value goes.
		if (from != null && to != null && (DotnetTypes.isValueType(from) || from.match(LString)) && to.match(LClass(_, _))
			&& !g.isGenericHaxeClass(to)) {
			texpr(RValue(LObject), e1);
			castTo(to);
			coerce(to, ret);
			return;
		}
		// A cast between value types of which one is a Nullable<T>, or both .NET structs, which gencs writes as
		// C#'s `(To)(object)e`: boxed, then converted as a Dynamic is.
		if (from != null && to != null && needVal(ret) && boxedCast(from, to)) {
			texpr(RValue(from), e1);
			code.opToken(IlOps.BOX, g.typeTokenOf(from), 1, 1);
			dyn.toSig(to);
			coerce(to, ret);
			return;
		}
		// IntPtr or UIntPtr to or from another value type: gencs casts through object, which always throws. A
		// haxe.lang.Null<T> counts as its T: gencs converts between IntPtr and Null<IntPtr>.
		inline function under(s:IlSigNorm) return nullArg(s) != null ? nullArg(s) : s;
		if (from != null && to != null && !IlPaths.sigEq(under(from), under(to)) && DotnetTypes.isValueType(from) && DotnetTypes.isValueType(to)
			&& (under(from).match(LIntPtr | LUIntPtr) || under(to).match(LIntPtr | LUIntPtr))) {
			function name(s:IlSigNorm, t:T):String return s.match(LIntPtr) ? "System.IntPtr" : s.match(LUIntPtr) ? "System.UIntPtr" : hxc.core.TPrinting.sTypeStr(t);
			var u = Unsupported.error("a cast between " + name(from, e1.type) + " and " + name(to, e.type)
				+ " throws at run time in gencs's C#, which casts through object; use new IntPtr(n), or ToInt32() and ToInt64()");
			u.pos = e1.pos;
			throw u;
		}
		var viaOwn = from != null && to != null && !IlPaths.sigEq(from, to) && !to.match(LObject) && (checked
			|| want != null && !IlPaths.sigEq(want, to) && (to.match(LString) && !inRuntimeClass()
				|| DotnetTypes.isValueType(from) && DotnetTypes.isValueType(to)
				|| from.match(LObject) && (DotnetTypes.isValueType(to) || isTypeParam(to) || isReference(to) && !g.isGenericHaxeClass(to))));
		if (viaOwn) {
			texpr(RValue(to), e1);
			coerce(to, ret);
			return;
		}
		// An unsafe cast to Dynamic of a function value's call boxes its `_f` result as it comes
		// (TexprCalls.invokeFunction).
		if (!checked && to != null && to.match(LObject) && strip(e1).expr.match(TCall(_, _))) calls.rawCall = strip(e1);
		// A value type cast to Dynamic that goes on to another value type: gencs writes no cast into Dynamic, and
		// then converts what is now a Dynamic, `Runtime.toInt((object)x)`. To the same type there is nothing to do.
		if (from != null && to != null && want != null && to.match(LObject) && DotnetTypes.isValueType(from) && DotnetTypes.isValueType(want)
			&& !IlPaths.sigEq(under(from), under(want))) {
			texpr(RValue(LObject), e1);
			calls.rawCall = null;
			coerce(LObject, ret);
			return;
		}
		texpr(switch (ret) {
			case RValue(null): RValue(sig(e.type));
			case r: r;
		}, e1);
		calls.rawCall = null;
	}

	// Whether a cast from the value type `from` to `to` goes through object, as in gencs: between a
	// Nullable<T> and any other value type, or between two .NET structs. Other pairs of value types stay
	// the numeric conversions, or refused.
	function boxedCast(from:IlSigNorm, to:IlSigNorm):Bool {
		if (!DotnetTypes.isValueType(from) || !DotnetTypes.isValueType(to) || IlPaths.sigEq(from, to)) return false;
		if (isHaxeNull(from) || isHaxeNull(to)) return false;
		if (DotnetTypes.isSystemNullable(from) || DotnetTypes.isSystemNullable(to)) return true;
		return isStruct(from) && isStruct(to) && !(g.isGenericHaxeClass(from) && g.isGenericHaxeClass(to));
	}

	// A struct, .NET or Haxe's @:struct class, other than a Nullable<T>, a haxe.lang.Null<T> and any enum (a
	// .NET enum, whose class the assemblies define, or a CLR enum, which is no class): a type whose values
	// `x == null` and an unsafe cast treat as structs.
	function isStruct(s:IlSigNorm):Bool {
		return switch (s) {
			case LValueType(p, _): !isHaxeNull(s) && !DotnetTypes.isSystemNullable(s) && g.externs.enumUnderlying(p) == null && g.classAt(p) != null;
			case _: false;
		}
	}

	// Statements, then the last expression where `ret` wants it. In user code a failing statement is
	// reported and the next one lowered.
	function block(ret:Ret, el:Array<TExpr>):Void {
		if (el.length == 0) {
			coerce(LVoid, ret);
			return;
		}
		// A value block's statements have points of their own, inside the statement around the block, which
		// takes its value's.
		var outer = statementPos, mark = needVal(ret) ? pointMark() : -1;
		// A block's own scope, unless its one statement is a block (TclassToIl.statement's wrapper around a
		// body), which declares nothing in it.
		var scoped = el.length > 1 || !el[0].expr.match(TBlock(_));
		if (scoped) code.openScope();
		for (i in 0...el.length) {
			var s = el[i];
			var r = i == el.length - 1 ? ret : RVoid;
			if (!needVal(r)) statementPoint(s) else resumePoint(mark, outer);
			// The statement giving the block's value fails with the statement around the block: the code
			// after it expects the value on the stack.
			if (onError == null || needVal(r)) {
				texpr(r, s);
				continue;
			}
			var depth = code.depth;
			try {
				texpr(r, s);
			} catch (u:Unsupported) {
				code.resetDepth(depth);
				var usesPoisoned = usesPoisonedVar(s);
				switch (s.expr) {
					case TVarExpr(v, _): poisoned.set(v.id, true);
					case _:
				}
				if (!usesPoisoned) onError(u);
			}
		}
		if (scoped) code.closeScope();
	}

	function usesPoisonedVar(e:TExpr):Bool {
		return switch (e.expr) {
			case TLocal(v): poisoned.exists(v.id);
			case _: TexprTools.checkExpr(usesPoisonedVar, e);
		}
	}

	function staticField(c:TClass, cf:TClassField):{token:Int, sig:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		// An event's var is its field-like backing field in its own class and has no value elsewhere.
		if (EventToIl.isEventVar(cf)) EventToIl.checkValue(g, cls, c, cf);
		var plan = g.ownerOf.get(cf);
		if (plan == null || !g.fieldTokens.exists(cf)) throw "internal error: no field " + Globals.sTypePath(c.path) + "." + cf.name;
		return {token: g.memberOf(plan, staticOwner(plan), cf), sig: g.fieldSigs.get(cf)};
	}

	// The type arguments of a static or instance field access's class (none for a static).
	static function paramsOf(fa:TFieldAccess):TParams {
		return switch (fa) {
			case FInstance(_, params, _): params;
			case _: [];
		}
	}

	// As gencs writes it, a static member of a generic class is reached through the instantiation
	// with object for each type parameter.
	static function staticOwner(plan:ClassPlan):IlSigNorm {
		return DotnetCtx.instanceOf(plan, [for (_ in plan.classParams) LObject]);
	}

	// The type arguments of `target`, a superclass or interface of `c` or `c` itself, when `c` has
	// `params`.
	static function argsAt(c:TClass, params:TParams, target:TClass):Null<TParams> {
		if (c == target) return params;
		var supers = c.interfaces.copy();
		if (c.superClass != null) supers.push(c.superClass);
		for (s in supers) {
			var r = argsAt(s.c, [for (t in s.params) TypeFunctions.applyParams(c.params, params, t)], target);
			if (r != null) return r;
		}
		return null;
	}

	// The type arguments of the class `plan` declares, as an access through `c` with `params` sees them.
	function ownerArgs(c:TClass, params:TParams, plan:ClassPlan):TParams {
		if (plan.classParams.length == 0) return [];
		var r = argsAt(c, params, plan.c);
		if (r == null) throw "internal error: " + plan.hxPath + " is not a supertype of " + Globals.sTypePath(c.path);
		return r;
	}

	static function isExtern(c:TClass):Bool return TypeFunctions.hasClassFlag(c, CExtern);

	// The @:nativeGen flat enum, a CLR enum, that values of type `t` belong to, or null.
	static function clrEnum(t:T):Null<TEnum> {
		return switch (TypeFunctions.follow(t)) {
			case TEnum(e, _) if (HxGen.isClrEnum(e)): e;
			case _: null;
		}
	}

	// The cast `e` as gencs's CastDetect leaves it. When its operand is itself a cast and no cast is
	// needed from the operand's type to `e`'s (see noCastNeeded), CastDetect gives the inner cast
	// `e`'s type, so the inner conversion is lost: `Sys.println((cast f : Int))` passes f itself, and
	// `(cast (cast b : Sub) : Base)` casts b to Base only. Inner casts are collapsed first, as
	// CastDetect visits them first.
	function collapseCast(e:TExpr):TExpr {
		return switch (e.expr) {
			case TCast(e1, md):
				var inner = collapseCast(e1);
				switch (inner.expr) {
					case TCast(z, md2) if (noCastNeeded(inner.type, e.type) || nullCastUnwrapped(inner.type, e.type)):
						new TExpr(TCast(z, md2), e.type, e.pos);
					case _: inner == e1 ? e : new TExpr(TCast(inner, md), e.type, e.pos);
				}
			case _: e;
		}
	}

	// Whether gencs's handle_cast adds no cast from `from` to `to`, judged on gencs's real types
	// (castReal): the same type; into Dynamic from anything but a haxe.lang.Null<T> or a pointer; a
	// class to one of its superclasses or interfaces with the same type arguments; native arrays;
	// the same core abstract. A cast to cs.system.Object or between different basic types is needed.
	function noCastNeeded(from:T, to:T):Bool {
		var f = castReal(from), t = castReal(to);
		if (realEq(f, t)) return true;
		return switch (t) {
			case TDynamic(_) | TMono(_):
				// gencs's gneeds_box.
				!switch (f) {
					case TAbstract(a, _): isNullAbstract(f) || TexprDynamic.isPath(a.path, ["cs"], "Pointer");
					case _: false;
				}
			case TInst(ct, _) if (TexprDynamic.isPath(ct.path, [], "String") || ct.kind.match(KTypeParameter(_))): false;
			case TInst(ct, tp):
				switch (f) {
					case TInst(cf, _) if (cf == ct && isNativeArray(t)): true;
					case TInst(cf, fp) if (!cf.kind.match(KTypeParameter(_))):
						var at = argsAt(cf, fp, ct);
						var a = at == null ? null : try sig(TInst(ct, at)) catch (_:Unsupported) null;
						var b = try sig(TInst(ct, tp)) catch (_:Unsupported) null;
						a != null && b != null && IlPaths.sigEq(a, b);
					case _: false;
				}
			case TAbstract(at, _) if (!isNullAbstract(t)):
				switch (f) {
					case TAbstract(af, _): af == at;
					case _: false;
				}
			case _: false;
		}
	}

	// Whether gencs's HardNullableSynf, which runs after CastDetect, gives a cast to haxe.lang.Null<T>
	// under a cast to `to` the outer type (its "unnecessary cast to Nullable"): `to` is neither a
	// haxe.lang.Null<T> nor String. `(cast (cast f : Null<Int>) : Float)` is f as a Float.
	static function nullCastUnwrapped(from:T, to:T):Bool {
		var t = castReal(to);
		var toString = switch (t) {
			case TInst(c, _): TexprDynamic.isPath(c.path, [], "String");
			case _: false;
		}
		return isNullAbstract(castReal(from)) && !isNullAbstract(t) && !toString;
	}

	static function isNullAbstract(t:T):Bool {
		return switch (t) {
			case TAbstract(a, [_]): TexprDynamic.isPath(a.path, [], "Null");
			case _: false;
		}
	}

	// gencs's real type as handle_cast tells types apart: Dynamic for Dynamic, EnumValue and
	// anonymous structures; Null<T> only of a basic type or type parameter (haxe.lang.Null<T>);
	// other abstracts unwrapped down to core types; monomorphs left as they are.
	static function castReal(t:T, depth = 0):T {
		if (depth > 20) return TypeFunctions.tDynamic;
		var f = TypeFunctions.followWithoutNull(t);
		return switch (f) {
			case TAnon(a) if (!a.status.get().match(Statics(_) | EnumStatics(_) | AbstractStatics(_))): TypeFunctions.tDynamic;
			case TAbstract(a, [p]) if (TexprDynamic.isPath(a.path, [], "Null")):
				var r = castReal(p, depth + 1);
				TexprDynamic.isBasic(r) || TexprDynamic.isTypeParamType(r) ? TAbstract(a, [r]) : r;
			case TAbstract(a, _) if (TexprDynamic.isPath(a.path, [], "EnumValue") || TexprDynamic.isPath(a.path, [], "Dynamic")):
				TypeFunctions.tDynamic;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)): castReal(TypeFunctions.getUnderlyingType(a, tl), depth + 1);
			case _: f;
		}
	}

	// gencommon's fast_eq on real types.
	static function realEq(a:T, b:T, depth = 0):Bool {
		if (depth > 20) return false;
		function params(p1:TParams, p2:TParams):Bool {
			if (p1.length != p2.length) return false;
			for (i in 0...p1.length) if (!realEq(castReal(p1[i]), castReal(p2[i]), depth + 1)) return false;
			return true;
		}
		return switch [a, b] {
			case [TDynamic(_), TDynamic(_)]: true;
			case [TMono(m1), TMono(m2)]: m1 == m2;
			case [TInst(c1, p1), TInst(c2, p2)]: c1 == c2 && params(p1, p2);
			case [TEnum(e1, p1), TEnum(e2, p2)]: e1 == e2 && params(p1, p2);
			case [TAbstract(a1, p1), TAbstract(a2, p2)]: a1 == a2 && params(p1, p2);
			case [TAnon(a1), TAnon(a2)]: a1 == a2;
			case _: false;
		}
	}

	// The extern .NET enum that values of type `t` belong to, or null.
	static function externEnum(t:T):Null<TEnum> {
		return switch (TypeFunctions.follow(t)) {
			case TEnum(e, _) if (e.isExtern): e;
			case _: null;
		}
	}

	// `e` as enumIndex(x) of a value x of an extern .NET enum, or null. An index is not the value .NET
	// stores, so a switch or comparison on it compares x with the constructors' values instead, as
	// gencs's SwitchToIf turns `switch enumIndex(x)` back into a switch on x.
	static function externEnumIndex(e:TExpr):Null<{value:TExpr, en:TEnum}> {
		return switch (strip(e).expr) {
			case TEnumIndex(x) if (externEnum(x.type) != null): {value: x, en: externEnum(x.type)};
			case _: null;
		}
	}

	// The constructor of `en` with index `i`.
	static function enumFieldAt(en:TEnum, i:Int):TEnumField {
		for (ef in en.constrs) if (ef.index == i) return ef;
		throw "internal error: " + Globals.sTypePath(en.path) + " has no constructor " + i;
	}

	// The end of an assignment whose value `s` is on the stack above what `store` consumes: C#'s value of an
	// assignment is the value stored, not what a setter returns, so it is kept across `store` when `ret`
	// needs it, as gencs's temporary does.
	function storeKeeping(ret:Ret, s:IlSigNorm, store:Void->Void):Void {
		var tmp = needVal(ret) ? ops.keepTop(s) : -1;
		store();
		if (tmp >= 0) {
			code.ldloc(tmp);
			coerce(s, ret);
		}
	}

	function assign(ret:Ret, lhs:TExpr, rhs:TExpr):Void {
		switch (lhs.expr) {
			case TLocal(v) if (refTarget(anySlot(v)) != null):
				var s = anySlot(v);
				var target = refTarget(s);
				load(s);
				texpr(RValue(target), rhs);
				storeKeeping(ret, target, () -> storeIndirect(target));
			case TLocal(v):
				var s = slot(v);
				texprStore(s.sig, lhs.type, rhs);
				if (needVal(ret)) code.op(IlOps.DUP, 1, 2);
				store(s);
				if (needVal(ret)) coerce(s.sig, ret);
			case TArray(e1, e2) if (calls.isDynamicVector(e1)):
				// System.Array's SetValue(value, index), the index kept while the value is computed.
				calls.pushDynamicVector(e1, e2);
				var idx = code.addLocal(LInt32);
				code.stloc(idx);
				texpr(RValue(LObject), rhs);
				storeKeeping(ret, LObject, () -> {
					code.ldloc(idx);
					calls.callArrayValue(true);
				});
			case TArray(e1, e2) if (calls.isDynamicArrayAccess(e1)):
				// Runtime.callField(a, "__set", hash, new object[]{i, v}).
				dyn.fieldCall(ret, lhs, e1, "__set", [e2, rhs]);
			case TArray(e1, e2) if (calls.haxeIndexer(e1, false, true) != null):
				// set_Item(index, value) of a Haxe class's indexer or of a companion interface's (an
				// Array<Dynamic>'s, whose setter casts the value to the element type), the value the stored one.
				var ix = calls.haxeIndexer(e1, false, true);
				var set = ix.setToken();
				calls.receiver(e1, ix.parent, true);
				nullOperand(RValue(ix.index), e2, false);
				texprStore(ix.value, lhs.type, rhs);
				storeKeeping(ret, ix.value, () -> code.opToken(ix.isStruct ? IlOps.CALL : IlOps.CALLVIRT, set, 3, 0));
			case TArray(e1, e2) if (isNativeArray(e1.type)):
				var elem = calls.pushArrayAndIndex(e1, e2);
				texpr(RValue(elem), rhs);
				storeKeeping(ret, elem, () -> code.stelem(elem, () -> g.typeTokenOf(elem)));
			case TArray(e1, e2) if (calls.isNetIndexer(e1, e2)):
				// set_Item(index, value), the value converted to the setter's parameter type.
				var ix = calls.netIndexer(e1, e2, lhs.type, false, true);
				var set = ix.setToken();
				calls.receiver(e1, ix.parent, true);
				nullOperand(RValue(ix.index), e2, false);
				texpr(RValue(ix.value), rhs);
				storeKeeping(ret, ix.value, () -> code.opToken(ix.isStruct ? IlOps.CALL : IlOps.CALLVIRT, set, 3, 0));
			case TArray(e1, e2) if (arrayOf(e1.type) != null):
				var m = calls.arrayAccessor(e1.type, "__set");
				calls.receiver(e1, m.owner);
				texpr(RValue(m.args[0]), e2);
				texprStore(m.args[1], lhs.type, rhs);
				code.opToken(IlOps.CALLVIRT, m.token, 3, 1);
				// __set returns the value it stored.
				coerce(m.ret, ret);
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (g.varProperties.exists(cf) && !dyn.isDynamicReceiver(fa, obj)):
				// A @:property var: its setter, as gencs's C# stores into the auto-property, the value the stored one.
				var a = calls.varAccessor(c, paramsOf(fa), cf, true);
				if (!a.isStatic) calls.receiver(obj, a.owner, true);
				texprStore(a.sig, lhs.type, rhs);
				storeKeeping(ret, a.sig, () -> code.opToken(a.op, a.token, a.isStatic ? 1 : 2, 0));
			case TField(_, FStatic(c, cf)) if (!isExtern(c)):
				var f = staticField(c, cf);
				texprStore(f.sig, lhs.type, rhs);
				if (needVal(ret)) code.op(IlOps.DUP, 1, 2);
				volatilePrefix(cf);
				code.opToken(IlOps.STSFLD, f.token, 1, 0);
				if (needVal(ret)) coerce(f.sig, ret);
			case TField(obj, fa) if (dyn.isDynamicReceiver(fa, obj)):
				// Runtime.setField, as gencs assigns a field of a Dynamic, a variable of a Haxe interface, or a
				// variable of a value typed as a companion interface.
				dyn.fieldSet(ret, lhs, obj, TexprDynamic.fieldName(fa), rhs, lhs.type);
			case TField(obj, FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c)):
				var f = calls.instanceField(c, cparams, cf);
				calls.receiver(obj, f.owner, true);
				texprStore(f.sig, lhs.type, rhs);
				storeKeeping(ret, f.sig, () -> {
					volatilePrefix(cf);
					code.opToken(IlOps.STFLD, f.token, 2, 0);
				});
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				var isStatic = fa.match(FStatic(_, _));
				var x = calls.externField(obj, fa, c, cf, false, true);
				var parent = x.parent, inst = x.args;
				switch (x.member) {
					case XField(open, initOnly):
						var s = ExternMembers.subst(open, inst);
						if (initOnly) throw new Unsupported("assignments to read-only .NET fields", true);
						if (!isStatic) calls.receiver(obj, parent, true);
						texpr(RValue(s), rhs);
						var token = g.mb.memberRef(g.typeTokenOf(parent), ExternMembers.memberName(cf), g.sigs.field(open));
						// The value of the assignment is the value stored, as for a property.
						storeKeeping(ret, s, () -> code.opToken(isStatic ? IlOps.STSFLD : IlOps.STFLD, token, isStatic ? 1 : 2, 0));
					case XProperty(open, _, setter) if (setter != null):
						var s = ExternMembers.subst(open, inst);
						if (!isStatic) calls.receiver(obj, parent);
						texpr(RValue(s), rhs);
						var token = g.mb.memberRef(g.typeTokenOf(parent), setter, g.sigs.method(!isStatic, LVoid, [open], 0));
						var op = isStatic || DotnetTypes.isValueType(parent) ? IlOps.CALL : IlOps.CALLVIRT;
						storeKeeping(ret, s, () -> code.opToken(op, token, isStatic ? 1 : 2, 0));
					case _:
						throw new Unsupported("assignments to a read-only .NET member", true);
				}
			case _:
				throw new Unsupported("this kind of assignment", false);
		}
	}

	static function strip(e:TExpr):TExpr {
		return switch (e.expr) {
			case TParenthesis(e1) | TMeta(_, e1): strip(e1);
			case _: e;
		}
	}

	static function isNullConst(e:TExpr):Bool return strip(e).expr.match(TConst(TNull));

	static function isBoolConst(e:TExpr):Bool return strip(e).expr.match(TConst(TBool(_)));

	// A read of a field of an anonymous structure or a Dynamic, which gencs makes with Runtime.getField.
	static function isDynamicRead(e:TExpr):Bool return strip(e).expr.match(TField(_, FAnon(_) | FDynamic(_)));

	static function constInt(e:TExpr):Null<Int> {
		return switch (strip(e).expr) {
			case TConst(TInt(v)): v;
			case _: null;
		}
	}

	static function isStringClass(c:TClass):Bool return c.path.pack.length == 0 && c.path.name == "String";

	static function isNumeric(s:IlSigNorm):Bool return s.match(LInt32 | LUInt32 | LFloat64 | LInt64 | LUInt64);

	// The type an operand is computed in: a Null<T> operand's T, read from its value. Char and the
	// small integers, which untyped code leaves as they are (hxcs's Bytes.compare subtracts two UInt8s),
	// are computed as Ints, as C# promotes them.
	function operandSig(op:Binop, e:TExpr):IlSigNorm {
		var s = switch (unNull(sig(e.type))) {
			case LChar | LInt8 | LUInt8 | LInt16 | LUInt16: LInt32;
			case s: s;
		}
		if (!isNumeric(s)) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		return s;
	}

	// A local or a Haxe class's static variable, which can be loaded and stored without a receiver; an
	// instance variable; an array element, whose array and index are kept in temporaries.
	function place(e:TExpr):Null<Place> {
		switch (e.expr) {
			case TParenthesis(e1) | TMeta(_, e1):
				return place(e1);
			case TArray(e1, e2) if (calls.isDynamicArrayAccess(e1)):
				// Through Runtime.callField's "__get" and "__set", on the array and index stored once.
				var arr = -1, idx = -1;
				return {
					sig: LObject,
					receiver: false,
					prepare: () -> {
						texpr(RValue(LObject), e1);
						arr = code.addLocal(LObject);
						code.stloc(arr);
						texpr(RValue(LObject), e2);
						idx = code.addLocal(LObject);
						code.stloc(idx);
					},
					load: () -> dyn.localFieldCall(arr, "__get", e1.pos, [idx]),
					store: () -> {
						var v = code.addLocal(LObject);
						code.stloc(v);
						dyn.localFieldCall(arr, "__set", e1.pos, [idx, v]);
						code.op(IlOps.POP, 1, 0);
					}
				};
			case TArray(e1, e2) if (!isNativeArray(e1.type) && (calls.haxeIndexer(e1, true, true) != null || calls.isNetIndexer(e1, e2))):
				// get_Item and set_Item on the receiver and index stored once: a Haxe class's indexer, a companion
				// interface's (`++` on an Array<Dynamic>'s element stores the double TexprDynamic.incDec computes,
				// as gencs's does), or a .NET class's. `op=` on an Array<Dynamic>'s element goes through
				// Runtime.callField instead (TexprDynamic.compound).
				var ix = calls.haxeIndexer(e1, true, true);
				if (ix == null) ix = calls.netIndexer(e1, e2, e.type, true, true);
				if (ix.isStruct) throw new Unsupported("read-modify-write through an indexer of a .NET struct", false);
				var get = ix.getToken(), set = ix.setToken();
				var recv = -1, idx = -1;
				function reload() {
					code.ldloc(recv);
					code.ldloc(idx);
				}
				// A Dynamic element that is a struct or Nullable is read and stored as an object, as gencs's
				// Runtime does, which converts it to the type of the operation.
				var boxed = TexprDynamic.isDynamic(e.type) && ix.value.match(LValueType(_, _));
				return {
					sig: boxed ? LObject : ix.value,
					receiver: true,
					prepare: () -> {
						texpr(RValue(ix.parent), e1);
						recv = code.addLocal(ix.parent);
						code.stloc(recv);
						nullOperand(RValue(ix.index), e2, false);
						idx = code.addLocal(ix.index);
						code.stloc(idx);
						reload();
					},
					load: () -> {
						reload();
						code.opToken(IlOps.CALLVIRT, get, 2, 1);
						if (boxed) convert(ix.value, LObject);
					},
					store: () -> {
						if (boxed) convert(LObject, ix.value);
						code.opToken(IlOps.CALLVIRT, set, 3, 0);
					}
				};
			case TArray(e1, e2) if (isNativeArray(e1.type) || arrayOf(e1.type) != null):
				var native = isNativeArray(e1.type);
				var get = native ? null : calls.arrayAccessor(e1.type, "__get");
				var set = native ? null : calls.arrayAccessor(e1.type, "__set");
				var elem = native ? vectorElement(calls.vectorSig(e1)) : get.ret;
				// As C#: the address of a value type's element, taken once. An operand that starts on an empty stack
				// can't have the array under it.
				if (native && DotnetTypes.isValueType(elem) && !TexprCalls.needsEmptyStack(e2)) {
					return {
						sig: elem,
						receiver: true,
						prepare: () -> {
							texpr(RValue(calls.vectorSig(e1)), e1);
							texpr(RValue(calls.indexSig(e2)), e2);
							code.opToken(IlOps.LDELEMA, g.typeTokenOf(elem), 2, 1);
						},
						load: () -> {
							code.op(IlOps.DUP, 1, 2);
							loadIndirect(elem);
						},
						store: () -> storeIndirect(elem)
					};
				}
				var arr = -1, idx = -1;
				function reload() {
					code.ldloc(arr);
					code.ldloc(idx);
				}
				return {
					sig: elem,
					receiver: true,
					prepare: () -> {
						var arrSig = native ? calls.vectorSig(e1) : get.owner;
						texpr(RValue(arrSig), e1);
						arr = code.addLocal(arrSig);
						code.stloc(arr);
						var idxSig = native ? calls.indexSig(e2) : get.args[0];
						texpr(RValue(idxSig), e2);
						idx = code.addLocal(idxSig);
						code.stloc(idx);
						reload();
					},
					load: () -> {
						reload();
						if (native) code.ldelem(elem, () -> g.typeTokenOf(elem)) else code.opToken(IlOps.CALLVIRT, get.token, 2, 1);
					},
					store: () -> {
						if (native) {
							code.stelem(elem, () -> g.typeTokenOf(elem));
						} else {
							code.opToken(IlOps.CALLVIRT, set.token, 3, 1);
							code.op(IlOps.POP, 1, 0);
						}
					}
				};
			case TLocal(v) if (refTarget(anySlot(v)) != null):
				var s = anySlot(v);
				var target = refTarget(s);
				return {
					sig: target,
					receiver: true,
					prepare: () -> load(s),
					load: () -> {
						code.op(IlOps.DUP, 1, 2);
						loadIndirect(target);
					},
					store: () -> storeIndirect(target)
				};
			case TLocal(v):
				var s = slot(v);
				return {sig: s.sig, receiver: false, prepare: () -> {}, load: () -> load(s), store: () -> store(s)};
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (g.varProperties.exists(cf) && !dyn.isDynamicReceiver(fa, obj)):
				// A @:property var: its getter and setter on the receiver evaluated once.
				var get = calls.varAccessor(c, paramsOf(fa), cf, false), set = calls.varAccessor(c, paramsOf(fa), cf, true);
				var isStatic = get.isStatic;
				return {
					sig: get.sig,
					receiver: !isStatic,
					prepare: () -> if (!isStatic) calls.receiver(obj, get.owner, true),
					load: () -> {
						if (!isStatic) code.op(IlOps.DUP, 1, 2);
						code.opToken(get.op, get.token, isStatic ? 0 : 1, 1);
					},
					store: () -> code.opToken(set.op, set.token, isStatic ? 1 : 2, 0)
				};
			case TField(_, FStatic(c, cf)) if (!isExtern(c) && cf.kind.match(Var(_))):
				var f = staticField(c, cf);
				return {
					sig: f.sig,
					receiver: false,
					prepare: () -> {},
					load: () -> {
						volatilePrefix(cf);
						code.opToken(IlOps.LDSFLD, f.token, 0, 1);
					},
					store: () -> {
						volatilePrefix(cf);
						code.opToken(IlOps.STSFLD, f.token, 1, 0);
					}
				};
			case TField(obj, fa = FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c) && cf.kind.match(Var(_))
				&& !dyn.isDynamicReceiver(fa, obj)):
				var f = calls.instanceField(c, cparams, cf);
				return {
					sig: f.sig,
					receiver: true,
					prepare: () -> calls.receiver(obj, f.owner, true),
					load: () -> {
						code.op(IlOps.DUP, 1, 2);
						volatilePrefix(cf);
						code.opToken(IlOps.LDFLD, f.token, 1, 1);
					},
					store: () -> {
						volatilePrefix(cf);
						code.opToken(IlOps.STFLD, f.token, 2, 0);
					}
				};
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c) && !isStringClass(c) && cf.kind.match(Var(_))
				&& !dyn.isDynamicReceiver(fa, obj)):
				// A .NET field, read and stored on the receiver evaluated once (a value type's address, as C# takes it).
				var isStatic = fa.match(FStatic(_, _));
				var x = calls.externField(obj, fa, c, cf, true, true);
				switch (x.member) {
					case XField(open, initOnly):
						if (initOnly) throw new Unsupported("assignments to read-only .NET fields", true);
						var token = g.mb.memberRef(g.typeTokenOf(x.parent), ExternMembers.memberName(cf), g.sigs.field(open));
						return {
							sig: ExternMembers.subst(open, x.args),
							receiver: !isStatic,
							prepare: () -> if (!isStatic) calls.receiver(obj, x.parent, true),
							load: () -> {
								if (!isStatic) code.op(IlOps.DUP, 1, 2);
								code.opToken(isStatic ? IlOps.LDSFLD : IlOps.LDFLD, token, isStatic ? 0 : 1, 1);
							},
							store: () -> code.opToken(isStatic ? IlOps.STSFLD : IlOps.STFLD, token, isStatic ? 1 : 2, 0)
						};
					case XProperty(open, getter, setter) if (getter != null && setter != null):
						// A hand-written extern variable bound to a .NET property: get once, set once.
						var get = g.mb.memberRef(g.typeTokenOf(x.parent), getter, g.sigs.method(!isStatic, open, [], 0));
						var set = g.mb.memberRef(g.typeTokenOf(x.parent), setter, g.sigs.method(!isStatic, LVoid, [open], 0));
						var op = isStatic || DotnetTypes.isValueType(x.parent) ? IlOps.CALL : IlOps.CALLVIRT;
						return {
							sig: ExternMembers.subst(open, x.args),
							receiver: !isStatic,
							prepare: () -> if (!isStatic) calls.receiver(obj, x.parent, true),
							load: () -> {
								if (!isStatic) code.op(IlOps.DUP, 1, 2);
								code.opToken(op, get, isStatic ? 0 : 1, 1);
							},
							store: () -> code.opToken(op, set, isStatic ? 1 : 2, 0)
						};
					case _:
						return null;
				}
			case _:
				return null;
		}
	}
}
