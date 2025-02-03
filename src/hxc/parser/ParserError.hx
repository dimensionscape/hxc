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

	/**
		This marks a NO-MATCH (no alternative matched at all) rather than a syntax error, and it is the
		ENCLOSING pattern position that decides what it means - at a production's first element, the
		enclosing production simply backtracks; anywhere later, it becomes a syntax error. A Haxe
		try/catch cannot see pattern position, so the verdict travels on the error itself. Only `expr`
		produces one (the expression production has no catch-all alternative), and only the handful
		of consumers that hold expr in a first pattern position honour it; `Parser.expr` clears it
		for everyone else, which is the conversion to a syntax error.
	*/
	public final soft:Bool;

	public function new(msg:ParserErrorMsg, pos:Position, soft:Bool = false) {
		super("ParserError");
		this.msg = msg;
		this.pos = pos;
		this.soft = soft;
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
