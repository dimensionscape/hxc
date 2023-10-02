package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.NotFound;
import hxc.core.TypeUnification;
import hxc.core.Ref;
import hxc.context.Context;
import hxc.context.Context.ContextError;
import haxe.ds.StringMap;

class TypeResolve {
	static final pNull = Position.nullPos;

	public static function resolveModule(ctx:Context, m:ModuleDef):Void {
		if (m.extra.processed >= 1) return;
		m.extra.processed = 1;
		var savedMod = ctx.currentModule;
		ctx.currentModule = m; // Resolve in-module sibling types against m.types first
		for (mt in m.types) {
			var info = TypeFunctions.tInfos(mt);
			var entry = ctx.declOfType.get(Context.pathKey(info.path));
			if (entry == null) continue; // Synthetic types (e.g. _Fields_, enum module-type) have no decl
			try {
				resolveType(ctx, mt, entry.decl, entry.pos);
			} catch (_:Dynamic) {
				ctx.currentModule = m;
			}
		}
		for (mt in m.types) resolveUsingMetadata(ctx, mt);
		ctx.currentModule = savedMod;
	}

	/**
	 * Resolve all loaded modules currently in the Context.
	 */
	public static function resolveAll(ctx:Context):Void {
		// Snapshot: resolution may load more modules (which append to ctx.modules).
		var i = 0;
		while (i < ctx.modules.length) {
			resolveModule(ctx, ctx.modules[i]);
			i++;
		}
	}

	static function resolveType(ctx:Context, mt:ModuleType, decl:TypeDef, p:Position):Void {
		switch ([mt, decl]) {
			case [TClassDecl(c), EClass(d)]:
				resolveClass(ctx, c, d, p);
			case [TAbstractDecl(a), EAbstract(d)]:
				resolveAbstract(ctx, a, d, p);
			case [TTypeDecl(td), ETypedef(d)]:
				resolveTypedef(ctx, td, d, p);
			case [TEnumDecl(e), EEnum(d)]:
				resolveEnum(ctx, e, d, p);
			case _:
				// Mismatch / unsupported (EStatic module-fields class, etc.), skip.
		}
	}

	static function resolveUsingMetadata(ctx:Context, mt:ModuleType):Void {
		var info = TypeFunctions.tInfos(mt);
		for (meta in info.meta) {
			if (meta.name != ":using") continue;
			for (param in meta.params) {
				var parts = exprPath(param);
				if (parts == null || parts.length == 0) continue;
				var path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
				var used = try ctx.getType(path, param.pos, null) catch (_:Dynamic) null;
				var usingClass = switch (used) {
					case TClassDecl(c): c;
					case TAbstractDecl(a) if (a.impl != null): a.impl;
					case _: null;
				}
				if (usingClass != null) addUsing(mt, usingClass, param.pos);
			}
		}
	}

	static function exprPath(e:Expr):Null<Array<String>> {
		return switch (e.expr) {
			case EConst(CIdent(s)): [s];
			case EField(e1, f, _):
				var pre = exprPath(e1);
				pre == null ? null : pre.concat([f]);
			case _: null;
		};
	}

	static function addUsing(mt:ModuleType, c:TClass, p:Position):Void {
		var u = {c: c, pos: p};
		switch (mt) {
			case TClassDecl(c2):
				c2.usings.unshift(u);
			case TEnumDecl(e):
				e.usings.unshift(u);
			case TTypeDecl(t):
				t.usings.unshift(u);
			case TAbstractDecl(a):
				a.usings.unshift(u);
		}
	}

	public static function resolveClass(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		// Pass 1: heritage. Filter HExtends/HImplements; load each type; set relations.
		for (f in d.dFlags) switch (f) {
			case HExtends(pt):
				var t = Typeload.loadInstance(ctx, c.params, pt.path, pt.pos, false, false);
				checkHerit(ctx, c, t, true, pt.pos);
			case HImplements(pt):
				var t = Typeload.loadInstance(ctx, c.params, pt.path, pt.pos, false, false);
				checkHerit(ctx, c, t, false, pt.pos);
			case _:
		}
		resolveClassFields(ctx, c, d, p);
	}

