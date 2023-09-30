package hxc.core;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.Ref;
import hxc.core.TypingError;

class TexprTools {
	static inline var DE_ALIVE = 0;
	static inline var DE_DEAD = 1;
	static inline var DE_BREAK_CONTINUE = 2;

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

	public static function makeStaticField(c:TClass, cf:TClassField, p:Position):TExpr {
		var eThis = makeStaticThis(c, p);
		return TypeFunctions.mk(TField(eThis, FStatic(c, cf)), cf.type, p);
	}

	// Anon carrying the right status (Statics / EnumStatics / AbstractStatics).
	public static function makeTypeExpr(mt:ModuleType, p:Position):TExpr {
		var t = switch (TypeFunctions.resolveTypedef(mt)) {
			case TClassDecl(c): TypeFunctions.mkAnon(new Ref(Statics(c)), c.statics);
			case TEnumDecl(e): TypeFunctions.mkAnon(new Ref(EnumStatics(e)));
			case TAbstractDecl(a): TypeFunctions.mkAnon(new Ref(AbstractStatics(a)), a.impl != null ? a.impl.statics : null);
			case _: throw new TypingError("Invalid module type", p);
		};
		return TypeFunctions.mk(TTypeExpr(mt), t, p);
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

	static function isTrueExpr(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(TBool(true)): true;
			case TParenthesis(e1): isTrueExpr(e1);
			case _: false;
		};
	}

