package hxc.codegen.dotnet;

// One C# expression of inline C# (`untyped __cs__`, `cs.Syntax.code`), as CsSyntax.parse reads it. `pos`
// and `len` are offsets into the code string.
typedef CsExpr = {def:CsExprDef, pos:Int, len:Int}

enum CsExprDef {
	CPlaceholder(n:Int);
	CThis;
	// A simple name, verbatim `@` stripped.
	CIdent(name:String);
	// The segment after `global::`.
	CGlobal(name:String);
	// `int` in `int.MinValue`.
	CKeywordType(name:String);
	CMember(e:CsExpr, name:String);
	CCall(e:CsExpr, args:Array<CsExpr>);
	CIndex(e:CsExpr, args:Array<CsExpr>);
	CNew(t:CsType, args:Array<CsExpr>);
	CCast(t:CsType, e:CsExpr);
	CIs(e:CsExpr, t:CsType);
	CUnop(op:String, e:CsExpr);
	CBinop(op:String, a:CsExpr, b:CsExpr);
	CLiteral(l:CsLiteral);
	CParen(e:CsExpr);
}

enum CsType {
	CTKeyword(name:String);
	CTNamed(global:Bool, segments:Array<String>, args:Array<CsType>);
	CTArray(t:CsType);
}

// A literal as written: an integer or real keeps its text, suffix included, for CsToIl to type.
enum CsLiteral {
	LInt(text:String);
	LReal(text:String);
	LString(s:String);
	LChar(c:Int);
	LBool(b:Bool);
	LNull;
}

enum CsParse {
	PExpr(e:CsExpr);
	// `throw` or `throw;`.
	PThrow;
	// A construct outside the subset (csexpr §7): `what` names it, `replacement` says what to write instead.
	PRefused(what:String, replacement:String, pos:Int);
	// The text does not parse.
	PError(reason:String, pos:Int);
}

private enum CsToken {
	// A name or a keyword; `verbatim` for `@name`, which is never a keyword.
	TName(name:String, verbatim:Bool);
	TInt(text:String);
	TReal(text:String);
	TStr(s:String);
	TChr(c:Int);
	TPlaceholder(n:Int);
	// Punctuation and operators, longest match first; `>` is always one token, so `>>` is two.
	TPunct(p:String);
	TEof;
}

private typedef Tok = {t:CsToken, pos:Int, len:Int};

// Ends the parse with its result.
private class CsStop {
	public final result:CsParse;

	public function new(result:CsParse) {
		this.result = result;
	}
}

// A lexer and recursive-descent parser for the subset of C# inline C# may use (plan ruling 1): one
// expression, with C#'s precedence (unary, multiplicative, additive, relational with `is`, equality, `&&`,
// `||`), or a bare `throw`. The constructs outside the subset are recognized at their first token, so the
// refusal can name them and their replacement.
class CsSyntax {
	public static final keywordTypes = [
		"bool", "byte", "sbyte", "short", "ushort", "int", "uint", "long", "ulong", "char", "float", "double", "decimal", "string", "object"
	];

	static final keywords = [
		"abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked", "class", "const", "continue", "decimal",
		"default", "delegate", "do", "double", "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for",
		"foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace", "new", "null", "object",
		"operator", "out", "override", "params", "private", "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short",
		"sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong",
		"unchecked", "unsafe", "ushort", "using", "virtual", "void", "volatile", "while"
	];

	static final puncts = [
		"::", "??", "?.", "=>", "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", "->",
		"(", ")", "[", "]", "{", "}", ".", ",", ";", ":", "?", "=", "<", ">", "+", "-", "*", "/", "%", "!", "~", "&", "|", "^"
	];

	// Statement keywords, which start a statement rather than an expression.
	static final statementKeywords = [
		"if", "for", "foreach", "while", "do", "return", "var", "switch", "try", "lock", "using", "goto", "break", "continue", "const", "fixed"
	];

	final text:String;
	final placeholders:Bool;
	final toks:Array<Tok> = [];
	var i = 0;

	function new(text:String, placeholders:Bool) {
		this.text = text;
		this.placeholders = placeholders;
	}

