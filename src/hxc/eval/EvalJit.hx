package hxc.eval;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.FrameLayout;
import hxc.eval.EvalValue;
import hxc.eval.EvalValue.EvalValueTools;
import hxc.eval.EvalContext;
import hxc.eval.EvalExceptions;

// A function body compiled once into nodes that run it: what the tree walk in EvalEmitter decides at every
// evaluation, a node decides once. Each node does what the matching arm of EvalEmitter.eval (run) and
// EvalEmitter.evalStmt (exec) does, in the same order. A name or path is hashed on a node's first run,
// never earlier, so hash ids are given out in the same order.
@:access(hxc.eval.EvalEmitter)
class EvalJit {
	// Moves on when a compilation-server request starts (EvalMacro.resetPerRequest): what a node keeps
	// from the running program, a static method it called, is looked up again in the next request.
	public static var epoch:Int = 0;

	// The compiled body of a function: made on its first call, kept on the function, made again when
	// its body or arguments changed or another context runs it. A caller keeps it too, typed.
	public static function compiled(ctx:EvalContext, tf:TFunc):JCompiled {
		var c:JCompiled = tf.evalJit;
		if (c != null && c.valid(ctx, tf)) return c;
		var layout = EvalEmitter.frameLayout(tf);
		c = new JCompiled(ctx, tf, layout, compile(ctx, layout, tf.expr));
		tf.evalJit = c;
		return c;
	}

	// A function body run in statement position: a return's value, or null when it runs off its end.
	public static function runBody(ctx:EvalContext, ev:Eval, node:JNode):EvalValue {
		var callPos = ev.currentPos;
		var r = try {
			node.exec(ctx, ev);
			if (ev.ctrl == EvalEmitter.CTRL_RETURN) {
				var v = ev.ctrlValue;
				ev.ctrl = EvalEmitter.CTRL_NONE;
				ev.ctrlValue = VNull;
				v;
			} else VNull;
		} catch (ret:EvalReturn) {
			ret.value;
		}
		ev.currentPos = callPos;
		return r;
	}

	// A method's call (EvalPrototype.makeFunction): `args` from `offset` on are its arguments, a missing or
	// null one taking its default (EvalEmitter.argValue), evaluated before its frame is pushed; then the
	// frame, the arguments bound, the body.
	public static function invoke(ctx:EvalContext, c:JCompiled, args:Array<EvalValue>, offset:Int, vthis:Null<EvalValue>, info:Null<EvalEnvInfo>):EvalValue {
		var n = c.argSlots.length;
		var defaults:Null<Array<EvalValue>> = null;
		for (i in 0...n) {
			var d = c.argDefaults[i];
			if (d == null) continue;
			var j = i + offset;
			switch (j < args.length ? args[j] : VNull) {
				case VNull:
					if (defaults == null) defaults = [];
					defaults[i] = EvalEmitter.eval(ctx, d);
				case _:
			}
		}
		if (info == null) info = EvalContext.createEnvInfo(vthis == null, c.expr.pos, EKEntrypoint, 0, 0);
		var env = EvalContext.pushEnvironment(ctx, info, c.layout);
		env.vthis = vthis;
		var locals = env.locals;
		for (i in 0...n) {
			var j = i + offset;
			var v = defaults == null ? null : defaults[i];
			locals[c.argSlots[i]] = v != null ? v : (j < args.length ? args[j] : VNull);
		}
		// More values than arguments, raised in the pushed environment.
		if (args.length > n + offset) EvalExceptions.excString(ctx, "Something went wrong");
		var ret = runBody(ctx, env.eval, c.node);
		EvalContext.popEnvironment(ctx, env);
		return ret;
	}

	public static function compile(ctx:EvalContext, layout:Null<FrameLayout>, e:TExpr):JNode {
		inline function c(x:TExpr):JNode return compile(ctx, layout, x);
		return switch (e.expr) {
			case TConst(TThis): new JThis(e);
			case TConst(TString(_)) | TConst(TFloat(_)) | TConst(TInt(_)) | TConst(TBool(_)) | TConst(TNull) | TConst(TSuper):
				new JConst(e);
			case TLocal(v):
				var s = ownSlot(layout, v);
				s >= 0 ? new JOwnLocal(e, s) : new JLocal(e, v);
			case TParenthesis(e1) | TMeta(_, e1):
				var inner = c(e1);
				// The wrapper's position only shows while its child runs without one of its own.
				hasPos(e1) ? inner : new JWrap(e, inner);
			case TCast(e1, mt): new JCast(e, c(e1), e1, mt);
			case TBlock(el): new JBlock(e, [for (x in el) c(x)]);
			case TVarExpr(v, eo):
				var s = ownSlot(layout, v);
				new JVar(e, v, s, eo == null ? null : c(eo));
			case TBinop(op, e1, e2): compileBinop(ctx, layout, e, op, e1, e2);
			case TUnop(op, flag, e1): compileUnop(ctx, layout, e, op, flag, e1);
			case TIf(econd, eif, eelse): new JIf(e, c(econd), c(eif), eelse == null ? null : c(eelse));
			case TWhile(econd, body, flag): new JWhile(e, c(econd), c(body), flag);
			case TFor(v, eiter, body): new JFor(e, v, layout, c(eiter), body);
			case TReturn(eo): new JReturn(e, eo == null ? null : c(eo));
			case TBreak: new JBreak(e);
			case TContinue: new JContinue(e);
			case TThrow(e1): new JThrow(e, c(e1));
			case TArrayDecl(el): new JArrayDecl(e, [for (x in el) c(x)]);
			case TObjectDecl(fields): new JObjectDecl(e, fields, [for (f in fields) c(f.expr)]);
			case TTry(e1, catches): new JTry(e, c(e1), catches, [for (cc in catches) c(cc.expr)]);
			case TArray(e1, e2): new JArray(e, c(e1), e1, c(e2), e2);
			case TTypeExpr(mt): new JTypeExpr(e, mt);
			case TFunction(tf): new JFunction(e, tf);
			case TField(e1, fa): new JField(e, e1, fa, fieldNeedsReceiver(fa) ? c(e1) : null);
			case TCall(callee, args): compileCall(ctx, layout, e, callee, args);
			case TNew(cl, params, args): new JNew(e, cl, params, args, [for (a in args) c(a)]);
			case TSwitch(subject, cases, edef):
				new JSwitch(e, c(subject), subject, cases, [for (cs in cases) [for (v in cs.values) c(v)]], [for (cs in cases) c(cs.expr)],
					edef == null ? null : c(edef));
			case TEnumParameter(e1, _, index): new JEnumParameter(e, c(e1), e1, index);
			case TEnumIndex(e1): new JEnumIndex(e, c(e1), e1);
			case _: new JTree(e);
		};
	}

	// The slot a function's own local has in its layout, -1 for any other.
	static function ownSlot(layout:Null<FrameLayout>, v:TVar):Int {
		if (layout == null || v.evalLayoutId != layout.id) return -1;
		return v.evalSlot;
	}

	static inline function hasPos(e:TExpr):Bool return e.pos != null && e.pos.min >= 0;

	// EvalEmitter.evalField evaluates the receiver of every field but a static's and an enum
	// constructor's.
	static function fieldNeedsReceiver(fa:TFieldAccess):Bool {
		return switch (fa) {
			case FStatic(_, _) | FEnum(_, _): false;
			case _: true;
		};
	}

	static function compileBinop(ctx:EvalContext, layout:Null<FrameLayout>, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):JNode {
		inline function c(x:TExpr):JNode return compile(ctx, layout, x);
		return switch (op) {
			case OpBoolAnd: new JBoolAnd(e, c(e1), c(e2));
			case OpBoolOr: new JBoolOr(e, c(e1), c(e2));
			case OpAssign: compileAssign(ctx, layout, e, e1, e2);
			case OpAssignOp(sub): compileReadWrite(ctx, layout, e, sub, e1, e2, true);
			case OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte: new JCompare(e, op, c(e1), e1, c(e2), e2);
			case _: new JArith(e, op, c(e1), c(e2));
		};
	}

