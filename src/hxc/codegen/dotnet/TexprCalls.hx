package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.core.Globals;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.OverloadResolution;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.ExternMembers;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.TclassToIl.ClassPlan;
import hxc.codegen.dotnet.TclassToIl.MethodAttrs;
import hxc.codegen.dotnet.TclassToIl.MethodKind;
import hxc.codegen.dotnet.TclassToIl.MethodPlan;
import hxc.codegen.dotnet.TclassToIl.PropertyPlan;
import hxc.codegen.dotnet.TexprToIl.Place;
import hxc.codegen.dotnet.TexprToIl.Ret;
import hxc.codegen.dotnet.TexprToIl.Slot;
import hxc.codegen.dotnet.TexprToIl.SpillMode;
import hxc.codegen.dotnet.TexprToIl.isExtern;
import hxc.codegen.dotnet.TexprToIl.isIntLike;
import hxc.codegen.dotnet.TexprToIl.isReference;
import hxc.codegen.dotnet.TexprToIl.isStringClass;
import hxc.codegen.dotnet.TexprToIl.isTypeParam;
import hxc.codegen.dotnet.TexprToIl.refTarget;
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.paramsOf;
import hxc.codegen.dotnet.TexprToIl.staticOwner;
import hxc.codegen.dotnet.TexprToIl.strip;
import hxc.codegen.dotnet.TexprOps.stringKind;

// A .NET indexer an `e1[i]` goes through (TexprCalls.netIndexer): the class declaring it with its type
// arguments applied, the types of its index and element there, and the tokens of its accessors, which
// refuse a missing one. `isStruct`: its class is a value type, whose accessors are called, not
// callvirted, on the receiver's address.
typedef NetIndexer = {
	parent:IlSigNorm,
	index:IlSigNorm,
	value:IlSigNorm,
	isStruct:Bool,
	getToken:Void->Int,
	setToken:Void->Int
}

// The member access of TexprToIl: receivers, fields, constants, calls, constructors, arrays and casts.
// Shares its state through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprFlow, hxc.codegen.dotnet.TexprDynamic,
	hxc.codegen.dotnet.CsToIl)
class TexprCalls {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;
	// A call of a function value that an unsafe cast to Dynamic wraps (TexprToIl.castExpr): its `_f`
	// result goes boxed as the double, without the conversion to the call's type.
	var rawCall:Null<TExpr> = null;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	// The class type arguments a field access sees: a static one gets Dynamic for each.
	function instantiation(c:TClass, fa:TFieldAccess):Array<IlSigNorm> {
		return switch (fa) {
			case FInstance(_, params, _): g.types.classArgs(c, params);
			case _: [for (_ in c.params) LObject];
		}
	}

	function parentOf(c:TClass, inst:Array<IlSigNorm>):IlSigNorm {
		return switch (g.types.classSig(c, [for (_ in c.params) TypeFunctions.tDynamic])) {
			case LClass(p, _): LClass(p, inst);
			case LValueType(p, _): LValueType(p, inst);
			case s: s;
		}
	}

	// The extern variable `cf` of `c` that `obj.cf` (or the static `c.cf`) accesses, which `reads` or `writes`,
	// as C# looks it up (ruling Y): from the receiver's static .NET class, as for a method (rulings M and P),
	// with protected members as ruling R allows them. `parent`: the .NET type declaring it, which the access
	// names, with `args` its type arguments, which the member's type takes.
	public function externField(obj:TExpr, fa:TFieldAccess, c:TClass, cf:TClassField, reads:Bool,
			writes:Bool):{member:ExternField, parent:IlSigNorm, args:Array<IlSigNorm>} {
		var inst = instantiation(c, fa);
		var site:FieldSite = {caller: tl.cls, classArgs: inst};
		var start = null;
		if (!fa.match(FStatic(_, _))) {
			var isSuper = strip(obj).expr.match(TConst(TSuper));
			var recv = receiverType(obj, c, cf, true);
			start = receiverClass(recv, c);
			if (start != null) {
				site.receiver = start.c;
				site.receiverArgs = start.args;
			}
			if (!isSuper) switch (recv) {
				case TInst(rc, _) if (!rc.kind.match(KTypeParameter(_))): site.receiverStatic = rc;
				case _:
			}
			if (!isSuper) switch (TypeFunctions.follow(obj.type)) {
				case TInst(tp, _) if (tp.kind.match(KTypeParameter(_))): site.receiverOpaque = true;
				case _:
			}
		}
		var b = g.externs.field(c, cf, reads, writes, site);
		var parent = ExternMembers.subst(b.parent, start != null ? start.args : inst);
		return {
			member: b.member,
			parent: parent,
			args: switch (parent) {
				case LClass(_, l) | LValueType(_, l): l;
				case _: [];
			}
		};
	}

	// The object an instance member is reached through; a value type's address. A field store needs
	// the address of a variable, not of a copy.
	function receiver(obj:TExpr, parent:IlSigNorm, forStore = false):Void {
		if (!DotnetTypes.isValueType(parent)) {
			tl.texpr(RValue(parent), obj);
			return;
		}
		// A member of a Null<T>'s T is reached through a copy of its value, as HardNullableSynf unwraps it.
		var own = try tl.sig(obj.type) catch (_:Unsupported) null;
		var unwraps = own != null && tl.isHaxeNull(own) && !IlPaths.sigEq(own, parent);
		if (!unwraps && pushAddress(obj, forStore)) return;
		// A value with no home, such as a call's result: C# works on a copy too.
		if (forStore) throw new Unsupported("assignments to fields of struct values", true);
		tl.texpr(RValue(parent), obj);
		var tmp = code.addLocal(parent);
		code.stloc(tmp);
		code.ldloca(tmp);
	}

