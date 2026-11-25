package hxc.codegen.dotnet;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.AttributesToIl.AttrValue;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.TclassToIl;

// What the body of one of the cast members does.
enum CastBody {
	// The static `__hx_cast<T_c_c…>(X me)`: `me.X_cast<T_c_c…>()` when `me` is not null, else null.
	CHelper(c:TClass);
	// The class's own `X_cast<T_c…>()`.
	COwn;
	// A parent cast of an hxgeneric class: `this.X_cast<b1..bn>()`, `args` the bk.
	CParent(args:Array<IlSigNorm>);
	// A parent cast of a class that is not hxgeneric: `this`.
	CThis;
}

// A generic interface or superclass a class has a parent cast for, its type arguments in terms of the
// class's type parameters.
private typedef Parent = {c:TClass, params:Array<T>};

// gencs's companion interfaces and cast members (realTypeParams.ml; types notes §3, §4). An hxgeneric
// class or interface `pack.X<T…>` gets the companion interface `pack.X`, which every instantiation
// implements: `[haxe.lang.GenericInterface(typeof(X<object…>))]`, extending haxe.lang.IHxObject, the
// companions of its generic superclasses and haxe.lang.IGenericObject. It declares `object X_cast<T_c…>()`,
// the casts of the generic interfaces the class implements that its superclass's companion lacks, its
// superclass's cast again, then every non-static, non-dynamic method the class declares (not an override)
// whose Haxe type mentions no type parameter. A generic interface keeps only the methods that mention
// one; the others are its companion's, and its `__hx_cast` lives in `pack.X__Statics_`.
//
// The class gets, after its constructors, the static `__hx_cast<T_c_c…>(X me)`, its own `X_cast`, which
// returns `this` when every type argument is the one asked for and otherwise copies the object field by
// field into a new instantiation (Array's goes on in hxc's runtime Array.hx, which carries Haxe issue
// 8314's forward), and a parent cast for every generic interface (deep) and generic
// superclass. A parent cast's body is types §4's: `this.X_cast<b1..bn>()`, each `bk` the first parent
// parameter whose argument is the class's k-th parameter, else that parameter itself (gencs passes the
// class's own parameters, so its parent casts return `this`; decision 2 of plan 3c). A class that is not
// hxgeneric gets `return this` for each generic interface its superclass has no cast for.
class CompanionToIl {
	// Whether gencs gives `c` a companion interface: an hxgeneric class or interface, not a local
	// function's class (gencs makes those after its generic analysis). Nor a struct: gencs gives a generic
	// struct implementing an hxgen interface a companion and an X_cast that `new`s it from an EmptyObject,
	// with `struct Cell<T> : haxe.lang.HxObject`, which C# does not compile; hxc's struct, which extends
	// no HxObject, gets the `return this` casts of a class that is not hxgeneric instead.
	public static function hasCompanion(g:DotnetCtx, c:TClass):Bool {
		return !TypeFunctions.hasClassFlag(c, CExtern) && !TypeFunctions.hasMeta(":struct", c.meta) && !g.closureOwners.exists(c)
			&& HxGeneric.isHxGeneric(g, c);
	}

	// The companion's CLR path: the class's own, without the arity.
	public static function companionPath(c:TClass):IlPath {
		var p = DotnetNames.typePath(TClassDecl(c));
		var tick = p.name.indexOf("`");
		return {ns: p.ns, nested: [], name: tick < 0 ? p.name : p.name.substr(0, tick)};
	}

	public static function companionSig(c:TClass):IlSigNorm {
		return LClass(companionPath(c), []);
	}

	// The companion of `c` as code may name it; Unsupported for an hxgeneric class without one (a struct or
	// a local function's class), whose instantiations share no CLR type.
	public static function companionOf(g:DotnetCtx, c:TClass):IlSigNorm {
		if (!hasCompanion(g, c)) {
			var what = TypeFunctions.hasMeta(":struct", c.meta) ? "a generic struct" : "a local function's generic class";
			throw new Unsupported(what + " as " + DotnetTypes.haxePath(TClassDecl(c)) + "<Dynamic>", false);
		}
		return companionSig(c);
	}

	// `<flatpath>_cast`: the path, @:native's if it has one, with its dots as underscores
	// (`haxe_ds_StringMap_cast`, `pk_Nat_cast` for @:native("pk.Nat")).
	public static function castName(c:TClass):String {
		var native = DotnetNames.nativeName(c.meta);
		var parts = native != null ? native.split(".") : c.path.pack.concat([c.path.name]);
		return parts.join("_") + "_cast";
	}

	static function staticsPath(c:TClass):IlPath {
		var p = companionPath(c);
		return {ns: p.ns, nested: [], name: p.name + "__Statics_"};
	}

