package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;

class ForLoop {
	// Resolve a method access `e.name` for a 0-argument call, returning the callee texpr.
	static function methodCallee(ctx:TyperContext, e:TExpr, name:String, p:Position):TExpr {
		var acc = Fields.typeField(ctx, e, name, p, MCall([]), WithTypeTools.value);
		return switch (acc) {
			case AKField(fa): FieldAccessTools.getFieldExpr(fa, FCall);
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

	// Type_for_loop (general iterator desugar).
	// `for (k => v in e)` desugars to iterating e.keyValueIterator(), binding k and v from each
	// pair, then typing the resulting block with the existing machinery.
	static function typeKeyValueForLoop(ctx:TyperContext, ki:String, vi:String, rhs:Expr, body:Expr, p:Position):TExpr {
		var tmpIt = "`kvit";
		var tmpKv = "`kv";
		inline function ident(n:String):Expr return new Expr(EConst(CIdent(n)), p);
		inline function decl(n:String, e:Expr):Expr
			return new Expr(EVars([{evName: {name: n, pos: p}, evFinal: false, evStatic: false, evType: null, evExpr: e, evMeta: []}]), p);
		inline function call0e(recv:Expr, m:String):Expr
			return new Expr(ECall(new Expr(EField(recv, m, EFNormal), p), []), p);
		var itDecl = decl(tmpIt, call0e(rhs, "keyValueIterator"));
		var cond = call0e(ident(tmpIt), "hasNext");
		var kvDecl = decl(tmpKv, call0e(ident(tmpIt), "next"));
		var kDecl = decl(ki, new Expr(EField(ident(tmpKv), "key", EFNormal), p));
		var vDecl = decl(vi, new Expr(EField(ident(tmpKv), "value", EFNormal), p));
		var innerBody = new Expr(EBlock([kvDecl, kDecl, vDecl, body]), p);
		var ewhile = new Expr(EWhile(cond, innerBody, NormalWhile), p);
		var block = new Expr(EBlock([itDecl, ewhile]), p);
		return Typer.typeExpr(ctx, block, WithTypeTools.noValue);
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
		// The iterator is e1.iterator when e1 is iterable, otherwise e1 itself.
		var iterExpr = try call0(ctx, e1, "iterator", p) catch (_:TypingError) e1;
		var pt = switch (TypeFunctions.follow(methodCallee(ctx, iterExpr, "next", p).type)) {
			case TFun(sig): sig.ret;
			case _: TypeFunctions.mkMono();
		};
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
		var whileBody = TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(v, enext), basic.tvoid, p),
			body
		]), basic.tvoid, p);
		var ewhile = TypeFunctions.mk(TWhile(ehasnext, whileBody, NormalWhile), basic.tvoid, p);
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(vIt, iterExpr), basic.tvoid, p),
			ewhile
		]), basic.tvoid, p);
	}
}
