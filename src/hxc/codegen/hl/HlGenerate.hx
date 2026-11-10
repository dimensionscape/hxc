package hxc.codegen.hl;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlContext;

using hxc.codegen.hl.HlContext;

// The generator's entry and the per-type generation: a port of genhl.ml's generate_static,
// generate_member, generate_type, generate_static_init (lines 3305-3652), create_context, add_types,
// build_code and generate (lines 3968-4189, without hl_check, the interpreter and HL/C).
class HlGenerate {
	static function metaString(e:Expr):Null<String> {
		return switch e.expr {
			case EConst(CString(s, _)): s;
			case _: null;
		}
	}

	// genhl.ml: generate_static
	static function generateStatic(ctx:HlContext, c:TClass, f:TClassField):Void {
		switch f.kind {
			case Var(_):
				return;
			case Method(_) if (TypeFunctions.hasClassFieldFlag(f, CfExtern)):
				return;
			case Method(_):
		}
		function addNative(lib:String, name:String) {
			var fid = HlTypes.allocFid(ctx, c, f);
			HlContext.lookup(ctx.cnatives, name + "@" + lib + "|" + fid, function() {
				ctx.definedFuns.set(fid, true);
				// the tuple's components right to left
				var t = HlTypes.toType(ctx, f.type);
				var n = ctx.allocString(name);
				var l = ctx.allocString(lib);
				return {lib: l, name: n, t: t, findex: fid};
			});
		}
		function makeBody(?genContent:Void->Void) {
			switch f.expr {
				case {expr: TFunction(fn)}:
					HlFunctions.makeFun(ctx, {cls: Globals.sTypePath(c.path), name: f.name}, HlTypes.allocFid(ctx, c, f), fn, null, null, genContent);
				case _:
					if (!TypeFunctions.hasMeta(":noExpr", f.meta)) HlContext.abort("Missing function body", f.pos);
			}
		}
		for (m in f.meta) {
			if (m.name != ":hlNative") continue;
			var params = m.params;
			if (params.length == 2 && metaString(params[0]) != null && metaString(params[1]) != null) {
				addNative(metaString(params[0]), metaString(params[1]));
			} else if (params.length == 1 && metaString(params[0]) != null) {
				addNative(metaString(params[0]), f.name);
			} else if (params.length == 1 && params[0].expr.match(EConst(CFloat(_)))) {
				var ver = switch params[0].expr {
					case EConst(CFloat(v, _)): v;
					case _: "";
				}
				var curVer = ctx.com.defines.rawDefined("hl_ver") ? ctx.com.defines.rawDefinedValue("hl_ver") : "";
				if (hxc.core.StringSort.compare(curVer, ver) < 0) {
					makeBody(function() {
						ctx.op(OThrow(HlCasts.makeString(ctx, "Requires compiling with -D hl-ver=" + ver + ".0 or higher", Position.nullPos)));
					});
				} else {
					addNative("std", f.name);
				}
			} else if (params.length == 0) {
				addNative("std", f.name);
			} else {
				HlContext.abort("Invalid @:hlNative decl", m.pos);
			}
			return;
		}
		makeBody();
	}

