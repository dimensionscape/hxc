package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;

// The typed invokers of methods used as values, which hxc adds to hxcs's by-name haxe.lang.Closure. Each
// such method that `gets` lets through gets one class extending haxe.lang.ClosureInvoker, named
// `<Class>_<method>__Invoke` in its class's package and module, with one shared instance in its
// `__hx_current`. Its `__hx_accepts<N>` holds only for a receiver of the class and arguments that already have
// the parameters' types, which the by-name path passes on as they are, so that its `__hx_call<N>_o`/`_f` behaves
// as that path does; every other call goes by name. That path is one of two. A static goes through reflection
// (Runtime.callMethodCasting), which unboxes the result and throws what the method throws again. An instance
// method goes through the `__hx_invokeField` of the receiver's class, whose case calls it and does neither, unless
// that class overrides it: then the case is Runtime.slowCallField, reflection again (`slowCallers`). No Haxe line
// wrote this code: under -debug its statements are hidden points.

@:access(hxc.codegen.dotnet.ClosuresToClass)
@:access(hxc.codegen.dotnet.ReflectionMembers)
class MethodInvokers {
	// ClosureInvoker's entry points: from six arguments on a call goes to __hx_invokeDynamic, by name.
	static inline final maxArgs = 5;

	final g:DotnetCtx;
	final pass:ClosuresToClass;
	final base:TClass;
	// The classes that send a method to Runtime.slowCallField, and those with a member that by name may be found
	// instead of a method, by its name; made when first needed.
	var slowCallersByName:Null<Map<String, Array<TClass>>> = null;
	var rivalsByName:Null<Map<String, Array<TClass>>> = null;

	public function new(g:DotnetCtx, pass:ClosuresToClass, base:TClass) {
		this.g = g;
		this.pass = pass;
		this.base = base;
	}

	// Whether a value of the method `cf` of `c` takes the direct path when its arguments allow it.
	public function gets(c:TClass, cf:TClassField, isStatic:Bool):Bool {
		if (!eligible(c, cf, isStatic)) return false;
		// By name, it may not be this method that is found: Runtime.slowCallField goes through the class's methods
		// with the name, as declared, and takes the first that fits best.
		if (isStatic) return !Lambda.exists(c.orderedStatics, f -> f != cf && f.name == cf.name);
		// `__hx_invokeField` has no case for it, so by name it is not found.
		if (TypeFunctions.hasMeta(":compilerGenerated", cf.meta)) return false;
		// By name, it may not be this method that is found.
		if (rivals(c, cf).length > 0) return false;
		var slow = slowCallers(c, cf);
		// Runtime.slowCallField answers a `toString` with the receiver's ToString.
		if (slow.length > 0 && cf.name == "toString") return false;
		// `__is__` tests one instantiation of a generic class, and a class of the standard library may be left out,
		// and then cannot be tested.
		return !Lambda.exists(slow, k -> k.params.length > 0 || g.isStd(k.pos));
	}

