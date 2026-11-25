package hxc.codegen.hl;

import hxc.ast.Position;
import hxc.core.Globals.Path;
import hxc.core.Type;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlContext;

using hxc.codegen.hl.HlContext;

// Values converted between HL types: a port of genhl.ml's eval_to, to_string, cast_to, unsafe_cast_to,
// make_const and make_string (lines 1047-1292, 1521-1537).
class HlCasts {
	// genhl.ml: eval_to
	public static function evalTo(ctx:HlContext, e:TExpr, t:HlType):Int {
		switch [e.expr, t] {
			case [TConst(TInt(i)), HF64]:
				var r = ctx.allocTmp(t);
				ctx.op(OFloat(r, ctx.allocFloat(i)));
				return r;
			case _:
				var r = HlExpr.evalExpr(ctx, e);
				return castTo(ctx, r, t, e.pos);
		}
	}

	// genhl.ml: to_string
	public static function toString(ctx:HlContext, r:Int, p:Position):Int {
		var rt = ctx.rtype(r);
		if (HlTypes.safeCast(rt, ctx.tstring)) return r;
		switch rt {
			case HUI8 | HUI16 | HI32:
				var len = ctx.allocTmp(HI32);
				ctx.hold(len);
				var lref = ctx.allocTmp(HRef(HI32));
				var bytes = ctx.allocTmp(HBytes);
				ctx.op(ORef(lref, len));
				// the constructor's arguments right to left
				var a = castTo(ctx, r, HI32, p);
				var f = HlTypes.allocStd(ctx, "itos", [HI32, HRef(HI32)], HBytes);
				ctx.op(OCall2(bytes, f, a, lref));
				var out = ctx.allocTmp(ctx.tstring);
				ctx.op(OCall2(out, HlTypes.allocFunPath(ctx, new Path([], "String"), "__alloc__"), bytes, len));
				ctx.free(len);
				return out;
			case HF32 | HF64:
				var len = ctx.allocTmp(HI32);
				var lref = ctx.allocTmp(HRef(HI32));
				var bytes = ctx.allocTmp(HBytes);
				ctx.op(ORef(lref, len));
				var a = castTo(ctx, r, HF64, p);
				var f = HlTypes.allocStd(ctx, "ftos", [HF64, HRef(HI32)], HBytes);
				ctx.op(OCall2(bytes, f, a, lref));
				var out = ctx.allocTmp(ctx.tstring);
				ctx.op(OCall2(out, HlTypes.allocFunPath(ctx, new Path([], "String"), "__alloc__"), bytes, len));
				return out;
			case _:
				var r = castTo(ctx, r, HDyn, p);
				var out = ctx.allocTmp(ctx.tstring);
				ctx.op(OJNotNull(r, 2));
				ctx.op(ONull(out));
				ctx.op(OJAlways(1));
				ctx.op(OCall1(out, HlTypes.allocFunPath(ctx, new Path([], "Std"), "string"), r));
				return out;
		}
	}

