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
				for (i in 0...d.enumCtors.length)
					enumCtorIndex.set(enumName + "." + strings[d.enumCtors[i][0]], i);
				continue;
			}
			var className = types[d.ints[0]];
			for (f in d.fields) {
				if (f.kind != "function" || f.body == null)
					continue;
				var isStatic = f.ints[0] == 1;
				var name = strings[f.ints[2]];
				if (isStatic)
					scriptStatics.set(className + "." + name, f.body);
			}
		}
	}

	public function run():Void {
		if (mainCall == null)
			return;
		fuel = fuelLimit;
		alloc = 0;
		compile(mainCall)(new Frame());
	}

	// Invoke a script static method (its FUN node) with args already evaluated.
	function invokeFun(fun:OpNode, thisv:Dynamic, args:Array<Dynamic>):Dynamic {
		burnFuel();
		if (++depth > maxDepth) {
			depth--;
			throw new BudgetError(CallDepth, "?", {file: "?", line: 0});
		}
		var frame = new Frame(thisv);
		// FUN ints: [type, argc, then per arg: nameId, id, captured, type, marker...]
		var argc = fun.ints[1];
		var idx = 2;
		for (i in 0...argc) {
			var vId = fun.ints[idx + 1];
			frame.locals.set(vId, args[i]);
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
				return function(f) { f.locals.set(vId, init(f)); return null; };
			case "VARDECL":
				var vId = n.ints[1];
				return function(f) { f.locals.set(vId, null); return null; };
			case "VAR":
				var vId = n.ints[0];
				return function(f) return f.locals.get(vId);
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
			case "CALLSTATIC":
				var typeName = types[n.ints[0]];
				var member = strings[n.ints[1]];
				var argcs = [for (k in n.kids) compile(k)];
				return function(f) {
					var args = [for (c in argcs) c(f)];
					return callStatic(typeName, member, args);
				};
			case "CALLMEMBER":
				var member = mapMethodShim(strings[n.ints[1]]);
				var recv = compile(n.kids[0]);
				// Enum runtime index (gencpp emits CALLMEMBER ::hx::EnumBase.__Index)
				if (member == "__Index")
					return function(f) return (recv(f) : EnumValue).index;
				var argcs = [for (i in 1...n.kids.length) compile(n.kids[i])];
				return function(f) {
					burnFuel();
					var obj = recv(f);
					var args = [for (c in argcs) c(f)];
					return mediator.callMethod(obj, member, args);
				};
			case "CREATEENUM":
				var idx = enumIdxOf(n.ints[0], n.ints[1]);
				var name = strings[n.ints[1]];
				var argcs = [for (k in n.kids) compile(k)];
				return function(f) { countAlloc(16); return new EnumValue(idx, name, [for (c in argcs) c(f)]); };
			case "FENUM":
				var idx = enumIdxOf(n.ints[0], n.ints[1]);
				var name = strings[n.ints[1]];
				return function(f) return new EnumValue(idx, name, []);
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
					return mediator.callMethod(obj, member, args);
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
				return function(f) return (arr(f) : Array<Dynamic>)[idx(f)];
			case "FLINK", "FNAME":
				var name = strings[n.ints[1]];
				var obj = compile(n.kids[0]);
				return function(f) return mediator.getField(obj(f), name);
			case "FTHISINST":
				var name = strings[n.ints[1]];
				return function(f) return mediator.getField(f.thisv, name);
			case "THIS":
				return function(f) return f.thisv;
			case "CLASSOF":
				var cls = resolveClass(types[n.ints[0]]);
				return function(f) return cls;
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
					if (normal) { while ((c(f) : Bool)) { burnFuel(); loopBody(b, f); } }
					else { do { burnFuel(); loopBody(b, f); } while ((c(f) : Bool)); }
					return null;
				};
			case "SWITCH":
				return compileSwitch(n);
			case "TRY":
				return compileTry(n);
			case "THROW":
				var e = compile(n.kids[0]);
				return function(f):Dynamic throw new ScriptThrow(e(f));
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
			} catch (t:ScriptThrow) {
				if (catches.length == 0)
					throw t;
				f.locals.set(catches[0].vId, t.value);
				return catches[0].body(f);
			}
		};
	}

	static inline function loopBody(b:Frame->Dynamic, f:Frame):Void {
		try b(f) catch (_:BreakSignal) {}
	}

	function compileSet(n:OpNode):Frame->Dynamic {
		var lv = n.kids[0];
		var rhs = compile(n.kids[1]);
		switch (lv.op) {
			case "VAR":
				var vId = lv.ints[0];
				return function(f) { var v = rhs(f); f.locals.set(vId, v); return v; };
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
					var nv = binop(base, f.locals.get(vId), rhs(f));
					f.locals.set(vId, nv);
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
					var old:Dynamic = f.locals.get(vId);
					var nv = numAdd(old, delta);
					f.locals.set(vId, nv);
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
		// Script-level Reflect goes through the same mediated seam, so it cannot bypass the
		// policy that gates direct member access.
		if (type == "Reflect") {
			switch (member) {
				case "field": return mediator.getField(args[0], args[1]);
				case "setField": mediator.setField(args[0], args[1], args[2]); return null;
				case "fields": return mediator.fields(args[0]);
				case _:
			}
		}
		return registry.staticCall(type, member, args);
	}

	function construct(type:String, args:Array<Dynamic>):Dynamic {
		// TODO: script-class construction resolves here once instances land; host for now.
		return registry.construct(type, args);
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
	function resolveClass(name:String):Class<Dynamic> {
		var c = classCache.get(name);
		if (c != null)
			return c;
		var dotted = StringTools.replace(StringTools.startsWith(name, "::") ? name.substr(2) : name, "::", ".");
		var rc = Type.resolveClass(dotted);
		if (rc == null)
			throw new InterpError("hxia: cannot resolve class '" + dotted + "'");
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

class BreakSignal extends haxe.Exception {
	public function new() super("break");
}

// A value thrown by script `throw`; caught by script `try`. Distinct from ReturnSignal and
// BudgetError so those flow past a catch.
class ScriptThrow extends haxe.Exception {
	public var value:Dynamic;
	public function new(value:Dynamic) { super("script-throw"); this.value = value; }
}

// A script enum value: constructor index (switch dispatches on it), name, and parameters.
class EnumValue {
	public var index:Int;
	public var name:String;
	public var params:Array<Dynamic>;
	public function new(index:Int, name:String, params:Array<Dynamic>) {
		this.index = index; this.name = name; this.params = params;
	}
}
