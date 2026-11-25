package hxc.codegen.dotnet;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.TclassToIl;
import hxc.codegen.dotnet.TexprToIl;

// A member of an enum's classes, whose body EnumToIl writes.
enum EnumMember {
	// The base class's `protected <Enum>(int index) : base(index)`.
	EBaseCtor;
	// `public static <Enum> <Ctor>(args)`, which returns `new <Enum>_<Ctor>(args)`.
	EFactory(ef:TEnumField);
	// The base class's static constructor: each singleton, then __hx_constructs.
	ECctor;
	// A constructor class's `.ctor(args) : base(index)`, which stores each argument in its field.
	ECtor(ef:TEnumField);
	EGetTag(ef:TEnumField);
	EGetParams(ef:TEnumField);
	EHashCode(ef:TEnumField);
	EEquals(ef:TEnumField);
	EToString(ef:TEnumField);
}

// What an hxgen enum became, and the tokens code that reaches it uses, read once the rows are written.
class EnumPlan {
	public final e:TEnum;
	public final base:ClassPlan;
	// The constructor classes, by constructor index.
	public final ctors:Array<ClassPlan>;
	// Each constructor's arguments' erased types (EnumToIl.argSig), by constructor index.
	public final argSigs:Array<Array<IlSigNorm>>;
	// haxe.lang.Enum::_hx_index, set once the rows are written.
	public var hxIndex = 0;
	// The base class's __hx_constructs, when Type.getEnumConstructs is used.
	public final constructs:Null<FieldPlan>;

	final baseCtor:MethodPlan;
	// By constructor index: the singleton of one without arguments, the factory of one with, the
	// constructor class's .ctor and argument fields.
	final singletons:Array<Null<FieldPlan>>;
	final factories:Array<Null<MethodPlan>>;
	final ctorMethods:Array<MethodPlan>;
	final params:Array<Array<FieldPlan>>;

	public function new(e:TEnum, base:ClassPlan, ctors:Array<ClassPlan>, argSigs:Array<Array<IlSigNorm>>, constructs:Null<FieldPlan>,
			baseCtor:MethodPlan, singletons:Array<Null<FieldPlan>>, factories:Array<Null<MethodPlan>>, ctorMethods:Array<MethodPlan>,
			params:Array<Array<FieldPlan>>) {
		this.e = e;
		this.base = base;
		this.ctors = ctors;
		this.argSigs = argSigs;
		this.constructs = constructs;
		this.baseCtor = baseCtor;
		this.singletons = singletons;
		this.factories = factories;
		this.ctorMethods = ctorMethods;
		this.params = params;
	}

	public function baseToken():Int return base.token;

	public function baseCtorToken():Int return baseCtor.token;

	public function ctorToken(ef:TEnumField):Int return ctors[ef.index].token;

	// The constructor class's .ctor.
	public function ctorMethodToken(ef:TEnumField):Int return ctorMethods[ef.index].token;

	// The static field holding the one value of a constructor without arguments.
	public function singleton(ef:TEnumField):Int {
		var f = singletons[ef.index];
		if (f == null) throw "internal error: " + base.hxPath + "." + ef.name + " has arguments";
		return f.token;
	}

	// The static factory method of a constructor with arguments.
	public function factory(ef:TEnumField):Int {
		var m = factories[ef.index];
		if (m == null) throw "internal error: " + base.hxPath + "." + ef.name + " has no arguments";
		return m.token;
	}

	// The field of the constructor class holding argument `i`.
	public function param(ef:TEnumField, i:Int):Int return params[ef.index][i].token;

	public function isSingleton(ef:TEnumField):Bool return singletons[ef.index] != null;
}

// An hxgen enum as gencs's enumToClass2 writes it: a base class extending haxe.lang.Enum, with a
// static readonly field holding the one value of each constructor without arguments and a static
// factory for each constructor with, and a sealed class per constructor, whose fields hold the
// arguments and which overrides getTag (and with arguments getParams, GetHashCode, Equals and
// toString). The enum's and the constructors' type parameters are erased.
class EnumToIl {
	static inline final hxEnumPath = "cs.internal.HxEnum";

