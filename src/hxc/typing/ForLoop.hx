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

class ForLoop {
	// Per-iteration loop-variable capture (reference: Codegen capture-vars / CPLoopVars). Under the
	// frame-based eval capture model a loop var reuses one slot across iterations, so every closure
	// inside the body reads the final value. To give each iteration a fresh binding we run the body
	// inside an immediately-invoked function whose parameter is the loop var itself: (function(v)
	// body)(v). Because the param reuses the same TVar (id) as the loop var, references to v inside
	// body resolve to the IIFE frame's fresh param slot, while the loop-frame value is threaded in as
	// the call argument.

	// True when any subnode is a closure literal (TFunction). Without a closure there is nothing
	// to capture, so wrapping would be pointless.
	static function containsClosure(e:TExpr):Bool {
		switch (e.expr) {
			case TFunction(_): return true;
			case TConst(_), TLocal(_), TTypeExpr(_), TBreak, TContinue, TIdent(_): return false;
			case TArray(e1, e2): return containsClosure(e1) || containsClosure(e2);
			case TBinop(_, e1, e2): return containsClosure(e1) || containsClosure(e2);
			case TField(e1, _): return containsClosure(e1);
			case TParenthesis(e1): return containsClosure(e1);
			case TObjectDecl(fields):
				for (f in fields) if (containsClosure(f.expr)) return true;
				return false;
			case TArrayDecl(values):
				for (v in values) if (containsClosure(v)) return true;
				return false;
			case TCall(e1, params):
				if (containsClosure(e1)) return true;
				for (a in params) if (containsClosure(a)) return true;
				return false;
			case TNew(_, _, args):
				for (a in args) if (containsClosure(a)) return true;
				return false;
			case TUnop(_, _, e1): return containsClosure(e1);
			case TVarExpr(_, e1): return e1 != null && containsClosure(e1);
			case TBlock(exprs):
				for (x in exprs) if (containsClosure(x)) return true;
				return false;
			case TFor(_, e1, e2): return containsClosure(e1) || containsClosure(e2);
			case TIf(econd, eif, eelse):
				return containsClosure(econd) || containsClosure(eif) || (eelse != null && containsClosure(eelse));
			case TWhile(econd, e1, _): return containsClosure(econd) || containsClosure(e1);
			case TSwitch(e1, cases, edef):
				if (containsClosure(e1)) return true;
				for (c in cases) {
					for (v in c.values) if (containsClosure(v)) return true;
					if (containsClosure(c.expr)) return true;
				}
				return edef != null && containsClosure(edef);
			case TTry(e1, catches):
				if (containsClosure(e1)) return true;
				for (c in catches) if (containsClosure(c.expr)) return true;
				return false;
			case TReturn(e1): return e1 != null && containsClosure(e1);
			case TThrow(e1): return containsClosure(e1);
			case TCast(e1, _): return containsClosure(e1);
			case TMeta(_, e1): return containsClosure(e1);
			case TEnumParameter(e1, _, _): return containsClosure(e1);
			case TEnumIndex(e1): return containsClosure(e1);
		}
	}

