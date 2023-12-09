package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.NotFound;
import hxc.core.StringHelper;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;

class Fields {
	// Visibility, including @:allow / @:access paths, module statics, superclass, type-param
	// constraints, and @:privateAccess (ctx.privateAccess).
	static function makePath(c:TClass, f:TClassField):Array<String> {
		return switch (c.kind) {
			case KAbstractImpl(a): a.path.pack.concat([a.path.name, f.name]);
			case KGenericInstance(c2, _): makePath(c2, f);
			case _ if (c.isPrivate): c.path.pack.slice(0, c.path.pack.length - 1).concat([c.path.name, f.name]);
			case _: c.path.pack.concat([c.path.name, f.name]);
		};
	}

	static function exprPath(acc:Array<String>, e:Expr):Array<String> {
		return switch (e.expr) {
			case EField(e1, fn, _): exprPath([fn].concat(acc), e1);
			case EConst(CIdent(n)): [n].concat(acc);
			case _: [];
		};
	}

	static function chkPath(psub:Array<String>, pfull:Array<String>, isCurrentPath:Bool):Bool {
		if (psub.length == 0) return true;
		if (pfull.length == 0) return false;
		if (psub[0] != pfull[0]) return false;
		var l1 = psub.slice(1);
		if (!isCurrentPath && l1.length == 0 && !StringHelper.startsUppercaseIdentifier(psub[0])) return false;
		return chkPath(l1, pfull.slice(1), isCurrentPath);
	}

	static function hasMetaPath(m:String, c:TClass, f:TClassField, path:Array<String>, isCurrentPath:Bool):Bool {
		function loop(ml:Metadata):Bool {
			for (entry in ml) if (entry.name == m) {
				for (e in entry.params) switch (e.expr) {
					case EConst(CIdent("std")): if (path.length == 2) return true;
					case _:
						var p = exprPath([], e);
						if (p.length != 0 && chkPath(p, path, isCurrentPath)) return true;
				}
			}
			return false;
		}
		return loop(c.meta) || loop(f.meta);
	}

	// forcePrivate ignores CfPublic, treating the field as non-public when an AccNo/AccNever
	// accessor makes a public field effectively private.
	static function canAccess(ctx:TyperContext, c:TClass, cf:TClassField, stat:Bool, forcePrivate:Bool = false):Bool {
		if (!forcePrivate && TypeFunctions.hasClassFieldFlag(cf, CfPublic)) return true;
		if (c == ctx.curclass) return true;
		var ms = ctx.curclass.module.statics;
		if (ms != null && c == ms) return true;
		var modulePath = ctx.curclass.module.path;
		var curPaths:Array<{path:Array<String>, cur:Bool}> = [{path: modulePath.pack.concat([modulePath.name]), cur: false}];
		function loopCur(c2:TClass, isCurrentPath:Bool):Void {
			curPaths.unshift({path: makePath(c2, ctx.curfield), cur: isCurrentPath});
			switch (c2.superClass) { case null: case sup: loopCur(sup.c, false); }
			for (i in c2.interfaces) loopCur(i.c, false);
		}
		loopCur(ctx.curclass, true);
		var isConstr = cf.name == "new";
		function loopTarget(c2:TClass):Bool {
			try {
				if (hasMetaPath(":access", ctx.curclass, ctx.curfield, makePath(c2, cf), true)) return true;
				function allowed(ff:TClassField):Bool {
					if (TypeFunctions.extendsClass(ctx.curclass, c2)) return true;
					for (cp in curPaths) if (hasMetaPath(":allow", c2, ff, cp.path, cp.cur)) return true;
					return false;
				}
				var direct:Bool;
				if (isConstr) {
					switch (c2.constructor) {
						case null: direct = false;
						case ctor:
							if (allowed(ctor)) direct = true;
							else if (ctor.expr == null) direct = false;
							else throw new NotFound();
					}
				} else {
					var ff = (stat ? c2.statics : c2.fields).get(cf.name);
					direct = ff == null ? false : allowed(ff);
				}
				if (direct) return true;
				return switch (c2.superClass) { case null: false; case sup: loopTarget(sup.c); };
			} catch (_:NotFound) {
				return false;
			}
		}
		var result = loopTarget(c);
		if (!result) switch (c.kind) {
			case KTypeParameter(tl):
				for (t in tl) switch (TypeFunctions.follow(t)) { case TInst(ci, _): if (loopTarget(ci)) { result = true; break; } case _: }
			case _:
		}
		return result || ctx.privateAccess > 0;
	}

