package hxc.codegen.dotnet;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.AttributesToIl.AttrType;
import hxc.codegen.dotnet.AttributesToIl.AttrValue;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.TclassToIl;

// gencs's indexers (check_special_behaviors in gencs.ml; codeblocks notes §3). Every class or interface
// that has an instance `__get` with one argument and/or `__set` with two, of its own and kept by DCE, gets
// `public V this[I index] { get { return this.__get(index); } set { this.__set(index, value); } }`, one per
// index type in the order of the C# type names: Public HideBySig SpecialName get_Item and set_Item, a
// Property row `Item` with the index in its signature, and [DefaultMember("Item")] on the type. A class
// with a companion interface (CompanionToIl) and array access also implements the companion's
// `object this[int key]` explicitly, as `global::<companion>.get_Item` and `set_Item`, which box the element
// and cast it back; the companion declares the abstract accessors and its own Property `Item`. Array has
// all of them: its `__get` and `__set` are @:keep in hxc's runtime.
//
// Where gencs's C# fails to compile, hxc does better: a generic class with array access whose own
// `__get(Int)` DCE removed, or that has no `__set`, gets a companion indexer it can implement (none, or a
// get-only one) instead of one it cannot (C# errors CS0535 and CS1061); and a companion that declares
// `__get` and `__set` themselves (they mention no type parameter) gets the one indexer, not gencs's two
// (CS0111). A `__get`/`__set` pair whose element types differ is refused.
//
// An interface gets the same indexer as a C# default interface member: Public Virtual HideBySig NewSlot
// SpecialName accessors with bodies that callvirt its `__get` and `__set`. An implementing class's own
// accessor of the same signature implements it, virtual and sealed as C# makes it.
class IndexerToIl {
	public static inline final itemName = "Item";

