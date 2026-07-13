package hxc.eval;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.context.Context;
import hxc.typing.TyperContext;
import hxc.typing.Typer;
import hxc.typing.Typeload;
import hxc.typing.Calls;
import hxc.typing.AccessKind.FieldAccess;
import hxc.eval.EvalValue;
import hxc.eval.EvalContext;
import hxc.eval.EvalHash;

// Runs macro functions at compile time: the typer hands a macro call here, the arguments are
// encoded into haxe.macro.Expr values, the function runs in a macro-mode interpreter, and the
// returned Expr value is decoded back to an AST and typed in place.
class EvalMacro {
	static var macroCtx:Null<EvalContext> = null;
	static var lastModuleCount:Int = -1;
	// A macro-world module was dropped (server eviction, the display file's re-load): the next flush
	// has types to replace even when the module count came back to what it was.
	static var macroWorldDirty:Bool = false;
	static var building:Bool = false;
	static var curPos:Position = Position.nullPos;
	static var macroCallDepth = 0;
	public static function debugCurPos():Position return curPos;

	// Where the running macro frame is, i.e. the API call itself.
	static function apiCallPos():Position {
		var ec = EvalContext.getCtx();
		var env = ec == null ? null : EvalContext.getEval(ec).env;
		if (env == null) return curPos;
		return env.parent != null ? env.parent.leavePos : env.leavePos;
	}
	static var curModule:Null<ModuleDef> = null;
	static var curTctx:Null<TyperContext> = null;
	static var expectedTypeStack:Array<WithType> = [];
	static var curBuildFields:Null<Array<ClassField>> = null;
	static var curBuildClass:Null<TClass> = null;
	// Context.getLocalType answers the built type, which is not always a class: an enum build has no
	// curBuildClass at all.
	static var curBuildType:Null<T> = null;
	static var curBuildParams:TParams = [];
	static var currentCom:Null<Context> = null;
	static var macroMessages:Array<EvalValue> = [];
	static var builtClasses:Map<String, Bool> = new Map();
	static var onAfterInitMacrosCallbacks:Array<{ec:EvalContext, fn:EvalValue}> = [];
	static var onAfterTypingCallbacks:Array<{ec:EvalContext, fn:EvalValue}> = [];
	static var onGenerateCallbacks:Array<{ec:EvalContext, fn:EvalValue}> = [];
	static var onGenerateAfterSaveCallbacks:Array<{ec:EvalContext, fn:EvalValue}> = [];
	static var onAfterGenerateCallbacks:Array<{ec:EvalContext, fn:EvalValue}> = [];
	static var macroMonoId:Int = 0;
	// One fake module per file, kept for the whole process so a later compilation depends on the same
	// object and its recorded mtime.
	static var fakeModules:haxe.ds.StringMap<ModuleDef> = new haxe.ds.StringMap();
	static var macroMonos:Map<Int, TMono> = new Map();

	// A typed-expr value round-trips its native objects through a hidden `$` handle: a tvar is stashed on
	// the object itself and read back from its `$` field. Class-field refs round-trip the same way.
	static var tvarRefs:Map<Int, TVar> = new Map();
	static var nextTvarRefId:Int = 0;
	static var cfieldRefs:Map<Int, TClassField> = new Map();
	static var nextCfieldRefId:Int = 0;
	static var moduleTypeRefs:Map<Int, ModuleType> = new Map();
	static var nextModuleTypeRefId:Int = 0;
	static var anonRefs:Map<Int, TAnon> = new Map();
	static var nextAnonRefIdDummy:Int = 0;

	public static function dumpRefStats():Void {
		if (Sys.getEnv("HXC_DBG_REFS") == null) return;
		inline function n<K, V>(m:Map<K, V>):Int { var c = 0; for (_ in m.keys()) c++; return c; }
		var o = Sys.stderr();
		if (macroCom != null) o.writeString("[refs] macroCom modules=" + macroCom.modules.length
			+ " types=" + macroCom.types.length + "
");
		if (curTctx != null && curTctx.com != null) o.writeString("[refs] hostCom modules=" + curTctx.com.modules.length
			+ " types=" + curTctx.com.types.length + "
");
		o.writeString("[refs] tvarRefs=" + n(tvarRefs) + " cfieldRefs=" + n(cfieldRefs)
			+ " moduleTypeRefs=" + n(moduleTypeRefs) + " anonRefs=" + n(anonRefs)
			+ " macroMonos=" + n(macroMonos) + " fakeModules=?" + "
");
		o.flush();
	}
	static var nextAnonRefId:Int = 0;

	static function stashModuleTypeRef(f:Map<Int, EvalValue>, mt:ModuleType):Void {
		var refId = nextModuleTypeRefId++;
		moduleTypeRefs.set(refId, mt);
		// A module type's decl rides in `__t`, an opaque TypeDecl instance, which decode reads back.
		f.set(EvalHash.hash("__t"), opaqueValue("haxe.macro.TypeDecl", refId));
	}

	// The API wrapper turns a decode failure into the macro's uncaught "Invalid expression"; a typing
	// error a reporting native raises (under an outer API's typingTimer) is not its own to convert -
	// it climbs to the API that ran the typer.
	static function regBuiltinRaw(ec:EvalContext, typeName:String, fieldName:String, f:VFunc):Void {
		var key = EvalHash.hash(typeName);
		var list = ec.builtins.staticBuiltins.get(key);
		if (list == null) { list = []; ec.builtins.staticBuiltins.set(key, list); }
		var wrapped:VFunc = function(a:Array<EvalValue>):EvalValue {
			try return f(a)
			catch (d:DecodeFailure) return EvalExceptions.excString(ec, d.text);
		};
		var nameKey = EvalHash.hash(fieldName);
		var entry = {name: nameKey, v: VFunction(wrapped, true)};
		for (i in 0...list.length) if (list[i].name == nameKey) { list[i] = entry; return; }
		list.push(entry);
	}

	static function regBuiltin(ec:EvalContext, typeName:String, fieldName:String, f:VFunc):Void {
		var key = EvalHash.hash(typeName);
		var list = ec.builtins.staticBuiltins.get(key);
		if (list == null) { list = []; ec.builtins.staticBuiltins.set(key, list); }
		// A macro API that fails raises a host typing error (TypingError or ContextError); surface it
		// as a catchable eval exception so macro-level try/catch (e.g. Context.typeof in a try) handles it.
		var wrapped:VFunc = function(a:Array<EvalValue>):EvalValue {
			try return f(a)
			catch (ce:hxc.context.Context.ContextError) return throwMacroError(ec, ce.message, ce.pos)
			catch (te:TypingError) return throwMacroError(ec, te.message, te.pos)
			// typingTimer turns a WithTypeError - an error raised while the macro was called from inside
			// call arguments - into the macro's Error the same way.
			catch (we:hxc.core.TypingError.WithTypeError) return throwMacroError(ec, we.message, we.pos)
			catch (d:DecodeFailure) return EvalExceptions.excString(ec, d.text);
		};
		// A new compilation swaps in its own API. Every closure here holds the com it was registered
		// with, so a re-registration must REPLACE the entry: a lookup through load("<snake>") ->
		// callMacroApi takes the first match, and a duplicate would keep answering from the previous
		// request's dead compilation.
		var nameKey = EvalHash.hash(fieldName);
		var entry = {name: nameKey, v: VFunction(wrapped, true)};
		for (i in 0...list.length) if (list[i].name == nameKey) { list[i] = entry; return; }
		list.push(entry);
	}

	// An expression-filter list to every macro-world type through Filters.apply_filters_once , so each
	// type is filtered exactly once before the interpreter sees it. hxc ran none of them: without
	// captured_vars a macro-world closure's mutable captures are never boxed, which is invisible while
	// a closure reads a LIVE parent frame and fatal the moment one snapshots its captures.
	static var macroFiltered:haxe.ds.ObjectMap<Dynamic, Bool> = new haxe.ds.ObjectMap();

	// The macro context's current module: loading a macro module makes it current, the flush that follows
	// builds its filters under it (so the exceptions filter's setup records that module's dependencies),
	// and nullModule is put back afterwards.
	static var macroCurModule:Null<ModuleDef> = null;

	// Flushing the macro context: the macro world's types in sorted finalization order, each one the
	// interpreter has not seen filtered (`ready`) and then added (the interpreter keeps what it has). The
	// order is the order their static delays - class inits included - run in.
	static function flushMacroWorld(ec:EvalContext):Void {
		var types = hxc.typing.Finalization.sortTypes(macroCom).types;
		// The sorted list becomes the macro com's types (its dump walks them in this order). hxc's macro
		// com keeps its own module list, which the extension slicing reads.
		macroCom.types = types;
		applyMacroWorldFilters(macroCom, types);
		// What fails while adding (a static initializer's exception) is catch_exceptions' report, which
		// as a Fatal_error: the compile ends there. (The had_error skip there is carried by the call's
		// own skipCall: skipping the add here makes hxc's rebuild-on-missing-prototype start a clean
		// world.)
		try EvalMain.addTypes(ec, types) catch (rte:EvalExceptions.EvalRunTimeException) {
			var info = runtimeMacroError(rte);
			if (info != null) throw new hxc.core.TypingError.FatalError(info.message, info.pos, 0, true);
			var stack = uncaughtExceptionStack(rte);
			var fe = new hxc.core.TypingError.FatalError(stack[0].message, stack[0].pos, 0, true);
			fe.callChain = stack;
			throw fe;
		} catch (e:TypingError) {
			// An Error out of adding types - the JIT's own (Unknown identifier) included - ends the
			// compile.
			if (Std.isOfType(e, hxc.core.TypingError.FatalError)) throw e;
			throw new hxc.core.TypingError.FatalError(e.message, e.pos, e.depth, true);
		}
	}

	public static function applyMacroWorldFilters(mcom:Context, types:Array<ModuleType>):Void {
		var tctx = new TyperContext(mcom);
		tctx.filterModule = macroCurModule;
		// The expression filters are built once per flush, the exceptions filter's setup included, with the
		// macro context's current module in effect.
		var exceptions = hxc.filters.Exceptions.filter(tctx);
		// The type filters, built once per flush: removeGenericBase, the exceptions constructor patcher
		// (whose instance load runs here, still under the macro context's current module), addFieldInits
		// (over RenameVars.init of the macro com) and applyNativePaths. The compilation server's snapshot
		// of what the filters change is not taken, since hxc's macro world is reused.
		var patchConstructors = hxc.typing.ExceptionFilters.patcher(tctx);
		macroCurModule = null;
		var renameLocals = hxc.filters.RenameVars.init(mcom.types, false, false);
		for (t in types) {
			var decl:Dynamic = switch (t) { case TClassDecl(c): c; case TEnumDecl(en): en; case TTypeDecl(td): td; case TAbstractDecl(a): a; };
			if (macroFiltered.exists(decl)) continue;
			macroFiltered.set(decl, true);
			switch (t) { case TClassDecl(c): tctx.curclass = c; case _: }
			// The expression filters: handle_abstract_casts, local_statics, VarLazifier, Exceptions and
			// captured_vars.
			hxc.filters.FiltersCommon.runExpressionFilters(tctx, [
				{name: "handle_abstract_casts", f: function(e) return hxc.filters.Filters.handleAbstractCasts(tctx, e)},
				{name: "local_statics", f: function(e) return hxc.filters.Filters.localStatics(tctx, e)},
				{name: "VarLazifier", f: function(e) return hxc.filters.Filters.varLazifier(mcom, e)},
				{name: "Exceptions", f: exceptions},
				{name: "captured_vars", f: function(e) return hxc.filters.CapturedVars.capturedVars(mcom, e)},
			], t);
			// `ready`: the type filters follow the expression filters, type by type.
			hxc.filters.Filters.removeGenericBase(t);
			patchConstructors(t);
			hxc.filters.Filters.addFieldInits(mcom, tctx, renameLocals, t);
			hxc.filters.Filters.applyNativePaths(mcom, t);
		}
	}

	static function registerContext(ec:EvalContext, com:Context):Void {
		// Each macro API is registered under both its public camelCase name (for direct calls to the
		// standard Context method) and its internal underscore-separated ABI name (reached via
		// load("<snake>") ->
		// callMacroApi). Same implementation behind both names.
		function reg2(camel:String, snake:String, f:VFunc):Void {
			regBuiltin(ec, "haxe.macro.Context", camel, f);
			if (snake != camel) regBuiltin(ec, "haxe.macro.Context", snake, f);
		}
		function reg2Raw(camel:String, snake:String, f:VFunc):Void {
			regBuiltinRaw(ec, "haxe.macro.Context", camel, f);
			if (snake != camel) regBuiltinRaw(ec, "haxe.macro.Context", snake, f);
		}
		reg2("defined", "defined", function(a) return com.defines.rawDefined(strOf(a[0])) ? VTrue : VFalse);
		// Resolve against cwd then the class path; the generator splices the raw contents at the requested
		// position.
		reg2("includeFile", "include_file", function(a) {
			var file = strOf(a[0]);
			var position = strOf(a[1]);
			var resolved = if (sys.FileSystem.exists(file)) file else {
				var found = null;
				for (cp in com.classPath) {
					var cand = cp + file;
					if (sys.FileSystem.exists(cand)) { found = cand; break; }
				}
				// The macro's uncaught exception, not a typing error.
				if (found == null) return EvalExceptions.excString(ec, "unable to find file for inclusion: " + file);
				found;
			};
			com.includeFiles.push({file: resolved, position: position});
			return VNull;
		});
		reg2("currentPos", "current_pos", function(a) return encPos(curPos));
		// The display position ENCLOSED IN p, and in the same file. atDisplayPos is both tests (its file
		// compare uses file keys).
		reg2("containsDisplayPosition", "contains_display_position",
			function(a) return hxc.typing.Typer.atDisplayPos(posArg(ec, a, 0, curPos)) ? VTrue : VFalse);
		// The live eval call stack's positions, newest first, skipping the API call frame itself.
		reg2("getMacroStack", "get_macro_stack", function(a) {
			var envs:Array<EvalValue> = [];
			// The first frame is the typed Context.getMacroStack wrapper itself, which is excluded
			// ("excluding the call to Context.getMacroStack()").
			var env = EvalContext.getEval(ec).env;
			if (env != null) env = env.parent;
			while (env != null) {
				envs.push(encPos(hxc.eval.EvalExceptions.envPosition(env)));
				env = env.parent;
			}
			return encodeArray(envs);
		});
		// Reads the PER-CONTEXT flag, like every other primitive registered here. A process-wide static is
		// never reset, so in server mode every request after the first would run its init macros with the
		// flag already true, and Context.assertInitMacro would warn on every Compiler init-only API.
		reg2("initMacrosDone", "init_macros_done", function(a) return com.initMacrosDone ? VTrue : VFalse);
		// Error/fatal_error abort at the given position. A null position fails to decode, which the macro
		// sees as an uncaught "Invalid expression"; the message is never reported.
		reg2Raw("error", "error", function(a) {
			if (a.length > 1 && a[1] == VNull) return EvalExceptions.excString(ec, "Invalid expression");
			// Report the error, then abort with an exception no macro try catches; the interpreter answers
			// nothing and the call types `null`.
			reportError(strOf(a[0]), posArg(ec, a, 1, curPos));
			throw new hxc.eval.EvalExceptions.MacroAbort();
		});
		reg2("fatalError", "fatal_error", function(a) {
			if (a.length > 1 && a[1] == VNull) return EvalExceptions.excString(ec, "Invalid expression");
			// A fatal error, which nothing catches before the compiler prints it and ends the compile - not
			// a macro try, not a build's failure routing.
			throw new hxc.core.TypingError.FatalError(strOf(a[0]), posArg(ec, a, 1, curPos),
				a.length > 2 && a[2].match(VInt(_)) ? intOf(a[2]) : 0, true);
		});
		reg2Raw("reportError", "report_error", function(a) { reportError(strOf(a[0]), posArg(ec, a, 1, curPos)); return VNull; });
		// Context.withOptions: the caller's typer context takes its inlining and transform switches from
		// the options (a null field leaves one alone, anything but a Bool is unexpected), the callback runs
		// (prepareCallback), and Std.finally restores.
		reg2Raw("withOptions", "with_options", function(a) {
			function opt(name:String):Null<Bool> return switch (EvalValueTools.vresolve(EvalField.field(ec, a[0], EvalHash.hash(name)))) {
				case VNull: null;
				case VTrue: true;
				case VFalse: false;
				case v: EvalExceptions.unexpectedValue(ec, v, "bool");
			};
			var inl = opt("allowInlining");
			var tr = opt("allowTransform");
			var f = prepareCallback(ec, a[1]);
			var tctx = curTctx;
			var oldInline = tctx != null ? tctx.allowInline : true;
			var oldTransform = tctx != null ? tctx.allowTransform : true;
			if (tctx != null) {
				if (inl != null) tctx.allowInline = inl;
				if (tr != null) tctx.allowTransform = tr;
			}
			function restore() if (tctx != null) { tctx.allowInline = oldInline; tctx.allowTransform = oldTransform; }
			// Runs the callback under catch_exceptions: an Abort answers null, a thrown haxe.macro.Error is
			// the typing error it names, anything else left uncaught is the compile's error with its chain
			// none of them a macro try's.
			var result = try applyFn(ec, f, [])
				catch (_:hxc.eval.EvalExceptions.MacroAbort) { restore(); return VNull; }
				catch (rte:EvalExceptions.EvalRunTimeException) {
					restore();
					var info = runtimeMacroError(rte);
					if (info != null) throw new TypingError(info.message, info.pos);
					var stack = uncaughtExceptionStack(rte);
					var te = new TypingError(stack[0].message, stack[0].pos);
					te.callChain = stack;
					throw te;
				}
				catch (e:Dynamic) { restore(); throw e; };
			restore();
			return result;
		});
		// Warning/info report through the compiler's message list; get_messages/filter_messages read and
		// filter that same list.
		reg2("warning", "warning", function(a) {
			com.addDiagnostic(strOf(a[0]), posArg(ec, a, 1, curPos), a.length > 2 && a[2].match(VInt(_)) ? intOf(a[2]) : 0, hxc.core.Globals.MessageSeverity.Warning);
			return VNull;
		});
		reg2("info", "info", function(a) {
			com.addDiagnostic(strOf(a[0]), posArg(ec, a, 1, curPos), a.length > 2 && a[2].match(VInt(_)) ? intOf(a[2]) : 0, hxc.core.Globals.MessageSeverity.Information);
			return VNull;
		});
		reg2("makeExpr", "make_expr", function(a) return makeExprValue(ec, a[0], posArg(ec, a, 1, curPos)));
		reg2("getExpectedType", "get_expected_type", function(a) {
			if (expectedTypeStack.length == 0) return VNull;
			return switch (expectedTypeStack[expectedTypeStack.length - 1]) {
				case WithType(t, _): encodeType(ec, t);
				case _: VNull;
			}
		});
		reg2("getCallArguments", "get_call_arguments", function(a) {
			if (com.callArgumentStack.length == 0) return VNull;
			return encodeArray([for (e in com.callArgumentStack[0]) encodeExpr(ec, e)]);
		});
		reg2("getLocalImports", "get_local_imports", function(a) {
			var m = currentModule();
			if (m == null) return encodeArray([]);
			var imports = com.moduleImports.get(Context.pathKey(m.path));
			if (imports == null) return encodeArray([]);
			return encodeArray([for (imp in imports.rawImports) encodeImportExpr(ec, imp)]);
		});
		reg2("getLocalModule", "get_local_module", function(a) {
			var m = currentModule();
			return mkString(m == null ? "" : Context.sTypePath(m.path));
		});
		// Context.parse / parseInlineString both call load("do_parse")(expr, pos, inline). When not
		// inlined, every sub-expression position is rewritten to the given pos, so a parsed macro result
		// reports the call site, not line 1 of the parsed string.
		reg2("do_parse", "do_parse", function(a) {
			var p = posArg(ec, a, 1, curPos);
			var inlined = a.length > 2 && a[2] == VTrue;
			var e = parseApiString(strOf(a[0]), p, inlined, com.defines);
			return encodeExpr(ec, inlined ? e : reanchorExpr(e, p));
		});
		reg2("parse", "parse", function(a) {
			var p = posArg(ec, a, 1, curPos);
			return encodeExpr(ec, reanchorExpr(parseApiString(strOf(a[0]), p, false, com.defines), p));
		});
		reg2("parseInlineString", "parse_inline_string", function(a) { var p = posArg(ec, a, 1, curPos); return encodeExpr(ec, parseApiString(strOf(a[0]), p, true, com.defines)); });
		// The CALLER's position is passed through, so every expression MacroStringTools.formatString builds
		// lands inside the string it was given rather than on the macro call.
		reg2("formatString", "format_string",
			function(a) return encodeExpr(ec, Typer.formatString(strOf(a[0]), posOf(ec, a[1], curPos), com.defines)));
		// Context.typeof types the argument expression and returns its (resolved) macro Type; follow
		// resolves a type (encodeType already collapses bound monomorphs, so it is the identity here).
		reg2("typeof", "typeof", function(a) {
			// An init macro has no expression typer yet; type in the macro world like the reference's
			// macro-context typer does API over mctx).
			var tctx = curTctx != null ? curTctx : (macroCom != null ? new TyperContext(macroCom) : null);
			if (tctx == null) throw new TypingError("typeof outside a macro", curPos);
			var te = typeMacroExpr(tctx, decodeExpr(ec, a[0], curPos));
			settleOpenReturns(te);
			return encodeType(ec, te.type);
		});
		reg2("typeExpr", "type_expr", function(a) {
			var tctx = curTctx != null ? curTctx : (macroCom != null ? new TyperContext(macroCom) : null);
			if (tctx == null) throw new TypingError("typeExpr outside a macro", curPos);
			var te = typeMacroExpr(tctx, decodeExpr(ec, a[0], curPos));
			settleOpenReturns(te);
			return encodeTypedExpr(ec, te);
		});
		// store_expr(e): type a syntax expression and store the typed expression, returning the syntax
		// marker `@:storedTypedExpr(id)` that re-types to it, so the macro gets the marker back and not its
		// syntax again.
		reg2("storeExpr", "store_expr", function(a) {
			if (curTctx == null) throw new TypingError("storeExpr outside a macro", curPos);
			var te = typeMacroExpr(curTctx, decodeExpr(ec, a[0], curPos));
			return storedTypedExprMarker(ec, te);
		});
		// Type the expression and retain its type.
		reg2("typeAndStoreExpr", "type_and_store_expr", function(a) {
			if (curTctx == null) throw new TypingError("typeAndStoreExpr outside a macro", curPos);
			var te = typeMacroExpr(curTctx, decodeExpr(ec, a[0], curPos));
			var fields:Map<Int, EvalValue> = new Map();
			fields.set(EvalHash.hash("expr"), encodeExpr(ec, Calls.texprToSyntax(curTctx, te)));
			fields.set(EvalHash.hash("type"), encodeType(ec, te.type));
			return VObject(new VObject([], ODictionary(fields)));
		});
		// get_typed_expr(te): convert a typed expression back to a syntax expression. A value that is not a
		// decodable typed expression raises "Invalid expression".
		reg2("getTypedExpr", "get_typed_expr", function(a) {
			if (curTctx == null) throw new TypingError("getTypedExpr outside a macro", curPos);
			var te = decodeStoredTypedExpr(ec, a[0]);
			return encodeExpr(ec, Calls.texprToSyntax(curTctx, te));
		});
		// store_typed_expr(te): store the decoded typed expression and return the syntax marker
		// `@:storedTypedExpr(id)` that re-types to it.
		reg2("storeTypedExpr", "store_typed_expr", function(a) {
			if (curTctx == null) throw new TypingError("storeTypedExpr outside a macro", curPos);
			var te = decodeStoredTypedExpr(ec, a[0]);
			return storedTypedExprMarker(ec, te);
		});
		// map_anon_ref(a, fn): rebuild the anonymous structure with every field's type passed through fn,
		// keeping each field's kind, metadata and flags.
		reg2("map_anon_ref", "map_anon_ref", function(a) {
			var t = decodeAnonRef(ec, a[0]);
			var fnv = a[1];
			return switch (TypeFunctions.follow(t)) {
				case TAnon(an):
					var fields = new haxe.ds.StringMap<TClassField>();
					for (name in an.fields.keys()) {
						var f = an.fields.get(name);
						var mappedV = switch (fnv) {
							case VFunction(fn, _): fn([encodeType(ec, f.type)]);
							case _: throw new TypingError("map_anon_ref: expected function", curPos);
						};
						var nf = TypeFunctions.mkField(f.name, decodeType(ec, mappedV), f.pos, f.namePos);
						nf.meta = f.meta;
						nf.kind = f.kind;
						nf.flags = f.flags;
						fields.set(name, nf);
					}
					switch (TypeFunctions.mkAnon(new hxc.core.Ref(an.status.get()), fields)) {
						case TAnon(an2): encodeAnonRef(ec, an2);
						case _: throw new TypingError("map_anon_ref: expected anonymous type", curPos);
					}
				case _: throw new TypingError("map_anon_ref: expected anonymous type", curPos);
			};
		});
		// apply_params(tpl, tl, t): substitute the type parameters through t. The target's parameter
		// occurrences are first rebound by STRUCTURAL equality to the decoded parameter instances, because
		// the substitution itself matches by physical identity.
		reg2("applyTypeParameters", "apply_params", function(a) {
			var tl = [for (x in arrOf(a[1])) decodeType(ec, x)];
			var tpl:TypeParams = [for (v in arrOf(a[0]))
				new TypedTypeParam(strOf(EvalField.field(ec, v, EvalHash.hash("name"))), decodeType(ec, EvalField.field(ec, v, EvalHash.hash("t"))), null)];
			function mapT(t:T):T {
				return switch (t) {
					case TInst(c, _) if (c.kind.match(KTypeParameter(_))):
						var hit:Null<T> = null;
						for (tp in tpl) if (TypeUnification.typeIseqDefault(t, tp.type)) { hit = tp.type; break; }
						hit != null ? hit : TypeFunctions.map(mapT, t);
					case _: TypeFunctions.map(mapT, t);
				};
			}
			return encodeType(ec, TypeFunctions.applyParams(tpl, tl, mapT(decodeType(ec, a[2]))));
		});
		reg2("getType", "get_type", function(a) {
			// When the segment before the last is uppercase it is the module and the last segment is a
			// sub-type (Module.Sub / pack.Module.Sub).
			var parts = strOf(a[0]).split(".");
			var last = parts[parts.length - 1];
			// An empty module name is the macro's uncaught exception, before anything is typed.
			if (last == "") return EvalExceptions.excString(ec, "Empty module name is not allowed");
			var packParts = parts.slice(0, parts.length - 1);
			var tpath:TypePath;
			if (packParts.length > 0) {
				var prev = packParts[packParts.length - 1];
				var c0 = prev.charCodeAt(0);
				if (c0 >= "A".code && c0 <= "Z".code)
					tpath = {tpackage: packParts.slice(0, packParts.length - 1), tname: prev, tsub: last, tparams: []};
				else
					tpath = {tpackage: packParts, tname: last, tsub: null, tparams: []};
			} else {
				tpath = {tpackage: [], tname: last, tsub: null, tparams: []};
			}
			// Context.getType resolves through the TYPER context of the call, so a bare name reaches the
			// sub-types of the module the macro was called from. curModule is that module (set at the
			// invocation); the host com's own currentModule is whatever typing left behind.
			var savedGetTypeMod = com.currentModule;
			if (curModule != null) com.currentModule = curModule;
			var modulesBefore = com.modules.length;
			var t = try typingTimer(com, function() return Typeload.loadInstance(com, [], tpath, curPos, true)) catch (e:Dynamic) {
				com.currentModule = savedGetTypeMod;
				// Context.getType answers nothing only for a missing module raised at the call's position,
				// which is reported as the uncaught exception "Type not found '...'". A module that exists but
				// lacks the type ("Module X does not define type Y") and a miss inside the module being loaded
				// stay the typing errors they are.
				var msg:Null<String> = Std.isOfType(e, TypingError) ? (e : TypingError).message
					: Std.isOfType(e, hxc.context.Context.ContextError) ? (e : hxc.context.Context.ContextError).message : null;
				var epos:Null<Position> = Std.isOfType(e, TypingError) ? (e : TypingError).pos
					: Std.isOfType(e, hxc.context.Context.ContextError) ? (e : hxc.context.Context.ContextError).pos : null;
				if (msg != null && StringTools.startsWith(msg, "Type not found : ") && epos != null
						&& epos.file == curPos.file && epos.min == curPos.min && epos.max == curPos.max)
					return EvalExceptions.excString(ec, "Type not found '" + strOf(a[0]) + "'");
				throw e;
			};
			com.currentModule = savedGetTypeMod;
			// Loading a new module while a field is typed flushes the PBuildClass delays, so the loaded
			// type's build macros run inside the call (an @:autoBuild subclass in the same module reports
			// from here). A type the macro defined (defineType adds its module without that flush) is built
			// at the next flush, after the macro returns.
			if (com.modules.length > modulesBefore) switch (TypeFunctions.follow(t)) {
				case TInst(c, _) if (c.module != null):
					for (mt in c.module.types) switch (mt) {
						case TClassDecl(c2): ensureBuilt(com, c2);
						case _:
					}
				case _:
			}
			return encodeType(ec, t);
		});
		// Context.onTypeNotFound: the callback is appended to com.loadExternType, whose loaders are tried
		// in turn when a module path has no file. A null answer means "not mine" and the next loader gets a
		// turn; anything else is decoded as a TypeDefinition and becomes the module.
		reg2("onTypeNotFound", "on_type_not_found", function(a) {
			var fn = prepareCallback(ec, a[0]);
			var ec2 = ec;
			com.loadExternType.push({name: "onTypeNotFound", load: function(path, p) {
				// prepareCallback: an abort answers nothing, null here.
				var v = try applyFn(ec2, fn, [mkString(hxc.core.Globals.sTypePath(path))]) catch (_:hxc.eval.EvalExceptions.MacroAbort) VNull;
				if (v == VNull) return null;
				var dp = posOf(ec2, EvalField.field(ec2, v, EvalHash.hash("pos")), p);
				return [decodeTypeDefinition(ec2, v, dp)];
			}});
			return VNull;
		});
		// send_json: the string is parsed and sent as the json request's result; without a json request
		// there is nothing to send and it answers false.
		reg2("send_json", "send_json", function(a) {
			if (com.jsonRpcId == null) return VFalse;
			hxc.Compiler.sendMacroJson(com, hxc.core.Json.Json.parse(strOf(a[0])));
			return VTrue;
		});
		// Context.registerModuleDependency: the named module is loaded and then made to depend on a FAKE
		// module standing for an arbitrary file, so the server re-types it when that file changes.
		// Loading it must not leave it as a dependency of whatever is being typed, so the caller's
		// dependency set is restored around the load.
		reg2("registerModuleDependency", "register_module_dependency", function(a) {
			var mpath = strOf(a[0]);
			var file = strOf(a[1]);
			var cur = com.currentModule;
			var oldDeps = cur != null ? cur.extra.deps : null;
			if (cur != null) cur.extra.deps = [for (k => v in oldDeps) k => v];
			var m = typingTimer(com, function() return hxc.context.ModuleLoader.loadModule(com, Ast.parsePath(mpath), curPos));
			if (cur != null) cur.extra.deps = oldDeps;
			TypeFunctions.addDependency(m, createFakeModule(com, file));
			return VNull;
		});
		reg2("getModule", "get_module", function(a) {
			// Context.getModule: type the whole module at the given path and return the list of module
			// types it declares.
			var m = typingTimer(com, function() return hxc.context.ModuleLoader.loadModule(com, Ast.parsePath(strOf(a[0])), curPos));
			return encodeArray([for (mt in m.types) encodeType(ec, TypeFunctions.typeOfModuleType(mt))]);
		});
		reg2("makeMonomorph", "make_monomorph", function(a) return encodeType(ec, TypeFunctions.mkMono()));
		reg2("unify", "unify", function(a) {
			if (curTctx == null) throw new TypingError("unify outside a macro", curPos);
			var t1 = decodeType(ec, a[0]);
			var t2 = decodeType(ec, a[1]);
			var e1 = TypeFunctions.mk(TObjectDecl([]), t1, Position.nullPos);
			var ok = typingTimer(curTctx.com, function() return try {
				Typer.castOrUnifyRaise(curTctx, t2, e1, Position.nullPos);
				true;
			} catch (_:hxc.core.TypingError.CastUnifyError) false, true);
			return ok ? VTrue : VFalse;
		});
		reg2("resolveType", "resolve_type", function(a) {
			if (curTctx == null) throw new TypingError("resolveType outside a macro", curPos);
			var p = posArg(ec, a, 1, curPos);
			var ct = decodeComplexType(ec, a[0], p);
			var t = typingTimer(curTctx.com, function() return Typeload.loadComplexType(curTctx.com, curTctx.typeParams, {ct: ct, pos: p}));
			return encodeType(ec, t);
		});
		// A type that cannot convert (ExitException) answers null.
		reg2("toComplexType", "to_complex_type", function(a) {
			var ct = try typeToComplexType(decodeType(ec, a[0])) catch (_:hxc.core.ExitException) null;
			return ct == null ? VNull : encodeComplexType(ec, {ct: ct, pos: hxc.ast.Position.nullPos});
		});
		reg2("typeToModuleType", "type_to_module_type", function(a) {
			return encodeModuleType(ec, TypeFunctions.moduleTypeOfType(decodeType(ec, a[0])));
		});
		reg2("moduleTypeToType", "module_type_to_type", function(a) {
			return encodeType(ec, TypeFunctions.typeOfModuleType(decodeModuleTypeValue(ec, a[0])));
		});
		reg2("withImports", "with_imports", function(a) {
			var m = com.currentModule;
			if (m == null) throw new TypingError("withImports outside a module", curPos);
			var key = Context.pathKey(m.path);
			var old = com.moduleImports.get(key);
			var next = cloneImports(old);
			// init_import / init_using LOAD each module now, so a missing one is "Type not found" here, not
			// at some later lookup that may never come.
			for (iv in arrOf(a[0])) { var spec = strOf(iv); addImportSpec(next, spec); loadImportModule(com, spec); }
			// init_using for each, and the context_init it fills runs at once.
			for (uv in arrOf(a[1])) {
				var spec = strOf(uv);
				next.usings.push(pathFromDotted(spec));
				next.usingClasses = hxc.filters.ImportCheck.usingClassesOf(hxc.filters.ImportCheck.usingTypes(com, spec.split("."), Position.nullPos), -1).concat(next.usingClasses);
			}
			com.moduleImports.set(key, next);
			try {
				var ret = applyFn(ec, a[2], []);
				restoreImports(com, key, old);
				return ret;
			} catch (e:Dynamic) {
				restoreImports(com, key, old);
				throw e;
			}
		});
		reg2("follow", "follow", function(a) {
			var t = decodeType(ec, a[0]);
			var once = a.length > 1 && a[1] != VNull && boolOf(a[1]);
			return encodeType(ec, once ? TypeFunctions.followOnce(t) : TypeFunctions.follow(t));
		});
		// The once variant also unwraps one non-core abstract layer, and a multi-type abstract resolves to
		// its concrete specialization.
		reg2("followWithAbstracts", "follow_with_abstracts", function(a) {
			var t = decodeType(ec, a[0]);
			var once = a.length > 1 && a[1] != VNull && boolOf(a[1]);
			function underlying(ab:hxc.core.Type.TAbstract, tl:hxc.core.Type.TParams):hxc.core.Type.T {
				if (TypeFunctions.hasMeta(":multiType", ab.meta)) {
					try return hxc.typing.Typer.resolveMultiTypeConcrete(ab, tl, Position.nullPos) catch (e:Dynamic) {}
				}
				return TypeFunctions.getUnderlyingType(ab, tl);
			}
			function fwa(t:hxc.core.Type.T):hxc.core.Type.T {
				return switch (TypeFunctions.follow(t)) {
					case TAbstract(ab, tl) if (!TypeFunctions.hasMeta(":coreType", ab.meta)): fwa(underlying(ab, tl));
					case t2: t2;
				}
			}
			var t1 = if (once) switch (t) {
				case TAbstract(ab, tl) if (!TypeFunctions.hasMeta(":coreType", ab.meta)): underlying(ab, tl);
				case _: TypeFunctions.followOnce(t);
			} else fwa(t);
			return encodeType(ec, t1);
		});
		// The host printer over the decoded type (one print context numbers the unbound monomorphs, an
		// anonymous structure lists its fields in descending name order). A null is a Null Access.
		reg2("s_type", "s_type", function(a) {
			if (a[0] == VNull) throw unexpectedValue(a[0], "enum");
			return mkString(hxc.core.TPrinting.sType(hxc.core.TPrinting.printContext(), decodeType(ec, a[0])));
		});
		reg2("defineType", "define_type", function(a) {
			// A definition the decoder rejects is reported as what was expected against what came back, at
			// the call.
			if (a[0] == VNull) throw decodingError(a[0], "TypeDefinition", "Null Access", curPos);
			defineMacroType(ec, com, a[0], a.length > 1 ? a[1] : VNull);
			return VNull;
		});
		// Context.defineModule(path, types, imports, usings): build the module from decoded type
		// definitions and inject it.
		reg2("defineModule", "define_module", function(a) {
			var parts = strOf(a[0]).split(".");
			var path:hxc.core.Globals.Path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
			var types = [for (tv in arrOf(a[1])) decodeTypeDefinition(ec, tv, Position.nullPos)];
			// The module's position is its first definition's, and the redefinition check reports there.
			var dp = types.length > 0 ? types[0].pos : Position.nullPos;
			var imports = (a.length > 2 && a[2] != VNull) ? [for (iv in arrOf(a[2])) decodeImport(ec, iv, dp)] : [];
			var usings = (a.length > 3 && a[3] != VNull) ? [for (uv in arrOf(a[3])) ({path: decodeTypePath(ec, uv), pos: dp} : PlacedTypePath)] : [];
			var existing = com.moduleLut.get(Context.pathKey(path));
			if (existing != null) {
				// The added classes queue their builds and nothing is forced here.
				var added = hxc.context.ModuleLoader.addTypeDeclsToModule(com, existing, types, imports, usings, dp);
				for (mt in added) switch (mt) {
					case TClassDecl(c):
						var def = com.declOfType.get(Context.pathKey(c.path));
						if (def != null) switch (def.decl) {
							case EClass(d): hxc.typing.TypeResolve.resolveClass(com, c, d, def.pos);
							case _:
						}
					case _:
				}
			} else {
				// Typed against the CALLING module's file, and depending on it, so editing the definer
				// dirties what the macro produced.
				var mdep = com.currentModule;
				var m = hxc.context.ModuleLoader.defineModuleDecls(com, path, types, imports, usings, dp, mdep);
				addMacroTypeDependency(com, m, mdep);
				// As defineType: nothing is forced here.
				hxc.typing.TypeResolve.resolveModule(com, m);
			}
			return VNull;
		});
		// getBuildFields encodes the fields anew on every call: two calls answer two arrays of two sets of
		// objects, and what a macro changes in one is not in the other.
		reg2("getBuildFields", "get_build_fields", function(a)
			return curBuildFields == null ? VNull : encodeArray([for (f in curBuildFields) encodeField(ec, f)]));
		// Context.getLocalType / getLocalClass (std reads TInst from this): the @:build target's type, or
		// outside a build macro the class containing the macro call (none for the null class), with empty
		// params.
		function localClass():Null<TClass> {
			if (curBuildClass != null) return curBuildClass;
			if (curTctx != null && curTctx.curclass != null && curTctx.curclass != TypeFunctions.nullClass) return curTctx.curclass;
			return null;
		}
		reg2("getLocalType", "get_local_type", function(a) {
			if (curBuildType != null) return encodeType(ec, curBuildType);
			var c = localClass();
			return c == null ? VNull : encodeType(ec, TInst(c, []));
		});
		reg2("getLocalClass", "get_local_class", function(a) {
			var c = localClass();
			return c == null ? VNull : encodeClassRef(ec, c);
		});
		regBuiltin(ec, "haxe.macro.Context", "makePosition", function(a) {
			var info = a.length > 0 ? a[0] : VNull;
			return encPos(new Position(strOf(EvalField.field(ec, info, EvalHash.hash("file"))), intOf(EvalField.field(ec, info, EvalHash.hash("min"))), intOf(EvalField.field(ec, info, EvalHash.hash("max")))));
		});
		regBuiltin(ec, "haxe.macro.Context", "make_position", function(a) {
			return encPos(new Position(a.length > 2 ? strOf(a[2]) : "?", a.length > 0 ? intOf(a[0]) : 0, a.length > 1 ? intOf(a[1]) : 0));
		});
		reg2("definedValue", "defined_value", function(a) {
			var k = strOf(a[0]);
			if (!com.defines.rawDefined(k)) return VNull;
			var v = com.defines.rawDefinedValue(k);
			return mkString(v);
		});
		regBuiltin(ec, "haxe.macro.Compiler", "getDefine", function(a) {
			var k = strOf(a[0]);
			var v = com.defines.rawDefined(k) ? mkString(com.defines.rawDefinedValue(k)) : VNull;
			return encodeExpr(ec, valueToExpr(ec, v, curPos));
		});
		reg2("define", "define", function(a) {
			var k = StringTools.replace(strOf(a[0]), "-", "_");
			if (a.length < 2 || a[1] == VNull) com.defines.rawDefine(k);
			else com.defines.rawDefineValue(k, strOf(a[1]));
			return VNull;
		});
		reg2("getConfiguration", "get_configuration", function(a) return getConfigurationValue(com, ec));
		reg2("typePatch", "type_patch", function(a) return typePatchValue(com, a));
		reg2("metaPatch", "meta_patch", function(a) return metaPatchValue(com, a));
		reg2("addGlobalMetadataImpl", "add_global_metadata_impl", function(a) return addGlobalMetadataValue(com, a));
		reg2("server_add_module_check_policy", "server_add_module_check_policy", function(a) {
			var filters = [for (v in arrOf(a[0])) strOf(v)];
			var policy = [for (v in arrOf(a[1])) moduleCheckPolicyOfInt(intOf(v))];
			var recursive = a[2] == VTrue;
			function add(c:Context):Void {
				// The list is folded in order, so the last filter of the call ends up in front.
				for (s in filters) c.moduleCheckPolicies.unshift({filter: s.split("."), policy: policy, recursive: recursive});
				for (m in c.modules) m.extra.checkPolicy = hxc.context.ModuleLoader.getPolicy(c, m.path);
			}
			// ContextOptions: 0 NormalContext, 1 MacroContext, 2 NormalAndMacroContext.
			switch (intOf(a[3])) {
				case 1: if (macroCom != null) add(macroCom);
				case 2: add(com); if (macroCom != null) add(macroCom);
				case _: add(com);
			}
			return VNull;
		});
		// Compiler.registerCustomDefine / registerCustomMetadata store user documentation entries.
		// The arrays are optional string arrays (a null array is empty, a null element a Null Access); a
		// platform and a target are parsed by name, each failure the macro's uncaught exception; the doc is
		// a string (a null a Null Access) and the name decodes last.
		inline function decodeUserDoc(o:EvalValue, src:EvalValue, withTargets:Bool):hxc.context.Context.UserDocEntry {
			function arrField(n:String):Array<String> {
				var v = EvalField.field(ec, o, EvalHash.hash(n));
				return v == VNull ? [] : [for (x in arrOf(v)) strOf(x)];
			}
			var platforms = arrField("platforms");
			for (pl in platforms) if (platformNames.indexOf(pl) < 0) EvalExceptions.excString(ec, "invalid platform " + pl);
			var targets = withTargets ? arrField("targets") : [];
			for (t in targets) if (metadataTargetNames.indexOf(t) < 0) EvalExceptions.excString(ec, "invalid metadata target " + t);
			var params = arrField("params");
			var links = arrField("links");
			var doc = strOf(EvalField.field(ec, o, EvalHash.hash("doc")));
			return {doc: doc, params: params, platforms: platforms, targets: targets, links: links, source: src == VNull ? null : strOf(src)};
		}
		reg2("registerDefineImpl", "register_define_impl", function(a) {
			var entry = decodeUserDoc(a[0], a.length > 1 ? a[1] : VNull, false);
			var name = strOf(EvalField.field(ec, a[0], EvalHash.hash("define")));
			com.userDefines.set(name, entry);
			return VNull;
		});
		reg2("registerMetadataImpl", "register_metadata_impl", function(a) {
			var entry = decodeUserDoc(a[0], a.length > 1 ? a[1] : VNull, true);
			var name = strOf(EvalField.field(ec, a[0], EvalHash.hash("metadata")));
			com.userMetas.set(name, entry);
			return VNull;
		});
		// The name of the method the macro was called from.
		reg2("getLocalMethod", "get_local_method", function(a) {
			return mkString(curTctx != null && curTctx.curfield != null ? curTctx.curfield.name : "null");
		});
		// Context.load(name, nargs): the raw macro-API lookup that std helpers (Compiler.nullSafety,
		// addGlobalMetadata, ...) route through. Every underscore-named Context builtin is a candidate;
		// names only the eval.vm surface serves fall through to callMacroApi.
		regBuiltin(ec, "haxe.macro.Context", "load", function(a) {
			var name = strOf(a[0]);
			var list = ec.builtins.staticBuiltins.get(EvalHash.hash("haxe.macro.Context"));
			if (list != null) {
				var h = EvalHash.hash(name);
				for (b in list) if (b.name == h && name != "load") return b.v;
			}
			return hxc.eval.EvalStdLib.callMacroApiValue(ec, name);
		});
		inline function encodeComMessage(d:hxc.context.Context.CompilerDiagnostic):EvalValue {
			return macroMessage(ec, d.severity.match(Warning) ? "Warning" : "Info", mkString(d.message), encPos(d.pos));
		}
		reg2("getMessages", "get_messages", function(a) {
			return encodeArray([for (d in com.diagnostics) if (!d.severity.match(Error)) encodeComMessage(d)]);
		});
		reg2("filterMessages", "filter_messages", function(a) {
			var pred = a[0];
			com.diagnostics = [for (d in com.diagnostics)
				if (d.severity.match(Error) || EvalMisc.isTrue(applyFn(ec, pred, [encodeComMessage(d)]))) d];
			return VNull;
		});
		reg2("getPosInfos", "get_pos_infos", function(a) return posInfosValue(ec, posArg(ec, a, 0, curPos)));
		// A persistent callback runs before the save state, a non-persistent one after it, so the latter
		// always runs after the former.
		reg2("onGenerate", "on_generate", function(a) {
			(a[1] == VFalse ? onGenerateAfterSaveCallbacks : onGenerateCallbacks).push({ec: ec, fn: prepareCallback(ec, a[0])});
			return VNull;
		});
		// The callback runs at generate time with a JSGenApi bound to a fresh GenJS context, replacing the
		// normal output.
		reg2("setCustomJSGenerator", "set_custom_js_generator", function(a) {
			var fn = a[0];
			// prepareCallback: anything but a function is an invalid expression.
			switch (fn) {
				case VFunction(_, _) | VFieldClosure(_, _):
				case _: return EvalExceptions.excString(ec, "Invalid expression");
			}
			com.jsGen = function() {
				EvalContext.setCtx(ec);
				var dir = haxe.io.Path.directory(com.file);
				if (dir != "" && !sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
				var jsCtx = hxc.generators.GenJS.allocCtx(com, com.getEsVersion());
				hxc.generators.GenJS.setupKwds(com);
				inline function fnv(f:Array<EvalValue>->EvalValue):EvalValue return VFunction(f, true);
				var fields:Map<Int, EvalValue> = new Map();
				fields.set(EvalHash.hash("outputFile"), mkString(com.file));
				fields.set(EvalHash.hash("types"), encodeArray([for (t in com.types) encodeType(ec, TypeFunctions.typeOfModuleType(t))]));
				fields.set(EvalHash.hash("main"), com.main == null ? VNull : encodeTypedExpr(ec, com.main));
				fields.set(EvalHash.hash("generateValue"), fnv(function(a2) {
					return mkString(hxc.generators.GenJS.genSingleExpr(jsCtx, decodeStoredTypedExpr(ec, a2[0]), false));
				}));
				fields.set(EvalHash.hash("generateStatement"), fnv(function(a2) {
					return mkString(hxc.generators.GenJS.genSingleExpr(jsCtx, decodeStoredTypedExpr(ec, a2[0]), true));
				}));
				fields.set(EvalHash.hash("isKeyword"), fnv(function(a2) {
					return hxc.generators.GenJS.isKeyword(strOf(a2[0])) ? VTrue : VFalse;
				}));
				fields.set(EvalHash.hash("hasFeature"), fnv(function(a2) {
					return com.hasFeature(strOf(a2[0])) ? VTrue : VFalse;
				}));
				fields.set(EvalHash.hash("addFeature"), fnv(function(a2) {
					com.addFeature(strOf(a2[0]));
					return VNull;
				}));
				fields.set(EvalHash.hash("quoteString"), fnv(function(a2) {
					return mkString('"' + hxc.core.StringHelper.sEscape(strOf(a2[0])) + '"');
				}));
				fields.set(EvalHash.hash("buildMetaData"), fnv(function(a2) {
					var meta = hxc.core.TexprTools.buildMetadata(com.basic, moduleTypeFromRef(ec, a2[0]));
					return meta == null ? VNull : encodeTypedExpr(ec, meta);
				}));
				fields.set(EvalHash.hash("setTypeAccessor"), fnv(function(a2) {
					var cb = a2[0];
					jsCtx.typeAccessor = function(t:ModuleType):String {
						return strOf(applyFn(ec, cb, [encodeType(ec, TypeFunctions.typeOfModuleType(t))]));
					};
					return VNull;
				}));
				fields.set(EvalHash.hash("setCurrentClass"), fnv(function(a2) {
					switch (moduleTypeFromRef(ec, a2[0])) {
						case TClassDecl(c): jsCtx.current = c;
						case _:
					}
					return VNull;
				}));
				applyFn(ec, fn, [VObject(new VObject([], ODictionary(fields)))]);
			};
			return VNull;
		});
		reg2("onAfterInitMacros", "on_after_init_macros", function(a) {
			onAfterInitMacrosCallbacks.push({ec: ec, fn: prepareCallback(ec, a[0])});
			return VNull;
		});
		reg2("onAfterGenerate", "on_after_generate", function(a) {
			onAfterGenerateCallbacks.push({ec: ec, fn: prepareCallback(ec, a[0])});
			return VNull;
		});
		reg2("onAfterTyping", "on_after_typing", function(a) {
			onAfterTypingCallbacks.push({ec: ec, fn: prepareCallback(ec, a[0])});
			return VNull;
		});
		reg2("getClassPath", "class_path", function(a) {
			var vals:Array<EvalValue> = [for (cp in com.classPath) mkString(cp)];
			return VArray(new VArray(vals, vals.length));
		});
		reg2("getOutput", "get_output", function(a) return mkString(com.file));
		reg2("setOutput", "set_output", function(a) { com.file = strOf(a[0]); return VNull; });
		reg2("positionToRange", "position_to_range", function(a) {
			var p = posOf(ec, a[0], curPos);
			var infos = hxc.ast.Position.getInfos(p);
			function obj(fields:Array<{name:String, value:EvalValue}>):EvalValue {
				var m:Map<Int, EvalValue> = new Map();
				for (f in fields) m.set(EvalHash.hash(f.name), f.value);
				return VObject(new VObject([], ODictionary(m)));
			}
			function mkP(line:Int, character:Int):EvalValue
				return obj([{name: "line", value: VInt(line)}, {name: "character", value: VInt(character)}]);
			return obj([
				{name: "file", value: mkString(p.file)},
				{name: "range", value: obj([
					{name: "start", value: mkP(infos.line, infos.column + 1)},
					{name: "end", value: mkP(infos.endLine, infos.endColumn + 1)}
				])}
			]);
		});
		// eval.vm.Context.callMacroApi("<snake>") returns the builtin registered under that
		// key; names only the eval-std surface serves (resolve_path, add_resource, ...)
		// fall through to its switch, which throws its own not-implemented.
		regBuiltin(ec, "eval.vm.Context", "callMacroApi", function(a) {
			var name = strOf(a[0]);
			var key = EvalHash.hash(name);
			var list = ec.builtins.staticBuiltins.get(EvalHash.hash("haxe.macro.Context"));
			if (list != null) for (e in list) if (e.name == key) return e.v;
			return hxc.eval.EvalStdLib.callMacroApiValue(ec, name);
		});
	}

	static function createFakeModule(com:Context, file:String):ModuleDef {
		// A path whose full path cannot be resolved stays as it is, and a failing stat is swallowed;
		// hxcpp's fullPath and stat fail fast on an empty path instead of throwing.
		var full = file == "" ? file : (try sys.FileSystem.fullPath(file) catch (_:Dynamic) file);
		var key = StringTools.replace(full, "\\", "/").toLowerCase();
		var mdep = fakeModules.get(key);
		if (mdep == null) {
			var time = full == "" ? 0.0 : (try sys.FileSystem.stat(full).mtime.getTime() / 1000.0 catch (_:Dynamic) 0.0);
			mdep = {
				id: TypeFunctions.allocMid(),
				path: {pack: ["$DEP"], name: full},
				types: [],
				statics: null,
				extra: TypeFunctions.moduleExtra(full, com.defines.getSignature(), time, MFake, [])
			};
			fakeModules.set(key, mdep);
		}
		com.moduleLut.set(hxc.context.Context.pathKey(mdep.path), mdep);
		return mdep;
	}

	static function cloneImports(old:Null<hxc.context.Context.ModuleImports>):hxc.context.Context.ModuleImports {
		var names = new haxe.ds.StringMap<hxc.context.Context.ImportedName>();
		var globals = new haxe.ds.StringMap<hxc.context.Context.ImportedGlobal>();
		if (old != null) {
			for (key in old.names.keys()) names.set(key, old.names.get(key));
			for (key in old.globals.keys()) globals.set(key, old.globals.get(key));
		}
		var next = new hxc.context.Context.ModuleImports(names, old == null ? [] : old.wildcards.copy(), old == null ? [] : old.usings.copy(), globals, old == null ? [] : old.rawImports.copy());
		if (old != null) next.usingClasses = old.usingClasses.copy();
		return next;
	}

	static function restoreImports(com:Context, key:String, old:Null<hxc.context.Context.ModuleImports>):Void {
		if (old == null) com.moduleImports.remove(key) else com.moduleImports.set(key, old);
	}

	static function pathFromDotted(s:String):hxc.core.Globals.Path {
		var parts = s.split(".");
		return {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
	}

	static function defineMacroType(ec:EvalContext, com:Context, v:EvalValue, moduleDependency:EvalValue):Void {
		var dp = posOf(ec, EvalField.field(ec, v, EvalHash.hash("pos")), curPos);
		var path = macroTypeDefinitionPath(ec, v);
		var td = decodeTypeDefinition(ec, v, dp);
		var hasMacroFields = isMacroClassDecl(td.decl);
		var hostDep = macroTypeDep(com, moduleDependency, dp, com.currentModule);
		// The module-types check reports at the position the definition carries (defineType passes the API
		// call's); the loader raises it without one.
		var hostModule = try hxc.context.ModuleLoader.defineTypeDecl(com, path, td.decl, td.pos, hostDep)
			catch (e:hxc.context.Context.ContextError) { throw new TypingError(e.message, curPos); };
		hostModule.extra.kind = MFake;
		addMacroTypeDependency(com, hostModule, hostDep);
		// defineType types the module: its classes queue their builds and nothing is forced here.
		hxc.typing.TypeResolve.resolveModule(com, hostModule);

		if (!com.isMacro && hasMacroFields) {
			if (macroCom == null) {
				macroCom = com.cloneForMacro();
				hxc.context.ModuleLoader.attach(macroCom);
				hxc.context.ModuleLoader.initBasicTypes(macroCom);
			}
			var macroTd = decodeTypeDefinition(ec, v, dp);
			var macroDep = macroTypeDep(macroCom, moduleDependency, dp, macroCurModule);
			var macroModule = hxc.context.ModuleLoader.defineTypeDecl(macroCom, path, macroTd.decl, macroTd.pos, macroDep);
			macroModule.extra.kind = MMacro;
			addMacroTypeDependency(macroCom, macroModule, macroDep);
			hxc.typing.TypeResolve.resolveModule(macroCom, macroModule);
		}
	}

	// The module a macro-created one is attributed to and depends on: the named one, else the current
	// module. Resolved before the definition, because the definition types against this module's file.
	static function macroTypeDep(com:Context, moduleDependency:EvalValue, p:Position, curmod:Null<ModuleDef>):ModuleDef {
		if (moduleDependency != VNull)
			return hxc.context.ModuleLoader.loadModule(com, pathFromDotted(strOf(moduleDependency)), p);
		return curmod != null ? curmod : TypeFunctions.nullModule;
	}

	static function addMacroTypeDependency(com:Context, m:ModuleDef, mdep:Null<ModuleDef>):Void {
		if (mdep != null) TypeFunctions.addDependency(m, mdep);
	}

	static function macroTypeDefinitionPath(ec:EvalContext, v:EvalValue):hxc.core.Globals.Path {
		var pack = [for (pv in arrOf(EvalField.field(ec, v, EvalHash.hash("pack")))) strOf(pv)];
		var name = strOf(EvalField.field(ec, v, EvalHash.hash("name")));
		if (pack.length > 0) {
			var last = pack[pack.length - 1];
			if (startsUppercaseIdentifier(last)) {
				pack = pack.slice(0, pack.length - 1);
				name = last;
			}
		}
		return {pack: pack, name: name};
	}

	static function startsUppercaseIdentifier(s:String):Bool {
		if (s.length == 0) return false;
		var c = s.charCodeAt(0);
		return c >= "A".code && c <= "Z".code;
	}

	static function isMacroClassDecl(td:TypeDef):Bool {
		return switch (td) {
			case EClass(d):
				for (f in d.dData) {
					for (m in f.cffMeta) if (m.name == ":macro") return true;
					for (a in f.cffAccess) if (a.access == AMacro) return true;
				}
				false;
			case _:
				false;
		}
	}

	static function forceModuleClassFields(com:Context, m:ModuleDef):Void {
		for (mt in m.types) switch (mt) {
			case TClassDecl(c):
				hxc.typing.TypeFields.forceClassFields(com, c);
			case _:
		}
	}

	static function splitImportPath(parts:Array<String>):Null<{modulePath:hxc.core.Globals.Path, sub:Null<String>, field:Null<String>}> {
		var pack:Array<String> = [];
		var i = 0;
		while (i < parts.length) {
			var c = parts[i].charCodeAt(0);
			if (c >= "A".code && c <= "Z".code) break;
			pack.push(parts[i]);
			i++;
		}
		if (i >= parts.length) return null;
		var moduleName = parts[i++];
		var sub:Null<String> = null;
		var field:Null<String> = null;
		if (i < parts.length) {
			var c2 = parts[i].charCodeAt(0);
			if (c2 >= "A".code && c2 <= "Z".code) {
				sub = parts[i++];
				if (i < parts.length) field = parts[i];
			} else {
				field = parts[i];
			}
		}
		return {modulePath: {pack: pack, name: moduleName}, sub: sub, field: field};
	}

	// The module an import or using names: the dotted path up to its first capitalised segment
	// (`a.b.C.d` and `a.b.C as X` both load a.b.C); a package wildcard loads nothing.
	static function loadImportModule(com:Context, raw:String):Void {
		var head = raw.split(" ")[0];
		var parts = head.split(".");
		var pack = [];
		for (seg in parts) {
			if (seg == "*" || seg == "") return;
			var c = seg.charCodeAt(0);
			if (c >= "A".code && c <= "Z".code) {
				hxc.context.ModuleLoader.loadModule(com, {pack: pack, name: seg}, Position.nullPos);
				return;
			}
			pack.push(seg);
		}
	}

	static function addImportSpec(imports:hxc.context.Context.ModuleImports, raw:String):Void {
		var spec = StringTools.trim(raw);
		var alias:Null<String> = null;
		var asIndex = spec.indexOf(" as ");
		if (asIndex >= 0) {
			alias = StringTools.trim(spec.substr(asIndex + 4));
			spec = StringTools.trim(spec.substr(0, asIndex));
		}
		if (StringTools.endsWith(spec, ".*")) {
			var wparts = spec.substr(0, spec.length - 2).split(".");
			var wsplit = splitImportPath(wparts);
			if (wsplit == null) {
				imports.wildcards.push(pathFromDotted(spec.substr(0, spec.length - 2)));
				return;
			}
			var com = currentCompiler();
			var mt = try com.getType(wsplit.modulePath, hxc.ast.Position.nullPos, wsplit.sub) catch (_:Dynamic) null;
			if (mt != null) switch (TypeFunctions.resolveTypedef(mt)) {
				case TClassDecl(cl) | TAbstractDecl({impl: cl}) if (cl != null):
					for (cf in cl.orderedStatics)
						if (!TypeFunctions.hasMeta(":noImportGlobal", cf.meta))
							imports.globals.set(cf.name, {ownerPath: wsplit.modulePath, ownerSub: wsplit.sub, field: cf.name});
				case TEnumDecl(en):
					for (name in en.names)
						if (!TypeFunctions.hasMeta(":noImportGlobal", en.constrs.get(name).meta))
							imports.globals.set(name, {ownerPath: wsplit.modulePath, ownerSub: wsplit.sub, field: name});
				case _:
			}
			return;
		}
		var split = splitImportPath(spec.split("."));
		if (split == null) return;
		if (split.field != null) {
			imports.globals.set(alias == null ? split.field : alias, {ownerPath: split.modulePath, ownerSub: split.sub, field: split.field});
		} else {
			imports.names.set(alias == null ? (split.sub == null ? split.modulePath.name : split.sub) : alias, {modulePath: split.modulePath, sub: split.sub});
		}
	}


	public static function runBuildMacros(com:Context):Void {
		// Build macros trigger through delays which run newest-first, so the last registered class builds
		// first; dependency order is still guaranteed by ensureBuilt's super/interface recursion. A build
		// can load more modules, so sweep to a fixed point (builtClasses keeps revisits cheap).
		var done = -1;
		while (com.modules.length != done) {
			done = com.modules.length;
			var mi = done - 1;
			while (mi >= 0) {
				var types = com.modules[mi].types;
				var ti = types.length - 1;
				while (ti >= 0) {
					switch (types[ti]) {
						case TClassDecl(c):
							try ensureBuilt(com, c) catch (e:TypingError) {
								// The pass runner catches nothing, so a build's error ends the compile. The
								// macro world's finalize hands it to the macro load's caller instead.
								if (com.isMacro) throw e;
								if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null) Sys.println("[buildfatal] " + Context.sTypePath(c.path));
								throw new hxc.core.TypingError.FatalError(e.message, e.pos, e.depth);
							}
						case _:
					}
					ti--;
				}
				mi--;
			}
		}
	}

	// Runs a class's build macros the first time the class is resolved: its own @:build plus any
	// @:autoBuild inherited from a superclass or implemented interface.
	// The build macros precede the field checks: a class whose build has not run yet has no final field
	// list to check.
	public static function hasPendingBuild(com:Context, c:TClass):Bool {
		var key = (com.isMacro ? "macro:" : "") + c.path.pack.join(".") + "." + c.path.name;
		return !builtClasses.exists(key) && collectBuildEntries(c).length > 0;
	}

	// Asking for a class's build macros is asking for its build, which is a no-op while that build runs and
	// once it ran.
	public static function ensureBuilt(com:Context, c:TClass):Void {
		if (!hxc.typing.TypeFields.buildStarted(c)) hxc.typing.TypeFields.buildClass(com, c);
	}

	// The build macros, run by the class's own build (TypeFields.buildClass) after its heritage is set.
	public static function runClassBuildMacros(com:Context, c:TClass):Void {
		// Per world: the built mark is on the class object, and the macro context holds its own copy of
		// every class. Keyed by path alone, a class the host had built would be skipped in the macro
		// world and its @:build would never run.
		var key = (com.isMacro ? "macro:" : "") + c.path.pack.join(".") + "." + c.path.name;
		if (builtClasses.exists(key)) return;
		hxc.typing.TypeResolve.forceQueuedBuild(c);
		// The super chain and interfaces build first so a child's build macro sees the parent's macro-added
		// fields.
		if (c.superClass != null) ensureBuilt(com, c.superClass.c);
		for (i in c.interfaces) ensureBuilt(com, i.c);
		// Marked before the entry check, not after: a class counts as built once it is built, whether or
		// not any @:build ran, so a second call is a no-op. Recording only the classes that HAD entries
		// would leave every ordinary class unmarked, so each construction of one would re-walk its entire
		// super and interface chain.
		builtClasses.set(key, true);
		var entries = collectBuildEntries(c);
		if (entries.length == 0) return;
		// A build's failure is RAISED out of the class build before any field is added, so the class is
		// left with none. It goes to whoever FORCED the build: the PBuildClass pass runner (which has no
		// handler, so the compile ends with it, after everything recorded so far) or an expression that
		// needed the class, whose own handlers record it and type on against the fieldless class.
		// runBuildMacros is the pass runner here.
		function fail(message:String, pos:Position, ?src:TypingError):Void {
			if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null)
				Sys.println("[buildraise] " + Context.sTypePath(c.path) + (com.isMacro ? " (macro): " : ": ") + message);
			c.fields = new haxe.ds.StringMap();
			c.statics = new haxe.ds.StringMap();
			c.orderedFields = [];
			c.orderedStatics = [];
			c.constructor = null;
			// The KIND leaves with it: a macro module that did not load is Module_not_found, which from the
			// argument annotation.
			if (src != null && Std.isOfType(src, hxc.core.TypingError.ModuleNotFoundError))
				throw new hxc.core.TypingError.ModuleNotFoundError(message, pos);
			throw new TypingError(message, pos);
		}
		// While the build macros run, the class's build state is BuildMacro pending; what a caller adds
		// there runs once they finish, and not after a raise.
		buildMacroPendings.set(c, []);
		try runBuildEntries(com, c, entries, fail) catch (e:Dynamic) {
			buildMacroPendings.remove(c);
			throw e;
		}
		var pending = buildMacroPendings.get(c);
		buildMacroPendings.remove(c);
		for (f in pending) f();
		// An enum abstract's rewrite runs after every @:build, over the fields they left.
		// TypeResolve.resolveModule left it for here.
		switch (c.kind) {
			case KAbstractImpl(a) if (a.isEnum): hxc.typing.TypeResolve.buildEnumAbstractAfterBuild(com, a);
			case _:
		}
		// Class initialization goes on past its build; a build that re-resolved the class already went
		// through it.
		hxc.typing.TypeResolve.initClassTail(com, c);
	}

	static var buildMacroPendings = new haxe.ds.ObjectMap<TClass, Array<Void->Void>>();

	/**
	 * The BuildMacro pending list of a class whose build macros are running, else null.
	 */
	public static function buildMacroPending(c:TClass):Null<Array<Void->Void>>
		return buildMacroPendings.get(c);

	static function runBuildEntries(com:Context, c:TClass, entries:Array<MetadataEntry>, fail:(String, Position, ?TypingError) -> Void):Void {
		for (entry in entries) try runBuild(com, c, entry) catch (e:TypingError) {
			fail(e.message, e.pos != null && e.pos != Position.nullPos ? e.pos : entry.pos, e);
		} catch (e:hxc.context.Context.ContextError) {
			// What applying the macro raises - the macro module's missing-module error among it - is
			// re-raised as it is; only a macro that answered nothing is Build failure.
			fail(e.message, e.pos != null && e.pos != Position.nullPos ? e.pos : entry.pos);
		} catch (e:EvalExceptions.EvalRunTimeException) {
			var info = runtimeMacroError(e);
			if (info != null) {
				// Context.error makes the macro RETURN NOTHING, which is the reference's own "Build
				// failure" case a raw throw never gets there.
				com.addDiagnostic(info.message, info.pos);
				fail("Build failure", new Position(entry.pos.file, entry.pos.min, entry.pos.min + 7));
			}
			else {
				// An UNCAUGHT exception reports at the throwing expression with the call chain under it. The
				// @:build metadata is the call site here, and the build path invokes the macro directly, so it
				// is not among the positions the unwind recorded. The chain is one error in the reference, and
				// its last line is the one that ends the compile.
				var stack = uncaughtExceptionStack(e);
				var last = stack[stack.length - 1];
				if (last.pos == null || last.pos.file != entry.pos.file || last.pos.min != entry.pos.min)
					stack.push({message: "Called from here", pos: entry.pos});
				var tail = stack.pop();
				if (stack.length > 0) com.addDiagnosticStack(stack);
				fail(tail.message, tail.pos);
			}
		} catch (e:hxc.core.TypingError.FatalError) {
			throw e;
		} catch (e:haxe.Exception) {
			if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null)
				Sys.println("[buildfail] " + Type.getClassName(Type.getClass(e)) + ": " + e.message);
			// Whatever applying the macro raises is re-raised; "Build failure" is only the macro that
			// answered nothing. A Sys.exit and a host exception out of a native go on up.
			if (Std.isOfType(e, EvalExceptions.EvalSysExit) || Std.isOfType(e, EvalExceptions.HostException)) throw e;
			fail("Build failure", new Position(entry.pos.file, entry.pos.min, entry.pos.min + 7));
		}
	}

	static function collectBuildEntries(c:TClass):Array<MetadataEntry> {
		return [for (m in c.meta) if (m.name == ":build") m];
	}

	static function findMeta(meta:Metadata, name:String):Null<MetadataEntry> {
		for (e in meta) if (e.name == name) return e;
		return null;
	}

	static function runBuild(com:Context, c:TClass, entry:MetadataEntry):Void {
		runBuildInner(com, c, entry);
	}

	// The part of a type's build that does not care what kind of type is being built: check the metadata
	// shape, load the macro's own module, run it in build mode and decode the Array<Field> it answers with.
	// Null means the macro returned null, which means "keep the fields you were given".
	// A decoding failure's report goes to <dump>/decoding_error.txt (the dump path defaults to "dump") and
	// the error names the expected type and the value's string form.
	static function decodingError(v:EvalValue, expected:String, detail:String, p:Position):TypingError {
		var path = "dump/decoding_error";
		try {
			if (!sys.FileSystem.exists("dump")) sys.FileSystem.createDirectory("dump");
			sys.io.File.saveContent(path + ".txt", "Expected " + expected + "\n" + detail + "\nline 1: " + EvalStdLib.stringOf(v));
		} catch (_:Dynamic) {}
		return new TypingError("Expected " + expected + " but got " + EvalStdLib.stringOf(v) + " (see " + path + ".txt for details)", p);
	}

	static function callBuildMacro(com:Context, entry:MetadataEntry, modul:ModuleDef, cls:Null<TClass>, selfType:T, params:TParams,
			typeParams:TypeParams, fields:Array<ClassField>, namePos:Position):Null<Array<ClassField>> {
		// The argument has to be exactly one call, and both complaints here point at the METADATA rather
		// than at whatever was written inside it.
		var callIsWellFormed = entry.params.length == 1 && entry.params[0].expr.match(ECall(_, _));
		if (!callIsWellFormed) throw new TypingError("Invalid build parameters", entry.pos);
		// The callee has to be a dotted identifier chain, and it is checked before the macro-context test
		// below: the path conversion raises at the expression that is not one, and the build names it
		// there.
		switch (entry.params[0].expr) {
			case ECall(callee, _):
				try hxc.ast.Ast.stringListOfExprPathRaise(callee) catch (_:Dynamic)
					throw new TypingError("Build call parameter must be a class path", callee.pos);
			case _:
		}
		// A @:build on a type the MACRO context loads cannot run: the macro would have to be interpreted
		// while it is itself being compiled. This is reached when the built type shares a module with the
		// macro function that builds it. Raised while the macro context builds the class, it leaves the
		// macro world the way a fatal error out of finalization does: reported, and the compile ends
		// there. It is RAISED out of the macro world's class build; who catches it decides the rest. A
		// macro call that loaded the class records it and types on (a second call then meets the method
		// missing from the failed build); a field force lets it end the compile.
		if (com.isMacro)
			throw new TypingError("You cannot use @:build inside a macro : make sure that your type is not used in macro", entry.pos);
		var callExpr = entry.params[0];
		// A macro path is split on "." and needs at least `Type.method`; a bare
		// `foo()` has no type to look the method up on.
		switch (callExpr.expr) {
			case ECall(callee, _) if (macroTarget(callee) == null):
				throw new TypingError("Invalid macro path", entry.pos);
			case _:
		}
		// The module's init runs before the build macro is applied.
		com.contextInitRun(modul);
		// Load the macro's own module into the macro world so the interpreter includes it.
		switch (callExpr.expr) {
			case ECall(callee, _):
				var t = macroTarget(callee);
				if (t != null) {
					var targetPath:hxc.core.Globals.Path = {pack: t.pack, name: t.name};
					var targetModule = com.typeToModule.get(Context.pathKey(targetPath));
					loadMacro(com, {pack: t.pack, name: t.module}, t.method, targetModule, modul, entry.pos, false, t.name != t.module ? t.name : null);
				}
			case _:
		}
		var ec = getContext(com);
		var savedBuildClass = curBuildClass;
		var savedBuildType = curBuildType;
		var savedBuildParams = curBuildParams;
		var savedBuildFields = curBuildFields;
		var savedTctx = curTctx;
		var savedPos = curPos;
		var savedMod = com.currentModule;
		function restore():Void {
			curBuildClass = savedBuildClass;
			curBuildType = savedBuildType;
			curBuildParams = savedBuildParams;
			curBuildFields = savedBuildFields;
		}
		try {
			var buildTctx = new TyperContext(com);
			if (cls != null) buildTctx.curclass = cls;
			buildTctx.typeParams = typeParams;
			buildTctx.tthis = selfType;
			com.currentModule = modul;
			curTctx = buildTctx;
			// Context.currentPos() in a build macro is the @:build meta's own position, not
			// the inner call.
			curPos = entry.pos;
			curBuildClass = cls;
			curBuildType = selfType;
			curBuildParams = params;
			curBuildFields = fields;
			var result = switch (callExpr.expr) {
				case ECall(callee, args):
					var target = macroTarget(callee);
					var targetPath:Null<hxc.core.Globals.Path> = target == null ? null : {pack: target.pack, name: target.name};
					var targetModule = targetPath == null ? null : com.typeToModule.get(Context.pathKey(targetPath));
					var cf = target == null ? null : macroWorldField(targetPath, target.method, targetModule);
					var sig = cf == null ? null : switch (TypeFunctions.follow(cf.type)) { case TFun(s): s; case _: null; };
					// The macro's DECLARED return is unified against what the mode expects, at the macro
					// field's own position: Array<haxe.macro.Expr.Field> for a @:build. Without it a macro
					// returning something else would fail later, or silently.
					if (sig != null && cf != null) {
						var fieldsT = try hxc.typing.Typeload.loadInstance(macroCom, [],
							{tpackage: [], tname: "Array", tsub: null, tparams: [TPType({ct: CTPath({tpackage: ["haxe", "macro"], tname: "Expr", tsub: "Field", tparams: []}), pos: cf.pos})]},
							cf.pos, false) catch (_:Dynamic) null;
						if (fieldsT != null) try hxc.core.TypeUnification.unifyDefault(sig.ret, fieldsT)
							catch (ue:hxc.core.TypeUnification.UnifyError) {
								com.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(ue.errors), cf.pos);
								// The interpreter answers nothing once an error has been displayed, and
								// nothing is "Build failure" at the metadata: the macro is not run.
								throw new TypingError("Build failure", entry.pos);
							}
					}
					var values = macroArgs(ec, args, sig == null ? null : sig.args);
					if (sig != null) while (values.length < sig.args.length) values.push(VNull);
					var result = callMacroFn(com, ec, callee, entry.pos, values, entry.pos);
					result;
				case _: throw new TypingError("@:build requires a macro call", callExpr.pos);
			};
			curTctx = savedTctx;
			curPos = savedPos;
			com.currentModule = savedMod;
			if (result == VNull) {
				restore();
				return null;
			}
			// A result the decoder rejects is reported as what was expected against what came back, at the
			// metadata, with the decoding report written to dump/decoding_error.txt. The decoder's own
			// complaints are plain strings.
			var newFields = try [for (fv in arrOf(result)) decodeField(ec, fv, namePos)] catch (d:DecodeFailure) {
				throw decodingError(result, "Array<Field>", d.text, entry.pos);
			};
			// A `macro` function in a class build's result, for a class the macro context has already
			// compiled (its path is in that world's type table), is refused at the build unless a macro of
			// that name stood in the fields the build started from: such a macro is assumed unchanged by the
			// @:build.
			if (cls != null && macroCom != null && macroCom.typeToModule.exists(Context.pathKey(cls.path))) {
				inline function isMacroField(f:ClassField):Bool {
					var r = false;
					for (a in f.cffAccess) if (a.access == AMacro) r = true;
					return r;
				}
				// The names compare as PLACED names, position included: only a
				// macro the build handed back as it stood matches, not one it re-created at its own
				// position under a name the class already had.
				for (nf in newFields) if (isMacroField(nf)) {
					var had = false;
					for (f in fields) if (f.cffName.name == nf.cffName.name && f.cffName.pos.file == nf.cffName.pos.file
							&& f.cffName.pos.min == nf.cffName.pos.min && f.cffName.pos.max == nf.cffName.pos.max && isMacroField(f)) had = true;
					if (!had) throw new TypingError("Class build macro cannot return a macro function when the class has already been compiled into the macro context", entry.pos);
				}
			}
			restore();
			return newFields;
		} catch (e:haxe.Exception) {
			restore();
			curTctx = savedTctx;
			curPos = savedPos;
			com.currentModule = savedMod;
			throw e;
		}
	}

	// An uncaught macro-time exception reports at the throwing expression with a "Called from here" frame
	// per enclosing call, innermost first, closing with the invocation's entry environment, whose leave
	// position is the call; a nested invocation's chain runs on into its caller's frames the same way.
	public static function uncaughtExceptionStack(re:EvalExceptions.EvalRunTimeException):Array<{message:String, pos:Position, ?depth:Int}> {
		var frames = [for (env in re.envStack) hxc.eval.EvalExceptions.envPosition(env)];
		// Only a frame at the null position is dropped; a fresh environment's (0,0) prints as line 1.
		frames = [for (p in frames) if (p != null && !hxc.eval.EvalExceptions.isNullPos(p)) p];
		var explicit = re.pos != null && !(re.pos.file == "?" && re.pos.min < 0);
		if (explicit && frames.length > 0) frames.shift();
		// A raise with no position of its own - an API native's failure, an invalid expression, a Null
		// Access - heads its report at the position the catcher passes, the macro invocation, the same one
		// that closes the "Called from here" chain.
		var invocation = re.callPositions.length > 0 ? re.callPositions[re.callPositions.length - 1] : null;
		var head = explicit ? re.pos : (invocation != null && invocation.file != "?" && invocation.min >= 0 ? invocation : Position.nullPos);
		var stack = [{message: "Uncaught exception " + EvalStdLib.stringOf(re.value), pos: head}];
		for (p in frames) stack.push({message: "Called from here", pos: p});
		return stack;
	}

	static function runBuildInner(com:Context, c:TClass, entry:MetadataEntry):Void {
		var declEntry = com.declOfType.get(Context.pathKey(c.path));
		if (declEntry == null) return;
		var d = switch (declEntry.decl) { case EClass(dd): dd; case _: return; };
		var newFields = callBuildMacro(com, entry, c.module, c, TInst(c, TypeFunctions.extractParamTypes(c.params)),
			TypeFunctions.extractParamTypes(c.params), c.params, d.dData, d.dName.pos);
		if (newFields == null) return;
		// Every field a class build returns is transformed again; for an abstract's implementation the
		// header is resolved by now, so a constructor's `this` and return are written from it.
		switch (c.kind) {
			case KAbstractImpl(a):
				var hints = try {
					aT: hxc.core.TexprToExpr.convertTypeHint(TAbstract(a, [for (tp in a.params) tp.type])),
					thisT: hxc.core.TexprToExpr.convertTypeHint(a.thisType)
				} catch (_:hxc.core.ExitException) null;
				if (hints != null)
					newFields = [for (f in newFields) hxc.context.ModuleLoader.transformAbstractField(hints.thisT, hints.aT, a, f, com)];
			case _:
		}
		var newDef:Definition<ClassFlag, Array<ClassField>> = {dName: d.dName, dDoc: d.dDoc, dParams: d.dParams, dMeta: d.dMeta, dFlags: d.dFlags, dData: newFields};
		com.declOfType.set(Context.pathKey(c.path), {decl: EClass(newDef), pos: declEntry.pos});
		// The FINAL field list is checked, the build's included (a duplicate name, a variable without hint
		// or value, an accessor name, a modifier): with the com, the registration reports them for what the
		// macro returned.
		hxc.context.ModuleLoader.rebuildFields(c, newFields, com);
		// Resolve the rewritten fields in the class's own module so its private sibling types (e.g. a
		// private typedef used in a field signature) resolve; a build triggered from another module's
		// typing (new C() -> ensureBuilt) would otherwise carry the caller's currentModule.
		var savedResolveMod = com.currentModule;
		com.currentModule = c.module;
		// The build macro rewrites fields only; the class heritage is already resolved, so re-resolve
		// just the field signatures (resolveClass would re-process extends and reject the set super).
		hxc.typing.TypeResolve.resolveClassFields(com, c, newDef, declEntry.pos);
		com.currentModule = savedResolveMod;
	}

	// An enum's constructors are shown to a build macro as ordinary fields, so a no-argument constructor
	// without type parameters reads as a var and every other one reads as a body-less function.
	static function enumConstructsAsFields(constructs:Array<EnumConstructor>):Array<ClassField> {
		return [
			for (c in constructs)
				new ClassField(c.ecName, c.ecDoc, c.ecPos, c.ecMeta, [], if (c.ecArgs.length == 0 && c.ecParams.length == 0) {
					FVar(c.ecType, null);
				} else {
					FFun({
						fParams: c.ecParams,
						fType: c.ecType,
						fExpr: null,
						fArgs: [for (a in c.ecArgs) ({name: {name: a.name, pos: Position.nullPos}, opt: a.opt, meta: [], type: a.type, value: null} : FunctionArg)]
					});
				})
		];
	}

	// The other direction: what the macro answered with, read back as enum constructors. A constructor may
	// only be a var or a function with no body (or an empty block).
	static function fieldsAsEnumConstructs(fields:Array<ClassField>, p:Position):Array<EnumConstructor> {
		return [
			for (f in fields) {
				var args:Array<{name:String, opt:Bool, type:TypeHint}> = [];
				var params:Array<TypeParam> = [];
				var t:Null<TypeHint> = null;
				switch (f.cffKind) {
					case FVar(vt, null):
						t = vt;
					case FFun(fd) if (fd.fExpr == null || fd.fExpr.expr.match(EBlock([]))):
						args = [
							for (a in fd.fArgs) {
								if (a.type == null) throw new TypingError("Missing function parameter type", f.cffPos);
								{name: a.name.name, opt: a.opt, type: a.type};
							}
						];
						params = fd.fParams;
						t = fd.fType;
					case _:
						throw new TypingError("Invalid enum constructor in @:build result", p);
				}
				({
					ecName: f.cffName,
					ecDoc: f.cffDoc,
					ecMeta: f.cffMeta,
					ecPos: f.cffPos,
					ecArgs: args,
					ecParams: params,
					ecType: t
				} : EnumConstructor);
			}
		];
	}

	// The build of an enum. TypeResolve.resolveEnum calls this before it walks the constructors, which is
	// where they are replaced too.
	public static function runEnumBuild(com:Context, e:TEnum, d:Definition<EnumFlag, Array<EnumConstructor>>):Void {
		var entries = [for (m in e.meta) if (m.name == ":build") m];
		if (entries.length == 0) return;
		var params = TypeFunctions.extractParamTypes(e.params);
		// The enum's build runs at module init and its failure is RAISED out of it, so the module's load
		// ends there for whoever loaded it.
		function fail(message:String, pos:Position):Void {
			if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null)
				Sys.println("[buildraise:enum] " + Context.sTypePath(e.path) + ": " + message);
			throw new TypingError(message, pos);
		}
		for (entry in entries) try {
			var newFields = callBuildMacro(com, entry, e.module, null, TEnum(e, params), params, e.params,
				enumConstructsAsFields(d.dData), d.dName.pos);
			if (newFields == null) continue;
			d.dData = fieldsAsEnumConstructs(newFields, entry.pos);
		} catch (ex:TypingError) {
			fail(ex.message, ex.pos != null && ex.pos != Position.nullPos ? ex.pos : entry.pos);
		} catch (ex:EvalExceptions.EvalRunTimeException) {
			var info = runtimeMacroError(ex);
			if (info != null) {
				// Context.error makes the macro RETURN NOTHING, which is the reference's own "Build
				// failure" case a raw throw never gets there.
				com.addDiagnostic(info.message, info.pos);
				fail("Build failure", new Position(entry.pos.file, entry.pos.min, entry.pos.min + 7));
			}
			else {
				// The @:build metadata is the call site here, and the build path invokes the macro directly, so
				// it is not among the positions the unwind recorded. The chain is one error in the reference,
				// and its last line is what leaves the build.
				var stack = uncaughtExceptionStack(ex);
				var last = stack[stack.length - 1];
				if (last.pos == null || last.pos.file != entry.pos.file || last.pos.min != entry.pos.min)
					stack.push({message: "Called from here", pos: entry.pos});
				var tail = stack.pop();
				if (stack.length > 0) com.addDiagnosticStack(stack);
				fail(tail.message, tail.pos);
			}
		} catch (ex:hxc.core.TypingError.FatalError) {
			throw ex;
		} catch (ex:haxe.Exception) {
			if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null)
				Sys.println("[buildfail:enum] " + Type.getClassName(Type.getClass(ex)) + ": " + ex.message);
			fail("Build failure", new Position(entry.pos.file, entry.pos.min, entry.pos.min + 7));
		}
	}

	static function flattenExprPath(e:Expr):Null<Array<String>> {
		return switch (e.expr) {
			case EConst(CIdent(s)): [s];
			case EField(e1, f, _): var pre = flattenExprPath(e1); pre == null ? null : pre.concat([f]);
			case _: null;
		};
	}

	// The first capitalized segment is the module; the last segment before the method is the class (a
	// Module.SubType.method path addresses a secondary module type).
	static function macroTarget(callee:Expr):Null<{pack:Array<String>, module:String, name:String, method:String, moduleOnly:Bool}> {
		var segs = flattenExprPath(callee);
		if (segs == null || segs.length < 2) return null;
		var typeSegs = segs.slice(0, segs.length - 1);
		var typeIdx = -1;
		for (i in 0...typeSegs.length) {
			var ch = typeSegs[i].charCodeAt(0);
			if (ch >= "A".code && ch <= "Z".code) { typeIdx = i; break; }
		}
		// The segment before the method is the class whatever its case, so `--macro nope.bar()` asks for
		// module `nope` and reports it missing.
		if (typeIdx < 0) typeIdx = typeSegs.length - 1;
		// moduleOnly: `Module.method` (a single type segment) can target a module-level
		// static, which wins over a same-named class's static; `Module.Class.method`
		// always targets the class.
		return {pack: typeSegs.slice(0, typeIdx), module: typeSegs[typeIdx], name: typeSegs[typeSegs.length - 1], method: segs[segs.length - 1], moduleOnly: typeSegs.length - typeIdx == 1};
	}

	static function macroPrototype(ec:EvalContext, path:hxc.core.Globals.Path, field:String, modulePath:Null<hxc.core.Globals.Path>, isInstance:Bool):Null<VPrototype> {
		var p = isInstance ? ec.instancePrototypes.get(EvalHash.pathHash(path)) : ec.staticPrototypes.get(EvalHash.pathHash(path));
		if (p != null && p.pnames.exists(EvalHash.hash(field))) return p;
		if (isInstance || macroCom == null) return p;
		var m = try hxc.context.ModuleLoader.loadModuleOpt(macroCom, modulePath != null ? modulePath : macroLoadPath(path), Position.nullPos) catch (_:Dynamic) null;
		// Only the REQUESTED class (or the module-statics carrier) may satisfy the lookup; a same-module
		// sibling with a same-named static must not shadow it (macros resolve by exact path + method).
		if (m != null) for (mt in m.types) switch (mt) {
			case TClassDecl(c) if ((c.path.name == path.name || (m.statics != null && c == m.statics)) && c.statics.exists(field)):
				var candidate = ec.staticPrototypes.get(EvalHash.pathHash(c.path));
				if (candidate != null) return candidate;
			case _:
		}
		return p;
	}

	// The macro call: -v logs the call before it runs, and the exit once it returns - which it also does,
	// answering nothing, for the abort a Context.error ends a macro with.
	static function logMacroCall(com:Context, name:String, p:Position):Void {
		com.log("Calling macro " + name + " (" + p.file + ":" + Position.lineNumber(p) + ")");
	}

	static function callMacroFn(com:Context, ec:EvalContext, callee:Expr, errPos:Position, values:Array<EvalValue>, p:Position):EvalValue {
		var fn = resolveMacroFn(ec, callee, errPos);
		if (!com.verbose) return fn(values);
		var t = macroTarget(callee);
		var name = hxc.core.Globals.sTypePath({pack: t.pack, name: t.name}) + "." + t.method;
		logMacroCall(com, name, p);
		var r = try fn(values) catch (a:hxc.eval.EvalExceptions.MacroAbort) { com.log("Exiting macro " + name); throw a; };
		com.log("Exiting macro " + name);
		return r;
	}

	static function resolveMacroFn(ec:EvalContext, callee:Expr, p:Position):VFunc {
		var t = macroTarget(callee);
		if (t == null) throw new TypingError("@:build target must be a static call", p);
		// The path names a type of the loaded module, and only a class carries macros - a typedef, enum
		// or abstract is "Macro should be called on a class".
		var tm = try hxc.context.ModuleLoader.loadModuleOpt(macroCom, {pack: t.pack, name: t.module}, p) catch (_:Dynamic) null;
		if (tm != null) for (mt in tm.types) {
			if (TypeFunctions.tInfos(mt).path.name == t.name) switch (mt) {
				case TClassDecl(_):
				case _: throw new TypingError("Macro should be called on a class", p);
			}
		}
		var proto = ec.staticPrototypes.get(EvalHash.pathHash({pack: t.pack, name: t.name}));
		// `Module.method` prefers the module-level static over a same-named class's static.
		if (t.moduleOnly) {
			var mm = try hxc.context.ModuleLoader.loadModuleOpt(macroCom, {pack: t.pack, name: t.module}, p) catch (_:Dynamic) null;
			if (mm != null && mm.statics != null && mm.statics.statics.exists(t.method)) {
				var sproto = ec.staticPrototypes.get(EvalHash.pathHash(mm.statics.path));
				if (sproto != null && sproto.pnames.exists(EvalHash.hash(t.method))) proto = sproto;
			}
		}
		if (proto == null || !proto.pnames.exists(EvalHash.hash(t.method))) {
			var m = try hxc.context.ModuleLoader.loadModuleOpt(macroCom, {pack: t.pack, name: t.module}, p) catch (_:Dynamic) null;
			if (m != null) for (mt in m.types) switch (mt) {
				case TClassDecl(c) if (c.statics.exists(t.method)):
					proto = ec.staticPrototypes.get(EvalHash.pathHash(c.path));
					if (proto != null) break;
				case _:
			}
		}
		// Both failures report at the METADATA (`p`), not at the call expression inside it.
		if (proto == null) {
			// The module loaded but holds no type of that name - `--macro haxe.macro.Compiler.Nope.bar()` -
			// is "Module X does not define type Y"; a module that does not load at all is the plain Type
			// not found.
			var mm = try hxc.context.ModuleLoader.loadModuleOpt(macroCom, {pack: t.pack, name: t.module}, p) catch (_:Dynamic) null;
			if (mm != null && t.name != t.module) {
				var defined = false;
				for (mt in mm.types) if (TypeFunctions.tInfos(mt).path.name == t.name) defined = true;
				if (!defined) throw new TypingError("Module " + hxc.core.Globals.sTypePath(mm.path) + " does not define type " + t.name, p);
			}
			// A missing module prints as "Type not found : <module>"; the KIND is what exempts it from the
			// argument annotation when typing against an argument.
			throw new hxc.core.TypingError.ModuleNotFoundError("Type not found : " + hxc.core.Globals.sTypePath({pack: t.pack, name: t.name}), p);
		}
		var idx = proto.pnames.get(EvalHash.hash(t.method));
		if (idx == null)
			throw new TypingError("Method " + t.method + " not found on class "
				+ hxc.core.Globals.sTypePath({pack: t.pack, name: t.name}), p);
		// The resolved field has to BE a function.
		return switch (proto.pfields[idx]) { case VFunction(f, _): f; case _: throw new TypingError("Macro call should be a method", p); };
	}

	// A typed constant argument reduced to its runtime value.
	static function makeConst(ec:EvalContext, e:TExpr):EvalValue {
		return switch (e.expr) {
			case TConst(TInt(i)): VInt(i);
			case TConst(TFloat(s)): VFloat(hxc.core.Numeric.parseFloatLit(s));
			case TConst(TString(s)): mkString(s);
			case TConst(TBool(b)): b ? VTrue : VFalse;
			case TConst(TNull): VNull;
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null): makeConst(ec, e1);
			case TObjectDecl(fields):
				var m:Map<Int, EvalValue> = new Map();
				for (f in fields) m.set(EvalHash.hash(f.key.name), makeConst(ec, f.expr));
				VObject(new VObject([], ODictionary(m)));
			case TArrayDecl(al):
				var vals = [for (x in al) makeConst(ec, x)];
				VArray(new VArray(vals, vals.length));
			case _: throw new TypingError("Argument should be a constant", e.pos);
		}
	}

	// An init-macro argument for a plain function call: literal constants, plus bare idents for
	// enum-abstract values (whose runtime value is the constructor name).
	static function initMacroConstArg(ec:EvalContext, e:Expr):EvalValue {
		return switch (e.expr) {
			case EConst(CString(v, _)): mkString(v);
			case EConst(CInt(v, _)): VInt(Std.parseInt(v));
			case EConst(CFloat(v, _)): VFloat(Std.parseFloat(v));
			case EConst(CIdent("true")): VTrue;
			case EConst(CIdent("false")): VFalse;
			case EConst(CIdent("null")): VNull;
			case EConst(CIdent(name)): mkString(name);
			case EParenthesis(e1): initMacroConstArg(ec, e1);
			case _: throw new TypingError("Argument should be a constant", e.pos);
		}
	}

	public static function runInitMacros(com:Context, exprs:Array<String>):Void {
		if (exprs.length == 0) return;
		for (s in exprs) {
			// Every position inside an init-macro expression is the one "--macro <expr>" position with min
			// -1 (printed "(unknown)"): a non-inline parse flattens sub-positions to p.
			var macroPos = new Position("--macro " + s, -1, -1);
			// The trailing-semicolon check sits inside the same try as the parse, so both failures record
			// "Could not parse `<e>`" first and then report themselves - two lines, both at the macro
			// position. The failure is re-thrown as a TypingError so it travels the normal message path; a
			// raw ParserError would print nothing but "Error: ParserError".
			var e:Expr = null;
			try {
				if (StringTools.endsWith(s, ";")) throw new TypingError("Unexpected ;", macroPos);
				e = hxc.parser.Parser.parseExprString(s, macroPos.file, com.defines);
			} catch (te:TypingError) {
				com.addDiagnostic("Could not parse `" + s + "`", macroPos);
				throw new TypingError(te.message, macroPos);
			} catch (pe:hxc.parser.ParserError) {
				com.addDiagnostic("Could not parse `" + s + "`", macroPos);
				throw new TypingError(hxc.parser.ParserError.errorMsg(pe.msg), macroPos);
			}
			function flatten(e2:Expr):Expr {
				var m = Ast.mapExpr(flatten, e2);
				return new Expr(m.expr, macroPos);
			}
			e = flatten(e);
			switch (e.expr) {
				case ECall(callee, args):
					// A bare method name defaults to haxe.macro.Compiler.
					switch (callee.expr) {
						case EConst(CIdent(meth)) if (meth.charCodeAt(0) >= "a".code && meth.charCodeAt(0) <= "z".code):
							var haxeE = new Expr(EConst(CIdent("haxe")), callee.pos);
							var macroE = new Expr(EField(haxeE, "macro", EFNormal), callee.pos);
							var compilerE = new Expr(EField(macroE, "Compiler", EFNormal), callee.pos);
							callee = new Expr(EField(compilerE, meth, EFNormal), callee.pos);
						case _:
					}
					var t = macroTarget(callee);
					// A --macro whose callee is not a dotted identifier chain.
					if (t == null) throw new TypingError("Invalid macro call", e.pos);
					// Compiler.addMetadata is a std wrapper around meta_patch, not a macro method.
					if (t.pack.join(".") == "haxe.macro" && t.name == "Compiler" && t.method == "addMetadata") {
						var ec = getContext(com);
						var savedPos = curPos;
						curPos = e.pos;
						var values = [for (a in args) initMacroConstArg(ec, a)];
						while (values.length < 4) values.push(VNull);
						var className = strOf(values[1]);
						var field = values[2] == VNull ? null : strOf(values[2]);
						if (!~/^[A-Za-z_][A-Za-z0-9_.]*$/.match(className)) throw new TypingError("Invalid " + className, e.pos);
						if (field != null && !~/^[A-Za-z_][A-Za-z0-9_]*$/.match(field)) throw new TypingError("Invalid " + field, e.pos);
						logMacroCall(com, "haxe.macro.Compiler.addMetadata", e.pos);
						metaPatchValue(com, values);
						com.log("Exiting macro haxe.macro.Compiler.addMetadata");
						curPos = savedPos;
						continue;
					}
					// The same for addGlobalMetadata, whose std half is only a defaulting wrapper over
					// add_global_metadata_impl. Running it through the interpreter would make a malformed
					// meta string surface as an uncaught interpreter exception with a "Called from here"
					// frame; raised from the primitive, it has nothing under it. The wrapper's own defaults
					// have to be supplied here (macro/Compiler.hx:487).
					if (t.pack.join(".") == "haxe.macro" && t.name == "Compiler" && t.method == "addGlobalMetadata") {
						var ec = getContext(com);
						var savedPos = curPos;
						curPos = e.pos;
						var values = [for (a in args) initMacroConstArg(ec, a)];
						while (values.length < 5) values.push(VNull);
						if (values[2] == VNull) values[2] = VTrue;
						if (values[3] == VNull) values[3] = VTrue;
						if (values[4] == VNull) values[4] = VFalse;
						logMacroCall(com, "haxe.macro.Compiler.addGlobalMetadata", e.pos);
						addGlobalMetadataValue(com, values);
						com.log("Exiting macro haxe.macro.Compiler.addGlobalMetadata");
						curPos = savedPos;
						continue;
					}
					// The init macro loads at the --macro position, through the ordinary macro load.
					loadMacro(com, {pack: t.pack, name: t.module}, t.method, null, null, e.pos, false, t.name != t.module ? t.name : null);
					var ec = getContext(com);
					var savedPos = curPos;
					curPos = e.pos;
					// A macro method receives its arguments as expressions; a plain function (like
					// Compiler.nullSafety) receives constants: the arguments type against the function's
					// signature (so a malformed object literal errors here) and the typed constants convert
					// to values.
					var cf = macroWorldField({pack: t.pack, name: t.name}, t.method, {pack: t.pack, name: t.module}, t.moduleOnly);
					var isMacroFn = cf != null && cf.kind.match(Method(MethMacro));
					var sig = cf == null ? null : switch (TypeFunctions.follow(cf.type)) { case TFun(s2): s2; case _: null; };
					var vargs = if (isMacroFn) {
						[for (a in args) encodeExpr(ec, a)];
					} else if (sig != null) {
						var tctx = new hxc.typing.TyperContext(macroCom);
						// The macro typer stays in nullModule until a load sets its module, and the init macro's
						// arguments type there: a bare enum value resolves against the expected type by joining that
						// module's types.
						var savedMod = macroCom.currentModule;
						if (savedMod == null) macroCom.currentModule = TypeFunctions.nullModule;
						var r = try hxc.typing.Calls.unifyCallArgs(tctx, args, sig.args, sig.ret, e.pos)
							catch (ex:Dynamic) { macroCom.currentModule = savedMod; throw ex; };
						macroCom.currentModule = savedMod;
						[for (te in r.el) makeConst(ec, te)];
					} else {
						[for (a in args) initMacroConstArg(ec, a)];
					}
					if (sig != null) while (vargs.length < sig.args.length) vargs.push(VNull);
					// Runs through Interp.call_path, whose catch_exceptions answers None to Context.error's Abort
					// the message is reported and the compilation goes on.
					try callMacroFn(com, ec, callee, e.pos, vargs, e.pos) catch (_:hxc.eval.EvalExceptions.MacroAbort) {}
					curPos = savedPos;
				case _:
					throw new TypingError("--macro expects a call expression", e.pos);
			}
		}
	}

	public static function runAfterInitMacrosCallbacks():Void {
		// The stage advances before the callbacks run, so an init-only API used inside one warns
		// CInitMacrosDone precedes after_init_macros callbacks). The driver sets ctx.initMacrosDone just
		// before calling this, which is that advance.
		for (cb in onAfterInitMacrosCallbacks) {
			EvalContext.setCtx(cb.ec);
			// A Context.error inside one callback records and the remaining callbacks still
			// run (the reference's callback runner catches per callback).
			try switch (cb.fn) {
				case VFunction(f, _): f([]);
				case VFieldClosure(recv, f): f([recv]);
				case _:
			} catch (_:hxc.eval.EvalExceptions.MacroAbort) {
				// An Abort answers None; the message is reported already.
			} catch (te:hxc.core.TypingError) {
				var mainCom = macroCom != null && macroCom.forwardWarningsTo != null ? macroCom.forwardWarningsTo : macroCom;
				if (mainCom != null) mainCom.addDiagnostic(te.message, te.pos, te.depth);
			} catch (re:hxc.eval.EvalExceptions.EvalRunTimeException) {
				var mainCom = macroCom != null && macroCom.forwardWarningsTo != null ? macroCom.forwardWarningsTo : macroCom;
				var info = runtimeMacroError(re);
				if (mainCom != null && info != null) mainCom.addDiagnostic(info.message, info.pos);
				else if (mainCom != null) mainCom.addDiagnostic(EvalStdLib.stringOf(re.value), Position.nullPos);
			}
		}
	}

	public static function runGenerateCallbacks(com:Context, afterSave:Bool = false):Void {
		for (cb in (afterSave ? onGenerateAfterSaveCallbacks : onGenerateCallbacks)) {
			EvalContext.setCtx(cb.ec);
			var types = [for (t in com.types) encodeType(cb.ec, TypeFunctions.typeOfModuleType(t))];
			runCallback(cb.ec, function() switch (cb.fn) {
				case VFunction(f, _): f([VArray(new VArray(types, types.length))]);
				case VFieldClosure(recv, f): f([recv, VArray(new VArray(types, types.length))]);
				case _:
			});
		}
	}

	// A callback runs with no macro call in progress: Context.currentPos() is the null position there, so
	// what Context.warning records prints with no position, and a Context.error (the haxe.macro.Error the
	// native boundary made of it) leaves the callback as an Error that ends the compile with its message
	// alone at the null position. A raw throw in a callback stays what it is.
	static function runCallback(ec:EvalContext, call:Void->Void):Void {
		var savedPos = curPos;
		EvalContext.setCtx(ec);
		try call() catch (ex:EvalExceptions.EvalRunTimeException) {
			curPos = savedPos;
			var info = runtimeMacroError(ex);
			if (info != null) throw new hxc.core.TypingError.FatalError(info.message, info.pos);
			throw ex;
		} catch (a:hxc.eval.EvalExceptions.MacroAbort) {
			// prepareCallback: an abort answers nothing; the message is already reported and the callback
			// has no value.
			curPos = savedPos;
		} catch (e:Dynamic) {
			curPos = savedPos;
			throw e;
		}
		curPos = savedPos;
	}

	// Finalization: callbacks are prepended and the list runs as it is, so the newest callback runs first.
	// A round hands over only the types no earlier round saw and then flushes, and one that added types is
	// followed by another. The callbacks are the ones registered before the first round.
	public static function runAfterTypingCallbacks(com:Context, flush:Void->Void):Void {
		if (onAfterTypingCallbacks.length == 0) return;
		var fl = onAfterTypingCallbacks.copy();
		fl.reverse();
		var handled = 0;
		while (com.types.length > handled) {
			var newTypes = com.types.slice(handled);
			handled = com.types.length;
			for (cb in fl) {
				EvalContext.setCtx(cb.ec);
				var types = [for (t in newTypes) encodeModuleType(cb.ec, t)];
				runCallback(cb.ec, function() switch (cb.fn) {
					case VFunction(f, _): f([VArray(new VArray(types, types.length))]);
					case VFieldClosure(recv, f): f([recv, VArray(new VArray(types, types.length))]);
					case _:
				});
			}
			flush();
		}
	}

	public static function runAfterGenerateCallbacks():Void {
		for (cb in onAfterGenerateCallbacks) {
			// The registering context may have been retired by a macro-context rebuild; run in the current
			// one so statics (migrated forward) and late-registered modules are visible, as if a single
			// interpreter stayed alive for the whole compilation.
			runCallback(macroCtx != null ? macroCtx : cb.ec, function() switch (cb.fn) {
				case VFunction(f, _): f([]);
				case VFieldClosure(recv, f): f([recv]);
				case _:
			});
		}
	}

	// Context.makeExpr: the value as an expression positioned at the decoded pos argument.
	public static function makeExprValue(ec:EvalContext, v:EvalValue, p:Position):EvalValue {
		return encodeExpr(ec, valueToExpr(ec, v, p));
	}

	public static function makeExprValueArgs(ec:EvalContext, v:EvalValue, pv:EvalValue):EvalValue {
		return makeExprValue(ec, v, posOf(ec, pv, curPos));
	}

	// Compiler.addGlobalMetadata: parse the meta string (an expression carrying leading metadata) and
	// record the path-filtered entry.
	public static function addGlobalMetadataValue(com:Context, a:Array<EvalValue>):EvalValue {
		var filter = strOf(a[0]);
		var metaSrc = strOf(a[1]);
		var recursive = a[2] == VTrue;
		var toTypes = a[3] == VTrue;
		var toFields = a[4] == VTrue;
		var e = try hxc.parser.Parser.parseExprString(metaSrc + " null", "--macro", com.defines)
			// Only a parse failure is caught: hxc routes DISPLAY answers through exceptions too, and
			// swallowing one of those would lose the request.
			catch (e:Dynamic) {
				if (!hxc.parser.ParserError.isParseFailure(e)) throw e;
				throw new TypingError("Malformed metadata string", apiCallPos());
			};
		function collect(e:Expr):Void switch (e.expr) {
			case EMeta(m, e1):
				// Every entry parsed from the string is re-placed at the API call's position, which for a
				// --macro call is null - "(unknown)" - rather than at the string's own offsets.
				var placed:MetadataEntry = {name: m.name, params: m.params, pos: curPos};
				com.globalMetadata.unshift({filter: filter == "" ? [] : filter.split("."), meta: placed, recursive: recursive, toTypes: toTypes, toFields: toFields});
				collect(e1);
			case _:
		}
		collect(e);
		return VNull;
	}

	// Compiler.addMetadata. Store its patch until the target module is loaded.
	public static function metaPatchValue(com:Context, a:Array<EvalValue>):EvalValue {
		var metaSrc = strOf(a[0]);
		var className = strOf(a[1]);
		var field = a.length < 3 || a[2] == VNull ? null : strOf(a[2]);
		var isStatic = a.length > 3 && a[3] == VTrue;
		var e = try hxc.parser.Parser.parseExprString(metaSrc + " null", "--macro", com.defines)
			// Only a parse failure is caught: hxc routes DISPLAY answers through exceptions too, and
			// swallowing one of those would lose the request.
			catch (e:Dynamic) {
				if (!hxc.parser.ParserError.isParseFailure(e)) throw e;
				throw new TypingError("Malformed metadata string", apiCallPos());
			};
		var entries:Array<MetadataEntry> = [];
		function collect(e:Expr):Void switch (e.expr) {
			case EMeta(m, e1):
				// Every entry is re-placed at the API call's position, null for a --macro call.
				entries.push({name: m.name, params: m.params, pos: curPos});
				collect(e1);
			case _:
		}
		collect(e);
		var parts = className.split(".");
		var path:hxc.core.Globals.Path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
		com.typePatches.push({path: path, field: field, isStatic: isStatic, meta: entries, remove: false, typeHint: null});
		return VNull;
	}

	public static function typePatchValue(com:Context, a:Array<EvalValue>):EvalValue {
		var className = strOf(a[0]);
		var field = strOf(a[1]);
		var isStatic = a.length > 2 && a[2] == VTrue;
		var typeSrc = a.length < 4 || a[3] == VNull ? null : strOf(a[3]);
		var parts = className.split(".");
		var path:hxc.core.Globals.Path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
		var typeHint:Null<TypeHint> = null;
		if (typeSrc != null) {
			var pkg = hxc.parser.Parser.parseModuleString("class __HxcTypePatch { var value:" + typeSrc + "; }", "--macro", com.defines);
			switch (pkg.decls[0].decl) {
				case EClass(d): switch (d.dData[0].cffKind) {
					case FVar(t, _): typeHint = t;
					case _: throw new TypingError("Invalid field type patch", curPos);
				}
				case _: throw new TypingError("Invalid field type patch", curPos);
			}
		}
		com.typePatches.push({path: path, field: field, isStatic: isStatic, meta: [], remove: typeSrc == null, typeHint: typeHint});
		return VNull;
	}

	public static function getConfigurationValue(com:Context, ec:EvalContext):EvalValue {
		function obj(fields:Array<{name:String, value:EvalValue}>):EvalValue {
			var m:Map<Int, EvalValue> = new Map();
			for (f in fields) m.set(EvalHash.hash(f.name), f.value);
			return VObject(new VObject([], ODictionary(m)));
		}
		function str(s:String):EvalValue return mkString(s);
		function strArray(a:Array<String>):EvalValue {
			var vals:Array<EvalValue> = [for (s in a) str(s)];
			return VArray(new VArray(vals, vals.length));
		}
		// The package rules, as a haxe.ds.StringMap.
		function packageRules():EvalValue {
			var m:Map<String, EvalValue> = new Map();
			for (name in com.forbiddenPackages.keys()) m.set(name, mkEnumValue(ec, "PackageRule", "Forbidden", []));
			for (name in com.packageRemaps.keys()) if (!com.forbiddenPackages.exists(name))
				m.set(name, mkEnumValue(ec, "PackageRule", "Remap", [mkString(com.packageRemaps.get(name))]));
			return EvalStdLib.mkStringMapValues(ec, m);
		}
		// A path object. hxc keeps a type as a dotted path; Dynamic is the StdTypes module's.
		function path(dotted:String):EvalValue {
			var parts = dotted.split(".");
			var name = parts.pop();
			return obj([{name: "pack", value: strArray(parts)}, {name: "name", value: str(name)}]);
		}
		function pathArray(l:Array<String>):EvalValue {
			var vals = [for (s in l) path(s)];
			return VArray(new VArray(vals, vals.length));
		}
		var pc = com.platformConfig;
		// The per-platform values hxc's config does not model: only Js sets reserved type paths; scoping is
		// Js, Cpp and Neko, the rest the default.
		var es6 = com.platform.match(Js) && com.getEsVersion() >= 6;
		var reserved = com.platform.match(Js) ? ["Object", "Error"] : [];
		var scope = switch (com.platform) {
			case Js: es6 ? "BlockScope" : "FunctionScope";
			case Cpp: "FunctionScope";
			case _: "BlockScope";
		};
		var flags:Array<EvalValue> = switch (com.platform) {
			case Js:
				[mkEnumValue(ec, "VarScopingFlags", com.defines.rawDefined("js_unflatten") ? "ReserveAllTopLevelSymbols" : "ReserveAllTypesFlat", [])]
					.concat(es6 ? [mkEnumValue(ec, "VarScopingFlags", "NoShadowing", []), mkEnumValue(ec, "VarScopingFlags", "SwitchCasesNoBlocks", [])]
						: [mkEnumValue(ec, "VarScopingFlags", "VarHoisting", []), mkEnumValue(ec, "VarScopingFlags", "NoCatchVarShadowing", [])]);
			case Cpp: [mkEnumValue(ec, "VarScopingFlags", "NoShadowing", [])];
			case Neko: [mkEnumValue(ec, "VarScopingFlags", "ReserveAllTopLevelSymbols", [])];
			case _: [];
		};
		var platformConfig = obj([
			{name: "staticTypeSystem", value: pc.isStatic ? VTrue : VFalse},
			{name: "sys", value: pc.sys ? VTrue : VFalse},
			{name: "capturePolicy", value: mkEnumValue(ec, "CapturePolicy", switch (pc.capturePolicy) {
				case CPNone: "None";
				case CPWrapRef: "WrapRef";
				case CPLoopVars: "LoopVars";
			}, [])},
			{name: "padNulls", value: pc.padNulls ? VTrue : VFalse},
			{name: "addFinalReturn", value: pc.addFinalReturn ? VTrue : VFalse},
			{name: "overloadFunctions", value: pc.supportsOverload ? VTrue : VFalse},
			{name: "canSkipNonNullableArgument", value: pc.canSkipNonNullableArgument ? VTrue : VFalse},
			{name: "reservedTypePaths", value: pathArray(reserved)},
			{name: "supportsFunctionEquality", value: VTrue},
			{name: "usesUtf16", value: pc.usesUtf16 ? VTrue : VFalse},
			{name: "thisBeforeSuper", value: pc.thisBeforeSuper ? VTrue : VFalse},
			{name: "supportsThreads", value: pc.supportsThreads ? VTrue : VFalse},
			{name: "supportsUnicode", value: pc.supportsUnicode ? VTrue : VFalse},
			{name: "supportsRestArgs", value: pc.supportsRestArgs ? VTrue : VFalse},
			{name: "exceptions", value: obj([
				{name: "nativeThrows", value: pathArray(pc.nativeThrows)},
				{name: "nativeCatches", value: pathArray(pc.nativeCatches)},
				{name: "avoidWrapping", value: pc.avoidWrapping ? VTrue : VFalse},
				{name: "wildcardCatch", value: path(pc.wildcardCatch)},
				{name: "baseThrow", value: path(pc.baseThrow)},
			])},
			{name: "scoping", value: obj([
				{name: "scope", value: mkEnumValue(ec, "VarScope", scope, [])},
				{name: "flags", value: VArray(new VArray(flags, flags.length))},
			])},
			{name: "supportsAtomics", value: pc.supportsAtomics ? VTrue : VFalse},
		]);
		var mainClass = com.mainClass == null ? VNull : obj([
			{name: "pack", value: strArray(com.mainClass.pack)},
			{name: "name", value: str(com.mainClass.name)},
		]);
		return obj([
			{name: "version", value: VInt(4307)},
			{name: "args", value: strArray(com.args)},
			{name: "debug", value: com.debug ? VTrue : VFalse},
			{name: "verbose", value: com.verbose ? VTrue : VFalse},
			{name: "foptimize", value: com.foptimize ? VTrue : VFalse},
			{name: "platform", value: str(hxc.core.Globals.platformName(com.platform))},
			{name: "platformConfig", value: platformConfig},
			{name: "stdPath", value: strArray(com.stdPath)},
			{name: "mainClass", value: mainClass},
			{name: "packageRules", value: packageRules()},
		]);
	}

	static function identChar(c:Int):Bool {
		return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code;
	}

	static function isIdentName(s:String):Bool {
		if (s.length == 0 || !identChar(s.charCodeAt(0))) return false;
		for (i in 1...s.length) {
			var c = s.charCodeAt(i);
			if (!identChar(c) && !(c >= "0".code && c <= "9".code)) return false;
		}
		return true;
	}

	// Build the dotted type-path expression for an enum value's owning enum.
	static function enumPathExpr(ec:EvalContext, pathHash:Int, p:Position):Expr {
		var mt = ec.typeCache.get(pathHash);
		if (mt == null) throw "value_to_expr: enum type not found";
		var infos = TypeFunctions.tInfos(mt);
		var path = infos.path;
		// A sub-type spells out Module.SubType so the path resolves from any context.
		var mpath = infos.module != null ? infos.module.path : path;
		var segs = (mpath.pack.join(".") == path.pack.join(".") && mpath.name == path.name)
			? path.pack.concat([path.name])
			: mpath.pack.concat([mpath.name, path.name]);
		var e = new Expr(EConst(CIdent(segs[0])), p);
		for (i in 1...segs.length) e = new Expr(EField(e, segs[i], EFNormal), p);
		return e;
	}

	// Build an AST expression that evaluates to the given runtime value; Context.makeExpr / `$v{...}` reify
	// a value back into a haxe.macro.Expr.
	static var valueToExprDepth = 0;

	// Converting a value recurses without a guard, and a cyclic object has to end as the macro's uncaught
	// "Stack overflow". hxcpp's stack is deep enough that the recursion would effectively never return, so
	// the depth is bounded here at a figure no acyclic value reaches.
	static function valueToExpr(ec:EvalContext, v:EvalValue, p:Position):Expr {
		if (++valueToExprDepth > 8000) {
			valueToExprDepth = 0;
			return EvalExceptions.excString(ec, "Stack overflow");
		}
		var e = try valueToExprInner(ec, v, p) catch (x:Dynamic) { valueToExprDepth--; throw x; };
		valueToExprDepth--;
		return e;
	}

	static function valueToExprInner(ec:EvalContext, v:EvalValue, p:Position):Expr {
		inline function mk(ed:ExprDef):Expr return new Expr(ed, p);
		return switch (EvalValue.EvalValueTools.vresolve(v)) {
			case VNull: mk(EConst(CIdent("null")));
			case VTrue: mk(EConst(CIdent("true")));
			case VFalse: mk(EConst(CIdent("false")));
			case VInt(i): mk(EConst(CInt(Std.string(i), null)));
			case VFloat(f):
				// Infinities and NaN embed as std.Math field reads; a finite value embeds its float lexeme
				// (e.g. "10.").
				if (!Math.isFinite(f) || Math.isNaN(f)) {
					var std = new Expr(EConst(CIdent("std")), p);
					var math = new Expr(EField(std, "Math", EFNormal), p);
					var name = Math.isNaN(f) ? "NaN" : f > 0 ? "POSITIVE_INFINITY" : "NEGATIVE_INFINITY";
					new Expr(EField(math, name, EFNormal), p);
				} else
					mk(EConst(CFloat(hxc.core.Numeric.floatRepres(f), null)));
			case VString(s): mk(EConst(CString(s.sstring.toText(), SDoubleQuotes)));
			case VNativeString(s): mk(EConst(CString(s.toText(), SDoubleQuotes)));
			case VArray(va): mk(EArrayDecl([for (i in 0...va.alength) valueToExpr(ec, va.avalues[i], p)]));
			case VObject(o):
				var fields:Array<ObjectField> = [];
				function add(name:String, val:EvalValue) {
					// Ignore generated pos fields.
					var isPos = name == "pos" && (switch (EvalValue.EvalValueTools.vresolve(val)) {
						case VInstance(vi): switch (vi.ikind) { case IPos(_): true; case _: false; };
						case _: false;
					});
					if (!isPos) fields.push({name: name, pos: p, quotes: isIdentName(name) ? NoQuotes : DoubleQuotes, expr: valueToExpr(ec, val, p)});
				}
				// Object fields fold the eval IntMap, a PATRICIA trie: the observable field order is
				// ascending little-endian-patricia visit order of the hashed keys.
				inline function camlOrder(names:Array<String>):Array<String>
					return hxc.eval.EvalStdLib.sortNamesPtmap(names);
				switch (o.oproto) {
					case OProto(proto):
						for (n in camlOrder([for (k in proto.pinstanceNames.keys()) EvalHash.revHash(k)]))
							add(n, o.ofields[proto.pinstanceNames.get(EvalHash.hash(n))]);
					case ODictionary(m):
						for (n in camlOrder([for (k in m.keys()) EvalHash.revHash(k)]))
							add(n, m.get(EvalHash.hash(n)));
				}
				mk(EObjectDecl(fields));
			case VEnumValue(ev):
				var proto = EvalContext.getStaticPrototypeRaise(ec, ev.epath);
				var name = switch (proto.pkind) { case PEnum(ctors): ctors[ev.eindex].name; case _: throw "value_to_expr: not an enum"; };
				var ctorExpr = new Expr(EField(enumPathExpr(ec, ev.epath, p), name, EFNormal), p);
				ev.eargs.length == 0 ? ctorExpr : mk(ECall(ctorExpr, [for (a in ev.eargs) valueToExpr(ec, a, p)]));
			case VInstance(vi): switch (vi.ikind) {
				// Each table folded, so in its keys' order.
				case IMap(m) if (vi.iproto.ppath == EvalHash.key_haxe_ds_IntMap
						|| vi.iproto.ppath == EvalHash.key_haxe_ds_StringMap
						|| vi.iproto.ppath == EvalHash.key_haxe_ds_ObjectMap):
					mk(EArrayDecl([for (entry in EvalStdLib.orderedMapEntries(VInstance(vi))) mk(EBinop(OpArrow, valueToExpr(ec, entry.key, p), valueToExpr(ec, entry.value, p)))]));
				case _:
					EvalExceptions.excValues(ec, ["Cannot convert ", " to expr"], [v]);
			}
			case other: EvalExceptions.excValues(ec, ["Cannot convert ", " to expr"], [other]);
		};
	}

	public static function isMacroField(cf:TClassField):Bool {
		return switch (cf.kind) { case Method(MethMacro): true; case _: false; };
	}

	// The host compilation context, for macro-world builtins that must mutate host state
	// (defines, global metadata) while running inside the macro interpreter.
	public static var hostCom:Null<Context>;

	// Flushing the macro context, as a host's macro load runs it: the interpreter gets every macro-world
	// type it has not seen yet.
	public static function flushMacroContext(com:Context):Void {
		if (com.isMacro) return;
		getContext(com);
	}

	static function getContext(com:Context):EvalContext {
		hostCom = com;
		evictDisplayModule();
		evictStaleMacroModules();
		// A macro running mid-build (installAndForce types bodies that may contain macro calls) must
		// not trigger another rebuild -- that recurses without bound. While building, reuse what we have.
		if (macroCom == null) initMacroContext(com);
		doReuse(com);
		if (!building && (macroCtx == null || lastModuleCount != macroCom.modules.length || macroWorldDirty)) {
			building = true;
			try {
				// The interpreter runs macro-world code, so build it from the macro context's modules
				// (macro defined, its own parse cache), never the host com. Context API queries still
				// target the host com (defines/types reflect the program being compiled).
				hxc.typing.TypeResolve.resolveAll(macroCom);
				// Flushing the macro context types every field body of every module the macro world has loaded
				// before a macro runs. That is what fills the missing-module memo (shared with the host) with
				// the same-package misses of the std's own haxe.macro modules before any Context.onTypeNotFound
				// hook exists. Lazy typers would leave those bodies to whoever needed them first - the host,
				// after the macro ran - and the hook would be asked about haxe.macro.Reflect and its kind.
				hxc.typing.TypeFields.typeAllModules(macroCom);
				if (macroCtx == null) {
					if (Sys.getEnv("HXC_DEBUG_MACROCTX") != null) Sys.println("[macroctx] FULL BUILD, modules=" + macroCom.modules.length);
					var ec = EvalMain.create(true);
					// The interpreter of this compilation: one the macro com's errors already marked
					// (installed when the macro context is created) stays marked.
					ec.hadError = interpHadError;
					registerContext(ec, com);
					flushMacroWorld(ec);
					if (interpHadError) ec.hadError = true;
					macroCtx = ec;
				} else {
					if (Sys.getEnv("HXC_DEBUG_MACROCTX") != null) Sys.println("[macroctx] EXTEND from " + lastModuleCount + " to " + macroCom.modules.length);
					// The interpreter takes only the types it has not seen (or whose module was typed
					// again) and keeps everything else, for the compilation.
					flushMacroWorld(macroCtx);
				}
				lastModuleCount = macroCom.modules.length;
				macroWorldDirty = false;
			} catch (e:Dynamic) { building = false; throw e; }
			building = false;
		}
		doReuse(com);
		EvalContext.setCtx(macroCtx);
		currentCom = com;
		return macroCtx;
	}

	static var macroCom:Context = null;

	// The macro-world compilation context, when one exists (a class evaluated at macro
	// time belongs to it, not to the host Context).
	public static function macroWorld():Null<Context> return macroCom;

	// A compilation's macro world is fresh and serves its modules back out of the shared cache, and
	// the server drops the display file from every cache before a request, so one module is what a
	// compilation can never inherit. hxc keeps the macro world in a process static, so without this a
	// second request would find the display file's macro-world fields already typed, run no display
	// hook, and answer empty. Dropping just that module keeps the guarantee without rebuilding the
	// whole macro world each request.
	static var pendingDisplayEvict:Bool = false;
	static var pendingStaleSweep:Bool = false;

	// A compilation that finds a cached interpreter reuses it and resets the static prototypes - every
	// non-persistent static initializer runs again. That is what puts a macro-world static back at its
	// declared value for each compilation, so a macro's counter does not keep counting across requests.
	static var pendingMacroReuse:Bool = false;

	public static function resetPerRequest():Void {
		// The macro context is reused across compilations, so its per-compilation registrations are told
		// apart by EPOCH rather than cleared, which the generic lookups still need. The module
		// redefinition check is what needs it.
		if (macroCom != null) macroCom.compilationEpoch++;
		// The cached macros belong to the compilation: every request loads its macros again - a module
		// evicted since is re-typed and adding types replaces its prototypes.
		if (macroCom != null) macroCom.cachedMacros = new haxe.ds.StringMap();
		macroCurModule = null;
		pendingDisplayEvict = true;
		pendingStaleSweep = true;
		pendingMacroReuse = true;
		survivors = new haxe.ds.ObjectMap();
		interpHadError = false;
		// The build macros a compilation ran are its own: a new request must run them again, since its
		// classes are typed from source again.
		builtClasses = new Map();
		// Hxc encodes a type, a field, a var or an anon as a registry id, so the registries belong to the
		// request: kept for the process, they would hold every request's typed world alive. The id
		// counters keep counting, so a handle that did outlive its request decodes to nothing rather than
		// to another request's type.
		tvarRefs = new Map();
		cfieldRefs = new Map();
		moduleTypeRefs = new Map();
		anonRefs = new Map();
		macroMonos = new Map();
		// The callback registry belongs to the compilation, and the server builds a fresh one per
		// request. Carrying the previous request's callbacks over would run every one of them twice.
		onAfterInitMacrosCallbacks = [];
		onAfterTypingCallbacks = [];
		onGenerateCallbacks = [];
		onGenerateAfterSaveCallbacks = [];
		onAfterGenerateCallbacks = [];
	}

	// Resets the static prototypes for a new compilation.
	static function doReuse(com:Context):Void {
		if (!pendingMacroReuse) return;
		// An error dropped the cached interpreter, so the next compilation began on a fresh one with
		// had_error clear; hxc keeps its one interpreter and clears it.
		if (macroCtx != null) macroCtx.hadError = false;
		interpHadError = false;
		// The com FRESH for every compilation, and file_contents with it, so a display request's unsaved
		// source is what the macro world parses too. hxc keeps one macro com alive across requests, so it
		// is re-synced here.
		if (macroCom != null) {
			macroCom.fileContents = com.fileContents.copy();
			// Same reason for the error POLICY: the macro com has to decide whether an error is ignored the
			// way the request in hand does. A world built by an earlier NON-display request would keep the
			// normal policy, so a macro argument whose type does not resolve would fail there instead of
			// recovering to Dynamic.
			macroCom.ignoreErrors = com.ignoreErrors;
			// And the memo of missing module paths: the macro com shares this compilation's.
			macroCom.moduleNonexistentLut = com.moduleNonexistentLut;
		}
		// The reset needs an interpreter. When the sweep retired one, the flag has to SURVIVE this call:
		// the rebuild below migrates the retired context's static values across, so without a reset
		// afterwards a macro-world static keeps what the previous compilation left in it (a @:genericBuild
		// whose defineType is guarded by one then never re-runs).
		if (macroCtx == null) return;
		pendingMacroReuse = false;
		var ec = macroCtx;
		// Reuse also swaps in the new compilation's api: every macro API closure holds the com it was
		// registered with, and the previous request's is dead.
		registerContext(ec, com);
		EvalContext.setCtx(ec);
		for (key in ec.staticInits.keys()) {
			var e = ec.staticInits.get(key);
			for (d in e.delays) d(e.proto);
		}
	}

	static function evictDisplayModule():Void {
		if (!pendingDisplayEvict) return;
		pendingDisplayEvict = false;
		if (macroCom == null) return;
		var df = hxc.parser.Parser.displayFile;
		if (df == null) return;
		evictMacroModulesOfFile(df);
	}

	// The module OBJECT survives as a dependency of whatever it built, and that is the copy the
	// dirty-subgraph walk consults, so it is tainted as well as dropped.
	static function dropMacroModule(m:ModuleDef, ?taintReason:String):Void {
		macroWorldDirty = true;
		if (taintReason != null) m.extra.cacheState = MSBad(Tainted(taintReason));
		macroCom.modules.remove(m);
		macroCom.moduleLut.remove(hxc.context.Context.pathKey(m.path));
		// com.types is rebuilt from the surviving modules on every compilation, so a retired module must
		// never leave types behind. This one is a live static: leaving them would make a re-load APPEND a
		// second copy of the same class, and anything walking com.types - the @usage statistics, for one -
		// would count every occurrence once per request that had touched the file.
		for (mt in m.types) macroCom.types.remove(mt);
	}

	// Every macro-world module is loaded again and revalidated per compilation. hxc keeps one macro com for
	// the whole process, and a moduleLut hit returns the module before any check runs, so without this an
	// edited macro would keep running the code of the request before. Same check, over what survived that
	// request.
	static function evictStaleMacroModules():Void {
		if (!pendingStaleSweep) return;
		pendingStaleSweep = false;
		survivors = new haxe.ds.ObjectMap();
		if (macroCom == null || !hxc.context.ServerCache.enabled) return;
		var stale:Array<ModuleDef> = [];
		for (m in macroCom.modules)
			if (hxc.context.ServerCache.checkModule(macroCom, m, Position.nullPos) != null) stale.push(m);
			else survivors.set(m, true);
		if (stale.length == 0) return;
		for (m in stale) dropMacroModule(m);
	}

	// The macro-world modules this compilation kept from the previous one: what a fresh macro com would
	// have served back out of the cache (ServerCache.markMacroModuleReused).
	static var survivors:haxe.ds.ObjectMap<ModuleDef, Bool> = new haxe.ds.ObjectMap();

	public static function survivedIntoRequest(m:ModuleDef):Bool return survivors.exists(m);

	// Tainting walks every signature context, so a file invalidated over the protocol taints its
	// macro-context module too and the next compilation re-types it. hxc keeps the macro world in a
	// live process static rather than serving it back out of the cache, so the module is dropped from
	// it here instead.
	public static function evictMacroModulesOfFile(file:String, ?taintReason:String):Void {
		if (macroCom == null || file == null) return;
		for (m in macroCom.modules.copy()) {
			var f = m.extra == null ? null : m.extra.file;
			if (f == null) continue;
			if (!hxc.core.PathKey.same(f, file)) continue;
			dropMacroModule(m, taintReason);
		}
	}

	// From the moment the macro context exists, an error its com reports marks the compilation's one
	// interpreter, whose macro calls answer nothing from then on. hxc builds its interpreter only when
	// a macro first runs, after the macro world has already typed what it loaded, and may build it
	// again; the mark belongs to the compilation, so it is kept here and handed to each one.
	static var interpHadError = false;

	static function markInterpError():Void {
		interpHadError = true;
		if (macroCtx != null) macroCtx.hadError = true;
	}

	static function initMacroContext(com:Context):Void {
		hxc.context.Context.onMacroWorldError = markInterpError;
		macroCom = com.cloneForMacro();
		hxc.context.ModuleLoader.attach(macroCom);
		hxc.context.ModuleLoader.initBasicTypes(macroCom);
		// Initializing the macro interpreter loads Expr and Type, nothing else.
		hxc.context.ModuleLoader.loadModule(macroCom, {pack: ["haxe", "macro"], name: "Expr"}, Position.nullPos);
		hxc.context.ModuleLoader.loadModule(macroCom, {pack: ["haxe", "macro"], name: "Type"}, Position.nullPos);
	}

	// The macro-world context, when one exists; the unification force-hook uses it to type a
	// macro-world field body in its own context.
	public static function getMacroCom():Null<Context> return macroCom;


	static function macroLoadPath(path:hxc.core.Globals.Path):hxc.core.Globals.Path {
		var suffix = "_Fields_";
		if (path.name.length > suffix.length && path.name.substr(path.name.length - suffix.length) == suffix) {
			var moduleName = path.name.substr(0, path.name.length - suffix.length);
			if (path.pack.length > 0 && path.pack[path.pack.length - 1] == "_" + moduleName) {
				var pack = path.pack.copy();
				pack.pop();
				return {pack: pack, name: moduleName};
			}
		}
		return path;
	}

	// Re-parse a macro's class under the macro defines (so its #if macro members exist) and install
	// that copy into the macro context. The host parses every module without macro, which drops the
	// #if macro members a macro function's body relies on. A MACRO field's display type merges the
	// host signature (where every argument the host cannot see is Dynamic) with the MACRO world's (a
	// Dynamic host argument takes the macro-world one, and the return is always the macro world's).
	// Without it a macro reads as `Dynamic -> Dynamic`.
	public static function macroFieldDisplayType(host:Context, c:TClass, cf:TClassField):Null<T> {
		if (!isMacroField(cf) || host.isMacro) return null;
		var mpath = c.module == null ? c.path : c.module.path;
		try loadMacro(host, c.path, cf.name, mpath, null, null, false)
			catch (e:hxc.core.TypingError.FatalError) throw e
			catch (_:Dynamic) {}
		if (macroCom == null) return null;
		var m = macroCom.moduleLut.get(hxc.context.Context.pathKey(mpath));
		if (m == null) return null;
		var mcf:Null<TClassField> = null;
		for (mt in m.types) switch (mt) {
			case TClassDecl(mc) if (mc.path.name == c.path.name):
				var f = mc.statics.get(cf.name);
				if (f == null) f = mc.fields.get(cf.name);
				if (f != null) mcf = f;
			case _:
		}
		if (mcf == null) return null;
		var mt2 = switch (mcf.type) { case TLazy(r): TypeFunctions.lazyType(r); case t: t; };
		var msig = switch (TypeFunctions.follow(mt2)) { case TFun(sig): sig; case _: return null; };
		inline function isDyn(t:T) return TypeFunctions.follow(t).match(TDynamic(_));
		return switch (TypeFunctions.follow(cf.type)) {
			case TFun(hsig):
				var args = [];
				var i = 0;
				while (i < hsig.args.length && i < msig.args.length) {
					args.push(isDyn(hsig.args[i].t) ? msig.args[i] : hsig.args[i]);
					i++;
				}
				while (i < msig.args.length) { args.push(msig.args[i]); i++; }
				TFun({args: args, ret: msig.ret});
			case _:
				TFun({args: msig.args, ret: msig.ret});
		};
	}

	static function isDisplayResult(e:Dynamic):Bool {
		return Std.isOfType(e, hxc.compiler.DisplayXml.DisplayPositions)
			|| Std.isOfType(e, hxc.compiler.DisplayXml.ToplevelCompletion)
			|| Std.isOfType(e, hxc.compiler.DisplayXml.SyntaxCompletion)
			|| Std.isOfType(e, hxc.parser.Parser.TypePathCompletion)
			|| Std.isOfType(e, hxc.typing.Typer.JsonToplevelCompletion);
	}

	// A display file whose module name is Name.macro is not a compile root, so nothing in the host
	// compilation would ever load it. It is loaded into the MACRO context instead, and dropped from that
	// context's lookups first so it types again in display mode even if an earlier --macro already typed
	// it.
	// The display file's module loads in the macro context with the macro-module load's display flag on:
	// the window in which the macro world's typing answers the request, since only it types a `#if macro`
	// body.
	public static function loadDisplayModuleInMacro(host:Context, path:hxc.core.Globals.Path):Void {
		var oldWindow = hxc.typing.TypeFields.macroDisplayWindow;
		hxc.typing.TypeFields.macroDisplayWindow = true;
		// A display answer or a type path completion leaves; any other failure of the load or its finalize
		// is dropped.
		try loadDisplayModuleInMacroInner(host, path)
		catch (e:hxc.core.TypingError) {}
		catch (e:hxc.context.Context.ContextError) {}
		catch (e:Dynamic) { hxc.typing.TypeFields.macroDisplayWindow = oldWindow; throw e; }
		hxc.typing.TypeFields.macroDisplayWindow = oldWindow;
	}

	static function loadDisplayModuleInMacroInner(host:Context, path:hxc.core.Globals.Path):Void {
		if (macroCom == null) initMacroContext(host);
		var key = hxc.context.Context.pathKey(path);
		var m = macroCom.moduleLut.get(key);
		if (m != null) {
			macroCom.moduleLut.remove(key);
			macroCom.typeToModule.remove(key);
			macroCom.modules.remove(m);
			for (mt in m.types) {
				var tk = hxc.context.Context.pathKey(TypeFunctions.tInfos(mt).path);
				macroCom.moduleLut.remove(tk);
				macroCom.typeToModule.remove(tk);
			}
			macroWorldDirty = true;
		}
		// The macro-module load with display on: the macro com takes the host's display record and the
		// restore it hands back is dropped, so the finalize that follows runs under it too. Under a request
		// that types selectively that finalize types the cursor's field and nothing else.
		loadMacroClass(host, path, null, true, null, null, null, true);
		// The MACRO context is finalized after the load, so every field body types there and a display
		// position inside one answers. loadMacroClass forces only the class whose name matches the module
		// path, so a display file whose main class is named differently would get its signatures typed
		// and nothing else.
		var loaded = macroCom.moduleLut.get(key);
		if (loaded != null && host.displayFullTyping) forceModuleClassFields(macroCom, loaded);
	}

	// displayWindow: the load is the display macro mode, and the macro world keeps the display position
	// through the load and the finalize.
	public static function loadMacroClass(host:Context, path:hxc.core.Globals.Path, ?fieldName:String, forceAll:Bool = false, ?modulePath:hxc.core.Globals.Path, ?dependent:ModuleDef, ?p:Position, displayWindow:Bool = false, ?sub:String):Void {
		evictDisplayModule();
		evictStaleMacroModules();
		if (macroCom == null) initMacroContext(host);
		var oldRaise = macroCom.raiseTypingErrors;
		macroCom.raiseTypingErrors = true;
		var oldWindow = hxc.typing.TypeFields.macroDisplayWindow;
		if (displayWindow) hxc.typing.TypeFields.macroDisplayWindow = true;
		// The macro com takes the host's whole display record for this load, the full-typing flag
		// included: under a display request the macro module is typed selectively, and a sibling of the
		// forced macro stays lazy. Carrying only the display position would type every field, so a caller
		// of the macro would report errors selective typing never reaches.
		var oldFullTyping = macroCom.displayFullTyping;
		if (displayWindow) macroCom.displayFullTyping = host.displayFullTyping;
		try {
			// A sub-type's module file has a different name than the class; the caller passes the declaring
			// module's path.
			// A macro module that does not exist is a missing-module error at the macro call.
			var m = hxc.context.ModuleLoader.loadModule(macroCom, modulePath != null ? modulePath : macroLoadPath(path), p != null ? p : Position.nullPos);
			macroCurModule = m;
			// The module being typed DEPENDS on the macro module it called into, across the context
			// boundary. Without it a macro's own file could be invalidated and every module built by it
			// still read as clean.
			var dep = dependent != null ? dependent : host.currentModule;
			if (dep != null) {
				// Adding a dependency clears the POST-PROCESSING mark, not the resolve gate: a cached copy
				// of the module has to run through the filters again now that its dependency set changed.
				// hxc's addDependency resets its own resolve gate, which would re-derive signatures out
				// from under the fields already typed.
				TypeFunctions.addDependency(dep, m, true);
				dep.extra.processed = 0;
			}
			hxc.typing.TypeResolve.resolveAll(macroCom);
			// Loading the module raises what the declarations report, and from here on it is finalization
			// typing bodies, which RECORDS. Keeping the raise mode on for the macro class's own fields would
			// turn a recorded verdict in a macro body into a throw that abandons the rest of the module's
			// macro-world typing.
			macroCom.raiseTypingErrors = false;
			// That finalize runs right after the macro module is loaded, before the method is even looked
			// up, and it types every field body of every module the macro world holds - the macro module's
			// own `using` targets included. That is what fills the missing-module memo (shared with the
			// host) with the same-package misses of Printer, ExprTools and the rest before any
			// Context.onTypeNotFound hook exists. Lazy typers forcing only the called field would leave
			// those bodies to the host, after the macro had run and registered its hook, which would then be
			// asked about haxe.macro.Reflect and its kind. The classes the macro world holds build here too
			// (class init in the macro context), which is where a @:build met inside a macro raises;
			// typeAllModules runs those first.
			hxc.typing.TypeFields.typeAllModules(macroCom);
			for (mt in m.types) switch (mt) {
				// The named field may live on a secondary module type (Module.SubType.method), so any
				// module class carrying it qualifies alongside the main one.
				case TClassDecl(c):
					if ((c.path.name == path.name && c.path.pack.join(".") == path.pack.join(".")) || (fieldName != null && c.statics.exists(fieldName)))
						if (forceAll || fieldName == null) {
							// The display route (no field) has had its finalize in typeAllModules above,
							// which under a selective request types the cursor's field alone.
							if (fieldName != null || macroCom.displayFullTyping)
								hxc.typing.TypeFields.forceClassFields(macroCom, c);
						} else {
							var cf = c.statics.get(fieldName);
							if (cf == null) cf = c.fields.get(fieldName);
							if (cf != null) hxc.typing.TypeFields.forceFieldBody(macroCom, c, cf);
						}
				case _:
			}
			// The macro load finalizes the MACRO context, which types every body that context holds - not
			// just the macro field about to be called. So a module carrying a macro is genuinely compiled
			// twice, once per world, and the `#if macro` half is type-checked in the macro world only;
			// forcing the named field alone would leave an error in that half unreported. Errors are
			// recorded here rather than raised: they are reported and the compilation carries on.
			var savedRaise = macroCom.raiseTypingErrors;
			macroCom.raiseTypingErrors = false;
			// These bodies can never be a display subject. A display request reaches the macro world only by
			// loading the display module in the macro context; what finalize types on the way to a macro
			// call is not the marked node. hxc decides by position, so without this the macro world's copy
			// of the display file would answer - with the macro-in-macro stand-in's type, so a hover on a
			// macro's result would read Unknown<0>. ... except on the route that does carry a display
			// request into the macro world: loading the display module in the macro context, which finalizes
			// there for exactly that reason. That is the forceAll / no-field route above, which types the
			// whole module unsuppressed. The DISPLAY file's own module is left alone entirely. The host owns
			// every answer about it - hover, position and @usage - and a second typed copy in the macro
			// world would be counted again by the @usage statistics, which recurse into the macro context on
			// purpose.
			var df = hxc.parser.Parser.displayFile;
			var mf = m.extra == null ? null : m.extra.file;
			var isDisplayFile = df != null && mf != null && hxc.core.PathKey.same(mf, df);
			var displayRoute = forceAll || fieldName == null;
			var savedSuppressed = hxc.parser.Parser.displaySuppressed;
			if (!displayRoute) hxc.parser.Parser.displaySuppressed = true;
			function force(c:TClass, cf:TClassField):Void {
				if (cf.expr != null) return;
				hxc.typing.TypeFields.forceFieldBody(macroCom, c, cf);
			}
			if (!isDisplayFile) for (mt in m.types) switch (mt) {
				case TClassDecl(c):
					for (cf in c.orderedStatics) force(c, cf);
					for (cf in c.orderedFields) force(c, cf);
					if (c.constructor != null) force(c, c.constructor);
				case _:
			}
			macroCom.raiseTypingErrors = savedRaise;
			if (!displayRoute) hxc.parser.Parser.displaySuppressed = savedSuppressed;
			// The class the path names has to carry the method among its statics, else "Method f not found
			// on class P" at the caller's position. A `macro` function a build macro ADDED in the host is
			// exactly that: the macro world built its copy of the class without the host's metadata, so the
			// method is not there. Only the callers that pass a position take the raise; the others verify
			// the method themselves afterwards. after the bodies: the macro load finalizes before it looks
			// the method up, so what the macro world's copy of the class records (an Unknown identifier for
			// the very method the host is asking about) precedes the miss.
			if (p != null && fieldName != null && !forceAll) {
				// A path naming the module itself finds the method among the module's own statics;
				// otherwise - a sub-type, or a class named apart from its module - the module has to hold a
				// type of that path ("Module X does not define type Y"), a class carrying the method as a
				// static (naming the path as written).
				var viaStatics = sub == null && m.statics != null
					&& hxc.core.Globals.sTypePath(m.path) == hxc.core.Globals.sTypePath(path)
					&& m.statics.statics.exists(fieldName);
				if (!viaStatics) {
					var tname = sub != null ? sub : path.name;
					var named:Null<ModuleType> = null;
					for (mt in m.types) {
						var tp = TypeFunctions.tInfos(mt).path;
						if (tp.name == tname && tp.pack.join(".") == path.pack.join(".")) named = mt;
					}
					if (named == null)
						throw new TypingError("Module " + hxc.core.Globals.sTypePath(m.path) + " does not define type " + tname, p);
					switch (named) {
						case TClassDecl(c):
							if (!c.statics.exists(fieldName))
								throw new TypingError("Method " + fieldName + " not found on class "
									+ hxc.core.Globals.sTypePath(path) + (sub != null ? "." + sub : ""), p);
						case _:
							throw new TypingError("Macro should be called on a class", p);
					}
				}
			}
		} catch (e:TypingError) {
			macroCom.raiseTypingErrors = oldRaise;
			hxc.typing.TypeFields.macroDisplayWindow = oldWindow;
			macroCom.displayFullTyping = oldFullTyping;
			throw e;
		} catch (e:Dynamic) {
			macroCom.raiseTypingErrors = oldRaise;
			hxc.typing.TypeFields.macroDisplayWindow = oldWindow;
			macroCom.displayFullTyping = oldFullTyping;
			// A display answer raised while typing a macro body is the request's result, not a macro-loading
			// failure to swallow; only a typing Error is swallowed. Neither is a fatal error: finalization
			// raises the fatal error of a body the macro world could not type straight out of the macro
			// world, and the compile ends on it. An exit is re-raised past the catchall, so a macro that
			// exits ends the compile there rather than leaving typing to carry on without its result.
			if (isDisplayResult(e) || Std.isOfType(e, hxc.core.TypingError.FatalError)
				|| Std.isOfType(e, hxc.eval.EvalExceptions.EvalSysExit) || Std.isOfType(e, hxc.eval.EvalExceptions.HostException)) throw e;
			// What the macro module's load or finalize raises - a class build's Type not found among it -
			// goes to the macro call. The swallows are the callers': the macro force's own display flag
			// (not the display load mode every force passes), and the catch-all of loading the display
			// module in the macro context.
			if (Std.isOfType(e, hxc.context.Context.ContextError)) throw e;
		}
		macroCom.raiseTypingErrors = oldRaise;
		hxc.typing.TypeFields.macroDisplayWindow = oldWindow;
		macroCom.displayFullTyping = oldFullTyping;
		// ': a host load flushes the macro context - finalize, generate, the filters built anew (the
		// exception filter's loads count against the loaded macro module, curmod) and add_types for what
		// the interpreter has not seen - whether or not anything is new. The first one creates the
		// interpreter (getContext). The load_display_module_in_macro route (no method) finalizes only .
		if (macroCtx != null && fieldName != null && !forceAll && !host.isMacro) {
			hxc.typing.TypeResolve.resolveAll(macroCom);
			hxc.typing.TypeFields.typeAllModules(macroCom);
			flushMacroWorld(macroCtx);
			lastModuleCount = macroCom.modules.length;
			macroWorldDirty = false;
		}
	}

	// A host macro load: a (class, method) not yet in cachedMacros loads its module, finalizes and flushes
	// the macro context (the first flush creates the interpreter), is cached, and puts nullModule back as
	// the macro context's module; one in cachedMacros skips all of that. Either way the module being typed
	// depends on the macro's module.
	public static function loadMacro(host:Context, path:hxc.core.Globals.Path, fieldName:String, modulePath:Null<hxc.core.Globals.Path>,
			dependent:Null<ModuleDef>, p:Null<Position>, display:Bool, ?sub:String):Void {
		var cacheKey = hxc.core.Globals.sTypePath(path) + (sub != null ? "." + sub : "") + "." + fieldName;
		if (macroCom == null || !macroCom.cachedMacros.exists(cacheKey)) {
			loadMacroClass(host, path, fieldName, false, modulePath, dependent, p, display, sub);
			getContext(host);
			macroCom.cachedMacros.set(cacheKey, true);
			macroCurModule = null;
		} else {
			var mloaded = macroCom.moduleLut.get(hxc.context.Context.pathKey(modulePath != null ? modulePath : macroLoadPath(path)));
			var dep = dependent != null ? dependent : host.currentModule;
			if (mloaded != null && dep != null) hxc.context.ModuleLoader.addDependency(dep, mloaded);
		}
	}

	// The outermost expansion of the most recent macro run, for the assign lvalue check.
	public static var lastExpansionAst:Null<Expr> = null;

	public static function run(tctx:TyperContext, fa:FieldAccess, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		// A macro is not CALLED from within the macro context. The call is replaced by `throw
		// "macro-in-macro"`, which is then typed like any expression. The macro world holds the module
		// carrying the macro, so its own bodies contain calls to it; running them there would execute
		// every macro a second time, out of order with the host's own calls (a macro keeping state in a
		// static would then answer the host's first call with the value its own macro-world run had left
		// behind).
		if (tctx.com.isMacro) {
			// The macro is still loaded first: a (class, method) not in cachedMacros finalizes the macro
			// context, which types the bodies still pending there, and is cached. The macro context is its
			// own macro context, and nothing is added to the interpreter from inside it.
			var mkey = switch (fa.host) {
				case FHStatic(c) | FHAbstract(_, _, c) | FHInstance(c, _): hxc.core.Globals.sTypePath(c.path) + "." + fa.field.name;
				case _: null;
			};
			var mloaded = switch (fa.host) {
				case FHStatic(c) | FHAbstract(_, _, c) | FHInstance(c, _): c.module;
				case _: null;
			};
			if (mkey != null && !tctx.com.cachedMacros.exists(mkey)) {
				macroCurModule = mloaded;
				hxc.typing.TypeFields.typeAllModules(tctx.com);
				tctx.com.cachedMacros.set(mkey, true);
				macroCurModule = null;
			}
			// The current module depends on the loaded one, cached or not.
			if (mloaded != null) hxc.context.ModuleLoader.addDependency(tctx.com.currentModule, mloaded);
			return Typer.typeExpr(tctx, {expr: EThrow({expr: EConst(CString("macro-in-macro", SDoubleQuotes)), pos: p}), pos: p}, withType);
		}
		// Saved before the call position is installed: a nested run (an @:from cast macro reached while
		// typing an outer macro's argument) must put back the OUTER call's position, as a per-call API
		// record would.
		var savedPos0 = curPos;
		curPos = p;
		var isInstance = false;
		var hostClass = switch (fa.host) {
			case FHStatic(c): c;
			case FHAbstract(_, _, c): c;
			case FHInstance(c, _):
				isInstance = true;
				c;
			case _: throw new TypingError("Only static or member macro functions are supported", p);
		};
		var path = hostClass.path;
		var callModule = moduleForPosition(tctx.com, p);
		// A member receiver is pushed as `this` before the macro loads and types the macro world, so its
		// stored id precedes the ids consumed by macro-context typing.
		var receiverSyntax = isInstance ? Calls.typedExprToSyntax(tctx, fa.on) : null;
		// A (class, method) the macro context has not loaded yet loads its module and finalizes the macro
		// world before the interpreter is consulted; one in cachedMacros skips both.
		try loadMacro(tctx.com, path, fa.field.name, hostClass.module != null ? hostClass.module.path : null,
			tctx.curclass != null ? tctx.curclass.module : null, p, false)
		catch (e:TypingError) {
			curPos = savedPos0;
			throw new hxc.context.Context.ContextError(e.message, e.pos, Other, e.depth);
		}
		var ec = getContext(tctx.com);
		// A member macro is a static of the macro context, called with its receiver as the first argument.
		var proto = macroPrototype(ec, path, fa.field.name, hostClass.module != null ? hostClass.module.path : null, false);
		var idx = proto == null ? null : proto.pnames.get(EvalHash.hash(fa.field.name));
		if (proto == null || idx == null) {
			// The macro field is absent because the host parsed the class without macro defined; load the
			// class from the macro world so its #if macro members are present.
			// What the macro module's declarations raise comes out of the module load as an Error, not as a
			// resolution miss, so the identifier and call fallbacks (which catch only a miss) let it pass
			// and the statement records it. hxc signals a miss with a TypingError, so the load's failure
			// travels as a ContextError, which those fallbacks do not catch - as Typeload.forceBuildInBody
			// does for a class build.
			try loadMacroClass(tctx.com, path, fa.field.name, false, hostClass.module != null ? hostClass.module.path : null,
				tctx.curclass != null ? tctx.curclass.module : null, p)
			catch (e:TypingError) {
				if (Std.isOfType(e, hxc.core.TypingError.FatalError)) throw e;
				curPos = savedPos0;
				throw new hxc.context.Context.ContextError(e.message, e.pos, Other, e.depth);
			}
			ec = getContext(tctx.com);
			proto = macroPrototype(ec, path, fa.field.name, hostClass.module != null ? hostClass.module.path : null, false);
			idx = proto == null ? null : proto.pnames.get(EvalHash.hash(fa.field.name));
		}
		// Once the macro world has reported an error (the macro com's error hook marks the interpreter, and
		// adding types then adds nothing), no macro is called: the call answers nothing and types as `null`
		// once its arguments are typed like any call's.
		var skipCall = ec.hadError;
		if (proto == null && !skipCall) throw new TypingError("Macro type not loaded: " + path.name, p);
		if (idx == null && !skipCall) throw new TypingError("Method " + fa.field.name + " not found on class " + hxc.core.Globals.sTypePath(path), p);
		var fn = skipCall ? null : switch (proto.pfields[idx]) {
			case VFunction(f, _): f;
			case _: throw new TypingError("Not a macro function: " + fa.field.name, p);
		};
		var savedTctx = curTctx;
		var savedPos = savedPos0;
		var savedModule = curModule;
		// The macro's RESULT is typed after the macro returns, with the interpreter's env stack popped: an
		// exception raised there - the not-found hook throwing while the result's type hint loads - reports
		// with no "Called from here" for this invocation.
		var resultPhase = false;
		macroCallDepth++;
		try {
			// The argument signature comes from the macro world: the host-context signature of a macro
			// method degrades its types to Dynamic, which would hide the Expr parameters.
			var sigCf = macroWorldField(path, fa.field.name, hostClass.module != null ? hostClass.module.path : null);
			var sigArgs = switch (TypeFunctions.follow((sigCf != null ? sigCf : fa.field).type)) { case TFun(s): s.args; case _: null; };
			var callEl = isInstance ? [receiverSyntax].concat(el) : el;
			// Static and member macros run the typed argument pipeline against the macro-world signature; a
			// member macro keeps its receiver Expr as the first declared argument there (it is dropped
			// host-side only), so the pushed receiver lines up with margs.
			// An abstract-hosted macro threads its receiver through the impl signature (this:AbstractType,
			// not Expr), which the pipeline does not model yet, so it stays on the legacy encode path.
			var usePipeline = switch (fa.host) {
				case FHStatic(_): true;
				case FHInstance(_, _): sigCf != null;
				case _: false;
			};
			var args = usePipeline ? typeMacroArgs(ec, tctx, callEl, sigArgs, p) : macroArgs(ec, callEl, sigArgs);
			curTctx = tctx;
			curPos = p;
			curModule = callModule;
			if (skipCall) {
				curTctx = savedTctx;
				curPos = savedPos;
				curModule = savedModule;
				macroCallDepth--;
				return Typer.typeExpr(tctx, new Expr(EConst(CIdent("null")), p), withType);
			}
			expectedTypeStack.push(withType);
			// The macro runs inside an entry environment at the call, whose leave position is the call
			// itself: the chain's last "Called from here" and the depth the recursion limit counts from. An
			// exception leaves it popped (catch_exceptions restores the environment it started with).
			var entryEval = EvalContext.getEval(ec);
			var entryEnv = EvalContext.pushEnvironment(ec, EvalContext.createEnvInfo(true, p, EKEntrypoint, 0, 0));
			hxc.eval.EvalExceptions.setLeavePosition(entryEnv, p);
			var macroName = hxc.core.Globals.sTypePath(path) + "." + fa.field.name;
			logMacroCall(tctx.com, macroName, p);
			var result = try fn(args) catch (e:Dynamic) {
				entryEval.env = entryEnv.parent;
				if (Std.isOfType(e, hxc.eval.EvalExceptions.MacroAbort)) tctx.com.log("Exiting macro " + macroName);
				throw e;
			};
			tctx.com.log("Exiting macro " + macroName);
			EvalContext.popEnvironment(ec, entryEnv);
			expectedTypeStack.pop();
			// The expression the macro answers with is decoded under the same guard as a build's fields -
			// null is "Expected Expr but got null".
			if (result == VNull) { curTctx = savedTctx; curPos = savedPos; curModule = savedModule; throw decodingError(result, "Expr", "", p); }
			var astExpr = decodeExpr(ec, result, p);
			curTctx = savedTctx;
			curPos = savedPos;
			curModule = savedModule;
			// A located error is installed for exactly this typing, which relocates a message with no
			// position onto the call. A nested expansion restores the outer call's position rather than
			// clearing it.
			var savedRelocate = tctx.com.relocateNullPosTo;
			tctx.com.relocateNullPosTo = p;
			resultPhase = true;
			var typed = try Typer.typeExpr(tctx, astExpr, withType)
				catch (te:haxe.Exception) { tctx.com.relocateNullPosTo = savedRelocate; throw te; }
			tctx.com.relocateNullPosTo = savedRelocate;
			// Recorded after the inner typing so nested macro runs cannot overwrite the OUTERMOST expansion;
			// the assign check reads it to judge a macro call lvalue.
			lastExpansionAst = astExpr;
			macroCallDepth--;
			return typed;
		} catch (e:haxe.Exception) {
			if (expectedTypeStack.length > 0 && expectedTypeStack[expectedTypeStack.length - 1] == withType) expectedTypeStack.pop();
			// The catcher's position, the macro invocation, heads a report whose raise has no position of
			// its own (the chain itself ends at the entry environment). Recorded on the exception as it
			// leaves this frame, innermost first: curPos read at catch time is whatever the restore put
			// back.
			var rte = Std.downcast(e, hxc.eval.EvalExceptions.EvalRunTimeException);
			if (rte != null && !resultPhase) rte.callPositions.push(p);
			curTctx = savedTctx;
			curPos = savedPos;
			curModule = savedModule;
			macroCallDepth--;
			// Context.error aborts once its message is reported: the interpreter answers nothing and the
			// call types `null`, at any depth.
			if (Std.isOfType(e, hxc.eval.EvalExceptions.MacroAbort)) return Typer.typeExpr(tctx, new Expr(EConst(CIdent("null")), p), withType);
			// What the macro does not catch is a typing error at the invocation, raised - a block records it
			// per statement and goes on, an initializer's escape ends the compile - and reported as the
			// interpreter prints it (the head and its "Called from here" chain). The conversion waits for
			// the OUTERMOST macro frame so nested expansions keep adding their invocation to the chain.
			if (rte != null && macroCallDepth == 0) {
				var info = runtimeMacroError(rte);
				if (info != null && isAbortValue(EvalContext.getCtx(), rte.value)) {
					// "error": display_error, then Abort; the interpreter answers None and the call types
					// `null` instead .
					tctx.com.addDiagnostic(info.message, info.pos);
					return Typer.typeExpr(tctx, new Expr(EConst(CIdent("null")), p), withType);
				}
				// A thrown haxe.macro.Error is the typing error it names, raised at its own position with no
				// "Uncaught exception" head and no chain.
				if (info != null) throw new TypingError(info.message, info.pos);
				var stack = uncaughtExceptionStack(rte);
				var te = new TypingError(stack[0].message, stack[0].pos);
				te.callChain = stack;
				throw te;
			}
			throw e;
		}
	}

	// The macro-world class field for a host-context field, carrying the real (Expr-typed)
	// signature. Null when the macro world has no such class or field.
	static function macroWorldField(path:hxc.core.Globals.Path, fieldName:String, modulePath:Null<hxc.core.Globals.Path>, preferModuleStatics:Bool = false):Null<TClassField> {
		if (macroCom == null) return null;
		var m = try hxc.context.ModuleLoader.loadModule(macroCom, modulePath != null ? modulePath : macroLoadPath(path), Position.nullPos) catch (_:Dynamic) return null;
		// A `Module.method` target prefers the module-level static over a class's.
		if (preferModuleStatics && m.statics != null) {
			var cf = m.statics.statics.get(fieldName);
			if (cf != null) return cf;
		}
		for (mt in m.types) switch (mt) {
			case TClassDecl(c) if ((c.path.name == path.name && c.path.pack.join(".") == path.pack.join(".")) || c.statics.exists(fieldName)):
				var cf = c.statics.get(fieldName);
				if (cf == null) cf = c.fields.get(fieldName);
				if (cf != null) return cf;
			case _:
		}
		return null;
	}

	static function moduleForPosition(com:Context, p:Position):Null<ModuleDef> {
		var cur = com.currentModule;
		if (moduleMatchesPosition(cur, p)) return cur;
		for (m in com.modules) if (moduleMatchesPosition(m, p)) return m;
		return cur;
	}

	static function moduleMatchesPosition(m:Null<ModuleDef>, p:Position):Bool {
		if (m == null || m.extra == null || p == null || p.file == null || p.file == "") return false;
		return hxc.core.PathKey.same(m.extra.file, p.file);
	}

	// The macro call argument pipeline: the macro-world signature classifies each parameter against
	// haxe.macro.Expr; Expr parameters accept any value and receive the raw argument AST, function
	// parameters type in the macro context and pass the evaluated closure, and other parameters must
	// be constants whose typed value passes. The [e][index] wrapping runs everything through
	// unifyCallArgs so arity checking and optional padding behave exactly like a normal call. A
	// trailing Array<Expr> parameter collects the surplus arguments.
	static function typeMacroArgs(ec:EvalContext, tctx:hxc.typing.TyperContext, el:Array<Expr>, sigArgs:Null<Array<TSignatureArg>>, p:Position):Array<EvalValue> {
		if (sigArgs == null) return [for (e in el) encodeExpr(ec, e)];
		var mctx = macroCom != null ? new hxc.typing.TyperContext(macroCom) : tctx;
		// The macro context types with no display kind and is not the display file, so nothing typed
		// through mctx here - the haxe.macro.Expr load at the call's position included - answers the host's
		// display request.
		var mw = hxc.typing.TypeFields.enterMacroWorld(mctx.com);
		try {
			var r = typeMacroArgsIn(ec, tctx, mctx, el, sigArgs, p);
			hxc.typing.TypeFields.leaveMacroWorld(mw);
			return r;
		} catch (e:Dynamic) {
			hxc.typing.TypeFields.leaveMacroWorld(mw);
			throw e;
		}
	}

	static function typeMacroArgsIn(ec:EvalContext, tctx:hxc.typing.TyperContext, mctx:hxc.typing.TyperContext, el:Array<Expr>, sigArgs:Array<TSignatureArg>, p:Position):Array<EvalValue> {
		var basic = mctx.com.basic;
		// Rest<Expr> in a macro signature reads as Array<Expr>.
		var margs = sigArgs.copy();
		if (margs.length > 0) {
			var lastT = margs[margs.length - 1].t;
			switch (TypeFunctions.follow(lastT)) {
				case TAbstract(ra, [t1]) if (ra.path.pack.length == 1 && ra.path.pack[0] == "haxe" && ra.path.name == "Rest"):
					var last = margs[margs.length - 1];
					margs[margs.length - 1] = {name: last.name, opt: last.opt, t: basic.tarray(t1)};
				case _:
			}
		}
		var exprPath:TypePath = {tpackage: ["haxe", "macro"], tname: "Expr", tparams: [], tsub: null};
		var exprT = hxc.typing.Typeload.loadInstance(mctx.com, [], exprPath, p, false);
		// A trailing Array<Expr> parameter splits the surplus arguments off; running out of arguments with
		// only the array parameter left still passes the empty-array placeholder so unifyCallArgs accepts
		// the call.
		var el2:Array<Expr> = [];
		var callEl = el;
		if (margs.length > 0) {
			switch (TypeFunctions.follow(margs[margs.length - 1].t)) {
				case TInst(c, [et]) if (c.path.pack.length == 0 && c.path.name == "Array"
						&& (try { TypeUnification.typeEqKind(EqStrict, et, exprT); true; } catch (_:UnifyError) false)):
					if (el.length >= margs.length - 1) {
						callEl = el.slice(0, margs.length - 1);
						el2 = el.slice(margs.length - 1);
						callEl.push(new Expr(EArrayDecl([]), p));
					}
				case _:
			}
		}
		// Classification: an Expr-compatible parameter degrades to Dynamic for the call check (any value
		// encodes); a function or value parameter keeps its type.
		var kinds:Array<Int> = []; // 0 = expr, 1 = function, 2 = other
		var checkArgs:Array<TSignatureArg> = [for (ma in margs) {
			var isExpr = try { TypeUnification.unifyDefault(ma.t, exprT); true; } catch (_:UnifyError) false;
			if (isExpr) {
				kinds.push(0);
				{name: ma.name, opt: ma.opt, t: TypeFunctions.tDynamic};
			} else {
				switch (TypeFunctions.follow(ma.t)) {
					case TFun(_): kinds.push(1);
					case _: kinds.push(2);
				}
				ma;
			}
		}];
		// Constants pass raw (single-quoted strings lose their interpolation kind), functions type later,
		// and anything else types as (null : Expr) for the error report; the [e][index] wrapping keeps the
		// original recoverable.
		function requote(e:Expr):Expr {
			return switch (e.expr) {
				case EConst(CString(cs, SSingleQuotes)): new Expr(EConst(CString(cs, SDoubleQuotes)), e.pos);
				case _: Ast.mapExpr(requote, e);
			}
		}
		var constants:Array<Expr> = [for (i in 0...callEl.length) {
			var e = callEl[i];
			var wrapped = if (try { hxc.core.TexprTools.typeConstantValue(basic, e); true; } catch (_:Dynamic) false)
				requote(e);
			else if (isFunctionExpr(e))
				new Expr(EConst(CIdent("null")), e.pos);
			else
				new Expr(ECheckType(new Expr(EConst(CIdent("null")), e.pos), {ct: CTPath(exprPath), pos: e.pos}), e.pos);
			new Expr(EArray(new Expr(EArrayDecl([wrapped]), e.pos), new Expr(EConst(CInt(Std.string(i), null)), e.pos)), e.pos);
		}];
		// The stand-in `(null : Expr)` is built at the argument'S own position. It must never answer a
		// display question: a display subject is a marked EDisplay node and these stand-ins are
		// synthesized after the marking, but hxc decides by position, so the check has to be off while
		// they are typed. The real argument expressions are typed after this, outside the window.
		var savedSuppressed = hxc.parser.Parser.displaySuppressed;
		hxc.parser.Parser.displaySuppressed = true;
		var elt = try Calls.unifyCallArgs(mctx, constants, checkArgs, TypeFunctions.tDynamic, p).el
			catch (e:Dynamic) { hxc.parser.Parser.displaySuppressed = savedSuppressed; throw e; };
		hxc.parser.Parser.displaySuppressed = savedSuppressed;
		var args:Array<EvalValue> = [];
		for (i in 0...elt.length) {
			var te = elt[i];
			var origE:Null<Expr> = null;
			var et = te;
			switch (te.expr) {
				case TArray({expr: TArrayDecl([inner])}, {expr: TConst(TInt(idx))}):
					origE = callEl[idx];
					et = inner;
				case TConst(TNull):
					origE = new Expr(EConst(CIdent("null")), te.pos);
				case _:
					origE = new Expr(EConst(CIdent("null")), te.pos);
			}
			var kind = i < kinds.length ? kinds[i] : 0;
			args.push(switch (kind) {
				case 0:
					encodeExpr(ec, withDisplayMark(origE));
				case 1:
					var ma = margs[i];
					var typed = typeMacroExpr(mctx, origE);
					try TypeUnification.unifyDefault(typed.type, ma.t) catch (ue:UnifyError)
						throw new TypingError(hxc.core.TPrinting.betterErrorMessage(ue.errors), origE.pos);
					hxc.eval.EvalEmitter.eval(ec, typed);
				case _:
					hxc.eval.EvalEmitter.eval(ec, et);
			});
		}
		// The surplus arguments encode as the trailing Array<Expr>.
		if (el2.length > 0) {
			args.pop();
			args.push(encodeArray([for (e in el2) encodeExpr(ec, e)]));
		}
		return args;
	}

	static function macroArgs(ec:EvalContext, el:Array<Expr>, sigArgs:Null<Array<TSignatureArg>>):Array<EvalValue> {
		if (sigArgs != null && sigArgs.length > 0) {
			var last = sigArgs[sigArgs.length - 1].t;
			var restT = restElemType(last);
			if (restT != null) return macroRestArgs(ec, el, sigArgs, restT);
			var arrayT = arrayExprElemType(last);
			if (arrayT != null) return macroRestArgs(ec, el, sigArgs, arrayT);
		}
		return [for (i in 0...el.length) macroArg(ec, el[i], (sigArgs != null && i < sigArgs.length) ? sigArgs[i].t : null, (sigArgs != null && i < sigArgs.length) ? sigArgs[i].name : null)];
	}

	static function macroRestArgs(ec:EvalContext, el:Array<Expr>, sigArgs:Array<TSignatureArg>, restT:T):Array<EvalValue> {
		var fixed = sigArgs.length - 1;
		var out:Array<EvalValue> = [];
		for (i in 0...fixed) out.push(i < el.length ? macroArg(ec, el[i], sigArgs[i].t, sigArgs[i].name) : VNull);
		var rest:Array<EvalValue> = [];
		for (i in fixed...el.length) rest.push(macroArg(ec, el[i], restT, sigArgs[sigArgs.length - 1].name));
		out.push(VArray(new VArray(rest, rest.length)));
		return out;
	}

	// An Expr (or ExprOf) macro parameter receives the reified expression; any other parameter type
	// receives the argument's constant value. Non-constant value arguments fall back to the reified
	// expression.
	static function macroArg(ec:EvalContext, e:Expr, pt:Null<T>, name:Null<String>):EvalValue {
		e = withDisplayMark(e);
		if (pt != null && !isExprParam(pt)) {
			var c = macroConstArg(ec, e);
			if (c.ok) return c.value;
			var isFunction = switch (TypeFunctions.follow(pt)) { case TFun(_): true; case _: false; };
			if (isFunction && !isFunctionExpr(e))
				throw new TypingError("haxe.macro.Expr should be " + hxc.core.TPrinting.sTypeStr(pt) + "\nFor function argument '" + (name == null ? "?" : name) + "'", e.pos);
		}
		return encodeExpr(ec, e);
	}

	static function withDisplayMark(e:Expr):Expr {
		if (e == null || e != hxc.typing.ExprPreprocessing.markedNode) return e;
		return new Expr(EDisplay(e, hxc.typing.ExprPreprocessing.markedKind), e.pos);
	}

	static function isFunctionExpr(e:Expr):Bool {
		return switch (e.expr) {
			case EFunction(_, _): true;
			case EParenthesis(e1) | ECast(e1, _) | EMeta(_, e1): isFunctionExpr(e1);
			case _: false;
		};
	}

	static function macroConstArg(ec:EvalContext, e:Expr):{ok:Bool, value:EvalValue} {
		function no():{ok:Bool, value:EvalValue} return {ok: false, value: VNull};
		return switch (e.expr) {
			case EConst(CString(s, _)):
				{ok: true, value: mkString(s)};
			case EConst(CInt(s, _)):
				var n = Std.parseInt(s);
				{ok: true, value: VInt(n == null ? 0 : n)};
			case EConst(CFloat(s, _)):
				{ok: true, value: VFloat(Std.parseFloat(s))};
			case EConst(CIdent("true")):
				{ok: true, value: VTrue};
			case EConst(CIdent("false")):
				{ok: true, value: VFalse};
			case EConst(CIdent("null")):
				{ok: true, value: VNull};
			case EParenthesis(e1) | ECast(e1, _) | EMeta(_, e1):
				macroConstArg(ec, e1);
			case EArrayDecl(el):
				var values:Array<EvalValue> = [];
				for (x in el) {
					var cv = macroConstArg(ec, x);
					if (!cv.ok) return no();
					values.push(cv.value);
				}
				{ok: true, value: VArray(new VArray(values, values.length))};
			case EObjectDecl(fields):
				var m = new Map<Int, EvalValue>();
				for (f in fields) {
					var cv = macroConstArg(ec, f.expr);
					if (!cv.ok) return no();
					m.set(EvalHash.hash(f.name), cv.value);
				}
				{ok: true, value: VObject(new VObject([], ODictionary(m)))};
			case _:
				no();
		}
	}

	// A MacroType macro has to return haxe.macro.Type, or else haxe.macro.ComplexType - unified against
	// each, the second failure raised at the macro field's position.
	static function checkMacroTypeReturn(cf:Null<TClassField>):Void {
		if (cf == null || macroCom == null) return;
		var mret = switch (TypeFunctions.follow(cf.type)) { case TFun(s): s.ret; case _: return; };
		var ttype = hxc.typing.Typeload.loadInstance(macroCom, [], {tpackage: ["haxe", "macro"], tname: "Type", tparams: [], tsub: null}, cf.pos, false);
		try {
			TypeUnification.unifyDefault(mret, ttype);
		} catch (_:hxc.core.TypeUnification.UnifyError) {
			var tct = hxc.typing.Typeload.loadInstance(macroCom, [], {tpackage: ["haxe", "macro"], tname: "Expr", tparams: [], tsub: "ComplexType"}, cf.pos, false);
			try TypeUnification.unifyDefault(mret, tct)
			catch (ue:hxc.core.TypeUnification.UnifyError)
				throw new TypingError(hxc.core.TPrinting.betterErrorMessage(ue.errors), cf.pos);
		}
	}

	public static function runGenericBuild(com:Context, c:TClass, params:TParams, fields:Array<ClassField>, p:Position, ?callerTypeParams:TypeParams):T {
		var entry = findMeta(c.meta, ":genericBuild");
		if (entry == null) throw new TypingError(Context.sTypePath(c.path) + " is missing @:genericBuild meta. Was it removed by a macro?", p);
		if (entry.params.length != 1) throw new TypingError("genericBuild requires a single expression call parameter", p);
		var callExpr = entry.params[0];
		switch (callExpr.expr) {
			case ECall(callee, _):
				var t = macroTarget(callee);
				if (t != null) loadMacro(com, {pack: t.pack, name: t.module}, t.method, null, null, p, false, t.name != t.module ? t.name : null);
			case _:
				throw new TypingError("genericBuild requires a single expression call parameter", p);
		}
		var ec = getContext(com);
		var savedBuildClass = curBuildClass;
		var savedBuildType = curBuildType;
		var savedBuildParams = curBuildParams;
		var savedBuildFields = curBuildFields;
		var savedTctx = curTctx;
		var savedPos = curPos;
		var savedMod = com.currentModule;
		try {
			var buildTctx = new TyperContext(com);
			buildTctx.curclass = c;
			// The macro runs in the CALLER's typing context (a generic build leaves ctx untouched), so
			// Context.resolveType and toComplexType round-trips resolve a bare method type param (e.g. `T`
			// from `of<T>(e:Event<T->Void>)`) to the call site's param, not the genericBuild class's own.
			buildTctx.typeParams = callerTypeParams != null ? callerTypeParams : c.params;
			buildTctx.tthis = TInst(c, params);
			com.currentModule = c.module;
			curTctx = buildTctx;
			// Context.currentPos() in a genericBuild macro is the INSTANTIATION position, unlike @:build
			// which uses the meta position.
			curPos = p;
			curBuildClass = c;
			curBuildType = TInst(c, params);
			curBuildParams = params;
			curBuildFields = fields;
			var result = switch (callExpr.expr) {
				case ECall(callee, args):
					var target = macroTarget(callee);
					var cf = target == null ? null : macroWorldField({pack: target.pack, name: target.name}, target.method, {pack: target.pack, name: target.module});
					checkMacroTypeReturn(cf);
					var sig = cf == null ? null : switch (TypeFunctions.follow(cf.type)) { case TFun(s): s; case _: null; };
					var values = macroArgs(ec, args, sig == null ? null : sig.args);
					if (sig != null) while (values.length < sig.args.length) values.push(VNull);
					// Instantiate the macro at the call position.
					callMacroFn(com, ec, callee, callExpr.pos, values, p);
				case _: throw new TypingError("genericBuild requires a single expression call parameter", callExpr.pos);
			};
			if (result == VNull) {
				curBuildClass = savedBuildClass;
				curBuildType = savedBuildType;
				curBuildParams = savedBuildParams;
				curBuildFields = savedBuildFields;
				curTctx = savedTctx;
				curPos = savedPos;
				com.currentModule = savedMod;
				return TypeFunctions.mkMono();
			}
			// A MacroType macro may return the legacy Type result as well as a ComplexType result; only a
			// value that fails to decode as a ComplexType falls back to Type decoding, and load errors
			// still surface.
			var ct:Null<ComplexType> = try decodeComplexType(ec, result, p) catch (e:TypingError) null;
			var ret:T = ct != null ? hxc.typing.Typeload.loadComplexType(com, buildTctx.typeParams, {ct: ct, pos: p}) : decodeType(ec, result);
			curBuildClass = savedBuildClass;
			curBuildType = savedBuildType;
			curBuildParams = savedBuildParams;
			curBuildFields = savedBuildFields;
			curTctx = savedTctx;
			curPos = savedPos;
			com.currentModule = savedMod;
			return ret;
		} catch (e:haxe.Exception) {
			curBuildClass = savedBuildClass;
			curBuildType = savedBuildType;
			curBuildParams = savedBuildParams;
			curBuildFields = savedBuildFields;
			curTctx = savedTctx;
			curPos = savedPos;
			com.currentModule = savedMod;
			throw e;
		}
	}

	// haxe.macro.MacroType<[Cls.method(args)]> runs the macro and becomes the type it returns. The call
	// arrives as the KExpr class the instance load makes for a TPExpr parameter, bracketed or bare.
	public static function runMacroType(com:Context, params:TParams, p:Position, ?callerTypeParams:TypeParams, ?resolvingClass:TClass):T {
		// A macro is not called from within the macro context - the call is replaced by a `throw
		// "macro-in-macro"` expression, and a MacroType then leaves a fresh monomorph behind. The macro
		// world loads the module holding the macro, so without this the same MacroType would run a second
		// time there, where a Context.getType for a type declared beside the caller is not found - and
		// that failing run would throw the host's answer away.
		if (com.isMacro) return TypeFunctions.mkMono();
		var callExpr:Null<Expr> = switch (params) {
			case [TInst({kind: KExpr(e)}, _)]:
				switch (e.expr) {
					case ECall(_, _): e;
					case EArrayDecl([e1]): switch (e1.expr) { case ECall(_, _): e1; case _: null; };
					case _: null;
				}
			case _: null;
		};
		if (callExpr == null) throw new TypingError("MacroType requires a single expression call parameter", p);
		var callee = switch (callExpr.expr) { case ECall(c, _): c; case _: null; };
		// The callee flattens to (path, field). Its own failure is "Invalid macro call".
		var target = callee == null ? null : macroTarget(callee);
		// A BARE ident is a static of the ENCLOSING class, so it resolves against the class whose signature
		// is being loaded rather than against a dotted path. hxc records that class on the Context while
		// field signatures resolve.
		if (target == null) switch (callee != null ? callee.expr : null) {
			case EConst(CIdent(i)):
				var cur = resolvingClass != null ? resolvingClass : com.resolvingClass;
				if (cur != null && cur.statics.exists(i)) {
					target = {pack: cur.path.pack, module: cur.module != null ? cur.module.path.name : cur.path.name, name: cur.path.name, method: i, moduleOnly: false};
					// Everything downstream reads the path back off the callee, so write the
					// resolved one in: the bare ident becomes the dotted pack.Class.method it names.
					var e = new Expr(EConst(CIdent(cur.path.pack.length > 0 ? cur.path.pack[0] : cur.path.name)), callee.pos);
					for (k in 1...cur.path.pack.length) e = new Expr(EField(e, cur.path.pack[k], EFNormal), callee.pos);
					if (cur.path.pack.length > 0) e = new Expr(EField(e, cur.path.name, EFNormal), callee.pos);
					callee = new Expr(EField(e, i, EFNormal), callee.pos);
				}
			case _:
		}
		if (target == null) throw new TypingError("Invalid macro call", p);
		loadMacro(com, {pack: target.pack, name: target.module}, target.method, null, null, p, false, target.name != target.module ? target.name : null);
		var ec = getContext(com);
		var savedTctx = curTctx;
		var savedPos = curPos;
		try {
			var tctx = new TyperContext(com);
			// A type-building macro runs in the CALLER's context untouched, so a type param of
			// the enclosing declaration still resolves inside Context.resolveType.
			tctx.typeParams = callerTypeParams != null ? callerTypeParams : [];
			curTctx = tctx;
			// Context.currentPos() is the INSTANTIATION position: the position of the type instance
			// being loaded.
			curPos = p;
			var args = switch (callExpr.expr) { case ECall(_, a): a; case _: []; };
			var cf = macroWorldField({pack: target.pack, name: target.name}, target.method, {pack: target.pack, name: target.module});
			checkMacroTypeReturn(cf);
			var sig = cf == null ? null : switch (TypeFunctions.follow(cf.type)) { case TFun(s): s; case _: null; };
			var values = macroArgs(ec, args, sig == null ? null : sig.args);
			if (sig != null) while (values.length < sig.args.length) values.push(VNull);
			var result = callMacroFn(com, ec, callee, p, values, p);
			// A macro that returns nothing leaves a fresh monomorph behind.
			var ret:T = if (result == VNull) TypeFunctions.mkMono() else {
				// A MacroType macro may return the legacy Type result as well as a ComplexType one; only a
				// value that fails to decode as a ComplexType falls back to Type.
				var ct:Null<ComplexType> = try decodeComplexType(ec, result, p) catch (e:TypingError) null;
				ct != null ? hxc.typing.Typeload.loadComplexType(com, tctx.typeParams, {ct: ct, pos: p}) : decodeType(ec, result);
			}
			curTctx = savedTctx;
			curPos = savedPos;
			return ret;
		} catch (e:haxe.Exception) {
			curTctx = savedTctx;
			curPos = savedPos;
			throw e;
		}
	}

	static function restElemType(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, params) if (params.length == 1 && a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Rest"): params[0];
			case _: null;
		};
	}

	static function arrayExprElemType(t:T):Null<T> {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, params) if (params.length == 1 && c.path.pack.length == 0 && c.path.name == "Array" && isExprParam(params[0])): params[0];
			case _: null;
		};
	}

	static function isExprParam(t:T):Bool {
		return switch (t) {
			case TType(d, _): d.path.name == "Expr" || d.path.name == "ExprOf";
			case TInst(c, _): c.path.name == "Expr";
			case TAbstract(a, _): a.path.name == "Expr";
			case TAnon(a): isExprAnon(a);
			case TLazy(f): isExprParam(TypeFunctions.lazyType(f));
			case _: false;
		};
	}

	static function isExprAnon(a:TAnon):Bool {
		var expr = a.fields.get("expr");
		var pos = a.fields.get("pos");
		return expr != null && pos != null && isExprDefType(expr.type) && isPositionType(pos.type);
	}

	static function isExprDefType(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TEnum(e, _) if (e.path.pack.length == 2 && e.path.pack[0] == "haxe" && e.path.pack[1] == "macro" && e.path.name == "ExprDef"): true;
			case _: false;
		};
	}

	static function isPositionType(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _) if (a.path.pack.length == 2 && a.path.pack[0] == "haxe" && a.path.pack[1] == "macro" && a.path.name == "Position"): true;
			case TAnon(a): a.fields.exists("file") && a.fields.exists("min") && a.fields.exists("max");
			case _: false;
		};
	}


	static function ctorName(ec:EvalContext, v:EvalValue):String {
		return switch (v) {
			case VEnumValue(ev): switch (ec.typeCache.get(ev.epath)) {
				case TEnumDecl(en): en.names[ev.eindex];
				case _: throw unexpectedValue(v, "enum value");
			};
			case _: throw unexpectedValue(v, "enum value");
		};
	}

	static function eargs(v:EvalValue):Array<EvalValue> {
		return switch (v) { case VEnumValue(ev): ev.eargs; case _: throw unexpectedValue(v, "enum value"); };
	}

	// A decoder handed the wrong kind of value raises the macro's own uncaught exception - "Null Access"
	// for null, otherwise the value and the kind expected. The failure travels as a DecodeFailure so a
	// build's decoding guard can turn it into its decoding report; anything else that meets it at the
	// native boundary makes it a string exception.
	static function unexpectedValue(v:EvalValue, expected:String):DecodeFailure {
		return new DecodeFailure(switch (v) {
			case VNull: "Null Access";
			case _: "Unexpected value " + EvalStdLib.valueKind(v) + "(" + EvalStdLib.stringOf(v) + "), expected " + expected;
		});
	}

	static function strOf(v:EvalValue):String {
		return switch (v) { case VString(s): s.sstring.toText(); case VNativeString(s): s.toText(); case _: throw unexpectedValue(v, "string"); };
	}

	// The module check policies, in the order haxe.macro.CompilationServer declares them.
	static function moduleCheckPolicyOfInt(i:Int):hxc.core.Type.ModuleCheckPolicy {
		return switch (i) {
			case 0: NoCheckFileTimeModification;
			case 1: CheckFileContentModification;
			case 2: NoCheckDependencies;
			case 3: NoCheckShadowing;
			case _: Retype;
		}
	}

	static function intOf(v:EvalValue):Int {
		return switch (v) { case VInt(i): i; case _: throw unexpectedValue(v, "int"); };
	}

	static function strOpt(v:EvalValue):Null<String> {
		return switch (v) { case VNull: null; case _: strOf(v); };
	}

	static function boolOf(v:EvalValue):Bool {
		return switch (v) { case VTrue: true; case _: false; };
	}

	static function arrOf(v:EvalValue):Array<EvalValue> {
		return switch (v) { case VArray(a): a.avalues.slice(0, a.alength); case VNull: []; case _: throw unexpectedValue(v, "array"); };
	}

	static function refGet(ec:EvalContext, v:EvalValue):EvalValue {
		return switch (EvalField.field(ec, v, EvalHash.hash("get"))) {
			case VFunction(f, _): f([]);
			case _: VNull;
		}
	}

	static function refString(ec:EvalContext, v:EvalValue):String {
		return switch (EvalField.field(ec, v, EvalHash.hash("toString"))) {
			case VFunction(f, _): strOf(f([]));
			case _:
				var payload = refGet(ec, v);
				var name = EvalField.field(ec, payload, EvalHash.hash("name"));
				var pack = EvalField.field(ec, payload, EvalHash.hash("pack"));
				switch [name, pack] {
					case [VString(n), VArray(a)]:
						var parts = [for (p in a.avalues.slice(0, a.alength)) strOf(p)];
						parts.length == 0 ? n.sstring.toText() : parts.join(".") + "." + n.sstring.toText();
					case _: "<unknown>";
				}
		}
	}

	static function macroTypeString(ec:EvalContext, v:EvalValue):String {
		if (v == VNull) return "Unknown<0>";
		var args = eargs(v);
		function params(pl:Array<EvalValue>):String {
			return pl.length == 0 ? "" : "<" + [for (p in pl) macroTypeString(ec, p)].join(", ") + ">";
		}
		function funArg(v:EvalValue, void:Bool):String {
			var s = macroTypeString(ec, v);
			return switch (ctorName(ec, v)) {
				case "TFun": "(" + s + ")";
				case "TAbstract" if (void && s == "Void"): "(" + s + ")";
				case _: s;
			}
		}
		return switch (ctorName(ec, v)) {
			case "TMono":
				var t = refGet(ec, args[0]);
				t == VNull ? "Unknown<0>" : macroTypeString(ec, t);
			case "TType":
				// The private typedef over an abstract implementation's statics anon (the type of the
				// abstract's name as a value) prints as Abstract<A>; the s_type native prints the decoded
				// type, which takes that arm.
				var head = switch (moduleTypeFromRef(ec, args[0])) {
					case TTypeDecl({type: TAnon(an)}): switch (an.status.get()) {
						case Statics({kind: KAbstractImpl(a)}): "Abstract<" + hxc.core.Globals.sTypePath(a.path) + ">";
						case _: null;
					}
					case _: null;
				};
				(head != null ? head : refString(ec, args[0])) + params(arrOf(args[1]));
			case "TEnum" | "TInst" | "TAbstract":
				refString(ec, args[0]) + params(arrOf(args[1]));
			case "TFun":
				var funArgs = arrOf(args[0]);
				var lhs = if (funArgs.length == 0) "()"
					else if (funArgs.length == 1 && strOf(EvalField.field(ec, funArgs[0], EvalHash.hash("name"))) == "")
						(boolOf(EvalField.field(ec, funArgs[0], EvalHash.hash("opt"))) ? "?" : "") + funArg(EvalField.field(ec, funArgs[0], EvalHash.hash("t")), true)
					else {
						var parts = [for (a in funArgs) {
							var name = strOf(EvalField.field(ec, a, EvalHash.hash("name")));
							(boolOf(EvalField.field(ec, a, EvalHash.hash("opt"))) ? "?" : "")
								+ (name == "" ? "" : name + " : ")
								+ funArg(EvalField.field(ec, a, EvalHash.hash("t")), true);
						}];
						"(" + parts.join(", ") + ")";
					}
				lhs + " -> " + funArg(args[1], false);
			case "TAnonymous":
				var an = refGet(ec, args[0]);
				var fields = arrOf(EvalField.field(ec, an, EvalHash.hash("fields")));
				if (fields.length == 0) "{}" else "{ " + [for (f in fields) strOf(EvalField.field(ec, f, EvalHash.hash("name"))) + " : " + macroTypeString(ec, EvalField.field(ec, f, EvalHash.hash("type")))].join(", ") + " }";
			case "TDynamic":
				args[0] == VNull ? "Dynamic" : "Dynamic<" + macroTypeString(ec, args[0]) + ">";
			case other:
				other;
		}
	}

	static function decodeType(ec:EvalContext, v:EvalValue):T {
		// Decoding a type reads the enum's fields off the value: null is a Null Access the macro sees as an
		// uncaught exception, not a type the compiler accepts.
		if (v == VNull) return EvalExceptions.excString(ec, "Null Access");
		var args = eargs(v);
		return switch (ctorName(ec, v)) {
			case "TMono":
				TMono(decodeMonoRef(ec, args[0]));
			case "TEnum":
				switch (moduleTypeFromRef(ec, args[0])) {
					case TEnumDecl(e): TEnum(e, [for (p in arrOf(args[1])) decodeType(ec, p)]);
					case _: throw new TypingError("Macro decode: expected enum type", curPos);
				}
			case "TInst":
				switch (moduleTypeFromRef(ec, args[0])) {
					case TClassDecl(c): TInst(c, [for (p in arrOf(args[1])) decodeType(ec, p)]);
					case _: throw new TypingError("Macro decode: expected class type", curPos);
				}
			case "TType":
				switch (moduleTypeFromRef(ec, args[0])) {
					case TTypeDecl(d): TType(d, [for (p in arrOf(args[1])) decodeType(ec, p)]);
					case _: throw new TypingError("Macro decode: expected typedef type", curPos);
				}
			case "TFun":
				TFun({
					args: [for (a in arrOf(args[0])) {
						name: strOf(EvalField.field(ec, a, EvalHash.hash("name"))),
						opt: boolOf(EvalField.field(ec, a, EvalHash.hash("opt"))),
						t: decodeType(ec, EvalField.field(ec, a, EvalHash.hash("t")))
					}],
					ret: decodeType(ec, args[1])
				});
			case "TAnonymous":
				decodeAnonRef(ec, args[0]);
			case "TDynamic":
				args[0] == VNull ? TypeFunctions.tDynamic : TDynamic(decodeType(ec, args[0]));
			case "TLazy":
				switch (args[0]) {
					case VInstance({ikind: ILazyType(r, _)}): TLazy(r);
					case _: decodeType(ec, refGet(ec, args[0]));
				}
			case "TAbstract":
				switch (moduleTypeFromRef(ec, args[0])) {
					case TAbstractDecl(a): TAbstract(a, [for (p in arrOf(args[1])) decodeType(ec, p)]);
					case _: throw new TypingError("Macro decode: expected abstract type", curPos);
				}
			case other:
				throw new TypingError("Macro decode: unhandled Type " + other, curPos);
		}
	}

	static function decodeAnonRef(ec:EvalContext, v:EvalValue):T {
		// A ref built here round-trips the anon itself.
		var handle = refHandle(ec, v);
		if (handle != null && anonRefs.exists(handle)) return TAnon(anonRefs.get(handle));
		var payload = refGet(ec, v);
		var fields = new haxe.ds.StringMap<TClassField>();
		for (fv in arrOf(EvalField.field(ec, payload, EvalHash.hash("fields")))) {
			var cf = decodeTypedClassField(ec, fv);
			fields.set(cf.name, cf);
		}
		return TypeFunctions.mkAnon(new hxc.core.Ref(Closed), fields);
	}

	static function decodeTypedClassField(ec:EvalContext, v:EvalValue):TClassField {
		var pos = posOf(ec, EvalField.field(ec, v, EvalHash.hash("pos")), curPos);
		var namePos = posOf(ec, EvalField.field(ec, v, EvalHash.hash("namePos")), pos);
		var cf = TypeFunctions.mkField(
			strOf(EvalField.field(ec, v, EvalHash.hash("name"))),
			decodeType(ec, EvalField.field(ec, v, EvalHash.hash("type"))),
			pos,
			namePos,
			boolOf(EvalField.field(ec, v, EvalHash.hash("isPublic")))
		);
		cf.doc = decodeDoc(EvalField.field(ec, v, EvalHash.hash("doc")));
		cf.meta = [];
		return cf;
	}

	// The mono id rides in the Ref's ikind like every other handle (encodeRef).
	static function decodeMonoRef(ec:EvalContext, v:EvalValue):TMono {
		var handle = refHandle(ec, v);
		if (handle == null) throw new TypingError("Macro decode: expected monomorph ref", curPos);
		var m = macroMonos.get(handle);
		if (m == null) throw new TypingError("Macro decode: unknown monomorph", curPos);
		return m;
	}

	static function moduleTypeFromRef(ec:EvalContext, v:EvalValue):ModuleType {
		// A ref built here round-trips the module type itself through the hidden `$` handle; the path
		// lookup below covers everything else.
		var handle = refHandle(ec, v);
		if (handle != null && moduleTypeRefs.exists(handle)) return moduleTypeRefs.get(handle);
		var path = pathFromDotted(refString(ec, v));
		var key = EvalHash.pathHash(path);
		var cached = ec.typeCache.get(key);
		if (cached != null) return cached;
		if (currentCom != null) {
			var wanted = Context.pathKey(path);
			for (m in currentCom.modules) for (mt in m.types) {
				if (Context.pathKey(TypeFunctions.tPath(mt)) == wanted)
					return mt;
			}
			try return currentCom.getType(path, curPos, null) catch (_:Dynamic) {}
		}
		throw new TypingError("Macro decode: type not found " + Context.pathKey(path), curPos);
	}

	// Set every sub-expression's position to p (bottom-up), so a non-inline parse result is fully anchored
	// to the call site.
	static function reanchorExpr(e:Expr, p:Position):Expr {
		var mapped = Ast.mapExpr(function(c) return reanchorExpr(c, p), e);
		return new Expr(mapped.expr, p);
	}

	static function decodeExpr(ec:EvalContext, v:EvalValue, dp:Position):Expr {
		// Decoding an expression reads the value's pos first, and a null pos is an invalid expression:
		// `Context.typeof(null)` is "Invalid expression", not the constant null.
		if (v == VNull) throw new DecodeFailure("Invalid expression");
		var p = posOf(ec, EvalField.field(ec, v, EvalHash.hash("pos")), dp);
		var ed = decodeExprDef(ec, EvalField.field(ec, v, EvalHash.hash("expr")), p);
		return new Expr(ed, p);
	}

	static function decodeExprOpt(ec:EvalContext, v:EvalValue, dp:Position):Null<Expr> {
		return v == VNull ? null : decodeExpr(ec, v, dp);
	}

	// A value that is not a well-formed haxe.macro.TypedExpr is an invalid expression, which the builtin
	// wrapper turns into the plain string exception "Invalid expression" (not a haxe.macro.Error).
	static function decodeStoredTypedExpr(ec:EvalContext, v:EvalValue):TExpr {
		return try decodeTypedExpr(ec, v) catch (e:Dynamic) {
			if (Sys.getEnv("HXC_DEBUG_DECODE") != null) Sys.println("[decode_texpr] " + Std.string(e));
			EvalExceptions.excString(ec, "Invalid expression");
		}
	}

	// The tvar itself round-trips through the hidden `$` handle.
	static function decodeTVar(ec:EvalContext, v:EvalValue):TVar {
		var handle = refHandle(ec, v);
		if (handle == null || !tvarRefs.exists(handle)) throw new TypingError("macro decode: expected tvar", curPos);
		return tvarRefs.get(handle);
	}

	static function classFieldFromRef(ec:EvalContext, v:EvalValue):TClassField {
		var handle = refHandle(ec, v);
		if (handle == null || !cfieldRefs.exists(handle)) throw new TypingError("macro decode: expected class field ref", curPos);
		return cfieldRefs.get(handle);
	}

	static function decodeTConstValue(ec:EvalContext, v:EvalValue):TConstant {
		var args = eargs(v);
		return switch (ctorName(ec, v)) {
			case "TInt": switch (args[0]) { case VInt(i): TInt(i); case _: throw new TypingError("macro decode: expected int", curPos); };
			case "TFloat": TFloat(strOf(args[0]));
			case "TString": TString(strOf(args[0]));
			case "TBool": TBool(boolOf(args[0]));
			case "TNull": TNull;
			case "TThis": TThis;
			case "TSuper": TSuper;
			case other: throw new TypingError("macro decode: unhandled TConstant " + other, curPos);
		};
	}

	// Resolve the constructor by name on the enum of the field's type.
	static function decodeEnumFieldValue(ec:EvalContext, v:EvalValue):TEnumField {
		var name = strOf(EvalField.field(ec, v, EvalHash.hash("name")));
		function getEnum(t:T):Null<TEnum> {
			return switch (TypeFunctions.follow(t)) {
				case TEnum(en, _): en;
				case TFun(sig): getEnum(sig.ret);
				case _: null;
			};
		}
		var en = getEnum(decodeType(ec, EvalField.field(ec, v, EvalHash.hash("type"))));
		var ef = en == null ? null : en.constrs.get(name);
		if (ef == null) throw new TypingError("macro decode: unknown enum field " + name, curPos);
		return ef;
	}

	static function decodeFieldAccessValue(ec:EvalContext, v:EvalValue):TFieldAccess {
		var args = eargs(v);
		return switch (ctorName(ec, v)) {
			case "FInstance": switch (moduleTypeFromRef(ec, args[0])) {
				case TClassDecl(c): FInstance(c, [for (p in arrOf(args[1])) decodeType(ec, p)], classFieldFromRef(ec, args[2]));
				case _: throw new TypingError("macro decode: expected class ref", curPos);
			}
			case "FStatic": switch (moduleTypeFromRef(ec, args[0])) {
				case TClassDecl(c): FStatic(c, classFieldFromRef(ec, args[1]));
				case _: throw new TypingError("macro decode: expected class ref", curPos);
			}
			case "FAnon": FAnon(classFieldFromRef(ec, args[0]));
			case "FDynamic": FDynamic(strOf(args[0]));
			case "FClosure":
				var co:Null<TClassWithParams> = if (args[0] == VNull) null else switch (moduleTypeFromRef(ec, EvalField.field(ec, args[0], EvalHash.hash("c")))) {
					case TClassDecl(c): {c: c, params: [for (p in arrOf(EvalField.field(ec, args[0], EvalHash.hash("params")))) decodeType(ec, p)]};
					case _: throw new TypingError("macro decode: expected class ref", curPos);
				};
				FClosure(co, classFieldFromRef(ec, args[1]));
			case "FEnum": switch (moduleTypeFromRef(ec, args[0])) {
				case TEnumDecl(e): FEnum(e, decodeEnumFieldValue(ec, args[1]));
				case _: throw new TypingError("macro decode: expected enum ref", curPos);
			}
			case other: throw new TypingError("macro decode: unhandled FieldAccess " + other, curPos);
		};
	}

	static function decodeModuleTypeValue(ec:EvalContext, v:EvalValue):ModuleType {
		var args = eargs(v);
		return switch (ctorName(ec, v)) {
			case "TClassDecl" | "TEnumDecl" | "TTypeDecl" | "TAbstract": moduleTypeFromRef(ec, args[0]);
			case other: throw new TypingError("macro decode: unhandled ModuleType " + other, curPos);
		};
	}

	static function decodeTFuncValue(ec:EvalContext, v:EvalValue):TFunc {
		var fnArgs:Array<TFuncArg> = [for (av in arrOf(EvalField.field(ec, v, EvalHash.hash("args")))) {
			var value = EvalField.field(ec, av, EvalHash.hash("value"));
			{v: decodeTVar(ec, EvalField.field(ec, av, EvalHash.hash("v"))), c: value == VNull ? null : decodeTypedExpr(ec, value)};
		}];
		return new TFunc(fnArgs, decodeType(ec, EvalField.field(ec, v, EvalHash.hash("t"))), decodeTypedExpr(ec, EvalField.field(ec, v, EvalHash.hash("expr"))));
	}

	public static function decodeTypedExpr(ec:EvalContext, v:EvalValue):TExpr {
		var p = posOf(ec, EvalField.field(ec, v, EvalHash.hash("pos")), curPos);
		var t = decodeType(ec, EvalField.field(ec, v, EvalHash.hash("t")));
		var ed = decodeTypedExprDef(ec, EvalField.field(ec, v, EvalHash.hash("expr")), p);
		return TypeFunctions.mk(ed, t, p);
	}

	static function decodeTypedExprDef(ec:EvalContext, e:EvalValue, p:Position):TExprExpr {
		var args = eargs(e);
		inline function loop(x:EvalValue):TExpr return decodeTypedExpr(ec, x);
		return switch (ctorName(ec, e)) {
			case "TConst": TConst(decodeTConstValue(ec, args[0]));
			case "TLocal": TLocal(decodeTVar(ec, args[0]));
			case "TArray": TArray(loop(args[0]), loop(args[1]));
			case "TBinop": TBinop(decodeBinop(ec, args[0]), loop(args[1]), loop(args[2]));
			case "TField": TField(loop(args[0]), decodeFieldAccessValue(ec, args[1]));
			case "TTypeExpr": TTypeExpr(decodeModuleTypeValue(ec, args[0]));
			case "TParenthesis": TParenthesis(loop(args[0]));
			case "TObjectDecl": TObjectDecl([for (fv in arrOf(args[0]))
				{key: {name: strOf(EvalField.field(ec, fv, EvalHash.hash("name"))), pos: p, quotes: NoQuotes}, expr: loop(EvalField.field(ec, fv, EvalHash.hash("expr")))}]);
			case "TArrayDecl": TArrayDecl([for (x in arrOf(args[0])) loop(x)]);
			case "TCall": TCall(loop(args[0]), [for (x in arrOf(args[1])) loop(x)]);
			case "TNew": switch (moduleTypeFromRef(ec, args[0])) {
				case TClassDecl(c): TNew(c, [for (x in arrOf(args[1])) decodeType(ec, x)], [for (x in arrOf(args[2])) loop(x)]);
				case _: throw new TypingError("macro decode: expected class ref", curPos);
			}
			case "TUnop": TUnop(decodeUnop(ec, args[0]), boolOf(args[1]) ? Postfix : Prefix, loop(args[2]));
			case "TFunction": TFunction(decodeTFuncValue(ec, args[0]));
			case "TVar": TVarExpr(decodeTVar(ec, args[0]), args[1] == VNull ? null : loop(args[1]));
			case "TBlock": TBlock([for (x in arrOf(args[0])) loop(x)]);
			case "TFor": TFor(decodeTVar(ec, args[0]), loop(args[1]), loop(args[2]));
			case "TIf": TIf(loop(args[0]), loop(args[1]), args[2] == VNull ? null : loop(args[2]));
			case "TWhile": TWhile(loop(args[0]), loop(args[1]), boolOf(args[2]) ? NormalWhile : DoWhile);
			case "TSwitch": TSwitch(loop(args[0]), [for (cv in arrOf(args[1]))
				{values: [for (x in arrOf(EvalField.field(ec, cv, EvalHash.hash("values")))) loop(x)], expr: loop(EvalField.field(ec, cv, EvalHash.hash("expr")))}], args[2] == VNull ? null : loop(args[2]));
			case "TTry": TTry(loop(args[0]), [for (cv in arrOf(args[1]))
				{v: decodeTVar(ec, EvalField.field(ec, cv, EvalHash.hash("v"))), expr: loop(EvalField.field(ec, cv, EvalHash.hash("expr")))}]);
			case "TReturn": TReturn(args[0] == VNull ? null : loop(args[0]));
			case "TBreak": TBreak;
			case "TContinue": TContinue;
			case "TThrow": TThrow(loop(args[0]));
			case "TCast": TCast(loop(args[0]), args[1] == VNull ? null : decodeModuleTypeValue(ec, args[1]));
			case "TMeta": TMeta(decodeMetadataEntry(ec, args[0], p), loop(args[1]));
			case "TEnumParameter": TEnumParameter(loop(args[0]), decodeEnumFieldValue(ec, args[1]), switch (args[2]) { case VInt(i): i; case _: throw new TypingError("macro decode: expected int", curPos); });
			case "TEnumIndex": TEnumIndex(loop(args[0]));
			case "TIdent": TIdent(strOf(args[0]));
			case other: throw new TypingError("macro decode: unhandled TypedExprDef " + other, curPos);
		};
	}

	// Type an expression on behalf of Context.typeof / typeExpr / storeExpr. A statement error inside a
	// block is recorded as a diagnostic by typeBlock's recovery instead of thrown, but a macro's typeExpr
	// has to propagate that error to the caller so the macro can catch it. Surface the first new error
	// diagnostic as a throw (the builtin wrapper turns it into a catchable haxe.macro.Error) and roll the
	// trial diagnostics back so a caught error does not leak into the final compiler output.
	static function typeMacroExpr(ctx:TyperContext, e:Expr):TExpr {
		var com = ctx.com;
		var before = com.diagnostics.length;
		var oldRaise = com.raiseTypingErrors;
		// Typing an expression is typingTimer with the type needed.
		var oldPass = needTypePass(com, true);
		com.raiseTypingErrors = true;
		// typingTimer turns the report off for the whole API call, so an expression the MACRO asked to type
		// reports back to the macro (which usually means a `catch`) rather than becoming a finding about
		// the file being reported on.
		var restoreReport = com.disableReportMode();
		var te = try Typer.typeExpr(ctx, e, WithTypeTools.value) catch (err:haxe.Exception) {
			com.raiseTypingErrors = oldRaise;
			com.currentPass = oldPass;
			restoreReport();
			if (com.diagnostics.length > before) com.diagnostics.resize(before);
			throw err;
		};
		com.raiseTypingErrors = oldRaise;
		com.currentPass = oldPass;
		restoreReport();
		// Fallback for a path that records into diagnostics directly (bypassing addDiagnostic): surface
		// the first new error and roll the trial diagnostics back.
		var i = before;
		while (i < com.diagnostics.length) {
			var d = com.diagnostics[i];
			if (d.severity == hxc.core.Globals.MessageSeverity.Error) {
				com.diagnostics.resize(before);
				throw new TypingError(d.message, d.pos, d.depth);
			}
			i++;
		}
		return te;
	}

	// EField's kind is an optional arg: a null (omitted) third slot means Normal, matching Expr.hx.
	static function decodeEFieldKind(ec:EvalContext, v:EvalValue):EFieldKind {
		return switch (v) {
			case VEnumValue(_): ctorName(ec, v) == "Safe" ? EFSafe : EFNormal;
			case _: EFNormal;
		};
	}

	static function decodeExprDef(ec:EvalContext, v:EvalValue, dp:Position):ExprDef {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "EConst": EConst(decodeConstant(ec, a[0]));
			case "EArray": EArray(decodeExpr(ec, a[0], dp), decodeExpr(ec, a[1], dp));
			case "EBinop": EBinop(decodeBinop(ec, a[0]), decodeExpr(ec, a[1], dp), decodeExpr(ec, a[2], dp));
			case "EField": EField(decodeExpr(ec, a[0], dp), strOf(a[1]), decodeEFieldKind(ec, a[2]));
			case "EParenthesis": EParenthesis(decodeExpr(ec, a[0], dp));
			case "EDisplay": EDisplay(decodeExpr(ec, a[0], dp), decodeDisplayKind(ec, a[1]));
			case "EObjectDecl": EObjectDecl([for (f in arrOf(a[0])) decodeObjField(ec, f, dp)]);
			case "EArrayDecl": EArrayDecl([for (e in arrOf(a[0])) decodeExpr(ec, e, dp)]);
			case "ECall": ECall(decodeExpr(ec, a[0], dp), [for (e in arrOf(a[1])) decodeExpr(ec, e, dp)]);
			case "EUnop": EUnop(decodeUnop(ec, a[0]), boolOf(a[1]) ? Postfix : Prefix, decodeExpr(ec, a[2], dp));
			case "EIf": EIf(decodeExpr(ec, a[0], dp), decodeExpr(ec, a[1], dp), decodeExprOpt(ec, a[2], dp));
			case "EReturn": EReturn(decodeExprOpt(ec, a[0], dp));
			case "EBlock": EBlock([for (e in arrOf(a[0])) decodeExpr(ec, e, dp)]);
			case "EVars": EVars([for (vv in arrOf(a[0])) decodeVar(ec, vv, dp)]);
			case "EThrow": EThrow(decodeExpr(ec, a[0], dp));
			case "EMeta": EMeta(decodeMetadataEntry(ec, a[0], dp), decodeExpr(ec, a[1], dp));
			case "ENew": ENew(decodePlacedTypePath(ec, a[0]), [for (e in arrOf(a[1])) decodeExpr(ec, e, dp)]);
			case "EFunction": EFunction(decodeFunctionKind(ec, a[0], dp), decodeFunc(ec, a[1], dp));
			case "EFor": EFor(decodeExpr(ec, a[0], dp), decodeExpr(ec, a[1], dp));
			case "EWhile": EWhile(decodeExpr(ec, a[0], dp), decodeExpr(ec, a[1], dp), boolOf(a[2]) ? NormalWhile : DoWhile);
			case "ESwitch": ESwitch(decodeExpr(ec, a[0], dp), [for (c in arrOf(a[1])) decodeCase(ec, c, dp)], a[2] == VNull ? null : {e: decodeExpr(ec, a[2], dp), pos: dp});
			case "ETry": ETry(decodeExpr(ec, a[0], dp), [for (c in arrOf(a[1])) decodeCatch(ec, c, dp)]);
			case "EBreak": EBreak;
			case "EContinue": EContinue;
			case "EUntyped": EUntyped(decodeExpr(ec, a[0], dp));
			case "ETernary": ETernary(decodeExpr(ec, a[0], dp), decodeExpr(ec, a[1], dp), decodeExpr(ec, a[2], dp));
			case "ECast": ECast(decodeExpr(ec, a[0], dp), a[1] == VNull ? null : decodeTypeHint(ec, a[1], dp));
			case "EIs": EIs(decodeExpr(ec, a[0], dp), decodeTypeHint(ec, a[1], dp));
			case "ECheckType": ECheckType(decodeExpr(ec, a[0], dp), decodeTypeHint(ec, a[1], dp));
			case other: throw new TypingError("Macro decode: unhandled ExprDef " + other, dp);
		};
	}

	static function decodeFunctionKind(ec:EvalContext, v:EvalValue, dp:Position):FunctionKind {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "FNamed": FKNamed({name: strOf(a[0]), pos: dp}, a.length > 1 && boolOf(a[1]));
			case "FArrow": FKArrow;
			case _: FKAnonymous;
		};
	}

	static function decodeCase(ec:EvalContext, v:EvalValue, dp:Position):SwitchCase {
		return {
			values: [for (x in arrOf(EvalField.field(ec, v, EvalHash.hash("values")))) decodeExpr(ec, x, dp)],
			guard: decodeExprOpt(ec, EvalField.field(ec, v, EvalHash.hash("guard")), dp),
			expr: decodeExprOpt(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp),
			// Read the hidden pos field, the null position when a macro built the case object without it
			// (the match then falls back to the body position).
			pos: posMaybe(ec, EvalField.field(ec, v, EvalHash.hash("pos")))
		};
	}

	static function decodeCatch(ec:EvalContext, v:EvalValue, dp:Position):Catch {
		var tv = EvalField.field(ec, v, EvalHash.hash("type"));
		// name_pos and pos both fall back to the null position - not to the enclosing expression, which is
		// the separate default a field's pos uses. haxe.macro.Expr.Catch has neither field, so a reified
		// catch always takes the fallback: hxparse builds every `switch stream` arm as `macro
		// @:pos(pat.pos) { try ... catch (_:NoMatch) ... }`, and the catch variable carries a NULL position
		// all the way to the generator, where the empty block the exceptions filter emits for an unused
		// catch variable prints at line 1. Falling back to the enclosing position would put it on the
		// switch line and shift the line markers after it.
		return {
			name: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))), pos: posMaybe(ec, EvalField.field(ec, v, EvalHash.hash("name_pos")))},
			type: tv == VNull ? null : decodeTypeHint(ec, tv, dp),
			expr: decodeExpr(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp),
			pos: posMaybe(ec, EvalField.field(ec, v, EvalHash.hash("pos")))
		};
	}

	static function decodeTypeHint(ec:EvalContext, v:EvalValue, dp:Position):TypeHint {
		// Read the position the encoder attached to the value.
		var p = switch (EvalValueTools.vresolve(v)) {
			case VEnumValue(ev) if (ev.enpos != null): ev.enpos;
			case _: dp;
		};
		return {ct: decodeComplexType(ec, v, dp), pos: p};
	}

	static function decodeComplexType(ec:EvalContext, v:EvalValue, dp:Position):ComplexType {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "TPath": CTPath(decodeTypePath(ec, a[0]));
			case "TFunction": CTFunction([for (x in arrOf(a[0])) decodeTypeHint(ec, x, dp)], decodeTypeHint(ec, a[1], dp));
			case "TAnonymous": CTAnonymous([for (f in arrOf(a[0])) decodeField(ec, f, dp)]);
			case "TParent": CTParent(decodeTypeHint(ec, a[0], dp));
			case "TOptional": CTOptional(decodeTypeHint(ec, a[0], dp));
			case "TNamed": CTNamed({name: strOf(a[0]), pos: dp}, decodeTypeHint(ec, a[1], dp));
			case "TExtend": CTExtend([for (p in arrOf(a[0])) decodePlacedTypePath(ec, p)], [for (f in arrOf(a[1])) decodeField(ec, f, dp)]);
			case "TIntersection": CTIntersection([for (x in arrOf(a[0])) decodeTypeHint(ec, x, dp)]);
			case other: throw new TypingError("Macro decode: unhandled ComplexType " + other, dp);
		};
	}

	static function decodeObjField(ec:EvalContext, v:EvalValue, dp:Position):ObjectField {
		// Quotes is an optional QuoteStatus (Unquoted = 0, Quoted = 1); a quoted key must survive the
		// macro round-trip or the generator emits its raw name (issue seen via the utest TestBuilder
		// build macro re-encoding every test body).
		var quotes:QuoteStatus = switch (EvalField.field(ec, v, EvalHash.hash("quotes"))) {
			case VEnumValue(ev) if (ev.eindex == 1): DoubleQuotes;
			case _: NoQuotes;
		};
		// Takes the field's own name_pos; a macro that builds an object field by hand may omit it, and
		// decode_placed_name then falls back to the enclosing position, which is what dp is here. uses
		// maybe_decode_pos, which swallows Invalid_expr and yields null_pos: a macro that builds an
		// object field by hand has no name_pos, and the STRICT decode_pos would fail the whole
		// Array<Field>.
		var np = try posOf(ec, EvalField.field(ec, v, EvalHash.hash("name_pos")), dp)
			catch (_:Dynamic) Position.nullPos;
		return {name: strOf(EvalField.field(ec, v, EvalHash.hash("field"))), pos: np, quotes: quotes, expr: decodeExpr(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp)};
	}

	static function decodeVar(ec:EvalContext, v:EvalValue, dp:Position):EVar {
		return {
			// A missing name_pos defaults to p.
			evName: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))), pos: posDefault(ec, EvalField.field(ec, v, EvalHash.hash("namePos")), dp)},
			evFinal: boolOf(EvalField.field(ec, v, EvalHash.hash("isFinal"))),
			evStatic: boolOf(EvalField.field(ec, v, EvalHash.hash("isStatic"))),
			evType: { var tv = EvalField.field(ec, v, EvalHash.hash("type")); tv == VNull ? null : decodeTypeHint(ec, tv, dp); },
			evExpr: decodeExprOpt(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp),
			evMeta: { var mv = EvalField.field(ec, v, EvalHash.hash("meta")); mv == VNull ? [] : [for (m in arrOf(mv)) decodeMetadataEntry(ec, m, dp)]; }
		};
	}

	static function decodeField(ec:EvalContext, v:EvalValue, dp:Position):ClassField {
		var name = strOf(EvalField.field(ec, v, EvalHash.hash("name")));
		// The field's own pos (used for the field position and, unless the field gives its own name_pos,
		// the name position). A macro-built field carries its real source pos here; dp is only the fallback
		// when the field omits pos.
		var pos = posOf(ec, EvalField.field(ec, v, EvalHash.hash("pos")), dp);
		// The modifier's position is the enum VALUE's own (the null position without one), so a modifier
		// the macro wrote reports inside haxe/macro/Expr.hx, where its constructor is declared.
		var access = [for (av in arrOf(EvalField.field(ec, v, EvalHash.hash("access")))) ({access: decodeAccess(ec, av),
			pos: switch (av) { case VEnumValue(ev) if (ev.enpos != null): ev.enpos; case _: Position.nullPos; }} : PlacedAccess)];
		var kind = decodeFieldKind(ec, EvalField.field(ec, v, EvalHash.hash("kind")), pos);
		var meta = decodeMetadata(ec, EvalField.field(ec, v, EvalHash.hash("meta")), pos);
		// `name_pos`, defaulting to the field's pos.
		var namePos = posDefault(ec, EvalField.field(ec, v, EvalHash.hash("name_pos")), pos);
		return new ClassField({name: name, pos: namePos}, decodeDoc(EvalField.field(ec, v, EvalHash.hash("doc"))), pos, meta, access, kind);
	}

	// The string becomes the doc's own text, with nothing inherited.
	static function decodeDoc(v:EvalValue):Documentation {
		return v == VNull ? null : Ast.docFromString(strOf(v));
	}

	static function decodeMetadata(ec:EvalContext, v:EvalValue, dp:Position):Metadata {
		return v == VNull ? [] : [for (mv in arrOf(v)) decodeMetadataEntry(ec, mv, dp)];
	}

	static function decodeMetadataEntry(ec:EvalContext, v:EvalValue, dp:Position):MetadataEntry {
		var name = strOf(EvalField.field(ec, v, EvalHash.hash("name")));
		var pv = EvalField.field(ec, v, EvalHash.hash("params"));
		var params = pv == VNull ? [] : [for (pe in arrOf(pv)) decodeExpr(ec, pe, dp)];
		return {name: name, params: params, pos: posOf(ec, EvalField.field(ec, v, EvalHash.hash("pos")), dp)};
	}

	static function decodeAccess(ec:EvalContext, v:EvalValue):Access {
		return switch (ctorName(ec, v)) {
			case "APublic": APublic; case "APrivate": APrivate; case "AStatic": AStatic; case "AOverride": AOverride;
			case "ADynamic": ADynamic; case "AInline": AInline; case "AMacro": AMacro; case "AFinal": AFinal;
			case "AExtern": AExtern; case "AAbstract": AAbstract; case "AOverload": AOverload;
			case other: throw new DecodeFailure("Unexpected value " + Std.string(other) + ", expected Access");
		};
	}

	static function decodeFieldKind(ec:EvalContext, v:EvalValue, dp:Position):ClassFieldKind {
		var a = eargs(v);
		// A property's accessor names carry the null position.
		return switch (ctorName(ec, v)) {
			case "FVar": FVar((a.length > 0 && a[0] != VNull) ? decodeTypeHint(ec, a[0], dp) : null, decodeExprOpt(ec, a.length > 1 ? a[1] : VNull, dp));
			case "FFun": FFun(decodeFunc(ec, a[0], dp));
			case "FProp": FProp({name: strOf(a[0]), pos: Position.nullPos}, {name: strOf(a[1]), pos: Position.nullPos}, (a.length > 2 && a[2] != VNull) ? decodeTypeHint(ec, a[2], dp) : null, decodeExprOpt(ec, a.length > 3 ? a[3] : VNull, dp));
			case other: throw new DecodeFailure("Unexpected value " + Std.string(other) + ", expected FieldType");
		};
	}

	static function decodeFunc(ec:EvalContext, v:EvalValue, dp:Position):Func {
		// `args` decodes as an array: a null is an invalid expression.
		var argsV = EvalField.field(ec, v, EvalHash.hash("args"));
		if (argsV == VNull) throw new DecodeFailure("Invalid expression");
		var args = [for (av in arrOf(argsV)) decodeFunctionArg(ec, av, dp)];
		var retV = EvalField.field(ec, v, EvalHash.hash("ret"));
		return {fParams: decodeTparams(ec, EvalField.field(ec, v, EvalHash.hash("params")), dp), fArgs: args, fType: retV == VNull ? null : decodeTypeHint(ec, retV, dp), fExpr: decodeExprOpt(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp)};
	}

	// Type parameters decode as an optional array (null array -> empty).
	static function decodeTparams(ec:EvalContext, v:EvalValue, dp:Position):Array<TypeParam> {
		return v == VNull ? [] : [for (x in arrOf(v)) decodeTparamDecl(ec, x, dp)];
	}

	// A type parameter declaration. constraints: [] -> none, [t] -> single, many -> CTIntersection.
	static function decodeTparamDecl(ec:EvalContext, v:EvalValue, dp:Position):TypeParam {
		var vconstraints = EvalField.field(ec, v, EvalHash.hash("constraints"));
		var vdefault = EvalField.field(ec, v, EvalHash.hash("defaultType"));
		var constraints:Null<TypeHint> = if (vconstraints == VNull) null else {
			var arr = arrOf(vconstraints);
			switch (arr.length) {
				case 0: null;
				case 1: decodeTypeHint(ec, arr[0], dp);
				case _: {ct: CTIntersection([for (t in arr) decodeTypeHint(ec, t, dp)]), pos: Position.nullPos};
			}
		};
		return {
			tpName: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))), pos: dp},
			tpParams: decodeTparams(ec, EvalField.field(ec, v, EvalHash.hash("params")), dp),
			tpConstraints: constraints,
			tpDefault: vdefault == VNull ? null : decodeTypeHint(ec, vdefault, dp),
			tpMeta: []
		};
	}

	static function decodeFunctionArg(ec:EvalContext, v:EvalValue, dp:Position):FunctionArg {
		var typeV = EvalField.field(ec, v, EvalHash.hash("type"));
		return {
			// haxe.macro.Expr.FunctionArg has no name_pos field, so the fallback is always taken: the
			// enclosing expression's position, the same rule the EVars arm spells out. A macro returning
			// EFunction with an invalid argument name then reports at the macro call position, where a null
			// fallback would print the error with no position at all.
			name: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))),
				pos: posDefault(ec, EvalField.field(ec, v, EvalHash.hash("name_pos")), dp)},
			opt: boolOf(EvalField.field(ec, v, EvalHash.hash("opt"))),
			meta: decodeMetadata(ec, EvalField.field(ec, v, EvalHash.hash("meta")), dp),
			type: typeV == VNull ? null : decodeTypeHint(ec, typeV, dp),
			value: decodeExprOpt(ec, EvalField.field(ec, v, EvalHash.hash("value")), dp)
		};
	}

	// The path's own pos, the null position when the object has none.
	static function decodePlacedTypePath(ec:EvalContext, v:EvalValue):PlacedTypePath {
		var pv = EvalField.field(ec, v, EvalHash.hash("pos"));
		return {path: decodeTypePath(ec, v), pos: pv == VNull ? Position.nullPos : posOf(ec, pv, Position.nullPos)};
	}

	static function decodeTypePath(ec:EvalContext, v:EvalValue):TypePath {
		var sub = EvalField.field(ec, v, EvalHash.hash("sub"));
		return {
			tpackage: [for (s in arrOf(EvalField.field(ec, v, EvalHash.hash("pack")))) strOf(s)],
			tname: strOf(EvalField.field(ec, v, EvalHash.hash("name"))),
			tparams: [for (x in arrOf(EvalField.field(ec, v, EvalHash.hash("params")))) decodeTypeParam(ec, x, Position.nullPos)],
			tsub: sub == VNull ? null : strOf(sub)
		};
	}

	static function decodeTypeParam(ec:EvalContext, v:EvalValue, dp:Position):TypeParamOrConst {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "TPExpr": TPExpr(decodeExpr(ec, a[0], dp));
			case _: TPType(decodeTypeHint(ec, a[0], dp));
		};
	}

	// An import is a tuple, so the mode decodes first; each path part carries its own position (pos before
	// name), and an alias's is lost (the null position). The declaration sits at defineModule's position.
	static function decodeImport(ec:EvalContext, v:EvalValue, dp:Position):Import {
		var modeV = EvalField.field(ec, v, EvalHash.hash("mode"));
		var mode:ImportMode = switch (ctorName(ec, modeV)) {
			case "IAll": ImportMode.IAll;
			case "IAsName": ImportMode.IAsName({name: strOf(eargs(modeV)[0]), pos: Position.nullPos});
			case _: ImportMode.INormal;
		};
		var path = [for (pv in arrOf(EvalField.field(ec, v, EvalHash.hash("path")))) {
			var pp = posOf(ec, EvalField.field(ec, pv, EvalHash.hash("pos")), dp);
			({name: strOf(EvalField.field(ec, pv, EvalHash.hash("name"))), pos: pp} : PlacedName);
		}];
		return {path: path, mode: mode, pos: dp};
	}

	static function encodeImportExpr(ec:EvalContext, imp:Import):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("path"), encodeArray([for (pn in imp.path) encodeImportPathPart(ec, pn)]));
		fields.set(EvalHash.hash("mode"), encodeImportMode(ec, imp.mode));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeImportPathPart(ec:EvalContext, pn:PlacedName):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(pn.name));
		fields.set(EvalHash.hash("pos"), encPos(pn.pos));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeImportMode(ec:EvalContext, mode:ImportMode):EvalValue {
		return switch (mode) {
			case INormal:
				mkEnumValue(ec, "ImportMode", "INormal", []);
			case IAsName(alias):
				mkEnumValue(ec, "ImportMode", "IAsName", [mkString(alias.name)]);
			case IAll:
				mkEnumValue(ec, "ImportMode", "IAll", []);
		}
	}

	static function decodeClassFlags(ec:EvalContext, kind:EvalValue, isExtern:Bool, dp:Position):Array<ClassFlag> {
		var flags:Array<ClassFlag> = [];
		if (isExtern) flags.push(HExtern);
		switch (ctorName(ec, kind)) {
			case "TDClass":
				var a = eargs(kind);
				// An interface's implements-slot entries are its extended interfaces.
				var isInterface = a.length > 2 && boolOf(a[2]);
				if (a.length > 0 && a[0] != VNull) flags.push(HExtends({path: decodeTypePath(ec, a[0]), pos: dp}));
				if (a.length > 1 && a[1] != VNull) for (iv in arrOf(a[1]))
					flags.push(isInterface ? HExtends({path: decodeTypePath(ec, iv), pos: dp}) : HImplements({path: decodeTypePath(ec, iv), pos: dp}));
				if (isInterface) flags.push(HInterface);
				if (a.length > 3 && boolOf(a[3])) flags.push(HFinal);
				if (a.length > 4 && boolOf(a[4])) flags.push(HAbstract);
			case other: throw new TypingError("defineModule supports only TDClass, got " + other, dp);
		}
		return flags;
	}

	static function decodeAbstractFlags(ec:EvalContext, kind:EvalValue, isExtern:Bool, dp:Position):Array<AbstractFlag> {
		var flags:Array<AbstractFlag> = [];
		var a = eargs(kind);
		if (a.length > 0 && a[0] != VNull) flags.push(AbOver(decodeTypeHint(ec, a[0], dp)));
		if (a.length > 1 && a[1] != VNull) for (fv in arrOf(a[1])) switch (ctorName(ec, fv)) {
			case "AbEnum":
				flags.push(AbEnum);
			case "AbFrom":
				flags.push(AbFrom(decodeTypeHint(ec, eargs(fv)[0], dp)));
			case "AbTo":
				flags.push(AbTo(decodeTypeHint(ec, eargs(fv)[0], dp)));
			case _:
				flags.push(AbFrom(decodeTypeHint(ec, fv, dp)));
		}
		if (a.length > 2 && a[2] != VNull) for (fv in arrOf(a[2])) flags.push(AbFrom(decodeTypeHint(ec, fv, dp)));
		if (a.length > 3 && a[3] != VNull) for (tv in arrOf(a[3])) flags.push(AbTo(decodeTypeHint(ec, tv, dp)));
		if (isExtern) flags.push(AbExtern);
		return flags;
	}

	static function decodeTypeDefinition(ec:EvalContext, v:EvalValue, dp:Position):TypeDecl {
		var name = strOf(EvalField.field(ec, v, EvalHash.hash("name")));
		// The definition's own pos becomes the type's pos (so a synthesized constructor lands on the
		// defining macro's position, not a null "?" frame).
		var pos = posOf(ec, EvalField.field(ec, v, EvalHash.hash("pos")), dp);
		var fields = [for (fv in arrOf(EvalField.field(ec, v, EvalHash.hash("fields")))) decodeField(ec, fv, pos)];
		var kind = EvalField.field(ec, v, EvalHash.hash("kind"));
		var isExtern = boolOf(EvalField.field(ec, v, EvalHash.hash("isExtern")));
		var params = decodeTparams(ec, EvalField.field(ec, v, EvalHash.hash("params")), pos);
		var meta = decodeMetadata(ec, EvalField.field(ec, v, EvalHash.hash("meta")), pos);
		var doc = decodeDoc(EvalField.field(ec, v, EvalHash.hash("doc")));
		return switch (ctorName(ec, kind)) {
			case "TDClass":
				var flags = decodeClassFlags(ec, kind, isExtern, pos);
				var def:Definition<ClassFlag, Array<ClassField>> = {dName: {name: name, pos: pos}, dDoc: doc, dParams: params, dMeta: meta, dFlags: flags, dData: fields};
				{decl: EClass(def), pos: pos};
			case "TDAbstract":
				var flags = decodeAbstractFlags(ec, kind, isExtern, pos);
				var def:Definition<AbstractFlag, Array<ClassField>> = {dName: {name: name, pos: pos}, dDoc: doc, dParams: params, dMeta: meta, dFlags: flags, dData: fields};
				{decl: EAbstract(def), pos: pos};
			case "TDEnum":
				// Each field converts to an enum constructor: a variable keeps no arguments, a function
				// requires typed arguments.
				var ctors:Array<hxc.ast.Ast.EnumConstructor> = [for (f in fields) {
					var eargs:Array<{name:String, opt:Bool, type:TypeHint}> = [];
					var eparams:Array<TypeParam> = [];
					var etype:Null<TypeHint> = null;
					switch (f.cffKind) {
						case FVar(t, null): etype = t;
						case FFun(fd):
							for (a in fd.fArgs) {
								if (a.type == null) throw new TypingError("Invalid expression", dp);
								eargs.push({name: a.name.name, opt: a.opt, type: a.type});
							}
							eparams = fd.fParams;
							etype = fd.fType;
						case _: throw new TypingError("Invalid expression", dp);
					}
					({ecName: f.cffName, ecDoc: f.cffDoc, ecMeta: f.cffMeta, ecArgs: eargs, ecPos: f.cffPos, ecParams: eparams, ecType: etype} : hxc.ast.Ast.EnumConstructor);
				}];
				var def:Definition<hxc.ast.Ast.EnumFlag, Array<hxc.ast.Ast.EnumConstructor>> = {dName: {name: name, pos: pos}, dDoc: doc, dParams: params, dMeta: meta, dFlags: isExtern ? [EExtern] : [], dData: ctors};
				{decl: EEnum(def), pos: pos};
			case "TDStructure":
				var def:Definition<hxc.ast.Ast.EnumFlag, TypeHint> = {dName: {name: name, pos: pos}, dDoc: doc, dParams: params, dMeta: meta, dFlags: isExtern ? [EExtern] : [], dData: {ct: CTAnonymous(fields), pos: pos}};
				{decl: ETypedef(def), pos: pos};
			case "TDAlias":
				var def:Definition<hxc.ast.Ast.EnumFlag, TypeHint> = {dName: {name: name, pos: pos}, dDoc: doc, dParams: params, dMeta: meta, dFlags: isExtern ? [EExtern] : [], dData: decodeTypeHint(ec, eargs(kind)[0], pos)};
				{decl: ETypedef(def), pos: pos};
			case "TDField":
				// A module-level field, its access list decoded like a field's.
				var a = eargs(kind);
				var fk = decodeFieldKind(ec, a[0], pos);
				var al = (a.length > 1 && a[1] != VNull) ? [for (av in arrOf(a[1])) ({access: decodeAccess(ec, av),
					pos: switch (av) { case VEnumValue(ev) if (ev.enpos != null): ev.enpos; case _: Position.nullPos; }} : PlacedAccess)] : [];
				var def:Definition<PlacedAccess, ClassFieldKind> = {dName: {name: name, pos: pos}, dDoc: doc, dParams: params, dMeta: meta, dFlags: al, dData: fk};
				{decl: EStatic(def), pos: pos};
			case other:
				throw new TypingError("Invalid expression", dp);
		};
	}

	static function decodeConstant(ec:EvalContext, v:EvalValue):Constant {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "CInt": CInt(strOf(a[0]), a.length > 1 ? strOpt(a[1]) : null);
			case "CFloat": CFloat(strOf(a[0]), a.length > 1 ? strOpt(a[1]) : null);
			case "CString":
				var kind = SDoubleQuotes;
				if (a.length > 1) switch (a[1]) { case VNull: case _: if (ctorName(ec, a[1]) == "SingleQuotes") kind = SSingleQuotes; }
				CString(strOf(a[0]), kind);
			case "CIdent": CIdent(strOf(a[0]));
			case "CRegexp": CRegexp(strOf(a[0]), strOf(a[1]));
			case other: throw new DecodeFailure("Unexpected value " + Std.string(other) + ", expected Constant");
		};
	}

	static function decodeBinop(ec:EvalContext, v:EvalValue):Binop {
		return switch (ctorName(ec, v)) {
			case "OpAdd": OpAdd; case "OpMult": OpMult; case "OpDiv": OpDiv; case "OpSub": OpSub; case "OpMod": OpMod;
			case "OpEq": OpEq; case "OpNotEq": OpNotEq; case "OpLt": OpLt; case "OpLte": OpLte; case "OpGt": OpGt; case "OpGte": OpGte;
			case "OpAnd": OpAnd; case "OpOr": OpOr; case "OpXor": OpXor; case "OpBoolAnd": OpBoolAnd; case "OpBoolOr": OpBoolOr;
			case "OpShl": OpShl; case "OpShr": OpShr; case "OpUShr": OpUShr;
			case "OpAssign": OpAssign; case "OpInterval": OpInterval; case "OpArrow": OpArrow; case "OpIn": OpIn;
			case "OpNullCoal": OpNullCoal;
			case "OpAssignOp": OpAssignOp(decodeBinop(ec, eargs(v)[0]));
			case other: throw new DecodeFailure("Unexpected value " + Std.string(other) + ", expected Binop");
		};
	}

	static function decodeUnop(ec:EvalContext, v:EvalValue):Unop {
		return switch (ctorName(ec, v)) {
			case "OpIncrement": Increment; case "OpDecrement": Decrement;
			case "OpNot": Not; case "OpNeg": Neg; case "OpNegBits": NegBits; case "OpSpread": Spread;
			case other: throw new DecodeFailure("Unexpected value " + Std.string(other) + ", expected Unop");
		};
	}


	static var enumCache:Map<String, TEnum> = new Map();

	static function findEnum(ec:EvalContext, name:String):TEnum {
		var cached = enumCache.get(name);
		if (cached != null) return cached;
		for (mt in ec.typeCache) switch (mt) {
			case TEnumDecl(en) if (en.path.name == name && en.path.pack.length == 2 && en.path.pack[0] == "haxe" && en.path.pack[1] == "macro"):
				enumCache.set(name, en);
				return en;
			case _:
		}
		throw "macro encode: enum not loaded: " + name;
	}

	static function mkEnumValue(ec:EvalContext, enumName:String, ctor:String, args:Array<EvalValue>):EvalValue {
		var en = findEnum(ec, enumName);
		var ef = en.constrs.get(ctor);
		if (ef == null) throw "macro encode: no constructor " + ctor + " in " + enumName;
		return VEnumValue(new VEnumValue(ef.index, args, EvalHash.pathHash(en.path), null));
	}

	// A missing doc is null, not an empty string.
	static function encodeDoc(s:Null<String>):EvalValue {
		return s == null ? VNull : mkString(s);
	}

	// The compiler's string as UTF-8 bytes (EvalString.createUnknown).
	static function mkString(s:String):EvalValue {
		if (s == null) return VNull;
		return hxc.eval.EvalString.EvalString.vOfText(s);
	}

	public static function encodeExpr(ec:EvalContext, e:Expr):EvalValue {
		var ed = encodeExprDef(ec, e.expr);
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("expr"), ed);
		fields.set(EvalHash.hash("pos"), encPos(e.pos));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeExprDef(ec:EvalContext, ed:ExprDef):EvalValue {
		return switch (ed) {
			case EConst(c): mkEnumValue(ec, "ExprDef", "EConst", [encodeConstant(ec, c)]);
			case EArray(e1, e2): mkEnumValue(ec, "ExprDef", "EArray", [encodeExpr(ec, e1), encodeExpr(ec, e2)]);
			case EBinop(op, e1, e2): mkEnumValue(ec, "ExprDef", "EBinop", [encodeBinop(ec, op), encodeExpr(ec, e1), encodeExpr(ec, e2)]);
			case EField(e1, f, k): mkEnumValue(ec, "ExprDef", "EField", [encodeExpr(ec, e1), mkString(f), mkEnumValue(ec, "EFieldKind", (k == EFSafe ? "Safe" : "Normal"), [])]);
			case EParenthesis(e1): mkEnumValue(ec, "ExprDef", "EParenthesis", [encodeExpr(ec, e1)]);
			case EArrayDecl(el): mkEnumValue(ec, "ExprDef", "EArrayDecl", [encodeArray([for (e in el) encodeExpr(ec, e)])]);
			case ECall(e1, el): mkEnumValue(ec, "ExprDef", "ECall", [encodeExpr(ec, e1), encodeArray([for (e in el) encodeExpr(ec, e)])]);
			case EUnop(op, flag, e1): mkEnumValue(ec, "ExprDef", "EUnop", [encodeUnop(ec, op), (switch (flag) { case Postfix: VTrue; case Prefix: VFalse; }), encodeExpr(ec, e1)]);
			case EIf(c, t, eo): mkEnumValue(ec, "ExprDef", "EIf", [encodeExpr(ec, c), encodeExpr(ec, t), eo == null ? VNull : encodeExpr(ec, eo)]);
			case EReturn(eo): mkEnumValue(ec, "ExprDef", "EReturn", [eo == null ? VNull : encodeExpr(ec, eo)]);
			case EBlock(el): mkEnumValue(ec, "ExprDef", "EBlock", [encodeArray([for (e in el) encodeExpr(ec, e)])]);
			case EVars(vl): mkEnumValue(ec, "ExprDef", "EVars", [encodeArray([for (v in vl) encodeVar(ec, v)])]);
			case EThrow(e1): mkEnumValue(ec, "ExprDef", "EThrow", [encodeExpr(ec, e1)]);
			case EObjectDecl(fl): mkEnumValue(ec, "ExprDef", "EObjectDecl", [encodeArray([for (f in fl) encodeObjField(ec, f)])]);
			case ENew(tp, el): mkEnumValue(ec, "ExprDef", "ENew", [encodeTypePath(ec, tp.path, tp.pos), encodeArray([for (e in el) encodeExpr(ec, e)])]);
			case EFunction(kind, f): mkEnumValue(ec, "ExprDef", "EFunction", [encodeFunctionKind(ec, kind), encodeFunc(ec, f)]);
			case EFor(it, e1): mkEnumValue(ec, "ExprDef", "EFor", [encodeExpr(ec, it), encodeExpr(ec, e1)]);
			case EWhile(c, e1, flag): mkEnumValue(ec, "ExprDef", "EWhile", [encodeExpr(ec, c), encodeExpr(ec, e1), (switch (flag) { case NormalWhile: VTrue; case DoWhile: VFalse; })]);
			case ESwitch(e1, cases, edef): mkEnumValue(ec, "ExprDef", "ESwitch", [encodeExpr(ec, e1), encodeArray([for (c in cases) encodeCase(ec, c)]), (edef == null || edef.e == null) ? VNull : encodeExpr(ec, edef.e)]);
			case ETry(e1, catches): mkEnumValue(ec, "ExprDef", "ETry", [encodeExpr(ec, e1), encodeArray([for (c in catches) encodeCatch(ec, c)])]);
			case EBreak: mkEnumValue(ec, "ExprDef", "EBreak", []);
			case EContinue: mkEnumValue(ec, "ExprDef", "EContinue", []);
			case EUntyped(e1): mkEnumValue(ec, "ExprDef", "EUntyped", [encodeExpr(ec, e1)]);
			case ETernary(c, t, e1): mkEnumValue(ec, "ExprDef", "ETernary", [encodeExpr(ec, c), encodeExpr(ec, t), encodeExpr(ec, e1)]);
			case EMeta(m, e1): mkEnumValue(ec, "ExprDef", "EMeta", [encodeMetadataEntry(ec, m), encodeExpr(ec, e1)]);
			case ECast(e1, th): mkEnumValue(ec, "ExprDef", "ECast", [encodeExpr(ec, e1), th == null ? VNull : encodeComplexType(ec, th)]);
			case EIs(e1, th): mkEnumValue(ec, "ExprDef", "EIs", [encodeExpr(ec, e1), encodeComplexType(ec, th)]);
			case ECheckType(e1, th): mkEnumValue(ec, "ExprDef", "ECheckType", [encodeExpr(ec, e1), encodeComplexType(ec, th)]);
			// A display node encodes as ITSELF, kind and all - a macro can match on it and build one.
			case EDisplay(e1, dk): mkEnumValue(ec, "ExprDef", "EDisplay", [encodeExpr(ec, e1), encodeDisplayKind(ec, dk)]);
			case _: throw "macro encode: unhandled ExprDef";
		};
	}

	static function encodeDisplayKind(ec:EvalContext, dk:hxc.ast.Ast.DisplayKind):EvalValue {
		return switch (dk) {
			case DKCall: mkEnumValue(ec, "DisplayKind", "DKCall", []);
			case DKDot: mkEnumValue(ec, "DisplayKind", "DKDot", []);
			case DKStructure: mkEnumValue(ec, "DisplayKind", "DKStructure", []);
			case DKMarked: mkEnumValue(ec, "DisplayKind", "DKMarked", []);
			case DKPattern(outermost): mkEnumValue(ec, "DisplayKind", "DKPattern", [outermost ? VTrue : VFalse]);
		};
	}

	static function decodeDisplayKind(ec:EvalContext, v:EvalValue):hxc.ast.Ast.DisplayKind {
		return switch (ctorName(ec, v)) {
			case "DKCall": DKCall;
			case "DKDot": DKDot;
			case "DKStructure": DKStructure;
			case "DKPattern": DKPattern(eargs(v)[0] == VTrue);
			case _: DKMarked;
		};
	}

	static function encodeVar(ec:EvalContext, ev:EVar):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(ev.evName.name));
		fields.set(EvalHash.hash("namePos"), encPos(ev.evName.pos));
		fields.set(EvalHash.hash("isFinal"), ev.evFinal ? VTrue : VFalse);
		fields.set(EvalHash.hash("isStatic"), ev.evStatic ? VTrue : VFalse);
		fields.set(EvalHash.hash("type"), ev.evType == null ? VNull : encodeComplexType(ec, ev.evType));
		fields.set(EvalHash.hash("expr"), ev.evExpr == null ? VNull : encodeExpr(ec, ev.evExpr));
		fields.set(EvalHash.hash("meta"), encodeArray([for (m in ev.evMeta) encodeMetadataEntry(ec, m)]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeField(ec:EvalContext, f:ClassField):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(f.cffName.name));
		// `name_pos` carries the placed name's position, and decoding the field restores it, so a field a
		// build macro hands back unchanged keeps its name where the parser put it - which the build's
		// placed-name equality check relies on.
		fields.set(EvalHash.hash("name_pos"), encPos(f.cffName.pos));
		fields.set(EvalHash.hash("doc"), encodeDoc(Ast.genDocTextOpt(f.cffDoc)));
		fields.set(EvalHash.hash("access"), encodeArray([for (pa in f.cffAccess) encodeAccess(ec, pa.access, pa.pos)]));
		fields.set(EvalHash.hash("kind"), encodeFieldKind(ec, f.cffKind));
		fields.set(EvalHash.hash("pos"), encPos(f.cffPos));
		fields.set(EvalHash.hash("meta"), encodeArray([for (m in f.cffMeta) encodeMetadataEntry(ec, m)]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	// A modifier keeps its position through a build's round trip, so a duplicate reports where it was
	// written.
	static function encodeAccess(ec:EvalContext, a:Access, ?pos:Position):EvalValue {
		var name = switch (a) {
			case APublic: "APublic"; case APrivate: "APrivate"; case AStatic: "AStatic"; case AOverride: "AOverride";
			case ADynamic: "ADynamic"; case AInline: "AInline"; case AMacro: "AMacro"; case AFinal: "AFinal";
			case AExtern: "AExtern"; case AAbstract: "AAbstract"; case AOverload: "AOverload";
		};
		var v = mkEnumValue(ec, "Access", name, []);
		if (pos != null) switch (v) { case VEnumValue(ev): ev.enpos = pos; case _: }
		return v;
	}

	static function encodeFieldKind(ec:EvalContext, k:ClassFieldKind):EvalValue {
		return switch (k) {
			case FVar(t, e): mkEnumValue(ec, "FieldType", "FVar", [t == null ? VNull : encodeComplexType(ec, t), e == null ? VNull : encodeExpr(ec, e)]);
			case FFun(fn): mkEnumValue(ec, "FieldType", "FFun", [encodeFunc(ec, fn)]);
			case FProp(get, set, t, e): mkEnumValue(ec, "FieldType", "FProp", [mkString(get.name), mkString(set.name), t == null ? VNull : encodeComplexType(ec, t), e == null ? VNull : encodeExpr(ec, e)]);
		};
	}

	static function encodeFunc(ec:EvalContext, f:Func):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("args"), encodeArray([for (a in f.fArgs) encodeFunctionArg(ec, a)]));
		fields.set(EvalHash.hash("ret"), f.fType == null ? VNull : encodeComplexType(ec, f.fType));
		fields.set(EvalHash.hash("expr"), f.fExpr == null ? VNull : encodeExpr(ec, f.fExpr));
		fields.set(EvalHash.hash("params"), encodeArray([for (tp in f.fParams) encodeTparamDecl(ec, tp)]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	// Names follow hxc's simplified ABI (plain strings, no name_pos), matching encodeFunctionArg. Meta is
	// elided like the field/arg encoders.
	static function encodeTparamDecl(ec:EvalContext, tp:TypeParam):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		// No defaultType is encoded.
		fields.set(EvalHash.hash("name"), mkString(tp.tpName.name));
		fields.set(EvalHash.hash("name_pos"), encPos(tp.tpName.pos));
		fields.set(EvalHash.hash("params"), encodeArray([for (p in tp.tpParams) encodeTparamDecl(ec, p)]));
		fields.set(EvalHash.hash("constraints"), tp.tpConstraints == null ? encodeArray([]) : encodeArray([encodeComplexType(ec, tp.tpConstraints)]));
		fields.set(EvalHash.hash("meta"), encodeArray([for (m in tp.tpMeta) encodeMetadataEntry(ec, m)]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeFunctionArg(ec:EvalContext, a:FunctionArg):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(a.name.name));
		// The argument name's position travels alongside the name, even though
		// haxe.macro.Expr.FunctionArg does not document the field, and decoding reads it back. Without it
		// a build macro that returns getBuildFields() unchanged would still lose every argument position,
		// which the js rest-arguments prologue then reports at the enclosing function instead of at the
		// argument.
		fields.set(EvalHash.hash("name_pos"), encPos(a.name.pos));
		fields.set(EvalHash.hash("opt"), a.opt ? VTrue : VFalse);
		fields.set(EvalHash.hash("type"), a.type == null ? VNull : encodeComplexType(ec, a.type));
		fields.set(EvalHash.hash("value"), a.value == null ? VNull : encodeExpr(ec, a.value));
		fields.set(EvalHash.hash("meta"), encodeArray([for (m in a.meta) encodeMetadataEntry(ec, m)]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeArray(items:Array<EvalValue>):EvalValue {
		return VArray(new VArray(items, items.length));
	}

	static function encodeConstant(ec:EvalContext, c:Constant):EvalValue {
		return switch (c) {
			case CInt(s, suf): mkEnumValue(ec, "Constant", "CInt", [mkString(s), mkString(suf)]);
			case CFloat(s, suf): mkEnumValue(ec, "Constant", "CFloat", [mkString(s), mkString(suf)]);
			case CString(s, kind): mkEnumValue(ec, "Constant", "CString", [mkString(s), mkEnumValue(ec, "StringLiteralKind", (switch (kind) { case SSingleQuotes: "SingleQuotes"; case SDoubleQuotes: "DoubleQuotes"; }), [])]);
			case CIdent(s): mkEnumValue(ec, "Constant", "CIdent", [mkString(s)]);
			case CRegexp(r, o): mkEnumValue(ec, "Constant", "CRegexp", [mkString(r), mkString(o)]);
		};
	}

	static function encodeBinop(ec:EvalContext, op:Binop):EvalValue {
		var name = switch (op) {
			case OpAdd: "OpAdd"; case OpMult: "OpMult"; case OpDiv: "OpDiv"; case OpSub: "OpSub"; case OpMod: "OpMod";
			case OpEq: "OpEq"; case OpNotEq: "OpNotEq"; case OpLt: "OpLt"; case OpLte: "OpLte"; case OpGt: "OpGt"; case OpGte: "OpGte";
			case OpAnd: "OpAnd"; case OpOr: "OpOr"; case OpXor: "OpXor"; case OpBoolAnd: "OpBoolAnd"; case OpBoolOr: "OpBoolOr";
			case OpShl: "OpShl"; case OpShr: "OpShr"; case OpUShr: "OpUShr";
			case OpAssign: "OpAssign"; case OpInterval: "OpInterval"; case OpArrow: "OpArrow"; case OpIn: "OpIn"; case OpNullCoal: "OpNullCoal";
			case OpAssignOp(sub): return mkEnumValue(ec, "Binop", "OpAssignOp", [encodeBinop(ec, sub)]);
		};
		return mkEnumValue(ec, "Binop", name, []);
	}

	static function encodeUnop(ec:EvalContext, op:Unop):EvalValue {
		var name = switch (op) {
			case Increment: "OpIncrement"; case Decrement: "OpDecrement";
			case Not: "OpNot"; case Neg: "OpNeg"; case NegBits: "OpNegBits"; case Spread: "OpSpread";
		};
		return mkEnumValue(ec, "Unop", name, []);
	}

	static function encodeObjField(ec:EvalContext, f:ObjectField):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("field"), mkString(f.name));
		// The field name's own position is encoded as `name_pos` and decoded back. Without it every field
		// of a structure that went through a build macro would come back carrying the enclosing literal's
		// position, which the typer then unions into pos - so --json would print `{x: x, y: y}` as the
		// span of both x and y.
		fields.set(EvalHash.hash("name_pos"), encPos(f.pos));
		fields.set(EvalHash.hash("expr"), encodeExpr(ec, f.expr));
		fields.set(EvalHash.hash("quotes"), mkEnumValue(ec, "QuoteStatus", (switch (f.quotes) { case NoQuotes: "Unquoted"; case DoubleQuotes: "Quoted"; }), []));
		return VObject(new VObject([], ODictionary(fields)));
	}

	// A placed path carries its position (a TPath's is the null position), and `sub` is left out when there
	// is none.
	static function encodeTypePath(ec:EvalContext, tp:TypePath, pos:Position):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("pack"), encodeArray([for (s in tp.tpackage) mkString(s)]));
		fields.set(EvalHash.hash("name"), mkString(tp.tname));
		fields.set(EvalHash.hash("params"), encodeArray([for (tpc in tp.tparams) encodeTypeParam(ec, tpc)]));
		fields.set(EvalHash.hash("pos"), encPos(pos));
		if (tp.tsub != null) fields.set(EvalHash.hash("sub"), mkString(tp.tsub));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeTypeParam(ec:EvalContext, tpc:TypeParamOrConst):EvalValue {
		return switch (tpc) {
			case TPType(th): mkEnumValue(ec, "TypeParam", "TPType", [encodeComplexType(ec, th)]);
			case TPExpr(e): mkEnumValue(ec, "TypeParam", "TPExpr", [encodeExpr(ec, e)]);
		};
	}

	static function encodeFunctionKind(ec:EvalContext, k:FunctionKind):EvalValue {
		return switch (k) {
			case FKAnonymous: mkEnumValue(ec, "FunctionKind", "FAnonymous", []);
			case FKNamed(n, inl): mkEnumValue(ec, "FunctionKind", "FNamed", [mkString(n.name), inl ? VTrue : VFalse]);
			case FKArrow: mkEnumValue(ec, "FunctionKind", "FArrow", []);
		};
	}

	static function encodeCase(ec:EvalContext, c:SwitchCase):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("values"), encodeArray([for (v in c.values) encodeExpr(ec, v)]));
		fields.set(EvalHash.hash("guard"), c.guard == null ? VNull : encodeExpr(ec, c.guard));
		fields.set(EvalHash.hash("expr"), c.expr == null ? VNull : encodeExpr(ec, c.expr));
		// The case position travels as a hidden pos field even though haxe.macro.Expr.Case does not declare
		// one.
		fields.set(EvalHash.hash("pos"), encPos(c.pos));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeCatch(ec:EvalContext, c:Catch):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(c.name.name));
		// name_pos and pos travel with the catch, so a build-macro round trip keeps the var-name and clause
		// positions instead of the decoder fallback.
		fields.set(EvalHash.hash("name_pos"), encPos(c.name.pos));
		// Preserve the catch type hint so a build macro that reads and re-emits a try/catch keeps the
		// declared catch type. Dropping it here made every round-tripped catch decode back to Dynamic,
		// which then bound the raw thrown value instead of a haxe.ValueException wrapper.
		fields.set(EvalHash.hash("type"), c.type == null ? VNull : encodeComplexType(ec, c.type));
		fields.set(EvalHash.hash("expr"), encodeExpr(ec, c.expr));
		fields.set(EvalHash.hash("pos"), encPos(c.pos));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeMetadataEntry(ec:EvalContext, m:MetadataEntry):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(m.name));
		fields.set(EvalHash.hash("params"), encodeArray([for (pe in m.params) encodeExpr(ec, pe)]));
		// The entry position is encoded; without it every metadata entry that survives a build macro round
		// trip would fall back to the field position.
		fields.set(EvalHash.hash("pos"), encPos(m.pos));
		return VObject(new VObject([], ODictionary(fields)));
	}

	// A referenced method whose inferred return is still an unbound monomorph has an untyped body; typing
	// it binds the return (e.g. Void), so the macro sees the settled type, as a read through the field's
	// lazy type would.
	static function settleOpenReturns(te:TExpr):Void {
		function openRet(cf:TClassField):Bool return switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): switch (TypeFunctions.follow(sig.ret)) { case TMono(r): r.type == null; case _: false; };
			case _: false;
		}
		switch (te.expr) {
			case TField(e1, fa):
				settleOpenReturns(e1);
				var hit = switch (fa) {
					case FInstance(c, _, cf) | FStatic(c, cf): {c: c, cf: cf};
					case FClosure(w, cf) if (w != null): {c: w.c, cf: cf};
					case _: null;
				}
				if (hit != null && hit.cf.expr == null && openRet(hit.cf) && currentCom != null) {
					hxc.typing.TypeFields.forceFieldBody(currentCom, hit.c, hit.cf);
					// The read carries a fresh return monomorph (FieldAccess.getFieldExpr FRead); bind it
					// to the now-settled declaration return.
					switch [TypeFunctions.follow(te.type), TypeFunctions.follow(hit.cf.type)] {
						case [TFun(s1), TFun(s2)]:
							switch (TypeFunctions.follow(s1.ret)) {
								case TMono(r) if (r.type == null):
									try TypeUnification.unifyDefault(s2.ret, s1.ret) catch (_:Dynamic) {}
								case _:
							}
						case _:
					}
				}
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, _) | TUnop(_, _, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1) | TThrow(e1):
				settleOpenReturns(e1);
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2) | TWhile(e1, e2, _):
				settleOpenReturns(e1); settleOpenReturns(e2);
			case TBlock(el) | TArrayDecl(el):
				for (x in el) settleOpenReturns(x);
			case TCall(e1, el):
				settleOpenReturns(e1); for (x in el) settleOpenReturns(x);
			case TNew(_, _, el):
				for (x in el) settleOpenReturns(x);
			case TObjectDecl(fl):
				for (f in fl) settleOpenReturns(f.expr);
			case TVarExpr(_, eo) | TReturn(eo):
				if (eo != null) settleOpenReturns(eo);
			case TIf(e1, e2, e3):
				settleOpenReturns(e1); settleOpenReturns(e2); if (e3 != null) settleOpenReturns(e3);
			case TSwitch(e1, cases, edef):
				settleOpenReturns(e1);
				for (c in cases) { for (v in c.values) settleOpenReturns(v); settleOpenReturns(c.expr); }
				if (edef != null) settleOpenReturns(edef);
			case TTry(e1, catches):
				settleOpenReturns(e1); for (c in catches) settleOpenReturns(c.expr);
			case TFunction(f):
				settleOpenReturns(f.expr);
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TIdent(_) | TBreak | TContinue:
		}
	}

	static function typeToComplexType(t:T):Null<ComplexType> {
		function hint(t:T):TypeHint return {ct: typeToComplexType(t), pos: Position.nullPos};
		// A KExpr type parameter (@:const) converts back to its expression.
		function params(tl:Array<T>):Array<TypeParamOrConst> return [for (t in tl) switch (t) {
			case TInst({kind: KExpr(e)}, _): TPExpr(e);
			case _: TPType(hint(t));
		}];
		// Module-aware path: a secondary type converts as <Module> with sub <Name>; a private type
		// converts by bare name. Typedefs and monomorphs are not followed (the path itself is the
		// result), except '#'-statics typedefs.
		function tpath(path:hxc.core.Globals.Path, mpath:hxc.core.Globals.Path, priv:Bool, tl:Array<T>):ComplexType {
			if (priv) return CTPath({tpackage: [], tname: path.name, tparams: params(tl), tsub: null});
			if (mpath.name == path.name) return CTPath({tpackage: path.pack, tname: path.name, tparams: params(tl), tsub: null});
			return CTPath({tpackage: mpath.pack, tname: mpath.name, tparams: params(tl), tsub: path.name});
		}
		return switch (t) {
			case TMono(r):
				// An unbound monomorph raises Exit through the whole conversion, however deep it sits; the
				// callers answer nothing for it.
				r.type == null ? throw new hxc.core.ExitException() : typeToComplexType(r.type);
			case TLazy(f):
				typeToComplexType(TypeFunctions.lazyType(f));
			case TInst(c, tl):
				switch (c.kind) {
					case KExpr(_) | KTypeParameter(_):
						CTPath({tpackage: [], tname: c.path.name, tparams: params(tl), tsub: null});
					case _:
						tpath(c.path, c.module.path, c.isPrivate, tl);
				}
			case TEnum(e, tl):
				tpath(e.path, e.module.path, e.isPrivate, tl);
			case TType(td, tl):
				if (td.path.name.charCodeAt(0) == "#".code) typeToComplexType(TypeFunctions.follow(t))
				else tpath(td.path, td.module.path, td.isPrivate, tl);
			case TAbstract(a, tl):
				tpath(a.path, a.module.path, a.isPrivate, tl);
			case TFun(sig):
				// A named argument converts as CTNamed and an optional one wraps in CTOptional.
				CTFunction([for (a in sig.args) {
					var th = hint(a.t);
					if (a.name != "") th = {ct: CTNamed({name: a.name, pos: Position.nullPos}, th), pos: Position.nullPos};
					if (a.opt) th = {ct: CTOptional(th), pos: Position.nullPos};
					th;
				}], hint(sig.ret));
			case TDynamic(_):
				CTPath({tpackage: [], tname: "Dynamic", tparams: [], tsub: null});
			case TAnon(an):
				// An anonymous type: statics print as Class<X>/Enum<X>; otherwise rebuild the anonymous
				// declaration, a var becoming a property whose accessor names spell its access.
				switch (an.status.get()) {
					case Statics(c):
						CTPath({tpackage: [], tname: "Class", tparams: [TPType({ct: CTPath({tpackage: c.path.pack, tname: c.path.name, tparams: [], tsub: null}), pos: Position.nullPos})], tsub: null});
					case EnumStatics(e):
						CTPath({tpackage: [], tname: "Enum", tparams: [TPType({ct: CTPath({tpackage: e.path.pack, tname: e.path.name, tparams: [], tsub: null}), pos: Position.nullPos})], tsub: null});
					case _:
						// No hint for an unresolved mono or an unconvertible type.
						function mkTypeHint(t:T):Null<TypeHint> {
							return switch (TypeFunctions.follow(t)) {
								case TMono(_): null;
								case _:
									var ct = try typeToComplexType(t) catch (_:hxc.core.ExitException) null;
									ct == null ? null : {ct: ct, pos: Position.nullPos};
							};
						}
						// The field list is in descending name order: an ascending visit that prepends
						// each.
						var names = [for (k in an.fields.keys()) k];
						names.sort(function(x, y) return x < y ? 1 : (x > y ? -1 : 0));
						var fields:Array<hxc.ast.Ast.ClassField> = [];
						for (n in names) {
							var f = an.fields.get(n);
							var access:Array<hxc.ast.Ast.PlacedAccess> = [];
							// Prepend semantics give [extern, final, public/private].
							if (TypeFunctions.hasClassFieldFlag(f, CfExtern)) access.push({access: AExtern, pos: Position.nullPos});
							if (TypeFunctions.hasClassFieldFlag(f, CfFinal)) access.push({access: AFinal, pos: Position.nullPos});
							access.push({access: TypeFunctions.hasClassFieldFlag(f, CfPublic) ? APublic : APrivate, pos: Position.nullPos});
							var kind:Null<ClassFieldKind> = switch [f.kind, TypeFunctions.follow(f.type)] {
								case [Var(v), _]:
									function vas(va:VarAccess, gs:String):String return switch (va) {
										case AccNormal | AccCtor | AccInline | AccRequire(_, _): "default";
										case AccNo: "null";
										case AccNever: "never";
										case AccCall: gs;
									};
									FProp({name: vas(v.read, "get"), pos: Position.nullPos}, {name: vas(v.write, "set"), pos: Position.nullPos}, mkTypeHint(f.type), null);
								case [Method(_), TFun(sig)]:
									FFun({
										fParams: [],
										fArgs: [for (a in sig.args) {name: {name: a.name, pos: Position.nullPos}, opt: a.opt, meta: [], type: mkTypeHint(a.t), value: null}],
										fType: mkTypeHint(sig.ret),
										fExpr: null
									});
								case _: null;
							};
							if (kind == null) return null;
							fields.push({cffName: {name: f.name, pos: Position.nullPos}, cffDoc: null, cffPos: f.pos, cffMeta: f.meta, cffAccess: access, cffKind: kind});
						}
						CTAnonymous(fields);
				}
		};
	}

	// The type HINT's position is attached to the ComplexType value, and decoding reads it back, so a
	// type that survives a macro round trip keeps its position rather than falling back to the
	// enclosing one, and `x is T` keeps the position of T.
	static function encodeComplexType(ec:EvalContext, th:TypeHint):EvalValue {
		var v = encodeComplexTypeInner(ec, th.ct);
		switch (v) {
			case VEnumValue(ev): ev.enpos = th.pos;
			case _:
		}
		return v;
	}

	static function encodeComplexTypeInner(ec:EvalContext, ct:ComplexType):EvalValue {
		return switch (ct) {
			case CTPath(tp): mkEnumValue(ec, "ComplexType", "TPath", [encodeTypePath(ec, tp, Position.nullPos)]);
			case CTFunction(args, ret): mkEnumValue(ec, "ComplexType", "TFunction", [encodeArray([for (a in args) encodeComplexType(ec, a)]), encodeComplexType(ec, ret)]);
			case CTAnonymous(fl): mkEnumValue(ec, "ComplexType", "TAnonymous", [encodeArray([for (f in fl) encodeField(ec, f)])]);
			case CTParent(t): mkEnumValue(ec, "ComplexType", "TParent", [encodeComplexType(ec, t)]);
			case CTExtend(paths, fl): mkEnumValue(ec, "ComplexType", "TExtend", [encodeArray([for (pp in paths) encodeTypePath(ec, pp.path, pp.pos)]), encodeArray([for (f in fl) encodeField(ec, f)])]);
			case CTOptional(t): mkEnumValue(ec, "ComplexType", "TOptional", [encodeComplexType(ec, t)]);
			case CTNamed(n, t): mkEnumValue(ec, "ComplexType", "TNamed", [mkString(n.name), encodeComplexType(ec, t)]);
			case CTIntersection(tl): mkEnumValue(ec, "ComplexType", "TIntersection", [encodeArray([for (t in tl) encodeComplexType(ec, t)])]);
		};
	}

	// Encode a typed type as a haxe.macro.Type value. Bound monomorphs are collapsed to their
	// bound type (matching a post-typing result), so Context.follow is the identity on these.
	static function encodeType(ec:EvalContext, t:T):EvalValue {
		return switch (t) {
			case TMono(m): m.type != null ? encodeType(ec, m.type) : mkEnumValue(ec, "Type", "TMono", [encodeMonoRef(ec, m)]);
			case TEnum(e, params): mkEnumValue(ec, "Type", "TEnum", [encodeEnumRef(ec, e), encodeArray([for (p in params) encodeType(ec, p)])]);
			case TInst(c, params): mkEnumValue(ec, "Type", "TInst", [encodeClassRef(ec, c), encodeArray([for (p in params) encodeType(ec, p)])]);
			case TType(d, params): mkEnumValue(ec, "Type", "TType", [encodeDefRef(ec, d), encodeArray([for (p in params) encodeType(ec, p)])]);
			case TFun(sig): mkEnumValue(ec, "Type", "TFun", [encodeArray([for (a in sig.args) encodeTypeFunArg(ec, a)]), encodeType(ec, sig.ret)]);
			case TAnon(an): mkEnumValue(ec, "Type", "TAnonymous", [encodeAnonRef(ec, an)]);
			case TDynamic(t2): mkEnumValue(ec, "Type", "TDynamic", [t2 == null ? VNull : encodeType(ec, t2)]);
			case TLazy(f): encodeType(ec, TypeFunctions.lazyType(f));
			case TAbstract(a, params): mkEnumValue(ec, "Type", "TAbstract", [encodeAbstractRef(ec, a), encodeArray([for (p in params) encodeType(ec, p)])]);
		};
	}

	public static function encodeTypedExpr(ec:EvalContext, e:TExpr):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("expr"), encodeTypedExprDef(ec, e.expr));
		fields.set(EvalHash.hash("pos"), encPos(e.pos));
		fields.set(EvalHash.hash("t"), encodeType(ec, e.type));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeTypedExprDef(ec:EvalContext, ed:TExprExpr):EvalValue {
		return switch (ed) {
			case TConst(c): mkEnumValue(ec, "TypedExprDef", "TConst", [encodeTConstant(ec, c)]);
			case TLocal(v): mkEnumValue(ec, "TypedExprDef", "TLocal", [encodeTVar(ec, v)]);
			case TArray(e1, e2): mkEnumValue(ec, "TypedExprDef", "TArray", [encodeTypedExpr(ec, e1), encodeTypedExpr(ec, e2)]);
			case TBinop(op, e1, e2): mkEnumValue(ec, "TypedExprDef", "TBinop", [encodeBinop(ec, op), encodeTypedExpr(ec, e1), encodeTypedExpr(ec, e2)]);
			case TField(e1, fa): mkEnumValue(ec, "TypedExprDef", "TField", [encodeTypedExpr(ec, e1), encodeTFieldAccess(ec, fa)]);
			case TTypeExpr(mt): mkEnumValue(ec, "TypedExprDef", "TTypeExpr", [encodeModuleType(ec, mt)]);
			case TParenthesis(e1): mkEnumValue(ec, "TypedExprDef", "TParenthesis", [encodeTypedExpr(ec, e1)]);
			case TObjectDecl(fl):
				mkEnumValue(ec, "TypedExprDef", "TObjectDecl", [encodeArray([for (f in fl) typedObjectField(ec, f.key.name, f.expr)])]);
			case TArrayDecl(el): mkEnumValue(ec, "TypedExprDef", "TArrayDecl", [encodeArray([for (e in el) encodeTypedExpr(ec, e)])]);
			case TCall(e1, el): mkEnumValue(ec, "TypedExprDef", "TCall", [encodeTypedExpr(ec, e1), encodeArray([for (e in el) encodeTypedExpr(ec, e)])]);
			case TNew(c, params, el): mkEnumValue(ec, "TypedExprDef", "TNew", [encodeClassRef(ec, c), encodeArray([for (p in params) encodeType(ec, p)]), encodeArray([for (e in el) encodeTypedExpr(ec, e)])]);
			case TUnop(op, flag, e1): mkEnumValue(ec, "TypedExprDef", "TUnop", [encodeUnop(ec, op), flag == Postfix ? VTrue : VFalse, encodeTypedExpr(ec, e1)]);
			case TFunction(fn): mkEnumValue(ec, "TypedExprDef", "TFunction", [encodeTFunc(ec, fn)]);
			case TVarExpr(v, eo): mkEnumValue(ec, "TypedExprDef", "TVar", [encodeTVar(ec, v), eo == null ? VNull : encodeTypedExpr(ec, eo)]);
			case TBlock(el): mkEnumValue(ec, "TypedExprDef", "TBlock", [encodeArray([for (e in el) encodeTypedExpr(ec, e)])]);
			case TFor(v, e1, e2): mkEnumValue(ec, "TypedExprDef", "TFor", [encodeTVar(ec, v), encodeTypedExpr(ec, e1), encodeTypedExpr(ec, e2)]);
			case TIf(c, e1, e2): mkEnumValue(ec, "TypedExprDef", "TIf", [encodeTypedExpr(ec, c), encodeTypedExpr(ec, e1), e2 == null ? VNull : encodeTypedExpr(ec, e2)]);
			case TWhile(c, e1, flag): mkEnumValue(ec, "TypedExprDef", "TWhile", [encodeTypedExpr(ec, c), encodeTypedExpr(ec, e1), flag == NormalWhile ? VTrue : VFalse]);
			case TSwitch(e1, cases, edef):
				mkEnumValue(ec, "TypedExprDef", "TSwitch", [encodeTypedExpr(ec, e1), encodeArray([for (c in cases) typedSwitchCase(ec, c)]), edef == null ? VNull : encodeTypedExpr(ec, edef)]);
			case TTry(e1, catches): mkEnumValue(ec, "TypedExprDef", "TTry", [encodeTypedExpr(ec, e1), encodeArray([for (c in catches) typedCatch(ec, c)])]);
			case TReturn(eo): mkEnumValue(ec, "TypedExprDef", "TReturn", [eo == null ? VNull : encodeTypedExpr(ec, eo)]);
			case TBreak: mkEnumValue(ec, "TypedExprDef", "TBreak", []);
			case TContinue: mkEnumValue(ec, "TypedExprDef", "TContinue", []);
			case TThrow(e1): mkEnumValue(ec, "TypedExprDef", "TThrow", [encodeTypedExpr(ec, e1)]);
			case TCast(e1, mt): mkEnumValue(ec, "TypedExprDef", "TCast", [encodeTypedExpr(ec, e1), mt == null ? VNull : encodeModuleType(ec, mt)]);
			case TMeta(m, e1): mkEnumValue(ec, "TypedExprDef", "TMeta", [encodeMetadataEntry(ec, m), encodeTypedExpr(ec, e1)]);
			case TEnumParameter(e1, ef, index): mkEnumValue(ec, "TypedExprDef", "TEnumParameter", [encodeTypedExpr(ec, e1), encodeEnumField(ec, ef), VInt(index)]);
			case TEnumIndex(e1): mkEnumValue(ec, "TypedExprDef", "TEnumIndex", [encodeTypedExpr(ec, e1)]);
			case TIdent(s): mkEnumValue(ec, "TypedExprDef", "TIdent", [mkString(s)]);
		};
	}

	static function encodeTConstant(ec:EvalContext, c:TConstant):EvalValue {
		return switch (c) {
			case TInt(i): mkEnumValue(ec, "TConstant", "TInt", [VInt(i)]);
			case TFloat(s): mkEnumValue(ec, "TConstant", "TFloat", [mkString(s)]);
			case TString(s): mkEnumValue(ec, "TConstant", "TString", [mkString(s)]);
			case TBool(b): mkEnumValue(ec, "TConstant", "TBool", [b ? VTrue : VFalse]);
			case TNull: mkEnumValue(ec, "TConstant", "TNull", []);
			case TThis: mkEnumValue(ec, "TConstant", "TThis", []);
			case TSuper: mkEnumValue(ec, "TConstant", "TSuper", []);
		};
	}

	static function encodeTVar(ec:EvalContext, v:TVar):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		var refId = nextTvarRefId++;
		tvarRefs.set(refId, v);
		// The tvar object's handle is an Unsafe instance, not a number.
		fields.set(EvalHash.hash("$"), unsafeValue(ec, refId));
		fields.set(EvalHash.hash("id"), VInt(v.id));
		fields.set(EvalHash.hash("name"), mkString(v.name));
		fields.set(EvalHash.hash("t"), encodeType(ec, v.type));
		// A local function's var reads as captured: the VFinal INDEX is stored as its flags.
		fields.set(EvalHash.hash("capture"), TypeFunctions.hasVarFlag(v, VCaptured) ? VTrue : VFalse);
		fields.set(EvalHash.hash("extra"), v.extra == null ? VNull : {
			var x:Map<Int, EvalValue> = new Map();
			x.set(EvalHash.hash("params"), encodeArray([for (tp in v.extra.params) encodeTypeParameterValue(ec, tp)]));
			x.set(EvalHash.hash("expr"), v.extra.expr == null ? VNull : encodeTypedExpr(ec, v.extra.expr));
			VObject(new VObject([], ODictionary(x)));
		});
		fields.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return v.meta, function(m) v.meta = m));
		fields.set(EvalHash.hash("isStatic"), TypeFunctions.hasVarFlag(v, VStatic) ? VTrue : VFalse);
		return VObject(new VObject([], ODictionary(fields)));
	}

	public static function encodeModuleType(ec:EvalContext, mt:ModuleType):EvalValue {
		return switch (mt) {
			case TClassDecl(c): mkEnumValue(ec, "ModuleType", "TClassDecl", [encodeClassRef(ec, c)]);
			case TEnumDecl(e): mkEnumValue(ec, "ModuleType", "TEnumDecl", [encodeEnumRef(ec, e)]);
			case TTypeDecl(d): mkEnumValue(ec, "ModuleType", "TTypeDecl", [encodeDefRef(ec, d)]);
			case TAbstractDecl(a): mkEnumValue(ec, "ModuleType", "TAbstract", [encodeAbstractRef(ec, a)]);
		};
	}

	static function encodeTFieldAccess(ec:EvalContext, fa:TFieldAccess):EvalValue {
		return switch (fa) {
			case FInstance(c, params, cf): mkEnumValue(ec, "FieldAccess", "FInstance", [encodeClassRef(ec, c), encodeArray([for (p in params) encodeType(ec, p)]), encodeClassFieldRef(ec, cf)]);
			case FStatic(c, cf): mkEnumValue(ec, "FieldAccess", "FStatic", [encodeClassRef(ec, c), encodeClassFieldRef(ec, cf)]);
			case FAnon(cf): mkEnumValue(ec, "FieldAccess", "FAnon", [encodeClassFieldRef(ec, cf)]);
			case FDynamic(s): mkEnumValue(ec, "FieldAccess", "FDynamic", [mkString(s)]);
			case FClosure(c, cf):
				var cv = c == null ? VNull : classWithParamsValue(ec, c);
				mkEnumValue(ec, "FieldAccess", "FClosure", [cv, encodeClassFieldRef(ec, cf)]);
			case FEnum(e, ef): mkEnumValue(ec, "FieldAccess", "FEnum", [encodeEnumRef(ec, e), encodeEnumField(ec, ef)]);
		};
	}

	static function encodeTFunc(ec:EvalContext, fn:TFunc):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("args"), encodeArray([for (a in fn.args) typedFuncArg(ec, a)]));
		fields.set(EvalHash.hash("t"), encodeType(ec, fn.type));
		fields.set(EvalHash.hash("expr"), encodeTypedExpr(ec, fn.expr));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function typedFuncArg(ec:EvalContext, a:TFuncArg):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("v"), encodeTVar(ec, a.v));
		fields.set(EvalHash.hash("value"), a.c == null ? VNull : encodeTypedExpr(ec, a.c));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function typedObjectField(ec:EvalContext, name:String, expr:TExpr):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(name));
		fields.set(EvalHash.hash("expr"), encodeTypedExpr(ec, expr));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function typedSwitchCase(ec:EvalContext, c:TSwitchCase):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("values"), encodeArray([for (e in c.values) encodeTypedExpr(ec, e)]));
		fields.set(EvalHash.hash("expr"), encodeTypedExpr(ec, c.expr));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function typedCatch(ec:EvalContext, c:TCatch):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("v"), encodeTVar(ec, c.v));
		fields.set(EvalHash.hash("expr"), encodeTypedExpr(ec, c.expr));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeBaseType(ec:EvalContext, path:hxc.core.Globals.Path):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(path.name));
		fields.set(EvalHash.hash("pack"), encodeArray([for (s in path.pack) mkString(s)]));
		fields.set(EvalHash.hash("module"), mkString(path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name));
		return VObject(new VObject([], ODictionary(fields)));
	}

	// A macro Ref<T> exposes get() and toString(); the dot path when it stands for a named type, "<extend>"
	// for the anonymous extension list.
	static function encodeRef(ec:EvalContext, payload:EvalValue, ?path:hxc.core.Globals.Path):EvalValue {
		return makeRef(ec, function(_) return payload,
			function(_) return mkString(path == null ? "<extend>" : Context.pathKey(path)), 0);
	}

	static function encodeMonoRef(ec:EvalContext, m:TMono):EvalValue {
		var id = ++macroMonoId;
		macroMonos.set(id, m);
		// The mono id rides in the ikind like every other handle, so the Ref has its two fields and nothing
		// more.
		return makeRef(ec, function(_) return m.type == null ? VNull : encodeType(ec, m.type), function(_) return mkString("<mono>"), id);
	}

	static function encodeAnonRef(ec:EvalContext, an:TAnon):EvalValue {
		var payload = function() {
			var fields:Map<Int, EvalValue> = new Map();
			// Fields encode in ascending name order.
			var names = [for (k in an.fields.keys()) k];
			names.sort(function(x, y) return x < y ? -1 : (x > y ? 1 : 0));
			fields.set(EvalHash.hash("fields"), encodeArray([for (n in names) encodeClassField(ec, an.fields.get(n))]));
			fields.set(EvalHash.hash("status"), encodeAnonStatus(ec, an.status.get()));
			return VObject(new VObject([], ODictionary(fields)));
		}
		var refId = nextAnonRefId++;
		anonRefs.set(refId, an);
		return makeRef(ec, function(_) return payload(), function(_) return mkString("<anonymous>"), refId);
	}

	static function encodeAnonStatus(ec:EvalContext, status:AnonStatus):EvalValue {
		return switch (status) {
			case Closed:
				mkEnumValue(ec, "AnonStatus", "AClosed", []);
			case Const:
				mkEnumValue(ec, "AnonStatus", "AConst", []);
			case Extend(tl):
				mkEnumValue(ec, "AnonStatus", "AExtend", [encodeRef(ec, encodeArray([for (t in tl) encodeType(ec, t)]))]);
			case Statics(c):
				mkEnumValue(ec, "AnonStatus", "AClassStatics", [encodeClassRef(ec, c)]);
			case EnumStatics(e):
				mkEnumValue(ec, "AnonStatus", "AEnumStatics", [encodeEnumRef(ec, e)]);
			case AbstractStatics(a):
				mkEnumValue(ec, "AnonStatus", "AAbstractStatics", [encodeAbstractRef(ec, a)]);
		};
	}

	// A lazy Ref<T>: .get() computes the payload on demand. Refs must stay lazy so a class encoding can
	// reference itself (field types, super chain) without infinite recursion.
	// A lazy that has not run yet reaches the macro as TLazy(f), and calling f forces it then - with the
	// context flushed first when it is still waiting.
	static function encodeLazyType(ec:EvalContext, t:T):EvalValue {
		return switch (t) {
			case TMono(m) if (m.type != null): encodeLazyType(ec, m.type);
			case TLazy(r):
				switch (r.get()) {
					case LAvailable(t2): encodeType(ec, t2);
					case _:
						var get = function():EvalValue {
							return switch (r.get()) {
								case LAvailable(t2): encodeType(ec, t2);
								case LWait(_):
									var com = currentCompiler();
									encodeType(ec, com == null ? TypeFunctions.lazyType(r) : typingTimer(com, function() return TypeFunctions.lazyType(r), true));
								case LProcessing(_):
									// Our type is on the processing stack, error instead of returning most likely an unbound
									// mono
									EvalExceptions.excString(ec, "Accessing a type while it's being typed");
							};
						};
						mkEnumValue(ec, "Type", "TLazy", [VInstance(new VInstance([], fakeProto("haxe.macro.LazyType"), ILazyType(r, get)))]);
				}
			case _: encodeType(ec, t);
		};
	}

	static function encodeLazyRef(ec:EvalContext, thunk:Void->EvalValue):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("get"), VFunction(function(_) return thunk(), true));
		return VObject(new VObject([], ODictionary(fields)));
	}

	// The reification's `$__mk_pos__(file, min, max)` builtin.
	public static function mkPosValue(a:Array<EvalValue>):EvalValue {
		return encPos(new Position(strOf(a[0]), intOf(a[1]), intOf(a[2])));
	}

	static function encPos(p:Position):EvalValue {
		var path = EvalHash.hash("haxe.macro.Position");
		var proto = ecProto(path);
		return VInstance(new VInstance([], proto, IPos(p)));
	}

	static function ecProto(path:Int):VPrototype {
		var ec = EvalContext.getCtx();
		var proto = ec.instancePrototypes.get(path);
		if (proto == null) {
			proto = new VPrototype(path, [], new Map(), [], new Map(), null, PClass([]), VNull);
			proto.pvalue = VPrototype(proto);
			ec.instancePrototypes.set(path, proto);
		}
		return proto;
	}

	static function posOf(ec:EvalContext, v:EvalValue, fallback:Position):Position {
		return switch (v) {
			// Anything but a Position value is an invalid expression; a null handed for a position is
			// "Invalid expression", not the caller's fallback (which stands in only for an argument that
			// was never passed, see posArg).
			case VNull:
				throw new DecodeFailure("Invalid expression");
			case VInstance(vi): switch (vi.ikind) {
				case IPos(p): p;
				case _: fallback;
			}
			case _:
				try new Position(strOf(EvalField.field(ec, v, EvalHash.hash("file"))), intOf(EvalField.field(ec, v, EvalHash.hash("min"))), intOf(EvalField.field(ec, v, EvalHash.hash("max"))))
				catch (_:Dynamic) fallback;
		};
	}

	// The string is padded with p.min spaces, so an error inside it carries the caller's file offsets
	// when inlining; when not, the failure reports at p itself, the whole API call. The stored id, as
	// the `@:storedTypedExpr(id)` marker that re-types to it.
	static function storedTypedExprMarker(ec:EvalContext, te:TExpr):EvalValue {
		var id = hxc.context.Context.allocStoredTypedExprId("api.storeTypedExpr");
		curTctx.com.storedTypedExprs.set(id, te);
		var eid = new Expr(EConst(CInt(Std.string(id), null)), curPos);
		return encodeExpr(ec, new Expr(EMeta({name: ":storedTypedExpr", params: [], pos: Position.nullPos}, eid), curPos));
	}

	static function parseApiString(src:String, p:Position, inlined:Bool, defines:hxc.core.Define):Expr {
		// An empty string is an invalid expression before any parsing.
		if (src == "") throw new DecodeFailure("Invalid expression");
		// A parser's or the lexer's error is a typing error at its own place in the caller-offset string
		// when inlined, at the caller otherwise.
		return try hxc.parser.Parser.parseExprString(src, p.file, defines, inlined)
		catch (e:hxc.parser.ParserError) {
			var at = inlined ? new Position(p.file, e.pos.min + p.min, e.pos.max + p.min) : p;
			throw new TypingError(hxc.parser.ParserError.errorMsg(e.msg), at);
		} catch (e:hxc.parser.LexerError) {
			var at = inlined ? new Position(p.file, e.pos.min + p.min, e.pos.max + p.min) : p;
			throw new TypingError(hxc.parser.LexerError.errorMsg(e.msg), at);
		}
	}

	// A missing position takes the caller's default.
	static function posDefault(ec:EvalContext, v:EvalValue, fallback:Position):Position {
		return v == VNull ? fallback : posOf(ec, v, fallback);
	}

	// A missing position is the null position.
	static function posMaybe(ec:EvalContext, v:EvalValue):Position {
		return v == VNull ? Position.nullPos : posOf(ec, v, Position.nullPos);
	}

	static function posArg(ec:EvalContext, args:Array<EvalValue>, index:Int, fallback:Position):Position {
		return args.length > index ? posOf(ec, args[index], fallback) : fallback;
	}

	// The platform and metadata-usage names each parser accepts.
	static final platformNames = ["cross", "js", "lua", "neko", "flash", "php", "cpp", "cs", "java", "python", "hl", "eval"];
	static final metadataTargetNames = ["TClass", "TClassField", "TAbstract", "TAbstractField", "TEnum", "TTypedef", "TAnyField", "TExpr", "TTypeParameter", "TVariable"];

	// A callback is a function or a bound method; anything else is an invalid expression at registration
	// (the API wrapper's "Invalid expression").
	static function prepareCallback(ec:EvalContext, v:EvalValue):EvalValue {
		return switch (EvalValueTools.vresolve(v)) {
			case VFunction(_, _) | VFieldClosure(_, _): v;
			case _: EvalExceptions.excString(ec, "Invalid expression");
		};
	}

	// Context.getLocalUsing: the caller module's usings as class refs, in module order - each using
	// prepends its classes, so the last declared comes first.
	public static function localUsingValue(ec:EvalContext):EvalValue {
		var com = currentCompiler();
		var m = currentModule();
		var classes:Array<TClass> = [];
		if (com != null && m != null) {
			var imports = com.moduleImports.get(Context.pathKey(m.path));
			if (imports != null) for (u in imports.usingClasses) classes.push(u.c);
		}
		return encodeArray([for (c in classes) encodeClassRef(ec, c)]);
	}

	// The caller's locals as a StringMap of TVars or of their types.
	public static function localVarsValue(ec:EvalContext, asVar:EvalValue):EvalValue {
		var entries:Map<String, EvalValue> = new Map();
		if (curTctx != null) for (name => v in curTctx.locals) entries.set(name, asVar == VTrue ? encodeTVar(ec, v) : encodeType(ec, v.type));
		return EvalStdLib.mkStringMapValues(ec, entries);
	}

	// typingTimer: while an API types or loads, a reported error is RAISED and the report mode is off; both
	// are restored on the way out. What the raise reaches is the API's wrapper, which makes it the macro's
	// Error value.
	static function typingTimer<T>(com:Context, f:Void->T, needType:Bool = false):T {
		var oldRaise = com.raiseTypingErrors;
		var oldPass = needTypePass(com, needType);
		com.raiseTypingErrors = true;
		var restoreReport = com.disableReportMode();
		var r = try f() catch (e:Dynamic) { com.raiseTypingErrors = oldRaise; com.currentPass = oldPass; restoreReport(); throw e; };
		com.raiseTypingErrors = oldRaise;
		com.currentPass = oldPass;
		restoreReport();
		return r;
	}

	// typingTimer: an API call that types moves a context still before PTypeField there and flushes the
	// class builds first; the pass is restored on exit.
	static function needTypePass(com:Context, needType:Bool):Int {
		var oldPass = com.currentPass;
		if (needType && com.currentPass < Context.PTypeField) {
			com.currentPass = Context.PTypeField;
			com.flushPass(Context.PBuildClass);
		}
		return oldPass;
	}

	static function applyFn(ec:EvalContext, fn:EvalValue, args:Array<EvalValue>):EvalValue {
		return switch (EvalValueTools.vresolve(fn)) {
			case VFunction(f, _): f(args);
			case VFieldClosure(recv, f): f([recv].concat(args));
			case v: EvalExceptions.unexpectedValue(ec, v, "function");
		};
	}

	static function macroMessage(ec:EvalContext, name:String, msg:EvalValue, pos:EvalValue):EvalValue {
		return mkEnumValue(ec, "Message", name, [msg, pos]);
	}

	static function posInfosValue(ec:EvalContext, p:Position):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("file"), mkString(p.file));
		fields.set(EvalHash.hash("min"), VInt(p.min));
		fields.set(EvalHash.hash("max"), VInt(p.max));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function throwMacroError(ec:EvalContext, msg:String, pos:Position):Dynamic {
		var posValue = encPos(pos);
		var err = macroErrorValue(ec, msg, posValue, pos);
		return EvalExceptions.throwValue(ec, err, pos);
	}

	static function macroErrorValue(ec:EvalContext, msg:String, posValue:EvalValue, pos:Position):EvalValue {
		var proto = ec.instancePrototypes.get(EvalHash.hash("haxe.macro.Error"));
		if (proto == null) proto = ec.instancePrototypes.get(EvalHash.hash("haxe.macro.Expr.Error"));
		if (proto == null) return mkString(msg);
		ensureInstanceSlot(proto, EvalHash.hash("message"));
		ensureInstanceSlot(proto, EvalHash.hash("get_message"));
		ensureInstanceSlot(proto, EvalHash.hash("pos"));
		ensureInstanceSlot(proto, EvalHash.hash("childErrors"));
		ensureInstanceSlot(proto, EvalHash.hash("toString"));
		ensureInstanceSlot(proto, EvalHash.hash("__hxcAbort"));
		var v:EvalValue = VInstance(new VInstance(proto.pinstanceFields.copy(), proto, INormal));
		EvalField.setField(ec, v, EvalHash.hash("message"), mkString(msg), pos);
		EvalField.setField(ec, v, EvalHash.hash("get_message"), VFunction(function(_) return mkString(msg), false), pos);
		EvalField.setField(ec, v, EvalHash.hash("pos"), posValue, pos);
		EvalField.setField(ec, v, EvalHash.hash("childErrors"), VNull, pos);
		// The value Context.error raises through the native boundary; a haxe.macro.Error a macro throws
		// itself is an uncaught exception like any other value Abort for the former and nothing
		// distinguishes the latter from a string).
		EvalField.setField(ec, v, EvalHash.hash("__hxcAbort"), VTrue, pos);
		// haxe.Exception.toString() yields the message, so Std.string(err) is the message text.
		EvalField.setField(ec, v, EvalHash.hash("toString"), VFunction(function(_) return mkString(msg), false), pos);
		return v;
	}

	static function ensureInstanceSlot(proto:VPrototype, name:Int):Void {
		if (proto.pinstanceNames.exists(name)) return;
		proto.pinstanceNames.set(name, proto.pinstanceFields.length);
		proto.pinstanceFields.push(VNull);
	}

	public static function currentPosition():Position {
		return curPos;
	}

	public static function currentModule():Null<ModuleDef> {
		if (curModule != null) return curModule;
		if (curTctx != null) return curTctx.com.currentModule;
		return currentCom == null ? null : currentCom.currentModule;
	}

	public static function currentCompiler():Null<Context> {
		if (curTctx != null) return curTctx.com;
		return currentCom;
	}

	public static function reportError(msg:String, pos:Position):Void {
		// A macro's reported error is a USER compiler message: it lands on the main compile
		// even when raised from the macro world (whose own error diagnostics do not forward).
		var com = currentCom;
		if (com != null && com.forwardWarningsTo != null) com = com.forwardWarningsTo;
		if (com != null) com.addDiagnostic(msg, pos);
	}

	// The value hxc's own Context.error raises + Abort), as opposed to a haxe.macro.Error a macro throws
	// itself.
	static function isAbortValue(ec:EvalContext, v:EvalValue):Bool {
		return switch (EvalValueTools.vresolve(v)) {
			case VInstance(_): EvalField.field(ec, v, EvalHash.hash("__hxcAbort")) == VTrue;
			case _: false;
		};
	}

	public static function runtimeMacroError(ex:EvalExceptions.EvalRunTimeException):Null<{message:String, pos:Position}> {
		var ec = try EvalContext.getCtx() catch (_:Dynamic) null;
		if (ec == null) return null;
		return switch (EvalValueTools.vresolve(ex.value)) {
			// Only a haxe.macro.Error instance reads as an error of its own (its message at its position);
			// any other thrown value is uncaught.
			case VInstance(vi) if (vi.iproto != null && (vi.iproto == ec.instancePrototypes.get(EvalHash.hash("haxe.macro.Error"))
					|| vi.iproto == ec.instancePrototypes.get(EvalHash.hash("haxe.macro.Expr.Error")))):
				// A user built haxe.macro.Error keeps message behind the Exception property
				// whose backing slot is __exceptionMessage; the raw message slot is null.
				var msgRaw = EvalField.field(ec, ex.value, EvalHash.hash("message"));
				if (EvalValueTools.vresolve(msgRaw).match(VNull))
					msgRaw = EvalField.field(ec, ex.value, EvalHash.keyExceptionMessage);
				var msg = switch (EvalValueTools.vresolve(msgRaw)) {
					case VNull: EvalStdLib.stringOf(ex.value);
					case _: EvalStdLib.stringOf(msgRaw);
				};
					var pv = EvalField.field(ec, ex.value, EvalHash.hash("pos"));
				var pos = switch (EvalValueTools.vresolve(pv)) {
					case VInstance(pi): switch (pi.ikind) { case IPos(p): p; case _: Position.nullPos; };
					case VObject(o): switch (o.oproto) {
						case ODictionary(fields):
							var file = EvalStdLib.stringOf(fields.get(EvalHash.hash("file")));
							var min = switch (fields.get(EvalHash.hash("min"))) { case VInt(i): i; case _: -1; };
							var max = switch (fields.get(EvalHash.hash("max"))) { case VInt(i): i; case _: -1; };
							new Position(file, min, max);
						case _: Position.nullPos;
					};
					case _: Position.nullPos;
				};
				{message: msg, pos: pos};
			case _: null;
		};
	}

	// haxe.macro.Type.MetaAccess: get/has/add/extract/remove over a mutable list.
	static function encodeMetaAccess(ec:EvalContext, getMeta:Void->Metadata, setMeta:Metadata->Void):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("get"), VFunction(function(_) return encodeArray([for (m in getMeta()) encodeMetadataEntry(ec, m)]), true));
		fields.set(EvalHash.hash("has"), VFunction(function(a) { var k = strOf(a[0]); for (m in getMeta()) if (m.name == k) return VTrue; return VFalse; }, true));
		fields.set(EvalHash.hash("add"), VFunction(function(a) {
			var k = strOf(a[0]);
			var params = (a.length > 1 && a[1] != VNull) ? [for (pv in arrOf(a[1])) decodeExpr(ec, pv, Position.nullPos)] : [];
			var meta = getMeta();
			// The entry prepends with the caller's position.
			var p = a.length > 2 ? posOf(ec, a[2], Position.nullPos) : Position.nullPos;
			meta.unshift({name: k, params: params, pos: p});
			setMeta(meta);
			return VNull;
		}, true));
		fields.set(EvalHash.hash("extract"), VFunction(function(a) { var k = strOf(a[0]); return encodeArray([for (m in getMeta()) if (m.name == k) encodeMetadataEntry(ec, m)]); }, true));
		fields.set(EvalHash.hash("remove"), VFunction(function(a) { var k = strOf(a[0]); setMeta([for (m in getMeta()) if (m.name != k) m]); return VNull; }, true));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeTVarAccess(ec:EvalContext, a:VarAccess):EvalValue {
		return switch (a) {
			case AccNormal: mkEnumValue(ec, "VarAccess", "AccNormal", []);
			case AccNo: mkEnumValue(ec, "VarAccess", "AccNo", []);
			case AccNever: mkEnumValue(ec, "VarAccess", "AccNever", []);
			case AccCtor: mkEnumValue(ec, "VarAccess", "AccCtor", []);
			case AccCall: mkEnumValue(ec, "VarAccess", "AccCall", []);
			case AccInline: mkEnumValue(ec, "VarAccess", "AccInline", []);
			case AccRequire(s, msg): mkEnumValue(ec, "VarAccess", "AccRequire", [mkString(s), msg == null ? VNull : mkString(msg)]);
		};
	}

	static function encodeTMethodKind(ec:EvalContext, m:MethodKind):EvalValue {
		return switch (m) {
			case MethNormal: mkEnumValue(ec, "MethodKind", "MethNormal", []);
			case MethInline: mkEnumValue(ec, "MethodKind", "MethInline", []);
			case MethDynamic: mkEnumValue(ec, "MethodKind", "MethDynamic", []);
			case MethMacro: mkEnumValue(ec, "MethodKind", "MethMacro", []);
		};
	}

	static function encodeTFieldKind(ec:EvalContext, k:FieldKind):EvalValue {
		return switch (k) {
			case Var(vk): mkEnumValue(ec, "FieldKind", "FVar", [encodeTVarAccess(ec, vk.read), encodeTVarAccess(ec, vk.write)]);
			case Method(m): mkEnumValue(ec, "FieldKind", "FMethod", [encodeTMethodKind(ec, m)]);
		};
	}

	static function encodeClassField(ec:EvalContext, cf:TClassField, ?owner:TClass):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("name"), mkString(cf.name));
		// A field's type is encoded LAZILY - a body not yet typed stays behind TLazy.
		f.set(EvalHash.hash("type"), encodeLazyType(ec, cf.type));
		f.set(EvalHash.hash("isPublic"), TypeFunctions.hasClassFieldFlag(cf, CfPublic) ? VTrue : VFalse);
		f.set(EvalHash.hash("params"), encodeArray([for (tp in cf.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return cf.meta, function(m) cf.meta = m));
		// ClassField.expr(): the field's typed expression, typing the body on demand when the owner is
		// known.
		f.set(EvalHash.hash("expr"), VFunction(function(_) {
			if (cf.expr == null && owner != null && currentCompiler() != null)
				hxc.typing.TypeFields.forceFieldBody(currentCompiler(), owner, cf);
			return cf.expr == null ? VNull : encodeTypedExpr(ec, cf.expr);
		}, true));
		f.set(EvalHash.hash("kind"), encodeTFieldKind(ec, cf.kind));
		f.set(EvalHash.hash("pos"), encPos(cf.pos));
		f.set(EvalHash.hash("namePos"), encPos(cf.namePos));
		f.set(EvalHash.hash("doc"), encodeDoc(Ast.getOwnDocOpt(cf.doc)));
		f.set(EvalHash.hash("overloads"), encodeLazyRef(ec, function() return encodeArray([for (ocf in cf.overloads) encodeClassField(ec, ocf)])));
		f.set(EvalHash.hash("isExtern"), TypeFunctions.hasClassFieldFlag(cf, CfExtern) ? VTrue : VFalse);
		f.set(EvalHash.hash("isFinal"), TypeFunctions.hasClassFieldFlag(cf, CfFinal) ? VTrue : VFalse);
		f.set(EvalHash.hash("isAbstract"), TypeFunctions.hasClassFieldFlag(cf, CfAbstract) ? VTrue : VFalse);
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeClassRelation(ec:EvalContext, rel:TClassWithParams):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("t"), encodeClassRef(ec, rel.c));
		f.set(EvalHash.hash("params"), encodeArray([for (p in rel.params) encodeType(ec, p)]));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeAbstractBinop(ec:EvalContext, op:TAbstractOp):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("op"), encodeBinop(ec, op.op));
		f.set(EvalHash.hash("field"), encodeClassField(ec, op.cf));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeAbstractUnop(ec:EvalContext, op:TAbstractUnop):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("op"), encodeUnop(ec, op.op));
		f.set(EvalHash.hash("postFix"), op.flag == Postfix ? VTrue : VFalse);
		f.set(EvalHash.hash("field"), encodeClassField(ec, op.cf));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeAbstractCast(ec:EvalContext, t:T, cf:Null<TClassField>):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("t"), encodeType(ec, t));
		f.set(EvalHash.hash("field"), cf == null ? VNull : encodeClassField(ec, cf));
		return VObject(new VObject([], ODictionary(f)));
	}

	// A macro Ref is a haxe.macro.Ref instance whose only fields are get and toString; the value it
	// stands for rides in the ikind (IRef), which is not a field at all, so no walk over a Ref -
	// Reflect.fields, and the value signature above all - sees an extra field. A standalone prototype
	// that is not one of the context's types, so Type.getClass of a Ref finds nothing.
	static var refProtoCache:Null<VPrototype> = null;

	static function refProto(ec:EvalContext):VPrototype {
		if (refProtoCache != null) return refProtoCache;
		var names:Map<Int, Int> = new Map();
		names.set(EvalHash.keyGet, 0);
		names.set(EvalHash.key_toString, 1);
		var proto = new VPrototype(EvalHash.hash("haxe.macro.Ref"), [], new Map(), [VNull, VNull], names, null, PInstance, VNull);
		proto.pvalue = VPrototype(proto);
		refProtoCache = proto;
		return proto;
	}

	// A bare haxe.macro.Unsafe instance with no fields, holding the value in its ikind. It is what a
	// tvar object's `$` field carries.
	static var unsafeProtoCache:Null<VPrototype> = null;

	static var opaqueProtos:Map<String, VPrototype> = new Map();

	// A standalone prototype that is not one of the context's types.
	static function fakeProto(path:String):VPrototype {
		var proto = opaqueProtos.get(path);
		if (proto == null) {
			proto = new VPrototype(EvalHash.hash(path), [], new Map(), [], new Map(), null, PInstance, VNull);
			proto.pvalue = VPrototype(proto);
			opaqueProtos.set(path, proto);
		}
		return proto;
	}

	static function opaqueValue(path:String, id:Int):EvalValue {
		var proto = opaqueProtos.get(path);
		if (proto == null) {
			proto = new VPrototype(EvalHash.hash(path), [], new Map(), [], new Map(), null, PInstance, VNull);
			proto.pvalue = VPrototype(proto);
			opaqueProtos.set(path, proto);
		}
		return VInstance(new VInstance([], proto, IRef(VInt(id))));
	}

	static function unsafeValue(ec:EvalContext, id:Int):EvalValue {
		if (unsafeProtoCache == null) {
			var proto = new VPrototype(EvalHash.hash("haxe.macro.Unsafe"), [], new Map(), [], new Map(), null, PInstance, VNull);
			proto.pvalue = VPrototype(proto);
			unsafeProtoCache = proto;
		}
		return VInstance(new VInstance([], unsafeProtoCache, IRef(VInt(id))));
	}

	// The Ref itself: get and toString in the prototype's slot order, the handle in the ikind.
	static function makeRef(ec:EvalContext, getFn:VFunc, toStringFn:VFunc, id:Int):EvalValue {
		return VInstance(new VInstance([VFunction(getFn, true), VFunction(toStringFn, true)], refProto(ec), IRef(VInt(id))));
	}

	// The handle a Ref (or a tvar object's `$`) carries, or null when the value is not one of ours.
	static function refHandle(ec:EvalContext, v:EvalValue):Null<Int> {
		return switch (EvalValueTools.vresolve(v)) {
			case VInstance({ikind: IRef(VInt(id))}): id;
			case VObject(_):
				// A module type's `__t`, or a tvar object's `$`
				var t = EvalField.field(ec, v, EvalHash.hash("__t"));
				refHandle(ec, t != VNull ? t : EvalField.field(ec, v, EvalHash.hash("$")));
			case _: null;
		};
	}

	// The class kind; KGenericBuild carries nothing.
	static function encodeClassKind(ec:EvalContext, k:TClassKind):EvalValue {
		return switch (k) {
			case KNormal: mkEnumValue(ec, "ClassKind", "KNormal", []);
			case KTypeParameter(tl): mkEnumValue(ec, "ClassKind", "KTypeParameter", [encodeArray([for (t in tl) encodeType(ec, t)])]);
			case KModuleFields(m): mkEnumValue(ec, "ClassKind", "KModuleFields", [mkString(Context.pathKey(m.path))]);
			case KExpr(e): mkEnumValue(ec, "ClassKind", "KExpr", [encodeExpr(ec, e)]);
			case KGeneric: mkEnumValue(ec, "ClassKind", "KGeneric", []);
			case KGenericInstance(cl, params): mkEnumValue(ec, "ClassKind", "KGenericInstance", [encodeClassRef(ec, cl), encodeArray([for (t in params) encodeType(ec, t)])]);
			case KMacroType: mkEnumValue(ec, "ClassKind", "KMacroType", []);
			case KAbstractImpl(a): mkEnumValue(ec, "ClassKind", "KAbstractImpl", [encodeAbstractRef(ec, a)]);
			case KGenericBuild(_): mkEnumValue(ec, "ClassKind", "KGenericBuild", []);
		};
	}

	static function encodeClassRef(ec:EvalContext, c:TClass):EvalValue {
		var refId = nextModuleTypeRefId++;
		moduleTypeRefs.set(refId, TClassDecl(c));
		return makeRef(ec, function(_) return encodeClassType(ec, c), function(_) return mkString(Context.pathKey(c.path)), refId);
	}

	static function encodeClassFieldRef(ec:EvalContext, cf:TClassField):EvalValue {
		var refId = nextCfieldRefId++;
		cfieldRefs.set(refId, cf);
		return makeRef(ec, function(_) return encodeClassField(ec, cf), function(_) return mkString(cf.name), refId);
	}

	static function encodeEnumRef(ec:EvalContext, e:TEnum):EvalValue {
		var refId = nextModuleTypeRefId++;
		moduleTypeRefs.set(refId, TEnumDecl(e));
		return makeRef(ec, function(_) return encodeEnumType(ec, e), function(_) return mkString(Context.pathKey(e.path)), refId);
	}

	static function encodeDefRef(ec:EvalContext, d:TDef):EvalValue {
		var refId = nextModuleTypeRefId++;
		moduleTypeRefs.set(refId, TTypeDecl(d));
		return makeRef(ec, function(_) return encodeDefType(ec, d), function(_) return mkString(Context.pathKey(d.path)), refId);
	}

	static function encodeAbstractRef(ec:EvalContext, a:TAbstract):EvalValue {
		var refId = nextModuleTypeRefId++;
		moduleTypeRefs.set(refId, TAbstractDecl(a));
		return makeRef(ec, function(_) return encodeAbstractType(ec, a), function(_) return mkString(Context.pathKey(a.path)), refId);
	}

	static function classWithParamsValue(ec:EvalContext, c:TClassWithParams):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("c"), encodeClassRef(ec, c.c));
		f.set(EvalHash.hash("params"), encodeArray([for (p in c.params) encodeType(ec, p)]));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeEnumField(ec:EvalContext, ef:TEnumField):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("name"), mkString(ef.name));
		f.set(EvalHash.hash("type"), encodeType(ec, ef.type));
		f.set(EvalHash.hash("pos"), encPos(ef.pos));
		f.set(EvalHash.hash("namePos"), encPos(ef.namePos));
		f.set(EvalHash.hash("doc"), encodeDoc(Ast.getOwnDocOpt(ef.doc)));
		f.set(EvalHash.hash("index"), VInt(ef.index));
		f.set(EvalHash.hash("params"), encodeArray([for (tp in ef.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return ef.meta, function(m) ef.meta = m));
		return VObject(new VObject([], ODictionary(f)));
	}

	// haxe.macro.Type.ClassType. Refs (super/fields/statics) are lazy so a class can reference itself
	// without infinite recursion.
	static function encodeClassType(ec:EvalContext, c:TClass):EvalValue {
		// Encoding a class forces its build first.
		hxc.typing.TypeResolve.forceQueuedBuild(c);
		var f:Map<Int, EvalValue> = new Map();
		// The hidden ref handle round-trips the decl through decode.
		stashModuleTypeRef(f, TClassDecl(c));
		f.set(EvalHash.hash("pack"), encodeArray([for (s in c.path.pack) mkString(s)]));
		f.set(EvalHash.hash("name"), mkString(c.path.name));
		f.set(EvalHash.hash("module"), mkString(c.module == null ? c.path.name : Context.pathKey(c.module.path)));
		f.set(EvalHash.hash("pos"), encPos(c.pos));
		f.set(EvalHash.hash("isPrivate"), c.isPrivate ? VTrue : VFalse);
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return c.meta, function(m) c.meta = m));
		f.set(EvalHash.hash("doc"), encodeDoc(Ast.getOwnDocOpt(c.doc)));
		f.set(EvalHash.hash("params"), encodeArray([for (tp in c.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("kind"), encodeClassKind(ec, c.kind));
		f.set(EvalHash.hash("isExtern"), TypeFunctions.hasClassFlag(c, CExtern) ? VTrue : VFalse);
		f.set(EvalHash.hash("isInterface"), TypeFunctions.hasClassFlag(c, CInterface) ? VTrue : VFalse);
		f.set(EvalHash.hash("isFinal"), TypeFunctions.hasClassFlag(c, CFinal) ? VTrue : VFalse);
		f.set(EvalHash.hash("isAbstract"), TypeFunctions.hasClassFlag(c, CAbstract) ? VTrue : VFalse);
		f.set(EvalHash.hash("superClass"), c.superClass == null ? VNull : encodeClassRelation(ec, c.superClass));
		f.set(EvalHash.hash("interfaces"), encodeArray([for (i in c.interfaces) encodeClassRelation(ec, i)]));
		f.set(EvalHash.hash("fields"), encodeLazyRef(ec, function() return encodeArray([for (cf in c.orderedFields) encodeClassField(ec, cf, c)])));
		f.set(EvalHash.hash("statics"), encodeLazyRef(ec, function() return encodeArray([for (cf in c.orderedStatics) encodeClassField(ec, cf, c)])));
		f.set(EvalHash.hash("constructor"), c.constructor == null ? VNull : encodeLazyRef(ec, function() return encodeClassField(ec, c.constructor)));
		f.set(EvalHash.hash("init"), c.init == null ? VNull : encodeTypedExpr(ec, c.init));
		f.set(EvalHash.hash("overrides"), encodeArray([for (cf in c.orderedFields) if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)) encodeClassFieldRef(ec, cf)]));
		// Exclude() makes the class extern and drops its init.
		f.set(EvalHash.hash("exclude"), VFunction(function(_) {
			TypeFunctions.addClassFlag(c, CExtern);
			c.init = null;
			return VNull;
		}, true));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeEnumType(ec:EvalContext, e:TEnum):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		stashModuleTypeRef(f, TEnumDecl(e));
		f.set(EvalHash.hash("pack"), encodeArray([for (s in e.path.pack) mkString(s)]));
		f.set(EvalHash.hash("name"), mkString(e.path.name));
		f.set(EvalHash.hash("module"), mkString(e.module == null ? e.path.name : Context.pathKey(e.module.path)));
		f.set(EvalHash.hash("pos"), encPos(e.pos));
		f.set(EvalHash.hash("isPrivate"), e.isPrivate ? VTrue : VFalse);
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return e.meta, function(m) e.meta = m));
		f.set(EvalHash.hash("doc"), encodeDoc(Ast.getOwnDocOpt(e.doc)));
		f.set(EvalHash.hash("params"), encodeArray([for (tp in e.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("isExtern"), e.isExtern ? VTrue : VFalse);
		// Exclude() makes the enum extern.
		f.set(EvalHash.hash("exclude"), VFunction(function(_) { e.isExtern = true; return VNull; }, true));
		// A haxe.ds.StringMap, so get/exists/keys work on it.
		var constrs:Map<String, EvalValue> = new Map();
		for (name in e.names) {
			var ef = e.constrs.get(name);
			if (ef != null) constrs.set(name, encodeEnumField(ec, ef));
		}
		f.set(EvalHash.hash("constructs"), EvalStdLib.mkStringMapValues(ec, constrs));
		f.set(EvalHash.hash("names"), encodeArray([for (name in e.names) mkString(name)]));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeTypeParameterValue(ec:EvalContext, tp:TypedTypeParam):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("name"), mkString(tp.name));
		f.set(EvalHash.hash("t"), encodeType(ec, tp.type));
		f.set(EvalHash.hash("defaultType"), tp.defaultType == null ? VNull : encodeType(ec, tp.defaultType));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeDefType(ec:EvalContext, d:TDef):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		stashModuleTypeRef(f, TTypeDecl(d));
		f.set(EvalHash.hash("pack"), encodeArray([for (s in d.path.pack) mkString(s)]));
		f.set(EvalHash.hash("name"), mkString(d.path.name));
		f.set(EvalHash.hash("module"), mkString(d.module == null ? d.path.name : Context.pathKey(d.module.path)));
		f.set(EvalHash.hash("pos"), encPos(d.pos));
		f.set(EvalHash.hash("isPrivate"), d.isPrivate ? VTrue : VFalse);
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return d.meta, function(m) d.meta = m));
		f.set(EvalHash.hash("doc"), encodeDoc(Ast.getOwnDocOpt(d.doc)));
		f.set(EvalHash.hash("params"), encodeArray([for (tp in d.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("type"), encodeType(ec, d.type));
		// A typedef is never extern and exclude() does nothing.
		f.set(EvalHash.hash("isExtern"), VFalse);
		f.set(EvalHash.hash("exclude"), VFunction(function(_) return VNull, true));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeAbstractType(ec:EvalContext, a:TAbstract):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		stashModuleTypeRef(f, TAbstractDecl(a));
		f.set(EvalHash.hash("pack"), encodeArray([for (s in a.path.pack) mkString(s)]));
		f.set(EvalHash.hash("name"), mkString(a.path.name));
		f.set(EvalHash.hash("module"), mkString(a.module == null ? a.path.name : Context.pathKey(a.module.path)));
		f.set(EvalHash.hash("pos"), encPos(a.pos));
		f.set(EvalHash.hash("isPrivate"), a.isPrivate ? VTrue : VFalse);
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return a.meta, function(m) a.meta = m));
		f.set(EvalHash.hash("doc"), encodeDoc(Ast.getOwnDocOpt(a.doc)));
		f.set(EvalHash.hash("params"), encodeArray([for (tp in a.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("type"), encodeType(ec, a.thisType));
		f.set(EvalHash.hash("binops"), encodeArray([for (op in a.ops) encodeAbstractBinop(ec, op)]));
		f.set(EvalHash.hash("unops"), encodeArray([for (op in a.unops) encodeAbstractUnop(ec, op)]));
		f.set(EvalHash.hash("array"), encodeArray([for (cf in a.array) encodeClassField(ec, cf)]));
		f.set(EvalHash.hash("from"), encodeArray([for (t in a.from) encodeAbstractCast(ec, t, null)].concat([for (c in a.fromField) encodeAbstractCast(ec, c.t, c.cf)])));
		f.set(EvalHash.hash("to"), encodeArray([for (t in a.to) encodeAbstractCast(ec, t, null)].concat([for (c in a.toField) encodeAbstractCast(ec, c.t, c.cf)])));
		f.set(EvalHash.hash("impl"), a.impl == null ? VNull : encodeClassRef(ec, a.impl));
		f.set(EvalHash.hash("resolve"), a.read == null ? VNull : encodeClassFieldRef(ec, a.read));
		f.set(EvalHash.hash("resolveWrite"), a.write == null ? VNull : encodeClassFieldRef(ec, a.write));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeTypeFunArg(ec:EvalContext, a:TSignatureArg):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(a.name));
		fields.set(EvalHash.hash("opt"), a.opt ? VTrue : VFalse);
		fields.set(EvalHash.hash("t"), encodeType(ec, a.t));
		return VObject(new VObject([], ODictionary(fields)));
	}
}

// A decoder handed the wrong kind of value. Converted at the native boundary into the macro's uncaught
// exception, or by a build's decoding guard into its decoding report.
class DecodeFailure extends haxe.Exception {
	public final text:String;
	public function new(text:String) {
		super(text);
		this.text = text;
	}
}
