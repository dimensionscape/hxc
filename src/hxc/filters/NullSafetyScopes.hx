package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.filters.NullSafety;

// Check whether an anonymous function passed to a method argument executes before the call returns.
class ImmediateExecution {
	var cache:haxe.ds.ObjectMap<TClassField, Map<Int, Bool>> = new haxe.ds.ObjectMap();

	public function new() {}

	function getCache(field:TClassField):Map<Int, Bool> {
		var c = cache.get(field);
		if (c == null) {
			c = new Map();
			cache.set(field, c);
		}
		return c;
	}

	public function check(callee:TExpr, argNum:Int):Bool {
		var clsField = switch (NullSafety.revealExpr(callee).expr) {
			case TField(_, FClosure(co, f)) if (co != null && f.kind.match(Method(MethNormal | MethInline))): {cls: co.c, field: f};
			case TField(_, FStatic(c, f)) if (f.kind.match(Method(MethNormal | MethInline))): {cls: c, field: f};
			case TField(_, FInstance(c, _, f)) if (f.kind.match(Method(MethNormal | MethInline))): {cls: c, field: f};
			case _: null;
		};
		if (clsField == null) return false;
		var cls = clsField.cls, field = clsField.field;
		// Array methods are known to be pure/immediate.
		if (cls.path.pack.length == 0 && cls.path.name == "Array") return true;
		if (field.expr == null) return false;
		return switch (field.expr.expr) {
			case TFunction(fn) if (TypeFunctions.hasClassFieldFlag(field, CfFinal) || !isOverridden(cls, field)):
				if (argNum < 0 || argNum >= fn.args.length) return false;
				var c = getCache(field);
				if (c.exists(argNum)) return c.get(argNum);
				c.set(argNum, true);
				var argVar = fn.args[argNum].v;
				var result = !isStored(argVar, fn.expr);
				c.set(argNum, result);
				result;
			case _: false;
		}
	}

	static function isOverridden(cls:TClass, field:TClassField):Bool {
		// Conservative: any descendant declaring the same field counts as an override.
		function walk(c:TClass):Bool {
			for (d in c.descendants) {
				if (d.fields.exists(field.name)) return true;
				if (walk(d)) return true;
			}
			return false;
		}
		return walk(cls);
	}

	// Is fnVar passed somewhere else (stored to a var/field, captured, thrown...).
	function isStored(fnVar:TVar, expr:TExpr):Bool {
		switch (expr.expr) {
			case TThrow({expr: TLocal(v)}) if (v.id == fnVar.id): return true;
			case TReturn(r) if (r != null):
				switch (r.expr) { case TLocal(v) if (v.id == fnVar.id): return true; case _: }
			case TCast({expr: TLocal(v)}, _) if (v.id == fnVar.id): return true;
			case TMeta(_, {expr: TLocal(v)}) if (v.id == fnVar.id): return true;
			case TBinop(OpAssign, _, {expr: TLocal(v)}) if (v.id == fnVar.id): return true;
			case TFunction(fn):
				var found = false;
				function captured(e:TExpr):Void {
					if (found) return;
					switch (e.expr) {
						case TLocal(v) if (v.id == fnVar.id): found = true;
						case _: hxc.core.TexprTools.iter(captured, e);
					}
				}
				captured(fn.expr);
				return found;
			case TCall(callee, args):
				if (isStored(fnVar, callee)) return true;
				for (i in 0...args.length) {
					var arg = args[i];
					var stored = switch (arg.expr) {
						case TLocal(v) if (v.id == fnVar.id): !check(callee, i);
						case _: isStored(fnVar, arg);
					};
					if (stored) return true;
				}
				return false;
			case _:
		}
		var found = false;
		hxc.core.TexprTools.iter(function(e) if (!found && isStored(fnVar, e)) found = true, expr);
		return found;
	}
}

// Per-loop/function safety scope.
class SafetyScope {
	public var mode:SafetyMode;
	public var scopeType:ScopeType;
	public var safeLocals:Map<String, TExpr>;
	public var neverSafe:Map<String, TExpr>;
	var declarations:Map<Int, TVar> = new Map();
	// Key -> parsed subject side table (keys are strings; the enum is needed for matching).
	public var parsedSubjects:Map<String, SafetySubject> = new Map();

