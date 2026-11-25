package hxc.codegen.dotnet;

import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;

// The compile's resources (-resource files and a macro's Context.addResource) as manifest resources, which
// std's haxe.Resource reads: each one is named "src.Resources." plus its name escaped as haxe.Resource
// escapes it at run time, and haxe.Resource.content lists the names, as gencs's static constructor does.

class ResourcesToIl {
	// haxe.io.Path.escape(name, true) as the .NET runtime runs it: per UTF-16 code unit, every one but
	// A-Z a-z 0-9 _ . / and \ becomes -x<decimal code unit>. gencs escapes the name's UTF-8 bytes instead
	// and keeps no \, so for a non-ASCII or backslash name its manifest name is not the one haxe.Resource
	// looks up; this one is.
	static function escape(name:String):String {
		var b = new StringBuf();
		for (i in 0...name.length) {
			var c = name.charCodeAt(i);
			var keep = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code)
				|| c == "_".code || c == ".".code || c == "/".code || c == "\\".code;
			if (keep) b.addChar(c) else b.add("-x" + c);
		}
		return b.toString();
	}

	public static function manifestName(name:String):String {
		return "src.Resources." + escape(name);
	}

	// A resource name for a message: quoted, with control characters as \x<two hex digits>.
	static function quote(name:String):String {
		var b = new StringBuf();
		b.add('"');
		var start = 0;
		function flush(end:Int) {
			if (end > start) b.add(name.substr(start, end - start));
		}
		for (i in 0...name.length) {
			var c = name.charCodeAt(i);
			var esc = switch (c) {
				case '"'.code: '\\"';
				case "\\".code: "\\\\";
				case "\n".code: "\\n";
				case "\r".code: "\\r";
				case "\t".code: "\\t";
				case _ if (c < 0x20 || c == 0x7F): "\\x" + StringTools.hex(c, 2).toLowerCase();
				case _: null;
			}
			if (esc != null) {
				flush(i);
				b.add(esc);
				start = i + 1;
			}
		}
		flush(name.length);
		b.add('"');
		return b.toString();
	}

	// haxe.Resource.content becomes the names in the reverse of resourceFoldOrder(), the order gencs lists
	// them in; an empty array when there are none, so listNames() works then too. The initializer gives the
	// class a .cctor, as gencs's `static Resource()`.
	public static function fillContent(ctx:Context):Void {
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (c.path.pack.length == 1 && c.path.pack[0] == "haxe" && c.path.name == "Resource"):
				var cf = c.statics.get("content");
				if (cf == null) return;
				var el = [];
				for (name in ctx.resourceFoldOrder()) el.unshift(TexprTools.makeString(ctx.basic, name, Position.nullPos));
				cf.expr = TypeFunctions.mk(TArrayDecl(el), cf.type, Position.nullPos);
				return;
			case _:
		}
	}

	// A ManifestResource row and blob entry per resource, in resourceFoldOrder() (the order hxcs passes
	// them to csc). Two names with one manifest name are an error: one would hide the other. A resource
	// has no source position (-resource is a command-line argument), so the error has none.
	public static function embed(g:DotnetCtx):Void {
		var ctx = g.ctx;
		var taken = new Map<String, String>();
		for (name in ctx.resourceFoldOrder()) {
			var manifest = manifestName(name);
			var other = taken.get(manifest);
			if (other != null) {
				g.error("the resources " + quote(other) + " and " + quote(name) + " would both be the manifest resource " + manifest,
					Position.nullPos);
				continue;
			}
			taken.set(manifest, name);
			g.mb.manifestResource(manifest, ctx.resources.get(name));
		}
	}

	// -D dotnet-trim-root: the descriptor ILLink reads from the assembly it is embedded in, by this exact name, and
	// strips from its output. It keeps every member, as the runtime's reflection reaches them by name. Opt-in, as
	// GetManifestResourceNames lists it in an untrimmed run, where gencs's assembly has only src.Resources.* names.
	public static function embedTrimRoot(g:DotnetCtx, assemblyName:String):Void {
		var name = StringTools.htmlEscape(assemblyName, true);
		var xml = '<linker>\n\t<assembly fullname="' + name + '" preserve="all" />\n</linker>\n';
		g.mb.manifestResource("ILLink.Descriptors.xml", haxe.io.Bytes.ofString(xml));
	}
}
