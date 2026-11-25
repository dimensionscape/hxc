package hxc.codegen.dotnet;

import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlData;

// Something the generator cannot compile yet. `what` names it for "dotnet: <what> is not supported
// yet"; `plural` picks "are". A null position is filled in by the expression or member being lowered.
class Unsupported {
	public var what:String;
	public var pos:Null<Position>;
	public var plural:Bool;
	// A bug in hxc rather than a missing feature: reported as "dotnet: <what>", in std code as well.
	public var isBug = false;
	// A compile error rather than a missing feature: reported as "dotnet: <what>", and stubbed in std code.
	public var isError = false;
	// One of the Haxe compiler's own errors, which gencs raises too: a compile error reported as "<what>",
	// without "dotnet: ".
	public var isHaxe = false;

	public function new(what:String, plural:Bool, ?pos:Position) {
		this.what = what;
		this.plural = plural;
		this.pos = pos;
	}

	public static function bug(what:String):Unsupported {
		var u = new Unsupported(what, false);
		u.isBug = true;
		return u;
	}

	public static function error(what:String):Unsupported {
		var u = new Unsupported(what, false);
		u.isError = true;
		return u;
	}

	public static function haxeError(what:String, pos:Position):Unsupported {
		var u = error(what);
		u.isHaxe = true;
		u.pos = pos;
		return u;
	}

	public function verb():String return plural ? "are" : "is";

	public function toString():String return "Unsupported(" + what + ")";
}

// How DotnetTypes.inferParams meets a position, as Haxe's unification: `Covariant` is unify(applied,
// declared), `Contravariant` unify(declared, applied), `Invariant` type_eq (a type argument).
private enum Variance {
	Covariant;
	Contravariant;
	Invariant;
}

// Haxe types as CLR signatures, as gencs maps them.
class DotnetTypes {
	final ctx:Context;
	final mb:ModuleBuilder;
	// The generation these types belong to, for HxGeneric; DotnetCtx sets it.
	public var g:Null<DotnetCtx> = null;

	// The types left out of the assembly, keyed by Haxe path, with the reason; GenerateDotnet fills it.
	public final leftOut = new Map<String, String>();

	// The type parameters of the class and method whose signatures are being written.
	var classParams:TypeParams = [];
	var methodParams:TypeParams = [];

	public function new(ctx:Context, mb:ModuleBuilder) {
		this.ctx = ctx;
		this.mb = mb;
	}

	public function withParams<R>(classParams:TypeParams, methodParams:TypeParams, f:() -> R):R {
		var oc = this.classParams, om = this.methodParams;
		this.classParams = classParams;
		this.methodParams = methodParams;
		try {
			var r = f();
			this.classParams = oc;
			this.methodParams = om;
			return r;
		} catch (e:Dynamic) {
			this.classParams = oc;
			this.methodParams = om;
			throw e;
		}
	}

	// The class type parameters signatures are being written in terms of.
	public function currentClassParams():TypeParams return classParams;

	// The method type parameters signatures are being written in terms of.
	public function currentMethodParams():TypeParams return methodParams;

	// The type parameter in scope with this name, the method's before the class's, or null.
	public function paramNamed(name:String):Null<T> {
		for (p in methodParams) if (p.name == name) return p.type;
		for (p in classParams) if (p.name == name) return p.type;
		return null;
	}

	public function inParams(classParams:TypeParams, methodParams:TypeParams, f:() -> Void):Void {
		withParams(classParams, methodParams, () -> {
			f();
			return true;
		});
	}

	public static function haxePath(mt:ModuleType):String {
		var infos = TypeFunctions.tInfos(mt);
		for (m in infos.meta)
			if (m.name == ":realPath" && m.params.length == 1) switch (m.params[0].expr) {
				case EConst(CString(s, _)): return s;
				case _:
			}
		return Globals.sTypePath(infos.path);
	}

	static function isPath(p:Path, pack:Array<String>, name:String):Bool {
		return p.name == name && IlPaths.strsEq(p.pack, pack);
	}

