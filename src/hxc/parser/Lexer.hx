package hxc.parser;

import hxc.ast.Ast;
import hxc.ast.Ast.Token;
import hxc.ast.Ast.Constant;
import hxc.ast.Ast.StringLiteralKind;
import hxc.ast.Position;
import hxc.ast.Ast.InvalidEscapeSequence;

class Lexer {
	final src:String;
	final file:String;
	var pos:Int;
	final len:Int;

	public function new(src:String, file:String) {
		this.src = src;
		this.file = file;
		this.pos = 0;
		this.len = src.length;
		skipHeader();
	}

	/** Current byte offset of the lexer cursor. */
	public inline function offset():Int
		return pos;

	// Source positions count UNICODE CODE POINTS, while a Haxe string indexes UTF-16 code units, so an
	// astral character counts twice here; without conversion every position after it is one too far right.
	// Convert at the single construction point; a source with no astral character (the overwhelming
	// majority) resolves to the identity after one scan.
	var hiSurrogates:Null<Array<Int>> = null;

	function scanSurrogates():Array<Int> {
		var a:Array<Int> = [];
		var i = 0;
		while (i < len) {
			var c = StringTools.fastCodeAt(src, i);
			if (c >= 0xD800 && c <= 0xDBFF) a.push(i);
			i++;
		}
		hiSurrogates = a;
		return a;
	}