	// Parses `text`; `placeholders` is false for cs.Syntax.plainCode, whose `{N}` is no placeholder.
	public static function parse(text:String, placeholders:Bool):CsParse {
		var p = new CsSyntax(text, placeholders);
		try {
			p.lex();
			return p.top();
		} catch (s:CsStop) {
			return s.result;
		}
	}

	// The `{N}` placeholders of `x`, in text order.
	public static function placeholdersOf(x:CsExpr):Array<CsExpr> {
		var r = [];
		function walk(x:CsExpr):Void {
			switch (x.def) {
				case CPlaceholder(_):
					r.push(x);
				case CMember(e1, _) | CCast(_, e1) | CIs(e1, _) | CUnop(_, e1) | CParen(e1):
					walk(e1);
				case CCall(e1, args) | CIndex(e1, args):
					walk(e1);
					for (a in args) walk(a);
				case CNew(_, args):
					for (a in args) walk(a);
				case CBinop(_, a, b):
					walk(a);
					walk(b);
				case CThis | CIdent(_) | CGlobal(_) | CKeywordType(_) | CLiteral(_):
			}
		}
		walk(x);
		return r;
	}

	static function refuse(what:String, replacement:String, pos:Int):Dynamic throw new CsStop(PRefused(what, replacement, pos));

	static function fail(reason:String, pos:Int):Dynamic throw new CsStop(PError(reason, pos));

	static function inHaxe(what:String, pos:Int):Dynamic return refuse(what, "write it in Haxe", pos);

	// ---- lexer

	inline function at(k:Int):Int return k < text.length ? StringTools.fastCodeAt(text, k) : -1;

	static inline function isDigit(c:Int):Bool return c >= "0".code && c <= "9".code;

	static inline function isHex(c:Int):Bool return isDigit(c) || c >= "a".code && c <= "f".code || c >= "A".code && c <= "F".code;

	static inline function isIdentStart(c:Int):Bool return c >= "a".code && c <= "z".code || c >= "A".code && c <= "Z".code || c == "_".code || c >= 0x80;

	static inline function isIdentPart(c:Int):Bool return isIdentStart(c) || isDigit(c);

	function lex():Void {
		var k = 0;
		while (true) {
			// Whitespace and comments.
			while (k < text.length) {
				var c = at(k);
				if (c == " ".code || c == "\t".code || c == "\r".code || c == "\n".code) {
					k++;
				} else if (c == "/".code && at(k + 1) == "/".code) {
					while (k < text.length && at(k) != "\n".code) k++;
				} else if (c == "/".code && at(k + 1) == "*".code) {
					var end = text.indexOf("*/", k + 2);
					if (end < 0) fail("the comment is not closed", k);
					k = end + 2;
				} else {
					break;
				}
			}
			if (k >= text.length) {
				toks.push({t: TEof, pos: k, len: 0});
				return;
			}
			var start = k, c = at(k);
			var t = if (c == "$".code || c == "@".code && at(k + 1) == "$".code) {
				inHaxe("an interpolated string", k);
			} else if (c == "@".code && at(k + 1) == "\"".code) {
				k = verbatimString(k + 2);
				TStr(lastString);
			} else if (c == "@".code && isIdentStart(at(k + 1))) {
				k++;
				while (isIdentPart(at(k))) k++;
				TName(text.substring(start + 1, k), true);
			} else if (isIdentStart(c)) {
				while (isIdentPart(at(k))) k++;
				TName(text.substring(start, k), false);
			} else if (isDigit(c) || c == ".".code && isDigit(at(k + 1))) {
				k = number(k);
				lastNumber;
			} else if (c == "\"".code) {
				k = regularString(k + 1);
				TStr(lastString);
			} else if (c == "'".code) {
				k = charLiteral(k + 1);
				TChr(lastChar);
			} else if (c == "{".code && placeholders && placeholderEnd(k) > 0) {
				var e = placeholderEnd(k);
				k = e + 1;
				TPlaceholder(Std.parseInt(text.substring(start + 1, e)));
			} else {
				var p = null;
				for (q in puncts) if (text.substr(k, q.length) == q) {
					p = q;
					break;
				}
				if (p == null) fail("unexpected `" + String.fromCharCode(c) + "`", k);
				k += p.length;
				TPunct(p);
			}
			toks.push({t: t, pos: start, len: k - start});
		}
	}