	// Resolve only the field signatures of an already-heritage-resolved class. A @:build macro
	// rewrites the field list but not the heritage, so it re-runs this without redoing extends.
	public static function resolveClassFields(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		var nameSeen = new haxe.ds.StringMap<Int>();
		// ABSTRACT-IMPL promotion: on a KAbstractImpl class a non-static field is registered as a static
		// (abstract member). Mirror that when locating the registered cf so the enum-abstract `var X`
		// members (syntactically non-static) are found in statics.
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var abstractTypeParams = switch (c.kind) {
			case KAbstractImpl(a): a.params;
			case _: null;
		};
		for (cff in d.dData) {
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			var isAbstractMember = isAbsImpl && !isStatic && cff.cffName.name != "new";
			if (isAbstractMember) isStatic = true;
			// The constructor lives in constructor (not fields); resolve it there.
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(cff.cffName.name);
			if (cf == null) continue;
			var key = (isStatic ? "s:" : "i:") + cff.cffName.name;
			var occ = nameSeen.exists(key) ? nameSeen.get(key) : 0;
			nameSeen.set(key, occ + 1);
			// Occurrence > 0 is a merged overload sibling: resolve onto its overloads slot.
			var target = if (occ > 0 && cf.overloads.length >= occ) cf.overloads[cf.overloads.length - occ] else cf;
			if (isAbstractMember) TypeFunctions.addClassFieldFlag(target, CfImpl);
			try {
				var params = if (isAbsImpl && abstractTypeParams != null && TypeFunctions.hasClassFieldFlag(target, CfImpl))
					abstractTypeParams
				else
					c.params;
				resolveFieldType(ctx, params, target, cff);
			} catch (e:ContextError) {
				ctx.unresolvedFields++;
			}
		}
		linkPropertyAccessors(c, isAbsImpl);
	}

	// Bind each property accessor signature to the property's declared type: an unannotated get_/set_
	// return or value argument would otherwise be a free monomorph that can unify with an unrelated sibling
	// type during inference. accessor checks.
	static function linkPropertyAccessors(c:TClass, isAbsImpl:Bool):Void {
		function usePropertyType(slot:T, pt:T):Void {
			switch (TypeFunctions.follow(slot)) {
				case TMono(r) if (r.type == null):
					TypeUnification.monoBind(r, pt);
				case _:
					try TypeUnification.unifyDefault(slot, pt) catch (_:Dynamic) {};
			}
		}
		function loop(fields:StringMap<TClassField>):Void {
			for (name in fields.keys()) {
				var cf = fields.get(name);
				var pt = cf.type;
				if (pt == null) continue;
				switch (cf.kind) {
					case Var(vk):
						if (vk.read.match(AccCall)) {
							var g = fields.get("get_" + name);
							if (g != null) switch (TypeFunctions.follow(g.type)) {
								case TFun(sig): usePropertyType(sig.ret, pt);
								case _:
							}
						}
						if (vk.write.match(AccCall)) {
							var st = fields.get("set_" + name);
							if (st != null) switch (TypeFunctions.follow(st.type)) {
								case TFun(sig):
									if (sig.args.length > 0) usePropertyType(sig.args[sig.args.length - 1].t, pt);
									usePropertyType(sig.ret, pt);
								case _:
							}
						}
					case _:
				}
			}
		}
		loop(c.statics);
		if (!isAbsImpl) loop(c.fields);
	}

