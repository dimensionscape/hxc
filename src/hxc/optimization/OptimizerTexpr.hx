package hxc.optimization;


import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.Numeric;
import hxc.context.PurityState;

private typedef Exit = hxc.core.ExitException;

class OptimizerTexpr {
	// Does not account for potential null accesses
	public static function hasSideEffect(e:TExpr):Bool {
		// Finding a side effect answers true at once.
		function loop(e:TExpr):Bool {
			return switch (e.expr) {
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TIdent(_): false;
				case TCall({expr: TField(e1, fa)}, el) if (PurityState.isPureFieldAccess(fa)):
					loop(e1) || TexprTools.existsIn(loop, el);
				case TNew(c, _, el) if (c.constructor != null && PurityState.isPure(c, c.constructor)):
					TexprTools.existsIn(loop, el);
				case TField(_, fa) if (PurityState.isExplicitlyImpure(fa)): true;
				case TNew(_, _, _) | TCall(_, _) | TBinop(OpAssignOp(_) | OpAssign, _, _) | TUnop(Increment | Decrement, _, _): true;
				case TReturn(_) | TBreak | TContinue | TThrow(_): true;
				case TCast(_, mt) if (mt != null): true;
				case _: TexprTools.checkExpr(loop, e);
			};
		}
		return loop(e);
	}

	public static function isReadOnlyFieldAccess(e:TExpr, fa:TFieldAccess):Bool {
		return switch (fa) {
			case FEnum(_, _): true;
			case FDynamic(_): false;
			case FAnon(cf) if (cf.kind.match(Var(_)) && varWriteIs(cf, AccNo) && e.expr.match(TIdent(_))): true;
			case FInstance(c, _, cf) | FStatic(c, cf): readOnlyKind(c, cf);
			case FClosure(w, cf) if (w != null): readOnlyKind(w.c, cf);
			case FAnon(cf) | FClosure(null, cf):
				switch (cf.kind) {
					case Method(MethDynamic): false;
					case Method(_): true;
					case _: false;
				}
			case _: false;
		};
	}

	static function varWriteIs(cf:TClassField, acc:VarAccess):Bool {
		return switch (cf.kind) {
			case Var(k): std.Type.enumEq(k.write, acc);
			case _: false;
		};
	}

	static function readOnlyKind(c:TClass, cf:TClassField):Bool {
		return switch (cf.kind) {
			case Method(MethDynamic): false;
			case Method(_): true;
			case Var(k) if (k.write.match(AccNever) && !TypeFunctions.hasClassFlag(c, CInterface)): true;
			case _: false;
		};
	}

	// Returns (mightBeAffected, collectModifiedLocals)
	public static function createAffectionChecker():{mightBeAffected:TExpr->Bool, collectModifiedLocals:TExpr->Void} {
		var modifiedLocals = new Map<Int, Bool>();
		function mightBeAffected(e:TExpr):Bool {
			function loop(e:TExpr):Bool {
				return switch (e.expr) {
					case TConst(_) | TFunction(_) | TTypeExpr(_): false;
					case TLocal(v) if (TypeFunctions.hasVarFlag(v, VCaptured)): true;
					case TLocal(v) if (modifiedLocals.exists(v.id)): true;
					case TField(e1, fa) if (!isReadOnlyFieldAccess(e1, fa)): true;
					case TCall(_, _) | TNew(_, _, _): true;
					case _: TexprTools.checkExpr(loop, e);
				};
			}
			return loop(e);
		}
		function collectModifiedLocals(e:TExpr):Void {
			switch (e.expr) {
				case TUnop(Increment | Decrement, _, {expr: TLocal(v)}):
					modifiedLocals.set(v.id, true);
				case TBinop(OpAssign | OpAssignOp(_), {expr: TLocal(v)}, e2):
					collectModifiedLocals(e2);
					modifiedLocals.set(v.id, true);
				case _:
					TexprTools.iter(collectModifiedLocals, e);
			}
		}
		return {mightBeAffected: mightBeAffected, collectModifiedLocals: collectModifiedLocals};
	}

