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
			return e;
		} catch (_:UnifyError) {}
		var casted = tryAbstractCast(ctx, e, t, p);
		if (casted != null) return casted;
		throw new TypingError("Cannot unify types", p);
	}

	static function doesUnify(a:T, b:T):Bool {
		return try { TypeUnification.unifyDefault(a, b); true; } catch (_:UnifyError) false;
	}

	// Implicit abstract conversion when plain unification fails: @:from on the target abstract or
	// @:to on the source abstract. A field cast calls the impl method; a bare from/to type is a
	// representation-preserving cast.
	static function tryAbstractCast(ctx:TyperContext, e:TExpr, t:T, p:Position):Null<TExpr> {
		switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _):
				if (a.impl != null) for (fc in a.fromField) if (doesUnify(e.type, fc.t)) return callImplCast(ctx, a.impl, fc.cf, e, t, p);
				for (ft in a.from) if (doesUnify(e.type, ft)) return TypeFunctions.mk(TCast(e, null), t, p);
			case _:
		}
		switch (TypeFunctions.follow(e.type)) {
			case TAbstract(a, _):
				if (a.impl != null) for (tc in a.toField) {
					if (tc.cf.params.length > 0) {
						// A generic @:to (return is a bare type parameter, as in Any) converts to anything.
						var monos = [for (_ in tc.cf.params) TypeFunctions.mkMono()];
						if (doesUnify(TypeFunctions.applyParams(tc.cf.params, monos, tc.t), t)) return TypeFunctions.mk(TCast(e, null), t, p);
					} else if (doesUnify(tc.t, t)) return callImplCast(ctx, a.impl, tc.cf, e, t, p);
				}
				for (tt in a.to) if (doesUnify(tt, t)) return TypeFunctions.mk(TCast(e, null), t, p);
			case _:
		}
		return null;
	}

	static function callImplCast(ctx:TyperContext, implC:TClass, cf:TClassField, e:TExpr, t:T, p:Position):TExpr {
		var implExpr = Texpr.makeTypeExpr(TClassDecl(implC), p);
		var staticExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p), FCall);
		return Calls.makeCall(ctx, staticExpr, [e], t, p);
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
						var acc = "_hx_comp";
						var decl = new Expr(EVars([{evName: {name: acc, pos: p}, evFinal: false, evStatic: false, evType: null, evExpr: new Expr(EArrayDecl([]), p), evMeta: []}]), p);
						var loop = comprehensionPush(acc, el[0]);
						return typeExpr(ctx, new Expr(EBlock([decl, loop, new Expr(EConst(CIdent(acc)), p)]), p), withType);
					case _:
						var expectedEt:Null<T> = switch (withType) {
							case WithType(wt, _): switch (TypeFunctions.follow(wt)) {
								case TInst(c, [t]) if (c.path.pack.length == 0 && c.path.name == "Array"): t;
								case _: null;
							};
							case _: null;
						};
						var ewt = expectedEt == null ? WithTypeTools.value : WithTypeTools.withType(expectedEt);
						var tl = [for (e in el) typeExpr(ctx, e, ewt)];
						var et = expectedEt != null ? expectedEt : (tl.length == 0 ? spawnMonomorph(ctx, p) : unifyMin(ctx, tl));
						TypeFunctions.mk(TArrayDecl(tl), ctx.com.basic.tarray(et), p);
				}
			case EObjectDecl(fields):
				var tfields:Array<TObjectField> = [];
				var anonFields = new haxe.ds.StringMap<TClassField>();
				var expected:Null<TAnon> = switch (withType) {
					case WithType(wt, _): switch (TypeFunctions.follow(wt)) { case TAnon(a): a; case _: null; };
					case _: null;
				};
				for (f in fields) {
					var fwt = WithTypeTools.value;
					if (expected != null) { var ef = expected.fields.get(f.name); if (ef != null) fwt = WithTypeTools.withType(ef.type); }
					var te = typeExpr(ctx, f.expr, fwt);
					tfields.push({key: {name: f.name, pos: f.pos, quotes: f.quotes}, expr: te});
					anonFields.set(f.name, TypeFunctions.mkField(f.name, te.type, f.pos, f.pos));
				}
				var t = TypeFunctions.mkAnon(new hxc.core.Ref(Const), anonFields);
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
			case ECast(e1, ct):
				var te = typeExpr(ctx, e1, WithTypeTools.value);
				if (ct == null) {
					TypeFunctions.mk(TCast(te, null), spawnMonomorph(ctx, p), p);
				} else {
					var t = Typeload.loadComplexType(ctx.com, ctx.typeParams, ct);
					var mt:Null<ModuleType> = switch (TypeFunctions.follow(t)) {
						case TInst(c, _): TClassDecl(c);
						case TEnum(en, _): TEnumDecl(en);
						case TAbstract(a, _): TAbstractDecl(a);
						case _: null;
					};
					TypeFunctions.mk(TCast(te, mt), t, p);
				}
			case EIs(_, _):
				throw new TypingError("is-expressions are not yet ported", p);
			case EDisplay(_, _):
				throw new TypingError("Display is not yet ported", p);
			case ECheckType(e1, th):
				var t = Typeload.loadComplexType(ctx.com, ctx.typeParams, th);
				var te = typeExpr(ctx, e1, WithTypeTools.withType(t));
				var te2 = castOrUnify(ctx, t, te, p);
				TypeUnification.typeIseqDefault(te2.type, t) ? te2 : TypeFunctions.mk(TCast(te2, null), t, p);
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
			case CRegexp(r, opt):
				var tp:PlacedTypePath = {path: {tpackage: [], tname: "EReg", tparams: [], tsub: null}, pos: p};
				var args = [new Expr(EConst(CString(r, SDoubleQuotes)), p), new Expr(EConst(CString(opt, SDoubleQuotes)), p)];
				typeNew(ctx, tp, args, withType, p);
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
				// Inside an abstract impl method, a bare call to a sibling member method threads `this`.
				var isAbsImpl = switch (ctx.curclass.kind) { case KAbstractImpl(_): true; case _: false; };
				if (isAbsImpl && smf.kind.match(Method(_)) && TypeFunctions.hasClassFieldFlag(smf, CfImpl) && ctx.locals.exists("this")) {
					var thisExpr = Texpr.makeLocal(ctx.locals.get("this"), p);
					return AKUsingField(FieldAccessTools.makeStaticExtensionAccess(ctx.curclass, smf, thisExpr, false, p));
				}
				var typeExpr = Texpr.makeTypeExpr(TClassDecl(ctx.curclass), p);
				return AKField(FieldAccessTools.create(typeExpr, smf, FieldAccessTools.getHost(ctx.curclass, smf), false, p));
			}
		}
		switch (withType) {
			case WithType(wt, _):
				switch (TypeFunctions.follow(wt)) {
					case TEnum(en, _) if (en.constrs.exists(i)):
						return Fields.enumConstructor(ctx, en, Texpr.makeTypeExpr(TEnumDecl(en), p), i, p);
					case _:
				}
			case _:
		}
		var bareEnum = findBareEnumConstructor(ctx, i);
		if (bareEnum != null) {
			var et = Texpr.makeTypeExpr(TEnumDecl(bareEnum), p);
			return Fields.enumConstructor(ctx, bareEnum, et, i, p);
		}
		if (i == "trace") {
			var logMt = ctx.com.getType({pack: ["haxe"], name: "Log"}, p, null);
			try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(logMt).module) catch (_:Dynamic) {}
			return Fields.typeField(ctx, Texpr.makeTypeExpr(logMt, p), "trace", p, mode, withType);
		}
		var mt = hxc.context.ModuleLoader.resolveBareType(ctx.com, ctx.com.currentModule, i, p);
		if (mt == null) {
			try mt = ctx.com.getType({pack: [], name: i}, p, null) catch (_:hxc.context.Context.ContextError) mt = null;
		}
		if (mt == null) throw new TypingError("Unknown identifier : " + i, p);
		// Hxc resolves field types in a separate pass; resolve the referenced module so its
		// statics have real types (idempotent via processed).
		try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
		switch (mt) { case TClassDecl(c): hxc.eval.EvalMacro.ensureBuilt(ctx.com, c); case _: }
		return AKExpr(Texpr.makeTypeExpr(mt, p));
	}

	// A bare identifier that names a constructor of an enum declared in the current module.
	static function findBareEnumConstructor(ctx:TyperContext, i:String):Null<TEnum> {
		var m = ctx.com.currentModule;
		if (m == null) return null;
		for (mt in m.types) switch (mt) {
			case TEnumDecl(en) if (en.constrs.exists(i)): return en;
			case _:
		}
		return null;
	}

	static function flattenIdentPath(e:ExprDef):Null<Array<String>> {
		return switch (e) {
			case EConst(CIdent(s)): [s];
			case EField(e1, f, _):
				var pre = flattenIdentPath(e1.expr);
				pre == null ? null : pre.concat([f]);
			case _: null;
		};
	}

	// Resolves a dotted ident chain (pack.Type.field...) as a package-qualified type path.
	static function tryTypePath(ctx:TyperContext, e:ExprDef, p:Position, mode:AccessMode, withType:WithType):Null<AccessKind> {
		var segs = flattenIdentPath(e);
		if (segs == null || segs.length < 2) return null;
		var typeIdx = -1;
		for (i in 0...segs.length) {
			var c = segs[i].charCodeAt(0);
			if (c >= "A".code && c <= "Z".code) { typeIdx = i; break; }
		}
		if (typeIdx < 0) return null;
		var pack = segs.slice(0, typeIdx);
		var name = segs[typeIdx];
		var rest = segs.slice(typeIdx + 1);
		var mt = try ctx.com.getType({pack: pack, name: name}, p, null) catch (_:Dynamic) return null;
		try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
		switch (mt) { case TClassDecl(c): hxc.eval.EvalMacro.ensureBuilt(ctx.com, c); case _: }
		var acc:AccessKind = AKExpr(Texpr.makeTypeExpr(mt, p));
		for (i in 0...rest.length) {
			var isLast = i == rest.length - 1;
			acc = Fields.typeField(ctx, accGet(ctx, acc), rest[i], p, isLast ? mode : MGet, isLast ? withType : WithTypeTools.value);
		}
		return acc;
	}

	// Lowers an array comprehension body so each tail expression pushes onto the accumulator.
	static function comprehensionPush(acc:String, e:Expr):Expr {
		return switch (e.expr) {
			case EFor(it, body): new Expr(EFor(it, comprehensionPush(acc, body)), e.pos);
			case EWhile(c, body, flag): new Expr(EWhile(c, comprehensionPush(acc, body), flag), e.pos);
			case EIf(c, e1, e2): new Expr(EIf(c, comprehensionPush(acc, e1), e2 == null ? null : comprehensionPush(acc, e2)), e.pos);
			case EBlock(l) if (l.length > 0):
				var nl = l.copy();
				nl[nl.length - 1] = comprehensionPush(acc, nl[nl.length - 1]);
				new Expr(EBlock(nl), e.pos);
			case _:
				new Expr(ECall(new Expr(EField(new Expr(EConst(CIdent(acc)), e.pos), "push", EFNormal), e.pos), [e]), e.pos);
		};
	}

	static function accGet(ctx:TyperContext, acc:AccessKind):TExpr {
		return switch (acc) {
			case AKExpr(e): e;
			case AKField(fa): FieldAccessTools.getFieldExpr(fa, FRead);
			case AKNo(_, p): throw new TypingError("This expression cannot be accessed for reading", p);
			case AKAccessor(fa):
				var getterAcc = Fields.typeField(ctx, fa.on, "get_" + fa.field.name, fa.pos, MCall([]), WithTypeTools.value);
				Calls.buildCall(ctx, getterAcc, [], WithTypeTools.value, fa.pos);
			case AKUsingAccessor(_): throw new TypingError("Property accessor reads are not yet ported (needs call dispatch, unit 5)", Position.nullPos);
			case AKUsingField(se):
				// Reading an abstract/static-extension field: a property calls its impl getter with the
				// receiver; otherwise read the impl field directly.
				var fa = se.access;
				var implC = FieldAccessTools.getHostClassRaise(fa.host);
				var getterCf = implC.statics.get("get_" + fa.field.name);
				if (getterCf != null) {
					var getterFa = FieldAccessTools.create(Texpr.makeTypeExpr(TClassDecl(implC), fa.pos), getterCf, FHStatic(implC), false, fa.pos);
					Calls.buildCall(ctx, AKUsingField({thisExpr: se.thisExpr, access: getterFa}), [], WithTypeTools.value, fa.pos);
				} else {
					FieldAccessTools.getFieldExpr(fa, FRead);
				}
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
				try {
					var te = typeExpr(ctx, e1, WithTypeTools.value);
					Fields.typeField(ctx, te, field, p, mode, withType);
				} catch (err:TypingError) {
					var acc = tryTypePath(ctx, EField(e1, field, EFNormal), p, mode, withType);
					if (acc == null) throw err;
					acc;
				}
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
				hxc.eval.EvalMacro.ensureBuilt(ctx.com, c);
				if (c.constructor == null) throw new TypingError(c.path.name + " does not have a constructor", p);
				var ctorType = TypeFunctions.applyParams(c.params, tl, c.constructor.type);
				var sig = switch (TypeFunctions.follow(ctorType)) {
					case TFun(s): s;
					case _: {args: [], ret: ctx.com.basic.tvoid};
				};
				var r = Calls.unifyCallArgs(ctx, el, sig.args, sig.ret, p);
				TypeFunctions.mk(TNew(c, tl, r.el), t, p);
			case TAbstract(a, _) if (a.impl != null && a.impl.statics.exists("_new")):
				// An abstract is constructed by calling its impl's _new static.
				var implExpr = Texpr.makeTypeExpr(TClassDecl(a.impl), p);
				Calls.buildCall(ctx, Fields.typeField(ctx, implExpr, "_new", p, MCall(el), withType), el, withType, p);
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