	static function checkHerit(ctx:Context, c:TClass, t:T, isExtends:Bool, p:Position):Void {
		if (isExtends) {
			if (c.superClass != null) throw new ContextError("Cannot extend several classes", p);
			switch (TypeFunctions.follow(t)) {
				case TInst(csup, params):
					if (TypeFunctions.hasClassFlag(c, CInterface)) {
						if (!TypeFunctions.hasClassFlag(csup, CInterface))
							throw new ContextError("Cannot extend by using a class", p);
						c.interfaces.push({c: csup, params: params});
						// Record `c` as a descendant of its
						// inheritance tree downward (keep overrides of reachable base methods).
						TypeFunctions.addDescendant(csup, c);
					} else {
						if (TypeFunctions.hasClassFlag(csup, CInterface))
							throw new ContextError("Cannot extend by using an interface", p);
						c.superClass = {c: csup, params: params};
						TypeFunctions.addDescendant(csup, c);
					}
				case _:
					throw new ContextError("Should extend by using a class", p);
			}
		} else {
			switch (TypeFunctions.follow(t)) {
				// Extern ArrayAccess<T> special-case (e.g. String implements ArrayAccess).
				case TInst(ca, [pt]) if (ca.path.pack.length == 0 && ca.path.name == "ArrayAccess" && TypeFunctions.hasClassFlag(ca, CExtern)):
					if (c.arrayAccess != null) throw new ContextError("Duplicate array access", p);
					c.arrayAccess = pt;
				case TInst(intf, params):
					if (TypeFunctions.hasClassFlag(c, CInterface))
						throw new ContextError("Interfaces cannot implement another interface (use extends instead)", p);
					if (!TypeFunctions.hasClassFlag(intf, CInterface))
						throw new ContextError("You can only implement an interface", p);
					c.interfaces.push({c: intf, params: params});
					TypeFunctions.addDescendant(intf, c);
				case TDynamic(dt):
					if (c.dynamicType != null) throw new ContextError("Cannot have several dynamics", p);
					c.dynamicType = (dt == null) ? TypeFunctions.tDynamic : dt;
				case _:
					throw new ContextError("Should implement by using an interface", p);
			}
		}
	}

	static function resolveAbstract(ctx:Context, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>, p:Position):Void {
		var isCore = TypeFunctions.hasMeta(":coreType", a.meta);
		var isType = false; // Set true once an underlying (AbOver) is seen

		function loadType(th:TypeHint):T {
			return Typeload.loadComplexType(ctx, a.params, th);
		}

		for (f in d.dFlags) switch (f) {
			case AbFrom(th): a.from.push(loadType(th));
			case AbTo(th): a.to.push(loadType(th));
			case AbOver(th):
				if (isCore) throw new ContextError("@:coreType abstracts cannot have an underlying type", p);
				var at = Typeload.loadComplexType(ctx, a.params, th);
				a.thisType = at;
				isType = true;
			case AbExtern:
			case AbPrivate | AbEnum:
		}

		if (!isType) {
			if (isCore)
				a.thisType = TAbstract(a, TypeFunctions.extractParamTypes(a.params));
			else
				throw new ContextError("Abstract is missing underlying type declaration", a.pos);
		}

		// At PBuildModule timing, when `kind = KAbstractImpl a &&
		// (where `thisType` is now resolved, so the Int/String/Other mode can be decided) over the
		// FVar; then re-register + re-resolve the impl fields so the new shape takes effect.
		if (a.isEnum && a.impl != null) {
			buildEnumAbstractFields(ctx, a, d, p);
		}

		resolveAbstractCasts(ctx, a, d);

		if (a.impl != null) {
			var implEntry = ctx.declOfType.get(Context.pathKey(a.impl.path));
			switch (implEntry != null ? implEntry.decl : null) {
				case EClass(impl):
					resolveClassFields(ctx, a.impl, impl, p);
				case _:
			}
		}

		resolveAbstractOps(ctx, a, d);

	}

