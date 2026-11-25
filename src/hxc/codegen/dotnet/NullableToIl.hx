package hxc.codegen.dotnet;

import haxe.Int64;
import haxe.ds.ObjectMap;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.AttributesToIl.AttrCtor;
import hxc.codegen.dotnet.AttributesToIl.AttrType;
import hxc.codegen.dotnet.AttributesToIl.AttrValue;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.HxGen;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.TclassToIl;

// A method's nullable metadata: its own context (null when nothing in its signature has one byte), the
// context its parameters are read in, and the bytes of its return type and parameters.
private typedef MethodNullable = {local:Null<Int>, ctx:Int, ret:Array<Int>, args:Array<Array<Int>>};

// A type's: its own context and the one its members are read in, and the bytes of its base type and of
// each interface it implements, by the interface's signature.
private typedef TypeNullable = {local:Null<Int>, ctx:Int, base:Null<Array<Int>>, interfaces:Array<{sig:IlSigNorm, bytes:Array<Int>}>};

// The nullable metadata of the types -D dotnet-nullable=<package>[,<package>...] enables: every type of a
// module whose package is exactly one of those named, its local functions' classes included, as the server
// app's build enables gencs's C# with `#nullable enable` before `namespace <package> {` (a sub-package's
// modules are not enabled). The rows are Roslyn's (its docs/features/nullable-metadata.md):
// - A type reference is a byte array, in pre-order: a reference type is its nullability then its type
//   arguments; System.Nullable<T> is T's; a generic value type is 0 then its arguments, another value type
//   nothing; an array (and a pointer, 0) its own byte then its element's; a type parameter reference its
//   nullability. Haxe has no `string?`: gencs writes every reference type as not null, 1, so a byte is 1
//   for a reference type and 0 for a generic struct, haxe.lang.Null<int> among them.
// - A type's NullableContext is the most common byte among its base type and interfaces (both oblivious at
//   the top, 0), its type parameters (2), and its members: each field's and property's type and each
//   method's own context, where a type's byte array counts only when all its bytes are equal. Ties go to 0,
//   then 1, then 2. A method's context is the same over its type parameters, return type and parameters.
//   Each is written only where it differs from the enclosing one (0 for a type), and a Nullable attribute
//   (one byte when all are equal, else the array) only where its bytes are not all the context.
// - The base type has its Nullable attribute too: Nullable(0) for object in a context of 1.
// Roslyn writes these rows before the others of their parent. The attribute types are System.Runtime's,
// whatever else defines them (AttributesToIl.runtimeAttr).
class NullableToIl {
	final packages:Map<String, Bool>;
	final types = new ObjectMap<ClassPlan, TypeNullable>();
	final methods = new ObjectMap<MethodPlan, MethodNullable>();
	// The bytes of each generic parameter's attribute, by owner token and number, for genericParam.
	final generics = new Map<String, Int>();
	var nullable1:Null<AttrCtor> = null;
	var nullableN:Null<AttrCtor> = null;
	var context:Null<AttrCtor> = null;

	public function new(packages:Array<String>) {
		this.packages = [for (p in packages) p => true];
	}

	// The packages a -D dotnet-nullable value names, or null when it is not a comma-separated list of
	// package paths.
	public static function parsePackages(s:String):Null<Array<String>> {
		var r = [];
		for (p in s.split(",")) {
			p = StringTools.trim(p);
			for (part in p.split("."))
				if (!~/^[a-z_][A-Za-z0-9_]*$/.match(part)) return null;
			r.push(p);
		}
		return r;
	}

	// Whether the class `c` is in a module of a package -D dotnet-nullable names.
	public static function enabled(g:DotnetCtx, c:TClass):Bool {
		return g.nullable != null && g.nullable.moduleEnabled(c.module);
	}

	function moduleEnabled(m:Null<ModuleDef>):Bool {
		return m != null && packages.exists(m.path.pack.join("."));
	}

	// The module of the Haxe type a plan belongs to: its class, or the enum or class whose class it is.
	static function moduleOf(g:DotnetCtx, plan:ClassPlan):Null<ModuleDef> {
		if (plan.c != null) return plan.c.module;
		for (ep in g.enumPlans) if (ep.base == plan || ep.ctors.indexOf(plan) >= 0) return ep.e.module;
		for (c in g.companionPlans.keys()) if (g.companionPlans.get(c) == plan) return c.module;
		for (c in g.staticsPlans.keys()) if (g.staticsPlans.get(c) == plan) return c.module;
		return null;
	}

	// Works out an enabled type's metadata before its rows are written, as a method's return value needs
	// a Param row of its own (returnRow).
	public static function prepare(g:DotnetCtx, plan:ClassPlan):Void {
		var n = g.nullable;
		if (n != null && n.moduleEnabled(moduleOf(g, plan))) n.planType(g, plan);
	}

	// Whether the method needs a Param row for its return value's attribute.
	public static function returnRow(g:DotnetCtx, m:MethodPlan):Bool {
		if (g.nullable == null) return false;
		var mn = g.nullable.methods.get(m);
		return mn != null && attribute(mn.ret, mn.ctx) != null;
	}

