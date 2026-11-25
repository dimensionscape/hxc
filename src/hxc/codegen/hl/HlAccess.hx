package hxc.codegen.hl;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlContext;

using hxc.codegen.hl.HlContext;

// genhl.ml: access
enum HlAccessKind {
	ANone;
	AGlobal(g:Int);
	ALocal(v:TVar, r:Int);
	AStaticVar(g:Int, t:HlType, fid:Int);
	AStaticFun(f:Int);
	AInstanceFun(e:TExpr, f:Int);
	AInstanceProto(e:TExpr, fid:Int);
	AInstanceField(e:TExpr, fid:Int);
	AArray(r:Int, at:HlType, vt:HlType, idx:Int);
	AVirtualMethod(e:TExpr, fid:Int);
	ADynamic(e:TExpr, name:Int);
	AEnum(e:TEnum, index:Int);
	ACaptured(index:Int);
}

// How a field, local or array element is reached: a port of genhl.ml's object_access, direct_method_call,
// get_access, array_read, jump_expr, eval_args and eval_null_check (lines 1293-1519).
class HlAccess {
	static inline function isMethNormal(f:TClassField):Bool {
		return f.kind.match(Method(MethNormal));
	}

	// genhl.ml: object_access
	public static function objectAccess(ctx:HlContext, eobj:TExpr, t:HlType, f:TClassField):HlAccessKind {
		switch t {
			case HObj(p) | HStruct(p):
				var i = HlTypes.getIndex(f.name, p);
				if (i == null) return ADynamic(eobj, ctx.allocString(f.name));
				return isMethNormal(f) ? AInstanceProto(eobj, -i.index - 1) : AInstanceField(eobj, i.index);
			case HVirtual(v):
				var fid = v.vindex.get(f.name);
				if (fid == null) return ADynamic(eobj, ctx.allocString(f.name));
				return isMethNormal(f) ? AVirtualMethod(eobj, fid) : AInstanceField(eobj, fid);
			case HDyn:
				return ADynamic(eobj, ctx.allocString(f.name));
			case _:
				return HlContext.abort("Unsupported field access " + HlDump.tstr(t), eobj.pos);
		}
	}

	// genhl.ml: direct_method_call
	public static function directMethodCall(ctx:HlContext, c:TClass, f:TClassField, ethis:TExpr):Bool {
		if (switch f.kind {
			case Method(m): m == MethDynamic;
			case Var(_): true;
		}) return false;
		if (TypeFunctions.hasClassFlag(c, CInterface)) return false;
		if (c.kind.match(KTypeParameter(_))) return false;
		if (HlContext.isOverridden(ctx, c, f) && !ethis.expr.match(TConst(TSuper))) return false;
		return true;
	}

	// genhl.ml: get_access
	public static function getAccess(ctx:HlContext, e:TExpr):HlAccessKind {
		switch e.expr {
			case TField(ethis, a):
				var tthis = TypeFunctions.follow(ethis.type);
				switch a {
					case FStatic(c, f) if (f.kind.match(Var(_) | Method(MethDynamic))):
						var cg = HlTypes.classGlobal(ctx, c);
						var fid = switch cg.t {
							case HObj(o):
								var i = HlTypes.getIndex(f.name, o);
								if (i == null) HlContext.die();
								i.index;
							case _: HlContext.die();
						}
						return AStaticVar(cg.g, cg.t, fid);
					case FStatic(c, f):
						return AStaticFun(HlTypes.allocFid(ctx, c, f));
					case _:
				}
				// FInstance (cdef, pl, f) | FClosure (Some (cdef, pl), f)
				var inst = switch a {
					case FInstance(c, pl, f): {c: c, params: pl, f: f};
					case FClosure(cp, f) if (cp != null): {c: cp.c, params: cp.params, f: f};
					case _: null;
				}
				if (inst != null) {
					var f = inst.f, pl = inst.params;
					switch tthis {
						case TInst(c, _) if (directMethodCall(ctx, c, f, ethis)):
							// cdef is the original definition, we want the last redefinition
							var lastDef = c;
							while (!lastDef.fields.exists(f.name)) {
								if (lastDef.superClass == null) {
									lastDef = inst.c;
									break;
								}
								lastDef = lastDef.superClass.c;
							}
							return AInstanceFun(ethis, HlTypes.allocFid(ctx, HlTypes.resolveClass(ctx, lastDef, pl, false), f));
						case _:
					}
					var cdef = inst.c;
					if (TypeFunctions.hasClassFlag(cdef, CInterface)) {
						function loop(t:T):{c:TClass, params:TParams} {
							return switch TypeFunctions.follow(t) {
								case TInst(c, pl): {c: c, params: pl};
								case TAbstract(a, pl): loop(TypeFunctions.getUnderlyingType(a, pl));
								case _: HlContext.abort(hxc.core.TPrinting.sType(hxc.core.TPrinting.printContext(), ethis.type) + " hl type should be interface", ethis.pos);
							}
						}
						var r = loop(ethis.type);
						cdef = r.c;
						pl = r.params;
					}
					return objectAccess(ctx, ethis, HlTypes.classType(ctx, cdef, pl, false), f);
				}
				switch a {
					case FAnon(f) | FClosure(_, f):
						return objectAccess(ctx, ethis, HlTypes.toType(ctx, ethis.type), f);
					case FDynamic(name):
						return ADynamic(ethis, ctx.allocString(name));
					case FEnum(en, ef):
						switch TypeFunctions.follow(ef.type) {
							case TFun(_):
								return AEnum(en, ef.index);
							case t:
								var ht = HlTypes.toType(ctx, t);
								return AGlobal(HlTypes.allocGlobal(ctx, HlTypes.efieldName(en, ef), ht));
						}
					case _:
						return HlContext.die();
				}
			case TLocal(v):
				var idx = ctx.capturedIndex(v);
				return idx == null ? ALocal(v, ctx.allocVar(v, false)) : ACaptured(idx);
			case TParenthesis(e):
				return getAccess(ctx, e);
			case TArray(a, i):
				function loop(t:T):HlAccessKind {
					return switch TypeFunctions.follow(t) {
						case TInst(c, [t]) if (c.path.pack.length == 0 && c.path.name == "Array"):
							var a = evalNullCheck(ctx, a);
							ctx.hold(a);
							var i = HlCasts.evalTo(ctx, i, HI32);
							ctx.free(a);
							var t = HlTypes.toType(ctx, t);
							AArray(a, t, t, i);
						case TAbstract(a, pl):
							loop(TypeFunctions.getUnderlyingType(a, pl));
						case _:
							var a = HlCasts.evalTo(ctx, a, HlTypes.classType(ctx, ctx.arrayImpl.adyn, [], false));
							ctx.op(ONullCheck(a));
							ctx.hold(a);
							var i = HlCasts.evalTo(ctx, i, HI32);
							ctx.free(a);
							AArray(a, HDyn, HlTypes.toType(ctx, e.type), i);
					}
				}
				return loop(a.type);
			case _:
				return ANone;
		}
	}