	static function resolveAbstractOps(ctx:Context, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>):Void {
		if (a.impl == null) return;
		var c = a.impl;
		a.ops = [];
		a.unops = [];
		a.array = [];
		for (cff in d.dData) {
			// Locate the impl cf (member -> promoted static; static -> static). Resolve it up front: both
			// the @:op arms and the @:arrayAccess arm need it.
			var cf = abstractImplField(c, cff.cffName.name);
			if (cf == null) continue;
			if (TypeFunctions.hasMeta(":arrayAccess", cff.cffMeta)) {
				a.array.push(cf);
				continue;
			}
			// The @:op meta survives transformAbstractField (it concats f.cffMeta), so read it off
			// the SOURCE field and resolve the matching impl cf by name. A member @:op was promoted
			// to a static abstract member; a `static` @:op stays a static too.
			if (!TypeFunctions.hasMeta(":op", cff.cffMeta)) continue;
			var meta = TypeFunctions.getMeta(":op", cff.cffMeta);
			// @:op takes exactly one expression param: an EBinop, EUnop, EArrayDecl ([]),
			// ECall, EField, or ETernary.
			if (meta.params.length != 1) continue;
			var opExpr = meta.params[0];
			switch (opExpr.expr) {
				// `@:op([])` (EArrayDecl) -> array (same arm as the
				// @:arrayAccess meta handled above).
				case EArrayDecl(_):
					a.array.push(cf);
				// Assignment / null-coalescing / ternary overloads
				// are explicitly rejected.
				case EBinop(OpAssign, _, _):
					throw new ContextError("Assignment overloading is not supported", opExpr.pos);
				case EBinop(OpNullCoal, _, _) | EBinop(OpAssignOp(OpNullCoal), _, _):
					throw new ContextError("Null coalescing overloading is not supported", opExpr.pos);
				case ETernary(_, _, _):
					throw new ContextError("Ternary overloading is not supported", opExpr.pos);
				case EBinop(op, _, _):
					a.ops.push({op: op, cf: cf});
				// `@:op(unop A)` / `@:op(A unop)`: register
				// (op, flag, cf) in unops.
				case EUnop(op, flag, _):
					a.unops.push({op: op, flag: flag, cf: cf});
				// `@:op(a)` call overload. The first method
				// becomes `call`; later ones are prepended as overloads of that field.
				case ECall(_, _):
					if (a.call == null)
						a.call = cf;
					else
						a.call.overloads.unshift(cf);
				case EField(_, _, _):
					registerResolveField(a, cf, cff, opExpr.pos);
				case _:
			}
		}
	}

	static function abstractImplField(c:TClass, name:String):Null<TClassField> {
		var cf = c.statics.get(name);
		if (cf == null) cf = c.fields.get(name);
		if (cf != null && TypeFunctions.hasClassFieldFlag(cf, CfExtern)) {
			var native = nativeImplField(c, name);
			if (native != null) return native;
		}
		return cf;
	}

	static function nativeImplField(c:TClass, name:String):Null<TClassField> {
		for (fieldName in c.statics.keys()) {
			var cf = c.statics.get(fieldName);
			if (!TypeFunctions.hasClassFieldFlag(cf, CfExtern) && nativeFieldName(cf) == name) return cf;
		}
		for (fieldName in c.fields.keys()) {
			var cf = c.fields.get(fieldName);
			if (!TypeFunctions.hasClassFieldFlag(cf, CfExtern) && nativeFieldName(cf) == name) return cf;
		}
		return null;
	}

	static function nativeFieldName(cf:TClassField):Null<String> {
		return try {
			var meta = TypeFunctions.getMeta(":native", cf.meta);
			switch (meta.params.length > 0 ? meta.params[0].expr : null) {
				case EConst(CString(s, _)): s;
				case _: null;
			}
		} catch (_:NotFound) null;
	}

