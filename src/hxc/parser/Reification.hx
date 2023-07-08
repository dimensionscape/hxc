package hxc.parser;

import hxc.ast.Ast;
import hxc.ast.Position;

class Reification {
	// curPos is the `@:pos` override, kept as an instance field.
	// inMacro selects the position-encoding strategy in `toPos`.
	var inMacro:Bool;
	var curPos:Null<Expr>;

	public function new(inMacro:Bool) {
		this.inMacro = inMacro;
		this.curPos = null;
	}

	public static function reifyExpr(e:Expr, inMacro:Bool):Expr {
		var r = new Reification(inMacro);
		var re = r.toExpr(e);
		var ct:TypeHint = {ct: CTPath({tpackage: ["haxe", "macro"], tname: "Expr", tparams: [], tsub: null}), pos: Position.nullPos};
		return new Expr(ECheckType(re, ct), e.pos);
	}

	public static function reifyComplexType(ct:ComplexType, p:Position):Expr {
		var r = new Reification(false);
		var re = r.toCType(ct, p);
		var hint:TypeHint = {ct: CTPath({tpackage: ["haxe", "macro"], tname: "Expr", tparams: [], tsub: "ComplexType"}), pos: Position.nullPos};
		return new Expr(ECheckType(re, hint), p);
	}

	function mkEnum(_ename:String, n:String, vl:Array<Expr>, p:Position):Expr {
		var pmin = new Position(p.file, p.min, p.min);
		var constr = new Expr(EConst(CIdent(n)), pmin);
		return vl.length == 0 ? constr : new Expr(ECall(constr, vl), pmin);
	}

	function toConst(c:Constant, p:Position):Expr {
		return switch (c) {
			case CInt(i, suffix):
				var sfx = suffix == null ? new Expr(EConst(CIdent("null")), p) : new Expr(EConst(CString(suffix, SDoubleQuotes)), p);
				mkEnum("Constant", "CInt", [new Expr(EConst(CString(i, SDoubleQuotes)), p), sfx], p);
			case CFloat(f, suffix):
				var sfx = suffix == null ? new Expr(EConst(CIdent("null")), p) : new Expr(EConst(CString(suffix, SDoubleQuotes)), p);
				mkEnum("Constant", "CFloat", [new Expr(EConst(CString(f, SDoubleQuotes)), p), sfx], p);
			case CString(s, qs):
				var qsE = mkEnum("StringLiteralKind", (qs == SDoubleQuotes ? "DoubleQuotes" : "SingleQuotes"), [], p);
				mkEnum("Constant", "CString", [new Expr(EConst(CString(s, SDoubleQuotes)), p), qsE], p);
			case CIdent(s):
				mkEnum("Constant", "CIdent", [new Expr(EConst(CString(s, SDoubleQuotes)), p)], p);
			case CRegexp(r, o):
				mkEnum("Constant", "CRegexp", [new Expr(EConst(CString(r, SDoubleQuotes)), p), new Expr(EConst(CString(o, SDoubleQuotes)), p)], p);
		}
	}

	function toBinop(o:Binop, p:Position):Expr {
		inline function op(n:String):Expr return mkEnum("Binop", n, [], p);
		return switch (o) {
			case OpAdd: op("OpAdd");
			case OpMult: op("OpMult");
			case OpDiv: op("OpDiv");
			case OpSub: op("OpSub");
			case OpAssign: op("OpAssign");
			case OpEq: op("OpEq");
			case OpNotEq: op("OpNotEq");
			case OpGt: op("OpGt");
			case OpGte: op("OpGte");
			case OpLt: op("OpLt");
			case OpLte: op("OpLte");
			case OpAnd: op("OpAnd");
			case OpOr: op("OpOr");
			case OpXor: op("OpXor");
			case OpBoolAnd: op("OpBoolAnd");
			case OpBoolOr: op("OpBoolOr");
			case OpShl: op("OpShl");
			case OpShr: op("OpShr");
			case OpUShr: op("OpUShr");
			case OpMod: op("OpMod");
			case OpAssignOp(o2): mkEnum("Binop", "OpAssignOp", [toBinop(o2, p)], p);
			case OpInterval: op("OpInterval");
			case OpArrow: op("OpArrow");
			case OpIn: op("OpIn");
			case OpNullCoal: op("OpNullCoal");
		}
	}

