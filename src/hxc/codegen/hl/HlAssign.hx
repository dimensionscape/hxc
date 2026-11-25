package hxc.codegen.hl;

import hxc.core.Type;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlContext;
import hxc.codegen.hl.HlAccess;

using hxc.codegen.hl.HlContext;

// Read-modify-write of a field, static, captured variable, array element or Dynamic field: a port of genhl.ml's
// gen_assign_op (lines 2941-3047), shared by the compound assignments (`a.x += b`) and `++`/`--` on anything
// but a local.
class HlAssign {
	// genhl.ml: gen_assign_op. `f` takes the register holding the current value and returns the one holding
	// the new value.
	public static function genAssignOp(ctx:HlContext, acc:HlAccessKind, e1:TExpr, f:Int->Int):Int {
		// gen_assign_op's inner `f`: a Null<number> is unboxed for `f` and boxed again
		function fWrap(r:Int):Int {
			return switch ctx.rtype(r) {
				case HNull(t):
					var r2 = ctx.allocTmp(t);
					ctx.op(OSafeCast(r2, r));
					var r3 = ctx.allocTmp(HNull(t));
					ctx.op(OToDyn(r3, f(r2)));
					r3;
				case _:
					f(r);
			}
		}
		switch acc {
			case AInstanceField(eobj, findex):
				var robj = HlAccess.evalNullCheck(ctx, eobj);
				ctx.hold(robj);
				var t = HlTypes.realType(ctx, e1);
				var r = ctx.allocTmp(t);
				ctx.op(OField(r, robj, findex));
				var r = HlCasts.castTo(ctx, r, HlTypes.toType(ctx, e1.type), e1.pos);
				var r = fWrap(r);
				ctx.free(robj);
				ctx.op(OSetField(robj, findex, HlCasts.castTo(ctx, r, t, e1.pos)));
				return r;
			case AStaticVar(g, t, fid):
				var o = ctx.allocTmp(t);
				ctx.op(OGetGlobal(o, g));
				var r = ctx.allocTmp(HlTypes.toType(ctx, e1.type));
				ctx.op(OField(r, o, fid));
				ctx.hold(o);
				var r = fWrap(r);
				ctx.free(o);
				ctx.op(OSetField(o, fid, r));
				return r;
			case AGlobal(g):
				var r = ctx.allocTmp(HlTypes.toType(ctx, e1.type));
				ctx.op(OGetGlobal(r, g));
				var r = fWrap(r);
				ctx.op(OSetGlobal(g, r));
				return r;
			case ACaptured(idx):
				var r = ctx.allocTmp(HlTypes.toType(ctx, e1.type));
				ctx.op(OEnumField(r, ctx.m.mcaptreg, 0, idx));
				var r = fWrap(r);
				ctx.op(OSetEnumField(ctx.m.mcaptreg, idx, r));
				return r;
			case AArray(ra, at, _, ridx):
				ctx.hold(ra);
				ctx.hold(ridx);
				var r = switch at {
					case HDyn:
						// call getDyn()
						var r = ctx.allocTmp(HDyn);
						ctx.op(OCallMethod(r, 0, [ra, ridx]));
						var r = fWrap(r);
						// call setDyn()
						ctx.op(OCallMethod(ctx.allocTmp(HVoid), 1, [ra, ridx, r]));
						r;
					case _:
						// bounds check against length
						var len = ctx.allocTmp(HI32);
						ctx.op(OField(len, ra, 0)); // length
						var j = ctx.jump(i -> OJULt(ridx, len, i));
						// the constructor's arguments right to left
						var fexpand = HlTypes.allocFunPath(ctx, HlTypes.arrayClass(ctx, at).path, "__expand");
						ctx.op(OCall2(ctx.allocTmp(HVoid), fexpand, ra, ridx));
						j();
						switch at {
							case HUI8 | HUI16 | HI32 | HF32 | HF64:
								var hbytes = ctx.allocTmp(HBytes);
								ctx.op(OField(hbytes, ra, 1));
								var ridx = ctx.shl(ridx, HlTypes.typeSizeBits(at));
								ctx.hold(ridx);
								ctx.hold(hbytes);
								var r = ctx.allocTmp(at);
								ctx.readMem(r, hbytes, ridx, at);
								var r = fWrap(r);
								ctx.writeMem(hbytes, ridx, at, r);
								ctx.free(ridx);
								ctx.free(hbytes);
								r;
							case _:
								var arr = ctx.allocTmp(HArray);
								ctx.op(OField(arr, ra, 1));
								var r = ctx.allocTmp(at);
								ctx.op(OGetArray(r, arr, ridx));
								ctx.hold(arr);
								var r = fWrap(r);
								ctx.free(arr);
								ctx.op(OSetArray(arr, ridx, r));
								r;
						}
				}
				ctx.free(ra);
				ctx.free(ridx);
				return r;
			case ADynamic(eobj, fid):
				var robj = HlAccess.evalNullCheck(ctx, eobj);
				ctx.hold(robj);
				var t = HlTypes.realType(ctx, e1);
				var r = ctx.allocTmp(t);
				ctx.op(ODynGet(r, robj, fid));
				var r = HlCasts.castTo(ctx, r, HlTypes.toType(ctx, e1.type), e1.pos);
				var r = fWrap(r);
				var r = HlCasts.castTo(ctx, r, t, e1.pos);
				ctx.free(robj);
				ctx.op(ODynSet(robj, fid, r));
				return r;
			case ANone | ALocal(_) | AStaticFun(_) | AInstanceFun(_) | AInstanceProto(_) | AVirtualMethod(_) | AEnum(_):
				return HlContext.die();
		}
	}
}
