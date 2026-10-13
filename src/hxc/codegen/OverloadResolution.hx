package hxc.codegen;

import hxc.core.NotFound;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.codegen.Overloads.OverloadCandidate;

// Picks the one overload a call reaches for the JVM generator, walking up the class chain and rating
// whatever it collects.

// The data each candidate carries: the class the overload was found on, the field itself, and the
// monomorphs its type parameters were opened to.
typedef ResolvedOverload = {
	var c:TClass;
	var cf:TClassField;
	var monos:Array<T>;
}

class OverloadResolution {
	// The element type of a haxe.Rest, or null for any other type.
	static function restElemType(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, params) if (params.length == 1 && a.path.pack.length == 1
				&& a.path.pack[0] == "haxe" && a.path.name == "Rest"): params[0];
			case _: null;
		};
	}

	public static function unifyCf(mapType:T->T, c:TClass, cf:TClassField, el:Array<TExpr>):Null<OverloadCandidate> {
		var monos = [for (_ in cf.params) TypeFunctions.mkMono()];
		var tf = TypeFunctions.follow(TypeFunctions.applyParams(cf.params, monos, mapType(cf.type)));
		return switch (tf) {
			case TFun(sig):
				function loop2(acc:Array<TExpr>, ei:Int, ti:Int):Null<OverloadCandidate> {
					if (ei < el.length && ti < sig.args.length) {
						var e = el[ei];
						var t = sig.args[ti].t;
						try {
							TypeUnification.unifyDefault(e.type, t);
							return loop2(acc.concat([e]), ei + 1, ti + 1);
						} catch (_:Dynamic) {
							var rest = restElemType(t);
							if (rest != null) {
								// A rest argument is only valid as the last parameter.
								if (ti != sig.args.length - 1) throw "die";
								try {
									// Only the arguments after e are checked against the rest element type,
									// so the argument that failed to
									// unify is dropped from the call, and they unify as (rest, argument)
									// where the normal path above unifies
									// (argument, parameter). Both are deliberate.
									var tail = [for (i in (ei + 1)...el.length) {
										TypeUnification.unifyDefault(rest, el[i].type);
										el[i];
									}];
									return {ftype: tf, fargs: acc.concat(tail), data: {c: c, cf: cf, monos: monos}};
								} catch (_:Dynamic) {
									return null;
								}
							}
							return null;
						}
					}
					if (ei >= el.length && ti >= sig.args.length)
						return {ftype: tf, fargs: acc, data: {c: c, cf: cf, monos: monos}};
					return null;
				}
				loop2([], 0, 0);
			case _:
				null;
		}
	}

	public static function findOverload(mapType:T->T, c:TClass, cf:TClassField, el:Array<TExpr>):Array<OverloadCandidate> {
		var acc = [];
		for (cf2 in [cf].concat(cf.overloads)) {
			var fcc = unifyCf(mapType, c, cf2, el);
			if (fcc != null) acc.push(fcc);
		}
		return acc;
	}

	public static function filterOverloads(candidates:Array<OverloadCandidate>):Null<ResolvedOverload> {
		var l = Overloads.reduceCompatible(candidates);
		return l.length == 0 ? null : (l[0].data : ResolvedOverload);
	}

	public static function resolveInstanceOverload(isCtor:Bool, mapType:T->T, c:TClass, name:String,
			el:Array<TExpr>):Null<ResolvedOverload> {
		var candidates:Array<OverloadCandidate> = [];
		function hasFunction(t1:T, fcc2:OverloadCandidate):Bool {
			return switch [TypeFunctions.follow(t1), fcc2.ftype] {
				case [TFun(sig1), TFun(sig2)]:
					TypeUnification.typeIseqDefault(TFun(new TSignature(sig1.args, TypeFunctions.tDynamic)),
						TFun(new TSignature(sig2.args, TypeFunctions.tDynamic)));
				case _: false;
			}
		}
		function loop(mapType:T->T, c:TClass) {
			var notFound = false;
			try {
				var cf = if (isCtor) {
					if (c.constructor == null) throw new NotFound("resolveInstanceOverload ctor");
					c.constructor;
				} else {
					var cf = c.fields.get(name);
					if (cf == null) throw new NotFound("resolveInstanceOverload field");
					cf;
				}
				var l = findOverload(mapType, c, cf, el);
				if (l.length == 0) throw new NotFound("resolveInstanceOverload empty");
				for (fcc in l) {
					var exists = false;
					for (cand in candidates) if (hasFunction(fcc.ftype, cand)) { exists = true; break; }
					if (!exists) candidates.unshift(fcc);
				}
				if (TypeFunctions.hasClassFieldFlag(cf, CfOverload) || cf.overloads.length != 0)
					throw new NotFound("resolveInstanceOverload keep walking");
			} catch (_:NotFound) {
				notFound = true;
			}
			if (notFound) {
				if (TypeFunctions.hasClassFlag(c, CInterface)) {
					for (i in c.interfaces)
						loop(function(t) return TypeFunctions.applyParams(i.c.params, [for (t in i.params) mapType(t)], t), i.c);
				} else switch (c.superClass) {
					case null:
					case s:
						loop(function(t) return TypeFunctions.applyParams(s.c.params, [for (t in s.params) mapType(t)], t), s.c);
				}
			}
		}
		loop(mapType, c);
		// candidates was built by prepending, so reverse it back to collection order
		candidates.reverse();
		return filterOverloads(candidates);
	}

	public static function maybeResolveInstanceOverload(isCtor:Bool, mapType:T->T, c:TClass,
			cf:TClassField, el:Array<TExpr>):Null<ResolvedOverload> {
		if (TypeFunctions.hasClassFieldFlag(cf, CfOverload) || cf.overloads.length != 0)
			return resolveInstanceOverload(isCtor, mapType, c, cf.name, el);
		return switch (unifyCf(mapType, c, cf, el)) {
			case null: {c: c, cf: cf, monos: TypeFunctions.extractParamTypes(cf.params)};
			case fcc: (fcc.data : ResolvedOverload);
		}
	}

	public static function maybeResolveConstructorOverload(c:TClass, tl:TParams,
			el:Array<TExpr>):Null<ResolvedOverload> {
		var r = TypeFunctions.getConstructorClass(c, tl);
		return maybeResolveInstanceOverload(true, function(t) return TypeFunctions.applyParams(r.c.params, r.tl, t),
			r.c, r.cf, el);
	}
}