	function toString(s:String, p:Position):Expr {
		if (s.length > 1 && s.charCodeAt(0) == "$".code) {
			return new Expr(EConst(CIdent(s.substr(1))), p);
		}
		return new Expr(EConst(CString(s, SDoubleQuotes)), p);
	}

	function toArray<T>(f:(T, Position) -> Expr, a:Array<T>, p:Position):Expr {
		return new Expr(EArrayDecl([for (s in a) f(s, p)]), p);
	}

	function toNull(p:Position):Expr return new Expr(EConst(CIdent("null")), p);

	function toOpt<T>(f:(T, Position) -> Expr, v:Null<T>, p:Position):Expr {
		return v == null ? toNull(p) : f(v, p);
	}

	function toBool(o:Bool, p:Position):Expr {
		return new Expr(EConst(CIdent(o ? "true" : "false")), p);
	}

	function toObj(fields:Array<{name:String, e:Expr}>, p:Position):Expr {
		return new Expr(EObjectDecl([for (f in fields) {name: f.name, pos: Position.nullPos, quotes: NoQuotes, expr: f.e}]), p);
	}

	function toPos(p:Position):Expr {
		if (curPos != null) return curPos;
		var file = new Expr(EConst(CString(p.file, SDoubleQuotes)), p);
		var pmin = new Expr(EConst(CInt(Std.string(p.min), null)), p);
		var pmax = new Expr(EConst(CInt(Std.string(p.max), null)), p);
		return toObj([{name: "file", e: file}, {name: "min", e: pmin}, {name: "max", e: pmax}], p);
	}

	function contextField(name:String, p:Position):Expr {
		var haxe = new Expr(EConst(CIdent("haxe")), p);
		var macro_ = new Expr(EField(haxe, "macro", EFNormal), p);
		var ctx = new Expr(EField(macro_, "Context", EFNormal), p);
		return new Expr(EField(ctx, name, EFNormal), p);
	}

	function toEncPos(p:Position):Expr {
		if (curPos != null) return curPos;
		return new Expr(ECall(contextField("makePosition", p), [toPos(p)]), p);
	}

	function toExprArray(a:Array<Expr>, p:Position):Expr {
		if (a.length == 1) {
			switch (a[0].expr) {
				case EMeta(m, e1) if (m.name == "$a" && m.params.length == 0):
					return switch (e1.expr) {
						case EArrayDecl(el): toExprArray(el, p);
						case _: e1;
					}
				case _:
			}
		}
		return toArray(function(e, _) return toExpr(e), a, p);
	}

	function toMeta(meta:Metadata, p:Position):Expr {
		return toArray(function(m:MetadataEntry, _) {
			return toObj([
				{name: "name", e: toString(m.name, m.pos)},
				{name: "params", e: toExprArray(m.params, m.pos)},
				{name: "pos", e: toPos(m.pos)},
			], m.pos);
		}, meta, p);
	}

