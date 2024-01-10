package hxc.parser;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Define;

using hxc.ast.Position;

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

	function new(tokens:Array<TokenInfo>, file:String, inMacro:Bool = false) {
		this.tokens = tokens;
		this.idx = 0;
		this.file = file;
		this.lastIdx = -1;
		this.stall = 0;
		this.inMacro = inMacro;
	}

	public static function parseExprString(src:String, file:String = "?", ?defines:Define, registerContent:Bool = false):Expr {
		var p = make(src, file, defines, registerContent);
		var e = p.expr();
		if (!p.tokEq(p.peek(), Eof)) p.serror();
		return e;
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
	static function lexAll(src:String, file:String):Array<TokenInfo> {
		var lex = new Lexer(src, file);
		var toks:Array<TokenInfo> = [];
		var lastSignificant:Null<Token> = null;
		var lastWasMarkup = false;
		// Lexer progress invariant: every non-Eof token call must advance the
		// stuck -> raise instead of spinning forever.
		var lastOff = lex.offset();
		while (true) {
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
				case Comment(_), CommentLine(_):
					// Filtered, like the reference token stream
				case _:
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
		return toks;
	}

	static function canStartMarkup(prev:Null<Token>, lastWasMarkup:Bool):Bool {
		if (lastWasMarkup || prev == null) return true;
		return switch (prev) {
			case POpen | BkOpen | BrOpen | Comma | Semicolon | DblDot | Question | QuestionDot | Arrow
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
		var toks = lexAll(src, file);
		// Conditional-compilation preprocessing (#if/#else/#elseif/#end/#error/
		// #line). Only run when the stream actually contains a Sharp token, so
		// the common expression-grammar path pays nothing. The active define set comes
		// from the caller (CLI/Setup later); default is empty (no hardcoded define tables).
		if (hasSharp(toks)) {
			var d = defines == null ? new Define() : defines;
			toks = Preprocess.run(toks, d);
		}
		return new Parser(toks, file, defines != null && defines.rawDefined("macro"));
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
		var name = parseMetaName(p1);
		var pEnd = tokens[idx - 1].pos;
		var params:Array<Expr> = [];
		// A `(...)` is metadata ARGS only when the `(` is IMMEDIATELY adjacent to the name (POpen.min ==
		// name.max, i.e. no whitespace). With a space,
		// `@:meta (expr)` is metadata APPLIED to the parenthesized expression, not args, so we
		if (tokEq(peek(), POpen) && peekInfo().pos.min == tokens[idx - 1].pos.max) {
			junk();
			params = parseCallParamsList();
			pEnd = expect(PClose);
		}
		return {name: name, params: params, pos: Position.union(p1, pEnd)};
	}

	function parseMetaName(p1:Position):String {
		// Optional leading ':' for compiler meta
		var prefix = "";
		if (tokEq(peek(), DblDot)) { junk(); prefix = ":"; }
		var parts:Array<String> = [];
		parts.push(metaNamePart());
		while (tokEq(peek(), Dot)) {
			junk();
			parts.push(metaNamePart());
		}
		return prefix + parts.join(".");
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
				var p2 = expect(BrClose);
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
			var p2 = expect(BrClose);
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

	function parseStructuralExtension():PlacedTypePath {
		expect(TBinop(OpGt));
		var t = parseTypePath();
		expect(Comma);
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
				junk();
				var t2 = parseComplexType();
				return switch (t2.ct) {
					case CTFunction(args, r):
						{ct: CTFunction([t].concat(args), r), pos: Position.union(t.pos, t2.pos)};
					case _:
						{ct: CTFunction([t], t2), pos: Position.union(t.pos, t2.pos)};
				}
			case TBinop(OpAnd):
				junk();
				var t2 = parseComplexType();
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

	function parseFunctionTypeNext(tl:Array<TypeHint>, p1:Position):TypeHint {
		expect(Arrow);
		var tret = parseComplexTypeInner(false);
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

	function parseTypePath2(p0:Null<Position>, pack:Array<String>, name:String, p1:Position):PlacedTypePath {
		if (isLowerIdent(name)) {
			if (tokEq(peek(), Dot)) {
				junk();
				return parseTypePath1(p0 == null ? p1 : p0, pack.concat([name]));
			} else {
				return err("Type name should start with an uppercase letter");
			}
		}
		var sub:Null<String> = null;
		var p2 = p1;
		if (tokEq(peek(), Dot)) {
			junk();
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
			junk();
			params = psep(Comma, parseTypePathOrConst);
			p2 = expect(TBinop(OpGt));
		}
		var tp:TypePath = {
			tpackage: pack.copy(),
			tname: name,
			tparams: params,
			tsub: sub,
		};
		return {path: tp, pos: Position.union(p0 == null ? p1 : p0, p2)};
	}

	function parseTypePathOrConst():TypeParamOrConst {
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
				return TPExpr(expr());
		}
	}

	function parseConstraintParams():Array<TypeParam> {
		if (!tokEq(peek(), TBinop(OpLt))) return [];
		junk();
		var l = [parseConstraintParam()];
		while (tokEq(peek(), Comma)) { junk(); l.push(parseConstraintParam()); }
		expect(TBinop(OpGt));
		return l;
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
			return new Expr(EArrayDecl([]), Position.union(p1, p2));
		}
		el.push(secureExpr());
		var p2 = p1;
		while (true) {
			if (tokEq(peek(), Comma)) {
				junk();
				if (tokEq(peek(), BkClose)) { p2 = next().pos; break; }
				el.push(secureExpr());
			} else if (tokEq(peek(), BkClose)) {
				p2 = next().pos; break;
			} else {
				return err("Expected , or ]");
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
			expect(DblDot);
			var e = secureExpr();
			acc.push({name: key.name, pos: key.pos, quotes: key.quotes, expr: e});
			pEnd = e.pos;
		}
		return new Expr(EObjectDecl(acc), Position.union(p0, pEnd));
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
				case Kwd(KwdCase):
					var p1 = next().pos;
					var el = psep(Comma, exprOrVar);
					var eg = parseGuardOpt();
					var pdot = expect(DblDot);
					if (el.length == 0) err("case without a pattern is not allowed");
					var b = blockWithPos(p1);
					var bexpr:Null<Expr> = (b.exprs.length == 0) ? null : new Expr(EBlock(b.exprs), Position.union(p1, b.pos));
					var cpos = (b.exprs.length == 0) ? Position.union(p1, pdot) : Position.union(p1, b.pos);
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
				return expr();
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
				idx = save;
				if (!tokEq(peek(), BrClose) && !tokEq(peek(), Eof)
					&& !tokEq(peek(), Kwd(KwdCase)) && !tokEq(peek(), Kwd(KwdDefault)))
					throw er;
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
				var vl = parseVarDecls(false);
				var p2 = semicolon();
				return new Expr(EVars(vl), Position.union(p1, p2));
			case Kwd(KwdFinal):
				// Could be `final x =...` var decl
				var save = idx;
				var p1 = next().pos;
				switch (peek()) {
					case Kwd(KwdVar):
						// Redundant `var` check
						var p2 = next().pos;
						throw new ParserError(Custom("`final var` is not supported, use `final` instead"), Position.union(p1, p2));
					case Const(CIdent(_)), Dollar(_), At:
						var vl = parseVarDecls(true);
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
					var vl = parseVarDecls(isFinal);
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
			case _:
		}
		var e = expr();
		semicolon();
		return e;
	}

	function parseVarDecls(isFinal:Bool):Array<EVar> {
		var vl:Array<EVar> = [parseVarDecl(isFinal)];
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
		return cur().pos;
	}

	function parseField(e1:Expr, efk:EFieldKind, p:Position):Expr {
		switch (peek()) {
			case Kwd(KwdMacro):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "macro", efk), Position.union(e1.pos, p2)));
			case Kwd(KwdExtern):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "extern", efk), Position.union(e1.pos, p2)));
			case Kwd(KwdFunction):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "function", efk), Position.union(e1.pos, p2)));
			case Kwd(KwdNew):
				var p2 = next().pos;
				return exprNext(new Expr(EField(e1, "new", efk), Position.union(e1.pos, p2)));
			case Const(CIdent(f)):
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
					case _: return serror();
				}
		}
	}

	function secureExpr():Expr {
		// A token that cannot start an expression reports Expected expression there. .
		switch (peek()) {
			case PClose | BrClose | BkClose | Semicolon | Comma | Eof:
				throw new ParserError(Expected(["expression"]), peekInfo().pos);
			case _:
		}
		return expr();
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
				var p2 = expect(BrClose);
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
				var vl = parseVarDecls(false);
				return new Expr(EVars(vl), p1);
			case Kwd(KwdFinal):
				var p1 = next().pos;
				var vl = parseVarDecls(true);
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
				var p = next().pos;
				var e = expr();
				return new Expr(EThrow(e), Position.union(p, e.pos));
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
				expect(PClose);
				var e = secureExpr();
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
				expect(PClose);
				var e = secureExpr();
				return new Expr(EWhile(cond, e, NormalWhile), Position.union(p1, e.pos));
			case Kwd(KwdDo):
				var p1 = next().pos;
				var e = secureExpr();
				expect(Kwd(KwdWhile));
				expect(POpen);
				var cond = secureExpr();
				var p2 = expect(PClose);
				return new Expr(EWhile(cond, e, DoWhile), Position.union(p1, p2));
			case Kwd(KwdSwitch):
				var p1 = next().pos;
				var e = secureExpr();
				expect(BrOpen);
				var sw = parseSwitchCases();
				var p2 = expect(BrClose);
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
		var t = parseTypePath();
		if (tokEq(peek(), POpen)) {
			junk();
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
				return serror();
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
		expect(PClose);
		var e1 = secureExpr();
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
				var el = parseCallParamsList();
				var p2 = expect(PClose);
				return exprNext(new Expr(ECall(e1, el), Position.union(e1.pos, p2)));
			case BkOpen:
				junk();
				var e2 = secureExpr();
				var p2 = expect(BkClose);
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
				expect(DblDot);
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
		var first = exprNext(new Expr(EConst(ident), p));
		semicolon();
		var acc:Array<Expr> = [first];
		var rest = blockWithPos(p);
		for (e in rest.exprs) acc.push(e);
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
			var l = parseTypeDecls(pack);
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

	function parseTypeDecls(pack:Array<String>):Array<TypeDecl> {
		var acc:Array<TypeDecl> = [];
		while (true) {
			if (tokEq(peek(), Eof)) break;
			var save = idx;
			var td:TypeDecl;
			try {
				td = parseTypeDecl();
			} catch (e:ParserError) {
				// No error-recovery in batch mode: rethrow if we made progress past EOF
				idx = save;
				if (tokEq(peek(), Eof)) break;
				throw e;
			}
			acc.push(td);
		}
		return acc;
	}

	function parseTypeDecl():TypeDecl {
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
				expect(TBinop(OpAssign));
				var t = parseComplexType();
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
					idx = save;
					var c2 = parseCommonFlags();
					var fp = parseClassFlags();
					return parseClassContent(doc, meta, c.concat(c2), [HAbstract].concat(fp.flags), p1);
				}
			case _:
				// `final NAME...` module-level final var
				var rc = c.copy();
				rc.reverse();
				if (rc.length > 0 && rc[0].flag == DFinal) {
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
				}
				return serror();
		}
	}

	function getDoc():Documentation return null;

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

	function parseClassContent(doc:Documentation, meta:Metadata, c:Array<PlacedDeclFlag>, n:Array<ClassFlag>, p1:Position):TypeDecl {
		var name = typeName();
		var tl = parseConstraintParams();
		var hl:Array<ClassFlag> = [];
		while (true) {
			switch (peek()) {
				case Kwd(KwdExtends):
					junk();
					var t = parseTypePath();
					hl.push(HExtends(t));
				case Kwd(KwdImplements):
					junk();
					var t = parseTypePath();
					hl.push(HImplements(t));
				case _:
					break;
			}
		}
		expect(BrOpen);
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
			if (tokEq(peek(), BrClose) || tokEq(peek(), Eof)) break;
			acc.push(parseClassField(tdecl));
		}
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
				return serror();
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
					junk();
					var t = parseComplexType();
					sl.push(AbTo(t));
				case Const(CIdent("from")):
					junk();
					var t = parseComplexType();
					sl.push(AbFrom(t));
				case _:
					break;
			}
		}
		expect(BrOpen);
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
							junk();
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
				return err("Expected identifier after import");
		}
		var p2 = expect(Semicolon);
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
							junk();
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
				return err("Expected identifier after using");
		}
		var p2 = expect(Semicolon);
		return {decl: EUsing(path), pos: Position.union(p1, p2)};
	}
}
