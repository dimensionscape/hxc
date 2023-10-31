package hxc.optimization;

// hxc.optimization.AnalyzerFusion: the fusion state, Fusion, Cleanup and Purity; split from
// AnalyzerTexpr to keep classes at a manageable size.

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.context.Context;
import hxc.context.PurityState;
import hxc.optimization.OptimizerTexpr;
import hxc.optimization.AnalyzerTexpr;
import haxe.ds.IntMap;
import haxe.ds.StringMap;

private typedef Exit = hxc.core.ExitException;

// The @:semantics(name) meta on the type chain
class ExtTypeSemantics {
	static function hasSemantics(t:T, name:String):Bool {
		function check(meta:Metadata):Bool {
			for (m in meta) {
				if (m.name != ":semantics") continue;
				for (p in m.params) switch (p.expr) {
					case EConst(CIdent(v)) if (v == name): return true;
					case _:
				}
			}
			return false;
		}
		function loop(t:T):Bool {
			return switch (t) {
				case TInst(c, _): check(c.meta);
				case TEnum(en, _): check(en.meta);
				case TType(td, tl): check(td.meta) || loop(TypeFunctions.applyTypedef(td, tl));
				case TAbstract(a, _): check(a.meta);
				case TLazy(f): loop(TypeFunctions.lazyType(f));
				case TMono(r): r.type != null && loop(r.type);
				case _: false;
			};
		}
		return loop(t);
	}

	public static function hasVariableSemantics(t:T):Bool return hasSemantics(t, "variable");
	public static function hasReferenceSemantics(t:T):Bool return hasSemantics(t, "reference");
	public static function hasValueSemantics(t:T):Bool return hasSemantics(t, "value");
}

// Local read/write counts driving the fuse loop
class FusionState {
	var _changed:Bool = false;
	var varReads:IntMap<Int> = new IntMap();
	var varWrites:IntMap<Int> = new IntMap();

	public function new() {}

	function change(map:IntMap<Int>, v:TVar, delta:Int):Void {
		map.set(v.id, (map.exists(v.id) ? map.get(v.id) : 0) + delta);
	}

	public inline function incReads(v:TVar):Void change(varReads, v, 1);
	public inline function decReads(v:TVar):Void change(varReads, v, -1);
	public inline function incWrites(v:TVar):Void change(varWrites, v, 1);
	public inline function decWrites(v:TVar):Void change(varWrites, v, -1);

	public inline function getReads(v:TVar):Int return varReads.exists(v.id) ? varReads.get(v.id) : 0;
	public inline function getWrites(v:TVar):Int return varWrites.exists(v.id) ? varWrites.get(v.id) : 0;

	public inline function changeWrites(v:TVar, delta:Int):Void change(varWrites, v, delta);

	public inline function changed():Void _changed = true;
	public inline function reset():Void _changed = false;
	public inline function didChange():Bool return _changed;

	public function inferFromTexpr(e:TExpr):Void {
		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TLocal(v): incReads(v);
				case TBinop(OpAssign, {expr: TLocal(v)}, e2):
					incWrites(v);
					loop(e2);
				case _: TexprTools.iter(loop, e);
			}
		}
		loop(e);
	}
}

// Fusion: join expressions to normalize the output shape
class Fusion {
	static function isAssignOp(op:Binop):Bool {
		return switch (op) {
			case OpAdd | OpMult | OpDiv | OpSub | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr | OpMod: true;
			case _: false;
		};
	}

	static function useAssignOp(com:Context, op:Binop, e1:TExpr, e2:TExpr, e3:TExpr):Bool {
		var e1 = com.platform.match(Eval) ? TexprTools.skip(e1) : e1;
		var e2 = com.platform.match(Eval) ? TexprTools.skip(e2) : e2;
		return isAssignOp(op) && AnalyzerTexpr.targetHandlesAssignOps(com, e3)
			&& TexprTools.equal(e1, e2) && !OptimizerTexpr.hasSideEffect(e1);
	}

