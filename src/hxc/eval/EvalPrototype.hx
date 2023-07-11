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
	static function makeFunction(ctx:EvalContext, tf:TFunc):VFunc {
		return function(args:Array<EvalValue>):EvalValue {
			var bound:Array<{vid:Int, value:EvalValue}> = [];
			for (i in 0...tf.args.length) {
				bound.push({vid: tf.args[i].v.id, value: i < args.length ? args[i] : VNull});
			}
			return EvalEmitter.runBody(ctx, bound, tf.expr);
		};
	}

	static inline function asFunction(e:Null<TExpr>):Null<TFunc> {
		return e == null ? null : switch (e.expr) {
			case TFunction(f): f;
			case _: null;
		};
	}

	public static function buildStatic(ctx:EvalContext, c:TClass):{proto:VPrototype, delays:Array<ProtoDelay>} {
		var key = EvalHash.pathHash(c.path);
		var pparent = c.superClass == null ? null : ctx.staticPrototypes.get(EvalHash.pathHash(c.superClass.c.path));
		var pfields:Array<EvalValue> = [];
		var pnames:Map<Int, Int> = new Map();
		var delays:Array<ProtoDelay> = [];
		if (!TypeFunctions.hasClassFlag(c, CExtern)) {
			for (cf in c.orderedStatics) {
				switch (cf.kind) {
					case Method(_):
						var tf = asFunction(cf.expr);
						if (tf != null) {
							pnames.set(EvalHash.hash(cf.name), pfields.length);
							pfields.push(VFunction(makeFunction(ctx, tf), true));
						}
					case Var(_):
						if (cf.expr != null) {
							var idx = pfields.length;
							pnames.set(EvalHash.hash(cf.name), idx);
							pfields.push(VNull);
							var init = cf.expr;
							delays.push(function(proto) {
								var ctxEval = EvalContext.getEval(ctx);
								ctxEval.env = null;
								EvalContext.pushEnvironment(ctx, {isStatic: true, file: 0, kind: EKEntrypoint, numLocals: 0, numCaptures: 0});
								proto.pfields[idx] = EvalEmitter.eval(ctx, init);
								ctxEval.env = null;
							});
						}
					case _:
				}
			}
		}
		var proto = new VPrototype(key, pfields, pnames, [], new Map(), pparent, PClass([]), VNull);
		proto.pvalue = VPrototype(proto);
		return {proto: proto, delays: delays};
	}

	public static function buildInstance(ctx:EvalContext, c:TClass):VPrototype {
		var key = EvalHash.pathHash(c.path);
		var pparent = c.superClass == null ? null : ctx.instancePrototypes.get(EvalHash.pathHash(c.superClass.c.path));
		var pfields:Array<EvalValue> = [];
		var pnames:Map<Int, Int> = new Map();
		var pinstFields:Array<EvalValue> = [];
		var pinstNames:Map<Int, Int> = new Map();
		for (cf in c.orderedFields) {
			switch (cf.kind) {
				case Method(_):
					var tf = asFunction(cf.expr);
					if (tf != null) {
						pnames.set(EvalHash.hash(cf.name), pfields.length);
						pfields.push(VFunction(makeFunction(ctx, tf), false));
					}
				case Var(_):
					pinstNames.set(EvalHash.hash(cf.name), pinstFields.length);
					pinstFields.push(VNull);
				case _:
			}
		}
		var proto = new VPrototype(key, pfields, pnames, pinstFields, pinstNames, pparent, PInstance, VNull);
		proto.pvalue = VPrototype(proto);
		return proto;
	}
}
