package hxc.codegen.dotnet;

import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.CsSyntax;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.ExternMembers;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.TexprToIl.Ret;
import hxc.codegen.dotnet.TexprToIl.isTypeParam;
import hxc.codegen.dotnet.TexprToIl.isReference;
import hxc.codegen.dotnet.TexprToIl.isNullConst;
import hxc.codegen.dotnet.TexprToIl.strip;

// What a name in inline C# is: a type (a static receiver or a cast target), a namespace, or a value it has
// already pushed (as its address, for a member access on a value type).
enum CsValue {
	VType(t:IlSigNorm);
	VNamespace(path:Array<String>);
	VPushed(t:IlSigNorm);
	// The address of a value of the value type `t`, pushed: a member access's receiver.
	VAddress(t:IlSigNorm);
}

// These hold a 64-bit integer, so they are classes: a number in an anonymous structure is a double on the
// C# target, which keeps 53 bits of it.

// A constant of an integer or real type, as C# checks them at compile time: an integer's value in `i` (a
// ulong's as its bits), a real's in `f`.
@:structInit private class CsConst {
	public var t:IlSigNorm;
	public var i:haxe.Int64;
	public var f:Float;
}

// A decimal constant: `mantissa` (non-negative) / 10^scale, negated when `negative`.
@:structInit private class DecimalConst {
	public var mantissa:haxe.Int64;
	public var negative:Bool;
	public var scale:Int;
}

// A C# integer literal's value and type (intLiteral).
@:structInit private class CsIntLiteral {
	public var v:haxe.Int64;
	public var t:IlSigNorm;
}

// A quotient and a remainder (udivMod).
@:structInit private class DivMod {
	public var q:haxe.Int64;
	public var r:haxe.Int64;
}

// A call's argument, pushed: its type (null for the null literal), its kind, and for a placeholder the Haxe
// type of its argument (ruling 7's refusal reads it).
private typedef CsArg = {t:Null<IlSigNorm>, kind:ArgKind, ?hx:T};

// Inline C# (`untyped __cs__`, `cs.Syntax.code`, `cs.Syntax.plainCode`) as IL: CsSyntax's expression, its
// names resolved over CLR types and lowered with C#'s semantics (csexpr §6). Shares its state through the
// TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprCalls, hxc.codegen.dotnet.CsNames)
class CsToIl {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final il:IlCode;
	// The type names of the text (CsNames).
	final names:CsNames;

	// The call being lowered: its placeholders' arguments, its position (where errors go) and the position of
	// its code string (where gencs puts a placeholder's error).
	var args:Array<TExpr> = [];
	var pos:Position = Position.nullPos;
	var textPos:Position = Position.nullPos;

