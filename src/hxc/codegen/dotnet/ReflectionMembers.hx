package hxc.codegen.dotnet;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.TclassToIl;
import hxc.codegen.dotnet.TexprToIl;

// The reflection members reflectionCFs.ml gives a class in gencs's model.
enum ReflectMember {
	RLookupField;
	RLookupField_f;
	RLookupSetField;
	RLookupSetField_f;
	RGetField;
	RGetField_f;
	RSetField;
	RSetField_f;
	RInvokeField;
	RGetFields;
}

// A field reflection reaches: one of the class's own, or one of a superclass outside gencs's model,
// whose fields the class reflects too; `owner` declares it.
private typedef Entry = {cf:TClassField, owner:TClass};

// What collect_fields keeps: every field, the methods only, or the variables and dynamic methods.
private enum Collect {
	CAll;
	CMethods;
	CVars;
}

// gencs's `__hx_getField`, `__hx_setField` (and their `_f` versions for Float values), `__hx_invokeField`
// and `__hx_getFields`, each a switch over the field's compile-time hash (FieldHashes) whose default
// asks the base class, and on a root class (one below a type outside the model, or a struct) the
// `__hx_lookup*` members those defaults reach. HxObject declares the root members in hxc's runtime copy,
// so a class extending it overrides only the members it has cases for.
class ReflectionMembers {
	// The classes reflectionCFs gives members: classes in gencs's model (structs included, which then
	// implement haxe.lang.IHxObject themselves).
	public static function applies(c:TClass):Bool {
		return HxGen.hasCtorModel(c);
	}

	// A class whose members are the first of the hierarchy: below a type outside gencs's model, or a
	// struct. A class with no superclass extends HxObject.
	public static function isRoot(c:TClass):Bool {
		if (TypeFunctions.hasMeta(":struct", c.meta)) return true;
		return c.superClass != null && !HxGen.isHxGen(TClassDecl(c.superClass.c));
	}

	static function name(r:ReflectMember):String {
		return switch (r) {
			case RLookupField: "__hx_lookupField";
			case RLookupField_f: "__hx_lookupField_f";
			case RLookupSetField: "__hx_lookupSetField";
			case RLookupSetField_f: "__hx_lookupSetField_f";
			case RGetField: "__hx_getField";
			case RGetField_f: "__hx_getField_f";
			case RSetField: "__hx_setField";
			case RSetField_f: "__hx_setField_f";
			case RInvokeField: "__hx_invokeField";
			case RGetFields: "__hx_getFields";
		}
	}

	// The member's signature, as IHxObject declares it.
	static function signature(g:DotnetCtx, r:ReflectMember):{ret:IlSigNorm, args:Array<IlSigNorm>, names:Array<String>} {
		var head:Array<IlSigNorm> = [LString, LInt32], headNames = ["field", "hash"];
		inline function sig(ret:IlSigNorm, args:Array<IlSigNorm>, names:Array<String>) return {ret: ret, args: head.concat(args), names: headNames.concat(names)};
		return switch (r) {
			case RLookupField: sig(LObject, [LBool, LBool], ["throwErrors", "isCheck"]);
			case RLookupField_f: sig(LFloat64, [LBool], ["throwErrors"]);
			case RLookupSetField: sig(LObject, [LObject], ["value"]);
			case RLookupSetField_f: sig(LFloat64, [LFloat64], ["value"]);
			case RGetField: sig(LObject, [LBool, LBool, LBool], ["throwErrors", "isCheck", "handleProperties"]);
			case RGetField_f: sig(LFloat64, [LBool, LBool], ["throwErrors", "handleProperties"]);
			case RSetField: sig(LObject, [LObject, LBool], ["value", "handleProperties"]);
			case RSetField_f: sig(LFloat64, [LFloat64, LBool], ["value", "handleProperties"]);
			case RInvokeField: sig(LObject, [LVector(LObject)], ["dynargs"]);
			case RGetFields: {ret: LVoid, args: [g.types.toSig(g.ctx.basic.tarray(g.ctx.basic.tstring))], names: ["baseArr"]};
		}
	}

