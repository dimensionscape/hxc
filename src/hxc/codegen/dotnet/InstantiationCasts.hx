package hxc.codegen.dotnet;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;

// gencs's casts between instantiations of a generic Haxe class (realTypeParams.ml's RealTypeParams
// filter; casts notes §1). A value going to an instantiation of an hxgeneric class or interface that it
// is not already is cast with the class's static helper:
//
//     (X<int>) X<object>.__hx_cast<int>((X) value)
//
// which gives the object itself when its type arguments are the ones asked for, and otherwise copies it
// into a new instantiation (CompanionToIl's X_cast). An interface's helper is on its `X__Statics_`
// class. A class that is not hxgeneric keeps its type arguments and gets C#'s cast. A value typed as the
// companion (an X<Dynamic>) is cast the same way. A value going to the companion, which every
// instantiation implements, gets no __hx_cast: a typed one needs nothing, anything else a castclass.
class InstantiationCasts {
	// The reference `from` on the stack as `to`, an instantiation of a generic Haxe class: nothing when
	// the erased instantiations are equal; otherwise castclass to the companion, the helper with `to`'s
	// type arguments, then castclass to `to`. Unsupported for an hxgeneric class without a companion (a
	// generic struct or a local function's class), whose instantiations share no CLR type to cast through.
	public static function emit(g:DotnetCtx, code:IlCode, from:IlSigNorm, to:IlSigNorm):Void {
		if (IlPaths.sigEq(from, to)) return;
		var c = classOf(g, to);
		if (c == null || !HxGeneric.isHxGeneric(g, c)) {
			code.opToken(DotnetTypes.isValueType(to) ? IlOps.UNBOX_ANY : IlOps.CASTCLASS, g.typeTokenOf(to), 1, 1);
			return;
		}
		if (!g.hasCompanion(c)) throw new Unsupported("a cast between instantiations of " + g.haxePathOf(to), false);
		var companion = g.companionOf(c);
		if (!g.isUpcast(from, companion)) code.opToken(IlOps.CASTCLASS, g.typeTokenOf(companion), 1, 1);
		code.opToken(IlOps.CALL, g.mb.methodSpec(g.castHelperOf(c), g.sigs.methodSpec(argsOf(to))), 1, 1);
		code.opToken(IlOps.CASTCLASS, g.typeTokenOf(to), 1, 1);
	}

	// Whether the Haxe type `t`, through typedefs, is a @:multiType abstract (Map).
	public static function isMultiType(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): TypeFunctions.hasMeta(":multiType", a.meta);
			case _: false;
		}
	}

	static function classOf(g:DotnetCtx, s:IlSigNorm):Null<TClass> {
		return switch (s) {
			case LClass(p, _) | LValueType(p, _): g.classAt(p);
			case _: null;
		}
	}

	static function argsOf(s:IlSigNorm):Array<IlSigNorm> {
		return switch (s) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
	}
}
