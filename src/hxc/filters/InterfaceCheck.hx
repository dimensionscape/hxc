package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.NotFound;
import hxc.context.Context;

// A class that implements an interface must provide each interface field with a compatible signature; a
// missing field or an incompatible redefinition is an error.
class InterfaceCheck {
	public static function run(ctx:Context):Void {
		// The found-field compatibility checks are DELAYED in the reference (delay PForce) and its delays
		// run newest-first, so they execute here in reverse queue order after every missing-field error
		// reported inline. (delay ctx PForce).
		var deferred:Array<Void->Void> = [];
		for (m in ctx.modules) for (mt in m.types) switch (mt) {
			case TClassDecl(c):
				// The Proxy magic type and extern C#-native classes are exempt. from check_interfaces.
				if (c.path.name == "Proxy" && c.path.pack.length == 0) continue;
				if (TypeFunctions.hasClassFlag(c, CExtern) && TypeFunctions.hasMeta(":cs.native", c.meta)) continue;
				for (imp in c.interfaces) checkInterface(ctx, c, imp.c, imp.params, deferred);
			case _:
		}
		deferred.reverse();
		for (d in deferred) d();
	}

	// Find a field on the class or a superclass, not on an interface, returning its param-mapping
	// function, mapped type, and field.
	static function classFieldNoInterf(c:TClass, name:String):{map:T->T, t:T, f:TClassField} {
		var own = c.fields.get(name);
		if (own != null) return {map: function(t) return t, t: own.type, f: own};
		if (c.superClass == null) throw new NotFound("InterfaceCheck.hx:38");
		var sup = c.superClass;
		var r = TypeFunctions.rawClassField(function(f) return f.type, sup.c, sup.params, name);
		var map = function(t) return TypeFunctions.applyParams(sup.c.params, sup.params, t);
		return {map: map, t: TypeFunctions.applyParams(sup.c.params, sup.params, r.t), f: r.f};
	}

	static function checkInterface(ctx:Context, c:TClass, intf:TClass, params:TParams, deferred:Array<Void->Void>):Void {
		// A super-interface's fields are also required, with the interface's params applied.
		for (i2 in intf.interfaces)
			checkInterface(ctx, c, i2.c, [for (p in i2.params) TypeFunctions.applyParams(intf.params, params, p)], deferred);
		var p = c.namePos;
		for (f in intf.orderedFields) checkField(ctx, c, intf, params, f, p, deferred);
	}

	static function isMethod(f:TClassField):Bool {
		return switch (f.kind) { case Method(_): true; case _: false; };
	}

	static function checkField(ctx:Context, c:TClass, intf:TClass, params:TParams, f:TClassField, p:Position, deferred:Array<Void->Void>):Void {
		var t = TypeFunctions.applyParams(intf.params, params, f.type);
		var found:Null<{map:T->T, t:T, f:TClassField}> = null;
		try found = classFieldNoInterf(c, f.name) catch (_:NotFound) found = null;
		if (found == null) {
			// A missing field: an abstract class may leave an interface method implicit; a field with
			// @:?default becomes an implicit override; otherwise a non-interface class errors.
			if (TypeFunctions.hasClassFlag(c, CAbstract) && isMethod(f)) return;
			if (TypeFunctions.hasClassFieldFlag(f, CfDefault)) return;
			if (!TypeFunctions.hasClassFlag(c, CInterface))
				ctx.addDiagnostic("Field " + f.name + " needed by " + Context.sTypePath(intf.path) + " is missing", p);
			return;
		}
		deferred.push(function() checkFoundField(ctx, c, intf, params, f, found));
	}

