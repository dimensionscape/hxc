package hxc.optimization;

// hxc.optimization.AnalyzerTexpr: helpers, TexprFilter and InterferenceReport; Fusion/Cleanup/Purity
// follow.

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.context.Context;
import hxc.context.PurityState;
import hxc.optimization.OptimizerTexpr;
import haxe.ds.IntMap;
import haxe.ds.StringMap;

private class Exit extends haxe.Exception {
	public function new() super("exit");
}

class AnalyzerTexpr {
	// Apply f to each value-position leaf of a branching expression; returns the rewritten expression and
	// the extracted single value if the expression was not branching.
	public static function mapValues(f:TExpr->TExpr, e:TExpr, allowControlFlow:Bool = true):{e:TExpr, efinal:Null<TExpr>} {
		var branching = false;
		var efinal:Null<TExpr> = null;
		function f2(e:TExpr):TExpr {
			if (branching) return f(e);
			efinal = e;
			return TypeFunctions.mk(TConst(TNull), e.type, e.pos);
		}
		var loop:(Bool, TExpr)->TExpr = null;
		loop = function(complex:Bool, e:TExpr):TExpr {
			return switch (e.expr) {
				case TIf(e1, e2, e3) if (e3 != null):
					branching = true;
					var e2 = loop(true, e2);
					var e3 = loop(true, e3);
					TypeFunctions.mk(TIf(e1, e2, e3), e.type, e.pos);
				case TSwitch(e1, cases, edef):
					branching = true;
					var cases = [for (c in cases) {values: c.values, expr: loop(true, c.expr)}];
					var edef = edef == null ? null : loop(true, edef);
					TypeFunctions.mk(TSwitch(e1, cases, edef), e.type, e.pos);
				case TBlock([e1]):
					loop(complex, e1);
				case TBlock(el):
					if (el.length == 0) f2(e)
					else {
						var last = loop(true, el[el.length - 1]);
						var e2 = TypeFunctions.mk(TBlock(el.slice(0, el.length - 1).concat([last])), e.type, e.pos);
						TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: e.pos}, e2), e.type, e.pos);
					}
				case TTry(e1, catches):
					branching = true;
					var e1 = loop(true, e1);
					var catches = [for (c in catches) {v: c.v, expr: loop(true, c.expr)}];
					TypeFunctions.mk(TTry(e1, catches), e.type, e.pos);
				case TMeta(m, e1):
					TypeFunctions.mk(TMeta(m, loop(complex, e1)), e.type, e.pos);
				case TParenthesis(e1):
					TypeFunctions.mk(TParenthesis(loop(complex, e1)), e.type, e.pos);
				case TBreak | TContinue | TThrow(_) | TReturn(_):
					if (!allowControlFlow) throw new Exit();
					e;
				case _:
					if (!complex) throw new Exit();
					f2(e);
			};
		}
		var e = loop(false, e);
		return {e: e, efinal: efinal};
	}

	public static function canThrow(e:TExpr):Bool {
		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TBlock(_):
				case TCall(_, _) | TNew(_, _, _) | TThrow(_): throw new Exit();
				case TCast(_, mt) if (mt != null): throw new Exit();
				case TField(_, _) | TArray(_, _): throw new Exit(); // Sigh
				case _: TexprTools.iter(loop, e);
			}
		}
		return try {
			loop(e);
			false;
		} catch (_:Exit) true;
	}

	public static function canBeInlined(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(_): true;
			case TParenthesis(e1) | TMeta(_, e1): canBeInlined(e1);
			case _: false;
		};
	}

	// Js handles unops and assign-ops natively
	public static function targetHandlesUnops(com:Context):Bool {
		return switch (com.platform) {
			case Lua | Python: false;
			case _: true;
		};
	}

	public static function targetHandlesAssignOps(com:Context, e2:TExpr):Bool {
		return switch (com.platform) {
			case Php: !OptimizerTexpr.hasSideEffect(e2);
			case Lua: false;
			case Cpp if (!com.defines.rawDefined("cppia")): false;
			case _: true;
		};
	}

	public static function targetHandlesSideEffectOrder(com:Context):Bool {
		return switch (com.platform) {
			case Cpp: com.defines.rawDefined("cppia");
			case Php: false;
			case _: true;
		};
	}

	public static function canBeUsedAsValue(com:Context, e:TExpr):Bool {
		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TBlock([e1]): loop(e1);
				case TBlock(_) | TSwitch(_, _, _) | TTry(_, _): throw new Exit();
				case TCall({expr: TConst(TString("phi"))}, _): throw new Exit();
				case TReturn(_) | TThrow(_) | TBreak | TContinue: throw new Exit();
				case TUnop(Increment | Decrement, _, _) if (!targetHandlesUnops(com)): throw new Exit();
				case TFunction(_):
				case _: TexprTools.iter(loop, e);
			}
		}
		return try {
			switch [com.platform, e.expr] {
				case [Cs | Cpp | Java | Flash | Lua, TConst(TNull)]: throw new Exit();
				case _:
			}
			loop(e);
			true;
		} catch (_:Exit) false;
	}

	public static function wrapMeta(s:String, e:TExpr):TExpr {
		return TypeFunctions.mk(TMeta({name: s, params: [], pos: e.pos}, e), e.type, e.pos);
	}

	public static function isReallyUnbound(s:String):Bool {
		return switch (s) {
			case "`trace" | "__int__": false;
			case _: true;
		};
	}

	// A plain identifier __js__ constant has no side effects
	public static function isUnboundCallThatMightHaveSideEffects(s:String, el:Array<TExpr>):Bool {
		return switch [s, el] {
			case ["__js__", [{expr: TConst(TString(code))}]]:
				var ok = code.length > 0;
				for (i in 0...code.length) {
					var c = code.charCodeAt(i);
					if (!((c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code)
						|| (c >= "0".code && c <= "9".code) || c == "_".code)) {
						ok = false;
						break;
					}
				}
				!ok;
			case _: true;
		};
	}

	public static function typeChangeOk(com:Context, t1:T, t2:T):Bool {
		if (t1 == t2) return true;
		function mapT(t:T):T {
			return switch (t) {
				case TMono(r): r.type == null ? TypeFunctions.tDynamic : mapT(r.type);
				case _: TypeFunctions.map(mapT, t);
			};
		}
		var t1 = mapT(t1);
		var t2 = mapT(t2);
		function isNullableOrWhatever(t:T):Bool {
			return switch (t) {
				case TMono(r): r.type != null && isNullableOrWhatever(r.type);
				case TAbstract(a, [_]) if (a.path.pack.length == 0 && a.path.name == "Null"): true;
				case TLazy(f): isNullableOrWhatever(TypeFunctions.lazyType(f));
				case TType(td, tl): isNullableOrWhatever(TypeFunctions.applyTypedef(td, tl));
				case TFun(_): false;
				case TInst(c, _) if (c.kind.match(KTypeParameter(_))): false;
				case TAbstract(a, _) if (TypeFunctions.hasMeta(":coreType", a.meta)):
					!TypeFunctions.hasMeta(":notNull", a.meta);
				case TAbstract(a, tl):
					!TypeFunctions.hasMeta(":notNull", a.meta) && isNullableOrWhatever(TypeFunctions.applyParams(a.params, tl, a.thisType));
				case _: true;
			};
		}
		if (t1 == t2) return true;
		return switch [TypeFunctions.follow(t1), TypeFunctions.follow(t2)] {
			case [TDynamic(_), _] | [_, TDynamic(_)]: false;
			case _:
				if (com.platformConfig.isStatic && isNullableOrWhatever(t1) != isNullableOrWhatever(t2)) false
				else hxc.core.TypeUnification.typeIseqDefault(t1, t2);
		};
	}
}