	static function registerResolveField(a:TAbstract, cf:TClassField, cff:ClassField, p:Position):Void {
		switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig) if (sig.args.length == 2):
				if (a.read != null) throw new ContextError("Multiple resolve-read methods are not supported", p);
				a.read = cf;
			case TFun(sig) if (sig.args.length == 3):
				if (a.write != null) throw new ContextError("Multiple resolve-write methods are not supported", p);
				a.write = cf;
			case _:
				throw new ContextError("Field type of resolve must be " + cff.cffName.name + " -> String -> T", p);
		}
	}

	// Resolve the @:from / @:to cast methods of an abstract into fromField / toField.
	// Check_abstract (the @:from / @:to arms): build a
	static function resolveAbstractCasts(ctx:Context, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>):Void {
		for (cff in d.dData) {
			var isFrom = TypeFunctions.hasMeta(":from", cff.cffMeta);
			var isTo = TypeFunctions.hasMeta(":to", cff.cffMeta);
			if (!isFrom && !isTo) continue;
			// A @:from/@:to method declared without `static` is an abstract member. check_abstract turns it
			// into an _Impl_ static with `this:thisType` prepended hxc defers full _Impl_ synthesis, so we
			// model that `this`-prepend here so the type has the leading arg
			// unifiesToField/unifiesFromField expect (TFun((_,_,ta)::_,_)).
			var isStatic = false;
			var isMacro = false;
			for (acc in cff.cffAccess) switch (acc.access) { case AStatic: isStatic = true; case AMacro: isMacro = true; case _: }
			var isAbstractMember = !isStatic;
			switch (cff.cffKind) {
				case FFun(fd):
					// Method-local type params + abstract params in scope for the signature.
					var methodParams:TypeParams = [];
					var localParams = a.params;
					if (fd.fParams.length > 0) {
						methodParams = Typeload.typeTypeParams(ctx, {pack: [], name: cff.cffName.name}, fd.fParams);
						localParams = methodParams.concat(a.params);
					}
					var args:Array<TSignatureArg> = [];
					// For an abstract member cast, the underlying `this:thisType` is the first arg of the
					// synthesized static impl (the receiver the cast converts from/relates).
					if (isAbstractMember) args.push({name: "this", opt: false, t: a.thisType});
					for (fa in fd.fArgs) {
						var at = Typeload.loadTypeHint(ctx, localParams, fa.type, false);
						if (fa.opt) at = ctx.basic.tnull(at);
						args.push({name: fa.name.name, opt: fa.opt || fa.value != null, t: at});
					}
					var ret = Typeload.loadTypeHint(ctx, localParams, fd.fType, false);
					var ft = TFun({args: args, ret: ret});
					var cf = TypeFunctions.mkField(cff.cffName.name, ft, cff.cffPos, cff.cffName.pos, true, true);
					cf.meta = cff.cffMeta;
					cf.kind = Method(isMacro ? MethMacro : MethInline);
					cf.params = methodParams;
					// Abstract-impl field flag (check_abstract sets CfImpl on @:to fields).
					TypeFunctions.addClassFieldFlag(cf, CfImpl);
					if (isFrom) {
						// @:from: stored type = the single (non-`this`/non-PosInfos) argument type i.e. the value
						// being converted into the abstract. For a member @:from
						var fromIdx = isAbstractMember ? 1 : 0;
						if (args.length > fromIdx) a.fromField.push({t: args[fromIdx].t, cf: cf});
					}
					if (isTo) {
						// @:to: stored type = the return type (concrete specialization).
						a.toField.push({t: ret, cf: cf});
					}
				case _:
			}
		}
	}

	static function buildEnumAbstractFields(ctx:Context, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>, p:Position):Void {
		var c = a.impl;
		// At: the abstract self-type hint,
		// `CTPath(pack.Name<params>)`. Built from a.path so loadComplexType resolves it back to
		// this abstract.
		var aTParams:Array<TypeParamOrConst> = [
			for (tp in d.dParams) TPType({ct: CTPath({tpackage: [], tname: tp.tpName.name, tparams: [], tsub: null}), pos: p})
		];
		var aT:TypeHint = {ct: CTPath({tpackage: a.path.pack, tname: a.path.name, tparams: aTParams, tsub: null}), pos: p};
		hxc.context.ModuleLoader.buildEnumAbstract(ctx.basic, a, aT, d.dData);
		// Member-var objects are the same references we just mutated, so they now carry the
		// static-inline-`@:enum` shape. Rebuild statics/fields/cl_ordered_* from it.
		var implEntry = ctx.declOfType.get(Context.pathKey(c.path));
		var implFields:Array<ClassField> = switch (implEntry != null ? implEntry.decl : null) {
			case EClass(impl): impl.dData;
			case _: null;
		};
		if (implFields == null) return;
		hxc.context.ModuleLoader.rebuildFields(c, implFields);
		for (cff in implFields) {
			var isStatic = false;
			for (acc in cff.cffAccess) if (acc.access == AStatic) isStatic = true;
			// Abstract-impl promotion (see resolveClass): a non-static impl field is a static.
			if (!isStatic && cff.cffName.name != "new") isStatic = true;
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(cff.cffName.name);
			if (cf == null) continue;
			try {
				resolveFieldType(ctx, c.params, cf, cff);
				if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) {
					cf.type = TAbstract(a, TypeFunctions.extractParamTypes(a.params));
				}
			} catch (e:ContextError) {
				ctx.unresolvedFields++;
			}
		}
	}

	static function resolveTypedef(ctx:Context, td:TDef, d:Definition<EnumFlag, TypeHint>, p:Position):Void {
		var tt = Typeload.loadComplexType(ctx, td.params, d.dData);
		switch (td.type) {
			case TMono(r) if (r.type == null):
				r.type = tt;
			case _:
				td.type = tt;
		}
	}

	public static function forceResolveTypedef(ctx:Context, td:TDef):Bool {
		switch (td.type) {
			case TMono(r) if (r.type == null):
			case _: return true; // Already resolved
		}
		var entry = ctx.declOfType.get(Context.pathKey(td.path));
		if (entry == null) return false;
		switch (entry.decl) {
			case ETypedef(d):
				var savedMod = ctx.currentModule;
				ctx.currentModule = td.module;
				try { resolveTypedef(ctx, td, d, entry.pos); } catch (_:Dynamic) {}
				ctx.currentModule = savedMod;
			case _:
		}
		return switch (td.type) { case TMono(r) if (r.type == null): false; case _: true; };
	}

	static function loadMacroHint(ctx:Context, typeParams:TypeParams, th:Null<TypeHint>):T {
		var exprPath:TypePath = {tpackage: ["haxe", "macro"], tname: "Expr", tparams: [], tsub: null};
		if (th == null) {
			return Typeload.loadInstance(ctx, typeParams, exprPath, hxc.ast.Position.nullPos, false);
		}
		switch (th.ct) {
			case CTPath(tp):
				var isExprOf =
					(tp.tpackage.length == 2 && tp.tpackage[0] == "haxe" && tp.tpackage[1] == "macro"
						&& tp.tname == "Expr" && tp.tsub == "ExprOf")
					|| (tp.tpackage.length == 0 && tp.tname == "ExprOf" && tp.tsub == null);
				if (isExprOf)
					return Typeload.loadInstance(ctx, typeParams, exprPath, th.pos, false);
			case _:
		}
		return Typeload.loadTypeHint(ctx, typeParams, th, false);
	}

	static function resolveEnum(ctx:Context, e:TEnum, d:Definition<EnumFlag, Array<EnumConstructor>>, p:Position):Void {
		// The enum self-type, with its declared params applied.
		var et = TEnum(e, TypeFunctions.extractParamTypes(e.params));
		var index = 0;
		for (c in d.dData) {
			// Constructor-local type params (e.g. `enum E { C<T>(x:T); }`) in scope.
			var ctorParams:TypeParams = [];
			if (c.ecParams.length > 0)
				ctorParams = Typeload.typeTypeParams(ctx, {pack: [], name: c.ecName.name}, c.ecParams);
			var localParams = ctorParams.concat(e.params);
			var t:T = if (c.ecArgs.length == 0) {
				et;
			} else {
				var args:Array<TSignatureArg> = [];
				for (a in c.ecArgs) {
					var at = Typeload.loadTypeHint(ctx, localParams, a.type, false);
					if (a.opt) at = ctx.basic.tnull(at);
					args.push({name: a.name, opt: a.opt, t: at});
				}
				TFun({args: args, ret: et});
			};
			var ef = new TEnumField(c.ecName.name, t, c.ecPos, c.ecName.pos, c.ecDoc, index, ctorParams, c.ecMeta);
			e.constrs.set(c.ecName.name, ef);
			e.names.push(c.ecName.name);
			index++;
		}
	}

	// Field-type resolution: the part of creating a variable, method or property field that
	// resolves its type.
	public static function resolveFieldType(ctx:Context, typeParams:TypeParams, cf:TClassField, cff:ClassField):Void {
		switch (cff.cffKind) {
			case FVar(th, _):
				// Var/final field with an explicit hint -> resolve; else leave the mono
				// the typer would infer from the initializer expr in Phase 3 pt c.
				if (th != null) cf.type = Typeload.loadComplexType(ctx, typeParams, th);
			case FProp(_, _, th, _):
				if (th != null) cf.type = Typeload.loadComplexType(ctx, typeParams, th);
			case FFun(fd):
				// Method -> TFun(args, ret). Faithful: optional arg -> Null<T>; missing hint > fresh mono (the
				// typer infers it). Method-local type params are not added to scope here (annotations only;
				// rarely affects stdlib signatures, and a missing local-param ref would just resolve via the
				// class params or a mono).
				var localParams = typeParams;
				var methodParams:TypeParams = [];
				if (fd.fParams.length > 0) {
					// Add method type params so arg/return hints referencing them resolve.
					methodParams = Typeload.typeTypeParams(ctx, {pack: [], name: cf.name}, fd.fParams);
					localParams = methodParams.concat(typeParams);
				}
				var isMacroField = false;
				for (acc in cff.cffAccess) if (acc.access == AMacro) isMacroField = true;
				var args:Array<TSignatureArg> = [];
				for (fa in fd.fArgs) {
					var at = isMacroField ? loadMacroHint(ctx, localParams, fa.type) : Typeload.loadTypeHint(ctx, localParams, fa.type, false);
					if (fa.opt) at = ctx.basic.tnull(at);
					var sigOpt = fa.opt || fa.value != null;
					args.push({name: fa.name.name, opt: sigOpt, t: at});
				}
				var ret = Typeload.loadTypeHint(ctx, localParams, fd.fType, false);
				cf.type = TFun({args: args, ret: ret});
				cf.params = methodParams;
				// Build a TFun signature from each
				// `@:overload(function(args):ret {})` meta and store it in overloads. This is
				// `(fd,data:Dynamic,?position)` / `(fd,data,position,encoding)` alternates) be
				// selected at the call site instead of only the primary `(fd,buffer:Buffer,...)`
				initMetaOverloads(ctx, localParams, cf);
		}
	}

	// For each `@:overload(function
	// (args):ret {})` meta on `cf`, load its args/ret into a TFun signature and push a cloned
	// TClassField carrying that type onto overloads. The empty-body / no-name / not-inline
	// checks are faithful but lenient here (the std/externs we load are well-formed). The
	// `@:overload` (no-args, supportsOverload "proper" overloads) form is not applicable to the JS
	// target (`supportsOverload = false` for js), so we only handle the meta-with-function form.
	static function initMetaOverloads(ctx:Context, typeParams:TypeParams, cf:TClassField):Void {
		var overloads:Array<TClassField> = [];
		for (m in cf.meta) {
			if (m.name != ":overload") continue;
			if (m.params.length != 1) continue;
			switch (m.params[0].expr) {
				case EFunction(_, f):
					// Method-local type params on the overload function (rare for the std/externs
					// we touch; load them so arg/ret hints referencing them resolve).
					var localParams = typeParams;
					var ovParams:TypeParams = [];
					if (f.fParams.length > 0) {
						ovParams = Typeload.typeTypeParams(ctx, {pack: [], name: cf.name}, f.fParams);
						localParams = ovParams.concat(typeParams);
					}
					var args:Array<TSignatureArg> = [];
					for (fa in f.fArgs) {
						// Topt: explicit type required, load the hint; opt `?`
						// Null-wraps; a default value reports opt in the signature (no wrap).
						var at = Typeload.loadTypeHint(ctx, localParams, fa.type, false);
						if (fa.opt) at = ctx.basic.tnull(at);
						var sigOpt = fa.opt || fa.value != null;
						args.push({name: fa.name.name, opt: sigOpt, t: at});
					}
					var ret = Typeload.loadTypeHint(ctx, localParams, f.fType, false);
					var ocf = TypeFunctions.copyField(cf);
					ocf.type = TFun({args: args, ret: ret});
					ocf.params = ovParams;
					ocf.overloads = [];
					// Drop the @:overload/@:value metas from the clone.
					ocf.meta = [for (mm in cf.meta) if (mm.name != ":overload" && mm.name != ":value") mm];
					overloads.push(ocf);
				case _:
			}
		}
		if (overloads.length > 0) cf.overloads = overloads;
	}
}
