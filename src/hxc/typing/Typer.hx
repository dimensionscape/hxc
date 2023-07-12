package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.TypingError;
import hxc.core.Texpr;
import hxc.core.WithType;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;
import hxc.typing.Matcher.Match;
import hxc.typing.TyperContext.CurrentFun;
import hxc.typing.Typeload;

class Typer {

	// A fresh mono, recorded in the per-function list.
	public static function spawnMonomorph(ctx:TyperContext, p:Position):T {
		var mono = TypeUnification.monoCreate();
		ctx.monomorphs.unshift({m: mono, p: p}); // Prepends (newest first)
		return TMono(mono);
	}

	public static function saveLocals(ctx:TyperContext):Void->Void {
		var saved = ctx.locals.copy();
		return function() ctx.locals = saved;
	}

	public static function addLocal(ctx:TyperContext, k:TVarKind, n:String, t:T, p:Position):TVar {
		var v = TypeFunctions.allocVar(k, n, t, p);
		ctx.locals.set(n, v);
		return v;
	}

	public static function addLocalWithOrigin(ctx:TyperContext, origin:TVarOrigin, n:String, t:T, p:Position):TVar {
		return addLocal(ctx, VUser(origin), n, t, p);
	}

	public static function monoOrDynamic(ctx:TyperContext, withType:WithType, p:Position):T {
		return switch (withType) {
			case NoValue: TDynamic(null);
			case Value(_) | WithType(_, _): spawnMonomorph(ctx, p);
		};
	}

	public static function castOrUnify(ctx:TyperContext, t:T, e:TExpr, p:Position):TExpr {
		try {
			TypeUnification.unifyDefault(e.type, t);
		} catch (_:UnifyError) {
			throw new TypingError("Cannot unify types", p);
		}
		return e;
	}