	// collect_fields: the class's own fields, then those of each superclass outside gencs's model, each
	// name once (the first seen), the whole list in reverse. Fields gencs skips (@:compilerGenerated,
	// @:skipReflection) and those with no body here (extern fields of a Haxe class, macros) are left out.
	static function collect(c:TClass, what:Collect):Array<Entry> {
		var seen = new Map<String, Bool>();
		var r:Array<Entry> = [];
		var cur = c;
		while (cur != null) {
			for (cf in cur.orderedFields) {
				if (seen.exists(cf.name)) continue;
				if (TypeFunctions.hasMeta(":compilerGenerated", cf.meta) || TypeFunctions.hasMeta(":skipReflection", cf.meta)) continue;
				if (TypeFunctions.hasClassFieldFlag(cf, CfExtern) && !TypeFunctions.hasClassFlag(cur, CExtern)) continue;
				// An overriding dynamic method is the field its superclass declares.
				if (cf.kind.match(Method(MethDynamic)) && TypeFunctions.hasClassFieldFlag(cf, CfOverride)) continue;
				var keep = switch [what, cf.kind] {
					case [_, Method(MethMacro)]: false;
					case [CAll, _]: true;
					case [CMethods, Method(MethDynamic)]: false;
					case [CMethods, Method(_)]: true;
					case [CVars, Method(MethDynamic) | Var(_)]: true;
					case _: false;
				}
				if (!keep) continue;
				seen.set(cf.name, true);
				r.push({cf: cf, owner: cur});
			}
			cur = cur.superClass != null && !HxGen.isHxGen(TClassDecl(cur.superClass.c)) ? cur.superClass.c : null;
		}
		r.reverse();
		return r;
	}

