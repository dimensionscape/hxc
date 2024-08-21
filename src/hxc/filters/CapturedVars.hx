package hxc.filters;

// hxc.filters.CapturedVars: captured-variable wrapping with the default haxe-array backing (the
// cs/java native-array variant is out of scope)

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.context.Context;
import hxc.filters.LocalUsage;

class CapturedVars {
	public static function capturedVars(com:Context, e:TExpr):TExpr {
		var basic = com.basic;

		// The default implementation backs a captured var with a one-element haxe Array
		function capturedType(t:T):T return basic.tarray(t);
		function mkRef(v:TVar, ve:Null<TExpr>, p:Position):TExpr {
			return TypeFunctions.mk(TArrayDecl(ve == null ? [] : [ve]), v.type, p);
		}
		function mkRefAccess(e:TExpr, v:TVar):TExpr {
			var inner = TypeFunctions.mk(e.expr, v.type, e.pos);
			return TypeFunctions.mk(TArray(inner, TypeFunctions.mk(TConst(TInt(0)), basic.tint, e.pos)), e.type, e.pos);
		}
		function mkInit(av:TVar, v:TVar, pos:Position):TExpr {
			var elocal = TypeFunctions.mk(TLocal(v), v.type, pos);
			return TypeFunctions.mk(TVarExpr(av, TypeFunctions.mk(TArrayDecl([elocal]), av.type, pos)), basic.tvoid, pos);
		}

		// Fresh var carrying the original (pre-wrap) type
		function mkVar(v:TVar, used:Map<Int, T>):TVar {
			var v2 = TypeFunctions.allocVar(v.kind, v.name, used.get(v.id), v.pos);
			v2.meta = v.meta;
			return v2;
		}

		var wrap:(Map<Int, T>, TExpr)->TExpr = null;
		wrap = function(used:Map<Int, T>, e:TExpr):TExpr {
			return switch (e.expr) {
				case TVarExpr(v, ve):
					var ve2 = if (used.exists(v.id))
						mkRef(v, ve == null ? null : wrap(used, ve), e.pos);
					else
						ve == null ? null : wrap(used, ve);
					TypeFunctions.mk(TVarExpr(v, ve2), e.type, e.pos);
				case TLocal(v) if (used.exists(v.id)):
					mkRefAccess(e, v);
				case TFor(v, it, expr) if (used.exists(v.id)):
					var vtmp = mkVar(v, used);
					var it = wrap(used, it);
					var expr = wrap(used, expr);
					TypeFunctions.mk(TFor(vtmp, it, TypeFunctions.concat(mkInit(v, vtmp, e.pos), expr)), e.type, e.pos);
				case TTry(expr, catches):
					var catches2 = [for (c in catches) {
						var ce = wrap(used, c.expr);
						if (used.exists(c.v.id)) {
							var vtmp = mkVar(c.v, used);
							{v: vtmp, expr: TypeFunctions.concat(mkInit(c.v, vtmp, ce.pos), ce)};
						} else {
							{v: c.v, expr: ce};
						}
					}];
					TypeFunctions.mk(TTry(wrap(used, expr), catches2), e.type, e.pos);
				case TFunction(f):
					// Variables used inside this function but declared outside it
					var fused = new Map<Int, TVar>();
					var tmpUsed = new Map<Int, Bool>();
					for (k in used.keys()) tmpUsed.set(k, true);
					function browse(u:Usage):Void {
						switch (u) {
							case UBlock(f) | ULoop(f) | UFunction(f): f(browse);
							case UUse(v) | UAssign(v):
								if (tmpUsed.exists(v.id)) fused.set(v.id, v);
							case UDeclare(v):
								tmpUsed.remove(v.id);
						}
					}
					LocalUsage.localUsage(browse, e);
					// `fused` is folded in ascending key order while consing onto the accumulator, so the
					// list comes out ordered by descending id. A Map iterates in bucket order here, and the order
					// is observable as the wrapper closure parameter order.
					var vars = [for (v in fused) v];
					vars.sort(function(a, b) return b.id - a.id);

					// In case the variable has been marked as used in a parallel scope
					var fexpr = wrap(used, f.expr);
					var fargs = [for (a in f.args) {
						if (used.exists(a.v.id)) {
							var vtmp = mkVar(a.v, used);
							fexpr = TypeFunctions.concat(mkInit(a.v, vtmp, e.pos), fexpr);
							{v: vtmp, c: a.c};
						} else a;
					}];
					var e2 = TypeFunctions.mk(TFunction(new TFunc(fargs, f.type, fexpr)), e.type, e.pos);
					// A new function scope keeps the captured loop variable from being overwritten by the next
					// iteration
					if (com.platformConfig.capturePolicy.match(CPLoopVars)) {
						// Copy declarations to avoid duplicates (issue #3902)
						var newVars = [for (v in vars) {id: v.id, v: TypeFunctions.allocVar(v.kind, v.name, v.type, v.pos)}];
						function replace(e:TExpr):TExpr {
							return switch (e.expr) {
								case TLocal(v):
									var found = null;
									for (nv in newVars) if (nv.id == v.id) { found = nv.v; break; }
									if (found == null) e else {
										TypeFunctions.addVarFlag(found, VCaptured);
										TypeFunctions.mk(TLocal(found), e.type, e.pos);
									}
								case _:
									TexprTools.mapExpr(replace, e);
							};
						}
						var e3 = replace(e2);
						var wrapper = TypeFunctions.mk(TFunction(new TFunc(
							[for (nv in newVars) {v: nv.v, c: null}],
							e3.type,
							TypeFunctions.mkBlock(TypeFunctions.mk(TReturn(e3), e3.type, e3.pos))
						)), TypeFunctions.tfun([for (nv in newVars) nv.v.type], e3.type), e3.pos);
						TypeFunctions.mk(TCall(
							TexprTools.mkParent(wrapper),
							[for (v in vars) TypeFunctions.mk(TLocal(v), v.type, e3.pos)]
						), e3.type, e3.pos);
					} else {
						e2;
					}
				case _:
					TexprTools.mapExpr(function(x) return wrap(used, x), e);
			};
		}

		function doWrap(used:Map<Int, TVar>, e:TExpr):TExpr {
			var it = used.keys();
			if (!it.hasNext()) return e;
			var usedTypes = new Map<Int, T>();
			for (v in used) {
				var vt = v.type;
				v.type = capturedType(vt);
				TypeFunctions.addVarFlag(v, VCaptured);
				usedTypes.set(v.id, vt);
			}
			return wrap(usedTypes, e);
		}

		var outLoop:TExpr->TExpr = null;
		outLoop = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TFor(_, _, _) | TWhile(_, _, _):
					// Variables declared in the loop but used in sub-functions
					var vars = new Map<Int, Int>();
					var used = new Map<Int, TVar>();
					var depth = 0;
					function collectVars(inLoop:Bool, u:Usage):Void {
						switch (u) {
							case UBlock(f):
								var old = [for (k => d in vars) {k: k, d: d}];
								f(function(u) collectVars(inLoop, u));
								vars.clear();
								for (x in old) vars.set(x.k, x.d);
							case ULoop(f):
								var old = [for (k => d in vars) {k: k, d: d}];
								f(function(u) collectVars(true, u));
								vars.clear();
								for (x in old) vars.set(x.k, x.d);
							case UFunction(f):
								depth++;
								f(function(u) collectVars(false, u));
								depth--;
							case UDeclare(v):
								if (inLoop) vars.set(v.id, depth);
							case UUse(v) | UAssign(v):
								if (vars.exists(v.id) && vars.get(v.id) != depth)
									used.set(v.id, v);
						}
					}
					LocalUsage.localUsage(function(u) collectVars(false, u), e);
					doWrap(used, e);
				case _:
					TexprTools.mapExpr(outLoop, e);
			};
		}

		function allVars(e:TExpr):Map<Int, TVar> {
			var vars = new Map<Int, Int>();
			var used = new Map<Int, TVar>();
			var assigned = new Map<Int, TVar>();
			var depth = 0;
			function collectVars(u:Usage):Void {
				switch (u) {
					case UBlock(f) | ULoop(f):
						var old = [for (k => d in vars) {k: k, d: d}];
						f(collectVars);
						vars.clear();
						for (x in old) vars.set(x.k, x.d);
					case UFunction(f):
						depth++;
						f(collectVars);
						depth--;
					case UDeclare(v):
						vars.set(v.id, depth);
					case UUse(v):
						if (vars.exists(v.id) && vars.get(v.id) != depth) {
							used.set(v.id, v);
							if (TypeFunctions.hasVarFlag(v, VAssigned)) assigned.set(v.id, v);
						}
					case UAssign(v):
						if (vars.exists(v.id)) {
							var d = vars.get(v.id);
							if (d != depth) {
								// Different depth: needs a wrap
								used.set(v.id, v);
								assigned.set(v.id, v);
							} else if (used.exists(v.id)) {
								// Same depth but assigned after a cross-depth use
								assigned.set(v.id, v);
							} else {
								TypeFunctions.addVarFlag(v, VAssigned);
							}
						}
				}
			}
			LocalUsage.localUsage(collectVars, e);
			// Mark all captured variables; local variable renaming reads this later
			for (v in used) TypeFunctions.addVarFlag(v, VCaptured);
			return assigned;
		}

		var captured = allVars(e);
		return switch (com.platformConfig.capturePolicy) {
			case CPNone: e;
			case CPWrapRef: doWrap(captured, e);
			case CPLoopVars: outLoop(e);
		};
	}
}
