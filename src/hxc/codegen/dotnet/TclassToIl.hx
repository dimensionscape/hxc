package hxc.codegen.dotnet;

import haxe.ds.ObjectMap;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.codegen.dotnet.CompanionToIl;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.EnumToIl;
import hxc.codegen.dotnet.EventToIl;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.HxGen;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.ReflectionMembers;
import hxc.codegen.dotnet.TexprToIl;

// AttributesToIl's targets, written AttrTarget.TField: imported, its constructors would hide hxc.core.Type's
// TType and TField.
private typedef AttrTarget = AttributesToIl.AttrTarget;

enum MethodKind {
	MField(cf:TClassField);
	// C#'s constructor for a class that declares none: it calls the base type's parameterless one.
	MImplicitCtor;
	MEntryPoint;
	// Static var initializers and __init__.
	MCctor;
	// gencs's ToString for a class with toString():String, which returns this.toString().
	MToString(toString:TClassField);
	// An override of System.Object's virtual method that calls the Haxe method `body` with its arguments:
	// the runtime Array's Equals and GetHashCode (arrayIdentity).
	MObjectOverride(body:TClassField);
	// The runtime Null<T> struct's C# surface (nullSurface): `op_Implicit(T)` (isImplicit), which wraps the
	// value with hasValue true, and `_ofDynamic(object)`, which calls ofDynamic<T>.
	MNullSurface(isImplicit:Bool);
	// An hxgen class's constructor taking haxe.lang.EmptyObject, which runs no constructor body.
	MEmptyCtor;
	// An hxgen class's real constructor: base(EmptyObject.EMPTY), or the parameterless base constructor
	// when the body calls no super(...), then the static constructor with `this` and the arguments.
	MSplitCtor(ctor:HaxeCtor);
	// The static __hx_ctor_* method holding a constructor's initializers and body, `__hx_this` (its first
	// argument) standing for `this` and super(...) calling the base class's static constructor.
	MStaticCtor(ctor:HaxeCtor);
	// A constructor cloned from the .NET base class's, under a class that descends from one.
	MClonedCtor(ctor:HaxeCtor);
	// One of gencs's `__hx_*` reflection members.
	MReflect(r:ReflectMember);
	// For an override with a contravariant parameter (OOverload): the override with the overridden
	// method's signature, which calls the method, a new virtual overload with its own signature.
	MBridge(cf:TClassField);
	// A member of one of the classes an hxgen enum becomes (EnumToIl).
	MEnum(e:TEnum, member:EnumMember);
	// An interface method the class implements with a method of other types (InterfaceBridge).
	MInterfaceBridge(b:InterfaceBridge);
	// One of the cast members of an hxgeneric class or its companion (CompanionToIl).
	MCast(c:TClass, body:CastBody);
	// A member of a class's companion interface, which has no body.
	MCompanionMember;
	// The public accessor of a CLR property (PropertyPlan), its getter or (`isSet`) its setter.
	MPropertyAccessor(p:PropertyPlan, isSet:Bool);
	// The public accessor of a CLR event (EventPlan), its add or (`isRemove`) its remove, which calls the
	// private body the Haxe add_X or remove_X became.
	MEventAccessor(e:EventPlan, isRemove:Bool);
	// An accessor of an indexer gencs gives a class with `__get` and `__set` (IndexerToIl), its getter or
	// (`isSet`) its setter, which calls `get` or `set`; `explicit` the element type of the explicit
	// implementation of the companion interface's indexer, null for the class's own.
	MIndexer(get:Null<TClassField>, set:Null<TClassField>, isSet:Bool, explicit:Null<IlSigNorm>);
	// gencs's overload of a @:nativeGen class's method or constructor `cf` with trailing optional arguments
	// (gencs.ml get_overloads_for_optional_args): its first `n` parameters, passing null or the default value
	// for each of the others to the full method, `: this(...)` for a constructor.
	MOptionalOverload(cf:TClassField, n:Int);
}

// How an override takes the slot of the method it overrides, as gencs's FixOverrides fixes one whose
// CLR signature differs from the slot's: the same signature; the slot's, the parameters whose types
// changed renamed `__temp_<name><n>` and converted into locals of their own names and types at the
// top of the body; or, when a parameter is contravariant (the base method's type unifies with the
// override's and not the other way round, unless the override's is Dynamic), the method keeps its own
// signature as a new virtual overload and an override with the slot's (MBridge) calls it.
enum OverrideShape {
	OSame;
	OInline(slot:{args:Array<IlSigNorm>, ret:IlSigNorm});
	OOverload(slot:{args:Array<IlSigNorm>, ret:IlSigNorm});
}

typedef MethodPlan = {
	kind:MethodKind,
	name:String,
	flags:Int,
	hasThis:Bool,
	ret:IlSigNorm,
	args:Array<IlSigNorm>,
	argNames:Array<String>,
	generics:Array<String>,
	pos:Position,
	token:Int,
	// An override that took its slot's signature (OInline): the parameter types its body sees.
	?ownArgs:Array<IlSigNorm>
};

// `cf` is null for a field of an enum's classes (EnumToIl); `token` is set when the row is written. The
// backing field of a @:property var has its property (`property`), whose accessors every access calls. A
// field with a FieldOffset has its `offset`, its FieldLayout row.
typedef FieldPlan = {cf:Null<TClassField>, name:String, flags:Int, sig:IlSigNorm, ?token:Int, ?property:PropertyPlan, ?offset:Int};

// A CLR property of a class, as gencs's gen_prop writes one for a var its InterfaceProps filter marks: the
// var `cf` (of the class or, for an override of its accessors, a superclass), the property's name and
// type, the private non-virtual bodies the Haxe get_X/set_X become (`_get_X`/`_set_X`, null for an accessor
// the class does not declare), the public accessors that call them and that every Haxe use of
// get_X/set_X calls, and its Property row's token, set when the row is written. A physical @:property var,
// which gencs writes as a C# auto-property (`{ get; set; }`), has no bodies: its accessors read and write
// its private backing field `backing` (planVarProperty), and it is static when the var is. An indexer
// (IndexerToIl) has the types of its index parameters in `index`, which is empty for any other property,
// and `cf` its `__get` (or `__set`).
typedef PropertyPlan = {
	cf:TClassField,
	name:String,
	sig:IlSigNorm,
	index:Array<IlSigNorm>,
	getBody:Null<MethodPlan>,
	setBody:Null<MethodPlan>,
	getter:Null<MethodPlan>,
	setter:Null<MethodPlan>,
	token:Int,
	?backing:FieldPlan,
	?isStatic:Bool
};

// A var as a class or one of its superclasses has it: the class declaring it, with its type arguments in
// terms of the first class's type parameters.
private typedef VarAt = {cf:TClassField, owner:TClass, params:Array<T>};

// A constructor of a class in gencs's class model: the real one, and the static one holding its body
// (null when the class descends from a native type).
typedef CtorPlan = {hx:HaxeCtor, real:MethodPlan, stat:Null<MethodPlan>};

// What a class becomes, worked out before any row is written, so a class that cannot be declared
// is left out without leaving rows behind. `c` is null for EntryPoint__Main and an enum's classes.
typedef ClassPlan = {
	c:Null<TClass>,
	hxPath:String,
	path:IlPath,
	flags:Int,
	// Null for System.Object, and for an interface, which has no base type.
	superSig:Null<IlSigNorm>,
	interfaces:Array<IlSigNorm>,
	fields:Array<FieldPlan>,
	methods:Array<MethodPlan>,
	classParams:TypeParams,
	isStd:Bool,
	// The class's own type, as `this` has it.
	thisSig:IlSigNorm,
	isStruct:Bool,
	// A generic class with a .cctor: gencs's `static bool __hx_init_called`, which lets the .cctor of
	// only the first instantiation run, since the CLR runs one per instantiation.
	initFlag:Bool,
	// gencs's class model (HxGen): the constructors, null for a class outside it, and the constructor
	// taking haxe.lang.EmptyObject.
	ctors:Null<Array<CtorPlan>>,
	emptyCtor:Null<MethodPlan>,
	// The CLR properties, in the order gencs writes them.
	properties:Array<PropertyPlan>,
	// The CLR events (EventToIl): the statics', then the instances', each last declared first.
	events:Array<EventPlan>,
	token:Int,
	// A StructLayout's Pack and Size, a ClassLayout row when either is not 0.
	?layout:{pack:Int, size:Int}
};

// An interface a class implements, with its type arguments in terms of the class's type parameters.
private typedef ImplementedInterface = {c:TClass, params:Array<T>, sig:IlSigNorm};

// An interface method `im` of `iface` that the method `target` of `owner` (the class or a superclass,
// with type arguments `ownerParams` in terms of the class's type parameters) implements with other
// types. As gencs's FixOverrides writes it, the class gets a method with the interface's signature
// `want`, which casts the arguments, calls the method and casts its result: for the same parameter types
// and another return type an explicit implementation `global::<interface>.<name>` (`explicit`); for other
// parameter types, which only an interface whose type arguments erasure changes has (`IQ<C>` is
// ``IQ`1<object>``), a public overload of the method's name.
typedef InterfaceBridge = {
	iface:ImplementedInterface,
	im:TClassField,
	want:{args:Array<IlSigNorm>, ret:IlSigNorm},
	target:TClassField,
	owner:TClass,
	ownerParams:Array<T>,
	explicit:Bool
};

// The class's own methods that implement an interface method (`own`); the bridges gencs adds in front of
// the class's fields, last made first (`bridges`); and the overloads it adds as the overloads of a method
// of the class itself, written in front of it (`overloads`).
private typedef InterfaceImpls = {
	own:ObjectMap<TClassField, Bool>,
	bridges:Array<InterfaceBridge>,
	overloads:ObjectMap<TClassField, Array<InterfaceBridge>>
};

class TypeAttrs {
	public static inline var PUBLIC = 0x1;
	public static inline var SEQUENTIAL = 0x8;
	public static inline var EXPLICIT = 0x10;
	public static inline var LAYOUT_MASK = 0x18;
	public static inline var INTERFACE = 0x20;
	public static inline var ABSTRACT = 0x80;
	public static inline var SEALED = 0x100;
	public static inline var BEFORE_FIELD_INIT = 0x100000;
}

class MethodAttrs {
	public static inline var PRIVATE = 0x1;
	public static inline var FAMILY = 0x4;
	public static inline var PUBLIC = 0x6;
	public static inline var STATIC = 0x10;
	public static inline var FINAL = 0x20;
	public static inline var VIRTUAL = 0x40;
	public static inline var HIDE_BY_SIG = 0x80;
	public static inline var NEW_SLOT = 0x100;
	public static inline var ABSTRACT = 0x400;
	public static inline var SPECIAL_NAME = 0x800;
	public static inline var RT_SPECIAL_NAME = 0x1000;
}

class SemanticsAttrs {
	public static inline var SETTER = 0x1;
	public static inline var GETTER = 0x2;
	public static inline var ADD_ON = 0x8;
	public static inline var REMOVE_ON = 0x10;
}

class FieldAttrs {
	public static inline var PRIVATE = 0x1;
	public static inline var FAMILY = 0x4;
	public static inline var PUBLIC = 0x6;
	public static inline var STATIC = 0x10;
	public static inline var INIT_ONLY = 0x20;
	public static inline var LITERAL = 0x40;
	public static inline var SPECIAL_NAME = 0x200;
	public static inline var RT_SPECIAL_NAME = 0x400;
	public static inline var HAS_DEFAULT = 0x8000;
}

// A Haxe class as a TypeDef with its fields and methods. Every member is public, as gencs makes
// them. Members come as instance fields, static fields, .ctor (for a class in gencs's model the
// EmptyObject one first), the cast members of a generic class (CompanionToIl), instance methods, the
// reflection members, the indexers' accessors (IndexerToIl), ToString, the static constructors, static
// methods, each in declaration order, then Main() and .cctor.

class TclassToIl {
	static final objectPath:IlPath = {ns: ["System"], nested: [], name: "Object"};
	static final valueTypePath:IlPath = {ns: ["System"], nested: [], name: "ValueType"};
	static inline final initFlagName = "__hx_init_called";

	// gencs's RenameTypeParameters (run last, on the generated classes): per class, a counter starting at 0, and
	// for each field (the instance fields in order, then the statics, then the constructor) a set of names in use
	// that starts as the class's type parameters; a field's type parameter whose name is in the set becomes the
	// name and the next counter value not in the set (`T` is `T1`, or `T2` after a `T1`), and every name joins the
	// set. A class without type parameters renames nothing, and neither does an @:overload's overload. gencs keeps
	// an override's base name in its signature and fails to compile (CS0246); here every name is the one written.
	public static function renamedTypeParams(c:TClass):ObjectMap<TClassField, Array<String>> {
		var r = new ObjectMap<TClassField, Array<String>>();
		var fields = c.orderedFields.concat(c.orderedStatics);
		if (c.constructor != null) fields.push(c.constructor);
		var counter = 0;
		for (cf in fields) {
			var used = [for (p in c.params) p.name];
			r.set(cf, [
				for (p in cf.params) {
					var name = p.name;
					while (used.indexOf(name) >= 0) name = p.name + ++counter;
					used.push(name);
					name;
				}
			]);
			for (o in cf.overloads) r.set(o, [for (p in o.params) p.name]);
		}
		return r;
	}