	public function toExpr(e:Expr):Expr {
		var p = e.pos;
		inline function expr(n:String, vl:Array<Expr>):Expr {
			var ee = mkEnum("ExprDef", n, vl, p);
			return toObj([{name: "expr", e: ee}, {name: "pos", e: toPos(p)}], p);
		}
		inline function loop(e2:Expr):Expr return toExpr(e2);

		switch (e.expr) {
			// `$ident` escape: a bare `$x` ident (>1 char, not `$__mk_pos__`) reifies to the
			case EConst(CIdent(n)) if (n.length > 1 && n.charCodeAt(0) == "$".code && n != "$__mk_pos__"):
				return toString(n, p);
			case EConst(c):
				return expr("EConst", [toConst(c, p)]);
			case EArray(e1, e2):
				return expr("EArray", [loop(e1), loop(e2)]);
			case EBinop(op, e1, e2):
				return expr("EBinop", [toBinop(op, p), loop(e1), loop(e2)]);
			case EField(e1, s, efk):
				var efkN = switch (efk) { case EFNormal: "Normal"; case EFSafe: "Safe"; };
				var pf = new Position(p.file, p.max - s.length, p.max);
				return expr("EField", [loop(e1), toString(s, pf), mkEnum("EFieldKind", efkN, [], pf)]);
			case EParenthesis(e1):
				return expr("EParenthesis", [loop(e1)]);
			case EObjectDecl(fl):
				var arr = new Expr(EArrayDecl([for (f in fl) {
					var qkN = switch (f.quotes) { case NoQuotes: "Unquoted"; case DoubleQuotes: "Quoted"; };
					toObj([
						{name: "field", e: toString(f.name, p)},
						{name: "expr", e: loop(f.expr)},
						{name: "quotes", e: mkEnum("QuoteStatus", qkN, [], f.pos)},
					], p);
				}]), p);
				return expr("EObjectDecl", [arr]);
			case EArrayDecl(el):
				return expr("EArrayDecl", [toExprArray(el, p)]);
			case ECall(e1, el):
				return expr("ECall", [loop(e1), toExprArray(el, p)]);
			case ENew(t, el):
				return expr("ENew", [toTPath(t.path, p), toExprArray(el, p)]);
			case EUnop(op, flag, e1):
				var opN = switch (op) {
					case Increment: "OpIncrement";
					case Decrement: "OpDecrement";
					case Not: "OpNot";
					case Neg: "OpNeg";
					case NegBits: "OpNegBits";
					case Spread: "OpSpread";
				};
				return expr("EUnop", [mkEnum("Unop", opN, [], p), toBool(flag == Postfix, p), loop(e1)]);
			case EBlock(el):
				return expr("EBlock", [toExprArray(el, p)]);
			case EFor(e1, e2):
				return expr("EFor", [loop(e1), loop(e2)]);
			case EIf(e1, e2, eelse):
				return expr("EIf", [loop(e1), loop(e2), toOptExpr(eelse, p)]);
			case ESwitch(e1, cases, edef):
				var casesExpr = toArray(function(c:SwitchCase, pp:Position) {
					return toObj([
						{name: "values", e: toExprArray(c.values, pp)},
						{name: "guard", e: toOptExpr(c.guard, pp)},
						{name: "expr", e: toOptExpr(c.expr, pp)},
					], pp);
				}, cases, p);
				var defExpr = edef == null ? toNull(p) : toOptExpr(edef.e, edef.pos);
				return expr("ESwitch", [loop(e1), casesExpr, defExpr]);
			case EWhile(e1, e2, flag):
				return expr("EWhile", [loop(e1), loop(e2), toBool(flag == NormalWhile, p)]);
			case EReturn(eo):
				return expr("EReturn", [toOptExpr(eo, p)]);
			case EBreak:
				return expr("EBreak", []);
			case EContinue:
				return expr("EContinue", []);
			case EUntyped(e1):
				return expr("EUntyped", [loop(e1)]);
			case EThrow(e1):
				return expr("EThrow", [loop(e1)]);
			case ETry(e1, catches):
				var arr = toArray(function(c:Catch, pp:Position) {
					return toObj([
						{name: "name", e: toString(c.name.name, c.name.pos)},
						{name: "type", e: toOpt(function(th, _pp) return toTypeHint(th), c.type, pp)},
						{name: "expr", e: loop(c.expr)},
					], pp);
				}, catches, p);
				return expr("ETry", [loop(e1), arr]);
			case ETernary(e1, e2, e3):
				return expr("ETernary", [loop(e1), loop(e2), loop(e3)]);
			case EVars(vl):
				var arr = toArray(function(v:EVar, pp:Position) {
					return toObj([
						{name: "name", e: toString(v.evName.name, v.evName.pos)},
						{name: "namePos", e: toPos(v.evName.pos)},
						{name: "type", e: toOpt(function(th, _pp) return toTypeHint(th), v.evType, pp)},
						{name: "expr", e: toOptExpr(v.evExpr, pp)},
						{name: "isFinal", e: toBool(v.evFinal, pp)},
						{name: "isStatic", e: toBool(v.evStatic, pp)},
						{name: "meta", e: toMeta(v.evMeta, pp)},
					], pp);
				}, vl, p);
				return expr("EVars", [arr]);
			case EFunction(kind, f):
				return expr("EFunction", [toFunctionKind(kind, p), toFun(f, p)]);
			// `@:pos(p) e`: override the reified positions with `p`.
			case EMeta(m, e1) if (m.name == ":pos" && m.params.length == 1):
				var old = curPos;
				curPos = m.params[0];
				var re = loop(e1);
				curPos = old;
				return re;
			// `$e{ e }` / `${ e }` (Meta.Dollar "" | "e"): splice the expr value directly.
			case EMeta(m, e1) if (m.name == "$" || m.name == "$e"):
				return e1;
			// `$a{ e }`: array-of-exprs splice into an EArrayDecl.
			case EMeta(m, e1) if (m.name == "$a"):
				return switch (e1.expr) {
					case EArrayDecl(el): expr("EArrayDecl", [toExprArray(el, p)]);
					case _: expr("EArrayDecl", [e1]);
				}
			// `$b{ e }`: block splice.
			case EMeta(m, e1) if (m.name == "$b"):
				return expr("EBlock", [e1]);
			// `$i{ e }`: identifier-from-string splice.
			case EMeta(m, e1) if (m.name == "$i"):
				return expr("EConst", [mkEnum("Constant", "CIdent", [e1], e1.pos)]);
			case EMeta(m, e1) if (m.name == "$v"):
				switch (e1.expr) {
					case EParenthesis({expr: ECheckType(e2, {ct: CTPath({tname: "String", tpackage: []})})}):
						return expr("EConst", [mkEnum("Constant", "CString", [e2], e2.pos)]);
					case EParenthesis({expr: ECheckType(e2, {ct: CTPath({tname: "Int", tpackage: []})})}):
						return expr("EConst", [mkEnum("Constant", "CInt", [e2], e2.pos)]);
					case EParenthesis({expr: ECheckType(e2, {ct: CTPath({tname: "Float", tpackage: []})})}):
						return expr("EConst", [mkEnum("Constant", "CFloat", [e2], e2.pos)]);
					case EConst(CInt(s, "i64")):
						return expr("EConst", [
							mkEnum("Constant", "CInt", [
								new Expr(EConst(CString(s, SDoubleQuotes)), e1.pos),
								new Expr(EConst(CString("i64", SDoubleQuotes)), e1.pos),
							], e1.pos)
						]);
					case _:
						// `haxe.macro.Context.makeExpr(e1, to_enc_pos)`.
						// To_enc_pos (in_macro=false) = `Context.makePosition`; our
						// makePosition is identity over the {file,min,max} object, so we pass the
						// position object directly (decodePos accepts it either way).
						return new Expr(ECall(contextField("makeExpr", p), [e1, toEncPos(e1.pos)]), p);
				}
			// `$p{ e }`: haxe.macro.MacroStringTools.toFieldExpr(e).
			case EMeta(m, e1) if (m.name == "$p"):
				var hx = new Expr(EConst(CIdent("haxe")), p);
				var mac = new Expr(EField(hx, "macro", EFNormal), p);
				var mst = new Expr(EField(mac, "MacroStringTools", EFNormal), p);
				return new Expr(ECall(new Expr(EField(mst, "toFieldExpr", EFNormal), p), [e1]), p);
			// Generic `@m e` meta reifies to EMeta.
			case EMeta(m, e1):
				// The `expr` wrapper still carries the outer expr pos.
				var entry = toObj([
					{name: "name", e: toString(m.name, m.pos)},
					{name: "params", e: toExprArray(m.params, m.pos)},
					{name: "pos", e: toPos(m.pos)},
				], m.pos);
				return expr("EMeta", [entry, loop(e1)]);
			case ECheckType(e1, ct):
				return expr("ECheckType", [loop(e1), toTypeHint(ct)]);
			case ECast(e1, ct):
				return expr("ECast", [loop(e1), toOpt(function(th, _pp) return toTypeHint(th), ct, p)]);
			case EIs(e1, ct):
				return expr("EIs", [loop(e1), toTypeHint(ct)]);
			case EDisplay(e1, dk):
				return expr("EDisplay", [loop(e1), mkEnum("DisplayKind", Ast.sDisplayKind(dk), [], p)]);
			case _:
				throw new ParserError(Custom("macro reification of this expression form is not yet supported"), p);
		}
	}

