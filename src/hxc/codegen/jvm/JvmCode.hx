package hxc.codegen.jvm;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import hxc.core.Ref;
import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmData;
import hxc.codegen.jvm.JvmSignature;

// emitting opcodes while tracking what is on the operand stack, so the maximum stack size and the frame
// types come out of the emission itself.

class EmptyStack {
	public function new() {}
}

typedef StackState = {stack:Array<JSignature>, size:Int};

class JvmStack {
	// the top of the stack is the FIRST element
	var stack:Array<JSignature> = [];
	var stackSize = 0;
	var maxStackSize = 0;

	public function new() {}

	public function push(js:JSignature):Void {
		stack.unshift(js);
		stackSize += JvmSignature.signatureSize(js);
		if (stackSize > maxStackSize) maxStackSize = stackSize;
	}

	public function pop():JSignature {
		if (stack.length == 0) throw new EmptyStack();
		var js = stack.shift();
		stackSize -= JvmSignature.signatureSize(js);
		return js;
	}

	public function toString():String {
		return "[" + [for (js in stack) JvmSignature.generateSignature(false, js)].join(", ") + "]";
	}

	public function save():StackState {
		return {stack: stack.copy(), size: stackSize};
	}

	public function top():JSignature {
		if (stack.length == 0) throw new EmptyStack();
		return stack[0];
	}

	public function restore(s:StackState):Void {
		stack = s.stack.copy();
		stackSize = s.size;
	}

	public function getMaxStackSize():Int return maxStackSize;
	public function setMaxStackSize(v:Int):Void maxStackSize = v;
	public function getStack():Array<JSignature> return stack;

	// the top i items, TOP FIRST. That is the order `op` takes its expect/return lists in, and the order
	// dupX1, dupX2, swap and TexprToJvm.doCompare read them in. Bottom-first order would make dupX1 record
	// the wrong type as the new top, and a later cast would then emit bytecode the verifier rejects.
	public function getStackItems(i:Int):Array<JSignature> {
		if (i > stack.length) throw new EmptyStack();
		var acc = [];
		for (k in 0...i) acc.push(stack[k]);
		return acc;
	}

	public function replace(jsig:JSignature):Void {
		pop();
		push(jsig);
	}
}

class JvmCode {
	public static function terminates(op:JOpCode):Bool {
		return switch (op) {
			case OpDreturn | OpFreturn | OpIreturn | OpLreturn | OpAreturn
				| OpGoto(_) | OpGoto_w(_) | OpJsr(_) | OpJsr_w(_) | OpAthrow | OpReturn: true;
			case _: false;
		}
	}
}

class CodeBuilder {
	public var stack(default, null):JvmStack = new JvmStack();
	var pool:JvmConstantPool;
	var lines:Array<{pc:Int, line:Int}> = [];
	var lastLine = -1;
	var currentLine = -1;
	var ops:Array<JOpCode> = [];
	var fp = 0;
	var terminated = false;

	public function new(pool:JvmConstantPool) {
		this.pool = pool;
	}

	public function isTerminated():Bool return terminated;
	public function setTerminated(b:Bool):Void terminated = b;

	// what the op expects is popped, what it returns is pushed in reverse.
	public function op(opcode:JOpCode, length:Int, expect:Array<JSignature>, ret:Array<JSignature>):Void {
		if (lastLine != currentLine) {
			lastLine = currentLine;
			lines.push({pc: fp, line: currentLine});
		}
		ops.push(opcode);
		fp += length;
		for (_ in expect) stack.pop();
		var i = ret.length;
		while (i-- > 0) stack.push(ret[i]);
		if (JvmCode.terminates(opcode)) terminated = true;
	}

	public function opMaybeWide(o:JOpCode, ow:JOpWide, i:Int, tl:Array<JSignature>, tr:Array<JSignature>):Void {
		switch (JvmGlobals.getNumericRangeUnsigned(i)) {
			case Int8Range: op(o, 2, tl, tr);
			case Int16Range: op(OpWide(ow), 4, tl, tr);
			case Int32Range: JvmGlobals.jerror("local index out of range");
		}
	}


	public function iload(i:Int, ?jsig:JSignature):Void {
		if (jsig == null) jsig = TInt;
		switch (i) {
			case 0: op(OpIload_0, 1, [], [jsig]);
			case 1: op(OpIload_1, 1, [], [jsig]);
			case 2: op(OpIload_2, 1, [], [jsig]);
			case 3: op(OpIload_3, 1, [], [jsig]);
			case i: opMaybeWide(OpIload(i), OpWIload(i), i, [], [jsig]);
		}
	}

