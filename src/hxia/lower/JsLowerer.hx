package hxia.lower;

import hxia.cppia.ModuleIR;
import hxia.cppia.OpTree;
import hxia.cppia.Decoder;

// T1 tier: lower a decoded ModuleIR to JS source, evaluated at load. This is the trusted-fast
// counterpart to the T3 interpreter (src/hxia/interp): the same ModuleIR, but each op is emitted as
// JS text instead of compiled to a Haxe closure, so the semantics follow the interpreter op-for-op
// and T1 output must be identical to T3.
//
// COVERED: literals, locals, all binary/unary ops, blocks, if/while/switch, break/continue, return,
// try/throw, local closures, arrays, script classes (constructors + prototype methods +
// inheritance), statics, and script enums. not covered: host enums, the ValueException wrapping the
// interpreter does at a catch boundary, and reflection. An unhandled op throws a LowerError naming
// it, so a gap is visible rather than silently emitting wrong code.
//
// The emitted module is a function `($host) => { ...decls...; run main }`. Script classes live in
// SC (JS constructor functions), script statics in SS, static vars in SV, interned no-arg enum
// values in EI. Host access goes through the `$host` seam ($new/$mem/$gs/$isType/$classof fall back
// to it). Every interpreter local `id` becomes a JS `var L<id>` in its function scope (ids are
// per-function).
class LowerError {
	public var message:String;
	public function new(m:String) this.message = m;
}

class JsLowerer {
	final strings:Array<String>;
	final types:Array<String>;
	final tree:ModuleTree;
	// Fully-qualified names of script statics ("Class.method"), so a CALLSTATIC to one is a direct
	// call rather than a host dispatch.
	final scriptStatics:Map<String, Bool> = new Map();
	var buf:StringBuf;
	// Nesting counter for generated temporaries ($s0/$e0, ...) so nested switches/tries never collide.
	var switchDepth = 0;
	// "Enum.Ctor" -> constructor index, for CREATEENUM/FENUM.
	final enumCtorIndex:Map<String, Int> = new Map();
	final enumCtorArity:Map<String, Int> = new Map();

	// Types the host provides natively (Math, haxe.Json, haxe.format.JsonParser, ...). The cppia may
	// still carry a decl copy of such a type as DCE fallout, but running that copy would re-execute
	// inlined internals that do not work off-target, so a call to one must go to the host - the same
	// rule the interpreter applies via registry.neutralStaticClass.
	final isNeutralStatic:String->Bool;

	public function new(ir:ModuleIR, ?isNeutralStatic:String->Bool) {
		this.isNeutralStatic = isNeutralStatic != null ? isNeutralStatic : function(_) return false;
		this.strings = [for (b in ir.strings) b.getString(0, b.length)];
		this.types = [for (b in ir.types) b.getString(0, b.length)];
		this.tree = Decoder.decode(ir);
		for (d in tree.decls)
			if (d.kind == "class") {
				var cn = types[d.ints[0]];
				if (this.isNeutralStatic(cn))
					continue;
				for (f in d.fields)
					if (f.kind == "function" && f.ints[0] == 1 && f.body != null)
						scriptStatics.set(cn + "." + strings[f.ints[2]], true);
			}
	}

	public static function lower(ir:ModuleIR, ?isNeutralStatic:String->Bool):String
		return new JsLowerer(ir, isNeutralStatic).emit();