	public static function functionSig(g:DotnetCtx, t:T):{args:Array<IlSigNorm>, names:Array<String>, ret:IlSigNorm} {
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig): {
					args: [for (a in sig.args) g.types.argSig(a.t, a.opt)],
					names: [for (a in sig.args) a.name],
					ret: g.types.toSig(sig.ret)
				};
			case _: throw "internal error: a method without a function type";
		}
	}

	static function at(u:Unsupported, pos:Position):Unsupported {
		if (u.pos == null) u.pos = pos;
		return u;
	}

	// The class's plan, into g.plans; throws Unsupported when it cannot be declared.
	public static function declare(g:DotnetCtx, c:TClass):Void {
		var isStd = g.isStd(c.pos);
		var plan = try g.types.withParams(c.params, [], () -> planClass(g, c, isStd)) catch (u:Unsupported) throw at(u, c.pos);
		g.plans.push(plan);
		g.planOf.set(c, plan);
	}

	// A @:classCode is C# source, which hxc does not compile. One of #pragma lines only (C# warnings have no IL)
	// is ignored; any other is an error at the class, and the class is planned as without it so that its uses
	// do not cascade.
	static function checkClassCode(g:DotnetCtx, c:TClass):Void {
		var m = TypeFunctions.getMetaOpt(":classCode", c.meta);
		if (m == null) return;
		var text = switch (m.params.length == 1 ? m.params[0].expr : null) {
			case EConst(CString(s, _)): s;
			case _: null;
		}
		if (text != null && isPragmaOnly(text)) {
			g.records.push("ignored #pragma @:classCode in " + DotnetTypes.haxePath(TClassDecl(c)));
			return;
		}
		var u = Unsupported.error("@:classCode is C# source, which hxc does not compile: declare the members in Haxe, calling .NET through extern classes (a @:classCode of #pragma lines only is ignored)");
		u.pos = c.pos;
		g.report(u);
	}

	// Whether every non-blank line, once // and /* */ comments are dropped, starts with #pragma.
	static function isPragmaOnly(text:String):Bool {
		var b = new StringBuf();
		var i = 0;
		while (i < text.length) {
			var ch = text.charAt(i), next = text.charAt(i + 1);
			if (ch == "/" && next == "/") {
				while (i < text.length && text.charAt(i) != "\n") i++;
			} else if (ch == "/" && next == "*") {
				var end = text.indexOf("*/", i + 2);
				i = end < 0 ? text.length : end + 2;
				b.addChar(" ".code);
			} else {
				b.add(ch);
				i++;
			}
		}
		for (line in b.toString().split("\n")) {
			var t = StringTools.trim(line);
			if (t != "" && !StringTools.startsWith(t, "#pragma")) return false;
		}
		return true;
	}

	static function functionCodeError(cf:TClassField):Unsupported {
		var u = Unsupported.error("@:functionCode is C# source, which hxc does not compile: write the body in Haxe, calling .NET through extern classes, or keep the metadata out of the dotnet build with #if !dotnet");
		u.pos = cf.pos;
		return u;
	}

	static function planClass(g:DotnetCtx, c:TClass, isStd:Bool):ClassPlan {
		var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
		var isStruct = TypeFunctions.hasMeta(":struct", c.meta);
		if (!isStd) checkClassCode(g, c);
		var superSig = switch (c.superClass) {
			case null: null;
			case s: g.types.classSig(s.c, s.params);
		}
		if (superSig != null && superSig.match(LObject)) superSig = null;
		if (superSig != null && !superSig.match(LClass(_, _))) throw new Unsupported("extending a value type", false);
		if (isStruct) {
			if (superSig != null) throw new Unsupported("structs that extend a class", true);
			superSig = LClass(valueTypePath, []);
		}
		// gencs's class model, for an hxgen class that is not a struct (C# has no struct deriving from
		// HxObject). Its constructor bodies move to static methods unless it descends from a native type.
		var model = !isStruct && HxGen.hasCtorModel(c);
		// An extern superclass in gencs's model (@:hxGen) would have to be a Haxe-generated assembly's class,
		// with its empty constructor, static constructors and reflection members; nothing here declares them.
		if (model && c.superClass != null && TypeFunctions.hasClassFlag(c.superClass.c, CExtern) && HxGen.isHxGen(TClassDecl(c.superClass.c)))
			throw new Unsupported("classes extending an extern class marked @:hxGen", true);
		var split = model && !HxGen.descendsFromNative(c);
		if (model && c.superClass == null && DotnetTypes.haxePath(TClassDecl(c)) != DotnetCtx.hxObjectPath)
			superSig = LClass(g.types.stdClassPath(DotnetCtx.hxObjectPath, "haxe.lang.HxObject", false), []);
		var interfaces = interfaceClosure(g, c);
		var impls = isInterface ? null : interfaceImpls(g, c, interfaces);
		var implementing = impls == null ? new ObjectMap<TClassField, Bool>() : impls.own;
		var props = isInterface ? null : planProperties(g, c, interfaces, implementing);
		var events = EventToIl.planEvents(g, c, implementing);
		var path = DotnetNames.typePath(TClassDecl(c));
		inline function site(name:String):AttributesToIl.AttrSite return {name: name, ns: path.ns};

		var fields:Array<FieldPlan> = [];
		// The CLR properties of the class's @:property vars (planVarProperty): the statics', then the instance
		// vars', each in declaration order, as gencs writes them around its own properties.
		var varProps = new ObjectMap<TClassField, PropertyPlan>();
		var staticProps:Array<PropertyPlan> = [], instanceProps:Array<PropertyPlan> = [];
		function addFields(list:Array<TClassField>, isStatic:Bool) {
			for (cf in list) {
				if (TypeFunctions.hasClassFieldFlag(cf, CfExtern)) continue;
				// An @:event var is no field: its event has accessors (EventToIl), over a private backing field when
				// it is field-like.
				var event = events == null ? null : events.vars.get(cf);
				if (event != null) {
					// C# has no initializer for an event with accessors of its own (CS0079), and hxc would drop
					// a static one's.
					if (!event.fieldLike && cf.expr != null) throw at(EventToIl.noValue(c, cf), cf.expr.pos);
					if (event.backing != null) fields.push(event.backing);
					continue;
				}
				// gencs's gen_prop makes a static property of a static @:property var with an accessor, its
				// accessors private static _get_X/_set_X; hxc does not write one yet.
				if (isStatic && !TypeFunctions.isPhysicalField(cf) && isCallVar(cf) && TypeFunctions.hasMeta(":property", cf.meta))
					throw new Unsupported("static @:property variables with get or set accessors", true, cf.pos);
				if (!TypeFunctions.isPhysicalField(cf)) continue;
				// As gencs's InterfaceVarsDeleteModf leaves them off, an interface has no fields, which a CLR
				// interface cannot have: its variables and dynamic methods are reached through Runtime
				// (TexprDynamic.isInterfaceField), its properties' accessors are its methods.
				if (isInterface && !isStatic) continue;
				try {
					switch (cf.kind) {
						case Var(_):
							// C# has no field initializers in structs, and gencs moves none into their constructors.
							if (isStruct && !isStatic && cf.expr != null) throw new Unsupported("instance variable initializers in structs", true);
							if (TypeFunctions.hasMeta(":property", cf.meta)) {
								var f = planVarProperty(g, c, cf, isStatic);
								fields.push(f);
								varProps.set(cf, f.property);
								(isStatic ? staticProps : instanceProps).push(f.property);
								continue;
							}
						case Method(MethDynamic):
							// A field of type haxe.lang.Function, which an override sets again (fieldInits).
							if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)) continue;
							if (isStruct && !isStatic) throw new Unsupported("dynamic methods in structs", true);
						case Method(_):
							continue;
					}
					var pseudo = AttributesToIl.pseudo(g, cf.meta, AttrTarget.TField, cf.pos, site(cf.name));
					// hxcs's Closure has no invoker: Haxe's reflection, which reads public fields, must not see it.
					var isInvoker = cf.name == "__hx_invoker" && c == g.runtimeClass("cs.internal.Closure");
					fields.push({
						cf: cf,
						name: DotnetNames.fieldName(c, cf.name),
						flags: (isInvoker ? FieldAttrs.FAMILY : FieldAttrs.PUBLIC) | (isStatic ? FieldAttrs.STATIC : 0) | pseudo.fieldFlags
							| (isStruct && c == g.runtimeClass("cs.internal._Null.Nullable") ? FieldAttrs.INIT_ONLY : 0),
						sig: g.types.toSig(cf.type),
						offset: pseudo.offset
					});
				} catch (u:Unsupported) throw at(u, cf.pos);
			}
		}
		addFields(c.orderedFields, false);
		addFields(c.orderedStatics, true);

		var renamed = renamedTypeParams(c);
		var methods:Array<MethodPlan> = [];
		// gencs's order (C# source order, which Roslyn keeps): the entry point, the static constructor, the
		// constructors, the static events, __hx_ctor_*, the statics, then the instance members.
		if (g.mainClass == c && c.path.name != "Main") methods.push(entryPoint(c.pos));
		var hasCctor = c.init != null;
		for (f in fields) if (f.flags & FieldAttrs.STATIC != 0 && f.cf.expr != null) hasCctor = true;
		if (hasCctor) {
			methods.push({
				kind: MCctor,
				name: ".cctor",
				flags: MethodAttrs.PRIVATE | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME,
				hasThis: false,
				ret: LVoid,
				args: [],
				argNames: [],
				generics: [],
				pos: c.pos,
				token: 0
			});
		}
		function addMethod(cf:TClassField, isStatic:Bool, isCtor:Bool) {
			switch (cf.kind) {
				case Method(MethMacro | MethDynamic): return;
				case Method(_):
				case Var(_):
					// A @:property var's accessors, where C# has its auto-property.
					var p = varProps.get(cf);
					if (p != null) {
						methods.push(p.getter);
						methods.push(p.setter);
					}
					return;
			}
			if (TypeFunctions.hasClassFieldFlag(cf, CfExtern)) return;
			// An @:overload method is one MethodDef per overload.
			for (f in [cf].concat(cf.overloads)) try {
				var isAbstract = isInterface || TypeFunctions.hasClassFieldFlag(f, CfAbstract);
				if (f.expr == null && !isAbstract) continue;
				// A generic interface's method that mentions no type parameter is its companion's.
				if (isInterface && CompanionToIl.isMember(g, c, f)) continue;
				var sig = g.types.withParams(c.params, f.params, () -> functionSig(g, f.type));
				if (isCtor && isStruct && sig.args.length == 0) {
					// As in gencs, a struct's constructor without arguments is the default one; it must be empty.
					if (!isEmpty(f.expr)) throw new Unsupported("struct constructors without arguments that do something", true);
					continue;
				}
				if (isCtor && !isStruct && !hasSuperCall(f.expr)) checkParameterlessBase(g, c);
				// The body of a property's accessor, which takes no slot: its public accessor does.
				var prop = isStatic || props == null ? null : props.bodies.get(f);
				// And of an event's, static or not (EventToIl).
				var event = events == null ? null : events.bodies.get(f);
				// An interface's and a field-like event's add_X and remove_X are the accessors.
				if (event != null && EventToIl.isReplaced(event)) continue;
				var shape = prop == null && event == null && !isStatic && !isCtor && !isInterface && isOverride(f) ? overrideShape(g, c, TypeFunctions.extractParamTypes(c.params), f, sig) : OSame;
				var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG;
				if (prop != null) flags = MethodAttrs.PRIVATE | MethodAttrs.HIDE_BY_SIG;
				else if (event != null) flags = MethodAttrs.PRIVATE | MethodAttrs.HIDE_BY_SIG | (isStatic ? MethodAttrs.STATIC : 0);
				else if (isStatic) flags |= MethodAttrs.STATIC;
				else if (isCtor) flags |= MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME;
				else flags |= virtuality(c, f, isStruct, implementing.exists(f) || CompanionToIl.isMember(g, c, f), !shape.match(OOverload(_)));
				var name = isCtor ? ".ctor" : prop != null || event != null ? "_" + f.name : DotnetNames.fieldName(c, f.name);
				var generics = renamed.get(f);
				if (!shape.match(OSame) && TypeFunctions.hasClassFieldFlag(f, CfAbstract))
					throw new Unsupported("abstract overrides that change the signature", true);
				// The overloads an erased interface needs of the method, which gencs writes in front of it.
				var made = impls == null ? null : impls.overloads.get(f);
				if (made != null) for (b in made) methods.push(bridgeMethod(g, c, b));
				switch (shape) {
					case OSame:
						if (prop == null && event == null && f == cf && cf.overloads.length == 0) for (o in optionalOverloads(g, c, f, flags, name, isStatic, isCtor, sig)) methods.push(o);
						var m:MethodPlan = {
							kind: MField(f),
							name: name,
							flags: flags,
							hasThis: !isStatic,
							ret: isCtor ? LVoid : sig.ret,
							args: sig.args,
							argNames: sig.names,
							generics: generics,
							pos: f.pos,
							token: 0
						};
						methods.push(m);
						if (prop != null) {
							if (f.name.charAt(0) == "s") prop.setBody = m else prop.getBody = m;
						}
						if (event != null) EventToIl.setBody(event, f, m);
					case OInline(slot):
						methods.push({
							kind: MField(f),
							name: name,
							flags: flags,
							hasThis: true,
							ret: slot.ret,
							args: slot.args,
							argNames: tempNames(g, sig, slot),
							generics: generics,
							pos: f.pos,
							token: 0,
							ownArgs: sig.args
						});
					case OOverload(slot):
						// The override first, as gencs writes the overload it adds in front of the method.
						methods.push({
							kind: MBridge(f),
							name: name,
							flags: MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.VIRTUAL,
							hasThis: true,
							ret: slot.ret,
							args: slot.args,
							argNames: tempNames(g, sig, slot),
							generics: generics,
							pos: f.pos,
							token: 0
						});
						methods.push({
							kind: MField(f),
							name: name,
							flags: flags,
							hasThis: true,
							ret: sig.ret,
							args: sig.args,
							argNames: sig.names,
							generics: generics,
							pos: f.pos,
							token: 0
						});
				}
			} catch (u:Unsupported) throw at(u, f.pos);
		}
		var ctors:Null<Array<CtorPlan>> = null;
		var emptyCtor:Null<MethodPlan> = null;
		var staticCtors:Array<MethodPlan> = [];
		if (model) {
			emptyCtor = ctorMethod(MEmptyCtor, [g.emptyObjectSig()], ["empty"], MethodAttrs.PUBLIC, c.pos);
			methods.push(emptyCtor);
			ctors = [];
			for (hc in HxGen.ctors(c)) try {
				var pos = hc.own != null ? hc.own.pos : c.pos;
				var args = [for (a in hc.args) g.types.argSig(a.t, a.opt)];
				var names = [for (a in hc.args) a.name];
				var kind = if (split) {
					MSplitCtor(hc);
				} else if (hc.own != null) {
					if (!hasSuperCall(hc.own.expr)) checkParameterlessBase(g, c);
					MField(hc.own);
				} else if (hc.clone) {
					MClonedCtor(hc);
				} else {
					checkParameterlessBase(g, c);
					MImplicitCtor;
				}
				// A constructor cloned from a protected one stays protected, as gencs keeps @:protected.
				var access = hc.own == null && hc.origin != null && TypeFunctions.hasMeta(":protected", hc.origin.meta) ? MethodAttrs.FAMILY : MethodAttrs.PUBLIC;
				var real = ctorMethod(kind, args, names, access, pos);
				methods.push(real);
				var stat:Null<MethodPlan> = null;
				if (split) {
					// In a generic class, the static constructor has the class's type parameters as its own.
					var self = g.types.withParams([], c.params, () -> g.types.toSig(TInst(c, TypeFunctions.extractParamTypes(c.params))));
					var statArgs = g.types.withParams([], c.params, () -> [for (a in hc.args) g.types.argSig(a.t, a.opt)]);
					stat = {
						kind: MStaticCtor(hc),
						name: HxGen.ctorName(c),
						flags: (TypeFunctions.hasClassFlag(c, CFinal) ? MethodAttrs.PRIVATE : MethodAttrs.FAMILY) | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG,
						hasThis: false,
						ret: LVoid,
						args: [self].concat(statArgs),
						argNames: ["__hx_this"].concat(names),
						generics: [for (p in c.params) p.name + "_c"],
						pos: pos,
						token: 0
					};
					staticCtors.push(stat);
				}
				ctors.push({hx: hc, real: real, stat: stat});
			} catch (u:Unsupported) throw at(u, hc.own != null ? hc.own.pos : c.pos);
		} else if (c.constructor != null && !TypeFunctions.hasClassFieldFlag(c.constructor, CfExtern)) {
			addMethod(c.constructor, false, true);
		} else if (!isInterface && !isStruct) {
			checkParameterlessBase(g, c);
			methods.push(implicitCtor(c.pos, TypeFunctions.hasClassFlag(c, CAbstract)));
		}
		// gencs writes the static events, then __hx_ctor_*, then the statics, after the constructors. A static
		// @:property var's auto-property accessors are among the statics, in declaration order (gencs dumps with
		// the var before and after a static method). The accessors of a static property with get/set methods
		// would come before __hx_ctor_* (`get_sp, __hx_ctor__G, __hx_cast, st, _get_sp`), but hxc refuses those.
		if (events != null) for (e in events.list) if (e.isStatic) {
			methods.push(e.adder);
			methods.push(e.remover);
		}
		// gencs adds each overload's static constructor in front of the earlier ones, after the main one:
		// the overloads come in reverse, the main one (listed last) still last.
		if (staticCtors.length > 1) {
			var main = staticCtors.pop();
			staticCtors.reverse();
			staticCtors.push(main);
		}
		for (m in staticCtors) methods.push(m);
		if (isStruct && impls != null && (impls.bridges.length > 0 || impls.overloads.keys().hasNext()))
			throw new Unsupported("interface methods implemented with other types", true);
		var casts = CompanionToIl.castMethods(g, c);
		for (m in casts) if (!m.hasThis) methods.push(m);
		for (cf in c.orderedStatics) addMethod(cf, true, false);
		// Then the instance events, then the properties.
		if (events != null) for (e in events.list) if (!e.isStatic) {
			methods.push(e.adder);
			methods.push(e.remover);
		}
		if (props != null) for (p in props.list) {
			if (p.getter != null) methods.push(p.getter);
			if (p.setter != null) methods.push(p.setter);
		}
		// gencs adds each bridge in front of the class's fields, so the last one made comes first, after
		// the static __hx_cast and before the cast methods.
		if (impls != null) for (b in impls.bridges) methods.push(bridgeMethod(g, c, b));
		for (m in casts) if (m.hasThis) methods.push(m);
		for (cf in c.orderedFields) addMethod(cf, false, false);
		for (r in ReflectionMembers.members(g, c)) methods.push(ReflectionMembers.plan(g, c, r));
		// gencs's indexers, after the reflection members and before ToString.
		var indexers = IndexerToIl.plan(g, c, methods);
		for (p in indexers) {
			if (p.getter != null) methods.push(p.getter);
			if (p.setter != null) methods.push(p.setter);
		}
		var toString = isInterface ? null : c.fields.get("toString");
		if (toString != null && wrapsToString(g, c, toString)) {
			methods.push({
				kind: MToString(toString),
				name: "ToString",
				flags: MethodAttrs.PUBLIC | MethodAttrs.VIRTUAL | MethodAttrs.HIDE_BY_SIG,
				hasThis: true,
				ret: LString,
				args: [],
				argNames: [],
				generics: [],
				pos: toString.pos,
				token: 0
			});
		}
		if (c == g.runtimeClass("Array")) for (m in arrayIdentity(c)) methods.push(m);
		// gencs's Null<T> has these two ahead of its ToString and constructor.
		if (isStruct && c == g.runtimeClass("cs.internal._Null.Nullable")) {
			var surface = nullSurface(c, g.types.toSig(TInst(c, TypeFunctions.extractParamTypes(c.params))));
			var slot = 0;
			for (m in surface) methods.insert(slot++, m);
		}

		checkDistinctSignatures(methods);

		var flags = TypeAttrs.PUBLIC;
		if (isInterface) {
			flags |= TypeAttrs.INTERFACE | TypeAttrs.ABSTRACT;
		} else {
			if (TypeFunctions.hasClassFlag(c, CAbstract)) flags |= TypeAttrs.ABSTRACT;
			if (TypeFunctions.hasClassFlag(c, CFinal) || isStruct) flags |= TypeAttrs.SEALED;
			if (isStruct) flags |= TypeAttrs.SEQUENTIAL;
			if (!hasCctor) flags |= TypeAttrs.BEFORE_FIELD_INIT;
		}
		var target = isInterface ? AttrTarget.TInterface : isStruct ? AttrTarget.TStruct : AttrTarget.TType;
		var pseudo = AttributesToIl.pseudo(g, c.meta, target, c.pos, site(c.path.name));
		// A StructLayout's layout replaces C#'s default: Sequential for a struct, Auto for a class.
		if (pseudo.layout != null) flags &= ~TypeAttrs.LAYOUT_MASK;
		flags |= pseudo.typeFlags;
		return {
			c: c,
			hxPath: DotnetTypes.haxePath(TClassDecl(c)),
			path: path,
			flags: flags,
			superSig: superSig,
			interfaces: CompanionToIl.addInterfaces(g, c, [for (i in interfaces) i.c], [for (i in interfaces) i.sig]),
			fields: fields,
			methods: methods,
			classParams: c.params,
			isStd: isStd,
			thisSig: g.types.toSig(TInst(c, TypeFunctions.extractParamTypes(c.params))),
			isStruct: isStruct,
			initFlag: hasCctor && c.params.length > 0,
			ctors: ctors,
			emptyCtor: emptyCtor,
			properties: staticProps.concat(props == null ? [] : props.list).concat(instanceProps).concat(indexers),
			events: events == null ? [] : events.list,
			token: 0,
			layout: pseudo.layout
		};
	}

	// A physical @:property var as gencs writes it, a C# auto-property (`public T X { get; set; }`, its
	// initializer moved into the constructor or the static constructor): Roslyn's private backing field
	// `<X>k__BackingField`, public non-virtual accessors get_X and set_X that read and write it, and a Property
	// row. Returns the backing field's plan, its `property` the PropertyPlan. C# reserves the accessors' names,
	// so gencs's C# for a class that declares get_X or set_X beside the var fails (CS0082).
	static function planVarProperty(g:DotnetCtx, c:TClass, cf:TClassField, isStatic:Bool):FieldPlan {
		for (prefix in ["get_", "set_"])
			if (c.fields.exists(prefix + cf.name) || c.statics.exists(prefix + cf.name))
				throw Unsupported.error("the @:property variable " + cf.name + " cannot have a method " + prefix + cf.name
					+ " beside it: its CLR property's accessor has that name");
		var name = DotnetNames.fieldName(c, cf.name);
		var sig = g.types.toSig(cf.type);
		var p:PropertyPlan = {
			cf: cf,
			name: name,
			sig: sig,
			index: [],
			getBody: null,
			setBody: null,
			getter: null,
			setter: null,
			token: 0,
			isStatic: isStatic
		};
		var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | (isStatic ? MethodAttrs.STATIC : 0);
		function accessor(isSet:Bool):MethodPlan {
			return {
				kind: MPropertyAccessor(p, isSet),
				name: (isSet ? "set_" : "get_") + name,
				flags: flags,
				hasThis: !isStatic,
				ret: isSet ? LVoid : sig,
				args: isSet ? [sig] : [],
				argNames: isSet ? ["value"] : [],
				generics: [],
				pos: cf.pos,
				token: 0
			};
		}
		p.getter = accessor(false);
		p.setter = accessor(true);
		p.backing = {
			cf: cf,
			name: "<" + name + ">k__BackingField",
			flags: FieldAttrs.PRIVATE | (isStatic ? FieldAttrs.STATIC : 0),
			sig: sig,
			property: p
		};
		return p.backing;
	}

	// Two methods of one name, static-ness, generic arity and CLR signature are invalid metadata (ECMA-335
	// II.22.26), and a call through Dynamic could reach either. Erasure gives two overloads one signature
	// when their Haxe types differ only in type arguments: `f(a:Array<C>)` and `f(a:Array<D>)` are both
	// ``f(Array`1<object>)``. gencs's C# for them fails with CS0111. Constructors count too, and so do the
	// members of a generic interface's companion (CompanionToIl.declare).
	public static function checkDistinctSignatures(methods:Array<MethodPlan>):Void {
		for (j in 1...methods.length) {
			var b = methods[j];
			for (i in 0...j) {
				var a = methods[i];
				if (a.name != b.name || a.hasThis != b.hasThis || a.generics.length != b.generics.length) continue;
				if (!IlPaths.sigEq(a.ret, b.ret) || !IlPaths.sigsEq(a.args, b.args)) continue;
				var name = switch (b.kind) {
					case MField(cf): cf.name;
					case _: b.name == ".ctor" ? "new" : b.name;
				}
				// At the later of the two in the source (constructors' overloads are planned last first).
				var pos = a.pos != null && b.pos != null && a.pos.file == b.pos.file && a.pos.min > b.pos.min ? a.pos : b.pos;
				throw new Unsupported("overloads that type-argument erasure makes identical (" + name + ")", true, pos);
			}
		}
	}

	// The interfaces the class lists and the ones they extend, as C# writes them all on the type. As
	// gencs makes them, an interface in its model extends haxe.lang.IHxObject, and so does a class in it
	// whose members are the first of the hierarchy (ReflectionMembers.isRoot).
	static function interfaceClosure(g:DotnetCtx, c:TClass):Array<ImplementedInterface> {
		var r:Array<ImplementedInterface> = [];
		var ihx = g.runtimeClass("cs.internal.IHxObject");
		function extendsIHxObject(i:TClass):Bool {
			return ihx != null && i != ihx && TypeFunctions.hasClassFlag(i, CInterface) && !TypeFunctions.hasClassFlag(i, CExtern)
				&& HxGen.isHxGen(TClassDecl(i));
		}
		function add(i:TClass, params:Array<T>) {
			// An extern interface with no .NET counterpart is only a Haxe type.
			if (TypeFunctions.hasClassFlag(i, CExtern) && !g.ctx.netDottedMap.exists(Globals.sTypePath(i.path))
				&& DotnetNames.nativeName(i.meta) == null)
				return;
			var sig = g.types.classSig(i, params);
			for (x in r) if (IlPaths.sigEq(x.sig, sig)) return;
			r.push({c: i, params: params, sig: sig});
			for (sup in i.interfaces) add(sup.c, [for (t in sup.params) TypeFunctions.applyParams(i.params, params, t)]);
			if (extendsIHxObject(i)) add(ihx, []);
		}
		for (i in c.interfaces) add(i.c, i.params);
		if (extendsIHxObject(c) || ihx != null && c != ihx && ReflectionMembers.applies(c) && ReflectionMembers.isRoot(c)) add(ihx, []);
		return r;
	}

	// A method's CLR signature as the instantiation of `owner` with `ownerArgs` (in terms of the class's
	// type parameters) has it: its own signature, in terms of its class's type parameters and its own,
	// with that instantiation's CLR type arguments put in. Erasure can make it differ from the Haxe types
	// applied: G<C>'s `get():T` is ``G`1<object>``'s `object get()`, the slot an override takes.
	static function methodSig(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField):{args:Array<IlSigNorm>, ret:IlSigNorm} {
		var inst = g.types.classArgs(owner, ownerArgs);
		var f = g.types.withParams(owner.params, cf.params, () -> functionSig(g, cf.type));
		return {args: [for (a in f.args) DotnetTypes.substitute(a, inst, [])], ret: DotnetTypes.substitute(f.ret, inst, [])};
	}

	// A method's signature with the Haxe types `ownerArgs` applied, in terms of the class's type
	// parameters and its own.
	static function haxeMethodSig(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField):{args:Array<IlSigNorm>, ret:IlSigNorm} {
		var f = g.types.withParams(g.types.currentClassParams(), cf.params, () -> functionSig(g, TypeFunctions.applyParams(owner.params, ownerArgs, cf.type)));
		return {args: f.args, ret: f.ret};
	}

	static function sameSig(a:{args:Array<IlSigNorm>, ret:IlSigNorm}, b:{args:Array<IlSigNorm>, ret:IlSigNorm}):Bool {
		return IlPaths.sigsEq(a.args, b.args) && IlPaths.sigEq(a.ret, b.ret);
	}

	static function isFinalMethod(c:TClass, cf:TClassField):Bool {
		return TypeFunctions.hasClassFieldFlag(cf, CfFinal) || TypeFunctions.hasClassFlag(c, CFinal) || TypeFunctions.hasMeta(":struct", c.meta)
			|| cf.kind.match(Method(MethInline));
	}

	// The class's own methods that implement an interface method, and the bridges and overloads for
	// interface methods it implements with other types (InterfaceImpls). The CLR matches an
	// implementation by name and exact signature, so an interface method without one it would match throws.
	static function interfaceImpls(g:DotnetCtx, c:TClass, interfaces:Array<ImplementedInterface>):InterfaceImpls {
		var own = new ObjectMap<TClassField, Bool>();
		var bridges:Array<InterfaceBridge> = [];
		var overloads = new ObjectMap<TClassField, Array<InterfaceBridge>>();
		var made:Array<InterfaceBridge> = [];
		var ihx = g.runtimeClass("cs.internal.IHxObject");
		for (i in interfaces) {
			// The reflection members, which the class or HxObject has, implement IHxObject.
			if (i.c == ihx) continue;
			var isExternInterface = TypeFunctions.hasClassFlag(i.c, CExtern);
			// gencs's InterfaceProps makes properties only for an interface converted from a --net-lib; a
			// hand-written extern interface's would be no member of the class, unless its var is @:property.
			if (isExternInterface && !TypeFunctions.hasMeta(":csNative", i.c.meta)) for (im in i.c.orderedFields)
				if (im.kind.match(Var(_)) && !hasPropertyVar(c, im.name))
					throw Unsupported.error("a class cannot implement the property " + im.name + " of the hand-written .NET interface extern "
						+ DotnetTypes.haxePath(TClassDecl(i.c)));
			for (im in i.c.orderedFields) {
				switch (im.kind) {
					case Var(_) if (EventToIl.isEventVar(im)):
						// The interface's event (a Haxe interface's @:event var, or the private one NetConverter makes of
						// a .NET interface's): the class needs an event, whose accessors the methods below match.
						checkEvent(g, c, i, im);
						continue;
					case Var(_) if (isExternInterface):
						if (!isCallVar(im)) throw new Unsupported("variables of .NET interfaces that are neither properties nor events", true);
						checkProperty(g, c, i, im);
						continue;
					case Var(_):
						// A Haxe interface's variable is no member of the CLR interface.
						continue;
					case Method(MethDynamic):
						// Nor is a dynamic method.
						continue;
					case Method(MethMacro):
						continue;
					case Method(_):
				}
				// A property's accessor is implemented by the class's property (checkProperty).
				if (isExternInterface && accessorOf(i.c, im) != null) continue;
				for (f in [im].concat(im.overloads)) {
					var name:String, want:{args:Array<IlSigNorm>, ret:IlSigNorm};
					// Whether erasure makes the interface's CLR signature differ from its Haxe types applied.
					var erased = false;
					if (isExternInterface) {
						var m = g.externs.method(i.c, f, true);
						if (m.genericCount > 0) throw new Unsupported("generic .NET interface methods", true);
						var iargs = switch (i.sig) {
							case LClass(_, l): l;
							case _: [];
						}
						name = m.name;
						want = switch (ExternMembers.subst(m.sig, iargs)) {
							case LMethod(_, r, l): {args: l, ret: r};
							case _: throw "internal error: not a method signature";
						}
					} else {
						name = DotnetNames.fieldName(i.c, f.name);
						want = methodSig(g, i.c, i.params, f);
						erased = !sameSig(want, haxeMethodSig(g, i.c, i.params, f));
					}
					var other = findImplementation(g, c, i.c, f.name, name, want, own);
					if (other == null) continue;
					if (isExternInterface || f.params.length > 0 || other.cf.params.length > 0 || im.overloads.length > 0)
						throw new Unsupported("interface methods implemented with other types", true);
					var found = slotSig(g, other.owner, other.params, other.cf);
					// A Null<T> the interface instantiates with String is a haxe.lang.Null<string> in its CLR
					// signature, which no conversion reaches from a string (gencs's C# for it fails with CS0535).
					var takes = want.args.concat([want.ret]), gives = found.args.concat([found.ret]);
					for (k in 0...takes.length) if (g.types.isNullOf(takes[k]) && !IlPaths.sigEq(takes[k], gives[k]))
						throw new Unsupported("implementations of a generic interface's Null<T> with String (" + DotnetTypes.haxePath(TClassDecl(i.c)) + "."
							+ f.name + ")", true);
					var explicit = IlPaths.sigsEq(found.args, want.args);
					if (!explicit && !erased) throw new Unsupported("interface methods implemented with other parameter types", true);
					var b = {iface: i, im: f, want: want, target: other.cf, owner: other.owner, ownerParams: other.params, explicit: explicit};
					if (!explicit) {
						// One overload of a name and signature, which a superclass may already have, as gencs adds
						// none when the class has one.
						if (hasOverload(made, name, want) || inheritsOverload(g, c, name, want)) continue;
						made.push(b);
						if (other.owner == c) {
							// The last one made comes first.
							var l = overloads.get(other.cf);
							if (l == null) overloads.set(other.cf, l = []);
							l.unshift(b);
							continue;
						}
					}
					bridges.push(b);
				}
			}
		}
		return {own: own, bridges: bridgeOrder(c, bridges), overloads: overloads};
	}

	// A var with a get or set accessor method.
	static function isCallVar(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Var(v): v.read == AccCall || v.write == AccCall;
			case _: false;
		}
	}

	// The var named `name` of `c` or of its nearest superclass that has a field of that name; null when that
	// field is no var or there is none.
	static function findVar(c:TClass, name:String):Null<VarAt> {
		var cur = c;
		var params = TypeFunctions.extractParamTypes(c.params);
		while (cur != null) {
			var cf = cur.fields.get(name);
			if (cf != null) return cf.kind.match(Var(_)) ? {cf: cf, owner: cur, params: params} : null;
			var s = cur.superClass;
			if (s == null) break;
			params = [for (t in s.params) TypeFunctions.applyParams(cur.params, params, t)];
			cur = s.c;
		}
		return null;
	}

	// A var of a Haxe class with a get or set accessor that gencs's gen_prop makes a property of: one marked
	// @:property (ruling T), or one InterfaceProps marks, whose name an interface the class lists itself
	// declares as such a var, when that interface was converted from a --net-lib. It becomes a property
	// unless it is physical (a physical @:property var is an auto-property, planVarProperty; gencs's C# for
	// a physical one implementing a .NET interface property fails, checkProperty).
	static function isPropertyVar(owner:TClass, cf:TClassField):Bool {
		if (TypeFunctions.hasClassFlag(owner, CInterface) || TypeFunctions.hasClassFlag(owner, CExtern) || !isCallVar(cf)) return false;
		if (TypeFunctions.hasMeta(":property", cf.meta)) return true;
		for (i in owner.interfaces) {
			if (!TypeFunctions.hasMeta(":csNative", i.c.meta)) continue;
			var iv = i.c.fields.get(cf.name);
			if (iv != null && isCallVar(iv)) return true;
		}
		return false;
	}

	// The property var the method `cf` of `c` is an accessor of, as gencs's partition finds it: a get_X or
	// set_X method of the class, X a property var of the class or a superclass (for a converted .NET
	// interface, a var of it with an accessor); null when there is none.
	static function accessorOf(c:TClass, cf:TClassField):Null<VarAt> {
		if (!cf.kind.match(Method(_)) || cf.name.length <= 4) return null;
		var prefix = cf.name.substr(0, 4);
		if (prefix != "get_" && prefix != "set_") return null;
		var v = findVar(c, cf.name.substr(4));
		if (v == null) return null;
		if (TypeFunctions.hasClassFlag(c, CExtern)) return TypeFunctions.hasMeta(":csNative", c.meta) && isCallVar(v.cf) ? v : null;
		if (isExternPropertyOverride(v, cf)) return v;
		return isPropertyVar(v.owner, v.cf) && !TypeFunctions.isPhysicalField(v.cf) ? v : null;
	}

	// Whether the class or a Haxe superclass has the variable `name` marked @:property.
	static function hasPropertyVar(c:TClass, name:String):Bool {
		var v = findVar(c, name);
		return v != null && !TypeFunctions.hasClassFlag(v.owner, CExtern) && TypeFunctions.hasMeta(":property", v.cf.meta);
	}

	// An @:property override of the accessor of a .NET base class's property, the var `v` a hand-written extern's:
	// gencs writes `override T X { get { return _get_X(); } }`.
	static function isExternPropertyOverride(v:VarAt, cf:TClassField):Bool {
		return TypeFunctions.hasClassFlag(v.owner, CExtern) && isCallVar(v.cf) && TypeFunctions.hasMeta(":property", cf.meta)
			&& TypeFunctions.hasClassFieldFlag(cf, CfOverride);
	}

	// The class's implementation of the .NET interface property `iv` of `i`: a property var of the class or a
	// superclass, of the interface property's type, whose class declares the accessors the interface has.
	// gencs's C# fails to compile each other shape (CS0535, CS0738).
	static function checkProperty(g:DotnetCtx, c:TClass, i:ImplementedInterface, iv:TClassField):Void {
		var v = findVar(c, iv.name);
		if (v == null) throw new Unsupported("abstract classes that leave interface methods unimplemented", true);
		if (TypeFunctions.hasClassFlag(v.owner, CExtern)) {
			checkBaseProperty(g, c, i, iv);
			return;
		}
		var iname = DotnetTypes.haxePath(TClassDecl(i.c));
		var what = " (" + iname + "." + iv.name + ")";
		if (TypeFunctions.isPhysicalField(v.cf))
			throw at(Unsupported.error("a physical variable cannot implement the .NET interface property " + iname + "." + iv.name), v.cf.pos);
		if (!isPropertyVar(v.owner, v.cf))
			throw at(Unsupported.error(iv.name + " implements the .NET interface property " + iname + "." + iv.name
				+ ", so the class declaring it must list " + iname + " itself"), v.cf.pos);
		var want = g.types.toSig(TypeFunctions.applyParams(i.c.params, i.params, iv.type));
		var have = g.types.toSig(TypeFunctions.applyParams(v.owner.params, v.params, v.cf.type));
		if (!IlPaths.sigEq(want, have))
			throw at(Unsupported.error(iv.name + " is of another type than the .NET interface property " + iname + "." + iv.name + " it implements"),
				v.cf.pos);
		switch (iv.kind) {
			case Var(a):
				for (prefix in [a.read == AccCall ? "get_" : null, a.write == AccCall ? "set_" : null]) {
					if (prefix == null) continue;
					var m = v.owner.fields.get(prefix + iv.name);
					if (m == null || !m.kind.match(Method(_)) || TypeFunctions.hasClassFieldFlag(m, CfExtern))
						throw new Unsupported(".NET interface properties whose " + prefix + iv.name + " the class of their variable does not declare" + what,
							true, v.cf.pos);
				}
			case _:
		}
	}

	// The class's implementation of the event `iv` of the interface `i`, a Haxe interface's or a .NET one's: an
	// @:event var of the class, whose accessors the class's add_ and remove_ methods implement (findImplementation
	// matches the interface's methods like any other's). The event of a .NET base class is the base's, which
	// findImplementation checks the accessors of. gencs's C# fails to compile a plain var (CS0535, CS0470) and a
	// @:protected one (CS0737; @:private and @:internal, which gencs's C# refuses the same, are ignored here as on
	// every member); a
	// superclass's event has accessors that are not virtual, unless that superclass lists the interface itself,
	// and C# adds a forwarding stub for them, which hxc does not write yet (ruling S).
	static function checkEvent(g:DotnetCtx, c:TClass, i:ImplementedInterface, iv:TClassField):Void {
		var v = findVar(c, iv.name);
		if (v == null) throw new Unsupported("abstract classes that leave interface methods unimplemented", true);
		if (TypeFunctions.hasClassFlag(v.owner, CExtern)) return;
		var iname = DotnetTypes.haxePath(TClassDecl(i.c));
		if (!EventToIl.isEventVar(v.cf))
			throw at(Unsupported.error(DotnetTypes.haxePath(TClassDecl(v.owner)) + "." + iv.name + " implements the event " + iname + "." + iv.name
				+ ", so it must be an @:event var (gencs: C# error CS0535)"), v.cf.pos);
		// The accessors of a @:protected event are Family, which implement no interface method.
		if (TypeFunctions.hasMeta(":protected", v.cf.meta))
			throw at(Unsupported.error(DotnetTypes.haxePath(TClassDecl(v.owner)) + "." + iv.name + " implements the event " + iname + "." + iv.name
				+ ", so it cannot be @:protected (gencs: C# error CS0737)"), v.cf.pos);
		function lists(owner:TClass):Bool {
			for (x in owner.interfaces) if (x.c == i.c || lists(x.c)) return true;
			return false;
		}
		if (v.owner != c && !lists(v.owner))
			throw at(new Unsupported("an interface event (" + iname + "." + iv.name + ") implemented by the non-virtual event of the superclass "
				+ DotnetTypes.haxePath(TClassDecl(v.owner)), false), v.cf.pos);
	}

	// The .NET interface property `iv` of `i` implemented by the .NET base class's property, of which the CLR
	// maps each accessor the interface declares to a public virtual method of the base of exactly its
	// signature when it loads the class. For a non-virtual one C# adds a forwarding stub, which hxc does not
	// write yet (ruling S).
	static function checkBaseProperty(g:DotnetCtx, c:TClass, i:ImplementedInterface, iv:TClassField):Void {
		var base = c, params = TypeFunctions.extractParamTypes(c.params);
		while (!TypeFunctions.hasClassFlag(base, CExtern)) {
			var s = base.superClass;
			params = [for (t in s.params) TypeFunctions.applyParams(base.params, params, t)];
			base = s.c;
		}
		var baseArgs = [for (t in params) g.types.toSig(t)];
		var iargs = switch (i.sig) {
			case LClass(_, l): l;
			case _: [];
		}
		var t:Null<IlSigNorm> = null;
		switch (iv.kind) {
			case Var(a):
				for (prefix in [a.read == AccCall ? "get_" : null, a.write == AccCall ? "set_" : null]) {
					if (prefix == null) continue;
					var acc = i.c.fields.get(prefix + iv.name);
					var name:String, sig:IlSigNorm;
					if (acc != null && acc.kind.match(Method(_))) {
						var m = g.externs.method(i.c, acc, true);
						name = m.name;
						sig = ExternMembers.subst(m.sig, iargs);
					} else {
						if (t == null) t = g.types.toSig(TypeFunctions.applyParams(i.c.params, i.params, iv.type));
						name = prefix + ExternMembers.memberName(iv);
						sig = prefix == "get_" ? LMethod([], t, []) : LMethod([], LVoid, [t]);
					}
					if (!g.externs.inheritsVirtual(base, baseArgs, name, sig))
						throw new Unsupported("a .NET interface property (" + DotnetTypes.haxePath(TClassDecl(i.c)) + "." + iv.name
							+ ") implemented by a non-virtual property of the .NET base class " + DotnetTypes.haxePath(TClassDecl(base)), false);
				}
			case _:
		}
	}

	// The class's CLR properties (PropertyPlan), in gencs's order: those whose var a superclass declares and
	// whose accessors the class overrides, by their last accessor in the class, then the class's own, last
	// declared first; and the property of each accessor body (`bodies`).
	static function planProperties(g:DotnetCtx, c:TClass, interfaces:Array<ImplementedInterface>,
			implementing:ObjectMap<TClassField, Bool>):{list:Array<PropertyPlan>, bodies:ObjectMap<TClassField, PropertyPlan>} {
		var bodies = new ObjectMap<TClassField, PropertyPlan>();
		var found = new Map<String, {v:VarAt, get:Null<TClassField>, set:Null<TClassField>}>();
		var inherited:Array<String> = [];
		var n = c.orderedFields.length;
		for (k in 0...n) {
			var cf = c.orderedFields[n - 1 - k];
			var v = accessorOf(c, cf);
			if (v == null || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) continue;
			if (cf.overloads.length > 0 || cf.params.length > 0 || !cf.kind.match(Method(MethNormal | MethInline))
				|| TypeFunctions.hasClassFieldFlag(cf, CfAbstract))
				throw new Unsupported("accessors of .NET interface properties that are overloaded, generic, dynamic or abstract", true, cf.pos);
			var e = found.get(v.cf.name);
			if (e == null) {
				found.set(v.cf.name, e = {v: v, get: null, set: null});
				if (v.owner != c) inherited.push(v.cf.name);
			}
			if (cf.name.charAt(0) == "g") e.get = cf else e.set = cf;
		}
		var names = inherited.copy();
		names.reverse();
		for (k in 0...n) {
			var cf = c.orderedFields[n - 1 - k];
			var e = found.get(cf.name);
			if (e != null && e.v.cf == cf) names.push(cf.name);
		}
		// For a hxgen generic class gencs's C# fails too (CS0686: the accessor would implement the companion
		// interface's get_X); a @:nativeGen one gencs compiles.
		if (names.length > 0 && c.params.length > 0)
			throw new Unsupported(".NET interface properties and @:property variables with accessors in generic classes", true);
		var list:Array<PropertyPlan> = [];
		for (name in names) {
			var e = found.get(name);
			var sig = g.types.toSig(TypeFunctions.applyParams(e.v.owner.params, e.v.params, e.v.cf.type));
			for (body in [e.get, e.set]) {
				if (body == null) continue;
				var f = functionSig(g, body.type);
				if (body == e.get ? f.args.length != 0 || !IlPaths.sigEq(f.ret, sig) : f.args.length != 1 || !IlPaths.sigEq(f.args[0], sig))
					throw at(Unsupported.error(body.name + " is of another type than its .NET interface property " + name), body.pos);
			}
			// gen_prop: an override when an accessor is one; else virtual when neither the class, the var nor
			// an accessor is final and both accessors are there.
			var isOverride = e.get != null && TypeFunctions.hasClassFieldFlag(e.get, CfOverride)
				|| e.set != null && TypeFunctions.hasClassFieldFlag(e.set, CfOverride);
			if (isOverride && e.v.owner == c) throw new Unsupported("accessors of .NET interface properties that override a method", true);
			// C# overrides a property only when its base declares it virtual (gencs's C# fails with CS0506).
			// A .NET base's accessor is its method, which must be virtual and of the override's signature (CS0506).
			if (TypeFunctions.hasClassFlag(e.v.owner, CExtern)) {
				for (body in [e.get, e.set])
					if (body != null) overrideShape(g, c, TypeFunctions.extractParamTypes(c.params), body, functionSig(g, body.type));
			} else if (isOverride && !isVirtualProperty(e.v.owner, e.v.cf, ownMethod(e.v.owner, "get_" + name), ownMethod(e.v.owner, "set_" + name))) {
				var o = e.get != null && TypeFunctions.hasClassFieldFlag(e.get, CfOverride) ? e.get : e.set;
				throw at(Unsupported.error(o.name + " cannot override the accessor of the non-virtual .NET interface property " + name), o.pos);
			}
			var isVirtual = isVirtualProperty(c, e.v.cf, e.get, e.set);
			var p:PropertyPlan = {
				cf: e.v.cf,
				name: name,
				sig: sig,
				index: [],
				getBody: null,
				setBody: null,
				getter: null,
				setter: null,
				token: 0
			};
			function accessor(body:TClassField, isSet:Bool):MethodPlan {
				var protected = TypeFunctions.hasClassFlag(e.v.owner, CExtern) && TypeFunctions.hasMeta(":protected", body.meta);
				var flags = (protected ? MethodAttrs.FAMILY : MethodAttrs.PUBLIC) | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME;
				if (isOverride) flags |= MethodAttrs.VIRTUAL;
				else if (isVirtual) flags |= MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT;
				// C# makes the accessor of a non-virtual property that implements an interface method final virtual.
				else if (implementing.exists(body) || declaresAccessor(interfaces, body.name))
					flags |= MethodAttrs.VIRTUAL | MethodAttrs.FINAL | MethodAttrs.NEW_SLOT;
				return {
					kind: MPropertyAccessor(p, isSet),
					name: body.name,
					flags: flags,
					hasThis: true,
					ret: isSet ? LVoid : sig,
					args: isSet ? [sig] : [],
					argNames: isSet ? ["value"] : [],
					generics: [],
					pos: body.pos,
					token: 0
				};
			}
			if (e.get != null) {
				p.getter = accessor(e.get, false);
				bodies.set(e.get, p);
			}
			if (e.set != null) {
				// A Haxe interface's set_X returns a value; the setter returns none.
				if (implementing.exists(e.set))
					throw new Unsupported("Haxe interface methods implemented by the setter of a .NET interface property", true, e.set.pos);
				p.setter = accessor(e.set, true);
				bodies.set(e.set, p);
			}
			list.push(p);
		}
		return {list: list, bodies: bodies};
	}

	// The method of that name `c` declares itself, or null.
	static function ownMethod(c:TClass, name:String):Null<TClassField> {
		var cf = c.fields.get(name);
		return cf != null && cf.kind.match(Method(_)) && !TypeFunctions.hasClassFieldFlag(cf, CfExtern) ? cf : null;
	}

	// gen_prop's is_virtual for the property var `cf` of `c` with the accessors `get` and `set` the class
	// declares (fn_is_final: a missing accessor counts as final).
	static function isVirtualProperty(c:TClass, cf:TClassField, get:Null<TClassField>, set:Null<TClassField>):Bool {
		if (get == null || set == null || TypeFunctions.hasClassFieldFlag(cf, CfFinal)) return false;
		return !isFinalMethod(c, get) && !isFinalMethod(c, set);
	}

	// Whether a .NET interface the class implements declares the accessor `name` of one of its properties.
	static function declaresAccessor(interfaces:Array<ImplementedInterface>, name:String):Bool {
		for (i in interfaces) {
			if (!TypeFunctions.hasClassFlag(i.c, CExtern)) continue;
			var m = i.c.fields.get(name);
			if (m != null && accessorOf(i.c, m) != null) return true;
			// A hand-written interface's property need not declare its accessor.
			var v = i.c.fields.get(name.substr(4));
			if (v != null && isCallVar(v)) return true;
		}
		return false;
	}

	// Whether `made` has an overload `name` whose signature, with the class type arguments `inst` put in
	// when given, is `want`.
	static function hasOverload(made:Array<InterfaceBridge>, name:String, want:{args:Array<IlSigNorm>, ret:IlSigNorm}, ?inst:Array<IlSigNorm>):Bool {
		for (b in made) {
			if (b.explicit || DotnetNames.fieldName(b.iface.c, b.im.name) != name) continue;
			var w = inst == null ? b.want : {
				args: [for (a in b.want.args) DotnetTypes.substitute(a, inst, [])],
				ret: DotnetTypes.substitute(b.want.ret, inst, [])
			};
			if (sameSig(w, want)) return true;
		}
		return false;
	}

	// Whether a superclass of `c` has the overload `name` with the signature `want` (in terms of c's type
	// parameters) that an erased interface it implements gave it.
	static function inheritsOverload(g:DotnetCtx, c:TClass, name:String, want:{args:Array<IlSigNorm>, ret:IlSigNorm}):Bool {
		var s = c.superClass;
		if (s == null) return false;
		var params = s.params;
		while (true) {
			var sc = s.c;
			if (TypeFunctions.hasClassFlag(sc, CExtern)) return false;
			if (hasOverload(madeOverloads(g, sc), name, want, g.types.classArgs(sc, params))) return true;
			var next = sc.superClass;
			if (next == null) return false;
			params = [for (t in next.params) TypeFunctions.applyParams(sc.params, params, t)];
			s = {c: next.c, params: params};
		}
	}

	// The overloads that erased interfaces give the class `c`, in terms of its own type parameters (none
	// when it cannot be declared), remembered for the round.
	static function madeOverloads(g:DotnetCtx, c:TClass):Array<InterfaceBridge> {
		var known = g.interfaceOverloads.get(c);
		if (known != null) return known;
		var impls = try g.types.withParams(c.params, [], () -> interfaceImpls(g, c, interfaceClosure(g, c))) catch (_:Unsupported) null;
		var r:Array<InterfaceBridge> = [];
		if (impls != null) {
			for (b in impls.bridges) if (!b.explicit) r.push(b);
			for (l in impls.overloads) r = r.concat(l);
		}
		g.interfaceOverloads.set(c, r);
		return r;
	}

	// The bridges in the order gencs adds them in front of the class's fields: it goes through the
	// interfaces the class lists, each one's own interfaces before its methods, and the last bridge made
	// comes first.
	static function bridgeOrder(c:TClass, bridges:Array<InterfaceBridge>):Array<InterfaceBridge> {
		if (bridges.length == 0) return bridges;
		var made:Array<InterfaceBridge> = [];
		function visit(i:TClass) {
			for (sup in i.interfaces) visit(sup.c);
			for (im in i.orderedFields) for (b in bridges) if (b.im == im && made.indexOf(b) < 0) made.push(b);
		}
		for (i in c.interfaces) visit(i.c);
		made.reverse();
		return made;
	}

	// gencs's overloads of a @:nativeGen class's, or an abstract's implementation class's, method or
	// constructor `f` (its own class's, not a local function's) that has trailing optional arguments and no
	// type parameters of its own: one per optional argument from the last, each taking the parameters before
	// it, the longest first, as gencs writes them in front of the method (gencs.ml:151-205, 2299). Each has
	// the method's flags, as gencs gives its copy of the field the field's own.
	static function optionalOverloads(g:DotnetCtx, c:TClass, f:TClassField, flags:Int, name:String, isStatic:Bool, isCtor:Bool,
			sig:{args:Array<IlSigNorm>, names:Array<String>, ret:IlSigNorm}):Array<MethodPlan> {
		if (!(TypeFunctions.hasMeta(":nativeGen", c.meta) || c.kind.match(KAbstractImpl(_))) || g.closureOwners.exists(c) || f.params.length > 0) return [];
		if (!f.kind.match(Method(MethNormal | MethInline)) || f.expr == null || !f.expr.expr.match(TFunction(_))) return [];
		var args = switch (TypeFunctions.follow(f.type)) {
			case TFun(s): s.args;
			case _: return [];
		}
		var r:Array<MethodPlan> = [];
		var n = args.length;
		while (n > 0 && args[n - 1].opt) {
			n--;
			r.push({
				kind: MOptionalOverload(f, n),
				name: name,
				flags: flags,
				hasThis: !isStatic,
				ret: isCtor ? LVoid : sig.ret,
				args: sig.args.slice(0, n),
				argNames: sig.names.slice(0, n),
				generics: [],
				pos: f.pos,
				token: 0
			});
		}
		return r;
	}

	static function bridgeMethod(g:DotnetCtx, c:TClass, b:InterfaceBridge):MethodPlan {
		var names = switch (TypeFunctions.follow(b.im.type)) {
			case TFun(sig): [for (a in sig.args) a.name];
			case _: throw "internal error: a method without a function type";
		}
		var name = DotnetNames.fieldName(b.iface.c, b.im.name);
		// An overload is virtual, which in a final class C# makes final.
		var flags = if (b.explicit) MethodAttrs.PRIVATE | MethodAttrs.FINAL;
			else MethodAttrs.PUBLIC | (TypeFunctions.hasClassFlag(c, CFinal) ? MethodAttrs.FINAL : 0);
		return {
			kind: MInterfaceBridge(b),
			name: b.explicit ? "global::" + displayName(c, b.iface.sig) + "." + name : name,
			flags: flags | MethodAttrs.VIRTUAL | MethodAttrs.HIDE_BY_SIG | MethodAttrs.NEW_SLOT,
			hasThis: true,
			ret: b.want.ret,
			args: b.want.args,
			argNames: names,
			generics: [],
			pos: b.target.pos,
			token: 0
		};
	}

	// A type as the C# compiler names it in an explicit implementation's name: `pack.I`, its type
	// arguments in angle brackets, a class's type parameters by name.
	public static function displayName(c:TClass, s:IlSigNorm):String {
		return switch (s) {
			case LClass(p, args) | LValueType(p, args):
				var parts = p.ns.concat(p.nested);
				var name = p.name;
				var tick = name.indexOf("`");
				if (tick >= 0) name = name.substr(0, tick);
				parts.push(name);
				parts.join(".") + (args.length == 0 ? "" : "<" + [for (a in args) displayName(c, a)].join(",") + ">");
			case LTypeParam(i): c.params[i].name;
			case LVector(e): displayName(c, e) + "[]";
			case _:
				var p = DotnetTypes.primitivePath(s);
				if (p == null) throw new Unsupported("interface methods implemented with other types", true);
				p.ns.join(".") + "." + p.name;
		}
	}

	// The Haxe name of the field `cf`, which @:native renamed when it has a :realPath.
	static function realName(cf:TClassField):String {
		for (m in cf.meta) if (m.name == ":realPath" && m.params.length == 1) switch (m.params[0].expr) {
			case hxc.ast.Ast.ExprDef.EConst(hxc.ast.Ast.Constant.CString(s, _)): return s;
			case _:
		}
		return cf.name;
	}

	// The method that implements the method of the interface `iface` with the CLR name `name` and signature
	// `want`: null when one has that signature (a method of the class itself goes into `own`), else the method
	// of that name with other types, which a bridge calls. A final or inline method of a superclass with that
	// signature stays the implementation, and is made virtual in its class (inheritedFinals).
	static function findImplementation(g:DotnetCtx, c:TClass, iface:TClass, hxName:String, name:String, want:{args:Array<IlSigNorm>, ret:IlSigNorm},
			own:ObjectMap<TClassField, Bool>):Null<{cf:TClassField, owner:TClass, params:Array<T>}> {
		var cur = c;
		var params = TypeFunctions.extractParamTypes(c.params);
		var other = new Unsupported("interface methods implemented with other types", true);
		while (cur != null) {
			var cf = cur.fields.get(hxName);
			if (cf == null && TypeFunctions.hasClassFlag(cur, CExtern)) for (f in cur.orderedFields) if (realName(f) == hxName) {
				// An extern base method that @:native renames, which Haxe takes as the implementation by its Haxe
				// name; the CLR, and gencs's C# (CS0535), look for the interface method's CLR name.
				throw Unsupported.error("the interface method " + DotnetTypes.haxePath(TClassDecl(iface)) + "." + hxName + " is implemented by "
					+ DotnetTypes.haxePath(TClassDecl(cur)) + "." + hxName + ", whose CLR name " + f.name + " differs from the interface method's "
					+ name);
			}
			if (cf != null) {
				// The .NET base class's own method, which the CLR checks when it loads the type: it maps the
				// interface method to a public virtual method of exactly its signature. For a non-virtual one C#
				// adds a forwarding stub, which hxc does not write yet (ruling S).
				if (TypeFunctions.hasClassFlag(cur, CExtern)) {
					var classArgs = [for (t in params) g.types.toSig(t)];
					return switch (g.externs.inheritedMethod(cur, classArgs, name, LMethod([], want.ret, want.args))) {
						case null: throw other;
						case true: null;
						case false:
							throw new Unsupported("an interface method (" + DotnetTypes.haxePath(TClassDecl(iface)) + "." + hxName
								+ ") implemented by a non-virtual method of the .NET base class " + DotnetTypes.haxePath(TClassDecl(cur)), false);
					}
				}
				if (DotnetNames.fieldName(cur, cf.name) != name) throw other;
				for (f in [cf].concat(cf.overloads)) {
					// An override that took its slot's signature (OInline) has that one, which the interface may want.
					if (!sameSig(slotSig(g, cur, params, f), want)) {
						// If not, it no longer has the one the interface wants.
						if (sameSig(methodSig(g, cur, params, f), want))
							throw new Unsupported("interface methods implemented by overrides that change the signature", true, f.pos);
						continue;
					}
					if (cur == c) own.set(f, true);
					else if (isFinalMethod(cur, f)) g.inheritedFinals.set(f, true);
					return null;
				}
				if (cf.overloads.length > 0 || !cf.kind.match(Method(MethNormal | MethInline))) throw other;
				return {cf: cf, owner: cur, params: params};
			}
			var s = cur.superClass;
			if (s == null) break;
			params = [for (t in s.params) TypeFunctions.applyParams(cur.params, params, t)];
			cur = s.c;
		}
		throw new Unsupported("abstract classes that leave interface methods unimplemented", true);
	}

	// Roslyn's rule for a final or inline method of the program that an interface of a subclass maps to (the
	// classes were all planned, so the base's flags are known to change only now): the method is `virtual final
	// newslot` in its own class, as if it implemented the interface there, and the subclass adds nothing.
	public static function openInheritedFinals(g:DotnetCtx):Void {
		for (p in g.plans) for (m in p.methods) {
			var f = switch (m.kind) {
				case MField(f): f;
				case _: continue;
			}
			if (m.hasThis && m.flags & (MethodAttrs.VIRTUAL | MethodAttrs.STATIC) == 0 && m.flags & 7 == MethodAttrs.PUBLIC && g.inheritedFinals.exists(f))
				m.flags |= MethodAttrs.VIRTUAL | MethodAttrs.FINAL | MethodAttrs.NEW_SLOT;
		}
	}

	// -D dotnet-seal: the assembly is taken to hold every class that extends one of its own, as a program's
	// does. A class no plan extends is sealed, and a virtual method of a class some plan extends is final
	// when no plan below it has a method of that name overriding it (an overload of the name keeps it virtual
	// too). The JIT then calls such a method directly and can inline it, and a test or cast for a sealed class
	// is one comparison of the method table, with or without profiling (ReadyToRun and Native AOT have none).
	// Plans are followed by their base type, not their Haxe superclass: an enum's constructor classes have no
	// TClass and override their enum class's methods. Interface methods and the MethodImpl rows of explicit
	// implementations are left as they are. Another assembly can no longer extend the sealed classes or
	// override the final methods, so this is opt-in.
	public static function sealLeaves(g:DotnetCtx):Void {
		var byPath = new Map<String, ClassPlan>();
		for (p in g.plans) byPath.set(NetConverter.ilpathS(p.path), p);
		function parent(p:ClassPlan):Null<ClassPlan> {
			return switch (p.superSig) {
				case LClass(path, _): byPath.get(NetConverter.ilpathS(path));
				case _: null;
			}
		}
		var extended = new Map<String, Bool>();
		var overridden = new Map<String, Bool>();
		function note(p:ClassPlan, m:Null<MethodPlan>) {
			if (m == null || m.flags & MethodAttrs.VIRTUAL == 0 || m.flags & MethodAttrs.NEW_SLOT != 0) return;
			var s = parent(p);
			while (s != null) {
				overridden.set(NetConverter.ilpathS(s.path) + "::" + m.name, true);
				s = parent(s);
			}
		}
		for (p in g.plans) {
			var s = parent(p);
			if (s != null) extended.set(NetConverter.ilpathS(s.path), true);
			for (m in p.methods) note(p, m);
			for (pr in p.properties) {
				note(p, pr.getter);
				note(p, pr.setter);
			}
		}
		for (p in g.plans) {
			if (p.flags & (TypeAttrs.INTERFACE | TypeAttrs.ABSTRACT | TypeAttrs.SEALED) != 0) continue;
			var own = NetConverter.ilpathS(p.path);
			if (!extended.exists(own)) {
				p.flags |= TypeAttrs.SEALED;
				continue;
			}
			for (m in p.methods)
				if (m.flags & (MethodAttrs.VIRTUAL | MethodAttrs.FINAL | MethodAttrs.ABSTRACT | MethodAttrs.STATIC) == MethodAttrs.VIRTUAL
					&& !overridden.exists(own + "::" + m.name))
					m.flags |= MethodAttrs.FINAL;
		}
	}

	// gencs's modifiers: virtual unless final or inline, override without newslot (unless FixOverrides
	// made the method a new overload: `overrides` false), abstract, and final virtual for a non-virtual
	// method that implements an interface method.
	static function virtuality(c:TClass, cf:TClassField, isStruct:Bool, implementsInterface:Bool, overrides:Bool):Int {
		if (TypeFunctions.hasClassFlag(c, CInterface)) return MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT | MethodAttrs.ABSTRACT;
		var isAbstract = TypeFunctions.hasClassFieldFlag(cf, CfAbstract);
		if (overrides && isOverride(cf)) return MethodAttrs.VIRTUAL | (isAbstract ? MethodAttrs.ABSTRACT : 0);
		if (isAbstract) return MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT | MethodAttrs.ABSTRACT;
		if (!isFinalMethod(c, cf)) return MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT;
		return implementsInterface ? MethodAttrs.VIRTUAL | MethodAttrs.FINAL | MethodAttrs.NEW_SLOT : 0;
	}

	// `override`, and as gencs has it, Equals(Dynamic):Bool and GetHashCode().
	static function isOverride(cf:TClassField):Bool {
		if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)) return true;
		return switch [cf.name, TypeFunctions.follow(cf.type)] {
			case ["Equals", TFun(sig)] if (sig.args.length == 1):
				TypeFunctions.follow(sig.args[0].t).match(TDynamic(_)) && switch (TypeFunctions.follow(sig.ret)) {
					case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Bool";
					case _: false;
				};
			case ["GetHashCode", TFun(sig)]: sig.args.length == 0;
			case _: false;
		}
	}

	// How the override `cf` of `owner` (with type arguments `ownerArgs`, in terms of the class being
	// planned), whose signature is `sig`, takes the slot of the method it overrides. The slot of a .NET
	// method or of an overloaded one is taken only with the same signature; a covariant one would
	// silently become a new method.
	static function overrideShape(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField, sig:{args:Array<IlSigNorm>, ret:IlSigNorm}):OverrideShape {
		var changed = new Unsupported("overrides that change the signature", true);
		var s = owner.superClass;
		if (s == null) return OSame;
		var params = [for (t in s.params) TypeFunctions.applyParams(owner.params, ownerArgs, t)];
		while (true) {
			var base = s.c.fields.get(cf.name);
			if (base != null && base.overloads.length == 0) {
				// An @:overload override of an overloaded method is matched, as gencs's FixOverrides does,
				// with the overloads where they are declared.
				var root = overloadedRoot(s.c, params, base);
				if (root != null) {
					s = root.s;
					params = root.s.params;
					base = root.cf;
				}
			}
			if (base != null) {
				if (TypeFunctions.hasClassFlag(s.c, CExtern)) {
					if (s.c.params.length > 0 || owner.params.length > 0) throw new Unsupported("overriding methods of generic .NET classes", true);
					var m = try g.externs.method(s.c, cf, true) catch (_:Unsupported) throw changed;
					if (!m.isVirtual) throw new Unsupported("overriding a non-virtual .NET method", false);
					var ret = switch (m.sig) {
						case LMethod(_, r, _): r;
						case _: throw "internal error: not a method signature";
					}
					if (!IlPaths.sigEq(ret, sig.ret)) throw changed;
					return OSame;
				}
				if (base.overloads.length > 0) {
					for (f in [base].concat(base.overloads)) if (sameSig(methodSig(g, s.c, params, f), sig)) return OSame;
					// The overload it overrides by Haxe types, whose CLR signature erasure changed (G<C>'s
					// `f(x:T)` is ``G`1<object>``'s `f(object)`): gencs overrides that one with a bridge to the
					// method, which becomes a new overload. With the same parameter types, C#'s covariant return
					// would take the slot instead.
					if (cf.params.length > 0) throw changed;
					var own = haxeMethodSig(g, owner, ownerArgs, cf);
					for (f in [base].concat(base.overloads)) if (f.params.length == 0 && sameSig(haxeMethodSig(g, s.c, params, f), own)) {
						var slot = methodSig(g, s.c, params, f);
						if (IlPaths.sigsEq(slot.args, sig.args)) throw new Unsupported("overrides of overloaded methods that change only the return type", true);
						return OOverload(slot);
					}
					throw changed;
				}
				var slot = slotSig(g, s.c, params, base);
				if (sameSig(slot, sig)) return OSame;
				if (slot.args.length != sig.args.length || slot.ret.match(LVoid) != sig.ret.match(LVoid) || base.params.length != cf.params.length)
					throw changed;
				return contravariant(g, owner, ownerArgs, cf, s.c, params, base) ? OOverload(slot) : OInline(slot);
			}
			var next = s.c.superClass;
			if (next == null) return OSame;
			params = [for (t in next.params) TypeFunctions.applyParams(s.c.params, params, t)];
			s = {c: next.c, params: params};
		}
	}

	// The overload of a superclass that a call of `c`'s @:overload override `cf` reaches when erasure changed
	// the signature of the overload it overrides (OOverload): that overload, whose slot the override's
	// bridge takes, as gencs's typer resolves the call to the overload where it is declared; else null.
	public static function overriddenOverload(g:DotnetCtx, c:TClass, cf:TClassField):Null<TClassField> {
		if (cf.params.length > 0 || cf.overloads.length > 0 || !TypeFunctions.hasClassFieldFlag(cf, CfOverride)
			|| !TypeFunctions.hasClassFieldFlag(cf, CfOverload))
			return null;
		return g.types.withParams(c.params, [], function():Null<TClassField> {
			var own = TypeFunctions.extractParamTypes(c.params);
			var root = overloadedRoot(c, own, cf);
			if (root == null) return null;
			var hx = haxeMethodSig(g, c, own, cf);
			for (f in [root.cf].concat(root.cf.overloads))
				if (f.params.length == 0 && sameSig(haxeMethodSig(g, root.s.c, root.s.params, f), hx))
					return sameSig(methodSig(g, root.s.c, root.s.params, f), methodSig(g, c, own, cf)) ? null : f;
			return null;
		});
	}

	// The field with overloads of a superclass of `c` (which has type arguments `params`, in terms of the
	// class being planned) that `c`'s field `cf` overrides through @:overload overrides, with that class and
	// its type arguments (`cf` itself when it has overloads); null when there is none.
	static function overloadedRoot(c:TClass, params:Array<T>, cf:TClassField):Null<{s:TClassWithParams, cf:TClassField}> {
		var cur = c, f = cf;
		while (f.overloads.length == 0) {
			if (!TypeFunctions.hasClassFieldFlag(f, CfOverride) || !TypeFunctions.hasClassFieldFlag(f, CfOverload)) return null;
			var next:Null<TClassField> = null;
			while (next == null) {
				var s = cur.superClass;
				if (s == null || TypeFunctions.hasClassFlag(s.c, CExtern)) return null;
				params = [for (t in s.params) TypeFunctions.applyParams(cur.params, params, t)];
				cur = s.c;
				next = cur.fields.get(cf.name);
			}
			f = next;
		}
		return {s: {c: cur, params: params}, cf: f};
	}

	// The CLR signature of the method `cf` of `owner`, which an override of it takes: its own, or for an
	// override that took its slot's (OInline), that one.
	static function slotSig(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField):{args:Array<IlSigNorm>, ret:IlSigNorm} {
		var own = methodSig(g, owner, ownerArgs, cf);
		if (!isOverride(cf)) return own;
		return switch (overrideShape(g, owner, ownerArgs, cf, own)) {
			case OInline(slot): slot;
			case _: own;
		}
	}

	// gencs's has_contravariant_args: a parameter of the base method `bf` whose type unifies with the
	// override's and not the other way round. An override parameter whose real type is Dynamic (Dynamic,
	// EnumValue, an anonymous structure) unifies with anything.
	static function contravariant(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField, base:TClass, baseArgs:Array<T>,
			bf:TClassField):Bool {
		function args(t:T):Array<T> {
			return switch (TypeFunctions.follow(t)) {
				case TFun(sig): [for (a in sig.args) a.t];
				case _: throw "internal error: a method without a function type";
			}
		}
		var cur = args(TypeFunctions.applyParams(owner.params, ownerArgs, cf.type));
		var orig = args(TypeFunctions.applyParams(base.params, baseArgs, bf.type));
		for (i in 0...cur.length) {
			var real = try g.types.withParams(g.types.currentClassParams(), cf.params, () -> g.types.toSig(cur[i])) catch (_:Unsupported) null;
			if (real != null && real.match(LObject)) continue;
			if (TypeUnification.doesUnify(orig[i], cur[i]) && !TypeUnification.doesUnify(cur[i], orig[i])) return true;
		}
		return false;
	}

	// The parameter names of an override that takes its slot's signature: `__temp_<name><n>` for each
	// parameter whose type changed, numbered by gencommon's mk_temp counter, which runs across the
	// program; the others keep their own.
	static function tempNames(g:DotnetCtx, sig:{args:Array<IlSigNorm>, names:Array<String>, ret:IlSigNorm},
			slot:{args:Array<IlSigNorm>, ret:IlSigNorm}):Array<String> {
		return [
			for (i in 0...sig.args.length)
				IlPaths.sigEq(sig.args[i], slot.args[i]) ? sig.names[i] : "__temp_" + sig.names[i] + (++g.tempCount)
		];
	}

	// The runtime Array's Equals and GetHashCode overrides, which the #8314 forward adds (casts notes §2.6):
	// they call its __hx_equals and __hx_hashCode, whose names keep them out of Haxe code's view (gencs's
	// Array has no Equals nor GetHashCode field), out of reflection and out of the companion interface.
	static function arrayIdentity(c:TClass):Array<MethodPlan> {
		function overrideOf(name:String, body:String, ret:IlSigNorm, args:Array<IlSigNorm>, argNames:Array<String>):MethodPlan {
			var cf = c.fields.get(body);
			if (cf == null) throw "internal error: the runtime Array has no " + body;
			return {
				kind: MObjectOverride(cf),
				name: name,
				flags: MethodAttrs.PUBLIC | MethodAttrs.VIRTUAL | MethodAttrs.HIDE_BY_SIG,
				hasThis: true,
				ret: ret,
				args: args,
				argNames: argNames,
				generics: [],
				pos: cf.pos,
				token: 0
			};
		}
		return [overrideOf("Equals", "__hx_equals", LBool, [LObject], ["other"]), overrideOf("GetHashCode", "__hx_hashCode", LInt32, [], [])];
	}

	// The runtime Null<T>'s `_ofDynamic` and `op_Implicit(T)`, which hxcs's @:classCode gives the struct and
	// which C# code calls (a bool passed to a Haxe ?b:Bool parameter converts through op_Implicit). Its
	// __NoValue__ conversion is left out, a recorded divergence.
	static function nullSurface(c:TClass, self:IlSigNorm):Array<MethodPlan> {
		var pos = c.pos;
		return [
			{
				kind: MNullSurface(false),
				name: "_ofDynamic",
				flags: MethodAttrs.PUBLIC | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG,
				hasThis: false,
				ret: self,
				args: [LObject],
				argNames: ["obj"],
				generics: [],
				pos: pos,
				token: 0
			},
			{
				kind: MNullSurface(true),
				name: "op_Implicit",
				flags: MethodAttrs.PUBLIC | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME,
				hasThis: false,
				ret: self,
				args: [LTypeParam(0)],
				argNames: ["val"],
				generics: [],
				pos: pos,
				token: 0
			}
		];
	}

	// gencs adds ToString for a class whose own toString() returns String and overrides nothing.
	static function wrapsToString(g:DotnetCtx, c:TClass, cf:TClassField):Bool {
		if (TypeFunctions.hasClassFieldFlag(cf, CfOverride) || TypeFunctions.hasClassFieldFlag(cf, CfExtern) || c.fields.exists("ToString")) return false;
		if (!cf.kind.match(Method(MethNormal | MethInline)) || cf.params.length > 0) return false;
		return switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig) if (sig.args.length == 0):
				var ret = try g.types.toSig(sig.ret) catch (_:Unsupported) null;
				ret != null && ret.match(LString);
			case _: false;
		}
	}

	static function isEmpty(e:TExpr):Bool {
		return switch (e.expr) {
			case TBlock(el): Lambda.foreach(el, isEmpty);
			case TMeta(_, e1) | TParenthesis(e1): isEmpty(e1);
			case TConst(TNull): true;
			case TFunction(tf): isEmpty(tf.expr);
			case _: false;
		}
	}

	static function isSuperCall(e:TExpr):Bool {
		return switch (e.expr) {
			case TCall({expr: TConst(TSuper)}, _): true;
			case TMeta(_, e1) | TParenthesis(e1): isSuperCall(e1);
			case _: false;
		}
	}

	static function hasSuperCall(e:TExpr):Bool {
		return isSuperCall(e) || TexprTools.checkExpr(hasSuperCall, e);
	}

	// A constructor that calls no super(...) calls the base type's parameterless one, which must exist;
	// a Haxe base class without a constructor has the implicit one, which calls its own base's.
	static function checkParameterlessBase(g:DotnetCtx, c:TClass):Void {
		var s = c.superClass;
		while (s != null) {
			var sc = s.c;
			if (TypeFunctions.hasClassFlag(sc, CExtern)) {
				var ctor = sc.constructor;
				var ok = false;
				if (ctor != null) for (cf in [ctor].concat(ctor.overloads)) switch (TypeFunctions.follow(cf.type)) {
					case TFun(sig) if (sig.args.length == 0): ok = true;
					case _:
				}
				if (!ok) throw new Unsupported("a base class without a parameterless constructor", false);
				return;
			}
			if (sc.constructor != null) {
				switch (TypeFunctions.follow(sc.constructor.type)) {
					case TFun(sig) if (sig.args.length == 0):
					case _: throw new Unsupported("inherited constructors", true);
				}
				return;
			}
			s = sc.superClass;
		}
	}

	// A constructor of a class in gencs's class model.
	static function ctorMethod(kind:MethodKind, args:Array<IlSigNorm>, names:Array<String>, access:Int, pos:Position):MethodPlan {
		return {
			kind: kind,
			name: ".ctor",
			flags: access | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME,
			hasThis: true,
			ret: LVoid,
			args: args,
			argNames: names,
			generics: [],
			pos: pos,
			token: 0
		};
	}

	public static function implicitCtor(pos:Position, isAbstract:Bool):MethodPlan {
		return {
			kind: MImplicitCtor,
			name: ".ctor",
			flags: (isAbstract ? MethodAttrs.FAMILY : MethodAttrs.PUBLIC) | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME,
			hasThis: true,
			ret: LVoid,
			args: [],
			argNames: [],
			generics: [],
			pos: pos,
			token: 0
		};
	}

	static function entryPoint(pos:Position):MethodPlan {
		return {
			kind: MEntryPoint,
			name: "Main",
			flags: MethodAttrs.PUBLIC | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG,
			hasThis: false,
			ret: LVoid,
			args: [],
			argNames: [],
			generics: [],
			pos: pos,
			token: 0
		};
	}

	// gencs's EntryPoint__Main, in Main's namespace, for a main class named Main.
	public static function entryPointClass(g:DotnetCtx, main:TClass):ClassPlan {
		var mainPath = DotnetNames.typePath(TClassDecl(main));
		var path:IlPath = {ns: mainPath.ns, nested: [], name: "EntryPoint__Main"};
		return {
			c: null,
			hxPath: "EntryPoint__Main",
			path: path,
			flags: TypeAttrs.PUBLIC | TypeAttrs.BEFORE_FIELD_INIT,
			superSig: null,
			interfaces: [],
			fields: [],
			methods: [implicitCtor(main.pos, false), entryPoint(main.pos)],
			classParams: [],
			isStd: false,
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

	// The plan's field and method rows, after every TypeDef row exists.
	public static function write(g:DotnetCtx, plan:ClassPlan):Void {
		var mb = g.mb;
		NullableToIl.prepare(g, plan);
		if (plan.flags & TypeAttrs.INTERFACE == 0)
			mb.setExtends(plan.token, plan.superSig == null ? mb.typeToken(objectPath, false) : sigToken(g, plan.superSig));
		var implemented = [for (s in plan.interfaces) {sig: s, token: sigToken(g, s)}];
		implemented.sort((a, b) -> a.token - b.token);
		for (i in implemented) NullableToIl.interfaceImpl(g, plan, i.sig, mb.interfaceImpl(plan.token, i.token));
		if (plan.c != null && plan.isStd && TypeFunctions.hasMeta(":classCode", plan.c.meta)) g.records.push("ignored @:classCode in " + plan.hxPath);
		if (plan.layout != null && (plan.layout.pack != 0 || plan.layout.size != 0)) mb.classLayout(plan.token, plan.layout.pack, plan.layout.size);
		checkFieldOffsets(g, plan);
		for (f in plan.fields) {
			f.token = mb.field(plan.token, f.flags, f.name, g.sigs.field(f.sig));
			if (f.offset != null && f.flags & FieldAttrs.STATIC == 0) mb.fieldLayout(f.token, f.offset);
			if (f.cf == null) continue;
			if (f.property != null) {
				// A @:property var has no field of its own to Haxe code: every access calls an accessor.
				g.varProperties.set(f.cf, f.property);
				g.ownerOf.set(f.cf, plan);
				continue;
			}
			g.fieldTokens.set(f.cf, f.token);
			g.fieldSigs.set(f.cf, f.sig);
			g.ownerOf.set(f.cf, plan);
		}
		if (plan.initFlag) mb.field(plan.token, FieldAttrs.PRIVATE | FieldAttrs.STATIC, initFlagName, g.sigs.field(LBool));
		for (m in plan.methods) {
			// A rare path the runtime's small methods keep apart (@:hxcCold) stays apart: inlined, it would bring its
			// dynamic calls into every caller. 8 is noinlining (ECMA-335 II.23.1.11).
			var impl = switch (m.kind) {
				case MField(cf) if (TypeFunctions.hasMeta(":hxcCold", cf.meta)): 8;
				case _: 0;
			}
			m.token = mb.method(plan.token, m.flags, impl, m.name, g.sigs.method(m.hasThis, m.ret, m.args, m.generics.length), m.argNames,
				NullableToIl.returnRow(g, m));
			switch (m.kind) {
				case MField(cf):
					g.methodTokens.set(cf, m.token);
					g.methodPlans.set(cf, m);
					g.methodSigs.set(cf, {ret: m.ret, args: m.args});
					g.ownerOf.set(cf, plan);
				case MSplitCtor(hc) if (hc.own != null):
					g.methodTokens.set(hc.own, m.token);
					g.methodPlans.set(hc.own, m);
					g.methodSigs.set(hc.own, {ret: m.ret, args: m.args});
					g.ownerOf.set(hc.own, plan);
				case MEntryPoint:
					g.entryPoint = m.token;
				case _:
			}
		}
		for (p in plan.properties) {
			p.token = mb.property(plan.token, p.name, g.sigs.property(p.sig, p.isStatic != true, p.index));
			// Roslyn marks an auto-property's backing field and both accessors CompilerGenerated.
			if (p.backing != null) AttributesToIl.compilerGenerated(g, [p.backing.token, p.getter.token, p.setter.token]);
			if (p.getter != null) mb.methodSemantics(SemanticsAttrs.GETTER, p.getter.token, p.token);
			if (p.setter != null) mb.methodSemantics(SemanticsAttrs.SETTER, p.setter.token, p.token);
			// Every Haxe use of get_X and set_X calls the public accessor, as gencs writes `o.X` and `o.X = v`.
			for (pair in [{body: p.getBody, accessor: p.getter}, {body: p.setBody, accessor: p.setter}]) {
				if (pair.body == null) continue;
				var cf = switch (pair.body.kind) {
					case MField(cf): cf;
					case _: throw "internal error: a property body that is no Haxe method";
				}
				g.methodTokens.set(cf, pair.accessor.token);
				g.methodPlans.set(cf, pair.accessor);
				g.methodSigs.set(cf, {ret: pair.accessor.ret, args: pair.accessor.args});
			}
		}
		EventToIl.write(g, plan);
		NullableToIl.write(g, plan);
	}

	// C#'s rules for FieldOffset, whose errors Roslyn gives: on the instance fields of a type with
	// StructLayout(LayoutKind.Explicit), every one of them, and on no other field. An auto-property has a
	// backing field no FieldOffset can name.
	static function checkFieldOffsets(g:DotnetCtx, plan:ClassPlan):Void {
		var explicit = plan.flags & TypeAttrs.LAYOUT_MASK == TypeAttrs.EXPLICIT;
		for (f in plan.fields) {
			if (f.cf == null) continue;
			var isStatic = f.flags & FieldAttrs.STATIC != 0;
			if (f.offset != null) {
				if (isStatic)
					g.error("the FieldOffset attribute is not allowed on the static field " + f.cf.name + " (C# error CS0637)", f.cf.pos);
				else if (!explicit)
					g.error("the FieldOffset attribute on " + f.cf.name + " needs StructLayout(LayoutKind.Explicit) on its type (C# error CS0636)", f.cf.pos);
			} else if (explicit && !isStatic) {
				if (f.property != null)
					g.error("the @:property variable " + f.cf.name + " cannot be in a type with StructLayout(LayoutKind.Explicit): it has no field to give an offset (C# error CS0842)", f.cf.pos);
				else
					g.error(f.cf.name + " needs a FieldOffset attribute, as its type has StructLayout(LayoutKind.Explicit) (C# error CS0625)", f.cf.pos);
			}
		}
	}

	// The class's attribute rows, after every row they name exists (an attribute class's constructor may come
	// later): the @:meta attributes where gencs's C# puts them (AttributesToIl), then C#'s
	// [DefaultMember("Item")] on a type that declares an indexer, which Roslyn writes after the type's own.
	// gencs puts an hxgen class's constructor's attributes on its (haxe.lang.EmptyObject) constructor, a
	// @:property var's on its property, and a parameter's typedef's on the parameter (an hxgen constructor's
	// on the real constructor and the static __hx_ctor_*); a generic interface's
	// members that mention no type parameter are its companion's (CompanionToIl), and so are their
	// attributes. The attributes of a var with no field or property are refused, where gencs's land on the
	// next C# member, and so is an argument's @:strict, which gencs drops.
	public static function writeAttributes(g:DotnetCtx, plan:ClassPlan):Void {
		var c = plan.c;
		var ns = plan.path.ns;
		inline function site(name:String):AttributesToIl.AttrSite return {name: name, ns: ns};
		var done = new ObjectMap<TClassField, Bool>();
		if (c != null) {
			var target = plan.flags & TypeAttrs.INTERFACE != 0 ? AttrTarget.TInterface : plan.isStruct ? AttrTarget.TStruct : AttrTarget.TType;
			AttributesToIl.forMember(g, plan.token, c.meta, target, c.pos, site(c.path.name));
			if (plan.emptyCtor != null && c.constructor != null)
				AttributesToIl.forMember(g, plan.emptyCtor.token, c.constructor.meta, AttrTarget.TCtor, c.constructor.pos, site("new"));
			inline function declares(cf:TClassField) return c.fields.get(cf.name) == cf || c.statics.get(cf.name) == cf;
			// (A field-like event's backing field has none of its var's, which gencs puts on no event.)
			for (f in plan.fields) if (f.cf != null && f.property == null && !done.exists(f.cf) && declares(f.cf) && !EventToIl.isEventVar(f.cf)) {
				done.set(f.cf, true);
				AttributesToIl.forMember(g, f.token, f.cf.meta, AttrTarget.TField, f.cf.pos, site(f.cf.name));
			}
			for (p in plan.properties) if (p.index.length == 0 && !done.exists(p.cf) && declares(p.cf)) {
				done.set(p.cf, true);
				AttributesToIl.forMember(g, p.token, p.cf.meta, AttrTarget.TProperty, p.cf.pos, site(p.cf.name));
			}
		}
		// The optional-argument overloads, whose attributes are their method's (written after it, and only
		// when its own gave no error, which C# would report for each overload again).
		var overloads:Array<MethodPlan> = [];
		var clean = new ObjectMap<TClassField, Bool>();
		for (m in plan.methods) switch (m.kind) {
			case MField(cf) if (!done.exists(cf)):
				var isCtor = m.name == ".ctor";
				if (isCtor && plan.emptyCtor != null) continue;
				done.set(cf, true);
				var before = g.diagnostics;
				AttributesToIl.forMember(g, m.token, cf.meta, isCtor ? AttrTarget.TCtor : AttrTarget.TMethod, cf.pos, site(isCtor ? "new" : cf.name));
				var args = signatureArgs(cf.type);
				if (args != null) paramAttributes(g, m, [for (a in args) {name: a.name, t: a.t}], 0, cf.pos, ns);
				if (g.diagnostics == before) clean.set(cf, true);
			case MOptionalOverload(_, _):
				overloads.push(m);
			// (The attribute is read from here, so `main`'s apartment attribute goes on this too.)
			case MEntryPoint:
				AttributesToIl.forEntryPoint(g, m.token, g.mainClass.statics.get("main"), site("Main"));
			// An hxgen class's constructor's parameters keep their typedefs' attributes on the real
			// constructor and on the static __hx_ctor_* (after its __hx_this), as gencs's argt_s writes both.
			case MSplitCtor(hc) | MStaticCtor(hc):
				var pos = hc.origin != null ? hc.origin.pos : plan.c.pos;
				paramAttributes(g, m, [for (a in hc.args) {name: a.name, t: a.t}], m.kind.match(MStaticCtor(_)) ? 1 : 0, pos, ns);
			case _:
		}
		for (m in overloads) switch (m.kind) {
			case MOptionalOverload(cf, n) if (clean.exists(cf)):
				var isCtor = m.name == ".ctor";
				AttributesToIl.forMember(g, m.token, cf.meta, isCtor ? AttrTarget.TCtor : AttrTarget.TMethod, cf.pos, site(isCtor ? "new" : cf.name));
				var args = signatureArgs(cf.type);
				if (args != null) paramAttributes(g, m, [for (a in args.slice(0, n)) {name: a.name, t: a.t}], 0, cf.pos, ns);
			case _:
		}
		if (c != null) {
			for (cf in c.orderedFields.concat(c.orderedStatics)) {
				// gencs writes no attribute on an event; the @:meta of its add_ and remove_ stay on their bodies.
				if (!cf.kind.match(Var(_)) || done.exists(cf) || TypeFunctions.hasClassFieldFlag(cf, CfExtern) || EventToIl.isEventVar(cf)) continue;
				var m = TypeFunctions.getMetaOpt(":meta", cf.meta);
				if (m == null) continue;
				var accessor = switch (cf.kind) {
					case Var(k) if (k.read != AccCall && k.write == AccCall): "set_" + cf.name;
					case _: "get_" + cf.name;
				}
				g.error(cf.name + " has no field or property in .NET (it is not physical), so its @:meta has nothing to go on; put it on " + accessor
					+ ", or make " + cf.name + " @:isVar or @:property", m.params.length > 0 ? m.params[0].pos : m.pos);
			}
			var fields = c.orderedFields.concat(c.orderedStatics);
			if (c.constructor != null) fields.push(c.constructor);
			inline function refuse(m:hxc.ast.Ast.MetadataEntry)
				g.error("@:strict on a function argument is not written (gencs drops it too); put the attribute on a typedef of the argument's type",
					m.params.length > 0 ? m.params[0].pos : m.pos);
			for (cf in fields) for (f in [cf].concat(cf.overloads)) {
				switch (f.expr) {
					case {expr: TFunction(tf)}:
						for (a in tf.args) for (m in a.v.meta) if (m.name == ":strict") refuse(m);
					case _:
				}
				// A bodiless method (an interface's, an abstract one) keeps its arguments' @:strict here.
				if (f.hxcArgStrict != null) for (m in f.hxcArgStrict) refuse(m);
			}
		}
		for (p in plan.properties) if (p.name == IndexerToIl.itemName && p.index.length > 0) {
			IndexerToIl.defaultMember(g, plan.token);
			break;
		}
	}

	// The Param rows of `m`'s arguments (from its parameter `first` on) for the @:meta of the typedefs their
	// types go through.
	static function paramAttributes(g:DotnetCtx, m:MethodPlan, args:Array<{name:String, t:T}>, first:Int, pos:hxc.ast.Position,
			ns:Array<String>):Void {
		for (i in 0...args.length) {
			var meta = typedefMeta(args[i].t);
			if (meta.length > 0 && first + i < m.argNames.length)
				AttributesToIl.forMember(g, g.mb.paramToken(m.token, first + i), meta, AttrTarget.TParam, pos, {name: args[i].name, ns: ns});
		}
	}

	// A method type's arguments, the typedefs in their types kept, or null.
	static function signatureArgs(t:T):Null<Array<TSignatureArg>> {
		while (true) switch (t) {
			case TFun(sig): return sig.args;
			case TLazy(f): t = TypeFunctions.lazyType(f);
			case TMono(m) if (m.type != null): t = m.type;
			case _: return null;
		}
	}

	// The @:meta of each typedef a parameter's type goes through, outermost first, as gencs's argt_s writes
	// them on the parameter.
	static function typedefMeta(t:T):Array<hxc.ast.Ast.MetadataEntry> {
		var r = [];
		for (_ in 0...64) switch (t) {
			case TType(td, _):
				for (m in td.meta) if (m.name == ":meta") r.push(m);
				t = TypeFunctions.followOnce(t);
			case TLazy(f): t = TypeFunctions.lazyType(f);
			case TMono(m) if (m.type != null): t = m.type;
			case _: break;
		}
		return r;
	}

	// A TypeDefOrRef coded index for a class signature.
	public static function sigToken(g:DotnetCtx, s:IlSigNorm):Int {
		return switch (s) {
			case LClass(p, []): g.mb.typeToken(p, false);
			case _: ModuleBuilder.coded(hxc.codegen.dotnet.IlMeta.TableIdx.ITypeDefOrRef, g.typeTokenOf(s));
		}
	}

	public static function emit(g:DotnetCtx, c:TClass):Void {
		emitPlan(g, g.planOf.get(c));
	}

	public static function emitPlan(g:DotnetCtx, plan:ClassPlan):Void {
		if (plan.c != null) ReflectionMembers.checkConflicts(g, plan.c);
		for (m in plan.methods) emitMethod(g, plan, m);
	}

	static function label(m:MethodPlan):String {
		return switch (m.kind) {
			case MField(cf): cf.name;
			case MImplicitCtor: "new";
			case MEntryPoint: "Main";
			case MCctor: "__init__";
			case MToString(_): "ToString";
			case MObjectOverride(_) | MNullSurface(_): m.name;
			case MEmptyCtor | MSplitCtor(_) | MClonedCtor(_): "new";
			case MStaticCtor(_): "new";
			case MReflect(r): ReflectionMembers.label(r);
			case MBridge(cf): cf.name;
			case MEnum(_, member): EnumToIl.label(member);
			case MInterfaceBridge(b): b.im.name;
			case MCast(_, _): m.name;
			case MCompanionMember: m.name;
			case MPropertyAccessor(_, _) | MEventAccessor(_, _): m.name;
			case MIndexer(_, _, _, _): m.name;
			case MOptionalOverload(cf, _): cf.name;
		}
	}

	// The base type's parameterless constructor: a MethodDef token when this module defines it for a
	// non-generic class, else a MemberRef.
	static function baseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var parent = plan.superSig == null ? LClass(objectPath, []) : plan.superSig;
		var token = 0;
		var superPlan = superPlanOf(g, plan);
		if (superPlan != null && parent.match(LClass(_, []))) for (m in superPlan.methods) if (m.name == ".ctor" && m.args.length == 0) token = m.token;
		if (token == 0) token = g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.method(true, LVoid, [], 0));
		code.ldarg(0);
		code.opToken(IlOps.CALL, token, 1, 0);
	}

	// The plan of the type the class extends, when this module defines it: its Haxe superclass's, or for
	// an hxgen class without one HxObject's.
	static function superPlanOf(g:DotnetCtx, plan:ClassPlan):Null<ClassPlan> {
		if (plan.c == null) return null;
		if (plan.c.superClass != null) return g.planOf.get(plan.c.superClass.c);
		if (plan.ctors == null) return null;
		var h = g.runtimeClass(DotnetCtx.hxObjectPath);
		return h == null || h == plan.c ? null : g.planOf.get(h);
	}

	// A constructor of the base type `parent`: its MethodDef token for a non-generic class, else a
	// MemberRef on the instantiation.
	static function ctorToken(g:DotnetCtx, parent:IlSigNorm, m:MethodPlan):Int {
		if (parent.match(LClass(_, []))) return m.token;
		return g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.method(true, LVoid, m.args, 0));
	}

	// base(EmptyObject.EMPTY): the base class's empty constructor.
	static function emptyBaseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var superPlan = superPlanOf(g, plan);
		if (superPlan == null || superPlan.emptyCtor == null) throw "internal error: the base class of " + plan.hxPath + " has no empty constructor";
		code.ldarg(0);
		code.ldcI4(0);
		code.opToken(IlOps.CALL, ctorToken(g, plan.superSig, superPlan.emptyCtor), 2, 0);
	}

	// The constructor plan of a class in gencs's model that `origin` (null: the empty `new()`) reaches.
	public static function ctorOf(plan:ClassPlan, origin:Null<TClassField>):CtorPlan {
		for (cp in plan.ctors) if (cp.hx.origin == origin) return cp;
		throw "internal error: " + plan.hxPath + " has no constructor for " + (origin == null ? "new()" : origin.name);
	}

	// A static constructor as a call reaches it: through the class's instantiation with object for each
	// type parameter, with `margs` for the method's own, as gencs writes `C<object>.__hx_ctor_C<T>(...)`.
	public static function staticCtorRef(g:DotnetCtx, plan:ClassPlan, stat:MethodPlan, margs:Array<IlSigNorm>):Int {
		if (plan.classParams.length == 0) return stat.token;
		var owner = DotnetCtx.instanceOf(plan, [for (_ in plan.classParams) LObject]);
		var token = g.mb.memberRef(g.typeTokenOf(owner), stat.name, g.sigs.method(false, LVoid, stat.args, stat.generics.length));
		return g.mb.methodSpec(token, g.sigs.methodSpec(margs));
	}

	// The real constructor of the Haxe class `plan` that `origin` reaches (null: its parameterless one).
	static function realCtorOf(g:DotnetCtx, plan:ClassPlan, origin:Null<TClassField>):MethodPlan {
		if (plan.ctors != null) return ctorOf(plan, origin).real;
		var m = origin == null ? null : g.methodPlans.get(origin);
		if (m == null) for (x in plan.methods) if (x.name == ".ctor" && x.kind.match(MImplicitCtor)) m = x;
		if (m == null) throw "internal error: no constructor of " + plan.hxPath;
		return m;
	}

	// C#'s default value of a type, as gencs passes `null` for each argument.
	static function pushDefault(g:DotnetCtx, code:IlCode, t:IlSigNorm):Void {
		if (DotnetTypes.isValueType(t) || t.match(LTypeParam(_) | LMethodTypeParam(_))) {
			var tmp = code.addLocal(t);
			code.ldloca(tmp);
			code.opToken(IlOps.INITOBJ, g.typeTokenOf(t), 1, 0);
			code.ldloc(tmp);
		} else {
			code.op(IlOps.LDNULL, 0, 1);
		}
	}

	// The constructor of the native base class that `origin` names (null: the parameterless one), with
	// the arguments `pushArgs` pushes after `this`.
	static function nativeBaseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode, origin:Null<TClassField>, owner:Null<TClass>,
			pushArgs:Array<IlSigNorm>->Void):Void {
		var s = plan.c.superClass;
		if (origin == null) {
			baseCtor(g, plan, code);
			return;
		}
		if (owner != s.c) throw new Unsupported("inherited .NET constructors", true);
		var inst = g.types.classArgs(s.c, s.params);
		code.ldarg(0);
		if (TypeFunctions.hasClassFlag(s.c, CExtern)) {
			var m = g.externs.method(s.c, origin, true);
			var parent = ExternMembers.subst(m.parent, inst);
			var parentArgs = switch (parent) {
				case LClass(_, l) | LValueType(_, l): l;
				case _: [];
			}
			var args = switch (m.sig) {
				case LMethod(_, _, l): [for (a in l) ExternMembers.subst(a, parentArgs)];
				case _: throw "internal error: not a method signature";
			}
			pushArgs(args);
			code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.methodSig(m.sig, 0)), args.length + 1, 0);
		} else {
			var m = realCtorOf(g, g.planOf.get(s.c), origin);
			var args = [for (a in m.args) DotnetTypes.substitute(a, inst, [])];
			pushArgs(args);
			code.opToken(IlOps.CALL, ctorToken(g, plan.superSig, m), args.length + 1, 0);
		}
	}

	// gencs's empty constructor: base(EmptyObject.EMPTY) under an hxgen class, the native base class's
	// constructor with the fewest parameters given nulls under a native one, nothing (the parameterless
	// one) at the root.
	static function emptyCtorBody(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var s = plan.c.superClass;
		var superPlan = superPlanOf(g, plan);
		if (s == null) {
			baseCtor(g, plan, code);
		} else if (superPlan != null && superPlan.emptyCtor != null) {
			emptyBaseCtor(g, plan, code);
		} else {
			// The first with the fewest, looking at the main constructor (listed last) before its overloads.
			var prev = HxGen.previousCtors(plan.c);
			var best = null;
			if (prev.length > 0) for (p in [prev[prev.length - 1]].concat(prev.slice(0, prev.length - 1)))
				if (best == null || p.args.length < best.args.length) best = p;
			if (best == null) {
				baseCtor(g, plan, code);
			} else {
				nativeBaseCtor(g, plan, code, best.origin, best.owner, args -> for (a in args) pushDefault(g, code, a));
			}
		}
		code.op(IlOps.RET, 0, 0);
	}

	static function functionOf(g:DotnetCtx, cf:TClassField, what:String):TFunc {
		return switch (g.exprOf(cf).expr) {
			case TFunction(tf): tf;
			case _: throw "internal error: method " + what + " has no function";
		}
	}

	// An hxgen class's real constructor: base(EmptyObject.EMPTY) when its body calls super(...) (which
	// the static constructor does), else the parameterless base constructor C# calls implicitly; then the
	// static constructor with `this` and the arguments.
	static function splitCtorBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, hc:HaxeCtor, code:IlCode):Void {
		var callsSuper = hc.own != null ? hasSuperCall(hc.own.expr) : hc.clone;
		if (callsSuper) emptyBaseCtor(g, plan, code) else baseCtor(g, plan, code);
		var stat = ctorOf(plan, hc.origin).stat;
		for (i in 0...m.args.length + 1) code.ldarg(i);
		var token = staticCtorRef(g, plan, stat, [for (i in 0...plan.classParams.length) LTypeParam(i)]);
		code.opToken(IlOps.CALL, token, m.args.length + 1, 0);
		code.op(IlOps.RET, 0, 0);
	}

	// The static constructor: the constructor's body with the initializers (withInits); without one, the
	// initializers, or for a cloned one the var initializers, the base class's static constructor with
	// the arguments, then the dynamic methods.
	static function staticCtorBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, hc:HaxeCtor, code:IlCode, lower:TexprToIl, what:String):Void {
		var c = plan.c;
		if (hc.own != null) {
			if (TypeFunctions.hasMeta(":functionCode", hc.own.meta)) throw functionCodeError(hc.own);
			var tf = functionOf(g, hc.own, what);
			lower.bindArgs(tf, 1, m.args.slice(1));
			statement(lower, RReturn, withInits(g, c, tf.expr));
			return;
		}
		var inits = fieldInits(g, c), dynamics = dynamicInits(g, c);
		if (!hc.clone) {
			initStatements(lower, c, inits.concat(dynamics));
			return;
		}
		initStatements(lower, c, inits);
		var s = c.superClass;
		var superPlan = g.planOf.get(s.c);
		var margs = g.types.classArgs(s.c, s.params);
		var stat = ctorOf(superPlan, hc.origin).stat;
		for (i in 0...m.args.length) code.ldarg(i);
		code.opToken(IlOps.CALL, staticCtorRef(g, superPlan, stat, margs), m.args.length, 0);
		initStatements(lower, c, dynamics);
	}

	static function initStatements(lower:TexprToIl, c:TClass, inits:Array<TExpr>):Void {
		if (inits.length > 0) statement(lower, RVoid, {expr: TBlock(inits), type: TypeFunctions.tDynamic, pos: c.pos});
	}

	// A constructor cloned from a native base class's: that constructor with the arguments, then the
	// initializers, which C# runs after it.
	static function clonedCtorBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, hc:HaxeCtor, code:IlCode, lower:TexprToIl):Void {
		var owner = null;
		for (p in HxGen.previousCtors(plan.c)) if (p.origin == hc.origin) owner = p.owner;
		nativeBaseCtor(g, plan, code, hc.origin, owner, _ -> for (i in 0...m.args.length) code.ldarg(i + 1));
		initStatements(lower, plan.c, fieldInits(g, plan.c).concat(dynamicInits(g, plan.c)));
	}

	// gencs's FixOverrides override for a method with a contravariant parameter (OOverload), with the
	// slot's signature: `return (R)this.f((A)a, ...)`, a call of the method, which keeps its own signature.
	@:access(hxc.codegen.dotnet.TexprToIl)
	static function bridgeBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, cf:TClassField, code:IlCode, lower:TexprToIl):Void {
		var target = g.methodPlans.get(cf);
		if (target == null) throw "internal error: no method " + plan.hxPath + "." + cf.name;
		code.ldarg(0);
		for (i in 0...m.args.length) {
			code.ldarg(i + 1);
			lower.convert(m.args[i], target.args[i]);
		}
		var token = g.memberOf(plan, plan.thisSig, cf);
		if (cf.params.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec([for (i in 0...cf.params.length) LMethodTypeParam(i)]));
		code.opToken(IlOps.CALLVIRT, token, m.args.length + 1, target.ret.match(LVoid) ? 0 : 1);
		if (m.ret.match(LVoid)) {
			if (!target.ret.match(LVoid)) code.op(IlOps.POP, 1, 0);
			code.op(IlOps.RET, 0, 0);
		} else {
			lower.convert(target.ret, m.ret);
			code.op(IlOps.RET, 1, 0);
		}
	}

	// gencs's optional-argument overload (MOptionalOverload): `return this.<method>(args, defaults)`, a
	// static's `return <Class>.<method>(...)` and a constructor's `: this(args, defaults) {}`. Each argument
	// it leaves out gets its default value, or null where it has none (`?x`); the full method's body then
	// applies the defaults as it does for any caller.
	@:access(hxc.codegen.dotnet.TexprToIl)
	static function optionalOverloadBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, cf:TClassField, n:Int, code:IlCode, lower:TexprToIl):Void {
		var target = g.methodPlans.get(cf);
		var tf = switch (g.exprOf(cf).expr) {
			case TFunction(tf): tf;
			case _: null;
		}
		if (target == null || tf == null) throw "internal error: no method " + plan.hxPath + "." + cf.name + " for its optional-argument overload";
		var first = m.hasThis ? 1 : 0;
		for (i in 0...n + first) code.ldarg(i);
		for (i in n...target.args.length) {
			var slot = target.args[i];
			var c = i < tf.args.length ? tf.args[i].c : null;
			if (c == null || TexprToIl.isNullConst(c)) {
				lower.pushDefault(slot);
			} else {
				var own = lower.sig(c.type);
				lower.texpr(RValue(own), c);
				lower.convert(own, slot);
			}
		}
		// A static is called through the class with object for its type parameters, as gencs writes
		// `C<object>.m(...)` for any static call.
		var token = g.memberOf(plan, m.hasThis ? plan.thisSig : TexprToIl.staticOwner(plan), cf);
		var argc = target.args.length + first;
		var pushes = target.ret.match(LVoid) ? 0 : 1;
		var virt = m.hasThis && m.name != ".ctor" && !plan.isStruct && target.flags & MethodAttrs.VIRTUAL != 0;
		code.opToken(virt ? IlOps.CALLVIRT : IlOps.CALL, token, argc, pushes);
		code.op(IlOps.RET, pushes, 0);
	}

	// An interface bridge (InterfaceBridge): `return (<ret>) this.<method>((<arg>) args)`, and for an
	// explicit implementation the MethodImpl row that makes it the interface method's implementation.
	@:access(hxc.codegen.dotnet.TexprToIl)
	static function interfaceBridgeBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, b:InterfaceBridge, code:IlCode, lower:TexprToIl):Void {
		var target = g.methodPlans.get(b.target), ownerPlan = g.planOf.get(b.owner), im = g.methodPlans.get(b.im);
		if (target == null || ownerPlan == null || im == null) throw "internal error: no method for the bridge " + m.name;
		var owner = b.owner == plan.c ? plan.thisSig : g.types.classSig(b.owner, b.ownerParams);
		var inst = switch (owner) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		var ret = DotnetTypes.substitute(target.ret, inst, []);
		code.ldarg(0);
		for (i in 0...m.args.length) {
			code.ldarg(i + 1);
			lower.convert(m.args[i], DotnetTypes.substitute(target.args[i], inst, []));
		}
		code.opToken(IlOps.CALLVIRT, g.memberOf(ownerPlan, owner, b.target), m.args.length + 1, ret.match(LVoid) ? 0 : 1);
		if (m.ret.match(LVoid)) {
			if (!ret.match(LVoid)) code.op(IlOps.POP, 1, 0);
			code.op(IlOps.RET, 0, 0);
		} else {
			lower.convert(ret, m.ret);
			code.op(IlOps.RET, 1, 0);
		}
		// The CLR finds an overload by its name and signature.
		if (!b.explicit) return;
		// A method a generic interface's companion declares is no member of the interface's instantiation.
		var imOwner = g.ownerOf.get(b.im);
		var decl = if (b.iface.c.params.length == 0 || imOwner != null && imOwner.classParams.length == 0) im.token;
			else g.mb.memberRef(g.typeTokenOf(b.iface.sig), im.name, g.sigs.method(true, im.ret, im.args, 0));
		g.mb.methodImpl(plan.token, m.token, decl);
	}

	// Instance var initializers, as gencommon's init_funcs moves them into constructors: @:readOnly
	// ones, which C# runs as field initializers, in declaration order, then the others in reverse
	// declaration order.
	static function fieldInits(g:DotnetCtx, c:TClass):Array<TExpr> {
		var readOnly = [], others = [];
		for (cf in c.orderedFields) {
			if (!cf.kind.match(Var(_)) || cf.expr == null || TypeFunctions.hasClassFieldFlag(cf, CfExtern) || !TypeFunctions.isPhysicalField(cf)) continue;
			var assign = initAssign(g, c, cf);
			if (TypeFunctions.hasMeta(":readOnly", cf.meta)) readOnly.push(assign) else others.unshift(assign);
		}
		return readOnly.concat(others);
	}

	// The dynamic methods' assignments, an override's included, which init_funcs adds after the var
	// initializers, in reverse declaration order.
	static function dynamicInits(g:DotnetCtx, c:TClass):Array<TExpr> {
		var r = [];
		for (cf in c.orderedFields)
			if (cf.kind.match(Method(MethDynamic)) && cf.expr != null && !TypeFunctions.hasClassFieldFlag(cf, CfExtern)) r.unshift(initAssign(g, c, cf));
		return r;
	}

	// `this.f = <f's value>`.
	static function initAssign(g:DotnetCtx, c:TClass, cf:TClassField):TExpr {
		var params = TypeFunctions.extractParamTypes(c.params);
		var ethis:TExpr = {expr: TConst(TThis), type: TInst(c, params), pos: cf.pos};
		return {
			expr: TBinop(OpAssign, {expr: TField(ethis, FInstance(c, params, cf)), type: cf.type, pos: cf.pos}, g.exprOf(cf)),
			type: cf.type,
			pos: cf.expr.pos
		};
	}

	// The constructor body with the initializers, as init_funcs's add_fn places them: when the body
	// starts with super(...), the var initializers before it and the dynamic methods after it (both
	// after it when the class descends from a native class, whose constructor C# runs first);
	// otherwise all before the body.
	static function withInits(g:DotnetCtx, c:TClass, body:TExpr):TExpr {
		var inits = fieldInits(g, c), dynamics = dynamicInits(g, c);
		if (inits.length == 0 && dynamics.length == 0) return body;
		var el = switch (body.expr) {
			case TBlock(el): el;
			case _: [body];
		}
		var block = if (el.length > 0 && isSuperCall(el[0])) {
			var head = [el[0]];
			if (HxGen.descendsFromNative(c)) head.concat(inits).concat(dynamics).concat(el.slice(1)) else inits.concat(head).concat(dynamics).concat(el.slice(1));
		} else {
			inits.concat(dynamics).concat(el);
		}
		return {expr: TBlock(block), type: body.type, pos: body.pos};
	}

	// For a constructor without super(...): the initializers, then the base type's parameterless
	// constructor, as init_funcs puts them before the super() of a cloned or empty constructor; under a
	// .NET base, whose constructor C# runs first, the other way round.
	static function initsAndBaseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode, lower:TexprToIl):Void {
		var inits = plan.c == null ? [] : fieldInits(g, plan.c).concat(dynamicInits(g, plan.c));
		var native = plan.c != null && HxGen.descendsFromNative(plan.c);
		if (native) baseCtor(g, plan, code);
		if (inits.length > 0) statement(lower, RVoid, {expr: TBlock(inits), type: TypeFunctions.tDynamic, pos: plan.c.pos});
		if (!native) baseCtor(g, plan, code);
	}

	static function emitMethod(g:DotnetCtx, plan:ClassPlan, m:MethodPlan):Void {
		// Abstract and interface methods have no body.
		if (m.flags & MethodAttrs.ABSTRACT != 0) return;
		var what = plan.hxPath + "." + label(m);
		var code = new IlCode(what);
		var failures:Array<Unsupported> = [];
		var stub:Null<Unsupported> = null;
		var lower = new TexprToIl(g, code, m.ret);
		if (!plan.isStd) lower.onError = u -> failures.push(u);
		lower.cls = plan.c;
		if (m.hasThis) lower.thisSig = plan.thisSig;
		// Under -debug, the methods that lower the user's expressions or field initializers have sequence
		// points and local scopes; the others, which hxc writes itself, have none. In a closure class only the
		// method with the function's body has them: the invoke method, or the Delegate method that the invoke
		// method of a function converted to a .NET delegate calls.
		// A plan with no class (an enum's) is no closure class; a null key is an error in a map on .NET.
		if (g.pdb != null) {
			code.points = [];
			lower.points = switch (m.kind) {
				case MField(cf) if (plan.c != null && g.closureOwners.exists(plan.c)):
					var delegate = plan.c.fields.get("Delegate");
					if (delegate != null && !delegate.kind.match(Method(_))) delegate = null;
					cf != plan.c.constructor && (delegate == null || cf == delegate);
				case MField(_): true;
				case MImplicitCtor | MClonedCtor(_) | MStaticCtor(_) | MCctor: plan.c == null || !g.closureOwners.exists(plan.c);
				case _: false;
			}
			if (lower.points) code.scopes = [];
		}
		try {
			g.types.inParams(plan.classParams, [], () -> switch (m.kind) {
				case MImplicitCtor:
					initsAndBaseCtor(g, plan, code, lower);
					if (failures.length == 0) lower.finish();
				case MEmptyCtor:
					emptyCtorBody(g, plan, code);
				case MSplitCtor(hc):
					splitCtorBody(g, plan, m, hc, code);
				case MClonedCtor(hc):
					clonedCtorBody(g, plan, m, hc, code, lower);
					if (failures.length == 0) lower.finish();
				case MStaticCtor(hc):
					// `__hx_this`, the first argument, stands for `this`; the class's type parameters are the
					// method's own.
					lower.thisSig = m.args[0];
					lower.splitCtor = true;
					g.types.inParams([], plan.classParams, () -> {
						staticCtorBody(g, plan, m, hc, code, lower, what);
						if (failures.length == 0) lower.finish();
					});
				case MReflect(r):
					ReflectionMembers.emit(g, plan, m, r, code, lower);
				case MEnum(e, member):
					EnumToIl.emit(g, m, e, member, code, lower);
				case MToString(cf):
					code.ldarg(0);
					code.opToken(plan.isStruct ? IlOps.CALL : IlOps.CALLVIRT, g.memberOf(plan, plan.thisSig, cf), 1, 1);
					code.op(IlOps.RET, 1, 0);
				case MObjectOverride(cf):
					for (i in 0...m.args.length + 1) code.ldarg(i);
					code.opToken(IlOps.CALL, g.memberOf(plan, plan.thisSig, cf), m.args.length + 1, 1);
					code.op(IlOps.RET, 1, 0);
				case MNullSurface(isImplicit):
					code.ldarg(0);
					if (isImplicit) {
						code.ldcI4(1);
						var ctor = plan.c.constructor;
						code.opToken(IlOps.NEWOBJ, g.memberOf(plan, plan.thisSig, ctor), 2, 1);
					} else {
						var of = plan.c.statics.get("ofDynamic");
						var ofPlan = of == null ? null : g.methodPlans.get(of);
						if (ofPlan == null) throw "internal error: the runtime Null has no ofDynamic";
						var token = g.mb.methodSpec(g.methodOf(plan, plan.thisSig, ofPlan), g.sigs.methodSpec([LTypeParam(0)]));
						code.opToken(IlOps.CALL, token, 1, 1);
					}
					code.op(IlOps.RET, 1, 0);
				case MField(cf):
					if (TypeFunctions.hasMeta(":functionCode", cf.meta)) throw functionCodeError(cf);
					var tf = switch (g.exprOf(cf).expr) {
						case TFunction(tf): tf;
						case _: throw "internal error: method " + what + " has no function";
					}
					g.types.inParams(plan.classParams, cf.params, () -> {
						var body = tf.expr;
						if (m.name == ".ctor") {
							if (!plan.isStruct && !hasSuperCall(body)) initsAndBaseCtor(g, plan, code, lower) else body = withInits(g, plan.c, body);
						}
						if (m.ownArgs != null) lower.bindOwnArgs(tf, m.args, m.ownArgs) else lower.bindArgs(tf, m.hasThis ? 1 : 0, m.args);
						lower.retType = tf.type;
						statement(lower, RReturn, body);
						if (failures.length == 0) lower.finish();
					});
				case MBridge(cf):
					g.types.inParams(plan.classParams, cf.params, () -> bridgeBody(g, plan, m, cf, code, lower));
				case MInterfaceBridge(b):
					interfaceBridgeBody(g, plan, m, b, code, lower);
				case MCast(c, body):
					CompanionToIl.emitCast(g, plan, m, c, body, code);
				case MCompanionMember:
					throw "internal error: a companion member with a body";
				case MPropertyAccessor(p, isSet):
					if (p.backing != null) backingAccessorBody(g, plan, p, isSet, code) else accessorBody(p, isSet, code);
				case MEventAccessor(e, isRemove):
					EventToIl.accessorBody(g, plan, e, isRemove, code);
				case MIndexer(get, set, isSet, explicit):
					IndexerToIl.emit(g, plan, m, get, set, isSet, explicit, code);
				case MOptionalOverload(cf, n):
					g.types.inParams(plan.classParams, [], () -> optionalOverloadBody(g, plan, m, cf, n, code, lower));
				case MEntryPoint:
					var boot = g.bootInit();
					if (boot != null) code.opToken(IlOps.CALL, boot, 0, 0);
					if (g.ctx.main != null) statement(lower, RVoid, g.ctx.main);
					if (failures.length == 0) lower.finish();
				case MCctor:
					if (plan.initFlag) initGuard(g, plan, code);
					if (plan.hxPath == fieldLookupPath) fieldTable(g, plan, code);
					cctor(g, plan, lower);
					if (failures.length == 0) lower.finish();
			});
		} catch (u:Unsupported) {
			if (u.pos == null) u.pos = m.pos;
			if (plan.isStd && !u.isBug) stub = u else failures.push(u);
		}
		if (failures.length > 0) {
			for (u in failures) g.report(u);
			return;
		}
		var body = if (stub != null) {
			g.records.push("stubbed " + what + ": " + stub.what);
			stubBody(g, stub.isError ? "hxc dotnet: " + what + ": " + stub.what
				: "hxc dotnet: " + what + " uses " + stub.what + ", which " + stub.verb() + " not supported yet");
		} else {
			var localsSig = code.locals.length == 0 ? 0 : g.mb.standAloneSig(g.sigs.locals(code.locals));
			if (g.pdb != null) g.pdb.method(m.token, localsSig, code);
			code.body(localsSig);
		}
		g.mb.setBody(m.token, body);
	}

	// A property's accessor, as C# compiles gencs's `get { return _get_X(); }` and `set { _set_X(value); }`:
	// a call of the private body, whose value the setter drops.
	static function accessorBody(p:PropertyPlan, isSet:Bool, code:IlCode):Void {
		var body = isSet ? p.setBody : p.getBody;
		if (body == null) throw "internal error: the property " + p.name + " has an accessor without a body";
		code.ldarg(0);
		if (isSet) code.ldarg(1);
		code.opToken(IlOps.CALL, body.token, isSet ? 2 : 1, body.ret.match(LVoid) ? 0 : 1);
		if (isSet && !body.ret.match(LVoid)) code.op(IlOps.POP, 1, 0);
		code.op(IlOps.RET, isSet ? 0 : 1, 0);
	}

	// A @:property var's accessor, as Roslyn compiles an auto-property's: `ldarg.0; ldfld; ret` and
	// `ldarg.0; ldarg.1; stfld; ret`, or for a static `ldsfld; ret` and `ldarg.0; stsfld; ret`. A generic
	// class's accessor reaches the field through the class's own instantiation.
	static function backingAccessorBody(g:DotnetCtx, plan:ClassPlan, p:PropertyPlan, isSet:Bool, code:IlCode):Void {
		var f = p.backing;
		var token = plan.classParams.length == 0 ? f.token : g.mb.memberRef(g.typeTokenOf(plan.thisSig), f.name, g.sigs.field(f.sig));
		if (p.isStatic) {
			if (isSet) code.ldarg(0);
			code.opToken(isSet ? IlOps.STSFLD : IlOps.LDSFLD, token, isSet ? 1 : 0, isSet ? 0 : 1);
		} else {
			code.ldarg(0);
			if (isSet) code.ldarg(1);
			code.opToken(isSet ? IlOps.STFLD : IlOps.LDFLD, token, isSet ? 2 : 1, isSet ? 0 : 1);
		}
		code.op(IlOps.RET, isSet ? 0 : 1, 0);
	}

	// A statement outside any block, reported like a block's own in user code.
	static function statement(lower:TexprToIl, ret:Ret, e:TExpr):Void {
		if (lower.onError == null) {
			lower.statementPoint(e);
			lower.texpr(ret, e);
			return;
		}
		lower.texpr(ret, {expr: TBlock([e]), type: e.type, pos: e.pos});
	}

	// gencs's guard: `if (C<object>.__hx_init_called) return; C<object>.__hx_init_called = true;`.
	static function initGuard(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var inst = [for (_ in plan.classParams) LObject];
		var owner = plan.isStruct ? LValueType(plan.path, inst) : LClass(plan.path, inst);
		var flag = g.mb.memberRef(g.typeTokenOf(owner), initFlagName, g.sigs.field(LBool));
		var go = code.newLabel();
		code.opToken(IlOps.LDSFLD, flag, 0, 1);
		code.branch(IlOps.BRFALSE, go);
		code.op(IlOps.RET, 0, 0);
		code.mark(go);
		code.ldcI4(1);
		code.opToken(IlOps.STSFLD, flag, 1, 0);
	}

	public static inline final fieldLookupPath = "cs.internal.FieldLookup";

	// FieldLookup's first snapshot, `new FieldTable(ids, names)` with every name FieldHashes recorded,
	// sorted by hash, as gencs fills `fieldIds` and `fields` (gencs.ml). FieldLookup's methods are
	// emitted after every other class's, so the table has them all; nothing in its .cctor comes before.
	static function fieldTable(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var tableField = plan.c.statics.get("table");
		var tableClass = g.runtimeClass("cs.internal.FieldTable");
		var tablePlan = tableClass == null ? null : g.planOf.get(tableClass);
		var ctor = null;
		if (tablePlan != null) for (m in tablePlan.methods) if (m.name == ".ctor" && m.args.length == 2) ctor = m;
		var token = tableField == null ? null : g.fieldTokens.get(tableField);
		if (ctor == null || token == null) throw "internal error: haxe.lang.FieldLookup has no table";
		var entries = FieldHashes.table();
		code.ldcI4(entries.length);
		code.opToken(IlOps.NEWARR, g.typeTokenOf(LInt32), 1, 1);
		for (i in 0...entries.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			code.ldcI4(entries[i].id);
			code.stelem(LInt32, () -> g.typeTokenOf(LInt32));
		}
		code.ldcI4(entries.length);
		code.opToken(IlOps.NEWARR, g.typeTokenOf(LString), 1, 1);
		for (i in 0...entries.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			code.opToken(IlOps.LDSTR, g.mb.userString(entries[i].name), 0, 1);
			code.opToken(IlOps.STELEM, g.typeTokenOf(LString), 3, 0);
		}
		code.opToken(IlOps.NEWOBJ, ctor.token, 2, 1);
		code.op(IlOps.VOLATILE, 0, 0);
		code.opToken(IlOps.STSFLD, token, 1, 0);
	}

	// gencommon's order: @:readOnly initializers, which C# runs as field initializers first, then
	// __init__, then the other static var initializers in declaration order. FieldLookup's table is
	// fieldTable's.
	static function cctor(g:DotnetCtx, plan:ClassPlan, lower:TexprToIl):Void {
		var c = plan.c;
		var readOnly = [], others = [];
		for (f in plan.fields) if (f.flags & FieldAttrs.STATIC != 0 && f.cf.expr != null) {
			if (plan.hxPath == fieldLookupPath && f.cf.name == "table") continue;
			var assign:TExpr = {
				expr: TBinop(OpAssign, {expr: TField({expr: TTypeExpr(TClassDecl(c)), type: f.cf.type, pos: f.cf.pos}, FStatic(c, f.cf)), type: f.cf.type, pos: f.cf.pos}, g.exprOf(f.cf)),
				type: f.cf.type,
				pos: f.cf.pos
			};
			(TypeFunctions.hasMeta(":readOnly", f.cf.meta) ? readOnly : others).push(assign);
		}
		var init = g.initOf(c);
		var exprs = readOnly.concat(init == null ? [] : [init]).concat(others);
		var block:TExpr = {expr: TBlock(exprs), type: TypeFunctions.tDynamic, pos: c.pos};
		lower.texpr(RVoid, block);
	}

	// The body of a standard-library method that uses something not supported yet.
	public static function stubBody(g:DotnetCtx, message:String):haxe.io.Bytes {
		var code = new IlCode("a stub");
		var ex = LClass({ns: ["System"], nested: [], name: "NotSupportedException"}, []);
		code.opToken(IlOps.LDSTR, g.mb.userString(message), 0, 1);
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(ex), ".ctor", g.sigs.method(true, LVoid, [LString], 0)), 1, 1);
		code.op(IlOps.THROW, 1, 0);
		return code.body(0);
	}
}
