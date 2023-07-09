package hxc.core;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.Ref;

class Texpr {
	public static inline function makeInt(basic:BasicTypes, i:Int, p:Position):TExpr {
		return TypeFunctions.mk(TConst(TInt(i)), basic.tint, p);
	}

	public static inline function makeFloat(basic:BasicTypes, f:String, p:Position):TExpr {
		return TypeFunctions.mk(TConst(TFloat(f)), basic.tfloat, p);
	}

	public static inline function makeBool(basic:BasicTypes, b:Bool, p:Position):TExpr {
		return TypeFunctions.mk(TConst(TBool(b)), basic.tbool, p);
	}

	public static inline function makeString(basic:BasicTypes, s:String, p:Position):TExpr {
		return TypeFunctions.mk(TConst(TString(s)), basic.tstring, p);
	}

	public static inline function makeNull(t:T, p:Position):TExpr {
		return TypeFunctions.mk(TConst(TNull), t, p);
	}

	public static inline function makeLocal(v:TVar, p:Position):TExpr {
		return TypeFunctions.mk(TLocal(v), v.type, p);
	}

	public static function makeStaticThis(c:TClass, p:Position):TExpr {
		var ta = TypeFunctions.mkAnon(new Ref(Statics(c)), c.statics);
		return TypeFunctions.mk(TTypeExpr(TClassDecl(c)), ta, p);
	}

	public static function makeConstTexpr(basic:BasicTypes, ct:TConstant, p:Position):TExpr {
		return switch (ct) {
			case TString(s): TypeFunctions.mk(TConst(TString(s)), basic.tstring, p);
			case TInt(i): TypeFunctions.mk(TConst(TInt(i)), basic.tint, p);
			case TFloat(f): TypeFunctions.mk(TConst(TFloat(f)), basic.tfloat, p);
			case TBool(b): TypeFunctions.mk(TConst(TBool(b)), basic.tbool, p);
			case TNull: TypeFunctions.mk(TConst(TNull), basic.tnull(TypeFunctions.mkMono()), p);
			case _: throw new TypingError("Unsupported constant", p);
		};
	}

	public static inline function makeThrow(e:TExpr, p:Position):TExpr {
		return TypeFunctions.mk(TThrow(e), TDynamic(null), p);
	}

	public static inline function mkParent(e:TExpr):TExpr {
		return TypeFunctions.mk(TParenthesis(e), e.type, e.pos);
	}

	public static function ensureParent(e:TExpr):TExpr {
		return switch (e.expr) {
			case TParenthesis(_): e;
			case _: mkParent(e);
		};
	}

	public static inline function mkReturn(e:TExpr):TExpr {
		return TypeFunctions.mk(TReturn(e), TDynamic(null), e.pos);
	}

	public static inline function binop(op:Binop, a:TExpr, b:TExpr, t:T, p:Position):TExpr {
		return TypeFunctions.mk(TBinop(op, a, b), t, p);
	}

	public static inline function index(basic:BasicTypes, e:TExpr, idx:Int, t:T, p:Position):TExpr {
		return TypeFunctions.mk(TArray(e, makeInt(basic, idx, p)), t, p);
	}

	// Suffix-less; the typer handles i32/i64/u32/f64 suffixes
	// before reaching here.
	public static function typeConstant(basic:BasicTypes, c:Constant, p:Position):TExpr {
		return switch (c) {
			case CInt(s, _):
				if (s.length > 10 && s.substr(0, 2) == "0x") throw new TypingError("Invalid hexadecimal integer", p);
				var i = Std.parseInt(s);
				if (i == null || i < -2147483648 || i > 2147483647) TypeFunctions.mk(TConst(TFloat(s)), basic.tfloat, p);
				else TypeFunctions.mk(TConst(TInt(i)), basic.tint, p);
			case CFloat(f, _): TypeFunctions.mk(TConst(TFloat(f)), basic.tfloat, p);
			case CString(s, _): TypeFunctions.mk(TConst(TString(s)), basic.tstring, p);
			case CIdent("true"): TypeFunctions.mk(TConst(TBool(true)), basic.tbool, p);
			case CIdent("false"): TypeFunctions.mk(TConst(TBool(false)), basic.tbool, p);
			case CIdent("null"): TypeFunctions.mk(TConst(TNull), basic.tnull(TypeFunctions.mkMono()), p);
			case CIdent(t): throw new TypingError("Invalid constant :  " + t, p);
			case CRegexp(_, _): throw new TypingError("Invalid constant", p);
		};
	}
}
