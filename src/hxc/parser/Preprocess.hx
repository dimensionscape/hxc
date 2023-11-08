package hxc.parser;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Define;

class Preprocess {
	final toks:Array<TokenInfo>;
	final defines:Define;
	var i:Int;
	final out:Array<TokenInfo>;
	// Stack of `#if` start positions still open (for unclosed-conditional errors)
	final mstack:Array<Position>;

	function new(toks:Array<TokenInfo>, defines:Define) {
		this.toks = toks;
		this.defines = defines;
		this.i = 0;
		this.out = [];
		this.mstack = [];
	}

	public static function run(toks:Array<TokenInfo>, defines:Define):Array<TokenInfo> {
		var p = new Preprocess(toks, defines);
		return p.process();
	}

	// Evaluate a conditional expression against the defines, as #if does. Used by @:require.
	public static function isTrueExpr(defines:Define, e:Expr):Bool {
		var p = new Preprocess([], defines);
		return isTrue(p.eval(e));
	}

	inline function peekTok():Token return i < toks.length ? toks[i].tok : Eof;
	inline function cur():TokenInfo return toks[i < toks.length ? i : toks.length - 1];
	inline function adv():TokenInfo { var t = toks[i]; i++; return t; }

	function process():Array<TokenInfo> {
		while (true) {
			if (i >= toks.length) break;
			var ti = toks[i];
			switch (ti.tok) {
				case Eof:
					out.push(ti);
					i++;
					break;
				case Sharp("end"):
					if (mstack.length == 0) { out.push(ti); i++; }
					else { mstack.pop(); i++; }
				case Sharp("elseif"):
					if (mstack.length == 0) { out.push(ti); i++; }
					else {
						mstack.pop();
						i++;
						parseMacroCond(); // Condition of the elseif we are leaving
						skipTokens(ti.pos, false);
					}
				case Sharp("else"):
					if (mstack.length == 0) { out.push(ti); i++; }
					else {
						mstack.pop();
						i++;
						skipTokens(ti.pos, false);
					}
				case Sharp("if"):
					var p = ti.pos;
					i++;
					enterMacro(true, p);
				case Sharp("error"):
					i++;
					switch (peekTok()) {
						case Const(CString(s, _)): throw new ParserError(Custom(s), ti.pos);
						case _: throw new ParserError(Unimplemented, ti.pos);
					}
				case Sharp("line"):
					i++;
					switch (peekTok()) {
						case Const(CInt(_, _)): i++;
						case _: throw new ParserError(Custom("Could not parse line number"), ti.pos);
					}
				case Sharp(s):
					throw new ParserError(Custom("Unknown token #" + s), ti.pos);
				case _:
					out.push(ti);
					i++;
			}
		}
		if (mstack.length > 0) {
			throw new ParserError(Unclosed_conditional, mstack[mstack.length - 1]);
		}
		return out;
	}

	// Parse cond, eval; if true push branch, else skip to else/elseif/end.
	function enterMacro(isIf:Bool, p:Position):Void {
		var e = parseMacroCond();
		if (isTrue(eval(e))) {
			mstack.push(p);
		} else {
			skipTokensLoop(p, true);
		}
	}

	// Skip until a matching #else/#elseif/#end, honoring nesting.
	function skipTokens(p:Position, test:Bool):Void {
		skipTokensLoop(p, test);
	}

	function skipTokensLoop(p:Position, test:Bool):Void {
		while (true) {
			if (i >= toks.length) {
				throw new ParserError(Unclosed_conditional, p);
			}
			var ti = toks[i];
			switch (ti.tok) {
				case Eof:
					throw new ParserError(Unclosed_conditional, p);
				case Sharp("end"):
					i++;
					return;
				case Sharp("elseif") if (!test):
					i++;
					parseMacroCond();
				case Sharp("else") if (!test):
					i++;
				case Sharp("else"):
					i++;
					mstack.push(ti.pos);
					return;
				case Sharp("elseif"):
					i++;
					enterMacro(false, ti.pos);
					return;
				case Sharp("if"):
					// Nested #if while skipping: skip its whole block too
					i++;
					parseMacroCond();
					skipTokensLoop(p, false);
					// After the nested block is consumed, keep skipping the outer
				case Sharp("error"), Sharp("line"):
					i++;
				case Sharp(s):
					throw new ParserError(Custom("Unknown token #" + s), ti.pos);
				case _:
					i++;
			}
		}
	}