	// genhl.ml: array_read
	public static function arrayRead(ctx:HlContext, ra:Int, at:HlType, vt:HlType, ridx:Int, p:Position):Int {
		switch at {
			case HUI8 | HUI16 | HI32 | HF32 | HF64:
				// check bounds
				ctx.hold(ridx);
				var length = ctx.allocTmp(HI32);
				ctx.free(ridx);
				ctx.op(OField(length, ra, 0));
				var j = ctx.jump(i -> OJULt(ridx, length, i));
				var r = ctx.allocTmp(switch at {
					case HUI8 | HUI16: HI32;
					case _: at;
				});
				switch at {
					case HUI8 | HUI16 | HI32:
						ctx.op(OInt(r, ctx.allocI32(0)));
					case HF32 | HF64:
						ctx.op(OFloat(r, ctx.allocFloat(0.)));
					case _:
						HlContext.die();
				}
				var jend = ctx.jump(i -> OJAlways(i));
				j();
				var hbytes = ctx.allocTmp(HBytes);
				ctx.op(OField(hbytes, ra, 1));
				ctx.readMem(r, hbytes, ctx.shl(ridx, HlTypes.typeSizeBits(at)), at);
				jend();
				return HlCasts.castTo(ctx, r, vt, p);
			case HDyn:
				// call getDyn
				var r = ctx.allocTmp(HDyn);
				ctx.op(OCallMethod(r, 0, [ra, ridx]));
				return HlCasts.unsafeCastTo(ctx, r, vt, p);
			case _:
				// check bounds
				ctx.hold(ridx);
				var length = ctx.allocTmp(HI32);
				ctx.free(ridx);
				ctx.op(OField(length, ra, 0));
				var j = ctx.jump(i -> OJULt(ridx, length, i));
				var r = ctx.allocTmp(vt);
				ctx.setDefault(r);
				var jend = ctx.jump(i -> OJAlways(i));
				j();
				var tmp = ctx.allocTmp(HDyn);
				var harr = ctx.allocTmp(HArray);
				ctx.op(OField(harr, ra, 1));
				ctx.op(OGetArray(tmp, harr, ridx));
				if (ctx.arrayCastGuard && HlTypes.isArrayType(vt)) {
					// -D hl-array-cast: Haxe converts an array read out of an array through the runtime, since it
					// may be an Array<Dynamic> standing in for the typed one.
					// It nearly always is an array of exactly the wanted type, so its type is compared first,
					// and the runtime is asked only when it is something else.
					ctx.op(OUnsafeCast(r, tmp));
					var jnull = ctx.jump(n -> OJNull(tmp, n));
					var ty = ctx.allocTmp(HType);
					ctx.hold(ty);
					var want = ctx.allocTmp(HType);
					ctx.free(ty);
					ctx.op(OGetType(ty, tmp));
					ctx.op(OType(want, vt));
					// a type has one address in a module, so its address is compared: comparing two type
					// values goes through hl_same_type
					var pty = ctx.allocTmp(HBytes);
					ctx.hold(pty);
					var pwant = ctx.allocTmp(HBytes);
					ctx.free(pty);
					ctx.op(OUnsafeCast(pty, ty));
					ctx.op(OUnsafeCast(pwant, want));
					var jsame = ctx.jump(n -> OJEq(pty, pwant, n));
					ctx.op(OSafeCast(r, tmp));
					jsame();
					jnull();
				} else
					ctx.op(OMov(r, HlCasts.unsafeCastTo(ctx, tmp, vt, p)));
				jend();
				return r;
		}
	}