	public static function isSystemEnum(p:IlPath):Bool {
		return p.name == "Enum" && p.nested.length == 0 && IlPaths.strsEq(p.ns, ["System"]);
	}

	// System.Nullable<T>, the .NET `T?` (not haxe.lang.Null<T>, which Null<T> of a value type is).
	public static function isSystemNullable(s:IlSigNorm):Bool {
		return switch (s) {
			case LValueType(p, [_]): p.name == "Nullable`1" && p.nested.length == 0 && IlPaths.strsEq(p.ns, ["System"]);
			case _: false;
		}
	}

	// Whether gencs wraps `s` in haxe.lang.Null<T> (is_cs_basic_type): a value type, or System.Enum, a class
	// that gencs's @:struct extern counts as one.
	public static function takesNullOf(s:IlSigNorm):Bool {
		return switch (s) {
			case LClass(p, []): isSystemEnum(p);
			case _: isValueType(s);
		}
	}

	public static function isValueType(s:IlSigNorm):Bool {
		return switch (s) {
			case LBool | LChar | LInt8 | LUInt8 | LInt16 | LUInt16 | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64
				| LIntPtr | LUIntPtr | LTypedReference | LValueType(_, _):
				true;
			case _: false;
		}
	}

	// The primitive a System type is written as in a signature, or null.
	public static function primitive(p:IlPath):Null<IlSigNorm> {
		if (p.nested.length > 0 || p.ns.length != 1 || p.ns[0] != "System") return null;
		return switch (p.name) {
			case "Object": LObject;
			case "String": LString;
			case "Boolean": LBool;
			case "Char": LChar;
			case "SByte": LInt8;
			case "Byte": LUInt8;
			case "Int16": LInt16;
			case "UInt16": LUInt16;
			case "Int32": LInt32;
			case "UInt32": LUInt32;
			case "Int64": LInt64;
			case "UInt64": LUInt64;
			case "Single": LFloat32;
			case "Double": LFloat64;
			case "IntPtr": LIntPtr;
			case "UIntPtr": LUIntPtr;
			case "TypedReference": LTypedReference;
			case _: null;
		}
	}

	// The System type of a primitive, for the tokens box and unbox.any take.
	public static function primitivePath(s:IlSigNorm):Null<IlPath> {
		var name = switch (s) {
			case LObject: "Object";
			case LString: "String";
			case LBool: "Boolean";
			case LChar: "Char";
			case LInt8: "SByte";
			case LUInt8: "Byte";
			case LInt16: "Int16";
			case LUInt16: "UInt16";
			case LInt32: "Int32";
			case LUInt32: "UInt32";
			case LInt64: "Int64";
			case LUInt64: "UInt64";
			case LFloat32: "Single";
			case LFloat64: "Double";
			case LIntPtr: "IntPtr";
			case LUIntPtr: "UIntPtr";
			case LTypedReference: "TypedReference";
			case _: return null;
		}
		return {ns: ["System"], nested: [], name: name};
	}

	// The .NET path of an extern class or enum: the referenced assemblies' own, else @:native.
	public function externPathOf(mt:ModuleType):IlPath {
		var infos = TypeFunctions.tInfos(mt);
		var p = ctx.netPathMap.get(Globals.sTypePath(infos.path));
		if (p != null) return p;
		var native = DotnetNames.nativeName(infos.meta);
		if (native != null) {
			// A loaded library's type, nested ones included: their @:native joins the enclosing types with
			// dots, which the split below would make a namespace.
			var q = ctx.netDottedMap.get(native);
			if (q != null) return q;
			var parts = native.split(".");
			var name = parts.pop();
			return {ns: parts, nested: [], name: name};
		}
		throw new Unsupported("the extern type " + Globals.sTypePath(infos.path) + " without a .NET name", false);
	}

	public function externPath(c:TClass):Null<IlPath> {
		return externPathOf(TClassDecl(c));
	}