	static function isVoidT(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	public static function apply(actx:AnalyzerTypes.AnalyzerContext, e:TExpr):TExpr {
		var config = actx.config;
		var com = actx.com;
		var state = new FusionState();
		state.inferFromTexpr(e);

		// `el` is a reversed element list; the result
		// comes out in source order
		var blockElement:(Array<TExpr>, Array<TExpr>, Bool)->Array<TExpr> = null;
		blockElement = function(acc:Array<TExpr>, el:Array<TExpr>, loopBottom:Bool):Array<TExpr> {
			var i = 0;
			while (i < el.length) {
				var e1 = el[i];
				var rest = i + 1;
				inline function drop():Void {
					el = el.slice(rest);
					i = 0;
				}
				inline function keep():Void {
					acc.unshift(e1);
					el = el.slice(rest);
					i = 0;
				}
				inline function expand(extra:Array<TExpr>):Void {
					el = extra.concat(el.slice(rest));
					i = 0;
				}
				switch (e1.expr) {
					case TBinop(OpAssign, {expr: TLocal(v1)}, {expr: TLocal(v2)}) if (v1 == v2):
						drop();
					case TBinop(OpAssign | OpAssignOp(_), _, _) | TUnop(Increment | Decrement, _, _):
						keep();
					case TLocal(_) if (!config.localDce):
						keep();
					case TLocal(v):
						state.decReads(v);
						drop();
					case TField(_, fa) if (PurityState.isExplicitlyImpure(fa)):
						keep();
					// No side effect
					case TFunction(_) | TConst(_) | TTypeExpr(_):
						drop();
					case TMeta(m, _) if (m.name == ":pure" && PurityState.getPurityFromMeta([m]).match(Pure)):
						drop();
					case TCall({expr: TField(ef, fa)}, el1) if (PurityState.isPureFieldAccess(fa) && config.localDce):
						expand([ef].concat(el1));
					case TNew(c, _, el1) if (c.constructor != null && PurityState.isPure(c, c.constructor) && config.localDce):
						expand(el1);
					case TIf({expr: TConst(TBool(t))}, eThen, eElse):
						if (t) expand([eThen])
						else if (eElse == null) drop()
						else expand([eElse]);
					case TSwitch(e2, cases, def):
						var r = Optimizer.checkConstantSwitch(e2, cases, def);
						if (r != null) expand([r]) else keep();
					// No-side-effect composites
					case TParenthesis(x) | TMeta(_, x) | TCast(x, null) | TField(x, _) | TUnop(_, _, x) | TEnumIndex(x) | TEnumParameter(x, _, _):
						expand([x]);
					case TArray(x1, x2) | TBinop(_, x1, x2):
						expand([x1, x2]);
					case TArrayDecl(el1) | TCall({expr: TField(_, FEnum(_, _))}, el1):
						expand(el1);
					case TObjectDecl(fl):
						expand([for (f in fl) f.expr]);
					case TIf(x1, x2, null) if (!OptimizerTexpr.hasSideEffect(x2)):
						expand([x1]);
					case TIf(x1, x2, x3) if (x3 != null && !OptimizerTexpr.hasSideEffect(x2) && !OptimizerTexpr.hasSideEffect(x3)):
						expand([x1]);
					case TBlock([x1]):
						expand([x1]);
					case TBlock([]):
						drop();
					case TContinue if (loopBottom):
						acc = [];
						drop();
					case _:
						keep();
				}
			}
			return acc;
		}

		function canBeFused(v:TVar, e:TExpr):Bool {
			var numUses = state.getReads(v);
			var numWrites = state.getWrites(v);
			var usable = AnalyzerTexpr.canBeUsedAsValue(com, e);
			var isCompilerGenerated = switch (v.kind) {
				case VUser(_) | VInlined: false;
				case _: true;
			};
			var hasTypeParams = v.extra != null && v.extra.params.length > 0;
			function isImpureExtern(e:TExpr):Bool {
				return switch (e.expr) {
					case TField(_, FStatic(cl, cf) | FInstance(cl, _, cf)) if (TypeFunctions.hasClassFlag(cl, CExtern)):
						!(TypeFunctions.hasMeta(":coreApi", cl.meta) || PurityState.isPure(cl, cf));
					case _:
						TexprTools.checkExpr(isImpureExtern, e);
				};
			}
			var impureExtern = isImpureExtern(e);
			var hasVariableSemantics = ExtTypeSemantics.hasVariableSemantics(v.type);
			var isVariableExpression = switch (e.expr) {
				case TLocal({kind: VUser(_)}): false;
				case _: true;
			};
			return numUses <= 1 && numWrites == 0 && usable
				&& !(hasVariableSemantics && isVariableExpression)
				&& (isCompilerGenerated
					|| (config.optimize && config.fusion && config.userVarFusion && !hasTypeParams && !impureExtern));
		}

		// Forward substitution of `var v1 = e1`
		// into the following elements, guarded by the interference report
		function handleAssignedLocal(v1:TVar, e1:TExpr, el:Array<TExpr>):Null<Array<TExpr>> {
			var found = false;
			var blocked = false;
			var ir = InterferenceReport.fromTexpr(e1);
			var replace:TExpr->TExpr = null;
			function explore(e:TExpr):TExpr {
				var old = blocked;
				blocked = true;
				var e = replace(e);
				blocked = old;
				return e;
			}
			function handleElUnordered(el:Array<TExpr>):Array<TExpr> {
				// Undefined argument evaluation order: find interferences past a replacement
				var reallyFound = found;
				var out = [for (e in el) {
					found = false;
					var e = replace(e);
					if (found) reallyFound = true;
					e;
				}];
				found = reallyFound;
				return out;
			}
			function handleEl(el:Array<TExpr>):Array<TExpr> {
				return AnalyzerTexpr.targetHandlesSideEffectOrder(com) ? [for (e in el) replace(e)] : handleElUnordered(el);
			}
			function handleCall(e2:TExpr, el:Array<TExpr>):{e:TExpr, el:Array<TExpr>} {
				return switch (com.platform) {
					case Neko:
						var el = [for (e in el) replace(e)];
						{e: replace(e2), el: el};
					case Cpp:
						var e2 = replace(e2);
						{e: e2, el: handleEl(el)};
					case _:
						var e2 = replace(e2);
						{e: e2, el: [for (e in el) replace(e)]};
				};
			}
			replace = function(e:TExpr):TExpr {
				if (found) return e;
				inline function remk(x:TExprExpr):TExpr return TypeFunctions.mk(x, e.type, e.pos);
				return switch (e.expr) {
					case TWhile(_, _, _) | TTry(_, _):
						throw new Exit();
					case TFunction(_):
						e;
					case TIf(x1, x2, xo):
						var x1 = replace(x1);
						if (!found && (ir.hasStateWrite() || ir.hasAnyFieldWrite() || ir.hasAnyVarWrite())) throw new Exit();
						var x2 = replace(x2);
						var xo = xo == null ? null : replace(xo);
						remk(TIf(x1, x2, xo));
					case TSwitch(x1, cases, edef):
						var x1 = switch (com.platform) {
							case Lua | Python: explore(x1);
							case _: replace(x1);
						};
						if (!found) throw new Exit();
						remk(TSwitch(x1, cases, edef));
					// Locals
					case TLocal(v2) if (v1 == v2 && !blocked):
						found = true;
						AnalyzerTexpr.typeChangeOk(com, v1.type, e1.type) ? e1 : TypeFunctions.mk(TCast(e1, null), v1.type, e.pos);
					case TLocal(v):
						if (ir.hasVarWrite(v) || ((TypeFunctions.hasVarFlag(v, VCaptured) || ExtTypeSemantics.hasReferenceSemantics(v.type)) && ir.hasStateWrite())) throw new Exit();
						e;
					case TBinop(OpAssign, x1 = {expr: TLocal(v)}, x2):
						var x2 = replace(x2);
						if (!found && ir.hasVarRead(v)) throw new Exit();
						remk(TBinop(OpAssign, x1, x2));
					// Never fuse into write positions (issue #7298)
					case TBinop(OpAssignOp(_), {expr: TLocal(v2)}, _) if (v1 == v2): throw new Exit();
					case TUnop(Increment | Decrement, _, {expr: TLocal(v2)}) if (v1 == v2): throw new Exit();
					case TBinop(op = OpAssignOp(_), x1 = {expr: TLocal(v)}, x2):
						var x2 = replace(x2);
						if (!found && (ir.hasVarRead(v) || ir.hasVarWrite(v))) throw new Exit();
						remk(TBinop(op, x1, x2));
					case TUnop(Increment | Decrement, _, {expr: TLocal(v)}) if (ir.hasVarRead(v) || ir.hasVarWrite(v)):
						throw new Exit();
					case TField(x1, fa):
						var x1 = replace(x1);
						if (!found && !OptimizerTexpr.isReadOnlyFieldAccess(x1, fa) && (ir.hasFieldWrite(TypeFunctions.fieldName(fa)) || ir.hasStateWrite())) throw new Exit();
						remk(TField(x1, fa));
					case TBinop(OpAssign, ef = {expr: TField(x1, fa)}, x2):
						var x1 = replace(x1);
						var x2 = replace(x2);
						if (!found && (ir.hasFieldRead(TypeFunctions.fieldName(fa)) || ir.hasStateRead())) throw new Exit();
						remk(TBinop(OpAssign, TypeFunctions.mk(TField(x1, fa), ef.type, ef.pos), x2));
					case TBinop(op = OpAssignOp(_), ef = {expr: TField(x1, fa)}, x2):
						var x1 = replace(x1);
						var s = TypeFunctions.fieldName(fa);
						if (!found && (ir.hasFieldWrite(s) || ir.hasStateWrite())) throw new Exit();
						var x2 = replace(x2);
						if (!found && (ir.hasFieldRead(s) || ir.hasStateRead())) throw new Exit();
						remk(TBinop(op, TypeFunctions.mk(TField(x1, fa), ef.type, ef.pos), x2));
					case TUnop(Increment | Decrement, _, {expr: TField(_, fa)})
						if (ir.hasFieldRead(TypeFunctions.fieldName(fa)) || ir.hasStateRead()
							|| ir.hasFieldWrite(TypeFunctions.fieldName(fa)) || ir.hasStateWrite()):
						throw new Exit();
					// Array
					case TArray(x1, x2):
						var x1 = replace(x1);
						var x2 = replace(x2);
						if (!found && ir.hasStateWrite()) throw new Exit();
						remk(TArray(x1, x2));
					case TBinop(OpAssign, ef = {expr: TArray(x1, x2)}, x3):
						var x1 = replace(x1);
						var x2 = replace(x2);
						var x3 = replace(x3);
						if (!found && ir.hasStateRead()) throw new Exit();
						remk(TBinop(OpAssign, TypeFunctions.mk(TArray(x1, x2), ef.type, ef.pos), x3));
					case TBinop(op = OpAssignOp(_), ef = {expr: TArray(x1, x2)}, x3):
						var x1 = replace(x1);
						var x2 = replace(x2);
						if (!found && ir.hasStateWrite()) throw new Exit();
						var x3 = replace(x3);
						if (!found && ir.hasStateRead()) throw new Exit();
						remk(TBinop(op, TypeFunctions.mk(TArray(x1, x2), ef.type, ef.pos), x3));
					case TUnop(Increment | Decrement, _, {expr: TArray(_, _)}) if (ir.hasStateRead() || ir.hasStateWrite()):
						throw new Exit();
					case TCall({expr: TIdent(s)}, el2) if (!AnalyzerTexpr.isUnboundCallThatMightHaveSideEffects(s, el2)):
						e;
					case TNew(c, tl, el2) if (c.constructor != null && PurityState.isPure(c, c.constructor)):
						var el2 = handleEl(el2);
						if (!found && (ir.hasStateWrite() || ir.hasAnyFieldWrite())) throw new Exit();
						remk(TNew(c, tl, el2));
					case TNew(c, tl, el2):
						var el2 = handleEl(el2);
						if (!found && (ir.hasStateWrite() || ir.hasStateRead() || ir.hasAnyFieldRead() || ir.hasAnyFieldWrite())) throw new Exit();
						remk(TNew(c, tl, el2));
					case TCall(ef = {expr: TField(_, FEnum(_, _))}, el2):
						var el2 = handleEl(el2);
						remk(TCall(ef, el2));
					case TCall(ef = {expr: TField(_, fa)}, el2) if (PurityState.isPureFieldAccess(fa)):
						var r = handleCall(ef, el2);
						if (!found && (ir.hasStateWrite() || ir.hasAnyFieldWrite())) throw new Exit();
						remk(TCall(r.e, r.el));
					case TCall(x1, el2):
						var r = switch (x1.expr) {
							case TIdent(s) if (s != "`trace" && s != "__int__"): {e: x1, el: el2};
							case _: handleCall(x1, el2);
						};
						if (!found && (ir.hasStateRead() || ir.hasAnyFieldRead() || ir.hasStateWrite() || ir.hasAnyFieldWrite())) throw new Exit();
						remk(TCall(r.e, r.el));
					case TObjectDecl(fl):
						var el2 = handleEl([for (f in fl) f.expr]);
						if (!found && (ir.hasStateWrite() || ir.hasAnyFieldWrite())) throw new Exit();
						remk(TObjectDecl([for (i in 0...fl.length) {key: fl[i].key, expr: el2[i]}]));
					case TArrayDecl(el2):
						var el2 = handleEl(el2);
						remk(TArrayDecl(el2));
					case TBinop(op, x1, x2) if (com.platform.match(Cpp)):
						var x1 = replace(x1);
						var tempFound = found;
						found = false;
						var x2 = replace(x2);
						found = found || tempFound;
						remk(TBinop(op, x1, x2));
					case _:
						TexprTools.mapExpr(replace, e);
				};
			}
			return try {
				var out = el.copy();
				var idx = 0;
				while (idx < out.length) {
					out[idx] = replace(out[idx]);
					if (found) break;
					idx++;
				}
				if (!found) throw new Exit();
				state.changed();
				state.decReads(v1);
				out;
			} catch (_:Exit) null;
		}

		// Both input and output element lists are reversed relative to source order (block_element flips
		// them back)
		var fuse:(Array<TExpr>, Array<TExpr>)->Array<TExpr> = null;
		fuse = function(acc:Array<TExpr>, el:Array<TExpr>):Array<TExpr> {
			while (el.length > 0) {
				var e1 = el[0];
				var next = el.length > 1 ? el[1] : null;
				inline function keep():Void {
					acc.unshift(e1);
					el = el.slice(1);
				}
				switch (e1.expr) {
					case TVarExpr(v1, null) if (next != null && switch (next.expr) {
						case TBinop(OpAssign, {expr: TLocal(v2)}, _): v1 == v2;
						case _: false;
					}):
						switch (next.expr) {
							case TBinop(OpAssign, _, e2):
								state.changed();
								state.decWrites(v1);
								el = [TypeFunctions.mk(TVarExpr(v1, e2), e1.type, e1.pos)].concat(el.slice(2));
							case _: keep();
						}
					case TIf(_, _, eelse) if (eelse != null && AnalyzerTexpr.canBeUsedAsValue(com, e1) && !isVoidT(e1.type)
						&& !(com.platform.match(Cpp) && !com.defines.rawDefined("cppia"))):
						// Common-assignment branches collapse into one valued assignment
						var handled = try {
							var i = 0;
							var stored:Null<{e:TExpr, f:TExpr->TExpr}> = null;
							function checkAssign(e:TExpr):TExpr {
								return switch (e.expr) {
									case TBinop(OpAssign, x1, x2):
										i++;
										if (stored == null) {
											stored = {e: x1, f: function(e2) return TypeFunctions.mk(TBinop(OpAssign, x1, e2), e.type, e.pos)};
											x2;
										} else if (TexprTools.equal(stored.e, x1)) x2 else throw new Exit();
									case _: throw new Exit();
								};
							}
							var r = AnalyzerTexpr.mapValues(checkAssign, e1);
							if (stored == null) throw new Exit();
							switch (stored.e.expr) {
								case TLocal(v): state.changeWrites(v, -i + 1);
								case _:
							}
							var fused = stored.f(r.e);
							state.changed();
							el = [fused].concat(el.slice(1));
							true;
						} catch (_:Exit) false;
						if (!handled) keep();
					case TVarExpr(v1, einit) if (einit != null && config.optimize && config.localDce && state.getReads(v1) == 0 && state.getWrites(v1) == 0):
						el = [einit].concat(el.slice(1));
					case TVarExpr(v1, null) if (!TypeFunctions.hasVarFlag(v1, VCaptured)):
						// `var v;` merged with a later single deep assignment
						var found = false;
						var replace:(Bool, TExpr)->TExpr = null;
						replace = function(deep:Bool, e:TExpr):TExpr {
							return switch (e.expr) {
								case TBinop(OpAssign, {expr: TLocal(v2)}, e2) if (v1 == v2):
									if (deep) throw new Exit();
									found = true;
									TypeFunctions.mk(TVarExpr(v1, e2), e1.type, e1.pos);
								case TLocal(v2) if (v1 == v2): throw new Exit();
								case _: TexprTools.mapExpr(function(x) return replace(true, x), e);
							};
						}
						var handled = try {
							var rest = el.slice(1);
							var idx = 0;
							while (idx < rest.length) {
								rest[idx] = replace(false, rest[idx]);
								if (found) break;
								idx++;
							}
							if (!found) throw new Exit();
							state.changed();
							state.decWrites(v1);
							el = rest;
							true;
						} catch (_:Exit) false;
						if (!handled) keep();
					case TVarExpr(v1, einit) if (einit != null && canBeFused(v1, einit)):
						var handled = false;
						if (next != null) switch (next.expr) {
							case TUnop(op = Increment | Decrement, Prefix, {expr: TLocal(v2)}) if (v1 == v2):
								var found = false;
								var replace:TExpr->TExpr = null;
								replace = function(e:TExpr):TExpr {
									return switch (e.expr) {
										case TLocal(v3) if (v1 == v3):
											if (found) throw new Exit();
											found = true;
											TypeFunctions.mk(TUnop(op, Postfix, e), e.type, e.pos);
										case TIf(_, _, _) | TSwitch(_, _, _) | TTry(_, _) | TWhile(_, _, _) | TFor(_, _, _):
											throw new Exit();
										case _:
											TexprTools.mapExpr(replace, e);
									};
								}
								try {
									var ev = replace(e1);
									if (!found) throw new Exit();
									state.changed();
									el = [ev].concat(el.slice(2));
									handled = true;
								} catch (_:Exit) {}
							case _:
						}
						if (!handled) {
							var r = handleAssignedLocal(v1, einit, el.slice(1));
							if (r != null) el = r else keep();
						}
					case TUnop(op = Increment | Decrement, Prefix, ev = {expr: TLocal(v)}) if (next != null):
						// Restore prefix/postfix forms into a following return or var init
						var handled = try {
							var e2full = next;
							var r:{e:TExpr, f:TExpr->TExpr} = switch (e2full.expr) {
								case TReturn(x2) if (x2 != null): {e: x2, f: function(e) return TypeFunctions.mk(TReturn(e), e2full.type, e2full.pos)};
								case TVarExpr(v2, x2) if (x2 != null): {e: x2, f: function(e) return TypeFunctions.mk(TVarExpr(v2, e), e2full.type, e2full.pos)};
								case _: throw new Exit();
							};
							inline function opsMatch(op1:Unop, op2:Binop):Bool
								return (op1.match(Increment) && op2.match(OpSub)) || (op1.match(Decrement) && op2.match(OpAdd));
							switch (r.e.expr) {
								case TBinop(op2, {expr: TLocal(v2)}, {expr: TConst(TInt(one))}) if (v == v2 && one == 1 && opsMatch(op, op2)):
									state.changed();
									state.decReads(v2);
									acc.unshift(r.f(TypeFunctions.mk(TUnop(op, Postfix, ev), e1.type, e1.pos)));
									el = el.slice(2);
									true;
								case TLocal(v2) if (v == v2):
									state.changed();
									state.decReads(v2);
									acc.unshift(r.f(TypeFunctions.mk(TUnop(op, Prefix, ev), e1.type, e1.pos)));
									el = el.slice(2);
									true;
								case _:
									throw new Exit();
							}
						} catch (_:Exit) false;
						if (!handled) keep();
					case TBinop(OpAssign, x1, {expr: TBinop(op, x2, x3)}) if (useAssignOp(com, op, x1, x2, x3)):
						function decr(e:TExpr):Void {
							switch (e.expr) {
								case TLocal(v): state.decReads(v);
								case _: TexprTools.iter(decr, e);
							}
						}
						decr(x1);
						state.changed();
						el = [TypeFunctions.mk(TBinop(OpAssignOp(op), x1, x3), e1.type, e1.pos)].concat(el.slice(1));
					case TBinop(OpAssignOp(_), x1, _) if (next != null && switch (next.expr) {
						case TVarExpr(_, x2): x2 != null && TexprTools.equal(x1, x2);
						case _: false;
					}):
						switch (next.expr) {
							case TVarExpr(v, _):
								state.changed();
								acc.unshift(TypeFunctions.mk(TVarExpr(v, e1), next.type, next.pos));
								el = el.slice(2);
							case _: keep();
						}
					case _:
						keep();
				}
			}
			return acc;
		}

		var loop:TExpr->TExpr = null;
		function block(loopBody:Bool, el:Array<TExpr>, t:T, p:Position):TExpr {
			var rel = [for (x in el) loop(x)];
			rel.reverse();
			var el2 = blockElement([], rel, loopBody);
			// Fuse flips element order; blockElement flips it back
			el2 = fuse([], el2);
			el2 = blockElement([], el2, false);
			while (true) {
				state.reset();
				el2 = fuse([], el2);
				el2 = blockElement([], el2, false);
				if (!state.didChange()) break;
			}
			return TypeFunctions.mk(TBlock(el2), t, p);
		}
		loop = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TWhile(condition, {expr: TBlock(el), type: t, pos: p}, flag):
					var condition = loop(condition);
					var body = block(true, el, t, p);
					TypeFunctions.mk(TWhile(condition, body, flag), e.type, e.pos);
				case TBlock(el):
					block(false, el, e.type, e.pos);
				case TCall({expr: TIdent(s)}, _) if (AnalyzerTexpr.isReallyUnbound(s)):
					e;
				case _:
					TexprTools.mapExpr(loop, e);
			};
		}
		return loop(e);
	}
}