	// EvalEmitter.assign: the target's location before the value.
	static function compileAssign(ctx:EvalContext, layout:Null<FrameLayout>, e:TExpr, lhs:TExpr, ve:TExpr):JNode {
		inline function c(x:TExpr):JNode return compile(ctx, layout, x);
		return switch (lhs.expr) {
			case TLocal(v): new JAssignLocal(e, v, ownSlot(layout, v), c(ve));
			case TField(_, FStatic(cl, cf)): new JAssignStatic(e, lhs, cl, cf, c(ve));
			case TField(e1, fa = FInstance(cl, _, cf)) if (EvalEmitter.isClassInstanceField(fa) && !(EvalEmitter.isBytesClass(cl) && cf.name == "length")):
				new JAssignField(e, lhs, e1, fa, c(e1), c(ve), 1);
			case TField(e1, fa = FAnon(_)) if (TypeFunctions.follow(e1.type).match(TAnon(_))):
				new JAssignField(e, lhs, e1, fa, c(e1), c(ve), 2);
			case TField(e1, fa): new JAssignField(e, lhs, e1, fa, c(e1), c(ve), 0);
			case TArray(e1, eidx): new JAssignArray(e, e1, c(e1), eidx, c(eidx), c(ve));
			case _: new JTree(e);
		};
	}

	// EvalEmitter.readWrite: read the target, the operand (1 when none), combine, write back.
	static function compileReadWrite(ctx:EvalContext, layout:Null<FrameLayout>, e:TExpr, op:Binop, target:TExpr, operand:Null<TExpr>, prefix:Bool):JNode {
		inline function c(x:TExpr):JNode return compile(ctx, layout, x);
		var opNode = operand == null ? null : c(operand);
		return switch (target.expr) {
			case TLocal(v): new JRWLocal(e, op, v, ownSlot(layout, v), opNode, prefix);
			case TField(_, FStatic(cl, cf)): new JRWStatic(e, op, cl, cf, opNode, prefix);
			case TField(fe, fa) if (EvalEmitter.isClassInstanceField(fa)): new JRWField(e, op, fe, fa, c(fe), opNode, prefix, true);
			case TField(fe, fa): new JRWField(e, op, fe, fa, c(fe), opNode, prefix, false);
			case TArray(arrE, idxE): new JRWArray(e, op, arrE, c(arrE), idxE, c(idxE), opNode, prefix);
			case _: new JTree(e);
		};
	}

	static function compileUnop(ctx:EvalContext, layout:Null<FrameLayout>, e:TExpr, op:Unop, flag:UnopFlag, e1:TExpr):JNode {
		inline function c(x:TExpr):JNode return compile(ctx, layout, x);
		return switch (op) {
			case Not: new JNot(e, c(e1));
			case Neg: new JNeg(e, c(e1));
			case NegBits: new JNegBits(e, c(e1));
			case Increment | Decrement:
				switch (e1.expr) {
					case TLocal(v) if (op == Increment && !TypeFunctions.hasVarFlag(v, VCaptured)):
						new JIncLocal(e, e1, v, ownSlot(layout, v), flag == Prefix);
					case _:
						compileReadWrite(ctx, layout, e, op == Increment ? OpAdd : OpSub, e1, null, flag == Prefix);
				}
			case _: new JTree(e);
		};
	}

	static function compileCall(ctx:EvalContext, layout:Null<FrameLayout>, e:TExpr, callee:TExpr, args:Array<TExpr>):JNode {
		inline function c(x:TExpr):JNode return compile(ctx, layout, x);
		var argNodes = [for (a in args) c(a)];
		switch (callee.expr) {
			case TField(_, FEnum(en, ef)): return new JEnumCall(e, en, ef, argNodes);
			case TIdent("$__mk_pos__"): return new JMkPos(e, argNodes);
			case _:
		}
		return new JCall(e, callee, args, argNodes, switch (callee.expr) {
			case TField(e1, fa) if (!fa.match(FStatic(_, _) | FEnum(_, _))): c(e1);
			case _: null;
		}, switch (callee.expr) {
			case TField(_, FStatic(_, _)) | TConst(TSuper) | TField({expr: TConst(TSuper)}, _): c(callee);
			case TField(_, fa) if (!fa.match(FStatic(_, _) | FEnum(_, _))): null;
			case _: c(callee);
		});
	}

	static inline function checkDepth(ctx:EvalContext, ev:Eval):Void {
		var env = ev.env;
		if (env != null && env.stackDepth > ctx.maxStackDepth) EvalExceptions.excString(ctx, "Stack overflow");
	}

	static inline function callAt(ev:Eval, p:Position, f:VFunc, args:Array<EvalValue>):EvalValue {
		if (ev.env != null) EvalExceptions.setLeavePosition(ev.env, p);
		return f(args);
	}

	// A closure captures its defining frame and runs its body in a child frame linked to it.
	public static function makeClosure(ctx:EvalContext, tf:TFunc, captured:EvalEnv):VFunc {
		var snap = EvalEmitter.snapshotCaptures(tf, captured);
		var ordinal = tf.evalOrdinal;
		// The closure's info is made with it, not per call.
		var info = EvalContext.createEnvInfo(true, tf.expr.pos, EKLocalFunction(ordinal), 0, 0);
		var cache:Null<JCompiled> = null;
		return function(args:Array<EvalValue>):EvalValue {
			var c = cache;
			if (c == null || !c.valid(ctx, tf)) {
				c = compiled(ctx, tf);
				cache = c;
			}
			var env2 = EvalContext.pushEnvironment(ctx, info, c.layout);
			env2.lexicalParent = snap;
			env2.vthis = captured == null ? null : captured.vthis;
			var n = c.argSlots.length;
			for (i in 0...n) {
				// EvalEmitter.argValue: a missing or null argument takes its default.
				var v = i < args.length ? args[i] : VNull;
				var d = c.argDefaults[i];
				if (d != null) switch (v) {
					case VNull: v = EvalEmitter.eval(ctx, d);
					case _:
				}
				env2.locals[c.argSlots[i]] = v;
			}
			// More values than arguments, raised in the pushed environment.
			if (args.length > n) EvalExceptions.excString(ctx, "Something went wrong");
			var r = runBody(ctx, env2.eval, c.node);
			EvalContext.popEnvironment(ctx, env2);
			return r;
		};
	}
}

class JCompiled {
	public final ctx:EvalContext;
	public final expr:TExpr;
	public final params:Array<TFuncArg>;
	public final layout:FrameLayout;
	public final node:JNode;
	// Each argument's slot in the layout and its default value, if it has one.
	public final argSlots:Array<Int>;
	public final argDefaults:Array<Null<TExpr>>;

	public function new(ctx:EvalContext, tf:TFunc, layout:FrameLayout, node:JNode) {
		this.ctx = ctx;
		this.expr = tf.expr;
		this.params = tf.args;
		this.layout = layout;
		this.node = node;
		this.argSlots = [for (a in tf.args) layout.slots.get(a.v.id)];
		this.argDefaults = [for (a in tf.args) a.c];
	}

	public inline function valid(ctx:EvalContext, tf:TFunc):Bool {
		return this.ctx == ctx && expr == tf.expr && params == tf.args;
	}
}

// A compiled expression. `run` is its value (EvalEmitter.eval), `exec` it run as a statement
// (EvalEmitter.evalStmt), which only control flow tells apart. `pos` is the position the node makes
// current while it runs, null when its own has none.
class JNode {
	public final e:TExpr;
	public final pos:Null<Position>;

	public function new(e:TExpr) {
		this.e = e;
		this.pos = (e.pos != null && e.pos.min >= 0) ? e.pos : null;
	}

	public function run(ctx:EvalContext, ev:Eval):EvalValue {
		throw "JNode.run";
	}

	public function exec(ctx:EvalContext, ev:Eval):Void {
		run(ctx, ev);
	}
}

// Anything not compiled runs through the tree walk.
class JTree extends JNode {
	override public function run(ctx:EvalContext, ev:Eval):EvalValue return EvalEmitter.eval(ctx, e);

	override public function exec(ctx:EvalContext, ev:Eval):Void EvalEmitter.evalStmt(ctx, e);
}

class JThis extends JNode {
	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var vthis = ev.env.vthis;
		return vthis == null ? VNull : vthis;
	}
}

// A constant: the value made once.
@:access(hxc.eval.EvalEmitter)
class JConst extends JNode {
	var value:Null<EvalValue>;

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var v = value;
		if (v == null) {
			v = switch (e.expr) {
				case TConst(c): EvalEmitter.evalConst(c);
				case _: VNull;
			};
			value = v;
		}
		return v;
	}
}

class JOwnLocal extends JNode {
	final slot:Int;

	public function new(e:TExpr, slot:Int) {
		super(e);
		this.slot = slot;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue return ev.env.locals[slot];
}

@:access(hxc.eval.EvalEmitter)
class JLocal extends JNode {
	final v:TVar;

