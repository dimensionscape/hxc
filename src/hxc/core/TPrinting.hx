package hxc.core;

import haxe.ds.StringMap;
import hxc.ast.Ast;                 
import hxc.core.TypeUnification.Meta;
import hxc.core.Type;
import hxc.core.Type.T;
import hxc.core.Type.TMono;
import hxc.core.Type.TMonoConstraintKind;
import hxc.core.Type.AnonStatus;

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
					case Statics(c): "{ Statics " + Globals.sTypePath(c.path) + " }";
					case EnumStatics(e): "{ EnumStatics " + Globals.sTypePath(e.path) + " }";
					case AbstractStatics(ab): "{ AbstractStatics " + Globals.sTypePath(ab.path) + " }";
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

	static function sTypeParams(ctx:Ref<Array<{m:TMono, id:Int}>>, tl:Array<T>):String {
		return tl.length == 0 ? "" : "<" + tl.map(function(t) return sType(ctx, t)).join(", ") + ">";
	}

	public static inline function sTypeStr(t:T):String {
		return sType(printContext(), t);
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
}
