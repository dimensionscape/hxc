package hxc.codegen.hl;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlContext;
import hxc.codegen.hl.HlAccess;

using hxc.codegen.hl.HlContext;

// The expression generator: a port of genhl.ml's get_enum_index, eval_var and eval_expr (lines 1539-2939)
// without the `$` intrinsics, TFor and TTry, which go through `unported` until Task 6 ports them.
class HlExpr {
	// A placeholder for an expression kind not ported yet: throws "hl: unported <kind>" and records the
	// function. The string is added to the table only after generation (HlGenerate.buildCode), so that
	// the indexes of the strings the ported code allocates are not shifted by it.
	static function unported(ctx:HlContext, kind:String, e:TExpr):Int {
		var s = ctx.allocTmp(HBytes);
		ctx.unportedKinds.push(kind);
		ctx.op(OString(s, -ctx.unportedKinds.length));
		ctx.op(OThrow(s));
		if (ctx.unported.indexOf(ctx.curName) < 0) ctx.unported.push(ctx.curName);
		return ctx.allocTmp(HlTypes.toType(ctx, e.type));
	}

	static function isCaughtLocal(e:TExpr):Bool {
		return switch e.expr {
			case TLocal(v): TypeFunctions.hasVarFlag(v, VCaught);
			case _: false;
		}
	}

	static inline function isPath(c:TClass, pack:Array<String>, name:String):Bool {
		return c.path.name == name && c.path.pack.join(".") == pack.join(".");
	}

	static function isEnumType(t:T):Bool {
		return TypeFunctions.follow(t).match(TEnum(_));
	}

	// genhl.ml: get_enum_index
	static function getEnumIndex(ctx:HlContext, v:TExpr):Int {
		var r = ctx.allocTmp(HI32);
		var re = evalExpr(ctx, v);
		ctx.op(ONullCheck(re));
		ctx.op(OEnumIndex(r, re));
		return r;
	}

	// genhl.ml: eval_var
	public static function evalVar(ctx:HlContext, v:TVar):Int {
		var idx = ctx.capturedIndex(v);
		if (idx == null) return ctx.allocVar(v, false);
		var r = ctx.allocTmp(HlTypes.toType(ctx, v.type));
		ctx.op(OEnumField(r, ctx.m.mcaptreg, 0, idx));
		return r;
	}

