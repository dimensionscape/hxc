package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;
import hxc.filters.NullSafetyScopes.ImmediateExecution;
import hxc.filters.NullSafetyClass.ClassChecker;


enum ScopeType {
	STNormal;
	STLoop;
	STClosure;
	// A closure which gets executed along the "normal" program flow without being delayed or stored somewhere
	STImmediateClosure;
}

enum SafetyMode {
	SMOff;
	SMLoose;
	SMStrict;
	SMStrictThreaded;
}

// Fields accessed through statics/locals/this are tracked by stable subjects; anything else cannot be
// null-checked into safety.
enum SafetySubject {
	SFieldOfClass(path:String, fields:Array<String>);
	SFieldOfLocalVar(id:Int, fields:Array<String>);
	SFieldOfThis(fields:Array<String>);
	SLocalVar(id:Int);
	SNotSuitable;
}

class SafetyError {
	public var msg:String;
	public function new(msg:String) this.msg = msg;
}

class NullSafety {
	public static function run(com:Context, types:Array<ModuleType>):Void {
		var report:Array<{msg:String, pos:Position}> = [];
		var immediateExecution = new ImmediateExecution();
		for (mt in types) switch (mt) {
			case TClassDecl(cls):
				new ClassChecker(cls, immediateExecution, report).check();
			case _:
		}
		// Registered report callbacks consume the errors instead of failing the compile. .
		if (com.nullSafetyReportCallbacks.length > 0) {
			for (cb in com.nullSafetyReportCallbacks) cb(report);
		} else {
			for (err in report) com.addDiagnostic(err.msg, err.pos);
		}
	}

	public static function addError(report:Array<{msg:String, pos:Position}>, msg:String, pos:Position):Void {
		var m = "Null safety: " + msg;
		for (e in report) if (e.msg == m && e.pos.file == pos.file && e.pos.min == pos.min && e.pos.max == pos.max) return;
		report.push({msg: m, pos: pos});
	}

	public static function strType(t:T):String {
		return hxc.core.TPrinting.sTypeStr(t);
	}

	public static function isStringType(t:T):Bool {
		return switch (t) {
			case TInst(c, _) if (c.path.pack.length == 0 && c.path.name == "String"): true;
			case TAbstract(a, [TInst(c, _)]) if (isNullPath(a) && c.path.pack.length == 0 && c.path.name == "String"): true;
			case _: false;
		}
	}

	static inline function isNullPath(a:TAbstract):Bool {
		return a.path.pack.length == 0 && a.path.name == "Null";
	}

	// Explicit Null<> typing (following typedefs and non-core abstracts).
	public static function isNullableType(t:T, dynamicIsNullable:Bool = false):Bool {
		return switch (t) {
			case TMono(r): r.type == null ? false : isNullableType(r.type, dynamicIsNullable);
			case TAbstract(a, [_]) if (isNullPath(a)): true;
			case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Any"): false;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				isNullableType(TypeFunctions.applyParams(a.params, tl, a.thisType), dynamicIsNullable);
			case TLazy(f): isNullableType(TypeFunctions.lazyType(f), dynamicIsNullable);
			case TType(td, tl): isNullableType(TypeFunctions.applyTypedef(td, tl), dynamicIsNullable);
			case TDynamic(_): dynamicIsNullable;
			case _: false;
		}
	}

	// Unwrap casts (only nullable-typed ones when staySafe) and metas.
	public static function revealExpr(expr:TExpr, staySafe:Bool = true):TExpr {
		return switch (expr.expr) {
			case TCast(e, _) if (!staySafe || isNullableType(expr.type)): revealExpr(e, staySafe);
			case TMeta(_, e): revealExpr(e, staySafe);
			case _: expr;
		}
	}

	public static function symbolName(expr:TExpr):String {
		return switch (revealExpr(expr, false).expr) {
			case TField(_, access): fieldName(access);
			case TIdent(name): name;
			case TLocal(v): v.name;
			case TNew(_, _, _): "new";
			case _: "";
		}
	}

	public static function fieldName(access:TFieldAccess):String {
		return switch (access) {
			case FInstance(_, _, cf) | FStatic(_, cf) | FAnon(cf) | FClosure(_, cf): cf.name;
			case FEnum(_, ef): ef.name;
			case FDynamic(n): n;
		}
	}

	static function pathKey(p:hxc.core.Globals.Path):String {
		return p.pack.join(".") + "." + p.name;
	}

