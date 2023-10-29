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

class GenJS {
	public var com:Context;
	public var buf:StringBuf;
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

	public static function checkVarDeclaration(v:TVar):Void {
		if (kwds2.exists(v.name)) v.name = "$" + v.name;
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
		// Path.flat_path: pack joined with '_'; a leading '_' marks a private package part
		return p.pack.length == 0 ? p.name : p.pack.join("_") + "_" + p.name;
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

	public function spr(s:String):Void {
		separator = false;
		buf.add(s);
	}

	public function print(s:String):Void {
		separator = false;
		buf.add(s);
	}

	// A separator-aware statement break
	public function newline():Void {
		var s = buf.toString();
		var last = s.length > 0 ? s.charAt(s.length - 1) : "";
		switch (last) {
			case "}" | "{" | ":" | ";" if (!separator):
				print("\n" + tabs);
			case _:
				print(";\n" + tabs);
		}
	}

	public function newprop():Void {
		var s = buf.toString();
		var last = s.length > 0 ? s.charAt(s.length - 1) : "";
		switch (last) {
			case "{": print("\n" + tabs);
			case _: print("\n" + tabs + ",");
		}
	}

	public function semicolon():Void {
		var s = buf.toString();
		var last = s.length > 0 ? s.charAt(s.length - 1) : "";
		switch (last) {
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

	// The driver entry lands with the declaration emitters; this placeholder writes the closure skeleton so
	// the -js plumbing is provable end to end.
	public static function generate(com:Context):Void {
		var esVersion = com.getEsVersion();
		setupKwds(com);
		var ctx = allocCtx(com, esVersion);
		hxc.codegen.Codegen.mapSourceHeader(com, function(s) ctx.print("// " + s + "\n"));
		throw new TypingError("GenJS expression and declaration emitters are not ported yet", Position.nullPos);
	}
}
