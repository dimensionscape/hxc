package hxc.optimization;


import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.typing.TyperContext;
import hxc.optimization.OptimizerTexpr;

class Optimizer {
	// Standard precedence (C++/JS/PHP operator table); left=true means left-associative
	public static function standardPrecedence(op:Binop):{p:Int, left:Bool} {
		return switch (op) {
			case OpIn: {p: 4, left: false};
			case OpMult | OpDiv | OpMod: {p: 5, left: true};
			case OpAdd | OpSub: {p: 6, left: true};
			case OpShl | OpShr | OpUShr: {p: 7, left: true};
			case OpLt | OpLte | OpGt | OpGte: {p: 8, left: true};
			case OpEq | OpNotEq: {p: 9, left: true};
			case OpAnd: {p: 10, left: true};
			case OpXor: {p: 11, left: true};
			case OpOr: {p: 12, left: true};
			case OpInterval: {p: 13, left: false};
			case OpBoolAnd: {p: 14, left: true};
			case OpBoolOr: {p: 15, left: true};
			case OpArrow: {p: 16, left: true};
			case OpNullCoal: {p: 17, left: false};
			case OpAssignOp(OpAssign): {p: 18, left: false}; // Mimics ?:
			case OpAssign | OpAssignOp(_): {p: 19, left: false};
		};
	}