	public function new(e:TExpr, v:TVar) {
		super(e);
		this.v = v;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var fe = EvalEmitter.localFrame(ev.env, v);
		return fe.locals[EvalEmitter.localSlot(fe, v)];
	}
}

class JWrap extends JNode {
	final inner:JNode;

	public function new(e:TExpr, inner:JNode) {
		super(e);
		this.inner = inner;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = inner.run(ctx, ev);
		ev.currentPos = old;
		return r;
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		inner.exec(ctx, ev);
		ev.currentPos = old;
	}
}

@:access(hxc.eval.EvalEmitter)
class JCast extends JNode {
	final inner:JNode;
	final e1:TExpr;
	final mt:Null<ModuleType>;
	var uintToFloat:Int = -1;

	public function new(e:TExpr, inner:JNode, e1:TExpr, mt:Null<ModuleType>) {
		super(e);
		this.inner = inner;
		this.e1 = e1;
		this.mt = mt;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = switch (mt) {
			// A safe cast `cast(e,T)` checks the runtime type and throws "Class cast error" unless the
			// value is null or `is v t`.
			case TClassDecl(_) | TEnumDecl(_) | TAbstractDecl(_):
				var v1 = inner.run(ctx, ev);
				switch (EvalValueTools.vresolve(v1)) {
					case VNull: v1;
					case _:
						var path = EvalHash.pathHash(TypeFunctions.tPath(mt));
						if (!EvalStdLib.isOfTypePath(ctx, v1, path)) EvalExceptions.excString(ctx, "Class cast error", e.pos);
						else v1;
				}
			case _:
				var v = inner.run(ctx, ev);
				if (uintToFloat < 0)
					uintToFloat = EvalEmitter.isAbstractPath(e1.type, [], "UInt") && EvalEmitter.isAbstractPath(e.type, [], "Float") ? 1 : 0;
				if (uintToFloat == 1) {
					switch (v) {
						case VInt(i): VFloat(i < 0 ? 4294967296.0 + i : i + 0.0);
						case VFloat(_): v;
						case _: v;
					}
				} else v;
		};
		ev.currentPos = old;
		return r;
	}
}

class JBlock extends JNode {
	final nodes:Array<JNode>;

	public function new(e:TExpr, nodes:Array<JNode>) {
		super(e);
		this.nodes = nodes;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r:EvalValue = VNull;
		for (n in nodes) r = n.run(ctx, ev);
		ev.currentPos = old;
		return r;
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		for (n in nodes) {
			n.exec(ctx, ev);
			if (ev.ctrl != 0) break;
		}
		ev.currentPos = old;
	}
}

@:access(hxc.eval.EvalEmitter)
class JVar extends JNode {
	final v:TVar;
	final slot:Int;
	final init:Null<JNode>;

	public function new(e:TExpr, v:TVar, slot:Int, init:Null<JNode>) {
		super(e);
		this.v = v;
		this.slot = slot;
		this.init = init;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var env = ev.env;
		var value = init == null ? VNull : init.run(ctx, ev);
		env.locals[slot >= 0 ? slot : EvalEmitter.localSlot(env, v)] = value;
		ev.currentPos = old;
		return VNull;
	}
}

class JBoolAnd extends JNode {
	final a:JNode;
	final b:JNode;

	public function new(e:TExpr, a:JNode, b:JNode) {
		super(e);
		this.a = a;
		this.b = b;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = EvalMisc.isTrue(a.run(ctx, ev)) ? b.run(ctx, ev) : VFalse;
		ev.currentPos = old;
		return r;
	}
}

class JBoolOr extends JNode {
	final a:JNode;
	final b:JNode;

	public function new(e:TExpr, a:JNode, b:JNode) {
		super(e);
		this.a = a;
		this.b = b;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = EvalMisc.isTrue(a.run(ctx, ev)) ? VTrue : b.run(ctx, ev);
		ev.currentPos = old;
		return r;
	}
}

@:access(hxc.eval.EvalEmitter)
class JArith extends JNode {
	final op:Binop;
	final a:JNode;
	final b:JNode;

	public function new(e:TExpr, op:Binop, a:JNode, b:JNode) {
		super(e);
		this.op = op;
		this.a = a;
		this.b = b;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = EvalEmitter.binopValue(ctx, op, a.run(ctx, ev), b.run(ctx, ev), e.pos);
		ev.currentPos = old;
		return r;
	}
}

// EvalEmitter.evalBinop's comparisons: on the eval target an ordering compares a UInt operand as its
// unsigned value.
@:access(hxc.eval.EvalEmitter)
class JCompare extends JNode {
	final op:Binop;
	final a:JNode;
	final e1:TExpr;
	final b:JNode;
	final e2:TExpr;
	final ordering:Bool;
	var uint1:Int = -1;
	var uint2:Int = -1;

	public function new(e:TExpr, op:Binop, a:JNode, e1:TExpr, b:JNode, e2:TExpr) {
		super(e);
		this.op = op;
		this.a = a;
		this.e1 = e1;
		this.b = b;
		this.e2 = e2;
		this.ordering = switch (op) {
			case OpGt | OpGte | OpLt | OpLte: true;
			case _: false;
		};
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var left = a.run(ctx, ev);
		var right = b.run(ctx, ev);
		if (ordering && EvalEmitter.isEvalTarget(ctx)) {
			if (uint1 < 0) uint1 = EvalEmitter.isUIntExpr(e1) ? 1 : 0;
			if (uint1 == 1) left = EvalEmitter.unsignedValue(left);
			if (uint2 < 0) uint2 = EvalEmitter.isUIntExpr(e2) ? 1 : 0;
			if (uint2 == 1) right = EvalEmitter.unsignedValue(right);
		}
		var r = EvalEmitter.binopValue(ctx, op, left, right, e.pos);
		ev.currentPos = old;
		return r;
	}
}

@:access(hxc.eval.EvalEmitter)
class JAssignLocal extends JNode {
	final v:TVar;
	final slot:Int;
	final value:JNode;

	public function new(e:TExpr, v:TVar, slot:Int, value:JNode) {
		super(e);
		this.v = v;
		this.slot = slot;
		this.value = value;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r:EvalValue;
		if (slot >= 0) {
			var env = ev.env;
			r = value.run(ctx, ev);
			env.locals[slot] = r;
		} else {
			var fe = EvalEmitter.localFrame(ev.env, v);
			r = value.run(ctx, ev);
			fe.locals[EvalEmitter.localSlot(fe, v)] = r;
		}
		ev.currentPos = old;
		return r;
	}
}

@:access(hxc.eval.EvalEmitter)
class JAssignStatic extends JNode {
	final lhs:TExpr;
	final cl:TClass;
	final cf:TClassField;
	final value:JNode;

	public function new(e:TExpr, lhs:TExpr, cl:TClass, cf:TClassField, value:JNode) {
		super(e);
		this.lhs = lhs;
		this.cl = cl;
		this.cf = cf;
		this.value = value;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var proto = EvalEmitter.ensureStaticProto(ctx, cl, lhs.pos);
		var v = value.run(ctx, ev);
		proto.pfields[EvalContext.getProtoFieldIndex(proto, EvalHash.hash(cf.name), lhs.pos)] = v;
		ev.currentPos = old;
		return v;
	}
}

// EvalEmitter.assign's field targets: a class's instance field (kind 1) takes an instance, decoded
// before the value; a structure's (kind 2) reads the value first and refuses null; any other (0).
@:access(hxc.eval.EvalEmitter)
class JAssignField extends JNode {
	final lhs:TExpr;
	final e1:TExpr;
	final fa:TFieldAccess;
	final obj:JNode;
	final value:JNode;
	final kind:Int;
	var hash:Int = -1;
	var cacheProto:Null<VPrototype> = null;
	var cacheIdx:Int = -1;

	public function new(e:TExpr, lhs:TExpr, e1:TExpr, fa:TFieldAccess, obj:JNode, value:JNode, kind:Int) {
		super(e);
		this.lhs = lhs;
		this.e1 = e1;
		this.fa = fa;
		this.obj = obj;
		this.value = value;
		this.kind = kind;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var o = obj.run(ctx, ev);
		if (kind == 1) {
			switch (o) {
				case VInstance(_):
				case _: EvalStdLib.unexpectedValueP(ctx, o, "instance", e1.pos);
			}
		}
		var v = value.run(ctx, ev);
		if (kind == 2 && o == VNull) EvalExceptions.excString(ctx, "field access on null", e1.pos);
		if (kind == 1) {
			// EvalField.setField on an instance: its prototype's slot for the name, kept per prototype.
			switch (o) {
				case VInstance(vi):
					if (hash < 0) hash = EvalEmitter.fieldKey(fa);
					if (vi.iproto != cacheProto) {
						cacheIdx = EvalContext.getInstanceFieldIndex(vi.iproto, hash, lhs.pos);
						cacheProto = vi.iproto;
					}
					vi.ifields[cacheIdx] = v;
				case _:
					EvalField.setField(ctx, o, EvalEmitter.fieldKey(fa), v, lhs.pos);
			}
		} else EvalField.setField(ctx, o, EvalEmitter.fieldKey(fa), v, lhs.pos);
		ev.currentPos = old;
		return v;
	}
}

@:access(hxc.eval.EvalEmitter)
class JAssignArray extends JNode {
	final e1:TExpr;
	final arr:JNode;
	final eidx:TExpr;
	final idxNode:JNode;
	final value:JNode;
	var vector:Int = -1;