	function parseMacroCond():Expr {
		var ti = cur();
		switch (ti.tok) {
			// No field chain. This array-based preprocessor lexes with the normal lexer (dots split into
			// Dot tokens), so it reconstructs the dotted path here, required for `#if target.unicode`.
			case Const(CIdent(t)):
				i++;
				return parseMacroCondFieldChain(new Expr(EConst(CIdent(t)), ti.pos));
			case Kwd(k):
				i++;
				return parseMacroCondFieldChain(new Expr(EConst(CIdent(Ast.sKeyword(k))), ti.pos));
			case Const(CString(s, kind)):
				i++;
				return new Expr(EConst(CString(s, kind)), ti.pos);
			case Const(CInt(v, sfx)):
				i++;
				return new Expr(EConst(CInt(v, sfx)), ti.pos);
			case Const(CFloat(v, sfx)):
				i++;
				return new Expr(EConst(CFloat(v, sfx)), ti.pos);
			case TUnop(op):
				i++;
				var e = parseMacroCond();
				return new Expr(EUnop(op, Prefix, e), ti.pos);
			case POpen:
				// Parenthesised full conditional expression: parse the sub-token
				// span up to the matching close paren and run the real parser.
				i++;
				var e = parseParenCond(ti.pos);
				return e;
			case _:
				throw new ParserError(Custom("Invalid condition expression"), ti.pos);
		}
	}

	// Reconstruct a dotted define path `a.b.c` from Dot-split tokens (the array-based equivalent of
	function parseMacroCondFieldChain(e:Expr):Expr {
		var acc = e;
		while (true) {
			var ti = cur();
			switch (ti.tok) {
				case Dot:
					i++;
					var tn = cur();
					switch (tn.tok) {
						case Const(CIdent(name)):
							i++;
							acc = new Expr(EField(acc, name, EFNormal), Position.union(acc.pos, tn.pos));
						case Kwd(k):
							i++;
							acc = new Expr(EField(acc, Ast.sKeyword(k), EFNormal), Position.union(acc.pos, tn.pos));
						case _:
							throw new ParserError(Custom("Invalid condition expression"), ti.pos);
					}
				case _:
					return acc;
			}
		}
	}

	// Collect tokens up to the matching ')' and parse them as one expression with
	// the full Parser, then validate to the conditional subset.
	function parseParenCond(popen:Position):Expr {
		var depth = 1;
		var sub:Array<TokenInfo> = [];
		while (true) {
			if (i >= toks.length) throw new ParserError(Custom("Unclosed ( in conditional"), popen);
			var ti = toks[i];
			switch (ti.tok) {
				case POpen: depth++; sub.push(ti); i++;
				case PClose:
					depth--;
					if (depth == 0) { i++; break; }
					sub.push(ti); i++;
				case Eof: throw new ParserError(Custom("Unclosed ( in conditional"), popen);
				// While a condition is parsed, keyword tokens are plain identifiers (e.g. `macro`,
				// `interp`,
				// `extern`, `dynamic` are define names, not keywords), so rewrite Kwd -> CIdent in the
				// collected span.
				case Kwd(k):
					sub.push(new TokenInfo(Const(CIdent(Ast.sKeyword(k))), ti.pos));
					i++;
				case _: sub.push(ti); i++;
			}
		}
		sub.push(new TokenInfo(Eof, popen));
		var e = Parser.parseExprFromTokens(sub, "<cond>");
		validateMacroCond(e);
		return new Expr(EParenthesis(e), popen);
	}

