package hxia.interp;

import haxe.io.Bytes;
import hxia.cppia.ModuleIR;
import hxia.cppia.Decoder;
import hxia.cppia.OpTree;
import hxia.Runtime.Limits;
import hxia.Errors;

// The sandboxed-tier interpreter: compiles a decoded module's op tree into Frame->Dynamic closures
// and runs it. Script values are host values (shared heap). Static calls resolve to script methods
// first, then to the host registry (the capability boundary). Execution is metered (fuel at loop
// back-edges and calls, call depth, allocation) for DoS resistance; the meter does not bound time
// spent inside a host native (SECURITY.md 4).
class Interp {
	final strings:Array<String>;
	final types:Array<String>;
	final registry:HostRegistry;
	final tree:ModuleTree;
	// "Type.method" -> the FUN op node of a script static method.
	final scriptStatics:Map<String, OpNode> = new Map();
	// "EnumType.Ctor" -> constructor index (position, = index; the writer sorts by it).
	final enumCtorIndex:Map<String, Int> = new Map();
	// Type name -> its script-class descriptor (ctor + instance methods), for `new` and dispatch.
	final scriptClasses:Map<String, ScriptClass> = new Map();
	// Enum type name -> its descriptor, for Type reflection over script enums.
	final scriptEnums:Map<String, ScriptEnum> = new Map();
	// Canonical instances of no-argument script enum constructors, so `A == A` holds like Haxe.
	final enumSingletons:Map<String, EnumValue> = new Map();
	// A host-class CLASSOF token -> the type name it was built from. The interpreter can present
	// distinct Class objects for one class across the neutral-static boundary, so a name-based
	// isOfType fallback needs the reliable compile-time name rather than Type.getClassName.
	final hostTokenNames:haxe.ds.ObjectMap<Dynamic, String> = new haxe.ds.ObjectMap();
	// "Class.field" -> current value of a script static var; its initializers run before main.
	final scriptStaticVars:Map<String, Dynamic> = new Map();
	final pendingStatics:Array<{key:String, body:Null<OpNode>}> = [];
	var mainCall:Null<OpNode>;

	// Metering
	final fuelLimit:Int;
	final maxDepth:Int;
	final maxAlloc:Int;
	var fuel:Int = 0;
	var depth:Int = 0;
	var alloc:Int = 0;

	// The single mediated seam for all reflective host access
	final mediator:Mediator;

	public function new(ir:ModuleIR, registry:HostRegistry, ?limits:Limits, ?mediator:Mediator) {
		this.registry = registry;
		this.mediator = mediator != null ? mediator : new Mediator(null, function(t, m) return registry.memberBinding(t, m));
		this.strings = [for (b in ir.strings) b.getString(0, b.length)];
		this.types = [for (b in ir.types) b.getString(0, b.length)];
		this.tree = Decoder.decode(ir);
		index();
		installSerialization();
		this.mainCall = tree.hasMain ? tree.main : null;
		this.fuelLimit = limits != null && limits.fuelPerCall != null ? limits.fuelPerCall : 100000000;
		this.maxDepth = limits != null && limits.maxCallDepth != null ? limits.maxCallDepth : 2000;
		this.maxAlloc = limits != null && limits.maxAllocBytes != null ? limits.maxAllocBytes : 1000000000;
	}

	inline function burnFuel():Void {
		if (--fuel < 0)
			throw new BudgetError(Fuel, "?", {file: "?", line: 0});
	}

	inline function countAlloc(n:Int):Void {
		alloc += n;
		if (alloc > maxAlloc)
			throw new BudgetError(AllocBytes, "?", {file: "?", line: 0});
	}

	function index():Void {
		for (d in tree.decls) {
			if (d.kind == "enum") {
				var enumName = types[d.ints[0]];
				var se = new ScriptEnum(enumName);
				for (i in 0...d.enumCtors.length) {
					var ctorName = strings[d.enumCtors[i][0]];
					enumCtorIndex.set(enumName + "." + ctorName, i);
					se.ctorNames.push(ctorName);
					se.ctorArity.push(d.enumCtors[i][1]);
				}
				scriptEnums.set(enumName, se);
				continue;
			}
			var className = types[d.ints[0]];
			var sc = new ScriptClass(className);
			var superId = d.ints[1];
			if (superId >= 0 && superId < types.length)
				sc.superName = types[superId];
			for (f in d.fields) {
				if (f.kind == "var") {
					// Static var: remember its initializer to run before main (instance vars are
					// set by the constructor body).
					var isStatic = f.ints[0] == 1;
					var vname = strings[f.ints[4]];
					if (isStatic) {
						pendingStatics.push({key: className + "." + vname, body: f.body});
						sc.staticFields.push(vname);
					} else {
						sc.instanceVars.push(vname);
					}
					continue;
				}
				if (f.kind != "function" || f.body == null)
					continue;
				var isStatic = f.ints[0] == 1;
				var name = strings[f.ints[2]];
				// The constructor is emitted with the static flag but has a `this` body; key it
				// by name so `new` allocates and runs it with the fresh instance as thisv.
				if (name == "new")
					sc.ctor = f.body;
				else if (isStatic) {
					scriptStatics.set(className + "." + name, f.body);
					sc.staticFields.push(name);
				} else
					sc.methods.set(name, f.body);
			}
			// A class with only static members is still registered so `new`/dispatch can find it.
			scriptClasses.set(className, sc);
		}
		// Resolve super links now that every class is registered.
		for (sc in scriptClasses)
			if (sc.superName != null)
				sc.superClass = scriptClasses.get(sc.superName);
	}

	// Evaluate static-var initializers once, before main. Declaration order across the module;
	// good enough for the corpus (cross-static init dependencies are rare and forward-declared).
	function initStatics():Void {
		for (p in pendingStatics)
			scriptStaticVars.set(p.key, p.body != null ? compile(p.body)(new Frame()) : null);
	}

	public function run():Void {
		fuel = fuelLimit;
		alloc = 0;
		initStatics();
		if (mainCall == null)
			return;
		compile(mainCall)(new Frame());
	}

	// Invoke a script static method (its FUN node) with args already evaluated.
	function invokeFun(fun:OpNode, thisv:Dynamic, args:Array<Dynamic>):Dynamic
		return runFun(fun, new Frame(thisv), args);

