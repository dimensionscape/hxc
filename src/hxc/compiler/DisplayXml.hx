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
	// Capture sort keys when building an item; printing no longer has its declaration context.
	?sortGroup:Int,
	?sortKey:String,
	?sortType:hxc.core.Type.T,
	// Keep a type parameter in new-completion only when its constraints permit construction.
	?tparam:hxc.core.Type.TClass,
}

// Syntax keyword answers use their own printer and concatenate items without separators.
class SyntaxCompletion {
	public final keywords:Array<String>;
	// JSON reports the subject as filterString and replaceRange; XML omits it.
	public var subjectName:Null<String>;
	public var subjectPos:Null<hxc.ast.Position>;

	public function new(keywords:Array<String>, ?subjectName:String, ?subjectPos:hxc.ast.Position) {
		this.keywords = keywords;
		this.subjectName = subjectName;
		this.subjectPos = subjectPos;
	}
}

class ToplevelCompletion {
	public final items:Array<ToplevelItem>;
	// Both formats share the collection; retain module types for JSON as well as the strings XML
	// needs.
	public var moduleTypes:Null<Array<hxc.core.Type.ModuleType>>;
	public var kind:Int = 2;
	public var subjectPos:Null<hxc.ast.Position>;
	public var subjectName:Null<String>;

	public function new(items:Array<ToplevelItem>, ?moduleTypes:Array<hxc.core.Type.ModuleType>) {
		this.items = items;
		this.moduleTypes = moduleTypes;
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

	public static function printKeywords(kwds:Array<String>):String {
		var b = new StringBuf();
		b.add("<il>\n");
		for (k in kwds) b.add('<i k="keyword">' + k + "</i>");
		b.add("</il>");
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

	// Absolutize file names only while printing; changing position keys would make unsaved buffers use
	// the disk file's line index.
	static function fullPathPrinter(file:String, line:Int):String {
		var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
		return '$full:$line:';
	}

	public static function printPositions(positions:Array<hxc.ast.Position>):String {
		var b = new StringBuf();
		b.add("<list>\n");
		for (p in positions)
			b.add("<pos>" + hxc.core.Globals.getErrorPosRef(fullPathPrinter, p) + "</pos>\n");
		b.add("</list>");
		return b.toString();
	}

	// Print the full path in p; omit p for a null position.
	public static function printType(t:String, p:hxc.ast.Position, ?doc:String):String {
		var head = if (p == null || p.min == -1) {
			"<type";
		} else {
			'<type p="' + htmlescape(hxc.core.Globals.getErrorPosRef(fullPathPrinter, p)) + '"';
		}
		if (doc != null) head += ' d="' + htmlescape(doc) + '"';
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
