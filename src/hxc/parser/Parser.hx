package hxc.parser;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Define;

using hxc.ast.Position;

// The display position sits right after a dot in a type path or import; carries the segments consumed so
// far.
class TypePathCompletion {
	public final pack:Array<String>;
	public final module:Null<String>;
	public final isImport:Bool;
	// The span the client replaces: the path segment the cursor is on. The JSON lane reports it both as
	// replaceRange and inside CRField's own range.
	public var pos:Null<Position>;

	public function new(pack:Array<String>, module:Null<String>, isImport:Bool, ?pos:Position) {
		this.pack = pack;
		this.module = module;
		this.isImport = isImport;
		this.pos = pos;
	}
}

// The display position sits in a block that only the MACRO context turns on, so the normal typing is
// abandoned and the module is loaded in that context.
class DisplayInMacroBlock extends haxe.Exception {
	public function new() super("display in macro block");
}

class Parser {
	final tokens:Array<TokenInfo>;
	var idx:Int;
	final file:String;

	// The token cursor MUST make forward progress. We track how many cursor
	// inspections (`peekInfo`) have happened since `idx` last advanced; if that
	// exceeds `STALL_LIMIT` the parser is stuck in a zero-progress loop and we
	// raise a clear error instead of hanging forever. This is a hard safety net,
	// independent of any external watchdog/timeout.
	static inline var STALL_LIMIT = 200000;
	var lastIdx:Int;
	var stall:Int;

	// True when parsing under the macro defines: reification then encodes positions via the $__mk_pos__
	// eval builtin.
	var inMacro:Bool;

	// Legacy --display: file and byte offset of the completion point; the parser raises TypePathCompletion
	// when the offset falls right after a dot in a type path of that file.
	public static var displayFile:Null<String> = null;
	public static var displayOffset:Int = -1;
	// Signature display (display mode DMSignature).
	public static var displaySignatureMode:Bool = false;
	// Completion display (display mode DMDefault): field or toplevel completion.
	public static var displayCompletionMode:Bool = false;
	// The name Meta.HxCompletion carries; it never reaches a real declaration, only the
	// metadata completion answer, which reports a null subject for it.
	public static inline var HX_COMPLETION_META = ":hxCompletion";
	// The keyword list for a type declaration position is DELAYED, so a more specific completion found
	// later wins; it is answered only if nothing else did.
	public static var delayedSyntaxCompletion:Null<Array<String>> = null;
	// The delayed syntax completion carries the SUBJECT alongside the keyword list: the identifier the
	// cursor sits in (if any) and the position the client replaces. The JSON lane reports both as
	// filterString/replaceRange; the legacy lane prints neither.
	public static var delayedSyntaxSubject:Null<{name:Null<String>, pos:Position}> = null;
	// Set when the SOURCE wrote a metadata entry whose name the cursor is on. Only the
	// parser can tell that: by the time fields are typed their metadata also holds injected
	// entries, which carry the position of whatever they were attached to.
	public static var displayMetaFound:Bool = false;
	// A position the preprocessor refuses to annotate answers NOTHING, however many later stages would
	// happily complete there.
	public static var displaySuppressed:Bool = false;
	// The display file has a conditional block that would be LIVE in the macro context.
	public static var displayModuleHasMacroDefines:Bool = false;
	// The display mode is a HOVER (it uses the enclosing-position test with a strict upper bound).
	public static var displayHoverMode:Bool = false;
	// Set only by display/completion and display/signatureHelp; every other request leaves it false.
	public static var wasAutoTriggered:Bool = false;
	// The metadata entry the cursor sits on, whatever the mode. The entry's own name is what reads its
	// documentation out of the registry.
	public static var displayMetaName:Null<String> = null;
	// The field name already written after the dot, and its position. The completion's filter string and
	// replace range come from it.
	public static var displayDotName:Null<String> = null;
	public static var displayDotPos:Null<Position> = null;
	// The parser answered a completion by RESUMING at a token, so it has already decided what the
	// request is about. ExprPreprocessing is skipped entirely when it is set, which keeps the marker
	// insertion below from claiming a position the parser has answered.
	public static var hadResume:Bool = false;
	// Errors recorded instead of raised while parsing the display file, so an incomplete construct does not
	// abort a display request.
	public static var syntaxErrors:Array<{msg:hxc.parser.ParserError.ParserErrorMsg, pos:Position}> = [];

	// Per-request reset for the wait server.
	public static function resetPerRequest():Void {
		displayFile = null;
		displayOffset = -1;
		displaySignatureMode = false;
		displayCompletionMode = false;
		displayMetaFound = false;
		displayMetaName = null;
		displaySuppressed = false;
		displayModuleHasMacroDefines = false;
		displayHoverMode = false;
		wasAutoTriggered = false;
		delayedSyntaxCompletion = null;
		delayedSyntaxSubject = null;
		displayDotName = null;
		displayDotPos = null;
		syntaxErrors = [];
		hadResume = false;
	}

	function isDisplayFile():Bool {
		return matchesDisplayFile(file);
	}

	public static function matchesDisplayFile(file:String):Bool {
		if (displayFile == null) return false;
		var f = StringTools.replace(file, "\\", "/");
		var df = StringTools.replace(displayFile, "\\", "/");
		return f == df || StringTools.endsWith(f, "/" + df) || StringTools.endsWith(df, "/" + f);
	}

	function atDisplayDot(dotPos:Position):Bool {
		if (displayFile == null || displayOffset < 0) return false;
		var f = StringTools.replace(file, "\\", "/");
		var df = StringTools.replace(displayFile, "\\", "/");
		if (!(f == df || StringTools.endsWith(f, "/" + df) || StringTools.endsWith(df, "/" + f))) return false;
		// The skipped region: from the dot's end to the next token's end.
		return displayOffset >= dotPos.max && displayOffset <= peekInfo().pos.max;
	}

	// An uppercase last segment names the module, the rest is the pack.
	static function raiseTypePath(segments:Array<String>, isImport:Bool):Dynamic {
		var last = segments.length == 0 ? null : segments[segments.length - 1];
		if (last != null && last.charCodeAt(0) >= "A".code && last.charCodeAt(0) <= "Z".code)
			throw new TypePathCompletion(segments.slice(0, segments.length - 1), last, isImport);
		throw new TypePathCompletion(segments.copy(), null, isImport);
	}

	function new(tokens:Array<TokenInfo>, file:String, inMacro:Bool = false) {
		this.tokens = tokens;
		this.idx = 0;
		this.file = file;
		this.lastIdx = -1;
		this.stall = 0;
		this.inMacro = inMacro;
	}

	public static function parseExprString(src:String, file:String = "?", ?defines:Define, registerContent:Bool = false):Expr {
		// The file's line index is saved and restored so an inline parse under a real file's name
		// (Context.parseInlineString at currentPos) does not corrupt the positions of expressions typed
		// afterwards in that file.
		var saved = registerContent ? hxc.ast.Position.saveFileEntry(file) : null;
		try {
			var p = make(src, file, defines, registerContent);
			var e = p.expr();
			if (!p.tokEq(p.peek(), Eof)) p.serror();
			if (registerContent) hxc.ast.Position.restoreFileEntry(file, saved);
			return e;
		} catch (err:Dynamic) {
			if (registerContent) hxc.ast.Position.restoreFileEntry(file, saved);
			throw err;
		}
	}

	/**
	 * Parse a single expression directly from a pre-lexed token list (used by the
	 * conditional-compilation preprocessor for parenthesised conditions). The token list must end in
	 * Eof and is not preprocessed again.
	 */
	public static function parseExprFromTokens(toks:Array<TokenInfo>, file:String):Expr {
		var p = new Parser(toks, file);
		var e = p.expr();
		if (!p.tokEq(p.peek(), Eof)) p.serror();
		return e;
	}

	// Lex `src` into a raw token list (comments filtered, ends in Eof), enforcing
	// the lexer forward-progress invariant.
	static function lexAll(src:String, file:String, out:{err:Null<LexerError>}):Array<TokenInfo> {
		var lex = new Lexer(src, file);
		var toks:Array<TokenInfo> = [];
		var lastSignificant:Null<Token> = null;
		var lastWasMarkup = false;
		var pendingDoc:Null<String> = null;
		// Lexer progress invariant: every non-Eof token call must advance the
		// stuck -> raise instead of spinning forever.
		var lastOff = lex.offset();
		try while (true) {
			if (canStartMarkup(lastSignificant, lastWasMarkup)) {
				var markup = lex.tryReadMarkupLiteral();
				if (markup != null) {
					for (mt in markup) toks.push(mt);
					lastSignificant = markup[markup.length - 1].tok;
					lastWasMarkup = true;
					var moff = lex.offset();
					if (moff <= lastOff) {
						throw new haxe.Exception("lexer made no progress (possible infinite loop)");
					}
					lastOff = moff;
					continue;
				}
			}
			var t = lex.token();
			switch (t.tok) {
				case Eof:
					toks.push(t);
					break;
				case Comment(content):
					// Filtered from the stream. Only a DOC comment (content starting with '*', i.e. a `/**`
					// block) records as the pending doc; the leading star strips always and a trailing star
					// strips when present.
					if (StringTools.startsWith(content, "*")) {
						var d = content.substr(1);
						if (StringTools.endsWith(d, "*")) d = d.substr(0, d.length - 1);
						pendingDoc = d;
					}
				case CommentLine(_):
					// Filtered from the token stream. A line comment in the DISPLAY file holding the cursor
					// answers a comment completion, which becomes an empty keyword list - and an empty list prints
					// nothing at all, so the request ends with no completion point. In completion mode the leading
					// `/` is excluded, so completing at the slash still reaches the expression before it. The min
					// > 0 guard is for a comment at the very start of the file.
					if (matchesDisplayFile(file) && displayOffset >= 0 && t.pos.min > 0) {
						var lo = displayCompletionMode ? t.pos.min + 1 : t.pos.min;
						if (lo <= displayOffset && displayOffset <= t.pos.max) displaySuppressed = true;
					}
				case _:
					// A completion whose position sits on a string or a REGEXP constant aborts the whole marking
					// pass, so the request finds no completion point at all. A single-quoted string only counts
					// when the completion was auto triggered. A markup literal never reaches here (it is read
					// before this switch), which keeps it answering.
					if (displayCompletionMode && matchesDisplayFile(file) && displayOffset >= 0
							&& t.pos.min <= displayOffset && displayOffset <= t.pos.max) switch (t.tok) {
						case Const(CString(_, k)): if (k != SSingleQuotes || wasAutoTriggered) displaySuppressed = true;
						case Const(CRegexp(_, _)): displaySuppressed = true;
						case _:
					}
					if (pendingDoc != null) {
						t.doc = pendingDoc;
						pendingDoc = null;
					}
					toks.push(t);
					lastSignificant = t.tok;
					lastWasMarkup = false;
			}
			var off = lex.offset();
			switch (t.tok) {
				case Eof:
				case _:
					if (off <= lastOff) {
						throw new haxe.Exception("lexer made no progress (possible infinite loop)");
					}
			}
			lastOff = off;
		}
		catch (e:LexerError) {
			// Deferring it made hxc report inventions from the cut-short stream instead.
			if (e.msg.match(MalformedFile)) throw e;
			out.err = e;
			toks.push(new TokenInfo(Eof, e.pos));
		}
		return toks;
	}

	static function canStartMarkup(prev:Null<Token>, lastWasMarkup:Bool):Bool {
		if (lastWasMarkup || prev == null) return true;
		return switch (prev) {
			// BrClose: a markup literal may open a STATEMENT after a closed block; the XML
			// name-start requirement keeps `{...} < b` comparisons lexing as operators.
			case POpen | BkOpen | BrOpen | BrClose | Comma | Semicolon | DblDot | Question | QuestionDot | Arrow
				| At | TSpread | TBinop(_) | TUnop(_):
				true;
			case Kwd(KwdReturn) | Kwd(KwdThrow) | Kwd(KwdCase) | Kwd(KwdElse) | Kwd(KwdIn)
				| Kwd(KwdVar) | Kwd(KwdFinal) | Kwd(KwdMacro) | Kwd(KwdUntyped) | Kwd(KwdCast)
				// `new` is followed by a type path, never markup; `function new<T>` needs the `<`
				// lexed as a type-parameter open, not a markup literal.
				| Kwd(KwdIf) | Kwd(KwdWhile) | Kwd(KwdDo) | Kwd(KwdFor)
				| Kwd(KwdSwitch) | Kwd(KwdTry):
				true;
			case _:
				false;
		}
	}

	static function make(src:String, file:String, ?defines:Define, registerContent:Bool = true):Parser {
		if (registerContent) Position.registerFileContent(file, src);
		var lexOut:{err:Null<LexerError>} = {err: null};
		var toks = lexAll(src, file, lexOut);
		// Conditional-compilation preprocessing (#if/#else/#elseif/#end/#error/
		// #line). Only run when the stream actually contains a Sharp token, so
		// the common expression-grammar path pays nothing. The active define set comes
		// from the caller (CLI/Setup later); default is empty (no hardcoded define tables).
		if (hasSharp(toks)) {
			var d = defines == null ? new Define() : defines;
			// handlePdi runs over the DISPLAY file's dead blocks only.
			var dead:Null<Array<{p:Position, cond:Expr}>> = matchesDisplayFile(file) && displayOffset >= 0 ? [] : null;
			// An unclosed #if is found by scanning the whole stream, but the preprocessor's verdicts belong
			// to the pull that reaches them, so a parse error before the conditional is reported instead.
			// Defer it on the same terms as a lexer fault.
			var ppFail:{err:Null<ParserError>} = {err: null};
			toks = Preprocess.run(toks, d, dead, ppFail);
			if (ppFail.err != null && lexOut.err == null)
				lexOut.err = new LexerError(Preprocessed(ppFail.err), ppFail.err.pos);
			if (dead != null) handlePdi(d, dead);
		}
		var pr = new Parser(toks, file, defines != null && defines.rawDefined("macro"));
		pr.pendingLexError = lexOut.err;
		return pr;
	}

	// Every DEAD block of the display file is re-evaluated with the defines ADAPTED to the MACRO
	// context. A block that would be live there means the module has macro-only code; the cursor
	// sitting inside such a block means the whole question belongs to the macro world, and the normal
	// typing is abandoned for it.
	static function handlePdi(defines:Define, dead:Array<{p:Position, cond:Expr}>):Void {
		var macroDefines = Define.adaptToMacroContext(defines);
		for (b in dead) {
			var hasMacroDefine = try Preprocess.isTrueExpr(macroDefines, b.cond) catch (_:Dynamic) false;
			if (hasMacroDefine) displayModuleHasMacroDefines = true;
			// The enclosing-position test, with the HOVER variant taking the upper bound strictly
			var inside = displayHoverMode
				? (b.p.min <= displayOffset && b.p.max > displayOffset)
				: (b.p.min <= displayOffset && b.p.max >= displayOffset);
			if (inside && hasMacroDefine) throw new DisplayInMacroBlock();
		}
	}

	static function hasSharp(toks:Array<TokenInfo>):Bool {
		for (t in toks) switch (t.tok) { case Sharp(_): return true; case _: }
		return false;
	}

	inline function peekInfo(o:Int = 0):TokenInfo {
		// Progress invariant: if we keep inspecting tokens without the cursor
		// ever advancing, we are looping with no input consumed -> bail out.
		if (idx == lastIdx) {
			if (++stall > STALL_LIMIT) {
				throw new ParserError(Custom("parser made no progress (possible infinite loop) near " + Std.string(tokens[idx < tokens.length ? idx : tokens.length - 1].tok)), cur0());
			}
		} else {
			lastIdx = idx;
			stall = 0;
		}
		var i = idx + o;
		if (pendingLexError != null && i >= tokens.length - 1) {
			var e = pendingLexError;
			pendingLexError = null;
			switch (e.msg) {
				case Preprocessed(pe): throw pe;
				case _: throw e;
			}
		}
		return i < tokens.length ? tokens[i] : tokens[tokens.length - 1];
	}

	// Position of the current token without going through the guarded peek path.
	inline function cur0():Position {
		var i = idx < tokens.length ? idx : tokens.length - 1;
		return tokens[i].pos;
	}

	inline function peek(o:Int = 0):Token return peekInfo(o).tok;

	inline function cur():TokenInfo return peekInfo(0);

	inline function junk():Void idx++;

	function next():TokenInfo {
		var t = peekInfo();
		idx++;
		return t;
	}

	function err(msg:String):Dynamic {
		throw new ParserError(Custom(msg), cur().pos);
	}

	// A null placed over the GAP between an already parsed position and the next token, so a cursor sitting
	// in the gap is enclosed by it (the max is one short of the next token's end).
	function nullStandIn(p1:Position):Expr {
		return new Expr(EConst(CIdent("null")), new Position(p1.file, p1.min, peekInfo().pos.max - 1));
	}

