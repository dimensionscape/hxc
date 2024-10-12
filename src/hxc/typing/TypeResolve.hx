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
import hxc.typing.Typeload.TypeParamHost;
import haxe.ds.StringMap;

class TypeResolve {
	static var heritagePositions:Map<String,Position> = new Map();
	static final pNull = Position.nullPos;

	public static function resolveModule(ctx:Context, m:ModuleDef):Void {
		if (m.extra.resolved >= 1) return;
		m.extra.resolved = 1;
		var savedMod = ctx.currentModule;
		ctx.currentModule = m; // Resolve in-module sibling types against m.types first
		for (mt in m.types) {
			var info = TypeFunctions.tInfos(mt);
			var entry = ctx.declOfType.get(Context.pathKey(info.path));
			if (entry == null) continue; // Synthetic types (e.g. _Fields_, enum module-type) have no decl
			try {
				resolveType(ctx, mt, entry.decl, entry.pos);
			} catch (dc:hxc.compiler.DisplayXml.ToplevelCompletion) {
				// A display completion is an answer, not a declaration error: it has to reach the responder
				// rather than be recorded and swallowed here.
				throw dc;
			} catch (e:ContextError) {
				// A declaration error (bad heritage, final extend, ...) is recorded so the rest of
				// the module still resolves but the compile fails.
				ctx.addDiagnostic(e.message, e.pos, e.depth);
				ctx.currentModule = m;
			} catch (e:hxc.core.TypingError) {
				ctx.addDiagnostic(e.message, e.pos, e.depth);
				ctx.currentModule = m;
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

	// On-demand resolution of one type (a forward-referenced typedef used in an intersection
	// while its module is still mid-resolution). Guarded against re-entry.
	static var onDemand:StringMap<Bool> = new StringMap();

	public static function resolveTypeOnDemand(ctx:Context, mt:ModuleType):Void {
		var info = TypeFunctions.tInfos(mt);
		var key = Context.pathKey(info.path);
		if (onDemand.exists(key)) return;
		var entry = ctx.declOfType.get(key);
		if (entry == null) return;
		onDemand.set(key, true);
		try resolveType(ctx, mt, entry.decl, entry.pos)
		catch (dc:hxc.compiler.DisplayXml.ToplevelCompletion) { onDemand.remove(key); throw dc; }
		catch (_:Dynamic) {}
		onDemand.remove(key);
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
				// A Module.SubType path (second-to-last segment capitalized) names a single type; a plain
				// module path brings in every non-private class of the module, like a using statement.
				var subOf:Null<{pack:Array<String>, moduleName:String, sub:String}> = null;
				if (parts.length >= 2) {
					var s2 = parts[parts.length - 2];
					var c0 = s2.charCodeAt(0);
					if (c0 >= "A".code && c0 <= "Z".code)
						subOf = {pack: parts.slice(0, parts.length - 2), moduleName: s2, sub: parts[parts.length - 1]};
				}
				function classOf(used:Null<ModuleType>):Null<TClass> {
					return switch (used) {
						case TClassDecl(c): c;
						case TAbstractDecl(a) if (a.impl != null): a.impl;
						case _: null;
					}
				}
				if (subOf != null) {
					var used = try ctx.getType({pack: subOf.pack, name: subOf.moduleName}, param.pos, subOf.sub) catch (_:Dynamic) null;
					var usingClass = classOf(used);
					if (usingClass != null) addUsing(mt, usingClass, param.pos);
					continue;
				}
				var path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
				var um = try hxc.context.ModuleLoader.loadModule(ctx, path, param.pos) catch (_:Dynamic) null;
				if (um != null) {
					// filter_classes reverses the type list, then the result is prepended; unshifting in
					// module order produces the same final order.
					for (umt in um.types) {
						if (TypeFunctions.tInfos(umt).isPrivate) continue;
						var usingClass = classOf(umt);
						if (usingClass != null) addUsing(mt, usingClass, param.pos);
					}
					continue;
				}
				var used = try ctx.getType(path, param.pos, null) catch (_:Dynamic) null;
				var usingClass = classOf(used);
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

	// Loading a heritage under a display request answers the toplevel type set, which is then filtered
	// for the position. An interface cannot `implements` at all, so answers nothing. Otherwise an
	// interface is offered when implementing (or when an interface extends), and a class only when
	// extending a class - never the type being declared, never a final one unless @:hack, and never a
	// basic class unless both are extern.
	static function answerHeritCompletion(ctx:Context, c:TClass, isExtends:Bool, p:Position):Void {
		var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
		var items:Array<hxc.compiler.DisplayXml.ToplevelItem> = [];
		if (isExtends || !isInterface) {
			inline function isBasicClassPath(path:hxc.core.Globals.Path):Bool {
				return path.pack.length == 0
					&& (path.name == "Array" || path.name == "String" || path.name == "Date" || path.name == "Xml");
			}
			for (mt in visibleTypesForCompletion(ctx)) {
				var inf = TypeFunctions.tInfos(mt);
				if (inf.isPrivate || Context.pathKey(inf.path) == Context.pathKey(c.path)) continue;
				var keep = switch (mt) {
					case TClassDecl(cm) if (TypeFunctions.hasClassFlag(cm, CInterface)):
						!isExtends || isInterface;
					case TClassDecl(cm):
						isExtends && !isInterface
							&& (!TypeFunctions.hasClassFlag(cm, CFinal) || TypeFunctions.hasMeta(":hack", c.meta))
							&& (!isBasicClassPath(cm.path)
								|| (TypeFunctions.hasClassFlag(c, CExtern) && TypeFunctions.hasClassFlag(cm, CExtern)));
					case _: false;
				};
				if (keep) items.push({kind: "type", name: inf.path.name, path: hxc.core.Globals.sTypePath(inf.path)});
			}
			items.sort(function(a, b) return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
		}
		throw new hxc.compiler.DisplayXml.ToplevelCompletion(items);
	}

	// The parser's magic type path reaching load_type_def means the cursor is in a type position, and
	// every type in scope is the answer (CRTypeHint). The heritage answer above is the same collection
	// with set_heritance's extra filtering on top.
	public static function answerTypeHintCompletion(ctx:Context, p:Position):Void {
		var items:Array<hxc.compiler.DisplayXml.ToplevelItem> = [];
		for (mt in visibleTypesForCompletion(ctx)) {
			var inf = TypeFunctions.tInfos(mt);
			if (inf.isPrivate) continue;
			items.push({kind: "type", name: inf.path.name, path: hxc.core.Globals.sTypePath(inf.path)});
		}
		items.sort(function(a, b) return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
		throw new hxc.compiler.DisplayXml.ToplevelCompletion(items);
	}

	// The types a completion here can see: everything loaded so far, which is what the reference's
	// collect reaches through the module lookup at the same moment.
	static function visibleTypesForCompletion(ctx:Context):Array<ModuleType> {
		var out:Array<ModuleType> = [];
		var seen = new Map<String, Bool>();
		for (key in ctx.moduleLut.keys()) {
			var m = ctx.moduleLut.get(key);
			for (mt in m.types) {
				var k = Context.pathKey(TypeFunctions.tInfos(mt).path);
				if (seen.exists(k)) continue;
				seen.set(k, true);
				out.push(mt);
			}
		}
		return out;
	}

	public static function resolveClass(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		// Pass 1: heritage. Filter HExtends/HImplements; load each type; set relations.
		for (f in d.dFlags) switch (f) {
			case HExtends(pt):
				heritagePositions.set(Context.pathKey(c.path), pt.pos);
				if (pt.path.tname == "") answerHeritCompletion(ctx, c, true, pt.pos);
				var t = try Typeload.loadInstance(ctx, c.params, pt.path, pt.pos, false) catch (err:ContextError) {
					if (err.message == "Recursive class") throw new ContextError(err.message, pt.pos, err.kind);
					throw err;
				};
				checkHerit(ctx, c, t, true, pt.pos, p);
			case HImplements(pt):
				heritagePositions.set(Context.pathKey(c.path), pt.pos);
				if (pt.path.tname == "") answerHeritCompletion(ctx, c, false, pt.pos);
				var t = try Typeload.loadInstance(ctx, c.params, pt.path, pt.pos, false) catch (err:ContextError) {
					if (err.message == "Recursive class") throw new ContextError(err.message, pt.pos, err.kind);
					throw err;
				};
				checkHerit(ctx, c, t, false, pt.pos);
			case _:
		}
		// A non-static method whose inherited parent field is MethDynamic is dynamic itself even without
		// the modifier. Applied here because the heritage above just resolved superClass (field shells were
		// created earlier).
		if (c.superClass != null) for (cf in c.orderedFields) switch (cf.kind) {
			case Method(MethNormal):
				var sup = c.superClass;
				while (sup != null) {
					var pf = sup.c.fields.get(cf.name);
					if (pf != null) {
						if (pf.kind.match(Method(MethDynamic))) cf.kind = Method(MethDynamic);
						break;
					}
					sup = sup.c.superClass;
				}
			case _:
		}
		resolveClassFields(ctx, c, d, p);
		markClassBuilt(c);
		TypeFields.addImplicitInterfaceFields(c);
	}

	// Inherited @:autoBuild entries become @:build entries on the derived type.
	static function inheritAutoBuild(ctx:Context, c:TClass, parent:TClass):Void {
		var meta = parent.meta.copy();
		if (ctx.defines.rawDefined("haxe_next")) meta.reverse();
		for (m in meta) if (m.name == ":autoBuild") {
			var pos = new Position(c.pos.file, c.pos.min, c.pos.min);
			c.meta = [{name: ":build", params: m.params, pos: pos}, m].concat(c.meta);
		}
	}

	// @:require(cond...) gates a field behind compiler flags: with no condition satisfied both accessors
	// become AccRequire, whose use errors with the flag name (or the trailing string message).
	static function checkRequire(ctx:Context, meta:Metadata):Null<{r:String, msg:Null<String>}> {
		for (entry in meta) {
			if (entry.name != ":require") continue;
			for (idx in 0...entry.params.length) {
				var e = entry.params[idx];
				var sc = switch (e.expr) {
					case EConst(CIdent(s)): s;
					case EBinop(op = OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte, {expr: EConst(CIdent(s))}, {expr: EConst(cst = CInt(_, _) | CFloat(_, _) | CString(_, _))}):
						s + Ast.sBinop(op) + Ast.sConstant(cst);
					case _: "";
				};
				if (!hxc.parser.Preprocess.isTrueExpr(ctx.defines, e)) {
					var rest = entry.params.slice(idx + 1);
					var msg = rest.length > 0 ? switch (rest[rest.length - 1].expr) {
						case EConst(CString(m, _)): m;
						case _: null;
					} : null;
					return {r: sc, msg: msg};
				}
			}
			// All conditions of this entry hold; a later @:require may still fail.
		}
		return null;
	}

	// Resolve only the field signatures of an already-heritage-resolved class. A @:build macro rewrites the
	// field list but not the heritage, so it re-runs this without redoing extends. the build protocol:
	// while a class is being built its build reports `Building [c]` so a re-entrant request is a NO-OP,
	// and on completion it is replaced by `Built` so later requests do nothing at all. hxc resolves fields
	// through a plain pass instead, with no such state, so anything that wanted to force a class early had
	// to re-run the pass and disturb the schedule for every other class. Track the same two states here.
	// Only buildClassFields consults them; the ordinary resolution path just records that it happened, and
	// an explicit re-resolution after a @:build macro rewrites the definition deliberately bypasses this.
	static var buildState = new haxe.ds.ObjectMap<TClass, Int>();
	static inline var BUILDING = 1;
	static inline var BUILT = 2;

	public static function markClassBuilt(c:TClass):Void {
		buildState.set(c, BUILT);
	}

	// Make sure the class is set up before its fields are read. Returns true when this call did the
	// work.
	public static function buildClassFields(ctx:Context, c:TClass, p:Position):Bool {
		if (buildState.exists(c)) return false;
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return false;
		switch (entry.decl) {
			case EClass(d):
				buildState.set(c, BUILDING);
				var savedModule = ctx.currentModule;
				if (c.module != null) ctx.currentModule = c.module;
				try resolveClassFields(ctx, c, d, p) catch (_:Dynamic) {}
				ctx.currentModule = savedModule;
				buildState.set(c, BUILT);
				return true;
			case _:
				return false;
		}
	}

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
			// Occurrence > 0 is a merged overload sibling: resolve onto its overloads slot. A second
			// constructor with no slot was reported as a duplicate and dropped (the first is kept), so it
			// binds nothing; falling through to `cf` rebinds the surviving constructor to the rejected
			// declaration.
			if (cff.cffName.name == "new" && occ > 0 && cf.overloads.length < occ) continue;
			var target = if (occ > 0 && cf.overloads.length >= occ) cf.overloads[cf.overloads.length - occ] else cf;
			if (isAbstractMember) TypeFunctions.addClassFieldFlag(target, CfImpl);
			try {
				var params = if (isAbsImpl && abstractTypeParams != null && TypeFunctions.hasClassFieldFlag(target, CfImpl))
					abstractTypeParams
				else
					c.params;
				resolveFieldType(ctx, params, target, cff, c.module);
				// A field-level @:require wins; a class-level one covers statics and the constructor.
				var req = checkRequire(ctx, cff.cffMeta);
				if (req == null && (isStatic || cff.cffName.name == "new")) req = checkRequire(ctx, c.meta);
				if (req != null) target.kind = Var({read: AccRequire(req.r, req.msg), write: AccRequire(req.r, req.msg)});
				// A non-static override with no explicit `public`/`private` inherits the overridden field's
				// visibility; registerFields defaulted it to private before superClass was resolved.
				if (!isStatic && cff.cffName.name != "new") {
					var isOverride = false, explicitVis = false;
					for (a in cff.cffAccess) switch (a.access) {
						case AOverride: isOverride = true;
						case APublic | APrivate: explicitVis = true;
						case _:
					}
					if (isOverride) {
						// An `override` field carries CfOverride, which the cpp generator reads to suppress
						// a redundant
						// _dyn() wrapper on the override.
						TypeFunctions.addClassFieldFlag(target, CfOverride);
						var parent = getParentField(c, cff.cffName.name);
						if (parent != null) {
							if (!explicitVis) {
								if (TypeFunctions.hasClassFieldFlag(parent, CfPublic)) TypeFunctions.addClassFieldFlag(target, CfPublic);
								else TypeFunctions.removeClassFieldFlag(target, CfPublic);
							}
							// An override without its own @:native inherits the overridden field's, so it
							// is emitted under the
							// same runtime name.
							if (!TypeFunctions.hasMeta(":native", target.meta) && TypeFunctions.hasMeta(":native", parent.meta))
								target.meta = [TypeFunctions.getMeta(":native", parent.meta)].concat(target.meta);
						}
					} else if (!explicitVis) {
						var parent = getParentField(c, cff.cffName.name);
						var isPublic = parent != null ? TypeFunctions.hasClassFieldFlag(parent, CfPublic)
							: (TypeFunctions.hasClassFlag(c, CExtern)
								|| TypeFunctions.hasClassFlag(c, CInterface)
								|| extendsPublic(c)
								|| (switch (c.kind) { case KModuleFields(_): true; case _: false; }));
						if (isPublic) TypeFunctions.addClassFieldFlag(target, CfPublic);
						else TypeFunctions.removeClassFieldFlag(target, CfPublic);
					}
				}
			} catch (e:ContextError) {
				var isUserMacroField = c.module != null && c.module.path.pack.length == 0
					&& (c.module.extra.file == null || (c.module.extra.file.toLowerCase().indexOf("utest") < 0 && c.module.extra.file.toLowerCase().indexOf("\\haxe\\") < 0));
				if (e.message == "Type not found : Expr" && isUserMacroField) {
					var duplicate = false;
					for (d in ctx.diagnostics) if (d.message == e.message && d.pos.file == e.pos.file && d.pos.min == e.pos.min && d.pos.max == e.pos.max) duplicate = true;
					if (!duplicate) ctx.addDiagnostic(e.message, e.pos, e.depth);
				}
				else ctx.unresolvedFields++;
			}
		}
		linkPropertyAccessors(ctx, c, isAbsImpl);
	}

	// The same-named instance field on the nearest superclass.
	static function getParentField(c:TClass, name:String):Null<TClassField> {
		var s = c.superClass;
		while (s != null) {
			var f = s.c.fields.get(name);
			if (f != null) return f;
			s = s.c.superClass;
		}
		return null;
	}

	static function extendsPublic(c:TClass):Bool {
		if (TypeFunctions.hasMeta(":publicFields", c.meta)) return true;
		return c.superClass != null && extendsPublic(c.superClass.c);
	}

	// Bind each property accessor signature to the property's declared type: an unannotated get_/set_
	// return or value argument would otherwise be a free monomorph that can unify with an unrelated sibling
	// type during inference. accessor checks.
	static function linkPropertyAccessors(ctx:Context, c:TClass, isAbsImpl:Bool):Void {
		// A property accessor placed with the wrong staticness (a member accessor for a static property, or
		// vice versa) is reported.
		var isExtern = TypeFunctions.hasClassFlag(c, CExtern);
		function checkAccessor(accName:String, propName:String, ownColl:StringMap<TClassField>, otherColl:StringMap<TClassField>, propIsStatic:Bool):Void {
			if (isExtern || TypeFunctions.hasClassFlag(c, CInterface)) return;
			if (ownColl.get(accName) != null) return;
			var other = otherColl.get(accName);
			if (other != null)
				ctx.addDiagnostic("Method " + accName + " is no valid accessor for " + propName + " because it is " + (propIsStatic ? "not " : "") + "static", other.pos);
		}
		function usePropertyType(slot:T, pt:T):Void {
			switch (TypeFunctions.follow(slot)) {
				case TMono(r) if (r.type == null):
					TypeUnification.monoBind(r, pt);
				case _:
					try TypeUnification.unifyDefault(slot, pt) catch (_:Dynamic) {};
			}
		}
		function loop(fields:StringMap<TClassField>, other:StringMap<TClassField>, propIsStatic:Bool):Void {
			inline function genAccessor(accName:String, propType:T, isSetter:Bool):TClassField {
				// Generate the virtual accessor for an interface property.
				var ft = isSetter ? TFun({args: [{name: "value", opt: false, t: propType}], ret: propType}) : TFun({args: [], ret: propType});
				var acc = TypeFunctions.mkField(accName, ft, c.pos, c.pos, true, false);
				acc.kind = Method(MethNormal);
				acc.meta = [{name: ":compilerGenerated", params: [], pos: Position.nullPos}, {name: ":noCompletion", params: [], pos: Position.nullPos}];
				return acc;
			}
			// A synthesized interface accessor (a getter or setter) is created by the method check, which
			// property creation delays to PConnectField. That pass runs after orderedFields is reversed
			// into declaration order, and each accessor is prepended. Because a pass flushes its delays
			// LIFO,
			// every generated accessor lands at the FRONT of the field list, in property-declaration order
			// (get before set per property). Collect them in declaration order here, then prepend the whole
			// batch.
			var orderedProps = propIsStatic ? c.orderedStatics : c.orderedFields;
			var genAccessors:Array<TClassField> = [];
			for (cf in orderedProps) {
				var name = cf.name;
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
							else if (TypeFunctions.hasClassFlag(c, CInterface)) {
								var acc = genAccessor("get_" + name, pt, false);
								fields.set(acc.name, acc);
								genAccessors.push(acc);
							}
							else checkAccessor("get_" + name, name, fields, other, propIsStatic);
						}
						if (vk.write.match(AccCall)) {
							var st = fields.get("set_" + name);
							if (st != null) switch (TypeFunctions.follow(st.type)) {
								case TFun(sig):
									if (sig.args.length > 0) usePropertyType(sig.args[sig.args.length - 1].t, pt);
									usePropertyType(sig.ret, pt);
								case _:
							}
							else if (TypeFunctions.hasClassFlag(c, CInterface)) {
								var acc = genAccessor("set_" + name, pt, true);
								fields.set(acc.name, acc);
								genAccessors.push(acc);
							}
							else checkAccessor("set_" + name, name, fields, other, propIsStatic);
						}
					case _:
				}
			}
			if (genAccessors.length > 0) {
				var newOrdered = genAccessors.concat(orderedProps);
				if (propIsStatic) c.orderedStatics = newOrdered;
				else c.orderedFields = newOrdered;
			}
		}
		loop(c.statics, c.fields, true);
		if (!isAbsImpl) loop(c.fields, c.statics, false);
	}

	// Whether c's inheritance chain (itself, supers, implemented interfaces) reaches target.
	static function extendsChain(c:TClass, target:TClass):Bool {
		if (c == target) return true;
		for (i in c.interfaces) if (extendsChain(i.c, target)) return true;
		return c.superClass != null && extendsChain(c.superClass.c, target);
	}

	static function checkHerit(ctx:Context, c:TClass, t:T, isExtends:Bool, p:Position, ?declP:Position):Void {
		if (isExtends) {
			if (c.superClass != null) throw new ContextError("Cannot extend several classes", p);
			switch (TypeFunctions.follow(t)) {
				case TInst(csup, params):
					if (extendsChain(csup, c)) throw new ContextError("Recursive class", heritagePositions.get(Context.pathKey(csup.path)) != null ? heritagePositions.get(Context.pathKey(csup.path)) : p);
					// A final class or interface cannot be extended; @:hack lifts the check for an extern
					// super, and a
					// type-parameter class is exempt.
					if (TypeFunctions.hasClassFlag(csup, CFinal)
							&& !((TypeFunctions.hasClassFlag(csup, CExtern) && TypeFunctions.hasMeta(":hack", c.meta))
								|| c.kind.match(KTypeParameter(_))))
						throw new ContextError("Cannot extend a final " + (TypeFunctions.hasClassFlag(c, CInterface) ? "interface" : "class"), declP != null ? declP : p);
					if (TypeFunctions.hasClassFlag(c, CInterface)) {
						if (!TypeFunctions.hasClassFlag(csup, CInterface))
							throw new ContextError("Cannot extend by using a class", p);
						// Prepended, so interfaces holds reverse source order
						c.interfaces.unshift({c: csup, params: params});
						// Record `c` as a descendant of its
						// inheritance tree downward (keep overrides of reachable base methods).
						TypeFunctions.addDescendant(csup, c);
					} else {
						if (TypeFunctions.hasClassFlag(csup, CInterface))
							throw new ContextError("Cannot extend by using an interface", p);
						c.superClass = {c: csup, params: params};
						TypeFunctions.addDescendant(csup, c);
					}
					inheritAutoBuild(ctx, c, csup);
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
					if (extendsChain(intf, c)) throw new ContextError("Recursive class", heritagePositions.get(Context.pathKey(intf.path)) != null ? heritagePositions.get(Context.pathKey(intf.path)) : p);
					if (!TypeFunctions.hasClassFlag(intf, CInterface))
						throw new ContextError("You can only implement an interface", p);
					// Prepended, so interfaces holds reverse source order
					c.interfaces.unshift({c: intf, params: params});
					TypeFunctions.addDescendant(intf, c);
					inheritAutoBuild(ctx, c, intf);
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

		var fromPos:Array<Position> = [];
		var toPos:Array<Position> = [];
		for (f in d.dFlags) switch (f) {
			case AbFrom(th): a.from.push(loadType(th)); fromPos.push(th.pos);
			case AbTo(th): a.to.push(loadType(th)); toPos.push(th.pos);
			case AbOver(th):
				if (isCore) throw new ContextError("@:coreType abstracts cannot have an underlying type", p);
				var at = Typeload.loadComplexType(ctx, a.params, th);
				a.thisType = at;
				isType = true;
				// A recursive underlying chain reports once the involved abstracts have resolved (a PForce
				// delay over a stack of the abstracts visited). Prepended: delays run newest-first, so the last
				// declared abstract's check reports the cycle (at the FIRST declared abstract's pos).
				ctx.pendingConstraintChecks.unshift(function() {
					var stack:Array<TAbstract> = [];
					function walk(t:T):Void switch (TypeFunctions.follow(t)) {
						case TAbstract(a2, _) if (!TypeFunctions.hasMeta(":coreType", a2.meta)):
							if (stack.indexOf(a2) >= 0)
								// Fatal: the remaining queued checks are skipped, so the cycle reports
								// once.
								throw new hxc.core.TypingError("Abstract underlying type cannot be recursive", a2.pos);
							else {
								stack.push(a2);
								walk(a2.thisType);
							}
						case _:
					}
					walk(at);
				});
			case AbExtern:
				// An extern abstract's implementation class is extern too, so a value-less enum-abstract
				// member
				// stays a real extern field rather than getting a synthesized ordinal value.
				if (a.impl != null) TypeFunctions.addClassFlag(a.impl, CExtern);
			case AbPrivate | AbEnum:
		}

		// From/to declarations must unify with the underlying type (the unification also marks
		// structure-matched class fields @:?used for DCE)
		if (!isCore && isType) {
			// Report the error at the from/to type hint.
			for (i in 0...a.from.length) {
				try hxc.core.TypeUnification.unifyDefault(a.from[i], a.thisType)
				catch (_:hxc.core.TypeUnification.UnifyError)
					throw new ContextError("You can only declare from/to with compatible types", i < fromPos.length ? fromPos[i] : a.pos);
			}
			for (i in 0...a.to.length) {
				try hxc.core.TypeUnification.unifyDefault(a.thisType, a.to[i])
				catch (_:hxc.core.TypeUnification.UnifyError)
					throw new ContextError("You can only declare from/to with compatible types", i < toPos.length ? toPos[i] : a.pos);
			}
		}

		// The check hangs off LOADING a from/to type hint: a core abstract with neither is fine with
		// @:callable (cpp NativeThreadHandle).
		if (isCore && (a.from.length > 0 || a.to.length > 0) && TypeFunctions.hasMeta(":callable", a.meta))
			throw new ContextError("@:coreType abstracts cannot be @:callable", a.pos);
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
					markClassBuilt(a.impl);
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
		// Each SYNTAX field with the cf built from it, so an OVERLOADED @:op name reaches every
		// declaration. Looking the field up by name cannot do that: it hands back the same cf twice, and
		// once a body-less declaration removes that one from statics the sibling is never visited and
		// survives into the output. Pair positionally instead, by taking the next not-yet-handled field
		// of that name.
		var handled:Array<TClassField> = [];
		for (cff in d.dData) {
			// Locate the impl cf (member -> promoted static; static -> static). Resolve it up front: both
			// the @:op arms and the @:arrayAccess arm need it.
			var cf = abstractImplField(c, cff.cffName.name);
			if (cf == null || handled.indexOf(cf) >= 0) {
				for (x in c.orderedStatics) if (x.name == cff.cffName.name && handled.indexOf(x) < 0) { cf = x; break; }
			}
			if (cf == null || handled.indexOf(cf) >= 0) continue;
			handled.push(cf);
			// A single field may carry SEVERAL of these metas at once (e.g. `@:op(A + B) @:arrayAccess
			// @:resolve`), so each is handled independently rather than mutually exclusively. every meta of
			// the field (loop cf.meta). starts set for a @:coreType abstract, and allow_no_expr() is called
			// by the @:arrayAccess / @:op([]) / @:op(binop) / @:op(unop) / @:op(call) / @:resolve arms (not
			// by @:from / @:to). A bodiless function in such a field is a declaration only.
			var allowsNoExpr = TypeFunctions.hasMeta(":coreType", a.meta);
			if (TypeFunctions.hasMeta(":arrayAccess", cff.cffMeta)) {
				a.array.push(cf);
				allowsNoExpr = true;
			}
			// @:resolve routes to the same read/write registration as @:op([EField]).
			if (TypeFunctions.hasMeta(":resolve", cff.cffMeta)) {
				registerResolveField(a, cf, cff, cf.pos);
				allowsNoExpr = true;
			}
			// The @:op meta survives transformAbstractField (it concats f.cffMeta), so read it off
			// the SOURCE field and resolve the matching impl cf by name. A member @:op was promoted
			// to a static abstract member; a `static` @:op stays a static too.
			if (TypeFunctions.hasMeta(":op", cff.cffMeta)) {
				var meta = TypeFunctions.getMeta(":op", cff.cffMeta);
				// @:op takes exactly one expression param: an EBinop, EUnop, EArrayDecl ([]),
				// ECall, EField, or ETernary.
				if (meta.params.length == 1) {
					var opExpr = meta.params[0];
					switch (opExpr.expr) {
						// `@:op([])` (EArrayDecl) -> array (same arm as the
						// @:arrayAccess meta handled above).
						case EArrayDecl(_):
							a.array.push(cf);
							allowsNoExpr = true;
						// Assignment / null-coalescing / ternary overloads
						// are explicitly rejected.
						case EBinop(OpAssign, _, _):
							throw new ContextError("Assignment overloading is not supported", cf.pos);
						case EBinop(OpNullCoal, _, _) | EBinop(OpAssignOp(OpNullCoal), _, _):
							throw new ContextError("Null coalescing overloading is not supported", cf.pos);
						case ETernary(_, _, _):
							throw new ContextError("Ternary overloading is not supported", cf.pos);
						case EBinop(op, _, _):
							a.ops.push({op: op, cf: cf});
							allowsNoExpr = true;
						// `@:op(unop A)` / `@:op(A unop)`: register
						// (op, flag, cf) in unops.
						case EUnop(op, flag, _):
							a.unops.push({op: op, flag: flag, cf: cf});
							allowsNoExpr = true;
						// `@:op(a)` call overload. The first method
						// becomes `call`; later ones are prepended as overloads of that field.
						case ECall(_, _):
							if (a.call == null)
								a.call = cf;
							else
								a.call.overloads.unshift(cf);
							allowsNoExpr = true;
						case EField(_, _, _):
							registerResolveField(a, cf, cff, opExpr.pos);
							allowsNoExpr = true;
						case _:
					}
				}
			}
			// A body-less function on such a field is a declaration only (the operation is performed
			// natively): tag it @:noExpr and, unless the abstract is @:coreType, never add it to the
			// implementation class, so no storage or dispatch is generated for it.
			switch (cff.cffKind) {
				case FFun(fd) if (fd.fExpr == null && allowsNoExpr):
					cf.meta.unshift({name: ":noExpr", params: [], pos: hxc.ast.Position.nullPos});
					if (!TypeFunctions.hasMeta(":coreType", a.meta)) {
						c.orderedStatics.remove(cf);
						if (c.statics.get(cf.name) == cf) c.statics.remove(cf.name);
					}
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
		// A resolve read is (this, String) and a write is (this, String, value); each may carry a trailing
		// optional PosInfos argument (auto-filled at the call site), so only the leading count
		// distinguishes them. is_empty_or_pos_infos on the tail.
		switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig) if (sig.args.length >= 2 && isEmptyOrPosInfos(sig.args.slice(2))):
				if (a.read != null) throw new ContextError("Multiple resolve-read methods are not supported", p);
				a.read = cf;
			case TFun(sig) if (sig.args.length >= 3 && isEmptyOrPosInfos(sig.args.slice(3))):
				if (a.write != null) throw new ContextError("Multiple resolve-write methods are not supported", p);
				a.write = cf;
			case _:
				throw new ContextError("Field type of resolve must be " + cff.cffName.name + " -> String -> T", p);
		}
	}

	// A trailing argument list that is empty or a single optional PosInfos (the auto-filled position
	// argument does not count toward arity).
	static function isEmptyOrPosInfos(args:Array<TSignatureArg>):Bool {
		return switch (args) {
			case []: true;
			case [one] if (one.opt): isPosInfos(one.t);
			case _: false;
		};
	}

	static function isPosInfos(t:T):Bool {
		return switch (t) {
			case TMono(r): r.type == null ? false : isPosInfos(r.type);
			case TLazy(f): isPosInfos(TypeFunctions.lazyType(f));
			case TType(td, []) if (td.path.name == "PosInfos" && td.path.pack.length == 1 && td.path.pack[0] == "haxe"): true;
			case TType(td, tl): isPosInfos(TypeFunctions.applyParams(td.params, tl, td.type));
			case TAbstract(ab, [inner]) if (ab.path.name == "Null" && ab.path.pack.length == 0): isPosInfos(inner);
			case _: false;
		};
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
					// A @:to cast's arity is fixed: a static one takes the value, a member one takes only the
					// implicit this; one trailing optional argument is allowed either way. (are_valid_args).
					if (isTo && !TypeFunctions.hasMeta(":multiType", a.meta)) {
						inline function optAt(k:Int):Bool return fd.fArgs[k].opt || fd.fArgs[k].value != null;
						var declared = fd.fArgs.length;
						var validStatic = declared == 1 || (declared == 2 && optAt(1));
						var validMember = declared == 0 || (declared == 1 && optAt(0));
						if (!isAbstractMember && !validStatic)
							ctx.addDiagnostic("static @:to method should have one argument", cff.cffPos);
						else if (isAbstractMember && !validMember)
							ctx.addDiagnostic("@:to method should have no arguments", cff.cffPos);
					}
					// Method-local type params + abstract params in scope for the signature.
					var methodParams:TypeParams = [];
					var localParams = a.params;
					if (fd.fParams.length > 0) {
						// The abstract's own params are in scope for a method param's constraint loads
						// constraints with ctx.typeParams).
						methodParams = Typeload.typeTypeParams(ctx, {pack: [], name: cff.cffName.name}, fd.fParams, a.params, cff.cffName.name == "new" ? TPHConstructor : TPHMethod);
						localParams = methodParams.concat(a.params);
					}
					// In the host context a macro function's signature degrades every type to Dynamic, with
					// ExprOf<T> keeping T, so a macro @:from accepts any value at unification and runs to
					// decide. .
					function macroHostType(th:Null<TypeHint>):T {
						if (th != null) switch (th.ct) {
							case CTPath(tp) if (tp.tparams.length == 1 && ((tp.tpackage.length == 0 && tp.tname == "ExprOf" && tp.tsub == null)
									|| (tp.tpackage.length == 2 && tp.tpackage[0] == "haxe" && tp.tpackage[1] == "macro" && tp.tname == "Expr" && tp.tsub == "ExprOf"))):
								switch (tp.tparams[0]) {
									case TPType(inner): return Typeload.loadTypeHint(ctx, localParams, inner, false);
									case _:
								}
							case _:
						}
						return TypeFunctions.tDynamic;
					}
					var hostMacro = isMacro && !ctx.isMacro;
					var args:Array<TSignatureArg> = [];
					// For an abstract member cast, the underlying `this:thisType` is the first arg of the
					// synthesized static impl (the receiver the cast converts from/relates).
					if (isAbstractMember) args.push({name: "this", opt: false, t: a.thisType});
					for (fa in fd.fArgs) {
						var at = hostMacro ? macroHostType(fa.type) : Typeload.loadTypeHint(ctx, localParams, fa.type, false);
						if (fa.opt || (fa.value != null && fa.value.expr.match(EConst(CIdent("null"))))) at = ctx.basic.tnull(at); // A null default makes the argument nullable
						args.push({name: fa.name.name, opt: fa.opt || fa.value != null, t: at});
					}
					var ret = hostMacro ? macroHostType(fd.fType) : Typeload.loadTypeHint(ctx, localParams, fd.fType, false);
					// An inferred @:from return is the abstract itself (the @:from contract);
					// parameterize it by the method's own type parameters so unification
					// freshens them per attempt (spawnConstrainedMonos) instead of binding a
					// shared open monomorph that the first cast poisons for later attempts. The
					// synthetic entry is never force-typed, and forcing it during unification
					// recurses, so settle the shape here at resolve time. Only when the arities
					// line up (the body would infer exactly Abstract<K...>); otherwise the plain
					// monomorph is kept.
					if (isFrom && !isAbstractMember && fd.fType == null
							&& methodParams.length > 0 && methodParams.length == a.params.length) {
						ret = TAbstract(a, [for (tp in methodParams) tp.type]);
					}
					var ft = TFun({args: args, ret: ret});
					var cf = TypeFunctions.mkField(cff.cffName.name, ft, cff.cffPos, cff.cffName.pos, true, true);
					cf.meta = cff.cffMeta;
					// is_multitype_cast inside the @:to handling only, so the meta lands on @:to fields
					// alone. Marking @:from as well made abstractCast's make() short-circuit to a bare
					// mk_cast, skipping the static call whose inliner binds a side-effectful argument to a
					// temp.
					if (isTo && TypeFunctions.hasMeta(":multiType", a.meta) && !isAbstractMember && !TypeFunctions.hasMeta(":multiType", cf.meta))
						cf.meta = [{name: ":multiType", params: [], pos: Position.nullPos}].concat(cf.meta);
					cf.kind = Method(isMacro ? MethMacro : MethInline);
					cf.params = methodParams;
					// Abstract-impl field flag (check_abstract sets CfImpl on @:to fields).
					TypeFunctions.addClassFieldFlag(cf, CfImpl);
					if (TypeFunctions.hasMeta(":generic", cff.cffMeta)) TypeFunctions.addClassFieldFlag(cf, CfGeneric);
					if (isFrom) {
						// @:from: the stored type resolves LAZILY. Forcing it first checks the declared
						// return is the abstract itself (against fresh param monos), then reads the built
						// signature's single argument, so an unhinted or since-inferred signature is seen
						// live. (the @:from exc_protect) and (ta).
						var fromIdx = isAbstractMember ? 1 : 0;
						if (args.length > fromIdx) {
							var declaredRet = ret;
							var fromMacro = isMacro;
							var regPos = cff.cffPos;
							var r:Ref<TLazy> = new Ref(null);
							r.set(TypeFunctions.lazyWait(function():T {
								// The return type of a from-function must be the abstract, not the underlying type
								if (!fromMacro) {
									try TypeUnification.typeEqKind(EqStrict, declaredRet, TAbstract(a, [for (_ in a.params) TypeFunctions.mkMono()]))
									catch (ue:hxc.core.TypeUnification.UnifyError)
										throw new hxc.core.TypingError(hxc.core.TPrinting.betterErrorMessage(ue.errors), regPos);
								}
								var t2:T = switch (TypeFunctions.follow(cf.type)) {
									case TFun(sig) if (sig.args.length == fromIdx + 1):
										sig.args[fromIdx].t;
									case TFun(sig) if (sig.args.length == fromIdx + 2 && sig.args[fromIdx + 1].opt && isPosInfos(sig.args[fromIdx + 1].t)):
										sig.args[fromIdx].t;
									case _:
										throw new hxc.core.TypingError("@:from cast functions must accept exactly one argument", regPos);
								};
								r.set(TypeFunctions.lazyAvailable(t2));
								return t2;
							}));
							a.fromField.push({t: TLazy(r), cf: cf});
							// A @:from's return to the abstract, and in the reference that constraint lands on the same
							// field the generator later reads. hxc keeps a separate modelled cast field on purpose
							// (forcing the real one during unification recurses, see the note above), so the constraint
							// reached only the model: an UNCALLED @:from with no declared return type kept the monomorph
							// its body never bound, and a target lowered that to Dynamic instead of the abstract. The
							// impl static's signature is still a bare monomorph here, so this has to wait for PForce,
							// which is where cast signatures anyway.
							if (isFrom && a.impl != null) {
								var castName = cff.cffName.name;
								ctx.delay(hxc.context.Context.PForce, function() {
									var implCf = a.impl.statics.get(castName);
									if (implCf == null) return;
									switch (TypeFunctions.follow(implCf.type)) {
										case TFun(isig) if (TypeFunctions.follow(isig.ret).match(TMono(_))):
											try TypeUnification.typeEqKind(EqStrict, isig.ret,
												TAbstract(a, [for (_ in a.params) TypeFunctions.mkMono()]))
											catch (_:hxc.core.TypeUnification.UnifyError) {}
										case _:
									}
								});
							}
						}
					}
					if (isTo) {
						// @:to: stored type = the return type (concrete specialization).
						a.toField.push({t: ret, cf: cf});
						// A @:to method gets CfImpl even when static so an instance-style call like
						// `bytes.toArrayBuffer()` resolves it through the abstract. Flag the impl class's
						// real field, not just the synthetic cast entry.
						if (a.impl != null) {
							var real = a.impl.statics.get(cff.cffName.name);
							if (real != null) TypeFunctions.addClassFieldFlag(real, CfImpl);
						}
					}
				case _:
			}
		}
	}

	static function buildEnumAbstractFields(ctx:Context, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>, p:Position):Void {
		var c = a.impl;
		// At: the abstract self-type hint, built the way TExprToExpr converts a type back to syntax: a
		// PRIVATE type converts to its bare name, a secondary type to Module.Sub, so loadComplexType
		// resolves it back to this abstract.
		var aTParams:Array<TypeParamOrConst> = [
			for (tp in d.dParams) TPType({ct: CTPath({tpackage: [], tname: tp.tpName.name, tparams: [], tsub: null}), pos: p})
		];
		var aCt = if (a.isPrivate)
			CTPath({tpackage: [], tname: a.path.name, tparams: aTParams, tsub: null});
		else if (a.path.name == a.module.path.name)
			CTPath({tpackage: a.path.pack, tname: a.path.name, tparams: aTParams, tsub: null});
		else
			CTPath({tpackage: a.module.path.pack, tname: a.module.path.name, tparams: aTParams, tsub: a.path.name});
		var aT:TypeHint = {ct: aCt, pos: p};
		hxc.context.ModuleLoader.buildEnumAbstract(ctx.basic, a, aT, d.dData, ctx);
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
				resolveFieldType(ctx, c.params, cf, cff, c.module);
				if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) {
					cf.type = TAbstract(a, TypeFunctions.extractParamTypes(a.params));
				}
			} catch (e:ContextError) {
				var isUserMacroField = c.module != null && c.module.path.pack.length == 0
					&& (c.module.extra.file == null || (c.module.extra.file.toLowerCase().indexOf("utest") < 0 && c.module.extra.file.toLowerCase().indexOf("\\haxe\\") < 0));
				if (e.message == "Type not found : Expr" && isUserMacroField) {
					var duplicate = false;
					for (d in ctx.diagnostics) if (d.message == e.message && d.pos.file == e.pos.file && d.pos.min == e.pos.min && d.pos.max == e.pos.max) duplicate = true;
					if (!duplicate) ctx.addDiagnostic(e.message, e.pos, e.depth);
				}
				else ctx.unresolvedFields++;
			}
		}
	}

	static function resolveTypedef(ctx:Context, td:TDef, d:Definition<EnumFlag, TypeHint>, p:Position):Void {
		var tt = Typeload.loadComplexType(ctx, td.params, d.dData);
		// @:eager follows the typedef immediately instead of leaving the alias to resolve lazily. .
		if (TypeFunctions.hasMeta(":eager", td.meta)) tt = TypeFunctions.follow(tt);
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
		var isExprOf = th == null ? false : switch (th.ct) {
			case CTPath(tp):
				((tp.tpackage.length == 2 && tp.tpackage[0] == "haxe" && tp.tpackage[1] == "macro"
					&& tp.tname == "Expr" && tp.tsub == "ExprOf")
					|| (tp.tpackage.length == 0 && tp.tname == "ExprOf" && tp.tsub == null))
					&& tp.tparams.length == 1;
			case _: false;
		};
		if (ctx.isMacro) {
			// In the macro context a missing hint and ExprOf<T> both read as haxe.macro.Expr; other hints
			// load
			// normally.
			if (th == null || isExprOf)
				return Typeload.loadInstance(ctx, typeParams, exprPath, th == null ? hxc.ast.Position.nullPos : th.pos, false);
			return Typeload.loadTypeHint(ctx, typeParams, th, false);
		}
		// The host sees a macro signature as Dynamic, keeping only ExprOf's inner type; haxe.PosInfos is
		// rejected.
		if (th == null) return TypeFunctions.tDynamic;
		switch (th.ct) {
			case CTPath(tp):
				if (isExprOf) switch (tp.tparams[0]) {
					case TPType(inner): return Typeload.loadTypeHint(ctx, typeParams, inner, false);
					case _:
				}
				if (tp.tpackage.length == 1 && tp.tpackage[0] == "haxe" && tp.tname == "PosInfos"
						&& tp.tsub == null && tp.tparams.length == 0)
					throw new ContextError("haxe.PosInfos is not allowed on macro functions, use Context.currentPos() instead", th.pos);
			case _:
		}
		return TypeFunctions.tDynamic;
	}

	static function checkMacroExprHint(ctx:Context, th:Null<TypeHint>, ownerModule:Null<ModuleDef>):Void {
		var module = ownerModule == null ? ctx.currentModule : ownerModule;
		if (th == null || module == null) return;
		// A platform-suffixed host file (Name.<target>.hx) has a macro-context sibling that carries its own
		// imports; the macro world resolves the hint there and the host never resolves it at all. (to_dyn).
		var mfile = module.extra.file;
		if (mfile != null && StringTools.endsWith(mfile, "." + hxc.core.Globals.platformName(ctx.platform) + ".hx")) return;
		switch (th.ct) {
			case CTPath(tp) if (tp.tpackage.length == 0 && tp.tname == "Expr" && tp.tsub == null):
				var imports = ctx.moduleImports.get(hxc.context.Context.pathKey(module.path));
				var imported = false;
			if (imports != null) for (imp in imports.rawImports) switch (imp.mode) {
				case INormal | IAsName(_):
					var names = [for (pn in imp.path) pn.name];
					if (names.length == 3 && names[0] == "haxe" && names[1] == "macro" && names[2] == "Expr") imported = true;
				case IAll:
					var names = [for (pn in imp.path) pn.name];
					if (names.length == 2 && names[0] == "haxe" && names[1] == "macro") imported = true;
			}
				if (!imported && imports != null && imports.names.exists("Expr")) imported = true;
				if (!imported && module.path.pack.length > 0
					&& (module.path.pack[0] == "haxe" || module.path.pack[0] == "utest")) imported = true;
				if (!imported && module.extra.file != null) {
					var moduleFile = module.extra.file.toLowerCase();
					if (moduleFile.indexOf("utest") >= 0 || moduleFile.indexOf("\\haxe\\") >= 0 || moduleFile.indexOf("/haxe/") >= 0) imported = true;
				}
				if (!imported && module.extra.file != null) {
					try {
						var source = sys.io.File.getContent(module.extra.file);
						if (source.indexOf("import haxe.macro.Expr") >= 0) imported = true;
					} catch (_:Dynamic) {}
				}
				if (!imported) throw new hxc.context.Context.ContextError("Type not found : Expr", th.pos);
			case _:
		}
	}

	static function resolveEnum(ctx:Context, e:TEnum, d:Definition<EnumFlag, Array<EnumConstructor>>, p:Position):Void {
		// The enum self-type, with its declared params applied.
		var et = TEnum(e, TypeFunctions.extractParamTypes(e.params));
		var index = 0;
		var isFlat = true;
		for (c in d.dData) {
			// Constructor-local type params (e.g. `enum E { C<T>(x:T); }`) in scope.
			var ctorParams:TypeParams = [];
			if (c.ecParams.length > 0)
				ctorParams = Typeload.typeTypeParams(ctx, {pack: [], name: c.ecName.name}, c.ecParams, null, TPHEnumConstructor);
			var localParams = ctorParams.concat(e.params);
			var rt = switch (c.ecType) {
				case null:
					et;
				case th:
					var t = Typeload.loadTypeHint(ctx, localParams, th, false);
					switch (TypeFunctions.follow(t)) {
						case TEnum(te, _) if (te == e):
						case _:
							throw new ContextError("Explicit enum type must be of the same enum type", c.ecPos);
					}
					t;
			};
			var t:T = if (c.ecArgs.length == 0) {
				rt;
			} else {
				var args:Array<TSignatureArg> = [];
				for (a in c.ecArgs) {
					var at = Typeload.loadTypeHint(ctx, localParams, a.type, false);
					if (a.opt) at = ctx.basic.tnull(at);
					args.push({name: a.name, opt: a.opt, t: at});
				}
				TFun({args: args, ret: rt});
			};
			var ef = new TEnumField(c.ecName.name, t, c.ecPos, c.ecName.pos, c.ecDoc, index, ctorParams, c.ecMeta);
			e.constrs.set(c.ecName.name, ef);
			e.names.push(c.ecName.name);
			if (c.ecArgs.length > 0) isFlat = false;
			index++;
		}
		// An enum whose every constructor takes no argument is FLAT, and carries the meta that unification
		// tests for a haxe.FlatEnum constraint.
		if (isFlat) e.meta = [{name: hxc.core.TypeUnification.Meta.FlatEnum, params: [], pos: Position.nullPos}].concat(e.meta);
	}

	// Field-type resolution: the part of creating a variable, method or property field that
	// resolves its type.
	public static function resolveFieldType(ctx:Context, typeParams:TypeParams, cf:TClassField, cff:ClassField, ?ownerModule:ModuleDef):Void {
		var fieldModule = ownerModule == null ? ctx.currentModule : ownerModule;
		switch (cff.cffKind) {
			case FVar(th, _):
				// Var/final field with an explicit hint -> resolve; else leave the mono
				// the typer would infer from the initializer expr in Phase 3 pt c.
				if (th != null) cf.type = Typeload.loadComplexType(ctx, typeParams, th);
			case FProp(_, _, th, _):
				if (th != null) cf.type = Typeload.loadComplexType(ctx, typeParams, th);
			case FFun(fd):
				// Method -> TFun(args, ret). Faithful: optional arg -> Null<T>; missing hint
				// > fresh mono (the typer infers it).
				var isStaticField = false;
				for (acc in cff.cffAccess) if (acc.access == AStatic) isStaticField = true;
				var isAbstractMember = TypeFunctions.hasClassFieldFlag(cf, CfImpl);
				var outerParams = (isStaticField && !isAbstractMember) ? [] : typeParams;
				var localParams = outerParams;
				var methodParams:TypeParams = [];
				if (fd.fParams.length > 0) {
					// Add method type params so arg/return hints referencing them resolve.
					methodParams = Typeload.typeTypeParams(ctx, {pack: [], name: cf.name}, fd.fParams, outerParams, cf.name == "new" ? TPHConstructor : TPHMethod);
					localParams = methodParams.concat(outerParams);
				}
				var isMacroField = false;
				for (acc in cff.cffAccess) if (acc.access == AMacro) isMacroField = true;
				if (isMacroField) {
					for (fa in fd.fArgs) checkMacroExprHint(ctx, fa.type, fieldModule);
					checkMacroExprHint(ctx, fd.fType, fieldModule);
				}
				var args:Array<TSignatureArg> = [];
				for (i in 0...fd.fArgs.length) {
					var fa = fd.fArgs[i];
					if (isMacroField && fieldModule != null) ctx.currentModule = fieldModule;
					var implicitThis = false;
					for (m in fa.meta) if (m.name == ":implicitThis") implicitThis = true;
					var argParams = implicitThis ? outerParams : localParams;
					var at = isMacroField ? loadMacroHint(ctx, argParams, fa.type) : Typeload.loadTypeHint(ctx, argParams, fa.type, false);
					if (isMacroField && fieldModule != null) ctx.currentModule = fieldModule;
					// A haxe.Rest argument must be last, non-optional and defaultless (checked at signature
					// build, so
					// externs check too).
					// The syntactic name gates the follow: following every argument's lazy hint at resolve
					// time recurses
					// into resolution.
					var restHint = switch (fa.type != null ? fa.type.ct : null) {
						case CTPath(tp) if (tp.tname == "Rest" || tp.tsub == "Rest"): true;
						case _: false;
					};
					if (restHint) switch (TypeFunctions.follow(at)) {
						case TAbstract(ra, rp) if (rp.length == 1 && ra.path.pack.length == 1 && ra.path.pack[0] == "haxe" && ra.path.name == "Rest"):
							// Recorded, not raised: resolveModule's recovery would swallow a raise.
							if (fa.opt) ctx.addDiagnostic("Rest argument cannot be optional", fa.name.pos);
							else if (fa.value != null) ctx.addDiagnostic("Rest argument cannot have default value", fa.value.pos);
							else if (i != fd.fArgs.length - 1) ctx.addDiagnostic("Rest should only be used for the last function argument", fa.name.pos);
						case _:
					}
					if (fa.opt || (fa.value != null && fa.value.expr.match(EConst(CIdent("null"))))) at = ctx.basic.tnull(at); // A null default makes the argument nullable
					var sigOpt = fa.opt || fa.value != null;
					args.push({name: fa.name.name, opt: sigOpt, t: at});
				}
				if (isMacroField && fieldModule != null) ctx.currentModule = fieldModule;
				// Constructor's return type is always Void regardless of any hint, so its signature reads
				// TFun(args, Void). Visible in a cppia host's __script_construct signature.
				var ret = (cf.name == "new" && !isStaticField) ? ctx.basic.tvoid
					: (isMacroField ? loadMacroHint(ctx, localParams, fd.fType) : Typeload.loadTypeHint(ctx, localParams, fd.fType, false));
				if (isMacroField && fieldModule != null) ctx.currentModule = fieldModule;
				cf.type = TFun({args: args, ret: ret});
				cf.params = methodParams;
				// The argument metadata is generated at field CREATION, so a body-less function (an extern
				// declaration) records its defaults too.
				hxc.typing.TypeFields.setFunctionValueMeta(cf, fd);
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
		// The filter REBUILDS meta: an @:overload(function(){}) entry is consumed into overloads and
		// dropped from the field's own metadata (a bare @:overload, which marks native platform
		// overloading,
		// is kept).
		var keptMeta:Metadata = [];
		for (m in cf.meta) {
			var converted = false;
			if (m.name != ":overload" || m.params.length != 1) { keptMeta.push(m); continue; }
			switch (m.params[0].expr) {
				case EFunction(_, f):
					// Method-local type params on the overload function (rare for the std/externs
					// we touch; load them so arg/ret hints referencing them resolve).
					var localParams = typeParams;
					var ovParams:TypeParams = [];
					if (f.fParams.length > 0) {
						// Enclosing params stay in scope for an overload param's constraint.
						ovParams = Typeload.typeTypeParams(ctx, {pack: [], name: cf.name}, f.fParams, typeParams, cf.name == "new" ? TPHConstructor : TPHMethod);
						localParams = ovParams.concat(typeParams);
					}
					var args:Array<TSignatureArg> = [];
					for (fa in f.fArgs) {
						// Topt: explicit type required, load the hint; opt `?`
						// Null-wraps; a default value reports opt in the signature (no wrap).
						var at = Typeload.loadTypeHint(ctx, localParams, fa.type, false);
						if (fa.opt || (fa.value != null && fa.value.expr.match(EConst(CIdent("null"))))) at = ctx.basic.tnull(at); // A null default makes the argument nullable
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
					converted = true;
				case _:
			}
			if (!converted) keptMeta.push(m);
		}
		cf.meta = keptMeta;
		if (overloads.length > 0) cf.overloads = overloads;
	}
}
