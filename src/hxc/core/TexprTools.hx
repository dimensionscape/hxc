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

	// Anon carrying the right status (Statics / EnumStatics / AbstractStatics). A typedef resolves to its
	// underlying module type, so the runtime value carries the concrete class/enum path.
	public static function makeTypeExpr(mt:ModuleType, p:Position):TExpr {
		var resolved = TypeFunctions.resolveTypedef(mt);
		var t = switch (resolved) {
			case TClassDecl(c): TypeFunctions.mkAnon(new Ref(Statics(c)), c.statics);
			case TEnumDecl(e): TypeFunctions.mkAnon(new Ref(EnumStatics(e)));
			case TAbstractDecl(a): TypeFunctions.mkAnon(new Ref(AbstractStatics(a)), a.impl != null ? a.impl.statics : null);
			case _: throw new TypingError("Invalid module type", p);
		};
		return TypeFunctions.mk(TTypeExpr(resolved), t, p);
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

	static function hexDigitValue(c:Int):Int {
		if (c >= "0".code && c <= "9".code) return c - "0".code;
		if (c >= "a".code && c <= "f".code) return c - "a".code + 10;
		if (c >= "A".code && c <= "F".code) return c - "A".code + 10;
		return -1;
	}

	// 32-bit literal semantics: a hex literal takes its bits (up to 8 digits, so
	// 0xFFFFFFFF is -1), a decimal one must fit the signed 32-bit range. Null on failure.
	public static function parseInt32Literal(s:String):Null<Int> {
		if (s.length >= 2 && s.substr(0, 2) == "0x") {
			if (s.length > 10 || s.length == 2) return null;
			var v = 0;
			for (ci in 2...s.length) {
				var d = hexDigitValue(s.charCodeAt(ci));
				if (d < 0) return null;
				v = (v << 4) | d;
			}
			return v;
		}
		if (!decimalFitsInt32(s)) return null;
		var i = Std.parseInt(s);
		if (i == null || i < -2147483648 || i > 2147483647) return null;
		return i;
	}

	public static function typeConstant(basic:BasicTypes, c:Constant, p:Position):TExpr {
		return switch (c) {
			case CInt(s, _):
				// Numeric separators are kept in the literal string (for macro reflection) but dropped when
				// computing the value.
				var s = StringTools.replace(s, "_", "");
				if (s.length > 10 && s.substr(0, 2) == "0x") throw new TypingError("Invalid hexadecimal integer", p);
				if (s.length >= 2 && s.substr(0, 2) == "0x") {
					// A hex literal takes its BITS: 0xFFFFFFFF is -1 (the 32-bit parse wraps;
					// Std.parseInt on hxcpp saturates instead).
					var v = 0;
					for (ci in 2...s.length) {
						var d = hexDigitValue(s.charCodeAt(ci));
						if (d < 0) throw new TypingError("Invalid hexadecimal integer", p);
						v = (v << 4) | d;
					}
					TypeFunctions.mk(TConst(TInt(v)), basic.tint, p);
				} else {
					var i = decimalFitsInt32(s) ? Std.parseInt(s) : null;
					if (i == null || i < -2147483648 || i > 2147483647) TypeFunctions.mk(TConst(TFloat(s)), basic.tfloat, p);
					else TypeFunctions.mk(TConst(TInt(i)), basic.tint, p);
				}
			// The raw literal is kept (numeric separators included); consumers that need the value parse
			// through parseFloatLit, which accepts underscores.
			case CFloat(f, _): TypeFunctions.mk(TConst(TFloat(f)), basic.tfloat, p);
			case CString(s, _): TypeFunctions.mk(TConst(TString(s)), basic.tstring, p);
			case CIdent("true"): TypeFunctions.mk(TConst(TBool(true)), basic.tbool, p);
			case CIdent("false"): TypeFunctions.mk(TConst(TBool(false)), basic.tbool, p);
			case CIdent("null"): TypeFunctions.mk(TConst(TNull), basic.tnull(TypeFunctions.mkMono()), p);
			case CIdent(t): throw new TypingError("Invalid constant :  " + t, p);
			case CRegexp(_, _): throw new TypingError("Invalid constant", p);
		};
	}

	// Fresh tvars for every declaration site so a stored typed expression re-inserts without sharing
	// variable slots with its original context; TConst TThis is rebuilt by fThis (the caller supplies the
	// enclosing context's this).
	public static function duplicateTvars(fThis:TExpr->TExpr, e:TExpr):TExpr {
		var vars:Map<Int, TVar> = new Map();
		function copyVar(v:TVar):TVar {
			var v2 = TypeFunctions.allocVar(v.kind, v.name, v.type, v.pos);
			v2.meta = v.meta;
			v2.extra = v.extra;
			v2.flags = v.flags;
			vars.set(v.id, v2);
			return v2;
		}
		function build(e:TExpr):TExpr {
			inline function mk2(ed:TExprExpr):TExpr return TypeFunctions.mk(ed, e.type, e.pos);
			return switch (e.expr) {
				case TVarExpr(v, eo):
					var v2 = copyVar(v);
					mk2(TVarExpr(v2, eo == null ? null : build(eo)));
				case TFor(v, e1, e2):
					var v2 = copyVar(v);
					mk2(TFor(v2, build(e1), build(e2)));
				case TTry(e1, catches):
					var e1b = build(e1);
					mk2(TTry(e1b, [for (c in catches) { var v2 = copyVar(c.v); {v: v2, expr: build(c.expr)}; }]));
				case TFunction(f):
					var args:Array<TFuncArg> = [for (a in f.args) {v: copyVar(a.v), c: a.c}];
					mk2(TFunction(new TFunc(args, f.type, build(f.expr))));
				case TLocal(v):
					var v2 = vars.get(v.id);
					v2 == null ? e : mk2(TLocal(v2));
				case TConst(TThis):
					fThis(e);
				case TConst(_) | TTypeExpr(_) | TIdent(_) | TBreak | TContinue:
					e;
				case TArray(e1, e2): mk2(TArray(build(e1), build(e2)));
				case TBinop(op, e1, e2): mk2(TBinop(op, build(e1), build(e2)));
				case TField(e1, fa): mk2(TField(build(e1), fa));
				case TParenthesis(e1): mk2(TParenthesis(build(e1)));
				case TObjectDecl(fl): mk2(TObjectDecl([for (f in fl) {key: f.key, expr: build(f.expr)}]));
				case TArrayDecl(el): mk2(TArrayDecl([for (x in el) build(x)]));
				case TCall(e1, el): mk2(TCall(build(e1), [for (x in el) build(x)]));
				case TNew(c, tl, el): mk2(TNew(c, tl, [for (x in el) build(x)]));
				case TUnop(op, flag, e1): mk2(TUnop(op, flag, build(e1)));
				case TBlock(el): mk2(TBlock([for (x in el) build(x)]));
				case TIf(c, e1, e2): mk2(TIf(build(c), build(e1), e2 == null ? null : build(e2)));
				case TWhile(c, e1, flag): mk2(TWhile(build(c), build(e1), flag));
				case TSwitch(e1, cases, edef):
					mk2(TSwitch(build(e1), [for (c in cases) {values: [for (x in c.values) build(x)], expr: build(c.expr)}], edef == null ? null : build(edef)));
				case TReturn(eo): mk2(TReturn(eo == null ? null : build(eo)));
				case TThrow(e1): mk2(TThrow(build(e1)));
				case TCast(e1, mt): mk2(TCast(build(e1), mt));
				case TMeta(m, e1): mk2(TMeta(m, build(e1)));
				case TEnumParameter(e1, ef, i): mk2(TEnumParameter(build(e1), ef, i));
				case TEnumIndex(e1): mk2(TEnumIndex(build(e1)));
			};
		}
		return build(e);
	}

	static function safeForAll2<A, B>(f:(a:A, b:B)->Bool, l1:Array<A>, l2:Array<B>):Bool {
		if (l1.length != l2.length) return false;
		for (i in 0...l1.length) if (!f(l1[i], l2[i])) return false;
		return true;
	}

	// Same class and equal name is the same field, so value equality on the name is enough.
	public static function equalFa(fa1:TFieldAccess, fa2:TFieldAccess):Bool {
		return switch ([fa1, fa2]) {
			case [FStatic(c1, cf1), FStatic(c2, cf2)]: c1 == c2 && cf1.name == cf2.name;
			case [FInstance(c1, tl1, cf1), FInstance(c2, tl2, cf2)]:
				c1 == c2 && safeForAll2(TypeUnification.typeIseqDefault, tl1, tl2) && cf1.name == cf2.name;
			case [FAnon(cf1), FAnon(cf2)]: cf1.name == cf2.name;
			case [FDynamic(s1), FDynamic(s2)]: s1 == s2;
			case [FClosure(null, cf1), FClosure(null, cf2)]: cf1.name == cf2.name;
			case [FClosure(w1, cf1), FClosure(w2, cf2)] if (w1 != null && w2 != null):
				w1.c == w2.c && safeForAll2(TypeUnification.typeIseqDefault, w1.params, w2.params) && cf1.name == cf2.name;
			case [FEnum(en1, ef1), FEnum(en2, ef2)]: en1 == en2 && ef1.name == ef2.name;
			case _: false;
		};
	}

	// Structural equality with identity on vars, classes and fields.
	public static function equal(e1:TExpr, e2:TExpr):Bool {
		return switch ([e1.expr, e2.expr]) {
			case [TConst(ct1), TConst(ct2)]: std.Type.enumEq(ct1, ct2);
			case [TLocal(v1), TLocal(v2)]: v1 == v2;
			case [TArray(eb1, ei1), TArray(eb2, ei2)]: equal(eb1, eb2) && equal(ei1, ei2);
			case [TBinop(op1, l1, r1), TBinop(op2, l2, r2)]: std.Type.enumEq(op1, op2) && equal(l1, l2) && equal(r1, r2);
			case [TField(a1, fa1), TField(a2, fa2)]: equal(a1, a2) && equalFa(fa1, fa2);
			case [TTypeExpr(TClassDecl(c1)), TTypeExpr(TClassDecl(c2))]: c1 == c2;
			case [TTypeExpr(TEnumDecl(x1)), TTypeExpr(TEnumDecl(x2))]: x1 == x2;
			case [TTypeExpr(TTypeDecl(t1)), TTypeExpr(TTypeDecl(t2))]: t1 == t2;
			case [TTypeExpr(TAbstractDecl(a1)), TTypeExpr(TAbstractDecl(a2))]: a1 == a2;
			case [TTypeExpr(_), TTypeExpr(_)]: false;
			case [TParenthesis(a1), TParenthesis(a2)]: equal(a1, a2);
			case [TObjectDecl(fl1), TObjectDecl(fl2)]:
				safeForAll2(function(f1:TObjectField, f2:TObjectField) return f1.key.name == f2.key.name && equal(f1.expr, f2.expr), fl1, fl2);
			case [TArrayDecl(el1), TArrayDecl(el2)] | [TBlock(el1), TBlock(el2)]: safeForAll2(equal, el1, el2);
			case [TCall(a1, el1), TCall(a2, el2)]: equal(a1, a2) && safeForAll2(equal, el1, el2);
			case [TNew(c1, tl1, el1), TNew(c2, tl2, el2)]:
				c1 == c2 && safeForAll2(TypeUnification.typeIseqDefault, tl1, tl2) && safeForAll2(equal, el1, el2);
			case [TUnop(op1, flag1, a1), TUnop(op2, flag2, a2)]: std.Type.enumEq(op1, op2) && std.Type.enumEq(flag1, flag2) && equal(a1, a2);
			case [TFunction(tf1), TFunction(tf2)]: tf1 == tf2;
			case [TVarExpr(v1, null), TVarExpr(v2, null)]: v1 == v2;
			case [TVarExpr(v1, x1), TVarExpr(v2, x2)] if (x1 != null && x2 != null): v1 == v2 && equal(x1, x2);
			case [TFor(v1, ec1, eb1), TFor(v2, ec2, eb2)]: v1 == v2 && equal(ec1, ec2) && equal(eb1, eb2);
			case [TIf(a1, t1, null), TIf(a2, t2, null)]: equal(a1, a2) && equal(t1, t2);
			case [TIf(a1, t1, x1), TIf(a2, t2, x2)] if (x1 != null && x2 != null): equal(a1, a2) && equal(t1, t2) && equal(x1, x2);
			// Eb2 is compared with itself, so a while's body never affects equality.
			case [TWhile(a1, _, flag1), TWhile(a2, eb2, flag2)]: equal(a1, a2) && equal(eb2, eb2) && std.Type.enumEq(flag1, flag2);
			case [TSwitch(a1, cases1, def1), TSwitch(a2, cases2, def2)]:
				equal(a1, a2)
				&& safeForAll2(function(c1:TSwitchCase, c2:TSwitchCase) return safeForAll2(equal, c1.values, c2.values) && equal(c1.expr, c2.expr), cases1, cases2)
				&& (def1 == null ? def2 == null : (def2 != null && equal(def1, def2)));
			case [TTry(a1, catches1), TTry(a2, catches2)]:
				equal(a1, a2) && safeForAll2(function(c1:TCatch, c2:TCatch) return c1.v == c2.v && equal(c1.expr, c2.expr), catches1, catches2);
			case [TReturn(null), TReturn(null)]: true;
			case [TReturn(x1), TReturn(x2)] if (x1 != null && x2 != null): equal(x1, x2);
			case [TThrow(a1), TThrow(a2)]: equal(a1, a2);
			case [TCast(a1, null), TCast(a2, null)]: equal(a1, a2);
			case [TCast(a1, mt1), TCast(a2, mt2)] if (mt1 != null && mt2 != null):
				// Module-type identity, arm by arm
				equal(a1, a2) && switch ([mt1, mt2]) {
					case [TClassDecl(c1), TClassDecl(c2)]: c1 == c2;
					case [TEnumDecl(x1), TEnumDecl(x2)]: x1 == x2;
					case [TTypeDecl(t1), TTypeDecl(t2)]: t1 == t2;
					case [TAbstractDecl(b1), TAbstractDecl(b2)]: b1 == b2;
					case _: false;
				};
			case [TMeta(m1, a1), TMeta(m2, a2)]:
				m1.name == m2.name && safeForAll2(function(x1:Expr, x2:Expr) return hxc.ast.Ast.Printer.sExpr(x1) == hxc.ast.Ast.Printer.sExpr(x2), m1.params, m2.params) && equal(a1, a2);
			case [TBreak, TBreak] | [TContinue, TContinue]: true;
			case [TEnumParameter(a1, ef1, i1), TEnumParameter(a2, ef2, i2)]: equal(a1, a2) && ef1 == ef2 && i1 == i2;
			case _: false;
		};
	}

	// Collapse nested typeless casts to the same type.
	public static function reduceUnsafeCasts(e:TExpr, t:T, requireCast:Bool = false):TExpr {
		function sameType(t1:T, t2:T):Bool {
			return TypeUnification.fastEq(TypeFunctions.followWithoutNull(t1), TypeFunctions.followWithoutNull(t2));
		}
		function loop(e:TExpr):TExpr {
			return switch (e.expr) {
				case TCast(subject, null):
					var result = loop(subject);
					if (sameType(e.type, subject.type)) result
					else TypeFunctions.mk(TCast(result, null), e.type, e.pos);
				case _: e;
			};
		}
		var result = loop(e);
		return switch (result.expr) {
			case TCast(_, _): result;
			case _ if (requireCast): TypeFunctions.mk(TCast(result, null), e.type, e.pos);
			case _: result;
		};
	}

	public static function fieldOn(e:TExpr, name:String, t:T, p:Position):TExpr {
		var f = try TypeFunctions.quickField(e.type, name) catch (_:hxc.core.NotFound)
			throw new TypingError("Field " + name + " not found on " + hxc.core.TPrinting.sTypeStr(e.type), p);
		return TypeFunctions.mk(TField(e, f), t, p);
	}

	public static function fcall(e:TExpr, name:String, el:Array<TExpr>, ret:T, p:Position):TExpr {
		var ft = TypeFunctions.tfun([for (x in el) x.type], ret);
		return TypeFunctions.mk(TCall(fieldOn(e, name, ft, p), el), ret, p);
	}

	// True when the predicate holds for at least one direct sub-expression (the root itself is not
	// tested)
	public static function checkExpr(predicate:TExpr->Bool, e:TExpr):Bool {
		var found = false;
		iter(function(x) if (!found && predicate(x)) found = true, e);
		return found;
	}

	// True when `e` reads or assigns the local variable `v` anywhere in its tree (used to detect a
	// self-recursive named local function).
	public static function referencesLocal(e:TExpr, v:TVar):Bool {
		var found = false;
		function loop(e2:TExpr):Void {
			if (found) return;
			switch (e2.expr) {
				case TLocal(v2) if (v2 == v): found = true;
				case _: iter(loop, e2);
			}
		}
		loop(e);
		return found;
	}

	public static function iter(f:TExpr->Void, e:TExpr):Void {
		switch (e.expr) {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2) | TWhile(e1, e2, _):
				f(e1);
				f(e2);
			case TThrow(e1) | TField(e1, _) | TEnumParameter(e1, _, _) | TEnumIndex(e1) | TParenthesis(e1) | TCast(e1, _) | TUnop(_, _, e1) | TMeta(_, e1):
				f(e1);
			case TArrayDecl(el) | TNew(_, _, el) | TBlock(el):
				for (x in el) f(x);
			case TObjectDecl(fl):
				for (fd in fl) f(fd.expr);
			case TCall(e1, el):
				f(e1);
				for (x in el) f(x);
			case TVarExpr(_, eo):
				if (eo != null) f(eo);
			case TFunction(fu):
				f(fu.expr);
			case TIf(ec, e1, e2):
				f(ec);
				f(e1);
				if (e2 != null) f(e2);
			case TSwitch(e1, cases, def):
				f(e1);
				for (c in cases) {
					for (v in c.values) f(v);
					f(c.expr);
				}
				if (def != null) f(def);
			case TTry(e1, catches):
				f(e1);
				for (c in catches) f(c.expr);
			case TReturn(eo):
				if (eo != null) f(eo);
		}
	}

	// Rebuild e with f applied to each direct sub-expression.
	public static function mapExpr(f:TExpr->TExpr, e:TExpr):TExpr {
		inline function mk2(ed:TExprExpr):TExpr return TypeFunctions.mk(ed, e.type, e.pos);
		return switch (e.expr) {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
				e;
			case TArray(e1, e2):
				var e1 = f(e1);
				mk2(TArray(e1, f(e2)));
			case TBinop(op, e1, e2):
				var e1 = f(e1);
				mk2(TBinop(op, e1, f(e2)));
			case TFor(v, e1, e2):
				var e1 = f(e1);
				mk2(TFor(v, e1, f(e2)));
			case TWhile(e1, e2, flag):
				var e1 = f(e1);
				mk2(TWhile(e1, f(e2), flag));
			case TThrow(e1):
				mk2(TThrow(f(e1)));
			case TEnumParameter(e1, ef, i):
				mk2(TEnumParameter(f(e1), ef, i));
			case TEnumIndex(e1):
				mk2(TEnumIndex(f(e1)));
			case TField(e1, v):
				mk2(TField(f(e1), v));
			case TParenthesis(e1):
				mk2(TParenthesis(f(e1)));
			case TUnop(op, pre, e1):
				mk2(TUnop(op, pre, f(e1)));
			case TArrayDecl(el):
				mk2(TArrayDecl([for (x in el) f(x)]));
			case TNew(t, pl, el):
				mk2(TNew(t, pl, [for (x in el) f(x)]));
			case TBlock(el):
				mk2(TBlock([for (x in el) f(x)]));
			case TObjectDecl(fl):
				mk2(TObjectDecl([for (fd in fl) {key: fd.key, expr: f(fd.expr)}]));
			case TCall(e1, el):
				var e1 = f(e1);
				mk2(TCall(e1, [for (x in el) f(x)]));
			case TVarExpr(v, eo):
				mk2(TVarExpr(v, eo == null ? null : f(eo)));
			case TFunction(fu):
				mk2(TFunction(new TFunc(fu.args, fu.type, f(fu.expr))));
			case TIf(ec, e1, e2):
				var ec = f(ec);
				var e1 = f(e1);
				mk2(TIf(ec, e1, e2 == null ? null : f(e2)));
			case TSwitch(e1, cases, def):
				var e1 = f(e1);
				var cases = [for (c in cases) {values: [for (v in c.values) f(v)], expr: f(c.expr)}];
				mk2(TSwitch(e1, cases, def == null ? null : f(def)));
			case TTry(e1, catches):
				var e1 = f(e1);
				mk2(TTry(e1, [for (c in catches) {v: c.v, expr: f(c.expr)}]));
			case TReturn(eo):
				mk2(TReturn(eo == null ? null : f(eo)));
			case TCast(e1, t):
				mk2(TCast(f(e1), t));
			case TMeta(m, e1):
				mk2(TMeta(m, f(e1)));
		};
	}

	// Unwrap parens, meta, single-expr blocks and typeless casts.
	public static function skip(e:TExpr):TExpr {
		return switch (e.expr) {
			case TParenthesis(e1) | TMeta(_, e1) | TBlock([e1]) | TCast(e1, null): skip(e1);
			case _: e;
		};
	}

	static function foldmapList<A>(f:(acc:A, e:TExpr)->{acc:A, e:TExpr}, acc:A, el:Array<TExpr>):{acc:A, el:Array<TExpr>} {
		var acc2 = [];
		for (e1 in el) {
			var r = f(acc, e1);
			acc = r.acc;
			acc2.push(r.e);
		}
		return {acc: acc, el: acc2};
	}

	static function foldmapOpt<A>(f:(acc:A, e:TExpr)->{acc:A, e:TExpr}, acc:A, eo:Null<TExpr>):{acc:A, eo:Null<TExpr>} {
		if (eo == null) return {acc: acc, eo: null};
		var r = f(acc, eo);
		return {acc: r.acc, eo: r.e};
	}

	// mapExpr threading an accumulator through the sub-expressions.
	public static function foldmap<A>(f:(acc:A, e:TExpr)->{acc:A, e:TExpr}, acc:A, e:TExpr):{acc:A, e:TExpr} {
		inline function mk2(ed:TExprExpr):TExpr return TypeFunctions.mk(ed, e.type, e.pos);
		return switch (e.expr) {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
				{acc: acc, e: e};
			case TArray(e1, e2):
				var r1 = f(acc, e1);
				var r2 = f(r1.acc, e2);
				{acc: r2.acc, e: mk2(TArray(r1.e, r2.e))};
			case TBinop(op, e1, e2):
				var r1 = f(acc, e1);
				var r2 = f(r1.acc, e2);
				{acc: r2.acc, e: mk2(TBinop(op, r1.e, r2.e))};
			case TFor(v, e1, e2):
				var r1 = f(acc, e1);
				var r2 = f(r1.acc, e2);
				{acc: r2.acc, e: mk2(TFor(v, r1.e, r2.e))};
			case TWhile(e1, e2, flag):
				var r1 = f(acc, e1);
				var r2 = f(r1.acc, e2);
				{acc: r2.acc, e: mk2(TWhile(r1.e, r2.e, flag))};
			case TThrow(e1):
				var r = f(acc, e1);
				{acc: r.acc, e: mk2(TThrow(r.e))};
			case TEnumParameter(e1, ef, i):
				var r = f(acc, e1);
				{acc: r.acc, e: mk2(TEnumParameter(r.e, ef, i))};
			case TEnumIndex(e1):
				var r = f(acc, e1);
				{acc: r.acc, e: mk2(TEnumIndex(r.e))};
			case TField(e1, v):
				var r = f(acc, e1);
				{acc: r.acc, e: mk2(TField(r.e, v))};
			case TParenthesis(e1):
				var r = f(acc, e1);
				{acc: r.acc, e: mk2(TParenthesis(r.e))};
			case TUnop(op, pre, e1):
				var r = f(acc, e1);
				{acc: r.acc, e: mk2(TUnop(op, pre, r.e))};
			case TArrayDecl(el):
				var r = foldmapList(f, acc, el);
				{acc: r.acc, e: mk2(TArrayDecl(r.el))};
			case TNew(t, pl, el):
				var r = foldmapList(f, acc, el);
				{acc: r.acc, e: mk2(TNew(t, pl, r.el))};
			case TBlock(el):
				var r = foldmapList(f, acc, el);
				{acc: r.acc, e: mk2(TBlock(r.el))};
			case TObjectDecl(fl):
				// Re-reverses to source order
				var flAcc = [];
				for (fd in fl) {
					var r = f(acc, fd.expr);
					acc = r.acc;
					flAcc.push({key: fd.key, expr: r.e});
				}
				{acc: acc, e: mk2(TObjectDecl(flAcc))};
			case TCall(e1, el):
				var r1 = f(acc, e1);
				var r2 = foldmapList(f, r1.acc, el);
				{acc: r2.acc, e: mk2(TCall(r1.e, r2.el))};
			case TVarExpr(v, eo):
				var r = foldmapOpt(f, acc, eo);
				{acc: r.acc, e: mk2(TVarExpr(v, r.eo))};
			case TFunction(fu):
				var r = f(acc, fu.expr);
				{acc: r.acc, e: mk2(TFunction(new TFunc(fu.args, fu.type, r.e)))};
			case TIf(ec, e1, eo):
				var rc = f(acc, ec);
				var r1 = f(rc.acc, e1);
				var ro = foldmapOpt(f, r1.acc, eo);
				{acc: ro.acc, e: mk2(TIf(rc.e, r1.e, ro.eo))};
			case TSwitch(e1, cases, def):
				var r1 = f(acc, e1);
				acc = r1.acc;
				// Cases fold by prepending without a final reverse, so their order comes out reversed.
				var casesAcc = [];
				for (c in cases) {
					var rv = foldmapList(f, acc, c.values);
					var re = f(rv.acc, c.expr);
					acc = re.acc;
					casesAcc.unshift({values: rv.el, expr: re.e});
				}
				var rd = foldmapOpt(f, acc, def);
				{acc: rd.acc, e: mk2(TSwitch(r1.e, casesAcc, rd.eo))};
			case TTry(e1, catches):
				var r1 = f(acc, e1);
				acc = r1.acc;
				// Re-reverses to source order
				var catchesAcc = [];
				for (c in catches) {
					var r = f(acc, c.expr);
					acc = r.acc;
					catchesAcc.push({v: c.v, expr: r.e});
				}
				{acc: acc, e: mk2(TTry(r1.e, catchesAcc))};
			case TReturn(eo):
				var r = foldmapOpt(f, acc, eo);
				{acc: r.acc, e: mk2(TReturn(r.eo))};
			case TCast(e1, t):
				var r = f(acc, e1);
				{acc: r.acc, e: mk2(TCast(r.e, t))};
			case TMeta(m, e1):
				var r = f(acc, e1);
				{acc: r.acc, e: mk2(TMeta(m, r.e))};
		};
	}

	// If (a == null) a = c;
	public static function setDefault(basic:BasicTypes, a:TVar, c:TExpr, p:Position):TExpr {
		var t = a.type;
		var ve = TypeFunctions.mk(TLocal(a), t, p);
		var cond = TypeFunctions.mk(TBinop(OpEq, ve, TypeFunctions.mk(TConst(TNull), t, p)), basic.tbool, p);
		return TypeFunctions.mk(TIf(mkParent(cond), TypeFunctions.mk(TBinop(OpAssign, ve, c), t, p), null), basic.tvoid, p);
	}

	// Constants, object and array literals of constants.
	public static function typeConstantValue(basic:BasicTypes, e:Expr):TExpr {
		return switch (e.expr) {
			case EConst(c):
				typeConstant(basic, c, e.pos);
			case EParenthesis(e1):
				typeConstantValue(basic, e1);
			case EObjectDecl(el):
				TypeFunctions.mk(TObjectDecl([for (f in el) {
					key: {name: f.name, pos: f.pos, quotes: f.quotes},
					expr: typeConstantValue(basic, f.expr)
				}]), TypeFunctions.mkAnon(new Ref(Closed)), e.pos);
			case EArrayDecl(el):
				TypeFunctions.mk(TArrayDecl([for (x in el) typeConstantValue(basic, x)]), basic.tarray(TypeFunctions.tDynamic), e.pos);
			case _:
				throw new TypingError("Constant value expected", e.pos);
		};
	}

	// The __meta__ object {obj?, statics?, fields?} carrying the run-time (non-colon) metadata of a type,
	// or null when it has none.
	public static function buildMetadata(basic:BasicTypes, t:ModuleType):Null<TExpr> {
		var p:Position;
		var meta:Array<{name:String, ml:Metadata}>;
		var fields:Array<{name:String, ml:Metadata}>;
		var statics:Array<{name:String, ml:Metadata}>;
		switch (t) {
			case TClassDecl(c):
				fields = [for (f in c.orderedFields) {name: f.name, ml: f.meta}];
				if (c.constructor != null) fields.push({name: "_", ml: c.constructor.meta});
				statics = [for (f in c.orderedStatics) {name: f.name, ml: f.meta}];
				p = c.pos;
				meta = [{name: "", ml: c.meta}];
			case TEnumDecl(en):
				p = en.pos;
				meta = [{name: "", ml: en.meta}];
				fields = [for (n in en.names) {name: n, ml: en.constrs.get(n).meta}];
				statics = [];
			case TTypeDecl(td):
				p = td.pos;
				meta = [{name: "", ml: td.meta}];
				fields = switch (TypeFunctions.follow(td.type)) {
					case TAnon(a):
						// Prepending each name of the sorted list makes it name-descending.
						var names = [for (k in a.fields.keys()) k];
						names.sort(Reflect.compare);
						var out = [];
						for (n in names) out.unshift({name: n, ml: a.fields.get(n).meta});
						out;
					case _: [];
				};
				statics = [];
			case TAbstractDecl(a):
				p = a.pos;
				meta = [{name: "", ml: a.meta}];
				fields = [];
				statics = [];
		}
		// Keep only run-time metadata: a name not starting with ':'
		function filter(l:Array<{name:String, ml:Metadata}>):Array<{name:String, ml:Metadata}> {
			var out = [];
			for (entry in l) {
				var ml = [for (m in entry.ml) if (m.name.length > 0 && m.name.charAt(0) != ":") m];
				if (ml.length > 0) out.push({name: entry.name, ml: ml});
			}
			return out;
		}
		var meta = filter(meta);
		var fields = filter(fields);
		var statics = filter(statics);
		function makeMetaField(ml:Metadata):TExpr {
			var h = new haxe.ds.StringMap<Bool>();
			return TypeFunctions.mk(TObjectDecl([for (m in ml) {
				if (h.exists(m.name)) throw new TypingError("Duplicate metadata '" + m.name + "'", m.pos);
				h.set(m.name, true);
				{
					key: {name: m.name, pos: Position.nullPos, quotes: NoQuotes},
					expr: TypeFunctions.mk(m.params.length == 0 ? TConst(TNull) : TArrayDecl([for (x in m.params) typeConstantValue(basic, x)]), basic.tarray(TypeFunctions.tDynamic), m.pos)
				};
			}]), TypeFunctions.tDynamic, p);
		}
		function makeMeta(l:Array<{name:String, ml:Metadata}>):TExpr {
			return TypeFunctions.mk(TObjectDecl([for (entry in l) {
				key: {name: entry.name, pos: Position.nullPos, quotes: NoQuotes},
				expr: makeMetaField(entry.ml)
			}]), TypeFunctions.tDynamic, p);
		}
		if (meta.length == 0 && fields.length == 0 && statics.length == 0) return null;
		var metaObj:Array<TObjectField> = [];
		if (fields.length > 0) metaObj.unshift({key: {name: "fields", pos: Position.nullPos, quotes: NoQuotes}, expr: makeMeta(fields)});
		if (statics.length > 0) metaObj.unshift({key: {name: "statics", pos: Position.nullPos, quotes: NoQuotes}, expr: makeMeta(statics)});
		for (entry in meta) if (entry.name == "") {
			metaObj.unshift({key: {name: "obj", pos: Position.nullPos, quotes: NoQuotes}, expr: makeMetaField(entry.ml)});
			break;
		}
		return TypeFunctions.mk(TObjectDecl(metaObj), TypeFunctions.tDynamic, p);
	}
}