	// True when a TBreak/TContinue is reachable in `e` without first crossing a nested loop
	// (TWhile/TFor) or a function boundary (TFunction). Such control flow targets this loop, and it
	// cannot cross the IIFE function boundary, so we must not wrap when it is present.
	static function hasBareLoopControl(e:TExpr):Bool {
		switch (e.expr) {
			case TBreak, TContinue: return true;
			// Nested loops rebind break/continue; function boundaries block them entirely.
			case TWhile(_, _, _), TFor(_, _, _), TFunction(_): return false;
			case TConst(_), TLocal(_), TTypeExpr(_), TIdent(_): return false;
			case TArray(e1, e2): return hasBareLoopControl(e1) || hasBareLoopControl(e2);
			case TBinop(_, e1, e2): return hasBareLoopControl(e1) || hasBareLoopControl(e2);
			case TField(e1, _): return hasBareLoopControl(e1);
			case TParenthesis(e1): return hasBareLoopControl(e1);
			case TObjectDecl(fields):
				for (f in fields) if (hasBareLoopControl(f.expr)) return true;
				return false;
			case TArrayDecl(values):
				for (v in values) if (hasBareLoopControl(v)) return true;
				return false;
			case TCall(e1, params):
				if (hasBareLoopControl(e1)) return true;
				for (a in params) if (hasBareLoopControl(a)) return true;
				return false;
			case TNew(_, _, args):
				for (a in args) if (hasBareLoopControl(a)) return true;
				return false;
			case TUnop(_, _, e1): return hasBareLoopControl(e1);
			case TVarExpr(_, e1): return e1 != null && hasBareLoopControl(e1);
			case TBlock(exprs):
				for (x in exprs) if (hasBareLoopControl(x)) return true;
				return false;
			case TIf(econd, eif, eelse):
				return hasBareLoopControl(econd) || hasBareLoopControl(eif) || (eelse != null && hasBareLoopControl(eelse));
			case TSwitch(e1, cases, edef):
				if (hasBareLoopControl(e1)) return true;
				for (c in cases) {
					for (v in c.values) if (hasBareLoopControl(v)) return true;
					if (hasBareLoopControl(c.expr)) return true;
				}
				return edef != null && hasBareLoopControl(edef);
			case TTry(e1, catches):
				if (hasBareLoopControl(e1)) return true;
				for (c in catches) if (hasBareLoopControl(c.expr)) return true;
				return false;
			case TReturn(e1): return e1 != null && hasBareLoopControl(e1);
			case TThrow(e1): return hasBareLoopControl(e1);
			case TCast(e1, _): return hasBareLoopControl(e1);
			case TMeta(_, e1): return hasBareLoopControl(e1);
			case TEnumParameter(e1, _, _): return hasBareLoopControl(e1);
			case TEnumIndex(e1): return hasBareLoopControl(e1);
		}
	}