	// genhl.ml: cast_to
	public static function castTo(ctx:HlContext, r:Int, t:HlType, p:Position, force:Bool = false):Int {
		var rt = ctx.rtype(r);
		if (HlTypes.safeCast(rt, t)) return r;
		switch [rt, t] {
			case [_, HVoid]:
				return ctx.allocTmp(HVoid);
			case [HVirtual(_), HVirtual(_)]:
				var tmp = ctx.allocTmp(HDyn);
				ctx.op(OMov(tmp, r));
				return castTo(ctx, tmp, t, p);
			case [HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64, HF32 | HF64]:
				var tmp = ctx.allocTmp(t);
				ctx.op(OToSFloat(tmp, r));
				return tmp;
			case [HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64, HUI8 | HUI16 | HI32 | HI64]:
				var tmp = ctx.allocTmp(t);
				ctx.op(OToInt(tmp, r));
				return tmp;
			case [HObj(o), HVirtual(_)]:
				var out = ctx.allocTmp(t);
				var fid:Null<Int> = null;
				var o2 = o;
				while (o2 != null && fid == null) {
					for (e in o2.pinterfaces) if (HlTypes.teq(e.t, t)) {
						fid = e.index;
						break;
					}
					o2 = o2.psuper;
				}
				if (fid == null) {
					// not an interface
					ctx.op(OToVirtual(out, r));
				} else {
					// memoisation
					var needNullCheck = !(r == 0 && ctx.m.mhasthis);
					var jend = if (needNullCheck) {
						var jnull = ctx.jump(d -> OJNotNull(r, d));
						ctx.op(ONull(out));
						var jend = ctx.jump(d -> OJAlways(d));
						jnull();
						jend;
					} else () -> {};
					ctx.op(OField(out, r, fid));
					var j = ctx.jump(d -> OJNotNull(out, d));
					ctx.op(OToVirtual(out, r));
					ctx.op(OSetField(r, fid, out));
					jend();
					j();
				}
				return out;
			case [HDynObj | HDyn, HVirtual(_)]:
				var out = ctx.allocTmp(t);
				ctx.op(OToVirtual(out, r));
				return out;
			case [HDyn, _]:
				var out = ctx.allocTmp(t);
				ctx.op(OSafeCast(out, r));
				return out;
			case [HNull(rt2), _] if (HlTypes.teq(t, rt2)):
				var out = ctx.allocTmp(t);
				ctx.op(OSafeCast(out, r));
				return out;
			case [HVoid, HDyn]:
				var tmp = ctx.allocTmp(HDyn);
				ctx.op(ONull(tmp));
				return tmp;
			case [_, HDyn]:
				var tmp = ctx.allocTmp(HDyn);
				ctx.op(OToDyn(tmp, r));
				return tmp;
			case [_, HNull(t2)] if (rt == t2):
				var tmp = ctx.allocTmp(HNull(t2));
				ctx.op(OToDyn(tmp, r));
				return tmp;
			case [HNull(t1), HNull(_)]:
				var j = ctx.jump(n -> OJNull(r, n));
				var rtmp = ctx.allocTmp(t1);
				ctx.op(OSafeCast(rtmp, r));
				var out = castTo(ctx, rtmp, t, p);
				ctx.op(OJAlways(1));
				j();
				ctx.op(ONull(out));
				return out;
			case [HRef(t1), HNull(_)]:
				var j = ctx.jump(n -> OJNull(r, n));
				var rtmp = ctx.allocTmp(t1);
				ctx.op(OUnref(rtmp, r));
				var out = castTo(ctx, rtmp, t, p);
				ctx.op(OJAlways(1));
				j();
				ctx.op(ONull(out));
				return out;
			case [HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64, HNull(t2)] if (t2.match(HF32 | HF64)):
				var tmp = ctx.allocTmp(t2);
				ctx.op(OToSFloat(tmp, r));
				var r = ctx.allocTmp(HNull(t2));
				ctx.op(OToDyn(r, tmp));
				return r;
			case [HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64, HNull(t2)] if (t2.match(HUI8 | HUI16 | HI32)):
				var tmp = ctx.allocTmp(t2);
				ctx.op(OToInt(tmp, r));
				var r = ctx.allocTmp(HNull(t2));
				ctx.op(OToDyn(r, tmp));
				return r;
			case [HNull(it), HF32 | HF64] if (it.match(HUI8 | HUI16 | HI32 | HI64)):
				var i = ctx.allocTmp(it);
				ctx.op(OSafeCast(i, r));
				var tmp = ctx.allocTmp(t);
				ctx.op(OToSFloat(tmp, i));
				return tmp;
			case [HNull(it), HUI8 | HUI16 | HI32 | HI64] if (it.match(HF32 | HF64)):
				var i = ctx.allocTmp(it);
				ctx.op(OSafeCast(i, r));
				var tmp = ctx.allocTmp(t);
				ctx.op(OToInt(tmp, i));
				return tmp;
			case [HFun(args1, _), HFun(args2, _)] if (args1.length == args2.length):
				var fid = HlFunctions.genMethodWrapper(ctx, rt, t, p);
				var fr = ctx.allocTmp(t);
				ctx.op(OJNotNull(r, 2));
				ctx.op(ONull(fr));
				ctx.op(OJAlways(1));
				ctx.op(OInstanceClosure(fr, fid, r));
				return fr;
			case [HObj(_), HObj(_)] if (HlTypes.isArrayType(rt) && HlTypes.isArrayType(t)):
				var out = ctx.allocTmp(t);
				ctx.op(OSafeCast(out, r));
				return out;
			case [HNull(_), HRef(t2)]:
				var out = ctx.allocTmp(t);
				ctx.op(OJNotNull(r, 2));
				ctx.op(ONull(out));
				var j = ctx.jump(n -> OJAlways(n));
				var r = castTo(ctx, r, t2, p);
				var r2 = ctx.allocTmp(t2);
				ctx.op(OMov(r2, r));
				ctx.hold(r2); // retain
				ctx.op(ORef(out, r2));
				j();
				return out;
			case [_, HRef(t2)]:
				var r = castTo(ctx, r, t2, p);
				var r2 = ctx.allocTmp(t2);
				ctx.op(OMov(r2, r));
				ctx.hold(r2); // retain
				var out = ctx.allocTmp(t);
				ctx.op(ORef(out, r2));
				return out;
			case _:
				if (force) {
					var out = ctx.allocTmp(t);
					ctx.op(OSafeCast(out, r));
					return out;
				}
				return HlContext.abort("Don't know how to cast " + HlDump.tstr(rt) + " to " + HlDump.tstr(t), p);
		}
	}