	static function readsCall(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Var(v): v.read == AccCall;
			case _: false;
		}
	}

	static function writesCall(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Var(v): v.write == AccCall;
			case _: false;
		}
	}

	static inline function readOnly(cf:TClassField):Bool return TypeFunctions.hasMeta(":readOnly", cf.meta);

	// A field getField_f and setField_f handle: a Float-like type (Int, UInt, Float, Single, the small
	// integers; not Int64), Dynamic or a type parameter.
	static function floatLike(g:DotnetCtx, cf:TClassField):Bool {
		// A haxe.lang.Null<T>, a type parameter's too, is not (gencs's real type).
		if (TexprDynamic.isNullType(cf.type)) return false;
		// gencs's is_dynamic: Dynamic, an unbound monomorph, a type parameter, EnumValue and an anonymous structure that
		// is not a class's, enum's or abstract's statics.
		if (TexprDynamic.isDynamic(cf.type)) return true;
		var s = try g.types.toSig(cf.type) catch (_:Unsupported) null;
		return s != null && s.match(LInt32 | LUInt32 | LFloat64 | LFloat32 | LInt8 | LUInt8 | LInt16 | LUInt16 | LChar);
	}

	static function getCases(g:DotnetCtx, c:TClass, isFloat:Bool):Array<Entry> {
		return [
			for (e in collect(c, isFloat ? CVars : CAll))
				if ((!isFloat || floatLike(g, e.cf)) && (readsCall(e.cf) || TypeFunctions.isPhysicalField(e.cf) && !readOnly(e.cf))) e
		];
	}

	static function setCases(g:DotnetCtx, c:TClass, isFloat:Bool):Array<Entry> {
		return [
			for (e in collect(c, CVars))
				if (!readOnly(e.cf) && (!isFloat || floatLike(g, e.cf)) && (writesCall(e.cf) || TypeFunctions.isPhysicalField(e.cf))) e
		];
	}

	// invokeField's cases: the class's own methods, and in one case calling Runtime.slowCallField, the
	// overriding ones and those of superclasses outside the model. An @:overload override that erasure
	// made a new overload (TclassToIl.overriddenOverload) is the class's own, as gencs's FixOverrides
	// leaves it.
	static function invokeCases(g:DotnetCtx, c:TClass):{own:Array<Entry>, old:Array<Entry>} {
		var own = [], old = [];
		for (e in collect(c, CMethods)) {
			var isOld = !c.fields.exists(e.cf.name)
				|| TypeFunctions.hasClassFieldFlag(e.cf, CfOverride) && (e.owner != c || TclassToIl.overriddenOverload(g, c, e.cf) == null);
			if (isOld) old.push(e) else own.push(e);
		}
		return {own: own, old: old};
	}

	static function listed(c:TClass):Array<Entry> {
		return [
			for (e in collect(c, CVars))
				if (!TypeFunctions.hasClassFieldFlag(e.cf, CfOverride)) e
		];
	}

	// The members the class gets, in gencs's order: on a root the lookups first; a member
	// the class declares itself (HxObject, DynamicObject) is not generated, nor one of a class extending
	// another in the model that has no cases.
	public static function members(g:DotnetCtx, c:TClass):Array<ReflectMember> {
		if (!applies(c)) return [];
		var root = isRoot(c);
		var r = [];
		inline function declared(n:String) return c.fields.exists(n);
		if (root && !declared("__hx_lookupField")) r = r.concat([RLookupField, RLookupField_f, RLookupSetField, RLookupSetField_f]);
		// gencs's order: implement_get_set adds setField_f, setField, getField, getField_f.
		if (!declared("__hx_getField")) {
			if (root || setCases(g, c, true).length > 0) r.push(RSetField_f);
			if (root || setCases(g, c, false).length > 0) r.push(RSetField);
			if (root || getCases(g, c, false).length > 0) r.push(RGetField);
			if (root || getCases(g, c, true).length > 0) r.push(RGetField_f);
		}
		if (!declared("__hx_invokeField") && (root || invokeCases(g, c).own.length > 0)) r.push(RInvokeField);
		if (!declared("__hx_getFields") && (root || listed(c).length > 0)) r.push(RGetFields);
		return r;
	}

	// gencs refuses two names a class reflects with the same hash.
	public static function checkConflicts(g:DotnetCtx, c:TClass):Void {
		if (!applies(c)) return;
		// The class's code hashes names into the same table (TexprDynamic.hash).
		var owner = DotnetTypes.haxePath(TClassDecl(c));
		for (e in collect(c, CAll)) {
			var other = FieldHashes.claim(owner, FieldHashes.hash(e.cf.name), e.cf.name);
			if (other != null) {
				g.ctx.addDiagnostic("Field conflict between " + e.cf.name + " and " + other, c.pos);
				g.diagnostics++;
			}
		}
	}

	// The member's plan: `public virtual` on a root (`final` too in a struct), an override elsewhere.
	public static function plan(g:DotnetCtx, c:TClass, r:ReflectMember):MethodPlan {
		var s = signature(g, r);
		var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.VIRTUAL;
		if (isRoot(c)) flags |= MethodAttrs.NEW_SLOT;
		if (TypeFunctions.hasMeta(":struct", c.meta)) flags |= MethodAttrs.FINAL;
		return {
			kind: MReflect(r),
			name: name(r),
			flags: flags,
			hasThis: true,
			ret: s.ret,
			args: s.args,
			argNames: s.names,
			generics: [],
			pos: c.pos,
			token: 0
		};
	}

	public static function label(r:ReflectMember):String return name(r);

	public static function emit(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, r:ReflectMember, code:IlCode, lower:TexprToIl):Void {
		new ReflectionEmitter(g, plan, code, lower).emit(r);
	}
}

// One member's body.
@:access(hxc.codegen.dotnet.TexprToIl)
private class ReflectionEmitter {
	final g:DotnetCtx;
	final plan:ClassPlan;
	final code:IlCode;
	final lower:TexprToIl;
	final c:TClass;
	final pos:Position;
	final thisParams:TParams;
	final isStruct:Bool;

	public function new(g:DotnetCtx, plan:ClassPlan, code:IlCode, lower:TexprToIl) {
		this.g = g;
		this.plan = plan;
		this.code = code;
		this.lower = lower;
		c = plan.c;
		pos = c.pos;
		thisParams = TypeFunctions.extractParamTypes(c.params);
		isStruct = plan.isStruct;
	}

	inline function mk(e:TExprExpr, t:T):TExpr return TypeFunctions.mk(e, t, pos);

	function ethis():TExpr return mk(TConst(TThis), TInst(c, thisParams));

	// The type arguments of `owner`, the class or one of its superclasses, in terms of the class's own.
	function ownerArgs(owner:TClass):TParams {
		var r = TexprToIl.argsAt(c, thisParams, owner);
		if (r == null) throw "internal error: " + owner.path.name + " is not a superclass of " + c.path.name;
		return r;
	}

	function field(e:{cf:TClassField, owner:TClass}):TExpr {
		var args = ownerArgs(e.owner);
		return mk(TField(ethis(), FInstance(e.owner, args, e.cf)), TypeFunctions.applyParams(e.owner.params, args, e.cf.type));
	}