	static function isFloatT(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Float";
			case _: false;
		};
	}

	static function isNumericT(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): a.path.pack.length == 0 && (a.path.name == "Float" || a.path.name == "Int");
			case _: false;
		};
	}

	// The float fold helper inside optimizeBinop: fold only when the printed value round-trips exactly
	static function checkFloat(e:TExpr, op:(a:Float, b:Float)->Float, f1:Float, f2:Float):TExpr {
		var f = op(f1, f2);
		var fstr = Numeric.floatRepres(f);
		if (!Math.isNaN(f) && Math.isFinite(f) && hxc.core.Numeric.parseFloatLit(fstr) == f)
			return TypeFunctions.mk(TConst(TFloat(fstr)), e.type, e.pos);
		return e;
	}

	public static function optimizeBinop(e:TExpr, op:Binop, e1:TExpr, e2:TExpr):TExpr {
		inline function reconst(c:TConstant):TExpr return TypeFunctions.mk(TConst(c), e.type, e.pos);
		return switch ([e1.expr, e2.expr]) {
			case [TConst(TInt(i)), _] if (i == 0 && op.match(OpAdd) && isNumericT(e2.type)): e2;
			case [TConst(TInt(i)), _] if (i == 1 && op.match(OpMult)): e2;
			case [TConst(TFloat(v)), _] if (op.match(OpAdd) && hxc.core.Numeric.parseFloatLit(v) == 0.0 && isFloatT(e2.type)): e2;
			case [TConst(TFloat(v)), _] if (op.match(OpMult) && hxc.core.Numeric.parseFloatLit(v) == 1.0 && isFloatT(e2.type)): e2;
			// Bits operations might cause overflow
			case [_, TConst(TInt(i))] if (i == 0 && switch (op) {
				case OpAdd: isNumericT(e1.type);
				case OpSub | OpShr | OpShl: true;
				case _: false;
			}): e1;
			case [_, TConst(TInt(i))] if (i == 1 && op.match(OpMult)): e1;
			case [_, TConst(TFloat(v))] if (switch (op) {
				case OpAdd | OpSub: hxc.core.Numeric.parseFloatLit(v) == 0.0 && isFloatT(e1.type);
				case _: false;
			}): e1;
			case [_, TConst(TFloat(v))] if (op.match(OpMult) && hxc.core.Numeric.parseFloatLit(v) == 1.0 && isFloatT(e1.type)): e1;
			case [TConst(TNull), TConst(TNull)]:
				switch (op) {
					case OpEq: reconst(TBool(true));
					case OpNotEq: reconst(TBool(false));
					case _: e;
				}
			case [TFunction(_), TConst(TNull)] | [TConst(TNull), TFunction(_)]:
				switch (op) {
					case OpEq: reconst(TBool(false));
					case OpNotEq: reconst(TBool(true));
					case _: e;
				}
			case [TConst(TInt(a)), TConst(TInt(b))]:
				// Fold via Int64 and refuse when truncating back to 32 bits loses the value
				inline function opt(f:(a:Int, b:Int)->Int):TExpr return reconst(TInt(f(a, b)));
				function checkOverflow(f:(a:haxe.Int64, b:haxe.Int64)->haxe.Int64):TExpr {
					var v = f(haxe.Int64.ofInt(a), haxe.Int64.ofInt(b));
					var iv:Int = v.low;
					if (haxe.Int64.eq(haxe.Int64.ofInt(iv), v)) return reconst(TInt(iv));
					return e;
				}
				inline function ebool(t:Bool):TExpr return reconst(TBool(t));
				switch (op) {
					case OpAdd: checkOverflow(haxe.Int64.add);
					case OpSub: checkOverflow(haxe.Int64.sub);
					case OpMult: checkOverflow(haxe.Int64.mul);
					case OpDiv: checkFloat(e, function(x, y) return x / y, a, b);
					case OpAnd: opt(function(x, y) return x & y);
					case OpOr: opt(function(x, y) return x | y);
					case OpXor: opt(function(x, y) return x ^ y);
					case OpShl: opt(function(x, y) return x << (y & 31));
					case OpShr: opt(function(x, y) return x >> (y & 31));
					case OpUShr: opt(function(x, y) return x >>> (y & 31));
					case OpEq: ebool(a == b);
					case OpNotEq: ebool(a != b);
					case OpGt: ebool(a > b);
					case OpGte: ebool(a >= b);
					case OpLt: ebool(a < b);
					case OpLte: ebool(a <= b);
					case _: e;
				}
			case [TConst(ca = TFloat(_) | TInt(_)), TConst(cb = TFloat(_) | TInt(_))]:
				var fa:Float = switch (ca) {
					case TFloat(a): hxc.core.Numeric.parseFloatLit(a);
					case TInt(a): a;
					case _: throw new TypingError("Unexpected constant", e.pos);
				}
				var fb:Float = switch (cb) {
					case TFloat(b): hxc.core.Numeric.parseFloatLit(b);
					case TInt(b): b;
					case _: throw new TypingError("Unexpected constant", e.pos);
				}
				inline function fop(f:(a:Float, b:Float)->Float):TExpr return checkFloat(e, f, fa, fb);
				inline function ebool(t:Bool):TExpr return reconst(TBool(t));
				switch (op) {
					case OpAdd: fop(function(x, y) return x + y);
					case OpDiv: fop(function(x, y) return x / y);
					case OpSub: fop(function(x, y) return x - y);
					case OpMult: fop(function(x, y) return x * y);
					case OpEq: ebool(fa == fb);
					case OpNotEq: ebool(fa != fb);
					case OpGt: ebool(fa > fb);
					case OpGte: ebool(fa >= fb);
					case OpLt: ebool(fa < fb);
					case OpLte: ebool(fa <= fb);
					case _: e;
				}
			case [TConst(TString("")), TConst(TString(s))] | [TConst(TString(s)), TConst(TString(""))] if (op.match(OpAdd)):
				reconst(TString(s));
			case [TConst(TBool(a)), TConst(TBool(b))]:
				inline function ebool(f:(a:Bool, b:Bool)->Bool):TExpr return reconst(TBool(f(a, b)));
				switch (op) {
					case OpEq: ebool(function(x, y) return x == y);
					case OpNotEq: ebool(function(x, y) return x != y);
					case OpBoolAnd: ebool(function(x, y) return x && y);
					case OpBoolOr: ebool(function(x, y) return x || y);
					case _: e;
				}
			case [TConst(a), TConst(b)] if (op.match(OpEq) || op.match(OpNotEq)):
				inline function ebool(t:Bool):TExpr return reconst(TBool(op.match(OpEq) ? t : !t));
				switch ([a, b]) {
					case [TInt(x), TFloat(y)] | [TFloat(y), TInt(x)]: ebool(x == hxc.core.Numeric.parseFloatLit(y));
					case _: ebool(std.Type.enumEq(a, b));
				}
			case [TConst(TBool(a)), _]:
				switch (op) {
					case OpBoolAnd: a ? e2 : reconst(TBool(false));
					case OpBoolOr: a ? reconst(TBool(true)) : e2;
					case _: e;
				}
			case [_, TConst(TBool(a))]:
				switch (op) {
					case OpBoolAnd if (a): e1;
					case OpBoolOr if (!a): e1;
					case _: e;
				}
			case [TField(_, FEnum(en1, f1)), TField(_, FEnum(en2, f2))] if (en1 == en2):
				switch (op) {
					case OpEq: reconst(TBool(f1 == f2));
					case OpNotEq: reconst(TBool(f1 != f2));
					case _: e;
				}
			case [x, TCall({expr: TField(_, FEnum(_, _))}, el)] | [TCall({expr: TField(_, FEnum(_, _))}, el), x]:
				switch ([op, x]) {
					case [OpEq | OpNotEq, TConst(TNull)]:
						var e0 = reconst(TBool(op.match(OpNotEq)));
						TypeFunctions.mk(TBlock(el.concat([e0])), e.type, e.pos);
					case [OpAssign, _]:
						e;
					case _:
						throw new TypingError("You cannot directly compare enums with arguments. Use either `switch`, `match` or `Type.enumEq`", e.pos);
				}
			case _:
				e;
		};
	}

	public static function optimizeUnop(e:TExpr, op:Unop, flag:UnopFlag, esub:TExpr):TExpr {
		inline function isIntT(t:T):Bool {
			return switch (TypeFunctions.follow(t)) {
				case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Int";
				case _: false;
			};
		}
		return switch ([op, esub.expr]) {
			case [Not, TConst(TBool(f))] | [Not, TParenthesis({expr: TConst(TBool(f))})]:
				TypeFunctions.mk(TConst(TBool(!f)), e.type, e.pos);
			case [Not, TBinop(bop, e1, e2)] | [Not, TParenthesis({expr: TBinop(bop, e1, e2)})]:
				var isInt = isIntT(e1.type) && isIntT(e2.type);
				var inverted:Null<Binop> = switch ([isInt, bop]) {
					case [true, OpGt]: OpLte;
					case [true, OpGte]: OpLt;
					case [true, OpLt]: OpGte;
					case [true, OpLte]: OpGt;
					case [_, OpEq]: OpNotEq;
					case [_, OpNotEq]: OpEq;
					case _: null;
				}
				inverted == null ? e : TypeFunctions.mk(TBinop(inverted, e1, e2), e.type, e.pos);
			case [Neg, TConst(TInt(i))]:
				TypeFunctions.mk(TConst(TInt(-i)), e.type, e.pos);
			case [NegBits, TConst(TInt(i))]:
				TypeFunctions.mk(TConst(TInt(~i)), e.type, e.pos);
			case [Neg, TConst(TFloat(f))]:
				var v = 0.0 - hxc.core.Numeric.parseFloatLit(f);
				var vstr = Numeric.floatRepres(v);
				if (hxc.core.Numeric.parseFloatLit(vstr) == v)
					TypeFunctions.mk(TConst(TFloat(vstr)), e.type, e.pos);
				else
					e;
			case _:
				e;
		};
	}
}