	// The offset of the `}` of a placeholder `{N}` at `k`, or -1.
	function placeholderEnd(k:Int):Int {
		var e = k + 1;
		while (isDigit(at(e))) e++;
		return e > k + 1 && at(e) == "}".code ? e : -1;
	}

	var lastString = "";
	var lastChar = 0;
	var lastNumber:CsToken = TEof;

	// A C# string literal's text may hold no placeholder: gencs would substitute the argument's source.
	function checkNoPlaceholder(s:String, pos:Int):Void {
		if (!placeholders) return;
		var k = s.indexOf("{");
		while (k >= 0) {
			var e = k + 1;
			while (e < s.length && isDigit(StringTools.fastCodeAt(s, e))) e++;
			if (e > k + 1 && e < s.length && StringTools.fastCodeAt(s, e) == "}".code)
				refuse("a placeholder inside a C# string literal", "build the string in Haxe", pos);
			k = s.indexOf("{", k + 1);
		}
	}

	// From after the opening `"` of `"..."`; returns the offset after the closing `"`.
	function regularString(k:Int):Int {
		var start = k - 1;
		var b = new StringBuf();
		while (true) {
			var c = at(k);
			if (c < 0 || c == "\n".code) fail("the string literal is not closed", start);
			k++;
			if (c == "\"".code) break;
			if (c == "\\".code) {
				k = escape(k, b);
			} else {
				b.addChar(c);
			}
		}
		lastString = b.toString();
		checkNoPlaceholder(lastString, start);
		return k;
	}

	// From after `@"`; `""` is a quote.
	function verbatimString(k:Int):Int {
		var start = k - 2;
		var b = new StringBuf();
		while (true) {
			var c = at(k);
			if (c < 0) fail("the string literal is not closed", start);
			k++;
			if (c == "\"".code) {
				if (at(k) != "\"".code) break;
				k++;
			}
			b.addChar(c);
		}
		lastString = b.toString();
		checkNoPlaceholder(lastString, start);
		return k;
	}

	// From after the opening `'`.
	function charLiteral(k:Int):Int {
		var start = k - 1;
		var b = new StringBuf();
		var c = at(k);
		if (c < 0 || c == "'".code || c == "\n".code) fail("the character literal is empty or not closed", start);
		k++;
		if (c == "\\".code) k = escape(k, b) else b.addChar(c);
		var s = b.toString();
		if (at(k) != "'".code || s.length != 1) fail("the character literal must hold one character", start);
		lastChar = StringTools.fastCodeAt(s, 0);
		return k + 1;
	}

	// A C# escape sequence, from after its `\`, added to `b`; returns the offset after it.
	function escape(k:Int, b:StringBuf):Int {
		var c = at(k);
		function hex(from:Int, min:Int, max:Int):Int {
			var e = from;
			while (e - from < max && isHex(at(e))) e++;
			if (e - from < min) fail("the escape sequence is malformed", k - 1);
			b.addChar(Std.parseInt("0x" + text.substring(from, e)));
			return e;
		}
		return switch (c) {
			case "'".code | "\"".code | "\\".code:
				b.addChar(c);
				k + 1;
			case "0".code: b.addChar(0); k + 1;
			case "a".code: b.addChar(7); k + 1;
			case "b".code: b.addChar(8); k + 1;
			case "f".code: b.addChar(12); k + 1;
			case "n".code: b.addChar(10); k + 1;
			case "r".code: b.addChar(13); k + 1;
			case "t".code: b.addChar(9); k + 1;
			case "v".code: b.addChar(11); k + 1;
			case "u".code: hex(k + 1, 4, 4);
			case "x".code: hex(k + 1, 1, 4);
			case _: fail("the escape sequence is not C#'s", k - 1);
		}
	}

