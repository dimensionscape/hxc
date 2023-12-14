package hxc.generators.cpp;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;

/**
	Run per type for the Cpp platform before generation: rewrite each override method's signature to match
	the overridden base method's (argument types + return type), so C++ sees a matching, non-covariant
	virtual signature. An argument whose type differs from the base is renamed to a `_tmp_` shadow and the
	real argument is rebound from a cast at the top of the body. This is cpp-only (js skips it, eval never
	generates), so it is safe to run as a mutation pass in CppGen.generate.
**/
class CppFixOverrides {
	// The overridden field, searched up the super chain (cpp skips interfaces), falling back to c's own
	// field (unless it is an AccRequire var).
	static function findField(com:Context, c:TClass, f:TClassField):Null<TClassField> {
		if (c.superClass != null) {
			var sup = c.superClass.c;
			// cpp.FastIterator is a strongly typed extern; the usual rules do not apply.
			if (!(sup.path.pack.length == 1 && sup.path.pack[0] == "cpp" && sup.path.name == "FastIterator")) {
				var r = findField(com, sup, f);
				if (r != null) return r;
			}
		}
		// Cpp uses delegation for interfaces, so interfaces is not searched.
		var own = c.fields.get(f.name);
		if (own == null) return null;
		switch (own.kind) {
			case Var(v) if (v.read.match(AccRequire(_, _))): return null;
			case _:
		}
		return own;
	}

	static function fixOverride(com:Context, c:TClass, f:TClassField, fd:Null<TFunc>):Void {
		var f2 = findField(com, c, f);
		if (f2 == null) return;
		var sig = switch (TypeFunctions.follow(f2.type)) { case TFun(s): s; case _: return; };
		if (fd != null) {
			var targs = sig.args, tret = sig.ret;
			var changed:Array<{v:TVar, v2:TVar}> = [];
			var nargs:Array<TFuncArg> = [];
			for (i in 0...fd.args.length) {
				var cur = fd.args[i];
				var t2 = targs[i].t;
				// Keep the argument when its type (with class + method params monomorphed) equals the base's.
				var same = try {
					hxc.core.TypeUnification.typeEqKind(EqStrict,
						TypeFunctions.monomorphs(c.params, TypeFunctions.monomorphs(f.params, cur.v.type)), t2);
					true;
				} catch (_:Dynamic) false;
				if (same) nargs.push(cur);
				else {
					var v2 = TypeFunctions.allocVar(VGenerated, "_tmp_" + cur.v.name, t2, cur.v.pos);
					changed.push({v: cur.v, v2: v2});
					nargs.push({v: v2, c: cur.c});
				}
			}
			var newExpr = fd.expr;
			if (changed.length > 0) {
				var el = switch (fd.expr.expr) { case TBlock(l): l; case _: [fd.expr]; };
				var p = el.length == 0 ? fd.expr.pos : el[0].pos;
				var tvoid = com.basic.tvoid;
				var elV = [for (ch in changed)
					TypeFunctions.mk(TVarExpr(ch.v, TypeFunctions.mk(TCast(TypeFunctions.mk(TLocal(ch.v2), ch.v2.type, p), null), ch.v.type, p)), tvoid, p)];
				newExpr = TypeFunctions.mk(TBlock(elV.concat(el)), fd.expr.type, fd.expr.pos);
			}
			var newTargs:Array<TSignatureArg> = [for (a in nargs) {name: a.v.name, opt: a.c != null, t: a.v.type}];
			var fd2 = new TFunc(nargs, tret, newExpr);
			f.expr = TypeFunctions.mk(TFunction(fd2), TFun({args: newTargs, ret: tret}), f.expr.pos);
			f.type = TFun({args: newTargs, ret: tret});
		} else if (TypeFunctions.hasClassFlag(c, CInterface)) {
			f.type = TFun({args: sig.args, ret: sig.ret});
		}
	}

	public static function fixOverrides(com:Context, t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c):
				// Overrides can be removed from interfaces (an inherited interface method is dropped).
				if (TypeFunctions.hasClassFlag(c, CInterface)) {
					c.orderedFields = c.orderedFields.filter(function(f) {
						var ff = findField(com, c, f);
						if (ff == null || ff == f) return true;
						c.fields.remove(f.name);
						return false;
					});
				}
				for (f in c.orderedFields) {
					switch [f.expr == null ? null : f.expr.expr, f.kind] {
						case [TFunction(fd), Method(MethNormal) | Method(MethInline)]:
							fixOverride(com, c, f, fd);
						case [null, Method(MethNormal) | Method(MethInline)] if (TypeFunctions.hasClassFlag(c, CInterface)):
							fixOverride(com, c, f, null);
						case _:
					}
				}
			case _:
		}
	}
}
