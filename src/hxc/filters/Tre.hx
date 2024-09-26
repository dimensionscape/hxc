package hxc.filters;

// Tail recursion elimination: a tail-position self-call becomes argument reassignment plus continue inside
// a while(true) wrapper.

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.typing.TyperContext;

class Tre {
	// Every call argument lands in a fresh temp first so the reassignments below cannot observe
	// already-overwritten arguments.
	static function collectNewArgsValues(ctx:TyperContext, args:Array<TExpr>):{declarations:Array<TExpr>, values:Array<TExpr>} {
		var declarations:Array<TExpr> = [];
		var values:Array<TExpr> = [];
		for (n in 0...args.length) {
			var arg = args[n];
			var v = TypeFunctions.allocVar(VGenerated, "`tmp" + n, arg.type, arg.pos);
			declarations.push(TypeFunctions.mk(TVarExpr(v, arg), ctx.com.basic.tvoid, v.pos));
			values.push(TypeFunctions.mk(TLocal(v), arg.type, arg.pos));
		}
		return {declarations: declarations, values: values};
	}

	// An omitted trailing argument reassigns from its default.
	static function assignArgs(fnArgs:Array<TFuncArg>, exprs:Array<TExpr>, p:Position):Array<TExpr> {
		var out:Array<TExpr> = [];
		for (i in 0...fnArgs.length) {
			var v = fnArgs[i].v;
			var e = i < exprs.length ? exprs[i] : fnArgs[i].c;
			if (e == null) throw new TypingError("Missing tail-call argument", p);
			var arg = TypeFunctions.mk(TLocal(v), e.type, e.pos);
			out.push(TypeFunctions.mk(TBinop(OpAssign, arg, e), e.type, e.pos));
		}
		return out;
	}

	static function replacementForTReturn(ctx:TyperContext, fn:TFunc, args:Array<TExpr>, p:Position):TExpr {
		var collected = collectNewArgsValues(ctx, args);
		var cont = TypeFunctions.mk(TContinue, ctx.com.basic.tvoid, Position.nullPos);
		var block = TypeFunctions.mk(TBlock(collected.declarations.concat(assignArgs(fn.args, collected.values, p)).concat([cont])),
			ctx.com.basic.tvoid, p);
		return TypeFunctions.mk(TMeta({name: ":tailRecursion", params: [], pos: Position.nullPos}, block), ctx.com.basic.tvoid, p);
	}

	static function collectCapturedArgs(args:Array<TVar>, e:TExpr):Array<TVar> {
		var result:Array<TVar> = [];
		function loop(inClosure:Bool, e:TExpr):Void {
			switch (e.expr) {
				// The result is built by PREPENDING, so the loop-scoped copies are allocated in reverse
				// discovery order. Their variable ids decide the wrapper closure's parameter order in
				// capturedVars.
				case TLocal(v) if (inClosure && v.kind.match(VUser(TVOArgument)) && result.indexOf(v) < 0 && args.indexOf(v) >= 0):
					result.unshift(v);
				case TFunction(f):
					loop(true, f.expr);
				case _:
					TexprTools.iter(function(x) loop(inClosure, x), e);
			}
		}
		loop(false, e);
		return result;
	}

	static function isArgumentLocal(e:TExpr):Bool {
		return switch (e.expr) {
			case TLocal(v): v.kind.match(VUser(TVOArgument));
			case _: false;
		};
	}

	// Captured arguments read through their loop-scoped copies, except the reassignments inside a
	// @:tailRecursion block which write the originals.
	static function replaceVars(replaceList:Array<{v:TVar, nv:TVar}>, inTailRecursion:Bool, e:TExpr):TExpr {
		return switch (e.expr) {
			case TBinop(OpAssign, arg, value) if (inTailRecursion && isArgumentLocal(arg)):
				var value2 = replaceVars(replaceList, inTailRecursion, value);
				TypeFunctions.mk(TBinop(OpAssign, arg, value2), e.type, e.pos);
			case TLocal(v):
				var found:Null<TVar> = null;
				for (r in replaceList) if (r.v == v) { found = r.nv; break; }
				found == null ? e : TypeFunctions.mk(TLocal(found), e.type, e.pos);
			case TMeta(m, _) if (m.name == ":tailRecursion"):
				TexprTools.mapExpr(function(x) return replaceVars(replaceList, true, x), e);
			case _:
				TexprTools.mapExpr(function(x) return replaceVars(replaceList, inTailRecursion, x), e);
		};
	}

