package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.context.CapturePolicy;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;

// The loop variable's name, its position and the kind of the display marker it was read
// through, if any.
typedef IterationIdent = {name:String, pos:Position, dko:Null<DisplayKind>};

enum IterationHead {
	IHNormal(i:IterationIdent);
	IHKeyValue(k:IterationIdent, v:IterationIdent);
}

class ForLoop {
	// The iterator contract unifies hasNext/next signatures with the loop's element type; an
	// unannotated method whose return is still an open mono must type its body first so the contract
	// does not bind the declaration mono to the loop's type and break the later body typing (the same
	// ordering as super-constructor forcing). Force the not-yet-typed iterator-protocol methods of a
	// class before STRUCTURALLY unifying it against Iterator/KeyValueIterator: the class-to-anon
	// unification reads raw field types and would bind an open inferred return (e.g. an inline next())
	// to the contract's type, breaking the later body typing at its declaration.
	public static function forceOpenIteratorFields(ctx:TyperContext, t:T):Void {
		switch (TypeFunctions.follow(t)) {
			case TInst(c, _):
				for (name in ["hasNext", "next", "iterator", "keyValueIterator"]) {
					var cf = c.fields.get(name);
					if (cf == null || !cf.kind.match(Method(_)) || cf.expr != null) continue;
					switch (TypeFunctions.follow(cf.type)) {
						case TFun(sig):
							switch (TypeFunctions.follow(sig.ret)) {
								case TMono(r) if (r.type == null):
									try TypeFields.forceFieldBody(ctx.com, c, cf) catch (_:Dynamic) {}
								case _:
							}
						case _:
					}
				}
			case _:
		}
	}

	public static function typeForLoop(ctx:TyperContext, it:Expr, e2:Expr, p:Position):TExpr {
		// A display marker stands for an EDisplay node around the expression the preprocessor chose. hxc
		// keeps that choice by identity (ExprPreprocessing.markedNode) and materializes the wrapper only
		// in a tree a macro is handed, so a node that is the marked one stands for EDisplay(node) here,
		// and a real EDisplay is read as well.
		function markOf(e:Expr):Null<DisplayKind>
			return e == ExprPreprocessing.markedNode ? ExprPreprocessing.markedKind : null;
		// The head is only pattern-matched, never typed, so a marker inside it that is dropped or
		// fails never reaches the display handler: nothing answers and the request reports the error
		// or the missing point - the verdict a raise out of the marked node's own typing leaves,
		// which is what markedNodeFailed records.
		function dropMark():Void {
			var mn = ExprPreprocessing.markedNode;
			if (mn != null && mn.pos.file == it.pos.file && it.pos.min <= mn.pos.min && mn.pos.max <= it.pos.max)
				Typer.markedNodeFailed = true;
		}
		// The loop variable is allocated at the identifier's position, not at the position of the whole
		// `for`: the lowered `var i = _g++` and the `_g < _g1` condition both union it, and without it
		// the js source map would drop the condition segment as a duplicate.
		function loopIdent(dko:Null<DisplayKind>, e1:Expr, markRead:Bool):IterationIdent {
			var dk = markRead ? null : markOf(e1);
			if (dk != null) return loopIdent(dk, e1, true);
			return switch (e1.expr) {
				case EConst(CIdent(i)): {name: i, pos: e1.pos, dko: dko};
				case EDisplay(inner, dk): loopIdent(dk, inner, false);
				case _:
					dropMark();
					throw new TypingError("Identifier expected", e1.pos);
			};
		}
		// `for (k => v in e)` parses as OpArrow(k, OpIn(v, e)) since `in` binds tighter than `=>`;
		// a macro-built head may carry OpIn(OpArrow(k, v), e) instead. A marked operand is an
		// EDisplay, which neither shape matches.
		function loop(dko:Null<DisplayKind>, e1:Expr, markRead:Bool):{ik:IterationHead, e1:Expr} {
			var dk = markRead ? null : markOf(e1);
			if (dk != null) return loop(dk, e1, true);
			switch (e1.expr) {
				case EBinop(OpIn, ea, eb):
					return switch (ea.expr) {
						case EBinop(OpArrow, ei1, ei2) if (markOf(ea) == null):
							if (dko != null) dropMark();
							{ik: IHKeyValue(loopIdent(null, ei1, false), loopIdent(null, ei2, false)), e1: eb};
						case _:
							{ik: IHNormal(loopIdent(dko, ea, false)), e1: eb};
					};
				case EDisplay(inner, dk):
					return loop(dk, inner, false);
				case EBinop(OpArrow, ei1, ein = {expr: EBinop(OpIn, ei2, eb)}) if (markOf(ein) == null):
					if (dko != null) dropMark();
					return {ik: IHKeyValue(loopIdent(null, ei1, false), loopIdent(null, ei2, false)), e1: eb};
				case _:
					// A head that is not `v in expr` still answers the display it was marked for before the
					// error is raised. The parser's dangling dot is an EDisplay(e, DKDot), which hxc
					// carries as
					// an empty field name that types as that completion - an unfinished `for ([].`
					// completes.
					if (dko != null || e1.expr.match(EField(_, "", _))) Typer.typeExpr(ctx, e1, WithTypeTools.value) else dropMark();
					throw new TypingError("For expression should be 'v in expr'", it.pos);
			}
		}
		var r = loop(null, it, false);
		return switch (r.ik) {
			case IHNormal(i): ForLoopFaithful.typeNormalForLoop(ctx, i, r.e1, e2, p);
			case IHKeyValue(k, v): ForLoopFaithful.typeKeyValueForLoop(ctx, k, v, r.e1, e2, p);
		};
	}

