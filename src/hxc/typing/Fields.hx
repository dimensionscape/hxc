package hxc.typing;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.NotFound;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;

class Fields {
	public static function fieldAccess(ctx:TyperContext, mode:AccessMode, f:TClassField, fh:FieldHost, e:TExpr, pfield:Position):AccessKind {
		var pfull = Position.union(e.pos, pfield);
		var isSet = mode.match(MSet(_));
		forceFieldType(ctx, f, fh);
		// Each field access consumes one @:bypassAccessor from the pending count.
		var bypassAccessor = if (ctx.bypassAccessor > 0) { ctx.bypassAccessor--; true; } else false;
		function makeAccess(isInline:Bool):FieldAccess {
			return FieldAccessTools.create(e, f, fh, isInline, pfull);
		}
		return switch (f.kind) {
			case Method(m):
				if (isSet && !m.match(MethDynamic) && !ctx.untypedMode)
					throw new TypingError("Cannot rebind this method : please use 'dynamic' before method declaration", pfield);
				switch (fh) {
					case FHAbstract(a, tl, c):
						AKUsingField(FieldAccessTools.makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, pfull));
					case _:
						AKField(makeAccess(false));
				}
			case Var(vk):
				var acc = isSet ? vk.write : vk.read;
				switch (acc) {
					case AccNormal | AccNo | AccNever | AccCtor:
						AKField(makeAccess(false));
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
						} else switch (fh) {
							case FHAbstract(a, tl, c):
								AKUsingAccessor(FieldAccessTools.makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, pfull));
							case _:
								AKAccessor(makeAccess(false));
						}
					case AccRequire(r, msg):
						throw new TypingError(msg != null ? msg : ("Field " + f.name + " is not available"), pfield);
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
		var monos:TParams = [for (_ in f.params) TypeFunctions.mkMono()];
		return TypeFunctions.applyParams(c.params, tl, TypeFunctions.applyParams(f.params, monos, f.type));
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
		return new TypingError(typeName(t) + " has no field " + i, p);
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

	public static function typeField(ctx:TyperContext, e:TExpr, i:String, p:Position, mode:AccessMode, withType:WithType):AccessKind {
		var pfield = p;
		return switch (TypeFunctions.follow(e.type)) {
			case TInst(c, tl):
				try classFieldWithAccess(ctx, mode, e, c, tl, i, pfield) catch (_:NotFound) {
					var u = tryUsing(ctx, e, i, pfield);
					if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
				}
			case TAnon(a):
				switch (a.status.get()) {
					case EnumStatics(en): enumConstructor(ctx, en, e, i, pfield);
					case _:
						var f = a.fields.get(i);
						if (f != null) {
							switch (a.status.get()) {
								case Statics(c): fieldAccess(ctx, mode, f, FHStatic(c), e, pfield);
								case AbstractStatics(ab) if (ab.impl != null):
									var host = (TypeFunctions.hasClassFieldFlag(f, CfImpl) || TypeFunctions.hasClassFieldFlag(f, CfEnum))
										? FHAbstract(ab, TypeFunctions.extractParamTypes(ab.params), ab.impl)
										: FHStatic(ab.impl);
									fieldAccess(ctx, mode, f, host, e, pfield);
								case _: fieldAccess(ctx, mode, f, FHAnon, e, pfield);
							}
						} else {
							var u = tryUsing(ctx, e, i, pfield);
							if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
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
							if (f != null) fieldAccess(ctx, mode, f, FHAnon, e, pfield);
							else if (isOpen) {
								var nf = mkUnknownField();
								TypeUnification.addDownConstraint(r, MField(nf));
								fieldAccess(ctx, mode, nf, FHAnon, e, pfield);
							} else throw fieldNotFound(e.type, i, pfield);
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
				var cf = a.impl.statics.get(i);
				if (cf == null) {
					var u = tryUsing(ctx, e, i, pfield);
					if (u != null) return u;
					throw fieldNotFound(e.type, i, pfield);
				}
				// A property (get/set accessors) dispatches through its accessor via fieldAccess (which
				// yields AKUsingAccessor for an abstract host); other fields are a direct impl access.
				var isProp = switch (cf.kind) { case Var(vk): vk.read.match(AccCall) || vk.write.match(AccCall); case _: false; };
				if (isProp) fieldAccess(ctx, mode, cf, FHAbstract(a, params, a.impl), e, pfield);
				else AKUsingField(FieldAccessTools.makeAbstractStaticExtensionAccess(a, params, a.impl, cf, e, false, pfield));
			case TAbstract(_, _):
				var u = tryUsing(ctx, e, i, pfield);
				if (u != null) u else throw new TypingError("Abstract field access is not yet ported", p);
			case TDynamic(_):
				AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), p));
			case _:
				if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
		};
	}

	static function usingDoesUnify(a:T, b:T):Bool {
		return try { hxc.core.TypeUnification.unifyDefault(a, b); true; } catch (_:hxc.core.TypeUnification.UnifyError) false;
	}

	// A field not found on its type may be provided by a `using` static extension whose first
	// argument accepts the receiver.
	static function tryUsing(ctx:TyperContext, e:TExpr, i:String, p:Position):Null<AccessKind> {
		var m = ctx.com.currentModule;
		if (m == null) return null;
		var imports = ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports == null) return null;
		for (up in imports.usings) {
			var mt = try ctx.com.getType(up, p, null) catch (_:Dynamic) null;
			if (mt == null) continue;
			switch (mt) {
				case TClassDecl(uc):
					try TypeResolve.resolveModule(ctx.com, TypeFunctions.tInfos(mt).module) catch (_:Dynamic) {}
					var cf = uc.statics.get(i);
					if (cf == null) continue;
					// Monomorphize the extension method's own type parameters so a generic first argument
					// (e.g. Iterable<A>) can accept the receiver.
					var cft = cf.type;
					if (cf.params.length > 0) {
						var monos:TParams = [for (_ in cf.params) TypeFunctions.mkMono()];
						cft = TypeFunctions.applyParams(cf.params, monos, cf.type);
					}
					switch (TypeFunctions.follow(cft)) {
						case TFun(sig) if (sig.args.length > 0 && usingDoesUnify(e.type, sig.args[0].t)):
							return AKUsingField(FieldAccessTools.makeStaticExtensionAccess(uc, cf, e, false, p));
						case _:
					}
				case _:
			}
		}
		return null;
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