	// Run a FUN body in a freshly entered frame (its parent, if any, is the captured scope).
	// Binds args by their per-arg id, meters depth, and unwraps the return signal.
	function runFun(fun:OpNode, frame:Frame, args:Array<Dynamic>):Dynamic {
		burnFuel();
		if (++depth > maxDepth) {
			depth--;
			throw new BudgetError(CallDepth, "?", {file: "?", line: 0});
		}
		// FUN ints: [type, argc, then per arg: nameId, id, captured, type, marker...]
		var argc = fun.ints[1];
		var idx = 2;
		for (i in 0...argc) {
			var vId = fun.ints[idx + 1];
			frame.declare(vId, i < args.length ? args[i] : null);
			idx += 5;
			// A marker==1 arg carries a default value kid, consumed during decode; skip here
		}
		var body = fun.kids[fun.kids.length - 1];
		try {
			compile(body)(frame);
		} catch (r:ReturnSignal) {
			depth--;
			return r.value;
		} catch (e:haxe.Exception) {
			depth--;
			throw e;
		}
		depth--;
		return null;
	}

	// Compile an op node to a closure over a frame. Compiled once, then executed by call.
	function compile(n:OpNode):Frame->Dynamic {
		switch (n.op) {
			case "BLOCK":
				var kids = [for (k in n.kids) compile(k)];
				return function(f) { var last:Dynamic = null; for (c in kids) last = c(f); return last; };
			case "TVARS":
				var kids = [for (k in n.kids) compile(k)];
				return function(f) { for (c in kids) c(f); return null; };
			case "VARDECLI":
				var vId = n.ints[1];
				var init = compile(n.kids[0]);
				return function(f) { f.declare(vId, init(f)); return null; };
			case "VARDECL":
				var vId = n.ints[1];
				return function(f) { f.declare(vId, null); return null; };
			case "VAR":
				var vId = n.ints[0];
				return function(f) return f.get(vId);
			case "i":
				var v = n.ints[0];
				return function(f) return v;
			case "s":
				var v = strings[n.ints[0]];
				return function(f) return v;
			case "f":
				var v = Std.parseFloat(strings[n.ints[0]]);
				return function(f) return v;
			case "true": return function(f) return true;
			case "false": return function(f) return false;
			case "NULL": return function(f) return null;
			case "RETVAL":
				var e = compile(n.kids[0]);
				return function(f):Dynamic throw new ReturnSignal(e(f));
			case "RETURN":
				return function(f):Dynamic throw new ReturnSignal(null);
			case "SET":
				return compileSet(n);
			case "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", ">>=", ">>>=", "<<=":
				return compileModify(n);
			case "++", "+++", "--", "---":
				return compileCrement(n);
			case "FUN":
				// A function literal used as a value: capture the defining frame and return a
				// host-callable closure. The captured frame is the live scope, so the closure
				// reads and mutates enclosing locals through the parent chain.
				return function(f) {
					countAlloc(32);
					var captured = f;
					return Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic
						return runFun(n, new Frame(null, captured), args));
				};
			case "CALL":
				// Invoke a closure value (kids[0]) with the remaining kids as args.
				var fnE = compile(n.kids[0]);
				var argcs = [for (i in 1...n.kids.length) compile(n.kids[i])];
				return function(f) {
					burnFuel();
					var fn = fnE(f);
					var args = [for (c in argcs) c(f)];
					if (fn == null || !Reflect.isFunction(fn))
						throw new InterpError("hxia: CALL target is not a function (a host method read as a value may be inlined/DCE'd on this target)");
					return Reflect.callMethod(null, fn, args);
				};
			case "CALLSTATIC":
				var typeName = types[n.ints[0]];
				var member = strings[n.ints[1]];
				var argcs = [for (k in n.kids) compile(k)];
				return function(f) {
					var args = [for (c in argcs) c(f)];
					return callStatic(typeName, member, args);
				};
			case "CALLMEMBER":
				var member = strings[n.ints[1]];
				var recv = compile(n.kids[0]);
				// Enum runtime index (gencpp emits CALLMEMBER ::hx::EnumBase.__Index)
				if (member == "__Index")
					return function(f) return (recv(f) : EnumValue).index;
				var argcs = [for (i in 1...n.kids.length) compile(n.kids[i])];
				return function(f) {
					burnFuel();
					var obj = recv(f);
					var args = [for (c in argcs) c(f)];
					return callMember(obj, member, args);
				};
			case "CREATEENUM":
				var name = strings[n.ints[1]];
				var etype = types[n.ints[0]];
				var argcs = [for (k in n.kids) compile(k)];
				// A host enum (e.g. ValueType) must construct the real host value so it compares equal to
				// values host functions return; a script-only enum builds our EnumValue.
				var he = tryResolveEnumHost(etype);
				if (he != null)
					return function(f) { countAlloc(16); return Type.createEnum(he, name, [for (c in argcs) c(f)]); };
				var idx = enumIdxOf(n.ints[0], n.ints[1]);
				return function(f) { countAlloc(16); return mkEnum(etype, idx, name, [for (c in argcs) c(f)]); };
			case "FENUM":
				var name = strings[n.ints[1]];
				var etype = types[n.ints[0]];
				var he = tryResolveEnumHost(etype);
				if (he != null)
					return function(f) return Type.createEnum(he, name, []);
				var idx = enumIdxOf(n.ints[0], n.ints[1]);
				return function(f) return mkEnum(etype, idx, name, []);
			case "ENUMI":
				var pi = n.ints[1];
				var e = compile(n.kids[0]);
				return function(f) return (e(f) : EnumValue).params[pi];
			case "CALLTHIS":
				var member = strings[n.ints[1]];
				var argcs = [for (k in n.kids) compile(k)];
				return function(f) {
					burnFuel();
					var obj = f.thisv;
					var args = [for (c in argcs) c(f)];
					return callMember(obj, member, args);
				};
			case "CALLSUPER":
				// A non-virtual call to a named super method on `this` (super.m(...)).
				var superType = types[n.ints[0]];
				var member = strings[n.ints[1]];
				var argcs = [for (k in n.kids) compile(k)];
				return function(f) {
					burnFuel();
					var args = [for (c in argcs) c(f)];
					var sc = scriptClasses.get(superType);
					var m = sc != null ? sc.lookup(member) : null;
					if (m != null)
						return invokeFun(m, f.thisv, args);
					return mediator.callMethod(f.thisv, member, args);
				};
			case "CALLSUPERNEW":
				// Run the super constructor against the instance under construction (this).
				var superType = types[n.ints[0]];
				var argcs = [for (k in n.kids) compile(k)];
				return function(f) {
					var args = [for (c in argcs) c(f)];
					var sc = scriptClasses.get(superType);
					if (sc != null && sc.ctor != null)
						invokeFun(sc.ctor, f.thisv, args);
					return null;
				};
			case "NEW":
				var typeName = types[n.ints[0]];
				var argcs = [for (k in n.kids) compile(k)];
				return function(f) {
					countAlloc(16);
					var args = [for (c in argcs) c(f)];
					return construct(typeName, args);
				};
			case "ADEF":
				var argcs = [for (k in n.kids) compile(k)];
				return function(f) { countAlloc(8 + argcs.length * 8); return [for (c in argcs) c(f)]; };
			case "ARRAYI":
				var arr = compile(n.kids[0]);
				var idx = compile(n.kids[1]);
				// Out-of-bounds reads yield null per the Haxe spec; hxcpp returns 0 for value-typed
				// arrays, so bounds-check explicitly to keep the interpreter target-neutral.
				return function(f) {
					var a:Array<Dynamic> = arr(f);
					var i:Int = idx(f);
					return (i >= 0 && i < a.length) ? a[i] : null;
				};
			case "FLINK", "FNAME":
				var name = strings[n.ints[1]];
				var obj = compile(n.kids[0]);
				return function(f) return getMember(obj(f), name);
			case "FTHISINST":
				var name = strings[n.ints[1]];
				return function(f) return getMember(f.thisv, name);
			case "FSTATIC":
				var key = types[n.ints[0]] + "." + strings[n.ints[1]];
				var type = types[n.ints[0]], name = strings[n.ints[1]];
				return function(f) return getStatic(key, type, name);
			case "THIS":
				return function(f) return f.thisv;
			case "CLASSOF":
				// A script class resolves to its descriptor (the token used by the script-aware
				// isOfType); primitives (Int/Float/Bool/...) have no runtime Class on js, so carry
				// a marker the script-aware isOfType dispatches by name; a host class resolves to a
				// runtime Class.
				var typeName = types[n.ints[0]];
				var token:Dynamic = if (scriptClasses.exists(typeName)) scriptClasses.get(typeName);
					else if (scriptEnums.exists(typeName)) scriptEnums.get(typeName);
					else if (PrimType.isPrimitive(typeName)) new PrimType(typeName);
					else {
						// Prefer the real host class; a meta-type with no runtime Class on this target
						// (Class/Enum on js) falls back to a name token so the type reference does not
						// fail.
						var rc = tryResolveClass(typeName);
						if (rc != null)
							hostTokenNames.set(rc, stripPath(typeName));
						rc != null ? (rc : Dynamic) : new PrimType(stripPath(typeName));
					}
				return function(f) return token;
			case "POSINFO":
				// Builds the haxe.PosInfos auto-filled for ?pos args: [file, line, class, method].
				var file = strings[n.ints[0]], line = n.ints[1], cls = strings[n.ints[2]], meth = strings[n.ints[3]];
				return function(f):Dynamic return {fileName: file, lineNumber: line, className: cls, methodName: meth};
			case "OBJDEF":
				var count = n.ints[0];
				var names = [for (i in 0...count) strings[n.ints[1 + i]]];
				var vals = [for (k in n.kids) compile(k)];
				return function(f) {
					countAlloc(16 + count * 8);
					var o:Dynamic = {};
					for (i in 0...count)
						mediator.setField(o, names[i], vals[i](f));
					return o;
				};
			case "+", "-", "*", "/", "%", "<", ">", "<=", ">=", "==", "!=", "&", "|", "^", ">>", ">>>", "<<":
				var l = compile(n.kids[0]);
				var r = compile(n.kids[1]);
				var op = n.op;
				return function(f) return binop(op, l(f), r(f));
			case "&&":
				var l = compile(n.kids[0]);
				var r = compile(n.kids[1]);
				return function(f):Dynamic return (l(f) : Bool) && (r(f) : Bool);
			case "||":
				var l = compile(n.kids[0]);
				var r = compile(n.kids[1]);
				return function(f):Dynamic return (l(f) : Bool) || (r(f) : Bool);
			case "!":
				var e = compile(n.kids[0]);
				return function(f):Dynamic return !(e(f) : Bool);
			case "NEG":
				var e = compile(n.kids[0]);
				return function(f):Dynamic return -(e(f) : Float);
			case "IF":
				var c = compile(n.kids[0]);
				var t = compile(n.kids[1]);
				return function(f):Dynamic { if ((c(f) : Bool)) t(f); return null; };
			case "IFELSE":
				var c = compile(n.kids[0]);
				var t = compile(n.kids[1]);
				var e = compile(n.kids[2]);
				return function(f):Dynamic return (c(f) : Bool) ? t(f) : e(f);
			case "WHILE":
				var normal = n.ints[0] == 1;
				var c = compile(n.kids[0]);
				var b = compile(n.kids[1]);
				return function(f):Dynamic {
					// Break exits the whole loop (caught here); continue skips an iteration (caught per-iteration
					// in loopBody).
					try {
						if (normal) { while ((c(f) : Bool)) { burnFuel(); loopBody(b, f); } }
						else { do { burnFuel(); loopBody(b, f); } while ((c(f) : Bool)); }
					} catch (_:BreakSignal) {}
					return null;
				};
			case "BREAK":
				return function(f):Dynamic throw BreakSignal.INSTANCE;
			case "CONTINUE":
				return function(f):Dynamic throw ContinueSignal.INSTANCE;
			case "SWITCH":
				return compileSwitch(n);
			case "TRY":
				return compileTry(n);
			case "THROW":
				var e = compile(n.kids[0]);
				return function(f):Dynamic throw new ScriptThrow(e(f));
			// Type coercions: identity on a dynamic shared heap (the value already is the host value; the
			// writer's cast/interface wrappers carry no runtime representation here).
			case "NOTNULL", "TCAST", "CAST", "TOINTERFACE", "TOINTERFACEARRAY", "TODATAARRAY", "TODYNARRAY":
				return compile(n.kids[0]);
			case "ISNULL":
				var e = compile(n.kids[0]);
				return function(f):Dynamic return e(f) == null;
			case "~":
				var e = compile(n.kids[0]);
				return function(f):Dynamic return ~(e(f) : Int);
			case "CASTINT":
				var e = compile(n.kids[0]);
				return function(f):Dynamic return Std.int(e(f));
			case "CASTBOOL":
				var e = compile(n.kids[0]);
				return function(f):Dynamic return (e(f) : Bool);
			case _:
				throw new InterpError("unimplemented op '" + n.op + "'");
		}
	}

	// SWITCH ints=[caseCount, hasDefault, nValues per case...]; kids=[cond, (values, body) per
	// case, optional default]. Guards are already lowered to IFs inside the case bodies.
	function compileSwitch(n:OpNode):Frame->Dynamic {
		var caseCount = n.ints[0];
		var hasDefault = n.ints[1] == 1;
		var cond = compile(n.kids[0]);
		var ki = 1;
		var cases:Array<{vals:Array<Frame->Dynamic>, body:Frame->Dynamic}> = [];
		for (ci in 0...caseCount) {
			var nv = n.ints[2 + ci];
			var vals = [for (_ in 0...nv) compile(n.kids[ki++])];
			var body = compile(n.kids[ki++]);
			cases.push({vals: vals, body: body});
		}
		var def = hasDefault ? compile(n.kids[ki++]) : null;
		return function(f):Dynamic {
			var cv:Dynamic = cond(f);
			for (c in cases)
				for (v in c.vals)
					if (v(f) == cv)
						return c.body(f);
			return def != null ? def(f) : null;
		};
	}

	// TRY ints=[count, per catch: nameId id captured type]; kids=[block, catch bodies].
	// First-catch binding (single typed catch is the common case; multi-type matching is a
	// refinement). ReturnSignal and BudgetError are not ScriptThrow, so they propagate.
	function compileTry(n:OpNode):Frame->Dynamic {
		var block = compile(n.kids[0]);
		var count = n.ints[0];
		var catches:Array<{vId:Int, body:Frame->Dynamic}> = [];
		for (ci in 0...count) {
			var vId = n.ints[1 + ci * 4 + 1];
			catches.push({vId: vId, body: compile(n.kids[1 + ci])});
		}
		return function(f):Dynamic {
			try {
				return block(f);
			} catch (e:haxe.Exception) {
				// Control-flow signals and the budget meter must flow past a catch; everything
				// else (a script `throw`, a host exception from a binding) is catchable so a
				// script `catch(e:Dynamic)` behaves like Haxe.
				if (Std.isOfType(e, ReturnSignal) || Std.isOfType(e, BreakSignal)
					|| Std.isOfType(e, ContinueSignal) || Std.isOfType(e, BudgetError))
					throw e;
				if (catches.length == 0)
					throw e;
				f.locals.set(catches[0].vId, caughtValue(e));
				return catches[0].body(f);
			}
		};
	}

	// The value a script `catch` binds: a script throw and a host thrown value both unwrap to
	// the original value; any other host exception is passed through as the exception object.
	static function caughtValue(e:haxe.Exception):Dynamic {
		if (Std.isOfType(e, ScriptThrow))
			return (cast e : ScriptThrow).value;
		if (Std.isOfType(e, haxe.ValueException))
			return (cast e : haxe.ValueException).value;
		return e;
	}

	static inline function loopBody(b:Frame->Dynamic, f:Frame):Void {
		try b(f) catch (_:ContinueSignal) {}
	}

	function compileSet(n:OpNode):Frame->Dynamic {
		var lv = n.kids[0];
		var rhs = compile(n.kids[1]);
		switch (lv.op) {
			case "VAR":
				var vId = lv.ints[0];
				return function(f) { var v = rhs(f); f.assign(vId, v); return v; };
			case "ARRAYI":
				var arr = compile(lv.kids[0]);
				var idx = compile(lv.kids[1]);
				return function(f) { var v = rhs(f); (arr(f) : Array<Dynamic>)[idx(f)] = v; return v; };
			case "FLINK", "FNAME", "FTHISINST":
				var name = strings[lv.ints[1]];
				var obj = lv.op == "FTHISINST" ? null : compile(lv.kids[0]);
				return function(f) {
					var v = rhs(f);
					setMember(obj != null ? obj(f) : f.thisv, name, v);
					return v;
				};
			case "FSTATIC":
				var key = types[lv.ints[0]] + "." + strings[lv.ints[1]];
				var type = types[lv.ints[0]], name = strings[lv.ints[1]];
				return function(f) { var v = rhs(f); setStatic(key, type, name, v); return v; };
			case _:
				throw new InterpError("unimplemented SET lvalue '" + lv.op + "'");
		}
	}

	// A compound assignment "<op>=" on a local: read, apply the base op, store.
	function compileModify(n:OpNode):Frame->Dynamic {
		var lv = n.kids[0];
		var rhs = compile(n.kids[1]);
		var base = n.op.substr(0, n.op.length - 1);
		switch (lv.op) {
			case "VAR":
				var vId = lv.ints[0];
				return function(f) {
					var nv = binop(base, f.get(vId), rhs(f));
					f.assign(vId, nv);
					return nv;
				};
			case "ARRAYI":
				var arr = compile(lv.kids[0]);
				var idx = compile(lv.kids[1]);
				return function(f) {
					var a:Array<Dynamic> = arr(f);
					var i:Int = idx(f);
					var nv = binop(base, a[i], rhs(f));
					a[i] = nv;
					return nv;
				};
			case "FLINK", "FNAME", "FTHISINST":
				var name = strings[lv.ints[1]];
				var obj = lv.op == "FTHISINST" ? null : compile(lv.kids[0]);
				return function(f) {
					var o = obj != null ? obj(f) : f.thisv;
					var nv = binop(base, getMember(o, name), rhs(f));
					setMember(o, name, nv);
					return nv;
				};
			case "FSTATIC":
				var key = types[lv.ints[0]] + "." + strings[lv.ints[1]];
				var type = types[lv.ints[0]], name = strings[lv.ints[1]];
				return function(f) {
					var nv = binop(base, getStatic(key, type, name), rhs(f));
					setStatic(key, type, name, nv);
					return nv;
				};
			case _:
				throw new InterpError("unimplemented modify lvalue '" + lv.op + "'");
		}
	}

	// ++/-- (prefix return new) and +++/--- (postfix return old) on a local.
	function compileCrement(n:OpNode):Frame->Dynamic {
		var lv = n.kids[0];
		var delta = (n.op == "++" || n.op == "+++") ? 1 : -1;
		var post = n.op.length == 3;
		switch (lv.op) {
			case "VAR":
				var vId = lv.ints[0];
				return function(f) {
					var old:Dynamic = f.get(vId);
					var nv = numAdd(old, delta);
					f.assign(vId, nv);
					return post ? old : nv;
				};
			case "ARRAYI":
				var arr = compile(lv.kids[0]);
				var idx = compile(lv.kids[1]);
				return function(f) {
					var a:Array<Dynamic> = arr(f);
					var i:Int = idx(f);
					var old:Dynamic = a[i];
					var nv = numAdd(old, delta);
					a[i] = nv;
					return post ? old : nv;
				};
			case "FSTATIC":
				var key = types[lv.ints[0]] + "." + strings[lv.ints[1]];
				var type = types[lv.ints[0]], name = strings[lv.ints[1]];
				return function(f) {
					var old:Dynamic = getStatic(key, type, name);
					var nv = numAdd(old, delta);
					setStatic(key, type, name, nv);
					return post ? old : nv;
				};
			case "FTHISINST", "FLINK", "FNAME":
				var name = strings[lv.ints[1]];
				var obj = lv.op == "FTHISINST" ? null : compile(lv.kids[0]);
				return function(f) {
					var o = obj != null ? obj(f) : f.thisv;
					var old:Dynamic = getMember(o, name);
					var nv = numAdd(old, delta);
					setMember(o, name, nv);
					return post ? old : nv;
				};
			case _:
				throw new InterpError("unimplemented crement lvalue '" + lv.op + "'");
		}
	}

	function callStatic(type:String, member:String, args:Array<Dynamic>):Dynamic {
		var fun = scriptStatics.get(type + "." + member);
		if (fun != null)
			return invokeFun(fun, null, args);
		// isOfType must understand script classes: their instances are all the same host class,
		// so a host check cannot tell them apart; dispatch on the ScriptObject's descriptor.
		if (type == "Std" && member == "isOfType")
			return scriptIsOfType(args[0], args[1]);
		// Script-level Reflect goes through the same mediated seam, so it cannot bypass the
		// policy that gates direct member access.
		if (type == "Reflect") {
			switch (member) {
				case "field": return getMember(args[0], args[1]);
				case "setField": setMember(args[0], args[1], args[2]); return null;
				case "getProperty": return getMember(args[0], args[1]);
				case "setProperty": setMember(args[0], args[1], args[2]); return null;
				case "fields":
					if (Std.isOfType(args[0], ScriptObject))
						return [for (k in (args[0] : ScriptObject).fields.keys()) k];
					return mediator.fields(args[0]);
				case "hasField":
					if (Std.isOfType(args[0], ScriptObject)) {
						var so:ScriptObject = args[0];
						return so.fields.exists(args[1]) || so.cls.lookup(args[1]) != null;
					}
					return Reflect.hasField(args[0], args[1]);
				case "isEnumValue": return Std.isOfType(args[0], EnumValue) || Reflect.isEnumValue(args[0]);
				case _:
			}
		}
		// Type reflection must understand script classes and enums (they are not host types).
		if (type == "Type") {
			var handled = typeReflect(member, args);
			if (handled != NotHandled)
				return handled;
		}
		if (registry.hasStatic(type, member))
			return registry.staticCall(type, member, args);
		// Authority-free std class: resolve the static reflectively through the mediated seam
		// (the policy still governs it; the class is the receiver Reflect.field reads from).
		var neutral = registry.neutralStaticClass(type);
		if (neutral != null)
			return mediator.callMethod(neutral, member, args);
		return registry.staticCall(type, member, args);
	}

	// Sentinel returned by typeReflect for a call it does not handle (distinct from a handled
	// call that legitimately returns null).
	static final NotHandled:Dynamic = {__notHandled: true};

	// Type.* reflection that understands script classes/enums (which are not host types). Script
	// tokens are ScriptClass/ScriptEnum descriptors; anything not involving a script type falls
	// through (NotHandled) to the host Type via the neutral-static path.
	function typeReflect(member:String, args:Array<Dynamic>):Dynamic {
		var a0:Dynamic = args[0];
		switch (member) {
			case "getClass":
				if (Std.isOfType(a0, ScriptObject)) return (a0 : ScriptObject).cls;
				if (Std.isOfType(a0, EnumValue)) return null;
			case "getClassName":
				if (Std.isOfType(a0, ScriptClass)) return (a0 : ScriptClass).name;
				if (Std.isOfType(a0, PrimType)) return (a0 : PrimType).name;
			case "getEnumName":
				if (Std.isOfType(a0, ScriptEnum)) return (a0 : ScriptEnum).name;
			case "resolveClass":
				if (scriptClasses.exists(a0)) return scriptClasses.get(a0);
			case "resolveEnum":
				if (scriptEnums.exists(a0)) return scriptEnums.get(a0);
			case "getSuperClass":
				if (Std.isOfType(a0, ScriptClass)) return (a0 : ScriptClass).superClass;
			case "getInstanceFields":
				if (Std.isOfType(a0, ScriptClass)) return (a0 : ScriptClass).instanceFields();
			case "getClassFields":
				if (Std.isOfType(a0, ScriptClass)) return (a0 : ScriptClass).staticFields.copy();
			case "createInstance":
				if (Std.isOfType(a0, ScriptClass)) return instantiate(a0, args[1]);
			case "createEmptyInstance":
				if (Std.isOfType(a0, ScriptClass)) return new ScriptObject(a0);
			case "getEnum":
				if (Std.isOfType(a0, EnumValue)) return scriptEnums.get((a0 : EnumValue).enumType);
			case "getEnumConstructs":
				if (Std.isOfType(a0, ScriptEnum)) return (a0 : ScriptEnum).ctorNames.copy();
			case "createEnum":
				if (Std.isOfType(a0, ScriptEnum)) return makeEnum(a0, (a0 : ScriptEnum).indexOf(args[1]), args[1], args[2]);
			case "createEnumIndex":
				if (Std.isOfType(a0, ScriptEnum)) { var se:ScriptEnum = a0; return makeEnum(se, args[1], se.ctorNames[args[1]], args[2]); }
			case "enumParameters":
				if (Std.isOfType(a0, EnumValue)) return (a0 : EnumValue).params.copy();
			case "enumConstructor":
				if (Std.isOfType(a0, EnumValue)) return (a0 : EnumValue).name;
			case "enumIndex":
				if (Std.isOfType(a0, EnumValue)) return (a0 : EnumValue).index;
			case "enumEq":
				if (Std.isOfType(a0, EnumValue) || Std.isOfType(args[1], EnumValue)) return enumEq(a0, args[1]);
			case "typeof":
				if (Std.isOfType(a0, ScriptObject)) return Type.ValueType.TClass(cast (a0 : ScriptObject).cls);
				if (Std.isOfType(a0, EnumValue)) return Type.ValueType.TEnum(cast scriptEnums.get((a0 : EnumValue).enumType));
				// A script class/enum referenced as a value is a plain object to the host: TObject.
				if (Std.isOfType(a0, ScriptClass) || Std.isOfType(a0, ScriptEnum)) return Type.ValueType.TObject;
			case _:
		}
		return NotHandled;
	}

	function instantiate(sc:ScriptClass, args:Array<Dynamic>):Dynamic {
		var so = new ScriptObject(sc);
		if (sc.ctor != null)
			invokeFun(sc.ctor, so, args != null ? args : []);
		return so;
	}

	function makeEnum(se:ScriptEnum, index:Int, ctor:String, params:Array<Dynamic>):EnumValue
		return mkEnum(se.name, index, ctor, params != null ? params : []);

	// Build a script enum value, returning the canonical singleton for a no-argument constructor
	// so reference equality matches Haxe (Serializer/Unserializer and `==` both rely on this).
	public function mkEnum(enumType:String, index:Int, ctor:String, params:Array<Dynamic>):EnumValue {
		if (params.length == 0) {
			var key = enumType + "." + ctor;
			var s = enumSingletons.get(key);
			if (s == null) {
				s = new EnumValue(index, ctor, [], enumType);
				enumSingletons.set(key, s);
			}
			return s;
		}
		return new EnumValue(index, ctor, params, enumType);
	}

	// Serialization must be script-aware: the host Serializer/Unserializer reflect internally
	// and cannot see script classes/enums. Bind them to the shims, which reconstruct script
	// values via this interpreter's descriptors. Wired here (not in NeutralStd) because the
	// script tables are only known after index().
	function installSerialization():Void {
		registry.bindStatic("haxe.Serializer", "run", function(a) return NeutralSerializer.run(a[0]));
		registry.bindNew("haxe.Serializer", function(_) return new NeutralSerializer());
		var self = this;
		registry.bindStatic("haxe.Unserializer", "run", function(a) return NeutralUnserializer.run(a[0], self));
		registry.bindNew("haxe.Unserializer", function(a) return new NeutralUnserializer(a[0], self));
		// USE_ENUM_INDEX / USE_CACHE static reads/writes still resolve to the host class.
		registry.markNeutralStatic("haxe.Serializer", haxe.Serializer);
		registry.markNeutralStatic("haxe.Unserializer", haxe.Unserializer);
	}

	// Structural enum equality for script enums (host Type.enumEq cannot see them).
	function enumEq(a:Dynamic, b:Dynamic):Bool {
		if (!Std.isOfType(a, EnumValue) || !Std.isOfType(b, EnumValue))
			return a == b;
		var ea:EnumValue = a, eb:EnumValue = b;
		if (ea.enumType != eb.enumType || ea.index != eb.index || ea.params.length != eb.params.length)
			return false;
		for (i in 0...ea.params.length)
			if (!enumEq(ea.params[i], eb.params[i]) && ea.params[i] != eb.params[i])
				return false;
		return true;
	}

	// isOfType that spans both worlds: a ScriptClass token matches a ScriptObject whose class
	// chain reaches it; anything else defers to the host check.
	function scriptIsOfType(v:Dynamic, token:Dynamic):Bool {
		if (Std.isOfType(token, PrimType))
			return (token : PrimType).matches(v);
		// The std shims stand in for their host types, so isOfType against the real class holds.
		if (Std.isOfType(v, NeutralBytes))
			return token == haxe.io.Bytes;
		if (Std.isOfType(v, NeutralStringBuf))
			return token == StringBuf;
		if (Std.isOfType(token, ScriptEnum))
			return Std.isOfType(v, EnumValue) && (v : EnumValue).enumType == (token : ScriptEnum).name;
		if (Std.isOfType(token, ScriptClass)) {
			if (!Std.isOfType(v, ScriptObject))
				return false;
			var c = (v : ScriptObject).cls;
			var target = (token : ScriptClass);
			while (c != null) {
				if (c == target)
					return true;
				c = c.superClass;
			}
			return false;
		}
		// A script object is not an instance of any host class (except Dynamic-ish checks).
		if (Std.isOfType(v, ScriptObject))
			return false;
		if (Std.isOfType(v, token))
			return true;
		throw "SCRIPTISOFTYPE tokenClass=[" + (try Type.getClassName(token) catch (_:Dynamic) "?") + "] vClass=[" + (try Type.getClassName(Type.getClass(v)) catch (_:Dynamic) "?") + "]";
		// Fallback: the host can hand out distinct Class objects for the same class across the
		// neutral-static boundary (e.g. `Lambda.list(x)` vs `new List()` both haxe.ds.List), so a
		// direct isOfType can miss. Compare by class name up the value's super chain.
		return sameByName(v, token);
	}

	function sameByName(v:Dynamic, token:Dynamic):Bool {
		if (v == null)
			return false;
		// Prefer the name CLASSOF built the token from (reliable across the neutral-static
		// boundary); fall back to the runtime class name.
		var wanted:String = hostTokenNames.get(token);
		if (wanted == null)
			wanted = try Type.getClassName(token) catch (_:Dynamic) null;
		if (wanted == null)
			return false;
		var c = Type.getClass(v);
		while (c != null) {
			if (Type.getClassName(c) == wanted)
				return true;
			c = Type.getSuperClass(c);
		}
		return false;
	}

	function construct(type:String, args:Array<Dynamic>):Dynamic {
		var sc = scriptClasses.get(type);
		if (sc != null) {
			var so = new ScriptObject(sc);
			if (sc.ctor != null)
				invokeFun(sc.ctor, so, args);
			return so;
		}
		return registry.construct(type, args);
	}

	// Member access that understands script instances: a ScriptObject stores its fields in a
	// map and dispatches methods through its class descriptor; everything else falls through
	// to the mediated host seam (the capability boundary).
	function getMember(obj:Dynamic, name:String):Dynamic {
		if (Std.isOfType(obj, ScriptObject)) {
			var so:ScriptObject = obj;
			if (so.fields.exists(name))
				return so.fields.get(name);
			// Reading a method as a value yields a bound closure (so Reflect.field(obj, method)
			// and `obj.method` used as a value both work).
			var m = so.cls.lookup(name);
			if (m != null)
				return Reflect.makeVarArgs(function(args:Array<Dynamic>) return invokeFun(m, so, args));
			return null;
		}
		// A registry-bound method read as a value resolves to a bound closure (reliable when the
		// host method has no reflective field, e.g. inline iterator methods on js).
		var mv = mediator.methodValue(obj, name);
		if (mv != null)
			return mv;
		var v = mediator.getField(obj, name);
		// Reading `o.method` yields a bound closure in Haxe; host reflection (js) returns the
		// method unbound, so calling it later would lose `this`. Rebind to the receiver. This
		// is what makes `for (x in it)` work: the loop reads it.hasNext/it.next as closures.
		if (Reflect.isFunction(v))
			return Reflect.makeVarArgs(function(args:Array<Dynamic>) return mediator.callMethod(obj, name, args));
		return v;
	}

	function setMember(obj:Dynamic, name:String, v:Dynamic):Void {
		if (Std.isOfType(obj, ScriptObject))
			(obj : ScriptObject).fields.set(name, v);
		else
			mediator.setField(obj, name, v);
	}

	function callMember(obj:Dynamic, name:String, args:Array<Dynamic>):Dynamic {
		if (Std.isOfType(obj, ScriptObject)) {
			var m = (obj : ScriptObject).cls.lookup(name);
			if (m != null)
				return invokeFun(m, obj, args);
		}
		// The cppia map remap (setString/getInt/...) only applies to map receivers; translating
		// it unconditionally would clobber same-named methods elsewhere (e.g. Bytes.getString).
		if (Std.isOfType(obj, haxe.Constraints.IMap))
			name = mapMethodShim(name);
		return mediator.callMethod(obj, name, args);
	}

	// Read a static field: a script static var if we own it, else a host static (Reflect on
	// the resolved class). Statics the interpreter does not know resolve through the mediator's
	// class, keeping host access on the single mediated seam.
	function getStatic(key:String, type:String, name:String):Dynamic {
		if (scriptStaticVars.exists(key))
			return scriptStaticVars.get(key);
		// A static method of a script class read as a value: return a bound-free closure.
		var fun = scriptStatics.get(type + "." + name);
		if (fun != null)
			return Reflect.makeVarArgs(function(args:Array<Dynamic>) return invokeFun(fun, null, args));
		// Math constants are inline/property statics on js, so reflection reads null; return the
		// literal values.
		if (type == "Math") {
			switch (name) {
				case "NaN": return Math.NaN;
				case "POSITIVE_INFINITY": return Math.POSITIVE_INFINITY;
				case "NEGATIVE_INFINITY": return Math.NEGATIVE_INFINITY;
				case "PI": return Math.PI;
				case _:
			}
		}
		var cls = resolveClass(type);
		return mediator.getField(cls, name);
	}

	function setStatic(key:String, type:String, name:String, v:Dynamic):Void {
		if (scriptStaticVars.exists(key))
			scriptStaticVars.set(key, v);
		else
			mediator.setField(resolveClass(type), name, v);
	}

	function enumIdxOf(enumTypeId:Int, ctorNameId:Int):Int {
		var key = types[enumTypeId] + "." + strings[ctorNameId];
		var i = enumCtorIndex.get(key);
		if (i == null)
			throw new InterpError("hxia: unknown enum constructor " + key);
		return i;
	}

	final classCache:Map<String, Class<Dynamic>> = new Map();

	// A CLASSOF operand is a cpp-style path ("::String", "::haxe::Exception"); resolve to a
	// runtime Class for isOfType/casts.
	final enumCache:Map<String, Enum<Dynamic>> = new Map();

	// Try to resolve a host enum type (cpp-pathed) to a runtime Enum; null if the host has no
	// such enum (i.e. it is a script-defined enum). A std enum (e.g. ValueType) is embedded in
	// the cppia as a decl but MUST behave as a host enum so its values interop with host
	// functions (Type.typeof), so host resolution takes precedence over the script index.
	function tryResolveEnumHost(name:String):Null<Enum<Dynamic>> {
		if (enumCache.exists(name))
			return enumCache.get(name);
		var dotted = StringTools.replace(StringTools.startsWith(name, "::") ? name.substr(2) : name, "::", ".");
		var re = Type.resolveEnum(dotted);
		enumCache.set(name, re);
		return re;
	}

	function resolveClass(name:String):Class<Dynamic> {
		var c = classCache.get(name);
		if (c != null)
			return c;
		var rc = tryResolveClass(name);
		if (rc == null)
			throw new InterpError("hxia: cannot resolve class '" + stripPath(name) + "'");
		return rc;
	}

	static inline function stripPath(name:String):String
		return StringTools.replace(StringTools.startsWith(name, "::") ? name.substr(2) : name, "::", ".");

	function tryResolveClass(name:String):Null<Class<Dynamic>> {
		if (classCache.exists(name))
			return classCache.get(name);
		var rc = Type.resolveClass(stripPath(name));
		classCache.set(name, rc);
		return rc;
	}

	// The cppia map remap turns set/get on typed maps into setInt/getString etc.; the neutral
	// host map has set/get, so translate back.
	static function mapMethodShim(m:String):String {
		return switch (m) {
			case "setInt" | "setString" | "setFloat" | "setBool" | "setInt64" | "setObject": "set";
			case "getInt" | "getString" | "getFloat" | "getBool" | "getInt64" | "getObject": "get";
			case _: m;
		};
	}

	static function binop(op:String, a:Dynamic, b:Dynamic):Dynamic {
		switch (op) {
			case "+":
				if (Std.isOfType(a, String) || Std.isOfType(b, String))
					return Std.string(a) + Std.string(b);
				return numAdd(a, b);
			case "-": return num(a) - num(b);
			case "*": return num(a) * num(b);
			case "/": return num(a) / num(b);
			case "%": return num(a) % num(b);
			case "<": return num(a) < num(b);
			case ">": return num(a) > num(b);
			case "<=": return num(a) <= num(b);
			case ">=": return num(a) >= num(b);
			case "==": return a == b;
			case "!=": return a != b;
			case "&": return int(a) & int(b);
			case "|": return int(a) | int(b);
			case "^": return int(a) ^ int(b);
			case ">>": return int(a) >> int(b);
			case ">>>": return int(a) >>> int(b);
			case "<<": return int(a) << int(b);
			case _: throw new InterpError("unimplemented binop '" + op + "'");
		}
	}

	static inline function numAdd(a:Dynamic, b:Dynamic):Dynamic {
		if (Std.isOfType(a, Int) && Std.isOfType(b, Int))
			return (a : Int) + (b : Int);
		return num(a) + num(b);
	}

	static inline function num(x:Dynamic):Float
		return (x : Float);

	static inline function int(x:Dynamic):Int
		return (x : Int);
}