	public function new(e:TExpr, e1:TExpr, arr:JNode, eidx:TExpr, idxNode:JNode, value:JNode) {
		super(e);
		this.e1 = e1;
		this.arr = arr;
		this.eidx = eidx;
		this.idxNode = idxNode;
		this.value = value;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		if (vector < 0) vector = EvalEmitter.isVectorTyped(e1.type) ? 1 : 0;
		var r:EvalValue;
		if (vector == 1) {
			var vv = EvalEmitter.asVector(ctx, arr.run(ctx, ev), e1.pos);
			var idx = EvalStdLib.decodeIntP(ctx, idxNode.run(ctx, ev), eidx.pos);
			r = value.run(ctx, ev);
			if (idx < 0) EvalExceptions.excString(ctx, "Negative vector index: " + idx, eidx.pos);
			EvalEmitter.vecElemSet(vv, idx, r);
		} else {
			var va = EvalEmitter.asArray(ctx, arr.run(ctx, ev), e1.pos);
			var idx = EvalStdLib.decodeIntP(ctx, idxNode.run(ctx, ev), eidx.pos);
			r = value.run(ctx, ev);
			if (idx < 0) EvalExceptions.excString(ctx, "Negative array index: " + idx, eidx.pos);
			EvalEmitter.arrayElemSet(va, idx, r);
		}
		ev.currentPos = old;
		return r;
	}
}

@:access(hxc.eval.EvalEmitter)
class JRWLocal extends JNode {
	final op:Binop;
	final v:TVar;
	final slot:Int;
	final operand:Null<JNode>;
	final prefix:Bool;

	public function new(e:TExpr, op:Binop, v:TVar, slot:Int, operand:Null<JNode>, prefix:Bool) {
		super(e);
		this.op = op;
		this.v = v;
		this.slot = slot;
		this.operand = operand;
		this.prefix = prefix;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var fe = slot >= 0 ? ev.env : EvalEmitter.localFrame(ev.env, v);
		var s = slot >= 0 ? slot : EvalEmitter.localSlot(fe, v);
		var v1 = fe.locals[s];
		var v2 = operand == null ? VInt(1) : operand.run(ctx, ev);
		var r = EvalEmitter.binopValue(ctx, op, v1, v2, e.pos);
		fe.locals[s] = r;
		ev.currentPos = old;
		return prefix ? r : v1;
	}
}

@:access(hxc.eval.EvalEmitter)
class JRWStatic extends JNode {
	final op:Binop;
	final cl:TClass;
	final cf:TClassField;
	final operand:Null<JNode>;
	final prefix:Bool;

	public function new(e:TExpr, op:Binop, cl:TClass, cf:TClassField, operand:Null<JNode>, prefix:Bool) {
		super(e);
		this.op = op;
		this.cl = cl;
		this.cf = cf;
		this.operand = operand;
		this.prefix = prefix;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var p = e.pos;
		var proto = EvalEmitter.ensureStaticProto(ctx, cl, p);
		var idx = EvalContext.getProtoFieldIndex(proto, EvalHash.hash(cf.name), p);
		var vf = proto.pfields[idx];
		var v2 = operand == null ? VInt(1) : operand.run(ctx, ev);
		var r = EvalEmitter.binopValue(ctx, op, vf, v2, p);
		proto.pfields[idx] = r;
		ev.currentPos = old;
		return prefix ? r : vf;
	}
}

@:access(hxc.eval.EvalEmitter)
class JRWField extends JNode {
	final op:Binop;
	final fe:TExpr;
	final fa:TFieldAccess;
	final obj:JNode;
	final operand:Null<JNode>;
	final prefix:Bool;
	final instance:Bool;

	public function new(e:TExpr, op:Binop, fe:TExpr, fa:TFieldAccess, obj:JNode, operand:Null<JNode>, prefix:Bool, instance:Bool) {
		super(e);
		this.op = op;
		this.fe = fe;
		this.fa = fa;
		this.obj = obj;
		this.operand = operand;
		this.prefix = prefix;
		this.instance = instance;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var p = e.pos;
		var o = obj.run(ctx, ev);
		// A read-write of an instance field takes an instance, or the value is unexpected.
		if (instance) {
			switch (o) {
				case VInstance(_):
				case _: EvalStdLib.unexpectedValueP(ctx, o, "instance", fe.pos);
			}
		}
		var name = EvalEmitter.fieldKey(fa);
		var vf = EvalField.field(ctx, o, name);
		var v2 = operand == null ? VInt(1) : operand.run(ctx, ev);
		var r = EvalEmitter.binopValue(ctx, op, vf, v2, p);
		EvalField.setField(ctx, o, name, r, p);
		ev.currentPos = old;
		return prefix ? r : vf;
	}
}

@:access(hxc.eval.EvalEmitter)
class JRWArray extends JNode {
	final op:Binop;
	final arrE:TExpr;
	final arr:JNode;
	final idxE:TExpr;
	final idxNode:JNode;
	final operand:Null<JNode>;
	final prefix:Bool;
	var vector:Int = -1;

	public function new(e:TExpr, op:Binop, arrE:TExpr, arr:JNode, idxE:TExpr, idxNode:JNode, operand:Null<JNode>, prefix:Bool) {
		super(e);
		this.op = op;
		this.arrE = arrE;
		this.arr = arr;
		this.idxE = idxE;
		this.idxNode = idxNode;
		this.operand = operand;
		this.prefix = prefix;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var p = e.pos;
		if (vector < 0) vector = EvalEmitter.isVectorTyped(arrE.type) ? 1 : 0;
		var result:EvalValue;
		if (vector == 1) {
			var vv = EvalEmitter.asVector(ctx, arr.run(ctx, ev), arrE.pos);
			var idx = EvalStdLib.decodeIntP(ctx, idxNode.run(ctx, ev), idxE.pos);
			if (idx < 0) EvalExceptions.excString(ctx, "Negative vector index: " + idx, idxE.pos);
			var v = EvalEmitter.vecElemGet(vv, idx);
			var v2 = operand == null ? VInt(1) : operand.run(ctx, ev);
			var r = EvalEmitter.binopValue(ctx, op, v, v2, p);
			EvalEmitter.vecElemSet(vv, idx, r);
			result = prefix ? r : v;
		} else {
			var va = EvalEmitter.asArray(ctx, arr.run(ctx, ev), arrE.pos);
			var idx = EvalStdLib.decodeIntP(ctx, idxNode.run(ctx, ev), idxE.pos);
			if (idx < 0) EvalExceptions.excString(ctx, "Negative array index: " + idx, idxE.pos);
			var v = EvalEmitter.arrayElemGet(va, idx);
			var v2 = operand == null ? VInt(1) : operand.run(ctx, ev);
			var r = EvalEmitter.binopValue(ctx, op, v, v2, p);
			EvalEmitter.arrayElemSet(va, idx, r);
			result = prefix ? r : v;
		}
		ev.currentPos = old;
		return result;
	}
}

class JNot extends JNode {
	final a:JNode;

	public function new(e:TExpr, a:JNode) {
		super(e);
		this.a = a;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = switch (a.run(ctx, ev)) {
			case VNull | VFalse: VTrue;
			case _: VFalse;
		};
		ev.currentPos = old;
		return r;
	}
}

// Negation: anything but a number is "Invalid operation".
class JNeg extends JNode {
	final a:JNode;

	public function new(e:TExpr, a:JNode) {
		super(e);
		this.a = a;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = switch (a.run(ctx, ev)) {
			case VInt(i): VInt(-i);
			case VFloat(f): VFloat(-f);
			case _: EvalExceptions.excString(ctx, "Invalid operation", e.pos);
		};
		ev.currentPos = old;
		return r;
	}
}

// ~x is -1 - x.
@:access(hxc.eval.EvalEmitter)
class JNegBits extends JNode {
	final a:JNode;