	function toOptExpr(eo:Null<Expr>, p:Position):Expr {
		return eo == null ? toNull(p) : toExpr(eo);
	}

	function toTPath(t:TypePath, p:Position):Expr {
		var len = t.tname.length;
		// `$Name` escape: a bare `$Name` path reifies to the ident itself;
		// With type params, `$TP<Int>` reuses TP but overwrites its params.
		if (t.tpackage.length == 0 && len > 1 && t.tname.charCodeAt(0) == "$".code) {
			var ei = new Expr(EConst(CIdent(t.tname.substr(1))), p);
			if (t.tparams.length == 0) return ei;
			var ea = toArray(function(tp, pp) return toTParam(tp, pp), t.tparams, p);
			return toObj([
				{name: "pack", e: new Expr(EField(ei, "pack", EFNormal), p)},
				{name: "name", e: new Expr(EField(ei, "name", EFNormal), p)},
				{name: "sub", e: new Expr(EField(ei, "sub", EFNormal), p)},
				{name: "params", e: ea},
			], p);
		}
		var fields:Array<{name:String, e:Expr}> = [
			{name: "pack", e: toArray(function(s, pp) return toString(s, pp), t.tpackage, p)},
			{name: "name", e: toString(t.tname, p)},
			{name: "params", e: toArray(function(tp, pp) return toTParam(tp, pp), t.tparams, p)},
		];
		if (t.tsub != null) fields.push({name: "sub", e: toString(t.tsub, p)});
		return toObj(fields, p);
	}

