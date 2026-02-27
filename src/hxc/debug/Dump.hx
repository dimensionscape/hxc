package hxc.debug;

import hxc.context.Context;
import hxc.core.Type;
import hxc.core.Globals;
import hxc.core.TPrinting;
import hxc.core.TypeFunctions;
import hxc.ast.Ast;           
import sys.io.File;
import sys.FileSystem;

// Typed-AST dump (reference: Dump). Only the pretty mode is wired: legacy and ast embed var ids that differ
// between compilers, so they cannot diff.
class Dump {
	public static function run(ctx:Context):Void {
		if (!ctx.defines.rawDefined("dump")) return;
		if (ctx.defines.rawDefinedValueSafe("dump", "") != "pretty") return;
		dumpTypes(ctx);
	}

	static function dumpFile(ctx:Context, path:Path):{ buf:StringBuf, close:Void->Void } {
		var dir = ctx.defines.rawDefinedValueSafe("dump_path", "dump") + "/" + Globals.platformName(ctx.platform);
		for (p in path.pack) dir += "/" + p;
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		var file = dir + "/" + path.name + ".dump";
		var buf = new StringBuf();
		// The dump is opened in text mode (open_out), so a Windows host writes CRLF line ends.
		return { buf: buf, close: function() {
			var out = File.write(file, false);
			out.writeString(buf.toString());
			out.close();
		} };
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
					case _: tp.name;
				}
			case _: tp.name;
		}
	}

	static function params(tl:TypeParams):String {
		return tl.length == 0 ? "" : "<" + tl.map(sTypeParam).join(", ") + ">";
	}

	static function dumpTypes(ctx:Context):Void {
		for (mt in ctx.types) {
			var path = TypeFunctions.tPath(mt);
			var df = dumpFile(ctx, path);
			var buf = df.buf;
			var pctx = TPrinting.printContext();
			var st = function(t:T) return TPrinting.sType(pctx, t);
			var sExpr = function(e:TExpr) return TPrinting.sExprPretty(false, "\t", true, st, e);
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
					buf.add(sMetas(a.meta, "") + (a.isPrivate ? "private " : "") + "abstract " + Globals.sTypePath(path) + params(a.params)
						+ a.from.map(function(t) return " from " + st(t)).join("")
						+ a.to.map(function(t) return " to " + st(t)).join("") + " {}");
			}
			df.close();
		}
	}
}
