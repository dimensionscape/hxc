package hxc.codegen.hl;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlContext;

using hxc.codegen.hl.HlContext;

// Functions: a port of genhl.ml's make_debug (lines 316-353), build_capture_vars, gen_method_wrapper and
// make_fun (lines 3049-3303).
class HlFunctions {
	// OCaml's Filename.is_relative (Win32 or Unix)
	static function isRelative(n:String):Bool {
		if (!hxc.core.Globals.isWindows) return !StringTools.startsWith(n, "/");
		return !StringTools.startsWith(n, "/") && !StringTools.startsWith(n, "\\") && !(n.length >= 2 && n.charAt(1) == ":");
	}

	// OCaml's Filename.concat: the platform separator only when the directory doesn't already end in one
	static function filenameConcat(dir:String, file:String):String {
		var win = hxc.core.Globals.isWindows;
		var last = dir.length == 0 ? "" : dir.charAt(dir.length - 1);
		var isSep = last == "/" || (win && (last == "\\" || last == ":"));
		return dir.length == 0 || isSep ? dir + file : dir + (win ? "\\" : "/") + file;
	}

	// OCaml's Sys.getcwd: hxcpp's Sys.getCwd adds a "/" when the directory doesn't end in a separator
	static function ocamlGetcwd():String {
		var d = Sys.getCwd();
		if (d.length > 1 && StringTools.endsWith(d, "/")) {
			var prev = d.charAt(d.length - 2);
			if (prev != "/" && prev != "\\") d = d.substr(0, d.length - 1);
		}
		return d;
	}

	// genhl.ml: make_debug's get_relative_path
	static function getRelativePath(ctx:HlContext, p:Position):String {
		if (ctx.com.defines.rawDefined("absolute_path")) {
			return isRelative(p.file) ? filenameConcat(ocamlGetcwd(), p.file) : p.file;
		}
		// lookup relative path
		var len = p.file.length;
		for (path in ctx.com.classPath) {
			var l = path.length;
			if (len > l && p.file.substr(0, l) == path) return p.file.substr(l);
		}
		return p.file;
	}

	// genhl.ml: make_debug
	public static function makeDebug(ctx:HlContext, arr:Array<Position>):Array<{file:Int, line:Int}> {
		var pos = {file: 0, line: 0};
		var curFile = 0;
		var curLine = 0;
		var cur = Position.nullPos;
		var out = [];
		for (p in arr) {
			if (p != cur) {
				var file = if (p.file == cur.file) curFile else HlContext.lookup(ctx.cdebugFiles, p.file,
					() -> ctx.isMacro ? p.file : getRelativePath(ctx, p));
				var line = ctx.isMacro ? (p.min | ((p.max - p.min) << 20)) : hxc.generators.cpp.CppEmit.getErrorLine(p);
				if (line != curLine || file != curFile) {
					curFile = file;
					curLine = line;
					pos = {file: file, line: line};
				}
				cur = p;
			}
			out.push(pos);
		}
		return out;
	}

	// genhl.ml: build_capture_vars
	public static function buildCaptureVars(ctx:HlContext, f:TFunc):HlMethodCapture {
		var ignoredVars = new Map<Int, Bool>();
		var usedVars = new Map<Int, TVar>();
		// get all captured vars in scope, ignore vars that are declared
		function declVar(v:TVar) {
			if (TypeFunctions.hasVarFlag(v, VCaptured)) ignoredVars.set(v.id, true);
		}
		function useVar(v:TVar) {
			if (TypeFunctions.hasVarFlag(v, VCaptured)) usedVars.set(v.id, v);
		}
		function loop(e:TExpr) {
			switch e.expr {
				case TLocal(v): useVar(v);
				case TVarExpr(v, _): declVar(v);
				case TTry(_, catches): for (c in catches) declVar(c.v);
				case TFunction(f): for (a in f.args) declVar(a.v);
				case _:
			}
			hxc.core.TexprTools.iter(loop, e);
		}
		for (a in f.args) declVar(a.v);
		loop(f.expr);
		var cvars = [for (id => v in usedVars) if (!ignoredVars.exists(id)) v];
		cvars.sort((v1, v2) -> v1.id - v2.id);
		var indexes = new Map<Int, Int>();
		var v0t = cvars.length == 1 ? HlTypes.toType(ctx, cvars[0].type) : HDyn;
		var ct:HlType, group:Bool;
		if (cvars.length == 0) {
			ct = HVoid;
			group = false;
		} else if (cvars.length == 1 && HlTypes.isNullable(v0t)) {
			ct = v0t;
			group = false;
		} else {
			for (i in 0...cvars.length) indexes.set(cvars[i].id, i);
			var ctypes = [for (v in cvars) HlTypes.toType(ctx, v.type)];
			ct = HlTypes.tupleType(ctx, ctypes);
			group = true;
		}
		return {cMap: indexes, cVars: cvars, cType: ct, cGroup: group};
	}