	// Outside a display mode the error is RAISED, inside one it is recorded and the caller's stand-in value
	// takes the place of what could not be parsed. A construct that hard-expects its closing token instead
	// loses everything after it, so an unfinished `if (`/`for (`/`while (`/`switch` never reaches the
	// cursor inside it.
	function syntaxError(msg:hxc.parser.ParserError.ParserErrorMsg, ?pos:Position):Void {
		var p = pos != null ? pos : peekInfo().pos;
		if (displayFile == null) throw new ParserError(msg, p);
		syntaxErrors.push({msg: msg, pos: p});
	}

	function mkNullExpr(p:Position):Expr {
		return new Expr(EConst(CIdent("null")), p);
	}

	// Signature mark: in signature display, the argument whose span from the preceding separator to
	// the following one covers the cursor is marked, and the index of that marked argument is what the
	// answer reports as the active parameter. Counting finished arguments instead would put the cursor
	// on the next parameter as soon as it leaves the last one. Resume: the cursor sitting exactly at
	// the end of this token, in the display file and in completion mode, means the construct the token
	// opens is what is being completed. Completion: the identifier the cursor sits in, CONSUMED, or an
	// empty subject at the display position when the cursor is in the gap after p0.
	function checkCompletion(p0:Position, plusOne:Bool):Null<{name:Null<String>, pos:Position}> {
		if (!isDisplayFile() || displayOffset < 0) return null;
		var np = peekInfo().pos;
		switch (peek()) {
			case Const(CIdent(n)) if (np.min <= displayOffset && displayOffset <= np.max):
				junk();
				return {name: n, pos: np};
			case _:
		}
		if (!wouldSkipDisplayPosition(p0, plusOne)) return null;
		return {name: null, pos: new Position(p0.file, displayOffset, displayOffset)};
	}

	function checkResume(p:Position):Bool {
		if (!(displayCompletionMode && isDisplayFile() && displayOffset >= 0 && p.max == displayOffset)) return false;
		hadResume = true;
		return true;
	}

	// The span from the end of this token to the end of the next one contains the cursor, so whatever
	// belongs between them was never written.
	function wouldSkipDisplayPosition(p1:Position, plusOne:Bool):Bool {
		if (!isDisplayFile() || displayOffset < 0) return false;
		var p2 = peekInfo().pos;
		var lo = p1.max + (plusOne ? 1 : 0);
		return lo <= displayOffset && displayOffset <= p2.max;
	}

	// The cursor sitting in the GAP between the end of this token and the start of the next one, in the
	// display file and in completion mode.
	function checkResumeRange(p:Position):Bool {
		if (!displayCompletionMode || !isDisplayFile() || displayOffset < 0) return false;
		return p.min < displayOffset && peekInfo().pos.min >= displayOffset;
	}

	// An empty package and name marks a type position that is under the cursor, which type loading answers
	// with every type in scope.
	static function magicTypePath():TypePath {
		return {tpackage: [], tname: "", tparams: [], tsub: null};
	}

	// An element list whose GAP holds the cursor gets a marked null in that gap, the element the user
	// has not written yet. Returns it as a list so a caller can splice it in unconditionally.
	function gapMark(pAfter:Position, pBefore:Position):Array<Expr> {
		if (!displayCompletionMode || !isDisplayFile() || displayOffset < 0) return [];
		if (pAfter.max > displayOffset || pBefore.min < displayOffset) return [];
		return [new Expr(EConst(CIdent("null")), new Position(pAfter.file, displayOffset, displayOffset))];
	}

	function checkSignatureMark(e:Expr, p1:Position, p2:Position):Expr {
		if (!displaySignatureMode || displayOffset < 0) return e;
		// Union of p1 and p2, then the enclosing-position test with a strict upper bound
		var pmin = p1.min < p2.min ? p1.min : p2.min;
		var pmax = p1.max > p2.max ? p1.max : p2.max;
		if (pmin <= displayOffset && pmax > displayOffset) return new Expr(EDisplay(e, DKMarked), e.pos);
		return e;
	}

	/**
		Set when the class-field parse found no field FORM at all: the soft failure that ends the field
		list. Consumed and reset by parseClassFields.
	*/
	var fieldFormFailed:Bool = false;

	/** Lexing or preprocessing stopped early on a fault. peekInfo raises it once the cursor
		reaches the truncated end, so a PARSE error inside the valid prefix is reported first. */
	var pendingLexError:Null<LexerError> = null;

	function serror():Dynamic {
		throw new ParserError(Unexpected(peek()), cur().pos);
	}

	function expect(t:Token):Position {
		var c = cur();
		if (Type.enumEq(c.tok, t)) { junk(); return c.pos; }
		throw new ParserError(Expected([Ast.sToken(t)]), c.pos);
	}

	inline function tokEq(a:Token, b:Token):Bool return Type.enumEq(a, b);

	static function precedence(op:Binop):{p:Int, left:Bool} {
		return switch (op) {
			case OpIn: {p: 0, left: false};
			case OpMod: {p: 1, left: true};
			case OpMult, OpDiv: {p: 2, left: true};
			case OpAdd, OpSub: {p: 3, left: true};
			case OpShl, OpShr, OpUShr: {p: 4, left: true};
			case OpOr, OpAnd, OpXor: {p: 5, left: true};
			case OpNullCoal: {p: 6, left: true};
			case OpEq, OpNotEq, OpGt, OpLt, OpGte, OpLte: {p: 7, left: true};
			case OpInterval: {p: 8, left: true};
			case OpBoolAnd: {p: 9, left: true};
			case OpBoolOr: {p: 10, left: true};
			case OpArrow: {p: 11, left: false};
			case OpAssign, OpAssignOp(_): {p: 12, left: false};
		}
	}

	static function isHigherThanTernary(op:Binop):Bool {
		return switch (op) {
			case OpAssign, OpAssignOp(_), OpArrow: false;
			case _: true;
		}
	}

	static function swap(op1:Binop, op2:Binop):Bool {
		var a = precedence(op1);
		var b = precedence(op2);
		return a.left && a.p <= b.p;
	}

	static function makeBinop(op:Binop, e:Expr, e2:Expr):Expr {
		return switch (e2.expr) {
			case EBinop(_op, _e, _e2) if (swap(op, _op)):
				var ne = makeBinop(op, e, _e);
				new Expr(EBinop(_op, ne, _e2), Position.union(ne.pos, _e2.pos));
			case ETernary(e1, et2, e3) if (isHigherThanTernary(op)):
				var ne = makeBinop(op, e, e1);
				new Expr(ETernary(ne, et2, e3), Position.union(ne.pos, e3.pos));
			case _:
				new Expr(EBinop(op, e, e2), Position.union(e.pos, e2.pos));
		}
	}

	static function negStr(s:String):String {
		return (s.charCodeAt(0) == '-'.code) ? s.substr(1) : "-" + s;
	}

	static function makeUnop(op:Unop, e:Expr, p1:Position):Expr {
		var p2 = e.pos;
		return switch (e.expr) {
			case EBinop(bop, e1, e2):
				new Expr(EBinop(bop, makeUnop(op, e1, p1), e2), Position.union(p1, p2));
			case ETernary(e1, e2, e3):
				new Expr(ETernary(makeUnop(op, e1, p1), e2, e3), Position.union(p1, p2));
			case EIs(e1, t):
				new Expr(EIs(makeUnop(op, e1, p1), t), Position.union(p1, p2));
			case EConst(CInt(i, suffix)) if (op == Neg):
				new Expr(EConst(CInt(negStr(i), suffix)), Position.union(p1, p2));
			case EConst(CFloat(j, suffix)) if (op == Neg):
				new Expr(EConst(CFloat(negStr(j), suffix)), Position.union(p1, p2));
			case _:
				new Expr(EUnop(op, Prefix, e), Position.union(p1, p2));
		}
	}

	static function makeMeta(name:String, params:Array<Expr>, e:Expr, p1:Position):Expr {
		var p2 = e.pos;
		return switch (e.expr) {
			case EBinop(OpAssign, _, _) | EBinop(OpAssignOp(_), _, _):
				new Expr(EMeta({name: name, params: params, pos: p1}, e), Position.union(p1, p2));
			case EBinop(bop, e1, e2):
				new Expr(EBinop(bop, makeMeta(name, params, e1, p1), e2), Position.union(p1, p2));
			case ETernary(e1, e2, e3):
				new Expr(ETernary(makeMeta(name, params, e1, p1), e2, e3), Position.union(p1, p2));
			case _:
				new Expr(EMeta({name: name, params: params, pos: p1}, e), Position.union(p1, p2));
		}
	}

	static function isPostfix(e:Expr, op:Unop):Bool {
		return switch (op) {
			case Increment, Decrement, Not: true;
			case Neg, NegBits, Spread: false;
		}
	}

	function identTok():PlacedName {
		switch (peek()) {
			case Const(CIdent(i)): var p = next().pos; return {name: i, pos: p};
			case _: return err("Expected identifier");
		}
	}

	function dollarIdent():PlacedName {
		switch (peek()) {
			case Const(CIdent(i)): var p = next().pos; return {name: i, pos: p};
			case Dollar(v): var p = next().pos; return {name: "$" + v, pos: p};
			case _: return err("Expected identifier");
		}
	}

	static function isLowerIdent(s:String):Bool {
		if (s.length == 0) return false;
		var i = 0;
		while (i < s.length) {
			var c = s.charCodeAt(i);
			if (c >= 'a'.code && c <= 'z'.code) return true;
			if (c == '_'.code) { i++; continue; }
			return false;
		}
		return true; // All underscores
	}

	function psepTrailing<T>(f:Void->T):Array<T> {
		var acc:Array<T> = [];
		while (true) {
			var save = idx;
			var v:T;
			try {
				v = f();
			} catch (e:ParserError) {
				if (idx != save) throw e;
				idx = save;
				break;
			}
			acc.push(v);
			if (tokEq(peek(), Comma)) {
				junk();
				if (tokEq(peek(), Comma)) throw new ParserError(Unexpected(Comma), peekInfo().pos);
				continue;
			}
			break;
		}
		return acc;
	}

	// Comma-separated list without a trailing comma.
	function psep<T>(sep:Token, f:Void->T):Array<T> {
		var acc:Array<T> = [];
		var save = idx;
		try {
			acc.push(f());
		} catch (e:ParserError) {
			// A parse that consumed tokens before failing is a real error and propagates. Swallowing it
			// turned `case (_.eq` into an empty pattern list, and the missing `:` got reported in place of
			// the paren expression's own `Expected ) or , or :`.
			if (idx != save) throw e;
			idx = save;
			return acc;
		}
		while (tokEq(peek(), sep)) {
			junk();
			acc.push(f());
		}
		return acc;
	}

	function parseMetaEntry():MetadataEntry {
		var p1 = expect(At);
		// A lone @ with the cursor right after it stands for the metadata completion marker, so the
		// declaration parses and the answer comes from the marker's position instead of the parse failing
		// on whatever follows.
		var resumeMarker = checkResume(p1);
		var name = try parseMetaName(p1) catch (er:ParserError) {
			if (!resumeMarker) throw er;
			syntaxErrors.push({msg: er.msg, pos: er.pos});
			// The marker exists only because the cursor is on this entry.
			displayMetaFound = true;
			return {name: HX_COMPLETION_META, params: [], pos: p1};
		}
		var pEnd = tokens[idx - 1].pos;
		var params:Array<Expr> = [];
		// A `(...)` is metadata ARGS only when the `(` is IMMEDIATELY adjacent to the name (POpen.min ==
		// name.max, i.e. no whitespace). With a space,
		// `@:meta (expr)` is metadata APPLIED to the parenthesized expression, not args, so we
		if (tokEq(peek(), POpen) && peekInfo().pos.min == tokens[idx - 1].pos.max) {
			junk();
			var pOpen = tokens[idx - 1].pos;
			params = psepTrailing(expr);
			// An unfinished argument list containing the display position keeps the parsed prefix so typing
			// can complete at the position; otherwise the missing close reports as usual.
			if (tokEq(peek(), PClose)) junk();
			else if (!(isDisplayFile() && displayOffset >= pOpen.min && displayOffset <= peekInfo().pos.max))
				throw new ParserError(Expected(params.length == 0 ? ["expression", ")"] : [",", ")"]), peekInfo().pos);
			// The entry position spans the name only; the arguments are excluded.
		}
		var entry = {name: name, params: params, pos: Position.union(p1, pEnd)};
		// The display position sitting on the entry answers on its name. Which answer follows the mode:
		// completion of the whole registry under DMDefault, this entry's own documentation under DMHover.
		if (isDisplayFile() && displayOffset >= entry.pos.min && displayOffset <= entry.pos.max) {
			if (displayCompletionMode) displayMetaFound = true;
			displayMetaName = entry.name;
		}
		return entry;
	}

	// Every part must sit IMMEDIATELY after what precedes it (p.min = p1.max). A following '.' needs no
	// adjacency of its own, but the part after it must be adjacent to the dot.
	function metaNameParts(prev:Position, acc:Array<String>):Array<String> {
		if (peekInfo().pos.min != prev.max) throw new ParserError(Expected(["metadata name"]), peekInfo().pos);
		acc.push(metaNamePart());
		if (tokEq(peek(), Dot)) return metaNameParts(next().pos, acc);
		return acc;
	}

	function parseMetaName(p1:Position):String {
		// A leading ':' must itself be adjacent to the '@'. Without the adjacency rule a name on the next
		// LINE reads as the metadata's name, which swallows the declaration that follows a bare '@'.
		if (tokEq(peek(), DblDot) && peekInfo().pos.min == p1.max) {
			var pd = next().pos;
			// A cursor right after the ':' is completing the name as well
			var marker = checkResume(pd);
			return try ":" + metaNameParts(pd, []).join(".") catch (er:ParserError) {
				if (!marker) throw er;
				syntaxErrors.push({msg: er.msg, pos: er.pos});
				HX_COMPLETION_META;
			}
		}
		return metaNameParts(p1, []).join(".");
	}

	function metaNamePart():String {
		switch (peek()) {
			case Const(CIdent(i)): junk(); return i;
			case Kwd(k): junk(); return Ast.sKeyword(k);
			case _: return err("Expected meta name");
		}
	}

	function parseMeta():Metadata {
		var acc:Metadata = [];
		while (tokEq(peek(), At)) {
			acc.push(parseMetaEntry());
		}
		return acc;
	}

	function parseTypeHint():TypeHint {
		var p1 = expect(DblDot);
		// With the cursor in the gap after the `:`, the hint is the magic type path at the display
		// position, and the real type is still parsed but discarded. Parsing it first would leave an
		// unfinished hint with no completion point.
		if (checkResumeRange(p1)) {
			try parseComplexType() catch (_:ParserError) {};
			return {ct: CTPath(magicTypePath()), pos: new Position(p1.file, displayOffset, displayOffset)};
		}
		var ct = parseComplexType();
		return ct;
	}

	function poptTypeHint():Null<TypeHint> {
		if (tokEq(peek(), DblDot)) return parseTypeHint();
		return null;
	}

	function parseComplexType():TypeHint {
		return parseComplexTypeMaybeNamed(false);
	}

	function parseComplexTypeMaybeNamed(allowNamed:Bool):TypeHint {
		if (tokEq(peek(), POpen)) {
			var p1 = next().pos;
			var tl = psepTrailing(() -> parseComplexTypeMaybeNamed(true));
			var p2 = expect(PClose);
			if (tl.length == 0) {
				return parseFunctionTypeNext(tl, p1);
			} else if (tl.length == 1) {
				switch (tl[0].ct) {
					case CTNamed(_, _):
						return parseFunctionTypeNext(tl, p1);
					case _:
						var t:TypeHint = {ct: CTParent(tl[0]), pos: Position.union(p1, p2)};
						return parseComplexTypeNext(t);
				}
			} else {
				return parseFunctionTypeNext(tl, p1);
			}
		}
		var t = parseComplexTypeInner(allowNamed);
		return parseComplexTypeNext(t);
	}

	function parseComplexTypeInner(allowNamed:Bool):TypeHint {
		switch (peek()) {
			case POpen:
				var p1 = next().pos;
				var t = parseComplexType();
				var p2 = expect(PClose);
				return {ct: CTParent(t), pos: Position.union(p1, p2)};
			case BrOpen:
				var p1 = next().pos;
				return parseBraceType(p1);
			case Question:
				var p1 = next().pos;
				var inner = parseComplexTypeInner(allowNamed);
				return {ct: CTOptional(inner), pos: Position.union(p1, inner.pos)};
			case TSpread:
				var p1 = next().pos;
				var inner = parseComplexTypeInner(allowNamed);
				var hint = switch (inner.ct) {
					case CTNamed(_, h): h;
					case _: inner;
				}
				var tp:TypePath = {tpackage: ["haxe"], tname: "Rest", tparams: [TPType(hint)], tsub: null};
				return {ct: CTPath(tp), pos: Position.union(p1, inner.pos)};
			case Const(CIdent(_)), Dollar(_):
				var n = dollarIdent();
				if (allowNamed && tokEq(peek(), DblDot)) {
					junk();
					var t = parseComplexType();
					return {ct: CTNamed(n, t), pos: Position.union(n.pos, t.pos)};
				}
				var tp = parseTypePath2(null, [], n.name, n.pos);
				return {ct: CTPath(tp.path), pos: tp.pos};
			case _:
				var tp = parseTypePath();
				return {ct: CTPath(tp.path), pos: tp.pos};
		}
	}

