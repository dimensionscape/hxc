package hxc.compiler;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.context.Context;
import hxc.core.Globals.MessageSeverity;

class Diagnostics {
	// Diagnostic kind 3 includes a description and the editor's removable range.
	public static var removableCode:Array<{s:String, p:Position, prange:Position}> = [];

	public static function reset():Void {
		removableCode = [];
	}

	// Skip supplementary diagnostics when an error has already been recorded.
	public static function collect(ctx:Context, inDiagnosticsFile:String->Bool):Void {
		for (d in ctx.diagnostics) if (d.severity == Error) return;
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c):
				if (!inDiagnosticsFile(c.pos.file)) continue;
				for (cf in c.orderedFields) prepareField(ctx, cf);
				for (cf in c.orderedStatics) prepareField(ctx, cf);
				if (c.constructor != null) prepareField(ctx, c.constructor);
			case _:
		}
	}

	static function prepareField(ctx:Context, cf:TClassField):Void {
		if (cf.expr == null) return;
		findUnusedVariables(cf.expr);
		checkOtherThings(ctx, cf.expr);
	}

	// The removable range ends at the initializer. Suppress it when several variables share the
	// declaration position.
	static function findUnusedVariables(root:TExpr):Void {
		var vars = new Map<Int, {v:TVar, p:Position}>();
		var order:Array<Int> = [];
		var pminCount = new Map<Int, Int>();
		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TVarExpr(v, eo) if (isUserVar(v) && v.name != "_" && !TypeFunctions.hasVarFlag(v, VUsedByTyper)):
					pminCount.set(e.pos.min, (pminCount.exists(e.pos.min) ? pminCount.get(e.pos.min) : 0) + 1);
					var p = if (eo != null && !isPatternVar(v)) {
						loop(eo);
						new Position(e.pos.file, e.pos.min, eo.pos.min);
					} else e.pos;
					if (!vars.exists(v.id)) order.push(v.id);
					vars.set(v.id, {v: v, p: p});
				case TLocal(v) if (isUserVar(v)):
					vars.remove(v.id);
				case _:
					TexprTools.iter(loop, e);
			}
		}
		loop(root);
		for (id in order) {
			var r = vars.get(id);
			if (r == null) continue;
			var p = pminCount.get(r.p.min) == 1 ? r.p : Position.nullPos;
			removableCode.push({s: "Unused variable", p: r.v.pos, prange: p});
		}
	}

	static inline function isUserVar(v:TVar):Bool {
		return v.kind.match(VUser(_));
	}

	static inline function isPatternVar(v:TVar):Bool {
		return v.kind.match(VUser(TVOPatternVariable));
	}

	// Distinguish effect-free statements from compounds with effectful children.
	static function checkOtherThings(ctx:Context, root:TExpr):Void {
		var hadEffect = false;
		inline function noEffect(p:Position)
			ctx.addDiagnostic("This code has no effect", p, 0, MessageSeverity.Warning);
		inline function pointlessCompound(s:String, p:Position)
			ctx.addDiagnostic("This " + s + " has no effect, but some of its sub-expressions do", p, 0, MessageSeverity.Warning);
		var loop:(Bool, TExpr) -> Void = null;
		function compound(s:String, el:Array<TExpr>, p:Position):Void {
			var old = hadEffect;
			hadEffect = false;
			for (e in el) loop(true, e);
			if (!hadEffect) noEffect(p) else pointlessCompound(s, p);
			hadEffect = old;
		}
		function inValueIter(e:TExpr):Void
			TexprTools.iter(function(e1) loop(true, e1), e);
		loop = function(inValue:Bool, e:TExpr):Void {
			switch (e.expr) {
				case TBlock(el):
					for (i in 0...el.length) loop(i == el.length - 1 ? inValue : false, el[i]);
				case TMeta(m, _) if (m.name == ":extern"):
					// So something like `[inlineFunc()]` is not reported.
					hadEffect = true;
				case TConst(_) | TTypeExpr(_) | TIdent(_) if (!inValue):
					noEffect(e.pos);
				case TLocal(v) if (!inValue && isUserVar(v)):
					noEffect(e.pos);
				case TFunction(tf) if (!inValue):
					noEffect(e.pos);
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TEnumParameter(_, _, _) | TEnumIndex(_) | TVarExpr(_, _) | TIdent(_):
				case TField(_, fa) if (hxc.context.PurityState.isExplicitlyImpure(fa)):
				case TFunction(tf):
					loop(false, tf.expr);
				case TCall({expr: TField(_, fa)}, el) if (!inValue && hxc.context.PurityState.isPureFieldAccess(fa)):
					compound("call", el, e.pos);
				case TCast(_, t) if (t != null):
					hadEffect = true;
					inValueIter(e);
				case TNew(_, _, _) | TCall(_, _) | TReturn(_) | TBreak | TContinue | TThrow(_)
					| TIf(_, _, _) | TTry(_, _) | TSwitch(_, _, _) | TWhile(_, _, _) | TFor(_, _, _)
					| TBinop(OpAssign | OpAssignOp(_), _, _) | TUnop(Increment | Decrement, _, _):
					hadEffect = true;
					inValueIter(e);
				case TParenthesis(e1) | TMeta(_, e1):
					loop(inValue, e1);
				case TArray(_, _) | TCast(_, _) | TBinop(_, _, _) | TUnop(_, _, _)
					| TField(_, _) | TArrayDecl(_) | TObjectDecl(_) if (inValue):
					inValueIter(e);
				case TArray(e1, e2):
					compound("array access", [e1, e2], e.pos);
				case TCast(e1, null):
					compound("cast", [e1], e.pos);
				case TBinop(op, e1, e2):
					compound("'" + hxc.ast.Ast.sBinop(op) + "' operator", [e1, e2], e.pos);
				case TUnop(op, _, e1):
					compound("'" + hxc.ast.Ast.sUnop(op) + "' operator", [e1], e.pos);
				case TField(e1, _):
					compound("field access", [e1], e.pos);
				case TArrayDecl(el):
					compound("array declaration", el, e.pos);
				case TObjectDecl(fl):
					compound("object declaration", [for (f in fl) f.expr], e.pos);
				case _:
					inValueIter(e);
			}
		};
		loop(true, root);
	}

}