// Cleanup: restore surface forms after analysis
class Cleanup {
	public static function apply(com:Context, e:TExpr):TExpr {
		function ifOrOp(e:TExpr, e1:TExpr, e2:TExpr, e3:TExpr):TExpr {
			return switch [TexprTools.skip(e1).expr, TexprTools.skip(e3).expr] {
				case [TUnop(Not, Prefix, e1x), TConst(TBool(true))]:
					OptimizerTexpr.optimizeBinop(TypeFunctions.mk(TBinop(OpBoolOr, e1x, e2), e.type, e.pos), OpBoolOr, e1x, e2);
				case [_, TConst(TBool(false))]:
					OptimizerTexpr.optimizeBinop(TypeFunctions.mk(TBinop(OpBoolAnd, e1, e2), e.type, e.pos), OpBoolAnd, e1, e2);
				case [_, TBlock([])]:
					TypeFunctions.mk(TIf(e1, e2, null), e.type, e.pos);
				case _:
					switch (TexprTools.skip(e2).expr) {
						case TBlock([]):
							var e1x = TypeFunctions.mk(TUnop(Not, Prefix, e1), e1.type, e1.pos);
							e1x = OptimizerTexpr.optimizeUnop(e1x, Not, Prefix, e1);
							TypeFunctions.mk(TIf(e1x, e3, null), e.type, e.pos);
						case _:
							TypeFunctions.mk(TIf(e1, e2, e3), e.type, e.pos);
					}
			};
		}
		var loop:TExpr->TExpr = null;
		loop = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TIf(e1, e2, e3) if (e3 != null):
					ifOrOp(e, loop(e1), loop(e2), loop(e3));
				case TUnop(Increment | Decrement, _, e1) if (TexprTools.skip(e1).expr.match(TConst(_))):
					loop(e1);
				case TCall({expr: TIdent(s)}, _) if (AnalyzerTexpr.isReallyUnbound(s)):
					e;
				case TBlock(el):
					var el = [for (x in el) {
						var x = loop(x);
						x.expr.match(TIf(_, _, _)) ? TypeFunctions.mk(x.expr, com.basic.tvoid, x.pos) : x;
					}];
					TypeFunctions.mk(TBlock(el), e.type, e.pos);
				case TWhile(e1, e2, NormalWhile):
					var e1 = loop(e1);
					var e2 = loop(e2);
					cleanupWhile(com, e, e1, e2);
				case TField(e1, FAnon({name: s}) | FDynamic(s)):
					var e1 = loop(e1);
					var fa = TypeFunctions.quickFieldDynamic(e1.type, s);
					TypeFunctions.mk(TField(e1, fa), e.type, e.pos);
				case TField({expr: TTypeExpr(_)}, _):
					e;
				case TTypeExpr(TClassDecl(_)):
					e;
				case TMeta(m, e1) if (m.name == ":ast" && !e1.expr.match(TSwitch(_, _, _))):
					loop(e1);
				case _:
					TexprTools.mapExpr(loop, e);
			};
		}
		return loop(e);
	}

	static function cleanupWhile(com:Context, e:TExpr, e1:TExpr, e2:TExpr):TExpr {
		function hasContinue(x:TExpr):Bool {
			return switch (x.expr) {
				case TContinue: true;
				case _: TexprTools.checkExpr(hasContinue, x);
			};
		}
		var hasCont = hasContinue(e2);
		function isTrue(x:TExpr):Bool {
			return switch (x.expr) {
				case TConst(TBool(true)): true;
				case TParenthesis(x1): isTrue(x1);
				case _: false;
			};
		}
		return switch (e2.expr) {
			case TBlock(el) if (el.length > 0 && switch (el[0].expr) {
				case TIf(_, {expr: TBlock([{expr: TBreak}])}, null): true;
				case _: false;
			}):
				switch (el[0].expr) {
					case TIf(ec, eb, null):
						var ec2 = TexprTools.skip(ec);
						ec2 = switch (ec2.expr) {
							case TUnop(_, _, x): x;
							case _: TypeFunctions.mk(TUnop(Not, Prefix, ec2), ec2.type, ec2.pos);
						};
						TypeFunctions.mk(TWhile(ec2, TypeFunctions.mk(TBlock(el.slice(1)), eb.type, eb.pos), NormalWhile), e.type, e.pos);
					case _: e;
				}
			case TBlock(el):
				var doWhile:Null<TExpr> = null;
				var locals = new IntMap<Bool>();
				function collectVars(x:TExpr):Void {
					switch (x.expr) {
						case TVarExpr(v, x1):
							locals.set(v.id, true);
							if (x1 != null) collectVars(x1);
						case _: TexprTools.iter(collectVars, x);
					}
				}
				function referencesLocal(x:TExpr):Bool {
					return switch (x.expr) {
						case TLocal(v) if (locals.exists(v.id)): true;
						case _: TexprTools.checkExpr(referencesLocal, x);
					};
				}
				function walk(el:Array<TExpr>):Array<TExpr> {
					if (el.length == 1) switch (el[0].expr) {
						case TBreak if (isTrue(e1) && !hasCont):
							doWhile = TypeFunctions.mk(TConst(TBool(true)), com.basic.tbool, e1.pos);
							return [];
						case TIf(econd, {expr: TBlock([{expr: TBreak}])}, null) if (isTrue(e1) && !referencesLocal(econd) && !hasCont):
							doWhile = econd;
							return [];
						case _:
					}
					if (el.length == 0) return [];
					return switch (el[0].expr) {
						case TBreak | TContinue | TReturn(_) | TThrow(_):
							[el[0]];
						case _:
							collectVars(el[0]);
							[el[0]].concat(walk(el.slice(1)));
					};
				}
				var el2 = walk(el);
				if (doWhile == null)
					TypeFunctions.mk(TWhile(e1, TypeFunctions.mk(TBlock(el2), e2.type, e2.pos), NormalWhile), e.type, e.pos)
				else {
					var econd = TypeFunctions.mk(TUnop(Not, Prefix, doWhile), doWhile.type, doWhile.pos);
					TypeFunctions.mk(TWhile(econd, TypeFunctions.mk(TBlock(el2), e2.type, e2.pos), DoWhile), e.type, e.pos);
				}
			case _:
				TypeFunctions.mk(TWhile(e1, e2, NormalWhile), e.type, e.pos);
		};
	}
}

