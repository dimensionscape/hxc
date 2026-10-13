package hxc.filters;

import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.NotFound;
import hxc.core.Type;
import hxc.core.TexprTools;
import hxc.core.TypeFunctions;

// Changes every defined function so that each argument with a default value takes a nullable type,
// and adds, at the start of the function, the unwrapping from the nullable argument to the
// non-nullable type.
//
// Runs on the Java target only. Without it a `x:Bool = false` argument keeps its unboxed type on the
// local while the method descriptor boxes it, and the JVM verifier rejects the mismatched stack map
// frame.

class DefaultArguments {
	static function genCheck(basic:BasicTypes, t:T, nullableVar:TVar, const:TExpr, pos:Position):TExpr {
		function isNull(t:T) {
			return switch (t) {
				case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Null";
				case _: false;
			}
		}
		function needsCast(t1:T, t2:T) return isNull(t1) != isNull(t2);
		var constT = const.type;
		var c = needsCast(t, constT) ? TypeFunctions.mkCast(const, t, pos) : const;
		var arg = TexprTools.makeLocal(nullableVar, pos);
		if (needsCast(t, nullableVar.type)) arg = TypeFunctions.mkCast(arg, t, pos);
		var check = TypeFunctions.mk(TBinop(OpEq, TexprTools.makeLocal(nullableVar, pos),
			TexprTools.makeNull(nullableVar.type, pos)), basic.tbool, pos);
		return TypeFunctions.mk(TIf(check, c, arg), t, pos);
	}

	// Each generated check is prepended while the caller maps over the arguments front to back, so the
	// emitted block comes out in reverse argument order: `new(?a:Int = 1, ?b:String = "foo")` checks b
	// before a.
	static function addOpt(com:Context, block:Array<TExpr>, pos:Position, a:TFuncArg):TFuncArg {
		if (a.c == null) return a;
		switch (a.c.expr) {
			case TConst(TNull):
				return a;
			case TConst(TString(_)):
				block.unshift(TexprTools.setDefault(com.basic, a.v, a.c, pos));
				return a;
			case _:
				var basic = com.basic;
				var nullableVar = TypeFunctions.allocVar(a.v.kind, a.v.name, basic.tnull(a.v.type), pos);
				// var v = (nullableVar == null) ? const : cast nullableVar;
				block.unshift(TypeFunctions.mk(TVarExpr(a.v,
					genCheck(basic, a.v.type, nullableVar, a.c, pos)), basic.tvoid, pos));
				return {v: nullableVar, c: a.c};
		}
	}

	static function changeFunc(com:Context, cl:TClass, cf:TClassField):Void {
		for (cf2 in cf.overloads) changeFunc(com, cl, cf2);
		if (TypeFunctions.hasClassFieldFlag(cf, CfPostProcessed)) return;
		switch (cf.kind) {
			case Var(_) | Method(MethDynamic): return;
			case _:
		}
		var sig = switch (TypeFunctions.follow(cf.type)) {
			case TFun(s): s;
			case t: throw "die:" + hxc.core.Globals.sTypePath(cl.path) + "." + cf.name + " : " + hxc.core.TPrinting.sTypeStr(t) + " extern=" + TypeFunctions.hasClassFlag(cl, CExtern);
		}
		var isCtor = cf.name == "new";
		var basic = com.basic;
		var found = false;
		var args = [
			for (a in sig.args) {
				if (a.opt) {
					found = true;
					new TSignatureArg(a.name, a.opt, basic.tnull(a.t));
				} else {
					new TSignatureArg(a.name, a.opt, a.t);
				}
			}
		];
		if (found && cf.expr != null) switch (cf.expr.expr) {
			case TFunction(tf):
				var block:Array<TExpr> = [];
				var tfArgs = [for (a in tf.args) addOpt(com, block, tf.expr.pos, a)];
				var argAssoc = [for (i in 0...tf.args.length) {from: tf.args[i].v, to: tfArgs[i]}];
				// a constructor whose super call has to stay the first statement gets the check inlined
				// into the super arguments instead
				function extractSuper(e:TExpr):{sup:TExpr, tl:Array<TExpr>} {
					switch (e.expr) {
						case TBlock(el) if (el.length > 0):
							switch (el[0].expr) {
								case TCall({expr: TConst(TSuper)}, _):
									return {sup: el[0], tl: el.slice(1)};
								case _:
									var r = extractSuper(el[0]);
									return {sup: r.sup, tl: r.tl.concat(el.slice(1))};
							}
						case _:
							throw new NotFound("defaultArguments extract_super");
					}
				}
				var newExpr:TExpr;
				try {
					if (!isCtor) throw new NotFound("defaultArguments not ctor");
					// Only a constructor whose @:hxGen ancestry reaches a superclass without @:hxGen needs
					// the super call
					// to stay first; when every ancestor is @:hxGen the checks are simply prepended.
					var c = cl;
					while (true) {
						if (!TypeFunctions.hasMeta(":hxGen", c.meta)) break;
						if (c.superClass == null) throw new NotFound("defaultArguments no super");
						c = c.superClass.c;
					}
					var r = extractSuper(tf.expr);
					switch (r.sup.expr) {
						case TCall(e1, sargs):
							// any super argument will be replaced by an inlined version of the check
							var replaced = false;
							function replaceArgs(e:TExpr):TExpr {
								switch (e.expr) {
									case TLocal(v):
										for (m in argAssoc) if (m.from == v && m.to.c != null) {
											replaced = true;
											return genCheck(basic, v.type, m.to.v, m.to.c, e.pos);
										}
										return e;
									case _:
										return TexprTools.mapExpr(replaceArgs, e);
								}
							}
							var sargs2 = [for (e in sargs) replaceArgs(e)];
							var sup = replaced
								? TypeFunctions.mk(TCall(e1, sargs2), r.sup.type, r.sup.pos)
								: r.sup;
							newExpr = TypeFunctions.mk(TBlock([sup].concat(block).concat(r.tl)),
								tf.expr.type, tf.expr.pos);
						case _:
							throw "die";
					}
				} catch (_:NotFound) {
					newExpr = TypeFunctions.concat(TypeFunctions.mk(TBlock(block), basic.tvoid,
						tf.expr.pos), tf.expr);
				}
				args = [for (a in tfArgs) new TSignatureArg(a.v.name, a.c != null, a.v.type)];
				var cfType = TFun(new TSignature(args, sig.ret));
				cf.expr = TypeFunctions.mk(TFunction({
					args: tfArgs,
					type: tf.type,
					expr: newExpr
				}), cfType, cf.expr.pos);
				cf.type = cfType;
			case _:
		}
		if (found) cf.type = TFun(new TSignature(args, sig.ret));
	}

	public static function run(com:Context, md:ModuleType):Void {
		switch (md) {
			case TClassDecl(cl):
				for (cf in cl.orderedFields) changeFunc(com, cl, cf);
				for (cf in cl.orderedStatics) changeFunc(com, cl, cf);
				if (cl.constructor != null) changeFunc(com, cl, cl.constructor);
			case _:
		}
	}
}
