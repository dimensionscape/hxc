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

	public function new(tok:Token, pos:Position) {
		this.tok = tok;
		this.pos = pos;
	}

	public function toString():String {
		return '${tok}@${pos.min}-${pos.max}';
	}
}
