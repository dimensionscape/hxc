package hxc.codegen.dotnet;

import hxc.core.Type;
import hxc.core.TypeFunctions;

// A constructor a class has as gencs sees it: its own, one cloned from the nearest ancestor that has
// constructors (each calling super(...) with its arguments), or the empty `new()` a class gets when no
// ancestor has one. Lists of them put a constructor's overloads before it, as gencs writes them.
// `origin` is the Haxe or .NET constructor the arguments reach (its own, or the ancestor's one it was
// cloned from), null for the empty one and for a clone of an ancestor's empty one; `clone` tells a
// clone, which calls super(...), from the empty one, which does not; `args` are in terms of the
// class's type parameters.
typedef HaxeCtor = {origin:Null<TClassField>, own:Null<TClassField>, clone:Bool, args:Array<{name:String, t:T, opt:Bool}>};

// Which types gencs generates with its own class model (setHXGen.ml), and the names that model uses.
// An "hxgen" class extends haxe.lang.HxObject (or implements haxe.lang.IHxObject), gets a constructor
// taking haxe.lang.EmptyObject, and keeps its constructor bodies in static `__hx_ctor_*` methods
// (overloadingConstructor.ml).
class HxGen {
	public static function isHxGen(mt:ModuleType):Bool {
		return switch (mt) {
			case TClassDecl(c):
				switch (c.kind) {
					case KAbstractImpl(a): isHxGen(TAbstractDecl(a));
					case _: isHxGenClass(c);
				}
			case TEnumDecl(e):
				if (e.isExtern) TypeFunctions.hasMeta(":hxGen", e.meta) else !TypeFunctions.hasMeta(":nativeGen", e.meta);
			case TAbstractDecl(a):
				if (TypeFunctions.hasMeta(":coreType", a.meta)) {
					!TypeFunctions.hasMeta(":nativeGen", a.meta);
				} else switch (TypeFunctions.follow(a.thisType)) {
					case TInst(c, _): isHxGen(TClassDecl(c));
					case TEnum(e, _): isHxGen(TEnumDecl(e));
					case TAbstract(a2, _): isHxGen(TAbstractDecl(a2));
					case _: !TypeFunctions.hasMeta(":nativeGen", a.meta);
				}
			case TTypeDecl(_): false;
		}
	}

	static function superOrInterfaceHxGen(c:TClass):Bool {
		if (c.superClass != null && isHxGenClass(c.superClass.c)) return true;
		for (i in c.interfaces) if (isHxGenClass(i.c)) return true;
		return false;
	}

	static function isHxGenClass(c:TClass):Bool {
		if (TypeFunctions.hasClassFlag(c, CExtern)) return TypeFunctions.hasMeta(":hxGen", c.meta) || superOrInterfaceHxGen(c);
		if (TypeFunctions.hasMeta(":nativeChildren", c.meta) || TypeFunctions.hasMeta(":nativeGen", c.meta) || TypeFunctions.hasMeta(":struct", c.meta))
			return superOrInterfaceHxGen(c);
		// Below a @:nativeChildren class (that is not hxgen itself), only an hxgen interface makes it hxgen.
		function hasNativeChildren(c:TClass):Bool {
			if (isHxGenClass(c)) return false;
			if (TypeFunctions.hasMeta(":struct", c.meta)) return true;
			if (TypeFunctions.hasMeta(":nativeChildren", c.meta) && !superOrInterfaceHxGen(c)) return true;
			return c.superClass != null && hasNativeChildren(c.superClass.c);
		}
		if (c.superClass != null && hasNativeChildren(c.superClass.c)) {
			for (i in c.interfaces) if (isHxGenClass(i.c)) return true;
			return false;
		}
		return true;
	}

	// The classes overloadingConstructor.ml gives constructors: not interfaces, abstract implementations
	// or module-level fields.
	public static function hasCtorModel(c:TClass):Bool {
		if (TypeFunctions.hasClassFlag(c, CInterface) || TypeFunctions.hasClassFlag(c, CExtern)) return false;
		return switch (c.kind) {
			case KAbstractImpl(_) | KModuleFields(_): false;
			case _: isHxGenClass(c);
		}
	}

