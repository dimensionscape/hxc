package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.NotFound;
import hxc.core.TypeUnification;
import hxc.core.TPrinting;
import hxc.core.Ref;
import hxc.context.Context;
import hxc.context.Context.ContextError;
import hxc.typing.Typeload.TypeParamHost;
import haxe.ds.StringMap;

class TypeResolve {
	static final pNull = Position.nullPos;

	public static function resolveModule(ctx:Context, m:ModuleDef):Void {
		if (m.extra.resolved >= 1) return;
		m.extra.resolved = 1;
		// An unresolvable `using` aborts the module's initialisation before it reaches a single
		// declaration, so the types exist but none of them is ever initialised. Resolving them anyway
		// prints a cascade of follow-on errors.
		if (ctx.moduleAborted.exists(Context.pathKey(m.path)) && abortsOnDeclError(ctx)) {
			markModuleErrored(ctx, m);
			return;
		}
		var savedMod = ctx.currentModule;
		ctx.currentModule = m; // Resolve in-module sibling types against m.types first
		// The reference splits this in two. init_module_type runs over the declarations IN order, and
		// everything but a plain class does its work there and then (init_abstract at init_enum,
		// init_typedef); a class only queues its build `delay ctx PBuildClass`). That bucket drains LIFO
		// takes the head), so the classes build last declaration first, after the rest of the module is
		// already initialised. hxc resolves eagerly, so it builds the same list by hand.
		var rest = [], classes = [];
		for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (c.kind.match(KNormal)): classes.unshift(mt);
			case _: rest.push(mt);
		}
		for (mt in rest.concat(classes)) {
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
				// A declaration error (bad heritage, final extend, ...) is recorded, and in a BATCH compile the
				// rest of the module is ABANDONED: the reference's typing_error raises out of init_module_type,
				// so no later declaration of that module is reached and exactly one such error is ever printed.
				markModuleErrored(ctx, m);
				ctx.addDiagnostic(e.message, e.pos, e.depth);
				ctx.currentModule = m;
				if (abortsOnDeclError(ctx)) break;
			} catch (e:hxc.core.TypingError) {
				markModuleErrored(ctx, m);
				ctx.addDiagnostic(e.message, e.pos, e.depth);
				ctx.currentModule = m;
				if (abortsOnDeclError(ctx)) break;
			} catch (e:Dynamic) {
				if (hxc.parser.ParserError.isParseFailure(e)) throw e;
				ctx.currentModule = m;
			}
		}
		for (mt in m.types) resolveUsingMetadata(ctx, mt);
		ctx.currentModule = savedMod;
	}

	/**
	 * A display request's job is to answer, so the errors that would cost the answer are skipped
	 * rather than raised, and the module keeps resolving.
	 */
	static inline function abortsOnDeclError(ctx:Context):Bool {
		return ctx.displaySpec == null;
	}

	// The error raises out of module initialisation, so the module's DELAYED field typing never runs -
	// for any of its types, not just the one that failed. A sibling class typed anyway reports every
	// member it expected from the broken one.
	static function markModuleErrored(ctx:Context, m:ModuleDef):Void {
		for (mt in m.types)
			ctx.declErrored.set(Context.pathKey(TypeFunctions.tInfos(mt).path), true);
	}


	/**
	 * Resolve all loaded modules currently in the Context.
	 */
	public static function resolveAll(ctx:Context):Void {
		// NEWEST module first. Field signatures are typed in a DELAYED pass, and a pass bucket is LIFO (a
		// delay prepends, a flush takes the head), so the module delayed first drains last. hxc derives
		// signatures eagerly here, so walking forward reports anything a type load emits on the way (the
		// deprecated-typedef warning is the observable one) in the opposite order. Same reasoning as
		// runBuildMacros, which iterates modules in reverse because PBuildClass delays are LIFO. Modules
		// loaded DURING resolution are appended, and those still resolve in order.
		var n = ctx.modules.length;
		var i = n - 1;
		while (i >= 0) {
			resolveModule(ctx, ctx.modules[i]);
			i--;
		}
		// Anything newly appended still resolves forward
		var j = n;
		while (j < ctx.modules.length) { resolveModule(ctx, ctx.modules[j]); j++; }
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
		if (hxc.core.PerfCount.on) hxc.core.PerfCount.bump("resolveType");
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
				// Anything that is not a dot path is rejected, and that is reported at the argument.
				if (parts == null || parts.length == 0)
					throw new ContextError("dot path expected", param.pos);
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
				var path:hxc.core.Globals.Path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
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
	static function answerHeritCompletion(ctx:Context, c:TClass, isExtends:Bool, p:Position,
			?subjectName:String, ?subjectPos:Position):Void {
		var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
		var items:Array<hxc.compiler.DisplayXml.ToplevelItem> = [];
		var mts:Array<ModuleType> = [];
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
				if (keep) {
					items.push({kind: "type", name: inf.path.name, path: hxc.core.Globals.sTypePath(inf.path)});
					mts.push(mt);
				}
			}
			// The XML lane sorts by name; the JSON one keeps the pair aligned.
			var order = [for (i in 0...items.length) i];
			order.sort(function(a, b) return items[a].name < items[b].name ? -1 : (items[a].name > items[b].name ? 1 : 0));
			items = [for (i in order) items[i]];
			mts = [for (i in order) mts[i]];
		}
		// CRExtends is 5, CRImplements 6.
		var tc = new hxc.compiler.DisplayXml.ToplevelCompletion(items, mts);
		tc.kind = isExtends ? 5 : 6;
		// Re-raised with the subject of the type-hint completion the failed load produced, i.e. the path
		// the user was writing.
		tc.subjectPos = subjectPos != null ? subjectPos : p;
		tc.subjectName = subjectName;
		// The same filter has to cover the class-path exploration the collection also reaches, whose files
		// hxc parses lazily - so the decision travels with the raise and is applied where the answer is
		// built, not here inside typing.
		tc.heritIsExtends = isExtends;
		tc.heritIsInterface = isInterface;
		tc.heritSelf = hxc.core.Globals.sTypePath(c.path);
		tc.heritHasHack = TypeFunctions.hasMeta(":hack", c.meta);
		throw tc;
	}

	// The parser's magic type path reaching load_type_def means the cursor is in a type position, and
	// every type in scope is the answer (CRTypeHint). The heritage answer above is the same collection
	// with set_heritance's extra filtering on top.
	public static function answerTypeHintCompletion(ctx:Context, p:Position, ?subjectName:String, kind:Int = 4):Void {
		var items:Array<hxc.compiler.DisplayXml.ToplevelItem> = [];
		var mts:Array<ModuleType> = [];
		var seenPaths = new Map<String, Bool>();
		// The current module's own types first. They exist from the moment the module is created, well
		// before it finishes loading, which is when a type hint inside that same module asks.
		var all:Array<ModuleType> = ctx.currentModule == null ? [] : ctx.currentModule.types.copy();
		for (mt in visibleTypesForCompletion(ctx)) all.push(mt);
		for (mt in all) {
			var inf = TypeFunctions.tInfos(mt);
			// A PRIVATE type is still offered inside the module that declares it.
			if (inf.isPrivate && (ctx.currentModule == null || inf.module != ctx.currentModule)) continue;
			var key = hxc.core.Globals.sTypePath(inf.path);
			if (seenPaths.exists(key)) continue;
			seenPaths.set(key, true);
			items.push({kind: "type", name: inf.path.name, path: key});
			mts.push(mt);
		}
		// A type collection reaches the same cache-files source an expression collection does, which is
		// where a bare PACKAGE name comes from. Without it a type hint offers types only, never `haxe`.
		var nTyped = items.length;
		hxc.typing.Typer.addCachedFileTypes(ctx, items, seenPaths);
		// The module types only cover the entries collected above; the cache-file ones have no
		// loaded type yet, so the JSON lane emits what it has and the XML lane the whole list.
		var typedItems = items.slice(0, nTyped);
		items.sort(function(a, b) return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
		// The type PARAMETERS in scope are part of the collection too, which makes a constructible one
		// reachable from `new <cursor>`.
		for (tp in hxc.typing.Typeload.currentTypeParams) switch (TypeFunctions.follow(tp.type)) {
			case TInst(pc, _):
				var key = hxc.core.Globals.sTypePath(pc.path);
				if (seenPaths.exists(key)) continue;
				seenPaths.set(key, true);
				items.unshift({kind: "type", name: pc.path.name, path: key, tparam: pc});
			case _:
		}
		// CRTypeHint is 4.
		var tc = new hxc.compiler.DisplayXml.ToplevelCompletion(items, mts);
		tc.kind = kind;
		tc.subjectPos = p;
		// The subject is keyed by the path the user was writing, which is what the client filters on.
		tc.subjectName = subjectName;
		throw tc;
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

	// A heritage entry whose type is a BARE unresolved name is DROPPED, silently, whenever a display
	// mode is active: there is no super class and no error. It is the one heritage arm that swallows
	// rather than reports, so a request answered from a file whose `extends` no longer resolves still
	// answers. A PACKAGED path is not covered (it still reports `Type not found : unit.Test`), and
	// neither is a plain compile.
	//
	// The guard is the display mode, not the ignore-errors check: that check arms the has-error flag
	// as a side effect, and the flag decides between aborting with the recorded errors and reporting
	// the missing completion point. So this reads the setting without arming the flag.
	static function heritageDropped(ctx:Context, err:ContextError):Bool {
		return switch (err.kind) {
			case ModuleNotFound(m) if (m.pack.length == 0 && ctx.ignoreErrors):
				// Called directly rather than through a delay.
				if (ctx.errorInDiagnosticsRun(err.pos))
					hxc.typing.Typer.handleUnresolvedIdentifier(ctx, m.name, err.pos);
				true;
			case _: false;
		};
	}

	public static function resolveClass(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		// A build marks the class BUILDING at its START, so a class reached again while it is building does
		// NOTHING further rather than re-running its heritage. There are two entry points - the module loop
		// and forceBuild - so the state belongs to the build, not to one of its callers: forcing a super
		// the loop is already resolving must not run the heritage twice and trip `superClass != null` as
		// "Cannot extend several classes".
		var st0 = buildState.get(c);
		if (st0 == BUILDING || st0 == BUILT) return;
		buildState.set(c, BUILDING);
		if (hxc.core.PerfCount.on) hxc.core.PerfCount.bump("resolveClass");
		// Pass 1: heritage. Filter HExtends/HImplements; load each type; set relations.
		for (f in d.dFlags) switch (f) {
			case HExtends(pt):
				if (pt.path.tname == "") answerHeritCompletion(ctx, c, true, pt.pos);
				var t:Null<T> = try Typeload.loadInstance(ctx, c.params, pt.path, pt.pos, false) catch (err:ContextError) {
					if (err.message == "Recursive class") throw new ContextError(err.message, pt.pos, err.kind);
					if (heritageDropped(ctx, err)) null else throw err;
				}
				// A heritage path that answered a type HINT completion is re-raised filtered for the position,
				// carrying that answer's own subject.
				catch (tc:hxc.compiler.DisplayXml.ToplevelCompletion) {
					if (tc.kind != 4) throw tc;
					answerHeritCompletion(ctx, c, true, pt.pos, tc.subjectName, tc.subjectPos);
					throw tc;
				};
				if (t != null) checkHerit(ctx, c, t, true, pt.pos, p);
			case HImplements(pt):
				if (pt.path.tname == "") answerHeritCompletion(ctx, c, false, pt.pos);
				var t:Null<T> = try Typeload.loadInstance(ctx, c.params, pt.path, pt.pos, false) catch (err:ContextError) {
					if (err.message == "Recursive class") throw new ContextError(err.message, pt.pos, err.kind);
					if (heritageDropped(ctx, err)) null else throw err;
				}
				// A heritage path that answered a type HINT completion is re-raised filtered for the position,
				// carrying that answer's own subject.
				catch (tc:hxc.compiler.DisplayXml.ToplevelCompletion) {
					if (tc.kind != 4) throw tc;
					answerHeritCompletion(ctx, c, false, pt.pos, tc.subjectName, tc.subjectPos);
					throw tc;
				};
				if (t != null) checkHerit(ctx, c, t, false, pt.pos);
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
		// Build with `fun() -> Built` once a class is built, so every later reach for its fields is a
		// no-op. This is the same one-shot: an abstract's implementation is reached both from its
		// abstract and from the ordinary class path, and without the check whichever ran second derived
		// every signature a second time.
		if (buildState.get(c) != BUILT) resolveClassFields(ctx, c, d, p);
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
	// Classes whose property accessors have already been checked. Same never-reset pattern as
	// buildState: a TClass instance belongs to one compile, so a stale entry cannot collide.
	static var propAccessorsChecked = new haxe.ds.ObjectMap<TClass, Bool>();
	// The same, for the post-heritage field collision checks. resolveClassFields runs more than
	// once for some classes and only its IDEMPOTENT work may repeat.
	static var fieldChecksDone = new haxe.ds.ObjectMap<TClass, Bool>();
	static inline var BUILDING = 1;
	static inline var BUILT = 2;

	/**
	 * Forcing a class runs its heritage and then its field initialisation, and it becomes Built only
	 * after both. While the build runs it answers `Building [c]`, which is how a reentrant force sees
	 * the cycle, and a class whose build FAILED is marked Built rather than retried forever.
	 *
	 * Forcing on demand from every site that needs a class (an anon unified against a class, the
	 * Iterator.next lookup, ...) is what lets declarations build in any order.
	 */
	public static function forceBuild(ctx:Context, c:TClass):BuildState {
		var st = buildState.get(c);
		if (st == BUILT) return Built;
		if (st == BUILDING) return Building([c]);
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return Built;
		switch (entry.decl) {
			case EClass(d):
				var savedModule = ctx.currentModule;
				if (c.module != null) ctx.currentModule = c.module;
				try resolveClass(ctx, c, d, entry.pos)
				catch (e:Dynamic) {
					ctx.currentModule = savedModule;
					buildState.set(c, BUILT);
					throw e;
				}
				ctx.currentModule = savedModule;
				buildState.set(c, BUILT);
				return Built;
			case _:
				return Built;
		}
	}

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
				try resolveClassFields(ctx, c, d, p) catch (e:Dynamic) {
					if (hxc.parser.ParserError.isParseFailure(e)) { ctx.currentModule = savedModule; throw e; }
				}
				ctx.currentModule = savedModule;
				buildState.set(c, BUILT);
				return true;
			case _:
				return false;
		}
	}


	public static function resolveClassFields(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		if (hxc.core.PerfCount.on) hxc.core.PerfCount.bump("resolveClassFields");
		// The class whose fields are being built, for everything a field signature loads; it nests, because
		// loading one signature can resolve another class's fields.
		var savedResolvingClass = ctx.resolvingClass;
		ctx.resolvingClass = c;
		try resolveClassFieldsInner(ctx, c, d, p) catch (e:Dynamic) {
			ctx.resolvingClass = savedResolvingClass;
			throw e;
		}
		ctx.resolvingClass = savedResolvingClass;
	}

	static function resolveClassFieldsInner(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		// The first thing field initialisation does after the @:libType check: a class carrying @:macro is
		// a Haxe 3 leftover and is REPORTED (as a display error, so the class still builds).
		if (TypeFunctions.hasMeta(":macro", c.meta))
			ctx.addDiagnostic("Macro classes are no longer allowed in haxe 3", c.pos);
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
			checkFieldAccessModifiers(ctx, cff);
			var isStatic = false;
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			var isAbstractMember = isAbsImpl && !isStatic && cff.cffName.name != "new";
			if (isAbstractMember) isStatic = true;
			// The constructor lives in constructor (not fields); resolve it there.
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else (isStatic ? c.statics : c.fields).get(cff.cffName.name);
			if (cf == null) continue;
			// A duplicate declaration was reported and never added, so it declares no field; pairing it by
			// name hands it the field it merely collided with.
			if (ctx.droppedFieldDecls.exists(cff)) continue;
			var key = (isStatic ? "s:" : "i:") + cff.cffName.name;
			var occ = nameSeen.exists(key) ? nameSeen.get(key) : 0;
			nameSeen.set(key, occ + 1);
			// Occurrence > 0 is a merged overload sibling: resolve onto its overloads slot. A second
			// constructor with no slot was reported as a duplicate and dropped (the first is kept), so it
			// binds nothing; falling through to `cf` rebinds the surviving constructor to the rejected
			// declaration.
			if (cff.cffName.name == "new" && occ > 0 && cf.overloads.length < occ) continue;
			// A real `overload` sibling lives in overloads. Without that - two declarations of one name that
			// are not overloads, which an abstract's body-less @:op set is - the k-th declaration is the
			// k-th REGISTERED field of that name, since ModuleLoader adds them in declaration order. The
			// by-name lookup above cannot express that: statics holds one entry per name and hands back the
			// last, so every earlier declaration resolved onto it and its own field never got a signature at
			// all.
			var target = if (occ > 0 && cf.overloads.length >= occ) cf.overloads[cf.overloads.length - occ]
				else nthFieldNamed(isStatic ? c.orderedStatics : c.orderedFields, cff.cffName.name, occ, cf);
			if (isAbstractMember) TypeFunctions.addClassFieldFlag(target, CfImpl);
			try {
				var params = if (isAbsImpl && abstractTypeParams != null && TypeFunctions.hasClassFieldFlag(target, CfImpl))
					abstractTypeParams
				else
					c.params;
				// @:generic exists to specialise per type argument, so a function with none of its own has
				// nothing to specialise on. It is raised here, at the field's own position, so the error is
				// recorded and the field dropped; raised at registration instead it ends the module and the
				// second message, about the now-unknown name, never comes.
				if (TypeFunctions.hasClassFieldFlag(target, CfGeneric)) switch (cff.cffKind) {
					case FFun(fd) if (fd.fParams.length == 0):
						throw new hxc.core.TypingError("Generic functions must have type parameters", cff.cffPos);
					case _:
				}
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
				// A field's signature is typed under protection, so a hint that does not resolve is an error
				// about the declaration, not a field quietly left untyped. The type load has already recovered
				// the cases a report is meant to survive.
				ctx.unresolvedFields++;
				throw e;
			} catch (e:hxc.core.TypingError) {
				// A Custom error raised at the field'S own position is recorded and the field is DROPPED, so
				// the module keeps typing and a later use of that name reports for itself. Any other position
				// or kind propagates and ends the module, which is what the declaration-error abort is for.
				var own = e.pos != null && cff.cffPos != null && e.pos.file == cff.cffPos.file
					&& e.pos.min == cff.cffPos.min && e.pos.max == cff.cffPos.max;
				if (!own || cff.cffName.name == "new"
					|| Std.isOfType(e, hxc.core.TypingError.ModuleNotFoundError)
					|| Std.isOfType(e, hxc.core.TypingError.CallError)) throw e;
				ctx.addDiagnostic(e.message, e.pos, e.depth);
				if (isStatic) {
					c.statics.remove(target.name);
					c.orderedStatics.remove(target);
				} else {
					c.fields.remove(target.name);
					c.orderedFields.remove(target);
				}
			}
		}
		linkPropertyAccessors(ctx, c, isAbsImpl);
		checkInheritedFieldCollisions(ctx, c, isAbsImpl);
	}

	// The nearest class UP the CHAIN declaring an instance field of this name - the superclass, then
	// its super, then the interfaces of each, depth first. Interfaces count, which superClass alone
	// does not reach.
	static function getDeclaredIn(sup:Null<{c:TClass, params:Array<T>}>, name:String):Null<TClass> {
		if (sup == null) return null;
		var c = sup.c;
		if (c.fields.exists(name)) return c;
		var r = getDeclaredIn(c.superClass, name);
		if (r != null) return r;
		for (i in c.interfaces) {
			var r2 = getDeclaredIn(i, name);
			if (r2 != null) return r2;
		}
		return null;
	}

	// Two checks that can only run once the HERITAGE is resolved, which is why they do not live
	// with the rest of the field registration in ModuleLoader.
	static function checkInheritedFieldCollisions(ctx:Context, c:TClass, isAbsImpl:Bool):Void {
		if (ctx == null || isAbsImpl) return;
		// The two checks do not share an exemption list. The static/instance collision is skipped on an
		// EXTERN class; the variable redefinition check is not - an extern subclass redeclaring an
		// inherited variable is still an error. Both skip @:libType.
		if (TypeFunctions.hasMeta(":libType", c.meta)) return;
		if (fieldChecksDone.exists(c)) return;
		fieldChecksDone.set(c, true);
		var isExtern = TypeFunctions.hasClassFlag(c, CExtern);
		// The half ModuleLoader cannot see: for a static field the superclass chain's instance fields
		// collide too. Skipped when the same-class half has already reported, since the reference
		// computes one `dup` and reports once.
		if (!isExtern) for (cf in c.orderedStatics) {
			if (cf.name == "__init__" || c.fields.exists(cf.name)) continue;
			if (getDeclaredIn(c.superClass, cf.name) != null)
				ctx.addDiagnostic("Same field name can't be used for both static and instance : " + cf.name, cf.pos);
		}
		// `override` needs a parent to override. Like the checks above this cannot run at registration -
		// superClass is not resolved yet, so every legitimately-overriding field in the std would be
		// reported.
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (c.superClass == null && !TypeFunctions.hasClassFlag(c, CInterface)) switch (entry != null ? entry.decl : null) {
			case EClass(d):
				for (cff in d.dData) for (acc in cff.cffAccess) if (acc.access == AOverride)
					ctx.addDiagnostic("Invalid modifier: override on field of class that has no parent", acc.pos);
			case _:
		}
		// The redefinition check runs when a variable binds, so it applies to VARIABLES and properties only
		// -
		// a method legally overrides one.
		for (cf in c.orderedFields) {
			switch (cf.kind) {
				case Var(_):
					var csup = getDeclaredIn(c.superClass, cf.name);
					if (csup == null) continue;
					// An interface declaration reached from a @:csNative class is exempt, a .NET-lib
					// artifact no
					// supported target produces.
					if (TypeFunctions.hasClassFlag(csup, CInterface) && TypeFunctions.hasMeta(":csNative", c.meta)) continue;
					ctx.addDiagnostic("Redefinition of variable " + cf.name + " in subclass is not allowed. Previously declared at "
						+ hxc.core.Globals.sTypePath(csup.path), cf.namePos);
				case _:
			}
		}
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

	// Whether the property was declared with the literal `get`/`set` accessor, which is the only form
	// that requires a method to exist. `dynamic` produces the same AccCall and requires nothing, so the
	// typed field cannot answer this.
	static function declaresAccessorMethod(ctx:Context, c:TClass, propName:String, isRead:Bool):Bool {
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return false;
		switch (entry.decl) {
			case EClass(d):
				for (cff in d.dData) {
					if (cff.cffName.name != propName) continue;
					switch (cff.cffKind) {
						case FProp(g, st, _, _): return (isRead ? g.name == "get" : st.name == "set");
						case _: return false;
					}
				}
			case _:
		}
		return false;
	}

	// The n-th field of this name in declaration order, or `fallback` when there is no such field
	// (a constructor, or a promoted member that is not in this list).
	static function nthFieldNamed(ordered:Array<TClassField>, name:String, n:Int, fallback:TClassField):TClassField {
		var seen = 0;
		for (x in ordered) if (x.name == name) {
			if (seen == n) return x;
			seen++;
		}
		return fallback;
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
		// The method check is scheduled only for a class that is not a library type.
		var isLib = TypeFunctions.hasMeta(":libType", c.meta);
		// The signature LINKING below is idempotent, so it does not matter that an abstract impl resolves
		// its fields more than once; the accessor COMPLAINTS are not, so each check runs exactly once per
		// property declaration.
		var reportAccessors = !propAccessorsChecked.exists(c);
		propAccessorsChecked.set(c, true);
		var pendingAccessorErrors:Array<{at:Int, items:Array<{msg:String, pos:Position}>}> = [];
		function checkAccessor(accName:String, propName:String, ownColl:StringMap<TClassField>, otherColl:StringMap<TClassField>, propIsStatic:Bool, propPos:Position, isRead:Bool):Null<{msg:String, pos:Position}> {
			if (isExtern || isLib || TypeFunctions.hasClassFlag(c, CInterface)) return null;
			if (ownColl.get(accName) != null) return null;
			// A member accessor is looked up through the overloads, which walks the superclass chain, so an
			// inherited getter satisfies the property. A static one is a plain lookup in statics only.
			if (!propIsStatic && getParentField(c, accName) != null) return null;
			var other = otherColl.get(accName);
			if (other != null)
				return {msg: "Method " + accName + " is no valid accessor for " + propName + " because it is " + (propIsStatic ? "not " : "") + "static", pos: other.pos};
			// The accessor exists nowhere. Only a literal `get`/`set` requires one - `dynamic` maps to
			// AccCall too but declares no method - and kind cannot tell those apart, so the declaration
			// decides.
			if (declaresAccessorMethod(ctx, c, propName, isRead))
				return {msg: "Method " + accName + " required by property " + propName + " is missing", pos: propPos};
			return null;
		}
		// The checks that run once the accessor has been found. They sit in a PForce delay, because
		// unifying earlier can resolve a TLazy and generate interface fields too late, so they land after
		// the body typing.
		function checkFoundAccessor(acc:TClassField, propName:String, propPos:Position, pt:T, isSetter:Bool, propIsImpl:Bool):Void {
			// Not gated on extern: the extern exemption belongs to the accessor-not-found case, so an extern
			// property whose accessor is declared with the wrong signature still reports. isLib skips the
			// whole accessor check, and an interface's accessor is generated rather than found.
			// reportAccessors keeps an abstract impl, whose fields resolve more than once, from queueing the
			// delay twice.
			if (isLib || TypeFunctions.hasClassFlag(c, CInterface) || !reportAccessors) return;
			ctx.delay(hxc.context.Context.PForce, function() {
				// A macro method cannot serve as an accessor. Two reports: the property
				// carries the complaint, the accessor is pointed at as a continuation.
				switch (acc.kind) {
					case Method(MethMacro):
						ctx.addDiagnostic(acc.name + ": Macro methods cannot be used as property accessor", propPos);
						// Hxc's formatter does not add the continuation marker; callers do (see InterfaceCheck's "...
						// " + betterErrorMessage).
						ctx.addDiagnostic("... " + acc.name + ": Accessor method is here", acc.pos, 1);
					case _:
				}
				// The accessor's type must unify with the expected one: `Void -> ret` for a getter and
				// `(value:ret) -> ret` for a setter, and for an abstract member property both carry the
				// `this` argument first.
				var ta = switch (c.kind) {
					case KAbstractImpl(a) if (propIsImpl): TypeFunctions.applyParams(a.params, TypeFunctions.extractParamTypes(a.params), a.thisType);
					case _: null;
				};
				var args:Array<TSignatureArg> = [];
				if (ta != null) args.push({name: "this", opt: false, t: ta});
				if (isSetter) args.push({name: "value", opt: false, t: pt});
				var expected:T = TFun({args: args, ret: pt});
				try TypeUnification.unifyDefault(acc.type, expected)
				catch (ue:hxc.core.TypeUnification.UnifyError) {
					ctx.addDiagnostic("In method " + acc.name + " required by property " + propName, acc.pos);
					ctx.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(ue.errors), acc.pos);
				}
				// An abstract's own property and a plain static accessor cannot be mixed.
				var accIsImpl = TypeFunctions.hasClassFieldFlag(acc, CfImpl);
				if ((propIsImpl && !accIsImpl) || (accIsImpl && !propIsImpl))
					ctx.addDiagnostic("Mixing abstract implementation and static properties/accessors is not allowed", acc.pos);
			});
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
						var accGet:Null<{msg:String, pos:Position}> = null;
						var accSet:Null<{msg:String, pos:Position}> = null;
						if (vk.read.match(AccCall)) {
							var g = fields.get("get_" + name);
							if (g != null) {
								switch (TypeFunctions.follow(g.type)) {
									case TFun(sig): usePropertyType(sig.ret, pt);
									case _:
								}
								checkFoundAccessor(g, name, cf.pos, pt, false, TypeFunctions.hasClassFieldFlag(cf, CfImpl));
							}
							else if (TypeFunctions.hasClassFlag(c, CInterface)) {
								var acc = genAccessor("get_" + name, pt, false);
								fields.set(acc.name, acc);
								genAccessors.push(acc);
							}
							else accGet = checkAccessor("get_" + name, name, fields, other, propIsStatic, cf.pos, true);
						}
						if (vk.write.match(AccCall)) {
							var st = fields.get("set_" + name);
							if (st != null) {
								switch (TypeFunctions.follow(st.type)) {
									case TFun(sig):
										if (sig.args.length > 0) usePropertyType(sig.args[sig.args.length - 1].t, pt);
										usePropertyType(sig.ret, pt);
									case _:
								}
								checkFoundAccessor(st, name, cf.pos, pt, true, TypeFunctions.hasClassFieldFlag(cf, CfImpl));
							}
							else if (TypeFunctions.hasClassFlag(c, CInterface)) {
								var acc = genAccessor("set_" + name, pt, true);
								fields.set(acc.name, acc);
								genAccessors.push(acc);
							}
							else accSet = checkAccessor("set_" + name, name, fields, other, propIsStatic, cf.pos, false);
						}
						// A delay prepends and a flush takes the HEAD, so of the two checks property creation
						// schedules (get, then set) the set one runs first - and across properties the last declared
						// one runs first, so the whole batch is emitted in reverse declaration order below.
						var perProp:Array<{msg:String, pos:Position}> = [];
						if (accSet != null) perProp.push(accSet);
						if (accGet != null) perProp.push(accGet);
						if (perProp.length > 0) pendingAccessorErrors.push({at: cf.pos.min, items: perProp});
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
		// A check is scheduled per property over one declaration-ordered field list; hxc walks statics
		// and members separately, so the batch is re-ordered by declaration position here. Reverse,
		// because the delay bucket flushes LIFO.
		pendingAccessorErrors.sort(function(a, b) return b.at - a.at);
		if (reportAccessors)
			for (pe in pendingAccessorErrors) for (e in pe.items) ctx.addDiagnostic(e.msg, e.pos);
	}

	// Whether c's inheritance chain (itself, supers, implemented interfaces) reaches target.
	static function extendsChain(c:TClass, target:TClass):Bool {
		if (c == target) return true;
		for (i in c.interfaces) if (extendsChain(i.c, target)) return true;
		return c.superClass != null && extendsChain(c.superClass.c, target);
	}

	static function isBasicClassPath(path:hxc.core.Globals.Path):Bool {
		return path.pack.length == 0
			&& (path.name == "Array" || path.name == "String" || path.name == "Date" || path.name == "Xml");
	}

	// The parameter belongs either to the current field, which then has to be @:generic, or to the
	// current class, which then has to be KGeneric. Only the class half can apply here - heritage is
	// resolved with no current field, whose empty parameter list never matches - so the question is
	// just whether the class is generic.
	static function isGenericParameter(c:TClass, csup:TClass):Bool {
		var name = csup.path.name;
		for (tp in c.params) if (tp.name == name) return c.kind.match(KGeneric);
		return false;
	}

	static function checkHerit(ctx:Context, c:TClass, t:T, isExtends:Bool, p:Position, ?declP:Position):Void {
		if (isExtends) {
			if (c.superClass != null) throw new ContextError("Cannot extend several classes", p);
			switch (TypeFunctions.follow(t)) {
				case TInst(csup, params):
					// Array/String/Date/Xml cannot be extended unless both sides are extern.
					if (isBasicClassPath(csup.path)
						&& !(TypeFunctions.hasClassFlag(c, CExtern) && TypeFunctions.hasClassFlag(csup, CExtern)))
						throw new ContextError("Cannot extend basic class", p);
					if (extendsChain(csup, c)) throw new ContextError("Recursive class", p);
					// A type parameter is never a base. The generic wording is reserved for a parameter of a
					// @:generic field or class (the field's params are checked before the class's).
					if (csup.kind.match(KTypeParameter(_))) {
						if (isGenericParameter(c, csup))
							throw new ContextError("Extending generic type parameters is no longer allowed in Haxe 4", p);
						throw new ContextError("Cannot extend type parameters", p);
					}
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
					// Each heritage entry yields a closure that runs before field initialisation: the super
					// is FORCED
					// first, so a base declared later in the module is built before anything reads it, and
					// then its
					// metadata is processed. hxc does not cancel and reschedule the build when the super is
					// not Built;
					// it forces and continues - forceBuild's own BUILDING guard is what stops a cycle
					// recursing.
					forceBuild(ctx, csup);
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
					if (extendsChain(intf, c)) throw new ContextError("Recursive class", p);
					if (!TypeFunctions.hasClassFlag(intf, CInterface))
						throw new ContextError("You can only implement an interface", p);
					// Prepended, so interfaces holds reverse source order
					c.interfaces.unshift({c: intf, params: params});
					TypeFunctions.addDescendant(intf, c);
					// An implemented interface is forced the same way.
					forceBuild(ctx, intf);
					inheritAutoBuild(ctx, c, intf);
				case TDynamic(dt):
					if (c.dynamicType != null) throw new ContextError("Cannot have several dynamics", p);
					// This is recorded as a display error and the class still gets its dynamic - which is why two
					// of them print this once and then the several-dynamics error.
					if (!TypeFunctions.hasClassFlag(c, CExtern))
						ctx.addDiagnostic("In haxe 4, implements Dynamic is only supported on externs", p);
					c.dynamicType = (dt == null) ? TypeFunctions.tDynamic : dt;
				case _:
					throw new ContextError("Should implement by using an interface", p);
			}
		}
	}

	static function resolveAbstract(ctx:Context, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>, p:Position):Void {
		var isCore = TypeFunctions.hasMeta(":coreType", a.meta);
		var isType = false; // Set true once an underlying (AbOver) is seen

		// Wraps each from/to in exc_protect and stores the result as TLazy, so the compatibility unify
		// runs when the type is FORCED, not when it is declared. That deferral is what lets the reference
		// build declarations in any order: an abstract declared before the type it converts to still
		// checks out, because the check happens later. hxc used to unify eagerly in a loop after the
		// flags, which fires while the underlying types may still be shells.
		function loadType(th:TypeHint, ?from:Bool):T {
			var t = Typeload.loadComplexType(ctx, a.params, th);
			if (isCore || from == null) return t;
			if (!isType)
				throw new ContextError("Missing underlying type declaration or @:coreType declaration", p);
			var isFrom = from;
			var r:Ref<TLazy> = new Ref(TypeFunctions.lazyAvailable(t));
			r.set(TypeFunctions.lazyWait(function():T {
				r.set(TypeFunctions.lazyProcessing(function():T return t));
				try {
					if (isFrom) hxc.core.TypeUnification.unifyDefault(t, a.thisType);
					else hxc.core.TypeUnification.unifyDefault(a.thisType, t);
				} catch (_:hxc.core.TypeUnification.UnifyError) {
					throw new ContextError("You can only declare from/to with compatible types", th.pos);
				}
				return t;
			}));
			// A protected lazy type DELAYS A PForce that FORCES it by default. Without it the check is
			// deferred into oblivion: an abstract nobody converts through never has its from/to unified and
			// an incompatible one compiles clean. The deferral and the force are one mechanism; keeping only
			// the deferral loses the check.
			ctx.delay(Context.PForce, function() TypeFunctions.lazyType(r));
			return TLazy(r);
		}

		// A non-core abstract checks at every from/to it loads that the underlying type is already
		// declared - the flags are processed in source order, so this is what a from/to with no `(T)`
		// reports. It is a DIFFERENT message from the one an abstract that ends with no underlying type
		// at all gets. The hint is loaded first, so a broken from/to type reports before this.
		function requireUnderlying():Void {
			if (!isCore && !isType)
				throw new ContextError("Missing underlying type declaration or @:coreType declaration", p);
		}
		var fromPos:Array<Position> = [];
		var toPos:Array<Position> = [];
		for (f in d.dFlags) switch (f) {
			case AbFrom(th): a.from.push(loadType(th, true)); requireUnderlying(); fromPos.push(th.pos);
			case AbTo(th): a.to.push(loadType(th, false)); requireUnderlying(); toPos.push(th.pos);
			case AbOver(th):
				// The implementation check comes first: a @:coreType abstract with no fields has no impl class,
				// and that is what it is told, not that it cannot have an underlying type.
				if (a.impl == null)
					throw new ContextError("Abstracts with underlying type must have an implementation", a.pos);
				if (isCore) throw new ContextError("@:coreType abstracts cannot have an underlying type", p);
				var at = Typeload.loadComplexType(ctx, a.params, th);
				// The underlying type through load_instance, where a typedef is a TLazy the reference forces on
				// demand. hxc resolves declarations eagerly in source order, so a typedef declared after this
				// abstract is still a bare shell here. Force it; resolveTypeOnDemand's own re-entry guard is
				// what makes a RECURSIVE typedef terminate.
				switch (at) {
					case TType(td, _): resolveTypeOnDemand(ctx, TTypeDecl(td));
					// Not the same for an abstract OVER ANOTHER abstract.
					case _:
				}
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
			// / for a class's fields with `ignore(c.build())`, which is one-shot: whoever gets there first
			// does the work and everyone after is a no-op. Deriving the impl here as well as through the
			// ordinary class path meant every abstract implementation in the program had its field
			// signatures built twice - the only classes in a compile that did.
			buildClassFields(ctx, a.impl, p);
		}

		resolveAbstractOps(ctx, a, d);

	}

	static function resolveAbstractOps(ctx:Context, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>):Void {
		if (a.impl == null) return;
		var c = a.impl;
		a.ops = [];
		a.unops = [];
		a.array = [];
		// Each SYNTAX field is processed with the field built from it, so an OVERLOADED @:op name reaches
		// every declaration. Looking the field up by name cannot do that: statics holds one entry per
		// name, so it hands back the same cf twice, one operator is registered against a field whose
		// signature never resolved, and once a body-less declaration removes that one from statics the
		// sibling is never visited and survives into the output. ModuleLoader builds the impl class from
		// `[for (f in d.dData) transformAbstractField(...)]`, one impl field per declaration and in the
		// same order, so the k-th declaration of a name is the k-th impl field of that name: pair
		// positionally on that, taking the next not-yet-handled field of that name. The snapshot is taken
		// before the loop because the decl-only removal below mutates orderedStatics as it goes.
		var implSnapshot = c.orderedStatics.copy();
		var nameOccurrence = new haxe.ds.StringMap<Int>();
		for (cff in d.dData) {
			var fname = cff.cffName.name;
			var occ = nameOccurrence.exists(fname) ? nameOccurrence.get(fname) : 0;
			nameOccurrence.set(fname, occ + 1);
			var cf:Null<TClassField> = null;
			var seen = 0;
			for (x in implSnapshot) if (x.name == fname) {
				if (seen == occ) { cf = x; break; }
				seen++;
			}
			// A member field promoted to a static under a different name, or one this class never
			// registered, still falls back to the by-name lookup.
			if (cf == null) cf = abstractImplField(c, fname);
			if (cf == null) continue;
			// The operand type the @:op and @:resolve checks compare against. A field declared without
			// `static`
			// in an abstract is an abstract member and its operand is the UNDERLYING type, because `this`
			// has been prepended to the signature; a static one compares against the abstract itself.
			var isStatic = false;
			var isMacroField = false;
			for (acc in cff.cffAccess) switch (acc.access) {
				case AStatic: isStatic = true;
				case AMacro: isMacroField = true;
				case _:
			}
			var isAbstractMember = !isStatic;
			var ta = TAbstract(a, [for (_ in a.params) TypeFunctions.mkMono()]);
			var tthis = (isAbstractMember || TypeFunctions.hasMeta(":to", cf.meta)) ? TypeFunctions.monomorphs(a.params, a.thisType) : a.thisType;
			var targ = isAbstractMember ? tthis : ta;
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
				registerResolveField(ctx, a, cf, cff, cf.pos, targ, isMacroField);
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
							// A binary operator overload must take the operand type on at least one side,
							// and the ARITY that
							// is wrong is reported differently for a member and a static, because the
							// member signature carries
							// the implicit `this`. A trailing optional PosInfos argument does not count
							// toward the arity either
							// way.
							var leftEq = false, rightEq = false;
							switch (TypeFunctions.follow(cf.type)) {
								case TFun(sig) if (sig.args.length == 2
									|| (sig.args.length == 3 && sig.args[2].opt && isPosInfos(sig.args[2].t))):
									leftEq = TypeUnification.typeIseqDefault(targ, sig.args[0].t);
									rightEq = TypeUnification.typeIseqDefault(targ, sig.args[1].t);
								case _:
									throw new ContextError(isAbstractMember ? "Member @:op functions must accept exactly one argument" : "Static @:op functions must accept exactly two arguments",
										cf.pos);
							}
							if (!leftEq && !rightEq)
								throw new ContextError("The left or right argument type must be " + TPrinting.sTypeStr(targ), cf.pos);
							if (rightEq && TypeFunctions.hasMeta(":commutative", cf.meta))
								throw new ContextError("Invalid metadata: @:commutative is only allowed if the right argument is not " + TPrinting.sTypeStr(targ),
									cf.pos);
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
							// Reported at pos - the whole field - not at the @:op argument, so a duplicate points at the
							// declaration.
							registerResolveField(ctx, a, cf, cff, cf.pos, targ, isMacroField);
							allowsNoExpr = true;
						case _:
					}
				}
			}
			// A body-less function in an abstract cannot have its return type inferred from anything, so it
			// must be written out. This precedes the @:noExpr tagging below and applies to every body-less
			// function of the abstract, whether or not the metadata on it allows the missing body.
			switch (cff.cffKind) {
				case FFun(fd) if (fd.fExpr == null && fd.fType == null):
					throw new ContextError("Functions without expressions must have an explicit return type", cf.pos);
				case _:
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
			var meta = TypeFunctions.getMetaOpt(":native", cf.meta);
			if (meta == null) return null;
			switch (meta.params.length > 0 ? meta.params[0].expr : null) {
				case EConst(CString(s, _)): s;
				case _: null;
			}
		} catch (_:NotFound) null;
	}

	static function registerResolveField(ctx:Context, a:TAbstract, cf:TClassField, cff:ClassField, p:Position, targ:T, isMacroField:Bool):Void {
		// A resolve read is (this, String) and a write is (this, String, value); each may carry a trailing
		// optional PosInfos argument (auto-filled at the call site), so only the leading count
		// distinguishes
		// them (isEmptyOrPosInfos on the tail).
		// The two leading arguments are checked against the operand type and String, and a macro field is
		// exempt because its arguments are Exprs.
		function checkFun(t1:T, t2:T):Void {
			if (isMacroField) return;
			if (!TypeUnification.typeIseqDefault(targ, t1))
				throw new ContextError("First argument type must be " + TPrinting.sTypeStr(targ), cf.pos);
			if (!TypeUnification.typeIseqDefault(ctx.basic.tstring, t2))
				throw new ContextError("Second argument type must be String", cf.pos);
		}
		switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig) if (sig.args.length >= 2 && isEmptyOrPosInfos(sig.args.slice(2))):
				if (a.read != null) throw new ContextError("Multiple resolve-read methods are not supported", p);
				checkFun(sig.args[0].t, sig.args[1].t);
				a.read = cf;
			case TFun(sig) if (sig.args.length >= 3 && isEmptyOrPosInfos(sig.args.slice(3))):
				if (a.write != null) throw new ContextError("Multiple resolve-write methods are not supported", p);
				checkFun(sig.args[0].t, sig.args[1].t);
				a.write = cf;
			case _:
				throw new ContextError("Field type of resolve must be " + TPrinting.sTypeStr(targ) + " -> String -> T", p);
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
							// A static @:to of a @:multiType abstract carries @:multiType itself - it off the field to
							// find the specializations. Like the CfImpl flag above it belongs on the impl class's real
							// static, not on the modelled cast entry, which is what the generators and --xml/--json
							// read.
							if (real != null && !isAbstractMember && TypeFunctions.hasMeta(":multiType", a.meta)
									&& !TypeFunctions.hasMeta(":multiType", real.meta))
								real.meta = ([{name: ":multiType", params: [], pos: Position.nullPos}] : Metadata).concat(real.meta);
						}
					}
				case _:
			}
		}
	}

	// Run once per field before its context is built. Two arms over the access list, in order: the
	// same modifier twice -> `Duplicate access modifier x` at the later one, with `Previously defined
	// here` as a sub-message at the earlier; public against private -> `Conflicting access modifier x`
	// with `Conflicts with this`. A repeat is not added to the accumulator, so three `public` report
	// against the first. Both arms carry null-position guards: a synthesized modifier has nothing to
	// point at. Both sub-messages carry the "... " sub-message prefix, which the enum abstract site
	// deliberately does not apply - the two `Conflicts with this` messages are not spelled the same
	// way.
	static function checkFieldAccessModifiers(ctx:Context, cff:ClassField):Void {
		if (ctx == null) return;
		var acc:Array<PlacedAccess> = [];
		for (a in cff.cffAccess) {
			var dup:Null<PlacedAccess> = null;
			for (prev in acc) if (prev.access == a.access) { dup = prev; break; }
			if (dup != null) {
				if (a.pos != Position.nullPos && dup.pos != Position.nullPos) {
					ctx.addDiagnostic("Duplicate access modifier " + hxc.ast.Ast.sAccess(a.access), a.pos);
					ctx.addDiagnostic("... Previously defined here", dup.pos, 1);
				}
				continue;
			}
			switch (a.access) {
				case APublic | APrivate:
					var other:Null<PlacedAccess> = null;
					for (prev in acc) switch (prev.access) { case APublic | APrivate: other = prev; break; case _: }
					if (other != null) {
						ctx.addDiagnostic("Conflicting access modifier " + hxc.ast.Ast.sAccess(a.access), a.pos);
						ctx.addDiagnostic("... Conflicts with this", other.pos, 1);
					} else acc.push(a);
				case _: acc.push(a);
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
		// An EAOther member gets no synthesised value and no hint, so it is still a bare `var A;` when
		// the field loop reaches it and reports the missing hint on top of "Value required".
		// registerFields runs that check before this build and so cannot know the mode; it exempts every
		// enum-abstract member there and asks again here.
		for (cff in d.dData) switch (cff.cffKind) {
			case FVar(null, null) if (hxc.core.TypeFunctions.hasMeta(":enum", cff.cffMeta)):
				ctx.addDiagnostic("Variable requires type-hint or initialization", cff.cffName.pos);
			case _:
		}
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
			// A duplicate declaration was reported and never added, so it declares no field; pairing it by
			// name hands it the field it merely collided with.
			if (ctx.droppedFieldDecls.exists(cff)) continue;
			try {
				// An abstract-impl field resolves against the abstract's type parameters. The impl class is
				// declared with none of its own, so a synthesized enum value hinted `Name<T>` has nothing to
				// bind T to without them.
				var params = TypeFunctions.hasClassFieldFlag(cf, CfImpl) ? a.params : c.params;
				resolveFieldType(ctx, params, cf, cff, c.module);
				if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) {
					cf.type = TAbstract(a, TypeFunctions.extractParamTypes(a.params));
				}
			} catch (e:ContextError) {
				// A field's signature is typed under protection, so a hint that does not resolve is an error
				// about the declaration, not a field quietly left untyped. The type load has already recovered
				// the cases a report is meant to survive.
				ctx.unresolvedFields++;
				throw e;
			}
		}
	}

	static function resolveTypedef(ctx:Context, td:TDef, d:Definition<EnumFlag, TypeHint>, p:Position):Void {
		var tt = Typeload.loadComplexType(ctx, td.params, d.dData);
		// A structural EXTEND and haxe.macro.MacroType resolve straight away; @:eager follows immediately;
		// EVERYTHING ELSE is left behind a TLazy whose forcing is what runs the recursion check. That
		// laziness is observable: the nullability test for an optional argument does not force a lazy and
		// DEFERS the Null<> wrap instead, so an optional argument typed by a typedef keeps its Null in the
		// XML output's parameter following (which has no TLazy arm) where a class-typed one loses it.
		var eager = TypeFunctions.hasMeta(":eager", td.meta);
		var direct = switch (d.dData.ct) {
			case CTExtend(_, _): true;
			case CTPath(tp): tp.tpackage.length == 2 && tp.tpackage[0] == "haxe" && tp.tpackage[1] == "macro"
				&& tp.tname == "MacroType";
			case _: false;
		};
		if (direct) {
			// MacroType has to be followed at once because doing so is what defines the module
			// types loaded afterwards; the check is the same recursion guard, applied eagerly.
			switch (d.dData.ct) {
				case CTPath(_) if (td.type == TypeFunctions.follow(tt)):
					throw new ContextError("Recursive typedef is not allowed", p);
				case _:
			}
		} else if (eager) {
			tt = TypeFunctions.follow(tt);
		} else {
			var inner = tt;
			var r:Ref<TLazy> = new Ref(TypeFunctions.lazyAvailable(TypeFunctions.tDynamic));
			r.set(TypeFunctions.lazyProcessing(function():T return inner));
			r.set(TypeFunctions.lazyWait(function():T {
				r.set(TypeFunctions.lazyProcessing(function():T return inner));
				checkRecursiveTypedef(td, inner, p);
				r.set(TypeFunctions.lazyAvailable(inner));
				return inner;
			}));
			tt = TLazy(r);
			// A protected lazy schedules a PForce that forces it by default. The recursion check is
			// therefore run whether or not anything ever uses the typedef, which makes a `typedef T = T`
			// nobody references still report. The TLazy WRAPPER stays in type either way, so the deferral
			// the XML output depends on is unaffected.
			ctx.delay(hxc.context.Context.PForce, function() TypeFunctions.lazyType(r));
		}
		switch (td.type) {
			case TMono(r) if (r.type == null):
				r.type = tt;
			case _:
				td.type = tt;
		}
	}

	// The alias may not reach ITSELF, whether directly or through another typedef.
	static function checkRecursiveTypedef(td:TDef, tt:T, p:Position):Void {
		if (tt == td.type) throw new ContextError("Recursive typedef is not allowed", p);
		switch (tt) {
			case TMono(r):
				if (r.type != null) checkRecursiveTypedef(td, r.type, p);
			case TLazy(f):
				checkRecursiveTypedef(td, TypeFunctions.lazyType(f), p);
			case TType(td2, tl):
				if (td2 == td) throw new ContextError("Recursive typedef is not allowed", p);
				checkRecursiveTypedef(td, TypeFunctions.applyTypedef(td2, tl), p);
			case _:
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

	static function resolveEnum(ctx:Context, e:TEnum, d:Definition<EnumFlag, Array<EnumConstructor>>, p:Position):Void {
		// The enum's @:build macros run here, before the constructors are walked, because what they
		// answer with replaces the declared constructor list.
		hxc.eval.EvalMacro.runEnumBuild(ctx, e, d);
		// The enum self-type, with its declared params applied.
		var et = TEnum(e, TypeFunctions.extractParamTypes(e.params));
		var index = 0;
		var isFlat = true;
		// A ClassField is collected per constructor alongside the TEnumField; they become the fields of the
		// enum's statics anon.
		var staticsFields = new haxe.ds.StringMap<hxc.core.Type.TClassField>();
		for (c in d.dData) {
			// Checked before the constructor is loaded so the first declaration is the one that stands.
			if (e.constrs.exists(c.ecName.name))
				throw new ContextError("Duplicate constructor " + c.ecName.name, c.ecName.pos);
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
							// Reported at the type HINT's own position, not over the whole constructor declaration.
							throw new ContextError("Explicit enum type must be of the same enum type", th.pos);
					}
					t;
			};
			var t:T = if (c.ecArgs.length == 0) {
				rt;
			} else {
				var args:Array<TSignatureArg> = [];
				// An argument may not be Void, and two arguments of one constructor may not share a name. Both
				// report at the constructor, except the Void one which names the offending type hint.
				var pnames = new haxe.ds.StringMap<Bool>();
				for (a in c.ecArgs) {
					switch (a.type == null ? null : a.type.ct) {
						case CTPath(tp) if (tp.tpackage.length == 0 && tp.tname == "Void"):
							throw new ContextError("Arguments of type Void are not allowed in enum constructors", a.type.pos);
						case _:
					}
					if (pnames.exists(a.name))
						throw new ContextError("Duplicate argument `" + a.name + "` in enum constructor " + c.ecName.name, c.ecPos);
					pnames.set(a.name, true);
					var at = Typeload.loadTypeHint(ctx, localParams, a.type, false);
					if (a.opt) at = ctx.basic.tnull(at);
					args.push({name: a.name, opt: a.opt, t: at});
				}
				TFun({args: args, ret: rt});
			};
			var ef = new TEnumField(c.ecName.name, t, c.ecPos, c.ecName.pos, c.ecDoc, index, ctorParams, c.ecMeta);
			e.constrs.set(c.ecName.name, ef);
			// A ClassField is also built per constructor, for the statics anon below: a value constructor
			// reads
			// as a read-only Var, one that takes arguments as a method.
			var ecf = TypeFunctions.mkField(ef.name, ef.type, ef.pos, ef.namePos);
			ecf.kind = switch (TypeFunctions.follow(ef.type)) {
				case TFun(_): Method(MethNormal);
				case _: Var({read: AccNormal, write: AccNo});
			};
			ecf.doc = ef.doc;
			ecf.params = ef.params;
			staticsFields.set(ecf.name, ecf);
			// A constructor carrying @:inheritDoc collects its inherited docs.
			if (TypeFunctions.hasMeta(":inheritDoc", c.ecMeta)) {
				var efDoc = ef;
				ctx.delay(hxc.context.Context.PConnectField, function() hxc.typing.InheritDoc.buildEnumFieldDoc(ctx, efDoc));
			}
			e.names.push(c.ecName.name);
			if (c.ecArgs.length > 0) isFlat = false;
			index++;
		}
		// The enum's own module type is a PRIVATE typedef whose type is the anon of its constructors,
		// tagged EnumStatics. An enum used as a value is typed as TType(type, params), so anon is what
		// Context.typeof of an enum type expression follows to. Without its fields a macro reflecting
		// over it (hxparse's @:mapping, which is how dox builds its keyword tables) sees an empty type.
		if (e.type != null) {
			e.type.params = e.params;
			e.type.type = TypeFunctions.mkAnon(new hxc.core.Ref(EnumStatics(e)), staticsFields);
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
					if (hxc.typing.Typer.atDisplayPos(fa.name.pos)) {
						var av = TypeFunctions.allocVar(VUser(TVOArgument), fa.name.name, at, fa.name.pos);
						hxc.typing.Typer.displayVariable(null, av, fa.name.pos);
					}
					args.push({name: fa.name.name, opt: sigOpt, t: at});
				}
				if (isMacroField && fieldModule != null) ctx.currentModule = fieldModule;
				// A constructor's return type is always Void regardless of any hint, so its signature reads
				// TFun(args, Void). Visible in a cppia host's __script_construct signature.
				// The hint is still loaded, for the display alone, so a cursor inside it has something to
				// answer
				// from; the resulting type is discarded either way.
				if (cf.name == "new" && !isStaticField && fd.fType != null
						&& hxc.typing.Typer.atDisplayPos(fd.fType.pos))
					try Typeload.loadTypeHint(ctx, localParams, fd.fType, false) catch (_:Dynamic) {}
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
			if (m.name != ":overload") { keptMeta.push(m); continue; }
			// The arms after the function form. A BARE @:overload marks native platform overloading and is
			// only legal where the platform has it; anything else that is not a function literal is a
			// malformed declaration.
			if (m.params.length == 0) {
				if (!ctx.platformConfig.supportsOverload)
					throw new ContextError("This platform does not support this kind of overload declaration. Try @:overload(function()... {}) instead", m.pos);
				TypeFunctions.addClassFieldFlag(cf, CfOverload);
				// A native overload cannot infer its argument types, so an unbound monomorph in the
				// signature is an
				// error naming the argument.
				switch (TypeFunctions.follow(cf.type)) {
					case TFun(sig):
						for (a in sig.args) switch (a.t) {
							case TMono(r) if (r.type == null):
								throw new ContextError("Explicit type required for overload functions\n... For function argument '" + a.name + "'", cf.pos);
							case _:
						}
					case _:
				}
				keptMeta.push(m);
				continue;
			}
			if (m.params.length != 1) throw new ContextError("Invalid @:overload metadata format", m.pos);
			switch (m.params[0].expr) {
				case EFunction(fk, f):
					// Three shape checks the declaration has to pass before any of it is loaded. The body
					// must be
					// exactly `{}` - an overload declares a SIGNATURE, and a real body would silently never
					// run.
					switch (fk) {
						case FKNamed(_, _): throw new ContextError("Function name must not be part of @:overload", m.params[0].pos);
						case _:
					}
					switch (f.fExpr == null ? null : f.fExpr.expr) {
						case EBlock(el) if (el.length == 0):
						case _: throw new ContextError("Overload must only declare an empty method body {}", m.params[0].pos);
					}
					switch (cf.kind) {
						case Method(MethInline): throw new ContextError("Cannot @:overload inline function", m.params[0].pos);
						case _:
					}
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
			// A single parameter that is not a function literal is the malformed form too.
			if (!converted) throw new ContextError("Invalid @:overload metadata format", m.pos);
		}
		cf.meta = keptMeta;
		if (overloads.length > 0) cf.overloads = overloads;
	}
}
