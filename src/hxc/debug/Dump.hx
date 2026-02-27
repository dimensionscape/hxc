package hxc.debug;

import hxc.context.Context;
import hxc.core.Type;
import hxc.core.Globals;
import hxc.core.TPrinting;
import hxc.core.TypeFunctions;
import hxc.ast.Ast;           
import sys.io.File;
import sys.FileSystem;

// The typed AST of every type (-D dump) and the module graph (-D dump-dependencies).
class Dump {
	// The main world and then the macro world, each by its own com.
	public static function run(ctx:Context):Void {
		var mcom = hxc.eval.EvalMacro.macroWorld();
		if (mcom == ctx) mcom = null;
		if (ctx.defines.rawDefined("dump")) {
			dumpTypesMode(ctx);
			if (mcom != null) dumpTypesMode(mcom);
		}
		if (ctx.defines.rawDefined("dump_dependencies")) {
			dumpDependencies(ctx, null);
			if (mcom != null) dumpDependencies(mcom, "macro");
		}
	}

	static function dumpTypesMode(ctx:Context):Void {
		switch (ctx.defines.rawDefinedValueSafe("dump", "")) {
			case "pretty": dumpTypes(ctx, function(st, e) return TPrinting.sExprPretty(false, "\t", true, st, e));
			case "legacy": dumpTypes(ctx, TPrinting.sExpr);
			case "record": dumpRecord(ctx);
			case "position": dumpPosition(ctx);
			case _:
				var printVarIds = !ctx.defines.rawDefined("dump_ignore_var_ids");
				dumpTypes(ctx, function(st, e) return TPrinting.sExprAst(printVarIds, "\t", st, e));
		}
	}

	static function platformNameMacro(ctx:Context):String {
		return ctx.defines.rawDefined("macro") ? "macro" : Globals.platformName(ctx.platform);
	}