	// An integer or real literal; sets lastNumber and returns the offset after it.
	function number(k:Int):Int {
		var start = k;
		if (at(k) == "0".code && (at(k + 1) == "x".code || at(k + 1) == "X".code)) {
			k += 2;
			while (isIdentPart(at(k))) k++;
			lastNumber = TInt(text.substring(start, k));
			return k;
		}
		var real = false;
		while (isDigit(at(k))) k++;
		if (at(k) == ".".code && isDigit(at(k + 1))) {
			real = true;
			k++;
			while (isDigit(at(k))) k++;
		}
		if (at(k) == "e".code || at(k) == "E".code) {
			real = true;
			k++;
			if (at(k) == "+".code || at(k) == "-".code) k++;
			if (!isDigit(at(k))) fail("the real literal's exponent has no digits", start);
			while (isDigit(at(k))) k++;
		}
		var suffixStart = k;
		while (isIdentPart(at(k))) k++;
		var suffix = text.substring(suffixStart, k).toLowerCase();
		if (suffix == "f" || suffix == "d" || suffix == "m") {
			real = true;
		} else if (real && suffix != "") {
			fail("the real literal's suffix `" + suffix + "` is not C#'s", start);
		}
		var s = text.substring(start, k);
		lastNumber = real ? TReal(s) : TInt(s);
		return k;
	}

	// ---- parser

	inline function peek(ahead = 0):Tok return toks[i + ahead < toks.length ? i + ahead : toks.length - 1];

	function isPunct(p:String, ahead = 0):Bool {
		return switch (peek(ahead).t) {
			case TPunct(q): q == p;
			case _: false;
		}
	}

	// Whether the token is the keyword `kw`, not a verbatim name.
	function isKeyword(kw:String, ahead = 0):Bool {
		return switch (peek(ahead).t) {
			case TName(n, false): n == kw;
			case _: false;
		}
	}

	function keywordAt(ahead = 0):Null<String> {
		return switch (peek(ahead).t) {
			case TName(n, false) if (keywords.indexOf(n) >= 0): n;
			case _: null;
		}
	}

	// A name that is not a keyword, or null.
	function nameAt(ahead = 0):Null<String> {
		return switch (peek(ahead).t) {
			case TName(n, true): n;
			case TName(n, false) if (keywords.indexOf(n) < 0): n;
			case _: null;
		}
	}

	function next():Tok {
		var t = peek();
		if (i < toks.length - 1) i++;
		return t;
	}

	function expect(p:String):Void {
		if (!isPunct(p)) unexpected();
		next();
	}

	function unexpected():Dynamic {
		var t = peek();
		return switch (t.t) {
			case TEof: fail("the expression ends early", t.pos);
			case _: fail("unexpected `" + text.substr(t.pos, t.len) + "`", t.pos);
		}
	}

	// The end offset of the last token taken.
	function lastEnd():Int {
		var t = toks[i > 0 ? i - 1 : 0];
		return t.pos + t.len;
	}

	function mk(def:CsExprDef, pos:Int):CsExpr return {def: def, pos: pos, len: lastEnd() - pos};

	function top():CsParse {
		if (isKeyword("throw")) {
			next();
			if (isPunct(";")) next();
			if (peek().t.match(TEof)) return PThrow;
			refuse("`throw` with a value", "use Haxe's throw (a bare `throw` or cs.Lib.rethrow(e) rethrows)", toks[0].pos);
		}
		if (startsStatement()) statements(peek().pos);
		var e = expr();
		switch (peek().t) {
			case TEof:
			case TPunct(";"): statements(peek().pos);
			case _: leftover();
		}
		return PExpr(e);
	}

	function statements(pos:Int):Dynamic return refuse("statements", "write statements in Haxe", pos);

	// A statement keyword or `{`, or a declaration: a type followed by a name.
	function startsStatement():Bool {
		var kw = keywordAt();
		if (kw != null && statementKeywords.indexOf(kw) >= 0) return true;
		if (isPunct("{")) return true;
		var save = i;
		var t = tryType();
		var decl = t != null && nameAt() != null;
		i = save;
		return decl;
	}