class ReturnSignal extends haxe.Exception {
	public var value:Dynamic;
	public function new(value:Dynamic) { super("return"); this.value = value; }
}

// Loop control signals. A shared instance avoids allocating on every break/continue (they carry no
// payload); catching by type still works.
class BreakSignal extends haxe.Exception {
	public static final INSTANCE = new BreakSignal();
	public function new() super("break");
}

class ContinueSignal extends haxe.Exception {
	public static final INSTANCE = new ContinueSignal();
	public function new() super("continue");
}

// A value thrown by script `throw`; caught by script `try`. Distinct from ReturnSignal and
// BudgetError so those flow past a catch.
class ScriptThrow extends haxe.Exception {
	public var value:Dynamic;
	public function new(value:Dynamic) { super("script-throw"); this.value = value; }
}

// A script class descriptor: its constructor and instance-method FUN nodes, keyed by name,
// plus a link to its super class so dispatch and `super` calls can walk the chain.
class ScriptClass {
	public var name:String;
	public var superName:Null<String>;
	public var superClass:Null<ScriptClass>;
	public var ctor:Null<OpNode>;
	public var methods:Map<String, OpNode> = new Map();
	public var instanceVars:Array<String> = [];
	public var staticFields:Array<String> = [];
	public function new(name:String) this.name = name;

