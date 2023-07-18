package hxc.eval;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypingError;
import hxc.core.WithType;
import hxc.context.Context;
import hxc.typing.TyperContext;
import hxc.typing.Typer;
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
	static var curTctx:Null<TyperContext> = null;
	static var curBuildFields:EvalValue = VNull;
	static var builtClasses:Map<String, Bool> = new Map();

	static function regBuiltin(ec:EvalContext, typeName:String, fieldName:String, f:VFunc):Void {
		var key = EvalHash.hash(typeName);
		var list = ec.builtins.staticBuiltins.get(key);
		if (list == null) { list = []; ec.builtins.staticBuiltins.set(key, list); }
		list.push({name: EvalHash.hash(fieldName), v: VFunction(f, true)});
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
		reg2("currentPos", "current_pos", function(a) return VNull);
		reg2("error", "error", function(a) { throw new TypingError(strOf(a[0]), curPos); });
		reg2("fatalError", "fatal_error", function(a) { throw new TypingError(strOf(a[0]), curPos); });
		reg2("warning", "warning", function(a) { Sys.println("Warning: " + strOf(a[0])); return VNull; });
		reg2("makeExpr", "make_expr", function(a) return makeExprValue(ec, a[0]));
		// Context.parse / parseInlineString both call load("do_parse")(expr, pos, inline). .
		reg2("do_parse", "do_parse", function(a) return encodeExpr(ec, hxc.parser.Parser.parseExprString(strOf(a[0]), "?")));
		// Context.typeof types the argument expression and returns its (resolved) macro Type; follow
		// resolves a type (encodeType already collapses bound monomorphs, so it is the identity here).
		reg2("typeof", "typeof", function(a) {
			if (curTctx == null) throw new TypingError("typeof outside a macro", curPos);
			var te = Typer.typeExpr(curTctx, decodeExpr(ec, a[0], curPos), NoValue);
			return encodeType(ec, te.type);
		});
		reg2("follow", "follow", function(a) return a[0]);
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
				hxc.context.ModuleLoader.defineModuleDecls(com, path, types, imports, usings, dp);
			}
			return VNull;
		});
		reg2("getBuildFields", "get_build_fields", function(a) return curBuildFields);
		reg2("makePosition", "make_position", function(a) {
			var m = new Map<Int, EvalValue>();
			m.set(EvalHash.hash("file"), a.length > 2 ? a[2] : VNull);
			m.set(EvalHash.hash("min"), a.length > 0 ? a[0] : VInt(0));
			m.set(EvalHash.hash("max"), a.length > 1 ? a[1] : VInt(0));
			return VObject(new VObject([], ODictionary(m)));
		});
		reg2("definedValue", "defined_value", function(a) {
			var k = strOf(a[0]);
			if (!com.defines.rawDefined(k)) return VNull;
			var v = com.defines.rawDefinedValue(k);
			return VString(new VString(v, v.length));
		});
		// eval.vm.Context.callMacroApi("<snake>") returns the builtin registered under that key.
		regBuiltin(ec, "eval.vm.Context", "callMacroApi", function(a) {
			var key = EvalHash.hash(strOf(a[0]));
			var list = ec.builtins.staticBuiltins.get(EvalHash.hash("haxe.macro.Context"));
			if (list != null) for (e in list) if (e.name == key) return e.v;
			throw new TypingError("Macro API not implemented: " + strOf(a[0]), curPos);
		});
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
		// A build failure must not abort the whole compile; the class keeps its declared fields.
		for (entry in entries) try runBuild(com, c, entry) catch (_:haxe.Exception) {}
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
		// Macro modules compile with `macro` defined so their #if macro sections are present.
		var hadMacro = com.defines.rawDefined("macro");
		if (!hadMacro) com.defines.rawDefine("macro");
		try runBuildInner(com, c, entry) catch (e:haxe.Exception) { if (!hadMacro) com.defines.values.remove("macro"); throw e; }
		if (!hadMacro) com.defines.values.remove("macro");
	}

	static function runBuildInner(com:Context, c:TClass, entry:MetadataEntry):Void {
		var declEntry = com.declOfType.get(Context.pathKey(c.path));
		if (declEntry == null) return;
		var d = switch (declEntry.decl) { case EClass(dd): dd; case _: return; };
		if (entry.params.length == 0) return;
		var callExpr = entry.params[0];
		// Load the macro's own module so the interpreter built below includes it.
		switch (callExpr.expr) {
			case ECall(callee, _):
				var t = macroTarget(callee);
				if (t != null) try hxc.context.ModuleLoader.loadModule(com, {pack: t.pack, name: t.name}, callExpr.pos) catch (_:Dynamic) {}
			case _:
		}
		var ec = getContext(com);
		curBuildFields = encodeArray([for (f in d.dData) encodeField(ec, f)]);
		var result = switch (callExpr.expr) {
			case ECall(callee, args): resolveMacroFn(ec, callee, callExpr.pos)([for (a in args) encodeExpr(ec, a)]);
			case _: throw new TypingError("@:build requires a macro call", callExpr.pos);
		};
		var newFields = [for (fv in arrOf(result)) decodeField(ec, fv, d.dName.pos)];
		var newDef:Definition<ClassFlag, Array<ClassField>> = {dName: d.dName, dDoc: d.dDoc, dParams: d.dParams, dMeta: d.dMeta, dFlags: d.dFlags, dData: newFields};
		com.declOfType.set(Context.pathKey(c.path), {decl: EClass(newDef), pos: declEntry.pos});
		hxc.context.ModuleLoader.rebuildFields(c, newFields);
		hxc.typing.TypeResolve.resolveClass(com, c, newDef, declEntry.pos);
		// Type the freshly added field bodies so their expr is set for the interpreter.
		hxc.typing.TypeFields.installAndForce(com);
	}

	static function flattenExprPath(e:Expr):Null<Array<String>> {
		return switch (e.expr) {
			case EConst(CIdent(s)): [s];
			case EField(e1, f, _): var pre = flattenExprPath(e1); pre == null ? null : pre.concat([f]);
			case _: null;
		};
	}

	static function macroTarget(callee:Expr):Null<{pack:Array<String>, name:String, method:String}> {
		var segs = flattenExprPath(callee);
		if (segs == null || segs.length < 2) return null;
		var typeSegs = segs.slice(0, segs.length - 1);
		var typeIdx = -1;
		for (i in 0...typeSegs.length) {
			var ch = typeSegs[i].charCodeAt(0);
			if (ch >= "A".code && ch <= "Z".code) { typeIdx = i; break; }
		}
		if (typeIdx < 0) return null;
		return {pack: typeSegs.slice(0, typeIdx), name: typeSegs[typeIdx], method: segs[segs.length - 1]};
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

	static function makeExprValue(ec:EvalContext, v:EvalValue):EvalValue {
		var ed = switch (v) {
			case VInt(i): mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CInt", [mkString(Std.string(i)), VNull])]);
			case VFloat(f): mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CFloat", [mkString(Std.string(f)), VNull])]);
			case VString(s): mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CString", [mkString(s.sstring), VNull])]);
			case VTrue: mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CIdent", [mkString("true")])]);
			case VFalse: mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CIdent", [mkString("false")])]);
			case VNull: mkEnumValue(ec, "ExprDef", "EConst", [mkEnumValue(ec, "Constant", "CIdent", [mkString("null")])]);
			case _: throw new TypingError("Context.makeExpr: unsupported value", curPos);
		};
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("expr"), ed);
		fields.set(EvalHash.hash("pos"), VNull);
		return VObject(new VObject([], ODictionary(fields)));
	}

	public static function isMacroField(cf:TClassField):Bool {
		return switch (cf.kind) { case Method(MethMacro): true; case _: false; };
	}

	static function getContext(com:Context):EvalContext {
		// A macro running mid-build (installAndForce types bodies that may contain macro calls) must
		// not trigger another rebuild -- that recurses without bound. While building, reuse what we have.
		if (!building && (macroCtx == null || lastModuleCount != com.modules.length)) {
			building = true;
			try {
				hxc.typing.TypeFields.installAndForce(com);
				var ec = EvalMain.create(true);
				registerContext(ec, com);
				EvalMain.addModules(ec, com.modules);
				macroCtx = ec;
				lastModuleCount = com.modules.length;
			} catch (e:Dynamic) { building = false; throw e; }
			building = false;
		}
		EvalContext.setCtx(macroCtx);
		return macroCtx;
	}

	static var macroCom:Context = null;

	// Re-parse a macro's class under the macro defines (so its #if macro members exist) and install that
	// copy into the macro context. The host parses every module without macro, which drops the #if macro
	// members a macro function's body relies on. reference:
	static function loadMacroClass(host:Context, path:hxc.core.Globals.Path):Void {
		if (macroCom == null) {
			macroCom = host.cloneForMacro();
			hxc.context.ModuleLoader.attach(macroCom);
			hxc.context.ModuleLoader.initBasicTypes(macroCom);
		}
		try {
			hxc.context.ModuleLoader.loadModule(macroCom, path, Position.nullPos);
			hxc.typing.TypeFields.typeAllModules(macroCom);
		} catch (_:Dynamic) {}
		if (macroCtx != null) EvalMain.addModules(macroCtx, macroCom.modules);
	}

	public static function run(tctx:TyperContext, fa:FieldAccess, el:Array<Expr>, withType:WithType, p:Position):TExpr {
		curPos = p;
		var path = switch (fa.host) {
			case FHStatic(c): c.path;
			case _: throw new TypingError("Only static macro functions are supported", p);
		};
		var ec = getContext(tctx.com);
		var proto = ec.staticPrototypes.get(EvalHash.pathHash(path));
		var idx = proto == null ? null : proto.pnames.get(EvalHash.hash(fa.field.name));
		if (proto == null || idx == null) {
			// The macro field is absent because the host parsed the class without macro defined; load
			// the class from the macro world so its #if macro members are present.
			loadMacroClass(tctx.com, path);
			proto = ec.staticPrototypes.get(EvalHash.pathHash(path));
			idx = proto == null ? null : proto.pnames.get(EvalHash.hash(fa.field.name));
		}
		if (proto == null) throw new TypingError("Macro type not loaded: " + path.name, p);
		if (idx == null) throw new TypingError("Macro not found: " + fa.field.name, p);
		var fn = switch (proto.pfields[idx]) {
			case VFunction(f, _): f;
			case _: throw new TypingError("Not a macro function: " + fa.field.name, p);
		};
		var sigArgs = switch (TypeFunctions.follow(fa.field.type)) { case TFun(s): s.args; case _: null; };
		var args = [for (i in 0...el.length) macroArg(ec, el[i], (sigArgs != null && i < sigArgs.length) ? sigArgs[i].t : null)];
		curTctx = tctx;
		var result = fn(args);
		var astExpr = decodeExpr(ec, result, p);
		return Typer.typeExpr(tctx, astExpr, withType);
	}

	// An Expr (or ExprOf) macro parameter receives the reified expression; any other parameter type
	// receives the argument's constant value. Non-constant value arguments fall back to the reified
	// expression.
	static function macroArg(ec:EvalContext, e:Expr, pt:Null<T>):EvalValue {
		if (pt != null && !isExprParam(pt)) switch (e.expr) {
			case EConst(CString(s, _)): return VString(new VString(s, s.length));
			case EConst(CInt(s, _)): var n = Std.parseInt(s); return VInt(n == null ? 0 : n);
			case EConst(CFloat(s, _)): return VFloat(Std.parseFloat(s));
			case EConst(CIdent("true")): return VTrue;
			case EConst(CIdent("false")): return VFalse;
			case EConst(CIdent("null")): return VNull;
			case _:
		}
		return encodeExpr(ec, e);
	}

	static function isExprParam(t:T):Bool {
		return switch (t) {
			case TType(d, _): d.path.name == "Expr" || d.path.name == "ExprOf";
			case TInst(c, _): c.path.name == "Expr";
			case TAbstract(a, _): a.path.name == "Expr";
			case TLazy(f): isExprParam(TypeFunctions.lazyType(f));
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

	static function strOpt(v:EvalValue):Null<String> {
		return switch (v) { case VNull: null; case _: strOf(v); };
	}

	static function boolOf(v:EvalValue):Bool {
		return switch (v) { case VTrue: true; case _: false; };
	}

	static function arrOf(v:EvalValue):Array<EvalValue> {
		return switch (v) { case VArray(a): a.avalues.slice(0, a.alength); case VNull: []; case _: throw "macro decode: expected array"; };
	}

	static function decodeExpr(ec:EvalContext, v:EvalValue, dp:Position):Expr {
		if (v == VNull) return new Expr(EConst(CIdent("null")), dp);
		var ed = decodeExprDef(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp);
		return new Expr(ed, dp);
	}

	static function decodeExprOpt(ec:EvalContext, v:EvalValue, dp:Position):Null<Expr> {
		return v == VNull ? null : decodeExpr(ec, v, dp);
	}

	static function decodeExprDef(ec:EvalContext, v:EvalValue, dp:Position):ExprDef {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "EConst": EConst(decodeConstant(ec, a[0]));
			case "EArray": EArray(decodeExpr(ec, a[0], dp), decodeExpr(ec, a[1], dp));
			case "EBinop": EBinop(decodeBinop(ec, a[0]), decodeExpr(ec, a[1], dp), decodeExpr(ec, a[2], dp));
			case "EField": EField(decodeExpr(ec, a[0], dp), strOf(a[1]), EFNormal);
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
			case "EMeta": decodeExpr(ec, a[1], dp).expr;
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
		return {name: strOf(EvalField.field(ec, v, EvalHash.hash("field"))), pos: dp, quotes: NoQuotes, expr: decodeExpr(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp)};
	}

	static function decodeVar(ec:EvalContext, v:EvalValue, dp:Position):EVar {
		return {
			evName: {name: strOf(EvalField.field(ec, v, EvalHash.hash("name"))), pos: dp},
			evFinal: boolOf(EvalField.field(ec, v, EvalHash.hash("isFinal"))),
			evStatic: false,
			evType: null,
			evExpr: decodeExprOpt(ec, EvalField.field(ec, v, EvalHash.hash("expr")), dp),
			evMeta: []
		};
	}

	static function decodeField(ec:EvalContext, v:EvalValue, dp:Position):ClassField {
		var name = strOf(EvalField.field(ec, v, EvalHash.hash("name")));
		var access = [for (av in arrOf(EvalField.field(ec, v, EvalHash.hash("access")))) ({access: decodeAccess(ec, av), pos: dp} : PlacedAccess)];
		var kind = decodeFieldKind(ec, EvalField.field(ec, v, EvalHash.hash("kind")), dp);
		return new ClassField({name: name, pos: dp}, null, dp, [], access, kind);
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
			case "FVar": FVar(null, decodeExprOpt(ec, a.length > 1 ? a[1] : VNull, dp));
			case "FFun": FFun(decodeFunc(ec, a[0], dp));
			case "FProp": FProp({name: strOf(a[0]), pos: dp}, {name: strOf(a[1]), pos: dp}, null, decodeExprOpt(ec, a.length > 3 ? a[3] : VNull, dp));
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
			meta: [],
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

	static function decodeClassFlags(ec:EvalContext, kind:EvalValue, dp:Position):Array<ClassFlag> {
		var flags:Array<ClassFlag> = [];
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

	static function decodeTypeDefinition(ec:EvalContext, v:EvalValue, dp:Position):TypeDecl {
		var name = strOf(EvalField.field(ec, v, EvalHash.hash("name")));
		var fields = [for (fv in arrOf(EvalField.field(ec, v, EvalHash.hash("fields")))) decodeField(ec, fv, dp)];
		var flags = decodeClassFlags(ec, EvalField.field(ec, v, EvalHash.hash("kind")), dp);
		var def:Definition<ClassFlag, Array<ClassField>> = {dName: {name: name, pos: dp}, dDoc: null, dParams: [], dMeta: [], dFlags: flags, dData: fields};
		return {decl: EClass(def), pos: dp};
	}

	static function decodeConstant(ec:EvalContext, v:EvalValue):Constant {
		var a = eargs(v);
		return switch (ctorName(ec, v)) {
			case "CInt": CInt(strOf(a[0]), a.length > 1 ? strOpt(a[1]) : null);
			case "CFloat": CFloat(strOf(a[0]), a.length > 1 ? strOpt(a[1]) : null);
			case "CString": CString(strOf(a[0]), SDoubleQuotes);
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
			case "OpAssignOp": OpAssignOp(decodeBinop(ec, eargs(v)[0]));
			case other: throw "macro decode: unhandled Binop " + other;
		};
	}

	static function decodeUnop(ec:EvalContext, v:EvalValue):Unop {
		return switch (ctorName(ec, v)) {
			case "OpIncrement": Increment; case "OpDecrement": Decrement;
			case "OpNot": Not; case "OpNeg": Neg; case "OpNegBits": NegBits;
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
		return s == null ? VNull : VString(new VString(s, s.length));
	}

	static function encodeExpr(ec:EvalContext, e:Expr):EvalValue {
		var ed = encodeExprDef(ec, e.expr);
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("expr"), ed);
		fields.set(EvalHash.hash("pos"), VNull);
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeExprDef(ec:EvalContext, ed:ExprDef):EvalValue {
		return switch (ed) {
			case EConst(c): mkEnumValue(ec, "ExprDef", "EConst", [encodeConstant(ec, c)]);
			case EArray(e1, e2): mkEnumValue(ec, "ExprDef", "EArray", [encodeExpr(ec, e1), encodeExpr(ec, e2)]);
			case EBinop(op, e1, e2): mkEnumValue(ec, "ExprDef", "EBinop", [encodeBinop(ec, op), encodeExpr(ec, e1), encodeExpr(ec, e2)]);
			case EField(e1, f, _): mkEnumValue(ec, "ExprDef", "EField", [encodeExpr(ec, e1), mkString(f)]);
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
		fields.set(EvalHash.hash("expr"), ev.evExpr == null ? VNull : encodeExpr(ec, ev.evExpr));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeField(ec:EvalContext, f:ClassField):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(f.cffName.name));
		fields.set(EvalHash.hash("doc"), VNull);
		fields.set(EvalHash.hash("access"), encodeArray([for (pa in f.cffAccess) encodeAccess(ec, pa.access)]));
		fields.set(EvalHash.hash("kind"), encodeFieldKind(ec, f.cffKind));
		fields.set(EvalHash.hash("pos"), VNull);
		fields.set(EvalHash.hash("meta"), encodeArray([]));
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
			case FVar(_, e): mkEnumValue(ec, "FieldType", "FVar", [VNull, e == null ? VNull : encodeExpr(ec, e)]);
			case FFun(fn): mkEnumValue(ec, "FieldType", "FFun", [encodeFunc(ec, fn)]);
			case FProp(get, set, _, e): mkEnumValue(ec, "FieldType", "FProp", [mkString(get.name), mkString(set.name), VNull, e == null ? VNull : encodeExpr(ec, e)]);
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
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeArray(items:Array<EvalValue>):EvalValue {
		return VArray(new VArray(items, items.length));
	}

	static function encodeConstant(ec:EvalContext, c:Constant):EvalValue {
		return switch (c) {
			case CInt(s, suf): mkEnumValue(ec, "Constant", "CInt", [mkString(s), mkString(suf)]);
			case CFloat(s, suf): mkEnumValue(ec, "Constant", "CFloat", [mkString(s), mkString(suf)]);
			case CString(s, _): mkEnumValue(ec, "Constant", "CString", [mkString(s), VNull]);
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
		fields.set(EvalHash.hash("type"), VNull);
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
			case TMono(m): m.type != null ? encodeType(ec, m.type) : mkEnumValue(ec, "Type", "TMono", [encodeRef(ec, VNull)]);
			case TEnum(e, params): mkEnumValue(ec, "Type", "TEnum", [encodeRef(ec, encodeBaseType(ec, e.path)), encodeArray([for (p in params) encodeType(ec, p)])]);
			case TInst(c, params): mkEnumValue(ec, "Type", "TInst", [encodeRef(ec, encodeBaseType(ec, c.path)), encodeArray([for (p in params) encodeType(ec, p)])]);
			case TType(d, params): mkEnumValue(ec, "Type", "TType", [encodeRef(ec, encodeBaseType(ec, d.path)), encodeArray([for (p in params) encodeType(ec, p)])]);
			case TFun(sig): mkEnumValue(ec, "Type", "TFun", [encodeArray([for (a in sig.args) encodeTypeFunArg(ec, a)]), encodeType(ec, sig.ret)]);
			case TAnon(_): mkEnumValue(ec, "Type", "TAnonymous", [encodeRef(ec, VNull)]);
			case TDynamic(t2): mkEnumValue(ec, "Type", "TDynamic", [t2 == null ? VNull : encodeType(ec, t2)]);
			case TLazy(f): encodeType(ec, TypeFunctions.lazyType(f));
			case TAbstract(a, params): mkEnumValue(ec, "Type", "TAbstract", [encodeRef(ec, encodeBaseType(ec, a.path)), encodeArray([for (p in params) encodeType(ec, p)])]);
		};
	}

	static function encodeBaseType(ec:EvalContext, path:hxc.core.Globals.Path):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(path.name));
		fields.set(EvalHash.hash("pack"), encodeArray([for (s in path.pack) mkString(s)]));
		fields.set(EvalHash.hash("module"), mkString(path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeRef(ec:EvalContext, payload:EvalValue):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("get"), VFunction(function(_) return payload, true));
		return VObject(new VObject([], ODictionary(fields)));
	}

	static function encodeTypeFunArg(ec:EvalContext, a:TSignatureArg):EvalValue {
		var fields:Map<Int, EvalValue> = new Map();
		fields.set(EvalHash.hash("name"), mkString(a.name));
		fields.set(EvalHash.hash("opt"), a.opt ? VTrue : VFalse);
		fields.set(EvalHash.hash("t"), encodeType(ec, a.t));
		return VObject(new VObject([], ODictionary(fields)));
	}
}
