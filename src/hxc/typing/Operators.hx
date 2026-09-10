package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.NotFound;
import hxc.core.WithType;
import hxc.debug.DebugDump;
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

// Raised as a typing error that propagates PAST the candidate loop - it is a verdict on a matched overload,
// not a "this candidate does not apply". The loop catches TypingError to move to the next candidate, so the
// verdict needs to be distinguishable or the search silently falls through to the underlying-type path and
// the operation compiles.
class AbstractOpResultError extends TypingError {}

class Operators {
	static function storedSyntax(ctx:TyperContext, e:TExpr):Expr {
		var id = hxc.context.Context.allocStoredTypedExprId("storedSyntax");
		ctx.com.storedTypedExprs.set(id, e);
		return new Expr(EMeta({name: ":storedTypedExpr", params: [], pos: Position.nullPos}, new Expr(EConst(CInt(Std.string(id), null)), e.pos)), e.pos);
	}
	static function unify(ctx:TyperContext, a:T, b:T, p:Position):Void {
		DebugDump.unify("operator", a, b, p);
		try {
			TypeUnification.unifyDefault(a, b);
		} catch (e:UnifyError) {
			// raiseOrDisplay, all three arms: untyped swallows, call arguments raise so the caller can try
			// another overload, everything else RECORDS and carries on.
			TyperContext.raiseOrDisplay(ctx, hxc.core.TPrinting.betterErrorMessage(e.errors), p);
		}
	}

	// The RAISING unify. Only OpEq/OpNotEq wants it, to pick the other direction when the first does not
	// unify (castOrUnifyRaise inside a try whose fallback is the recording cast). Everywhere else uses the
	// recording unify above, and raising there would swallow every later complaint.
	static function unifyRaise(ctx:TyperContext, a:T, b:T, p:Position):Void {
		DebugDump.unify("operator", a, b, p);
		try {
			TypeUnification.unifyDefault(a, b);
		} catch (e:UnifyError) {
			if (ctx.untypedMode) return;
			throw new TypingError(hxc.core.TPrinting.betterErrorMessage(e.errors), p);
		}
	}

	static function checkAssign(ctx:TyperContext, e:TExpr):Void {
		switch (e.expr) {
			// When errors are ignored, assigning to a final local is not rejected here either.
			case TLocal(v) if (TypeFunctions.hasVarFlag(v, VFinal) && !ctx.untypedMode && !ctx.com.ignoreErrors):
				throw new TypingError("Cannot assign to final", e.pos);
			case TLocal(v) if (v.extra == null):
			// Every TField is let through: whether the write is allowed is decided by the ACCESS (an
			// unwritable one resolves to AKNo), not here.
			case TArray(_, _) | TField(_, _) | TIdent(_):
			case TConst(TThis) | TTypeExpr(_) if (ctx.untypedMode):
			case _ if (!ctx.untypedMode):
				throw new TypingError("Invalid assign", e.pos);
			case _:
		}
	}

	static function isSameAssignTarget(e1:TExpr, e2:TExpr):Bool {
		return switch [e1.expr, e2.expr] {
			case [TLocal(v1), TLocal(v2)] if (v1 == v2): true;
			case [TField({expr: TConst(TThis)}, FInstance(_, _, f1)), TField({expr: TConst(TThis)}, FInstance(_, _, f2))] if (f1 == f2): true;
			case _: false;
		}
	}

