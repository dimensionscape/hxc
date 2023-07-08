package hxc.core;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Ref;
import hxc.core.Type;
import hxc.core.Globals.Path;
import hxc.core.TypeFunctions;
import hxc.core.NotFound;
import haxe.ds.StringMap;

/** Meta string names used by unification (parser stores them ':'-prefixed). */
class Meta {
	public static inline var CoreType = ":coreType";
	public static inline var Transitive = ":transitive";
	public static inline var MultiType = ":multiType";
	public static inline var ForwardVariance = ":forwardVariance";
	public static inline var FlatEnum = ":flatEnum";
	public static inline var Runtime = ":runtime";
	public static inline var MaybeUsed = ":maybeUsed";
	public static inline var Optional = ":optional";
	public static inline var From = ":from";
	public static inline var To = ":to";
	public static inline var ImplicitCast = ":implicitCast";
}

enum UnifyErrorKind {
	Cannot_unify(a:T, b:T);
	Invalid_field_type(s:String);
	Has_no_field(t:T, s:String);
	Has_no_runtime_field(t:T, s:String);
	Has_extra_field(t:T, s:String);
	Invalid_kind(s:String, a:FieldKind, b:FieldKind);
	Invalid_visibility(s:String);
	Not_matching_optional(s:String);
	Cant_force_optional;
	Invariant_parameter(i:Int);
	Constraint_failure(s:String);
	Missing_overload(cf:TClassField, t:T);
	FinalInvariance;
	Invalid_function_argument(index:Int, total:Int);
	Invalid_return_type;
	Unify_custom(s:String);
}

class UnifyError extends haxe.Exception {
	public var errors:Array<UnifyErrorKind>;
	public function new(errors:Array<UnifyErrorKind>) {
		super("Unify_error");
		this.errors = errors;
	}
}

enum EqKind {
	EqStrict;
	EqCoreType;
	EqRightDynamic;
	EqBothDynamic;
	EqDoNotFollowNull; // Like EqStrict, but does not follow Null<T>
}

@:structInit
class UnificationContext {
	public var allowTransitiveCast:Bool;
	public var allowAbstractCast:Bool;   // Allows a non-transitive abstract cast (from,to,@:from,@:to)
	public var allowDynamicToCast:Bool;  // Allows a cast from dynamic to non-dynamic
	public var equalityKind:EqKind;
	public var equalityUnderlying:Bool;
	public function new(allowTransitiveCast:Bool, allowAbstractCast:Bool, allowDynamicToCast:Bool,
			equalityKind:EqKind, equalityUnderlying:Bool) {
		this.allowTransitiveCast = allowTransitiveCast;
		this.allowAbstractCast = allowAbstractCast;
		this.allowDynamicToCast = allowDynamicToCast;
		this.equalityKind = equalityKind;
		this.equalityUnderlying = equalityUnderlying;
	}

	// A copy with the given equality kind.
	public function withEqualityKind(k:EqKind):UnificationContext {
		return new UnificationContext(allowTransitiveCast, allowAbstractCast, allowDynamicToCast, k, equalityUnderlying);
	}
	public function withAllowTransitiveCast(b:Bool):UnificationContext {
		return new UnificationContext(b, allowAbstractCast, allowDynamicToCast, equalityKind, equalityUnderlying);
	}
	public function withAllowAbstractCast(b:Bool):UnificationContext {
		return new UnificationContext(allowTransitiveCast, b, allowDynamicToCast, equalityKind, equalityUnderlying);
	}
	public function withEqualityUnderlying(b:Bool):UnificationContext {
		return new UnificationContext(allowTransitiveCast, allowAbstractCast, allowDynamicToCast, equalityKind, b);
	}
	// A copy that compares underlying types, both sides dynamic.
	public function withUnderlyingBothDynamic():UnificationContext {
		return new UnificationContext(allowTransitiveCast, allowAbstractCast, allowDynamicToCast, EqBothDynamic, true);
	}
}

enum UnifyMinResult {
	UnifyMinOk(t:T);
	UnifyMinError(l:Array<UnifyErrorKind>, i:Int);
}

@:structInit
class RecStack<A> {
	public var recStack:Array<A>;
	public function new() this.recStack = [];
}

enum UnificationMatrixState {
	STop;
	SType(t:T);
	SBottom;
}

// Unification_matrix (consumed by the typer overload/unifyMin).
// `dump` is omitted (TPrinting is a later port).
class UnificationMatrix {
	final values:Array<UnificationMatrixState>;

	public function new(arity:Int) {
		values = [for (_ in 0...arity) STop];
	}

	public function join(t:T, at:Int):Void {
		switch (values[at]) {
			case STop: values[at] = SType(t);
			case SBottom:
			case SType(t2): if (!TypeUnification.typeIseqDefault(t, t2)) values[at] = SBottom;
		}
	}

	public function getType(at:Int):Null<T> {
		return switch (values[at]) {
			case SType(t): t;
			case _: null;
		}
	}
}

class TypeUnification {
	static var eqStack:RecStack<{a:T, b:T}> = new RecStack();
	static var unifyStack:RecStack<{a:T, b:T}> = new RecStack();
	static var varianceStack:RecStack<{a:T, b:T}> = new RecStack();
	static var abstractCastStack:RecStack<{a:T, b:T}> = new RecStack();
	static var unifyNewMonos:RecStack<T> = new RecStack();

	public static function error(l:Array<UnifyErrorKind>):Dynamic {
		throw new UnifyError(l);
	}

	static function checkConstraint(name:String, f:Void->Void):Void {
		try {
			f();
		} catch (e:UnifyError) {
			throw new UnifyError([Constraint_failure(name)].concat(e.errors));
		}
	}

	public static var defaultUnificationContext(get, never):UnificationContext;
	static function get_defaultUnificationContext():UnificationContext {
		return {
			allowTransitiveCast: true,
			allowAbstractCast: true,
			allowDynamicToCast: true,
			equalityKind: EqStrict,
			equalityUnderlying: false
		};
	}

	static function isEmptyMap<V>(m:StringMap<V>):Bool {
		return !m.keys().hasNext();
	}

	static function fieldCount<V>(m:StringMap<V>):Int {
		var n = 0;
		for (_ in m.keys()) n++;
		return n;
	}

	static function anonClosed(a:TAnon):Bool {
		return switch (a.status.get()) {
			case Closed: true;
			case _: false;
		};
	}

	// Minimal type printer for the `close` recursive-type error message only.
	// TPrinting is a later port; the message text is not semantically load-bearing.
	static function sType(t:T):String {
		return switch (t) {
			case TMono(r): r.type == null ? "Unknown<0>" : sType(r.type);
			case TEnum(e, _): sPath(e.path);
			case TInst(c, _): sPath(c.path);
			case TType(d, _): sPath(d.path);
			case TAbstract(a, _): sPath(a.path);
			case TFun(_): "Function";
			case TAnon(_): "{...}";
			case TDynamic(_): "Dynamic";
			case TLazy(f): sType(TypeFunctions.lazyType(f));
		}
	}
	static function sPath(p:Path):String {
		return p.pack.length == 0 ? p.name : p.pack.join(".") + "." + p.name;
	}

	public static function monoCreate():TMono {
		return new TMono(null, [], []);
	}

	static function addUpConstraint(m:TMono, constr:TUpConstraint):Void {
		m.upConstraints = [constr].concat(m.upConstraints);
		switch (constr.t) {
			case TMono(m2):
				m2.downConstraints = ([MMono(m, constr.name)] : Array<TMonoConstraint>).concat(m2.downConstraints);
			case _:
		}
	}

	static function addDownConstraint(m:TMono, constr:TMonoConstraint):Void {
		m.downConstraints = [constr].concat(m.downConstraints);
		switch (constr) {
			case MMono(m2, s):
				m2.upConstraints = [{t: TMono(m), name: s}].concat(m.upConstraints);
			case _:
		}
	}

	static function constraintOfType(name:Null<String>, t:T):Array<TMonoConstraint> {
		return switch (TypeFunctions.follow(t)) {
			case TMono(m2):
				[MMono(m2, name)];
			case TAnon(an) if (!isEmptyMap(an.fields)):
				var l:Array<TMonoConstraint> = [];
				for (cf in an.fields) l.push(MField(cf));
				l;
			case TAnon(_):
				[MEmptyStructure];
			case _:
				[MType(t, name)];
		}
	}

	static function constrainToType(m:TMono, name:Null<String>, t:T):Void {
		for (c in constraintOfType(name, t)) addDownConstraint(m, c);
	}