// TexprFilter: normalize control flow before graph construction.
// Removed forms after apply: OpBoolAnd/OpBoolOr (to TIf), OpAssignOp on locals (to OpAssign), prefix and
// postfix increment/decrement, do-while and conditional while (to while(true) with a break), TFor (to
// TWhile).
class TexprFilter {
	public static function apply(com:Context, e:TExpr):TExpr {
		var loop:TExpr->TExpr = null;
		loop = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TBinop(op = OpBoolAnd | OpBoolOr, e1, e2):
					var eThen = e2;
					var eIf:TExpr, eElse:TExpr;
					if (op.match(OpBoolOr)) {
						eIf = TypeFunctions.mk(TUnop(Not, Prefix, e1), com.basic.tbool, e.pos);
						eElse = TypeFunctions.mk(TConst(TBool(true)), com.basic.tbool, e.pos);
					} else {
						eIf = e1;
						eElse = TypeFunctions.mk(TConst(TBool(false)), com.basic.tbool, e.pos);
					}
					loop(TypeFunctions.mk(TIf(eIf, eThen, eElse), e.type, e.pos));
				case TBinop(OpAssignOp(op), e1 = {expr: TLocal(_)}, e2):
					var eop = TypeFunctions.mk(TBinop(op, e1, e2), e.type, e.pos);
					loop(TypeFunctions.mk(TBinop(OpAssign, e1, eop), e.type, e.pos));
				case TUnop(op = Increment | Decrement, flag, e1 = {expr: TLocal(_)}):
					var eOne = TypeFunctions.mk(TConst(TInt(1)), com.basic.tint, e1.pos);
					var assignOp:Binop = OpAssignOp(op.match(Increment) ? OpAdd : OpSub);
					var easgn = TypeFunctions.mk(TBinop(assignOp, e1, eOne), e.type, e.pos);
					var e2 = if (flag.match(Prefix)) easgn else {
						TypeFunctions.mk(TBlock([
							TypeFunctions.mk(TBinop(assignOp, e1, eOne), e.type, e.pos),
							TypeFunctions.mk(TBinop(op.match(Increment) ? OpSub : OpAdd, e1, eOne), e.type, e.pos)
						]), e.type, e.pos);
					}
					loop(e2);
				case TWhile(e1, e2, DoWhile) if (isTrueExpr(e1)):
					loop(TypeFunctions.mk(TWhile(e1, e2, NormalWhile), e.type, e.pos));
				case TWhile(e1, e2, flag) if (!isTrueExpr(e1)):
					var p = e.pos;
					var eBreak = TypeFunctions.mk(TBreak, TypeFunctions.tDynamic, p);
					var eNot = TypeFunctions.mk(TUnop(Not, Prefix, TexprTools.mkParent(e1)), e1.type, e1.pos);
					function eIf(eo:Null<TExpr>):TExpr return TypeFunctions.mk(TIf(eNot, eBreak, eo), com.basic.tvoid, p);
					function mapContinue(e:TExpr):TExpr {
						return switch (e.expr) {
							case TContinue:
								TexprTools.duplicateTvars(function(x) return x, eIf(e));
							case TWhile(_, _, _) | TFor(_, _, _):
								e;
							case _:
								TexprTools.mapExpr(mapContinue, e);
						};
					}
					var e2 = flag.match(NormalWhile) ? e2 : mapContinue(e2);
					var eIf0 = eIf(null);
					var eBlock = flag.match(NormalWhile) ? TypeFunctions.concat(eIf0, e2) : TypeFunctions.concat(e2, eIf0);
					var eTrue = TypeFunctions.mk(TConst(TBool(true)), com.basic.tbool, p);
					loop(TypeFunctions.mk(TWhile(TexprTools.mkParent(eTrue), eBlock, NormalWhile), e.type, p));
				case TFor(v, e1, e2):
					loop(forRemap(com.basic, v, e1, e2, e.pos));
				case _:
					TexprTools.mapExpr(loop, e);
			};
		}
		return loop(e);
	}

	static function isTrueExpr(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(TBool(true)): true;
			case TParenthesis(e1): isTrueExpr(e1);
			case _: false;
		};
	}

	// For-in over an iterator becomes a hasNext/next while
	public static function forRemap(basic:BasicTypes, v:TVar, e1:TExpr, e2:TExpr, p:Position):TExpr {
		var v2 = TypeFunctions.allocVar(v.kind, v.name, e1.type, e1.pos);
		var ev2 = TypeFunctions.mk(TLocal(v2), e1.type, e1.pos);
		var t1 = TypeFunctions.followWithAbstracts(e1.type);
		var hasNextFa = try TypeFunctions.quickField(t1, "hasNext") catch (_:hxc.core.NotFound)
			throw new TypingError(hxc.core.TPrinting.sTypeStr(t1) + "has no field hasNext()", p);
		var eHasNext = TypeFunctions.mk(TField(ev2, hasNextFa), TypeFunctions.tfun([], basic.tbool), e1.pos);
		eHasNext = TypeFunctions.mk(TCall(eHasNext, []), basic.tbool, eHasNext.pos);
		var nextFa = try TypeFunctions.quickField(t1, "next") catch (_:hxc.core.NotFound)
			throw new TypingError(hxc.core.TPrinting.sTypeStr(t1) + "has no field next()", p);
		var eNext = TypeFunctions.mk(TField(ev2, nextFa), TypeFunctions.tfun([], v.type), e1.pos);
		eNext = TypeFunctions.mk(TCall(eNext, []), v.type, e1.pos);
		var eAssign = TypeFunctions.mk(TVarExpr(v, eNext), basic.tvoid, p);
		var eBody = TypeFunctions.concat(eAssign, e2);
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(v2, e1), basic.tvoid, e1.pos),
			TypeFunctions.mk(TWhile(TypeFunctions.mk(TParenthesis(eHasNext), eHasNext.type, eHasNext.pos), eBody, NormalWhile), basic.tvoid, e1.pos)
		]), basic.tvoid, p);
	}
}

