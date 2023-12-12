package hxc.optimization;

// hxc.optimization.InlineConstructors: the first pass finds inline objects (TNew with an inline
// constructor, TObjectDecl, TArrayDecl) and the variables aliasing them, cancelling any object that
// escapes; the second pass replaces the surviving objects with one local per field and rewrites the
// accesses through the aliases.

import haxe.ds.IntMap;
import haxe.ds.StringMap;
import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.TypeUnification;
import hxc.typing.TyperContext;
import hxc.typing.Inline;

private typedef IOCtor = {c:TClass, tl:TParams, cf:TClassField, forced:Bool};

private enum IOKind {
	IOKCtor(ioc:IOCtor);
	IOKStructure;
	IOKArray(len:Int);
}

private class InlineObject {
	public var kind:IOKind;
	public var expr:TExpr;
	public var pos:Position;
	public var hasUntyped:Bool;
	public var cancelled:Bool = false;
	public var declared:Bool = false;
	public var aliases:Array<InlineVar> = [];
	public var fields:StringMap<InlineVar> = new StringMap();
	public var inlineMethods:Array<TExpr> = [];
	public var dependentVars:Array<TVar> = [];

	public function new(kind:IOKind, expr:TExpr, hasUntyped:Bool) {
		this.kind = kind;
		this.expr = expr;
		this.pos = expr.pos;
		this.hasUntyped = hasUntyped;
	}
}

private enum IVKind {
	IVKField(io:InlineObject, name:String, constExpr:Null<TExpr>);
	IVKLocal;
}

private enum IVState {
	IVSUnassigned;
	IVSAliasing(io:InlineObject);
	IVSCancelled;
}

private class InlineVar {
	public var v:TVar;
	public var state:IVState = IVSUnassigned;
	public var kind:IVKind;
	public var closed:Bool = false;

	public function new(v:TVar, kind:IVKind) {
		this.v = v;
		this.kind = kind;
	}
}

private enum IOField {
	IOFInlineMethod(io:InlineObject, iv:InlineVar, c:TClass, tl:TParams, cf:TClassField, tf:TFunc);
	IOFInlineVar(iv:InlineVar);
	IOFNone;
}

class InlineConstructors {
	public static function apply(ctx:TyperContext, e:TExpr):TExpr {
		return new InlineConstructorsRun(ctx).run(e);
	}
}

private class InlineConstructorsRun {
	var ctx:TyperContext;
	var inlineObjs:IntMap<InlineObject> = new IntMap();
	var vars:IntMap<InlineVar> = new IntMap();
	var scopedIvs:Array<InlineVar> = [];
	var currIoId:Int = 0;
	var includedUntyped:Bool = false;

	public function new(ctx:TyperContext) {
		this.ctx = ctx;
	}

	inline function getIo(ioid:Int):Null<InlineObject> return inlineObjs.get(ioid);

	inline function getIv(vid:Int):Null<InlineVar> return vars.get(vid < 0 ? -vid : vid);

	function cancelIo(io:InlineObject, p:Position):Void {
		if (io.cancelled) return;
		io.cancelled = true;
		for (iv in io.aliases) cancelIv(iv, p);
		for (name in io.fields.keys()) cancelIv(io.fields.get(name), p);
		switch (io.kind) {
			case IOKCtor(ioc):
				for (v in io.dependentVars) if (v.id < 0) cancelV(v, p);
				if (ioc.forced) {
					ctx.com.addDiagnostic("Forced inline constructor could not be inlined", io.pos);
					ctx.com.addDiagnostic("Cancellation happened here", p, 1);
				}
			case _:
		}
	}

	function cancelIv(iv:InlineVar, p:Position):Void {
		if (iv.state.match(IVSCancelled)) return;
		var old = iv.state;
		iv.state = IVSCancelled;
		switch (old) {
			case IVSAliasing(io): cancelIo(io, p);
			case _:
		}
		var remove = switch (iv.kind) {
			case IVKField(io, _, _): io.cancelled;
			case IVKLocal: true;
		};
		if (remove) {
			var v = iv.v;
			vars.remove(v.id < 0 ? -v.id : v.id);
			if (v.id < 0) v.id = -v.id;
		}
	}

