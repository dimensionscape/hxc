package hxc.codegen;


import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.NotFound;
import hxc.context.Context;

class Codegen {
	public static function hasProperties(c:TClass):Bool {
		for (f in c.orderedFields) {
			switch (f.kind) {
				case Var(k) if (k.read.match(AccCall)): return true;
				case Var(k) if (k.write.match(AccCall)): return true;
				case _:
					if (TypeFunctions.hasMeta(":accessor", f.meta)) return true;
			}
		}
		return c.superClass != null && hasProperties(c.superClass.c);
	}

	// Prepending reverses field order and places each setter before its getter.
	public static function getProperties(fields:Array<TClassField>):Array<{name:String, value:String}> {
		var acc:Array<{name:String, value:String}> = [];
		for (f in fields) {
			if (TypeFunctions.hasMeta(":accessor", f.meta)) {
				acc.unshift({name: f.name, value: f.name});
			} else {
				switch (f.kind) {
					case Var(k) if (k.read.match(AccCall)): acc.unshift({name: "get_" + f.name, value: "get_" + f.name});
					case _:
				}
				switch (f.kind) {
					case Var(k) if (k.write.match(AccCall)): acc.unshift({name: "set_" + f.name, value: "set_" + f.name});
					case _:
				}
			}
		}
		return acc;
	}

	// Base64 with the standard table and no '=' padding.
	public static function bytesSerialize(data:haxe.io.Bytes):String {
		return haxe.crypto.Base64.encode(data, false);
	}

	public static function mapSourceHeader(ctx:Context, f:String->Void):Void {
		var s = ctx.defines.rawDefinedValueSafe("source_header", "");
		if (s != "") f(s);
	}

	// Double braces escape a brace. An integer {N} inserts expression N; out-of-range indices fail and
	// other braces remain literal.
	public static function interpolateCode(ctx:Context, code:String, tl:Array<TExpr>, fString:String->Void, fExpr:TExpr->Void, p:Position):Void {
		var i = 0;
		function err(msg:String) {
			ctx.addDiagnostic(msg, new Position(p.file, p.min + i, p.max));
		}
		// Split into alternating text and single-brace tokens.
		var toks:Array<{delim:Bool, s:String}> = [];
		var start = 0;
		for (k in 0...code.length) {
			var ch = code.charAt(k);
			if (ch == "{" || ch == "}") {
				if (k > start) toks.push({delim: false, s: code.substring(start, k)});
				toks.push({delim: true, s: ch});
				start = k + 1;
			}
		}
		if (start < code.length) toks.push({delim: false, s: code.substring(start)});
		// Integer parsing: optional sign, decimal or 0x hex, '_' separators allowed
		function parseIntOf(s:String):Null<Int> {
			s = StringTools.replace(s, "_", "");
			if (s.length == 0) return null;
			var neg = false;
			var j = 0;
			if (s.charAt(0) == "-" || s.charAt(0) == "+") { neg = s.charAt(0) == "-"; j = 1; }
			if (j >= s.length) return null;
			var body = s.substr(j);
			var v:Null<Int>;
			if (body.length > 2 && body.charAt(0) == "0" && (body.charAt(1) == "x" || body.charAt(1) == "X")) {
				for (k in 2...body.length) {
					var c = body.toLowerCase().charCodeAt(k);
					if (!((c >= "0".code && c <= "9".code) || (c >= "a".code && c <= "f".code))) return null;
				}
				v = Std.parseInt(body);
			} else {
				for (k in 0...body.length) {
					var c = body.charCodeAt(k);
					if (c < "0".code || c > "9".code) return null;
				}
				v = Std.parseInt(body);
			}
			return v == null ? null : (neg ? -v : v);
		}
		var t = 0;
		while (t < toks.length) {
			var a = toks[t];
			if (!a.delim) {
				i += a.s.length;
				fString(a.s);
				t++;
			} else if (t + 1 < toks.length && toks[t + 1].delim && toks[t + 1].s == a.s) {
				i += 2;
				fString(a.s);
				t += 2;
			} else if (a.s == "{" && t + 2 < toks.length && !toks[t + 1].delim && toks[t + 2].delim && toks[t + 2].s == "}") {
				var n = toks[t + 1].s;
				var idx = parseIntOf(n);
				if (idx == null) {
					fString("{" + n + "}");
				} else if (idx < 0 || idx >= tl.length) {
					err("Out-of-bounds special parameter: " + n);
				} else {
					fExpr(tl[idx]);
				}
				i += 2 + n.length;
				t += 3;
			} else {
				fString(a.s);
				i++;
				t++;
			}
		}
	}

	// Return the first single-argument @:native entry, or null. A non-string argument is an error.
	public static function getNativeName(ctx:Context, meta:Metadata):Null<{name:String, pos:Position}> {
		var found:Null<MetadataEntry> = null;
		for (m in meta) {
			if (m.name == ":native" && m.params.length == 1) { found = m; break; }
		}
		if (found == null) return null;
		switch (found.params[0].expr) {
			case EConst(CString(name, _)):
				return {name: name, pos: found.params[0].pos};
			case _:
				throw new hxc.core.TypingError("String expected", found.pos);
		}
	}
}
