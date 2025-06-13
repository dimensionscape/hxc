package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.NotFound;
import hxc.core.TypingError;
import hxc.core.TexprTools;
import hxc.core.WithType;
import hxc.debug.DebugDump;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;
import hxc.typing.Matcher.Match;
import hxc.typing.TyperContext.CurrentFun;
import hxc.typing.Typeload;

// The typed toplevel-completion entries the JSON display lane collects; literals and keywords are appended
// at report time.
enum JsonToplevelEntry {
	JTLocal(v:TVar);
	JTField(cf:TClassField, c:TClass, isStatic:Bool);
	JTType(mt:hxc.core.Type.ModuleType);
	// An enum's constructors and an enum abstract's values are part of the toplevel collection in
	// their own right.
	JTEnumAbstract(a:hxc.core.Type.TAbstract, c:TClass, cf:TClassField);
	JTEnumCtor(en:hxc.core.Type.TEnum, ef:hxc.core.Type.TEnumField);
}

// The toplevel collection aborts typing and answers at report time through the JSON completion serializer.
class JsonToplevelCompletion extends haxe.Exception {
	public var items:Array<JsonToplevelEntry>;
	// The subject is the display expression's own dotted path at its own position; with no name the
	// position collapses to the cursor.
	public var subjectName:Null<String>;
	public var subjectPos:Null<hxc.ast.Position>;
	// The EXPECTED type at the cursor travels with the collection; it becomes the mode's args.
	public var wt:Null<hxc.core.WithType.WithType>;
	// A toplevel collection raised from inside a PATTERN is re-raised as CRPattern, carrying whether this
	// is the outermost pattern.
	public var patternOutermost:Null<Bool>;
	public function new(items:Array<JsonToplevelEntry>, ?subjectName:String, ?subjectPos:hxc.ast.Position, ?wt:hxc.core.WithType.WithType) {
		super("json toplevel completion");
		this.items = items;
		this.wt = wt;
		if (subjectName != null && subjectName != "") {
			this.subjectName = subjectName;
			this.subjectPos = subjectPos;
		}
	}
}

class Typer {
	// The stack of cast fields being applied, for macro @:from recursion.
	static var abstractCastStack:Array<TClassField> = [];

	// Clears the per-compilation mutable statics so a wait-server request types like a fresh process (each
	// request is an isolated compilation over the persistent caches).
	public static function resetPerRequest():Void {
		abstractCastStack = [];
		expectedArrayAllowDynamic = false;
		displayDefinition = false;
		displayFound = null;
		displaySubjectError = null;
		displayHover = false;
		hoverFound = null;
		hoverWalked = new haxe.ds.ObjectMap();
		definitionWalked = new haxe.ds.ObjectMap();
		exprDisplayOff = false;
		hxc.typing.ExprPreprocessing.markedNode = null;
		displayTypeDefinition = false;
		displaySignature = false;
		signatureFound = null;
		signatureCallPos = null;
		displayToplevel = false;
		displayToplevelJson = false;
		markedDisplay = null;
		displayUsage = false;
		displayImplementation = false;
		usageTargetField = null;
		usageTargetVar = null;
		usageTargetEnumField = null;
		usageTargetClass = null;
		usageTargetType = null;
		patternDisplay = false;
		hxc.typing.Typeload.typeHints = [];
		fieldCompletionFound = null;
	}

	// A fresh mono, recorded in the per-function list. A valid Haxe identifier: an initial letter or `_`,
	// then letters, digits or `_`. A quoted object field like "x-bar" is not one.
	static function isValidIdentifier(s:String):Bool {
		if (s.length == 0) return false;
		inline function isAlphaUnderscore(c:Int) return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code;
		if (!isAlphaUnderscore(s.charCodeAt(0))) return false;
		for (i in 1...s.length) {
			var c = s.charCodeAt(i);
			if (!isAlphaUnderscore(c) && !(c >= "0".code && c <= "9".code)) return false;
		}
		return true;
	}

	public static function spawnMonomorph(ctx:TyperContext, p:Position):T {
		var mono = TypeUnification.monoCreate();
		ctx.monomorphs.unshift({m: mono, p: p}); // Prepends (newest first)
		return TMono(mono);
	}

	public static function saveLocals(ctx:TyperContext):Void->Void {
		var saved = ctx.locals.copy();
		return function() ctx.locals = saved;
	}

	public static function addLocal(ctx:TyperContext, k:TVarKind, n:String, t:T, p:Position):TVar {
		var v = TypeFunctions.allocVar(k, n, t, p);
		ctx.locals.set(n, v);
		return v;
	}

	// A named local validates like any identifier, with its origin naming the message; a variable literally
	// named "this" is tolerated.
	public static function checkLocalVariableName(ctx:TyperContext, name:String, origin:TVarOrigin, p:Position):Void {
		if (name == "this") return;
		var kind = switch (origin) {
			case TVOLocalVariable: "variable";
			case TVOArgument: "function argument";
			case TVOForVariable: "for variable";
			case TVOPatternVariable: "pattern variable";
			case TVOCatchVariable: "catch variable";
			case TVOLocalFunction: "function";
		};
		if (StringTools.startsWith(name, "$"))
			ctx.com.addDiagnostic(hxc.core.StringHelper.capitalize(kind) + " names starting with a dollar are not allowed: \"" + name + "\"", p);
		else if (!hxc.core.StringHelper.isValidIdentifier(name))
			ctx.com.addDiagnostic("\"" + hxc.core.StringHelper.sEscape(name) + "\" is not a valid " + kind + " name.", p);
	}

	// The name check runs at each creation site with the name position (some call sites carry a
	// broader position).
	public static function addLocalWithOrigin(ctx:TyperContext, origin:TVarOrigin, n:String, t:T, p:Position):TVar {
		return addLocal(ctx, VUser(origin), n, t, p);
	}

	public static function monoOrDynamic(ctx:TyperContext, withType:WithType, p:Position):T {
		return switch (withType) {
			case NoValue: TDynamic(null);
			case Value(_) | WithType(_, _): spawnMonomorph(ctx, p);
		};
	}

	static function castOrUnifyInner(ctx:TyperContext, t:T, e:TExpr, p:Position, raiseOnFail:Bool):TExpr {
		if (TypeUnification.fastEq(e.type, t)) return e;
		// The cast-field search runs before plain unification: its strict first pass can pick a @:from
		// whose parameter matches exactly even when the value would also unify with a plain `from` type.
		if (!TypeUnification.typeIseqDefault(t, e.type)) {
			var casted = tryAbstractCast(ctx, e, t, p);
			if (casted != null) return casted;
		} else return e;
		var uerr:Array<hxc.core.TypeUnification.UnifyErrorKind> = null;
		try {
			TypeUnification.unifyDefault(e.type, t);
			return e;
		} catch (ue:UnifyError) { uerr = ue.errors; }
		// Untyped code swallows the unification failure and keeps the value . The RAISING variant does
		// not consult untyped: always raises, and call-argument typing needs that failure so
		// optional-argument SKIPPING still happens inside untyped code.
		if (!raiseOnFail && ctx.untypedMode) return e;
		throw new TypingError(hxc.core.TPrinting.betterErrorMessage(uerr), p);
	}

	// Never consults untyped.
	public static function castOrUnifyRaise(ctx:TyperContext, t:T, e:TExpr, p:Position):TExpr {
		return castOrUnifyInner(ctx, t, e, p, true);
	}

	// The non-raising variant, with the failure routed through raiseOrDisplay, which drops it entirely in
	// untyped code.
	public static function castOrUnify(ctx:TyperContext, t:T, e:TExpr, p:Position):TExpr {
		return castOrUnifyInner(ctx, t, e, p, false);
	}

	static function doesUnify(a:T, b:T):Bool {
		return try { TypeUnification.unifyDefault(a, b); true; } catch (_:UnifyError) false;
	}

	static function prefersAbstractCast(from:T, to:T):Bool {
		return switch [TypeFunctions.follow(from), TypeFunctions.follow(to)] {
			case [TAbstract(a, tl), _] if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				hasDirectToCast(a, tl, to);
			case _:
				false;
		}
	}

	static function hasDirectToCast(a:TAbstract, tl:Array<T>, to:T):Bool {
		for (castField in a.toField) {
			var castType = TypeFunctions.applyParams(a.params, tl, castField.t);
			if (sameDirectCastTarget(castType, to)) return true;
		}
		return false;
	}

	static function sameDirectCastTarget(a:T, b:T):Bool {
		return switch [TypeFunctions.follow(a), TypeFunctions.follow(b)] {
			case [TDynamic(_), TDynamic(_)]:
				true;
			case [TAbstract(a1, _), TAbstract(a2, _)]:
				a1 == a2;
			case [TInst(c1, _), TInst(c2, _)]:
				c1 == c2;
			case [TEnum(e1, _), TEnum(e2, _)]:
				e1 == e2;
			case _:
				false;
		}
	}

	// Implicit abstract conversion. The search is recursive: a declarative from/to type can expose a nested
	// runtime cast field.
	static function tryAbstractCast(ctx:TyperContext, e:TExpr, t:T, p:Position):Null<TExpr> {
		try return abstractCastLoop(ctx, e, t, e.type, [], p) catch (_:NotFound) return null;
	}

	// Null protocol: null means "no implicit cast applies", exactly what the NotFound throws meant.
	// makeAbstractCast can still raise NotFound (impl-less abstract, macro recursion probe), so the
	// try/catch stays around it and around the whole loop at the caller; only the finder misses and
	// the fall-throughs stop throwing.
	static function abstractCastLoop(ctx:TyperContext, e:TExpr, tleft:T, tright:T, stack:Array<{l:T, r:T}>, p:Position):Null<TExpr> {
		for (s in stack)
			if (TypeUnification.fastEq(tleft, s.l) && TypeUnification.fastEq(tright, s.r))
				return null;
		var stack2 = [{l: tleft, r: tright}].concat(stack);
		var uctx = TypeUnification.defaultUnificationContext;
		switch [TypeFunctions.follow(tleft), TypeFunctions.follow(tright)] {
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)]:
				var found = TypeUnification.findToFrom(uctx, e.type, tleft, a2, tl2, a1, tl1);
				if (found == null) return null;
				return makeAbstractCast(ctx, found.a, found.tl, found.castField, e, tleft, p);
			case [TAbstract(a, tl), _]:
				var ff = TypeUnification.findFromOpt(uctx, e.type, a, tl);
				if (ff != null)
					try return makeAbstractCast(ctx, a, tl, ff, e, tleft, p) catch (_:NotFound) {}
				for (tc in a.from) {
					var tnext = TypeFunctions.applyParams(a.params, tl, tc);
					if (!TypeUnification.typeIseqDefault(tnext, tleft))
						return abstractCastLoop(ctx, e, tnext, tright, stack2, p);
				}
				return null;
			case [_, TAbstract(a, tl)]:
				var ft = TypeUnification.findToOpt(uctx, tleft, a, tl);
				if (ft != null)
					try return makeAbstractCast(ctx, a, tl, ft, e, tleft, p) catch (_:NotFound) {}
				for (tc in a.to) {
					var tnext = TypeFunctions.applyParams(a.params, tl, tc);
					if (!TypeUnification.typeIseqDefault(tnext, tright))
						return abstractCastLoop(ctx, e, tleft, tnext, stack2, p);
				}
				return null;
			case _:
				return null;
		}
	}

	static function makeAbstractCast(ctx:TyperContext, a:TAbstract, tl:Array<T>, castField:TAbstractCast, e:TExpr, t:T, p:Position):TExpr {
		// Only a @:multiType cast field short-circuits to a plain cast; everything else (including extern
		// inline casts like Any.__promote) goes through a static call, whose inliner binds a side-effectful
		// receiver to a temp.
		if (TypeFunctions.hasMeta(":multiType", castField.cf.meta)) return TypeFunctions.mk(TCast(e, null), t, p);
		if (a.impl == null) throw new NotFound("Typer.hx:300");
		// Macro @:from recursion probe.
		if (hxc.eval.EvalMacro.isMacroField(castField.cf) && abstractCastStack.length > 0
			&& abstractCastStack[0] == castField.cf) {
			try {
				TypeUnification.unifyDefault(e.type, t);
			} catch (_:UnifyError) {
				throw new NotFound("Typer.hx:307");
			}
		}
		if (castField.cf == ctx.curfield || abstractCastStack.indexOf(castField.cf) >= 0)
			throw new TypingError("Recursive implicit cast", p);
		abstractCastStack.push(castField.cf);
		var result:TExpr;
		try {
			result = callImplCast(ctx, a.impl, castField.cf, e, t, p);
		} catch (err:Dynamic) {
			abstractCastStack.pop();
			throw err;
		}
		abstractCastStack.pop();
		// The implicit cast result is tagged @:implicitCast.
		return TypeFunctions.mk(TMeta({name: ":implicitCast", params: [], pos: result.pos}, result), result.type, result.pos);
	}

	// A trailing optional ?p:haxe.PosInfos on a cast method receives the call-site info.
	static function castArgs(ctx:TyperContext, cf:TClassField, e:TExpr, p:Position):Array<TExpr> {
		return switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): Calls.padPosInfos(ctx, sig.args, [e], p);
			case _: [e];
		};
	}

	static function callImplCast(ctx:TyperContext, implC:TClass, cf:TClassField, e:TExpr, t:T, p:Position):TExpr {
		if (hxc.eval.EvalMacro.isMacroField(cf)) return callMacroCast(ctx, implC, cf, e, t, p);
		// The from/to entry may be the synthetic selection field; the call goes to the impl class's real
		// static, whose body must be forced before makeCall consumes expr, or an inline cast survives to
		// the generators pointing at a function that is never emitted.
		var realCf = implC.statics.get(cf.name);
		if (realCf != null) cf = realCf;
		TypeFields.forceFieldBody(ctx.com, implC, cf);
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), p);
		var staticExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p), FCall);
		return Calls.makeCall(ctx, staticExpr, castArgs(ctx, cf, e, p), t, p);
	}

	static function callImplCastDirect(ctx:TyperContext, implC:TClass, cf:TClassField, e:TExpr, t:T, p:Position):TExpr {
		if (hxc.eval.EvalMacro.isMacroField(cf)) return callMacroCast(ctx, implC, cf, e, t, p);
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), p);
		var staticExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p), FCall);
		return TypeFunctions.mk(TCall(staticExpr, castArgs(ctx, cf, e, p)), t, p);
	}

	static function callMacroCast(ctx:TyperContext, implC:TClass, cf:TClassField, e:TExpr, t:T, p:Position):TExpr {
		// The whole attempt is SPECULATIVE: a failing macro cast raises NotFound and leaves no diagnostics
		// behind, so anything the macro run or its result's retype recorded rolls back.
		var before = ctx.com.diagnostics.length;
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(implC), p);
		var fa = FieldAccessTools.create(implExpr, cf, FHStatic(implC), false, p);
		try {
			var result = hxc.eval.EvalMacro.run(ctx, fa, [Calls.typedExprToSyntax(ctx, e)], WithTypeTools.withType(t), p);
			return try castOrUnify(ctx, t, result, p) catch (te:TypingError) {
				if (te.message == "Recursive implicit cast") throw te;
				throw new NotFound("Typer.hx:364");
			};
		} catch (err:haxe.Exception) {
			if (ctx.com.diagnostics.length > before) {
				// Warnings recorded during the trial survive; only trial ERRORS roll back.
				var kept = [for (i in before...ctx.com.diagnostics.length) ctx.com.diagnostics[i]];
				ctx.com.diagnostics.resize(before);
				for (d in kept) if (!d.severity.match(Error)) ctx.com.diagnostics.push(d);
			}
			throw err;
		}
	}

	static function isVoid(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	static function defaultCatchTypeHint(p:Position):TypeHint {
		return {
			ct: CTPath({tpackage: ["haxe"], tname: "Exception", tparams: [], tsub: null}),
			pos: p
		};
	}

	static function isDynamic(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TDynamic(_): true;
			case _: false;
		}
	}

	static function checkCatchTypeParams(params:TParams, p:Position):Void {
		for (pt in params) switch (TypeFunctions.followWithAbstracts(pt)) {
			case TDynamic(_):
			case _: throw new TypingError("Catch class parameter must be Dynamic", p);
		}
	}

	static function isGenericCatchParameter(ctx:TyperContext, c:TClass):Bool {
		if (!TypeFunctions.hasClassFieldFlag(ctx.curfield, CfGeneric)) return false;
		for (tp in ctx.curfield.params) switch (TypeFunctions.follow(tp.type)) {
			case TInst(c2, _) if (c2 == c):
				return true;
			case _:
		}
		return false;
	}

	// A type param is constructible if a constraint exposes a `new` field, is haxe.Constructible<T>, or
	// nests another constructible type param.
	static function getConstructibleConstraint(ctx:TyperContext, tl:Array<T>, p:Position):Null<TSignature> {
		function extractFunction(t:T):TSignature {
			return switch (TypeFunctions.follow(t)) {
				case TFun(sig): sig;
				case _: throw new TypingError("Constructible type parameter should be function", p);
			};
		}
		function loop(tl:Array<T>):Null<TSignature> {
			for (t in tl) switch (TypeFunctions.follow(t)) {
				case TAnon(a):
					var nf = a.fields.get("new");
					if (nf != null) return extractFunction(nf.type);
				case TAbstract(a, [t1]) if (a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Constructible"):
					return extractFunction(t1);
				case TInst(c, _) if (c.kind.match(KTypeParameter(_))):
					var tl1 = switch (c.kind) { case KTypeParameter(x): x; case _: []; };
					var r = loop(tl1);
					if (r != null) return r;
				case _:
			}
			return null;
		}
		return loop(tl);
	}

	static function isGenericParameter(ctx:TyperContext, c:TClass):Bool {
		if (ctx.curclass != null) {
			switch (ctx.curclass.kind) {
				case KGeneric:
					for (tp in ctx.curclass.params) switch (TypeFunctions.follow(tp.type)) {
						case TInst(c2, _) if (c2 == c): return true;
						case _:
					}
				case _:
			}
		}
		if (ctx.curfield != null && TypeFunctions.hasClassFieldFlag(ctx.curfield, CfGeneric)) {
			for (tp in ctx.curfield.params) switch (TypeFunctions.follow(tp.type)) {
				case TInst(c2, _) if (c2 == c): return true;
				case _:
			}
		}
		return false;
	}

	/**
	 * The three complaints report at three DIFFERENT positions and the distinction is not cosmetic:
	 * the type-parameter one is about the try as a whole (`pTry`), the parameter check is about the
	 * hint that was written (`pHint`), and the catch-all is about the catch body (`pBody`), because by
	 * then the hint has been followed through typedefs and abstracts and no longer corresponds to any
	 * span the user wrote.
	 */
	static function normalizeCatchType(ctx:TyperContext, t:T, pTry:Position, pHint:Position, pBody:Position):T {
		function loop(t:T):T {
			return switch (TypeFunctions.follow(t)) {
				case TInst(c, _) if (c.kind.match(KTypeParameter(_)) && !isGenericCatchParameter(ctx, c)):
					throw new TypingError("Cannot catch non-generic type parameter", pTry);
				case TInst(_, params) | TEnum(_, params):
					checkCatchTypeParams(params, pHint);
					t;
				case TAbstract(a, params) if (TypeFunctions.hasMeta(":runtimeValue", a.meta)):
					checkCatchTypeParams(params, pHint);
					t;
				case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
					loop(TypeFunctions.getUnderlyingType(a, tl));
				case TDynamic(_):
					t;
				case _:
					throw new TypingError("Catch type must be a class, an enum or Dynamic", pBody);
			}
		}
		return loop(t);
	}

	static function checkCatchUnreachable(prev:Array<TCatch>, t:T, p:Position):Void {
		for (c in prev) {
			if (isDynamic(c.v.type)) throw new TypingError("This block is unreachable", p);
			if (!isDynamic(t)) {
				try {
					TypeUnification.unifyDefault(t, c.v.type);
					throw new TypingError("This block is unreachable", p);
				} catch (_:UnifyError) {}
			}
		}
	}

	// The compile-time value of a single-character string's `.code`. A host string is UTF-16 here, so a
	// character outside the BMP is a surrogate pair (two units) that combines into its codepoint. Returns
	// null when the literal is not exactly one codepoint, letting normal field access report the error.
	static function singleCodePoint(s:String):Null<Int> {
		if (s.length == 1) return s.charCodeAt(0);
		if (s.length == 2) {
			var hi = s.charCodeAt(0);
			var lo = s.charCodeAt(1);
			if (hi >= 0xD800 && hi <= 0xDBFF && lo >= 0xDC00 && lo <= 0xDFFF)
				return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
		}
		return null;
	}

	public static function unifyMinRaise(ctx:TyperContext, el:Array<TExpr>):T {
		var basic = ctx.com.basic;
		if (el.length == 0) return spawnMonomorph(ctx, Position.nullPos);
		if (el.length == 1) return el[0].type;

		function chkNull(e:TExpr):Bool {
			if (TypeFunctions.isNull(e.type) || TypeFunctions.isExplicitNull(e.type)) return true;
			return switch (e.expr) {
				case TConst(TNull): true;
				case TBlock(el2): el2.length == 0 ? false : chkNull(el2[el2.length - 1]);
				case TParenthesis(e2): chkNull(e2);
				case TMeta(_, e2): chkNull(e2);
				case _: false;
			};
		}

		var t = spawnMonomorph(ctx, Position.nullPos);
		var hasError = false;
		for (e in el) {
			if (chkNull(e)) t = basic.tnull(t);
			try {
				TypeUnification.unifyDefault(e.type, t);
			} catch (_:UnifyError) {
				try {
					TypeUnification.unifyDefault(t, e.type);
					t = TypeFunctions.isNull(t) ? basic.tnull(e.type) : e.type;
				} catch (_:UnifyError) {
					hasError = true;
					break;
				}
			}
		}
		if (!hasError) return t;

		var anonMin = unifyMinConstAnon(ctx, el);
		if (anonMin != null) return anonMin;

		var funMin = unifyMinFun(el);
		if (funMin != null) return funMin;

		var commonTypes = TypeUnification.collectBaseTypes(t);
		var dynTypes = [];
		for (ty in commonTypes) {
			switch (ty) {
				case TInst(c, params) if (params.length > 0 && hasUnifyMinDynamic(c)):
					dynTypes.push(TInst(c, [for (_ in params) TDynamic(null)]));
				case _:
			}
		}
		dynTypes.reverse();
		if (dynTypes.length > 0) commonTypes = commonTypes.concat(dynTypes);
		var elTail = el.slice(1);
		var tl = [for (e in elTail) e.type];
		return switch (TypeUnification.unify_min_(TypeUnification.defaultUnificationContext, commonTypes, tl)) {
			case UnifyMinOk(t2): t2;
			case UnifyMinError(l, index):
				throw new hxc.core.TypingError.MinUnifyError(hxc.core.TPrinting.betterErrorMessage(l), elTail[index].pos);
		};
	}

	static function unifyMinConstAnon(ctx:TyperContext, el:Array<TExpr>):Null<T> {
		var fieldsByExpr:Array<haxe.ds.StringMap<TExpr>> = [];
		var fieldNames:Array<String> = [];
		var fieldCount = -1;
		for (e in el) {
			switch [TypeFunctions.follow(e.type), e.expr] {
				case [TAnon(a), TObjectDecl(fields)] if (a.status.get().match(Const)):
					var map = new haxe.ds.StringMap<TExpr>();
					for (f in fields) map.set(f.key.name, f.expr);
					var count = 0;
					for (_ in map.keys()) count++;
					if (fieldCount == -1) {
						fieldCount = count;
						for (n in map.keys()) fieldNames.push(n);
					} else if (fieldCount != count) {
						return null;
					}
					for (n in fieldNames) if (!map.exists(n)) return null;
					fieldsByExpr.push(map);
				case _:
					return null;
			}
		}
		var fields = new haxe.ds.StringMap<TClassField>();
		for (n in fieldNames) {
			var exprs = [for (m in fieldsByExpr) m.get(n)];
			var ft = try unifyMinRaise(ctx, exprs) catch (_:TypingError) return null;
			fields.set(n, TypeFunctions.mkField(n, ft, exprs[0].pos, Position.nullPos));
		}
		return TypeFunctions.mkAnon(new hxc.core.Ref(Closed), fields);
	}

	// Common type of function values: per argument keep the type every other argument type unifies into
	// (contravariance), and unify-min the returns.
	static function unifyMinFun(el:Array<TExpr>):Null<T> {
		var args:Array<TSignatureArg>;
		var tr0:T;
		switch (TypeFunctions.follow(el[0].type)) {
			case TFun(sig): args = sig.args.copy(); tr0 = sig.ret;
			case _: return null;
		}
		var rets:Array<T> = [];
		for (i in 1...el.length) {
			switch (TypeFunctions.follow(el[i].type)) {
				case TFun(sig):
					if (sig.args.length != args.length) return null;
					for (j in 0...args.length) {
						var tcur = args[j].t;
						var argnew = sig.args[j];
						if (TypeUnification.doesUnify(argnew.t, tcur)) args[j] = argnew;
						else if (!TypeUnification.doesUnify(tcur, argnew.t)) return null;
					}
					rets.push(sig.ret);
				case _: return null;
			}
		}
		var commonTypes = TypeUnification.collectBaseTypes(tr0);
		return switch (TypeUnification.unify_min_(TypeUnification.defaultUnificationContext, commonTypes, rets)) {
			case UnifyMinOk(tr): TFun({args: args, ret: tr});
			case UnifyMinError(_, _): null;
		};
	}

	static function hasUnifyMinDynamic(c:TClass):Bool {
		if (TypeFunctions.hasMeta(":unifyMinDynamic", c.meta)) return true;
		return switch (c.superClass) {
			case null: false;
			case s: hasUnifyMinDynamic(s.c);
		};
	}

	public static function unifyMin(ctx:TyperContext, el:Array<TExpr>):T {
		// Reports every unify failure unifyMinRaise raised, with no filtering on what it says, and
		// recovers to the first element's type.
		return try unifyMinRaise(ctx, el) catch (e:hxc.core.TypingError.MinUnifyError) {
			if (!ctx.untypedMode) ctx.com.addDiagnostic(e.message, e.pos, e.depth);
			el[0].type;
		};
	}

	public static function unifyMinForTypeSource(ctx:TyperContext, el:Array<TExpr>, src:Null<WithTypeSource>):T {
		return switch (src) {
			case ImplicitReturn if (Lambda.exists(el, function(e) return isVoid(e.type))):
				ctx.com.basic.tvoid;
			case _: unifyMin(ctx, el);
		};
	}

	// Side effect of the expected walk: seeing Dynamic anywhere allows a mixed literal to degrade to
	// Array<Dynamic> even when the walk itself resolves nothing.
	static var expectedArrayAllowDynamic:Bool = false;

	static function arrayElementFromType(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, [et]) if (c.path.pack.length == 0 && c.path.name == "Array"):
				switch (TypeFunctions.follow(et)) {
					case TMono(_): null;
					case TDynamic(_): expectedArrayAllowDynamic = true; et;
					case _: et;
				}
			case _:
				null;
		}
	}

	static function anonFieldCount(a:TAnon):Int {
		var n = 0;
		for (_ in a.fields.keys()) n++;
		return n;
	}

	// The element type of a closed { hasNext():Bool, next():T } anon.
	static function getIteratorParam(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TAnon(a) if (a.status.get().match(Closed)):
				var hn = a.fields.get("hasNext");
				var nx = a.fields.get("next");
				if (hn == null || nx == null) null;
				else switch [TypeFunctions.follow(hn.type), TypeFunctions.follow(nx.type)] {
					case [TFun(sh), TFun(sn)] if (sh.args.length == 0 && sn.args.length == 0):
						var isBool = switch (TypeFunctions.follow(sh.ret)) {
							case TAbstract(ab, []): ab.path.pack.length == 0 && ab.path.name == "Bool";
							case _: false;
						};
						if (isBool && anonFieldCount(a) == 2) sn.ret else null;
					case _: null;
				}
			case _: null;
		}
	}

	// The element type of a closed { iterator():Iterator<T> } anon.
	static function getIterableParam(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TAnon(a) if (a.status.get().match(Closed)):
				var it = a.fields.get("iterator");
				if (it == null) null;
				else switch (TypeFunctions.follow(it.type)) {
					case TFun(s) if (s.args.length == 0):
						var r = getIteratorParam(s.ret);
						if (r != null && anonFieldCount(a) == 1) r else null;
					case _: null;
				}
			case _: null;
		}
	}

	static function expectedArrayElement(ctx:TyperContext, t:T):Null<T> {
		function loop(seen:Array<T>, t:T):Null<T> {
			t = TypeFunctions.follow(t);
			var direct = arrayElementFromType(t);
			if (direct != null) return direct;
			return switch (t) {
				// An expected structural (Iterable/Iterator) type gives its element.
				case TAnon(_):
					getIterableParam(t);
				case TAbstract(a, tl):
					for (seenT in seen) if (TypeUnification.fastEq(seenT, t)) return null;
					var hits:Array<T> = [];
					for (ft in getAbstractFroms(ctx, a, tl)) {
						var et = loop(seen.concat([t]), ft);
						if (et != null) hits.push(et);
					}
					hits.length == 1 ? hits[0] : null;
				case TDynamic(_):
					expectedArrayAllowDynamic = true;
					t;
				case _:
					null;
			}
		}
		return loop([], t);
	}

	// A @:from field with @:from(ignoredByInference) is skipped when inferring an expected type from an
	// abstract's froms.
	static function fromIgnoredByInference(ml:Metadata):Bool {
		var ignored = false;
		for (m in ml) if (m.name == ":from") for (e in m.params) switch (e.expr) {
			case EConst(CIdent("ignoredByInference")):
				ignored = true;
			case EBinop(OpAssign, {expr: EConst(CIdent("ignoredByInference"))}, {expr: EConst(CIdent(v))}) if (v == "true" || v == "false"):
				ignored = v == "true";
			case _:
		}
		return ignored;
	}

	// The from types an expected abstract offers for inference: direct from entries with params applied,
	// plus each single-argument @:from field whose monomorphized return matches the abstract strictly (a
	// macro @:from degrades to Dynamic and fails this check, so it never leaks a Dynamic expectation).
	// Duplicated params keep the probe from binding the real expected parameters.
	public static function getAbstractFroms(ctx:TyperContext, a:TAbstract, pl:Array<T>):Array<T> {
		var acc:Array<T> = [for (t in a.from) TypeFunctions.applyParams(a.params, pl, t)];
		for (fc in a.fromField) {
			var f = fc.cf;
			// The cast entry and the impl class's real static are separate objects here, so the
			// self-exclusion also matches by name against the current impl field.
			if (f == ctx.curfield) continue;
			if (ctx.curfield != null && f.name == ctx.curfield.name
					&& a.impl != null && a.impl.statics.get(ctx.curfield.name) == ctx.curfield) continue;
			if (fromIgnoredByInference(f.meta)) continue;
			var ftype = f.params.length == 0 ? f.type : {
				var monos:Array<T> = [for (_ in f.params) TypeFunctions.mkMono()];
				TypeFunctions.applyParams(f.params, monos, f.type);
			};
			switch (TypeFunctions.follow(ftype)) {
				case TFun(sig) if (sig.args.length == 1):
					try {
						TypeUnification.typeEqKind(EqStrict, sig.ret, TAbstract(a, [for (x in pl) TypeFunctions.duplicate(x)]));
						acc = [sig.args[0].t].concat(acc);
					} catch (_:UnifyError) {}
				case _:
			}
		}
		return acc;
	}

	static function abstractFromTypes(ctx:TyperContext, t:T):Array<T> {
		t = TypeFunctions.follow(t);
		return switch (t) {
			case TAbstract(a, tl):
				getAbstractFroms(ctx, a, tl);
			case _:
				[];
		}
	}

	// Type_expr (core subset). A subtree the COMPILER built, registered by identity the way
	// markedDisplay is. The reference can never answer a display question from one: ExprPreprocessing
	// chose the subject before the rewrite existed, so the node was never a candidate. hxc decides by
	// position, and these carry the position of the construct they were built for, so the check is off
	// while the subtree types. The rest of the construct - the arguments the user wrote - types
	// outside this window and still answers.
	public static var synthesizedNodes:Array<Expr> = [];

	public static function synthesized(e:Expr):Expr {
		synthesizedNodes.push(e);
		return e;
	}

	public static function typeExpr(ctx:TyperContext, e:Expr, withType:WithType, ?mode:AccessMode):TExpr {
		if (synthesizedNodes.length > 0 && synthesizedNodes.remove(e)) {
			var saved = hxc.parser.Parser.displaySuppressed;
			hxc.parser.Parser.displaySuppressed = true;
			var r = try typeExpr(ctx, e, withType, mode)
				catch (ex:Dynamic) { hxc.parser.Parser.displaySuppressed = saved; throw ex; };
			hxc.parser.Parser.displaySuppressed = saved;
			return r;
		}
		if (mode == null) mode = MGet;
		var basic = ctx.com.basic;
		var p = e.pos;
		var typed = switch (e.expr) {
			case EConst(c): typeConst(ctx, c, p, mode, withType);
			case EParenthesis(e1):
				var te = typeExpr(ctx, e1, withType);
				// Keeps the PARENTHESIS position here, not the inner one, so the node spans both
				// parentheses as the parser built it. Collapsing it onto the inner would make the two
				// indistinguishable, and the js source map would then drop the outer segment as a
				// duplicate.
				TypeFunctions.mk(TParenthesis(te), te.type, p);
			case EBlock([]) if (emptyBlockIsObject(withType)):
				// `{}` parses as an empty block; in a value position with a known (non-mono) type it is an
				// empty object literal, not a Void block.
				typeExpr(ctx, new Expr(EObjectDecl([]), p), withType);
			case EBlock(l):
				var restore = saveLocals(ctx);
				var te = typeBlock(ctx, l, withType, p);
				restore();
				te;
			case EVars(vl): typeVars(ctx, vl, p);
			case EIf(econd, e1, e2): typeIf(ctx, econd, e1, e2, withType, false, p);
			case ETernary(econd, e1, e2): typeIf(ctx, econd, e1, e2, withType, true, p);
			case EWhile(cond, body, NormalWhile):
				var oldLoop = ctx.inLoop;
				var c = castOrUnify(ctx, basic.tbool, typeExpr(ctx, cond, WithTypeTools.value), p);
				ctx.inLoop = true;
				var b = typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
				ctx.inLoop = oldLoop;
				TypeFunctions.mk(TWhile(c, b, NormalWhile), basic.tvoid, p);
			case EWhile(cond, body, DoWhile):
				var oldLoop = ctx.inLoop;
				ctx.inLoop = true;
				var b = typeExpr(ctx, Expr.ensureBlock(body), WithTypeTools.noValue);
				ctx.inLoop = oldLoop;
				var c = typeExpr(ctx, cond, WithTypeTools.value);
				c = castOrUnify(ctx, basic.tbool, c, c.pos);
				TypeFunctions.mk(TWhile(c, b, DoWhile), basic.tvoid, p);
			case EReturn(re):
				if (!ctx.inFunction) {
					// Reported and RECOVERED as the returned value so the initializer still types (and its
					// own mismatches still report).
					ctx.com.addDiagnostic("Return outside function", p);
					return re == null ? TypeFunctions.mk(TConst(TNull), spawnMonomorph(ctx, p), p) : typeExpr(ctx, re, withType);
				}
				typeReturn(ctx, re, withType, p);
			case EBreak:
				if (!ctx.inLoop) throw new TypingError("Break outside loop", p);
				TypeFunctions.mk(TBreak, monoOrDynamic(ctx, withType, p), p);
			case EContinue:
				if (!ctx.inLoop) throw new TypingError("Continue outside loop", p);
				TypeFunctions.mk(TContinue, monoOrDynamic(ctx, withType, p), p);
			case EThrow(e1):
				var te = typeExpr(ctx, e1, WithTypeTools.value);
				TypeFunctions.mk(TThrow(te), monoOrDynamic(ctx, withType, p), p);
			case EUntyped(e1):
				var old = ctx.untypedMode;
				ctx.untypedMode = true;
				if (!TypeFunctions.hasMeta(":has_untyped", ctx.curfield.meta))
					ctx.curfield.meta = ([{name: ":has_untyped", params: [], pos: p}] : Metadata).concat(ctx.curfield.meta);
				var te = try typeExpr(ctx, e1, withType) catch (err:haxe.Exception) { ctx.untypedMode = old; throw err; }
				ctx.untypedMode = old;
				TypeFunctions.mk(te.expr, spawnMonomorph(ctx, te.pos), te.pos);
			case EMeta(m, e1) if (m.name == ":toString"):
				// Every trace argument is wrapped in this meta. An abstract whose impl declares toString is
				// converted here, so haxe.Log.trace receives the string rather than the abstract value;
				// otherwise `trace(someMap)` would pass the Map straight through as Dynamic.
				var teTs = typeExpr(ctx, e1, withType);
				switch (TypeFunctions.follow(teTs.type)) {
					case TAbstract(a, _) if (a.impl != null && a.impl.statics.exists("toString")):
						Calls.callToString(ctx, teTs);
					case _: teTs;
				}
			case EMeta(m, _) if (m.name == ":markup"):
				// A markup literal surviving to typing was not consumed.
				throw new TypingError("Markup literals must be processed by a macro", p);
			case EMeta(m, e1) if (m.name == ":privateAccess"):
				ctx.privateAccess++;
				var rPriv = try typeExpr(ctx, e1, withType) catch (err:haxe.Exception) { ctx.privateAccess--; throw err; };
				ctx.privateAccess--;
				return rPriv;
			case EMeta(m, e1) if (m.name == ":noPrivateAccess"):
				// Strips any enclosing @:privateAccess for the subexpression.
				var oldPa = ctx.privateAccess;
				ctx.privateAccess = 0;
				var rNoPriv = try typeExpr(ctx, e1, withType) catch (err:haxe.Exception) { ctx.privateAccess = oldPa; throw err; };
				ctx.privateAccess = oldPa;
				return rNoPriv;
			case EMeta(m, e1) if (m.name == ":bypassAccessor"):
					// The next field access typed within e1 consumes this and becomes a raw access.
					var oldBypass = ctx.bypassAccessor;
					ctx.bypassAccessor = oldBypass + 1;
					var teBypass = try typeExpr(ctx, e1, withType) catch (err:haxe.Exception) { ctx.bypassAccessor = oldBypass; throw err; }
					function bypassDepth(x:Expr):Int return switch (x.expr) {
						case EMeta(m2, inner) if (m2.name == ":bypassAccessor"): 1 + bypassDepth(inner);
						case _: 0;
					};
					var nestedBypass = bypassDepth(e1);
					if (ctx.bypassAccessor > oldBypass && nestedBypass != 1)
						ctx.com.addDiagnostic("Field access expression expected after @:bypassAccessor metadata", m.pos);
					ctx.bypassAccessor = oldBypass;
					teBypass;
			case EMeta(m, e1) if (m.name == ":mergeBlock"):
					// A @:mergeBlock block opens no scope; its declarations merge into the enclosing block.
					// Type the inner statements in the current scope and wrap them so the enclosing block
					// splices them (see typeBlock).
					switch (e1.expr) {
						case EBlock(el):
							var inner = typeBlock(ctx, el, withType, p);
							TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: p}, inner), inner.type, inner.pos);
						case _: typeExpr(ctx, e1, withType);
					}
				case EMeta(m, {expr: EReturn(re)}) if (m.name == ":implicitReturn"):
					// An arrow function body's synthesized return.
					if (!ctx.inFunction) throw new TypingError("Return outside function", p);
					typeReturn(ctx, re, withType, p, true);
				case EMeta(m, e1) if (m.name == ":storedTypedExpr"):
					var id = switch (e1.expr) {
						case EConst(CInt(s, _)): Std.parseInt(s);
						case _: null;
					}
					if (id == null || !ctx.com.storedTypedExprs.exists(id)) throw new TypingError("Unknown stored typed expression", p);
					// Fresh tvars on every retrieval so the expression does not share variable slots with
					// its original (macro-time) context; this rebinds to the enclosing context.
					TexprTools.duplicateTvars(function(te) {
						return getThis(ctx, te.pos);
					}, ctx.com.storedTypedExprs.get(id));
				case EMeta(m, e1) if (m.name == ":fixed" && ctx.com.platform.match(Cpp)):
					// @:fixed survives typing on cpp so the retyper builds the typed AnonStruct literal.
					var te = typeExpr(ctx, e1, withType);
					TypeFunctions.mk(TMeta(m, te), te.type, te.pos);
				case EMeta(m, e1) if (m.name == ":nullSafety" && m.params.length == 1 && m.params[0].expr.match(EConst(CIdent("Off")))):
					// @:nullSafety(Off) survives typing so the null-safety filter sees the opt-out.
					var te = typeExpr(ctx, e1, withType);
					TypeFunctions.mk(TMeta(m, te), te.type, te.pos);
				case EMeta(m, {expr: ECall(callee, args)}) if (m.name == ":inline"):
					accGet(ctx, Calls.typeCallAccess(ctx, callee, args, withType, p, true, m.pos));
				case EMeta(m, {expr: ENew(tp, el)}) if (m.name == ":inline"):
					// A forced-inline construction keeps the marker for the inline-constructor filter.
					var te = typeNew(ctx, tp, el, withType, p);
					TypeFunctions.mk(TMeta({name: ":inline", params: [], pos: Position.nullPos}, te), te.type, te.pos);
				case EMeta(m, e1) if (m.name == ":inline"):
					// Only a call or constructor may follow the inline keyword; anything else (an anonymous
					// function, a plain value) reports and types without inlining.
					ctx.com.addDiagnostic("Call or function expected after inline keyword", p);
					typeExpr(ctx, e1, withType);
				case EMeta(m, e1) if (m.name.length > 1 && m.name.charCodeAt(0) == "$".code):
					// A `$i{...}` / `$e{...}` reification meta reaching the typer is outside any macro
					// expression (a macro body reifies these before typing).
					var reificationMessage = "Reification $" + m.name.substr(1) + " is not allowed outside of `macro` expression";
					// Reported once per world. A module that also holds a macro is compiled once per world, and
					// each compilation reports it, so it prints twice for that shape and once for every other.
					ctx.com.addDiagnostic(reificationMessage, m.pos);
					typeExpr(ctx, e1, withType);
				case EMeta(_, e1):
				typeExpr(ctx, e1, withType);
			case EField(_, _, _) | EArray(_, _) | ECall(_, _):
				accGet(ctx, typeAccess(ctx, e.expr, p, mode, withType));
			case EBinop(op, e1, e2):
				// An assignment whose own span holds the cursor while neither operand does is "probably" a
				// request on the RIGHT-hand side, so side becomes the display subject. Bottom-up in the
				// reference; here an operand already covering the cursor is what stands in for was_annotated.
				switch (op) {
					case OpAssign | OpAssignOp(_)
						if (hxc.parser.Parser.displayCompletionMode && fieldCompletionFound == null
							&& atDisplayPos(p) && !atDisplayPos(e1.pos) && !atDisplayPos(e2.pos)):
						markedDisplay = e2;
					case _:
				}
				Operators.typeBinop(ctx, op, e1, e2, false, withType, p);
			case EUnop(op, flag, e1):
				Operators.typeUnop(ctx, op, flag, e1, withType, p);
			case ESwitch(e1, cases, def):
				// The matcher output wraps in @:ast carrying the original switch syntax. Downstream, the
				// var-and-assign block unwrap does not cross the meta, so a value match keeps its subject
				// binds inside the var init.
				var me = Match.matchExpr(ctx, e1, cases, def, withType, false, p);
				TypeFunctions.mk(TMeta({name: ":ast", params: [e], pos: p}, me), me.type, me.pos);
			case EFor(it, body):
				ForLoop.typeForLoop(ctx, it, body, p);
			case ENew(tp, el):
				// The type list a `new <cursor>` raises is re-raised filtered to what can actually be
				// CONSTRUCTED - a class or abstract with a constructor, inherited ones included, or a type
				// parameter whose constraints make it constructible. Nothing else survives.
				try typeNew(ctx, tp, el, withType, p)
				catch (tc:hxc.compiler.DisplayXml.ToplevelCompletion) {
					var items = [for (it in tc.items) if (newCandidateSurvives(ctx, it, p)) it];
					var keep = new haxe.ds.StringMap<Bool>();
					for (it in items) if (it.path != null) keep.set(it.path, true);
					var mts = tc.moduleTypes == null ? null
						: [for (mt in tc.moduleTypes) if (keep.exists(hxc.core.Globals.sTypePath(TypeFunctions.tInfos(mt).path))) mt];
					var out = new hxc.compiler.DisplayXml.ToplevelCompletion(items, mts);
					// The filtered collection answers as CRNew (10), carrying the subject the raise built -
					// the JSON lane has nothing else to report with.
					out.kind = 10;
					out.subjectPos = tc.subjectPos;
					out.subjectName = tc.subjectName;
					throw out;
				}
			case EFunction(kind, f):
				// An anonymous function as a plain STATEMENT has no receiver for its value.
				if (withType.match(NoValue)) switch (kind) {
					case FKNamed(_, _):
					case _: ctx.com.addDiagnostic("Unnamed lvalue functions are not supported", p);
				}
				var savedTypeParams = ctx.typeParams;
				var localParams:TypeParams = [];
				if (f.fParams.length > 0) {
					// An unnamed local function has no name to specialise under, and a local function used as a
					// value cannot carry parameters at all. The first is recorded, the second raises, so `var f =
					// function<T>(v:T) ...` prints both.
					if (!kind.match(FKNamed(_, _)))
						ctx.com.addDiagnostic("Type parameters not supported in unnamed local functions", p);
					if (!withType.match(NoValue))
						throw new TypingError("Type parameters are not supported for rvalue functions", p);
					// A local function's own type parameters (`function foo<T>(...)`) are in scope for its
					// argument/return hints and body.
					var declPath:hxc.core.Globals.Path = {pack: [], name: switch (kind) { case FKNamed(n, _): n.name; case _: "`localfun"; }};
					for (tp in f.fParams) localParams.push(Typeload.typeTypeParam(ctx.com, declPath, () -> savedTypeParams.concat(localParams), tp));
					ctx.typeParams = savedTypeParams.concat(localParams);
				}
				var args:Array<TFuncArg> = [];
				for (fa in f.fArgs) {
					var at = Typeload.loadTypeHint(ctx.com, ctx.typeParams, fa.type, fa.opt);
					checkLocalVariableName(ctx, fa.name.name, TVOArgument, fa.name.pos);
					// Every function argument, local functions included, is allocated as
					// VUser(TVOArgument). Tail-recursion elimination keys all three of its checks off that
					// kind (captured arguments, the tail-recursion assign arm, the argument-local test), so
					// treating a local function's arguments as local VARIABLES would make it reuse the
					// parameters instead of redeclaring loop-scoped copies.
					var av = TypeFunctions.allocVar(VUser(TVOArgument), fa.name.name, at, fa.name.pos);
					// The display is answered from the argument's own name range.
					if (atDisplayPos(fa.name.pos)) displayVariable(ctx, av, fa.name.pos);
					args.push({v: av, c: null});
				}
				var ret = Typeload.loadTypeHint(ctx.com, ctx.typeParams, f.fType, false);
				// Top-down inference: bind unannotated (mono) arg/return types from an expected function
				// type.
				function expectVoid(t:T):Bool {
					return switch (TypeFunctions.follow(t)) {
						case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
						case _: false;
					}
				}
				function maybeUnifyArg(t1:T, t2:T):Void {
					switch (TypeFunctions.follow(t1)) {
						case TMono(_): try TypeUnification.unifyDefault(t2, t1) catch (_:Dynamic) {}
						case _:
					}
				}
				function maybeUnifyRet(t2:T):Void {
					// A Void expected return is not forced onto a non-arrow function (its body infers the return),
					// but an arrow does take Void so its body types in void context (its value is discarded, no
					// value-return synthesized).
					var isArrow = switch (kind) { case FKArrow: true; case _: false; };
					if (!expectVoid(t2) || isArrow) switch (TypeFunctions.follow(ret)) {
						case TMono(_): try TypeUnification.unifyDefault(ret, t2) catch (_:Dynamic) {}
						case _:
					}
				}
				function applyFunExpectation(t:T):Bool {
					return switch (TypeFunctions.follow(t)) {
						case TFun(sig) if (sig.args.length == args.length):
							for (i in 0...args.length) maybeUnifyArg(args[i].v.type, sig.args[i].t);
							maybeUnifyRet(sig.ret);
							true;
						case _:
							false;
					}
				}
				function flattenAbstractSources(t:T, seen:Array<T>):Array<T> {
					t = TypeFunctions.follow(t);
					return switch (t) {
						case TAbstract(_, _):
							for (seenT in seen) if (TypeUnification.fastEq(seenT, t)) return [];
							var sources = abstractFromTypes(ctx, t);
							if (sources.length == 1) flattenAbstractSources(sources[0], seen.concat([t])) else {
								var out:Array<T> = [];
								for (source in sources) switch (TypeFunctions.follow(source)) {
									case TAbstract(_, _): out = out.concat(flattenAbstractSources(source, seen.concat([t])));
									case _: out.push(source);
								}
								out;
							}
						case _:
							[t];
					}
				}
				function commonType(types:Array<T>):Null<T> {
					if (types.length == 0) return null;
					var first = types[0];
					for (i in 1...types.length) if (!TypeUnification.typeIseqDefault(first, types[i])) return null;
					return first;
				}
				function applyAbstractFunctionMatrix(t:T):Void {
					var candidates = [for (source in flattenAbstractSources(t, [])) switch (TypeFunctions.follow(source)) {
						case TFun(sig) if (sig.args.length == args.length): sig;
						case _: null;
					}].filter(x -> x != null);
					if (candidates.length == 0) return;
					for (i in 0...args.length) {
						var t = commonType([for (sig in candidates) sig.args[i].t]);
						if (t != null) maybeUnifyArg(args[i].v.type, t);
					}
					var rt = commonType([for (sig in candidates) sig.ret]);
					if (rt != null) maybeUnifyRet(rt);
				}
				switch (withType) {
					case WithType(wt, _):
						if (!applyFunExpectation(wt)) applyAbstractFunctionMatrix(wt);
					case _:
				}
				// An arg is optional in the function type when marked `?` or given a default value.
				var ft = TFun({args: [for (i in 0...args.length) {name: args[i].v.name, opt: f.fArgs[i].opt || f.fArgs[i].value != null, t: args[i].v.type}], ret: ret});
				// A named local function binds its name (in scope before the body, so it can recurse)
				// and evaluates to a TVar assignment; an anonymous one is just the function value.
				var namedVar:Null<TVar> = switch (kind) {
					case FKNamed(n, _):
						checkLocalVariableName(ctx, n.name, TVOLocalFunction, n.pos);
						addLocal(ctx, VUser(TVOLocalFunction), n.name, ft, n.pos);
					case _: null;
				};
				// A named generic local function stores its type params so a later call can monomorphize
				// them.
				// An INLINE local function additionally stores its function expression on extra (set
				// after the body types, below), which the identifier resolver turns into a fake inline
				// field call.
				if (namedVar != null && localParams.length > 0) namedVar.extra = new TVarExtra(localParams);
				// Type each argument default value against its (possibly inferred) type, binding an unbound
				// monomorph and recording it for runtime default insertion. .
				for (i in 0...args.length) {
					var fa = f.fArgs[i];
					var at = args[i].v.type;
					if (fa.value != null) {
						args[i].c = typeExpr(ctx, fa.value, WithTypeTools.withType(at));
						// The typed default with the argument type (Null-wrapped, since a default makes the argument
						// optional). This records a constraint on the argument monomorph that survives to its close,
						// so a later use that links it to another mono can resolve to the default's type.
						var target = fa.opt ? ctx.com.basic.tnull(at) : at;
						try TypeUnification.unifyDefault(args[i].c.type, target) catch (_:UnifyError) {};
					}
					else if (fa.opt) args[i].c = TypeFunctions.mk(TConst(TNull), at, fa.name.pos);
				}
				// A local function of a member types as FunMemberClassLocal (abstract members as
				// FunMemberAbstractLocal) so `this` inside it resolves to the captured `this local.
				var localMode:CurrentFun = switch (ctx.curfun) {
					case FunStatic: FunStatic;
					case FunMemberAbstract | FunMemberAbstractLocal: FunMemberAbstractLocal;
					case _: FunMemberClassLocal;
				};
				var tf = typeFunction(ctx, args, ret, localMode, f.fExpr, p);
				ctx.typeParams = savedTypeParams;
				var fnExpr = TypeFunctions.mk(TFunction(tf), ft, p);
				// The cursor on a named local function's name answers with the variable it binds, so the answer
				// is the name's own range and not the whole function.
				if (namedVar != null && atDisplayPos(namedVar.pos)) displayVariable(ctx, namedVar, namedVar.pos);
				if (namedVar == null) fnExpr;
					else {
						// A recursive named local function is bound in two steps: `var f = null; f = <fn>`,
						// so the closure captures the (mutable) slot and a self-call sees the assigned
						// value rather than the null it was constructed with. In value position the
						// declaration is followed by a TLocal read so the whole expression evaluates to the
						// function.
						var isRec = TexprTools.referencesLocal(fnExpr, namedVar);
						var isInline = switch (kind) { case FKNamed(_, inl): inl; case _: false; };
						// The inline local function's body is stored on extra so calls inline it through
						// the fake-field machinery.
						if (isInline || localParams.length > 0) namedVar.extra = new TVarExtra(localParams, isInline ? fnExpr : null);
						var tvoid = ctx.com.basic.tvoid;
						var exprs:Array<TExpr> = [];
						var declFileIsDisplay = {
							var df = hxc.parser.Parser.displayFile;
							if (df == null) false else {
								var f = StringTools.replace(p.file, "\\", "/");
								var d = StringTools.replace(df, "\\", "/");
								f == d || StringTools.endsWith(f, "/" + d) || StringTools.endsWith(d, "/" + f);
							}
						};
						if (isRec) {
							// An inline local function cannot be recursive.
							if (isInline) ctx.com.addDiagnostic("Inline function cannot be recursive", fnExpr.pos);
							exprs.push(TypeFunctions.mk(TVarExpr(namedVar, TypeFunctions.mk(TConst(TNull), ft, p)), tvoid, p));
							exprs.push(TypeFunctions.mk(TBinop(OpAssign, TypeFunctions.mk(TLocal(namedVar), ft, p), fnExpr), ft, p));
						} else if (isInline && !declFileIsDisplay) {
							// No variable is declared, since every call inlines.
							exprs.push(TypeFunctions.mk(TBlock([]), tvoid, p));
						} else {
							exprs.push(TypeFunctions.mk(TVarExpr(namedVar, fnExpr), tvoid, p));
						}
						if (!withType.match(NoValue) && !isInline)
							exprs.push(TypeFunctions.mk(TLocal(namedVar), namedVar.type, p));
						if (exprs.length == 1) exprs[0];
						else {
							var block = TypeFunctions.mk(TBlock(exprs), namedVar.type, p);
							TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: p}, block), namedVar.type, p);
						}
					}
			case EArrayDecl(el):
				switch (el) {
					case [{expr: EFor(_, _)}] | [{expr: EWhile(_, _, _)}]:
						typeArrayComprehension(ctx, el[0], withType, p);
					case _ if (el.length > 0 && (switch (el[0].expr) { case EBinop(OpArrow, _, _): true; case _: false; })):
						typeMapDeclaration(ctx, el, withType, p);
					case _:
						// With a Map<K,V> expected, an empty literal is `new Map()`, and a literal whose one element
						// is the DISPLAY node types that element against the key type - that is what makes the first
						// key of a map declaration complete against K. Anything else is an ordinary array
						// declaration. hxc marks the gap with a null stand-in rather than an EDisplay node, so "is
						// the display node" is the position test.
						var mapKV:Null<{k:T, v:T}> = switch (withType) {
							case WithType(wt, _): switch (TypeFunctions.follow(wt)) {
								case TAbstract(a, tl) if (a.path.name == "Map" && tl.length == 2): {k: tl[0], v: tl[1]};
								case _: null;
							};
							case _: null;
						};
						var emptyMap:Null<TExpr> = null;
						if (mapKV != null && el.length == 0) {
							var tp:PlacedTypePath = {path: {tpackage: ["haxe", "ds"], tname: "Map", tparams: [], tsub: null}, pos: p};
							emptyMap = typeNew(ctx, tp, [], withType, p, false);
						}
						if (mapKV != null && el.length == 1 && atDisplayPos(el[0].pos))
							return typeExpr(ctx, el[0], WithTypeTools.withType(mapKV.k));
						if (emptyMap != null) emptyMap else {
							expectedArrayAllowDynamic = false;
							var expectedEt:Null<T> = switch (withType) {
								case WithType(wt, _): expectedArrayElement(ctx, wt);
								case _: null;
							};
							var allowDyn = expectedArrayAllowDynamic;
							var ewt = expectedEt == null ? WithTypeTools.value : WithTypeTools.withType(expectedEt);
							// An element that does not unify with the expected element type coerces through
							// an implicit abstract cast.
							var tl = [for (e in el) {
								var te = typeExpr(ctx, e, ewt);
								if (expectedEt != null) {
									try hxc.core.TypeUnification.unifyDefault(te.type, expectedEt)
									catch (_:hxc.core.TypeUnification.UnifyError) te = castOrUnify(ctx, expectedEt, te, e.pos);
								}
								te;
							}];
							// Without an expected element type the elements must share one; a mixed literal is an error
							// unless forced to Array<Dynamic> or in untyped code.
							var et = if (expectedEt != null) expectedEt
								else if (tl.length == 0) spawnMonomorph(ctx, p)
								else try unifyMinRaise(ctx, tl) catch (te:TypingError) {
									if (allowDyn || ctx.untypedMode) TypeFunctions.tDynamic;
									else {
										ctx.com.addDiagnostic("Arrays of mixed types are only allowed if the type is forced to Array<Dynamic>", te.pos);
										throw te;
									}
								};
							TypeFunctions.mk(TArrayDecl(tl), ctx.com.basic.tarray(et), p);
						}
				}
			case EObjectDecl(fields):
				// The display position sits inside the literal on no field: complete the EXPECTED
				// structure's fields. (CRStructureField via display_expr on an object declaration).
				if (hxc.parser.Parser.displayFile != null && fieldCompletionFound == null && atDisplayPos(p)) {
					// The cursor on a field name makes that field the completion SUBJECT; only a field it is not
					// on hands the answer to its own value. Testing the values first would let the stand-in the
					// parser leaves after a missing `:` swallow a cursor that is really sitting on the name.
					var covered = false;
					for (f in fields) if (!atDisplayPos(f.pos) && atDisplayPos(f.expr.pos)) { covered = true; break; }
					var anRaw = expectedAnonFromWithType(ctx, withType);
					if (anRaw == null) anRaw = structInitAnonFields(ctx, withType);
					// The cursor BETWEEN a field's `:` and its value completes against THAT field's type with an
					// empty subject - the value already written must not become the filter string.
					if (anRaw != null) for (f in fields) {
						if (atDisplayPos(f.pos)) continue;
						var between = new Position(f.pos.file, f.pos.max + 1, f.expr.pos.min - 1);
						if (between.max < between.min || !atDisplayPos(between)) continue;
						var decl = anRaw.fields.get(f.name);
						var fwt = decl != null ? WithTypeTools.withType(decl.type) : WithTypeTools.value;
						if (displayToplevelJson)
							throw new JsonToplevelCompletion(collectToplevelJson(ctx, fwt), null, between, fwt);
						if (displayToplevel)
							throw new hxc.compiler.DisplayXml.ToplevelCompletion(collectToplevel(ctx, fwt, true));
					}
					var an = covered ? null : anRaw;
					// An anon that came from a typedef reports that typedef as the origin; a bare one reports
					// itself.
					var anOrigin:Null<hxc.core.Type.ModuleType> = if (an == null) null else switch (withType) {
						case WithType(wt, _): switch (wt) { case TType(td, _): TTypeDecl(td); case _: null; };
						case _: null;
					}
					// A @:structInit class completes like a structure, from the fields its constructor accepts,
					// and reports the class as the origin.
					if (an != null && anOrigin == null) anOrigin = switch (withType) {
						case WithType(wt, _): switch (TypeFunctions.follow(wt)) { case TInst(c, _): TClassDecl(c); case _: null; };
						case _: null;
					}
					// One field whose value is a null at a NULL position is what the parser leaves behind for `{
					// ident`. With no structure expected that is not a structure completion at all - it is a
					// toplevel one keyed by the name, which is how a function body of just `{ foo
					// }` answers.
					if (an == null && !covered && fields.length == 1 && fields[0].expr.pos.min == -1
							&& fields[0].expr.expr.match(EConst(CIdent("null")))) {
						// The field name is the subject.
						if (displayToplevelJson) throw new JsonToplevelCompletion(collectToplevelJson(ctx, withType), fields[0].name, fields[0].pos, withType);
						if (displayToplevel) throw new hxc.compiler.DisplayXml.ToplevelCompletion(collectToplevel(ctx, withType, false));
					}
					if (an != null) {
						// A field already GIVEN in the literal is removed from the candidates, so only what is still
						// missing is offered.
						var given = new haxe.ds.StringMap<Bool>();
						for (f in fields) if (!atDisplayPos(f.pos)) given.set(f.name, true);
						var cand = [for (name in an.fields.keys()) if (!given.exists(name)) an.fields.get(name)];
						// Sort by declaration position descending; for an empty literal the list is then built by
						// prepending, which turns that back into ascending.
						cand.sort(function(c1, c2) return c2.pos.min - c1.pos.min);
						if (fields.length == 0) cand.reverse();
						fieldCompletionFound = [for (cf in cand) {
							kind: cf.kind.match(Method(_)) ? "method" : "var",
							name: cf.name,
							type: hxc.core.TPrinting.sTypeStr(cf.type),
							doc: Ast.genDocTextOpt(cf.doc)
						}];
						// The JSON answer is the same collection under kind 1 (CRStructureField), keyed by the field
						// name the cursor is on.
						var subjName:Null<String> = null;
						var subjPos:Null<Position> = null;
						for (f in fields) if (atDisplayPos(f.pos)) { subjName = f.name; subjPos = f.pos; break; }
						var doff = hxc.parser.Parser.displayOffset;
						var insert = new Position(p.file, doff, doff);
						jsonFieldCompletion = {
							entries: [for (cf in cand) {cf: cf, scope: CFSMember, originClass: null, originAnon: null, builtIn: false}],
							receiver: null,
							insertPos: insert,
							originModuleType: anOrigin,
							noSort: true,
							kind: 1,
							subjectName: subjName,
							subjectPos: subjPos != null ? subjPos : insert
						};
					}
				}
				// A field may appear only once in an object literal.
				{
					var seen = new haxe.ds.StringMap<Bool>();
					for (f in fields) {
						if (seen.exists(f.name)) throw new TypingError("Duplicate field in object declaration : " + f.name, f.pos);
						seen.set(f.name, true);
					}
				}
				// A `{...}` literal against a @:structInit class types as a call to that class's
				// constructor, matching fields to constructor arguments by name.
				var scHit = switch (withType) {
					case WithType(wt, _): switch (TypeFunctions.follow(wt)) {
						case TInst(c, tl) if (TypeFunctions.hasMeta(":structInit", c.meta)): {c: c, tl: tl, t: TypeFunctions.follow(wt)};
						case _: null;
					};
					case _: null;
				};
				var scSig = scHit == null ? null : switch (try findConstructorType(ctx, scHit.c, scHit.tl) catch (_:Dynamic) null) {
					case null: null;
					case ct: switch (TypeFunctions.follow(ct)) { case TFun(sig): sig; case _: null; };
				};
				// A @:structInit target without a constructor (an interface carrying the meta) reports at
				// the literal and types plainly.
				// RAISED so the var-initializer recovery records it and no further unify runs.
				if (scHit != null && scSig == null)
					throw new TypingError(hxc.core.Globals.sTypePath(scHit.c.path) + " does not have a constructor", p);
				if (scHit != null && scSig != null) {
					// Type each provided field against its constructor-arg type in the object literal
					// source order; build the call in the constructor declared arg order, hoisting a field
					// into a temp when a later-source field has a side effect, so initializers still run in
					// source order.
					var argByName = new haxe.ds.StringMap<TSignatureArg>();
					for (arg in scSig.args) argByName.set(arg.name, arg);
					// Each constructor argument becomes a synthetic field positioned at that argument's own VAR,
					// or at the constructor name when the constructor has no body, and a cursor on the field name
					// is then answered with it. That is how a field of a @:structInit class reports its own
					// declaration.
					if (hxc.parser.Parser.displayFile != null && atDisplayPos(p)) {
						if (scHit.c.constructor == null) try ensureStructInitCtor(ctx, scHit.c) catch (_:Dynamic) {}
						var ctor = scHit.c.constructor;
						if (ctor != null) {
							var argPos = new haxe.ds.StringMap<Position>();
							var tfArgs = ctor.expr == null ? null : switch (ctor.expr.expr) {
								case TFunction(fn): fn.args;
								case _: null;
							}
							for (i in 0...scSig.args.length) {
								var nm = scSig.args[i].name;
								argPos.set(nm, tfArgs != null && i < tfArgs.length ? tfArgs[i].v.pos : ctor.namePos);
							}
							for (f in fields) if (atDisplayPos(f.pos)) {
								var arg = argByName.get(f.name);
								var ap = argPos.get(f.name);
								if (arg != null && ap != null) displayAnonField(TypeFunctions.mkField(f.name, arg.t, ap, ap));
							}
						}
					}
					var byName = new haxe.ds.StringMap<TExpr>();
					for (f in fields) {
						var arg = argByName.get(f.name);
						var te = typeExpr(ctx, f.expr, arg != null ? WithTypeTools.withStructureField(arg.t, f.name) : WithTypeTools.value);
						if (arg != null) te = castOrUnify(ctx, arg.t, te, te.pos);
						byName.set(f.name, te);
					}
					var evars:Array<TExpr> = [];
					var hadSideEffect = false;
					var fi = fields.length - 1;
					while (fi >= 0) {
						var fname = fields[fi].name;
						var te = byName.get(fname);
						switch (te.expr) {
							case TConst(_) | TTypeExpr(_) | TFunction(_):
							case _:
								if (hadSideEffect) {
									var v = TypeFunctions.allocVar(VGenerated, "`", te.type, te.pos);
									evars.unshift(TypeFunctions.mk(TVarExpr(v, te), te.type, te.pos));
									byName.set(fname, TexprTools.makeLocal(v, te.pos));
								} else if (hasSideEffect(te)) {
									hadSideEffect = true;
								}
						}
						fi--;
					}
					// A field the literal omits takes the constructor's declared default value for that
					// argument; only an argument with no default falls back to null.
					var ctorTf:Null<TFunc> = null;
					{
						var ctorCf = try TypeFunctions.getConstructorClass(scHit.c, scHit.tl).cf catch (_:Dynamic) null;
						if (ctorCf != null) {
							if (ctorCf.expr == null) try TypeFields.forceFieldBody(ctx.com, scHit.c, ctorCf) catch (_:Dynamic) {};
							if (ctorCf.expr != null) switch (ctorCf.expr.expr) { case TFunction(tf): ctorTf = tf; case _: }
						}
					}
					var el:Array<TExpr> = [];
					var missing:Array<String> = [];
					for (arg in scSig.args) {
						var te = byName.get(arg.name);
						if (te != null) el.push(te);
						else {
							var dflt:Null<TExpr> = null;
							if (ctorTf != null) for (a in ctorTf.args) if (a.v.name == arg.name && a.c != null) { dflt = a.c; break; }
							if (dflt != null) el.push(dflt);
							else if (arg.opt) el.push(TexprTools.makeNull(arg.t, p));
							else { missing.push(arg.name); el.push(TexprTools.makeNull(arg.t, p)); }
						}
					}
					if (missing.length > 0) {
						missing.sort(function(x, y) return x < y ? 1 : (x > y ? -1 : 0));
						var msg = missing.length == 1 ? "Object requires field " + missing[0] : "Object requires fields: " + missing.join(", ");
						if (ctx.inCallArgs) throw new TypingError(msg, p) else ctx.com.addDiagnostic(msg, p);
					}
					var enew = TypeFunctions.mk(TNew(scHit.c, scHit.tl, el), scHit.t, p);
					if (evars.length == 0) enew else TypeFunctions.mk(TBlock(evars.concat([enew])), scHit.t, p);
				} else {
					var tfields:Array<TObjectField> = [];
					var anonFields = new haxe.ds.StringMap<TClassField>();
					var expected = expectedAnonFromWithType(ctx, withType);
					// A Dynamic<T> expectation types every field at T instead of a per-field lookup.
					var dynParam:Null<T> = switch (withType) {
						case WithType(wt, _): switch (expectedAnonFromType(ctx, wt, [])) {
							case ODKDynamic(dt): dt;
							case _: null;
						};
						case _: null;
					};
					for (f in fields) {
						var ef = dynParam == null && expected != null ? expected.fields.get(f.name) : null;
						var ft:Null<T> = dynParam != null ? dynParam : (ef != null ? ef.type : null);
						// The cursor on a field name answers with the field it matched in the EXPECTED structure, so
						// it reports that field's declaration and its declared type rather than the literal's own.
						if (ef != null && atDisplayPos(f.pos)) displayAnonField(ef);
						var fwt = ft != null ? WithTypeTools.withStructureField(ft, f.name) : WithTypeTools.value;
						var te = typeExpr(ctx, f.expr, fwt);
						// With no expected structure the field answers with itself, typed from its value.
						// The field is built (and displayed) whether or not the name is a valid identifier;
						// only the anon entry below is guarded.
						if (expected == null && dynParam == null && atDisplayPos(f.pos))
							displayAnonField(TypeFunctions.mkField(f.name, te.type, Ast.punion(f.pos, te.pos), f.pos));
						// Against an expected field type, coerce the value to it so an implicit abstract cast
						// (e.g. Int -> Int64 @:from) applies, matching the field's declared type.
						if (ft != null) {
							te = castOrUnify(ctx, ft, te, te.pos);
							// A non-null value against a nullable expectation wraps so the runtime
							// representation stays nullable.
							if (TypeFunctions.isNull(ft) && !TypeFunctions.isNull(te.type))
								te = TypeFunctions.mk(TCast(te, null), ctx.com.basic.tnull(te.type), te.pos);
							// The stored field expr carries the EXPECTED type: a loose unify that is not
							// strictly equal wraps in a plain cast, so e.g. a String value behind a
							// Dynamic<Dynamic> field reads as Dynamic downstream (inline constructors fold
							// on that strict equality).
							try TypeUnification.typeEqKind(EqStrict, te.type, ft)
							catch (_:UnifyError) te = TypeFunctions.mk(TCast(te, null), ft, te.pos);
						}
						tfields.push({key: {name: f.name, pos: f.pos, quotes: f.quotes}, expr: te});
						// Against an expected structure the field takes the expected type (the value was
						// just coerced to it), so e.g. `({f: -1} : {f:Float})` is `{f:Float}`, not
						// `{f:Int}`.
						// A field whose name is not a valid identifier (a quoted key like "x-bar") is a
						// reflection-only field: it stays in the runtime object but not in the structure
						// type, and never counts as an "extra field".
						if (isValidIdentifier(f.name)) {
							// The anon field records the typed expr's type, which the strict-cast wrap
							// above has already aligned to any expectation. pos spans the whole `name:
							// expr` pair and only namePos is the name; --json prints pos as the
							// structure field's span.
							var anonField = TypeFunctions.mkField(f.name, te.type, Ast.punion(f.pos, te.pos), f.pos);
							if (ef != null && TypeFunctions.hasClassFieldFlag(ef, CfFinal)) TypeFunctions.addClassFieldFlag(anonField, CfFinal);
							anonFields.set(f.name, anonField);
						}
					}
					// The status ref is kept so the end of the enclosing function can close it.
					var anonStatus = new hxc.core.Ref(Const);
					ctx.opened.unshift(anonStatus);
					var t = TypeFunctions.mkAnon(anonStatus, anonFields);
					// A literal against an expected structure must provide every non-optional expected
					// field and nothing more. Recorded, not raised, so every violation is reported (and a
					// macro Context.typeof raises through the record).
					if (expected != null && !ctx.untypedMode) {
						// Inside call arguments the violation raises so the caller annotates it with the
						// parameter name; outside it is recorded.
						inline function reportOrRaise(msg:String, pos:Position):Void {
							if (ctx.inCallArgs) throw new TypingError(msg, pos);
							ctx.com.addDiagnostic(msg, pos);
						}
						var missing:Array<String> = [];
						for (n in expected.fields.keys()) {
							var ef = expected.fields.get(n);
							if (!TypeFunctions.hasMeta(":optional", ef.meta) && !anonFields.exists(n)) missing.push(n);
						}
						// Missing fields are listed in descending name order.
						missing.sort(function(x, y) return x < y ? 1 : (x > y ? -1 : 0));
						if (missing.length == 1) reportOrRaise("Object requires field " + missing[0], p);
						else if (missing.length > 1) reportOrRaise("Object requires fields: " + missing.join(", "), p);
						// Extra fields accumulate by prepending, so they report in reverse source order.
						var i = fields.length - 1;
						while (i >= 0) {
							var f = fields[i];
							if (!expected.fields.exists(f.name) && isValidIdentifier(f.name))
								reportOrRaise(hxc.core.TPrinting.sTypeStr(t) + " has extra field " + f.name, f.pos);
							i--;
						}
					}
					TypeFunctions.mk(TObjectDecl(tfields), t, p);
				}
			case ETry(e1, catches):
				var te = typeExpr(ctx, e1, withType);
				var tcatches:Array<TCatch> = [];
				var bodies = [te];
				for (c in catches) {
					var th = c.type != null ? c.type : defaultCatchTypeHint(c.pos);
					var catchType = Typeload.loadComplexType(ctx.com, ctx.typeParams, th);
					var normalizedCatchType = normalizeCatchType(ctx, catchType, p, th.pos, c.expr.pos);
					checkCatchUnreachable(tcatches, normalizedCatchType, c.expr.pos);
					var restore = saveLocals(ctx);
					checkLocalVariableName(ctx, c.name.name, TVOCatchVariable, c.name.pos);
					// The catch var is declared at the var name's position, not the catch clause's.
					var v = addLocal(ctx, VUser(TVOCatchVariable), c.name.name, catchType, c.name.pos);
					// Display on the catch variable's own name.
					if (atDisplayPos(c.name.pos)) displayVariable(ctx, v, c.name.pos);
					var cbody = typeExpr(ctx, c.expr, withType);
					v.type = normalizedCatchType;
					restore();
					tcatches.push({v: v, expr: cbody});
					bodies.push(cbody);
				}
				// The try's result type: a STATEMENT try is Void with no branch unification (a catch calling a
				// not-yet-inferred method must not bind that method's open return mono); against an expected
				// monomorph or Void the source decides; a CONCRETE expectation casts the body and every catch
				// individually (the implicit-cast call lands inside each branch, so the analyzer can drop a
				// pure unused branch value while keeping the try shell); otherwise the branches unify to a
				// common type.
				var tryT = switch (withType) {
					case NoValue: ctx.com.basic.tvoid;
					case WithType(wt, src) if (switch (TypeFunctions.follow(wt)) { case TMono(_): true; case wtf: isVoid(wtf); }):
						unifyMinForTypeSource(ctx, bodies, src);
					case WithType(wt, _):
						te = castOrUnify(ctx, wt, te, te.pos);
						for (tc in tcatches) tc.expr = castOrUnify(ctx, wt, tc.expr, tc.expr.pos);
						wt;
					case _: unifyMin(ctx, bodies);
				};
				TypeFunctions.mk(TTry(te, tcatches), tryT, p);
			case ECast(e1, ct):
				var te = typeExpr(ctx, e1, WithTypeTools.value);
				if (ct == null) {
					TypeFunctions.mk(TCast(te, null), spawnMonomorph(ctx, p), p);
				} else {
					var t = Typeload.loadComplexType(ctx.com, ctx.typeParams, ct);
					// The runtime-checked cast target: an abstract without @:runtimeValue resolves to its
					// underlying type, so the eval safe-cast check sees the concrete class (or the @:runtimeValue
					// basic). A runtime cast can only check a nominal type, so the target has to reduce to a class
					// or an enum, its parameters have to be erased (they do not exist at runtime), and a type
					// parameter is not a target at all. All three report at the type, not the cast expression.
					function checkParam(pt:T):Void switch (TypeFunctions.follow(pt)) {
						// An unbound monomorph means Dynamic was never bound (issue #4675).
						case TMono(_):
						case TDynamic(_):
						case _: throw new TypingError("Cast type parameters must be Dynamic", ct.pos);
					}
					function loop(t:T):Null<ModuleType> return switch (TypeFunctions.follow(t)) {
						case TInst(c, params):
							for (pt in params) checkParam(pt);
							if (c.kind.match(KTypeParameter(_)))
								throw new TypingError("Can't cast to a type parameter", ct.pos);
							TClassDecl(c);
						case TEnum(en, params):
							for (pt in params) checkParam(pt);
							TEnumDecl(en);
						case TAbstract(a, params) if (TypeFunctions.hasMeta(":runtimeValue", a.meta)):
							for (pt in params) checkParam(pt);
							TAbstractDecl(a);
						case TAbstract(a, params): loop(TypeFunctions.getUnderlyingType(a, params));
						case _: throw new TypingError("Cast type must be a class or an enum", ct.pos);
					};
					TypeFunctions.mk(TCast(te, loop(t)), t, p);
				}
			case EIs(e1, th):
				// `x is T` is sugar for Std.isOfType(x, T); T must be a named type path (its type
				// parameters are ignored at runtime).
				switch (th.ct) {
					case CTPath(tp):
						if (tp.tparams.length > 0) ctx.com.addDiagnostic("Type parameters are not supported for the `is` operator", th.pos);
						var e = typeExpr(ctx, e1, WithTypeTools.value);
						var mt = Typeload.resolveTypePath(ctx.com, {pack: tp.tpackage, name: tp.tname}, tp.tsub, th.pos);
						// The cursor on the type of an `is` answers with that type, not with the whole expression,
						// and it answers the DECLARED type - the redirect below is only for codegen.
						if (atDisplayPos(th.pos)) displayModuleType(ctx.com, mt, th.pos);
						switch (mt) {
							case TAbstractDecl(a) if (a.impl != null): mt = TClassDecl(a.impl);
							case _:
						}
						var eType = TexprTools.makeTypeExpr(mt, th.pos);
						var std = switch (Typeload.resolveTypePath(ctx.com, {pack: [], name: "Std"}, null, p)) {
							case TClassDecl(c): c;
							case _: throw new TypingError("Std is not a class", p);
						};
						var cf = std.statics.get("isOfType");
						if (cf == null) throw new TypingError("Field not found : isOfType", p);
						// The Std.isOfType reference is built at a zero-range position (max equals min),
						// not at the full expression range.
						var stdIs = TexprTools.makeStaticField(std, cf, hxc.core.Globals.mkZeroRangePos(p));
						TypeFunctions.mk(TCall(stdIs, [e, eType]), ctx.com.basic.tbool, p);
					case _:
						ctx.com.addDiagnostic("Unsupported type for `is` operator", th.pos);
						TexprTools.makeBool(ctx.com.basic, false, p);
				}
			case EDisplay(e1, dk):
				// The display SUBJECT is typed and answered from. hxc answers from POSITIONS, so a marked
				// node only has to type through; a DKDot is a field completion on its inner expression,
				// which is the one shape a MACRO can return - hxc carries that request as an empty field
				// name.
				switch (dk) {
					case DKDot: typeExpr(ctx, new Expr(EField(e1, "", EFNormal), p), withType);
					case _: typeExpr(ctx, e1, withType);
				}
			case ECheckType(e1, th):
				var t = Typeload.loadComplexType(ctx.com, ctx.typeParams, th);
				// A `(v : C)` hint in a body forces C's build macros like any class reference does
				// (building an instance runs the class build past PBuildClass); expression typing is late
				// enough.
				switch (TypeFunctions.follow(t)) {
					case TInst(hc, _): hxc.eval.EvalMacro.ensureBuilt(ctx.com, hc);
					case _:
				}
				var te = typeExpr(ctx, e1, WithTypeTools.withType(t));
				var te2 = try castOrUnify(ctx, t, te, p) catch (err:TypingError) {
					switch (TypeFunctions.follow(t)) {
						case TAnon(_) if (err.message.indexOf(" should ") >= 0):
							ctx.com.addDiagnostic(err.message, err.pos, err.depth);
							te;
						case _:
							throw err;
					}
				};
				// PHYSICAL identity, not structural. A monomorph bound to t is still a distinct TMono
				// object, so the reification cast is kept (matters on cpp where throwing (getNull():Int)
				// must materialize the int).
				(te2.type == t) ? te2 : TypeFunctions.mk(TCast(te2, null), t, p);
		};
		DebugDump.typed("typeExpr", typed);
		// Wraps the expression the preprocessor decided is the display subject; it and then answers with
		// the toplevel collection. hxc has no EDisplay node in the typer, so the decision is recorded and
		// read back here, at the same point and with the same expected type.
		if (markedDisplay == e) { markedDisplay = null; raiseToplevelMarked(ctx, e, withType); }
		if (displayDefinition && atDisplayPos(e.pos)) checkDisplayDefinition(ctx, typed);
		if ((displayHover || displayTypeDefinition) && atExprHoverPos(e.pos)) checkDisplayHover(ctx, typed, withType);
		if ((displayUsage || displayImplementation) && atDisplayPos(e.pos)) captureUsageTarget(typed, ctx);
		return typed;
	}

	// Legacy --display @position: the innermost typed expression enclosing the display offset yields its
	// declaration position; post-order typing makes the first enclosing match the innermost.
	public static var displayDefinition:Bool = false;
	// First (innermost) hit wins; recorded rather than raised so the surrounding call-argument
	// recovery cannot swallow it. When the cursor is on the unresolved name the error is the answer -
	// the request reports the identifier rather than returning positions. hxc throws there, but a
	// field-body recovery catches it and the answer path would then return an empty position list, so
	// the error would never surface. Recording that the SUBJECT failed is what lets the answer defer
	// to it. Deliberately not a general has-error test: an error elsewhere must not suppress an
	// answer.
	public static var displaySubjectError:Null<{msg:String, pos:Position}> = null;

	public static var displayFound:Null<Array<Position>> = null;

	// Legacy --display @type: the innermost typed expression enclosing the display offset reports its type;
	// post-order typing makes the first enclosing hit the innermost.
	public static var displayHover:Bool = false;
	// The typed expression is kept alongside so the JSON protocol can build the full hover item (field
	// access, local, enum field).
	// hexpected: the with-type at the hover point, encoded as `expected`.
	// tctx is the scope the hovered expression was typed in; the isQualified retype needs it.
	public static var hoverFound:Null<{t:T, p:Position, ?e:TExpr, ?wt:hxc.core.WithType.WithType, ?tctx:TyperContext, ?mt:hxc.core.Type.ModuleType}> = null;

	// DMTypeDefinition shares the hover capture; the report resolves the captured type's declaration
	// position.
	public static var displayTypeDefinition:Bool = false;

	// DMSignature: a call whose argument span contains the display position captures its callee's
	// signatures and the active argument.
	public static var displaySignature:Bool = false;
	// The span of the call the signature was recorded from; a nested call replaces it only when its own
	// span is strictly inside (the innermost call is the marked one).
	public static var signatureCallPos:Null<Position> = null;
	public static var signatureFound:Null<{sigs:Array<{args:Array<hxc.core.Type.TSignatureArg>, ret:T, doc:hxc.ast.Ast.Documentation}>, activeArg:Int}> = null;

	// An EArray under signature display: an Array reports one (index:Int) signature returning its element,
	// and an abstract reports its @:arrayAccess overloads with the `this` argument dropped. Anything else
	// reports none.
	// A class or an abstract with an implementation contributes its constructor and that constructor's
	// overloads.
	static function checkNewSignatureDisplay(ctx:TyperContext, tp:PlacedTypePath, el:Array<Expr>, p:Position):Void {
		var active = 0;
		var marked = false;
		for (i in 0...el.length) switch (el[i].expr) {
			case EDisplay(inner, DKMarked):
				active = i;
				el[i] = inner;
				marked = true;
				break;
			case _:
		}
		// An empty argument list counts as marked, so the parentheses on their own are enough to ask for
		// the signature.
		if (!marked && !(el.length == 0 && atDisplayPos(p))) return;
		var t = try Typeload.loadInstance(ctx.com, ctx.typeParams, tp.path, tp.pos, true) catch (_:Dynamic) return;
		// A type parameter is constructed through its Constructible constraint, and the function that
		// constraint names is the signature.
		switch (TypeFunctions.follow(t)) {
			case TInst(cl, _) if (cl.kind.match(KTypeParameter(_))):
				var ctl = switch (cl.kind) { case KTypeParameter(x): x; case _: []; };
				var csig = try getConstructibleConstraint(ctx, ctl, p) catch (_:Dynamic) null;
				signatureFound = {sigs: csig == null ? [] : [{args: csig.args, ret: csig.ret, doc: null}], activeArg: active};
				return;
			case _:
		}
		var c:Null<TClass> = switch (TypeFunctions.follow(t)) {
			case TInst(cl, _): cl;
			case TAbstract(a, _) if (a.impl != null): a.impl;
			case _: null;
		};
		if (c == null) { signatureFound = {sigs: [], activeArg: active}; return; }
		var ctor = c.constructor;
		var cur = c;
		while (ctor == null && cur.superClass != null) { cur = cur.superClass.c; ctor = cur.constructor; }
		if (ctor == null) { signatureFound = {sigs: [], activeArg: active}; return; }
		var sigs = [];
		inline function add(cf:TClassField):Void switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): sigs.push({args: sig.args, ret: sig.ret, doc: cf.doc});
			case _:
		}
		add(ctor);
		for (o in ctor.overloads) add(o);
		signatureFound = {sigs: sigs, activeArg: active};
	}

	static function checkArraySignatureDisplay(ctx:TyperContext, e1:Expr, e2:Expr, withType:WithType, p:Position):Void {
		var active = 0;
		switch (e2.expr) {
			case EDisplay(inner, DKMarked): active = 0;
			case _: return; // Only the marked index asks for a signature
		}
		// Maps bottom-up under `not !found`, so the INNERMOST node holding the cursor wins whether it is
		// a call or an array access. hxc types the outer call first, so this may only replace a record
		// whose span strictly contains it.
		if (signatureFound != null && signatureCallPos != null
			&& !(p.min >= signatureCallPos.min && p.max <= signatureCallPos.max
				&& (p.min > signatureCallPos.min || p.max < signatureCallPos.max))) return;
		var te1 = try typeExpr(ctx, e1, WithTypeTools.value) catch (_:TypingError) return;
		signatureCallPos = p;
		switch (TypeFunctions.follow(te1.type)) {
			case TInst(c, [t]) if (c.path.pack.length == 0 && c.path.name == "Array"):
				signatureFound = {
					// This literal doc is attached to the array index.
					sigs: [{args: [{name: "index", opt: false, t: ctx.com.basic.tint}], ret: t, doc: Ast.docFromString("The array index")}],
					activeArg: active
				};
			case TAbstract(a, tl):
				if (a.impl != null) hxc.eval.EvalMacro.ensureBuilt(ctx.com, a.impl);
				var sigs = [];
				for (cf in a.array) switch (TypeFunctions.follow(cf.type)) {
					case TFun(sig) if (sig.args.length > 0):
						// A VOID-returning @:arrayAccess is not a candidate where a value is wanted, which
						// is every position but NoValue.
						var retVoid = switch (TypeFunctions.follow(sig.ret)) {
							case TAbstract(va, _): va.path.pack.length == 0 && va.path.name == "Void";
							case _: false;
						};
						if (retVoid && !withType.match(NoValue)) continue;
						var rest = sig.args.slice(1);
						sigs.push({
							args: ([for (x in rest) ({name: x.name, opt: x.opt, t: TypeFunctions.applyParams(a.params, tl, x.t)} : hxc.core.Type.TSignatureArg)] : Array<hxc.core.Type.TSignatureArg>),
							ret: TypeFunctions.applyParams(a.params, tl, sig.ret),
							doc: cf.doc
						});
					case _:
				}
				signatureFound = {sigs: sigs, activeArg: active};
			case _:
				signatureFound = {sigs: [], activeArg: active};
		}
	}

	// A constructor in a PATTERN resolves against the pattern's expected type, not as a free
	// expression, so an enum whose constructors are not imported still reports its signature.
	public static function patternConstructorSignature(en:TEnum, tl:TParams, ef:TEnumField, params:Array<Expr>, p:Position):Void {
		var active = 0;
		for (i in 0...params.length) switch (params[i].expr) {
			case EDisplay(inner, DKMarked): active = i; params[i] = inner; break;
			case _:
		}
		if (signatureFound != null && signatureCallPos != null
			&& !(p.min >= signatureCallPos.min && p.max <= signatureCallPos.max
				&& (p.min > signatureCallPos.min || p.max < signatureCallPos.max))) return;
		switch (TypeFunctions.follow(TypeFunctions.applyParams(en.params, tl, ef.type))) {
			case TFun(sig):
				signatureFound = {sigs: [{args: sig.args, ret: sig.ret, doc: ef.doc}], activeArg: active};
				signatureCallPos = p;
			case _:
		}
	}

	public static function checkSignatureDisplay(ctx:TyperContext, e1:Expr, params:Array<Expr>, p:Position):Void {
		// The active argument is the index of the one the PARSER marked, and the marker is stripped
		// before anything is typed, since a display node has no typing of its own. Counting finished
		// arguments instead would put the cursor on the next parameter as soon as it leaves the last one.
		var active = 0;
		for (i in 0...params.length) switch (params[i].expr) {
			case EDisplay(inner, DKMarked):
				active = i;
				params[i] = inner;
				break;
			case _:
		}
		// The display position must sit inside the argument span (after the callee).
		var off = hxc.parser.Parser.displayOffset;
		if (!atDisplayPos(p) || off <= e1.pos.max) return;
		// Marks the INNERMOST call holding the cursor, and only that one. hxc types the outer call first,
		// so a nested call may only replace a record whose span strictly contains its own.
		if (signatureFound != null && signatureCallPos != null
			&& !(p.min >= signatureCallPos.min && p.max <= signatureCallPos.max
				&& (p.min > signatureCallPos.min || p.max < signatureCallPos.max))) return;
		// `$type` under DMSignature: one (expression : <mono>) signature carrying its own documentation.
		switch (e1.expr) {
			case EConst(CIdent("$type")):
				signatureFound = {
					sigs: [{args: [{name: "expression", opt: false, t: TypeFunctions.mkMono()}],
						ret: TypeFunctions.mkMono(),
						doc: Ast.docFromString("Outputs type of argument as a warning and uses argument as value")}],
					activeArg: active
				};
				signatureCallPos = p;
				return;
			case _:
		}
		// A `super(...)` call reports the SUPER's constructor signatures.
		switch (e1.expr) {
			case EConst(CIdent("super")):
				var sup = ctx.curclass == null ? null : ctx.curclass.superClass;
				var ctor = sup == null ? null : superConstructor(sup.c);
				if (ctor != null) {
					var sigs = [];
					inline function addCtor(cf:TClassField) switch (TypeFunctions.follow(cf.type)) {
						case TFun(sig): sigs.push({args: sig.args, ret: sig.ret, doc: cf.doc});
						case _:
					}
					addCtor(ctor);
					for (o in ctor.overloads) addCtor(o);
					signatureFound = {sigs: sigs, activeArg: active};
					signatureCallPos = p;
				}
				return;
			case _:
		}
		// `f.bind(` reports the signature of F ITSELF, not of the magic bind field, so the callee is the
		// receiver whenever it follows to a function.
		var callee:Null<TExpr> = switch (e1.expr) {
			case EField(recv, "bind", _):
				var te = try typeExpr(ctx, recv, WithTypeTools.value) catch (_:TypingError) null;
				(te != null && TypeFunctions.follow(te.type).match(TFun(_))) ? te : null;
			case _: null;
		};
		if (callee == null) callee = try typeExpr(ctx, e1, WithTypeTools.value) catch (_:TypingError) return;
		// Unwrap @:callable abstracts.
		function followCallable(t:T):T {
			return switch (TypeFunctions.follow(t)) {
				case TAbstract(a, tl) if (TypeFunctions.hasMeta(":callable", a.meta)):
					followCallable(TypeFunctions.applyParams(a.params, tl, a.thisType));
				case t2: t2;
			};
		}
		// The field's own type first, then its overloads reversed, and each one dropped when the calling
		// scope cannot reach it. A "wacky" overload (the @:overload metadata kind, which carries no
		// CfOverload flag) documents itself from the MAIN field, since the metadata form has no doc of
		// its own.
		var cands:Array<{args:Array<hxc.core.Type.TSignatureArg>, ret:T, doc:hxc.ast.Ast.Documentation}> = [];
		// A MACRO callee resolves to its macro-world signature first.
		switch (callee.expr) {
			case TField(_, FStatic(mc, mcf) | FInstance(mc, _, mcf)):
				var mt2 = hxc.eval.EvalMacro.macroFieldDisplayType(ctx.com, mc, mcf);
				if (mt2 != null) callee = TypeFunctions.mk(callee.expr, mt2, callee.pos);
			case _:
		}
		function addCand(t:T, doc:hxc.ast.Ast.Documentation):Void switch (followCallable(t)) {
			case TFun(sig): cands.push({args: sig.args, ret: sig.ret, doc: doc});
			// What is not a function after the @:callable unwrap is an error naming the type, not a silently
			// empty signature list.
			case t2: throw new TypingError("Not a callable type: " + hxc.core.TPrinting.sTypeStr(t2), p);
		}
		switch (callee.expr) {
			case TField(_, FStatic(c, cf) | FInstance(c, _, cf)):
				var stat = switch (callee.expr) { case TField(_, FStatic(_, _)): true; case _: false; };
				var wacky = !TypeFunctions.hasClassFieldFlag(cf, CfOverload);
				var all = [cf];
				var ovl = cf.overloads.copy();
				ovl.reverse();
				for (o in ovl) all.push(o);
				for (o in all)
					if (hxc.typing.Fields.canAccess(ctx, c, o, stat))
						addCand(o == cf ? callee.type : o.type, wacky ? cf.doc : o.doc);
			// A closure over a known class goes through the same access filter; an anonymous one has no
			// class to check against.
			case TField(_, FClosure(cp, cf)) if (cp != null):
				var wacky = !TypeFunctions.hasClassFieldFlag(cf, CfOverload);
				var all = [cf];
				var ovl = cf.overloads.copy();
				ovl.reverse();
				for (o in ovl) all.push(o);
				for (o in all)
					if (hxc.typing.Fields.canAccess(ctx, cp.c, o, false))
						addCand(o == cf ? callee.type : o.type, wacky ? cf.doc : o.doc);
			case TField(_, FAnon(cf) | FClosure(_, cf)):
				var wacky = !TypeFunctions.hasClassFieldFlag(cf, CfOverload);
				addCand(callee.type, cf.doc);
				var ovl = cf.overloads.copy();
				ovl.reverse();
				for (o in ovl) addCand(o.type, wacky ? cf.doc : o.doc);
			case _:
				addCand(callee.type, null);
		}
		if (cands.length == 0) return;
		// A display position past the last written argument gets a null appended so argument unification
		// can fail on arity instead of silently accepting.
		var el = params.copy();
		if (el.length > 0 && active >= el.length) el.push(new Expr(EConst(CIdent("null")), Position.nullPos));
		// An overload survives when the arguments written so far still unify with it (too FEW arguments
		// is expected, not a mismatch). The accumulator prepends, so what survives comes out reversed;
		// nothing surviving keeps the lot.
		var kept = [];
		for (cand in cands) {
			var ok = try { unifyCallArgsForSignature(ctx, el, cand.args, cand.ret, p); true; }
				catch (err:TypingError) err.message.indexOf("Not enough arguments") >= 0
				catch (_:Dynamic) false;
			if (ok) kept.unshift(cand);
		}
		signatureFound = {sigs: kept.length == 0 ? cands : kept, activeArg: active};
		signatureCallPos = p;
	}

	// The keep test runs the real argument unification but must leave nothing behind: it types
	// the argument expressions, and a display hook firing inside one would answer the request
	// with a completion from a candidate that is only being probed.
	static function unifyCallArgsForSignature(ctx:TyperContext, el:Array<Expr>, args:Array<hxc.core.Type.TSignatureArg>, r:T, p:Position):Void {
		var sSig = displaySignature, sFound = signatureFound;
		var sHover = displayHover, sDef = displayDefinition, sTop = displayToplevel;
		displaySignature = false; displayHover = false; displayDefinition = false; displayToplevel = false;
		try {
			hxc.typing.Calls.unifyCallArgs(ctx, el, args, r, p);
		} catch (e:haxe.Exception) {
			displaySignature = sSig; signatureFound = sFound;
			displayHover = sHover; displayDefinition = sDef; displayToplevel = sTop;
			throw e;
		}
		displaySignature = sSig; signatureFound = sFound;
		displayHover = sHover; displayDefinition = sDef; displayToplevel = sTop;
	}

	public static function atHoverPos(p:Position):Bool {
		return atDisplayPos(p);
	}

	// DMHover picks the display subject with a STRICT upper bound. A cursor sitting exactly at the end of a
	// node is therefore outside it and the ENCLOSING one answers: `"x".length|` is a question about the
	// call it is an argument of, not about length.
	public static function atExprHoverPos(p:Position):Bool {
		if (hxc.parser.Parser.displaySuppressed || exprDisplayOff) return false;
		var df = hxc.parser.Parser.displayFile;
		var off = hxc.parser.Parser.displayOffset;
		if (df == null || off < 0) return false;
		if (!(p.min <= off && off < p.max)) return false;
		var f = StringTools.replace(p.file, "\\", "/");
		var d = StringTools.replace(df, "\\", "/");
		return f == d || StringTools.endsWith(f, "/" + d) || StringTools.endsWith(d, "/" + f);
	}

	// The whole-literal record a desugared construct leaves no typed node for. Same
	// narrowest-wins rule as checkDisplayHover, so a real node inside the span still wins.
	static function noteLiteralHover(ctx:TyperContext, te:TExpr, p:Position, ?withType:hxc.core.WithType.WithType):Void {
		if (hoverFound != null && (p.max - p.min) >= (hoverFound.p.max - hoverFound.p.min)) return;
		hoverFound = {t: te.type, p: p, e: te, wt: withType, tctx: ctx};
	}

	// Typing is POST-ORDER, so by the time an enclosing node runs this its inner nodes have
	// already run it themselves, and the descent below re-walks exactly what they covered. On a
	// chain of N nodes that all enclose the cursor - N nested parentheses is the plain case -
	// that is O(N^2), and a display request on a deeply nested expression stops answering at all
	// while a plain compile of the same file is unaffected. Skipping a node this request already
	// walked cannot change the answer: the winner is the SMALLEST enclosing range, the comparison
	// below is strict, so a second visit to the same node never updates what the first recorded.
	// The descent itself has to stay - a synthesized sub-node never runs the tail check on its
	// own, which is what it is here for.
	static var hoverWalked:haxe.ds.ObjectMap<TExpr, Bool> = new haxe.ds.ObjectMap();

	static function checkDisplayHover(ctx:TyperContext, te:TExpr, ?withType:hxc.core.WithType.WithType):Void {
		if (hoverWalked.exists(te)) return;
		hoverWalked.set(te, true);
		switch (te.expr) {
			// Recurse only into a PROPER sub-range: a synthetic receiver (the module type expr
			// under an unqualified enum constructor) reuses the whole ident's position and must
			// not shadow the field the cursor is on.
			case TField(e1, _) | TCall(e1, _) | TCast(e1, _) | TParenthesis(e1)
				if (atExprHoverPos(e1.pos) && (e1.pos.min > te.pos.min || e1.pos.max < te.pos.max)):
				checkDisplayHover(ctx, e1, withType);
			case _:
		}
		// The SMALLEST enclosing range wins: a desugared part (an interpolated string literal) reuses the
		// whole expression's position, so first-completed is not always innermost. The typed expr's own
		// position must still enclose the offset; a match-compiled body carries a rewritten position
		// unrelated to the syntactic node the gate saw.
		if (!atExprHoverPos(te.pos)) return;
		// A declaration reports the variable's type, and a `super(...)` call the SUPER's; the nodes
		// themselves are Void.
		var ht = switch (te.expr) {
			case TVarExpr(v, _): v.type;
			case TCall(e1 = {expr: TConst(TSuper)}, _): e1.type;
			case _: te.type;
		};
		if (hoverFound == null || (te.pos.max - te.pos.min) < (hoverFound.p.max - hoverFound.p.min))
			hoverFound = {t: ht, p: te.pos, e: te, wt: withType, tctx: ctx};
	}

	// A field item is "qualified" when typing its BARE name in the same scope, against the same expected
	// type, reproduces the very expression being reported. The identifier carries a null position so
	// re-typing it cannot re-enter the display hooks. Any typing failure means the name does not resolve
	// here, hence false.
	public static function retypeIsQualified(ctx:TyperContext, e:TExpr, name:String, t:T):Bool {
		if (ctx == null || e == null) return false;
		// The probe identifier has a null position so the position-keyed display checks cannot fire while
		// it re-types. hxc additionally signals display results by throwing, and some collection points key
		// off the display MODE rather than the position, so the modes are switched off for the probe: a
		// raise here would be swallowed by the catch below and lose the real response, and a nested capture
		// would overwrite the very hover being reported.
		var sHover = displayHover, sTypeDef = displayTypeDefinition, sDef = displayDefinition;
		var sTop = displayToplevel, sTopJson = displayToplevelJson, sSig = displaySignature;
		var sUsage = displayUsage, sImpl = displayImplementation;
		var sFound = hoverFound;
		displayHover = false; displayTypeDefinition = false; displayDefinition = false;
		displayToplevel = false; displayToplevelJson = false; displaySignature = false;
		displayUsage = false; displayImplementation = false;
		var result = try {
			var e2 = typeExpr(ctx, new Expr(EConst(CIdent(name)), Position.nullPos),
				hxc.core.WithType.WithType.WithType(t, null));
			hxc.core.TexprTools.equal(e, e2);
		} catch (_:Dynamic) false;
		displayHover = sHover; displayTypeDefinition = sTypeDef; displayDefinition = sDef;
		displayToplevel = sTop; displayToplevelJson = sTopJson; displaySignature = sSig;
		displayUsage = sUsage; displayImplementation = sImpl;
		hoverFound = sFound;
		return result;
	}

	// Legacy --display file@pos@toplevel: an identifier at the display position raises the
	// visible-identifier collection instead of resolving.
	public static var displayToplevel = false;
	// The JSON completion lane's toplevel capture (CRToplevel): typed entries, recorded then answered at
	// report time.
	public static var displayToplevelJson = false;

	// The one-shot subset: locals in scope, the enclosing class fields (statics always, members
	// outside a static context), every type of every loaded module, the literal and keyword sets.
	// Sorting happens at report time.
	static function collectToplevelJson(ctx:TyperContext, ?withType:WithType):Array<JsonToplevelEntry> {
		var out:Array<JsonToplevelEntry> = [];
		function noCompletion(meta:Metadata):Bool return TypeFunctions.hasMeta(":noCompletion", meta);
		for (name in ctx.locals.keys()) {
			var v = ctx.locals.get(name);
			if (name.length > 0 && name.charCodeAt(0) != "`".code) out.push(JTLocal(v));
		}
		var c = ctx.curclass;
		if (c != null) {
			if (ctx.curfun != FunStatic) {
				var cur = c;
				while (cur != null) {
					for (name in cur.fields.keys()) {
						var cf = cur.fields.get(name);
						if (!noCompletion(cf.meta)) out.push(JTField(cf, cur, false));
					}
					cur = cur.superClass == null ? null : cur.superClass.c;
				}
			}
			for (cf in c.orderedStatics) if (!noCompletion(cf.meta)) out.push(JTField(cf, c, true));
		}
		for (m in ctx.com.modules) for (mt in m.types) {
			var infos = TypeFunctions.tInfos(mt);
			if (infos.isPrivate && m != (ctx.curclass == null ? null : ctx.curclass.module)) continue;
			if (noCompletion(infos.meta)) continue;
			out.push(JTType(mt));
		}
		// Over the current module's types , the module's imports and the EXPECTED type - which is what
		// puts an enum abstract's own values in front of an assignment to it.
		var seenEnum = new haxe.ds.StringMap<Bool>();
		function enumCtors(mt:Null<hxc.core.Type.ModuleType>):Void {
			if (mt == null) return;
			switch (mt) {
				case TAbstractDecl(a) if (a.isEnum && a.impl != null && ctx.curclass != a.impl):
					var key = hxc.core.Globals.sTypePath(a.path);
					if (seenEnum.exists(key)) return;
					seenEnum.set(key, true);
					for (cf in a.impl.orderedStatics)
						if (TypeFunctions.hasClassFieldFlag(cf, CfEnum) && !noCompletion(cf.meta))
							out.push(JTEnumAbstract(a, a.impl, cf));
				case TTypeDecl(td):
					switch (TypeFunctions.follow(td.type)) {
						case TEnum(e, _): enumCtors(TEnumDecl(e));
						case _:
					}
				case TEnumDecl(e):
					var key = hxc.core.Globals.sTypePath(e.path);
					if (seenEnum.exists(key)) return;
					seenEnum.set(key, true);
					for (n in e.constrs.keys()) out.push(JTEnumCtor(e, e.constrs.get(n)));
				case _:
			}
		}
		if (ctx.com.currentModule != null) for (mt in ctx.com.currentModule.types) enumCtors(mt);
		if (withType != null) switch (withType) {
			case WithType(tt, _):
				enumCtors(try TypeFunctions.moduleTypeOfType(TypeFunctions.follow(tt)) catch (_:Dynamic) null);
			case _:
		}
		return out;
	}

	// An unresolved identifier where only types are wanted: a type name that did not resolve. A type
	// position collects no locals and no instance fields, which is what a typer context carrying
	// neither gives here.
	public static function handleUnresolvedIdentifier(com:hxc.context.Context, i:String, p:Position):Void {
		recordUnresolvedIdentifier(new TyperContext(com), i, p);
	}

	// Nesting depth of a type_ident_raise-style SPECULATIVE lookup: inside one, an unresolved name
	// raises without being recorded, because the caller has another route. when find_before_pos gives
	// up, the reference hands typing the expression unmarked, so no EDisplay is reached and nothing in
	// it answers - the request ends with "No completion point was found", or with whatever error the
	// body recorded. hxc answers from positions, so the verdict is carried here instead.
	public static var exprDisplayOff:Bool = false;

	public static var identSpeculation:Int = 0;

	// A candidate whose name matches exactly is an IMPORT suggestion carrying its full type path (kind 0);
	// anything else is a typo suggestion naming it (kind 1).
	// The candidate set for an unresolved identifier includes the KEYWORDS and the `trace` builtin. hxc's
	// collectToplevel has the LEGACY shape (the XML @toplevel lane emits no keyword items), so they are
	// added here. Without them a typo one edit from a keyword would suggest nothing.
	static final unresolvedKeywords = [
		"function", "var", "final", "if", "else", "while", "do", "for", "break", "return",
		"continue", "switch", "try", "new", "throw", "untyped", "cast", "inline", "trace"
	];

	static function recordUnresolvedIdentifier(ctx:TyperContext, i:String, p:Position):Void {
		var items = try collectToplevel(ctx) catch (_:Dynamic) return;
		items = items.concat([for (k in unresolvedKeywords) {kind: "keyword", name: k}]);
		var scored = [];
		for (it in items) {
			var d = hxc.core.StringError.levenshtein(i, it.name);
			scored.push({item: it, d: d});
		}
		scored.sort(function(a, b) return a.d - b.d);
		var out:Array<{kind:Int, name:String}> = [];
		for (e in scored) {
			// Similarity filtering stops at the first candidate that fails the bound.
			var shorter = i.length < e.item.name.length ? i.length : e.item.name.length;
			if (e.d > Std.int(shorter / 3)) break;
			if (e.d == 0) {
				if (e.item.kind != "type") continue;
				out.push({kind: 0, name: e.item.path != null ? e.item.path : e.item.name});
			} else out.push({kind: 1, name: e.item.name});
		}
		// prepends. The recorders themselves run LIFO (the PForce delays a type hint queues come off the
		// front), so prepending puts the list back in source order, which is the order the diagnostics
		// are emitted in.
		ctx.com.unresolvedIdentifiers.unshift({name: i, pos: p, suggestions: out});
	}

	static function collectToplevel(ctx:TyperContext, ?withType:WithType, sort:Bool = false):Array<hxc.compiler.DisplayXml.ToplevelItem> {
		var items:Array<hxc.compiler.DisplayXml.ToplevelItem> = [];
		var displayOff = hxc.parser.Parser.displayOffset;
		inline function sType(t:T):String return hxc.core.TPrinting.sTypeStr(t);
		function noCompletion(meta:Metadata):Bool return TypeFunctions.hasMeta(":noCompletion", meta);
		// Locals in scope
		for (name in ctx.locals.keys()) {
			var v = ctx.locals.get(name);
			if (name.length > 0 && name.charCodeAt(0) != "`".code) {
				// A local sorts by how far the cursor is PAST its declaration, so the nearest one comes first,
				// behind a levenshtein distance to the name the position expects when there is one .
				var d = displayOff - v.pos.min;
				var key = StringTools.lpad(Std.string(d < 0 ? 0 : d), "0", 5);
				var exp = expectedName(withType);
				if (exp != null) key = StringTools.lpad(Std.string(levenshtein(exp, v.name)), "0", 5) + key;
				items.push({kind: "local", name: name, type: sType(v.type), sortGroup: 0, sortKey: key, sortType: v.type});
			}
		}
		var c = ctx.curclass;
		// Member fields, including inherited ones
		if (c != null && ctx.curfun != FunStatic) {
			var cur = c;
			// Every inherited field is mapped with the class's own parameters, so a member declared on
			// C1<T> reads with the argument C3 -> C2<String> -> C1<String> supplies, not as the raw
			// parameter.
			var curArgs:TParams = TypeFunctions.extractParamTypes(c.params);
			while (cur != null) {
				for (name in cur.fields.keys()) {
					var cf = cur.fields.get(name);
					var ct = cf.type;
					if (cur.params.length > 0) ct = TypeFunctions.applyParams(cur.params, curArgs, ct);
					// The class's own member is 10, an inherited one 11.
					if (!noCompletion(cf.meta)) items.push({kind: "member", name: cf.name, type: sType(ct),
						doc: Ast.genDocTextOpt(cf.doc), sortGroup: cur == c ? 10 : 11, sortKey: cf.name, sortType: ct});
				}
				if (cur.superClass == null) cur = null;
				else {
					// The super's arguments are written in terms of THIS class's parameters, so
					// they carry the substitution up the chain.
					var sup = cur.superClass;
					curArgs = [for (pt in sup.params) TypeFunctions.applyParams(cur.params, curArgs, pt)];
					cur = sup.c;
				}
			}
		}
		// Statics; on an abstract impl the CfImpl fields read as members
		if (c != null) switch (c.kind) {
			case KAbstractImpl(a) if (a.impl != null):
				for (cf in a.impl.orderedStatics) {
					if (noCompletion(cf.meta)) continue;
					if (TypeFunctions.hasClassFieldFlag(cf, CfImpl)) {
						// An abstract's member reads without the leading `this` argument its impl carries.
						var mt = switch (TypeFunctions.follow(cf.type)) {
							case TFun(sig) if (sig.args.length > 0): TFun({args: sig.args.slice(1), ret: sig.ret});
							case t2: t2;
						};
						if (ctx.curfun != FunStatic) items.push({kind: "member", name: cf.name, type: sType(mt),
							doc: Ast.genDocTextOpt(cf.doc), sortGroup: 10, sortKey: cf.name, sortType: mt});
					} else items.push({kind: "static", name: cf.name, type: sType(cf.type),
						doc: Ast.genDocTextOpt(cf.doc), sortGroup: 13, sortKey: cf.name, sortType: cf.type});
				}
			case _:
				for (cf in c.orderedStatics) {
					if (noCompletion(cf.meta)) continue;
					// A macro field resolves to its macro-world display type.
					var st = hxc.eval.EvalMacro.macroFieldDisplayType(ctx.com, c, cf);
					if (st == null) st = cf.type;
					items.push({kind: "static", name: cf.name, type: sType(st),
						doc: Ast.genDocTextOpt(cf.doc), sortGroup: 13, sortKey: cf.name, sortType: st});
				}
		}
		// The module globals: every static a bare name reaches through an import, whether an explicit field
		// import or a wildcard put it there. Only what access checks allow and what is not @:noCompletion
		// is kept.
		{
			var curMod = ctx.com.currentModule;
			var imports = curMod == null ? null : ctx.com.moduleImports.get(hxc.context.Context.pathKey(curMod.path));
			if (imports != null) {
				var seenGlobal = new Map<String, Bool>();
				function staticsOf(mt:ModuleType):Null<TClass> return switch (mt) {
					case TClassDecl(cl): cl;
					case TAbstractDecl(a) if (a.impl != null): a.impl;
					case _: null;
				};
				function addImported(cl:TClass, cf:TClassField, name:String):Void {
					if (seenGlobal.exists(name) || noCompletion(cf.meta)) return;
					if (!Fields.canAccess(ctx, cl, cf, true)) return;
					seenGlobal.set(name, true);
					// A StaticImport is group 14.
					items.push({kind: "static", name: name, type: sType(cf.type),
						doc: Ast.genDocTextOpt(cf.doc), sortGroup: 14, sortKey: name, sortType: cf.type});
				}
				for (name in imports.globals.keys()) {
					var g = imports.globals.get(name);
					var mt = try ctx.com.getType(g.ownerPath, Position.nullPos, g.ownerSub) catch (_:Dynamic) null;
					var cl = mt == null ? null : staticsOf(mt);
					if (cl == null) continue;
					try TypeResolve.resolveModule(ctx.com, cl.module) catch (_:Dynamic) {}
					var cf = cl.statics.get(g.field != null ? g.field : name);
					if (cf != null) addImported(cl, cf, name);
				}
			}
		}
		// Enum constructors. Each enum contributes once: every arm checks whether the path was already
		// recorded, and records it.
		var seenEnumPaths = new Map<String, Bool>();
		function enumCtors(mt:ModuleType):Void {
			switch (mt) {
				case TEnumDecl(en):
					var key = hxc.core.Globals.sTypePath(en.path);
					if (seenEnumPaths.exists(key)) return;
					seenEnumPaths.set(key, true);
					for (name in en.constrs.keys()) {
						var ef = en.constrs.get(name);
						// An enum field sorts before everything else in a pattern, and by its declaration INDEX
						// rather than its name - which is the only thing that puts the constructors back in source
						// order.
						items.push({kind: "enum", name: ef.name, type: sType(ef.type), doc: Ast.genDocTextOpt(ef.doc),
							sortGroup: patternDisplay ? -1 : 20, sortKey: StringTools.lpad(Std.string(ef.index), "0", 4), sortType: ef.type});
					}
				case TAbstractDecl(a) if (a.isEnum && a.impl != null && a.impl != c):
					var key = hxc.core.Globals.sTypePath(a.path);
					if (seenEnumPaths.exists(key)) return;
					seenEnumPaths.set(key, true);
					for (cf in a.impl.orderedStatics)
						if (TypeFunctions.hasClassFieldFlag(cf, CfEnum) && !noCompletion(cf.meta))
							items.push({kind: "enumabstract", name: cf.name, type: sType(cf.type), doc: Ast.genDocTextOpt(cf.doc),
								sortGroup: patternDisplay ? -1 : 21, sortKey: cf.name, sortType: cf.type});
				case TTypeDecl(td):
					// A typedef contributes only if it aliases an enum.
					switch (TypeFunctions.follow(td.type)) {
						case TEnum(en, _): enumCtors(TEnumDecl(en));
						case _:
					}
				case _:
			}
		}
		var m = c == null ? null : c.module;
		if (m != null) for (mt in m.types) enumCtors(mt);
		// The EXPECTED type's constructors, which makes an enum value complete inside a call argument or
		// an assignment whose target is that enum.
		if (withType != null) switch (withType) {
			case WithType(t, _):
				switch (TypeFunctions.follow(t)) {
					case TEnum(en, _): enumCtors(TEnumDecl(en));
					case TAbstract(a, _): enumCtors(TAbstractDecl(a));
					case _:
				}
			case _:
		}
		// Literals Each literal carries a type, which is what ranks it against the expected one - null is
		// Dynamic, the booleans are Bool, trace is a function.
		inline function lit(n:String, lt:T) items.push({kind: "literal", name: n, sortGroup: 50, sortKey: n, sortType: lt});
		lit("null", TypeFunctions.tDynamic);
		lit("true", ctx.com.basic.tbool);
		lit("false", ctx.com.basic.tbool);
		switch (ctx.curfun) {
			case FunMember | FunConstructor | FunMemberClassLocal:
				lit("this", c == null ? TypeFunctions.tDynamic : TInst(c, TypeFunctions.extractParamTypes(c.params)));
				if (c != null && c.superClass != null) lit("super", TInst(c.superClass.c, c.superClass.params));
			case FunMemberAbstract:
				lit("abstract", c == null ? TypeFunctions.tDynamic : TInst(c, TypeFunctions.extractParamTypes(c.params)));
			case _:
		}
		lit("trace", TFun({args: [{name: "value", opt: false, t: TypeFunctions.tDynamic}], ret: ctx.com.basic.tvoid}));
		// Type params
		for (tp in ctx.typeParams) switch (TypeFunctions.follow(tp.type)) {
			case TInst(pc, _): items.push({kind: "type", name: pc.path.name, path: hxc.core.Globals.sTypePath(pc.path),
				sortGroup: 30, sortKey: pc.path.name, tparam: pc});
			case _:
		}
		// Module types, then the implicit StdTypes import (newest first, matching the reversed
		// module_imports print). Abstract impl and module-fields carriers are excluded. (add_type).
		var seenPaths = new haxe.ds.StringMap<Bool>();
		function addType(mt:ModuleType):Void {
			switch (mt) {
				case TClassDecl({kind: KAbstractImpl(_) | KModuleFields(_)}): return;
				case _:
			}
			var inf = TypeFunctions.tInfos(mt);
			if (noCompletion(inf.meta)) return;
			var key = hxc.core.Globals.sTypePath(inf.path);
			if (seenPaths.exists(key)) return;
			seenPaths.set(key, true);
			// A type sorts by IMPORT STATUS then dotted path. Everything reached here is in scope by
			// definition (the module's own types and StdTypes), which is Imported; the cache-files source
			// below contributes the Unimported ones.
			items.push({kind: "type", name: inf.path.name, path: key, sortGroup: 31, sortKey: key});
		}
		if (m != null) for (mt in m.types) addType(mt);
		var std = ctx.com.moduleLut.get("StdTypes");
		if (std != null) {
			var l = std.types.copy();
			l.reverse();
			for (mt in l) addType(mt);
		}
		addCachedFileTypes(ctx.com, items, seenPaths);
		return sort ? sortToplevel(items, withType) : items;
	}

	// An EDisplay inside a PATTERN answers with the pattern's own expected type, which is what ranks the
	// subject enum's constructors first.
	public static function raiseToplevelInPattern(ctx:TyperContext, t:T, name:String, outermost:Bool = true,
			?p:Position):Void {
		if (fieldCompletionFound != null) return;
		var wt = WithTypeTools.withType(t);
		if (displayToplevelJson) {
			// The recovery stand-in `null` is not a subject the user wrote; the collection is sorted
			// exactly when the subject is empty, which is what the legacy lane keys off too.
			var subj = name == "null" ? null : name;
			var ex = new JsonToplevelCompletion(collectToplevelJson(ctx, wt), subj, p, wt);
			ex.patternOutermost = outermost;
			throw ex;
		}
		if (displayToplevel)
			throw new hxc.compiler.DisplayXml.ToplevelCompletion(
				collectToplevel(ctx, WithTypeTools.withType(t), name == "null"));
	}

	// The expression the preprocessor marked as the display subject, recorded instead of wrapped since
	// hxc's typer has no EDisplay node. Identity, not position, so an expression that merely shares a
	// span is never mistaken for it.
	public static var markedDisplay:Null<Expr> = null;

	// /:105: the cursor in the whitespace where an expression is EXPECTED but has not been written - after
	// a var's `=` or an assignment's - marks whatever the parser found there as the display subject, so the
	// statement it swallowed is completed against instead of reported. The span runs from p0 (the var's
	// type hint, or its name when it has none) to where that expression starts.
	public static function markedGap(p0:Position, e:Expr):Bool {
		if (!hxc.parser.Parser.displayCompletionMode || fieldCompletionFound != null) return false;
		return atDisplayPos(new Position(p0.file, p0.min, e.pos.min));
	}

	// A marked expression that is not a field access answers with the toplevel collection keyed by its
	// own dotted path; anything that is not a path (a call, a literal, `null`) has an empty subject,
	// which is the sorted case.
	public static function raiseToplevelMarked(ctx:TyperContext, e:Expr, withType:WithType):Void {
		if (fieldCompletionFound != null) return;
		var name = try Ast.stringListOfExprPathRaise(e).join(".") catch (_:Dynamic) "";
		if (name == "null") name = "";
		if (displayToplevelJson) throw new JsonToplevelCompletion(collectToplevelJson(ctx, withType), name, e.pos, withType);
		if (displayToplevel)
			throw new hxc.compiler.DisplayXml.ToplevelCompletion(collectToplevel(ctx, withType, name == ""));
	}

	// The argument or structure field the position is filling.
	static function expectedName(withType:Null<WithType>):Null<String> {
		return switch (withType) {
			case Value(FunctionArgument(si)) | WithType(_, FunctionArgument(si)): si.name;
			case Value(StructureField(si)) | WithType(_, StructureField(si)): si.name;
			case _: null;
		};
	}

	static function levenshtein(a:String, b:String):Int {
		var prev = [for (j in 0...b.length + 1) j];
		for (i in 0...a.length) {
			var cur = [i + 1];
			for (j in 0...b.length) {
				var sub = prev[j] + (a.charCodeAt(i) == b.charCodeAt(j) ? 0 : 1);
				var del = prev[j + 1] + 1;
				var ins = cur[j] + 1;
				cur.push(sub < del ? (sub < ins ? sub : ins) : (del < ins ? del : ins));
			}
			prev = cur;
		}
		return prev[b.length];
	}

	// A display inside a PATTERN is DKPattern, which becomes TKPattern, which floats the enum constructors
	// above everything else. hxc does not thread the display kind through the matcher, so the pattern
	// context is flagged here.
	public static var patternDisplay:Bool = false;

	// The reference sorts only when the completion subject is empty `sort = (name = "")`), so a
	// partially typed identifier keeps the collection order and only a bare position gets ranked.
	static function sortToplevel(items:Array<hxc.compiler.DisplayXml.ToplevelItem>, withType:Null<WithType>):Array<hxc.compiler.DisplayXml.ToplevelItem> {
		var expected:Null<T> = switch (withType) {
			case WithType(t, _) if (!TypeFunctions.follow(t).match(TMono(_))): t;
			case _: null;
		};
		// How well the item's own type fits the expected one. An enum constructor is judged on what it
		// returns, so an argument-less one ranks with it .
		function comp(it:hxc.compiler.DisplayXml.ToplevelItem):Int {
			if (expected == null) return 0;
			var t = it.sortType;
			if (t == null) return 9;
			if (it.kind == "enum") switch (TypeFunctions.follow(t)) {
				case TFun(sig): t = sig.ret;
				case _:
			}
			if (TypeUnification.typeIseqDefault(t, expected)) return 0;
			if (TypeFunctions.follow(t).match(TDynamic(_))) return 5;
			try { TypeUnification.unifyDefault(t, expected); return 1; } catch (_:Dynamic) {}
			return switch (TypeFunctions.follow(t)) {
				case TFun(sig):
					if (TypeUnification.typeIseqDefault(sig.ret, expected)) 2
					else try { TypeUnification.unifyDefault(sig.ret, expected); 3; } catch (_:Dynamic) 7;
				case _: 6;
			};
		}
		var keyed = [for (i in 0...items.length) {
			it: items[i], c: comp(items[i]),
			g: items[i].sortGroup == null ? 500 : items[i].sortGroup,
			k: items[i].sortKey == null ? "" : items[i].sortKey, i: i
		}];
		keyed.sort(function(a, b) {
			if (a.c != b.c) return a.c - b.c;
			if (a.g != b.g) return a.g - b.g;
			if (a.k != b.k) return a.k < b.k ? -1 : 1;
			// The sort is stable, so equal keys keep the collection order.
			return a.i - b.i;
		});
		return [for (e in keyed) e.it];
	}

	// The third collection source: every file the compilation cache knows, whether or not this compile
	// loaded it. Each file's DECLARATIONS become type items, and a file that contributed anything also
	// contributes its package (named by the package's last segment). The old protocol deliberately
	// takes the ADVANCED branch here, not the legacy-completion one.
	public static function addCachedFileTypes(com:hxc.context.Context, items:Array<hxc.compiler.DisplayXml.ToplevelItem>,
			seenPaths:Map<String, Bool>):Void {
		if (!hxc.context.ServerCache.enabled) return;
		// A package with a `_`-prefixed segment is the private `_Module` container and is never offered.
		function packVisible(pack:Array<String>):Bool {
			for (s in pack) if (s.length > 0 && s.charCodeAt(0) == "_".code) return false;
			return true;
		}
		var packages:Array<Array<String>> = [];
		var seenPack = new Map<String, Bool>();
		// The same parse-only class-path scan the json toplevel answer folds over; nothing here is typed.
		for (cf in hxc.compiler.ToplevelScan.get(com)) {
			if (!packVisible(cf.pack)) continue;
			var moduleName = cf.moduleName;
			var added = false;
			for (td in cf.decls) {
				var info = declNameAndFlags(td.decl);
				if (info == null || info.priv || TypeFunctions.hasMeta(":noCompletion", info.meta)) continue;
				var full = (cf.pack.length == 0 ? "" : cf.pack.join(".") + ".")
					+ (info.name == moduleName ? info.name : moduleName + "." + info.name);
				if (seenPaths.exists(full)) continue;
				seenPaths.set(full, true);
				// Nothing reached through the cache is in scope yet, so these are the Unimported group.
				items.push({kind: "type", name: info.name, path: full, sortGroup: 32, sortKey: full});
				added = true;
			}
			// The package contributes under its last segment.
			if (added && cf.pack.length > 0) {
				var key = cf.pack.join(".");
				if (!seenPack.exists(key)) { seenPack.set(key, true); packages.push(cf.pack); }
			}
		}
		// Packages are emitted after every type source.
		for (pack in packages) if (packVisible(pack))
			items.push({kind: "package", name: pack[pack.length - 1], sortGroup: 40, sortKey: pack.join(".")});
	}

	// The name, privacy and metadata of a declaration; an import or using contributes nothing.
	static function declNameAndFlags(d:hxc.ast.Ast.TypeDef):Null<{name:String, priv:Bool, meta:Metadata}> {
		return switch (d) {
			case EClass(dd): {name: dd.dName.name, priv: dd.dFlags.indexOf(HPrivate) >= 0, meta: dd.dMeta};
			case EEnum(dd): {name: dd.dName.name, priv: dd.dFlags.indexOf(EPrivate) >= 0, meta: dd.dMeta};
			case ETypedef(dd): {name: dd.dName.name, priv: dd.dFlags.indexOf(EPrivate) >= 0, meta: dd.dMeta};
			case EAbstract(dd): {name: dd.dName.name, priv: dd.dFlags.indexOf(AbPrivate) >= 0, meta: dd.dMeta};
			case _: null;
		}
	}

	// Reached an ANONYMOUS structure's field: the declaration answers by itself, exactly as a class
	// field's does.
	public static function displayAnonField(cf:TClassField):Void {
		if (displayDefinition) {
			if (displayFound == null) displayFound = [cf.namePos];
		} else if (displayHover || displayTypeDefinition) {
			if (hoverFound == null) {
				var t = switch (cf.type) { case TLazy(r): TypeFunctions.lazyType(r); case t2: t2; };
				hoverFound = {t: t, p: cf.namePos};
			}
		} else if (displayUsage || displayImplementation) {
			if (usageTargetField == null) usageTargetField = cf;
		}
	}

	// A DECLARED class field the cursor sits on answers by itself, without any expression referring to
	// it. An abstract's own member drops the leading `this` its impl carries prepare_using_field), and
	// a constructor reads as the function that produces its class , which is not what its stored
	// signature says.
	public static function displayClassField(c:Null<TClass>, isCtor:Bool, cf:TClassField, p:Position):Void {
		if (displayDefinition) {
			if (displayFound == null) displayFound = [cf.namePos];
		} else if (displayHover || displayTypeDefinition) {
			if (hoverFound == null || (p.max - p.min) < (hoverFound.p.max - hoverFound.p.min)) {
				var t = switch (cf.type) { case TLazy(r): TypeFunctions.lazyType(r); case t2: t2; };
				if (TypeFunctions.hasClassFieldFlag(cf, CfImpl)) t = switch (TypeFunctions.follow(t)) {
					case TFun(sig) if (sig.args.length > 0): TFun({args: sig.args.slice(1), ret: sig.ret});
					case t2: t2;
				};
				if (isCtor && c != null) switch (TypeFunctions.follow(t)) {
					case TFun(sig): t = TFun({args: sig.args, ret: TInst(c, TypeFunctions.extractParamTypes(c.params))});
					case _:
				}
				hoverFound = {t: t, p: p};
			}
		} else if (displayUsage || displayImplementation) {
			if (usageTargetField == null) usageTargetField = cf;
		}
	}

	// A type path under the cursor answers with that type - its declaration position, its own type for
	// hover, itself as the usage subject.
	public static function displayModuleType(com:hxc.context.Context, mt:hxc.core.Type.ModuleType, p:Position, allowCompletion:Bool = false):Void {
		var inf = TypeFunctions.tInfos(mt);
		if (displayDefinition) {
			if (displayFound == null) displayFound = [inf.namePos];
		} else if (displayHover || displayTypeDefinition) {
			// A type path answers with a type item, not with an expression.
			if (hoverFound == null)
				hoverFound = {t: TypeFunctions.typeOfModuleType(mt), p: p, mt: mt};
		} else if (displayUsage || displayImplementation) {
			usageTargetType = mt;
		} else if (allowCompletion && hxc.parser.Parser.displayCompletionMode && fieldCompletionFound == null) {
			// Under DMDefault the type path answers with the type HINT collection, with the type's own
			// dotted path as the subject. Only callers that allow display reach this.
			hxc.typing.TypeResolve.answerTypeHintCompletion(com, p, hxc.core.Globals.sTypePath(inf.path));
		}
	}

	// The report uses the DOTTED name's own span, so `Array<Foo>` with the cursor on Foo answers Foo
	// and not Array.
	public static function checkDisplayType(com:hxc.context.Context, t:T, tp:PlacedTypePath):Void {
		if (hxc.parser.Parser.displayFile == null) return;
		var path = tp.path;
		var strings = path.tsub != null ? [path.tsub, path.tname].concat(path.tpackage) : [path.tname].concat(path.tpackage);
		var pName = new Position(tp.pos.file, tp.pos.min, tp.pos.min + strings.join(".").length);
		if (!atDisplayPos(pName)) return;
		var mt = try TypeFunctions.moduleTypeOfType(t) catch (_:hxc.core.ExitException) null;
		if (mt != null) displayModuleType(com, mt, pName, true);
	}

	// A variable declaration answers the display by itself when the cursor sits on its name, without
	// any typed expression referring to it. A function argument is the case that has no expression at
	// all to be found through.
	// `trace` under the cursor is answered SYNTHETICALLY - one Dynamic argument named "value"
	// returning
	// Void, documented "Print given arguments" - because the real haxe.Log.trace signature carries the
	// PosInfos argument the compiler fills in. A definition or type-definition question answers no
	// position at all.
	public static function displayTraceIdent(ctx:TyperContext, p:Position):Void {
		if (displayDefinition || displayTypeDefinition) {
			if (atDisplayPos(p) && displayFound == null) displayFound = [];
			return;
		}
		// A HOVER subject is picked with a strict upper bound, so the cursor sitting at the very end of
		// `trace` is outside it and the enclosing call answers instead.
		if (!displayHover || !atExprHoverPos(p)) return;
		var t = TFun({args: [{name: "value", opt: false, t: TypeFunctions.tDynamic}], ret: ctx.com.basic.tvoid});
		if (hoverFound == null || (p.max - p.min) < (hoverFound.p.max - hoverFound.p.min))
			hoverFound = {t: t, p: p, e: TypeFunctions.mk(TIdent("trace"), t, p), tctx: ctx,
				wt: hxc.core.WithType.WithTypeTools.namedArgument("value")};
	}

	public static function displayVariable(ctx:TyperContext, v:TVar, p:Position):Void {
		if (displayDefinition) {
			if (displayFound == null) displayFound = [v.pos];
		} else if (displayHover || displayTypeDefinition) {
			// DMTypeDefinition resolves from the same captured type.
			if (hoverFound == null)
				hoverFound = {t: v.type, p: p, e: TypeFunctions.mk(TLocal(v), v.type, p), tctx: ctx};
		} else if (displayUsage || displayImplementation) {
			if (usageTargetField == null && usageTargetVar == null && usageTargetEnumField == null)
				usageTargetVar = v;
		}
	}

	// Runs on the ACCESS, before the assignment decides whether the write is legal at all. hxc only
	// ever hands the display hooks a typed EXPRESSION, and a rejected write never becomes one, so an
	// lvalue under the cursor answered nothing.
	public static function checkDisplayOnAccess(ctx:TyperContext, acc:hxc.typing.AccessKind.AccessKind, p:Position):Void {
		if (!atDisplayPos(p)) return;
		if (!displayDefinition && !displayHover && !displayTypeDefinition && !displayUsage && !displayImplementation) return;
		// The RECEIVER is its own node: `|e.toString()` is a question about e, not about the
		// static extension it is passed to, so the answer comes from the receiver instead.
		var recv:Null<TExpr> = switch (acc) {
			case AKUsingField(se) | AKUsingAccessor(se):
				(se.thisExpr != null && atDisplayPos(se.thisExpr.pos)) ? se.thisExpr : null;
			case _: null;
		};
		if (recv != null) {
			if (displayDefinition) checkDisplayDefinition(ctx, recv);
			if (displayHover || displayTypeDefinition) checkDisplayHover(ctx, recv, null);
			if (displayUsage || displayImplementation) captureUsageTarget(recv);
			return;
		}
		function readExpr(a:hxc.typing.AccessKind.AccessKind):Null<TExpr> return switch (a) {
			case AKNo(inner, _): readExpr(inner);
			// A `?.` node reports the then expression of the null-check TIf, built as the access CAST to
			// tnull - but only when its type is not nullable. A structure is nullable, so an inner link
			// keeps its own type while a basic one reports Null<T>. The cast is then unwrapped KEEPING the
			// cast type, which is why the field is still what answers a definition request.
			case AKSafeNav(sn):
				var inner = readExpr(sn.access);
				if (inner != null && !TypeFunctions.isNullable(inner.type))
					inner = TypeFunctions.mk(inner.expr, ctx.com.basic.tnull(inner.type), inner.pos);
				inner;
			case AKExpr(te): te;
			case AKField(fa) | AKAccessor(fa):
				try hxc.typing.FieldAccessTools.getFieldExpr(fa, FRead) catch (_:Dynamic) null;
			case AKUsingField(se) | AKUsingAccessor(se):
				try hxc.typing.FieldAccessTools.getFieldExpr(se.access, FRead) catch (_:Dynamic) null;
			case _: null;
		};
		var te = readExpr(acc);
		if (te == null) return;
		// A macro field reports its MACRO-WORLD signature.
		switch (te.expr) {
			case TField(_, FStatic(mc, mcf) | FInstance(mc, _, mcf) | FClosure({c: mc}, mcf)):
				var mt2 = hxc.eval.EvalMacro.macroFieldDisplayType(ctx.com, mc, mcf);
				if (mt2 != null) te = TypeFunctions.mk(te.expr, mt2, te.pos);
			case _:
		}
		if (displayDefinition) checkDisplayDefinition(ctx, te);
		if (displayHover || displayTypeDefinition) checkDisplayHover(ctx, te, null);
		if (displayUsage || displayImplementation) captureUsageTarget(te);
	}

	// The constructor test, resolved against what is already loaded (the module the cursor is in is
	// mid-typing). An abstract counts when its impl declares _new. What a `new <cursor>` keeps out of
	// the toplevel collection.
	static function newCandidateSurvives(ctx:TyperContext, it:hxc.compiler.DisplayXml.ToplevelItem, p:Position):Bool {
		if (it.tparam != null) return switch (it.tparam.kind) {
			case KTypeParameter(tl): (try getConstructibleConstraint(ctx, tl, p) catch (_:Dynamic) null) != null;
			case _: false;
		};
		return it.kind == "type" && typeItemHasConstructor(ctx, it);
	}

	static function typeItemHasConstructor(ctx:TyperContext, it:hxc.compiler.DisplayXml.ToplevelItem):Bool {
		if (it.path == null) return false;
		// A constructor that is not PUBLIC only counts inside the class itself or a subclass of it, inside
		// the abstract whose impl declares it, or under @:privateAccess (YesButPrivate).
		function reachable(c:TClass, ctor:TClassField):Bool {
			if (TypeFunctions.hasClassFieldFlag(ctor, CfPublic)) return true;
			if (ctx.privateAccess > 0) return true;
			switch (ctx.curclass.kind) {
				case KAbstractImpl(a) if (hxc.core.Globals.sTypePath(a.path) == hxc.core.Globals.sTypePath(c.path)): return true;
				case _:
			}
			var cur = ctx.curclass;
			while (cur != null) {
				if (cur == c) return true;
				cur = cur.superClass == null ? null : cur.superClass.c;
			}
			return false;
		}
		function ctorOf(c:TClass):Bool {
			var cur = c;
			while (cur != null) {
				if (cur.constructor != null) return reachable(cur, cur.constructor);
				cur = cur.superClass == null ? null : cur.superClass.c;
			}
			return false;
		}
		function check(mt:ModuleType):Bool return switch (mt) {
			case TClassDecl(c): switch (c.kind) {
					case KAbstractImpl(a): a.impl != null && a.impl.statics.exists("_new");
					case _: ctorOf(c);
				};
			case TAbstractDecl(a): a.impl != null && a.impl.statics.exists("_new");
			case TTypeDecl(td): switch (TypeFunctions.follow(td.type)) {
					case TInst(c, _): ctorOf(c);
					case TAbstract(a, _): a.impl != null && a.impl.statics.exists("_new");
					case _: false;
				};
			case _: false;
		};
		inline function pathOf(mt:ModuleType):String return hxc.core.Globals.sTypePath(TypeFunctions.tInfos(mt).path);
		if (ctx.com.currentModule != null)
			for (mt in ctx.com.currentModule.types) if (pathOf(mt) == it.path) return check(mt);
		for (key in ctx.com.moduleLut.keys())
			for (mt in ctx.com.moduleLut.get(key).types) if (pathOf(mt) == it.path) return check(mt);
		return false;
	}

	// ctx.inDisplay is on while the marked expression types, so an unresolved name raises ANYWHERE
	// inside that subtree, not only for one the cursor is on. hxc reads the marked node's range rather
	// than carrying a flag: a flag would have to survive the raise this very arm performs, and a
	// display flag outliving its subtree is an easy mistake to make. Positions nest, so being inside
	// the span is being inside the subtree.
	static function inMarkedSubtree(p:Position):Bool {
		var mn = hxc.typing.ExprPreprocessing.markedNode;
		if (mn == null || mn.pos == null || p == null) return false;
		if (!hxc.typing.ExprPreprocessing.inDisplayFile(p)) return false;
		// A BLOCK mark is excluded. What differs is what happens next, and it is TEMPORAL. type_block
		// catches Error PER STATEMENT and records it, so the block itself types cleanly and the display
		// walk raises its answer before typing ends - the answer wins, and the recorded error never
		// reaches . With the call marked instead, typing the marked node itself raises, no answer is ever
		// produced, and aborts with the error. So the real discriminator is whether the marked NODE typed
		// cleanly, and excluding a block stands in for the one case where a statement error is swallowed
		// under it. Giving hxc that signal directly would retire this exclusion.
		switch (mn.expr) { case EBlock(_): return false; case _: }
		return mn.pos.min <= p.min && p.max <= mn.pos.max;
	}

	public static function atDisplayPos(p:Position):Bool {
		// A position the preprocessor refused to annotate is not a display position for anything downstream
		// either.
		if (hxc.parser.Parser.displaySuppressed) return false;
		var df = hxc.parser.Parser.displayFile;
		var off = hxc.parser.Parser.displayOffset;
		if (df == null || off < 0) return false;
		if (!(p.min <= off && off <= p.max)) return false;
		var f = StringTools.replace(p.file, "\\", "/");
		var d = StringTools.replace(df, "\\", "/");
		return f == d || StringTools.endsWith(f, "/" + d) || StringTools.endsWith(d, "/" + f);
	}

	// Legacy --display @usage: the symbol at the display offset is captured by identity during typing; the
	// compiler then scans every typed expression for references to it.
	public static var displayUsage:Bool = false;

	// DMImplementation shares the usage capture; the report collects extenders, implementers and overriders
	// instead of references.
	public static var displayImplementation:Bool = false;
	public static var usageTargetField:Null<TClassField> = null;
	public static var usageTargetVar:Null<TVar> = null;
	public static var usageTargetEnumField:Null<TEnumField> = null;

	// Ctx0: the scope the expression was typed in, needed to resolve `super`.
	static function captureUsageTarget(te:TExpr, ?ctx0:TyperContext):Void {
		if (usageTargetField != null || usageTargetVar != null || usageTargetEnumField != null) return;
		TexprTools.iter(function(child) {
			if (atDisplayPos(child.pos)
				&& (child.pos.min > te.pos.min || child.pos.max < te.pos.max))
				captureUsageTarget(child, ctx0);
		}, te);
		if (usageTargetField != null || usageTargetVar != null || usageTargetEnumField != null) return;
		switch (te.expr) {
			case TField(_, FEnum(_, ef)): usageTargetEnumField = ef;
			case TField(_, FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf)): usageTargetField = cf;
			case TLocal(v) | TVarExpr(v, _): usageTargetVar = v;
			case TNew(c, _, _) if (c.constructor != null): usageTargetField = c.constructor;
			// A `super(...)` call is a reference to the SUPER constructor.
			case TCall({expr: TConst(TSuper)}, _):
				var sup = ctx0 == null || ctx0.curclass == null ? null : ctx0.curclass.superClass;
				var ctor = sup == null ? null : superConstructor(sup.c);
				if (ctor != null) usageTargetField = ctor;
			case TTypeExpr(mt):
				usageTargetType = mt;
				switch (mt) { case TClassDecl(c): usageTargetClass = c; case _: }
			case _:
		}
	}

	public static var usageTargetClass:Null<TClass> = null;

	// Under DMUsage/DMImplementation a type is the usage subject, whether the cursor sat on an
	// expression naming it or on a type hint.
	public static var usageTargetType:Null<hxc.core.Type.ModuleType> = null;

	// Legacy field completion at a dangling display dot: a type lists its public statics CONCATENATED
	// with the module's other types. Recorded, not raised, so the surrounding catch Dynamic recovery
	// cannot swallow it (same rule as displayFound).
	public static var fieldCompletionFound:Null<Array<hxc.compiler.DisplayXml.DisplayField>> = null;

	// The typed completion capture for the JSON protocol: each entry keeps the real field plus its origin
	// so CompletionItem.toJson can serialize faithfully (the legacy XML lane above stringifies).
	// receiver/insertPos feed CRField and replaceRange.
	public static var jsonFieldCompletion:Null<{
		entries:Array<{cf:TClassField, scope:hxc.core.Type.ClassFieldScope, originClass:Null<TClass>, originAnon:Null<TAnon>, builtIn:Bool, ?fromParent:Bool}>,
		receiver:Null<TExpr>,
		insertPos:Position,
		// The ORIGIN, which for a structure is the typedef or the @:structInit class the fields came from,
		// not a class each entry declares.
		?originModuleType:hxc.core.Type.ModuleType,
		// Orders a structure's fields by declaration position, so the answer keeps the order it was built
		// in rather than sorting by name the way a field completion does.
		?noSort:Bool,
		// Which CompletionResultKind the answer carries. CRField (0) unless the completion came from
		// somewhere else, like an `override` modifier (CROverride, 12).
		?kind:Int,
		?subjectName:String,
		?subjectPos:Position
	}> = null;

	static function displayFieldCompletion(ctx:TyperContext, e1:Expr, p:Position):TExpr {
		var identName = switch (e1.expr) { case EConst(CIdent(s)): s; case _: null; };
		// The receiver of a dot path is looked up SPECULATIVELY, and the raise is what sends a package
		// prefix to the type-path route in the catch below. hxc reaches it through the REPORTING
		// typeIdent, so the attempt runs with the recording off - the same counter the dot-path head
		// uses. Without it the head to a monomorph and `@:access(pack.<cursor>)` answers an empty field
		// list.
		var speculativeHead = flattenIdentPath(e1.expr) != null;
		if (speculativeHead) identSpeculation++;
		var typed:Null<TExpr> = try typeExpr(ctx, e1, WithTypeTools.value) catch (err:TypingError) {
			if (speculativeHead) { identSpeculation--; speculativeHead = false; }
			// An unresolvable receiver that spells an existing package directory is a dot-path prefix (a
			// metadata argument like @:access(pack.); complete the package instead of reporting. .
			var segments:Array<String> = [];
			function collect(e:Expr):Bool {
				return switch (e.expr) {
					case EConst(CIdent(s)): segments.push(s); true;
					case EField(e2, f, _): if (collect(e2)) { segments.push(f); true; } else false;
					case _: false;
				}
			}
			var allLower = collect(e1);
			if (allLower) for (s in segments) if (s.length == 0 || !(s.charCodeAt(0) >= "a".code && s.charCodeAt(0) <= "z".code)) { allLower = false; break; }
			if (allLower) {
				var rel = segments.join("/");
				var hit = false;
				for (cp in ctx.com.classPath) {
					var dir = cp + rel;
					if (sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir)) { hit = true; break; }
				}
				// The dot-path package raise is the LEGACY answer only; the JSON protocol answers the same
				// position with the toplevel collection instead false whenever json_out is set).
				if (hit && (ctx.com.jsonRpcId == null || hxc.context.DisplayJson.legacyCompletion))
					throw new hxc.parser.Parser.TypePathCompletion(segments, null, false);
				if (hit && displayToplevelJson) throw new JsonToplevelCompletion(collectToplevelJson(ctx));
			}
			if (identName != null && moduleTypeList(ctx, identName) != null) null else throw err;
		};
		if (speculativeHead) identSpeculation--;
		var fields:Array<hxc.compiler.DisplayXml.DisplayField> = [];
		var seen = new haxe.ds.StringMap<Bool>();
		var jsonEntries:Array<{cf:TClassField, scope:hxc.core.Type.ClassFieldScope, originClass:Null<TClass>, originAnon:Null<TAnon>, builtIn:Bool, ?fromParent:Bool}> = [];
		function pushJson(cf:TClassField, scope:hxc.core.Type.ClassFieldScope, originClass:Null<TClass>, originAnon:Null<TAnon>, builtIn:Bool):Void {
			jsonEntries.push({cf: cf, scope: scope, originClass: originClass, originAnon: originAnon, builtIn: builtIn});
		}
		var pushScope:hxc.core.Type.ClassFieldScope = CFSMember;
		var pushOriginClass:Null<TClass> = null;
		var pushOriginAnon:Null<TAnon> = null;
		// Every field is mapped through the instance's parameters, so a field of Array<T> on an `[]`
		// reads as its element monomorph rather than as Array.T.
		var pushParams:Null<TypeParams> = null;
		var pushArgs:Null<TParams> = null;
		function push(cf:TClassField):Void {
			if (seen.exists(cf.name)) return;
			seen.set(cf.name, true);
			var t = switch (cf.type) { case TLazy(r): TypeFunctions.lazyType(r); case t: t; };
			if (pushParams != null && pushArgs != null && pushParams.length > 0)
				t = TypeFunctions.applyParams(pushParams, pushArgs, t);
			pushJson(cf, pushScope, pushOriginClass, pushOriginAnon, false);
			fields.push({
				kind: cf.kind.match(Method(_)) ? "method" : "var",
				name: cf.name,
				type: hxc.core.TPrinting.sTypeStr(t),
				doc: Ast.genDocTextOpt(cf.doc)
			});
		}
		// A field is offered when the current context could actually reach it, which is what the access
		// check decides (@:allow, @:access, a subclass, @:privateAccess). A non-public accessor is hidden
		// whatever access says, and a static never shows an abstract's @:impl members.
		function shouldAccess(c2:TClass, cf:TClassField, stat:Bool):Bool {
			if (TypeFunctions.hasMeta(":noCompletion", cf.meta)) return false;
			if (c2 != ctx.curclass && !TypeFunctions.hasClassFieldFlag(cf, CfPublic) && cf.name.length > 4) {
				var pre = cf.name.substr(0, 4);
				if (pre == "get_" || pre == "set_") return false;
				return hxc.typing.Fields.canAccess(ctx, c2, cf, stat);
			}
			return (!stat || !TypeFunctions.hasClassFieldFlag(cf, CfImpl))
				&& hxc.typing.Fields.canAccess(ctx, c2, cf, stat);
		}
		// A field reported under a type other than its own declared one (an abstract member read without
		// its receiver, a parameter substitution) is copied so the declaration is left untouched.
		function withType(cf:TClassField, t:T):TClassField {
			var c2 = TypeFunctions.mkField(cf.name, t, cf.pos, cf.namePos);
			c2.doc = cf.doc;
			c2.meta = cf.meta;
			c2.kind = cf.kind;
			c2.params = cf.params;
			c2.flags = cf.flags;
			return c2;
		}
		// The fields a type offers, walked structurally. A class walks its hierarchy, a type parameter
		// offers what its constraints do, an abstract offers its own @:impl members plus whatever
		// @:forward lets through, an enum value offers the one EnumValue static, a structure its members,
		// and a
		// function only the magic bind.
		function loopType(t:T):Void {
			switch (TypeFunctions.follow(t)) {
				// A type parameter accesses the fields of its constraints.
				case TInst(c, _) if (c.kind.match(KTypeParameter(_))):
					switch (c.kind) { case KTypeParameter(tl): for (ct in tl) loopType(ct); case _: }
				case TInst(c, tl):
					var savedScope = pushScope;
					pushScope = CFSMember;
					// An interface walks its extends list, a class its super chain. Each level's arguments are
					// written in terms of the level below's parameters, so they carry the substitution up.
					function walkClass(cur:TClass, curArgs:TParams):Void {
						pushOriginClass = cur;
						pushParams = cur.params;
						pushArgs = curArgs;
						for (name in cur.fields.keys()) {
							var cf = cur.fields.get(name);
							if (shouldAccess(cur, cf, false)) push(cf);
						}
						inline function up(c2:TClass, params:TParams):TParams
							return [for (pt in params) TypeFunctions.applyParams(cur.params, curArgs, pt)];
						if (TypeFunctions.hasClassFlag(cur, CInterface)) {
							for (i in cur.interfaces) walkClass(i.c, up(i.c, i.params));
						} else switch (cur.superClass) {
							case null:
							case sup: walkClass(sup.c, up(sup.c, sup.params));
						}
					}
					walkClass(c, tl);
					pushParams = null;
					pushArgs = null;
					pushOriginClass = null;
					pushScope = savedScope;
				// An abstract shows every @:impl field except its constructor, each read without the receiver
				// its impl carries.
				case TAbstract(a, tl) if (a.impl != null):
					var impl = a.impl;
					var savedScope = pushScope;
					pushScope = CFSMember;
					pushOriginClass = impl;
					for (cf in impl.orderedStatics) {
						if (!TypeFunctions.hasClassFieldFlag(cf, CfImpl)) continue;
						if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) continue;
						if (!shouldAccess(impl, cf, false)) continue;
						var ct = switch (cf.type) { case TLazy(r): TypeFunctions.lazyType(r); case t2: t2; };
						ct = switch (TypeFunctions.follow(ct)) {
							case TFun(sig) if (sig.args.length > 0): TFun({args: sig.args.slice(1), ret: sig.ret});
							case t2: t2;
						};
						if (tl.length > 0) ct = TypeFunctions.applyParams(a.params, tl, ct);
						push(withType(cf, ct));
					}
					pushOriginClass = null;
					// With @:forward the UNDERLYING type's fields are collected separately and merged in,
					// keeping only the names the meta lists (all of them when it lists none) and never one
					// the abstract declares itself.
					if (TypeFunctions.hasMeta(":forward", a.meta)) {
						var listed = [for (e in TypeFunctions.getMeta(":forward", a.meta).params)
							switch (e.expr) { case EConst(CIdent(s)): s; case _: null; }];
						var savedFields = fields, savedSeen = seen, savedJson = jsonEntries;
						fields = []; seen = new haxe.ds.StringMap(); jsonEntries = [];
						loopType(TypeFunctions.applyParams(a.params, tl, a.thisType));
						var got = fields, gotJson = jsonEntries;
						fields = savedFields; seen = savedSeen; jsonEntries = savedJson;
						for (i in 0...got.length) {
							var f = got[i];
							if (listed.length > 0 && listed.indexOf(f.name) < 0) continue;
							if (impl.fields.exists(f.name) || impl.statics.exists(f.name)) continue;
							if (seen.exists(f.name)) continue;
							seen.set(f.name, true);
							fields.push(f);
							jsonEntries.push(gotJson[i]);
						}
					}
					pushScope = savedScope;
				// An enum value carries EnumValue's `match`, nothing else.
				case TEnum(_, _):
					var ev = try Typeload.resolveTypePath(ctx.com, {pack: [], name: "EnumValue"}, null, p) catch (_:Dynamic) null;
					switch (ev) {
						case TAbstractDecl(a) if (a.impl != null):
							var cf = a.impl.statics.get("match");
							if (cf != null) push(cf);
						case _:
					}
				// An unbound monomorph offers what its STRUCTURAL constraints require. A closed structure
				// BINDS the monomorph and the bound type answers; an open one offers the constraint's own
				// fields.
				case TMono(m):
					function foldConstraints(k:hxc.core.Type.TMonoConstraintKind):Void switch (k) {
						case CStructural(cfields, isOpen):
							if (!isOpen) {
								hxc.core.TypeUnification.close(m);
								if (m.type != null) loopType(m.type);
							} else loopType(TypeFunctions.mkAnon(new hxc.core.Ref(Closed), cfields));
						case CMixed(l): for (k2 in l) foldConstraints(k2);
						case CTypes(_) | CUnknown:
					}
					foldConstraints(TypeFunctions.monomorphClassifyConstraintsRef(m));
				case TAnon(an):
					var savedAnon = pushOriginAnon;
					pushOriginAnon = an;
					// The statics of a @:forwardStatics abstract's UNDERLYING class come first, before the
					// impl's own.
					var fwdAbstract:Null<TAbstract> = switch (an.status.get()) {
						case Statics(sc): switch (sc.kind) { case KAbstractImpl(a): a; case _: null; };
						case AbstractStatics(a): a;
						case _: null;
					};
					if (fwdAbstract != null && TypeFunctions.hasMeta(":forwardStatics", fwdAbstract.meta))
						switch (TypeFunctions.follow(fwdAbstract.thisType)) {
							case TInst(uc, _):
								var savedC = pushOriginClass;
								pushOriginClass = uc;
								for (cf in uc.orderedStatics)
									if (shouldAccess(uc, cf, true)) push(cf);
								pushOriginClass = savedC;
							case _:
						}
					for (name in an.fields.keys()) push(an.fields.get(name));
					pushOriginAnon = savedAnon;
				// A function has no field except the magic bind, which takes and returns the same signature
				// with every argument made optional.
				case TFun(sig):
					if (!seen.exists("bind")) {
						var opt = TFun({args: [for (a2 in sig.args) {name: a2.name, opt: true, t: a2.t}], ret: sig.ret});
						var cf = TypeFunctions.mkField("bind", TypeFunctions.tfun([opt], opt), p, Position.nullPos);
						cf.kind = Method(MethNormal);
						push(cf);
					}
				case _:
			}
		}
		// A single-character string constant offers the compile-time `code` field first.
		switch (e1.expr) {
			case EConst(CString(s, _)) if (s.length == 1):
				seen.set("code", true);
				fields.push({kind: "var", name: "code", type: "Int",
					doc: "The character code of this character (inlined at compile-time)."});
			case _:
		}
		if (typed != null) switch (typed.expr) {
			case TTypeExpr(TClassDecl(c)):
				// Private statics complete inside their declaring class.
				pushScope = CFSStatic;
				pushOriginClass = c;
				for (cf in c.orderedStatics)
					if (shouldAccess(c, cf, true)) push(cf);
			case _:
				// Fields of the value's type. (loop on e.type).
				loopType(typed.type);
		}
		// The static extensions in scope are part of a field completion. They come after the receiver's
		// own fields, which is what the `seen` check in push already expresses (a name the type itself
		// provides is skipped). The using loop runs on the receiver's type whatever the receiver is, so
		// `C.<cursor>` collects the extensions declared over Class<C> too.
		if (typed != null) switch (typed.expr) {
			case _:
				pushScope = CFSMember;
				pushOriginClass = null;
				pushOriginAnon = null;
				pushParams = null;
				pushArgs = null;
				hxc.typing.Fields.collectUsingFields(ctx, typed, p, function(cf, t) {
					if (seen.exists(cf.name)) return;
					seen.set(cf.name, true);
					pushJson(cf, CFSMember, null, null, false);
					fields.push({
						kind: cf.kind.match(Method(_)) ? "method" : "var",
						name: cf.name,
						type: hxc.core.TPrinting.sTypeStr(t),
						doc: Ast.genDocTextOpt(cf.doc)
					});
				});
		}
		jsonFieldCompletion = {entries: jsonEntries, receiver: typed, insertPos: p};
		// The statics list CONCATENATES the module's other types (the same-named main type
		// excluded), whether or not any statics exist.
		if (identName != null) {
			var ml = moduleTypeList(ctx, identName);
			if (ml != null) fields = fields.concat(ml);
		} else {
			// A dotted receiver naming a module lists all the module's types with their dotted paths.
			var segs:Array<String> = [];
			function collect(e:Expr):Bool {
				return switch (e.expr) {
					case EConst(CIdent(s)): segs.push(s); true;
					case EField(e2, f, _): if (collect(e2)) { segs.push(f); true; } else false;
					case _: false;
				}
			}
			if (collect(e1) && segs.length >= 2) {
				var mpath:hxc.core.Globals.Path = {pack: segs.slice(0, segs.length - 1), name: segs[segs.length - 1]};
				var m = try hxc.context.ModuleLoader.loadModule(ctx.com, mpath, Position.nullPos) catch (_:Dynamic) null;
				if (m != null) for (mt in m.types) {
					var info = TypeFunctions.tInfos(mt);
					if (info.isPrivate) continue;
					fields.push({kind: "type", name: info.path.name, type: hxc.core.Globals.sTypePath(info.path), doc: null});
				}
			}
		}
		if (fieldCompletionFound == null) fieldCompletionFound = fields;
		return TypeFunctions.mk(TConst(TNull), spawnMonomorph(ctx, p), p);
	}

	static function moduleTypeList(ctx:TyperContext, name:String):Null<Array<hxc.compiler.DisplayXml.DisplayField>> {
		var m = try hxc.context.ModuleLoader.loadModule(ctx.com, {pack: [], name: name}, Position.nullPos) catch (_:Dynamic) null;
		if (m == null) return null;
		return [for (mt in m.types) {
			var path = TypeFunctions.tPath(mt);
			if (path.name == name) continue;
			{kind: "type", name: path.name, type: path.name, doc: null};
		}];
	}

	// A call whose ARGUMENTS fail to unify still resolves its callee; the definition records
	// from the resolved access before argument typing can abort the call.
	public static function noteDisplayAccess(ctx:TyperContext, acc:AccessKind, pos:Position):Void {
		if (!displayDefinition || displayFound != null || !atDisplayPos(pos)) return;
		switch (acc) {
			case AKExpr(te): checkDisplayDefinition(ctx, te);
			case AKField(fa) | AKAccessor(fa):
				// Go through the field EXPRESSION rather than claiming the position outright: the
				// receiver may be what the cursor is actually on, and only the recursion knows.
				var te = try hxc.typing.FieldAccessTools.getFieldExpr(fa, FRead) catch (_:Dynamic) null;
				if (te != null) checkDisplayDefinition(ctx, te);
				if (displayFound == null) displayFound = [fa.field.namePos];
			// A static-extension callee resolves to a field just the same; the OVERLOAD the call
			// selected is the one to report.
			case AKUsingField(se) | AKUsingAccessor(se):
				// The RECEIVER is its own node: `|e.toString()` asks about e, not about the
				// static extension it is passed to.
				if (se.thisExpr != null && atDisplayPos(se.thisExpr.pos)) checkDisplayDefinition(ctx, se.thisExpr);
				else displayFound = [se.access.field.namePos];
			case _:
		}
	}

	// Walks up until a class actually declares a constructor.
	static function superConstructor(c:Null<TClass>):Null<TClassField> {
		var cur = c;
		while (cur != null) {
			if (cur.constructor != null) return cur.constructor;
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return null;
	}

	// The same post-order redundancy as checkDisplayHover, and the same memo. This one only
	// short-circuits once a declaration is found; until then every enclosing node re-walks the whole
	// subtree, so an expression that answers nothing (a chain of parentheses around a literal) is the
	// quadratic case.
	static var definitionWalked:haxe.ds.ObjectMap<TExpr, Bool> = new haxe.ds.ObjectMap();

	static function checkDisplayDefinition(ctx:TyperContext, te:TExpr):Void {
		if (displayFound != null) return;
		if (definitionWalked.exists(te)) return;
		definitionWalked.set(te, true);
		// A sub-expression that still encloses the offset is the more precise match: recurse
		// into any PROPER enclosing sub-range first (an assignment target or call argument
		// types inside a wrapper whose own node carries no declaration).
		TexprTools.iter(function(child) {
			if (displayFound == null && atDisplayPos(child.pos)
				&& (child.pos.min > te.pos.min || child.pos.max < te.pos.max))
				checkDisplayDefinition(ctx, child);
		}, te);
		if (displayFound != null) return;
		var pl:Array<Position> = switch (te.expr) {
			case TField(_, FEnum(_, ef)): [ef.namePos];
			case TField(_, FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf)): [cf.namePos];
			case TLocal(v): [v.pos];
			// A declaration reports itself, but only when the cursor sits on the name; an offset inside the
			// initializer whose own extraction found nothing must not claim it. The `this` an abstract
			// constructor is rewritten around carries the whole constructor's position, so without this it
			// claimed every cursor inside the body.
			case TVarExpr(v, _) if (v.kind.match(VUser(_)) && atDisplayPos(v.pos)): [v.pos];
			case TTypeExpr(mt): [TypeFunctions.tInfos(mt).namePos];
			case TNew(c, _, _): c.constructor != null ? [c.constructor.namePos] : [];
			// `super(...)` reports the SUPER constructor, and a bare `super` the super class.
			case TCall({expr: TConst(TSuper)}, _):
				var sup = ctx.curclass == null ? null : ctx.curclass.superClass;
				var ctor = sup == null ? null : superConstructor(sup.c);
				ctor == null ? [] : [ctor.namePos];
			case TConst(TSuper):
				var sup = ctx.curclass == null ? null : ctx.curclass.superClass;
				sup == null ? [] : [sup.c.namePos];
			// Walk into a call's CALLEE and a cast's operand STRUCTURALLY, with no position test of their
			// own: `n|ew X()` on an abstract types as a call to the impl's _new, whose own position is
			// nowhere near the cursor.
			case TCall(e1, _) | TCast(e1, _):
				checkDisplayDefinition(ctx, e1);
				[];
			// `A.new` types as a function whose whole body returns the construction, and the display is a
			// question about that constructor.
			case TFunction({expr: {expr: TReturn(e1 = {expr: TNew(_, _, _)})}}) if (e1 != null):
				checkDisplayDefinition(ctx, e1);
				[];
			case _: [];
		};
		if (pl.length > 0) displayFound = pl;
	}

	// A @:structInit class's completable fields are the ARGUMENTS its constructor accepts, with the
	// receiver's type parameters applied, each reported at the declared field of that name. A class whose
	// constructor cannot be read contributes every var field it declares instead.
	// The completion answer needs the same anon without a typer context (the collection is already raised
	// by then); only the ctor-signature branch wanted one.
	public static function structInitAnonForCompletion(withType:WithType):Null<TAnon> {
		return try structInitAnonFields(null, withType) catch (_:Dynamic) null;
	}

	static function structInitAnonFields(ctx:TyperContext, withType:WithType):Null<TAnon> {
		var hit = switch (withType) {
			case WithType(wt, _): switch (TypeFunctions.follow(wt)) {
				case TInst(c, tl) if (TypeFunctions.hasMeta(":structInit", c.meta)): {c: c, tl: tl};
				case _: null;
			};
			case _: null;
		};
		if (hit == null) return null;
		var c = hit.c;
		// A @:structInit class needs its constructor while its FIELDS type, so there is always a signature
		// to read - including the super's arguments. hxc synthesizes it in a filter, long after a
		// completion runs, so it is forced here.
		if (c.constructor == null && ctx != null) try ensureStructInitCtor(ctx, c) catch (_:Dynamic) {}
		var ctor = c.constructor;
		var sig = ctor == null ? null : switch (try findConstructorType(ctx, c, hit.tl) catch (_:Dynamic) null) {
			case null: null;
			case ct: switch (TypeFunctions.follow(ct)) { case TFun(s): s; case _: null; };
		};
		var fields = new haxe.ds.StringMap<TClassField>();
		if (sig != null) {
			// The constructor's own doc is read as JAVADOC, and each argument takes its documentation from
			// the matching @param tag.
			var jd = switch (Ast.genDocTextOpt(ctor.doc)) {
				case null: null;
				case d: new hxc.core.Javadoc(d);
			}
			// With a typed constructor body every argument reports its own VAR position, so a field
			// forwarded from a superclass reports where that field is declared; in the bodyless case a field
			// of this class reports its own name and doc.
			var tfArgs:Null<Array<TFuncArg>> = ctor.expr == null ? null : switch (ctor.expr.expr) {
				case TFunction(fn): fn.args;
				case _: null;
			}
			for (arg in sig.args) {
				var np = ctor.namePos;
				var doc:hxc.ast.Ast.Documentation = null;
				if (tfArgs != null) {
					for (fa in tfArgs) if (fa.v.name == arg.name) { np = fa.v.pos; break; }
					doc = jd == null ? null : Ast.docFromStringOpt(jd.getParamInfo(arg.name));
				} else {
					var decl = c.fields.get(arg.name);
					if (decl != null) { np = decl.namePos; doc = decl.doc; }
					else doc = jd == null ? null : Ast.docFromStringOpt(jd.getParamInfo(arg.name));
				}
				var cf = TypeFunctions.mkField(arg.name, arg.t, np, np);
				cf.doc = doc;
				fields.set(arg.name, cf);
			}
		} else {
			for (name in c.fields.keys()) {
				var cf = c.fields.get(name);
				switch (cf.kind) {
					case Var(_):
						var cf2 = TypeFunctions.mkField(cf.name, TypeFunctions.applyParams(c.params, hit.tl, cf.type), cf.namePos, cf.namePos);
						cf2.doc = cf.doc;
						fields.set(name, cf2);
					case _:
				}
			}
		}
		if (!fields.keys().hasNext()) return null;
		return {fields: fields, status: new hxc.core.Ref(Closed)};
	}

	static function expectedAnonFromWithType(ctx:TyperContext, withType:WithType):Null<TAnon> {
		return switch (withType) {
			case WithType(t, _):
				switch (expectedAnonFromType(ctx, t, [])) {
					// An empty expected structure imposes no field requirements: the literal types plainly
					// and unification decides, so `({name:1} : {})` and an abstract `from {}` both accept
					// any object.
					case ODKStructure(a) if (a.fields.keys().hasNext()): a;
					case _: null;
				}
			case _: null;
		}
	}

	static function expectedAnonFromType(ctx:TyperContext, t:T, seen:Array<T>):ObjectDeclKind {
		return switch (TypeFunctions.follow(t)) {
			case TAnon(a):
				ODKStructure(a);
			// Dynamic<T> types every field at T (an empty structure expectation with a dynamic parameter).
			case TDynamic(dt) if (dt != null):
				ODKDynamic(dt);
			case TAbstract(a, params) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				for (old in seen) if (TypeUnification.shallowEq(t, old)) return ODKPlain;
				// Every non-plain candidate counts, INCLUDING a nested ambiguity: a from-type that is
				// itself an abstract with several structure candidates keeps the outer level ambiguous
				// (EitherType<Range, EitherType<A, B>> types its literal plainly).
				var hits:Array<ObjectDeclKind> = [];
				var nextSeen = seen.concat([t]);
				function consider(ft:T):Void {
					switch (expectedAnonFromType(ctx, ft, nextSeen)) {
						case ODKPlain:
						case odk: hits.push(odk);
					}
				}
				// The candidates come from getAbstractFroms, so a from-field's own type parameters are
				// fresh monomorphs rather than raw parameter types leaking into field expectations.
				for (ft in getAbstractFroms(ctx, a, params))
					consider(ft);
				switch (hits) {
					case []: ODKPlain;
					case [one]: one;
					case _: ODKFailed;
				}
			case _:
				ODKPlain;
		}
	}

	// Desugar single-quote string interpolation ('$ident' / '${expr}') into concatenation.
	public static function formatString(str:String, p:Position, ?defines:hxc.core.Define):Expr {
		function isIdentStart(c:Int):Bool return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code;
		function isIdentChar(c:Int):Bool return isIdentStart(c) || (c >= "0".code && c <= "9".code);
		var parts:Array<Expr> = [];
		function spaces(n:Int):String {
			var out = new StringBuf();
			for (_ in 0...n) out.addChar(" ".code);
			return out.toString();
		}
		var i = 0;
		var n = str.length;
		// Each fragment carries its own CONTENT span (one past the opening quote); a plain string fragment
		// spans the source it consumed, built from SUBSTRINGS so multi-byte content passes through
		// untouched.
		var frag = "";
		var fragStart = 0;
		var segStart = 0;
		// Every apostrophe scanned bumps the position by one, because the source spelled it `'` (two
		// characters) while the string value holds one. Every part positioned after such an apostrophe
		// therefore sits one further right per apostrophe already scanned.
		// Parsing resumes after a group's closing brace, so the inside of a `${...}` is never walked: an
		// apostrophe there is ordinary source that was never spelled `'`, and must not shift the parts that
		// follow.
		function aposAt(idx:Int):Int {
			var n2 = 0;
			var k = 0;
			while (k < idx) {
				var ck = str.charCodeAt(k);
				if (ck == "'".code) n2++;
				if (ck == "$".code && k + 1 < n && str.charCodeAt(k + 1) == "{".code) {
					var depth = 1;
					var j = k + 2;
					while (j < n && depth > 0) {
						var cj = str.charCodeAt(j);
						if (cj == "{".code) depth++;
						else if (cj == "}".code) depth--;
						j++;
					}
					k = j;
					continue;
				}
				k++;
			}
			return n2;
		}
		// The part offsets are BYTE counts into the string value, while p.min came from the lexer in code
		// points. Every offset added to p.min is therefore a UTF-8 byte count, so a part following a
		// non-ASCII character sits one column further right per extra byte.
		function byteOff(idx:Int):Int {
			var n2 = idx;
			for (k in 0...idx) {
				var c = StringTools.unsafeCodeAt(str, k);
				if (c >= 0x80)
					n2 += if (c < 0x800) 1 else if (c <= 0xDFFF && c >= 0xD800) 1 else if (c < 0x10000) 2 else 3;
			}
			return n2;
		}
		function flush(forceEmpty:Bool = false) {
			if (frag == "" && i > segStart) fragStart = segStart;
			frag += str.substring(segStart, i);
			segStart = i;
			if (frag != "") {
				var adj = aposAt(i);
				parts.push(new Expr(EConst(CString(frag, SDoubleQuotes)), new Position(p.file, p.min + 1 + byteOff(fragStart) + adj, p.min + 1 + byteOff(i) + adj)));
				frag = "";
			} else if (forceEmpty && parts.length == 0) {
				// A string STARTING with an interpolation leads with an empty literal so the chain
				// concatenates as String.
				var adj = aposAt(i);
				parts.push(new Expr(EConst(CString("", SDoubleQuotes)), new Position(p.file, p.min + 1 + byteOff(i) + adj, p.min + 1 + byteOff(i) + adj)));
			}
		}
		while (i < n) {
			var c = str.charCodeAt(i);
			if (c == "$".code && i + 1 < n) {
				var d = str.charCodeAt(i + 1);
				if (d == "$".code) {
					// One dollar stays; the segment split skips its twin.
					if (frag == "") fragStart = segStart;
					frag += str.substring(segStart, i + 1);
					segStart = i + 2;
					i += 2;
				}
				else if (d == "{".code) {
					flush(true);
					var depth = 1;
					var j = i + 2;
					var sb = new StringBuf();
					while (j < n && depth > 0) {
						var cj = str.charCodeAt(j);
						if (cj == "{".code) { depth++; sb.addChar(cj); }
						else if (cj == "}".code) { depth--; if (depth > 0) sb.addChar(cj); }
						else sb.addChar(cj);
						j++;
					}
					if (StringTools.trim(sb.toString()) == "")
						throw new TypingError("Expression cannot be empty", new Position(p.file, p.min + byteOff(i) + 3, p.min + byteOff(j)));
					try {
						var exprStart = p.min + byteOff(i) + 3 + aposAt(i);
						parts.push(hxc.parser.Parser.parseExprString(spaces(exprStart) + sb.toString(), p.file, defines));
					} catch (err:hxc.parser.ParserError) {
						throw new TypingError(hxc.parser.ParserError.errorMsg(err.msg), err.pos);
					}
					i = j;
					segStart = i;
				} else if (isIdentStart(d)) {
					flush(true);
					var j = i + 1;
					var sb = new StringBuf();
					while (j < n && isIdentChar(str.charCodeAt(j))) { sb.addChar(str.charCodeAt(j)); j++; }
					// The ident's own source range: content starts one past the opening quote.
					var adjI = aposAt(i);
					parts.push(new Expr(EConst(CIdent(sb.toString())), new Position(p.file, p.min + byteOff(i) + 2 + adjI, p.min + byteOff(j) + 1 + adjI)));
					i = j;
					segStart = i;
				} else i++;
			} else i++;
		}
		flush();
		// The first fragment stands alone; pairs union their spans (no leading empty literal).
		if (parts.length == 0) return new Expr(EConst(CString("", SDoubleQuotes)), p);
		var acc = parts[0];
		for (k in 1...parts.length) acc = new Expr(EBinop(OpAdd, acc, parts[k]), Position.union(acc.pos, parts[k].pos));
		return acc;
	}

	static function typeConst(ctx:TyperContext, c:Constant, p:Position, mode:AccessMode, withType:WithType):TExpr {
		var basic = ctx.com.basic;
		return switch (c) {
			case CIdent(s):
				// Carries `not !was_annotated`: exactly one node in the expression is the display subject. A
				// field access already answered here is that node, so a stand-in the recovery put at an
				// enclosing position must not displace it.
				if (displayToplevelJson && atDisplayPos(p) && fieldCompletionFound == null)
					throw new JsonToplevelCompletion(collectToplevelJson(ctx, withType), s == "null" ? null : s, p, withType);
				if (displayToplevel && atDisplayPos(p) && fieldCompletionFound == null)
					// The recovery's `null` stand-in is an empty subject, and exactly when the subject is empty. A
					// real identifier under the cursor keeps the collection order.
					throw new hxc.compiler.DisplayXml.ToplevelCompletion(collectToplevel(ctx, withType, s == "null"));
				if (s == "super" && !withType.match(NoValue)) throw new TypingError("Cannot use super as value", p);
				accGet(ctx, typeIdent(ctx, s, p, mode, withType));
			case CInt(s, suffix):
				if (suffix == null) TexprTools.typeConstant(basic, c, p);
				else switch (suffix) {
					case "i32":
						// A 32-bit literal: hex takes its bits (0xFFFFFFFFi32 = -1), decimal
						// must fit the signed 32-bit range.
						var s2 = StringTools.replace(s, "_", "");
						var i:Null<Int> = TexprTools.parseInt32Literal(s2);
						if (i == null) throw new TypingError("Cannot represent " + s + " with a 32 bit integer", p);
						TypeFunctions.mk(TConst(TInt(i)), basic.tint, p);
					case "i64":
						// NNNi64 is a haxe.Int64 literal: split the 64-bit value into high/low halves and
						// build haxe.Int64.make(high, low).
						var v = parseInt64Literal(StringTools.replace(s, "_", ""));
						function intExpr(n:Int):Expr return new Expr(EConst(CInt(Std.string(n), null)), p);
						var mk = new Expr(EField(new Expr(EField(new Expr(EConst(CIdent("haxe")), p), "Int64", EFNormal), p), "make", EFNormal), p);
						var call = new Expr(ECall(mk, [intExpr(v.high), intExpr(v.low)]), p);
						typeExpr(ctx, call, withType);
					case "u32":
						// NNNu32 is `(NNN : UInt)`.
						var inner = new Expr(EConst(CInt(s, null)), p);
						var ct:TypeHint = {ct: CTPath({tpackage: [], tname: "UInt", tparams: [], tsub: null}), pos: p};
						typeExpr(ctx, new Expr(ECheckType(inner, ct), p), withType);
					case other: throw new TypingError(other + " is not a valid integer suffix", p);
				}
			case CFloat(s, suffix):
				if (suffix == null) TexprTools.typeConstant(basic, c, p);
				else switch (suffix) {
					case "f64": TexprTools.typeConstant(basic, CFloat(s, null), p);
					case other: throw new TypingError(other + " is not a valid float suffix", p);
				}
			// Every non-empty single-quoted string routes through the interpolation builder, not just
			// $-containing ones: the resulting constant carries the CONTENT span (quotes excluded), which
			// downstream errors report.
			case CString(str, SSingleQuotes) if (str != ""):
				var te = typeExpr(ctx, formatString(str, p), withType);
				// The parts start one past the literal and union their spans, so the CHAIN covers neither
				// quote nor the gaps around an interpolation brace. Display marks the SOURCE literal and
				// answers with what it typed to, so those positions still report String; hxc scans typed
				// nodes, and the literal has none of its own after the rewrite. Record one over its whole
				// span.
				if ((displayHover || displayTypeDefinition) && atExprHoverPos(p))
					noteLiteralHover(ctx, te, p, withType);
				te;
			case CString(_, _):
				TexprTools.typeConstant(basic, c, p);
			case CRegexp(r, opt):
				var tp:PlacedTypePath = {path: {tpackage: [], tname: "EReg", tparams: [], tsub: null}, pos: p};
				var args = [new Expr(EConst(CString(r, SDoubleQuotes)), p), new Expr(EConst(CString(opt, SDoubleQuotes)), p)];
				typeNew(ctx, tp, args, withType, p, false);
		};
	}

	// Type_ident (subset): locals and the literal idents. Member/static fields, types, imports, and globals
	// resolve in the fields-dispatch unit.
	public static function assignToThisIsAllowed(ctx:TyperContext):Bool {
		return switch (ctx.curclass.kind) {
			case KAbstractImpl(_):
				switch (ctx.curfield.kind) {
					case Method(MethInline): true;
					case Method(_): ctx.curfield.name == "_new" || ctx.curfield.name == "new";
					case _: false;
				}
			case _: false;
		};
	}

	static function typeIdent(ctx:TyperContext, i:String, p:Position, mode:AccessMode, withType:WithType):AccessKind {
		// A reified $i{""} produces an empty ident.
		if (i == "") throw new TypingError("Identifier name must not be empty", p);
		// With the identifier as the SUBJECT: a cursor inside a name is a completion request on it.
		// typeConst covers the value positions; a CALLEE is resolved here instead and never reached that
		// check, so `f|oo("")` answered nothing.
		if ((displayToplevel || displayToplevelJson) && fieldCompletionFound == null && mode.match(MCall(_)) && atDisplayPos(p)) {
			if (displayToplevelJson) throw new JsonToplevelCompletion(collectToplevelJson(ctx, withType), i, p, withType);
			throw new hxc.compiler.DisplayXml.ToplevelCompletion(collectToplevel(ctx, withType));
		}
		if (i == "abstract") {
			return switch [mode, ctx.curclass.kind] {
				case [MSet(_), KAbstractImpl(_)]: throw new TypingError("Property 'abstract' is read-only", p);
				case [MGet, KAbstractImpl(a)] | [MCall(_), KAbstractImpl(a)]:
					var v = ctx.locals.get("this");
					if (v == null) throw new TypingError("Cannot reference this abstract here", p);
					var tl = TypeFunctions.extractParamTypes(a.params);
					AKExpr(TypeFunctions.mk(TLocal(v), TAbstract(a, tl), p));
				case _:
					throw new TypingError("Property 'abstract' is reserved and only available in abstracts", p);
			}
		}
		// Assigning the abstract's this marks the method as modifying it and requires an inline (or
		// constructor) context.
		if (i == "this" && mode.match(MSet(_)) && ctx.locals.exists("this") && ctx.curclass.kind.match(KAbstractImpl(_))) {
			TypeFunctions.addClassFieldFlag(ctx.curfield, CfModifiesThis);
			if (!assignToThisIsAllowed(ctx))
				throw new TypingError("Abstract 'this' value can only be modified inside an inline function", p);
		}
		if (ctx.locals.exists(i)) {
			var v = ctx.locals.get(i);
			// Every local the typer looks up is flagged, which is what the unused-variable diagnostic
			// tests.
			TypeFunctions.addVarFlag(v, VUsedByTyper);
			// A local inline function resolves through a fake extern class holding an inline method, so a
			// call reuses the regular inline machinery (outer locals referenced by the body pass through as
			// captures-by-substitution). Reading or assigning the name is an error.
			// The inline-closure emulation is gated on dmsInline, which is false for every display mode:
			// hover on the callee must see the closure's function type, not the inlined body.
			if (v.extra != null && v.extra.expr != null && ctx.com.displaySpec == null) switch (v.extra.expr.expr) {
				case TFunction(_):
					switch (mode) {
						case MCall(_):
							var fnExpr = v.extra.expr;
							var fake = TypeFunctions.mkClass(ctx.curclass.module, {pack: ["local"], name: v.name}, fnExpr.pos, Position.nullPos);
							TypeFunctions.addClassFlag(fake, CExtern);
							var cf = TypeFunctions.mkField(v.name, v.type, fnExpr.pos, Position.nullPos);
							cf.params = v.extra.params;
							cf.expr = fnExpr;
							cf.kind = Method(MethInline);
							fake.fields.set(cf.name, cf);
							var eNull = TypeFunctions.mk(TConst(TNull), TInst(fake, []), p);
							return AKField(FieldAccessTools.create(eNull, cf, FHInstance(fake, []), true, p));
						case MSet(_):
							throw new TypingError("Cannot set inline closure", p);
						case MGet:
							throw new TypingError("Cannot create closure on inline closure", p);
					}
				case _:
			}
			return AKExpr(TexprTools.makeLocal(v, p));
		}
		switch (i) {
			case "null":
				// With an expected type the null literal adopts it directly; an expected unbound monomorph
				// is raw-bound to Null<?> (no constraint close) unless already nullable. The literal
				// reusing the expected type instance keeps the equality unify a no-op, so a constrained
				// mono is not closed by a null comparison.
				var tnull:T = switch (withType) {
					case WithType(wt, _):
						switch (TypeFunctions.follow(wt)) {
							case TMono(r) if (!TypeFunctions.isNullable(wt)):
								TypeUnification.doBind(r, ctx.com.basic.tnull(spawnMonomorph(ctx, p)));
							case _:
						}
						wt;
					case _:
						ctx.com.basic.tnull(spawnMonomorph(ctx, p));
				};
				// The null literal is readable but never writable, and the AKNo is what makes a write
				// report "This expression cannot be accessed for writing" rather than falling through to
				// the assignment check's "Invalid assign" (`null = 1`, `null += 1`, `++null`).
				var accNull = AKExpr(TypeFunctions.mk(TConst(TNull), tnull, p));
				return mode.match(MGet) ? accNull : AKNo(accNull, p);
			case "true":
				var accT = AKExpr(TexprTools.makeBool(ctx.com.basic, true, p));
				return mode.match(MGet) ? accT : AKNo(accT, p);
			case "false":
				var accF = AKExpr(TexprTools.makeBool(ctx.com.basic, false, p));
				return mode.match(MGet) ? accF : AKNo(accF, p);
			// `this` reads freely but is only WRITABLE inside an abstract, where the write is the
			// abstract's underlying value; anywhere else the access is AKNo, which makes `this = x` report
			// "cannot be accessed for writing" instead of "Invalid assign". MCall gets the same treatment.
			case "this":
				var accThis = AKExpr(getThis(ctx, p));
				return switch (mode) {
					case MSet(_):
						if (ctx.curfield != null) TypeFunctions.addClassFieldFlag(ctx.curfield, CfModifiesThis);
						switch (ctx.curclass.kind) {
							case KAbstractImpl(_):
								if (!assignToThisIsAllowed(ctx))
									throw new TypingError("Abstract 'this' value can only be modified inside an inline function", p);
								accThis;
							case _: AKNo(accThis, p);
						}
					case MCall(_):
						switch (ctx.curclass.kind) {
							case KAbstractImpl(_): accThis;
							case _: AKNo(accThis, p);
						}
					case MGet: accThis;
				};
			case _:
		}
		if (ctx.curclass != TypeFunctions.nullClass) {
			// Member-variable lookup searches the whole inheritance chain, not just the class's own fields,
			// so a bare call to an inherited method resolves against `this`. The access uses the class the
			// field was found in as its host.
			if (!ctx.curfun.match(FunStatic)) {
				var found = TypeFunctions.rawClassFieldOpt(function(f) return TypeFunctions.fieldType(f), ctx.curclass, TypeFunctions.extractParamTypes(ctx.curclass.params), i);
				if (found != null) {
					var thisExpr = getThis(ctx, p);
					var host:FieldHost = switch (found.c2) { case null: FHAnon; case cw: FHInstance(cw.c, cw.params); };
					// Dispatch on the field kind so a property read/write goes through its accessor
					// (get_/set_), not a raw field access.
					return Fields.fieldAccess(ctx, mode, found.f, host, thisExpr, p);
				}
			}
			var smf = ctx.curclass.statics.get(i);
			if (smf != null) {
				if (TypeFunctions.hasClassFieldFlag(smf, CfImpl)
					&& !TypeFunctions.hasClassFieldFlag(ctx.curfield, CfImpl)
					&& !TypeFunctions.hasClassFieldFlag(smf, CfEnum))
					throw new TypingError("Cannot access non-static field " + smf.name + " from static method", p);
				// Inside an abstract impl method, a bare call to a sibling member method threads `this`.
				var absImpl = switch (ctx.curclass.kind) { case KAbstractImpl(ab): ab; case _: null; };
				if (absImpl != null && TypeFunctions.hasClassFieldFlag(smf, CfImpl) && !TypeFunctions.hasClassFieldFlag(smf, CfEnum)) {
					var thisExpr = getThis(ctx, p);
					// The `this` node is retyped to the abstract before the field access, so threading it on to a
					// sibling member casts it back down to the underlying type. Without that cast the inliner
					// would see a bare TLocal and substitute where it should bind a temp.
					var atl = TypeFunctions.extractParamTypes(absImpl.params);
					thisExpr = TypeFunctions.mk(thisExpr.expr, TAbstract(absImpl, atl), thisExpr.pos);
					// A bare reference to a sibling abstract member threads `this`: a method becomes a
					// static extension call, a var/property dispatches through its accessor (get_/set_)
					// rather than emitting a raw static field access.
					switch (smf.kind) {
						case Method(_):
							// The access is hosted on FHAbstract, which makes the call unify the receiver as the applied
							// underlying type rather than as the abstract it was just retyped to.
							return AKUsingField(FieldAccessTools.makeAbstractStaticExtensionAccess(absImpl, atl, ctx.curclass, smf, thisExpr, false, p));
						case Var(_):
							return Fields.fieldAccess(ctx, mode, smf, FHAbstract(absImpl, atl, ctx.curclass), thisExpr, p);
					}
				}
				var typeExpr = TexprTools.makeTypeExpr(TClassDecl(ctx.curclass), p);
				return Fields.fieldAccess(ctx, mode, smf, FieldAccessTools.getHost(ctx.curclass, smf), typeExpr, p);
			}
		}
		switch (withType) {
			case WithType(wt, _):
				var expectedEnum = expectedEnumLike(wt, []);
				if (expectedEnum != null && expectedEnum.constrs.exists(i)) {
					var acc = Fields.enumConstructor(ctx, expectedEnum, TexprTools.makeTypeExpr(TEnumDecl(expectedEnum), p), i, p);
					// A constructor function's return unifies with the expected type so the enum's type
					// parameters bind from the expectation before the arguments; failure is ignored. .
					switch (acc) {
						case AKExpr(te):
							switch (TypeFunctions.follow(te.type)) {
								case TFun(sig): try TypeUnification.unifyDefault(sig.ret, wt) catch (_:UnifyError) {};
								case _:
							}
						case _:
					}
					return acc;
				}
				switch (TypeFunctions.follow(wt)) {
					case TAbstract(a, tl) if (a.isEnum && a.impl != null && a.impl.statics.exists(i)):
						// An enum-abstract value used unqualified resolves against the expected type, like an
						// enum constructor: look it up as an @:enum static on the abstract's impl class.
						var cf = a.impl.statics.get(i);
						if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) {
							// The access over FHAbstract with the abstract's own params and leaves the field alone.
							// Rebinding type to the EXPECTED type's params instead overwrote the member's declared type
							// on the shared field, so `var fruit:TagE<Tag1>` came back as TagE<T> and a `case fruit:` no
							// longer narrowed T. Typing the initializer put the declared type back, which is what hid
							// it.
							var typeExpr = TexprTools.makeTypeExpr(TClassDecl(a.impl), p);
							return Fields.fieldAccess(ctx, mode, cf,
								FHAbstract(a, TypeFunctions.extractParamTypes(a.params), a.impl), typeExpr, p);
						}
					case _:
				}
			case _:
		}
		var bareEnum = findBareEnumLike(ctx, i);
		if (bareEnum != null) switch (bareEnum) {
			case TEnumDecl(en):
				return Fields.enumConstructor(ctx, en, TexprTools.makeTypeExpr(TEnumDecl(en), p), i, p);
			case TAbstractDecl(a) if (a.impl != null):
				var cf = a.impl.statics.get(i);
				// Without an expected type the value's abstract parameters are fresh constrained
				// monomorphs, not the declared type parameters. (the enum field type unifies with
				// TAbstract(a, spawnConstrainedMonos ...)).
				if (TypeFunctions.hasClassFieldFlag(cf, CfEnum))
					cf.type = TAbstract(a, TypeUnification.spawnConstrainedMonos(function(t) return t, a.params));
				return Fields.fieldAccess(ctx, mode, cf, FHStatic(a.impl), TexprTools.makeTypeExpr(TClassDecl(a.impl), p), p);
			case _:
		}
		// A module-level field (Haxe 4.2 module-level `var`/`function`, stored in the synthetic
		// <Module>_Fields_ class) is visible unqualified within its own module.
		var modStatic = resolveModuleStatic(ctx, i, p, mode);
		if (modStatic != null) return modStatic;
		var resolvedToTypeParameter = false;
		for (tp in ctx.typeParams) if (tp.name == i) {
			resolvedToTypeParameter = true;
			switch (TypeFunctions.follow(TypeFunctions.extractParamType(tp))) {
				case TInst(c, _) if (isGenericParameter(ctx, c) && TypeFunctions.hasMeta(":const", c.meta)):
					var e = TexprTools.makeTypeExpr(TClassDecl(c), p);
					return AKExpr(TypeFunctions.mk(e.expr, TypeFunctions.extractParamType(tp), e.pos));
				case _:
			}
			break;
		}
		if (i == "trace") {
			var logMt = ctx.com.getType({pack: ["haxe"], name: "Log"}, p, null);
			try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(logMt).module) catch (_:Dynamic) {}
			return Fields.typeField(ctx, TexprTools.makeTypeExpr(logMt, p), "trace", p, mode, withType);
		}
		// A static-field import (`import M.field`) or a static wildcard (`import M.*` on a type) makes a
		// static field or enum constructor available unqualified.
		var imp = resolveImportedStatic(ctx, i, p, mode);
		if (imp != null) return imp;
		// A lowercase identifier is never looked up as a type. Without the guard every unresolved
		// lowercase name (a pattern capture, an argument) would run the whole unqualified type walk, and
		// each step of that walk is a real module load whose miss consults the extern-type loaders -
		// which is what Context.onTypeNotFound observes.
		var mt = hxc.ast.Ast.isLowerIdent(i) ? null
			: hxc.context.ModuleLoader.resolveBareType(ctx.com, ctx.com.currentModule, i, p);
		if (mt == null && !hxc.ast.Ast.isLowerIdent(i)) {
			try mt = ctx.com.getType({pack: [], name: i}, p, null) catch (_:hxc.context.Context.ContextError) mt = null;
		}
		if (mt == null) {
			// In untyped mode an unresolved identifier becomes a TIdent, letting reification builtins such
			// as $__mk_pos__ (recognized by the interpreter) pass typing. A name that is a package root on
			// the class path stays unresolved instead, so the enclosing field chain resolves it as a type
			// path .
			if (ctx.untypedMode && !isPackageRoot(ctx, i)) {
			// The magic __this__ is the raw receiver in untyped code: a plain TConst(TThis), deliberately
			// not the captured `this local, so the js std can name the enclosing object inside a nested
			// function.
			if (i == "__this__") return AKExpr(TypeFunctions.mk(TConst(TThis), ctx.tthis, p));
			return AKExpr(TypeFunctions.mk(TIdent(i), spawnMonomorph(ctx, p), p));
		}
			if (resolvedToTypeParameter) throw new TypingError("Only @:const type parameters on @:generic classes can be used as value", p);
			// An unresolved ident naming an instance field of the current class from a static function
			// reports the access error, not an unknown identifier.
			if (ctx.curfun.match(FunStatic) && ctx.curclass != TypeFunctions.nullClass && ctx.curclass.fields.exists(i))
				throw new TypingError("Cannot access " + i + " in static function", p);
			// An expected enum-like type turns an unknown ident into a suggestion over the type's
			// constructors. (StringError.string_error).
			switch (withType) {
				case WithType(wt, _):
					var cand:Null<{path:hxc.core.Globals.Path, names:Array<String>}> = switch (TypeFunctions.follow(wt)) {
						case TEnum(en, _): {path: en.path, names: [for (k in en.constrs.keys()) k]};
						case TAbstract(a, _) if (a.isEnum && a.impl != null):
							{path: a.path, names: [
								for (k in a.impl.statics.keys())
									if (TypeFunctions.hasClassFieldFlag(a.impl.statics.get(k), CfEnum)) k
							]};
						case _: null;
					};
					if (cand != null)
						throw new TypingError(hxc.core.StringError.stringError(i, cand.names,
							"Identifier '" + i + "' is not part of " + hxc.core.Globals.sTypePath(cand.path)), p);
				case _:
			}
			// An existing module that defines no type of its own name reports the module error, not an
			// unknown identifier.
			if (i.charCodeAt(0) >= "A".code && i.charCodeAt(0) <= "Z".code) {
				var mod = findUnqualifiedModule(ctx, i, p);
				if (mod != null && hxc.context.ModuleLoader.findTypeInModuleOpt(mod, i) == null)
					throw new TypingError("Module " + hxc.core.Globals.sTypePath(mod.path) + " does not define type " + i, p);
			}
			// Record the candidates the toplevel set offers, so the diagnostics report can name them. It
			// runs long after this context is gone, which is why the suggestions are computed here.
			// In a DIAGNOSTICS run the name is only recorded, never reported - the access recovers to a
			// monomorph so the rest of the field still types, and the report describes it as an unresolved
			// identifier rather than as a compiler error.
			if (identSpeculation == 0 && ctx.com.errorInDiagnosticsRun(p)) {
				recordUnresolvedIdentifier(ctx, i, p);
				// The MISSING field the name implies is recorded alongside the unresolved identifier, so the
				// report can offer to create it.
				Fields.handleMissingIdent(ctx, i, mode, withType, p);
				return AKExpr(TypeFunctions.mk(TIdent(i), TypeFunctions.mkMono(), p));
			}
			// Outside DMNone the name is REPORTED and recovers to a TIdent at a fresh monomorph, so
			// everything after it in the expression still types and the request can still be answered from
			// elsewhere in it. the raise for the display SUBJECT, which here is the identifier the cursor is
			// on - there the raise is how the request gets answered. adds a fake local, but only behind
			// ServerConfig.legacy_completion, a JSON-RPC initialize option that hxc has no way to set.
			if (identSpeculation == 0 && ctx.com.displaySpec != null && !atDisplayPos(p)
					&& !inMarkedSubtree(p)) {
				ctx.com.addDiagnostic("Unknown identifier : " + i, p, 0);
				return AKExpr(TypeFunctions.mk(TIdent(i), TypeFunctions.mkMono(), p));
			}
			if (identSpeculation == 0 && ctx.com.displaySpec != null
					&& (atDisplayPos(p) || inMarkedSubtree(p)) && displaySubjectError == null)
				displaySubjectError = {msg: "Unknown identifier : " + i, pos: p};
			throw new TypingError("Unknown identifier : " + i, p);
		}
		switch (mt) {
			case TTypeDecl(td): hxc.filters.DeprecationCheck.checkTypedefUse(ctx.com, td, p);
			case _:
		}
		// Hxc resolves field types in a separate pass; resolve the referenced module so its
		// statics have real types (idempotent via processed).
		try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
		switch (mt) { case TClassDecl(c): hxc.eval.EvalMacro.ensureBuilt(ctx.com, c); case _: }
		return AKExpr(TexprTools.makeTypeExpr(buildGenericValueType(ctx, mt, p), p));
	}

	// A @:genericBuild class referenced as a value builds first and the reference becomes the built module
	// type.
	public static function buildGenericValueType(ctx:TyperContext, mt:ModuleType, p:Position):ModuleType {
		return switch (mt) {
			case TClassDecl(c):
				switch (c.kind) {
					case KGenericBuild(fields):
						var t = hxc.eval.EvalMacro.runGenericBuild(ctx.com, c, [], fields, p, ctx.typeParams);
						var built = try TypeFunctions.moduleTypeOfType(TypeFunctions.follow(t)) catch (_:Dynamic) {
							// A Dynamic build result references the Dynamic type itself.
							switch (TypeFunctions.follow(t)) {
								case TDynamic(_): ctx.com.getType({pack: [], name: "Dynamic"}, p, null);
								case _: throw new TypingError("Invalid module type", p);
							}
						}
						buildGenericValueType(ctx, built, p);
					case _: mt;
				}
			case _: mt;
		}
	}

	static var packageRootCache:Null<haxe.ds.StringMap<Bool>> = null;

	// True when `name` is a package directory on the class path.
	static function isPackageRoot(ctx:TyperContext, name:String):Bool {
		if (packageRootCache == null) packageRootCache = new haxe.ds.StringMap();
		var hit = packageRootCache.get(name);
		if (hit != null) return hit;
		var found = false;
		for (cp in ctx.com.classPath) {
			if (sys.FileSystem.exists(cp + name) && sys.FileSystem.isDirectory(cp + name)) {
				found = true;
				break;
			}
		}
		packageRootCache.set(name, found);
		return found;
	}

	static function expectedEnumLike(t:T, stack:Array<T>):Null<TEnum> {
		for (s in stack) if (TypeUnification.shallowEq(t, s)) return null;
		return switch (TypeFunctions.follow(t)) {
			case TEnum(en, _):
				en;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta) && a.from.length == 1):
				expectedEnumLike(TypeFunctions.applyParams(a.params, tl, a.from[0]), [t].concat(stack));
			case _:
				null;
		}
	}

	// Parse an i64 literal string (decimal or 0x-hex) into its 64-bit value.
	static function parseInt64Literal(s:String):haxe.Int64 {
		if (s.length >= 2 && (s.substr(0, 2) == "0x" || s.substr(0, 2) == "0X")) {
			var v = haxe.Int64.ofInt(0);
			var sixteen = haxe.Int64.ofInt(16);
			for (i in 2...s.length) {
				var c = s.charCodeAt(i);
				var d = if (c >= "0".code && c <= "9".code) c - "0".code
					else if (c >= "a".code && c <= "f".code) c - "a".code + 10
					else if (c >= "A".code && c <= "F".code) c - "A".code + 10
					else 0;
				v = haxe.Int64.add(haxe.Int64.mul(v, sixteen), haxe.Int64.ofInt(d));
			}
			return v;
		}
		return haxe.Int64.parseString(s);
	}

	// A bare identifier provided by an explicit static-field import (`import M.field`) or a static
	// wildcard import (`import M.*` where M is a type): resolve it as that type's static field or
	// enum constructor. Abstract members (CfImpl, which need `this`) are not importable unqualified.
	static function resolveImportedStatic(ctx:TyperContext, i:String, p:Position, mode:AccessMode):Null<AccessKind> {
		var m = ctx.com.currentModule;
		if (m == null) return null;
		var imports = ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports == null) return null;
		// A wildcard `import Class.*` skips @:noImportGlobal fields and constructors; an explicit field
		// import is not filtered.
		function tryType(mt:ModuleType, lookupName:String, wildcard:Bool = false):Null<AccessKind> {
			try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
			switch (mt) {
				case TClassDecl(c):
					hxc.eval.EvalMacro.ensureBuilt(ctx.com, c);
					var cf = c.statics.get(lookupName);
					if (cf != null && wildcard && TypeFunctions.hasMeta(":noImportGlobal", cf.meta)) cf = null;
					if (cf != null) return Fields.fieldAccess(ctx, mode, cf, FHStatic(c), TexprTools.makeTypeExpr(TClassDecl(c), p), p);
				case TAbstractDecl(a) if (a.impl != null):
					var cf = a.impl.statics.get(lookupName);
					if (cf != null && wildcard && TypeFunctions.hasMeta(":noImportGlobal", cf.meta)) cf = null;
					if (cf != null && !TypeFunctions.hasClassFieldFlag(cf, CfImpl))
						return Fields.fieldAccess(ctx, mode, cf, FHStatic(a.impl), TexprTools.makeTypeExpr(TClassDecl(a.impl), p), p);
				case TEnumDecl(en) if (en.constrs.exists(lookupName)):
					if (wildcard && TypeFunctions.hasMeta(":noImportGlobal", en.constrs.get(lookupName).meta)) return null;
					return Fields.enumConstructor(ctx, en, TexprTools.makeTypeExpr(TEnumDecl(en), p), lookupName, p);
				case _:
			}
			return null;
		}
		var g = imports.globals.get(i);
		if (g != null) {
			var mt = try ctx.com.getType(g.ownerPath, p, g.ownerSub) catch (_:Dynamic) null;
			if (mt != null) { var r = tryType(mt, g.field != null ? g.field : i); if (r != null) { imports.markImport(g.impIdx); return r; } }
			// `import M.field` where field is a MODULE-LEVEL static: the module may have no main type at
			// all; resolve against its statics holder.
			var mod = try hxc.context.ModuleLoader.loadModule(ctx.com, g.ownerPath, p) catch (_:Dynamic) null;
			if (mod != null && mod.statics != null) {
				try TypeResolve.resolveModule(ctx.com, mod) catch (_:Dynamic) {}
				var sc = mod.statics;
				var cf = sc.statics.get(g.field != null ? g.field : i);
				if (cf != null) { imports.markImport(g.impIdx); return Fields.fieldAccess(ctx, mode, cf, FHStatic(sc), TexprTools.makeTypeExpr(TClassDecl(sc), p), p); }
			}
		}
		// `import M.X` with an uppercase trailing X was recorded as a sub-type import; when M has no
		// sub-type X, it falls back to a static field X of M's main type (an uppercase static).
		var n = imports.names.get(i);
		if (n != null && n.sub != null) {
			var subMt = try ctx.com.getType(n.modulePath, p, n.sub) catch (_:Dynamic) null;
			if (subMt == null) {
				var mainMt = try ctx.com.getType(n.modulePath, p, null) catch (_:Dynamic) null;
				if (mainMt != null) { var r = tryType(mainMt, n.sub); if (r != null) { imports.markImport(n.impIdx); return r; } }
				// An uppercase module-level static (`import M.UpperCase [as X]`) is recorded as a sub-type
				// import; when no such type exists it is a field of statics.
				var mod = try hxc.context.ModuleLoader.loadModule(ctx.com, n.modulePath, p) catch (_:Dynamic) null;
				if (mod != null && mod.statics != null) {
					try TypeResolve.resolveModule(ctx.com, mod) catch (_:Dynamic) {}
					var sc = mod.statics;
					var cf = sc.statics.get(n.sub);
					if (cf != null) return Fields.fieldAccess(ctx, mode, cf, FHStatic(sc), TexprTools.makeTypeExpr(TClassDecl(sc), p), p);
				}
			}
		}
		// A plain module import (`import M;`) exposes every PUBLIC module-level static of M as a bare
		// identifier INormal: md.statics' public fields enter module_globals).
		var oi = imports.order.length - 1;
		while (oi >= 0) {
			var ni = imports.order[oi--];
			if (ni.sub != null || ni.aliased == true) continue;
			var mod = try hxc.context.ModuleLoader.loadModule(ctx.com, ni.modulePath, p) catch (_:Dynamic) continue;
			if (mod.statics == null) continue;
			try TypeResolve.resolveModule(ctx.com, mod) catch (_:Dynamic) {}
			var sc = mod.statics;
			var cf = sc.statics.get(i);
			if (cf != null && TypeFunctions.hasClassFieldFlag(cf, CfPublic))
				return Fields.fieldAccess(ctx, mode, cf, FHStatic(sc), TexprTools.makeTypeExpr(TClassDecl(sc), p), p);
		}
		for (w in imports.wildcards) {
			var mt = try ctx.com.getType(w, p, null) catch (_:Dynamic) null;
			if (mt != null) { var r = tryType(mt, i, true); if (r != null) { imports.markWildcard(w); return r; } }
		}
		return null;
	}

	// A bare identifier naming a module-level field (stored on the synthetic <Module>_Fields_ class).
	static function resolveModuleStatic(ctx:TyperContext, i:String, p:Position, mode:AccessMode):Null<AccessKind> {
		var m = ctx.com.currentModule;
		if (m == null || m.statics == null) return null;
		var c = m.statics;
		var cf = c.statics.get(i);
		if (cf == null) return null;
		return Fields.fieldAccess(ctx, mode, cf, FHStatic(c), TexprTools.makeTypeExpr(TClassDecl(c), p), p);
	}

	// The unqualified module walk (wildcard imports, then current package up to root):
	// the first existing module with the given name.
	static function findUnqualifiedModule(ctx:TyperContext, name:String, p:Position):Null<hxc.core.Type.ModuleDef> {
		var m = ctx.com.currentModule;
		if (m == null) return null;
		var imports = ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports != null) for (w in imports.wildcards) {
			var mod = try hxc.context.ModuleLoader.loadModule(ctx.com, {pack: w.pack.concat([w.name]), name: name}, p) catch (_:Dynamic) null;
			if (mod != null) return mod;
		}
		var mpack = m.path.pack;
		var pi = mpack.length;
		while (pi >= 0) {
			if (!(pi == mpack.length && name == m.path.name)) {
				var mod = try hxc.context.ModuleLoader.loadModule(ctx.com, {pack: mpack.slice(0, pi), name: name}, p) catch (_:Dynamic) null;
				if (mod != null) return mod;
			}
			pi--;
		}
		return null;
	}

	// `Module.field` where Module is not a type bound in the current module context: the unqualified
	// module
	// walk resolves the module's statics field before its types.
	static function unqualifiedModuleStaticField(ctx:TyperContext, modName:String, field:String, p:Position, mode:AccessMode):Null<AccessKind> {
		if (ctx.locals.exists(modName)) return null;
		var m = ctx.com.currentModule;
		if (m == null) return null;
		for (mt in m.types) if (TypeFunctions.tInfos(mt).path.name == modName) return null;
		var imports = ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports != null) {
			if (imports.names.exists(modName)) return null;
			for (key in imports.names.keys()) {
				var ni = imports.names.get(key);
				if (ni.sub != null || ni.aliased == true) continue;
				var im = try hxc.context.ModuleLoader.loadModule(ctx.com, ni.modulePath, p) catch (_:Dynamic) continue;
				for (mt in im.types) if (TypeFunctions.tInfos(mt).path.name == modName) return null;
			}
		}
		function resolveMod(mod:Null<hxc.core.Type.ModuleDef>):Null<AccessKind> {
			if (mod == null) return null;
			try TypeResolve.resolveModule(ctx.com, mod) catch (_:Dynamic) {}
			if (mod.statics != null) {
				var sc = mod.statics;
				var cf = sc.statics.get(field);
				if (cf != null) return Fields.fieldAccess(ctx, mode, cf, FHStatic(sc), TexprTools.makeTypeExpr(TClassDecl(sc), p), p);
			}
			// An uppercase part after the module name resolves as one of its types
			// (resolve_in_module -> resolve_module_type), beating the main class's static.
			var c0 = field.charCodeAt(0);
			if (c0 >= "A".code && c0 <= "Z".code) {
				for (mt2 in mod.types) {
					var ti = TypeFunctions.tInfos(mt2);
					if (ti.path.name == field && !(ti.isPrivate && mod != ctx.com.currentModule)) {
						switch (mt2) { case TClassDecl(c2): hxc.eval.EvalMacro.ensureBuilt(ctx.com, c2); case _: }
						return AKExpr(TexprTools.makeTypeExpr(buildGenericValueType(ctx, mt2, p), p));
					}
				}
			}
			return null;
		}
		if (imports != null) for (w in imports.wildcards) {
			var r = resolveMod(try hxc.context.ModuleLoader.loadModule(ctx.com, {pack: w.pack.concat([w.name]), name: modName}, p) catch (_:Dynamic) null);
			if (r != null) return r;
		}
		var mpack = m.path.pack;
		var pi = mpack.length;
		while (pi >= 0) {
			if (!(pi == mpack.length && modName == m.path.name)) {
				var r = resolveMod(try hxc.context.ModuleLoader.loadModule(ctx.com, {pack: mpack.slice(0, pi), name: modName}, p) catch (_:Dynamic) null);
				if (r != null) return r;
			}
			pi--;
		}
		return null;
	}

	// A bare identifier that names a constructor of an enum, or a member of an enum abstract, declared
	// in the current module or brought in by a module import. Returns the owning enum/abstract decl.
	static function findBareEnumLike(ctx:TyperContext, i:String):Null<ModuleType> {
		var m = ctx.com.currentModule;
		if (m == null) return null;
		function scan(types:Array<ModuleType>):Null<ModuleType> {
			for (mt in types) switch (mt) {
				case TEnumDecl(en) if (en.constrs.exists(i)): return mt;
				case TAbstractDecl(a) if (a.isEnum && a.impl != null && a.impl.statics.exists(i)): return mt;
				case TTypeDecl(td):
					switch (TypeFunctions.follow(td.type)) {
						case TEnum(en, _) if (en.constrs.exists(i)): return TEnumDecl(en);
						case TAbstract(a, _) if (a.isEnum && a.impl != null && a.impl.statics.exists(i)): return TAbstractDecl(a);
						case _:
					}
				case _:
			}
			return null;
		}
		var ownTypes = m.types.copy();
		ownTypes.reverse();
		var own = scan(ownTypes);
		if (own != null) return own;
		// A module import brings the constructors/members of that module's enums into scope.
		var imports = ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports != null) {
			function scanPath(path:hxc.core.Globals.Path):Null<ModuleType> {
				var md = try hxc.context.ModuleLoader.loadModule(ctx.com, path, Position.nullPos) catch (_:Dynamic) null;
				if (md != null) try hxc.typing.TypeResolve.resolveModule(ctx.com, md) catch (_:Dynamic) {}
				return md == null ? null : scan(md.types);
			}
			// Reversed declaration order: imports are prepended, so a name exposed by several imports
			// resolves to the last-declared one.
			var impIdx = imports.order.length - 1;
			while (impIdx >= 0) {
				var imp = imports.order[impIdx--];
				if (imp.aliased == true) continue;
				if (imp.sub != null) {
					// A sub-type import (`import pack.Module.Sub`) exposes constructors/members only when the
					// imported sub-type is ITSELF an enum or enum-abstract (`import haxe.CallStack.StackItem`
					// brings FilePos/Method/...); it must not expose a sibling enum in the same module, or a
					// member like haxe.display.Display.DisplayItemKind.Type would shadow the std Type class when
					// only the sibling `Package` typedef was imported. Scan just the imported sub-type.
					var md = try hxc.context.ModuleLoader.loadModule(ctx.com, imp.modulePath, Position.nullPos) catch (_:Dynamic) null;
					if (md != null) {
						try hxc.typing.TypeResolve.resolveModule(ctx.com, md) catch (_:Dynamic) {}
						for (mt in md.types) if (TypeFunctions.tInfos(mt).path.name == imp.sub) {
							var r = scan([mt]); if (r != null) return r;
						}
					}
				} else {
					// A whole-module import (`import pack.Module`) brings every enum's constructors into scope.
					var r = scanPath(imp.modulePath); if (r != null) return r;
				}
			}
			for (w in imports.wildcards) { var r = scanPath(w); if (r != null) return r; }
		}
		return null;
	}

	static function flattenIdentPath(e:ExprDef):Null<Array<String>> {
		return switch (e) {
			case EConst(CIdent(s)): [s];
			case EField(e1, f, _):
				var pre = flattenIdentPath(e1.expr);
				pre == null ? null : pre.concat([f]);
			case _: null;
		};
	}

	// Resolves a dotted ident chain (pack.Type.field...) as a package-qualified type path.
	static function tryTypePath(ctx:TyperContext, e:ExprDef, p:Position, mode:AccessMode, withType:WithType):Null<AccessKind> {
		var segs = flattenIdentPath(e);
		if (segs == null || segs.length < 2) return null;
		var typeIdx = -1;
		for (i in 0...segs.length) {
			var c = segs[i].charCodeAt(0);
			if (c >= "A".code && c <= "Z".code) { typeIdx = i; break; }
		}
		if (typeIdx < 0) return null;
		var pack = segs.slice(0, typeIdx);
		// A leading `std` package selects the standard library type, bypassing a shadowing local or import
		// (e.g. `std.haxe.crypto.Md5` while a local `var haxe` is in scope). (std pack).
		if (pack.length > 0 && pack[0] == "std") pack = pack.slice(1);
		var name = segs[typeIdx];
		var rest = segs.slice(typeIdx + 1);
		// A module with no same-named main type (e.g. unit.MyMacro holds only MyRestMacro /
		// MyMacroHelper) leaves the main-type lookup empty; keep going so the sub-type lookup below
		// can still resolve the path rather than bailing to a field access.
		var mt = try ctx.com.getType({pack: pack, name: name}, p, null) catch (_:Dynamic) null;
		// pack.SubType where SubType is a module-level type brought in by `import pack.Module` (so it
		// has no module file of its own, e.g. scripthost.Issue5351_2 from `import scripthost.Issue5351`):
		// find an imported module in the same package that declares it as a sub-type.
		if (mt == null) {
			var m = ctx.com.currentModule;
			// A fully-qualified reference to a module-level SIBLING type in the current module
			// (unit.UsedReferenced2 written inside module unit.TestDCE): it has no file of its own, but is
			// already loaded as a sibling of the enclosing module.
			if (m != null && m.path.pack.join(".") == pack.join(".")) {
				for (mtp in m.types) {
					if (TypeFunctions.tInfos(mtp).path.name == name) { mt = mtp; break; }
				}
			}
			var imports = m == null ? null : ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
			if (mt == null && imports != null) {
				for (imp in imports.names) {
					if (imp.modulePath.pack.join(".") == pack.join(".") && imp.modulePath.name != name) {
						var cand = try ctx.com.getType(imp.modulePath, p, name) catch (_:Dynamic) null;
						if (cand != null) { mt = cand; break; }
					}
				}
			}
		}
		// pack.Module.SubType.field: when the next segment names a sub-type of the module, resolve it as
		// the type (module + sub) rather than a field access on the module's main type.
		if (rest.length > 0) {
			var c0 = rest[0].charCodeAt(0);
			if (c0 >= "A".code && c0 <= "Z".code) {
				var subMt = try ctx.com.getType({pack: pack, name: name}, p, rest[0]) catch (_:Dynamic) null;
				if (subMt != null) { mt = subMt; rest = rest.slice(1); }
			}
		}
		// Resolution against a module the module-level static field first, then (for an uppercase part) a
		// sub-type, then the main type (the main type falls to the normal path). The remaining segments
		// chain as field accesses with per-segment positions.
		function chainFrom(base:AccessKind, fromIdx:Int, ends:Array<Int>):AccessKind {
			var acc = base;
			for (i in fromIdx...rest.length) {
				var isLast = i == rest.length - 1;
				var segP = new Position(p.file, p.min, ends[i]);
				acc = Fields.typeField(ctx, accGet(ctx, acc), rest[i], segP, isLast ? mode : MGet, isLast ? withType : WithTypeTools.value);
			}
			return acc;
		}
		function segEnds():Array<Int> {
			var ends:Array<Int> = [];
			var endAcc = p.max;
			var ei = rest.length - 1;
			while (ei >= 0) { ends[ei] = endAcc; endAcc -= rest[ei].length + 1; ei--; }
			return ends;
		}
		function resolveInModule(mod:Null<hxc.core.Type.ModuleDef>):Null<AccessKind> {
			if (mod == null || rest.length == 0) return null;
			try TypeResolve.resolveModule(ctx.com, mod) catch (_:Dynamic) {}
			var ends = segEnds();
			var basePos = new Position(p.file, p.min, ends.length > 0 ? ends[0] - rest[0].length - 1 : p.max);
			if (mod.statics != null && mod.statics.statics.exists(rest[0]))
				return chainFrom(AKExpr(TexprTools.makeTypeExpr(TClassDecl(mod.statics), basePos)), 0, ends);
			var c0 = rest[0].charCodeAt(0);
			if (c0 >= "A".code && c0 <= "Z".code) {
				for (mt2 in mod.types) {
					var ti = TypeFunctions.tInfos(mt2);
					if (ti.path.name == rest[0] && !(ti.isPrivate && mod != ctx.com.currentModule)) {
						switch (mt2) { case TClassDecl(c2): hxc.eval.EvalMacro.ensureBuilt(ctx.com, c2); case _: }
						return rest.length == 1
							? AKExpr(TexprTools.makeTypeExpr(buildGenericValueType(ctx, mt2, p), p))
							: chainFrom(AKExpr(TexprTools.makeTypeExpr(buildGenericValueType(ctx, mt2, p), new Position(p.file, p.min, ends[0]))), 1, ends);
					}
				}
			}
			return null;
		}
		function staticsChain(mod:Null<hxc.core.Type.ModuleDef>):Null<AccessKind> {
			if (mod == null || mod.statics == null || rest.length == 0) return null;
			if (!mod.statics.statics.exists(rest[0])) return null;
			try TypeResolve.resolveModule(ctx.com, mod) catch (_:Dynamic) {}
			return chainFrom(AKExpr(TexprTools.makeTypeExpr(TClassDecl(mod.statics), p)), 0, segEnds());
		}
		if (mt == null) {
			var r = resolveInModule(try hxc.context.ModuleLoader.loadModule(ctx.com, {pack: pack, name: name}, p) catch (_:Dynamic) null);
			// The module may be visible through a named or wildcard import
			// (`import pack.inner.*;` then `InnerMod.lowerCase` / `InnerMod.SubType`).
			if (r == null && pack.length == 0) {
				var curM = ctx.com.currentModule;
				var mImports = curM == null ? null : ctx.com.moduleImports.get(hxc.context.Context.pathKey(curM.path));
				if (mImports != null) {
					var ni = mImports.names.get(name);
					if (ni != null && ni.sub == null)
						r = resolveInModule(try hxc.context.ModuleLoader.loadModule(ctx.com, ni.modulePath, p) catch (_:Dynamic) null);
					if (r == null) for (w in mImports.wildcards) {
						r = resolveInModule(try hxc.context.ModuleLoader.loadModule(ctx.com, {pack: w.pack.concat([w.name]), name: name}, p) catch (_:Dynamic) null);
						if (r != null) break;
					}
				}
				// Search from the current package up to the root.
				if (r == null && curM != null) {
					var mpack = curM.path.pack;
					var pi = mpack.length;
					while (r == null && pi >= 1) {
						r = resolveInModule(try hxc.context.ModuleLoader.loadModule(ctx.com, {pack: mpack.slice(0, pi), name: name}, p) catch (_:Dynamic) null);
						pi--;
					}
				}
			}
			if (r != null) return r;
			// The last guess: the report names the module - the leading lowercase package plus the first
			// uppercase segment - and never the trailing field segments, which is why `Priv.four` complains
			// about `Priv`. It points at the segment the scan stopped on: the first uppercase one, or the
			// SECOND when the path has two in a row (a module and its sub-type), so `Nope.Sub.f` spans
			// `Nope.Sub` while still naming only `Nope`. The `std` prefix is already stripped out of `pack`
			// above, and stays in the span but not the message.
			var stopIdx = typeIdx;
			var sub:Null<String> = null;
			if (typeIdx + 1 < segs.length) {
				var c1 = segs[typeIdx + 1].charCodeAt(0);
				if (c1 >= "A".code && c1 <= "Z".code) { sub = segs[typeIdx + 1]; stopIdx = typeIdx + 1; }
			}
			var pStop = p.max;
			for (j in (stopIdx + 1)...segs.length) pStop -= segs[j].length + 1;
			var pName = new Position(p.file, p.min, pStop);
			// The module has to be loaded already for the "does not define" wording; anything else is
			// Module_not_found /:286).
			if (ctx.com.moduleLut.exists(hxc.context.Context.pathKey({pack: pack, name: name})))
				throw new TypingError("Module " + hxc.core.Globals.sTypePath({pack: pack, name: name})
					+ " does not define type " + (sub != null ? sub : name), pName);
			throw new hxc.core.TypingError.ModuleNotFoundError("Type not found : " + hxc.core.Globals.sTypePath({pack: pack, name: name}), pName);
		}
		if (rest.length > 0) {
			// A module-level static wins over a same-named static of the module's main
			// class for `Module.field` access (resolution suite
			// testUnimportedModuleStaticBeforeMainClassStatic).
			var r = staticsChain(TypeFunctions.tInfos(mt).module);
			if (r != null) return r;
		}
		switch (mt) {
			case TTypeDecl(td): hxc.filters.DeprecationCheck.checkTypedefUse(ctx.com, td, p);
			case _:
		}
		try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
		switch (mt) { case TClassDecl(c): hxc.eval.EvalMacro.ensureBuilt(ctx.com, c); case _: }
		// Each chain link's source span ends at its own segment (reconstructed from the right edge), so
		// field errors narrow to the field name like the reference's per-EField positions do pfield).
		var ends:Array<Int> = [];
		var endAcc = p.max;
		var ei = rest.length - 1;
		while (ei >= 0) { ends[ei] = endAcc; endAcc -= rest[ei].length + 1; ei--; }
		var basePos = rest.length == 0 ? p : new Position(p.file, p.min, endAcc);
		var acc:AccessKind = AKExpr(TexprTools.makeTypeExpr(buildGenericValueType(ctx, mt, p), basePos));
		for (i in 0...rest.length) {
			var isLast = i == rest.length - 1;
			var segP = new Position(p.file, p.min, ends[i]);
			acc = Fields.typeField(ctx, accGet(ctx, acc), rest[i], segP, isLast ? mode : MGet, isLast ? withType : WithTypeTools.value);
		}
		return acc;
	}

	static function typeArrayComprehension(ctx:TyperContext, e:Expr, withType:WithType, p:Position):TExpr {
		// Uses a gen local; the syntactic name must stay unique for resolution, so the typed var is
		// renamed to the backtick form afterwards (RenameVars then produces _g like the reference)
		var acc = "_hx_comp";
		var mapped = comprehensionPush(new Expr(EConst(CIdent(acc)), p), e);
		var init = mapped.isMap
			? new Expr(ENew({path: {tpackage: ["haxe", "ds"], tname: "Map", tparams: [], tsub: null}, pos: p}, []), p)
			: new Expr(EArrayDecl([]), p);
		// The empty accumulator types WITH the expectation first, so the loop body's push checks each
		// element against the known element type (a mismatched literal reports at its own position, not as
		// a whole-array unify). A map accumulator keeps the plain value context: the multiType Map
		// constructor cannot take an expectation whose parameters are still open monomorphs.
		var tea = typeExpr(ctx, init, mapped.isMap ? WithTypeTools.value : withType);
		var v = TypeFunctions.allocVar(VGenerated, "`", tea.type, p);
		// The reference stores the accumulator local and references it through the @:storedTypedExpr
		// marker; the ID is consumed either way, which keeps the stored-expression id stream aligned. .
		var refId = hxc.context.Context.allocStoredTypedExprId("comprehension " + p.file + ":" + Position.getInfos(p).line);
		ctx.com.storedTypedExprs.set(refId, TypeFunctions.mk(TLocal(v), v.type, p));
		var restore = saveLocals(ctx);
		ctx.locals.set(acc, v);
		var efor = typeExpr(ctx, mapped.expr, WithTypeTools.noValue);
		restore();
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(v, tea), ctx.com.basic.tvoid, p),
			efor,
			TypeFunctions.mk(TLocal(v), v.type, p),
		]), v.type, p);
	}

	// Lowers a comprehension body so each tail expression updates the accumulator. Whether the
	// comprehension tail is a map (key => value) form; decides the accumulator without rewriting, so
	// the rewrite can wait for the stored ref.
	static function comprehensionIsMap(e:Expr):Bool {
		return switch (e.expr) {
			case EFor(_, body) | EWhile(_, body, _) | EParenthesis(body): comprehensionIsMap(body);
			case EIf(_, e1, e2): comprehensionIsMap(e1) || (e2 != null && comprehensionIsMap(e2));
			case EBlock(l) if (l.length > 0): comprehensionIsMap(l[l.length - 1]);
			case EBinop(OpArrow, _, _): true;
			case _: false;
		};
	}

	static function comprehensionPush(acc:Expr, e:Expr):{expr:Expr, isMap:Bool} {
		inline function same(expr:Expr, isMap:Bool) return {expr: expr, isMap: isMap};
		// The accumulator local once and reuses that reference at every push site (`efield
		// (e_ref,"push")`), so the receiver keeps the COMPREHENSION's position while the call and the
		// field take the body position. Rebuilding the identifier at the body position collapsed the two,
		// and the js source map lost the receiver's own segment.
		inline function call(name:String, args:Array<Expr>):Expr
			return new Expr(ECall(new Expr(EField(acc, name, EFNormal), e.pos), args), e.pos);
		return switch (e.expr) {
			case EFor(it, body):
				var b = comprehensionPush(acc, body);
				same(new Expr(EFor(it, b.expr), e.pos), b.isMap);
			case EWhile(c, body, flag):
				var b = comprehensionPush(acc, body);
				same(new Expr(EWhile(c, b.expr, flag), e.pos), b.isMap);
			case EIf(c, e1, e2):
				var b1 = comprehensionPush(acc, e1);
				var b2 = e2 == null ? null : comprehensionPush(acc, e2);
				same(new Expr(EIf(c, b1.expr, b2 == null ? null : b2.expr), e.pos), b1.isMap || (b2 != null && b2.isMap));
			case EBlock(l) if (l.length > 0):
				var nl = l.copy();
				var last = comprehensionPush(acc, nl[nl.length - 1]);
				nl[nl.length - 1] = last.expr;
				same(new Expr(EBlock(nl), e.pos), last.isMap);
			case EBlock([]):
				// An empty block body is an empty object literal.
				comprehensionPush(acc, new Expr(EObjectDecl([]), e.pos));
			case EParenthesis(e1):
				var b = comprehensionPush(acc, e1);
				same(new Expr(EParenthesis(b.expr), e.pos), b.isMap);
			case EBinop(OpArrow, a, b):
				same(call("set", [a, b]), true);
			case _:
				same(call("push", [e]), false);
		};
	}

	// Acc_get (subset).
	// Read of a field flagged inline (AccInline var, or an inline method closure). For an inline var the
	// stored constant value is substituted at the access site.
	static function samePath(a:hxc.core.Globals.Path, b:hxc.core.Globals.Path):Bool {
		return a.name == b.name && a.pack.join(".") == b.pack.join(".");
	}

	static function externInlineImplClass(c:TClass):TClass {
		var m = c.module;
		var implPath:hxc.core.Globals.Path = {pack: m.path.pack.concat(["_" + m.path.name]), name: m.path.name + "_Impl_"};
		for (mt in m.types) switch (mt) {
			case TClassDecl(c2) if (samePath(c2.path, implPath)):
				return c2;
			case _:
		}
		var c2 = TypeFunctions.mkClass(m, implPath, c.pos, Position.nullPos);
		m.types.unshift(TClassDecl(c2));
		return c2;
	}

	static function externInlineField(ctx:TyperContext, c:TClass, cf:TClassField):TClassField {
		var c2 = externInlineImplClass(c);
		var cf2 = c2.statics.get(cf.name);
		if (cf2 != null) return cf2;
		TypeFields.forceFieldBody(ctx.com, c, cf);
		var body = cf.expr == null ? null : foldInlineStatics(ctx, cf.expr);
		cf2 = new TClassField(cf.name, cf.type, cf.pos, cf.namePos, cf.doc, cf.meta.copy(), Method(MethNormal), cf.params.copy(), body, cf.exprUnoptimized, cf.overloads.copy(), cf.flags);
		TypeFunctions.removeClassFieldFlag(cf2, CfExtern);
		TypeFunctions.addClassFieldFlag(cf2, CfStatic);
		c2.statics.set(cf2.name, cf2);
		c2.orderedStatics.unshift(cf2);
		return cf2;
	}

	static function foldedInlineStatic(ctx:TyperContext, c:TClass, cf:TClassField, p:Position):Null<TExpr> {
		switch (cf.kind) {
			case Var({read: AccInline}):
				TypeFields.forceFieldBody(ctx.com, c, cf);
				return switch (cf.expr) {
					case null:
						null;
					case e:
						// A read of an inline var is repositioned RECURSIVELY. Moving only the outer node leaves
						// everything under it at its declaration position, and enum abstract values are each wrapped
						// in an ECast, so the constant underneath keeps the declaring file. On js that drags the
						// declaring module into the source map's `sources`, which shifts every later source index and
						// desynchronises the mappings.
						function reposition(x:TExpr):TExpr
							return TexprTools.mapExpr(reposition, TypeFunctions.mk(x.expr, x.type, p));
						var e2 = reposition(e);
						TypeUnification.typeIseqDefault(cf.type, e2.type) ? e2 : TypeFunctions.mk(TCast(e2, null), cf.type, p);
				}
			case _:
				return null;
		}
	}

	static function foldInlineStatics(ctx:TyperContext, e:TExpr):TExpr {
		function m(x:TExpr):TExpr return foldInlineStatics(ctx, x);
		var ne:TExprExpr = switch (e.expr) {
			case TField(e1, fa):
				switch (fa) {
					case FStatic(c, cf):
						var folded = foldedInlineStatic(ctx, c, cf, e.pos);
						if (folded != null) return folded;
						TField(m(e1), fa);
					case _:
						TField(m(e1), fa);
				}
			case TArray(e1, e2): TArray(m(e1), m(e2));
			case TBinop(op, e1, e2): TBinop(op, m(e1), m(e2));
			case TParenthesis(e1): TParenthesis(m(e1));
			case TObjectDecl(fields): TObjectDecl([for (f in fields) {key: f.key, expr: m(f.expr)}]);
			case TArrayDecl(values): TArrayDecl([for (x in values) m(x)]);
			case TCall(e1, params): TCall(m(e1), [for (x in params) m(x)]);
			case TNew(c, params, args): TNew(c, params, [for (x in args) m(x)]);
			case TUnop(op, flag, e1): TUnop(op, flag, m(e1));
			case TFunction(f): TFunction(new TFunc([for (a in f.args) {v: a.v, c: a.c == null ? null : m(a.c)}], f.type, m(f.expr)));
			case TVarExpr(v, eo): TVarExpr(v, eo == null ? null : m(eo));
			case TBlock(exprs): TBlock([for (x in exprs) m(x)]);
			case TFor(v, e1, e2): TFor(v, m(e1), m(e2));
			case TIf(econd, eif, eelse): TIf(m(econd), m(eif), eelse == null ? null : m(eelse));
			case TWhile(econd, e1, flag): TWhile(m(econd), m(e1), flag);
			case TSwitch(e1, cases, edef):
				TSwitch(m(e1), [for (c in cases) {values: [for (v in c.values) m(v)], expr: m(c.expr)}], edef == null ? null : m(edef));
			case TTry(e1, catches): TTry(m(e1), [for (c in catches) {v: c.v, expr: m(c.expr)}]);
			case TReturn(eo): TReturn(eo == null ? null : m(eo));
			case TThrow(e1): TThrow(m(e1));
			case TCast(e1, mt): TCast(m(e1), mt);
			case TMeta(entry, e1): TMeta(entry, m(e1));
			case TEnumParameter(e1, ef, index): TEnumParameter(m(e1), ef, index);
			case TEnumIndex(e1): TEnumIndex(m(e1));
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_):
				e.expr;
		};
		return TypeFunctions.mk(ne, e.type, e.pos);
	}

	static function inlineRead(ctx:TyperContext, fa:FieldAccess):TExpr {
		var cf = fa.field;
		var p = fa.pos;
		return switch (cf.kind) {
			case Method(_):
				var wrapClass = switch (TypeFunctions.follow(fa.on.type)) {
					case TInst(c, _) if ((TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) && !TypeFunctions.hasMeta(":runtime", cf.meta)):
						throw new TypingError("Can't create closure on an extern inline member method", p);
					case TAnon(a):
						switch (a.status.value) {
							case Statics(c) if (TypeFunctions.hasClassFlag(c, CExtern) && !TypeFunctions.hasMeta(":runtime", cf.meta)):
								c;
							case Statics(_) if (TypeFunctions.hasClassFieldFlag(cf, CfExtern) && !TypeFunctions.hasMeta(":runtime", cf.meta)):
								throw new TypingError("Cannot create closure on @:extern inline method", p);
							case _:
								null;
						}
					case _:
						null;
				};
				if (wrapClass != null) {
					var c2 = externInlineImplClass(wrapClass);
					var cf2 = externInlineField(ctx, wrapClass, cf);
					FieldAccessTools.getFieldExpr(FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(c2), p), cf2, FHStatic(c2), true, p), FRead);
				} else {
					FieldAccessTools.getFieldExpr(fa, FRead);
				}
			case Var(_):
				if (cf.expr == null) {
					// The inline var's initializer may not be typed yet (its module is processed later,
					// or it is an enum-abstract value forced on demand); type its body before reading the
					// stored constant. A genuine cycle leaves expr null and falls through to the error.
					var host = try FieldAccessTools.getHostClassRaise(fa.host) catch (_:hxc.core.NotFound) null;
					if (host != null) hxc.typing.TypeFields.forceFieldBody(ctx.com, host, cf);
				}
				switch (cf.expr) {
					case null: throw new TypingError("Recursive inline is not supported", p);
					case e:
						// apply_params is the identity for static/instance hosts, so substituting the stored value
						// only moves it to the access position; a TCast bridges any type mismatch. a read of an
						// inline var RECURSIVELY: let rec loop e = Type.map_expr loop { e with pos = p; ... } Moving
						// only the outer node leaves everything under it at its declaration position, and
						// build_enum_abstract wraps every value in an ECast, so the constant underneath keeps the
						// declaring file. On js that drags the declaring module into the source map's `sources`,
						// which shifts every later source index and desynchronises the mappings.
						function reposition1(x:TExpr):TExpr
							return TexprTools.mapExpr(reposition1, TypeFunctions.mk(x.expr, x.type, p));
						var e2 = reposition1(e);
						var tf = cf.type;
						TypeUnification.typeIseqDefault(tf, e2.type) ? e2 : TypeFunctions.mk(TCast(e2, null), tf, p);
				}
		};
	}

	// An empty `{}` is an object literal (not a Void block) when a value of a known structure type is
	// expected. With no expected value, or an implicit return into a still-open monomorph, it stays a block.
	static function emptyBlockIsObject(wt:WithType):Bool {
		return switch (wt) {
			case NoValue: false;
			case WithType(t, ImplicitReturn): switch (TypeFunctions.follow(t)) { case TMono(_): false; case _: true; };
			case _: true;
		};
	}

	public static function accGet(ctx:TyperContext, acc:AccessKind):TExpr {
		// A using-extension access never surfaces as a plain TField the definition extractor sees; record
		// it from the access itself.
		if (displayDefinition && displayFound == null) switch (acc) {
			case AKUsingField(se) | AKUsingAccessor(se) if (atDisplayPos(se.access.pos)):
				displayFound = [se.access.field.namePos];
			case _:
		}
		return switch (acc) {
			case AKExpr(e): e;
			case AKField(fa):
				// An inline read replaces the field access with its constant, losing the field;
				// the definition position records here where the field is still known.
				if (fa.isInline && displayDefinition && displayFound == null && atDisplayPos(fa.pos))
					displayFound = [fa.field.namePos];
				// A macro field turned into a value is an error, except under a display request, where the
				// cursor is probably on the subject of a macro call.
				if (fa.field.kind.match(Method(MethMacro)) && hxc.parser.Parser.displayFile == null)
					throw new TypingError("Invalid macro access", fa.pos);
				fa.isInline ? inlineRead(ctx, fa) : FieldAccessTools.getFieldExpr(fa, FRead, ctx.curfield);
			// Under a display request the unreadable access still yields its own expression, so what the
			// cursor is on can be reported.
			case AKNo(acc, p):
				if (!ctx.com.ignoreErrors) throw new TypingError("This expression cannot be accessed for reading", p);
				accGet(ctx, acc);
			case AKAccessor(fa):
				switch (FieldAccessTools.resolveAccessor(fa, MGet)) {
					case AccessorFound(getterFa):
						Calls.buildCall(ctx, AKField(getterFa), [], WithTypeTools.value, fa.pos);
					case AccessorAnon:
						// No accessor field is available (anon structure or extern class): synthesize a
						// dynamic get_<name>() call.
						var t = fa.field.type;
						var tf = TFun({args: [], ret: t});
						Calls.makeCall(ctx, TypeFunctions.mk(TField(fa.on, TypeFunctions.quickFieldDynamic(fa.on.type, "get_" + fa.field.name)), tf, fa.pos), [], t, fa.pos);
					case AccessorNotFound | AccessorInvalid:
						throw new TypingError("This field cannot be accessed for reading", fa.pos);
				}
			case AKUsingAccessor(se):
				// Reading an abstract property calls the impl's get_<name>(this).
				var fa = se.access;
				var implC = FieldAccessTools.getHostClassRaise(fa.host);
				var getterCf = implC.statics.get("get_" + fa.field.name);
				if (getterCf == null) throw new TypingError("This field cannot be accessed for reading", fa.pos);
				// The accessor keeps the abstract host so its signature gets the instance's type parameters
				// applied.
				var getterFa = FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(implC), fa.pos), getterCf, fa.host, false, fa.pos);
				Calls.buildCall(ctx, AKUsingField({thisExpr: se.thisExpr, access: getterFa}), [], WithTypeTools.value, fa.pos);
			case AKUsingField(se):
				// Reading an abstract/static-extension field: a property calls its impl getter with the
				// receiver; otherwise read the impl field directly.
				var fa = se.access;
				var implC = FieldAccessTools.getHostClassRaise(fa.host);
				var getterCf = implC.statics.get("get_" + fa.field.name);
				if (getterCf != null) {
					var getterFa = FieldAccessTools.create(TexprTools.makeTypeExpr(TClassDecl(implC), fa.pos), getterCf, fa.host, false, fa.pos);
					Calls.buildCall(ctx, AKUsingField({thisExpr: se.thisExpr, access: getterFa}), [], WithTypeTools.value, fa.pos);
				} else {
					var fieldExpr = FieldAccessTools.getFieldExpr(fa, FGet);
					switch (TypeFunctions.follow(fieldExpr.type)) {
						case TFun(sig) if (sig.args.length > 0):
							// AKUsingField: the closure binds the receiver through an OUTER one-arg wrapper
							// `function(_e) return function(args) ...` applied to the receiver; expression
							// reduction later inlines the immediate call, so a receiver read inside the
							// inner closure stays the bound `_e` local (the capture forces the temp).
							var p = fa.pos;
							var receiverType = switch (TypeFunctions.follow(se.thisExpr.type)) {
								case TAbstract(a, tl) if (TypeFunctions.hasClassFieldFlag(fa.field, CfImpl)):
									TypeFunctions.applyParams(a.params, tl, a.thisType);
								case _:
									se.thisExpr.type;
							};
							try TypeUnification.unifyDefault(receiverType, sig.args[0].t) catch (_:Dynamic) {};
							var rest = sig.args.slice(1);
							var ret = sig.ret;
							var tcallb = TFun({args: rest, ret: ret});
							var twrap = TFun({args: [{name: "_e", opt: false, t: se.thisExpr.type}], ret: tcallb});
							var args:Array<TFuncArg> = [];
							var locals:Array<TExpr> = [];
							for (a in rest) {
								var vt = a.opt ? ctx.com.basic.tnull(a.t) : a.t;
								// An unnamed function-type argument gets a bare generated local (renamed
								// _g), a named one keeps its name.
								var name = a.name == "" ? "`" : a.name;
								var v = TypeFunctions.allocVar(VGenerated, name, vt, p);
								args.push({v: v, c: a.opt ? TypeFunctions.mk(TConst(TNull), vt, p) : null});
								locals.push(TypeFunctions.mk(TLocal(v), vt, p));
							}
							var ve = TypeFunctions.allocVar(VGenerated, "_e", se.thisExpr.type, se.thisExpr.pos);
							var call = Calls.makeCall(ctx, fieldExpr,
								[TypeFunctions.mk(TLocal(ve), ve.type, p)].concat(locals), ret, p);
							var body = isVoid(TypeFunctions.follow(ret)) ? call : TypeFunctions.mk(TReturn(call), TypeFunctions.tDynamic, p);
							var ecallb = TypeFunctions.mk(TFunction(new TFunc(args, ret, body)), tcallb, p);
							var ewrap = TypeFunctions.mk(TFunction(new TFunc([{v: ve, c: null}], tcallb,
								TypeFunctions.mk(TReturn(ecallb), TypeFunctions.tDynamic, p))), twrap, p);
							Calls.makeCall(ctx, ewrap, [se.thisExpr], tcallb, p);
						case _:
							FieldAccessTools.getFieldExpr(fa, FRead);
					}
				}
			case AKAccess(_, _, _, _, _): throw new TypingError("Abstract array access is not yet ported", Position.nullPos);
			case AKResolve(se, name):
				// A macro resolve method runs at type time with the receiver as syntax and the field name
				// as a string literal; the resolve call goes through the field call, which dispatches macro
				// methods.
				if (se.access.field.kind.match(Method(MethMacro))) {
					var eName = new Expr(EConst(CString(name, SDoubleQuotes)), se.access.pos);
					return hxc.eval.EvalMacro.run(ctx, se.access, [Calls.typedExprToSyntax(ctx, se.thisExpr), eName], WithTypeTools.value, se.access.pos);
				}
				var ce = FieldAccessTools.getFieldExpr(se.access, FCall);
				switch (TypeFunctions.follow(ce.type)) {
					case TFun(sig) if (sig.args.length >= 2):
						// The resolve name is built at Position.nullPos, so it contributes no source
						// mapping at all.
						var eName = TexprTools.makeString(ctx.com.basic, name, hxc.ast.Position.nullPos);
						var nameArg = castOrUnify(ctx, sig.args[1].t, eName, eName.pos);
						Calls.makeCall(ctx, ce, Calls.padPosInfos(ctx, sig.args, [se.thisExpr, nameArg], se.access.pos), sig.ret, se.access.pos);
					case _:
						throw new TypingError("Resolve target is not a function", se.access.pos);
				}
			case AKSafeNav(sn):
				var ethen = accGet(ctx, sn.access);
				var t = ctx.com.basic.tnull(ethen.type);
				if (!TypeFunctions.isNull(ethen.type) && !TypeFunctions.isExplicitNull(ethen.type))
					ethen = TypeFunctions.mk(TCast(ethen, null), t, ethen.pos);
				var enullBase = TypeFunctions.mk(TConst(TNull), sn.base.type, sn.pos);
				var econd = TypeFunctions.mk(TBinop(OpNotEq, sn.base, enullBase), ctx.com.basic.tbool, sn.pos);
				var eelse = TypeFunctions.mk(TConst(TNull), t, sn.pos);
				var eif = TypeFunctions.mk(TIf(econd, ethen, eelse), t, sn.pos);
				sn.tempVar == null ? eif : TypeFunctions.mk(TBlock([sn.tempVar, eif]), t, sn.pos);
		};
	}

	// `T.new` is the constructor as a value: a function `(args) -> new T(args)`. Handles a class and a
	// @:forward.new abstract (whose construction forwards to the underlying class).
	static function constructorValue(ctx:TyperContext, e1:Expr, mode:AccessMode, p:Position):Null<AccessKind> {
		// The receiver types as a value and its failure stands: `Nope.new` is an unknown identifier, not
		// a missing type. Swallowing it here would drop through to the dot-path resolver, which would
		// answer about the path instead.
		var te1 = typeExpr(ctx, e1, WithTypeTools.value);
		// An abstract with its own constructor: `A.new` is a closure over the impl `_new` static.
		switch (te1.expr) {
			case TTypeExpr(TAbstractDecl(a)) if (a.impl != null && !TypeFunctions.hasMeta(":forward.new", a.meta) && a.impl.statics.exists("_new")):
				if (mode.match(MSet(_))) throw new TypingError("Cannot set constructor", p);
				if (mode.match(MCall(_))) throw new TypingError("Cannot call constructor like this, use 'new " + hxc.core.Globals.sTypePath(a.path) + "()' instead", p);
				// Building the closure over `_new` can fail for a complex (e.g. inline, generic) ctor; fall
				// back to the normal access path rather than dropping the whole enclosing field.
				return try {
					var newCf = a.impl.statics.get("_new");
					hxc.typing.TypeFields.forceFieldBody(ctx.com, a.impl, newCf);
					var atl:TParams = [for (_ in a.params) TypeFunctions.mkMono()];
					var sig = switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, atl, TypeFunctions.follow(newCf.type)))) { case TFun(s): s; case _: null; };
					if (sig == null) null;
					else {
						var retT = TAbstract(a, atl);
						var vl = [for (arg in sig.args) TypeFunctions.allocVar(VGenerated, arg.name, arg.t, p)];
						var el:Array<TExpr> = [for (v in vl) TexprTools.makeLocal(v, p)];
						var implExpr = TexprTools.makeTypeExpr(TClassDecl(a.impl), p);
						var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, newCf, FHStatic(a.impl), false, p), FCall);
						var call = Calls.makeCall(ctx, fieldExpr, el, retT, p);
						var body = TypeFunctions.mk(TReturn(call), retT, p);
						var tf = new TFunc([for (v in vl) {v: v}], retT, body);
						AKExpr(TypeFunctions.mk(TFunction(tf), TFun({args: sig.args, ret: retT}), p));
					}
				} catch (_:haxe.Exception) null;
			case _:
		}
		// (target class, its params, the value type of `new`, an optional cast target for an abstract)
		var target:Null<{c:TClass, tl:TParams, vt:T, castTo:Null<T>}> = switch (te1.expr) {
			case TTypeExpr(TClassDecl(c)):
				// Constrained monos so a class param's constraint still checks when the closure's call
				// binds it.
				var monos:TParams = TypeUnification.spawnConstrainedMonos(function(t) return t, c.params);
				{c: c, tl: monos, vt: TInst(c, monos), castTo: null};
			case TTypeExpr(TAbstractDecl(a)) if (a.impl != null && TypeFunctions.hasMeta(":forward.new", a.meta)):
				var atl:TParams = [for (_ in a.params) TypeFunctions.mkMono()];
				switch (TypeFunctions.follow(a.thisType)) {
					case TInst(uc, upl): {c: uc, tl: upl, vt: TInst(uc, upl), castTo: TAbstract(a, atl)};
					case _: null;
				}
			case _: null;
		};
		// The `X.new` arm has no fallthrough. A receiver that is not a class type is this error, over the
		// whole access and whatever the mode.
		if (target == null) throw new TypingError("Binding new is only allowed on class types", p);
		if (mode.match(MSet(_))) throw new TypingError("Cannot set constructor", p);
		if (mode.match(MCall(_))) throw new TypingError("Cannot call constructor like this, use 'new " + hxc.core.Globals.sTypePath(target.c.path) + "()' instead", p);
		hxc.eval.EvalMacro.ensureBuilt(ctx.com, target.c);
		// An inherited constructor resolves on the nearest ancestor declaring one, with the ancestor's
		// parameters applied along the chain; none anywhere is "does not have a constructor".
		var ownerC = target.c;
		var ownerTl = target.tl;
		var ctor = ownerC.constructor;
		while (ctor == null && ownerC.superClass != null) {
			var sup = ownerC.superClass;
			ownerTl = [for (t in sup.params) TypeFunctions.applyParams(ownerC.params, ownerTl, t)];
			ownerC = sup.c;
			ctor = ownerC.constructor;
		}
		if (ctor == null)
			throw new TypingError(hxc.core.Globals.sTypePath(target.c.path) + " does not have a constructor", p);
		if (TypeFunctions.hasClassFlag(target.c, CAbstract))
			throw new TypingError(hxc.core.Globals.sTypePath(target.c.path) + " is abstract and cannot be constructed", p);
		hxc.typing.TypeFields.forceFieldBody(ctx.com, ownerC, ctor);
		var sig = switch (TypeFunctions.follow(TypeFunctions.applyParams(ownerC.params, ownerTl, TypeFunctions.follow(ctor.type)))) { case TFun(s): s; case _: return null; };
		var vl = [for (arg in sig.args) TypeFunctions.allocVar(VGenerated, arg.name, arg.t, p)];
		var el:Array<TExpr> = [for (v in vl) TexprTools.makeLocal(v, p)];
		var enew = TypeFunctions.mk(TNew(target.c, target.tl, el), target.vt, p);
		var result = target.castTo == null ? enew : TypeFunctions.mk(TCast(enew, null), target.castTo, p);
		var retT = target.castTo == null ? target.vt : target.castTo;
		var body = TypeFunctions.mk(TReturn(result), retT, p);
		var tf = new TFunc([for (v in vl) {v: v}], retT, body);
		return AKExpr(TypeFunctions.mk(TFunction(tf), TFun({args: sig.args, ret: retT}), p));
	}

	public static function typeAccess(ctx:TyperContext, edef:ExprDef, p:Position, mode:AccessMode, withType:WithType):AccessKind {
		return switch (edef) {
			case EConst(CIdent(s)):
				typeIdent(ctx, s, p, mode, withType);
			case EField(e1, field, EFSafe):
				if (StringTools.startsWith(field, "$")) throw new TypingError("Field names starting with $ are not allowed", p);
				var base = typeExpr(ctx, e1, WithTypeTools.value);
				var safeBase = base;
				var temp:Null<TExpr> = null;
				switch (base.expr) {
					case TLocal(_) | TTypeExpr(_) | TConst(_):
					case _:
						var v = TypeFunctions.allocVar(VGenerated, "tmp", base.type, base.pos);
						temp = TypeFunctions.mk(TVarExpr(v, base), ctx.com.basic.tvoid, base.pos);
						safeBase = TexprTools.makeLocal(v, base.pos);
				}
				var snAcc = AKSafeNav({pos: p, base: safeBase, tempVar: temp,
					access: Fields.typeField(ctx, safeBase, field, p, mode, withType)});
				// A `?.` chain desugars into a null check whose type is Null<T> and whose parts
				// carry the whole chain's position, so the display has to answer from the ACCESS:
				// the field itself, exactly as a plain `.` would report it.
				checkDisplayOnAccess(ctx, snAcc, p);
				snAcc;
			case EField(e1, field, _):
				if (StringTools.startsWith(field, "$")) throw new TypingError("Field names starting with $ are not allowed", p);
				// The dangling display dot (EField with an empty name from parseField) asks for the legacy
				// field-completion list. (display on dot paths).
				if (field == "" && hxc.parser.Parser.displayFile != null) return AKExpr(displayFieldCompletion(ctx, e1, p));
				if (field == "new") {
					var cv = constructorValue(ctx, e1, mode, p);
					if (cv != null) return cv;
				}
				switch (e1.expr) {
					case EConst(CString(s, _)) if (field == "code"):
						var cp = singleCodePoint(s);
						if (cp == null) throw new TypingError("String must be a single UTF8 char", e1.pos);
						return AKExpr(TypeFunctions.mk(TConst(TInt(cp)), ctx.com.basic.tint, p));
					case EConst(CIdent("super")):
						// `super.field` resolves the field against the superclass with a TSuper receiver, so
						// the call dispatches to the inherited definition rather than an override.
						var sup = ctx.curclass.superClass;
						// The ident is typed first, so all of this reports at the `super` TOKEN rather than over the
						// whole field access, and the superclass check comes before the current-function one (an
						// abstract has no superclass, so it is told that rather than that it is an abstract).
						if (sup == null) throw new TypingError("Current class does not have a superclass", e1.pos);
						switch (ctx.curfun) {
							case FunMember | FunConstructor:
							case FunMemberAbstract:
								throw new TypingError("Cannot access super inside an abstract function", e1.pos);
							case FunStatic:
								throw new TypingError("Cannot access super inside a static function", e1.pos);
							case FunMemberClassLocal | FunMemberAbstractLocal:
								throw new TypingError("Cannot access super inside a local function", e1.pos);
						}
						var superExpr = TypeFunctions.mk(TConst(TSuper), TInst(sup.c, sup.params), e1.pos);
						return Fields.typeField(ctx, superExpr, field, p, mode, withType);
					case EConst(CIdent(modName)) if (modName.charCodeAt(0) >= "A".code && modName.charCodeAt(0) <= "Z".code):
						// An uppercase ident not bound in the current module context (its own types, imports)
						// resolves as a module, whose module-level statics win over the module's types >
						// resolve_in_module: resolve_module_field runs first).
						var acc = unqualifiedModuleStaticField(ctx, modName, field, p, mode);
						if (acc != null) return acc;
					case _:
				}
				try {
					// Is the SPECULATIVE lookup: it raises and reports nothing, and uses it for a dot path's head
					// so a package prefix falls through to the type-path route below. hxc reaches that head
					// through the REPORTING typeIdent, so the attempt runs with the recording off - a resolvable
					// `haxe.Log.trace` must not leave `haxe` in the unresolved list.
					var speculative = flattenIdentPath(e1.expr) != null;
					if (speculative) identSpeculation++;
					var acc = try typeAccess(ctx, e1.expr, e1.pos, MGet, WithTypeTools.value)
						catch (headErr:Dynamic) { if (speculative) identSpeculation--; throw headErr; };
					if (speculative) identSpeculation--;
					switch (acc) {
						case AKSafeNav(sn):
							AKSafeNav({
								pos: sn.pos,
								base: sn.base,
								tempVar: sn.tempVar,
								access: Fields.typeField(ctx, accGet(ctx, sn.access), field, p, mode, withType)
							});
						case _:
							Fields.typeField(ctx, accGet(ctx, acc), field, p, mode, withType);
					}
				} catch (err:TypingError) {
					// The dot-path route only applies when the path COULD be a package-led type path (leading
					// lowercase segment) or when the base itself failed to resolve; a resolved base whose field is
					// missing keeps its own error the route up front, no fallback).
					var segs0 = flattenIdentPath(EField(e1, field, EFNormal));
					var baseUnresolved = StringTools.startsWith(err.message, "Unknown identifier :")
						|| StringTools.startsWith(err.message, "Type not found :")
						|| (StringTools.startsWith(err.message, "Module ") && err.message.indexOf(" does not define type ") >= 0);
					var lowerLed = segs0 != null && segs0.length > 0 && {
						var c0 = segs0[0].charCodeAt(0);
						c0 >= "a".code && c0 <= "z".code;
					};
					// A base bound in the current module context (own types, NAMED imports)
					// falls back to the module walk on a field miss (resolve_unqualified's
					// type_field ~resume -> find_in_unqualified_modules); a wildcard- or
					// package-resolved base keeps its field error.
					var contextBound = false;
					if (!lowerLed && !baseUnresolved && segs0 != null && segs0.length > 0) {
						var curM2 = ctx.com.currentModule;
						if (curM2 != null) {
							for (mt2 in curM2.types) if (TypeFunctions.tInfos(mt2).path.name == segs0[0]) { contextBound = true; break; }
							if (!contextBound) {
								var imps2 = ctx.com.moduleImports.get(hxc.context.Context.pathKey(curM2.path));
								if (imps2 != null && imps2.names.exists(segs0[0])) contextBound = true;
							}
						}
					}
					if (!lowerLed && !baseUnresolved && !contextBound) throw err;
					var acc = tryTypePath(ctx, EField(e1, field, EFNormal), p, mode, withType);
					if (acc == null) throw err;
					acc;
				}
			case EArray(e1, e2):
				if (displaySignature) checkArraySignatureDisplay(ctx, e1, e2, withType, p);
				var a1 = typeAccess(ctx, e1.expr, e1.pos, MGet, WithTypeTools.value);
				var te2 = typeExpr(ctx, e2, WithTypeTools.value);
				switch (a1) {
					case AKSafeNav(sn):
						AKSafeNav({
							pos: sn.pos,
							base: sn.base,
							tempVar: sn.tempVar,
							access: Calls.arrayAccess(ctx, accGet(ctx, sn.access), te2, mode, p)
						});
					case _:
						Calls.arrayAccess(ctx, accGet(ctx, a1), te2, mode, p);
				}
			case ECall(e1, params):
				if (displaySignature) checkSignatureDisplay(ctx, e1, params, p);
				hxc.eval.EvalMacro.lastExpansionAst = null;
				var acc = Calls.typeCallAccess(ctx, e1, params, withType, p);
				// A call result is not an lvalue; a MACRO call defers to its EXPANSION, which reports at
				// its own position when it is itself a call (an inline call would otherwise reduce to an
				// assignable field first).
				if (mode.match(MSet(_)) && !ctx.untypedMode) {
					var expansion = hxc.eval.EvalMacro.lastExpansionAst;
					if (expansion == null) {
						throw new TypingError("Invalid assign", p);
					} else {
						var inner = expansion;
						while (true) switch (inner.expr) {
							case EParenthesis(e2) | EMeta(_, e2): inner = e2;
							case _: break;
						}
						if (inner.expr.match(ECall(_, _))) throw new TypingError("Invalid assign", inner.pos);
					}
				}
				acc;
			case _:
				AKExpr(typeExpr(ctx, new Expr(edef, p), withType));
		};
	}

	static function typeBlock(ctx:TyperContext, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		// The display position sits inside this block but on no statement (whitespace or an empty body):
		// the spot is marked and completion raises with an empty subject. Statements before the cursor
		// type first so their locals are in scope. The display preprocessor runs only when the parser did
		// not resume: a resume has already produced the display node, so no marker may be inserted
		// anywhere else. Without that check `switch s.<cursor>` would lose its field completion to this
		// scan, since the switch ends exactly where the cursor is.
		if ((displayToplevel || displayToplevelJson) && !hxc.parser.Parser.hadResume
			&& atDisplayPos(p) && fieldCompletionFound == null) {
			var covered = false;
			for (e in el) if (atDisplayPos(e.pos)) {
				// A switch is the one node that may DECLINE the position it encloses, so it does not
				// trigger when the cursor is on its closing `}`. A switch the cursor sits just past claims
				// nothing, and the block it is a statement of answers instead. Every other node annotates
				// itself, which is what this scan stands in for.
				switch (e.expr) {
					case ESwitch(_, _, _) if (e.pos.max <= hxc.parser.Parser.displayOffset):
					case _: covered = true; break;
				}
			}
			if (!covered) {
				var off = hxc.parser.Parser.displayOffset;
				for (e in el) if (e.pos.max < off) try typeExpr(ctx, e, WithTypeTools.noValue) catch (_:TypingError) {}
				if (displayToplevelJson)
					throw new JsonToplevelCompletion(collectToplevelJson(ctx));
				// A bare position in a block has no subject at all.
				throw new hxc.compiler.DisplayXml.ToplevelCompletion(collectToplevel(ctx, withType, true));
			}
		}
		var acc:Array<TExpr> = [];
		function merge(e:TExpr) {
			switch (e.expr) {
				case TMeta(m, inner) if (m.name == ":mergeBlock"):
					switch (inner.expr) {
						case TBlock(el2): for (x in el2) acc.push(x);
						case _: acc.push(e);
					}
				case _: acc.push(e);
			}
		}
		var i = 0;
		while (i < el.length) {
			var wt = (i == el.length - 1) ? withType : WithTypeTools.noValue;
			// A statement that fails to type is recorded and skipped so the rest of the block still types,
			// accumulating multiple errors instead of aborting on the first.
			try {
				merge(typeExpr(ctx, el[i], wt));
			} catch (err:TypingError) {
				ctx.com.addDiagnostic(err.message, err.pos, err.depth);
			}
			i++;
		}
		var t = acc.length == 0 ? ctx.com.basic.tvoid : acc[acc.length - 1].type;
		return TypeFunctions.mk(TBlock(acc), t, p);
	}

	static function typeVars(ctx:TyperContext, vl:Array<EVar>, p:Position):TExpr {
		var basic = ctx.com.basic;
		var out:Array<{v:TVar, e:Null<TExpr>}> = [];
		// The cursor on a var name marks nothing here (the declaration answers it, and every var after it
		// is left alone); otherwise the first initializer whose leading gap holds the cursor becomes the
		// display subject.
		if (atDisplayPos(p)) for (ev in vl) {
			if (atDisplayPos(ev.evName.pos)) break;
			// A var with no expression has nothing to mark; a cursor on its type hint is picked up while
			// that hint loads.
			if (ev.evExpr == null) continue;
			if (markedGap(ev.evType != null ? ev.evType.pos : ev.evName.pos, ev.evExpr)) {
				markedDisplay = ev.evExpr;
				break;
			}
		}
		for (ev in vl) {
			var n = ev.evName.name;
			var pv = ev.evName.pos;
			checkLocalVariableName(ctx, n, TVOLocalVariable, pv);
			try {
				// The hint loads inside the same attempt as the initializer, so a hint that fails skips
				// everything after it - the initializer is not typed, the variable is not the one the user
				// declared, and nothing answers a display request from it.
				var t:T = ev.evType == null ? spawnMonomorph(ctx, pv) : Typeload.loadTypeHint(ctx.com, ctx.typeParams, ev.evType);
				var e:Null<TExpr> = switch (ev.evExpr) {
					case null: null;
					case ex:
						var oldLoop = ctx.inLoop;
						if (ev.evStatic) ctx.inLoop = false;
						var te = try typeExpr(ctx, ex, WithTypeTools.withType(t)) catch (err:TypingError) { ctx.inLoop = oldLoop; throw err; };
						ctx.inLoop = oldLoop;
						castOrUnify(ctx, t, te, p);
				};
				// A var carrying the :this meta is the abstract constructor's synthetic this-var; classify
				// it VAbstractThis (compiler-generated) so fusion still folds it under -debug.
				var v = if (TypeFunctions.hasMeta(":this", ev.evMeta))
					addLocal(ctx, VAbstractThis, n, t, pv)
				else
					addLocalWithOrigin(ctx, TVOLocalVariable, n, t, pv);
				v.meta = ev.evMeta;
				if (ev.evFinal) TypeFunctions.addVarFlag(v, VFinal);
				if (ev.evStatic) TypeFunctions.addVarFlag(v, VStatic);
				// The cursor on the DECLARED name answers with the variable itself, which makes a hover there a
				// Local rather than the expression around it.
				if (atDisplayPos(pv)) displayVariable(ctx, v, pv);
				out.push({v: v, e: e});
			} catch (err:TypingError) {
				// Record the error, then a generated local at Dynamic with no initializer. VGenerated, not the
				// user origin: the declaration did not survive, so it is not the variable the user wrote and
				// must not be reported as one.
				ctx.com.addDiagnostic(err.message, err.pos, err.depth);
				out.push({v: addLocal(ctx, VGenerated, n, TypeFunctions.tDynamic, pv), e: null});
			} catch (ce:hxc.context.Context.ContextError) {
				ctx.com.addDiagnostic(ce.message, ce.pos, ce.depth);
				out.push({v: addLocal(ctx, VGenerated, n, TypeFunctions.tDynamic, pv), e: null});
			}
		}
		for (ve in out) {
			switch (TypeFunctions.follow(ve.v.type)) {
				case TMono(_):
					// A still-open var type re-checks once inference settles; a later binding to Void (e.g.
					// through an assignment) still reports.
					var v = ve.v;
					ctx.com.pendingConstraintChecks.push(function() {
						if (isVoid(TypeFunctions.follow(v.type)))
							ctx.com.addDiagnostic("Variables of type Void are not allowed", v.pos);
					});
				case ft:
					if (isVoid(ft))
						throw new TypingError("Variables of type Void are not allowed", ve.v.pos);
			}
		}
		if (out.length == 1) {
			return TypeFunctions.mk(TVarExpr(out[0].v, out[0].e), basic.tvoid, p);
		}
		var block = [for (ve in out) TypeFunctions.mk(TVarExpr(ve.v, ve.e), basic.tvoid, p)];
		var e = TypeFunctions.mk(TBlock(block), basic.tvoid, p);
		return TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: p}, e), e.type, e.pos);
	}

	static function typeIf(ctx:TyperContext, econd:Expr, e1:Expr, e2:Null<Expr>, withType:WithType, isTernary:Bool, p:Position):TExpr {
		var c = typeExpr(ctx, econd, WithTypeTools.value);
		if (isTernary) switch (c.expr) {
			case TConst(TNull): throw new TypingError("Cannot use null as ternary condition", c.pos);
			case _:
		}
		c = castOrUnify(ctx, ctx.com.basic.tbool, c, p);
		var te1 = typeExpr(ctx, Expr.ensureBlock(e1), withType);
		return switch (e2) {
			case null: TypeFunctions.mk(TIf(c, te1, null), ctx.com.basic.tvoid, p);
			case ex2:
				var te2 = typeExpr(ctx, Expr.ensureBlock(ex2), withType);
				makeIfThenElse(ctx, c, te1, te2, withType, p);
		};
	}

	public static function makeIfThenElse(ctx:TyperContext, e0:TExpr, e1:TExpr, e2:TExpr, withType:WithType, p:Position):TExpr {
		var t:T;
		switch (withType) {
			case NoValue:
				t = ctx.com.basic.tvoid;
			case Value(_):
				t = unifyMin(ctx, [e1, e2]);
			case WithType(tt, src):
				var ft = TypeFunctions.follow(tt);
				var useMin = switch (ft) {
					case TMono(_): true;
					case _: isVoid(ft);
				};
				if (useMin) {
					t = unifyMinForTypeSource(ctx, [e1, e2], src);
				} else {
					e1 = castOrUnify(ctx, tt, e1, e1.pos);
					e2 = castOrUnify(ctx, tt, e2, e2.pos);
					t = tt;
				}
		}
		return TypeFunctions.mk(TIf(e0, e1, e2), t, p);
	}

	static function typeReturn(ctx:TyperContext, e:Null<Expr>, withType:WithType, p:Position, implicit:Bool = false):TExpr {
		var isAbstractCtor = ctx.curfun.match(FunMemberAbstract) && ctx.curfield != null && ctx.curfield.name == "_new";
		switch (e) {
			case null if (isAbstractCtor):
				// An early `return;` in an abstract constructor returns `cast this`, so the
				// definite-assignment filter sees the read and reports a missing `this = value`.
				var ecast = TypeFunctions.mk(TCast(getThis(ctx, p), null), ctx.ret, p);
				return TypeFunctions.mk(TReturn(ecast), monoOrDynamic(ctx, withType, p), p);
			case null:
				var v = ctx.com.basic.tvoid;
				try {
					TypeUnification.unifyDefault(v, ctx.ret);
				} catch (_:UnifyError) {
					throw new TypingError("Void should be " + "the function's return type", p);
				}
				var expectVoid = switch (withType) {
					case WithType(t, _): isVoid(t);
					case Value(ImplicitReturn): true;
					case _: false;
				};
				return TypeFunctions.mk(TReturn(null), expectVoid ? v : monoOrDynamic(ctx, withType, p), p);
			case ex:
				// A value return in an abstract constructor reports unless it is the synthesized `cast
				// this`.
				if (isAbstractCtor) switch (ex.expr) {
					case ECast({expr: EConst(CIdent("this"))}, null):
					case _: ctx.com.addDiagnostic("Cannot return a value from constructor", p);
				}
				try {
				// An arrow function's implicit return carries the ImplicitReturn source so a switch body
				// can settle an open return mono from a bare `return;` arm.
				var withExpected = isVoid(TypeFunctions.follow(ctx.ret)) ? WithTypeTools.noValue
					: implicit ? WithTypeTools.ofImplicitReturn(ctx.ret) : WithTypeTools.withType(ctx.ret);
				var teRaw = typeExpr(ctx, ex, withExpected);
				// A Void return type with an implicit return (an arrow-function body) emits just the
				// expression, with no return statement: `() -> {}` and `() -> voidCall()` produce an
				// empty/plain body, not a trailing `return;`.
				if (implicit && isVoid(TypeFunctions.follow(ctx.ret))) return teRaw;
				// Returning a value from a Void function discards the value rather than unifying it.
				// ctx.ret may only just have settled to Void while typing teRaw (an inner `return` in an
				// unannotated arrow whose return mono that branch binds), so re-check here, not only up
				// front. `return null` is exempt: it stays a type error ("Cannot return null from
				// Void-function"), handled by the value path below.
				if (isVoid(TypeFunctions.follow(ctx.ret)) && !isVoid(TypeFunctions.follow(teRaw.type)) && !teRaw.expr.match(TConst(TNull))) {
					var vt = monoOrDynamic(ctx, withType, p);
					return TypeFunctions.mk(TBlock([teRaw, TypeFunctions.mk(TReturn(null), vt, p)]), vt, teRaw.pos);
				}
				var te = castOrUnify(ctx, ctx.ret, teRaw, p);
				if (isVoid(TypeFunctions.follow(te.type))) {
					switch (te.expr) {
						case TConst(TNull): throw new TypingError("Cannot return `null` from Void-function", p);
						case _:
					}
					var t = monoOrDynamic(ctx, withType, p);
					return TypeFunctions.mk(TBlock([te, TypeFunctions.mk(TReturn(null), t, p)]), t, te.pos);
				}
				return TypeFunctions.mk(TReturn(te), monoOrDynamic(ctx, withType, p), p);
				} catch (err:TypingError) {
					// Inside call arguments the failure raises so the argument boundary annotates it with the
					// parameter name .
					if (ctx.com.isMacro || ctx.inCallArgs) throw err;
					ctx.com.addDiagnostic(err.message, err.pos, err.depth);
					if (StringTools.startsWith(err.message, "Int should be haxe.ds.Option"))
						ctx.com.addDiagnostic(err.message, err.pos, err.depth);
					var nullExpr = TypeFunctions.mk(TConst(TNull), TypeFunctions.mkMono(), p);
					return TypeFunctions.mk(TReturn(nullExpr), monoOrDynamic(ctx, withType, p), p);
				}
		}
	}

	// Inside a member's local function `this` becomes a generated `this local captured from the
	// enclosing member (materialized by typeFunction below and renamed _gthis by RenameVars); a plain
	// member/constructor uses TConst(TThis) directly.
	public static function getThis(ctx:TyperContext, p:Position):TExpr {
		function abstractThisLocal():Null<TVar> {
			var direct = ctx.locals.get("this");
			if (direct != null) return direct;
			for (name in ctx.locals.keys()) {
				var candidate = ctx.locals.get(name);
				if (candidate != null && TypeFunctions.hasMeta(":this", candidate.meta)) return candidate;
			}
			return null;
		}
		return switch (ctx.curfun) {
			case FunStatic:
				throw new TypingError("Cannot access this from a static function", p);
			case FunMemberClassLocal:
				var v = if (ctx.vthis == null) {
					var v2 = addLocal(ctx, VGenerated, "`this", ctx.tthis, p);
					ctx.vthis = v2;
					v2;
				} else {
					ctx.locals.set(ctx.vthis.name, ctx.vthis);
					ctx.vthis;
				}
				TypeFunctions.mk(TLocal(v), ctx.tthis, p);
			case FunMemberAbstractLocal:
				var v = abstractThisLocal();
				if (v == null) throw new TypingError("Cannot reference this abstract here", p);
				TypeFunctions.mk(TLocal(v), v.type, p);
			case FunMemberAbstract:
				var v = abstractThisLocal();
				if (v == null) throw new TypingError("Cannot reference this abstract here", p);
				TypeFunctions.mk(TLocal(v), v.type, p);
			case FunConstructor | FunMember:
				TypeFunctions.mk(TConst(TThis), ctx.tthis, p);
		}
	}

	public static function typeFunction(ctx:TyperContext, args:Array<TFuncArg>, ret:T, fmode:CurrentFun, bodyExpr:Null<Expr>, p:Position):TFunc {
		// Monomorphs spawned while typing this function close at its conclusion (the newest sit at the
		// front of the registry).
		var monoDepth = ctx.monomorphs.length;
		var oldInFunction = ctx.inFunction;
		var oldCurfun = ctx.curfun;
		var oldRet = ctx.ret;
		var oldLoop = ctx.inLoop;
		// ctx.opened is cleared for the new function.
		var oldOpened = ctx.opened;
		ctx.opened = [];
		// A fresh member/constructor/static gets its own captured-this slot; a local function shares the
		// enclosing member's (each field is typed in its own context).
		var isLocalFn = fmode.match(FunMemberClassLocal | FunMemberAbstractLocal);
		var oldVthis = ctx.vthis;
		if (!isLocalFn) ctx.vthis = null;
		var restore = saveLocals(ctx);
		ctx.inFunction = true;
		ctx.curfun = fmode;
		ctx.ret = ret;
		ctx.inLoop = false;
		for (a in args) ctx.locals.set(a.v.name, a.v);
		function reset() {
			restore();
			if (!isLocalFn) ctx.vthis = oldVthis;
			ctx.inFunction = oldInFunction;
			ctx.curfun = oldCurfun;
			ctx.ret = oldRet;
			ctx.inLoop = oldLoop;
			// Opened structures close at the END of the function, before the enclosing list is put back.
			for (r in ctx.opened) r.set(Closed);
			ctx.opened = oldOpened;
		}
		if (bodyExpr == null) {
			reset();
			throw new TypingError("Function body required", p);
		}
		// Print the field's syntax tree when it carries @:debug.position, or @:debug.display in a display
		// run. They are the only way to see what the parser built for a body the recovery had to
		// reassemble.
		if (ctx.curfield != null && (TypeFunctions.hasMeta(":debug.position", ctx.curfield.meta)
			|| (hxc.parser.Parser.displayFile != null && TypeFunctions.hasMeta(":debug.display", ctx.curfield.meta))))
			Sys.println("syntax:" + "
" + hxc.ast.Ast.Expr.dumpWithPos(bodyExpr));
		var errorsBefore = ctx.com.errorCount();
		var te = try typeExpr(ctx, bodyExpr, WithTypeTools.noValue) catch (e:TypingError) {
			reset();
			throw e;
		}
		var bodyHadError = ctx.com.errorCount() > errorsBefore;
		// An inferred return type with no value-return settles to Void; a resolved non-Void return requires
		// every path to return, throw, or dead-end.
		switch (TypeFunctions.follow(ret)) {
			case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Void"):
			case TMono(_) if (!hasReturn(te)):
				try TypeUnification.unifyDefault(ctx.com.basic.tvoid, ret) catch (_:UnifyError) {}
			case TMono(_):
				try returnFlow(ctx, ret, te) catch (_:ReturnFlowExit) {}
			// A dynamic method is reassignable, so its inferred return is linked to Void at body typing
			// before any reassignment binds it; hxc's field order can bind it first, so a dynamic method is
			// exempt from the flow check.
			case _ if (!isLocalFn && ctx.curfield != null && ctx.curfield.kind.match(Method(MethDynamic))):
			case _ if (bodyHadError):
			case _:
				try returnFlow(ctx, ret, te) catch (_:ReturnFlowExit) {}
		}
		// A constructor whose class inherits a constructor has to call super(). When the inherited one is
		// @:compilerGenerated the call is SYNTHESIZED instead of complaining (Filters.insertMissingSuper
		// does that), so only a user-written inherited constructor makes the omission an error - and it
		// is recorded, leaving the constructor otherwise typed.
		if (fmode.match(FunConstructor) && ctx.curclass != null && ctx.curclass.superClass != null) {
			var sup = try TypeFunctions.getConstructorClass(ctx.curclass.superClass.c, ctx.curclass.superClass.params)
				catch (_:hxc.core.NotFound) null;
			if (sup != null && !TypeFunctions.hasMeta(":compilerGenerated", sup.cf.meta)
				&& !hxc.filters.Filters.bodyCallsSuper(te))
				ctx.com.addDiagnostic("Missing super constructor call", p);
		}
		// A member whose local functions captured `this` declares the `this local, inserted before its
		// first use so a constructor's super() call stays first when possible.
		if (!isLocalFn && ctx.vthis != null) {
			var v = ctx.vthis;
			var ev = TypeFunctions.mk(TVarExpr(v, TypeFunctions.mk(TConst(TThis), ctx.tthis, p)), ctx.com.basic.tvoid, p);
			function usesV(e:TExpr):Bool {
				var found = false;
				function walk(e2:TExpr):Void {
					if (found) return;
					switch (e2.expr) { case TLocal(v2) if (v2 == v): found = true; case _: TexprTools.iter(walk, e2); }
				}
				walk(e);
				return found;
			}
			te = switch (te.expr) {
				case TBlock(el) if (ctx.com.platformConfig.thisBeforeSuper):
					// The platform can touch `this` before super(), so the declaration goes first
					TypeFunctions.mk(TBlock([ev].concat(el)), te.type, te.pos);
				case TBlock(el):
					var out:Array<TExpr> = [];
					var inserted = false;
					for (x in el) {
						if (!inserted && usesV(x)) { out.push(ev); inserted = true; }
						out.push(x);
					}
					if (!inserted) out.unshift(ev);
					TypeFunctions.mk(TBlock(out), te.type, te.pos);
				case _:
					TypeFunctions.mk(TBlock([ev, te]), te.type, te.pos);
			}
		}
		// Close this function's monomorphs, materializing structural constraints into their anon (a close
		// failure reports, not aborts). Closed entries leave the registry so an enclosing function does not
		// re-close them.
		var newCount = ctx.monomorphs.length - monoDepth;
		if (newCount > 0) {
			for (i in 0...newCount) {
				var mp = ctx.monomorphs[i];
				try TypeUnification.close(mp.m) catch (e:UnifyError) ctx.com.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(e.errors), mp.p);
			}
			ctx.monomorphs.splice(0, newCount);
		}
		reset();
		return new TFunc(args, ret, te);
	}

	// A class without its own constructor inherits the nearest superclass constructor, with the superclass
	// type arguments substituted along the inheritance chain. Generate a constructor for a @:structInit
	// class that lacks one, from its physical var fields (one argument per field, assigned to it),
	// threading the superclass constructor for inheritance. / get_struct_init_super_info. a non-extern
	// class with no constructor of its own but a superclass constructor inherits a forwarding one
	// (`function(args) super(args)`), so the generator emits the super call instead of an empty body.
	// Default values collapse to null on a non-static target (js), matching the reference. Runs for every
	// class before generation.
	static function hasInstanceFieldInit(c:TClass):Bool {
		for (f in c.orderedFields) switch (f.kind) {
			case Var(_) if (f.expr != null): return true;
			case _:
		}
		return false;
	}

	public static function ensureInheritedCtor(ctx:TyperContext, c:TClass):Void {
		if (c.constructor != null) return;
		if (TypeFunctions.hasClassFlag(c, CExtern)) return;
		// Process the super first so its (possibly synthesized) constructor exists before this class
		// looks it up, matching the reference's dependency-ordered add_constructor pass.
		if (c.superClass != null) ensureInheritedCtor(ctx, c.superClass.c);
		var found = if (c.superClass == null) null
			else try TypeFunctions.getConstructorClass(c, TypeFunctions.extractParamTypes(c.params)) catch (_:hxc.core.NotFound) null;
		if (found == null) {
			// No ancestor constructor to forward to: a class with an instance field initializer still needs
			// an (empty, compiler-generated) constructor so add_field_inits can fill it and a subclass can
			// forward. .
			if (hasInstanceFieldInit(c)) {
				var tvoid0 = ctx.com.basic.tvoid;
				var ct0 = TFun({args: [], ret: tvoid0});
				var tf0 = new TFunc([], tvoid0, TypeFunctions.mk(TBlock([]), tvoid0, c.pos));
				var cf0 = TypeFunctions.mkField("new", ct0, c.pos, c.pos);
				cf0.kind = Method(MethNormal);
				cf0.meta = [{name: ":compilerGenerated", params: [], pos: Position.nullPos}];
				cf0.expr = TypeFunctions.mk(TFunction(tf0), ct0, c.pos);
				c.constructor = cf0;
			}
			return;
		}
		var tvoid = ctx.com.basic.tvoid;
		TypeFields.forceFieldBody(ctx.com, found.c, found.cf);
		var st = TypeFunctions.applyParams(found.c.params, found.tl, found.cf.type);
		var superTfArgs:Null<Array<TFuncArg>> = found.cf.expr == null ? null
			: switch (found.cf.expr.expr) { case TFunction(tf): tf.args; case _: null; };
		var isStaticPf = ctx.com.platformConfig.isStatic;
		var isCppPf = ctx.com.platform.match(Cpp);
		switch (TypeFunctions.follow(st)) {
			case TFun(sig):
				var args:Array<TFuncArg> = [];
				var sigArgs:Array<TSignatureArg> = [];
				var superLocals:Array<TExpr> = [];
				for (ai in 0...sig.args.length) {
					var sa = sig.args[ai];
					// Copy the super arg, carrying the default only when the platform needs it. A non-static
					// target drops it to null (the super call fills it). On cpp a String default is kept; any
					// other cpp default makes the arg Null<T> with a null default so the super's own v.Default(x)
					// fills it when null is passed.
					var def = superTfArgs != null && ai < superTfArgs.length ? superTfArgs[ai].c : null;
					var argType = sa.t;
					var argDefault:Null<TExpr> = null;
					if (def != null) {
						if (!isStaticPf) argDefault = TypeFunctions.mk(TConst(TNull), sa.t, c.pos);
						else if (isCppPf && def.expr.match(TConst(TString(_)))) argDefault = def;
						else if (isCppPf) { argType = ctx.com.basic.tnull(sa.t); argDefault = TypeFunctions.mk(TConst(TNull), argType, c.pos); }
						else argDefault = def;
					} else if (sa.opt) {
						argDefault = TypeFunctions.mk(TConst(TNull), sa.t, c.pos);
					}
					var v = TypeFunctions.allocVar(VUser(TVOArgument), sa.name, argType, c.pos);
					args.push({v: v, c: argDefault});
					sigArgs.push({name: sa.name, opt: sa.opt, t: argType});
					superLocals.push(TypeFunctions.mk(TLocal(v), argType, c.pos));
				}
				var superCallee = TypeFunctions.mk(TConst(TSuper), TInst(c.superClass.c, c.superClass.params), c.pos);
				var body = TypeFunctions.mk(TCall(superCallee, superLocals), tvoid, c.pos);
				var ctorType = TFun({args: sigArgs, ret: tvoid});
				var tf = new TFunc(args, tvoid, body);
				var cfCtor = TypeFunctions.mkField("new", ctorType, c.pos, c.pos);
				// The forwarder keeps the parent constructor's kind, so an inherited INLINE constructor stays
				// inlinable (inline_constructors folds `new Child(...)` through the forwarded super call).
				cfCtor.kind = found.cf.kind;
				cfCtor.params = found.cf.params;
				// The inherited forwarding constructor keeps :compilerGenerated only when the PARENT ctor
				// carries it, so a class inheriting a user-written ctor exposes a meta-free `new` (rtti).
				cfCtor.meta = [for (m in found.cf.meta) if (m.name == ":compilerGenerated") m];
				cfCtor.expr = TypeFunctions.mk(TFunction(tf), ctorType, c.pos);
				c.constructor = cfCtor;
			case _:
		}
	}

	public static function ensureStructInitCtorFor(ctx:TyperContext, c:TClass):Void {
		try ensureStructInitCtor(ctx, c) catch (_:Dynamic) {}
	}

	static function ensureStructInitCtor(ctx:TyperContext, c:TClass):Void {
		if (c.constructor != null) return;
		if (!TypeFunctions.hasMeta(":structInit", c.meta)) return;
		// An interface never gets the synthesized constructor (it already reported); the struct literal
		// then reports the missing constructor.
		if (TypeFunctions.hasClassFlag(c, CInterface)) return;
		var params = TypeFunctions.extractParamTypes(c.params);
		var tvoid = ctx.com.basic.tvoid;
		var tthis = TypeFunctions.mk(TConst(TThis), TInst(c, params), c.pos);
		var args:Array<TFuncArg> = [];
		var sigArgs:Array<TSignatureArg> = [];
		var body:Array<TExpr> = [];
		// Every documented field contributes an `@param` line to the synthesized constructor's own doc.
		var docBuf = new StringBuf();
		// A field declared with a default value (`var x:Int = 100`) becomes an optional constructor
		// argument, and its assignment is guarded so an omitted arg keeps the declared default. The
		// default is detected from the AST field list.
		var hasDefault = new haxe.ds.StringMap<Bool>();
		var entry = ctx.com.declOfType.get(hxc.context.Context.pathKey(c.path));
		if (entry != null) switch (entry.decl) {
			case EClass(d):
				for (f in d.dData) switch (f.cffKind) {
					case FVar(_, e) if (e != null): hasDefault.set(f.cffName.name, true);
					case FProp(_, _, _, e) if (e != null): hasDefault.set(f.cffName.name, true);
					case _:
				}
			case _:
		}
		for (cf in c.orderedFields) {
			var physical = switch (cf.kind) {
				case Var(k): switch (k.read) { case AccCall | AccInline | AccRequire(_, _): false; case _: switch (k.write) { case AccCall: false; case _: true; } };
				case _: false;
			};
			if (!physical) continue;
			switch (cf.type) { case TLazy(r): cf.type = TypeFunctions.lazyType(r); case _: }
			var dflt = hasDefault.exists(cf.name);
			var opt = dflt || TypeFunctions.hasMeta(":optional", cf.meta);
			var at = opt ? ctx.com.basic.tnull(cf.type) : cf.type;
			var v = TypeFunctions.allocVar(VGenerated, cf.name, at, cf.namePos);
			args.push({v: v});
			sigArgs.push({name: cf.name, opt: opt, t: at});
			// The synthesized assignments all carry the class position, not each field's own position.
			var ef = TypeFunctions.mk(TField(tthis, FInstance(c, params, cf)), cf.type, c.pos);
			var ev = TypeFunctions.mk(TLocal(v), v.type, c.pos);
			var assign = TypeFunctions.mk(TBinop(OpAssign, ef, ev), cf.type, c.pos);
			switch (Ast.genDocTextOpt(cf.doc)) {
				case null:
				case d: docBuf.add("@param " + cf.name + " " + StringTools.trim(d) + "\n");
			}
			if (dflt) {
				// If (arg != null) this.field = arg -- the field keeps its declared default otherwise
				var cond = TypeFunctions.mk(TBinop(OpNotEq, ev, TypeFunctions.mk(TConst(TNull), at, c.pos)), ctx.com.basic.tbool, c.pos);
				body.push(TypeFunctions.mk(TIf(cond, assign, null), tvoid, c.pos));
			} else {
				body.push(assign);
			}
		}
		if (c.superClass != null) {
			ensureStructInitCtor(ctx, c.superClass.c);
			if (c.superClass.c.constructor != null) {
				var st = TypeFunctions.applyParams(c.superClass.c.params, c.superClass.params, c.superClass.c.constructor.type);
				switch (TypeFunctions.follow(st)) {
					case TFun(ssig):
						var superLocals:Array<TExpr> = [];
						// The super's own argument VARS are reused, so a forwarded field keeps the position where it
						// was declared.
						var superArgs:Null<Array<TFuncArg>> = c.superClass.c.constructor.expr == null ? null
							: switch (c.superClass.c.constructor.expr.expr) { case TFunction(sfn): sfn.args; case _: null; };
						for (i in 0...ssig.args.length) {
							var sa = ssig.args[i];
							var spos = superArgs != null && i < superArgs.length ? superArgs[i].v.pos : c.pos;
							var sv = TypeFunctions.allocVar(VGenerated, sa.name, sa.t, spos);
							args.push({v: sv});
							sigArgs.push({name: sa.name, opt: sa.opt, t: sa.t});
							superLocals.push(TypeFunctions.mk(TLocal(sv), sa.t, c.pos));
						}
						var superCallee = TypeFunctions.mk(TConst(TSuper), TInst(c.superClass.c, c.superClass.params), c.pos);
						body.unshift(TypeFunctions.mk(TCall(superCallee, superLocals), tvoid, c.pos));
					case _:
				}
			}
		}
		var tf = new TFunc(args, tvoid, TypeFunctions.mk(TBlock(body), tvoid, c.pos));
		var ctorType = TFun({args: sigArgs, ret: tvoid});
		var cfCtor = TypeFunctions.mkField("new", ctorType, c.pos, c.pos);
		cfCtor.kind = Method(MethNormal);
		// The synthesized constructor carries the collected @param doc and both metas, then collects what
		// @:inheritDoc brings it.
		cfCtor.doc = Ast.docFromString(docBuf.toString());
		cfCtor.meta = [
			{name: ":compilerGenerated", params: [], pos: Position.nullPos},
			{name: ":inheritDoc", params: [], pos: Position.nullPos}
		];
		cfCtor.expr = TypeFunctions.mk(TFunction(tf), ctorType, c.pos);
		c.constructor = cfCtor;
		hxc.typing.InheritDoc.buildClassFieldDoc(ctx.com, c, cfCtor);
	}

	static function findConstructorType(ctx:TyperContext, c:TClass, tl:TParams):Null<T> {
		var all = findConstructorTypes(ctx, c, tl);
		return all.length == 0 ? null : all[0];
	}

	// The primary constructor type plus its @:overload variants, class params applied (overloads are
	// expanded for the call-site retry).
	public static function findConstructorTypes(ctx:TyperContext, c:TClass, tl:TParams):Array<T> {
		var cur = c;
		var curTl = tl;
		while (cur != null) {
			ensureStructInitCtor(ctx, cur);
			if (cur.constructor != null) {
				var cf = cur.constructor;
				var curTl2 = curTl;
				var curCl = cur;
				function apply(t:T):T return TypeFunctions.applyParams(curCl.params, curTl2, t);
				// The constructor's own type params instantiate as constrained monomorphs, the same way a field
				// call treats method params; a constraint naming a still open class param defers through the
				// mono up-constraints.
				function instantiate(cfi:TClassField):T {
					var t = cfi.type;
					if (cfi.params.length > 0) {
						var monos = TypeUnification.spawnConstrainedMonos(apply, cfi.params);
						t = TypeFunctions.applyParams(cfi.params, monos, t);
					}
					return apply(t);
				}
				return [instantiate(cf)].concat([for (o in cf.overloads) instantiate(o)]);
			}
			if (cur.superClass == null) return [];
			hxc.eval.EvalMacro.ensureBuilt(ctx.com, cur.superClass.c);
			var superTl = [for (sp in cur.superClass.params) TypeFunctions.applyParams(cur.params, curTl, sp)];
			cur = cur.superClass.c;
			curTl = superTl;
		}
		return [];
	}

	static function hasTypeParameter(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, params):
				switch (c.kind) {
					case KTypeParameter(_): true;
					case _: hasTypeParameterParams(params);
				}
			case TEnum(_, params) | TType(_, params) | TAbstract(_, params):
				hasTypeParameterParams(params);
			case TFun(sig):
				for (arg in sig.args) if (hasTypeParameter(arg.t)) return true;
				hasTypeParameter(sig.ret);
			case TAnon(a):
				for (name in a.fields.keys()) if (hasTypeParameter(a.fields.get(name).type)) return true;
				false;
			case TLazy(f):
				hasTypeParameter(TypeFunctions.lazyType(f));
			case TDynamic(t):
				t != null && hasTypeParameter(t);
			case TMono(_):
				false;
		}
	}

	static function hasTypeParameterParams(params:Array<T>):Bool {
		for (t in params) if (hasTypeParameter(t)) return true;
		return false;
	}

	// The missing-constructor error names the abstract, not the impl class that carries _new.
	public static function noConstructorPath(c:TClass):hxc.core.Globals.Path {
		return switch (c.kind) { case KAbstractImpl(a): a.path; case _: c.path; };
	}

	// Construct a value of the underlying type a @:forward.new abstract forwards to: a class via its
	// constructor, an abstract via its _new impl, or a nested @:forward.new abstract by recursing on
	// its underlying. .
	static function constructForwarded(ctx:TyperContext, t:T, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		return switch (TypeFunctions.follow(t)) {
			case TInst(uc, upl):
				hxc.eval.EvalMacro.ensureBuilt(ctx.com, uc);
				var ctorType = findConstructorType(ctx, uc, upl);
				if (ctorType == null) throw new TypingError(hxc.core.Globals.sTypePath(uc.path) + " does not have a constructor", p);
				var sig = switch (TypeFunctions.follow(ctorType)) { case TFun(s): s; case _: {args: [], ret: ctx.com.basic.tvoid}; };
				var r = Calls.unifyCallArgs(ctx, el, sig.args, sig.ret, p);
				TypeFunctions.mk(TNew(uc, upl, r.el), TInst(uc, upl), p);
			case TAbstract(ua, ual) if (ua.impl != null && ua.impl.statics.exists("_new")):
				var newCf = ua.impl.statics.get("_new");
				TypeFields.forceFieldBody(ctx.com, ua.impl, newCf);
				var implExpr = TexprTools.makeTypeExpr(TClassDecl(ua.impl), p);
				var fa = FieldAccessTools.create(implExpr, newCf, FHAbstract(ua, ual, ua.impl), false, p);
				Calls.buildCall(ctx, AKField(fa), el, withType, p);
			case TAbstract(ua, ual) if (ua.impl != null && TypeFunctions.hasMeta(":forward.new", ua.meta)):
				var inner = constructForwarded(ctx, TypeFunctions.applyParams(ua.params, ual, ua.thisType), el, withType, p);
				TypeFunctions.mk(TCast(inner, null), TAbstract(ua, ual), p);
			case _:
				throw new TypingError("This type cannot be constructed", p);
		};
	}

	// userWritten: a construction the user actually spelled.
	public static function typeNew(ctx:TyperContext, tp:PlacedTypePath, el:Array<Expr>, withType:WithType, p:Position, userWritten:Bool = true):TExpr {
		// ENew under signature display: the signatures are the constructor's, found on the instantiated
		// type.
		if (displaySignature && signatureFound == null) checkNewSignatureDisplay(ctx, tp, el, p);
		try switch (ctx.com.getType({pack: tp.path.tpackage, name: tp.path.tname}, tp.pos, tp.path.tsub)) {
			case TTypeDecl(td): hxc.filters.DeprecationCheck.checkTypedefConstruction(ctx.com, td, tp.pos); hxc.filters.DeprecationCheck.markTypedefConstruction(p); hxc.filters.DeprecationCheck.markTypedefConstruction(tp.pos);
			case _:
		} catch (_:Dynamic) {}
		var t:T;
		// If the type fails to load and the display position is in the ARGUMENTS, type them anyway so the
		// request is answered, then re-raise.
		inline function typeArgsForDisplay():Void {
			for (e in el) if (atDisplayPos(e.pos)) {
				for (e2 in el) try typeExpr(ctx, e2, WithTypeTools.value) catch (_:Dynamic) {}
				break;
			}
		}
		if (tp.path.tparams.length == 0) {
			ctx.com.callArgumentStack.unshift(el);
			try {
				t = Typeload.loadInstance(ctx.com, ctx.typeParams, tp.path, tp.pos, true);
				ctx.com.callArgumentStack.shift();
			} catch (e:Dynamic) {
				ctx.com.callArgumentStack.shift();
				typeArgsForDisplay();
				throw e;
			}
		} else {
			try t = Typeload.loadInstance(ctx.com, ctx.typeParams, tp.path, tp.pos, false)
			catch (e:Dynamic) { typeArgsForDisplay(); throw e; }
		}
		// A construction reports its type path the way a type hint does, which under a completion request
		// answers with the type set; the ENew wrapper around this call is what narrows that to the types
		// something can actually be constructed from.
		if (userWritten) checkDisplayType(ctx.com, t, tp);
		return switch (TypeFunctions.follow(t)) {
				case TInst(c, params) if (c.kind.match(KTypeParameter(_))):
					// New T() on a generic type parameter resolves the constructor from a constructible
					// constraint.
					if (!isGenericParameter(ctx, c)) throw new TypingError("Only generic type parameters can be constructed", p);
					var ctl = switch (c.kind) { case KTypeParameter(x): x; case _: []; };
					switch (getConstructibleConstraint(ctx, ctl, p)) {
						case null: throw new TypingError(hxc.core.Globals.sTypePath(c.path) + " does not have a constructor", p);
						case cc:
							var r = Calls.unifyCallArgs(ctx, el, cc.args, cc.ret, p);
							TypeFunctions.mk(TNew(c, params, r.el), t, p);
					}
			case TInst(c, tl):
				var tl = switch (c.kind) {
					case KGeneric if (tp.path.tparams.length == 0 && hasTypeParameterParams(tl)):
						TypeUnification.spawnConstrainedMonos(function(t) return t, c.params);
					case _:
						tl;
				}
				var t = TInst(c, tl);
				// An abstract class has no direct construction.
				if (TypeFunctions.hasClassFlag(c, CAbstract))
					throw new TypingError(hxc.core.Globals.sTypePath(c.path) + " is abstract and cannot be constructed", p);
				hxc.eval.EvalMacro.ensureBuilt(ctx.com, c);
				// Force the constructor body so its unannotated param types are inferred from the body (e.g.
				// `new(x) this.x = x` gives x the field type) before call args are unified against them; else
				// the
				// first call site binds those still-open param monos to its arg types, corrupting later
				// constructions.
				if (c.constructor != null) TypeFields.forceFieldBody(ctx.com, c, c.constructor);
				var ctorTypes = findConstructorTypes(ctx, c, tl);
				if (ctorTypes.length == 0) throw new TypingError(hxc.core.Globals.sTypePath(noConstructorPath(c)) + " does not have a constructor", p);
				if (c.constructor != null) Fields.checkConstructorAccess(ctx, c, c.constructor, p);
				// Try each constructor signature, first success wins (overload retry).
				var r:Dynamic = null;
				var firstError:Null<Dynamic> = null;
				var chosenArgs:Null<Array<hxc.core.Type.TSignatureArg>> = null;
				for (ctorType in ctorTypes) {
					var sig = switch (TypeFunctions.follow(ctorType)) {
						case TFun(s): s;
						case _: {args: [], ret: ctx.com.basic.tvoid};
					};
					try {
						r = TypeUnification.withMonoRollback(function() return Calls.unifyCallArgs(ctx, el, sig.args, sig.ret, p));
						chosenArgs = sig.args;
						break;
					} catch (e:hxc.core.TypeUnification.UnifyError) {
						if (firstError == null) firstError = e;
					} catch (e:TypingError) {
						if (StringTools.startsWith(e.message, "Unknown identifier :") && e.message.indexOf("\n") >= 0)
							e = new TypingError(e.message.split("\n")[0], e.pos, e.depth);
						var prevError:Null<TypingError> = firstError == null ? null : try cast(firstError, TypingError) catch (_:Dynamic) null;
						var prevMsg = prevError == null ? "" : prevError.message;
						if (firstError == null || StringTools.startsWith(prevMsg, "Too many arguments") || StringTools.startsWith(prevMsg, "Not enough arguments")) firstError = e;
					}
				}
				if (r == null) throw (firstError != null ? firstError : new TypingError("No matching overload", p));
				// A construction reports the constructor the call resolved to, as the function that produces
				// the instance - not the instance type, which is all the typed node itself carries.
				if ((displayHover || displayTypeDefinition) && chosenArgs != null && atExprHoverPos(p)
						&& (hoverFound == null || (p.max - p.min) < (hoverFound.p.max - hoverFound.p.min)))
					hoverFound = {t: TFun({args: chosenArgs, ret: t}), p: p};
				switch (c.kind) {
					case KGeneric if (tp.path.tparams.length == 0 && Typeload.canSpecializeGeneric(tl)):
						// Only specialize when every parameter is concrete (no open monomorph and no type
						// parameter): `new Stack<S>()` inside a generic method keeps S abstract and must
						// build a normal instance, else it would specialize on the bare S and lose the
						// field initializers. .
						var gc = Typeload.specializeGenericClass(ctx.com, c, tl, p);
						TypeFunctions.mk(TNew(gc, [], r.el), TInst(gc, []), p);
					case KGeneric:
						// Parameters not inferable from the arguments: an expected type that is already a
						// specialization of this class is used directly. .
						var fromExpected = switch (withType) {
							case WithType(wt, _):
								switch (TypeFunctions.follow(wt)) {
									case TInst(gc2, tl2):
										switch (gc2.kind) {
											// The base compares by path: the macro context types its own copy of
											// the class, so a specialization cached from the other world has a
											// physically different base.
											case KGenericInstance(base, _) if (base == c
													|| (base.path.name == c.path.name && base.path.pack.join(".") == c.path.pack.join("."))):
												TypeFunctions.mk(TNew(gc2, tl2, r.el), TInst(gc2, tl2), p);
											case _: null;
										}
									case _: null;
								}
							case _: null;
						};
						fromExpected != null ? fromExpected : TypeFunctions.mk(TNew(c, tl, r.el), t, p);
					case _:
						TypeFunctions.mk(TNew(c, tl, r.el), t, p);
				}
			case TAbstract(a, atl) if (TypeFunctions.hasMeta(":multiType", a.meta)):
				// A @:multiType abstract (Map) picks a concrete implementation by unifying the key type
				// against each @:to cast's key-parameter constraint, then constructs that type. The
				// expression is typed as the abstract (Map) so it unifies with Map-typed targets; the
				// concrete type is only the constructed runtime value (field access goes through the
				// abstract impl).
				var usedAtl = atl.length == 0 && tp.path.tparams.length == 0
					? [for (_ in a.params) spawnMonomorph(ctx, p)]
					: atl;
				if (tp.path.tparams.length == 0) switch (withType) {
					case WithType(wt, _):
						switch (TypeFunctions.follow(wt)) {
							case TAbstract(wa, wtl) if (wa == a && wtl.length == a.params.length):
								usedAtl = wtl;
							case _:
						}
					case _:
				}
				// An explicitly requested specialization whose selector is still an unresolved mono is
				// rejected. Keep an untyped `new Map()` available for later inference, but report the
				// diagnostic when the expected Map type supplied the open parameter (the generic empty-map
				// case).
				var selector = usedAtl.length > 0 ? TypeFunctions.followWithAbstracts(usedAtl[0]) : TypeFunctions.tDynamic;
				var expectedOpen = switch (withType) {
					case WithType(_, FunctionArgument(_)): true;
					case _: false;
				};
				if (expectedOpen && TypeFunctions.hasMono(selector)) {
					var at = TypeFunctions.applyParams(a.params, usedAtl, a.thisType);
					throw new TypingError("Type parameters of multi type abstracts must be known (for " + hxc.core.TPrinting.sTypeStr(at) + ")", p);
				}
				// Every multiType construction is typed as TNew of the impl; a later filter rewrites it to
				// the @:to cast's static call. Resolving eagerly here would make typing-time inlines (an
				// abstract member called on the fresh construction) see a concrete-typed receiver instead
				// of the abstract.
				if (a.impl != null) {
					var sig = switch (a.impl.statics.get("_new")) {
						case null:
							{args: [], ret: ctx.com.basic.tvoid};
						case newCf:
							TypeFields.forceFieldBody(ctx.com, a.impl, newCf);
							var newType = TypeFunctions.applyParams(a.params, usedAtl, newCf.type);
							switch (TypeFunctions.follow(newType)) {
								case TFun(s): s;
								case _: {args: [], ret: ctx.com.basic.tvoid};
							}
					}
					var r = Calls.unifyCallArgs(ctx, el, sig.args, sig.ret, p);
					return TypeFunctions.mk(TNew(a.impl, usedAtl, r.el), TAbstract(a, usedAtl), p);
				}
				var selection = resolveMultiType(ctx, a, usedAtl, p);
				// The cast call takes the receiver plus the full constructor argument list: TNew is typed
				// against _new (padding omitted optionals with nulls) and the abstract-cast filter appends
				// those args after the null receiver, so the @:to signature (t, ...ctor args) is always
				// saturated.
				var ctorArgs:Array<TExpr> = [];
				if (a.impl != null) switch (a.impl.statics.get("_new")) {
					case null:
					case newCf:
						TypeFields.forceFieldBody(ctx.com, a.impl, newCf);
						switch (TypeFunctions.follow(TypeFunctions.applyParams(a.params, usedAtl, newCf.type))) {
							case TFun(s): ctorArgs = Calls.unifyCallArgs(ctx, el, s.args, s.ret, p).el;
							case _:
						}
				}
				return buildMultiTypeCastCall(ctx, a, usedAtl, selection.castField, selection.castType, selection.ret, ctorArgs, p);
			case TAbstract(a, atl) if (a.impl != null && a.impl.statics.exists("_new")):
				// An abstract is constructed by calling its impl _new static, with the abstract type
				// parameters applied so a generic abstract threads them (a rigid type parameter would
				// otherwise fail to unify against the arguments).
				var newCf = a.impl.statics.get("_new");
				Fields.checkConstructorAccess(ctx, a.impl, newCf, p);
				TypeFields.forceFieldBody(ctx.com, a.impl, newCf);
				var implExpr = TexprTools.makeTypeExpr(TClassDecl(a.impl), p);
				var fa = FieldAccessTools.create(implExpr, newCf, FHAbstract(a, atl, a.impl), false, p);
				Calls.buildCall(ctx, AKField(fa), el, withType, p);
			case TAbstract(a, atl) if (a.impl != null && TypeFunctions.hasMeta(":forward.new", a.meta)):
				// @:forward.new forwards construction to the underlying type: build the underlying value
				// and cast it to the abstract. . Apply the abstract's type arguments so `new
				// Foo<Array<Int>>()` forwards to Array's constructor (not the bare type parameter T) and a
				// `new Foo<Bar>()` / `new Foo<Foo<_>>()` forwards into the underlying abstract's own
				// constructor.
				var enew = constructForwarded(ctx, TypeFunctions.applyParams(a.params, atl, a.thisType), el, withType, p);
				TypeFunctions.mk(TCast(enew, null), TAbstract(a, atl), p);
			case TAbstract(a, _) if (a.impl != null):
				// An abstract with an implementation but no _new constructor cannot be built.
				throw new TypingError(hxc.core.Globals.sTypePath(a.path) + " does not have a constructor", p);
			case _:
				throw new TypingError("This type cannot be constructed", p);
		};
	}

	static function typeMapDeclaration(ctx:TyperContext, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		var mapParams = switch (withType) {
			case WithType(wt, _): getMapParams(ctx, wt);
			case _: null;
		};
		var tkey = mapParams == null ? spawnMonomorph(ctx, p) : mapParams.k;
		var tval = mapParams == null ? spawnMonomorph(ctx, p) : mapParams.v;
		var keys:Array<TExpr> = [];
		var values:Array<TExpr> = [];
		// A repeated constant key is an error.
		var seenKeys:Array<TExpr> = [];
		function checkKey(k:TExpr):Void {
			switch (k.expr) {
				case TConst(c):
					for (prev in seenKeys) if (std.Type.enumEq(prev.expr, k.expr)) {
						// The first message is recorded at the new key, then the sub-message raises at depth 1
						// against the previous key, so a duplicate map key keeps its "previously here" half.
						ctx.com.addDiagnostic("Duplicate key", k.pos);
						throw new TypingError("... Previously defined here", prev.pos, 1);
					}
					seenKeys.push(k);
				case _:
			}
		}
		for (e in el) switch (e.expr) {
			case EBinop(OpArrow, k, v):
				if (mapParams == null) {
					var tk = typeExpr(ctx, k, WithTypeTools.value);
					checkKey(tk);
					keys.push(tk);
					values.push(typeExpr(ctx, v, WithTypeTools.value));
				} else {
					var tk = typeExpr(ctx, k, WithTypeTools.withType(tkey));
					checkKey(tk);
					var tv = typeExpr(ctx, v, WithTypeTools.withType(tval));
					keys.push(castOrUnify(ctx, tkey, tk, tk.pos));
					values.push(castOrUnify(ctx, tval, tv, tv.pos));
				}
			case _:
				// The recovery's stand-in for an entry the user has not written is not a `k => v` pair; it is
				// there so the position has something to complete on, and typing it answers the request rather
				// than rejecting the literal. The key type is what the entry starts with, so the completion is
				// ranked against it rather than against nothing.
				if (atDisplayPos(e.pos))
					typeExpr(ctx, e, mapParams == null ? WithTypeTools.value : WithTypeTools.withType(tkey));
				else throw new TypingError("Expected a => b", e.pos);
		}
		if (mapParams == null) {
			tkey = unifyMinRaise(ctx, keys);
			tval = unifyMinRaise(ctx, values);
		}
		var mt = Typeload.resolveTypePath(ctx.com, {pack: ["haxe", "ds"], name: "Map"}, null, p);
		TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module);
		var a = switch (mt) {
			case TAbstractDecl(ab): ab;
			case _: throw new TypingError("Map is not an abstract", p);
		};
		var impl = a.impl;
		if (impl == null) throw new TypingError("Map has no implementation", p);
		var tmap = TAbstract(a, [tkey, tval]);
		// A bare escape-char gen local (renamed to _g), not a named temp.
		var tmp = TypeFunctions.allocVar(VGenerated, "`", tmap, p);
		var local = TypeFunctions.mk(TLocal(tmp), tmap, p);
		var newMap = TypeFunctions.mk(TNew(impl, [tkey, tval], []), tmap, p);
		var setCf = impl.statics.get("set");
		if (setCf == null) throw new TypingError("Map.set is not available", p);
		var setExpr = TypeFunctions.mk(TField(TexprTools.makeTypeExpr(TClassDecl(impl), p), FStatic(impl, setCf)),
			TFun({args: [{name: "this", opt: false, t: tmap}, {name: "key", opt: false, t: tkey}, {name: "value", opt: false, t: tval}], ret: ctx.com.basic.tvoid}), p);
		var block:Array<TExpr> = [TypeFunctions.mk(TVarExpr(tmp, newMap), ctx.com.basic.tvoid, p)];
		for (i in 0...keys.length)
			block.push(Calls.makeCall(ctx, setExpr, [local, keys[i], values[i]], ctx.com.basic.tvoid, p));
		block.push(local);
		return TypeFunctions.mk(TBlock(block), tmap, p);
	}

	static function getMapParams(ctx:TyperContext, t:T):Null<{k:T, v:T}> {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, [tk, tv]) if (a.path.pack.join(".") == "haxe.ds" && a.path.name == "Map"):
				{k: tk, v: tv};
			case TInst(c, [tv]) if (c.path.pack.join(".") == "haxe.ds" && c.path.name == "StringMap"):
				{k: ctx.com.basic.tstring, v: tv};
			case TInst(c, [tv]) if (c.path.pack.join(".") == "haxe.ds" && c.path.name == "IntMap"):
				{k: ctx.com.basic.tint, v: tv};
			case TInst(c, [tk, tv]) if (c.path.pack.join(".") == "haxe.ds" && (c.path.name == "ObjectMap" || c.path.name == "EnumValueMap")):
				{k: tk, v: tv};
			case _:
				null;
		};
	}

	// Select a @:multiType abstract's concrete implementation: the first @:to cast whose key
	// type-parameter constraint is satisfied by the actual key type, with the concrete return
	// type specialized to the actual type parameters.
	public static function resolveMultiType(ctx:TyperContext, a:TAbstract, atl:Array<T>, p:Position):{castField:TAbstractCast, castType:T, ret:T} {
		var spec = findMultitypeSpecialization(ctx.com, a, atl, p);
		return {castField: spec.castField, castType: applyMultiTypeCastType(a, atl, spec.castField.cf), ret: spec.m};
	}

	public static function resolveMultiTypeConcrete(a:TAbstract, atl:Array<T>, p:Position):T {
		return findMultitypeSpecializationType(a, atl);
	}

	// The @:multiType meta names which type parameters must be known to pick the specialization (each
	// optionally wrapped @:followWithAbstracts); a parameter not named is passed through when closed and
	// degrades to Dynamic while still a monomorph.
	static function findMultitypeParams(a:TAbstract, pl:Array<T>):{tl:Array<T>, definitive:Array<T>} {
		var meta = TypeFunctions.getMeta(":multiType", a.meta);
		if (meta == null || meta.params.length == 0) return {tl: pl, definitive: pl};
		var relevant = new Map<String, T->T>();
		for (e in meta.params) {
			function loop(f:T->T, e:Expr):Void switch (e.expr) {
				case EConst(CIdent(s)): relevant.set(s, f);
				case EMeta(mm, e1) if (mm.name == ":followWithAbstracts"): loop(TypeFunctions.followWithAbstracts, e1);
				case _: throw new TypingError("Type parameter expected", e.pos);
			}
			loop(function(t) return t, e);
		}
		var definitive:Array<T> = [];
		var tl:Array<T> = [for (i in 0...a.params.length) {
			var f = relevant.get(a.params[i].name);
			var t = pl[i];
			if (f != null) { var t2 = f(t); definitive.push(t2); t2; }
			else if (!TypeFunctions.hasMono(t)) t;
			else TypeFunctions.tDynamic;
		}];
		return {tl: tl, definitive: definitive};
	}

	// The specialization arrives as `follow m` whose inner parameters are still monomorphs bound during
	// findTo's unification (StringMap<TMono(:=Int)>). Resolve them through so consumers see the literal
	// parameter types; hxc's inliner and analyzer key some decisions on the syntactic type.
	static function deepFollow(t:T):T {
		return TypeFunctions.map(deepFollow, TypeFunctions.follow(t));
	}

	// findTo unifies for real, and a failed candidate's partial bindings persist (doesFuncUnify does not
	// roll back).
	// Building the abstract forces the impl class, and each cast field's lazy signature resolves while it
	// types - a PERMANENT binding of an unhinted @:to's inferred return. If a rollback undid that binding,
	// the return monomorph would come back open, the next specialization would unify it BACKWARDS onto a
	// fresh monomorph, and every later read of the field would see an unbound type, which cpp lowers to
	// Dynamic. So the bodies are forced up front, outside any rollback.
	static function forceCastFields(a:TAbstract):Void {
		if (TypeUnification.buildAbstractRef != null) TypeUnification.buildAbstractRef(a);
	}

	// The specialization runs without a mono-rollback frame: findTo's partial bindings persist. This
	// wrapper marks where such a frame would go; forceCastFields still runs first, since building the
	// abstract really does force the impl class.
	static function specializeRolledBack<R>(f:Void->R):R {
		return f();
	}

	// Resolve through findTo against a fresh monomorph; raises NotFound (get_underlying_type falls
	// back to thisType on it).
	static function multitypeResult(castField:TAbstractCast, pl:Array<T>, m:T):T {
		var cf = castField.cf;
		if (cf.params.length == pl.length) {
			var t = TypeFunctions.applyParams(cf.params, pl, castField.t);
			// The stored toField type is a monomorph when the @:to has no declared return type. So only keep
			// the caller-node rebuild while it is closed, and otherwise fall back to the reference's result,
			// or cpp lowers the specialization to Dynamic.
			if (!TypeFunctions.hasMono(t)) return t;
		}
		return deepFollow(m);
	}

	public static function findMultitypeSpecializationType(a:TAbstract, pl:Array<T>):T {
		forceCastFields(a);
		return specializeRolledBack(function() {
			var m = TypeFunctions.mkMono();
			var r = findMultitypeParams(a, pl);
			var castField = TypeUnification.findTo(TypeUnification.defaultUnificationContext, m, a, r.tl);
			for (t in r.definitive) if (TypeFunctions.hasMono(t)) throw new NotFound("Typer.hx:6259");
			return multitypeResult(castField, pl, m);
		});
	}

	// The erroring variant used when a multiType construction must specialize, with the js-only Map
	// Class-key rejection.
	public static function findMultitypeSpecialization(com:hxc.context.Context, a:TAbstract, pl:Array<T>, p:Position):{castField:TAbstractCast, m:T} {
		var m = TypeFunctions.mkMono();
		var r = findMultitypeParams(a, pl);
		var tl = r.tl;
		if (com.platform == Js && a.path.pack.length == 2 && a.path.pack[0] == "haxe" && a.path.pack[1] == "ds"
				&& a.path.name == "Map" && tl.length > 0) {
			var t1 = tl[0];
			var stack:Array<T> = [];
			function loop(t:T):T {
				for (t2 in stack) if (TypeUnification.fastEq(t, t2)) return t;
				stack.push(t);
				return switch (TypeFunctions.follow(t)) {
					case TAbstract(ca, _) if (ca.path.pack.length == 0 && ca.path.name == "Class"):
						throw new TypingError("Cannot use " + hxc.core.TPrinting.sTypeStr(t1)
							+ " as key type to Map because Class<T> is not comparable on JavaScript", p);
					case TEnum(en, _):
						for (n in en.constrs.keys()) loop(en.constrs.get(n).type);
						TypeFunctions.map(loop, t);
					case _:
						TypeFunctions.map(loop, t);
				}
			}
			loop(t1);
		}
		forceCastFields(a);
		return specializeRolledBack(function() {
			var castField = try {
				var c = TypeUnification.findTo(TypeUnification.defaultUnificationContext, m, a, tl);
				for (t in r.definitive) if (TypeFunctions.hasMono(t)) {
					var at = TypeFunctions.applyParams(a.params, pl, a.thisType);
					throw new TypingError("Type parameters of multi type abstracts must be known (for "
						+ hxc.core.TPrinting.sTypeStr(at) + ")", p);
				}
				c;
			} catch (_:NotFound) {
				var at = TypeFunctions.applyParams(a.params, pl, a.thisType);
				var st = hxc.core.TPrinting.sTypeStr(at);
				if (TypeFunctions.hasMono(at))
					throw new TypingError("Type parameters of multi type abstracts must be known (for " + st + ")", p);
				throw new TypingError("Abstract " + hxc.core.Globals.sTypePath(a.path) + " has no @:to function that accepts " + st, p);
			}
			return {castField: castField, m: multitypeResult(castField, pl, m)};
		});
	}


	static function applyMultiTypeCastType(a:TAbstract, atl:Array<T>, cf:TClassField):T {
		var t = cf.type;
		if (cf.params.length > 0) {
			// A @:to cast field carries its own constrained parameters (toStringMap<K:String>), and a
			// candidate is only valid when the abstract key type satisfies them. Spawn CONSTRAINED
			// monomorphs so binding enforces the constraint, the same way unifiesToField does.
			// Substituting the abstract type arguments directly, or plain monomorphs, would accept the first
			// cast whose arity matched and pick toStringMap for an object key.
			function mapAbs(x:T):T return a.params.length > 0 ? TypeFunctions.applyParams(a.params, atl, x) : x;
			var params = TypeUnification.spawnConstrainedMonos(mapAbs, cf.params);
			t = TypeFunctions.applyParams(cf.params, params, t);
		}
		if (a.params.length > 0) t = TypeFunctions.applyParams(a.params, atl, t);
		return t;
	}

	static function selectMultiTypeByCtorArgs(ctx:TyperContext, a:TAbstract, atl:Array<T>, el:Array<Expr>, p:Position):Null<{castField:TAbstractCast, castType:T, ret:T, args:Array<TExpr>}> {
		if (el.length == 0) return null;
		var typedArgs = [for (e in el) typeExpr(ctx, e, WithTypeTools.value)];
		function hasOpenParam(t:T):Bool return switch (TypeFunctions.follow(t)) {
			case TMono(_): true;
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))): true;
			case TAbstract(_, tl) | TEnum(_, tl) | TInst(_, tl): [for (x in tl) if (hasOpenParam(x)) true].length > 0;
			case TFun(sig): [for (x in sig.args) if (hasOpenParam(x.t)) true].length > 0 || hasOpenParam(sig.ret);
			case _: false;
		};
		if ([for (e in typedArgs) if (hasOpenParam(e.type)) true].length > 0) return null;
		for (toCast in a.toField) {
			var savedSelectors:Array<{m:TMono, old:Null<T>}> = [for (t in atl) switch (t) { case TMono(m): {m: m, old: m.type}; case _: null; }].filter(function(x) return x != null);
			var found = try TypeUnification.withMonoRollback(function() {
				var castType = applyMultiTypeCastType(a, atl, toCast.cf);
				return switch (TypeFunctions.follow(castType)) {
					case TFun(sig) if (sig.args.length == typedArgs.length + 1):
						var args:Array<TExpr> = [];
						for (i in 0...typedArgs.length) {
							args.push(castOrUnify(ctx, sig.args[i + 1].t, typedArgs[i], typedArgs[i].pos));
						}
						var receiver = TypeFunctions.applyParams(a.params, atl, a.thisType);
						TypeUnification.unifyDefault(receiver, sig.args[0].t);
						{castField: toCast, castType: castType, ret: sig.ret, args: args};
					case _:
						throw new TypingError("No matching multi-type constructor", p);
				}
			}) catch (err:haxe.Exception) null;
			if (found == null) for (s in savedSelectors) switch (s.old) { case null: TypeUnification.unbind(s.m); case old: TypeUnification.monoBind(s.m, old); }
			if (found != null) return found;
		}
		return null;
	}

	public static function buildMultiTypeCastCall(ctx:TyperContext, a:TAbstract, atl:Array<T>, castField:TAbstractCast, castType:T, ret:T, args:Array<TExpr>, p:Position):TExpr {
		if (a.impl == null) throw new TypingError("Cannot construct multi-type abstract " + a.path.name, p);
		var cf = a.impl.statics.exists(castField.cf.name) ? a.impl.statics.get(castField.cf.name) : castField.cf;
		TypeFields.forceFieldBody(ctx.com, a.impl, cf);
		var implExpr = TexprTools.makeTypeExpr(TClassDecl(a.impl), p);
		var fieldExpr = FieldAccessTools.getFieldExpr(FieldAccessTools.create(implExpr, cf, FHStatic(a.impl), false, p), FCall);
		var callee = TypeFunctions.mk(fieldExpr.expr, castType, fieldExpr.pos);
		var receiver = TexprTools.makeNull(TAbstract(a, atl), p);
		var call = Calls.makeCall(ctx, callee, [receiver].concat(args), ret, p);
		return TypeFunctions.mk(call.expr, TAbstract(a, atl), p);
	}


	// A non-Void function body must return, throw, or dead-end on every path; the first path that falls
	// through reports "Missing return: <type>".
	static function returnFlow(ctx:TyperContext, ret:T, e:TExpr):Void {
		inline function error():Void {
			ctx.com.addDiagnostic("Missing return: " + hxc.core.TPrinting.sTypeStr(ret), e.pos);
			throw new ReturnFlowExit();
		}
		switch (e.expr) {
			case TReturn(_) | TThrow(_):
			case TParenthesis(e1) | TMeta(_, e1): returnFlow(ctx, ret, e1);
			case TBlock(el):
				if (el.length == 0) error();
				else {
					var i = 0;
					while (i < el.length) {
						if (i == el.length - 1) { returnFlow(ctx, ret, el[i]); break; }
						if (TexprTools.hasDeadEnd(el[i])) break;
						i++;
					}
				}
			case TIf(_, e1, e2) if (e2 != null):
				returnFlow(ctx, ret, e1);
				returnFlow(ctx, ret, e2);
			case TSwitch(_, cases, edef) if (edef != null):
				for (c in cases) returnFlow(ctx, ret, c.expr);
				returnFlow(ctx, ret, edef);
			case TSwitch({expr: TMeta(m, _)}, cases, null) if (m.name == ":exhaustive"):
				for (c in cases) returnFlow(ctx, ret, c.expr);
			case TTry(e1, catches):
				returnFlow(ctx, ret, e1);
				for (c in catches) returnFlow(ctx, ret, c.expr);
			case TWhile({expr: TConst(TBool(true))}, body, _):
				// An infinite while(true) with no break of its own always returns. A break of a nested loop
				// does not count.
				var broke = false;
				function loop(e2:TExpr):Void {
					if (broke) return;
					switch (e2.expr) {
						case TWhile(_, _, _) | TFor(_, _, _):
						case TBreak: broke = true;
						case _: TexprTools.iter(loop, e2);
					}
				}
				loop(body);
				if (broke) error();
			case _:
				if (!TexprTools.hasDeadEnd(e)) error();
		}
	}

	static function hasReturn(e:TExpr):Bool {
		return switch (e.expr) {
			case TReturn(eo): eo != null;
			case TFunction(_) | TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_): false;
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2): hasReturn(e1) || hasReturn(e2);
			case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TThrow(e1) | TCast(e1, _) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1): hasReturn(e1);
			case TVarExpr(_, eo): eo != null && hasReturn(eo);
			case TObjectDecl(fields): Lambda.exists(fields, f -> hasReturn(f.expr));
			case TArrayDecl(el) | TBlock(el): Lambda.exists(el, hasReturn);
			case TCall(e1, el): hasReturn(e1) || Lambda.exists(el, hasReturn);
			case TNew(_, _, el): Lambda.exists(el, hasReturn);
			case TIf(e1, e2, e3): hasReturn(e1) || hasReturn(e2) || (e3 != null && hasReturn(e3));
			case TWhile(e1, e2, _): hasReturn(e1) || hasReturn(e2);
			case TSwitch(e1, cases, edef): hasReturn(e1) || Lambda.exists(cases, c -> Lambda.exists(c.values, hasReturn) || hasReturn(c.expr)) || (edef != null && hasReturn(edef));
			case TTry(e1, catches): hasReturn(e1) || Lambda.exists(catches, c -> hasReturn(c.expr));
		};
	}

	// Whether evaluating the expression can cause a side effect (assignment, increment, call, allocation,
	// control flow). Object-literal @:structInit field initializers that follow a side-effecting field are
	// hoisted into temp vars so they still evaluate in source order. Conservative (does not model @:pure).
	public static function hasSideEffect(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TIdent(_): false;
			case TNew(_, _, _) | TCall(_, _) | TReturn(_) | TBreak | TContinue | TThrow(_): true;
			case TBinop(OpAssign | OpAssignOp(_), _, _): true;
			case TUnop(Increment | Decrement, _, _): true;
			case TCast(e1, mt): mt != null || hasSideEffect(e1);
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2): hasSideEffect(e1) || hasSideEffect(e2);
			case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1): hasSideEffect(e1);
			case TVarExpr(_, eo): eo != null && hasSideEffect(eo);
			case TObjectDecl(fields): Lambda.exists(fields, f -> hasSideEffect(f.expr));
			case TArrayDecl(el) | TBlock(el): Lambda.exists(el, hasSideEffect);
			case TIf(e1, e2, e3): hasSideEffect(e1) || hasSideEffect(e2) || (e3 != null && hasSideEffect(e3));
			case TWhile(e1, e2, _): hasSideEffect(e1) || hasSideEffect(e2);
			case TSwitch(e1, cases, edef): hasSideEffect(e1) || Lambda.exists(cases, c -> Lambda.exists(c.values, hasSideEffect) || hasSideEffect(c.expr)) || (edef != null && hasSideEffect(edef));
			case TTry(e1, catches): hasSideEffect(e1) || Lambda.exists(catches, c -> hasSideEffect(c.expr));
		};
	}
}

// Object-literal expected-type classification; the struct-init class case is handled separately.
enum ObjectDeclKind {
	ODKPlain;
	ODKFailed;
	ODKStructure(a:TAnon);
	// A Dynamic<T> expectation types every field at T.
	ODKDynamic(t:T);
}

// Unwinds returnFlow once a fall-through path has been reported.
private class ReturnFlowExit extends haxe.Exception {
	public function new() super("return-flow-exit");
}