	static function validateMacroCond(e:Expr):Void {
		switch (e.expr) {
			case EConst(CIdent(_)) | EConst(CString(_, _)) | EConst(CInt(_, _)) | EConst(CFloat(_, _)):
			case EUnop(_, _, e1): validateMacroCond(e1);
			case EBinop(_, e1, e2): validateMacroCond(e1); validateMacroCond(e2);
			case EParenthesis(e1): validateMacroCond(e1);
			case EField(e1, _, _): validateMacroCond(e1);
			case ECall(c, args):
				switch (c.expr) {
					case EConst(CIdent(_)): for (a in args) validateMacroCond(a);
					case _: throw new ParserError(Custom("Invalid condition expression"), e.pos);
				}
			case _: throw new ParserError(Custom("Invalid condition expression"), e.pos);
		}
	}

	function eval(e:Expr):SmallType {
		switch (e.expr) {
			case EConst(CIdent(id)):
				return defines.rawDefined(id) ? TString(defines.rawDefinedValue(id)) : TNull;
			case EConst(CString(s, _)): return TString(s);
			case EConst(CInt(v, _)): return TFloat(floatVal(v)); // Float parse (hex/underscore)
			case EConst(CFloat(v, _)): return TFloat(floatVal(v));
			case ECall(c, args):
				switch (c.expr) {
					case EConst(CIdent("version")) if (args.length == 1):
						switch (args[0].expr) {
							case EConst(CString(s, _)): return TVersion(s);
							case _: throw new ParserError(Custom("Invalid version()"), e.pos);
						}
					case _: throw new ParserError(Custom("Invalid condition expression"), e.pos);
				}
			case EBinop(OpBoolAnd, e1, e2): return TBool(isTrue(eval(e1)) && isTrue(eval(e2)));
			case EBinop(OpBoolOr, e1, e2): return TBool(isTrue(eval(e1)) || isTrue(eval(e2)));
			case EUnop(Not, _, e1): return TBool(!isTrue(eval(e1)));
			case EParenthesis(e1): return eval(e1);
			case EBinop(op, e1, e2):
				var v1 = eval(e1);
				var v2 = eval(e2);
				return evalCompare(op, v1, v2, e.pos);
			case EField(_, _, _):
				var path = fieldPath(e);
				if (path == null) throw new ParserError(Custom("Invalid condition expression"), e.pos);
				return defines.rawDefined(path) ? TString(defines.rawDefinedValue(path)) : TNull;
			case _:
				throw new ParserError(Custom("Invalid condition expression"), e.pos);
		}
	}

	static function fieldPath(e:Expr):Null<String> {
		return switch (e.expr) {
			case EConst(CIdent(s)): s;
			case EField(e1, f, _):
				var pre = fieldPath(e1);
				pre == null ? null : pre + "." + f;
			case _: null;
		}
	}

	function evalCompare(op:Binop, v1:SmallType, v2:SmallType, p:Position):SmallType {
		// Auto-cast string<->float like eval_binop_exprs
		switch ([v1, v2]) {
			case [TString(s1), TFloat(_)]:
				var f = floatOfStringOpt(s1); // Is strict (whole string must parse)
				if (f != null) v1 = TFloat(f);
			case [TFloat(_), TString(s2)]:
				var f = floatOfStringOpt(s2);
				if (f != null) v2 = TFloat(f);
			case _:
		}
		var c = cmp(v1, v2, p);
		return switch (op) {
			case OpEq: TBool(c != null && c == 0);
			case OpNotEq: TBool(!(c != null && c == 0));
			case OpGt: TBool(c != null && c > 0);
			case OpGte: TBool(c != null && c >= 0);
			case OpLt: TBool(c != null && c < 0);
			case OpLte: TBool(c != null && c <= 0);
			case _: throw new ParserError(Custom("Unsupported operation"), p);
		}
	}