	static function isFalseExpr(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(TBool(false)): true;
			case TParenthesis(e1): isFalseExpr(e1);
			case _: false;
		};
	}

	static function isExhaustiveSwitch(e:TExpr, def:Null<TExpr>):Bool {
		if (def != null) return true;
		return switch (e.expr) {
			case TMeta(m, e1):
				m.name == ":exhaustive" || m.name == "exhaustive" || isExhaustiveSwitch(e1, def);
			case TParenthesis(e1):
				isExhaustiveSwitch(e1, def);
			case _:
				false;
		};
	}

	static inline function seq(a:Int, b:Void->Int):Int {
		return a == DE_ALIVE ? b() : a;
	}

	static function anyDead(el:Array<TExpr>):Int {
		for (e in el) {
			var r = deadEndState(e);
			if (r != DE_ALIVE) return r;
		}
		return DE_ALIVE;
	}

	static function deadEndState(e:TExpr):Int {
		return switch (e.expr) {
			case TBreak | TContinue:
				DE_BREAK_CONTINUE;
			case TThrow(e1):
				var r = deadEndState(e1);
				r == DE_BREAK_CONTINUE ? r : DE_DEAD;
			case TReturn(eo):
				switch (eo) {
					case null: DE_DEAD;
					case e1:
						var r = deadEndState(e1);
						r == DE_BREAK_CONTINUE ? r : DE_DEAD;
				}
			case TFunction(_):
				DE_ALIVE;
			case TIf(cond, eif, eelse):
				var rc = deadEndState(cond);
				if (rc != DE_ALIVE) rc;
				else switch (eelse) {
					case null: DE_ALIVE;
					case ee:
						var r1 = deadEndState(eif);
						var r2 = deadEndState(ee);
						if (r1 == DE_BREAK_CONTINUE || r2 == DE_BREAK_CONTINUE) DE_BREAK_CONTINUE;
						else (r1 == DE_DEAD && r2 == DE_DEAD) ? DE_DEAD : DE_ALIVE;
				}
			case TSwitch(e1, cases, def):
				var r = deadEndState(e1);
				if (r != DE_ALIVE) r;
				else if (!isExhaustiveSwitch(e1, def)) DE_ALIVE;
				else {
					var out = DE_DEAD;
					for (c in cases) {
						var cr = anyDead(c.values);
						if (cr == DE_ALIVE) cr = deadEndState(c.expr);
						if (cr == DE_BREAK_CONTINUE) { out = DE_BREAK_CONTINUE; break; }
						if (cr == DE_ALIVE) { out = DE_ALIVE; break; }
					}
					if (out == DE_DEAD && def != null) out = deadEndState(def);
					out;
				}
			case TFor(_, e1, _):
				deadEndState(e1);
			case TBinop(OpBoolAnd, e1, e2):
				var r = deadEndState(e1);
				if (r != DE_ALIVE) r else isTrueExpr(e1) ? deadEndState(e2) : DE_ALIVE;
			case TBinop(OpBoolOr, e1, e2):
				var r = deadEndState(e1);
				if (r != DE_ALIVE) r else isFalseExpr(e1) ? deadEndState(e2) : DE_ALIVE;
			case TWhile(cond, body, flag):
				var r = deadEndState(cond);
				if (r != DE_ALIVE) r;
				else {
					var br = deadEndState(body);
					var bodyDead = br == DE_DEAD;
					((flag == DoWhile || isTrueExpr(cond)) && bodyDead) ? DE_DEAD : DE_ALIVE;
				}
			case TTry(e1, catches):
				if (catches.length == 0) deadEndState(e1);
				else {
					var out = DE_DEAD;
					for (c in catches) {
						var cr = deadEndState(c.expr);
						if (cr == DE_BREAK_CONTINUE) { out = DE_BREAK_CONTINUE; break; }
						if (cr == DE_ALIVE) { out = DE_ALIVE; break; }
					}
					out;
				}
			case TArray(e1, e2) | TBinop(_, e1, e2):
				seq(deadEndState(e1), function() return deadEndState(e2));
			case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TCast(e1, _) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1):
				deadEndState(e1);
			case TVarExpr(_, eo):
				eo == null ? DE_ALIVE : deadEndState(eo);
			case TObjectDecl(fields):
				for (f in fields) {
					var r = deadEndState(f.expr);
					if (r != DE_ALIVE) return r;
				}
				DE_ALIVE;
			case TArrayDecl(el) | TBlock(el):
				anyDead(el);
			case TCall(e1, el):
				seq(deadEndState(e1), function() return anyDead(el));
			case TNew(_, _, el):
				anyDead(el);
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TIdent(_):
				DE_ALIVE;
		};
	}

	public static function hasDeadEnd(e:TExpr):Bool {
		return deadEndState(e) != DE_ALIVE;
	}

	public static inline function index(basic:BasicTypes, e:TExpr, idx:Int, t:T, p:Position):TExpr {
		return TypeFunctions.mk(TArray(e, makeInt(basic, idx, p)), t, p);
	}

	// Suffix-less; the typer handles i32/i64/u32/f64 suffixes
	// before reaching here.
	static function decimalFitsInt32(s:String):Bool {
		var neg = s.charAt(0) == "-";
		var body = neg ? s.substr(1) : s;
		if (body.length >= 2 && body.substr(0, 2).toLowerCase() == "0x") return true;
		while (body.length > 1 && body.charAt(0) == "0") body = body.substr(1);
		for (i in 0...body.length) {
			var c = body.charCodeAt(i);
			if (c < "0".code || c > "9".code) return false;
		}
		var max = neg ? "2147483648" : "2147483647";
		if (body.length != max.length) return body.length < max.length;
		return body <= max;
	}

	public static function typeConstant(basic:BasicTypes, c:Constant, p:Position):TExpr {
		return switch (c) {
			case CInt(s, _):
				// Numeric separators are kept in the literal string (for macro reflection) but dropped when
				// computing the value.
				var s = StringTools.replace(s, "_", "");
				if (s.length > 10 && s.substr(0, 2) == "0x") throw new TypingError("Invalid hexadecimal integer", p);
				var i = decimalFitsInt32(s) ? Std.parseInt(s) : null;
				if (i == null || i < -2147483648 || i > 2147483647) TypeFunctions.mk(TConst(TFloat(s)), basic.tfloat, p);
				else TypeFunctions.mk(TConst(TInt(i)), basic.tint, p);
			case CFloat(f, _): TypeFunctions.mk(TConst(TFloat(StringTools.replace(f, "_", ""))), basic.tfloat, p);
			case CString(s, _): TypeFunctions.mk(TConst(TString(s)), basic.tstring, p);
			case CIdent("true"): TypeFunctions.mk(TConst(TBool(true)), basic.tbool, p);
			case CIdent("false"): TypeFunctions.mk(TConst(TBool(false)), basic.tbool, p);
			case CIdent("null"): TypeFunctions.mk(TConst(TNull), basic.tnull(TypeFunctions.mkMono()), p);
			case CIdent(t): throw new TypingError("Invalid constant :  " + t, p);
			case CRegexp(_, _): throw new TypingError("Invalid constant", p);
		};
	}
}