// InterferenceReport: how code influences and is influenced by state
class InterferenceReport {
	public var varReads:IntMap<Bool>;
	public var varWrites:IntMap<Bool>;
	public var fieldReads:StringMap<Bool>;
	public var fieldWrites:StringMap<Bool>;
	public var stateRead:Bool;
	public var stateWrite:Bool;

	public function new() {
		varReads = new IntMap();
		varWrites = new IntMap();
		fieldReads = new StringMap();
		fieldWrites = new StringMap();
		stateRead = false;
		stateWrite = false;
	}

	public inline function setVarRead(v:TVar):Void varReads.set(v.id, true);
	public inline function setVarWrite(v:TVar):Void varWrites.set(v.id, true);
	public inline function setFieldRead(s:String):Void fieldReads.set(s, true);
	public inline function setFieldWrite(s:String):Void fieldWrites.set(s, true);
	public inline function setStateRead():Void stateRead = true;
	public inline function setStateWrite():Void stateWrite = true;

	public inline function hasVarRead(v:TVar):Bool return varReads.exists(v.id);
	public inline function hasVarWrite(v:TVar):Bool return varWrites.exists(v.id);
	public inline function hasFieldRead(s:String):Bool return fieldReads.exists(s);
	public inline function hasFieldWrite(s:String):Bool return fieldWrites.exists(s);
	public inline function hasStateRead():Bool return stateRead;
	public inline function hasStateWrite():Bool return stateWrite;
	public inline function hasAnyFieldRead():Bool return fieldReads.keys().hasNext();
	public inline function hasAnyFieldWrite():Bool return fieldWrites.keys().hasNext();
	public inline function hasAnyVarRead():Bool return varReads.keys().hasNext();
	public inline function hasAnyVarWrite():Bool return varWrites.keys().hasNext();