	static function makeValidFilename(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			var ok = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code)
				|| c == "_".code || c == "-".code || c == ".".code || c == ",".code;
			if (ok) b.addChar(c) else b.add("_");
		}
		return b.toString();
	}

	// Every leading component is a directory made when missing, the last is the file name (made valid and
	// cut to fit) plus ".dump", opened in text mode, so a Windows host writes CRLF line ends.
	static function createDumpfile(l:Array<String>):{ buf:StringBuf, close:Void->Void } {
		var dir = "";
		for (i in 0...l.length - 1) {
			dir = i == 0 ? l[0] : dir + "/" + l[i];
			if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		}
		var d = makeValidFilename(l[l.length - 1]);
		var maxlen = 200 - ".dump".length;
		if (d.length > maxlen) d = d.substr(0, maxlen);
		var file = (l.length > 1 ? dir + "/" : "") + d + ".dump";
		var buf = new StringBuf();
		return { buf: buf, close: function() {
			var out = File.write(file, false);
			out.writeString(buf.toString());
			out.close();
		} };
	}

	static function createDumpfileFromPath(ctx:Context, path:Path):{ buf:StringBuf, close:Void->Void } {
		return createDumpfile([dumpPath(ctx), platformNameMacro(ctx)].concat(path.pack).concat([path.name]));
	}

	static function dumpPath(ctx:Context):String {
		return ctx.defines.rawDefinedValueSafe("dump_path", "dump");
	}

	static function sAccess(isRead:Bool, a:VarAccess):String {
		return switch (a) {
			case AccNormal: "default";
			case AccNo: "null";
			case AccNever: "never";
			case AccCall: isRead ? "get" : "set";
			case AccInline: "inline";
			case AccRequire(n, _): "require " + n;
			case AccCtor: "ctor";
		}
	}

	static function sMetas(ml:Metadata, tabs:String):String {
		if (ml.length == 0) return "";
		var parts = ml.map(function(me) {
			var args = me.params.length == 0 ? "" : "(" + me.params.map(Printer.sExpr).join(", ") + ")";
			return "@" + me.name + args;
		});
		return parts.join(" ") + "\n" + tabs;
	}

	static function sTypeParam(tp:TypedTypeParam):String {
		return switch (TypeFunctions.follow(tp.type)) {
			case TInst(c, _):
				switch (c.kind) {
					case KTypeParameter(tl1):
						var s = tl1.length == 0 ? tp.name : tp.name + ":" + tl1.map(TPrinting.sTypeStr).join(" & ");
						tp.defaultType == null ? s : s + " = " + TPrinting.sTypeStr(tp.defaultType);
					case _: Globals.die("", "not a type parameter");
				}
			case _: Globals.die("", "not a type parameter");
		}
	}

	static function params(tl:TypeParams):String {
		return tl.length == 0 ? "" : "<" + tl.map(sTypeParam).join(", ") + ">";
	}

	// One print context for the whole types walk.
	static function dumpTypes(ctx:Context, sExprWith:(T->String, TExpr)->String):Void {
		var pctx = TPrinting.printContext();
		var st = function(t:T) return TPrinting.sType(pctx, t);
		var sExpr = function(e:TExpr) return sExprWith(st, e);
		for (mt in ctx.types) {
			var path = TypeFunctions.tPath(mt);
			var df = createDumpfileFromPath(ctx, path);
			var buf = df.buf;
			switch (mt) {
				case TClassDecl(c):
					var isExtern = TypeFunctions.hasClassFlag(c, CExtern);
					var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
					function isInlineVar(k:FieldKind):Bool {
						return switch (k) { case Var(vk): vk.read == AccInline && vk.write == AccNever; case _: false; };
					}
					function printField(stat:Bool, f:TClassField):Void {
						var pub = (TypeFunctions.hasClassFieldFlag(f, CfPublic) && !(isExtern || isInterface)) ? "public " : "";
						var kindPrefix = switch (f.kind) {
							case Var(_) if (isInlineVar(f.kind)): "inline ";
							case Var(_): "";
							case Method(m): switch (m) { case MethNormal: ""; case MethDynamic: "dynamic "; case MethInline: "inline "; case MethMacro: "macro "; };
						};
						var keyword = switch (f.kind) { case Var(_): "var"; case Method(_): "function"; };
						var nameAcc = f.name + switch (f.kind) {
							case Var(vk) if (vk.read == AccNormal && vk.write == AccNormal): "";
							case Var(_) if (isInlineVar(f.kind)): "";
							case Var(vk): "(" + sAccess(true, vk.read) + "," + sAccess(false, vk.write) + ")";
							case _: "";
						};
						buf.add("\n\t" + sMetas(f.meta, "\t") + pub + (stat ? "static " : "") + kindPrefix + keyword + " " + nameAcc + params(f.params));
						switch (f.kind) {
							case Var(_):
								buf.add(":" + st(f.type) + (f.expr == null ? "" : " = " + sExpr(f.expr)) + ";");
							case Method(_):
								if (isExtern || isInterface) {
									switch (f.type) {
										case TFun(sig): buf.add("(" + sig.args.map(function(a) return a.name + ":" + st(a.t)).join(", ") + "):" + st(sig.ret) + ";");
										case _:
									}
								} else {
									buf.add(f.expr == null ? "" : sExpr(f.expr));
								}
						}
						buf.add("\n");
						for (o in f.overloads) printField(stat, o);
					}
					buf.add(sMetas(c.meta, "") + (c.isPrivate ? "private " : "") + (isExtern ? "extern " : "") + (isInterface ? "interface" : "class") + " " + Globals.sTypePath(path) + params(c.params));
					switch (c.superClass) { case null: case sup: buf.add(" extends " + st(TInst(sup.c, sup.params))); }
					for (i in c.interfaces) buf.add(" implements " + st(TInst(i.c, i.params)));
					switch (c.arrayAccess) { case null: case t: buf.add(" implements ArrayAccess<" + st(t) + ">"); }
					buf.add(" {\n");
					switch (c.constructor) { case null: case f: printField(false, f); }
					for (f in c.orderedFields) printField(false, f);
					for (f in c.orderedStatics) printField(true, f);
					switch (c.init) {
						case null:
						case e:
							buf.add("\n\tstatic function __init__() ");
							buf.add(sExpr(e));
							buf.add("\n");
					}
					buf.add("}");
				case TEnumDecl(e):
					buf.add(sMetas(e.meta, "") + (e.isPrivate ? "private " : "") + (e.isExtern ? "extern " : "") + "enum " + Globals.sTypePath(path) + params(e.params) + " {\n");
					for (n in e.names) {
						var f = e.constrs.get(n);
						var args = switch (f.type) {
							case TFun(sig): "(" + sig.args.map(function(a) return (a.opt ? "?" : "") + a.name + ":" + st(a.t)).join(", ") + ")";
							case _: "";
						};
						buf.add("\t" + f.name + args + ";\n");
					}
					buf.add("}");
				case TTypeDecl(t):
					buf.add(sMetas(t.meta, "") + (t.isPrivate ? "private " : "") + "typedef " + Globals.sTypePath(path) + params(t.params) + " = " + st(t.type));
				case TAbstractDecl(a):
					// String.concat " " over pieces that each start with a space.
					buf.add(sMetas(a.meta, "") + (a.isPrivate ? "private " : "") + "abstract " + Globals.sTypePath(path) + params(a.params)
						+ a.from.map(function(t) return " from " + st(t)).join(" ")
						+ a.to.map(function(t) return " to " + st(t)).join(" ") + " {}");
			}
			df.close();
		}
	}

	static function dumpRecord(ctx:Context):Void {
		for (mt in ctx.types) {
			var df = createDumpfileFromPath(ctx, TypeFunctions.tPath(mt));
			df.buf.add(switch (mt) {
				case TClassDecl(c): RecordPrinter.sTclass("", c);
				case TEnumDecl(en): RecordPrinter.sTenum("", en);
				case TTypeDecl(t): RecordPrinter.sTdef("", t);
				case TAbstractDecl(a): RecordPrinter.sTabstract("", a);
			});
			df.close();
		}
	}

	// Classes only, constructor then statics then fields.
	static function dumpPosition(ctx:Context):Void {
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c):
				var df = createDumpfileFromPath(ctx, TypeFunctions.tPath(mt));
				var buf = df.buf;
				buf.add(Globals.sTypePath(c.path) + "\n");
				function field(cf:TClassField):Void {
					buf.add("\t" + cf.name + "\n");
					if (cf.expr != null) buf.add(dumpWithPos("\t", cf.expr) + "\n");
				}
				if (c.constructor != null) field(c.constructor);
				for (cf in c.orderedStatics) field(cf);
				for (cf in c.orderedFields) field(cf);
				df.close();
			case _:
		}
	}

	// Right-aligned in four columns ("%4i").
	static function pad4(i:Int):String {
		var s = Std.string(i);
		while (s.length < 4) s = " " + s;
		return s;
	}

	public static function dumpWithPos(tabs:String, e:TExpr):String {
		var buf = new StringBuf();
		function loop_(tabs:String, e:TExpr):Void {
			var p = e.pos;
			function add(s:String) buf.add(pad4(p.min) + "-" + pad4(p.max) + " " + tabs + s + "\n");
			function loop(e:TExpr) loop_(tabs + "  ", e);
			switch (e.expr) {
				case TConst(ct): add(TPrinting.sConst(ct));
				case TLocal(v): add("TLocal " + v.name);
				case TTypeExpr(mt): add("TTypeExpr " + Globals.sTypePath(TypeFunctions.tPath(mt)));
				case TIdent(s): add("TIdent " + s);
				case TEnumParameter(e1, ef, _):
					add("TEnumParameter " + ef.name);
					loop(e1);
				case TEnumIndex(e1):
					add("TEnumIndex");
					loop(e1);
				case TArray(e1, e2):
					add("TArray");
					loop(e1);
					loop(e2);
				case TBinop(op, e1, e2):
					add("TBinop " + Ast.sBinop(op));
					loop(e1);
					loop(e2);
				case TField(e1, s):
					add("TField " + TypeFunctions.fieldName(s));
					loop(e1);
				case TParenthesis(e1):
					add("TParenthesis");
					loop(e1);
				case TObjectDecl(fl):
					add("TObjectDecl");
					for (f in fl) {
						buf.add(pad4(f.key.pos.min) + "-" + pad4(f.key.pos.max) + " " + tabs + f.key.name + "\n");
						loop(f.expr);
					}
				case TArrayDecl(el):
					add("TArrayDecl");
					for (x in el) loop(x);
				case TCall(e1, el):
					add("TCall");
					loop(e1);
					for (x in el) loop(x);
				case TNew(c, _, el):
					add("TNew " + Globals.sTypePath(c.path));
					for (x in el) loop(x);
				case TUnop(op, _, e1):
					add("TUnop " + Ast.sUnop(op));
					loop(e1);
				case TVarExpr(v, eo):
					add("TVar " + v.name);
					if (eo != null) loop_(tabs + "  ", eo);
				case TFunction(tf):
					add("TFunction");
					loop(tf.expr);
				case TBlock(el):
					add("TBlock");
					for (x in el) loop(x);
				case TFor(v, e1, e2):
					add("TFor " + v.name);
					loop(e1);
					loop(e2);
				case TIf(e1, e2, eo):
					add("TIf");
					loop(e1);
					loop(e2);
					if (eo != null) loop(eo);
				case TWhile(e1, e2, _):
					add("TWhile");
					loop(e1);
					loop(e2);
				case TSwitch(e1, cases, def):
					add("TSwitch");
					loop(e1);
					for (c in cases) {
						for (x in c.values) loop_(tabs + "    ", x);
						loop_(tabs + "      ", c.expr);
					}
					if (def != null) loop_(tabs + "      ", def);
				case TTry(e1, catches):
					add("TTry");
					loop(e1);
					for (c in catches) loop_(tabs + "    ", c.expr);
				case TReturn(eo):
					add("TReturn");
					if (eo != null) loop(eo);
				case TBreak:
					add("TBreak");
				case TContinue:
					add("TContinue");
				case TThrow(e1):
					add("EThrow");
					loop(e1);
				case TCast(e1, _):
					add("TCast");
					loop(e1);
				case TMeta(m, e1):
					add("TMeta " + m.name);
					loop(e1);
			}
		}
		loop_(tabs, e);
		return buf.toString();
	}

	// Modules in order, each module's deps in module id order, then every dependency file with the
	// modules that depend on it, in hash-table bucket order, each list newest first.
	static function dumpDependencies(ctx:Context, targetOverride:Null<String>):Void {
		var targetName = targetOverride == null ? platformNameMacro(ctx) : targetOverride;
		var df = createDumpfile([dumpPath(ctx), targetName, "dependencies"]);
		var buf = df.buf;
		var order = new hxc.core.NameHash.HashTableOrder();
		var dep = new haxe.ds.StringMap<Array<ModuleDef>>();
		for (m in modulesOf(ctx)) {
			buf.add(m.extra.file + ":\n");
			var ids = [for (id in m.extra.deps.keys()) id];
			ids.sort(function(a, b) return a < b ? -1 : a > b ? 1 : 0);
			for (id in ids) {
				var file = m.extra.deps.get(id).extra.file;
				buf.add("\t" + file + "\n");
				var l = dep.get(file);
				if (l == null) l = [];
				dep.set(file, [m].concat(l));
				order.add(file, hxc.core.NameHash.NameHash.stringHash(file));
			}
		}
		df.close();
		var df = createDumpfile([dumpPath(ctx), targetName, "dependants"]);
		var buf = df.buf;
		for (n in order.visitOrder()) {
			buf.add(n + ":\n");
			for (m in dep.get(n)) buf.add("\t" + m.extra.file + "\n");
		}
		df.close();
	}

	// The main world's module list is the finalization's sorted list (Finalization.run); the macro world's
	// is the same sort of its module lookup, assigned when the macro context is flushed.
	static function modulesOf(ctx:Context):Array<ModuleDef> {
		if (!ctx.defines.rawDefined("macro")) return ctx.modules;
		var l = [for (m in ctx.moduleLut) m];
		l.sort(function(m1, m2) return hxc.typing.Finalization.comparePath(m1.path, m2.path));
		return l;
	}
}