	static function isInterface(c:TClass):Bool return TypeFunctions.hasClassFlag(c, CInterface);

	// Whether the method `f` of the hxgeneric class or interface `c` is a member of its companion: an
	// instance method (not dynamic, not an override) whose Haxe type mentions no type parameter, of the
	// class or of the method (has_type_params, which follows typedefs: `it():Iterator<T>` is a member).
	// The bodies of the runtime Array's Equals and GetHashCode overrides, which the #8314 forward adds to
	// it (gencs's Array has neither), are not, so the companion stays gencs's.
	public static function isMember(g:DotnetCtx, c:TClass, f:TClassField):Bool {
		if (!f.kind.match(Method(MethNormal | MethInline)) || TypeFunctions.hasClassFieldFlag(f, CfOverride)) return false;
		if (TypeFunctions.hasClassFieldFlag(f, CfExtern) || c.constructor == f) return false;
		if ((f.name == "__hx_equals" || f.name == "__hx_hashCode") && c == g.runtimeClass("Array")) return false;
		return hasCompanion(g, c) && !HxGeneric.hasTypeParams(f.type);
	}

	static function apply(c:TClass, params:Array<T>, t:T):T return TypeFunctions.applyParams(c.params, params, t);

	// The interfaces a class or interface lists, in the order its declaration lists them (the typer keeps
	// them the other way round).
	static function listed(c:TClass):Array<TClassWithParams> {
		var r = c.interfaces.copy();
		r.reverse();
		return r;
	}

	// The generic interfaces (deep, each one's own interfaces before it) and generic superclasses the
	// class has parent casts for, in gencs's order: its own interfaces, then its superclass's list, then
	// its superclass; a parent reached twice keeps its last place.
	static function parents(g:DotnetCtx, c:TClass):Array<Parent> {
		var known = g.castParents.get(c);
		if (known != null) return known;
		var r:Array<Parent> = [];
		function add(p:TClass, params:Array<T>) {
			for (i in 0...r.length) if (r[i].c == p) {
				r.splice(i, 1);
				break;
			}
			r.push({c: p, params: params});
		}
		for (p in listedParents(g, c)) add(p.c, p.params);
		var s = c.superClass;
		if (s != null && !TypeFunctions.hasClassFlag(s.c, CExtern)) {
			for (p in parents(g, s.c)) add(p.c, [for (t in p.params) apply(s.c, s.params, t)]);
			if (hasCompanion(g, s.c)) add(s.c, s.params);
		}
		g.castParents.set(c, r);
		return r;
	}

	// The generic interfaces the class lists (deep, each one's own interfaces before it); one reached twice
	// keeps its last place.
	static function listedParents(g:DotnetCtx, c:TClass):Array<Parent> {
		var r:Array<Parent> = [];
		function iface(i:TClass, params:Array<T>) {
			for (sup in listed(i)) iface(sup.c, [for (t in sup.params) apply(i, params, t)]);
			if (!hasCompanion(g, i)) return;
			for (k in 0...r.length) if (r[k].c == i) {
				r.splice(k, 1);
				break;
			}
			r.push({c: i, params: params});
		}
		for (i in listed(c)) iface(i.c, i.params);
		return r;
	}

	// The parents the class declares a cast member for: all of them for an hxgeneric class; for another
	// class, the generic interfaces it lists, even one whose cast a superclass has (gencs writes the cast
	// in each class that lists the interface).
	static function declaredParents(g:DotnetCtx, c:TClass):Array<Parent> {
		if (isInterface(c) || TypeFunctions.hasClassFlag(c, CExtern)) return [];
		if (hasCompanion(g, c)) return parents(g, c);
		return listedParents(g, c);
	}

	// The names of the cast members a class has, declared or inherited. Each class asks for its
	// superclass's, so they are remembered for the round, as parents are.
	static function castNames(g:DotnetCtx, c:TClass):Array<String> {
		if (TypeFunctions.hasClassFlag(c, CExtern)) return [];
		var known = g.castNames.get(c);
		if (known != null) return known;
		var r = [];
		if (hasCompanion(g, c)) r.push(castName(c));
		for (p in declaredParents(g, c)) r.push(castName(p.c));
		if (c.superClass != null) r = r.concat(castNames(g, c.superClass.c));
		g.castNames.set(c, r);
		return r;
	}

	static function castGenerics(c:TClass, suffix:String):Array<String> {
		return [for (p in c.params) p.name + suffix];
	}

	static function method(kind:MethodKind, name:String, flags:Int, hasThis:Bool, ret:IlSigNorm, args:Array<IlSigNorm>, argNames:Array<String>,
			generics:Array<String>, pos:hxc.ast.Position):MethodPlan {
		return {
			kind: kind,
			name: name,
			flags: flags,
			hasThis: hasThis,
			ret: ret,
			args: args,
			argNames: argNames,
			generics: generics,
			pos: pos,
			token: 0
		};
	}