	// A method of the class or a superclass by name, as `this.name` finds it.
	function methodNamed(n:String):{cf:TClassField, owner:TClass} {
		var cur = c;
		while (cur != null) {
			var cf = cur.fields.get(n);
			if (cf != null && cf.kind.match(Method(_))) return {cf: cf, owner: cur};
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		throw new Unsupported("reflection of a property without its accessor " + n, false, pos);
	}

	// `this.m(args)`, the method's own type parameters as Dynamic.
	function call(m:{cf:TClassField, owner:TClass}, args:Array<TExpr>):TExpr {
		var t = TypeFunctions.applyParams(m.owner.params, ownerArgs(m.owner), m.cf.type);
		t = TypeFunctions.applyParams(m.cf.params, [for (_ in m.cf.params) TypeFunctions.tDynamic], t);
		var ret = switch (TypeFunctions.follow(t)) {
			case TFun(sig): sig.ret;
			case _: throw "internal error: " + m.cf.name + " is not a method";
		}
		return mk(TCall(mk(TField(ethis(), FInstance(m.owner, ownerArgs(m.owner), m.cf)), t), args), ret);
	}

	// The argument types of `this.m`, as call() applies them.
	function argTypes(m:{cf:TClassField, owner:TClass}):Array<TSignatureArg> {
		var t = TypeFunctions.applyParams(m.owner.params, ownerArgs(m.owner), m.cf.type);
		t = TypeFunctions.applyParams(m.cf.params, [for (_ in m.cf.params) TypeFunctions.tDynamic], t);
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig): sig.args;
			case _: throw "internal error: " + m.cf.name + " is not a method";
		}
	}

	// A local of type `t`, for a value converted in IL that a lowered expression then reads.
	function local(t:T):{v:TVar, index:Int, sig:IlSigNorm} {
		var s = lower.sig(t);
		var v = TypeFunctions.allocVar(VGenerated, "__hx_value", t, pos);
		var index = code.addLocal(s);
		lower.bindLocal(v, index, s);
		return {v: v, index: index, sig: s};
	}

	function localExpr(l:{v:TVar, index:Int, sig:IlSigNorm}):TExpr return mk(TLocal(l.v), l.v.type);

	// ---- runtime members

	function runtimeClass():TClass {
		var rt = g.runtimeClass("cs.internal.Runtime");
		if (rt == null) throw new Unsupported("reflection without haxe.lang.Runtime", false, pos);
		g.types.checkKept(TClassDecl(rt));
		return rt;
	}

	function runtimeCall(n:String, margs:Array<IlSigNorm>, pops:Int, pushes:Int):Void {
		var cf = runtimeClass().statics.get(n);
		var token = cf == null ? null : g.methodTokens.get(cf);
		if (token == null) throw new Unsupported("haxe.lang.Runtime." + n, false, pos);
		if (margs.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec(margs));
		code.opToken(IlOps.CALL, token, pops, pushes);
	}

	function undefinedValue():Void {
		var cf = runtimeClass().statics.get("undefined");
		var token = cf == null ? null : g.fieldTokens.get(cf);
		if (token == null) throw new Unsupported("haxe.lang.Runtime.undefined", false, pos);
		code.opToken(IlOps.LDSFLD, token, 0, 1);
	}

	function functionClass():TClass {
		var f = g.runtimeClass("cs.internal.Function");
		if (f == null) throw new Unsupported("reflection without haxe.lang.Function", false, pos);
		g.types.checkKept(TClassDecl(f));
		return f;
	}

	function throwMemberAccess(message:String):Void {
		var ex = LClass({ns: ["System"], nested: [], name: "MemberAccessException"}, []);
		code.opToken(IlOps.LDSTR, g.mb.userString(message), 0, 1);
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(ex), ".ctor", g.sigs.method(true, LVoid, [LString], 0)), 1, 1);
		code.op(IlOps.THROW, 1, 0);
	}

	// ---- conversions

	// The object on the stack as a `to`, as gencs converts a Dynamic (TexprDynamic.toSig: Runtime.toInt,
	// toDouble, toBool, toString, genericCast for a type parameter, C#'s cast), Null<T>.ofDynamic.
	function fromDynamic(to:IlSigNorm):Void {
		switch (to) {
			case LValueType(_, [_]) if (lower.isHaxeNull(to)):
				// Null<object>.ofDynamic<T>(value), as gencs writes it.
				lower.ofDynamic(to);
			case LClass(_, _) if (g.isGenericHaxeClass(to)):
				// An Array<Dynamic> into an Array<Int> field, which gencs's __hx_setField converts with __hx_cast.
				lower.instanceCast(LObject, to);
			case _ if (DotnetTypes.isValueType(to) || to.match(LObject | LString | LClass(_, _) | LVector(_) | LArray(_, _) | LTypeParam(_) | LMethodTypeParam(_))):
				lower.dyn.toSig(to);
			case _:
				throw new Unsupported("reflection of fields of type " + to, false, pos);
		}
	}

	// The Float on the stack as a `to`, as C# casts a double.
	function fromDouble(to:IlSigNorm):Void {
		switch (to) {
			case LFloat64:
			case LInt32: code.op(IlOps.CONV_I4, 1, 1);
			case LUInt32: code.op(IlOps.CONV_U4, 1, 1);
			case LFloat32: code.op(IlOps.CONV_R4, 1, 1);
			case LInt8: code.op(IlOps.CONV_I1, 1, 1);
			case LUInt8: code.op(IlOps.CONV_U1, 1, 1);
			case LInt16: code.op(IlOps.CONV_I2, 1, 1);
			case LUInt16 | LChar: code.op(IlOps.CONV_U2, 1, 1);
			case LObject: code.opToken(IlOps.BOX, g.typeTokenOf(LFloat64), 1, 1);
			case LTypeParam(_) | LMethodTypeParam(_):
				code.opToken(IlOps.BOX, g.typeTokenOf(LFloat64), 1, 1);
				runtimeCall("genericCast", [to], 1, 1);
			case _:
				throw new Unsupported("reflection of fields of type " + to, false, pos);
		}
	}

	// The value of `e` as an object: boxed, Null<T> through toDynamic(), null for Void.
	function pushBoxed(e:TExpr):Void {
		var s = lower.sig(e.type);
		if (s.match(LVoid)) {
			lower.texpr(RVoid, e);
			code.op(IlOps.LDNULL, 0, 1);
		} else if (lower.isHaxeNull(s)) {
			lower.texpr(RValue(s), e);
			lower.nullToDynamic(s);
		} else {
			lower.texpr(RValue(LObject), e);
		}
	}

	// The value of `e` as a Float: converted, or through Runtime.toDouble for Dynamic and type parameters.
	function pushDouble(e:TExpr):Void {
		var s = lower.sig(e.type);
		if (s.match(LObject | LTypeParam(_) | LMethodTypeParam(_))) {
			lower.texpr(RValue(LObject), e);
			runtimeCall("toDouble", [], 1, 1);
		} else {
			lower.texpr(RValue(LFloat64), e);
		}
	}

	// ---- structure

	// `switch (hash)`: each case's hashes jump to its body; the default is the fall-through.
	function dispatch(cases:Array<{hashes:Array<Int>, body:Void->Void}>, def:Void->Void):Void {
		var labels = [for (_ in cases) code.newLabel()];
		for (i in 0...cases.length) for (h in cases[i].hashes) {
			code.ldarg(2);
			code.ldcI4(h);
			code.branch(IlOps.BEQ, labels[i]);
		}
		def();
		for (i in 0...cases.length) {
			code.mark(labels[i]);
			cases[i].body();
		}
	}

	function ret(pops:Int):Void code.op(IlOps.RET, pops, 0);

	// `base.name(args)`: the nearest superclass's member of that name, called on `this` without dispatch.
	function baseCall(r:ReflectMember, argc:Int, hasResult:Bool):Void {
		var n = @:privateAccess ReflectionMembers.name(r);
		var cur = c.superClass;
		var found:Null<{plan:ClassPlan, m:MethodPlan, owner:IlSigNorm}> = null;
		if (cur == null) {
			// A class without a superclass extends HxObject, which declares every member.
			var h = g.runtimeClass(DotnetCtx.hxObjectPath);
			var hp = h == null ? null : g.planOf.get(h);
			if (hp != null) for (m in hp.methods) if (m.name == n && m.hasThis) found = {plan: hp, m: m, owner: hp.thisSig};
		}
		while (cur != null && found == null) {
			var p = g.planOf.get(cur.c);
			if (p == null) break;
			for (m in p.methods) if (m.name == n && m.hasThis) found = {plan: p, m: m, owner: g.types.classSig(cur.c, cur.params)};
			if (found != null) break;
			var next = cur.c.superClass;
			if (next == null) {
				var h = g.runtimeClass(DotnetCtx.hxObjectPath);
				var hp = h == null || h == cur.c ? null : g.planOf.get(h);
				if (hp != null) for (m in hp.methods) if (m.name == n && m.hasThis) found = {plan: hp, m: m, owner: hp.thisSig};
				break;
			}
			var params = [for (p in next.params) TypeFunctions.applyParams(cur.c.params, cur.params, p)];
			cur = {c: next.c, params: params};
		}
		// A superclass outside this module's plans, such as an extern class marked @:hxGen, has no members
		// to call.
		if (found == null) throw new Unsupported("reflection below a superclass with no " + n, false, pos);
		var token = found.plan.classParams.length == 0 ? found.m.token : g.mb.memberRef(g.typeTokenOf(found.owner), n,
			g.sigs.method(true, found.m.ret, found.m.args, 0));
		for (i in 0...argc + 1) code.ldarg(i);
		code.opToken(IlOps.CALL, token, argc + 1, hasResult ? 1 : 0);
		ret(hasResult ? 1 : 0);
	}

	// `this.name(args)` for one of the class's own members (a root's lookups and getField).
	function ownCall(r:ReflectMember, pushArgs:Void->Void, argc:Int, hasResult:Bool):Void {
		var n = @:privateAccess ReflectionMembers.name(r);
		var m = null;
		for (x in plan.methods) if (x.name == n && x.hasThis) m = x;
		if (m == null) throw "internal error: no " + n + " in " + plan.hxPath;
		var token = plan.classParams.length == 0 ? m.token : g.mb.memberRef(g.typeTokenOf(plan.thisSig), n, g.sigs.method(true, m.ret, m.args, 0));
		code.ldarg(0);
		pushArgs();
		code.opToken(isStruct ? IlOps.CALL : IlOps.CALLVIRT, token, argc + 1, hasResult ? 1 : 0);
	}

	function hashOf(cf:TClassField):Int return FieldHashes.use(cf.name);

	public function emit(r:ReflectMember):Void {
		var root = ReflectionMembers.isRoot(c);
		switch (r) {
			case RLookupField:
				var notCheck = code.newLabel(), noThrow = code.newLabel();
				code.ldarg(4);
				code.branch(IlOps.BRFALSE, notCheck);
				undefinedValue();
				ret(1);
				code.mark(notCheck);
				code.ldarg(3);
				code.branch(IlOps.BRFALSE, noThrow);
				throwMemberAccess("Field not found.");
				code.mark(noThrow);
				code.op(IlOps.LDNULL, 0, 1);
				ret(1);
			case RLookupField_f:
				var noThrow = code.newLabel();
				code.ldarg(3);
				code.branch(IlOps.BRFALSE, noThrow);
				throwMemberAccess("Field not found or incompatible field type.");
				code.mark(noThrow);
				code.opR8(IlOps.LDC_R8, 0.0, 0, 1);
				ret(1);
			case RLookupSetField:
				throwMemberAccess("Cannot access field for writing.");
			case RLookupSetField_f:
				throwMemberAccess("Cannot access field for writing or incompatible type.");
			case RGetField:
				dispatch([
					for (e in @:privateAccess ReflectionMembers.getCases(g, c, false))
						{hashes: [hashOf(e.cf)], body: getCase.bind(e, false, 5)}
				], () -> {
					if (root) {
						ownCall(RLookupField, () -> for (i in 1...5) code.ldarg(i), 4, true);
						ret(1);
					} else {
						baseCall(r, 5, true);
					}
				});
			case RGetField_f:
				dispatch([
					for (e in @:privateAccess ReflectionMembers.getCases(g, c, true))
						{hashes: [hashOf(e.cf)], body: getCase.bind(e, true, 4)}
				], () -> {
					if (root) {
						ownCall(RLookupField_f, () -> for (i in 1...4) code.ldarg(i), 3, true);
						ret(1);
					} else {
						baseCall(r, 4, true);
					}
				});
			case RSetField | RSetField_f:
				var isFloat = r == RSetField_f;
				dispatch([
					for (e in @:privateAccess ReflectionMembers.setCases(g, c, isFloat))
						{hashes: [hashOf(e.cf)], body: setCase.bind(e, isFloat)}
				], () -> {
					if (root) {
						ownCall(isFloat ? RLookupSetField_f : RLookupSetField, () -> for (i in 1...4) code.ldarg(i), 3, true);
						ret(1);
					} else {
						baseCall(r, 4, true);
					}
				});
			case RInvokeField:
				var ic = @:privateAccess ReflectionMembers.invokeCases(g, c);
				var cases = [];
				if (ic.old.length > 0) cases.push({hashes: [for (e in ic.old) hashOf(e.cf)], body: slowCall});
				for (e in ic.own) cases.push({hashes: [hashOf(e.cf)], body: invokeCase.bind(e)});
				dispatch(cases, () -> {
					if (root) {
						// ((Function)this.__hx_getField(field, hash, true, false, false)).__hx_invokeDynamic(dynargs)
						ownCall(RGetField, () -> {
							code.ldarg(1);
							code.ldarg(2);
							code.ldcI4(1);
							code.ldcI4(0);
							code.ldcI4(0);
						}, 5, true);
						var fc = functionClass();
						var invoke = fc.fields.get("__hx_invokeDynamic");
						var token = invoke == null ? null : g.methodTokens.get(invoke);
						if (token == null) throw new Unsupported("haxe.lang.Function.__hx_invokeDynamic", false, pos);
						code.opToken(IlOps.CASTCLASS, g.typeTokenOf(lower.sig(TInst(fc, []))), 1, 1);
						code.ldarg(3);
						code.opToken(IlOps.CALLVIRT, token, 2, 1);
						ret(1);
					} else {
						baseCall(r, 3, true);
					}
				});
			case RGetFields:
				var arr = TypeFunctions.allocVar(VGenerated, "baseArr", g.ctx.basic.tarray(g.ctx.basic.tstring), pos);
				lower.bindArg(arr, 1, lower.sig(arr.type));
				var arrExpr = mk(TLocal(arr), arr.type);
				var arrayClass = switch (TypeFunctions.follow(arr.type)) {
					case TInst(ac, _): ac;
					case _: throw "internal error: Array is not a class";
				}
				var push = arrayClass.fields.get("push");
				if (push == null) throw new Unsupported("Array.push", false, pos);
				var pushType = TypeFunctions.applyParams(arrayClass.params, [g.ctx.basic.tstring], push.type);
				for (e in @:privateAccess ReflectionMembers.listed(c)) {
					var callee = mk(TField(arrExpr, FInstance(arrayClass, [g.ctx.basic.tstring], push)), pushType);
					lower.texpr(RVoid, mk(TCall(callee, [mk(TConst(TString(e.cf.name)), g.ctx.basic.tstring)]), g.ctx.basic.tint));
				}
				if (root) ret(0) else baseCall(r, 1, false);
		}
	}

	// A getField case: the value, a property's getter's (always for one with no storage, with
	// `handleProperties` for one with), or for a method a haxe.lang.Closure.
	function getCase(e:Entry, isFloat:Bool, handlePropsArg:Int):Void {
		var push = isFloat ? pushDouble : pushBoxed;
		var cf = e.cf;
		switch (cf.kind) {
			case Var(v) if (v.read == AccCall):
				var getter = call(methodNamed("get_" + cf.name), []);
				if (!TypeFunctions.isPhysicalField(cf)) {
					push(getter);
				} else {
					var direct = code.newLabel();
					code.ldarg(handlePropsArg);
					code.branch(IlOps.BRFALSE, direct);
					push(getter);
					ret(1);
					code.mark(direct);
					push(field(e));
				}
			case Var(_) | Method(MethDynamic):
				push(field(e));
			case Method(_):
				lower.calls.pushClosure(ethis(), LObject, cf.name);
		}
		ret(1);
	}

	// A setField case: the value converted to the field's type, stored or given to the setter, then
	// returned as it came.
	function setCase(e:Entry, isFloat:Bool):Void {
		var cf = e.cf;
		var target = field(e);
		var tmp = local(target.type);
		code.ldarg(3);
		if (isFloat) fromDouble(tmp.sig) else fromDynamic(tmp.sig);
		code.stloc(tmp.index);
		var store = () -> lower.texpr(RVoid, mk(TBinop(OpAssign, target, localExpr(tmp)), target.type));
		if (writesCall(cf)) {
			var setter = () -> lower.texpr(RVoid, call(methodNamed("set_" + cf.name), [localExpr(tmp)]));
			if (!TypeFunctions.isPhysicalField(cf)) {
				setter();
			} else {
				var direct = code.newLabel(), done = code.newLabel();
				code.ldarg(4);
				code.branch(IlOps.BRFALSE, direct);
				setter();
				code.branch(IlOps.BR, done);
				code.mark(direct);
				store();
				code.mark(done);
			}
		} else {
			store();
		}
		code.ldarg(3);
		ret(1);
	}

	static function writesCall(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Var(v): v.write == AccCall;
			case _: false;
		}
	}

	// An overriding method, or one of a superclass outside the model: Runtime.slowCallField(this, field,
	// dynargs).
	function slowCall():Void {
		lower.texpr(RValue(LObject), ethis());
		code.ldarg(1);
		code.ldarg(3);
		runtimeCall("slowCallField", [], 3, 1);
		ret(1);
	}

	// An own method: each argument from `dynargs` (an optional one null when `dynargs` is shorter),
	// converted to the parameter's type, then the call; a Void method gives null.
	function invokeCase(e:Entry):Void {
		var overridden = TclassToIl.overriddenOverload(g, c, e.cf);
		if (overridden != null) {
			slotCase(overridden);
			return;
		}
		var m = {cf: e.cf, owner: e.owner};
		var args = [];
		var types = argTypes(m);
		for (i in 0...types.length) {
			var a = types[i];
			// An optional argument of a value type (or System.Enum) is a haxe.lang.Null<T> (DotnetTypes.argSig).
			var tmp = local(a.opt && DotnetTypes.takesNullOf(lower.sig(a.t)) ? g.ctx.basic.tnull(a.t) : a.t);
			if (a.opt) {
				var missing = code.newLabel(), done = code.newLabel();
				code.ldarg(3);
				code.op(IlOps.LDLEN, 1, 1);
				code.op(IlOps.CONV_I4, 1, 1);
				code.ldcI4(i);
				code.branch(IlOps.BLE, missing);
				code.ldarg(3);
				code.ldcI4(i);
				code.opToken(IlOps.LDELEM, g.typeTokenOf(LObject), 2, 1);
				code.branch(IlOps.BR, done);
				code.mark(missing);
				code.op(IlOps.LDNULL, 0, 1);
				code.mark(done);
			} else {
				code.ldarg(3);
				code.ldcI4(i);
				code.opToken(IlOps.LDELEM, g.typeTokenOf(LObject), 2, 1);
			}
			fromDynamic(tmp.sig);
			code.stloc(tmp.index);
			args.push(localExpr(tmp));
		}
		pushBoxed(call(m, args));
		ret(1);
	}

	// An @:overload override that erasure made a new overload: as gencs writes its case,
	// `(this as G<object>).f((object) dynargs[0], ...)`, a call of the overload `root` it overrides, each
	// argument converted to that overload's CLR parameter type.
	function slotCase(root:TClassField):Void {
		var plan = g.ownerOf.get(root), target = g.methodPlans.get(root);
		if (plan == null || plan.c == null || target == null) throw "internal error: no method " + root.name;
		var inst = g.types.classArgs(plan.c, ownerArgs(plan.c));
		var owner = DotnetCtx.instanceOf(plan, inst);
		code.ldarg(0);
		for (i in 0...target.args.length) {
			code.ldarg(3);
			code.ldcI4(i);
			code.opToken(IlOps.LDELEM, g.typeTokenOf(LObject), 2, 1);
			fromDynamic(DotnetTypes.substitute(target.args[i], inst, []));
		}
		var r = DotnetTypes.substitute(target.ret, inst, []);
		code.opToken(IlOps.CALLVIRT, g.memberOf(plan, owner, root), target.args.length + 1, r.match(LVoid) ? 0 : 1);
		if (r.match(LVoid)) code.op(IlOps.LDNULL, 0, 1) else lower.convert(r, LObject);
		ret(1);
	}
}