	static function isVoid(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	public static function unifyMinRaise(ctx:TyperContext, el:Array<TExpr>):T {
		var basic = ctx.com.basic;
		if (el.length == 0) return spawnMonomorph(ctx, Position.nullPos);
		if (el.length == 1) return el[0].type;

		function chkNull(e:TExpr):Bool {
			if (TypeFunctions.isNull(e.type) || TypeFunctions.isExplicitNull(e.type)) return true;
			return switch (e.expr) {
				case TConst(TNull): true;
				case TBlock(el2): el2.length == 0 ? false : chkNull(el2[el2.length - 1]);
				case TParenthesis(e2): chkNull(e2);
				case TMeta(_, e2): chkNull(e2);
				case _: false;
			};
		}

		var t = spawnMonomorph(ctx, Position.nullPos);
		var hasError = false;
		for (e in el) {
			if (chkNull(e)) t = basic.tnull(t);
			try {
				TypeUnification.unifyDefault(e.type, t);
			} catch (_:UnifyError) {
				try {
					TypeUnification.unifyDefault(t, e.type);
					t = TypeFunctions.isNull(t) ? basic.tnull(e.type) : e.type;
				} catch (_:UnifyError) {
					hasError = true;
					break;
				}
			}
		}
		if (!hasError) return t;

		var commonTypes = TypeUnification.collectBaseTypes(t);
		var dynTypes = [];
		for (ty in commonTypes) {
			switch (ty) {
				case TInst(c, params) if (params.length > 0 && hasUnifyMinDynamic(c)):
					dynTypes.push(TInst(c, [for (_ in params) TDynamic(null)]));
				case _:
			}
		}
		dynTypes.reverse();
		if (dynTypes.length > 0) commonTypes = commonTypes.concat(dynTypes);
		var elTail = el.slice(1);
		var tl = [for (e in elTail) e.type];
		return switch (TypeUnification.unify_min_(TypeUnification.defaultUnificationContext, commonTypes, tl)) {
			case UnifyMinOk(t2): t2;
			case UnifyMinError(l, index):
				throw new TypingError("Cannot find a common type for the given expressions", elTail[index].pos);
		};
	}

	static function hasUnifyMinDynamic(c:TClass):Bool {
		if (TypeFunctions.hasMeta(":unifyMinDynamic", c.meta)) return true;
		return switch (c.superClass) {
			case null: false;
			case s: hasUnifyMinDynamic(s.c);
		};
	}

	public static function unifyMin(ctx:TyperContext, el:Array<TExpr>):T {
		return try unifyMinRaise(ctx, el) catch (_:TypingError) el[0].type;
	}

	public static function unifyMinForTypeSource(ctx:TyperContext, el:Array<TExpr>, src:Null<WithTypeSource>):T {
		return switch (src) {
			case ImplicitReturn if (Lambda.exists(el, function(e) return isVoid(e.type))):
				ctx.com.basic.tvoid;
			case _: unifyMin(ctx, el);
		};
	}

	public static function typeExpr(ctx:TyperContext, e:Expr, withType:WithType, ?mode:AccessMode):TExpr {
		if (mode == null) mode = MGet;
		var basic = ctx.com.basic;
		var p = e.pos;
		return switch (e.expr) {
			case EConst(c): typeConst(ctx, c, p, mode, withType);
			case EParenthesis(e1):
				var te = typeExpr(ctx, e1, withType);
				TypeFunctions.mk(TParenthesis(te), te.type, te.pos);
			case EBlock(l):
				var restore = saveLocals(ctx);
				var te = typeBlock(ctx, l, withType, p);
				restore();
				te;
			case EVars(vl): typeVars(ctx, vl, p);
			case EIf(econd, e1, e2): typeIf(ctx, econd, e1, e2, withType, false, p);
			case ETernary(econd, e1, e2): typeIf(ctx, econd, e1, e2, withType, true, p);
			case EWhile(cond, body, NormalWhile):
				var oldLoop = ctx.inLoop;
				var c = castOrUnify(ctx, basic.tbool, typeExpr(ctx, cond, WithTypeTools.value), p);
				ctx.inLoop = true;
				var b = typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
				ctx.inLoop = oldLoop;
				TypeFunctions.mk(TWhile(c, b, NormalWhile), basic.tvoid, p);
			case EWhile(cond, body, DoWhile):
				var oldLoop = ctx.inLoop;
				ctx.inLoop = true;
				var b = typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
				ctx.inLoop = oldLoop;
				var c = typeExpr(ctx, cond, WithTypeTools.value);
				c = castOrUnify(ctx, basic.tbool, c, c.pos);
				TypeFunctions.mk(TWhile(c, b, DoWhile), basic.tvoid, p);
			case EReturn(re):
				if (!ctx.inFunction) throw new TypingError("Return outside function", p);
				typeReturn(ctx, re, withType, p);
			case EBreak:
				if (!ctx.inLoop) throw new TypingError("Break outside loop", p);
				TypeFunctions.mk(TBreak, monoOrDynamic(ctx, withType, p), p);
			case EContinue:
				if (!ctx.inLoop) throw new TypingError("Continue outside loop", p);
				TypeFunctions.mk(TContinue, monoOrDynamic(ctx, withType, p), p);
			case EThrow(e1):
				var te = typeExpr(ctx, e1, WithTypeTools.value);
				TypeFunctions.mk(TThrow(te), monoOrDynamic(ctx, withType, p), p);
			case EUntyped(e1):
				typeExpr(ctx, e1, withType);
			case EMeta(_, e1):
				typeExpr(ctx, e1, withType);
			case EField(_, _, _) | EArray(_, _) | ECall(_, _):
				accGet(ctx, typeAccess(ctx, e.expr, p, mode, withType));
			case EBinop(op, e1, e2):
				Operators.typeBinop(ctx, op, e1, e2, false, withType, p);
			case EUnop(op, flag, e1):
				Operators.typeUnop(ctx, op, flag, e1, withType, p);
			case ESwitch(e1, cases, def):
				Match.matchExpr(ctx, e1, cases, def, withType, false, p);
			case EFor(it, body):
				ForLoop.typeForLoop(ctx, it, body, p);
			case ENew(tp, el):
				typeNew(ctx, tp, el, withType, p);
			case EFunction(kind, f):
				var args:Array<TFuncArg> = [];
				for (fa in f.fArgs) {
					var at = Typeload.loadTypeHint(ctx.com, ctx.typeParams, fa.type, fa.opt);
					args.push({v: TypeFunctions.allocVar(VUser(TVOLocalVariable), fa.name.name, at, fa.name.pos), c: null});
				}
				var ret = Typeload.loadTypeHint(ctx.com, ctx.typeParams, f.fType, false);
				var ft = TFun({args: [for (a in args) {name: a.v.name, opt: false, t: a.v.type}], ret: ret});
				switch (kind) {
					case FKNamed(n, _): addLocal(ctx, VUser(TVOLocalVariable), n.name, ft, n.pos);
					case _:
				}
				var tf = typeFunction(ctx, args, ret, ctx.curfun, f.fExpr, p);
				TypeFunctions.mk(TFunction(tf), ft, p);
			case EArrayDecl(el):
				switch (el) {
					case [{expr: EFor(_, _)}] | [{expr: EWhile(_, _, _)}]:
						throw new TypingError("Array comprehensions are not yet ported", p);
					case _:
						var tl = [for (e in el) typeExpr(ctx, e, WithTypeTools.value)];
						var et = tl.length == 0 ? spawnMonomorph(ctx, p) : unifyMin(ctx, tl);
						TypeFunctions.mk(TArrayDecl(tl), ctx.com.basic.tarray(et), p);
				}
			case EObjectDecl(fields):
				var tfields:Array<TObjectField> = [];
				var anonFields = new haxe.ds.StringMap<TClassField>();
				for (f in fields) {
					var te = typeExpr(ctx, f.expr, WithTypeTools.value);
					tfields.push({key: {name: f.name, pos: f.pos, quotes: f.quotes}, expr: te});
					anonFields.set(f.name, TypeFunctions.mkField(f.name, te.type, f.pos, f.pos));
				}
				var t = TypeFunctions.mkAnon(new hxc.core.Ref(Closed), anonFields);
				TypeFunctions.mk(TObjectDecl(tfields), t, p);
			case ETry(e1, catches):
				var te = typeExpr(ctx, e1, withType);
				var tcatches:Array<TCatch> = [];
				var bodies = [te];
				for (c in catches) {
					var restore = saveLocals(ctx);
					var ct = c.type != null ? Typeload.loadComplexType(ctx.com, ctx.typeParams, c.type) : TypeFunctions.tDynamic;
					var v = addLocal(ctx, VUser(TVOCatchVariable), c.name.name, ct, c.pos);
					var cbody = typeExpr(ctx, c.expr, withType);
					restore();
					tcatches.push({v: v, expr: cbody});
					bodies.push(cbody);
				}
				TypeFunctions.mk(TTry(te, tcatches), unifyMin(ctx, bodies), p);
			case ECast(_, _):
				throw new TypingError("cast is not yet ported", p);
			case EIs(_, _):
				throw new TypingError("is-expressions are not yet ported", p);
			case EDisplay(_, _):
				throw new TypingError("Display is not yet ported", p);
			case ECheckType(_, _):
				throw new TypingError("Type checks are not yet ported", p);
		};
	}

	static function typeConst(ctx:TyperContext, c:Constant, p:Position, mode:AccessMode, withType:WithType):TExpr {
		var basic = ctx.com.basic;
		return switch (c) {
			case CIdent(s):
				if (s == "super" && !withType.match(NoValue)) throw new TypingError("Cannot use super as value", p);
				accGet(ctx, typeIdent(ctx, s, p, mode, withType));
			case CInt(s, suffix):
				if (suffix == null) Texpr.typeConstant(basic, c, p);
				else switch (suffix) {
					case "i32":
						var i = Std.parseInt(s);
						if (i == null) throw new TypingError("Cannot represent " + s + " with a 32 bit integer", p);
						TypeFunctions.mk(TConst(TInt(i)), basic.tint, p);
					case "i64" | "u32": throw new TypingError("Integer suffix " + suffix + " is not yet supported", p);
					case other: throw new TypingError(other + " is not a valid integer suffix", p);
				}
			case CFloat(s, suffix):
				if (suffix == null) Texpr.typeConstant(basic, c, p);
				else switch (suffix) {
					case "f64": Texpr.typeConstant(basic, CFloat(s, null), p);
					case other: throw new TypingError(other + " is not a valid float suffix", p);
				}
			case CString(_, _):
				Texpr.typeConstant(basic, c, p);
			case CRegexp(_, _):
				throw new TypingError("Regex literals are not yet ported", p);
		};
	}

	// Type_ident (subset): locals and the literal idents. Member/static fields, types,
	// imports, and globals resolve in the fields-dispatch unit.
	static function typeIdent(ctx:TyperContext, i:String, p:Position, mode:AccessMode, withType:WithType):AccessKind {
		if (ctx.locals.exists(i)) {
			return AKExpr(Texpr.makeLocal(ctx.locals.get(i), p));
		}
		switch (i) {
			case "null": return AKExpr(TypeFunctions.mk(TConst(TNull), ctx.com.basic.tnull(spawnMonomorph(ctx, p)), p));
			case "true": return AKExpr(Texpr.makeBool(ctx.com.basic, true, p));
			case "false": return AKExpr(Texpr.makeBool(ctx.com.basic, false, p));
			case "this": return AKExpr(TypeFunctions.mk(TConst(TThis), ctx.tthis, p));
			case _:
		}
		if (ctx.curclass != TypeFunctions.nullClass) {
			var imf = ctx.curclass.fields.get(i);
			if (imf != null && !ctx.curfun.match(FunStatic)) {
				var thisExpr = TypeFunctions.mk(TConst(TThis), ctx.tthis, p);
				return AKField(FieldAccessTools.create(thisExpr, imf, FieldAccessTools.getHost(ctx.curclass, imf), false, p));
			}
			var smf = ctx.curclass.statics.get(i);
			if (smf != null) {
				var typeExpr = Texpr.makeTypeExpr(TClassDecl(ctx.curclass), p);
				return AKField(FieldAccessTools.create(typeExpr, smf, FieldAccessTools.getHost(ctx.curclass, smf), false, p));
			}
		}
		try {
			var mt = ctx.com.getType({pack: [], name: i}, p, null);
			// Hxc resolves field types in a separate pass; resolve the referenced module so its
			// statics have real types (idempotent via processed).
			try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
			return AKExpr(Texpr.makeTypeExpr(mt, p));
		} catch (_:hxc.context.Context.ContextError) {
			throw new TypingError("Unknown identifier : " + i, p);
		}
	}

	static function accGet(ctx:TyperContext, acc:AccessKind):TExpr {
		return switch (acc) {
			case AKExpr(e): e;
			case AKField(fa): FieldAccessTools.getFieldExpr(fa, FRead);
			case AKNo(_, p): throw new TypingError("This expression cannot be accessed for reading", p);
			case AKAccessor(_) | AKUsingAccessor(_): throw new TypingError("Property accessor reads are not yet ported (needs call dispatch, unit 5)", Position.nullPos);
			case AKUsingField(_): throw new TypingError("Static-extension field reads are not yet ported (unit 5)", Position.nullPos);
			case AKAccess(_, _, _, _, _): throw new TypingError("Abstract array access is not yet ported", Position.nullPos);
			case AKResolve(_, _): throw new TypingError("@:resolve access is not yet ported", Position.nullPos);
			case AKSafeNav(_): throw new TypingError("Safe navigation is not yet ported", Position.nullPos);
		};
	}

	public static function typeAccess(ctx:TyperContext, edef:ExprDef, p:Position, mode:AccessMode, withType:WithType):AccessKind {
		return switch (edef) {
			case EConst(CIdent(s)):
				typeIdent(ctx, s, p, mode, withType);
			case EField(e1, field, _):
				if (StringTools.startsWith(field, "$")) throw new TypingError("Field names starting with $ are not allowed", p);
				var te = typeExpr(ctx, e1, WithTypeTools.value);
				Fields.typeField(ctx, te, field, p, mode, withType);
			case EArray(e1, e2):
				var te1 = typeExpr(ctx, e1, WithTypeTools.value);
				var te2 = typeExpr(ctx, e2, WithTypeTools.value);
				Calls.arrayAccess(ctx, te1, te2, mode, p);
			case ECall(e1, params):
				AKExpr(Calls.typeCall(ctx, e1, params, withType, p));
			case _:
				AKExpr(typeExpr(ctx, new Expr(edef, p), withType));
		};
	}

	static function typeBlock(ctx:TyperContext, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		var acc:Array<TExpr> = [];
		function merge(e:TExpr) {
			switch (e.expr) {
				case TMeta(m, inner) if (m.name == ":mergeBlock"):
					switch (inner.expr) {
						case TBlock(el2): for (x in el2) acc.push(x);
						case _: acc.push(e);
					}
				case _: acc.push(e);
			}
		}
		var i = 0;
		while (i < el.length) {
			var wt = (i == el.length - 1) ? withType : WithTypeTools.noValue;
			merge(typeExpr(ctx, el[i], wt));
			i++;
		}
		var t = acc.length == 0 ? ctx.com.basic.tvoid : acc[acc.length - 1].type;
		return TypeFunctions.mk(TBlock(acc), t, p);
	}

	static function typeVars(ctx:TyperContext, vl:Array<EVar>, p:Position):TExpr {
		var basic = ctx.com.basic;
		var out:Array<{v:TVar, e:Null<TExpr>}> = [];
		for (ev in vl) {
			var n = ev.evName.name;
			var pv = ev.evName.pos;
			var t = Typeload.loadTypeHint(ctx.com, ctx.typeParams, ev.evType);
			var e:Null<TExpr> = switch (ev.evExpr) {
				case null: null;
				case ex:
					var oldLoop = ctx.inLoop;
					if (ev.evStatic) ctx.inLoop = false;
					var te = typeExpr(ctx, ex, WithTypeTools.withType(t));
					ctx.inLoop = oldLoop;
					castOrUnify(ctx, t, te, p);
			};
			var v = addLocalWithOrigin(ctx, TVOLocalVariable, n, t, pv);
			v.meta = ev.evMeta;
			if (ev.evFinal) TypeFunctions.addVarFlag(v, VFinal);
			if (ev.evStatic) TypeFunctions.addVarFlag(v, VStatic);
			out.push({v: v, e: e});
		}
		if (out.length == 1) {
			return TypeFunctions.mk(TVarExpr(out[0].v, out[0].e), basic.tvoid, p);
		}
		var block = [for (ve in out) TypeFunctions.mk(TVarExpr(ve.v, ve.e), basic.tvoid, p)];
		var e = TypeFunctions.mk(TBlock(block), basic.tvoid, p);
		return TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: p}, e), e.type, e.pos);
	}

	static function typeIf(ctx:TyperContext, econd:Expr, e1:Expr, e2:Null<Expr>, withType:WithType, isTernary:Bool, p:Position):TExpr {
		var c = typeExpr(ctx, econd, WithTypeTools.value);
		if (isTernary) switch (c.expr) {
			case TConst(TNull): throw new TypingError("Cannot use null as ternary condition", c.pos);
			case _:
		}
		c = castOrUnify(ctx, ctx.com.basic.tbool, c, p);
		var te1 = typeExpr(ctx, Expr.ensureBlock(e1), withType);
		return switch (e2) {
			case null: TypeFunctions.mk(TIf(c, te1, null), ctx.com.basic.tvoid, p);
			case ex2:
				var te2 = typeExpr(ctx, Expr.ensureBlock(ex2), withType);
				makeIfThenElse(ctx, c, te1, te2, withType, p);
		};
	}

	static function makeIfThenElse(ctx:TyperContext, e0:TExpr, e1:TExpr, e2:TExpr, withType:WithType, p:Position):TExpr {
		var t:T;
		switch (withType) {
			case NoValue:
				t = ctx.com.basic.tvoid;
			case Value(_):
				t = unifyMin(ctx, [e1, e2]);
			case WithType(tt, src):
				var ft = TypeFunctions.follow(tt);
				var useMin = switch (ft) {
					case TMono(_): true;
					case _: isVoid(ft);
				};
				if (useMin) {
					t = unifyMinForTypeSource(ctx, [e1, e2], src);
				} else {
					e1 = castOrUnify(ctx, tt, e1, e1.pos);
					e2 = castOrUnify(ctx, tt, e2, e2.pos);
					t = tt;
				}
		}
		return TypeFunctions.mk(TIf(e0, e1, e2), t, p);
	}

	static function typeReturn(ctx:TyperContext, e:Null<Expr>, withType:WithType, p:Position):TExpr {
		switch (e) {
			case null:
				var v = ctx.com.basic.tvoid;
				try {
					TypeUnification.unifyDefault(v, ctx.ret);
				} catch (_:UnifyError) {
					throw new TypingError("Void should be " + "the function's return type", p);
				}
				var expectVoid = switch (withType) {
					case WithType(t, _): isVoid(t);
					case Value(ImplicitReturn): true;
					case _: false;
				};
				return TypeFunctions.mk(TReturn(null), expectVoid ? v : monoOrDynamic(ctx, withType, p), p);
			case ex:
				var withExpected = isVoid(TypeFunctions.follow(ctx.ret)) ? WithTypeTools.noValue : WithTypeTools.withType(ctx.ret);
				var te = castOrUnify(ctx, ctx.ret, typeExpr(ctx, ex, withExpected), p);
				if (isVoid(TypeFunctions.follow(te.type))) {
					switch (te.expr) {
						case TConst(TNull): throw new TypingError("Cannot return null from Void-function", p);
						case _:
					}
					var t = monoOrDynamic(ctx, withType, p);
					return TypeFunctions.mk(TBlock([te, TypeFunctions.mk(TReturn(null), t, p)]), t, te.pos);
				}
				return TypeFunctions.mk(TReturn(te), monoOrDynamic(ctx, withType, p), p);
		}
	}

	public static function typeFunction(ctx:TyperContext, args:Array<TFuncArg>, ret:T, fmode:CurrentFun, bodyExpr:Null<Expr>, p:Position):TFunc {
		var oldInFunction = ctx.inFunction;
		var oldCurfun = ctx.curfun;
		var oldRet = ctx.ret;
		var oldLoop = ctx.inLoop;
		var restore = saveLocals(ctx);
		ctx.inFunction = true;
		ctx.curfun = fmode;
		ctx.ret = ret;
		ctx.inLoop = false;
		for (a in args) ctx.locals.set(a.v.name, a.v);
		function reset() {
			restore();
			ctx.inFunction = oldInFunction;
			ctx.curfun = oldCurfun;
			ctx.ret = oldRet;
			ctx.inLoop = oldLoop;
		}
		if (bodyExpr == null) {
			reset();
			throw new TypingError("Function body required", p);
		}
		var te = try typeExpr(ctx, bodyExpr, WithTypeTools.noValue) catch (e:TypingError) {
			reset();
			throw e;
		}
		// An inferred return type with no value-return settles to Void.
		switch (TypeFunctions.follow(ret)) {
			case TMono(_) if (!hasReturn(te)):
				try TypeUnification.unifyDefault(ctx.com.basic.tvoid, ret) catch (_:UnifyError) {}
			case _:
		}
		reset();
		return new TFunc(args, ret, te);
	}

	public static function typeNew(ctx:TyperContext, tp:PlacedTypePath, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		var t = Typeload.loadInstance(ctx.com, ctx.typeParams, tp.path, tp.pos, tp.path.tparams.length == 0);
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, tl):
				if (c.constructor == null) throw new TypingError(c.path.name + " does not have a constructor", p);
				var ctorType = TypeFunctions.applyParams(c.params, tl, c.constructor.type);
				var sig = switch (TypeFunctions.follow(ctorType)) {
					case TFun(s): s;
					case _: {args: [], ret: ctx.com.basic.tvoid};
				};
				var r = Calls.unifyCallArgs(ctx, el, sig.args, sig.ret, p);
				TypeFunctions.mk(TNew(c, tl, r.el), t, p);
			case _:
				throw new TypingError("This type cannot be constructed", p);
		};
	}

	static function hasReturn(e:TExpr):Bool {
		return switch (e.expr) {
			case TReturn(eo): eo != null;
			case TFunction(_) | TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_): false;
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2): hasReturn(e1) || hasReturn(e2);
			case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TThrow(e1) | TCast(e1, _) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1): hasReturn(e1);
			case TVarExpr(_, eo): eo != null && hasReturn(eo);
			case TObjectDecl(fields): Lambda.exists(fields, f -> hasReturn(f.expr));
			case TArrayDecl(el) | TBlock(el): Lambda.exists(el, hasReturn);
			case TCall(e1, el): hasReturn(e1) || Lambda.exists(el, hasReturn);
			case TNew(_, _, el): Lambda.exists(el, hasReturn);
			case TIf(e1, e2, e3): hasReturn(e1) || hasReturn(e2) || (e3 != null && hasReturn(e3));
			case TWhile(e1, e2, _): hasReturn(e1) || hasReturn(e2);
			case TSwitch(e1, cases, edef): hasReturn(e1) || Lambda.exists(cases, c -> Lambda.exists(c.values, hasReturn) || hasReturn(c.expr)) || (edef != null && hasReturn(edef));
			case TTry(e1, catches): hasReturn(e1) || Lambda.exists(catches, c -> hasReturn(c.expr));
		};
	}
}
