package hxc.codegen;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals;
import hxc.context.Context;

// One tree builder supplies both @:rtti __rtti and --xml output.
private enum Xml {
	Node(name:String, att:Array<{a:String, v:String}>, childs:Array<Xml>);
	PCData(s:String);
	CData(s:String);
}

class GenXml {
	static inline function tag(name:String):Xml return Node(name, [], []);
	static inline function node(name:String, att:Array<{a:String, v:String}>, childs:Array<Xml>):Xml return Node(name, att, childs);

	static function genString(s:String):Xml {
		return (s.indexOf("<") >= 0 || s.indexOf(">") >= 0 || s.indexOf("&") >= 0) ? CData(s) : PCData(s);
	}

	static function genPath(path:Path):{a:String, v:String} {
		return {a: "path", v: path.pack.concat([path.name]).join(".")};
	}

	static function realPath(path:Path, meta:Metadata):Path {
		for (m in meta) if (m.name == ":realPath") switch (m.params.length > 0 ? m.params[0].expr : null) {
			case EConst(CString(s, _)):
				var parts = s.split(".");
				return {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
			case _:
		}
		return path;
	}

	static function tpath(t:ModuleType):Path {
		var i = TypeFunctions.tInfos(t);
		return realPath(i.path, i.meta);
	}

	static function followParam(t:T):T {
		return switch (t) {
			case TMono(r): r.type == null ? t : followParam(r.type);
			case TAbstract(a, [t1]) if (a.path.pack.length == 0 && a.path.name == "Null"): followParam(t1);
			case _: t;
		}
	}

	static function genDocOpt(doc:Documentation):Array<Xml> {
		var d = hxc.ast.Ast.genDocTextOpt(doc);
		if (d == null) return [];
		var s = StringTools.trim(d);
		s = s.split("\r\n").join("\n").split("\r").join("\n");
		return [node("haxe_doc", [], [genString(s)])];
	}

	static function genMeta(meta:Metadata):Array<Xml> {
		// Used/MaybeUsed/RealPath/Pure, and nothing else, so `:impl` reaches the output.
		var kept = [for (m in meta) if (m.name != ":used" && m.name != ":maybeUsed" && m.name != ":realPath" && m.name != ":pure" && m.name != ":hxcImpl") m];
		if (kept.length == 0) return [];
		var nodes = [for (m in kept)
			node("m", [{a: "n", v: m.name}], [for (e in m.params) node("e", [], [genString(hxc.ast.Ast.Printer.sExpr(e))])])];
		return [node("meta", [], nodes)];
	}

	static function genArgName(arg:TSignatureArg):String {
		return (arg.opt ? "?" : "") + arg.name;
	}

	public static function genType(t:T, ?values:haxe.ds.StringMap<Expr>):Xml {
		return switch (t) {
			case TMono(m): m.type == null ? tag("unknown") : genType(m.type);
			case TEnum(e, params): genTypeRef("e", TEnumDecl(e), params);
			case TInst(c, params): genTypeRef("c", TClassDecl(c), params);
			case TAbstract(a, params): genTypeRef("x", TAbstractDecl(a), params);
			case TType(td, params): genTypeRef("t", TTypeDecl(td), params);
			case TFun(sig):
				var names = [for (a in sig.args) genArgName(a)].join(":");
				var vatt:Array<{a:String, v:String}> = [];
				if (values != null) {
					var hasValue = false;
					var vs = [for (a in sig.args) {
						var e = values.get(a.name);
						if (e != null) { hasValue = true; hxc.ast.Ast.Printer.sExpr(e); } else "";
					}];
					if (hasValue) vatt = [{a: "v", v: vs.join(":")}];
				}
				var args = [for (a in sig.args) a.opt ? followParam(a.t) : a.t];
				node("f", [{a: "a", v: names}].concat(vatt), [for (x in args.concat([sig.ret])) genType(x)]);
			case TAnon(an):
				// Prepending in ascending key order produces descending field names.
				var names = [for (k in an.fields.keys()) k];
				names.sort(Reflect.compare);
				names.reverse();
				node("a", [], [for (n in names) {
					var f = TypeFunctions.copyField(an.fields.get(n));
					TypeFunctions.removeClassFieldFlag(f, CfPublic);
					genField([], f);
				}]);
			case TDynamic(null): node("d", [], []);
			case TDynamic(t2): node("d", [], [genType(t2)]);
			case TLazy(f): genType(TypeFunctions.lazyType(f));
		}
	}

	static function genTypeRef(n:String, t:ModuleType, pl:TParams):Xml {
		return node(n, [genPath(tpath(t))], [for (p in pl) genType(p)]);
	}

	static function genField(att:Array<{a:String, v:String}>, f:TClassField):Xml {
		function addGetSet(acc:VarAccess, name:String, att:Array<{a:String, v:String}>):Array<{a:String, v:String}> {
			return switch (acc) {
				case AccNormal | AccRequire(_, _) | AccCtor: att;
				case AccNo | AccNever: [{a: name, v: "null"}].concat(att);
				case AccCall: [{a: name, v: "accessor"}].concat(att);
				case AccInline: [{a: name, v: "inline"}].concat(att);
			}
		}
		if (f.expr != null) att = [{a: "line", v: Std.string(Position.lineNumber(f.expr.pos))}].concat(att);
		var values = new haxe.ds.StringMap<Expr>();
		switch (f.kind) {
			case Var(v):
				for (m in f.meta) if (m.name == ":value" && m.params.length == 1) {
					att = [{a: "expr", v: hxc.ast.Ast.Printer.sExpr(m.params[0])}].concat(att);
					break;
				}
				att = addGetSet(v.read, "get", addGetSet(v.write, "set", att));
			case Method(m):
				att = switch (m) {
					case MethNormal | MethMacro: [{a: "set", v: "method"}].concat(att);
					case MethDynamic: [{a: "set", v: "dynamic"}].concat(att);
					case MethInline: [{a: "get", v: "inline"}, {a: "set", v: "null"}].concat(att);
				}
				values = Ast.getValueMeta(f.meta);
		}
		if (f.params.length > 0)
			att = [{a: "params", v: [for (tp in f.params) TypeFunctions.extractParamName(tp)].join(":")}].concat(att);
		var overloads:Array<Xml> = f.overloads.length == 0 ? [] : [node("overloads", [], [for (o in f.overloads) genField([], o)])];
		var fieldName = f.name;
		for (m in f.meta) if (m.name == ":realPath") switch (m.params.length > 0 ? m.params[0].expr : null) {
			case EConst(CString(s, _)): fieldName = s;
			case _:
		}
		if (TypeFunctions.hasClassFieldFlag(f, CfPublic)) att = [{a: "public", v: "1"}].concat(att);
		if (TypeFunctions.hasClassFieldFlag(f, CfFinal)) att = [{a: "final", v: "1"}].concat(att);
		if (TypeFunctions.hasClassFieldFlag(f, CfAbstract)) att = [{a: "abstract", v: "1"}].concat(att);
		return node(fieldName, att, [genType(f.type, values)].concat(genMeta(f.meta)).concat(genDocOpt(f.doc)).concat(overloads));
	}

	static function genConstr(e:TEnumField):Xml {
		var doc = genDocOpt(e.doc);
		var att:Array<{a:String, v:String}> = [];
		var childs:Array<Xml> = doc;
		switch (TypeFunctions.follow(e.type)) {
			case TFun(sig):
				att = [{a: "a", v: [for (a in sig.args) genArgName(a)].join(":")}];
				childs = [for (a in sig.args) genType(a.opt ? followParam(a.t) : a.t)].concat(doc);
			case _:
		}
		return node(e.name, att, childs.concat(genMeta(e.meta)));
	}

	static function genTypeParams(ipos:Bool, priv:Bool, path:Path, params:TypeParams, pos:Position, m:ModuleDef):Array<{a:String, v:String}> {
		var att = [genPath(path), {a: "params", v: [for (tp in params) TypeFunctions.extractParamName(tp)].join(":")}];
		if (ipos && pos != Position.nullPos) att.push({a: "file", v: pos.file});
		if (priv) att.push({a: "private", v: "1"});
		if (!(m.path.pack.join(".") == path.pack.join(".") && m.path.name == path.name))
			att.push({a: "module", v: m.path.pack.concat([m.path.name]).join(".")});
		return att;
	}

	static function genClassPath(name:String, c:TClass, pl:TParams):Xml {
		return node(name, [{a: "path", v: Globals.sTypePath(tpath(TClassDecl(c)))}], [for (p in pl) genType(p)]);
	}

	static function existsIn(f:TClassField, c:TClass):Bool {
		if (c.fields.exists(f.name)) return true;
		return c.superClass != null && existsIn(f, c.superClass.c);
	}

	public static function genTypeDecl(com:Context, ipos:Bool, t:ModuleType):Xml {
		var m = TypeFunctions.tInfos(t).module;
		return switch (t) {
			case TClassDecl(c):
				// Exclude __init__: hxc retains it as a static field, but the RTTI model stores its body
				// separately.
				var stats = [for (cf in c.orderedStatics)
					if (cf.name != "__meta__" && cf.name != "__init__" && !TypeFunctions.hasMeta(":genericInstance", cf.meta) && !TypeFunctions.hasMeta(":noDoc", cf.meta))
						genField([{a: "static", v: "1"}], cf)];
				var fields = [for (cf in c.orderedFields)
					if (!TypeFunctions.hasMeta(":genericInstance", cf.meta) && !TypeFunctions.hasMeta(":noDoc", cf.meta))
						genField(c.superClass != null && existsIn(cf, c.superClass.c) ? [{a: "override", v: "1"}] : [], cf)];
				var constr = c.constructor == null ? [] : [genField([], c.constructor)];
				var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
				var impl = [for (i in c.interfaces) genClassPath(isInterface ? "extends" : "implements", i.c, i.params)];
				var tree = c.superClass == null ? impl : [genClassPath("extends", c.superClass.c, c.superClass.params)].concat(impl);
				var att = genTypeParams(ipos, c.isPrivate, tpath(t), c.params, c.pos, m);
				if (TypeFunctions.hasClassFlag(c, CExtern)) att.push({a: "extern", v: "1"});
				if (isInterface) att.push({a: "interface", v: "1"});
				if (TypeFunctions.hasClassFlag(c, CFinal)) att.push({a: "final", v: "1"});
				if (TypeFunctions.hasClassFlag(c, CAbstract)) att.push({a: "abstract", v: "1"});
				node("class", att, tree.concat(stats).concat(fields).concat(constr).concat(genDocOpt(c.doc)).concat(genMeta(c.meta)));
			case TEnumDecl(e):
				var constrs = [for (n in e.names) genConstr(e.constrs.get(n))];
				node("enum", genTypeParams(ipos, e.isPrivate, tpath(t), e.params, e.pos, m),
					constrs.concat(genDocOpt(e.doc)).concat(genMeta(e.meta)));
			case TTypeDecl(td):
				node("typedef", genTypeParams(ipos, td.isPrivate, td.path, td.params, td.pos, m),
					[genType(td.type)].concat(genDocOpt(td.doc)).concat(genMeta(td.meta)));
			case TAbstractDecl(a):
				function mkCast(t:T):Xml return node("icast", [], [genType(t)]);
				function mkFieldCast(t:T, cf:TClassField):Null<Xml>
					return TypeFunctions.hasMeta(":noDoc", cf.meta) ? null : node("icast", [{a: "field", v: cf.name}], [genType(t)]);
				function fieldCasts(l:Array<{t:T, cf:TClassField}>):Array<Xml> {
					var out:Array<Xml> = [];
					for (c in l) { var x = mkFieldCast(c.t, c.cf); if (x != null) out.push(x); }
					return out;
				}
				var sub:Array<Xml> = (a.from.length == 0 && a.fromField.length == 0) ? []
					: [node("from", [], [for (t1 in a.from) mkCast(t1)].concat(fieldCasts(a.fromField)))];
				var sup:Array<Xml> = (a.to.length == 0 && a.toField.length == 0) ? []
					: [node("to", [], [for (t1 in a.to) mkCast(t1)].concat(fieldCasts(a.toField)))];
				var impl:Array<Xml> = a.impl == null ? [] : [node("impl", [], [genTypeDecl(com, ipos, TClassDecl(a.impl))])];
				var thisNode = [node("this", [], [genType(a.thisType)])];
				node("abstract", genTypeParams(ipos, a.isPrivate, tpath(t), a.params, a.pos, m),
					sub.concat(thisNode).concat(sup).concat(genDocOpt(a.doc)).concat(genMeta(a.meta)).concat(impl));
		}
	}

	// Entity escaping: an `&` starting a `&#` character reference is kept as is.
	static function escapeEntities(s:String):String {
		var b:StringBuf = null;
		var start = 0;
		var l = s.length;
		for (p in 0...l) {
			var rep = switch (s.charCodeAt(p)) {
				case ">".code: "&gt;";
				case "<".code: "&lt;";
				case "&".code: p < l - 1 && s.charCodeAt(p + 1) == "#".code ? null : "&amp;";
				case "'".code: "&apos;";
				case "\"".code: "&quot;";
				case _: null;
			}
			if (rep != null) {
				if (b == null) b = new StringBuf();
				b.addSub(s, start, p - start);
				b.add(rep);
				start = p + 1;
			}
		}
		if (b == null) return s;
		b.addSub(s, start, l - start);
		return b.toString();
	}

	static function attStr(att:Array<{a:String, v:String}>):String {
		return [for (x in att) " " + x.a + "=\"" + escapeEntities(x.v) + "\""].join("");
	}

	static function writeXml(buf:StringBuf, tabs:String, x:Xml):Void {
		switch (x) {
			case Node(name, att, []):
				buf.add(tabs + "<" + name + attStr(att) + "/>");
			case Node(name, att, [one]):
				buf.add(tabs + "<" + name + attStr(att) + ">");
				writeXml(buf, "", one);
				buf.add("</" + name + ">");
			case Node(name, att, childs):
				buf.add(tabs + "<" + name + attStr(att) + ">\n");
				for (c in childs) {
					writeXml(buf, tabs + "\t", c);
					buf.add("\n");
				}
				buf.add(tabs + "</" + name + ">");
			case PCData(s):
				buf.add(s);
			case CData(s):
				buf.add("<![CDATA[" + s + "]]>");
		}
	}

	public static function genTypeString(com:Context, t:ModuleType):String {
		var x = genTypeDecl(com, false, t);
		var buf = new StringBuf();
		writeXml(buf, "", x);
		return buf.toString();
	}

	// Emit types without @:noDoc, including positions, under one haxe root.
	public static function generate(com:Context, file:String):Void {
		var decls = [for (t in com.types) if (!TypeFunctions.hasMeta(":noDoc", TypeFunctions.tInfos(t).meta)) genTypeDecl(com, true, t)];
		var buf = new StringBuf();
		buf.add("<!-- This file can be parsed by haxe.rtti.XmlParser -->\n");
		writeXml(buf, "", Node("haxe", [], decls));
		var dir = haxe.io.Path.directory(file);
		if (dir != "" && !sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent(file, buf.toString());
	}
}