	// A referenced type must come from an assembly NetRefs finds.
	function defined(p:IlPath):IlPath {
		var refs = NetRefs.of(ctx);
		if (refs.definer(p) != null) return p;
		throw Unsupported.error(refs.missing(p));
	}

	// A type the assembly defines, unless it was left out.
	public function checkKept(mt:ModuleType):Void {
		var key = haxePath(mt);
		var why = leftOut.get(key);
		if (why != null) throw new Unsupported(key + " (left out: " + why + ")", false);
	}

	// Whether the type parameter `tp` is `c`. The typer keeps a constrained parameter's type behind a
	// TLazy, so a structural match on the raw type misses it.
	public static function isParam(tp:TypedTypeParam, c:TClass):Bool {
		var t = tp.type;
		while (t.match(TLazy(_))) switch (t) {
			case TLazy(f): t = TypeFunctions.lazyType(f);
			case _:
		}
		return switch (t) {
			case TInst(c2, _): c2 == c;
			case _: false;
		}
	}

	function typeParam(c:TClass):IlSigNorm {
		for (i in 0...classParams.length) if (isParam(classParams[i], c)) return LTypeParam(i);
		for (i in 0...methodParams.length) if (isParam(methodParams[i], c)) return LMethodTypeParam(i);
		// A type parameter of a local function or one the signature does not declare.
		return LObject;
	}

	static final systemType:IlPath = {ns: ["System"], nested: [], name: "Type"};

	var typesByPath:Null<Map<String, ModuleType>> = null;

	// The program's class or enum with this Haxe path, or null.
	public function typeNamed(hxPath:String):Null<ModuleType> {
		if (typesByPath == null) {
			typesByPath = new Map();
			for (mt in ctx.types) switch (mt) {
				case TClassDecl(_) | TEnumDecl(_): typesByPath.set(haxePath(mt), mt);
				case _:
			}
		}
		return typesByPath.get(hxPath);
	}

	// The CLR path of a standard-library class or enum the mapping needs, which must be kept; without
	// it, `what` is not supported.
	public function stdClassPath(hxPath:String, what:String, plural:Bool):IlPath {
		var mt = typeNamed(hxPath);
		if (mt == null) throw new Unsupported(what, plural);
		checkKept(mt);
		return DotnetNames.typePath(mt);
	}

	// Replaces class type parameters with `classArgs` and method type parameters with `methodArgs`.
	public static function substitute(s:IlSigNorm, classArgs:Array<IlSigNorm>, methodArgs:Array<IlSigNorm>):IlSigNorm {
		inline function all(l:Array<IlSigNorm>) return [for (a in l) substitute(a, classArgs, methodArgs)];
		return switch (s) {
			case LTypeParam(i) if (i < classArgs.length): classArgs[i];
			case LMethodTypeParam(i) if (i < methodArgs.length): methodArgs[i];
			case LPointer(t): LPointer(substitute(t, classArgs, methodArgs));
			case LManagedPointer(t): LManagedPointer(substitute(t, classArgs, methodArgs));
			case LVector(t): LVector(substitute(t, classArgs, methodArgs));
			case LArray(t, d): LArray(substitute(t, classArgs, methodArgs), d);
			case LValueType(p, l): LValueType(p, all(l));
			case LClass(p, l): LClass(p, all(l));
			case LMethod(cc, r, l): LMethod(cc, substitute(r, classArgs, methodArgs), all(l));
			case _: s;
		}
	}