	// After an anonymous-structure field the parser wants `,` or `}`; anything else is recorded and
	// the structure closes at the last token it read, so an unfinished `{signatures: Array<String`
	// still yields the fields it did parse.
	function closeAnonFields():Position {
		if (tokEq(peek(), BrClose)) return next().pos;
		syntaxError(Expected([",", "}"]));
		return tokens[idx > 0 ? idx - 1 : 0].pos;
	}

	function parseBraceType(p1:Position):TypeHint {
		// Either anonymous { fields }, or extension { > T, fields }
		if (tokEq(peek(), TBinop(OpGt))) {
			var tl:Array<PlacedTypePath> = [parseStructuralExtension()];
			while (tokEq(peek(), TBinop(OpGt))) {
				tl.push(parseStructuralExtension());
			}
			// After the extension list, the remaining body is EITHER the short anon-var form or a full
			// class-field body
			if (isAnonVarBody()) {
				var fields = parseAnonFields();
				var p2 = closeAnonFields();
				return {ct: CTExtend(tl, fields), pos: Position.union(p1, p2)};
			}
			var r = parseClassFields(true, p1);
			return {ct: CTExtend(tl, r.fields), pos: Position.union(p1, r.pos)};
		}
		// Discriminate between the short anon-var form and the class-field body
		// form (which allows `function`/`var`/access/metadata fields), exactly as
		// the reference falls through from parse_type_anonymous to parse_class_fields.
		if (isAnonVarBody()) {
			var fields = parseAnonFields();
			var p2 = closeAnonFields();
			return {ct: CTAnonymous(fields), pos: Position.union(p1, p2)};
		}
		var r = parseClassFields(true, p1);
		return {ct: CTAnonymous(r.fields), pos: Position.union(p1, r.pos)};
	}

	// True iff the brace body is the short anonymous-structure form, i.e. a sequence of `?name: Type`
	// / `name: Type` entries. False if it is a class-field body (`function`/`var`/`final`/access
	// keyword/ metadata leading), which must go through parseClassFields. Pure lookahead; only commits
	// on `?` or a dollarIdent followed by `:`.
	function isAnonVarBody():Bool {
		// Empty body `{}` => treat as anonymous (vacuously the short form).
		if (tokEq(peek(), BrClose)) return true;
		// Leading `?` is always the short optional-field form.
		if (tokEq(peek(), Question)) return true;
		// `ident:` or `$ident:` with no preceding keyword/metadata => short form.
		switch (peek()) {
			case Const(CIdent(_)), Dollar(_):
				return tokEq(peek(1), DblDot);
			case _:
				return false;
		}
	}

	// `from <cursor>` yields the MAGIC type path, and so does `from <cursor> {}`, where a type WAS parsed
	// but the cursor was skipped over to reach it.
	// The magic arm is the SECOND alternative - a real type parses first, and the magic path only stands in
	// when that attempt fails having consumed nothing and the cursor is in the gap after p.
	function parseComplexTypeAt(p:Position):TypeHint {
		var save = idx;
		try {
			return parseComplexType();
		} catch (er:ParserError) {
			if (idx != save) throw er;
			idx = save;
			if (!wouldSkipDisplayPosition(p, false)) throw er;
			return {ct: CTPath(magicTypePath()), pos: new Position(p.file, displayOffset, displayOffset)};
		}
	}

	function abstractRelationType(pk:Position):TypeHint {
		var t = parseComplexTypeAt(pk);
		// A type WAS parsed but the cursor was skipped OVER to reach it, which is `from <cursor> {}`
		// swallowing the body as an anonymous structure.
		if (isDisplayFile() && displayOffset >= 0 && pk.max < displayOffset && t.pos.min >= displayOffset)
			return {ct: CTPath(magicTypePath()), pos: new Position(t.pos.file, displayOffset, displayOffset)};
		return t;
	}

	function parseStructuralExtension():PlacedTypePath {
		var p1 = expect(TBinop(OpGt));
		// A real type path is parsed first; only a failure that consumed nothing reaches the magic arm,
		// where `> <cursor>` yields the MAGIC type path (which type loading answers with every type in
		// scope, filtered to structures by the CTExtend arm) and the trailing comma is optional. Checking
		// the cursor before parsing would complete over `> |A` instead of answering about A.
		var save = idx;
		var t:PlacedTypePath;
		try t = parseTypePath() catch (er:ParserError) {
			if (idx != save) throw er;
			idx = save;
			if (!wouldSkipDisplayPosition(p1, false)) throw er;
			if (tokEq(peek(), Comma)) junk();
			return {path: magicTypePath(), pos: new Position(p1.file, displayOffset, displayOffset)};
		}
		// The comma after an extension is recorded when missing, not raised, so `> T` with nothing after
		// it still yields the path it did parse.
		if (tokEq(peek(), Comma)) junk();
		else syntaxError(Expected([","]));
		return t;
	}

	// Short anonymous-type field list: `?name: Type` entries separated by `,`. A leading `?` does not
	// wrap the type in CTOptional, it strips the `?`, keeps the type, and tags the field with
	// `@:optional` metadata.
	function parseAnonFields():Array<ClassField> {
		var fields:Array<ClassField> = [];
		while (!tokEq(peek(), BrClose) && !tokEq(peek(), Eof)) {
			var opt = false;
			var qpos = Position.nullPos;
			if (tokEq(peek(), Question)) { qpos = cur().pos; junk(); opt = true; }
			var name = dollarIdent();
			var th = parseTypeHint();
			var meta:Metadata = opt ? [{name: ":optional", params: [], pos: Position.nullPos}] : [];
			var startPos = opt ? qpos : name.pos;
			fields.push({
				cffName: opt ? {name: name.name, pos: Position.union(qpos, name.pos)} : name,
				cffDoc: null,
				cffPos: Position.union(startPos, th.pos),
				cffMeta: meta,
				cffAccess: [],
				cffKind: FVar(th, null),
			});
			if (tokEq(peek(), Comma)) junk();
			else break;
		}
		return fields;
	}

	function parseComplexTypeNext(t:TypeHint):TypeHint {
		switch (peek()) {
			case Arrow:
				var pa = next().pos;
				// Nothing after the arrow is not an error when the CURSOR is what stands there - the magic
				// path answers with every type in scope.
				var t2 = missingTypeAtCursor(pa, function() return parseComplexType());
				return switch (t2.ct) {
					case CTFunction(args, r):
						{ct: CTFunction([t].concat(args), r), pos: Position.union(t.pos, t2.pos)};
					case _:
						{ct: CTFunction([t], t2), pos: Position.union(t.pos, t2.pos)};
				}
			case TBinop(OpAnd):
				var pa = next().pos;
				// The same rule for an intersection
				var t2 = missingTypeAtCursor(pa, function() return parseComplexType());
				return switch (t2.ct) {
					case CTIntersection(tl):
						{ct: CTIntersection([t].concat(tl)), pos: Position.union(t.pos, t2.pos)};
					case _:
						{ct: CTIntersection([t, t2]), pos: Position.union(t.pos, t2.pos)};
				}
			case _:
				return t;
		}
	}

	// A type the grammar REQUIRES but the user has not written stands in as the magic path when the cursor
	// is what sits in its place, so the request completes on types instead of reporting a syntax error. A
	// failure that consumed tokens is a real error.
	function missingTypeAtCursor(pa:Position, parse:Void->TypeHint):TypeHint {
		var save = idx;
		try return parse() catch (er:ParserError) {
			if (idx != save || !wouldSkipDisplayPosition(pa, false)) throw er;
			idx = save;
			return {ct: CTPath(magicTypePath()), pos: new Position(pa.file, displayOffset, displayOffset)};
		}
	}

	function parseFunctionTypeNext(tl:Array<TypeHint>, p1:Position):TypeHint {
		var pa = expect(Arrow);
		var tret = missingTypeAtCursor(pa, function() return parseComplexTypeInner(false));
		return {ct: CTFunction(tl, tret), pos: Position.union(p1, tret.pos)};
	}

	function parseTypePath():PlacedTypePath {
		return parseTypePath1(null, []);
	}

	function parseTypePath1(p0:Null<Position>, pack:Array<String>):PlacedTypePath {
		var n = dollarIdentMacro(pack);
		return parseTypePath2(p0, pack, n.name, n.pos);
	}

	function dollarIdentMacro(pack:Array<String>):PlacedName {
		switch (peek()) {
			case Const(CIdent(i)): var p = next().pos; return {name: i, pos: p};
			case Dollar(v): var p = next().pos; return {name: "$" + v, pos: p};
			case Kwd(KwdMacro) if (pack.length > 0): var p = next().pos; return {name: "macro", pos: p};
			case Kwd(KwdExtern) if (pack.length > 0): var p = next().pos; return {name: "extern", pos: p};
			case Kwd(KwdFunction) if (pack.length > 0): var p = next().pos; return {name: "function", pos: p};
			case _: return err("Expected identifier");
		}
	}

	// Type paths, imports and usings all gate the dot completion on checkResume - the cursor sitting
	// exactly at the dot's end - not on wouldSkipDisplayPosition. The wider span would swallow a
	// cursor inside the name after the dot, so `import Type.Valu|eType` would answer with Type's
	// statics instead of hovering ValueType.
	function parseTypePath2(p0:Null<Position>, pack:Array<String>, name:String, p1:Position):PlacedTypePath {
		// With the cursor on the path, an otherwise invalid one is RETURNED as written rather than
		// reported, so the typer answers a completion about the name being typed instead of a syntax
		// error.
		var pFull = p0 == null ? p1 : Position.union(p0, p1);
		inline function checkDisplay():Null<PlacedTypePath> {
			if (!isDisplayFile() || displayOffset < 0) return null;
			if (!(pFull.min <= displayOffset && displayOffset <= pFull.max)) return null;
			return {path: {tpackage: pack.copy(), tname: name, tparams: [], tsub: null}, pos: pFull};
		}
		if (isLowerIdent(name)) {
			if (tokEq(peek(), Dot)) {
				var dp = next().pos;
				if (checkResume(dp)) raiseTypePath(pack.concat([name]), false);
				return parseTypePath1(p0 == null ? p1 : p0, pack.concat([name]));
			} else {
				var cd = checkDisplay();
				if (cd != null) return cd;
				// After a lowercase path element, only a SEMICOLON earns the uppercase message - that is the
				// shape of a `import pack.thing;` gone wrong. Every other token falls to `check_display
				// serror`, which reports `Unexpected <token>`. Collapsing the two blamed the case of the name
				// for what is really an unexpected token.
				if (tokEq(peek(), Semicolon)) return err("Type name should start with an uppercase letter");
				return serror();
			}
		}
		var sub:Null<String> = null;
		var p2 = p1;
		if (tokEq(peek(), Dot)) {
			var dp = next().pos;
			if (checkResume(dp)) raiseTypePath(pack.concat([name]), false);
			switch (peek()) {
				case Const(CIdent(sn)) if (!isLowerIdent(sn)):
					p2 = next().pos;
					sub = sn;
				case _:
					return serror();
			}
		}
		var params:Array<TypeParamOrConst> = [];
		if (tokEq(peek(), TBinop(OpLt))) {
			var plt = next().pos;
			params = psep(Comma, parseTypePathOrConst.bind(plt));
			// A missing `>` is recorded and the path closes at the last token it read, so an unfinished
			// `Array<String` still yields a type path to answer about.
			if (tokEq(peek(), TBinop(OpGt))) p2 = next().pos;
			else {
				syntaxError(Expected([">"]));
				p2 = tokens[idx > 0 ? idx - 1 : 0].pos;
			}
		}
		var tp:TypePath = {
			tpackage: pack.copy(),
			tname: name,
			tparams: params,
			tsub: sub,
		};
		return {path: tp, pos: Position.union(p0 == null ? p1 : p0, p2)};
	}

	function parseTypePathOrConst(plt:Position):TypeParamOrConst {
		// BkOpen array, then a complex type, then unop/neg+const, then const, then expr.
		switch (peek()) {
			case BkOpen:
				var p1 = next().pos;
				var e = parseArrayDecl(p1);
				return TPExpr(e);
			case TUnop(op):
				var p1 = next().pos;
				switch (peek()) {
					case Const(c):
						var p2 = next().pos;
						return TPExpr(makeUnop(op, new Expr(EConst(c), p2), p1));
					case _: return serror();
				}
			case TBinop(OpSub):
				var p1 = next().pos;
				switch (peek()) {
					case Const(c):
						var p2 = next().pos;
						return TPExpr(makeUnop(Neg, new Expr(EConst(c), p2), p1));
					case _: return serror();
				}
			case Kwd(KwdTrue):
				var p = next().pos; return TPExpr(new Expr(EConst(CIdent("true")), p));
			case Kwd(KwdFalse):
				var p = next().pos; return TPExpr(new Expr(EConst(CIdent("false")), p));
			case _:
		}
		// Try complex type first; fall back to const/expr.
		var save = idx;
		try {
			return TPType(parseComplexType());
		} catch (e:ParserError) {
			// A hard parse error, not a clean backtrack to the const/expr alternative.
			if (idx != save) throw e;
			idx = save;
		}
		switch (peek()) {
			case Const(c):
				var p = next().pos;
				return TPExpr(new Expr(EConst(c), p));
			case _:
		}
		// The last alternative. Only a parameter that could not be read at all becomes the magic type
		// path, so `Null<|>` completes on the types in scope while `Array<Strin|g` keeps the name the
		// user is writing.
		var saveE = idx;
		try {
			return TPExpr(expr());
		} catch (er:ParserError) {
			if (idx != saveE) throw er;
			idx = saveE;
			if (!wouldSkipDisplayPosition(plt, false)) throw er;
			return TPType({ct: CTPath(magicTypePath()), pos: new Position(plt.file, displayOffset, displayOffset)});
		}
	}

	function parseConstraintParams():Array<TypeParam> {
		if (!tokEq(peek(), TBinop(OpLt))) return [];
		junk();
		var save = idx;
		try {
			var l = [parseConstraintParam()];
			while (tokEq(peek(), Comma)) { junk(); l.push(parseConstraintParam()); }
			expect(TBinop(OpGt));
			return l;
		} catch (er:ParserError) {
			// A parameter list that could not be read at all junks a `>` so the follow-up parse is not
			// thrown off by it, and records what was expected there. An attempt that consumed tokens is a
			// real error.
			if (idx != save) throw er;
			var pos = tokEq(peek(), TBinop(OpGt)) ? next().pos : null;
			syntaxError(Expected(["type parameter"]), pos);
			return [];
		}
	}

	function parseConstraintParam():TypeParam {
		var meta = parseMeta();
		var name = typeName();
		var cto:Null<TypeHint> = null;
		if (tokEq(peek(), DblDot)) { junk(); cto = parseComplexType(); }
		var def:Null<TypeHint> = null;
		if (tokEq(peek(), TBinop(OpAssign))) { junk(); def = parseComplexType(); }
		return {tpName: name, tpParams: [], tpConstraints: cto, tpDefault: def, tpMeta: meta};
	}

	function typeName():PlacedName {
		switch (peek()) {
			case Const(CIdent(name)):
				var p = next().pos;
				if (isLowerIdent(name)) err("Type name should start with an uppercase letter");
				return {name: name, pos: p};
			case Dollar(name):
				var p = next().pos;
				return {name: "$" + name, pos: p};
			case _: return err("Expected type name");
		}
	}

	function parseFunParam():FunctionArg {
		var meta = parseMeta();
		var opt = false;
		var spread = false;
		if (tokEq(peek(), Question)) { junk(); opt = true; }
		else if (tokEq(peek(), TSpread)) { junk(); spread = true; }
		var name = dollarIdent();
		var t = poptTypeHint();
		var c = parseFunParamValue();
		if (spread) {
			var inner:TypeHint = (t != null) ? t : {ct: ctMono(), pos: Position.nullPos};
			var rest:TypePath = {tpackage: ["haxe"], tname: "Rest", tparams: [TPType(inner)], tsub: null};
			t = {ct: CTPath(rest), pos: inner.pos};
		}
		return {name: name, opt: opt, meta: meta, type: t, value: c};
	}

	static function ctMono():ComplexType {
		return CTPath({tpackage: ["$"], tname: "_hx_mono", tparams: [], tsub: null});
	}

	function parseFunParamValue():Null<Expr> {
		if (tokEq(peek(), TBinop(OpAssign))) { junk(); return expr(); }
		return null;
	}