	// descends_from_native_or_skipctor: the class or an ancestor is not hxgen or has @:skipCtor. Such a
	// class keeps C#'s own constructor chain, with no static constructors.
	public static function descendsFromNative(c:TClass):Bool {
		var cur = c;
		while (cur != null) {
			if (!isHxGenClass(cur) || TypeFunctions.hasMeta(":skipCtor", cur.meta)) return true;
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return false;
	}

	// Whether the class derives from haxe.lang.HxObject.
	public static function derivesFromHxObject(c:TClass):Bool {
		if (c.kind.match(KTypeParameter(_) | KAbstractImpl(_)) || TypeFunctions.hasClassFlag(c, CInterface) || TypeFunctions.hasMeta(":struct", c.meta)
			|| !isHxGen(TClassDecl(c))) return false;
		// The root of its superclasses has to be the class that extends HxObject (TclassToIl): a
		// @:nativeGen or an extern root makes the base of the whole chain instead.
		var root = c;
		while (root.superClass != null) root = root.superClass.c;
		return hasCtorModel(root) && !TypeFunctions.hasMeta(":struct", root.meta);
	}

	public static function ctorName(c:TClass):String {
		return "__hx_ctor_" + c.path.pack.join("_") + "_" + c.path.name;
	}

	// A @:nativeGen flat enum, which gencs writes as a CLR enum.
	public static function isClrEnum(e:TEnum):Bool {
		return !e.isExtern && e.params.length == 0 && TypeFunctions.hasMeta(":nativeGen", e.meta) && TypeFunctions.hasMeta(":flatEnum", e.meta);
	}

	static function funArgs(t:T):Array<{name:String, t:T, opt:Bool}> {
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig): [for (a in sig.args) {name: a.name, t: a.t, opt: a.opt}];
			case _: throw "internal error: a constructor without a function type";
		}
	}

	// The class's constructors. Only a class with no ancestor constructor at all gets the empty `new()`:
	// a superclass in the model has constructors of its own by then (its own, clones or its empty
	// one), so its subclasses clone them, as overloadingConstructor processes superclasses first. A
	// class outside gencs's model (@:nativeGen, a struct) has its own, or the parameterless one C#
	// gives it.
	public static function ctors(c:TClass):Array<HaxeCtor> {
		var ctor = c.constructor;
		if (ctor != null && !TypeFunctions.hasClassFieldFlag(ctor, CfExtern)) {
			var r:Array<HaxeCtor> = [];
			for (f in ctor.overloads.concat([ctor]))
				if (f.expr != null) r.push({origin: f, own: f, clone: false, args: funArgs(f.type)});
			if (r.length > 0) return r;
		}
		if (hasCtorModel(c)) {
			var prev = previousCtors(c);
			if (prev.length > 0) return [for (p in prev) {origin: p.origin, own: null, clone: true, args: p.args}];
		}
		return [{origin: null, own: null, clone: false, args: []}];
	}

	// The constructors of the nearest ancestor that has any (prev_ctor), with their arguments in terms
	// of `c`'s type parameters, the main one last; .NET constructors marked @:skipCtor are left out.
	public static function previousCtors(c:TClass):Array<{origin:Null<TClassField>, args:Array<{name:String, t:T, opt:Bool}>, owner:TClass}> {
		var s = c.superClass;
		if (s == null) return [];
		inline function applied(args:Array<{name:String, t:T, opt:Bool}>) {
			return [for (a in args) {name: a.name, t: TypeFunctions.applyParams(s.c.params, s.params, a.t), opt: a.opt}];
		}
		if (TypeFunctions.hasClassFlag(s.c, CExtern)) {
			var ctor = s.c.constructor;
			if (ctor == null) {
				var up = previousCtors(s.c);
				return [for (p in up) {origin: p.origin, args: applied(p.args), owner: p.owner}];
			}
			return [
				for (f in ctor.overloads.concat([ctor]))
					if (!TypeFunctions.hasMeta(":skipCtor", f.meta)) {origin: f, args: applied(funArgs(f.type)), owner: s.c}
			];
		}
		return [for (d in ctors(s.c)) {origin: d.origin, args: applied(d.args), owner: s.c}];
	}
}