	// genhl.ml: gen_method_wrapper
	public static function genMethodWrapper(ctx:HlContext, rt:HlType, t:HlType, p:Position):Int {
		var key = HlTypes.typeKey(rt) + "/" + HlTypes.typeKey(t);
		var fid = ctx.methodWrappers.get(key);
		if (fid != null) return fid;
		var fid = HlContext.lookupAlloc(ctx.cfids, true);
		ctx.methodWrappers.set(key, fid);
		var old = ctx.m;
		var targs, tret, iargs, iret;
		switch t {
			case HFun(args, ret):
				targs = args;
				tret = ret;
			case _:
				return HlContext.die();
		}
		switch rt {
			case HFun(args, ret):
				iargs = args;
				iret = ret;
			case _:
				return HlContext.die();
		}
		ctx.m = new HlMethodContext(fid, HDyn, HlContext.nullCapture(), false);
		var rfun = ctx.allocTmp(rt);
		var rargs = [for (t in targs) {
			var r = ctx.allocTmp(t);
			ctx.hold(r);
			r;
		}];
		var casts = [for (i in 0...rargs.length) {
			var r2 = HlCasts.castTo(ctx, rargs[i], iargs[i], p, true);
			ctx.hold(r2);
			ctx.free(rargs[i]);
			r2;
		}];
		for (r in casts) ctx.free(r);
		var rret = ctx.allocTmp(iret);
		ctx.op(OCallClosure(rret, rfun, casts));
		ctx.op(ORet(HlCasts.castTo(ctx, rret, tret, p)));
		var f:HlFunction = {
			fpath: {cls: "", name: ""},
			findex: fid,
			ftype: HFun([rt].concat(targs), tret),
			regs: ctx.m.mregs.arr.copy(),
			code: ctx.m.mops.copy(),
			debug: makeDebug(ctx, ctx.m.mdebug),
			assigns: ctx.m.massign.copy()
		};
		ctx.m = old;
		ctx.cfunctions.push(f);
		return fid;
	}

	static function hasFinalJump(e:TExpr):Bool {
		// prevents a jump outside function bounds error
		return switch e.expr {
			case TBlock(el): el.length == 0 ? false : hasFinalJump(el[el.length - 1]);
			case TParenthesis(e): hasFinalJump(e);
			case TReturn(_): false;
			case _: true;
		}
	}

