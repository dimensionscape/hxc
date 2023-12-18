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
	static var building:Bool = false;
	static var curPos:Position = Position.nullPos;
	static var curModule:Null<ModuleDef> = null;
	static var curTctx:Null<TyperContext> = null;
	static var expectedTypeStack:Array<WithType> = [];
	static var curBuildFields:EvalValue = VNull;
	static var curBuildClass:Null<TClass> = null;
	static var curBuildParams:TParams = [];
	static var currentCom:Null<Context> = null;
	static var macroMessages:Array<EvalValue> = [];
	static var builtClasses:Map<String, Bool> = new Map();
	static var onGenerateCallbacks:Array<{ec:EvalContext, fn:EvalValue}> = [];
	static var macroMonoId:Int = 0;
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
	static var nextAnonRefId:Int = 0;

	static function stashModuleTypeRef(f:Map<Int, EvalValue>, mt:ModuleType):Void {
		var refId = nextModuleTypeRefId++;
		moduleTypeRefs.set(refId, mt);
		f.set(EvalHash.hash("$"), VInt(refId));
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
			catch (te:TypingError) return throwMacroError(ec, te.message, te.pos);
		};
		list.push({name: EvalHash.hash(fieldName), v: VFunction(wrapped, true)});
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
				if (found == null) throw new TypingError("unable to find file for inclusion: " + file, curPos);
				found;
			};
			com.includeFiles.push({file: resolved, position: position});
			return VNull;
		});
		reg2("currentPos", "current_pos", function(a) return encPos(curPos));
		// Error/fatal_error abort at the given position. "error"/"fatal_error" (vfun3 msg p depth ->
		// raise (Error.Fatal_error (located msg p, depth))).
		reg2("error", "error", function(a) { throw new TypingError(strOf(a[0]), posArg(ec, a, 1, curPos)); });
		reg2("fatalError", "fatal_error", function(a) { throw new TypingError(strOf(a[0]), posArg(ec, a, 1, curPos)); });
		reg2("reportError", "report_error", function(a) { reportError(strOf(a[0]), posArg(ec, a, 1, curPos)); return VNull; });
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
		reg2("makeExpr", "make_expr", function(a) return makeExprValue(ec, a[0]));
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
		// Context.parse / parseInlineString both call load("do_parse")(expr, pos, inline). When not
		// inlined, every sub-expression position is rewritten to the given pos, so a parsed macro result
		// reports the call site, not line 1 of the parsed string.
		reg2("do_parse", "do_parse", function(a) {
			var p = posArg(ec, a, 1, curPos);
			var inlined = a.length > 2 && a[2] == VTrue;
			var e = hxc.parser.Parser.parseExprString(strOf(a[0]), p.file, com.defines, inlined);
			return encodeExpr(ec, inlined ? e : reanchorExpr(e, p));
		});
		reg2("parse", "parse", function(a) {
			var p = posArg(ec, a, 1, curPos);
			return encodeExpr(ec, reanchorExpr(hxc.parser.Parser.parseExprString(strOf(a[0]), p.file, com.defines), p));
		});
		reg2("parseInlineString", "parse_inline_string", function(a) return encodeExpr(ec, hxc.parser.Parser.parseExprString(strOf(a[0]), posArg(ec, a, 1, curPos).file, com.defines, true)));
		reg2("formatString", "format_string", function(a) return encodeExpr(ec, Typer.formatString(strOf(a[0]), curPos, com.defines)));
		// Context.typeof types the argument expression and returns its (resolved) macro Type; follow
		// resolves a type (encodeType already collapses bound monomorphs, so it is the identity here).
		reg2("typeof", "typeof", function(a) {
			if (curTctx == null) throw new TypingError("typeof outside a macro", curPos);
			var te = typeMacroExpr(curTctx, decodeExpr(ec, a[0], curPos));
			settleOpenReturns(te);
			return encodeType(ec, te.type);
		});
		reg2("typeExpr", "type_expr", function(a) {
			if (curTctx == null) throw new TypingError("typeExpr outside a macro", curPos);
			var te = typeMacroExpr(curTctx, decodeExpr(ec, a[0], curPos));
			settleOpenReturns(te);
			return encodeTypedExpr(ec, te);
		});
		// store_expr(e): type a syntax expression and store the typed expression, returning the syntax
		// marker `@:storedTypedExpr(id)` that re-types to it. /
		reg2("storeExpr", "store_expr", function(a) {
			if (curTctx == null) throw new TypingError("storeExpr outside a macro", curPos);
			var te = typeMacroExpr(curTctx, decodeExpr(ec, a[0], curPos));
			return encodeExpr(ec, Calls.typedExprToSyntax(curTctx, te));
		});
		// Type the expression and retain its type.
		reg2("typeAndStoreExpr", "type_and_store_expr", function(a) {
			if (curTctx == null) throw new TypingError("typeAndStoreExpr outside a macro", curPos);
			var te = typeMacroExpr(curTctx, decodeExpr(ec, a[0], curPos));
			var fields:Map<Int, EvalValue> = new Map();
			fields.set(EvalHash.hash("expr"), encodeExpr(ec, Calls.typedExprToSyntax(curTctx, te)));
			fields.set(EvalHash.hash("type"), encodeType(ec, te.type));
			return VObject(new VObject([], ODictionary(fields)));
		});
		// get_typed_expr(te): convert a typed expression back to a syntax expression. A value that is not a
		// decodable typed expression raises "Invalid expression".
		reg2("getTypedExpr", "get_typed_expr", function(a) {
			if (curTctx == null) throw new TypingError("getTypedExpr outside a macro", curPos);
			var te = decodeStoredTypedExpr(ec, a[0]);
			return encodeExpr(ec, Calls.typedExprToSyntax(curTctx, te));
		});
		// store_typed_expr(te): store the decoded typed expression and return the syntax marker
		// `@:storedTypedExpr(id)` that re-types to it.
		reg2("storeTypedExpr", "store_typed_expr", function(a) {
			if (curTctx == null) throw new TypingError("storeTypedExpr outside a macro", curPos);
			var te = decodeStoredTypedExpr(ec, a[0]);
			var id = curTctx.com.nextStoredTypedExprId++;
			curTctx.com.storedTypedExprs.set(id, te);
			var eid = new Expr(EConst(CInt(Std.string(id), null)), curPos);
			return encodeExpr(ec, new Expr(EMeta({name: ":storedTypedExpr", params: [], pos: Position.nullPos}, eid), curPos));
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
			var path = pathFromDotted(strOf(a[0]));
			var tpath:TypePath = hxc.ast.Ast.mkTypePath(path);
			return encodeType(ec, Typeload.loadInstance(com, [], tpath, curPos, true));
		});
		reg2("makeMonomorph", "make_monomorph", function(a) return encodeType(ec, TypeFunctions.mkMono()));
		reg2("unify", "unify", function(a) {
			if (curTctx == null) throw new TypingError("unify outside a macro", curPos);
			var t1 = decodeType(ec, a[0]);
			var t2 = decodeType(ec, a[1]);
			var e1 = TypeFunctions.mk(TObjectDecl([]), t1, Position.nullPos);
			return macroCastOrUnify(t2, e1) ? VTrue : VFalse;
		});
		reg2("resolveType", "resolve_type", function(a) {
			if (curTctx == null) throw new TypingError("resolveType outside a macro", curPos);
			var p = posArg(ec, a, 1, curPos);
			var t = Typeload.loadComplexType(curTctx.com, curTctx.typeParams, {ct: decodeComplexType(ec, a[0], p), pos: p});
			return encodeType(ec, t);
		});
		reg2("toComplexType", "to_complex_type", function(a) {
			var ct = typeToComplexType(decodeType(ec, a[0]));
			return ct == null ? VNull : encodeComplexType(ec, ct);
		});
		reg2("withImports", "with_imports", function(a) {
			var m = com.currentModule;
			if (m == null) throw new TypingError("withImports outside a module", curPos);
			var key = Context.pathKey(m.path);
			var old = com.moduleImports.get(key);
			var next = cloneImports(old);
			for (iv in arrOf(a[0])) addImportSpec(next, strOf(iv));
			for (uv in arrOf(a[1])) next.usings.push(pathFromDotted(strOf(uv)));
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
		reg2("s_type", "s_type", function(a) return mkString(macroTypeString(ec, a[0])));
		reg2("defineType", "define_type", function(a) {
			defineMacroType(ec, com, a[0], a.length > 1 ? a[1] : VNull);
			return VNull;
		});
		// Context.defineModule(path, types, imports, usings): build the module from decoded type
		// definitions and inject it.
		reg2("defineModule", "define_module", function(a) {
			var parts = strOf(a[0]).split(".");
			var path:hxc.core.Globals.Path = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
			if (!com.moduleLut.exists(Context.pathKey(path))) {
				var dp = Position.nullPos;
				var types = [for (tv in arrOf(a[1])) decodeTypeDefinition(ec, tv, dp)];
				var imports = (a.length > 2 && a[2] != VNull) ? [for (iv in arrOf(a[2])) decodeImport(ec, iv, dp)] : [];
				var usings = (a.length > 3 && a[3] != VNull) ? [for (uv in arrOf(a[3])) ({path: decodeTypePath(ec, uv), pos: dp} : PlacedTypePath)] : [];
				var m = hxc.context.ModuleLoader.defineModuleDecls(com, path, types, imports, usings, dp);
				hxc.typing.TypeResolve.resolveModule(com, m);
				for (mt in m.types) switch (mt) {
					case TClassDecl(c):
						hxc.typing.TypeFields.forceClassFields(com, c);
					case _:
				}
			}
			return VNull;
		});
		reg2("getBuildFields", "get_build_fields", function(a) return curBuildFields);
		// Context.getLocalType / getLocalClass (std reads TInst from this): the @:build target's type, or
		// outside a build macro the class containing the macro call (none for the null class), with empty
		// params.
		function localClass():Null<TClass> {
			if (curBuildClass != null) return curBuildClass;
			if (curTctx != null && curTctx.curclass != null && curTctx.curclass != TypeFunctions.nullClass) return curTctx.curclass;
			return null;
		}
		reg2("getLocalType", "get_local_type", function(a) {
			if (curBuildClass != null) return encodeType(ec, TInst(curBuildClass, curBuildParams));
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
		reg2("getConfiguration", "get_configuration", function(a) return getConfigurationValue(com));
		reg2("addGlobalMetadataImpl", "add_global_metadata_impl", function(a) return addGlobalMetadataValue(com, a));
		// Compiler.registerCustomDefine / registerCustomMetadata store user documentation entries. /
		// register_metadata_impl.
		inline function decodeUserDoc(o:EvalValue, src:EvalValue):hxc.context.Context.UserDocEntry {
			function strField(n:String):Null<String> {
				var v = EvalField.field(ec, o, EvalHash.hash(n));
				return v == VNull ? null : strOf(v);
			}
			function arrField(n:String):Array<String> {
				var v = EvalField.field(ec, o, EvalHash.hash(n));
				return v == VNull ? [] : [for (x in arrOf(v)) strOf(x)];
			}
			return {doc: strField("doc"), params: arrField("params"), platforms: arrField("platforms"), source: src == VNull ? null : strOf(src)};
		}
		reg2("registerDefineImpl", "register_define_impl", function(a) {
			var name = strOf(EvalField.field(ec, a[0], EvalHash.hash("define")));
			com.userDefines.set(name, decodeUserDoc(a[0], a.length > 1 ? a[1] : VNull));
			return VNull;
		});
		reg2("registerMetadataImpl", "register_metadata_impl", function(a) {
			var name = strOf(EvalField.field(ec, a[0], EvalHash.hash("metadata")));
			com.userMetas.set(name, decodeUserDoc(a[0], a.length > 1 ? a[1] : VNull));
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
		reg2("onGenerate", "on_generate", function(a) {
			onGenerateCallbacks.push({ec: ec, fn: a[0]});
			return VNull;
		});
		// eval.vm.Context.callMacroApi("<snake>") returns the builtin registered under that key.
		regBuiltin(ec, "eval.vm.Context", "callMacroApi", function(a) {
			var name = strOf(a[0]);
			var key = EvalHash.hash(name);
			var list = ec.builtins.staticBuiltins.get(EvalHash.hash("haxe.macro.Context"));
			if (list != null) for (e in list) if (e.name == key) return e.v;
			throw new TypingError("Macro API not implemented: " + name, curPos);
		});
		regBuiltin(ec, "haxe.macro.TypeTools", "toString", function(a) return mkString(macroTypeString(ec, a[0])));
	}

	static function cloneImports(old:Null<hxc.context.Context.ModuleImports>):hxc.context.Context.ModuleImports {
		var names = new haxe.ds.StringMap<hxc.context.Context.ImportedName>();
		var globals = new haxe.ds.StringMap<hxc.context.Context.ImportedGlobal>();
		if (old != null) {
			for (key in old.names.keys()) names.set(key, old.names.get(key));
			for (key in old.globals.keys()) globals.set(key, old.globals.get(key));
		}
		return new hxc.context.Context.ModuleImports(names, old == null ? [] : old.wildcards.copy(), old == null ? [] : old.usings.copy(), globals, old == null ? [] : old.rawImports.copy());
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
		var hostModule = hxc.context.ModuleLoader.defineTypeDecl(com, path, td.decl, td.pos);
		hostModule.extra.kind = MFake;
		addMacroTypeDependency(com, hostModule, moduleDependency, dp);
		hxc.typing.TypeResolve.resolveModule(com, hostModule);
		forceModuleClassFields(com, hostModule);

		if (!com.isMacro && hasMacroFields) {
			if (macroCom == null) {
				macroCom = com.cloneForMacro();
				hxc.context.ModuleLoader.attach(macroCom);
				hxc.context.ModuleLoader.initBasicTypes(macroCom);
			}
			var macroTd = decodeTypeDefinition(ec, v, dp);
			var macroModule = hxc.context.ModuleLoader.defineTypeDecl(macroCom, path, macroTd.decl, macroTd.pos);
			macroModule.extra.kind = MMacro;
			addMacroTypeDependency(macroCom, macroModule, moduleDependency, dp);
			hxc.typing.TypeResolve.resolveModule(macroCom, macroModule);
			forceModuleClassFields(macroCom, macroModule);
			staleMacroCtx = macroCtx;
			macroCtx = null;
			lastModuleCount = -1;
		}
	}

	static function addMacroTypeDependency(com:Context, m:ModuleDef, moduleDependency:EvalValue, p:Position):Void {
		if (moduleDependency != VNull) {
			var dep = hxc.context.ModuleLoader.loadModule(com, pathFromDotted(strOf(moduleDependency)), p);
			TypeFunctions.addDependency(m, dep);
		} else if (com.currentModule != null) {
			TypeFunctions.addDependency(m, com.currentModule);
		}
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

	static function addImportSpec(imports:hxc.context.Context.ModuleImports, raw:String):Void {
		var spec = StringTools.trim(raw);
		var alias:Null<String> = null;
		var asIndex = spec.indexOf(" as ");
		if (asIndex >= 0) {
			alias = StringTools.trim(spec.substr(asIndex + 4));
			spec = StringTools.trim(spec.substr(0, asIndex));
		}
		if (StringTools.endsWith(spec, ".*")) {
			imports.wildcards.push(pathFromDotted(spec.substr(0, spec.length - 2)));
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
		for (m in com.modules) for (mt in m.types) switch (mt) {
			case TClassDecl(c): ensureBuilt(com, c);
			case _:
		}
	}

	// Runs a class's build macros the first time the class is resolved: its own @:build plus any
	// @:autoBuild inherited from a superclass or implemented interface.
	public static function ensureBuilt(com:Context, c:TClass):Void {
		var key = c.path.pack.join(".") + "." + c.path.name;
		if (builtClasses.exists(key)) return;
		var entries = collectBuildEntries(c);
		if (entries.length == 0) return;
		builtClasses.set(key, true);
		// A build failure is recorded rather than raised so the rest of the module still types,
		// but the compile fails; the class keeps its declared fields.
		for (entry in entries) try runBuild(com, c, entry) catch (e:TypingError) {
			com.addDiagnostic(e.message, e.pos != null && e.pos != Position.nullPos ? e.pos : entry.pos, e.depth);
		} catch (e:haxe.Exception) {
			com.addDiagnostic("Build failure: " + e.message, entry.pos);
		}
	}

	static function collectBuildEntries(c:TClass):Array<MetadataEntry> {
		var entries:Array<MetadataEntry> = [];
		var own = findMeta(c.meta, ":build");
		if (own != null) entries.push(own);
		var seen:Map<String, Bool> = new Map();
		function visit(t:TClass):Void {
			var k = t.path.pack.join(".") + "." + t.path.name;
			if (seen.exists(k)) return;
			seen.set(k, true);
			var ab = findMeta(t.meta, ":autoBuild");
			if (ab != null) entries.push(ab);
			if (t.superClass != null) visit(t.superClass.c);
			for (i in t.interfaces) visit(i.c);
		}
		if (c.superClass != null) visit(c.superClass.c);
		for (i in c.interfaces) visit(i.c);
		return entries;
	}

	static function findMeta(meta:Metadata, name:String):Null<MetadataEntry> {
		for (e in meta) if (e.name == name) return e;
		return null;
	}

	static function runBuild(com:Context, c:TClass, entry:MetadataEntry):Void {
		runBuildInner(com, c, entry);
	}

	static function runBuildInner(com:Context, c:TClass, entry:MetadataEntry):Void {
		var declEntry = com.declOfType.get(Context.pathKey(c.path));
		if (declEntry == null) return;
		var d = switch (declEntry.decl) { case EClass(dd): dd; case _: return; };
		if (entry.params.length == 0) return;
		var callExpr = entry.params[0];
		// Load the macro's own module into the macro world so the interpreter includes it.
		switch (callExpr.expr) {
			case ECall(callee, _):
				var t = macroTarget(callee);
				if (t != null) loadMacroClass(com, {pack: t.pack, name: t.module}, t.method);
			case _:
		}
		var ec = getContext(com);
		var savedBuildClass = curBuildClass;
		var savedBuildParams = curBuildParams;
		var savedBuildFields = curBuildFields;
		var savedTctx = curTctx;
		var savedPos = curPos;
		var savedMod = com.currentModule;
		try {
			var buildTctx = new TyperContext(com);
			buildTctx.curclass = c;
			buildTctx.typeParams = c.params;
			buildTctx.tthis = TInst(c, TypeFunctions.extractParamTypes(c.params));
			com.currentModule = c.module;
			curTctx = buildTctx;
			curPos = callExpr.pos;
			curBuildClass = c;
			curBuildParams = TypeFunctions.extractParamTypes(c.params);
			curBuildFields = encodeArray([for (f in d.dData) encodeField(ec, f)]);
			var result = switch (callExpr.expr) {
				case ECall(callee, args): resolveMacroFn(ec, callee, callExpr.pos)([for (a in args) encodeExpr(ec, a)]);
				case _: throw new TypingError("@:build requires a macro call", callExpr.pos);
			};
			curTctx = savedTctx;
			curPos = savedPos;
			com.currentModule = savedMod;
			if (result == VNull) {
				curBuildClass = savedBuildClass;
				curBuildParams = savedBuildParams;
				curBuildFields = savedBuildFields;
				return;
			}
			var newFields = [for (fv in arrOf(result)) decodeField(ec, fv, d.dName.pos)];
			var newDef:Definition<ClassFlag, Array<ClassField>> = {dName: d.dName, dDoc: d.dDoc, dParams: d.dParams, dMeta: d.dMeta, dFlags: d.dFlags, dData: newFields};
			com.declOfType.set(Context.pathKey(c.path), {decl: EClass(newDef), pos: declEntry.pos});
			curBuildClass = savedBuildClass;
			curBuildParams = savedBuildParams;
			curBuildFields = savedBuildFields;
			hxc.context.ModuleLoader.rebuildFields(c, newFields);
			// Resolve the rewritten fields in the class's own module so its private sibling types (e.g. a
			// private typedef used in a field signature) resolve; a build triggered from another module's
			// typing (new C() -> ensureBuilt) would otherwise carry the caller's currentModule.
			var savedResolveMod = com.currentModule;
			com.currentModule = c.module;
			// The build macro rewrites fields only; the class heritage is already resolved, so re-resolve
			// just the field signatures (resolveClass would re-process extends and reject the set super).
			hxc.typing.TypeResolve.resolveClassFields(com, c, newDef, declEntry.pos);
			// Type the freshly added field bodies so their expr is set for the interpreter.
			hxc.typing.TypeFields.forceClassFields(com, c);
			com.currentModule = savedResolveMod;
		} catch (e:haxe.Exception) {
			curBuildClass = savedBuildClass;
			curBuildParams = savedBuildParams;
			curBuildFields = savedBuildFields;
			curTctx = savedTctx;
			curPos = savedPos;
			com.currentModule = savedMod;
			throw e;
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
	static function macroTarget(callee:Expr):Null<{pack:Array<String>, module:String, name:String, method:String}> {
		var segs = flattenExprPath(callee);
		if (segs == null || segs.length < 2) return null;
		var typeSegs = segs.slice(0, segs.length - 1);
		var typeIdx = -1;
		for (i in 0...typeSegs.length) {
			var ch = typeSegs[i].charCodeAt(0);
			if (ch >= "A".code && ch <= "Z".code) { typeIdx = i; break; }
		}
		if (typeIdx < 0) return null;
		return {pack: typeSegs.slice(0, typeIdx), module: typeSegs[typeIdx], name: typeSegs[typeSegs.length - 1], method: segs[segs.length - 1]};
	}

	static function resolveMacroFn(ec:EvalContext, callee:Expr, p:Position):VFunc {
		var t = macroTarget(callee);
		if (t == null) throw new TypingError("@:build target must be a static call", p);
		var proto = ec.staticPrototypes.get(EvalHash.pathHash({pack: t.pack, name: t.name}));
		if (proto == null) throw new TypingError("@:build macro class not loaded: " + t.name, p);
		var idx = proto.pnames.get(EvalHash.hash(t.method));
		if (idx == null) throw new TypingError("@:build macro not found: " + t.method, p);
		return switch (proto.pfields[idx]) { case VFunction(f, _): f; case _: throw new TypingError("Not a macro: " + t.method, p); };
	}

	// A typed constant argument reduced to its runtime value.
	static function makeConst(ec:EvalContext, e:TExpr):EvalValue {
		return switch (e.expr) {
			case TConst(TInt(i)): VInt(i);
			case TConst(TFloat(s)): VFloat(Std.parseFloat(s));
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
			var e = hxc.parser.Parser.parseExprString(s, macroPos.file, com.defines);
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
					if (t == null) throw new TypingError("--macro target must be a static call", e.pos);
					loadMacroClass(com, {pack: t.pack, name: t.module}, t.method, true);
					var ec = getContext(com);
					var savedPos = curPos;
					curPos = e.pos;
					// A macro method receives its arguments as expressions; a plain function (like
					// Compiler.nullSafety) receives constants: the arguments type against the function's
					// signature (so a malformed object literal errors here) and the typed constants convert
					// to values.
					var cf = macroWorldField({pack: t.pack, name: t.name}, t.method, {pack: t.pack, name: t.module});
					var isMacroFn = cf != null && cf.kind.match(Method(MethMacro));
					var sig = cf == null ? null : switch (TypeFunctions.follow(cf.type)) { case TFun(s2): s2; case _: null; };
					var vargs = if (isMacroFn) {
						[for (a in args) encodeExpr(ec, a)];
					} else if (sig != null) {
						var tctx = new hxc.typing.TyperContext(macroCom);
						var r = hxc.typing.Calls.unifyCallArgs(tctx, args, sig.args, sig.ret, e.pos);
						[for (te in r.el) makeConst(ec, te)];
					} else {
						[for (a in args) initMacroConstArg(ec, a)];
					}
					if (sig != null) while (vargs.length < sig.args.length) vargs.push(VNull);
					resolveMacroFn(ec, callee, e.pos)(vargs);
					curPos = savedPos;
				case _:
					throw new TypingError("--macro expects a call expression", e.pos);
			}
		}
	}

	public static function runGenerateCallbacks():Void {
		for (cb in onGenerateCallbacks) {
			EvalContext.setCtx(cb.ec);
			switch (cb.fn) {
				case VFunction(f, _): f([VArray(new VArray([], 0))]);
				case VFieldClosure(recv, f): f([recv, VArray(new VArray([], 0))]);
				case _:
			}
		}
	}

	public static function makeExprValue(ec:EvalContext, v:EvalValue):EvalValue {
		return encodeExpr(ec, valueToExpr(ec, v, Position.nullPos));
	}

	// Compiler.addGlobalMetadata: parse the meta string (an expression carrying leading metadata) and
	// record the path-filtered entry.
	public static function addGlobalMetadataValue(com:Context, a:Array<EvalValue>):EvalValue {
		var filter = strOf(a[0]);
		var metaSrc = strOf(a[1]);
		var recursive = a[2] == VTrue;
		var toTypes = a[3] == VTrue;
		var toFields = a[4] == VTrue;
		var e = hxc.parser.Parser.parseExprString(metaSrc + " null", "--macro", com.defines);
		function collect(e:Expr):Void switch (e.expr) {
			case EMeta(m, e1):
				com.globalMetadata.unshift({filter: filter == "" ? [] : filter.split("."), meta: m, recursive: recursive, toTypes: toTypes, toFields: toFields});
				collect(e1);
			case _:
		}
		collect(e);
		return VNull;
	}

	public static function getConfigurationValue(com:Context):EvalValue {
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
		var pc = com.platformConfig;
		var platformConfig = obj([
			{name: "staticTypeSystem", value: pc.isStatic ? VTrue : VFalse},
			{name: "sys", value: pc.sys ? VTrue : VFalse},
			{name: "padNulls", value: pc.padNulls ? VTrue : VFalse},
			{name: "addFinalReturn", value: pc.addFinalReturn ? VTrue : VFalse},
			{name: "overloadFunctions", value: pc.supportsOverload ? VTrue : VFalse},
			{name: "canSkipNonNullableArgument", value: pc.canSkipNonNullableArgument ? VTrue : VFalse},
			{name: "supportsFunctionEquality", value: VTrue},
			{name: "usesUtf16", value: pc.usesUtf16 ? VTrue : VFalse},
			{name: "thisBeforeSuper", value: VFalse},
			{name: "supportsThreads", value: pc.supportsThreads ? VTrue : VFalse},
			{name: "supportsUnicode", value: pc.supportsUnicode ? VTrue : VFalse},
			{name: "supportsRestArgs", value: pc.supportsRestArgs ? VTrue : VFalse},
			{name: "supportsAtomics", value: VFalse},
		]);
		var mainClass = com.mainClass == null ? VNull : obj([
			{name: "pack", value: strArray(com.mainClass.pack)},
			{name: "name", value: str(com.mainClass.name)},
		]);
		return obj([
			{name: "version", value: VInt(4307)},
			{name: "args", value: strArray(com.args)},
			{name: "debug", value: com.debug ? VTrue : VFalse},
			{name: "verbose", value: VFalse},
			{name: "foptimize", value: com.foptimize ? VTrue : VFalse},
			{name: "platform", value: str(hxc.core.Globals.platformName(com.platform))},
			{name: "platformConfig", value: platformConfig},
			{name: "stdPath", value: strArray(com.stdPath)},
			{name: "mainClass", value: mainClass},
			{name: "packageRules", value: obj([])},
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
	static function valueToExpr(ec:EvalContext, v:EvalValue, p:Position):Expr {
		inline function mk(ed:ExprDef):Expr return new Expr(ed, p);
		return switch (EvalValue.EvalValueTools.vresolve(v)) {
			case VNull: mk(EConst(CIdent("null")));
			case VTrue: mk(EConst(CIdent("true")));
			case VFalse: mk(EConst(CIdent("false")));
			case VInt(i): mk(EConst(CInt(Std.string(i), null)));
			case VFloat(f): mk(EConst(CFloat(Std.string(f), null)));
			case VString(s): mk(EConst(CString(s.sstring, SDoubleQuotes)));
			case VNativeString(s): mk(EConst(CString(s, SDoubleQuotes)));
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
				switch (o.oproto) {
					case OProto(proto): for (k in proto.pinstanceNames.keys()) add(EvalHash.revHash(k), o.ofields[proto.pinstanceNames.get(k)]);
					case ODictionary(m): for (k in m.keys()) add(EvalHash.revHash(k), m.get(k));
				}
				mk(EObjectDecl(fields));
			case VEnumValue(ev):
				var proto = EvalContext.getStaticPrototypeRaise(ec, ev.epath);
				var name = switch (proto.pkind) { case PEnum(ctors): ctors[ev.eindex].name; case _: throw "value_to_expr: not an enum"; };
				var ctorExpr = new Expr(EField(enumPathExpr(ec, ev.epath, p), name, EFNormal), p);
				ev.eargs.length == 0 ? ctorExpr : mk(ECall(ctorExpr, [for (a in ev.eargs) valueToExpr(ec, a, p)]));
			case VInstance(vi): switch (vi.ikind) {
				case IMap(m) if (vi.iproto.ppath == EvalHash.key_haxe_ds_IntMap
						|| vi.iproto.ppath == EvalHash.key_haxe_ds_StringMap
						|| vi.iproto.ppath == EvalHash.key_haxe_ds_ObjectMap
						|| vi.iproto.ppath == EvalHash.hash("haxe.ds.EnumValueMap")):
					mk(EArrayDecl([for (entry in m) mk(EBinop(OpArrow, valueToExpr(ec, entry.key, p), valueToExpr(ec, entry.value, p)))]));
				case _:
					EvalExceptions.excString(ec, "Cannot convert " + EvalExceptions.sValueKind(v) + " to expr");
			}
			case other: EvalExceptions.excString(ec, "Cannot convert " + EvalExceptions.sValueKind(other) + " to expr");
		};
	}

	public static function isMacroField(cf:TClassField):Bool {
		return switch (cf.kind) { case Method(MethMacro): true; case _: false; };
	}

	// The host compilation context, for macro-world builtins that must mutate host state
	// (defines, global metadata) while running inside the macro interpreter.
	public static var hostCom:Null<Context>;

	static function getContext(com:Context):EvalContext {
		hostCom = com;
		// A macro running mid-build (installAndForce types bodies that may contain macro calls) must
		// not trigger another rebuild -- that recurses without bound. While building, reuse what we have.
		if (macroCom == null) {
			macroCom = com.cloneForMacro();
			hxc.context.ModuleLoader.attach(macroCom);
			hxc.context.ModuleLoader.initBasicTypes(macroCom);
		}
		if (!building && (macroCtx == null || lastModuleCount != macroCom.modules.length)) {
			building = true;
			try {
				// The interpreter runs macro-world code, so build it from the macro context's modules
				// (macro defined, its own parse cache), never the host com. Context API queries still
				// target the host com (defines/types reflect the program being compiled).
				hxc.typing.TypeResolve.resolveAll(macroCom);
				hxc.typing.TypeFields.installLazy(macroCom);
				if (macroCtx == null) {
					if (Sys.getEnv("HXC_DEBUG_MACROCTX") != null) Sys.println("[macroctx] FULL BUILD, modules=" + macroCom.modules.length);
					var ec = EvalMain.create(true);
					registerContext(ec, com);
					EvalMain.addModules(ec, macroCom.modules);
					// A rebuild must not reset macro-world static state; carry static var values over from
					// the retired context.
					if (staleMacroCtx != null) {
						migrateMacroStatics(staleMacroCtx, ec);
						staleMacroCtx = null;
					}
					macroCtx = ec;
				} else if (macroCom.modules.length > lastModuleCount) {
					if (Sys.getEnv("HXC_DEBUG_MACROCTX") != null) Sys.println("[macroctx] EXTEND from " + lastModuleCount + " to " + macroCom.modules.length);
					// Extend the existing context with only the newly loaded modules. Rebuilding the whole
					// macro context on every macro-load (a suite macro-loads O(N) classes) would be O(N^2)
					// and exhaust the GC ("Too many heap sections").
					EvalMain.addModules(macroCtx, macroCom.modules.slice(lastModuleCount));
				}
				lastModuleCount = macroCom.modules.length;
			} catch (e:Dynamic) { building = false; throw e; }
			building = false;
		}
		EvalContext.setCtx(macroCtx);
		currentCom = com;
		return macroCtx;
	}

	static var macroCom:Context = null;

	// The macro-world context, when one exists; the unification force-hook uses it to type a
	// macro-world field body in its own context.
	public static function getMacroCom():Null<Context> return macroCom;

	// Adds modules loaded into the macro world after the interpreter was built (e.g. a module
	// pulled in by typing a method body on demand mid-eval) to the running interpreter.
	public static function syncMacroModules():Void {
		if (macroCtx == null || macroCom == null || building) return;
		if (macroCom.modules.length > lastModuleCount) {
			hxc.typing.TypeResolve.resolveAll(macroCom);
			hxc.typing.TypeFields.installLazy(macroCom);
			EvalMain.addModules(macroCtx, macroCom.modules.slice(lastModuleCount));
			lastModuleCount = macroCom.modules.length;
		}
	}
	static var staleMacroCtx:Null<EvalContext> = null;

	// Copy every static var value from a retired macro context into its replacement so mutable
	// macro-world state (e.g. an Expr cached in a macro class static) survives a rebuild.
	static function migrateMacroStatics(oldCtx:EvalContext, newCtx:EvalContext):Void {
		for (key in oldCtx.staticPrototypes.keys()) {
			var op = oldCtx.staticPrototypes.get(key);
			var np = newCtx.staticPrototypes.get(key);
			if (np == null) continue;
			var c = switch (newCtx.typeCache.get(key)) { case TClassDecl(c): c; case _: null; };
			if (c == null) continue;
			for (name in op.pnames.keys()) {
				var cf = c.statics.get(EvalHash.revHash(name));
				if (cf == null || !cf.kind.match(Var(_))) continue;
				var ni = np.pnames.get(name);
				if (ni != null) np.pfields[ni] = op.pfields[op.pnames.get(name)];
			}
		}
	}

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
		if (path.pack.length > 0) {
			var last = path.pack[path.pack.length - 1];
			if (last.length > 1 && last.charAt(0) == "_") {
				var pack = path.pack.copy();
				pack.pop();
				return {pack: pack, name: last.substr(1)};
			}
		}
		return path;
	}

	// Re-parse a macro's class under the macro defines (so its #if macro members exist) and install that
	// copy into the macro context. The host parses every module without macro, which drops the #if macro
	// members a macro function's body relies on. reference:
	static function loadMacroClass(host:Context, path:hxc.core.Globals.Path, ?fieldName:String, forceAll:Bool = false, ?modulePath:hxc.core.Globals.Path):Void {
		if (macroCom == null) {
			macroCom = host.cloneForMacro();
			hxc.context.ModuleLoader.attach(macroCom);
			hxc.context.ModuleLoader.initBasicTypes(macroCom);
		}
		try {
			// A sub-type's module file has a different name than the class; the caller passes the declaring
			// module's path. .
			var m = hxc.context.ModuleLoader.loadModule(macroCom, modulePath != null ? modulePath : macroLoadPath(path), Position.nullPos);
			hxc.typing.TypeResolve.resolveAll(macroCom);
			hxc.typing.TypeFields.installLazy(macroCom);
			for (mt in m.types) switch (mt) {
				// The named field may live on a secondary module type (Module.SubType.method), so any
				// module class carrying it qualifies alongside the main one.
				case TClassDecl(c) if ((c.path.name == path.name || (fieldName != null && c.statics.exists(fieldName))) && c.path.pack.join(".") == path.pack.join(".")):
					if (forceAll || fieldName == null)
						hxc.typing.TypeFields.forceClassFields(macroCom, c);
					else {
						var cf = c.statics.get(fieldName);
						if (cf == null) cf = c.fields.get(fieldName);
						if (cf != null) {
							hxc.typing.TypeFields.forceFieldBody(macroCom, c, cf);
							var needsRebuild = forceReachableStatics(macroCom, c, cf);
							if (macroCtx != null) {
								var key = EvalHash.pathHash(c.path);
								var fieldHash = EvalHash.hash(fieldName);
								var sp = macroCtx.staticPrototypes.get(key);
								var ip = macroCtx.instancePrototypes.get(key);
								if ((sp != null && !sp.pnames.exists(fieldHash)) || (ip != null && !ip.pnames.exists(fieldHash)))
									needsRebuild = true;
							}
							// A dependency or requested field typed only now, after its class's prototype
							// was built, leaves that prototype without a live slot; rebuild (state migrates).
							if (needsRebuild && macroCtx != null) {
								staleMacroCtx = macroCtx;
								macroCtx = null;
								lastModuleCount = -1;
							}
						}
					}
				case _:
			}
		} catch (_:Dynamic) {}
		// Extend the live macro context in place with only the newly loaded modules (never re-add all,
		// which would be O(N^2) across a suite's many macro-loads). Keeps the caller's `ec` valid.
		if (macroCtx != null && macroCom.modules.length > lastModuleCount) {
			EvalMain.addModules(macroCtx, macroCom.modules.slice(lastModuleCount));
			lastModuleCount = macroCom.modules.length;
		} else if (macroCtx != null && fieldName != null) {
			var proto = macroCtx.staticPrototypes.get(EvalHash.pathHash(path));
			if (proto == null || !proto.pnames.exists(EvalHash.hash(fieldName))) {
				staleMacroCtx = macroCtx;
				macroCtx = null;
				lastModuleCount = -1;
			}
		}
	}

	// Returns true when a body was typed for a field whose class already has a live prototype in the
	// macro context (that prototype's slot for it is a dead thrower and needs a rebuild).
	static function forceReachableStatics(com:Context, owner:TClass, root:TClassField):Bool {
		var staleProto = false;
		var seen = new Map<TClassField, Bool>();
		var scan:Null<TExpr>->Void = null;
		function forceAndScan(c:TClass, cf:TClassField):Void {
			if (seen.exists(cf)) return;
			seen.set(cf, true);
			if (cf.expr == null) {
				hxc.typing.TypeFields.forceFieldBody(com, c, cf);
				if (cf.expr != null && macroCtx != null && macroCtx.staticPrototypes.exists(EvalHash.pathHash(c.path)))
					staleProto = true;
			}
			scan(cf.expr);
		}
		scan = function(e:Null<TExpr>):Void {
			if (e == null) return;
			switch (e.expr) {
				case TField(e1, fa):
					scan(e1);
					switch (fa) {
						case FStatic(c, cf) | FInstance(c, _, cf):
							forceAndScan(c, cf);
						case FClosure(c, cf) if (c != null):
							forceAndScan(c.c, cf);
						case _:
					}
				case TParenthesis(e1) | TUnop(_, _, e1) | TThrow(e1) | TCast(e1, _) | TMeta(_, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1):
					scan(e1);
				case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2):
					scan(e1); scan(e2);
				case TObjectDecl(fields):
					for (f in fields) scan(f.expr);
				case TArrayDecl(el) | TBlock(el):
					for (x in el) scan(x);
				case TCall(e1, el):
					scan(e1); for (x in el) scan(x);
				case TNew(_, _, el):
					for (x in el) scan(x);
				case TIf(e1, e2, e3):
					scan(e1); scan(e2); scan(e3);
				case TWhile(e1, e2, _):
					scan(e1); scan(e2);
				case TSwitch(e1, cases, edef):
					scan(e1);
					for (c in cases) {
						for (v in c.values) scan(v);
						scan(c.expr);
					}
					scan(edef);
				case TTry(e1, catches):
					scan(e1);
					for (c in catches) scan(c.expr);
				case TFunction(tf):
					scan(tf.expr);
				case TVarExpr(_, eo):
					scan(eo);
				case TReturn(eo):
					scan(eo);
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_):
			}
		};
		seen.set(root, true);
		scan(root.expr);
		return staleProto;
	}

	public static function run(tctx:TyperContext, fa:FieldAccess, el:Array<Expr>, withType:WithType, p:Position):TExpr {
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
		var ec = getContext(tctx.com);
		var proto = isInstance ? ec.instancePrototypes.get(EvalHash.pathHash(path)) : ec.staticPrototypes.get(EvalHash.pathHash(path));
		var idx = proto == null ? null : proto.pnames.get(EvalHash.hash(fa.field.name));
		if (proto == null || idx == null) {
			// The macro field is absent because the host parsed the class without macro defined; load
			// the class from the macro world so its #if macro members are present.
			loadMacroClass(tctx.com, path, fa.field.name, false, hostClass.module != null ? hostClass.module.path : null);
			ec = getContext(tctx.com);
			proto = isInstance ? ec.instancePrototypes.get(EvalHash.pathHash(path)) : ec.staticPrototypes.get(EvalHash.pathHash(path));
			idx = proto == null ? null : proto.pnames.get(EvalHash.hash(fa.field.name));
		}
		if (proto == null) throw new TypingError("Macro type not loaded: " + path.name, p);
		if (idx == null) throw new TypingError("Macro not found: " + fa.field.name, p);
		var fn = switch (proto.pfields[idx]) {
			case VFunction(f, _): f;
			case _: throw new TypingError("Not a macro function: " + fa.field.name, p);
		};
		var savedTctx = curTctx;
		var savedPos = curPos;
		var savedModule = curModule;
		try {
			// The argument signature comes from the macro world: the host-context signature of a macro
			// method degrades its types to Dynamic, which would hide the Expr parameters.
			var sigCf = macroWorldField(path, fa.field.name, hostClass.module != null ? hostClass.module.path : null);
			var sigArgs = switch (TypeFunctions.follow((sigCf != null ? sigCf : fa.field).type)) { case TFun(s): s.args; case _: null; };
			var callEl = isInstance ? [Calls.typedExprToSyntax(tctx, fa.on)].concat(el) : el;
			var args = macroArgs(ec, callEl, sigArgs);
			if (isInstance) args.unshift(VNull);
			curTctx = tctx;
			curPos = p;
			curModule = callModule;
			expectedTypeStack.push(withType);
			var result = fn(args);
			expectedTypeStack.pop();
			var astExpr = decodeExpr(ec, result, p);
			curTctx = savedTctx;
			curPos = savedPos;
			curModule = savedModule;
			return Typer.typeExpr(tctx, astExpr, withType);
		} catch (e:haxe.Exception) {
			if (expectedTypeStack.length > 0 && expectedTypeStack[expectedTypeStack.length - 1] == withType) expectedTypeStack.pop();
			curTctx = savedTctx;
			curPos = savedPos;
			curModule = savedModule;
			throw e;
		}
	}

	// The macro-world class field for a host-context field, carrying the real (Expr-typed)
	// signature. Null when the macro world has no such class or field.
	static function macroWorldField(path:hxc.core.Globals.Path, fieldName:String, modulePath:Null<hxc.core.Globals.Path>):Null<TClassField> {
		if (macroCom == null) return null;
		var m = try hxc.context.ModuleLoader.loadModule(macroCom, modulePath != null ? modulePath : macroLoadPath(path), Position.nullPos) catch (_:Dynamic) return null;
		for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (c.path.name == path.name && c.path.pack.join(".") == path.pack.join(".")):
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
		var moduleFile = normalizeFile(m.extra.file);
		var posFile = normalizeFile(p.file);
		return moduleFile == posFile || StringTools.endsWith(moduleFile, "/" + posFile) || StringTools.endsWith(posFile, "/" + moduleFile);
	}

	static function normalizeFile(file:String):String {
		return StringTools.replace(file, "\\", "/").toLowerCase();
	}

	static function macroArgs(ec:EvalContext, el:Array<Expr>, sigArgs:Null<Array<TSignatureArg>>):Array<EvalValue> {
		if (sigArgs != null && sigArgs.length > 0) {
			var last = sigArgs[sigArgs.length - 1].t;
			var restT = restElemType(last);
			if (restT != null) return macroRestArgs(ec, el, sigArgs, restT);
			var arrayT = arrayExprElemType(last);
			if (arrayT != null) return macroRestArgs(ec, el, sigArgs, arrayT);
		}
		return [for (i in 0...el.length) macroArg(ec, el[i], (sigArgs != null && i < sigArgs.length) ? sigArgs[i].t : null)];
	}

	static function macroRestArgs(ec:EvalContext, el:Array<Expr>, sigArgs:Array<TSignatureArg>, restT:T):Array<EvalValue> {
		var fixed = sigArgs.length - 1;
		var out:Array<EvalValue> = [];
		for (i in 0...fixed) out.push(i < el.length ? macroArg(ec, el[i], sigArgs[i].t) : VNull);
		var rest:Array<EvalValue> = [];
		for (i in fixed...el.length) rest.push(macroArg(ec, el[i], restT));
		out.push(VArray(new VArray(rest, rest.length)));
		return out;
	}

	// An Expr (or ExprOf) macro parameter receives the reified expression; any other parameter type
	// receives the argument's constant value. Non-constant value arguments fall back to the reified
	// expression.
	static function macroArg(ec:EvalContext, e:Expr, pt:Null<T>):EvalValue {
		if (pt != null && !isExprParam(pt)) {
			var c = macroConstArg(ec, e);
			if (c.ok) return c.value;
		}
		return encodeExpr(ec, e);
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

	public static function runGenericBuild(com:Context, c:TClass, params:TParams, fields:Array<ClassField>, p:Position):T {
		var entry = findMeta(c.meta, ":genericBuild");
		if (entry == null) throw new TypingError(Context.sTypePath(c.path) + " is missing @:genericBuild meta. Was it removed by a macro?", p);
		if (entry.params.length != 1) throw new TypingError("genericBuild requires a single expression call parameter", p);
		var callExpr = entry.params[0];
		switch (callExpr.expr) {
			case ECall(callee, _):
				var t = macroTarget(callee);
				if (t != null) loadMacroClass(com, {pack: t.pack, name: t.module}, t.method);
			case _:
				throw new TypingError("genericBuild requires a single expression call parameter", p);
		}
		var ec = getContext(com);
		var savedBuildClass = curBuildClass;
		var savedBuildParams = curBuildParams;
		var savedBuildFields = curBuildFields;
		var savedTctx = curTctx;
		var savedPos = curPos;
		var savedMod = com.currentModule;
		try {
			var buildTctx = new TyperContext(com);
			buildTctx.curclass = c;
			buildTctx.typeParams = c.params;
			buildTctx.tthis = TInst(c, params);
			com.currentModule = c.module;
			curTctx = buildTctx;
			curPos = callExpr.pos;
			curBuildClass = c;
			curBuildParams = params;
			curBuildFields = encodeArray([for (f in fields) encodeField(ec, f)]);
			var result = switch (callExpr.expr) {
				case ECall(callee, args): resolveMacroFn(ec, callee, callExpr.pos)([for (a in args) encodeExpr(ec, a)]);
				case _: throw new TypingError("genericBuild requires a single expression call parameter", callExpr.pos);
			};
			if (result == VNull) {
				curBuildClass = savedBuildClass;
				curBuildParams = savedBuildParams;
				curBuildFields = savedBuildFields;
				curTctx = savedTctx;
				curPos = savedPos;
				com.currentModule = savedMod;
				return TypeFunctions.mkMono();
			}
			var ct = decodeComplexType(ec, result, p);
			curBuildClass = savedBuildClass;
			curBuildParams = savedBuildParams;
			curBuildFields = savedBuildFields;
			curTctx = savedTctx;
			curPos = savedPos;
			com.currentModule = savedMod;
			var ret = hxc.typing.Typeload.loadComplexType(com, c.params, {ct: ct, pos: p});
			return ret;
		} catch (e:haxe.Exception) {
			curBuildClass = savedBuildClass;
			curBuildParams = savedBuildParams;
			curBuildFields = savedBuildFields;
			curTctx = savedTctx;
			curPos = savedPos;
			com.currentModule = savedMod;
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
				case _: throw "macro decode: not an enum value";
			};
			case _: throw "macro decode: expected enum value";
		};
	}

	static function eargs(v:EvalValue):Array<EvalValue> {
		return switch (v) { case VEnumValue(ev): ev.eargs; case _: throw "macro decode: expected enum value"; };
	}

	static function strOf(v:EvalValue):String {
		return switch (v) { case VString(s): s.sstring; case VNativeString(s): s; case _: throw "macro decode: expected string"; };
	}

	static function intOf(v:EvalValue):Int {
		return switch (v) { case VInt(i): i; case _: throw "macro decode: expected int"; };
	}

	static function strOpt(v:EvalValue):Null<String> {
		return switch (v) { case VNull: null; case _: strOf(v); };
	}

	static function boolOf(v:EvalValue):Bool {
		return switch (v) { case VTrue: true; case _: false; };
	}

	static function arrOf(v:EvalValue):Array<EvalValue> {
		return switch (v) { case VArray(a): a.avalues.slice(0, a.alength); case VNull: []; case _: throw "macro decode: expected array"; };
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
						parts.length == 0 ? n.sstring : parts.join(".") + "." + n.sstring;
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
			case "TEnum" | "TInst" | "TType" | "TAbstract":
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

	static function macroCastOrUnify(tleft:T, eright:TExpr):Bool {
		var didCast = macroCheckCast(tleft, eright.type);
		if (didCast) return true;
		var didUnify = try {
			TypeUnification.unifyDefault(eright.type, tleft);
			true;
		} catch (_:UnifyError) false;
		return didUnify;
	}

	static function macroCheckCast(tleft:T, tright:T):Bool {
		var stack:Array<{tleft:T, tright:T}> = [];
		function loop(tleft:T, tright:T):Bool {
			if (TypeUnification.typeIseqDefault(tleft, tright)) return true;
			for (item in stack) if (TypeUnification.fastEq(tleft, item.tleft) && TypeUnification.fastEq(tright, item.tright)) return false;
			stack.push({tleft: tleft, tright: tright});
			var uctx = TypeUnification.defaultUnificationContext;
			var ok = switch [TypeFunctions.follow(tleft), TypeFunctions.follow(tright)] {
				case [TAbstract(a1, tl1), TAbstract(a2, tl2)]:
					try {
						TypeUnification.findToFrom(uctx, tright, tleft, a2, tl2, a1, tl1);
						true;
					} catch (_:hxc.core.NotFound) {
						false;
					}
				case [TAbstract(a, tl), _]:
					try {
						TypeUnification.findFrom(uctx, tright, a, tl);
						true;
					} catch (_:hxc.core.NotFound) {
						macroLoopAbstractFrom(a, tl, tleft, tright, loop);
					}
				case [_, TAbstract(a, tl)]:
					try {
						TypeUnification.findTo(uctx, tleft, a, tl);
						true;
					} catch (_:hxc.core.NotFound) {
						macroLoopAbstractTo(a, tl, tleft, tright, loop);
					}
				case _:
					false;
			}
			stack.pop();
			return ok;
		}
		return loop(tleft, tright);
	}

	static function macroLoopAbstractFrom(a:TAbstract, tl:Array<T>, tleft:T, tright:T, loop:T->T->Bool):Bool {
		for (tc in a.from) {
			if (!TypeUnification.typeIseqDefault(tc, tleft)
				&& loop(TypeFunctions.applyParams(a.params, tl, tc), tright))
				return true;
		}
		return false;
	}

	static function macroLoopAbstractTo(a:TAbstract, tl:Array<T>, tleft:T, tright:T, loop:T->T->Bool):Bool {
		for (tc in a.to) {
			if (!TypeUnification.typeIseqDefault(tc, tright)
				&& loop(tleft, TypeFunctions.applyParams(a.params, tl, tc)))
				return true;
		}
		return false;
	}

	static function decodeType(ec:EvalContext, v:EvalValue):T {
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
				args[0] == VNull ? TDynamic(null) : TDynamic(decodeType(ec, args[0]));
			case "TLazy":
				decodeType(ec, refGet(ec, args[0]));
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
		switch (EvalField.field(ec, v, EvalHash.hash("$"))) {
			case VInt(id) if (anonRefs.exists(id)): return TAnon(anonRefs.get(id));
			case _:
		}
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
		cf.meta = [];
		return cf;
	}

	static function decodeMonoRef(ec:EvalContext, v:EvalValue):TMono {
		return switch (EvalField.field(ec, v, EvalHash.hash("__hxc_mono_id"))) {
			case VInt(id):
				var m = macroMonos.get(id);
				if (m == null) throw new TypingError("Macro decode: unknown monomorph", curPos);
				m;
			case _:
				throw new TypingError("Macro decode: expected monomorph ref", curPos);
		};
	}

	static function moduleTypeFromRef(ec:EvalContext, v:EvalValue):ModuleType {
		// A ref built here round-trips the module type itself through the hidden `$` handle; the path
		// lookup below covers everything else.
		switch (EvalField.field(ec, v, EvalHash.hash("$"))) {
			case VInt(id) if (moduleTypeRefs.exists(id)): return moduleTypeRefs.get(id);
			case _:
		}
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
		if (v == VNull) return new Expr(EConst(CIdent("null")), dp);
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
		return switch (EvalField.field(ec, v, EvalHash.hash("$"))) {
			case VInt(id) if (tvarRefs.exists(id)): tvarRefs.get(id);
			case _: throw new TypingError("macro decode: expected tvar", curPos);
		};
	}

	static function classFieldFromRef(ec:EvalContext, v:EvalValue):TClassField {
		return switch (EvalField.field(ec, v, EvalHash.hash("$"))) {
			case VInt(id) if (cfieldRefs.exists(id)): cfieldRefs.get(id);
			case _: throw new TypingError("macro decode: expected class field ref", curPos);
		};
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

	static function decodeTypedExpr(ec:EvalContext, v:EvalValue):TExpr {
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
		com.raiseTypingErrors = true;
		var te = try Typer.typeExpr(ctx, e, WithTypeTools.value) catch (err:haxe.Exception) {
			com.raiseTypingErrors = oldRaise;
			if (com.diagnostics.length > before) com.diagnostics.resize(before);
			throw err;
		};
		com.raiseTypingErrors = oldRaise;
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
			case "ENew": ENew({path: decodeTypePath(ec, a[0]), pos: dp}, [for (e in arrOf(a[1])) decodeExpr(ec, e, dp)]);
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
			pos: dp
		};
	}

	static function decodeCatch(ec:EvalContext, v:EvalValue, dp:Position):Catch {
		var tv = EvalField.field(ec, v, EvalHash.hash("type"));
		return {
			name: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))), pos: dp},
			type: tv == VNull ? null : decodeTypeHint(ec, tv, dp),
			expr: decodeExpr(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp),
			pos: dp
		};
	}

	static function decodeTypeHint(ec:EvalContext, v:EvalValue, dp:Position):TypeHint {
		return {ct: decodeComplexType(ec, v, dp), pos: dp};
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
			case "TExtend": CTExtend([for (p in arrOf(a[0])) {path: decodeTypePath(ec, p), pos: dp}], [for (f in arrOf(a[1])) decodeField(ec, f, dp)]);
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
		return {name: strOf(EvalField.field(ec, v, EvalHash.hash("field"))), pos: dp, quotes: quotes, expr: decodeExpr(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp)};
	}

	static function decodeVar(ec:EvalContext, v:EvalValue, dp:Position):EVar {
		return {
			evName: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))), pos: dp},
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
		var access = [for (av in arrOf(EvalField.field(ec, v, EvalHash.hash("access")))) ({access: decodeAccess(ec, av), pos: pos} : PlacedAccess)];
		var kind = decodeFieldKind(ec, EvalField.field(ec, v, EvalHash.hash("kind")), pos);
		var meta = decodeMetadata(ec, EvalField.field(ec, v, EvalHash.hash("meta")), pos);
		return new ClassField({name: name, pos: pos}, null, pos, meta, access, kind);
	}

	static function decodeMetadata(ec:EvalContext, v:EvalValue, dp:Position):Metadata {
		return v == VNull ? [] : [for (mv in arrOf(v)) decodeMetadataEntry(ec, mv, dp)];
	}

	static function decodeMetadataEntry(ec:EvalContext, v:EvalValue, dp:Position):MetadataEntry {
		var name = strOf(EvalField.field(ec, v, EvalHash.hash("name")));
		var pv = EvalField.field(ec, v, EvalHash.hash("params"));
		var params = pv == VNull ? [] : [for (pe in arrOf(pv)) decodeExpr(ec, pe, dp)];
		return {name: name, params: params, pos: dp};
	}

	static function decodeAccess(ec:EvalContext, v:EvalValue):Access {
		return switch (ctorName(ec, v)) {
			case "APublic": APublic; case "APrivate": APrivate; case "AStatic": AStatic; case "AOverride": AOverride;
			case "ADynamic": ADynamic; case "AInline": AInline; case "AMacro": AMacro; case "AFinal": AFinal;
			case "AExtern": AExtern; case "AAbstract": AAbstract; case "AOverload": AOverload;
			case other: throw "macro decode: unhandled Access " + other;
		};
	}

	static function decodeFieldKind(ec:EvalContext, v:EvalValue, dp:Position):ClassFieldKind {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "FVar": FVar((a.length > 0 && a[0] != VNull) ? decodeTypeHint(ec, a[0], dp) : null, decodeExprOpt(ec, a.length > 1 ? a[1] : VNull, dp));
			case "FFun": FFun(decodeFunc(ec, a[0], dp));
			case "FProp": FProp({name: strOf(a[0]), pos: dp}, {name: strOf(a[1]), pos: dp}, (a.length > 2 && a[2] != VNull) ? decodeTypeHint(ec, a[2], dp) : null, decodeExprOpt(ec, a.length > 3 ? a[3] : VNull, dp));
			case other: throw "macro decode: unhandled FieldType " + other;
		};
	}

	static function decodeFunc(ec:EvalContext, v:EvalValue, dp:Position):Func {
		var args = [for (av in arrOf(EvalField.field(ec, v, EvalHash.hash("args")))) decodeFunctionArg(ec, av, dp)];
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
			name: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))), pos: dp},
			opt: boolOf(EvalField.field(ec, v, EvalHash.hash("opt"))),
			meta: decodeMetadata(ec, EvalField.field(ec, v, EvalHash.hash("meta")), dp),
			type: typeV == VNull ? null : decodeTypeHint(ec, typeV, dp),
			value: decodeExprOpt(ec, EvalField.field(ec, v, EvalHash.hash("value")), dp)
		};
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

	static function decodeImport(ec:EvalContext, v:EvalValue, dp:Position):Import {
		var path = [for (pv in arrOf(EvalField.field(ec, v, EvalHash.hash("path")))) ({name: strOf(EvalField.field(ec, pv, EvalHash.hash("name"))), pos: dp} : PlacedName)];
		var modeV = EvalField.field(ec, v, EvalHash.hash("mode"));
		var mode:ImportMode = switch (ctorName(ec, modeV)) {
			case "IAll": ImportMode.IAll;
			case "IAsName": ImportMode.IAsName({name: strOf(eargs(modeV)[0]), pos: dp});
			case _: ImportMode.INormal;
		};
		return {path: path, mode: mode};
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
				if (a.length > 0 && a[0] != VNull) flags.push(HExtends({path: decodeTypePath(ec, a[0]), pos: dp}));
				if (a.length > 1 && a[1] != VNull) for (iv in arrOf(a[1])) flags.push(HImplements({path: decodeTypePath(ec, iv), pos: dp}));
				if (a.length > 2 && boolOf(a[2])) flags.push(HInterface);
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
		return switch (ctorName(ec, kind)) {
			case "TDClass":
				var flags = decodeClassFlags(ec, kind, isExtern, pos);
				var def:Definition<ClassFlag, Array<ClassField>> = {dName: {name: name, pos: pos}, dDoc: null, dParams: params, dMeta: meta, dFlags: flags, dData: fields};
				{decl: EClass(def), pos: pos};
			case "TDAbstract":
				var flags = decodeAbstractFlags(ec, kind, isExtern, pos);
				var def:Definition<AbstractFlag, Array<ClassField>> = {dName: {name: name, pos: pos}, dDoc: null, dParams: params, dMeta: meta, dFlags: flags, dData: fields};
				{decl: EAbstract(def), pos: pos};
			case other:
				throw new TypingError("defineType supports only TDClass/TDAbstract, got " + other, dp);
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
			case other: throw "macro decode: unhandled Constant " + other;
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
			case other: throw "macro decode: unhandled Binop " + other;
		};
	}

	static function decodeUnop(ec:EvalContext, v:EvalValue):Unop {
		return switch (ctorName(ec, v)) {
			case "OpIncrement": Increment; case "OpDecrement": Decrement;
			case "OpNot": Not; case "OpNeg": Neg; case "OpNegBits": NegBits; case "OpSpread": Spread;
			case other: throw "macro decode: unhandled Unop " + other;
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
		return VEnumValue(new VEnumValue(ef.index, args, EvalHash.pathHash(en.path), ef.namePos));
	}

	static function mkString(s:String):EvalValue {
		if (s == null) return VNull;
		var ns = EvalStdLib.normalizeString(s);
		return VString(new VString(ns, EvalStdLib.stringLength(ns)));
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
			case ENew(tp, el): mkEnumValue(ec, "ExprDef", "ENew", [encodeTypePath(ec, tp.path), encodeArray([for (e in el) encodeExpr(ec, e)])]);
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
			case ECast(e1, th): mkEnumValue(ec, "ExprDef", "ECast", [encodeExpr(ec, e1), th == null ? VNull : encodeComplexType(ec, th.ct)]);
			case EIs(e1, th): mkEnumValue(ec, "ExprDef", "EIs", [encodeExpr(ec, e1), encodeComplexType(ec, th.ct)]);
			case ECheckType(e1, th): mkEnumValue(ec, "ExprDef", "ECheckType", [encodeExpr(ec, e1), encodeComplexType(ec, th.ct)]);
			case EDisplay(e1, _): encodeExprDef(ec, e1.expr);
			case _: throw "macro encode: unhandled ExprDef";
		};
	}

	static function encodeVar(ec:EvalContext, ev:EVar):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(ev.evName.name));
		fields.set(EvalHash.hash("isFinal"), ev.evFinal ? VTrue : VFalse);
		fields.set(EvalHash.hash("isStatic"), ev.evStatic ? VTrue : VFalse);
		fields.set(EvalHash.hash("type"), ev.evType == null ? VNull : encodeComplexType(ec, ev.evType.ct));
		fields.set(EvalHash.hash("expr"), ev.evExpr == null ? VNull : encodeExpr(ec, ev.evExpr));
		fields.set(EvalHash.hash("meta"), encodeArray([for (m in ev.evMeta) encodeMetadataEntry(ec, m)]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeField(ec:EvalContext, f:ClassField):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(f.cffName.name));
		fields.set(EvalHash.hash("doc"), VNull);
		fields.set(EvalHash.hash("access"), encodeArray([for (pa in f.cffAccess) encodeAccess(ec, pa.access)]));
		fields.set(EvalHash.hash("kind"), encodeFieldKind(ec, f.cffKind));
		fields.set(EvalHash.hash("pos"), encPos(f.cffPos));
		fields.set(EvalHash.hash("meta"), encodeArray([for (m in f.cffMeta) encodeMetadataEntry(ec, m)]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeAccess(ec:EvalContext, a:Access):EvalValue {
		var name = switch (a) {
			case APublic: "APublic"; case APrivate: "APrivate"; case AStatic: "AStatic"; case AOverride: "AOverride";
			case ADynamic: "ADynamic"; case AInline: "AInline"; case AMacro: "AMacro"; case AFinal: "AFinal";
			case AExtern: "AExtern"; case AAbstract: "AAbstract"; case AOverload: "AOverload";
		};
		return mkEnumValue(ec, "Access", name, []);
	}

	static function encodeFieldKind(ec:EvalContext, k:ClassFieldKind):EvalValue {
		return switch (k) {
			case FVar(t, e): mkEnumValue(ec, "FieldType", "FVar", [t == null ? VNull : encodeComplexType(ec, t.ct), e == null ? VNull : encodeExpr(ec, e)]);
			case FFun(fn): mkEnumValue(ec, "FieldType", "FFun", [encodeFunc(ec, fn)]);
			case FProp(get, set, t, e): mkEnumValue(ec, "FieldType", "FProp", [mkString(get.name), mkString(set.name), t == null ? VNull : encodeComplexType(ec, t.ct), e == null ? VNull : encodeExpr(ec, e)]);
		};
	}

	static function encodeFunc(ec:EvalContext, f:Func):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("args"), encodeArray([for (a in f.fArgs) encodeFunctionArg(ec, a)]));
		fields.set(EvalHash.hash("ret"), f.fType == null ? VNull : encodeComplexType(ec, f.fType.ct));
		fields.set(EvalHash.hash("expr"), f.fExpr == null ? VNull : encodeExpr(ec, f.fExpr));
		fields.set(EvalHash.hash("params"), encodeArray([for (tp in f.fParams) encodeTparamDecl(ec, tp)]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	// Names follow hxc's simplified ABI (plain strings, no name_pos), matching encodeFunctionArg. Meta is
	// elided like the field/arg encoders.
	static function encodeTparamDecl(ec:EvalContext, tp:TypeParam):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(tp.tpName.name));
		fields.set(EvalHash.hash("params"), encodeArray([for (p in tp.tpParams) encodeTparamDecl(ec, p)]));
		fields.set(EvalHash.hash("constraints"), tp.tpConstraints == null ? encodeArray([]) : encodeArray([encodeComplexType(ec, tp.tpConstraints.ct)]));
		fields.set(EvalHash.hash("defaultType"), tp.tpDefault == null ? VNull : encodeComplexType(ec, tp.tpDefault.ct));
		fields.set(EvalHash.hash("meta"), encodeArray([]));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeFunctionArg(ec:EvalContext, a:FunctionArg):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(a.name.name));
		fields.set(EvalHash.hash("opt"), a.opt ? VTrue : VFalse);
		fields.set(EvalHash.hash("type"), a.type == null ? VNull : encodeComplexType(ec, a.type.ct));
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
		fields.set(EvalHash.hash("expr"), encodeExpr(ec, f.expr));
		fields.set(EvalHash.hash("quotes"), mkEnumValue(ec, "QuoteStatus", (switch (f.quotes) { case NoQuotes: "Unquoted"; case DoubleQuotes: "Quoted"; }), []));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeTypePath(ec:EvalContext, tp:TypePath):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("pack"), encodeArray([for (s in tp.tpackage) mkString(s)]));
		fields.set(EvalHash.hash("name"), mkString(tp.tname));
		fields.set(EvalHash.hash("params"), encodeArray([for (tpc in tp.tparams) encodeTypeParam(ec, tpc)]));
		fields.set(EvalHash.hash("sub"), tp.tsub == null ? VNull : mkString(tp.tsub));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeTypeParam(ec:EvalContext, tpc:TypeParamOrConst):EvalValue {
		return switch (tpc) {
			case TPType(th): mkEnumValue(ec, "TypeParam", "TPType", [encodeComplexType(ec, th.ct)]);
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
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeCatch(ec:EvalContext, c:Catch):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(c.name.name));
		// Preserve the catch type hint so a build macro that reads and re-emits a try/catch keeps the
		// declared catch type. Dropping it here made every round-tripped catch decode back to Dynamic,
		// which then bound the raw thrown value instead of a haxe.ValueException wrapper.
		fields.set(EvalHash.hash("type"), c.type == null ? VNull : encodeComplexType(ec, c.type.ct));
		fields.set(EvalHash.hash("expr"), encodeExpr(ec, c.expr));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeMetadataEntry(ec:EvalContext, m:MetadataEntry):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(m.name));
		fields.set(EvalHash.hash("params"), encodeArray([for (pe in m.params) encodeExpr(ec, pe)]));
		fields.set(EvalHash.hash("pos"), VNull);
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
				r.type == null ? null : typeToComplexType(r.type);
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
									var ct = typeToComplexType(t);
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

	static function encodeComplexType(ec:EvalContext, ct:ComplexType):EvalValue {
		return switch (ct) {
			case CTPath(tp): mkEnumValue(ec, "ComplexType", "TPath", [encodeTypePath(ec, tp)]);
			case CTFunction(args, ret): mkEnumValue(ec, "ComplexType", "TFunction", [encodeArray([for (a in args) encodeComplexType(ec, a.ct)]), encodeComplexType(ec, ret.ct)]);
			case CTAnonymous(fl): mkEnumValue(ec, "ComplexType", "TAnonymous", [encodeArray([for (f in fl) encodeField(ec, f)])]);
			case CTParent(t): mkEnumValue(ec, "ComplexType", "TParent", [encodeComplexType(ec, t.ct)]);
			case CTExtend(paths, fl): mkEnumValue(ec, "ComplexType", "TExtend", [encodeArray([for (pp in paths) encodeTypePath(ec, pp.path)]), encodeArray([for (f in fl) encodeField(ec, f)])]);
			case CTOptional(t): mkEnumValue(ec, "ComplexType", "TOptional", [encodeComplexType(ec, t.ct)]);
			case CTNamed(n, t): mkEnumValue(ec, "ComplexType", "TNamed", [mkString(n.name), encodeComplexType(ec, t.ct)]);
			case CTIntersection(tl): mkEnumValue(ec, "ComplexType", "TIntersection", [encodeArray([for (t in tl) encodeComplexType(ec, t.ct)])]);
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

	static function encodeTypedExpr(ec:EvalContext, e:TExpr):EvalValue {
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
		fields.set(EvalHash.hash("$"), VInt(refId));
		fields.set(EvalHash.hash("id"), VInt(v.id));
		fields.set(EvalHash.hash("name"), mkString(v.name));
		fields.set(EvalHash.hash("t"), encodeType(ec, v.type));
		fields.set(EvalHash.hash("capture"), VFalse);
		fields.set(EvalHash.hash("extra"), VNull);
		fields.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return v.meta, function(m) v.meta = m));
		fields.set(EvalHash.hash("isStatic"), VFalse);
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeModuleType(ec:EvalContext, mt:ModuleType):EvalValue {
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

	static function encodeRef(ec:EvalContext, payload:EvalValue, ?path:hxc.core.Globals.Path):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("get"), VFunction(function(_) return payload, true));
		// A macro Ref<T> also exposes toString() -- the type's dot path -- which Std.string of the
		// encoded Type enum uses; without it a base-type ref renders as its raw {get: ...} structure.
		if (path != null) fields.set(EvalHash.hash("toString"), VFunction(function(_) return mkString(Context.pathKey(path)), true));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeMonoRef(ec:EvalContext, m:TMono):EvalValue {
		var id = ++macroMonoId;
		macroMonos.set(id, m);
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("get"), VFunction(function(_) return m.type == null ? VNull : encodeType(ec, m.type), true));
		fields.set(EvalHash.hash("toString"), VFunction(function(_) return mkString("<mono>"), true));
		fields.set(EvalHash.hash("__hxc_mono_id"), VInt(id));
		return VObject(new VObject([], ODictionary(fields)));
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
		var fields:Map<Int, EvalValue> = new Map();
		var refId = nextAnonRefId++;
		anonRefs.set(refId, an);
		fields.set(EvalHash.hash("$"), VInt(refId));
		fields.set(EvalHash.hash("get"), VFunction(function(_) return payload(), true));
		fields.set(EvalHash.hash("toString"), VFunction(function(_) return mkString("<anonymous>"), true));
		return VObject(new VObject([], ODictionary(fields)));
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

	// A lazy Ref<T>: .get() computes the payload on demand. Refs must stay lazy so a class encoding
	// can reference itself (field types, super chain) without infinite recursion.
	static function encodeLazyRef(ec:EvalContext, thunk:Void->EvalValue):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("get"), VFunction(function(_) return thunk(), true));
		return VObject(new VObject([], ODictionary(fields)));
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
			case VNull:
				fallback;
			case VInstance(vi): switch (vi.ikind) {
				case IPos(p): p;
				case _: fallback;
			}
			case _:
				try new Position(strOf(EvalField.field(ec, v, EvalHash.hash("file"))), intOf(EvalField.field(ec, v, EvalHash.hash("min"))), intOf(EvalField.field(ec, v, EvalHash.hash("max"))))
				catch (_:Dynamic) fallback;
		};
	}

	static function posArg(ec:EvalContext, args:Array<EvalValue>, index:Int, fallback:Position):Position {
		return args.length > index ? posOf(ec, args[index], fallback) : fallback;
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
		var v:EvalValue = VInstance(new VInstance(proto.pinstanceFields.copy(), proto, INormal));
		EvalField.setField(ec, v, EvalHash.hash("message"), mkString(msg), pos);
		EvalField.setField(ec, v, EvalHash.hash("get_message"), VFunction(function(_) return mkString(msg), false), pos);
		EvalField.setField(ec, v, EvalHash.hash("pos"), posValue, pos);
		EvalField.setField(ec, v, EvalHash.hash("childErrors"), VNull, pos);
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
		if (currentCom != null) currentCom.addDiagnostic(msg, pos);
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
			meta.push({name: k, params: params, pos: Position.nullPos});
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
		f.set(EvalHash.hash("type"), encodeType(ec, cf.type));
		f.set(EvalHash.hash("isPublic"), TypeFunctions.hasClassFieldFlag(cf, CfPublic) ? VTrue : VFalse);
		f.set(EvalHash.hash("params"), encodeArray([]));
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
		f.set(EvalHash.hash("doc"), VNull);
		f.set(EvalHash.hash("overloads"), encodeLazyRef(ec, function() return encodeArray([for (ocf in cf.overloads) encodeClassField(ec, ocf)])));
		f.set(EvalHash.hash("isExtern"), VFalse);
		f.set(EvalHash.hash("isFinal"), VFalse);
		f.set(EvalHash.hash("isAbstract"), VFalse);
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

	static function encodeClassRef(ec:EvalContext, c:TClass):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		stashModuleTypeRef(f, TClassDecl(c));
		f.set(EvalHash.hash("get"), VFunction(function(_) return encodeClassType(ec, c), true));
		f.set(EvalHash.hash("toString"), VFunction(function(_) return mkString(Context.pathKey(c.path)), true));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeClassFieldRef(ec:EvalContext, cf:TClassField):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		var refId = nextCfieldRefId++;
		cfieldRefs.set(refId, cf);
		f.set(EvalHash.hash("$"), VInt(refId));
		f.set(EvalHash.hash("get"), VFunction(function(_) return encodeClassField(ec, cf), true));
		f.set(EvalHash.hash("toString"), VFunction(function(_) return mkString(cf.name), true));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeEnumRef(ec:EvalContext, e:TEnum):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		stashModuleTypeRef(f, TEnumDecl(e));
		f.set(EvalHash.hash("get"), VFunction(function(_) return encodeEnumType(ec, e), true));
		f.set(EvalHash.hash("toString"), VFunction(function(_) return mkString(Context.pathKey(e.path)), true));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeDefRef(ec:EvalContext, d:TDef):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		stashModuleTypeRef(f, TTypeDecl(d));
		f.set(EvalHash.hash("get"), VFunction(function(_) return encodeDefType(ec, d), true));
		f.set(EvalHash.hash("toString"), VFunction(function(_) return mkString(Context.pathKey(d.path)), true));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeAbstractRef(ec:EvalContext, a:TAbstract):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		stashModuleTypeRef(f, TAbstractDecl(a));
		f.set(EvalHash.hash("get"), VFunction(function(_) return encodeAbstractType(ec, a), true));
		f.set(EvalHash.hash("toString"), VFunction(function(_) return mkString(Context.pathKey(a.path)), true));
		return VObject(new VObject([], ODictionary(f)));
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
		f.set(EvalHash.hash("doc"), VNull);
		f.set(EvalHash.hash("index"), VInt(ef.index));
		f.set(EvalHash.hash("params"), encodeArray([]));
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return ef.meta, function(m) ef.meta = m));
		return VObject(new VObject([], ODictionary(f)));
	}

	// haxe.macro.Type.ClassType. Refs (super/fields/statics) are lazy so a class can reference itself
	// without infinite recursion.
	static function encodeClassType(ec:EvalContext, c:TClass):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("pack"), encodeArray([for (s in c.path.pack) mkString(s)]));
		f.set(EvalHash.hash("name"), mkString(c.path.name));
		f.set(EvalHash.hash("module"), mkString(c.module == null ? c.path.name : Context.pathKey(c.module.path)));
		f.set(EvalHash.hash("pos"), encPos(c.pos));
		f.set(EvalHash.hash("isPrivate"), VFalse);
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return c.meta, function(m) c.meta = m));
		f.set(EvalHash.hash("doc"), VNull);
		f.set(EvalHash.hash("params"), encodeArray([for (tp in c.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("kind"), mkEnumValue(ec, "ClassKind", "KNormal", []));
		f.set(EvalHash.hash("isExtern"), TypeFunctions.hasClassFlag(c, CExtern) ? VTrue : VFalse);
		f.set(EvalHash.hash("isInterface"), TypeFunctions.hasClassFlag(c, CInterface) ? VTrue : VFalse);
		f.set(EvalHash.hash("isFinal"), TypeFunctions.hasClassFlag(c, CFinal) ? VTrue : VFalse);
		f.set(EvalHash.hash("isAbstract"), VFalse);
		f.set(EvalHash.hash("superClass"), c.superClass == null ? VNull : encodeClassRelation(ec, c.superClass));
		f.set(EvalHash.hash("interfaces"), encodeArray([for (i in c.interfaces) encodeClassRelation(ec, i)]));
		f.set(EvalHash.hash("fields"), encodeLazyRef(ec, function() return encodeArray([for (cf in c.orderedFields) encodeClassField(ec, cf, c)])));
		f.set(EvalHash.hash("statics"), encodeLazyRef(ec, function() return encodeArray([for (cf in c.statics) encodeClassField(ec, cf, c)])));
		f.set(EvalHash.hash("constructor"), c.constructor == null ? VNull : encodeLazyRef(ec, function() return encodeClassField(ec, c.constructor)));
		f.set(EvalHash.hash("init"), VNull);
		f.set(EvalHash.hash("overrides"), encodeArray([]));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeEnumType(ec:EvalContext, e:TEnum):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("pack"), encodeArray([for (s in e.path.pack) mkString(s)]));
		f.set(EvalHash.hash("name"), mkString(e.path.name));
		f.set(EvalHash.hash("module"), mkString(e.module == null ? e.path.name : Context.pathKey(e.module.path)));
		f.set(EvalHash.hash("pos"), encPos(e.pos));
		f.set(EvalHash.hash("isPrivate"), e.isPrivate ? VTrue : VFalse);
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return e.meta, function(m) e.meta = m));
		f.set(EvalHash.hash("doc"), VNull);
		f.set(EvalHash.hash("params"), encodeArray([for (tp in e.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("isExtern"), e.isExtern ? VTrue : VFalse);
		var constrs:Map<Int, EvalValue> = new Map();
		for (name in e.names) {
			var ef = e.constrs.get(name);
			if (ef != null) constrs.set(EvalHash.hash(name), encodeEnumField(ec, ef));
		}
		f.set(EvalHash.hash("constructs"), VObject(new VObject([], ODictionary(constrs))));
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
		f.set(EvalHash.hash("pack"), encodeArray([for (s in d.path.pack) mkString(s)]));
		f.set(EvalHash.hash("name"), mkString(d.path.name));
		f.set(EvalHash.hash("module"), mkString(d.module == null ? d.path.name : Context.pathKey(d.module.path)));
		f.set(EvalHash.hash("pos"), encPos(d.pos));
		f.set(EvalHash.hash("isPrivate"), d.isPrivate ? VTrue : VFalse);
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return d.meta, function(m) d.meta = m));
		f.set(EvalHash.hash("doc"), VNull);
		f.set(EvalHash.hash("params"), encodeArray([for (tp in d.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("type"), encodeType(ec, d.type));
		return VObject(new VObject([], ODictionary(f)));
	}

	static function encodeAbstractType(ec:EvalContext, a:TAbstract):EvalValue {
		var f:Map<Int, EvalValue> = new Map();
		f.set(EvalHash.hash("pack"), encodeArray([for (s in a.path.pack) mkString(s)]));
		f.set(EvalHash.hash("name"), mkString(a.path.name));
		f.set(EvalHash.hash("module"), mkString(a.module == null ? a.path.name : Context.pathKey(a.module.path)));
		f.set(EvalHash.hash("pos"), encPos(a.pos));
		f.set(EvalHash.hash("isPrivate"), a.isPrivate ? VTrue : VFalse);
		f.set(EvalHash.hash("meta"), encodeMetaAccess(ec, function() return a.meta, function(m) a.meta = m));
		f.set(EvalHash.hash("doc"), VNull);
		f.set(EvalHash.hash("params"), encodeArray([for (tp in a.params) encodeTypeParameterValue(ec, tp)]));
		f.set(EvalHash.hash("type"), encodeType(ec, a.thisType));
		f.set(EvalHash.hash("binops"), encodeArray([for (op in a.ops) encodeAbstractBinop(ec, op)]));
		f.set(EvalHash.hash("unops"), encodeArray([for (op in a.unops) encodeAbstractUnop(ec, op)]));
		f.set(EvalHash.hash("array"), encodeArray([for (cf in a.array) encodeClassField(ec, cf)]));
		f.set(EvalHash.hash("from"), encodeArray([for (t in a.from) encodeAbstractCast(ec, t, null)].concat([for (c in a.fromField) encodeAbstractCast(ec, c.t, c.cf)])));
		f.set(EvalHash.hash("to"), encodeArray([for (t in a.to) encodeAbstractCast(ec, t, null)].concat([for (c in a.toField) encodeAbstractCast(ec, c.t, c.cf)])));
		f.set(EvalHash.hash("impl"), a.impl == null ? VNull : encodeClassRef(ec, a.impl));
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
