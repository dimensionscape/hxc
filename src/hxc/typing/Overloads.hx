package hxc.typing;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.NotFound;
import hxc.context.Context;

// One `overload` candidate that accepted the call: its field, the call's function type with the candidate's
// parameters instantiated, the typed arguments, and what commits it.
typedef OverloadCandidate<P> = {cf:TClassField, tf:T, args:Array<TExpr>, payload:P};

// Which `overload` fields a name stands for, and which of the candidates that accepted a call is the best.
class Overloads {
	// sameOverloadArgs: the same type parameters (names and constraints) and the same argument types, the
	// first field's parameters standing for the second's.
	public static function sameOverloadArgs(t1:T, t2:T, f1:TClassField, f2:TClassField, ?getVmtype:T->T):Bool {
		var fTransform = getVmtype != null ? getVmtype : function(t:T) return t;
		function fEq(a:T, b:T):Bool return TypeUnification.typeIseqDefault(fTransform(a), fTransform(b));
		function compareTypeParams():Bool {
			var params1 = f1.params, params2 = f2.params;
			var i = 0;
			while (true) {
				if (i == params1.length && i == params2.length) return true;
				if (i == params1.length || i == params2.length) return false;
				var tp1 = params1[i], tp2 = params2[i];
				function constraintsEqual(a:T, b:T):Bool {
					return switch [TypeFunctions.follow(a), TypeFunctions.follow(b)] {
						case [TInst({kind: KTypeParameter(tl1)}, _), TInst({kind: KTypeParameter(tl2)}, _)]:
							if (tl1.length != tl2.length) false else {
								var ok = true;
								for (j in 0...tl1.length) if (!fEq(tl1[j], tl2[j])) { ok = false; break; }
								ok;
							}
						case _: false;
					};
				}
				if (!(tp1.name == tp2.name && constraintsEqual(tp1.type, tp2.type))) return false;
				i++;
			}
		}
		function compareArguments(tl1:Array<TSignatureArg>, tl2:Array<TSignatureArg>):Bool {
			if (tl1.length != tl2.length) return false;
			for (j in 0...tl1.length) if (!fEq(tl1[j].t, tl2[j].t)) return false;
			return true;
		}
		function compareTypes():Bool {
			var ft1 = TypeFunctions.follow(TypeFunctions.applyParams(f1.params, TypeFunctions.extractParamTypes(f2.params), t1));
			return switch [ft1, TypeFunctions.follow(t2)] {
				case [TFun(s1), TFun(s2)]: compareArguments(s1.args, s2.args);
				case _: false;
			};
		}
		return compareTypeParams() && compareTypes();
	}

	// collectOverloads: the class's own field and its overloads, then the superclass's (an interface's:
	// each super-interface's), each type mapped into the class's terms; a signature already collected hides
	// the inherited one.
	public static function collectOverloads(map:T->T, c:TClass, i:String):Array<{t:T, cf:TClassField}> {
		var acc:Array<{t:T, cf:TClassField}> = [];
		function loop(map:T->T, c:TClass):Void {
			function maybeAdd(cf:TClassField):Void {
				var t = map(cf.type);
				for (e in acc) if (sameOverloadArgs(t, e.t, cf, e.cf)) return;
				acc.unshift({t: t, cf: cf});
			}
			var cf = c.fields.get(i);
			if (cf != null) switch (cf.kind) {
				case Var(_):
				case Method(_):
					maybeAdd(cf);
					for (o in cf.overloads) maybeAdd(o);
			}
			if (c.superClass == null) {
				if (TypeFunctions.hasClassFlag(c, CInterface))
					for (ip in c.interfaces) {
						var tl = [for (t in ip.params) map(t)];
						var ic = ip.c;
						loop(function(t:T) return TypeFunctions.applyParams(ic.params, tl, map(t)), ic);
					}
			} else {
				var sup = c.superClass;
				var tl = [for (t in sup.params) map(t)];
				var sc = sup.c;
				loop(function(t:T) return TypeFunctions.applyParams(sc.params, tl, map(t)), sc);
			}
		}
		loop(map, c);
		acc.reverse();
		return acc;
	}

