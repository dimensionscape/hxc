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

	// The modules whose resolution is OPEN right now. resolved is set at the start, so it
	// cannot tell an in-progress module from a finished one; a build forced from a body
	// (Typeload.forceBuildInBody) has to know, because a class's inherited @:autoBuild is read
	// from a heritage that resolution is still setting.
	public static var resolving:haxe.ds.ObjectMap<ModuleDef, Bool> = new haxe.ds.ObjectMap();

	public static function resolveModule(ctx:Context, m:ModuleDef):Void {
		// No display answers come from the macro world (see TypeFields).
		var mw = hxc.typing.TypeFields.enterMacroWorld(ctx);
		try resolveModuleEntry(ctx, m) catch (e:Dynamic) { hxc.typing.TypeFields.leaveMacroWorld(mw); throw e; }
		hxc.typing.TypeFields.leaveMacroWorld(mw);
	}

	static function resolveModuleEntry(ctx:Context, m:ModuleDef):Void {
		if (m.extra.resolved >= 1) return;
		resolving.set(m, true);
		// Module initialisation and the class build run under PBuildModule / PBuildClass, so a load
		// made while resolving never flushes.
		var savedPass = ctx.currentPass;
		ctx.currentPass = Context.PBuildModule;
		ctx.resolveDepth++;
		try {
			resolveModuleInner(ctx, m);
		} catch (e:Dynamic) {
			ctx.resolveDepth--;
			ctx.currentPass = savedPass;
			resolving.remove(m);
			throw e;
		}
		ctx.resolveDepth--;
		ctx.currentPass = savedPass;
	}

	static function resolveModuleInner(ctx:Context, m:ModuleDef):Void {
		m.extra.resolved = 1;
		var init = new ModuleInit(ctx, m);
		// An unresolvable `using` aborts the module's initialisation before it reaches a single
		// declaration, so the types exist but none of them is ever initialised. Resolving them anyway
		// prints a cascade of follow-on errors.
		if (ctx.moduleAborted.exists(Context.pathKey(m.path))) {
			markModuleErrored(ctx, m);
			init.close();
			return;
		}
		var savedMod = ctx.currentModule;
		ctx.currentModule = m; // Resolve in-module sibling types against m.types first
		// Initialize declarations in source order, deferring every class build to PBuildClass. Classes
		// then build in reverse declaration order after abstracts, enums, and typedefs initialize.
		// Reversing the entire list changes which mutually recursive abstract reports the cycle. Generic
		// classes, generic-build classes, module statics carriers, and abstract implementation classes
		// all take the delay. Their heritage must fail in the same order as ordinary classes. Abstract
		// fields, conversions, operators, and enum-abstract members are resolved in the implementation's
		// build slot. Place the implementation declaration before its abstract: queue the implementation,
		// then initialize the abstract header and load its underlying type.
		var implOf = new haxe.ds.ObjectMap<TClass, ModuleType>();
		for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (c.kind.match(KAbstractImpl(_))): implOf.set(c, mt);
			case _:
		}
		var initOrder:Array<ModuleType> = [];
		for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (implOf.exists(c)):
			case TAbstractDecl(a) if (a.impl != null && implOf.exists(a.impl)):
				initOrder.push(implOf.get(a.impl));
				initOrder.push(mt);
			case _:
				initOrder.push(mt);
		}
		for (mt in initOrder) {
			var info = TypeFunctions.tInfos(mt);
			var entry = ctx.declOfType.get(Context.pathKey(info.path));
			if (entry == null) continue; // Synthetic types (e.g. _Fields_, enum module-type) have no decl
			switch (mt) {
				case TClassDecl(c):
					var slot = new ClassSlot(init, mt, c, entry.decl, entry.pos);
					c.hxcClassSlot = slot;
					init.pending++;
					// The class's build is queued as a PBuildClass delay, in declaration order with the
					// rest of the
					// module's initialisation: the declaration resolves inside that build, or wherever a
					// build site
					// forces it first.
					ctx.classSlots.push(slot);
					hxc.typing.TypeFields.queueClassBuild(ctx, c);
					continue;
				case _:
			}
			try {
				initDecl(ctx, mt, entry.decl, entry.pos);
				init.builtBefore.push(Context.pathKey(info.path));
			} catch (dc:hxc.compiler.DisplayXml.ToplevelCompletion) {
				// A display completion is an answer, not a declaration error: it has to reach the responder
				// rather than be recorded and swallowed here.
				throw dc;
			} catch (e:ContextError) {
				declFailed(ctx, init, e, e.message, e.pos, e.depth, savedMod);
				break;
			} catch (e:hxc.core.TypingError) {
				declFailed(ctx, init, e, e.message, e.pos, e.depth, savedMod);
				break;
			} catch (e:Dynamic) {
				if (hxc.parser.ParserError.isParseFailure(e)) throw e;
				hxc.core.TypingError.FatalError.pass(e);
				ctx.currentModule = m;
			}
		}
		ctx.currentModule = savedMod;
		init.close();
	}

	// One declaration's initialisation: the class build for a class (its slot), the abstract,
	// enum or typedef initialisation for the rest.
	static function initDecl(ctx:Context, mt:ModuleType, decl:TypeDef, pos:Position):Void {
		var impl:Null<{a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>, p:Position}> = null;
		switch (mt) {
			case TClassDecl(c): switch (c.kind) {
				case KAbstractImpl(a):
					var ad = ctx.declOfType.get(Context.pathKey(a.path));
					if (ad != null) switch (ad.decl) {
						case EAbstract(dd): impl = {a: a, d: dd, p: ad.pos};
						case _:
					}
				case _:
			}
			case _:
		}
		// The enum-abstract rewrite of the member declarations (the access list, @:enum, the synthesised
		// values) happens at the START of the implementation's field build, so the field's own access check
		// never sees `public private`; running it after the class build reports the conflict twice.
		// It follows the class's @:build macros, so an implementation with one pending is rewritten when
		// its
		// build runs (EvalMacro.ensureBuilt).
		if (impl != null && impl.a.isEnum && !hxc.eval.EvalMacro.hasPendingBuild(ctx, impl.a.impl))
			buildEnumAbstractFields(ctx, impl.a, impl.d.dParams, impl.d.dData, impl.p);
		resolveType(ctx, mt, decl, pos);
		if (impl != null) resolveAbstractImpl(ctx, impl.a, impl.d, impl.p);
		resolveUsingMetadata(ctx, mt);
	}

	// A declaration error (bad heritage, final extend, ...) is recorded, and the rest of the module is
	// ABANDONED: the error raises out of module initialisation (or out of the class build), so no
	// later declaration of that module is reached and exactly one such error is ever printed.
	//
	// The types are marked too, since their fields are never bound and their bodies never typed.
	// Typing them anyway prints a cascade - an unresolved super leaves every inherited member unknown,
	// so one bad `extends` becomes many errors.
	static function declFailed(ctx:Context, init:ModuleInit, e:Dynamic, message:String, pos:Position, depth:Int, savedMod:ModuleDef):Void {
		markModuleErrored(ctx, init.m);
		// The types built before a declaration error: their builds ran - a class declared after the
		// failing one is built first (the delays are LIFO) - and bound their variables.
		for (k in init.builtBefore) ctx.declBuiltBeforeError.set(k, true);
		if (escapesDeclError(ctx)) { ctx.currentModule = savedMod; throw e; }
		var chain = Std.isOfType(e, hxc.core.TypingError) ? (e : hxc.core.TypingError).callChain
			: Std.isOfType(e, ContextError) ? (e : ContextError).callChain : null;
		ctx.addTypingError(message, pos, depth, chain);
		ctx.currentModule = init.m;
		ctx.declAborted = true;
		init.aborted = true;
	}

	static function drainClassSlots(ctx:Context):Void {
		while (ctx.classSlots.length > 0) {
			var slot:ClassSlot = ctx.classSlots.pop();
			runClassSlot(ctx, slot);
		}
	}

	// Finalization's flush: builds a resolution that raised left queued run here, before the
	// bodies. Nothing is queued once every resolution returned normally.
	public static function flushClassSlots(ctx:Context):Void {
		if (ctx.resolveDepth > 0 || ctx.classSlots.length == 0) return;
		var mw = hxc.typing.TypeFields.enterMacroWorld(ctx);
		var savedPass = ctx.currentPass;
		ctx.currentPass = Context.PBuildModule;
		ctx.resolveDepth++;
		try drainClassSlots(ctx) catch (e:Dynamic) {
			ctx.resolveDepth--;
			ctx.currentPass = savedPass;
			hxc.typing.TypeFields.leaveMacroWorld(mw);
			throw e;
		}
		ctx.resolveDepth--;
		ctx.currentPass = savedPass;
		hxc.typing.TypeFields.leaveMacroWorld(mw);
	}

	// A queued build taking its turn: its failure is its module's declaration error.
	static function runClassSlot(ctx:Context, slot:ClassSlot):Void {
		if (slot.started) return;
		var init = slot.init;
		slot.started = true;
		if (init.aborted) { slot.finish(); return; }
		var savedMod = ctx.currentModule;
		ctx.currentModule = init.m;
		try {
			initDecl(ctx, slot.mt, slot.decl, slot.pos);
			init.builtBefore.push(Context.pathKey(slot.c.path));
		} catch (dc:hxc.compiler.DisplayXml.ToplevelCompletion) {
			slot.finish();
			throw dc;
		} catch (e:ContextError) {
			slot.finish();
			declFailed(ctx, init, e, e.message, e.pos, e.depth, savedMod);
		} catch (e:hxc.core.TypingError) {
			slot.finish();
			declFailed(ctx, init, e, e.message, e.pos, e.depth, savedMod);
		} catch (e:Dynamic) {
			slot.finish();
			if (hxc.parser.ParserError.isParseFailure(e)) throw e;
			hxc.core.TypingError.FatalError.pass(e);
		}
		slot.finish();
		ctx.currentModule = savedMod;
	}

	/**
		Every build site forces a class's queued build out of turn (the heritage, the macro API,
		imports, ...): the delay finds it Built when its turn comes. A failure goes to whoever forced it,
		as a raise out of build does. A class of a module abandoned by a declaration error is left as
		that error left it.
	**/
	public static function forceQueuedBuild(c:TClass):Void {
		var slot:Null<ClassSlot> = c.hxcClassSlot;
		if (slot == null || slot.started) return;
		// Forcing it is running build, which resolves the declaration first and comes back here for
		// that.
		if (!hxc.typing.TypeFields.buildStarted(c)) {
			hxc.typing.TypeFields.buildClass(slot.init.ctx, c);
			return;
		}
		var init = slot.init;
		slot.started = true;
		if (init.aborted) { slot.finish(); return; }
		var ctx = init.ctx;
		var savedMod = ctx.currentModule;
		ctx.currentModule = init.m;
		try {
			initDecl(ctx, slot.mt, slot.decl, slot.pos);
			init.builtBefore.push(Context.pathKey(c.path));
		} catch (e:Dynamic) {
			ctx.currentModule = savedMod;
			c.hxcBuildState = BUILT;
			slot.finish();
			throw e;
		}
		ctx.currentModule = savedMod;
		slot.finish();
	}

	// A diagnostics run does not ignore errors, so the raise leaves the typing stage and the
	// diagnostics handler records the message and emits the report on the spot. Nothing gathered after
	// typing reaches that report - the module list above all, which is filled only when typing
	// finishes - so a module's unused imports cannot appear in it. Every other request, a display one
	// included, records the raise and abandons the module: ignoring errors applies only at its own
	// call sites (an unqualified missing type in a type load or in a heritage), never here.
	static inline function escapesDeclError(ctx:Context):Bool {
		return ctx.isDiagnosticsRun();
	}

	// The error raises out of module initialisation, so the module's DELAYED field typing never runs -
	// for any of its types, not just the one that failed. A sibling class typed anyway reports every
	// member it expected from the broken one.
	static function markModuleErrored(ctx:Context, m:ModuleDef):Void {
		for (mt in m.types)
			ctx.declErrored.set(Context.pathKey(TypeFunctions.tPath(mt)), true);
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

	static function resolveType(ctx:Context, mt:ModuleType, decl:TypeDef, p:Position):Void {
		if (hxc.core.PerfCount.on) hxc.core.PerfCount.bump("resolveType");
		// /474/556/608: init_class/init_enum/init_typedef/init_abstract make a type whose name holds the
		// cursor the display subject (display_module_type; an abstract's impl class stands for the
		// abstract). Definition and hover answer from it once typing ends (Compiler.displayTypeAtName); a
		// completion request raises the type-hint collection here.
		if (hxc.parser.Parser.displayCompletionMode) {
			var namePos:Null<Position> = switch (decl) {
				case EClass(d): d.dName.pos;
				case EAbstract(d): d.dName.pos;
				case ETypedef(d): d.dName.pos;
				case EEnum(d): d.dName.pos;
				case _: null;
			};
			if (namePos != null && Typer.atDisplayPos(namePos)) {
				var subject = switch (mt) {
					case TClassDecl({kind: KAbstractImpl(a)}): TAbstractDecl(a);
					case _: mt;
				};
				Typer.displayModuleType(ctx, subject, namePos, true);
			}
		}
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
				// A Module.SubType path (second-to-last segment not Ast.isLowerIdent) names a single type; a
				// plain module path brings in every non-private class of the module, like a using statement.
				var subOf:Null<{pack:Array<String>, moduleName:String, sub:String}> = null;
				if (parts.length >= 2) {
					var s2 = parts[parts.length - 2];
					if (!hxc.ast.Ast.isLowerIdent(s2))
						subOf = {pack: parts.slice(0, parts.length - 2), moduleName: s2, sub: parts[parts.length - 1]};
				}
				function classOf(used:Null<ModuleType>):Null<TClass> {
					return switch (used) {
						case TClassDecl(c): c;
						case TAbstractDecl(a) if (a.impl != null): a.impl;
						case _: null;
					}
				}
				// A `using` does one lookup, of the module or of the sub-type, and lets it RAISE when the path
				// names nothing; swallowing it here accepts `@:using(nosuchpkg)`.
				var lookupErr:Dynamic = null;
				if (subOf != null) {
					var used = try ctx.getType({pack: subOf.pack, name: subOf.moduleName}, param.pos, subOf.sub) catch (e:Dynamic) { lookupErr = e; null; };
					var usingClass = classOf(used);
					if (usingClass != null) addUsing(mt, usingClass, param.pos);
					else if (lookupErr != null) throw lookupErr;
					continue;
				}
				var path:hxc.core.Globals.Path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
				var um = try hxc.context.ModuleLoader.loadModule(ctx, path, param.pos) catch (e:Dynamic) { lookupErr = e; null; };
				if (um != null) {
					// The using list is built by reversing the type list and prepending the result; unshifting in
					// module order produces the same final order. The module's statics class comes first in the
					// input, so it lands last.
					if (um.statics != null) addUsing(mt, um.statics, param.pos);
					for (umt in um.types) {
						if (TypeFunctions.tInfos(umt).isPrivate) continue;
						var usingClass = classOf(umt);
						if (usingClass != null) addUsing(mt, usingClass, param.pos);
					}
					continue;
				}
				// A plain path is a module, loaded as a module and nothing else; a type of the current module
				// under that name is not found, so `@:using(SameModuleType)` is rejected.
				throw lookupErr;
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
			// An implementation class carries the abstract's @:using (the metadata is copied onto it), and
			// it registers on the abstract; the implementation's own list stays empty, so a static extension
			// reached through the abstract's type expression (its Statics anon) is not found.
			case TClassDecl({kind: KAbstractImpl(a)}):
				a.usings.unshift(u);
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
		// An interface cannot implement, so answers nothing at all; any other heritage keeps an
		// interface, or a class it may extend.
		if (isExtends || !isInterface) {
			tc.jsonEntries = hxc.typing.Typer.collectTypesJson(ctx, hxc.typing.Typeload.currentTypeParams);
			var hack = TypeFunctions.hasMeta(":hack", c.meta);
			var cExtern = TypeFunctions.hasClassFlag(c, CExtern);
			tc.jsonFilter = function(info) {
				var cm = info.kind == "type" ? hxc.typing.Typer.completionModuleType(info) : null;
				if (cm == null) return false;
				var self = cm.pack.join(".") == c.path.pack.join(".") && cm.name == c.path.name;
				var basic = cm.pack.length == 0 && (cm.name == "Array" || cm.name == "String" || cm.name == "Date" || cm.name == "Xml");
				return switch (cm.kind) {
					case 1: (!isExtends || isInterface) && !self;
					case 0: isExtends && !isInterface && !self && (!cm.isFinal || hack) && (!basic || (cExtern && cm.isExtern));
					case _: false;
				};
			};
		} else {
			tc.jsonEntries = [];
			tc.jsonFilter = function(_) return false;
		}
		throw tc;
	}

	// The parser's magic type path reaching load_type_def means the cursor is in a type position, and
	// every type in scope is the answer (CRTypeHint). The heritage answer above is the same collection
	// with set_heritance's extra filtering on top.
	public static function answerTypeHintCompletion(ctx:Context, p:Position, ?subjectName:String, kind:Int = 4):Void {
		var items:Array<hxc.compiler.DisplayXml.ToplevelItem> = [];
		var mts:Array<ModuleType> = [];
		var seenPaths = new Map<String, Bool>();
		// A type whose name was already offered is Shadowed, which is its own group when the collection
		// is sorted.
		var names = new Map<String, Bool>();
		// The type PARAMETERS in scope come first, which makes a constructible one reachable from
		// `new <cursor>`.
		for (tp in hxc.typing.Typeload.currentTypeParams) switch (TypeFunctions.follow(tp.type)) {
			case TInst(pc, _):
				items.push({kind: "type", name: pc.path.name, path: hxc.core.Globals.sTypePath(pc.path), tparam: pc,
					sortGroup: 30, sortKey: pc.path.name});
				names.set(pc.path.name, true);
			case _:
		}
		// The current module's own types are listed next. They exist from the moment the module is
		// created, well before it finishes loading, which is when a type hint inside that same module
		// asks.
		var all:Array<ModuleType> = ctx.currentModule == null ? [] : ctx.currentModule.types.copy();
		for (mt in visibleTypesForCompletion(ctx)) all.push(mt);
		for (mt in all) {
			// An abstract's implementation class and a module's statics holder are never offered.
			switch (mt) {
				case TClassDecl(c) if (c.kind.match(KAbstractImpl(_) | KModuleFields(_))): continue;
				case _:
			}
			var inf = TypeFunctions.tInfos(mt);
			// A PRIVATE type is still offered inside the module that declares it.
			if (inf.isPrivate && (ctx.currentModule == null || inf.module != ctx.currentModule)) continue;
			var key = hxc.core.Globals.sTypePath(inf.path);
			if (seenPaths.exists(key)) continue;
			// A path is recorded as seen only for a type that is offered.
			if (TypeFunctions.hasMeta(":noCompletion", inf.meta)) continue;
			seenPaths.set(key, true);
			// Sort groups: Imported 31, Shadowed 33, keyed by the dotted path.
			items.push({kind: "type", name: inf.path.name, path: key,
				sortGroup: names.exists(inf.path.name) ? 33 : 31, sortKey: key});
			names.set(inf.path.name, true);
			mts.push(mt);
		}
		// A type collection reaches the same cache-files source an expression collection does, which is
		// where a bare PACKAGE name comes from. Without it a type hint offers types only, never `haxe`.
		hxc.typing.Typer.addCachedFileTypes(ctx, items, seenPaths);
		// Only a collection for an unnamed subject is sorted: a collection for a subject that already has a
		// name (a declaration's own, or a path being written) keeps the order it was collected in. The
		// legacy-completion name sort is the JSON-RPC option, off here.
		// Sorted, it orders by group, then key.
		if (subjectName == null || subjectName == "")
			items = hxc.typing.Typer.sortToplevel(items, null);
		// CRTypeHint is 4.
		var tc = new hxc.compiler.DisplayXml.ToplevelCompletion(items, mts);
		tc.kind = kind;
		tc.subjectPos = p;
		// The subject is keyed by the path the user was writing, which is what the client filters on.
		tc.subjectName = subjectName;
		tc.jsonEntries = hxc.typing.Typer.collectTypesJson(ctx, hxc.typing.Typeload.currentTypeParams);
		throw tc;
	}

	// The types a type collection sees before the types from files: the current module's own, then the
	// module's imports reversed. Everything else loaded is not in scope: the files offered beyond
	// these come from the server's cache, which addCachedFileTypes adds on its own.
	static function visibleTypesForCompletion(ctx:Context):Array<ModuleType> {
		var out:Array<ModuleType> = ctx.currentModule == null ? [] : ctx.currentModule.types.copy();
		var imported = hxc.typing.Typer.moduleImportTypes(ctx);
		imported.reverse();
		for (mt in imported) out.push(mt);
		// The types from files exist only where the server keeps a cache of them. The XML lane lists
		// those from the parse-only scan (Typer.addCachedFileTypes); an entry of the JSON lane needs a
		// type, which only the modules already loaded have, so under the server those stand in for the
		// files there.
		if (hxc.context.ServerCache.enabled) {
			var seen = new Map<String, Bool>();
			for (mt in out) seen.set(Context.pathKey(TypeFunctions.tPath(mt)), true);
			for (key in ctx.moduleLut.keys()) {
				var m = ctx.moduleLut.get(key);
				for (mt in m.types) {
					var k = Context.pathKey(TypeFunctions.tPath(mt));
					if (seen.exists(k)) continue;
					seen.set(k, true);
					out.push(mt);
				}
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
			// The display mode is active on the host for every display request but diagnostics and
			// statistics,
			// which is ignoreErrors; the macro context has no display mode except inside an MDisplay load,
			// which
			// hands it the host's display settings - ignoreErrors crosses into the macro com unchanged, so
			// on
			// its own it is not the macro world's answer.
			case ModuleNotFound(m) if (m.pack.length == 0 && ctx.ignoreErrors
					&& (!ctx.isMacro || hxc.typing.TypeFields.macroDisplayWindow)):
				// Called directly rather than through a delay.
				if (ctx.errorInDiagnosticsRun(err.pos))
					hxc.typing.Typer.handleUnresolvedIdentifier(ctx, m.name, err.pos);
				true;
			case _: false;
		};
	}

	// Heritage: class super/implements.
	// Remoting proxy: parse T's module, turn its class into Remoting_T / Async_T - a `__cnx` connection
	// field, a constructor taking it, and one public instance method per public method of T that
	// resolves and calls it over the connection - type that module, and make it this class's super. The
	// std shipped with 4.3.7 carries no haxe.remoting, so the built class reports its connection type
	// as not found.
	static function extendRemoting(ctx:Context, c:TClass, t:TypePath, p:Position, async:Bool, prot:Bool):Void {
		if (c.superClass != null) throw new ContextError("Cannot extend several classes", p);
		var path:hxc.core.Globals.Path = {pack: t.tpackage, name: t.tname};
		var newName = (async ? "Async_" : "Remoting_") + t.tname;
		var np = Position.nullPos;
		// Check if the proxy already exists
		var mt:Null<ModuleType> = try hxc.context.ModuleLoader.loadTypeDef(ctx, {pack: t.tpackage, name: newName}, p) catch (_:ContextError) null;
		if (mt == null) {
			// Build it
			ctx.log("Building proxy for " + Context.sTypePath(path));
			var file = try hxc.context.ModuleLoader.resolveModuleFile(ctx, path, p) catch (_:ContextError)
				throw new ContextError("Could not load proxy module " + Context.sTypePath(path) + (t.tpackage.length == 0 ? " (try using absolute path)" : ""), p);
			var pkg = hxc.context.ModuleLoader.parseModuleFile(ctx, hxc.context.ModuleLoader.moduleFileContent(ctx, file), file);
			function ident(s:String):Expr return new Expr(EConst(CIdent(s)), p);
			function connectionHint():TypeHint
				return {ct: CTPath({tpackage: ["haxe", "remoting"], tname: async ? "AsyncConnection" : "Connection", tparams: [], tsub: null}), pos: np};
			var cnxField:ClassField = {cffName: {name: "__cnx", pos: np}, cffPos: p, cffDoc: null, cffMeta: [], cffAccess: [],
				cffKind: FVar(connectionHint(), null)};
			var newField:ClassField = {cffName: {name: "new", pos: np}, cffPos: p, cffDoc: null, cffMeta: [], cffAccess: [{access: APublic, pos: np}],
				cffKind: FFun({fParams: [], fArgs: [{name: {name: "c", pos: np}, opt: false, meta: [], type: null, value: null}], fType: null,
					fExpr: new Expr(EBinop(OpAssign, ident("__cnx"), ident("c")), p)})};
			var tvoid:TypeHint = {ct: CTPath({tpackage: [], tname: "Void", tparams: [], tsub: null}), pos: np};
			function hasAccess(f:ClassField, a:Access):Bool return [for (x in f.cffAccess) if (x.access == a) true].length > 0;
			function buildField(isPublic:Bool, f:ClassField):Null<ClassField> {
				if (f.cffName.name == "new") return null;
				return switch (f.cffKind) {
					case FFun(fd) if ((isPublic || hasAccess(f, APublic)) && !hasAccess(f, AStatic)):
						for (a in fd.fArgs) if (a.type == null)
							throw new ContextError("Field " + f.cffName.name + " type is not complete and cannot be used by RemotingProxy", p);
						var eargs = [new Expr(EArrayDecl([for (a in fd.fArgs) ident(a.name.name)]), p)];
						var ftype:Null<TypeHint> = switch (fd.fType) {
							case {ct: CTPath({tpackage: [], tname: "Void"})}: null;
							case th: th;
						};
						var fargs = fd.fArgs;
						if (async) {
							if (ftype != null)
								fargs = fd.fArgs.concat([{name: {name: "__callb", pos: np}, opt: true, meta: [],
									type: {ct: CTFunction([ftype], tvoid), pos: np}, value: null}]);
							else
								eargs = eargs.concat([ident("null")]);
						}
						var id:Expr = new Expr(EConst(CString(f.cffName.name, SDoubleQuotes)), p);
						if (!prot) id = new Expr(ECall(ident("__unprotect__"), [id]), p);
						var resolved = new Expr(ECall(new Expr(EField(ident("__cnx"), "resolve", EFNormal), p), [id]), p);
						var expr = new Expr(ECall(new Expr(EField(resolved, "call", EFNormal), p), eargs), p);
						if (!async && ftype != null) expr = new Expr(EReturn(expr), p);
						var nfd:Func = {fParams: fd.fParams, fArgs: fargs, fType: async ? null : ftype, fExpr: new Expr(EBlock([expr]), p)};
						({cffName: f.cffName, cffPos: f.cffPos, cffDoc: null, cffMeta: [], cffAccess: [{access: APublic, pos: np}], cffKind: FFun(nfd)} : ClassField);
					case _: null;
				}
			}
			var types:Array<TypeDecl> = [], imports:Array<Import> = [], usings:Array<PlacedTypePath> = [];
			for (decl in pkg.decls) switch (decl.decl) {
				case EImport(i): imports.push(i);
				case EUsing(names):
					var last = names[names.length - 1];
					usings.push({path: {tpackage: [for (n in names.slice(0, names.length - 1)) n.name], tname: last.name, tparams: [], tsub: null}, pos: last.pos});
				case EClass(cd) if (cd.dName.name == t.tname):
					// The proxy reads the built class's parameters, which are this declaration's, before
					// any of its
					// fields are typed; hxc's typeModule resolves the hints on the way, so the check comes
					// first.
					if (cd.dParams.length > 0) throw new ContextError("Remoting proxy must be a class without parameters", p);
					var isPublic = [for (fl in cd.dFlags) if (fl.match(HExtern) || fl.match(HInterface)) true].length > 0;
					// The fields: the constructor, the connection, then the methods in declaration order.
					var fields:Array<ClassField> = [newField, cnxField];
					for (f in cd.dData) { var b = buildField(isPublic, f); if (b != null) fields.push(b); }
					types.push({decl: EClass({dName: {name: newName, pos: cd.dName.pos}, dDoc: cd.dDoc, dParams: cd.dParams, dMeta: cd.dMeta, dFlags: [], dData: fields}), pos: decl.pos});
				case _: types.push(decl);
			}
			var m = hxc.context.ModuleLoader.defineModuleDecls(ctx, {pack: t.tpackage, name: newName}, types, imports, usings, p);
			TypeFunctions.addDependency(c.module, m);
			for (x in m.types) if (TypeFunctions.tPath(x).name == newName) mt = x;
			if (mt == null) throw new ContextError("Module " + Context.sTypePath(path) + " does not define type " + t.tname, p);
		}
		switch (mt) {
			case TClassDecl(c2) if (c2.params.length == 0):
				// The module's fields resolve here, after the parameter check, so a generic target reports
				// only
				// that check.
				resolveModule(ctx, c2.module);
				forceBuild(ctx, c2);
				c.superClass = {c: c2, params: []};
			case _:
				throw new ContextError("Remoting proxy must be a class without parameters", p);
		}
	}

	public static function resolveClass(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		// A build marks the class BUILDING at its START, so a class reached again while it is building does
		// NOTHING further rather than re-running its heritage. There are two entry points - the module loop
		// and forceBuild - so the state belongs to the build, not to one of its callers: forcing a super
		// the loop is already resolving must not run the heritage twice and trip `superClass != null` as
		// "Cannot extend several classes".
		var st0 = c.hxcBuildState;
		if (st0 == BUILDING || st0 == BUILT) return;
		c.hxcBuildState = BUILDING;
		if (hxc.core.PerfCount.on) hxc.core.PerfCount.bump("resolveClass");
		// One interface check per class
		var hasInterf = [false];
		// Pass 1: heritage. Filter HExtends/HImplements; load each type; set relations.
		for (f0 in d.dFlags) {
		var f = switch (f0) {
			case HExtends(pt): HExtends(resolveHeritageImports(ctx, pt));
			case HImplements(pt): HImplements(resolveHeritageImports(ctx, pt));
			case _: f0;
		}
		switch (f) {
			case HExtends(pt):
				// `haxe.remoting.Proxy<T>` / `AsyncProxy<T>` in an extends clause is not a heritage but a
				// request
				// to BUILD a proxy class for T's module.
				if (pt.path.tpackage.length == 2 && pt.path.tpackage[0] == "haxe" && pt.path.tpackage[1] == "remoting"
						&& (pt.path.tname == "Proxy" || pt.path.tname == "AsyncProxy") && pt.path.tparams.length == 1) {
					switch (pt.path.tparams[0]) {
						case TPType({ct: CTPath(target)}):
							extendRemoting(ctx, c, target, p, pt.path.tname == "AsyncProxy", true);
							continue;
						case _:
					}
				}
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
				if (t != null) checkHerit(ctx, c, t, true, pt.pos, p, hasInterf);
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
				if (t != null) checkHerit(ctx, c, t, false, pt.pos, null, hasInterf);
			case _:
		}
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
		// Once a class is built every later reach for its fields is a no-op. This is that one-shot: an
		// abstract's implementation is reached both from its abstract and from the ordinary class path,
		// and without the check whichever ran second derives every signature a second time. The build
		// macros run before a single signature is typed, so the fields of a class with a build to run are
		// the build's to resolve (EvalMacro.runClassBuildMacros) - the list it leaves, and only that.
		if (c.hxcBuildState != BUILT) {
			if (hxc.eval.EvalMacro.hasPendingBuild(ctx, c)) c.hxcFieldsDeferred = true;
			else resolveClassFields(ctx, c, d, p);
		}
		// A build that got past its heritage and fields forces the class's own type parameters here, so a
		// constraint naming an unknown type reports at the end of this build - before any later
		// declaration is built - and never at all for a build that raised earlier.
		for (tp in c.params) TypeFunctions.follow(tp.type);
		markClassBuilt(c);
		TypeFields.addImplicitInterfaceFields(c);
	}

	// Before the heritage loads them, a heritage path with no package takes the package of the type its
	// name finds - among the module's own types, then in the module's imports (marking that import
	// used). The type load then sees the qualified path, and a display answer on it is narrowed by the
	// QUALIFIED name's length.
	static function resolveHeritageImports(ctx:Context, pt:PlacedTypePath):PlacedTypePath {
		var t = pt.path;
		if (t.tpackage.length > 0) return pt;
		var cur = ctx.currentModule;
		if (cur == null) return pt;
		var found:Null<ModuleType> = null;
		for (mt in cur.types) if (TypeFunctions.tPath(mt).name == t.tname) { found = mt; break; }
		if (found == null)
			found = try hxc.context.ModuleLoader.resolveNamedImportType(ctx, cur, t.tname, pt.pos) catch (_:Dynamic) null;
		if (found == null) return pt;
		var pack = TypeFunctions.tPath(found).pack;
		if (pack.length == 0) return pt;
		return {path: {tpackage: pack, tname: t.tname, tsub: t.tsub, tparams: t.tparams}, pos: pt.pos};
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

	// Resolve only the field signatures of an already-heritage-resolved class. A @:build macro rewrites
	// the field list but not the heritage, so it re-runs this without redoing extends.
	// The build protocol: while a class is being built a re-entrant request is a NO-OP, and once it is
	// built later requests do nothing at all. Without that state anything that wants to force a class
	// early has to re-run the pass and disturb the schedule for every other class.
	// Track the two states here. Only buildClassFields consults them; the ordinary resolution path just
	// records that it happened, and an explicit re-resolution after a @:build macro rewrites the
	// definition deliberately bypasses this.
	// A class's build state, whether its property accessors and post-heritage field checks ran:
	// TClass.hxcBuildState / hxcPropAccessorsChecked / hxcFieldChecksDone.
	// resolveClassFields runs more than once for some classes and only its IDEMPOTENT work may repeat.
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
		var st = c.hxcBuildState;
		if (st == BUILT) return Built;
		if (st == BUILDING) return Building([c]);
		if (c.hxcClassSlot != null) {
			forceQueuedBuild(c);
			if (c.hxcBuildState == BUILT) return Built;
		}
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return Built;
		switch (entry.decl) {
			case EClass(d):
				var savedModule = ctx.currentModule;
				if (c.module != null) ctx.currentModule = c.module;
				try resolveClass(ctx, c, d, entry.pos)
				catch (e:Dynamic) {
					ctx.currentModule = savedModule;
					c.hxcBuildState = BUILT;
					throw e;
				}
				ctx.currentModule = savedModule;
				c.hxcBuildState = BUILT;
				return Built;
			case _:
				return Built;
		}
	}

	public static function markClassBuilt(c:TClass):Void {
		c.hxcBuildState = BUILT;
	}

	// Make sure the class is set up before its fields are read. Returns true when this call did the
	// work.
	public static function buildClassFields(ctx:Context, c:TClass, p:Position):Bool {
		if ((c.hxcBuildState != 0)) return false;
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return false;
		switch (entry.decl) {
			case EClass(d):
				c.hxcBuildState = BUILDING;
				var savedModule = ctx.currentModule;
				if (c.module != null) ctx.currentModule = c.module;
				// A typing error raised while binding the fields comes OUT of the build, and the
				// module-level
				// handler records it as the declaration's one error. Swallowing it here lets an abstract
				// whose field
				// names a type that does not exist compile clean, with its @:op check reading a signature
				// that was
				// never built. The one-shot state is still set on the way out: the build is Built whether
				// or not it
				// raised, so a second caller does not rebuild and re-raise.
				try resolveClassFields(ctx, c, d, p) catch (e:Dynamic) {
					ctx.currentModule = savedModule;
					c.hxcBuildState = BUILT;
					if (hxc.parser.ParserError.isParseFailure(e)) throw e;
					hxc.core.TypingError.FatalError.pass(e);
					if (Std.isOfType(e, ContextError) || Std.isOfType(e, hxc.core.TypingError)) throw e;
				}
				ctx.currentModule = savedModule;
				c.hxcBuildState = BUILT;
				return true;
			case _:
				return false;
		}
	}


	public static function resolveClassFields(ctx:Context, c:TClass, d:Definition<ClassFlag, Array<ClassField>>, p:Position):Void {
		c.hxcFieldsDeferred = false;
		// Heritage is already set by the time this runs, from either build path, so the field-level
		// reports held since module load are released here.
		// The build macros run before any field check: with a build still to run, the verdicts wait for the
		// resolve the build performs over the fields it leaves.
		if (!hxc.eval.EvalMacro.hasPendingBuild(ctx, c)) ctx.flushFieldDiagnostics(c);
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
		// Each field is added to the class at the END of its iteration, so a property lookup while setting
		// up arguments and return types sees only the fields declared before it.
		var created = new haxe.ds.StringMap<TClassField>();
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
				else TypeFunctions.declaredField(c, cff.cffName.name, isStatic);
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
				var prefix = isStatic ? "s:" : "i:";
				resolveFieldType(ctx, params, target, cff, c.module, c, n -> created.get(prefix + n));
				// Creating a method runs the abstract checks on the field it creates.
				switch (c.kind) {
					case KAbstractImpl(a) if (cff.cffKind.match(FFun(_))): checkAbstractCasts(ctx, a, c, target, cff, isAbstractMember);
					case _:
				}
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
				// An overload sibling joins the first declaration's overloads; the map keeps the first.
				if (!created.exists(key)) created.set(key, target);
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
		// A class whose own build is still to run gets there after it (EvalMacro.ensureBuilt).
		if (!hxc.eval.EvalMacro.hasPendingBuild(ctx, c)) initClassTail(ctx, c);
	}

	// The end of field initialisation, which a subclass's build macro already sees. The tallies are
	// the forced constructor (an instance var or property with a value) and the uninitialized finals,
	// whose head, the last final declared, is the one reported. A @:structInit class already has its
	// constructor by then; hxc builds that one at install.
	public static function initClassTail(ctx:Context, c:TClass):Void {
		if (TypeFunctions.hasMeta(":structInit", c.meta)) return;
		var entry = ctx.declOfType.get(Context.pathKey(c.path));
		if (entry == null) return;
		var d = switch (entry.decl) { case EClass(dd): dd; case _: return; };
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		var forceConstructor = false;
		var lastUninitializedFinal:Null<TClassField> = null;
		for (cff in d.dData) {
			var isStatic = isAbsImpl && cff.cffName.name != "new";
			for (a in cff.cffAccess) if (a.access == AStatic) isStatic = true;
			if (isStatic || ctx.droppedFieldDecls.exists(cff)) continue;
			var cf = c.fields.get(cff.cffName.name);
			if (cf == null) continue;
			switch (cff.cffKind) {
				case FVar(_, e) | FProp(_, _, _, e) if (e != null): forceConstructor = true;
				case _:
			}
			switch (cff.cffKind) {
				case FVar(_, null) if (TypeFunctions.hasClassFieldFlag(cf, CfFinal) && !TypeFunctions.hasClassFieldFlag(cf, CfExtern)
						&& !TypeFunctions.hasClassFlag(c, CExtern) && !TypeFunctions.hasClassFlag(c, CInterface)):
					lastUninitializedFinal = cf;
				case _:
			}
		}
		if (lastUninitializedFinal != null && c.constructor == null && !TypeFunctions.hasClassFlag(c, CAbstract)) {
			TypeFields.addDiagnosticOnce(ctx, "This class has uninitialized final vars, which requires a constructor", c.pos);
			TypeFields.addDiagnosticOnce(ctx, "Example of an uninitialized final var", lastUninitializedFinal.namePos);
		}
		// addConstructor does not deal with overloads, so a platform with them goes without.
		if (!ctx.platformConfig.supportsOverload) Typer.addConstructor(new hxc.typing.TyperContext(ctx), c, forceConstructor);
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
		// The same wait as the field verdicts: the checks are for the fields a build leaves.
		if (hxc.eval.EvalMacro.hasPendingBuild(ctx, c)) return;
		if (c.hxcFieldChecksDone) return;
		c.hxcFieldChecksDone = true;
		var isExtern = TypeFunctions.hasClassFlag(c, CExtern);
		// The half ModuleLoader cannot see: for a static field the superclass chain's instance fields
		// collide too. Skipped when the same-class half has already reported, since one duplicate is
		// computed and reported once. In declaration order: the field being added collides with what the
		// class already holds - a static with the instance fields (the superclass chain's included), an
		// instance field with the statics - and reports at the whole field. It cannot run at
		// registration, before the heritage resolves: a
		// class with a missing parent must not report the collision.
		if (!isExtern) {
			var all = c.orderedStatics.concat(c.orderedFields);
			all.sort(function(a, b) return a.pos.min - b.pos.min);
			var seenStatic = new haxe.ds.StringMap<Bool>(), seenInstance = new haxe.ds.StringMap<Bool>();
			for (cf in all) {
				if (cf.name == "new") continue;
				var isStatic = c.statics.get(cf.name) == cf;
				var collides = isStatic
					? (seenInstance.exists(cf.name) || getDeclaredIn(c.superClass, cf.name) != null)
					: seenStatic.exists(cf.name);
				if (collides)
					ctx.addDiagnostic("Same field name can't be used for both static and instance : " + cf.name, cf.pos);
				(isStatic ? seenStatic : seenInstance).set(cf.name, true);
			}
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
	public static function nthFieldNamed(ordered:Array<TClassField>, name:String, n:Int, fallback:TClassField):TClassField {
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

	// The method check for each property: the accessor checks, and an interface's generated accessors.
	// (A hint-less accessor's type comes from resolveFieldType.)
	static function linkPropertyAccessors(ctx:Context, c:TClass, isAbsImpl:Bool):Void {
		// A property accessor placed with the wrong staticness (a member accessor for a static property, or
		// vice versa) is reported.
		var isExtern = TypeFunctions.hasClassFlag(c, CExtern);
		// The method check is scheduled only for a class that is not a library type.
		var isLib = TypeFunctions.hasMeta(":libType", c.meta);
		// The signature LINKING below is idempotent, so it does not matter that an abstract impl resolves
		// its fields more than once; the accessor COMPLAINTS are not, so each check runs exactly once per
		// property declaration.
		var reportAccessors = !c.hxcPropAccessorsChecked;
		c.hxcPropAccessorsChecked = true;
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
		function loop(fields:StringMap<TClassField>, other:StringMap<TClassField>, propIsStatic:Bool):Void {
			inline function genAccessor(accName:String, propType:T, isSetter:Bool, propPos:Position):TClassField {
				// Generate the virtual accessor for an interface property.
				var ft = isSetter ? TFun({args: [{name: "value", opt: false, t: propType}], ret: propType}) : TFun({args: [], ret: propType});
				// The accessor's position is the PROPERTY field's own: it stands for `x(get, set)`, not for
				// the
				// whole declaration, and --xml/--json print it.
				var acc = TypeFunctions.mkField(accName, ft, propPos, Position.nullPos, true, false);
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
								checkFoundAccessor(g, name, cf.pos, pt, false, TypeFunctions.hasClassFieldFlag(cf, CfImpl));
							}
							else if (TypeFunctions.hasClassFlag(c, CInterface)) {
								var acc = genAccessor("get_" + name, pt, false, cf.pos);
								fields.set(acc.name, acc);
								genAccessors.push(acc);
							}
							else accGet = checkAccessor("get_" + name, name, fields, other, propIsStatic, cf.pos, true);
						}
						if (vk.write.match(AccCall)) {
							var st = fields.get("set_" + name);
							if (st != null) {
								checkFoundAccessor(st, name, cf.pos, pt, true, TypeFunctions.hasClassFieldFlag(cf, CfImpl));
							}
							else if (TypeFunctions.hasClassFlag(c, CInterface)) {
								var acc = genAccessor("set_" + name, pt, true, cf.pos);
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

	// A @:libType class's interfaces are never checked
	static function scheduleInterfaceCheck(ctx:Context, c:TClass):Void
		ctx.delay(Context.PConnectField, () -> hxc.filters.InterfaceCheck.checkInterfacesOrDelay(ctx, c));

	static function checkHerit(ctx:Context, c:TClass, t:T, isExtends:Bool, p:Position, ?declP:Position, ?hasInterf:Array<Bool>):Void {
		var isLib = TypeFunctions.hasMeta(":libType", c.meta);
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
						// An interface's super-interfaces are checked too, once, at PConnectField.
						if (hasInterf != null && !hasInterf[0]) {
							if (!isLib) scheduleInterfaceCheck(ctx, c);
							hasInterf[0] = true;
						}
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
					// The class's interfaces are checked once, at PConnectField.
					if (hasInterf != null && !hasInterf[0] && !isLib && !TypeFunctions.hasMeta("$do_not_check_interf", c.meta)) {
						scheduleInterfaceCheck(ctx, c);
						hasInterf[0] = true;
					}
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

		// The abstract's own slot does the HEADER and no more: the underlying type, the metadata casts, the
		// flags. Everything that needs the implementation's FIELDS - the enum-abstract members, the
		// @:from/@:to cast methods, the operators, the field signatures themselves - is the implementation
		// class's own build, which takes the PBuildClass delay like every class (it is declared as a class)
		// and so runs in that bucket's last-declaration-first order, AFTER a later class's heritage: with
		// `abstract A { function g():Nope2 }` before `class P extends Nope`, Nope is reported and the
		// module
		// stops. resolveModule calls resolveAbstractImpl at the implementation's slot; an abstract without
		// one has nothing to wait for.
		if (a.impl == null) resolveAbstractImpl(ctx, a, d, p);
	}

	// The implementation's build (see resolveAbstract): the cast methods, the field signatures,
	// the operators. The enum-abstract members are rewritten by buildEnumAbstractFields before
	// the implementation class resolves (resolveModule).
	public static function resolveAbstractImpl(ctx:Context, a:TAbstract, d:Definition<AbstractFlag, Array<ClassField>>, p:Position):Void {
		if (a.impl != null) {
			// Reaching for a class's fields is one-shot: whoever gets there first does the work and
			// everyone
			// after is a no-op.
			buildClassFields(ctx, a.impl, p);
			// The abstract checks run as each field binds, after the build macros: an implementation whose
			// fields wait for its build registers its operators once they are resolved
			// (resolveDeferredAbstractOps).
			if (a.impl.hxcFieldsDeferred) {
				a.impl.hxcAbstractOpsDeferred = true;
				return;
			}
		}
		resolveAbstractOps(ctx, a, d);
	}

	public static function resolveDeferredAbstractOps(ctx:Context, a:TAbstract):Void {
		var ad = ctx.declOfType.get(Context.pathKey(a.path));
		switch (ad == null ? null : ad.decl) {
			case EAbstract(d): resolveAbstractOps(ctx, a, d);
			case _:
		}
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
			var isInlineField = false;
			for (acc in cff.cffAccess) switch (acc.access) {
				case AStatic: isStatic = true;
				case AMacro: isMacroField = true;
				case AInline: isInlineField = true;
				case _:
			}
			var isAbstractMember = !isStatic;
			var ta = TAbstract(a, [for (_ in a.params) TypeFunctions.mkMono()]);
			var tthis = (isAbstractMember || TypeFunctions.hasMeta(":to", cf.meta)) ? TypeFunctions.monomorphs(a.params, a.thisType) : a.thisType;
			var targ = isAbstractMember ? tthis : ta;
			// A single field may carry SEVERAL of these metas at once (e.g. `@:op(A + B) @:arrayAccess
			// @:resolve`), so each is handled independently rather than mutually exclusively: every meta of
			// the
			// field is walked.
			// Whether the field may have no expression: see abstractFieldAllowsNoExpr. An arm that raises
			// ends
			// the field before the flag is read, so it is computed up front.
			var allowsNoExpr = abstractFieldAllowsNoExpr(a, cff);
			// A macro field has no body in the host (hostBodiless), so there it takes every no-body arm
			// below; the macro world keeps the body.
			var hostBodiless = isMacroField && !ctx.isMacro;
			if (TypeFunctions.hasMeta(":arrayAccess", cff.cffMeta)) {
				// This arm covers @:arrayAccess and @:op([]).
				if (isMacroField) ctx.addDiagnostic("Invalid modifier: macro on array-access function", cff.cffPos);
				a.array.push(cf);
			}
			// @:resolve routes to the same read/write registration as @:op([EField]).
			if (TypeFunctions.hasMeta(":resolve", cff.cffMeta)) {
				registerResolveField(ctx, a, cf, cff, cf.pos, targ, isMacroField);
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
							if (isMacroField) ctx.addDiagnostic("Invalid modifier: macro on array-access function", cff.cffPos);
							a.array.push(cf);
						// Assignment / null-coalescing / ternary overloads
						// are explicitly rejected.
						case EBinop(OpAssign, _, _):
							throw new ContextError("Assignment overloading is not supported", cf.pos);
						case EBinop(OpNullCoal, _, _) | EBinop(OpAssignOp(OpNullCoal), _, _):
							throw new ContextError("Null coalescing overloading is not supported", cf.pos);
						case ETernary(_, _, _):
							throw new ContextError("Ternary overloading is not supported", cf.pos);
						case EBinop(op, _, _):
							// This comes before the arity check below, which raises.
							if (isMacroField) ctx.addDiagnostic("Invalid modifier: macro on operator function", cff.cffPos);
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
						// `@:op(unop A)` / `@:op(A unop)`: register
						// (op, flag, cf) in unops.
						case EUnop(op, flag, _):
							if (isMacroField) ctx.addDiagnostic("Invalid modifier: macro on operator function", cff.cffPos);
							a.unops.push({op: op, flag: flag, cf: cf});
						// `@:op(a)` call overload. The first method
						// becomes `call`; later ones are prepended as overloads of that field.
						case ECall(_, _):
							if (a.call == null)
								a.call = cf;
							else
								a.call.overloads.unshift(cf);
						case EField(_, _, _):
							// Reported at pos - the whole field - not at the @:op argument, so a duplicate points at the
							// declaration.
							registerResolveField(ctx, a, cf, cff, cf.pos, targ, isMacroField);
						case _:
					}
				}
			}
			// This and the return-type check below sit in the same body-less block, and the inline one comes
			// first. It is recorded, not raised, so the return-type check still runs after it on the same
			// field.
			switch (cff.cffKind) {
				case FFun(fd) if ((fd.fExpr == null || hostBodiless) && isInlineField):
					ctx.addDiagnostic("Inline functions must have an expression", cf.pos);
				case _:
			}
			// A body-less function in an abstract cannot have its return type inferred from anything, so it
			// must be written out. This precedes the @:noExpr tagging below and applies to every body-less
			// function of the abstract, whether or not the metadata on it allows the missing body.
			switch (cff.cffKind) {
				case FFun(fd) if (fd.fExpr == null && fd.fType == null && !hostBodiless):
					// Raised at pos, the field's own position, so it is recorded and the field is skipped: the
					// module keeps going and a second body-less field reports as well. Raising it out of this pass
					// instead ends the module on the first one, and leaves a later heritage error of the same
					// module unreported.
					ctx.addDiagnostic("Functions without expressions must have an explicit return type", cf.pos);
					ctx.droppedFieldDecls.set(cff, true);
					// Every implementation field is a static, so not adding the field means removing it
					// from
					// the statics.
					c.statics.remove(cf.name);
					c.orderedStatics.remove(cf);
					continue;
				case _:
			}
			// The test is for a missing body, so a macro field in the host on one of these arms does
			// not bind, exactly like a body-less one.
			if (allowsNoExpr) switch (cff.cffKind) {
				case FFun(fd) if (fd.fExpr == null || hostBodiless): ctx.abstractNoExprFields.set(cf, true);
				case _:
			}
			// A body-less function on such a field is a declaration only (the operation is performed
			// natively): tag it @:noExpr and, unless the abstract is @:coreType, never add it to the
			// implementation class, so no storage or dispatch is generated for it.
			switch (cff.cffKind) {
				case FFun(fd) if ((fd.fExpr == null || hostBodiless) && allowsNoExpr):
					cf.meta.unshift({name: ":noExpr", params: [], pos: hxc.ast.Position.nullPos});
					if (!TypeFunctions.hasMeta(":coreType", a.meta)) {
						c.orderedStatics.remove(cf);
						if (c.statics.get(cf.name) == cf) c.statics.remove(cf.name);
					}
				case _:
			}
		}
	}

	// Set from the start for a @:coreType abstract, and allowed by the @:arrayAccess / @:op([]) /
	// @:op(binop) / @:op(unop) / @:op(call) arms - never by @:from, @:to, @:resolve or @:op(a.b).
	// Allowing it does nothing for an extern field, which the `extern` access or the @:extern metadata
	// decides.
	public static function abstractFieldAllowsNoExpr(a:TAbstract, cff:ClassField):Bool {
		if (TypeFunctions.hasMeta(":coreType", a.meta)) return true;
		for (acc in cff.cffAccess) if (acc.access == AExtern) return false;
		if (TypeFunctions.hasMeta(":extern", cff.cffMeta)) return false;
		for (m in cff.cffMeta) switch (m.name) {
			case ":arrayAccess":
				return true;
			case ":op" if (m.params.length == 1):
				switch (m.params[0].expr) {
					case EArrayDecl(_) | EUnop(_, _, _) | ECall(_, _):
						return true;
					case EBinop(OpAssign | OpNullCoal | OpAssignOp(OpNullCoal), _, _):
						return false;
					case EBinop(_, _, _):
						return true;
					case ETernary(_, _, _):
						return false;
					case _:
				}
			case _:
		}
		return false;
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

	public static function isPosInfos(t:T):Bool {
		return switch (t) {
			case TMono(r): r.type == null ? false : isPosInfos(r.type);
			case TLazy(f): isPosInfos(TypeFunctions.lazyType(f));
			case TType(td, []) if (td.path.name == "PosInfos" && td.path.pack.length == 1 && td.path.pack[0] == "haxe"): true;
			case TType(td, tl): isPosInfos(TypeFunctions.applyParams(td.params, tl, td.type));
			case TAbstract(ab, [inner]) if (ab.path.name == "Null" && ab.path.pack.length == 0): isPosInfos(inner);
			case _: false;
		};
	}

	// The abstract checks' @:from and @:to arms, run on the impl class's field as it is created: the
	// cast entry is that field, and its stored type is the protected lazy that PForce forces. An Error
	// escaping the lazy is fatal. The meta list is walked in order and every @:from and @:to on it
	// registers; the prepended lists are reversed at the end of field initialisation, which appending
	// in field order already is.
	static function checkAbstractCasts(ctx:Context, a:TAbstract, c:TClass, cf:TClassField, cff:ClassField, isAbstractMember:Bool):Void {
		var t = cf.type;
		var ret = switch (t) { case TFun(sig): sig.ret; case _: return; };
		for (x in a.fromField) if (x.cf == cf) return;
		for (x in a.toField) if (x.cf == cf) return;
		var p = cff.cffPos;
		var isMacro = cf.kind.match(Method(MethMacro));
		// Made once per field and shared by its arms.
		var m = TypeFunctions.mkMono();
		var ta:T = TAbstract(a, [for (_ in a.params) TypeFunctions.mkMono()]);
		var tthis = (isAbstractMember || TypeFunctions.hasMeta(":to", cf.meta)) ? TypeFunctions.monomorphs(a.params, a.thisType) : a.thisType;
		function fatal(e:hxc.core.TypingError):Dynamic {
			if (Std.isOfType(e, hxc.core.TypingError.FatalError)) throw e;
			throw new hxc.core.TypingError.FatalError(e.message, e.pos, e.depth, true);
		}
		for (meta in cf.meta) switch (meta.name) {
			case ":from":
				var r:Ref<TLazy> = new Ref(null);
				r.set(TypeFunctions.lazyWait(function():T {
					r.set(TypeFunctions.lazyProcessing(function() return t));
					try {
						// The return type of a from-function must be the abstract, not the
						// underlying type.
						if (!isMacro) try TypeUnification.typeEqKind(EqStrict, ret, ta)
							catch (ue:hxc.core.TypeUnification.UnifyError) throw new hxc.core.TypingError(TPrinting.betterErrorMessage(ue.errors), p);
						var arg:T = switch (t) {
							case TFun(sig) if (sig.args.length == 1): sig.args[0].t;
							case TFun(sig) if (sig.args.length == 2 && sig.args[1].opt && isPosInfos(sig.args[1].t)): sig.args[0].t;
							case _: throw new hxc.core.TypingError("@:from cast functions must accept exactly one argument", p);
						};
						r.set(TypeFunctions.lazyAvailable(arg));
						return arg;
					} catch (e:hxc.core.TypingError) return fatal(e);
				}));
				a.fromField.push({t: TLazy(r), cf: cf});
				ctx.delay(Context.PForce, function() TypeFunctions.lazyType(r));
			case ":to":
				if (isMacro) ctx.addDiagnostic("Invalid modifier: macro on cast function", p);
				// The argument check runs over the field's own signature, `this` included for a member.
				var validArgs = switch (t) {
					case TFun(sig): sig.args.length == 1 || (sig.args.length == 2 && sig.args[1].opt && isPosInfos(sig.args[1].t));
					case _: true;
				};
				if (!validArgs && !TypeFunctions.hasMeta(":multiType", a.meta))
					throw new hxc.core.TypingError(isAbstractMember ? "@:to method should have no arguments" : "static @:to method should have one argument", p);
				if (!TypeFunctions.hasClassFieldFlag(cf, CfImpl)) TypeFunctions.addClassFieldFlag(cf, CfImpl);
				var isMultitypeCast = TypeFunctions.hasMeta(":multiType", a.meta) && !isAbstractMember;
				if (isMultitypeCast && !TypeFunctions.hasMeta(":multiType", cf.meta))
					cf.meta = ([{name: ":multiType", params: [], pos: Position.nullPos}] : Metadata).concat(cf.meta);
				var r:Ref<TLazy> = new Ref(null);
				r.set(TypeFunctions.lazyWait(function():T {
					r.set(TypeFunctions.lazyProcessing(function() return t));
					try {
						var args:Array<T> = if (isMultitypeCast) {
							var ctor = c.statics.get("_new");
							if (ctor == null)
								throw new hxc.core.TypingError("Constructor of multi-type abstract must be defined before the individual @:to-functions are", cf.pos);
							switch (TypeFunctions.follow(TypeFunctions.monomorphs(a.params, ctor.type))) {
								case TFun(sig): [for (x in sig.args) x.t];
								case _: throw "multi-type constructor is not a function";
							}
						} else switch (cf.type) {
							// This reads type unfollowed: the field's own lazy type by now, unless it
							// binds no body.
							case TFun(sig) if (sig.args.length == 2 && sig.args[1].opt && isPosInfos(sig.args[1].t)): [sig.args[1].t];
							case _: [];
						};
						// Resolve the return monomorph `m` against the expected signature.
						var expected:T = TFun({args: [for (x in [tthis].concat(args)) {name: "", opt: false, t: x}], ret: m});
						try TypeUnification.unifyDefault(t, expected)
						catch (ue:hxc.core.TypeUnification.UnifyError) throw new hxc.core.TypingError(TPrinting.betterErrorMessage(ue.errors), cf.pos);
						var res:T = switch (TypeFunctions.follow(m)) {
							case TMono(_) if (ret == TypeFunctions.tDynamic): TypeFunctions.tDynamic;
							case mm: mm;
						};
						r.set(TypeFunctions.lazyAvailable(res));
						return res;
					} catch (e:hxc.core.TypingError) return fatal(e);
				}));
				a.toField.push({t: TLazy(r), cf: cf});
				ctx.delay(Context.PForce, function() TypeFunctions.lazyType(r));
			case _:
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

	// The rewrite of an implementation whose @:build macros just ran, over the fields they left.
	public static function buildEnumAbstractAfterBuild(ctx:Context, a:TAbstract):Void {
		var ad = ctx.declOfType.get(Context.pathKey(a.path));
		var implEntry = ctx.declOfType.get(Context.pathKey(a.impl.path));
		switch ([ad == null ? null : ad.decl, implEntry == null ? null : implEntry.decl]) {
			case [EAbstract(dd), EClass(impl)]:
				var saved = ctx.currentModule;
				ctx.currentModule = a.impl.module;
				buildEnumAbstractFields(ctx, a, dd.dParams, impl.dData, ad.pos);
				ctx.currentModule = saved;
			case _:
		}
	}

	static function buildEnumAbstractFields(ctx:Context, a:TAbstract, dParams:Array<TypeParam>, fields:Array<ClassField>, p:Position):Void {
		// The module's context init runs before the enum-abstract rewrite.
		ctx.contextInitRun(a.module);
		var c = a.impl;
		// At: the abstract self-type hint, built the way TExprToExpr converts a type back to syntax: a
		// PRIVATE type converts to its bare name, a secondary type to Module.Sub, so loadComplexType
		// resolves it back to this abstract.
		var aTParams:Array<TypeParamOrConst> = [
			for (tp in dParams) TPType({ct: CTPath({tpackage: [], tname: tp.tpName.name, tparams: [], tsub: null}), pos: p})
		];
		var aCt = if (a.isPrivate)
			CTPath({tpackage: [], tname: a.path.name, tparams: aTParams, tsub: null});
		else if (a.path.name == a.module.path.name)
			CTPath({tpackage: a.path.pack, tname: a.path.name, tparams: aTParams, tsub: null});
		else
			CTPath({tpackage: a.module.path.pack, tname: a.module.path.name, tparams: aTParams, tsub: a.path.name});
		var aT:TypeHint = hxc.typing.Typeload.synthesizedHint({ct: aCt, pos: p});
		hxc.context.ModuleLoader.buildEnumAbstract(ctx.basic, a, aT, fields, ctx);
		// An EAOther member gets no synthesised value and no hint, so it is still a bare `var A;` when
		// the field loop reaches it and reports the missing hint on top of "Value required".
		// registerFields runs that check before this build and so cannot know the mode; it exempts every
		// enum-abstract member there and asks again here.
		for (cff in fields) switch (cff.cffKind) {
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
		// Each field is added at the END of its iteration, as in resolveClass.
		var created = new haxe.ds.StringMap<TClassField>();
		for (cff in implFields) {
			var isStatic = false;
			for (acc in cff.cffAccess) if (acc.access == AStatic) isStatic = true;
			// Abstract-impl promotion (see resolveClass): a non-static impl field is a static.
			if (!isStatic && cff.cffName.name != "new") isStatic = true;
			var cf = if (!isStatic && cff.cffName.name == "new") c.constructor
				else TypeFunctions.declaredField(c, cff.cffName.name, isStatic);
			if (cf == null) continue;
			// A duplicate declaration was reported and never added, so it declares no field; pairing it by
			// name hands it the field it merely collided with.
			if (ctx.droppedFieldDecls.exists(cff)) continue;
			try {
				// An abstract-impl field resolves against the abstract's type parameters. The impl class is
				// declared with none of its own, so a synthesized enum value hinted `Name<T>` has nothing to
				// bind T to without them.
				var params = TypeFunctions.hasClassFieldFlag(cf, CfImpl) ? a.params : c.params;
				var prefix = isStatic ? "s:" : "i:";
				resolveFieldType(ctx, params, cf, cff, c.module, c, n -> created.get(prefix + n));
				// An enum-abstract member keeps a hint it DECLARED, and only one that declared none is
				// typed as the
				// abstract, so `var A:Int = 1` in `enum abstract E(Int)` is rejected - by the binding's
				// check, below
				// in TypeFields.
				if (TypeFunctions.hasClassFieldFlag(cf, CfEnum)) switch (cff.cffKind) {
					case FVar(null, _):
						cf.type = TAbstract(a, TypeFunctions.extractParamTypes(a.params));
					case _:
				}
				var key = (isStatic ? "s:" : "i:") + cff.cffName.name;
				if (!created.exists(key)) created.set(key, cf);
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
		// A display-allowed load.
		var tt = Typeload.loadComplexType(ctx, td.params, d.dData, true);
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
				// A constructor is typed with the enum's parameters in scope.
				ctorParams = Typeload.typeTypeParams(ctx, {pack: [], name: c.ecName.name}, c.ecParams, null, TPHEnumConstructor, null, e.params);
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
			// A cursor on the constructor's name answers with the constructor, over its whole declaration.
			if (hxc.typing.Typer.atDisplayPos(ef.namePos)) hxc.typing.Typer.displayEnumField(e, ef, ef.pos);
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
	public static function resolveFieldType(ctx:Context, typeParams:TypeParams, cf:TClassField, cff:ClassField, ?ownerModule:ModuleDef, ?owner:TClass,
			?createdField:String->Null<TClassField>):Void {
		var fieldModule = ownerModule == null ? ctx.currentModule : ownerModule;
		switch (cff.cffKind) {
			case FVar(th, eo):
				// Var/final field with an explicit hint -> resolve; else leave the mono the typer would
				// infer from
				// the initializer expr in Phase 3 pt c.
				// The variable's hint loads as a type hint, a display-allowed load.
				if (th != null) cf.type = Typeload.loadTypeHint(ctx, typeParams, th);
				// The initializer is recorded at field CREATION, after the hint loads, so a @:generic
				// specialization cloned from a HERITAGE clause - before the base's body is typed - still
				// copies its
				// :value.
				dropGeneratedMeta(cf);
				if (eo != null) cf.meta = [{name: ":value", params: [eo], pos: Position.nullPos}].concat(cf.meta);
			case FProp(_, _, th, eo):
				// A property's hint loads as a type hint as well.
				if (th != null) cf.type = Typeload.loadTypeHint(ctx, typeParams, th);
				dropGeneratedMeta(cf);
				if (eo != null) cf.meta = [{name: ":value", params: [eo], pos: Position.nullPos}].concat(cf.meta);
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
				// The RETURN is typed before the arguments, so whatever the return type loads is loaded
				// first.
				if (isMacroField && fieldModule != null) ctx.currentModule = fieldModule;
				// A constructor's return type is always Void regardless of any hint, so its signature reads
				// TFun(args, Void). Visible in a cppia host's __script_construct signature.
				// The hint is still loaded, for the display alone, so a cursor inside it has something to
				// answer
				// from; the resulting type is discarded either way.
				if (cf.name == "new" && !isStaticField && fd.fType != null
						&& hxc.typing.Typer.atDisplayPos(fd.fType.pos))
					try Typeload.loadTypeHint(ctx, localParams, fd.fType, false) catch (_:Dynamic) {}
				// A `get_` method with no arguments is a getter and a `set_` method with one a setter; one
				// without a hint takes the type of the property the rest of its name names, when that
				// property reads (getter) or writes (setter) through a call.
				var name = cff.cffName.name;
				var accessorKind = name.length < 4 ? 0 : switch (name.substr(0, 4)) {
					case "get_": fd.fArgs.length == 0 ? 1 : 0;
					case "set_": fd.fArgs.length == 1 ? 2 : 0;
					case _: 0;
				};
				function propertyType():Null<T> {
					var pcf = createdField == null ? null : createdField(name.substr(4));
					if (pcf == null) return null;
					return switch (pcf.kind) {
						case Var(vk) if (accessorKind == 1 && vk.read == AccCall): pcf.type;
						case Var(vk) if (accessorKind == 2 && vk.write == AccCall): pcf.type;
						case _: null;
					};
				}
				var ret = (cf.name == "new" && !isStaticField) ? ctx.basic.tvoid : {
					var pt = fd.fType == null && accessorKind != 0 ? propertyType() : null;
					pt != null ? pt : (isMacroField ? loadMacroHint(ctx, localParams, fd.fType) : Typeload.loadTypeHint(ctx, localParams, fd.fType, false));
				};
				if (isMacroField && fieldModule != null) ctx.currentModule = fieldModule;
				var args:Array<TSignatureArg> = [];
				// An abstract member other than `_new` and a macro takes the underlying `this` first, typed
				// thisType
				// with no name lookup. An abstract member is a field declared without static in the impl
				// class.
				// CfImpl is not the test: a static @:to carries it too.
				if (!isStaticField && cf.name != "_new" && !isMacroField) switch (owner == null ? null : owner.kind) {
					case KAbstractImpl(a): args.push({name: "this", opt: false, t: a.thisType});
					case _:
				}
				for (i in 0...fd.fArgs.length) {
					var fa = fd.fArgs[i];
					if (isMacroField && fieldModule != null) ctx.currentModule = fieldModule;
					// A setter's first argument takes the property type the same way.
					var pt = i == 0 && fa.type == null && accessorKind == 2 ? propertyType() : null;
					var at = pt != null ? pt : isMacroField ? loadMacroHint(ctx, localParams, fa.type) : Typeload.loadTypeHint(ctx, localParams, fa.type, false);
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
				cf.type = TFun({args: args, ret: ret});
				cf.params = methodParams;
				// The argument metadata is generated at field CREATION, so a body-less function (an extern
				// declaration) records its defaults too.
				dropGeneratedMeta(cf);
				Typeload.generateArgsMeta(fd.fArgs, m -> cf.meta = [m].concat(cf.meta));
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
	// An enum abstract's implementation fields are resolved twice here (buildEnumAbstractFields,
	// then resolveClassFields) where the reference creates each field once. What the first pass
	// generated is dropped before the second adds it again; it is the only metadata carrying the
	// shared null position, so a user's own @:value survives.
	static function dropGeneratedMeta(cf:TClassField):Void {
		cf.meta = [for (m in cf.meta) if (m.pos != Position.nullPos || (m.name != ":value" && m.name != ":haxe.arguments")) m];
	}

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
					// The overload's own defaults and argument metadata.
					Typeload.generateArgsMeta(f.fArgs, m -> ocf.meta = [m].concat(ocf.meta));
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

// The initialisation of one module, and the class builds it queued.
private class ModuleInit {
	public var ctx:Context;
	public var m:ModuleDef;
	public var builtBefore:Array<String> = [];
	// A declaration error abandoned the module: its builds still queued never run.
	public var aborted:Bool = false;
	public var pending:Int = 0;
	var open:Bool = true;

	public function new(ctx:Context, m:ModuleDef) {
		this.ctx = ctx;
		this.m = m;
	}

	// The module's resolution stays open (TypeResolve.resolving) until its last class is built.
	public function close():Void {
		open = false;
		if (pending == 0) TypeResolve.resolving.remove(m);
	}

	public function slotDone():Void {
		pending--;
		if (!open && pending == 0) TypeResolve.resolving.remove(m);
	}
}

private class ClassSlot {
	public var init:ModuleInit;
	public var mt:ModuleType;
	public var c:TClass;
	public var decl:TypeDef;
	public var pos:Position;
	public var started:Bool = false;
	var finished:Bool = false;

	public function new(init:ModuleInit, mt:ModuleType, c:TClass, decl:TypeDef, pos:Position) {
		this.init = init;
		this.mt = mt;
		this.c = c;
		this.decl = decl;
		this.pos = pos;
	}

	public function finish():Void {
		if (finished) return;
		finished = true;
		c.hxcClassSlot = null;
		init.slotDone();
	}
}
