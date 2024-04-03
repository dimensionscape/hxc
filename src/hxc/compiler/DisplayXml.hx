package hxc.compiler;


typedef DisplayField = {
	// Protocol k values include var, method, type, package, local, literal, keyword, metadata and
	// timer. Modules print as type but have a separate sort order.
	kind:String,
	name:String,
	type:String,
	doc:Null<String>,
	?sort:Int,
}

class DisplayPositions {
	public final positions:Array<hxc.ast.Position>;

	public function new(positions:Array<hxc.ast.Position>) {
		this.positions = positions;
	}
}

// Completion kind values include local, member, static, enum, enumabstract, type, package and
// literal. type, path and doc fill the t, p and d attributes.
typedef ToplevelItem = {
	kind:String,
	name:String,
	?type:String,
	?path:String,
	?doc:String,
}

class ToplevelCompletion {
	public final items:Array<ToplevelItem>;

	public function new(items:Array<ToplevelItem>) {
		this.items = items;
	}
}

class DisplayXml {
	public static function htmlescape(s:String):String {
		s = StringTools.replace(s, "&", "&amp;");
		s = StringTools.replace(s, "<", "&lt;");
		s = StringTools.replace(s, ">", "&gt;");
		s = StringTools.replace(s, "\"", "&quot;");
		return s;
	}

	// Sort by kind priority and name, then emit i elements inside list.
	public static function printFields(fields:Array<DisplayField>):String {
		var b = new StringBuf();
		b.add("<list>\n");
		var sorted = fields.copy();
		sorted.sort(function(a, c) {
			var ka = legacySort(a), kc = legacySort(c);
			if (ka != kc) return ka - kc;
			return a.name < c.name ? -1 : (a.name > c.name ? 1 : 0);
		});
		for (f in sorted) {
			var d = f.doc == null ? "" : f.doc;
			b.add('<i n="' + f.name + '" k="' + f.kind + '"><t>' + htmlescape(f.type) + "</t><d>" + htmlescape(d) + "</d></i>\n");
		}
		b.add("</list>\n");
		return b.toString();
	}

	// Preserve collection order. Deduplicate value identifiers, retain types and packages, and omit
	// keywords and metadata from legacy output.
	public static function printToplevel(items:Array<ToplevelItem>):String {
		var b = new StringBuf();
		b.add("<il>\n");
		var seen = new haxe.ds.StringMap<Bool>();
		inline function checkIdent(s:String):Bool {
			return if (seen.exists(s)) false else { seen.set(s, true); true; }
		}
		inline function sDoc(d:Null<String>):String {
			return d == null ? "" : ' d="' + htmlescape(d) + '"';
		}
		for (it in items) switch (it.kind) {
			case "local" | "member" | "static" | "enum" | "enumabstract":
				if (checkIdent(it.name))
					b.add('<i k="' + it.kind + '" t="' + htmlescape(it.type == null ? "" : it.type) + '"' + sDoc(it.doc) + ">" + it.name + "</i>\n");
			case "type":
				b.add('<i k="type" p="' + htmlescape(it.path == null ? it.name : it.path) + '"' + ">" + it.name + "</i>\n");
			case "package":
				b.add('<i k="package">' + it.name + "</i>\n");
			case "literal":
				b.add('<i k="literal">' + it.name + "</i>\n");
			case _:
		}
		b.add("</il>");
		return b.toString();
	}

	// <pos>file:line: characters a-b</pos> per position, with the real (absolute) file path and no newline
	// after the closing tag.
	public static function printPositions(positions:Array<hxc.ast.Position>):String {
		var b = new StringBuf();
		b.add("<list>\n");
		for (p in positions) {
			var full = try sys.FileSystem.fullPath(p.file) catch (_:Dynamic) p.file;
			var ap = new hxc.ast.Position(full, p.min, p.max);
			b.add("<pos>" + hxc.core.Globals.getErrorPosRef(function(file, line) return '$file:$line:', ap) + "</pos>\n");
		}
		b.add("</list>");
		return b.toString();
	}

	// Print the full path in p; omit p for a null position.
	public static function printType(t:String, p:hxc.ast.Position):String {
		var head = if (p == null || p.min == -1) {
			"<type";
		} else {
			var full = try sys.FileSystem.fullPath(p.file) catch (_:Dynamic) p.file;
			var ap = new hxc.ast.Position(full, p.min, p.max);
			'<type p="' + htmlescape(hxc.core.Globals.getErrorPosRef(function(file, line) return '$file:$line:', ap)) + '"';
		}
		return head + ">\n" + htmlescape(t) + "\n</type>\n";
	}

	static function legacySort(f:DisplayField):Int {
		if (f.sort != null) return f.sort;
		return switch (f.kind) {
			case "var": 0;
			case "method": 1;
			case "type": 2;
			case "package": 4;
			case "metadata": 5;
			case "timer": 6;
			case "local": 7;
			case "literal": 9;
			case "keyword": 10;
			case _: 11;
		};
	}
}
