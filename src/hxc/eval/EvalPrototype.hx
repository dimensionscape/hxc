package hxc.eval;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.eval.EvalValue;
import hxc.eval.EvalContext;
import hxc.eval.EvalEmitter;
import hxc.eval.EvalHash;

typedef ProtoDelay = VPrototype->Void;

// Builds the runtime prototypes for a typed class. Static and instance methods become callables;
// fields are laid out in offset-indexed arrays addressed by the hashed-name maps.
class EvalPrototype {
	// An instance method or constructor receives the receiver as the first call argument and binds
	// it as this; a static method binds its arguments directly.
	static function makeFunction(ctx:EvalContext, tf:TFunc, isInstance:Bool):VFunc {
		return function(args:Array<EvalValue>):EvalValue {
			var offset = isInstance ? 1 : 0;
			var bound:Array<{vid:Int, value:EvalValue}> = [];
			for (i in 0...tf.args.length) {
				var j = i + offset;
				bound.push({vid: tf.args[i].v.id, value: j < args.length ? args[j] : VNull});
			}
			var vthis = isInstance ? (args.length > 0 ? args[0] : VNull) : null;
			return EvalEmitter.runBody(ctx, bound, tf.expr, vthis);
		};
	}

	public static function makeConstructor(ctx:EvalContext, c:TClass):Null<VFunc> {
		if (c.constructor == null) return null;
		var tf = asFunction(c.constructor.expr);
		return tf == null ? null : makeFunction(ctx, tf, true);
	}

	// The static face of an enum: each constructor is a value (no-arg) or a builder (with args).
	public static function buildEnum(ctx:EvalContext, en:TEnum):VPrototype {
		var key = EvalHash.pathHash(en.path);
		var pfields:Array<EvalValue> = [];
		var pnames:Map<Int, Int> = new Map();
		var constructors:Array<{name:String, args:Array<Int>}> = [];
		for (name in en.names) {
			var ef = en.constrs.get(name);
			var idx = ef.index;
			var pos = ef.namePos;
			var v:EvalValue = switch (TypeFunctions.follow(ef.type)) {
				case TFun(sig):
					constructors.push({name: name, args: [for (a in sig.args) EvalHash.hash(a.name)]});
					VFunction(function(args:Array<EvalValue>):EvalValue return EvalValue.VEnumValue(new VEnumValue(idx, args, key, pos)), false);
				case _:
					constructors.push({name: name, args: []});
					EvalValue.VEnumValue(new VEnumValue(idx, [], key, pos));
			};
			pnames.set(EvalHash.hash(name), pfields.length);
			pfields.push(v);
		}
		var proto = new VPrototype(key, pfields, pnames, [], new Map(), null, PEnum(constructors), VNull);
		// The enum used as a value (Type.getEnumConstructs(E), createEnum) resolves to its prototype.
		proto.pvalue = VPrototype(proto);
		return proto;
	}

	static inline function asFunction(e:Null<TExpr>):Null<TFunc> {
		return e == null ? null : switch (e.expr) {
			case TFunction(f): f;
			case _: null;
		};
	}

	static inline function isRemovable(cf:TClassField):Bool {
		return TypeFunctions.hasClassFieldFlag(cf, CfExtern) || TypeFunctions.hasClassFieldFlag(cf, CfGeneric);
	}

	// Install native builtins for a type (extern stdlib classes get their fields from here).
	static function addBuiltins(list:Null<Array<BuiltinField>>, pfields:Array<EvalValue>, pnames:Map<Int, Int>):Void {
		if (list == null) return;
		for (b in list) {
			if (!pnames.exists(b.name)) {
				pnames.set(b.name, pfields.length);
				pfields.push(b.v);
			}
		}
	}