	public static function needParent(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(_) | TLocal(_) | TArray(_, _) | TField(_, _) | TEnumParameter(_, _, _) | TEnumIndex(_) | TParenthesis(_)
				| TCall(_, _) | TNew(_, _, _) | TTypeExpr(_) | TObjectDecl(_) | TArrayDecl(_) | TIdent(_): false;
			case TCast(e1, null) | TMeta(_, e1): needParent(e1);
			case _: true;
		};
	}

	static function followWithAbstractsWithoutNull(t:T):T {
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				followWithAbstractsWithoutNull(TypeFunctions.getUnderlyingType(a, tl));
			case x: x;
		};
	}

	static function isBoolT(t:T):Bool {
		return switch (t) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Bool";
			case _: false;
		};
	}

	public static function sanitizeExpr(com:Context, e:TExpr):TExpr {
		function parent(e:TExpr):TExpr {
			return switch (e.expr) {
				case TParenthesis(_): e;
				case _: TypeFunctions.mk(TParenthesis(e), e.type, e.pos);
			};
		}
		function block(e:TExpr):TExpr {
			return switch (e.expr) {
				case TBlock(_): e;
				case _: TypeFunctions.mk(TBlock([e]), e.type, e.pos);
			};
		}
		// Once printed, these read as several statements and must be blocked
		function complex(e:TExpr):TExpr {
			return switch (e.expr) {
				case TVarExpr(_, _) | TFor(_, _, _): block(e);
				case TCall({expr: TIdent("__js__")}, _): block(e);
				case _: e;
			};
		}
		// The printed expression ends with an if that has no else
		function hasIf(e:TExpr):Bool {
			return switch (e.expr) {
				case TIf(_, _, null): true;
				case TWhile(_, e1, NormalWhile): hasIf(e1);
				case TFor(_, _, e1): hasIf(e1);
				case _: false;
			};
		}
		return switch (e.expr) {
			case TConst(TNull):
				if (com.platformConfig.isStatic && !TypeFunctions.isNullable(e.type)) {
					function loop(t:T):Void {
						switch (TypeFunctions.follow(t)) {
							case TMono(_): // The null will cast to a default value
							case TFun(_): // Flash-specific case
							case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
								loop(TypeFunctions.applyParams(a.params, tl, a.thisType));
							case _:
								com.addDiagnostic("On static platforms, null can't be used as basic type " + hxc.core.TPrinting.sTypeStr(e.type), e.pos);
						}
					}
					loop(e.type);
				}
				e;
			case TBinop(op, e1, e2):
				function swap(op1:Binop, op2:Binop):Bool {
					var r1 = standardPrecedence(op1);
					var r2 = standardPrecedence(op2);
					return r1.left && r1.p <= r2.p;
				}
				function loop(ee:TExpr, left:Bool):Bool {
					return switch (ee.expr) {
						case TBinop(op2, _, _): left ? !swap(op2, op) : swap(op, op2);
						case TIf(_, _, _): left ? !swap(OpAssignOp(OpAssign), op) : swap(op, OpAssignOp(OpAssign));
						case TCast(e1, null) | TMeta(_, e1): loop(e1, left);
						case TConst(TInt(i)) if (!left):
							switch (op) {
								case OpAdd | OpSub: i < 0;
								case _: false;
							}
						case TConst(TFloat(flt)) if (!left):
							switch (op) {
								case OpAdd | OpSub: flt.charAt(0) == "-";
								case _: false;
							}
						case _: false;
					};
				}
				var e1 = loop(e1, true) ? parent(e1) : e1;
				var e2 = loop(e2, false) ? parent(e2) : e2;
				TypeFunctions.mk(TBinop(op, e1, e2), e.type, e.pos);
			case TUnop(Not, Prefix, {expr: TUnop(Not, Prefix, e1)})
				| TUnop(Not, Prefix, {expr: TParenthesis({expr: TUnop(Not, Prefix, e1)})})
				if (isBoolT(followWithAbstractsWithoutNull(e1.type))):
				e1;
			case TUnop(op, mode, e1):
				function loop(ee:TExpr):TExpr {
					return switch (ee.expr) {
						case TConst(TInt(i)) if (op.match(Neg) && i < 0): parent(e1);
						case TConst(TFloat(flt)) if (op.match(Neg) && flt.charAt(0) == "-"): parent(e1);
						case TBinop(_, _, _) | TIf(_, _, _) | TUnop(_, _, _): parent(e1);
						case TCast(x, null) | TMeta(_, x): loop(x);
						case _: e1;
					};
				}
				TypeFunctions.mk(TUnop(op, mode, loop(e1)), e.type, e.pos);
			case TIf(e1, e2, eelse):
				var e1 = parent(e1);
				var e2 = if ((eelse != null && hasIf(e2)) || e2.expr.match(TIf(_, _, _))) block(e2) else complex(e2);
				var eelse = eelse == null ? null : complex(eelse);
				TypeFunctions.mk(TIf(e1, e2, eelse), e.type, e.pos);
			case TWhile(e1, e2, flag):
				TypeFunctions.mk(TWhile(parent(e1), complex(e2), flag), e.type, e.pos);
			case TFor(v, e1, e2):
				TypeFunctions.mk(TFor(v, e1, complex(e2)), e.type, e.pos);
			case TFunction(f):
				var f2 = switch (f.expr.expr) {
					case TBlock(exprs):
						// Drop a trailing bare `return` from a Void function body
						if (isVoidT(TypeFunctions.follow(f.type)) && exprs.length > 0 && exprs[exprs.length - 1].expr.match(TReturn(null)))
							new TFunc(f.args, f.type, TypeFunctions.mk(TBlock(exprs.slice(0, exprs.length - 1)), f.expr.type, f.expr.pos));
						else f;
					case _:
						new TFunc(f.args, f.type, block(f.expr));
				}
				TypeFunctions.mk(TFunction(f2), e.type, e.pos);
			case TCall(e2, args):
				if (needParent(e2)) TypeFunctions.mk(TCall(parent(e2), args), e.type, e.pos) else e;
			case TEnumParameter(e2, ef, i):
				if (needParent(e2)) TypeFunctions.mk(TEnumParameter(parent(e2), ef, i), e.type, e.pos) else e;
			case TEnumIndex(e2):
				if (needParent(e2)) TypeFunctions.mk(TEnumIndex(parent(e2)), e.type, e.pos) else e;
			case TField(e2, f):
				if (needParent(e2)) TypeFunctions.mk(TField(parent(e2), f), e.type, e.pos) else e;
			case TArray(e1, e2):
				if (needParent(e1)) TypeFunctions.mk(TArray(parent(e1), e2), e.type, e.pos) else e;
			case TTry(e1, catches):
				TypeFunctions.mk(TTry(block(e1), [for (c in catches) {v: c.v, expr: block(c.expr)}]), e.type, e.pos);
			case TSwitch(e1, cases, def):
				var cases = [for (c in cases) {values: c.values, expr: complex(c.expr)}];
				TypeFunctions.mk(TSwitch(parent(e1), cases, def == null ? null : complex(def)), e.type, e.pos);
			case _:
				e;
		};
	}

	static function isVoidT(t:T):Bool {
		return switch (t) {
			case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	public static function reduceExpr(ctx:TyperContext, e:TExpr):TExpr {
		return switch (e.expr) {
			case TSwitch(_, cases, _):
				for (c in cases) for (v in c.values) switch (v.expr) {
					case TCall({expr: TField(_, FEnum(_, _))}, _):
						throw new TypingError("Not-constant enum in switch cannot be matched", v.pos);
					case _:
				}
				e;
			case TBlock(l):
				if (l.length == 0) e
				else {
					var ec = l[l.length - 1];
					// Remove no-ops: not-final constants in blocks
					var rest = [for (i in 0...l.length - 1) l[i]];
					var filtered = [for (x in rest) if (!switch (x.expr) {
						case TConst(_) | TBlock([]) | TObjectDecl([]): true;
						case _: false;
					}) x];
					if (filtered.length == 0) ec
					else {
						filtered.push(ec);
						TypeFunctions.mk(TBlock(filtered), e.type, e.pos);
					}
				}
			case TParenthesis(ec):
				TypeFunctions.mk(ec.expr, ec.type, e.pos);
			case TTry(e1, []):
				e1;
			case _:
				e;
		};
	}

	public static function sanitize(com:Context, tctx:TyperContext, e:TExpr):TExpr {
		return sanitizeExpr(com, reduceExpr(tctx, TexprTools.mapExpr(function(x) return sanitize(com, tctx, x), e)));
	}

	static function checkEnumConstructionArgs(el:Array<TExpr>, i:Int):Bool {
		var b = true;
		for (idx in 0...el.length) {
			if (idx != i && OptimizerTexpr.hasSideEffect(el[idx])) {
				b = false;
				break;
			}
		}
		return b;
	}

	static function extractConstantValue(e:TExpr):Null<TExpr> {
		return switch (e.expr) {
			case TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_) | TNull): e;
			case TConst(TThis | TSuper): null;
			case TField(_, FStatic(_, cf)) if (switch (cf.kind) {
				case Var(k): k.write.match(AccNever);
				case _: false;
			}):
				cf.expr == null ? null : extractConstantValue(cf.expr);
			case TField(_, FEnum(_, _)): e;
			case TParenthesis(e1): extractConstantValue(e1);
			case _: null;
		};
	}

	public static function checkConstantSwitch(e1:TExpr, cases:Array<TSwitchCase>, def:Null<TExpr>):Null<TExpr> {
		function isEmpty(e:TExpr):Bool return e.expr.match(TBlock([]));
		var subject = TexprTools.skip(e1);
		switch (subject.expr) {
			case TConst(ct) if (!ct.match(TSuper) && !ct.match(TThis)):
				for (c in cases) {
					var el = [];
					for (e2 in c.values) {
						var v = extractConstantValue(e2);
						if (v == null) return null; // Unknown value: leave the switch alone
						el.push(v);
					}
					for (e2 in el) if (TexprTools.equal(subject, e2)) return c.expr;
				}
				return def;
			case _:
				var allEmpty = def == null || isEmpty(def);
				if (allEmpty) for (c in cases) if (!isEmpty(c.expr)) { allEmpty = false; break; }
				return allEmpty ? subject : null;
		}
	}

	public static function reduceControlFlow(com:Context, e:TExpr):TExpr {
		return switch (e.expr) {
			case TIf({expr: TConst(TBool(t))}, e1, e2):
				if (t) e1 else (e2 == null ? TypeFunctions.mk(TBlock([]), e.type, e.pos) : e2);
			case TWhile({expr: TConst(TBool(false))}, _, flag):
				switch (flag) {
					case NormalWhile: TypeFunctions.mk(TBlock([]), e.type, e.pos); // Erase sub
					case DoWhile: e; // Sub may contain continue/break
				}
			case TSwitch(e1, cases, def):
				var r = checkConstantSwitch(e1, cases, def);
				r == null ? e : r;
			case TBinop(op, e1, e2):
				OptimizerTexpr.optimizeBinop(e, op, e1, e2);
			case TUnop(op, flag, esub):
				OptimizerTexpr.optimizeUnop(e, op, flag, esub);
			case TCall(f = {expr: TField(o, FClosure(c, cf))}, el):
				var fmode:TFieldAccess = c == null ? FAnon(cf) : FInstance(c.c, c.params, cf);
				TypeFunctions.mk(TCall(TypeFunctions.mk(TField(o, fmode), f.type, f.pos), el), e.type, e.pos);
			case TEnumParameter({expr: TCall({expr: TField(_, FEnum(_, ef1))}, el)}, ef2, i)
				| TEnumParameter({expr: TParenthesis({expr: TCall({expr: TField(_, FEnum(_, ef1))}, el)})}, ef2, i)
				if (ef1 == ef2 && checkEnumConstructionArgs(el, i)):
				i < el.length ? el[i] : e;
			case TCast(_, null):
				// requireCast is target-specific: cpp/flash always keep the reification cast so a
				// monomorph-typed value is materialized to its static type.
				var requireCast = switch (com.platform) {
					case Cpp | Flash: true;
					case Java: com.defines.rawDefined("jvm");
					case Cs: com.defines.rawDefined("erase_generics") || com.defines.rawDefined("fast_cast");
					case _: false;
				};
				TexprTools.reduceUnsafeCasts(e, e.type, requireCast);
			case _:
				e;
		};
	}

	// Recursion stack for the inline guard
	static var inlineStack:Array<TClassField> = [];

	static function recStackDefault<A>(value:TClassField, fn:Void->A, def:A):A {
		for (v in inlineStack) if (v == value) return def;
		inlineStack.push(value);
		var r = try fn() catch (err:Dynamic) {
			inlineStack.pop();
			throw err;
		}
		inlineStack.pop();
		return r;
	}

	static function stackHas(cf:TClassField):Bool {
		for (v in inlineStack) if (v == cf) return true;
		return false;
	}

	static function reduceLoop(ctx:TyperContext, e:TExpr):TExpr {
		var e = TexprTools.mapExpr(function(x) return reduceLoop(ctx, x), e);
		return sanitizeExpr(ctx.com, switch (e.expr) {
			case TCall(e1, el):
				switch (TexprTools.skip(e1).expr) {
					case TFunction(fn) if (e1.expr.match(TMeta({name: ":loopCapture"}, _))):
						// The eval loop-capture wrapper must keep its own frame per iteration;
						// it is not an inline candidate (see ForLoop.wrapLoopVarsBody).
						reduceExpr(ctx, e);
					case TFunction(fn):
						// An immediately-called closure inlines against a synthetic field and a this receiver, so
						// `(f)(x)` folds to the function body with x bound.
						var ef = TexprTools.skip(e1);
						var rt = switch (TypeFunctions.follow(ef.type)) { case TFun(sig): sig.ret; case _: e.type; };
						var cf = TypeFunctions.mkField("", ef.type, e.pos, e.pos);
						var ethis = TypeFunctions.mk(TConst(TThis), TypeFunctions.tDynamic, e.pos);
						var inl = try hxc.typing.Inline.typeInline(ctx, null, cf, fn, ethis, el, rt, e.pos, true) catch (_:Dynamic) null;
						if (inl == null) reduceExpr(ctx, e) else reduceLoop(ctx, inl);
					case TField(_, FStatic(_, cf) | FInstance(_, _, cf)) if (cf.kind.match(Method(MethInline)) && !stackHas(cf)):
						var inl = hxc.typing.Inline.tryInline(ctx, TexprTools.skip(e1), el, e.type, e.pos, false, false);
						if (inl == null) reduceExpr(ctx, e)
						else recStackDefault(cf, function() return reduceLoop(ctx, inl), inl);
					case TField({expr: TTypeExpr(TClassDecl(c))}, field):
						var r = apiInline(ctx, c, TypeFunctions.fieldName(field), el, e.pos);
						if (r == null) reduceExpr(ctx, e) else reduceLoop(ctx, r);
					case _:
						reduceExpr(ctx, e);
				}
			case _:
				reduceExpr(ctx, reduceControlFlow(ctx.com, e));
		});
	}

	public static function reduceExpression(ctx:TyperContext, e:TExpr):TExpr {
		if (!ctx.com.foptimize) return e;
		// Keep the current field on the stack so self-recursive inlining stops (#7569)
		return recStackDefault(ctx.curfield, function() return reduceLoop(ctx, e), e);
	}

	public static function makeConstantExpression(ctx:TyperContext, e:TExpr, concatStrings:Bool = false):Null<TExpr> {
		var e = reduceLoop(ctx, e);
		return switch (e.expr) {
			case TConst(_): e;
			case TField({expr: TTypeExpr(_)}, FEnum(_, _)): e;
			case TBinop(op = OpAdd | OpSub | OpMult | OpDiv | OpMod | OpShl | OpShr | OpUShr | OpOr | OpAnd | OpXor, e1, e2):
				var c1 = makeConstantExpression(ctx, e1);
				var c2 = makeConstantExpression(ctx, e2);
				switch [c1, c2] {
					case [{expr: TConst(TString(s1))}, {expr: TConst(TString(s2))}] if (concatStrings):
						TypeFunctions.mk(TConst(TString(s1 + s2)), ctx.com.basic.tstring, Position.union(e1.pos, e2.pos));
					case [x1, x2] if (x1 != null && x2 != null):
						TypeFunctions.mk(TBinop(op, x1, x2), e.type, e.pos);
					case _: null;
				}
			case TUnop(op = Neg | NegBits, Prefix, e1):
				var c1 = makeConstantExpression(ctx, e1);
				c1 == null ? null : TypeFunctions.mk(TUnop(op, Prefix, c1), e.type, e.pos);
			case TCast(e1, null):
				var c1 = makeConstantExpression(ctx, e1);
				c1 == null ? null : TypeFunctions.mk(TCast(c1, null), e.type, e.pos);
			case TParenthesis(e1):
				var c1 = makeConstantExpression(ctx, e1, concatStrings);
				c1 == null ? null : TypeFunctions.mk(TParenthesis(c1), e.type, e.pos);
			case TMeta(m, e1):
				var c1 = makeConstantExpression(ctx, e1, concatStrings);
				c1 == null ? null : TypeFunctions.mk(TMeta(m, c1), e.type, e.pos);
			case TTypeExpr(_): e;
			case _: null;
		};
	}

	// The js and platform-neutral arms; cs/java arms omitted, those targets are out of scope
	public static function apiInline(ctx:TyperContext, c:TClass, field:String, params:Array<TExpr>, p:Position):Null<TExpr> {
		var com = ctx.com;
		function mkTypeexpr(path:Path):TExpr {
			var m = com.moduleLut.get(Context.pathKey(path));
			if (m == null) throw new TypingError("Type not loaded: " + Context.sTypePath(path), p);
			for (mt in m.types) switch (mt) {
				case TClassDecl(cl) if (cl.path.name == path.name && cl.path.pack.join(".") == path.pack.join(".")):
					return TexprTools.makeStaticThis(cl, p);
				case _:
			}
			throw new TypingError("Type not found: " + Context.sTypePath(path), p);
		}
		var tstring = com.basic.tstring;
		var tbool = com.basic.tbool;
		var tint = com.basic.tint;
		var isJs = com.platform == Js;
		var pathKey = Context.pathKey(c.path);
		if (isJs && (pathKey == "Std" && (field == "is" || field == "isOfType") || pathKey == "js.Boot" && field == "__instanceof") && params.length == 2) {
			var o = params[0];
			var t = params[1];
			function isTrivial(e:TExpr):Bool return e.expr.match(TConst(_)) || e.expr.match(TLocal(_));
			function typeofCheck(name:String):TExpr {
				var tof = TexprTools.fcall(mkTypeexpr({pack: ["js"], name: "Syntax"}), "typeof", [o], tstring, p);
				return TypeFunctions.mk(TBinop(OpEq, tof, TypeFunctions.mk(TConst(TString(name)), tstring, p)), tbool, p);
			}
			function skipCast(e:TExpr):TExpr {
				return switch (e.expr) {
					case TCast(x, null): skipCast(x);
					case _: e;
				};
			}
			return switch (skipCast(t).expr) {
				case TTypeExpr(TClassDecl({path: {pack: [], name: "String"}})): typeofCheck("string");
				case TTypeExpr(TAbstractDecl(a)) if (a.path.pack.length == 0 && a.path.name == "Bool"): typeofCheck("boolean");
				case TTypeExpr(TAbstractDecl(a)) if (a.path.pack.length == 0 && a.path.name == "Float"): typeofCheck("number");
				case TTypeExpr(TAbstractDecl(a)) if (a.path.pack.length == 0 && a.path.name == "Int" && isTrivial(o)):
					// Typeof(o) == "number" && (o|0) === o
					var lhs = TypeFunctions.mk(TBinop(OpOr, o, TypeFunctions.mk(TConst(TInt(0)), tint, p)), tint, p);
					var jscheck = TexprTools.fcall(mkTypeexpr({pack: ["js"], name: "Syntax"}), "strictEq", [lhs, o], tbool, p);
					TypeFunctions.mk(TBinop(OpBoolAnd, typeofCheck("number"), jscheck), tbool, p);
				case TTypeExpr(TClassDecl({path: {pack: [], name: "Array"}})):
					var iof = TexprTools.fcall(mkTypeexpr({pack: ["js"], name: "Syntax"}), "instanceof", [o, t], tbool, p);
					if (!com.defines.rawDefined("js_enums_as_arrays")) iof
					else {
						var en = TypeFunctions.mk(TField(o, FDynamic("__enum__")), TypeFunctions.tDynamic, p);
						var nul = TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, p);
						var notEnum = TypeFunctions.mk(TBinop(OpEq, en, nul), tbool, p);
						TypeFunctions.mk(TBinop(OpBoolAnd, iof, notEnum), tbool, p);
					}
				case TTypeExpr(TClassDecl(cls)):
					if (TypeFunctions.hasClassFlag(cls, CInterface))
						TexprTools.fcall(mkTypeexpr({pack: ["js"], name: "Boot"}), "__implements", [o, t], tbool, p);
					else
						TexprTools.fcall(mkTypeexpr({pack: ["js"], name: "Syntax"}), "instanceof", [o, t], tbool, p);
				case _:
					null;
			};
		}
		if (isJs && pathKey == "js.Boot" && field == "__downcastCheck" && params.length == 2) {
			switch (params[1].expr) {
				case TTypeExpr(TClassDecl(cls)):
					if (TypeFunctions.hasClassFlag(cls, CInterface))
						return TexprTools.fcall(TexprTools.makeStaticThis(c, p), "__implements", [params[0], params[1]], tbool, p);
					else
						return TexprTools.fcall(mkTypeexpr({pack: ["js"], name: "Syntax"}), "instanceof", [params[0], params[1]], tbool, p);
				case _:
			}
		}
		return apiInline2(com, c, field, params, p);
	}

	// Platform-neutral arms; the cs/java-only arms are omitted
	public static function apiInline2(com:Context, c:TClass, field:String, params:Array<TExpr>, p:Position):Null<TExpr> {
		var pathKey = Context.pathKey(c.path);
		inline function intConst(i:Int):TExpr return TypeFunctions.mk(TConst(TInt(i)), com.basic.tint, p);
		return switch [pathKey, field, params] {
			case ["Type", "enumIndex", [{expr: TField(_, FEnum(_, f))}]]:
				intConst(f.index);
			case ["Type", "enumIndex", [{expr: TCall({expr: TField(_, FEnum(_, f))}, pl)}]]:
				var pure = true;
				for (x in pl) if (OptimizerTexpr.hasSideEffect(x)) { pure = false; break; }
				pure ? intConst(f.index) : null;
			case ["Std", "int", [x = {expr: TConst(TInt(_))}]]:
				TypeFunctions.mk(x.expr, x.type, p);
			case ["String", "fromCharCode", [{expr: TConst(TInt(i))}]] if (i > 0 && i < 128):
				TypeFunctions.mk(TConst(TString(String.fromCharCode(i))), com.basic.tstring, p);
			case ["Std", "string", [{expr: TCast(x = {expr: TConst(ct)}, null)}]] | ["Std", "string", [x = {expr: TConst(ct)}]]:
				switch (ct) {
					case TString(_): TypeFunctions.mk(x.expr, x.type, p);
					case TInt(i): TypeFunctions.mk(TConst(TString(Std.string(i))), com.basic.tstring, p);
					case TBool(b): TypeFunctions.mk(TConst(TString(b ? "true" : "false")), com.basic.tstring, p);
					case _: null;
				}
			case ["Std", "string", [x = {expr: TIf(_, {expr: TConst(TString(_))}, {expr: TConst(TString(_))})}]]:
				x;
			case ["Std", "string", [ev = {expr: TLocal(v) | TField({expr: TLocal(v)}, _)}]]
				if (com.platform == Js && v.kind.match(VUser(_))):
				var pos = ev.pos;
				function stringv():TExpr {
					var toStr = TypeFunctions.mk(TBinop(OpAdd, TypeFunctions.mk(TConst(TString("")), com.basic.tstring, pos), ev), com.basic.tstring, pos);
					// Js always null-checks here
					var chkNull = TypeFunctions.mk(TBinop(OpEq, ev, TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, pos)), com.basic.tbool, pos);
					return TypeFunctions.mk(TIf(chkNull, TypeFunctions.mk(TConst(TString("null")), com.basic.tstring, pos), toStr), com.basic.tstring, pos);
				}
				switch (TypeFunctions.follow(ev.type)) {
					case TInst({path: {pack: [], name: "String"}}, []): stringv();
					case TAbstract(a, []) if (a.path.pack.length == 0 && (a.path.name == "Float" || a.path.name == "Int" || a.path.name == "UInt" || a.path.name == "Bool")): stringv();
					case _: null;
				}
			case ["Std", "int", [{expr: TConst(TFloat(fs))}]]:
				var f = hxc.core.Numeric.parseFloatLit(fs);
				if (Math.isNaN(f) || !Math.isFinite(f)) null;
				else if (f <= -2147483648.0 - 1.0 || f >= 2147483647.0 + 1.0) null; // Out of range
				else intConst(Std.int(f));
			case ["Math", "ceil", [{expr: TConst(TFloat(fs))}]]:
				var f = hxc.core.Numeric.parseFloatLit(fs);
				if (Math.isNaN(f) || !Math.isFinite(f)) null;
				else if (f <= -2147483648.0 - 1.0 || f >= 2147483647.0) null;
				else intConst(Std.int(Math.fceil(f)));
			case ["Math", "floor", [{expr: TConst(TFloat(fs))}]]:
				var f = hxc.core.Numeric.parseFloatLit(fs);
				if (Math.isNaN(f) || !Math.isFinite(f)) null;
				else if (f <= -2147483648.0 || f >= 2147483647.0 + 1.0) null;
				else intConst(Std.int(Math.ffloor(f)));
			case _:
				null;
		};
	}
}