	public static function getSubject(mode:SafetyMode, expr:TExpr):SafetySubject {
		return switch (revealExpr(expr).expr) {
			case TLocal(v):
				SLocalVar(v.id);
			case TField({expr: TTypeExpr(_)}, FStatic(cls, field)) if (mode != SMStrictThreaded || TypeFunctions.hasClassFieldFlag(field, CfFinal)):
				SFieldOfClass(pathKey(cls.path), [field.name]);
			case TField({expr: TConst(TThis)}, FInstance(_, _, field) | FAnon(field)) if (mode != SMStrictThreaded || TypeFunctions.hasClassFieldFlag(field, CfFinal)):
				SFieldOfThis([field.name]);
			case TField({expr: TLocal(v)}, FInstance(_, _, field) | FAnon(field)) if (mode != SMStrictThreaded || TypeFunctions.hasClassFieldFlag(field, CfFinal)):
				SFieldOfLocalVar(v.id, [field.name]);
			case TField(e, FInstance(_, _, field) | FAnon(field)) if (mode != SMStrictThreaded):
				switch (getSubject(mode, e)) {
					case SFieldOfClass(path, fields): SFieldOfClass(path, [field.name].concat(fields));
					case SFieldOfThis(fields): SFieldOfThis([field.name].concat(fields));
					case SFieldOfLocalVar(id, fields): SFieldOfLocalVar(id, [field.name].concat(fields));
					case _: SNotSuitable;
				}
			case _:
				SNotSuitable;
		}
	}

	public static function subjectKey(s:SafetySubject):String {
		return switch (s) {
			case SFieldOfClass(path, fields): "c:" + path + "." + fields.join(".");
			case SFieldOfLocalVar(id, fields): "v:" + id + "." + fields.join(".");
			case SFieldOfThis(fields): "t:" + fields.join(".");
			case SLocalVar(id): "l:" + id;
			case SNotSuitable: "!";
		}
	}

	// A call result cannot be tracked; only local/this/static field chains can.
	public static function isSuitable(mode:SafetyMode, expr:TExpr):Bool {
		return switch (revealExpr(expr).expr) {
			case TField({expr: TConst(TThis)}, FInstance(_, _, _)): true;
			case TField({expr: TLocal(_)}, FInstance(_, _, _) | FAnon(_)): true;
			case TField({expr: TTypeExpr(_)}, FStatic(_, _)): true;
			case TLocal(_): true;
			case TField(target, FInstance(_, _, _) | FStatic(_, _) | FAnon(_)) if (mode != SMStrictThreaded): isSuitable(mode, target);
			case _: false;
		}
	}

	// Metadata of each of the callee's declared arguments.
	public static function getArgumentsMeta(callee:TExpr, expectedArgsCount:Int):Array<Metadata> {
		function emptyList(n:Int):Array<Metadata> return [for (_ in 0...(n < 0 ? 0 : n)) ([] : Metadata)];
		switch (callee.expr) {
			case TField(_, FAnon(field) | FClosure(_, field) | FStatic(_, field) | FInstance(_, _, field)):
				for (entry in field.meta) {
					if (entry.name != ":haxe.arguments") continue;
					switch (entry.params) {
						case [{expr: EFunction(_, f)}] if (f.fArgs.length == expectedArgsCount):
							return [for (a in f.fArgs) a.meta != null ? a.meta : ([] : Metadata)];
						case _:
					}
				}
				return emptyList(expectedArgsCount);
			case TFunction(fn) if (fn.args.length == expectedArgsCount):
				return [for (a in fn.args) a.v.meta != null ? a.v.meta : ([] : Metadata)];
			case _:
				return emptyList(expectedArgsCount);
		}
	}

	public static function unfoldNull(t:T):T {
		return switch (t) {
			case TMono(r): r.type == null ? t : unfoldNull(r.type);
			case TAbstract(a, [t1]) if (isNullPath(a)): unfoldNull(t1);
			// A non-core abstract unfolds to its underlying type.
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				unfoldNull(TypeFunctions.applyParams(a.params, tl, a.thisType));
			case TLazy(f): unfoldNull(TypeFunctions.lazyType(f));
			case TType(td, tl): unfoldNull(TypeFunctions.applyTypedef(td, tl));
			case _: t;
		}
	}

	public static function accessedFieldName(access:TFieldAccess):String {
		return fieldName(access);
	}

	public static function containsUnsafeMeta(metadata:Metadata):Bool {
		for (m in metadata) if (m.name == ":nullSafety") switch (m.params) {
			case [{expr: EConst(CIdent("Off"))}]: return true;
			case _:
		}
		return false;
	}