	public function new(e:TExpr, a:JNode) {
		super(e);
		this.a = a;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = EvalEmitter.binopValue(ctx, OpSub, VInt(-1), a.run(ctx, ev), e.pos);
		ev.currentPos = old;
		return r;
	}
}

// ++ on a local no closure captures increments in place.
@:access(hxc.eval.EvalEmitter)
class JIncLocal extends JNode {
	final e1:TExpr;
	final v:TVar;
	final slot:Int;
	final prefix:Bool;

	public function new(e:TExpr, e1:TExpr, v:TVar, slot:Int, prefix:Bool) {
		super(e);
		this.e1 = e1;
		this.v = v;
		this.slot = slot;
		this.prefix = prefix;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var fe = slot >= 0 ? ev.env : EvalEmitter.localFrame(ev.env, v);
		var s = slot >= 0 ? slot : EvalEmitter.localSlot(fe, v);
		var cur = fe.locals[s];
		var next = switch (cur) {
			case VInt(i): VInt(i + 1);
			case VFloat(f): VFloat(f + 1);
			case _: EvalStdLib.unexpectedValueP(ctx, cur, "number", e1.pos);
		};
		fe.locals[s] = next;
		ev.currentPos = old;
		return prefix ? next : cur;
	}
}

class JIf extends JNode {
	final cond:JNode;
	final then:JNode;
	final otherwise:Null<JNode>;

	public function new(e:TExpr, cond:JNode, then:JNode, otherwise:Null<JNode>) {
		super(e);
		this.cond = cond;
		this.then = then;
		this.otherwise = otherwise;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = if (EvalMisc.isTrue(cond.run(ctx, ev))) then.run(ctx, ev) else if (otherwise != null) otherwise.run(ctx, ev) else VNull;
		ev.currentPos = old;
		return r;
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		if (EvalMisc.isTrue(cond.run(ctx, ev))) then.exec(ctx, ev);
		else if (otherwise != null) otherwise.exec(ctx, ev);
		ev.currentPos = old;
	}
}

// EvalEmitter.evalWhile: a value-position break or continue is caught, a statement-position one is
// the eval's ctrl; a return the body signalled leaves the loop, raised when the loop is a value.
@:access(hxc.eval.EvalEmitter)
class JWhile extends JNode {
	final cond:JNode;
	final body:JNode;
	final doWhile:Bool;

	public function new(e:TExpr, cond:JNode, body:JNode, flag:WhileFlag) {
		super(e);
		this.cond = cond;
		this.body = body;
		this.doWhile = flag == DoWhile;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = loop(ctx, ev, false);
		ev.currentPos = old;
		return r;
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		loop(ctx, ev, true);
		ev.currentPos = old;
	}

	function loop(ctx:EvalContext, ev:Eval, stmt:Bool):EvalValue {
		var loopPos = ev.currentPos;
		if (!doWhile) {
			while (EvalMisc.isTrue(cond.run(ctx, ev))) {
				try body.exec(ctx, ev) catch (_:EvalBreak) { ev.currentPos = loopPos; break; } catch (_:EvalContinue) ev.currentPos = loopPos;
				if (ev.ctrl != 0) {
					if (ev.ctrl == EvalEmitter.CTRL_BREAK) {
						ev.ctrl = 0;
						break;
					}
					if (ev.ctrl != EvalEmitter.CTRL_CONTINUE) return EvalEmitter.loopReturn(ev, stmt);
					ev.ctrl = 0;
				}
				EvalEmitter.poll();
			}
		} else {
			var go = true;
			while (go) {
				try body.exec(ctx, ev) catch (_:EvalBreak) { ev.currentPos = loopPos; break; } catch (_:EvalContinue) ev.currentPos = loopPos;
				if (ev.ctrl != 0) {
					if (ev.ctrl == EvalEmitter.CTRL_BREAK) {
						ev.ctrl = 0;
						break;
					}
					if (ev.ctrl != EvalEmitter.CTRL_CONTINUE) return EvalEmitter.loopReturn(ev, stmt);
					ev.ctrl = 0;
				}
				EvalEmitter.poll();
				go = EvalMisc.isTrue(cond.run(ctx, ev));
			}
		}
		return VNull;
	}
}

// A TFor runs as its hasNext/next loop, lowered when the loop first runs (EvalEmitter.forRemapped); without
// a com it is EvalEmitter.evalFor's loop.
@:access(hxc.eval.EvalEmitter)
class JFor extends JNode {
	final v:TVar;
	final layout:Null<FrameLayout>;
	final iter:JNode;
	final bodyExpr:TExpr;
	var remapped:Null<JNode> = null;
	var body:Null<JNode> = null;

	public function new(e:TExpr, v:TVar, layout:Null<FrameLayout>, iter:JNode, bodyExpr:TExpr) {
		super(e);
		this.v = v;
		this.layout = layout;
		this.iter = iter;
		this.bodyExpr = bodyExpr;
	}

	function remap(ctx:EvalContext):Null<JNode> {
		if (remapped != null) return remapped;
		var com = ctx.com != null ? ctx.com : @:privateAccess hxc.eval.EvalMacro.macroCom;
		if (com == null) return null;
		var eiter = switch (e.expr) {
			case TFor(_, ei, _): ei;
			case _: null;
		};
		remapped = EvalJit.compile(ctx, layout, EvalEmitter.forRemapped(com, e, v, eiter, bodyExpr));
		return remapped;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = remap(ctx);
		var result = r != null ? r.run(ctx, ev) : iterate(ctx, ev, false);
		ev.currentPos = old;
		return result;
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = remap(ctx);
		if (r != null) r.exec(ctx, ev) else iterate(ctx, ev, true);
		ev.currentPos = old;
	}

	function iterate(ctx:EvalContext, ev:Eval, stmt:Bool):EvalValue {
		if (body == null) body = EvalJit.compile(ctx, layout, bodyExpr);
		var p = e.pos;
		var it = iter.run(ctx, ev);
		var env = ev.env;
		var loopPos = ev.currentPos;
		while (EvalMisc.isTrue(EvalEmitter.callField(ctx, it, "hasNext", [], p))) {
			env.locals[EvalEmitter.localSlot(env, v)] = EvalEmitter.callField(ctx, it, "next", [], p);
			try body.exec(ctx, ev) catch (_:EvalBreak) { ev.currentPos = loopPos; break; } catch (_:EvalContinue) ev.currentPos = loopPos;
			if (ev.ctrl != 0) {
				if (ev.ctrl == EvalEmitter.CTRL_BREAK) {
					ev.ctrl = 0;
					break;
				}
				if (ev.ctrl != EvalEmitter.CTRL_CONTINUE) return EvalEmitter.loopReturn(ev, stmt);
				ev.ctrl = 0;
			}
			EvalEmitter.poll();
		}
		return VNull;
	}
}

@:access(hxc.eval.EvalEmitter)
class JReturn extends JNode {
	final value:Null<JNode>;

	public function new(e:TExpr, value:Null<JNode>) {
		super(e);
		this.value = value;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		if (pos != null) ev.currentPos = pos;
		throw new EvalReturn(value == null ? VNull : value.run(ctx, ev));
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var v = value == null ? VNull : value.run(ctx, ev);
		ev.ctrlValue = v;
		ev.ctrl = EvalEmitter.CTRL_RETURN;
		ev.currentPos = old;
	}
}

@:access(hxc.eval.EvalEmitter)
class JBreak extends JNode {
	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		if (pos != null) ev.currentPos = pos;
		throw new EvalBreak();
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		ev.ctrl = EvalEmitter.CTRL_BREAK;
	}
}

@:access(hxc.eval.EvalEmitter)
class JContinue extends JNode {
	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		if (pos != null) ev.currentPos = pos;
		throw new EvalContinue();
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		ev.ctrl = EvalEmitter.CTRL_CONTINUE;
	}
}

// A throw raises at its own position.
class JThrow extends JNode {
	final value:JNode;

	public function new(e:TExpr, value:JNode) {
		super(e);
		this.value = value;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		if (pos != null) ev.currentPos = pos;
		return EvalExceptions.throwValue(ctx, value.run(ctx, ev), e.pos);
	}
}

class JArrayDecl extends JNode {
	final nodes:Array<JNode>;

	public function new(e:TExpr, nodes:Array<JNode>) {
		super(e);
		this.nodes = nodes;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = VArray(new VArray([for (x in nodes) x.run(ctx, ev)], nodes.length));
		ev.currentPos = old;
		return r;
	}
}