// The record printers -D dump=record writes.
class RecordPrinter {
	static function sType(t:T):String {
		return TPrinting.sType(TPrinting.printContext(), t);
	}

	static function sPos(p:hxc.ast.Position):String {
		return p.file + ": " + p.min + "-" + p.max;
	}

	static function sRecordFields(tabs:String, fields:Array<Array<String>>):String {
		var sl = [for (f in fields) f[0] + " = " + f[1] + ";"];
		return "{\n" + tabs + "\t" + sl.join("\n\t" + tabs) + "\n" + tabs + "}";
	}

	static function sList<A>(sep:String, f:A->String, l:Array<A>):String {
		return "[" + [for (x in l) f(x)].join(sep) + "]";
	}

	static function sOpt<A>(f:A->String, o:Null<A>):String {
		return o == null ? "None" : f(o);
	}

	static function sDoc(d:Documentation):String {
		return d == null ? "None" : Ast.genDocText(d);
	}

	static function sMetadataEntry(me:MetadataEntry):String {
		return "@" + me.name + (me.params.length == 0 ? "" : "(" + [for (e in me.params) Printer.sExpr(e)].join(", ") + ")");
	}

	static function sMetadata(ml:Metadata):String {
		return sList(" ", sMetadataEntry, ml);
	}

