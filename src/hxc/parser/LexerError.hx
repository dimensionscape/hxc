package hxc.parser;

import hxc.ast.Position;

enum LexerErrorMsg {
	InvalidCharacter(c:Int);
	UnterminatedString;
	UnterminatedRegexp;
	UnclosedComment;
	UnclosedCode;
	InvalidEscape(c:Int, ?msg:String);
	InvalidOption;
	UnterminatedMarkup;
}

class LexerError extends haxe.Exception {
	public final msg:LexerErrorMsg;
	public final pos:Position;

	public function new(msg:LexerErrorMsg, pos:Position) {
		super("LexerError");
		this.msg = msg;
		this.pos = pos;
	}

	public static function errorMsg(e:LexerErrorMsg):String {
		return switch e {
			case InvalidCharacter(c) if (c > 32 && c < 128): "Invalid character '" + String.fromCharCode(c) + "'";
			case InvalidCharacter(c): "Invalid character 0x" + StringTools.hex(c, 2);
			case UnterminatedString: "Unterminated string";
			case UnterminatedRegexp: "Unterminated regular expression";
			case UnclosedComment: "Unclosed comment";
			case UnclosedCode: "Unclosed code string";
			case InvalidEscape(c, null): "Invalid escape sequence \\" + charEscaped(c);
			case InvalidEscape(c, msg): "Invalid escape sequence \\" + charEscaped(c) + ". " + msg;
			case InvalidOption: "Invalid regular expression option";
			case UnterminatedMarkup: "Unterminated markup literal";
		}
	}

	// Char.escaped: escape ' \ and the C0 controls; printable ASCII as-is; else \DDD (decimal).
	static function charEscaped(c:Int):String {
		return switch c {
			case "'".code: "\\'";
			case "\\".code: "\\\\";
			case "\n".code: "\\n";
			case "\t".code: "\\t";
			case "\r".code: "\\r";
			case 8: "\\b";
			case _ if (c >= " ".code && c <= "~".code): String.fromCharCode(c);
			case _: "\\" + StringTools.lpad(Std.string(c), "0", 3);
		}
	}
}