	// Called by printing etc.; must not modify state.
	static function classify_down_constraints_(m:TMono):{monos:Array<TMono>, kind:TMonoConstraintKind} {
		var types:Array<TUpConstraint> = [];
		var fields = new StringMap<TClassField>();
		var is_open = false;
		var monos:Array<TMono> = [];

		function check(constr:TMonoConstraint):Void {
			switch (constr) {
				case MMono(m2, name):
					switch (m2.type) {
						case null:
							var res = classify_down_constraints_(m2);
							monos = monos.concat(res.monos);
							switch (res.kind) {
								case CUnknown:
									// Collect unconstrained monomorphs because we have to bind them.
									monos = [m2].concat(monos);
								case _:
									// Recursively inherit constraints.
									for (c in m2.downConstraints) check(c);
							}
						case some:
							for (c in constraintOfType(name, some)) check(c);
					}
				case MField(cf):
					fields.set(cf.name, cf);
				case MType(t2, name):
					types.push({t: t2, name: name});
				case MOpenStructure | MEmptyStructure:
					is_open = true;
			}
		}
		for (c in m.downConstraints) check(c);

		var k1:TMonoConstraintKind = types.length > 0 ? CTypes(types) : CUnknown;
		var kind:TMonoConstraintKind =
			if (!isEmptyMap(fields) || is_open) {
				var k2 = CStructural(fields, is_open);
				switch (k1) {
					case CTypes(_): CMixed([k1, k2]);
					case _: k2;
				}
			} else {
				k1;
			}
		return {monos: monos, kind: kind};
	}

	public static function classifyDownConstraints(m:TMono):TMonoConstraintKind {
		return classify_down_constraints_(m).kind;
	}

	static function checkDownConstraints(constr:TMonoConstraintKind, t:T):Void {
		switch (constr) {
			case CUnknown:
			case CTypes(tl):
				for (e in tl) {
					var t2 = e.t;
					var f = function() unify(defaultUnificationContext, t, t2);
					switch (e.name) {
						case null: f();
						case name: checkConstraint(name, f);
					}
				}
			case CStructural(fields, _is_open):
				var t2 = TypeFunctions.mkAnon(new Ref<AnonStatus>(Closed), fields);
				unify(defaultUnificationContext, t, t2);
			case CMixed(l):
				for (c in l) checkDownConstraints(c, t);
		}
	}

	static function collectUpConstraints(m:TMono):Array<TUpConstraint> {
		function collect(m:TMono, acc:Array<TUpConstraint>):Array<TUpConstraint> {
			for (uc in m.upConstraints) {
				switch (uc.t) {
					case TMono(m2):
						switch (m2.type) {
							case some if (some != null):
								switch (TypeFunctions.follow(some)) {
									case TMono(_): // Acc unchanged
									case _: acc = [uc].concat(acc);
								}
							case _:
								acc = collect(m2, acc);
						}
					case _:
						acc = [uc].concat(acc);
				}
			}
			return acc;
		}
		return collect(m, []);
	}

	static function checkUpConstraints(m:TMono, t:T):Void {
		for (uc in collectUpConstraints(m)) {
			var t2 = uc.t;
			var checkFn = function() unify(defaultUnificationContext, t2, t);
			switch (uc.name) {
				case null: checkFn();
				case name: checkConstraint(name, checkFn);
			}
		}
	}

	static function doBind(m:TMono, t:T):Void {
		m.type = t;
		m.downConstraints = [];
		m.upConstraints = [];
	}

	public static function monoBind(m:TMono, t:T):Void {
		switch (t) {
			case TAnon(_) if (listMemOpenStructure(m.downConstraints)):
				// Merge fields semantics
				constrainToType(m, null, t);
				close(m);
			case TMono(m2):
				if (m != m2) {
					switch (m2.type) {
						case null:
							for (c in m.downConstraints) addDownConstraint(m2, c);
							for (uc in m.upConstraints) addUpConstraint(m2, uc);
							doBind(m, t);
						case some:
							monoBind(m, some);
					}
				}
			case _:
				checkUpConstraints(m, t);
				// Due to recursive constraints (#9603), tentatively bind before checking.
				m.type = t;
				var kind = classifyDownConstraints(m);
				try {
					checkDownConstraints(kind, t);
				} catch (e:haxe.Exception) {
					m.type = null;
					throw e;
				}
				m.type = null;
				doBind(m, t);
		}
	}

	static function listMemOpenStructure(l:Array<TMonoConstraint>):Bool {
		for (c in l) switch (c) { case MOpenStructure: return true; case _: }
		return false;
	}

	public static function close(m:TMono):Void {
		switch (m.type) {
			case some if (some != null):
			case _:
				switch (classifyDownConstraints(m)) {
					case CUnknown:
					case CTypes(l) if (l.length == 1):
						doBind(m, l[0].t);
					case CTypes(_) | CMixed(_):
					case CStructural(fields, _):
						// Detect recursive type
						function checkRecursion(cf:TClassField):Void {
							function loop(t:T):T {
								return switch (t) {
									case TMono(m2) if (m == m2):
										var s = sType(t) + " appears in { " + cf.name + ": " + sType(cf.type) + " }";
										throw new UnifyError([Unify_custom("Recursive type"), Unify_custom(s)]);
									case _:
										TypeFunctions.map(loop, t);
								}
							}
							loop(cf.type);
						}
						for (cf in fields) checkRecursion(cf);
						doBind(m, TypeFunctions.mkAnon(new Ref<AnonStatus>(Closed), fields));
				}
		}
	}

	public static function unbind(m:TMono):Void {
		m.type = null;
	}

	public static function spawnConstrainedMonos(map:T->T, params:TypeParams):Array<T> {
		var checks:Array<{mono:TMono, constr:Array<T>, path:String}> = [];
		var monos:Array<T> = [for (tp in params) {
			var mono = monoCreate();
			switch (TypeFunctions.follow(tp.type)) {
				case TInst(c, _) if (isTypeParamWithConstraints(c)):
					switch (c.kind) {
						case KTypeParameter(constr) if (constr.length != 0):
							checks.push({mono: mono, constr: constr, path: sPath(c.path)});
						case _:
					}
				case _:
			}
			TMono(mono);
		}];
		function map2(t:T):T return map(TypeFunctions.applyParams(params, monos, t));
		for (chk in checks) {
			for (t in chk.constr) constrainToType(chk.mono, chk.path, map2(t));
		}
		return monos;
	}

	static inline function isTypeParamWithConstraints(c:TClass):Bool {
		return switch (c.kind) { case KTypeParameter(constr): constr.length != 0; case _: false; }
	}

	public static function followAndClose(t:T):T {
		var ft = TypeFunctions.follow(t);
		return switch (ft) {
			case TMono(r):
				close(r);
				if (r.type != null) followAndClose(ft) else ft;
			case _: ft;
		}
	}

	static function link(e:TMono, a:T, b:T):Bool {
		// Tell if setting a == b will create a type-loop
		function loop(t:T):Bool {
			if (t == a) return true;
			return switch (t) {
				case TMono(tm):
					switch (tm.type) { case null: false; case some: loop(some); }
				case TEnum(_, tl):
					Lambda.exists(tl, loop);
				case TInst(_, tl) | TType(_, tl) | TAbstract(_, tl):
					Lambda.exists(tl, loop);
				case TFun(sig):
					{
						var found = false;
						for (arg in sig.args) if (loop(arg.t)) { found = true; break; }
						found || loop(sig.ret);
					}
				case TDynamic(null):
					false;
				case TDynamic(t2):
					loop(t2);
				case TLazy(f):
					loop(TypeFunctions.lazyType(f));
				case TAnon(an):
					var found = false;
					for (cf in an.fields) if (loop(cf.type)) { found = true; break; }
					found;
			}
		}
		// Tell if already a ~= b
		if (loop(b)) {
			return TypeFunctions.follow(b) == a;
		} else if (b == TypeFunctions.tDynamic) {
			return true;
		} else {
			monoBind(e, b);
			return true;
		}
	}

	static function linkDynamic(a:T, b:T):Void {
		switch [TypeFunctions.follow(a), TypeFunctions.follow(b)] {
			case [TMono(r), TDynamic(_)]: monoBind(r, b);
			case [TDynamic(_), TMono(r)]: monoBind(r, a);
			case _:
		}
	}

