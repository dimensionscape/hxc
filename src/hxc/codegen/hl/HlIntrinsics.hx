package hxc.codegen.hl;

import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlContext;

using hxc.codegen.hl.HlContext;

// The `$` intrinsics: a port of genhl.ml's eval_expr case `TCall ({ eexpr = TIdent s }, el) when s.[0] = '$'`
// (lines 1650-2058).
class HlIntrinsics {
	static inline function isPath(path:Path, pack:Array<String>, name:String):Bool {
		return path.name == name && path.pack.join(".") == pack.join(".");
	}

	// the element type of a `hl.BytesAccess<T>`, or null
	static function bytesAccessParam(t:T):Null<T> {
		return switch TypeFunctions.follow(t) {
			case TAbstract(a, [t]) if (isPath(a.path, ["hl"], "BytesAccess")): t;
			case _: null;
		}
	}

	// the element type of a `hl.NativeArray<T>`, or null
	static function nativeArrayParam(t:T):Null<T> {
		return switch TypeFunctions.follow(t) {
			case TAbstract(a, [t]) if (isPath(a.path, ["hl"], "NativeArray")): t;
			case _: null;
		}
	}

	// the local variable under parentheses, metadata and unsafe casts (`$setref` and `$unref`'s loop), or null
	static function refLocal(e:TExpr):Null<TVar> {
		return switch e.expr {
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null): refLocal(e1);
			case TLocal(v): v;
			case _: null;
		}
	}

	// hlcode.ml: hl_hash, over the string's UTF-8 bytes up to the first NUL
	static function hlHash(s:String):Int {
		var b = haxe.io.Bytes.ofString(s);
		var h = 0;
		for (i in 0...b.length) {
			var c = b.get(i);
			if (c == 0) break;
			h = h * 223 + c;
		}
		return h % 0x1FFFFF7B;
	}

	// `$bsetui8`, `$bsetui16`, `$bseti32`, `$bseti64`, `$bsetf32`, `$bsetf64`
	static function bset(ctx:HlContext, args:Array<TExpr>, vt:HlType, mk:(Int, Int, Int) -> HlOp):Int {
		var b = HlCasts.evalTo(ctx, args[0], HBytes);
		ctx.hold(b);
		var pos = HlCasts.evalTo(ctx, args[1], HI32);
		ctx.hold(pos);
		var r = HlCasts.evalTo(ctx, args[2], vt);
		ctx.free(pos);
		ctx.free(b);
		ctx.op(mk(b, pos, r));
		return r;
	}

	// `$bgetui8`, `$bgetui16`, `$bgeti32`, `$bgeti64`, `$bgetf32`, `$bgetf64`
	static function bget(ctx:HlContext, args:Array<TExpr>, rt:HlType, mk:(Int, Int, Int) -> HlOp):Int {
		var b = HlCasts.evalTo(ctx, args[0], HBytes);
		ctx.hold(b);
		var pos = HlCasts.evalTo(ctx, args[1], HI32);
		ctx.free(b);
		var r = ctx.allocTmp(rt);
		ctx.op(mk(r, b, pos));
		return r;
	}

	// genhl.ml: eval_expr's `TCall ({ eexpr = TIdent s }, el) when s.[0] = '$'`
	public static function evalIntrinsic(ctx:HlContext, name:String, args:Array<TExpr>, e:TExpr):Int {
		function invalid():Dynamic return HlContext.abort("Invalid native call", e.pos);
		function unknown():Dynamic return HlContext.abort("Unknown native call " + name, e.pos);
		var n = args.length;
		switch name {
			case "$new" if (n == 1 && args[0].expr.match(TTypeExpr(TClassDecl(_)))):
				switch TypeFunctions.follow(e.type) {
					case TInst(c, pl):
						var r = ctx.allocTmp(HlTypes.classType(ctx, c, pl, false));
						ctx.op(ONew(r));
						return r;
					case _:
						return invalid();
				}
			case "$int" if (n == 1):
				switch args[0].expr {
					case TBinop(OpDiv, e1, e2) if (HlTypes.isInt(HlTypes.toType(ctx, e1.type)) && HlTypes.isInt(HlTypes.toType(ctx, e2.type))):
						var tmp = ctx.allocTmp(HI32);
						var r1 = HlCasts.evalTo(ctx, e1, HI32);
						ctx.hold(r1);
						var r2 = HlCasts.evalTo(ctx, e2, HI32);
						ctx.free(r1);
						ctx.op(HlTypes.unsignedOp(e1, e2) ? OUDiv(tmp, r1, r2) : OSDiv(tmp, r1, r2));
						return tmp;
					case _:
						var tmp = ctx.allocTmp(HI32);
						ctx.op(OToInt(tmp, HlExpr.evalExpr(ctx, args[0])));
						return tmp;
				}
			case "$bsetui8" if (n == 3):
				return bset(ctx, args, HI32, (b, p, r) -> OSetUI8(b, p, r));
			case "$bsetui16" if (n == 3):
				return bset(ctx, args, HI32, (b, p, r) -> OSetUI16(b, p, r));
			case "$bseti32" if (n == 3):
				return bset(ctx, args, HI32, (b, p, r) -> OSetMem(b, p, r));
			case "$bseti64" if (n == 3):
				return bset(ctx, args, HI64, (b, p, r) -> OSetMem(b, p, r));
			case "$bsetf32" if (n == 3):
				return bset(ctx, args, HF32, (b, p, r) -> OSetMem(b, p, r));
			case "$bsetf64" if (n == 3):
				return bset(ctx, args, HF64, (b, p, r) -> OSetMem(b, p, r));
			case "$bytes_sizebits" if (n == 1):
				var t = bytesAccessParam(args[0].type);
				if (t == null) return HlContext.abort("Invalid BytesAccess", args[0].pos);
				return ctx.regInt(switch HlTypes.toType(ctx, t) {
					case HUI8: 0;
					case HUI16: 1;
					case HI32 | HF32: 2;
					case HI64 | HF64: 3;
					case t: HlContext.abort("Unsupported basic type " + HlDump.tstr(t), e.pos);
				});
			case "$bytes_nullvalue" if (n == 1):
				var t = bytesAccessParam(args[0].type);
				if (t == null) return HlContext.abort("Invalid BytesAccess", args[0].pos);
				var t = HlTypes.toType(ctx, t);
				var r = ctx.allocTmp(t);
				switch t {
					case HUI8 | HUI16 | HI32 | HI64:
						ctx.op(OInt(r, ctx.allocI32(0)));
					case HF32 | HF64:
						ctx.op(OFloat(r, ctx.allocFloat(0.)));
					case t:
						HlContext.abort("Unsupported basic type " + HlDump.tstr(t), e.pos);
				}
				return r;
			case "$bget" if (n == 2):
				var t = bytesAccessParam(args[0].type);
				if (t == null) return HlContext.abort("Invalid BytesAccess", args[0].pos);
				var b = HlCasts.evalTo(ctx, args[0], HBytes);
				ctx.hold(b);
				var pos = HlCasts.evalTo(ctx, args[1], HI32);
				ctx.free(b);
				switch HlTypes.toType(ctx, t) {
					case HUI8:
						var r = ctx.allocTmp(HI32);
						ctx.op(OGetUI8(r, b, pos));
						return r;
					case HUI16:
						var r = ctx.allocTmp(HI32);
						ctx.op(OGetUI16(r, b, ctx.shl(pos, 1)));
						return r;
					case HI32:
						var r = ctx.allocTmp(HI32);
						ctx.op(OGetMem(r, b, ctx.shl(pos, 2)));
						return r;
					case HI64:
						var r = ctx.allocTmp(HI64);
						ctx.op(OGetMem(r, b, ctx.shl(pos, 3)));
						return r;
					case HF32:
						var r = ctx.allocTmp(HF32);
						ctx.op(OGetMem(r, b, ctx.shl(pos, 2)));
						return r;
					case HF64:
						var r = ctx.allocTmp(HF64);
						ctx.op(OGetMem(r, b, ctx.shl(pos, 3)));
						return r;
					case t:
						return HlContext.abort("Unsupported basic type " + HlDump.tstr(t), e.pos);
				}
			case "$bset" if (n == 3):
				var t = bytesAccessParam(args[0].type);
				if (t == null) return HlContext.abort("Invalid BytesAccess", args[0].pos);
				var b = HlCasts.evalTo(ctx, args[0], HBytes);
				ctx.hold(b);
				var pos = HlCasts.evalTo(ctx, args[1], HI32);
				ctx.hold(pos);
				var value = args[2];
				function setShifted(vt:HlType, bits:Int):Int {
					var v = HlCasts.evalTo(ctx, value, vt);
					ctx.hold(v);
					var idx = ctx.shl(pos, bits);
					ctx.op(bits == 1 ? OSetUI16(b, idx, v) : OSetMem(b, idx, v));
					ctx.free(v);
					return v;
				}
				var v = switch HlTypes.toType(ctx, t) {
					case HUI8:
						var v = HlCasts.evalTo(ctx, value, HI32);
						ctx.op(OSetUI8(b, pos, v));
						v;
					case HUI16: setShifted(HI32, 1);
					case HI32: setShifted(HI32, 2);
					case HI64: setShifted(HI64, 3);
					case HF32: setShifted(HF32, 2);
					case HF64: setShifted(HF64, 3);
					case t: HlContext.abort("Unsupported basic type " + HlDump.tstr(t), e.pos);
				}
				ctx.free(b);
				ctx.free(pos);
				return v;
			case "$bgetui8" if (n == 2):
				return bget(ctx, args, HI32, (r, b, p) -> OGetUI8(r, b, p));
			case "$bgetui16" if (n == 2):
				return bget(ctx, args, HI32, (r, b, p) -> OGetUI16(r, b, p));
			case "$bgeti32" if (n == 2):
				return bget(ctx, args, HI32, (r, b, p) -> OGetMem(r, b, p));
			case "$bgeti64" if (n == 2):
				return bget(ctx, args, HI64, (r, b, p) -> OGetMem(r, b, p));
			case "$bgetf32" if (n == 2):
				return bget(ctx, args, HF32, (r, b, p) -> OGetMem(r, b, p));
			case "$bgetf64" if (n == 2):
				return bget(ctx, args, HF64, (r, b, p) -> OGetMem(r, b, p));
			case "$asize" if (n == 1):
				var r = ctx.allocTmp(HI32);
				ctx.op(OArraySize(r, HlCasts.evalTo(ctx, args[0], HArray)));
				return r;
			case "$aalloc" if (n == 1):
				var pt = nativeArrayParam(e.type);
				var et = pt == null ? invalid() : HlTypes.toType(ctx, pt);
				var size = HlCasts.evalTo(ctx, args[0], HI32);
				var a = ctx.allocTmp(HArray);
				var rt = ctx.allocTmp(HType);
				ctx.op(OType(rt, et));
				ctx.op(OCall2(a, HlTypes.allocStd(ctx, "alloc_array", [HType, HI32], HArray), rt, size));
				return a;
			case "$aget" if (n == 2):
				// read/write on arrays are unsafe : the type of NativeArray needs to be correcly set.
				var pt = nativeArrayParam(args[0].type);
				var at = pt == null ? invalid() : HlTypes.toType(ctx, pt);
				var arr = HlCasts.evalTo(ctx, args[0], HArray);
				ctx.hold(arr);
				var pos = HlCasts.evalTo(ctx, args[1], HI32);
				ctx.free(arr);
				var r = ctx.allocTmp(at);
				ctx.op(OGetArray(r, arr, pos));
				return HlCasts.castTo(ctx, r, HlTypes.toType(ctx, e.type), e.pos);
			case "$aset" if (n == 3):
				var pt = nativeArrayParam(args[0].type);
				var et = pt == null ? invalid() : HlTypes.toType(ctx, pt);
				var arr = HlCasts.evalTo(ctx, args[0], HArray);
				ctx.hold(arr);
				var pos = HlCasts.evalTo(ctx, args[1], HI32);
				ctx.hold(pos);
				var r = HlCasts.evalTo(ctx, args[2], et);
				ctx.free(pos);
				ctx.free(arr);
				ctx.op(OSetArray(arr, pos, r));
				return r;
			case "$abytes" if (n == 1):
				var a = args[0];
				switch TypeFunctions.follow(a.type) {
					case TInst(c, [t]) if (isPath(c.path, [], "Array") && HlTypes.isNumber(HlTypes.toType(ctx, t))):
						var ra = HlExpr.evalExpr(ctx, a);
						var r = ctx.allocTmp(HBytes);
						ctx.op(ONullCheck(ra));
						ctx.op(OField(r, ra, 1));
						return r;
					case t:
						return HlContext.abort("Invalid array type " + hxc.core.TPrinting.sTypeStr(t), a.pos);
				}
			case "$ref" if (n == 1):
				switch args[0].expr {
					case TLocal(v):
						var r = ctx.allocTmp(HlTypes.toType(ctx, e.type));
						var rv = switch ctx.rtype(r) {
							case HRef(_): ctx.allocVar(v, false);
							case _: invalid();
						}
						ctx.hold(rv); // infinite hold
						ctx.op(ORef(r, rv));
						return r;
					case _:
						return HlContext.abort("Ref should be a local variable", args[0].pos);
				}
			case "$setref" if (n == 2):
				var v = refLocal(args[0]);
				if (v == null) return invalid();
				var r = ctx.allocVar(v, false);
				var rv = HlCasts.evalTo(ctx, args[1], switch ctx.rtype(r) {
					case HRef(t): t;
					case _: invalid();
				});
				ctx.op(OSetref(r, rv));
				return r;
			case "$unref" if (n == 1):
				var v = refLocal(args[0]);
				if (v == null) return invalid();
				var r = ctx.allocVar(v, false);
				var out = ctx.allocTmp(switch ctx.rtype(r) {
					case HRef(t): t;
					case _: invalid();
				});
				ctx.op(OUnref(out, r));
				return out;
			case "$refdata" if (n == 1):
				var v = HlExpr.evalExpr(ctx, args[0]);
				var t = HlTypes.toType(ctx, e.type);
				var r = ctx.allocTmp(t.match(HRef(_)) ? t : invalid());
				ctx.op(ORefData(r, v));
				return r;
			case "$refoffset" if (n == 2):
				var r = HlExpr.evalExpr(ctx, args[0]);
				var re = HlCasts.evalTo(ctx, args[1], HI32);
				var t = ctx.rtype(r);
				var r2 = ctx.allocTmp(t.match(HRef(_)) ? t : invalid());
				ctx.op(ORefOffset(r2, r, re));
				return r2;
			case "$ttype" if (n == 1):
				var r = ctx.allocTmp(HType);
				ctx.op(OType(r, HlTypes.toType(ctx, args[0].type)));
				return r;
			case "$tdyntype" if (n == 1):
				var r = ctx.allocTmp(HType);
				ctx.op(OGetType(r, HlCasts.evalTo(ctx, args[0], HDyn)));
				return r;
			case "$tkind" if (n == 1):
				var r = ctx.allocTmp(HI32);
				ctx.op(OGetTID(r, HlCasts.evalTo(ctx, args[0], HType)));
				return r;
			case "$resources" if (n == 0):
				return resources(ctx);
			case "$rethrow" if (n == 1):
				var r = ctx.allocTmp(HVoid);
				ctx.op(ORethrow(HlCasts.evalTo(ctx, args[0], HDyn)));
				return r;
			case "$allTypes" if (n == 0):
				var r = ctx.allocTmp(HlTypes.toType(ctx, e.type));
				ctx.op(OGetGlobal(r, HlTypes.allocGlobal(ctx, "__types__", ctx.rtype(r))));
				return r;
			case "$allTypes" if (n == 1):
				var v = HlExpr.evalExpr(ctx, args[0]);
				ctx.op(OSetGlobal(HlTypes.allocGlobal(ctx, "__types__", ctx.rtype(v)), v));
				return v;
			case "$hash" if (n == 1):
				switch args[0].expr {
					case TConst(TString(str)):
						var r = ctx.allocTmp(HI32);
						ctx.op(OInt(r, ctx.allocI32(hlHash(str))));
						return r;
					case _:
						return HlContext.abort("Constant string required", args[0].pos);
				}
			case "$enumIndex" if (n == 1):
				return HlExpr.getEnumIndex(ctx, args[0]);
			case "$__mk_pos__" if (n == 3 && args[0].expr.match(TConst(TString(_)))):
				// macros only - generated by reification
				var file = switch args[0].expr {
					case TConst(TString(s)): s;
					case _: HlContext.die();
				}
				var rt = HAbstract("macro_pos", ctx.allocString("macro_pos"));
				var r = ctx.allocTmp(rt);
				var rfile = ctx.allocTmp(HBytes);
				ctx.op(OBytes(rfile, ctx.allocBytes(haxe.io.Bytes.ofString(file))));
				ctx.hold(rfile);
				var min = HlExpr.evalExpr(ctx, args[1]);
				ctx.hold(min);
				var max = HlExpr.evalExpr(ctx, args[2]);
				ctx.op(OCall3(r, HlTypes.allocStd(ctx, "make_macro_pos", [HBytes, HI32, HI32], rt), rfile, min, max));
				ctx.free(rfile);
				ctx.free(min);
				return r;
			case _:
				return unknown();
		}
	}

	// `$resources`: the resources in the order Haxe's `Hashtbl.fold` over com.resources gives them, as a
	// NativeArray of haxe._Resource.ResourceContent
	static function resources(ctx:HlContext):Int {
		var tdef = Lambda.find(ctx.com.types, t -> isPath(TypeFunctions.tPath(t), ["haxe", "_Resource"], "ResourceContent"));
		var c = switch tdef {
			case TClassDecl(c): c;
			case _: HlContext.die();
		}
		var t = HlTypes.classType(ctx, c, [], false);
		var arr = ctx.allocTmp(HArray);
		var rt = ctx.allocTmp(HType);
		ctx.op(OType(rt, t));
		// Hashtbl.fold visits the buckets in order and prepends each binding: the visit order reversed
		var res = ctx.com.resourceFoldOrder();
		res.reverse();
		var size = ctx.regInt(res.length);
		ctx.op(OCall2(arr, HlTypes.allocStd(ctx, "alloc_array", [HType, HI32], HArray), rt, size));
		var ro = ctx.allocTmp(t);
		var rb = ctx.allocTmp(HBytes);
		var ridx = ctx.regInt(0);
		ctx.hold(ridx);
		var hasLen = switch t {
			case HObj(p): p.pindex.exists("dataLen");
			case _: HlContext.die();
		}
		for (k in res) {
			var v = ctx.com.resources.get(k);
			ctx.op(ONew(ro));
			ctx.op(OString(rb, ctx.allocString(k)));
			ctx.op(OSetField(ro, 0, rb));
			// fix for Resource.getString
			var hasNul = false;
			for (i in 0...v.length) if (v.get(i) == 0) {
				hasNul = true;
				break;
			}
			var str = v;
			if (!hasNul) {
				str = haxe.io.Bytes.alloc(v.length + 1);
				str.blit(0, v, 0, v.length);
				str.set(v.length, 0);
			}
			ctx.op(OBytes(rb, ctx.allocBytes(str)));
			ctx.op(OSetField(ro, 1, rb));
			if (hasLen) ctx.op(OSetField(ro, 2, ctx.regInt(v.length)));
			ctx.op(OSetArray(arr, ridx, ro));
			ctx.op(OIncr(ridx));
		}
		ctx.free(ridx);
		return arr;
	}
}