	function parseFunction(p1:Position, inl:Bool):Expr {
		var name:Null<PlacedName> = null;
		switch (peek()) {
			case Const(CIdent(_)), Dollar(_):
				name = dollarIdent();
			case _:
		}
		// The cursor on a local function's name raises Exit, which leaves the whole expression
		// UNANNOTATED
		// - the name a function is about to be given is not something to complete, so the request answers
		// nothing at all.
		if (displayCompletionMode && isDisplayFile() && displayOffset >= 0) {
			var pn = name != null ? name.pos : new Position(p1.file, p1.max + 1, peekInfo().pos.min);
			if (pn.min <= displayOffset && displayOffset <= pn.max) displaySuppressed = true;
		}
		var pl = parseConstraintParams();
		expect(POpen);
		var al = psepTrailing(parseFunParam);
		expect(PClose);
		var t = poptTypeHint();
		var e = secureExpr();
		var f:Func = {fParams: pl, fArgs: al, fType: t, fExpr: e};
		var kind:FunctionKind = (name == null) ? FKAnonymous : FKNamed(name, inl);
		return new Expr(EFunction(kind, f), Position.union(p1, e.pos));
	}

	function arrowFunction(p1:Position, al:Array<FunctionArg>, er:Expr):Expr {
		var p = er.pos;
		var ret = new Expr(EMeta({name: ":implicitReturn", params: [], pos: Position.nullPos}, new Expr(EReturn(er), p)), p);
		var f:Func = {fParams: [], fArgs: al, fType: null, fExpr: ret};
		return new Expr(EFunction(FKArrow, f), Position.union(p1, p));
	}

	function arrowIdentCheckType(e:Expr):{np:PlacedName, t:Null<TypeHint>} {
		return switch (e.expr) {
			case EConst(CIdent(n)): {np: {name: n, pos: e.pos}, t: null};
			case ECheckType(inner, t):
				switch (inner.expr) {
					case EConst(CIdent(n)): {np: {name: n, pos: inner.pos}, t: t};
					case _: serror();
				}
			case _: serror();
		}
	}

	function arrowFirstParam(e:Expr):FunctionArg {
		return switch (e.expr) {
			case EConst(CIdent(n)) if (n == "true" || n == "false" || n == "null" || n == "this" || n == "super"):
				err("Invalid argument name");
			case EConst(CIdent(n)):
				{name: {name: n, pos: e.pos}, opt: false, meta: [], type: null, value: null};
			case EBinop(OpAssign, e1, e2):
				var r = arrowIdentCheckType(e1);
				{name: r.np, opt: true, meta: [], type: r.t, value: e2};
			case EParenthesis(inner):
				switch (inner.expr) {
					case EBinop(OpAssign, e1, e2):
						var r = arrowIdentCheckType(e1);
						{name: r.np, opt: true, meta: [], type: r.t, value: e2};
					case _:
						var r = arrowIdentCheckType(inner);
						{name: r.np, opt: false, meta: [], type: r.t, value: null};
				}
			case _: serror();
		}
	}

	function parseArrayDecl(p1:Position):Expr {
		var el:Array<Expr> = [];
		if (tokEq(peek(), BkClose)) {
			var p2 = next().pos;
			// Under a completion runs loop_el, and gives an empty list one marked null, so an empty literal
			// holding the cursor has something to complete on (which is where the expected element type
			// comes from).
			return new Expr(EArrayDecl(gapMark(p1, p2)), Position.union(p1, p2));
		}
		el.push(secureExpr());
		var p2 = p1;
		while (true) {
			if (tokEq(peek(), Comma)) {
				var pc = next().pos;
				if (tokEq(peek(), BkClose)) {
					p2 = next().pos;
					// The cursor past the trailing comma is the element the user has not written yet.
					el = el.concat(gapMark(pc, p2));
					break;
				}
				el.push(secureExpr());
			} else if (tokEq(peek(), BkClose)) {
				p2 = next().pos; break;
			} else {
				// The missing `]` is recorded inside the display file and the elements parsed so far stand, so
				// `[<cursor>` with nothing closing it still has a node at the position to complete on.
				var np = peekInfo().pos;
				if (displayFile == null) return err("Expected , or ]");
				syntaxErrors.push({msg: Expected([",", "]"]), pos: np});
				p2 = np;
				break;
			}
		}
		return new Expr(EArrayDecl(el), Position.union(p1, p2));
	}

	function parseObjDecl(firstField:ObjectField, p0:Position):Expr {
		var acc:Array<ObjectField> = [firstField];
		var pEnd = p0;
		while (tokEq(peek(), Comma)) {
			junk();
			var key:{name:String, pos:Position, quotes:QuoteStatus};
			switch (peek()) {
				case Const(CIdent(name)): var p = next().pos; key = {name: name, pos: p, quotes: NoQuotes};
				case Const(CString(name, _)): var p = next().pos; key = {name: name, pos: p, quotes: DoubleQuotes};
				case _: break;
			}
			// A missing `:` after a field name is recorded and the value read anyway, so `{ a: 1, fie` still
			// carries `fie` as a field for completion to answer on.
			if (tokEq(peek(), DblDot)) junk();
			else syntaxError(Expected([":"]));
			var e = secureExpr();
			acc.push({name: key.name, pos: key.pos, quotes: key.quotes, expr: e});
			pEnd = e.pos;
		}
		return new Expr(EObjectDecl(acc), Position.union(p0, pEnd));
	}

	// The call parameters take a SEPARATE path in the display file: they recover argument by argument, a
	// failed one becoming a null STAND-IN spanning the gap up to the next token, and each argument is
	// marked for signature help. Keeping only the parsed prefix would leave no node under the cursor, so
	// completion inside an unfinished argument list would have nothing to answer. Both a call and a `new`
	// go through it.
	function parseCallParamsResume(pOpen:Position):{el:Array<Expr>, p2:Position} {
		if (tokEq(peek(), PClose)) {
			// An empty argument list whose parentheses hold the cursor still gets one marked null, so the
			// position has something to complete on.
			var p2 = next().pos;
			return {el: gapMark(pOpen, p2), p2: p2};
		}
		var el:Array<Expr> = [];
		var pprev = pOpen;
		while (true) {
			var e:Expr;
			try {
				e = expr();
			} catch (er:ParserError) {
				// Under a display mode the error is recorded, not raised
				syntaxErrors.push({msg: Expected(el.length == 0 ? ["expression", ")"] : ["expression"]), pos: peekInfo().pos});
				e = nullStandIn(pprev);
			}
			if (tokEq(peek(), PClose)) {
				var p2 = next().pos;
				el.push(checkSignatureMark(e, pprev, p2));
				return {el: el, p2: p2};
			}
			if (tokEq(peek(), Comma)) {
				var pc = next().pos;
				if (tokEq(peek(), PClose)) {
					var p3 = next().pos;
					el.push(checkSignatureMark(e, pprev, p3));
					// The cursor after the trailing comma is a marked null of its own, the argument the user has
					// not written yet.
					return {el: el.concat(gapMark(pc, p3)), p2: p3};
				}
				el.push(checkSignatureMark(e, pprev, pc));
				pprev = pc;
				continue;
			}
			var p2 = peekInfo().pos;
			syntaxErrors.push({msg: Expected([",", ")"]), pos: p2});
			el.push(checkSignatureMark(e, pprev, p2));
			return {el: el, p2: p2};
		}
	}

	function parseCallParamsList():Array<Expr> {
		var el = psepTrailing(expr);
		if (!tokEq(peek(), PClose))
			throw new ParserError(Expected(el.length == 0 ? ["expression", ")"] : [",", ")"]), peekInfo().pos);
		return el;
	}

	function parseSwitchCases():{cases:Array<SwitchCase>, def:Null<{e:Null<Expr>, pos:Position}>} {
		var cases:Array<SwitchCase> = [];
		var def:Null<{e:Null<Expr>, pos:Position}> = null;
		while (true) {
			switch (peek()) {
				case Kwd(KwdDefault):
					var p1 = next().pos;
					var pdot = expect(DblDot);
					var b = blockWithPos(p1);
					if (def != null) err("Duplicate default");
					def = (b.exprs.length == 0) ? {e: null, pos: pdot} : {e: new Expr(EBlock(b.exprs), Position.union(p1, b.pos)), pos: Position.union(p1, b.pos)};
					// The default's own body gets the same mark when the cursor is in the gap after it, so
					// `default:` with nothing written still answers.
					{
						var dm = gapMark(def.pos, peekInfo().pos);
						if (dm.length > 0)
							def = {e: (def.e == null) ? dm[0] : new Expr(EBlock(b.exprs.concat(dm)), Position.union(p1, dm[0].pos)), pos: def.pos};
					}
				case Kwd(KwdCase):
					var p1 = next().pos;
					var el = psep(Comma, exprOrVar);
					var eg = parseGuardOpt();
					// A missing `:` is recorded, not raised, so `case <cursor>` with nothing after it still forms
					// a case and the pattern the user is writing gets answered.
					var pdot = expectUnlessResume(DblDot);
					if (el.length == 0) err("case without a pattern is not allowed");
					var b = blockWithPos(p1);
					var bexpr:Null<Expr> = (b.exprs.length == 0) ? null : new Expr(EBlock(b.exprs), Position.union(p1, b.pos));
					var cpos = (b.exprs.length == 0) ? Position.union(p1, pdot) : Position.union(p1, b.pos);
					// A cursor in the gap between the end of this case and the start of the next one (or the
					// closing brace) belongs to this case body, where the pattern's captured variables are in
					// scope. The reference appends a marked null there; here the stand-in carries the display
					// position itself, which is what the toplevel collection keys off.
					var cm = gapMark(cpos, peekInfo().pos);
					if (cm.length > 0)
						bexpr = (bexpr == null) ? cm[0] : new Expr(EBlock(b.exprs.concat(cm)), Position.union(p1, cm[0].pos));
					cases.push({values: el, guard: eg, expr: bexpr, pos: cpos});
				case _:
					break;
			}
		}
		return {cases: cases, def: def};
	}

	function parseGuardOpt():Null<Expr> {
		if (tokEq(peek(), Kwd(KwdIf))) {
			junk();
			expect(POpen);
			var e = expr();
			expect(PClose);
			return e;
		}
		return null;
	}

	function exprOrVar():Expr {
		switch (peek()) {
			case Kwd(KwdVar):
				var p1 = next().pos;
				var np = dollarIdent();
				return new Expr(EVars([mkEvar(np, false)]), Position.union(p1, np.pos));
			case Kwd(KwdFinal):
				var p1 = next().pos;
				var np = dollarIdent();
				return new Expr(EVars([mkEvar(np, true)]), Position.union(p1, np.pos));
			case _:
				// The pattern falls through to secureExpr, so a case pattern the user has not written yet
				// stands in as a null over the gap. That is what puts the display position in the PATTERN,
				// where the subject type is expected, instead of leaving it to the case body where nothing
				// is expected.
				return secureExpr();
		}
	}

	static function mkEvar(np:PlacedName, isFinal:Bool):EVar {
		return {evName: np, evFinal: isFinal, evStatic: false, evType: null, evExpr: null, evMeta: []};
	}

	// Zero-catch `try e` still spans the body.
	function parseCatches(catches:Array<Catch>, pmax0:Position):{catches:Array<Catch>, max:Position} {
		var pmax = pmax0;
		while (tokEq(peek(), Kwd(KwdCatch))) {
			var p = next().pos;
			expect(POpen);
			var name = dollarIdent();
			var t:Null<TypeHint> = null;
			if (tokEq(peek(), DblDot)) {
				t = parseTypeHint();
			}
			expect(PClose);
			var e = secureExpr();
			catches.push({name: name, type: t, expr: e, pos: Position.union(p, e.pos)});
			pmax = e.pos;
		}
		return {catches: catches, max: pmax};
	}

	// A keyword where a name is expected gets a specific message instead of "Expected identifier".
	function noKeyword(what:String):Void {
		switch (peek()) {
			case Kwd(kwd): err("Keyword " + Ast.sKeyword(kwd) + " cannot be used as " + what);
			case _:
		}
	}

	function parseVarDecl(isFinal:Bool):EVar {
		var meta = parseMeta();
		noKeyword("variable name");
		var name = dollarIdent();
		var t = poptTypeHint();
		var eo:Null<Expr> = null;
		if (tokEq(peek(), TBinop(OpAssign))) { junk(); eo = secureExpr(); }
		return {evName: name, evFinal: isFinal, evStatic: false, evType: t, evExpr: eo, evMeta: meta};
	}

	// Parse block elements until failure / BrClose
	function blockWithPos(p:Position):{exprs:Array<Expr>, pos:Position} {
		var acc:Array<Expr> = [];
		var lastPos = p;
		while (true) {
			if (tokEq(peek(), BrClose) || tokEq(peek(), Eof)) break;
			if (tokEq(peek(), Kwd(KwdCase)) || tokEq(peek(), Kwd(KwdDefault))) break;
			var save = idx;
			var e:Expr;
			try {
				e = parseBlockElt();
			} catch (er:ParserError) {
				// In the DISPLAY file a failed block element records its error and the block resumes from the
				// stream position the failed attempt reached, so an incomplete construct under the cursor does
				// not abort hover/definition requests elsewhere in the file. Skipping a token there instead let
				// the block run past the field it stopped at and swallow every sibling declaration after it.
				if (isDisplayFile() && !er.msg.match(Missing_semicolon)) {
					if (idx == save) break;
					syntaxErrors.push({msg: er.msg, pos: er.pos});
					continue;
				}
				// A missing semicolon is a hard error; recovery here would silently drop the parsed element
				// instead of reporting.
				if (er.msg.match(Missing_semicolon)) throw er;
				// An attempt that consumed NOTHING is a soft failure, which ENDS the block - whoever opened
				// it then reports what it was missing. Only a partially consumed element is the non-soft
				// error.
				var consumed = idx > save;
				idx = save;
				if (consumed) throw er;
				break;
			}
			acc.push(e);
			lastPos = e.pos;
		}
		return {exprs: acc, pos: lastPos};
	}

	function parseBlockElt():Expr {
		switch (peek()) {
			case Kwd(KwdVar):
				var p1 = next().pos;
				var vl = parseVarDecls(false, p1);
				var p2 = semicolon();
				return new Expr(EVars(vl), Position.union(p1, p2));
			case Kwd(KwdFinal):
				// Could be `final x =...` var decl
				var save = idx;
				var p1 = next().pos;
				switch (peek()) {
					case Kwd(KwdVar):
						// The redundant `var` is recorded as an error and consumed, so the declaration still parses
						// as a final one. Raising instead would leave the name behind as an unresolved identifier of
						// its own.
						var p2 = next().pos;
						syntaxError(Custom("`final var` is not supported, use `final` instead"), Position.union(p1, p2));
						var vl = parseVarDecls(true, p1);
						var pEnd = semicolon();
						return new Expr(EVars(vl), Position.union(p1, pEnd));
					case Const(CIdent(_)), Dollar(_), At:
						var vl = parseVarDecls(true, p1);
						var p2 = semicolon();
						return new Expr(EVars(vl), Position.union(p1, p2));
					case _:
						idx = save;
				}
			case Kwd(KwdInline):
				var p1 = next().pos;
				if (tokEq(peek(), Kwd(KwdFunction))) {
					junk();
					var e = parseFunction(p1, true);
					semicolon();
					return e;
				}
				var e = secureExpr();
				semicolon();
				return makeMeta(":inline", [], e, p1);
			case Kwd(KwdStatic):
				next();
				if (tokEq(peek(), Kwd(KwdVar)) || tokEq(peek(), Kwd(KwdFinal))) {
					var isFinal = tokEq(peek(), Kwd(KwdFinal));
					var vp = next().pos;
					var vl = parseVarDecls(isFinal, vp);
					for (v in vl) v.evStatic = true;
					var p2 = semicolon();
					return new Expr(EVars(vl), Position.union(vp, p2));
				}
				return err("Expected var or final");
			case Kwd(KwdFunction):
				var p1 = next().pos;
				var e = parseFunction(p1, false);
				semicolon();
				return e;
			case At if (peek(1).match(DblDot) && peek(2).match(Const(CIdent("markup")))):
				// A block-level markup literal accepts but does not require a semicolon.
				var e = expr();
				if (tokEq(peek(), Semicolon)) junk();
				return e;
			case _:
		}
		var e = expr();
		semicolon();
		return e;
	}

	// A head that matches NOTHING is a soft failure and falls to the hard "Missing variable identifier" at
	// p1, which names the `var` keyword rather than whatever token turned up in place of the name.
	function parseVarDecls(isFinal:Bool, p1:Position):Array<EVar> {
		var save = idx;
		var first = try parseVarDecl(isFinal)
		catch (er:ParserError) {
			if (idx != save) throw er;
			// A KEYWORD where the name belongs is a hard error that names the keyword ("Keyword final
			// cannot be used as variable name"); anything else is a soft failure, and only that becomes
			// "Missing variable identifier".
			switch (peek()) {
				case Kwd(_): throw er;
				case _:
			}
			throw new ParserError(Custom("Missing variable identifier"), p1);
		}
		var vl:Array<EVar> = [first];
		while (tokEq(peek(), Comma)) {
			junk();
			vl.push(parseVarDecl(isFinal));
		}
		return vl;
	}