	static function helper(c:TClass):MethodPlan {
		return method(MCast(c, CHelper(c)), "__hx_cast", MethodAttrs.PUBLIC | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG, false, LObject, [companionSig(c)],
			["me"], castGenerics(c, "_c_c"), c.pos);
	}

	// The cast members the class itself has, which come after its constructors: `__hx_cast`, its own cast
	// and its parent casts for an hxgeneric class, `return this` casts for another.
	public static function castMethods(g:DotnetCtx, c:TClass):Array<MethodPlan> {
		if (isInterface(c) || TypeFunctions.hasClassFlag(c, CExtern)) return [];
		var inherited = c.superClass == null ? [] : castNames(g, c.superClass.c);
		var isFinal = TypeFunctions.hasClassFlag(c, CFinal) || TypeFunctions.hasMeta(":struct", c.meta);
		// virtual, an override of an inherited cast in an hxgeneric class (another class's hides it, as C#'s
		// `virtual` does), or in a final class one that only implements the companion's member.
		function flags(name:String):Int {
			var f = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.VIRTUAL;
			if (hasCompanion(g, c) && inherited.indexOf(name) >= 0) return f;
			return f | MethodAttrs.NEW_SLOT | (isFinal ? MethodAttrs.FINAL : 0);
		}
		var r:Array<MethodPlan> = [];
		if (hasCompanion(g, c)) {
			r.push(helper(c));
			r.push(method(MCast(c, COwn), castName(c), flags(castName(c)), true, LObject, [], [], castGenerics(c, "_c"), c.pos));
		}
		for (p in declaredParents(g, c)) {
			var body = hasCompanion(g, c) ? CParent(parentArgs(g, c, p)) : CThis;
			r.push(method(MCast(c, body), castName(p.c), flags(castName(p.c)), true, LObject, [], [], castGenerics(p.c, "_c"), c.pos));
		}
		return r;
	}

	// Types §4's type arguments b1..bn of the parent cast of `p`: for each type parameter Tk of the class,
	// the cast's own parameter Pj_c for the first parent parameter whose argument, after erasure, is Tk;
	// Tk itself when none is (`Fixed<T> implements I1<Int>` keeps T, and its cast returns `this`).
	static function parentArgs(g:DotnetCtx, c:TClass, p:Parent):Array<IlSigNorm> {
		var erased = g.types.withParams(c.params, [], () -> g.types.classArgs(p.c, p.params));
		return [
			for (k in 0...c.params.length) {
				var b = LTypeParam(k);
				for (j in 0...erased.length) if (IlPaths.sigEq(erased[j], LTypeParam(k))) {
					b = LMethodTypeParam(j);
					break;
				}
				b;
			}
		];
	}

	// The interfaces a class or interface implements besides those Haxe lists: its companion and
	// haxe.lang.IGenericObject, its generic superclasses' companions and those of the generic interfaces
	// in `implemented`, as C# lists every interface it reaches.
	public static function addInterfaces(g:DotnetCtx, c:TClass, implemented:Array<TClass>, sigs:Array<IlSigNorm>):Array<IlSigNorm> {
		var r = sigs.copy();
		function add(s:IlSigNorm) {
			for (x in r) if (IlPaths.sigEq(x, s)) return;
			r.push(s);
		}
		if (hasCompanion(g, c)) {
			add(companionSig(c));
			add(genericObjectSig(g));
		}
		var s = c.superClass;
		while (s != null) {
			if (hasCompanion(g, s.c)) add(companionSig(s.c));
			s = s.c.superClass;
		}
		for (i in implemented) if (hasCompanion(g, i)) add(companionSig(i));
		return r;
	}

	static function genericObjectSig(g:DotnetCtx):IlSigNorm {
		return LClass(g.types.stdClassPath("cs.internal.IGenericObject", "generic classes without haxe.lang.IGenericObject", true), []);
	}

	static function hxObjectSig(g:DotnetCtx):IlSigNorm {
		return LClass(g.types.stdClassPath("cs.internal.IHxObject", "generic classes without haxe.lang.IHxObject", true), []);
	}

	// A member of a companion interface.
	static function abstractMethod(kind:MethodKind, name:String, ret:IlSigNorm, args:Array<IlSigNorm>, argNames:Array<String>, generics:Array<String>,
			pos:hxc.ast.Position):MethodPlan {
		var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT | MethodAttrs.ABSTRACT;
		return method(kind, name, flags, true, ret, args, argNames, generics, pos);
	}

	static function castDecl(c:TClass, pos:hxc.ast.Position):MethodPlan {
		return abstractMethod(MCompanionMember, castName(c), LObject, [], [], castGenerics(c, "_c"), pos);
	}