	public function lload(i:Int):Void {
		switch (i) {
			case 0: op(OpLload_0, 1, [], [TLong]);
			case 1: op(OpLload_1, 1, [], [TLong]);
			case 2: op(OpLload_2, 1, [], [TLong]);
			case 3: op(OpLload_3, 1, [], [TLong]);
			case i: opMaybeWide(OpLload(i), OpWLload(i), i, [], [TLong]);
		}
	}

	public function fload(i:Int):Void {
		switch (i) {
			case 0: op(OpFload_0, 1, [], [TFloat]);
			case 1: op(OpFload_1, 1, [], [TFloat]);
			case 2: op(OpFload_2, 1, [], [TFloat]);
			case 3: op(OpFload_3, 1, [], [TFloat]);
			case i: opMaybeWide(OpFload(i), OpWFload(i), i, [], [TFloat]);
		}
	}

	public function dload(i:Int):Void {
		switch (i) {
			case 0: op(OpDload_0, 1, [], [TDouble]);
			case 1: op(OpDload_1, 1, [], [TDouble]);
			case 2: op(OpDload_2, 1, [], [TDouble]);
			case 3: op(OpDload_3, 1, [], [TDouble]);
			case i: opMaybeWide(OpDload(i), OpWDload(i), i, [], [TDouble]);
		}
	}

	public function aload(vtt:JSignature, i:Int):Void {
		switch (i) {
			case 0: op(OpAload_0, 1, [], [vtt]);
			case 1: op(OpAload_1, 1, [], [vtt]);
			case 2: op(OpAload_2, 1, [], [vtt]);
			case 3: op(OpAload_3, 1, [], [vtt]);
			case i: opMaybeWide(OpAload(i), OpWAload(i), i, [], [vtt]);
		}
	}

	public function istore(i:Int):Void {
		switch (i) {
			case 0: op(OpIstore_0, 1, [TInt], []);
			case 1: op(OpIstore_1, 1, [TInt], []);
			case 2: op(OpIstore_2, 1, [TInt], []);
			case 3: op(OpIstore_3, 1, [TInt], []);
			case i: opMaybeWide(OpIstore(i), OpWIstore(i), i, [TInt], []);
		}
	}

	public function lstore(i:Int):Void {
		switch (i) {
			case 0: op(OpLstore_0, 1, [TLong], []);
			case 1: op(OpLstore_1, 1, [TLong], []);
			case 2: op(OpLstore_2, 1, [TLong], []);
			case 3: op(OpLstore_3, 1, [TLong], []);
			case i: opMaybeWide(OpLstore(i), OpWLstore(i), i, [TLong], []);
		}
	}

	public function fstore(i:Int):Void {
		switch (i) {
			case 0: op(OpFstore_0, 1, [TFloat], []);
			case 1: op(OpFstore_1, 1, [TFloat], []);
			case 2: op(OpFstore_2, 1, [TFloat], []);
			case 3: op(OpFstore_3, 1, [TFloat], []);
			case i: opMaybeWide(OpFstore(i), OpWFstore(i), i, [TFloat], []);
		}
	}

	public function dstore(i:Int):Void {
		switch (i) {
			case 0: op(OpDstore_0, 1, [TDouble], []);
			case 1: op(OpDstore_1, 1, [TDouble], []);
			case 2: op(OpDstore_2, 1, [TDouble], []);
			case 3: op(OpDstore_3, 1, [TDouble], []);
			case i: opMaybeWide(OpDstore(i), OpWDstore(i), i, [TDouble], []);
		}
	}

	public function astore(vtt:JSignature, i:Int):Void {
		switch (i) {
			case 0: op(OpAstore_0, 1, [vtt], []);
			case 1: op(OpAstore_1, 1, [vtt], []);
			case 2: op(OpAstore_2, 1, [vtt], []);
			case 3: op(OpAstore_3, 1, [vtt], []);
			case i: opMaybeWide(OpAstore(i), OpWAstore(i), i, [vtt], []);
		}
	}

	public function iinc(index:Int, i:Int):Void {
		switch [JvmGlobals.getNumericRangeUnsigned(index), JvmGlobals.getNumericRange(i)] {
			case [Int8Range, Int8Range]: op(OpIinc(index, i), 3, [], []);
			case [Int8Range | Int16Range, Int8Range | Int16Range]: op(OpWide(OpWIinc(index, i)), 6, [], []);
			case _: JvmGlobals.jerror("iinc out of range");
		}
	}


