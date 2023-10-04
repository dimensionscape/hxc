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
	static function checkFieldAccess(ctx:TyperContext, c:TClass, f:TClassField, p:Position):Void {
		if (!ctx.untypedMode && !TypeFunctions.hasClassFieldFlag(f, CfPublic) && !TypeFunctions.extendsClass(ctx.curclass, c))
			throw new TypingError("Cannot access private field " + f.name, p);
	}

	static function checkAbstractFieldAccess(ctx:TyperContext, a:TAbstract, f:TClassField, p:Position):Void {
		if (a.impl != null && TypeFunctions.hasClassFieldFlag(f, CfImpl))
			checkFieldAccess(ctx, a.impl, f, p);
	}

	public static function fieldAccess(ctx:TyperContext, mode:AccessMode, f:TClassField, fh:FieldHost, e:TExpr, pfield:Position):AccessKind {
		var pfull = Position.union(e.pos, pfield);
		var isSet = mode.match(MSet(_));
		forceFieldType(ctx, f, fh);
		switch (fh) {
			case FHStatic(c):
				switch (c.kind) {
					case KAbstractImpl(_):
						checkFieldAccess(ctx, c, f, pfield);
					case _:
				}
			case _:
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
									if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
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
				if (cf != null && !TypeFunctions.hasClassFieldFlag(cf, CfImpl)) cf = null;
				if (cf == null) {
					var resolveCf = switch (mode) {
						case MSet(_): a.write;
						case _: a.read;
					};
					if (resolveCf != null) {
						return AKResolve(FieldAccessTools.makeAbstractStaticExtensionAccess(a, params, a.impl, resolveCf, e, false, pfield), i);
					}
					// @:forward: a member not on the impl is resolved on the underlying type, which the
					// abstract wraps transparently.
					if (forwardsField(a, i)) {
						var underlying = TypeFunctions.applyParams(a.params, params, a.thisType);
						return typeField(ctx, TypeFunctions.mk(e.expr, underlying, e.pos), i, pfield, mode, withType);
					}
					var u = tryUsing(ctx, e, i, pfield);
					if (u != null) return u;
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
				if (u != null) u else throw new TypingError("Abstract field access is not yet ported", p);
			case TDynamic(_):
				AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), p));
			case _:
				// A field not found on an enum or other value may come from a `using` static extension
				// (e.g. the global EnumValueTools on an enum value).
				var u = tryUsing(ctx, e, i, pfield);
				if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), TDynamic(null), pfield)) else throw fieldNotFound(e.type, i, pfield);
		};
	}

	static function usingDoesUnify(a:T, b:T):Bool {
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
		var cf = uc.statics.get(i);
		if (cf == null) return null;
		switch (cf.type) {
			case TMono(r) if (r.type == null):
				var entry = ctx.com.declOfType.get(hxc.context.Context.pathKey(uc.path));
				if (entry != null) switch (entry.decl) {
					case EClass(d): TypeResolve.resolveClassFields(ctx.com, uc, d, entry.pos);
					case _:
				}
			case _:
		}
		var cft = cf.type;
		if (cf.params.length > 0) {
			var monos:TParams = [for (_ in cf.params) TypeFunctions.mkMono()];
			cft = TypeFunctions.applyParams(cf.params, monos, cf.type);
		}
		return switch (TypeFunctions.follow(cft)) {
			case TFun(sig) if (sig.args.length > 0 && usingAccepts(cf, e.type, sig.args[0].t)):
				AKUsingField(FieldAccessTools.makeStaticExtensionAccess(uc, cf, e, false, p));
			case _: null;
		};
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

	static function tryUsing(ctx:TyperContext, e:TExpr, i:String, p:Position):Null<AccessKind> {
		for (u in typeUsings(e.type)) {
			var r = tryUsingClass(ctx, u.c, e, i, p);
			if (r != null) return r;
		}
		var m = ctx.com.currentModule;
		var imports = m == null ? null : ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports != null) {
			for (up in imports.usings) {
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

	static function typeUsings(t:T):Array<TClassUsing> {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _): c.usings;
			case TEnum(e, _): e.usings;
			case TType(td, _): td.usings;
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