	// A shape that the by-name path treats in a way of its own stays by name.
	public static function eligible(c:TClass, cf:TClassField, isStatic:Bool):Bool {
		if (!cf.kind.match(Method(MethNormal | MethInline)) || cf.expr == null || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) return false;
		if (TypeFunctions.hasClassFlag(c, CExtern) || !HxGen.derivesFromHxObject(c) || c.params.length > 0) return false;
		if (cf.params.length > 0 || cf.overloads.length > 0 || TypeFunctions.hasClassFieldFlag(cf, CfOverload)) return false;
		if (TypeFunctions.hasMeta(":skipReflection", cf.meta) || TypeFunctions.hasMeta(":native", cf.meta)) return false;
		// The by-name path looks for the Haxe name, and a member named like its class has another one.
		if (DotnetNames.fieldName(c, cf.name) != cf.name) return false;
		// Runtime.slowCallField answers a static `toString` with the ToString of the System.Type.
		if (isStatic && cf.name == "toString") return false;
		var s = c.superClass;
		while (s != null) {
			if (s.c.params.length > 0) return false;
			// A static that hides a superclass's: which one by name finds is not for this class to say.
			if (isStatic && s.c.statics.exists(cf.name)) return false;
			s = s.c.superClass;
		}
		return switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig):
				sig.args.length <= maxArgs && !Lambda.exists(sig.args, a -> a.opt || !isDirect(a.t)) && (ClosuresToClass.isVoid(sig.ret) || isDirect(sig.ret));
			case _: false;
		}
	}

	// A parameter or result type of the direct path: Int, Float, Bool, String, Dynamic, or a class or enum
	// without type arguments. A Null<T> is haxe.lang.Null<T> or converts through it, so it is no T here; a
	// haxe.Rest is an abstract with a type argument. A .NET class stays out: `is object` holds for
	// Runtime.undefined itself, and a parameter that is IConvertible gets ToType by name.
	static function isDirect(t:T):Bool {
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, []): a.path.pack.length == 0 && ["Int", "Float", "Bool"].indexOf(a.path.name) >= 0;
			case TDynamic(_) | TEnum(_, []): true;
			case TInst(c, []) if (c.path.pack.length == 0 && c.path.name == "String"): true;
			case TInst(c, []): !c.kind.match(KTypeParameter(_)) && !TypeFunctions.hasClassFlag(c, CExtern) && !isConvertible(c);
			case _: false;
		}
	}

	static function isConvertible(c:TClass):Bool {
		var path = DotnetNames.typePath(TClassDecl(c));
		if (path.name == "IConvertible" && path.ns.join(".") == "System") return true;
		if (c.superClass != null && isConvertible(c.superClass.c)) return true;
		return Lambda.exists(c.interfaces, i -> isConvertible(i.c));
	}

	// The classes in `c`'s line that send the instance method `cf` to Runtime.slowCallField: those that override it
	// and have a method of their own. One without has no `__hx_invokeField`, so a superclass's case calls the method.
	function slowCallers(c:TClass, cf:TClassField):Array<TClass> {
		index();
		return inLine(slowCallersByName, c, cf);
	}

	// The classes in `c`'s line with a member that by name may be found instead of the method `cf`, whose case or
	// Runtime.slowCallField's search of the members goes by the name alone.
	function rivals(c:TClass, cf:TClassField):Array<TClass> {
		index();
		return inLine(rivalsByName, c, cf);
	}

	function index():Void {
		if (slowCallersByName != null) return;
		slowCallersByName = new Map();
		rivalsByName = new Map();
		function add(to:Map<String, Array<TClass>>, name:String, k:TClass) {
			var l = to.get(name);
			if (l == null) to.set(name, l = []);
			l.push(k);
		}
		for (mt in g.ctx.types) switch (mt) {
			case TClassDecl(k) if (HxGen.derivesFromHxObject(k)):
				// A class that cannot be planned is left out, and then is no receiver.
				var cases = try ReflectionMembers.invokeCases(g, k) catch (_:Unsupported) null;
				if (cases != null && cases.own.length > 0) for (e in cases.old) if (e.owner == k) add(slowCallersByName, e.cf.name, k);
				for (f in k.orderedFields) if (isRival(k, f)) add(rivalsByName, f.name, k);
			case _:
		}
	}

	// A member named as another of its class, or as one of a superclass and not its plain override: the typer lets only
	// an @:overload or a @:native name do that. One that `__hx_invokeField` has no case for counts too, as
	// Runtime.slowCallField searches the members.
	static function isRival(k:TClass, f:TClassField):Bool {
		if (k.fields.get(f.name) != f) return true;
		if (TypeFunctions.hasClassFieldFlag(f, CfOverride) && !TypeFunctions.hasClassFieldFlag(f, CfOverload)) return false;
		var s = k.superClass;
		while (s != null) {
			if (s.c.fields.exists(f.name)) return true;
			s = s.c.superClass;
		}
		return false;
	}

	static function inLine(byName:Map<String, Array<TClass>>, c:TClass, cf:TClassField):Array<TClass> {
		var l = byName.get(cf.name);
		return l == null ? [] : l.filter(k -> isSameOrBelow(k, c) || isSameOrBelow(c, k));
	}

	static function isSameOrBelow(c:TClass, parent:TClass):Bool {
		var s = c;
		while (s != null) {
			if (s == parent) return true;
			s = s.superClass == null ? null : s.superClass.c;
		}
		return false;
	}

	// Makes the invoker class of the method `cf` of `c`, unless it has one.
	public function note(c:TClass, cf:TClassField, isStatic:Bool):Void {
		if (g.methodInvokers.exists(cf)) return;
		var sig = switch (TypeFunctions.follow(cf.type)) {
			case TFun(s): s;
			case _: throw "internal error: the method " + cf.name + " has no function type";
		}
		var basic = g.ctx.basic;
		var at = g.pdb != null ? Position.nullPos : cf.pos;
		var stem = c.path.name + "_" + cf.name + "__Invoke", name = stem, n = 0;
		while (pass.taken.exists(Globals.sTypePath({pack: c.path.pack, name: name}))) name = stem + "_" + (n++);
		var invoker = TypeFunctions.mkClass(c.module, {pack: c.path.pack.copy(), name: name}, cf.pos, cf.pos);
		pass.taken.set(Globals.sTypePath(invoker.path), true);
		// Outside gencs's class model, as the classes closuresToClass adds are.
		invoker.meta = [{name: ":nativeGen", params: [], pos: cf.pos}];
		invoker.superClass = {c: base, params: []};

		var arity = sig.args.length;
		for (f in [
			entry("__hx_accepts" + arity, at, args -> [ret(accepts(isStatic ? null : c, sig, args, at), at)]),
			entry("__hx_call" + arity + "_o", at, args -> callO(c, cf, isStatic, sig, args, at)),
			entry("__hx_call" + arity + "_f", at, args -> callF(c, cf, isStatic, sig, args, at))
		]) {
			invoker.fields.set(f.name, f);
			invoker.orderedFields.push(f);
		}

		// new() { super(arity); }
		var ctorType = TFun({args: [], ret: basic.tvoid});
		var superCall = TypeFunctions.mk(TCall(TypeFunctions.mk(TConst(TSuper), TInst(base, []), at), [pass.int(arity, at)]), basic.tvoid, at);
		var ctor = ClosuresToClass.newMethod("new", ctorType, at);
		ctor.expr = TypeFunctions.mk(TFunction(new TFunc([], basic.tvoid, TypeFunctions.mk(TBlock([superCall]), basic.tvoid, at))), ctorType, at);
		invoker.constructor = ctor;

		var current = TypeFunctions.mkField("__hx_current", TInst(invoker, []), at, at, true, true);
		invoker.statics.set(current.name, current);
		invoker.orderedStatics.push(current);

		g.methodInvokers.set(cf, invoker);
		pass.added.push(invoker);
		g.addClosureClass(invoker, c);
	}

	// The override of ClosureInvoker's `name`, whose body `body` makes from its arguments: the receiver,
	// then a Float and a Dynamic for each argument.
	function entry(name:String, at:Position, body:Array<TVar>->Array<TExpr>):TClassField {
		var inherited = base.fields.get(name);
		if (inherited == null) throw "internal error: haxe.lang.ClosureInvoker has no " + name;
		var sig = switch (TypeFunctions.follow(inherited.type)) {
			case TFun(s): s;
			case _: throw "internal error: haxe.lang.ClosureInvoker." + name + " is not a method";
		}
		var args = [for (a in sig.args) TypeFunctions.allocVar(VGenerated, a.name, a.t, at)];
		var cf = ClosuresToClass.newMethod(name, inherited.type, at);
		TypeFunctions.addClassFieldFlag(cf, CfOverride);
		var fun = new TFunc([for (a in args) {v: a}], sig.ret, TypeFunctions.mk(TBlock(body(args)), g.ctx.basic.tvoid, at));
		cf.expr = TypeFunctions.mk(TFunction(fun), inherited.type, at);
		return cf;
	}

	static function ret(e:TExpr, at:Position):TExpr {
		return TypeFunctions.mk(TReturn(e), TypeFunctions.tDynamic, at);
	}

	static function floatOf(args:Array<TVar>, i:Int, at:Position):TExpr return ClosuresToClass.local(args[1 + 2 * i], at);

	static function dynamicOf(args:Array<TVar>, i:Int, at:Position):TExpr return ClosuresToClass.local(args[2 + 2 * i], at);

	// `d == Runtime.undefined`: the argument is the double in its Float half.
	function isUndefined(d:TExpr, at:Position):TExpr {
		var runtime = pass.runtime;
		var undefined = runtime.statics.get("undefined");
		var rt = TypeFunctions.mk(TTypeExpr(TClassDecl(runtime)), TypeFunctions.tDynamic, at);
		var undef = TypeFunctions.mk(TField(rt, FStatic(runtime, undefined)), undefined.type, at);
		return TypeFunctions.mk(TBinop(OpEq, d, undef), g.ctx.basic.tbool, at);
	}

	// `__is__(d, mt)`, which a null fails.
	function isOf(d:TExpr, mt:ModuleType, at:Position):TExpr {
		var callee = TypeFunctions.mk(TIdent("__is__"), TypeFunctions.tDynamic, at);
		return TypeFunctions.mk(TCall(callee, [d, TypeFunctions.mk(TTypeExpr(mt), TypeFunctions.tDynamic, at)]), g.ctx.basic.tbool, at);
	}

	// Whether an instance method's receiver is of its class `receiver`, and the arguments have the parameters'
	// types, each one as the by-name path would pass it on as it is, or for a whole double in an Int's range, as
	// the same Int. A null goes by name.
	function accepts(receiver:Null<TClass>, sig:TSignature, args:Array<TVar>, at:Position):TExpr {
		var basic = g.ctx.basic;
		var all:Null<TExpr> = receiver == null ? null : isOf(ClosuresToClass.local(args[0], at), TClassDecl(receiver), at);
		for (i in 0...sig.args.length) {
			var test = accept(sig.args[i].t, floatOf(args, i, at), dynamicOf(args, i, at), at);
			if (test == null) continue;
			all = all == null ? test : TypeFunctions.mk(TBinop(OpBoolAnd, all, test), basic.tbool, at);
		}
		return all != null ? all : TypeFunctions.mk(TConst(TBool(true)), basic.tbool, at);
	}

	// The test of one argument, null when any value passes.
	function accept(t:T, f:TExpr, d:TExpr, at:Position):Null<TExpr> {
		var basic = g.ctx.basic;
		function is(mt:ModuleType):TExpr return isOf(d, mt, at);
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TDynamic(_):
				null;
			case TAbstract(a, _) if (a.path.name == "Int"):
				var whole = TypeFunctions.mkCast(TypeFunctions.mkCast(f, basic.tint, at), basic.tfloat, at);
				TypeFunctions.mk(TIf(isUndefined(d, at), TypeFunctions.mk(TBinop(OpEq, f, whole), basic.tbool, at), is(TAbstractDecl(a))), basic.tbool, at);
			case TAbstract(a, _) if (a.path.name == "Float"):
				TypeFunctions.mk(TBinop(OpBoolOr, isUndefined(d, at), is(TAbstractDecl(a))), basic.tbool, at);
			case TAbstract(a, _):
				is(TAbstractDecl(a));
			case TInst(c, _):
				is(TClassDecl(c));
			case TEnum(en, _):
				is(TEnumDecl(en));
			case _:
				throw "internal error: an invoker of a method with the parameter type " + t;
		}
	}

	// The call with its arguments unpacked, as a closure class's invoke method unpacks them, after the
	// statements that go in `unpack`.
	function call(c:TClass, cf:TClassField, isStatic:Bool, sig:TSignature, args:Array<TVar>, unpack:Array<TExpr>, at:Position):TExpr {
		var basic = g.ctx.basic;
		var locals = [];
		for (i in 0...sig.args.length) {
			var t = sig.args[i].t;
			var f = floatOf(args, i, at), d = dynamicOf(args, i, at);
			var value = TypeFunctions.mkCast(d, t, at);
			// Only these can come as a double; the others' tests refuse one.
			if (TypeFunctions.followWithoutNull(t).match(TDynamic(_) | TAbstract({path: {name: "Int" | "Float"}}, _)))
				value = TypeFunctions.mk(TIf(isUndefined(d, at), pass.fromFloat(f, t, at), value), t, at);
			var v = TypeFunctions.allocVar(VGenerated, "arg" + i, t, at);
			unpack.push(TypeFunctions.mk(TVarExpr(v, value), basic.tvoid, at));
			locals.push(ClosuresToClass.local(v, at));
		}
		var callee = if (isStatic) {
			TField(TypeFunctions.mk(TTypeExpr(TClassDecl(c)), TypeFunctions.tDynamic, at), FStatic(c, cf));
		} else {
			TField(TypeFunctions.mkCast(ClosuresToClass.local(args[0], at), TInst(c, []), at), FInstance(c, [], cf));
		}
		return TypeFunctions.mk(TCall(TypeFunctions.mk(callee, cf.type, at), locals), sig.ret, at);
	}

	// A call of Runtime's static method `name`.
	function runtimeCall(name:String, arg:TExpr, t:T, at:Position):TExpr {
		var runtime = pass.runtime;
		var cf = runtime.statics.get(name);
		if (cf == null) throw "internal error: haxe.lang.Runtime has no " + name;
		var rt = TypeFunctions.mk(TTypeExpr(TClassDecl(runtime)), TypeFunctions.tDynamic, at);
		return TypeFunctions.mk(TCall(TypeFunctions.mk(TField(rt, FStatic(runtime, cf)), cf.type, at), [arg]), t, at);
	}

	// The result as an object, as the by-name path gets it: through reflection, from MethodBase.Invoke and
	// Runtime.unbox, as a Dynamic can hold a boxed haxe.lang.Null<T>; from a `__hx_invokeField` case, as it is.
	function boxed(call:TExpr, sig:TSignature, reflected:Bool, at:Position):TExpr {
		var value = TypeFunctions.mkCast(call, TypeFunctions.tDynamic, at);
		return reflected && TypeFunctions.followWithoutNull(sig.ret).match(TDynamic(_)) ? runtimeCall("unbox", value, TypeFunctions.tDynamic, at) : value;
	}

	// What follows the unpacking: `body`'s statements, for a call the by-name path makes through reflection or
	// not. The first kind go in `throwingAgain`: a static's always, an instance method's when the receiver is of a
	// class that sends it to Runtime.slowCallField.
	function byPath(c:TClass, cf:TClassField, isStatic:Bool, args:Array<TVar>, body:Bool->Array<TExpr>, at:Position):Array<TExpr> {
		if (isStatic) return [throwingAgain(body(true), at)];
		var basic = g.ctx.basic;
		var test:Null<TExpr> = null;
		for (k in slowCallers(c, cf)) {
			var is = isOf(ClosuresToClass.local(args[0], at), TClassDecl(k), at);
			test = test == null ? is : TypeFunctions.mk(TBinop(OpBoolOr, test, is), basic.tbool, at);
		}
		if (test == null) return body(false);
		return [TypeFunctions.mk(TIf(test, throwingAgain(body(true), at)), basic.tvoid, at)].concat(body(false));
	}

	// `body` in a try that throws what it catches again, as Runtime.callMethodCasting throws an InnerException:
	// that resets the exception's trace, so a program reads the same frames as by name, without the method's
	// own. Throwing the catch's own variable would be a `rethrow`, which keeps them, so this throws a copy.
	function throwingAgain(body:Array<TExpr>, at:Position):TExpr {
		var basic = g.ctx.basic;
		var exception = g.runtimeClass("cs.system.Exception");
		if (exception == null) throw "internal error: the runtime has no cs.system.Exception";
		var caught = TypeFunctions.allocVar(VGenerated, "e", TInst(exception, []), at);
		var copy = TypeFunctions.allocVar(VGenerated, "thrown", caught.type, at);
		var again = [
			TypeFunctions.mk(TVarExpr(copy, ClosuresToClass.local(caught, at)), basic.tvoid, at),
			TypeFunctions.mk(TThrow(ClosuresToClass.local(copy, at)), TypeFunctions.tDynamic, at)
		];
		var tried = TypeFunctions.mk(TBlock(body), basic.tvoid, at);
		return TypeFunctions.mk(TTry(tried, [{v: caught, expr: TypeFunctions.mk(TBlock(again), basic.tvoid, at)}]), basic.tvoid, at);
	}

	function callO(c:TClass, cf:TClassField, isStatic:Bool, sig:TSignature, args:Array<TVar>, at:Position):Array<TExpr> {
		var el = [];
		var e = call(c, cf, isStatic, sig, args, el, at);
		return el.concat(byPath(c, cf, isStatic, args, reflected -> {
			ClosuresToClass.isVoid(sig.ret) ? [e, ret(TypeFunctions.nullExpr(TypeFunctions.tDynamic, at), at)] : [ret(boxed(e, sig, reflected, at), at)];
		}, at));
	}

	function callF(c:TClass, cf:TClassField, isStatic:Bool, sig:TSignature, args:Array<TVar>, at:Position):Array<TExpr> {
		var basic = g.ctx.basic;
		var el = [];
		var e = call(c, cf, isStatic, sig, args, el, at);
		return el.concat(byPath(c, cf, isStatic, args, reflected -> {
			if (ClosuresToClass.isVoid(sig.ret)) {
				[e, ret(TypeFunctions.mk(TConst(TFloat("0.0")), basic.tfloat, at), at)];
			} else if (TypeFunctions.followWithoutNull(sig.ret).match(TAbstract({path: {name: "Int" | "Float"}}, _))) {
				[ret(TypeFunctions.mkCast(e, basic.tfloat, at), at)];
			} else {
				[ret(runtimeCall("toDouble", boxed(e, sig, reflected, at), basic.tfloat, at), at)];
			}
		}, at));
	}
}
