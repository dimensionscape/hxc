package hxia.lower;

import hxia.cppia.ModuleIR;
import hxia.cppia.OpTree;
import hxia.cppia.Decoder;

// H2 T1 tier (first slice): lower a decoded ModuleIR to JS source, evaluated at load. The gate is identical
// output T3 == T1 (see tools/hxia-h2.sh).
//
// SCOPE of this slice: main-only pure-compute programs - literals, locals, binops, control flow, local
// closures, and host/script static calls. Script classes/instances, enums, and the exception model are
// later slices; an unhandled op throws a LowerError naming it, so coverage grows visibly.
//
// The emitted module is a function `($host) => { ...script statics...; run main }`. Host statics go through
// `$host.callStatic(type, member, args)`; script statics call the lowered JS function. Every interpreter
// local `id` becomes a JS `var L<id>` in its function scope (ids are per-function).
class LowerError {
	public var message:String;
	public function new(m:String) this.message = m;
}

class JsLowerer {
	final strings:Array<String>;
	final types:Array<String>;
	final tree:ModuleTree;
	// Fully-qualified names of script statics ("Class.method"), so a CALLSTATIC to one is a direct
	// call rather than a host dispatch.
	final scriptStatics:Map<String, Bool> = new Map();
	var buf:StringBuf;

	public function new(ir:ModuleIR) {
		this.strings = [for (b in ir.strings) b.getString(0, b.length)];
		this.types = [for (b in ir.types) b.getString(0, b.length)];
		this.tree = Decoder.decode(ir);
		for (d in tree.decls)
			if (d.kind == "class") {
				var cn = types[d.ints[0]];
				for (f in d.fields)
					if (f.kind == "function" && f.ints[0] == 1 && f.body != null)
						scriptStatics.set(cn + "." + strings[f.ints[2]], true);
			}
	}

	public static function lower(ir:ModuleIR):String
		return new JsLowerer(ir).emit();

	function emit():String {
		buf = new StringBuf();
		buf.add("(function($host){\n\"use strict\";\nvar SS = {};\n");
		for (d in tree.decls)
			if (d.kind == "class")
				emitClassStatics(d);
			else if (d.kind == "enum" || d.kind == "interface")
				throw new LowerError("decl kind '" + d.kind + "' not lowered yet");
		if (tree.hasMain && tree.main != null) {
			buf.add("return function(){ ");
			emitExpr(tree.main);
			buf.add("; };\n");
		} else {
			buf.add("return function(){};\n");
		}
		buf.add("})");
		return buf.toString();
	}

	function emitClassStatics(d:DeclNode):Void {
		var cn = types[d.ints[0]];
		for (f in d.fields) {
			if (f.kind != "function" || f.ints[0] != 1 || f.body == null)
				continue;
			var name = strings[f.ints[2]];
			buf.add("SS[" + jsStr(cn + "." + name) + "] = ");
			emitFun(f.body);
			buf.add(";\n");
		}
	}

	// A FUN op: ints = [type, argc, then per arg: nameId, id, captured, type, marker]; kids are the
	// default-value exprs (for marker==1 args, in order) followed by the body block.
	function emitFun(fun:OpNode):Void {
		var argc = fun.ints[1];
		var argIds = [];
		var defaults = [];
		var idx = 2;
		for (i in 0...argc) {
			argIds.push(fun.ints[idx + 1]);
			defaults.push(fun.ints[idx + 4] == 1);
			idx += 5;
		}
		buf.add("function(");
		for (i in 0...argc) {
			if (i > 0) buf.add(",");
			buf.add("A" + i);
		}
		buf.add("){\n");
		// Bind args to their local slots, applying defaults for absent/null optional args.
		var defKid = 0;
		for (i in 0...argc) {
			buf.add("var L" + argIds[i] + " = A" + i + ";\n");
			if (defaults[i]) {
				buf.add("if (L" + argIds[i] + " == null) L" + argIds[i] + " = ");
				emitExpr(fun.kids[defKid++]);
				buf.add(";\n");
			}
		}
		// The body is the block after the default-value kids.
		var body = fun.kids[fun.kids.length - 1];
		emitStmt(body);
		buf.add("}");
	}

	// Emit a node in STATEMENT position (its value is discarded).
	function emitStmt(n:OpNode):Void {
		switch (n.op) {
			case "BLOCK", "TVARS":
				buf.add("{\n");
				for (k in n.kids) { emitStmt(k); buf.add(";\n"); }
				buf.add("}");
			case "VARDECL":
				buf.add("var L" + n.ints[1]);
			case "VARDECLI":
				buf.add("var L" + n.ints[1] + " = ");
				emitExpr(n.kids[0]);
			case "IF":
				buf.add("if (");
				emitExpr(n.kids[0]);
				buf.add(") ");
				emitStmt(n.kids[1]);
			case "IFELSE":
				buf.add("if (");
				emitExpr(n.kids[0]);
				buf.add(") ");
				emitStmt(n.kids[1]);
				buf.add(" else ");
				emitStmt(n.kids[2]);
			case "WHILE":
				// While ints[0] = normalWhile (1) vs do-while (0).
				if (n.ints[0] == 1) {
					buf.add("while (");
					emitExpr(n.kids[0]);
					buf.add(") ");
					emitStmt(n.kids[1]);
				} else {
					buf.add("do ");
					emitStmt(n.kids[1]);
					buf.add(" while (");
					emitExpr(n.kids[0]);
					buf.add(")");
				}
			case "BREAK":
				buf.add("break");
			case "CONTINUE":
				buf.add("continue");
			case "RETVAL":
				buf.add("return ");
				emitExpr(n.kids[0]);
			case "RETURN":
				buf.add("return");
			case _:
				// Any other node is an expression whose value is discarded.
				emitExpr(n);
		}
	}