	// genhl.ml: eval_expr
	public static function evalExpr(ctx:HlContext, e:TExpr):Int {
		ctx.setCurpos(e.pos);
		switch e.expr {
			case TConst(c):
				switch c {
					case TInt(i):
						var r = ctx.allocTmp(HI32);
						ctx.op(OInt(r, ctx.allocI32(i)));
						return r;
					case TFloat(f):
						var r = ctx.allocTmp(HF64);
						ctx.op(OFloat(r, ctx.allocFloat(Std.parseFloat(f))));
						return r;
					case TBool(b):
						var r = ctx.allocTmp(HBool);
						ctx.op(OBool(r, b));
						return r;
					case TString(s):
						return HlCasts.makeString(ctx, s, e.pos);
					case TThis | TSuper:
						return 0; // first reg
					case TNull:
						var r = ctx.allocTmp(HlTypes.toType(ctx, e.type));
						ctx.op(ONull(r));
						return r;
				}
			case TVarExpr(v, init):
				if (init == null) {
					if (ctx.capturedIndex(v) == null) ctx.declVar(v);
				} else {
					var ri = HlCasts.evalTo(ctx, init, HlTypes.toType(ctx, v.type));
					var idx = ctx.capturedIndex(v);
					if (idx == null) {
						var r = ctx.allocVar(v, true);
						ctx.pushOp(OMov(r, ri));
						ctx.addAssign(v);
					} else {
						ctx.op(OSetEnumField(ctx.m.mcaptreg, idx, ri));
					}
				}
				return ctx.allocTmp(HVoid);
			case TLocal(v):
				// the call's arguments right to left: the target type first
				var t = HlTypes.toType(ctx, e.type);
				var idx = ctx.capturedIndex(v);
				var r = if (idx == null) {
					// we need to make a copy for cases such as (a - a++)
					var r = ctx.allocVar(v, false);
					var r2 = ctx.allocTmp(ctx.rtype(r));
					ctx.op(OMov(r2, r));
					r2;
				} else {
					var r = ctx.allocTmp(HlTypes.toType(ctx, v.type));
					ctx.op(OEnumField(r, ctx.m.mcaptreg, 0, idx));
					r;
				}
				return HlCasts.castTo(ctx, r, t, e.pos);
			case TReturn(null):
				ctx.beforeReturn();
				var r = ctx.allocTmp(HVoid);
				ctx.op(ORet(r));
				return ctx.allocTmp(HDyn);
			case TReturn(e1):
				var r = HlCasts.evalTo(ctx, e1, ctx.m.mret);
				ctx.beforeReturn();
				ctx.op(ORet(r));
				return ctx.allocTmp(HDyn);
			case TParenthesis(e1):
				return evalExpr(ctx, e1);
			case TBlock(el):
				var old = ctx.m.mdeclared;
				ctx.m.mdeclared = [];
				var r = -1;
				if (el.length == 0) r = ctx.allocTmp(HVoid);
				for (i in 0...el.length) {
					if (i == el.length - 1) r = evalExpr(ctx, el[i]); else evalExpr(ctx, el[i]);
				}
				// the OCaml list is walked head first: the last declared first
				var i = ctx.m.mdeclared.length - 1;
				while (i >= 0) {
					var vid = ctx.m.mdeclared[i--];
					var r = ctx.m.mvars.get(vid);
					if (r != null && r >= 0) {
						ctx.m.mvars.remove(vid);
						ctx.free(r);
					}
				}
				ctx.m.mdeclared = old;
				return r;
			case TCall({expr: TConst(TSuper), type: st}, el):
				switch TypeFunctions.follow(st) {
					case TInst(csup, _):
						var f = csup.constructor;
						if (f == null) HlContext.die();
						var r = ctx.allocTmp(HVoid);
						var el = HlAccess.evalArgs(ctx, el, HlTypes.toType(ctx, f.type), e.pos);
						ctx.op(OCallN(r, HlTypes.allocFid(ctx, csup, f), [0].concat(el)));
						return r;
					case _:
						return HlContext.die();
				}
			case TCall({expr: TIdent(s)}, _) if (s.charAt(0) == "$"):
				return unported(ctx, "intrinsic " + s, e);
			case TEnumIndex(v):
				return getEnumIndex(ctx, v);
			case TCall({expr: TField(_, FStatic(c, cf))}, [{expr: TCast(v, _)}]) if (isPath(c, [], "Type") && cf.name == "enumIndex" && isEnumType(v.type)):
				return getEnumIndex(ctx, v);
			case TCall({expr: TField(_, FStatic(c, cf))}, [v]) if (isPath(c, [], "Type") && cf.name == "enumIndex" && isEnumType(v.type)):
				return getEnumIndex(ctx, v);
			case TCall(e1 = {expr: TField(ef, FStatic(c, cf))}, [v]) if (isPath(c, [], "Reflect") && cf.name == "makeVarArgs"):
				var ec = TypeFunctions.mk(TField(ef, FStatic(c, c.statics.get("_makeVarArgs"))), e1.type, e1.pos);
				return evalExpr(ctx, TypeFunctions.mk(TCall(ec, [v]), e.type, e.pos));
			case TCall({expr: TField(_, FStatic(c, cf))}, [v, vt]) if (isPath(c, [], "Std") && (cf.name == "instance" || cf.name == "downcast")):
				var r = evalExpr(ctx, v);
				ctx.hold(r);
				var c = HlCasts.evalTo(ctx, vt, HlTypes.classType(ctx, ctx.baseType, [], false));
				ctx.hold(c);
				var rv = ctx.allocTmp(HlTypes.toType(ctx, e.type));
				var rb = ctx.allocTmp(HBool);
				ctx.op(OCall2(rb, HlTypes.allocFunPath(ctx, new Path(["hl"], "BaseType"), "check"), c, r));
				var jnext = ctx.jump(n -> OJFalse(rb, n));
				ctx.op(OMov(rv, HlCasts.unsafeCastTo(ctx, r, HlTypes.toType(ctx, e.type), e.pos, false)));
				var jend = ctx.jump(n -> OJAlways(n));
				jnext();
				ctx.op(ONull(rv));
				jend();
				ctx.free(r);
				ctx.free(c);
				return rv;
			case TCall(ec, args):
				return evalCall(ctx, e, ec, args);
			case TField(ec, FInstance(c, [t], cf)) if (isPath(c, [], "Array") && cf.name == "length" && HlTypes.toType(ctx, t) == HDyn):
				var r = ctx.allocTmp(HI32);
				var a = HlAccess.evalNullCheck(ctx, ec);
				ctx.op(OCall1(r, HlTypes.allocFunPath(ctx, new Path(["hl", "types"], "ArrayDyn"), "get_length"), a));
				return r;
			case TField(_, a):
				return evalField(ctx, e, a);
			case TObjectDecl(fl):
				return evalObjectDecl(ctx, e, fl);
			case TNew(c, pl, el):
				var c = HlTypes.resolveClass(ctx, c, pl, false);
				var r = ctx.allocTmp(HlTypes.classType(ctx, c, pl, false));
				ctx.op(ONew(r));
				ctx.hold(r);
				var constr = c.constructor;
				if (constr == null) {
					if (c.interfaces.length != 0) HlContext.die();
				} else if (constr.expr == null) {
					HlContext.abort(Globals.sTypePath(c.path) + " does not have a constructor", e.pos);
				} else {
					var rl = HlAccess.evalArgs(ctx, el, HlTypes.toType(ctx, constr.expr.type), e.pos);
					var ret = ctx.allocTmp(HVoid);
					var g = HlTypes.allocFid(ctx, c, constr);
					ctx.op(switch rl.length {
						case 0: OCall1(ret, g, r);
						case 1: OCall2(ret, g, r, rl[0]);
						case 2: OCall3(ret, g, r, rl[0], rl[1]);
						case 3: OCall4(ret, g, r, rl[0], rl[1], rl[2]);
						case _: OCallN(ret, g, [r].concat(rl));
					});
				}
				ctx.free(r);
				return r;
			case TIf(cond, eif, eelse):
				var t = HlTypes.toType(ctx, e.type);
				var out = ctx.allocTmp(t);
				var j = HlAccess.jumpExpr(ctx, cond, false);
				var isVoid = HlTypes.teq(t, HVoid);
				var rif = isVoid ? evalExpr(ctx, eif) : HlCasts.evalTo(ctx, eif, t);
				ctx.setCurpos(HlTypes.maxPos(eif));
				if (!isVoid) ctx.op(OMov(out, rif));
				if (eelse == null) {
					j();
				} else {
					var jexit = ctx.jump(i -> OJAlways(i));
					j();
					if (isVoid) evalExpr(ctx, eelse) else ctx.op(OMov(out, HlCasts.evalTo(ctx, eelse, t)));
					jexit();
				}
				return out;
			case TBinop(bop, e1, e2):
				return evalBinop(ctx, e, bop, e1, e2);
			case TUnop(Not, _, v):
				var tmp = ctx.allocTmp(HBool);
				var r = HlCasts.evalTo(ctx, v, HBool);
				ctx.op(ONot(tmp, r));
				return tmp;
			case TUnop(Neg, _, v):
				var t = HlTypes.toType(ctx, e.type);
				var tmp = ctx.allocTmp(t);
				var r = HlCasts.evalTo(ctx, v, t);
				ctx.op(ONeg(tmp, r));
				return tmp;
			case TUnop(Spread, _, _):
				return HlContext.die("Unexpected spread operator");
			case TUnop(NegBits, _, v):
				var t = HlTypes.toType(ctx, e.type);
				var tmp = ctx.allocTmp(t);
				var r = HlCasts.evalTo(ctx, v, t);
				var mask = switch t {
					case HUI8: 0xFF;
					case HUI16: 0xFFFF;
					case HI32: 0xFFFFFFFF;
					case _: HlContext.abort("Unsupported " + HlDump.tstr(t), e.pos);
				}
				ctx.hold(r);
				var r2 = ctx.allocTmp(t);
				ctx.free(r);
				ctx.op(OInt(r2, ctx.allocI32(mask)));
				ctx.op(OXor(tmp, r, r2));
				return tmp;
			case TUnop(uop, fix, v):
				return evalIncrDecr(ctx, e, uop, fix, v);
			case TFunction(f):
				return evalFunction(ctx, e, f);
			case TThrow(e1) if (e1.expr.match(TLocal(_)) && isCaughtLocal(e1)):
				// throwing a catch var means we want to rethrow an exception
				var r = ctx.allocTmp(HVoid);
				ctx.op(ORethrow(HlCasts.evalTo(ctx, e1, HDyn)));
				return r;
			case TThrow(v):
				ctx.op(OThrow(HlCasts.evalTo(ctx, v, HDyn)));
				return ctx.allocTmp(HDyn);
			case TWhile(cond, eloop, NormalWhile):
				var oldb = ctx.m.mbreaks, oldc = ctx.m.mcontinues, oldtrys = ctx.m.mloopTrys;
				ctx.m.mbreaks = [];
				ctx.m.mcontinues = [];
				ctx.m.mloopTrys = ctx.m.mtrys;
				var continuePos = ctx.currentPos();
				var ret = ctx.jumpBack();
				var j = HlAccess.jumpExpr(ctx, cond, false);
				evalExpr(ctx, eloop);
				ctx.setCurpos(HlTypes.maxPos(e));
				ret();
				j();
				var here = ctx.currentPos();
				for (f in ctx.m.mbreaks) f(here);
				for (f in ctx.m.mcontinues) f(continuePos);
				ctx.m.mbreaks = oldb;
				ctx.m.mcontinues = oldc;
				ctx.m.mloopTrys = oldtrys;
				return ctx.allocTmp(HVoid);
			case TWhile(cond, eloop, DoWhile):
				var oldb = ctx.m.mbreaks, oldc = ctx.m.mcontinues, oldtrys = ctx.m.mloopTrys;
				ctx.m.mbreaks = [];
				ctx.m.mcontinues = [];
				ctx.m.mloopTrys = ctx.m.mtrys;
				var continuePos = ctx.currentPos();
				var ret = ctx.jumpBack();
				evalExpr(ctx, eloop);
				var j = HlAccess.jumpExpr(ctx, cond, false);
				ret();
				j();
				var here = ctx.currentPos();
				for (f in ctx.m.mbreaks) f(here);
				for (f in ctx.m.mcontinues) f(continuePos);
				ctx.m.mbreaks = oldb;
				ctx.m.mcontinues = oldc;
				ctx.m.mloopTrys = oldtrys;
				return ctx.allocTmp(HVoid);
			case TCast({expr: TCast(v, null)}, null) if (!HlTypes.isNumber(HlTypes.toType(ctx, e.type))):
				// coalesce double casts into a single runtime check - temp fix for Map accesses
				return evalExpr(ctx, TypeFunctions.mk(TCast(v, null), e.type, e.pos));
			case TCast(v, null):
				var t = HlTypes.toType(ctx, e.type);
				var rv = evalExpr(ctx, v);
				switch t {
					case HF32 | HF64 if (HlTypes.unsigned(v.type)):
						var r = ctx.allocTmp(t);
						ctx.op(OToUFloat(r, rv));
						return r;
					case HDyn if (ctx.rtype(rv).match(HFun(_))):
						// if called, a HDyn method will return HDyn, not its usual return type
						var r = ctx.allocTmp(t);
						ctx.op(OMov(r, rv));
						return r;
					case _:
						return HlCasts.castTo(ctx, rv, t, e.pos, true);
				}
			case TArrayDecl(el):
				return evalArrayDecl(ctx, e, el);
			case TArray(_):
				switch HlAccess.getAccess(ctx, e) {
					case AArray(a, at, vt, idx):
						return HlAccess.arrayRead(ctx, a, at, vt, idx, e.pos);
					case _:
						return HlContext.die();
				}
			case TMeta(_, e1):
				return evalExpr(ctx, e1);
			case TFor(_):
				return unported(ctx, "TFor", e);
			case TSwitch(en, cases, def):
				return evalSwitch(ctx, e, en, cases, def);
			case TEnumParameter(ec, f, index):
				var pt, isSingle;
				switch HlTypes.toType(ctx, ec.type) {
					case HEnum(en):
						pt = en.efields[f.index].t[index];
						isSingle = en.efields.length == 1;
					case _:
						return HlContext.die();
				}
				var er = evalExpr(ctx, ec);
				if (isSingle) ctx.op(ONullCheck(er)); // #7560
				var r = ctx.allocTmp(pt);
				ctx.op(OEnumField(r, er, f.index, index));
				return HlCasts.castTo(ctx, r, HlTypes.toType(ctx, e.type), e.pos);
			case TContinue:
				ctx.beforeBreakContinue();
				var pos = ctx.currentPos();
				ctx.op(OJAlways(-1)); // loop
				ctx.m.mcontinues.push(target -> ctx.setOp(pos, OJAlways(target - (pos + 1))));
				return ctx.allocTmp(HVoid);
			case TBreak:
				ctx.beforeBreakContinue();
				var pos = ctx.currentPos();
				ctx.op(OJAlways(-1)); // loop
				ctx.m.mbreaks.push(target -> ctx.setOp(pos, OJAlways(target - (pos + 1))));
				return ctx.allocTmp(HVoid);
			case TTry(_):
				return unported(ctx, "TTry", e);
			case TTypeExpr(t):
				return HlTypes.typeValue(ctx, t, e.pos);
			case TCast(ev, _):
				var t = HlTypes.toType(ctx, e.type);
				var re = evalExpr(ctx, ev);
				var rt = ctx.allocTmp(t);
				if (HlTypes.safeCast(ctx.rtype(re), t)) {
					ctx.op(OMov(rt, re));
				} else switch TypeFunctions.followWithAbstracts(e.type) {
					case TInst(c, _) if (TypeFunctions.hasClassFlag(c, CInterface)):
						ctx.hold(re);
						var c = HlCasts.evalTo(ctx, TypeFunctions.mk(TTypeExpr(TClassDecl(c)), TypeFunctions.tDynamic, e.pos),
							HlTypes.classType(ctx, ctx.baseType, [], false));
						ctx.hold(c);
						var rb = ctx.allocTmp(HBool);
						ctx.op(OCall2(rb, HlTypes.allocFunPath(ctx, new Path(["hl"], "BaseType"), "check"), c, re));
						var jnext = ctx.jump(n -> OJTrue(rb, n));
						var jnext2 = ctx.jump(n -> OJNull(re, n));
						ctx.op(OThrow(HlCasts.makeString(ctx, "Cast error", e.pos)));
						jnext();
						jnext2();
						ctx.op(OMov(rt, HlCasts.unsafeCastTo(ctx, re, HlTypes.toType(ctx, e.type), e.pos, false)));
						ctx.free(c);
						ctx.free(re);
					case _:
						ctx.op(OSafeCast(rt, re));
				}
				return rt;
			case TIdent(s):
				return HlContext.abort("Unbound identifier " + s, e.pos);
		}
	}

