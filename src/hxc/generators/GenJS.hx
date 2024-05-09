package hxc.generators;

// This file starts with the output context and emit primitives; the expression and declaration emitters
// build on top.

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.Globals.Path;
import hxc.context.Context;
import haxe.ds.StringMap;

// Source map; positions encoded as base64 VLQ deltas
private class JsSourceMap {
	public var sources:Array<String> = [];
	public var sourcesHash:StringMap<Int> = new StringMap();
	public var mappings:StringBuf = new StringBuf();
	public var sourceLastFile = 0;
	public var sourceLastLine = 0;
	public var sourceLastCol = 0;
	public var printComma = false;
	public var outputLastCol = 0;
	public var outputCurrentCol = 0;
	public var currentExpr:Null<{file:Int, line:Int, col:Int}> = null;

	public function new() {}

	static var base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	public function encodeMapping(pos:{file:Int, line:Int, col:Int}):Void {
		if (printComma)
			mappings.add(",");
		else
			printComma = true;
		function base64Vlq(number:Int):Void {
			var vlq = number < 0 ? ((-number) << 1) + 1 : number << 1;
			while (true) {
				var digit = vlq & 31;
				vlq >>= 5;
				mappings.add(base64Chars.charAt(vlq > 0 ? digit | 32 : digit));
				if (vlq <= 0) break;
			}
		}
		base64Vlq(outputCurrentCol - outputLastCol);
		base64Vlq(pos.file - sourceLastFile);
		base64Vlq(pos.line - sourceLastLine);
		base64Vlq(pos.col - sourceLastCol);
		sourceLastFile = pos.file;
		sourceLastLine = pos.line;
		sourceLastCol = pos.col;
		outputLastCol = outputCurrentCol;
	}

	// Returns the restore closure
	public function addMapping(p:Position):Void->Void {
		if (p.min < 0) return function() {};
		var file = sourcesHash.get(p.file);
		if (file == null) {
			file = sources.length;
			sourcesHash.set(p.file, file);
			sources.push(p.file);
		}
		var infos = Position.getInfos(p);
		var pos = {file: file, line: infos.line - 1, col: infos.column};
		if (sourceLastFile != pos.file || sourceLastLine != pos.line || sourceLastCol != pos.col) {
			var old = currentExpr;
			currentExpr = pos;
			encodeMapping(pos);
			return function() currentExpr = old;
		}
		return function() {};
	}

	public function handleNewlines(str:String):Void {
		var from = 0;
		while (true) {
			var next = str.indexOf("\n", from);
			if (next < 0) {
				outputCurrentCol += str.length - from;
				break;
			}
			next += 1;
			mappings.add(";");
			outputLastCol = 0;
			outputCurrentCol = 0;
			printComma = false;
			if (currentExpr != null) encodeMapping(currentExpr);
			from = next;
		}
	}
}

class GenJS {
	public var com:Context;
	public var buf:StringBuf;
	public var smap:Null<JsSourceMap>;
	public var packages:StringMap<Bool>;
	public var jsModern:Bool;
	public var jsFlatten:Bool;
	public var hasResolveClass:Bool;
	public var hasInterfaceCheck:Bool;
	public var esVersion:Int;
	public var current:TClass;
	public var statics:Array<{c:TClass, f:TClassField, e:TExpr}>;
	public var inits:Array<TExpr>;
	public var tabs:String;
	// Named valueVar, not inValue: an inValue field collides with the inValue parameter of hxcpp's
	// generated __SetField reflection helper
	public var valueVar:Null<TVar>;
	public var inLoop:Bool;
	public var idCounter:Int;
	public var separator:Bool;
	public var foundExpose:Bool;
	public var catchVars:Array<TExpr>;
	// Filled by allocCtx
	public var typeAccessor:ModuleType->String;

	static var kwds:StringMap<Bool> = new StringMap();

	static var es3kwds = [
		"abstract", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
		"debugger", "default", "delete", "do", "double", "else", "enum", "export", "extends", "false", "final",
		"finally", "float", "for", "function", "goto", "if", "implements", "import", "in", "instanceof", "int",
		"interface", "long", "native", "null", "package", "private", "protected",
		"public", "return", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws",
		"transient", "true", "try", "typeof", "var", "void", "volatile", "while", "with"
	];

	static var es5kwds = [
		"arguments", "break", "case", "catch", "class", "const", "continue",
		"debugger", "default", "delete", "do", "else", "enum", "eval", "export", "extends", "false",
		"finally", "for", "function", "if", "implements", "import", "in", "instanceof",
		"interface", "let", "new", "null", "package", "private", "protected",
		"public", "return", "static", "super", "switch", "this", "throw",
		"true", "try", "typeof", "var", "void", "while", "with", "yield"
	];

	// Identifiers reserved to keep the output clean; escaped on declaration
	static var kwds2:StringMap<Bool> = {
		var h = new StringMap();
		for (s in [
			"Infinity", "NaN", "decodeURI", "decodeURIComponent", "encodeURI", "encodeURIComponent",
			"escape", "eval", "isFinite", "isNaN", "parseFloat", "parseInt", "undefined", "unescape",
			"JSON", "Number", "Object", "console", "window", "require"
		]) h.set(s, true);
		h;
	};

	public static function setupKwds(com:Context):Void {
		kwds = new StringMap();
		var lst = com.getEsVersion() >= 5 ? es5kwds : es3kwds;
		for (s in lst) kwds.set(s, true);
	}