	// genhl.ml: make_fun
	public static function makeFun(ctx:HlContext, name:{cls:String, name:String}, fidx:Int, f:TFunc, cthis:Null<TClass>,
			cparent:Null<HlMethodCapture>, ?genContent:Void->Void):HlMethodCapture {
		var old = ctx.m;
		var capt = buildCaptureVars(ctx, f);
		var hasCapturedVars = capt.cVars.length > 0;
		if (cparent != null && hasCapturedVars && Lambda.foreach(capt.cVars, v -> cparent.cMap.exists(v.id))) capt = cparent;

		ctx.m = new HlMethodContext(fidx, HlTypes.toType(ctx, f.type), capt, cthis != null);

		ctx.setCurpos(f.expr.pos);

		var tthis:Null<HlType> = null;
		if (cthis != null) {
			tthis = HlTypes.toType(ctx, TInst(cthis, []));
			ctx.hold(ctx.allocTmp(tthis)); // index 0
		}

		var rcapt:Null<Int> = null;
		if (hasCapturedVars && cparent != null) {
			if (capt.cGroup) {
				var r = ctx.allocTmp(capt.cType);
				ctx.hold(r);
				rcapt = r;
			} else {
				rcapt = ctx.allocVar(capt.cVars[0], true);
			}
		}

		var args = [for (a in f.args) {
			var v = a.v;
			var t = HlTypes.toType(ctx, v.type);
			var r = ctx.allocVar(a.c == null ? v : new TVar(v.id, v.name,
				!HlTypes.isNullable(t) ? TAbstract(ctx.refAbstract, [v.type]) : v.type, v.kind, v.extra, v.meta, v.flags, v.pos), true);
			ctx.addAssign(v); // record var name
			ctx.rtype(r);
		}];

		if (hasCapturedVars) ctx.m.mcaptreg = if (rcapt == null && !capt.cGroup) {
			-1;
		} else if (rcapt == null) {
			var r = ctx.allocTmp(capt.cType);
			ctx.hold(r);
			ctx.op(OEnumAlloc(r, 0));
			ctx.addCapture(r);
			r;
		} else {
			ctx.addCapture(rcapt);
			rcapt;
		}

		for (a in f.args) {
			var v = a.v;
			var r = ctx.allocVar(v, false);
			var vt = HlTypes.toType(ctx, v.type);
			var capt = ctx.capturedIndex(v);
			var c = a.c;
			if (c == null || c.expr.match(TConst(TNull))) {
			} else if (!HlTypes.isNullable(vt)) {
				// if optional but not null, turn into a not nullable here
				var j = ctx.jump(n -> OJNotNull(r, n));
				var t = ctx.allocTmp(vt);
				switch vt {
					case HUI8 | HUI16 | HI32 | HI64:
						switch c.expr {
							case TConst(TInt(i)): ctx.op(OInt(t, ctx.allocI32(i)));
							case TConst(TFloat(s)): ctx.op(OInt(t, ctx.allocI32(Std.int(hxc.core.Numeric.parseFloatLit(s)))));
							case _: HlContext.die();
						}
					case HF32 | HF64:
						switch c.expr {
							case TConst(TInt(i)): ctx.op(OFloat(t, ctx.allocFloat(i)));
							case TConst(TFloat(s)): ctx.op(OFloat(t, ctx.allocFloat(hxc.core.Numeric.parseFloatLit(s))));
							case _: HlContext.die();
						}
					case HBool:
						switch c.expr {
							case TConst(TBool(b)): ctx.op(OBool(t, b));
							case _: HlContext.die();
						}
					case _:
						HlContext.die();
				}
				if (capt == null) ctx.addAssign(v);
				var jend = ctx.jump(n -> OJAlways(n));
				j();
				ctx.op(OUnref(t, r));
				if (capt == null) ctx.addAssign(v);
				jend();
				ctx.m.mvars.set(v.id, t);
				ctx.free(r);
				ctx.hold(t);
			} else {
				var j = ctx.jump(n -> OJNotNull(r, n));
				function underlying() return HlTypes.toType(ctx, TypeFunctions.followWithAbstracts(v.type));
				switch c.expr {
					case TConst(TNull | TThis | TSuper):
						HlContext.die();
					case TConst(TInt(i)) if (underlying().match(HUI8 | HUI16 | HI32 | HI64 | HDyn)):
						var tmp = ctx.allocTmp(HI32);
						ctx.op(OInt(tmp, ctx.allocI32(i)));
						ctx.op(OToDyn(r, tmp));
					case TConst(TFloat(s)) if (underlying().match(HUI8 | HUI16 | HI32 | HI64)):
						var tmp = ctx.allocTmp(HI32);
						ctx.op(OInt(tmp, ctx.allocI32(Std.int(hxc.core.Numeric.parseFloatLit(s)))));
						ctx.op(OToDyn(r, tmp));
					case TConst(TInt(i)):
						var tmp = ctx.allocTmp(HF64);
						ctx.op(OFloat(tmp, ctx.allocFloat(i)));
						ctx.op(OToDyn(r, tmp));
					case TConst(TFloat(s)):
						var tmp = ctx.allocTmp(HF64);
						ctx.op(OFloat(tmp, ctx.allocFloat(hxc.core.Numeric.parseFloatLit(s))));
						ctx.op(OToDyn(r, tmp));
					case TConst(TBool(b)):
						var tmp = ctx.allocTmp(HBool);
						ctx.op(OBool(tmp, b));
						ctx.op(OToDyn(r, tmp));
					case TConst(TString(s)):
						ctx.op(OMov(r, HlCasts.makeString(ctx, s, f.expr.pos)));
					case _:
						ctx.op(OMov(r, HlCasts.evalTo(ctx, c, vt)));
				}
				j();
			}
			if (capt != null) ctx.op(OSetEnumField(ctx.m.mcaptreg, capt, ctx.allocVar(v, false)));
		}

		if (genContent != null) genContent();

		HlExpr.evalExpr(ctx, f.expr);
		var tret = HlTypes.toType(ctx, f.type);
		ctx.setCurpos(HlTypes.maxPos(f.expr));
		if (HlTypes.teq(tret, HVoid)) {
			ctx.op(ORet(ctx.allocTmp(HVoid)));
		} else if (hasFinalJump(f.expr)) {
			var r = ctx.allocTmp(tret);
			switch tret {
				case HI32 | HUI8 | HUI16 | HI64: ctx.op(OInt(r, ctx.allocI32(0)));
				case HF32 | HF64: ctx.op(OFloat(r, ctx.allocFloat(0.)));
				case HBool: ctx.op(OBool(r, false));
				case _: ctx.op(ONull(r));
			}
			ctx.op(ORet(r));
		}
		var fargs = (tthis == null ? [] : [tthis]).concat(rcapt == null ? [] : [ctx.rtype(rcapt)]).concat(args);
		var hlf:HlFunction = {
			fpath: name,
			findex: fidx,
			ftype: HFun(fargs, tret),
			regs: ctx.m.mregs.arr.copy(),
			code: ctx.m.mops.copy(),
			debug: makeDebug(ctx, ctx.m.mdebug),
			assigns: ctx.m.massign.copy()
		};
		ctx.m = old;
		ctx.definedFuns.set(fidx, true);
		var f = if (ctx.optimize && (genContent == null || name.cls != "" || name.name != "")) {
			var t = hxc.core.Timer.timer(["generate", "hl", "opt"]);
			var dumpOut = ctx.dumpOut;
			var f = HlOpt.optimize(dumpOut == null ? null : line -> {
				dumpOut.writeString(line + "\n");
			}, i -> ctx.cstrings.arr[i], hlf);
			t();
			f;
		} else hlf;
		ctx.cfunctions.push(f);
		return capt;
	}
}