	public static function buildStatic(ctx:EvalContext, c:TClass):{proto:VPrototype, delays:Array<ProtoDelay>} {
		var key = EvalHash.pathHash(c.path);
		var pparent = c.superClass == null ? null : ctx.staticPrototypes.get(EvalHash.pathHash(c.superClass.c.path));
		var pfields:Array<EvalValue> = [];
		var pnames:Map<Int, Int> = new Map();
		var delays:Array<ProtoDelay> = [];
		if (!TypeFunctions.hasClassFlag(c, CExtern)) {
			for (cf in c.orderedStatics) {
				if (isRemovable(cf)) continue;
				switch (cf.kind) {
					case Method(_):
						var tf = asFunction(cf.expr);
						if (tf != null) {
							pnames.set(EvalHash.hash(cf.name), pfields.length);
							pfields.push(VFunction(makeFunction(ctx, tf, false), true));
						}
					case Var(_) if (cf.expr != null):
						var idx = pfields.length;
						pnames.set(EvalHash.hash(cf.name), idx);
						pfields.push(VNull);
						var init = cf.expr;
						delays.push(function(proto) {
							var ctxEval = EvalContext.getEval(ctx);
							var prev = ctxEval.env;
							var env = EvalContext.pushEnvironment(ctx, {isStatic: true, file: 0, kind: EKEntrypoint, numLocals: 0, numCaptures: 0});
							try {
								proto.pfields[idx] = EvalEmitter.eval(ctx, init);
							} catch (e:haxe.Exception) {
								ctxEval.env = prev;
								// A static initializer that fails while building the macro context (a separate,
								// eagerly initialized interpreter) must not abort the macro; leave it null and go on.
								if (!ctx.isMacro) throw e;
							}
							EvalContext.popEnvironment(ctx, env);
						});
					// A physical field without an initializer still occupies a slot.
					case _ if (TypeFunctions.isPhysicalField(cf)):
						pnames.set(EvalHash.hash(cf.name), pfields.length);
						pfields.push(VNull);
					case _:
				}
			}
		}
		addBuiltins(ctx.builtins.staticBuiltins.get(key), pfields, pnames);
		var proto = new VPrototype(key, pfields, pnames, [], new Map(), pparent, PClass([]), VNull);
		proto.pvalue = VPrototype(proto);
		return {proto: proto, delays: delays};
	}

	public static function buildInstance(ctx:EvalContext, c:TClass):VPrototype {
		var key = EvalHash.pathHash(c.path);
		var pparent = c.superClass == null ? null : ctx.instancePrototypes.get(EvalHash.pathHash(c.superClass.c.path));
		// Methods are resolved through the parent chain, but instance data is stored flat, so the
		// instance-field layout starts from the parent's fields.
		var pfields:Array<EvalValue> = [];
		var pnames:Map<Int, Int> = new Map();
		var pinstFields:Array<EvalValue> = pparent != null ? pparent.pinstanceFields.copy() : [];
		var pinstNames:Map<Int, Int> = new Map();
		if (pparent != null) for (k in pparent.pinstanceNames.keys()) pinstNames.set(k, pparent.pinstanceNames.get(k));
		for (cf in c.orderedFields) {
			if (isRemovable(cf)) continue;
			switch (cf.kind) {
				case Method(_):
					var tf = asFunction(cf.expr);
					if (tf != null) {
						pnames.set(EvalHash.hash(cf.name), pfields.length);
						pfields.push(VFunction(makeFunction(ctx, tf, true), false));
					} else if (TypeFunctions.hasClassFieldFlag(cf, CfAbstract)) {
						pnames.set(EvalHash.hash(cf.name), pfields.length);
						pfields.push(VNull);
					}
				case Var(_) if (TypeFunctions.isPhysicalField(cf)):
					pinstNames.set(EvalHash.hash(cf.name), pinstFields.length);
					pinstFields.push(VNull);
				case _:
			}
		}
		addBuiltins(ctx.builtins.instanceBuiltins.get(key), pfields, pnames);
		var proto = new VPrototype(key, pfields, pnames, pinstFields, pinstNames, pparent, PInstance, VNull);
		proto.pvalue = VPrototype(proto);
		return proto;
	}
}