	public function new(mode:SafetyMode, scopeType:ScopeType, safeLocals:Map<String, TExpr>, neverSafe:Map<String, TExpr>) {
		this.mode = mode;
		this.scopeType = scopeType;
		this.safeLocals = safeLocals;
		this.neverSafe = neverSafe;
	}

	public function resetTo(state:Map<String, TExpr>):Void {
		safeLocals.clear();
		for (k in state.keys()) safeLocals.set(k, state.get(k));
	}

	public function declareVar(v:TVar):Void declarations.set(v.id, v);

	public function ownsVar(v:TVar):Bool return declarations.exists(v.id);

	public function isSafe(expr:TExpr):Bool {
		if (!NullSafety.isNullableType(expr.type)) return true;
		return switch (getSubject(expr)) {
			case SNotSuitable: false;
			case subj:
				var key = NullSafety.subjectKey(subj);
				!neverSafe.exists(key) && safeLocals.exists(key);
		}
	}

	public function addToSafety(expr:TExpr):Void {
		switch (getSubject(expr)) {
			case SNotSuitable:
			case subj: safeLocals.set(NullSafety.subjectKey(subj), expr);
		}
	}

	public function removeFromSafety(expr:TExpr, forever:Bool = false):Void {
		switch (getSubject(expr)) {
			case SNotSuitable:
			case subj:
				var key = NullSafety.subjectKey(subj);
				safeLocals.remove(key);
				if (forever) neverSafe.set(key, expr);
		}
	}

	public function filterSafety(sample:Map<String, TExpr>):Void {
		for (key in [for (k in safeLocals.keys()) k])
			if (!sample.exists(key)) safeLocals.remove(key);
	}

	// Assigning to expr un-safes any tracked chain rooted in it.
	public function reassigned(expr:TExpr):Void {
		var subj = getSubject(expr);
		if (subj == SNotSuitable) return;
		switch (subj) {
			case SFieldOfClass(_, _) | SFieldOfLocalVar(_, _) | SFieldOfThis(_): dropSafeFieldsInStrictMode();
			case _:
		}
		function startsWith(safeFields:Array<String>, fields:Array<String>):Bool {
			var a = safeFields.copy(); a.reverse();
			var b = fields.copy(); b.reverse();
			return NullSafety.listStartsWithList(a, b);
		}
		var removeList:Array<String> = [];
		for (key in safeLocals.keys()) {
			var safeSubj = parsedSubjects.get(key);
			if (safeSubj == null) continue;
			switch ([safeSubj, subj]) {
				case [SFieldOfLocalVar(safeId, _), SLocalVar(vId)] if (safeId == vId):
					removeList.push(key);
				case [SFieldOfLocalVar(safeId, safeFields), SFieldOfLocalVar(vId, fields)] if (safeId == vId && startsWith(safeFields, fields)):
					removeList.push(key);
				case [SFieldOfClass(safePath, safeFields), SFieldOfClass(path, fields)] if (safePath == path && startsWith(safeFields, fields)):
					removeList.push(key);
				case [SFieldOfThis(safeFields), SFieldOfThis(fields)] if (startsWith(safeFields, fields)):
					removeList.push(key);
				case _:
			}
		}
		for (k in removeList) safeLocals.remove(k);
	}

	public function getSubject(expr:TExpr):SafetySubject {
		var subj = NullSafety.getSubject(mode, expr);
		if (subj != SNotSuitable) parsedSubjects.set(NullSafety.subjectKey(subj), subj);
		return subj;
	}

	public function callMade():Void dropSafeFieldsInStrictMode();

	function dropSafeFieldsInStrictMode():Void {
		switch (mode) {
			case SMOff | SMLoose:
			case SMStrict | SMStrictThreaded:
				var removeList:Array<String> = [];
				for (key in safeLocals.keys()) {
					switch (parsedSubjects.get(key)) {
						case SFieldOfLocalVar(_, _) | SFieldOfClass(_, _) | SFieldOfThis(_): removeList.push(key);
						case _:
					}
				}
				for (k in removeList) safeLocals.remove(k);
		}
	}
}