	public static function containsSafeMeta(metadata:Metadata):Bool {
		for (m in metadata) if (m.name == ":nullSafety") switch (m.params) {
			case [] | [{expr: EConst(CIdent("Loose" | "Strict" | "StrictThreaded"))}]: return true;
			case _:
		}
		return false;
	}

	public static function safetyEnabled(meta:Metadata):Bool {
		return containsSafeMeta(meta) && !containsUnsafeMeta(meta);
	}

	public static function safetyMode(metadata:Metadata):Null<SafetyMode> {
		var mode:Null<SafetyMode> = null;
		for (m in metadata) {
			if (mode == SMOff) break;
			if (m.name != ":nullSafety") continue;
			switch (m.params) {
				case [{expr: EConst(CIdent("Off"))}]: mode = SMOff;
				case [] | [{expr: EConst(CIdent("Loose"))}]: if (mode == null) mode = SMLoose;
				case [{expr: EConst(CIdent("Strict"))}]: mode = SMStrict;
				case [{expr: EConst(CIdent("StrictThreaded"))}]: mode = SMStrictThreaded;
				case _:
			}
		}
		return mode == null ? SMOff : mode;
	}

	public static function validateSafetyMeta(report:Array<{msg:String, pos:Position}>, metadata:Metadata):Void {
		for (m in metadata) {
			if (m.name != ":nullSafety") continue;
			switch (m.params) {
				case [] | [{expr: EConst(CIdent("Off" | "Loose" | "Strict" | "StrictThreaded"))}]:
				case _: addError(report, "Invalid argument for @:nullSafety meta", m.pos);
			}
		}
	}

	public static function shouldBeInitialized(field:TClassField):Bool {
		if (TypeFunctions.hasClassFieldFlag(field, CfExtern)) return false;
		return switch (field.kind) {
			case Var({read: AccNormal | AccInline | AccNo}) | Var({write: AccNormal | AccNo}): true;
			case Var(_): TypeFunctions.hasMeta(":isVar", field.meta);
			case _: false;
		}
	}

	public static function isTrace(expr:TExpr):Bool {
		return switch (expr.expr) {
			case TIdent("`trace"): true;
			case TField(_, FStatic(c, cf)) if (c.path.pack.length == 1 && c.path.pack[0] == "haxe" && c.path.name == "Log" && cf.name == "trace"): true;
			case _: false;
		}
	}

	public static function listStartsWithList(haystack:Array<String>, needle:Array<String>):Bool {
		if (needle.length > haystack.length) return false;
		for (i in 0...needle.length) if (haystack[i] != needle[i]) return false;
		return true;
	}

	// Collect exprs checked against null in a condition: (nulls-if-true, not-nulls-if-true).
	public static function processCondition(mode:SafetyMode, condition:TExpr, isNullableExpr:TExpr->Bool, callback:TExpr->Void):{nulls:Array<TExpr>, notNulls:Array<TExpr>} {
		var nulls:Array<TExpr> = [];
		var notNulls:Array<TExpr> = [];
		function add(toNulls:Bool, expr:TExpr):Void {
			expr = revealExpr(expr);
			if (toNulls) nulls.push(expr) else notNulls.push(expr);
		}
		function traverse(positive:Bool, e:TExpr):Void {
			switch (e.expr) {
				case TUnop(Not, Prefix, e1): traverse(!positive, e1);
				case TBinop(OpEq, {expr: TConst(TNull)}, checked) if (isSuitable(mode, checked)):
					add(positive, checked);
				case TBinop(OpEq, checked, {expr: TConst(TNull)}) if (isSuitable(mode, checked)):
					add(positive, checked);
				case TBinop(OpNotEq, {expr: TConst(TNull)}, checked) if (isSuitable(mode, checked)):
					add(!positive, checked);
				case TBinop(OpNotEq, checked, {expr: TConst(TNull)}) if (isSuitable(mode, checked)):
					add(!positive, checked);
				case TBinop(OpEq, e1, checked) if (isSuitable(mode, checked) && !isNullableExpr(e1)):
					if (positive) notNulls.push(checked);
				case TBinop(OpEq, checked, e1) if (isSuitable(mode, checked) && !isNullableExpr(e1)):
					if (positive) notNulls.push(checked);
				case TBinop(OpBoolAnd, l, r) if (positive):
					traverse(positive, l);
					traverse(positive, r);
				case TBinop(OpBoolAnd, l, r) if (!positive):
					for (_ in 0...2) {
						var res = processCondition(mode, l, isNullableExpr, callback);
						for (x in res.notNulls) add(true, x);
					}
				case TBinop(OpBoolOr, l, r) if (!positive):
					traverse(positive, l);
					traverse(positive, r);
				case TBinop(OpBoolOr, l, r) if (positive):
					for (_ in 0...2) {
						var res = processCondition(mode, l, isNullableExpr, callback);
						for (x in res.nulls) add(true, x);
					}
				case TParenthesis(e1): traverse(positive, e1);
				case _: callback(e);
			}
		}
		traverse(true, condition);
		return {nulls: nulls, notNulls: notNulls};
	}
}