	// What follows a complete expression and is not part of the subset.
	function leftover():Dynamic {
		var t = peek();
		return switch (t.t) {
			case TPunct("=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|=" | "^=" | "++" | "--"):
				refuse("assignment", "write it in Haxe (a .NET indexer's setter is x.set_Item(a, b, value))", t.pos);
			case TPunct("=>"): refuse("a lambda", "write a Haxe function, which converts to the .NET delegate type", t.pos);
			case TPunct("?"): refuse("?:", "use Haxe's if expression", t.pos);
			case TPunct("??"): inHaxe("??", t.pos);
			case TPunct("?."): inHaxe("?.", t.pos);
			case TPunct("&" | "|" | "^" | "<<"): inHaxe("the " + text.substr(t.pos, t.len) + " operator", t.pos);
			case TPunct(">") if (isPunct(">", 1)): inHaxe("the >> operator", t.pos);
			case TName("as", false): refuse("`as`", "use Std.downcast(e, T)", t.pos);
			case _: unexpected();
		}
	}

	function expr():CsExpr {
		return orExpr();
	}

	function orExpr():CsExpr {
		var e = andExpr();
		while (isPunct("||")) {
			next();
			e = mk(CBinop("||", e, andExpr()), e.pos);
		}
		return e;
	}

	function andExpr():CsExpr {
		var e = equality();
		while (isPunct("&&")) {
			next();
			e = mk(CBinop("&&", e, equality()), e.pos);
		}
		return e;
	}

	function equality():CsExpr {
		var e = relational();
		while (isPunct("==") || isPunct("!=")) {
			var op = switch (next().t) {
				case TPunct(p): p;
				case _: throw "unreachable";
			}
			e = mk(CBinop(op, e, relational()), e.pos);
		}
		return e;
	}

	function relational():CsExpr {
		var e = additive();
		while (true) {
			if (isKeyword("is")) {
				next();
				var t = tryType();
				if (t == null) unexpected();
				e = mk(CIs(e, t), e.pos);
			} else if ((isPunct("<") || isPunct(">") || isPunct("<=") || isPunct(">=")) && !(isPunct(">") && isPunct(">", 1))) {
				var op = switch (next().t) {
					case TPunct(p): p;
					case _: throw "unreachable";
				}
				e = mk(CBinop(op, e, additive()), e.pos);
			} else {
				return e;
			}
		}
	}

	function additive():CsExpr {
		var e = multiplicative();
		while (isPunct("+") || isPunct("-")) {
			var op = isPunct("+") ? "+" : "-";
			next();
			e = mk(CBinop(op, e, multiplicative()), e.pos);
		}
		return e;
	}

	function multiplicative():CsExpr {
		var e = unary();
		while (isPunct("*") || isPunct("/") || isPunct("%")) {
			var op = switch (next().t) {
				case TPunct(p): p;
				case _: throw "unreachable";
			}
			e = mk(CBinop(op, e, unary()), e.pos);
		}
		return e;
	}

	function unary():CsExpr {
		var t = peek();
		switch (t.t) {
			case TPunct("!" | "-"):
				var op = isPunct("!") ? "!" : "-";
				next();
				return mk(CUnop(op, unary()), t.pos);
			case TPunct("++" | "--"):
				refuse("assignment", "write it in Haxe (a .NET indexer's setter is x.set_Item(a, b, value))", t.pos);
			case TPunct("+" | "~"):
				inHaxe("the unary " + text.substr(t.pos, t.len) + " operator", t.pos);
			case TPunct("&" | "*" | "->"):
				inHaxe("pointers", t.pos);
			case TPunct("("):
				var c = tryCast();
				if (c != null) return c;
			case _:
		}
		return postfix(primary());
	}

