package hxc.compiler;

import hxc.context.Context;
import hxc.context.Context.CompilerDiagnostic;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Globals.MessageSeverity;

// Message formatters selected by -D message.reporting.
class Messages {
	static function epos(p:Position):String {
		return Globals.getErrorPosRef(function(file, line) return '$file:$line:', p);
	}

	static function isNullPos(p:Position):Bool {
		return p.min < 0;
	}

	static function isUnknownFile(f:String):Bool {
		return f == "" || f == "?";
	}

	static function repeat(s:String, n:Int):String {
		var b = new StringBuf();
		for (_ in 0...(n < 0 ? 0 : n)) b.add(s);
		return b.toString();
	}

	static function rmComplPrefix(s:String):String {
		return StringTools.startsWith(s, "... ") ? s.substr(4) : s;
	}

	public static function classicString(cm:CompilerDiagnostic):Null<String> {
		var str = switch (cm.severity) {
			case Warning: "Warning : " + cm.message;
			case _: cm.message;
		};
		if (isNullPos(cm.pos)) return str;
		var e = epos(cm.pos);
		var lines = str.split("\n");
		var parts = [lines[0]];
		for (i in 1...lines.length) parts.push("... " + lines[i]);
		return e + " : " + parts.join("\n" + e + " : ");
	}

	public static function indentedString(cm:CompilerDiagnostic):Null<String> {
		if (cm.message == "End of overload failure reasons") return null;
		var str = switch (cm.severity) {
			case Warning: "Warning : " + cm.message;
			case Information: "Info : " + cm.message;
			case _: cm.message;
		};
		if (isNullPos(cm.pos)) return str;
		var e = epos(cm.pos);
		var lines = str.split("\n");
		var out = [];
		for (i in 0...lines.length) {
			var depth = i == 0 ? cm.depth : cm.depth + 1;
			out.push(repeat(" ", depth * 2) + e + " : " + rmComplPrefix(lines[i]));
		}
		return out.join("\n");
	}

	// Return 1-based source lines with the pretty renderer's middle crop applied.
	static function resolveSource(file:String, l1:Int, l2:Int):Array<{n:Int, s:String}> {
		var content = try sys.io.File.getContent(file) catch (_:Dynamic) return [];
		var all = content.split("\n");
		var out = [];
		var i = l1;
		while (i <= l2 && i - 1 < all.length) {
			var line = all[i - 1];
			if (StringTools.endsWith(line, "\r")) line = line.substr(0, line.length - 1);
			out.push({n: i, s: line});
			i++;
		}
		if (out.length > 4) {
			var hd = out[0];
			var indent = 0;
			while (indent < hd.s.length - 1 && (hd.s.charCodeAt(indent) == " ".code || hd.s.charCodeAt(indent) == "\t".code)) indent++;
			out = [hd, {n: 0, s: repeat(" ", indent + 1) + "[...]"}, out[out.length - 1]];
		}
		return out;
	}

