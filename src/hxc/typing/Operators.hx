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

class Operators {
	static function unify(ctx:TyperContext, a:T, b:T, p:Position):Void {
		DebugDump.unify("operator", a, b, p);
		try {
			TypeUnification.unifyDefault(a, b);
		} catch (e:UnifyError) {
			throw new TypingError(hxc.core.TPrinting.betterErrorMessage(e.errors), p);
		}
	}

	static function checkAssign(ctx:TyperContext, e:TExpr):Void {
		switch (e.expr) {
			case TLocal(v) if (TypeFunctions.hasVarFlag(v, VFinal) && !ctx.untypedMode):
				throw new TypingError("Cannot assign to final", e.pos);
			case TLocal(v) if (v.extra == null):
			case TField(ef, FInstance(_, _, cf)) if (!ctx.untypedMode):
				switch (cf.kind) {
					case Var({write: AccNever}) if (!isConstructorThisField(ctx, ef)):
						throw new TypingError("This expression cannot be accessed for writing", e.pos);
					case _:
				}
			case TField(_, FStatic(_, cf) | FAnon(cf)) if (!ctx.untypedMode):
				switch (cf.kind) {
					case Var({write: AccNever}):
						throw new TypingError("This expression cannot be accessed for writing", e.pos);
					case _:
				}
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
			function gen(x:TExpr):TExpr {
				// Ignore the visibility of toString.
				ctx.privateAccess++;
				var accS = hxc.typing.Fields.typeField(ctx, x, "toString", x.pos, MCall([]), WithTypeTools.withType(tstring));
				ctx.privateAccess--;
				return hxc.typing.Calls.buildCall(ctx, accS, [], WithTypeTools.withType(tstring), x.pos);
			}
			// A static-platform non-nullable operand never takes the null branch, and the `e == null` check
			// below would type a null at the operand's non-nullable basic type, which trips the static-null
			// check. this path with the same isStatic test.
			if (ctx.com.platformConfig.isStatic && !TypeFunctions.isNullable(e.type))
				return gen(e);
			var strNull = TypeFunctions.mk(TConst(TString("null")), tstring, e.pos);
			if (!hxc.typing.Calls.needsTempVar(e)) {
				var check = TypeFunctions.mk(TBinop(OpEq, e, TexprTools.makeNull(e.type, e.pos)), ctx.com.basic.tbool, e.pos);
				return TypeFunctions.mk(TIf(check, strNull, gen(e)), tstring, e.pos);
			}
			var tmp = TypeFunctions.allocVar(VGenerated, "tmp", e.type, e.pos);
			var tmpLocal = TexprTools.makeLocal(tmp, e.pos);
			var check = TypeFunctions.mk(TBinop(OpEq, tmpLocal, TexprTools.makeNull(e.type, e.pos)), ctx.com.basic.tbool, e.pos);
			var iff = TypeFunctions.mk(TIf(check, strNull, gen(tmpLocal)), tstring, e.pos);
			var decl = TypeFunctions.mk(TVarExpr(tmp, e), ctx.com.basic.tvoid, e.pos);
			return TypeFunctions.mk(TBlock([decl, iff]), tstring, e.pos);
		}
		// Wrap `e` in a Std.string(e) call: any non-primitive, non-abstract operand of a string
		// concatenation is stringified through Std.string so it gets Haxe semantics (an Array prints as
		// [a,b,c], not the native comma-join).
		function stdString(e:TExpr):TExpr {
			var std = try ctx.com.getType({pack: [], name: "Std"}, p, null) catch (_:Dynamic) null;
			switch (std) {
				case TClassDecl(c):
					var cf = c.statics.get("string");
					if (cf == null) return e;
					hxc.typing.TypeFields.forceFieldBody(ctx.com, c, cf);
					var stdExpr = TexprTools.makeTypeExpr(TClassDecl(c), e.pos);
					var acc = hxc.typing.Fields.fieldAccess(ctx, MCall([]), cf, FHStatic(c), stdExpr, e.pos);
					var callee = Typer.accGet(ctx, acc);
					return hxc.typing.Calls.makeCall(ctx, callee, [e], tstring, e.pos);
				case _: return e;
			}
		}
		function toString(e:TExpr):TExpr {
			// An abstract operand in a string concatenation whose impl defines toString is converted by
			// calling it (null-checked); other operands are stringified by the runtime.
			return switch (classify(e.type)) {
				case KAbstract(a, _) if (a.impl != null && a.impl.statics.exists("toString")):
					callToString(e);
				case KInt | KFloat | KString: e;
				case KUnk | KDyn | KNumParam(_) | KStrParam(_) | KOther:
					// A non-primitive operand (Array, an enum, an anon, ...) stringifies through
					// Std.string, not the target's native coercion.
					stdString(e);
				case KAbstract(_, _):
					// An abstract with no toString is converted to String by its @:to String cast when it
					// has one; otherwise it stringifies as its underlying value.
					try Typer.castOrUnify(ctx, tstring, e, p) catch (_:Dynamic) e;
			};
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
				var c1 = e1, c2 = e2;
				try unify(ctx, c1.type, c2.type, p) catch (_:TypingError) {
					try unify(ctx, c2.type, c1.type, p) catch (_:TypingError) {
						// Neither operand unifies directly: follow an abstract @:to/@:from cast so an
						// abstract compares against its underlying type (plain unify does not chase method
						// casts). .
						try c1 = Typer.castOrUnify(ctx, c2.type, c1, c1.pos) catch (_:TypingError) c2 = Typer.castOrUnify(ctx, c1.type, c2, c2.pos);
					}
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
				throw new TypingError("The range operator (...) is not yet ported", p);
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
	static function makeStaticOpCall(ctx:TyperContext, implC:TClass, cf:TClassField, args:Array<TExpr>, tret:T, p:Position):TExpr {
		var implExpr = hxc.core.TexprTools.makeStaticThis(implC, p);
		var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p), FCall);
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
		return try {
			switch (TypeFunctions.follow(e1.type)) {
				case TAbstract(a, tl) if (a.impl != null): findAbstractBinop(ctx, op, e1, e2, a, a.impl, tl, true, isAssignOp, withType, p);
				case _: throw new NotFound();
			}
		} catch (_:NotFound) {
			try {
				switch (TypeFunctions.follow(e2.type)) {
					case TAbstract(a, tl) if (a.impl != null): findAbstractBinop(ctx, op, e1, e2, a, a.impl, tl, false, isAssignOp, withType, p);
					case _: null;
				}
			} catch (_:NotFound) null;
		}
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
					var tExpected = switch (makeBinop(ctx, opCf, u1, u2, isAssignOp, withType, p)) {
						case BinopNormal(_, _, _, t, _, _, _): t;
						case BinopSpecial(e, _): e.type;
					};
					try TypeUnification.unifyDefault(tret, tExpected) catch (_:UnifyError) {
						switch (TypeFunctions.follow(tret)) {
							case TAbstract(ra, rtl) if (TypeUnification.typeIseqDefault(TypeFunctions.getUnderlyingType(ra, rtl), tExpected)):
							case _:
								throw new TypingError("The result of this operation (" + hxc.core.TPrinting.sTypeStr(tExpected) + ") is not compatible with declared return type " + hxc.core.TPrinting.sTypeStr(tret), p);
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
					var tvoid = ctx.com.basic.tvoid;
					var vlhs = TypeFunctions.allocVar(VGenerated, "lhs", me2.type, me2.pos);
					var vrhs = TypeFunctions.allocVar(VGenerated, "rhs", me1.type, me1.pos);
					var elhs = TexprTools.makeLocal(vlhs, me2.pos);
					var erhs = TexprTools.makeLocal(vrhs, me1.pos);
					var e = TypeFunctions.mk(TBlock([
						TypeFunctions.mk(TVarExpr(vlhs, me2), tvoid, me2.pos),
						TypeFunctions.mk(TVarExpr(vrhs, me1), tvoid, me1.pos),
						TypeFunctions.mk(TBinop(op, erhs, elhs), tret, p)
					]), tret, p);
					return BinopSpecial(e, isAssignOp);
				}
				return BinopSpecial(TypeFunctions.mk(TBinop(op, me1, me2), tret, p), isAssignOp);
			} else if (swapped) {
				// Preserve evaluation order after the commutative swap by binding both operands to temps.
				var tvoid = ctx.com.basic.tvoid;
				var vlhs = TypeFunctions.allocVar(VGenerated, "lhs", me2.type, me2.pos);
				var vrhs = TypeFunctions.allocVar(VGenerated, "rhs", me1.type, me1.pos);
				var elhs = TexprTools.makeLocal(vlhs, me2.pos);
				var erhs = TexprTools.makeLocal(vrhs, me1.pos);
				var call = makeStaticOpCall(ctx, implC, cf, [erhs, elhs], tret, p);
				var e = TypeFunctions.mk(TBlock([
					TypeFunctions.mk(TVarExpr(vlhs, me2), tvoid, me2.pos),
					TypeFunctions.mk(TVarExpr(vrhs, me1), tvoid, me1.pos),
					call
				]), tret, p);
				return BinopSpecial(e, needsAssign);
			} else {
				return BinopSpecial(makeStaticOpCall(ctx, implC, cf, [me1, me2], tret, p), needsAssign);
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
								var monos = [for (_ in cf.params) TypeFunctions.mkMono()];
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
									re2 = Typer.castOrUnify(ctx, t2, ce2, p);
								} else {
									TypeUnification.typeEqKind(EqStrict, ce2.type, t2);
									re1 = Typer.castOrUnify(ctx, t1, ce1, p);
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
						// Try direct order, then the commutative-swapped order. A failed probe (Unify_error or a
						// typing error from the cast) moves on; the mono rollback inside check has already
						// undone any speculative binding.
						try {
							return check(e1, e2, false);
						} catch (_:UnifyError) {
						} catch (_:TypingError) {
						}
						if (TypeFunctions.hasMeta(":commutative", cf.meta)) {
							try {
								return check(e2, e1, true);
							} catch (_:UnifyError) {
							} catch (_:TypingError) {
							}
						}
					case _:
				}
			}
			throw new NotFound();
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
			case TConst(TNull) if (!TypeFunctions.isExplicitNull(t)): throw new UnifyError([]);
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
			case OpInterval:
				var tp:PlacedTypePath = {path: {tpackage: [], tname: "IntIterator", tparams: [], tsub: null}, pos: p};
				Typer.typeNew(ctx, tp, [e1, e2], withType, p);
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
				TypeFunctions.mk(TBlock([decl, iff]), t, p);
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

	static function assignTo(ctx:TyperContext, te1:TExpr, e2:Expr, p:Position):TExpr {
		var te2 = Typer.castOrUnify(ctx, te1.type, Typer.typeExpr(ctx, e2, WithTypeTools.withType(te1.type)), p);
		checkAssign(ctx, te1);
		if (isSameAssignTarget(te1, te2)) throw new TypingError("Assigning a value to itself", p);
		return TypeFunctions.mk(TBinop(OpAssign, te1, te2), te1.type, p);
	}

	static function maybeTempReceiver(ctx:TyperContext, recv:TExpr, p:Position):{expr:TExpr, init:Null<TExpr>} {
		// A stable side-effect-free lvalue stays as-is so an inline setter assigning `this` writes
		// back through the original storage (a static field, array element or field chain).
		return if (Inline.isStableLvalue(recv)) {expr: recv, init: null} else switch (recv.expr) {
			case _:
				var v = TypeFunctions.allocVar(VGenerated, "fh", recv.type, p);
				{expr: TexprTools.makeLocal(v, p), init: TypeFunctions.mk(TVarExpr(v, recv), ctx.com.basic.tvoid, p)};
		}
	}

	static function typeAssign(ctx:TyperContext, e1:Expr, e2:Expr, withType:WithType, p:Position):TExpr {
		// A concrete map write `m[k] = v` lowers to m.set(k, v), yielding v. Map operations stay on the
		// concrete impl (which has get/set); the @:arrayAccess proper lives on the Map abstract.
		switch (e1.expr) {
			case EArray(baseE, keyE):
				var tb = Typer.typeExpr(ctx, baseE, WithTypeTools.value);
				var kv = switch (TypeFunctions.follow(tb.type)) { case TInst(c, tl): Calls.imapKV(c, tl); case _: null; };
				if (kv != null) {
					var tvoid = ctx.com.basic.tvoid;
					var tk = Typer.castOrUnify(ctx, kv.k, Typer.typeExpr(ctx, keyE, WithTypeTools.value), keyE.pos);
					var tv = Typer.castOrUnify(ctx, kv.v, Typer.typeExpr(ctx, e2, WithTypeTools.withType(kv.v)), p);
					var vb = TypeFunctions.allocVar(VGenerated, "`", tb.type, p);
					var vk = TypeFunctions.allocVar(VGenerated, "`", tk.type, p);
					var vv = TypeFunctions.allocVar(VGenerated, "`", tv.type, p);
					var eb = TexprTools.makeLocal(vb, p);
					var ek = TexprTools.makeLocal(vk, p);
					var ev = TexprTools.makeLocal(vv, p);
					var setExpr = Typer.accGet(ctx, hxc.typing.Fields.typeField(ctx, eb, "set", p, MGet, WithTypeTools.value));
					var setCall = Calls.makeCall(ctx, setExpr, [ek, ev], tvoid, p);
					return TypeFunctions.mk(TBlock([
						TypeFunctions.mk(TVarExpr(vb, tb), tvoid, p),
						TypeFunctions.mk(TVarExpr(vk, tk), tvoid, p),
						TypeFunctions.mk(TVarExpr(vv, tv), tvoid, p),
						setCall,
						ev
					]), tv.type, p);
				}
			case _:
		}
		return switch (Typer.typeAccess(ctx, e1.expr, e1.pos, MSet(e2), withType)) {
			case AKExpr(te1): assignTo(ctx, te1, e2, p);
			case AKField(fa): assignTo(ctx, FieldAccessTools.getFieldExpr(fa, FWrite), e2, p);
			case AKAccessor(fa):
				switch (FieldAccessTools.resolveAccessor(fa, MSet(e2))) {
					case AccessorFound(setterFa):
						hxc.typing.Calls.buildCall(ctx, AKField(setterFa), [e2], WithTypeTools.value, p);
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
				hxc.typing.Calls.arraySet(ctx, a, tl, c, ebase, ekey, e2, p);
			case AKNo(_, np): throw new TypingError("This expression cannot be accessed for writing", np);
			case AKUsingAccessor(se):
				// Writing an abstract property calls the impl's set_<name>(this, value).
				var fa = se.access;
				var implC = FieldAccessTools.getHostClassRaise(fa.host);
				var setterCf = implC.statics.get("set_" + fa.field.name);
				if (setterCf == null) throw new TypingError("This expression cannot be accessed for writing", p);
				// The accessor keeps the abstract host so its signature gets the instance's type parameters
				// applied.
				var setterFa = FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(implC), fa.pos), setterCf, fa.host, false, fa.pos);
				hxc.typing.Calls.buildCall(ctx, AKUsingField({thisExpr: se.thisExpr, access: setterFa}), [e2], WithTypeTools.value, p);
			case AKResolve(se, name):
				// `e.name = value` on an abstract with a resolve-write (@:op(a.b) taking name and value)
				// calls resolveWrite(this, name, value).
				var ce = FieldAccessTools.getFieldExpr(se.access, FCall);
				switch (TypeFunctions.follow(ce.type)) {
					case TFun(sig) if (sig.args.length >= 3):
						var eName = TexprTools.makeString(ctx.com.basic, name, se.access.pos);
						var nameArg = Typer.castOrUnify(ctx, sig.args[1].t, eName, eName.pos);
						var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.withType(sig.args[2].t));
						var valArg = Typer.castOrUnify(ctx, sig.args[2].t, te2, p);
						hxc.typing.Calls.makeCall(ctx, ce, Calls.padPosInfos(ctx, sig.args, [se.thisExpr, nameArg, valArg], se.access.pos), sig.ret, se.access.pos);
					case _:
						throw new TypingError("Resolve target is not a function", se.access.pos);
				}
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
						var vb = TypeFunctions.allocVar(VGenerated, "`", tb.type, p);
						var vk = TypeFunctions.allocVar(VGenerated, "`", tk.type, p);
						var eb = TexprTools.makeLocal(vb, p);
						var ek = TexprTools.makeLocal(vk, p);
						var get = Calls.abstractArrayGet(ctx, a, tl, a.impl, eb, ek, p);
						var keyInit:Null<TExpr> = null;
						switch (get.key.expr) {
							case TLocal(v) if (v == vk):
							case _:
								var vkc = TypeFunctions.allocVar(VGenerated, "`", get.key.type, p);
								keyInit = TypeFunctions.mk(TVarExpr(vkc, get.key), tvoid, p);
								get = Calls.abstractArrayGet(ctx, a, tl, a.impl, eb, TexprTools.makeLocal(vkc, p), p);
						}
						var eget = get.expr;
						var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
						var eop = toTexpr(makeBinop(ctx, sub, eget, te2, true, withType, p));
						var eset = Calls.arraySetValue(ctx, a, tl, a.impl, eb, get.key, function(_) return eop, p);
						var block = [
							TypeFunctions.mk(TVarExpr(vb, tb), tvoid, p),
							TypeFunctions.mk(TVarExpr(vk, tk), tvoid, p)
						];
						if (keyInit != null) block.push(keyInit);
						block.push(eset);
						return TypeFunctions.mk(TBlock(block), eset.type, p);
					case _:
				}
			case _:
		}
		// Bind the side-effecting parts of an lvalue (an array base/key, a field receiver) to temps so the
		// lvalue can be read and written without re-evaluating them.
		function stabilizeLvalue(te1:TExpr):{init:Array<TExpr>, lv:TExpr} {
			var tvoid = ctx.com.basic.tvoid;
			var init:Array<TExpr> = [];
			// A value_reference names the bound part after its position: a field host is fh, an array base
			// and index are base and index.
			function temp(e:TExpr, name:String):TExpr {
				return switch (e.expr) {
					case TLocal(_) | TConst(_) | TTypeExpr(_): e;
					case _:
						var v = TypeFunctions.allocVar(VGenerated, name, e.type, e.pos);
						init.push(TypeFunctions.mk(TVarExpr(v, e), tvoid, e.pos));
						TexprTools.makeLocal(v, e.pos);
				};
			}
			var lv = switch (te1.expr) {
				case TArray(base, key): TypeFunctions.mk(TArray(temp(base, "base"), temp(key, "index")), te1.type, te1.pos);
				case TField(recv, fa): TypeFunctions.mk(TField(temp(recv, "fh"), fa), te1.type, te1.pos);
				case _: te1;
			};
			return {init: init, lv: lv};
		}
		function compound(te1:TExpr):TExpr {
			var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
			// An abstract @:op compound assign is `a = a.op(b)` (the op dispatches to the impl method); a
			// native op stays as a compound TBinop the evaluator applies in place. The target is only
			// checked writable when the result actually reassigns: a dedicated @:op(A += B) overload is its
			// own assignment and is legal on a final.
			return switch (makeBinop(ctx, sub, te1, te2, true, withType, p)) {
				case BinopSpecial(_, true):
					checkAssign(ctx, te1);
					// A plain @:op(A + B) reused for `+=` reassigns `a = a.op(b)`, which names the target twice;
					// bind its side-effecting parts to temps and re-dispatch so it is evaluated once.
					var st = stabilizeLvalue(te1);
					var opCall = switch (makeBinop(ctx, sub, st.lv, te2, true, withType, p)) {
						case BinopSpecial(oc, _): oc;
						case r: toTexpr(r);
					};
					var assign = TypeFunctions.mk(TBinop(OpAssign, st.lv, Typer.castOrUnify(ctx, st.lv.type, opCall, p)), st.lv.type, p);
					st.init.length == 0 ? assign : TypeFunctions.mk(TBlock(st.init.concat([assign])), assign.type, p);
				case BinopSpecial(opCall, false):
					// A dedicated @:op(A += B) overload is the assignment and returns its own result (often Void).
					opCall;
				case r:
					checkAssign(ctx, te1);
					// The binop result carries the typed operands (a string concatenation wraps a
					// non-string operand in Std.string), so the compound form reuses them; a right side
					// that no longer starts from the target falls back to a plain assignment.
					var eRhs = Typer.castOrUnify(ctx, te1.type, toTexpr(r), p);
					switch (eRhs.expr) {
						case TBinop(op2, a, b) if (Type.enumEq(op2, sub) && TexprTools.equal(te1, a)):
							TypeFunctions.mk(TBinop(OpAssignOp(op2), a, b), te1.type, p);
						case _:
							TypeFunctions.mk(TBinop(OpAssign, te1, eRhs), te1.type, p);
					}
			};
		}
		// A property/accessor target `a.p op= b` evaluates the receiver once, reads via the getter, applies
		// the op, and writes via the setter.
		function accessorCompound(recv:TExpr, host:hxc.typing.AccessKind.FieldHost, name:String):TExpr {
			var implC = FieldAccessTools.getHostClassRaise(host);
			var getterCf = implC.statics.get("get_" + name);
			var setterCf = implC.statics.get("set_" + name);
			if (getterCf == null || setterCf == null) throw new TypingError("This compound assignment target is not yet ported", p);
			var tvoid = ctx.com.basic.tvoid;
			var tmp = maybeTempReceiver(ctx, recv, p);
			var er = tmp.expr;
			var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), p);
			// The accessor keeps the abstract host so its signature gets the instance's type parameters
			// applied.
			var getExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, getterCf, host, false, p), FCall);
			var setExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, setterCf, host, false, p), FCall);
			function retOfE(e:TExpr):T return switch (TypeFunctions.follow(e.type)) { case TFun(s): s.ret; case _: tvoid; };
			function retOf(cf:TClassField):T return retOfE(cf == getterCf ? getExpr : setExpr);
			var readVal = Calls.makeCall(ctx, getExpr, [er], retOf(getterCf), p);
			var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
			var opResult = toTexpr(makeBinop(ctx, sub, readVal, te2, true, withType, p));
			var setCall = Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOf(getterCf), opResult, p)], retOf(setterCf), p);
			return tmp.init == null ? setCall : TypeFunctions.mk(TBlock([tmp.init, setCall]), retOf(setterCf), p);
		}
		// A class property `a.p op= b` evaluates the receiver once, reads via its read access (the getter
		// or
		// the stored field), applies the op, and writes via its write access.
		function accessorInstanceCompound(fa:hxc.typing.AccessKind.FieldAccess):TExpr {
			var recv = fa.on;
			var tvoid = ctx.com.basic.tvoid;
			var tmp = maybeTempReceiver(ctx, recv, p);
			var er = tmp.expr;
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
			case AKExpr(te1): compound(te1);
			case AKNo(acc2, np):
				// A write-restricted target (a final field) still takes a compound op when the abstract
				// declares a dedicated overload that needs no write-back; the write error is deferred to
				// the needs-assign result.
				var te1 = switch (acc2) {
					case AKExpr(te): te;
					case AKField(fa) | AKAccessor(fa): FieldAccessTools.getFieldExpr(fa, FWrite);
					case _: throw new TypingError("This expression cannot be accessed for writing", np);
				};
				var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
				switch (makeBinop(ctx, sub, te1, te2, true, withType, p)) {
					case BinopSpecial(opCall, false): opCall;
					case _: throw new TypingError("This expression cannot be accessed for writing", np);
				}
			case AKField(fa):
				// A property with a call accessor on either side reads via its getter and writes via its
				// setter; a plain field stays a raw compound.
				var accCall = switch (fa.field.kind) { case Var(k): k.read.match(AccCall) || k.write.match(AccCall); case _: false; };
				accCall ? accessorInstanceCompound(fa) : compound(FieldAccessTools.getFieldExpr(fa, FWrite));
			case AKAccessor(fa): accessorInstanceCompound(fa);
			case AKUsingAccessor(se):
				accessorCompound(se.thisExpr, se.access.host, se.access.field.name);
			case AKResolve(se, name):
				// Compound assign on a resolve field: resolveWrite(this, name, resolveRead(this, name) OP
				// value), evaluating the receiver once.
				var aw = switch (se.access.host) { case FHAbstract(a, tl, c): {a: a, tl: tl, c: c}; case _: null; };
				if (aw == null || aw.a.write == null)
					throw new TypingError("This compound assignment target is not yet ported", p);
				var basic = ctx.com.basic;
				var vr = TypeFunctions.allocVar(VGenerated, "fh", se.thisExpr.type, se.thisExpr.pos);
				var recv = TexprTools.makeLocal(vr, p);
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
				var tempInit = TypeFunctions.mk(TVarExpr(vr, se.thisExpr), basic.tvoid, p);
				switch (makeBinop(ctx, sub, read, te2, true, withType, p)) {
					case BinopSpecial(opCall, false):
						// A dedicated @:op(a -= b) overload is the assignment and returns its own result, so the
						// value is not written back through resolveWrite.
						TypeFunctions.mk(TBlock([tempInit, opCall]), opCall.type, p);
					case br:
						var opResult = toTexpr(br);
						var writeSe = FieldAccessTools.makeAbstractStaticExtensionAccess(aw.a, aw.tl, aw.c, aw.a.write, recv, false, p);
						var writeCe = FieldAccessTools.getFieldExpr(writeSe.access, FCall);
						var write = switch (TypeFunctions.follow(writeCe.type)) {
							case TFun(ws) if (ws.args.length >= 3):
								var nm2 = TexprTools.makeString(basic, name, p);
								var nameArg = Typer.castOrUnify(ctx, ws.args[1].t, nm2, p);
								var valArg = Typer.castOrUnify(ctx, ws.args[2].t, opResult, p);
								Calls.makeCall(ctx, writeCe, Calls.padPosInfos(ctx, ws.args, [recv, nameArg, valArg], p), ws.ret, p);
							case _: throw new TypingError("Resolve target is not a function", p);
						};
						TypeFunctions.mk(TBlock([tempInit, write]), write.type, p);
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
				// `a[k]++` / `--a[k]` on an abstract @:arrayAccess: bind base+key to temps, then get, op
				// with 1, and set, yielding the old value for postfix and the new value for prefix.
				switch (e.expr) {
					case EArray(baseE, keyE):
						var tb = Typer.typeExpr(ctx, baseE, WithTypeTools.value);
						switch (TypeFunctions.follow(tb.type)) {
							case TAbstract(a, tl) if (a.impl != null && a.array.length > 0):
								return arrayIncr(ctx, a, tl, op, flag, tb, keyE, withType, p);
							case TInst(c, tl):
								var kv = Calls.imapKV(c, tl);
								if (kv != null) return imapIncr(ctx, kv, op, flag, tb, keyE, withType, p);
							case _:
						}
					case _:
				}
				switch (Typer.typeAccess(ctx, e.expr, e.pos, MSet(null), withType)) {
					case AKExpr(te):
						var abs = tryAbstractUnop(ctx, op, flag, te, p);
						if (abs != null) abs else makeUnop(ctx, op, flag, te, p);
					case AKField(fa):
						var accCall = switch (fa.field.kind) { case Var(k): k.read.match(AccCall) || k.write.match(AccCall); case _: false; };
						if (accCall) accessorIncr(ctx, op, flag, fa, withType, p) else {
							var te = FieldAccessTools.getFieldExpr(fa, FWrite);
							var abs = tryAbstractUnop(ctx, op, flag, te, p);
							if (abs != null) abs else makeUnop(ctx, op, flag, te, p);
						}
					case AKAccessor(fa): accessorIncr(ctx, op, flag, fa, withType, p);
					case AKUsingAccessor(se): usingAccessorIncr(ctx, op, flag, se, withType, p);
					case AKNo(acc2, np):
						// A dedicated abstract increment overload needs no write-back, so it applies to a
						// write-restricted target (a final field); anything else is a write error.
						var te = switch (acc2) {
							case AKExpr(te2): te2;
							case AKField(fa) | AKAccessor(fa): FieldAccessTools.getFieldExpr(fa, FWrite);
							case _: throw new TypingError("This expression cannot be accessed for writing", np);
						};
						var abs = tryAbstractUnop(ctx, op, flag, te, p);
						if (abs != null) abs else throw new TypingError("This expression cannot be accessed for writing", np);
					case _: throw new TypingError("This increment target is not yet ported", p);
				}
			case Not | Neg | NegBits:
				var te = Typer.typeExpr(ctx, e, WithTypeTools.value);
				var abs = tryAbstractUnop(ctx, op, flag, te, p);
				if (abs != null) abs else makeUnop(ctx, op, flag, te, p);
		};
	}

	// Increment/decrement of a concrete map element `m[k]++` via its IMap get(k)/set(k, v) methods,
	// binding base and key to temps so each evaluates once. Postfix yields the old value, prefix the new.
	static function imapIncr(ctx:TyperContext, kv:{k:T, v:T}, op:Unop, flag:UnopFlag, tb:TExpr, keyE:Expr, withType:WithType, p:Position):TExpr {
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var tk = Typer.castOrUnify(ctx, kv.k, Typer.typeExpr(ctx, keyE, WithTypeTools.value), keyE.pos);
		var vb = TypeFunctions.allocVar(VGenerated, "`", tb.type, p);
		var vk = TypeFunctions.allocVar(VGenerated, "`", tk.type, p);
		var eb = TexprTools.makeLocal(vb, p);
		var ek = TexprTools.makeLocal(vk, p);
		var getExpr = Typer.accGet(ctx, hxc.typing.Fields.typeField(ctx, eb, "get", p, MGet, WithTypeTools.value));
		var setExpr = Typer.accGet(ctx, hxc.typing.Fields.typeField(ctx, eb, "set", p, MGet, WithTypeTools.value));
		var eget = Calls.makeCall(ctx, getExpr, [ek], ctx.com.basic.tnull(kv.v), p);
		var binop = op.match(Increment) ? OpAdd : OpSub;
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		var stmts = [TypeFunctions.mk(TVarExpr(vb, tb), tvoid, p), TypeFunctions.mk(TVarExpr(vk, tk), tvoid, p)];
		if (flag.match(Postfix)) {
			var vold = TypeFunctions.allocVar(VGenerated, "`o", eget.type, p);
			var eold = TexprTools.makeLocal(vold, p);
			stmts.push(TypeFunctions.mk(TVarExpr(vold, eget), tvoid, p));
			var newv = toTexpr(makeBinop(ctx, binop, eold, one, false, withType, p));
			stmts.push(Calls.makeCall(ctx, setExpr, [ek, Typer.castOrUnify(ctx, kv.v, newv, p)], tvoid, p));
			stmts.push(eold);
			return TypeFunctions.mk(TBlock(stmts), eold.type, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, eget, one, false, withType, p));
		var vnew = TypeFunctions.allocVar(VGenerated, "`n", newv.type, p);
		var enew = TexprTools.makeLocal(vnew, p);
		stmts.push(TypeFunctions.mk(TVarExpr(vnew, newv), tvoid, p));
		stmts.push(Calls.makeCall(ctx, setExpr, [ek, Typer.castOrUnify(ctx, kv.v, enew, p)], tvoid, p));
		stmts.push(enew);
		return TypeFunctions.mk(TBlock(stmts), enew.type, p);
	}

	// Increment/decrement of an abstract @:arrayAccess element via getter+setter.
	static function arrayIncr(ctx:TyperContext, a:TAbstract, tl:TParams, op:Unop, flag:UnopFlag, tb:TExpr, keyE:Expr, withType:WithType, p:Position):TExpr {
		var tk = Typer.typeExpr(ctx, keyE, WithTypeTools.value);
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var vb = TypeFunctions.allocVar(VGenerated, "`", tb.type, p);
		var vk = TypeFunctions.allocVar(VGenerated, "`", tk.type, p);
		var eb = TexprTools.makeLocal(vb, p);
		var ek = TexprTools.makeLocal(vk, p);
		var get = Calls.abstractArrayGet(ctx, a, tl, a.impl, eb, ek, p);
		var binop = op.match(Increment) ? OpAdd : OpSub;
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		var stmts = [TypeFunctions.mk(TVarExpr(vb, tb), tvoid, p), TypeFunctions.mk(TVarExpr(vk, tk), tvoid, p)];
		switch (get.key.expr) {
			case TLocal(v) if (v == vk):
			case _:
				var vkc = TypeFunctions.allocVar(VGenerated, "`", get.key.type, p);
				stmts.push(TypeFunctions.mk(TVarExpr(vkc, get.key), tvoid, p));
				get = Calls.abstractArrayGet(ctx, a, tl, a.impl, eb, TexprTools.makeLocal(vkc, p), p);
		}
		var eget = get.expr;
		function fallback(e:TypingError):TExpr {
			if (e.message != "No matching @:arrayAccess setter") throw e;
			var abs = tryAbstractUnop(ctx, op, flag, eget, p);
			if (abs == null) throw e;
			var out = stmts.copy();
			out.push(abs);
			return TypeFunctions.mk(TBlock(out), abs.type, p);
		}
		if (flag.match(Postfix)) {
			var vold = TypeFunctions.allocVar(VGenerated, "`o", eget.type, p);
			var eold = TexprTools.makeLocal(vold, p);
			stmts.push(TypeFunctions.mk(TVarExpr(vold, eget), tvoid, p));
			var newv = toTexpr(makeBinop(ctx, binop, eold, one, false, withType, p));
			try {
				stmts.push(Calls.arraySetValue(ctx, a, tl, a.impl, eb, get.key, function(_) return newv, p));
			} catch (e:TypingError) {
				return fallback(e);
			}
			stmts.push(eold);
			return TypeFunctions.mk(TBlock(stmts), eold.type, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, eget, one, false, withType, p));
		var vnew = TypeFunctions.allocVar(VGenerated, "`n", newv.type, p);
		var enew = TexprTools.makeLocal(vnew, p);
		stmts.push(TypeFunctions.mk(TVarExpr(vnew, newv), tvoid, p));
		try {
			stmts.push(Calls.arraySetValue(ctx, a, tl, a.impl, eb, get.key, function(_) return enew, p));
		} catch (e:TypingError) {
			return fallback(e);
		}
		stmts.push(enew);
		return TypeFunctions.mk(TBlock(stmts), enew.type, p);
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
			var gAcc = hxc.typing.Fields.typeField(ctx, er, "get_" + name, fa.pos, MCall([]), WithTypeTools.value);
			ctx.privateAccess--;
			return Calls.buildCall(ctx, gAcc, [], WithTypeTools.value, fa.pos);
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
			var setterExpr = Typer.accGet(ctx, hxc.typing.Fields.typeField(ctx, er, "set_" + name, fa.pos, MGet, WithTypeTools.value));
			ctx.privateAccess--;
			return Calls.makeCall(ctx, setterExpr, [Typer.castOrUnify(ctx, value.type, value, p)], value.type, p);
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
		var tmp = maybeTempReceiver(ctx, recv, p);
		var er = tmp.expr;
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), p);
		// The accessor keeps the abstract host so its signature gets the instance's type parameters
		// applied.
		var getExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, getterCf, fa.host, false, p), FCall);
		var setExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, setterCf, fa.host, false, p), FCall);
		function retOfE(e:TExpr):T return switch (TypeFunctions.follow(e.type)) { case TFun(s): s.ret; case _: tvoid; };
		function retOf(cf:TClassField):T return retOfE(cf == getterCf ? getExpr : setExpr);
		var readVal = Calls.makeCall(ctx, getExpr, [er], retOf(getterCf), p);
		var binop = op.match(Increment) ? OpAdd : OpSub;
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		// As with a class property, the setter call is the value; only a postfix used as a value needs the
		// old value in a postfix temp.
		var stmts = tmp.init == null ? [] : [tmp.init];
		if (flag.match(Postfix) && !withType.match(NoValue)) {
			var vpost = TypeFunctions.allocVar(VGenerated, "postfix", readVal.type, p);
			var epost = TexprTools.makeLocal(vpost, p);
			stmts.push(TypeFunctions.mk(TVarExpr(vpost, readVal), tvoid, p));
			var newv = toTexpr(makeBinop(ctx, binop, epost, one, false, withType, p));
			stmts.push(Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOf(getterCf), newv, p)], retOf(setterCf), p));
			stmts.push(epost);
			return TypeFunctions.mk(TBlock(stmts), epost.type, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, readVal, one, false, withType, p));
		var setCall = Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOf(getterCf), newv, p)], retOf(setterCf), p);
		if (stmts.length == 0) return setCall;
		stmts.push(setCall);
		return TypeFunctions.mk(TBlock(stmts), setCall.type, p);
	}

	// Increment/decrement of a class property via its accessors: read once, apply +/-1, write back; postfix
	// yields the old value, prefix the new.
	static function accessorIncr(ctx:TyperContext, op:Unop, flag:UnopFlag, fa:hxc.typing.AccessKind.FieldAccess, withType:WithType, p:Position):TExpr {
		var recv = fa.on;
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var binop = op.match(Increment) ? OpAdd : OpSub;
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		// Increment/Decrement: bind the receiver to fh only when it is not a plain local/const
		// (value_reference get_expr_part "fh"); the setter call is itself the value, so prefix and
		// value-discarded forms need no extra temp; a postfix used as a value binds the old value to
		// postfix.
		var recvInit:Null<TExpr> = null;
		var er = recv;
		if (!recv.expr.match(TLocal(_) | TTypeExpr(_) | TConst(_))) {
			var vr = TypeFunctions.allocVar(VGenerated, "fh", recv.type, p);
			er = TexprTools.makeLocal(vr, p);
			recvInit = TypeFunctions.mk(TVarExpr(vr, recv), tvoid, p);
		}
		var readVal = accessorReadOn(ctx, er, fa);
		if (flag.match(Postfix) && !withType.match(NoValue)) {
			var vpost = TypeFunctions.allocVar(VGenerated, "postfix", readVal.type, p);
			var epost = TexprTools.makeLocal(vpost, p);
			var newv = toTexpr(makeBinop(ctx, binop, epost, one, false, withType, p));
			var stmts:Array<TExpr> = [];
			if (recvInit != null) stmts.push(recvInit);
			stmts.push(TypeFunctions.mk(TVarExpr(vpost, readVal), tvoid, p));
			stmts.push(accessorWriteOn(ctx, er, fa, newv, p));
			stmts.push(epost);
			return TypeFunctions.mk(TBlock(stmts), epost.type, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, readVal, one, false, withType, p));
		var setCall = accessorWriteOn(ctx, er, fa, newv, p);
		return recvInit == null ? setCall : TypeFunctions.mk(TBlock([recvInit, setCall]), setCall.type, p);
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
			case Increment | Decrement:
				// checkAssign runs at the caller; here only checkInt.
				checkInt();
			case Spread:
				throw new TypingError("Unexpected unary operator in makeUnop", p);
		};
		return TypeFunctions.mk(TUnop(op, flag, e), t, p);
	}
}
