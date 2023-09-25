package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.TexprTools;
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

	// Ordered comparison treats an abstract over a numeric type as that type (result is Bool, so
	// there is no result-type imprecision); operands keep their abstract value at runtime.
	static function cmpClass(t:T, op:Binop):TypeClass {
		return switch (classify(t)) {
			case KAbstract(a, _) if (hasDeclaredOp(a, op)): switch (classify(a.thisType)) { case KInt: KInt; case KFloat: KFloat; case _: KAbstract(a, []); }
			case k: k;
		};
	}

	static function hasDeclaredOp(a:TAbstract, op:Binop):Bool {
		for (aop in a.ops) if (sameOp(aop.op, op)) return true;
		return false;
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

		function callToString(e:TExpr):TExpr {
			// `if (e == null) "null" else e.toString()`, using a temp for a non-trivial operand so it is
			// evaluated once. .
			function gen(x:TExpr):TExpr
				return hxc.typing.Calls.buildCall(ctx, hxc.typing.Fields.typeField(ctx, x, "toString", x.pos, MCall([]), WithTypeTools.withType(tstring)), [], WithTypeTools.withType(tstring), x.pos);
			var strNull = TypeFunctions.mk(TConst(TString("null")), tstring, e.pos);
			var simple = switch (e.expr) { case TLocal(_) | TConst(_): true; case _: false; };
			if (simple) {
				var check = TypeFunctions.mk(TBinop(OpEq, e, TexprTools.makeNull(e.type, e.pos)), ctx.com.basic.tbool, e.pos);
				return TypeFunctions.mk(TIf(check, strNull, gen(e)), tstring, e.pos);
			}
			var tmp = TypeFunctions.allocVar(VGenerated, "`tmp", e.type, e.pos);
			var tmpLocal = TexprTools.makeLocal(tmp, e.pos);
			var check = TypeFunctions.mk(TBinop(OpEq, tmpLocal, TexprTools.makeNull(e.type, e.pos)), ctx.com.basic.tbool, e.pos);
			var iff = TypeFunctions.mk(TIf(check, strNull, gen(tmpLocal)), tstring, e.pos);
			var decl = TypeFunctions.mk(TVarExpr(tmp, e), ctx.com.basic.tvoid, e.pos);
			return TypeFunctions.mk(TBlock([decl, iff]), tstring, e.pos);
		}
		function toString(e:TExpr):TExpr {
			// An abstract operand in a string concatenation whose impl defines toString is converted by
			// calling it (null-checked); other operands are stringified by the runtime.
			return switch (classify(e.type)) {
				case KAbstract(a, _) if (a.impl != null && a.impl.statics.exists("toString")):
					callToString(e);
				case _: e;
			};
		}
		function mkOp(a:TExpr, b:TExpr, t:T):BinopResult {
			if (op.match(OpAdd) && (switch (classify(t)) { case KString: true; case _: false; })) {
				a = toString(a);
				b = toString(b);
			}
			return BinopNormal(op, a, b, t, isAssignOp, false, p);
		}

		// Abstract operator overloading dispatches through the abstract @:op methods.
		if (!op.match(OpAssign) && !op.match(OpAssignOp(_))) {
			var opCall = tryAbstractOp(ctx, op, e1, e2, p);
			if (opCall != null) return BinopSpecial(opCall, isAssignOp);
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
				switch ([cmpClass(e1.type, op), cmpClass(e2.type, op)]) {
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

	// An operand already of the same abstract (by path) is passed through despite a possible
	// distinct type instance; otherwise an implicit cast is attempted.
	static function coerceArg(ctx:TyperContext, argT:T, e:TExpr, p:Position):Null<TExpr> {
		switch [TypeFunctions.follow(argT), TypeFunctions.follow(e.type)] {
			case [TAbstract(x, _), TAbstract(y, _)] if (x.path.name == y.path.name && x.path.pack.join(".") == y.path.pack.join(".")): return e;
			case _:
		}
		return try Typer.castOrUnify(ctx, argT, e, p) catch (_:TypingError) null;
	}

	static function sameOp(a:Binop, b:Binop):Bool {
		return switch [a, b] {
			case [OpAdd, OpAdd] | [OpSub, OpSub] | [OpMult, OpMult] | [OpDiv, OpDiv] | [OpMod, OpMod]
				| [OpLt, OpLt] | [OpLte, OpLte] | [OpGt, OpGt] | [OpGte, OpGte] | [OpEq, OpEq] | [OpNotEq, OpNotEq]
				| [OpAnd, OpAnd] | [OpOr, OpOr] | [OpXor, OpXor] | [OpShl, OpShl] | [OpShr, OpShr] | [OpUShr, OpUShr]
				| [OpBoolAnd, OpBoolAnd] | [OpBoolOr, OpBoolOr]: true;
			case _: false;
		};
	}

	// The abstract on the left of the operator owns the dispatch; its value is passed as the
	// impl method receiver and the right operand is coerced to the second parameter.
	static function tryAbstractOp(ctx:TyperContext, op:Binop, e1:TExpr, e2:TExpr, p:Position):Null<TExpr> {
		switch (TypeFunctions.follow(e1.type)) {
			case TAbstract(a, tl) if (a.impl != null):
				for (aop in a.ops) {
					if (!sameOp(aop.op, op)) continue;
					switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, aop.cf.type))) {
						case TFun(sig) if (sig.args.length == 2):
							var c2 = coerceArg(ctx, sig.args[1].t, e2, p);
							if (c2 == null) continue;
							// The @:op method body may not be typed yet; force it so a real (non-native)
							// operator dispatches to the method instead of a bare TBinop the runtime rejects.
							if (aop.cf.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx.com, a.impl, aop.cf);
							if (aop.cf.expr == null) {
								// A bodyless (native) @:op is the underlying operation, typed as its declared return.
								return TypeFunctions.mk(TBinop(op, e1, c2), sig.ret, p);
							}
							var implExpr = hxc.core.TexprTools.makeStaticThis(a.impl, p);
							var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, aop.cf, FHStatic(a.impl), false, p), FCall);
							return Calls.makeCall(ctx, fieldExpr, [e1, c2], sig.ret, p);
						case _:
					}
				}
			case _:
		}
		return null;
	}

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
			case OpAssignOp(OpNullCoal):
				// `a ??= b` rewrites to `a = (if (a != null) a else b)`.
				var eNull = new Expr(EConst(CIdent("null")), p);
				var eCond = new Expr(EBinop(OpNotEq, e1, eNull), p);
				var eIf = new Expr(EIf(eCond, e1, e2), p);
				typeAssign(ctx, e1, eIf, withType, p);
			case OpAssignOp(sub):
				typeAssignOp(ctx, sub, e1, e2, withType, p);
			case OpInterval:
				var tp:PlacedTypePath = {path: {tpackage: [], tname: "IntIterator", tparams: [], tsub: null}, pos: p};
				Typer.typeNew(ctx, tp, [e1, e2], withType, p);
			case OpNullCoal:
				// `a ?? b` desugars to `{ var tmp = a; if (tmp != null) tmp else b }`, evaluating the left
				// once.
				var te1 = Typer.typeExpr(ctx, e1, withType);
				var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.withType(te1.type));
				var t = Typer.unifyMin(ctx, [te1, te2]);
				var tvoid = ctx.com.basic.tvoid;
				var tmp = TypeFunctions.allocVar(VGenerated, "`tmp", te1.type, p);
				var tmpLocal = TexprTools.makeLocal(tmp, p);
				var check = TypeFunctions.mk(TBinop(OpNotEq, tmpLocal, TexprTools.makeNull(te1.type, p)), ctx.com.basic.tbool, p);
				var iff = TypeFunctions.mk(TIf(check, tmpLocal, te2), t, p);
				var decl = TypeFunctions.mk(TVarExpr(tmp, te1), tvoid, p);
				TypeFunctions.mk(TBlock([decl, iff]), t, p);
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
			case AKAccessor(fa):
				var setterAcc = hxc.typing.Fields.typeField(ctx, fa.on, "set_" + fa.field.name, fa.pos, MCall([e2]), WithTypeTools.value);
				hxc.typing.Calls.buildCall(ctx, setterAcc, [e2], WithTypeTools.value, p);
			case AKAccess(a, tl, c, ebase, ekey):
				hxc.typing.Calls.arraySet(ctx, a, tl, c, ebase, ekey, e2, p);
			case AKNo(_, np): throw new TypingError("This expression cannot be accessed for writing", np);
			case AKUsingAccessor(se):
				// Writing an abstract property calls the impl's set_<name>(this, value).
				var fa = se.access;
				var implC = FieldAccessTools.getHostClassRaise(fa.host);
				var setterCf = implC.statics.get("set_" + fa.field.name);
				if (setterCf == null) throw new TypingError("This expression cannot be accessed for writing", p);
				var setterFa = FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(implC), fa.pos), setterCf, FHStatic(implC), false, fa.pos);
				hxc.typing.Calls.buildCall(ctx, AKUsingField({thisExpr: se.thisExpr, access: setterFa}), [e2], WithTypeTools.value, p);
			case _: throw new TypingError("This assignment target is not yet ported", p);
		};
	}

	static function typeAssignOp(ctx:TyperContext, sub:Binop, e1:Expr, e2:Expr, withType:WithType, p:Position):TExpr {
		// `a[k] op= v` on an abstract @:arrayAccess: bind base and key to temps, read via the getter, apply
		// the op, write via the setter. AKAccess.
		switch (e1.expr) {
			case EArray(baseE, keyE):
				var tb = Typer.typeExpr(ctx, baseE, WithTypeTools.value);
				switch (TypeFunctions.follow(tb.type)) {
					case TAbstract(a, tl) if (a.impl != null && a.array.length > 0):
						var tk = Typer.typeExpr(ctx, keyE, WithTypeTools.value);
						var tvoid = ctx.com.basic.tvoid;
						var vb = TypeFunctions.allocVar(VGenerated, "`b", tb.type, p);
						var vk = TypeFunctions.allocVar(VGenerated, "`k", tk.type, p);
						var eb = TexprTools.makeLocal(vb, p);
						var ek = TexprTools.makeLocal(vk, p);
						var eget = switch (Calls.arrayAccess(ctx, eb, ek, MGet, p)) { case AKExpr(e): e; case _: throw new TypingError("@:arrayAccess getter not resolved", p); };
						var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
						var eop = toTexpr(makeBinop(ctx, sub, eget, te2, true, withType, p));
						var eset = Calls.arraySetValue(ctx, a, tl, a.impl, eb, ek, function(_) return eop, p);
						return TypeFunctions.mk(TBlock([
							TypeFunctions.mk(TVarExpr(vb, tb), tvoid, p),
							TypeFunctions.mk(TVarExpr(vk, tk), tvoid, p),
							eset
						]), eset.type, p);
					case _:
				}
			case _:
		}
		function compound(te1:TExpr):TExpr {
			var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
			// An abstract @:op compound assign is `a = a.op(b)` (the op dispatches to the impl method); a
			// native op stays as a compound TBinop the evaluator applies in place.
			return switch (makeBinop(ctx, sub, te1, te2, true, withType, p)) {
				case BinopSpecial(opCall, _):
					TypeFunctions.mk(TBinop(OpAssign, te1, Typer.castOrUnify(ctx, te1.type, opCall, p)), te1.type, p);
				case _:
					TypeFunctions.mk(TBinop(OpAssignOp(sub), te1, te2), te1.type, p);
			};
		}
		return switch (Typer.typeAccess(ctx, e1.expr, e1.pos, MGet, withType)) {
			case AKExpr(te1): compound(te1);
			case AKField(fa): compound(FieldAccessTools.getFieldExpr(fa, FWrite));
			case _:
				throw new TypingError("This compound assignment target is not yet ported", p);
		};
	}

	public static function typeUnop(ctx:TyperContext, op:Unop, flag:UnopFlag, e:Expr, withType:WithType, p:Position):TExpr {
		return switch (op) {
			case Spread:
				throw new TypingError("Spread unary operator is only allowed for unpacking the last argument in a call with rest arguments", p);
			case Increment | Decrement:
				// `a[k]++` / `--a[k]` on an abstract @:arrayAccess: bind base+key to temps, then get, op
				// with 1, and set, yielding the old value for postfix and the new value for prefix.
				switch (e.expr) {
					case EArray(baseE, keyE):
						var tb = Typer.typeExpr(ctx, baseE, WithTypeTools.value);
						switch (TypeFunctions.follow(tb.type)) {
							case TAbstract(a, tl) if (a.impl != null && a.array.length > 0):
								return arrayIncr(ctx, a, tl, op, flag, tb, keyE, withType, p);
							case _:
						}
					case _:
				}
				switch (Typer.typeAccess(ctx, e.expr, e.pos, MGet, withType)) {
					case AKExpr(te):
						var abs = tryAbstractUnop(ctx, op, flag, te, p);
						if (abs != null) abs else TypeFunctions.mk(TUnop(op, flag, te), te.type, p);
					case AKField(fa):
						var te = FieldAccessTools.getFieldExpr(fa, FWrite);
						var abs = tryAbstractUnop(ctx, op, flag, te, p);
						if (abs != null) abs else TypeFunctions.mk(TUnop(op, flag, te), te.type, p);
					case _: throw new TypingError("This increment target is not yet ported", p);
				}
			case Not | Neg | NegBits:
				var te = Typer.typeExpr(ctx, e, WithTypeTools.value);
				var abs = tryAbstractUnop(ctx, op, flag, te, p);
				if (abs != null) abs else makeUnop(ctx, op, flag, te, p);
		};
	}

	// Increment/decrement of an abstract @:arrayAccess element via getter+setter.
	static function arrayIncr(ctx:TyperContext, a:TAbstract, tl:TParams, op:Unop, flag:UnopFlag, tb:TExpr, keyE:Expr, withType:WithType, p:Position):TExpr {
		var tk = Typer.typeExpr(ctx, keyE, WithTypeTools.value);
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var vb = TypeFunctions.allocVar(VGenerated, "`b", tb.type, p);
		var vk = TypeFunctions.allocVar(VGenerated, "`k", tk.type, p);
		var eb = TexprTools.makeLocal(vb, p);
		var ek = TexprTools.makeLocal(vk, p);
		var eget = switch (Calls.arrayAccess(ctx, eb, ek, MGet, p)) { case AKExpr(e): e; case _: throw new TypingError("@:arrayAccess getter not resolved", p); };
		var binop = op.match(Increment) ? OpAdd : OpSub;
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		var stmts = [TypeFunctions.mk(TVarExpr(vb, tb), tvoid, p), TypeFunctions.mk(TVarExpr(vk, tk), tvoid, p)];
		if (flag.match(Postfix)) {
			var vold = TypeFunctions.allocVar(VGenerated, "`o", eget.type, p);
			var eold = TexprTools.makeLocal(vold, p);
			stmts.push(TypeFunctions.mk(TVarExpr(vold, eget), tvoid, p));
			var newv = toTexpr(makeBinop(ctx, binop, eold, one, false, withType, p));
			stmts.push(Calls.arraySetValue(ctx, a, tl, a.impl, eb, ek, function(_) return newv, p));
			stmts.push(eold);
			return TypeFunctions.mk(TBlock(stmts), eold.type, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, eget, one, false, withType, p));
		var vnew = TypeFunctions.allocVar(VGenerated, "`n", newv.type, p);
		var enew = TexprTools.makeLocal(vnew, p);
		stmts.push(TypeFunctions.mk(TVarExpr(vnew, newv), tvoid, p));
		stmts.push(Calls.arraySetValue(ctx, a, tl, a.impl, eb, ek, function(_) return enew, p));
		stmts.push(enew);
		return TypeFunctions.mk(TBlock(stmts), enew.type, p);
	}

	// An abstract that overloads this unary operator dispatches to its @:op impl method.
	static function tryAbstractUnop(ctx:TyperContext, op:Unop, flag:UnopFlag, e:TExpr, p:Position):Null<TExpr> {
		switch (TypeFunctions.follow(e.type)) {
			case TAbstract(a, tl) if (a.impl != null):
				for (au in a.unops) {
					if (au.op != op || au.flag != flag) continue;
					var sig = switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, au.cf.type))) { case TFun(s): s; case _: null; };
					var ret = sig != null ? sig.ret : e.type;
					if (au.cf.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx.com, a.impl, au.cf);
					if (au.cf.expr == null) return TypeFunctions.mk(TUnop(op, flag, e), ret, p);
					var implExpr = hxc.core.TexprTools.makeStaticThis(a.impl, p);
					var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, au.cf, FHStatic(a.impl), false, p), FCall);
					return Calls.makeCall(ctx, fieldExpr, [e], ret, p);
				}
			case _:
		}
		return null;
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
