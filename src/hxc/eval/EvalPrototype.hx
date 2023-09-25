package hxc.eval;

import hxc.ast.Ast;
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
				bound.push({vid: tf.args[i].v.id, value: EvalEmitter.argValue(ctx, tf.args[i], j < args.length ? args[j] : VNull)});
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
		addMeta(enumMeta(en), pfields, pnames);
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
			var idx = pnames.get(b.name);
			if (idx == null) {
				pnames.set(b.name, pfields.length);
				pfields.push(b.v);
			} else {
				pfields[idx] = b.v;
			}
		}
	}

	// Runtime metadata (the compiler-synthesized __meta__ static). Only user metadata (a name not
	// starting with ':' or '$') is kept; the params, which must be constant-value expressions, are
	// evaluated to runtime values.

	// A metadata param is restricted to constant values: only constants, parentheses, object and
	// array literals; anything else is not a constant value.
	static function metaConstant(e:Expr):EvalValue {
		return switch (e.expr) {
			case EConst(c): metaConst(c);
			case EParenthesis(e1): metaConstant(e1);
			case EObjectDecl(fields):
				var m = new Map<Int, EvalValue>();
				for (f in fields) m.set(EvalHash.hash(f.name), metaConstant(f.expr));
				VObject(new VObject([], ODictionary(m)));
			case EArrayDecl(el): VArray(new VArray([for (x in el) metaConstant(x)], el.length));
			case _: throw new EvalMetaError();
		};
	}

	// Constant folding for a metadata leaf (int overflow / hex fall back to float, the three keyword
	// idents map to their values, any other ident is not a constant).
	static function metaConst(c:Constant):EvalValue {
		return switch (c) {
			case CInt(s, _):
				if (s.length > 10 && s.substr(0, 2) == "0x") throw new EvalMetaError();
				var i = Std.parseInt(s);
				(i == null || i < -2147483648 || i > 2147483647) ? VFloat(Std.parseFloat(s)) : VInt(i);
			case CFloat(f, _): VFloat(Std.parseFloat(f));
			case CString(s, _): VString(new VString(s, s.length));
			case CIdent("true"): VTrue;
			case CIdent("false"): VFalse;
			case CIdent("null"): VNull;
			case _: throw new EvalMetaError();
		};
	}

	// True for a user metadata name: not a compiler/reserved one (leading ':' or '$').
	static inline function isUserMeta(name:String):Bool {
		if (name.length == 0) return false;
		var c = name.charCodeAt(0);
		return c != ":".code && c != "$".code;
	}

	// One entry's params become an Array of values, or null when there are no params (both no-parens
	// and empty-parens yield the empty list, hence null).
	static function metaParams(params:Array<Expr>):EvalValue {
		if (params.length == 0) return VNull;
		return VArray(new VArray([for (p in params) metaConstant(p)], params.length));
	}

	// Turn one named-metadata list ({name -> Metadata}) into a VObject of {name -> params}, keeping
	// only user metadata and only entries that still carry some. Returns null when nothing remains.
	static function metaField(entries:Array<{name:String, meta:Metadata}>):Null<EvalValue> {
		var m = new Map<Int, EvalValue>();
		var any = false;
		for (e in entries) {
			var inner = new Map<Int, EvalValue>();
			var innerAny = false;
			for (me in e.meta) if (isUserMeta(me.name)) {
				inner.set(EvalHash.hash(me.name), metaParams(me.params));
				innerAny = true;
			}
			if (innerAny) {
				m.set(EvalHash.hash(e.name), VObject(new VObject([], ODictionary(inner))));
				any = true;
			}
		}
		return any ? VObject(new VObject([], ODictionary(m))) : null;
	}

	// The metadata of a single type (its own meta list under the "" key). Returns null when it has no
	// user metadata.
	static function metaObj(meta:Metadata):Null<EvalValue> {
		var inner = new Map<Int, EvalValue>();
		var any = false;
		for (me in meta) if (isUserMeta(me.name)) {
			inner.set(EvalHash.hash(me.name), metaParams(me.params));
			any = true;
		}
		return any ? VObject(new VObject([], ODictionary(inner))) : null;
	}

	// Assemble the __meta__ value {obj?, fields?, statics?} for a type, or null when nothing applies.
	// The nested metadata is dropped whole if any param is not a constant value, so a malformed entry
	// never aborts the run.
	static function buildMeta(obj:Metadata, fields:Array<{name:String, meta:Metadata}>,
			statics:Array<{name:String, meta:Metadata}>):Null<EvalValue> {
		try {
			var vObj = metaObj(obj);
			var vFields = metaField(fields);
			var vStatics = metaField(statics);
			if (vObj == null && vFields == null && vStatics == null) return null;
			var m = new Map<Int, EvalValue>();
			if (vObj != null) m.set(EvalHash.hash("obj"), vObj);
			if (vFields != null) m.set(EvalHash.hash("fields"), vFields);
			if (vStatics != null) m.set(EvalHash.hash("statics"), vStatics);
			return VObject(new VObject([], ODictionary(m)));
		} catch (_:EvalMetaError) {
			return null;
		}
	}

	// Install a computed __meta__ value as a static-prototype field.
	static function addMeta(v:Null<EvalValue>, pfields:Array<EvalValue>, pnames:Map<Int, Int>):Void {
		if (v == null) return;
		pnames.set(EvalHash.key___meta__, pfields.length);
		pfields.push(v);
	}

	// The runtime metadata of a class: its own meta, instance fields (the constructor keyed under "_"),
	// and statics.
	static function classMeta(c:TClass):Null<EvalValue> {
		var fields:Array<{name:String, meta:Metadata}> = [for (f in c.orderedFields) {name: f.name, meta: f.meta}];
		if (c.constructor != null) fields.push({name: "_", meta: c.constructor.meta});
		var statics:Array<{name:String, meta:Metadata}> = [for (f in c.orderedStatics) {name: f.name, meta: f.meta}];
		return buildMeta(c.meta, fields, statics);
	}

	// The runtime metadata of an enum: its own meta plus each constructor's meta (under fields).
	static function enumMeta(en:TEnum):Null<EvalValue> {
		var fields:Array<{name:String, meta:Metadata}> = [];
		for (n in en.names) {
			var ef = en.constrs.get(n);
			if (ef != null) fields.push({name: n, meta: ef.meta});
		}
		return buildMeta(en.meta, fields, []);
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
		addMeta(classMeta(c), pfields, pnames);
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
						// A dynamic method is reassignable per instance, so it also occupies an instance
						// slot defaulting
						// to the same function.
						if (cf.kind.match(Method(MethDynamic))) {
							pinstNames.set(EvalHash.hash(cf.name), pinstFields.length);
							pinstFields.push(VFunction(makeFunction(ctx, tf, true), false));
						} else {
							// A plain override of an inherited dynamic method must replace that inherited
							// instance-slot's default so instances dispatch to this override, not the base.
							var inherited = pinstNames.get(EvalHash.hash(cf.name));
							if (inherited != null) pinstFields[inherited] = VFunction(makeFunction(ctx, tf, true), false);
						}
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

// Signals that a metadata param is not a constant value, so its whole __meta__ is skipped.
class EvalMetaError extends haxe.Exception {
	public function new() super("not a constant metadata value");
}