	// The companion interface of the class or interface `c`, whose own plan is declared, and for an
	// interface its `__Statics_` class: into g.plans, the companion before the class and the statics class
	// after it. Throws Unsupported when they cannot be declared.
	public static function declare(g:DotnetCtx, c:TClass):Void {
		if (!hasCompanion(g, c)) return;
		var plan = g.planOf.get(c);
		if (plan == null) throw "internal error: no plan for " + DotnetTypes.haxePath(TClassDecl(c));
		var methods:Array<MethodPlan> = [castDecl(c, c.pos)];
		var bases = [hxObjectSig(g)];
		var indexer = null;
		if (isInterface(c)) {
			// The interface's methods that mention no type parameter, which its own plan left out.
			var renamed = TclassToIl.renamedTypeParams(c);
			for (cf in c.orderedFields) for (f in [cf].concat(cf.overloads)) if (isMember(g, c, f)) {
				var sig = g.types.withParams(c.params, f.params, () -> TclassToIl.functionSig(g, f.type));
				methods.push(abstractMethod(MField(f), DotnetNames.fieldName(c, f.name), sig.ret, sig.args, sig.names, renamed.get(f), f.pos));
			}
		} else {
			var s = c.superClass;
			var superHas = s != null && hasCompanion(g, s.c) ? [for (p in parents(g, s.c)) p.c] : [];
			for (p in parents(g, c)) if (isInterface(p.c) && superHas.indexOf(p.c) < 0) methods.push(castDecl(p.c, c.pos));
			if (s != null && hasCompanion(g, s.c)) methods.push(castDecl(s.c, c.pos));
			for (m in plan.methods) switch (m.kind) {
				case MField(f) if (m.hasThis && m.name != ".ctor" && isMember(g, c, f)):
					methods.push(abstractMethod(MCompanionMember, m.name, m.ret, m.args, m.argNames, m.generics, m.pos));
				case _:
			}
			// gencs's `object this[int key]` of a companion with array access, after its other methods.
			indexer = IndexerToIl.companionMembers(plan);
			if (indexer != null) for (m in indexer.methods) methods.push(m);
			while (s != null) {
				if (hasCompanion(g, s.c)) bases.push(companionSig(s.c));
				s = s.c.superClass;
			}
		}
		bases.push(genericObjectSig(g));
		// A generic interface's members that mention no type parameter come here, not through planClass.
		TclassToIl.checkDistinctSignatures(methods);
		var companion = typePlan(plan, "companion", companionPath(c), TypeAttrs.PUBLIC | TypeAttrs.INTERFACE | TypeAttrs.ABSTRACT, bases, methods);
		if (indexer != null) companion.properties = [indexer.property];
		g.plans.insert(g.plans.indexOf(plan), companion);
		g.companionPlans.set(c, companion);
		g.companionOrder.push(c);
		if (isInterface(c)) {
			var statics = typePlan(plan, "statics", staticsPath(c), TypeAttrs.PUBLIC | TypeAttrs.BEFORE_FIELD_INIT, [],
				[helper(c), TclassToIl.implicitCtor(c.pos, false)]);
			g.plans.insert(g.plans.indexOf(plan) + 1, statics);
			g.staticsPlans.set(c, statics);
		}
	}

	// A TypeDef that belongs to the class of `plan` and has no Haxe class of its own: its companion or its
	// `__Statics_` class.
	static function typePlan(plan:ClassPlan, what:String, path:IlPath, flags:Int, interfaces:Array<IlSigNorm>, methods:Array<MethodPlan>):ClassPlan {
		return {
			c: null,
			hxPath: plan.hxPath + " (" + what + ")",
			path: path,
			flags: flags,
			superSig: null,
			interfaces: interfaces,
			fields: [],
			methods: methods,
			classParams: [],
			isStd: plan.isStd,
			thisSig: LClass(path, []),
			isStruct: false,
			initFlag: false,
			ctors: null,
			emptyCtor: null,
			properties: [],
			events: [],
			token: 0
		};
	}

	// What comes after the TypeDef rows are written: the companion's GenericInterface attribute, whose
	// argument is `typeof(X<object…>)`, serialized by name as a System.Type argument is: X`n[[System.Object,
	// System.Runtime, …]], the type arguments assembly-qualified as Roslyn writes them.
	public static function emit(g:DotnetCtx, c:TClass):Void {
		var companion = g.companionPlans.get(c);
		if (companion == null) return;
		var ga = g.runtimeClass("cs.internal.GenericInterface");
		var gaPlan = ga == null ? null : g.planOf.get(ga);
		var ctor = null;
		if (gaPlan != null) for (m in gaPlan.methods) if (m.name == ".ctor" && m.args.length == 1) ctor = m;
		if (ctor == null) throw "internal error: haxe.lang.GenericInterface has no constructor";
		var name = AttributesToIl.serializedName(g, LClass(DotnetNames.typePath(TClassDecl(c)), [for (_ in c.params) LObject]));
		var param = AttributesToIl.attrTypeOf(g, ctor.args[0]);
		if (param == null) throw "internal error: haxe.lang.GenericInterface's constructor takes no Type";
		AttributesToIl.write(g, companion.token, {token: ctor.token, params: [param]}, [AType(name)], []);
	}