	// A loop variable read through a display marker answers it once the body is typed, as the
	// identifier naming it at its own position.
	public static function checkDisplay(ctx:TyperContext, i:TVar, ident:IterationIdent):Void {
		if (ident.dko != null)
			Typer.handleDisplay(ctx, new Expr(EConst(CIdent(i.name)), i.pos), ident.dko, MGet, WithTypeTools.withType(i.type));
	}
}

// The for-loop lowering used by generated targets. IterationKind classifies the iterated
// expression; toTexpr builds the loop shape.
enum IterationKindKind {
	IteratorIntConst(a:TExpr, b:TExpr, ascending:Bool);
	IteratorIntUnroll(offset:Int, length:Int, ascending:Bool);
	IteratorInt(a:TExpr, b:TExpr);
	IteratorArrayDecl(el:Array<TExpr>);
	IteratorArray;
	IteratorArrayAccess;
	IteratorCustom(fNext:(TExpr, TExpr, T, Position)->TExpr, fLength:(TExpr, Position)->TExpr);
	IteratorAbstract(v:TVar, eNext:TExpr, eHasNext:TExpr);
	IteratorIterator;
	IteratorGenericStack(c:TClass);
	IteratorDynamic;
}

private class ForExit extends haxe.Exception {
	public function new() super("exit");
}

class ForLoopFaithful {
	// Generated locals carry the backtick name and are renamed to _g by RenameVars.
	static function genLocal(ctx:TyperContext, t:T, p:Position):TVar {
		return Typer.addLocal(ctx, VGenerated, "`", t, p);
	}

	public static function concat(e1:TExpr, e2:TExpr):TExpr {
		var e = switch [e1.expr, e2.expr] {
			case [TBlock(el1), TBlock(el2)]: TBlock(el1.concat(el2));
			case [TBlock(el1), _]: TBlock(el1.concat([e2]));
			case [_, TBlock(el2)]: TBlock([e1].concat(el2));
			case _: TBlock([e1, e2]);
		};
		return TypeFunctions.mk(e, e2.type, Position.union(e1.pos, e2.pos));
	}

	// The Iterator<mono> typedef applied to a fresh monomorph
	public static function tIterator(ctx:TyperContext):{t:T, pt:T} {
		var mt = ctx.com.getType({pack: [], name: "StdTypes"}, Position.nullPos, "Iterator");
		return switch (mt) {
			case TTypeDecl(td):
				// The applied typedef, the structure itself, which is what a failed unification against it
				// prints.
				var pt = TypeFunctions.mkMono();
				{t: TypeFunctions.applyTypedef(td, [pt]), pt: pt};
			case _:
				throw new TypingError("Standard library Iterator typedef not found", Position.nullPos);
		};
	}

	// The syntactic expression weight for unrolling, or null when the body breaks/continues
	// (those cannot unroll).
	public static function getUnrollWeight(ctx:TyperContext, e2:Expr):Null<Int> {
		// A display request never unrolls. The unrolled copies replace the loop variable with a
		// constant, so nothing in the body refers to it any more and a request about it - its uses
		// above all - has nothing left to find.
		if (ctx.com.ignoreErrors) return null;
		var numExpr = 0;
		function loop(e:Expr):Expr {
			switch (e.expr) {
				case EContinue | EBreak: throw new ForExit();
				case _:
					numExpr++;
					Ast.mapExpr(loop, e);
			}
			return e;
		}
		return try {
			loop(e2);
			numExpr;
		} catch (_:ForExit) null;
	}

	static function unrollAllowed(ctx:TyperContext, weight:Null<Int>, i:Int):Bool {
		if (weight == null) return false;
		var maxCost = Std.parseInt(ctx.com.defines.rawDefinedValueSafe("loop_unroll_max_cost", "250"));
		if (maxCost == null) maxCost = 250;
		return i * weight <= maxCost;
	}