	// The types `params` stand for where `declared`, written in terms of them, meets the applied type
	// `actual`, as gencs infers a generic method's type arguments; Dynamic where nothing binds one. gencs
	// unifies, by Haxe's rules, each argument's applied type with its declared one and the return's
	// likewise, the return first, and the first binding stays. A local generic function's whole function
	// type is unified instead (`localFunction`), so its arguments are met as a function type's are. A
	// plain T binds what it meets, so the typer's Null<Int> stays Null<Int> (haxe.lang.Null<int>, gencs's
	// object). Where a declared Null<T> meets a Null<Int> depends on the position's variance: as an
	// argument or a return, T binds Int (gencs's `wrap<int>(nn.@value)` for `wrap<T>(x:T):Null<T>`, where
	// a null becomes 0, an hxcs bug kept); inside a function-typed argument's own arguments, Null<Int>
	// (`cbn<object>` for `cbn<T>(f:Null<T>->Bool, x:T)`); inside a type argument, one Null level per side
	// (`retNullArr<object>` for `retNullArr<T>(x:T):Array<Null<T>>`). What `given` binds already stays.
	public static function inferParams(params:TypeParams, declared:T, actual:T, localFunction:Bool, ?given:Array<Null<T>>):Array<T> {
		var bound:Array<Null<T>> = given != null ? given.copy() : [for (_ in params) null];
		function indexOf(c:TClass):Int {
			for (i in 0...params.length) if (isParam(params[i], c)) return i;
			return -1;
		}
		function nullArg(t:T):Null<T> {
			return switch (t) {
				case TAbstract(a, [t1]) if (a.path.pack.length == 0 && a.path.name == "Null"): t1;
				case _: null;
			}
		}
		// A Null<Null<Int>> binds as the one Null<Int> it stands for.
		function bind(i:Int, a:T):Void {
			var t = TypeFunctions.follow(a);
			if (bound[i] != null || t.match(TMono(_))) return;
			bound[i] = switch (a) {
				case TAbstract(n, [_]) if (nullArg(a) != null): TAbstract(n, [t]);
				case _: t;
			}
		}
		function walk(d:T, a:T, v:Variance, depth:Int):Void {
			if (depth > 20) return;
			d = TypeFunctions.followWithoutNull(d);
			a = TypeFunctions.followWithoutNull(a);
			switch (d) {
				case TInst(c, []) if (c.kind.match(KTypeParameter(_)) && indexOf(c) >= 0):
					bind(indexOf(c), a);
					return;
				case _:
			}
			var dn = nullArg(d), an = nullArg(a);
			switch (v) {
				// unify takes every Null off its left side (the applied type when covariant, the declared one
				// when contravariant) before the one on its right.
				case Covariant if (an != null):
					walk(d, an, v, depth + 1);
					return;
				case Contravariant if (dn != null):
					walk(dn, a, v, depth + 1);
					return;
				// type_eq takes one Null off each side.
				case _ if (dn != null || an != null):
					walk(dn != null ? dn : d, an != null ? an : a, v, depth + 1);
					return;
				case _:
			}
			switch (d) {
				case TInst(c, dl):
					switch (a) {
						case TInst(c2, al) if (c2 == c && al.length == dl.length): for (i in 0...dl.length) walk(dl[i], al[i], Invariant, depth + 1);
						case _:
					}
				case TAbstract(x, dl):
					switch (a) {
						case TAbstract(x2, al) if (x2 == x && al.length == dl.length): for (i in 0...dl.length) walk(dl[i], al[i], Invariant, depth + 1);
						case _:
					}
				case TEnum(x, dl):
					switch (a) {
						case TEnum(x2, al) if (x2 == x && al.length == dl.length): for (i in 0...dl.length) walk(dl[i], al[i], Invariant, depth + 1);
						case _:
					}
				case TFun(ds):
					// A function type's arguments unify the other way round.
					var flipped = switch (v) {
						case Covariant: Contravariant;
						case Contravariant: Covariant;
						case Invariant: Invariant;
					}
					switch (a) {
						case TFun(as) if (as.args.length == ds.args.length):
							walk(ds.ret, as.ret, v, depth + 1);
							for (i in 0...ds.args.length) walk(ds.args[i].t, as.args[i].t, flipped, depth + 1);
						case _:
					}
				case _:
			}
		}
		switch [TypeFunctions.followWithoutNull(declared), TypeFunctions.followWithoutNull(actual)] {
			case [TFun(ds), TFun(as)] if (!localFunction && as.args.length == ds.args.length):
				walk(ds.ret, as.ret, Covariant, 1);
				for (i in 0...ds.args.length) walk(ds.args[i].t, as.args[i].t, Covariant, 1);
			case _:
				walk(declared, actual, Covariant, 0);
		}
		return [for (b in bound) b == null ? TypeFunctions.tDynamic : b];
	}