	// getOverloads, memoized per compilation context.
	public static function getOverloads(com:Context, c:TClass, i:String):Array<{t:T, cf:TClassField}> {
		var key = Context.pathKey(c.path) + "." + i;
		var l = com.overloadCache.get(key);
		if (l == null) {
			l = collectOverloads(function(t:T) return t, c, i);
			com.overloadCache.set(key, l);
		}
		return l;
	}

	// A class whose overloads change forgets what was collected for it.
	public static function forgetOverloads(com:Context, c:TClass, i:String):Void {
		com.overloadCache.remove(Context.pathKey(c.path) + "." + i);
	}

	// Every function type reads as `() -> Dynamic`, which is how the JVM sees two functional arguments.
	public static function ambiguateFuns(t:T):T {
		return switch (TypeFunctions.follow(t)) {
			case TFun(_): TFun(new TSignature([], TypeFunctions.tDynamic));
			case _: TypeFunctions.map(ambiguateFuns, t);
		};
	}


	static inline var MAX_INT = 0x7fffffff;

	static function isNullAbstract(a:TAbstract):Bool {
		return a.path.pack.length == 0 && a.path.name == "Null";
	}

	static function isCoreType(a:TAbstract):Bool {
		return TypeFunctions.hasMeta(":coreType", a.meta);
	}

	static function simplifyT(t:T):T {
		return switch (t) {
			case TInst(_, _) | TEnum(_, _):
				t;
			case TAbstract(a, [t2]) if (isNullAbstract(a)):
				switch (simplifyT(t2)) {
					case s = TAbstract(a2, _) if (isCoreType(a2)): TAbstract(a, [simplifyT(s)]);
					case s = TEnum(_, _): TAbstract(a, [simplifyT(s)]);
					case s: s;
				}
			case TAbstract(a, _) if (isCoreType(a)):
				t;
			case TAbstract(a, tl):
				simplifyT(TypeFunctions.getUnderlyingType(a, tl));
			case TType(td, tl):
				simplifyT(TypeFunctions.applyTypedef(td, tl));
			case TMono(r):
				r.type != null ? simplifyT(r.type) : TypeFunctions.tDynamic;
			case TAnon(_):
				TypeFunctions.tDynamic;
			case TDynamic(_):
				t;
			case TLazy(f):
				simplifyT(TypeFunctions.lazyType(f));
			case TFun(_):
				t;
		};
	}

	static function rateTp(tlfun:Array<T>, tlarg:Array<T>):Int {
		var acc = 0;
		for (i in 0...tlfun.length) if (!TypeUnification.typeIseqDefault(tlfun[i], tlarg[i])) acc++;
		return acc;
	}