	static final decimal:IlSigNorm = LValueType({ns: ["System"], nested: [], name: "Decimal"}, []);

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		il = tl.code;
		names = new CsNames(this);
	}

	// The code string of an inline C# call, which must be a constant (gencs's error, at the argument).
	public static function constantText(e:TExpr):String {
		return switch (strip(e).expr) {
			case TConst(TString(s)): s;
			case _: throw Unsupported.haxeError("The `code` argument for cs.Syntax.code must be a string constant", e.pos);
		}
	}

	// A Haxe method inline C# calls directly: a normal one, or an inline one with a body (not extern). A dynamic
	// method is a variable's value.
	public static function directMethod(c:TClass, cf:TClassField):Bool {
		return switch (cf.kind) {
			case Method(MethNormal): true;
			case Method(MethInline): !TypeFunctions.hasClassFieldFlag(cf, CfExtern) && !TypeFunctions.hasClassFlag(c, CExtern);
			case _: false;
		}
	}

	public static function isSyntaxClass(c:TClass):Bool return c.path.pack.length == 1 && c.path.pack[0] == "cs" && c.path.name == "Syntax";

	// The inline C# call `e`, whose code string is `text` and whose placeholders' arguments are `args`,
	// where `ret` wants it. `isUntyped`: `untyped __cs__`, whose value takes the type it is used as through
	// C#'s implicit conversions; cs.Syntax's is a Dynamic, converted as gencs converts one (plan ruling 3).
	public function code(ret:Ret, e:TExpr, text:String, args:Array<TExpr>, isUntyped:Bool, pos:Position):Void {
		// A placeholder's argument may hold inline C# of its own.
		var outer = {args: this.args, pos: this.pos, textPos: this.textPos};
		function restore() {
			this.args = outer.args;
			this.pos = outer.pos;
			this.textPos = outer.textPos;
		}
		this.args = args;
		this.pos = pos;
		try {
			lower(ret, e, text, isUntyped);
		} catch (x:Dynamic) {
			restore();
			// What the lookup refuses (ExternMembers, NetRefs) is reported at the call.
			if (Std.isOfType(x, Unsupported)) {
				var u:Unsupported = x;
				if (u.pos == null) u.pos = pos;
			}
			throw x;
		}
		restore();
	}

	function lower(ret:Ret, e:TExpr, text:String, isUntyped:Bool):Void {
		var plain = false;
		textPos = pos;
		switch (strip(e).expr) {
			case TCall(callee, all):
				textPos = all[0].pos;
				plain = switch (strip(callee).expr) {
					case TField(_, FStatic(_, cf)): cf.name == "plainCode";
					case _: false;
				}
			case _:
		}
		switch (CsSyntax.parse(text, !plain)) {
			case PThrow:
				if (ret.match(RValue(_))) error("a bare `throw` in inline C# has no value");
				tl.flow.rethrow(pos);
			case PRefused("statements", replacement, _):
				error("inline C# must be one expression or a bare `throw`; " + replacement);
			case PRefused(what, replacement, _):
				var plural = StringTools.endsWith(what, "arguments") || what == "pointers";
				error(what + (plural ? " are" : " is") + " not part of the inline C# subset; " + replacement);
			case PError(reason, _):
				error("inline C# does not parse: " + reason);
			case PExpr(x):
				// gencs reports the first out-of-bounds placeholder whatever the text holds before it.
				for (ph in CsSyntax.placeholdersOf(x)) switch (ph.def) {
					case CPlaceholder(n) if (n >= args.length): outOfBounds(n, ph);
					case _:
				}
				var t = value(x);
				switch (ret) {
					case RVoid | RReturn:
						if (t == null || !t.match(LVoid)) il.op(IlOps.POP, 1, 0);
					case RValue(want):
						if (t != null && t.match(LVoid)) error("the inline C# expression has no value (C# error CS0029)");
						var target = want != null ? want : tl.sig(e.type);
						if (isUntyped && constantConverts(x, target)) tl.convert(t, target) else convertResult(t, target, !isUntyped, e.type);
				}
		}
	}

	function error(what:String):Dynamic {
		var u = Unsupported.error(what);
		u.pos = pos;
		throw u;
	}

	// The value of type `cs` on the stack as the `target` of the call's Haxe type `haxeType`. `castLike`
	// (cs.Syntax): as gencs converts a Dynamic, Runtime.toInt, toDouble, toBool and toString of the boxed
	// value, ofDynamic and genericCast too, and C#'s explicit cast to any other type. Otherwise C#'s implicit
	// conversions only, as gencs writes the C# with no conversion around it.
	function convertResult(cs:Null<IlSigNorm>, target:IlSigNorm, castLike:Bool, haxeType:T):Void {
		if (castLike) {
			if (fromDynamic(target)) {
				box(cs);
				tl.convert(LObject, target);
			} else {
				explicitCast(cs, target);
			}
			return;
		}
		if (cs == null) {
			if (isTypeParam(target)) {
				var name = hxc.core.TPrinting.sTypeStr(haxeType);
				error("the inline C# expression is null, which does not convert to the type parameter " + name.substr(name.lastIndexOf(".") + 1)
					+ " (C# error CS0403); use default(T)");
			}
			if (DotnetTypes.isValueType(target)) error("the inline C# expression is null, which does not convert to "
				+ hxc.core.TPrinting.sTypeStr(haxeType) + " (C# error CS0037)");
			return;
		}
		if (!g.externs.implicitlyConverts(cs, target)) {
			userConversionError(cs, target, false);
			var explicit = explicitlyConverts(cs, target);
			error("the inline C# expression is " + article(csName(cs)) + ", which does not convert to " + hxc.core.TPrinting.sTypeStr(haxeType)
				+ " implicitly (C# error " + (explicit ? "CS0266); add a cast in the C# text" : "CS0029)"));
		}
		tl.convert(cs, target);
	}

	// The types gencs converts a Dynamic to through the runtime (TexprDynamic.toSig): the Haxe numbers, Bool
	// and String, a type parameter, a haxe.lang.Null<T> and Dynamic itself.
	function fromDynamic(s:IlSigNorm):Bool {
		return s.match(LInt32 | LUInt32 | LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LFloat64 | LFloat32 | LBool | LString | LObject)
			|| isTypeParam(s) || tl.isHaxeNull(s);
	}

	// Whether C# has an explicit conversion from `from` to `to` (CS0266 rather than CS0029 where it has no
	// implicit one, CS0030 in a cast): between numbers, boxing, unboxing and between references.
	function explicitlyConverts(from:IlSigNorm, to:IlSigNorm):Bool {
		if (IlPaths.sigEq(from, to) || isNumber(from) && isNumber(to)) return true;
		var fromEnum = enumUnderlying(from), toEnum = enumUnderlying(to);
		if ((fromEnum != null || toEnum != null) && isNumber(fromEnum != null ? fromEnum : from) && isNumber(toEnum != null ? toEnum : to)) return true;
		return boxes(from, to) || unboxes(from, to) || referenceConverts(from, to);
	}

	static function isValue(s:IlSigNorm):Bool return DotnetTypes.isValueType(s) || isTypeParam(s);

	static function isSystemNamed(s:IlSigNorm, name:String):Bool {
		return switch (s) {
			case LClass(p, []): p.nested.length == 0 && p.name == name && p.ns.length == 1 && p.ns[0] == "System";
			case _: false;
		}
	}

	// Boxing: a value type (or type parameter) to object or to a reference type it converts to implicitly
	// (System.ValueType, an interface it implements); a type parameter to any interface.
	function boxes(from:IlSigNorm, to:IlSigNorm):Bool {
		if (!isValue(from) || isValue(to)) return false;
		return to.match(LObject) || isReference(to) && (g.externs.implicitlyConverts(from, to) || isTypeParam(from) && g.externs.isInterface(to));
	}

	// Unboxing to the value type (or type parameter) `to`: only from object, System.ValueType, System.Enum or
	// an interface; from any other reference type it is C# error CS0030.
	function unboxes(from:IlSigNorm, to:IlSigNorm):Bool {
		return isValue(to) && (from.match(LObject) || isSystemNamed(from, "ValueType") || isSystemNamed(from, "Enum")
			|| isReference(from) && g.externs.isInterface(from));
	}

	// C#'s reference conversions, implicit or explicit: an upcast, a downcast, from or to object, to or from an
	// interface (but not for string, which is sealed, or an array beyond the upcasts), and between arrays of
	// references that convert so.
	function referenceConverts(from:IlSigNorm, to:IlSigNorm):Bool {
		if (!isReference(from) || !isReference(to)) return false;
		if (from.match(LObject) || to.match(LObject)) return true;
		inline function upcast(a:IlSigNorm, b:IlSigNorm) return g.isUpcast(a, b) || g.externs.implicitlyConverts(a, b);
		if (upcast(from, to) || upcast(to, from)) return true;
		switch [from, to] {
			case [LVector(a), LVector(b)]: return isReference(a) && isReference(b) && referenceConverts(a, b);
			case _:
		}
		if (from.match(LString | LVector(_) | LArray(_, _)) || to.match(LString | LVector(_) | LArray(_, _))) return false;
		return g.externs.isInterface(from) || g.externs.isInterface(to);
	}

	// ---- names (csexpr §6.2)

	// What a name in the C# text is: a type or namespace, as C# looks the name up, else the value of a member
	// of a type or of a value, a call, an indexer or `new`, pushed. A simple name that is neither is unknown
	// (the typer lifts the Haxe names the text uses into placeholders).
	function resolveName(x:CsExpr):CsValue {
		var tn = names.typeOrNamespace(x);
		if (tn != null) return tn;
		return switch (x.def) {
			case CIdent(name): unknownName(name, "CS0103");
			case CGlobal(name): unknownName("global::" + name, "CS0400");
			case CThis: unknownName("this", "CS0103");
			case CMember(e1, name): VPushed(memberGet(e1, name));
			case CCall(callee, args): VPushed(call(callee, args));
			case CIndex(e1, args): VPushed(index(e1, args));
			case CNew(t, args): VPushed(newObject(t, args));
			case _: VPushed(value(x));
		}
	}

	function unknownName(name:String, csError:String):Dynamic {
		return error("the inline C# name " + name + " is no local, member or type here (C# error " + csError + ")");
	}

	// ---- members (csexpr §6.2, §6.3)

	// The program's class a type is, or null for a .NET type.
	function programClass(s:Null<IlSigNorm>):Null<TClass> {
		return switch (s) {
			case LClass(p, _) | LValueType(p, _): g.externs.compiledClass(p);
			case _: null;
		}
	}

	// The receiver of a member access `e1.m`: a type or a namespace, or the value of `e1` pushed. A value of a
	// value type goes as its address (VAddress), as C# reaches a member through a variable: the variable's own
	// for a placeholder whose argument is one, else a temporary's (a call's result, say).
	function receiver(e1:CsExpr):CsValue {
		var tn = names.typeOrNamespace(e1);
		if (tn != null) return tn;
		switch (e1.def) {
			case CPlaceholder(n) if (n < args.length):
				var a = args[n];
				var t = tl.sig(a.type);
				if (DotnetTypes.isValueType(t) && !tl.isHaxeNull(t) && tl.calls.pushAddress(a, false)) return VAddress(t);
			case _:
		}
		return switch (resolveName(e1)) {
			case VPushed(t) if (t != null && DotnetTypes.isValueType(t)):
				var tmp = il.addLocal(t);
				il.stloc(tmp);
				il.ldloca(tmp);
				VAddress(t);
			case r: r;
		}
	}

	// The type a member access's receiver `r` gives the lookup, and whether it is static (a type).
	function receiverType(r:CsValue, name:String):{t:IlSigNorm, isStatic:Bool} {
		return switch (r) {
			case VType(t): {t: t, isStatic: true};
			case VPushed(null): error("the inline C# null has no member " + name + " (C# error CS0023)");
			case VPushed(t) | VAddress(t):
				if (t.match(LVoid)) error("the inline C# expression has no value (C# error CS0029)");
				if (isTypeParam(t)) throw new Unsupported("members of a type parameter in inline C#", true);
				{t: t, isStatic: false};
			case VNamespace(path): unknownName(path.concat([name]).join("."), "CS0234");
		}
	}

	// Before an instance member of `parent` is reached through `r`: a value type's address becomes the boxed
	// value when the member is a reference type's (Object's, ValueType's or Enum's), as 4a's extern calls box it.
	// True when the member is a value type's, which is called rather than called virtually.
	function boxReceiverFor(r:CsValue, parent:IlSigNorm):Bool {
		var onValue = DotnetTypes.isValueType(parent);
		switch (r) {
			case VAddress(t) if (!onValue):
				il.opToken(IlOps.LDOBJ, g.typeTokenOf(t), 1, 1);
				il.opToken(IlOps.BOX, g.typeTokenOf(t), 1, 1);
			case _:
		}
		return onValue;
	}

	static function parentArgs(parent:IlSigNorm):Array<IlSigNorm> {
		return switch (parent) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
	}

	// Unsupported errors of the extern lookup at the call's position.
	function atPos<T>(f:Void->T):T {
		try {
			return f();
		} catch (u:Unsupported) {
			if (u.pos == null) u.pos = pos;
			throw u;
		}
	}

	// `e1.name` as a value: a field, a literal (an enum member, `int.MinValue`) as its constant, or a property
	// through its getter.
	function memberGet(e1:CsExpr, name:String):IlSigNorm {
		var r = receiver(e1);
		var rt = receiverType(r, name);
		var c = programClass(rt.t);
		if (c != null) {
			var base = netBaseFor(c, name, rt.isStatic);
			if (base == null) return programField(c, name, rt.isStatic, r);
			rt = {t: base, isStatic: rt.isStatic};
		}
		var b = atPos(() -> g.externs.memberCs(rt.t, name, rt.isStatic));
		if (b == null) {
			if (atPos(() -> g.externs.hasMethodCs(rt.t, name)))
				error("a method group is not part of the inline C# subset; call the method, or write a Haxe function");
			return unknownName(csName(rt.t) + "." + name, rt.isStatic ? "CS0117" : "CS1061");
		}
		var parent = b.parent;
		switch (b.member) {
			case XConstant(k, declared):
				// An enum's literal loads as its underlying type, which says whether it is signed.
				var under = enumUnderlying(declared);
				var s = tl.calls.constant(k, under != null ? under : declared);
				// An enum's literal is of the enum type; a null one, of its declared type.
				return s == null || !(isNumber(declared) || declared.match(LBool | LChar | LString)) ? declared : s;
			case XField(open, _):
				var token = g.mb.memberRef(g.typeTokenOf(parent), name, g.sigs.field(open));
				if (rt.isStatic) {
					il.opToken(IlOps.LDSFLD, token, 0, 1);
				} else {
					boxReceiverFor(r, parent);
					il.opToken(IlOps.LDFLD, token, 1, 1);
				}
				return ExternMembers.subst(open, parentArgs(parent));
			case XProperty(open, getter, _):
				var token = g.mb.memberRef(g.typeTokenOf(parent), getter, g.sigs.method(!rt.isStatic, open, [], 0));
				if (rt.isStatic) il.opToken(IlOps.CALL, token, 0, 1) else il.opToken(boxReceiverFor(r, parent) ? IlOps.CALL : IlOps.CALLVIRT, token, 1, 1);
				return ExternMembers.subst(open, parentArgs(parent));
		}
	}

	// The arguments of a call, pushed in order: each one's type (null for the null literal) and its kind, by
	// which C# also converts an int constant or the null literal (4a's ruling X), and a placeholder's Haxe type.
	function pushArgs(args:Array<CsExpr>):Array<CsArg> {
		return [
			for (a in args) {
				var c = constant(a);
				var t = value(a);
				if (t != null && t.match(LVoid)) error("the inline C# expression has no value (C# error CS0029)");
				{t: t, kind: t == null ? KNull : c != null && c.t.match(LInt32) ? KIntConst(c.i.low) : KPlain, hx: placeholderType(a)};
			}
		];
	}

	// The Haxe type of the argument of the placeholder `x` is, through parentheses, or null.
	function placeholderType(x:CsExpr):Null<T> {
		return switch (x.def) {
			case CParen(e1): placeholderType(e1);
			case CPlaceholder(n) if (n < args.length): args[n].type;
			case _: null;
		}
	}

	// The .NET method `name` that a call with the arguments `pushed` binds on the receiver type `t`.
	function bind(t:IlSigNorm, name:String, isStatic:Bool, pushed:Array<CsArg>):Null<CsMethod> {
		return atPos(() -> g.externs.bindCs(t, name, isStatic, [for (p in pushed) p.t == null ? LObject : p.t], [for (p in pushed) p.kind], pos,
			{caller: tl.cls, types: [for (p in pushed) p.hx]}));
	}

	static function sameSig(a:IlSigNorm, b:IlSigNorm):Bool {
		inline function norm(s:IlSigNorm) return switch (s) {
			case LClass(p, []) | LValueType(p, []):
				var prim = DotnetTypes.primitive(p);
				prim != null ? prim : s;
			case _: s;
		}
		return IlPaths.sigEq(norm(a), norm(b));
	}

	// Converts the arguments `pushed`, on the stack, to the parameter types `params` with C#'s implicit
	// conversions (which the binding checked): from the first that needs code on, they go through
	// temporaries. `fixReceiver`, which then runs with only the receiver on the stack, changes it as the member
	// needs (`boxReceiverFor`).
	function convertArgs(pushed:Array<CsArg>, params:Array<IlSigNorm>, ?fixReceiver:Void->Void):Void {
		var n = pushed.length;
		function needs(i:Int):Bool {
			var from = pushed[i].t, to = params[i];
			if (from == null) return DotnetTypes.isValueType(to);
			return !sameSig(from, to) && !(isReference(from) && isReference(to));
		}
		var k = n;
		for (i in 0...n) if (needs(i)) {
			k = i;
			break;
		}
		if (fixReceiver != null) k = 0;
		if (k == n && fixReceiver == null) return;
		var temps = [for (_ in 0...n) -1];
		var i = n - 1;
		while (i >= k) {
			temps[i] = il.addLocal(pushed[i].t == null ? LObject : pushed[i].t);
			il.stloc(temps[i]);
			i--;
		}
		if (fixReceiver != null) fixReceiver();
		for (i in k...n) {
			var from = pushed[i].t, to = params[i];
			if (from == null && DotnetTypes.isValueType(to)) {
				// The null literal to a Nullable<T>: its default.
				tl.pushDefault(to);
				continue;
			}
			il.ldloc(temps[i]);
			if (from == null || !needs(i)) continue;
			if (DotnetTypes.isSystemNullable(to)) tl.convert(from, to) else explicitCast(from, to);
		}
	}

	// A call `callee(args)`: a method of a .NET type or value bound as C# binds it, or a Haxe class's.
	function call(callee:CsExpr, args:Array<CsExpr>):IlSigNorm {
		var e1:CsExpr, name:String;
		switch (callee.def) {
			case CMember(recv, n):
				e1 = recv;
				name = n;
			case CIdent(_) | CGlobal(_) | CThis | CKeywordType(_):
				return switch (resolveName(callee)) {
					case VType(t): error("the inline C# type " + csName(t) + " is no method");
					case _: error("the inline C# namespace is no method");
				}
			case CPlaceholder(n) if (n < this.args.length):
				// The lift makes a Haxe method the text calls (`hello(fld)`, `this.b.add(s)`) a placeholder whose
				// argument is the method's field, which is called directly.
				switch (strip(this.args[n]).expr) {
					case TField(_, FStatic(c, cf)) if (directMethod(c, cf)):
						// A static call does not use its receiver.
						return programCall(c, cf.name, true, VType(LObject), args);
					case TField(e1, FInstance(c, _, cf)) if (directMethod(c, cf)):
						var t = tl.sig(e1.type);
						tl.texpr(RValue(t), e1);
						return programCall(c, cf.name, false, VPushed(t), args);
					case _:
				}
				throw new Unsupported("calls of a value (a delegate) in inline C#", true);
			case _:
				throw new Unsupported("calls of a value (a delegate) in inline C#", true);
		}
		var r = receiver(e1);
		var rt = receiverType(r, name);
		var c = programClass(rt.t);
		if (c != null) {
			var base = netBaseFor(c, name, rt.isStatic);
			if (base == null) return programCall(c, name, rt.isStatic, r, args);
			rt = {t: base, isStatic: rt.isStatic};
		}
		var pushed = pushArgs(args);
		var m = bind(rt.t, name, rt.isStatic, pushed);
		if (m == null) {
			var b = atPos(() -> g.externs.memberCs(rt.t, name, rt.isStatic));
			if (b != null) {
				var t = switch (b.member) {
					case XField(s, _) | XConstant(_, s) | XProperty(s, _, _): s;
				}
				if (!g.externs.isDelegateType(t))
					error("the .NET member " + csName(rt.t) + "." + name + " is no method or delegate, which a call cannot invoke (C# error CS1955)");
				throw new Unsupported("calls of a .NET field or property's value (a delegate) in inline C#", true);
			}
			return unknownName(csName(rt.t) + "." + name, rt.isStatic ? "CS0117" : "CS1061");
		}
		return emitCall(m, r, rt.isStatic, pushed);
	}

	// The bound .NET method `m` called (`isNew`: constructed) with the arguments `pushed`, after the receiver
	// `r` (a type for a static method or `new`).
	function emitCall(m:CsMethod, r:CsValue, isStatic:Bool, pushed:Array<CsArg>, isNew = false):IlSigNorm {
		var onValue = DotnetTypes.isValueType(m.parent);
		var fix = switch (r) {
			case VAddress(_) if (!isStatic && !isNew && !onValue): () -> boxReceiverFor(r, m.parent);
			case _: null;
		}
		convertArgs(pushed, m.params, fix);
		for (j in 0...m.omitted.length) tl.calls.pushDefault(m.omitted[j], m.params[pushed.length + j]);
		var token = g.mb.memberRef(g.typeTokenOf(m.parent), m.name, g.sigs.methodSig(m.sig, m.genericCount));
		if (m.typeArgs != null && m.typeArgs.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec(m.typeArgs));
		if (isNew) {
			il.opToken(IlOps.NEWOBJ, token, m.params.length, 1);
			return switch (r) {
				case VType(t): t;
				case _: throw "internal error: `new` without a type";
			}
		}
		var op = isStatic || onValue ? IlOps.CALL : IlOps.CALLVIRT;
		il.opToken(op, token, m.params.length + (isStatic ? 0 : 1), m.ret.match(LVoid) ? 0 : 1);
		return m.ret;
	}

	// `new T(args)`: the .NET constructor bound as a call; a struct's `new T()` without one is its default.
	function newObject(t:CsType, args:Array<CsExpr>):IlSigNorm {
		var s = names.resolveType(t);
		if (programClass(s) != null) throw new Unsupported("`new` of a Haxe class in inline C#", false);
		if (DotnetTypes.isValueType(s) && args.length == 0 && !atPos(() -> g.externs.hasParameterlessCtor(s))) {
			tl.pushDefault(s);
			return s;
		}
		var pushed = pushArgs(args);
		var m = bind(s, ".ctor", false, pushed);
		if (m == null) error("no .NET constructor of " + csName(s) + " takes these arguments (C# error CS1729)");
		return emitCall(m, VType(s), false, pushed, true);
	}

	// `e1[args]`: an array's element (one int index), or the getter of the .NET indexer, bound as a call.
	function index(e1:CsExpr, args:Array<CsExpr>):IlSigNorm {
		var r = receiver(e1);
		var rt = receiverType(r, "[]");
		if (rt.isStatic) error("the inline C# type " + csName(rt.t) + " cannot be indexed (C# error CS0119)");
		switch (rt.t) {
			case LVector(elem):
				if (args.length != 1) error("an inline C# array takes one index (C# error CS0022)");
				var it = value(args[0]);
				if (it == null || !it.match(LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LInt32))
					throw new Unsupported("array indexes of other types than int in inline C#", true);
				il.ldelem(elem, () -> g.typeTokenOf(elem));
				return elem;
			case _:
		}
		if (programClass(rt.t) != null) throw new Unsupported("indexers of Haxe classes in inline C#", true);
		var getter = atPos(() -> g.externs.indexerGetterCs(rt.t));
		var noIndexer = "the inline C# expression is " + article(csName(rt.t)) + ", which has no indexer (C# error CS0021)";
		if (getter == null) error(noIndexer);
		var pushed = pushArgs(args);
		var m = bind(rt.t, getter, false, pushed);
		if (m == null) error(noIndexer);
		return emitCall(m, r, false, pushed);
	}

	// ---- members of the program's classes

	// The field named `name` of `c` or of a superclass (static ones with `isStatic`), and the class declaring it.
	static function findField(c:TClass, name:String, isStatic:Bool):Null<{owner:TClass, cf:TClassField}> {
		var cur = c;
		while (cur != null && !TypeFunctions.hasClassFlag(cur, CExtern)) {
			var cf = isStatic ? cur.statics.get(name) : cur.fields.get(name);
			if (cf != null) return {owner: cur, cf: cf};
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return null;
	}

	// Where the member `name` of the program's class `c` is looked up when `c` and its Haxe superclasses do not
	// declare it: the .NET class of its nearest extern superclass, with the type arguments the chain gives it
	// (C# finds the inherited .NET member there); null when `c` declares it or has no extern superclass.
	function netBaseFor(c:TClass, name:String, isStatic:Bool):Null<IlSigNorm> {
		if (findField(c, name, isStatic) != null || c.params.length > 0) return null;
		var cur = c, params:Array<T> = [];
		while (cur.superClass != null) {
			var sup = cur.superClass, cparams = cur.params, args = params;
			params = [for (p in sup.params) TypeFunctions.applyParams(cparams, args, p)];
			cur = sup.c;
			if (TypeFunctions.hasClassFlag(cur, CExtern)) return tl.sig(TInst(cur, params));
		}
		return null;
	}

	// A member of `c` C# text names that `c` does not have: one DCE removed (ruling 7), else unknown.
	function missingMember(c:TClass, name:String, isStatic:Bool):Dynamic {
		var cur = c;
		while (cur != null) {
			if (g.ctx.dceRemovedFields.exists(Globals.sTypePath(cur.path) + "." + name))
				error("the inline C# member " + Globals.sTypePath(cur.path) + "." + name + " was removed by DCE, as only C# text uses it; add @:keep to it");
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return unknownName(Globals.sTypePath(c.path) + "." + name, isStatic ? "CS0117" : "CS1061");
	}

	// `c.name` (`isStatic`) or `x.name` for an `x` of `c`'s type, pushed as `r`: a variable of the program's
	// class, as gencs writes it a C# field.
	function programField(c:TClass, name:String, isStatic:Bool, r:CsValue):IlSigNorm {
		var f = findField(c, name, isStatic);
		if (f == null) return missingMember(c, name, isStatic);
		var cf = f.cf;
		if (cf.kind.match(Method(_))) error("a method group is not part of the inline C# subset; call the method, or write a Haxe function");
		if (g.varProperties.exists(cf)) throw new Unsupported("@:property variables of Haxe classes in inline C#", true);
		// A Haxe property with accessors is no C# member.
		if (!TypeFunctions.isPhysicalVarField(cf)) return unknownName(Globals.sTypePath(c.path) + "." + name, isStatic ? "CS0117" : "CS1061");
		if (isStatic) {
			var e:TExpr = {expr: TField({expr: TTypeExpr(TClassDecl(f.owner)), type: cf.type, pos: pos}, FStatic(f.owner, cf)), type: cf.type, pos: pos};
			var s = tl.sig(cf.type);
			tl.texpr(RValue(s), e);
			return s;
		}
		if (f.owner.params.length > 0 || c.params.length > 0) throw new Unsupported("members of generic Haxe classes in inline C#", true);
		if (g.ownerOf.get(cf) == null) throw new Unsupported("this Haxe variable in inline C#", false);
		var fld = tl.calls.instanceField(f.owner, [], cf);
		boxReceiverFor(r, fld.owner);
		il.opToken(IlOps.LDFLD, fld.token, 1, 1);
		return fld.sig;
	}

	// `c.name(args)` (`isStatic`) or `x.name(args)` for an `x` of `c`'s type, pushed as `r`: a method of the
	// program's class, with C#'s implicit conversions of the arguments to its parameters (CS1503 otherwise).
	function programCall(c:TClass, name:String, isStatic:Bool, r:CsValue, args:Array<CsExpr>):IlSigNorm {
		var f = findField(c, name, isStatic);
		if (f == null) return missingMember(c, name, isStatic);
		var cf = f.cf;
		if (!cf.kind.match(Method(_)) || cf.kind.match(Method(MethDynamic)))
			throw new Unsupported("calls of a Haxe variable's value in inline C#", true);
		if (cf.overloads.length > 0 || cf.params.length > 0 || f.owner.params.length > 0 || c.params.length > 0)
			throw new Unsupported("calls of overloaded or generic Haxe methods in inline C#", true);
		g.types.checkKept(TClassDecl(f.owner));
		var plan = g.ownerOf.get(cf);
		if (plan == null || !g.methodTokens.exists(cf)) throw new Unsupported("calls of this Haxe method in inline C#", false);
		var owner = isStatic ? TexprToIl.staticOwner(plan) : DotnetCtx.instanceOf(plan, []);
		var m = tl.calls.methodRef(plan, owner, [], cf, cf.type, cf.type);
		var pushed = pushArgs(args);
		var what = Globals.sTypePath(f.owner.path) + "." + name;
		if (pushed.length != m.args.length) error("the Haxe method " + what + " takes " + m.args.length + " arguments (C# error CS1501)");
		for (i in 0...pushed.length) {
			var p = pushed[i], to = m.args[i];
			var ok = p.t == null ? isReference(to) || DotnetTypes.isSystemNullable(to) : g.externs.implicitlyConverts(p.t, to);
			if (!ok)
				error("the inline C# argument " + (i + 1) + " of " + what + " is " + article(csName(p.t)) + ", which does not convert to " + csName(to)
					+ " (C# error CS1503)");
		}
		var onValue = DotnetTypes.isValueType(owner);
		var fix = switch (r) {
			case VAddress(_) if (!isStatic && !onValue): () -> boxReceiverFor(r, owner);
			case _: null;
		}
		convertArgs(pushed, m.args, fix);
		il.opToken(isStatic || onValue ? IlOps.CALL : IlOps.CALLVIRT, m.token, m.args.length + (isStatic ? 0 : 1), m.ret.match(LVoid) ? 0 : 1);
		return m.ret;
	}

	static function keywordType(name:String):IlSigNorm {
		return switch (name) {
			case "bool": LBool;
			case "byte": LUInt8;
			case "sbyte": LInt8;
			case "short": LInt16;
			case "ushort": LUInt16;
			case "int": LInt32;
			case "uint": LUInt32;
			case "long": LInt64;
			case "ulong": LUInt64;
			case "char": LChar;
			case "float": LFloat32;
			case "double": LFloat64;
			case "decimal": decimal;
			case "string": LString;
			case "object": LObject;
			case _: throw "internal error: no keyword type " + name;
		}
	}

	// A type as C# names it, for errors.
	static function csName(s:Null<IlSigNorm>):String {
		if (s == null) return "null";
		return switch (s) {
			case LBool: "bool";
			case LUInt8: "byte";
			case LInt8: "sbyte";
			case LInt16: "short";
			case LUInt16: "ushort";
			case LInt32: "int";
			case LUInt32: "uint";
			case LInt64: "long";
			case LUInt64: "ulong";
			case LChar: "char";
			case LFloat32: "float";
			case LFloat64: "double";
			case LString: "string";
			case LObject: "object";
			case LVector(e): csName(e) + "[]";
			case _ if (isDecimal(s)): "decimal";
			case LClass(p, _) | LValueType(p, _): p.ns.concat(p.nested).concat([p.name]).join(".");
			case _: Std.string(s);
		}
	}

	static function article(name:String):String return ("aeiou".indexOf(name.charAt(0)) >= 0 ? "an " : "a ") + name;

	// ---- values

	// Pushes the value of `x` and returns its type: null for the null literal, LVoid when it has none.
	function value(x:CsExpr):Null<IlSigNorm> {
		return switch (x.def) {
			case CPlaceholder(n):
				placeholder(n, x);
			case CLiteral(l):
				literal(l);
			case CParen(e1):
				value(e1);
			case CUnop("!", e1):
				boolOperand(e1);
				not();
				LBool;
			case CUnop(_, e1):
				constant(x);
				negate(e1);
			case CBinop(op = "&&" | "||", a, b):
				shortCircuit(op == "&&", a, b);
			case CBinop(op, a, b):
				constant(x);
				var ta = value(a);
				binary(op, a, b, ta, value(b));
			case CCast(t, e1):
				var to = names.resolveType(t);
				constant(x);
				castExpr(to, e1);
			case CIs(e1, t):
				var to = names.resolveType(t);
				box(value(e1));
				il.opToken(IlOps.ISINST, g.typeTokenOf(to), 1, 1);
				il.op(IlOps.LDNULL, 0, 1);
				il.op(IlOps.CGT_UN, 2, 1);
				LBool;
			case _:
				switch (resolveName(x)) {
					case VPushed(t): t;
					case VType(t): error("the inline C# type " + csName(t) + " is no value");
					case VNamespace(path): error("the inline C# namespace " + path.join(".") + " is no value (C# error CS0118)");
					case VAddress(_): throw "internal error: an address as a value";
				}
		}
	}

	// Argument `n`, evaluated at each use as gencs's text substitution does, in its own type; a
	// haxe.lang.Null<T> goes as gencs's `toDynamic()`, an object.
	function outOfBounds(n:Int, x:CsExpr):Dynamic {
		throw Unsupported.haxeError("Out-of-bounds special parameter: " + n, new Position(textPos.file, textPos.min + x.pos, textPos.max));
	}

	// A Haxe null of a reference type or Dynamic is gencs's text `null`, the C# null literal (as
	// `literal(LNull)`); one of a Null<T> of a value type or of a type parameter is gencs's
	// `default(global::haxe.lang.Null<int>)` or `default(T)`, a typed value.
	function placeholder(n:Int, x:CsExpr):Null<IlSigNorm> {
		if (n >= args.length) outOfBounds(n, x);
		var a = args[n];
		var t = argSig(a);
		if (isNullConst(a) && !tl.isHaxeNull(t) && !isTypeParam(t) && !DotnetTypes.isValueType(t)) {
			il.op(IlOps.LDNULL, 0, 1);
			return null;
		}
		if (tl.isHaxeNull(t)) t = LObject;
		tl.texpr(RValue(t), a);
		return t;
	}

	// The CLR type of a placeholder's argument: its Haxe type's, but for a call of Object's own member through
	// an untyped field (`(s : cs.system.String).GetHashCode()`, of no type yet), which gencs's C# calls directly,
	// so C# types it as the member returns, and TexprCalls calls it so too.
	function argSig(a:TExpr):IlSigNorm {
		switch [TypeFunctions.follow(a.type), strip(a).expr] {
			case [TMono(_), TCall(callee, cargs)]:
				switch (strip(callee).expr) {
					case TField(_, FDynamic(name)):
						var m = tl.calls.objectMember(name, cargs.length);
						if (m != null) return m;
					case _:
				}
			case _:
		}
		return tl.sig(a.type);
	}

	// The value of a float literal with the `f` suffix. Roslyn rounds the decimal to a float once; hxc parses
	// it to a double first, which gives another float when that double lies exactly between two floats (the
	// decimal was just above or below that midpoint, and the double rounds to even). The exact decimal is not
	// worth the cost (no inline C# has an f literal), so such a literal is refused, an exact midpoint too. A
	// literal that rounds to infinity is C#'s error CS0594, and hxc must not write the infinity; the midpoint
	// between float.MaxValue and 2^128 rounds up, so it is out of range too (its neighbours below, rounded to
	// the same double, are refused with it).
	function singleLiteral(digits:String):Float {
		var d = Std.parseFloat(digits);
		if (d >= Math.pow(2, 128) - Math.pow(2, 103))
			error("the float literal is out of range for float, or too close to float.MaxValue for hxc to round it as C# does (C# error CS0594)");
		if (isSingleMidpoint(d)) error("hxc cannot round this float literal as C# does; write it with fewer digits");
		return d;
	}

	// Whether the finite double `d` is exactly halfway between two adjacent floats.
	static function isSingleMidpoint(d:Float):Bool {
		if (!Math.isFinite(d) || d <= 0) return false;
		var bits = haxe.io.FPHelper.floatToI32(d);
		for (n in [bits - 1, bits + 1]) {
			if (n < 0 || n >= 0x7F800000) continue;
			if (d == (haxe.io.FPHelper.i32ToFloat(bits) + haxe.io.FPHelper.i32ToFloat(n)) / 2) return true;
		}
		return false;
	}

	function literal(l:CsLiteral):Null<IlSigNorm> {
		switch (l) {
			case LInt(s):
				var lit = intLiteral(s);
				if (lit == null) error("inline C# does not parse: " + s + " is no C# integer literal, or too large for one");
				pushInt(lit.v, lit.t);
				return lit.t;
			case LReal(s):
				var suffix = s.charAt(s.length - 1).toLowerCase();
				var digits = "fdm".indexOf(suffix) >= 0 ? s.substr(0, s.length - 1) : s;
				switch (suffix) {
					case "m":
						var d = decimalLiteral(digits);
						if (d == null) throw new Unsupported("decimal literals of more than 18 significant digits or 28 decimals", true);
						pushDecimal(d);
						return decimal;
					case "f":
						il.opR4(IlOps.LDC_R4, singleLiteral(digits), 0, 1);
						return LFloat32;
					case _:
						il.opR8(IlOps.LDC_R8, Std.parseFloat(digits), 0, 1);
						return LFloat64;
				}
			case LString(s):
				il.opToken(IlOps.LDSTR, g.mb.userString(s), 0, 1);
				return LString;
			case LChar(c):
				il.ldcI4(c);
				return LChar;
			case LBool(b):
				il.ldcI4(b ? 1 : 0);
				return LBool;
			case LNull:
				il.op(IlOps.LDNULL, 0, 1);
				return null;
		}
	}

	function pushInt(v:haxe.Int64, t:IlSigNorm):Void {
		if (t.match(LInt32 | LUInt32)) il.ldcI4(v.low) else il.opI64(IlOps.LDC_I8, v, 0, 1);
	}

	// A C# integer literal, such as hxcs's `0xffffffffL` in haxe.Int64.make: its value and the type C# gives
	// it, the first of int, uint, long and ulong that holds it and that its suffix allows; null when it is
	// none or too large.
	static function intLiteral(text:String):Null<CsIntLiteral> {
		var body = text;
		var suffix = "";
		while (body.length > 0 && "uUlL".indexOf(body.charAt(body.length - 1)) >= 0) {
			suffix = body.charAt(body.length - 1).toLowerCase() + suffix;
			body = body.substr(0, body.length - 1);
		}
		if (suffix != "" && suffix != "u" && suffix != "l" && suffix != "ul" && suffix != "lu") return null;
		var hex = body.length > 2 && (body.substr(0, 2) == "0x" || body.substr(0, 2) == "0X");
		var digits = hex ? body.substr(2).toLowerCase() : body;
		// At most 16 hex or 19 decimal digits, which fit in a ulong.
		if (digits.length == 0 || digits.length > (hex ? 16 : 19)) return null;
		var v:haxe.Int64 = 0;
		for (i in 0...digits.length) {
			var d = (hex ? "0123456789abcdef" : "0123456789").indexOf(digits.charAt(i));
			if (d < 0) return null;
			v = hex ? (v << 4) | d : v * 10 + d;
		}
		var unsigned = suffix.indexOf("u") >= 0, long = suffix.indexOf("l") >= 0;
		inline function fits(high:Int, low:Int) return haxe.Int64.ucompare(v, haxe.Int64.make(high, low)) <= 0;
		var t = if (!long && !unsigned && fits(0, 0x7FFFFFFF)) LInt32
			else if (!long && fits(0, 0xFFFFFFFF)) LUInt32
			else if (!unsigned && fits(0x7FFFFFFF, 0xFFFFFFFF)) LInt64
			else LUInt64;
		return {v: v, t: t};
	}

	// ---- decimal (plan ruling 5)

	static function isDecimal(s:Null<IlSigNorm>):Bool {
		return s != null && switch (s) {
			case LValueType(p, []): p.name == "Decimal" && p.nested.length == 0 && p.ns.length == 1 && p.ns[0] == "System";
			case _: false;
		}
	}

	// The digits of a real literal or a Float constant (`2.5`, `1e3`), exact: null when the mantissa has more
	// than 18 digits or the scale more than 28.
	static function decimalLiteral(s:String):Null<DecimalConst> {
		var exp = 0;
		var e = s.toLowerCase().indexOf("e");
		if (e >= 0) {
			var n = Std.parseInt(s.substr(e + 1));
			if (n == null) return null;
			exp = n;
			s = s.substr(0, e);
		}
		var dot = s.indexOf(".");
		var scale = dot < 0 ? 0 : s.length - dot - 1;
		var digits = dot < 0 ? s : s.substr(0, dot) + s.substr(dot + 1);
		while (digits.length > 1 && digits.charAt(0) == "0") digits = digits.substr(1);
		scale -= exp;
		while (scale < 0) {
			digits += "0";
			scale++;
		}
		if (digits.length > 18 || scale > 28) return null;
		var m:haxe.Int64 = 0;
		for (i in 0...digits.length) {
			var d = "0123456789".indexOf(digits.charAt(i));
			if (d < 0) return null;
			m = m * 10 + d;
		}
		return {mantissa: m, negative: false, scale: scale};
	}

	// The decimal `(decimal)x` folds to, as Roslyn does for a constant `x`: an integer literal or Int constant
	// exactly; a decimal literal as written; a real literal or Float constant as .NET's decimal(double) gives
	// it, at most 15 significant digits without trailing zeros (null, not folded, for more). A negation
	// folds too.
	function decimalConstant(x:CsExpr):Null<DecimalConst> {
		switch (x.def) {
			case CParen(e1):
				return decimalConstant(e1);
			case CUnop("-", e1):
				var d = decimalConstant(e1);
				if (d != null) d.negative = !d.negative;
				return d;
			case CLiteral(LInt(s)):
				var lit = intLiteral(s);
				return lit == null || lit.v < 0 ? null : {mantissa: lit.v, negative: false, scale: 0};
			case CLiteral(LReal(s)) if (StringTools.endsWith(s.toLowerCase(), "m")):
				return decimalLiteral(s.substr(0, s.length - 1));
			case CLiteral(LReal(s)):
				var suffix = s.charAt(s.length - 1).toLowerCase();
				return suffix == "f" ? null : fromDouble(suffix == "d" ? s.substr(0, s.length - 1) : s);
			case CPlaceholder(n) if (n < args.length):
				return switch (strip(args[n]).expr) {
					case TConst(TInt(v)):
						var m = haxe.Int64.ofInt(v);
						{mantissa: v < 0 ? -m : m, negative: v < 0, scale: 0};
					case TConst(TFloat(f)): fromDouble(f);
					case _: null;
				}
			case _:
				return null;
		}
	}

	// decimal(double) of the real written as `s`: its digits, when it has at most 15 significant ones (which a
	// double keeps), without trailing zeros after the point.
	static function fromDouble(s:String):Null<DecimalConst> {
		var negative = StringTools.startsWith(s, "-");
		var d = decimalLiteral(negative ? s.substr(1) : s);
		if (d == null || haxe.Int64.compare(d.mantissa, haxe.Int64.make(0x38D7E, 0xA4C67FFF)) > 0) return null; // 10^15 - 1
		while (d.scale > 0 && d.mantissa % 10 == 0) {
			d.mantissa = d.mantissa / 10;
			d.scale--;
		}
		d.negative = negative;
		return d;
	}

	// A decimal constant as Roslyn writes it: Decimal.Zero, One or MinusOne, the int32 or int64 constructor,
	// or the five-part constructor (lo, mid, hi, isNegative, scale).
	function pushDecimal(d:DecimalConst):Void {
		var dec = g.typeTokenOf(decimal);
		var m = d.mantissa;
		var signed = d.negative ? -m : m;
		var isInt = d.scale == 0 && m <= 0x7FFFFFFF;
		var v = signed.low;
		if (isInt && v >= -1 && v <= 1) {
			var name = v == 0 ? "Zero" : v == 1 ? "One" : "MinusOne";
			il.opToken(IlOps.LDSFLD, g.mb.memberRef(dec, name, g.sigs.field(decimal)), 0, 1);
		} else if (isInt) {
			il.ldcI4(v);
			il.opToken(IlOps.NEWOBJ, g.mb.memberRef(dec, ".ctor", g.sigs.method(true, LVoid, [LInt32], 0)), 1, 1);
		} else if (d.scale == 0) {
			il.opI64(IlOps.LDC_I8, signed, 0, 1);
			il.opToken(IlOps.NEWOBJ, g.mb.memberRef(dec, ".ctor", g.sigs.method(true, LVoid, [LInt64], 0)), 1, 1);
		} else {
			il.ldcI4(m.low);
			il.ldcI4(m.high);
			il.ldcI4(0);
			il.ldcI4(d.negative ? 1 : 0);
			il.ldcI4(d.scale);
			il.opToken(IlOps.NEWOBJ, g.mb.memberRef(dec, ".ctor", g.sigs.method(true, LVoid, [LInt32, LInt32, LInt32, LBool, LUInt8], 0)), 5, 1);
		}
	}

	// A static method of System.Decimal, called on the arguments on the stack.
	function decimalCall(name:String, ret:IlSigNorm, argSigs:Array<IlSigNorm>):Void {
		var token = g.mb.memberRef(g.typeTokenOf(decimal), name, g.sigs.method(false, ret, argSigs, 0));
		il.opToken(IlOps.CALL, token, argSigs.length, 1);
	}

	// ---- operators

	static function isNumber(s:Null<IlSigNorm>):Bool {
		return s != null && (s.match(LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64) || isDecimal(s));
	}

	static function isString(s:Null<IlSigNorm>):Bool return s != null && s.match(LString);

	static function isUnsigned(s:IlSigNorm):Bool return s.match(LUInt32 | LUInt64);

	static function isFloat(s:IlSigNorm):Bool return s.match(LFloat32 | LFloat64);

	// The type C#'s binary numeric promotion computes `a` and `b` in, or null where C# has no operator. `ca`
	// and `cb` are their constants, if they are: a non-negative int constant goes with a uint or ulong operand
	// as that type, and a non-negative long constant with a ulong, as C# converts a constant implicitly.
	static function promote(a:IlSigNorm, b:IlSigNorm, ca:Null<CsConst>, cb:Null<CsConst>):Null<IlSigNorm> {
		if (isDecimal(a) || isDecimal(b)) return isFloat(a) || isFloat(b) ? null : decimal;
		if (a.match(LFloat64) || b.match(LFloat64)) return LFloat64;
		if (a.match(LFloat32) || b.match(LFloat32)) return LFloat32;
		inline function signed(s:IlSigNorm) return s.match(LInt8 | LInt16 | LInt32 | LInt64);
		if (a.match(LUInt64) || b.match(LUInt64)) {
			var other = a.match(LUInt64) ? b : a, c = a.match(LUInt64) ? cb : ca;
			return signed(other) && !nonNegative(c, true) ? null : LUInt64;
		}
		if (a.match(LInt64) || b.match(LInt64)) return LInt64;
		if (a.match(LUInt32) || b.match(LUInt32)) {
			var other = a.match(LUInt32) ? b : a, c = a.match(LUInt32) ? cb : ca;
			return signed(other) && !nonNegative(c, false) ? LInt64 : LUInt32;
		}
		return LInt32;
	}

	// A non-negative int constant (with `long`, also a long one), which converts to an unsigned type.
	static function nonNegative(c:Null<CsConst>, long:Bool):Bool {
		return c != null && (c.t.match(LInt32) || long && c.t.match(LInt64)) && c.i >= 0;
	}

	// Converts the value under the one of type `top` on the stack with `convert`, `top` going through a
	// temporary meanwhile.
	function convertUnder(top:Null<IlSigNorm>, convert:Void->Void):Void {
		var tmp = il.addLocal(top == null ? LObject : top);
		il.stloc(tmp);
		convert();
		il.ldloc(tmp);
	}

	// The operands of types `ta` and `tb` on the stack, written `a` and `b`, converted to the type C#
	// computes `op` in, which this returns; refused where C# has no numeric operator for them.
	function numericOperands(op:String, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var t = isNumber(ta) && isNumber(tb) ? promote(ta, tb, constant(a), constant(b)) : null;
		if (t == null) operatorError(op, ta, tb);
		// A small integer and a uint are an int32 on the stack already.
		var same = IlPaths.sigEq(ta, t) || t.match(LInt32 | LUInt32) && ta.match(LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LInt32 | LUInt32);
		if (!same) convertUnder(tb, () -> explicitCast(ta, t));
		explicitCast(tb, t);
		return t;
	}

	function operatorError(op:String, a:Null<IlSigNorm>, b:Null<IlSigNorm>):Dynamic {
		return error("the inline C# operator " + op + " does not apply to " + article(csName(a)) + " and " + article(csName(b)) + " (C# error CS0019)");
	}

	// `a op b` but `&&` and `||`, with both operands pushed: `ta` and `tb` are their types.
	function binary(op:String, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		return switch (op) {
			case "+" if (isString(ta) || isString(tb)): concat(ta, tb);
			case "==" | "!=": equality(op == "==", a, b, ta, tb);
			case "<" | ">" | "<=" | ">=": comparison(op, a, b, ta, tb);
			case _: arithmetic(op, a, b, ta, tb);
		}
	}

	function arithmetic(op:String, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var t = numericOperands(op, a, b, ta, tb);
		if (isDecimal(t)) {
			decimalCall(switch (op) {
				case "+": "op_Addition";
				case "-": "op_Subtraction";
				case "*": "op_Multiply";
				case "/": "op_Division";
				case _: "op_Modulus";
			}, decimal, [decimal, decimal]);
			return t;
		}
		var unsigned = isUnsigned(t);
		il.op(switch (op) {
			case "+": IlOps.ADD;
			case "-": IlOps.SUB;
			case "*": IlOps.MUL;
			case "/": unsigned ? IlOps.DIV_UN : IlOps.DIV;
			case _: unsigned ? IlOps.REM_UN : IlOps.REM;
		}, 2, 1);
		return t;
	}

	// C#'s string `+`: String.Concat of the two strings, or of both as objects when one is not a string.
	function concat(ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var both = isString(ta) && isString(tb);
		if (!both) {
			if (ta != null && DotnetTypes.isValueType(ta) || ta != null && isTypeParam(ta)) convertUnder(tb, () -> box(ta));
			box(tb);
		}
		var argSig = both ? LString : LObject;
		il.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(LString), "Concat", g.sigs.method(false, LString, [argSig, argSig], 0)), 2, 1);
		return LString;
	}

	function comparison(op:String, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var t = numericOperands(op, a, b, ta, tb);
		if (isDecimal(t)) {
			decimalCall(switch (op) {
				case "<": "op_LessThan";
				case ">": "op_GreaterThan";
				case "<=": "op_LessThanOrEqual";
				case _: "op_GreaterThanOrEqual";
			}, LBool, [decimal, decimal]);
			return LBool;
		}
		// As Roslyn: `<=` is `!(a > b)` and `>=` is `!(a < b)`, unordered for doubles, so NaN compares false.
		var un = isUnsigned(t) || isFloat(t) && (op == "<=" || op == ">=");
		switch (op) {
			case "<": il.compare(isUnsigned(t) ? IlOps.CLT_UN : IlOps.CLT, isFloat(t));
			case ">": il.compare(isUnsigned(t) ? IlOps.CGT_UN : IlOps.CGT, isFloat(t));
			case "<=": il.compare(un ? IlOps.CGT_UN : IlOps.CGT, isFloat(t));
			case _: il.compare(un ? IlOps.CLT_UN : IlOps.CLT, isFloat(t));
		}
		if (op == "<=" || op == ">=") not();
		return LBool;
	}

	function not():Void {
		il.ldcI4(0);
		il.op(IlOps.CEQ, 2, 1);
	}

	// `==` and `!=`: numbers after promotion, two bools, two strings by value (String.op_Equality), other
	// references and null by a user-defined operator where one applies (C# 12.4.5), else by identity.
	function equality(eq:Bool, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var op = eq ? "==" : "!=";
		if (isNumber(ta) && isNumber(tb)) {
			var t = numericOperands(op, a, b, ta, tb);
			if (isDecimal(t)) {
				decimalCall(eq ? "op_Equality" : "op_Inequality", LBool, [decimal, decimal]);
				return LBool;
			}
			il.op(IlOps.CEQ, 2, 1);
		} else if (isString(ta) && isString(tb)) {
			var token = g.mb.memberRef(g.typeTokenOf(LString), eq ? "op_Equality" : "op_Inequality", g.sigs.method(false, LBool, [LString, LString], 0));
			il.opToken(IlOps.CALL, token, 2, 1);
			return LBool;
		} else if (ta != null && ta.match(LBool) && tb != null && tb.match(LBool)) {
			il.op(IlOps.CEQ, 2, 1);
		} else if ((ta == null || isReference(ta)) && (tb == null || isReference(tb))) {
			// C# calls a user-defined operator that applies (System.Version's), else compares references.
			var name = eq ? "op_Equality" : "op_Inequality";
			var starts = [for (t in [ta, tb]) { var s = operatorStart(t); if (s != null) s; }];
			var m = starts.length == 0 ? null : atPos(() -> g.externs.equalityCs(name, ta, tb, starts));
			if (m == null) {
				il.op(IlOps.CEQ, 2, 1);
			} else {
				var pushed = [for (t in [ta, tb]) {t: t, kind: t == null ? KNull : KPlain}];
				convertArgs(pushed, m.params);
				il.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(m.parent), m.name, g.sigs.methodSig(m.sig, 0)), 2, 1);
				return LBool;
			}
		} else {
			operatorError(op, ta, tb);
		}
		if (!eq) not();
		return LBool;
	}

	// Where C#'s lookup of a user-defined `==` for an operand of the reference type `t` starts: its .NET class,
	// or a Haxe-compiled class's nearest .NET ancestor (Haxe classes declare no operators). Null for the null
	// literal, object, string (whose operator compares as references do where it applies here), arrays, type
	// parameters and a Haxe class with no .NET ancestor.
	function operatorStart(t:Null<IlSigNorm>):Null<IlSigNorm> {
		if (t == null || isTypeParam(t)) return null;
		var c = programClass(t);
		if (c != null) {
			var cur = c, params = [for (p in c.params) p.type];
			while (cur.superClass != null) {
				var sup = cur.superClass, cparams = cur.params, args = params;
				params = [for (p in sup.params) TypeFunctions.applyParams(cparams, args, p)];
				cur = sup.c;
				if (TypeFunctions.hasClassFlag(cur, CExtern)) return tl.sig(TInst(cur, params));
			}
			return null;
		}
		return switch (t) {
			case LClass(_, _): t;
			case _: null;
		}
	}

	// Pushes `x`, which must be a bool.
	function boolOperand(x:CsExpr):Void {
		var t = value(x);
		if (t == null || !t.match(LBool))
			error("the inline C# expression is " + article(csName(t)) + ", which does not convert to bool implicitly (C# error CS0029)");
	}

	// `a && b` and `a || b`, which evaluate b only when a does not decide.
	function shortCircuit(isAnd:Bool, a:CsExpr, b:CsExpr):IlSigNorm {
		var decided = il.newLabel(), end = il.newLabel();
		boolOperand(a);
		il.branch(isAnd ? IlOps.BRFALSE : IlOps.BRTRUE, decided);
		boolOperand(b);
		il.branch(IlOps.BR, end);
		il.mark(decided);
		il.ldcI4(isAnd ? 0 : 1);
		il.mark(end);
		return LBool;
	}

	// Unary `-` with C#'s promotion: a small integer computes as an int, a uint as a long, and a ulong has
	// none. `-2147483648` and `-9223372036854775808` are int.MinValue and long.MinValue, as in C#.
	function negate(x:CsExpr):IlSigNorm {
		switch (x.def) {
			case CLiteral(LInt(s)):
				var lit = intLiteral(s);
				if (lit != null && lit.t.match(LUInt32) && lit.v == haxe.Int64.make(0, 0x80000000)) {
					il.ldcI4(0x80000000);
					return LInt32;
				}
				if (lit != null && lit.t.match(LUInt64) && lit.v == haxe.Int64.make(0x80000000, 0)) {
					il.opI64(IlOps.LDC_I8, lit.v, 0, 1);
					return LInt64;
				}
			case CLiteral(LReal(s)) if (StringTools.endsWith(s.toLowerCase(), "m")):
				var d = decimalConstant(x);
				if (d != null) {
					d.negative = !d.negative;
					pushDecimal(d);
					return decimal;
				}
			case _:
		}
		var t = value(x);
		if (t == null) return operatorError1("-", t);
		switch (t) {
			case LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LInt32:
				il.op(IlOps.NEG, 1, 1);
				return LInt32;
			case LUInt32:
				il.op(IlOps.CONV_U8, 1, 1);
				il.op(IlOps.NEG, 1, 1);
				return LInt64;
			case LInt64 | LFloat32 | LFloat64:
				il.op(IlOps.NEG, 1, 1);
				return t;
			case _ if (isDecimal(t)):
				decimalCall("op_UnaryNegation", decimal, [decimal]);
				return decimal;
			case _:
				return operatorError1("-", t);
		}
	}

	function operatorError1(op:String, t:Null<IlSigNorm>):Dynamic {
		return error("the inline C# operator " + op + " does not apply to " + article(csName(t)) + " (C# error CS0023)");
	}

	// ---- constants

	// The value of `x` when it is a C# constant expression of a number type, which C# computes at compile
	// time: a literal, an Int or Float constant argument (gencs prints it as a literal), and `-`, the
	// arithmetic operators and numeric casts of constants. As in C#, an overflow (CS0220), a division by zero
	// (CS0020) and a constant cast out of range (CS0221) are errors. Null for any other expression.
	function constant(x:CsExpr):Null<CsConst> {
		switch (x.def) {
			case CParen(e1):
				return constant(e1);
			case CLiteral(LInt(s)):
				var lit = intLiteral(s);
				return lit == null ? null : {t: lit.t, i: lit.v, f: 0.0};
			case CLiteral(LChar(c)):
				return {t: LChar, i: c, f: 0.0};
			case CLiteral(LReal(s)):
				var suffix = s.charAt(s.length - 1).toLowerCase();
				if (suffix == "m") return null;
				var digits = suffix == "f" || suffix == "d" ? s.substr(0, s.length - 1) : s;
				return {t: suffix == "f" ? LFloat32 : LFloat64, i: 0, f: suffix == "f" ? singleLiteral(digits) : Std.parseFloat(digits)};
			case CPlaceholder(n) if (n < args.length):
				var t = tl.sig(args[n].type);
				return switch (strip(args[n]).expr) {
					case TConst(TInt(v)) if (t.match(LInt32)): {t: LInt32, i: v, f: 0.0};
					case TConst(TFloat(f)) if (t.match(LFloat64)): {t: LFloat64, i: 0, f: Std.parseFloat(f)};
					case _: null;
				}
			case CUnop("-", e1):
				return negateConstant(e1);
			case CMember(e1, name):
				// A literal of a .NET type, `int.MinValue`.
				var t = switch (names.typeOrNamespace(e1)) {
					case VType(t) if (programClass(t) == null): t;
					case _: return null;
				}
				var b = atPos(() -> g.externs.memberCs(t, name, true));
				if (b == null) return null;
				return switch (b.member) {
					case XConstant(IInt(v), s = LInt32 | LUInt32): {t: s, i: haxe.Int64.make(s.match(LUInt32) ? 0 : v >> 31, v), f: 0.0};
					case XConstant(IInt64(_, v), s = LInt64 | LUInt64): {t: s, i: v, f: 0.0};
					case XConstant(IByte(v) | IShort(v), s = LInt8 | LUInt8 | LInt16 | LUInt16):
						var signed = s.match(LInt8 | LInt16), bits = s.match(LInt8 | LUInt8) ? 24 : 16;
						{t: s, i: signed ? (v << bits) >> bits : v, f: 0.0};
					case XConstant(IChar(v), LChar): {t: LChar, i: v, f: 0.0};
					case XConstant(IFloat32(v), LFloat32): {t: LFloat32, i: 0, f: v};
					case XConstant(IFloat64(v), LFloat64): {t: LFloat64, i: 0, f: v};
					case _: null;
				}
			case CBinop(op = "+" | "-" | "*" | "/" | "%", a, b):
				var ca = constant(a), cb = constant(b);
				if (ca == null || cb == null) return null;
				var t = promote(ca.t, cb.t, ca, cb);
				if (t == null || isDecimal(t)) return null;
				if (!isFloat(t)) return {t: t, i: integerOp(op, ca.i, cb.i, t), f: 0.0};
				var fa = asFloat(ca), fb = asFloat(cb);
				return {t: t, i: 0, f: switch (op) {
					case "+": fa + fb;
					case "-": fa - fb;
					case "*": fa * fb;
					case "/": fa / fb;
					case _: fa % fb;
				}};
			case CCast(ct, e1):
				var c = constant(e1);
				var to = names.resolveType(ct);
				if (c == null || !isNumber(to) || isDecimal(to)) return null;
				if (isFloat(to)) return {t: to, i: 0, f: asFloat(c)};
				if (!isFloat(c.t)) {
					if (!fits(c, to)) constantRange(constString(c), to);
					return {t: to, i: c.i, f: 0.0};
				}
				var whole = c.f < 0 ? Math.fceil(c.f) : Math.ffloor(c.f);
				if (!Math.isFinite(c.f) || !floatFits(whole, to)) constantRange(Std.string(c.f), to);
				// A ulong of 2^63 or more as its bits.
				return {t: to, i: haxe.Int64.fromFloat(whole >= 9.223372036854775808e18 ? whole - 1.8446744073709551616e19 : whole), f: 0.0};
			case _:
				return null;
		}
	}

	// `-c` of the constant `x`, with C#'s promotion: `-2147483648` and `-9223372036854775808` are int.MinValue
	// and long.MinValue; a ulong has no `-` (value reports it).
	function negateConstant(x:CsExpr):Null<CsConst> {
		switch (x.def) {
			case CLiteral(LInt(s)):
				var lit = intLiteral(s);
				if (lit != null && lit.t.match(LUInt32) && lit.v == haxe.Int64.make(0, 0x80000000)) return {t: LInt32, i: haxe.Int64.make(-1, 0x80000000), f: 0.0};
				if (lit != null && lit.t.match(LUInt64) && lit.v == haxe.Int64.make(0x80000000, 0)) return {t: LInt64, i: lit.v, f: 0.0};
			case _:
		}
		var c = constant(x);
		if (c == null) return null;
		return switch (c.t) {
			case LFloat32 | LFloat64: {t: c.t, i: 0, f: -c.f};
			case LUInt64: null;
			case LUInt32: {t: LInt64, i: -c.i, f: 0.0};
			case LInt64:
				if (c.i == haxe.Int64.make(0x80000000, 0)) overflow();
				{t: LInt64, i: -c.i, f: 0.0};
			case _:
				if (c.i == haxe.Int64.make(-1, 0x80000000)) overflow();
				{t: LInt32, i: -c.i, f: 0.0};
		}
	}

	function overflow():Dynamic return error("the inline C# constant expression overflows (C# error CS0220)");

	function constantRange(text:String, to:IlSigNorm):Dynamic {
		return error("the inline C# constant " + text + " does not convert to " + csName(to) + " (C# error CS0221)");
	}

	// Whether the constant `x` converts to `target` implicitly, as C# converts a constant: an int one that a
	// smaller or unsigned integer type holds, or a non-negative long one to ulong.
	function constantConverts(x:CsExpr, target:IlSigNorm):Bool {
		if (!target.match(LInt8 | LUInt8 | LInt16 | LUInt16 | LUInt32 | LUInt64)) return false;
		var c = constant(x);
		return c != null && (c.t.match(LInt32) && fits(c, target) || c.t.match(LInt64) && target.match(LUInt64) && c.i >= 0);
	}

	// Whether the integer constant `c` is in the range of the integer type `to`.
	static function fits(c:CsConst, to:IlSigNorm):Bool {
		// A ulong of 2^63 or more.
		if (c.t.match(LUInt64) && c.i < 0) return to.match(LUInt64);
		var v = c.i;
		inline function within(lo:haxe.Int64, hi:haxe.Int64) return v >= lo && v <= hi;
		return switch (to) {
			case LInt8: within(-128, 127);
			case LUInt8: within(0, 255);
			case LInt16: within(-32768, 32767);
			case LUInt16 | LChar: within(0, 65535);
			case LInt32: within(haxe.Int64.make(-1, 0x80000000), 0x7FFFFFFF);
			case LUInt32: within(0, haxe.Int64.make(0, 0xFFFFFFFF));
			case LInt64: true;
			case LUInt64: v >= 0;
			case _: false;
		}
	}

	// Whether the whole number `f` is in the range of the integer type `to`.
	static function floatFits(f:Float, to:IlSigNorm):Bool {
		return switch (to) {
			case LInt8: f >= -128 && f <= 127;
			case LUInt8: f >= 0 && f <= 255;
			case LInt16: f >= -32768 && f <= 32767;
			case LUInt16 | LChar: f >= 0 && f <= 65535;
			case LInt32: f >= -2147483648.0 && f <= 2147483647.0;
			case LUInt32: f >= 0 && f <= 4294967295.0;
			case LInt64: f >= -9.223372036854775808e18 && f < 9.223372036854775808e18;
			case LUInt64: f >= 0 && f < 1.8446744073709551616e19;
			case _: false;
		}
	}

	static function asFloat(c:CsConst):Float {
		if (isFloat(c.t)) return c.f;
		var low:Float = c.i.low < 0 ? c.i.low + 4294967296.0 : c.i.low;
		var high:Float = c.t.match(LUInt64) && c.i.high < 0 ? c.i.high + 4294967296.0 : c.i.high;
		return high * 4294967296.0 + low;
	}

	static function constString(c:CsConst):String {
		if (!(c.t.match(LUInt64) && c.i < 0)) return Std.string(c.i);
		// Unsigned: v / 10 is (v >>> 1) / 5.
		var q = (c.i >>> 1) / 5;
		return Std.string(q) + Std.string(c.i - q * 10);
	}

	// `a op b` of two integer constants of the type `t` (a ulong's as its bits), checked as C# checks them.
	function integerOp(op:String, a:haxe.Int64, b:haxe.Int64, t:IlSigNorm):haxe.Int64 {
		if ((op == "/" || op == "%") && b == 0) error("the inline C# constant expression divides by zero (C# error CS0020)");
		switch (t) {
			case LUInt64:
				switch (op) {
					case "+":
						var r = a + b;
						if (haxe.Int64.ucompare(r, a) < 0) overflow();
						return r;
					case "-":
						if (haxe.Int64.ucompare(a, b) < 0) overflow();
						return a - b;
					case "*":
						return mulU64(a, b);
					case _:
						var qr = udivMod(a, b);
						return op == "/" ? qr.q : qr.r;
				}
			case LInt64:
				var min = haxe.Int64.make(0x80000000, 0);
				switch (op) {
					case "+":
						var r = a + b;
						if ((a >= 0) == (b >= 0) && (r >= 0) != (a >= 0)) overflow();
						return r;
					case "-":
						var r = a - b;
						if ((a >= 0) != (b >= 0) && (r >= 0) != (a >= 0)) overflow();
						return r;
					case "*":
						var r = a * b;
						if (a != 0 && (r / a != b || a == -1 && b == min)) overflow();
						return r;
					case "/":
						if (a == min && b == -1) overflow();
						return a / b;
					case _:
						return b == -1 ? haxe.Int64.ofInt(0) : a % b;
				}
			case _:
				// An int or uint: the exact value fits in a long, then must fit in `t`.
				var r = switch (op) {
					case "+": a + b;
					case "-": a - b;
					case "*":
						if (Math.abs(asFloat({t: LInt64, i: a, f: 0.0}) * asFloat({t: LInt64, i: b, f: 0.0})) >= 1099511627776.0) overflow();
						a * b;
					case "/": a / b;
					case _: a % b;
				}
				if (!fits({t: LInt64, i: r, f: 0.0}, t)) overflow();
				return r;
		}
	}

	// The ulong product of `a` and `b` (bits), or the overflow error.
	function mulU64(a:haxe.Int64, b:haxe.Int64):haxe.Int64 {
		var ah = haxe.Int64.make(0, a.high), al = haxe.Int64.make(0, a.low);
		var bh = haxe.Int64.make(0, b.high), bl = haxe.Int64.make(0, b.low);
		if (ah != 0 && bh != 0) overflow();
		var x = ah != 0 ? ah : bh, y = ah != 0 ? bl : al;
		if (asFloat({t: LInt64, i: x, f: 0.0}) * asFloat({t: LInt64, i: y, f: 0.0}) >= 4294967296.0) overflow();
		var low = al * bl;
		var r = ((x * y) << 32) + low;
		if (haxe.Int64.ucompare(r, low) < 0) overflow();
		return r;
	}

	// Unsigned division of the bits `a` by `b` (not 0).
	static function udivMod(a:haxe.Int64, b:haxe.Int64):DivMod {
		if (b < 0) {
			var q = haxe.Int64.ucompare(a, b) >= 0 ? haxe.Int64.ofInt(1) : haxe.Int64.ofInt(0);
			return {q: q, r: a - q * b};
		}
		if (a >= 0) return {q: a / b, r: a % b};
		var q = ((a >>> 1) / b) << 1;
		var r = a - q * b;
		if (haxe.Int64.ucompare(r, b) >= 0) {
			q = q + 1;
			r = r - b;
		}
		return {q: q, r: r};
	}

	// ---- casts

	// `(to)x`. A decimal from a constant folds as Roslyn does (plan ruling 5).
	function castExpr(to:IlSigNorm, x:CsExpr):IlSigNorm {
		if (isDecimal(to)) {
			var d = decimalConstant(x);
			if (d != null) {
				pushDecimal(d);
				return to;
			}
		}
		explicitCast(value(x), to);
		return to;
	}

	// The underlying type of the .NET enum `s`, or null when it is none.
	function enumUnderlying(s:Null<IlSigNorm>):Null<IlSigNorm> {
		return switch (s) {
			case LValueType(p, []) if (!isDecimal(s)): g.externs.enumUnderlying(p);
			case _: null;
		}
	}

	// Refuses a conversion between `from` and `to` that a user-defined conversion operator of either may make
	// (`explicit`: op_Explicit too), which hxc does not apply (csexpr §7); decimal's are applied above.
	function userConversionError(from:IlSigNorm, to:IlSigNorm, explicit:Bool):Void {
		var op = g.externs.userConversion(from, explicit);
		if (op == null) op = g.externs.userConversion(to, explicit);
		if (op != null) error("hxc cannot apply the .NET conversion " + op + " in inline C#; convert in Haxe");
	}

	// A value type on the stack boxed, as C# converts it to object.
	function box(s:Null<IlSigNorm>):Void {
		if (s != null && (DotnetTypes.isValueType(s) || isTypeParam(s))) il.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
	}

	// C#'s explicit (unchecked) conversion of the `from` on the stack to `to`: identity, between numbers
	// (decimal through its op_Implicit and op_Explicit), boxing, unboxing (unbox.any), and between references
	// an upcast or castclass.
	function explicitCast(from:Null<IlSigNorm>, to:IlSigNorm):Void {
		if (from == null) {
			if (DotnetTypes.isValueType(to)) error("the inline C# null does not convert to " + csName(to) + " (C# error CS0037)");
			return;
		}
		if (IlPaths.sigEq(from, to)) return;
		if (from.match(LVoid)) error("the inline C# expression has no value (C# error CS0029)");
		// An enum converts explicitly to and from the numbers and other enums, as its underlying type (decimal
		// through that type).
		var fromEnum = enumUnderlying(from), toEnum = enumUnderlying(to);
		if (fromEnum != null || toEnum != null) {
			var f = fromEnum != null ? fromEnum : from, t = toEnum != null ? toEnum : to;
			if (isNumber(f) && isNumber(t)) {
				explicitCast(f, t);
				return;
			}
		}
		if (isDecimal(from) && isNumber(to)) {
			decimalCall("op_Explicit", to, [decimal]);
		} else if (isDecimal(to) && isNumber(from)) {
			decimalCall(isFloat(from) ? "op_Explicit" : "op_Implicit", decimal, [from]);
		} else if (isNumber(from) && isNumber(to)) {
			numericCast(from, to);
		} else if (boxes(from, to)) {
			box(from);
			if (!to.match(LObject) && !g.externs.implicitlyConverts(from, to)) tl.castTo(to);
		} else if (unboxes(from, to)) {
			il.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
		} else if (referenceConverts(from, to)) {
			if (!to.match(LObject) && !g.isUpcast(from, to) && !g.externs.implicitlyConverts(from, to)) tl.castTo(to);
		} else {
			userConversionError(from, to, true);
			error("the inline C# expression is " + article(csName(from)) + ", which does not convert to " + csName(to) + " (C# error CS0030)");
		}
	}

	// C#'s unchecked conversion between the primitive numbers `from` and `to` (no decimal).
	function numericCast(from:IlSigNorm, to:IlSigNorm):Void {
		var unsignedFrom = from.match(LUInt8 | LUInt16 | LChar | LUInt32 | LUInt64);
		var from64 = from.match(LInt64 | LUInt64);
		var fromFloat = isFloat(from);
		inline function op(o:Int) il.op(o, 1, 1);
		switch (to) {
			case LInt8: op(IlOps.CONV_I1);
			case LUInt8: op(IlOps.CONV_U1);
			case LInt16: op(IlOps.CONV_I2);
			case LUInt16 | LChar: op(IlOps.CONV_U2);
			case LInt32: if (from64 || fromFloat) op(IlOps.CONV_I4);
			case LUInt32: if (from64 || fromFloat) op(IlOps.CONV_U4);
			case LInt64 | LUInt64:
				if (fromFloat) op(to.match(LInt64) ? IlOps.CONV_I8 : IlOps.CONV_U8);
				else if (!from64) op(unsignedFrom ? IlOps.CONV_U8 : IlOps.CONV_I8);
			case LFloat32 | LFloat64:
				if (from.match(LUInt32 | LUInt64)) op(IlOps.CONV_R_UN);
				op(to.match(LFloat32) ? IlOps.CONV_R4 : IlOps.CONV_R8);
			case _:
				throw "internal error: not a number: " + to;
		}
	}
}
