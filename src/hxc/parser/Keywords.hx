package hxc.parser;

import hxc.ast.Ast;
import hxc.ast.Ast.Keyword;

class Keywords {
	static final list:Array<Keyword> = [
		KwdFunction, KwdClass, KwdStatic, KwdVar, KwdIf, KwdElse, KwdWhile, KwdDo, KwdFor,
		KwdBreak, KwdReturn, KwdContinue, KwdExtends, KwdImplements, KwdImport,
		KwdSwitch, KwdCase, KwdDefault, KwdPublic, KwdPrivate, KwdTry, KwdUntyped,
		KwdCatch, KwdNew, KwdThis, KwdThrow, KwdExtern, KwdEnum, KwdIn, KwdInterface,
		KwdCast, KwdOverride, KwdDynamic, KwdTypedef, KwdPackage,
		KwdInline, KwdUsing, KwdNull, KwdTrue, KwdFalse, KwdAbstract, KwdMacro, KwdFinal,
		KwdOperator, KwdOverload,
	];

	static final h:Map<String, Keyword> = {
		var m = new Map<String, Keyword>();
		for (k in list)
			m.set(Ast.sKeyword(k), k);
		m;
	};

	public static inline function lookup(s:String):Null<Keyword> {
		return h.get(s);
	}
}
