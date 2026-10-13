package hxc.codegen;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;

// narrowing a set of compatible overloads down to the one that is called. A candidate is rated per argument
// by how many conversions the caller's type needs to reach the callee's, and the lowest rating wins.

typedef OverloadCandidate = {
	ftype:T,            // the candidate's applied signature
	fargs:Array<TExpr>, // the typed call arguments
	data:Dynamic        // whatever the caller wants back
};

typedef Rate = {conv:Int, tp:Int};

class NotRelated {
	public function new() {}
}

class Overloads {
	static inline var MAX_INT = 2147483647;

	public static function simplifyT(t:T):T {
		return switch (t) {
			case TInst(_, _) | TEnum(_, _): t;
			case TAbstract(a, [t2]) if (isNull(a)):
				switch (simplifyT(t2)) {
					case t2b = TAbstract(a2, _) if (TypeFunctions.hasMeta(":coreType", a2.meta)):
						TAbstract(a, [simplifyT(t2b)]);
					case t2b = TEnum(_, _): TAbstract(a, [simplifyT(t2b)]);
					case t2b: t2b;
				}
			case TAbstract(a, _) if (TypeFunctions.hasMeta(":coreType", a.meta)): t;
			case TAbstract(a, tl): simplifyT(TypeFunctions.getUnderlyingType(a, tl));
			case TType(td, tl): simplifyT(TypeFunctions.applyTypedef(td, tl));
			case TMono(r): r.type != null ? simplifyT(r.type) : TypeFunctions.tDynamic;
			case TAnon(_): TypeFunctions.tDynamic;
			case TDynamic(_): t;
			case TLazy(f): simplifyT(TypeFunctions.lazyType(f));
			case TFun(_): t;
		}
	}

	static inline function isNull(a:TAbstract):Bool {
		return a.path.pack.length == 0 && a.path.name == "Null";
	}

	// how many of the parameters are not the same type.
	static function rateTp(tlfun:Array<T>, tlarg:Array<T>):Int {
		var acc = 0;
		var n = tlfun.length < tlarg.length ? tlfun.length : tlarg.length;
		for (i in 0...n)
			if (!TypeUnification.typeIseqDefault(tlfun[i], tlarg[i])) acc++;
		return acc;
	}

	// The first number counts conversions, the second the type parameters that differ. Smaller is better.
	public static function rateConv(cacc:Int, tfun:T, targ:T):Rate {
		var sf = simplifyT(tfun);
		var sa = simplifyT(targ);
		switch [sf, sa] {
			case [TInst(cf, tlf), TInst(ca, tla)] if (TypeFunctions.hasClassFlag(cf, CInterface)):
				// breadth-first through the implemented interfaces
				var stack:Array<{acc:Int, c:TClass, tl:Array<T>}> = [{acc: 0, c: ca, tl: tla}];
				var cur = {acc: 0, c: ca, tl: tla};
				while (true) {
					if (stack.length == 0) {
						if (cur.c.superClass == null) throw new NotRelated();
						var sup = cur.c.superClass;
						cur = {
							acc: cur.acc + 1, c: sup.c,
							tl: [for (t in sup.params) TypeFunctions.applyParams(cur.c.params, cur.tl, t)]
						};
						stack = [cur];
						continue;
					}
					var head = stack[0];
					if (head.c == cf) return {conv: cacc + head.acc, tp: rateTp(tlf, head.tl)};
					stack = stack.slice(1).concat([
						for (i in head.c.interfaces)
							{acc: head.acc + 1, c: i.c,
							 tl: [for (t in i.params) TypeFunctions.applyParams(head.c.params, head.tl, t)]}
					]);
				}
			case [TInst(cf, tlf), TInst(ca, tla)]:
				var acc = 0;
				var c = ca;
				var tl = tla;
				while (c != cf) {
					if (c.superClass == null) throw new NotRelated();
					var sup = c.superClass;
					var next = [for (t in sup.params) TypeFunctions.applyParams(c.params, tl, t)];
					acc++;
					c = sup.c;
					tl = next;
				}
				return {conv: cacc + acc, tp: rateTp(tlf, tl)};
			case [TEnum(ef, tlf), TEnum(ea, tla)]:
				if (ef != ea) throw new NotRelated();
				return {conv: cacc, tp: rateTp(tlf, tla)};
			case [TDynamic(_), TDynamic(_)]:
				return {conv: cacc, tp: 0};
			case [TDynamic(_), _]:
				// a function taking Dynamic is always the worst of the set
				return {conv: MAX_INT, tp: 0};
			case [TAbstract(a, _), TDynamic(_)] if (TypeFunctions.hasMeta(":coreType", a.meta) && !isNull(a)):
				// unboxing a Dynamic into a basic type carries a penalty
				return {conv: cacc + 2, tp: 0};
			case [_, TDynamic(_)]:
				return {conv: cacc + 1, tp: 0};
			case [TAbstract(af, [tf]), TAbstract(aa, [ta])] if (isNull(af) && isNull(aa)):
				return rateConv(cacc, tf, ta);
			case [TAbstract(af, [tf]), _] if (isNull(af)):
				return rateConv(cacc + 1, tf, sa);
			case [_, TAbstract(aa, [ta])] if (isNull(aa)):
				return rateConv(cacc + 1, sf, ta);
			case [TAbstract(af, tlf), TAbstract(aa, tla)]:
				if (af == aa) return {conv: cacc, tp: rateTp(tlf, tla)};
				for (t in af.from) {
					try return rateConv(cacc + 1, TypeFunctions.applyParams(af.params, tlf, t), targ)
					catch (_:NotRelated) {}
				}
				for (t in aa.to) {
					try return rateConv(cacc + 1, tfun, TypeFunctions.applyParams(aa.params, tla, t))
					catch (_:NotRelated) {}
				}
				throw new NotRelated();
			case [TFun(_), TFun(_)]:
				// unification has already established these are compatible
				return {conv: cacc, tp: 0};
			case _:
				throw new NotRelated();
		}
	}