// Each field's name is hashed where the tree walk hashes it, on the first run, and kept.
class JObjectDecl extends JNode {
	final fields:Array<TObjectField>;
	final nodes:Array<JNode>;
	var keys:Null<Array<Int>> = null;

	public function new(e:TExpr, fields:Array<TObjectField>, nodes:Array<JNode>) {
		super(e);
		this.fields = fields;
		this.nodes = nodes;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var m = new Map<Int, EvalValue>();
		var ks = keys;
		if (ks == null) {
			for (i in 0...fields.length) m.set(EvalHash.hash(fields[i].key.name), nodes[i].run(ctx, ev));
			keys = [for (f in fields) EvalHash.hash(f.key.name)];
		} else {
			for (i in 0...ks.length) m.set(ks[i], nodes[i].run(ctx, ev));
		}
		var r = VObject(new VObject([], ODictionary(m)));
		ev.currentPos = old;
		return r;
	}
}

@:access(hxc.eval.EvalEmitter)
class JTry extends JNode {
	final body:JNode;
	final catches:Array<TCatch>;
	final handlers:Array<JNode>;
	var paths:Null<Array<Null<Int>>> = null;

	public function new(e:TExpr, body:JNode, catches:Array<TCatch>, handlers:Array<JNode>) {
		super(e);
		this.body = body;
		this.catches = catches;
		this.handlers = handlers;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = attempt(ctx, ev, false);
		ev.currentPos = old;
		return r;
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		attempt(ctx, ev, true);
		ev.currentPos = old;
	}

	function attempt(ctx:EvalContext, ev:Eval, stmt:Bool):EvalValue {
		var savedEnv = ev.env;
		var tryPos = ev.currentPos;
		var result:EvalValue = VNull;
		ev.lastExceptionPos = Position.nullPos;
		try {
			if (stmt) body.exec(ctx, ev) else result = body.run(ctx, ev);
		} catch (ex:EvalRunTimeException) {
			ev.env = savedEnv;
			ev.currentPos = tryPos;
			// The exception stack up to this try's environment.
			ev.exceptionStack = EvalExceptions.buildExceptionStack(ex, savedEnv);
			result = runCatch(ctx, ev, ex.value, savedEnv, function() { throw ex; }, stmt);
		} catch (ex:Dynamic) {
			// Control-flow signals must reach their own handlers, never a program try/catch.
			if (Std.isOfType(ex, EvalBreak) || Std.isOfType(ex, EvalContinue) || Std.isOfType(ex, EvalReturn) || Std.isOfType(ex, EvalSysExit)
				|| Std.isOfType(ex, EvalThreadExit)) throw ex;
			// A try catches runtime exceptions alone (see EvalEmitter.evalTry).
			if (Std.isOfType(ex, hxc.eval.EvalExceptions.MacroAbort) || Std.isOfType(ex, hxc.core.TypingError.FatalError) || Std.isOfType(ex, hxc.core.TypingError)
				|| Std.isOfType(ex, hxc.eval.EvalExceptions.HostException)) throw ex;
			if (ev.lastExceptionPos == null || ev.lastExceptionPos.min < 0) ev.lastExceptionPos = ev.currentPos;
			ev.env = savedEnv;
			ev.currentPos = tryPos;
			ev.exceptionStack = EvalEmitter.hostExceptionStack(ev);
			var s = Std.string(ex);
			var v = hxc.eval.EvalString.EvalString.vOfText(s);
			result = runCatch(ctx, ev, v, savedEnv, function() return EvalExceptions.throwValue(ctx, v, e.pos), stmt);
		}
		return result;
	}

	// EvalEmitter.runCatch: a clause's type path is worked out when a value first meets it.
	function runCatch(ctx:EvalContext, ev:Eval, value:EvalValue, savedEnv:EvalEnv, onUnmatched:Void->EvalValue, stmt:Bool):EvalValue {
		if (paths == null) paths = [for (_ in catches) null];
		for (i in 0...catches.length) {
			var c = catches[i];
			var path = paths[i];
			if (path == null) {
				path = EvalEmitter.catchPath(c.v.type);
				paths[i] = path == null ? -1 : path;
			} else if (path == -1) path = null;
			if (path == null || EvalStdLib.isOfTypePath(ctx, value, path)) {
				savedEnv.locals[EvalEmitter.localSlot(savedEnv, c.v)] = value;
				if (!stmt) return handlers[i].run(ctx, ev);
				handlers[i].exec(ctx, ev);
				return VNull;
			}
		}
		return onUnmatched();
	}
}

// A value typed eval.Vector reads as a vector, anything else as an array.
@:access(hxc.eval.EvalEmitter)
class JArray extends JNode {
	final arr:JNode;
	final e1:TExpr;
	final idxNode:JNode;
	final e2:TExpr;
	var vector:Int = -1;

	public function new(e:TExpr, arr:JNode, e1:TExpr, idxNode:JNode, e2:TExpr) {
		super(e);
		this.arr = arr;
		this.e1 = e1;
		this.idxNode = idxNode;
		this.e2 = e2;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		if (vector < 0) vector = EvalEmitter.isVectorTyped(e1.type) ? 1 : 0;
		var r:EvalValue;
		if (vector == 1) {
			var vv = EvalEmitter.asVector(ctx, arr.run(ctx, ev), e1.pos);
			var idx = EvalStdLib.decodeIntP(ctx, idxNode.run(ctx, ev), e2.pos);
			r = EvalEmitter.vecElemGet(vv, idx);
		} else {
			var va = EvalEmitter.asArray(ctx, arr.run(ctx, ev), e1.pos);
			var idx = EvalStdLib.decodeIntP(ctx, idxNode.run(ctx, ev), e2.pos);
			r = EvalEmitter.arrayElemGet(va, idx);
		}
		ev.currentPos = old;
		return r;
	}
}

class JTypeExpr extends JNode {
	final mt:ModuleType;

	public function new(e:TExpr, mt:ModuleType) {
		super(e);
		this.mt = mt;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		// A type without an eval prototype (e.g. the core-type abstracts Int/Float/Bool) still
		// needs a value marker carrying its path, for Std.isOfType and reflection.
		var tpath = EvalHash.pathHash(TypeFunctions.tPath(mt));
		var tproto = ctx.staticPrototypes.get(tpath);
		if (tproto == null) {
			tproto = new VPrototype(tpath, [], new Map(), [], new Map(), null, PClass([]), VNull);
			tproto.pvalue = VPrototype(tproto);
			ctx.staticPrototypes.set(tpath, tproto);
		}
		return tproto.pvalue;
	}
}

class JFunction extends JNode {
	final tf:TFunc;

	public function new(e:TExpr, tf:TFunc) {
		super(e);
		this.tf = tf;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = VFunction(EvalJit.makeClosure(ctx, tf, ev.env), true);
		ev.currentPos = old;
		return r;
	}
}

// EvalEmitter.evalField with its receiver evaluated by the node (no receiver for a static or an enum
// constructor).
@:access(hxc.eval.EvalEmitter)
class JField extends JNode {
	final e1:TExpr;
	final fa:TFieldAccess;
	final recv:Null<JNode>;

	public function new(e:TExpr, e1:TExpr, fa:TFieldAccess, recv:Null<JNode>) {
		super(e);
		this.e1 = e1;
		this.fa = fa;
		this.recv = recv;
	}

	// 0 not yet known; 1 a class's var read (EvalEmitter.evalField's last FInstance case), 2 any other.
	var mode:Int = 0;
	var cf:Null<TClassField> = null;
	var hash:Int = -1;
	// The slot the name has on the last instance prototype seen. Slots are only ever added to a
	// prototype, so an index once found stays right.
	var cacheProto:Null<VPrototype> = null;
	var cacheIdx:Int = -1;

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		if (mode == 0) mode = varRead();
		var r = if (mode == 1) readVar(ctx, recv.run(ctx, ev)) else EvalEmitter.evalField(ctx, e1, fa, e.pos, recv == null ? null : recv.run(ctx, ev));
		ev.currentPos = old;
		return r;
	}

	function varRead():Int {
		switch (fa) {
			case FInstance(c, _, f):
				if (f.name == "length" && (EvalEmitter.isArrayClass(c) || EvalEmitter.isEvalVector(c) || EvalEmitter.isBytesClass(c))) return 2;
				if (!f.kind.match(Var(_))) return 2;
				cf = f;
				return 1;
			case _:
				return 2;
		}
	}

	// evalField's instance read: an instance's field (the field read on it, or `stack` on an exception
	// read from its native stack); anything else as evalField takes it.
	function readVar(ctx:EvalContext, rv:EvalValue):EvalValue {
		switch (rv) {
			case VInstance(vi):
				if (hash < 0) hash = EvalHash.hash(cf.name);
				var v:EvalValue;
				if (vi.iproto == cacheProto) {
					v = vi.ifields[cacheIdx];
				} else {
					v = EvalField.field(ctx, rv, hash);
					if (hash != EvalHash.keyLength) {
						var i = vi.iproto.pinstanceNames.get(hash);
						if (i != null) {
							cacheProto = vi.iproto;
							cacheIdx = i;
						}
					}
				}
				return (v == VNull && cf.name == "stack" && EvalStdLib.isOfTypePath(ctx, rv, EvalHash.keyHaxeException)) ? EvalField.field(ctx, rv, EvalHash.keyNativeStack) : v;
			case _:
				return EvalEmitter.evalField(ctx, e1, fa, e.pos, rv);
		}
	}
}