	public function d2f():Void op(OpD2f, 1, [TDouble], [TFloat]);
	public function d2i():Void op(OpD2i, 1, [TDouble], [TInt]);
	public function d2l():Void op(OpD2l, 1, [TDouble], [TLong]);
	public function f2d():Void op(OpF2d, 1, [TFloat], [TDouble]);
	public function f2i():Void op(OpF2i, 1, [TFloat], [TInt]);
	public function f2l():Void op(OpF2l, 1, [TFloat], [TLong]);
	public function i2b(jsig:JSignature):Void op(OpI2b, 1, [TInt], [jsig]);
	public function i2c():Void op(OpI2c, 1, [TInt], [TChar]);
	public function i2d():Void op(OpI2d, 1, [TInt], [TDouble]);
	public function i2f():Void op(OpI2f, 1, [TInt], [TFloat]);
	public function i2l():Void op(OpI2l, 1, [TInt], [TLong]);
	public function i2s():Void op(OpI2s, 1, [TInt], [TShort]);
	public function l2d():Void op(OpL2d, 1, [TLong], [TDouble]);
	public function l2f():Void op(OpL2f, 1, [TLong], [TFloat]);
	public function l2i():Void op(OpL2i, 1, [TLong], [TInt]);


	public function newarray(ta:JSignature, t:Int):Void op(OpNewarray(t), 2, [TInt], [ta]);
	public function anewarray(ta:JSignature, offset:Int):Void op(OpAnewarray(offset), 3, [TInt], [ta]);
	public function arraylength(ta:JSignature):Void op(OpArraylength, 1, [ta], [TInt]);
	public function aastore(ta:JSignature, te:JSignature):Void op(OpAastore, 1, [te, TInt, ta], []);
	public function aaload(ta:JSignature, te:JSignature):Void op(OpAaload, 1, [TInt, ta], [te]);
	public function castore(ta:JSignature):Void op(OpCastore, 1, [TChar, TInt, ta], []);
	public function caload(ta:JSignature):Void op(OpCaload, 1, [TInt, ta], [TChar]);
	public function fastore(ta:JSignature):Void op(OpFastore, 1, [TFloat, TInt, ta], []);
	public function faload(ta:JSignature):Void op(OpFaload, 1, [TInt, ta], [TFloat]);
	public function lastore(ta:JSignature):Void op(OpLastore, 1, [TLong, TInt, ta], []);
	public function laload(ta:JSignature):Void op(OpLaload, 1, [TInt, ta], [TLong]);
	public function sastore(ta:JSignature):Void op(OpSastore, 1, [TShort, TInt, ta], []);
	public function saload(ta:JSignature):Void op(OpSaload, 1, [TInt, ta], [TShort]);
	public function iastore(ta:JSignature):Void op(OpIastore, 1, [TInt, TInt, ta], []);
	public function iaload(ta:JSignature):Void op(OpIaload, 1, [TInt, ta], [TInt]);
	public function dastore(ta:JSignature):Void op(OpDastore, 1, [TDouble, TInt, ta], []);
	public function daload(ta:JSignature):Void op(OpDaload, 1, [TInt, ta], [TDouble]);
	public function bastore(jsig:JSignature, ta:JSignature):Void op(OpBastore, 1, [jsig, TInt, ta], []);
	public function baload(jsig:JSignature, ta:JSignature):Void op(OpBaload, 1, [TInt, ta], [jsig]);


	public function getstatic(offset:Int, t:JSignature):Void op(OpGetstatic(offset), 3, [], [t]);
	public function putstatic(offset:Int, t:JSignature):Void op(OpPutstatic(offset), 3, [t], []);
	public function getfield(offset:Int, tobj:JSignature, t:JSignature):Void op(OpGetfield(offset), 3, [tobj], [t]);
	public function putfield(offset:Int, tobj:JSignature, t:JSignature):Void op(OpPutfield(offset), 3, [t, tobj], []);


	public function invokestatic(offset:Int, tl:Array<JSignature>, tr:Array<JSignature>):Void {
		op(OpInvokestatic(offset), 3, rev(tl), tr);
	}

	public function invokevirtual(offset:Int, t1:JSignature, tl:Array<JSignature>, tr:Array<JSignature>):Void {
		op(OpInvokevirtual(offset), 3, rev([t1].concat(tl)), tr);
	}