	// `(T)e`, by C#'s rule for telling it from a parenthesised expression: the parentheses hold a type, and
	// either that type is no expression (a keyword type, an array or generic type) or the token after `)`
	// starts an operand (a name, a keyword other than `as` and `is`, a literal, `(`, a placeholder, `!`, `~`).
	function tryCast():Null<CsExpr> {
		var start = peek().pos, save = i;
		next();
		var t = tryType();
		if (t == null || !isPunct(")")) {
			i = save;
			return null;
		}
		next();
		var notExpr = switch (t) {
			case CTKeyword(_) | CTArray(_): true;
			case CTNamed(_, _, args): args.length > 0;
		}
		var operand = switch (peek().t) {
			case TName(n, false): n != "as" && n != "is";
			case TName(_, true) | TInt(_) | TReal(_) | TStr(_) | TChr(_) | TPlaceholder(_): true;
			case TPunct("(" | "!" | "~"): true;
			case _: false;
		}
		if (!notExpr && !operand) {
			i = save;
			return null;
		}
		return mk(CCast(t, unary()), start);
	}

	// A type at the current token, taken, or null with nothing taken.
	function tryType(arrays = true):Null<CsType> {
		var save = i;
		var t = typeNoArray();
		if (t == null) {
			i = save;
			return null;
		}
		while (arrays && isPunct("[") && isPunct("]", 1)) {
			next();
			next();
			t = CTArray(t);
		}
		return t;
	}

	function typeNoArray():Null<CsType> {
		var kw = keywordAt();
		if (kw != null && keywordTypes.indexOf(kw) >= 0) {
			next();
			return CTKeyword(kw);
		}
		var global = false;
		if (isKeyword("global") && isPunct("::", 1)) {
			next();
			next();
			global = true;
		}
		var name = nameAt();
		if (name == null) return null;
		next();
		var segments = [name];
		while (isPunct(".") && nameAt(1) != null) {
			next();
			segments.push(nameAt());
			next();
		}
		var args = [];
		if (isPunct("<")) {
			args = typeArgs();
			if (args == null) return null;
		}
		return CTNamed(global, segments, args);
	}

	// `<T, U>`, taken, or null.
	function typeArgs():Null<Array<CsType>> {
		var save = i;
		next();
		var args = [];
		while (true) {
			var t = tryType();
			if (t == null) {
				i = save;
				return null;
			}
			args.push(t);
			if (isPunct(",")) {
				next();
				continue;
			}
			if (isPunct(">")) {
				next();
				return args;
			}
			i = save;
			return null;
		}
	}

	// C#'s rule for `name<...>`: type arguments when they parse and the token after `>` is one that can
	// follow them (`(`, `.` and the like), else `<` is less-than.
	function explicitTypeArgs():Bool {
		if (!isPunct("<")) return false;
		var save = i;
		var args = typeArgs();
		var follows = args != null && switch (peek().t) {
			case TPunct("(" | ")" | "]" | "}" | ":" | ";" | "," | "." | "?" | "==" | "!=" | "|" | "^" | "&&" | "||" | "&" | "["): true;
			case TEof: true;
			case _: false;
		}
		i = save;
		return follows;
	}

	function primary():CsExpr {
		var t = peek();
		switch (t.t) {
			case TInt(s):
				next();
				return mk(CLiteral(LInt(s)), t.pos);
			case TReal(s):
				next();
				return mk(CLiteral(LReal(s)), t.pos);
			case TStr(s):
				next();
				return mk(CLiteral(LString(s)), t.pos);
			case TChr(c):
				next();
				return mk(CLiteral(LChar(c)), t.pos);
			case TPlaceholder(n):
				next();
				return mk(CPlaceholder(n), t.pos);
			case TPunct("("):
				next();
				var e = expr();
				if (isPunct(",")) inHaxe("a tuple", peek().pos);
				expect(")");
				if (isPunct("=>")) leftover();
				return mk(CParen(e), t.pos);
			case TName(name, true):
				next();
				if (explicitTypeArgs()) typeArgsRefused(t.pos);
				return mk(CIdent(name), t.pos);
			case TName(name, false):
				return keywordOrName(name, t);
			case TPunct("{"):
				return statements(t.pos);
			case _:
				return unexpected();
		}
	}

	function typeArgsRefused(pos:Int):Dynamic return refuse("explicit type arguments", "call the method from Haxe", pos);

