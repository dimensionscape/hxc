package hxc.parser;

import hxc.ast.Ast.Token;
import hxc.ast.Position;

/** A lexed token together with its source position, pair the lexer/parser pass around (a positional pair -> a named record). */
@:structInit
class TokenInfo {
	public var tok:Token;
	public var pos:Position;

	// The block comment immediately preceding this token (delimiting stars stripped); the parser's
	// getDoc reads it.
	public var doc:Null<String>;

	// Set on the token FOLLOWING an #if whose condition did not parse. The condition production has
	// no catch-all, so the miss is a no-match raised inside the main stream's fill and the list
	// that was pulling ends there. Which of the two that means - a clean end or
	// `Unexpected <token>` - is the list parser's own rule, so the list loops decide it.
	public var condBreak:Int = 0;

	// Set on a `<` whose markup scan ran to the end of the file. Markup is lexed on DEMAND, from the
	// three grammar positions that accept a markup literal, so it is never scanned at a position
	// where no expression is expected. hxc lexes the whole file up front, so the scan happens
	// anyway and its FAILURE waits for the parser to say whether a scan belongs there at all.
	public var markupFailed:Bool = false;

	// Raw (UTF-16 unit) offset of the token's start, or -1 for a synthetic token. Markup is re-lexed
	// from the position of a `<` the PARSER chose; hxc's positions are code-point offsets, so the
	// lexer needs this to seek there.
	public var rawPmin:Int = -1;

	// Set on the `@` the pre-pass synthesises for a markup literal it scanned itself, so the
	// parser can tell it from a user-written `@:markup` and give it a markup literal's
	// shape (no exprNext) rather than a metadata entry's.
	public var markupSynthetic:Bool = false;

	public function new(tok:Token, pos:Position) {
		this.tok = tok;
		this.pos = pos;
	}

	public function toString():String {
		return '${tok}@${pos.min}-${pos.max}';
	}
}