	// Incompatible type pairing is a HARD error. Version comparisons parse the
	// string side (parseVersion errors become a ParserError at the condition position).
	static function cmp(v1:SmallType, v2:SmallType, p:Position):Null<Int> {
		return switch ([v1, v2]) {
			case [TNull, _] | [_, TNull]: null;
			case [TFloat(a), TFloat(b)]: a < b ? -1 : (a > b ? 1 : 0);
			case [TString(a), TString(b)]: a < b ? -1 : (a > b ? 1 : 0);
			case [TBool(a), TBool(b)]: (a == b) ? 0 : (!a ? -1 : 1);
			case [TVersion(a), TVersion(b)] | [TVersion(a), TString(b)] | [TString(a), TVersion(b)]:
				try
					Semver.compareVersion(Semver.parseVersion(a), Semver.parseVersion(b))
				catch (e:haxe.Exception)
					throw new ParserError(Custom(e.message), p);
			case _:
				throw new ParserError(Custom("Cannot compare " + sValue(v1) + " and " + sValue(v2)), p);
		}
	}

	static function isTrue(v:SmallType):Bool {
		return switch (v) {
			case TBool(false), TNull: false;
			case TFloat(0.0): false;
			case _: true;
		}
	}

	// S_value (for the "Cannot compare..." message)
	static function sValue(v:SmallType):String {
		return switch v {
			case TNull: "null";
			case TBool(b): "boolean " + b;
			case TFloat(f):
				// A float always prints with a decimal point (0. not 0).
				var sf = Std.string(f);
				if (~/^-?[0-9]+$/.match(sf)) sf += ".";
				"float " + sf;
			case TString(s): "string \"" + s + "\"";
			case TVersion(v): "version " + v;
		}
	}

	static inline function isDigit(c:Int):Bool
		return c >= "0".code && c <= "9".code;

	// For a known-valid numeric lexeme (always succeeds for int/float tokens)
	static function floatVal(s:String):Float {
		var f = floatOfStringOpt(s);
		return f != null ? f : Std.parseFloat(s);
	}

	// Accepts 0x hex and '_' separators, and requires the whole string to be a valid number (else
	// Failure). null = parse failure.
	static function floatOfStringOpt(s:String):Null<Float> {
		var t = StringTools.replace(s, "_", "");
		if (t.length == 0)
			return null;
		var low = t.toLowerCase();
		if (StringTools.startsWith(low, "0x") || StringTools.startsWith(low, "-0x") || StringTools.startsWith(low, "+0x")) {
			var n = Std.parseInt(t); // Hex int (hex floats are out of scope for define values)
			return n == null ? null : (n : Float);
		}
		var i = 0;
		var n = t.length;
		var c0 = t.charCodeAt(0);
		if (c0 == "+".code || c0 == "-".code)
			i++;
		var digits = 0;
		while (i < n && isDigit(t.charCodeAt(i))) {
			i++;
			digits++;
		}
		if (i < n && t.charCodeAt(i) == ".".code) {
			i++;
			while (i < n && isDigit(t.charCodeAt(i))) {
				i++;
				digits++;
			}
		}
		if (digits == 0)
			return null;
		if (i < n && (t.charCodeAt(i) == "e".code || t.charCodeAt(i) == "E".code)) {
			i++;
			if (i < n && (t.charCodeAt(i) == "+".code || t.charCodeAt(i) == "-".code))
				i++;
			var ed = 0;
			while (i < n && isDigit(t.charCodeAt(i))) {
				i++;
				ed++;
			}
			if (ed == 0)
				return null;
		}
		if (i != n)
			return null; // Trailing garbage is a parse failure
		return Std.parseFloat(t);
	}
}

enum SmallType {
	TNull;
	TBool(b:Bool);
	TFloat(f:Float);
	TString(s:String);
	TVersion(v:String);
}