	static function checkLoopVarModification(vl:Array<TVar>, e:TExpr):Void {
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

	// True only for eval: its frame-based capture model reuses one slot per loop var, so the typer wraps.
	// The generator targets get per-iteration freshness from the captured-vars FILTER for CPLoopVars, ref
	// boxing for CPWrapRef), matching the reference, which never wraps in the typer.
	static function needsLoopVarWrap(ctx:TyperContext):Bool {
		return ctx.com.platform.match(Eval);
	}

	// Wrap `body` so it runs inside an IIFE taking the given loop vars as parameters, giving each
	// iteration a fresh frame for its captured loop variables. Only called when safe (see guards). The
	// closure carries :loopCapture so the optimizer's immediately-called-closure inlining leaves it
	// alone: in the reference, capture wrappers are built by the captured-vars filter after
	// reduce_expression, so they are structurally never inline candidates.
	static function wrapLoopVarsBody(ctx:TyperContext, loopVars:Array<TVar>, body:TExpr, p:Position):TExpr {
		var basic = ctx.com.basic;
		var args:Array<TFuncArg> = [for (v in loopVars) {v: v}];
		var sigArgs:Array<TSignatureArg> = [for (v in loopVars) {name: v.name, opt: false, t: v.type}];
		var tf = new TFunc(args, basic.tvoid, body);
		var ft = TFun({args: sigArgs, ret: basic.tvoid});
		var closure = TypeFunctions.mk(TFunction(tf), ft, p);
		closure = TypeFunctions.mk(TMeta({name: ":loopCapture", params: [], pos: p}, closure), ft, p);
		var callArgs = [for (v in loopVars) TexprTools.makeLocal(v, p)];
		return TypeFunctions.mk(TCall(closure, callArgs), basic.tvoid, p);
	}
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

	static function forceOpenMethod(ctx:TyperContext, acc:AccessKind):Void {
		var fa = switch (acc) {
			case AKField(fa): fa;
			case AKUsingField(se): se.access;
			case _: return;
		};
		var cf = fa.field;
		if (!cf.kind.match(Method(_)) || cf.expr != null) return;
		switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig):
				switch (TypeFunctions.follow(sig.ret)) {
					case TMono(r) if (r.type == null):
						switch (fa.host) {
							case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c):
								try TypeFields.forceFieldBody(ctx.com, c, cf) catch (_:Dynamic) {}
							case _:
						}
					case _:
				}
			case _:
		}
	}

	// Resolve a method access `e.name` for a 0-argument call, returning the callee texpr.
	static function methodCallee(ctx:TyperContext, e:TExpr, name:String, p:Position):TExpr {
		var acc = Fields.typeField(ctx, e, name, p, MCall([]), WithTypeTools.value);
		forceOpenMethod(ctx, acc);
		return switch (acc) {
			case AKField(fa): FieldAccessTools.getFieldExpr(fa, FCall);
			case AKUsingField(se): FieldAccessTools.getFieldExpr(se.access, FCall);
			case AKExpr(ce): ce;
			case _: throw new TypingError("Cannot call " + name, p);
		};
	}

	// Build a 0-argument call `e.name`, dispatched through the full call machinery so an iterator
	// supplied by an abstract method (e.g. Map.iterator via its _Impl_) resolves like any other call.
	static function call0(ctx:TyperContext, e:TExpr, name:String, p:Position):TExpr {
		var acc = Fields.typeField(ctx, e, name, p, MCall([]), WithTypeTools.value);
		forceOpenMethod(ctx, acc);
		return Calls.buildCall(ctx, acc, [], WithTypeTools.value, p);
	}

	static function typeKeyValueForLoop(ctx:TyperContext, ki:String, vi:String, rhs:Expr, body:Expr, p:Position):TExpr {
		var basic = ctx.com.basic;
		var rhsTyped = Typer.typeExpr(ctx, rhs, WithTypeTools.value);
		var iterExpr = try call0(ctx, rhsTyped, "keyValueIterator", p) catch (kvErr:TypingError) {
			// rhsTyped may itself be a KeyValueIterator (exposing hasNext/next); use it directly then. If
			// it is neither iterable nor exposes keyValueIterator, the missing accessor is the real
			// problem, so surface that error rather than a later hasNext failure. from
			// IterationKind.check_iterator .
			try { call0(ctx, rhsTyped, "hasNext", p); call0(ctx, rhsTyped, "next", p); rhsTyped; }
			catch (_:TypingError) throw kvErr;
		};
		var oldLoop = ctx.inLoop;
		var oldLocals = Typer.saveLocals(ctx);
		ctx.inLoop = true;
		var vIt = Typer.addLocal(ctx, VGenerated, "_hx_kvit", iterExpr.type, p);
		var eIt = TexprTools.makeLocal(vIt, p);
		var ehasnext = call0(ctx, eIt, "hasNext", p);
		// hasNext must yield Bool (the Iterator<T> contract); reference types it with WithType Bool.
		try hxc.core.TypeUnification.unifyDefault(ehasnext.type, basic.tbool)
		catch (e:hxc.core.TypeUnification.UnifyError) throw new TypingError(hxc.core.TPrinting.betterErrorMessage(e.errors), p);
		var enext = call0(ctx, eIt, "next", p);
		var vKv = Typer.addLocal(ctx, VGenerated, "_hx_kv", enext.type, p);
		var eKv = TexprTools.makeLocal(vKv, p);
		var ekey = Typer.accGet(ctx, Fields.typeField(ctx, eKv, "key", p, MGet, WithTypeTools.value));
		var evalue = Typer.accGet(ctx, Fields.typeField(ctx, eKv, "value", p, MGet, WithTypeTools.value));
		var vkey = Typer.addLocalWithOrigin(ctx, TVOForVariable, ki, ekey.type, p);
		var vvalue = Typer.addLocalWithOrigin(ctx, TVOForVariable, vi, evalue.type, p);
		var typedBody = Typer.typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
		ctx.inLoop = oldLoop;
		oldLocals();
		var whileBody = TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(vKv, enext), basic.tvoid, p),
			TypeFunctions.mk(TVarExpr(vkey, ekey), basic.tvoid, p),
			TypeFunctions.mk(TVarExpr(vvalue, evalue), basic.tvoid, p),
			typedBody
		]), basic.tvoid, p);
		var ewhile = TypeFunctions.mk(TWhile(ehasnext, whileBody, NormalWhile), basic.tvoid, p);
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(vIt, iterExpr), basic.tvoid, p),
			ewhile
		]), basic.tvoid, p);
	}

	// Array-access iteration: for an array-like value (a length:Int field plus array read access) that
	// exposes no iterator, desugar `for (x in e)` to a 0...length index loop over e[i], reusing the
	// existing length/array-access typing. Returns null when e is not array-like. The increment runs before
	// the body so `continue` stays correct.
	static function tryArrayAccessForLoop(ctx:TyperContext, vName:String, e1Expr:Expr, e2:Expr, p:Position):Null<TExpr> {
		inline function ident(n:String):Expr return new Expr(EConst(CIdent(n)), p);
		inline function decl(n:String, e:Expr):Expr
			return new Expr(EVars([{evName: {name: n, pos: p}, evFinal: false, evStatic: false, evType: null, evExpr: e, evMeta: []}]), p);
		var arr = "_hx_aa_arr", idx = "_hx_aa_i";
		var cond = new Expr(EBinop(OpLt, ident(idx), new Expr(EField(ident(arr), "length", EFNormal), p)), p);
		var wbody = new Expr(EBlock([
			decl(vName, new Expr(EArray(ident(arr), ident(idx)), p)),
			new Expr(EUnop(Increment, Postfix, ident(idx)), p),
			e2
		]), p);
		var block = new Expr(EBlock([
			decl(arr, e1Expr),
			decl(idx, new Expr(EConst(CInt("0", null)), p)),
			new Expr(EWhile(cond, wbody, NormalWhile), p)
		]), p);
		var restore = Typer.saveLocals(ctx);
		return try Typer.typeExpr(ctx, block, WithTypeTools.noValue) catch (_:TypingError) { restore(); null; };
	}

	static function typeIntIteratorForLoop(ctx:TyperContext, vName:String, e1:TExpr, e2:Expr, p:Position):Null<TExpr> {
		var args = switch (e1.expr) {
			case TNew(c, [], args) if (c.path.pack.length == 0 && c.path.name == "IntIterator" && args.length == 2):
				args;
			case _:
				return null;
		}
		var basic = ctx.com.basic;
		var oldLoop = ctx.inLoop;
		var oldLocals = Typer.saveLocals(ctx);
		ctx.inLoop = true;
		var vIndex = Typer.addLocal(ctx, VGenerated, "_hx_i", basic.tint, args[0].pos);
		var eIndex = TexprTools.makeLocal(vIndex, p);
		var v = Typer.addLocalWithOrigin(ctx, TVOForVariable, vName, basic.tint, p);
		var body = Typer.typeExpr(ctx, Expr.ensureBlock(e2), WithTypeTools.noValue);
		checkLoopVarModification([v], body);
		ctx.inLoop = oldLoop;
		oldLocals();

		// The IntIterator captures its upper bound at construction; bind it to a temp so a body that
		// mutates the bound expression does not change the iteration count.
		var vMax = TypeFunctions.allocVar(VGenerated, "_hx_max", args[1].type, args[1].pos);
		var eMax = TexprTools.makeLocal(vMax, p);
		var op = TypeFunctions.mk(TUnop(Increment, Postfix, eIndex), basic.tint, p);
		var evar = TypeFunctions.mk(TVarExpr(v, op), basic.tvoid, p);
		var iterBody = body;
		if (needsLoopVarWrap(ctx) && containsClosure(body) && !hasBareLoopControl(body)) {
			iterBody = wrapLoopVarsBody(ctx, [v], body, p);
		}
		var whileBody = TypeFunctions.mk(TBlock([evar, iterBody]), basic.tvoid, p);
		var cond = TypeFunctions.mk(TBinop(OpLt, eIndex, eMax), basic.tbool, p);
		var ewhile = TypeFunctions.mk(TWhile(cond, whileBody, NormalWhile), basic.tvoid, p);
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(vIndex, args[0]), basic.tvoid, args[0].pos),
			TypeFunctions.mk(TVarExpr(vMax, args[1]), basic.tvoid, args[1].pos),
			ewhile
		]), basic.tvoid, p);
	}

	public static function typeForLoop(ctx:TyperContext, it:Expr, e2:Expr, p:Position):TExpr {
		var vName:String;
		var e1Expr:Expr;
		switch (it.expr) {
			// `for (k => v in e)` parses as OpArrow(k, OpIn(v, e)) since `in` binds tighter than
			// `=>`; a macro-built head may carry the OpIn(OpArrow(k, v), e) shape instead.
			case EBinop(OpArrow, kexpr = {expr: EConst(CIdent(ki))}, {expr: EBinop(OpIn, vexpr = {expr: EConst(CIdent(vi))}, rhs)})
				| EBinop(OpIn, {expr: EBinop(OpArrow, kexpr = {expr: EConst(CIdent(ki))}, vexpr = {expr: EConst(CIdent(vi))})}, rhs):
				Typer.checkLocalVariableName(ctx, ki, TVOForVariable, kexpr.pos);
				Typer.checkLocalVariableName(ctx, vi, TVOForVariable, vexpr.pos);
				return ctx.com.platform.match(Eval)
					? typeKeyValueForLoop(ctx, ki, vi, rhs, e2, p)
					: ForLoopFaithful.typeKeyValueForLoop(ctx, ki, vi, rhs, e2, p);
			case EBinop(OpIn, lhs, rhs):
				vName = switch (lhs.expr) {
					case EConst(CIdent(i)): i;
					case _: throw new TypingError("Identifier expected", lhs.pos);
				};
				Typer.checkLocalVariableName(ctx, vName, TVOForVariable, lhs.pos);
				e1Expr = rhs;
			case _:
				throw new TypingError("For expression should be 'v in expr'", it.pos);
		}
		// The eval lane keeps the legacy lowering below: its frame-based capture model needs
		// the typer-level IIFE wrap that the reference performs in the captured-vars filter,
		// which the eval pipeline does not run. Generated targets take the faithful port.
		if (!ctx.com.platform.match(Eval))
			return ForLoopFaithful.typeNormalForLoop(ctx, vName, e1Expr, e2, p);
		var basic = ctx.com.basic;
		var e1 = Typer.typeExpr(ctx, e1Expr, WithTypeTools.value);
		var intLoop = typeIntIteratorForLoop(ctx, vName, e1, e2, p);
		if (intLoop != null) return intLoop;
		// The iterator is e1.iterator when e1 is iterable, otherwise e1 itself. If e1 exposes no iterator,
		// fall back to array-access iteration for array-like values.
		var iterExpr = e1;
		var pt = TypeFunctions.mkMono();
		try {
			iterExpr = try call0(ctx, e1, "iterator", p) catch (_:TypingError) e1;
			// When the iterator candidate is an abstract that does not expose next directly, follow it to its
			// underlying type (the reference casts to Iterator<_>) so an abstract over an Iterator iterates.
			var nextCallee = try methodCallee(ctx, iterExpr, "next", p) catch (_:TypingError) {
				var ut = TypeFunctions.followWithAbstracts(iterExpr.type);
				iterExpr = TypeFunctions.mk(TCast(iterExpr, null), ut, iterExpr.pos);
				methodCallee(ctx, iterExpr, "next", p);
			};
			pt = switch (TypeFunctions.follow(nextCallee.type)) {
				case TFun(sig): sig.ret;
				case _: TypeFunctions.mkMono();
			};
		} catch (err:TypingError) {
			var aa = tryArrayAccessForLoop(ctx, vName, e1Expr, e2, p);
			if (aa != null) return aa;
			throw err;
		}
		var oldLoop = ctx.inLoop;
		var oldLocals = Typer.saveLocals(ctx);
		ctx.inLoop = true;
		var vIt = Typer.addLocal(ctx, VGenerated, "_hx_it", iterExpr.type, p);
		var eIt = TexprTools.makeLocal(vIt, p);
		var v = Typer.addLocalWithOrigin(ctx, TVOForVariable, vName, pt, p);
		var body = Typer.typeExpr(ctx, Expr.ensureBlock(e2), WithTypeTools.noValue);
		ctx.inLoop = oldLoop;
		oldLocals();
		var ehasnext = call0(ctx, eIt, "hasNext", p);
		var enext = call0(ctx, eIt, "next", p);
		// CPLoopVars: give each iteration a fresh binding of the loop var, but only when the body
		// captures it (contains a closure) and no bare break/continue would need to cross the IIFE.
		var iterBody = body;
		if (needsLoopVarWrap(ctx) && containsClosure(body) && !hasBareLoopControl(body)) {
			iterBody = wrapLoopVarsBody(ctx, [v], body, p);
		}
		var whileBody = TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(v, enext), basic.tvoid, p),
			iterBody
		]), basic.tvoid, p);
		var ewhile = TypeFunctions.mk(TWhile(ehasnext, whileBody, NormalWhile), basic.tvoid, p);
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(vIt, iterExpr), basic.tvoid, p),
			ewhile
		]), basic.tvoid, p);
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
	static function tIterator(ctx:TyperContext):{t:T, pt:T} {
		var mt = ctx.com.getType({pack: [], name: "StdTypes"}, Position.nullPos, "Iterator");
		return switch (mt) {
			case TTypeDecl(td):
				var pt = TypeFunctions.mkMono();
				{t: TType(td, [pt]), pt: pt};
			case _:
				throw new TypingError("Standard library Iterator typedef not found", Position.nullPos);
		};
	}

	// The syntactic expression weight for unrolling, or null when the body breaks/continues
	// (those cannot unroll).
	public static function getUnrollWeight(ctx:TyperContext, e2:Expr):Null<Int> {
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
			var e2 = Typer.castOrUnify(ctx, it.t, e, p);
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
				} catch (_:hxc.core.TypeUnification.UnifyError) {
					tryLastResort(function() {
						if (dynamicIterator != null) return dynamicIterator;
						throw new TypingError("Field iterator has an invalid type", accExpr.pos);
					});
				}
			}
			try {
				var acc = Fields.typeField(ctx, e, s, e.pos, MCall([]), WithTypeTools.withType(it.t));
				tryAcc(acc);
			} catch (_:Fields.FieldNotFoundError) {
				tryLastResort(function() {
					if (dynamicIterator != null) return dynamicIterator;
					var acc = Fields.typeField(ctx, e, s, e.pos, MCall([]), WithTypeTools.withType(it.t));
					return tryAcc(acc);
				});
			}
		}
		return {e: e1, pt: it.pt};
	}

	static function ofTexprByArrayAccess(ctx:TyperContext, e:TExpr, p:Position):{kind:IterationKindKind, e:TExpr, pt:T} {
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
		function dynamicIterator(e2:TExpr):{kind:IterationKindKind, e:TExpr, pt:T} {
			throw new TypingError("You can" + "'" + "t iterate on a Dynamic value, please specify Iterator or Iterable", e2.pos);
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
				case _: {kind: IteratorIterator, e: r.e, pt: r.pt};
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
					var accNext = Fields.typeField(ctx, eTmp, "next", p, MCall([]), WithTypeTools.value, false);
					var accHasNext = Fields.typeField(ctx, eTmp, "hasNext", p, MCall([]), WithTypeTools.withType(ctx.com.basic.tbool), false);
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

	public static function typeNormalForLoop(ctx:TyperContext, vName:String, e1Expr:Expr, e2:Expr, p:Position):TExpr {
		var e1 = Typer.typeExpr(ctx, e1Expr, WithTypeTools.value);
		var oldLoop = ctx.inLoop;
		var oldLocals = Typer.saveLocals(ctx);
		ctx.inLoop = true;
		var e2b = Expr.ensureBlock(e2);
		var iterator = ofTexpr(ctx, e1, getUnrollWeight(ctx, e2b), p);
		var i = Typer.addLocalWithOrigin(ctx, TVOForVariable, vName, iterator.pt, p);
		var te2 = Typer.typeExpr(ctx, e2b, WithTypeTools.noValue);
		ctx.inLoop = oldLoop;
		oldLocals();
		return toTexpr(ctx, i, iterator, te2, p);
	}

	public static function typeKeyValueForLoop(ctx:TyperContext, ki:String, vi:String, rhs:Expr, body:Expr, p:Position):TExpr {
		var basic = ctx.com.basic;
		var e1 = Typer.typeExpr(ctx, rhs, WithTypeTools.value);
		switch (TypeFunctions.follow(e1.type)) {
			case TDynamic(_) | TMono(_):
				throw new TypingError("You can" + "'" + "t iterate on a Dynamic value, please specify KeyValueIterator or KeyValueIterable", e1.pos);
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
		var vkey = Typer.addLocalWithOrigin(ctx, TVOForVariable, ki, ekey.type, p);
		var vvalue = Typer.addLocalWithOrigin(ctx, TVOForVariable, vi, evalue.type, p);
		var e2 = Typer.typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
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
