package hxc.codegen.dotnet;

import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.core.Type;
import hxc.core.TypeFunctions;

// What a class's generic analysis found: hxgeneric, not, or not known yet because it reached a class
// whose own analysis is still running.
private enum Found {
	Yes;
	No;
	Unresolved;
}

// Which generic classes gencs treats as "hxgeneric" (realTypeParams.ml's set_hxgeneric): it erases their
// type arguments and gives them a companion interface and casts. A generic class or interface that
// gencs generates with its own model (HxGen.isHxGen; a @:nativeGen subclass of an hxgen class is one)
// is hxgeneric unless its superclass is not (a generic one that is not hxgeneric, or a non-generic one
// that is not hxgen, such as a @:nativeGen or .NET class), or one of its instance variables has, after
// typedefs, Null and abstracts, the type of a generic class that is not hxgeneric applied to something
// with a type parameter in it (`var l:List_1<T>`). cs.NativeArray<T> does not count, as gencs casts its
// type parameter itself, and neither does a Haxe enum, which is no generic class in the CLR. Any other
// generic class keeps its type arguments as they are ("native generic").
//
// gencs runs the analysis in passes. A class it reaches while that class's own analysis is still
// running is unresolved, which is no evidence against either, and a class with no evidence against it
// is hxgeneric in the end. Evidence against is final, so a No is kept at once; a Yes that leaned on an
// unresolved class is kept only for the class whose analysis started the walk, the one every
// unresolved reference leads back to.
class HxGeneric {
	// Whether the class `c` is hxgeneric; false for a class without type parameters.
	public static function isHxGeneric(g:DotnetCtx, c:TClass):Bool {
		if (c.params.length == 0 || c.kind.match(KTypeParameter(_))) return false;
		var known = g.hxGenericClasses.get(c);
		if (known != null) return known;
		var r = new HxGeneric(g).ofClass(c) != No;
		g.hxGenericClasses.set(c, r);
		return r;
	}

	final g:DotnetCtx;
	// The classes whose analysis is running, outermost first.
	final running:Array<ModuleType> = [];

	function new(g:DotnetCtx) {
		this.g = g;
	}

	function isRunning(mt:ModuleType):Bool {
		for (r in running) switch [r, mt] {
			case [TClassDecl(a), TClassDecl(b)] if (a == b): return true;
			case _:
		}
		return false;
	}

	function ofClass(c:TClass):Found {
		// A superclass without type parameters is evidence for when it is hxgen, against otherwise (a
		// @:nativeGen or .NET one).
		if (c.params.length == 0) return HxGen.isHxGen(TClassDecl(c)) ? Yes : No;
		var known = g.hxGenericClasses.get(c);
		if (known != null) return known ? Yes : No;
		if (isRunning(TClassDecl(c))) return Unresolved;
		// A local generic function's class (ClosuresToClass) is instantiated with the function's type
		// arguments as gencs binds them for the call, erased as a generic method's are.
		if (g.closureOwners.exists(c)) return keepClass(c, Yes);
		// is_hxgen decides, not @:nativeGen alone: a @:nativeGen subclass of an hxgen class is hxgen.
		if (!HxGen.isHxGen(TClassDecl(c))) return keepClass(c, No);
		running.push(TClassDecl(c));
		var r = try {
			var sup = c.superClass == null ? Yes : ofClass(c.superClass.c);
			if (sup == No) No else {
				var found = sup;
				for (cf in c.orderedFields) {
					var f = ofVariable(cf.type);
					if (f == No) {
						found = No;
						break;
					}
					if (f == Unresolved) found = Unresolved;
				}
				found;
			}
		} catch (e:Dynamic) {
			running.pop();
			throw e;
		}
		running.pop();
		// Every unresolved reference leads back to a type on the walk; with none left but this one, the
		// evidence is complete.
		if (r == Unresolved && running.length == 0) r = Yes;
		return r == Unresolved ? r : keepClass(c, r);
	}

	function keepClass(c:TClass, r:Found):Found {
		g.hxGenericClasses.set(c, r == Yes);
		return r;
	}

	// The evidence an instance variable of type `t` gives: No when it is a generic class that is not
	// hxgeneric, applied to a type parameter somewhere.
	function ofVariable(t:T):Found {
		var r = realType(t);
		return switch (r) {
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))): Yes;
			case TInst(c, _) if (hasTypeParams(r)):
				if (c.path.name == "NativeArray" && c.path.pack.length == 1 && c.path.pack[0] == "cs") Yes else ofClass(c);
			// A Haxe enum is no generic class in the CLR, so no evidence either way.
			case _: Yes;
		}
	}

	// gencs's real type: typedefs, Null and abstracts that are not core types followed to what they stand
	// for.
	static function realType(t:T):T {
		var cur = TypeFunctions.follow(t);
		for (_ in 0...50) switch (cur) {
			case TAbstract(a, pl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				cur = TypeFunctions.follow(TypeFunctions.getUnderlyingType(a, pl));
			case _:
				return cur;
		}
		return cur;
	}

	// has_type_params: whether a type parameter occurs in `t`, through type arguments and function types.
	public static function hasTypeParams(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))): true;
			case TInst(_, l) | TEnum(_, l) | TAbstract(_, l):
				for (p in l) if (hasTypeParams(p)) return true;
				false;
			case TFun(sig):
				for (a in sig.args) if (hasTypeParams(a.t)) return true;
				hasTypeParams(sig.ret);
			case _: false;
		}
	}
}