	// genhl.ml: unsafe_cast_to
	public static function unsafeCastTo(ctx:HlContext, r:Int, t:HlType, p:Position, debugchk:Bool = true):Int {
		var rt = ctx.rtype(r);
		if (HlTypes.safeCast(rt, t)) return r;
		var tIsVirtual = t.match(HVirtual(_));
		switch rt {
			case HFun(_):
				return castTo(ctx, r, t, p);
			case HDyn if (HlTypes.isArrayType(t)):
				return castTo(ctx, r, t, p);
			case HDyn | HObj(_) if (tIsVirtual):
				return castTo(ctx, r, t, p);
			case HObj(_) if (HlTypes.isArrayType(rt) && HlTypes.isArrayType(t)):
				return castTo(ctx, r, t, p);
			case HVirtual(_) if (t.match(HObj(_) | HVirtual(_))):
				return castTo(ctx, r, t, p, true);
			case _:
				if (HlTypes.isDynamic(ctx.rtype(r)) && HlTypes.isDynamic(t)) {
					var r2 = ctx.allocTmp(t);
					ctx.op(OUnsafeCast(r2, r));
					if (ctx.com.debug && debugchk) {
						ctx.hold(r2);
						var r3 = castTo(ctx, r, t, p, true);
						var j = ctx.jump(n -> OJEq(r2, r3, n));
						ctx.op(OAssert(0));
						j();
						ctx.free(r2);
					}
					return r2;
				}
				return castTo(ctx, r, t, p, true);
		}
	}

	// genhl.ml: make_const (constval has one constructor, CString)
	public static function makeConst(ctx:HlContext, s:String, p:Position):Int {
		var cidx = HlContext.lookup(ctx.cconstants, s, function() {
			var u = HlTypes.toUtf8(s, p);
			// the list's elements right to left
			var len = ctx.allocI32(u.count);
			var str = ctx.allocString(u.s);
			var g = HlContext.lookupAlloc(ctx.cglobals, ctx.tstring);
			return {global: g, fields: [str, len]};
		});
		return ctx.cconstants.arr[cidx].global;
	}

	// genhl.ml: make_string
	public static function makeString(ctx:HlContext, s:String, p:Position):Int {
		var r = ctx.allocTmp(ctx.tstring);
		ctx.op(OGetGlobal(r, makeConst(ctx, s, p)));
		return r;
	}
}
