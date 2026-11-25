package hxc.codegen.dotnet;

import haxe.ds.ObjectMap;
import haxe.ds.StringMap;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.TclassToIl;

// A C# event of a Haxe class or interface, as gencs's gen_event writes one for an @:event var of (default,
// default) access whose class has the methods add_X and remove_X (Filters.checkCsEvents makes sure it does).
// The event is the Event row `name` of the delegate type `sig`, with the public accessors `add_X(value)` and
// `remove_X(value)` (SpecialName, Static for a static event, Family for a @:protected var). The var `cf` has no
// field. A custom event's accessors call the private non-virtual bodies the Haxe methods become, `_add_X` and
// `_remove_X` (`addBody`, `removeBody`). Every Haxe use of add_X and remove_X calls the accessor, as gencs
// writes `s.X += h` and `s.X -= h`. Reading or assigning the var of a custom event is refused: C# lets an
// event with accessors of its own appear only on the left of `+=` and `-=` (CS0079).
//
// A field-like event (`fieldLike`: C# `event T X;`, gencs's when both Haxe bodies are empty) has no bodies: its
// accessors, which the C# compiler writes, combine the handler into a private `backing` field of the var's name
// with Delegate.Combine or Delegate.Remove in an Interlocked.CompareExchange loop, and are CompilerGenerated as
// the field is. Inside its own class the var is that field; anywhere else it has no value (CS0070). An
// interface's event (`isInterface`: C# `event T X;` in an interface) has abstract accessors, CompilerGenerated
// too, which are the interface's Haxe add_X and remove_X; the accessors of a class's event that implements one
// are virtual and sealed.
//
// Where gencs's C# fails to compile, hxc says so instead: an instance event of an hxgeneric class (CS0686), a Haxe
// override of an event's add_ or remove_ (CS0115), a read of a custom event's var (CS0079) and a read of a
// field-like event's var outside its class (CS0070) are errors, and the event's type must be a delegate
// (CS0066). A DCE that keeps the var and both methods together (Dce.eventSiblings) makes an event whose var
// Haxe never reads still an event, where gencs's C# fails (CS1061).
typedef EventPlan = {
	cf:TClassField,
	// The class or interface declaring the event.
	owner:TClass,
	isInterface:Bool,
	name:String,
	sig:IlSigNorm,
	isStatic:Bool,
	fieldLike:Bool,
	// The Haxe methods add_X and remove_X, and the private methods they become.
	addCf:TClassField,
	removeCf:TClassField,
	addBody:Null<MethodPlan>,
	removeBody:Null<MethodPlan>,
	adder:MethodPlan,
	remover:MethodPlan,
	backing:Null<FieldPlan>,
	// The Event row's token, set when the row is written.
	token:Int
};