	public static function fromTexpr(e:TExpr):InterferenceReport {
		var ir = new InterferenceReport();
		function loop(e:TExpr):Void {
			switch (e.expr) {
				// Vars
				case TLocal(v):
					ir.setVarRead(v);
					if (TypeFunctions.hasVarFlag(v, VCaptured)) ir.setStateRead();
				case TBinop(OpAssign, {expr: TLocal(v)}, e2):
					ir.setVarWrite(v);
					if (TypeFunctions.hasVarFlag(v, VCaptured)) ir.setStateWrite();
					loop(e2);
				case TBinop(OpAssignOp(_), {expr: TLocal(v)}, e2):
					ir.setVarRead(v);
					ir.setVarWrite(v);
					if (TypeFunctions.hasVarFlag(v, VCaptured)) {
						ir.setStateRead();
						ir.setStateWrite();
					}
					loop(e2);
				case TUnop(Increment | Decrement, _, {expr: TLocal(v)}):
					ir.setVarRead(v);
					ir.setVarWrite(v);
				case TField(e1, fa):
					loop(e1);
					if (!OptimizerTexpr.isReadOnlyFieldAccess(e1, fa)) ir.setFieldRead(TypeFunctions.fieldName(fa));
				case TBinop(OpAssign, {expr: TField(e1, fa)}, e2):
					ir.setFieldWrite(TypeFunctions.fieldName(fa));
					loop(e1);
					loop(e2);
				case TBinop(OpAssignOp(_), {expr: TField(e1, fa)}, e2):
					var name = TypeFunctions.fieldName(fa);
					ir.setFieldRead(name);
					ir.setFieldWrite(name);
					loop(e1);
					loop(e2);
				case TUnop(Increment | Decrement, _, {expr: TField(e1, fa)}):
					var name = TypeFunctions.fieldName(fa);
					ir.setFieldRead(name);
					ir.setFieldWrite(name);
					loop(e1);
				// Array
				case TArray(e1, e2):
					ir.setStateRead();
					loop(e1);
					loop(e2);
				case TBinop(OpAssign, {expr: TArray(e1, e2)}, e3):
					ir.setStateWrite();
					loop(e1);
					loop(e2);
					loop(e3);
				case TBinop(OpAssignOp(_), {expr: TArray(e1, e2)}, e3):
					ir.setStateRead();
					ir.setStateWrite();
					loop(e1);
					loop(e2);
					loop(e3);
				case TUnop(Increment | Decrement, _, {expr: TArray(e1, e2)}):
					ir.setStateRead();
					ir.setStateWrite();
					loop(e1);
					loop(e2);
				case TCall({expr: TIdent(s)}, el) if (!AnalyzerTexpr.isUnboundCallThatMightHaveSideEffects(s, el)):
					for (x in el) loop(x);
				case TNew(c, _, el) if (c.constructor != null && PurityState.isPure(c, c.constructor)):
					ir.setStateRead();
					for (x in el) loop(x);
				case TCall({expr: TField(e1, FEnum(_, _))}, el):
					loop(e1);
					for (x in el) loop(x);
				case TCall({expr: TField(e1, fa)}, el) if (PurityState.isPureFieldAccess(fa)):
					ir.setStateRead();
					loop(e1);
					for (x in el) loop(x);
				case TCall(e1, el):
					ir.setStateRead();
					ir.setStateWrite();
					loop(e1);
					for (x in el) loop(x);
				case TNew(_, _, el):
					ir.setStateRead();
					ir.setStateWrite();
					for (x in el) loop(x);
				case TBinop(OpAssign, e1, e2):
					ir.setStateWrite();
					loop(e1);
					loop(e2);
				case TBinop(OpAssignOp(_), e1, e2):
					ir.setStateRead();
					ir.setStateWrite();
					loop(e1);
					loop(e2);
				case TUnop(Increment | Decrement, _, e1):
					ir.setStateRead();
					ir.setStateWrite();
					loop(e1);
				case _:
					TexprTools.iter(loop, e);
			}
		}
		loop(e);
		return ir;
	}
}
