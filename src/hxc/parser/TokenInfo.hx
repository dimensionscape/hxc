package hxc.parser;

import hxc.ast.Ast.Token;
import hxc.ast.Position;

/** A lexed token together with its source position, pair the lexer/parser pass around (a positional pair -> a named record). */
@:structInit
class TokenInfo {
	public var tok:Token;
	public var pos:Position;

	public function new(tok:Token, pos:Position) {
		this.tok = tok;
		this.pos = pos;
	}

	public function toString():String {
		return '${tok}@${pos.min}-${pos.max}';
	}
}
