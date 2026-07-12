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
	public static function canAccess(ctx:TyperContext, c:TClass, cf:TClassField, stat:Bool, forcePrivate:Bool = false):Bool {
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
							else throw new NotFound("Fields.hx:90");
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
	public static function checkFieldAccess(ctx:TyperContext, c:TClass, f:TClassField, stat:Bool, p:Position):Void {
		if (!ctx.untypedMode && !canAccess(ctx, c, f, stat)) {
			var msg = "Cannot access private field " + f.name;
			for (d in ctx.com.diagnostics) if (d.message == msg && d.pos.file == p.file && d.pos.min == p.min && d.pos.max == p.max) return;
			ctx.com.addDiagnostic(msg, p);
		}
	}

	static function checkAbstractFieldAccess(ctx:TyperContext, a:TAbstract, f:TClassField, p:Position):Void {
		if (a.impl != null && TypeFunctions.hasClassFieldFlag(f, CfImpl))
			checkFieldAccess(ctx, a.impl, f, true, p);
	}

	// Recorded (not raised) so typing continues; a missing constructor is left to the caller (a null
	// constructor is handled there).
	public static function checkConstructorAccess(ctx:TyperContext, c:TClass, f:TClassField, p:Position):Void {
		// A constructor the compiler wrote (@:structInit) is not one the source may call. It is recorded
		// rather than raised, so the call goes on to report its arguments too.
		if (TypeFunctions.hasMeta(":compilerGenerated", f.meta))
			ctx.com.addDiagnostic(hxc.core.Globals.sTypePath(c.path) + " does not have a constructor", p);
		if (!ctx.untypedMode && !(canAccess(ctx, c, f, true) || TypeFunctions.extendsClass(ctx.curclass, c))) {
			// An abstract impl reports the abstract's path.
			var path = switch (c.kind) { case KAbstractImpl(a): a.path; case _: c.path; };
			ctx.com.addDiagnostic("Cannot access private constructor of " + hxc.core.Globals.sTypePath(path), p);
		}
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
		// A method read as a value whose inferred return is still an open monomorph has not had its
		// body typed. Force it so the return (and the argument monos it settles) bind from the body,
		// not from the first use site that would bind them to Dynamic.
		if (!mode.match(MCall(_)) && f.expr == null && f.kind.match(Method(_))) {
			var retOpen = switch (TypeFunctions.follow(TypeFields.fieldCallType(f))) {
				case TFun(sig): TypeFunctions.follow(sig.ret).match(TMono(_));
				case _: false;
			};
			if (retOpen) switch (fh) {
				case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c): TypeFields.forceFieldBody(ctx.com, c, f);
				case FHAnon:
			}
		}
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
		// Hxia profile mask: a masked std member used without its capability atom is an error.
		hxc.hxia.CapabilityMask.check(ctx, fh, f.name, pfield);
		// Each field access consumes one @:bypassAccessor from the pending count.
		var bypassAccessor = if (ctx.bypassAccessor > 0) { ctx.bypassAccessor--; true; } else false;
		// An access is inline only where inlining is allowed (ctx.allowInline).
		function makeAccess(isInline:Bool):FieldAccess {
			return FieldAccessTools.create(e, f, fh, isInline && ctx.allowInline, pfull);
		}
		switch [f.kind, fh, e.expr] {
			case [Var(v), FHInstance(_, _), TConst(TSuper)]:
				switch (mode) {
					case MGet | MCall(_) if (v.read == AccCall):
					case MSet(_) if (v.write == AccCall):
					case _:
						ctx.com.addDiagnostic("Normal variables cannot be accessed with 'super', use 'this' instead", pfield);
				}
			case _:
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
						// A method READ rather than called. A macro cannot be a value at all, and neither can a
						// @:generic function. Both are recorded and the access is built anyway.
						if (mode.match(MGet) && !m.match(MethInline)) {
							if (m.match(MethMacro))
								ctx.com.addDiagnostic("Macro functions must be called immediately", pfield);
							else if (TypeFunctions.hasClassFieldFlag(f, CfGeneric))
								ctx.com.addDiagnostic("Cannot create closure on generic function", pfield);
						}
						// And `super.f` read as a value rather than called.
						if (fh.match(FHInstance(_, _)) && e.expr.match(TConst(TSuper)) && !mode.match(MCall(_)))
							ctx.com.addDiagnostic("Cannot create closure on super method", pfield);
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
						hxc.filters.DeprecationCheck.checkPropertyUse(ctx, f, pfield);
						AKField(makeAccess(true));
					// A property access the display position is on does not resolve to its accessor - it stays a
					// plain field access to the property itself, which is the declaration the request is asking
					// about, not the getter's. The same holds with transforms off (Context.withOptions).
					case AccCall if (!ctx.allowTransform || hxc.typing.Typer.atDisplayPos(pfull)):
						AKField(makeAccess(false));
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
							// Both are recorded, and the access carries on as a plain field access.
							// Inside a pattern probe the first lands in the probed span and aborts the
							// probe, which is
							// why the hint does not double up there.
							if (!TypeFunctions.isPhysicalField(f)) {
								ctx.com.addDiagnostic("This field cannot be accessed because it is not a real variable", pfield);
								ctx.com.addDiagnostic("Add @:isVar here to enable it", f.pos);
							}
							AKField(makeAccess(false));
						} else {
							hxc.filters.DeprecationCheck.checkPropertyUse(ctx, f, pfield);
							switch (fh) {
								// A static access to a member property (already reported) has no receiver to thread; the
								// plain accessor call then reports its own missing-this error.
								case FHAbstract(_, _, _) if (e.expr.match(TTypeExpr(_))):
									AKAccessor(makeAccess(false));
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
		// The APPLIED type prints, with a suggestion over the type's own field names. It is the
		// plain printed type, so a function type keeps its signature, and it prints UNFOLLOWED, so
		// an alias keeps its own name (`Iterator<Int>`, not the anon it stands for).
		var msg = hxc.core.TPrinting.sTypeStr(t) + " has no field " + i;
		if (i != "") {
			var names:Array<String> = switch (TypeFunctions.follow(t)) {
				case TInst(c, _):
					var acc = [];
					var cur = c;
					while (cur != null) {
						for (cf in cur.orderedFields) acc.push(cf.name);
						cur = cur.superClass == null ? null : cur.superClass.c;
					}
					acc;
				case TAnon(an): [for (cf in an.fields) cf.name];
				case TAbstract(a, _) if (a.impl != null): [for (cf in a.impl.orderedStatics) cf.name];
				case _: [];
			};
			msg = hxc.core.StringError.stringError(i, names, msg);
		}
		return new FieldNotFoundError(msg, p);
	}

	// A field access that did not resolve, in a run whose job is to REPORT, records the field the
	// code implies - its name, the type the context wants and the kind the access mode implies -
	// so the report can offer to create it.
	// Exit means there is nothing usable to describe and nothing is recorded.
	/**
			LOAD the bare name and compare. The same path back is Imported, a different one Shadowed,
			and a name that will not load at all is Unimported - the synthesized argument type
			`Class<Std>` is one.
	*/
	static function getImportStatus(ctx:TyperContext, path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus {
		var mt = try hxc.context.ModuleLoader.loadTypeDef(ctx.com, {pack: [], name: path.name}, Position.nullPos)
			catch (_:Dynamic) null;
		if (mt == null) return Unimported;
		var got = TypeFunctions.tInfos(mt).path;
		return got.name == path.name && got.pack.join(".") == path.pack.join(".") ? Imported : Shadowed;
	}

	public static function handleMissingFieldRaise(ctx:TyperContext, tthis:T, i:String, mode:AccessMode,
			withType:WithType, pfield:Position):Void {
		// This check comes first: outside a diagnostics run nothing below runs, and in particular the
		// call's arguments are not typed here to describe the missing method - the call types them
		// itself, and typing them twice would report a bad argument twice.
		if (!ctx.com.errorInDiagnosticsRun(pfield)) return;
		// Hxc threads a call's withType into the access, because its enum resolution reads the
		// expectation there. That has to stop at this reading: a call target is described as typed
		// against a plain value. Left as NoValue, the MCall arm below would bind the synthesized method's
		// return type to Void instead of leaving a free monomorph, and the report would describe a method
		// the user has not written yet as returning Void.
		var wt = mode.match(MCall(_)) ? WithTypeTools.value : withType;
		// The RETURN type: what is expected, a fresh monomorph for a plain value, and for a
		// NoValue access whatever the assigned expression turns out to be.
		var tret:Null<T> = switch (wt) {
			case WithType(t, _): t;
			case Value(_): TypeFunctions.mkMono();
			case NoValue: switch (mode) {
				case MCall(_): ctx.com.basic.tvoid;
				case MSet(e) if (e != null):
					try Typer.typeExpr(ctx, e, WithTypeTools.value).type catch (_:Dynamic) return;
				case _: return;
			};
		};
		// The field type and KIND: a call implies a method taking the arguments written, a read a
		// read-only var, a write a settable one.
		var t:T, kind:FieldKind;
		switch (mode) {
			case MCall(el):
				var args:Array<hxc.core.Type.TSignatureArg> = [];
				for (idx in 0...el.length) {
					var name = Expr.findIdent(el[idx]);
					var te = try Typer.typeExpr(ctx, el[idx], WithTypeTools.value) catch (_:Dynamic) return;
					args.push({name: name != null ? name : "arg" + idx, opt: false, t: te.type});
				}
				t = TFun({args: args, ret: tret}); kind = Method(MethNormal);
			case MGet:
				t = tret; kind = Var({read: AccNormal, write: AccNo});
			case MSet(_):
				t = tret; kind = Var({read: AccNormal, write: AccNormal});
		}
		var cf = TypeFunctions.mkField(i, t, pfield, Position.nullPos, false, false);
		cf.meta = [{name: ":compilerGenerated", params: [], pos: Position.nullPos},
			{name: ":noCompletion", params: [], pos: Position.nullPos}];
		cf.kind = kind;
		// WHERE the field would go, and whether it has to be public to be reachable from here.
		var mt:Null<ModuleType> = null;
		var scope = hxc.core.Type.ClassFieldScope.CFSMember;
		var isPublic = true;
		switch (TypeFunctions.follow(tthis)) {
			case TInst(c, _): mt = TClassDecl(c); isPublic = !canAccess(ctx, c, cf, false);
			case TEnum(en, _): mt = TEnumDecl(en);
			case TAbstract(a, _): mt = TAbstractDecl(a);
			case TAnon(an): switch (an.status.get()) {
				case Statics(c): mt = TClassDecl(c); scope = CFSStatic; isPublic = !canAccess(ctx, c, cf, true);
				case EnumStatics(en): mt = TEnumDecl(en); scope = CFSStatic;
				case AbstractStatics(a): mt = TAbstractDecl(a); scope = CFSStatic;
				case _: return;
			}
			case _: return;
		}
		if (isPublic) TypeFunctions.addClassFieldFlag(cf, CfPublic);
		if (scope == CFSStatic) TypeFunctions.addClassFieldFlag(cf, CfStatic);
		// The conversion happens here, with the record. This site is only reached in a diagnostics run
		// (the errorInDiagnosticsRun check at the call site), so it cannot disturb an ordinary compile.
		var ct = hxc.core.CompletionItem.CompletionTypeTools.fromType(
			function(path) return getImportStatus(ctx, path), t);
		ctx.com.missingFields.push({pos: pfield, on: mt, scope: scope,
			fields: [{cf: cf, t: t, ct: ct}], cause: "FieldAccess"});
	}

	// A bare name that did not resolve is a missing field of the enclosing STATICS in a static
	// function, and of `this` otherwise.
	public static function handleMissingIdent(ctx:TyperContext, i:String, mode:AccessMode,
			withType:WithType, p:Position):Void {
		if (ctx.curclass == null) return;
		var tthis = switch (ctx.curfun) {
			// makeStaticThis: the STATICS anon of the enclosing class.
			case FunStatic: hxc.core.TexprTools.makeTypeExpr(TClassDecl(ctx.curclass), p).type;
			case _: ctx.tthis;
		};
		try handleMissingFieldRaise(ctx, tthis, i, mode, withType, p) catch (_:Dynamic) {}
	}

	// Once no strategy answers, the verdict is recorded and the access recovers as a dynamic field
	// over a fresh monomorph, so typing goes on - a call's arguments are still typed after a bad
	// callee, and `Q.a(Q.b())` reports both. Only a `resume` site gets the not-found error back
	// instead: the for-loop iterator probes and dot-path resolution, and hxc's own probes - the
	// abstract forward and constraint walks, the accessor lookups, the dot-path chains, the iterator
	// shapes - since they catch the raise to try something else.
	public static function notFound(ctx:TyperContext, e:TExpr, i:String, p:Position, pfield:Position, mode:AccessMode, withType:WithType, resume:Bool):AccessKind {
		var err = fieldNotFound(e.type, i, pfield);
		if (resume) throw err;
		if (!ctx.untypedMode) {
			// Records what a diagnostics run can offer to create; Exit means nothing, and the plain
			// verdict follows either way.
			try handleMissingFieldRaise(ctx, e.type, i, mode, withType, pfield) catch (_:Dynamic) {}
			ctx.com.addDiagnostic(err.message, pfield);
		}
		return AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), Typer.spawnMonomorph(ctx, p), p));
	}

	public static function typeField(ctx:TyperContext, e:TExpr, i:String, p:Position, mode:AccessMode, withType:WithType, allowResolve:Bool = true, resume:Bool = false):AccessKind {
		if (hxc.core.PerfCount.on) hxc.core.PerfCount.bump("typeField");
		if (ctx.untypedMode) {
			return try typeFieldInner(ctx, e, i, p, mode, withType, allowResolve, resume)
			// The untyped fallback is a dynamic field of a fresh monomorph's type.
			catch (_:FieldNotFoundError) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), Typer.spawnMonomorph(ctx, p), p));
		}
		return typeFieldInner(ctx, e, i, p, mode, withType, allowResolve, resume);
	}

	// Every FDynamic access is built at `p`, the full field position; the name slice `pfield` serves
	// only for error reporting. An `untyped b.field` access therefore starts with its receiver and
	// does not become a separate source map segment.
	static function typeFieldInner(ctx:TyperContext, e:TExpr, i:String, p:Position, mode:AccessMode, withType:WithType, allowResolve:Bool = true, resume:Bool = false):AccessKind {
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
										constrained = typeField(ctx, TypeFunctions.mkCast(e, t, p), i, p, mode, withType, true, true);
										break;
									} catch (_:NotFound) {
									} catch (_:TypingError) {
									}
								case _:
							}
						case _:
					}
					if (constrained != null) constrained else {
						var u = tryUsing(ctx, e, i, p);
						if (u != null) u else {
							// The TInst fallback. It runs after the using extensions, so a matching extension still
							// wins. A class declaring `implements Dynamic<T>` reads any unknown field at T; the
							// declaration is inherited, so the walk continues up superClass.
							var dynT:Null<T> = null;
							var cur = c, curTl = tl;
							while (cur != null) {
								if (cur.dynamicType != null) {
									dynT = TypeFunctions.applyParams(cur.params, curTl, cur.dynamicType);
									break;
								}
								if (cur.superClass == null) break;
								curTl = [for (st in cur.superClass.params) TypeFunctions.applyParams(cur.params, curTl, st)];
								cur = cur.superClass.c;
							}
							if (dynT != null) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), dynT, p));
							// Naming a static through an instance is its own message, and it is checked on the class the
							// receiver has, not on the superclass the dynamic walk ended at.
							else if (c.statics.exists(i))
								throw new TypingError("Cannot access static field " + i + " from a class instance", pfield);
							else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), Typer.spawnMonomorph(ctx, p), p))
							else notFound(ctx, e, i, p, pfield, mode, withType, resume);
						}
					}
				}
			case TAnon(a):
				switch (a.status.get()) {
					case EnumStatics(en):
						// An enum constructor access is built at `p`, the full field position,
						// so it collapses with its own type expression into one source map segment.
						if (en.constrs.exists(i)) enumConstructor(ctx, en, e, i, p);
						else {
							var u = tryUsing(ctx, e, i, p);
							if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), Typer.spawnMonomorph(ctx, p), p)) else notFound(ctx, e, i, p, pfield, mode, withType, resume);
						}
					case _:
						var f = a.fields.get(i);
						if (f != null) {
							// Recorded, not raised: resolution continues and the accessor call then
							// reports its own missing-this error.
							if (TypeFunctions.hasClassFieldFlag(f, CfImpl) && !TypeFunctions.hasClassFieldFlag(f, CfEnum))
								ctx.com.addDiagnostic("Cannot access non-static abstract field statically", pfield);
							switch (a.status.get()) {
								case Statics(c):
									// A field the compiler synthesized under a name of its own (a promoted
									// static local) cannot
									// be named in source.
									if (TypeFunctions.hasClassFieldFlag(f, CfNoLookup))
										ctx.com.addDiagnostic("This field cannot be accessed explicitly", pfield);
									fieldAccess(ctx, mode, f, FHStatic(c), e, pfield);
								case _: fieldAccess(ctx, mode, f, FHAnon, e, pfield);
							}
						} else {
							switch (a.status.get()) {
								// The implementation class's statics forward under @:forwardStatics.
								case Statics({kind: KAbstractImpl(ab)}) if (forwardsStaticField(ab, i)):
									// The underlying type expression is built with p and the lookup re-enters typeField, which
									// raises on a miss (so the forwarded access keeps the full span, not the name slice, and a
									// miss is the ORIGINAL receiver's: `Abstract<F> has no field`, at the field).
									var fwd:Null<AccessKind> = try {
										var mt = TypeFunctions.moduleTypeOfType(ab.thisType);
										typeField(ctx, hxc.core.TexprTools.makeTypeExpr(mt, p), i, p, mode, withType, true, true);
									} catch (_:hxc.core.ExitException) null catch (_:FieldNotFoundError) null;
									if (fwd != null) fwd
									else {
										var u = tryUsing(ctx, e, i, p);
										if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), Typer.spawnMonomorph(ctx, p), p)) else notFound(ctx, e, i, p, pfield, mode, withType, resume);
									}
								case _:
									var u = tryUsing(ctx, e, i, p);
									if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), Typer.spawnMonomorph(ctx, p), p))
									// Reaching for an instance field through the class value (Class<C>) is
									// a
									// static-access error, not a missing field.
									else switch (a.status.get()) {
										case Statics(c) if (c.fields.exists(i)):
											// This is REPORTED, and the access falls through to a dynamic
											// access over a fresh
											// monomorph. Raising instead would let the failure reach
											// unifyCallArgs, which appends
											// "... For function argument 'v'" - a decoration that does not
											// belong here, because the
											// monomorph unifies and the call never fails.
											ctx.com.addDiagnostic("Static access to instance field " + i + " is not allowed", pfield);
											AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), Typer.spawnMonomorph(ctx, p), p));
										case _: notFound(ctx, e, i, p, pfield, mode, withType, resume);
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
					// This one is built at `p`, the whole field-access expression, not at the name:
					// `untyped
					// o.toString` records `o.toString`, which is what --json prints for the synthetic field
					// a
					// monomorph picks up.
					var nf = TypeFunctions.mkField(i, TypeFunctions.mkMono(), p, Position.nullPos);
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
								var u = tryUsing(ctx, e, i, p);
								if (u != null) u else notFound(ctx, e, i, p, pfield, mode, withType, resume);
							}
						case CTypes(tl):
							var res:AccessKind = null;
							var err:Dynamic = null;
							for (tc in tl) {
								try { res = typeField(ctx, TypeFunctions.mk(e.expr, tc.t, e.pos), i, p, mode, withType, true, true); break; }
								catch (ex:NotFound) err = ex
								catch (ex:TypingError) err = ex;
							}
							if (res != null) res else throw (err != null ? err : new NotFound());
						case CUnknown:
							// Only the current function's monomorph list is asked: a monomorph an enclosing function
							// registered is registered again here, and closes when this function ends.
							var seen = false;
							for (i in 0...ctx.monomorphs.length - ctx.monoFunctionStart) if (ctx.monomorphs[i].m == r) { seen = true; break; }
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
					// they are tried before forwarding recurses into the underlying type's extensions, and
					// AKResolve is the last stage. As at the tryUsing sites, a static extension access is built at
					// the full field position. This is the `@:using(...)` on the type's own list.
					var own = tryUsingList(ctx, typeUsings(e.type, i), e, i, p);
					if (own != null) return own;
					// @:forward: a member not on the impl is resolved on the underlying type, which the abstract
					// wraps transparently, without the underlying's resolve fallback: the outer abstract's own
					// resolve runs first.
					if (forwardsField(a, i)) {
						// The guarded traversal raises "Abstract chain detected" on a recursive
						// underlying chain.
						var underlying = TypeFunctions.getUnderlyingTypeFirst(a, params);
						// If the underlying lacks it too, fall through to a `using` extension on the
						// ORIGINAL abstract receiver: module extensions are tried on the abstract itself
						// before
						// forwarding, so an extension whose first argument is the abstract type still
						// matches.
						try {
							// The field lookup gets a receiver CAST to the underlying type; only the cs
							// target retypes
							// the node in place. The cast is observable: it makes an inlined abstract
							// member see a Cast
							// rather than a plain local, so the receiver binds a temp instead of
							// substituting.
							var recv = ctx.com.platform.match(Cs)
								? TypeFunctions.mk(e.expr, underlying, e.pos)
								: TypeFunctions.mk(TCast(e, null), underlying, e.pos);
							return typeField(ctx, recv, i, pfield, mode, withType, false, true);
						} catch (_:FieldNotFoundError) {}
					}
					var u = tryUsing(ctx, e, i, p);
					if (u != null) return u;
					if (allowResolve) {
						var resolveCf = switch (mode) {
							case MSet(_): a.write;
							case _: a.read;
						};
						if (resolveCf != null) {
							// Force the resolve method's body so an inferred return settles from the body
							// (return f -> String) before the resolve call unifies it with the expected
							// type.
							if (resolveCf.expr == null) TypeFields.forceFieldBody(ctx.com, a.impl, resolveCf);
							// The resolve access is built at the full field position, not the name slice.
							return AKResolve(FieldAccessTools.makeAbstractStaticExtensionAccess(a, params, a.impl, resolveCf, e, false, p), i);
						}
						// The underlying's resolve is the final fallback, after the own-resolve attempt.
						if (forwardsField(a, i)) {
							var underlying = TypeFunctions.applyParams(a.params, params, a.thisType);
							try {
								return typeField(ctx, TypeFunctions.mk(e.expr, underlying, e.pos), i, pfield, mode, withType, true, true);
							} catch (_:FieldNotFoundError) {}
						}
					}
					if (staticCf != null && !TypeFunctions.hasClassFieldFlag(staticCf, CfImpl))
						throw new TypingError("Invalid call to static function " + i + " through abstract instance", pfield);
					return notFound(ctx, e, i, p, pfield, mode, withType, resume);
				}
				// A property (get/set accessors) dispatches through its accessor via fieldAccess (which
				// yields AKUsingAccessor for an abstract host); other fields are a direct impl access.
				var isProp = switch (cf.kind) { case Var(vk): vk.read.match(AccCall) || vk.write.match(AccCall); case _: false; };
				checkAbstractFieldAccess(ctx, a, cf, pfield);
				if (isProp) fieldAccess(ctx, mode, cf, FHAbstract(a, params, a.impl), e, pfield);
				// The access is built at the union of the receiver's position and the field name's; the
				// name
				// slice alone would make the callee a separate source map segment from its own receiver.
				else AKUsingField(FieldAccessTools.makeAbstractStaticExtensionAccess(a, params, a.impl, cf, e, false, Position.union(e.pos, pfield)));
			case TAbstract(_, _):
				var u = tryUsing(ctx, e, i, p);
				if (u != null) u else notFound(ctx, e, i, p, pfield, mode, withType, resume);
			case TDynamic(dt):
				// A using extension applies to a Dynamic receiver before the dynamic-field fallback.
				// A field on Dynamic<T> reads at T, plain Dynamic otherwise.
				var u = tryUsing(ctx, e, i, p);
				if (u != null) u else AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), dt == null ? TypeFunctions.tDynamic : dt, p));
			case _:
				// A field not found on an enum or other value may come from a `using` static extension
				// (e.g. the global EnumValueTools on an enum value).
				var u = tryUsing(ctx, e, i, p);
				if (u != null) u else if (ctx.untypedMode) AKExpr(TypeFunctions.mk(TField(e, FDynamic(i)), Typer.spawnMonomorph(ctx, p), p)) else notFound(ctx, e, i, p, pfield, mode, withType, resume);
		};
	}

	// A @:multiType abstract on EITHER side goes through the abstract-cast machinery, whose first step
	// is a type-equality check - and that is what binds the extension's own type parameter from the
	// receiver. Resolving a concrete specialization first cannot work: `Map<Unknown<0>, Float>` has
	// nothing to specialize on, so a `Map<String, Float>` receiver would match no candidate at all.
	// Returns the receiver, cast to the extension's first argument when a @:multiType abstract is
	// involved (and that expression is what the access carries), else unchanged once it unifies. Null
	// when it does not.
	static function usingDoesUnify(ctx:TyperContext, e:TExpr, t:T, p:Position):Null<TExpr> {
		function isMulti(t:T):Bool return switch (TypeFunctions.follow(t)) {
			case TAbstract(ab, _): TypeFunctions.hasMeta(":multiType", ab.meta);
			case _: false;
		}
		var a = e.type;
		var b = t;
		if (isMulti(a) || isMulti(b)) {
			return try TypeUnification.withMonoRollback(function() {
				return Typer.castOrUnifyRaise(ctx, b, e, p);
			}) catch (_:hxc.core.TypeUnification.UnifyError) null
			catch (_:TypingError) null;
		}
		// The receiver never coerces through Dynamic to claim an extension (allowDynamicToCast =
		// false).
		return try TypeUnification.withMonoRollback(function() {
			TypeUnification.unify({
				allowTransitiveCast: true,
				allowAbstractCast: true,
				allowDynamicToCast: false,
				equalityKind: hxc.core.TypeUnification.EqKind.EqStrict,
				equalityUnderlying: false
			}, a, b);
			return e;
		}) catch (_:hxc.core.TypeUnification.UnifyError) null;
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

	static function usingAccepts(ctx:TyperContext, cf:TClassField, e:TExpr, first:T, p:Position):Null<TExpr> {
		// A Dynamic receiver only takes extensions whose first argument is exactly Dynamic: Dynamic
		// unifies with anything, so a String-first extension would otherwise claim any dynamic field
		// access.
		switch (TypeFunctions.follow(e.type)) {
			case TDynamic(null):
				switch (TypeFunctions.follow(first)) {
					case TDynamic(null):
					case _: return null;
				}
			case _:
		}
		if (!hxc.eval.EvalMacro.isMacroField(cf))
			return usingDoesUnify(ctx, e, first, p);
		var exprOf = exprOfParam(first);
		if (exprOf != null)
			return usingDoesUnify(ctx, e, exprOf, p);
		if (isMacroExprParam(first))
			return e;
		return usingDoesUnify(ctx, e, first, p);
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
		var isMacroPackage = uc.path.pack.length == 2 && uc.path.pack[0] == "haxe" && uc.path.pack[1] == "macro";
		if (!isMacroPackage) try TypeResolve.resolveModule(ctx.com, uc.module) catch (_:Dynamic) {}
		var cf0 = uc.statics.get(i);
		if (cf0 == null) return null;
		if (!isMacroPackage) switch (cf0.type) {
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
				case TFun(sig) if (sig.args.length > 0):
					var er = usingAccepts(ctx, cf, e, sig.args[0].t, p);
					if (er != null) return AKUsingField(FieldAccessTools.makeStaticExtensionAccess(uc, cf, er, false, p));
				case _:
			}
		}
		return null;
	}

	// A field completion also offers every `using` static whose first argument accepts the receiver,
	// listed with that argument dropped and with @:noUsing / @:noCompletion / an abstract impl member
	// skipped. The acceptance test is the same resolution the call path runs, one name at a time, so
	// nothing is offered that would not actually resolve.
	public static function collectUsingFields(ctx:TyperContext, e:TExpr, p:Position, add:TClassField->T->Void):Void {
		if (TypeFunctions.follow(e.type).match(TMono(_))) return;
		var seenClasses:Array<TClass> = [];
		function tryClass(uc:Null<TClass>):Void {
			if (uc == null || seenClasses.indexOf(uc) >= 0) return;
			seenClasses.push(uc);
			for (cf in uc.orderedStatics) {
				if (TypeFunctions.hasMeta(":noUsing", cf.meta) || TypeFunctions.hasMeta(":noCompletion", cf.meta)) continue;
				if (TypeFunctions.hasClassFieldFlag(cf, CfImpl)) continue;
				var ok = try tryUsingClass(ctx, uc, e, cf.name, p) != null catch (_:Dynamic) false;
				if (!ok) continue;
				// Over `f :: f.overloads` and handles each one: the candidate is whichever accepts the receiver
				// as its first argument, which is not necessarily the main field. An overload set's main field
				// can be the ZERO-argument one, and reading only that offered the field nowhere at all.
				for (o in [cf].concat(cf.overloads)) {
					var t = switch (o.type) { case TLazy(r): TypeFunctions.lazyType(r); case t2: t2; };
					// The receiver is unified against the first argument of a copy whose own type
					// parameters
					// are fresh monos, so the reported signature carries the bindings that unification made
					// (K becomes String, not K).
					if (o.params.length > 0) {
						var monos = TypeUnification.spawnConstrainedMonos(function(x) return x, o.params);
						t = TypeFunctions.applyParams(o.params, monos, t);
					}
					var matched = false;
					switch (TypeFunctions.follow(t)) {
						case TFun(sig) if (sig.args.length > 0):
							// The same acceptance test the call path uses: a plain unify is stricter and drops the
							// Map-receiver-against-StringMap-parameter cases.
							if (usingAccepts(ctx, o, e, sig.args[0].t, p) != null) {
								add(cf, TFun({args: sig.args.slice(1), ret: sig.ret}));
								matched = true;
							}
						case _:
					}
					if (matched) break;
				}
			}
		}
		function tryModuleType(mt:ModuleType):Void switch (mt) {
			case TClassDecl(uc): tryClass(uc);
			case TAbstractDecl(a) if (a.impl != null): tryClass(a.impl);
			case TTypeDecl(td): switch (TypeFunctions.follow(td.type)) {
					case TInst(uc, _): tryClass(uc);
					case TAbstract(a, _) if (a.impl != null): tryClass(a.impl);
					case _:
				}
			case _:
		}
		// loop_module_using, the type's own @:using, then the module's, then global.
		for (u in typeUsings(e.type, "")) tryClass(u.c);
		var m = ctx.com.currentModule;
		var imports = m == null ? null : ctx.com.moduleImports.get(hxc.context.Context.pathKey(m.path));
		if (imports != null) {
			var ups = imports.usings.copy();
			ups.reverse();
			for (up in ups) {
				var um = try hxc.context.ModuleLoader.loadModule(ctx.com, up, p) catch (_:Dynamic) null;
				if (um != null) {
					var uts = um.types.copy();
					uts.reverse();
					for (mt in uts) if (!TypeFunctions.tInfos(mt).isPrivate) tryModuleType(mt);
					continue;
				}
				var mt = try ctx.com.getType(up, p, null) catch (_:Dynamic) null;
				if (mt != null) tryModuleType(mt);
				else if (isMacroToolsUsing(up)) for (toolPath in macroToolsUsingModules) {
					var tool = try ctx.com.getType(toolPath, p, null) catch (_:Dynamic) null;
					if (tool != null) tryModuleType(tool);
				}
			}
		}
		for (gp in globalUsingModules) {
			var gm = try hxc.context.ModuleLoader.loadModule(ctx.com, gp, p) catch (_:Dynamic) null;
			if (gm != null) for (mt in gm.types) tryModuleType(mt);
		}
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
	static var globalUsingModules:Array<hxc.core.Globals.Path> = [{pack: ["haxe"], name: "EnumTools"}];
	static var macroToolsUsingModules:Array<hxc.core.Globals.Path> = [
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

	// The classes one `using` contributes, as module_using holds them - a module's statics class and
	// non-private types (a typedef resolved, an abstract its impl) last-declared first
	// (filter_classes), or the single named type.
	public static function usingClasses(com:hxc.context.Context, up:hxc.core.Globals.Path, p:Position):Array<TClass> {
		var out:Array<TClass> = [];
		function add(mt:ModuleType):Void switch (TypeFunctions.resolveTypedef(mt)) {
			case TClassDecl(c): out.unshift(c);
			case TAbstractDecl(a) if (a.impl != null): out.unshift(a.impl);
			case _:
		}
		var um = try hxc.context.ModuleLoader.loadModule(com, up, p) catch (_:Dynamic) null;
		if (um != null) {
			if (um.statics != null) add(TClassDecl(um.statics));
			for (mt in um.types) if (!TypeFunctions.tInfos(mt).isPrivate) add(mt);
			return out;
		}
		var mt = try com.getType(up, p, null) catch (_:Dynamic) null;
		if (mt != null) add(mt);
		return out;
	}

	static function tryUsingList(ctx:TyperContext, usings:Array<TClassUsing>, e:TExpr, i:String, p:Position):Null<AccessKind> {
		for (u in usings) {
			var r = tryUsingClass(ctx, u.c, e, i, p);
			if (r != null) return r;
		}
		return null;
	}

	// The static extension receiver is unified and the access built at `p`, the full field position,
	// not at the name slice, so a `using` call such as `field.access.has(AFinal)` starts with its own
	// receiver and shares its map segment.
	static function tryUsing(ctx:TyperContext, e:TExpr, i:String, p:Position):Null<AccessKind> {
		// A `super` receiver of a class type rewrites to `cast this` (fresh mono inside, the
		// receiver's type outside), so the extension call passes `this` with an explicit upcast that
		// survives to the generators (cpp emits `( (Foo)(this) )`).
		switch ([TypeFunctions.follow(e.type), e.expr]) {
			case [TInst(_, _), TConst(TSuper)]:
				e = TypeFunctions.mk(TCast(TypeFunctions.mk(TConst(TThis), TypeFunctions.mkMono(), e.pos), null), e.type, e.pos);
			case _:
		}
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
						if (r != null) { imports.markUsing(up); return r; }
					}
					continue;
				}
				var mt = try ctx.com.getType(up, p, null) catch (_:Dynamic) null;
				if (mt != null) {
					var r = tryUsingModuleType(ctx, mt, e, i, p);
					if (r != null) { imports.markUsing(up); return r; }
				} else if (isMacroToolsUsing(up)) {
					for (toolPath in macroToolsUsingModules) {
						var tool = try ctx.com.getType(toolPath, p, null) catch (_:Dynamic) null;
						if (tool == null) continue;
						var r = tryUsingModuleType(ctx, tool, e, i, p);
						if (r != null) { imports.markUsing(up); return r; }
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
				// A @:forward abstract also exposes its underlying type's usings, one guarded
				// step at a time; the guarded traversal raises on a recursive chain.
				a.usings.concat(typeUsings(TypeFunctions.getUnderlyingTypeFirst(a, tl), i));
			case TAbstract(a, _): a.usings;
			// A statics anon maps back to its class, enum or abstract. An abstract's own @:using stays on
			// the abstract, so the Statics anon of its implementation offers none of it.
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
				// The scan stops at the first name that matches, so an argument that is neither an identifier
				// nor a string is only reported once an earlier one has not already answered.
				case EConst(CIdent(_)) | EConst(CString(_, _)):
				case _: throw new TypingError("Identifier or string expected as argument to @:forward", param.pos);
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
		var monos = TypeUnification.spawnConstrainedMonos(function(t) return t, en.params);
		var t = TypeFunctions.applyParams(en.params, monos, ef.type);
		if (ef.params.length > 0) {
			var monos2 = TypeUnification.spawnConstrainedMonos(function(t2) return TypeFunctions.applyParams(en.params, monos, t2), ef.params);
			t = TypeFunctions.applyParams(ef.params, monos2, t);
		}
		return AKExpr(TypeFunctions.mk(TField(e, FEnum(en, ef)), t, p));
	}
}

class FieldNotFoundError extends TypingError {
}