	// The token code calls a class's or interface's `__hx_cast<…>` with (a MethodSpec of it gives the
	// type arguments): for a class through its instantiation with object for each parameter, as gencs
	// writes `G<object>.__hx_cast<int>(…)`; for an interface its `__Statics_` class's method.
	public static function castHelperOf(g:DotnetCtx, c:TClass):Int {
		var plan = isInterface(c) ? g.staticsPlans.get(c) : g.planOf.get(c);
		if (plan == null || !hasCompanion(g, c)) throw "internal error: " + DotnetTypes.haxePath(TClassDecl(c)) + " has no __hx_cast";
		for (m in plan.methods) if (m.name == "__hx_cast" && !m.hasThis) {
			if (plan.classParams.length == 0) return m.token;
			var owner = DotnetCtx.instanceOf(plan, [for (_ in plan.classParams) LObject]);
			return g.mb.memberRef(g.typeTokenOf(owner), m.name, g.sigs.method(false, m.ret, m.args, m.generics.length));
		}
		throw "internal error: " + DotnetTypes.haxePath(TClassDecl(c)) + " has no __hx_cast";
	}

	// A cast member's body.
	public static function emitCast(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, c:TClass, body:CastBody, code:IlCode):Void {
		switch (body) {
			case CHelper(of):
				// me != null ? me.X_cast<T_c_c…>() : null
				var companion = g.companionPlans.get(of);
				if (companion == null) throw "internal error: no companion for " + DotnetTypes.haxePath(TClassDecl(of));
				var call = g.mb.methodSpec(companion.methods[0].token, g.sigs.methodSpec([for (i in 0...m.generics.length) LMethodTypeParam(i)]));
				var some = code.newLabel();
				code.ldarg(0);
				code.branch(IlOps.BRTRUE, some);
				code.op(IlOps.LDNULL, 0, 1);
				code.op(IlOps.RET, 1, 0);
				code.mark(some);
				code.ldarg(0);
				code.opToken(IlOps.CALLVIRT, call, 1, 1);
				code.op(IlOps.RET, 1, 0);
			case CThis:
				code.ldarg(0);
				// A struct's `this` is its address: the value, boxed.
				if (plan.isStruct) {
					code.opToken(IlOps.LDOBJ, g.typeTokenOf(plan.thisSig), 1, 1);
					code.opToken(IlOps.BOX, g.typeTokenOf(plan.thisSig), 1, 1);
				}
				code.op(IlOps.RET, 1, 0);
			case CParent(args):
				code.ldarg(0);
				code.opToken(IlOps.CALLVIRT, ownCast(g, plan, c, args), 1, 1);
				code.op(IlOps.RET, 1, 0);
			case COwn:
				var copy = new CastCopy(g, plan, c, code);
				if (c == g.runtimeClass("Array")) copy.emitArray() else if (TypeFunctions.hasClassFlag(c, CAbstract)) copy.emitAbstract() else copy.emit();
		}
	}

	// The class's own cast with the type arguments `args`, called on `this`.
	static function ownCast(g:DotnetCtx, plan:ClassPlan, c:TClass, args:Array<IlSigNorm>):Int {
		var own = null;
		for (x in plan.methods) if (x.kind.match(MCast(_, COwn))) own = x;
		if (own == null) throw "internal error: " + plan.hxPath + " has no cast of its own";
		var token = g.mb.memberRef(g.typeTokenOf(plan.thisSig), own.name, g.sigs.method(true, LObject, [], own.generics.length));
		return g.mb.methodSpec(token, g.sigs.methodSpec(args));
	}
}

// A NativeArray field over a type parameter that X_cast copies element by element: through
// Runtime.genericCast<T_c> (`elem` null) or the hxgeneric class `elem`'s __hx_cast.
private typedef ArrayField = {cf:TClassField, owner:TClass, elem:Null<TClass>};