	// rateConv: (conversions, type-parameter mismatches); NotFound when the argument's type cannot reach
	// the parameter's.
	static function rateConv(cacc:Int, tfun:T, targ:T):{a:Int, b:Int} {
		return switch [simplifyT(tfun), simplifyT(targ)] {
			case [TInst(cf, tlf), TInst(ca0, tla0)] if (TypeFunctions.hasClassFlag(cf, CInterface)):
				// Breadth-first
				var stack:Array<{acc:Int, c:TClass, tl:Array<T>}> = [{acc: 0, c: ca0, tl: tla0}];
				var cur = {acc: 0, c: ca0, tl: tla0};
				var found:Null<{acc:Int, tl:Array<T>}> = null;
				while (found == null) {
					if (stack.length == 0) {
						var ca = cur.c;
						if (ca.superClass == null) throw new NotFound();
						var sup = ca.superClass;
						cur = {acc: cur.acc + 1, c: sup.c, tl: [for (t in sup.params) TypeFunctions.applyParams(ca.params, cur.tl, t)]};
						stack = [cur];
						continue;
					}
					var top = stack[0];
					if (top.c == cf) {
						found = {acc: top.acc, tl: top.tl};
						break;
					}
					var s = stack.slice(1);
					for (i in top.c.interfaces)
						s.push({acc: top.acc + 1, c: i.c, tl: [for (t in i.params) TypeFunctions.applyParams(top.c.params, top.tl, t)]});
					stack = s;
				}
				{a: cacc + found.acc, b: rateTp(tlf, found.tl)};
			case [TInst(cf, tlf), TInst(ca0, tla0)]:
				var acc = 0;
				var ca = ca0;
				var tla = tla0;
				while (cf != ca) {
					if (ca.superClass == null) throw new NotFound();
					var sup = ca.superClass;
					var tl2 = [for (t in sup.params) TypeFunctions.applyParams(ca.params, tla, t)];
					acc++;
					ca = sup.c;
					tla = tl2;
				}
				{a: cacc + acc, b: rateTp(tlf, tla)};
			case [TEnum(ef, tlf), TEnum(ea, tla)]:
				if (ef != ea) throw new NotFound();
				{a: cacc, b: rateTp(tlf, tla)};
			case [TDynamic(_), TDynamic(_)]:
				{a: cacc, b: 0};
			case [TDynamic(_), _]:
				// A function with dynamic will always be worst of all
				{a: MAX_INT, b: 0};
			case [TAbstract(a, _), TDynamic(_)] if (isCoreType(a) && !isNullAbstract(a)):
				// A dynamic to a basic type will have an "unboxing" penalty
				{a: cacc + 2, b: 0};
			case [_, TDynamic(_)]:
				{a: cacc + 1, b: 0};
			case [TAbstract(an1, [tf]), TAbstract(an2, [ta])] if (isNullAbstract(an1) && isNullAbstract(an2)):
				rateConv(cacc + 0, tf, ta);
			case [TAbstract(an1, [tf]), ta] if (isNullAbstract(an1)):
				rateConv(cacc + 1, tf, ta);
			case [tf, TAbstract(an2, [ta])] if (isNullAbstract(an2)):
				rateConv(cacc + 1, tf, ta);
			case [TAbstract(af, tlf), TAbstract(aa, tla)]:
				if (af == aa) {a: cacc, b: rateTp(tlf, tla)} else {
					var ret:Null<{a:Int, b:Int}> = null;
					for (t in af.from) {
						try {
							ret = rateConv(cacc + 1, TypeFunctions.applyParams(af.params, tlf, t), targ);
							break;
						} catch (_:NotFound) {}
					}
					if (ret == null) for (t in aa.to) {
						try {
							ret = rateConv(cacc + 1, tfun, TypeFunctions.applyParams(aa.params, tla, t));
							break;
						} catch (_:NotFound) {}
					}
					if (ret == null) throw new NotFound();
					ret;
				}
			case [TFun(_), TFun(_)]:
				// Unify will make sure they are compatible
				{a: cacc, b: 0};
			case _:
				throw new NotFound();
		};
	}

	// The (Int, Int) pairs compare lexicographically.
	static inline function le(x:{a:Int, b:Int}, y:{a:Int, b:Int}):Bool return x.a < y.a || (x.a == y.a && x.b <= y.b);

	static inline function lt(x:{a:Int, b:Int}, y:{a:Int, b:Int}):Bool return x.a < y.a || (x.a == y.a && x.b < y.b);

	// isBest: no worse anywhere (lists of unequal length never are) and better somewhere.
	static function isBest(arg1:Array<{a:Int, b:Int}>, arg2:Array<{a:Int, b:Int}>):Bool {
		if (arg1.length != arg2.length) return false;
		for (i in 0...arg1.length) if (!le(arg1[i], arg2[i])) return false;
		for (i in 0...arg1.length) if (lt(arg1[i], arg2[i])) return true;
		return false;
	}