	// Resolve a method by name, walking up the super chain (virtual dispatch).
	public function lookup(name:String):Null<OpNode> {
		var c = this;
		while (c != null) {
			var m = c.methods.get(name);
			if (m != null)
				return m;
			c = c.superClass;
		}
		return null;
	}

	// Instance fields (vars + methods) for Type.getInstanceFields, in declaration order and
	// walking up the super chain (super first, matching Haxe), deduplicated.
	public function instanceFields():Array<String> {
		var out:Array<String> = [];
		var chain:Array<ScriptClass> = [];
		var c = this;
		while (c != null) { chain.unshift(c); c = c.superClass; }
		for (k in chain) {
			for (v in k.instanceVars)
				if (out.indexOf(v) < 0) out.push(v);
			for (m in k.methods.keys())
				if (out.indexOf(m) < 0) out.push(m);
		}
		return out;
	}
}

// A script enum descriptor: its constructors by name and index, for Type.resolveEnum /
// createEnum / getEnumConstructs and enum reflection.
class ScriptEnum {
	public var name:String;
	public var ctorNames:Array<String> = [];
	public var ctorArity:Array<Int> = [];
	public function new(name:String) this.name = name;

	public function indexOf(ctor:String):Int
		return ctorNames.indexOf(ctor);
}