	// no worse anywhere, and better somewhere.
	static function isBest(a:Array<Rate>, b:Array<Rate>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) {
			var x = a[i], y = b[i];
			if (!(x.conv < y.conv || (x.conv == y.conv && x.tp <= y.tp))) return false;
		}
		for (i in 0...a.length) {
			var x = a[i], y = b[i];
			if (x.conv < y.conv || (x.conv == y.conv && x.tp < y.tp)) return true;
		}
		return false;
	}

	static function rmDuplicates(l:Array<OverloadCandidate>):Array<OverloadCandidate> {
		var acc:Array<OverloadCandidate> = [];
		for (c in l) {
			var seen = false;
			for (a in acc) if (TypeUnification.typeIseqDefault(c.ftype, a.ftype)) { seen = true; break; }
			if (!seen) acc.push(c);
		}
		return acc;
	}

	static function countOptionals(t:T):Int {
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig):
				var n = 0;
				for (a in sig.args) if (a.opt) n++;
				n;
			case _: 0;
		}
	}

	// only the candidates with the fewest optional arguments survive.
	static function fewerOptionals(l:Array<OverloadCandidate>):Array<OverloadCandidate> {
		var acc:Array<OverloadCandidate> = [];
		for (c in l) {
			if (acc.length == 0) { acc.push(c); continue; }
			var accOpt = countOptionals(acc[0].ftype);
			var cOpt = countOptionals(c.ftype);
			if (accOpt == cOpt) acc.push(c);
			else if (accOpt > cOpt) acc = [c];
		}
		return acc;
	}

	static function isRestType(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, [p]) if (a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Rest"): p;
			case _: null;
		}
	}

	public static function reduceCompatible(compatible:Array<OverloadCandidate>):Array<OverloadCandidate> {
		var l = fewerOptionals(rmDuplicates(compatible));
		if (l.length <= 1) return l;
		function rateArg(t:T, e:TExpr):Rate {
			// an implicit cast starts with a penalty above every other one except Dynamic
			return switch (e.expr) {
				case TMeta(m, _) if (m.name == ":implicitCast"): {conv: MAX_INT - 1, tp: 0};
				case _: rateConv(0, t, e.type);
			}
		}
		function mkRate(c:OverloadCandidate):{rates:Array<Rate>, isRest:Bool} {
			var args = switch (TypeFunctions.follow(c.ftype)) {
				case TFun(sig): sig.args;
				case _: return null;
			};
			var rates:Array<Rate> = [];
			var ei = 0, ai = 0;
			while (true) {
				if (ei >= c.fargs.length && ai >= args.length) return {rates: rates, isRest: false};
				if (ai < args.length && args[ai].opt) { ei++; ai++; continue; }
				if (ai == args.length - 1) {
					var rest = isRestType(args[ai].t);
					if (rest != null) {
						while (ei < c.fargs.length) { rates.push(rateArg(rest, c.fargs[ei])); ei++; }
						return {rates: rates, isRest: true};
					}
				}
				if (ei >= c.fargs.length) return {rates: rates, isRest: false};
				if (ai >= args.length) return {rates: rates, isRest: false};
				rates.push(rateArg(args[ai].t, c.fargs[ei]));
				ei++; ai++;
			}
		}
		var bestRate:Array<Rate> = null;
		var bestIsRest = false;
		var best:Array<OverloadCandidate> = [];
		for (c in l) {
			var r = try mkRate(c) catch (_:NotRelated) null;
			if (r == null) continue;
			if (bestRate == null) { bestRate = r.rates; bestIsRest = r.isRest; best = [c]; continue; }
			if (isBest(r.rates, bestRate)) { bestRate = r.rates; bestIsRest = r.isRest; best = [c]; }
			else if (isBest(bestRate, r.rates)) {}
			// equal: the one without Rest is preferred
			else if (r.isRest && !bestIsRest) {}
			else if (!r.isRest && bestIsRest) { bestRate = r.rates; bestIsRest = r.isRest; best = [c]; }
			else best.push(c);
		}
		return best;
	}

	// two declarations are the SAME overload when their type parameters and their argument types agree.
	public static function sameOverloadArgs(t1:T, t2:T, f1:TClassField, f2:TClassField):Bool {
		if (f1.params.length != f2.params.length) return false;
		for (i in 0...f1.params.length) {
			var tp1 = f1.params[i], tp2 = f2.params[i];
			if (tp1.name != tp2.name) return false;
			var ok = switch [TypeFunctions.follow(tp1.type), TypeFunctions.follow(tp2.type)] {
				case [TInst({kind: KTypeParameter(tl1)}, _), TInst({kind: KTypeParameter(tl2)}, _)]:
					if (tl1.length != tl2.length) false;
					else {
						var eq = true;
						for (j in 0...tl1.length) if (!TypeUnification.typeIseqDefault(tl1[j], tl2[j])) { eq = false; break; }
						eq;
					}
				case _: false;
			}
			if (!ok) return false;
		}
		var a1 = TypeFunctions.follow(TypeFunctions.applyParams(f1.params, [for (tp in f2.params) tp.type], t1));
		return switch [a1, TypeFunctions.follow(t2)] {
			case [TFun(s1), TFun(s2)]:
				if (s1.args.length != s2.args.length) false;
				else {
					var eq = true;
					for (i in 0...s1.args.length)
						if (!TypeUnification.typeIseqDefault(s1.args[i].t, s2.args[i].t)) { eq = false; break; }
					eq;
				}
			case _: false;
		}
	}

	// every declaration of that name up the chain, each with its type mapped through the parameters it was
	// reached by.
	public static function collectOverloads(c:TClass, params:Array<T>, name:String):Array<{t:T, cf:TClassField}> {
		var acc:Array<{t:T, cf:TClassField}> = [];
		function loop(map:T->T, c:TClass):Void {
			function maybeAdd(cf:TClassField):Void {
				var t = map(cf.type);
				for (e in acc) if (sameOverloadArgs(t, e.t, cf, e.cf)) return;
				acc.push({t: t, cf: cf});
			}
			var cf = c.fields.get(name);
			if (cf != null) switch (cf.kind) {
				case Var(_):
				case Method(_):
					maybeAdd(cf);
					for (o in cf.overloads) maybeAdd(o);
			}
			if (c.superClass != null) {
				var sup = c.superClass;
				loop(function(t) return TypeFunctions.applyParams(sup.c.params, [for (t2 in sup.params) map(t2)], map(t)), sup.c);
			} else if (TypeFunctions.hasClassFlag(c, CInterface)) {
				for (i in c.interfaces)
					loop(function(t) return TypeFunctions.applyParams(i.c.params, [for (t2 in i.params) map(t2)], map(t)), i.c);
			}
		}
		loop(function(t) return TypeFunctions.applyParams(c.params, params, t), c);
		return acc;
	}
}