	// the count is the argument slots plus the receiver.
	public function invokeinterface(offset:Int, t1:JSignature, tl:Array<JSignature>, tr:Array<JSignature>):Void {
		var count = 1;
		for (jsig in tl) count += JvmSignature.signatureSize(jsig);
		op(OpInvokeinterface(offset, count), 5, rev([t1].concat(tl)), tr);
	}

	public function invokespecial(offset:Int, t1:JSignature, tl:Array<JSignature>, tr:Array<JSignature>):Void {
		op(OpInvokespecial(offset), 3, rev([t1].concat(tl)), tr);
	}

	public function invokedynamic(offset:Int, tl:Array<JSignature>, tr:Array<JSignature>):Void {
		op(OpInvokedynamic(offset), 5, rev(tl), tr);
	}

	static inline function rev(l:Array<JSignature>):Array<JSignature> {
		var c = l.copy();
		c.reverse();
		return c;
	}

	// the uninitialized entry remembers where the new happened.
	public function new_(offset:Int):Void op(OpNew(offset), 3, [], [TUninitialized(fp)]);


	public function returnVoid():Void op(OpReturn, 1, [], []);

	public function returnValue(t:JSignature):Void {
		var o = switch (t) {
			case TInt | TBool | TByte | TChar | TShort: OpIreturn;
			case TLong: OpLreturn;
			case TFloat: OpFreturn;
			case TDouble: OpDreturn;
			case _: OpAreturn;
		};
		op(o, 1, [t], []);
	}

	public function athrow():Void op(OpAthrow, 1, [stack.top()], []);


	public function if_(cmp:JCmp, r:Ref<Int>):Void op(OpIf(cmp, r), 3, [TBool], []);
	public function ifIcmp(cmp:JCmp, r:Ref<Int>):Void op(OpIf_icmp(cmp, r), 3, [TInt, TInt], []);
	public function ifAcmpEq(t1:JSignature, t2:JSignature, r:Ref<Int>):Void op(OpIf_acmpeq(r), 3, [t1, t2], []);
	public function ifAcmpNe(t1:JSignature, t2:JSignature, r:Ref<Int>):Void op(OpIf_acmpne(r), 3, [t1, t2], []);
	public function ifNull(t:JSignature, r:Ref<Int>):Void op(OpIfnull(r), 3, [t], []);
	public function ifNonnull(t:JSignature, r:Ref<Int>):Void op(OpIfnonnull(r), 3, [t], []);
	public function goto(r:Ref<Int>):Void op(OpGoto(r), 3, [], []);

	// the table is padded so its data starts on a four byte boundary.
	public function lookupswitch(offsetDef:Ref<Int>, offsets:Array<{v:Int, offset:Ref<Int>}>):Void {
		var pad = (fp + 1) % 4;
		pad = pad == 0 ? pad : 4 - pad;
		op(OpLookupswitch(pad, offsetDef, offsets), 9 + pad + offsets.length * 8, [TInt], []);
	}

	public function tableswitch(offsetDef:Ref<Int>, low:Int, high:Int, offsets:Array<Ref<Int>>):Void {
		var pad = (fp + 1) % 4;
		pad = pad == 0 ? pad : 4 - pad;
		op(OpTableswitch(pad, offsetDef, low, high, offsets), 13 + pad + offsets.length * 4, [TInt], []);
	}


	public function dcmpg():Void op(OpDcmpg, 1, [TDouble, TDouble], [TInt]);
	public function dcmpl():Void op(OpDcmpl, 1, [TDouble, TDouble], [TInt]);
	public function fcmpg():Void op(OpFcmpg, 1, [TFloat, TFloat], [TInt]);
	public function fcmpl():Void op(OpFcmpl, 1, [TFloat, TFloat], [TInt]);
	public function lcmpl():Void op(OpLcmp, 1, [TLong, TLong], [TInt]);


	public function iadd():Void op(OpIadd, 1, [TInt, TInt], [TInt]);
	public function isub():Void op(OpIsub, 1, [TInt, TInt], [TInt]);
	public function imul():Void op(OpImul, 1, [TInt, TInt], [TInt]);
	public function iand():Void op(OpIand, 1, [TInt, TInt], [TInt]);
	public function ior():Void op(OpIor, 1, [TInt, TInt], [TInt]);
	public function ixor():Void op(OpIxor, 1, [TInt, TInt], [TInt]);
	public function ishl():Void op(OpIshl, 1, [TInt, TInt], [TInt]);
	public function ishr():Void op(OpIshr, 1, [TInt, TInt], [TInt]);
	public function iushr():Void op(OpIushr, 1, [TInt, TInt], [TInt]);
	public function irem():Void op(OpIrem, 1, [TInt, TInt], [TInt]);
	public function ineg():Void op(OpIneg, 1, [TInt], [TInt]);