	// gencs's haxe.lang.Null<T> of `s`.
	public function nullOf(s:IlSigNorm):IlSigNorm {
		return LValueType(stdClassPath("cs.internal._Null.Nullable", "Null<T> of a value type", false), [s]);
	}

	// Whether `s` is an instantiation of haxe.lang.Null<T>.
	public function isNullOf(s:IlSigNorm):Bool {
		return switch (s) {
			case LValueType(p, [_]): IlPaths.key(p) == IlPaths.key(stdClassPath("cs.internal._Null.Nullable", "Null<T> of a value type", false));
			case _: false;
		}
	}

	// A method argument's type. An optional argument of a value type, which only a default value makes
	// (`?x:Int` is a Null<Int> already), is a haxe.lang.Null<T>, as gencs's default arguments are.
	public function argSig(t:T, opt:Bool):IlSigNorm {
		var s = toSig(t);
		return opt && takesNullOf(s) && !isNullOf(s) ? nullOf(s) : s;
	}

	// The CLR type arguments of the class `c` applied to `params`, as gencs's change_param_type gives
	// them. An hxgeneric class's (HxGeneric) are erased by `typeArg`, all of them to object when one is
	// Dynamic; any other generic's (a .NET one, a @:nativeGen or native generic Haxe class) keep their
	// types, except that a Null<T> of a value type is object there too.
	public function classArgs(c:TClass, params:Array<T>):Array<IlSigNorm> {
		if (params.length == 0) return [];
		if (!HxGeneric.isHxGeneric(g, c)) return [for (a in params) nativeArg(a)];
		if (hasDynamicArg(params)) return [for (_ in params) LObject];
		return [for (a in params) typeArg(a)];
	}

	// An argument of a generic that is not hxgeneric, or of a generic .NET method: its own type, but never
	// a haxe.lang.Null.
	public function nativeArg(t:T):IlSigNorm {
		var s = toSig(t);
		return isNullOf(s) ? LObject : s;
	}

	// Whether one of `params`, through typedefs and Null, is Dynamic, which makes gencs type the
	// instantiation as its companion interface and instantiate it with object for every argument. An
	// unbound monomorph counts, as in gencs: `var a = []` is a `global::Array`, and so is the result of
	// `Std.downcast(d, Array)`.
	public static function hasDynamicArg(params:Array<T>):Bool {
		for (p in params) switch (TypeFunctions.follow(p)) {
			case TDynamic(_) | TMono(_): return true;
			case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Dynamic"): return true;
			case _:
		}
		return false;
	}

