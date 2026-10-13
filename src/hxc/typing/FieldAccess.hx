package hxc.typing;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.NotFound;
import hxc.typing.AccessKind;

// The access kind differs from the field host.
enum FieldAccessMode {
	FGet;   // Plain expression with applied field type parameters
	FCall;  // Does not apply field type parameters
	FRead;  // Actual reading (for FClosure and such)
	FWrite; // Used as lhs (no semantic difference to FGet)
}

enum AccessorResolution<T> {
	AccessorFound(v:T);
	AccessorAnon;
	AccessorNotFound;
	AccessorInvalid;
}

class FieldAccessTools {
	public static function create(e:TExpr, cf:TClassField, fh:FieldHost, isInline:Bool, p:Position):FieldAccess {
		return {on: e, field: cf, host: fh, isInline: isInline, pos: p};
	}

	public static function applyFa(cf:TClassField, fh:FieldHost):TFieldAccess {
		return switch (fh) {
			case FHStatic(c): FStatic(c, cf);
			case FHInstance(c, tl): FInstance(c, tl, cf);
			case FHAbstract(_, _, c): FStatic(c, cf);
			case FHAnon: FAnon(cf);
		};
	}

	public static function getHost(c:TClass, cf:TClassField):FieldHost {
		if (TypeFunctions.hasClassFieldFlag(cf, CfStatic)) return FHStatic(c);
		return switch (c.kind) {
			case KAbstractImpl(a): FHAbstract(a, TypeFunctions.extractParamTypes(a.params), c);
			case _: FHInstance(c, TypeFunctions.extractParamTypes(c.params));
		};
	}

	// How the type of the accessed field is seen from its host.
	public static function getMapFunction(fa:FieldAccess):T->T {
		return switch (fa.host) {
			case FHInstance(c, tl): TypeFunctions.classMapFunction(c, tl);
			case FHAbstract(a, tl, _): function(t:T) return TypeFunctions.applyParams(a.params, tl, t);
			case _: function(t:T) return t;
		};
	}

	public static function getHostClassRaise(fh:FieldHost):TClass {
		return switch (fh) {
			case FHStatic(c): c;
			case FHInstance(c, _): c;
			case FHAbstract(_, _, c): c;
			case FHAnon: throw new NotFound("FieldAccess.hx:52");
		};
	}

	// TypeFunctions.classMapFunction walks the super chain. There is no short-circuit on an empty `tl`:
	// a class with no parameters of its own still has to apply the substitutions of the classes above it.
	static function mapType(c:TClass, tl:TParams, t:T):T {
		return TypeFunctions.classMapFunction(c, tl)(t);
	}

	static function declaredReturnIsOpen(cf:TClassField):Bool {
		return switch (TypeFunctions.follow(TypeFields.fieldCallType(cf))) {
			case TFun(sig): switch (TypeFunctions.follow(sig.ret)) { case TMono(r): r.type == null; case _: false; };
			case _: false;
		};
	}

	public static function getFieldExpr(fa:FieldAccess, mode:FieldAccessMode, ?curField:TClassField):TExpr {
		var cf = fa.field;
		var t = switch (mode) {
			case FCall: TypeFields.fieldCallType(cf);
			case FGet | FRead | FWrite: TypeFunctions.fieldType(cf);
		};
		// A method value read while its inferred return is still an unbound monomorph gets a FRESH
		// mono: a caller unifying the closure's return (eq(foo(), 3)) must not bind the declaration
		// mono, which the later body typing needs open.
		// A recursive self-read (cf == curField) or a read of a field whose body is currently being
		// forced (TypeFields.isForcing) is exempt: such a read sees the actual declaration signature,
		// so it must track the real return mono that body typing later binds, not a throwaway fresh mono.
		// The INFERRED return is the declaration's own: a return a type parameter stands for is a
		// monomorph only in the instance just built, and the body that is never typed for it (a
		// declared signature is not typed lazily) has nothing to bind.
		if (cf != curField && !TypeFields.isForcing(cf) && mode.match(FRead) && cf.kind.match(Method(_)) && cf.expr == null
				&& declaredReturnIsOpen(cf)) switch (TypeFunctions.follow(t)) {
			case TFun(sig):
				switch (TypeFunctions.follow(sig.ret)) {
					case TMono(r) if (r.type == null):
						t = TFun({args: sig.args, ret: TypeFunctions.mkMono()});
					case _:
				}
			case _:
		}
		var faAcc:TFieldAccess;
		switch (fa.host) {
			case FHStatic(c):
				faAcc = FStatic(c, cf);
			case FHInstance(c, tl):
				faAcc = switch (cf.kind) {
					case Method(_) if (mode.match(FRead)): FClosure({c: c, params: tl}, cf);
					case _: FInstance(c, tl, cf);
				};
				t = mapType(c, tl, t);
			case FHAbstract(a, tl, c):
				faAcc = FStatic(c, cf);
				t = TypeFunctions.applyParams(a.params, tl, t);
			case FHAnon:
				faAcc = switch (cf.kind) {
					case Method(_) if (mode.match(FRead)): FClosure(null, cf);
					case _: FAnon(cf);
				};
		}
		return TypeFunctions.mk(TField(fa.on, faAcc), t, fa.pos);
	}