	public function ladd():Void op(OpLadd, 1, [TLong, TLong], [TLong]);
	public function lsub():Void op(OpLsub, 1, [TLong, TLong], [TLong]);
	public function lmul():Void op(OpLmul, 1, [TLong, TLong], [TLong]);
	public function ldivOp():Void op(OpLdiv, 1, [TLong, TLong], [TLong]);
	public function landOp():Void op(OpLand, 1, [TLong, TLong], [TLong]);
	public function lorOp():Void op(OpLor, 1, [TLong, TLong], [TLong]);
	public function lxorOp():Void op(OpLxor, 1, [TLong, TLong], [TLong]);
	public function lshl():Void op(OpLshl, 1, [TInt, TLong], [TLong]);
	public function lshr():Void op(OpLshr, 1, [TInt, TLong], [TLong]);
	public function lushr():Void op(OpLushr, 1, [TInt, TLong], [TLong]);
	public function lrem():Void op(OpLrem, 1, [TLong, TLong], [TLong]);
	public function lneg():Void op(OpLneg, 1, [TLong], [TLong]);

	public function fadd():Void op(OpFadd, 1, [TFloat, TFloat], [TFloat]);
	public function fsub():Void op(OpFsub, 1, [TFloat, TFloat], [TFloat]);
	public function fmul():Void op(OpFmul, 1, [TFloat, TFloat], [TFloat]);
	public function fdiv():Void op(OpFdiv, 1, [TFloat, TFloat], [TFloat]);
	public function frem():Void op(OpFrem, 1, [TFloat, TFloat], [TFloat]);
	public function fneg():Void op(OpFneg, 1, [TFloat], [TFloat]);

	public function dadd():Void op(OpDadd, 1, [TDouble, TDouble], [TDouble]);
	public function dsub():Void op(OpDsub, 1, [TDouble, TDouble], [TDouble]);
	public function dmul():Void op(OpDmul, 1, [TDouble, TDouble], [TDouble]);
	public function ddiv():Void op(OpDdiv, 1, [TDouble, TDouble], [TDouble]);
	public function drem():Void op(OpDrem, 1, [TDouble, TDouble], [TDouble]);
	public function dneg():Void op(OpDneg, 1, [TDouble], [TDouble]);


	public function popOp():Void {
		var top = stack.top();
		op(JvmSignature.signatureSize(top) == 1 ? OpPop : OpPop2, 1, [top], []);
	}

	public function dup():Void {
		switch (stack.top()) {
			case TLong | TDouble: op(OpDup2, 1, [], [stack.top()]);
			case _: op(OpDup, 1, [], [stack.top()]);
		}
	}

	public function dupX1():Void {
		var tl = stack.getStackItems(2);
		var tl2 = [tl[0]].concat(revOf(tl));
		switch (tl[0]) {
			case TLong | TDouble: op(OpDup2_x1, 1, tl, tl2);
			case _: op(OpDup_x1, 1, tl, tl2);
		}
	}

	public function dupX2():Void {
		var tl = stack.getStackItems(3);
		var sizes = [for (t in tl) JvmSignature.signatureSize(t)];
		if (sizes[0] == 2 && sizes[1] == 2) op(OpDup2_x2, 1, [tl[0], tl[1]], [tl[0], tl[1], tl[0]]);
		else if (sizes[0] == 1 && sizes[1] == 2) op(OpDup_x2, 1, [tl[0], tl[1]], [tl[0], tl[1], tl[0]]);
		else if (sizes[0] == 1 && sizes[1] == 1 && sizes[2] == 1) op(OpDup_x2, 1, tl, [tl[0], tl[1], tl[2], tl[0]]);
		else if (sizes[0] == 2 && sizes[1] == 1 && sizes[2] == 1) op(OpDup2_x2, 1, tl, [tl[0], tl[1], tl[2], tl[0]]);
		else JvmGlobals.jerror("???");
	}

	public function swap():Void {
		var tl = stack.getStackItems(2);
		op(OpSwap, 1, tl, revOf(tl));
	}