	function emit():String {
		buf = new StringBuf();
		buf.add("(function($host){\n\"use strict\";\n");
		// SC: script classes (constructor functions), SS: script statics (functions),
		// SV: script static vars. The runtime helpers mirror the interpreter's construct/callMember/
		// getStatic: prefer the script world, fall back to the host seam.
		buf.add("var SC = {}, SS = {}, SV = {};\n");
		buf.add("function $new(t, args){ var c = SC[t]; if (c) { var o = new c(); if (o.__ctor) o.__ctor.apply(o, args); return o; } return $host.construct(t, args); }\n");
		// A store the cppia inlines from Bytes.set is `<recv>.b[i] = v`; mask to 0..255 when the
		// receiver is a byte buffer, as the interpreter does at its ARRAYI store.
		buf.add("function $bset(o, i, v){ $fld(o, \"b\")[i] = $host.isBytes(o) ? (v & 0xFF) : v; return v; }\n");
		// The checked cast throws only for a SCRIPT instance that fails the script-type test (the
		// interpreter's checkedCast); host values and Dynamic targets pass through.
		buf.add("function $tcast(v, t){ if (v != null && v.__sc === true && t !== \"Dynamic\" && SC[t] && !$isType(v, t))"
			+ " throw \"Cannot cast to \" + t; return v; }\n");
		// A member call dispatches directly only on a SCRIPT instance (tagged __sc); every host value
		// goes through the seam so the registry's bindings win, exactly as the interpreter's mediator
		// does. Preferring the native JS method here would silently bypass bindings that exist because
		// the native one differs (e.g. String.substr, whose omitted length arrives as an explicit null).
		buf.add("function $mem(o, m, args){ if (o != null && o.__sc === true && typeof o[m] === \"function\") return o[m].apply(o, args); return $host.callMember(o, m, args); }\n");
		buf.add("function $gs(k, t, m){ if (Object.prototype.hasOwnProperty.call(SV, k)) return SV[k]; if (SS[k]) return SS[k]; return $host.getStatic(t, m); }\n");
		// Reading `o.method` as a value yields a bound method in Haxe, but a plain JS property read
		// yields the unbound function - calling it later loses `this` (Lambda.array({iterator: m.keys})
		// then sees an undefined receiver). Bind on read, caching per script instance so repeated reads
		// give the same closure (Reflect.compareMethods), exactly as the interpreter does. An own
		// function-valued field is already a closure and may be reassigned, so it is returned raw - only
		// PROTOTYPE methods are bound and cached (the interpreter caches methods, never fields; caching a
		// field would keep serving the stale closure after reassignment).
		buf.add("function $fld(o, n){ if (o == null) throw \"Null Object Reference\"; var v = o[n]; if (typeof v !== \"function\") return v;"
			+ " if (o.__sc === true) { if (Object.prototype.hasOwnProperty.call(o, n)) return v;"
			+ " var c = o.__b || (o.__b = {}); return c[n] || (c[n] = v.bind(o)); } return v.bind(o); }\n");
		// A script class is a JS constructor, so `is` against it is a prototype-chain test.
		buf.add("function $isType(v, t){ if (t === \"Dynamic\") return true; var c = SC[t]; if (c && v instanceof c) return true;"
			+ " if (v != null && v.__ifs && v.__ifs[t]) return true;"
			+ " if (ED[t]) return v != null && v.__e === t; return $host.isOfType(v, t); }\n");
		buf.add("function $classof(t){ var c = SC[t]; if (c) return c; var e = ED[t]; if (e) return e; return $host.classOf(t); }
");
		// A script enum value: {__e type, __i index, __n ctor name, __p params}. A no-argument
		// constructor is interned per type+name so `A == A` holds, as it does in the interpreter.
		buf.add("var EI = {};\n");
		// The shared prototype carries toString so an enum stringifies as `Ctor(a,b)` like Haxe, and
		// keeps it off the own-field set that Reflect.fields reports. A null parameter must print as
		// "null" (JS Array.join renders null as ""), matching Haxe.
		buf.add("var EP = { toString: function(){ if (!this.__p.length) return this.__n;"
			+ " var s = []; for (var i = 0; i < this.__p.length; i++) { var x = this.__p[i]; s.push(x == null ? \"null\" : \"\" + x); }"
			+ " return this.__n + \"(\" + s.join(\",\") + \")\"; } };\n");
		buf.add("function $mkE(t, i, n, p){ var o = Object.create(EP); o.__e = t; o.__i = i; o.__n = n; o.__p = p; return o; }\n");
		buf.add("function $enum(t, i, n, p){ if (p.length === 0) { var k = t + \".\" + n; var s = EI[k]; if (!s) { s = EI[k] = $mkE(t, i, n, []); } return s; } return $mkE(t, i, n, p); }\n");
		// Enum constructor indices, so CREATEENUM/FENUM can resolve a ctor name to its index.
		for (d in tree.decls) {
			if (d.kind != "enum")
				continue;
			var en = types[d.ints[0]];
			for (i in 0...d.enumCtors.length) {
				enumCtorIndex.set(en + "." + strings[d.enumCtors[i][0]], i);
				enumCtorArity.set(en + "." + strings[d.enumCtors[i][0]], d.enumCtors[i][1]);
			}
		}
		// Pass 1: allocators, so a forward reference between classes resolves.
		for (d in tree.decls) {
			if (d.kind == "enum")
				continue;
			if (d.kind != "class" && d.kind != "interface")
				throw new LowerError("decl kind '" + d.kind + "' not lowered yet");
			buf.add("SC[" + jsStr(types[d.ints[0]]) + "] = function(){};\n");
		}
		// Pass 2: prototype chains (extends), before any method is attached.
		for (d in tree.decls) {
			if (d.kind == "enum")
				continue;
			var superId = d.ints[1];
			if (superId >= 0 && superId < types.length) {
				var cn = jsStr(types[d.ints[0]]), sn = jsStr(types[superId]);
				buf.add("if (SC[" + sn + "]) { SC[" + cn + "].prototype = Object.create(SC[" + sn
					+ "].prototype); SC[" + cn + "].prototype.constructor = SC[" + cn + "]; }\n");
			}
		}
		// Tag script prototypes (after the chains are built, since Object.create replaces them) so
		// $mem can tell a script instance from a host value, and carry the class name so reflection
		// over a script type can answer getClass/getClassName without a side table.
		for (d in tree.decls)
			if (d.kind != "enum") {
				var cn = jsStr(types[d.ints[0]]);
				buf.add("SC[" + cn + "].prototype.__sc = true; SC[" + cn + "].prototype.__cname = " + cn
					+ "; SC[" + cn + "].__cname = " + cn + ";\n");
				// The transitive interface set, as prototype flags for $isType.
				var ifs = transitiveInterfaces(d);
				if (ifs.length > 0)
					buf.add("SC[" + cn + "].prototype.__ifs = {" + [for (nm in ifs) jsStr(nm) + ": true"].join(", ") + "};\n");
				// The Type.getInstanceFields list, in the interpreter's order (super chain first,
				// vars then methods per class, extern property vars dropped, deduplicated). Instance
				// vars live on instances, not the prototype, so the host cannot derive this itself.
				buf.add("SC[" + cn + "].__ifields = [" + [for (nm in instanceFieldList(d)) jsStr(nm)].join(", ") + "];\n");
				// Value-typed field defaults for Type.createEmptyInstance (cpp zero-initialises
				// Int/Float/Bool fields when the constructor is skipped; the cppia asserts those).
				var vd = valueDefaults(d);
				if (vd.length > 0)
					buf.add("SC[" + cn + "].__vdef = {" + vd.join(", ") + "};\n");
			}
		// Hand the script tables to the host so Type.*/Reflect.* over a script value are answered by
		// the script world, as the interpreter's typeReflect does.
		// Script-enum descriptors (constructor names/arities + __meta__), so the host can answer
		// resolveEnum/createEnum/getEnumConstructs/rtti-Meta for enums that exist only in this module.
		buf.add("var ED = {};
");
		for (d in tree.decls) {
			if (d.kind != "enum")
				continue;
			var en = types[d.ints[0]];
			var names = [for (c in d.enumCtors) jsStr(strings[c[0]])];
			var arities = [for (c in d.enumCtors) Std.string(c[1])];
			buf.add("ED[" + jsStr(en) + "] = {__ename: " + jsStr(en) + ", ctors: [" + names.join(", ") + "], arity: [" + arities.join(", ") + "]};
");
			if (d.enumMeta != null) {
				buf.add("ED[" + jsStr(en) + "].__meta__ = ");
				emitExpr(d.enumMeta);
				buf.add(";
");
			}
		}
		buf.add("$host.bindTables(SC, SS, SV, ED, $enum);
");
		// Pass 3: members (instance methods onto the prototype, statics into SS).
		for (d in tree.decls)
			emitClassMembers(d);
		// Pass 4: static var initializers, in declaration order (the interpreter's pendingStatics).
		for (d in tree.decls) {
			var cn = types[d.ints[0]];
			for (f in d.fields) {
				if (f.kind != "var" || f.ints[0] != 1 || f.ints[3] == 1)
					continue;
				var vn = strings[f.ints[4]];
				buf.add("SV[" + jsStr(cn + "." + vn) + "] = ");
				if (f.body != null) emitExpr(f.body) else buf.add("null");
				buf.add(";\n");
				// The inlined haxe.rtti.Meta accessors read __meta__ as a direct field off the
				// class token, so attach it to the constructor too.
				if (vn == "__meta__" && d.kind != "enum")
					buf.add("SC[" + jsStr(cn) + "].__meta__ = SV[" + jsStr(cn + ".__meta__") + "];
");
			}
		}
		// Class __init__ static initializers run after the static vars exist, before main - the
		// interpreter's initStatics/pendingInits ordering.
		for (d in tree.decls) {
			var cn = types[d.ints[0]];
			for (f in d.fields)
				if (f.kind == "function" && f.body != null && strings[f.ints[2]] == "__init__")
					buf.add("SS[" + jsStr(cn + ".__init__") + "]();\n");
		}
		if (tree.hasMain && tree.main != null) {
			buf.add("return function(){ ");
			emitExpr(tree.main);
			buf.add("; };\n");
		} else {
			buf.add("return function(){};\n");
		}
		buf.add("})");
		return buf.toString();
	}

	// The full interface set an instance of this class satisfies: direct interfaces, the super
	// chain's, and everything those interfaces extend - the interpreter's scriptClassImplements
	// BFS, computed once at lower time and emitted as prototype flags for $isType.
	function transitiveInterfaces(d:DeclNode):Array<String> {
		var byName:Map<String, DeclNode> = new Map();
		for (x in tree.decls)
			if (x.kind != "enum")
				byName.set(types[x.ints[0]], x);
		var seen:Map<String, Bool> = new Map();
		var out:Array<String> = [];
		function visit(x:Null<DeclNode>, isIface:Bool):Void {
			if (x == null)
				return;
			var name = types[x.ints[0]];
			if (isIface && !seen.exists(name)) {
				seen.set(name, true);
				out.push(name);
			}
			var nIfaces = x.ints[2];
			for (k in 0...nIfaces) {
				var idn = x.ints[3 + k];
				if (idn >= 0 && idn < types.length && !seen.exists(types[idn]))
					visit(byName.get(types[idn]), true);
			}
			var superId = x.ints[1];
			if (superId >= 0 && superId < types.length)
				visit(byName.get(types[superId]), isIface);
		}
		visit(d, false);
		return out;
	}

	// Type.getInstanceFields for a script class, mirroring the interpreter's
	// ScriptClass.instanceFields(): the super chain first, then this class; per class its instance
	// vars (extern property vars dropped - VAR ints [static, read, write, extern, name, ...]) then
	// its methods; deduplicated.
	function instanceFieldList(d:DeclNode):Array<String> {
		var byName:Map<String, DeclNode> = new Map();
		for (x in tree.decls)
			if (x.kind != "enum")
				byName.set(types[x.ints[0]], x);
		var chain:Array<DeclNode> = [];
		var c:Null<DeclNode> = d;
		while (c != null) {
			chain.unshift(c);
			var superId = c.ints[1];
			c = (superId >= 0 && superId < types.length) ? byName.get(types[superId]) : null;
		}
		var out:Array<String> = [];
		for (k in chain) {
			for (f in k.fields) {
				if (f.kind != "var" || f.ints[0] == 1 || f.ints[3] == 1)
					continue;
				var nm = strings[f.ints[4]];
				if (out.indexOf(nm) < 0)
					out.push(nm);
			}
			for (f in k.fields) {
				if (f.kind != "function" || f.ints[0] == 1 || f.body == null)
					continue;
				var nm = strings[f.ints[2]];
				if (nm != "new" && out.indexOf(nm) < 0)
					out.push(nm);
			}
		}
		return out;
	}

	// Zero defaults for value-typed instance vars down the super chain (the cppia type name is the
	// native lowercase form: "int"/"float"/"bool"), for Type.createEmptyInstance.
	function valueDefaults(d:DeclNode):Array<String> {
		var byName:Map<String, DeclNode> = new Map();
		for (x in tree.decls)
			if (x.kind != "enum")
				byName.set(types[x.ints[0]], x);
		var out:Array<String> = [];
		var seen:Map<String, Bool> = new Map();
		var c:Null<DeclNode> = d;
		while (c != null) {
			for (f in c.fields) {
				if (f.kind != "var" || f.ints[0] == 1 || f.ints[3] == 1)
					continue;
				var nm = strings[f.ints[4]];
				if (seen.exists(nm))
					continue;
				seen.set(nm, true);
				var tn = (f.ints[5] >= 0 && f.ints[5] < types.length) ? types[f.ints[5]] : "";
				var i = tn.lastIndexOf(":");
				if (i >= 0)
					tn = tn.substr(i + 1);
				switch (tn) {
					case "Int" | "UInt" | "Int64" | "Int32" | "int" | "int64" | "unsigned int": out.push(jsStr(nm) + ": 0");
					case "Float" | "Single" | "float" | "double": out.push(jsStr(nm) + ": 0");
					case "Bool" | "bool": out.push(jsStr(nm) + ": false");
					case _:
				}
			}
			var superId = c.ints[1];
			c = (superId >= 0 && superId < types.length) ? byName.get(types[superId]) : null;
		}
		return out;
	}

	function emitClassMembers(d:DeclNode):Void {
		var cn = types[d.ints[0]];
		for (f in d.fields) {
			if (f.kind != "function" || f.body == null)
				continue;
			var name = strings[f.ints[2]];
			// __init__'s body is a raw block, not a FUN node (the interpreter compiles it directly in
			// pendingInits), so wrap it in a zero-arg function here.
			if (name == "__init__") {
				buf.add("SS[" + jsStr(cn + ".__init__") + "] = function(){ ");
				emitStmt(f.body);
				buf.add("; };\n");
				continue;
			}
			// The constructor is emitted WITH the static flag but has a `this` body, so it must be
			// matched by name before the static test (same rule as the interpreter's index()).
			if (name == "new") {
				buf.add("SC[" + jsStr(cn) + "].prototype.__ctor = ");
			} else if (f.ints[0] == 1) {
				buf.add("SS[" + jsStr(cn + "." + name) + "] = ");
			} else {
				buf.add("SC[" + jsStr(cn) + "].prototype[" + jsStr(name) + "] = ");
			}
			emitFun(f.body);
			buf.add(";\n");
		}
	}

	// A FUN op: ints = [type, argc, then per arg: nameId, id, captured, type, marker]; kids are the
	// default-value exprs (for marker==1 args, in order) followed by the body block.
	function emitFun(fun:OpNode):Void {
		var argc = fun.ints[1];
		var argIds = [];
		var defaults = [];
		var idx = 2;
		for (i in 0...argc) {
			argIds.push(fun.ints[idx + 1]);
			defaults.push(fun.ints[idx + 4] == 1);
			idx += 5;
		}
		buf.add("function(");
		for (i in 0...argc) {
			if (i > 0) buf.add(",");
			buf.add("A" + i);
		}
		buf.add("){\n");
		// Bind args to their local slots, applying defaults for absent/null optional args.
		var defKid = 0;
		for (i in 0...argc) {
			buf.add("var L" + argIds[i] + " = A" + i + ";\n");
			if (defaults[i]) {
				buf.add("if (L" + argIds[i] + " == null) L" + argIds[i] + " = ");
				emitExpr(fun.kids[defKid++]);
				buf.add(";\n");
			}
		}
		// The body is the block after the default-value kids.
		var body = fun.kids[fun.kids.length - 1];
		emitStmt(body);
		buf.add("}");
	}

	// Emit a node in STATEMENT position (its value is discarded).
	function emitStmt(n:OpNode):Void {
		switch (n.op) {
			case "BLOCK", "TVARS":
				buf.add("{\n");
				for (k in n.kids) { emitStmt(k); buf.add(";\n"); }
				buf.add("}");
			case "VARDECL":
				buf.add("var L" + n.ints[1]);
			case "VARDECLI":
				buf.add("var L" + n.ints[1] + " = ");
				emitExpr(n.kids[0]);
			case "IF":
				buf.add("if (");
				emitExpr(n.kids[0]);
				buf.add(") ");
				emitStmt(n.kids[1]);
			case "IFELSE":
				buf.add("if (");
				emitExpr(n.kids[0]);
				buf.add(") ");
				emitStmt(n.kids[1]);
				buf.add(" else ");
				emitStmt(n.kids[2]);
			case "WHILE":
				// While ints[0] = normalWhile (1) vs do-while (0).
				if (n.ints[0] == 1) {
					buf.add("while (");
					emitExpr(n.kids[0]);
					buf.add(") ");
					emitStmt(n.kids[1]);
				} else {
					buf.add("do ");
					emitStmt(n.kids[1]);
					buf.add(" while (");
					emitExpr(n.kids[0]);
					buf.add(")");
				}
			case "BREAK":
				buf.add("break");
			case "CONTINUE":
				buf.add("continue");
			case "RETVAL":
				buf.add("return ");
				emitExpr(n.kids[0]);
			case "RETURN":
				buf.add("return");
			case "SWITCH":
				emitSwitchStmt(n);
			case "TRY":
				emitTry(n);
			case "THROW":
				buf.add("throw ");
				emitExpr(n.kids[0]);
			case _:
				// Any other node is an expression whose value is discarded.
				emitExpr(n);
		}
	}

	// Emit a node in EXPRESSION position (produces a JS value).
	function emitExpr(n:OpNode):Void {
		switch (n.op) {
			case "i": buf.add(Std.string(n.ints[0]));
			case "f": buf.add(strings[n.ints[0]]);
			case "s": buf.add(jsStr(strings[n.ints[0]]));
			case "true": buf.add("true");
			case "false": buf.add("false");
			case "NULL": buf.add("null");
			case "VAR": buf.add("L" + n.ints[0]);
			case "BLOCK":
				// A block in expression position: emit as a comma-expression yielding the last value.
				buf.add("(");
				for (i in 0...n.kids.length) {
					if (i > 0) buf.add(", ");
					emitExpr(n.kids[i]);
				}
				buf.add(")");
			case "SET":
				emitSet(n);
			case "+", "-", "*", "/", "%", "<", ">", "<=", ">=", "==", "!=", "&", "|", "^", "<<", ">>", "&&", "||":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" " + n.op + " ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case ">>>":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" >>> ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case "NEG":
				buf.add("(-");
				emitExpr(n.kids[0]);
				buf.add(")");
			case "!":
				buf.add("(!");
				emitExpr(n.kids[0]);
				buf.add(")");
			case "~":
				buf.add("(~");
				emitExpr(n.kids[0]);
				buf.add(")");
			case "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", ">>=", ">>>=", "<<=":
				emitModify(n);
			case "++", "+++", "--", "---":
				emitCrement(n);
			case "ADEF":
				buf.add("[");
				for (i in 0...n.kids.length) {
					if (i > 0) buf.add(", ");
					emitExpr(n.kids[i]);
				}
				buf.add("]");
			case "ARRAYI":
				emitExpr(n.kids[0]);
				buf.add("[");
				emitExpr(n.kids[1]);
				buf.add("]");
			case "CALLSTATIC":
				emitCallStatic(n);
			case "THIS":
				buf.add("this");
			case "CLASSOF":
				// A class referenced as a value: the script constructor function, else a host token.
				buf.add("$classof(" + jsStr(types[n.ints[0]]) + ")");
			case "POSINFO":
				// The auto-filled haxe.PosInfos for a `?pos` argument.
				buf.add("{fileName:" + jsStr(strings[n.ints[0]]) + ", lineNumber:" + n.ints[1]
					+ ", className:" + jsStr(strings[n.ints[2]]) + ", methodName:" + jsStr(strings[n.ints[3]]) + "}");
			case "OBJDEF":
				// An anonymous object literal: ints[0] = field count, then the name ids; kids are values.
				var count = n.ints[0];
				buf.add("{");
				for (i in 0...count) {
					if (i > 0) buf.add(", ");
					buf.add(jsStr(strings[n.ints[1 + i]]) + ": ");
					emitExpr(n.kids[i]);
				}
				buf.add("}");
			case "NEW":
				buf.add("$new(" + jsStr(types[n.ints[0]]) + ", ");
				emitArgArray(n.kids, 0);
				buf.add(")");
			case "FLINK", "FNAME":
				buf.add("$fld(");
				emitExpr(n.kids[0]);
				buf.add(", " + jsStr(strings[n.ints[1]]) + ")");
			case "FTHISINST", "FTHISNAME":
				buf.add("$fld(this, " + jsStr(strings[n.ints[1]]) + ")");
			case "FSTATIC":
				var t = types[n.ints[0]], m = strings[n.ints[1]];
				// A neutral-static type's statics live on the host (haxe.Serializer.USE_CACHE must reach the
				// real class the shim reads), never in the module's SV.
				if (isNeutralStatic(t)) {
					buf.add("$host.getStatic(" + jsStr(t) + ", " + jsStr(m) + ")");
					return;
				}
				buf.add("$gs(" + jsStr(t + "." + m) + ", " + jsStr(t) + ", " + jsStr(m) + ")");
			case "CREATEENUM":
				emitEnumCtor(n, n.kids, false);
			case "FENUM":
				emitEnumCtor(n, [], true);
			case "ENUMI":
				// Extract constructor parameter ints[1] from an enum value.
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(").__p[" + n.ints[1] + "]");
			case "CALLMEMBER":
				// Gencpp emits the enum runtime index as CALLMEMBER ::hx::EnumBase.__Index; on our enum
				// representation that is the stored index, not a method.
				if (strings[n.ints[1]] == "__Index") {
					buf.add("(");
					emitExpr(n.kids[0]);
					buf.add(").__i");
					return;
				}
				buf.add("$mem(");
				emitExpr(n.kids[0]);
				buf.add(", " + jsStr(strings[n.ints[1]]) + ", ");
				emitArgArray(n.kids, 1);
				buf.add(")");
			case "CALLTHIS":
				buf.add("$mem(this, " + jsStr(strings[n.ints[1]]) + ", ");
				emitArgArray(n.kids, 0);
				buf.add(")");
			case "CALLSUPER":
				// Non-virtual call to a named super method: reach it off the super prototype.
				buf.add("SC[" + jsStr(types[n.ints[0]]) + "].prototype[" + jsStr(strings[n.ints[1]])
					+ "].apply(this, ");
				emitArgArray(n.kids, 0);
				buf.add(")");
			case "CALLSUPERNEW":
				buf.add("SC[" + jsStr(types[n.ints[0]]) + "].prototype.__ctor.apply(this, ");
				emitArgArray(n.kids, 0);
				buf.add(")");
			case "CALL":
				emitExpr(n.kids[0]);
				buf.add("(");
				for (i in 1...n.kids.length) {
					if (i > 1) buf.add(", ");
					emitExpr(n.kids[i]);
				}
				buf.add(")");
			case "FUN":
				emitFun(n);
			case "IFELSE":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" ? ");
				emitExpr(n.kids[1]);
				buf.add(" : ");
				emitExpr(n.kids[2]);
				buf.add(")");
			case "ISNULL":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" == null)");
			case "NOTNULL":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" != null)");
			case "CAST", "CASTINT", "CASTBOOL", "TOINTERFACE", "TOINTERFACEARRAY", "TODATAARRAY", "TODYNARRAY":
				// Identity coercions on a dynamic heap.
				emitExpr(n.kids[0]);
			case "TCAST":
				// A checked `cast(e, T)`: throws on a script instance that is not of the target script
				// type, like the interpreter's checkedCast; everything else passes through.
				buf.add("$tcast(");
				emitExpr(n.kids[0]);
				buf.add(", " + jsStr(types[n.ints[0]]) + ")");
			case _:
				throw new LowerError("op '" + n.op + "' not lowered yet");
		}
	}

	function emitSet(n:OpNode):Void {
		var lv = n.kids[0];
		switch (lv.op) {
			case "VAR":
				buf.add("(L" + lv.ints[0] + " = ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case "ARRAYI":
				// A store the cppia inlined from Bytes.set is `<recv>.b[i] = v`; $bset masks it to
				// 0..255 when the receiver is a byte buffer (the interpreter's ARRAYI-store rule).
				var ak = lv.kids[0];
				if ((ak.op == "FLINK" || ak.op == "FNAME") && strings[ak.ints[1]] == "b") {
					buf.add("$bset(");
					emitExpr(ak.kids[0]);
					buf.add(", ");
					emitExpr(lv.kids[1]);
					buf.add(", ");
					emitExpr(n.kids[1]);
					buf.add(")");
					return;
				}
				buf.add("(");
				emitExpr(lv.kids[0]);
				buf.add("[");
				emitExpr(lv.kids[1]);
				buf.add("] = ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case "FLINK", "FNAME":
				buf.add("(");
				emitExpr(lv.kids[0]);
				buf.add("[" + jsStr(strings[lv.ints[1]]) + "] = ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case "FTHISINST", "FTHISNAME":
				buf.add("(this[" + jsStr(strings[lv.ints[1]]) + "] = ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case "FSTATIC":
				var st = types[lv.ints[0]];
				if (isNeutralStatic(st)) {
					buf.add("$host.setStatic(" + jsStr(st) + ", " + jsStr(strings[lv.ints[1]]) + ", ");
					emitExpr(n.kids[1]);
					buf.add(")");
					return;
				}
				buf.add("(SV[" + jsStr(st + "." + strings[lv.ints[1]]) + "] = ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case _:
				throw new LowerError("SET lvalue '" + lv.op + "' not lowered yet");
		}
	}

	// SWITCH ints=[caseCount, hasDefault, then nValues per case]; kids=[cond, per case: values...,
	// body, then the default body]. Lowered as an if/else chain rather than a JS `switch`, because
	// Haxe compares case values with `==` (JS `switch` uses `===`) and the values are expressions,
	// not constants. An if/else chain also keeps return/break/continue in the enclosing function.
	function emitSwitchStmt(n:OpNode):Void {
		var caseCount = n.ints[0];
		var hasDefault = n.ints[1] == 1;
		var tmp = "$s" + (switchDepth++);
		buf.add("{ var " + tmp + " = ");
		emitExpr(n.kids[0]);
		buf.add(";\n");
		var ki = 1;
		for (ci in 0...caseCount) {
			var nv = n.ints[2 + ci];
			buf.add(ci == 0 ? "if (" : "else if (");
			for (vi in 0...nv) {
				if (vi > 0) buf.add(" || ");
				buf.add(tmp + " == ");
				emitExpr(n.kids[ki++]);
			}
			buf.add(") ");
			emitBlockStmt(n.kids[ki++]);
			buf.add("\n");
		}
		if (hasDefault) {
			buf.add(caseCount == 0 ? "" : "else ");
			emitBlockStmt(n.kids[ki++]);
			buf.add("\n");
		}
		buf.add("}");
		switchDepth--;
	}

	// TRY ints=[count, then per catch: nameId, id, captured, type]; kids=[block, catch bodies].
	// The catch clauses are tested in order against the thrown value ($isType), matching the
	// interpreter's dispatchCatch; an unmatched value is rethrown so an outer try sees it. The
	// ValueException wrapping the interpreter does for a value caught as Exception is a later slice.
	function emitTry(n:OpNode):Void {
		var count = n.ints[0];
		var ev = "$e" + (switchDepth++);
		buf.add("try ");
		emitBlockStmt(n.kids[0]);
		buf.add("\ncatch (" + ev + ") {\n");
		for (ci in 0...count) {
			var vId = n.ints[1 + ci * 4 + 1];
			var typeId = n.ints[1 + ci * 4 + 3];
			var type = (typeId >= 0 && typeId < types.length) ? types[typeId] : "Dynamic";
			buf.add(ci == 0 ? "if (" : "else if (");
			buf.add("$isType(" + ev + ", " + jsStr(type) + ")) { var L" + vId + " = " + ev + ";\n");
			emitStmt(n.kids[1 + ci]);
			buf.add(";\n}\n");
		}
		buf.add(count == 0 ? "throw " + ev + ";\n" : "else throw " + ev + ";\n");
		buf.add("}");
		switchDepth--;
	}

	// Emit a node as a statement, always brace-wrapped so it is a valid if/else or try branch.
	function emitBlockStmt(n:OpNode):Void {
		if (n.op == "BLOCK" || n.op == "TVARS") {
			emitStmt(n);
		} else {
			buf.add("{ ");
			emitStmt(n);
			buf.add("; }");
		}
	}

	// CREATEENUM/FENUM: ints[0] = enum type, ints[1] = constructor name; kids are the arguments
	// (FENUM has none). A host enum is not lowered yet - the script enum table is authoritative here.
	function emitEnumCtor(n:OpNode, args:Array<OpNode>, isRef:Bool):Void {
		var et = types[n.ints[0]];
		var ctor = strings[n.ints[1]];
		var idx = enumCtorIndex.get(et + "." + ctor);
		if (idx == null) {
			// A host enum (haxe.ds.Option, ValueType, ...): the host builds the same wrapper
			// shape, mirroring the interpreter's mkHostEnum.
			buf.add("$host.hostEnum(" + jsStr(et) + ", " + jsStr(ctor) + ", ");
			emitArgArray(args, 0);
			buf.add(")");
			return;
		}
		// A parametric constructor REFERENCED as a value (`var c = MyEnum.C`) is a factory function,
		// not the enum value; a no-arg constructor is the constant itself (the interpreter's FENUM).
		if (isRef && enumCtorArity.get(et + "." + ctor) > 0) {
			buf.add("function(){ return $enum(" + jsStr(et) + ", " + idx + ", " + jsStr(ctor)
				+ ", Array.prototype.slice.call(arguments)); }");
			return;
		}
		buf.add("$enum(" + jsStr(et) + ", " + idx + ", " + jsStr(ctor) + ", ");
		emitArgArray(args, 0);
		buf.add(")");
	}

	// Emit `[a, b, c]` from kids starting at `from` (the argument list of a call op).
	function emitArgArray(kids:Array<OpNode>, from:Int):Void {
		buf.add("[");
		for (i in from...kids.length) {
			if (i > from) buf.add(", ");
			emitExpr(kids[i]);
		}
		buf.add("]");
	}

	function emitModify(n:OpNode):Void {
		var t = lvalueText(n.kids[0]);
		if (t == null) {
			// A side-effecting receiver/index must be evaluated once: hoist both into an IIFE's parameters,
			// then apply the operator to the single evaluation.
			var parts = indexedParts(n.kids[0]);
			if (parts == null)
				throw new LowerError("modify lvalue '" + n.kids[0].op + "' not lowered yet");
			buf.add("(function($o,$k,$v){ return $o[$k] " + n.op + " $v; })(");
			buf.add(parts.recv + ", " + parts.key + ", ");
			emitExpr(n.kids[1]);
			buf.add(")");
			return;
		}
		buf.add("(" + t + " " + n.op + " ");
		emitExpr(n.kids[1]);
		buf.add(")");
	}

	function emitCrement(n:OpNode):Void {
		// The THREE-character ops are the POST forms and the two-character ops are PRE - the same
		// rule the interpreter uses (`post = n.op.length == 3`). Getting this backwards silently
		// off-by-ones every `p++` used for its value, e.g. JsonParser's fastCodeAt(str, pos++).
		var v = lvalueText(n.kids[0]);
		if (v == null) {
			var parts = indexedParts(n.kids[0]);
			if (parts == null)
				throw new LowerError("crement lvalue '" + n.kids[0].op + "' not lowered yet");
			var delta = (n.op == "++" || n.op == "+++") ? "+ 1" : "- 1";
			var post = n.op.length == 3;
			buf.add("(function($o,$k){ var $x = $o[$k]; $o[$k] = $x " + delta + "; return "
				+ (post ? "$x" : "$o[$k]") + "; })(" + parts.recv + ", " + parts.key + ")");
			return;
		}
		switch (n.op) {
			case "++": buf.add("(++" + v + ")");
			case "--": buf.add("(--" + v + ")");
			case "+++": buf.add("(" + v + "++)");
			case "---": buf.add("(" + v + "--)");
			case _: throw new LowerError("crement '" + n.op + "'");
		}
	}

	// JS lvalue text for a compound assignment / increment. Returns null when re-evaluating the
	// receiver would be unsafe (a side-effecting receiver must not run twice), so the caller reports
	// an honest LowerError instead of emitting wrong code.
	function lvalueText(lv:OpNode):Null<String> {
		return switch (lv.op) {
			case "VAR": "L" + lv.ints[0];
			case "FSTATIC": "SV[" + jsStr(types[lv.ints[0]] + "." + strings[lv.ints[1]]) + "]";
			case "FTHISINST", "FTHISNAME": "this[" + jsStr(strings[lv.ints[1]]) + "]";
			case "FLINK", "FNAME" if (isPure(lv.kids[0])):
				render(lv.kids[0]) + "[" + jsStr(strings[lv.ints[1]]) + "]";
			case "ARRAYI" if (isPure(lv.kids[0]) && isPure(lv.kids[1])):
				render(lv.kids[0]) + "[" + render(lv.kids[1]) + "]";
			case _: null;
		};
	}

	// Split an indexed lvalue into its receiver and key expressions, for the single-evaluation IIFE
	// form used when either part has a side effect. Returns null for a shape with no key.
	function indexedParts(lv:OpNode):Null<{recv:String, key:String}> {
		return switch (lv.op) {
			case "ARRAYI": {recv: render(lv.kids[0]), key: render(lv.kids[1])};
			case "FLINK", "FNAME": {recv: render(lv.kids[0]), key: jsStr(strings[lv.ints[1]])};
			case _: null;
		};
	}

	// A node whose evaluation has no side effect, so it may be emitted twice.
	static function isPure(n:OpNode):Bool {
		return switch (n.op) {
			case "VAR", "THIS", "i", "s", "f", "true", "false", "NULL": true;
			case _: false;
		};
	}

	// Render a node to JS text without disturbing the main buffer.
	function render(n:OpNode):String {
		var save = buf;
		buf = new StringBuf();
		emitExpr(n);
		var out = buf.toString();
		buf = save;
		return out;
	}

	function emitCallStatic(n:OpNode):Void {
		var typeName = types[n.ints[0]];
		var member = strings[n.ints[1]];
		var key = typeName + "." + member;
		// `x is T` is Std.isOfType(x, CLASSOF T). Resolve it against the compile-time type name, as
		// the interpreter does: a primitive (Int/Float/Bool) has no runtime Class on js, so passing a
		// CLASSOF token to the host would compare against nothing.
		if (key == "Std.isOfType" && n.kids.length == 2 && n.kids[1].op == "CLASSOF") {
			buf.add("$isType(");
			emitExpr(n.kids[0]);
			buf.add(", " + jsStr(types[n.kids[1].ints[0]]) + ")");
			return;
		}
		if (scriptStatics.exists(key)) {
			buf.add("SS[" + jsStr(key) + "](");
			for (i in 0...n.kids.length) {
				if (i > 0) buf.add(", ");
				emitExpr(n.kids[i]);
			}
			buf.add(")");
		} else {
			// Host static: dispatch through the registry seam.
			buf.add("$host.callStatic(" + jsStr(typeName) + ", " + jsStr(member) + ", [");
			for (i in 0...n.kids.length) {
				if (i > 0) buf.add(", ");
				emitExpr(n.kids[i]);
			}
			buf.add("])");
		}
	}

	// A JS string literal for an arbitrary Haxe string (JSON string encoding is valid JS).
	static function jsStr(s:String):String
		return haxe.Json.stringify(s);
}