	public static function prettyString(ctx:Context, ectx:PrettyCtx, cm:CompilerDiagnostic):Null<String> {
		if (cm.message == "End of overload failure reasons") return null;
		ectx.lastPositions.set(cm.depth, cm.pos);
		var nullpos = isNullPos(cm.pos);

		var info = Position.getInfos(cm.pos);
		var l1 = info.line, p1 = info.column + 1, l2 = info.endLine, p2 = info.endColumn + 1;
		var e = nullpos ? (isUnknownFile(cm.pos.file) ? "(unknown position)" : cm.pos.file) : epos(cm.pos);
		var lines = nullpos ? [] : resolveSource(cm.pos.file, l1, l2);

		var parentPos = cm.depth == 0 ? Position.nullPos : (ectx.lastPositions.exists(cm.depth - 1) ? ectx.lastPositions.get(cm.depth - 1) : Position.nullPos);
		var prev = ectx.previous;
		var sevChanged = prev == null || cm.severity != prev.sev;
		var posChanged = (prev == null || !posEq(cm.pos, prev.pos) || (cm.depth != prev.depth && cm.depth != prev.depth + 1)) && (isNullPos(parentPos) || !posEq(cm.pos, parentPos));
		var fileChanged = prev == null || (posChanged && !((isUnknownFile(cm.pos.file) && isUnknownFile(prev.pos.file)) || cm.pos.file == prev.pos.file) && cm.pos.file != prev.pos.file);

		var displayHeading = cm.depth == 0 || sevChanged || fileChanged;
		var hasSource = lines.length > 0;
		var displaySource = hasSource && (cm.depth == 0 || sevChanged || posChanged);
		var displayPosMarker = (!nullpos) && hasSource && (cm.depth == 0 || sevChanged || posChanged);

		var maxLine = ectx.maxLines.exists(cm.depth) ? ectx.maxLines.get(cm.depth) : 0;
		var gutterLen = Std.string(maxLine).length + 2;

		var noColor = ctx.defines.rawDefined("message.no_color");
		var cReset = noColor ? "" : "\x1b[0m";
		var cBold = noColor ? "" : "\x1b[1m";
		var cDim = noColor ? "" : "\x1b[2m";
		var cSev = noColor ? "" : switch (cm.severity) {
			case Warning: "\x1b[33m";
			case Error: "\x1b[31m";
			case _: "\x1b[34m";
		};
		var cSevBg = noColor ? "" : switch (cm.severity) {
			case Warning: "\x1b[30;43m";
			case Error: "\x1b[30;41m";
			case _: "\x1b[30;44m";
		};
		var sevLabel = cm.depth > 0 ? " -> " : (noColor
			? "[" + sevName(cm.severity) + "]"
			: " " + sevName(cm.severity) + " ");

		var out = new StringBuf();
		if (displayHeading) out.add(cSevBg + sevLabel + cReset + " " + e + "\n\n");

		if (displaySource) {
			for (ln in lines) {
				var l = ln.n;
				var line = ln.s.split("\t").join(" ");
				var len = line.length;
				var nbLen = Std.string(l).length;
				var body = if (l == 0) {
					cDim + line + cReset;
				} else if (l1 == l2) {
					(p1 > 1 ? cDim + line.substr(0, p1 - 1) : "") + cReset + cBold + line.substr(p1 - 1, p2 - p1) + cReset + cDim + line.substr(p2 - 1, len - p2 + 1) + cReset;
				} else if (l == l1) {
					(p1 > 1 ? cDim + line.substr(0, p1 - 1) : "") + cReset + cBold + line.substr(p1 - 1, len - p1 + 1) + cReset;
				} else if (l == l2) {
					(p2 > 1 ? cBold + line.substr(0, p2 - 1) : "") + cReset + cDim + line.substr(p2 - 1, len - p2 + 1) + cReset;
				} else {
					cBold + line + cReset;
				}
				out.add(repeat(" ", gutterLen - nbLen - 1) + (l == 0 ? "-" : Std.string(l)) + " | " + body + "\n");
			}
		}

		if (displayPosMarker) {
			var marker = l1 == l2 ? repeat(" ", p1) + cSev + repeat("^", p1 == p2 ? 1 : p2 - p1) + cReset : "";
			out.add(repeat(" ", gutterLen) + "|" + marker + "\n");
		}

		for (s in cm.message.split("\n")) out.add(repeat(" ", gutterLen) + "| " + rmComplPrefix(s) + "\n");

		ectx.previous = {pos: nullpos ? Position.nullPos : cm.pos, sev: cm.severity, depth: cm.depth};
		ectx.gutter.set(cm.depth, gutterLen);

		var res = out.toString();
		if (cm.depth > 0) {
			var ind = 0;
			var d = cm.depth;
			while (d > 0) { ind += ectx.gutter.exists(d - 1) ? ectx.gutter.get(d - 1) : 3; d--; }
			var padded = [for (s in res.split("\n")) s == "" ? "" : repeat(" ", ind) + s];
			res = padded.join("\n");
		}
		return res;
	}

	static function posEq(a:Position, b:Position):Bool {
		return a.file == b.file && a.min == b.min && a.max == b.max;
	}

	static function sevName(sev:MessageSeverity):String {
		return switch (sev) {
			case Warning: "WARNING";
			case Information: "INFO";
			case Hint: "HINT";
			case Error: "ERROR";
		};
	}

	static function maxLines(msgs:Array<CompilerDiagnostic>):Map<Int, Int> {
		var m = new Map<Int, Int>();
		for (cm in msgs) {
			var l2 = Position.getInfos(cm.pos).endLine;
			var old = m.exists(cm.depth) ? m.get(cm.depth) : 0;
			if (l2 > old) m.set(cm.depth, l2);
		}
		return m;
	}

	public static function display(ctx:Context):Void {
		// Validate both screen and log formats, even when one will not be printed.
		var mode = validateMode(ctx, "message.reporting", "classic");
		validateMode(ctx, "message.log_format", "indent");
		var msgs = ctx.diagnostics;
		var ectx:PrettyCtx = {lastPositions: new Map(), previous: null, gutter: new Map(), maxLines: maxLines(msgs)};
		var buf = new StringBuf();
		for (cm in msgs) {
			var s = switch (mode) {
				case "pretty": prettyString(ctx, ectx, cm);
				case "indent": indentedString(cm);
				case _: classicString(cm);
			};
			if (s != null) buf.add(s + "\n");
		}
		Sys.stderr().writeString(buf.toString());
	}

	// Report an unknown mode using its canonical define key, then use the default.
	static function validateMode(ctx:Context, key:String, def:String):String {
		var mode = ctx.defines.rawDefinedValueSafe(key, def);
		if (mode != "pretty" && mode != "indent" && mode != "classic") {
			ctx.addDiagnostic('Invalid message reporting mode: "$mode", expected classic | pretty | indent (for -D $key).', Position.nullPos);
			return def;
		}
		return mode;
	}
}

typedef PrettyCtx = {
	var lastPositions:Map<Int, Position>;
	var previous:Null<{pos:Position, sev:MessageSeverity, depth:Int}>;
	var gutter:Map<Int, Int>;
	var maxLines:Map<Int, Int>;
};