// The body of an hxgeneric class's own `X_cast<T_c…>()` (gencs's, types §3):
//
//     if (Runtime.eq(typeof(T), typeof(T_c)) && …) return this;
//     X<T_c…> new_me = new X<T_c…>(EmptyObject.EMPTY);
//     Array<string> fields = Reflect.fields(this);
//     int i = 0;
//     while (i < fields.length) {
//         string field = fields[i++];
//         switch (field) {
//             case "<a NativeArray field>": <copy it element by element, nulls skipped>; break;
//             default: Reflect.setField(new_me, field, Reflect.field(this, field)); break;
//         }
//     }
//     return new_me;
private class CastCopy {
	final g:DotnetCtx;
	final plan:ClassPlan;
	final c:TClass;
	final code:IlCode;
	// The new instance's type arguments: the method's own type parameters.
	final margs:Array<IlSigNorm>;

	public function new(g:DotnetCtx, plan:ClassPlan, c:TClass, code:IlCode) {
		this.g = g;
		this.plan = plan;
		this.c = c;
		this.code = code;
		margs = [for (i in 0...c.params.length) LMethodTypeParam(i)];
	}

	function staticOf(hxPath:String, name:String, what:String):{token:Int, sig:{ret:IlSigNorm, args:Array<IlSigNorm>}} {
		var cls = g.runtimeClass(hxPath);
		if (cls == null) throw new Unsupported(what, false, c.pos);
		g.types.checkKept(TClassDecl(cls));
		var cf = cls.statics.get(name);
		var token = cf == null ? null : g.methodTokens.get(cf);
		if (token == null) throw new Unsupported(what, false, c.pos);
		return {token: token, sig: g.methodSigs.get(cf)};
	}