	static function isConstructorThisField(ctx:TyperContext, e:TExpr):Bool {
		return switch (ctx.curfun) {
			case FunConstructor:
				switch (e.expr) {
					case TConst(TThis): true;
					case TLocal(v) if (ctx.vthis != null && v == ctx.vthis): true;
					case TLocal({kind: VGenerated | VInlined | VInlinedConstructorVariable}): true;
					case _: false;
				}
			case _:
				false;
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
			// A @:coreType abstract is never KAbstract: it classifies by its @:to casts instead (a
			// cpp.AtomicInt, whose to is Int, is KNumParam -> Std.string in a concat). hxc builds an impl
			// class for a coreType abstract's native methods, so impl alone does not decide it.
			case TAbstract(a, tl) if (a.impl != null && !TypeFunctions.hasMeta(":coreType", a.meta)): KAbstract(a, tl);
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
		// isDynamicArray: a non-Array-shaped receiver counts as dynamic
		function isDynamicArray(t:T):Bool {
			return switch (TypeFunctions.follow(t)) {
				case TInst(_, [p]): isDynamic(p);
				case _: true;
			};
		}
		function isDynamicField(t:T, name:String):Bool {
			return switch (TypeFunctions.follow(t)) {
				case TAnon(a):
					var cf = a.fields.get(name);
					cf != null && isDynamic(cf.type);
				case TMono(m):
					// A structurally-constrained monomorph (a.length adds a length field) is not dynamic in
					// that field: read the constraint field's type.
					switch (TypeUnification.classifyDownConstraints(m)) {
						case CStructural(fields, _):
							var cf = fields.get(name);
							cf != null && isDynamic(cf.type);
						case _: true;
					}
				case TInst(c, tl):
					try {
						var f = TypeFunctions.classField(c, tl, name);
						isDynamic(TypeFunctions.applyParams(c.params, tl, f.t));
					} catch (_:hxc.core.NotFound) false;
				case _: true;
			};
		}
		// isDynamicReturn: a non-function type counts as dynamic
		function isDynamicReturn(t:T):Bool {
			return switch (TypeFunctions.follow(t)) {
				case TFun(sig): isDynamic(sig.ret);
				case _: true;
			};
		}
		// Quick analysis of the common dynamic-to-mono conversions (array reads, field reads, calls whose
		// function type returns Dynamic).
		function maybeDynamicMono(e:TExpr):Bool {
			inline function rec(e2:TExpr, t:T):Bool {
				return switch (TypeFunctions.follow(t)) {
					case TMono(_) | TDynamic(_): maybeDynamicMono(e2);
					case _: false;
				};
			}
			return switch (e.expr) {
				case TLocal(_): isDynamic(e.type);
				case TArray(e1, _): isDynamicArray(e1.type) || rec(e1, e1.type);
				case TField(e1, fa): isDynamicField(e1.type, TypeFunctions.fieldName(fa)) || rec(e1, e1.type);
				case TCall(e1, _): isDynamicReturn(e1.type) || rec(e1, e1.type);
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

		// String conversion. An abstract with a static toString goes through the one Calls.callToString; an
		// operand that is not a basic type through Std.string, typed as a field access with the binop's own
		// expected type.
		function toString(e:TExpr):TExpr {
			function loop(t:T):TExpr {
				return switch (classify(t)) {
					case KAbstract(a, _) if (a.impl != null && a.impl.statics.exists("toString")):
						hxc.typing.Calls.callToString(ctx, e);
					case KInt | KFloat | KString: e;
					case KUnk | KDyn | KNumParam(_) | KStrParam(_) | KOther:
						var std = TexprTools.makeTypeExpr(Typeload.resolveTypePath(ctx.com, {pack: [], name: "Std"}, null, e.pos), e.pos);
						var acc = Typer.accGet(ctx, hxc.typing.Fields.typeField(ctx, std, "string", e.pos, MCall([]), withType));
						TypeFunctions.follow(acc.type);
						acc = switch (acc.expr) {
							case TField(e0, FClosure(cwp, f)) if (cwp != null): TypeFunctions.mk(TField(e0, FInstance(cwp.c, cwp.params, f)), acc.type, acc.pos);
							case _: acc;
						};
						hxc.typing.Calls.makeCall(ctx, acc, [e], tstring, e.pos);
					case KAbstract(a, tl):
						try Typer.castOrUnifyRaise(ctx, tstring, e, p)
						catch (_:hxc.core.TypingError.CastUnifyError) loop(TypeFunctions.getUnderlyingType(a, tl));
				};
			}
			return loop(e.type);
		}
		function mkOp(a:TExpr, b:TExpr, t:T):BinopResult {
			if (op.match(OpAdd) && (switch (classify(t)) { case KString: true; case _: false; })) {
				a = toString(a);
				b = toString(b);
			}
			return BinopNormal(op, a, b, t, isAssignOp, false, p);
		}

		// Abstract operator overloading dispatches through the abstract @:op methods (left or right
		// operand).
		if (!op.match(OpAssign) && !op.match(OpAssignOp(_))) {
			var br = tryAbstractBinop(ctx, op, e1, e2, isAssignOp, withType, p);
			if (br != null) {
				if (DebugDump.enabled("select", p))
					DebugDump.selected("op", p, "abstract " + Std.string(op) + " -> " + DebugDump.typeString(binopResultType(br)));
				return br;
			}
		}
		var result = switch (op) {
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
					case _: throw new TypingError("Cannot add " + hxc.core.TPrinting.sTypeStr(e1.type) + " and " + hxc.core.TPrinting.sTypeStr(e2.type), p);
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
				var c1 = e1, c2 = e2;
				try unifyRaise(ctx, c1.type, c2.type, p) catch (_:TypingError) {
					try unifyRaise(ctx, c2.type, c1.type, p) catch (_:TypingError) {
						// Neither operand unifies directly: follow an abstract @:to/@:from cast so an abstract
						// compares against its underlying type (plain unify does not chase method casts); the failure
						// reports at the BINOP position without aborting, so a boolean context around the comparison
						// still checks. The first operand goes through castOrUnifyRaise, and on its failure the
						// second through castOrUnify, which records its own verdict.
						try c1 = Typer.castOrUnifyRaise(ctx, c2.type, c1, p) catch (_:TypingError) {
							c2 = Typer.castOrUnify(ctx, c1.type, c2, p);
						}
					}
				}
				switch [TypeFunctions.follow(c1.type), TypeFunctions.follow(c2.type)] {
					case [TEnum(en, _), _] | [_, TEnum(en, _)]:
						var hasArgs = false;
						for (name in en.constrs.keys()) switch (TypeFunctions.follow(en.constrs.get(name).type)) {
							case TFun(sig) if (sig.args.length > 0): hasArgs = true;
							case _:
						}
						if (hasArgs && p.file.indexOf("/haxe/") < 0 && p.file.indexOf("\\haxe\\") < 0)
							ctx.com.warning(hxc.core.WarningList.Warning.WUnsafeEnumEquality, [], "Equality operations on this enum might lead to unexpected results because some constructors have arguments", p);
					case _:
				}
				mkOp(c1, c2, tbool);
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
					case _: throw new TypingError("Cannot compare " + hxc.core.TPrinting.sTypeStr(e1.type) + " and " + hxc.core.TPrinting.sTypeStr(e2.type), p);
				}
				mkOp(e1, e2, tbool);
			case OpBoolAnd | OpBoolOr:
				unify(ctx, e1.type, tbool, p);
				unify(ctx, e2.type, tbool, p);
				mkOp(e1, e2, tbool);
			case OpInterval:
				// IntIterator is loaded as a core type, each bound is cast to Int with castOrUnifyRaise,
				// and the construction is built directly.
				var t = Typeload.loadCoreType(ctx.com, "IntIterator");
				var c = switch (t) {
					case TInst(c, []): c;
					case _: throw new TypingError("IntIterator is not a class", p);
				};
				var ce1 = Typer.castOrUnifyRaise(ctx, tint, e1, e1.pos);
				var ce2 = Typer.castOrUnifyRaise(ctx, tint, e2, e2.pos);
				BinopSpecial(TypeFunctions.mk(TNew(c, [], [ce1, ce2]), t, p), false);
			case OpArrow:
				throw new TypingError("Unexpected =>", p);
			case OpIn:
				throw new TypingError("Unexpected in", p);
			case OpNullCoal | OpAssign | OpAssignOp(_):
				throw new TypingError("This operator is not handled by make_binop", p);
		};
		if (DebugDump.enabled("select", p))
			DebugDump.selected("op", p, "builtin " + Std.string(op) + " -> " + DebugDump.typeString(binopResultType(result)));
		return result;
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

	// Emit the static impl-method call for a @:op field, preserving evaluation order when the operands were
	// swapped for a @:commutative overload (bind both to temps so the original left is evaluated first).
	static function makeStaticOpCall(ctx:TyperContext, implC:TClass, cf:TClassField, map:T->T, args:Array<TExpr>, tret:T, p:Position):TExpr {
		var implExpr = hxc.core.TexprTools.makeStaticThis(implC, p);
		var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p), FCall);
		// The static call spawns fresh monomorphs for the field's own params and types the field
		// EXPRESSION as `map cf.type`, where the caller's map applies the ABSTRACT's parameters. Hosting
		// the access on the impl class alone leaves the signature holding the abstract's type parameters,
		// and a referenced-type walk skips a KTypeParameter, so the types reachable only through an @:op
		// signature would never get their include emitted.
		var monos = [for (_ in cf.params) TypeFunctions.mkMono()];
		function mapFull(t:T):T return map(TypeFunctions.applyParams(cf.params, monos, t));
		fieldExpr = TypeFunctions.mk(fieldExpr.expr, mapFull(cf.type), fieldExpr.pos);
		// A trailing optional ?p:haxe.PosInfos on the op method receives the call-site info.
		switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): args = Calls.padPosInfos(ctx, sig.args, args, p);
			case _:
		}
		return Calls.makeCall(ctx, fieldExpr, args, tret, p);
	}

	// Try to dispatch a binary operator through an abstract @:op overload, on either operand. The
	// abstract-side operand is matched with a NON-binding-on-failure type equality (EqStrict, wrapped in a
	// mono-rollback so a failed probe never leaves an unrelated mono bound), the other operand is
	// implicitly cast.
	static function tryAbstractBinop(ctx:TyperContext, op:Binop, e1:TExpr, e2:TExpr, isAssignOp:Bool, withType:WithType, p:Position):Null<BinopResult> {
		// A non-abstract e1 falls through to the e2 probe DIRECTLY rather than by throwing NotFound, which
		// on hxcpp would cost a throw for every binop whose left side is not an abstract. The catches stay
		// for findAbstractBinop's own NotFound, which still means "no overload matched".
		switch (TypeFunctions.follow(e1.type)) {
			case TAbstract(a, tl) if (a.impl != null):
				try return findAbstractBinop(ctx, op, e1, e2, a, a.impl, tl, true, isAssignOp, withType, p)
				catch (_:NotFound) {}
			case _:
		}
		return try {
			switch (TypeFunctions.follow(e2.type)) {
				case TAbstract(a, tl) if (a.impl != null): findAbstractBinop(ctx, op, e1, e2, a, a.impl, tl, false, isAssignOp, withType, p);
				case _: null;
			}
		} catch (_:NotFound) null;
	}

	// A NotFound in the overload search bubbles to tryAbstractBinop, which then tries the other operand.
	static function findAbstractBinop(ctx:TyperContext, op:Binop, e1:TExpr, e2:TExpr, a:TAbstract, implC:TClass, tl:TParams, left:Bool, isAssignOp:Bool, withType:WithType, p:Position):BinopResult {
		function map(t:T):T return TypeFunctions.applyParams(a.params, tl, t);
		var isEqOp = switch (op) { case OpEq | OpNotEq: true; case _: false; };

		// == / != with a monomorph operand: unify the two operand types so comparison semantics hold.
		if (isEqOp) switch [TypeFunctions.follow(e1.type), TypeFunctions.follow(e2.type)] {
			case [TMono(_), _] | [_, TMono(_)]: try TypeUnification.unifyDefault(e1.type, e2.type) catch (_:UnifyError) {}
			case _:
		}

		function make(opCf:Binop, cf:TClassField, me1:TExpr, me2:TExpr, tret:T, needsAssign:Bool, swapped:Bool):BinopResult {
			// The @:op body may be unforced; force it so a genuinely bodyless (native) @:op is
			// distinguished from a not-yet-typed one.
			if (cf.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx.com, implC, cf);
			if (cf.expr == null && !hxc.typing.TypeFields.fieldHasSyntaxBody(ctx.com, implC, cf) && !TypeFunctions.hasClassFieldFlag(cf, CfExtern)) {
				// For a bodyless @:op on a non-core-type abstract the declared return type must be
				// compatible with the native result of the operation on the underlying types.
				if (!TypeFunctions.hasMeta(":coreType", a.meta)) {
					var u1 = TypeFunctions.mk(me1.expr, TypeFunctions.followWithAbstracts(me1.type), me1.pos);
					var u2 = TypeFunctions.mk(me1.expr, TypeFunctions.followWithAbstracts(me2.type), me1.pos);
					// makeBinop takes the operator being resolved, not the @:op's own (an OpAssignOp for a
					// `+=` overload, which makeBinop does not handle).
					var tExpected = switch (makeBinop(ctx, op, u1, u2, isAssignOp, withType, p)) {
						case BinopNormal(_, _, _, t, _, _, _): t;
						case BinopSpecial(e, _): e.type;
					};
					try TypeUnification.unifyDefault(tret, tExpected) catch (_:UnifyError) {
						switch (TypeFunctions.follow(tret)) {
							case TAbstract(ra, rtl) if (TypeUnification.typeIseqDefault(TypeFunctions.getUnderlyingType(ra, rtl), tExpected)):
							case _:
								throw new AbstractOpResultError("The result of this operation (" + hxc.core.TPrinting.sTypeStr(tExpected) + ") is not compatible with declared return type " + hxc.core.TPrinting.sTypeStr(tret), p);
						}
					}
				}
				// A bodyless @:op means the underlying-type semantics: emit the native operation on the
				// (possibly swapped) operands, typed as the declared return. It is returned as a special
				// result (not BinopNormal) so a compound assignment lowers it to `a = (a op b)` rather than
				// a native `a op= b`, which the evaluator cannot apply to an abstract value. The assign
				// flag
				// uses isAssignOp (bodyless @:op wants underlying-type assignment semantics).
				if (swapped) {
					// The binop result binds through the value reference, whose block is tagged :mergeBlock
					// so it FLATTENS into the enclosing block. A plain nested block is a value instead, and
					// the temps get substituted straight back out again.
					var vrVars:Array<TExpr> = [];
					var elhs = vrAsVar(ctx, vrVars, "lhs", me2);
					var erhs = vrAsVar(ctx, vrVars, "rhs", me1);
					return BinopSpecial(vrToTexpr(vrVars, TypeFunctions.mk(TBinop(op, erhs, elhs), tret, p)), isAssignOp);
				}
				return BinopSpecial(TypeFunctions.mk(TBinop(op, me1, me2), tret, p), isAssignOp);
			} else if (swapped) {
				// Both operands bind through the value reference so the original left is evaluated first;
				// the block is tagged :mergeBlock so it FLATTENS into the enclosing block rather than
				// staying a nested value.
				var vrVars:Array<TExpr> = [];
				var elhs = vrAsVar(ctx, vrVars, "lhs", me2);
				var erhs = vrAsVar(ctx, vrVars, "rhs", me1);
				var call = makeStaticOpCall(ctx, implC, cf, map, [erhs, elhs], tret, p);
				return BinopSpecial(vrToTexpr(vrVars, call), needsAssign);
			} else {
				return BinopSpecial(makeStaticOpCall(ctx, implC, cf, map, [me1, me2], tret, p), needsAssign);
			}
		}

		// Search a.ops for an overload matching findOp; returns the BinopResult or throws NotFound.
		function loop(findOp:Binop, ol:Array<TAbstractOp>):BinopResult {
			for (i in 0...ol.length) {
				var aop = ol[i];
				if (!Type.enumEq(aop.op, findOp)) continue;
				var cf = aop.cf;
				var isImpl = TypeFunctions.hasClassFieldFlag(cf, CfImpl);
				switch (TypeFunctions.follow(cf.type)) {
					case TFun(sig) if (sig.args.length >= 2):
						var bt1 = sig.args[0].t;
						var bt2 = sig.args[1].t;
						var btret = sig.ret;
						function check(ce1:TExpr, ce2:TExpr, swapped:Bool):BinopResult {
							// Fresh monos per attempt so a failed probe cannot bind the method's own params, and
							// wrap the whole attempt in a mono-rollback so a failure restores every touched mono.
							return TypeUnification.withMonoRollback(function() {
								// The op method's own params spawn CONSTRAINED, so a Float operand cannot
								// bind a T:Int param (UInt.equalsInt vs equalsFloat selection).
								var monos = TypeUnification.spawnConstrainedMonos(function(t) return t, cf.params);
								function mapCf(t:T):T return map(TypeFunctions.applyParams(cf.params, monos, t));
								var t1 = mapCf(bt1);
								var t2 = mapCf(bt2);
								var tret = mapCf(btret);
								if (isImpl) t1 = TypeFunctions.followWithAbstracts(t1);
								var re1:TExpr, re2:TExpr;
								if (left || (!left && swapped)) {
									var lhsT = isImpl ? TypeFunctions.followWithAbstracts(ce1.type) : ce1.type;
									TypeUnification.typeEqKind(EqStrict, lhsT, t1);
									re1 = ce1;
									// An overload ATTEMPT casts its operand through castOrUnifyRaise; the
									// failure is what moves the search on.
									re2 = Typer.castOrUnifyRaise(ctx, t2, ce2, p);
								} else {
									TypeUnification.typeEqKind(EqStrict, ce2.type, t2);
									re1 = Typer.castOrUnifyRaise(ctx, t1, ce1, p);
									re2 = ce2;
								}
								// Null operand only allowed against an explicitly-nullable arg (issue #3376).
								if (isEqOp) {
									checkNullArg(re2, t2);
									checkNullArg(re1, t1);
								}
								var needsAssign = isAssignOp && Type.enumEq(aop.op, op);
								return make(aop.op, cf, re1, re2, tret, needsAssign, swapped);
							});
						}
						// Try direct order, then the commutative-swapped order. The search moves on only
						// for a UNIFICATION failure (a unify error, or the one castOrUnifyRaise raises);
						// any other error out of the attempt - such as the inliner's write check on the
						// overload it picked - goes on up. The mono rollback inside check has already
						// undone any speculative binding.
						try {
							return check(e1, e2, false);
						} catch (_:UnifyError) {
						} catch (_:hxc.core.TypingError.CastUnifyError) {
						}
						if (TypeFunctions.hasMeta(":commutative", cf.meta)) {
							try {
								return check(e2, e1, true);
							} catch (_:UnifyError) {
							} catch (_:hxc.core.TypingError.CastUnifyError) {
							} catch (_:NotFound) {
							}
						}
					case _:
				}
			}
			throw new NotFound("Operators.hx:673");
		}

		// Right operand: only non-impl (bodyless) or @:commutative overloads may apply.
		function find(findOp:Binop):BinopResult {
			if (left) return loop(findOp, a.ops);
			var filtered = [for (aop in a.ops) if (!TypeFunctions.hasClassFieldFlag(aop.cf, CfImpl) || TypeFunctions.hasMeta(":commutative", aop.cf.meta)) aop];
			return loop(findOp, filtered);
		}

		if (isAssignOp) {
			return try find(OpAssignOp(op)) catch (_:NotFound) find(op);
		}
		return find(op);
	}

	static function checkNullArg(e:TExpr, t:T):Void {
		switch (e.expr) {
			case TConst(TNull) if (!TypeFunctions.isExplicitNull(t)): throw new UnifyError([], "Operators.hx:694");
			case _:
		}
	}

	static function binopResultType(br:BinopResult):T {
		return switch (br) {
			case BinopNormal(_, _, _, t, _, _, _): t;
			case BinopSpecial(e, _): e.type;
		};
	}

	static function toTexpr(br:BinopResult):TExpr {
		return switch (br) {
			case BinopNormal(op, lhs, rhs, t, _, _, pos): TypeFunctions.mk(TBinop(op, lhs, rhs), t, pos);
			case BinopSpecial(e, _): e;
		};
	}

	static function promotedBinopWithType(op:Binop, withType:WithType):WithType {
		return switch (withType) {
			case WithType(t, _):
				switch (TypeFunctions.follow(t)) {
					case TAbstract(a, _):
						var n = 0;
						for (aop in a.ops) if (Type.enumEq(aop.op, op) || Type.enumEq(aop.op, OpAssignOp(op))) n++;
						n == 1 ? withType : WithTypeTools.value;
					case _:
						WithTypeTools.value;
				}
			case _:
				WithTypeTools.value;
		}
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
			case OpAssignOp(OpBoolAnd | OpBoolOr):
				throw new TypingError("The operators ||= and &&= are not supported", p);
			case OpAssignOp(sub):
				typeAssignOp(ctx, sub, e1, e2, withType, p);
			case OpNullCoal:
				// `a ?? b` desugars to `{ var tmp = a; if (tmp != null) tmp else b }`, evaluating the left
				// once.
				var te1 = Typer.typeExpr(ctx, Expr.ensureBlock(e1), withType);
				var te2 = Typer.typeExpr(ctx, Expr.ensureBlock(e2), WithTypeTools.withType(te1.type));
				var tmin = Typer.unifyMin(ctx, [te1, te2]);
				// The result type: when e2 is not a dead end and is not explicitly
					// Null, strip Null from tmin so a null-coalescing with a non-nullable right side is itself
					// non-nullable (e.g. nullBool ?? true is Bool, not Null<Bool>).
					var t = if (TexprTools.hasDeadEnd(te2)) {
						TypeFunctions.followWithoutType(ctx.com.basic.tnull(tmin));
					} else {
						switch (te2.type) {
							case TAbstract(a, [_]) if (a.path.pack.length == 0 && a.path.name == "Null"): tmin;
							case _: TypeFunctions.followWithoutType(tmin);
						}
					};
				var tvoid = ctx.com.basic.tvoid;
				var tmpType = ctx.com.basic.tnull(tmin);
				// The value-reference temp keeps its plain name (not a gen local), so it renders as tmp,
				// not _gtmp.
				var tmp = TypeFunctions.allocVar(VGenerated, "tmp", tmpType, p);
				var tmpLocal = TexprTools.makeLocal(tmp, p);
				var check = TypeFunctions.mk(TBinop(OpNotEq, tmpLocal, TexprTools.makeNull(tmpType, p)), ctx.com.basic.tbool, p);
				var iff = Typer.makeIfThenElse(ctx, check, tmpLocal, te2, WithTypeTools.withType(t), p);
				var decl = TypeFunctions.mk(TVarExpr(tmp, te1), tvoid, p);
				// The temp-binding block is wrapped in a :mergeBlock meta, so the analyzer merges it into
				// the enclosing scope and declares an assigned-in-branches result var before the temp,
				// rather than splicing the plain block and emitting the temp first.
				var block = TypeFunctions.mk(TBlock([decl, iff]), t, p);
				TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: Position.nullPos}, block), t, p);
			case _:
				var lhsWt = promotedBinopWithType(op, withType);
				var te1 = Typer.typeExpr(ctx, e1, lhsWt);
				var rhsWt = switch (op) {
					case OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte: WithTypeTools.withType(te1.type);
					case _: lhsWt;
				};
				var te2 = Typer.typeExpr(ctx, e2, rhsWt);
				toTexpr(makeBinop(ctx, op, te1, te2, isAssignOp, withType, p));
		};
	}

	// typeRhs: the value of an assignment that fails to type is recorded and stands as `null`, so the
	// assignment itself is still made - a final field assigned that way in a constructor counts as
	// initialized.
	static function typeRhs(ctx:TyperContext, e2:Expr, withType:WithType):TExpr {
		return try Typer.typeExpr(ctx, e2, withType) catch (err:TypingError) {
			ctx.com.addTypingError(err.message, err.pos, err.depth, err.callChain);
			TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, e2.pos);
		} catch (ce:hxc.context.Context.ContextError) {
			ctx.com.addTypingError(ce.message, ce.pos, ce.depth, ce.callChain);
			TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, e2.pos);
		};
	}

	static function assignTo(ctx:TyperContext, te1:TExpr, e2:Expr, p:Position):TExpr {
		var te2 = Typer.castOrUnify(ctx, te1.type, typeRhs(ctx, e2, WithTypeTools.withType(te1.type)), p);
		// A named local function is not writable.
		switch (te1.expr) {
			case TLocal(v) if (v.kind.match(VUser(TVOLocalFunction)) && !ctx.untypedMode):
				throw new TypingError("Cannot access function " + v.name + " for writing", p);
			case _:
		}
		checkAssign(ctx, te1);
		if (isSameAssignTarget(te1, te2)) throw new TypingError("Assigning a value to itself", p);
		return TypeFunctions.mk(TBinop(OpAssign, te1, te2), te1.type, p);
	}

	// Value reference, vrGetExprAux: depth 0 keeps a field/array access SHAPE, binding only its non-simple
	// parts ("fh" receiver, "base"/"index" operands); depth 1 binds any non-simple expression whole. Binds
	// accumulate as TVar decls.
	// vrAsVar: always bind, allocating at the bound expression's position and referring to the new local at
	// v.pos.
	static function vrAsVar(ctx:TyperContext, vars:Array<TExpr>, name:String, e:TExpr):TExpr {
		var v = TypeFunctions.allocVar(VGenerated, name, e.type, e.pos);
		vars.push(TypeFunctions.mk(TVarExpr(v, e), ctx.com.basic.tvoid, v.pos));
		return TexprTools.makeLocal(v, v.pos);
	}

	static function vrGetExprAux(ctx:TyperContext, vars:Array<TExpr>, depth:Int, name:String, e:TExpr):TExpr {
		return switch (TexprTools.skip(e).expr) {
			case TLocal(_) | TTypeExpr(_) | TConst(_):
				e;
			case TField(ef, fa) if (depth == 0):
				var ef2 = vrGetExprAux(ctx, vars, 1, "fh", ef);
				TypeFunctions.mk(TField(ef2, fa), e.type, e.pos);
			case TArray(e1, e2) if (depth == 0):
				var e1b = vrGetExprAux(ctx, vars, 1, "base", e1);
				var e2b = vrGetExprAux(ctx, vars, 1, "index", e2);
				TypeFunctions.mk(TArray(e1b, e2b), e.type, e.pos);
			case _:
				var v = TypeFunctions.allocVar(VGenerated, name, e.type, e.pos);
				vars.push(TypeFunctions.mk(TVarExpr(v, e), ctx.com.basic.tvoid, v.pos));
				TexprTools.makeLocal(v, v.pos);
		}
	}

	// vrToTexpr: the binds-plus-result block is wrapped in @:mergeBlock, so a statement-position result
	// SPLICES into the enclosing block (typeBlock's merge); fusion then sees flat statements instead of a
	// nested value block it could collapse into an argument.
	static function vrToTexpr(vars:Array<TExpr>, e:TExpr):TExpr {
		if (vars.length == 0) return e;
		var b = TypeFunctions.mk(TBlock(vars.concat([e])), e.type, e.pos);
		return TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: Position.nullPos}, b), b.type, b.pos);
	}

	static function maybeTempReceiver(ctx:TyperContext, recv:TExpr, p:Position):{expr:TExpr, init:Null<TExpr>} {
		// A stable side-effect-free lvalue stays as-is so an inline setter assigning `this` writes
		// back through the original storage (a static field, array element or field chain).
		return if (Inline.isStableLvalue(recv)) {expr: recv, init: null} else switch (recv.expr) {
			case _:
				// The bound temp is allocated at the bound EXPRESSION's position and declared at `v.pos`, so
				// the declaration sits on the receiver rather than on the enclosing operator.
				var v = TypeFunctions.allocVar(VGenerated, "fh", recv.type, recv.pos);
				{expr: TexprTools.makeLocal(v, v.pos), init: TypeFunctions.mk(TVarExpr(v, recv), ctx.com.basic.tvoid, v.pos)};
		}
	}

	static function typeAssign(ctx:TyperContext, e1:Expr, e2:Expr, withType:WithType, p:Position):TExpr {
		var lhsAcc = Typer.typeAccess(ctx, e1.expr, e1.pos, MSet(e2), withType);
		// The display answers on the ACCESS, whether or not the write that follows is allowed.
		Typer.checkDisplayOnAccess(ctx, lhsAcc, e1.pos);
		// When errors are ignored the write check does not raise. It recurses into the access the AKNo
		// WRAPS and assigns through that, so a display request still has a real assignment expression to
		// answer from - which is how `finalField = x` reports the field type rather than the enclosing
		// block. A diagnostics run carries EPNormal and reports it as the error it is.
		while (true) switch (lhsAcc) {
			case AKNo(inner, np):
				if (!ctx.com.ignoreError())
					throw new TypingError("This expression cannot be accessed for writing", np);
				lhsAcc = inner;
			case _: break;
		}
		return switch (lhsAcc) {
			case AKExpr(te1): assignTo(ctx, te1, e2, p);
			case AKField(fa):
				// Assigning to a dynamic method must see its inferred return already settled (a no-return
				// body links the mono to Void) before the rhs types against it. hxc types signature and
				// body separately, so force the body here to bind the same monos.
				if (fa.field.kind.match(Method(_))) {
					var hostC = try FieldAccessTools.getHostClassRaise(fa.host) catch (_:Dynamic) null;
					if (hostC != null) hxc.typing.TypeFields.forceFieldBody(ctx.com, hostC, fa.field);
				}
				assignTo(ctx, FieldAccessTools.getFieldExpr(fa, FWrite), e2, p);
			case AKAccessor(fa):
				switch (FieldAccessTools.resolveAccessor(fa, MSet(e2))) {
					case AccessorFound(setterFa):
						hxc.typing.Calls.accessorCallResult(fa, hxc.typing.Calls.buildCall(ctx, AKField(setterFa), [e2], WithTypeTools.value, p));
					case AccessorAnon:
						// No accessor field is available (anon structure or extern class): synthesize a
						// dynamic set_<name>(v) call.
						var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.withType(fa.field.type));
						var t = fa.field.type;
						var tf = TFun({args: [{name: "value", opt: false, t: te2.type}], ret: t});
						hxc.typing.Calls.makeCall(ctx, TypeFunctions.mk(TField(fa.on, TypeFunctions.quickFieldDynamic(fa.on.type, "set_" + fa.field.name)), tf, p), [te2], t, p);
					case AccessorNotFound | AccessorInvalid:
						throw new TypingError("This expression cannot be accessed for writing", p);
				}
			case AKAccess(a, tl, c, ebase, ekey):
				// The value is typed once, as a value, before a setter is looked for (the array write access
				// lookup casts it to each candidate's parameter).
				var te2 = typeRhs(ctx, e2, WithTypeTools.value);
				hxc.typing.Calls.arraySetValue(ctx, a, tl, c, ebase, ekey, function(_) return te2, p);
			case AKNo(_, np): throw new TypingError("This expression cannot be accessed for writing", np);
			case AKUsingAccessor(se):
				// Writing an abstract property calls the impl's set_<name>(this, value).
				var fa = se.access;
				var implC = FieldAccessTools.getHostClassRaise(fa.host);
				var setterCf = implC.statics.get("set_" + fa.field.name);
				// A write through an abstract's accessor takes a found accessor only; anything else is
				// "Could not resolve accessor" at the assignment (the READ is the one that falls to the
				// anon route).
				if (setterCf == null) throw new TypingError("Could not resolve accessor", p);
				{
					// The accessor keeps the abstract host so its signature gets the instance's type
					// parameters applied.
					var setterFa = FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(implC), fa.pos), setterCf, fa.host, false, fa.pos);
					hxc.typing.Calls.buildCall(ctx, AKUsingField({thisExpr: se.thisExpr, access: setterFa}), [e2], WithTypeTools.value, p);
				}
			case AKResolve(se, name):
				// `e.name = value` on an abstract with a resolve-write (@:op(a.b) taking name and value)
				// calls resolveWrite(this, name, value).
				if (se.access.field.kind.match(Method(MethMacro))) {
					var ce = FieldAccessTools.getFieldExpr(se.access, FCall);
					var sig = switch (TypeFunctions.follow(ce.type)) { case TFun(s) if (s.args.length >= 3): s; case _: throw new TypingError("Resolve target is not a function", se.access.pos); };
					var eName = new Expr(EConst(CString(name, SDoubleQuotes)), se.access.pos);
					var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.withType(sig.args[2].t));
					return hxc.eval.EvalMacro.run(ctx, se.access, [storedSyntax(ctx, se.thisExpr), eName, storedSyntax(ctx, te2)], WithTypeTools.value, se.access.pos);
				}
				var ce = FieldAccessTools.getFieldExpr(se.access, FCall);
				switch (TypeFunctions.follow(ce.type)) {
					case TFun(sig) if (sig.args.length >= 3):
						// The resolve name is built at Position.nullPos, so it contributes no source
						// mapping at all.
						var eName = TexprTools.makeString(ctx.com.basic, name, hxc.ast.Position.nullPos);
						var nameArg = Typer.castOrUnifyRaise(ctx, sig.args[1].t, eName, eName.pos);
						var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.withType(sig.args[2].t));
						// The cast is made at the argument's own position (e.pos), so an implicit @:from wrapper sits
						// on the value, not the assignment.
						var valArg = Typer.castOrUnifyRaise(ctx, sig.args[2].t, te2, te2.pos);
						hxc.typing.Calls.makeCall(ctx, ce, Calls.padPosInfos(ctx, sig.args, [se.thisExpr, nameArg, valArg], se.access.pos), sig.ret, se.access.pos);
					case _:
						throw new TypingError("Resolve target is not a function", se.access.pos);
				}
			case _: throw new TypingError("This assignment target is not yet ported", p);
		};
	}

	static function typeAssignOp(ctx:TyperContext, sub:Binop, e1:Expr, e2:Expr, withType:WithType, p:Position):TExpr {
		// mkAssign: every write this builds first casts the right side to the target type and then COMPACTS
		// back to a compound operator when the result is exactly `target op rhs`. The same closure covers
		// the assignment an abstract's @:op result needs as well as the plain one, so an abstract compound
		// does not stay expanded as `a = a + b`.
		function mkAssign(target:TExpr, eRhs:TExpr):TExpr {
			var eRhs = Typer.castOrUnify(ctx, target.type, eRhs, p);
			return switch (eRhs.expr) {
				case TBinop(op2, a, b) if (Type.enumEq(op2, sub) && TexprTools.equal(target, a)):
					TypeFunctions.mk(TBinop(OpAssignOp(op2), a, b), target.type, p);
				case _:
					TypeFunctions.mk(TBinop(OpAssign, target, eRhs), target.type, p);
			};
		}
		function compound(te1:TExpr):TExpr {
			var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
			// An abstract @:op compound assign is `a = a.op(b)` (the op dispatches to the impl method); a
			// native op stays as a compound TBinop the evaluator applies in place. The target is only
			// checked writable when the result actually reassigns: a dedicated @:op(A += B) overload is its
			// own assignment and is legal on a final.
			return switch (makeBinop(ctx, sub, te1, te2, true, withType, p)) {
				case BinopSpecial(opCall, true):
					// The overload's result goes to the assignment: checkAssign when it needs assigning, then the
					// target takes it. The callers stabilized the lvalue before the operator resolved, so the
					// overload is resolved - and its inline expanded - once.
					checkAssign(ctx, te1);
					mkAssign(te1, opCall);
				case BinopSpecial(opCall, false):
					// A dedicated @:op(A += B) overload is the assignment and returns its own result (often Void).
					opCall;
				case r:
					checkAssign(ctx, te1);
					// The binop result carries the typed operands (a string concatenation wraps a
					// non-string operand in Std.string), so the compound form reuses them; a right side
					// that no longer starts from the target falls back to a plain assignment.
					mkAssign(te1, toTexpr(r));
			};
		}
		// A property/accessor target `a.p op= b` evaluates the receiver once, reads via the getter, applies
		// the op, and writes via the setter.
		function accessorCompound(prop:hxc.typing.AccessKind.FieldAccess, recv:TExpr, host:hxc.typing.AccessKind.FieldHost, name:String, faPos:Position):TExpr {
			var implC = FieldAccessTools.getHostClassRaise(host);
			var getterCf = implC.statics.get("get_" + name);
			var setterCf = implC.statics.get("set_" + name);
			if (getterCf == null || setterCf == null) throw new TypingError("This compound assignment target is not yet ported", p);
			var tvoid = ctx.com.basic.tvoid;
			// The receiver stabilizes at depth 0, so an array-access receiver keeps its shape with
			// "base"/"index" binds and duplicates as an expression in the get and set calls.
			var recvVars:Array<TExpr> = [];
			var er = vrGetExprAux(ctx, recvVars, 0, "fh", recv);
			// The accessor field expression is built at the property's position.
			var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), faPos);
			// The accessor keeps the abstract host so its signature gets the instance's type parameters
			// applied.
			var getExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, getterCf, host, false, faPos), FCall);
			function retOfE(e:TExpr):T return switch (TypeFunctions.follow(e.type)) { case TFun(s): s.ret; case _: tvoid; };
			// The read goes through the getter and types the right side; the setter is resolved only when
			// the value is written.
			Calls.forceFieldType(getterCf);
			var readVal = Calls.accessorCallResult(prop, Calls.makeCall(ctx, getExpr, [er], retOfE(getExpr), p));
			var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
			var opResult = toTexpr(makeBinop(ctx, sub, readVal, te2, true, withType, p));
			Calls.forceFieldType(setterCf);
			var setExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, setterCf, host, false, faPos), FCall);
			Calls.checkModifiesThisDirect(ctx, implC, setterCf, recv, p);
			var setCall = Calls.accessorCallResult(prop, Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOfE(getExpr), opResult, p)], retOfE(setExpr), p));
			return vrToTexpr(recvVars, setCall);
		}
		// A class property `a.p op= b` evaluates the receiver once, reads via its read access (the getter
		// or
		// the stored field), applies the op, and writes via its write access.
		function accessorInstanceCompound(fa:hxc.typing.AccessKind.FieldAccess):TExpr {
			var recv = fa.on;
			var tvoid = ctx.com.basic.tvoid;
			// The receiver binds through the same value reference the increment path uses, with no exemption
			// for a stable lvalue: `c.next.x += 1` emits `var fh = c.next; fh.set_x(fh.get_x() + 1)`, not
			// `c.next.set_x(c.next.get_x() + 1)`, which would re-evaluate it once per accessor.
			var recvVars:Array<TExpr> = [];
			var er = vrGetExprAux(ctx, recvVars, 1, "fh", recv);
			var tmp = {expr: er, init: recvVars.length > 0 ? recvVars[0] : null};
			var readVal = accessorReadOn(ctx, er, fa);
			var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
			var br = makeBinop(ctx, sub, readVal, te2, true, withType, p);
			// A dedicated @:op(A += B) overload (needsAssign=false) mutates in place and needs no setter write;
			// a plain @:op(A + B) reused for `+=` writes the reassembled value back through the setter.
			var tail = switch (br) {
				case BinopSpecial(opCall, false): opCall;
				case _: accessorWriteOn(ctx, er, fa, toTexpr(br), p);
			};
			return tmp.init == null ? tail : TypeFunctions.mk(TBlock([tmp.init, tail]), tail.type, p);
		}
		// The target resolves with a write access so a (default, set) property dispatches through its
		// setter for the write half.
		return switch (Typer.typeAccess(ctx, e1.expr, e1.pos, MSet(e2), withType)) {
			// `a[k] op= v` on an abstract @:arrayAccess: the read access resolves first so the key carries
			// any getter coercion, then each operand binds to a gen temp only when it is not a constant
			// expression (a const key stays inline, keeping the element access foldable by constructor
			// inlining); the key declaration emits before the base one.
			case AKAccess(a, tl, c, ebase, ekey0):
				var tvoid = ctx.com.basic.tvoid;
				var probe = Calls.findArrayReadAccess(ctx, a, tl, c, ekey0, p);
				function maybeBind(e:TExpr):{e:TExpr, decl:Null<TExpr>} {
					var cst = hxc.optimization.Optimizer.makeConstantExpression(ctx, e);
					return if (cst != null) {e: cst, decl: null} else {
						var v = TypeFunctions.allocVar(VGenerated, "`", e.type, p);
						{e: TexprTools.makeLocal(v, p), decl: TypeFunctions.mk(TVarExpr(v, e), tvoid, p)};
					};
				}
				var bk = maybeBind(probe.key);
				var bb = maybeBind(ebase);
				var get = {expr: Calls.mkArrayGetCall(ctx, {cf: probe.cf, sig: probe.sig, key: bk.e}, c, bb.e, p), key: bk.e, cf: probe.cf};
				var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
				var eop = toTexpr(makeBinop(ctx, sub, get.expr, te2, true, withType, p));
				var setter:Null<TClassField> = null;
				var eset = Calls.arraySetValue(ctx, a, tl, c, bb.e, get.key, function(_) return eop, p, true, function(cf) setter = cf);
				// Getter and setter must be both bodied (calls) or both bodiless (a plain TArray on the
				// underlying value); one of each has no form to build.
				if (setter != null && ((setter.expr == null) != (get.cf.expr == null)))
					throw new TypingError("Invalid array access getter/setter combination", p);
				var block:Array<TExpr> = [];
				if (bk.decl != null) block.push(bk.decl);
				if (bb.decl != null) block.push(bb.decl);
				block.push(eset);
				block.length == 1 ? eset : TypeFunctions.mk(TBlock(block), eset.type, p);
			case AKExpr(te1):
				// The lvalue stabilizes through a value reference first: a depth-0 array access keeps its
				// shape binding "base"/"index", a field keeps "fh", anything else binds whole as "lhs"; the
				// binop and the write then reuse the stabilized shape.
				var vrVars:Array<TExpr> = [];
				var lv = vrGetExprAux(ctx, vrVars, 0, "lhs", te1);
				var out = compound(lv);
				vrToTexpr(vrVars, out);
			case AKNo(acc2, np):
				// A write-restricted target (a final field) still takes a compound op when the abstract
				// declares a dedicated overload that needs no write-back; the write error is deferred to
				// the needs-assign result.
				var te1 = switch (acc2) {
					case AKExpr(te): te;
					case AKField(fa) | AKAccessor(fa): FieldAccessTools.getFieldExpr(fa, FWrite);
					case _: throw new TypingError("This expression cannot be accessed for writing", np);
				};
				// The retry runs at the access kind's own position, not the compound's: AKNo's position
				// (the field's) replaces the outer p before the operator resolution is re-entered.
				var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
				// The retry searches abstract overloads only, so it SUCCEEDS with an overload or raises
				// NotFound - `false += 1` is a write error, not a `Cannot add Bool and Int`. An error out
				// of the overload it did pick (the inliner's write check) is not NotFound and goes on up. A
				// result that needs the write-back raises NotFound too.
				var retry = tryAbstractBinop(ctx, sub, te1, te2, true, withType, np);
				switch (retry) {
					case BinopSpecial(opCall, false): opCall;
					case _: throw new TypingError("This expression cannot be accessed for writing", np);
				}
			case AKField(fa):
				// A property with a call accessor on either side reads via its getter and writes via its
				// setter; a plain field binds its receiver part as "fh" and stays a raw compound.
				var accCall = switch (fa.field.kind) { case Var(k): k.read.match(AccCall) || k.write.match(AccCall); case _: false; };
				if (accCall) accessorInstanceCompound(fa) else {
					var recvVars:Array<TExpr> = [];
					var ef = vrGetExprAux(ctx, recvVars, 1, "fh", fa.on);
					var out = compound(FieldAccessTools.getFieldExpr({on: ef, field: fa.field, host: fa.host, isInline: fa.isInline, pos: fa.pos}, FWrite));
					vrToTexpr(recvVars, out);
				}
			case AKAccessor(fa): accessorInstanceCompound(fa);
			case AKUsingAccessor(se):
				accessorCompound(se.access, se.thisExpr, se.access.host, se.access.field.name, se.access.pos);
			case AKResolve(se, name):
				// Compound assign on a resolve field: resolveWrite(this, name, resolveRead(this, name) OP
				// value), evaluating the receiver once.
				var aw = switch (se.access.host) { case FHAbstract(a, tl, c): {a: a, tl: tl, c: c}; case _: null; };
				if (aw == null || aw.a.write == null)
					throw new TypingError("This compound assignment target is not yet ported", p);
				var basic = ctx.com.basic;
				// The receiver stabilizes through a value reference (a simple local binds nothing).
				var recvVars:Array<TExpr> = [];
				var recv = vrGetExprAux(ctx, recvVars, 0, "fh", se.thisExpr);
				if (aw.a.read == null)
					throw new TypingError("This compound assignment target is not yet ported", p);
				var readSe = FieldAccessTools.makeAbstractStaticExtensionAccess(aw.a, aw.tl, aw.c, aw.a.read, recv, false, p);
				var readCe = FieldAccessTools.getFieldExpr(readSe.access, FCall);
				var read = switch (TypeFunctions.follow(readCe.type)) {
					case TFun(rs) if (rs.args.length >= 2):
						var nm = TexprTools.makeString(basic, name, se.access.pos);
						Calls.makeCall(ctx, readCe, Calls.padPosInfos(ctx, rs.args, [recv, Typer.castOrUnify(ctx, rs.args[1].t, nm, nm.pos)], p), rs.ret, p);
					case _: throw new TypingError("Resolve target is not a function", se.access.pos);
				};
				var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
				switch (makeBinop(ctx, sub, read, te2, true, withType, p)) {
					case BinopSpecial(opCall, false):
						// A dedicated @:op(a -= b) overload is the assignment and returns its own result, so the
						// value is not written back through resolveWrite.
						vrToTexpr(recvVars, opCall);
					case br:
						var opResult = toTexpr(br);
						// The write call passes the ORIGINAL receiver, not the stabilized read; only the
						// read half reuses the bind.
						var writeSe = FieldAccessTools.makeAbstractStaticExtensionAccess(aw.a, aw.tl, aw.c, aw.a.write, se.thisExpr, false, p);
						var writeCe = FieldAccessTools.getFieldExpr(writeSe.access, FCall);
						var write = switch (TypeFunctions.follow(writeCe.type)) {
							case TFun(ws) if (ws.args.length >= 3):
								var nm2 = TexprTools.makeString(basic, name, p);
								se.access.field.kind.match(Method(MethMacro))
									? hxc.eval.EvalMacro.run(ctx, se.access, [Calls.typedExprToSyntax(ctx, se.thisExpr), new Expr(EConst(CString(name, SDoubleQuotes)), p), storedSyntax(ctx, opResult)], WithTypeTools.value, p)
									: Calls.makeCall(ctx, writeCe, Calls.padPosInfos(ctx, ws.args, [se.thisExpr, Typer.castOrUnify(ctx, ws.args[1].t, nm2, p), Typer.castOrUnify(ctx, ws.args[2].t, opResult, p)], p), ws.ret, p);
							case _: throw new TypingError("Resolve target is not a function", p);
						};
						vrToTexpr(recvVars, write);
				}
			case _:
				throw new TypingError("This compound assignment target is not yet ported", p);
		};
	}

	public static function typeUnop(ctx:TyperContext, op:Unop, flag:UnopFlag, e:Expr, withType:WithType, p:Position):TExpr {
		return switch (op) {
			case Spread:
				throw new TypingError("Spread unary operator is only allowed for unpacking the last argument in a call with rest arguments", p);
			case Increment | Decrement:
				switch (Typer.typeAccess(ctx, e.expr, e.pos, MSet(null), withType)) {
					case AKAccess(a, tl, c, ebase, ekey): arrayIncr(ctx, a, tl, c, op, flag, ebase, ekey, withType, p);
					case AKExpr(te):
						var abs = tryAbstractUnop(ctx, op, flag, te, p);
						// With no abstract overload, an increment/decrement checks the target is assignable
						// and only then that it is Int: `--"s"` is an Invalid assign, not a `String should
						// be Int`. The other access kinds never get here - a field re-resolves to a TField,
						// which checkAssign always allows, and an accessor writes through its setter.
						if (abs != null) abs else { checkAssign(ctx, te); makeUnop(ctx, op, flag, te, p); }
					case AKField(fa):
						var accCall = switch (fa.field.kind) { case Var(k): k.read.match(AccCall) || k.write.match(AccCall); case _: false; };
						if (accCall) accessorIncr(ctx, op, flag, fa, withType, p) else {
							// The receiver part binds as "fh" before the unop applies to the field.
							var recvVars:Array<TExpr> = [];
							var ef = vrGetExprAux(ctx, recvVars, 1, "fh", fa.on);
							var te = FieldAccessTools.getFieldExpr({on: ef, field: fa.field, host: fa.host, isInline: fa.isInline, pos: fa.pos}, FWrite);
							var abs = tryAbstractUnop(ctx, op, flag, te, p);
							var out = if (abs != null) abs else makeUnop(ctx, op, flag, te, p);
							vrToTexpr(recvVars, out);
						}
					case AKAccessor(fa): accessorIncr(ctx, op, flag, fa, withType, p);
					case AKUsingAccessor(se): usingAccessorIncr(ctx, op, flag, se, withType, p);
					case AKNo(acc2, np):
						// A dedicated abstract increment overload needs no write-back, so it applies to a
						// write-restricted target (a final field); anything else is a write error.
						var te = switch (acc2) {
							case AKExpr(te2): te2;
							case AKField(fa) | AKAccessor(fa): FieldAccessTools.getFieldExpr(fa, FWrite);
							case AKNo(_, _): Typer.typeExpr(ctx, e, WithTypeTools.value);
							case _: throw new TypingError("This expression cannot be accessed for writing", np);
						};
						var abs = tryAbstractUnop(ctx, op, flag, te, p);
						// There is no checkAssign on this path: an unwritable access either resolves through an
						// abstract overload or is a write error, whatever the operand looks like. Checking first
						// would report `Invalid assign` for `++null`.
						if (abs != null) abs else throw new TypingError("This expression cannot be accessed for writing", np);
					case _: throw new TypingError("This increment target is not yet ported", p);
				}
			case Not | Neg | NegBits:
				var te = Typer.typeExpr(ctx, e, WithTypeTools.value);
				var abs = tryAbstractUnop(ctx, op, flag, te, p);
				if (abs != null) abs else makeUnop(ctx, op, flag, te, p);
		};
	}

	// Increment/decrement of an abstract @:arrayAccess element via getter+setter.
	static function arrayIncr(ctx:TyperContext, a:TAbstract, tl:TParams, c:TClass, op:Unop, flag:UnopFlag, tb:TExpr, ekey:TExpr, withType:WithType, p:Position):TExpr {
		// Increment/decrement through @:arrayAccess: bind key and read value to "tmp" temps, apply the op
		// inline, write through @:arrayAccess; the block yields the set-call result for prefix and the read
		// temp for postfix. The base expression feeds both calls directly (no base temp is bound).
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var vKey = TypeFunctions.allocVar(VGenerated, "tmp", ekey.type, ekey.pos);
		var evarKey = TypeFunctions.mk(TVarExpr(vKey, ekey), tvoid, ekey.pos);
		var ekeyL = TexprTools.makeLocal(vKey, ekey.pos);
		var get = Calls.abstractArrayGet(ctx, a, tl, c, tb, ekeyL, p);
		var eGet = get.expr;
		var vGet = TypeFunctions.allocVar(VGenerated, "tmp", eGet.type, eGet.pos);
		var evGet = TexprTools.makeLocal(vGet, p);
		var evarGet = TypeFunctions.mk(TVarExpr(vGet, eGet), tvoid, p);
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		var eOp = TypeFunctions.mk(TBinop(op.match(Increment) ? OpAdd : OpSub, evGet, one), evGet.type, p);
		var eSet = Calls.arraySetValue(ctx, a, tl, c, tb, ekeyL, function(_) return eOp, p, false);
		if (eSet == null) {
			// NotFound: the read is made again with the ORIGINAL key, and the operator goes to the
			// overload-or-make path - an @:op(A++) on the value, else the plain unop.
			var e = Calls.abstractArrayGet(ctx, a, tl, c, tb, ekey, p).expr;
			var abs = tryAbstractUnop(ctx, op, flag, e, p);
			if (abs != null) return abs;
			checkAssign(ctx, e);
			return makeUnop(ctx, op, flag, e, p);
		}
		var el = [evarKey, evarGet, eSet].concat(flag.match(Postfix) ? [evGet] : []);
		// The whole block is typed as the setter result (the @:arrayAccess element type) for both prefix
		// and postfix; a postfix read temp yields the old value cast to that type at the use site, not
		// the nullable getter result type.
		return TypeFunctions.mk(TBlock(el), eSet.type, p);
	}

	// The callee must keep the property's own position. hxc resolves the accessor by name, and the
	// name slice is then derived from the ACCESSOR's name length (four characters longer than the
	// property's), which starts the callee before its own receiver and adds a source map segment. Put
	// the callee back on the property position.
	static function atFieldPos(e:TExpr, p:Position):TExpr {
		return switch (e.expr) {
			case TField(_, _): TypeFunctions.mk(e.expr, e.type, p);
			case _: e;
		};
	}

	// Read a class property `er.p`: call its getter when the read accessor is AccCall, else read the stored
	// field.
	static function accessorReadOn(ctx:TyperContext, er:TExpr, fa:hxc.typing.AccessKind.FieldAccess):TExpr {
		var name = fa.field.name;
		var isCall = switch (fa.field.kind) { case Var(k): k.read.match(AccCall); case _: false; };
		if (isCall) {
			// An anonymous-structure host has no accessor field: synthesize a dynamic get_<name>() call
			// resolved on the runtime object.
			if (fa.host.match(FHAnon)) {
				var t = fa.field.type;
				var tf = TFun({args: [], ret: t});
				return Calls.makeCall(ctx, TypeFunctions.mk(TField(er, TypeFunctions.quickFieldDynamic(er.type, "get_" + name)), tf, fa.pos), [], t, fa.pos);
			}
			// The property access already governs visibility; the getter dispatch is internal and must not
			// re-check the (usually private) accessor's own visibility.
			ctx.privateAccess++;
			var gAcc = hxc.typing.Fields.typeField(ctx, er, "get_" + name, fa.pos, MCall([]), WithTypeTools.value, true, true);
			ctx.privateAccess--;
			var call = Calls.buildCall(ctx, gAcc, [], WithTypeTools.value, fa.pos);
			return Calls.accessorCallResult(fa, switch (call.expr) {
				case TCall(callee, args): TypeFunctions.mk(TCall(atFieldPos(callee, fa.pos), args), call.type, call.pos);
				case _: call;
			});
		}
		var faOn = FieldAccessTools.create(er, fa.field, fa.host, false, fa.pos);
		return FieldAccessTools.getFieldExpr(faOn, FRead);
	}

	// Write `er.p = value`: call its setter when the write accessor is AccCall, else assign the stored
	// field.
	static function accessorWriteOn(ctx:TyperContext, er:TExpr, fa:hxc.typing.AccessKind.FieldAccess, value:TExpr, p:Position):TExpr {
		var name = fa.field.name;
		var isCall = switch (fa.field.kind) { case Var(k): k.write.match(AccCall); case _: false; };
		if (isCall) {
			// An anonymous-structure host has no accessor field: synthesize a dynamic set_<name>(v) call
			// resolved on the runtime object.
			if (fa.host.match(FHAnon)) {
				var t = fa.field.type;
				var tf = TFun({args: [{name: "value", opt: false, t: value.type}], ret: t});
				return Calls.makeCall(ctx, TypeFunctions.mk(TField(er, TypeFunctions.quickFieldDynamic(er.type, "set_" + name)), tf, p), [value], t, p);
			}
			// See accessorReadOn: the setter dispatch is internal, so bypass the accessor's
			// own visibility check (the property access already governed it).
			ctx.privateAccess++;
			// The accessor is CALLED as a field, exactly as the getter above is. Resolving it with MGet and
			// then calling the resulting expression would make it a closure over the setter, which GenJS
			// prints as `$bind(c,c.set_x)(...)` instead of `c.set_x(...)`.
			var sAcc = hxc.typing.Fields.typeField(ctx, er, "set_" + name, fa.pos, MCall([]),
				WithTypeTools.value, true, true);
			ctx.privateAccess--;
			// accGet on a method access yields a CLOSURE over it, which GenJS prints as
			// `$bind(c,c.set_x)`. Take the field expression with the call flavour instead.
			var setterExpr = switch (sAcc) {
				case AKField(sfa) | AKAccessor(sfa):
					Calls.forceFieldType(sfa.field);
					FieldAccessTools.getFieldExpr(sfa, FCall);
				case _: Typer.accGet(ctx, sAcc);
			};
			return Calls.accessorCallResult(fa, Calls.makeCall(ctx, atFieldPos(setterExpr, fa.pos),
				[Typer.castOrUnify(ctx, value.type, value, p)], value.type, p));
		}
		var faOn = FieldAccessTools.create(er, fa.field, fa.host, false, fa.pos);
		var target = FieldAccessTools.getFieldExpr(faOn, FWrite);
		return TypeFunctions.mk(TBinop(OpAssign, target, Typer.castOrUnify(ctx, target.type, value, p)), target.type, p);
	}

	// Increment/decrement of an abstract property (get,set) via its static impl accessors, passing the
	// abstract value as this.
	static function usingAccessorIncr(ctx:TyperContext, op:Unop, flag:UnopFlag, se:hxc.typing.AccessKind.StaticExtensionAccess, withType:WithType, p:Position):TExpr {
		var fa = se.access;
		var implC = FieldAccessTools.getHostClassRaise(fa.host);
		var name = fa.field.name;
		var getterCf = implC.statics.get("get_" + name);
		var setterCf = implC.statics.get("set_" + name);
		if (getterCf == null || setterCf == null) throw new TypingError("This increment target is not yet ported", p);
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var recv = se.thisExpr;
		// The lhs is processed as a value reference "fh": a field or array access keeps its shape with only
		// the non-simple PARTS bound; the processed expression feeds both the getter and the setter
		// dispatch.
		var recvVars:Array<TExpr> = [];
		var er = vrGetExprAux(ctx, recvVars, 0, "fh", recv);
		// The accessor field expression is built at `fa.pos`, the property's own position, not at the
		// enclosing operator's, so the generated accessor call sits on `c.v` and not on the `++`.
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), fa.pos);
		// The accessor keeps the abstract host so its signature gets the instance's type parameters
		// applied.
		var getExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, getterCf, fa.host, false, fa.pos), FCall);
		var setExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, setterCf, fa.host, false, fa.pos), FCall);
		function retOfE(e:TExpr):T return switch (TypeFunctions.follow(e.type)) { case TFun(s): s.ret; case _: tvoid; };
		function retOf(cf:TClassField):T return retOfE(cf == getterCf ? getExpr : setExpr);
		Calls.forceFieldType(getterCf);
		var readVal = Calls.accessorCallResult(fa, Calls.makeCall(ctx, getExpr, [er], retOf(getterCf), p));
		var binop = op.match(Increment) ? OpAdd : OpSub;
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		// As with a class property, the setter call is the value; only a postfix used as a value needs the
		// old value in a postfix temp.
		var stmts = recvVars;
		if (flag.match(Postfix) && !withType.match(NoValue)) {
			// Postfix temp: the read passes through the value reference "lhs" (binding a complex read
			// whole, or just its receiver part as "fh"), the postfix temp captures it, and the written
			// value reuses that processed read expression rather than the postfix temp.
			var eLhs = vrGetExprAux(ctx, stmts, 0, "lhs", readVal);
			var vpost = TypeFunctions.allocVar(VGenerated, "postfix", eLhs.type, p);
			var epost = TexprTools.makeLocal(vpost, p);
			stmts.push(TypeFunctions.mk(TVarExpr(vpost, eLhs), tvoid, p));
			var newv = toTexpr(makeBinop(ctx, binop, eLhs, one, false, withType, p));
			Calls.forceFieldType(setterCf);
			stmts.push(Calls.accessorCallResult(fa, Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOf(getterCf), newv, p)], retOf(setterCf), p)));
			stmts.push(epost);
			return TypeFunctions.mk(TBlock(stmts), epost.type, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, readVal, one, false, withType, p));
		Calls.forceFieldType(setterCf);
		var setCall = Calls.accessorCallResult(fa, Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOf(getterCf), newv, p)], retOf(setterCf), p));
		if (stmts.length == 0) return setCall;
		stmts.push(setCall);
		// The receiver-temp block is wrapped in a :mergeBlock meta so the analyzer merges it flat instead
		// of emitting a nested block.
		var block = TypeFunctions.mk(TBlock(stmts), setCall.type, p);
		return TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: Position.nullPos}, block), block.type, p);
	}

	// Increment/decrement of a class property via its accessors: read once, apply +/-1, write back; postfix
	// yields the old value, prefix the new.
	static function accessorIncr(ctx:TyperContext, op:Unop, flag:UnopFlag, fa:hxc.typing.AccessKind.FieldAccess, withType:WithType, p:Position):TExpr {
		var recv = fa.on;
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var binop = op.match(Increment) ? OpAdd : OpSub;
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		// Increment/decrement: bind the receiver to fh only when it is not a plain local/const; the
		// setter call is itself the value, so prefix and value-discarded forms need no extra temp; a
		// postfix used as a value binds the old value to postfix. The receiver binds at depth 1: the temp
		// is allocated at the bound EXPRESSION's position and declared at `v.pos`, so the declaration
		// sits on the receiver, not on the operator.
		var recvVars:Array<TExpr> = [];
		var er = vrGetExprAux(ctx, recvVars, 1, "fh", recv);
		var recvInit:Null<TExpr> = recvVars.length > 0 ? recvVars[0] : null;
		var readVal = accessorReadOn(ctx, er, fa);
		if (flag.match(Postfix) && !withType.match(NoValue)) {
			// Postfix temp: a complex read binds as "lhs" first, the postfix temp captures it, and the
			// written value reuses the read expression rather than the postfix temp.
			var stmts:Array<TExpr> = [];
			if (recvInit != null) stmts.push(recvInit);
			var eLhs = vrGetExprAux(ctx, stmts, 0, "lhs", readVal);
			var vpost = TypeFunctions.allocVar(VGenerated, "postfix", eLhs.type, p);
			var epost = TexprTools.makeLocal(vpost, p);
			stmts.push(TypeFunctions.mk(TVarExpr(vpost, eLhs), tvoid, p));
			var newv = toTexpr(makeBinop(ctx, binop, eLhs, one, false, withType, p));
			stmts.push(accessorWriteOn(ctx, er, fa, newv, p));
			stmts.push(epost);
			return TypeFunctions.mk(TBlock(stmts), epost.type, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, readVal, one, false, withType, p));
		var setCall = accessorWriteOn(ctx, er, fa, newv, p);
		// The receiver-temp block is wrapped in a :mergeBlock meta, so the analyzer merges it into the
		// enclosing scope instead of emitting a nested block.
		if (recvInit == null) return setCall;
		var block = TypeFunctions.mk(TBlock([recvInit, setCall]), setCall.type, p);
		return TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: Position.nullPos}, block), block.type, p);
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
					// Only an @:op with no body is the plain unop. One whose body a display request leaves untyped
					// still has an expression there - an @:op field is given a stand-in body because its presence
					// matters - so it is called like any other.
					if (au.cf.expr == null && !hxc.typing.TypeFields.fieldHasSyntaxBody(ctx.com, a.impl, au.cf))
						return TypeFunctions.mk(TUnop(op, flag, e), ret, p);
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
			case Increment | Decrement:
				// checkAssign runs at the caller; here only checkInt.
				checkInt();
			case Spread:
				throw new TypingError("Unexpected unary operator in makeUnop", p);
		};
		return TypeFunctions.mk(TUnop(op, flag, e), t, p);
	}
}