	static function findAccessorForField(host:FieldHost, cf:TClassField, t:T, mode:AccessMode):AccessorResolution<{cf:TClassField, host:FieldHost}> {
		return switch (cf.kind) {
			case Var(vk):
				var acc = switch (mode) { case MSet(_): vk.write; case _: vk.read; };
				switch (acc) {
					case AccCall:
						var name = (switch (mode) { case MSet(_): "set_"; case _: "get_"; }) + cf.name;
						switch (host) {
							case FHStatic(c):
								var cfAcc = c.statics.get(name);
								cfAcc != null ? AccessorFound({cf: cfAcc, host: host}) : AccessorAnon;
							case FHInstance(c, tl):
								var c2 = c, tl2 = tl;
								switch (TypeFunctions.follow(t)) {
									case TInst(ci, tli): c2 = ci; tl2 = tli;
									case _:
								}
								var r = TypeFunctions.rawClassFieldOpt(function(f) return f.type, c2, tl2, name);
								if (r != null) {
									var newHost = switch (r.c2) {
										case null: FHAnon;
										case cw: FHInstance(cw.c, cw.params);
									};
									AccessorFound({cf: r.f, host: newHost});
								} else {
									TypeFunctions.hasClassFlag(c, CExtern) ? AccessorAnon : AccessorNotFound;
								}
							case FHAbstract(_, _, c):
								var cfAcc = c.statics.get(name);
								cfAcc != null ? AccessorFound({cf: cfAcc, host: host}) : AccessorAnon;
							case FHAnon:
								AccessorAnon;
						}
					case _:
						AccessorInvalid;
				}
			case _:
				AccessorInvalid;
		};
	}

	public static function resolveAccessor(fa:FieldAccess, mode:AccessMode):AccessorResolution<FieldAccess> {
		return switch (findAccessorForField(fa.host, fa.field, fa.on.type, mode)) {
			case AccessorFound(r): AccessorFound(create(fa.on, r.cf, r.host, fa.isInline, fa.pos));
			case AccessorInvalid: AccessorInvalid;
			case AccessorAnon: AccessorAnon;
			case AccessorNotFound: AccessorNotFound;
		};
	}

	public static function makeStaticExtensionAccess(c:TClass, cf:TClassField, eThis:TExpr, isInline:Bool, p:Position):StaticExtensionAccess {
		// A super receiver flows into the extension as a plain call argument, which no target can
		// emit (`super` may only appear in a direct super field access); it becomes a cast of
		// `this`.
		switch (eThis.expr) {
			case TConst(TSuper):
				eThis = TypeFunctions.mk(TCast(TypeFunctions.mk(TConst(TThis), eThis.type, eThis.pos), null), eThis.type, eThis.pos);
			case _:
		}
		var eStatic = TexprTools.makeStaticThis(c, p);
		return {thisExpr: eThis, access: create(eStatic, cf, FHStatic(c), isInline, p)};
	}

	public static function makeAbstractStaticExtensionAccess(a:TAbstract, tl:TParams, c:TClass, cf:TClassField, eThis:TExpr, isInline:Bool, p:Position):StaticExtensionAccess {
		var eStatic = TexprTools.makeStaticThis(c, p);
		return {thisExpr: eThis, access: create(eStatic, cf, FHAbstract(a, tl, c), isInline, p)};
	}
}
