package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.WithType;
import hxc.codegen.dotnet.CsSyntax;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;
import hxc.typing.Fields;
import hxc.typing.Typer;
import hxc.typing.TyperContext;

// A Haxe name lifted out of inline C#: its typed expression, the Haxe expression that typed it (null when a
// chain cannot go on over it), and the text after its placeholder (`.Name` for a member C# finds on the .NET
// superclass, which CsToIl resolves).
private typedef Lifted = {te:TExpr, e:Null<Expr>, suffix:String};

// The Haxe names of an inline C# text (`untyped __cs__`, `cs.Syntax.code`), resolved in the Haxe scope where the
// typer meets the text, as C#'s simple-name lookup takes them (a local, then a member of the class chain, before
// any type or namespace): each becomes a `{k}` placeholder whose argument is its typed expression (csexpr §6.1
// item 2). Inlining, unrolling, closure capture, boxing and DCE then see ordinary expressions, where gencs's C#
// binds the text to its own renamed output. Type names stay for CsToIl, which resolves them as CLR names.
class CsLift {
	final ctx:TyperContext;
	// The code string's position.
	final p:Position;
	// `sourceOffsets`: where each offset of the code string is in its literal; null to report the names at
	// the whole string.
	final offsets:Null<Array<Int>>;
	// The number of the first added placeholder: the existing ones keep theirs.
	final first:Int;
	final edits:Array<{pos:Int, len:Int, text:String}> = [];
	final added:Array<TExpr> = [];

	function new(ctx:TyperContext, first:Int, p:Position, code:String) {
		this.ctx = ctx;
		this.first = first;
		this.p = p;
		this.offsets = sourceOffsets(code, p);
	}

	// The source offset, from the literal's start, of each offset of `code` and of its end, where `p` is the
	// string literal `code` was written as: past the opening quote and through the escapes \n, \t, \r, \\, \",
	// \', an ASCII \xHH and a single-quoted string's $$. Null for any other source (another escape, a non-ASCII
	// character, a constant that is no literal there), or where the mapped text is not `code`.
	static function sourceOffsets(code:String, p:Position):Null<Array<Int>> {
		var src = try Position.getFileContent(p.file) catch (_:Dynamic) return null;
		if (p.min < 0 || p.max > src.length || p.max - p.min < 2) return null;
		var raw = src.substring(p.min, p.max);
		var quote = raw.charAt(0);
		if ((quote != '"' && quote != "'") || raw.charAt(raw.length - 1) != quote) return null;
		var r = [], text = new StringBuf(), i = 1, end = raw.length - 1;
		while (i < end) {
			var c = raw.charCodeAt(i);
			if (c >= 0x80) return null;
			r.push(i);
			if (c == "\\".code) {
				var n = raw.charAt(i + 1);
				switch (n) {
					case "n": text.add("\n");
					case "t": text.add("\t");
					case "r": text.add("\r");
					case "\\" | '"' | "'": text.add(n);
					case "x":
						var hex = raw.substr(i + 2, 2);
						if (!~/^[0-7][0-9a-fA-F]$/.match(hex)) return null;
						text.addChar(Std.parseInt("0x" + hex));
						i += 2;
					case _: return null;
				}
				i += 2;
			} else if (c == "$".code && quote == "'") {
				if (raw.charAt(i + 1) != "$") return null;
				text.add("$");
				i += 2;
			} else {
				text.addChar(c);
				i++;
			}
		}
		r.push(end);
		return text.toString() == code ? r : null;
	}

	// The text `code` of an inline C# call with the placeholders' arguments `args`, its code string at `p`, with
	// its Haxe names lifted; null when it does not parse or names nothing to lift.
	public static function lift(ctx:TyperContext, code:String, args:Array<TExpr>, p:Position):Null<{code:String, args:Array<TExpr>}> {
		var x = switch (CsSyntax.parse(code, true)) {
			case PExpr(x): x;
			case _: return null;
		}
		// With a placeholder out of bounds nothing is lifted, so CsToIl reports it as gencs does, rather than
		// that placeholder reading a lifted name.
		for (ph in CsSyntax.placeholdersOf(x)) switch (ph.def) {
			case CPlaceholder(n) if (n >= args.length): return null;
			case _:
		}
		var l = new CsLift(ctx, args.length, p, code);
		l.walk(x, false);
		if (l.edits.length == 0) return null;
		// From last to first, so the earlier offsets still hold.
		var edits = l.edits.copy();
		edits.sort((a, b) -> b.pos - a.pos);
		for (ed in edits) code = code.substr(0, ed.pos) + ed.text + code.substr(ed.pos + ed.len);
		return {code: code, args: args.concat(l.added)};
	}