	public static function validJsIdent(s:String):Bool {
		if (s.length == 0) return false;
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			var ok = (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code)
				|| c == "$".code || c == "_".code
				|| (i > 0 && c >= "0".code && c <= "9".code);
			if (!ok) return false;
		}
		return true;
	}

	public static function field(s:String):String {
		return !validJsIdent(s) ? "[\"" + s + "\"]" : "." + s;
	}

	public static function ident(s:String):String {
		return kwds.exists(s) ? "$" + s : s;
	}

	public static function isKeyword(s:String):Bool {
		return kwds.exists(s);
	}

	// One expression printed to a string: value or statement form, then the buffer and id counter reset for
	// the next call.
	public static function genSingleExpr(ctx:GenJS, e:TExpr, expr:Bool):String {
		if (expr) ctx.genExpr(e) else ctx.genValue(e);
		var str = ctx.buf.toString();
		ctx.buf = new StringBuf();
		ctx.idCounter = 0;
		return str;
	}

	public static function checkVarDeclaration(v:TVar):Void {
		if (kwds2.exists(v.name)) v.name = "$" + v.name;
		// Internal generated locals (notably the anonymous-function receiver) may use a backtick
		// placeholder; the variable-renaming pass normally gives them a legal name. Keep the emitter valid
		// if that rename has not happened yet.
		if (!validJsIdent(v.name)) v.name = "$" + Std.string(v.id);
	}

	public static function anonField(s:String):String {
		return (kwds.exists(s) || !validJsIdent(s)) ? "'" + s + "'" : s;
	}

	public function staticField(c:TClass, f:TClassField):String {
		return switch (f.name) {
			case s = ("length" | "name") if (!TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasMeta(":hxGen", c.meta)):
				switch (f.kind) {
					case Method(_) if (esVersion >= 6): "." + s;
					case _: ".$" + s;
				}
			case s:
				field(s);
		};
	}

	public static function moduleField(com:Context, m:ModuleDef, f:TClassField):String {
		return try {
			hxc.codegen.Codegen.getNativeName(com, f.meta).name;
		} catch (_:hxc.core.NotFound) {
			flatPath(m.path) + "_" + f.name;
		}
	}

	public static function moduleFieldExposePath(com:Context, mpath:Path, f:TClassField):String {
		return try {
			hxc.codegen.Codegen.getNativeName(com, f.meta).name;
		} catch (_:hxc.core.NotFound) {
			dotPath(mpath) + "." + f.name;
		}
	}

	public static function dotPath(p:Path):String {
		return p.pack.length == 0 ? p.name : p.pack.join(".") + "." + p.name;
	}

	public static function flatPath(p:Path):String {
		// Flat path: every segment escapes '_' to '_$' to prevent name collisions, then package parts and
		// the name join with '_'. So a private module part `_Foo` becomes `_$Foo`.
		inline function escape(str:String):String return str.split("_").join("_$");
		return p.pack.length == 0 ? escape(p.name)
			: [for (seg in p.pack) escape(seg)].join("_") + "_" + escape(p.name);
	}

	public function sPath(p:Path):String {
		return jsFlatten ? flatPath(p) : dotPath(p);
	}

	public static function processExpose(com:Context, meta:Metadata, fDefault:Void->String, f:String->Void):Void {
		for (m in meta) {
			if (m.name != ":expose") continue;
			switch (m.params) {
				case [{expr: EConst(CString(s, _))}]: f(s);
				case []: f(fDefault());
				case _: throw new TypingError("Invalid @:expose parameters", m.pos);
			}
			return;
		}
	}

	public inline function hasFeature(f:String):Bool return com.hasFeature(f);
	public inline function addFeature(f:String):Void com.addFeature(f);

	public static function unsupported(p:Position):Dynamic {
		throw new TypingError("This expression cannot be compiled to Javascript", p);
	}

	// Spr / print. StringBuf has no random access, so the buffer's last character is tracked here
	// rather than paying a full buf.toString() copy per newline/newprop/semicolon (quadratic on the
	// whole output).
	var lastChar:String = "";
	public function spr(s:String):Void {
		separator = false;
		if (smap != null) smap.handleNewlines(s);
		if (s.length > 0) lastChar = s.charAt(s.length - 1);
		buf.add(s);
	}

	public function print(s:String):Void {
		separator = false;
		if (smap != null) smap.handleNewlines(s);
		if (s.length > 0) lastChar = s.charAt(s.length - 1);
		buf.add(s);
	}

	// Source mapping over an expression position
	public inline function addMapping(e:TExpr):Void->Void {
		return smap != null ? smap.addMapping(e.pos) : function() {};
	}

	// The .js.map JSON plus the sourceMappingURL trailer
	public function writeMappings():Void {
		var basefile = haxe.io.Path.withoutDirectory(com.file);
		print("\n//# sourceMappingURL=" + StringTools.urlEncode(basefile) + ".map");
		var b = new StringBuf();
		function toUrl(file:String):String {
			return StringTools.replace(StringTools.replace(sys.FileSystem.absolutePath(file), "\\", "/"), "\\", "/");
		}
		b.add("{\n");
		b.add("\"version\":3,\n");
		b.add("\"file\":\"" + StringTools.replace(basefile, "\\", "\\\\") + "\",\n");
		b.add("\"sourceRoot\":\"\",\n");
		b.add("\"sources\":[" + [for (s in smap.sources) "\"file:///" + toUrl(s) + "\""].join(",") + "],\n");
		if (com.defines.rawDefined("source_map_content")) {
			b.add("\"sourcesContent\":[" + [for (s in smap.sources) {
				try "\"" + sEscape(sys.io.File.getContent(s)) + "\"" catch (_:Dynamic) "null";
			}].join(",") + "],\n");
		}
		b.add("\"names\":[],\n");
		b.add("\"mappings\":\"");
		b.add(smap.mappings.toString());
		b.add("\"\n");
		b.add("}");
		sys.io.File.saveContent(com.file + ".map", b.toString());
	}

	static function sEscape(s:String):String {
		var b = new StringBuf();
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i);
			switch (c) {
				case "\n".code: b.add("\\n");
				case "\t".code: b.add("\\t");
				case "\r".code: b.add("\\r");
				case "\"".code: b.add("\\\"");
				case "\\".code: b.add("\\\\");
				case _:
					// A surrogate pair joins into one code point: addChar on a lone half
					// yields U+FFFD on this host runtime (same handling as the lexer).
					if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
						var lo = s.charCodeAt(i + 1);
						if (lo >= 0xDC00 && lo <= 0xDFFF) {
							b.addChar(0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00));
							i += 2;
							continue;
						}
					}
					b.addChar(c);
			}
			i++;
		}
		return b.toString();
	}

	// A separator-aware statement break
	public function newline():Void {
		switch (lastChar) {
			case "}" | "{" | ":" | ";" if (!separator):
				print("\n" + tabs);
			case _:
				print(";\n" + tabs);
		}
	}

	public function newprop():Void {
		switch (lastChar) {
			case "{": print("\n" + tabs);
			case _: print("\n" + tabs + ",");
		}
	}

	public function semicolon():Void {
		switch (lastChar) {
			case "}" if (!separator):
			case _: spr(";");
		}
	}

	public function concatWith<A>(sep:String, f:A->Void, l:Array<A>):Void {
		for (i in 0...l.length) {
			if (i > 0) spr(sep);
			f(l[i]);
		}
	}

	public function openBlock():Void->Void {
		var oldt = tabs;
		tabs = "\t" + tabs;
		return function() tabs = oldt;
	}

	public function thisStr():String {
		return valueVar == null ? "this" : "$this";
	}

	public function varKeyword():String {
		return esVersion >= 6 ? "let" : "var";
	}

	public function new() {}

	public static function allocCtx(com:Context, esVersion:Int):GenJS {
		var ctx = new GenJS();
		ctx.com = com;
		ctx.buf = new StringBuf();
		// Source maps under --debug or the js-source-map/source-map defines
		ctx.smap = (com.debug || com.defines.rawDefined("js_source_map") || com.defines.rawDefined("source_map"))
			? new JsSourceMap() : null;
		ctx.packages = new StringMap();
		ctx.jsModern = !com.defines.rawDefined("js_classic");
		ctx.jsFlatten = !com.defines.rawDefined("js_unflatten");
		ctx.hasResolveClass = com.hasFeature("Type.resolveClass");
		ctx.hasInterfaceCheck = com.hasFeature("js.Boot.__interfLoop");
		ctx.esVersion = esVersion;
		ctx.statics = [];
		ctx.inits = [];
		ctx.current = TypeFunctions.nullClass;
		ctx.tabs = "";
		ctx.valueVar = null;
		ctx.inLoop = false;
		ctx.idCounter = 0;
		ctx.separator = false;
		ctx.foundExpose = false;
		ctx.catchVars = [];
		ctx.typeAccessor = function(t:ModuleType):String {
			return switch (t) {
				case TEnumDecl(e) if (e.isExtern && !TypeFunctions.hasMeta(":jsRequire", e.meta)):
					dotPath(e.path);
				case TClassDecl(c):
					var p = getGeneratedClassPath(c);
					if (TypeFunctions.hasClassFlag(c, CExtern) && !TypeFunctions.hasMeta(":jsRequire", c.meta))
						dotPath(p);
					else
						ctx.sPath(p);
				case _:
					ctx.sPath(TypeFunctions.tPath(t));
			};
		};
		return ctx;
	}

	// Abstract impls use the abstract's own path unless @:native renamed them
	public static function getGeneratedClassPath(c:TClass):Path {
		return switch (c.kind) {
			case KAbstractImpl(a) if (!TypeFunctions.hasMeta(":native", c.meta)): a.path;
			case _: c.path;
		};
	}

	public static function isAbstractImpl(c:TClass):Bool {
		return c.kind.match(KAbstractImpl(_));
	}

	static function needsSwitchBreak(e:TExpr):Bool {
		return switch (e.expr) {
			case TBlock([]): true;
			case TBlock(el): needsSwitchBreak(el[el.length - 1]);
			case TMeta(m, {expr: TBreak}) if (m.name == ":loopLabel"): false;
			case TContinue | TReturn(_) | TThrow(_): false;
			case _: true;
		};
	}

	static function isIteratorFieldAccess(fa:TFieldAccess):Bool {
		return switch (TypeFunctions.fieldName(fa)) {
			case "iterator" | "keyValueIterator": true;
			case _: false;
		};
	}

	function isDynamicIterator(e:TExpr):Bool {
		function check(x:TExpr):Bool {
			function loop(t:T):Bool {
				return switch (TypeFunctions.follow(t)) {
					case TInst({path: {pack: [], name: "Array"}}, _): true;
					case TInst(c, _) if (c.kind.match(KTypeParameter(_))): true;
					case TAnon(_) | TDynamic(_) | TMono(_): true;
					case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
						loop(TypeFunctions.getUnderlyingType(a, tl));
					case _: false;
				};
			}
			return hasFeature("haxe.iterators.ArrayIterator.*") && loop(x.type);
		}
		return switch (e.expr) {
			case TField(x, f) if (isIteratorFieldAccess(f)): check(x);
			case _: false;
		};
	}

	function genConstant(p:Position, c:TConstant):Void {
		switch (c) {
			case TInt(i): print(Std.string(i));
			case TFloat(s): spr(s);
			case TString(s): print("\"" + hxc.core.StringHelper.sEscape(s) + "\"");
			case TBool(b): spr(b ? "true" : "false");
			case TNull: spr("null");
			case TThis: spr(thisStr());
			case TSuper:
				if (esVersion < 6) throw new TypingError("super is only supported on es6+", p);
				spr("super");
		}
	}

	static function isCodeInjectionFunction(e:TExpr):Bool {
		return switch (e.expr) {
			case TIdent("__js__"): true;
			case TField(_, FStatic({path: {pack: ["js"], name: "Syntax"}}, {name: "code" | "plainCode"})): true;
			case _: false;
		};
	}

	static function isRestT(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, _): a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Rest";
			case _: false;
		};
	}

	// On es<6 a trailing spread turns the call into fn.apply
	function applyArgs(el:Array<TExpr>, addNullContext:Bool = false):{apply:Bool, el:Array<TExpr>} {
		if (esVersion < 6 && el.length > 0) {
			switch (el[el.length - 1].expr) {
				case TUnop(Spread, Prefix, rest) if (el.length == 1 && !addNullContext):
					return {apply: true, el: [rest]};
				case TUnop(Spread, Prefix, rest):
					// [arg1, ..., argN].concat(rest)
					var args = el.slice(0, el.length - 1);
					if (addNullContext) args = [TypeFunctions.mk(TConst(TNull), TypeFunctions.tDynamic, Position.nullPos)].concat(args);
					var arr = TypeFunctions.mk(TArrayDecl(args), TypeFunctions.tDynamic, Position.nullPos);
					var concat = TypeFunctions.mk(TField(arr, FDynamic("concat")), TypeFunctions.tDynamic, Position.nullPos);
					return {apply: true, el: [TypeFunctions.mk(TCall(concat, [rest]), TypeFunctions.tDynamic, Position.nullPos)]};
				case _:
			}
		}
		return {apply: false, el: el};
	}

	function printDeprecation(msg:String, p:Position):Void {
		com.warning(WDeprecated, [], msg, p);
	}

	// The typer packs a trailing haxe.Rest<T> into its @:from Array cast (eval needs the value form); JS
	// keeps rest args flat, so the array literal is unpacked back into plain call args.
	// True when a function type's last parameter is a haxe.Rest<T>: only such a call flattens a packed rest
	// argument. A plain parameter that happens to receive a rest value (e.g. a RestIterator constructor
	// taking the rest as one value) keeps the argument intact.
	static function calleeLastParamIsRest(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig) if (sig.args.length > 0): isRestT(sig.args[sig.args.length - 1].t);
			case _: false;
		};
	}

	static function unwrapRestArgs(el:Array<TExpr>, calleeType:T):Array<TExpr> {
		if (el.length == 0) return el;
		if (!calleeLastParamIsRest(calleeType)) return el;
		var last = el[el.length - 1];
		if (!isRestT(last.type)) return el;
		function arrayItems(x:TExpr):Null<Array<TExpr>> {
			return switch (x.expr) {
				case TArrayDecl(items): items;
				case TCall(_, [inner]): arrayItems(TexprTools.skip(inner));
				case TCast(inner, _) | TMeta(_, inner) | TParenthesis(inner): arrayItems(inner);
				case _: null;
			};
		}
		var items = arrayItems(TexprTools.skip(last));
		if (items == null) return el;
		return el.slice(0, el.length - 1).concat(items);
	}

	function genCall(e:TExpr, el:Array<TExpr>, inValueCtx:Bool):Void {
		var el = unwrapRestArgs(el, e.type);
		var r = applyArgs(el);
		var apply = r.apply;
		var el = r.el;
		switch (e.expr) {
			case TConst(TSuper) if (esVersion < 6):
				switch (current.superClass) {
					case null: throw new TypingError("Missing api.setCurrentClass", e.pos);
					case sup:
						var call = apply ? "apply" : "call";
						print(typeAccessor(TClassDecl(sup.c)) + "." + call + "(" + thisStr());
						for (p in el) {
							print(",");
							genValue(p);
						}
						spr(")");
				}
			case TField({expr: TConst(TSuper)}, f) if (esVersion < 6):
				switch (current.superClass) {
					case null: throw new TypingError("Missing api.setCurrentClass", e.pos);
					case sup:
						var name = TypeFunctions.fieldName(f);
						var call = apply ? "apply" : "call";
						print(typeAccessor(TClassDecl(sup.c)) + ".prototype" + field(name) + "." + call + "(" + thisStr());
						for (p in el) {
							print(",");
							genValue(p);
						}
						spr(")");
				}
			case TCall(x, _) if (!isCodeInjectionFunction(x)):
				if (apply) genCallWithApply(e, el)
				else {
					spr("(");
					genValue(e);
					spr(")");
					spr("(");
					concatWith(",", genValue, el);
					spr(")");
				}
			case TField(_, FStatic({path: {pack: ["js"], name: "Syntax"}}, {name: meth})):
				genSyntax(meth, el, e.pos);
			case TField(_, FStatic({path: {pack: ["js"], name: "Lib"}}, {name: "rethrow"})) if (el.length == 0):
				switch (catchVars) {
					case []: throw new TypingError("js.Lib.rethrow can only be called inside a catch block", e.pos);
					case _:
						spr("throw ");
						genValue(catchVars[0]);
				}
			case TField(_, FStatic({path: {pack: ["js"], name: "Lib"}}, {name: "getOriginalException"})) if (el.length == 0):
				switch (catchVars) {
					case []: throw new TypingError("js.Lib.getOriginalException can only be called inside a catch block", e.pos);
					case _: genValue(catchVars[0]);
				}
			case TIdent("__new__"):
				printDeprecation("__new__ is deprecated, use js.Syntax.construct instead", e.pos);
				genSyntax("construct", el, e.pos);
			case TIdent("__js__"):
				printDeprecation("__js__ is deprecated, use js.Syntax.code instead", e.pos);
				genSyntax("code", el, e.pos);
			case TIdent("__instanceof__"):
				printDeprecation("__instanceof__ is deprecated, use js.Syntax.instanceof instead", e.pos);
				genSyntax("instanceof", el, e.pos);
			case TIdent("__typeof__"):
				printDeprecation("__typeof__ is deprecated, use js.Syntax.typeof instead", e.pos);
				genSyntax("typeof", el, e.pos);
			case TIdent("__strict_eq__"):
				printDeprecation("__strict_eq__ is deprecated, use js.Syntax.strictEq instead", e.pos);
				genSyntax("strictEq", el, e.pos);
			case TIdent("__strict_neq__"):
				printDeprecation("__strict_neq__ is deprecated, use js.Syntax.strictNeq instead", e.pos);
				genSyntax("strictNeq", el, e.pos);
			case TIdent("__define_feature__") if (el.length == 2):
				genExpr(el[1]);
			case TIdent("__feature__") if (el.length >= 2):
				switch (el[0].expr) {
					case TConst(TString(f)):
						if (hasFeature(f)) genValue(el[1])
						else if (el.length > 2) genValue(el[2]);
					case _: unsupported(e.pos);
				}
			case TIdent("__resources__") if (el.length == 0):
				spr("[");
				// Resources are listed in the order of a 16-bucket hash table read by a prepending fold:
				// visit buckets 0..15 (no resize below 33 entries), each bucket newest-first, then the
				// prepend reverses the visit order. Bucket index = the name's string hash land 15.
				var cap = 16;
				var buckets:Array<Array<String>> = [for (_ in 0...cap) []];
				for (n in com.resourceOrder) buckets[hxc.eval.EvalStdLib.seededStringHash(n) & (cap - 1)].unshift(n);
				var names:Array<String> = [];
				for (b in buckets) for (n in b) names.push(n);
				names.reverse();
				concatWith(",", function(name:String) {
					spr("{ ");
					spr("name : ");
					genConstant(e.pos, TString(name));
					spr(", data : ");
					genConstant(e.pos, TString(hxc.codegen.Codegen.bytesSerialize(com.resources.get(name))));
					spr("}");
				}, names);
				spr("]");
			case TIdent("`trace") if (el.length == 2):
				var e2 = el[0];
				var infos = el[1];
				if (hasFeature("haxe.Log.trace")) {
					var t:Null<ModuleType> = null;
					for (mt in com.types) {
						var tp = TypeFunctions.tPath(mt);
						if (tp.name == "Log" && tp.pack.length == 1 && tp.pack[0] == "haxe") { t = mt; break; }
					}
					if (t == null) throw new TypingError("haxe.Log not loaded", e.pos);
					spr(typeAccessor(t));
					spr(".trace(");
					genValue(e2);
					spr(",");
					genValue(infos);
					spr(")");
				} else {
					spr("console.log(");
					switch (infos.expr) {
						case TObjectDecl(fl) if (fl.length >= 2 && fl[0].key.name == "fileName" && fl[1].key.name == "lineNumber"):
							switch [fl[0].expr.expr, fl[1].expr.expr] {
								case [TConst(TString(file)), TConst(TInt(line))]:
									print("\"" + file + ":" + line + ":\",");
								case _:
							}
						case _:
					}
					genValue(e2);
					spr(")");
				}
			case TField(x, f) if (el.length == 0 && TypeFunctions.fieldName(f) == "iterator" && isDynamicIterator(e)):
				addFeature("use.$getIterator");
				print("$getIterator(");
				genValue(x);
				print(")");
			case TField(x, f) if (el.length == 0 && TypeFunctions.fieldName(f) == "keyValueIterator" && isDynamicIterator(e)):
				addFeature("use.$getKeyValueIterator");
				print("$getKeyValueIterator(");
				genValue(x);
				print(")");
			case _:
				if (apply) genCallWithApply(e, el)
				else {
					genValue(e);
					spr("(");
					concatWith(",", genValue, el);
					spr(")");
				}
		}
	}

	function genCallWithApply(target:TExpr, args:Array<TExpr>):Void {
		if (args.length != 1) throw new TypingError("args for gen_call_with_apply must contain exactly one item", target.pos);
		switch (target.expr) {
			case TField(eThis, FInstance(_, _, {name: fname}) | FAnon({name: fname}) | FDynamic(fname) | FClosure(_, {name: fname})):
				addFeature("thisForCallWithRestArgs");
				spr("($_=");
				genValue(eThis);
				spr(",$_." + fname + ".apply($_,");
				concatWith(",", genValue, args);
				spr("))");
			case _:
				genValue(target);
				spr(".apply(null,");
				concatWith(",", genValue, args);
				spr(")");
		}
	}

	static function addObjectdeclParens(e:TExpr):TExpr {
		function loop(x:TExpr):TExpr {
			return switch (x.expr) {
				case TCast(e1, null) | TMeta(_, e1): loop(e1);
				case TObjectDecl(_): TypeFunctions.mk(TParenthesis(x), x.type, x.pos);
				case _: x;
			};
		}
		return loop(e);
	}

	// Each expression records a source mapping while generating
	static var genCount = 0;
	public function genExpr(e:TExpr):Void {
		var clearMapping = addMapping(e);
		genExprBody(e);
		clearMapping();
	}

	function genExprBody(e:TExpr):Void {
		switch (e.expr) {
			case TConst(c): genConstant(e.pos, c);
			case TLocal(v): spr(ident(v.name));
			case TArray(e1, e2):
				genValue(addObjectdeclParens(e1));
				spr("[");
				genValue(e2);
				spr("]");
			case TBinop(op, {expr: TField(x, f)}, e2) if (isIteratorFieldAccess(f)):
				genValue(x);
				spr(field(TypeFunctions.fieldName(f)));
				print(" " + Ast.sBinop(op) + " ");
				genValue(e2);
			case TBinop(op = OpEq | OpNotEq, {expr: TField(x, f = FClosure(_, _))}, {expr: TConst(TNull)}):
				genValue(x);
				spr(field(TypeFunctions.fieldName(f)));
				print(" " + Ast.sBinop(op) + " null");
			case TBinop(op = OpEq | OpNotEq, {expr: TConst(TNull)}, {expr: TField(x, f = FClosure(_, _))}):
				print("null " + Ast.sBinop(op) + " ");
				genValue(x);
				spr(field(TypeFunctions.fieldName(f)));
			case TBinop(op, e1, e2):
				genValue(e1);
				print(" " + Ast.sBinop(op) + " ");
				genValue(e2);
			case TField(x, f) if (TypeFunctions.fieldName(f) == "iterator" && isDynamicIterator(e)):
				addFeature("use.$iterator");
				print("$iterator(");
				genValue(x);
				print(")");
			case TField(x, f) if (TypeFunctions.fieldName(f) == "keyValueIterator" && isDynamicIterator(e)):
				addFeature("use.$keyValueIterator");
				print("$keyValueIterator(");
				genValue(x);
				print(")");
			case TUnop(op, flag, fe = {expr: TField(x, f)}) if (isIteratorFieldAccess(f) && isDynamicIterator(fe)):
				// Don't generate $iterator(value) for exprs like value.iterator--
				switch (flag) {
					case Prefix:
						spr(Ast.sUnop(op));
						genValue(x);
						print("." + TypeFunctions.fieldName(f));
					case Postfix:
						genValue(x);
						print("." + TypeFunctions.fieldName(f));
						spr(Ast.sUnop(op));
				}
			case TField(x, FClosure(w, {name: "push"})) if (w != null && w.c.path.pack.length == 0 && w.c.path.name == "Array"):
				// Issue #1997
				addFeature("use.$arrayPush");
				addFeature("use.$bind");
				print("$bind(");
				genValue(x);
				print(",$arrayPush)");
			case TField(x, FClosure(_, f)):
				addFeature("use.$bind");
				switch (x.expr) {
					case TConst(_) | TLocal(_):
						print("$bind(");
						genValue(x);
						print(",");
						genValue(x);
						print((TypeFunctions.hasMeta(":selfCall", f.meta) ? "" : field(f.name)) + ")");
					case _:
						print("($_=");
						genValue(x);
						print(",$bind($_,$_" + (TypeFunctions.hasMeta(":selfCall", f.meta) ? "" : field(f.name)) + "))");
				}
			case TEnumIndex(x):
				genValue(x);
				if (!com.defines.rawDefined("js_enums_as_arrays"))
					print("._hx_index")
				else
					print("[1]");
			case TEnumParameter(x, f, i):
				genValue(x);
				if (!com.defines.rawDefined("js_enums_as_arrays")) {
					var fname = switch (f.type) {
						case TFun(sig): sig.args[i].name;
						case _: throw new TypingError("Invalid enum parameter", e.pos);
					};
					print("." + ident(fname));
				} else
					print("[" + (i + 2) + "]");
			case TField(_, FStatic({path: {pack: [], name: ""}}, f)):
				spr(f.name);
			case TField(x, FInstance(_, _, f) | FStatic(_, f) | FAnon(f)) if (TypeFunctions.hasMeta(":selfCall", f.meta)):
				genValue(x);
			case TField(_, FStatic(c = {kind: KModuleFields(m)}, f)):
				spr(moduleField(com, m, f));
			case TField(x, f):
				function skip(x:TExpr):TExpr {
					return switch (x.expr) {
						case TCast(e1, null) | TMeta(_, e1): skip(e1);
						case TConst(TInt(_) | TFloat(_)) | TObjectDecl(_): TypeFunctions.mk(TParenthesis(x), x.type, x.pos);
						case _: x;
					};
				}
				genValue(skip(x));
				spr(switch (f) {
					case FStatic(c, cf): staticField(c, cf);
					case FEnum(_, _) | FInstance(_, _, _) | FAnon(_) | FDynamic(_) | FClosure(_, _): field(TypeFunctions.fieldName(f));
				});
			case TTypeExpr(t):
				spr(typeAccessor(t));
			case TParenthesis(e1):
				spr("(");
				genValue(e1);
				spr(")");
			case TMeta(m, e1) if (m.name == ":loopLabel"):
				switch (m.params) {
					case [{expr: EConst(CInt(n, _))}]:
						switch (e1.expr) {
							case TWhile(_, _, _) | TFor(_, _, _):
								print("_hx_loop" + n + ": ");
								genExpr(e1);
							case TBreak:
								print("break _hx_loop" + n);
							case _: throw new TypingError("Invalid loop label", e.pos);
						}
					case _: throw new TypingError("Invalid loop label", e.pos);
				}
			case TMeta(_, e1):
				genExpr(e1);
			case TReturn(eo):
				if (valueVar != null) unsupported(e.pos);
				if (eo == null) spr("return")
				else {
					spr("return ");
					genValue(eo);
				}
			case TBreak:
				if (!inLoop) unsupported(e.pos);
				spr("break");
			case TContinue:
				if (!inLoop) unsupported(e.pos);
				spr("continue");
			case TBlock(el):
				print("{");
				var bend = openBlock();
				for (x in el) genBlockElement(x);
				bend();
				newline();
				print("}");
			case TFunction(f):
				genFunction(f, e.pos);
			case TCall(callee, el):
				genCall(callee, el, false);
			case TArrayDecl(el):
				spr("[");
				concatWith(",", genValue, el);
				spr("]");
			case TThrow(e1):
				spr("throw ");
				genValue(e1);
			case TVarExpr(v, eo):
				spr(varKeyword() + " ");
				checkVarDeclaration(v);
				spr(ident(v.name));
				if (eo != null) {
					spr(" = ");
					genValue(eo);
				}
			case TNew({path: {pack: [], name: "Array"}}, _, []):
				print("[]");
			case TNew(c, _, el):
				var r = applyArgs(unwrapRestArgs(el, c.constructor == null ? TypeFunctions.tDynamic : c.constructor.type), true);
				var isSelfCall = c.constructor != null && TypeFunctions.hasMeta(":selfCall", c.constructor.meta);
				if (!isSelfCall) print(r.apply ? "(new" : "new ");
				var cls = typeAccessor(TClassDecl(c));
				if (r.apply) {
					print("(Function.prototype.bind.apply(" + cls + ",");
					concatWith(",", genValue, r.el);
					print(")))");
				} else {
					print(cls + "(");
					concatWith(",", genValue, r.el);
					spr(")");
				}
			case TIf(cond, eif, eelse):
				spr("if");
				genCondition(cond);
				spr(" ");
				genExpr(TypeFunctions.mkBlock(eif));
				if (eelse != null) {
					switch (eif.expr) {
						case TObjectDecl(_): separator = false;
						case _:
					}
					semicolon();
					spr(" else ");
					genExpr(eelse.expr.match(TIf(_, _, _)) ? eelse : TypeFunctions.mkBlock(eelse));
				}
			case TUnop(op, Prefix, e1):
				spr(Ast.sUnop(op));
				genValue(e1);
			case TUnop(op, Postfix, e1):
				genValue(e1);
				spr(Ast.sUnop(op));
			case TWhile(cond, body, NormalWhile):
				var oldInLoop = inLoop;
				inLoop = true;
				spr("while");
				genCondition(cond);
				spr(" ");
				genExpr(body);
				inLoop = oldInLoop;
			case TWhile(cond, body, DoWhile):
				var oldInLoop = inLoop;
				inLoop = true;
				spr("do ");
				genExpr(body);
				semicolon();
				spr(" while");
				genCondition(cond);
				inLoop = oldInLoop;
			case TObjectDecl(fields):
				spr("{ ");
				concatWith(", ", function(fl:TObjectField) {
					switch (fl.key.quotes) {
						case DoubleQuotes: print("\"" + hxc.core.StringHelper.sEscape(fl.key.name) + "\" : ");
						case NoQuotes: print(anonField(fl.key.name) + " : ");
					}
					genValue(fl.expr);
				}, fields);
				spr("}");
				separator = true;
			case TFor(v, it, body):
				checkVarDeclaration(v);
				var oldInLoop = inLoop;
				inLoop = true;
				var itName = switch (it.expr) {
					case TLocal(v2): ident(v2.name);
					case _:
						var id = idCounter;
						idCounter++;
						var name = "$it" + id;
						print(varKeyword() + " " + name + " = ");
						genValue(it);
						newline();
						name;
				};
				print("while( " + itName + ".hasNext() ) {");
				var bend = openBlock();
				newline();
				print(varKeyword() + " " + ident(v.name) + " = " + itName + ".next()");
				genBlockElement(body);
				bend();
				newline();
				spr("}");
				inLoop = oldInLoop;
			case TTry(etry, [c]):
				spr("try ");
				genExpr(etry);
				checkVarDeclaration(c.v);
				print(" catch( " + c.v.name + " ) ");
				catchVars.unshift(TypeFunctions.mk(TLocal(c.v), c.v.type, c.v.pos));
				genExpr(c.expr);
				catchVars.shift();
			case TTry(_, _):
				throw new TypingError("Unhandled try/catch, please report", e.pos);
			case TSwitch(cond, cases, def):
				spr("switch");
				genCondition(cond);
				spr(" {");
				newline();
				for (c in cases) {
					for (v in c.values) {
						switch (v.expr) {
							case TConst(TNull):
								spr("case null: case undefined:");
							case _:
								spr("case ");
								genValue(v);
								spr(":");
						}
					}
					var bend = openBlock();
					genBlockElement(c.expr);
					if (needsSwitchBreak(c.expr)) {
						newline();
						print("break");
					}
					bend();
					newline();
				}
				if (def != null) {
					spr("default:");
					var bend = openBlock();
					genBlockElement(def);
					bend();
					newline();
				}
				spr("}");
			case TCast(e1, null):
				genExpr(e1);
			case TCast(e1, mt):
				print(typeAccessor(TClassDecl(bootClass())) + ".__cast(");
				genValue(e1);
				spr(" , ");
				spr(typeAccessor(mt));
				spr(")");
			case TIdent(s):
				spr(s);
		}
	}

	// A single JavaScript condition delimiter around the typed value. Keep an existing AST parenthesis
	// as that delimiter instead of duplicating it.
	function genCondition(e:TExpr):Void {
		switch (e.expr) {
			case TParenthesis(e1):
				spr("(");
				genValue(e1);
				spr(")");
			case _:
				spr("(");
				genValue(e);
				spr(")");
		}
	}

	// A stand-in js.Boot class reference for __cast
	static var _bootClass:TClass = null;

	static function bootClass():TClass {
		if (_bootClass == null) {
			var mod:ModuleDef = TypeFunctions.nullClass.module;
			_bootClass = TypeFunctions.mkClass(mod, {pack: ["js"], name: "Boot"}, Position.nullPos, Position.nullPos);
		}
		return _bootClass;
	}

	function genFunction(f:TFunc, pos:Position, keyword:String = "function"):Void {
		var old = {v: valueVar, l: inLoop};
		valueVar = null;
		inLoop = false;
		var f = f;
		var args:Array<String>;
		var lastRest = f.args.length > 0 && f.args[f.args.length - 1].c == null
			&& isRestT(f.args[f.args.length - 1].v.type);
		if (lastRest) {
			var v = f.args[f.args.length - 1].v;
			if (esVersion >= 6) {
				args = [for (a in f.args) {
					checkVarDeclaration(a.v);
					a.v == v ? "..." + ident(a.v.name) : ident(a.v.name);
				}];
			} else {
				checkVarDeclaration(v);
				var nonRest = f.args.slice(0, f.args.length - 1);
				var argsDecl = declareRestArgsLegacy(nonRest.length, v);
				var el = switch (f.expr.expr) {
					case TBlock(el): argsDecl.concat(el);
					case _: argsDecl.concat([f.expr]);
				};
				var body = TypeFunctions.mk(TBlock(el), f.expr.type, f.expr.pos);
				f = new TFunc(nonRest, f.type, body);
				args = [for (a in f.args) {
					checkVarDeclaration(a.v);
					ident(a.v.name);
				}];
			}
		} else {
			args = [for (a in f.args) {
				checkVarDeclaration(a.v);
				ident(a.v.name);
			}];
		}
		print(keyword + "(" + args.join(",") + ") ");
		var body = funBlock(f, pos);
		body = switch (body.expr) {
			case TBlock(_): body;
			case _: TypeFunctions.mk(TBlock([body]), body.type, body.pos);
		};
		genExpr(body);
		valueVar = old.v;
		inLoop = old.l;
		separator = true;
	}

	function declareRestArgsLegacy(offset:Int, restArg:TVar):Array<TExpr> {
		var i = Std.string(offset);
		var newArray = TypeFunctions.mk(TIdent("new Array($l>" + i + "?$l-" + i + ":0)"), TypeFunctions.tDynamic, restArg.pos);
		var populate = TypeFunctions.mk(TIdent("for(var $i=" + i + ";$i<$l;++$i){" + ident(restArg.name) + "[$i-" + i + "]=arguments[$i];}"), com.basic.tvoid, restArg.pos);
		return [
			TypeFunctions.mk(TIdent("var $l=arguments.length"), com.basic.tvoid, restArg.pos),
			TypeFunctions.mk(TVarExpr(restArg, newArray), com.basic.tvoid, restArg.pos),
			populate
		];
	}

	// Prepend the null-default checks
	function funBlock(f:TFunc, p:Position):TExpr {
		var e = f.expr;
		for (a in f.args) {
			switch (a.c) {
				case null | {expr: TConst(TNull)}:
				case c:
					e = TypeFunctions.concat(TexprTools.setDefault(com.basic, a.v, c, p), e);
			}
		}
		return e;
	}

	public function genBlockElement(e:TExpr, newlineAfter:Bool = false, keepBlocks:Bool = false):Void {
		switch (e.expr) {
			case TBlock(el) if (!keepBlocks):
				for (x in el) genBlockElement(x, newlineAfter);
			case TCall({expr: TIdent("__feature__")}, params) if (params.length >= 2):
				switch (params[0].expr) {
					case TConst(TString(f)):
						if (hasFeature(f)) genBlockElement(params[1], newlineAfter)
						else if (params.length > 2) genBlockElement(params[2], newlineAfter);
					case _: unsupported(e.pos);
				}
			case TFunction(_):
				genBlockElement(TypeFunctions.mk(TParenthesis(e), e.type, e.pos), newlineAfter);
			case TObjectDecl(fl):
				for (f in fl) genBlockElement(f.expr, newlineAfter);
			case _:
				if (!newlineAfter) newline();
				genExpr(e);
				if (newlineAfter) newline();
		}
	}

	// Values record mappings too
	public function genValue(e:TExpr):Void {
		var clearMapping = addMapping(e);
		genValueBody(e);
		clearMapping();
	}

	function genValueBody(e:TExpr):Void {
		function assign(e2:TExpr):TExpr {
			return TypeFunctions.mk(TBinop(OpAssign,
				TypeFunctions.mk(TLocal(valueVar), TypeFunctions.tDynamic, e2.pos), e2), e2.type, e2.pos);
		}
		function startValue():Void->Void {
			var old = {v: valueVar, l: inLoop};
			var r = TypeFunctions.allocVar(VGenerated, "$r", TypeFunctions.tDynamic, e.pos);
			valueVar = r;
			inLoop = false;
			spr("(function($this) ");
			spr("{");
			var b = openBlock();
			newline();
			spr("var $r");
			newline();
			return function() {
				newline();
				spr("return $r");
				b();
				newline();
				spr("}");
				valueVar = old.v;
				inLoop = old.l;
				print("(" + thisStr() + "))");
			};
		}
		switch (e.expr) {
			case TConst(_) | TLocal(_) | TArray(_, _) | TBinop(_, _, _) | TField(_, _) | TEnumParameter(_, _, _)
				| TEnumIndex(_) | TTypeExpr(_) | TParenthesis(_) | TObjectDecl(_) | TArrayDecl(_) | TNew(_, _, _)
				| TUnop(_, _, _) | TFunction(_) | TIdent(_):
				genExpr(e);
			case TMeta(_, e1):
				genValue(e1);
			case TCall(callee, el):
				genCall(callee, el, true);
			case TReturn(_) | TBreak | TContinue:
				unsupported(e.pos);
			case TCast(e1, null):
				genValue(e1);
			case TCast(e1, mt):
				print(typeAccessor(TClassDecl(bootClass())) + ".__cast(");
				genValue(e1);
				spr(" , ");
				spr(typeAccessor(mt));
				spr(")");
			case TVarExpr(_, _) | TFor(_, _, _) | TWhile(_, _, _) | TThrow(_):
				// Value is discarded anyway
				var v = startValue();
				genExpr(e);
				v();
			case TBlock([e1]):
				genValue(e1);
			case TBlock(el):
				var v = startValue();
				if (el.length == 0) {
					spr("return null");
				} else {
					for (i in 0...el.length - 1) {
						genExpr(el[i]);
						newline();
					}
					genExpr(assign(el[el.length - 1]));
				}
				v();
			case TIf(cond, eif, eelse):
				// Drop the parens unless the condition binds looser than ?:
				var cond = switch (cond.expr) {
					case TParenthesis({expr: TBinop(OpAssign | OpAssignOp(_), _, _) | TIf(_, _, _)}): cond;
					case TParenthesis(e1): e1;
					case _: cond;
				};
				genValue(cond);
				spr(" ? ");
				genValue(eif);
				spr(" : ");
				if (eelse == null) spr("null") else genValue(eelse);
			case TSwitch(cond, cases, def):
				var v = startValue();
				genExpr(TypeFunctions.mk(TSwitch(cond,
					[for (c in cases) {values: c.values, expr: assign(c.expr)}],
					def == null ? null : assign(def)), e.type, e.pos));
				v();
			case TTry(b, catches):
				var v = startValue();
				function block(x:TExpr):TExpr return TypeFunctions.mk(TBlock([x]), x.type, x.pos);
				genExpr(TypeFunctions.mk(TTry(block(assign(b)),
					[for (c in catches) {v: c.v, expr: block(assign(c.expr))}]), e.type, e.pos));
				v();
		}
	}

	function genSyntax(meth:String, args:Array<TExpr>, pos:Position):Void {
		switch [meth, args] {
			case ["construct", _] if (args.length >= 1):
				spr("new ");
				switch (args[0].expr) {
					case TConst(TString(cl)): spr(cl);
					case _: genValue(args[0]);
				}
				spr("(");
				concatWith(",", genValue, args.slice(1));
				spr(")");
			case ["instanceof", [o, t]]:
				spr("((");
				genValue(o);
				print(") instanceof ");
				genValue(t);
				spr(")");
			case ["typeof", [o]]:
				spr("typeof(");
				genValue(o);
				spr(")");
			case ["strictEq", [x, y]]:
				// Extra parens for operator precedence
				spr("((");
				genValue(x);
				spr(") === ");
				genValue(y);
				spr(")");
			case ["strictNeq", [x, y]]:
				spr("((");
				genValue(x);
				spr(") !== ");
				genValue(y);
				spr(")");
			case ["delete", [o, f]]:
				spr("delete(");
				genValue(o);
				spr("[");
				genValue(f);
				spr("]");
				spr(")");
			case ["code", _] if (args.length >= 1):
				var code = args[0];
				var codeStr = switch (code.expr) {
					case TConst(TString(s)): s;
					case _: throw new TypingError("The `code` argument for js.Syntax.code must be a string constant", code.pos);
				};
				var params = args.slice(1);
				if (params.length == 0 && codeStr == "this") {
					spr(thisStr());
				} else {
					function revealExpr(x:TExpr):TExpr {
						return switch (x.expr) {
							case TCast(e1, _) | TMeta(_, e1): revealExpr(e1);
							case _: x;
						};
					}
					var params = [for (arg in params) switch (revealExpr(arg).expr) {
						case TIf(_, _, _) | TBinop(_, _, _) | TUnop(_, _, _): TypeFunctions.mk(TParenthesis(arg), arg.type, arg.pos);
						case _: arg;
					}];
					hxc.codegen.Codegen.interpolateCode(com, codeStr, params, spr, genValue, code.pos);
				}
			case ["plainCode", [code]]:
				var codeStr = switch (code.expr) {
					case TConst(TString(s)): s;
					case _: throw new TypingError("The `code` argument for js.Syntax.plainCode must be a string constant", code.pos);
				};
				spr(codeStr.split("\r\n").join("\n"));
			case ["field", [eobj, efield]]:
				genValue(eobj);
				switch (TexprTools.skip(efield).expr) {
					case TConst(TString(s)) if (validJsIdent(s)):
						spr(".");
						spr(s);
					case _:
						spr("[");
						genValue(efield);
						spr("]");
				}
			case _:
				throw new TypingError("Unknown js.Syntax method `" + meth + "` with " + args.length + " arguments", pos);
		}
	}

	function generatePackageCreate(p:Path):Void {
		if (p.pack.length == 0) {
			print("var ");
			return;
		}
		var acc:Array<String> = [];
		for (part in p.pack) {
			var keyParts = acc.concat([part]);
			var key = keyParts.join(".");
			if (!packages.exists(key)) {
				packages.set(key, true);
				if (acc.length == 0) {
					if (jsModern) print("var " + part + " = {}")
					else print("var " + part + " = " + part + " || {}");
				} else {
					var path = acc.join(".") + field(part);
					if (jsModern) print(path + " = {}")
					else print("if(!" + path + ") " + path + " = {}");
				}
				separator = true;
				newline();
			}
			acc.push(part);
		}
	}

	function checkFieldName(c:TClass, f:TClassField):Void {
		switch (f.name) {
			case "prototype" | "__proto__" | "constructor":
				throw new TypingError("The field name '" + f.name + "'  is not allowed in JS", f.expr == null ? c.pos : f.expr.pos);
			case _:
		}
	}

	static function pathToBrackets(path:String):String {
		var parts = path.split(".");
		return "[\"" + parts.join("\"][\"") + "\"]";
	}

	function genModuleFields(m:ModuleDef, c:TClass, fl:Array<TClassField>):Void {
		for (f in fl) {
			var name = moduleField(com, m, f);
			if (f.expr == null) {
				if (TypeFunctions.isPhysicalField(f)) {
					print("var " + name + " = null");
					newline();
				}
			} else switch (f.expr.expr) {
				case TFunction(fn):
					idCounter = 0;
					print("function " + name);
					genFunction(fn, f.expr.pos, "");
					separator = false;
					newline();
					var mpath = m.path;
					processExpose(com, f.meta, function() return moduleFieldExposePath(com, mpath, f), function(s) {
						print("$hx_exports" + pathToBrackets(s) + " = " + name);
						newline();
					});
				case _:
					statics.push({c: c, f: f, e: f.expr});
			}
		}
	}

	function genClassStaticField(c:TClass, clPath:Path, f:TClassField):Void {
		switch (f.expr) {
			case null | {expr: TConst(TNull)} if (!hasFeature("Type.getClassFields")):
			case null if (!TypeFunctions.isPhysicalField(f)):
			case null:
				print(sPath(clPath) + staticField(c, f) + " = null");
				newline();
			case e:
				switch (e.expr) {
					case TFunction(_):
						var path = sPath(clPath) + staticField(c, f);
						idCounter = 0;
						print(path + " = ");
						processExpose(com, f.meta, function() return dotPath(clPath) + "." + f.name, function(s) print("$hx_exports" + pathToBrackets(s) + " = "));
						genValue(e);
						newline();
					case _:
						statics.push({c: c, f: f, e: e});
				}
		}
	}

	function canGenClassField(f:TClassField):Bool {
		switch (f.expr) {
			case null | {expr: TConst(TNull)} if (!hasFeature("Type.getInstanceFields")):
				return false;
			case _:
		}
		if (TypeFunctions.hasClassFieldFlag(f, CfExtern)) return false;
		return TypeFunctions.isPhysicalField(f);
	}

	function genClassField(c:TClass, f:TClassField):Void {
		checkFieldName(c, f);
		if (f.expr == null) {
			newprop();
			print(anonField(f.name) + ": ");
			print("null");
		} else {
			newprop();
			print(anonField(f.name) + ": ");
			idCounter = 0;
			genValue(f.expr);
			separator = false;
		}
	}

	function generateClassName(clPath:Path):Void {
		if (hasFeature("js.Boot.isClass")) {
			var p = sPath(clPath);
			print(p + ".__name__ = ");
			if (hasFeature("Type.getClassName") || (clPath.pack.length == 0 && (clPath.name == "Array" || clPath.name == "String")))
				print("\"" + dotPath(clPath) + "\"")
			else
				print("true");
			newline();
		}
	}

	function generateClassIsInterface(c:TClass):Void {
		if (TypeFunctions.hasClassFlag(c, CInterface) && hasFeature("js.Boot.isInterface")) {
			print(sPath(c.path) + ".__isInterface__ = true");
			newline();
		}
	}

	function genProps(props:Array<{name:String, value:String}>):String {
		return [for (p in props) p.name + ":\"" + p.value + "\""].join(",");
	}

	function generateClassEs3(c:TClass):Void {
		var clPath = getGeneratedClassPath(c);
		var abstractImpl = isAbstractImpl(c);

		if (jsFlatten) print("var ")
		else generatePackageCreate(clPath);

		var p = sPath(clPath);
		var dotp = dotPath(clPath);
		var addedToHxClasses = hasResolveClass && !abstractImpl;

		// Keep $hxClasses off the declaration line so a debugger's class stringification does not trip
		if (com.debug || jsModern || !addedToHxClasses)
			print(p + " = ")
		else
			print(p + " = $hxClasses[\"" + dotp + "\"] = ");

		if (!com.debug)
			processExpose(com, c.meta, function() return dotp, function(s) print("$hx_exports" + pathToBrackets(s) + " = "));

		if (abstractImpl) {
			// Abstract implementations only hold statics
			print("{}");
			separator = true;
		} else {
			switch (c.constructor) {
				case {expr: e} if (e != null): genExpr(e);
				case _:
					print("function() { }");
					separator = true;
			}
		}

		newline();

		if ((jsModern || com.debug) && addedToHxClasses) {
			print("$hxClasses[\"" + dotp + "\"] = " + p);
			newline();
		}

		if (com.debug)
			processExpose(com, c.meta, function() return dotp, function(s) {
				print("$hx_exports" + pathToBrackets(s) + " = " + p);
				newline();
			});

		if (!abstractImpl) {
			generateClassName(clPath);
			generateClassIsInterface(c);
		}

		if (hasInterfaceCheck && c.interfaces.length > 0) {
			print(p + ".__interfaces__ = [" + [for (i in c.interfaces) typeAccessor(TClassDecl(i.c))].join(",") + "]");
			newline();
		}

		var hasPropertyReflection = hasFeature("Reflect.getProperty") || hasFeature("Reflect.setProperty");

		if (hasPropertyReflection) {
			var props = hxc.codegen.Codegen.getProperties(c.orderedStatics);
			if (props.length > 0) {
				print(p + ".__properties__ = {" + genProps(props) + "}");
				separator = true;
				newline();
			}
		}

		for (f in c.orderedStatics) genClassStaticField(c, clPath, f);

		var hasClass = hasFeature("js.Boot.getClass") && (c.superClass != null || c.orderedFields.length > 0 || c.constructor != null);
		var hasFieldsToGen = false;
		for (f in c.orderedFields) if (canGenClassField(f)) { hasFieldsToGen = true; break; }
		var hasPrototype = c.superClass != null || hasClass || hasFieldsToGen;
		if (hasPrototype) {
			switch (c.superClass) {
				case null:
					print(p + ".prototype = {");
				case sup:
					var psup = typeAccessor(TClassDecl(sup.c));
					print(p + ".__super__ = " + psup);
					newline();
					print(p + ".prototype = $extend(" + psup + ".prototype,{");
			}

			var bend = openBlock();
			for (f in c.orderedFields) if (canGenClassField(f)) genClassField(c, f);
			if (hasClass) {
				newprop();
				print("__class__: " + p);
			}

			if (hasPropertyReflection) {
				var props = hxc.codegen.Codegen.getProperties(c.orderedFields);
				if (props.length > 0) {
					if (c.superClass != null && hxc.codegen.Codegen.hasProperties(c.superClass.c)) {
						newprop();
						var psup = typeAccessor(TClassDecl(c.superClass.c));
						print("__properties__: $extend(" + psup + ".prototype.__properties__,{" + genProps(props) + "})");
					} else {
						newprop();
						print("__properties__: {" + genProps(props) + "}");
					}
				}
			}

			bend();
			print("\n}");
			if (c.superClass == null) separator = true else print(")");
			newline();
		}
	}

	function generateClassEs6(c:TClass):Void {
		var clPath = getGeneratedClassPath(c);
		var p = sPath(clPath);
		var dotp = dotPath(clPath);

		var clsName:String;
		if (!jsFlatten && clPath.pack.length > 0) {
			generatePackageCreate(clPath);
			print(p + " = ");
			clsName = flatPath(clPath);
		} else {
			clsName = p;
		}
		print("class " + clsName);

		if (c.superClass != null)
			print(" extends " + typeAccessor(TClassDecl(c.superClass.c)));

		spr(" {");
		var closeBlock = openBlock();

		var ctor = c.constructor;
		if (ctor != null && ctor.expr != null) switch (ctor.expr.expr) {
			case TFunction(f):
				newline();
				genFunction(f, ctor.expr.pos, "constructor");
				separator = false;
			case _:
		}

		function methodDefName(cf:TClassField):String
			return validJsIdent(cf.name) ? cf.name : "\"" + cf.name + "\"";

		var nonmethodFields:Array<TClassField> = [];
		for (cf in c.orderedFields) {
			var emitted = false;
			if (cf.kind.match(Method(_)) && cf.expr != null) switch (cf.expr.expr) {
				case TFunction(f):
					checkFieldName(c, cf);
					newline();
					genFunction(f, cf.expr.pos, methodDefName(cf));
					separator = false;
					emitted = true;
				case _:
			}
			if (!emitted) nonmethodFields.push(cf);
		}

		var exposedStaticMethods:Array<{path:String, name:String}> = [];
		var nonmethodStatics:Array<TClassField> = [];
		for (cf in c.orderedStatics) {
			var emitted = false;
			if (cf.kind.match(Method(_)) && cf.expr != null) switch (cf.expr.expr) {
				case TFunction(f):
					checkFieldName(c, cf);
					newline();
					genFunction(f, cf.expr.pos, "static " + methodDefName(cf));
					separator = false;
					var name = cf.name;
					processExpose(com, cf.meta, function() return dotp + "." + name, function(s) exposedStaticMethods.unshift({path: s, name: name}));
					emitted = true;
				case _:
			}
			if (!emitted) nonmethodStatics.push(cf);
		}

		closeBlock();
		newline();
		spr("}");
		newline();

		for (m in exposedStaticMethods) {
			print("$hx_exports" + pathToBrackets(m.path) + " = " + p + "." + m.name + ";");
			newline();
		}

		for (f in nonmethodStatics) genClassStaticField(c, clPath, f);

		var abstractImpl = isAbstractImpl(c);

		var added = false;
		if (hasResolveClass && !abstractImpl) {
			added = true;
			print("$hxClasses[\"" + dotp + "\"] = ");
		}
		processExpose(com, c.meta, function() return dotp, function(s) {
			added = true;
			print("$hx_exports" + pathToBrackets(s) + " = ");
		});
		if (added) {
			spr(p);
			newline();
		}

		if (!abstractImpl) {
			generateClassName(clPath);
			generateClassIsInterface(c);
		}

		if (hasInterfaceCheck && c.interfaces.length > 0) {
			print(p + ".__interfaces__ = [" + [for (i in c.interfaces) typeAccessor(TClassDecl(i.c))].join(",") + "]");
			newline();
		}

		var hasPropertyReflection = hasFeature("Reflect.getProperty") || hasFeature("Reflect.setProperty");
		// The es6 props writer puts a space after the colon, the es3 one does not
		function genPropsEs6(props:Array<{name:String, value:String}>):String
			return [for (pr in props) pr.name + ": \"" + pr.value + "\""].join(",");

		if (hasPropertyReflection) {
			var props = hxc.codegen.Codegen.getProperties(nonmethodStatics);
			if (props.length > 0) {
				print(p + ".__properties__ = {" + genPropsEs6(props) + "}");
				separator = true;
				newline();
			}
		}

		if (c.superClass != null && (hasInterfaceCheck || hasFeature("Type.getSuperClass"))) {
			var psup = typeAccessor(TClassDecl(c.superClass.c));
			print(p + ".__super__ = " + psup);
			newline();
		}

		var hasClass = hasFeature("js.Boot.getClass") && (c.superClass != null || c.orderedFields.length > 0 || c.constructor != null);
		var propsToGenerate = hasPropertyReflection ? hxc.codegen.Codegen.getProperties(c.orderedFields) : [];
		var fieldsToGenerate = if (hasFeature("Type.getInstanceFields")) {
			TypeFunctions.hasClassFlag(c, CInterface)
				? [for (f in c.orderedFields) if (TypeFunctions.isPhysicalField(f)) f]
				: [for (f in nonmethodFields) if (TypeFunctions.isPhysicalVarField(f)) f];
		} else [];

		if (hasClass || propsToGenerate.length > 0 || fieldsToGenerate.length > 0) {
			print("Object.assign(" + p + ".prototype, {");
			var bend = openBlock();

			if (hasClass) {
				newprop();
				print("__class__: " + p);
			}

			for (f in fieldsToGenerate) genClassField(c, f);

			if (propsToGenerate.length > 0) {
				newprop();
				if (c.superClass != null && hxc.codegen.Codegen.hasProperties(c.superClass.c)) {
					var psup = typeAccessor(TClassDecl(c.superClass.c));
					print("__properties__: Object.assign({}, " + psup + ".prototype.__properties__, {" + genPropsEs6(propsToGenerate) + "})");
				} else {
					print("__properties__: {" + genPropsEs6(propsToGenerate) + "}");
				}
			}

			bend();
			print("\n})");
			newline();
		}
	}

	function generateClass(c:TClass):Void {
		current = c;
		idCounter = 0;
		if (c.path.pack.length == 0 && c.path.name == "Function")
			throw new TypingError("This class redefine a native one", c.pos);
		switch (c.kind) {
			case KModuleFields(m):
				genModuleFields(m, c, c.orderedStatics);
			case _:
				if (esVersion >= 6)
					generateClassEs6(c)
				else
					generateClassEs3(c);
		}
	}

	function generateEnum(e:TEnum):Void {
		var p = sPath(e.path);
		var dotp = dotPath(e.path);
		var hasEnumFeature = hasFeature("has_enum");
		if (jsFlatten) print("var ")
		else generatePackageCreate(e.path);
		print(p + " = ");
		var asObjects = !com.defines.rawDefined("js_enums_as_arrays");
		if (asObjects)
			print("$hxEnums[\"" + dotp + "\"] = ")
		else if (hasFeature("Type.resolveEnum"))
			print("$hxClasses[\"" + dotp + "\"] = ");
		spr("{");
		if (hasFeature("js.Boot.isEnum"))
			print(" __ename__:" + (hasFeature("Type.getEnumName") ? "\"" + dotp + "\"" : "true") + ",");
		if (asObjects)
			print("__constructs__:null")
		else
			print("__constructs__:[" + [for (s in e.names) "\"" + s + "\""].join(",") + "]");
		var bend:Void->Void;
		if (!asObjects) {
			spr(" }");
			separator = true;
			newline();
			bend = function() {};
		} else {
			bend = openBlock();
		}
		for (n in e.names) {
			var f = e.constrs.get(n);
			if (asObjects) {
				newprop();
				print(anonField(f.name) + ": ");
			} else
				print(p + field(f.name) + " = ");
			switch (f.type) {
				case TFun(sig):
					var sargs = [for (a in sig.args) ident(a.name)].join(",");
					if (asObjects) {
						var sfields = [for (a in sig.args) ident(a.name) + ":" + ident(a.name)].join(",");
						var sparams = [for (a in sig.args) "\"" + ident(a.name) + "\""].join(",");
						print("($_=function(" + sargs + ") { return {_hx_index:" + f.index + "," + sfields + ",__enum__:\"" + dotp + "\"");
						if (hasEnumFeature) spr(",toString:$estr");
						print("}; },$_._hx_name=\"" + f.name + "\",$_.__params__ = [" + sparams + "],$_)");
					} else {
						print("function(" + sargs + ") { var $x = [\"" + f.name + "\"," + f.index + "," + sargs + "]; $x.__enum__ = " + p + ";");
						if (hasEnumFeature) spr(" $x.toString = $estr;");
						spr(" return $x; }");
					}
				case _:
					if (asObjects) {
						print("{_hx_name:\"" + f.name + "\",_hx_index:" + f.index + ",__enum__:\"" + dotp + "\"" + (hasEnumFeature ? ",toString:$estr" : "") + "}");
					} else {
						print("[\"" + f.name + "\"," + f.index + "]");
						newline();
						if (hasFeature("has_enum")) {
							print(p + field(f.name) + ".toString = $estr");
							newline();
						}
						print(p + field(f.name) + ".__enum__ = " + p);
					}
			}
			if (!asObjects) newline();
		}
		bend();
		if (asObjects) {
			spr("\n}");
			separator = true;
			newline();
			print(p + ".__constructs__ = [" + [for (s in e.names) p + field(s)].join(",") + "]");
			newline();
		}
		if (hasFeature("Type.allEnums")) {
			var ctorsWithoutArgs = [for (s in e.names) if (!TypeFunctions.follow(e.constrs.get(s).type).match(TFun(_))) s];
			print(p + ".__empty_constructs__ = [" + [for (s in ctorsWithoutArgs) p + "." + s].join(",") + "]");
			newline();
		}
		var meta = TexprTools.buildMetadata(com.basic, TEnumDecl(e));
		if (meta != null) {
			print(p + ".__meta__ = ");
			genExpr(meta);
			newline();
		}
	}

	function generateStatic(c:TClass, f:TClassField, e:TExpr):Void {
		switch (c.kind) {
			case KModuleFields(m):
				print("var " + moduleField(com, m, f) + " = ");
				var mpath = m.path;
				processExpose(com, f.meta, function() return moduleFieldExposePath(com, mpath, f), function(s) print("$hx_exports" + pathToBrackets(s) + " = "));
			case _:
				var clPath = getGeneratedClassPath(c);
				processExpose(com, f.meta, function() return dotPath(clPath) + "." + f.name, function(s) print("$hx_exports" + pathToBrackets(s) + " = "));
				print(sPath(clPath) + staticField(c, f) + " = ");
		}
		genValue(e);
		newline();
	}

	function generateRequire(path:Path, meta:Metadata):Void {
		var entry = TypeFunctions.getMeta(":jsRequire", meta);
		var p = sPath(path);
		if (jsFlatten) spr("var ")
		else generatePackageCreate(path);
		switch (entry.params) {
			case [{expr: EConst(CString(moduleName, _))}]:
				print(p + " = require(\"" + moduleName + "\")");
			case [{expr: EConst(CString(moduleName, _))}, {expr: EConst(CString(objectPath, _))}]:
				print(p + " = require(\"" + moduleName + "\")." + objectPath);
			case _:
				throw new TypingError("Unsupported @:jsRequire format", entry.pos);
		}
		newline();
	}

	function needToGenerateInterface(c:TClass):Bool {
		return hasResolveClass || hasInterfaceCheck || com.isDirectlyUsed(c.meta);
	}

	function generateType(t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c):
				if (c.init != null) inits.unshift(c.init);
				// Hxc keeps a static __init__ as a field (the interpreter calls it); the reference moves its
				// body to init at load time (typeloadFields FKInit), so route it to the init list here and keep
				// it out of the statics
				var initCf = c.statics.get("__init__");
				if (initCf != null && initCf.expr != null) {
					switch (initCf.expr.expr) {
						case TFunction(fn): inits.unshift(fn.expr);
						case _:
					}
					c.statics.remove("__init__");
					c.orderedStatics = [for (f in c.orderedStatics) if (f.name != "__init__") f];
				}
				// Math.__name__ is added only when required (Math is extern); empty Std is skipped
				var p = sPath(c.path);
				if (p == "Math") generateClassName(c.path);
				if (p == "Std" && c.orderedStatics.length == 0) {
					// Nothing
				} else if (!TypeFunctions.hasClassFlag(c, CExtern)) {
					if (!TypeFunctions.hasClassFlag(c, CInterface) || needToGenerateInterface(c)) {
						// Collect periodically; the probe is diagnostics-only.
						genCount++;
							if (genCount % 200 == 0) {
							#if cpp cpp.vm.Gc.run(true); #end
							hxc.filters.Filters.memProbe("gen:" + Std.string(genCount) + ":" + hxc.core.Globals.sTypePath(c.path));
						}
						generateClass(c);
					}
				} else if (TypeFunctions.hasMeta(":jsRequire", c.meta) && com.isDirectlyUsed(c.meta)) {
					generateRequire(getGeneratedClassPath(c), c.meta);
				} else if (!jsFlatten && TypeFunctions.hasMeta(":initPackage", c.meta)) {
					if (c.path.pack.length > 0) generatePackageCreate(c.path);
				}
			case TEnumDecl(e) if (e.isExtern):
				if (TypeFunctions.hasMeta(":jsRequire", e.meta) && com.isDirectlyUsed(e.meta))
					generateRequire(e.path, e.meta);
			case TEnumDecl(e):
				generateEnum(e);
			case TTypeDecl(_) | TAbstractDecl(_):
		}
	}

	public static function generate(com:Context):Void {
		// A custom generator installed by a macro replaces the whole output.
		if (com.jsGen != null) {
			com.jsGen();
			return;
		}
		var esVersion = com.getEsVersion();
		if (esVersion >= 6)
			hxc.filters.ES6Ctors.rewriteCtors(com);
		var ctx = allocCtx(com, esVersion);
		hxc.codegen.Codegen.mapSourceHeader(com, function(s) ctx.print("// " + s + "\n"));
		// Raw files spliced by haxe.macro.Compiler.includeFile: placement "top" prints before everything,
		// "closure" just before the closure wrapper below.
		var includeFiles = com.includeFiles.copy();
		includeFiles.reverse();
		for (inc in includeFiles) if (inc.position == "top")
			ctx.print(sys.io.File.getContent(inc.file) + "\n;");
		if (ctx.hasFeature("Class") || ctx.hasFeature("Type.getClassName")) ctx.addFeature("js.Boot.isClass");
		if (ctx.hasFeature("Enum") || ctx.hasFeature("Type.getEnumName")) ctx.addFeature("js.Boot.isEnum");

		var nodejs = com.defines.rawDefined("nodejs");
		setupKwds(com);

		var exposed:Array<String> = [];
		for (t in com.types) switch (t) {
			case TClassDecl(c):
				var getExposePath:TClassField->String;
				switch (c.kind) {
					case KModuleFields(m):
						var mpath = m.path;
						getExposePath = function(f) return moduleFieldExposePath(com, mpath, f);
					case _:
						var path = dotPath(c.path);
						processExpose(com, c.meta, function() return path, function(s) exposed.push(s));
						getExposePath = function(f) return path + "." + f.name;
				}
				for (f in c.orderedStatics)
					processExpose(com, f.meta, function() return getExposePath(f), function(s) exposed.push(s));
			case _:
		}
		var anyExposed = exposed.length > 0;
		// Nested-object index for shallow exposure
		var exposedObject = {name: "", fields: new Array<Dynamic>()};
		var toplevelExposed:Array<String> = [];
		if (anyExposed) {
			var exportMap = new StringMap<{name:String, fields:Array<Dynamic>}>();
			for (path in exposed) {
				var parts = path.split(".");
				var pre = "";
				for (i in 0...parts.length) {
					if (i < parts.length - 1) {
						var f = parts[i];
						var cur = pre == "" ? f : pre + "." + f;
						if (!exportMap.exists(cur)) {
							var elts = {name: f, fields: new Array<Dynamic>()};
							exportMap.set(cur, elts);
							var cobject = pre == "" ? exposedObject : exportMap.get(pre);
							cobject.fields.unshift(elts);
						}
						pre = cur;
					} else if (i == 0) {
						toplevelExposed.unshift(parts[0]);
					}
				}
			}
		}

		var definedGlobalValue = com.defines.rawDefinedValueSafe("js_global", "");
		var definedGlobal = definedGlobalValue != "";

		function typeofJoin(l:Array<String>):String {
			if (l.length == 1) return l[0];
			return "typeof " + l[0] + " != \"undefined\" ? " + l[0] + " : " + typeofJoin(l.slice(1));
		}

		var varExports = {name: "$hx_exports", value: typeofJoin(definedGlobal ? ["exports", definedGlobalValue] : ["exports", "window", "self", "this"])};
		var varGlobal = {name: "$global", value: typeofJoin(definedGlobal ? [definedGlobalValue] : ["window", "global", "self", "this"])};

		for (inc in includeFiles) if (inc.position == "closure")
			ctx.print(sys.io.File.getContent(inc.file) + "\n;");
		var closureArgs = [varGlobal];
		if (anyExposed && !com.defines.rawDefined("shallow_expose"))
			closureArgs.unshift(varExports);
		if (ctx.esVersion < 5)
			closureArgs.unshift({name: "console", value: typeofJoin(["console", "{log:function(){}}"])});

		if (nodejs)
			for (s in ["global", "process", "__filename", "__dirname", "module"]) kwds2.set(s, true);

		if (anyExposed && (com.defines.rawDefined("shallow_expose") || !ctx.jsModern)) {
			ctx.print("var " + varExports.name + " = " + varExports.value);
			ctx.separator = true;
			ctx.newline();
		}

		if (ctx.jsModern) {
			// Wrap the output in a closure
			ctx.print("(function (" + [for (a in closureArgs) a.name].join(", ") + ") { \"use strict\"");
			ctx.newline();
		}

		function printObj(f:{name:String, fields:Array<Dynamic>}, root:String):Void {
			var path = root + pathToBrackets(f.name);
			ctx.print(path + " = " + path + " || {}");
			ctx.separator = true;
			ctx.newline();
			ctx.concatWith(";", function(g:Dynamic) printObj(g, path), f.fields);
		}
		for (f in exposedObject.fields) printObj(f, "$hx_exports");

		if (!ctx.jsModern && ctx.esVersion < 5)
			ctx.addFeature("js.Lib.global"); // Console polyfill reads console from $global

		if (!ctx.jsModern)
			ctx.print("var " + varGlobal.name + " = " + varGlobal.value + ";\n");

		if (!ctx.jsModern && ctx.esVersion < 5)
			ctx.spr("var console = $global.console || {log:function(){}};\n");

		var enumsAsObjects = !com.defines.rawDefined("js_enums_as_arrays");

		var vars:Array<String> = [];
		if (ctx.hasResolveClass || (!enumsAsObjects && ctx.hasFeature("Type.resolveEnum")))
			vars.push("$hxClasses = " + (ctx.jsModern ? "{}" : "$hxClasses || {}"));
		if (ctx.hasFeature("has_enum"))
			vars.push("$estr = function() { return " + ctx.typeAccessor(TClassDecl(bootClass())) + ".__string_rec(this,''); }");
		if (enumsAsObjects && (ctx.hasFeature("has_enum") || ctx.hasFeature("Type.resolveEnum")))
			vars.push("$hxEnums = $hxEnums || {}");
		var hasDollarUnderscore = false;
		for (t in com.types) switch (t) {
			case TEnumDecl(e) if (!e.isExtern):
				if (!hasDollarUnderscore) {
					vars.push("$_");
					hasDollarUnderscore = true;
				}
			case _:
		}
		if (vars.length > 0) {
			ctx.print("var " + vars.join(","));
			ctx.separator = true;
			ctx.newline();
		}
		var needsExtend = false;
		if (ctx.esVersion < 6)
			for (t in com.types) switch (t) {
				case TClassDecl(c) if (c.superClass != null && !TypeFunctions.hasClassFlag(c, CExtern)): needsExtend = true; break;
				case _:
			}
		if (needsExtend) {
			var extendCode = "function $extend(from, fields) {\n"
				+ (ctx.esVersion < 5
					? "	function Inherit() {} Inherit.prototype = from; var proto = new Inherit();\n"
					: "	var proto = Object.create(from);\n")
				+ "	for (var name in fields) proto[name] = fields[name];\n"
				+ "	if( fields.toString !== Object.prototype.toString ) proto.toString = fields.toString;\n"
				+ "	return proto;\n"
				+ "}\n";
			ctx.spr(extendCode);
		}
		if (com.defines.rawDefined("genjs_debug")) {
			Sys.println("[GENJS] types=" + com.types.length);
			for (t in com.types) Sys.println("[GENJS] " + Context.sTypePath(TypeFunctions.tPath(t)));
		}
		for (t in com.types) ctx.generateType(t);
		// Feature discovery over inits and statics
		function chkFeatures(e:TExpr):Void {
			if (ctx.isDynamicIterator(e)) ctx.addFeature("use.$iterator");
			switch (e.expr) {
				case TField(_, FClosure(_, _)):
					ctx.addFeature("use.$bind");
				case TCall(ef = {expr: TField(_, f)}, []) if (TypeFunctions.fieldName(f) == "iterator" && ctx.isDynamicIterator(ef)):
					ctx.addFeature("use.$getIterator");
				case _:
					TexprTools.iter(chkFeatures, e);
			}
		}
		for (e in ctx.inits) chkFeatures(e);
		for (s in ctx.statics) chkFeatures(s.e);
		if (ctx.hasFeature("use.$iterator")) {
			ctx.addFeature("use.$bind");
			var arrayIterator = ctx.sPath({pack: ["haxe", "iterators"], name: "ArrayIterator"});
			ctx.print("function $iterator(o) { if( o instanceof Array ) return function() { return new " + arrayIterator + "(o); }; return typeof(o.iterator) == 'function' ? $bind(o,o.iterator) : o.iterator; }");
			ctx.newline();
		}
		if (ctx.hasFeature("use.$keyValueIterator")) {
			ctx.addFeature("use.$bind");
			ctx.print("function $keyValueIterator(o) { if( o instanceof Array ) return function() { return HxOverrides.keyValueIter(o); }; return typeof(o.keyValueIterator) == 'function' ? $bind(o,o.keyValueIterator) : o.keyValueIterator; }");
			ctx.newline();
		}
		if (ctx.hasFeature("use.$getIterator")) {
			var arrayIterator = ctx.sPath({pack: ["haxe", "iterators"], name: "ArrayIterator"});
			ctx.print("function $getIterator(o) { if( o instanceof Array ) return new " + arrayIterator + "(o); else return o.iterator(); }");
			ctx.newline();
		}
		if (ctx.hasFeature("use.$getKeyValueIterator")) {
			ctx.print("function $getKeyValueIterator(o) { if( o instanceof Array ) return HxOverrides.keyValueIter(o); else return o.keyValueIterator(); }");
			ctx.newline();
		}
		if (ctx.hasFeature("use.$bind")) {
			ctx.addFeature("$global.$haxeUID");
			if (!hasDollarUnderscore) {
				ctx.print("var $_");
				ctx.newline();
				hasDollarUnderscore = true;
			}
			if (ctx.esVersion < 5)
				ctx.print("function $bind(o,m) { if( m == null ) return null; if( m.__id__ == null ) m.__id__ = $global.$haxeUID++; var f; if( o.hx__closures__ == null ) o.hx__closures__ = {}; else f = o.hx__closures__[m.__id__]; if( f == null ) { f = function(){ return f.method.apply(f.scope, arguments); }; f.scope = o; f.method = m; o.hx__closures__[m.__id__] = f; } return f; }")
			else
				ctx.print("function $bind(o,m) { if( m == null ) return null; if( m.__id__ == null ) m.__id__ = $global.$haxeUID++; var f; if( o.hx__closures__ == null ) o.hx__closures__ = {}; else f = o.hx__closures__[m.__id__]; if( f == null ) { f = m.bind(o); o.hx__closures__[m.__id__] = f; } return f; }");
			ctx.newline();
		}
		if (ctx.hasFeature("use.$arrayPush")) {
			ctx.print("function $arrayPush(x) { return this.push(x); }");
			ctx.newline();
		}
		if (ctx.hasFeature("$global.$haxeUID")) {
			ctx.addFeature("js.Lib.global");
			ctx.print("$global.$haxeUID |= 0;\n");
		}
		if (!hasDollarUnderscore && ctx.hasFeature("thisForCallWithRestArgs")) {
			ctx.print("var $_");
			ctx.newline();
			hasDollarUnderscore = true;
		}
		var initsRev = ctx.inits.copy();
		initsRev.reverse();
		for (e in initsRev) ctx.genBlockElement(e, true, ctx.esVersion >= 6);
		// ctx.statics is APPENDED in declaration order, so it emits as-is: a static initializer may read an
		// earlier one.
		for (s in ctx.statics) ctx.generateStatic(s.c, s.f, s.e);
		if (com.main != null) {
			ctx.genExpr(com.main);
			ctx.newline();
		}
		if (ctx.jsModern) {
			var args = closureArgs;
			if (!(ctx.hasFeature("js.Lib.global") || definedGlobal)) {
				// $global can be {} when nothing reads it
				args = args.copy();
				args[args.length - 1] = {name: args[args.length - 1].name, value: "{}"};
			}
			ctx.print("})(" + [for (a in args) a.value].join(", ") + ")");
			ctx.newline();
		}

		if (anyExposed && com.defines.rawDefined("shallow_expose")) {
			for (f in exposedObject.fields) {
				var fo:{name:String, fields:Array<Dynamic>} = f;
				ctx.print("var " + fo.name + " = $hx_exports" + pathToBrackets(fo.name));
				ctx.separator = true;
				ctx.newline();
			}
			for (f in toplevelExposed) {
				ctx.print("var " + f + " = $hx_exports" + pathToBrackets(f));
				ctx.separator = true;
				ctx.newline();
			}
		}

		// Write the source map or remove a stale one, then flush
		if (ctx.smap != null)
			ctx.writeMappings();
		else
			try sys.FileSystem.deleteFile(com.file + ".map") catch (_:Dynamic) {}
		sys.io.File.saveContent(com.file, ctx.buf.toString());
	}
}