	function typeOf(t:IlSigNorm):Void {
		var systemType = LClass({ns: ["System"], nested: [], name: "Type"}, []);
		var handle = LValueType({ns: ["System"], nested: [], name: "RuntimeTypeHandle"}, []);
		code.opToken(IlOps.LDTOKEN, g.typeTokenOf(t), 0, 1);
		code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(systemType), "GetTypeFromHandle", g.sigs.method(false, systemType, [handle], 0)), 1, 1);
	}

	// if (Runtime.eq(typeof(T), typeof(T_c)) && …) return this; then `other`.
	function sameArgsReturnThis(other:Label):Void {
		var eq = staticOf("cs.internal.Runtime", "eq", "generic classes without haxe.lang.Runtime.eq");
		for (i in 0...c.params.length) {
			typeOf(LTypeParam(i));
			typeOf(LMethodTypeParam(i));
			code.opToken(IlOps.CALL, eq.token, 2, 1);
			code.branch(IlOps.BRFALSE, other);
		}
		code.ldarg(0);
		code.op(IlOps.RET, 1, 0);
		code.mark(other);
	}

	// An abstract class's own cast, which only a subclass that is not generic inherits (a generic one
	// overrides it): `this` for its own type arguments, else an InvalidCastException. gencs's body,
	// `return this.X_cast<T…>()`, calls itself until the stack overflows for any type arguments; a
	// deliberate divergence (decision 4 of plan 3c).
	public function emitAbstract():Void {
		sameArgsReturnThis(code.newLabel());
		var ex = LClass({ns: ["System"], nested: [], name: "InvalidCastException"}, []);
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(ex), ".ctor", g.sigs.method(true, LVoid, [], 0)), 0, 1);
		code.op(IlOps.THROW, 1, 0);
	}

	// Array's own cast: gencs's check for the same type arguments, then `this.__hx_castTo<T_c>()` of hxc's
	// runtime Array.hx, which reinterprets an untyped array for Haxe issue 8314 and otherwise copies as
	// emit() does (casts notes §2.4).
	public function emitArray():Void {
		var castTo = null;
		for (m in plan.methods) switch (m.kind) {
			case MField(cf) if (cf.name == "__hx_castTo" && m.hasThis): castTo = m;
			case _:
		}
		if (castTo == null) throw "internal error: Array has no __hx_castTo";
		sameArgsReturnThis(code.newLabel());
		var token = g.mb.memberRef(g.typeTokenOf(plan.thisSig), castTo.name, g.sigs.method(true, castTo.ret, castTo.args, castTo.generics.length));
		code.ldarg(0);
		code.opToken(IlOps.CALL, g.mb.methodSpec(token, g.sigs.methodSpec(margs)), 1, 1);
		code.op(IlOps.RET, 1, 0);
	}

	public function emit():Void {
		var what = "generic classes without Reflect.fields, field and setField";
		var fields = staticOf("Reflect", "fields", what);
		var field = staticOf("Reflect", "field", what);
		var setField = staticOf("Reflect", "setField", what);
		if (plan.emptyCtor == null) throw "internal error: " + plan.hxPath + " has no empty constructor";

		sameArgsReturnThis(code.newLabel());

		var newSig = DotnetCtx.instanceOf(plan, margs);
		var newMe = code.addLocal(newSig);
		code.ldcI4(0);
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(newSig), ".ctor", g.sigs.method(true, LVoid, plan.emptyCtor.args, 0)), 1, 1);
		code.stloc(newMe);

		var listSig = fields.sig.ret;
		var list = code.addLocal(listSig);
		code.ldarg(0);
		code.opToken(IlOps.CALL, fields.token, 1, 1);
		code.stloc(list);
		var index = code.addLocal(LInt32);
		code.ldcI4(0);
		code.stloc(index);
		var name = code.addLocal(LString);

		var arrayClass = g.runtimeClass("Array");
		var arrayPlan = arrayClass == null ? null : g.planOf.get(arrayClass);
		var lengthCf = arrayClass == null ? null : arrayClass.fields.get("length");
		var storeCf = arrayClass == null ? null : arrayClass.fields.get("__a");
		if (arrayPlan == null || lengthCf == null || storeCf == null) throw "internal error: Array has no length or __a";

		var loop = code.newLabel(), done = code.newLabel();
		code.mark(loop);
		code.ldloc(index);
		code.ldloc(list);
		code.opToken(IlOps.LDFLD, g.memberOf(arrayPlan, listSig, lengthCf), 1, 1);
		code.branch(IlOps.BGE, done);
		// field = fields.__a[i++]
		code.ldloc(list);
		code.opToken(IlOps.LDFLD, g.memberOf(arrayPlan, listSig, storeCf), 1, 1);
		code.ldloc(index);
		code.ldelem(LString, () -> g.typeTokenOf(LString));
		code.stloc(name);
		code.ldloc(index);
		code.ldcI4(1);
		code.op(IlOps.ADD, 2, 1);
		code.stloc(index);

		var arrays = arrayFields();
		var labels = [for (_ in arrays) code.newLabel()];
		var strEq = g.mb.memberRef(g.typeTokenOf(LString), "op_Equality", g.sigs.method(false, LBool, [LString, LString], 0));
		for (k in 0...arrays.length) {
			code.ldloc(name);
			code.opToken(IlOps.LDSTR, g.mb.userString(DotnetNames.fieldName(arrays[k].owner, arrays[k].cf.name)), 0, 1);
			code.opToken(IlOps.CALL, strEq, 2, 1);
			code.branch(IlOps.BRTRUE, labels[k]);
		}
		// Reflect.setField(new_me, field, Reflect.field(this, field))
		code.ldloc(newMe);
		code.ldloc(name);
		code.ldarg(0);
		code.ldloc(name);
		code.opToken(IlOps.CALL, field.token, 2, 1);
		code.opToken(IlOps.CALL, setField.token, 3, 0);
		code.branch(IlOps.BR, loop);
		for (k in 0...arrays.length) {
			code.mark(labels[k]);
			copyArray(arrays[k], newMe);
			code.branch(IlOps.BR, loop);
		}
		code.mark(done);
		code.ldloc(newMe);
		code.op(IlOps.RET, 1, 0);
	}

	// The class's and its superclasses' instance variables typed cs.NativeArray<E> where E has a type
	// parameter in it and is one (not Null of one), or an hxgeneric class applied to one.
	function arrayFields():Array<ArrayField> {
		var chain = [];
		var cur = c;
		while (cur != null && !TypeFunctions.hasClassFlag(cur, CExtern)) {
			chain.unshift(cur);
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		var r:Array<ArrayField> = [];
		for (owner in chain) for (cf in owner.orderedFields) {
			if (!cf.kind.match(Var(_)) || TypeFunctions.hasClassFieldFlag(cf, CfExtern) || !TypeFunctions.isPhysicalField(cf)) continue;
			var e = nativeArrayElement(cf.type);
			if (e == null || !HxGeneric.hasTypeParams(e) || isNull(e)) continue;
			switch (TypeFunctions.follow(e)) {
				case TInst(p, _) if (p.kind.match(KTypeParameter(_))):
					r.push({cf: cf, owner: owner, elem: null});
				case TInst(x, _) if (CompanionToIl.hasCompanion(g, x)):
					r.push({cf: cf, owner: owner, elem: x});
				case _:
			}
		}
		return r;
	}

	static function nativeArrayElement(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TInst(x, [e]) if (x.path.name == "NativeArray" && x.path.pack.length == 1 && x.path.pack[0] == "cs"): e;
			case _: null;
		}
	}

	// Null<T> after typedefs, which gencs leaves to the default case.
	static function isNull(t:T):Bool {
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, [_]): a.path.pack.length == 0 && a.path.name == "Null";
			case _: false;
		}
	}

	// The field as an instance of the class with the type arguments `selfArgs` reaches it (`this`: the
	// class's own parameters; `new_me`: the method's): its token and type there.
	function fieldOn(f:ArrayField, selfArgs:Array<IlSigNorm>):{token:Int, sig:IlSigNorm} {
		var ownerPlan = g.ownerOf.get(f.cf);
		if (ownerPlan == null) throw "internal error: no field " + f.cf.name;
		var ownerSig = f.owner == c ? plan.thisSig : g.types.withParams(c.params, [], () -> g.types.classSig(f.owner, ownerArgs(f.owner)));
		var owner = DotnetTypes.substitute(ownerSig, selfArgs, []);
		var inst = switch (owner) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		return {token: g.memberOf(ownerPlan, owner, f.cf), sig: DotnetTypes.substitute(g.fieldSigs.get(f.cf), inst, [])};
	}

	// The type arguments of the superclass `owner` in terms of the class's type parameters.
	function ownerArgs(owner:TClass):Array<T> {
		var cur = c;
		var params = TypeFunctions.extractParamTypes(c.params);
		while (cur != owner) {
			var s = cur.superClass;
			params = [for (t in s.params) TypeFunctions.applyParams(cur.params, params, t)];
			cur = s.c;
		}
		return params;
	}

	static function elementOf(s:IlSigNorm):IlSigNorm {
		return switch (s) {
			case LVector(e): e;
			case _: throw "internal error: a NativeArray field that is not a vector";
		}
	}

	// case "<field>": if (this.f != null) { copy each element that is not null } else new_me.f = null;
	function copyArray(f:ArrayField, newMe:Int):Void {
		var mine = fieldOn(f, [for (i in 0...c.params.length) LTypeParam(i)]);
		var theirs = fieldOn(f, margs);
		var oldElem = elementOf(mine.sig), newElem = elementOf(theirs.sig);
		var isNull = code.newLabel(), next = code.newLabel(), loop = code.newLabel(), done = code.newLabel();
		code.ldarg(0);
		code.opToken(IlOps.LDFLD, mine.token, 1, 1);
		code.branch(IlOps.BRFALSE, isNull);
		var arr = code.addLocal(theirs.sig), i = code.addLocal(LInt32), obj = code.addLocal(LObject);
		code.ldarg(0);
		code.opToken(IlOps.LDFLD, mine.token, 1, 1);
		code.op(IlOps.LDLEN, 1, 1);
		code.op(IlOps.CONV_I4, 1, 1);
		code.opToken(IlOps.NEWARR, g.typeTokenOf(newElem), 1, 1);
		code.stloc(arr);
		code.ldcI4(-1);
		code.stloc(i);
		code.mark(loop);
		// while (++i < this.f.Length)
		code.ldloc(i);
		code.ldcI4(1);
		code.op(IlOps.ADD, 2, 1);
		code.op(IlOps.DUP, 1, 2);
		code.stloc(i);
		code.ldarg(0);
		code.opToken(IlOps.LDFLD, mine.token, 1, 1);
		code.op(IlOps.LDLEN, 1, 1);
		code.op(IlOps.CONV_I4, 1, 1);
		code.branch(IlOps.BGE, done);
		// object o = this.f[i]; if (o != null) arr[i] = <o as the new element type>;
		code.ldarg(0);
		code.opToken(IlOps.LDFLD, mine.token, 1, 1);
		code.ldloc(i);
		code.ldelem(oldElem, () -> g.typeTokenOf(oldElem));
		if (DotnetTypes.isValueType(oldElem) || oldElem.match(LTypeParam(_) | LMethodTypeParam(_))) code.opToken(IlOps.BOX, g.typeTokenOf(oldElem), 1, 1);
		code.stloc(obj);
		code.ldloc(obj);
		code.branch(IlOps.BRFALSE, loop);
		code.ldloc(arr);
		code.ldloc(i);
		code.ldloc(obj);
		if (f.elem == null) {
			var genericCast = staticOf("cs.internal.Runtime", "genericCast", "generic classes without haxe.lang.Runtime.genericCast");
			code.opToken(IlOps.CALL, g.mb.methodSpec(genericCast.token, g.sigs.methodSpec([newElem])), 1, 1);
		} else {
			// castclass to the companion, its __hx_cast with the new type arguments, castclass to the element.
			InstantiationCasts.emit(g, code, LObject, newElem);
		}
		code.stelem(newElem, () -> g.typeTokenOf(newElem));
		code.branch(IlOps.BR, loop);
		code.mark(done);
		code.ldloc(newMe);
		code.ldloc(arr);
		code.opToken(IlOps.STFLD, theirs.token, 2, 0);
		code.branch(IlOps.BR, next);
		code.mark(isNull);
		code.ldloc(newMe);
		code.op(IlOps.LDNULL, 0, 1);
		code.opToken(IlOps.STFLD, theirs.token, 2, 0);
		code.mark(next);
	}
}