// An enum value remembers where it was constructed.
class JEnumCall extends JNode {
	final en:TEnum;
	final ef:TEnumField;
	final args:Array<JNode>;

	public function new(e:TExpr, en:TEnum, ef:TEnumField, args:Array<JNode>) {
		super(e);
		this.en = en;
		this.ef = ef;
		this.args = args;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var values = [for (a in args) a.run(ctx, ev)];
		var r = VEnumValue(new VEnumValue(ef.index, values, EvalHash.pathHash(en.path), e.pos));
		ev.currentPos = old;
		return r;
	}
}

class JMkPos extends JNode {
	final args:Array<JNode>;

	public function new(e:TExpr, args:Array<JNode>) {
		super(e);
		this.args = args;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = EvalMacro.mkPosValue([for (x in args) x.run(ctx, ev)]);
		ev.currentPos = old;
		return r;
	}
}

// EvalEmitter.evalCall, with the callee's receiver (a field call on anything but a static or an enum
// constructor) or the callee itself compiled.
@:access(hxc.eval.EvalEmitter)
@:access(hxc.eval.EvalJit)
class JCall extends JNode {
	final callee:TExpr;
	final argExprs:Array<TExpr>;
	final args:Array<JNode>;
	final recv:Null<JNode>;
	final calleeNode:Null<JNode>;
	// 0 unknown, 1 a trace call, 2 not.
	var trace:Int = 0;
	// A proper static method, read on the call's first run in a request and kept for the request.
	var staticFn:Null<EvalValue> = null;
	var staticEpoch:Int = -1;
	// An instance method's name, hashed on the first run, and the method last found for an instance of
	// `methodProto` with no slot of that name (methodSlots slots then; a slot added since could hold it).
	var methodHash:Int = -1;
	var methodProto:Null<VPrototype> = null;
	var methodSlots:Int = -1;
	var methodFn:Null<VFunc> = null;

	public function new(e:TExpr, callee:TExpr, argExprs:Array<TExpr>, args:Array<JNode>, recv:Null<JNode>, calleeNode:Null<JNode>) {
		super(e);
		this.callee = callee;
		this.argExprs = argExprs;
		this.args = args;
		this.recv = recv;
		this.calleeNode = calleeNode;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = call(ctx, ev);
		ev.currentPos = old;
		return r;
	}

	inline function evalArgs(ctx:EvalContext, ev:Eval):Array<EvalValue> {
		return evalArgsFrom(ctx, ev, 0);
	}

	// The arguments' values from index `first` on, the array made at its size.
	function evalArgsFrom(ctx:EvalContext, ev:Eval, first:Int):Array<EvalValue> {
		var n = args.length;
		var argv:Array<EvalValue> = [];
		argv.resize(n + first);
		for (i in 0...n) argv[i + first] = args[i].run(ctx, ev);
		return argv;
	}

	function call(ctx:EvalContext, ev:Eval):EvalValue {
		var p = e.pos;
		switch (callee.expr) {
			case TConst(TSuper):
				// Super() checks the depth first; a native-backed parent's special super call records no leave
				// position, an interpreted parent's is recorded after the arguments (callAt).
				EvalJit.checkDepth(ctx, ev);
				var argv = evalArgs(ctx, ev);
				var vthis = ev.env.vthis;
				switch (TypeFunctions.follow(callee.type)) {
					case TInst(c, _):
						var key = EvalHash.pathHash(c.path);
						var cb = ctx.builtins.constructorBuiltins.get(key);
						if (cb != null) {
							switch [vthis, cb(argv)] {
								case [VInstance(vt), VInstance(built)]: EvalStdLib.superDelegates.set(vt, built);
								case _:
							}
						} else {
							var ctor = ctx.constructors.get(key);
							if (ctor == null && c.constructor != null) {
								EvalEmitter.forceInWorld(ctx, c);
								var made = hxc.eval.EvalPrototype.makeConstructor(ctx, c);
								if (made != null) {
									ctx.constructors.set(key, made);
									ctor = made;
								}
							}
							if (ctor != null) EvalJit.callAt(ev, p, ctor, [vthis].concat(argv));
						}
					case _:
				}
				return VNull;
			case TField({expr: TConst(TSuper)}, fa):
				// A `super.method()` call dispatches to the definition on the named class.
				var c = switch (fa) {
					case FInstance(cc, _, _): cc;
					case FClosure(cc, _): cc == null ? null : cc.c;
					case _: null;
				};
				var cf = switch (fa) {
					case FInstance(_, _, f) | FClosure(_, f): f;
					case _: null;
				};
				if (c != null && cf != null) {
					var proto = ctx.instancePrototypes.get(EvalHash.pathHash(c.path));
					var m = EvalEmitter.superProtoMethod(proto, EvalHash.hash(cf.name));
					var vthis = ev.env.vthis;
					// A super field call: the depth check, the arguments, and the call with no leave position
					// recorded.
					EvalJit.checkDepth(ctx, ev);
					var argv = evalArgs(ctx, ev);
					switch (m) {
						case VFunction(f, _): return f([vthis].concat(argv));
						case _:
					}
				}
			case _:
		}
		switch (callee.expr) {
			// StringTools.fastCodeAt and unsafeCodeAt are intrinsics.
			case TField(_, FStatic(c, cf)) if (argExprs.length == 2 && c.path.pack.length == 0 && c.path.name == "StringTools" && (cf.name == "fastCodeAt" || cf.name == "unsafeCodeAt")):
				var s = EvalStdLib.decodeVString(ctx, args[0].run(ctx, ev));
				var index = EvalStdLib.decodeIntP(ctx, args[1].run(ctx, ev), p);
				if (cf.name == "unsafeCodeAt") return VInt(hxc.eval.EvalString.EvalString.charAt(s, index));
				return index < 0 || index >= s.slength ? VNull : VInt(hxc.eval.EvalString.EvalString.charAt(s, index));
			case _:
		}
		EvalJit.checkDepth(ctx, ev);
		var leaveFirst = switch (callee.expr) {
			case TField(_, FStatic(_, cf)): !EvalEmitter.isProperMethod(cf);
			case TField(_, FInstance(_, _, cf)): !EvalEmitter.isProperMethod(cf);
			case _: true;
		};
		// A method read off an instance is called with the receiver directly, without the bound-method
		// value EvalField.dynamicField would make for it.
		var direct:Null<VFunc> = null;
		var directRecv:EvalValue = VNull;
		var fn = switch (callee.expr) {
			// The receiver first, null-checked at its position.
			case TField(e1, fa) if (!fa.match(FStatic(_, _) | FEnum(_, _))):
				var recvValue = recv.run(ctx, ev);
				if (recvValue == VNull) EvalExceptions.excString(ctx, "Null Access", e1.pos);
				switch [fa, recvValue] {
					case [FInstance(c, _, cf), VInt(_) | VFloat(_) | VTrue | VFalse | VObject(_) | VEnumValue(_) | VFunction(_, _) | VFieldClosure(_, _)
						| VNativeString(_) | VString(_) | VArray(_) | VVector(_) | VPrototype(_)] if (EvalEmitter.isProperMethod(cf)):
						if (EvalEmitter.isFinalMethod(ctx, c, cf) && !TypeFunctions.hasClassFlag(c, CInterface)) {
							var proto = EvalContext.getInstancePrototype(ctx, EvalHash.pathHash(c.path), callee.pos);
							switch (try EvalField.protoFieldRaise(proto, EvalHash.hash(cf.name)) catch (_:hxc.core.NotFound) VNull) {
								case VFunction(f, _): VFieldClosure(recvValue, f);
								case m: m;
							}
						} else {
							var proto = switch (recvValue) {
								case VPrototype(pr): pr;
								case VString(_): ctx.stringPrototype;
								case VArray(_): ctx.arrayPrototype;
								case VVector(_): ctx.vectorPrototype;
								case _: EvalStdLib.unexpectedValueP(ctx, recvValue, "instance", p);
							};
							var m = try EvalField.protoFieldRaise(proto, EvalHash.hash(cf.name)) catch (_:hxc.core.NotFound)
								EvalExceptions.excString(ctx, "Field " + cf.name + " not found on prototype " + EvalHash.revHash(proto.ppath), p);
							switch (m) {
								case VFunction(f, _): VFieldClosure(recvValue, f);
								case _: m;
							}
						}
					// EvalEmitter.evalField's read of a method on a receiver that is not null:
					// EvalField.dynamicField.
					case [FInstance(_, _, cf), _] if (cf.kind.match(Method(_))):
						if (methodHash < 0) methodHash = EvalHash.hash(cf.name);
						var rv = EvalValueTools.vresolve(recvValue);
						var cached:Null<VFunc> = null;
						switch (rv) {
							case VInstance(vi) if (vi.iproto == methodProto && vi.iproto.pinstanceFields.length == methodSlots):
								cached = methodFn;
							case _:
						}
						if (cached != null) {
							direct = cached;
							directRecv = rv;
							VNull;
						} else switch (EvalField.field(ctx, rv, methodHash)) {
							case VFunction(f, false):
								direct = f;
								directRecv = rv;
								// Field read it off the prototype chain when the instance has no slot of the name
								switch (rv) {
									case VInstance(vi) if (methodHash != EvalHash.keyLength && !vi.iproto.pinstanceNames.exists(methodHash)):
										methodProto = vi.iproto;
										methodSlots = vi.iproto.pinstanceFields.length;
										methodFn = f;
									case _:
								}
								VNull;
							case _:
								EvalValueTools.vresolve(EvalField.dynamicField(ctx, rv, methodHash));
						}
					case _:
						EvalValueTools.vresolve(EvalEmitter.evalField(ctx, e1, fa, callee.pos, recvValue));
				}
			// A proper static method's slot is read before the arguments.
			case TField(_, FStatic(_, cf)) if (EvalEmitter.isProperMethod(cf)):
				if (staticEpoch == EvalJit.epoch && staticFn != null) staticFn else {
					var f = switch (EvalValueTools.vresolve(calleeNode.run(ctx, ev))) {
						case v = VFunction(_, _): v;
						case v: EvalExceptions.excValues(ctx, ["Cannot call ", ""], [v], p);
					};
					staticFn = f;
					staticEpoch = EvalJit.epoch;
					f;
				}
			case _: EvalValueTools.vresolve(calleeNode.run(ctx, ev));
		};
		if (leaveFirst && ev.env != null) EvalExceptions.setLeavePosition(ev.env, p);
		if (direct != null) {
			var argv = evalArgsFrom(ctx, ev, 1);
			argv[0] = directRecv;
			return leaveFirst ? direct(argv) : EvalJit.callAt(ev, p, direct, argv);
		}
		var argv = evalArgs(ctx, ev);
		if (trace == 0) {
			trace = switch (callee.expr) {
				case TField(_, FStatic(c, cf)) if (cf.name == "trace" && c.path.name == "Log" && c.path.pack.length == 1 && c.path.pack[0] == "haxe"): 1;
				case _: 2;
			};
		}
		if (trace == 1 && EvalEmitter.isEvalTarget(ctx)) {
			if (argExprs.length > 0 && EvalEmitter.isUIntExpr(argExprs[0])) argv[0] = EvalEmitter.unsignedValue(argv[0]);
			if (argExprs.length > 1) argv[1] = EvalEmitter.normalizeTraceValue(argExprs[1], argv[1]);
		}
		return switch (fn) {
			case VFunction(f, _): leaveFirst ? f(argv) : EvalJit.callAt(ev, p, f, argv);
			case VFieldClosure(r, f):
				argv.insert(0, r);
				leaveFirst ? f(argv) : EvalJit.callAt(ev, p, f, argv);
			// A macro's TLazy(f) is called to force the type.
			case VInstance({ikind: ILazyType(_, get)}): get();
			case v:
				if (ev.env != null) EvalExceptions.setLeavePosition(ev.env, p);
				EvalExceptions.excValues(ctx, ["Cannot call ", ""], [v]);
		};
	}
}