	static function sTypeParam(tp:TypedTypeParam):String {
		return switch (TypeFunctions.follow(tp.type)) {
			case TInst(c, _):
				switch (c.kind) {
					case KTypeParameter(tl1):
						var s = tl1.length == 0 ? tp.name : tp.name + ":" + tl1.map(sType).join(" & ");
						tp.defaultType == null ? s : s + " = " + sType(tp.defaultType);
					case _: Globals.die("", "not a type parameter");
				}
			case _: Globals.die("", "not a type parameter");
		}
	}

	static function sTypeParams(tl:TypeParams):String {
		return sList(", ", sTypeParam, tl);
	}

	// A name per set bit, prepended, so the highest bit comes first.
	static function sFlags(flags:Int, allFlags:Array<String>):String {
		var l:Array<String> = [];
		for (i in 0...allFlags.length) if (Flags.hasFlag(flags, i)) l.unshift(allFlags[i]);
		return l.join(" ");
	}

	static function sClassKind(k:TClassKind):String {
		return switch (k) {
			case KNormal: "KNormal";
			case KTypeParameter(tl): "KTypeParameter [" + TPrinting.sTypes(tl) + "]";
			case KExpr(_): "KExpr";
			case KGeneric: "KGeneric";
			case KGenericInstance(c, tl): "KGenericInstance " + Globals.sTypePath(c.path) + "<" + TPrinting.sTypes(tl) + ">";
			case KMacroType: "KMacroType";
			case KGenericBuild(_): "KGenericBuild";
			case KAbstractImpl(a): "KAbstractImpl " + Globals.sTypePath(a.path);
			case KModuleFields(m): "KModuleFields " + Globals.sTypePath(m.path);
		}
	}