class EventToIl {
	// An @:event var Haxe's check_cs_events and gencs's gen_event make a C# event of. Another access (haxeui's
	// builder macro turns its @:event vars into (default, set) ones) is a plain variable.
	public static function isEventVar(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Var(v): v.read == AccNormal && v.write == AccNormal && TypeFunctions.hasMeta(":event", cf.meta);
			case _: false;
		}
	}

	// The class's events (its extern ones are the .NET assembly's): the statics', then the instances', each
	// last declared first, as gencs declares them; the event of each add_X and remove_X (`bodies`, the bodies
	// of a custom event, which become private methods, and the methods an interface's or a field-like event's
	// accessors replace); and the vars (`vars`), which have no field but a field-like event's `backing`.
	// `implementing` holds the class's methods that implement a method of an interface it lists: an accessor of
	// those is virtual and sealed, as C# makes it.
	public static function planEvents(g:DotnetCtx, c:TClass, implementing:ObjectMap<TClassField, Bool>):{
		list:Array<EventPlan>,
		bodies:ObjectMap<TClassField, EventPlan>,
		vars:ObjectMap<TClassField, EventPlan>
	} {
		var list:Array<EventPlan> = [];
		var bodies = new ObjectMap<TClassField, EventPlan>();
		var vars = new ObjectMap<TClassField, EventPlan>();
		function collect(fields:Array<TClassField>, isStatic:Bool) {
			var table = isStatic ? c.statics : c.fields;
			var found:Array<EventPlan> = [];
			for (cf in fields) {
				if (!isEventVar(cf) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) continue;
				try {
					found.push(planEvent(g, c, cf, table, isStatic, implementing));
				} catch (u:Unsupported) {
					if (u.pos == null) u.pos = cf.pos;
					throw u;
				}
			}
			found.reverse();
			for (e in found) {
				list.push(e);
				vars.set(e.cf, e);
				bodies.set(e.addCf, e);
				bodies.set(e.removeCf, e);
			}
		}
		collect(c.orderedStatics, true);
		collect(c.orderedFields, false);
		return {list: list, bodies: bodies, vars: vars};
	}

	static function planEvent(g:DotnetCtx, c:TClass, cf:TClassField, table:StringMap<TClassField>, isStatic:Bool,
			implementing:ObjectMap<TClassField, Bool>):EventPlan {
		var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
		function method(prefix:String, isInterface:Bool):TClassField {
			var m = table.get(prefix + cf.name);
			if (m == null || !m.kind.match(Method(_))) throw Unsupported.bug("the @:event var " + cf.name + " has no method " + prefix + cf.name);
			// An interface's methods are abstract by being an interface's.
			if (m.overloads.length > 0 || m.params.length > 0 || !m.kind.match(Method(MethNormal | MethInline)) || !isInterface && TypeFunctions.hasClassFieldFlag(m, CfAbstract))
				throw new Unsupported("event methods that are overloaded, generic, dynamic or abstract (" + m.name + ")", true, m.pos);
			return m;
		}
		var sig = g.types.toSig(cf.type);
		if (!g.externs.isDelegateType(sig)) throw Unsupported.error("the type of the @:event var " + cf.name + " is no .NET delegate type (C# error CS0066)");
		var name = DotnetNames.fieldName(c, cf.name);
		var e:EventPlan = {
			cf: cf,
			owner: c,
			isInterface: isInterface,
			name: name,
			sig: sig,
			isStatic: isStatic,
			fieldLike: false,
			addCf: method("add_", isInterface),
			removeCf: method("remove_", isInterface),
			addBody: null,
			removeBody: null,
			adder: null,
			remover: null,
			backing: null,
			token: 0
		};
		// An interface's accessors are its Haxe methods add_X and remove_X, which have no bodies. A class's event is
		// field-like when both Haxe bodies are empty (gencs takes the kind from the one declared first, and drops
		// the other body).
		if (isInterface) {
			// A generic interface's method that mentions no type parameter is its companion's.
			if (CompanionToIl.isMember(g, c, e.addCf) || CompanionToIl.isMember(g, c, e.removeCf))
				throw new Unsupported("an @:event var of a generic interface (" + cf.name + ")", false);
		} else if (hasEmptyBody(e.addCf) && hasEmptyBody(e.removeCf)) {
			e.fieldLike = true;
			e.backing = {cf: cf, name: name, flags: FieldAttrs.PRIVATE | (isStatic ? FieldAttrs.STATIC : 0), sig: sig};
		}
		// gencs's get_fun_modifiers: @:protected on the var.
		var access = TypeFunctions.hasMeta(":protected", cf.meta) ? MethodAttrs.FAMILY : MethodAttrs.PUBLIC;
		function accessor(body:TClassField, isRemove:Bool):MethodPlan {
			var flags = access | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | (isStatic ? MethodAttrs.STATIC : 0);
			// C# makes the accessor of an event that implements an interface method final virtual.
			if (!isStatic && implementing.exists(body)) flags |= MethodAttrs.VIRTUAL | MethodAttrs.FINAL | MethodAttrs.NEW_SLOT;
			// An interface's are abstract: public virtual newslot abstract, no Family.
			if (isInterface) flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT | MethodAttrs.ABSTRACT;
			return {
				kind: MEventAccessor(e, isRemove),
				name: (isRemove ? "remove_" : "add_") + name,
				flags: flags,
				hasThis: !isStatic,
				ret: LVoid,
				args: [sig],
				argNames: ["value"],
				generics: [],
				pos: body.pos,
				token: 0
			};
		}
		e.adder = accessor(e.addCf, false);
		e.remover = accessor(e.removeCf, true);
		return e;
	}

	// gencs's is_empty_function: the body is `{}`.
	static function hasEmptyBody(cf:TClassField):Bool {
		return switch (cf.expr) {
			case {expr: TFunction(tf)}: tf.expr.expr.match(TBlock([]));
			case _: false;
		}
	}

	// The private body a Haxe add_X or remove_X became.
	public static function setBody(e:EventPlan, cf:TClassField, m:MethodPlan):Void {
		if (cf == e.addCf) e.addBody = m else e.removeBody = m;
	}

	// Whether the Haxe methods add_X and remove_X of the event `e` are written as no methods of their own: an
	// interface's and a field-like event's are the accessors.
	public static function isReplaced(e:EventPlan):Bool {
		return e.isInterface || e.fieldLike;
	}

	// The plan's Event rows and their accessors' MethodSemantics rows, after its methods' rows exist, and the
	// checks that need the whole class: errors where gencs's C# fails to compile.
	public static function write(g:DotnetCtx, plan:ClassPlan):Void {
		var mb = g.mb;
		for (e in plan.events) {
			e.token = mb.event(plan.token, e.name, TclassToIl.sigToken(g, e.sig));
			mb.methodSemantics(SemanticsAttrs.ADD_ON, e.adder.token, e.token);
			mb.methodSemantics(SemanticsAttrs.REMOVE_ON, e.remover.token, e.token);
			g.eventVars.set(e.cf, e);
			// Roslyn marks a field-like event's field and both accessors CompilerGenerated, and an interface's
			// accessors.
			if (isReplaced(e)) {
				var marked = [e.adder.token, e.remover.token];
				if (e.backing != null) marked.unshift(e.backing.token);
				AttributesToIl.compilerGenerated(g, marked);
			}
			// Every Haxe use of add_X and remove_X calls the public accessor, as gencs writes `o.X += h`.
			for (pair in [{cf: e.addCf, accessor: e.adder}, {cf: e.removeCf, accessor: e.remover}]) {
				g.ownerOf.set(pair.cf, plan);
				g.methodTokens.set(pair.cf, pair.accessor.token);
				g.methodPlans.set(pair.cf, pair.accessor);
				g.methodSigs.set(pair.cf, {ret: pair.accessor.ret, args: pair.accessor.args});
			}
			// The accessors of an instance event of an hxgeneric class would implement the add_ and remove_ of its
			// companion interface, which C# refuses.
			if (!plan.isStd && !e.isStatic && !e.isInterface && (CompanionToIl.isMember(g, plan.c, e.addCf) || CompanionToIl.isMember(g, plan.c, e.removeCf)))
				g.error("an @:event var of a generic class (" + plan.hxPath + "." + e.cf.name + ") is not supported (gencs: C# error CS0686)", e.cf.pos);
		}
		if (plan.c != null && !plan.isStd) for (m in plan.methods) switch (m.kind) {
			case MField(cf) if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)):
				var v = eventOfAccessor(plan.c, cf);
				if (v != null)
					g.error(plan.hxPath + "." + cf.name + " overrides the " + v.prefix + " method of the event " + DotnetTypes.haxePath(TClassDecl(v.owner)) + "."
						+ v.cf.name + ", which is no virtual method (gencs: C# error CS0115)", cf.pos);
			case _:
		}
	}

	// The @:event var a superclass of `c` declares that the add_ or remove_ method `cf` is a body of, the class
	// declaring it and the method's prefix.
	static function eventOfAccessor(c:TClass, cf:TClassField):Null<{cf:TClassField, owner:TClass, prefix:String}> {
		var prefix = StringTools.startsWith(cf.name, "add_") ? "add_" : StringTools.startsWith(cf.name, "remove_") ? "remove_" : null;
		if (prefix == null) return null;
		var name = cf.name.substr(prefix.length);
		var cur = c.superClass;
		while (cur != null) {
			var v = cur.c.fields.get(name);
			if (v != null) return isEventVar(v) && !TypeFunctions.hasClassFlag(cur.c, CExtern) ? {cf: v, owner: cur.c, prefix: prefix} : null;
			cur = cur.c.superClass;
		}
		return null;
	}

	// An accessor's body, as C# compiles gencs's `add { _add_X(value); }`: `ldarg.0; ldarg.1; call _add_X; ret`,
	// and for a static event `ldarg.0; call _add_X; ret`; a generic class's body is reached through its own
	// instantiation.
	public static function accessorBody(g:DotnetCtx, plan:ClassPlan, e:EventPlan, isRemove:Bool, code:IlCode):Void {
		if (e.fieldLike) {
			fieldLikeBody(g, plan, e, isRemove, code);
			return;
		}
		var body = isRemove ? e.removeBody : e.addBody;
		if (body == null) throw "internal error: the event " + e.name + " has an accessor without a body";
		if (!e.isStatic) code.ldarg(0);
		code.ldarg(e.isStatic ? 0 : 1);
		code.opToken(IlOps.CALL, g.methodOf(plan, plan.thisSig, body), e.isStatic ? 1 : 2, 0);
		code.op(IlOps.RET, 0, 0);
	}

	static final delegateSig:IlSigNorm = LClass({ns: ["System"], nested: [], name: "Delegate"}, []);
	static final interlockedPath:IlPath = {ns: ["System", "Threading"], nested: [], name: "Interlocked"};

	// A field-like event's accessor, as Roslyn compiles it (`T t0 = field; T t1; do { t1 = t0; T t2 =
	// (T)Delegate.Combine(t1, value); t0 = Interlocked.CompareExchange(ref field, t2, t1); } while (t0 != t1);`,
	// Remove for the remove accessor); a static event's reads and takes the address of the static field, and its
	// value is argument 0. A generic class's accessor reaches the field through the class's own instantiation.
	static function fieldLikeBody(g:DotnetCtx, plan:ClassPlan, e:EventPlan, isRemove:Bool, code:IlCode):Void {
		var f = e.backing;
		var fieldToken = plan.classParams.length == 0 ? f.token : g.mb.memberRef(g.typeTokenOf(plan.thisSig), f.name, g.sigs.field(f.sig));
		var t = e.sig;
		var combine = g.mb.memberRef(g.typeTokenOf(delegateSig), isRemove ? "Remove" : "Combine",
			g.sigs.method(false, delegateSig, [delegateSig, delegateSig], 0));
		var arg = LMethodTypeParam(0);
		var compareExchange = g.mb.methodSpec(g.mb.memberRef(g.typeTokenOf(LClass(interlockedPath, [])), "CompareExchange",
			g.sigs.method(false, arg, [LManagedPointer(arg), arg, arg], 1)), g.sigs.methodSpec([t]));
		var current = code.addLocal(t), seen = code.addLocal(t), combined = code.addLocal(t);
		var value = e.isStatic ? 0 : 1;
		function field(address:Bool) {
			if (e.isStatic) {
				code.opToken(address ? IlOps.LDSFLDA : IlOps.LDSFLD, fieldToken, 0, 1);
			} else {
				code.ldarg(0);
				code.opToken(address ? IlOps.LDFLDA : IlOps.LDFLD, fieldToken, 1, 1);
			}
		}
		field(false);
		code.stloc(current);
		var again = code.newLabel();
		code.mark(again);
		code.ldloc(current);
		code.stloc(seen);
		code.ldloc(seen);
		code.ldarg(value);
		code.opToken(IlOps.CALL, combine, 2, 1);
		code.opToken(IlOps.CASTCLASS, g.typeTokenOf(t), 1, 1);
		code.stloc(combined);
		field(true);
		code.ldloc(combined);
		code.ldloc(seen);
		code.opToken(IlOps.CALL, compareExchange, 3, 1);
		code.stloc(current);
		code.ldloc(current);
		code.ldloc(seen);
		code.branch(IlOps.BNE_UN, again);
		code.op(IlOps.RET, 0, 0);
	}

	// The class, `c` or one of its superclasses, that declares the field `cf`.
	static function declaringClass(c:TClass, cf:TClassField):TClass {
		var owner = c;
		while (owner.fields.get(cf.name) != cf && owner.statics.get(cf.name) != cf && owner.superClass != null) owner = owner.superClass.c;
		return owner;
	}

	// The error for a read or an assignment of the var `cf` of an event, reached through the class `c`: C# lets an
	// event with accessors of its own appear only on the left of `+=` and `-=` (CS0079).
	public static function noValue(c:TClass, cf:TClassField):Unsupported {
		return Unsupported.error("the event " + DotnetTypes.haxePath(TClassDecl(declaringClass(c, cf))) + "." + cf.name
			+ " has add_/remove_ bodies, so it has no value to read or assign (C# error CS0079)");
	}

	// Whether a read or an assignment of the var `cf` of an event, reached through the class `c` from the code
	// of `from`, is the access of a backing field. It is for a field-like event inside its own class; a custom
	// event's has no value (CS0079), and a field-like event's has none outside its class, a subclass and a
	// local function's class included (CS0070).
	public static function checkValue(g:DotnetCtx, from:Null<TClass>, c:TClass, cf:TClassField):Void {
		var e = g.eventVars.get(cf);
		if (e != null && e.isInterface)
			throw Unsupported.error("the event " + DotnetTypes.haxePath(TClassDecl(e.owner)) + "." + cf.name
				+ " is an interface event, so it has no value to read or assign (C# error CS0079)");
		// No plan: the owner's was not built (it is left out), so it is not known whether the event is custom or field-like.
		if (e == null)
			throw Unsupported.error("the event " + DotnetTypes.haxePath(TClassDecl(declaringClass(c, cf))) + "." + cf.name
				+ " has no value to read or assign here (C# error CS0079 for an event with add_/remove_ bodies, CS0070 outside its class"
				+ " for a field-like one)");
		if (!e.fieldLike) throw noValue(c, cf);
		if (from != e.owner) {
			var path = DotnetTypes.haxePath(TClassDecl(e.owner));
			throw Unsupported.error("the event " + path + "." + cf.name + " has empty add_/remove_ bodies, so it is field-like: only " + path
				+ " itself can read or assign it (C# error CS0070)");
		}
	}
}