	// Recorded, not raised, so typing continues and a batch compile reports every access violation.
	static function checkFieldAccess(ctx:TyperContext, c:TClass, f:TClassField, stat:Bool, p:Position):Void {
		if (!ctx.untypedMode && !canAccess(ctx, c, f, stat))
			ctx.com.addDiagnostic("Cannot access private field " + f.name, p);
	}

	// Recorded (not raised) so typing continues; a missing constructor is left to the caller (a null
	// constructor is handled there).
	public static function checkConstructorAccess(ctx:TyperContext, c:TClass, f:TClassField, p:Position):Void {
		if (!ctx.untypedMode && !(canAccess(ctx, c, f, true) || TypeFunctions.extendsClass(ctx.curclass, c)))
			ctx.com.addDiagnostic("Cannot access private constructor of " + hxc.core.Globals.sTypePath(c.path), p);
	}

	static function checkAbstractFieldAccess(ctx:TyperContext, a:TAbstract, f:TClassField, p:Position):Void {
		if (a.impl != null && TypeFunctions.hasClassFieldFlag(f, CfImpl))
			checkFieldAccess(ctx, a.impl, f, true, p);
	}

	// The @:require failure text: names the flag, with special phrasing for sys and flash
	// versions, or a generic line when the flag is unknown.
	static function errorRequire(r:String):String {
		if (r == "") return "This field is not available with the current compilation flags";
		var what = if (r == "sys") {
			"a system platform (php,neko,cpp,etc.)";
		} else if (StringTools.startsWith(r, "flash") && r.length > 5) {
			var v = StringTools.replace(r.substr(5), "_", ".");
			"flash version " + v + " (use -swf-version " + v + ")";
		} else {
			"'" + r + "' to be enabled";
		}
		return "Accessing this field requires " + what;
	}