	function toTParam(t:TypeParamOrConst, p:Position):Expr {
		return switch (t) {
			case TPType(th): mkEnum("TypeParam", "TPType", [toCType(th.ct, p)], p);
			case TPExpr(e): mkEnum("TypeParam", "TPExpr", [toExpr(e)], p);
		}
	}

	function toTypeHint(th:TypeHint):Expr {
		return toCType(th.ct, th.pos);
	}

	function toCType(ct:ComplexType, p:Position):Expr {
		inline function ce(n:String, vl:Array<Expr>):Expr return mkEnum("ComplexType", n, vl, p);
		return switch (ct) {
			// A bare `$Name` path (no pack/params/sub) is the escape ident.
			case CTPath(t) if (t.tpackage.length == 0 && t.tparams.length == 0 && t.tsub == null
				&& t.tname.length > 0 && t.tname.charCodeAt(0) == "$".code):
				toString(t.tname, p);
			case CTPath(t): ce("TPath", [toTPath(t, p)]);
			case CTFunction(args, ret): ce("TFunction", [toArray(function(a, pp) return toTypeHint(a), args, p), toTypeHint(ret)]);
			case CTAnonymous(fields): ce("TAnonymous", [toArray(function(f, pp) return toCField(f, pp), fields, p)]);
			case CTParent(t): ce("TParent", [toTypeHint(t)]);
			case CTExtend(paths, fields):
				ce("TExtend", [
					toArray(function(a:PlacedTypePath, pp) return toTPath(a.path, pp), paths, p),
					toArray(function(f, pp) return toCField(f, pp), fields, p),
				]);
			case CTOptional(t): ce("TOptional", [toTypeHint(t)]);
			case CTNamed(n, t): ce("TNamed", [toString(n.name, n.pos), toTypeHint(t)]);
			case CTIntersection(tl): ce("TIntersection", [toArray(function(a, pp) return toCType(a.ct, a.pos), tl, p)]);
		}
	}