	// An enum gencs writes as classes.
	public static function isHxGenEnum(e:TEnum):Bool {
		return !e.isExtern && HxGen.isHxGen(TEnumDecl(e));
	}

	// The enum whose classes values of type `t` belong to, or null. An abstract over the enum (haxeui's
	// Variant) holds the same values.
	public static function enumOfType(t:T):Null<TEnum> {
		return switch (TypeFunctions.followWithAbstracts(t)) {
			case TEnum(e, _) if (isHxGenEnum(e)): e;
			case _: null;
		}
	}

	// The constructors, by index.
	public static function constructors(e:TEnum):Array<TEnumField> {
		var r:Array<TEnumField> = [for (_ in e.names) null];
		for (name in e.names) {
			var ef = e.constrs.get(name);
			r[ef.index] = ef;
		}
		return r;
	}

	// The CLR path of a constructor's class, <Enum>_<Ctor> next to the base class.
	public static function ctorPath(e:TEnum, ef:TEnumField):IlPath {
		var base = DotnetNames.typePath(TEnumDecl(e));
		return {ns: base.ns, nested: [], name: base.name + "_" + ef.name};
	}

	static function args(ef:TEnumField):Array<{name:String, t:T, opt:Bool}> {
		return switch (TypeFunctions.follow(ef.type)) {
			case TFun(sig): [for (a in sig.args) {name: a.name, t: a.t, opt: a.opt}];
			case _: [];
		}
	}

	// The enum a constructor belongs to, which its type returns.
	public static function enumOf(ef:TEnumField):TEnum {
		var t = switch (TypeFunctions.follow(ef.type)) {
			case TFun(sig): TypeFunctions.follow(sig.ret);
			case t: t;
		}
		return switch (t) {
			case TEnum(e, _): e;
			case _: throw "internal error: the constructor " + ef.name + " does not make an enum value";
		}
	}

	// The erased type of argument `i` of the constructor `ef`: the enum's and the constructor's type
	// parameters applied as Dynamic. So an argument whose type is an instantiation of a generic Haxe class
	// with one of those type parameters (Array<T>, G<T>, Array<Null<T>>) is gencs's companion interface
	// (Array, G; types notes §1). A generic class without a companion (a struct, a @:nativeGen class, one
	// that is not hxgeneric; CompanionToIl) keeps X<object…>, so one there is refused.
	public static function argSig(g:DotnetCtx, ef:TEnumField, i:Int):IlSigNorm {
		var a = args(ef)[i];
		var params = enumOf(ef).params.concat(ef.params);
		var t = TypeFunctions.applyParams(params, [for (_ in params) TypeFunctions.tDynamic], a.t);
		var s = g.types.withParams([], [], () -> g.types.argSig(t, a.opt));
		if (g.isGenericHaxeClass(s) && mentions(a.t, params)) throw new Unsupported("enum arguments of generic classes without a companion interface", true, ef.pos);
		return s;
	}

	// Whether `t` names one of `params`.
	static function mentions(t:T, params:TypeParams, depth = 0):Bool {
		if (depth > 20) return false;
		inline function any(l:Array<T>) return Lambda.exists(l, x -> mentions(x, params, depth + 1));
		return switch (t) {
			case TMono(m): m.type != null && mentions(m.type, params, depth + 1);
			case TLazy(f): mentions(TypeFunctions.lazyType(f), params, depth + 1);
			case TInst(c, []) if (c.kind.match(KTypeParameter(_))): Lambda.exists(params, p -> DotnetTypes.isParam(p, c));
			case TInst(_, l) | TEnum(_, l) | TType(_, l) | TAbstract(_, l): any(l);
			case TFun(sig): any([for (a in sig.args) a.t]) || mentions(sig.ret, params, depth + 1);
			case TAnon(_) | TDynamic(_): false;
		}
	}