	// The compatibility half of check_field, run from the reversed deferred queue. (the delay PForce body).
	static function checkFoundField(ctx:Context, c:TClass, intf:TClass, params:TParams, f:TClassField, found:{map:T->T, t:T, f:TClassField}):Void {
		var f2 = found.f;
		var t2 = found.t;
		var fp = f2.namePos;
		function mkind(m:MethodKind):Int return switch (m) { case MethNormal | MethInline: 0; case MethDynamic: 1; case MethMacro: 2; };
		if (TypeFunctions.hasClassFieldFlag(f, CfPublic) && !TypeFunctions.hasClassFieldFlag(f2, CfPublic) && !TypeFunctions.hasMeta(":compilerGenerated", f.meta)) {
			ctx.addDiagnostic("Field " + f.name + " should be public as requested by " + Context.sTypePath(intf.path), fp);
			return;
		}
		var kindOk = TypeUnification.unifyKind(f2.kind, f.kind) && switch [f.kind, f2.kind] {
			case [Var(_), Var(_)]: true;
			case [Method(m1), Method(m2)]: mkind(m1) == mkind(m2);
			case _: false;
		};
		if (!kindOk) {
			ctx.addDiagnostic("Field " + f.name + " has different property access than in " + Context.sTypePath(intf.path)
				+ " (" + hxc.core.TPrinting.sKind(f2.kind) + " should be " + hxc.core.TPrinting.sKind(f.kind) + ")", fp);
			return;
		}
		var map1 = function(tt:T) return TypeFunctions.applyParams(intf.params, params, tt);
		try {
			validRedefinition(map1, found.map, f2, t2, f, TypeFunctions.applyParams(intf.params, params, f.type));
		} catch (e:UnifyError) {
			if (!(TypeFunctions.hasMeta(":cs.native", c.meta) && TypeFunctions.hasClassFlag(c, CExtern))) {
				// The depth-1 messages carry the "... " prefix; the classic formatter keeps it and prefixes
				// continuation lines, the indent formatter strips it.
				ctx.addDiagnostic("Field " + f.name + " has different type than in " + Context.sTypePath(intf.path), fp);
				ctx.addDiagnostic("... Interface field is defined here", f.pos, 1);
				ctx.addDiagnostic("... " + hxc.core.TPrinting.betterErrorMessage(e.errors), fp, 1);
			}
		}
	}

	// Child = f1/t1, parent = f2/t2.
	public static function validRedefinition(map1:T->T, map2:T->T, f1:TClassField, t1:T, f2:TClassField, t2:T):Void {
		function valid(a:T, b:T):Void {
			TypeUnification.unifyDefault(a, b);
			if (TypeFunctions.isNull(a) != TypeFunctions.isNull(b)
				|| (isDynamicT(TypeFunctions.follow(a)) && !isDynamicT(TypeFunctions.follow(b))))
				throw new UnifyError([Cannot_unify(a, b)], "InterfaceCheck.hx:114");
		}
		// Type parameters: for equal non-empty param lists both types are applied to the same fresh
		// placeholder types; any other param list leaves the types unchanged.
		var pt1 = t1, pt2 = t2;
		if (f1.params.length == f2.params.length && f1.params.length > 0) {
			var monos:TParams = [for (tp in f1.params) TInst(TypeFunctions.mkClass(TypeFunctions.nullModule, {pack: [], name: tp.name}, Position.nullPos, Position.nullPos), [])];
			pt1 = TypeFunctions.applyParams(f1.params, monos, t1);
			pt2 = TypeFunctions.applyParams(f2.params, monos, t2);
		}
		switch [f1.kind, f2.kind] {
			case [Method(m1), Method(m2)] if (m1 != MethDynamic && m2 != MethDynamic):
				switch [TypeFunctions.follow(pt1), TypeFunctions.follow(pt2)] {
					case [TFun(sig1), TFun(sig2)]:
						if (sig1.args.length != sig2.args.length) throw new UnifyError([Unify_custom("Different number of function arguments")], "InterfaceCheck.hx:129");
						// `i` is 0 while checking the return, then the 1-based argument index. The failing
						// position selects Invalid_return_type vs Invalid_function_argument.
						var i = 0;
						try {
							valid(sig1.ret, sig2.ret);
							for (k in 0...sig1.args.length) {
								i = k + 1;
								var a1 = sig1.args[k], a2 = sig2.args[k];
								if (a1.opt != a2.opt) throw new UnifyError([Not_matching_optional(a1.name)], "InterfaceCheck.hx:138");
								try valid(a2.t, a1.t) catch (_:UnifyError) throw new UnifyError([Cannot_unify(a1.t, a2.t)], "InterfaceCheck.hx:139");
							}
						} catch (e:UnifyError) {
							var msg:UnifyErrorKind = i == 0 ? Invalid_return_type : Invalid_function_argument(i, sig1.args.length);
							throw new UnifyError([Cannot_unify(pt1, pt2), msg].concat(e.errors), "InterfaceCheck.hx:143");
						}
					case _:
				}
			case [_, Var(vk)] if (vk.write.match(AccNo) || vk.write.match(AccNever)):
				valid(pt1, pt2); // Write variance
			case [_, Var(vk)] if (vk.read.match(AccNo) || vk.read.match(AccNever)):
				valid(pt2, pt1); // Read variance
			case _ if (TypeFunctions.hasClassFieldFlag(f2, CfFinal)):
				valid(pt1, pt2);
			case _:
				TypeUnification.typeEqKind(EqStrict, pt1, pt2);
				if (TypeFunctions.isNull(pt1) != TypeFunctions.isNull(pt2)) throw new UnifyError([Cannot_unify(pt1, pt2)], "InterfaceCheck.hx:155");
		}
	}

	static function isDynamicT(t:T):Bool {
		return switch (t) { case TDynamic(_): true; case _: false; };
	}
}
