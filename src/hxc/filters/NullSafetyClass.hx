package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.filters.NullSafety;
import hxc.filters.NullSafetyScopes;
import hxc.filters.NullSafetyChecker;

// Per-class driver: field bodies, accessors, var-field initialization.
class ClassChecker {
	var cls:TClass;
	var clsMeta:Metadata;
	var isSafeClass:Bool;
	var immediateExecution:ImmediateExecution;
	var report:Array<{msg:String, pos:Position}>;
	var checker:ExprChecker;
	var mode:Null<SafetyMode> = null;

	public function new(cls:TClass, immediateExecution:ImmediateExecution, report:Array<{msg:String, pos:Position}>) {
		this.cls = cls;
		clsMeta = switch (cls.kind) {
			case KAbstractImpl(a): cls.meta.concat(a.meta);
			case _: cls.meta;
		};
		isSafeClass = NullSafety.safetyEnabled(clsMeta);
		this.immediateExecution = immediateExecution;
		this.report = report;
		checker = new ExprChecker(SMLoose, immediateExecution, report);
	}

	public function check():Void {
		NullSafety.validateSafetyMeta(report, clsMeta);
		if (isSafeClass && !TypeFunctions.hasClassFlag(cls, CExtern) && !TypeFunctions.hasClassFlag(cls, CInterface))
			checkVarFields();
		function checkField(isStatic:Bool, f:TClassField):Void {
			NullSafety.validateSafetyMeta(report, f.meta);
			switch (NullSafety.safetyMode(clsMeta.concat(f.meta))) {
				case SMOff:
				case fieldMode:
					if (f.expr != null)
						getChecker(fieldMode).checkRootExpr(f.expr);
					checkAccessors(isStatic, f);
			}
		}
		if (cls.constructor != null) checkField(false, cls.constructor);
		for (f in cls.orderedFields) checkField(false, f);
		for (f in cls.orderedStatics) checkField(true, f);
	}

	// A getter/setter of a non-nullable property must return safe values.
	function checkAccessors(isStatic:Bool, field:TClassField):Void {
		switch (field.kind) {
			case Var(vk) if (!NullSafety.isNullableType(field.type)):
				var fields = isStatic ? cls.statics : cls.fields;
				function checkAccessor(prefix:String):Void {
					var accessor = fields.get(prefix + field.name);
					if (accessor == null || !isInSafety(accessor)) return;
					if (accessor.expr == null) return;
					switch (accessor.expr.expr) {
						case TFunction(fn):
							var fn2 = new TFunc(fn.args, field.type, fn.expr);
							getChecker(classSafetyMode()).checkRootExpr(TypeFunctions.mk(TFunction(fn2), accessor.expr.type, accessor.expr.pos));
						case _:
					}
				}
				if (vk.read == AccCall) checkAccessor("get_");
				if (vk.write == AccCall) checkAccessor("set_");
			case _:
		}
	}

	function classSafetyMode():SafetyMode {
		if (mode == null) mode = NullSafety.safetyMode(clsMeta);
		return mode;
	}

	function getChecker(m:SafetyMode):ExprChecker {
		if (checker.mode != m)
			checker = new ExprChecker(m, immediateExecution, report);
		return checker;
	}

	function isInSafety(field:TClassField):Bool {
		return (isSafeClass && !NullSafety.containsUnsafeMeta(field.meta)) || NullSafety.safetyEnabled(field.meta);
	}

	function checkVarFields():Void {
		function checkField(isStatic:Bool, field:TClassField):Void {
			NullSafety.validateSafetyMeta(report, field.meta);
			if (!NullSafety.shouldBeInitialized(field)) return;
			if (NullSafety.isNullableType(field.type) || !isInSafety(field)) return;
			if (field.expr == null) {
				if (isStatic)
					checker.error("Field \"" + field.name + "\" is not nullable thus should have an initial value.", [field.pos]);
			} else {
				if (!@:privateAccess checker.canPassExpr(field.expr, field.type, field.expr.pos))
					checker.error("Cannot set nullable initial value for not-nullable field \"" + field.name + "\".", [field.pos]);
			}
		}
		for (f in cls.orderedFields) checkField(false, f);
		for (f in cls.orderedStatics) checkField(true, f);
		checkFieldsInitializationInConstructor();
	}