	function cancelV(v:TVar, p:Position):Void {
		var iv = getIv(v.id);
		if (iv != null) cancelIv(iv, p);
	}

	function setIvAlias(iv:InlineVar, io:InlineObject):Void {
		if (!iv.state.match(IVSUnassigned) || io.cancelled) {
			cancelIo(io, io.pos);
			cancelIv(iv, io.pos);
		} else {
			iv.state = IVSAliasing(io);
			io.aliases.unshift(iv);
		}
	}

	function add(v:TVar, kind:IVKind):InlineVar {
		var iv = new InlineVar(v, kind);
		v.id = -v.id;
		vars.set(-v.id, iv);
		return iv;
	}

	function allocIoFieldFull(io:InlineObject, fname:String, constExpr:Null<TExpr>, t:T, p:Position):InlineVar {
		var v = TypeFunctions.allocVar(VInlined, fname, t, p);
		var iv = add(v, IVKField(io, fname, constExpr));
		io.fields.set(fname, iv);
		return iv;
	}

	function allocConstIoField(io:InlineObject, fname:String, constExpr:TExpr):InlineVar {
		var iv = allocIoFieldFull(io, fname, constExpr, constExpr.type, constExpr.pos);
		iv.state = IVSCancelled;
		return iv;
	}

	function allocIoField(io:InlineObject, fname:String, t:T, p:Position):InlineVar {
		return allocIoFieldFull(io, fname, null, t, p);
	}

	static function intFieldName(i:Int):String {
		return i < 0 ? "n" + (-i) : "" + i;
	}

