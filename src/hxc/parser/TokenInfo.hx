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

	public function new(tok:Token, pos:Position) {
		this.tok = tok;
		this.pos = pos;
	}

	public function toString():String {
		return '${tok}@${pos.min}-${pos.max}';
	}
}