	static function sBool(b:Bool):String return b ? "true" : "false";

	static function sExprAst(tabs:String):TExpr->String {
		return function(e) return TPrinting.sExprAst(true, tabs, sType, e);
	}

	public static function sTclassField(tabs:String, cf:TClassField):String {
		return sRecordFields(tabs, [
			["cf_name", cf.name],
			["cf_doc", sDoc(cf.doc)],
			["cf_type", TPrinting.sTypeKind(TypeFunctions.follow(cf.type))],
			["cf_pos", sPos(cf.pos)],
			["cf_name_pos", sPos(cf.namePos)],
			["cf_meta", sMetadata(cf.meta)],
			["cf_kind", TPrinting.sKind(cf.kind)],
			["cf_params", sTypeParams(cf.params)],
			["cf_expr", sOpt(sExprAst("\t\t"), cf.expr)],
			["cf_flags", sFlags(cf.flags, Flags.flagTClassFieldNames)],
		]);
	}

	public static function sTclass(tabs:String, c:TClass):String {
		return sRecordFields(tabs, [
			["cl_path", Globals.sTypePath(c.path)],
			["cl_module", Globals.sTypePath(c.module.path)],
			["cl_pos", sPos(c.pos)],
			["cl_name_pos", sPos(c.namePos)],
			["cl_private", sBool(c.isPrivate)],
			["cl_doc", sDoc(c.doc)],
			["cl_meta", sMetadata(c.meta)],
			["cl_params", sTypeParams(c.params)],
			["cl_kind", sClassKind(c.kind)],
			["cl_super", sOpt(function(s:TClassWithParams) return sType(TInst(s.c, s.params)), c.superClass)],
			["cl_implements", sList(", ", function(i:TClassWithParams) return sType(TInst(i.c, i.params)), c.interfaces)],
			["cl_array_access", sOpt(sType, c.arrayAccess)],
			["cl_init", sOpt(sExprAst(""), c.init)],
			["cl_constructor", sOpt(function(f) return sTclassField(tabs + "\t", f), c.constructor)],
			["cl_ordered_fields", sList("\n\t", function(f) return sTclassField(tabs + "\t", f), c.orderedFields)],
			["cl_ordered_statics", sList("\n\t", function(f) return sTclassField(tabs + "\t", f), c.orderedStatics)],
		]);
	}