	static function countOptionals(t:T):Int {
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig): var n = 0; for (a in sig.args) if (a.opt) n++; n;
			case _: 0;
		};
	}

	static function isRest(t:T):Bool {
		return switch (t) {
			case TAbstract(a, _): a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Rest";
			case _: false;
		};
	}

	// reduceCompatible. The candidate lists keep the order prepending gives them, which decides the
	// first of several equally good candidates.
	public static function reduceCompatible<P>(compatible:Array<OverloadCandidate<P>>):Array<OverloadCandidate<P>> {
		// Remove duplicates: a candidate whose type equals one already kept is dropped.
		var unique:Array<OverloadCandidate<P>> = [];
		for (fcc in compatible) {
			var dup = false;
			for (u in unique) if (TypeUnification.typeIseqDefault(fcc.tf, u.tf)) { dup = true; break; }
			if (!dup) unique.unshift(fcc);
		}
		// Prefer the candidates with fewer optional arguments.
		var acc:Array<OverloadCandidate<P>> = [];
		for (fcc in unique) {
			if (acc.length == 0) { acc = [fcc]; continue; }
			var accOpt = countOptionals(acc[0].tf);
			var compOpt = countOptionals(fcc.tf);
			if (accOpt == compOpt) acc.unshift(fcc);
			else if (accOpt < compOpt) {}
			else acc = [fcc];
		}
		if (acc.length <= 1) return acc;
		function rateArg(t:T, e:TExpr):{a:Int, b:Int} {
			return switch (e.expr) {
				// If the argument is an implicit cast, we need to start with a penalty higher than any other
				// implicit cast - other than Dynamic, which is MAX_INT
				case TMeta({name: ":implicitCast"}, _): {a: MAX_INT - 1, b: 0};
				case _: rateConv(0, t, e.type);
			};
		}
		// mkRate: the plain arguments are rated in reverse, a trailing Rest's elements appended.
		function mkRate(elist:Array<TExpr>, args:Array<TSignatureArg>):{rate:Array<{a:Int, b:Int}>, rest:Bool} {
			var rate:Array<{a:Int, b:Int}> = [];
			var ei = 0, ai = 0;
			while (true) {
				var eLeft = elist.length - ei, aLeft = args.length - ai;
				if (eLeft == 0 && aLeft == 0) return {rate: rate, rest: false};
				if (eLeft > 0 && aLeft > 0 && args[ai].opt) { ei++; ai++; continue; }
				if (aLeft == 1 && isRest(TypeFunctions.follow(args[ai].t))) {
					var t = switch (TypeFunctions.follow(args[ai].t)) {
						case TAbstract(_, [t]): t;
						case _: throw "rest without a type parameter";
					};
					for (j in ei...elist.length) rate.push(rateArg(t, elist[j]));
					return {rate: rate, rest: true};
				}
				if (eLeft > 0 && aLeft > 0) {
					rate.unshift(rateArg(args[ai].t, elist[ei]));
					ei++;
					ai++;
					continue;
				}
				// This can happen on padNulls = false targets, see #10434
				if (eLeft == 0) return {rate: rate, rest: false};
				throw "mk_rate: more arguments than parameters";
			}
		}
		var best:Null<{rate:Array<{a:Int, b:Int}>, rest:Bool, l:Array<OverloadCandidate<P>>}> = null;
		for (fcc in acc) {
			var sig = switch (TypeFunctions.follow(fcc.tf)) {
				case TFun(s): s;
				case _: throw "overload candidate is not a function";
			};
			var r = try mkRate(fcc.args, sig.args) catch (_:NotFound) continue;
			if (best == null) {
				// If it's the first one, assume it's the best
				best = {rate: r.rate, rest: r.rest, l: [fcc]};
			} else if (isBest(r.rate, best.rate)) {
				best = {rate: r.rate, rest: r.rest, l: [fcc]};
			} else if (isBest(best.rate, r.rate)) {
			} else if (r.rest && !best.rest) {
				// If they are equal, we prefer the one without Rest (issue #10205)
			} else if (!r.rest && best.rest) {
				best = {rate: r.rate, rest: r.rest, l: [fcc]};
			} else {
				best.l.unshift(fcc);
			}
		}
		if (best == null) return [];
		var out = best.l.copy();
		out.reverse();
		return out;
	}
}
