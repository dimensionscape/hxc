package hxc.parser;

import hxc.ast.Ast;
import hxc.ast.Ast.Token;
import hxc.ast.Position;

enum ParserErrorMsg {
	Unexpected(t:Token);
	Duplicate_default;
	Missing_semicolon;
	Unclosed_conditional;
	Unimplemented;
	Missing_type;
	Expected(sl:Array<String>);
	StreamError(s:String);
	Custom(s:String);
}

class ParserError extends haxe.Exception {
	public final msg:ParserErrorMsg;
	public final pos:Position;

	public function new(msg:ParserErrorMsg, pos:Position) {
		super("ParserError");
		this.msg = msg;
		this.pos = pos;
	}

	public static function errorMsg(m:ParserErrorMsg):String {
		return switch m {
			case Unexpected(Kwd(k)): "Unexpected keyword \"" + Ast.sKeyword(k) + "\"";
			case Unexpected(t): "Unexpected " + Ast.sToken(t);
			case Duplicate_default: "Duplicate default";
			case Missing_semicolon: "Missing ;";
			case Unclosed_conditional: "Unclosed conditional compilation block";
			case Unimplemented: "Not implemented for current platform";
			case Missing_type: "Missing type declaration";
			case Expected(sl): "Expected " + sl.join(" or ");
			case StreamError(s): s;
			case Custom(s): s;
		}
	}
}