	public static function sTdef(tabs:String, t:TDef):String {
		return sRecordFields(tabs, [
			["t_path", Globals.sTypePath(t.path)],
			["t_module", Globals.sTypePath(t.module.path)],
			["t_pos", sPos(t.pos)],
			["t_name_pos", sPos(t.namePos)],
			["t_private", sBool(t.isPrivate)],
			["t_doc", sDoc(t.doc)],
			["t_meta", sMetadata(t.meta)],
			["t_params", sTypeParams(t.params)],
			["t_type", TPrinting.sTypeKind(t.type)],
		]);
	}

	static function sTenumField(tabs:String, ef:TEnumField):String {
		return sRecordFields(tabs, [
			["ef_name", ef.name],
			["ef_doc", sDoc(ef.doc)],
			["ef_pos", sPos(ef.pos)],
			["ef_name_pos", sPos(ef.namePos)],
			["ef_type", TPrinting.sTypeKind(ef.type)],
			["ef_index", Std.string(ef.index)],
			["ef_params", sTypeParams(ef.params)],
			["ef_meta", sMetadata(ef.meta)],
		]);
	}

	public static function sTenum(tabs:String, en:TEnum):String {
		// The constructors in descending name order: an ascending visit that prepends each.
		var names = [for (n in en.constrs.keys()) n];
		names.sort(function(a, b) return a < b ? 1 : a > b ? -1 : 0);
		return sRecordFields(tabs, [
			["e_path", Globals.sTypePath(en.path)],
			["e_module", Globals.sTypePath(en.module.path)],
			["e_pos", sPos(en.pos)],
			["e_name_pos", sPos(en.namePos)],
			["e_private", sBool(en.isPrivate)],
			["d_doc", sDoc(en.doc)],
			["e_meta", sMetadata(en.meta)],
			["e_params", sTypeParams(en.params)],
			["e_type", sTdef("\t", en.type)],
			["e_extern", sBool(en.isExtern)],
			["e_constrs", sList("\n\t", function(n) return sTenumField(tabs + "\t", en.constrs.get(n)), names)],
			["e_names", en.names.join(", ")],
		]);
	}

	public static function sTabstract(tabs:String, a:TAbstract):String {
		return sRecordFields(tabs, [
			["a_path", Globals.sTypePath(a.path)],
			["a_modules", Globals.sTypePath(a.module.path)],
			["a_pos", sPos(a.pos)],
			["a_name_pos", sPos(a.namePos)],
			["a_private", sBool(a.isPrivate)],
			["a_doc", sDoc(a.doc)],
			["a_meta", sMetadata(a.meta)],
			["a_params", sTypeParams(a.params)],
			["a_ops", sList(", ", function(o:TAbstractOp) return Ast.sBinop(o.op) + ": " + o.cf.name, a.ops)],
			["a_unops", sList(", ", function(o:TAbstractUnop) return Ast.sUnop(o.op) + " (" + (o.flag.match(Postfix) ? "postfix" : "prefix") + "): " + o.cf.name, a.unops)],
			["a_impl", sOpt(function(c:TClass) return Globals.sTypePath(c.path), a.impl)],
			["a_this", TPrinting.sTypeKind(a.thisType)],
			["a_from", sList(", ", TPrinting.sTypeKind, a.from)],
			["a_to", sList(", ", TPrinting.sTypeKind, a.to)],
			["a_from_field", sList(", ", function(f:TAbstractCast) return TPrinting.sTypeKind(f.t) + ": " + f.cf.name, a.fromField)],
			["a_to_field", sList(", ", function(f:TAbstractCast) return TPrinting.sTypeKind(f.t) + ": " + f.cf.name, a.toField)],
			["a_array", sList(", ", function(cf:TClassField) return cf.name, a.array)],
			["a_read", sOpt(function(cf:TClassField) return cf.name, a.read)],
			["a_write", sOpt(function(cf:TClassField) return cf.name, a.write)],
		]);
	}
}