	static function isValidMethod(ctx:HlContext, t:T):Bool {
		return switch TypeFunctions.follow(t) {
			case TFun(sig):
				switch TypeFunctions.follow(sig.ret) {
					case TInst({kind: KTypeParameter(tl)}, _):
						// don't allow if we have a constraint virtual, see hxbit.Serializer.getRef
						!Lambda.exists(tl, t -> HlTypes.toType(ctx, t).match(HVirtual(_)));
					case _: false;
				}
			case _: false;
		}
	}

	// eval_expr's TCall (ec, args)
	static function evalCall(ctx:HlContext, e:TExpr, ec:TExpr, args:Array<TExpr>):Int {
		var tfun = HlTypes.realType(ctx, ec);
		function el() return HlAccess.evalArgs(ctx, args, tfun, e.pos);
		var ret = ctx.allocTmp(switch tfun {
			case HFun(_, r): r;
			case _: HDyn;
		});
		var defRet:Null<Int> = null;
		switch HlAccess.getAccess(ctx, ec) {
			case AStaticFun(f):
				var el = el();
				ctx.op(switch el.length {
					case 0: OCall0(ret, f);
					case 1: OCall1(ret, f, el[0]);
					case 2: OCall2(ret, f, el[0], el[1]);
					case 3: OCall3(ret, f, el[0], el[1], el[2]);
					case 4: OCall4(ret, f, el[0], el[1], el[2], el[3]);
					case _: OCallN(ret, f, el);
				});
			case AInstanceFun(ethis, f):
				var r = HlAccess.evalNullCheck(ctx, ethis);
				ctx.hold(r);
				var el = [r].concat(el());
				ctx.free(r);
				ctx.op(switch el.length {
					case 1: OCall1(ret, f, el[0]);
					case 2: OCall2(ret, f, el[0], el[1]);
					case 3: OCall3(ret, f, el[0], el[1], el[2]);
					case 4: OCall4(ret, f, el[0], el[1], el[2], el[3]);
					case _: OCallN(ret, f, el);
				});
			case AInstanceProto({expr: TConst(TThis)}, fid):
				ctx.op(OCallThis(ret, fid, el()));
			case AInstanceProto(ethis, fid) | AVirtualMethod(ethis, fid):
				var r = HlAccess.evalNullCheck(ctx, ethis);
				ctx.hold(r);
				var el = [r].concat(el());
				ctx.free(r);
				ctx.op(OCallMethod(ret, fid, el));
			case AEnum(_, index):
				ctx.op(OMakeEnum(ret, index, el()));
			case AArray(a, at, vt, idx):
				var r = HlAccess.arrayRead(ctx, a, at, vt, idx, ec.pos);
				ctx.hold(r);
				ctx.op(ONullCheck(r));
				ctx.op(OCallClosure(ret, r, el())); // if it's a value, it's a closure
				ctx.free(r);
			case _:
				// don't use real_type here
				var tfun = HlTypes.toType(ctx, ec.type);
				var r = HlAccess.evalNullCheck(ctx, ec);
				ctx.hold(r);
				var el = HlAccess.evalArgs(ctx, args, tfun, e.pos);
				ctx.free(r);
				var ret = ctx.allocTmp(switch tfun {
					case HFun(_, r): r;
					case _: HDyn;
				});
				ctx.op(OCallClosure(ret, r, el)); // if it's a value, it's a closure
				defRet = HlCasts.castTo(ctx, ret, HlTypes.toType(ctx, e.type), e.pos, true);
		}
		if (defRet != null) return defRet;
		var rt = HlTypes.toType(ctx, e.type);
		switch ec.expr {
			case TField(_, FInstance(_, _, {kind: Method(MethNormal | MethInline), type: t})) if (isValidMethod(ctx, t)):
				// let's trust the compiler when it comes to casting the return value from a type parameter
				return HlCasts.unsafeCastTo(ctx, ret, rt, e.pos);
			case _:
				return HlCasts.castTo(ctx, ret, rt, e.pos, true);
		}
	}