	// A @:noClosure method (or any method of a @:noClosure class) cannot be read as a value.
	static function checkNoClosureMeta(ctx:TyperContext, f:TClassField, fh:FieldHost, mode:AccessMode, p:Position):Void {
		switch (mode) {
			case MGet | MSet(_):
				switch (f.kind) {
					case Method(_):
						var clMeta = switch (fh) {
							case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c): c.meta;
							case _: [];
						};
						if (TypeFunctions.hasMeta(":noClosure", clMeta) || TypeFunctions.hasMeta(":noClosure", f.meta))
							throw new TypingError("Method " + f.name + " cannot be used as a value", p);
					case _:
				}
			case _:
		}
	}

	public static function fieldAccess(ctx:TyperContext, mode:AccessMode, f:TClassField, fh:FieldHost, e:TExpr, pfield:Position):AccessKind {
		var pfull = Position.union(e.pos, pfield);
		var isSet = mode.match(MSet(_));
		checkNoClosureMeta(ctx, f, fh, mode, pfield);
		forceFieldType(ctx, f, fh);
		// Visibility. An overloaded method call is checked after the actual overload is resolved, so
		// skip it here; an instance access uses the actual (potential child) class from the receiver
		// type.
		function maybeCheckVisibility(c:TClass, stat:Bool):Void {
			switch (mode) {
				case MCall(_) if (TypeFunctions.hasClassFieldFlag(f, CfOverload)):
				case _: checkFieldAccess(ctx, c, f, stat, pfield);
			}
		}
		switch (fh) {
			case FHInstance(_, _):
				switch (TypeFunctions.follow(e.type)) {
					case TInst(c2, _): maybeCheckVisibility(c2, false);
					case _:
				}
			case FHStatic(c): maybeCheckVisibility(c, true);
			case FHAbstract(_, _, c): maybeCheckVisibility(c, true);
			case FHAnon:
		}
		// Each field access consumes one @:bypassAccessor from the pending count.
		var bypassAccessor = if (ctx.bypassAccessor > 0) { ctx.bypassAccessor--; true; } else false;
		function makeAccess(isInline:Bool):FieldAccess {
			return FieldAccessTools.create(e, f, fh, isInline, pfull);
		}
		return switch (f.kind) {
			case Method(m):
				if (isSet && !m.match(MethDynamic) && !ctx.untypedMode)
					throw new TypingError("Cannot rebind this method : please use 'dynamic' before method declaration", pfield);
				function methodAccess() {
					return makeAccess(m.match(MethInline));
				}
				switch (fh) {
					case FHAbstract(a, tl, c):
						AKUsingField(FieldAccessTools.makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, pfull));
					case _:
						AKField(methodAccess());
				}
			case Var(vk):
				var acc = isSet ? vk.write : vk.read;
				// An AccNo/AccNever access outside the owner resolves to AKNo, which errors only when the
				// value is actually read, written or called.
				function normalFailure():AccessKind return AKNo(AKField(makeAccess(false)), pfield);
				switch (acc) {
					case AccNo if (ctx.privateAccess == 0):
						switch (TypeFunctions.follow(e.type)) {
							case TInst(c2, _) if (TypeFunctions.extendsClass(ctx.curclass, c2) || canAccess(ctx, c2, f, false, true)):
								AKField(makeAccess(false));
							case TAnon(an):
								switch (an.status.get()) {
									case Statics(c2) if (ctx.curclass == c2 || canAccess(ctx, c2, f, true, true)): AKField(makeAccess(false));
									case _: ctx.untypedMode ? AKField(makeAccess(false)) : normalFailure();
								}
							case _:
								ctx.untypedMode ? AKField(makeAccess(false)) : normalFailure();
						}
					case AccNormal | AccNo:
						AKField(makeAccess(false));
					case AccNever:
						ctx.untypedMode ? AKField(makeAccess(false)) : normalFailure();
					case AccCtor:
						var ok = switch [ctx.curfun, fh] {
							case [FunConstructor, FHInstance(c2, _)]:
								c2 == ctx.curclass || (TypeFunctions.hasClassFlag(c2, CAbstract) && TypeFunctions.extendsClass(ctx.curclass, c2));
							case _: false;
						};
						ok ? AKField(makeAccess(false)) : normalFailure();
					case AccInline:
						AKField(makeAccess(true));
					case AccCall:
						// Reading/writing a property through its own accessor (or under @:bypassAccessor)
						// resolves to a raw field access, so the getter/setter does not recurse into itself.
						var accName = (isSet ? "set_" : "get_") + f.name;
						var selfAccess = accName == ctx.curfield.name && (switch (e.expr) {
							case TConst(TThis): true;
							case TLocal(v): ctx.vthis != null && v == ctx.vthis;
							case TTypeExpr(TClassDecl(c)): c == ctx.curclass;
							case _: false;
						});
						if (bypassAccessor || selfAccess) {
							if (!TypeFunctions.isPhysicalField(f))
								throw new TypingError("This field cannot be accessed because it is not a real variable", pfield);
							AKField(makeAccess(false));
						} else {
							hxc.filters.DeprecationCheck.checkPropertyUse(ctx, f, pfield);
							switch (fh) {
								case FHAbstract(a, tl, c):
									AKUsingAccessor(FieldAccessTools.makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, pfull));
								case _:
									AKAccessor(makeAccess(false));
							}
						}
					case AccRequire(r, msg):
						throw new TypingError(msg != null ? msg : errorRequire(r), pfield);
				}
		};
	}

	static function forceFieldType(ctx:TyperContext, f:TClassField, fh:FieldHost):Void {
		if (f.expr != null) return;
		switch (f.kind) {
			case Var(_):
				switch (fh) {
					case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c):
						TypeFields.forceFieldBody(ctx.com, c, f);
					case FHAnon:
				}
			case _:
		}
	}

	static function fieldTypeC(c:TClass, tl:TParams, f:TClassField):T {
		if (f.params.length == 0) return TypeFunctions.applyParams(c.params, tl, f.type);
		function mapClassParams(t:T):T return TypeFunctions.applyParams(c.params, tl, t);
		var monos:TParams = TypeUnification.spawnConstrainedMonos(mapClassParams, f.params);
		return mapClassParams(TypeFunctions.applyParams(f.params, monos, f.type));
	}

	static function classField(c:TClass, tl:TParams, i:String):{c2:Null<TClassWithParams>, t:T, f:TClassField} {
		return TypeFunctions.rawClassField(function(f) return fieldTypeC(c, tl, f), c, tl, i);
	}

	static function classFieldWithAccess(ctx:TyperContext, mode:AccessMode, e:TExpr, c:TClass, tl:TParams, i:String, pfield:Position):AccessKind {
		var r = classField(c, tl, i);
		var fh = switch (r.c2) {
			case null: FHAnon;
			case cw: FHInstance(cw.c, cw.params);
		};
		return fieldAccess(ctx, mode, r.f, fh, e, pfield);
	}

	static function fieldNotFound(t:T, i:String, p:Position):TypingError {
		return new FieldNotFoundError(typeName(t) + " has no field " + i, p);
	}

	static function typeName(t:T):String {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _): hxc.core.Globals.sTypePath(c.path);
			case TAbstract(a, _): hxc.core.Globals.sTypePath(a.path);
			case TEnum(e, _): hxc.core.Globals.sTypePath(e.path);
			case TAnon(_): "<structure>";
			case _: "Type";
		};
	}

	public static function typeField(ctx:TyperContext, e:TExpr, i:String, p:Position, mode:AccessMode, withType:WithType, allowResolve:Bool = true):AccessKind {
		if (ctx.untypedMode) {
			return try typeFieldInner(ctx, e, i, p, mode, withType, allowResolve)
			catch (_:FieldNotFoundError) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), p));
		}
		return typeFieldInner(ctx, e, i, p, mode, withType, allowResolve);
	}

	static function typeFieldInner(ctx:TyperContext, e:TExpr, i:String, p:Position, mode:AccessMode, withType:WithType, allowResolve:Bool = true):AccessKind {
		// The field's own position is the trailing name-length slice of the access span.
		var pfield = (e.pos.file == p.file && e.pos.min == p.min && e.pos.max == p.max)
			? p : new Position(p.file, p.max - i.length, p.max);
		return switch (TypeFunctions.follow(e.type)) {
			case TInst(c, tl):
				try classFieldWithAccess(ctx, mode, e, c, tl, i, pfield) catch (_:NotFound) {
					var constrained:AccessKind = null;
					switch (c.kind) {
						case KTypeParameter(constraints):
							for (t in constraints) switch (TypeFunctions.follow(t)) {
								case TAbstract(_, _):
									try {
										constrained = typeField(ctx, TypeFunctions.mkCast(e, t, p), i, p, mode, withType);
										break;
									} catch (_:NotFound) {
									} catch (_:TypingError) {
									}
								case _:
							}
						case _:
					}
					if (constrained != null) constrained else {
						var u = tryUsing(ctx, e, i, pfield);
						if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
					}
				}
			case TAnon(a):
				switch (a.status.get()) {
					case EnumStatics(en):
						if (en.constrs.exists(i)) enumConstructor(ctx, en, e, i, pfield);
						else {
							var u = tryUsing(ctx, e, i, pfield);
							if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
						}
					case _:
						var f = a.fields.get(i);
						if (f != null) {
							if (TypeFunctions.hasClassFieldFlag(f, CfImpl) && !TypeFunctions.hasClassFieldFlag(f, CfEnum))
								throw new TypingError("Cannot access non-static abstract field statically", pfield);
							switch (a.status.get()) {
								case Statics(c): fieldAccess(ctx, mode, f, FHStatic(c), e, pfield);
								case AbstractStatics(ab) if (ab.impl != null):
									var host = (TypeFunctions.hasClassFieldFlag(f, CfImpl) || TypeFunctions.hasClassFieldFlag(f, CfEnum))
										? FHAbstract(ab, TypeFunctions.extractParamTypes(ab.params), ab.impl)
										: FHStatic(ab.impl);
									checkAbstractFieldAccess(ctx, ab, f, pfield);
									fieldAccess(ctx, mode, f, host, e, pfield);
								case _: fieldAccess(ctx, mode, f, FHAnon, e, pfield);
							}
						} else {
							switch (a.status.get()) {
								case AbstractStatics(ab) if (ab.impl != null && forwardsStaticField(ab, i)):
									try {
										var mt = TypeFunctions.moduleTypeOfType(ab.thisType);
										typeField(ctx, hxc.core.TexprTools.makeTypeExpr(mt, pfield), i, pfield, mode, withType);
									} catch (_:hxc.core.ExitException) {
										var u = tryUsing(ctx, e, i, pfield);
										if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
									}
								case _:
									var u = tryUsing(ctx, e, i, pfield);
									if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield))
									// Reaching for an instance field through the class value (Class<C>) is
									// a
									// static-access error, not a missing field.
									else switch (a.status.get()) {
										case Statics(c) if (c.fields.exists(i)):
											throw new TypingError("Static access to instance field " + i + " is not allowed", pfield);
										case _: throw fieldNotFound(e.type, i, pfield);
									}
							}
						}
				}
			case TMono(r):
				// A field access on a monomorph adds a structural down-constraint (the receiver becomes an
				// open anon with this field) unless its constraints already pin a concrete type or
				// structure.
				var isSet = mode.match(MSet(_));
				function mkUnknownField():TClassField {
					var nf = TypeFunctions.mkField(i, TypeFunctions.mkMono(), pfield, Position.nullPos);
					nf.kind = Var(new VarKind(AccNormal, isSet ? AccNormal : AccNo));
					return nf;
				}
				function checkConstr(kind:TMonoConstraintKind):AccessKind {
					return switch (kind) {
						case CStructural(fields, isOpen):
							var f = fields.get(i);
							if (f != null) {
								// A field first seen by a READ carries AccNo write access; a later WRITE on
								// an open structure promotes it to a normal write.
								switch (f.kind) {
									case Var(vk) if (isOpen && isSet && vk.write.match(AccNo)):
										f.kind = Var(new VarKind(vk.read, AccNormal));
									case _:
								}
								fieldAccess(ctx, mode, f, FHAnon, e, pfield);
							}
						else if (isOpen) {
								var nf = mkUnknownField();
								TypeUnification.addDownConstraint(r, MField(nf));
								fieldAccess(ctx, mode, nf, FHAnon, e, pfield);
							} else {
								// A CLOSED structural monomorph (e.g. bound by an intersection constraint
								// A & B) still consults the module's using extensions before failing.
								var u = tryUsing(ctx, e, i, pfield);
								if (u != null) u else throw fieldNotFound(e.type, i, pfield);
							}
						case CTypes(tl):
							var res:AccessKind = null;
							var err:Dynamic = null;
							for (tc in tl) {
								try { res = typeField(ctx, TypeFunctions.mk(e.expr, tc.t, e.pos), i, p, mode, withType); break; }
								catch (ex:NotFound) err = ex
								catch (ex:TypingError) err = ex;
							}
							if (res != null) res else throw (err != null ? err : new NotFound());
						case CUnknown:
							var seen = false;
							for (mp in ctx.monomorphs) if (mp.m == r) { seen = true; break; }
							if (!seen) ctx.monomorphs.unshift({m: r, p: p});
							var nf = mkUnknownField();
							TypeUnification.addDownConstraint(r, MField(nf));
							TypeUnification.addDownConstraint(r, MOpenStructure);
							fieldAccess(ctx, mode, nf, FHAnon, e, pfield);
						case CMixed(kinds):
							var res:AccessKind = null;
							var err:Dynamic = null;
							for (k in kinds) {
								try { res = checkConstr(k); break; }
								catch (ex:NotFound) err = ex
								catch (ex:TypingError) err = ex;
							}
							if (res != null) res else throw (err != null ? err : new NotFound());
					};
				}
				checkConstr(TypeUnification.classifyDownConstraints(r));
			case TAbstract(a, params) if (a.impl != null):
				var staticCf = a.impl.statics.get(i);
				var cf = staticCf;
				if (cf != null && !TypeFunctions.hasClassFieldFlag(cf, CfImpl)) cf = null;
				if (cf == null) {
					// The type's own using extensions win over @:forward and over the @:op(a.b) resolve fallback:
					// type_field_by_type_extension before forwarding recurses into the underlying type's
					// extensions, and AKResolve lives in the last stage (type_field_by_fallback).
					var own = tryUsingList(ctx, typeUsings(e.type, i), e, i, pfield);
					if (own != null) return own;
					// @:forward: a member not on the impl is resolved on the underlying type, which the abstract
					// wraps transparently, without the underlying's resolve fallback: the outer abstract's own
					// resolve runs first.
					if (forwardsField(a, i)) {
						var underlying = TypeFunctions.applyParams(a.params, params, a.thisType);
						// If the underlying lacks it too, fall through to a `using` extension on the
						// ORIGINAL abstract receiver: module extensions are tried on the abstract itself
						// before
						// forwarding, so an extension whose first argument is the abstract type still
						// matches.
						try {
							return typeField(ctx, TypeFunctions.mk(e.expr, underlying, e.pos), i, pfield, mode, withType, false);
						} catch (_:FieldNotFoundError) {}
					}
					var u = tryUsing(ctx, e, i, pfield);
					if (u != null) return u;
					if (allowResolve) {
						var resolveCf = switch (mode) {
							case MSet(_): a.write;
							case _: a.read;
						};
						if (resolveCf != null) {
							return AKResolve(FieldAccessTools.makeAbstractStaticExtensionAccess(a, params, a.impl, resolveCf, e, false, pfield), i);
						}
						// The underlying's resolve is the final fallback, after the own-resolve attempt.
						if (forwardsField(a, i)) {
							var underlying = TypeFunctions.applyParams(a.params, params, a.thisType);
							try {
								return typeField(ctx, TypeFunctions.mk(e.expr, underlying, e.pos), i, pfield, mode, withType);
							} catch (_:FieldNotFoundError) {}
						}
					}
					if (staticCf != null && !TypeFunctions.hasClassFieldFlag(staticCf, CfImpl))
						throw new TypingError("Invalid call to static function " + i + " through abstract instance", pfield);
					throw fieldNotFound(e.type, i, pfield);
				}
				// A property (get/set accessors) dispatches through its accessor via fieldAccess (which
				// yields AKUsingAccessor for an abstract host); other fields are a direct impl access.
				var isProp = switch (cf.kind) { case Var(vk): vk.read.match(AccCall) || vk.write.match(AccCall); case _: false; };
				checkAbstractFieldAccess(ctx, a, cf, pfield);
				if (isProp) fieldAccess(ctx, mode, cf, FHAbstract(a, params, a.impl), e, pfield);
				else AKUsingField(FieldAccessTools.makeAbstractStaticExtensionAccess(a, params, a.impl, cf, e, false, pfield));
			case TAbstract(_, _):
				var u = tryUsing(ctx, e, i, pfield);
				if (u != null) u else throw fieldNotFound(e.type, i, pfield);
			case TDynamic(_):
				// A using extension applies to a Dynamic receiver before the dynamic-field fallback
				// type_field_by_type_extension runs before type_field_by_fallback).
				var u = tryUsing(ctx, e, i, pfield);
				if (u != null) u else AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), p));
			case _:
				// A field not found on an enum or other value may come from a `using` static extension
				// (e.g. the global EnumValueTools on an enum value).
				var u = tryUsing(ctx, e, i, pfield);
				if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
		};
	}

	static function usingDoesUnify(a:T, b:T):Bool {
		// A multi-type abstract on either side goes through the abstract-cast machinery, which resolves the
		// concrete specialization before unifying (Map receiver against a StringMap parameter and vice
		// versa).
		function multi(t:T):Null<T> return switch (TypeFunctions.follow(t)) {
			case TAbstract(ab, tl) if (TypeFunctions.hasMeta(":multiType", ab.meta)):
				try TypeFunctions.follow(Typer.resolveMultiTypeConcrete(ab, tl, Position.nullPos)) catch (_:Dynamic) null;
			case _: null;
		}
		var a2 = multi(a); if (a2 != null) a = a2;
		var b2 = multi(b); if (b2 != null) b = b2;
		return try TypeUnification.withMonoRollback(function() {
			TypeUnification.unifyDefault(a, b);
			return true;
		}) catch (_:hxc.core.TypeUnification.UnifyError) false;
	}

	static function exprOfParam(t:T):Null<T> {
		return switch (t) {
			case TType(td, params) if (params.length == 1 && td.path.name == "ExprOf"):
				params[0];
			case TLazy(f):
				exprOfParam(TypeFunctions.lazyType(f));
			case _:
				null;
		}
	}

	static function isMacroExprParam(t:T):Bool {
		return switch (t) {
			case TType(td, _): td.path.name == "Expr" || td.path.name == "ExprOf";
			case TInst(c, _): c.path.name == "Expr";
			case TAbstract(a, _): a.path.name == "Expr";
			case TAnon(a):
				a.fields.exists("expr") && a.fields.exists("pos");
			case TLazy(f):
				isMacroExprParam(TypeFunctions.lazyType(f));
			case _:
				false;
		}
	}

	static function usingAccepts(cf:TClassField, recv:T, first:T):Bool {
		if (!hxc.eval.EvalMacro.isMacroField(cf))
			return usingDoesUnify(recv, first);
		var exprOf = exprOfParam(first);
		if (exprOf != null)
			return usingDoesUnify(recv, exprOf);
		if (isMacroExprParam(first))
			return true;
		return usingDoesUnify(recv, first);
	}

	// True when the abstract forwards member `name` to its underlying type: @:forward with no
	// arguments forwards everything, @:forward(a, b, ...) forwards only the listed names.
	static function forwardsField(a:TAbstract, name:String):Bool {
		return forwardsMetaField(a, name, ":forward");
	}

	static function forwardsStaticField(a:TAbstract, name:String):Bool {
		return forwardsMetaField(a, name, ":forwardStatics");
	}

	static function forwardsMetaField(a:TAbstract, name:String, meta:String):Bool {
		if (!TypeFunctions.hasMeta(meta, a.meta)) return false;
		var entry = TypeFunctions.getMeta(meta, a.meta);
		if (entry.params.length == 0) return true;
		for (pe in entry.params) switch (pe.expr) {
			case EConst(CIdent(n)) if (n == name): return true;
			case EConst(CString(s, _)) if (s == name): return true;
			case _:
		}
		return false;
	}

	// A field not found on its type may be provided by a `using` static extension whose first
	// argument accepts the receiver.
	// One static-extension class: if it declares a static `i` whose first argument accepts the receiver,
	// build the using access. Its own type parameters are monomorphized so a generic first argument
	// (e.g. Iterable<A>) can accept the receiver.
	static function tryUsingClass(ctx:TyperContext, uc:TClass, e:TExpr, i:String, p:Position):Null<AccessKind> {
		try TypeResolve.resolveModule(ctx.com, uc.module) catch (_:Dynamic) {}
		var cf0 = uc.statics.get(i);
		if (cf0 == null) return null;
		switch (cf0.type) {
			case TMono(r) if (r.type == null):
				var entry = ctx.com.declOfType.get(hxc.context.Context.pathKey(uc.path));
				if (entry != null) switch (entry.decl) {
					case EClass(d): TypeResolve.resolveClassFields(ctx.com, uc, d, entry.pos);
					case _:
				}
			case _:
		}
		// Every overload of the extension field is a candidate.
		for (cf in [cf0].concat(cf0.overloads)) {
			// An extension candidate is skipped when @:noUsing, when it is an abstract member impl, or
			// when it is not accessible from the current class.
			if (TypeFunctions.hasMeta(":noUsing", cf.meta) || TypeFunctions.hasClassFieldFlag(cf, CfImpl)) continue;
			if (!ctx.untypedMode && !canAccess(ctx, uc, cf, true)) continue;
			var cft = cf.type;
			if (cf.params.length > 0) {
				// Constrained monos so the receiver must satisfy the extension type parameter constraints
				// (e.g. sorted<T:Float> does not accept an Array<String> receiver).
				var monos = TypeUnification.spawnConstrainedMonos(function(t) return t, cf.params);
				cft = TypeFunctions.applyParams(cf.params, monos, cf.type);
			}
			switch (TypeFunctions.follow(cft)) {
				case TFun(sig) if (sig.args.length > 0 && usingAccepts(cf, e.type, sig.args[0].t)):
					return AKUsingField(FieldAccessTools.makeStaticExtensionAccess(uc, cf, e, false, p));
				case _:
			}
		}
		return null;
	}

	static function tryUsingModuleType(ctx:TyperContext, mt:ModuleType, e:TExpr, i:String, p:Position):Null<AccessKind> {
		return switch (mt) {
			case TClassDecl(uc):
				tryUsingClass(ctx, uc, e, i, p);
			case TAbstractDecl(a) if (a.impl != null):
				tryUsingClass(ctx, a.impl, e, i, p);
			case TTypeDecl(td):
				switch (TypeFunctions.follow(td.type)) {
					case TInst(uc, _): tryUsingClass(ctx, uc, e, i, p);
					case TAbstract(a, _) if (a.impl != null): tryUsingClass(ctx, a.impl, e, i, p);
					case _: null;
				}
			case _:
				null;
		};
	}

	// Compiler-wide static extensions applied to every module: haxe.EnumTools.{EnumTools, EnumValueTools}
	// (so EnumValue.getIndex / Enum.createByName resolve without an explicit `using`). .
	static var globalUsingModules = [{pack: ["haxe"], name: "EnumTools"}];
	static var macroToolsUsingModules = [
		{pack: ["haxe", "macro"], name: "ExprTools"},
		{pack: ["haxe", "macro"], name: "ComplexTypeTools"},
		{pack: ["haxe", "macro"], name: "TypeTools"},
		{pack: ["haxe", "macro"], name: "MacroStringTools"},
		{pack: ["haxe", "macro"], name: "TypedExprTools"},
		{pack: ["haxe", "macro"], name: "PositionTools"}
	];

	static function isMacroToolsUsing(path:hxc.core.Globals.Path):Bool {
		return path.pack.length == 2 && path.pack[0] == "haxe" && path.pack[1] == "macro" && path.name == "Tools";
	}

	static function tryUsingList(ctx:TyperContext, usings:Array<TClassUsing>, e:TExpr, i:String, p:Position):Null<AccessKind> {
		for (u in usings) {
			var r = tryUsingClass(ctx, u.c, e, i, p);
			if (r != null) return r;
		}
		return null;
	}

	static function tryUsing(ctx:TyperContext, e:TExpr, i:String, p:Position):Null<AccessKind> {
		var own = tryUsingList(ctx, typeUsings(e.type, i), e, i, p);
		if (own != null) return own;
		var m = ctx.com.currentModule;
		var imports = m == null ? null : ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports != null) {
			// A later using declaration takes priority: the reference prepends each using onto
			// module_using, so lookup runs in reverse declaration order .
			var ups = imports.usings.copy();
			ups.reverse();
			for (up in ups) {
				// `using pack.Module` (no subtype) brings in every non-private type of the module as a
				// static extension, not just the main type. filters isPrivate from md.types; getType returns
				// only the main type, missing sibling extension classes (Issue5231/Issue7142). A subtype using
				// (pack.Module.Sub) fails to load as a module and falls back to the single-type getType path
				// below.
				var um = try hxc.context.ModuleLoader.loadModule(ctx.com, up, p) catch (_:Dynamic) null;
				if (um != null) {
					// filter_classes reverses the module type list (last-declared type wins), so scan
					// types back-to-front.
					var uts = um.types.copy();
					uts.reverse();
					for (mt in uts) {
						if (TypeFunctions.tInfos(mt).isPrivate) continue;
						var r = tryUsingModuleType(ctx, mt, e, i, p);
						if (r != null) return r;
					}
					continue;
				}
				var mt = try ctx.com.getType(up, p, null) catch (_:Dynamic) null;
				if (mt != null) {
					var r = tryUsingModuleType(ctx, mt, e, i, p);
					if (r != null) return r;
				} else if (isMacroToolsUsing(up)) {
					for (toolPath in macroToolsUsingModules) {
						var tool = try ctx.com.getType(toolPath, p, null) catch (_:Dynamic) null;
						if (tool == null) continue;
						var r = tryUsingModuleType(ctx, tool, e, i, p);
						if (r != null) return r;
					}
				}
			}
		}
		// Global usings applied to every module. (ctx.g.global_using after module_using).
		for (gp in globalUsingModules) {
			var gm = try hxc.context.ModuleLoader.loadModule(ctx.com, gp, p) catch (_:Dynamic) null;
			if (gm == null) continue;
			for (mt in gm.types) switch (mt) {
				case TClassDecl(uc):
					var r = tryUsingClass(ctx, uc, e, i, p);
					if (r != null) return r;
				case TAbstractDecl(a) if (a.impl != null):
					var r = tryUsingClass(ctx, a.impl, e, i, p);
					if (r != null) return r;
				case _:
			}
		}
		return null;
	}

	// The type-own using list is collected on the UNFOLLOWED type: a typedef contributes its own
	// @:using before the type it aliases, one follow step at a time.
	static function typeUsings(t:T, i:String):Array<TClassUsing> {
		return switch (t) {
			case TMono(r): r.type == null ? [] : typeUsings(r.type, i);
			case TLazy(f): typeUsings(TypeFunctions.lazyType(f), i);
			case TType(td, tl): td.usings.concat(typeUsings(TypeFunctions.applyParams(td.params, tl, td.type), i));
			case TInst(c, _): collectClassUsings(c, []);
			case TEnum(e, _): e.usings;
			case TAbstract(a, [t1]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				// Null is unwrapped before the extension walk.
				typeUsings(t1, i);
			case TAbstract(a, tl) if (forwardAllows(a, i) && !TypeFunctions.hasMeta(":coreType", a.meta)):
				// @:forward abstracts also expose the underlying type's usings.
				a.usings.concat(typeUsings(TypeFunctions.applyParams(a.params, tl, a.thisType), i));
			case TAbstract(a, _): a.usings;
			case TAnon(a): switch (a.status.get()) {
				case Statics(c): c.usings;
				case EnumStatics(e): e.usings;
				case AbstractStatics(a): a.usings;
				case _: [];
			}
			case _: [];
		};
	}

	// @:forward with arguments only forwards the named fields.
	static function forwardAllows(a:TAbstract, i:String):Bool {
		for (meta in a.meta) {
			if (meta.name != ":forward") continue;
			if (meta.params.length == 0) return true;
			for (param in meta.params) switch (param.expr) {
				case EConst(CIdent(n)) if (n == i): return true;
				case EConst(CString(n, _)) if (n == i): return true;
				case _:
			}
			return false;
		}
		return false;
	}

	// A class inherits @:using from its base classes and interfaces: own usings first, then
	// super, then each interface, recursively so a grandparent/base-interface @:using still
	// reaches the leaf type.
	static function collectClassUsings(c:TClass, acc:Array<TClassUsing>):Array<TClassUsing> {
		for (u in c.usings) acc.push(u);
		if (c.superClass != null) collectClassUsings(c.superClass.c, acc);
		for (impl in c.interfaces) collectClassUsings(impl.c, acc);
		return acc;
	}

	public static function enumConstructor(ctx:TyperContext, en:TEnum, e:TExpr, i:String, p:Position):AccessKind {
		var ef = en.constrs.get(i);
		if (ef == null) throw fieldNotFound(e.type, i, p);
		var monos = [for (_ in en.params) TypeFunctions.mkMono()];
		var t = TypeFunctions.applyParams(en.params, monos, ef.type);
		if (ef.params.length > 0) {
			var monos2 = [for (_ in ef.params) TypeFunctions.mkMono()];
			t = TypeFunctions.applyParams(ef.params, monos2, t);
		}
		return AKExpr(TypeFunctions.mk(TField(e, FEnum(en, ef)), t, p));
	}
}

class FieldNotFoundError extends TypingError {
}