	// The attribute of an InterfaceImpl row (`token`) of an enabled type, for its interface `sig`.
	public static function interfaceImpl(g:DotnetCtx, plan:ClassPlan, sig:IlSigNorm, token:Int):Void {
		var tn = g.nullable == null ? null : g.nullable.types.get(plan);
		if (tn == null) return;
		for (i in tn.interfaces) if (IlPaths.sigEq(i.sig, sig)) {
			g.nullable.put(g, token, attribute(i.bytes, tn.ctx));
			return;
		}
	}

	// The rows of an enabled type and its members, once their rows exist.
	public static function write(g:DotnetCtx, plan:ClassPlan):Void {
		var n = g.nullable;
		var tn = n == null ? null : n.types.get(plan);
		if (tn == null) return;
		if (tn.local != null && tn.local != 0) AttributesToIl.write(g, plan.token, n.contextCtor(g), [AInt(ATU1, Int64.ofInt(tn.local))], [], true);
		if (tn.base != null) n.put(g, plan.token, attribute(tn.base, tn.ctx));
		for (i in 0...plan.classParams.length) n.pending(plan.token, i, attribute([2], tn.ctx));
		for (f in plan.fields) n.put(g, f.token, attribute(bytes(f.sig), tn.ctx));
		for (m in plan.methods) {
			var mn = n.methods.get(m);
			if (mn.local != null && mn.local != tn.ctx)
				AttributesToIl.write(g, m.token, n.contextCtor(g), [AInt(ATU1, Int64.ofInt(mn.local))], [], true);
			var ret = attribute(mn.ret, mn.ctx);
			if (ret != null) n.put(g, g.mb.paramToken(m.token, -1), ret);
			// Every plan names each of its arguments, so each has its Param row (its bytes are counted for the context).
			if (mn.args.length != m.argNames.length) throw "internal error: " + plan.hxPath + "." + m.name + " has " + mn.args.length + " arguments and " + m.argNames.length + " names";
			for (i in 0...mn.args.length) n.put(g, g.mb.paramToken(m.token, i), attribute(mn.args[i], mn.ctx));
			for (i in 0...m.generics.length) n.pending(m.token, i, attribute([2], mn.ctx));
		}
		for (p in plan.properties) n.put(g, p.token, attribute(bytes(p.sig), tn.ctx));
		// An event's Nullable attribute, which its type's context does not count (planType): Roslyn's tally takes a
		// field-like event's backing field and its accessors' parameters, not the event itself.
		for (e in plan.events) n.put(g, e.token, attribute(bytes(e.sig), tn.ctx));
	}

	// The attribute of a GenericParam row (`token`), the type or method `owner`'s parameter `number`.
	public static function genericParam(g:DotnetCtx, owner:Int, number:Int, token:Int):Void {
		var n = g.nullable;
		if (n == null) return;
		var b = n.generics.get(owner + ":" + number);
		if (b != null) n.put(g, token, [b]);
	}

	function pending(owner:Int, number:Int, a:Null<Array<Int>>):Void {
		if (a == null) generics.remove(owner + ":" + number) else generics.set(owner + ":" + number, a[0]);
	}

	function planType(g:DotnetCtx, plan:ClassPlan):Void {
		var counts = new Counts();
		var base = null;
		if (plan.flags & TypeAttrs.INTERFACE == 0) {
			base = oblivious(plan.superSig == null ? LObject : plan.superSig);
			counts.add(common(base));
		}
		var interfaces = [for (s in plan.interfaces) {sig: s, bytes: oblivious(s)}];
		for (i in interfaces) counts.add(common(i.bytes));
		// gencs writes the `where` clauses of a @:nativeGen class outside its class model, and drops the others.
		// The classes of local functions are outside it in hxc's model, but gencs writes them no `where` clause
		// (closuresToClass copies the parameters, not their constraints).
		var constrained = plan.c != null && TypeFunctions.hasMeta(":nativeGen", plan.c.meta) && !HxGen.isHxGen(TClassDecl(plan.c))
			&& !g.closureOwners.exists(plan.c);
		if (constrained) checkParams(g, plan.c.params, plan.hxPath, plan.c.pos);
		for (_ in plan.classParams) counts.add(2);
		for (f in plan.fields) counts.add(common(bytes(f.sig)));
		var planned = [];
		var checkedFields = [];
		for (m in plan.methods) {
			switch (m.kind) {
				// Once per field, though its optional-argument overloads and bridges are plans too.
				case MField(cf) | MOptionalOverload(cf, _) | MBridge(cf) if (constrained && checkedFields.indexOf(cf) < 0): checkedFields.push(cf); checkParams(g, cf.params, plan.hxPath + "." + cf.name, cf.pos);
				case _:
			}
			var mc = new Counts();
			for (_ in m.generics) mc.add(2);
			var ret = bytes(m.ret);
			mc.add(common(ret));
			var args = [for (a in m.args) bytes(a)];
			for (a in args) mc.add(common(a));
			var mn = {local: mc.most(), ctx: 0, ret: ret, args: args};
			counts.add(mn.local);
			planned.push({m: m, mn: mn});
		}
		for (p in plan.properties) counts.add(common(bytes(p.sig)));
		var local = counts.most();
		var ctx = local == null ? 0 : local;
		for (x in planned) {
			x.mn.ctx = x.mn.local == null ? ctx : x.mn.local;
			methods.set(x.m, x.mn);
		}
		types.set(plan, {local: local, ctx: ctx, base: base, interfaces: interfaces});
	}