	// Pushes the address of the value-type variable `e` names, as C# takes it for a member access: a
	// local, an argument, a struct's `this`, or an instance or static field (of a field, and so on).
	// False, with nothing pushed, for anything else, and for a readonly .NET field, which C# copies. With
	// `forStore`, a chain that starts at a value with no home throws, as C# rejects a store to it.
	function pushAddress(e:TExpr, forStore:Bool):Bool {
		switch (strip(e).expr) {
			case TLocal(v) if (refTarget(tl.anySlot(v)) != null):
				// A cs.Ref or cs.Out parameter holds the address already.
				tl.load(tl.anySlot(v));
				return true;
			case TLocal(v):
				var s = tl.slot(v);
				if (s.arg) code.ldarga(s.index) else code.ldloca(s.index);
				return true;
			case TConst(TThis) if (tl.thisSig != null && DotnetTypes.isValueType(tl.thisSig)):
				code.ldarg(0);
				return true;
			case TField(obj, fa = FStatic(_, cf) | FInstance(_, _, cf)) if (g.varProperties.exists(cf) && !tl.dyn.isDynamicReceiver(fa, obj)):
				// A @:property var has no home: C# works on a copy of the getter's value.
				return false;
			case TField(obj, fa = FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c) && cf.kind.match(Var(_))
				&& !tl.dyn.isDynamicReceiver(fa, obj)):
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner, forStore);
				code.opToken(IlOps.LDFLDA, f.token, 1, 1);
				return true;
			case TField(_, FStatic(c, cf)) if (!isExtern(c) && cf.kind.match(Var(_))):
				code.opToken(IlOps.LDSFLDA, tl.staticField(c, cf).token, 0, 1);
				return true;
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c) && cf.kind.match(Var(_))):
				var x = externField(obj, fa, c, cf, true, true);
				switch (x.member) {
					case XField(open, false):
						var isStatic = fa.match(FStatic(_, _));
						var parent = x.parent;
						if (!isStatic) receiver(obj, parent, forStore);
						var token = g.mb.memberRef(g.typeTokenOf(parent), ExternMembers.memberName(cf), g.sigs.field(open));
						code.opToken(isStatic ? IlOps.LDSFLDA : IlOps.LDFLDA, token, isStatic ? 0 : 1, 1);
						return true;
					case _:
						return false;
				}
			case _:
				return false;
		}
	}

	// A .NET literal, typed as its field declares it: the metadata stores SByte and Byte, Int16 and
	// UInt16, Int32 and UInt32 alike, and the reader keeps the small ones unsigned.
	function constant(c:IlConstant, declared:IlSigNorm):Null<IlSigNorm> {
		switch (c) {
			case IBool(b):
				code.ldcI4(b ? 1 : 0);
				return LBool;
			case IChar(i):
				code.ldcI4(i);
				return LChar;
			case IByte(i):
				var signed = declared.match(LInt8);
				code.ldcI4(signed ? (i << 24) >> 24 : i);
				return signed ? LInt8 : LUInt8;
			case IShort(i):
				var unsigned = declared.match(LUInt16 | LChar);
				code.ldcI4(unsigned ? i : (i << 16) >> 16);
				return unsigned ? declared : LInt16;
			case IInt(i):
				code.ldcI4(i);
				return declared.match(LUInt32) ? LUInt32 : LInt32;
			case IInt64(_, i):
				code.opI64(IlOps.LDC_I8, i, 0, 1);
				return declared.match(LUInt64) ? LUInt64 : LInt64;
			case IFloat32(f):
				code.opR4(IlOps.LDC_R4, f, 0, 1);
				return LFloat32;
			case IFloat64(f):
				code.opR8(IlOps.LDC_R8, f, 0, 1);
				return LFloat64;
			case IString(b):
				var buf = new StringBuf();
				var i = 0;
				while (i + 1 < b.length) {
					var u = b.getUInt16(i);
					i += 2;
					if (u >= 0xD800 && u < 0xDC00 && i + 1 < b.length) {
						var lo = b.getUInt16(i);
						i += 2;
						u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
					}
					buf.addChar(u);
				}
				code.opToken(IlOps.LDSTR, g.mb.userString(buf.toString()), 0, 1);
				return LString;
			case INull:
				code.op(IlOps.LDNULL, 0, 1);
				return null;
		}
	}

	function fieldRead(ret:Ret, e:TExpr, obj:TExpr, fa:TFieldAccess):Void {
		switch (fa) {
			case FClosure(null, cf):
				// A method of an anonymous structure is one of its fields.
				if (!TexprDynamic.isDynamic(obj.type)) throw new Unsupported("method closures", true);
				tl.dyn.fieldGet(ret, e, obj, cf.name, e.type, true);
			case FInstance(_, _, cf) | FClosure(_, cf) if (tl.dyn.isDynamicReceiver(fa, obj)):
				// A variable or dynamic method of a Haxe interface, or a member of a value typed as a companion
				// interface that the companion lacks, through Runtime.getField as gencs reads it.
				tl.dyn.fieldGet(ret, e, obj, cf.name, e.type, true);
			case FStatic(c, cf) if (!isExtern(c) && isMethod(cf)):
				// A static method as a value: `new Closure(typeof(C), "name", hash)`.
				g.types.checkKept(TClassDecl(c));
				var plan = g.ownerOf.get(cf);
				if (plan == null) throw Unsupported.bug("a closure of " + Globals.sTypePath(c.path) + "." + cf.name + " without a method (an hxc bug)");
				pushClosure(null, staticOwner(plan), cf.name);
				pushInvoker(cf);
				tl.coerce(closureSig(), ret);
			case FStatic(c, cf) | FInstance(c, _, cf) if (g.varProperties.exists(cf)):
				// A @:property var: its getter, as gencs's C# reads the auto-property.
				var a = varAccessor(c, paramsOf(fa), cf, false);
				if (!a.isStatic) receiver(obj, a.owner);
				code.opToken(a.op, a.token, a.isStatic ? 0 : 1, 1);
				tl.coerce(a.sig, ret);
			case FStatic(c, cf) if (!isExtern(c)):
				var f = tl.staticField(c, cf);
				if (!needVal(ret)) return;
				tl.volatilePrefix(cf);
				code.opToken(IlOps.LDSFLD, f.token, 0, 1);
				tl.coerce(f.sig, ret);
			case FInstance(c, _, cf) | FClosure({c: c}, cf) if (isStringClass(c) && cf.kind.match(Method(_))):
				// hxcs's Runtime calls a String's methods by their Haxe names.
				pushClosure(obj, LString, cf.name);
				tl.coerce(closureSig(), ret);
			case FInstance(c, _, cf) if (isStringClass(c)):
				if (cf.name != "length") throw new Unsupported("the String field " + cf.name, false);
				tl.texpr(RValue(LString), obj);
				callString("get_Length", LInt32, []);
				tl.coerce(LInt32, ret);
			case FInstance(_, _, cf) if (cf.name == "Length" && isNativeArray(obj.type)):
				nativeLength(ret, obj);
			case FStatic(c, cf) | FInstance(c, _, cf) | FClosure({c: c}, cf) if (isExtern(c) && cf.kind.match(Method(_))):
				// A .NET method as a value, which Runtime.callField reaches by reflection.
				var isStatic = fa.match(FStatic(_, _));
				pushClosure(isStatic ? null : obj, parentOf(c, instantiation(c, fa)), ExternMembers.memberName(cf));
				tl.coerce(closureSig(), ret);
			case FStatic(c, cf) | FInstance(c, _, cf) if (isExtern(c)):
				var isStatic = fa.match(FStatic(_, _));
				var x = externField(obj, fa, c, cf, true, false);
				var parent = x.parent, inst = x.args;
				switch (x.member) {
					case XConstant(k, declared):
						if (!isStatic) throw new Unsupported("instance .NET constants", true);
						var s = constant(k, declared);
						tl.coerce(s, ret);
					case XField(open, _):
						if (!isStatic) receiver(obj, parent);
						var token = g.mb.memberRef(g.typeTokenOf(parent), ExternMembers.memberName(cf), g.sigs.field(open));
						code.opToken(isStatic ? IlOps.LDSFLD : IlOps.LDFLD, token, isStatic ? 0 : 1, 1);
						tl.coerce(ExternMembers.subst(open, inst), ret);
					case XProperty(open, getter, _) if (getter != null):
						if (!isStatic) receiver(obj, parent);
						var token = g.mb.memberRef(g.typeTokenOf(parent), getter, g.sigs.method(!isStatic, open, [], 0));
						code.opToken(isStatic || DotnetTypes.isValueType(parent) ? IlOps.CALL : IlOps.CALLVIRT, token, isStatic ? 0 : 1, 1);
						tl.coerce(ExternMembers.subst(open, inst), ret);
					case _:
						throw new Unsupported("reading a write-only .NET property", false);
				}
			case FInstance(_, _, cf) | FClosure(_, cf) if (cf.kind.match(Method(_)) && isDynamicArray(obj.type)):
				// gencs reads a method of an Array<Dynamic>, the non-generic Array, through Runtime.getField.
				tl.dyn.fieldGet(ret, e, obj, cf.name, e.type, true);
			case FInstance(c, _, cf) | FClosure({c: c}, cf) if (isMethod(cf)):
				// An instance method as a value: `new Closure(obj, "name", hash)`, the receiver evaluated now,
				// the method found by name when the closure is called.
				g.types.checkKept(TClassDecl(c));
				pushClosure(obj, LObject, cf.name);
				pushInvoker(cf);
				tl.coerce(closureSig(), ret);
			case FInstance(c, cparams, cf) | FClosure({c: c, params: cparams}, cf):
				// A variable, or a dynamic method (read as a value, the typer's FClosure), its field.
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner);
				tl.volatilePrefix(cf);
				code.opToken(IlOps.LDFLD, f.token, 1, 1);
				tl.coerce(f.sig, ret);
			case FStatic(_, _):
				throw new Unsupported("this kind of field access", false);
			case FAnon(_) | FDynamic(_) if (tl.dyn.isDynamicReceiver(fa, obj)):
				// Runtime.getField, as gencs reads a field of a Dynamic or an anonymous structure.
				tl.dyn.fieldGet(ret, e, obj, TexprDynamic.fieldName(fa), e.type, true);
			case FAnon(_):
				throw new Unsupported("anonymous structure fields", true);
			case FDynamic(_):
				throw new Unsupported("dynamic field access", false);
			case FClosure(_, _):
				throw new Unsupported("method closures", true);
			case FEnum(en, ef) if (HxGen.isClrEnum(en)):
				// A CLR enum's literal, its index.
				if (!needVal(ret)) return;
				g.types.checkKept(TEnumDecl(en));
				code.ldcI4(ef.index);
				tl.coerce(tl.sig(e.type), ret);
			case FEnum(en, ef) if (en.isExtern):
				// A .NET enum's literal, its value in the referenced assembly.
				if (!needVal(ret)) return;
				externEnumLiteral(en, ef);
				tl.coerce(tl.sig(e.type), ret);
			case FEnum(en, ef) if (EnumToIl.isHxGenEnum(en)):
				// A constructor without arguments is the base class's static field holding its one value.
				g.types.checkKept(TEnumDecl(en));
				var plan = g.enumPlans.get(en);
				if (!plan.isSingleton(ef)) {
					// One with arguments, as a value: a closure of the base class's factory.
					pushClosure(null, plan.base.thisSig, ef.name);
					tl.coerce(closureSig(), ret);
					return;
				}
				if (!needVal(ret)) return;
				code.opToken(IlOps.LDSFLD, plan.singleton(ef), 0, 1);
				tl.coerce(plan.base.thisSig, ret);
			case FEnum(_, _):
				throw new Unsupported("enum constructors", true);
		}
	}

	// Pushes the value of a constructor of an extern .NET enum.
	function externEnumLiteral(en:TEnum, ef:TEnumField):Void {
		var lit = g.externs.enumLiteral(en, ef);
		constant(lit.c, lit.underlying);
	}

	// A native array's Length: ldlen, then the native int as an Int.
	function nativeLength(ret:Ret, obj:TExpr):Void {
		tl.texpr(RValue(vectorSig(obj)), obj);
		code.op(IlOps.LDLEN, 1, 1);
		code.op(IlOps.CONV_I4, 1, 1);
		tl.coerce(LInt32, ret);
	}

	static function isStd(c:TClass):Bool return c.path.pack.length == 0 && c.path.name == "Std";

	// The expression whose static type Std.string can print directly, else null.
	// Only an unchecked cast to Dynamic is looked through: one to another type converts or checks the
	// value, as gencs's C# cast does.
	function stringArg(e:TExpr):Null<TExpr> {
		var inner = strip(e);
		try {
			switch (inner.expr) {
				case TCast(x, null) if (tl.sig(inner.type).match(LObject)): inner = strip(x);
				case _:
			}
			var s = tl.sig(inner.type);
			// A Null<T> goes to Std.string as an object, as its Dynamic argument takes it.
			if (tl.isHaxeNull(s)) return null;
			stringKind(s);
		} catch (_:Unsupported) {
			return null;
		}
		return inner;
	}

	// An instance member of System.String, with the receiver on the stack.
	function callString(name:String, retSig:IlSigNorm, argSigs:Array<IlSigNorm>):Void {
		var token = g.mb.memberRef(g.typeTokenOf(LString), name, g.sigs.method(true, retSig, argSigs, 0));
		code.opToken(IlOps.CALLVIRT, token, argSigs.length + 1, retSig.match(LVoid) ? 0 : 1);
	}

	// String members, as gencs maps them.
	function stringCall(ret:Ret, obj:TExpr, cf:TClassField, args:Array<TExpr>):Void {
		switch (cf.name) {
			case "toUpperCase" | "toLowerCase":
				tl.texpr(RValue(LString), obj);
				callString(cf.name == "toUpperCase" ? "ToUpperInvariant" : "ToLowerInvariant", LString, []);
				tl.coerce(LString, ret);
			case "toString":
				tl.texpr(RValue(LString), obj);
				tl.coerce(LString, ret);
			case "charAt" | "charCodeAt" | "indexOf" | "lastIndexOf" | "split" | "substring" | "substr":
				stringExtCall(ret, cf.name, obj, args);
			case _:
				// The private externs name the System.String member.
				var argSigs, retSig;
				switch (TypeFunctions.follow(cf.type)) {
					case TFun(fsig):
						argSigs = [for (a in fsig.args) tl.sig(a.t)];
						retSig = tl.sig(fsig.ret);
					case _:
						throw "internal error: String." + cf.name + " is not a function";
				}
				tl.texpr(RValue(LString), obj);
				pushArgs(args, argSigs);
				callString(ExternMembers.memberName(cf), retSig, argSigs);
				tl.coerce(retSig, ret);
		}
	}

	// A static method of cs.internal.StringExt (haxe.lang.StringExt in the assembly), the receiver first.
	function stringExtCall(ret:Ret, name:String, receiver:Null<TExpr>, args:Array<TExpr>):Void {
		var found = null;
		for (mt in g.ctx.types) switch (mt) {
			case TClassDecl(c) if (DotnetTypes.haxePath(mt) == "cs.internal.StringExt"):
				g.types.checkKept(mt);
				var cf = c.statics.get(name);
				var token = cf == null ? null : g.methodTokens.get(cf);
				if (token != null) found = {token: token, m: g.methodSigs.get(cf)};
			case _:
		}
		if (found == null) throw new Unsupported("String." + name, false);
		var all = receiver == null ? args : [receiver].concat(args);
		pushArgs(all, found.m.args);
		code.opToken(IlOps.CALL, found.token, all.length, found.m.ret.match(LVoid) ? 0 : 1);
		tl.coerce(found.m.ret, ret);
	}

	// Pushes the arguments as the parameters' types `slots`. `targets`, the parameters' Haxe types where the
	// call knows them, decides a cast between instantiations of a generic Haxe class (TexprToIl.texprTo).
	function pushArgs(args:Array<TExpr>, slots:Array<IlSigNorm>, ?targets:Array<T>):Void {
		if (args.length != slots.length) throw new Unsupported("calls that leave out arguments", true);
		if (targets != null && targets.length != args.length) targets = null;
		for (i in 0...args.length) switch (slots[i]) {
			case LManagedPointer(t):
				// cs.Ref and cs.Out: the address of a variable of exactly that type, as C#'s ref and out.
				var s = try tl.sig(args[i].type) catch (_:Unsupported) null;
				if (s == null || !IlPaths.sigEq(s, t) || !pushAddress(args[i], true))
					throw new Unsupported("by-reference arguments that are not variables of the parameter's type", true);
			case s:
				tl.texprTo(s, targets == null ? null : targets[i], args[i]);
		}
	}

	// The argument types of the constructor of `c` (its own or an ancestor's) that `args` reach, with `params`
	// applied, as pushArgs takes them; null when there is none.
	static function ctorTargets(c:TClass, params:TParams, args:Array<TExpr>):Null<Array<T>> {
		var owner = try TypeFunctions.getConstructorClass(c, params) catch (_:Dynamic) null;
		var r = owner == null ? null : OverloadResolution.maybeResolveConstructorOverload(c, params, args);
		return r == null ? null : argTypes(TypeFunctions.applyParams(owner.c.params, owner.tl, r.cf.type));
	}

	// The argument types of the function type `t`, as a call applies them; null when it is no function.
	static function argTypes(t:T):Null<Array<T>> {
		return switch (TypeFunctions.follow(t)) {
			case TFun(fsig): [for (a in fsig.args) a.t];
			case _: null;
		}
	}

	function call(ret:Ret, e:TExpr, callee:TExpr, args:Array<TExpr>):Void {
		switch (callee.expr) {
			case TField(_, FStatic(c, cf)) if (isStd(c) && cf.name == "int" && args.length == 1):
				// As gencs writes Std.int: a C# cast (of a Dynamic converted by Runtime.toDouble).
				tl.texpr(RValue(LFloat64), args[0]);
				code.op(IlOps.CONV_I4, 1, 1);
				tl.coerce(LInt32, ret);
			case TField(_, FStatic(c, cf)) if (isStd(c) && (cf.name == "isOfType" || cf.name == "is") && args.length == 2
				&& strip(args[1]).expr.match(TTypeExpr(_))):
				tl.dyn.isOfType(ret, args[0], strip(args[1]));
			case TField(obj, FDynamic(name)) if (objectMember(name, args.length) != null):
				// Object's own members, which gencs calls directly on a Dynamic.
				var m = objectMember(name, args.length);
				tl.texpr(RValue(LObject), obj);
				for (a in args) tl.texpr(RValue(LObject), a);
				code.opToken(IlOps.CALLVIRT, g.mb.memberRef(g.typeTokenOf(LObject), name, g.sigs.method(true, m, [for (_ in args) LObject], 0)),
					args.length + 1, 1);
				tl.coerce(m, ret);
			case TField(obj, fa = FDynamic(_) | FAnon(_) | FInstance(_, _, _)) if (tl.dyn.isDynamicReceiver(fa, obj)):
				// Runtime.callField, as gencs calls a method of a Dynamic, a variable of a function type or a
				// dynamic method of a Haxe interface, or a method of a value typed as a companion interface that
				// the companion lacks.
				tl.dyn.fieldCall(ret, e, obj, TexprDynamic.fieldName(fa), args);
			case TField(_, FStatic(c, cf)) if (isStd(c) && cf.name == "string" && args.length == 1 && stringArg(args[0]) != null):
				// A value of a known type prints as in a concatenation, Bool as true or false.
				tl.ops.pushString(stringArg(args[0]));
				tl.coerce(LString, ret);
			case TField(obj, FInstance(c, _, cf)) if (isStringClass(c)):
				stringCall(ret, obj, cf, args);
			case TField(obj, FInstance(_, _, cf)) if (cf.name == "get_Length" && args.length == 0 && isNativeArray(obj.type)):
				nativeLength(ret, obj);
			case TField(_, FStatic(c, cf)) if (emptyInstanceOf(e, c, cf, args) != null):
				// overloadingConstructor's init_expr_filter: Type.createEmptyInstance of a constant hxgen class
				// is `new C(EmptyObject.EMPTY)`, which runs no constructor body.
				var target = emptyInstanceOf(e, c, cf, args);
				// newobj cannot create an abstract class (gencs's C# does not compile either).
				if (TypeFunctions.hasClassFlag(target.c, CAbstract)) throw new Unsupported("Type.createEmptyInstance of an abstract class", false);
				g.types.checkKept(TClassDecl(target.c));
				var plan = g.planOf.get(target.c);
				var owner = DotnetCtx.instanceOf(plan, g.types.classArgs(target.c, target.params));
				var token = plan.classParams.length == 0 ? plan.emptyCtor.token : g.mb.memberRef(g.typeTokenOf(owner), ".ctor",
					g.sigs.method(true, LVoid, plan.emptyCtor.args, 0));
				code.ldcI4(0);
				code.opToken(IlOps.NEWOBJ, token, 1, 1);
				tl.coerce(owner, ret);
			case TField(_, FStatic(c, cf)) if (isNativeArrayClass(c) && cf.name == "make"):
				// cs.NativeArray.make(a, b): C#'s `new T[]{a, b}`, as gencs writes it.
				newVector(ret, e, args);
			case TField(_, FStatic(c, cf)) if (tl.dyn.reflectCall(ret, e, c, cf, args)):
				// Reflect.field and setField with a constant name, lowered as field access.
			case TField(_, FStatic(c, cf)) if (CsToIl.isSyntaxClass(c) && (cf.name == "code" || cf.name == "plainCode") && args.length >= 1):
				tl.inlineCs.code(ret, e, CsToIl.constantText(args[0]), args.slice(1), false, e.pos);
			case TField(_, FStatic(c, cf)) if (isStringClass(c) && cf.name == "fromCharCode"):
				stringExtCall(ret, cf.name, null, args);
			case TField(_, FStatic(c, cf)) if (isStringClass(c)):
				// The private externs name System.String's static methods, such as Compare.
				var fsig = switch (TypeFunctions.follow(cf.type)) {
					case TFun(fsig): fsig;
					case _: throw "internal error: String." + cf.name + " is not a function";
				}
				var argSigs = [for (a in fsig.args) tl.sig(a.t)], retSig = tl.sig(fsig.ret);
				pushArgs(args, argSigs);
				var token = g.mb.memberRef(g.typeTokenOf(LString), ExternMembers.memberName(cf), g.sigs.method(false, retSig, argSigs, 0));
				code.opToken(IlOps.CALL, token, argSigs.length, retSig.match(LVoid) ? 0 : 1);
				tl.coerce(retSig, ret);
			case TField(_, FStatic(_, cf) | FInstance(_, _, cf)) if (!isMethod(cf)):
				// A variable of a function type, or a dynamic method.
				invokeFunction(ret, e, callee, args);
			case TField(_, FStatic(c, cf)) if (!isExtern(c)):
				g.types.checkKept(TClassDecl(c));
				var target = pickOverload(c, [], cf, args, true);
				var plan = g.ownerOf.get(target);
				if (plan == null || !g.methodTokens.exists(target)) throw "internal error: no method " + Globals.sTypePath(c.path) + "." + cf.name;
				var m = methodRef(plan, staticOwner(plan), [], target, target.type, callee.type, receiverArgs(c, target, args));
				pushArgs(args, m.args, argTypes(callee.type));
				code.opToken(IlOps.CALL, m.token, args.length, m.ret.match(LVoid) ? 0 : 1);
				tl.coerce(m.ret, ret);
			case TField(_, FStatic(c, cf)) if (isExtern(c) && (cf.name == "op_Addition" || cf.name == "op_Subtraction") && args.length == 2
				&& g.externs.isDelegate(c)):
				// The delegate abstract's `+` and `-` (NetConverter.convertIlClass declares these, which no delegate
				// type has): C#'s `d1 + d2` and `d1 - d2`, Delegate.Combine and Delegate.Remove cast back.
				var d = tl.sig(e.type);
				pushArgs(args, [d, d]);
				var name = cf.name == "op_Addition" ? "Combine" : "Remove";
				code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(systemDelegate), name, g.sigs.method(false, systemDelegate, [systemDelegate, systemDelegate], 0)),
					2, 1);
				code.opToken(IlOps.CASTCLASS, g.typeTokenOf(d), 1, 1);
				tl.coerce(d, ret);
			case TField(_, FStatic(c, cf)) if (isExtern(c) && cf.name == "ReferenceEquals" && args.length == 2 && Globals.sTypePath(c.path) == "System.Object"):
				// Object.ReferenceEquals(a, b) is `ceq`, as C# compiles it: the JIT drops a value type's box next to it even in
				// unoptimized code, which a call would allocate.
				pushArgs(args, [LObject, LObject]);
				code.op(IlOps.CEQ, 2, 1);
				tl.coerce(LBool, ret);
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				externCall(ret, obj, fa, c, cf, args, callee.type);
			case TConst(TSuper):
				superCtorCall(args);
				tl.coerce(LVoid, ret);
			case TField(obj, FInstance(c, _, cf)) if (!TypeFunctions.hasClassFlag(c, CInterface) && tl.dyn.companionReceiver(obj)):
				// A method a class's companion interface declares (TexprDynamic.companionMember): the interface's.
				companionCall(ret, obj, tl.dyn.companionMember(c, cf), args, callee.type);
			case TField(obj, FInstance(c, params, cf)):
				// super.m() calls the base class's method itself.
				var isSuper = strip(obj).expr.match(TConst(TSuper));
				var m = haxeMethod(c, params, cf, args, callee.type, !isSuper);
				// A static constructor has no `this` to call the base method on non-virtually (gencs's C#,
				// `base.m()` in a static method, does not compile either).
				if (isSuper && tl.splitCtor) throw new Unsupported("super.method() calls in constructors", true);
				if (isSuper) code.ldarg(0) else receiver(obj, m.owner);
				pushArgs(args, m.args, argTypes(callee.type));
				var op = isSuper || DotnetTypes.isValueType(m.owner) ? IlOps.CALL : IlOps.CALLVIRT;
				if (m.isSetter) {
					// A property's set_X is its setter, and the call's value is the argument (ruling 7), as
					// gencs writes `o.X = v`.
					tl.storeKeeping(ret, m.args[0], () -> code.opToken(op, m.token, 2, 0));
					return;
				}
				code.opToken(op, m.token, args.length + 1, m.ret.match(LVoid) ? 0 : 1);
				tl.coerce(m.ret, ret);
			case TField(_, FEnum(en, ef)) if (EnumToIl.isHxGenEnum(en)):
				enumFactoryCall(ret, en, ef, args, callee.type);
			case TIdent(name):
				magicCall(ret, e, name, args);
			case _:
				invokeFunction(ret, e, callee, args);
		}
	}

	// `obj.name(args)` on a value typed as a companion interface, for the method `member` of a class that
	// the companion declares: callvirt on the companion's own declaration, as gencs's C# calls it (types notes
	// §5). An interface's methods that mention no type parameter are its companion's already (CompanionToIl).
	function companionCall(ret:Ret, obj:TExpr, member:{c:TClass, cf:TClassField}, args:Array<TExpr>, calleeType:T):Void {
		var m = g.methodPlans.get(member.cf), companion = g.companionPlans.get(member.c);
		var decl = null;
		if (m != null && companion != null) for (x in companion.methods) {
			if (x.kind.match(MCompanionMember) && x.name == m.name && IlPaths.sigEq(LMethod([], x.ret, x.args), LMethod([], m.ret, m.args))
				&& x.generics.length == m.generics.length)
				decl = x;
		}
		if (decl == null) throw "internal error: the companion of " + Globals.sTypePath(member.c.path) + " has no method " + member.cf.name;
		var margs = [for (t in DotnetTypes.inferParams(member.cf.params, member.cf.type, calleeType, false)) g.types.typeArg(t)];
		var token = margs.length > 0 ? g.mb.methodSpec(decl.token, g.sigs.methodSpec(margs)) : decl.token;
		var retSig = DotnetTypes.substitute(decl.ret, [], margs);
		tl.texpr(RValue(CompanionToIl.companionSig(member.c)), obj);
		pushArgs(args, [for (a in decl.args) DotnetTypes.substitute(a, [], margs)], argTypes(calleeType));
		code.opToken(IlOps.CALLVIRT, token, args.length + 1, retSig.match(LVoid) ? 0 : 1);
		tl.coerce(retSig, ret);
	}

	// A call of a function value, a haxe.lang.Function, as gencs's closuresToClass writes it. Each
	// argument is a pair: the value as a double and Runtime.undefined when its type is like a Float (not
	// an Int64), else 0.0 and the value boxed. `__hx_invoke<N>_f` when the call's type is like a Float,
	// else `_o`, the result then converted to the call's type; six arguments or more go boxed to
	// `__hx_invokeDynamic(object[])`. A callee that is not typed as a function is cast to one and always
	// gets `_o`. As NOTES §3.6 found, an Int result reaching Dynamic through an unsafe cast (an explicit
	// `cast`, or the inliner's for an argument of a Dynamic parameter, as in Sys.println) stays a Double.
	public function invokeFunction(ret:Ret, e:TExpr, callee:TExpr, args:Array<TExpr>):Void {
		var raw = rawCall == e;
		rawCall = null;
		var fc = runtimeClass("cs.internal.Function");
		var fnSig = tl.sig(TInst(fc, []));
		var typed = IlPaths.sigEq(tl.sig(callee.type), fnSig);
		if (typed) {
			tl.texpr(RValue(fnSig), callee);
		} else {
			tl.texpr(RValue(LObject), callee);
			tl.castTo(fnSig);
		}
		var own = tl.sig(e.type);
		if (args.length >= 6) {
			tl.dyn.pushObjects(args);
			code.opToken(IlOps.CALLVIRT, functionMethod(fc, "__hx_invokeDynamic"), 2, 1);
			tl.dyn.finish(LObject, own, ret);
			return;
		}
		for (a in args) {
			if (strip(a).expr.match(TUnop(Spread, _, _))) throw new Unsupported("the spread operator", false);
			if (TexprDynamic.likeFloatReal(a.type) && !TexprDynamic.likeI64Real(a.type)) {
				tl.texpr(RValue(LFloat64), a);
				pushUndefined();
			} else {
				code.opR8(IlOps.LDC_R8, 0.0, 0, 1);
				tl.texpr(RValue(LObject), a);
			}
		}
		var isFloat = typed && TexprDynamic.likeFloatReal(e.type) && !TexprDynamic.likeI64Real(e.type);
		code.opToken(IlOps.CALLVIRT, functionMethod(fc, "__hx_invoke" + args.length + (isFloat ? "_f" : "_o")), 1 + 2 * args.length, 1);
		// gencs's cast of the result to the call's type disappears under an unsafe cast, which then boxes
		// the double: `(object)f.__hx_invoke0_f()`.
		if (raw && isFloat) tl.coerce(LFloat64, ret) else tl.dyn.finish(isFloat ? LFloat64 : LObject, own, ret);
	}

	// Pushes a haxe.lang.Closure of the method `name` of `receiver`, evaluated now; of the type `owner`'s
	// static method, `typeof(owner)`, without one. Calling it calls the method by name through
	// Runtime.callField.
	public function pushClosure(receiver:Null<TExpr>, owner:IlSigNorm, name:String):Void {
		var c = runtimeClass("cs.internal.Closure");
		var plan = g.planOf.get(c);
		var ctor = null;
		if (plan != null) for (m in plan.methods) if (m.name == ".ctor" && m.args.length == 3) ctor = m;
		if (ctor == null) throw "internal error: haxe.lang.Closure has no constructor";
		if (receiver != null) tl.texpr(RValue(LObject), receiver) else pushTypeOf(owner);
		code.opToken(IlOps.LDSTR, g.mb.userString(name), 0, 1);
		code.ldcI4(FieldHashes.use(name));
		code.opToken(IlOps.NEWOBJ, ctor.token, 3, 1);
	}

	// With a new haxe.lang.Closure on the stack, gives it the invoker of the method `cf`, if it has one:
	// `closure.__hx_setInvoker(Invoker.__hx_current ?? (Invoker.__hx_current = new Invoker()))`.
	public function pushInvoker(cf:TClassField):Void {
		var invoker = g.methodInvokers.get(cf);
		if (invoker == null) return;
		// An invoker class that was left out: the value goes by name.
		var plan = g.planOf.get(invoker);
		if (plan == null) return;
		var ctor = null;
		for (m in plan.methods) if (m.name == ".ctor") ctor = m;
		if (ctor == null) throw "internal error: " + plan.hxPath + " has no constructor";
		var current = tl.staticField(invoker, invoker.statics.get("__hx_current"));
		var closure = runtimeClass("cs.internal.Closure");
		var set = functionMethod(closure, "__hx_setInvoker");
		var made = code.newLabel();
		code.op(IlOps.DUP, 1, 2);
		code.opToken(IlOps.LDSFLD, current.token, 0, 1);
		code.op(IlOps.DUP, 1, 2);
		code.branch(IlOps.BRTRUE, made);
		code.op(IlOps.POP, 1, 0);
		code.opToken(IlOps.NEWOBJ, ctor.token, 0, 1);
		code.op(IlOps.DUP, 1, 2);
		code.opToken(IlOps.STSFLD, current.token, 1, 0);
		code.mark(made);
		code.opToken(IlOps.CALLVIRT, set, 2, 0);
	}

	function closureSig():IlSigNorm return tl.sig(TInst(runtimeClass("cs.internal.Closure"), []));

	// A class of hxc's copy of hxcs's runtime that the code needs.
	function runtimeClass(hxPath:String):TClass {
		var c = g.runtimeClass(hxPath);
		if (c == null) throw new Unsupported("function values without " + hxPath, false);
		g.types.checkKept(TClassDecl(c));
		return c;
	}

	// The token of haxe.lang.Function's virtual method `name`.
	function functionMethod(fc:TClass, name:String):Int {
		var cf = fc.fields.get(name);
		if (cf == null) throw "internal error: haxe.lang.Function has no " + name;
		return haxeMethod(fc, [], cf, [], cf.type).token;
	}

	// Runtime.undefined, the Dynamic half of an argument passed as a double.
	function pushUndefined():Void {
		var rt = runtimeClass("cs.internal.Runtime");
		var cf = rt.statics.get("undefined");
		if (cf == null) throw new Unsupported("haxe.lang.Runtime.undefined", false);
		code.opToken(IlOps.LDSFLD, tl.staticField(rt, cf).token, 0, 1);
	}

	// A method, not a variable or a dynamic method, which is a field holding a haxe.lang.Function.
	static function isMethod(cf:TClassField):Bool {
		return cf.kind.match(Method(_)) && !cf.kind.match(Method(MethDynamic));
	}

	// An Array<Dynamic>, which hxcs declares as the non-generic Array.
	static function isDynamicArray(t:T):Bool {
		var a = arrayOf(t);
		return a != null && TexprDynamic.isTDynamic(a.params[0]);
	}

	// A constructor with arguments: its factory, each argument converted to its type in the call's
	// instantiation (`calleeType`) first, then to the factory's erased one, as Some(2) of an Opt<Float>
	// stores a boxed Float.
	function enumFactoryCall(ret:Ret, en:TEnum, ef:TEnumField, args:Array<TExpr>, calleeType:T):Void {
		g.types.checkKept(TEnumDecl(en));
		var plan = g.enumPlans.get(en);
		var erased = plan.argSigs[ef.index];
		var own = switch (TypeFunctions.follow(calleeType)) {
			case TFun(sig): [for (a in sig.args) g.types.argSig(a.t, a.opt)];
			case _: throw "internal error: the constructor " + ef.name + " is called without a function type";
		}
		if (args.length != erased.length || own.length != erased.length) throw new Unsupported("calls that leave out arguments", true);
		for (i in 0...args.length) {
			tl.texpr(RValue(own[i]), args[i]);
			tl.convert(own[i], erased[i]);
		}
		code.opToken(IlOps.CALL, plan.factory(ef), args.length, 1);
		tl.coerce(plan.base.thisSig, ret);
	}

	// The return type of System.Object's member `name` taking `argc` arguments, or null for another name.
	function objectMember(name:String, argc:Int):Null<IlSigNorm> {
		return switch [name, argc] {
			case ["ToString", 0]: LString;
			case ["GetHashCode", 0]: LInt32;
			case ["GetType", 0]: systemType;
			case ["Equals", 1]: LBool;
			case _: null;
		}
	}

	// The class a call of Type.createEmptyInstance with a constant class in gencs's model creates, with
	// its type arguments, or null.
	function emptyInstanceOf(e:TExpr, c:TClass, cf:TClassField, args:Array<TExpr>):Null<{c:TClass, params:TParams}> {
		if (c.path.pack.length != 0 || c.path.name != "Type" || cf.name != "createEmptyInstance" || args.length != 1) return null;
		var cl = switch (strip(args[0]).expr) {
			case TTypeExpr(TClassDecl(cl)): cl;
			case _: return null;
		}
		return switch (TypeFunctions.follow(e.type)) {
			case TInst(c2, params) if (c2 == cl && HxGen.isHxGen(TClassDecl(cl))):
				var plan = g.planOf.get(cl);
				plan == null || plan.emptyCtor == null ? null : {c: cl, params: params};
			case _: null;
		}
	}

	static final systemType:IlSigNorm = LClass({ns: ["System"], nested: [], name: "Type"}, []);
	static final monitor:IlSigNorm = LClass({ns: ["System", "Threading"], nested: [], name: "Monitor"}, []);

	// `new T[]{a, b}` of the call's type, a cs.NativeArray<T>.
	function newVector(ret:Ret, e:TExpr, args:Array<TExpr>):Void {
		var elem = vectorElement(tl.sig(e.type));
		var elemToken = g.typeTokenOf(elem);
		for (a in args) if (strip(a).expr.match(TUnop(Spread, _, _))) throw new Unsupported("the spread operator", false);
		// When an element holds a loop or a try, which need an empty stack, the elements are evaluated
		// first, in order, into locals, as gencs's C# evaluates a block it hoists out of the initializer
		// (`__temp_stmt1`).
		var temps:Null<Array<Int>> = null;
		if (Lambda.exists(args, needsEmptyStack)) temps = [
			for (a in args) {
				tl.texpr(RValue(elem), a);
				var t = code.addLocal(elem);
				code.stloc(t);
				t;
			}
		];
		code.ldcI4(args.length);
		code.opToken(IlOps.NEWARR, elemToken, 1, 1);
		for (i in 0...args.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			if (temps != null) code.ldloc(temps[i]) else tl.texpr(RValue(elem), args[i]);
			code.stelem(elem, () -> elemToken);
		}
		tl.coerce(LVector(elem), ret);
	}

	// Whether `e` holds something that starts on an empty stack: a loop's head or a try block. A local
	// function's body is its own method.
	static function needsEmptyStack(e:TExpr):Bool {
		return switch (e.expr) {
			case TWhile(_, _, _) | TFor(_, _, _) | TTry(_, _): true;
			case TFunction(_): false;
			case _: TexprTools.checkExpr(needsEmptyStack, e);
		}
	}

	static final systemDelegate:IlSigNorm = LClass({ns: ["System"], nested: [], name: "Delegate"}, []);

	// `cast __delegate__(f)`, the conversion `e` of a Haxe function to the .NET delegate type D, as
	// ClosuresToClass.delegate leaves it: `f` is a method group, a static method or an instance method on
	// its receiver (a closure class's Delegate method among them), which gencs's C# writes as `(D)(o.m)`.
	// Roslyn's delegate creation: the receiver (null for a static method), the method's address
	// (ldvirtftn on a dup of the receiver for a virtual method), then D's constructor. No delegate is
	// cached, where Roslyn caches one made from a static method (ruling 9). As C#'s method group
	// conversion, the method takes the types of D's Invoke, a parameter of a reference type also one
	// the Invoke's type converts to, and returns its return type or a reference type converting to it;
	// gencs's C# does not compile otherwise (CS0030, CS0123), and hxc refuses it.
	function delegate(ret:Ret, e:TExpr, call:TExpr):Void {
		var del = switch (call.expr) {
			case TCall(_, [del]): strip(del);
			case _: throw "internal error: not a __delegate__ call";
		}
		var d = tl.sig(e.type);
		var invoke = g.externs.delegateInvoke(d);
		if (invoke == null) throw Unsupported.bug("a conversion to " + ExternMembers.sigS(d) + ", which is no .NET delegate type");
		var targets = [{d: d, invoke: invoke}];
		// The delegate going on as another delegate type that it does not convert to, as Haxe unifies
		// Func_2<Int, Bool> with Func_2<Dynamic, Bool>: gencs's C# casts it there, which C# refuses (CS0030)
		// unless the method converts to that type too, and which throws otherwise.
		switch (ret) {
			case RValue(t) if (t != null && !IlPaths.sigEq(t, d) && !g.externs.implicitlyConverts(d, t)):
				var other = g.externs.delegateInvoke(t);
				if (other != null) targets.unshift({d: t, invoke: other});
			case _:
		}
		function check(args:Array<IlSigNorm>, r:IlSigNorm):Void {
			for (target in targets) {
				var invoke = target.invoke;
				var ok = args.length == invoke.args.length && delegateConverts(r, invoke.ret);
				for (i in 0...args.length) if (ok && !delegateConverts(invoke.args[i], args[i])) ok = false;
				if (ok) continue;
				var u = Unsupported.error("a function of type " + hxc.core.TPrinting.sTypeStr(del.type) + " converted to the .NET delegate "
					+ ExternMembers.sigS(target.d) + ", whose Invoke takes (" + [for (a in invoke.args) ExternMembers.sigS(a)].join(", ") + ") -> "
					+ ExternMembers.sigS(invoke.ret));
				u.pos = del.pos;
				throw u;
			}
		}
		switch (del.expr) {
			case TField(_, FStatic(c, cf)) if (!isExtern(c) && isMethod(cf) && !isOverloaded(cf)):
				g.types.checkKept(TClassDecl(c));
				var plan = g.ownerOf.get(cf);
				if (plan == null || !g.methodTokens.exists(cf)) throw "internal error: no method " + Globals.sTypePath(c.path) + "." + cf.name;
				var m = methodRef(plan, staticOwner(plan), [], cf, cf.type, del.type);
				check(m.args, m.ret);
				code.op(IlOps.LDNULL, 0, 1);
				code.opToken(IlOps.LDFTN, m.token, 0, 1);
			case TField(obj, fa = FClosure({c: c, params: params}, cf)) if (!isExtern(c) && !isStringClass(c) && isMethod(cf) && !isOverloaded(cf)
				&& !tl.dyn.isDynamicReceiver(fa, obj) && (TypeFunctions.hasClassFlag(c, CInterface) || !tl.dyn.companionReceiver(obj))):
				var m = haxeMethod(c, params, cf, [], del.type, true);
				if (DotnetTypes.isValueType(m.owner)) throw new Unsupported("methods of structs as .NET delegates", true);
				check(m.args, m.ret);
				receiver(obj, m.owner);
				var plan = g.methodPlans.get(cf);
				if (plan != null && (plan.flags & MethodAttrs.VIRTUAL) != 0) {
					code.op(IlOps.DUP, 1, 2);
					code.opToken(IlOps.LDVIRTFTN, m.token, 1, 1);
				} else {
					code.opToken(IlOps.LDFTN, m.token, 0, 1);
				}
			case TField(_, FStatic(c, _) | FClosure({c: c}, _)) if (isExtern(c)):
				throw new Unsupported(".NET methods as .NET delegates", true);
			case _:
				throw new Unsupported("this kind of method as a .NET delegate", false);
		}
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(d), ".ctor", g.sigs.method(true, LVoid, [LObject, LIntPtr], 0)), 2, 1);
		tl.coerce(d, ret);
	}

	static function isOverloaded(cf:TClassField):Bool {
		return cf.overloads.length > 0 || TypeFunctions.hasClassFieldFlag(cf, CfOverload);
	}

	// Whether a delegate's `from` passes as `to` in C#'s method group conversion: the same type, or
	// reference types with an implicit reference conversion between them.
	function delegateConverts(from:IlSigNorm, to:IlSigNorm):Bool {
		return IlPaths.sigEq(from, to) || isReference(from) && isReference(to) && g.externs.implicitlyConverts(from, to);
	}

	// gencs's magic identifiers in untyped code, which hxcs's std uses: `__as__(e)` is C#'s `e as T`
	// with T the call's type, `__is__(e, T)` C#'s `e is T`, `__typeof__(T)` `typeof(T)` and
	// `__lock__(obj, block)` `lock (obj) block`. `__array__(a, b)`, which the captured_vars filter
	// writes to box a captured variable that is written, is `new T[]{a, b}`. `__refused__(what)` is what
	// ClosuresToClass could not lower.
	function magicCall(ret:Ret, e:TExpr, name:String, args:Array<TExpr>):Void {
		switch [name, args.length] {
			case ["__array__", _]:
				newVector(ret, e, args);
			case ["__refused__", 1]:
				switch (strip(args[0]).expr) {
					case TConst(TString(what)): throw new Unsupported(what, true);
					case _: throw new Unsupported("untyped code", false);
				}
			case ["__as__", 1]:
				var to = tl.sig(e.type);
				tl.texpr(RValue(LObject), args[0]);
				if (DotnetTypes.isValueType(to)) {
					code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
				} else if (isTypeParam(to)) {
					code.opToken(IlOps.ISINST, g.typeTokenOf(to), 1, 1);
					code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
				} else if (!to.match(LObject)) {
					code.opToken(IlOps.ISINST, g.typeTokenOf(to), 1, 1);
				}
				tl.coerce(to, ret);
			case ["__is__", 2]:
				var t = typeArg(args[1]);
				tl.texpr(RValue(LObject), args[0]);
				code.opToken(IlOps.ISINST, g.typeTokenOf(t), 1, 1);
				code.op(IlOps.LDNULL, 0, 1);
				code.op(IlOps.CGT_UN, 2, 1);
				tl.coerce(LBool, ret);
			case ["__typeof__", 1]:
				pushTypeOf(typeArg(args[0]));
				tl.coerce(systemType, ret);
			case ["__lock__", 2]:
				lock(args[0], args[1]);
				tl.coerce(LVoid, ret);
			case ["__cs__", n] if (n >= 1):
				tl.inlineCs.code(ret, e, CsToIl.constantText(args[0]), args.slice(1), true, e.pos);
			case _:
				throw new Unsupported("untyped code", false);
		}
	}

	// The type a magic identifier's type argument names: a type expression, or in untyped code the name
	// of a type parameter in scope. A generic class is its instantiation with object for each parameter,
	// as gencs writes `typeof(G<object>)`, not its companion interface.
	function typeArg(e:TExpr):IlSigNorm {
		switch (strip(e).expr) {
			case TTypeExpr(mt):
				var params = [for (_ in TypeFunctions.tParams(mt)) TypeFunctions.tDynamic];
				return tl.sig(switch (mt) {
					// An abstract named as a value is its implementation class.
					case TClassDecl(c): switch (c.kind) {
							case KAbstractImpl(a): TAbstract(a, [for (_ in a.params) TypeFunctions.tDynamic]);
							case _: return g.types.classSig(c, params);
						}
					case TEnumDecl(en): TEnum(en, params);
					case TTypeDecl(td): TType(td, params);
					case TAbstractDecl(a): TAbstract(a, params);
				});
			case TIdent(name):
				var t = g.types.paramNamed(name);
				if (t != null) return tl.sig(t);
			case _:
		}
		throw new Unsupported("untyped code", false);
	}

	// typeof(T): its token, then System.Type.GetTypeFromHandle.
	function pushTypeOf(t:IlSigNorm):Void {
		var handle = LValueType({ns: ["System"], nested: [], name: "RuntimeTypeHandle"}, []);
		code.opToken(IlOps.LDTOKEN, g.typeTokenOf(t), 0, 1);
		code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(systemType), "GetTypeFromHandle", g.sigs.method(false, systemType, [handle], 0)), 1, 1);
	}

	// C#'s `lock (obj) block`: Monitor.Enter on the object, then the block in a try whose finally calls
	// Monitor.Exit. A type expression locks its System.Type, as gencs writes `lock(typeof(T))`.
	function lock(obj:TExpr, block:TExpr):Void {
		if (code.depth != 0) throw new Unsupported("`lock` inside expressions", false);
		if (strip(obj).expr.match(TTypeExpr(_))) pushTypeOf(typeArg(obj)) else tl.texpr(RValue(LObject), obj);
		var held = code.addLocal(LObject);
		code.stloc(held);
		var enter = g.mb.memberRef(g.typeTokenOf(monitor), "Enter", g.sigs.method(false, LVoid, [LObject], 0));
		var exit = g.mb.memberRef(g.typeTokenOf(monitor), "Exit", g.sigs.method(false, LVoid, [LObject], 0));
		code.ldloc(held);
		code.opToken(IlOps.CALL, enter, 1, 0);
		tl.flow.tryFinally(() -> tl.texpr(RVoid, block), () -> {
			code.ldloc(held);
			code.opToken(IlOps.CALL, exit, 1, 0);
		});
	}

	// The overload a call of a Haxe method reaches, as the JVM generator picks it.
	function pickOverload(c:TClass, params:TParams, cf:TClassField, args:Array<TExpr>, isStatic:Bool):TClassField {
		if (cf.overloads.length == 0 && !TypeFunctions.hasClassFieldFlag(cf, CfOverload)) return methodOfSignature(c, cf, isStatic);
		var mapType = (t:T) -> TypeFunctions.applyParams(c.params, params, t);
		var r = isStatic ? OverloadResolution.filterOverloads(OverloadResolution.findOverload(mapType, c, cf, args)) : OverloadResolution.maybeResolveInstanceOverload(false,
			mapType, c, cf, args);
		if (r == null) throw new Unsupported("this call of an overloaded method", false);
		return methodOfSignature(c, r.cf, isStatic);
	}

	// A signature in an @:overload meta, as on std's Reflect.makeVarArgs, has no method of its own, and the typer may
	// have put it in the call: the call binds to the field it belongs to, as C# binds it to the only method gencs writes.
	function methodOfSignature(c:TClass, cf:TClassField, isStatic:Bool):TClassField {
		if (g.methodTokens.exists(cf)) return cf;
		var main = isStatic ? c.statics.get(cf.name) : c.fields.get(cf.name);
		return main != null && g.methodTokens.exists(main) ? main : cf;
	}

	// A Haxe class's instance variable as an access through `c` with `params` reaches it: its token, its
	// type there and the type of the class declaring it.
	function instanceField(c:TClass, params:TParams, cf:TClassField):{token:Int, sig:IlSigNorm, owner:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		cf = declaredField(c, cf);
		// An event's var is its field-like backing field in its own class and has no value elsewhere.
		if (EventToIl.isEventVar(cf)) EventToIl.checkValue(g, tl.cls, c, cf);
		var plan = g.ownerOf.get(cf);
		if (plan == null || !g.fieldTokens.exists(cf)) {
			if (!TypeFunctions.isPhysicalField(cf)) throw new Unsupported("this kind of field access", false);
			throw "internal error: no field " + Globals.sTypePath(c.path) + "." + cf.name;
		}
		var inst = g.types.classArgs(plan.c, tl.ownerArgs(c, params, plan));
		var owner = DotnetCtx.instanceOf(plan, inst);
		return {token: g.memberOf(plan, owner, cf), sig: DotnetTypes.substitute(g.fieldSigs.get(cf), inst, []), owner: owner};
	}

	// The getter or (`isSet`) the setter of the CLR property a @:property var is (DotnetCtx.varProperties), as
	// an access through `c` with `params` reaches it: its token and call opcode, the property's type there, the
	// type of the class declaring it (for a static, gencs's instantiation of a generic class with object) and
	// whether it is static.
	function varAccessor(c:TClass, params:TParams, cf:TClassField, isSet:Bool):{token:Int, op:Int, sig:IlSigNorm, owner:IlSigNorm, isStatic:Bool} {
		g.types.checkKept(TClassDecl(c));
		var p = g.varProperties.get(cf), plan = g.ownerOf.get(cf);
		var m = isSet ? p.setter : p.getter;
		if (p.isStatic) {
			var owner = staticOwner(plan);
			return {token: g.methodOf(plan, owner, m), op: IlOps.CALL, sig: p.sig, owner: owner, isStatic: true};
		}
		var inst = g.types.classArgs(plan.c, tl.ownerArgs(c, params, plan));
		var owner = DotnetCtx.instanceOf(plan, inst);
		return {
			token: g.methodOf(plan, owner, m),
			op: DotnetTypes.isValueType(owner) ? IlOps.CALL : IlOps.CALLVIRT,
			sig: DotnetTypes.substitute(p.sig, inst, []),
			owner: owner,
			isStatic: false
		};
	}

	// The field an overriding dynamic method of `c` stands for: the one its superclass declares.
	static function declaredField(c:TClass, cf:TClassField):TClassField {
		var cur = c;
		while (cf.kind.match(Method(MethDynamic)) && TypeFunctions.hasClassFieldFlag(cf, CfOverride) && cur.superClass != null) {
			cur = cur.superClass.c;
			var f = cur.fields.get(cf.name);
			if (f != null) cf = f;
		}
		return cf;
	}

	// A method's token as a call reaches it, with a MethodSpec for a generic method, and its argument
	// and return types there. `declared` is the method's type with the class's type arguments applied;
	// the call's `calleeType` gives the method's own, those `given` binds aside. As gencs's change_param_type,
	// a class that is not hxgen (with type parameters of its own: not hxgeneric) keeps those: `Continue.then<T>` of
	// a @:nativeGen class takes a Task<IStorageFile>, which no Task<object> is.
	function methodRef(plan:ClassPlan, owner:IlSigNorm, inst:Array<IlSigNorm>, target:TClassField, declared:T,
			calleeType:T, ?given:Array<Null<T>>):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm} {
		var token = g.memberOf(plan, owner, target);
		var native = plan.c != null && !(plan.c.params.length == 0 ? HxGen.isHxGen(TClassDecl(plan.c)) : HxGeneric.isHxGeneric(g, plan.c));
		var margs = [for (t in DotnetTypes.inferParams(target.params, declared, calleeType, false, given)) native ? g.types.nativeArg(t) : g.types.typeArg(t)];
		if (margs.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec(margs));
		var m = g.methodSigs.get(target);
		return {
			token: token,
			args: [for (a in m.args) DotnetTypes.substitute(a, inst, margs)],
			ret: DotnetTypes.substitute(m.ret, inst, margs)
		};
	}

	// What a call of an abstract's member method `cf` binds of its type parameters before the call's
	// types do: the abstract's own, which come last (GenerateDotnet.addAbstractParams), from the receiver,
	// the first argument. `listInts().then(f)` with a Pr<Int> receiver is `then<R,int>`. hxc's typer
	// types the call of an implicit member `@:to` cast without the abstract's type arguments applied, so
	// the call's type cannot give them there; Haxe's applies them, and gencs has `toArr<int>`. Null where
	// the receiver is not of the abstract's type (`this1` inside the abstract), which the call's types
	// then bind.
	static function receiverArgs(c:TClass, cf:TClassField, args:Array<TExpr>):Null<Array<Null<T>>> {
		var a = switch (c.kind) {
			case KAbstractImpl(a) if (a.params.length > 0 && args.length > 0 && GenerateDotnet.isAbstractMember(cf)): a;
			case _: return null;
		}
		var first = cf.params.length - a.params.length;
		if (first < 0 || cf.params[first] != a.params[0]) return null;
		return switch (TypeFunctions.follow(args[0].type)) {
			case TAbstract(a2, tl) if (a2 == a && tl.length == a.params.length):
				[for (i in 0...cf.params.length) i < first || TypeFunctions.follow(tl[i - first]).match(TMono(_)) ? null : tl[i - first]];
			case _: null;
		}
	}

	// A Haxe class's instance method, the overload the call reaches. A virtual call of an @:overload override
	// that erasure gave a bridge reaches, as gencs's does, the overload it overrides, whose slot the bridge takes.
	function haxeMethod(c:TClass, params:TParams, cf:TClassField, args:Array<TExpr>, calleeType:T,
			isVirtual = false):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm, owner:IlSigNorm, isSetter:Bool} {
		g.types.checkKept(TClassDecl(c));
		var target = pickOverload(c, params, cf, args, false);
		var declaring = g.ownerOf.get(target);
		if (isVirtual && declaring != null && declaring.c != null) {
			var o = TclassToIl.overriddenOverload(g, declaring.c, target);
			if (o != null) target = o;
		}
		var plan = g.ownerOf.get(target);
		if (plan == null || !g.methodTokens.exists(target)) throw "internal error: no method " + Globals.sTypePath(c.path) + "." + cf.name;
		var hxArgs = tl.ownerArgs(c, params, plan);
		var inst = g.types.classArgs(plan.c, hxArgs);
		var owner = DotnetCtx.instanceOf(plan, inst);
		var declared = plan.c == null ? target.type : TypeFunctions.applyParams(plan.c.params, hxArgs, target.type);
		var m = methodRef(plan, owner, inst, target, declared, calleeType);
		// The set_X of a property var stands for the property's setter (TclassToIl.write).
		var isSetter = g.methodPlans.get(target).kind.match(MPropertyAccessor(_, true));
		return {token: m.token, args: m.args, ret: m.ret, owner: owner, isSetter: isSetter};
	}

	// A method of a referenced assembly; super.m() calls the base method itself.
	function externCall(ret:Ret, obj:TExpr, fa:TFieldAccess, c:TClass, cf:TClassField, args:Array<TExpr>, calleeType:T):Void {
		var isStatic = fa.match(FStatic(_, _));
		var isSuper = !isStatic && strip(obj).expr.match(TConst(TSuper));
		var inst = instantiation(c, fa);
		// The extern method's type arguments, inferred from the call as for a Haxe method.
		var own:Array<IlSigNorm> = [];
		if (cf.params.length > 0) {
			var declared = switch (fa) {
				case FInstance(_, params, _): TypeFunctions.applyParams(c.params, params, cf.type);
				case _: cf.type;
			}
			own = [for (t in DotnetTypes.inferParams(cf.params, declared, calleeType, false)) g.types.nativeArg(t)];
		}
		var site = externCallSite(args, inst, own);
		var recv = isStatic ? null : receiverType(obj, c, cf);
		var start = recv == null ? null : receiverClass(recv, c);
		if (!isSuper) switch (recv) {
			case TInst(rc, _) if (!rc.kind.match(KTypeParameter(_))): site.receiverStatic = rc;
			case _:
		}
		// A type-parameter receiver (a constraint was taken for a hand-written extern) is no receiver of the caller's class.
		if (!isSuper) switch (TypeFunctions.follow(obj.type)) {
			case TInst(tp, _) if (tp.kind.match(KTypeParameter(_))): site.receiverOpaque = true;
			case _:
		}
		if (start != null) {
			site.receiver = start.c;
			site.receiverArgs = start.args;
		} else if (!isStatic && !isSuper && TypeFunctions.hasClassFlag(c, CInterface)) {
			// Ruling O: through an extern interface that extends the declaring one.
			switch (recv) {
				case TInst(rc, _) if (rc != c && TypeFunctions.hasClassFlag(rc, CInterface) && TypeFunctions.hasClassFlag(rc, CExtern) && hasNetType(rc)):
					g.externs.checkInterfaceReceiver(rc, c, cf);
				case _:
			}
		}
		var m = g.externs.method(c, cf, false, site);
		if (isSuper) m = g.externs.superCall(start != null ? start.c : c, m);
		// A generic method's type arguments: those the call's argument types give when the extern method has
		// no type parameters (ExternMembers.method), else the extern method's own.
		var margs:Array<IlSigNorm> = m.typeArgs != null ? m.typeArgs : own;
		// Matching skips methods of another generic arity, so this fires only after a matching bug.
		if (m.typeArgs == null && cf.params.length != m.genericCount || m.typeArgs != null && m.typeArgs.length != m.genericCount)
			throw Unsupported.bug("a .NET method with another generic arity (internal: overload matching)");
		var parent = ExternMembers.subst(m.parent, start != null ? start.args : inst);
		var parentArgs = switch (parent) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		var ilRet:IlSigNorm, ilArgs:Array<IlSigNorm>;
		switch (m.sig) {
			case LMethod(_, r, l):
				ilRet = r;
				ilArgs = l;
			case _:
				throw "internal error: not a method signature";
		}
		if (isSuper) code.ldarg(0) else if (!isStatic) receiver(obj, parent);
		var slots = [for (a in ilArgs) DotnetTypes.substitute(a, parentArgs, margs)];
		pushExternArgs(args, slots, m.omitted);
		var token = g.mb.memberRef(g.typeTokenOf(parent), m.name, g.sigs.methodSig(m.sig, m.genericCount));
		if (margs.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec(margs));
		var retSlot = DotnetTypes.substitute(ilRet, parentArgs, margs);
		var op = isStatic || isSuper || DotnetTypes.isValueType(parent) ? IlOps.CALL : IlOps.CALLVIRT;
		// The value of `x.P = v`, which the typer makes a call of set_P, is v, as C#'s: what the setter stored.
		var stored = retSlot.match(LVoid) && needVal(ret) && cf.name.substr(0, 4) == "set_" && args.length == 1 && slots.length == 1;
		if (retSlot.match(LVoid) && needVal(ret) && !stored) throw new Unsupported("the value of a .NET setter call", false);
		function call() code.opToken(op, token, ilArgs.length + (isStatic ? 0 : 1), retSlot.match(LVoid) ? 0 : 1);
		if (stored) {
			tl.storeKeeping(ret, slots[0], call);
			return;
		}
		call();
		tl.coerce(retSlot, ret);
	}

	// Ruling M: where C# starts looking for an instance method `c` declares, when that is below `c`: the
	// extern class of the receiver's static type, or its nearest extern superclass that has a .NET type,
	// with its type arguments. Null where that is `c` itself or `c` is not among its superclasses (an
	// interface's method, or a receiver of another kind of type).
	function receiverClass(recv:T, c:TClass):Null<{c:TClass, args:Array<IlSigNorm>}> {
		var rc:TClass, params:Array<T>;
		switch (recv) {
			case TInst(c1, p1) if (!c1.kind.match(KTypeParameter(_))):
				rc = c1;
				params = p1;
			case _:
				return null;
		}
		inline function up():Bool {
			var sup = rc.superClass;
			if (sup != null) {
				var cparams = rc.params, args = params;
				params = [for (p in sup.params) TypeFunctions.applyParams(cparams, args, p)];
				rc = sup.c;
			}
			return sup != null;
		}
		// The nearest extern class with a .NET type.
		while (rc != c && !(TypeFunctions.hasClassFlag(rc, CExtern) && hasNetType(rc))) if (!up()) return null;
		if (rc == c) return null;
		var start = rc, startParams = params;
		while (rc != c) if (!up()) return null;
		return {c: start, args: g.types.classArgs(start, startParams)};
	}

	// The receiver's static type for rulings M and O, followed: a type parameter's is its one constraint
	// that is an extern class or interface with a .NET type, or a Haxe class below one (ruling P). A call of
	// a hand-written extern's method through a type parameter with several constraints, or none of those,
	// is refused (`isField`: an access to a variable).
	function receiverType(obj:TExpr, c:TClass, cf:TClassField, isField = false):T {
		var t = TypeFunctions.follow(obj.type);
		switch (t) {
			case TInst(tp, _):
				switch (tp.kind) {
					case KTypeParameter(constraints) if (!TypeFunctions.hasMeta(":csNative", c.meta)):
						if (constraints.length == 1) {
							var k = TypeFunctions.follow(constraints[0]);
							if (mapsToNet(k)) return k;
						}
						throw Unsupported.error("hxc cannot tell which .NET " + (isField ? "member " : "overload of ")
							+ ExternMembers.sigS(LClass(g.types.externPath(c), [])) + "." + ExternMembers.memberName(cf) + " the type parameter "
							+ tp.path.name + "'s constraints select");
					case _:
				}
			case _:
		}
		return t;
	}

	// Whether `t` is an extern class or interface with a .NET type, or a Haxe class below such a class.
	function mapsToNet(t:T):Bool {
		var k = switch (t) {
			case TInst(k, _) if (!k.kind.match(KTypeParameter(_))): k;
			case _: return false;
		}
		if (!TypeFunctions.hasClassFlag(k, CExtern) && TypeFunctions.hasClassFlag(k, CInterface)) return false;
		while (k != null) {
			if (TypeFunctions.hasClassFlag(k, CExtern)) return hasNetType(k);
			k = k.superClass == null ? null : k.superClass.c;
		}
		return false;
	}

	// Whether the extern class `c` names a .NET type a referenced assembly defines.
	function hasNetType(c:TClass):Bool {
		return try NetRefs.of(g.ctx).definer(g.types.externPath(c)) != null catch (_:Unsupported) false;
	}

	// A .NET constructor: its MemberRef, with the arguments pushed (`argc` of them).
	function externCtor(c:TClass, params:TParams, args:Array<TExpr>):{token:Int, parent:IlSigNorm, argc:Int} {
		var r = OverloadResolution.maybeResolveConstructorOverload(c, params, args);
		if (r == null) throw "internal error: no constructor of " + Globals.sTypePath(c.path) + " fits";
		if (r.c != c) throw new Unsupported("inherited .NET constructors", true);
		var classArgs = g.types.classArgs(c, params);
		var m = g.externs.method(c, r.cf, false, externCallSite(args, classArgs, []));
		var parent = ExternMembers.subst(m.parent, classArgs);
		var parentArgs = switch (parent) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		var ilArgs = switch (m.sig) {
			case LMethod(_, _, l): l;
			case _: throw "internal error: not a method signature";
		}
		pushExternArgs(args, [for (a in ilArgs) ExternMembers.subst(a, parentArgs)], m.omitted);
		return {token: g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.methodSig(m.sig, 0)), parent: parent, argc: ilArgs.length};
	}

	// A call site of an extern method with the arguments `args`, as ExternMembers.method takes it: each
	// argument's own type, as gencs's C# sees it, unless it is Dynamic (a type parameter is its own type, as C#
	// infers a generic method's type argument from it: `Ovl.G(x)` is `G<!0>`), and the type arguments of the
	// extern class and method.
	function externCallSite(args:Array<TExpr>, classArgs:Array<IlSigNorm>, methodArgs:Array<IlSigNorm>):ExternCall {
		return {
			args: args,
			argTypes: [for (a in args) TexprDynamic.isDynamic(a.type) && !TexprDynamic.isTypeParamType(a.type) ? null : try tl.sig(a.type) catch (_:Unsupported) null],
			caller: tl.cls,
			classArgs: classArgs,
			methodArgs: methodArgs
		};
	}

	// Pushes the arguments of a call of a .NET method whose parameters are of the types `slots`: those
	// given, then a default for each one the call leaves out, `omitted`.
	function pushExternArgs(args:Array<TExpr>, slots:Array<IlSigNorm>, omitted:Array<IlMethodArg>):Void {
		if (args.length + omitted.length != slots.length) throw new Unsupported("calls that leave out arguments", true);
		pushArgs(args, slots.slice(0, args.length));
		for (i in 0...omitted.length) pushDefault(omitted[i], slots[args.length + i]);
	}

	// Pushes what C# passes for the parameter `arg`, of the type `slot`, that a call leaves out, as Roslyn
	// fills it from the metadata (values notes §2): its Constant row's value (a Nullable<A>'s wrapped, a
	// value going to a reference type boxed, null to a value type default(T)), its DecimalConstant or
	// DateTimeConstant attribute's, an empty params array, or for an [Optional] parameter without a value
	// System.Reflection.Missing.Value going to object and default(T) otherwise.
	function pushDefault(arg:IlMethodArg, slot:IlSigNorm):Void {
		var inner = switch (slot) {
			case LValueType(_, [a]) if (DotnetTypes.isSystemNullable(slot)): a;
			case _: null;
		}
		// Wraps the value on the stack when the slot is its Nullable.
		function wrap():Void {
			if (inner != null) tl.convert(inner, slot);
		}
		switch (arg.pdefault) {
			case PDecimal(scale, negative, hi, mid, lo):
				var decimal = LValueType(systemPath("Decimal"), []);
				code.ldcI4(lo);
				code.ldcI4(mid);
				code.ldcI4(hi);
				code.ldcI4(negative ? 1 : 0);
				code.ldcI4(scale);
				code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(decimal), ".ctor", g.sigs.method(true, LVoid, [LInt32, LInt32, LInt32, LBool, LUInt8], 0)), 5, 1);
				wrap();
				return;
			case PDateTime(ticks):
				var dateTime = LValueType(systemPath("DateTime"), []);
				code.opI64(IlOps.LDC_I8, ticks, 0, 1);
				code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(dateTime), ".ctor", g.sigs.method(true, LVoid, [LInt64], 0)), 1, 1);
				wrap();
				return;
			case PParamArray:
				var elem = switch (slot) {
					case LVector(t): t;
					case _: throw "internal error: a params parameter that is no array";
				}
				var empty = g.mb.memberRef(g.typeTokenOf(LClass(systemPath("Array"), [])), "Empty", g.sigs.method(false, LVector(LMethodTypeParam(0)), [], 1));
				code.opToken(IlOps.CALL, g.mb.methodSpec(empty, g.sigs.methodSpec([elem])), 0, 1);
				return;
			case null:
		}
		switch (arg.constant) {
			case null if (slot.match(LObject)):
				var missing = LClass({ns: ["System", "Reflection"], nested: [], name: "Missing"}, []);
				code.opToken(IlOps.LDSFLD, g.mb.memberRef(g.typeTokenOf(missing), "Value", g.sigs.field(missing)), 0, 1);
			case null | INull:
				tl.pushDefault(slot);
			case k:
				var t = inner != null ? inner : slot;
				var stored = switch (t) {
					case LValueType(p, []):
						var u = g.externs.enumUnderlying(p);
						u != null ? u : t;
					case _: t;
				}
				var pushed = constant(k, stored);
				if (inner != null) wrap() else if (pushed != null && DotnetTypes.isValueType(pushed) && !DotnetTypes.isValueType(slot))
					code.opToken(IlOps.BOX, g.typeTokenOf(pushed), 1, 1);
		}
	}

	static function systemPath(name:String):IlPath return {ns: ["System"], nested: [], name: name};

	// A Haxe class's constructor: the one the arguments reach, or the implicit one; 0 for a struct's
	// parameterless one, which is not declared.
	function haxeCtor(c:TClass, params:TParams, args:Array<TExpr>):{token:Int, args:Array<IlSigNorm>, owner:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		var plan = g.planOf.get(c);
		if (plan == null) throw "internal error: no plan for " + Globals.sTypePath(c.path);
		var inst = g.types.classArgs(c, params);
		var owner = DotnetCtx.instanceOf(plan, inst);
		var m:Null<MethodPlan> = null;
		if (plan.ctors != null) {
			// gencs's model: the class's own constructor, or one cloned from an ancestor's, that the
			// arguments reach.
			var origin = null;
			if (TypeFunctions.hasConstructor(c)) {
				var r = OverloadResolution.maybeResolveConstructorOverload(c, params, args);
				if (r == null) throw "internal error: no constructor of " + Globals.sTypePath(c.path) + " fits";
				origin = r.cf;
			}
			m = TclassToIl.ctorOf(plan, origin).real;
		} else if (c.constructor == null || TypeFunctions.hasClassFieldFlag(c.constructor, CfExtern)) {
			for (x in plan.methods) if (x.name == ".ctor") m = x;
		} else {
			var r = OverloadResolution.maybeResolveConstructorOverload(c, params, args);
			m = g.methodPlans.get(r == null ? c.constructor : r.cf);
		}
		if (m == null) return {token: 0, args: [], owner: owner};
		// A generic class's constructor is a MemberRef on the instantiation.
		var token = plan.classParams.length == 0 ? m.token : g.mb.memberRef(g.typeTokenOf(owner), ".ctor", g.sigs.method(true, LVoid, m.args, 0));
		return {token: token, args: [for (a in m.args) DotnetTypes.substitute(a, inst, [])], owner: owner};
	}

	// super(...): the base class's constructor on `this`; in a static constructor, the base class's
	// static constructor on `__hx_this`.
	function superCtorCall(args:Array<TExpr>):Void {
		var s = tl.cls == null ? null : tl.cls.superClass;
		if (s == null || tl.thisSig == null) throw new Unsupported("`super` calls", true);
		if (tl.splitCtor) {
			g.types.checkKept(TClassDecl(s.c));
			var plan = g.planOf.get(s.c);
			var r = OverloadResolution.maybeResolveConstructorOverload(s.c, s.params, args);
			if (r == null) throw "internal error: no constructor of " + Globals.sTypePath(s.c.path) + " fits";
			var stat = TclassToIl.ctorOf(plan, r.cf).stat;
			var margs = g.types.classArgs(s.c, s.params);
			code.ldarg(0);
			pushArgs(args, [for (i in 1...stat.args.length) DotnetTypes.substitute(stat.args[i], [], margs)], ctorTargets(s.c, s.params, args));
			code.opToken(IlOps.CALL, TclassToIl.staticCtorRef(g, plan, stat, margs), args.length + 1, 0);
			return;
		}
		if (isExtern(s.c)) {
			code.ldarg(0);
			var ctor = externCtor(s.c, s.params, args);
			code.opToken(IlOps.CALL, ctor.token, ctor.argc + 1, 0);
			return;
		}
		var ctor = haxeCtor(s.c, s.params, args);
		if (ctor.token == 0) throw "internal error: no constructor of " + Globals.sTypePath(s.c.path);
		code.ldarg(0);
		pushArgs(args, ctor.args, ctorTargets(s.c, s.params, args));
		code.opToken(IlOps.CALL, ctor.token, args.length + 1, 0);
	}

	function construct(ret:Ret, c:TClass, params:TParams, args:Array<TExpr>):Void {
		if (isStringClass(c)) {
			// new String(s) is s.
			if (args.length != 1) throw new Unsupported("this String constructor", false);
			tl.texpr(RValue(LString), args[0]);
			tl.coerce(LString, ret);
			return;
		}
		if (isNativeArrayClass(c)) {
			// new NativeArray<T>(n): newarr.
			if (args.length != 1) throw "internal error: NativeArray takes one argument";
			var elem = tl.sig(params[0]);
			// Where the array becomes an erased instantiation's storage, as hxcs's inlined Array.alloc makes
			// it for map (`new Array<object>((object[]) new object[n])` in gencs's C#), it is an object[]:
			// gencs erases the inlined method's type parameter there. A NativeArray<C> made for itself stays
			// a C[].
			switch (ret) {
				case RValue(LVector(LObject)) if (!elem.match(LObject)): elem = LObject;
				case _:
			}
			tl.texpr(RValue(LInt32), args[0]);
			code.opToken(IlOps.NEWARR, g.typeTokenOf(elem), 1, 1);
			tl.coerce(LVector(elem), ret);
			return;
		}
		if (isExtern(c)) {
			var zero = args.length == 0 ? g.externs.structDefault(c, g.types.classArgs(c, params)) : null;
			if (zero != null) {
				zeroed(zero);
				tl.coerce(zero, ret);
				return;
			}
			var ctor = externCtor(c, params, args);
			code.opToken(IlOps.NEWOBJ, ctor.token, ctor.argc, 1);
			tl.coerce(ctor.parent, ret);
			return;
		}
		var ctor = haxeCtor(c, params, args);
		var t = ctor.owner;
		if (ctor.token == 0) {
			// A struct without a constructor that takes arguments: a zeroed value.
			if (!DotnetTypes.isValueType(t) || args.length > 0) throw "internal error: no constructor of " + Globals.sTypePath(c.path);
			zeroed(t);
		} else {
			pushArgs(args, ctor.args, ctorTargets(c, params, args));
			code.opToken(IlOps.NEWOBJ, ctor.token, args.length, 1);
		}
		tl.coerce(t, ret);
	}

	function zeroed(t:IlSigNorm):Void {
		var tmp = code.addLocal(t);
		code.ldloca(tmp);
		code.opToken(IlOps.INITOBJ, g.typeTokenOf(t), 1, 0);
		code.ldloc(tmp);
	}

	static function isNativeArrayClass(c:TClass):Bool {
		return c.path.name == "NativeArray" && c.path.pack.length == 1 && c.path.pack[0] == "cs";
	}

	static function isNativeArray(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, [_]): isNativeArrayClass(c);
			case _: false;
		}
	}

	// The standard library's Array class and its type arguments, when `t` is an Array.
	static function arrayOf(t:T):Null<{c:TClass, params:TParams}> {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, params) if (c.path.pack.length == 0 && c.path.name == "Array" && !isExtern(c)): {c: c, params: params};
			case _: null;
		}
	}

	static function vectorElement(s:IlSigNorm):IlSigNorm {
		return switch (s) {
			case LVector(t): t;
			case _: throw "internal error: not a native array: " + s;
		}
	}

	// An index is an Int, or a UInt, which is the same int32 on the stack.
	function indexSig(e:TExpr):IlSigNorm {
		var s = tl.sig(e.type);
		return isIntLike(s) ? s : LInt32;
	}

	// Array's __get or __set on an Array of type `t`.
	function arrayAccessor(t:T, name:String):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm, owner:IlSigNorm} {
		var a = arrayOf(t);
		var cf = a.c.fields.get(name);
		if (cf == null) throw new Unsupported("Array." + name, false);
		return haxeMethod(a.c, a.params, cf, [], cf.type);
	}

	// The type of the native array `e` as it is read. A variable of a generic Haxe class holds the array
	// of its erased instantiation, whatever the access's Haxe type says: Array<C>'s __a, inlined from
	// hxcs's Array, is an object[], whose elements convert as they are read, as in gencs's C#.
	function vectorSig(e:TExpr):IlSigNorm {
		switch (strip(e).expr) {
			case TField(_, FInstance(c, params, cf)) if (!isExtern(c) && cf.kind.match(Var(_)) && !g.varProperties.exists(cf)):
				var s = try instanceField(c, params, cf).sig catch (_:Unsupported) null;
				if (s != null && s.match(LVector(_))) return s;
			case _:
		}
		return tl.sig(e.type);
	}

	// Whether `e1[i]` is reached through Runtime.callField's "__get" and "__set", as gencs reaches an element
	// of a Dynamic. An Array<Dynamic>, whose type is Array's companion interface, has gencs's companion indexer
	// (isCompanionArrayAccess).
	function isDynamicArrayAccess(e1:TExpr):Bool {
		if (isNativeArray(e1.type)) return false;
		return arrayOf(e1.type) == null && TexprDynamic.isDynamic(e1.type);
	}

	// Whether `e1[i]` goes through the indexer of a companion interface, gencs's `object this[int key]`
	// (IndexerToIl): `e1` is an Array<Dynamic>, or another Dynamic instantiation of an hxgeneric class with
	// array access. gencs reads, writes and increments the element through it, and reaches it with
	// Runtime.callField's "__get" and "__set" for `op=` (TexprDynamic.compound).
	function isCompanionArrayAccess(e1:TExpr):Bool {
		if (isNativeArray(e1.type) || !g.types.isCompanionTyped(e1.type)) return false;
		return switch (TypeFunctions.follow(e1.type)) {
			case TInst(c, _): arrayAccessClass(c) != null;
			case _: false;
		}
	}

	// The nearest class, `c` or a superclass that is no extern, that implements ArrayAccess.
	static function arrayAccessClass(c:TClass):Null<TClass> {
		var cur = c;
		while (cur != null && !isExtern(cur)) {
			if (cur.arrayAccess != null) return cur;
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return null;
	}

	// A read of `c[i]` whose class `c` (or the class `aa` up its chain that implements ArrayAccess) has no
	// __get: one dead code elimination removed, or none at all.
	function noGet(c:TClass, aa:TClass):Unsupported {
		var cur = c;
		while (cur != null) {
			var n = DotnetTypes.haxePath(TClassDecl(cur));
			if (g.ctx.dceRemovedFields.exists(Globals.sTypePath(cur.path) + ".__get"))
				return Unsupported.error("a[i] on " + n + " needs " + n + ".__get, which dead code elimination removed: mark it @:keep");
			if (cur == aa) break;
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return Unsupported.error(DotnetTypes.haxePath(TClassDecl(c)) + " has no __get: a[i] on it cannot be read");
	}

	static function noSet(c:TClass):Unsupported {
		return Unsupported.error(DotnetTypes.haxePath(TClassDecl(c)) + " has no __set: a[i] on it cannot be assigned");
	}

	// The indexer gencs gives a Haxe class with __get and __set (IndexerToIl) that `e1[i]` goes through, for an
	// access that `reads` or `writes`: on a value typed as a companion interface the companion's, else for
	// each accessor the one of the nearest class up from `e1`'s that declares it (a subclass that overrides
	// only __get has a get-only indexer, whose class's base class's setter a store calls, where gencs's C#
	// fails with CS0200). Null when `e1` is no Haxe class with array access (Array has its own lowering);
	// an access whose accessor DCE removed, or that has none, is refused, as gencs's C# fails.
	function haxeIndexer(e1:TExpr, reads:Bool, writes:Bool):Null<NetIndexer> {
		if (isNativeArray(e1.type)) return null;
		var rc:TClass, params:Array<T>;
		switch (TypeFunctions.follow(e1.type)) {
			case TInst(c, p) if (!c.kind.match(KTypeParameter(_)) && !isExtern(c)):
				rc = c;
				params = p;
			case _:
				return null;
		}
		var aa = arrayAccessClass(rc);
		if (aa == null) return null;
		if (g.types.isCompanionTyped(e1.type)) return companionIndexer(rc, aa, reads, writes);
		if (arrayOf(e1.type) != null) return null;
		var getAt:Null<{owner:IlSigNorm, inst:Array<IlSigNorm>, plan:ClassPlan, m:MethodPlan, depth:Int}> = null, setAt = null;
		var cur = rc, args = params, depth = 0;
		while (cur != null) {
			// A .NET base class's indexer, which no Haxe class below it hides, is TexprCalls.netIndexer's.
			if (isExtern(cur)) {
				if (getAt == null && setAt == null) return null;
				break;
			}
			var plan = g.planOf.get(cur);
			if (plan != null) for (p in plan.properties) if (p.name == IndexerToIl.itemName && p.index.length == 1 && isIntLike(p.index[0])) {
				var inst = g.types.classArgs(cur, args);
				var owner = DotnetCtx.instanceOf(plan, inst);
				if (getAt == null && p.getter != null) getAt = {owner: owner, inst: inst, plan: plan, m: p.getter, depth: depth};
				if (setAt == null && p.setter != null) setAt = {owner: owner, inst: inst, plan: plan, m: p.setter, depth: depth};
			}
			var sup = cur.superClass;
			if (sup == null) break;
			var cparams = cur.params, cargs = args;
			args = [for (p in sup.params) TypeFunctions.applyParams(cparams, cargs, p)];
			cur = sup.c;
			depth++;
		}
		if (reads && getAt == null) throw noGet(rc, aa);
		if (writes && setAt == null) throw noSet(rc);
		var getValue = getAt == null ? null : DotnetTypes.substitute(getAt.m.ret, getAt.inst, []);
		var setValue = setAt == null ? null : DotnetTypes.substitute(setAt.m.args[1], setAt.inst, []);
		if (reads && writes && !IlPaths.sigEq(getValue, setValue))
			throw new Unsupported("read-modify-write through indexers of different element types", false);
		var main = !reads ? setAt : !writes ? getAt : getAt.depth <= setAt.depth ? getAt : setAt;
		return {
			parent: main.owner,
			index: DotnetTypes.substitute(main.m.args[0], main.inst, []),
			value: reads ? getValue : setValue,
			isStruct: DotnetTypes.isValueType(main.owner),
			getToken: () -> g.methodOf(getAt.plan, getAt.owner, getAt.m),
			setToken: () -> g.methodOf(setAt.plan, setAt.owner, setAt.m)
		};
	}

	// The indexer of the companion interface of `c` or of the nearest generic superclass whose companion has
	// one, `object this[int key]` (IndexerToIl.companionMembers); `aa` is the class with array access.
	function companionIndexer(c:TClass, aa:TClass, reads:Bool, writes:Bool):NetIndexer {
		var cur = c;
		var found:Null<{sig:IlSigNorm, p:PropertyPlan}> = null;
		while (cur != null && found == null && !isExtern(cur) && g.hasCompanion(cur)) {
			var cp = g.companionPlans.get(cur);
			if (cp != null) for (p in cp.properties) if (p.name == IndexerToIl.itemName) found = {sig: CompanionToIl.companionSig(cur), p: p};
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		if (found == null) {
			if (aa.fields.get("__get") == null) throw noGet(c, aa);
			throw new Unsupported("a[i] through a Dynamic instantiation of a class whose indexer its companion interface does not declare", false);
		}
		var p = found.p;
		if (reads && p.getter == null) throw noGet(c, aa);
		if (writes && p.setter == null) throw noSet(c);
		return {
			parent: found.sig,
			index: LInt32,
			value: p.sig,
			isStruct: false,
			getToken: () -> p.getter.token,
			setToken: () -> p.setter.token
		};
	}

	// Whether `e` is a native array field read through Runtime from a value typed as a companion interface,
	// such as hxcs's Array `__a` in the inlined map and filter on an Array<Dynamic>: its CLR type depends on
	// the object's instantiation (an int[] for an Array<Int> held as an Array<Dynamic>), so its elements are
	// reached through System.Array's GetValue and SetValue. gencs casts it to object[], which throws for an
	// int[] (types notes §5); decision 4 of plan 3c keeps hxc's working.
	function isDynamicVector(e:TExpr):Bool {
		return isNativeArray(e.type) && switch (strip(e).expr) {
			case TField(obj, fa = FInstance(_, _, _)): tl.dyn.companionReceiver(obj) && tl.dyn.isDynamicReceiver(fa, obj);
			case _: false;
		}
	}

	static final systemArray:IlSigNorm = LClass({ns: ["System"], nested: [], name: "Array"}, []);

	// Pushes the native array `e1` (isDynamicVector), read with Runtime.getField and not converted to its
	// Haxe type, as a System.Array, then the index `e2` as an Int.
	function pushDynamicVector(e1:TExpr, e2:TExpr):Void {
		switch (strip(e1).expr) {
			case TField(obj, fa):
				tl.dyn.fieldHead(obj, TexprDynamic.fieldName(fa));
				code.ldcI4(1);
				tl.dyn.runtimeCall("getField", LObject);
			case _:
				throw "internal error: not a field read";
		}
		code.opToken(IlOps.CASTCLASS, g.typeTokenOf(systemArray), 1, 1);
		tl.nullOperand(RValue(LInt32), e2, false);
	}

	// System.Array's GetValue(int) or SetValue(object, int) on what is on the stack.
	function callArrayValue(set:Bool):Void {
		var token = g.mb.memberRef(g.typeTokenOf(systemArray), set ? "SetValue" : "GetValue",
			g.sigs.method(true, set ? LVoid : LObject, set ? [LObject, LInt32] : [LInt32], 0));
		code.opToken(IlOps.CALLVIRT, token, set ? 3 : 2, set ? 0 : 1);
	}

	// Pushes a native array and an index into it; returns the element type.
	function pushArrayAndIndex(e1:TExpr, e2:TExpr):IlSigNorm {
		var vec = vectorSig(e1);
		tl.texpr(RValue(vec), e1);
		tl.nullOperand(RValue(indexSig(e2)), e2, false);
		return vectorElement(vec);
	}

	// The extern class with a .NET type that `e1[i]` is an indexer of, with its type arguments: the class of
	// `e1`'s type, or the nearest superclass of a Haxe class that is one. Null for any other array access.
	function indexerClass(e1:TExpr):Null<{c:TClass, params:Array<T>, recv:TClass}> {
		var rc:TClass, params:Array<T>, recv:TClass;
		switch (TypeFunctions.follow(e1.type)) {
			case TInst(c, p) if (!c.kind.match(KTypeParameter(_))):
				rc = recv = c;
				params = p;
			case _:
				return null;
		}
		while (!(isExtern(rc) && hasNetType(rc))) {
			var sup = rc.superClass;
			if (sup == null) return null;
			var cparams = rc.params, args = params;
			params = [for (p in sup.params) TypeFunctions.applyParams(cparams, args, p)];
			rc = sup.c;
		}
		return {c: rc, params: params, recv: recv};
	}

	// Whether `e1[i]` is a .NET class's indexer (values notes §3): get_Item and set_Item.
	function isNetIndexer(e1:TExpr, e2:TExpr):Bool {
		var r = indexerClass(e1);
		return r != null && g.externs.indexer(r.c, r.params, tl.cls, r.recv, e2) != null;
	}

	// Refuses a read-modify-write through the indexer of a .NET struct, whose receiver would have to be kept
	// as an address across the load and the store.
	function refuseStructIndexer(e1:TExpr, e2:TExpr):Void {
		var r = indexerClass(e1);
		var ix = r == null ? null : g.externs.indexer(r.c, r.params, tl.cls, r.recv, e2);
		if (ix != null && DotnetTypes.isValueType(ix.parent))
			throw new Unsupported("read-modify-write through an indexer of a .NET struct", false);
	}

	// The indexer of `e1`'s class for the index `e2`, for an access to an element of the Haxe type `element` that
	// `reads` or `writes`.
	function netIndexer(e1:TExpr, e2:TExpr, element:T, reads:Bool, writes:Bool):NetIndexer {
		var r = indexerClass(e1);
		var ix = r == null ? null : g.externs.indexer(r.c, r.params, tl.cls, r.recv, e2);
		if (ix == null) throw "internal error: not a .NET indexer";
		var args = switch (ix.parent) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		var index = ExternMembers.subst(ix.indexSig, args), value = ExternMembers.subst(ix.valueSig, args);
		// A converted extern's element is Dynamic, or the type of its first one-parameter property, which need not
		// be the bound indexer's; a hand-written one's is as it declares it.
		if (!TexprDynamic.isDynamic(element)) g.externs.checkIndexerElement(r.c, value, tl.sig(element), reads, writes);
		var what = ExternMembers.sigS(ix.parent);
		return {
			parent: ix.parent,
			index: index,
			value: value,
			isStruct: DotnetTypes.isValueType(ix.parent),
			getToken: () -> {
				if (ix.getter == null) throw Unsupported.error("the .NET indexer of " + what + " has no public getter");
				return g.mb.memberRef(g.typeTokenOf(ix.parent), ix.getter, g.sigs.method(true, ix.valueSig, [ix.indexSig], 0));
			},
			setToken: () -> {
				if (ix.setter == null) throw Unsupported.error("the .NET indexer of " + what + " has no public setter");
				return g.mb.memberRef(g.typeTokenOf(ix.parent), ix.setter, g.sigs.method(true, LVoid, [ix.indexSig, ix.valueSig], 0));
			}
		};
	}

	// a[i]: ldelem on a native array, Array's __get on an Array, get_Item on a .NET class's indexer, on the
	// indexer of a Haxe class with __get or of a companion interface (an Array<Dynamic>'s), and on a Dynamic
	// gencs's Runtime.callField(a, "__get", hash, new object[]{i}).
	function arrayRead(ret:Ret, e:TExpr, e1:TExpr, e2:TExpr):Void {
		if (tl.sig(e1.type).match(LString)) {
			// s[i] on a String is C#'s indexer, a Char16.
			tl.texpr(RValue(LString), e1);
			tl.nullOperand(RValue(indexSig(e2)), e2, false);
			callString("get_Chars", LChar, [LInt32]);
			tl.coerce(LChar, ret);
			return;
		}
		if (isDynamicVector(e1)) {
			pushDynamicVector(e1, e2);
			callArrayValue(false);
			tl.coerce(LObject, ret);
			return;
		}
		if (isNativeArray(e1.type)) {
			var elem = pushArrayAndIndex(e1, e2);
			code.ldelem(elem, () -> g.typeTokenOf(elem));
			tl.coerce(elem, ret);
			return;
		}
		if (isDynamicArrayAccess(e1)) {
			tl.dyn.fieldCall(ret, e, e1, "__get", [e2]);
			return;
		}
		var hx = haxeIndexer(e1, true, false);
		if (hx != null) {
			// get_Item: the companion's `object this[int key]`, or a Haxe class's indexer.
			var get = hx.getToken();
			receiver(e1, hx.parent);
			tl.nullOperand(RValue(hx.index), e2, false);
			code.opToken(hx.isStruct ? IlOps.CALL : IlOps.CALLVIRT, get, 2, 1);
			tl.coerce(hx.value, ret);
			return;
		}
		if (isNetIndexer(e1, e2)) {
			var ix = netIndexer(e1, e2, e.type, true, false);
			var get = ix.getToken();
			receiver(e1, ix.parent);
			tl.nullOperand(RValue(ix.index), e2, false);
			code.opToken(ix.isStruct ? IlOps.CALL : IlOps.CALLVIRT, get, 2, 1);
			// A converted extern's element is Dynamic: gencs reads a struct or Nullable element as an object, which
			// Runtime converts to what is wanted.
			var viaObject = switch (ret) {
				case RValue(to) if (to != null && TexprDynamic.isDynamic(e.type) && ix.value.match(LValueType(_, _))):
					!IlPaths.sigEq(to, ix.value);
				case _:
					false;
			}
			if (viaObject) tl.coerce(ix.value, RValue(LObject));
			tl.coerce(viaObject ? LObject : ix.value, ret);
			return;
		}
		if (arrayOf(e1.type) == null) throw new Unsupported("array access", false);
		var m = arrayAccessor(e1.type, "__get");
		receiver(e1, m.owner);
		tl.nullOperand(RValue(m.args[0]), e2, false);
		code.opToken(IlOps.CALLVIRT, m.token, 2, 1);
		tl.coerce(m.ret, ret);
	}

	// [e1, e2]: a native array filled with stelem, then new Array<T>(native).
	function arrayLiteral(ret:Ret, e:TExpr, el:Array<TExpr>):Void {
		var a = arrayOf(e.type);
		if (a == null) throw new Unsupported("array literals", true);
		g.types.checkKept(TClassDecl(a.c));
		var plan = g.planOf.get(a.c);
		var elem = g.types.classArgs(a.c, a.params)[0];
		var owner = DotnetCtx.instanceOf(plan, [elem]);
		var ctor = null;
		for (m in plan.methods) if (m.name == ".ctor" && m.args.length == 1 && IlPaths.sigEq(m.args[0], LVector(LTypeParam(0)))) ctor = m;
		if (ctor == null) throw "internal error: Array has no constructor from a native array";
		var elemToken = g.typeTokenOf(elem);
		code.ldcI4(el.length);
		code.opToken(IlOps.NEWARR, elemToken, 1, 1);
		for (i in 0...el.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			tl.texprStore(elem, a.params[0], el[i]);
			code.stelem(elem, () -> elemToken);
		}
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(owner), ".ctor", g.sigs.method(true, LVoid, ctor.args, 0)), 1, 1);
		tl.coerce(owner, ret);
	}
}