	// Lifts the names of `x`, a call's callee when `callee`.
	function walk(x:CsExpr, callee:Bool):Void {
		var c = chain(x, callee);
		if (c != null) {
			record(c.node, c.lifted);
			return;
		}
		switch (x.def) {
			case CMember(e1, _):
				walk(e1, false);
			case CCall(e1, args):
				walk(e1, true);
				for (a in args) walk(a, false);
			case CIndex(e1, args):
				walk(e1, false);
				for (a in args) walk(a, false);
			case CNew(_, args):
				for (a in args) walk(a, false);
			case CCast(_, e1) | CIs(e1, _) | CUnop(_, e1) | CParen(e1):
				walk(e1, false);
			case CBinop(_, a, b):
				walk(a, false);
				walk(b, false);
			case CPlaceholder(_) | CThis | CIdent(_) | CGlobal(_) | CKeywordType(_) | CLiteral(_):
		}
	}

	function record(node:CsExpr, l:Lifted):Void {
		edits.push({pos: node.pos, len: node.len, text: "{" + (first + added.length) + "}" + l.suffix});
		added.push(l.te);
	}

	// The longest lifted head of `x`: `x` itself, or a receiver of the member accesses `x` is (`this.sb.b` of
	// `this.sb.b.Insert`, where Insert is a .NET member); null when its head is no Haxe name.
	function chain(x:CsExpr, callee:Bool):Null<{node:CsExpr, lifted:Lifted}> {
		var l = switch (x.def) {
			case CThis:
				thisValue(x);
			case CIdent(name):
				simpleName(name, x, callee);
			case CMember(e1, name):
				var r = chain(e1, false);
				if (r == null || r.node != e1) return r;
				var m = member(r.lifted, name, x, callee);
				return m == null ? r : {node: x, lifted: m};
			case _:
				null;
		}
		return l == null ? null : {node: x, lifted: l};
	}

	function pos(x:CsExpr):Position {
		return offsets == null ? p : new Position(p.file, p.min + offsets[x.pos], p.min + offsets[x.pos + x.len]);
	}

	function expr(def:ExprDef, x:CsExpr):Expr return new Expr(def, pos(x));

	static function isExtern(c:TClass):Bool return TypeFunctions.hasClassFlag(c, CExtern);

	// A method a lifted callee calls directly (CsToIl.directMethod): not a dynamic, macro or extern inline one.
	// Its class is a non-extern Haxe class wherever the lift asks.
	static function isMethod(cf:TClassField):Bool {
		return cf.kind.match(Method(MethNormal)) || cf.kind.match(Method(MethInline)) && !TypeFunctions.hasClassFieldFlag(cf, CfExtern);
	}

	// A method named but not called, which C# does not convert to a value here (CS0428): it is not lifted as a
	// value, and CsToIl refuses it.
	static function methodGroup(cf:TClassField, callee:Bool):Bool return !callee && cf.kind.match(Method(_));

	function thisValue(x:CsExpr):Null<Lifted> {
		if (ctx.curclass == TypeFunctions.nullClass || ctx.curfun.match(FunStatic)) return null;
		var e = expr(EConst(CIdent("this")), x);
		return {te: Typer.typeExpr(ctx, e, WithTypeTools.value), e: e, suffix: ""};
	}