	static function isNullConst(e:TExpr):Bool {
		return e.expr.match(TConst(TNull));
	}

	// genhl.ml: jump_expr
	public static function jumpExpr(ctx:HlContext, e:TExpr, jcond:Bool):Void->Void {
		switch e.expr {
			case TParenthesis(e):
				return jumpExpr(ctx, e, jcond);
			case TUnop(Not, _, e):
				return jumpExpr(ctx, e, !jcond);
			case TBinop(OpEq, e1, e2) if (isNullConst(e1) || isNullConst(e2)):
				var r = HlExpr.evalExpr(ctx, isNullConst(e1) ? e2 : e1);
				if (HlTypes.isNullable(ctx.rtype(r))) return ctx.jump(i -> jcond ? OJNull(r, i) : OJNotNull(r, i));
				if (!jcond) return ctx.jump(i -> OJAlways(i));
				return () -> {};
			case TBinop(OpNotEq, e1, e2) if (isNullConst(e1) || isNullConst(e2)):
				var r = HlExpr.evalExpr(ctx, isNullConst(e1) ? e2 : e1);
				if (HlTypes.isNullable(ctx.rtype(r))) return ctx.jump(i -> jcond ? OJNotNull(r, i) : OJNull(r, i));
				if (jcond) return ctx.jump(i -> OJAlways(i));
				return () -> {};
			case TBinop(jop, e1, e2) if (jop.match(OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte)):
				var t = HlTypes.commonType(ctx, e1, e2, jop == OpEq || jop == OpNotEq, e.pos);
				var r1 = HlCasts.evalTo(ctx, e1, t);
				ctx.hold(r1);
				var r2 = HlCasts.evalTo(ctx, e2, t);
				ctx.free(r1);
				var unsigned = HlTypes.unsignedOp(e1, e2);
				return ctx.jump(function(i) {
					function lt(a, b) return unsigned ? OJULt(a, b, i) : (!jcond && HlTypes.isFloat(t)) ? OJNotGte(a, b, i) : OJSLt(a, b, i);
					function gte(a, b) return unsigned ? OJUGte(a, b, i) : (!jcond && HlTypes.isFloat(t)) ? OJNotLt(a, b, i) : OJSGte(a, b, i);
					return switch jop {
						case OpEq: jcond ? OJEq(r1, r2, i) : OJNotEq(r1, r2, i);
						case OpNotEq: jcond ? OJNotEq(r1, r2, i) : OJEq(r1, r2, i);
						case OpGt: jcond ? lt(r2, r1) : gte(r2, r1);
						case OpGte: jcond ? gte(r1, r2) : lt(r1, r2);
						case OpLt: jcond ? lt(r1, r2) : gte(r1, r2);
						case OpLte: jcond ? gte(r2, r1) : lt(r2, r1);
						case _: HlContext.die();
					}
				});
			case TBinop(OpBoolAnd, e1, e2):
				var j = jumpExpr(ctx, e1, false);
				var j2 = jumpExpr(ctx, e2, jcond);
				if (jcond) j();
				return () -> {
					if (!jcond) j();
					j2();
				};
			case TBinop(OpBoolOr, e1, e2):
				var j = jumpExpr(ctx, e1, true);
				var j2 = jumpExpr(ctx, e2, jcond);
				if (!jcond) j();
				return () -> {
					if (jcond) j();
					j2();
				};
			case _:
				var r = HlCasts.evalTo(ctx, e, HBool);
				return ctx.jump(i -> jcond ? OJTrue(r, i) : OJFalse(r, i));
		}
	}

	// genhl.ml: eval_args
	public static function evalArgs(ctx:HlContext, el:Array<TExpr>, t:HlType, p:Position):Array<Int> {
		var tl = switch t {
			case HFun(args, _): args;
			case HDyn: [for (_ in el) HDyn];
			case _: HlContext.die();
		}
		if (tl.length != el.length) HlContext.die("List.map2");
		var rl = [for (i in 0...el.length) {
			var e = el[i], t = tl[i];
			var r = switch [e.expr, t] {
				case [TConst(TNull), HRef(_)]:
					var r = ctx.allocTmp(t);
					ctx.op(ONull(r));
					r;
				case _:
					HlCasts.evalTo(ctx, e, t);
			}
			ctx.hold(r);
			r;
		}];
		for (r in rl) ctx.free(r);
		ctx.setCurpos(p);
		return rl;
	}

	// genhl.ml: eval_null_check
	public static function evalNullCheck(ctx:HlContext, e:TExpr):Int {
		var r = HlExpr.evalExpr(ctx, e);
		switch e.expr {
			case TConst(TThis) | TConst(TSuper):
			case _: ctx.op(ONullCheck(r));
		}
		return r;
	}
}
