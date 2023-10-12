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

	// True when the active capture policy needs per-iteration loop-var freshness. CPNone relies on
	// native block scoping for fresh bindings; every other policy runs the frame-based model.
	static function needsLoopVarWrap(ctx:TyperContext):Bool {
		return switch (ctx.com.platformConfig.capturePolicy) {
			case CPNone: false;
			case CPLoopVars, CPWrapRef: true;
		};
	}

	// Wrap `body` so it runs inside an IIFE taking the given loop vars as parameters, giving each
	// iteration a fresh frame for its captured loop variables. Only called when safe (see guards).
	static function wrapLoopVarsBody(ctx:TyperContext, loopVars:Array<TVar>, body:TExpr, p:Position):TExpr {
		var basic = ctx.com.basic;
		var args:Array<TFuncArg> = [for (v in loopVars) {v: v}];
		var sigArgs:Array<TSignatureArg> = [for (v in loopVars) {name: v.name, opt: false, t: v.type}];
		var tf = new TFunc(args, basic.tvoid, body);
		var closure = TypeFunctions.mk(TFunction(tf), TFun({args: sigArgs, ret: basic.tvoid}), p);
		var callArgs = [for (v in loopVars) TexprTools.makeLocal(v, p)];
		return TypeFunctions.mk(TCall(closure, callArgs), basic.tvoid, p);
	}
	// Resolve a method access `e.name` for a 0-argument call, returning the callee texpr.
	static function methodCallee(ctx:TyperContext, e:TExpr, name:String, p:Position):TExpr {
		var acc = Fields.typeField(ctx, e, name, p, MCall([]), WithTypeTools.value);
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
			// `for (k => v in e)` parses as OpArrow(k, OpIn(v, e)) since `in` binds tighter than `=>`.
			case EBinop(OpArrow, {expr: EConst(CIdent(ki))}, {expr: EBinop(OpIn, {expr: EConst(CIdent(vi))}, rhs)}):
				return typeKeyValueForLoop(ctx, ki, vi, rhs, e2, p);
			case EBinop(OpIn, lhs, rhs):
				vName = switch (lhs.expr) {
					case EConst(CIdent(i)): i;
					case _: throw new TypingError("Identifier expected", lhs.pos);
				};
				e1Expr = rhs;
			case _:
				throw new TypingError("For expression should be 'v in expr'", it.pos);
		}
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