	function semicolon():Position {
		if (tokEq(peek(), Semicolon)) return next().pos;
		var li = idx - 1;
		var last = (li >= 0 && li < tokens.length) ? tokens[li] : null;
		if (last != null && tokEq(last.tok, BrClose))
			return last.pos;
		// Outside the closing-brace exemption a missing semicolon is a parse error at the next token. In
		// display mode a syntax error RECORDS without aborting the parse, which makes it a parser
		// diagnostic rather than nothing at all.
		if (isDisplayFile()) {
			syntaxErrors.push({msg: Missing_semicolon, pos: cur().pos});
			return cur().pos;
		}
		throw new ParserError(Missing_semicolon, cur().pos);
	}

	function parseField(e1:Expr, efk:EFieldKind, p:Position):Expr {
		// Opens with check_resume: a cursor sitting exactly at the dot's end completes on the receiver's
		// fields, whether or not a name follows it. Only checking the DANGLING dot below missed `foo.bar`
		// with the cursor right after the dot, which is the ordinary way an editor asks for completion.
		// The empty field name is how the request is carried here, as the dangling-dot case already does.
		// A cursor inside the field name completes on the same receiver: the reference gets there by
		// annotating the enclosing field access DKMarked) rather than at the dot, but the request and the
		// answer are the same, and the span from the dot to the end of the name is what encloses_position
		// accepts for that access.
		var resumed = checkResume(p);
		if (resumed || (displayCompletionMode && atDisplayDot(p))) {
			// The completion's SUBJECT is the field name already written, spanning back from the display
			// expression's end by that name's length. The empty field name above is only how the request
			// travels, so the name is kept here.
			displayDotName = null;
			displayDotPos = null;
			var np = peekInfo().pos;
			if (np.min == p.max) switch (peek()) {
				case Const(CIdent(n)): displayDotName = n; displayDotPos = np;
				case _:
			}
			var e = new Expr(EField(e1, "", efk), Position.union(e1.pos, p));
			// 's resume arm returns the display node - it does not run expr_next, so whatever follows the
			// dot stays in the stream and is parsed on its own. That is what ends the enclosing block at
			// `this.` + `.resume`, which in turn lets a declaration after it belong to the class rather
			// than to the function body.
			return resumed ? e : exprNext(e);
		}
		// Every name arm is guarded by `p.max = p2.min` - the field name must TOUCH the dot. `k.` with
		// the name on the next line is not a field access at all, so the name stays a statement of its own.
		var adjacent = peekInfo().pos.min == p.max;
		switch (peek()) {
			case Kwd(KwdMacro) if (adjacent):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "macro", efk), Position.union(e1.pos, p2)));
			case Kwd(KwdExtern) if (adjacent):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "extern", efk), Position.union(e1.pos, p2)));
			case Kwd(KwdFunction) if (adjacent):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "function", efk), Position.union(e1.pos, p2)));
			case Kwd(KwdNew) if (adjacent):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "new", efk), Position.union(e1.pos, p2)));
			case Const(CIdent(f)) if (adjacent):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, f, efk), Position.union(e1.pos, p2)));
			case Dollar(v):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "$" + v, efk), Position.union(e1.pos, p2)));
			case _:
				// Integer followed by dot -> float
				switch (e1.expr) {
					case EConst(CInt(v, null)):
						return exprNext(new Expr(EConst(CFloat(v + ".", null)), Position.union(p, e1.pos)));
					case _:
						// A dangling dot at the display position is a field-completion request: keep an
						// empty field access so typing resolves (and reports on) the receiver.
						// (display_expr EDisplay DKDot).
						if (atDisplayDot(p)) return exprNext(new Expr(EField(e1, "", EFNormal), Position.union(e1.pos, p)));
						return serror();
				}
		}
	}

	// The token if it is there, otherwise syntaxError, which records rather than raises inside the display
	// file and stands the next position in.
	function expectUnlessResume(t:Token):Position {
		if (tokEq(peek(), t)) return next().pos;
		var np = peekInfo().pos;
		if (displayFile == null) throw new ParserError(Expected([Ast.sToken(t)]), np);
		syntaxErrors.push({msg: Expected([Ast.sToken(t)]), pos: np});
		return np;
	}

	function secureExpr():Expr {
		// A token that cannot start an expression reports Expected expression there. .
		switch (peek()) {
			case PClose | BrClose | BkClose | Semicolon | Comma | Eof:
				var np = peekInfo().pos;
				// Under a display mode the error is recorded rather than raised, and a null stands in for the
				// missing expression. Its position spans the GAP from just past the last token to just inside
				// the next one, so a cursor sitting in that gap is enclosed by the stand-in and gets answered
				// there instead of the parse aborting.
				if (isDisplayFile()) {
					syntaxErrors.push({msg: Expected(["expression"]), pos: np});
					var last = tokens[idx > 0 ? idx - 1 : 0];
					// A value-like last token contributes one more character, which is what puts the gap start
					// past a bare identifier or keyword
					var offset = switch (last.tok) {
						case Const(_) | Kwd(_) | Dollar(_): 1;
						case _: 0;
					};
					return new Expr(EConst(CIdent("null")),
						new Position(last.pos.file, last.pos.max + offset, np.max - 1));
				}
				throw new ParserError(Expected(["expression"]), np);
			case _:
		}
		// secureExpr is `expr` with a CATCH-ALL fallback, not a fixed token list, so any other token that
		// cannot start an expression stands in too. The fallback is reached only when the attempt consumed
		// NOTHING (a soft failure); a partially consumed one propagates, which is the `idx != save` test.
		// Outside a display file the original error stands, so no existing message changes.
		var save = idx;
		var np = peekInfo().pos;
		try {
			return expr();
		} catch (er:ParserError) {
			if (idx != save || displayFile == null) throw er;
			syntaxErrors.push({msg: Expected(["expression"]), pos: np});
			var last = tokens[idx > 0 ? idx - 1 : 0];
			var offset = switch (last.tok) {
				case Const(_) | Kwd(_) | Dollar(_): 1;
				case _: 0;
			};
			return new Expr(EConst(CIdent("null")),
				new Position(last.pos.file, last.pos.max + offset, np.max - 1));
		}
	}

	function parseMacroExpr(p:Position):Expr {
		switch (peek()) {
			case DblDot:
				next();
				var th = parseComplexType();
				return Reification.reifyComplexType(th.ct, p, inMacro);
			case Kwd(KwdClass), Kwd(KwdInterface):
				var d = parseClassForMacro();
				return Reification.reifyTypeDef(d, p, inMacro);
			// A declaration reifies as an EVars node of its own, rather than going through the expression
			// grammar
			case Kwd(KwdVar):
				var p1 = next().pos;
				return Reification.reifyExpr(new Expr(EVars(psep(Comma, function() return parseVarDecl(false))), p1), inMacro);
			case Kwd(KwdFinal):
				var p1 = next().pos;
				switch (peek()) {
					case Kwd(KwdVar):
						var p2 = next().pos;
						syntaxError(Custom("`final var` is not supported, use `final` instead"), Position.union(p1, p2));
					case _:
				}
				return Reification.reifyExpr(new Expr(EVars(psep(Comma, function() return parseVarDecl(true))), p1), inMacro);
			case _:
		}
		var e = secureExpr();
		return Reification.reifyExpr(e, inMacro);
	}

	function parseClassForMacro():TypeDecl {
		var fp = parseClassFlags();                             
		var p1 = fp.pos;
		var name:PlacedName = switch (peek()) {
			case Const(CIdent(_)), Dollar(_): typeName();
			case _: {name: "", pos: Position.nullPos};
		};
		var tl = parseConstraintParams();
		var hl:Array<ClassFlag> = [];
		while (true) {
			switch (peek()) {
				case Kwd(KwdExtends):
					junk();
					hl.push(HExtends(parseTypePath()));
				case Kwd(KwdImplements):
					junk();
					hl.push(HImplements(parseTypePath()));
				case _:
					break;
			}
		}
		expect(BrOpen);
		var cf = parseClassFields(true, p1); // Tdecl is true: this class needs no name
		var flags = fp.flags.concat(hl);
		var def:Definition<ClassFlag, Array<ClassField>> = {
			dName: name, dDoc: null, dParams: tl, dMeta: [], dFlags: flags, dData: cf.fields,
		};
		return {decl: EClass(def), pos: Position.union(p1, cf.pos)};
	}

	function expr():Expr {
		switch (peek()) {
			case At:
				var entry = parseMetaEntry();
				var e = secureExpr();
				return makeMeta(entry.name, entry.params, e, entry.pos);
			case BrOpen:
				var p1 = next().pos;
				var b = block1(p1);
				// Under a display mode a missing } is recorded and the block is closed at the next token's
				// position ("guess the last position"), so a truncated body does not abort the whole parse.
				var p2 = if (!tokEq(peek(), BrClose) && isDisplayFile()) {
					syntaxErrors.push({msg: Expected(["}"]), pos: peekInfo().pos});
					peekInfo().pos;
				} else expect(BrClose);
				var e = new Expr(b, Position.union(p1, p2));
				return switch (b) {
					case EObjectDecl(_): exprNext(e);
					case _: e;
				}
			case Kwd(KwdMacro):
				// `macro.field` -> field access on ident "macro"
				// otherwise -> parseMacroExpr (reification).
				var p = next().pos;
				if (tokEq(peek(), Dot)) {
					var pd = next().pos;
					return parseField(new Expr(EConst(CIdent("macro")), p), EFNormal, pd);
				}
				return parseMacroExpr(p);
			case Kwd(KwdVar):
				var p1 = next().pos;
				var vl = parseVarDecls(false, p1);
				return new Expr(EVars(vl), p1);
			case Kwd(KwdFinal):
				var p1 = next().pos;
				// The redundant `var` is recorded as an error and consumed, so the declaration still parses as
				// a final one.
				switch (peek()) {
					case Kwd(KwdVar):
						var p2 = next().pos;
						syntaxError(Custom("`final var` is not supported, use `final` instead"), Position.union(p1, p2));
					case _:
				}
				var vl = parseVarDecls(true, p1);
				return new Expr(EVars(vl), p1);
			case Const(c):
				var p = next().pos;
				return exprNext(new Expr(EConst(c), p));
			case Kwd(KwdThis):
				var p = next().pos; return exprNext(new Expr(EConst(CIdent("this")), p));
			case Kwd(KwdAbstract):
				var p = next().pos; return exprNext(new Expr(EConst(CIdent("abstract")), p));
			case Kwd(KwdTrue):
				var p = next().pos; return exprNext(new Expr(EConst(CIdent("true")), p));
			case Kwd(KwdFalse):
				var p = next().pos; return exprNext(new Expr(EConst(CIdent("false")), p));
			case Kwd(KwdNull):
				var p = next().pos; return exprNext(new Expr(EConst(CIdent("null")), p));
			case Kwd(KwdCast):
				return parseCast();
			case Kwd(KwdThrow):
				// EThrow keeps the KEYWORD token position only, no union with the thrown value.
				var p = next().pos;
				var e = expr();
				return new Expr(EThrow(e), p);
			case Kwd(KwdNew):
				return parseNew();
			case POpen:
				return parseParen();
			case BkOpen:
				var p1 = next().pos;
				var e = parseArrayDecl(p1);
				return exprNext(e);
			case Kwd(KwdFunction):
				var p1 = next().pos;
				return parseFunction(p1, false);
			case TUnop(op):
				var p1 = next().pos;
				var e = expr();
				return makeUnop(op, e, p1);
			case TSpread:
				var p1 = next().pos;
				var e = expr();
				return makeUnop(Spread, e, Position.union(p1, e.pos));
			case TBinop(OpSub):
				var p1 = next().pos;
				var e = expr();
				return makeUnop(Neg, e, p1);
			case Kwd(KwdFor):
				var p = next().pos;
				expect(POpen);
				var it = secureExpr();
				// A missing `)` is recorded and the loop body stands in as null
				var e = if (tokEq(peek(), PClose)) {
					next();
					secureExpr();
				} else {
					syntaxError(Expected([")"]));
					mkNullExpr(it.pos);
				}
				return new Expr(EFor(it, e), Position.union(p, e.pos));
			case Kwd(KwdIf):
				return parseIf();
			case Kwd(KwdReturn):
				var p = next().pos;
				var save = idx;
				try {
					var e = expr();
					return new Expr(EReturn(e), Position.union(p, e.pos));
				} catch (er:ParserError) {
					idx = save;
					return new Expr(EReturn(null), p);
				}
			case Kwd(KwdBreak):
				var p = next().pos; return new Expr(EBreak, p);
			case Kwd(KwdContinue):
				var p = next().pos; return new Expr(EContinue, p);
			case Kwd(KwdWhile):
				var p1 = next().pos;
				expect(POpen);
				var cond = secureExpr();
				// A missing `)` is recorded and the loop body stands in as null
				var e = if (tokEq(peek(), PClose)) {
					next();
					secureExpr();
				} else {
					syntaxError(Expected([")"]));
					mkNullExpr(cond.pos);
				}
				return new Expr(EWhile(cond, e, NormalWhile), Position.union(p1, e.pos));
			case Kwd(KwdDo):
				var p1 = next().pos;
				var e = secureExpr();
				// A missing `while` is recorded and the body alone stands in (the `do` is ignored), so an
				// unfinished loop body still answers.
				if (!tokEq(peek(), Kwd(KwdWhile)) && isDisplayFile()) {
					syntaxErrors.push({msg: Expected(["while"]), pos: peekInfo().pos});
					return e;
				}
				expect(Kwd(KwdWhile));
				expect(POpen);
				var cond = secureExpr();
				// Recorded rather than raised in the display file, as expectUnlessResume does
				var p2 = if (!tokEq(peek(), PClose) && isDisplayFile()) {
					syntaxErrors.push({msg: Expected([")"]), pos: peekInfo().pos});
					peekInfo().pos;
				} else expect(PClose);
				return new Expr(EWhile(cond, e, DoWhile), Position.union(p1, p2));
			case Kwd(KwdSwitch):
				var p1 = next().pos;
				var e = secureExpr();
				// A missing `{` is recorded and the switch stands in with no cases, so a subject still
				// under construction is reachable.
				if (!tokEq(peek(), BrOpen)) {
					syntaxError(Expected(["{"]));
					return new Expr(ESwitch(e, [], null), Position.union(p1, e.pos));
				}
				next();
				var sw = parseSwitchCases();
				// Ignore a missing } and "guess" the last position
				var p2 = if (!tokEq(peek(), BrClose) && isDisplayFile()) {
					syntaxErrors.push({msg: Expected(["}"]), pos: peekInfo().pos});
					peekInfo().pos;
				} else expect(BrClose);
				return new Expr(ESwitch(e, sw.cases, sw.def), Position.union(p1, p2));
			case Kwd(KwdTry):
				var p1 = next().pos;
				var e = secureExpr();
				var cs = parseCatches([], e.pos);
				return new Expr(ETry(e, cs.catches), Position.union(p1, cs.max));
			case IntInterval(i):
				var p1 = next().pos;
				var e2 = expr();
				return makeBinop(OpInterval, new Expr(EConst(CInt(i, null)), p1), e2);
			case Kwd(KwdUntyped):
				var p1 = next().pos;
				var e = secureExpr();
				return new Expr(EUntyped(e), Position.union(p1, e.pos));
			case Dollar(v):
				var p = next().pos;
				return exprNext(new Expr(EConst(CIdent("$" + v)), p));
			case Kwd(KwdInline):
				var p = next().pos;
				var e = secureExpr();
				return makeMeta(":inline", [], e, p);
			case _:
				return serror();
		}
	}

	function parseCast():Expr {
		var p1 = next().pos;
		if (tokEq(peek(), POpen)) {
			var pp = next().pos;
			var e = expr();
			if (tokEq(peek(), Comma)) {
				junk();
				var t = parseComplexType();
				var p2 = expect(PClose);
				return exprNext(new Expr(ECast(e, t), Position.union(p1, p2)));
			} else if (tokEq(peek(), DblDot)) {
				var t = parseTypeHint();
				var p2 = expect(PClose);
				var ep = new Expr(EParenthesis(new Expr(ECheckType(e, t), Position.union(p1, p2))), Position.union(p1, p2));
				return exprNext(new Expr(ECast(ep, null), Position.union(p1, ep.pos)));
			} else {
				var p2 = expect(PClose);
				var ep = exprNext(new Expr(EParenthesis(e), Position.union(pp, p2)));
				return exprNext(new Expr(ECast(ep, null), Position.union(p1, ep.pos)));
			}
		}
		var e = secureExpr();
		return exprNext(new Expr(ECast(e, null), Position.union(p1, e.pos)));
	}

	function parseNew():Expr {
		var p1 = next().pos;
		// `new <cursor>` yields the MAGIC type path rather than failing, and the missing `(` is recorded,
		// so the ENew node exists for the completion to be filtered through.
		var save = idx;
		var t:PlacedTypePath;
		try t = parseTypePath() catch (er:ParserError) {
			if (idx != save) throw er;
			idx = save;
			if (!wouldSkipDisplayPosition(p1, true)) throw er;
			t = {path: magicTypePath(), pos: new Position(p1.file, displayOffset, displayOffset)};
		}
		if (!tokEq(peek(), POpen) && isDisplayFile()) {
			syntaxErrors.push({msg: Expected(["("]), pos: peekInfo().pos});
			return new Expr(ENew(t, []), Position.union(p1, t.pos));
		}
		if (tokEq(peek(), POpen)) {
			var pOpen = next().pos;
			if (isDisplayFile()) {
				var r = parseCallParamsResume(pOpen);
				return exprNext(new Expr(ENew(t, r.el), Position.union(p1, r.p2)));
			}
			var el = parseCallParamsList();
			var p2 = expect(PClose);
			return exprNext(new Expr(ENew(t, el), Position.union(p1, p2)));
		}
		return err("Expected (");
	}

	function parseParen():Expr {
		var p1 = next().pos;
		if (tokEq(peek(), PClose)) {
			var p2 = next().pos;
			var er = arrowExpr();
			return arrowFunction(p1, [], er);
		}
		// (?ident,...) ->...
		if (tokEq(peek(), Question)) {
			var save = idx;
			try {
				junk();
				var al = psepTrailing(parseFunParam);
				if (al.length > 0) al[0] = {name: al[0].name, opt: true, meta: [], type: al[0].type, value: al[0].value};
				expect(PClose);
				var er = arrowExpr();
				return arrowFunction(p1, al, er);
			} catch (e:ParserError) {
				idx = save;
			}
		}
		var e = expr();
		switch (peek()) {
			case PClose:
				var p2 = next().pos;
				return exprNext(new Expr(EParenthesis(e), Position.union(p1, p2)));
			case Comma:
				junk();
				var al = psepTrailing(parseFunParam);
				expect(PClose);
				var er = arrowExpr();
				return arrowFunction(p1, [arrowFirstParam(e)].concat(al), er);
			case DblDot:
				var t = parseTypeHint();
				switch (peek()) {
					case PClose:
						var p2 = next().pos;
						return exprNext(new Expr(EParenthesis(new Expr(ECheckType(e, t), Position.union(p1, p2))), Position.union(p1, p2)));
					case Comma:
						junk();
						var al = psepTrailing(parseFunParam);
						expect(PClose);
						var er = arrowExpr();
						var r = arrowIdentCheckType(e);
						var first:FunctionArg = {name: r.np, opt: false, meta: [], type: t, value: null};
						return arrowFunction(p1, [first].concat(al), er);
					case TBinop(OpAssign):
						junk();
						var ea1 = expr();
						// (e: t = ea1,...) -> er
						var al2:Array<FunctionArg>;
						if (tokEq(peek(), PClose)) {
							junk();
							al2 = [];
						} else {
							expect(Comma);
							al2 = psepTrailing(parseFunParam);
							expect(PClose);
						}
						var er = arrowExpr();
						switch (e.expr) {
							case EConst(CIdent(n)):
								var first:FunctionArg = {name: {name: n, pos: e.pos}, opt: true, meta: [], type: t, value: ea1};
								return arrowFunction(p1, [first].concat(al2), er);
							case _: return serror();
						}
					case _:
						return serror();
				}
			case _:
				// A missing `)` is recorded and the parenthesis closes at the end of the expression inside
				// it, then parsing continues. Raising here would lose the whole statement, and with it any
				// display node the recovery had already built inside.
				syntaxError(Expected([")", ",", ":"]));
				return exprNext(new Expr(EParenthesis(e), Position.union(p1, e.pos)));
		}
	}

	function arrowExpr():Expr {
		expect(Arrow);
		return expr();
	}

	function parseIf():Expr {
		var p = next().pos;
		expect(POpen);
		var cond = secureExpr();
		// A missing `)` is recorded and the then-branch stands in as null
		var e1 = if (tokEq(peek(), PClose)) {
			next();
			secureExpr();
		} else {
			syntaxError(Expected([")"]));
			mkNullExpr(cond.pos);
		}
		var e2:Null<Expr> = null;
		if (tokEq(peek(), Kwd(KwdElse))) {
			junk();
			e2 = secureExpr();
		} else if (tokEq(peek(), Semicolon) && tokEq(peek(1), Kwd(KwdElse))) {
			junk(); junk();
			e2 = secureExpr();
		}
		var endPos = (e2 == null) ? e1.pos : e2.pos;
		return new Expr(EIf(cond, e1, e2), Position.union(p, endPos));
	}

	function isDollarIdent(e:Expr):Bool {
		// Only idents that start with '$'.
		return switch (e.expr) {
			case EConst(CIdent(n)): n.charCodeAt(0) == '$'.code;
			case _: false;
		}
	}

	function exprNext(e1:Expr):Expr {
		switch (peek()) {
			case BrOpen if (isDollarIdent(e1)):
				// `$ident{...}` macro reification meta: an EMeta named after the identifier
				var p1 = next().pos;
				var eparam = expr();
				var p2 = expect(BrClose);
				switch (e1.expr) {
					case EConst(CIdent(n)):
						return exprNext(new Expr(EMeta({name: n, params: [], pos: e1.pos}, eparam), Position.union(p1, p2)));
					case _: return serror();
				}
			case Dot:
				var p = next().pos;
				return parseField(e1, EFNormal, p);
			case QuestionDot:
				var p = next().pos;
				return parseField(e1, EFSafe, p);
			case POpen:
				var p1 = next().pos;
				// The call parameters take a SEPARATE path in the display file: they recover argument by
				// argument and a failed one becomes a null STAND-IN spanning the gap up to the next token.
				// Keeping only the parsed prefix would leave no node under the cursor, so completion inside
				// an unfinished argument list would have nothing to answer at all.
				if (isDisplayFile()) {
					var r = parseCallParamsResume(p1);
					return exprNext(new Expr(ECall(e1, r.el), Position.union(e1.pos, r.p2)));
				}
				var el = psepTrailing(expr);
				if (tokEq(peek(), PClose)) {
					var p2 = next().pos;
					return exprNext(new Expr(ECall(e1, el), Position.union(e1.pos, p2)));
				}
				throw new ParserError(Expected(el.length == 0 ? ["expression", ")"] : [",", ")"]), peekInfo().pos);
			case BkOpen:
				var p1 = next().pos;
				var e2 = secureExpr();
				// A missing ] is recorded, not raised, and the index carries the signature mark like a call
				// argument does.
				var p2 = if (!tokEq(peek(), BkClose) && isDisplayFile()) {
					syntaxErrors.push({msg: Expected(["]"]), pos: peekInfo().pos});
					peekInfo().pos;
				} else expect(BkClose);
				e2 = checkSignatureMark(e2, p1, p2);
				return exprNext(new Expr(EArray(e1, e2), Position.union(e1.pos, p2)));
			case Arrow:
				var pa = next().pos;
				var er = secureExpr();
				return arrowFunction(e1.pos, [arrowFirstParam(e1)], er);
			case TBinop(OpGt):
				return exprNextGt(e1);
			case TBinop(op):
				junk();
				var e2 = secureExpr();
				return makeBinop(op, e1, e2);
			case TSpread:
				junk();
				var e2 = secureExpr();
				return makeBinop(OpInterval, e1, e2);
			case TUnop(op) if (isPostfix(e1, op)):
				var p = next().pos;
				return exprNext(new Expr(EUnop(op, Postfix, e1), Position.union(e1.pos, p)));
			case Question:
				junk();
				var e2 = expr();
				// A missing `:` is recorded and the then branch alone stands in for the whole conditional, so a
				// cursor inside it is still reachable.
				if (!tokEq(peek(), DblDot)) {
					syntaxError(Expected([":"]));
					return e2;
				}
				next();
				var e3 = expr();
				return new Expr(ETernary(e1, e2, e3), Position.union(e1.pos, e3.pos));
			case Kwd(KwdIn):
				junk();
				var e2 = expr();
				return makeBinop(OpIn, e1, e2);
			case Const(CIdent("is")):
				junk();
				var t = parseComplexType();
				var eis = new Expr(EIs(e1, t), Position.union(e1.pos, t.pos));
				return exprNext(eis);
			case _:
				return e1;
		}
	}

	// `>`-recombination: >>, >>>, >=, >>=, >>>= using token adjacency
	function exprNextGt(e1:Expr):Expr {
		var p1 = next().pos; // First >
		if (tokEq(peek(), TBinop(OpGt)) && peekInfo().pos.min == p1.max) {
			var p2 = next().pos;
			if (tokEq(peek(), TBinop(OpGt)) && peekInfo().pos.min == p2.max) {
				var p3 = next().pos;
				if (tokEq(peek(), TBinop(OpAssign)) && peekInfo().pos.min == p3.max) {
					junk();
					var e2 = expr();
					return makeBinop(OpAssignOp(OpUShr), e1, e2);
				}
				var e2 = secureExpr();
				return makeBinop(OpUShr, e1, e2);
			}
			if (tokEq(peek(), TBinop(OpAssign)) && peekInfo().pos.min == p2.max) {
				junk();
				var e2 = expr();
				return makeBinop(OpAssignOp(OpShr), e1, e2);
			}
			var e2 = secureExpr();
			return makeBinop(OpShr, e1, e2);
		}
		if (tokEq(peek(), TBinop(OpAssign)) && peekInfo().pos.min == p1.max) {
			junk();
			var e2 = secureExpr();
			return makeBinop(OpGte, e1, e2);
		}
		var e2 = secureExpr();
		return makeBinop(OpGt, e1, e2);
	}

	function block1(p1:Position):ExprDef {
		switch (peek()) {
			case Const(CIdent(name)):
				var p = next().pos;
				return block2({name: name, pos: p, quotes: NoQuotes}, CIdent(name), p);
			case Const(CString(name, qs)):
				var p = next().pos;
				return block2({name: name, pos: p, quotes: DoubleQuotes}, CString(name, qs), p);
			case _:
				var b = blockWithPos(p1);
				return EBlock(b.exprs);
		}
	}

	function block2(key:{name:String, pos:Position, quotes:QuoteStatus}, ident:Constant, p:Position):ExprDef {
		if (tokEq(peek(), DblDot)) {
			junk();
			var e = secureExpr();
			var od = parseObjDecl({name: key.name, pos: key.pos, quotes: key.quotes, expr: e}, p);
			return od.expr;
		}
		// The first element goes through the block recovery TOO, so a failure while reading it is recovered
		// exactly like any later one - recorded, the element dropped, the block continuing from where the
		// attempt stopped. Parsing it outside the recovery would let one broken statement take the whole
		// enclosing block with it.
		var acc:Array<Expr> = [];
		var save = idx;
		var first:Null<Expr> = null;
		try {
			first = exprNext(new Expr(EConst(ident), p));
			semicolon();
		} catch (er:ParserError) {
			if (!isDisplayFile() || idx == save) throw er;
			syntaxErrors.push({msg: er.msg, pos: er.pos});
			first = null;
		}
		if (first != null) acc.push(first);
		var rest = blockWithPos(p);
		for (e in rest.exprs) acc.push(e);
		// A block holding exactly the identifier under the cursor is really the start of a STRUCTURE
		// literal - `{ fie` and `{ fie }` both parse as blocks - so it becomes an object declaration with
		// that one field, whose value stands at a null position so nothing downstream reads it as written.
		// This is decided on the PARSED tree, before any block a later stage synthesizes exists.
		if (acc.length == 1 && displayCompletionMode && ident.match(CIdent(_)) && acc[0] == first
				&& first.expr.match(EConst(CIdent(_))) && isDisplayFile()
				&& p.min <= displayOffset && displayOffset <= p.max)
			return EObjectDecl([{
				name: key.name, pos: key.pos, quotes: NoQuotes,
				expr: new Expr(EConst(CIdent("null")), Position.nullPos)
			}]);
		return EBlock(acc);
	}

	// Module / declaration GRAMMAR Display-mode / error-resume paths are intentionally omitted: on
	// unexpected input we throw ParserError (batch compile only).

	/**
		Lex + parse a whole module (file): `package` + type declarations until EOF.
	*/
	public static function parseModuleString(src:String, file:String = "?", ?defines:Define):Package {
		var p = make(src, file, defines);
		return p.parseFile();
	}

	function parseFile():Package {
		if (tokEq(peek(), Kwd(KwdPackage))) {
			junk();
			var pack = parsePackage();
			// `package <Ident>` with empty pack is an error in the reference,
			// but only when pack=[] and next is an uppercase ident; we keep it
			// lenient-but-faithful: require a semicolon to close the package.
			semicolon();
			var l = parseTypeDecls(pack, 1, tokens[idx > 0 ? idx - 1 : 0].pos.max);
			return {pack: pack, decls: l};
		}
		var l = parseTypeDecls([]);
		return {pack: [], decls: l};
	}

	function parsePackage():Array<String> {
		// Dot-separated lowercase identifiers (or `macro`)
		var acc:Array<String> = [];
		var save = idx;
		var first = lowerIdentOrMacroOpt();
		if (first == null) { idx = save; return acc; }
		acc.push(first);
		while (tokEq(peek(), Dot)) {
			junk();
			var n = lowerIdentOrMacroOpt();
			if (n == null) break;
			acc.push(n);
		}
		return acc;
	}

	function lowerIdentOrMacroOpt():Null<String> {
		return switch (peek()) {
			case Const(CIdent(i)) if (isLowerIdent(i)): junk(); i;
			case Kwd(KwdMacro): junk(); "macro";
			case Kwd(KwdExtern): junk(); "extern";
			case Kwd(KwdFunction): junk(); "function";
			case _: null;
		}
	}

	// Walk BACK over the tokens that merely prefix a declaration (a `private`, a metadata entry with or
	// without its call parentheses) so the skip stops in front of the declaration itself rather than in the
	// middle of its prefix, then drop k tokens. The window is read back to front, so index 0 below is the
	// k-th token ahead.
	function junkTokens(k:Int):Void {
		while (k > 0) {
			inline function tok(i:Int):Token return peek(k - 1 - i);
			if (tok(0).match(Kwd(KwdPrivate))) { k--; continue; }
			var isName = switch (tok(0)) {
				case Const(CIdent(_)) | Kwd(_): true;
				case _: false;
			};
			if (isName && k >= 2 && tok(1).match(At)) { k = k - 2; continue; }
			if (isName && k >= 3 && tok(1).match(DblDot) && tok(2).match(At)) { k = k - 3; continue; }
			if (tok(0).match(PClose)) {
				// Count matching parentheses back to the metadata call's opening one.
				var n = 0, i = 1;
				while (i < k) {
					switch (tok(i)) {
						case POpen: if (n == 0) break; n--;
						case PClose: n++;
						case _:
					}
					i++;
				}
				var nameAt = i + 1;
				var nameIsName = nameAt < k ? (switch (tok(nameAt)) { case Const(CIdent(_)) | Kwd(_): true; case _: false; }) : false;
				if (nameIsName && nameAt + 1 < k && tok(nameAt + 1).match(At)) { k = k - (nameAt + 2); continue; }
				if (nameIsName && nameAt + 2 < k && tok(nameAt + 1).match(DblDot) && tok(nameAt + 2).match(At)) { k = k - (nameAt + 3); continue; }
			}
			break;
		}
		idx += k;
	}

	// Resume: skip forward to the next plausible declaration start so a broken one does not abort the
	// whole file. Returns true when a field start was found (the caller retries a field), false at a
	// closing brace, a type keyword or Eof (the caller stops).
	function resumeScan(tdecl:Bool, fdecl:Bool):Bool {
		var k = 1;
		while (true) {
			if (idx + k - 1 >= tokens.length) return false;
			inline function tok(i:Int):Token return peek(k - 1 - i);
			var t0 = tok(0);
			var t1 = k >= 2 ? tok(1) : null;
			var t2 = k >= 3 ? tok(2) : null;
			var isKwd = t0.match(Kwd(_));
			if (isKwd && t1 != null && t1.match(At)) { k++; continue; }
			if (isKwd && t1 != null && t2 != null && t1.match(DblDot) && t2.match(At)) { k++; continue; }
			if (fdecl) {
				var fieldStart = switch [t0, t1] {
					case [Const(_), Kwd(KwdFunction)]: true;
					case [Kwd(KwdNew), Kwd(KwdFunction)]: true;
					case _: false;
				};
				if (fieldStart) { junkTokens(k - 2); return true; }
				switch (t0) {
					case Kwd(KwdMacro) | Kwd(KwdPublic) | Kwd(KwdStatic) | Kwd(KwdVar) | Kwd(KwdFinal)
						| Kwd(KwdOverride) | Kwd(KwdDynamic) | Kwd(KwdInline) | Kwd(KwdOverload):
						junkTokens(k - 1);
						return true;
					case _:
				}
			}
			if (tdecl && t0.match(BrClose)) { junkTokens(k - 1); return false; }
			switch (t0) {
				case Eof | Kwd(KwdImport) | Kwd(KwdUsing) | Kwd(KwdExtern) | Kwd(KwdClass)
					| Kwd(KwdInterface) | Kwd(KwdEnum) | Kwd(KwdTypedef) | Kwd(KwdAbstract):
					junkTokens(k - 1);
					return false;
				case _:
			}
			k++;
		}
	}

	// With the cursor in the GAP between the previous declaration and the next token, the answer is which
	// declaration keywords may start here: the flags and type keywords, plus import/using once a package
	// has been seen and package as well before that, and none of them inside import.hx.
	function typeDeclKeywords(mode:Int):Array<String> {
		var inImportHx = StringTools.endsWith(StringTools.replace(file, "\\", "/"), "/import.hx") || file == "import.hx";
		var l = inImportHx ? [] : ["private", "extern", "class", "interface", "enum", "abstract", "typedef", "final"];
		return switch (mode) {
			case 0: ["package", "import", "using"].concat(l);
			case 1: ["import", "using"].concat(l);
			case _: l;
		};
	}

	function checkTypeDeclCompletion(mode:Int, pmax:Int):Void {
		if (!displayCompletionMode || !isDisplayFile() || displayOffset < 0) return;
		var nextPmin = tokEq(peek(), Eof) ? 0x3FFFFFFF : peekInfo().pos.min;
		if (!(pmax <= displayOffset && nextPmin >= displayOffset)) return;
		delayedSyntaxCompletion = typeDeclKeywords(mode);
		// The subject is the identifier the cursor is IN when the next token is one, at that token's
		// position; otherwise no name, at the next token's position.
		var np = peekInfo().pos;
		var sname:Null<String> = switch (peek()) {
			case Const(CIdent(n)) if (np.min <= displayOffset && displayOffset <= np.max): n;
			case _: null;
		};
		delayedSyntaxSubject = {name: sname, pos: np};
	}

	function parseTypeDecls(pack:Array<String>, mode:Int = 0, pmax:Int = -1):Array<TypeDecl> {
		var acc:Array<TypeDecl> = [];
		while (true) {
			checkTypeDeclCompletion(mode, pmax);
			if (tokEq(peek(), Eof)) break;
			var save = idx;
			var td:TypeDecl;
			try {
				td = parseTypeDecl(mode);
			} catch (e:ParserError) {
				// In the display file the error is recorded and the scan skips to the next plausible
				// declaration, so one broken declaration does not cost the answer for the rest of the file.
				if (isDisplayFile()) {
					syntaxErrors.push({msg: e.msg, pos: e.pos});
					if (idx == save) idx++;
					resumeScan(false, false);
					continue;
				}
				// No error-recovery in batch mode: rethrow if we made progress past EOF
				idx = save;
				if (tokEq(peek(), Eof)) break;
				throw e;
			}
			acc.push(td);
			// An import or using keeps imports available, anything else closes that window.
			mode = switch (td.decl) { case EImport(_) | EUsing(_): 1; case _: 2; };
			pmax = td.pos.max;
		}
		return acc;
	}

	// A cursor sitting after a type-declaration flag (`extern `, `final `, ...) asks which declaration
	// keywords may still follow it: class and interface always, plus the flags not already given, and
	// final additionally opens enum/abstract/typedef.
	function checkTypeDeclFlagCompletion(mode:Int, flags:Array<{flag:DeclFlag, pos:Position}>):Void {
		if (!displayCompletionMode || !isDisplayFile()) return;
		function has(f:DeclFlag):Bool {
			for (x in flags) if (Type.enumEq(x.flag, f)) return true;
			return false;
		}
		// Class and interface always, plus the flags not already given, and final additionally opens
		// enum/abstract/typedef.
		function afterFlagKeywords():Array<String> {
			var l = ["class", "interface"];
			if (!has(DPrivate)) l.unshift("private");
			if (!has(DExtern)) l.unshift("extern");
			if (!has(DFinal)) l = ["final", "enum", "abstract", "typedef"].concat(l);
			return l;
		}
		// An identifier under the cursor is an incomplete declaration - the parser would fail on it
		// anyway
		// - so it answers right here, with that name as the subject. Which list depends on whether any
		// flag
		// has been given yet.
		var np = peekInfo().pos;
		switch (peek()) {
			case Const(CIdent(name)) if (np.min <= displayOffset && displayOffset <= np.max):
				throw new hxc.compiler.DisplayXml.SyntaxCompletion(
					flags.length == 0 ? typeDeclKeywords(mode) : afterFlagKeywords(), name, np);
			case _:
		}
		if (flags.length == 0) return;
		// The cursor lies between the flag and the next token, and the subject is empty at the display
		// position
		var last = flags[flags.length - 1].pos;
		if (!(displayOffset >= last.max + 1 && displayOffset <= peekInfo().pos.max)) return;
		throw new hxc.compiler.DisplayXml.SyntaxCompletion(afterFlagKeywords(), null,
			new Position(last.file, displayOffset, displayOffset));
	}

	function parseTypeDecl(mode:Int = 2):TypeDecl {
		switch (peek()) {
			case Kwd(KwdImport):
				var p1 = next().pos;
				return parseImport(p1);
			case Kwd(KwdUsing):
				var p1 = next().pos;
				return parseUsing(p1);
			case _:
		}
		var doc = getDoc();
		var meta = parseMeta();
		var c = parseCommonFlags();
		switch (peek()) {
			case Kwd(KwdFunction):
				var p1 = next().pos;
				var name = dollarIdent();
				var pl = parseConstraintParams();
				expect(POpen);
				var args = psepTrailing(parseFunParam);
				expect(PClose);
				var t = poptTypeHint();
				var e:Null<Expr> = null;
				var p2 = p1;
				var save = idx;
				try {
					var ee = expr();
					semicolon();
					e = ee; p2 = ee.pos;
				} catch (er:ParserError) {
					if (tokEq(tokens[save].tok, BrOpen)) throw er;
					idx = save;
					p2 = semicolon();
				}
				var f:Func = {fParams: pl, fArgs: args, fType: t, fExpr: e};
				var def:Definition<PlacedAccess, ClassFieldKind> = {
					dName: name, dDoc: doc, dParams: pl, dMeta: meta,
					dFlags: filterModuleFieldFlags(c), dData: FFun(f),
				};
				return {decl: EStatic(def), pos: Position.union(p1, p2)};
			case Kwd(KwdVar):
				var p1 = next().pos;
				var name = dollarIdent();
				var kind:ClassFieldKind;
				var p2:Position;
				if (tokEq(peek(), POpen)) {
					junk();
					var i1 = propertyIdent();
					expect(Comma);
					var i2 = propertyIdent();
					expect(PClose);
					var t = poptTypeHint();
					var a = parseVarFieldAssignment();
					kind = FProp(i1, i2, t, a.e); p2 = a.pos;
				} else {
					var t = poptTypeHint();
					var a = parseVarFieldAssignment();
					kind = FVar(t, a.e); p2 = a.pos;
				}
				var def:Definition<PlacedAccess, ClassFieldKind> = {
					dName: name, dDoc: doc, dParams: [], dMeta: meta,
					dFlags: filterModuleFieldFlags(c), dData: kind,
				};
				return {decl: EStatic(def), pos: Position.union(p1, p2)};
			case Kwd(KwdEnum):
				var p1 = next().pos;
				if (tokEq(peek(), Kwd(KwdAbstract))) {
					var p1b = next().pos;
					var flags = [AbEnum].concat(convertAbstractFlags(c));
					return parseAbstract(doc, meta, flags, p1b);
				}
				var name = typeName();
				var tl = parseConstraintParams();
				expect(BrOpen);
				var l:Array<EnumConstructor> = [];
				while (!tokEq(peek(), BrClose) && !tokEq(peek(), Eof)) {
					l.push(parseEnumCtor());
				}
				var p2 = expect(BrClose);
				var def:Definition<EnumFlag, Array<EnumConstructor>> = {
					dName: name, dDoc: doc, dParams: tl, dMeta: meta,
					dFlags: filterEnumFlags(c), dData: l,
				};
				return {decl: EEnum(def), pos: Position.union(p1, p2)};
			case Kwd(KwdClass), Kwd(KwdInterface):
				var fp = parseClassFlags();
				return parseClassContent(doc, meta, c, fp.flags, fp.pos);
			case Kwd(KwdTypedef):
				var p1 = next().pos;
				var name = typeName();
				var tl = parseConstraintParams();
				// The `=` is a plain pattern element, so a different token there is an error with no message,
				// reported as `Unexpected <token>`, not as an expectation.
				if (!tokEq(peek(), TBinop(OpAssign))) serror();
				var pAssign = expect(TBinop(OpAssign));
				// The typedef's right-hand side goes through parseComplexTypeAt, so `typedef Foo =
				// <cursor>` reaches the typer as the magic path and answers a type hint completion instead
				// of failing the declaration.
				var t = parseComplexTypeAt(pAssign);
				if (tokEq(peek(), Semicolon)) junk();
				var def:Definition<EnumFlag, TypeHint> = {
					dName: name, dDoc: doc, dParams: tl, dMeta: meta,
					dFlags: filterEnumFlags(c), dData: t,
				};
				return {decl: ETypedef(def), pos: Position.union(p1, t.pos)};
			case Kwd(KwdAbstract):
				var p1 = next().pos;
				var save = idx;
				try {
					return parseAbstract(doc, meta, convertAbstractFlags(c), p1);
				} catch (e:ParserError) {
					// Catching every error rewound over a fault deep inside the abstract's body and then reported
					// `Unexpected <name>` from the retry, hiding the real one.
					if (idx != save) throw e;
					idx = save;
					var c2 = parseCommonFlags();
					var fp = parseClassFlags();
					return parseClassContent(doc, meta, c.concat(c2), [HAbstract].concat(fp.flags), p1);
				}
			case _:
				// `final NAME...` module-level final var
				var rc = c.copy();
				rc.reverse();
				// The module-level field parse is ATTEMPTED, and falling out of it is what reaches the flag
				// completion. `final ` with the cursor after it is a declaration flag, not the start of a
				// final variable.
				var beforeFinal = idx;
				if (rc.length > 0 && rc[0].flag == DFinal) try {
					var p1 = rc[0].pos;
					var crest = rc.slice(1);
					crest.reverse();
					var name = dollarIdent();
					var t = poptTypeHint();
					var a = parseVarFieldAssignment();
					var flags = filterModuleFieldFlags(crest);
					flags.push({access: AFinal, pos: p1});
					var def:Definition<PlacedAccess, ClassFieldKind> = {
						dName: name, dDoc: doc, dParams: [], dMeta: meta,
						dFlags: flags, dData: FVar(t, a.e),
					};
					return {decl: EStatic(def), pos: Position.union(p1, a.pos)};
				} catch (er:ParserError) {
					idx = beforeFinal;
				}
				checkTypeDeclFlagCompletion(mode, c);
				return serror();
		}
	}

	// The block comment stored on the declaration's first token. The most recent doc comment HOLDS until a
	// getDoc consumes it, surviving across skipped tokens and distance (a well-known doc leak).
	// Token-attached docs scan forward monotonically into lastDoc.
	var lastDoc:Null<String> = null;
	var docScanIdx:Int = 0;

	function getDoc():Documentation {
		var limit = idx < tokens.length ? idx : tokens.length - 1;
		while (docScanIdx <= limit) {
			var d = tokens[docScanIdx].doc;
			if (d != null) lastDoc = d;
			docScanIdx++;
		}
		var d = lastDoc;
		lastDoc = null;
		return d == null ? null : Ast.docFromString(d);
	}

	function parseCommonFlags():Array<PlacedDeclFlag> {
		var acc:Array<PlacedDeclFlag> = [];
		while (true) {
			var f:Null<DeclFlag> = switch (peek()) {
				case Kwd(KwdPrivate): DPrivate;
				case Kwd(KwdExtern): DExtern;
				case Kwd(KwdFinal): DFinal;
				case Kwd(KwdMacro): DMacro;
				case Kwd(KwdDynamic): DDynamic;
				case Kwd(KwdInline): DInline;
				case Kwd(KwdPublic): DPublic;
				case Kwd(KwdStatic): DStatic;
				case Kwd(KwdOverload): DOverload;
				case _: null;
			}
			if (f == null) break;
			var p = next().pos;
			acc.push({flag: f, pos: p});
		}
		return acc;
	}

	static function filterModuleFieldFlags(c:Array<PlacedDeclFlag>):Array<PlacedAccess> {
		var out:Array<PlacedAccess> = [];
		for (f in c) {
			var a:Null<Access> = switch (f.flag) {
				case DPrivate: APrivate;
				case DMacro: AMacro;
				case DDynamic: ADynamic;
				case DInline: AInline;
				case DOverload: AOverload;
				case DExtern: AExtern;
				case _: null; // DFinal/DPublic/DStatic unsupported at module-field level
			}
			if (a != null) out.push({access: a, pos: f.pos});
		}
		return out;
	}

	static function filterEnumFlags(c:Array<PlacedDeclFlag>):Array<EnumFlag> {
		var out:Array<EnumFlag> = [];
		for (f in c) switch (f.flag) {
			case DPrivate: out.push(EPrivate);
			case DExtern: out.push(EExtern);
			case _:
		}
		return out;
	}

	static function convertAbstractFlags(c:Array<PlacedDeclFlag>):Array<AbstractFlag> {
		var out:Array<AbstractFlag> = [];
		for (f in c) switch (f.flag) {
			case DPrivate: out.push(AbPrivate);
			case DExtern: out.push(AbExtern);
			case _:
		}
		return out;
	}

	static function filterClassFlags(c:Array<PlacedDeclFlag>):Array<ClassFlag> {
		var out:Array<ClassFlag> = [];
		for (f in c) switch (f.flag) {
			case DPrivate: out.push(HPrivate);
			case DExtern: out.push(HExtern);
			case DFinal: out.push(HFinal);
			case _:
		}
		return out;
	}

	function parseClassFlags():{flags:Array<ClassFlag>, pos:Position} {
		switch (peek()) {
			case Kwd(KwdClass): var p = next().pos; return {flags: [], pos: p};
			case Kwd(KwdInterface): var p = next().pos; return {flags: [HInterface], pos: p};
			case _: return serror();
		}
	}

	// With the cursor sitting just past `extends` or `implements`, the heritage takes the MAGIC type path
	// (an empty name) at the display position instead of failing. Loading that path is what asks which
	// types may stand here, and the inheritance check is what filters them.
	// The second result says whether the path was RESUMED at the display position, which stops the heritage
	// loop reporting again.
	function parseHeritTypePath(pkeyword:Position):{path:PlacedTypePath, resumed:Bool} {
		// The resume is a RECOVERY: only a path that fails to parse hands the position back, so a
		// name that does parse stays the subject and the typer answers about it.
		var save = idx;
		try {
			return {path: parseTypePath(), resumed: false};
		} catch (e:ParserError) {
			var matchedNothing = idx == save;
			idx = save;
			// The path is the SECOND element after the relation keyword, and the type path parse has no
			// fallback arm, so a path that matches nothing is a soft failure that the enclosing pattern
			// turns into a non-soft error - reported as `Unexpected <token>`, not as dollarIdentMacro's own
			// "Expected identifier".
			if (matchedNothing && !isDisplayFile()) serror();
			if (!wouldSkipDisplayPosition(pkeyword, true)) throw e;
			var dp = new Position(pkeyword.file, displayOffset, displayOffset);
			return {path: {path: magicTypePath(), pos: dp}, resumed: true};
		}
	}

	function parseClassContent(doc:Documentation, meta:Metadata, c:Array<PlacedDeclFlag>, n:Array<ClassFlag>, p1:Position):TypeDecl {
		var name = typeName();
		var tl = parseConstraintParams();
		var hl:Array<ClassFlag> = [];
		// The cursor in a GAP of the heritage clause asks which relation keyword belongs there, and an
		// interface may only extend. p0 tracks the end of what was consumed last, so each gap runs from
		// there to the next token.
		var hadDisplay = false;
		var isInterface = false;
		for (f in n) if (f.match(HInterface)) isInterface = true;
		function relationKeywords():Array<String> {
			return isInterface ? ["extends"] : ["extends", "implements"];
		}
		function checkDisplay(pp:Position):Void {
			if (hadDisplay || !isDisplayFile() || displayOffset < 0) return;
			if (!(pp.min <= displayOffset && displayOffset <= pp.max)) return;
			throw new hxc.compiler.DisplayXml.SyntaxCompletion(relationKeywords(), null,
				new Position(pp.file, displayOffset, displayOffset), 13);
		}
		var p0 = tokens[idx > 0 ? idx - 1 : 0].pos;
		while (true) {
			switch (peek()) {
				case Kwd(KwdExtends) | Kwd(KwdImplements):
					var isExtends = tokEq(peek(), Kwd(KwdExtends));
					var pk = next().pos;
					var r = parseHeritTypePath(pk);
					checkDisplay(new Position(pk.file, p0.max, pk.min));
					// With no type parameters the span is widened by one so the cursor right after the name
					// is not offered extends/implements again.
					p0 = new Position(r.path.pos.file, r.path.pos.min,
						r.path.pos.max + (r.path.path.tparams.length == 0 ? 1 : 0));
					if (r.resumed) hadDisplay = true;
					hl.push(isExtends ? HExtends(r.path) : HImplements(r.path));
				case _:
					break;
			}
		}
		// The `{` TERMINATES the heritage loop, and its absence is a recorded syntax error rather than a
		// raise, so the fields still parse. Requiring it here would drop the whole declaration in a display
		// file and with it any answer inside its heritage.
		if (tokEq(peek(), BrOpen)) {
			checkDisplay(new Position(p0.file, p0.max, peekInfo().pos.min));
			expect(BrOpen);
		} else {
			// An identifier under the cursor here is an incomplete relation keyword, answered with that name
			// as the subject. This is guarded on the CURSOR, not on the file, so outside display it simply
			// never matches and control falls through.
			var np = peekInfo().pos;
			switch (peek()) {
				case Const(CIdent(iname)) if (isDisplayFile() && np.min <= displayOffset && displayOffset <= np.max):
					throw new hxc.compiler.DisplayXml.SyntaxCompletion(relationKeywords(), iname, np, 13);
				case _:
			}
			// This arm is not display-only: syntaxError raises outside display and records inside it. Gating
			// it on the display file would let a batch compile fall to expect(BrOpen) and report the bare
			// `{` instead of the full alternative set.
			checkDisplay(new Position(p0.file, p0.max, peekInfo().pos.max));
			syntaxError(Expected(["extends", "implements", "{"]));
		}
		var cf = parseClassFields(false, p1);
		var flags = filterClassFlags(c).concat(n).concat(hl);
		var def:Definition<ClassFlag, Array<ClassField>> = {
			dName: name, dDoc: doc, dParams: tl, dMeta: meta, dFlags: flags, dData: cf.fields,
		};
		return {decl: EClass(def), pos: Position.union(p1, cf.pos)};
	}

	function parseClassFields(tdecl:Bool, p1:Position):{fields:Array<ClassField>, pos:Position} {
		var acc:Array<ClassField> = [];
		while (true) {
			if (tokEq(peek(), BrClose) || tokEq(peek(), Eof)) {
				// A field parse is ATTEMPTED at the closing brace: its getDoc consumes any pending doc
				// before the attempt fails, so a trailing doc comment in a body never leaks onto the next
				// declaration.
				getDoc();
				break;
			}
			// In the display file a failed field is recorded and the scan looks for the next plausible field
			// start; finding none ends the body where it stands, so a declaration that runs into the next
			// one still yields a class rather than aborting the file.
			if (isDisplayFile()) {
				var save = idx;
				var cff = try parseClassField(tdecl) catch (er:ParserError) {
					syntaxErrors.push({msg: er.msg, pos: er.pos});
					// Without rewinding, a sibling type after an unclosed body was eaten by the body and
					// vanished from the module.
					idx = save;
					// With no field start left, the body ends here (acc, last_pos) - there is no closing brace to
					// expect.
					if (resumeScan(tdecl, true) && idx > save) continue;
					return {fields: acc, pos: tokens[save > 0 ? save - 1 : 0].pos};
				};
				acc.push(cff);
				continue;
			}
			// The list ends on a soft failure, which means the field matched NOTHING at all; the missing
			// brace is then reported by the expect below as `Expected }`. A parse that consumed tokens
			// before failing is a non-soft error and stays fatal; letting every inner failure escape would
			// report `Unexpected <token>` instead of `Expected }`.
			var save = idx;
			var cff:Null<ClassField> = null;
			fieldFormFailed = false;
			try cff = parseClassField(tdecl)
			catch (er:ParserError) {
				// End the list on a soft failure: either the field matched nothing at all, or it reached
				// the form choice and none applied. Anything else consumed its way into a real syntax error
				// and propagates.
				if (!fieldFormFailed && idx != save) throw er;
				// No rewind: the stream does not give back what getDoc and the metadata parse already took,
				// so the list ends exactly where the field gave up and the expect below reports the missing
				// brace at that token.
				break;
			}
			acc.push(cff);
		}
		// A display-mode parse tolerates a body left unclosed by an earlier recovery (the file ends before
		// the closing brace).
		if (tokEq(peek(), Eof) && isDisplayFile())
			return {fields: acc, pos: peekInfo().pos};
		var p2 = expect(BrClose);
		return {fields: acc, pos: p2};
	}

	function parseClassField(tdecl:Bool):ClassField {
		var doc = getDoc();
		var meta = parseMeta();
		var al = parseCfRights();
		var name:PlacedName;
		var kind:ClassFieldKind;
		var fpos:Position;

		switch (peek()) {
			case Kwd(KwdVar):
				var p1 = next().pos;
				var q = questionableDollarIdent();
				name = q.name;
				if (q.opt) meta = optionalMeta(meta);
				if (tokEq(peek(), POpen)) {
					junk();
					var i1 = propertyIdent();
					expect(Comma);
					var i2 = propertyIdent();
					expect(PClose);
					var t = poptTypeHint();
					var a = parseVarFieldAssignment();
					kind = FProp(i1, i2, t, a.e); fpos = Position.union(p1, a.pos);
				} else {
					var t = poptTypeHint();
					var a = parseVarFieldAssignment();
					kind = FVar(t, a.e); fpos = Position.union(p1, a.pos);
				}
			case Kwd(KwdFinal):
				var p1 = next().pos;
				switch (peek()) {
					case Kwd(KwdVar):
						// Redundant `var` check
						var p2 = next().pos;
						throw new ParserError(Custom("`final var` is not supported, use `final` instead"), Position.union(p1, p2));
					case Const(CIdent(_)), Dollar(_), Question:
						var q = questionableDollarIdent();
						name = q.name;
						if (q.opt) meta = optionalMeta(meta);
						var t = poptTypeHint();
						var a = parseVarFieldAssignment();
						kind = FVar(t, a.e);
						al = al.concat([{access: AFinal, pos: p1}]);
						fpos = Position.union(p1, a.pos);
					case _:
						var al2 = parseCfRights();
						var ff = parseFunctionField(doc, meta, al.concat([{access: AFinal, pos: p1}]).concat(al2));
						name = ff.name; kind = ff.kind; meta = ff.meta; al = ff.al; fpos = ff.pos;
				}
			case Kwd(KwdFunction):
				var ff = parseFunctionField(doc, meta, al);
				name = ff.name; kind = ff.kind; meta = ff.meta; al = ff.al; fpos = ff.pos;
			case _:
				// With no access flags consumed this is a soft failure, which ends the field list so the
				// missing brace is reported by parseClassFields; with flags it is a hard serror(). Treating
				// both as serror() would report `Unexpected <token>` instead of `Expected }`, and treating both
				// as end-of-list the reverse.
				var last = al.length == 0 ? null : al[al.length - 1];
				if (last == null) {
					fieldFormFailed = true;
					return serror();
				}
				// The last flag is `override` and a cursor sits on it, so the request is which inherited
				// field to override: an empty method marked @:displayOverride stands in for the one being
				// written.
				if (!last.access.match(AOverride)) return serror();
				var cc = checkCompletion(last.pos, true);
				if (cc == null) return serror();
				name = {name: cc.name == null ? "" : cc.name, pos: cc.pos};
				kind = FFun({fParams: [], fArgs: [], fType: null, fExpr: null});
				meta = [{name: ":displayOverride", params: [], pos: Position.nullPos}].concat(meta);
				fpos = Position.union(last.pos, cc.pos);
		}

		// Position offset by leading access keyword
		var pos = (al.length == 0) ? fpos : Position.union(al[0].pos, fpos);
		return {
			cffName: name, cffDoc: doc, cffPos: pos, cffMeta: meta, cffAccess: al, cffKind: kind,
		};
	}

	static function optionalMeta(meta:Metadata):Metadata {
		return [{name: ":optional", params: [], pos: Position.nullPos}].concat(meta);
	}

	function parseFunctionField(doc:Documentation, meta:Metadata, al:Array<PlacedAccess>):{name:PlacedName, kind:ClassFieldKind, meta:Metadata, al:Array<PlacedAccess>, pos:Position} {
		var p1 = expect(Kwd(KwdFunction));
		var name = parseFunName();
		var pl = parseConstraintParams();
		expect(POpen);
		var args = psepTrailing(parseFunParam);
		// This `)` is a pattern ELEMENT, and a mid-pattern token mismatch is reported as `Unexpected
		// <actual token>`. Only a site that raises an explicit expectation reports `Expected )`, so
		// expect() would name the wrong half of the mismatch here.
		if (!tokEq(peek(), PClose)) serror();
		expect(PClose);
		var t = poptTypeHint();
		var e:Null<Expr> = null;
		var p2 = p1;
		var save = idx;
		try {
			var ee = expr();
			semicolon();
			e = ee; p2 = ee.pos;
		} catch (er:ParserError) {
			if (tokEq(tokens[save].tok, BrOpen)) throw er;
			idx = save;
			p2 = semicolon();
		}
		var f:Func = {fParams: pl, fArgs: args, fType: t, fExpr: e};
		return {name: name, kind: FFun(f), meta: meta, al: al, pos: Position.union(p1, p2)};
	}

	function parseFunName():PlacedName {
		switch (peek()) {
			case Kwd(KwdNew): var p = next().pos; return {name: "new", pos: p};
			case _: return dollarIdent();
		}
	}

	function parseCfRights():Array<PlacedAccess> {
		var acc:Array<PlacedAccess> = [];
		while (true) {
			var a:Null<Access> = switch (peek()) {
				case Kwd(KwdStatic): AStatic;
				case Kwd(KwdMacro): AMacro;
				case Kwd(KwdPublic): APublic;
				case Kwd(KwdPrivate): APrivate;
				case Kwd(KwdOverride): AOverride;
				case Kwd(KwdDynamic): ADynamic;
				case Kwd(KwdInline): AInline;
				case Kwd(KwdExtern): AExtern;
				case Kwd(KwdAbstract): AAbstract;
				case Kwd(KwdOverload): AOverload;
				case _: null;
			}
			if (a == null) break;
			var p = next().pos;
			acc.push({access: a, pos: p});
		}
		return acc;
	}

	function propertyIdent():PlacedName {
		switch (peek()) {
			case Const(CIdent(i)): var p = next().pos; return {name: i, pos: p};
			case Kwd(KwdDynamic): var p = next().pos; return {name: "dynamic", pos: p};
			case Kwd(KwdDefault): var p = next().pos; return {name: "default", pos: p};
			case Kwd(KwdNull): var p = next().pos; return {name: "null", pos: p};
			case _: return err("Expected property accessor");
		}
	}

	// Optional leading `?` then dollarIdent
	function questionableDollarIdent():{opt:Bool, name:PlacedName} {
		var opt = false;
		var qpos:Null<Position> = null;
		if (tokEq(peek(), Question)) { qpos = next().pos; opt = true; }
		var n = dollarIdent();
		if (qpos != null && qpos.max != n.pos.min)
			throw new ParserError(Custom("Invalid usage of ?, use ?" + n.name + " instead"), qpos);
		return {opt: opt, name: n};
	}

	function parseVarFieldAssignment():{e:Null<Expr>, pos:Position} {
		if (tokEq(peek(), TBinop(OpAssign))) {
			junk();
			var e = expr();
			var p2 = semicolon();
			return {e: e, pos: p2};
		}
		var p2 = semicolon();
		return {e: null, pos: p2};
	}

	function parseEnumCtor():EnumConstructor {
		var doc = getDoc();
		var meta = parseMeta();
		var name = identTok();
		var params = parseConstraintParams();
		var args:Array<{name:String, opt:Bool, type:TypeHint}> = [];
		if (tokEq(peek(), POpen)) {
			junk();
			args = psepTrailing(parseEnumParam);
			expect(PClose);
		}
		var t = poptTypeHint();
		var p2 = semicolon();
		return {
			ecName: name, ecDoc: doc, ecMeta: meta, ecArgs: args,
			ecPos: Position.union(name.pos, p2), ecParams: params, ecType: t,
		};
	}

	function parseEnumParam():{name:String, opt:Bool, type:TypeHint} {
		var opt = false;
		if (tokEq(peek(), Question)) { junk(); opt = true; }
		var n = identTok();
		var t = parseTypeHint();
		return {name: n.name, opt: opt, type: t};
	}

	function parseAbstract(doc:Documentation, meta:Metadata, flags:Array<AbstractFlag>, p1:Position):TypeDecl {
		var name = typeName();
		var tl = parseConstraintParams();
		// Optional ( ComplexType )
		var st:Null<TypeHint> = null;
		if (tokEq(peek(), POpen)) {
			junk();
			st = parseComplexType();
			expect(PClose);
		}
		// Any number of abstract relations (from/to)
		var sl:Array<AbstractFlag> = [];
		while (true) {
			switch (peek()) {
				case Const(CIdent("to")):
					var pk = next().pos;
					sl.push(AbTo(abstractRelationType(pk)));
				case Const(CIdent("from")):
					var pk = next().pos;
					sl.push(AbFrom(abstractRelationType(pk)));
				case _:
					break;
			}
		}
		// The missing `{` after the relations is recorded inside the display file, so `abstract A(Int)
		// from <cursor>` with no body still yields a declaration. What is expected there is a body or
		// another relation.
		if (tokEq(peek(), BrOpen)) junk();
		else syntaxError(Expected(["{", "to", "from"]));
		var cf = parseClassFields(false, p1);
		var allFlags = (st == null) ? flags : [AbOver(st)].concat(flags);
		allFlags = allFlags.concat(sl);
		var def:Definition<AbstractFlag, Array<ClassField>> = {
			dName: name, dDoc: doc, dParams: tl, dMeta: meta, dFlags: allFlags, dData: cf.fields,
		};
		return {decl: EAbstract(def), pos: Position.union(p1, cf.pos)};
	}

	function parseImport(p1:Position):TypeDecl {
		var path:Array<PlacedName> = [];
		var mode:ImportMode = INormal;
		switch (peek()) {
			case Const(CIdent(name)):
				var p = next().pos;
				path.push({name: name, pos: p});
				var done = false;
				while (!done) {
					switch (peek()) {
						case Dot:
							var dp = next().pos;
							if (checkResume(dp)) raiseTypePath([for (pn in path) pn.name], true);
							switch (peek()) {
								case Const(CIdent(k)): var pk = next().pos; path.push({name: k, pos: pk});
								case Kwd(KwdMacro): var pk = next().pos; path.push({name: "macro", pos: pk});
								case Kwd(KwdExtern): var pk = next().pos; path.push({name: "extern", pos: pk});
								case Kwd(KwdFunction): var pk = next().pos; path.push({name: "function", pos: pk});
								case TBinop(OpMult): junk(); mode = IAll; done = true;
								case _: done = true;
							}
						case Kwd(KwdIn):
							junk();
							var nm = identTok();
							mode = IAsName(nm); done = true;
						case Const(CIdent("as")):
							junk();
							var nm = identTok();
							mode = IAsName(nm); done = true;
						case _:
							done = true;
					}
				}
			case _:
				// `import |` leaves the path empty rather than failing, and that with every type in scope.
				if (!wouldSkipDisplayPosition(p1, true)) return err("Expected identifier after import");
		}
		// The cursor standing where the semicolon would be is not an error at all, and a semicolon
		// missing for any other reason is recorded, so the import the user has half-typed still reaches
		// import handling and answers the display.
		var p2 = if (tokEq(peek(), Semicolon)) next().pos
			else if (wouldSkipDisplayPosition(p1, true)) new Position(p1.file, displayOffset, displayOffset)
			else { syntaxError(Expected([".", ";", "as"])); tokens[idx > 0 ? idx - 1 : 0].pos; };
		var ipos = Position.union(p1, p2);
		return {decl: EImport({path: path, mode: mode, pos: ipos}), pos: ipos};
	}

	function parseUsing(p1:Position):TypeDecl {
		var path:Array<PlacedName> = [];
		switch (peek()) {
			case Const(CIdent(name)):
				var p = next().pos;
				path.push({name: name, pos: p});
				var done = false;
				while (!done) {
					switch (peek()) {
						case Dot:
							var dp = next().pos;
							// The cursor right after the dot completes on the path so far, the same rule
							// the import path carries.
							if (checkResume(dp)) raiseTypePath([for (pn in path) pn.name], false);
							switch (peek()) {
								case Const(CIdent(k)): var pk = next().pos; path.push({name: k, pos: pk});
								case Kwd(KwdMacro): var pk = next().pos; path.push({name: "macro", pos: pk});
								case Kwd(KwdExtern): var pk = next().pos; path.push({name: "extern", pos: pk});
								case Kwd(KwdFunction): var pk = next().pos; path.push({name: "function", pos: pk});
								case _: done = true;
							}
						case _:
							done = true;
					}
				}
			case _:
				// The same rule for `using |`.
				if (!wouldSkipDisplayPosition(p1, true)) return err("Expected identifier after using");
		}
		// The same rule the import above carries
		var p2 = if (tokEq(peek(), Semicolon)) next().pos
			else if (wouldSkipDisplayPosition(p1, true)) new Position(p1.file, displayOffset, displayOffset)
			else { syntaxError(Expected([".", ";"])); tokens[idx > 0 ? idx - 1 : 0].pos; };
		return {decl: EUsing(path), pos: Position.union(p1, p2)};
	}
}