	// A class iterator with an inline hasNext lowers to var tmp = it; while (tmp.hasNext()) {
	// var v = tmp.next(); body }
	static function optimizeForLoopIterator(ctx:TyperContext, v:TVar, e1:TExpr, e2:TExpr, p:Position):TExpr {
		function getClassAndParams(e:TExpr):{c:TClass, tl:TParams} {
			return switch (TypeFunctions.follow(e.type)) {
				case TInst(c, pl): {c: c, tl: pl};
				case _:
					switch (e.expr) {
						case TCast(e2, null): getClassAndParams(e2);
						case TCall({expr: TField(_, FInstance(c, pl, cf))}, _):
							switch (TypeFunctions.follow(TypeFunctions.applyParams(c.params, pl, cf.type))) {
								case TFun(sig):
									switch (TypeFunctions.follow(sig.ret)) {
										case TInst(c2, pl2): {c: c2, tl: pl2};
										case _: throw new ForExit();
									}
								case _: throw new ForExit();
							}
						case _: throw new ForExit();
					}
			};
		}
		var ct = getClassAndParams(e1);
		var c = ct.c, tl = ct.tl;
		var fhasnext = try TypeFunctions.rawClassField(function(cf) return TypeFunctions.applyParams(c.params, tl, cf.type), c, tl, "hasNext").f
			catch (_:hxc.core.NotFound) throw new ForExit();
		if (!fhasnext.kind.match(Method(MethInline))) throw new ForExit();
		var itType = TInst(c, tl);
		var tmp = genLocal(ctx, itType, e1.pos);
		var eit = TypeFunctions.mk(TLocal(tmp), itType, p);
		var basic = ctx.com.basic;
		var ehasnext = Calls.makeCall(ctx,
			TypeFunctions.mk(TField(eit, FInstance(c, tl, fhasnext)), TypeFunctions.tfun([], basic.tbool), p),
			[], basic.tbool, p);
		var faNext = try FInstance(c, tl, TypeFunctions.rawClassField(function(cf) return TypeFunctions.applyParams(c.params, tl, cf.type), c, tl, "next").f)
			catch (_:hxc.core.NotFound) TypeFunctions.quickFieldDynamic(eit.type, "next");
		var enext = TypeFunctions.mk(TVarExpr(v, Calls.makeCall(ctx,
			TypeFunctions.mk(TField(eit, faNext), TypeFunctions.tfun([], v.type), p),
			[], v.type, p)), basic.tvoid, p);
		var eblock = switch (e2.expr) {
			case TBlock(el): TypeFunctions.mk(TBlock([enext].concat(el)), basic.tvoid, e2.pos);
			case _: TypeFunctions.mk(TBlock([enext, e2]), basic.tvoid, p);
		};
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(tmp, e1), basic.tvoid, p),
			TypeFunctions.mk(TWhile(ehasnext, eblock, NormalWhile), basic.tvoid, p)
		]), basic.tvoid, p);
	}

	// Cast to Iterator<mono>, or call e.iterator(), with the array-access last resort threaded
	// through.
	static function checkIterator(ctx:TyperContext, s:String, e:TExpr, p:Position, ?lastResort:Void->TExpr):{e:TExpr, pt:T} {
		var it = tIterator(ctx);
		var dynamicIterator:Null<TExpr> = null;
		ForLoop.forceOpenIteratorFields(ctx, e.type);
		var e1 = try {
			// A castOrUnifyRaise failure selects the next iteration strategy.
			var e2 = Typer.castOrUnifyRaise(ctx, it.t, e, p);
			switch (TypeFunctions.followWithAbstracts(e2.type)) {
				case TDynamic(_) | TMono(_):
					dynamicIterator = e2;
					throw new TypingError("Avoid iterating on a dynamic value", p);
				case _: e2;
			}
		} catch (unifyErr:TypingError) {
			function tryLastResort(after:Void->TExpr):TExpr {
				return try {
					if (lastResort == null) throw new hxc.core.NotFound();
					lastResort();
				} catch (_:hxc.core.NotFound) after();
			}
			function tryAcc(acc:AccessKind):TExpr {
				var accExpr = Calls.buildCall(ctx, acc, [], WithTypeTools.value, e.pos);
				ForLoop.forceOpenIteratorFields(ctx, accExpr.type);
				return try {
					hxc.core.TypeUnification.unifyDefault(accExpr.type, it.t);
					accExpr;
				} catch (ue:hxc.core.TypeUnification.UnifyError) {
					// Both messages are recorded at the failed unification, and the loop goes on over a Dynamic
					// null, which ofTexpr then reports as a Dynamic iteration.
					tryLastResort(function() {
						if (dynamicIterator != null) return dynamicIterator;
						ctx.com.addDiagnostic("Field iterator has an invalid type", accExpr.pos, unifyErr.depth);
						ctx.com.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(ue.errors), accExpr.pos, unifyErr.depth + 1);
						return TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, accExpr.pos);
					});
				}
			}
			try {
				var acc = Fields.typeField(ctx, e, s, e.pos, MCall([]), WithTypeTools.withType(it.t), true, true);
				tryAcc(acc);
			} catch (_:Fields.FieldNotFoundError) {
				tryLastResort(function() {
					if (dynamicIterator != null) return dynamicIterator;
					var acc = Fields.typeField(ctx, e, s, e.pos, MCall([]), WithTypeTools.withType(it.t), true, true);
					return tryAcc(acc);
				});
			}
		}
		return {e: e1, pt: it.pt};
	}

	public static function ofTexprByArrayAccess(ctx:TyperContext, e:TExpr, p:Position):{kind:IterationKindKind, e:TExpr, pt:T} {
		switch (TypeFunctions.follow(e.type)) {
			case TInst(c, pl) if (c.arrayAccess != null
					&& c.fields.exists("length")
					&& (switch (TypeFunctions.follow(c.fields.get("length").type)) {
						case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Int";
						case _: false;
					})
					&& !c.fields.exists("iterator")):
				return {kind: IteratorArrayAccess, e: e, pt: TypeFunctions.applyParams(c.params, pl, c.arrayAccess)};
			case TAbstract(a, tl) if (a.impl != null):
				var c = a.impl;
				var cfLength = c.statics.get("get_length");
				if (cfLength == null) throw new hxc.core.NotFound();
				switch (TypeFunctions.follow(cfLength.type)) {
					case TFun(sig):
						switch (TypeFunctions.follow(sig.ret)) {
							case TAbstract({path: {pack: [], name: "Int"}}, _):
							case _: throw new hxc.core.NotFound();
						}
					case _: throw new hxc.core.NotFound();
				}
				function getLength(eBase:TExpr, p2:Position):TExpr {
					var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(TexprTools.makeStaticThis(c, p2), cfLength, FHStatic(c), false, p2), FCall);
					return Calls.makeCall(ctx, fieldExpr, [eBase], ctx.com.basic.tint, p2);
				}
				// @:arrayAccess getter on the implementation
				if (a.array.length > 0) {
					function getNext(eBase:TExpr, eIndex:TExpr, t:T, p2:Position):TExpr {
						return Calls.abstractArrayGet(ctx, a, tl, c, eBase, eIndex, p2).expr;
					}
					// Resolve the element type from the first array-access getter field
					var pt:Null<T> = null;
					for (cf in a.array) {
						switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, tl, cf.type))) {
							case TFun(sig) if (sig.args.length >= 2): pt = sig.ret;
							case _:
						}
						if (pt != null) break;
					}
					if (pt != null)
						return {kind: IteratorCustom(getNext, getLength), e: e, pt: pt};
				}
				// @:arrayAccess on a core-type abstract with one parameter
				if (!TypeFunctions.hasMeta(":arrayAccess", a.meta)) throw new hxc.core.NotFound();
				if (!TypeFunctions.hasMeta(":coreType", a.meta)) throw new hxc.core.NotFound();
				if (tl.length != 1) throw new hxc.core.NotFound();
				function getNextElem(arr:TExpr, iexpr:TExpr, pt2:T, p2:Position):TExpr {
					return TypeFunctions.mk(TArray(arr, iexpr), pt2, p2);
				}
				return {kind: IteratorCustom(getNextElem, getLength), e: e, pt: tl[0]};
			case _:
		}
		throw new hxc.core.NotFound();
	}

	public static function ofTexpr(ctx:TyperContext, e:TExpr, unrollWeight:Null<Int>, p:Position):{kind:IterationKindKind, e:TExpr, pt:T} {
		// Recorded, and the loop still lowers as a Dynamic iteration.
		function dynamicIterator(e2:TExpr):{kind:IterationKindKind, e:TExpr, pt:T} {
			ctx.com.addDiagnostic("You can" + "'" + "t iterate on a Dynamic value, please specify Iterator or Iterable", e2.pos);
			return {kind: IteratorDynamic, e: e2, pt: TypeFunctions.tDynamic};
		}
		function doCheckIterator():{kind:IterationKindKind, e:TExpr, pt:T} {
			var arrayAccessResult:Null<{kind:IterationKindKind, e:TExpr, pt:T}> = null;
			function lastResort():TExpr {
				arrayAccessResult = ofTexprByArrayAccess(ctx, e, p);
				return TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, p);
			}
			var r = checkIterator(ctx, "iterator", e, p, lastResort);
			if (arrayAccessResult != null) return arrayAccessResult;
			return switch (TypeFunctions.followWithAbstracts(r.e.type)) {
				case TMono(_) | TDynamic(_): dynamicIterator(r.e);
				// With transforms off, the iterated expression itself, not its .iterator().
				case _: {kind: IteratorIterator, e: ctx.allowTransform ? r.e : e, pt: r.pt};
			};
		}
		function tryForwardArrayIterator():{kind:IterationKindKind, e:TExpr, pt:T} {
			switch (TypeFunctions.follow(e.type)) {
				case TAbstract(a, params) if (switch (a.thisType) {
						case TInst({path: {pack: [], name: "Array"}}, [_]): true;
						case _: false;
					}):
					var forwards = false;
					for (m in a.meta) if (m.name == ":forward") {
						if (m.params.length == 0) forwards = true
						else for (pe in m.params) switch (pe.expr) {
							case EConst(CIdent("iterator")): forwards = true;
							case _:
						}
					}
					if (!forwards) throw new hxc.core.NotFound();
					switch (TypeFunctions.applyParams(a.params, params, a.thisType)) {
						case t = TInst({path: {pack: [], name: "Array"}}, [pt]):
							return {kind: IteratorArray, e: TypeFunctions.mk(TCast(e, null), t, e.pos), pt: pt};
						case _:
							throw new hxc.core.NotFound();
					}
				case _:
					throw new hxc.core.NotFound();
			}
		}
		return switch [e.expr, TypeFunctions.follow(e.type)] {
			case [TNew(c, [], [efrom, eto]), _] if (c.path.pack.length == 0 && c.path.name == "IntIterator"):
				var kind = switch [efrom.expr, eto.expr] {
					case [TConst(TInt(a)), TConst(TInt(b))]:
						var diff = a - b;
						var len = diff < 0 ? -diff : diff;
						if (unrollAllowed(ctx, unrollWeight, len))
							IteratorIntUnroll(a, len, diff <= 0);
						else
							IteratorIntConst(efrom, eto, diff <= 0);
					case _:
						var eto2 = switch (TypeFunctions.follow(eto.type)) {
							case TAbstract({path: {pack: [], name: "Int"}}, []): eto;
							case _: TypeFunctions.mk(TCast(eto, null), ctx.com.basic.tint, eto.pos);
						};
						IteratorInt(efrom, eto2);
				};
				{kind: kind, e: e, pt: ctx.com.basic.tint};
			case [TArrayDecl(el), TInst({path: {pack: [], name: "Array"}}, [pt])]:
				var kind = unrollAllowed(ctx, unrollWeight, el.length) ? IteratorArrayDecl(el) : IteratorArray;
				{kind: kind, e: e, pt: pt};
			case [_, TInst({path: {pack: [], name: "Array"}}, [pt])]:
				{kind: IteratorArray, e: e, pt: pt};
			case [_, TAbstract(a, _)] if (a.impl != null):
				try {
					var vTmp = genLocal(ctx, e.type, e.pos);
					var eTmp = TexprTools.makeLocal(vTmp, vTmp.pos);
					// Probe next/hasNext without the @:op(a.b) resolve fallback: a resolve would claim any name,
					// and this probe must fail over to the iterator() lookup instead.
					var accNext = Fields.typeField(ctx, eTmp, "next", p, MCall([]), WithTypeTools.value, false, true);
					var accHasNext = Fields.typeField(ctx, eTmp, "hasNext", p, MCall([]), WithTypeTools.withType(ctx.com.basic.tbool), false, true);
					switch [accNext, accHasNext] {
						case [AKExpr({expr: TField(_, FDynamic(_))}), _] | [_, AKExpr({expr: TField(_, FDynamic(_))})]:
							throw new hxc.core.NotFound();
						case _:
					}
					var eNext = Calls.buildCall(ctx, accNext, [], WithTypeTools.value, e.pos);
					var eHasNext = Calls.buildCall(ctx, accHasNext, [], WithTypeTools.value, e.pos);
					{kind: IteratorAbstract(vTmp, eNext, eHasNext), e: e, pt: eNext.type};
				} catch (_:hxc.core.NotFound) {
					try tryForwardArrayIterator() catch (_:hxc.core.NotFound) doCheckIterator();
				} catch (_:Fields.FieldNotFoundError) {
					try tryForwardArrayIterator() catch (_:hxc.core.NotFound) doCheckIterator();
				}
			case [_, TAbstract(_, _)]:
				try tryForwardArrayIterator() catch (_:hxc.core.NotFound) doCheckIterator();
			// A haxe.ds.GenericStack whose @:generic instance has already been built iterates by walking
			// its cells directly, so the iterator object never exists.
			case [_, TInst(c, [])] if (switch (c.kind) {
					case KGenericInstance(cg, [_]): cg.path.pack.length == 2
						&& cg.path.pack[0] == "haxe" && cg.path.pack[1] == "ds"
						&& cg.path.name == "GenericStack";
					case _: false;
				}):
				var pt = switch (c.kind) { case KGenericInstance(_, [t]): t; case _: throw false; };
				{kind: IteratorGenericStack(c), e: e, pt: pt};
			case [_, TMono(_)] | [_, TDynamic(_)]:
				dynamicIterator(e);
			case _:
				doCheckIterator();
		};
	}

	public static function toTexpr(ctx:TyperContext, v:TVar, iterator:{kind:IterationKindKind, e:TExpr, pt:T}, e2:TExpr, p:Position):TExpr {
		var e1 = iterator.e;
		var pt = iterator.pt;
		var basic = ctx.com.basic;
		var tVoid = basic.tvoid;
		var tInt = basic.tint;
		function mkField(e:TExpr, n:String):TExprExpr {
			return TField(e, try TypeFunctions.quickField(e.type, n) catch (_:hxc.core.NotFound) throw new TypingError("Missing field " + n, e.pos));
		}
		function getArrayLength(arr:TExpr, p2:Position):TExpr {
			return TypeFunctions.mk(mkField(arr, "length"), basic.tint, p2);
		}
		function checkLoopVarModification(vl:Array<TVar>, e:TExpr):Void {
			function loop(e:TExpr):Void {
				switch (e.expr) {
					case TBinop(OpAssign, {expr: TLocal(l)}, _)
						| TBinop(OpAssignOp(_), {expr: TLocal(l)}, _)
						| TUnop(Increment, _, {expr: TLocal(l)})
						| TUnop(Decrement, _, {expr: TLocal(l)}) if (vl.indexOf(l) >= 0):
						throw new TypingError("Loop variable cannot be modified", e.pos);
					case _:
						TexprTools.iter(loop, e);
				}
			}
			loop(e);
		}
		function getNextArrayElement(arr:TExpr, iexpr:TExpr, pt2:T, p2:Position):TExpr {
			return TypeFunctions.mk(TArray(arr, iexpr), pt2, p2);
		}
		function genIntIter(e1:TExpr, pt2:T, fGet:(TExpr, TExpr, T, Position)->TExpr, fLength:(TExpr, Position)->TExpr):TExpr {
			var index = genLocal(ctx, tInt, v.pos);
			index.meta = ([{name: ":forLoopVariable", params: [], pos: Position.nullPos}] : Metadata).concat(index.meta);
			var arr:TExpr;
			var avar:Null<{v:TVar, e:TExpr}> = null;
			switch (e1.expr) {
				case TLocal(_): arr = e1;
				case _:
					var atmp = genLocal(ctx, e1.type, e1.pos);
					arr = TypeFunctions.mk(TLocal(atmp), e1.type, e1.pos);
					avar = {v: atmp, e: e1};
			}
			var iexpr = TypeFunctions.mk(TLocal(index), tInt, p);
			var aget = TypeFunctions.mk(TVarExpr(v, fGet(arr, iexpr, pt2, p)), tVoid, v.pos);
			var incr = TypeFunctions.mk(TUnop(Increment, Prefix, iexpr), tInt, p);
			var block = switch (e2.expr) {
				case TBlock(el): TypeFunctions.mk(TBlock([aget, incr].concat(el)), tVoid, e2.pos);
				case _: TypeFunctions.mk(TBlock([aget, incr, e2]), tVoid, p);
			};
			var elength = fLength(arr, p);
			var el = [TypeFunctions.mk(TWhile(
				TypeFunctions.mk(TBinop(OpLt, iexpr, elength), basic.tbool, p),
				block, NormalWhile), tVoid, p)];
			if (avar != null) el.unshift(TypeFunctions.mk(TVarExpr(avar.v, avar.e), tVoid, p));
			el.unshift(TypeFunctions.mk(TVarExpr(index, TexprTools.makeInt(basic, 0, p)), tVoid, p));
			return TypeFunctions.mk(TBlock(el), tVoid, p);
		}
		return switch (iterator.kind) {
			// With transforms off (Context.withOptions) the loop stays a TFor.
			case _ if (!ctx.allowTransform): TypeFunctions.mk(TFor(v, e1, e2), tVoid, p);
			case IteratorIntUnroll(offset, length, ascending):
				checkLoopVarModification([v], e2);
				if (!ascending) throw new TypingError("Cannot iterate backwards", p);
				var el:Array<TExpr> = [];
				var localVars:Array<TExpr> = [];
				for (i in 0...length) {
					var ei = TexprTools.makeInt(basic, ascending ? i + offset : offset - i, p);
					var loop:TExpr->TExpr = null;
					loop = function(e:TExpr):TExpr {
						return switch (e.expr) {
							case TLocal(v2) if (v2 == v):
								TypeFunctions.mk(ei.expr, ei.type, e.pos);
							case TVarExpr(v2, eo) if (TypeFunctions.hasVarFlag(v2, VStatic)):
								if (el.length == 0) localVars.push(TypeFunctions.mk(TVarExpr(v2, eo), e.type, e.pos));
								TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, Position.nullPos);
							case _:
								TexprTools.mapExpr(loop, e);
						};
					}
					var e2i = loop(e2);
					for (lv in localVars) el.push(lv);
					localVars = [];
					e2i = TexprTools.duplicateTvars(function(x) return x, e2i);
					el.push(e2i);
				}
				TypeFunctions.mk(TBlock(el), tVoid, p);
			case IteratorIntConst(a, b, ascending):
				checkLoopVarModification([v], e2);
				if (!ascending) throw new TypingError("Cannot iterate backwards", p);
				var vIndex = genLocal(ctx, tInt, a.pos);
				var evarIndex = TypeFunctions.mk(TVarExpr(vIndex, a), tVoid, a.pos);
				var evIndex = TexprTools.makeLocal(vIndex, vIndex.pos);
				var econd = TypeFunctions.mk(TBinop(OpLt, evIndex, b), basic.tbool, Position.union(v.pos, b.pos));
				var evIncr = TypeFunctions.mk(TUnop(Increment, Postfix, evIndex), tInt, Position.union(a.pos, b.pos));
				// The lowered declaration looks in the OUTPUT as though it carried evIncr's position, but
				// that is the ANALYZER's doing, not this line's: AnalyzerFusion rebuilds a declaration
				// fused
				// with a preceding increment at the INITIALISER's position.
				var evar = TypeFunctions.mk(TVarExpr(v, evIncr), tVoid, Position.union(v.pos, a.pos));
				var body = concat(evar, e2);
				TypeFunctions.mk(TBlock([
					evarIndex,
					TypeFunctions.mk(TWhile(econd, body, NormalWhile), tVoid, p)
				]), tVoid, p);
			case IteratorInt(a, b):
				checkLoopVarModification([v], e2);
				var vIndex = genLocal(ctx, tInt, a.pos);
				var evarIndex = TypeFunctions.mk(TVarExpr(vIndex, a), tVoid, a.pos);
				var evIndex = TexprTools.makeLocal(vIndex, vIndex.pos);
				var vB = genLocal(ctx, b.type, b.pos);
				var evarB = TypeFunctions.mk(TVarExpr(vB, b), tVoid, b.pos);
				var evB = TexprTools.makeLocal(vB, b.pos);
				var econd = TypeFunctions.mk(TBinop(OpLt, evIndex, evB), basic.tbool, Position.union(v.pos, b.pos));
				var evIncr = TypeFunctions.mk(TUnop(Increment, Postfix, evIndex), tInt, Position.union(a.pos, b.pos));
				// The lowered declaration looks in the OUTPUT as though it carried evIncr's position, but
				// that is the ANALYZER's doing, not this line's: AnalyzerFusion rebuilds a declaration
				// fused
				// with a preceding increment at the INITIALISER's position.
				var evar = TypeFunctions.mk(TVarExpr(v, evIncr), tVoid, Position.union(v.pos, a.pos));
				var body = concat(evar, e2);
				TypeFunctions.mk(TBlock([
					evarIndex,
					evarB,
					TypeFunctions.mk(TWhile(econd, body, NormalWhile), tVoid, p)
				]), tVoid, p);
			case IteratorArrayDecl(el):
				var el2 = [for (e in el) {
					var ev = TypeFunctions.mk(TVarExpr(v, e), tVoid, e.pos);
					TexprTools.duplicateTvars(function(x) return x, concat(ev, e2));
				}];
				TypeFunctions.mk(TBlock(el2), tVoid, p);
			case IteratorArray | IteratorArrayAccess:
				genIntIter(e1, pt, getNextArrayElement, getArrayLength);
			case IteratorCustom(fNext, fLength):
				genIntIter(e1, pt, fNext, fLength);
			case IteratorIterator:
				try optimizeForLoopIterator(ctx, v, e1, e2, p)
				catch (_:ForExit) TypeFunctions.mk(TFor(v, e1, e2), tVoid, p);
			case IteratorGenericStack(c):
				var tcell = c.fields.get("head").type;
				var cell = genLocal(ctx, tcell, p);
				var cexpr = TypeFunctions.mk(TLocal(cell), tcell, p);
				var evar = TypeFunctions.mk(TVarExpr(v, TypeFunctions.mk(mkField(cexpr, "elt"), pt, p)), tVoid, v.pos);
				var enext = TypeFunctions.mk(TBinop(OpAssign, cexpr, TypeFunctions.mk(mkField(cexpr, "next"), tcell, p)), tcell, p);
				var block = switch (e2.expr) {
					case TBlock(el): TypeFunctions.mk(TBlock([evar, enext].concat(el)), tVoid, e2.pos);
					case _: TypeFunctions.mk(TBlock([evar, enext, e2]), tVoid, p);
				};
				TypeFunctions.mk(TBlock([
					TypeFunctions.mk(TVarExpr(cell, TypeFunctions.mk(mkField(e1, "head"), tcell, p)), tVoid, p),
					TypeFunctions.mk(TWhile(
						TypeFunctions.mk(TBinop(OpNotEq, cexpr, TypeFunctions.mk(TConst(TNull), tcell, p)), basic.tbool, p),
						block,
						NormalWhile
					), tVoid, p)
				]), tVoid, p);
			case IteratorAbstract(vTmp, eNext, eHasNext):
				var evar = TypeFunctions.mk(TVarExpr(v, eNext), tVoid, p);
				var body = concat(evar, e2);
				TypeFunctions.mk(TBlock([
					TypeFunctions.mk(TVarExpr(vTmp, e1), tVoid, p),
					TypeFunctions.mk(TWhile(eHasNext, body, NormalWhile), tVoid, p)
				]), tVoid, p);
			case IteratorDynamic:
				TypeFunctions.mk(TFor(v, e1, e2), tVoid, p);
		};
	}

	public static function typeNormalForLoop(ctx:TyperContext, ident:IterationIdent, e1Expr:Expr, e2:Expr, p:Position):TExpr {
		var e1 = Typer.typeExpr(ctx, e1Expr, WithTypeTools.value);
		var oldLoop = ctx.inLoop;
		var oldLocals = Typer.saveLocals(ctx);
		ctx.inLoop = true;
		var e2b = Expr.ensureBlock(e2);
		var iterator = ofTexpr(ctx, e1, getUnrollWeight(ctx, e2b), p);
		// The name is checked as the local is added.
		Typer.checkLocalVariableName(ctx, ident.name, TVOForVariable, ident.pos);
		var i = Typer.addLocalWithOrigin(ctx, TVOForVariable, ident.name, iterator.pt, ident.pos);
		var te2 = Typer.typeExpr(ctx, e2b, WithTypeTools.noValue);
		ForLoop.checkDisplay(ctx, i, ident);
		ctx.inLoop = oldLoop;
		oldLocals();
		return toTexpr(ctx, i, iterator, te2, p);
	}

	public static function typeKeyValueForLoop(ctx:TyperContext, ikey:IterationIdent, ivalue:IterationIdent, rhs:Expr, body:Expr, p:Position):TExpr {
		var basic = ctx.com.basic;
		var e1 = Typer.typeExpr(ctx, rhs, WithTypeTools.value);
		switch (TypeFunctions.follow(e1.type)) {
			// Recorded, and the loop is typed all the same.
			case TDynamic(_) | TMono(_):
				ctx.com.addDiagnostic("You can" + "'" + "t iterate on a Dynamic value, please specify KeyValueIterator or KeyValueIterable", e1.pos);
			case _:
		}
		var r = checkIterator(ctx, "keyValueIterator", e1, e1.pos);
		e1 = r.e;
		var pt = r.pt;
		var oldLoop = ctx.inLoop;
		var oldLocals = Typer.saveLocals(ctx);
		ctx.inLoop = true;
		var vtmp = genLocal(ctx, e1.type, e1.pos);
		var etmp = TexprTools.makeLocal(vtmp, vtmp.pos);
		var ehasnext = Calls.buildCall(ctx, Fields.typeField(ctx, etmp, "hasNext", etmp.pos, MCall([]), WithTypeTools.withType(basic.tbool)), [], WithTypeTools.value, etmp.pos);
		var enext = Calls.buildCall(ctx, Fields.typeField(ctx, etmp, "next", etmp.pos, MCall([]), WithTypeTools.value), [], WithTypeTools.value, etmp.pos);
		var v = genLocal(ctx, pt, e1.pos);
		var ev = TexprTools.makeLocal(v, v.pos);
		var ekey = Typer.accGet(ctx, Fields.typeField(ctx, ev, "key", ev.pos, MGet, WithTypeTools.value));
		var evalue = Typer.accGet(ctx, Fields.typeField(ctx, ev, "value", ev.pos, MGet, WithTypeTools.value));
		Typer.checkLocalVariableName(ctx, ikey.name, TVOForVariable, ikey.pos);
		var vkey = Typer.addLocalWithOrigin(ctx, TVOForVariable, ikey.name, ekey.type, ikey.pos);
		Typer.checkLocalVariableName(ctx, ivalue.name, TVOForVariable, ivalue.pos);
		var vvalue = Typer.addLocalWithOrigin(ctx, TVOForVariable, ivalue.name, evalue.type, ivalue.pos);
		var e2 = Typer.typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
		ForLoop.checkDisplay(ctx, vkey, ikey);
		ForLoop.checkDisplay(ctx, vvalue, ivalue);
		var ebody = TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(v, enext), basic.tvoid, enext.pos),
			TypeFunctions.mk(TVarExpr(vkey, ekey), basic.tvoid, ekey.pos),
			TypeFunctions.mk(TVarExpr(vvalue, evalue), basic.tvoid, evalue.pos),
			e2
		]), basic.tvoid, e2.pos);
		var e = TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(vtmp, e1), basic.tvoid, e1.pos),
			TypeFunctions.mk(TWhile(ehasnext, ebody, NormalWhile), basic.tvoid, p)
		]), basic.tvoid, p);
		ctx.inLoop = oldLoop;
		oldLocals();
		return e;
	}
}