	// gencs writes a constrained type parameter's `where` clause, which changes its byte, and hxc writes no
	// constraints (GenericParamConstraint rows): refused rather than guessed. A String constraint has no
	// `where` clause in C#, as for ExternMembers.constrainedParam.
	function checkParams(g:DotnetCtx, params:TypeParams, what:String, pos:hxc.ast.Position):Void {
		for (p in params) switch (TypeFunctions.follow(p.type)) {
			case TInst(c, _):
				switch (c.kind) {
					case KTypeParameter(tl) if (Lambda.exists(tl, x -> !TypeFunctions.follow(x).match(TInst({path: {pack: [], name: "String"}}, [])))):
						g.error("hxc cannot write the nullable metadata (-D dotnet-nullable) of " + what + ": its type parameter " + p.name
							+ " is constrained, and hxc writes no constraints", pos);
					case _:
				}
			case _:
		}
	}

	// A type's bytes, in pre-order.
	static function bytes(s:IlSigNorm):Array<Int> {
		var out = [];
		function add(s:IlSigNorm) switch (s) {
			case LString | LObject | LTypeParam(_) | LMethodTypeParam(_):
				out.push(1);
			case LClass(_, args):
				out.push(1);
				for (a in args) add(a);
			case LValueType(p, [a]) if (p.ns.join(".") == "System" && p.nested.length == 0 && p.name == "Nullable`1"):
				add(a);
			case LValueType(_, args) if (args.length > 0):
				out.push(0);
				for (a in args) add(a);
			case LVector(e) | LArray(e, _):
				out.push(1);
				add(e);
			case LPointer(e):
				out.push(0);
				add(e);
			// A ref or out parameter's type is its element's.
			case LManagedPointer(e):
				add(e);
			case LMethod(_, _, _):
				throw "internal error: nullable metadata for a function pointer type";
			case _:
		}
		add(s);
		return out;
	}

	// A base type's or interface's bytes: oblivious at the top, as Roslyn writes them.
	static function oblivious(s:IlSigNorm):Array<Int> {
		var b = bytes(s);
		if (b.length > 0) b[0] = 0;
		return b;
	}

	// The byte all of `b` is, or null when they differ or there are none.
	static function common(b:Array<Int>):Null<Int> {
		if (b.length == 0) return null;
		for (x in b) if (x != b[0]) return null;
		return b[0];
	}

	// The Nullable attribute `b` needs in context `ctx`: none when it is empty or all `ctx`, one byte when its
	// bytes are equal, else all of them.
	static function attribute(b:Array<Int>, ctx:Int):Null<Array<Int>> {
		if (b.length == 0) return null;
		var c = common(b);
		if (c == null) return b;
		return c == ctx ? null : [c];
	}

	function put(g:DotnetCtx, owner:Int, a:Null<Array<Int>>):Void {
		if (a == null) return;
		if (a.length == 1) {
			if (nullable1 == null) nullable1 = AttributesToIl.runtimeAttr(g, "System.Runtime.CompilerServices", "NullableAttribute", [ATU1]);
			AttributesToIl.write(g, owner, nullable1, [AInt(ATU1, Int64.ofInt(a[0]))], [], true);
		} else {
			if (nullableN == null)
				nullableN = AttributesToIl.runtimeAttr(g, "System.Runtime.CompilerServices", "NullableAttribute", [ATArray(ATU1)]);
			AttributesToIl.write(g, owner, nullableN, [AArray(ATU1, [for (x in a) AInt(ATU1, Int64.ofInt(x))])], [], true);
		}
	}

	function contextCtor(g:DotnetCtx):AttrCtor {
		if (context == null) context = AttributesToIl.runtimeAttr(g, "System.Runtime.CompilerServices", "NullableContextAttribute", [ATU1]);
		return context;
	}
}

// Roslyn's MostCommonNullableValueBuilder: how often each byte is a member's, the most common winning, a tie
// going to 0, then 1, then 2; null when nothing was counted.
private class Counts {
	final n = [0, 0, 0];

	public function new() {}

	public function add(b:Null<Int>):Void {
		if (b != null) n[b]++;
	}

	public function most():Null<Int> {
		var max = n[0], value = 0;
		if (n[1] > max) {
			max = n[1];
			value = 1;
		}
		if (n[2] > max) return 2;
		return max == 0 ? null : value;
	}
}