	// An argument's field: named like the argument, except that one named like its class becomes
	// Name_Name, repeated while that is another argument's name, as DotnetNames.fieldName names class
	// members (C# has no member named like its type). The constructor's and factory's parameters keep
	// the argument's name.
	static function fieldName(className:String, name:String, names:Array<String>):String {
		if (name != className) return name;
		var n = name + "_" + name;
		while (names.indexOf(n) >= 0) n = n + "_" + n;
		return n;
	}

	static function method(kind:MethodKind, name:String, flags:Int, hasThis:Bool, ret:IlSigNorm, args:Array<IlSigNorm>, argNames:Array<String>,
			e:TEnum):MethodPlan {
		return {
			kind: kind,
			name: name,
			flags: flags,
			hasThis: hasThis,
			ret: ret,
			args: args,
			argNames: argNames,
			generics: [],
			pos: e.pos,
			token: 0
		};
	}

	static function classPlan(hxPath:String, path:IlPath, flags:Int, superSig:IlSigNorm, fields:Array<FieldPlan>, methods:Array<MethodPlan>,
			isStd:Bool):ClassPlan {
		return {
			c: null,
			hxPath: hxPath,
			path: path,
			flags: flags,
			superSig: superSig,
			interfaces: [],
			fields: fields,
			methods: methods,
			classParams: [],
			isStd: isStd,
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

	// The enum's plans, the base class's first, into g.plans and g.enumPlans; throws Unsupported when
	// it cannot be declared.
	public static function declare(g:DotnetCtx, e:TEnum):Void {
		var plan = try planEnum(g, e) catch (u:Unsupported) {
			if (u.pos == null) u.pos = e.pos;
			throw u;
		}
		g.plans.push(plan.base);
		for (p in plan.ctors) g.plans.push(p);
		g.enumPlans.set(e, plan);
	}

	static function planEnum(g:DotnetCtx, e:TEnum):EnumPlan {
		var isStd = g.isStd(e.pos);
		var hxPath = DotnetTypes.haxePath(TEnumDecl(e));
		var path = DotnetNames.typePath(TEnumDecl(e));
		var self = LClass(path, []);
		var hxEnum = g.runtimeClass(hxEnumPath);
		if (hxEnum == null) throw new Unsupported("enums", true);
		var hxEnumSig = LClass(g.types.stdClassPath(hxEnumPath, "enums", true), []);
		// haxe.lang.Enum's getParams, whose signature the overrides take.
		var paramsSig = switch (TypeFunctions.follow(hxEnum.fields.get("getParams").type)) {
			case TFun(sig): g.types.withParams([], [], () -> g.types.toSig(sig.ret));
			case _: throw "internal error: haxe.lang.Enum.getParams is not a method";
		}
		var ctors = constructors(e);
		var argSigs = [for (ef in ctors) [for (i in 0...args(ef).length) argSig(g, ef, i)]];

		var singletons:Array<Null<FieldPlan>> = [], factories:Array<Null<MethodPlan>> = [];
		var baseFields:Array<FieldPlan> = [];
		for (ef in ctors) {
			var f:Null<FieldPlan> = null;
			if (argSigs[ef.index].length == 0) {
				f = {cf: null, name: ef.name, flags: FieldAttrs.PUBLIC | FieldAttrs.STATIC | FieldAttrs.INIT_ONLY, sig: self};
				baseFields.push(f);
			}
			singletons.push(f);
		}
		// gencs's __hx_constructs, which Type.getEnumConstructs reads, on every enum when it is used. It is
		// not public: getEnumConstructs looks for it among the non-public static fields.
		var constructs:Null<FieldPlan> = null;
		if (g.ctx.hasFeature("Type.getEnumConstructs")) {
			constructs = {cf: null, name: "__hx_constructs", flags: FieldAttrs.FAMILY | FieldAttrs.STATIC | FieldAttrs.INIT_ONLY, sig: LVector(LString)};
			baseFields.push(constructs);
		}
		var baseCtor = method(MEnum(e, EBaseCtor), ".ctor", MethodAttrs.FAMILY | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME,
			true, LVoid, [LInt32], ["index"], e);
		var baseMethods = [baseCtor];
		for (ef in ctors) {
			var m:Null<MethodPlan> = null;
			if (argSigs[ef.index].length > 0) {
				m = method(MEnum(e, EFactory(ef)), ef.name, MethodAttrs.PUBLIC | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG, false, self,
					argSigs[ef.index], [for (a in args(ef)) a.name], e);
				baseMethods.push(m);
			}
			factories.push(m);
		}
		if (baseFields.length > 0) {
			baseMethods.push(method(MEnum(e, ECctor), ".cctor",
				MethodAttrs.PRIVATE | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME, false, LVoid, [],
				[], e));
		}
		var base = classPlan(hxPath, path, TypeAttrs.PUBLIC | TypeAttrs.BEFORE_FIELD_INIT, hxEnumSig, baseFields, baseMethods, isStd);

		var ctorPlans = [], ctorMethods = [], params = [];
		var overrides = MethodAttrs.PUBLIC | MethodAttrs.VIRTUAL | MethodAttrs.HIDE_BY_SIG;
		for (ef in ctors) {
			var sigs = argSigs[ef.index];
			var names = [for (a in args(ef)) a.name];
			var className = ctorPath(e, ef).name;
			var fields:Array<FieldPlan> = [
				for (i in 0...sigs.length)
					{cf: null, name: fieldName(className, names[i], names), flags: FieldAttrs.PUBLIC | FieldAttrs.INIT_ONLY, sig: sigs[i]}
			];
			var ctor = method(MEnum(e, ECtor(ef)), ".ctor", MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME,
				true, LVoid, sigs, names, e);
			var methods = [ctor];
			if (sigs.length > 0) methods.push(method(MEnum(e, EGetParams(ef)), "getParams", overrides, true, paramsSig, [], [], e));
			methods.push(method(MEnum(e, EGetTag(ef)), "getTag", overrides, true, LString, [], [], e));
			if (sigs.length > 0) {
				methods.push(method(MEnum(e, EHashCode(ef)), "GetHashCode", overrides, true, LInt32, [], [], e));
				methods.push(method(MEnum(e, EEquals(ef)), "Equals", overrides, true, LBool, [LObject], ["other"], e));
				methods.push(method(MEnum(e, EToString(ef)), "toString", overrides, true, LString, [], [], e));
			}
			var p = ctorPath(e, ef);
			ctorPlans.push(classPlan(hxPath + "_" + ef.name, p, TypeAttrs.PUBLIC | TypeAttrs.SEALED | TypeAttrs.BEFORE_FIELD_INIT, self, fields, methods, isStd));
			ctorMethods.push(ctor);
			params.push(fields);
		}
		return new EnumPlan(e, base, ctorPlans, argSigs, constructs, baseCtor, singletons, factories, ctorMethods, params);
	}

	// Once every row is written: the token of haxe.lang.Enum::_hx_index in each plan.
	public static function written(g:DotnetCtx):Void {
		var hxEnum = g.runtimeClass(hxEnumPath);
		var cf = hxEnum == null ? null : hxEnum.fields.get("_hx_index");
		var token = cf == null ? null : g.fieldTokens.get(cf);
		for (plan in g.enumPlans) {
			if (token == null) throw "internal error: haxe.lang.Enum has no _hx_index";
			plan.hxIndex = token;
		}
	}

	public static function label(member:EnumMember):String {
		return switch (member) {
			case EBaseCtor | ECtor(_): "new";
			case EFactory(ef): ef.name;
			case ECctor: "__init__";
			case EGetTag(_): "getTag";
			case EGetParams(_): "getParams";
			case EHashCode(_): "GetHashCode";
			case EEquals(_): "Equals";
			case EToString(_): "toString";
		}
	}

	// A method of haxe.lang.Enum, the MethodDef of hxc's runtime copy.
	static function hxEnumMethod(g:DotnetCtx, name:String):Int {
		var hxEnum = g.runtimeClass(hxEnumPath);
		var cf = hxEnum == null ? null : name == "new" ? hxEnum.constructor : hxEnum.statics.get(name);
		var token = cf == null ? null : g.methodTokens.get(cf);
		if (token == null) throw "internal error: haxe.lang.Enum has no " + name;
		return token;
	}

	@:access(hxc.codegen.dotnet.TexprToIl)
	public static function emit(g:DotnetCtx, m:MethodPlan, e:TEnum, member:EnumMember, code:IlCode, lower:TexprToIl):Void {
		var plan = g.enumPlans.get(e);
		switch (member) {
			case EBaseCtor:
				code.ldarg(0);
				code.ldarg(1);
				code.opToken(IlOps.CALL, hxEnumMethod(g, "new"), 2, 0);
			case EFactory(ef):
				for (i in 0...m.args.length) code.ldarg(i);
				code.opToken(IlOps.NEWOBJ, plan.ctorMethodToken(ef), m.args.length, 1);
			case ECctor:
				// C#'s static field initializers, in declaration order.
				var ctors = constructors(e);
				for (ef in ctors) if (plan.isSingleton(ef)) {
					code.opToken(IlOps.NEWOBJ, plan.ctorMethodToken(ef), 0, 1);
					code.opToken(IlOps.STSFLD, plan.singleton(ef), 1, 0);
				}
				if (plan.constructs != null) {
					var stringToken = g.typeTokenOf(LString);
					code.ldcI4(ctors.length);
					code.opToken(IlOps.NEWARR, stringToken, 1, 1);
					for (ef in ctors) {
						code.op(IlOps.DUP, 1, 2);
						code.ldcI4(ef.index);
						code.opToken(IlOps.LDSTR, g.mb.userString(ef.name), 0, 1);
						code.opToken(IlOps.STELEM, stringToken, 3, 0);
					}
					code.opToken(IlOps.STSFLD, plan.constructs.token, 1, 0);
				}
			case ECtor(ef):
				code.ldarg(0);
				code.ldcI4(ef.index);
				code.opToken(IlOps.CALL, plan.baseCtorToken(), 2, 0);
				for (i in 0...m.args.length) {
					code.ldarg(0);
					code.ldarg(i + 1);
					code.opToken(IlOps.STFLD, plan.param(ef, i), 2, 0);
				}
			case EGetTag(ef):
				code.opToken(IlOps.LDSTR, g.mb.userString(ef.name), 0, 1);
			case EGetParams(ef):
				// new Array<object>(new object[]{...}).
				pushParams(g, plan, ef, code, lower);
				code.opToken(IlOps.NEWOBJ, arrayFromNative(g, m.ret), 1, 1);
			case EToString(ef):
				// haxe.lang.Enum.paramsToString("<Ctor>", new object[]{...}).
				code.opToken(IlOps.LDSTR, g.mb.userString(ef.name), 0, 1);
				pushParams(g, plan, ef, code, lower);
				code.opToken(IlOps.CALL, hxEnumMethod(g, "paramsToString"), 2, 1);
			case EHashCode(ef):
				// haxe.lang.Enum.paramsGetHashCode(<index>, new object[]{...}).
				code.ldcI4(ef.index);
				pushParams(g, plan, ef, code, lower);
				code.opToken(IlOps.CALL, hxEnumMethod(g, "paramsGetHashCode"), 2, 1);
			case EEquals(ef):
				// The same object, or one of this constructor's class whose arguments are each Type.enumEq<object>
				// to this one's, as Dynamics.
				var objectToken = g.typeTokenOf(LObject);
				var refEq = g.mb.memberRef(objectToken, "ReferenceEquals", g.sigs.method(false, LBool, [LObject, LObject], 0));
				var enumEq = typeEnumEq(g);
				var other = code.addLocal(plan.ctors[ef.index].thisSig);
				var notSame = code.newLabel(), differ = code.newLabel();
				code.ldarg(0);
				code.ldarg(1);
				code.opToken(IlOps.CALL, refEq, 2, 1);
				code.branch(IlOps.BRFALSE, notSame);
				code.ldcI4(1);
				code.op(IlOps.RET, 1, 0);
				code.mark(notSame);
				code.ldarg(1);
				code.opToken(IlOps.ISINST, plan.ctorToken(ef), 1, 1);
				code.stloc(other);
				code.ldloc(other);
				code.branch(IlOps.BRFALSE, differ);
				for (i in 0...plan.argSigs[ef.index].length) {
					code.ldarg(0);
					pushParam(plan, ef, i, code, lower);
					code.ldloc(other);
					pushParam(plan, ef, i, code, lower);
					code.opToken(IlOps.CALL, enumEq, 2, 1);
					code.branch(IlOps.BRFALSE, differ);
				}
				code.ldcI4(1);
				code.op(IlOps.RET, 1, 0);
				code.mark(differ);
				code.ldcI4(0);
		}
		code.op(IlOps.RET, m.ret.match(LVoid) ? 0 : 1, 0);
	}

	// `new object[]{this.a, ...}`, each argument field as a Dynamic (pushParam).
	static function pushParams(g:DotnetCtx, plan:EnumPlan, ef:TEnumField, code:IlCode, lower:TexprToIl):Void {
		var sigs = plan.argSigs[ef.index];
		var objectToken = g.typeTokenOf(LObject);
		code.ldcI4(sigs.length);
		code.opToken(IlOps.NEWARR, objectToken, 1, 1);
		for (i in 0...sigs.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			code.ldarg(0);
			pushParam(plan, ef, i, code, lower);
			code.stelem(LObject, () -> objectToken);
		}
	}

	// Argument `i` of the constructor class's object on the stack as a Dynamic: a value type boxed, a
	// haxe.lang.Null<T> through toDynamic().
	@:access(hxc.codegen.dotnet.TexprToIl)
	static function pushParam(plan:EnumPlan, ef:TEnumField, i:Int, code:IlCode, lower:TexprToIl):Void {
		code.opToken(IlOps.LDFLD, plan.param(ef, i), 1, 1);
		lower.convert(plan.argSigs[ef.index][i], LObject);
	}

	// Type.enumEq<object>, which the generated Equals compares each argument with.
	static function typeEnumEq(g:DotnetCtx):Int {
		var type = g.runtimeClass("Type");
		var cf = type == null ? null : type.statics.get("enumEq");
		var token = cf == null ? null : g.methodTokens.get(cf);
		if (token == null) throw new Unsupported("enum equality without Type.enumEq", false);
		return g.mb.methodSpec(token, g.sigs.methodSpec([LObject]));
	}

	// The constructor of the Array instantiation `array` that takes a native array, as array literals use.
	static function arrayFromNative(g:DotnetCtx, array:IlSigNorm):Int {
		var arrayClass = g.runtimeClass("Array");
		var plan = arrayClass == null ? null : g.planOf.get(arrayClass);
		var ctor = null;
		if (plan != null) for (m in plan.methods) if (m.name == ".ctor" && m.args.length == 1 && IlPaths.sigEq(m.args[0], LVector(LTypeParam(0)))) ctor = m;
		if (ctor == null) throw "internal error: Array has no constructor from a native array";
		return g.mb.memberRef(g.typeTokenOf(array), ".ctor", g.sigs.method(true, LVoid, ctor.args, 0));
	}
}