	// Instance fields without initial values must initialize in the constructor before use.
	function checkFieldsInitializationInConstructor():Void {
		var fieldsToInitialize:Map<String, TClassField> = new Map();
		var thisVars:Map<Int, TVar> = new Map();
		for (f in cls.orderedFields) {
			if (NullSafety.shouldBeInitialized(f)
					&& !NullSafety.isNullableType(f.type)
					&& !NullSafety.containsUnsafeMeta(f.meta)
					&& f.expr == null)
				fieldsToInitialize.set(f.name, f);
		}
		function initCount(m:Map<String, TClassField>):Int {
			var n = 0;
			for (_ in m.keys()) n++;
			return n;
		}
		function checkUnsafeUsage(initList:Map<String, TClassField>, safetyEnabled:Bool, e:TExpr):Void {
			if (initCount(initList) == 0) return;
			switch (e.expr) {
				case TField({expr: TConst(TThis)}, FInstance(_, _, field)):
					if (initList.exists(field.name))
						checker.error("Cannot use field " + field.name + " until initialization.", [e.pos]);
				case TField({expr: TConst(TThis)}, FClosure(_, field)):
					checker.error("Cannot use method " + field.name + " until all instance fields are initialized.", [e.pos]);
				case TCall({expr: TField({expr: TConst(TThis)}, FInstance(_, _, field))}, args):
					checker.error("Cannot call method " + field.name + " until all instance fields are initialized.", [e.pos]);
					for (a in args) checkUnsafeUsage(initList, safetyEnabled, a);
				case TConst(TThis) if (safetyEnabled):
					checker.error("Cannot use \"this\" until all instance fields are initialized.", [e.pos]);
				case TLocal(v) if (safetyEnabled && thisVars.exists(v.id)):
					checker.error("Cannot use \"this\" until all instance fields are initialized.", [e.pos]);
				case TMeta(m, e1) if (m.name == ":nullSafety" && m.params.length == 1 && m.params[0].expr.match(EConst(CIdent("Off")))):
					TexprTools.iter(function(x) checkUnsafeUsage(initList, false, x), e1);
				case TMeta(m, e1) if (m.name == ":nullSafety"):
					TexprTools.iter(function(x) checkUnsafeUsage(initList, true, x), e1);
				case _:
					TexprTools.iter(function(x) checkUnsafeUsage(initList, safetyEnabled, x), e);
			}
		}
		function copyMap(m:Map<String, TClassField>):Map<String, TClassField> {
			var out:Map<String, TClassField> = new Map();
			for (k in m.keys()) out.set(k, m.get(k));
			return out;
		}
		function traverse(initList:Map<String, TClassField>, e:TExpr):Map<String, TClassField> {
			switch (e.expr) {
				case TBinop(OpAssign, {expr: TField({expr: TConst(TThis)}, FInstance(_, _, f))}, rightExpr):
					initList.remove(f.name);
					traverse(initList, rightExpr);
				case TWhile(condition, body, DoWhile):
					checkUnsafeUsage(initList, true, condition);
					traverse(initList, body);
				case TBlock(exprs):
					for (x in exprs) traverse(initList, x);
				case TIf(_, ifBlock, elseBlock) if (elseBlock != null):
					var ifInit = traverse(copyMap(initList), ifBlock);
					var elseInit = traverse(copyMap(initList), elseBlock);
					initList.clear();
					for (k in ifInit.keys()) initList.set(k, ifInit.get(k));
					for (k in elseInit.keys()) initList.set(k, elseInit.get(k));
				// Var _gthis = this
				case TVarExpr(v, init) if (init != null && init.expr.match(TConst(TThis))):
					thisVars.set(v.id, v);
				case _:
					checkUnsafeUsage(initList, true, e);
			}
			return initList;
		}
		if (cls.constructor != null && cls.constructor.expr != null) {
			switch (cls.constructor.expr.expr) {
				case TFunction(fn): traverse(fieldsToInitialize, fn.expr);
				case _:
			}
		}
		for (name in fieldsToInitialize.keys()) {
			checker.error(
				"Field \"" + name + "\" is not nullable thus should have an initial value or should be initialized in constructor.",
				[fieldsToInitialize.get(name).pos]);
		}
	}
}