	function codePointOffset(i:Int):Int {
		var a = hiSurrogates != null ? hiSurrogates : scanSurrogates();
		if (a.length == 0) return i;
		var lo = 0;
		var hi = a.length;
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			if (a[mid] < i) lo = mid + 1 else hi = mid;
		}
		return i - lo;
	}

	inline function mkPos(pmin:Int, pmax:Int):Position
		return new Position(file, codePointOffset(pmin), codePointOffset(pmax));

	inline function peek(o:Int = 0):Int {
		var i = pos + o;
		return i < len ? src.charCodeAt(i) : -1;
	}

	inline function text(start:Int):String
		return src.substr(start, pos - start);

	// StringBuf.addChar mangles a lone surrogate half on hxcpp (it becomes U+FFFD),
	// so an astral char must be copied as one code point for the literal to
	// round-trip the source exactly.
	function copyChar(buf:StringBuf):Void {
		var c = peek();
		if (c >= 0xD800 && c <= 0xDBFF) {
			var n = peek(1);
			if (n >= 0xDC00 && n <= 0xDFFF) {
				buf.addChar(0x10000 + ((c - 0xD800) << 10) + (n - 0xDC00));
				pos += 2;
				return;
			}
		}
		buf.addChar(c);
		pos++;
	}

	inline function mk(start:Int, t:Token):TokenInfo
		return new TokenInfo(t, mkPos(start, pos));

	static inline function isDigit(c:Int):Bool
		return c >= "0".code && c <= "9".code;

	static inline function isHex(c:Int):Bool
		return isDigit(c) || (c >= "a".code && c <= "f".code) || (c >= "A".code && c <= "F".code);

	static inline function isLower(c:Int):Bool
		return c >= "a".code && c <= "z".code;

	static inline function isUpper(c:Int):Bool
		return c >= "A".code && c <= "Z".code;

	static inline function isAlpha(c:Int):Bool
		return isLower(c) || isUpper(c);

	static inline function isIdentChar(c:Int):Bool
		return isAlpha(c) || isDigit(c) || c == "_".code;

	static function isXmlNameStart(c:Int):Bool {
		return c == "$".code || c == ":".code || c == "_".code || (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code)
			|| (c >= 0xC0 && c <= 0xD6) || (c >= 0xD8 && c <= 0xF6) || (c >= 0xF8 && c <= 0x2FF) || (c >= 0x370 && c <= 0x37D)
			|| (c >= 0x37F && c <= 0x1FFF) || (c >= 0x200C && c <= 0x200D) || (c >= 0x2070 && c <= 0x218F) || (c >= 0x2C00 && c <= 0x2FEF)
			|| (c >= 0x3001 && c <= 0xD7FF) || (c >= 0xF900 && c <= 0xFDCF) || (c >= 0xFDF0 && c <= 0xFFFD) || (c >= 0x10000 && c <= 0xEFFFF);
	}

	static function isXmlNameChar(c:Int):Bool {
		return isXmlNameStart(c) || c == "-".code || c == ".".code || isDigit(c) || c == 0xB7 || (c >= 0x300 && c <= 0x36F)
			|| (c >= 0x203F && c <= 0x2040);
	}

	// Recursive over 0xfeff and the "#!" line; the trailing newline
	// matches the zero-width "" arm and is left for token. Loop to mirror the recursion (any number
	// of leading BOMs, then one shebang line).
	function skipHeader():Void {
		while (true) {
			if (peek() == 0xFEFF) {
				pos++;
				continue;
			}
			// A UTF-8 BOM read as bytes is the three-byte sequence EF BB BF.
			if (peek() == 0xEF && peek(1) == 0xBB && peek(2) == 0xBF) {
				pos += 3;
				continue;
			}
			if (peek() == "#".code && peek(1) == "!".code) {
				while (pos < len && peek() != "\n".code && peek() != "\r".code)
					pos++;
				continue;
			}
			break;
		}
	}

	/** Token. Returns the next token, including Comment/CommentLine. */
	public function token():TokenInfo {
		while (true) {
			var c = peek();
			if (c == " ".code || c == "\t".code || c == "\n".code || c == "\r".code)
				pos++;
			else
				break;
		}
		var start = pos;
		var c = peek();
		if (c == -1)
			return mk(start, Eof);

		if (isDigit(c))
			return number(start);
		if (c == ".".code && isDigit(peek(1)))
			return numberDotStart(start);

		// "//" comment and "/*", handled in symbol via '/'
		if (c == "/".code && peek(1) == "*".code)
			return readBlockComment(start);
		if (c == "/".code && peek(1) == "/".code)
			return readLineComment(start);

		if (c == '"'.code)
			return readDoubleString(start);
		if (c == "'".code)
			return readSingleString(start);

		if (c == "~".code && peek(1) == "/".code)
			return readRegexp(start);

		// '#', ident, ident starts lowercase or '_' (never uppercase); `#Foo` is not
		// a sharp token (it falls to symbol -> Invalid_character on '#').
		if (c == "#".code && (isLower(peek(1)) || peek(1) == "_".code))
			return sharp(start);

		if (c == "$".code)
			return dollar(start);

		if (isLower(c) || c == "_".code)
			return identOrKeyword(start);
		if (isUpper(c))
			return upperIdent(start);

		return symbol(start);
	}

	function number(start:Int):TokenInfo {
		// Else `0x`/`0X`/`0xg` fall back to standalone `0` + ident, per sedlex maximal-munch.
		if (peek() == "0".code && peek(1) == "x".code && isHex(peek(2))) {
			pos += 2;
			while (isHex(peek()) || (peek() == "_".code && isHex(peek(1))))
				pos++;
			consumeIntSuffix();
			return mk(start, splitIntSuffix(text(start)));
		}
		if (peek() == "0".code)
			pos++; // Standalone "0"
		else {
			pos++;
			consumeSepDigits();
		}
		// Integer "..." -> IntInterval
		if (peek() == ".".code && peek(1) == ".".code && peek(2) == ".".code) {
			var s = text(start);
			pos += 3;
			return mk(start, IntInterval(s));
		}
		if (peek() == ".".code && (isDigit(peek(1)) || (isExpChar(peek(1)) && expDigitsAt(2)))) {
			pos++;
			consumeIntegerDigits();
			if (hasExponentAhead())
				consumeExponent();
			consumeFloatSuffix();
			return mk(start, splitFloatSuffix(text(start)));
		}
		if (hasExponentAhead()) {
			consumeExponent();
			consumeFloatSuffix();
			return mk(start, splitFloatSuffix(text(start)));
		}
		if (hasFloatSuffixAhead()) {
			consumeFloatSuffix();
			return mk(start, splitFloatSuffix(text(start)));
		}
		consumeIntSuffix();
		return mk(start, splitIntSuffix(text(start)));
	}

	function numberDotStart(start:Int):TokenInfo {
		pos++;
		consumeIntegerDigits();
		if (hasExponentAhead())
			consumeExponent();
		consumeFloatSuffix();
		return mk(start, splitFloatSuffix(text(start)));
	}

	static inline function isExpChar(c:Int):Bool
		return c == "e".code || c == "E".code;

	// A valid exponent digit run begins at offset o: a digit, or a sign then a digit
	inline function expDigitsAt(o:Int):Bool
		return isDigit(peek(o)) || ((peek(o) == "+".code || peek(o) == "-".code) && isDigit(peek(o + 1)));

	inline function hasExponentAhead():Bool
		return isExpChar(peek()) && expDigitsAt(1);

	inline function consumeIntegerDigits():Void {
		while (isDigit(peek()) || (peek() == "_".code && isDigit(peek(1))))
			pos++;
	}

	inline function consumeSepDigits():Void {
		while (isDigit(peek()) || (peek() == "_".code && isDigit(peek(1))))
			pos++;
	}

	function consumeExponent():Void {
		pos++;
		if (peek() == "+".code || peek() == "-".code)
			pos++;
		consumeIntegerDigits();
	}

	function hasFloatSuffixAhead():Bool {
		var p = pos;
		if (peek() == "_".code)
			p++;
		return p < len && src.charCodeAt(p) == "f".code && p + 1 < len && isDigit(src.charCodeAt(p + 1));
	}

	function consumeFloatSuffix():Void {
		if (hasFloatSuffixAhead()) {
			if (peek() == "_".code)
				pos++;
			pos++;
			consumeSepDigits();
		}
	}

	function consumeIntSuffix():Void {
		var p = pos;
		if (peek() == "_".code)
			p++;
		if (p < len && (src.charCodeAt(p) == "i".code || src.charCodeAt(p) == "u".code) && p + 1 < len && isDigit(src.charCodeAt(p + 1))) {
			pos = p + 1;
			consumeSepDigits();
		}
	}

	static function splitSuffix(s:String, isInt:Bool):{lit:String, suffix:Null<String>} {
		var n = s.length;
		var pivot = -1;
		for (i in 0...n) {
			var c = s.charCodeAt(i);
			if (c == "i".code || c == "u".code)
				pivot = i;
			else if (c == "f".code && !isInt)
				pivot = i;
		}
		if (pivot < 0)
			return {lit: s, suffix: null};
		var litLen = s.charCodeAt(pivot - 1) == "_".code ? pivot - 1 : pivot;
		return {lit: s.substr(0, litLen), suffix: s.substr(pivot)};
	}

	static function splitIntSuffix(s:String):Token {
		var r = splitSuffix(s, true);
		return Const(CInt(r.lit, r.suffix));
	}

	static function splitFloatSuffix(s:String):Token {
		var r = splitSuffix(s, false);
		return Const(CFloat(r.lit, r.suffix));
	}

	function identOrKeyword(start:Int):TokenInfo {
		while (isIdentChar(peek()))
			pos++;
		var s = text(start);
		var kw = Keywords.lookup(s);
		return kw != null ? mk(start, Kwd(kw)) : mk(start, Const(CIdent(s)));
	}

	function upperIdent(start:Int):TokenInfo {
		while (isIdentChar(peek()))
			pos++;
		return mk(start, Const(CIdent(text(start))));
	}

	// '"' -> string (raw) -> unescape
	function readDoubleString(start:Int):TokenInfo {
		pos++; // Opening "
		var buf = new StringBuf();
		while (true) {
			var c = peek();
			if (c == -1)
				throw new LexerError(UnterminatedString, mkPos(start, start));
			if (c == '"'.code) {
				pos++;
				break;
			}
			if (c == "\\".code) {
				buf.addChar(c);
				pos++;
				var n = peek();
				if (n == -1)
					throw new LexerError(UnterminatedString, mkPos(start, start));
				buf.addChar(n);
				pos++;
				continue;
			}
			copyChar(buf);
		}
		return mk(start, Const(CString(unescapeAt(buf.toString(), start), SDoubleQuotes)));
	}

	// A single-quoted string: read raw (with ${} via codeString), then unescaped
	function readSingleString(start:Int):TokenInfo {
		pos++; // Opening '
		var buf = new StringBuf();
		while (true) {
			var c = peek();
			if (c == -1)
				throw new LexerError(UnterminatedString, mkPos(start, start));
			if (c == "'".code) {
				pos++;
				break;
			}
			if (c == "\\".code) {
				buf.addChar(c);
				pos++;
				var n = peek();
				if (n == -1)
					throw new LexerError(UnterminatedString, mkPos(start, start));
				buf.addChar(n);
				pos++;
				continue;
			}
			if (c == "$".code) {
				if (peek(1) == "$".code) {
					buf.addChar("$".code);
					buf.addChar("$".code);
					pos += 2;
					continue;
				}
				if (peek(1) == "{".code) {
					var dollarPos = pos;
					buf.addChar("$".code);
					buf.addChar("{".code);
					pos += 2;
					codeString(buf, dollarPos);
					continue;
				}
				buf.addChar("$".code); // Lone '$'
				pos++;
				continue;
			}
			copyChar(buf);
		}
		return mk(start, Const(CString(unescapeAt(buf.toString(), start), SSingleQuotes)));
	}

	// Copy a balanced interpolation region verbatim.
	function codeString(buf:StringBuf, pmin:Int):Void {
		var open = 0;
		while (true) {
			var c = peek();
			if (c == -1)
				throw new LexerError(UnclosedCode, mkPos(pmin, pmin));
			if (c == "{".code) {
				buf.addChar(c);
				pos++;
				open++;
				continue;
			}
			if (c == "}".code) {
				buf.addChar(c);
				pos++;
				if (open > 0) {
					open--;
					continue;
				}
				return; // Matched closing brace
			}
			if (c == '"'.code) {
				var qpos = pos;
				buf.addChar('"'.code);
				pos++;
				scanRawDouble(buf, qpos);
				buf.addChar('"'.code);
				continue;
			}
			if (c == "'".code) {
				var qpos = pos;
				buf.addChar("'".code);
				pos++;
				scanRawSingle(buf, qpos);
				buf.addChar("'".code);
				continue;
			}
			if (c == "/".code) {
				if (peek(1) == "*".code) {
					// Block comment: consumed and discarded
					var cpos = pos;
					pos += 2;
					skipBlockComment(cpos);
					continue;
				}
				if (peek(1) == "/".code) {
					// Line comment: stored
					buf.addChar("/".code);
					buf.addChar("/".code);
					pos += 2;
					while (pos < len && peek() != "\n".code && peek() != "\r".code)
						copyChar(buf);
					continue;
				}
				buf.addChar("/".code);
				pos++;
				continue;
			}
			copyChar(buf);
		}
	}

	// Nested double-quoted string body inside ${...}: append raw content (no quotes), consume closing "
	function scanRawDouble(buf:StringBuf, pmin:Int):Void {
		while (true) {
			var c = peek();
			if (c == -1)
				throw new LexerError(UnterminatedString, mkPos(pmin, pmin));
			if (c == '"'.code) {
				pos++;
				return;
			}
			if (c == "\\".code) {
				buf.addChar(c);
				pos++;
				var n = peek();
				if (n == -1)
					throw new LexerError(UnterminatedString, mkPos(pmin, pmin));
				buf.addChar(n);
				pos++;
				continue;
			}
			copyChar(buf);
		}
	}

	// Nested single-quoted string body inside ${...}
	function scanRawSingle(buf:StringBuf, pmin:Int):Void {
		while (true) {
			var c = peek();
			if (c == -1)
				throw new LexerError(UnterminatedString, mkPos(pmin, pmin));
			if (c == "'".code) {
				pos++;
				return;
			}
			if (c == "\\".code) {
				buf.addChar(c);
				pos++;
				var n = peek();
				if (n == -1)
					throw new LexerError(UnterminatedString, mkPos(pmin, pmin));
				buf.addChar(n);
				pos++;
				continue;
			}
			if (c == "$".code) {
				if (peek(1) == "$".code) {             
					buf.addChar("$".code);
					buf.addChar("$".code);
					pos += 2;
					continue;
				}
				if (peek(1) == "{".code) {
					var dollarPos = pos;
					buf.addChar("$".code);
					buf.addChar("{".code);
					pos += 2;
					codeString(buf, dollarPos);
					continue;
				}
				buf.addChar("$".code);
				pos++;
				continue;
			}
			copyChar(buf);
		}
	}

	// Consume a /*... */ comment, discarding it (used inside codeString)
	function skipBlockComment(pmin:Int):Void {
		while (true) {
			var c = peek();
			if (c == -1)
				throw new LexerError(UnclosedComment, mkPos(pmin, pmin));
			if (c == "*".code && peek(1) == "/".code) {
				pos += 2;
				return;
			}
			pos++;
		}
	}

	// /472, unescape (Ast), re-raising Invalid_escape_sequence as a lexer Invalid_escape
	function unescapeAt(raw:String, pmin:Int):String {
		try {
			return Ast.unescape(raw);
		} catch (e:InvalidEscapeSequence) {
			throw new LexerError(InvalidEscape(e.c, e.escMsg), mkPos(pmin + e.i, pmin + e.i));
		}
	}

	function readRegexp(start:Int):TokenInfo {
		pos += 2;
		var buf = new StringBuf();
		while (true) {
			var c = peek();
			if (c == -1 || c == "\n".code || c == "\r".code)
				throw new LexerError(UnterminatedRegexp, mkPos(start, start));
			if (c == "\\".code) {
				var n = peek(1);
				if (n == -1)
					throw new LexerError(UnterminatedRegexp, mkPos(start, start));
				switch (n) {
					case "/".code: buf.addChar("/".code); pos += 2;
					case "r".code: buf.addChar("\r".code); pos += 2;
					case "n".code: buf.addChar("\n".code); pos += 2;
					case "t".code: buf.addChar("\t".code); pos += 2;
					case "\\".code | "$".code | ".".code | "*".code | "+".code | "^".code | "|".code | "{".code | "}".code | "[".code | "]".code
						| "(".code | ")".code | "?".code | "-".code | "w".code | "W".code | "b".code | "B".code | "s".code | "S".code
						| "d".code | "D".code | "x".code:
						buf.addChar("\\".code);
						buf.addChar(n);
						pos += 2;
					case _ if (isDigit(n)): // Include decimal digits in the identifier character class.
						buf.addChar("\\".code);
						buf.addChar(n);
						pos += 2;
					case "u".code | "U".code if (isHex(peek(2)) && isHex(peek(3)) && isHex(peek(4)) && isHex(peek(5))):
						buf.addChar("\\".code);
						buf.addChar(n);
						buf.addChar(peek(2));
						buf.addChar(peek(3));
						buf.addChar(peek(4));
						buf.addChar(peek(5));
						pos += 6;
					case _: // Any other escape: an invalid character, the backslash (92)
						throw new LexerError(InvalidCharacter("\\".code), mkPos(pos + 1, pos + 1));
				}
				continue;
			}
			if (c == "/".code) {
				pos++;
				break;
			}
			copyChar(buf);
		}
		var opt = new StringBuf();
		while (true) {
			var c = peek();
			switch (c) {
				case "g".code | "i".code | "m".code | "s".code | "u".code:
					opt.addChar(c);
					pos++;
				case _ if (isLower(c)):
					throw new LexerError(InvalidOption, mkPos(pos, pos));
				case _:
					return mk(start, Const(CRegexp(buf.toString(), opt.toString())));
			}
		}
	}

	function readBlockComment(start:Int):TokenInfo {
		pos += 2;
		var cstart = pos;
		while (true) {
			var c = peek();
			if (c == -1)
				throw new LexerError(UnclosedComment, mkPos(start, start));
			if (c == "*".code && peek(1) == "/".code) {
				var content = src.substr(cstart, pos - cstart);
				pos += 2;
				return mk(start, Comment(content));
			}
			pos++;
		}
	}

	function readLineComment(start:Int):TokenInfo {
		pos += 2;
		var cstart = pos;
		while (pos < len && peek() != "\n".code && peek() != "\r".code)
			pos++;
		return mk(start, CommentLine(src.substr(cstart, pos - cstart)));
	}

	// Payload is the ident after '#'. (The dotted form is recognized for #if conditions.)
	// '#', ident, the MAIN token uses the non-dotted `ident`. The dotted
	function sharp(start:Int):TokenInfo {
		pos++;
		var s = pos;
		while (isIdentChar(peek()))
			pos++;
		return mk(start, Sharp(src.substr(s, pos - s)));
	}

	function dollar(start:Int):TokenInfo {
		pos++;
		var s = pos;
		while (isIdentChar(peek()))
			pos++;
		return mk(start, Dollar(src.substr(s, pos - s)));
	}

	// Emits a single '>' (OpGt) and the parser recombines contextually.

	function symbol(start:Int):TokenInfo {
		var c = peek();
		switch (c) {
			case "+".code:
				if (peek(1) == "+".code) { pos += 2; return mk(start, TUnop(Increment)); }
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpAssignOp(OpAdd))); }
				pos++; return mk(start, TBinop(OpAdd));
			case "-".code:
				if (peek(1) == "-".code) { pos += 2; return mk(start, TUnop(Decrement)); }
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpAssignOp(OpSub))); }
				if (peek(1) == ">".code) { pos += 2; return mk(start, Arrow); }
				pos++; return mk(start, TBinop(OpSub));
			case "*".code:
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpAssignOp(OpMult))); }
				pos++; return mk(start, TBinop(OpMult));
			case "/".code:
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpAssignOp(OpDiv))); }
				pos++; return mk(start, TBinop(OpDiv));
			case "%".code:
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpAssignOp(OpMod))); }
				pos++; return mk(start, TBinop(OpMod));
			case "=".code:
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpEq)); }
				if (peek(1) == ">".code) { pos += 2; return mk(start, TBinop(OpArrow)); }
				pos++; return mk(start, TBinop(OpAssign));
			case "!".code:
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpNotEq)); }
				pos++; return mk(start, TUnop(Not));
			case "<".code:
				if (peek(1) == "<".code && peek(2) == "=".code) { pos += 3; return mk(start, TBinop(OpAssignOp(OpShl))); }
				if (peek(1) == "<".code) { pos += 2; return mk(start, TBinop(OpShl)); }
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpLte)); }
				pos++; return mk(start, TBinop(OpLt));
			case ">".code:
				pos++; return mk(start, TBinop(OpGt)); // Single-char only
			case "&".code:
				if (peek(1) == "&".code && peek(2) == "=".code) { pos += 3; return mk(start, TBinop(OpAssignOp(OpBoolAnd))); }
				if (peek(1) == "&".code) { pos += 2; return mk(start, TBinop(OpBoolAnd)); }
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpAssignOp(OpAnd))); }
				pos++; return mk(start, TBinop(OpAnd));
			case "|".code:
				if (peek(1) == "|".code && peek(2) == "=".code) { pos += 3; return mk(start, TBinop(OpAssignOp(OpBoolOr))); }
				if (peek(1) == "|".code) { pos += 2; return mk(start, TBinop(OpBoolOr)); }
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpAssignOp(OpOr))); }
				pos++; return mk(start, TBinop(OpOr));
			case "^".code:
				if (peek(1) == "=".code) { pos += 2; return mk(start, TBinop(OpAssignOp(OpXor))); }
				pos++; return mk(start, TBinop(OpXor));
			case "~".code:
				pos++; return mk(start, TUnop(NegBits));
			case "?".code:
				if (peek(1) == "?".code && peek(2) == "=".code) { pos += 3; return mk(start, TBinop(OpAssignOp(OpNullCoal))); }
				if (peek(1) == "?".code) { pos += 2; return mk(start, TBinop(OpNullCoal)); }
				if (peek(1) == ".".code) { pos += 2; return mk(start, QuestionDot); }
				pos++; return mk(start, Question);
			case ".".code:
				if (peek(1) == ".".code && peek(2) == ".".code) { pos += 3; return mk(start, TSpread); }
				pos++; return mk(start, Dot);
			case ";".code: pos++; return mk(start, Semicolon);
			case ":".code: pos++; return mk(start, DblDot);
			case ",".code: pos++; return mk(start, Comma);
			case "[".code: pos++; return mk(start, BkOpen);
			case "]".code: pos++; return mk(start, BkClose);
			case "{".code: pos++; return mk(start, BrOpen);
			case "}".code: pos++; return mk(start, BrClose);
			case "(".code: pos++; return mk(start, POpen);
			case ")".code: pos++; return mk(start, PClose);
			case "@".code: pos++; return mk(start, At);
			case _:
				throw new LexerError(InvalidCharacter(c), mkPos(start, start));
		}
	}

	public function tryReadMarkupLiteral():Null<Array<TokenInfo>> {
		var save = pos;
		while (true) {
			var c = peek();
			if (c == " ".code || c == "\t".code || c == "\n".code || c == "\r".code)
				pos++;
			else
				break;
		}
		var start = pos;
		if (peek() != "<".code) {
			pos = save;
			return null;
		}
		var n0 = peek(1);
		if (n0 != ">".code && !isXmlNameStart(n0)) {
			pos = save;
			return null;
		}
		var xml = lexXml(); // Scans from '<' through the close; leaves pos after the literal
		var end = pos;
		var metaPos = mkPos(start, start + 1);
		return [
			new TokenInfo(At, metaPos),
			new TokenInfo(DblDot, metaPos),
			new TokenInfo(Const(CIdent("markup")), metaPos),
			new TokenInfo(Const(CString(xml, SDoubleQuotes)), mkPos(start, end)),
		];
	}

	/** Inline `<xml>` markup scan. `pos` must be at the opening `<`. Returns the raw markup string; leaves `pos` after the literal. */
	public function lexXml():String {
		var p = pos; // At '<'
		pos++; // Consume '<'
		var nameEnd = readXmlNameAt(pos);
		var name = src.substring(pos, nameEnd);
		pos = nameEnd;
		var buf = new StringBuf();
		buf.add("<");
		buf.add(name);
		var openTag = "<" + name;
		var closeTag = "</" + name + ">";
		notXml(buf, 0, name != "", openTag, closeTag, p);
		return buf.toString();
	}

	function readXmlNameAt(p:Int):Int {
		if (p >= len || !isXmlNameStart(src.charCodeAt(p)))
			return p;
		p++;
		while (p < len && isXmlNameChar(src.charCodeAt(p)))
			p++;
		return p;
	}

	function notXml(buf:StringBuf, depth:Int, inOpen:Bool, openTag:String, closeTag:String, markupStart:Int):Void {
		while (true) {
			if (pos >= len)
				throw new LexerError(UnterminatedMarkup, mkPos(markupStart, markupStart));
			var c = peek();
			if (c == "<".code && peek(1) == "/".code) {
				var ne = readXmlNameAt(pos + 2);
				if (ne < len && src.charCodeAt(ne) == ">".code) {
					var s = src.substring(pos, ne + 1);
					buf.add(s);
					pos = ne + 1;
					if (s == closeTag) {
						if (depth == 0)
							return;
						depth--;
						inOpen = false;
					} else
						inOpen = false;
					continue;
				}
			}
			if (c == "<".code && isXmlNameStart(peek(1))) {
				var ne = readXmlNameAt(pos + 1);
				var s = src.substring(pos, ne);
				buf.add(s);
				pos = ne;
				if (s == openTag) {
					depth++;
					inOpen = true;
				} else
					inOpen = false;
				continue;
			}
			if (c == "/".code && peek(1) == ">".code) {
				buf.add("/>");
				pos += 2;
				if (inOpen)
					depth--;
				if (depth < 0)
					return;
				inOpen = false;
				continue;
			}
			// Bare '<': the opening
			// rule precedes the single-char rule and wins the length-1 tie, resetting inOpen.
			if (c == "<".code) {
				buf.addChar(c);
				pos++;
				if ("<" == openTag) {
					depth++;
					inOpen = true;
				} else
					inOpen = false;
				continue;
			}
			// Single '/' | '>' or any other run: store one char (inOpen preserved)
			copyChar(buf);
		}
	}
}