	function keywordOrName(name:String, t:Tok):CsExpr {
		switch (name) {
			case "true" | "false":
				next();
				return mk(CLiteral(LBool(name == "true")), t.pos);
			case "null":
				next();
				return mk(CLiteral(LNull), t.pos);
			case "this":
				next();
				return mk(CThis, t.pos);
			case "new":
				return newExpr(t);
			case "typeof":
				refuse("typeof", "use cs.Lib.toNativeType(T)", t.pos);
			case "default":
				inHaxe("default(T)", t.pos);
			case "ref" | "out":
				refuse("ref and out arguments", "call the method from Haxe with a cs.Ref<T> or cs.Out<T> argument", t.pos);
			case "checked" | "unchecked" | "sizeof" | "stackalloc" | "delegate" | "base":
				inHaxe(name, t.pos);
			case "throw":
				refuse("`throw` with a value", "use Haxe's throw (a bare `throw` or cs.Lib.rethrow(e) rethrows)", t.pos);
			case "global" if (isPunct("::", 1)):
				next();
				next();
				var n = nameAt();
				if (n == null) unexpected();
				next();
				return mk(CGlobal(n), t.pos);
			case _ if (keywordTypes.indexOf(name) >= 0):
				next();
				return mk(CKeywordType(name), t.pos);
			case "await" | "nameof":
				// Contextual keywords: names unless used as the operator.
				if (isPunct("(", 1) || nameAt(1) != null) inHaxe(name, t.pos);
			case _ if (keywords.indexOf(name) >= 0):
				fail("`" + name + "` is a C# keyword; write @" + name + " for the Haxe local", t.pos);
			case _:
		}
		next();
		if (explicitTypeArgs()) typeArgsRefused(t.pos);
		return mk(CIdent(name), t.pos);
	}

	// `new T(args)`; array creation and initializers are refused.
	function newExpr(t:Tok):CsExpr {
		next();
		var type = tryType(false);
		if (isPunct("[") || type == null && isPunct("[")) refuse("array creation", "use new cs.NativeArray<T>(n)", t.pos);
		if (type == null) unexpected();
		if (isPunct("{")) inHaxe("an object or collection initializer", peek().pos);
		if (!isPunct("(")) unexpected();
		var args = arguments(")");
		if (isPunct("{")) inHaxe("an object or collection initializer", peek().pos);
		return mk(CNew(type, args), t.pos);
	}

	// `(a, b)` or `[a, b]`, from its opening token.
	function arguments(close:String):Array<CsExpr> {
		next();
		var args = [];
		if (isPunct(close)) {
			next();
			return args;
		}
		while (true) {
			if (isKeyword("ref") || isKeyword("out") || isKeyword("in"))
				refuse("ref and out arguments", "call the method from Haxe with a cs.Ref<T> or cs.Out<T> argument", peek().pos);
			if (nameAt() != null && isPunct(":", 1)) inHaxe("a named argument", peek().pos);
			args.push(expr());
			if (isPunct(",")) {
				next();
				continue;
			}
			if (isPunct(close)) {
				next();
				return args;
			}
			leftover();
		}
	}

	function postfix(e:CsExpr):CsExpr {
		while (true) {
			var t = peek();
			switch (t.t) {
				case TPunct("."):
					next();
					var n = nameAt();
					if (n == null) {
						var kw = keywordAt();
						if (kw != null) fail("`" + kw + "` is a C# keyword; write @" + kw + " for the member", peek().pos);
						unexpected();
					}
					next();
					if (explicitTypeArgs()) typeArgsRefused(t.pos);
					e = mk(CMember(e, n), e.pos);
				case TPunct("("):
					e = mk(CCall(e, arguments(")")), e.pos);
				case TPunct("["):
					e = mk(CIndex(e, arguments("]")), e.pos);
				case TPunct("++" | "--"):
					refuse("assignment", "write it in Haxe (a .NET indexer's setter is x.set_Item(a, b, value))", t.pos);
				case TPunct("?."):
					inHaxe("?.", t.pos);
				case TPunct("->"):
					inHaxe("pointers", t.pos);
				case _:
					return e;
			}
		}
	}
}