@:access(hxc.eval.EvalEmitter)
@:access(hxc.eval.EvalJit)
class JNew extends JNode {
	final cl:TClass;
	final params:TParams;
	final argExprs:Array<TExpr>;
	final args:Array<JNode>;

	public function new(e:TExpr, cl:TClass, params:TParams, argExprs:Array<TExpr>, args:Array<JNode>) {
		super(e);
		this.cl = cl;
		this.params = params;
		this.argExprs = argExprs;
		this.args = args;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		// A class with a special (native) constructor constructs natively, with no depth check; any other
		// through a constructor call.
		if (!ctx.builtins.constructorBuiltins.exists(EvalHash.pathHash(cl.path))) EvalJit.checkDepth(ctx, ev);
		var r = EvalEmitter.evalNew(ctx, cl, params, [for (a in args) a.run(ctx, ev)], e.pos, argExprs.length == 0 ? null : argExprs[0].pos);
		ev.currentPos = old;
		return r;
	}
}

@:access(hxc.eval.EvalEmitter)
class JSwitch extends JNode {
	final subject:JNode;
	final subjectExpr:TExpr;
	final cases:Array<TSwitchCase>;
	final values:Array<Array<JNode>>;
	final bodies:Array<JNode>;
	final def:Null<JNode>;
	var intSwitch:Int = -1;

	public function new(e:TExpr, subject:JNode, subjectExpr:TExpr, cases:Array<TSwitchCase>, values:Array<Array<JNode>>, bodies:Array<JNode>, def:Null<JNode>) {
		super(e);
		this.subject = subject;
		this.subjectExpr = subjectExpr;
		this.cases = cases;
		this.values = values;
		this.bodies = bodies;
		this.def = def;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = select(ctx, ev, false);
		ev.currentPos = old;
		return r;
	}

	override public function exec(ctx:EvalContext, ev:Eval):Void {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		select(ctx, ev, true);
		ev.currentPos = old;
	}

	function select(ctx:EvalContext, ev:Eval, stmt:Bool):EvalValue {
		var v = subject.run(ctx, ev);
		// An Int subject whose cases are all integer constants takes an Int32 or null, anything else
		// unexpected.
		switch (v) {
			case VInt(_) | VNull:
			case _:
				if (intSwitch < 0) intSwitch = EvalEmitter.isIntSwitch(subjectExpr, cases) ? 1 : 0;
				if (intSwitch == 1) EvalStdLib.unexpectedValueP(ctx, v, "int", subjectExpr.pos);
		}
		for (i in 0...values.length) {
			for (cv in values[i]) {
				if (EvalValueTools.equals(v, cv.run(ctx, ev))) {
					if (!stmt) return bodies[i].run(ctx, ev);
					bodies[i].exec(ctx, ev);
					return VNull;
				}
			}
		}
		if (def == null) return VNull;
		if (!stmt) return def.run(ctx, ev);
		def.exec(ctx, ev);
		return VNull;
	}
}

class JEnumParameter extends JNode {
	final a:JNode;
	final e1:TExpr;
	final index:Int;

	public function new(e:TExpr, a:JNode, e1:TExpr, index:Int) {
		super(e);
		this.a = a;
		this.e1 = e1;
		this.index = index;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = switch (a.run(ctx, ev)) {
			case VEnumValue(v): v.eargs[index];
			case v: EvalExceptions.unexpectedValue(ctx, v, "enum value", e1.pos);
		};
		ev.currentPos = old;
		return r;
	}
}

// The enum index: the value is decoded as an enum value.
class JEnumIndex extends JNode {
	final a:JNode;
	final e1:TExpr;

	public function new(e:TExpr, a:JNode, e1:TExpr) {
		super(e);
		this.a = a;
		this.e1 = e1;
	}

	override public function run(ctx:EvalContext, ev:Eval):EvalValue {
		var old = ev.currentPos;
		if (pos != null) ev.currentPos = pos;
		var r = switch (a.run(ctx, ev)) {
			case VEnumValue(v): VInt(v.eindex);
			case v: EvalStdLib.unexpectedValueP(ctx, v, "enum value", e1.pos);
		};
		ev.currentPos = old;
		return r;
	}
}
