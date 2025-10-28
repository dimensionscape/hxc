package hxc.core;

import haxe.ds.StringMap;
import hxc.ast.Ast;                 
import hxc.core.TypeUnification.Meta;
import hxc.core.Type;
import hxc.core.Type.T;
import hxc.core.Type.TMono;
import hxc.core.Type.TMonoConstraintKind;
import hxc.core.Type.AnonStatus;
import hxc.core.Type.FieldKind;
import hxc.core.Type.VarAccess;
import hxc.core.Type.MethodKind;
import hxc.core.TypeUnification.UnifyErrorKind;
import hxc.core.Globals.Path;

// Type and typed-expression printers. sType renders a type as a string with Unknown<N> numbering for
// unbound monomorphs; it backs $type, -D dump, and unify-error messages. sExpr prints a typed expression
// tree.
class TPrinting {
	// A fresh print context. Physical-keyed on the TMono node so repeated monos render the same Unknown<N>.
	public static function printContext():Ref<Array<{m:TMono, id:Int}>> {
		return new Ref([]);
	}

	// Structural debug label
	public static function sTypeKind(t:T):String {
		inline function map(tl:Array<T>):String return tl.map(sTypeKind).join(", ");
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null: "TMono (None)";
					case some: "TMono (Some (" + sTypeKind(some) + "))";
				}
			case TEnum(en, tl): 'TEnum(${Globals.sTypePath(en.path)}, [${map(tl)}])';
			case TInst(c, tl): 'TInst(${Globals.sTypePath(c.path)}, [${map(tl)}])';
			case TType(d, tl): 'TType(${Globals.sTypePath(d.path)}, [${map(tl)}])';
			case TAbstract(a, tl): 'TAbstract(${Globals.sTypePath(a.path)}, [${map(tl)}])';
			case TFun(sig):
				var args = sig.args.map(function(a) return (a.opt ? "?" : "") + a.name + ":" + sTypeKind(a.t)).join(", ");
				'TFun([$args], ${sTypeKind(sig.ret)})';
			case TAnon(_): "TAnon";
			case TDynamic(_): "TDynamic";
			case TLazy(_): "TLazy";
		}
	}

	// Canonical type string with Unknown<N> mono numbering
	public static function sType(ctx:Ref<Array<{m:TMono, id:Int}>>, t:T):String {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null:
						var found:Null<Int> = null;
						for (e in ctx.get()) if (e.m == r) { found = e.id; break; }
						if (found != null) {
							'Unknown<$found>';
						} else {
							var id = ctx.get().length;
							ctx.get().unshift({m: r, id: id});
							// Classify + render down-constraints
							function loop(k:TMonoConstraintKind):String {
								return switch (k) {
									case CUnknown: "";
									case CTypes(tl): tl.map(function(uc) return sType(ctx, uc.t)).join(" & ");
									case CStructural(fields, _): sType(ctx, TypeFunctions.mkAnon(new Ref(AnonStatus.Closed), fields));
									case CMixed(l): l.map(loop).join(" & ");
								}
							}
							var s = loop(TypeFunctions.monomorphClassifyConstraintsRef(r));
							'Unknown<$id>' + (s == "" ? "" : " : " + s);
						}
					case some: sType(ctx, some);
				}
			case TEnum(e, tl):
				Globals.sTypePath(e.path) + sTypeParams(ctx, tl);
			case TInst(c, tl):
				switch (c.kind) {
					case KExpr(e): Printer.sExpr(e);
					case _: Globals.sTypePath(c.path) + sTypeParams(ctx, tl);
				}
			case TType(d, tl):
				// Abstract<...> when the typedef aliases an abstract-impl statics anon
				var abstractHead = switch (d.type) {
					case TAnon(an): switch (an.status.get()) {
						case Statics(sc): switch (sc.kind) {
							case KAbstractImpl(a): "Abstract<" + Globals.sTypePath(a.path) + ">";
							case _: null;
						}
						case _: null;
					}
					case _: null;
				}
				abstractHead != null ? abstractHead : Globals.sTypePath(d.path) + sTypeParams(ctx, tl);
			case TAbstract(a, tl):
				Globals.sTypePath(a.path) + sTypeParams(ctx, tl);
			case TFun(sig):
				var args = switch (sig.args) {
					case []: "()";
					case [a] if (a.name == ""): (a.opt ? "?" : "") + sFun(ctx, a.t, true);
					case l:
						"(" + l.map(function(a) return (a.opt ? "?" : "") + (a.name == "" ? "" : a.name + " : ") + sFun(ctx, a.t, true)).join(", ") + ")";
				}
				'$args -> ${sFun(ctx, sig.ret, false)}';
			case TAnon(a):
				switch (a.status.get()) {
					case Statics(c): "Class<" + Globals.sTypePath(c.path) + ">";
					case EnumStatics(e): "Enum<" + Globals.sTypePath(e.path) + ">";
					case AbstractStatics(ab): "Abstract<" + Globals.sTypePath(ab.path) + ">";
					case _:
						// The fields render in descending name order.
						var names = [for (k in a.fields.keys()) k];
						names.sort(function(x, y) return x < y ? 1 : (x > y ? -1 : 0));
						var fl = names.map(function(n) {
							var f = a.fields.get(n);
							return (TypeFunctions.hasMeta(Meta.Optional, f.meta) ? " ?" : " ") + f.name + " : " + sType(ctx, f.type);
						});
						"{" + fl.join(",") + " }";
				}
			case TDynamic(null): "Dynamic";
			case TDynamic(t2): "Dynamic" + sTypeParams(ctx, [t2]);
			case TLazy(f): sType(ctx, TypeFunctions.lazyType(f));
		}
	}

	// Parenthesize function/void args in signature position.
	static function sFun(ctx:Ref<Array<{m:TMono, id:Int}>>, t:T, void:Bool):String {
		return switch (t) {
			case TFun(_): "(" + sType(ctx, t) + ")";
			case TAbstract(a, []) if (void && a.path.pack.length == 0 && a.path.name == "Void"):
				"(" + sType(ctx, t) + ")";
			case TMono(r):
				switch (r.type) { case null: sType(ctx, t); case some: sFun(ctx, some, void); }
			case TLazy(f): sFun(ctx, TypeFunctions.lazyType(f), void);
			case _: sType(ctx, t);
		}
	}

	// When set, sType renders type parameters as "<...>". Used only for the have/want leaf types of a
	// structured unify error; the inner "X should be Y" and every other caller keep the full parameters.
	static var shortParams:Bool = false;

	static function sTypeParams(ctx:Ref<Array<{m:TMono, id:Int}>>, tl:Array<T>):String {
		if (tl.length == 0) return "";
		if (shortParams) return "<" + [for (_ in tl) "..."].join(", ") + ">";
		return "<" + tl.map(function(t) return sType(ctx, t)).join(", ") + ">";
	}

	public static inline function sTypeStr(t:T):String {
		return sType(printContext(), t);
	}

	// A list of types sharing one print context so their Unknown<N> numbering stays consistent across the
	// list.
	public static function sTypes(tl:Array<T>, sep:String = ", "):String {
		var pc = printContext();
		return [for (t in tl) sType(pc, t)].join(sep);
	}

	// Cannot-unify message: both types share one print context.
	public static function unifyErrorMsg(t1:T, t2:T):String {
		var pc = printContext();
		return sType(pc, t1) + " should be " + sType(pc, t2);
	}

	static function shortType(ctx:Ref<Array<{m:TMono, id:Int}>>, t:T):String {
		var s = sType(ctx, t);
		return s.length > 150 ? s.substr(0, 147) + "..." : s;
	}

	static function sAccessK(isRead:Bool, a:VarAccess):String {
		return switch (a) {
			case AccNormal: "default";
			case AccNo: "null";
			case AccNever: "never";
			case AccCall: isRead ? "get" : "set";
			case AccInline: "inline";
			case AccRequire(n, _): "require " + n;
			case AccCtor: "ctor";
		}
	}

	public static function sKind(k:FieldKind):String {
		return switch (k) {
			case Var(v) if (v.read == AccNormal && v.write == AccNormal): "var";
			case Var(v): "(" + sAccessK(true, v.read) + "," + sAccessK(false, v.write) + ")";
			case Method(m): switch (m) {
				case MethNormal: "method";
				case MethDynamic: "dynamic method";
				case MethInline: "inline method";
				case MethMacro: "macro method";
			}
		}
	}

	static function unifyErrorMsgOne(ctx:Ref<Array<{m:TMono, id:Int}>>, err:UnifyErrorKind):String {
		return switch (err) {
			case Cannot_unify(t1, t2): sType(ctx, t1) + " should be " + sType(ctx, t2);
			case Invalid_field_type(s): "Invalid type for field " + s + " :";
			case Has_no_field(t, n): shortType(ctx, t) + " has no field " + n;
			case Has_no_runtime_field(t, n): sType(ctx, t) + "." + n + " is not accessible at runtime";
			case Has_extra_field(t, n): shortType(ctx, t) + " has extra field " + n;
			case Invalid_kind(f, a, b):
				switch [a, b] {
					case [Var(va), Var(vb)]:
						var name, stra, strb;
						if (va.read == vb.read) { name = "setter"; stra = sAccessK(false, va.write); strb = sAccessK(false, vb.write); }
						else if (va.write == vb.write) { name = "getter"; stra = sAccessK(true, va.read); strb = sAccessK(true, vb.read); }
						else { name = "access"; stra = "(" + sAccessK(true, va.read) + "," + sAccessK(false, va.write) + ")"; strb = "(" + sAccessK(true, vb.read) + "," + sAccessK(false, vb.write) + ")"; }
						"Inconsistent " + name + " for field " + f + " : " + stra + " should be " + strb;
					case _: "Field " + f + " is " + sKind(a) + " but should be " + sKind(b);
				}
			case Invalid_visibility(n): "The field " + n + " is not public";
			case Not_matching_optional(n): "Optional attribute of parameter " + n + " differs";
			case Cant_force_optional: "Optional parameters can't be forced";
			case Invariant_parameter(_): "Type parameters are invariant";
			case Constraint_failure(name): "Constraint check failure for " + name;
			case Missing_overload(cf, t): cf.name + " has no overload for " + sType(ctx, t);
			case FinalInvariance: "Cannot unify final and non-final fields";
			case Invalid_function_argument(i, _): "Cannot unify argument " + i;
			case Invalid_return_type: "Cannot unify return types";
			case Unify_custom(msg): msg;
		}
	}

	// Turn a unify-error list into either a simple "X should be Y" or, when the mismatch is nested in a
	// field/argument/return/type-parameter, the "error: <cause>\nhave: <actual>\nwant: <expected>" form
	// (the have/want lines are rendered as message continuations by the formatters).
	// The chain terminal prints anon fields as names only (optional marked ?), function arguments elided,
	// and type parameters as <...>; unbound monomorphs share the outer print context numbering.
	static function beShallowType(ctx:Ref<Array<{m:TMono, id:Int}>>, t:T):String {
		return switch (t) {
			case TMono(r): switch (r.type) { case null: sType(ctx, t); case some: beShallowType(ctx, some); };
			case TEnum(e, tl): Globals.sTypePath(e.path) + beShallowParams(tl);
			case TInst(c, tl): switch (c.kind) {
				case KExpr(_): sType(ctx, t);
				case _: Globals.sTypePath(c.path) + beShallowParams(tl);
			};
			case TType(d, tl): Globals.sTypePath(d.path) + beShallowParams(tl);
			case TAbstract(a, tl): Globals.sTypePath(a.path) + beShallowParams(tl);
			case TFun({args: []}): "() -> ...";
			case TFun({args: [{name: ""}]}): "... -> ...";
			case TFun(sig): "(" + [for (a in sig.args) (a.opt ? "?" : "") + "..."].join(", ") + ") -> ...";
			case TAnon(a): switch (a.status.get()) {
				case Statics(c): "{ Statics " + Globals.sTypePath(c.path) + " }";
				case EnumStatics(e): "{ EnumStatics " + Globals.sTypePath(e.path) + " }";
				case AbstractStatics(ab): "{ AbstractStatics " + Globals.sTypePath(ab.path) + " }";
				case _:
					// Prepending in ascending key order prints fields in descending order.
					var names = [for (n in a.fields.keys()) n];
					names.sort(function(x, y) return x < y ? 1 : (x > y ? -1 : 0));
					var fl = [for (n in names) (TypeFunctions.hasMeta(":optional", a.fields.get(n).meta) ? " ?" : " ") + n];
					"{" + fl.join(",") + " }";
			};
			case TDynamic(null): "Dynamic";
			case TDynamic(t2): "Dynamic" + beShallowParams([t2]);
			case TLazy(f): beShallowType(ctx, TypeFunctions.lazyType(f));
		};
	}

	static function beShallowParams(tl:Array<T>):String {
		return tl.length == 0 ? "" : "<" + [for (_ in tl) "..."].join(", ") + ">";
	}

	public static function betterErrorMessage(errors:Array<UnifyErrorKind>):String {
		var ctx = printContext();
		// Collapse a run of consecutive Cannot_unify down to its first entry.
		var l:Array<UnifyErrorKind> = [];
		var i = 0;
		while (i < errors.length) {
			var cur = errors[i];
			if (cur.match(Cannot_unify(_, _)))
				while (i + 1 < errors.length && errors[i + 1].match(Cannot_unify(_, _))) i++;
			l.push(cur);
			i++;
		}
		var root = getAccessChain(l);
		var buffer = new StringBuf();
		function fill(s:String, idx:Int, total:Int):Array<String> {
			return [for (k in 1...total + 1) k == idx ? s : "..."];
		}
		function getParams(t:T):{path:Path, count:Int} {
			return switch (t) {
				case TInst(c, pl): {path: c.path, count: pl.length};
				case TEnum(e, pl): {path: e.path, count: pl.length};
				case TAbstract(a, pl): {path: a.path, count: pl.length};
				case TType(d, pl): {path: d.path, count: pl.length};
				case _: {path: {pack: [], name: "?"}, count: 0};
			}
		}
		function loopAccess(access:BEAccess, prev:BEAccess):{a:String, e:String} {
			function deep():{a:String, e:String} {
				if (access.next != null) return loopAccess(access.next, access);
				if (access.messages.length > 0) buffer.add(unifyErrorMsgOne(ctx, access.messages[0]));
				return {a: beShallowType(ctx, access.actual), e: beShallowType(ctx, access.expected)};
			}
			return switch (access.kind) {
				case BField(s):
					var r = deep();
					{a: "{ " + s + ": " + r.a + " }", e: "{ " + s + ": " + r.e + " }"};
				case BFuncArg(idx, total):
					var r = deep();
					var sl1 = fill(r.a, idx, total);
					var sl2 = fill(r.e, idx, total);
					// Arguments are contravariant, so the actual/expected sides swap.
					{a: "(" + sl2.join(", ") + ") -> ...", e: "(" + sl1.join(", ") + ") -> ..."};
				case BFuncRet:
					var r = deep();
					{a: "(...) -> " + r.a, e: "(...) -> " + r.e};
				case BTypeParam(idx):
					var r = deep();
					var p1 = getParams(prev.actual);
					var p2 = getParams(prev.expected);
					{a: Globals.sTypePath(p1.path) + "<" + fill(r.a, idx, p1.count).join(", ") + ">", e: Globals.sTypePath(p2.path) + "<" + fill(r.e, idx, p2.count).join(", ") + ">"};
				case BRoot:
					deep();
			}
		}
		if (root.next == null) {
			var all = root.extra.concat(root.messages);
			all.reverse();
			return [for (e in all) unifyErrorMsgOne(ctx, e)].join("\n");
		}
		var r = loopAccess(root.next, root);
		return "error: " + buffer.toString() + "\nhave: " + r.a + "\nwant: " + r.e;
	}

	// Fold the flat error list into a chain of field/argument/return/type-parameter accesses ending at the
	// leaf mismatch.
	static function getAccessChain(errors:Array<UnifyErrorKind>):BEAccess {
		var root = new BEAccess(BRoot, TDynamic(null), TDynamic(null));
		var current = root;
		for (err in errors) switch (err) {
			case Cannot_unify(t1, t2): current.actual = t1; current.expected = t2; current.messages.unshift(err);
			case Invalid_field_type(s): var a = new BEAccess(BField(s), TDynamic(null), TDynamic(null)); current.next = a; current = a;
			case Invalid_function_argument(idx, total): var a = new BEAccess(BFuncArg(idx, total), TDynamic(null), TDynamic(null)); current.next = a; current = a;
			case Invalid_return_type: var a = new BEAccess(BFuncRet, TDynamic(null), TDynamic(null)); current.next = a; current = a;
			case Invariant_parameter(idx): var a = new BEAccess(BTypeParam(idx), TDynamic(null), TDynamic(null)); current.next = a; current = a;
			case Unify_custom(_): current.extra.unshift(err);
			case _: current.messages.unshift(err);
		}
		return root;
	}


	public static function sConst(c:TConstant):String {
		return switch (c) {
			case TInt(i): Std.string(i);
			case TFloat(s): s;
			case TString(s): '"' + StringHelper.sEscape(s) + '"';
			case TBool(b): b ? "true" : "false";
			case TNull: "null";
			case TThis: "this";
			case TSuper: "super";
		}
	}

	// `st` is the type printer used for the FInstance field type.
	static function sFieldAccess(st:T->String, fa:TFieldAccess):String {
		return switch (fa) {
			case FStatic(c, f): "static(" + Globals.sTypePath(c.path) + "." + f.name + ")";
			case FInstance(c, _, f): "inst(" + Globals.sTypePath(c.path) + "." + f.name + " : " + st(f.type) + ")";
			case FClosure(cwp, f): "closure(" + (cwp == null ? f.name : Globals.sTypePath(cwp.c.path) + "." + f.name) + ")";
			case FAnon(f): "anon(" + f.name + ")";
			case FEnum(en, f): "enum(" + Globals.sTypePath(en.path) + "." + f.name + ")";
			case FDynamic(f): "dynamic(" + f + ")";
		}
	}

	// Structural expression printer; st supplies type formatting.
	public static function sExpr(st:T->String, e:TExpr):String {
		function loop(e:TExpr):String return sExpr(st, e);
		inline function slist(f:TExpr->String, l:Array<TExpr>):String return l.map(f).join(",");
		function sVar(v:TVar):String return v.name + ":" + v.id + (TypeFunctions.hasVarFlag(v, VCaptured) ? "[c]" : "");
		var str = switch (e.expr) {
			case TConst(c): "Const " + sConst(c);
			case TLocal(v): "Local " + sVar(v);
			case TArray(e1, e2): loop(e1) + "[" + loop(e2) + "]";
			case TBinop(op, e1, e2): "(" + loop(e1) + " " + Ast.sBinop(op) + " " + loop(e2) + ")";
			case TEnumIndex(e1): "EnumIndex " + loop(e1);
			case TEnumParameter(e1, _, i): loop(e1) + "[" + i + "]";
			case TField(e1, f): loop(e1) + "." + sFieldAccess(st, f);
			case TTypeExpr(m): "TypeExpr " + Globals.sTypePath(TypeFunctions.tPath(m));
			case TParenthesis(e1): "Parenthesis " + loop(e1);
			case TObjectDecl(fl): "ObjectDecl {" + fl.map(function(of) return of.key.name + " : " + loop(of.expr)).join(",") + "}";
			case TArrayDecl(el): "ArrayDecl [" + slist(loop, el) + "]";
			case TCall(e1, el): "Call " + loop(e1) + "(" + slist(loop, el) + ")";
			case TNew(c, pl, el): "New " + Globals.sTypePath(c.path) + (pl.length == 0 ? "" : "<" + pl.map(st).join(",") + ">") + "(" + slist(loop, el) + ")";
			case TUnop(op, f, e1): f.match(Prefix) ? "(" + Ast.sUnop(op) + " " + loop(e1) + ")" : "(" + loop(e1) + " " + Ast.sUnop(op) + ")";
			case TFunction(f):
				var args = f.args.map(function(a) return sVar(a.v) + " : " + st(a.v.type) + (a.c == null ? "" : " = " + loop(a.c))).join(",");
				"Function(" + args + ") : " + st(f.type) + " = " + loop(f.expr);
			case TVarExpr(v, eo): "Vars " + sVar(v) + " : " + st(v.type) + (eo == null ? "" : " = " + loop(eo));
			case TBlock(el): "Block {\n" + el.map(function(e) return loop(e) + ";\n").join("") + "}";
			case TFor(v, econd, e1): "For (" + sVar(v) + " : " + st(v.type) + " in " + loop(econd) + "," + loop(e1) + ")";
			case TIf(ec, e1, e2): "If (" + loop(ec) + "," + loop(e1) + (e2 == null ? "" : "," + loop(e2)) + ")";
			case TWhile(ec, e1, flag): flag.match(NormalWhile) ? "While (" + loop(ec) + "," + loop(e1) + ")" : "DoWhile (" + loop(e1) + "," + loop(ec) + ")";
			case TSwitch(e1, cases, def): "Switch (" + loop(e1) + ",(" + cases.map(function(c) return "case " + slist(loop, c.values) + ": " + loop(c.expr)).join(",") + ")" + (def == null ? "" : "," + loop(def)) + ")";
			case TTry(e1, cl): "Try " + loop(e1) + "(" + cl.map(function(c) return "catch( " + sVar(c.v) + " : " + st(c.v.type) + " ) " + loop(c.expr)).join(",") + ") ";
			case TReturn(null): "Return";
			case TReturn(e1): "Return " + loop(e1);
			case TBreak: "Break";
			case TContinue: "Continue";
			case TThrow(e1): "Throw " + loop(e1);
			case TCast(e1, mt): "Cast " + (mt == null ? "" : Globals.sTypePath(TypeFunctions.tPath(mt)) + ": ") + loop(e1);
			case TMeta(entry, e1): "@" + entry.name + " " + loop(e1); // Args omitted
			case TIdent(s): "Ident " + s;
		}
		return "(" + str + " : " + st(e.type) + ")";
	}

	public static function sExprStr(e:TExpr):String {
		var ctx = printContext();
		return sExpr(function(t) return sType(ctx, t), e);
	}

	// Default tagged-tree format for TypedExprTools.toString.
	public static function sExprAst(printVarIds:Bool, tabs:String, sType:T->String, e:TExpr):String {
		function loop(x:TExpr, extraTabs:String = ""):String return sExprAst(printVarIds, tabs + "\t" + extraTabs, sType, x);
		function tagArgs(tabs:String, sl:Array<String>):String {
			return switch (sl) {
				case []: "";
				case [s] if (s.indexOf("\n") < 0): " " + s;
				case _: var t = "\n" + tabs + "\t"; t + sl.join(t);
			}
		}
		function tag(s:String, sl:Array<String>, ?t:T, extraTabs:String = ""):String {
			return "[" + s + ":" + sType(t == null ? e.type : t) + "]" + tagArgs(tabs + extraTabs, sl);
		}
		function varId(v:TVar):Int return printVarIds ? v.id : 0;
		function local(v:TVar, ?t:T):String return "[Local " + v.name + "(" + varId(v) + "):" + sType(v.type) + (t == null ? "" : ":" + sType(t)) + "]";
		function moduleType(mt:ModuleType):String return "[TypeExpr " + Globals.sTypePath(TypeFunctions.tPath(mt)) + ":" + sType(e.type) + "]";
		return switch (e.expr) {
			case TConst(c): tag("Const", [sConst(c)], e.type);
			case TLocal(v): local(v, e.type);
			case TArray(e1, e2): tag("Array", [loop(e1), loop(e2)]);
			case TBinop(op, e1, e2): tag("Binop", [loop(e1), Ast.sBinop(op), loop(e2)]);
			case TUnop(op, flag, e1): tag("Unop", [Ast.sUnop(op), flag.match(Postfix) ? "Postfix" : "Prefix", loop(e1)]);
			case TEnumParameter(e1, ef, i): tag("EnumParameter", [loop(e1), ef.name, Std.string(i)]);
			case TEnumIndex(e1): tag("EnumIndex", [loop(e1)]);
			case TField(e1, fa):
				var sfa = switch (fa) {
					case FInstance(c, tl, cf): tag("FInstance", [sType(TInst(c, tl)), cf.name + ":" + sType(cf.type)], null, "\t");
					case FStatic(c, cf): tag("FStatic", [Globals.sTypePath(c.path), cf.name + ":" + sType(cf.type)], null, "\t");
					case FClosure(co, cf): tag("FClosure", [co == null ? "None" : sType(TInst(co.c, co.params)), cf.name + ":" + sType(cf.type)], null, "\t");
					case FAnon(cf): tag("FAnon", [cf.name + ":" + sType(cf.type)], null, "\t");
					case FDynamic(s): tag("FDynamic", [s], null, "\t");
					case FEnum(en, ef): tag("FEnum", [Globals.sTypePath(en.path), ef.name], null, "\t");
				};
				tag("Field", [loop(e1), sfa]);
			case TTypeExpr(mt): moduleType(mt);
			case TParenthesis(e1): tag("Parenthesis", [loop(e1)]);
			case TObjectDecl(fl): tag("ObjectDecl", [for (f in fl) Ast.sObjectKeyName(f.key.name, f.key.quotes) + ": " + loop(f.expr)]);
			case TArrayDecl(el): tag("ArrayDecl", [for (x in el) loop(x)]);
			case TCall(e1, el): tag("Call", [loop(e1)].concat([for (x in el) loop(x)]));
			case TNew(c, tl, el): tag("New", [sType(TInst(c, tl))].concat([for (x in el) loop(x)]));
			case TFunction(f):
				function arg(a:TFuncArg):String return tag("Arg", a.c == null ? [local(a.v)] : [local(a.v), loop(a.c)], a.v.type, "\t");
				tag("Function", [for (a in f.args) arg(a)].concat([loop(f.expr)]));
			case TVarExpr(v, eo): "[Var " + v.name + "(" + varId(v) + "):" + sType(v.type) + "]" + tagArgs(tabs, eo == null ? [] : [loop(eo)]);
			case TBlock(el): tag("Block", [for (x in el) loop(x)]);
			case TIf(econd, e1, e2): tag("If", [loop(econd), "[Then:" + sType(e1.type) + "] " + loop(e1)].concat(e2 == null ? [] : ["[Else:" + sType(e2.type) + "] " + loop(e2)]));
			case TCast(e1, null): tag("Cast", [loop(e1)]);
			case TCast(e1, mt): tag("Cast", [loop(e1), moduleType(mt)]);
			case TThrow(e1): tag("Throw", [loop(e1)]);
			case TBreak: tag("Break", []);
			case TContinue: tag("Continue", []);
			case TReturn(null): tag("Return", []);
			case TReturn(e1): tag("Return", [loop(e1)]);
			case TWhile(e1, e2, NormalWhile): tag("While", [loop(e1), loop(e2)]);
			case TWhile(e1, e2, DoWhile): tag("Do", [loop(e1), loop(e2)]);
			case TFor(v, e1, e2): tag("For", [local(v), loop(e1), loop(e2)]);
			case TTry(e1, catches):
				var sl = [for (c in catches) "Catch " + local(c.v) + tagArgs(tabs + "\t", [loop(c.expr, "\t")])];
				tag("Try", [loop(e1)].concat(sl));
			case TSwitch(e1, cases, eo):
				var sl = [for (c in cases) tag("Case", [for (x in c.values) loop(x)].concat([loop(c.expr, "\t")]), c.expr.type, "\t")];
				if (eo != null) sl.push(tag("Default", [loop(eo, "\t")], eo.type, "\t"));
				tag("Switch", [loop(e1)].concat(sl));
			case TMeta(m, e1):
				var ms = m.name;
				if (m.params.length > 0) ms += "(" + [for (x in m.params) hxc.ast.Ast.Printer.sExpr(x)].join(", ") + ")";
				tag("Meta", [ms, loop(e1)]);
			case TIdent(s): tag("Ident", [s]);
		};
	}

	public static function sExprPretty(printVarIds:Bool, tabs:String, topLevel:Bool, st:T->String, e:TExpr):String {
		function loop(x:TExpr):String return sExprPretty(printVarIds, tabs, false, st, x);
		inline function clist(f:TExpr->String, l:Array<TExpr>):String return l.map(f).join(", ");
		function local(v:TVar):String return printVarIds ? v.name + "<" + v.id + ">" : v.name;
		return switch (e.expr) {
			case TConst(c): sConst(c);
			case TLocal(v): local(v);
			case TArray(e1, e2): loop(e1) + "[" + loop(e2) + "]";
			case TBinop(op, e1, e2): loop(e1) + " " + Ast.sBinop(op) + " " + loop(e2);
			case TEnumParameter(e1, _, i): loop(e1) + "[" + i + "]";
			case TEnumIndex(e1): "enumIndex " + loop(e1);
			case TField(e1, s): loop(e1) + "." + TypeFunctions.fieldName(s);
			case TTypeExpr(mt): Globals.sTypePath(TypeFunctions.tPath(mt));
			case TParenthesis(e1): "(" + loop(e1) + ")";
			case TObjectDecl(fl): "{" + fl.map(function(of) return Ast.sObjectKeyName(of.key.name, of.key.quotes) + " : " + loop(of.expr)).join(", ") + "}";
			case TArrayDecl(el): "[" + clist(loop, el) + "]";
			case TCall(e1, el): loop(e1) + "(" + clist(loop, el) + ")";
			case TNew(c, _, el): "new " + Globals.sTypePath(c.path) + "(" + clist(loop, el) + ")";
			case TUnop(op, f, e1): f.match(Prefix) ? Ast.sUnop(op) + " " + loop(e1) : loop(e1) + " " + Ast.sUnop(op);
			case TFunction(f):
				var args = f.args.map(function(a) return local(a.v) + ":" + st(a.v.type) + (a.c == null ? "" : " = " + loop(a.c))).join(", ");
				(topLevel ? "" : "function") + "(" + args + ") " + loop(f.expr);
			case TVarExpr(v, eo): "var " + local(v) + (eo == null ? "" : " = " + loop(eo));
			case TBlock(el):
				var ntabs = tabs + "\t";
				switch (el) {
					case []: "{}";
					case _: "{\n" + el.map(function(x) return ntabs + sExprPretty(printVarIds, ntabs, topLevel, st, x) + ";\n").join("") + tabs + "}";
				}
			case TFor(v, econd, e1): "for (" + local(v) + " in " + loop(econd) + ") " + loop(e1);
			case TIf(e1, ethen, eelse): "if (" + loop(e1) + ") " + loop(ethen) + (eelse == null ? "" : " else " + loop(eelse));
			case TWhile(econd, e1, flag):
				flag.match(NormalWhile) ? "while (" + loop(econd) + ") " + loop(e1) : "do (" + loop(e1) + ") while(" + loop(econd) + ")";
			case TSwitch(e1, cases, def):
				var ntabs = tabs + "\t";
				var body = cases.map(function(c) return ntabs + "case " + clist(loop, c.values) + ": " + sExprPretty(printVarIds, ntabs, topLevel, st, c.expr) + ";\n").join("");
				var d = def == null ? "" : ntabs + "default: " + sExprPretty(printVarIds, ntabs, topLevel, st, def) + "\n";
				"switch (" + loop(e1) + ") {\n" + body + d + tabs + "}";
			case TTry(e1, cl):
				"try " + loop(e1) + cl.map(function(c) return " catch (" + local(c.v) + ":" + st(c.v.type) + ") " + loop(c.expr)).join(", ");
			case TReturn(null): "return";
			case TReturn(e1): "return " + loop(e1);
			case TBreak: "break";
			case TContinue: "continue";
			case TThrow(e1): "throw " + loop(e1);
			case TCast(e1, null): "cast " + loop(e1);
			case TCast(e1, mt): "cast (" + loop(e1) + "," + Globals.sTypePath(TypeFunctions.tPath(mt)) + ")";
			case TMeta(entry, e1):
				"@" + entry.name + (entry.params.length == 0 ? "" : "(" + entry.params.map(Printer.sExpr).join(", ") + ")") + " " + loop(e1);
			case TIdent(s): s;
		}
	}
}

enum BEKind {
	BField(s:String);
	BFuncArg(index:Int, total:Int);
	BFuncRet;
	BTypeParam(index:Int);
	BRoot;
}

class BEAccess {
	public var kind:BEKind;
	public var expected:T;
	public var actual:T;
	public var messages:Array<UnifyErrorKind> = [];
	public var extra:Array<UnifyErrorKind> = [];
	public var next:Null<BEAccess> = null;

	public function new(kind:BEKind, actual:T, expected:T) {
		this.kind = kind;
		this.actual = actual;
		this.expected = expected;
	}
}