	// One type argument of an hxgeneric instantiation, as gencs erases it (types notes §1): a type
	// parameter stays; a basic type is its CLR type (Int, Float, Bool, UInt, Single, the cs.StdTypes
	// integers, Int64, an abstract over one of them, a .NET struct or enum, a @:nativeGen flat enum);
	// String, Null<String> and an abstract over String are string; everything else is object, Null<Int>
	// and every other Null<T> included.
	public function typeArg(t:T):IlSigNorm {
		return switch (t) {
			case TMono(m): m.type == null ? LObject : typeArg(m.type);
			case TLazy(f): typeArg(TypeFunctions.lazyType(f));
			case TType(d, params): typeArg(TypeFunctions.applyTypedef(d, params));
			case TDynamic(_) | TAnon(_) | TFun(_): LObject;
			case TAbstract(a, [p]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				typeArg(p).match(LString) ? LString : LObject;
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))): typeParam(c);
			case TInst(c, _) if (isPath(c.path, [], "String")): LString;
			// A Haxe class is object, unless it is a struct.
			case TInst(c, _) if (!TypeFunctions.hasClassFlag(c, CExtern) && !TypeFunctions.hasMeta(":struct", c.meta)): LObject;
			// A Haxe enum is object, unless it is a CLR enum.
			case TEnum(e, _) if (!e.isExtern && !HxGen.isClrEnum(e)): LObject;
			// A non-core abstract stands for its underlying type.
			case TAbstract(a, params) if (!TypeFunctions.hasMeta(":coreType", a.meta) && !isPath(a.path, ["cs", "_Flags"], "EnumUnderlying")):
				typeArg(TypeFunctions.getUnderlyingType(a, params));
			case _:
				switch (toSig(t)) {
					case s = LBool | LChar | LInt8 | LUInt8 | LInt16 | LUInt16 | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64 | LIntPtr | LUIntPtr:
						s;
					case s = LValueType(_, _) if (!isNullOf(s)): s;
					case LString: LString;
					case s = LTypeParam(_) | LMethodTypeParam(_): s;
					case _: LObject;
				}
		}
	}

	// The CLR class of the Haxe class `c` applied to `params`, as an extends or implements clause, a `new`
	// or a member access names it: never the companion interface, which toSig gives for a Dynamic
	// argument; ``X`1<object>`` instead.
	public function classSig(c:TClass, params:Array<T>):IlSigNorm {
		if (TypeFunctions.hasClassFlag(c, CExtern) || c.kind.match(KTypeParameter(_)) || isPath(c.path, [], "String")) return toSig(TInst(c, params));
		checkKept(TClassDecl(c));
		var p = DotnetNames.typePath(TClassDecl(c));
		var args = classArgs(c, params);
		return TypeFunctions.hasMeta(":struct", c.meta) ? LValueType(p, args) : LClass(p, args);
	}

	// Whether toSig gives `t` as a companion interface: through typedefs, Null and abstracts that are not
	// core types, an instantiation with a Dynamic argument of an hxgeneric class or interface that has a
	// companion (types notes §1). Members are reached through such a value as types notes §5 has it.
	public function isCompanionTyped(t:T):Bool {
		for (_ in 0...50) switch (t) {
			case TMono(m):
				if (m.type == null) return false;
				t = m.type;
			case TLazy(f):
				t = TypeFunctions.lazyType(f);
			case TType(d, [_]) if (isPath(d.path, ["cs"], "Ref") || isPath(d.path, ["cs"], "Out")):
				return false;
			case TType(d, params):
				t = TypeFunctions.applyTypedef(d, params);
			case TInst(c, params):
				return !c.kind.match(KTypeParameter(_)) && !TypeFunctions.hasClassFlag(c, CExtern) && hasDynamicArg(params) && g != null
					&& g.hasCompanion(c);
			case TAbstract(a, [p]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				t = p;
			case TAbstract(a, params) if (!TypeFunctions.hasMeta(":coreType", a.meta) && !isPath(a.path, ["cs", "_Flags"], "EnumUnderlying")):
				t = TypeFunctions.getUnderlyingType(a, params);
			case _:
				return false;
		}
		return false;
	}

	public function toSig(t:T):IlSigNorm {
		return switch (t) {
			case TMono(m): m.type == null ? LObject : toSig(m.type);
			case TLazy(f): toSig(TypeFunctions.lazyType(f));
			case TDynamic(_) | TAnon(_): LObject;
			case TFun(_): LClass(stdClassPath("cs.internal.Function", "function types", true), []);
			case TType(d, [p]) if (isPath(d.path, ["cs"], "Ref") || isPath(d.path, ["cs"], "Out")):
				LManagedPointer(toSig(p));
			case TType(d, params): toSig(TypeFunctions.applyTypedef(d, params));
			case TEnum(e, params):
				if (!e.isExtern) {
					checkKept(TEnumDecl(e));
					// A @:nativeGen flat enum is a CLR enum.
					if (HxGen.isClrEnum(e)) return LValueType(DotnetNames.typePath(TEnumDecl(e)), []);
					// gencs's enum class (EnumToIl), whose type parameters are erased: Opt<String> is Opt.
					if (HxGen.isHxGen(TEnumDecl(e))) return LClass(DotnetNames.typePath(TEnumDecl(e)), []);
					throw new Unsupported("@:nativeGen enums with type parameters", true);
				}
				LValueType(defined(externPathOf(TEnumDecl(e))), []);
			case TInst(c, params):
				switch (c.kind) {
					case KTypeParameter(_): return typeParam(c);
					case _:
				}
				if (isPath(c.path, [], "String")) return LString;
				if (TypeFunctions.hasClassFlag(c, CExtern)) {
					if (isPath(c.path, ["cs"], "NativeArray")) return LVector(toSig(params[0]));
					var p = externPath(c);
					var prim = primitive(p);
					if (prim != null) return prim;
					var args = classArgs(c, params);
					defined(p);
					// System.Enum extends System.ValueType, so it is a @:struct extern, but the CLR has it a class.
					TypeFunctions.hasMeta(":struct", c.meta) && !isSystemEnum(p) ? LValueType(p, args) : LClass(p, args);
				} else {
					// An instantiation with a Dynamic argument is the class's companion interface (types notes §1); one
					// of a class without a companion (a generic struct or a local function's class) keeps X<object…>.
					if (hasDynamicArg(params) && g != null && g.hasCompanion(c)) {
						checkKept(TClassDecl(c));
						return g.companionOf(c);
					}
					classSig(c, params);
				}
			case TAbstract(a, params):
				var p = a.path;
				if (p.pack.length == 0) switch (p.name) {
					case "Int": return LInt32;
					case "Float": return LFloat64;
					case "Bool": return LBool;
					case "Void": return LVoid;
					case "Single": return LFloat32;
					case "UInt": return LUInt32;
					case "Dynamic": return LObject;
					// gencs's real type of EnumValue is Dynamic.
					case "EnumValue": return LObject;
					case "Null":
						// gencs's haxe.lang.Null<T>, the standard library's cs.internal.Null struct, for a value
						// type and, as gencs has it, for a type parameter, which may stand for one.
						var s = toSig(params[0]);
						if ((takesNullOf(s) || s.match(LTypeParam(_) | LMethodTypeParam(_))) && !isNullOf(s))
							return nullOf(s);
						return s;
					case "Class" | "Enum":
						return LClass(defined(systemType), []);
					case _:
				}
				if (isPath(p, ["cs"], "Pointer")) {
					// gencs writes a Pointer<Dynamic> as `void*`, not `object*`.
					switch (TypeFunctions.follow(params[0])) {
						case TDynamic(_): return LPointer(LVoid);
						case TAbstract(da, _) if (da.path.pack.length == 0 && da.path.name == "Dynamic"): return LPointer(LVoid);
						case _:
					}
					return LPointer(toSig(params[0]));
				}
				if (p.pack.length == 1 && p.pack[0] == "cs" && p.name != "Pointer" && a.module.path.name == "StdTypes") switch (p.name) {
					case "Int8": return LInt8;
					case "Int16": return LInt16;
					case "Char16": return LChar;
					case "UInt8": return LUInt8;
					case "UInt16": return LUInt16;
					case "Int64": return LInt64;
					case "UInt64": return LUInt64;
					case _:
				}
				// cs.Flags's EnumUnderlying<T> is the .NET enum T itself, as gencs writes it.
				if (isPath(p, ["cs", "_Flags"], "EnumUnderlying")) return toSig(params[0]);
				if (TypeFunctions.hasMeta(":coreType", a.meta)) throw new Unsupported("the core type " + Globals.sTypePath(p), false);
				toSig(TypeFunctions.getUnderlyingType(a, params));
		}
	}
}
