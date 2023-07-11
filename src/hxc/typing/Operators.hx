package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.typing.FieldAccess;

enum TypeClass {
	KInt;
	KFloat;
	KString;
	KUnk;
	KDyn;
	KOther;
	KNumParam(t:T);
	KStrParam(t:T);
	KAbstract(a:TAbstract, tl:TParams);
}

enum BinopResult {
	BinopNormal(op:Binop, lhs:TExpr, rhs:TExpr, t:T, needsAssign:Bool, swapped:Bool, pos:Position);
	BinopSpecial(e:TExpr, needsAssign:Bool);
}

class Operators {
	static function unify(ctx:TyperContext, a:T, b:T, p:Position):Void {
		try {
			TypeUnification.unifyDefault(a, b);
		} catch (_:UnifyError) {
			throw new TypingError("Cannot unify types", p);
		}
	}

	static inline function isVoid(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	public static function classify(t:T):TypeClass {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, []) if (c.path.pack.length == 0 && c.path.name == "String"): KString;
			case TAbstract(a, tl) if (a.impl != null): KAbstract(a, tl);
			case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Int"): KInt;
			case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Float"): KFloat;
			case TAbstract(a, []) if (Lambda.exists(a.to, isNumLike)): KNumParam(t);
			case TInst(c, _) if (typeParamHas(c, isNumLike)): KNumParam(t);
			case TAbstract(a, []) if (Lambda.exists(a.to, isStrLike)): KStrParam(t);
			case TInst(c, _) if (typeParamHas(c, isStrLike)): KStrParam(t);
			case TMono(r) if (r.type == null): KUnk;
			case TDynamic(_): KDyn;
			case _: KOther;
		};
	}

	static function isNumLike(t:T):Bool {
		return switch (classify(t)) { case KInt | KFloat: true; case _: false; };
	}

	static function isStrLike(t:T):Bool {
		return switch (classify(t)) { case KString: true; case _: false; };
	}

	static function typeParamHas(c:TClass, pred:T->Bool):Bool {
		return switch (c.kind) {
			case KTypeParameter(ctl): Lambda.exists(ctl, pred);
			case _: false;
		};
	}

	public static function unifyInt(ctx:TyperContext, e:TExpr, k:TypeClass):Bool {
		function isDynamic(t:T):Bool {
			return switch (TypeFunctions.follow(t)) { case TDynamic(_): true; case _: false; };
		}
		function maybeDynamicMono(e:TExpr):Bool {
			return switch (e.expr) {
				case TLocal(_): isDynamic(e.type);
				case TParenthesis(e2): maybeDynamicMono(e2);
				case TMeta(_, e2): maybeDynamicMono(e2);
				case TIf(_, a, b) if (b != null): maybeDynamicMono(a) || maybeDynamicMono(b);
				case _: false;
			};
		}
		return switch (k) {
			case KUnk | KDyn if (maybeDynamicMono(e)):
				unify(ctx, e.type, ctx.com.basic.tfloat, e.pos);
				false;
			case _:
				unify(ctx, e.type, ctx.com.basic.tint, e.pos);
				true;
		};
	}

	public static function makeBinop(ctx:TyperContext, op:Binop, e1:TExpr, e2:TExpr, isAssignOp:Bool, withType:WithType, p:Position):BinopResult {
		var basic = ctx.com.basic;
		var tint = basic.tint, tfloat = basic.tfloat, tstring = basic.tstring, tbool = basic.tbool;
		var haxeNext = ctx.com.defines.rawDefined("haxe_next");

		function toString(e:TExpr):TExpr {
			return switch (classify(e.type)) {
				case KInt | KFloat | KString: e;
				case _: throw new TypingError("String concatenation with a non-primitive operand is not yet ported", e.pos);
			};
		}
		function mkOp(a:TExpr, b:TExpr, t:T):BinopResult {
			if (op.match(OpAdd) && (switch (classify(t)) { case KString: true; case _: false; })) {
				a = toString(a);
				b = toString(b);
			}
			return BinopNormal(op, a, b, t, isAssignOp, false, p);
		}

		return switch (op) {
			case OpAdd:
				var t = switch ([classify(e1.type), classify(e2.type)]) {
					case [KInt, KInt]: tint;
					case [KFloat, KInt] | [KInt, KFloat] | [KFloat, KFloat]: tfloat;
					case [KUnk, KInt]: unifyInt(ctx, e1, KUnk) ? tint : tfloat;
					case [KUnk, KFloat] | [KUnk, KString]:
						if (haxeNext) e2.type else { unify(ctx, e1.type, e2.type, e1.pos); e1.type; }
					case [KInt, KUnk]: unifyInt(ctx, e2, KUnk) ? tint : tfloat;
					case [KFloat, KUnk] | [KString, KUnk]:
						if (haxeNext) e1.type else { unify(ctx, e2.type, e1.type, e2.pos); e2.type; }
					case [_, KString] | [KString, _]: tstring;
					case [_, KDyn]: e2.type;
					case [KDyn, _]: e1.type;
					case [KUnk, KUnk]:
						var ok1 = unifyInt(ctx, e1, KUnk);
						var ok2 = unifyInt(ctx, e2, KUnk);
						(ok1 && ok2) ? tint : tfloat;
					case [KNumParam(t1), KNumParam(t2)] if (TypeUnification.typeIseqDefault(t1, t2)): t1;
					case [KNumParam(t), KInt] | [KInt, KNumParam(t)]: t;
					case [KNumParam(_), KFloat] | [KFloat, KNumParam(_)] | [KNumParam(_), KNumParam(_)]: tfloat;
					case [KNumParam(_), KUnk]: unify(ctx, e2.type, tfloat, e2.pos); tfloat;
					case [KUnk, KNumParam(_)]: unify(ctx, e1.type, tfloat, e1.pos); tfloat;
					case [KStrParam(_), _] | [_, KStrParam(_)]: tstring;
					case [KAbstract(_, _), KFloat]: unify(ctx, e1.type, tfloat, e1.pos); tfloat;
					case [KFloat, KAbstract(_, _)]: unify(ctx, e2.type, tfloat, e2.pos); tfloat;
					case [KAbstract(_, _), KInt]: unify(ctx, e1.type, tint, e1.pos); tint;
					case [KInt, KAbstract(_, _)]: unify(ctx, e2.type, tint, e2.pos); tint;
					case _: throw new TypingError("Cannot add the given types", p);
				};
				mkOp(e1, e2, t);
			case OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr:
				unify(ctx, e1.type, tint, e1.pos);
				unify(ctx, e2.type, tint, e2.pos);
				mkOp(e1, e2, tint);
			case OpMod | OpMult | OpDiv | OpSub:
				var result = op.match(OpDiv) ? tfloat : tint;
				switch ([classify(e1.type), classify(e2.type)]) {
					case [KFloat, KFloat]: result = tfloat;
					case [KNumParam(t1), KNumParam(t2)] if (TypeUnification.typeIseqDefault(t1, t2)): if (!op.match(OpDiv)) result = t1;
					case [KNumParam(_), KNumParam(_)]: result = tfloat;
					case [KNumParam(t), KInt] | [KInt, KNumParam(t)]: if (!op.match(OpDiv)) result = t;
					case [KNumParam(_), KFloat] | [KFloat, KNumParam(_)]: result = tfloat;
					case [KFloat, _]: unifyInt(ctx, e2, classify(e2.type)); result = tfloat;
					case [_, KFloat]: unifyInt(ctx, e1, classify(e1.type)); result = tfloat;
					case [k1, k2]:
						var ok1 = unifyInt(ctx, e1, k1);
						var ok2 = unifyInt(ctx, e2, k2);
						if (!ok1 || !ok2) result = tfloat;
				}
				mkOp(e1, e2, result);
			case OpEq | OpNotEq:
				switch (TypeFunctions.follow(e2.type)) {
					case TAbstract(a, _) if (isVoid(e2.type)): throw new TypingError("Cannot compare Void", p);
					case _:
				}
				try unify(ctx, e1.type, e2.type, p) catch (_:TypingError) unify(ctx, e2.type, e1.type, p);
				mkOp(e1, e2, tbool);
			case OpGt | OpGte | OpLt | OpLte:
				switch ([classify(e1.type), classify(e2.type)]) {
					case [KInt, KInt] | [KInt, KFloat] | [KFloat, KInt] | [KFloat, KFloat] | [KString, KString]:
					case [KInt, KUnk]: unifyInt(ctx, e2, KUnk);
					case [KFloat, KUnk] | [KString, KUnk]: unify(ctx, e2.type, e1.type, e2.pos);
					case [KUnk, KInt]: unifyInt(ctx, e1, KUnk);
					case [KUnk, KFloat] | [KUnk, KString]: unify(ctx, e1.type, e2.type, e1.pos);
					case [KUnk, KUnk]: unifyInt(ctx, e1, KUnk); unifyInt(ctx, e2, KUnk);
					case [KDyn, KInt] | [KDyn, KFloat] | [KDyn, KString]:
					case [KInt, KDyn] | [KFloat, KDyn] | [KString, KDyn]:
					case [KDyn, KDyn]:
					case [KNumParam(_), KInt] | [KNumParam(_), KFloat] | [KNumParam(_), KNumParam(_)] | [KNumParam(_), KDyn] | [KNumParam(_), KUnk]:
					case [KInt, KNumParam(_)] | [KFloat, KNumParam(_)] | [KDyn, KNumParam(_)] | [KUnk, KNumParam(_)]:
					case [KStrParam(_), KString] | [KStrParam(_), KStrParam(_)] | [KStrParam(_), KUnk] | [KStrParam(_), KDyn]:
					case [KString, KStrParam(_)] | [KUnk, KStrParam(_)] | [KDyn, KStrParam(_)]:
					case _: throw new TypingError("Cannot compare the given types", p);
				}
				mkOp(e1, e2, tbool);
			case OpBoolAnd | OpBoolOr:
				unify(ctx, e1.type, tbool, p);
				unify(ctx, e2.type, tbool, p);
				mkOp(e1, e2, tbool);
			case OpInterval:
				throw new TypingError("The range operator (...) is not yet ported", p);
			case OpArrow:
				throw new TypingError("Unexpected =>", p);
			case OpIn:
				throw new TypingError("Unexpected in", p);
			case OpNullCoal | OpAssign | OpAssignOp(_):
				throw new TypingError("This operator is not handled by make_binop", p);
		};
	}

	// Primitive operators excluding assignment.
	static function toTexpr(br:BinopResult):TExpr {
		return switch (br) {
			case BinopNormal(op, lhs, rhs, t, _, _, pos): TypeFunctions.mk(TBinop(op, lhs, rhs), t, pos);
			case BinopSpecial(e, _): e;
		};
	}

	public static function typeBinop(ctx:TyperContext, op:Binop, e1:Expr, e2:Expr, isAssignOp:Bool, withType:WithType, p:Position):TExpr {
		return switch (op) {
			case OpAssign:
				typeAssign(ctx, e1, e2, withType, p);
			case OpAssignOp(sub):
				typeAssignOp(ctx, sub, e1, e2, withType, p);
			case _:
				var te1 = Typer.typeExpr(ctx, e1, WithTypeTools.value);
				var rhsWt = switch (op) {
					case OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte: WithTypeTools.withType(te1.type);
					case _: WithTypeTools.value;
				};
				var te2 = Typer.typeExpr(ctx, e2, rhsWt);
				toTexpr(makeBinop(ctx, op, te1, te2, isAssignOp, withType, p));
		};
	}

	static function assignTo(ctx:TyperContext, te1:TExpr, e2:Expr, p:Position):TExpr {
		var te2 = Typer.castOrUnify(ctx, te1.type, Typer.typeExpr(ctx, e2, WithTypeTools.withType(te1.type)), p);
		return TypeFunctions.mk(TBinop(OpAssign, te1, te2), te1.type, p);
	}

	static function typeAssign(ctx:TyperContext, e1:Expr, e2:Expr, withType:WithType, p:Position):TExpr {
		return switch (Typer.typeAccess(ctx, e1.expr, e1.pos, MSet(e2), withType)) {
			case AKExpr(te1): assignTo(ctx, te1, e2, p);
			case AKField(fa): assignTo(ctx, FieldAccessTools.getFieldExpr(fa, FWrite), e2, p);
			case AKNo(_, np): throw new TypingError("This expression cannot be accessed for writing", np);
			case _: throw new TypingError("This assignment target is not yet ported", p);
		};
	}

	static function typeAssignOp(ctx:TyperContext, sub:Binop, e1:Expr, e2:Expr, withType:WithType, p:Position):TExpr {
		return switch (Typer.typeAccess(ctx, e1.expr, e1.pos, MGet, withType)) {
			case AKExpr(te1):
				var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
				makeBinop(ctx, sub, te1, te2, true, withType, p);
				TypeFunctions.mk(TBinop(OpAssignOp(sub), te1, te2), te1.type, p);
			case AKField(fa):
				var te1 = FieldAccessTools.getFieldExpr(fa, FWrite);
				var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
				makeBinop(ctx, sub, te1, te2, true, withType, p);
				TypeFunctions.mk(TBinop(OpAssignOp(sub), te1, te2), te1.type, p);
			case _:
				throw new TypingError("This compound assignment target is not yet ported", p);
		};
	}

	public static function typeUnop(ctx:TyperContext, op:Unop, flag:UnopFlag, e:Expr, withType:WithType, p:Position):TExpr {
		return switch (op) {
			case Spread:
				throw new TypingError("Spread unary operator is only allowed for unpacking the last argument in a call with rest arguments", p);
			case Increment | Decrement:
				switch (Typer.typeAccess(ctx, e.expr, e.pos, MGet, withType)) {
					case AKExpr(te): TypeFunctions.mk(TUnop(op, flag, te), te.type, p);
					case AKField(fa):
						var te = FieldAccessTools.getFieldExpr(fa, FWrite);
						TypeFunctions.mk(TUnop(op, flag, te), te.type, p);
					case _: throw new TypingError("This increment target is not yet ported", p);
				}
			case Not | Neg | NegBits:
				var te = Typer.typeExpr(ctx, e, WithTypeTools.value);
				makeUnop(ctx, op, flag, te, p);
		};
	}

	static function makeUnop(ctx:TyperContext, op:Unop, flag:UnopFlag, e:TExpr, p:Position):TExpr {
		var basic = ctx.com.basic;
		function checkInt():T {
			return switch (classify(e.type)) {
				case KFloat: basic.tfloat;
				case KNumParam(t): unify(ctx, e.type, basic.tfloat, e.pos); t;
				case k: unifyInt(ctx, e, k) ? basic.tint : basic.tfloat;
			};
		}
		var t = switch (op) {
			case Not:
				if (flag.match(Postfix)) throw new TypingError("Postfix ! is not supported", p);
				unify(ctx, e.type, basic.tbool, e.pos);
				basic.tbool;
			case NegBits:
				unify(ctx, e.type, basic.tint, e.pos);
				basic.tint;
			case Neg:
				checkInt();
			case Increment | Decrement | Spread:
				throw new TypingError("Unexpected unary operator in makeUnop", p);
		};
		return TypeFunctions.mk(TUnop(op, flag, e), t, p);
	}
}