// Purity: infer @:pure(inferredPure) marks across the call graph
class PurityNode {
	public var ownerClass:TClass;
	public var field:TClassField;
	public var purity:Purity;
	public var dependents:Array<PurityNode>;

	public function new(c:TClass, cf:TClassField) {
		this.ownerClass = c;
		this.field = cf;
		this.purity = PurityState.getPurity(c, cf);
		this.dependents = [];
	}
}

private class PurityConflict extends haxe.Exception {
	public var node:PurityNode;
	public var pos:Position;

	public function new(node:PurityNode, pos:Position) {
		super("purity-conflict");
		this.node = node;
		this.pos = pos;
	}
}

class PurityInference {
	static var nodeLut:StringMap<PurityNode> = new StringMap();

	static function getFieldId(c:TClass, cf:TClassField):String {
		return Context.sTypePath(c.path) + "." + cf.name;
	}

	static function getNode(c:TClass, cf:TClassField):PurityNode {
		var id = getFieldId(c, cf);
		var n = nodeLut.get(id);
		if (n == null) {
			n = new PurityNode(c, cf);
			nodeLut.set(id, n);
		}
		return n;
	}

	static function taint(node:PurityNode):Void {
		switch (node.purity) {
			case Impure:
			case ExpectPure(p): throw new PurityConflict(node, p);
			case MaybePure | Pure | InferredPure:
				node.purity = Impure;
				for (d in node.dependents) taint(d);
				var c = node.ownerClass;
				while (c.superClass != null) {
					c = c.superClass.c;
					var cf = c.fields.get(node.field.name);
					if (cf != null) taint(getNode(c, cf));
				}
		}
	}

