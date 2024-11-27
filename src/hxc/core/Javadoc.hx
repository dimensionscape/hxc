package hxc.core;

// hxc.core.Javadoc: a documentation block's `@tag value` lines. A tag starts at the first non-whitespace
// character of a line (a leading `*` is skipped), its value runs to the end of that line, and any following
// line INDENTED FURTHER than the tag continues it.
class Javadoc {
	var doc:String;
	var params:Map<String, String> = null;

	public function new(doc:String) {
		this.doc = doc;
	}

	public function getParamInfo(name:String):Null<String> {
		if (params == null) parseTags();
		return params.exists(name) ? params.get(name) : null;
	}

	// The first non-whitespace character of a line, with its indentation. A single leading `*` is part of
	// the comment frame, not the content.
	function nextLineStart(p:Int):Null<{c:String, p:Int, indent:Int}> {
		var l = doc.length;
		var hadStar = false;
		var indent = 0;
		while (true) {
			if (p >= l) return null;
			var c = doc.charAt(p);
			if (c == " " || c == "\t") { indent++; p++; }
			else if (c == "*" && !hadStar) { hadStar = true; indent = 0; p++; }
			else if (c == "\r" || c == "\n") { hadStar = false; indent = 0; p++; }
			else return {c: c, p: p + 1, indent: indent};
		}
	}

	// (position of the last real character, position of the next one), so trailing whitespace never reaches
	// the value.
	function lastCharPosOnLine(p:Int):{pl:Int, pn:Int} {
		var l = doc.length;
		var pl = p, pn = p;
		while (true) {
			if (pn == l) return {pl: pl, pn: pn};
			var c = doc.charAt(pn);
			if (c == " " || c == "\r" || c == "\t") pn++;
			else if (c == "\n") return {pl: pl, pn: pn + 1};
			else { pl = pn; pn++; }
		}
	}

	// Only the `param` tag is consumed here; its value separates at the first space into the parameter
	// name and its documentation.
	function parseTags():Void {
		params = new Map();
		var l = doc.length;
		var p = 0;
		while (true) {
			var nl = nextLineStart(p);
			if (nl == null) return;
			if (nl.c != "@") {
				var lc = lastCharPosOnLine(nl.p);
				p = lc.pn;
				continue;
			}
			var sp = doc.indexOf(" ", nl.p);
			if (sp < 0) return;
			var tag = doc.substring(nl.p, sp);
			var value = new StringBuf();
			var ps = sp + 1;
			while (true) {
				var lc = lastCharPosOnLine(ps);
				value.add(doc.substring(ps, lc.pl + 1));
				var nl2 = nextLineStart(lc.pn);
				if (nl2 != null && nl2.indent > nl.indent) {
					value.add("\n");
					value.add(nl2.c);
					ps = nl2.p;
				} else {
					p = lc.pn;
					break;
				}
			}
			if (tag == "param") {
				var v = value.toString();
				var sep = v.indexOf(" ");
				if (sep >= 0) params.set(v.substring(0, sep), v.substring(sep + 1));
				else params.set(v, "");
			}
		}
	}
}
