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
			// Untyped code ignores unification failures.
			if (ctx.untypedMode) return;
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

	static function checkAbstractFinalTarget(e:TExpr, ?errorPos:Position):Void {
		var ep = errorPos == null ? e.pos : errorPos;
		switch (e.expr) {
			case TLocal(v) if (TypeFunctions.hasVarFlag(v, VFinal)):
				throw new TypingError("Cannot modify abstract value of final local", ep);
			case TField(_, fa):
				var cf = switch (fa) {
					case FInstance(_, _, f) | FStatic(_, f) | FAnon(f) | FClosure(_, f): f;
					case FEnum(_, _) | FDynamic(_): null;
				};
				if (cf != null && TypeFunctions.hasClassFieldFlag(cf, CfFinal))
					throw new TypingError("Cannot modify abstract value of final field", ep);
			case _:
		}
	}

	static function abstractOpWrites(ctx:TyperContext, t:T, op:Binop):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _):
				var writes = false;
				for (aop in a.ops) {
					if (!(Type.enumEq(aop.op, op) || Type.enumEq(aop.op, OpAssignOp(op)))) continue;
					hxc.typing.TypeFields.forceFieldBody(ctx.com, a.impl, aop.cf);
					var body = aop.cf.expr;
					if (body != null) {
						var arg:TVar = switch (body.expr) { case TFunction(tf) if (tf.args.length > 0): tf.args[0].v; case _: null; };
						function visit(e:TExpr):Void {
							switch (e.expr) {
								case TBinop(OpAssign | OpAssignOp(_), {expr: TLocal(v)}, _) if (v == arg): writes = true;
								case TUnop(Increment | Decrement, _, {expr: TLocal(v)}) if (v == arg): writes = true;
								case _: TexprTools.iter(visit, e);
							}
						}
						visit(body);
					}
				}
				writes;
			case _: false;
		};
	}

	static function abstractUnopWrites(ctx:TyperContext, t:T, op:Unop):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _) if (a.impl != null):
				var writes = false;
				for (au in a.unops) if (au.op == op) {
					hxc.typing.TypeFields.forceFieldBody(ctx.com, a.impl, au.cf);
					var body = au.cf.expr;
					if (body != null) {
						var arg:TVar = switch (body.expr) { case TFunction(tf) if (tf.args.length > 0): tf.args[0].v; case _: null; };
						function visit(e:TExpr):Void switch (e.expr) {
							case TBinop(OpAssign | OpAssignOp(_), {expr: TLocal(v)}, _) if (v == arg): writes = true;
							case TUnop(Increment | Decrement, _, {expr: TLocal(v)}) if (v == arg): writes = true;
							case _: TexprTools.iter(visit, e);
						};
						visit(body);
					}
				}
				writes;
			case _: false;
		};
	}

	static function abstractHasUnop(t:T, op:Unop):Bool return switch (TypeFunctions.follow(t)) {
		case TAbstract(a, _): [for (au in a.unops) if (au.op == op) au].length > 0;
		case _: false;
	};

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
			// calling it (null-checked); other operands are stringified by the runtime. The inner loop
			// walks over the type (not the expr) so an abstract with no @:to String recurses through its
			// underlying type: a cpp.Callable over a function reaches KOther and stringifies.
			function loop(t:T):TExpr {
				return switch (classify(t)) {
					case KAbstract(a, _) if (a.impl != null && a.impl.statics.exists("toString")):
						callToString(e);
					case KInt | KFloat | KString: e;
					case KUnk | KDyn | KNumParam(_) | KStrParam(_) | KOther:
						// A non-primitive operand (Array, an enum, an anon, ...) stringifies through
						// Std.string, not the target's native coercion.
						stdString(e);
					case KAbstract(a, tl):
						// An abstract with no toString is converted to String by its @:to String cast when
						// it has one; otherwise it stringifies as its underlying value.
						try Typer.castOrUnify(ctx, tstring, e, p) catch (_:Dynamic) loop(TypeFunctions.getUnderlyingType(a, tl));
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
				try unify(ctx, c1.type, c2.type, p) catch (_:TypingError) {
					try unify(ctx, c2.type, c1.type, p) catch (_:TypingError) {
						// Neither operand unifies directly: follow an abstract @:to/@:from cast so an abstract
						// compares against its underlying type (plain unify does not chase method casts); the failure
						// reports at the BINOP position without aborting, so a boolean context around the comparison
						// still checks. (AbstractCast.cast_or_unify ... p).
						try c1 = Typer.castOrUnify(ctx, c2.type, c1, p) catch (_:TypingError) {
							try c2 = Typer.castOrUnify(ctx, c1.type, c2, p) catch (te:TypingError) {
								ctx.com.addDiagnostic(te.message, te.pos, te.depth);
							}
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
				var call = makeStaticOpCall(ctx, implC, cf, map, [erhs, elhs], tret, p);
				var e = TypeFunctions.mk(TBlock([
					TypeFunctions.mk(TVarExpr(vlhs, me2), tvoid, me2.pos),
					TypeFunctions.mk(TVarExpr(vrhs, me1), tvoid, me1.pos),
					call
				]), tret, p);
				return BinopSpecial(e, needsAssign);
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

	static function assignTo(ctx:TyperContext, te1:TExpr, e2:Expr, p:Position):TExpr {
		var te2 = Typer.castOrUnify(ctx, te1.type, Typer.typeExpr(ctx, e2, WithTypeTools.withType(te1.type)), p);
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

	// #get_expr_aux: depth 0 keeps a field/array access SHAPE, binding only its non-simple parts ("fh"
	// receiver, "base"/"index" operands); depth 1 binds any non-simple expression whole. Binds accumulate
	// as TVar decls.
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
						// The read access resolves first so the key carries any getter coercion, then each operand
						// binds to a gen temp only when it is not a constant expression (a const key stays inline,
						// keeping the element access foldable by inline_constructors); the key declaration emits
						// before the base one. (find_array_read_access + maybe_bind_to_temp via
						// Optimizer.make_constant_expression).
						var probe = Calls.abstractArrayGet(ctx, a, tl, a.impl, tb, tk, p);
						function maybeBind(e:TExpr):{e:TExpr, decl:Null<TExpr>} {
							var c = hxc.optimization.Optimizer.makeConstantExpression(ctx, e);
							return if (c != null) {e: c, decl: null} else {
								var v = TypeFunctions.allocVar(VGenerated, "`", e.type, p);
								{e: TexprTools.makeLocal(v, p), decl: TypeFunctions.mk(TVarExpr(v, e), tvoid, p)};
							};
						}
						var bk = maybeBind(probe.key);
						var bb = maybeBind(tb);
						var get = Calls.abstractArrayGet(ctx, a, tl, a.impl, bb.e, bk.e, p);
						var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
						var eop = toTexpr(makeBinop(ctx, sub, get.expr, te2, true, withType, p));
						var eset = Calls.arraySetValue(ctx, a, tl, a.impl, bb.e, get.key, function(_) return eop, p);
						var block:Array<TExpr> = [];
						if (bk.decl != null) block.push(bk.decl);
						if (bb.decl != null) block.push(bb.decl);
						block.push(eset);
						return block.length == 1 ? eset : TypeFunctions.mk(TBlock(block), eset.type, p);
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
			if (abstractOpWrites(ctx, te1.type, sub)) checkAbstractFinalTarget(te1, switch (te1.expr) { case TLocal(_): p; case _: null; });
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
					vrToTexpr(st.init, mkAssign(st.lv, opCall));
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
		function accessorCompound(recv:TExpr, host:hxc.typing.AccessKind.FieldHost, name:String):TExpr {
			var implC = FieldAccessTools.getHostClassRaise(host);
			var getterCf = implC.statics.get("get_" + name);
			var setterCf = implC.statics.get("set_" + name);
			if (getterCf == null || setterCf == null) throw new TypingError("This compound assignment target is not yet ported", p);
			var tvoid = ctx.com.basic.tvoid;
			// The receiver stabilizes at depth 0, so an array-access receiver keeps its shape with
			// "base"/"index" binds and duplicates as an expression in the get and set calls.
			var recvVars:Array<TExpr> = [];
			var er = vrGetExprAux(ctx, recvVars, 0, "fh", recv);
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
			Calls.checkModifiesThisDirect(ctx, implC, setterCf, recv, p);
			var setCall = Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOf(getterCf), opResult, p)], retOf(setterCf), p);
			return vrToTexpr(recvVars, setCall);
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
				if (abstractOpWrites(ctx, te1.type, sub)) checkAbstractFinalTarget(te1, switch (te1.expr) { case TLocal(_): p; case _: null; });
				var te2 = Typer.typeExpr(ctx, e2, WithTypeTools.value);
				switch (makeBinop(ctx, sub, te1, te2, true, withType, p)) {
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
				accessorCompound(se.thisExpr, se.access.host, se.access.field.name);
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
				var pre = try Typer.typeExpr(ctx, e, WithTypeTools.value) catch (_:Dynamic) null;
			if (pre != null && !abstractHasUnop(pre.type, op) && !abstractUnopWrites(ctx, pre.type, op)) switch (pre.expr) {
				case TLocal(v) if (TypeFunctions.hasVarFlag(v, VFinal)): checkAssign(ctx, pre);
				case TField(_, _):
					try checkAssign(ctx, pre) catch (err:TypingError) { throw err; }
				case _:
			}
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
						if (abstractUnopWrites(ctx, te.type, op)) checkAbstractFinalTarget(te, p);
						var abs = tryAbstractUnop(ctx, op, flag, te, p);
						if (abs != null) abs else makeUnop(ctx, op, flag, te, p);
					case AKField(fa):
						var accCall = switch (fa.field.kind) { case Var(k): k.read.match(AccCall) || k.write.match(AccCall); case _: false; };
						if (accCall) accessorIncr(ctx, op, flag, fa, withType, p) else {
							// The receiver part binds as "fh" before the unop applies to the field.
							var recvVars:Array<TExpr> = [];
							var ef = vrGetExprAux(ctx, recvVars, 1, "fh", fa.on);
							var te = FieldAccessTools.getFieldExpr({on: ef, field: fa.field, host: fa.host, isInline: fa.isInline, pos: fa.pos}, FWrite);
							if (abstractUnopWrites(ctx, te.type, op)) checkAbstractFinalTarget(te, p);
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
						if (abstractUnopWrites(ctx, te.type, op)) checkAbstractFinalTarget(te, p);
						var abs = tryAbstractUnop(ctx, op, flag, te, p);
						if (abs != null) abs else { checkAssign(ctx, te); throw new TypingError("This expression cannot be accessed for writing", np); }
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
		// The concrete-IMap variant of the increment (hxc types some map bases at the resolved instance):
		// same temp naming and shape as the abstract path produces through Map_Impl_.arrayWrite (key/read
		// temps "tmp", the written value binds as arrayWrite's "v" parameter for prefix; the base feeds
		// both calls directly).
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var tk = Typer.castOrUnify(ctx, kv.k, Typer.typeExpr(ctx, keyE, WithTypeTools.value), keyE.pos);
		var vKey = TypeFunctions.allocVar(VGenerated, "tmp", tk.type, tk.pos);
		var ek = TexprTools.makeLocal(vKey, p);
		var getExpr = Typer.accGet(ctx, hxc.typing.Fields.typeField(ctx, tb, "get", p, MGet, WithTypeTools.value));
		var setExpr = Typer.accGet(ctx, hxc.typing.Fields.typeField(ctx, tb, "set", p, MGet, WithTypeTools.value));
		var eget = Calls.makeCall(ctx, getExpr, [ek], ctx.com.basic.tnull(kv.v), p);
		var binop = op.match(Increment) ? OpAdd : OpSub;
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		var stmts = [TypeFunctions.mk(TVarExpr(vKey, tk), tvoid, p)];
		if (flag.match(Postfix)) {
			var vold = TypeFunctions.allocVar(VGenerated, "tmp", eget.type, p);
			var eold = TexprTools.makeLocal(vold, p);
			stmts.push(TypeFunctions.mk(TVarExpr(vold, eget), tvoid, p));
			var newv = toTexpr(makeBinop(ctx, binop, eold, one, false, withType, p));
			stmts.push(Calls.makeCall(ctx, setExpr, [ek, Typer.castOrUnify(ctx, kv.v, newv, p)], tvoid, p));
			stmts.push(eold);
			// The increment expression yields the element type (what the abstract @:arrayAccess setter
			// returns), not the nullable getter result: the block as e_set.type (V), so a Null<V>/Dynamic
			// old value casts to V at the use site.
			return TypeFunctions.mk(TBlock(stmts), kv.v, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, eget, one, false, withType, p));
		var vnew = TypeFunctions.allocVar(VGenerated, "v", newv.type, p);
		var enew = TexprTools.makeLocal(vnew, p);
		stmts.push(TypeFunctions.mk(TVarExpr(vnew, newv), tvoid, p));
		stmts.push(Calls.makeCall(ctx, setExpr, [ek, Typer.castOrUnify(ctx, kv.v, enew, p)], tvoid, p));
		stmts.push(enew);
		return TypeFunctions.mk(TBlock(stmts), enew.type, p);
	}

	// Increment/decrement of an abstract @:arrayAccess element via getter+setter.
	static function arrayIncr(ctx:TyperContext, a:TAbstract, tl:TParams, op:Unop, flag:UnopFlag, tb:TExpr, keyE:Expr, withType:WithType, p:Position):TExpr {
		// Increment/decrement through @:arrayAccess: bind key and read value to "tmp" temps, apply the op
		// inline, write through @:arrayAccess; the block yields the set-call result for prefix and the read
		// temp for postfix. The base expression feeds both calls directly (no base temp is bound).
		var tvoid = ctx.com.basic.tvoid;
		var tint = ctx.com.basic.tint;
		var ekey = Typer.typeExpr(ctx, keyE, WithTypeTools.value);
		var vKey = TypeFunctions.allocVar(VGenerated, "tmp", ekey.type, ekey.pos);
		var evarKey = TypeFunctions.mk(TVarExpr(vKey, ekey), tvoid, ekey.pos);
		var ekeyL = TexprTools.makeLocal(vKey, ekey.pos);
		var get = Calls.abstractArrayGet(ctx, a, tl, a.impl, tb, ekeyL, p);
		var eGet = get.expr;
		var vGet = TypeFunctions.allocVar(VGenerated, "tmp", eGet.type, eGet.pos);
		var evGet = TexprTools.makeLocal(vGet, p);
		var evarGet = TypeFunctions.mk(TVarExpr(vGet, eGet), tvoid, p);
		var one = TypeFunctions.mk(TConst(TInt(1)), tint, p);
		var eOp = TypeFunctions.mk(TBinop(op.match(Increment) ? OpAdd : OpSub, evGet, one), evGet.type, p);
		var eSet = Calls.arraySetValue(ctx, a, tl, a.impl, tb, ekeyL, function(_) return eOp, p, false);
		if (eSet == null) {
			// An @:op(A++)-style unop on the read value covers the increment, else the setter resolution
			// raises its own diagnostic.
			var abs = tryAbstractUnop(ctx, op, flag, eGet, p);
			if (abs == null) {
				Calls.arraySetValue(ctx, a, tl, a.impl, tb, ekeyL, function(_) return eOp, p);
				throw new TypingError("No matching @:arrayAccess setter", p);
			}
			return TypeFunctions.mk(TBlock([evarKey, abs]), abs.type, p);
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
			var gAcc = hxc.typing.Fields.typeField(ctx, er, "get_" + name, fa.pos, MCall([]), WithTypeTools.value);
			ctx.privateAccess--;
			var call = Calls.buildCall(ctx, gAcc, [], WithTypeTools.value, fa.pos);
			return switch (call.expr) {
				case TCall(callee, args): TypeFunctions.mk(TCall(atFieldPos(callee, fa.pos), args), call.type, call.pos);
				case _: call;
			};
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
			return Calls.makeCall(ctx, atFieldPos(setterExpr, fa.pos), [Typer.castOrUnify(ctx, value.type, value, p)], value.type, p);
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
			stmts.push(Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOf(getterCf), newv, p)], retOf(setterCf), p));
			stmts.push(epost);
			return TypeFunctions.mk(TBlock(stmts), epost.type, p);
		}
		var newv = toTexpr(makeBinop(ctx, binop, readVal, one, false, withType, p));
		var setCall = Calls.makeCall(ctx, setExpr, [er, Typer.castOrUnify(ctx, retOf(getterCf), newv, p)], retOf(setterCf), p);
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