	static function taintRaise(node:PurityNode):Void {
		taint(node);
		throw new Exit();
	}

	static function applyToField(com:Context, isCtor:Bool, isStatic:Bool, c:TClass, cf:TClassField):Void {
		var node = getNode(c, cf);
		function checkField(c2:TClass, cf2:TClassField):Void {
			var node2 = getNode(c2, cf2);
			switch (node2.purity) {
				case Pure | InferredPure | ExpectPure(_):
				case Impure: taintRaise(node);
				case MaybePure: node2.dependents.unshift(node);
			}
		}
		function checkWrite(e1:TExpr):Void {
			switch (e1.expr) {
				case TLocal(v):
					// A reference-semantics local write is impure; plain locals are fine
					if (ExtTypeSemantics.hasReferenceSemantics(v.type)) taintRaise(node);
				case TField({expr: TConst(TThis)}, _) if (isCtor):
					// A constructor may write its own fields
				case _:
					taintRaise(node);
			}
		}
		var loop:TExpr->Void = null;
		loop = function(e:TExpr):Void {
			switch (e.expr) {
				case TMeta(m, _) if (m.name == ":pure"):
					if (PurityState.getPurityFromMeta([m]).match(Impure)) taintRaise(node);
				case TThrow(_):
					taintRaise(node);
				case TBinop(OpAssign | OpAssignOp(_), e1, e2):
					checkWrite(e1);
					loop(e2);
				case TUnop(Increment | Decrement, _, e1):
					checkWrite(e1);
				case TCall({expr: TField(_, FStatic(c2, cf2))}, el):
					for (x in el) loop(x);
					checkField(c2, cf2);
				case TNew(c2, _, el):
					for (x in el) loop(x);
					if (c2.constructor != null) checkField(c2, c2.constructor)
					else taintRaise(node);
				case TCall({expr: TConst(TSuper)}, el):
					if (c.superClass != null && c.superClass.c.constructor != null) {
						checkField(c.superClass.c, c.superClass.c.constructor);
						for (x in el) loop(x);
					} else taintRaise(node);
				case TCall({expr: TIdent(s)}, el) if (!AnalyzerTexpr.isUnboundCallThatMightHaveSideEffects(s, el)):
					for (x in el) loop(x);
				case TCall(_, _):
					taintRaise(node);
				case _:
					TexprTools.iter(loop, e);
			}
		}
		switch (cf.kind) {
			case Method(MethDynamic) | Var(_):
				taint(node);
			case Method(MethNormal) if (!(isStatic || isCtor || TypeFunctions.hasClassFieldFlag(cf, CfFinal))):
				taint(node);
			case _:
				if (cf.expr == null) {
					if (!PurityState.isPure(c, cf)) taint(node);
				} else if (TypeFunctions.hasClassFieldFlag(cf, CfExtern) || TypeFunctions.hasMeta(":functionCode", cf.meta)
					|| TypeFunctions.hasMeta(":hlNative", cf.meta) || TypeFunctions.hasMeta(":hlNative", c.meta)) {
					if (!PurityState.isPure(c, cf)) taint(node);
				} else {
					try {
						switch (node.purity) {
							case Impure: taintRaise(node);
							case Pure: throw new Exit();
							case _: loop(cf.expr);
						}
					} catch (_:Exit) {}
				}
		}
	}

	static function applyToClass(com:Context, c:TClass):Void {
		for (cf in c.orderedFields) applyToField(com, false, false, c, cf);
		for (cf in c.orderedStatics) applyToField(com, false, true, c, cf);
		if (c.constructor != null) applyToField(com, true, false, c, c.constructor);
	}

	public static function infer(com:Context):Void {
		nodeLut = new StringMap();
		for (mt in com.types) switch (mt) {
			case TClassDecl(c):
				try applyToClass(com, c) catch (conflict:PurityConflict) {
					com.addDiagnostic("Impure field overrides/implements field which was explicitly marked as @:pure", conflict.node.field.pos);
					com.addDiagnostic("Pure field is here", conflict.pos, 1);
				}
			case _:
		}
		for (id in nodeLut.keys()) {
			var node = nodeLut.get(id);
			switch (node.purity) {
				case Pure | MaybePure if (!TypeFunctions.hasMeta(":pure", node.field.meta)):
					node.field.meta = ([{name: ":pure", params: [new Expr(EConst(CIdent("inferredPure")), node.field.pos)], pos: node.field.pos}] : Metadata).concat(node.field.meta);
				case _:
			}
		}
	}
}
