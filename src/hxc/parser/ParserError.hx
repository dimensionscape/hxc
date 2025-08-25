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

/**
 * The token stream's own fill raising. A conditional-compilation fault is raised from inside the
 * token stream, so nothing in the grammar can absorb one: it leaves the whole parse. hxc's grammar
 * catches ParserError at thirty sites, and a backtracking one (psepTrailing, the first-element
 * alternatives) would take the fault for "no element here" and report its own message at the
 * truncated stream. The fault travels as a class none of them catch, and the parse entries hand the
 * ParserError it carries back out.
 */
class PreprocessorAbort extends haxe.Exception {
	public final err:ParserError;

	public function new(err:ParserError) {
		super("PreprocessorAbort");
		this.err = err;
	}
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

	/**
		Raised by the PREPROCESSOR, not by a grammar alternative. A conditional-compilation fault is
		raised from the token stream's own fill, while a production that did not match is a syntax
		error, and the recovery arms catch only the latter - so the fault travels past them and is
		reported. hxc funnels both through this one type and a Haxe try/catch cannot tell them apart,
		so the verdict travels on the error, exactly as `soft` above carries the no-match one.
	*/
	public final fromPreprocessor:Bool;

	public function new(msg:ParserErrorMsg, pos:Position, soft:Bool = false, fromPreprocessor:Bool = false) {
		super("ParserError");
		this.msg = msg;
		this.pos = pos;
		this.soft = soft;
		this.fromPreprocessor = fromPreprocessor;
	}

	/**
	    Loading a module type records a LOAD error and lets the compile carry on. A PARSE failure is a
	    different exception and passes straight through every such recovery, ending the compile where
	    it happened.
	*/
	public static function isParseFailure(e:Dynamic):Bool {
		return Std.isOfType(e, ParserError) || Std.isOfType(e, LexerError);
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
