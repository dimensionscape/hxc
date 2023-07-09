package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.Texpr;
import hxc.core.WithType;
import hxc.core.Globals;
import hxc.core.TypingError;

enum ConKind {
	ConConst(c:TConstant);
	ConEnum(e:TEnum, ef:TEnumField);
	ConStatic(c:TClass, cf:TClassField);
	ConTypeExpr(mt:ModuleType);
	ConFields(fields:Array<String>);
	ConArray(i:Int);
}

typedef Con = {kind:ConKind, pos:Position};

class Constructor {
	public static inline function make(kind:ConKind, pos:Position):Con {
		return {kind: kind, pos: pos};
	}

	static function sConst(ct:TConstant):String {
		return switch (ct) {
			case TInt(i): Std.string(i);
			case TFloat(f): f;
			case TString(s): '"' + s + '"';
			case TBool(b): b ? "true" : "false";
			case TNull: "null";
			case TThis: "this";
			case TSuper: "super";
		};
	}

	static function constEq(a:TConstant, b:TConstant):Bool {
		return switch ([a, b]) {
			case [TInt(i1), TInt(i2)]: i1 == i2;
			case [TFloat(f1), TFloat(f2)]: f1 == f2;
			case [TString(s1), TString(s2)]: s1 == s2;
			case [TBool(b1), TBool(b2)]: b1 == b2;
			case [TNull, TNull] | [TThis, TThis] | [TSuper, TSuper]: true;
			case _: false;
		};
	}

	public static function toString(con:Con):String {
		return switch (con.kind) {
			case ConConst(ct): sConst(ct);
			case ConEnum(_, ef): ef.name;
			case ConStatic(c, cf):
				var path = switch (c.kind) { case KAbstractImpl(a): a.path; case _: c.path; };
				Globals.sTypePath(path) + "." + cf.name;
			case ConTypeExpr(mt): Globals.sTypePath(TypeFunctions.tInfos(mt).path);
			case ConFields(fields): "{ " + fields.join(", ") + " }";
			case ConArray(i): "<array " + i + ">";
		};
	}

	// Equal (physical equality for enum/class/type; structural for constants).
	public static function equal(con1:Con, con2:Con):Bool {
		return switch ([con1.kind, con2.kind]) {
			case [ConConst(ct1), ConConst(ct2)]: constEq(ct1, ct2);
			case [ConEnum(en1, ef1), ConEnum(en2, ef2)]: en1 == en2 && ef1 == ef2;
			case [ConStatic(c1, cf1), ConStatic(c2, cf2)]: c1 == c2 && cf1 == cf2;
			case [ConTypeExpr(mt1), ConTypeExpr(mt2)]: mt1 == mt2;
			case [ConFields(_), ConFields(_)]: true;
			case [ConArray(i1), ConArray(i2)]: i1 == i2;
			case _: false;
		};
	}

	public static function arity(con:Con):Int {
		return switch (con.kind) {
			case ConEnum(_, ef): switch (ef.type) { case TFun(sig): sig.args.length; case _: 0; };
			case ConConst(_): 0;
			case ConFields(fields): fields.length;
			case ConArray(i): i;
			case ConTypeExpr(_): 0;
			case ConStatic(_, _): 0;
		};
	}

	// Compare (ordering for the decision-tree tables).
	public static function compare(con1:Con, con2:Con):Int {
		inline function cmpStr(a:String, b:String):Int return a < b ? -1 : (a > b ? 1 : 0);
		return switch ([con1.kind, con2.kind]) {
			case [ConConst(ct1), ConConst(ct2)]: cmpStr(sConst(ct1), sConst(ct2));
			case [ConEnum(_, ef1), ConEnum(_, ef2)]: ef1.index - ef2.index;
			case [ConStatic(_, cf1), ConStatic(_, cf2)]: cmpStr(cf1.name, cf2.name);
			case [ConTypeExpr(mt1), ConTypeExpr(mt2)]: cmpStr(Globals.sTypePath(TypeFunctions.tInfos(mt1).path), Globals.sTypePath(TypeFunctions.tInfos(mt2).path));
			case [ConFields(_), ConFields(_)]: 0;
			case [ConArray(i1), ConArray(i2)]: i1 - i2;
			case _: -1;
		};
	}

	public static function toTexpr(ctx:TyperContext, matchDebug:Bool, con:Con):TExpr {
		var p = con.pos;
		var basic = ctx.com.basic;
		return switch (con.kind) {
			case ConEnum(_, ef):
				matchDebug ? Texpr.makeString(basic, ef.name, p) : Texpr.makeInt(basic, ef.index, p);
			case ConConst(ct): Texpr.makeConstTexpr(basic, ct, p);
			case ConArray(i): Texpr.makeInt(basic, i, p);
			case ConStatic(c, cf): Texpr.makeStaticField(c, cf, p);
			case ConTypeExpr(_): throw new TypingError("Constructor.to_texpr for a type expression is not yet ported", p);
			case ConFields(_): throw new TypingError("Something went wrong", p);
		};
	}
}