	// The class's indexers, and its explicit implementation of its companion's, as PropertyPlans whose
	// accessors (kind MIndexer) `planClass` adds to its methods. `methods` are the class's methods so far,
	// among them its `__get` and `__set`, whose signatures the accessors take.
	public static function plan(g:DotnetCtx, c:TClass, methods:Array<MethodPlan>):Array<PropertyPlan> {
		if (c.kind.match(KAbstractImpl(_))) return [];
		var get = c.fields.get("__get"), set = c.fields.get("__set");
		if (get == null && set == null) return [];
		var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
		function planOf(f:TClassField):Null<MethodPlan> {
			for (m in methods) switch (m.kind) {
				case MField(x) if (x == f && m.hasThis): return m;
				case _:
			}
			return null;
		}
		// One group per index type, as gencs's PMap keyed by the C# type's name.
		var groups:Array<{key:String, index:IlSigNorm, value:IlSigNorm, get:Null<TClassField>, set:Null<TClassField>}> = [];
		function group(index:IlSigNorm) {
			for (x in groups) if (IlPaths.sigEq(x.index, index)) return x;
			var x = {key: csName(c, index), index: index, value: null, get: null, set: null};
			groups.push(x);
			return x;
		}
		if (get != null) for (f in [get].concat(get.overloads)) {
			var m = planOf(f);
			// gencs warns about a __get without exactly one argument and leaves it out.
			if (m == null || m.args.length != 1) continue;
			var x = group(m.args[0]);
			x.value = m.ret;
			x.get = f;
		}
		if (set != null) for (f in [set].concat(set.overloads)) {
			var m = planOf(f);
			if (m == null || m.args.length != 2) continue;
			var x = group(m.args[0]);
			if (x.get != null && !IlPaths.sigEq(x.value, m.args[1])) {
				// gencs warns, and its indexer's setter passes the getter's type to __set, which C# rejects.
				var u = Unsupported.error(DotnetTypes.haxePath(TClassDecl(c)) + ".__get and __set disagree on the element type for the index "
					+ csName(c, x.index) + " (" + csName(c, x.value) + " and " + csName(c, m.args[1]) + "): gencs's indexer for them does not compile");
				u.pos = f.pos;
				throw u;
			}
			if (x.get == null) x.value = m.args[1];
			x.set = f;
		}
		groups.sort((a, b) -> a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
		var r:Array<PropertyPlan> = [];
		// An interface's indexer is a C# default interface member, virtual with a body.
		var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME
			| (isInterface ? MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT : 0);
		var implemented = isInterface ? [] : interfaceAccessors(g, c);
		for (x in groups) {
			var p = property(c, itemName, x.value, x.index, x.get, x.set, null, ["index", "value"], flags, "", (x.get != null ? x.get : x.set).pos);
			// An accessor that implements an indexer accessor of an interface the class lists is virtual and
			// sealed, as C# makes a member that implicitly implements an interface member.
			for (a in [p.getter, p.setter]) if (a != null) for (i in implemented) if (i.isSet == (a == p.setter) && IlPaths.sigEq(i.index, x.index)
				&& IlPaths.sigEq(i.value, x.value))
				a.flags |= MethodAttrs.VIRTUAL | MethodAttrs.FINAL | MethodAttrs.NEW_SLOT;
			r.push(p);
		}
		// The explicit implementation of the companion's `object this[int key]`, on gencs's own __get's
		// index and on the group of the Int index.
		if (c.arrayAccess != null && CompanionToIl.hasCompanion(g, c)) {
			var own = get == null ? null : planOf(get);
			var ints = null;
			for (x in groups) if (x.index.match(LInt32)) ints = x;
			if (own != null && own.args.length == 1 && own.args[0].match(LInt32) && ints != null && ints.get != null) {
				var element = g.types.toSig(TypeFunctions.applyParams(c.params, [for (_ in c.params) TypeFunctions.tDynamic], c.arrayAccess));
				// The explicit accessors cast between the element and __get's and __set's types as C# does: a box,
				// an unbox or a reference cast, never a conversion between two value types.
				checkCast(c, ints.value, element, ints.get.pos);
				if (ints.set != null) checkCast(c, element, ints.value, ints.set.pos);
				var prefix = "global::" + TclassToIl.displayName(c, CompanionToIl.companionSig(c)) + ".";
				r.push(property(c, prefix + itemName, element, LInt32, ints.get, ints.set, element, ["key", "value"],
					MethodAttrs.PRIVATE | MethodAttrs.FINAL | MethodAttrs.VIRTUAL | MethodAttrs.HIDE_BY_SIG | MethodAttrs.NEW_SLOT | MethodAttrs.SPECIAL_NAME,
					prefix, get.pos));
			}
		}
		return r;
	}

	// The indexer accessors of the interfaces `c` lists (deep) that gencs gives an indexer (an interface's own
	// kept __get and __set, not a companion's), with their index and element types in `c`'s terms.
	static function interfaceAccessors(g:DotnetCtx, c:TClass):Array<{isSet:Bool, index:IlSigNorm, value:IlSigNorm}> {
		var r = [];
		function visit(i:TClass, params:Array<T>) {
			for (name in ["__get", "__set"]) {
				var f = i.fields.get(name);
				if (f == null) continue;
				for (o in [f].concat(f.overloads)) {
					if (CompanionToIl.isMember(g, i, o)) continue;
					var sig = try TclassToIl.functionSig(g, TypeFunctions.applyParams(i.params, params, o.type)) catch (_:Unsupported) null;
					if (sig == null) continue;
					if (name == "__get" && sig.args.length == 1) r.push({isSet: false, index: sig.args[0], value: sig.ret});
					if (name == "__set" && sig.args.length == 2) r.push({isSet: true, index: sig.args[0], value: sig.args[1]});
				}
			}
			for (sup in i.interfaces) visit(sup.c, [for (t in sup.params) TypeFunctions.applyParams(i.params, params, t)]);
		}
		for (i in c.interfaces) if (!TypeFunctions.hasClassFlag(i.c, CExtern)) visit(i.c, i.params);
		return r;
	}

	// Refuses an explicit accessor's cast from `from` to `to` that is not a box, an unbox or a reference cast.
	static function checkCast(c:TClass, from:IlSigNorm, to:IlSigNorm, pos:hxc.ast.Position):Void {
		if (IlPaths.sigEq(from, to) || !(isValueLike(from) && isValueLike(to))) return;
		var u = Unsupported.error("the element type of " + DotnetTypes.haxePath(TClassDecl(c)) + "'s array access (" + csName(c, to)
			+ ") is another value type than its __get's and __set's (" + csName(c, from) + "): the explicit indexer of its companion interface cannot cast between them");
		u.pos = pos;
		throw u;
	}

	static function isValueLike(s:IlSigNorm):Bool return DotnetTypes.isValueType(s) || s.match(LTypeParam(_));

	static function property(c:TClass, name:String, value:IlSigNorm, index:IlSigNorm, get:Null<TClassField>, set:Null<TClassField>,
			explicit:Null<IlSigNorm>, names:Array<String>, flags:Int, prefix:String, pos:hxc.ast.Position):PropertyPlan {
		var p:PropertyPlan = {
			cf: get != null ? get : set,
			name: name,
			sig: value,
			index: [index],
			getBody: null,
			setBody: null,
			getter: null,
			setter: null,
			token: 0
		};
		function accessor(isSet:Bool):MethodPlan {
			return {
				kind: MIndexer(get, set, isSet, explicit),
				name: prefix + (isSet ? "set_" : "get_") + itemName,
				flags: flags,
				hasThis: true,
				ret: isSet ? LVoid : value,
				args: isSet ? [index, value] : [index],
				argNames: isSet ? names : [names[0]],
				generics: [],
				pos: pos,
				token: 0
			};
		}
		if (get != null) p.getter = accessor(false);
		if (set != null) p.setter = accessor(true);
		return p;
	}

	// A type as gencs's t_s names it, for the order of the indexers: C#'s keywords for the primitive types,
	// a type parameter's name, `global::` and the path for any other.
	static function csName(c:TClass, s:IlSigNorm):String {
		return switch (s) {
			case LInt32: "int";
			case LUInt32: "uint";
			case LInt64: "long";
			case LUInt64: "ulong";
			case LFloat64: "double";
			case LFloat32: "float";
			case LBool: "bool";
			case LString: "string";
			case LObject: "object";
			case LChar: "char";
			case LTypeParam(i): c.params[i].name;
			case _: "global::" + (try TclassToIl.displayName(c, s) catch (_:Unsupported) Std.string(s));
		}
	}

	// The companion's members for the explicit indexer of the class `plan`: abstract get_Item and, when the
	// class has one, set_Item, and the Property `Item`. Null when the class implements none.
	public static function companionMembers(plan:ClassPlan):Null<{methods:Array<MethodPlan>, property:PropertyPlan}> {
		for (p in plan.properties) {
			var explicit = switch (p.getter != null ? p.getter.kind : p.setter.kind) {
				case MIndexer(_, _, _, e): e;
				case _: null;
			}
			if (explicit == null) continue;
			var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT | MethodAttrs.ABSTRACT
				| MethodAttrs.SPECIAL_NAME;
			var q:PropertyPlan = {
				cf: p.cf,
				name: itemName,
				sig: explicit,
				index: [LInt32],
				getBody: null,
				setBody: null,
				getter: null,
				setter: null,
				token: 0
			};
			function accessor(m:MethodPlan, isSet:Bool):MethodPlan {
				return {
					kind: MCompanionMember,
					name: (isSet ? "set_" : "get_") + itemName,
					flags: flags,
					hasThis: true,
					ret: m.ret,
					args: m.args,
					argNames: m.argNames,
					generics: [],
					pos: m.pos,
					token: 0
				};
			}
			var methods = [];
			if (p.getter != null) methods.push(q.getter = accessor(p.getter, false));
			if (p.setter != null) methods.push(q.setter = accessor(p.setter, true));
			return {methods: methods, property: q};
		}
		return null;
	}

	// [DefaultMember("Item")] on the TypeDef `token`, as C# puts it on a type that declares an indexer: after
	// the nullable rows and before the type's @:meta, as Roslyn orders them.
	public static function defaultMember(g:DotnetCtx, token:Int):Void {
		var ctor = AttributesToIl.runtimeAttr(g, "System.Reflection", "DefaultMemberAttribute", [ATString]);
		AttributesToIl.write(g, token, ctor, [AString(itemName)], [], true);
	}

	// An indexer's accessor (MIndexer), as C# compiles gencs's: `return this.__get(index);` and
	// `this.__set(index, value);`, `call` for a method that is not virtual; an explicit one boxes the element
	// and casts it back, and gets the MethodImpl row that makes it the companion's accessor.
	public static function emit(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, get:Null<TClassField>, set:Null<TClassField>, isSet:Bool,
			explicit:Null<IlSigNorm>, code:IlCode):Void {
		var target = g.methodPlans.get(isSet ? set : get);
		if (target == null) throw "internal error: no method for the indexer accessor " + m.name;
		var token = g.methodOf(plan, plan.thisSig, target);
		var op = target.flags & MethodAttrs.VIRTUAL != 0 ? IlOps.CALLVIRT : IlOps.CALL;
		code.ldarg(0);
		code.ldarg(1);
		if (isSet) {
			code.ldarg(2);
			if (explicit != null) castElement(g, explicit, target.args[1], code);
			code.opToken(op, token, 3, target.ret.match(LVoid) ? 0 : 1);
			if (!target.ret.match(LVoid)) code.op(IlOps.POP, 1, 0);
			code.op(IlOps.RET, 0, 0);
		} else {
			code.opToken(op, token, 2, 1);
			if (explicit != null) castElement(g, target.ret, explicit, code);
			code.op(IlOps.RET, 1, 0);
		}
		if (explicit == null) return;
		var companion = g.companionPlans.get(plan.c);
		var decl = null;
		if (companion != null) for (x in companion.methods) if (x.name == (isSet ? "set_" : "get_") + itemName) decl = x;
		if (decl == null) throw "internal error: the companion of " + plan.hxPath + " has no " + m.name;
		g.mb.methodImpl(plan.token, m.token, decl.token);
	}

	// C#'s cast between the element types of an explicit accessor and of __get or __set: a box, an unbox.any
	// or a castclass.
	static function castElement(g:DotnetCtx, from:IlSigNorm, to:IlSigNorm, code:IlCode):Void {
		if (IlPaths.sigEq(from, to)) return;
		var fromValue = isValueLike(from), toValue = isValueLike(to);
		if (fromValue && !toValue) {
			code.opToken(IlOps.BOX, g.typeTokenOf(from), 1, 1);
			if (!to.match(LObject)) code.opToken(IlOps.CASTCLASS, g.typeTokenOf(to), 1, 1);
		} else if (!fromValue && toValue) {
			code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
		} else if (!fromValue && !toValue) {
			if (!to.match(LObject)) code.opToken(IlOps.CASTCLASS, g.typeTokenOf(to), 1, 1);
		} else {
			throw "internal error: an explicit indexer's cast between two value types (checkCast)";
		}
	}
}
