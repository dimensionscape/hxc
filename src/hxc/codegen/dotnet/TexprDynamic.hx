package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.TexprToIl.Ret;
import hxc.codegen.dotnet.TexprToIl.isNullConst;
import hxc.codegen.dotnet.TexprToIl.isTypeParam;
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.strip;

// Dynamic in TexprToIl, lowered to the haxe.lang.Runtime calls gencs emits: field access through
// getField, setField and callField (dynamicFieldAccess.ml, reflectionCFs.ml), operators through eq,
// refEq, plus, compare and the conversions (dynamicOperators.ml and gencs's handlers), and the
// conversions of a Dynamic to other types (castDetect.ml and gencs's cast handler). Shares its state
// through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprFlow, hxc.codegen.dotnet.TexprCalls,
	hxc.codegen.dotnet.ReflectionMembers)
class TexprDynamic {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	// ---- Haxe types as gencs classifies them

	static function isPath(p:Path, pack:Array<String>, name:String):Bool {
		return p.name == name && IlPaths.strsEq(p.pack, pack);
	}

	// gencs's is_dynamic, on the real type: Dynamic, an unbound monomorph, a type parameter, an
	// anonymous structure that is not a class's statics, EnumValue; abstracts are followed, and Null<T>
	// is Dynamic only when its type is (haxe.lang.Null<T> otherwise).
	static function isDynamic(t:T, depth = 0):Bool {
		if (depth > 20) return false;
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TDynamic(_): true;
			case TMono(_): true;
			case TAnon(a): !a.status.get().match(Statics(_) | EnumStatics(_) | AbstractStatics(_));
			case TInst(c, _): c.kind.match(KTypeParameter(_));
			case TAbstract(a, [p]) if (isPath(a.path, [], "Null")): !isTypeParamType(p) && !isBasic(p) && isDynamic(p, depth + 1);
			case TAbstract(a, _) if (isPath(a.path, [], "EnumValue") || isPath(a.path, [], "Dynamic")): true;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)): isDynamic(TypeFunctions.getUnderlyingType(a, tl), depth + 1);
			case _: false;
		}
	}

	// gencs's is_null on the real type: a Null<T> of a basic type or a type parameter, which is
	// haxe.lang.Null<T>.
	static function isNullType(t:T):Bool {
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, [p]) if (isPath(a.path, [], "Null")): isBasic(p) || isTypeParamType(p);
			case _: false;
		}
	}

	// Followed as Haxe's `follow` does (Null<T> included, abstracts not).
	static function isTDynamic(t:T):Bool return TypeFunctions.follow(t).match(TDynamic(_));

	// isTDynamic through abstracts, as gencs's real type sees Any: Dynamic.
	static function isRealTDynamic(t:T, depth = 0):Bool {
		if (depth > 20) return false;
		return switch (TypeFunctions.follow(t)) {
			case TDynamic(_): true;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)): isRealTDynamic(TypeFunctions.getUnderlyingType(a, tl), depth + 1);
			case _: false;
		}
	}

	static function isStringType(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _): isPath(c.path, [], "String");
			case _: false;
		}
	}

	static function isTypeParamType(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _): c.kind.match(KTypeParameter(_));
			case _: false;
		}
	}

	// gencs's is_cs_basic_type.
	static function isBasic(t:T, depth = 0):Bool {
		if (depth > 20) return false;
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, []) if (isPath(c.path, ["haxe"], "Int32") || isPath(c.path, ["haxe"], "Int64")): true;
			case TAbstract(a, []) if (isPath(a.path, ["cs"], "Int64") || isPath(a.path, ["cs"], "UInt64") || isPath(a.path, [], "Int")
				|| isPath(a.path, [], "Float") || isPath(a.path, [], "Bool")):
				true;
			case TAbstract(a, _) if (isPath(a.path, ["cs"], "Pointer")): false;
			case t2 = TAbstract(_, _) if (likeFloat(t2)): true;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)): isBasic(TypeFunctions.getUnderlyingType(a, tl), depth + 1);
			case TEnum(en, _): !HxGen.isHxGen(TEnumDecl(en));
			case TInst(c, _): TypeFunctions.hasMeta(":struct", c.meta);
			case _: false;
		}
	}

	// gencommon's like_float and like_int: Float or Int, or an abstract with a from or to cast to one.
	static function likeFloat(t:T, depth = 0):Bool {
		if (depth > 10) return false;
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []) if (isPath(a.path, [], "Float") || isPath(a.path, [], "Int")): true;
			case TAbstract(a, _) if (isPath(a.path, ["cs"], "Pointer")): false;
			case TAbstract(a, _): Lambda.exists(a.from, x -> likeFloat(x, depth + 1)) || Lambda.exists(a.to, x -> likeFloat(x, depth + 1));
			case _: false;
		}
	}

	// gencommon's like_float on gencs's real type (`can_be_float (real_type t)`): abstracts followed to
	// their underlying type, and a Null<T> that is haxe.lang.Null<T> is not like a Float, so a Null<Int>
	// field reads through getField and a missing one is null.
	static function likeFloatReal(t:T, depth = 0):Bool {
		if (depth > 20) return false;
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, [p]) if (isPath(a.path, [], "Null")): !isBasic(p) && !isTypeParamType(p) && likeFloatReal(p, depth + 1);
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)): likeFloatReal(TypeFunctions.getUnderlyingType(a, tl), depth + 1);
			case t2: likeFloat(t2);
		}
	}

	// gencommon's like_i64: cs.Int64, cs.UInt64 or haxe.Int64, or an abstract with a from or to cast
	// to one; on gencs's real type, as like_float is.
	static function likeI64Real(t:T, depth = 0):Bool {
		if (depth > 20) return false;
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, []) if (isPath(a.path, ["cs"], "Int64") || isPath(a.path, ["cs"], "UInt64") || isPath(a.path, ["haxe"], "Int64")): true;
			case TAbstract(a, [p]) if (isPath(a.path, [], "Null")): !isBasic(p) && !isTypeParamType(p) && likeI64Real(p, depth + 1);
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)): likeI64Real(TypeFunctions.getUnderlyingType(a, tl), depth + 1);
			case TAbstract(a, _): Lambda.exists(a.from, x -> likeI64Real(x, depth + 1)) || Lambda.exists(a.to, x -> likeI64Real(x, depth + 1));
			case _: false;
		}
	}

	static function likeInt(t:T, depth = 0):Bool {
		if (depth > 10) return false;
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []) if (isPath(a.path, [], "Int")): true;
			case TAbstract(a, _) if (isPath(a.path, ["cs"], "Pointer")): false;
			case TAbstract(a, _): Lambda.exists(a.from, x -> likeInt(x, depth + 1)) || Lambda.exists(a.to, x -> likeInt(x, depth + 1));
			case _: false;
		}
	}

	// A field access gencs reaches through Runtime: a field of a Dynamic or of an anonymous structure
	// that is not a class's statics, a variable or dynamic method of a Haxe interface, or a member of a
	// value typed as a companion interface that the companion does not declare (types notes §5). A name
	// the receiver's class declares is its own field in gencs.
	function isDynamicReceiver(fa:TFieldAccess, obj:TExpr):Bool {
		return switch (fa) {
			case FDynamic(n): !isClassField(obj.type, n);
			case FAnon(_): isDynamic(obj.type);
			case FClosure(null, _): false;
			case FInstance(c, _, cf) | FClosure({c: c}, cf):
				// An interface's event var has no value to reach through Runtime (C# error CS0079).
				if (isInterfaceField(c, cf) && EventToIl.isEventVar(cf)) EventToIl.checkValue(g, null, c, cf);
				isInterfaceField(c, cf) || companionReceiver(obj) && companionMember(c, cf) == null;
			case _: false;
		}
	}

	// Whether `obj` is a value typed as a companion interface (DotnetTypes.isCompanionTyped). `super` in a
	// class that extends an X<Dynamic> is the X<object…> its class extends.
	function companionReceiver(obj:TExpr):Bool {
		return !strip(obj).expr.match(TConst(TSuper)) && g.types.isCompanionTyped(obj.type);
	}

	// The method of `c`, or the one of an ancestor that `cf` overrides, that a companion interface declares
	// (CompanionToIl.isMember), with its class; null for a variable, a dynamic method, or a method whose Haxe
	// signature mentions a type parameter, which a value typed as a companion reaches through Runtime.
	function companionMember(c:TClass, cf:TClassField):Null<{c:TClass, cf:TClassField}> {
		if (!cf.kind.match(Method(MethNormal | MethInline))) return null;
		var cur = c, f = cf;
		while (TypeFunctions.hasClassFieldFlag(f, CfOverride)) {
			if (cur.superClass == null || f.overloads.length > 0) return null;
			cur = cur.superClass.c;
			var x = cur.fields.get(cf.name);
			if (x != null) f = x;
		}
		return CompanionToIl.isMember(g, cur, f) ? {c: cur, cf: f} : null;
	}

	// A variable or dynamic method of a Haxe interface, which gencs's InterfaceVarsDeleteModf leaves off
	// the CLR interface (a CLR interface has no fields): through the interface, gencs reaches it with
	// Runtime.getField, setField and callField, as a field of a Dynamic.
	static function isInterfaceField(c:TClass, cf:TClassField):Bool {
		return TypeFunctions.hasClassFlag(c, CInterface) && !TypeFunctions.hasClassFlag(c, CExtern)
			&& cf.kind.match(Var(_) | Method(MethDynamic));
	}

	static function isClassField(t:T, name:String):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, params) if (!c.kind.match(KTypeParameter(_))): TypeFunctions.rawClassFieldOpt(f -> f.type, c, params, name) != null;
			case _: false;
		}
	}

	static function fieldName(fa:TFieldAccess):String {
		return switch (fa) {
			case FDynamic(n): n;
			case FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf): cf.name;
			case FEnum(_, ef): ef.name;
		}
	}

	// ---- haxe.lang.Runtime

	// The static method of haxe.lang.Runtime with this name, the overload whose first argument is
	// `first` when it has several.
	function runtimeMethod(name:String, ?first:IlSigNorm):{token:Int, m:{ret:IlSigNorm, args:Array<IlSigNorm>}} {
		var rt = g.runtimeClass("cs.internal.Runtime");
		if (rt == null) throw new Unsupported("Dynamic without haxe.lang.Runtime", false);
		g.types.checkKept(TClassDecl(rt));
		var cf = rt.statics.get(name);
		if (cf != null) for (f in [cf].concat(cf.overloads)) {
			var m = g.methodSigs.get(f), token = g.methodTokens.get(f);
			if (m == null || token == null) continue;
			if (first == null || m.args.length > 0 && IlPaths.sigEq(m.args[0], first)) return {token: token, m: m};
		}
		throw new Unsupported("haxe.lang.Runtime." + name, false);
	}

	// Calls a Runtime method whose arguments are on the stack; `margs` instantiate a generic one.
	function runtimeCall(name:String, ?first:IlSigNorm, ?margs:Array<IlSigNorm>):IlSigNorm {
		var r = runtimeMethod(name, first);
		var token = margs == null || margs.length == 0 ? r.token : g.mb.methodSpec(r.token, g.sigs.methodSpec(margs));
		code.opToken(IlOps.CALL, token, r.m.args.length, r.m.ret.match(LVoid) ? 0 : 1);
		return margs == null ? r.m.ret : DotnetTypes.substitute(r.m.ret, [], margs);
	}

	// Std.string, which gencs writes for a Dynamic or a type parameter in a String concatenation; the
	// object on the stack.
	function stdString():Void {
		var std = switch (g.types.typeNamed("Std")) {
			case TClassDecl(c): c;
			case _: null;
		}
		var cf = std == null ? null : std.statics.get("string");
		var token = cf == null ? null : g.methodTokens.get(cf);
		if (token == null) throw new Unsupported("Dynamic in string concatenation without Std.string", false);
		g.types.checkKept(TClassDecl(std));
		code.opToken(IlOps.CALL, token, 1, 1);
	}

	// A value of type `from` where `ret` wants it, through the expression's own type `own` as gencs's
	// casts to the expression's type do.
	function finish(from:IlSigNorm, own:IlSigNorm, ret:Ret):Void {
		if (!needVal(ret) || own.match(LVoid)) {
			tl.coerce(from, ret);
			return;
		}
		tl.convert(from, own);
		tl.coerce(own, ret);
	}

	function own(e:TExpr):IlSigNorm return tl.sig(e.type);

	// ---- conversions

	// The object on the stack as a `to`, as gencs converts a Dynamic: Runtime.toInt (then C#'s cast to a
	// smaller integer), toDouble (then to Single), toBool, toString, genericCast<T> for a type parameter,
	// C#'s cast for any other type. Inside haxe.lang.Runtime gencs writes C#'s cast for all but Bool.
	function toSig(to:IlSigNorm):Void {
		if (to.match(LObject)) return;
		if (tl.inRuntimeClass() && !to.match(LBool)) {
			if (DotnetTypes.isValueType(to) || isTypeParam(to)) code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1) else tl.castTo(to);
			return;
		}
		switch (to) {
			case LInt32 | LUInt32:
				runtimeCall("toInt");
			case LInt8 | LUInt8 | LInt16 | LUInt16 | LChar:
				runtimeCall("toInt");
				code.op(switch (to) {
					case LInt8: IlOps.CONV_I1;
					case LUInt8: IlOps.CONV_U1;
					case LInt16: IlOps.CONV_I2;
					case _: IlOps.CONV_U2;
				}, 1, 1);
			case LFloat64:
				runtimeCall("toDouble");
			case LFloat32:
				runtimeCall("toDouble");
				code.op(IlOps.CONV_R4, 1, 1);
			case LBool:
				runtimeCall("toBool");
			case LString:
				runtimeCall("toString");
			case LTypeParam(_) | LMethodTypeParam(_):
				runtimeCall("genericCast", null, [to]);
			case _ if (DotnetTypes.isValueType(to)):
				code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
			case _:
				// An instantiation of a generic Haxe class through __hx_cast (TexprToIl.instanceCast).
				tl.castTo(to);
		}
	}

	// ---- field access

	// The compile-time hash of `name`, which code at `pos` uses. As reflectionCFs' hash_field does, a
	// class whose code hashes two names to the same value is refused: "Field conflict between ...".
	function hash(name:String, pos:Position):Int {
		var h = FieldHashes.use(name);
		var other = FieldHashes.claim(tl.cls == null ? "" : DotnetTypes.haxePath(TClassDecl(tl.cls)), h, name);
		if (other != null) {
			g.ctx.addDiagnostic("Field conflict between " + name + " and " + other, pos);
			g.diagnostics++;
		}
		return h;
	}

	// Pushes the receiver, the name and its hash, the start of every Runtime field call.
	function fieldHead(obj:TExpr, name:String):Void {
		tl.texpr(RValue(LObject), obj);
		nameAndHash(name, obj.pos);
	}

	// Pushes the receiver of a Runtime field call and returns the type of the Runtime overload's first
	// parameter, as C# picks it for the receiver gencs types: the HxObject overload for a value of a Haxe
	// class (an interface, a struct, a type parameter, a class that extends a .NET class and a
	// companion-typed value keep the Dynamic one).
	function fieldReceiver(obj:TExpr):IlSigNorm {
		var hx = g.runtimeClass("cs.internal.HxObject");
		var first = LObject;
		if (hx != null && extendsHxObject(obj.type) && !g.types.isCompanionTyped(obj.type)) {
			first = tl.sig(TInst(hx, []));
		}
		tl.texpr(RValue(first), obj);
		return first;
	}

	// Whether a value typed `t` is of a class that derives from haxe.lang.HxObject.
	function extendsHxObject(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _): HxGen.derivesFromHxObject(c);
			case _: false;
		}
	}

	// Pushes the name and its hash, used at `pos`, after the receiver.
	function nameAndHash(name:String, pos:Position):Void {
		code.opToken(IlOps.LDSTR, g.mb.userString(name), 0, 1);
		code.ldcI4(hash(name, pos));
	}

	// `obj.name` through Runtime.getField(obj, "name", hash, throwErrors), or getField_f when the access
	// is typed like a Float (`resultType`), then converted to it; `e` is the expression whose value this is.
	function fieldGet(ret:Ret, e:TExpr, obj:TExpr, name:String, resultType:T, throwErrors:Bool):Void {
		var isFloat = likeFloatReal(resultType);
		var first = fieldReceiver(obj);
		nameAndHash(name, obj.pos);
		code.ldcI4(throwErrors ? 1 : 0);
		if (isFloat) {
			runtimeCall("getField_f", first);
			// gencs casts the Float to the access's type, then the value goes where the expression goes.
			var rs = tl.sig(resultType);
			if (!needVal(ret)) {
				tl.coerce(LFloat64, ret);
				return;
			}
			tl.convert(LFloat64, rs);
			// A Float that a Float is wanted for stays a float64, with no box and Runtime.toDouble between.
			if (rs.match(LFloat64) && ret.match(RValue(LFloat64))) return;
			finish(rs, own(e), ret);
		} else {
			runtimeCall("getField", first);
			switch (ret) {
				case RValue(want) if (want != null && isNullType(resultType) && !tl.isHaxeNull(want) && !want.match(LString) && tl.keepNull.indexOf(e) < 0):
					// A Null<T> read meets a cast to another type, which HardNullableSynf applies to the object
					// itself (TexprToIl.nullOperand): `(object)getField(...)`, `Runtime.toDouble(getField(...))`.
					tl.coerce(LObject, ret);
				case _:
					finish(LObject, own(e), ret);
			}
		}
	}

	// `obj.name = value` through Runtime.setField, or setField_f with the value as a Float when the
	// assignment is typed like a Float (`fieldType`); its value is what the call returns.
	function fieldSet(ret:Ret, e:TExpr, obj:TExpr, name:String, value:TExpr, fieldType:T):Void {
		var isFloat = likeFloatReal(fieldType);
		var first = fieldReceiver(obj);
		nameAndHash(name, obj.pos);
		tl.texpr(RValue(isFloat ? LFloat64 : LObject), value);
		if (isFloat) {
			runtimeCall("setField_f", first);
			if (!needVal(ret)) {
				tl.coerce(LFloat64, ret);
				return;
			}
			var rs = tl.sig(fieldType);
			tl.convert(LFloat64, rs);
			finish(rs, own(e), ret);
		} else {
			runtimeCall("setField", first);
			finish(LObject, own(e), ret);
		}
	}

	// `obj.name(args)` through Runtime.callField(obj, "name", hash, new object[]{args}), null for no
	// arguments; the result is converted to the call's type.
	function fieldCall(ret:Ret, e:TExpr, obj:TExpr, name:String, args:Array<TExpr>):Void {
		var first = fieldReceiver(obj);
		nameAndHash(name, obj.pos);
		pushObjects(args);
		runtimeCall("callField", first);
		finish(LObject, own(e), ret);
	}

	// Runtime.callField(receiver, "name", hash, new object[]{values}) on object locals the caller has
	// already stored, as a place read and written more than once needs (TexprToIl.place); `pos` is where
	// the name is used. Leaves the call's object result.
	function localFieldCall(receiver:Int, name:String, pos:Position, values:Array<Int>):Void {
		code.ldloc(receiver);
		nameAndHash(name, pos);
		pushObjectArray(values.length, i -> code.ldloc(values[i]));
		runtimeCall("callField", LObject);
	}

	// C#'s `new object[]{...}`, or null for no values.
	function pushObjects(args:Array<TExpr>):Void {
		for (a in args) if (strip(a).expr.match(TUnop(Spread, _, _))) throw new Unsupported("the spread operator", false);
		pushObjectArray(args.length, i -> tl.texpr(RValue(LObject), args[i]));
	}

	// `new object[]{...}` of `count` values, each pushed as an object by `push(i)`, or null for none.
	function pushObjectArray(count:Int, push:Int->Void):Void {
		if (count == 0) {
			code.op(IlOps.LDNULL, 0, 1);
			return;
		}
		var objToken = g.typeTokenOf(LObject);
		code.ldcI4(count);
		code.opToken(IlOps.NEWARR, objToken, 1, 1);
		for (i in 0...count) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			push(i);
			code.opToken(IlOps.STELEM, objToken, 3, 0);
		}
	}

	// The type a field named `name` has on a value of type `t` (a class instance's or an anonymous
	// structure's), or Dynamic, as gencs's mk_field_access types Reflect.field and setField with a
	// constant name.
	static function fieldTypeOn(t:T, name:String):T {
		switch (TypeFunctions.follow(t)) {
			case TInst(c, params) if (!c.kind.match(KTypeParameter(_))):
				var r = TypeFunctions.rawClassFieldOpt(f -> f.type, c, params, name);
				if (r != null) return r.t;
			case TAnon(a) if (a.fields.exists(name)):
				return a.fields.get(name).type;
			case _:
		}
		return TypeFunctions.tDynamic;
	}

	// Reflect.field(o, "name") and Reflect.setField(o, "name", v) with a constant name, as field access
	// that does not throw for a missing field; false for any other call.
	function reflectCall(ret:Ret, e:TExpr, c:TClass, cf:TClassField, args:Array<TExpr>):Bool {
		if (c.path.pack.length != 0 || c.path.name != "Reflect") return false;
		var name = args.length < 2 ? null : switch (strip(args[1]).expr) {
			case TConst(TString(s)): s;
			case _: null;
		}
		if (name == null) return false;
		switch [cf.name, args.length] {
			case ["field", 2]:
				// An anonymous structure or Dynamic reads as Dynamic, a class instance as its field's type.
				fieldGet(ret, e, args[0], name, isDynamic(args[0].type) ? TypeFunctions.tDynamic : fieldTypeOn(args[0].type, name), false);
				return true;
			case ["setField", 3]:
				fieldSet(ret, e, args[0], name, args[2], fieldTypeOn(args[0].type, name));
				return true;
			case _:
				return false;
		}
	}

	// ---- operators

	// gencs's should_handle_opeq: Dynamic, an anonymous structure, a monomorph, a type parameter or a
	// Null<T> of a value type.
	static function handlesEq(t:T):Bool return isDynamic(t) || isNullType(t);

	static function isUndefined(e:TExpr):Bool return TexprOps.isUndefined(e);

	// Whether `==` and `!=` go through Runtime: not a comparison of a Dynamic or Null<T> with literal null,
	// nor one with Runtime.undefined.
	static function eqChanges(e1:TExpr, e2:TExpr):Bool {
		if (isNullConst(e1) && (!isTypeParamType(e2.type) && isDynamic(e2.type) || isNullType(e2.type))) return false;
		if (isNullConst(e2) && (!isTypeParamType(e1.type) && isDynamic(e1.type) || isNullType(e1.type))) return false;
		if (isUndefined(e1) || isUndefined(e2)) return false;
		return handlesEq(e1.type) || handlesEq(e2.type);
	}

	// Lowers `e` (op e1 e2) when an operand makes it Dynamic, as gencs's DynamicOperators does; false for
	// the operators that lower as usual.
	function binop(ret:Ret, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):Bool {
		switch (op) {
			case OpEq | OpNotEq:
				if (!eqChanges(e1, e2)) return false;
				// Runtime.refEq when neither side is basic, Dynamic, a String or a type parameter.
				var isBasicOp = isBasic(e1.type) || isBasic(e2.type);
				var isRef = !isBasicOp && !(isRealTDynamic(e1.type) || isRealTDynamic(e2.type) || isStringType(e1.type) || isStringType(e2.type)
					|| isTypeParamType(e1.type) || isTypeParamType(e2.type));
				tl.nullOperand(RValue(LObject), e1, false);
				tl.nullOperand(RValue(LObject), e2, false);
				runtimeCall(isRef ? "refEq" : "eq");
				if (op.match(OpNotEq)) tl.ops.not();
				finish(LBool, own(e), ret);
				return true;
			case OpAdd:
				if (!(isDynamic(e1.type) || isDynamic(e2.type))) return false;
				// A String result is a concatenation, lowered with the other String operands.
				if (tl.sig(e.type).match(LString)) return false;
				// A Null<T> conditional operand is unwrapped whole (TexprToIl.nullOperand).
				tl.nullOperand(RValue(LObject), e1, false);
				tl.nullOperand(RValue(LObject), e2, false);
				runtimeCall("plus");
				finish(LObject, own(e), ret);
				return true;
			case OpLt | OpLte | OpGt | OpGte:
				if (isDynamic(e.type) || isDynamic(e1.type) || isDynamic(e2.type) || isStringType(e1.type) || isStringType(e2.type)) {
					// String.CompareOrdinal(a, b) <op> 0 when the left side is a String, else
					// Runtime.compare(a, b) <op> 0.
					var ordinal = isStringType(e1.type);
					// gencs unwraps a Null<T> conditional on the left whole; on the right CastDetect pushes the
					// cast into its branches.
					tl.nullOperand(RValue(ordinal ? LString : LObject), e1, false);
					tl.texpr(RValue(ordinal ? LString : LObject), e2);
					if (ordinal) {
						code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(LString), "CompareOrdinal",
							g.sigs.method(false, LInt32, [LString, LString], 0)), 2, 1);
					} else {
						runtimeCall("compare");
					}
					code.ldcI4(0);
					switch (op) {
						case OpLt: code.compare(IlOps.CLT, false);
						case OpGt: code.compare(IlOps.CGT, false);
						case OpLte:
							code.compare(IlOps.CGT, false);
							tl.ops.not();
						case _:
							code.compare(IlOps.CLT, false);
							tl.ops.not();
					}
					finish(LBool, own(e), ret);
					return true;
				}
				return false;
			case OpSub | OpMult | OpDiv | OpMod | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr:
				if (!(isDynamic(e.type) || isDynamic(e1.type) || isDynamic(e2.type))) return false;
				// Arithmetic on Floats (Ints when the expression is typed Int), bitwise operators on Ints.
				var t = op.match(OpSub | OpMult | OpDiv | OpMod) && !likeInt(e.type) ? LFloat64 : LInt32;
				tl.nullOperand(RValue(t), e1, false);
				tl.ops.numericTail(op, t, e2, t, false);
				finish(t, own(e), ret);
				return true;
			case _:
				return false;
		}
	}

	// `-e1` and `~e1` on a Dynamic: through Runtime.toDouble and toInt; false otherwise.
	function unary(ret:Ret, e:TExpr, op:Unop, e1:TExpr):Bool {
		if (!isDynamic(e1.type) && !isDynamic(e.type)) return false;
		switch (op) {
			case Neg:
				var t = likeFloat(e.type) ? tl.sig(e.type) : LFloat64;
				if (!t.match(LFloat64 | LInt32)) t = LFloat64;
				tl.texpr(RValue(t), e1);
				code.op(IlOps.NEG, 1, 1);
				finish(t, own(e), ret);
			case NegBits:
				tl.texpr(RValue(LInt32), e1);
				code.op(IlOps.NOT, 1, 1);
				finish(LInt32, own(e), ret);
			case _:
				return false;
		}
		return true;
	}

	// The access `obj.name` gencs reaches through Runtime, or null.
	function dynamicField(e:TExpr):Null<{obj:TExpr, name:String}> {
		return switch (strip(e).expr) {
			case TField(obj, fa) if (isDynamicReceiver(fa, obj)): {obj: obj, name: fieldName(fa)};
			case _: null;
		}
	}

	// `++` and `--` on a Dynamic, as gencs's DynamicOperators writes them: in Int when the expression is
	// typed like an Int, else in Float; a field through getField_f and setField_f, a variable or other
	// place converted (Runtime.toInt or toDouble) and the result stored boxed.
	function incDec(ret:Ret, e:TExpr, increment:Bool, postfix:Bool, e1:TExpr):Bool {
		var df = dynamicField(e1);
		if (df == null && !isDynamic(e1.type) && !isNullType(e1.type)) return false;
		var t = likeInt(e.type) ? LInt32 : LFloat64;
		function step() {
			if (t.match(LInt32)) code.ldcI4(1) else code.opR8(IlOps.LDC_R8, 1.0, 0, 1);
			code.op(increment ? IlOps.ADD : IlOps.SUB, 2, 1);
		}
		var kept = needVal(ret) ? code.addLocal(t) : -1;
		if (df != null) {
			tl.texpr(RValue(LObject), df.obj);
			var recv = code.addLocal(LObject);
			code.stloc(recv);
			var h = hash(df.name, df.obj.pos);
			code.ldloc(recv);
			code.opToken(IlOps.LDSTR, g.mb.userString(df.name), 0, 1);
			code.ldcI4(h);
			code.ldcI4(1);
			runtimeCall("getField_f", LObject);
			tl.convert(LFloat64, t);
			if (postfix && kept >= 0) {
				code.op(IlOps.DUP, 1, 2);
				code.stloc(kept);
			}
			step();
			var next = code.addLocal(t);
			code.stloc(next);
			code.ldloc(recv);
			code.opToken(IlOps.LDSTR, g.mb.userString(df.name), 0, 1);
			code.ldcI4(h);
			code.ldloc(next);
			tl.convert(t, LFloat64);
			runtimeCall("setField_f", LObject);
			// setField_f returns the value it stored.
			if (!postfix && kept >= 0) {
				tl.convert(LFloat64, t);
				code.stloc(kept);
			} else {
				code.op(IlOps.POP, 1, 0);
			}
		} else {
			var p = tl.place(e1);
			if (p == null) throw new Unsupported("this kind of assignment", false);
			p.prepare();
			p.load();
			tl.convert(p.sig, t);
			if (postfix && kept >= 0) {
				code.op(IlOps.DUP, 1, 2);
				code.stloc(kept);
			}
			step();
			if (!postfix && kept >= 0) {
				code.op(IlOps.DUP, 1, 2);
				code.stloc(kept);
			}
			tl.convert(t, p.sig);
			p.store();
		}
		if (kept >= 0) {
			code.ldloc(kept);
			finish(t, own(e), ret);
		}
		return true;
	}

	// gencs's is_dynamic_expr: a Dynamic, or a field gencs reaches through Runtime (field_is_dynamic).
	function isDynamicExpr(e:TExpr):Bool return isDynamic(e.type) || dynamicField(e) != null;

	// `lhs op= rhs` as gencs's DynamicOperators writes it when an operand is Dynamic, the left side is a
	// field reached through Runtime or a Null<T> (should_change; for `+=` only the left side counts):
	// `lhs = lhs op rhs`, a field's receiver and an array and its index evaluated once into temporaries.
	// The operator is then lowered as any other, so `a.x += 1` on an anonymous structure's Int field adds
	// Ints and a Null<T> is computed in T (HardNullableSynf); a String concatenation stays as it is
	// unless its left side is such a field.
	function compound(ret:Ret, e:TExpr, op:Binop, lhs:TExpr, rhs:TExpr):Bool {
		var changes = isDynamicExpr(lhs) || isNullType(lhs.type) || !op.match(OpAdd) && (isDynamic(e.type) || isDynamicExpr(rhs));
		if (!changes || tl.sig(e.type).match(LString) && dynamicField(lhs) == null) return false;
		// A struct receiver stays where it is: a field of a copy would be stored into the copy.
		function stable(x:TExpr):TExpr {
			return switch (strip(x).expr) {
				case TLocal(_) | TConst(_) | TTypeExpr(_): x;
				case _ if (tl.flow.isStruct(x)): x;
				case _: tl.flow.spill(x);
			}
		}
		var target = switch (strip(lhs).expr) {
			case TField(obj, fa): new TExpr(TField(stable(obj), fa), lhs.type, lhs.pos);
			case TArray(a, i):
				tl.calls.refuseStructIndexer(a, i);
				// An element of an Array<Dynamic> (a companion interface's indexer) through Runtime.callField's
				// "__get" and "__set", as gencs's DynamicOperators reaches it, which convert the value: the
				// receiver as a Dynamic.
				var recv = stable(a);
				if (tl.calls.isCompanionArrayAccess(a)) recv = new TExpr(TCast(recv, null), TypeFunctions.tDynamic, recv.pos);
				new TExpr(TArray(recv, stable(i)), lhs.type, lhs.pos);
			case _: lhs;
		}
		tl.assign(ret, target, new TExpr(TBinop(op, target, rhs), e.type, e.pos));
		return true;
	}

	// ---- anonymous objects

	// gencs's is_side_effects_free (reflectionCFs.ml's implement_dynamic_object_ctor).
	function sideEffectFree(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(_) | TLocal(_) | TFunction(_) | TTypeExpr(_): true;
			case TUnop(Increment | Decrement, _, _) | TBinop(OpAssign | OpAssignOp(_), _, _): false;
			case TUnop(_, _, e1): sideEffectFree(e1);
			case TArray(e1, e2) | TBinop(_, e1, e2): sideEffectFree(e1) && sideEffectFree(e2);
			case TIf(cond, e1, e2) if (e2 != null): sideEffectFree(cond) && sideEffectFree(e1) && sideEffectFree(e2);
			// A field reached through Runtime is a call by the time gencs looks.
			case TField(e1, fa) if (isDynamicReceiver(fa, e1)): false;
			case TField(e1, _) | TParenthesis(e1) | TMeta(_, e1) | TCast(e1, _): sideEffectFree(e1);
			case TArrayDecl(el): Lambda.foreach(el, sideEffectFree);
			case _: false;
		}
	}

	// `{f: v, ...}` as gencs's ObjectDeclMap writes it: `new haxe.lang.DynamicObject(hashes, dynamics,
	// hashes_f, dynamics_f)`. A value that may have side effects is evaluated first, in source order, into
	// a temporary. A field whose real type is like a Float and not an Int64 goes into the second pair as a
	// double, any other boxed into the first; each pair is sorted by hash, which decides the order
	// Reflect.fields and the Serializer see.
	function objectDecl(ret:Ret, fields:Array<TObjectField>):Void {
		var dyns:Array<{h:Int, v:TExpr}> = [], floats:Array<{h:Int, v:TExpr}> = [];
		var values = [for (f in fields) sideEffectFree(f.expr) ? f.expr : tl.flow.spill(f.expr)];
		for (i in 0...fields.length) {
			var t = fields[i].expr.type;
			var entry = {h: hash(fields[i].key.name, fields[i].key.pos), v: values[i]};
			if (likeFloatReal(t) && !likeI64Real(t)) floats.push(entry) else dyns.push(entry);
		}
		function byHash(a:{h:Int, v:TExpr}, b:{h:Int, v:TExpr}) return a.h < b.h ? -1 : a.h > b.h ? 1 : 0;
		haxe.ds.ArraySort.sort(dyns, byHash);
		haxe.ds.ArraySort.sort(floats, byHash);
		var c = g.runtimeClass("cs.internal.DynamicObject");
		if (c == null) throw new Unsupported("anonymous objects without haxe.lang.DynamicObject", true);
		g.types.checkKept(TClassDecl(c));
		var plan = g.planOf.get(c);
		var ctor = null;
		if (plan != null) for (m in plan.methods) if (m.name == ".ctor" && m.args.length == 4 && IlPaths.sigEq(m.args[0], LVector(LInt32))) ctor = m;
		if (ctor == null) throw "internal error: haxe.lang.DynamicObject has no constructor from four arrays";
		function array(elem:IlSigNorm, n:Int, push:Int->Void):Void {
			var token = g.typeTokenOf(elem);
			code.ldcI4(n);
			code.opToken(IlOps.NEWARR, token, 1, 1);
			for (i in 0...n) {
				code.op(IlOps.DUP, 1, 2);
				code.ldcI4(i);
				push(i);
				code.opToken(IlOps.STELEM, token, 3, 0);
			}
		}
		array(LInt32, dyns.length, i -> code.ldcI4(dyns[i].h));
		array(LObject, dyns.length, i -> tl.texpr(RValue(LObject), dyns[i].v));
		array(LInt32, floats.length, i -> code.ldcI4(floats[i].h));
		array(LFloat64, floats.length, i -> tl.texpr(RValue(LFloat64), floats[i].v));
		code.opToken(IlOps.NEWOBJ, ctor.token, 4, 1);
		tl.coerce(plan.thisSig, ret);
	}

	// ---- Std.isOfType

	// Std.isOfType(o, T) with a type expression, inline as gencs writes it (gencs.ml's Std.is handler):
	// C#'s `is`, `o is double || o is int || o is uint` for Float, `o is int || o is uint ||
	// Runtime.isInt(o)` for Int, `o is uint || Runtime.isUInt(o)` for UInt (plain `is` for all three
	// inside haxe.lang.Runtime), and not null for Dynamic.
	function isOfType(ret:Ret, obj:TExpr, texpr:TExpr):Void {
		var mt = switch (texpr.expr) {
			case TTypeExpr(mt): mt;
			case _: throw "internal error: not a type expression";
		}
		// An abstract named as a value is its implementation class.
		var path = switch (mt) {
			case TClassDecl({kind: KAbstractImpl(a)}): DotnetTypes.haxePath(TAbstractDecl(a));
			case _: DotnetTypes.haxePath(mt);
		}
		tl.texpr(RValue(LObject), obj);
		if (path == "Dynamic") {
			code.op(IlOps.LDNULL, 0, 1);
			code.op(IlOps.CGT_UN, 2, 1);
			tl.coerce(LBool, ret);
			return;
		}
		// A generic class is tested as gencs writes `o is G`: G<Dynamic…>, which is its companion interface, so
		// any instantiation and any subclass passes (types notes §5), or for a @:nativeGen or .NET class
		// ``G`1<object…>``. gencs names a companion for a native generic or a generic struct too, which has
		// none, so its C# does not compile (probe t7probe/nocomp). An enum class, whose type parameters are
		// erased, is tested as itself; Class and Enum as System.Type, what their values are.
		var tested = switch (mt) {
			case TClassDecl(c) if (c.params.length > 0 && !c.kind.match(KAbstractImpl(_))):
				if (!TypeFunctions.hasClassFlag(c, CExtern) && HxGen.isHxGen(mt) && !g.hasCompanion(c))
					throw new Unsupported("Std.isOfType with a generic class that has no companion interface", false);
				tl.sig(TInst(c, [for (_ in c.params) TypeFunctions.tDynamic]));
			case TEnumDecl(en) if (EnumToIl.isHxGenEnum(en)): null;
			case TAbstractDecl(_) if (path == "Class" || path == "Enum"): null;
			case _:
				if (TypeFunctions.tParams(mt).length > 0) throw new Unsupported("Std.isOfType with a generic type", false);
				null;
		}
		var tests:Array<IlSigNorm> = [], call:Null<String> = null;
		if (!tl.inRuntimeClass()) switch (path) {
			case "Float": tests = [LFloat64, LInt32, LUInt32];
			case "Int":
				tests = [LInt32, LUInt32];
				call = "isInt";
			case "UInt":
				tests = [LUInt32];
				call = "isUInt";
			case _:
		}
		if (tests.length == 0) {
			code.opToken(IlOps.ISINST, g.typeTokenOf(tested != null ? tested : tl.calls.typeArg(texpr)), 1, 1);
			code.op(IlOps.LDNULL, 0, 1);
			code.op(IlOps.CGT_UN, 2, 1);
			tl.coerce(LBool, ret);
			return;
		}
		var tmp = code.addLocal(LObject);
		code.stloc(tmp);
		var yes = code.newLabel(), end = code.newLabel();
		for (s in tests) {
			code.ldloc(tmp);
			code.opToken(IlOps.ISINST, g.typeTokenOf(s), 1, 1);
			code.branch(IlOps.BRTRUE, yes);
		}
		if (call != null) {
			code.ldloc(tmp);
			runtimeCall(call);
		} else {
			code.ldcI4(0);
		}
		code.branch(IlOps.BR, end);
		code.mark(yes);
		code.ldcI4(1);
		code.mark(end);
		tl.coerce(LBool, ret);
	}
}