// Can a value of type a be passed where b is expected, null-safety-wise. Throws SafetyError.
class Unificator {
	var stack:Array<{a:T, b:T}> = [];
	// Typedef application builds fresh nodes, so a recursive type cannot end the recursion by node
	// identity; a depth cap backstops it.
	var depth:Int = 0;

	public function new() {}

	public function unify(a:T, b:T):Void {
		if (a == b) return;
		if (depth > 100) return;
		depth++;
		try {
			unifyInner(a, b);
			depth--;
		} catch (e:Dynamic) {
			depth--;
			throw e;
		}
	}

	function unifyInner(a:T, b:T):Void {
		switch ([a, b]) {
			case [_, TAbstract(ab, [_])] if (ab.path.pack.length == 0 && ab.path.name == "Null"):
			case [TAbstract(ab, [_]), _] if (ab.path.pack.length == 0 && ab.path.name == "Null" && !NullSafety.isNullableType(b)):
				throw new SafetyError("");
			case [TInst(_, ap), TInst(_, bp)] if (ap.length == bp.length):
				for (i in 0...ap.length) unify(ap[i], bp[i]);
			case [TAnon(aa), TAnon(ba)]:
				unifyAnonToAnon(aa, ba);
			case [TInst(ac, ap), TAnon(ba)]:
				unifyClassToAnon(ac, ap, ba);
			case [TFun(asig), TFun(bsig)]:
				unifyFunctions(asig, bsig);
			case [TLazy(f), _]: unify(TypeFunctions.lazyType(f), b);
			case [_, TLazy(f)]: unify(a, TypeFunctions.lazyType(f));
			case [TMono(r), _]: if (r.type != null) unify(r.type, b);
			case [_, TMono(r)]: if (r.type != null) unify(a, r.type);
			case [TType(td, tl), _]: unifyRec(a, b, function() unify(TypeFunctions.applyTypedef(td, tl), b));
			case [_, TType(td, tl)]: unifyRec(a, b, function() unify(a, TypeFunctions.applyTypedef(td, tl)));
			case [TAbstract(ab, tl), _] if (!TypeFunctions.hasMeta(":coreType", ab.meta)):
				unify(TypeFunctions.applyParams(ab.params, tl, ab.thisType), b);
			case [_, TAbstract(ab, tl)] if (!TypeFunctions.hasMeta(":coreType", ab.meta)):
				unify(a, TypeFunctions.applyParams(ab.params, tl, ab.thisType));
			case _:
		}
	}

	function unifyRec(a:T, b:T, frun:Void->Void):Void {
		for (e in stack) if (hxc.core.TypeUnification.fastEq(a, e.a) && hxc.core.TypeUnification.fastEq(b, e.b)) return;
		stack.push({a: a, b: b});
		try {
			frun();
			stack.pop();
		} catch (e:Dynamic) {
			stack.pop();
			throw e;
		}
	}

	function unifyAnonToAnon(a:TAnon, b:TAnon):Void {
		for (name in b.fields.keys()) {
			var af = a.fields.get(name);
			if (af != null) unify(af.type, b.fields.get(name).type);
		}
	}

	function unifyClassToAnon(a:TClass, aParams:TParams, b:TAnon):Void {
		for (name in b.fields.keys()) {
			var af = a.fields.get(name);
			if (af != null) {
				var at = TypeFunctions.applyParams(a.params, aParams, af.type);
				unify(at, b.fields.get(name).type);
			}
		}
	}

	function unifyFunctions(a:TSignature, b:TSignature):Void {
		switch (b.ret) {
			case TAbstract(ab, []) if (ab.path.pack.length == 0 && ab.path.name == "Void"):
			case _: unify(a.ret, b.ret);
		}
		var n = a.args.length < b.args.length ? a.args.length : b.args.length;
		for (i in 0...n) unify(b.args[i].t, a.args[i].t);
	}
}