	function toFunctionKind(kind:FunctionKind, p:Position):Expr {
		return switch (kind) {
			case FKAnonymous:
				mkEnum("FunctionKind", "FAnonymous", [], p);
			case FKArrow:
				mkEnum("FunctionKind", "FArrow", [], p);
			case FKNamed(name, inlined):
				mkEnum("FunctionKind", "FNamed", [toString(name.name, name.pos), toBool(inlined, name.pos)], p);
		}
	}

	function toFun(f:Func, p:Position):Expr {
		var pf = new Position(p.file, p.min, p.min);
		inline function farg(a:FunctionArg, pp:Position):Expr {
			var fields:Array<{name:String, e:Expr}> = [
				{name: "name", e: toString(a.name.name, pp)},
				{name: "opt", e: toBool(a.opt, pp)},
				{name: "type", e: toOpt(function(th, _pp) return toTypeHint(th), a.type, pp)},
			];
			if (a.value != null) fields.push({name: "value", e: toExpr(a.value)});
			return toObj(fields, pp);
		}
		function fparam(t:TypeParam, pp:Position):Expr {
			var fields:Array<{name:String, e:Expr}> = [
				{name: "name", e: toString(t.tpName.name, t.tpName.pos)},
				{name: "constraints", e: t.tpConstraints == null ? toNull(pp) : toArray(function(c, pp2) return toCType(c.ct, pp2), [t.tpConstraints], pp)},
				{name: "params", e: toArray(function(t2, pp2) return fparam(t2, pp2), t.tpParams, pp)},
			];
			return toObj(fields, pp);
		}
		var fields:Array<{name:String, e:Expr}> = [
			{name: "args", e: toArray(function(a, pp) return farg(a, pp), f.fArgs, pf)},
			{name: "ret", e: toOpt(function(th, _pp) return toTypeHint(th), f.fType, pf)},
			{name: "expr", e: toOpt(function(e, _pp) return toExpr(e), f.fExpr, pf)},
			{name: "params", e: toArray(function(t, pp) return fparam(t, pp), f.fParams, pf)},
		];
		return toObj(fields, pf);
	}

	function toAccess(a:PlacedAccess, p:Position):Expr {
		var n = switch (a.access) {
			case APublic: "APublic";
			case APrivate: "APrivate";
			case AStatic: "AStatic";
			case AOverride: "AOverride";
			case ADynamic: "ADynamic";
			case AInline: "AInline";
			case AMacro: "AMacro";
			case AFinal: "AFinal";
			case AExtern: "AExtern";
			case AAbstract: "AAbstract";
			case AOverload: "AOverload";
		};
		return mkEnum("Access", n, [], p);
	}