	// eval_expr's TField (ec, a)
	static function evalField(ctx:HlContext, e:TExpr, a:TFieldAccess):Int {
		var r = ctx.allocTmp(HlTypes.toType(ctx, HlTypes.fieldType(ctx, a, e.pos)));
		switch HlAccess.getAccess(ctx, e) {
			case AGlobal(g):
				ctx.op(OGetGlobal(r, g));
			case AStaticVar(g, t, fid):
				var o = ctx.allocTmp(t);
				ctx.op(OGetGlobal(o, g));
				ctx.op(OField(r, o, fid));
			case AStaticFun(f):
				ctx.op(OStaticClosure(r, f));
			case AInstanceFun(ethis, f):
				ctx.op(OInstanceClosure(r, f, HlAccess.evalNullCheck(ctx, ethis)));
			case AInstanceField(ethis, fid):
				var robj = HlAccess.evalNullCheck(ctx, ethis);
				ctx.op(switch ethis.expr {
					case TConst(TThis): OGetThis(r, fid);
					case _: OField(r, robj, fid);
				});
			case AInstanceProto(ethis, fid) | AVirtualMethod(ethis, fid):
				var robj = HlAccess.evalNullCheck(ctx, ethis);
				switch ctx.rtype(robj) {
					case HObj(_):
						ctx.op(OVirtualClosure(r, robj, fid));
					case HVirtual(vp):
						ctx.op(ODynGet(r, robj, vp.vfields[fid].nameIndex));
					case _:
						HlContext.die();
				}
			case ADynamic(ethis, f):
				var robj = HlAccess.evalNullCheck(ctx, ethis);
				ctx.op(ODynGet(r, robj, f));
			case AEnum(en, index):
				var curFid = ctx.cfids.arr.length;
				var name = en.names[index];
				var fid = HlTypes.allocFunPath(ctx, en.path, name);
				if (fid == curFid) {
					var ef = en.constrs.get(name);
					var sig = switch TypeFunctions.follow(ef.type) {
						case TFun(sig): sig;
						case _: HlContext.die();
					}
					var p = ef.pos;
					var eargs:Array<TFuncArg> = [for (a in sig.args) {
						v: TypeFunctions.allocVar(VGenerated, a.name, a.t, en.pos),
						c: a.opt ? TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, Position.nullPos) : null
					}];
					var ecall = TypeFunctions.mk(TCall(e, [for (a in eargs) TypeFunctions.mk(TLocal(a.v), a.v.type, p)]), sig.ret, p);
					var f = new TFunc(eargs, sig.ret, TypeFunctions.mk(TReturn(ecall), ctx.com.basic.tvoid, p));
					HlFunctions.makeFun(ctx, {cls: "", name: ""}, fid, f, null, null);
				}
				ctx.op(OStaticClosure(r, fid));
			case ANone | ALocal(_) | AArray(_) | ACaptured(_):
				HlContext.abort("Invalid access", e.pos);
		}
		var toT = HlTypes.toType(ctx, e.type);
		return switch toT {
			case HFun(_): HlCasts.castTo(ctx, r, toT, e.pos);
			case _: HlCasts.unsafeCastTo(ctx, r, toT, e.pos);
		}
	}

	// eval_expr's TObjectDecl fl
	static function evalObjectDecl(ctx:HlContext, e:TExpr, fl:Array<TObjectField>):Int {
		var t = HlTypes.toType(ctx, e.type);
		switch t {
			case HVirtual(vp) if (vp.vfields.length == fl.length
				&& !Lambda.exists(fl, f -> f.key.name == "toString" && HlTypes.isToString(f.expr.type))):
				var r = ctx.allocTmp(t);
				ctx.op(ONew(r));
				ctx.hold(r);
				for (f in fl) {
					var fidx = vp.vindex.get(f.key.name);
					if (fidx == null) HlContext.die();
					var ft = vp.vfields[fidx].t;
					var v = HlCasts.evalTo(ctx, f.expr, ft);
					ctx.op(OSetField(r, fidx, v));
				}
				ctx.free(r);
				return r;
			case _:
				var r = ctx.allocTmp(HDynObj);
				ctx.op(ONew(r));
				ctx.hold(r);
				var a = switch TypeFunctions.follow(e.type) {
					case TAnon(a): a;
					case TDynamic(null): null;
					case _: HlContext.die();
				}
				for (f in fl) {
					var s = f.key.name, ev = f.expr;
					var cf = a == null ? null : a.fields.get(s);
					var ft = cf == null ? ev.type : cf.type;
					var v = HlCasts.evalTo(ctx, ev, HlTypes.toType(ctx, ft));
					ctx.op(ODynSet(r, ctx.allocString(s), v));
					if (s == "toString" && HlTypes.isToString(ev.type)) {
						var f = ctx.allocTmp(HFun([], HBytes));
						ctx.op(OInstanceClosure(f, HlTypes.allocFunPath(ctx, new Path([], "String"), "call_toString"), r));
						ctx.op(ODynSet(r, ctx.allocString("__string"), f));
					}
				}
				ctx.free(r);
				return HlCasts.castTo(ctx, r, HlTypes.toType(ctx, e.type), e.pos);
		}
	}

	// eval_expr's TFunction f
	static function evalFunction(ctx:HlContext, e:TExpr, f:TFunc):Int {
		var fid = HlTypes.allocFunctionName(ctx, "function#" + ctx.cfids.arr.length);
		var capt = HlFunctions.makeFun(ctx, {cls: "", name: ""}, fid, f, null, ctx.m.mcaptured);
		var r = ctx.allocTmp(HlTypes.toType(ctx, e.type));
		if (capt == ctx.m.mcaptured) {
			ctx.op(OInstanceClosure(r, fid, ctx.m.mcaptreg));
		} else if (capt.cVars.length == 0) {
			ctx.op(OStaticClosure(r, fid));
		} else if (capt.cVars.length == 1 && !capt.cGroup) {
			ctx.op(OInstanceClosure(r, fid, evalVar(ctx, capt.cVars[0])));
		} else {
			var env = ctx.allocTmp(capt.cType);
			ctx.op(OEnumAlloc(env, 0));
			ctx.hold(env);
			for (i in 0...capt.cVars.length) ctx.op(OSetEnumField(env, i, evalVar(ctx, capt.cVars[i])));
			ctx.free(env);
			ctx.op(OInstanceClosure(r, fid, env));
		}
		return r;
	}

	// eval_expr's TArrayDecl el
	static function evalArrayDecl(ctx:HlContext, e:TExpr, el:Array<TExpr>):Int {
		var r = ctx.allocTmp(HlTypes.toType(ctx, e.type));
		var et = switch TypeFunctions.follow(e.type) {
			case TInst(_, [t]): HlTypes.toType(ctx, t);
			case _: HlContext.die();
		}
		function arrayBytes(bits:Int, t:HlType, tname:String, getOp:(Int, Int, Int) -> HlOp) {
			var b = ctx.allocTmp(HBytes);
			var size = ctx.regInt(el.length << bits);
			ctx.op(OCall1(b, HlTypes.allocStd(ctx, "alloc_bytes", [HI32], HBytes), size));
			var idx = ctx.regInt(0);
			ctx.hold(idx);
			ctx.hold(b);
			for (e in el) {
				var r = HlCasts.evalTo(ctx, e, t);
				ctx.hold(r);
				ctx.op(getOp(b, ctx.shl(idx, bits), r));
				ctx.free(r);
				ctx.op(OIncr(idx));
			}
			ctx.free(b);
			ctx.free(idx);
			// the constructor's arguments right to left
			var len = ctx.regInt(el.length);
			ctx.op(OCall2(r, HlTypes.allocFunPath(ctx, new Path(["hl", "types"], "ArrayBase"), "alloc" + tname), b, len));
		}
		switch et {
			case HI32:
				arrayBytes(2, HI32, "I32", (b, i, r) -> OSetMem(b, i, r));
			case HUI16:
				arrayBytes(1, HI32, "UI16", (b, i, r) -> OSetUI16(b, i, r));
			case HF32:
				arrayBytes(2, HF32, "F32", (b, i, r) -> OSetMem(b, i, r));
			case HF64:
				arrayBytes(3, HF64, "F64", (b, i, r) -> OSetMem(b, i, r));
			case _:
				var at = HlTypes.isDynamic(et) ? et : HDyn;
				var a = ctx.allocTmp(HArray);
				var rt = ctx.allocTmp(HType);
				ctx.op(OType(rt, at));
				var size = ctx.regInt(el.length);
				ctx.op(OCall2(a, HlTypes.allocStd(ctx, "alloc_array", [HType, HI32], HArray), rt, size));
				ctx.hold(a);
				for (i in 0...el.length) {
					var r = HlCasts.evalTo(ctx, el[i], at);
					ctx.op(OSetArray(a, ctx.regInt(i), r));
				}
				ctx.free(a);
				var tmp = HlTypes.teq(et, HDyn) ? ctx.allocTmp(HlTypes.classType(ctx, ctx.arrayImpl.aobj, [], false)) : r;
				ctx.op(OCall1(tmp, HlTypes.allocFunPath(ctx, new Path(["hl", "types"], "ArrayObj"), "alloc"), a));
				if (tmp != r) {
					var re = ctx.allocTmp(HBool);
					ctx.op(OBool(re, true));
					var ren = ctx.allocTmp(HRef(HBool));
					ctx.op(ORef(ren, re));
					ctx.op(OCall2(r, HlTypes.allocFunPath(ctx, new Path(["hl", "types"], "ArrayDyn"), "alloc"), tmp, ren));
				}
		}
		return r;
	}

	// eval_expr's TSwitch's get_int: the case value as an Int, or null (OCaml raises Exit)
	static function switchInt(e:TExpr):Null<Int> {
		return switch e.expr {
			case TConst(TInt(i)): i;
			case _: null;
		}
	}

	// eval_expr's TSwitch (en, cases, def)
	static function evalSwitch(ctx:HlContext, e:TExpr, en:TExpr, cases:Array<TSwitchCase>, def:Null<TExpr>):Int {
		var rt = HlTypes.toType(ctx, e.type);
		var r = ctx.allocTmp(rt);
		var isVoid = HlTypes.teq(rt, HVoid);
		// the checks that raise Exit, made before anything is generated (they generate nothing)
		var max = -1;
		var ints = cases.length > 0;
		for (c in cases) {
			for (v in c.values) {
				var i = switchInt(v);
				if (i == null || i < 0) {
					ints = false;
					break;
				}
				if (i > max) max = i;
			}
			if (!ints) break;
		}
		if (max > 255) ints = false;
		if (ints) {
			var ridx = HlCasts.evalTo(ctx, en, HI32);
			var indexes = [for (_ in 0...max + 1) 0];
			ctx.op(OSwitch(ridx, indexes, 0));
			var switchPos = ctx.currentPos();
			if (def == null) {
				if (!isVoid) ctx.setDefault(r);
			} else {
				var re = HlCasts.evalTo(ctx, def, rt);
				if (!isVoid) ctx.op(OMov(r, re));
			}
			// a prepended list in OCaml: here the head is the last element
			var jends = [ctx.jump(i -> OJAlways(i))];
			for (c in cases) {
				for (v in c.values) indexes[switchInt(v)] = ctx.currentPos() - switchPos;
				var re = HlCasts.evalTo(ctx, c.expr, rt);
				if (!isVoid) ctx.op(OMov(r, re));
				jends.push(ctx.jump(i -> OJAlways(i)));
			}
			ctx.setOp(switchPos - 1, OSwitch(ridx, indexes, ctx.currentPos() - switchPos));
			var i = jends.length;
			while (i > 0) jends[--i]();
		} else {
			// a prepended list in OCaml: here the head is the last element
			var jends:Array<Void->Void> = [];
			var rvalue = evalExpr(ctx, en);
			function loop(c:TSwitchCase):Void->Void {
				ctx.hold(rvalue);
				var ok = [for (v in c.values) {
					var ct = HlTypes.commonType(ctx, en, v, true, v.pos);
					switch [v.expr, ct] {
						case [TConst(TString(str)), HObj({pname: "String"})]:
							var jnull = ctx.jump(n -> OJNull(rvalue, n));

							// compare len
							var rlen = ctx.allocTmp(HI32);
							ctx.op(OField(rlen, rvalue, 1));
							ctx.hold(rlen);
							var u = HlTypes.toUtf8(str, v.pos);
							var rlen2 = ctx.regInt(u.count);
							var jdiff = ctx.jump(n -> OJNotEq(rlen, rlen2, n));
							ctx.free(rlen);

							// compare data
							var rbytes = ctx.allocTmp(HBytes);
							ctx.op(OField(rbytes, rvalue, 0));
							ctx.hold(rbytes);
							var rbytes2 = ctx.allocTmp(HBytes);
							ctx.op(OString(rbytes2, ctx.allocString(u.s)));
							var result = ctx.allocTmp(HI32);
							ctx.op(OCall3(result, HlTypes.allocStd(ctx, "string_compare", [HBytes, HBytes, HI32], HI32), rbytes, rbytes2, rlen));
							ctx.free(rbytes);

							ctx.hold(result);
							var zero = ctx.regInt(0);
							var jok = ctx.jump(n -> OJEq(result, zero, n));
							ctx.free(result);

							jnull();
							jdiff();
							jok;
						case _:
							var r = HlCasts.evalTo(ctx, v, ct);
							ctx.jump(n -> OJEq(r, rvalue, n));
					}
				}];
				ctx.free(rvalue);
				return () -> {
					for (f in ok) f();
					var re = HlCasts.evalTo(ctx, c.expr, rt);
					if (!isVoid) ctx.op(OMov(r, re));
					jends.push(ctx.jump(n -> OJAlways(n)));
				};
			}
			var all = [for (c in cases) loop(c)];
			if (def == null) {
				if (!isVoid) ctx.op(ONull(r));
			} else {
				var rdef = HlCasts.evalTo(ctx, def, rt);
				if (!isVoid) ctx.op(OMov(r, rdef));
			}
			jends.push(ctx.jump(n -> OJAlways(n)));
			for (f in all) f();
			var i = jends.length;
			while (i > 0) jends[--i]();
		}
		return r;
	}

	// eval_expr's TBinop's binop: the op itself, on registers already evaluated
	static function binop(ctx:HlContext, e:TExpr, bop:Binop, e1:TExpr, e2:TExpr, r:Int, a:Int, b:Int):Void {
		function isUnsigned() return HlTypes.unsignedOp(e1, e2);
		function boolop(f:Int->HlOp) {
			var j = ctx.jump(f);
			ctx.op(OBool(r, false));
			ctx.op(OJAlways(1));
			j();
			ctx.op(OBool(r, true));
		}
		switch bop {
			case OpLte: boolop(d -> isUnsigned() ? OJUGte(b, a, d) : OJSLte(a, b, d));
			case OpGt: boolop(d -> isUnsigned() ? OJULt(b, a, d) : OJSGt(a, b, d));
			case OpGte: boolop(d -> isUnsigned() ? OJUGte(a, b, d) : OJSGte(a, b, d));
			case OpLt: boolop(d -> isUnsigned() ? OJULt(a, b, d) : OJSLt(a, b, d));
			case OpEq: boolop(d -> OJEq(a, b, d));
			case OpNotEq: boolop(d -> OJNotEq(a, b, d));
			case OpAdd:
				switch ctx.rtype(r) {
					case HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64:
						ctx.op(OAdd(r, a, b));
					case HObj(p) if (p.pname == "String"):
						// the constructor's arguments right to left
						var sb = HlCasts.toString(ctx, b, e2.pos);
						var sa = HlCasts.toString(ctx, a, e1.pos);
						ctx.op(OCall2(r, HlTypes.allocFunPath(ctx, new Path([], "String"), "__add__"), sa, sb));
					case HDyn:
						ctx.op(OCall2(r, HlTypes.allocFunPath(ctx, new Path([], "Std"), "__add__"), a, b));
					case t:
						HlContext.abort("Cannot add " + HlDump.tstr(t), e.pos);
				}
			case OpSub | OpMult | OpMod | OpDiv:
				switch ctx.rtype(r) {
					case HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64:
						switch bop {
							case OpSub: ctx.op(OSub(r, a, b));
							case OpMult: ctx.op(OMul(r, a, b));
							case OpMod: ctx.op(HlTypes.unsigned(e1.type) ? OUMod(r, a, b) : OSMod(r, a, b));
							case OpDiv: ctx.op(OSDiv(r, a, b)); // don't use UDiv since both operands are float already
							case _: HlContext.die();
						}
					case HDyn:
						var n = ctx.regInt(switch bop {
							case OpSub: 1;
							case OpMult: 2;
							case OpMod: 3;
							case OpDiv: 4;
							case _: HlContext.die();
						});
						ctx.op(OCall3(r, HlTypes.allocStd(ctx, "dyn_op", [HI32, HDyn, HDyn], HDyn), n, a, b));
					case _:
						HlContext.die();
				}
			case OpShl | OpShr | OpUShr | OpAnd | OpOr | OpXor:
				switch ctx.rtype(r) {
					case HUI8 | HUI16 | HI32 | HI64:
						switch bop {
							case OpShl: ctx.op(OShl(r, a, b));
							case OpShr: ctx.op(HlTypes.unsigned(e1.type) ? OUShr(r, a, b) : OSShr(r, a, b));
							case OpUShr: ctx.op(OUShr(r, a, b));
							case OpAnd: ctx.op(OAnd(r, a, b));
							case OpOr: ctx.op(OOr(r, a, b));
							case OpXor: ctx.op(OXor(r, a, b));
							case _:
						}
					case HDyn:
						var n = ctx.regInt(switch bop {
							case OpShl: 5;
							case OpShr: 6;
							case OpUShr: 7;
							case OpAnd: 8;
							case OpOr: 9;
							case OpXor: 10;
							case _: HlContext.die();
						});
						ctx.op(OCall3(r, HlTypes.allocStd(ctx, "dyn_op", [HI32, HDyn, HDyn], HDyn), n, a, b));
					case _:
						HlContext.die();
				}
			case OpAssignOp(bop):
				binop(ctx, e, bop, e1, e2, r, a, b);
			case _:
				HlContext.die();
		}
	}

	// eval_expr's TBinop (bop, e1, e2)
	static function evalBinop(ctx:HlContext, e:TExpr, bop:Binop, e1:TExpr, e2:TExpr):Int {
		switch bop {
			case OpLte | OpGt | OpGte | OpLt | OpEq | OpNotEq:
				var r = ctx.allocTmp(HBool);
				var t = HlTypes.commonType(ctx, e1, e2, bop == OpEq || bop == OpNotEq, e.pos);
				var a = HlCasts.evalTo(ctx, e1, t);
				ctx.hold(a);
				var b = HlCasts.evalTo(ctx, e2, t);
				ctx.free(a);
				binop(ctx, e, bop, e1, e2, r, a, b);
				return r;
			case OpAdd | OpSub | OpMult | OpDiv | OpMod | OpShl | OpShr | OpUShr | OpAnd | OpOr | OpXor:
				var t = switch HlTypes.toType(ctx, e.type) {
					case HNull(t): t;
					case t: t;
				}
				var convString = bop == OpAdd && HlTypes.isString(t);
				function evalOperand(e:TExpr):Int {
					if (convString) {
						var r = evalExpr(ctx, e);
						return HlCasts.toString(ctx, r, e.pos);
					}
					return HlCasts.evalTo(ctx, e, t);
				}
				var r = ctx.allocTmp(t);
				var a = evalOperand(e1);
				ctx.hold(a);
				var b = evalOperand(e2);
				ctx.free(a);
				binop(ctx, e, bop, e1, e2, r, a, b);
				return r;
			case OpAssign:
				function value() {
					// the call's arguments right to left
					var t = HlTypes.realType(ctx, e1);
					return HlCasts.evalTo(ctx, e2, t);
				}
				switch HlAccess.getAccess(ctx, e1) {
					case AGlobal(g):
						var r = value();
						ctx.op(OSetGlobal(g, r));
						return r;
					case AStaticVar(g, t, fid):
						var r = value();
						ctx.hold(r);
						var o = ctx.allocTmp(t);
						ctx.free(r);
						ctx.op(OGetGlobal(o, g));
						ctx.op(OSetField(o, fid, r));
						return r;
					case AInstanceField({expr: TConst(TThis)}, fid):
						var r = value();
						ctx.op(OSetThis(fid, r));
						return r;
					case AInstanceField(ethis, fid):
						var rthis = HlAccess.evalNullCheck(ctx, ethis);
						ctx.hold(rthis);
						var r = value();
						ctx.free(rthis);
						ctx.op(OSetField(rthis, fid, r));
						return r;
					case ALocal(v, l):
						var r = value();
						ctx.pushOp(OMov(l, r));
						ctx.addAssign(v);
						return r;
					case AArray(ra, at, _, ridx):
						ctx.hold(ra);
						ctx.hold(ridx);
						var v = HlCasts.castTo(ctx, value(), switch at {
							case HUI16 | HUI8: HI32;
							case _: at;
						}, e.pos);
						ctx.hold(v);
						// bounds check against length
						switch at {
							case HDyn:
								// call setDyn(); the constructor's arguments right to left
								var cv = HlCasts.castTo(ctx, v, HlTypes.isDynamic(at) ? at : HDyn, e.pos);
								ctx.op(OCallMethod(ctx.allocTmp(HVoid), 1, [ra, ridx, cv]));
							case _:
								var len = ctx.allocTmp(HI32);
								ctx.op(OField(len, ra, 0)); // length
								var j = ctx.jump(i -> OJULt(ridx, len, i));
								var fexpand = HlTypes.allocFunPath(ctx, HlTypes.arrayClass(ctx, at).path, "__expand");
								ctx.op(OCall2(ctx.allocTmp(HVoid), fexpand, ra, ridx));
								j();
								switch at {
									case HI32 | HF64 | HUI16 | HF32:
										var b = ctx.allocTmp(HBytes);
										ctx.op(OField(b, ra, 1));
										ctx.writeMem(b, ctx.shl(ridx, HlTypes.typeSizeBits(at)), at, v);
									case _:
										var arr = ctx.allocTmp(HArray);
										ctx.op(OField(arr, ra, 1));
										ctx.op(OSetArray(arr, ridx, HlCasts.castTo(ctx, v, HlTypes.isDynamic(at) ? at : HDyn, e.pos)));
								}
						}
						ctx.free(v);
						ctx.free(ra);
						ctx.free(ridx);
						return v;
					case ADynamic(ethis, f):
						var obj = HlAccess.evalNullCheck(ctx, ethis);
						ctx.hold(obj);
						var r = evalExpr(ctx, e2);
						ctx.free(obj);
						ctx.op(ODynSet(obj, f, r));
						return r;
					case ACaptured(index):
						var r = value();
						ctx.op(OSetEnumField(ctx.m.mcaptreg, index, r));
						return r;
					case AEnum(_) | ANone | AInstanceFun(_) | AInstanceProto(_) | AStaticFun(_) | AVirtualMethod(_):
						return HlContext.die();
				}
			case OpBoolOr:
				var r = ctx.allocTmp(HBool);
				var j = HlAccess.jumpExpr(ctx, e1, true);
				var j2 = HlAccess.jumpExpr(ctx, e2, true);
				ctx.op(OBool(r, false));
				var jend = ctx.jump(b -> OJAlways(b));
				j();
				j2();
				ctx.op(OBool(r, true));
				jend();
				return r;
			case OpBoolAnd:
				var r = ctx.allocTmp(HBool);
				var j = HlAccess.jumpExpr(ctx, e1, false);
				var j2 = HlAccess.jumpExpr(ctx, e2, false);
				ctx.op(OBool(r, true));
				var jend = ctx.jump(b -> OJAlways(b));
				j();
				j2();
				ctx.op(OBool(r, false));
				jend();
				return r;
			case OpAssignOp(bop2):
				switch HlAccess.getAccess(ctx, e1) {
					case ALocal(v, l):
						var r = HlCasts.evalTo(ctx, TypeFunctions.mk(TBinop(bop2, e1, e2), e.type, e.pos), HlTypes.toType(ctx, e1.type));
						ctx.pushOp(OMov(l, r));
						ctx.addAssign(v);
						return r;
					case acc:
						return HlAssign.genAssignOp(ctx, acc, e1, function(r) {
							ctx.hold(r);
							var b = if (bop2 == OpAdd && HlTypes.isString(ctx.rtype(r))) {
								HlCasts.toString(ctx, evalExpr(ctx, e2), e2.pos);
							} else {
								HlCasts.evalTo(ctx, e2, ctx.rtype(r));
							}
							ctx.free(r);
							binop(ctx, e, bop, e1, e2, r, r, b);
							return r;
						});
				}
			case OpInterval | OpArrow | OpIn | OpNullCoal:
				return HlContext.die();
		}
	}

	// eval_expr's TUnop (Increment | Decrement, fix, v)
	static function evalIncrDecr(ctx:HlContext, e:TExpr, uop:Unop, fix:UnopFlag, v:TExpr):Int {
		return switch [HlAccess.getAccess(ctx, v), fix] {
			case [ALocal(_, r), Prefix]:
				incrDecr(ctx, uop, r);
				r;
			case [ALocal(_, r), Postfix]:
				var r2 = ctx.allocTmp(ctx.rtype(r));
				ctx.hold(r2);
				ctx.op(OMov(r2, r));
				incrDecr(ctx, uop, r);
				ctx.free(r2);
				r2;
			case [acc, _]:
				var ret = 0;
				switch acc {
					case AArray(a, _, _, idx):
						ctx.hold(a);
						ctx.hold(idx);
					case _:
				}
				HlAssign.genAssignOp(ctx, acc, v, function(r) {
					if (fix == Prefix) {
						ret = r;
					} else {
						ctx.hold(r);
						var tmp = ctx.allocTmp(ctx.rtype(r));
						ctx.free(r);
						ctx.op(OMov(tmp, r));
						ret = tmp;
					}
					ctx.hold(ret);
					incrDecr(ctx, uop, r);
					return r;
				});
				ctx.free(ret);
				switch acc {
					case AArray(a, _, _, idx):
						ctx.free(a);
						ctx.free(idx);
					case _:
				}
				ret;
		}
	}

	// eval_expr's TUnop (Increment | Decrement) unop
	static function incrDecr(ctx:HlContext, uop:Unop, r:Int):Void {
		var t = ctx.rtype(r);
		switch t {
			case HUI8 | HUI16 | HI32 | HI64:
				ctx.op(uop == Increment ? OIncr(r) : ODecr(r));
			case HF32 | HF64:
				ctx.hold(r);
				var tmp = ctx.allocTmp(t);
				ctx.free(r);
				ctx.op(OFloat(tmp, ctx.allocFloat(1.)));
				ctx.op(uop == Increment ? OAdd(r, r, tmp) : OSub(r, r, tmp));
			case HNull(t2) if (HlTypes.isNumber(t2)):
				ctx.hold(r);
				var tmp = ctx.allocTmp(t2);
				ctx.free(r);
				ctx.op(OSafeCast(tmp, r));
				incrDecr(ctx, uop, tmp);
				ctx.op(OToDyn(r, tmp));
			case HDyn if (uop == Increment):
				ctx.hold(r);
				var tmp = ctx.allocTmp(HDyn);
				ctx.free(r);
				ctx.op(OToDyn(tmp, ctx.regInt(1)));
				ctx.op(OCall2(r, HlTypes.allocFunPath(ctx, new Path([], "Std"), "__add__"), r, tmp));
			case HDyn if (uop == Decrement):
				var r2 = ctx.allocTmp(HF64);
				ctx.hold(r2);
				var tmp = ctx.allocTmp(HF64);
				ctx.free(r2);
				ctx.op(OSafeCast(r2, r));
				ctx.op(OFloat(tmp, ctx.allocFloat(1.)));
				ctx.op(OSub(r2, r2, tmp));
				ctx.op(OSafeCast(r, r2));
			case _:
				HlContext.die();
		}
	}
}