	// genhl.ml: generate_member
	static function generateMember(ctx:HlContext, c:TClass, f:TClassField):Void {
		switch f.kind {
			case Var(_):
				return;
			case _ if (HlTypes.isExternField(f)):
				return;
			case Method(_):
		}
		var genContent = f.name != "new" ? null : function() {
			var o = switch HlTypes.classType(ctx, c, TypeFunctions.extractParamTypes(c.params), false) {
				case HObj(o) | HStruct(o): o;
				case _: HlContext.die();
			}
			// init dynamic functions
			for (f in c.orderedFields) switch f.kind {
				case Method(MethDynamic):
					var r = ctx.allocTmp(HlTypes.toType(ctx, f.type));
					var idx = HlTypes.getIndex(f.name, o);
					if (idx == null) HlContext.die();
					var fid = idx.index;
					ctx.op(OGetThis(r, fid));
					ctx.op(OJNotNull(r, 2));
					ctx.op(OInstanceClosure(r, HlTypes.allocFid(ctx, c, f), 0));
					ctx.op(OSetThis(fid, r));
				case _:
			}
		}
		var ff = switch f.expr {
			case {expr: TFunction(fn)}: fn;
			case null if (TypeFunctions.hasClassFieldFlag(f, CfAbstract)):
				var sig = switch TypeFunctions.follow(f.type) {
					case TFun(sig): sig;
					case _: HlContext.die();
				}
				var args:Array<TFuncArg> = [for (a in sig.args) {v: TypeFunctions.allocVar(VGenerated, a.name, a.t, Position.nullPos), c: null}];
				new TFunc(args, sig.ret, TypeFunctions.mk(TThrow(TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, Position.nullPos)), TypeFunctions.tDynamic, Position.nullPos));
			case _:
				HlContext.abort("Missing function body", f.pos);
		}
		HlFunctions.makeFun(ctx, {cls: Globals.sTypePath(c.path), name: f.name}, HlTypes.allocFid(ctx, c, f), ff, c, null, genContent);
		if (f.name == "toString" && !TypeFunctions.hasClassFieldFlag(f, CfOverride) && !c.fields.exists("__string") && HlTypes.isToString(f.type)) {
			var p = f.pos;
			// function __string() return this.toString().bytes
			var params = TypeFunctions.extractParamTypes(c.params);
			var ethis = TypeFunctions.mk(TConst(TThis), TInst(c, params), p);
			var tstrT = ctx.com.basic.tstring;
			var tstr = TypeFunctions.mk(TCall(TypeFunctions.mk(TField(ethis, FInstance(c, params, f)), f.type, p), []), tstrT, p);
			var cstr = switch tstrT {
				case TInst(c, _): c;
				case _: HlContext.die();
			}
			var cfBytes = cstr.fields.get("bytes");
			if (cfBytes == null) HlContext.die();
			var estr = TypeFunctions.mk(TReturn(TypeFunctions.mk(TField(tstr, FInstance(cstr, [], cfBytes)), cfBytes.type, p)), ctx.com.basic.tvoid, p);
			HlFunctions.makeFun(ctx, {cls: Globals.sTypePath(c.path), name: "__string"}, HlTypes.allocFunPath(ctx, c.path, "__string"),
				new TFunc([], cfBytes.type, estr), c, null);
		}
	}

	// generate_type's merge_inits: a constructor's block statements from outside its span (the member
	// initialisers) take the function's position
	static function mergeInits(e:Null<TExpr>):Null<TExpr> {
		if (e == null) return e;
		switch e.expr {
			case TFunction(f):
				switch f.expr.expr {
					case TBlock(el):
						function merge(ei:TExpr):TExpr {
							function loop(ei:TExpr):TExpr {
								var ei = hxc.core.TexprTools.mapExpr(loop, ei);
								return TypeFunctions.mk(ei.expr, ei.type, e.pos);
							}
							return (ei.pos.min < e.pos.min || ei.pos.max > e.pos.max) ? loop(ei) : ei;
						}
						var body = TypeFunctions.mk(TBlock([for (ei in el) merge(ei)]), f.expr.type, f.expr.pos);
						return TypeFunctions.mk(TFunction(new TFunc(f.args, f.type, body)), e.type, e.pos);
					case _:
				}
			case _:
		}
		return e;
	}

	// genhl.ml: generate_type
	static function generateType(ctx:HlContext, t:ModuleType):Void {
		switch t {
			case TClassDecl(c) if (TypeFunctions.hasClassFlag(c, CInterface)):
			case TClassDecl(c) if (TypeFunctions.hasClassFlag(c, CExtern)):
				for (f in c.orderedStatics) for (m in f.meta) if (m.name == ":hlNative") generateStatic(ctx, c, f);
			case TClassDecl(c):
				for (f in c.orderedStatics) generateStatic(ctx, c, f);
				if (c.constructor != null) {
					var f = TypeFunctions.copyField(c.constructor);
					f.expr = mergeInits(f.expr);
					generateMember(ctx, c, f);
				}
				for (f in c.orderedFields) generateMember(ctx, c, f);
			case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
		}
	}

	// genhl.ml: generate_static_init
	static function generateStaticInit(ctx:HlContext, types:Array<ModuleType>, main:Null<TExpr>):Int {
		var tVoid = ctx.com.basic.tvoid;
		function genContent() {
			var isInit = ctx.allocTmp(HBool);
			ctx.op(OCall0(isInit, HlTypes.allocFunPath(ctx, new Path([], "Type"), "init")));
			ctx.hold(isInit);
			// init class values
			for (t in types) switch t {
				case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern)
						&& !(HlTypes.isArrayClass(Globals.sTypePath(c.path)) && c.path.name != "ArrayDyn")
						&& c != ctx.coreType && c != ctx.coreEnum):
					var path = c == ctx.arrayImpl.abase ? new Path([], "Array") : c == ctx.baseClass ? new Path([], "Class") : c.path;
					var cg = HlTypes.classGlobal(ctx, c, false);
					var g = cg.g, ct = cg.t;
					var ctype = c == ctx.arrayImpl.abase ? ctx.arrayImpl.aall : c;
					var t = HlTypes.classType(ctx, ctype, TypeFunctions.extractParamTypes(ctype.params), false);
					function index(name:String):Int {
						return switch ct {
							case HObj(o):
								var i = HlTypes.getIndex(name, o);
								if (i == null) HlContext.die();
								i.index;
							case _: HlContext.die();
						}
					}
					var rc = switch t {
						case HObj(o) if ((o.pclassglobal == null ? -1 : o.pclassglobal) != g):
							// manual registration for objects with prototype tricks (Array)
							var rc = ctx.allocTmp(ct);
							ctx.op(ONew(rc));
							ctx.op(OSetGlobal(g, rc));
							ctx.hold(rc);
							var rt = ctx.allocTmp(HType);
							ctx.op(OType(rt, t));
							ctx.op(OSetField(rc, index("__type__"), rt));
							var rn = HlExpr.evalExpr(ctx, TypeFunctions.mk(TConst(TString(Globals.sTypePath(path))), ctx.com.basic.tstring, c.pos));
							ctx.op(OSetField(rc, index("__name__"), rn));
							var rname = ctx.allocTmp(HBytes);
							ctx.op(OString(rname, ctx.allocString(Globals.sTypePath(path))));
							var freg = HlTypes.allocFunPath(ctx, new Path([], "Type"), "register");
							ctx.op(OCall2(ctx.allocTmp(HVoid), freg, rname, rc));
							rc;
						case _:
							var rct = ctx.allocTmp(HType);
							ctx.op(OType(rct, ct));
							ctx.hold(rct);
							var rt = ctx.allocTmp(HType);
							ctx.op(OType(rt, t));
							var rname = ctx.allocTmp(HBytes);
							ctx.op(OString(rname, ctx.allocString(Globals.sTypePath(path))));
							var rc = ctx.allocTmp(HlTypes.classType(ctx, ctx.baseClass, [], false));
							ctx.op(OCall3(rc, HlTypes.allocFunPath(ctx, new Path([], "Type"), "initClass"), rct, rt, rname));
							ctx.hold(rc);
							ctx.free(rct);
							rc;
					}
					if (TypeFunctions.hasClassFlag(c, CInterface)) {
						var l = [];
						function lookup(cv:TClass):Bool {
							return Lambda.exists(cv.interfaces, i -> i.c == c || lookup(i.c));
						}
						for (t in ctx.com.types) switch t {
							case TClassDecl(c2) if (!TypeFunctions.hasClassFlag(c2, CInterface) && !TypeFunctions.hasClassFlag(c2, CExtern)):
								if (lookup(c2)) l.unshift(c2);
							case _:
						}
						var ra = ctx.allocTmp(HArray);
						var rt = ctx.allocTmp(HType);
						ctx.op(OType(rt, HType));
						// the constructor's arguments right to left
						var n = ctx.regInt(l.length);
						ctx.op(OCall2(ra, HlTypes.allocStd(ctx, "alloc_array", [HType, HI32], HArray), rt, n));
						for (i in 0...l.length) {
							ctx.op(OType(rt, HlTypes.toType(ctx, TInst(l[i], []))));
							ctx.op(OSetArray(ra, ctx.regInt(i), rt));
						}
						ctx.op(OSetField(rc, index("__implementedBy__"), ra));
						// TODO : use a plain class for interface object since we don't allow statics
						var rt = ctx.allocTmp(ct);
						ctx.op(OSafeCast(rt, rc));
						ctx.op(OSetGlobal(g, rt));
					}
					var meta = hxc.core.TexprTools.buildMetadata(ctx.com.basic, TClassDecl(c));
					if (meta != null) {
						var r = HlCasts.evalTo(ctx, meta, HDyn);
						ctx.op(OSetField(rc, index("__meta__"), r));
					}
					ctx.free(rc);
				case TEnumDecl(e) if (!e.isExtern):
					var et = HlTypes.enumClass(ctx, e);
					var t = HlTypes.enumType(ctx, e);
					var ret = ctx.allocTmp(HType);
					ctx.op(OType(ret, et));
					ctx.hold(ret);
					var rt = ctx.allocTmp(HType);
					ctx.op(OType(rt, t));
					var r = ctx.allocTmp(HlTypes.classType(ctx, ctx.baseEnum, [], false));
					ctx.op(OCall2(r, HlTypes.allocFunPath(ctx, new Path([], "Type"), "initEnum"), ret, rt));
					ctx.free(ret);
					function index(name:String):Int {
						return switch et {
							case HObj(o):
								var i = HlTypes.getIndex(name, o);
								if (i == null) HlContext.die();
								i.index;
							case _: HlContext.die();
						}
					}
					var avalues = ctx.allocTmp(HArray);
					ctx.op(OField(avalues, r, index("__evalues__")));
					for (n in e.names) {
						var f = e.constrs.get(n);
						switch TypeFunctions.follow(f.type) {
							case TFun(_):
							case _:
								var g = HlTypes.allocGlobal(ctx, HlTypes.efieldName(e, f), t);
								var r = ctx.allocTmp(t);
								var rd = ctx.allocTmp(HDyn);
								var ri = ctx.regInt(f.index);
								ctx.op(OGetArray(rd, avalues, ri));
								ctx.op(OSafeCast(r, rd));
								ctx.op(OSetGlobal(g, r));
						}
					}
					var meta = hxc.core.TexprTools.buildMetadata(ctx.com.basic, TEnumDecl(e));
					if (meta != null) {
						var rm = HlCasts.evalTo(ctx, meta, HDyn);
						ctx.op(OSetField(r, index("__meta__"), rm));
					}
				case TAbstractDecl(a) if (a.path.pack.length == 0):
					var name = a.path.name;
					switch name {
						case "Int" | "Float" | "Dynamic" | "Bool":
							var isBool = name == "Bool";
							var t = HlTypes.classType(ctx, isBool ? ctx.coreEnum : ctx.coreType, [], false);
							function index(name:String):Int {
								return switch t {
									case HObj(o):
										var i = HlTypes.getIndex(name, o);
										if (i == null) HlContext.die();
										i.index;
									case _: HlContext.die();
								}
							}
							var g = HlTypes.allocGlobal(ctx, "$" + name, t);
							var r = ctx.allocTmp(t);
							var rt = ctx.allocTmp(HType);
							ctx.op(ONew(r));
							ctx.op(OType(rt, switch name {
								case "Int": HI32;
								case "Float": HF64;
								case "Dynamic": HDyn;
								case _: HBool;
							}));
							ctx.op(OSetField(r, index("__type__"), rt));
							var rs = HlCasts.makeString(ctx, name, a.pos);
							ctx.op(OSetField(r, index(isBool ? "__ename__" : "__name__"), rs));
							ctx.op(OSetGlobal(g, r));
							var bytes = ctx.allocTmp(HBytes);
							ctx.op(OString(bytes, ctx.allocString(name)));
							var freg = HlTypes.allocFunPath(ctx, new Path([], "Type"), "register");
							ctx.op(OCall2(ctx.allocTmp(HVoid), freg, bytes, r));
						case _:
					}
				case _:
			}
			var j = ctx.jump(d -> OJTrue(isInit, d));
			ctx.op(ORet(ctx.allocTmp(HVoid)));
			j();
			ctx.free(isInit);
		}
		// init class statics
		var initExprs = [];
		var exprs = [];
		for (t in types) {
			switch t {
				case TClassDecl(c) if (c.init != null): initExprs.push(c.init);
				case _:
			}
			switch t {
				case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern)):
					for (f in c.orderedStatics) switch [f.kind, f.expr] {
						case [Var(_), e] if (e != null):
							var p = e.pos;
							exprs.push(TypeFunctions.mk(TBinop(OpAssign, TypeFunctions.mk(TField(TypeFunctions.mk(TTypeExpr(t), TypeFunctions.tDynamic, p), FStatic(c, f)), f.type, p), e), f.type, p));
						case _:
					}
				case _:
			}
		}
		// call main()
		if (main != null) exprs.push(main);
		var fid = HlContext.lookupAlloc(ctx.cfids, true);
		HlFunctions.makeFun(ctx, {cls: "", name: ""}, fid, new TFunc([], tVoid, TypeFunctions.mk(TBlock(initExprs.concat(exprs)), tVoid, Position.nullPos)), null, null, genContent);
		return fid;
	}

	// genhl.ml: create_context
	static function createContext(com:Context, isMacro:Bool):HlContext {
		function getType(name:String):ModuleType {
			for (pack in [["hl"], ["hl", "types"]]) for (t in com.types) {
				var p = TypeFunctions.tPath(t);
				if (p.name == name && p.pack.join(".") == pack.join(".")) return t;
			}
			throw "hl type " + name + " not found";
		}
		function getClass(name:String):TClass {
			return switch getType(name) {
				case TClassDecl(c): c;
				case _: HlContext.die();
			}
		}
		function getAbstract(name:String):TAbstract {
			return switch getType(name) {
				case TAbstractDecl(a): a;
				case _: HlContext.die();
			}
		}
		var ctx = new HlContext(com);
		ctx.isMacro = isMacro;
		ctx.optimize = !com.defines.rawDefined("hl_no_opt");
		ctx.m = new HlMethodContext(0, HVoid, HlContext.nullCapture(), false);
		ctx.arrayImpl = {
			aall: getClass("ArrayAccess"),
			abase: getClass("ArrayBase"),
			adyn: getClass("ArrayDyn"),
			aobj: getClass("ArrayObj"),
			aui16: getClass("ArrayBytes_hl_UI16"),
			ai32: getClass("ArrayBytes_Int"),
			af32: getClass("ArrayBytes_hl_F32"),
			af64: getClass("ArrayBytes_Float")
		};
		ctx.baseClass = getClass("Class");
		ctx.baseEnum = getClass("Enum");
		ctx.baseType = getClass("BaseType");
		ctx.coreType = getClass("CoreType");
		ctx.coreEnum = getClass("CoreEnum");
		ctx.refAbstract = getAbstract("Ref");
		ctx.tstring = HlTypes.toType(ctx, com.basic.tstring);
		ctx.allocString("");
		HlTypes.classType(ctx, ctx.baseClass, [], false);
		return ctx;
	}

	// genhl.ml: add_types
	static function addTypes(ctx:HlContext, types:Array<ModuleType>):Void {
		for (t in types) switch t {
			case TClassDecl(c) if (c.path.pack.join(".") == "hl.types" && (c.path.name == "BytesIterator" || c.path.name == "BytesKeyValueIterator" || c.path.name == "ArrayBytes")):
				TypeFunctions.addClassFlag(c, CExtern);
			case TClassDecl(c):
				function loop(p:Null<TClassWithParams>, f:TClassField):Bool {
					if (p != null && (p.c.fields.exists(f.name) || loop(p.c.superClass, f))) {
						ctx.overrides.set(HlContext.overrideKey(f.name, p.c.path), true);
						return true;
					}
					return false;
				}
				if (!ctx.isMacro) for (f in c.orderedFields) if (TypeFunctions.hasClassFieldFlag(f, CfOverride)) loop(c.superClass, f);
				for (m in c.meta) {
					if (m.name != ":hlNative") continue;
					var lib:String, prefix:String;
					var s0 = m.params.length > 0 ? metaString(m.params[0]) : null;
					var s1 = m.params.length > 1 ? metaString(m.params[1]) : null;
					if (m.params.length == 1 && s0 != null) {
						lib = s0;
						prefix = "";
					} else if (m.params.length == 2 && s0 != null && s1 != null) {
						lib = s0;
						prefix = s1;
					} else {
						HlContext.abort("hlNative on class requires library name", m.pos);
						continue;
					}
					// adds :hlNative for all empty methods
					for (f in c.orderedStatics) switch f.kind {
						case Method(MethNormal) if (!Lambda.exists(f.meta, m -> m.name == ":hlNative")):
							var empty = switch f.expr {
								case null: true;
								case {expr: TFunction({expr: {expr: TBlock([])}})}: true;
								case {expr: TFunction({expr: {expr: TBlock([{expr: TReturn({expr: TConst(_)})}])}})}: true;
								case _: false;
							}
							if (empty) {
								var name = prefix + (~/[A-Z]+/g.map(f.name, r -> "_" + r.matched(0))).toLowerCase();
								f.meta = [{name: ":hlNative", params: [
									new Expr(EConst(CString(lib, SDoubleQuotes)), m.pos),
									new Expr(EConst(CString(name, SDoubleQuotes)), m.pos)
								], pos: m.pos}].concat(f.meta);
							}
						case _:
					}
				}
			case _:
		}
		for (t in types) generateType(ctx, t);
	}

	// genhl.ml: build_code
	static function buildCode(ctx:HlContext, types:Array<ModuleType>, main:Null<TExpr>):HlCodeData {
		var ep = generateStaticInit(ctx, types, main);
		var bytes = ctx.cbytes.arr.copy();
		return {
			version: bytes.length == 0 ? 4 : 5,
			entrypoint: ep,
			strings: ctx.cstrings.arr.copy(),
			bytes: bytes,
			ints: ctx.cints.arr.copy(),
			floats: ctx.cfloats.arr.copy(),
			globals: ctx.cglobals.arr.copy(),
			natives: ctx.cnatives.arr.copy(),
			functions: ctx.cfunctions.copy(),
			debugfiles: ctx.cdebugFiles.arr.copy(),
			constants: ctx.cconstants.arr.copy()
		};
	}

	// OCaml's Array.sort: a ternary heap sort, so equal elements do not keep their order.
	static function ocamlArraySort<X>(a:Array<X>, cmp:X->X->Int):Void {
		// maxson's `raise (Bottom i)` is answered as -1 - i
		function maxson(l:Int, i:Int):Int {
			var i31 = i + i + i + 1;
			var x = i31;
			if (i31 + 2 < l) {
				if (cmp(a[i31], a[i31 + 1]) < 0) x = i31 + 1;
				if (cmp(a[x], a[i31 + 2]) < 0) x = i31 + 2;
				return x;
			}
			return if (i31 + 1 < l && cmp(a[i31], a[i31 + 1]) < 0) i31 + 1 else if (i31 < l) i31 else -1 - i;
		}
		function trickle(l:Int, i:Int, e:X):Void {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) {
					a[-1 - j] = e;
					return;
				}
				if (cmp(a[j], e) > 0) {
					a[i] = a[j];
					i = j;
				} else {
					a[i] = e;
					return;
				}
			}
		}
		function bubble(l:Int, i:Int):Int {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) return -1 - j;
				a[i] = a[j];
				i = j;
			}
		}
		function trickleup(i:Int, e:X):Void {
			while (true) {
				var father = Std.int((i - 1) / 3);
				if (cmp(a[father], e) < 0) {
					a[i] = a[father];
					if (father > 0) i = father;
					else {
						a[0] = e;
						return;
					}
				} else {
					a[i] = e;
					return;
				}
			}
		}
		var l = a.length;
		var i = Std.int((l + 1) / 3) - 1;
		while (i >= 0) {
			trickle(l, i, a[i]);
			i--;
		}
		i = l - 1;
		while (i >= 2) {
			var e = a[i];
			a[i] = a[0];
			trickleup(bubble(i, 0), e);
			i--;
		}
		if (l > 1) {
			var e = a[1];
			a[1] = a[0];
			a[0] = e;
		}
	}

	static function escapeCommand(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var ch = s.charAt(i);
			if (ch == "\"" || ch == "\\") b.add("\\");
			b.add(ch);
		}
		return "\"" + b.toString() + "\"";
	}

	// path.ml: file_extension (the text after the last ".", or the whole name when there is none, lowercased)
	static function fileExtension(file:String):String {
		var parts = file.split(".");
		return parts[parts.length - 1].toLowerCase();
	}

	// genhl.ml: generate (and generate.ml's part of it: the old output removed, fix_overrides, the log line
	// and the timer)
	public static function generate(com:Context):Void {
		if (fileExtension(com.file) == "hl" && sys.FileSystem.exists(com.file)) try sys.FileSystem.deleteFile(com.file) catch (_:Dynamic) {}
		for (t in com.types) FixOverrides.fixOverrides(com, t);
		com.log("Generating hl: " + com.file);
		var tGen = hxc.core.Timer.timer(["generate", "hl"]);
		try {
			generateCode(com);
		} catch (e:hxc.core.TypingError) {
			com.addDiagnostic(e.message, e.pos);
		}
		tGen();
	}

	static function generateCode(com:Context):Void {
		var dump = com.defines.rawDefined("dump");
		var ctx = createContext(com, false);
		if (dump) {
			// genhl.ml opens dump/hlopt.txt in create_context, and writes it as each function is optimised
			ctx.dumpOut = new StringBuf();
			hxc.core.PathKey.mkdirFromPath("dump/hlopt.txt");
			sys.io.File.saveContent("dump/hlopt.txt", "");
		}
		addTypes(ctx, com.types);
		var code = buildCode(ctx, com.types, com.main);
		ocamlArraySort(code.natives, (n1, n2) -> n1.lib - n2.lib);
		if (dump) {
			sys.io.File.saveContent("dump/hlopt.txt", ctx.dumpOut.toString());
			var out = new StringBuf();
			HlDump.dump(s -> {
				out.add(s);
				out.add("\n");
			}, code);
			sys.io.File.saveContent("dump/hlcode.txt", out.toString());
		}
		var tWrite = hxc.core.Timer.timer(["generate", "hl", "write"]);
		if (fileExtension(com.file) == "c") {
			com.addDiagnostic("hl: HL/C output is not supported yet", Position.nullPos);
			tWrite();
			return;
		}
		sys.io.File.saveBytes(com.file, HlWriter.write(code, !com.defines.rawDefined("hl_no_debug")));
		tWrite();
		if (com.defines.rawDefined("run")) {
			if (Sys.command("haxelib run hashlink run " + escapeCommand(com.file)) != 0) throw "Failed to run HL";
		}
	}
}