	// Closures capturing an argument get a per-iteration copy so each iteration's closures see their own
	// value.
	static function wrapLoop(ctx:TyperContext, args:Array<TVar>, body:TExpr):TExpr {
		function wrap(e:TExpr):TExpr {
			var cond = TypeFunctions.mk(TConst(TBool(true)), ctx.com.basic.tbool, Position.nullPos);
			return TypeFunctions.mk(TWhile(cond, e, NormalWhile), e.type, e.pos);
		}
		var captured = collectCapturedArgs(args, body);
		if (captured.length == 0) return wrap(body);
		var declarations:Array<TExpr> = [];
		var replaceList:Array<{v:TVar, nv:TVar}> = [];
		for (v in captured) {
			var nv = TypeFunctions.allocVar(VGenerated, "`" + v.name, v.type, v.pos);
			// Prepending onto `declarations` leaves them in REVERSE of `captured`, which is the order the
			// copies are declared in the loop body.
			declarations.unshift(TypeFunctions.mk(TVarExpr(nv, TypeFunctions.mk(TLocal(v), v.type, v.pos)), ctx.com.basic.tvoid, v.pos));
			replaceList.push({v: v, nv: nv});
		}
		return wrap(TypeFunctions.mk(TBlock(declarations.concat([replaceVars(replaceList, false, body)])), body.type, body.pos));
	}

	static function fnArgsVars(fn:TFunc):Array<TVar> {
		return [for (a in fn.args) a.v];
	}

	static function isRecursiveNamedLocalCall(fnVar:TVar, callee:TExpr, args:Array<TExpr>):Bool {
		return switch (callee.expr) {
			case TLocal(v): v == fnVar;
			case _: false;
		};
	}

	static function isRecursiveMethodCall(field:TClassField, callee:TExpr, args:Array<TExpr>):Bool {
		return switch (callee.expr) {
			// Member abstract function: the receiver must be the abstract this argument
			case TField(_, FStatic(_, cf)) if (TypeFunctions.hasClassFieldFlag(cf, CfImpl) && args.length > 0 && args[0].expr.match(TLocal(_))):
				var thisMeta = switch (args[0].expr) {
					case TLocal(v): TypeFunctions.hasMeta(":this", v.meta);
					case _: false;
				};
				cf == field && thisMeta;
			case TField(_, FStatic(_, cf)):
				cf == field;
			case _: false;
		};
	}

	static function transformFunction(ctx:TyperContext, isRecursiveCall:(callee:TExpr, args:Array<TExpr>)->Bool, fn:TFunc):TFunc {
		var addLoop = false;
		function transformExpr(cancelTre:Bool, functionEnd:Bool, e:TExpr):TExpr {
			return switch (e.expr) {
				// Cancel tre inside of loop bodies
				case TWhile(_, _, _) | TFor(_, _, _):
					TexprTools.mapExpr(function(x) return transformExpr(true, false, x), e);
				// Cancel tre inside of try blocks
				case TTry(eTry, catches):
					var eTry2 = transformExpr(true, functionEnd, eTry);
					TypeFunctions.mk(TTry(eTry2, [for (c in catches) {v: c.v, expr: transformExpr(cancelTre, functionEnd, c.expr)}]), e.type, e.pos);
				case TBinop(OpAssign, eVar = {expr: TLocal(v = {kind: VUser(TVOLocalFunction)})}, eFn = {expr: TFunction(fn2)}):
					var fn3 = transformFunction(ctx, function(callee, args) return isRecursiveNamedLocalCall(v, callee, args), fn2);
					TypeFunctions.mk(TBinop(OpAssign, eVar, TypeFunctions.mk(TFunction(fn3), eFn.type, eFn.pos)), e.type, e.pos);
				// Anonymous function
				case TFunction(_):
					e;
				// Return a recursive call to the current function
				case TReturn(r) if (r != null):
					switch (r.expr) {
						case TCall(callee, args) if (!cancelTre && isRecursiveCall(callee, args)):
							addLoop = true;
							replacementForTReturn(ctx, fn, args, e.pos);
						case _:
							TypeFunctions.mk(TReturn(transformExpr(cancelTre, functionEnd, r)), e.type, e.pos);
					}
				case TBlock(exprs):
					var out:Array<TExpr> = [];
					var i = 0;
					var stop = false;
					while (i < exprs.length && !stop) {
						var cur = exprs[i];
						var isLast = i == exprs.length - 1;
						switch (cur.expr) {
							case TCall(callee, args) if (isLast && !cancelTre && functionEnd && isRecursiveCall(callee, args)):
								addLoop = true;
								out.push(replacementForTReturn(ctx, fn, args, cur.pos));
								stop = true;
							case TCall(callee, args) if (i == exprs.length - 2 && exprs[i + 1].expr.match(TReturn(null)) && !cancelTre && isRecursiveCall(callee, args)):
								addLoop = true;
								out.push(replacementForTReturn(ctx, fn, args, cur.pos));
								stop = true;
							case _:
								out.push(transformExpr(cancelTre, functionEnd && isLast, cur));
						}
						i++;
					}
					TypeFunctions.mk(TBlock(out), e.type, e.pos);
				case _:
					TexprTools.mapExpr(function(x) return transformExpr(cancelTre, functionEnd, x), e);
			};
		}
		var body = transformExpr(false, true, fn.expr);
		if (addLoop) {
			var isVoid = switch (TypeFunctions.follow(fn.type)) {
				case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Void"): true;
				case _: false;
			};
			if (isVoid) {
				body = TypeFunctions.mk(TBlock([body, TypeFunctions.mk(TReturn(null), ctx.com.basic.tvoid, Position.nullPos)]),
					ctx.com.basic.tvoid, Position.nullPos);
			}
			body = wrapLoop(ctx, fnArgsVars(fn), body);
		}
		return new TFunc(fn.args, fn.type, body);
	}