// A script-class instance: its class descriptor plus a field map. Fields and methods on it
// are resolved by the interpreter (getMember/setMember/callMember), never by raw host
// reflection, so a script object stays inside the same mediated model as host values.
class ScriptObject {
	public var cls:ScriptClass;
	public var fields:Map<String, Dynamic> = new Map();
	public function new(cls:ScriptClass) this.cls = cls;
}

// A CLASSOF token for a primitive type, which has no runtime Class on some targets (js). It
// dispatches isOfType with literal type checks that compile correctly on every host.
class PrimType {
	public var name:String;
	public function new(name:String) this.name = name;

	public static function isPrimitive(name:String):Bool {
		return switch (name) {
			case "Int" | "Float" | "Bool" | "UInt" | "Single" | "Dynamic": true;
			case _: false;
		}
	}

	public function matches(v:Dynamic):Bool {
		return switch (name) {
			case "Int" | "UInt": Std.isOfType(v, Int);
			case "Float" | "Single": Std.isOfType(v, Float);
			case "Bool": Std.isOfType(v, Bool);
			case "Dynamic": true;
			// A host class name whose runtime Class could not be resolved on this target: match by
			// class name up the value's super chain (the same class can present distinct Class
			// objects across the neutral-static boundary, so an identity check is unreliable).
			case _: nameInChain(v, name);
		}
	}

	static function nameInChain(v:Dynamic, name:String):Bool {
		if (v == null)
			return false;
		var c = Type.getClass(v);
		while (c != null) {
			if (Type.getClassName(c) == name)
				return true;
			c = Type.getSuperClass(c);
		}
		return false;
	}
}

// A script enum value: constructor index (switch dispatches on it), name, and parameters.
class EnumValue {
	public var index:Int;
	public var name:String;
	public var params:Array<Dynamic>;
	public var enumType:String;
	public function new(index:Int, name:String, params:Array<Dynamic>, ?enumType:String) {
		this.index = index; this.name = name; this.params = params;
		this.enumType = enumType;
	}

	// Haxe enum string form: `Name` for a no-arg constructor, `Name(p0,p1)` otherwise. Host
	// Std.string calls this automatically, so script enums stringify like real ones everywhere.
	public function toString():String {
		if (params == null || params.length == 0)
			return name;
		var s = name + "(";
		for (i in 0...params.length) {
			if (i > 0)
				s += ",";
			s += Std.string(params[i]);
		}
		return s + ")";
	}
}