	// Emit a node in EXPRESSION position (produces a JS value).
	function emitExpr(n:OpNode):Void {
		switch (n.op) {
			case "i": buf.add(Std.string(n.ints[0]));
			case "f": buf.add(strings[n.ints[0]]);
			case "s": buf.add(jsStr(strings[n.ints[0]]));
			case "true": buf.add("true");
			case "false": buf.add("false");
			case "NULL": buf.add("null");
			case "VAR": buf.add("L" + n.ints[0]);
			case "BLOCK":
				// A block in expression position: emit as a comma-expression yielding the last value.
				buf.add("(");
				for (i in 0...n.kids.length) {
					if (i > 0) buf.add(", ");
					emitExpr(n.kids[i]);
				}
				buf.add(")");
			case "SET":
				emitSet(n);
			case "+", "-", "*", "/", "%", "<", ">", "<=", ">=", "==", "!=", "&", "|", "^", "<<", ">>", "&&", "||":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" " + n.op + " ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case ">>>":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" >>> ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case "NEG":
				buf.add("(-");
				emitExpr(n.kids[0]);
				buf.add(")");
			case "!":
				buf.add("(!");
				emitExpr(n.kids[0]);
				buf.add(")");
			case "~":
				buf.add("(~");
				emitExpr(n.kids[0]);
				buf.add(")");
			case "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", ">>=", ">>>=", "<<=":
				emitModify(n);
			case "++", "+++", "--", "---":
				emitCrement(n);
			case "ADEF":
				buf.add("[");
				for (i in 0...n.kids.length) {
					if (i > 0) buf.add(", ");
					emitExpr(n.kids[i]);
				}
				buf.add("]");
			case "ARRAYI":
				emitExpr(n.kids[0]);
				buf.add("[");
				emitExpr(n.kids[1]);
				buf.add("]");
			case "CALLSTATIC":
				emitCallStatic(n);
			case "CALL":
				emitExpr(n.kids[0]);
				buf.add("(");
				for (i in 1...n.kids.length) {
					if (i > 1) buf.add(", ");
					emitExpr(n.kids[i]);
				}
				buf.add(")");
			case "FUN":
				emitFun(n);
			case "IFELSE":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" ? ");
				emitExpr(n.kids[1]);
				buf.add(" : ");
				emitExpr(n.kids[2]);
				buf.add(")");
			case "ISNULL":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" == null)");
			case "NOTNULL":
				buf.add("(");
				emitExpr(n.kids[0]);
				buf.add(" != null)");
			case "CAST", "CASTINT", "CASTBOOL", "TCAST":
				// CAST is identity on a dynamic heap. TCAST is a checked `cast(e, T)`; its throw-on-bad-
				// cast is a later slice, so it is identity here (correct for a valid cast, which the
				// pure-compute corpus only uses).
				emitExpr(n.kids[0]);
			case _:
				throw new LowerError("op '" + n.op + "' not lowered yet");
		}
	}

	function emitSet(n:OpNode):Void {
		var lv = n.kids[0];
		switch (lv.op) {
			case "VAR":
				buf.add("(L" + lv.ints[0] + " = ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case "ARRAYI":
				buf.add("(");
				emitExpr(lv.kids[0]);
				buf.add("[");
				emitExpr(lv.kids[1]);
				buf.add("] = ");
				emitExpr(n.kids[1]);
				buf.add(")");
			case _:
				throw new LowerError("SET lvalue '" + lv.op + "' not lowered yet");
		}
	}

	function emitModify(n:OpNode):Void {
		var lv = n.kids[0];
		if (lv.op != "VAR")
			throw new LowerError("modify lvalue '" + lv.op + "' not lowered yet");
		buf.add("(L" + lv.ints[0] + " " + n.op + " ");
		emitExpr(n.kids[1]);
		buf.add(")");
	}

	function emitCrement(n:OpNode):Void {
		// "++" / "--" are post; "+++" / "---" are pre (gencpp's prefix variants).
		var lv = n.kids[0];
		if (lv.op != "VAR")
			throw new LowerError("crement lvalue '" + lv.op + "' not lowered yet");
		var v = "L" + lv.ints[0];
		switch (n.op) {
			case "++": buf.add("(" + v + "++)");
			case "--": buf.add("(" + v + "--)");
			case "+++": buf.add("(++" + v + ")");
			case "---": buf.add("(--" + v + ")");
			case _: throw new LowerError("crement '" + n.op + "'");
		}
	}

	function emitCallStatic(n:OpNode):Void {
		var typeName = types[n.ints[0]];
		var member = strings[n.ints[1]];
		var key = typeName + "." + member;
		if (scriptStatics.exists(key)) {
			buf.add("SS[" + jsStr(key) + "](");
			for (i in 0...n.kids.length) {
				if (i > 0) buf.add(", ");
				emitExpr(n.kids[i]);
			}
			buf.add(")");
		} else {
			// Host static: dispatch through the registry seam.
			buf.add("$host.callStatic(" + jsStr(typeName) + ", " + jsStr(member) + ", [");
			for (i in 0...n.kids.length) {
				if (i > 0) buf.add(", ");
				emitExpr(n.kids[i]);
			}
			buf.add("])");
		}
	}

	// A JS string literal for an arbitrary Haxe string (JSON string encoding is valid JS).
	static function jsStr(s:String):String
		return haxe.Json.stringify(s);
}