	static function hasTailRecursion(isRecursiveCall:(callee:TExpr, args:Array<TExpr>)->Bool, cancelTre:Bool, functionEnd:Bool, e:TExpr):Bool {
		return switch (e.expr) {
			// Cancel tre inside of loop bodies
			case TFor(_, _, _) | TWhile(_, _, _):
				TexprTools.checkExpr(function(x) return hasTailRecursion(isRecursiveCall, true, false, x), e);
			// Cancel tre inside of try blocks
			case TTry(eTry, catches):
				if (hasTailRecursion(isRecursiveCall, true, functionEnd, eTry)) true
				else {
					var found = false;
					for (c in catches) if (!found) found = hasTailRecursion(isRecursiveCall, cancelTre, functionEnd, c.expr);
					found;
				}
			case TBinop(OpAssign, {expr: TLocal(v = {kind: VUser(TVOLocalFunction)})}, {expr: TFunction(fn)}):
				hasTailRecursion(function(callee, args) return isRecursiveNamedLocalCall(v, callee, args), false, true, fn.expr);
			// Anonymous function
			case TFunction(_):
				false;
			case TReturn(r):
				// Only a returned direct call matches; any other returned value falls to the catch-all,
				// descending into the value with functionEnd preserved (a trailing bare self-call in a
				// value switch branch is a tail call).
				r != null && switch (r.expr) {
					case TCall(callee, args): !cancelTre && isRecursiveCall(callee, args);
					case _: hasTailRecursion(isRecursiveCall, cancelTre, functionEnd, r);
				};
			case TBlock(exprs):
				var found = false;
				var i = 0;
				while (i < exprs.length && !found) {
					var cur = exprs[i];
					var isLast = i == exprs.length - 1;
					switch (cur.expr) {
						case TCall(callee, args) if (isLast && !cancelTre && functionEnd):
							found = isRecursiveCall(callee, args);
						case TCall(callee, args) if (i == exprs.length - 2 && exprs[i + 1].expr.match(TReturn(null)) && !cancelTre):
							found = isRecursiveCall(callee, args);
						case _:
							found = hasTailRecursion(isRecursiveCall, cancelTre, functionEnd && isLast, cur);
					}
					i++;
				}
				found;
			case _:
				TexprTools.checkExpr(function(x) return hasTailRecursion(isRecursiveCall, cancelTre, functionEnd, x), e);
		};
	}

	public static function run(ctx:TyperContext):TExpr->TExpr {
		if (ctx.com.defines.rawDefined("no_tre")) return function(e) return e;
		return function(e) {
			return switch (e.expr) {
				case TFunction(fn):
					var isTreEligible = switch (ctx.curfield.kind) {
						case Method(MethDynamic): false;
						case Method(MethInline): true;
						case Method(MethNormal): ctx.curclass.statics.exists(ctx.curfield.name);
						case _: TypeFunctions.hasClassFieldFlag(ctx.curfield, CfFinal);
					};
					function isRecursiveCall(callee:TExpr, args:Array<TExpr>):Bool {
						return isTreEligible && isRecursiveMethodCall(ctx.curfield, callee, args);
					}
					if (hasTailRecursion(isRecursiveCall, false, true, fn.expr)) {
						var fn2 = transformFunction(ctx, isRecursiveCall, fn);
						TypeFunctions.mk(TFunction(fn2), e.type, e.pos);
					} else e;
				case _: e;
			};
		};
	}
}