	static function fastEqCheck(type_param_check:T->T->Bool, a:T, b:T):Bool {
		if (a == b) return true;
		return switch [a, b] {
			case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length):
				var ok = true;
				for (i in 0...s1.args.length) if (!type_param_check(s1.args[i].t, s2.args[i].t)) { ok = false; break; }
				ok && type_param_check(s1.ret, s2.ret);
			case [TType(t1, l1), TType(t2, l2)]:
				t1 == t2 && forAll2(type_param_check, l1, l2);
			case [TEnum(e1, l1), TEnum(e2, l2)]:
				e1 == e2 && forAll2(type_param_check, l1, l2);
			case [TInst(c1, l1), TInst(c2, l2)]:
				c1 == c2 && forAll2(type_param_check, l1, l2);
			case [TAbstract(a1, l1), TAbstract(a2, l2)]:
				a1 == a2 && forAll2(type_param_check, l1, l2);
			case _:
				false;
		}
	}

	static function forAll2(f:T->T->Bool, l1:Array<T>, l2:Array<T>):Bool {
		if (l1.length != l2.length) return false;
		for (i in 0...l1.length) if (!f(l1[i], l2[i])) return false;
		return true;
	}

	public static function fastEq(a:T, b:T):Bool return fastEqCheck(fastEq, a, b);

	static function fastEqPair(a:T, b:T, a2:T, b2:T):Bool return fastEq(a, a2) && fastEq(b, b2);

	static function fastEqUnboundMono(a:T, b:T):Bool {
		return switch [a, b] {
			case [TMono(m1), TMono(m2)] if (m1.type == null && m2.type == null): true;
			case _: fastEqCheck(fastEqUnboundMono, a, b);
		}
	}

	static function fastEqMono(ml:Array<T>, a:T, b:T):Bool {
		if (fastEqCheck(fastEqMono.bind(ml), a, b)) return true;
		return switch [a, b] {
			case [TMono(_), _]: memq(a, ml);
			case _: false;
		}
	}

	static function memq<X>(v:X, l:Array<X>):Bool {
		for (x in l) if (x == v) return true;
		return false;
	}

	public static function shallowEq(a:T, b:T):Bool {
		if (a == b) return true;
		var fa = TypeFunctions.follow(a);
		var fb = TypeFunctions.follow(b);
		if (fastEqCheck(shallowEq, fa, fb)) return true;
		return switch [fa, fb] {
			case [t, TMono(m)] if (m.type == null && t == TypeFunctions.tDynamic): true;
			case [TMono(m), t] if (m.type == null && t == TypeFunctions.tDynamic): true;
			case [TMono(m1), TMono(m2)] if (m1.type == null && m2.type == null): true;
			case [TAnon(a1), TAnon(a2)]:
				function fieldsEq():Bool {
					var fields1:Array<TClassField> = [for (f in a1.fields) f];
					var fields2:Array<TClassField> = [for (f in a2.fields) f];
					fields1.sort(function(x, y) return Reflect.compare(x.name, y.name));
					fields2.sort(function(x, y) return Reflect.compare(x.name, y.name));
					if (fields1.length != fields2.length) return false;
					for (i in 0...fields1.length) {
						var f1 = fields1[i], f2 = fields2[i];
						if (f1.name != f2.name) return false;
						var ok = try shallowEq(f1.type, f2.type) catch (e:NotFound) false;
						if (!ok) return false;
					}
					return true;
				}
				switch [a2.status.get(), a1.status.get()] {
					case [Statics(c), Statics(c2)]: c == c2;
					case [EnumStatics(e), EnumStatics(e2)]: e == e2;
					case [AbstractStatics(ab), AbstractStatics(ab2)]: ab == ab2;
					case [Extend(tl1), Extend(tl2)]: fieldsEq() && forAll2(shallowEq, tl1, tl2);
					case [Closed, Closed]: fieldsEq();
					case [Const, Const]: fieldsEq();
					case _: false;
				}
			case _:
				false;
		}
	}

	static inline function cannotUnify(a:T, b:T):UnifyErrorKind return Cannot_unify(a, b);
	static inline function invalidField(n:String):UnifyErrorKind return Invalid_field_type(n);
	static inline function invalidKind(n:String, a:FieldKind, b:FieldKind):UnifyErrorKind return Invalid_kind(n, a, b);
	static inline function invalidVisibility(n:String):UnifyErrorKind return Invalid_visibility(n);
	static inline function hasNoField(t:T, n:String):UnifyErrorKind return Has_no_field(t, n);
	static inline function hasExtraField(t:T, n:String):UnifyErrorKind return Has_extra_field(t, n);

	static function unifyAccess(a1:VarAccess, a2:VarAccess):Bool {
		if (Type.enumEq(a1, a2)) return true;
		return switch [a1, a2] {
			case [_, AccNo] | [_, AccNever]: true;
			case [AccInline, AccNormal]: true;
			case _: false;
		}
	}

	static function directAccess(a:VarAccess):Bool {
		return switch (a) {
			case AccNo | AccNever | AccNormal | AccInline | AccRequire(_, _) | AccCtor: true;
			case AccCall: false;
		}
	}

	static function unifyKind(k1:FieldKind, k2:FieldKind):Bool {
		if (fieldKindEq(k1, k2)) return true;
		return switch [k1, k2] {
			case [Var(v1), Var(v2)]:
				unifyAccess(v1.read, v2.read) && unifyAccess(v1.write, v2.write);
			case [Var(v), Method(m)]:
				switch [v.read, v.write, m] {
					case [AccNormal, _, MethNormal]: true;
					case [AccNormal, AccNormal, MethDynamic]: true;
					case _: false;
				}
			case [Method(m), Var(v)]:
				switch (m) {
					case MethDynamic: directAccess(v.read) && directAccess(v.write);
					case MethMacro: false;
					case MethNormal | MethInline:
						switch [v.read, v.write] {
							case [AccNormal, AccNo] | [AccNormal, AccNever]: true;
							case _: false;
						}
				}
			case [Method(m1), Method(m2)]:
				switch [m1, m2] {
					case [MethInline, MethNormal] | [MethDynamic, MethNormal]: true;
					case _: false;
				}
		}
	}

	// Structural equality for VarAccess (handles AccRequire payloads).
	static function varAccessEq(a:VarAccess, b:VarAccess):Bool {
		return switch [a, b] {
			case [AccRequire(s1, m1), AccRequire(s2, m2)]: s1 == s2 && m1 == m2;
			case _: Type.enumEq(a, b);
		}
	}
	static function fieldKindEq(k1:FieldKind, k2:FieldKind):Bool {
		return switch [k1, k2] {
			case [Var(v1), Var(v2)]: varAccessEq(v1.read, v2.read) && varAccessEq(v1.write, v2.write);
			case [Method(m1), Method(m2)]: Type.enumEq(m1, m2);
			case _: false;
		}
	}

	static function recStackExists<A>(f:A->Bool, s:RecStack<A>):Bool {
		for (v in s.recStack) if (f(v)) return true;
		return false;
	}

	static function recStackLoop<A, R>(stack:RecStack<A>, value:A, f:Void->R):R {
		stack.recStack = [value].concat(stack.recStack);
		try {
			var r = f();
			stack.recStack = stack.recStack.slice(1);
			return r;
		} catch (e:haxe.Exception) {
			stack.recStack = stack.recStack.slice(1);
			throw e;
		}
	}

	static function recStack<A, R>(stack:RecStack<A>, value:A, fcheck:A->Bool, frun:Void->R, ferror:Array<UnifyErrorKind>->R):R {
		if (!recStackExists(fcheck, stack)) {
			stack.recStack = [value].concat(stack.recStack);
			try {
				var v = frun();
				stack.recStack = stack.recStack.slice(1);
				return v;
			} catch (e:UnifyError) {
				stack.recStack = stack.recStack.slice(1);
				return ferror(e.errors);
			} catch (e:haxe.Exception) {
				stack.recStack = stack.recStack.slice(1);
				throw e;
			}
		}
		// All call sites here are unit-returning (R = Void via Dynamic); return null.
		return null;
	}

	static function recStackDefault<A, R>(stack:RecStack<A>, value:A, fcheck:A->Bool, frun:Void->R, def:R):R {
		if (!recStackExists(fcheck, stack)) return recStackLoop(stack, value, frun);
		else return def;
	}

	public static function typeEq(uctx:UnificationContext, a:T, b:T):Void {
		var param = uctx.equalityKind;
		function canFollow(t:T):Bool {
			return switch (param) {
				case EqCoreType: false;
				case EqDoNotFollowNull: !TypeFunctions.isExplicitNull(t);
				case _: true;
			}
		}
		function canFollowAbstract(ab:TAbstract):Bool {
			return uctx.equalityUnderlying && switch (ab.thisType) {
				case TAbstract(ab2, _): ab2 != ab;
				case _: true;
			}
		}
		if (a == b) return;
		switch [a, b] {
			case [TLazy(f), _]: typeEq(uctx, TypeFunctions.lazyType(f), b);
			case [_, TLazy(f)]: typeEq(uctx, a, TypeFunctions.lazyType(f));
			case [TMono(t), _]:
				switch (t.type) {
					case null: if (param == EqCoreType || !link(t, a, b)) error([cannotUnify(a, b)]);
					case some: typeEq(uctx, some, b);
				}
			case [_, TMono(t)]:
				switch (t.type) {
					case null: if (param == EqCoreType || !link(t, b, a)) error([cannotUnify(a, b)]);
					case some: typeEq(uctx, a, some);
				}
			case [TDynamic(null), TDynamic(null)]:
			case [TDynamic(a2), TDynamic(b2)] if (a2 != null && b2 != null):
				typeEq(uctx, a2, b2);
			case [_, _] if (a == TypeFunctions.tDynamic && param == EqBothDynamic):
			case [_, _] if (b == TypeFunctions.tDynamic && (param == EqRightDynamic || param == EqBothDynamic)):
			case [TAbstract(a1, [t1]), TAbstract(a2, [t2])] if (isNullPath(a1.path) && isNullPath(a2.path)):
				typeEq(uctx, t1, t2);
			case [TAbstract(a1, [t1]), _] if (isNullPath(a1.path) && param != EqDoNotFollowNull):
				typeEq(uctx, t1, b);
			case [_, TAbstract(a2, [t2])] if (isNullPath(a2.path) && param != EqDoNotFollowNull):
				typeEq(uctx, a, t2);
			case [TType(t1, tl1), TType(t2, tl2)] if ((t1 == t2 || (param == EqCoreType && pathEq(t1.path, t2.path))) && tl1.length == tl2.length):
				typeEqParams(uctx, a, b, tl1, tl2);
			case [TType(t1, tl1), _] if (canFollow(a)):
				recStack(eqStack, {a: a, b: b}, function(p) return fastEqPair(a, b, p.a, p.b),
					function() { TypeFunctions.tryApplyParamsRec(t1.params, tl1, t1.type, function(ax) typeEq(uctx, ax, b)); return null; },
					function(l) { error([cannotUnify(a, b)].concat(l)); return null; });
			case [_, TType(t2, tl2)] if (canFollow(b)):
				recStack(eqStack, {a: a, b: b}, function(p) return fastEqPair(a, b, p.a, p.b),
					function() { TypeFunctions.tryApplyParamsRec(t2.params, tl2, t2.type, function(bx) typeEq(uctx, a, bx)); return null; },
					function(l) { error([cannotUnify(a, b)].concat(l)); return null; });
			case [TEnum(e1, tl1), TEnum(e2, tl2)]:
				if (e1 != e2 && !(param == EqCoreType && pathEq(e1.path, e2.path))) error([cannotUnify(a, b)]);
				typeEqParams(uctx, a, b, tl1, tl2);
			case [TInst(c1, tl1), TInst(c2, tl2)]:
				if (c1 != c2 && !(param == EqCoreType && pathEq(c1.path, c2.path))
					&& (switch [c1.kind, c2.kind] { case [KExpr(_), KExpr(_)]: false; case _: true; }))
					error([cannotUnify(a, b)]);
				typeEqParams(uctx, a, b, tl1, tl2);
			case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length):
				var i = 0;
				try {
					typeEq(uctx, s1.ret, s2.ret);
					for (k in 0...s1.args.length) {
						i++;
						var a1 = s1.args[k], a2 = s2.args[k];
						if (a1.opt != a2.opt) error([Not_matching_optional(a1.name)]);
						typeEq(uctx, a1.t, a2.t);
					}
				} catch (e:UnifyError) {
					var msg:UnifyErrorKind = i == 0 ? Invalid_return_type : Invalid_function_argument(i, s1.args.length);
					error([cannotUnify(a, b), msg].concat(e.errors));
				}
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)] if (a1 == a2 || (param == EqCoreType && pathEq(a1.path, a2.path))):
				typeEqParams(uctx, a, b, tl1, tl2);
			case [TAbstract(ab, tl), _] if (canFollowAbstract(ab)):
				typeEq(uctx, TypeFunctions.applyParams(ab.params, tl, ab.thisType), b);
			case [_, TAbstract(ab, tl)] if (canFollowAbstract(ab)):
				typeEq(uctx, a, TypeFunctions.applyParams(ab.params, tl, ab.thisType));
			case [TAnon(a1), TAnon(a2)]:
				try {
					switch (a2.status.get()) {
						case Statics(c): switch (a1.status.get()) { case Statics(c2) if (c == c2): case _: error([]); }
						case EnumStatics(e): switch (a1.status.get()) { case EnumStatics(e2) if (e == e2): case _: error([]); }
						case AbstractStatics(ab): switch (a1.status.get()) { case AbstractStatics(ab2) if (ab == ab2): case _: error([]); }
						case _:
					}
					for (n in a1.fields.keys()) {
						var f1 = a1.fields.get(n);
						if (!a2.fields.exists(n)) {
							error([hasNoField(b, n)]);
						}
						var f2 = a2.fields.get(n);
						if (!fieldKindEq(f1.kind, f2.kind) && (param == EqStrict || param == EqCoreType || !unifyKind(f1.kind, f2.kind)))
							error([invalidKind(n, f1.kind, f2.kind)]);
						try {
							typeEq(uctx, f1.type, f2.type);
						} catch (e:UnifyError) {
							error([invalidField(n)].concat(e.errors));
						}
						if (TypeFunctions.hasClassFieldFlag(f1, CfPublic) != TypeFunctions.hasClassFieldFlag(f2, CfPublic))
							error([invalidVisibility(n)]);
					}
					for (n in a2.fields.keys()) {
						if (!a1.fields.exists(n)) error([hasNoField(a, n)]);
					}
				} catch (e:UnifyError) {
					error([cannotUnify(a, b)].concat(e.errors));
				}
			case _:
				error([cannotUnify(a, b)]);
		}
	}

	static function typeEqParams(uctx:UnificationContext, a:T, b:T, tl1:Array<T>, tl2:Array<T>):Void {
		var i = 0;
		for (k in 0...tl1.length) {
			i++;
			try {
				typeEq(uctx, tl1[k], tl2[k]);
			} catch (e:UnifyError) {
				error([cannotUnify(a, b), Invariant_parameter(i)].concat(e.errors));
			}
		}
	}

	public static function typeIseq(uctx:UnificationContext, a:T, b:T):Bool {
		return try { typeEq(uctx, a, b); true; } catch (e:UnifyError) false;
	}

	public static function typeIseqStrict(a:T, b:T):Bool {
		return try {
			typeEq(defaultUnificationContext.withEqualityKind(EqDoNotFollowNull), a, b);
			true;
		} catch (e:UnifyError) false;
	}

	public static function unify(uctx:UnificationContext, a:T, b:T):Void {
		if (a == b) return;
		switch [a, b] {
			case [TLazy(f), _]: unify(uctx, TypeFunctions.lazyType(f), b);
			case [_, TLazy(f)]: unify(uctx, a, TypeFunctions.lazyType(f));
			case [TMono(t), _]:
				switch (t.type) {
					case null: if (!link(t, a, b)) error([cannotUnify(a, b)]);
					case some: unify(uctx, some, b);
				}
			case [_, TMono(t)]:
				switch (t.type) {
					case null: if (!link(t, b, a)) error([cannotUnify(a, b)]);
					case some: unify(uctx, a, some);
				}
			case [TType(t, tl), _]:
				recStack(unifyStack, {a: a, b: b},
					function(p) return fastEqUnboundMono(a, p.a) && fastEq(b, p.b),
					function() { TypeFunctions.tryApplyParamsRec(t.params, tl, t.type, function(ax) unify(uctx, ax, b)); return null; },
					function(l) { error([cannotUnify(a, b)].concat(l)); return null; });
			case [_, TType(t, tl)]:
				recStack(unifyStack, {a: a, b: b},
					function(p) return fastEq(a, p.a) && fastEqUnboundMono(b, p.b),
					function() { TypeFunctions.tryApplyParamsRec(t.params, tl, t.type, function(bx) unify(uctx, a, bx)); return null; },
					function(l) { error([cannotUnify(a, b)].concat(l)); return null; });
			case [TEnum(ea, tl1), TEnum(eb, tl2)]:
				if (ea != eb) error([cannotUnify(a, b)]);
				unifyTypeParams(uctx, a, b, tl1, tl2);
			case [TAbstract(a1, [t1]), _] if (isNullPath(a1.path)):
				try unify(uctx, t1, b) catch (e:UnifyError) error([cannotUnify(a, b)].concat(e.errors));
			case [_, TAbstract(a2, [t2])] if (isNullPath(a2.path)):
				try unify(uctx, a, t2) catch (e:UnifyError) error([cannotUnify(a, b)].concat(e.errors));
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)] if (a1 == a2):
				try {
					unifyTypeParams(uctx, a, b, tl1, tl2);
				} catch (err:UnifyError) {
					// The type could still have a from/to relation to itself (issue #3494)
					try {
						unifyAbstracts(uctx, a, b, a1, tl1, a2, tl2);
					} catch (e2:UnifyError) {
						throw err;
					}
				}
			case [TAbstract(a1, _), _] if (isVoidPath(a1.path)):
				error([cannotUnify(a, b)]);
			case [_, TAbstract(a2, _)] if (isVoidPath(a2.path)):
				error([cannotUnify(a, b)]);
			case [TAbstract(a1, []), _] if (isHaxePath(a1.path, "NotVoid")):
			case [_, TAbstract(a2, [])] if (isHaxePath(a2.path, "NotVoid")):
			case [TAbstract(ab, tl), TAbstract(a2, _)] if (isHaxePath(a2.path, "FlatEnum") || isHaxePath(a2.path, "Function") || isHaxePath(a2.path, "Constructible")):
				unifyTo(uctx.withAllowTransitiveCast(false), a, b, ab, tl);
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)]:
				unifyAbstracts(uctx, a, b, a1, tl1, a2, tl2);
			case [TInst(c1, tl1), TInst(c2, tl2)]:
				function loop(c:TClass, tl:Array<T>):Bool {
					if (c == c2) {
						unifyTypeParams(uctx, a, b, tl, tl2);
						return true;
					}
					var bySuper = switch (c.superClass) {
						case null: false;
						case s: loop(s.c, [for (x in s.params) TypeFunctions.applyParams(c.params, tl, x)]);
					}
					if (bySuper) return true;
					for (impl in c.interfaces) {
						if (loop(impl.c, [for (x in impl.params) TypeFunctions.applyParams(c.params, tl, x)])) return true;
					}
					return switch (c.kind) {
						case KTypeParameter(pl):
							var found = false;
							for (t in pl) {
								switch (TypeFunctions.follow(t)) {
									case TInst(cs, tls):
										if (loop(cs, [for (x in tls) TypeFunctions.applyParams(c.params, tl, x)])) { found = true; break; }
									case TAbstract(aa, tla):
										if (unifiesTo(uctx, a, b, aa, tla)) { found = true; break; }
									case _:
								}
							}
							found;
						case _: false;
					}
				}
				if (!loop(c1, tl1)) error([cannotUnify(a, b)]);
			case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length):
				var uctx2 = get_nested_context(uctx);
				var i = 0;
				try {
					switch (TypeFunctions.follow(s2.ret)) {
						case TAbstract(av, _) if (isVoidPath(av.path)): i++;
						case _: unify(uctx2, s1.ret, s2.ret); i++;
					}
					// Contravariance: iterate l2,l1 zipped
					for (k in 0...s2.args.length) {
						var a2 = s2.args[k], a1 = s1.args[k];
						if (a2.opt && !a1.opt) error([Cant_force_optional]);
						unify(uctx2, a2.t, a1.t);
						i++;
					}
				} catch (e:UnifyError) {
					var msg:UnifyErrorKind = i == 0 ? Invalid_return_type : Invalid_function_argument(i, s1.args.length);
					error([cannotUnify(a, b), msg].concat(e.errors));
				}
			case [TInst(c, tl), TAnon(an)]:
				if (isEmptyMap(an.fields)) {
					switch (c.kind) {
						case KTypeParameter(pl):
							// One of the constraints must unify with { }
							if (!Lambda.exists(pl, function(t) return switch (TypeFunctions.follow(t)) { case TInst(_, _) | TAnon(_): true; case _: false; }))
								error([cannotUnify(a, b)]);
						case _:
					}
				}
				c.build();
				try {
					for (n in an.fields.keys()) {
						var f2 = an.fields.get(n);
						// Introducing monomorphs while unifying might create infinite loops (#2315)
						var monos:Array<T> = [];
						function makeType(f:TClassField):T {
							return switch (f.params) {
								case []: f.type;
								case l:
									var ml = [for (_ in l) TypeFunctions.mkMono()];
									monos = ml;
									TypeFunctions.applyParams(f.params, ml, f.type);
							}
						}
						var rcf = try TypeFunctions.rawClassField(makeType, c, tl, n) catch (e:NotFound) { error([hasNoField(a, n)]); null; }
						var f1 = rcf.f;
						var ft = TypeFunctions.applyParams(c.params, tl, rcf.t);
						if (!unifyKind(f1.kind, f2.kind)) error([invalidKind(n, f1.kind, f2.kind)]);
						if (TypeFunctions.hasClassFieldFlag(f2, CfPublic) && !TypeFunctions.hasClassFieldFlag(f1, CfPublic))
							error([invalidVisibility(n)]);

						switch (f2.kind) {
							case Var(vk) if (switch (vk.read) { case AccNo | AccNever: true; case _: false; }):
								// Write target: recursive unification with possible recursion check
								var old_monos = unifyNewMonos.recStack;
								unifyNewMonos.recStack = monos.concat(unifyNewMonos.recStack);
								recStack(unifyStack, {a: ft, b: f2.type},
									function(p) return fastEq(p.b, f2.type) && fastEqMono(unifyNewMonos.recStack, ft, p.a),
									function() { try unifyWithAccess(uctx, f1, ft, f2) catch (e:haxe.Exception) { unifyNewMonos.recStack = old_monos; throw e; } return null; },
									function(l) { error([invalidField(n)].concat(l)); return null; });
								unifyNewMonos.recStack = old_monos;
							case Method(MethNormal) | Method(MethInline) | Var({write: AccNo}) | Var({write: AccNever}):
								// Read-only var: reversed unification
								var old_monos = unifyNewMonos.recStack;
								unifyNewMonos.recStack = monos.concat(unifyNewMonos.recStack);
								recStack(unifyStack, {a: f2.type, b: ft},
									function(p) return fastEqMono(unifyNewMonos.recStack, p.b, ft) && fastEq(f2.type, p.a),
									function() { try unifyWithAccess(uctx, f1, ft, f2) catch (e:haxe.Exception) { unifyNewMonos.recStack = old_monos; throw e; } return null; },
									function(l) { error([invalidField(n)].concat(l)); return null; });
								unifyNewMonos.recStack = old_monos;
							case _:
								try unifyWithAccess(uctx, f1, ft, f2)
								catch (e:UnifyError) error([invalidField(n)].concat(e.errors));
						}

						for (f2o in f2.overloads) {
							var matched = false;
							var cands = [f1].concat(f1.overloads);
							for (f1o in cands) if (typeIseq(uctx, f1o.type, f2o.type)) { matched = true; break; }
							if (!matched) error([Missing_overload(f1, f2o.type)]);
						}
						if (!TypeFunctions.hasMeta(Meta.MaybeUsed, f1.meta)) {
							f1.meta = ([{name: Meta.MaybeUsed, params: [], pos: f1.pos}] : Metadata).concat(f1.meta);
							switch (f2.kind) {
								case Var(vk):
									function checkAccessor(name:String):Void {
										try {
											var cf = TypeFunctions.rawClassField(makeType, c, tl, name).f;
											if (!TypeFunctions.hasMeta(Meta.MaybeUsed, cf.meta))
												cf.meta = ([{name: Meta.MaybeUsed, params: [], pos: f1.pos}] : Metadata).concat(cf.meta);
										} catch (e:NotFound) {}
									}
									switch (vk.read) { case AccCall: checkAccessor("get_" + f1.name); case _: }
									switch (vk.write) { case AccCall: checkAccessor("set_" + f1.name); case _: }
								case _:
							}
						}
						switch (f1.kind) {
							case Method(MethInline):
								if ((TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFieldFlag(f1, CfExtern)) && !TypeFunctions.hasMeta(Meta.Runtime, f1.meta))
									error([Has_no_runtime_field(a, n)]);
							case _:
						}
					}
					switch (an.status.get()) {
						case Statics(_) | EnumStatics(_) | AbstractStatics(_): error([]);
						case Closed | Extend(_) | Const:
					}
				} catch (e:UnifyError) {
					error([cannotUnify(a, b)].concat(e.errors));
				}
			case [TAnon(a1), TAnon(a2)]:
				unifyAnons(uctx, a, b, a1, a2);
			case [TAnon(an), TAbstract(ab, [pt])] if (isEmptyPath(ab.path, "Class")):
				switch (an.status.get()) {
					case Statics(cl): unify(uctx, TInst(cl, [for (_ in cl.params) TypeFunctions.mkMono()]), pt);
					case _: error([cannotUnify(a, b)]);
				}
			case [TAnon(an), TAbstract(ab, [pt])] if (isEmptyPath(ab.path, "Enum")):
				switch (an.status.get()) {
					case EnumStatics(e): unify(uctx, TEnum(e, [for (_ in e.params) TypeFunctions.mkMono()]), pt);
					case _: error([cannotUnify(a, b)]);
				}
			case [TEnum(_, _), TAbstract(ab, [])] if (isEmptyPath(ab.path, "EnumValue")):
			case [TEnum(en, _), TAbstract(ab, [])] if (isHaxePath(ab.path, "FlatEnum") && TypeFunctions.hasMeta(Meta.FlatEnum, en.meta)):
			case [TFun(_), TAbstract(ab, [])] if (isHaxePath(ab.path, "Function")):
			case [TInst(c, tl), TAbstract(ab, [t1])] if (isHaxePath(ab.path, "Constructible")):
				try {
					switch (c.kind) {
						case KTypeParameter(tlc):
							// Type parameters require an equal Constructible constraint
							if (!Lambda.exists(tlc, function(t) return switch (TypeFunctions.follow(t)) {
								case TAbstract(ab2, [t2]) if (isHaxePath(ab2.path, "Constructible")): typeIseq(uctx, t1, t2);
								case _: false;
							})) error([cannotUnify(a, b)]);
						case _:
							var r = TypeFunctions.classField(c, tl, "new");
							if (!TypeFunctions.hasClassFieldFlag(r.f, CfPublic)) error([invalidVisibility("new")]);
							try unify(uctx, r.t, t1) catch (e:UnifyError) error([cannotUnify(a, b)].concat(e.errors));
					}
				} catch (e:NotFound) {
					error([hasNoField(a, "new")]);
				}
			case [TDynamic(null), _]:
				if (uctx.allowDynamicToCast) {
				} else switch (b) {
					case TDynamic(null):
					case _: error([cannotUnify(a, b)]);
				}
			case [TDynamic(t1), _] if (t1 != null):
				switch (b) {
					case TDynamic(null):
					case TDynamic(t2) if (t2 != null):
						if (t2 != t1) {
							try typeEq(uctx.withEqualityKind(EqRightDynamic), t1, t2)
							catch (e:UnifyError) error([cannotUnify(a, b)].concat(e.errors));
						}
					case TAbstract(bb, tl):
						unifyFrom(uctx, a, b, bb, tl);
					case _:
						error([cannotUnify(a, b)]);
				}
			case [_, TDynamic(null)]:
			case [_, TDynamic(t1)] if (t1 != null):
				switch (a) {
					case TAnon(an):
						try {
							switch (an.status.get()) {
								case Statics(_) | EnumStatics(_): error([]);
								case _:
							}
							for (f in an.fields) {
								try typeEq(uctx, TypeFunctions.fieldType(f), t1)
								catch (e:UnifyError) error([invalidField(f.name)].concat(e.errors));
							}
						} catch (e:UnifyError) {
							error([cannotUnify(a, b)].concat(e.errors));
						}
					case TAbstract(aa, tl):
						unifyTo(uctx, a, b, aa, tl);
					case _:
						error([cannotUnify(a, b)]);
				}
			case [TAbstract(aa, tl), _]:
				unifyTo(uctx, a, b, aa, tl);
			case [TInst(c, pl), TAbstract(bb, tl)] if (isTypeParam(c)):
				// One of the constraints must satisfy the abstract
				switch (c.kind) {
					case KTypeParameter(ctl):
						if (!Lambda.exists(ctl, function(t) {
							var t2 = TypeFunctions.applyParams(c.params, pl, t);
							return try { unify(uctx, t2, b); true; } catch (e:UnifyError) false;
						})) unifyFrom(uctx, a, b, bb, tl);
					case _:
						unifyFrom(uctx, a, b, bb, tl);
				}
			case [_, TAbstract(bb, tl)]:
				unifyFrom(uctx, a, b, bb, tl);
			case _:
				error([cannotUnify(a, b)]);
		}
	}

	static function unifyAnons(uctx:UnificationContext, a:T, b:T, a1:TAnon, a2:TAnon):Void {
		try {
			for (n in a2.fields.keys()) {
				var f2 = a2.fields.get(n);
				if (a1.fields.exists(n)) {
					var f1 = a1.fields.get(n);
					if (!unifyKind(f1.kind, f2.kind)) error([invalidKind(n, f1.kind, f2.kind)]);
					if (TypeFunctions.hasClassFieldFlag(f2, CfPublic) && !TypeFunctions.hasClassFieldFlag(f1, CfPublic))
						error([invalidVisibility(n)]);
					try {
						var f1_type = if (fastEq(f1.type, f2.type)) f1.type else TypeFunctions.fieldType(f1);
						unifyWithAccess(uctx, f1, f1_type, f2);
						switch (a1.status.get()) {
							case Statics(_) if (!TypeFunctions.hasMeta(Meta.MaybeUsed, f1.meta)):
								f1.meta = ([{name: Meta.MaybeUsed, params: [], pos: f1.pos}] : Metadata).concat(f1.meta);
							case _:
						}
					} catch (e:UnifyError) {
						error([invalidField(n)].concat(e.errors));
					}
				} else {
					switch (a1.status.get()) {
						case Const if (TypeFunctions.hasMeta(Meta.Optional, f2.meta)):
							a1.fields.set(f2.name, f2);
						case _:
							error([hasNoField(a, n)]);
					}
				}
			}
			switch (a2.status.get()) {
				case Statics(c): switch (a1.status.get()) { case Statics(c2) if (c == c2): case _: error([]); }
				case EnumStatics(e): switch (a1.status.get()) { case EnumStatics(e2) if (e == e2): case _: error([]); }
				case AbstractStatics(ab): switch (a1.status.get()) { case AbstractStatics(ab2) if (ab == ab2): case _: error([]); }
				case Const | Extend(_) | Closed:
			}
		} catch (e:UnifyError) {
			error([cannotUnify(a, b)].concat(e.errors));
		}
	}

	static function doesFuncUnify(f:Void->Void):Bool {
		return try { f(); true; } catch (e:UnifyError) false;
	}
	static function doesFuncUnifyArg(f:T->Void, arg:T):Bool {
		return try { f(arg); true; } catch (e:UnifyError) false;
	}

	static function get_abstract_context(uctx:UnificationContext, a:T, b:T, ab:TAbstract):UnificationContext {
		if (TypeFunctions.hasMeta(Meta.CoreType, ab.meta) || TypeFunctions.hasMeta(Meta.Transitive, ab.meta))
			return uctx;
		else if (uctx.allowAbstractCast)
			return uctx.withAllowAbstractCast(false);
		else {
			error([cannotUnify(a, b)]);
			return uctx;
		}
	}

	static function get_nested_context(uctx:UnificationContext):UnificationContext {
		return uctx.withAllowAbstractCast(true);
	}

	static function unifiesWithAbstract(uctx:UnificationContext, a:T, b:T, f:UnificationContext->Bool):Bool {
		return recStackDefault(abstractCastStack, {a: a, b: b},
			function(p) return fastEqPair(a, b, p.a, p.b),
			function() return (uctx.allowTransitiveCast && f(uctx.withAllowTransitiveCast(false))) || f(uctx),
			false);
	}

	static function get_abstract_unify_func(uctx:UnificationContext, equality_kind:EqKind):T->T->Void {
		if (uctx.allowTransitiveCast) return function(x:T, y:T) unify(uctx, x, y);
		else return function(x:T, y:T) typeEq(uctx.withEqualityKind(equality_kind), x, y);
	}

	static function unifyAbstracts(uctx:UnificationContext, a:T, b:T, a1:TAbstract, tl1:Array<T>, a2:TAbstract, tl2:Array<T>):Void {
		if (!unifiesAbstracts(uctx, a, b, a1, tl1, a2, tl2)) error([cannotUnify(a, b)]);
	}

	static function unifyFrom(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>):Void {
		if (!unifiesFrom(uctx, a, b, ab, tl)) error([cannotUnify(a, b)]);
	}

	static function unifyTo(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>):Void {
		if (!unifiesTo(uctx, a, b, ab, tl)) error([cannotUnify(a, b)]);
	}

	static function unifiesAbstracts(uctx:UnificationContext, a:T, b:T, a1:TAbstract, tl1:Array<T>, a2:TAbstract, tl2:Array<T>):Bool {
		return unifiesWithAbstract(uctx, a, b, function(uctx) {
			return Lambda.exists(a1.to, unifiesToDirect.bind(uctx, a, b, a1, tl1))
				|| Lambda.exists(a2.from, unifiesFromDirect.bind(uctx, a, b, a2, tl2));
		});
	}

	static function unifiesFrom(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>):Bool {
		return unifiesWithAbstract(uctx, a, b, function(uctx) {
			return Lambda.exists(ab.from, unifiesFromDirect.bind(uctx, a, b, ab, tl));
		});
	}

	static function unifiesTo(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>):Bool {
		return unifiesWithAbstract(uctx, a, b, function(uctx) {
			return Lambda.exists(ab.to, unifiesToDirect.bind(uctx, a, b, ab, tl));
		});
	}

	static function unifiesFromDirect(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>, t:T):Bool {
		return doesFuncUnify(function() {
			var t2 = TypeFunctions.applyParams(ab.params, tl, t);
			var uctx2 = get_abstract_context(uctx, a, b, ab);
			var unify_func = get_abstract_unify_func(uctx2, EqRightDynamic);
			unify_func(a, t2);
		});
	}

	static function unifiesToDirect(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>, t:T):Bool {
		return doesFuncUnify(function() {
			var t2 = TypeFunctions.applyParams(ab.params, tl, t);
			var uctx2 = get_abstract_context(uctx, a, b, ab);
			var unify_func = get_abstract_unify_func(uctx2, EqStrict);
			unify_func(t2, b);
		});
	}

	static function unifiesFromField(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>, t:T, cf:TClassField):Bool {
		return doesFuncUnify(function() {
			switch (TypeFunctions.follow(cf.type)) {
				case TFun(sig):
					var r = sig.ret;
					function map0(x:T):T return TypeFunctions.applyParams(ab.params, tl, x);
					var monos = spawnConstrainedMonos(map0, cf.params);
					function map2(x:T):T return map0(TypeFunctions.applyParams(cf.params, monos, x));
					var uctx2 = get_abstract_context(uctx, a, b, ab);
					var unify_func = get_abstract_unify_func(uctx2, EqStrict);
					unify_func(a, map2(t));
					unify_func(map2(r), b);
				case _:
					throw "unifies_from_field: expected TFun";
			}
		});
	}

	static function unifiesToField(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>, t:T, cf:TClassField):Bool {
		return doesFuncUnify(function() {
			switch (TypeFunctions.follow(cf.type)) {
				case TFun(sig) if (sig.args.length >= 1):
					var ta = sig.args[0].t;
					function map0(x:T):T return TypeFunctions.applyParams(ab.params, tl, x);
					var monos = spawnConstrainedMonos(map0, cf.params);
					function map2(x:T):T return map0(TypeFunctions.applyParams(cf.params, monos, x));
					var uctx2 = get_abstract_context(uctx, a, b, ab);
					var unify_func = get_abstract_unify_func(uctx2, EqStrict);
					var athis = map2(ab.thisType);
					// Cannot allow implicit casts when the this type is not completely known yet
					if (TypeFunctions.hasMeta(Meta.MultiType, ab.meta) && TypeFunctions.hasMono(athis)) throw new UnifyError([]);
					withVariance(uctx2, function(x, y) typeEq(uctx2.withEqualityKind(EqStrict), x, y), athis, map2(ta));
					unify_func(map2(t), b);
				case _:
					throw "unifies_to_field: expected TFun";
			}
		});
	}

	static function unifyWithVariance(uctx:UnificationContext, f:T->T->Void, t1:T, t2:T):Void {
		t1 = TypeFunctions.followWithoutType(t1);
		t2 = TypeFunctions.followWithoutType(t2);
		function fail():Void error([cannotUnify(t1, t2)]);
		function unifyRec(fn:Void->Void):Void {
			recStack(varianceStack, {a: t1, b: t2}, function(p) return fastEqPair(t1, t2, p.a, p.b),
				function() { fn(); return null; }, function(_) { fail(); return null; });
		}
		function unifyNested(x:T, y:T):Void withVariance(get_nested_context(uctx), f, x, y);
		function unifyTls(tl1:Array<T>, tl2:Array<T>):Void { for (i in 0...tl1.length) unifyNested(tl1[i], tl2[i]); }
		function get_this_type(ab:TAbstract, tl:Array<T>):T return TypeFunctions.followWithoutType(TypeFunctions.applyParams(ab.params, tl, ab.thisType));
		function get_defined_type(td:TDef, tl:Array<T>):T return TypeFunctions.followWithoutType(TypeFunctions.applyTypedef(td, tl));
		function compareUnderlying():Void typeEq(uctx.withUnderlyingBothDynamic(), t1, t2);
		function unifiesAbstract(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>, ats:Array<T>):Bool {
			return try {
				var uctx2 = get_abstract_context(uctx, a, b, ab);
				recStackDefault(abstractCastStack, {a: a, b: b}, function(p) return fastEqPair(a, b, p.a, p.b),
					function() return Lambda.exists(ats, function(at) return doesFuncUnifyArg(function(at) {
						var at2 = TypeFunctions.applyParams(ab.params, tl, at);
						if (ats == ab.to) withVariance(uctx2, f, at2, b);
						else withVariance(uctx2, f, a, at2);
					}, at)),
					false);
			} catch (e:UnifyError) false;
		}
		switch [t1, t2] {
			case [TInst(c1, tl1), TInst(c2, tl2)] if (c1 == c2): unifyTls(tl1, tl2);
			case [TEnum(en1, tl1), TEnum(en2, tl2)] if (en1 == en2): unifyTls(tl1, tl2);
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)] if (a1 == a2): unifyTls(tl1, tl2);
			case [TType(td1, tl1), TType(td2, tl2)] if (td1 == td2): unifyTls(tl1, tl2);
			case [TType(td, tl), _]: unifyRec(function() unifyWithVariance(uctx, f, get_defined_type(td, tl), t2));
			case [_, TType(td, tl)]: unifyRec(function() unifyWithVariance(uctx, f, t1, get_defined_type(td, tl)));
			case [TAbstract(ab, tl), _] if (TypeFunctions.hasMeta(Meta.ForwardVariance, ab.meta)):
				withVariance(uctx, f, get_this_type(ab, tl), t2);
			case [_, TAbstract(ab, tl)] if (TypeFunctions.hasMeta(Meta.ForwardVariance, ab.meta)):
				withVariance(uctx, f, t1, get_this_type(ab, tl));
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)]:
				if (!unifiesAbstract(uctx, t1, t2, a1, tl1, a1.to) && !unifiesAbstract(uctx, t1, t2, a2, tl2, a2.from)) fail();
				compareUnderlying();
			case [TAbstract(ab, tl), _]:
				if (!unifiesAbstract(uctx, t1, t2, ab, tl, ab.to)) fail();
				compareUnderlying();
			case [_, TAbstract(ab, tl)]:
				if (!unifiesAbstract(uctx, t1, t2, ab, tl, ab.from)) fail();
				compareUnderlying();
			case [TAnon(a1), TAnon(a2)]:
				unifyAnons(uctx, t1, t2, a1, a2);
			case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length):
				for (i in 0...s1.args.length) unifyNested(s1.args[i].t, s2.args[i].t);
				unifyNested(s1.ret, s2.ret);
			case _:
				fail();
		}
	}

	static function unifyTypeParams(uctx:UnificationContext, a:T, b:T, tl1:Array<T>, tl2:Array<T>):Void {
		var uctx2 = get_nested_context(uctx);
		var i = 0;
		for (k in 0...tl1.length) {
			i++;
			try {
				withVariance(uctx2, function(x, y) typeEq(uctx2.withEqualityKind(EqRightDynamic), x, y), tl1[k], tl2[k]);
			} catch (e:UnifyError) {
				error([cannotUnify(a, b), Invariant_parameter(i)].concat(e.errors));
			}
		}
	}

	static function withVariance(uctx:UnificationContext, f:T->T->Void, t1:T, t2:T):Void {
		try {
			f(t1, t2);
		} catch (e:UnifyError) {
			var l = e.errors;
			try {
				unifyWithVariance(uctx, f, t1, t2);
			} catch (e2:UnifyError) {
				throw new UnifyError(l);
			}
		}
	}

	static function unifyWithAccess(uctx:UnificationContext, f1:TClassField, t1:T, f2:TClassField):Void {
		var uctx2 = get_nested_context(uctx);
		switch (f2.kind) {
			case Var(vk) if (switch (vk.read) { case AccNo | AccNever: true; case _: false; }):
				unify(uctx2, f2.type, t1);
			case Method(MethNormal) | Method(MethInline) | Var({write: AccNo}) | Var({write: AccNever}):
				if (TypeFunctions.hasClassFieldFlag(f1, CfFinal) != TypeFunctions.hasClassFieldFlag(f2, CfFinal))
					throw new UnifyError([FinalInvariance]);
				unify(uctx2, t1, f2.type);
			case _:
				withVariance(uctx2, function(x, y) typeEq(uctx2.withEqualityKind(EqBothDynamic), x, y), t1, f2.type);
		}
	}

	public static function doesUnify(a:T, b:T):Bool {
		return try { unify(defaultUnificationContext, a, b); true; } catch (e:UnifyError) false;
	}

	public static function unifyDefault(a:T, b:T):Void {
		unify(defaultUnificationContext, a, b);
	}

	public static function typeEqKind(param:EqKind, a:T, b:T):Void {
		typeEq(defaultUnificationContext.withEqualityKind(param), a, b);
	}

	public static function typeIseqDefault(a:T, b:T):Bool {
		return typeIseq(defaultUnificationContext, a, b);
	}

	// Uctx find: try non-transitive first, then transitive.
	static function findCastField(uctx:UnificationContext, find:UnificationContext->Null<TAbstractCast>):TAbstractCast {
		var found = try find(uctx.withAllowTransitiveCast(false)) catch (e:NotFound) find(uctx);
		if (found == null) throw new NotFound();
		return found;
	}

	public static function findFieldFrom(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>):TAbstractCast {
		for (c in ab.fromField) if (unifiesFromField(uctx, a, b, ab, tl, c.t, c.cf)) return c;
		throw new NotFound();
	}

	public static function findFieldTo(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>):TAbstractCast {
		for (c in ab.toField) if (unifiesToField(uctx, a, b, ab, tl, c.t, c.cf)) return c;
		throw new NotFound();
	}

	// Uctx a ab tl: relate a concrete `a` to the abstract `ab` (the @:from direction). Returns the
	// matching @:from cast field.
	public static function findFrom(uctx:UnificationContext, a:T, ab:TAbstract, tl:Array<T>):TAbstractCast {
		if (TypeFunctions.follow(a) == TypeFunctions.tDynamic) {
			for (c in ab.fromField) if (TypeFunctions.follow(c.t) == TypeFunctions.tDynamic) return c;
			throw new NotFound();
		}
		var b:T = TAbstract(ab, tl);
		return findCastField(uctx, function(uctx) {
			if (unifiesFrom(uctx, a, b, ab, tl)) return null;
			else return findFieldFrom(uctx, a, b, ab, tl);
		});
	}

	// Uctx b ab tl: relate the abstract `ab` to a concrete `b` (the @:to
	public static function findTo(uctx:UnificationContext, b:T, ab:TAbstract, tl:Array<T>):TAbstractCast {
		if (TypeFunctions.follow(b) == TypeFunctions.tDynamic) {
			for (c in ab.toField) if (TypeFunctions.follow(c.t) == TypeFunctions.tDynamic) return c;
			throw new NotFound();
		}
		var a:T = TAbstract(ab, tl);
		return findCastField(uctx, function(uctx) {
			if (unifiesTo(uctx, a, b, ab, tl)) return null;
			else return findFieldTo(uctx, a, b, ab, tl);
		});
	}

	// Returns the chosen abstract + tl + the cast field, or null when a plain unify suffices
	// (unifiesAbstracts true) - the caller then needs no cast.
	public static function findToFrom(uctx:UnificationContext, a:T, b:T, a1:TAbstract, tl1:Array<T>, a2:TAbstract, tl2:Array<T>):Null<{a:TAbstract, tl:Array<T>, castField:TAbstractCast}> {
		var side:{a:TAbstract, tl:Array<T>} = null;
		var found:Null<TAbstractCast> = null;
		var noCast = false;
		try {
			found = findCastField(uctx, function(uctx):Null<TAbstractCast> {
				if (unifiesAbstracts(uctx, a, b, a1, tl1, a2, tl2)) { noCast = true; return null; }
				else {
					return try {
						var tc = findFieldTo(uctx, a, b, a1, tl1);
						side = {a: a1, tl: tl1};
						tc;
					} catch (e:NotFound) {
						side = {a: a2, tl: tl2};
						findFieldFrom(uctx, a, b, a2, tl2);
					}
				}
			});
		} catch (e:NotFound) {
			if (noCast) return null;
			throw e;
		}
		if (noCast || found == null) return null;
		return {a: side.a, tl: side.tl, castField: found};
	}

	public static function collectBaseTypes(t:T):Array<T> {
		var tl:Array<T> = [];
		function loop(t:T):Void {
			switch (t) {
				case TInst(cl, params):
					switch (cl.kind) {
						case KTypeParameter(tlc): for (x in tlc) loop(x);
						case _:
					}
					for (impl in cl.interfaces) {
						loop(TypeFunctions.applyParams(cl.params, params, TInst(impl.c, impl.params)));
					}
					switch (cl.superClass) {
						case null:
						case s: loop(TypeFunctions.applyParams(cl.params, params, TInst(s.c, s.params)));
					}
					tl = [t].concat(tl);
				case TType(td, pl):
					loop(TypeFunctions.applyTypedef(td, pl));
					// Prioritize the most generic definition
					tl = [t].concat(tl);
				case TLazy(f):
					loop(TypeFunctions.lazyType(f));
				case TMono(r):
					switch (r.type) { case null: case some: loop(some); }
				case _:
					tl = [t].concat(tl);
			}
		}
		loop(t);
		return tl;
	}

	public static function unify_min_(uctx:UnificationContext, common_types:Array<T>, tl:Array<T>):UnifyMinResult {
		var first_error:Null<{l:Array<UnifyErrorKind>, p:Int}> = null;
		function loop(index:Int, common_types:Array<T>, tl:Array<T>):UnifyMinResult {
			if (tl.length == 0) {
				if (common_types.length == 0) {
					return switch (first_error) {
						case null: UnifyMinError([Unify_custom("Could not determine common type, please add a type-hint")], 0);
						case fe: UnifyMinError(fe.l, fe.p);
					}
				} else {
					return UnifyMinOk(common_types[0]);
				}
			} else {
				var t = tl[0];
				var rest = tl.slice(1);
				var newCommon = common_types.filter(function(tp) {
					return try {
						unify(uctx, t, tp);
						true;
					} catch (e:UnifyError) {
						if (first_error == null) first_error = {l: e.errors, p: index};
						false;
					}
				});
				return loop(index + 1, newCommon, rest);
			}
		}
		return loop(0, common_types, tl);
	}

	public static function unifyMin(uctx:UnificationContext, t0:T, tl:Array<T>):UnifyMinResult {
		return switch (tl) {
			case []: UnifyMinOk(t0);
			case _:
				var common_types = collectBaseTypes(t0);
				unify_min_(uctx, common_types, tl);
		}
	}

	static inline function isNullPath(p:Path):Bool return p.pack.length == 0 && p.name == "Null";
	static inline function isVoidPath(p:Path):Bool return p.pack.length == 0 && p.name == "Void";
	static inline function isEmptyPath(p:Path, name:String):Bool return p.pack.length == 0 && p.name == name;
	static inline function isHaxePath(p:Path, name:String):Bool return p.pack.length == 1 && p.pack[0] == "haxe" && p.name == name;
	static function pathEq(p1:Path, p2:Path):Bool {
		if (p1.name != p2.name || p1.pack.length != p2.pack.length) return false;
		for (i in 0...p1.pack.length) if (p1.pack[i] != p2.pack[i]) return false;
		return true;
	}
	static inline function isTypeParam(c:TClass):Bool return switch (c.kind) { case KTypeParameter(_): true; case _: false; };

	public static function install():Void {
		TypeFunctions.monomorphCreateRef = monoCreate;
		TypeFunctions.monomorphBindRef = monoBind;
		TypeFunctions.monomorphClassifyConstraintsRef = classifyDownConstraints;
	}
}