	// A simple name: a local, else a member of the current class chain (an instance one outside a static
	// function; a static one of the class or of a Haxe superclass, as C# finds it), else nothing.
	function simpleName(name:String, x:CsExpr, callee:Bool):Null<Lifted> {
		var e = expr(EConst(CIdent(name)), x);
		if (ctx.locals.exists(name)) return {te: Typer.typeExpr(ctx, e, WithTypeTools.value), e: e, suffix: ""};
		var c = ctx.curclass;
		if (c == TypeFunctions.nullClass) return null;
		if (!ctx.curfun.match(FunStatic)) {
			var found = TypeFunctions.rawClassFieldOpt(f -> TypeFunctions.fieldType(f), c, TypeFunctions.extractParamTypes(c.params), name);
			if (found != null) {
				// A member of the .NET superclass: `this` is lifted and CsToIl finds the member, as C# does; so too
				// for a method group, which CsToIl refuses.
				if (found.c2 != null && isExtern(found.c2.c) || methodGroup(found.f, callee)) {
					var t = thisValue(x);
					return t == null ? null : {te: t.te, e: null, suffix: "." + name};
				}
				if (readsByAccessor(found.f)) {
					var t = thisValue(x);
					return t == null || !TypeFunctions.isPhysicalVarField(found.f) ? null : rawRead(t.te, found.c2, found.f, found.t, x);
				}
				return typed(e, callee);
			}
		}
		var cur = c;
		while (cur != null && !isExtern(cur)) {
			var cf = cur.statics.get(name);
			if (cf != null) {
				if (methodGroup(cf, callee)) return null;
				if (readsByAccessor(cf))
					return TypeFunctions.isPhysicalVarField(cf) ? rawRead(null, {c: cur, params: []}, cf, cf.type, x) : null;
				if (cur == c) return typed(e, callee);
				var acc = Fields.fieldAccess(ctx, callee ? MCall([]) : MGet, cf, FHStatic(cur), TexprTools.makeTypeExpr(TClassDecl(cur), e.pos), e.pos);
				return access(acc, null, callee);
			}
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return null;
	}

	// `prefix.name`, when `name` is a field of the non-extern Haxe class `prefix` is (a variable, or a method
	// being called), typed under @:privateAccess, as gencs's C# reaches the private fields Haxe makes public.
	function member(prefix:Lifted, name:String, x:CsExpr, callee:Bool):Null<Lifted> {
		if (prefix.e == null) return null;
		var found = switch (TypeFunctions.follow(prefix.te.type)) {
			case TInst(c, params) if (!isExtern(c) && !c.kind.match(KTypeParameter(_))):
				TypeFunctions.rawClassFieldOpt(f -> TypeFunctions.fieldType(f), c, params, name);
			case _:
				null;
		}
		if (found == null || found.c2 == null || isExtern(found.c2.c)) return null;
		// A call of a variable's value stays for CsToIl to refuse.
		if (methodGroup(found.f, callee) || callee && !isMethod(found.f)) return null;
		if (readsByAccessor(found.f)) return TypeFunctions.isPhysicalVarField(found.f) ? rawRead(prefix.te, found.c2, found.f, found.t, x) : null;
		ctx.privateAccess++;
		var l = try typed(expr(EField(prefix.e, name, EFNormal), x), callee) catch (err:haxe.Exception) {
			ctx.privateAccess--;
			throw err;
		}
		ctx.privateAccess--;
		return l;
	}

	// A Haxe variable read through a getter, or never readable (`var x(get, never)`): gencs writes it as no C#
	// member, so its C# finds none by that name (CS0103, or CS1061 through a value, as CsToIl's `{0}.x` does),
	// or, for a physical one (`@:isVar`, or with a default read or write), as a plain field, which its C#
	// reads directly, bypassing the getter.
	static function readsByAccessor(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Var(vk): vk.read.match(AccCall | AccNever);
			case _: false;
		}
	}

	// The raw read of the physical variable `cf` of `owner` (static where `recv` is null), as gencs's C# reads
	// its field; nothing chains on over it.
	function rawRead(recv:Null<TExpr>, owner:TClassWithParams, cf:TClassField, t:T, x:CsExpr):Lifted {
		var at = pos(x);
		var e = recv == null ? TField(TexprTools.makeTypeExpr(TClassDecl(owner.c), at), FStatic(owner.c, cf)) : TField(recv,
			FInstance(owner.c, owner.params, cf));
		return {te: TypeFunctions.mk(e, t, at), e: null, suffix: ""};
	}

	// The member `e` names, as a value, or as the method a callee calls.
	function typed(e:Expr, callee:Bool):Null<Lifted> {
		if (!callee) return {te: Typer.typeExpr(ctx, e, WithTypeTools.value), e: e, suffix: ""};
		return access(Typer.typeAccess(ctx, e.expr, e.pos, MCall([]), WithTypeTools.value), e, true);
	}

	function access(acc:AccessKind, e:Null<Expr>, callee:Bool):Null<Lifted> {
		return switch (acc) {
			case AKField(fa) if (callee && isMethod(fa.field)):
				{te: FieldAccessTools.getFieldExpr(fa, FCall), e: null, suffix: ""};
			case AKField(fa) if (fa.field.kind.match(Method(MethInline | MethMacro))):
				// An extern inline or macro method has no value to call; the name stays, unknown to CsToIl.
				null;
			case AKExpr(_) | AKField(_) | AKAccessor(_):
				{te: Typer.accGet(ctx, acc), e: e, suffix: ""};
			case _:
				null;
		}
	}
}