	function toCField(f:ClassField, _p:Position):Expr {
		var p = f.cffPos;
		inline function toKind(k:ClassFieldKind):Expr {
			return switch (k) {
				case FVar(ct, e):
					mkEnum("FieldType", "FVar", [
						toOpt(function(th, _pp) return toTypeHint(th), ct, p),
						toOpt(function(e2, _pp) return toExpr(e2), e, p),
					], p);
				case FFun(fn):
					mkEnum("FieldType", "FFun", [toFun(fn, p)], p);
				case FProp(get, set, t, e):
					mkEnum("FieldType", "FProp", [
						toString(get.name, get.pos),
						toString(set.name, set.pos),
						toOpt(function(th, _pp) return toTypeHint(th), t, p),
						toOpt(function(e2, _pp) return toExpr(e2), e, p),
					], p);
			}
		}
		var fields:Array<{name:String, e:Expr}> = [];
		fields.push({name: "name", e: toString(f.cffName.name, f.cffName.pos)});
		var docText = Ast.genDocTextOpt(f.cffDoc);
		if (docText != null) fields.push({name: "doc", e: toString(docText, p)});
		if (f.cffAccess.length != 0) fields.push({name: "access", e: toArray(function(a, pp) return toAccess(a, pp), f.cffAccess, p)});
		fields.push({name: "kind", e: toKind(f.cffKind)});
		fields.push({name: "pos", e: toPos(f.cffPos)});
		if (f.cffMeta.length != 0) fields.push({name: "meta", e: toMeta(f.cffMeta, p)});
		return toObj(fields, p);
	}

	function toTParamDecl(t:TypeParam, p:Position):Expr {
		return toObj([
			{name: "name", e: toString(t.tpName.name, t.tpName.pos)},
			{name: "params", e: new Expr(EArrayDecl([for (t2 in t.tpParams) toTParamDecl(t2, p)]), p)},
			{name: "meta", e: toMeta(t.tpMeta, p)},
			{name: "constraints", e: new Expr(EArrayDecl(t.tpConstraints == null ? [] : [toCType(t.tpConstraints.ct, p)]), p)},
			{name: "defaultType", e: toOpt(function(th, _pp) return toCType(th.ct, p), t.tpDefault, p)},
		], p);
	}

	public static function reifyTypeDef(decl:TypeDecl, p:Position):Expr {
		var r = new Reification(false);
		var re = r.toTypeDef(decl);
		var ct:TypeHint = {ct: CTPath({tpackage: ["haxe", "macro"], tname: "Expr", tparams: [], tsub: "TypeDefinition"}), pos: Position.nullPos};
		return new Expr(ECheckType(re, ct), p);
	}

	function toTypeDef(decl:TypeDecl):Expr {
		var p = decl.pos;
		switch (decl.decl) {
			case EClass(d):
				var ext:Null<Expr> = null;
				var impl:Array<Expr> = [];
				var interf = false;
				var fin = false;
				var abstr = false;
				var isExtern = false;
				for (flag in d.dFlags) {
					switch (flag) {
						case HExtern: isExtern = true;
						case HPrivate:
						case HInterface: interf = true;
						case HExtends(t):
							if (ext == null) ext = toTPath(t.path, p);
							else impl.unshift(toTPath(t.path, p));
						case HImplements(i): impl.unshift(toTPath(i.path, p));
						case HFinal: fin = true;
						case HAbstract: abstr = true;
					}
				}
				impl.reverse();
				var extE = ext == null ? new Expr(EConst(CIdent("null")), p) : ext;
				var kind = mkEnum("TypeDefKind", "TDClass", [
					extE,
					new Expr(EArrayDecl(impl), p),
					toBool(interf, p),
					toBool(fin, p),
					toBool(abstr, p),
				], p);
				return toObj([
					{name: "pack", e: new Expr(EArrayDecl([]), p)},
					{name: "name", e: toString(d.dName.name, d.dName.pos)},
					{name: "pos", e: toPos(p)},
					{name: "meta", e: toMeta(d.dMeta, p)},
					{name: "params", e: new Expr(EArrayDecl([for (tp in d.dParams) toTParamDecl(tp, p)]), p)},
					{name: "isExtern", e: toBool(isExtern, p)},
					{name: "kind", e: kind},
					{name: "fields", e: new Expr(EArrayDecl([for (fld in d.dData) toCField(fld, p)]), p)},
				], p);
			case _:
				// Only `macro class {...}` is reified here. Other decls are out of scope.
				throw new ParserError(Custom("macro reification of this type definition is not supported"), p);
		}
	}
}