	static function isExternCtor(c:TClass, cf:TClassField):Bool {
		return TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern);
	}

	function makeExprForList(el:Array<TExpr>, t:T, p:Position):TExpr {
		return switch (el) {
			case []: TypeFunctions.mk(TBlock([]), ctx.com.basic.tvoid, p);
			case [e]: e;
			case _: TypeFunctions.mk(TBlock(el), t, p);
		};
	}

	// El arrives in reverse order (index 0 is the last expression)
	function makeExprForRevList(el:Array<TExpr>, t:T, p:Position):TExpr {
		var l = el.copy();
		l.reverse();
		return makeExprForList(l, t, p);
	}

	static function inlineObjectId(m:MetadataEntry):Null<Int> {
		if (m.name != ":inlineObject") return null;
		return switch (m.params) {
			case [{expr: EConst(CInt(s, _))}]: Std.parseInt(s);
			case _: null;
		};
	}

	static function inlineCtorArgId(m:MetadataEntry):Null<Int> {
		if (m.name != ":inlineConstructorArgument") return null;
		return switch (m.params) {
			case [{expr: EConst(CInt(s, _))}]: Std.parseInt(s);
			case _: null;
		};
	}

	static function isValidStructureField(s:String):Bool {
		if (s.length == 0) return false;
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			var alpha = (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code;
			var digit = c >= "0".code && c <= "9".code;
			if (!(alpha || (i > 0 && digit))) return false;
		}
		return true;
	}

	function checkForCtors(forceInline:Bool, e:TExpr):Bool {
		var isCtor = false;
		var isMetaInline = false;
		switch (e.expr) {
			case TMeta({name: ":inline"}, _):
				isMetaInline = true;
			case TObjectDecl(_) | TArrayDecl(_):
				isCtor = true;
			case TNew(_, _, _) if (forceInline):
				isCtor = true;
			case TNew(c, _, _) if (c.constructor != null
					&& c.constructor.kind.match(Method(MethInline))
					&& c.constructor.expr != null
					&& c.constructor.expr.expr.match(TFunction(_))):
				isCtor = Inline.needsInline(ctx, c, c.constructor);
			case _:
		}
		return isCtor || TexprTools.checkExpr(function(x) return checkForCtors(isMetaInline, x), e);
	}

	function markCtors(forceInline:Bool, e:TExpr):TExpr {
		switch (e.expr) {
			case TMeta(m, _) if (inlineCtorArgId(m) != null):
				return e;
			case _:
		}
		var isMetaInline = e.expr.match(TMeta({name: ":inline"}, _));
		var e = TexprTools.mapExpr(function(x) return markCtors(isMetaInline, x), e);
		function mark():TExpr {
			currIoId++;
			var idExpr = new Expr(EConst(CInt("" + currIoId, null)), e.pos);
			var meta:MetadataEntry = {name: ":inlineObject", params: [idExpr], pos: e.pos};
			return TypeFunctions.mk(TMeta(meta, e), e.type, e.pos);
		}
		return switch (e.expr) {
			case TObjectDecl(_) | TArrayDecl(_):
				mark();
			case TNew(_, _, _) if (forceInline):
				mark();
			case TNew(c, _, _) if (c.constructor != null
					&& c.constructor.kind.match(Method(MethInline))
					&& c.constructor.expr != null
					&& c.constructor.expr.expr.match(TFunction(_))):
				Inline.needsInline(ctx, c, c.constructor) ? mark() : e;
			case _:
				e;
		};
	}

	function analyze(seenCtors:Array<TClassField>, captured:Bool, isLvalue:Bool, e:TExpr):Null<InlineVar> {
		function mkIo(iok:IOKind, id:Int, expr:TExpr, hasUntyped:Bool = false):InlineObject {
			var io = new InlineObject(iok, expr, hasUntyped);
			inlineObjs.set(id, io);
			return io;
		}
		inline function analyzeInLvalue(e:TExpr):Null<InlineVar> return analyze(seenCtors, captured, true, e);
		function analyzeInCtor(cf:TClassField, captured2:Bool, e:TExpr):Null<InlineVar> return analyze([cf].concat(seenCtors), captured2, false, e);
		inline function analyzeSub(captured2:Bool, e:TExpr):Null<InlineVar> return analyze(seenCtors, captured2, false, e);

		function getIoInlineMethod(io:InlineObject, fname:String):Null<{c:TClass, tl:TParams, cf:TClassField, tf:TFunc}> {
			return switch (io.kind) {
				case IOKCtor(ctor):
					var f = ctor.c.fields.get(fname);
					if (f == null) null
					else switch [f.params, f.kind, f.expr] {
						case [[], Method(MethInline), fe] if (fe != null && fe.expr.match(TFunction(_))):
							var tf = switch (fe.expr) { case TFunction(tf2): tf2; case _: null; };
							Inline.needsInline(ctx, ctor.c, f) ? {c: ctor.c, tl: ctor.tl, cf: f, tf: tf} : null;
						case _: null;
					}
				case _: null;
			};
		}

		function handleFieldCase(captured2:Bool, isLvalue2:Bool, efield:TExpr, ethis:TExpr, fname:String, validateIo:InlineObject->Bool):IOField {
			return switch (analyzeSub(true, ethis)) {
				case iv if (iv != null && switch (iv.state) { case IVSAliasing(io): validateIo(io); case _: false; }):
					var io = switch (iv.state) { case IVSAliasing(io2): io2; case _: null; };
					switch (getIoInlineMethod(io, fname)) {
						case m if (m != null):
							var methodType = TypeFunctions.applyParams(m.c.params, m.tl, m.cf.type);
							var fieldIsFunction = TypeFunctions.follow(efield.type).match(TFun(_));
							if (fieldIsFunction && TypeUnification.doesUnify(methodType, efield.type))
								IOFInlineMethod(io, iv, m.c, m.tl, m.cf, m.tf);
							else {
								cancelIv(iv, efield.pos);
								IOFNone;
							}
						case _:
							var fiv = io.fields.get(fname);
							var ok = fiv != null;
							if (ok && !TypeUnification.typeIseqStrict(fiv.v.type, efield.type)) ok = false;
							var fivIsConst = ok && switch (fiv.kind) { case IVKField(_, _, ce): ce != null; case _: false; };
							if (ok && isLvalue2 && fivIsConst) ok = false;
							if (ok && fiv.closed) ok = false;
							if (ok && !isLvalue2 && fiv.state.match(IVSUnassigned)) {
								var opts = hxc.core.WarningList.fromMeta(ctx.curfield.meta).concat(hxc.core.WarningList.fromMeta(ctx.curclass.meta));
								ctx.com.warning(WConstructorInliningCancelled, opts, "Constructor inlining cancelled because of use of uninitialized member field " + fname, ethis.pos);
								ok = false;
							}
							if (ok) {
								if (!captured2) cancelIv(fiv, efield.pos);
								IOFInlineVar(fiv);
							} else {
								cancelIv(iv, efield.pos);
								IOFNone;
							}
					}
				case iv if (iv != null):
					cancelIv(iv, efield.pos);
					IOFNone;
				case _:
					IOFNone;
			};
		}

		function handleFieldCaseNoMethods(efield:TExpr, ethis:TExpr, fname:String, validateIo:InlineObject->Bool):Null<InlineVar> {
			return switch (handleFieldCase(captured, isLvalue, efield, ethis, fname, validateIo)) {
				case IOFInlineMethod(io, _, _, _, _, _): cancelIo(io, efield.pos); null;
				case IOFInlineVar(iv): iv;
				case IOFNone: null;
			};
		}

		function handleDefaultCase(e:TExpr):Null<InlineVar> {
			var old = scopedIvs;
			scopedIvs = [];
			TexprTools.iter(function(x) analyzeSub(false, x), e);
			for (iv in scopedIvs) iv.closed = true;
			scopedIvs = old;
			return null;
		}

		function analyzeCallArgs(callArgs:Array<TExpr>):{vs:Array<TVar>, es:Array<TExpr>} {
			var vs:Array<TVar> = [];
			var es:Array<TExpr> = [];
			for (a in callArgs) {
				switch (a.expr) {
					case TConst(_):
						es.push(a);
					case _:
						var v = TypeFunctions.allocVar(VGenerated, "arg", a.type, a.pos);
						var decle = TypeFunctions.mk(TVarExpr(v, a), ctx.com.basic.tvoid, a.pos);
						analyzeSub(true, decle);
						var mde:MetadataEntry = {name: ":inlineConstructorArgument", params: [new Expr(EConst(CInt("" + v.id, null)), a.pos)], pos: a.pos};
						es.push(TypeFunctions.mk(TMeta(mde, a), a.type, a.pos));
						vs.unshift(v);
				}
			}
			return {vs: vs, es: es};
		}

		function handleInlineObjectCase(ioId:Int, forceInline:Bool, e:TExpr):Null<InlineVar> {
			switch [e.expr, e.type] {
				case [TNew(c, tl, pl), _] if (captured && c.constructor != null && c.constructor.expr != null
						&& c.constructor.expr.expr.match(TFunction(_)) && seenCtors.indexOf(c.constructor) < 0):
					var cf = c.constructor;
					var tf = switch (cf.expr.expr) { case TFunction(tf2): tf2; case _: null; };
					var args = analyzeCallArgs(pl);
					var v = TypeFunctions.allocVar(VGenerated, "inl" + c.path.name, e.type, e.pos);
					var ethis = TypeFunctions.mk(TLocal(v), TInst(c, tl), e.pos);
					var inlined = Inline.typeInlineCtor(ctx, c, cf, tf, ethis, args.es, e.pos);
					if (inlined != null) {
						inlined = markCtors(false, inlined);
						var hasUntyped = TypeFunctions.hasMeta(":has_untyped", cf.meta);
						var forced = isExternCtor(c, cf) || forceInline;
						var io = mkIo(IOKCtor({c: c, tl: tl, cf: cf, forced: forced}), ioId, inlined, hasUntyped);
						io.dependentVars = args.vs;
						function loop(c2:TClass, tl2:TParams):Void {
							for (fld in c2.orderedFields) switch (fld.kind) {
								case Var(_):
									var fieldT = TypeFunctions.applyParams(c2.params, tl2, fld.type);
									allocIoField(io, fld.name, fieldT, v.pos);
								case _:
							}
							if (c2.superClass != null)
								loop(c2.superClass.c, [for (t in c2.superClass.params) TypeFunctions.applyParams(c2.params, tl2, t)]);
						}
						loop(c, tl);
						var iv = add(v, IVKLocal);
						setIvAlias(iv, io);
						analyzeInCtor(cf, true, io.expr);
						return iv;
					} else {
						for (av in args.vs) cancelV(av, av.pos);
						if (isExternCtor(c, cf)) ctx.com.addDiagnostic("Extern constructor could not be inlined", e.pos);
						return null;
					}
				case [TNew(c, _, _), _] if (c.constructor != null && c.constructor.kind.match(Method(MethInline))
						&& c.constructor.expr != null && isExternCtor(c, c.constructor)):
					throw new TypingError("Extern constructor could not be inlined", e.pos);
				case [TObjectDecl(fl), _] if (captured && fl.length > 0 && Lambda.foreach(fl, function(f) return isValidStructureField(f.key.name))):
					var v = TypeFunctions.allocVar(VGenerated, "inlobj", e.type, e.pos);
					var ev = TypeFunctions.mk(TLocal(v), v.type, e.pos);
					var el = [for (f in fl) {
						var ef = TypeFunctions.mk(TField(ev, FDynamic(f.key.name)), f.expr.type, f.expr.pos);
						TypeFunctions.mk(TBinop(OpAssign, ef, f.expr), f.expr.type, f.expr.pos);
					}];
					var ioExpr = makeExprForList(el, ctx.com.basic.tvoid, e.pos);
					var io = mkIo(IOKStructure, ioId, ioExpr);
					for (f in fl) allocIoField(io, f.key.name, f.expr.type, v.pos);
					var iv = add(v, IVKLocal);
					setIvAlias(iv, io);
					for (x in el) analyzeSub(true, x);
					return iv;
				case [TArrayDecl(el), TInst(_, [elemType])] if (captured):
					var len = el.length;
					var v = TypeFunctions.allocVar(VGenerated, "inlarr", e.type, e.pos);
					var ev = TypeFunctions.mk(TLocal(v), v.type, e.pos);
					var el2 = [for (i in 0...el.length) {
						var x = el[i];
						var ef = TypeFunctions.mk(TArray(ev, TypeFunctions.mk(TConst(TInt(i)), x.type, x.pos)), elemType, x.pos);
						TypeFunctions.mk(TBinop(OpAssign, ef, x), elemType, x.pos);
					}];
					var ioExpr = makeExprForList(el2, ctx.com.basic.tvoid, e.pos);
					var io = mkIo(IOKArray(len), ioId, ioExpr);
					allocConstIoField(io, "length", TypeFunctions.mk(TConst(TInt(len)), ctx.com.basic.tint, e.pos));
					for (i in 0...len) allocIoField(io, intFieldName(i), elemType, v.pos);
					var iv = add(v, IVKLocal);
					setIvAlias(iv, io);
					for (x in el2) analyzeSub(true, x);
					return iv;
				case _:
					return handleDefaultCase(e);
			}
		}

		return switch (e.expr) {
			case TMeta({name: ":inline"}, {expr: TMeta(m, inner)}) if (inlineObjectId(m) != null):
				handleInlineObjectCase(inlineObjectId(m), true, inner);
			case TMeta(m, inner) if (inlineObjectId(m) != null):
				handleInlineObjectCase(inlineObjectId(m), false, inner);
			case TVarExpr(v, null):
				add(v, IVKLocal);
				null;
			case TVarExpr(v, rve):
				switch (analyzeSub(true, rve)) {
					case riv if (riv != null && riv.state.match(IVSAliasing(_))):
						var io = switch (riv.state) { case IVSAliasing(io2): io2; case _: null; };
						var iv = add(v, IVKLocal);
						setIvAlias(iv, io);
					case _:
				}
				null;
			case TBinop(OpAssign, lve, rve):
				switch (analyzeInLvalue(lve)) {
					case iv if (iv != null && iv.state.match(IVSUnassigned)):
						switch (analyzeSub(true, rve)) {
							case riv if (riv != null && riv.state.match(IVSAliasing(_))):
								var io = switch (riv.state) { case IVSAliasing(io2): io2; case _: null; };
								scopedIvs.unshift(iv);
								setIvAlias(iv, io);
							case _:
								cancelIv(iv, lve.pos);
						}
						iv;
					case iv if (iv != null):
						cancelIv(iv, e.pos);
						analyzeSub(false, rve);
						null;
					case _:
						analyzeSub(false, rve);
						null;
				}
			case TField(ethis, fa):
				handleFieldCaseNoMethods(e, ethis, TypeFunctions.fieldName(fa), function(_) return true);
			case TArray(ethis, {expr: TConst(TInt(i))}):
				var idx:Int = i;
				handleFieldCaseNoMethods(e, ethis, intFieldName(idx), function(io) return switch (io.kind) {
					case IOKArray(l): idx >= 0 && idx < l;
					case _: false;
				});
			case TLocal(v) if (v.id < 0):
				var iv = getIv(v.id);
				if (iv.closed || !captured) cancelIv(iv, e.pos);
				iv;
			case TBlock(el):
				var r:Null<InlineVar> = null;
				for (i in 0...el.length) {
					if (i == el.length - 1) r = analyzeSub(captured, el[i]);
					else analyzeSub(true, el[i]);
				}
				r;
			case TMeta(m, _) if (inlineCtorArgId(m) != null):
				// The contents were analyzed when the argument was declared
				var iv = getIv(inlineCtorArgId(m));
				if (iv != null) {
					if (iv.closed || !captured) cancelIv(iv, e.pos);
					iv;
				} else null;
			case TParenthesis(inner) | TMeta(_, inner) | TCast(inner, null):
				analyzeSub(captured, inner);
			case TCall(efield = {expr: TField(ethis, fa)}, callArgs):
				var fname = TypeFunctions.fieldName(fa);
				switch (handleFieldCase(false, false, efield, ethis, fname, function(_) return true)) {
					case IOFInlineMethod(io, ioVar, c, tl, cf, tf):
						var args = analyzeCallArgs(callArgs);
						io.dependentVars = io.dependentVars.concat(args.vs);
						io.hasUntyped = io.hasUntyped || TypeFunctions.hasMeta(":has_untyped", cf.meta);
						var ethisLocal = TypeFunctions.mk(TLocal(ioVar.v), TInst(c, tl), e.pos);
						var inlined = Inline.typeInline(ctx, c, cf, tf, ethisLocal, args.es, e.type, e.pos);
						if (inlined != null) {
							inlined = markCtors(false, inlined);
							io.inlineMethods.push(inlined);
							switch (analyzeSub(captured, inlined)) {
								case iv if (iv != null):
									// The parent object might have been cancelled while analyzing the body
									if (io.cancelled) {
										cancelIv(iv, e.pos);
										null;
									} else {
										io.dependentVars.unshift(iv.v);
										iv;
									}
								case _: null;
							}
						} else {
							cancelIo(io, e.pos);
							null;
						}
					case IOFInlineVar(iv):
						cancelIv(iv, e.pos);
						for (a in callArgs) analyzeSub(false, a);
						null;
					case IOFNone:
						for (a in callArgs) analyzeSub(false, a);
						null;
				}
			case TFunction(tf):
				analyzeSub(true, tf.expr);
			case _:
				handleDefaultCase(e);
		};
	}

	function getIvVarDecls(iv:InlineVar):Array<TExpr> {
		return switch [iv.state, iv.kind] {
			case [IVSAliasing(io), _]: getIoVarDecls(io);
			case [_, IVKField(_, _, ce)] if (ce != null): [];
			case [IVSCancelled, _]:
				[TypeFunctions.mk(TVarExpr(iv.v, null), ctx.com.basic.tvoid, iv.v.pos)];
			case _: [];
		};
	}

	function getIoVarDecls(io:InlineObject):Array<TExpr> {
		if (io.declared) return [];
		io.declared = true;
		// Ascending key order
		var names = [for (k in io.fields.keys()) k];
		names.sort(Reflect.compare);
		var acc:Array<TExpr> = [];
		for (n in names) acc = acc.concat(getIvVarDecls(io.fields.get(n)));
		return acc;
	}

	// The returned list is in REVERSE order
	function finalMap(unwrapBlock:Bool, e:TExpr):{el:Array<TExpr>, io:Null<InlineObject>} {
		function defaultCase(e:TExpr):{el:Array<TExpr>, io:Null<InlineObject>} {
			var f = function(x:TExpr):TExpr {
				var r = finalMap(false, x);
				return makeExprForRevList(r.el, x.type, x.pos);
			};
			return {el: [TexprTools.mapExpr(f, e)], io: null};
		}
		// Last flag: the field resolved to an inlined method
		function fieldCase(ethis:TExpr, fa:TFieldAccess, efield:TExpr):{el:Array<TExpr>, io:Null<InlineObject>, method:Bool} {
			var r = finalMap(false, ethis);
			if (r.io != null) {
				var io = r.io;
				var fname = TypeFunctions.fieldName(fa);
				var fiv = io.fields.get(fname);
				if (fiv != null) {
					switch (fiv.state) {
						case IVSAliasing(io2):
							return {el: r.el, io: io2, method: false};
						case _:
							var newExpr = switch (fiv.kind) {
								case IVKField(_, _, ce) if (ce != null): TypeFunctions.mk(ce.expr, ce.type, e.pos);
								case _: TypeFunctions.mk(TLocal(fiv.v), efield.type, efield.pos);
							};
							return {el: [newExpr].concat(r.el), io: null, method: false};
					}
				}
				// Not an inline variable: it must be an inlined method call
				if (io.inlineMethods.length > 0) {
					var m = io.inlineMethods.shift();
					var r2 = finalMap(false, m);
					return {el: r2.el.concat(r.el), io: r2.io, method: true};
				}
				throw new TypingError("Malformed inline object field access", efield.pos);
			}
			var te = makeExprForRevList(r.el, ethis.type, ethis.pos);
			return {el: [TypeFunctions.mk(TField(te, fa), efield.type, efield.pos)], io: null, method: false};
		}
		return switch (e.expr) {
			case TMeta(m, inner) if (inlineObjectId(m) != null):
				var io = getIo(inlineObjectId(m));
				if (io != null && !io.cancelled) {
					if (io.hasUntyped) includedUntyped = true;
					var r = finalMap(true, io.expr);
					{el: r.el.concat(getIoVarDecls(io)), io: io};
				} else defaultCase(inner);
			case TVarExpr(v, null) if (v.id < 0):
				{el: getIvVarDecls(getIv(v.id)), io: null};
			case TVarExpr(v, ve) if (v.id < 0):
				var decls = getIvVarDecls(getIv(v.id));
				var r = finalMap(true, ve);
				{el: r.el.concat(decls), io: null};
			case TBinop(OpAssign, lve, rve):
				var lr = finalMap(false, lve);
				var rr = finalMap(true, rve);
				if (lr.io != null) {
					{el: rr.el.concat(lr.el), io: lr.io};
				} else {
					var rve2 = makeExprForRevList(rr.el, rve.type, rve.pos);
					switch (lr.el) {
						case []: throw new TypingError("Malformed inline object assignment", e.pos);
						case el2:
							var head = el2[0];
							var assign = TypeFunctions.mk(TBinop(OpAssign, head, rve2), head.type, head.pos);
							{el: [assign].concat(el2.slice(1)), io: null};
					}
				}
			case TCall(efield = {expr: TField(ethis, fa)}, callArgs):
				var fr = fieldCase(ethis, fa, efield);
				if (fr.method) {
					{el: fr.el, io: fr.io};
				} else {
					var f = function(x:TExpr):TExpr {
						var r = finalMap(false, x);
						return makeExprForRevList(r.el, x.type, x.pos);
					};
					var e1 = makeExprForRevList(fr.el, efield.type, efield.pos);
					{el: [TypeFunctions.mk(TCall(e1, [for (a in callArgs) f(a)]), e.type, e.pos)], io: null};
				}
			case TField(ethis, fa):
				var fr = fieldCase(ethis, fa, e);
				{el: fr.el, io: fr.io};
			case TArray(ethis, idx = {expr: TConst(TInt(i))}):
				var r = finalMap(false, ethis);
				if (r.io != null) {
					var io = r.io;
					var fname = intFieldName(i);
					var fiv = io.fields.get(fname);
					if (fiv == null) throw new TypingError("Malformed inline array access", e.pos);
					switch (fiv.state) {
						case IVSAliasing(io2):
							{el: r.el, io: io2};
						case _:
							{el: [TypeFunctions.mk(TLocal(fiv.v), e.type, e.pos)].concat(r.el), io: null};
					}
				} else {
					var te = makeExprForRevList(r.el, ethis.type, ethis.pos);
					{el: [TypeFunctions.mk(TArray(te, idx), e.type, e.pos)], io: null};
				}
			case TLocal(v) if (v.id < 0):
				switch (getIv(v.id).state) {
					case IVSAliasing(io):
						{el: [], io: io};
					case _:
						{el: [TypeFunctions.mk(TLocal(getIv(v.id).v), e.type, e.pos)], io: null};
				}
			case TBlock(el):
				var acc:Array<TExpr> = [];
				var io:Null<InlineObject> = null;
				for (i in 0...el.length) {
					var r = finalMap(unwrapBlock, el[i]);
					acc = r.el.concat(acc);
					if (i == el.length - 1) io = r.io;
				}
				if (unwrapBlock || io != null) {
					{el: acc, io: io};
				} else {
					var l = acc.copy();
					l.reverse();
					{el: [TypeFunctions.mk(TBlock(l), e.type, e.pos)], io: null};
				}
			case TMeta(m, inner) if (inlineCtorArgId(m) != null):
				finalMap(false, inner);
			case TParenthesis(inner) | TCast(inner, null) | TMeta(_, inner):
				var r = finalMap(false, inner);
				if (r.io != null) {
					r;
				} else {
					var inner2 = makeExprForRevList(r.el, inner.type, inner.pos);
					var rebuilt = switch (e.expr) {
						case TParenthesis(_): TypeFunctions.mk(TParenthesis(inner2), e.type, e.pos);
						case TCast(_, mt): TypeFunctions.mk(TCast(inner2, mt), e.type, e.pos);
						case TMeta(m2, _): TypeFunctions.mk(TMeta(m2, inner2), e.type, e.pos);
						case _: inner2;
					};
					{el: [rebuilt], io: null};
				}
			case _:
				defaultCase(e);
		};
	}

	function getPrettyName(iv:InlineVar):String {
		return switch (iv.kind) {
			case IVKField(io, fname, null):
				var user:Null<InlineVar> = null;
				for (a in io.aliases) if (a.v.kind.match(VUser(_)) || a.v.kind.match(VInlined)) { user = a; break; }
				if (user == null && io.aliases.length > 0) user = io.aliases[0];
				(user != null ? getPrettyName(user) : iv.v.name) + "_" + fname;
			case _:
				iv.v.name;
		};
	}

	public function run(originalE:TExpr):TExpr {
		if (!checkForCtors(false, originalE)) return originalE;
		var e = markCtors(false, originalE);
		analyze([], false, false, e);
		var allCancelled = true;
		for (io in inlineObjs) if (!io.cancelled) { allCancelled = false; break; }
		if (allCancelled) {
			for (iv in vars) if (iv.v.id < 0) iv.v.id = -iv.v.id;
			return originalE;
		}
		var r = finalMap(false, e);
		var cf = ctx.curfield;
		if (includedUntyped && !TypeFunctions.hasMeta(":has_untyped", cf.meta))
			cf.meta = ([{name: ":has_untyped", params: [], pos: e.pos}] : Metadata).concat(cf.meta);
		var result = makeExprForRevList(r.el, e.type, e.pos);
		for (iv in vars) {
			var v = iv.v;
			if (v.id < 0) {
				v.id = -v.id;
				v.name = getPrettyName(iv);
			}
		}
		return result;
	}
}