	static inline function revOf(l:Array<JSignature>):Array<JSignature> {
		var c = l.copy();
		c.reverse();
		return c;
	}

	public function checkcastSig(jsig:JSignature):Void {
		var offset = pool.addType(JvmSignature.generateSignature(false, jsig));
		op(OpCheckcast(offset), 3, [stack.top()], [jsig]);
	}

	public function checkcast(path:JPath):Void {
		var offset = pool.addPath(path);
		var jsig = if (path.pack.length == 0 && path.name == "Int") TInt
			else if (path.pack.length == 1 && (path.pack[0] == "haxe" || path.pack[0] == "java") && path.name == "Int64") TLong
			else TObject(path, []);
		op(OpCheckcast(offset), 3, [stack.top()], [jsig]);
	}

	public function instanceof(path:JPath):Void {
		var offset = pool.addPath(path);
		op(OpInstanceof(offset), 3, [stack.top()], [TInt]);
	}


	public function monitorenter():Void op(OpMonitorenter, 1, [stack.top()], []);
	public function monitorexit():Void op(OpMonitorexit, 1, [stack.top()], []);


	public function aconstNull(t:JSignature):Void op(OpAconst_null, 1, [], [t]);

	public function ldc(offset:Int, vt:JSignature):Void {
		if (offset < 0xFF) op(OpLdc(offset), 2, [], [vt]);
		else op(OpLdc_w(offset), 3, [], [vt]);
	}

	public function bconst(b:Bool):Void op(b ? OpIconst_1 : OpIconst_0, 1, [], [TBool]);

	public function iconst(i:Int):Void {
		var instr:JOpCode;
		var count:Int;
		switch (i) {
			case -1: instr = OpIconst_m1; count = 1;
			case 0: instr = OpIconst_0; count = 1;
			case 1: instr = OpIconst_1; count = 1;
			case 2: instr = OpIconst_2; count = 1;
			case 3: instr = OpIconst_3; count = 1;
			case 4: instr = OpIconst_4; count = 1;
			case 5: instr = OpIconst_5; count = 1;
			case i:
				switch (JvmGlobals.getNumericRange(i)) {
					case Int8Range: instr = OpBipush(i); count = 2;
					case Int16Range: instr = OpSipush(i); count = 3;
					case Int32Range:
						var offset = pool.add(ConstInt(i));
						if (offset < 0xFF) { instr = OpLdc(offset); count = 2; }
						else { instr = OpLdc_w(offset); count = 3; }
				}
		}
		op(instr, count, [], [TInt]);
	}

	public function dconst(f:Float):Void {
		var instr:JOpCode;
		var count:Int;
		if (f == 0.0) { instr = OpDconst_0; count = 1; }
		else if (f == 1.0) { instr = OpDconst_1; count = 1; }
		else { instr = OpLdc2_w(pool.add(ConstDouble(f))); count = 3; }
		op(instr, count, [], [TDouble]);
	}

	public function lconst(d:haxe.Int64):Void {
		var instr:JOpCode;
		var count:Int;
		if (d == haxe.Int64.ofInt(0)) { instr = OpLconst_0; count = 1; }
		else if (d == haxe.Int64.ofInt(1)) { instr = OpLconst_1; count = 1; }
		else { instr = OpLdc2_w(pool.add(ConstLong(d))); count = 3; }
		op(instr, count, [], [TLong]);
	}

	public function fconst(f:Float):Void {
		var instr:JOpCode;
		var count:Int;
		if (f == 0.0) { instr = OpFconst_0; count = 1; }
		else if (f == 1.0) { instr = OpFconst_1; count = 1; }
		else if (f == 2.0) { instr = OpFconst_2; count = 1; }
		else { instr = OpLdc_w(pool.add(ConstFloat(f))); count = 3; }
		op(instr, count, [], [TFloat]);
	}

	public function sconst(t:JSignature, offset:Int):Void ldc(offset, t);

	public function getPool():JvmConstantPool return pool;
	public function getFp():Int return fp;
	public function getOps():Array<JOpCode> return ops;
	public function getStack():JvmStack return stack;
	public function getMaxStackSize():Int return stack.getMaxStackSize();
	public function getLines():Array<{pc:Int, line:Int}> return lines;
	public function setLine(line:Int):Void currentLine = line;

	public function exportCode():Bytes {
		var ch = new BytesOutput();
		ch.bigEndian = true;
		for (o in ops) JvmWriter.writeOpcode(ch, o);
		return ch.getBytes();
	}
}
