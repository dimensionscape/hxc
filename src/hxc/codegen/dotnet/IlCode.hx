package hxc.codegen.dotnet;

import haxe.Int64;
import haxe.io.Bytes;

// The opcodes the generator emits (ECMA-335 III); a two-byte opcode is 0xFE00 | its second byte.
class IlOps {
	public static inline var NOP = 0x00;
	public static inline var LDARG_0 = 0x02;
	public static inline var LDLOC_0 = 0x06;
	public static inline var STLOC_0 = 0x0A;
	public static inline var LDARG_S = 0x0E;
	public static inline var LDARGA_S = 0x0F;
	public static inline var STARG_S = 0x10;
	public static inline var LDLOC_S = 0x11;
	public static inline var LDLOCA_S = 0x12;
	public static inline var STLOC_S = 0x13;
	public static inline var LDNULL = 0x14;
	public static inline var LDC_I4_M1 = 0x15;
	public static inline var LDC_I4_0 = 0x16;
	public static inline var LDC_I4_S = 0x1F;
	public static inline var LDC_I4 = 0x20;
	public static inline var LDC_I8 = 0x21;
	public static inline var LDC_R4 = 0x22;
	public static inline var LDC_R8 = 0x23;
	public static inline var DUP = 0x25;
	public static inline var POP = 0x26;
	public static inline var CALL = 0x28;
	public static inline var RET = 0x2A;
	public static inline var BR_S = 0x2B;
	public static inline var BR = 0x38;
	public static inline var BRFALSE = 0x39;
	public static inline var BRTRUE = 0x3A;
	public static inline var BEQ = 0x3B;
	public static inline var BGE = 0x3C;
	public static inline var BGT = 0x3D;
	public static inline var BLE = 0x3E;
	public static inline var BLT = 0x3F;
	public static inline var BNE_UN = 0x40;
	public static inline var BGE_UN = 0x41;
	public static inline var BGT_UN = 0x42;
	public static inline var BLE_UN = 0x43;
	public static inline var BLT_UN = 0x44;
	public static inline var LDIND_REF = 0x50;
	public static inline var STIND_REF = 0x51;
	public static inline var ADD = 0x58;
	public static inline var SUB = 0x59;
	public static inline var MUL = 0x5A;
	public static inline var DIV = 0x5B;
	public static inline var DIV_UN = 0x5C;
	public static inline var REM = 0x5D;
	public static inline var REM_UN = 0x5E;
	public static inline var AND = 0x5F;
	public static inline var OR = 0x60;
	public static inline var XOR = 0x61;
	public static inline var SHL = 0x62;
	public static inline var SHR = 0x63;
	public static inline var SHR_UN = 0x64;
	public static inline var NEG = 0x65;
	public static inline var NOT = 0x66;
	public static inline var CONV_I1 = 0x67;
	public static inline var CONV_I2 = 0x68;
	public static inline var CONV_I4 = 0x69;
	public static inline var CONV_I8 = 0x6A;
	public static inline var CONV_R4 = 0x6B;
	public static inline var CONV_R8 = 0x6C;
	public static inline var CONV_U4 = 0x6D;
	public static inline var CONV_U8 = 0x6E;
	public static inline var CALLVIRT = 0x6F;
	public static inline var LDOBJ = 0x71;
	public static inline var LDSTR = 0x72;
	public static inline var NEWOBJ = 0x73;
	public static inline var CASTCLASS = 0x74;
	public static inline var ISINST = 0x75;
	public static inline var THROW = 0x7A;
	public static inline var LDFLD = 0x7B;
	public static inline var LDFLDA = 0x7C;
	public static inline var STFLD = 0x7D;
	public static inline var LDSFLD = 0x7E;
	public static inline var LDSFLDA = 0x7F;
	public static inline var STSFLD = 0x80;
	public static inline var STOBJ = 0x81;
	public static inline var CONV_R_UN = 0x76;
	public static inline var BOX = 0x8C;
	public static inline var NEWARR = 0x8D;
	public static inline var LDLEN = 0x8E;
	public static inline var LDELEMA = 0x8F;
	public static inline var LDELEM = 0xA3;
	public static inline var STELEM = 0xA4;
	public static inline var UNBOX_ANY = 0xA5;
	public static inline var CONV_U2 = 0xD1;
	public static inline var CONV_U1 = 0xD2;
	public static inline var LDTOKEN = 0xD0;
	public static inline var ENDFINALLY = 0xDC;
	public static inline var LEAVE = 0xDD;
	public static inline var LEAVE_S = 0xDE;
	public static inline var CEQ = 0xFE01;
	public static inline var CGT = 0xFE02;
	public static inline var CGT_UN = 0xFE03;
	public static inline var CLT = 0xFE04;
	public static inline var CLT_UN = 0xFE05;
	public static inline var LDFTN = 0xFE06;
	public static inline var LDVIRTFTN = 0xFE07;
	public static inline var LDARG = 0xFE09;
	public static inline var LDARGA = 0xFE0A;
	public static inline var STARG = 0xFE0B;
	public static inline var LDLOC = 0xFE0C;
	public static inline var LDLOCA = 0xFE0D;
	public static inline var STLOC = 0xFE0E;
	public static inline var VOLATILE = 0xFE13;
	public static inline var INITOBJ = 0xFE15;
	public static inline var RETHROW = 0xFE1A;
}

typedef Label = Int;

// Where a statement's IL starts, and its position in the source (null: a hidden point).
typedef SeqPoint = {offset:Int, pos:Null<hxc.ast.Position>};

// A block's IL range, its end exclusive, the named locals declared in it, in order, and the blocks in it.
typedef LocalScope = {start:Int, end:Int, vars:Array<{index:Int, name:String}>, children:Array<LocalScope>};

// An open protected region: where the block and the current handler start, the handler's kind (0 a
// catch clause, 2 a finally) and caught class, and the clauses of the handlers already ended.
private typedef TryBlock = {start:Int, end:Int, handler:Int, flags:Int, classToken:Int, clauses:Array<Array<Int>>};

// One method's IL: the instruction bytes, the evaluation stack depth after each instruction and its
// maximum, labels with the depth each is reached at, local types and exception clauses. Instructions
// and branches emitted while nothing reaches the code, such as the rest of an expression after a
// `throw` in one of its operands, are dropped, as C# leaves out dead code.

class IlCode {
	// Where a branch's operand is, the end of its instruction, and its target.
	final fixups:Array<{at:Int, end:Int, label:Label}> = [];
	// A label's offset (-1 until marked) and the depth it is reached at (-1 until known).
	final labelPos:Array<Int> = [];
	final labelDepth:Array<Int> = [];
	final tries:Array<TryBlock> = [];
	final clauses:Array<Array<Int>> = [];
	public final what:String;
	var code = new IlBytes();

	// The instructions since anything last recorded an offset, as each one's start and opcode: nothing can branch
	// between them or see where they are, so a branch can still rewrite them (fuse).
	final tailStarts:Array<Int> = [];
	final tailOps:Array<Int> = [];
	// Where the last `compare` is, and whether its operands are floats.
	var compareAt = -1;
	var compareFloat = false;
	// The type of the last castclass.
	var lastCast = 0;
	// Whether finish has run.
	var finished = false;

	public final locals:Array<hxc.codegen.dotnet.IlData.IlSigNorm> = [];

	// -1 after an unconditional transfer, until the next mark.
	public var depth(default, null):Int = 0;
	public var maxStack(default, null):Int = 0;

	// The sequence points in IL order, when the PDB wants them (-debug); null otherwise.
	public var points:Null<Array<SeqPoint>> = null;
	// How many times `points` has changed, so a caller can tell whether lowering a part recorded any.
	public var pointEdits(default, null):Int = 0;

	// The outermost local scopes, when the PDB wants them (-debug); null otherwise.
	public var scopes:Null<Array<LocalScope>> = null;
	// The scopes open, innermost last, and whether each was opened by nameLocal rather than a block.
	final openScopes:Array<{scope:LocalScope, implicit:Bool}> = [];

	// The IL's size so far.
	public var length(get, never):Int;

	inline function get_length():Int return code.length;

	// `what` names the method in internal errors.
	public function new(what:String) {
		this.what = what;
	}

	public function newLabel():Label {
		labelPos.push(-1);
		labelDepth.push(-1);
		return labelPos.length - 1;
	}

	public inline function reachable():Bool return depth >= 0;

	// A sequence point at the current offset, where reachable code starts on an empty stack, or with
	// `onStack` anywhere reachable (a catch's start, with the exception on the stack). It replaces one
	// already there, whose statement emitted no IL, and adds nothing after one at the same position.
	public function point(pos:Null<hxc.ast.Position>, onStack = false):Void {
		settle();
		if (points == null || depth < 0 || depth != 0 && !onStack) return;
		var last = points.length - 1;
		if (last >= 0 && points[last].offset == code.length) {
			points.pop();
			pointEdits++;
			last--;
		}
		if (last >= 0 && samePos(points[last].pos, pos)) return;
		points.push({offset: code.length, pos: pos});
		pointEdits++;
	}

	// A block's scope starts at the current offset.
	public function openScope():Void {
		settle();
		if (scopes == null) return;
		pushScope(false);
	}

	function pushScope(implicit:Bool):Void {
		var s:LocalScope = {start: code.length, end: -1, vars: [], children: []};
		(openScopes.length == 0 ? scopes : openScopes[openScopes.length - 1].scope.children).push(s);
		openScopes.push({scope: s, implicit: implicit});
	}

	// The innermost block's scope ends at the current offset, with the scopes nameLocal opened in it. After
	// a statement failed to lower, the scopes it opened stay open, and the method is not written.
	public function closeScope():Void {
		settle();
		if (scopes == null) return;
		while (openScopes.length > 0) {
			var o = openScopes.pop();
			o.scope.end = code.length;
			if (!o.implicit) break;
		}
	}

	// Local `index` holds the variable `name` from here to the end of the innermost block. A name the
	// block has named already (two inlined functions' variables) starts a scope of its own, to the block's
	// end, as the PDB names a variable once per scope.
	public function nameLocal(index:Int, name:String):Void {
		settle();
		if (scopes == null || openScopes.length == 0) return;
		for (v in openScopes[openScopes.length - 1].scope.vars) if (v.name == name) {
			pushScope(true);
			break;
		}
		openScopes[openScopes.length - 1].scope.vars.push({index: index, name: name});
	}

	static function samePos(a:Null<hxc.ast.Position>, b:Null<hxc.ast.Position>):Bool {
		return a == null ? b == null : b != null && a.file == b.file && a.min == b.min && a.max == b.max;
	}

	function fail(msg:String):Dynamic {
		throw "internal error: " + msg + " in " + what;
	}

	public function mark(l:Label):Void {
		if (labelPos[l] >= 0) fail("label marked twice");
		settle();
		labelPos[l] = code.length;
		var d = labelDepth[l];
		if (depth >= 0) {
			if (d >= 0 && d != depth) fail("stack depth " + depth + " meets " + d + " at a label");
			labelDepth[l] = depth;
		} else if (d >= 0) {
			// Reached only by forward branches, at their depth.
			depth = d;
		}
		// Else nothing reaches it yet: a backward branch to it could only come from the dead code after
		// it, so that stays dead.
	}

	// Whether a branch already goes to the label.
	public inline function targeted(l:Label):Bool return labelDepth[l] >= 0;

	// A branch still to come goes back to the label, at the current depth, so what follows it is reachable.
	public function willReach(l:Label):Void {
		labelDepth[l] = depth;
	}

	// Marks the label unless nothing reaches it, so code after a transfer stays unreachable.
	public function markIfUsed(l:Label):Void {
		if (depth >= 0 || labelDepth[l] >= 0) mark(l);
	}

	// Recovery after a user-code statement failed to lower: its IL is thrown away, so the stack is
	// put back to where the statement started.
	public function resetDepth(d:Int):Void {
		settle();
		depth = d;
	}

	function settle():Void {
		tailStarts.resize(0);
		tailOps.resize(0);
	}

	function opcode(code:Int):Void {
		tailStarts.push(this.code.length);
		tailOps.push(code);
		if (code > 0xFF) {
			this.code.u8(0xFE);
			this.code.u8(code & 0xFF);
		} else {
			this.code.u8(code);
		}
	}

	function stack(pops:Int, pushes:Int):Void {
		if (depth < pops) fail("stack underflow");
		depth += pushes - pops;
		if (depth > maxStack) maxStack = depth;
	}

	// After these, nothing falls through.
	function transfers(code:Int):Bool {
		return code == IlOps.BR || code == IlOps.LEAVE || code == IlOps.RET || code == IlOps.THROW || code == IlOps.RETHROW
			|| code == IlOps.ENDFINALLY;
	}

	public function op(code:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		if (transfers(code)) depth = -1;
	}

	public function opI32(code:Int, v:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.u32(v);
	}

	function opI8(code:Int, v:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.u8(v);
	}

	function opU16(code:Int, v:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.u16(v);
	}

	public function opI64(code:Int, v:Int64, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.i64(v);
	}

	public function opR8(code:Int, v:Float, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.f64(v);
	}

	public function opR4(code:Int, v:Float, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.f32(v);
	}

	// ldelem for an array of `elem`: the typed short form C# emits for a primitive (ILVerify rejects the
	// token form for Char and Boolean) or a reference, the token form otherwise; `token` is called only then.
	public function ldelem(elem:hxc.codegen.dotnet.IlData.IlSigNorm, token:() -> Int):Void {
		var short = switch (elem) {
			case LInt8: 0x90;
			case LBool | LUInt8: 0x91;
			case LInt16: 0x92;
			case LChar | LUInt16: 0x93;
			case LInt32: 0x94;
			case LUInt32: 0x95;
			case LInt64 | LUInt64: 0x96;
			case LIntPtr | LUIntPtr: 0x97;
			case LFloat32: 0x98;
			case LFloat64: 0x99;
			case LObject | LString | LClass(_, _) | LVector(_) | LArray(_, _): 0x9A;
			case _: -1;
		}
		if (short >= 0) op(short, 2, 1) else opToken(IlOps.LDELEM, token(), 2, 1);
	}

	// stelem for an array of `elem`, as ldelem.
	public function stelem(elem:hxc.codegen.dotnet.IlData.IlSigNorm, token:() -> Int):Void {
		var short = switch (elem) {
			case LIntPtr | LUIntPtr: 0x9B;
			case LBool | LInt8 | LUInt8: 0x9C;
			case LChar | LInt16 | LUInt16: 0x9D;
			case LInt32 | LUInt32: 0x9E;
			case LInt64 | LUInt64: 0x9F;
			case LFloat32: 0xA0;
			case LFloat64: 0xA1;
			case LObject | LString | LClass(_, _) | LVector(_) | LArray(_, _): 0xA2;
			case _: -1;
		}
		if (short >= 0) op(short, 3, 0) else opToken(IlOps.STELEM, token(), 3, 0);
	}

	// A read through the address on the stack, of a value of type `t`: the typed short form C# emits for a primitive,
	// or -1 for what has none.
	public static function ldindOf(t:hxc.codegen.dotnet.IlData.IlSigNorm):Int {
		return switch (t) {
			case LInt8: 0x46;
			case LBool | LUInt8: 0x47;
			case LInt16: 0x48;
			case LChar | LUInt16: 0x49;
			case LInt32: 0x4A;
			case LUInt32: 0x4B;
			case LInt64 | LUInt64: 0x4C;
			case LIntPtr | LUIntPtr: 0x4D;
			case LFloat32: 0x4E;
			case LFloat64: 0x4F;
			case _: -1;
		}
	}

	// A write through the address on the stack, as ldindOf.
	public static function stindOf(t:hxc.codegen.dotnet.IlData.IlSigNorm):Int {
		return switch (t) {
			case LBool | LInt8 | LUInt8: 0x52;
			case LChar | LInt16 | LUInt16: 0x53;
			case LInt32 | LUInt32: 0x54;
			case LInt64 | LUInt64: 0x55;
			case LFloat32: 0x56;
			case LFloat64: 0x57;
			case LIntPtr | LUIntPtr: 0xDF;
			case _: -1;
		}
	}

	public function opToken(code:Int, token:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		// A cast of a value just cast to the same type: Roslyn drops the one a gencs `(T)(T)x` has too.
		if (code == IlOps.CASTCLASS) {
			if (tailOps.length > 0 && tailOps[tailOps.length - 1] == IlOps.CASTCLASS && token == lastCast) return;
			lastCast = token;
		}
		stack(pops, pushes);
		opcode(code);
		this.code.u32(token);
		if (transfers(code)) depth = -1;
	}

	// clt, cgt or their unordered forms on operands that are floats or not, which a branch on the result has to
	// know to invert them.
	public function compare(code:Int, isFloat:Bool):Void {
		if (depth < 0) return;
		compareAt = this.code.length;
		compareFloat = isFloat;
		op(code, 2, 1);
	}

	// brfalse or brtrue on the comparison just emitted, as the one instruction Roslyn emits for it: the opcode to
	// emit, with what it no longer needs taken off the code. On NaN `ceq` is false and `bne.un` jumps, so that needs
	// no type; a branch on the opposite of `clt` or `cgt` has to swap its unordered form for a float, and a
	// comparison made with `op` has no known type, so only `ceq` and the null tests fuse with one.
	function fuse(code:Int):Int {
		var sense = code == IlOps.BRTRUE;
		while (tailOps.length >= 2) {
			var last = tailOps[tailOps.length - 1], prev = tailOps[tailOps.length - 2];
			if (last == IlOps.CEQ && (prev == IlOps.LDC_I4_0 || prev == IlOps.LDNULL)) sense = !sense
			else if (last != IlOps.CGT_UN || prev != IlOps.LDNULL) break;
			dropTail(2);
		}
		var known = tailOps.length > 0 && tailStarts[tailStarts.length - 1] == compareAt;
		var fused = tailOps.length == 0 ? -1 : switch (tailOps[tailOps.length - 1]) {
			case IlOps.CEQ: sense ? IlOps.BEQ : IlOps.BNE_UN;
			case IlOps.CLT if (known): sense ? IlOps.BLT : compareFloat ? IlOps.BGE_UN : IlOps.BGE;
			case IlOps.CLT_UN if (known): sense ? IlOps.BLT_UN : compareFloat ? IlOps.BGE : IlOps.BGE_UN;
			case IlOps.CGT if (known): sense ? IlOps.BGT : compareFloat ? IlOps.BLE_UN : IlOps.BLE;
			case IlOps.CGT_UN if (known): sense ? IlOps.BGT_UN : compareFloat ? IlOps.BLE : IlOps.BLE_UN;
			case _: -1;
		}
		if (fused < 0) return sense ? IlOps.BRTRUE : IlOps.BRFALSE;
		dropTail(1);
		// The comparison's operands are on the stack again, for the branch to pop.
		depth++;
		return fused;
	}

	// Takes the last `n` instructions off the code.
	function dropTail(n:Int):Void {
		var keep = tailOps.length - n;
		this.code.truncate(tailStarts[keep]);
		tailStarts.resize(keep);
		tailOps.resize(keep);
	}

	// The long form until finish. A conditional branch pops its operands; `leave` empties the stack.
	public function branch(code:Int, l:Label):Void {
		if (depth < 0) return;
		if (code == IlOps.BRFALSE || code == IlOps.BRTRUE) code = fuse(code);
		var pops = switch (code) {
			case IlOps.BR | IlOps.LEAVE: 0;
			case IlOps.BRFALSE | IlOps.BRTRUE: 1;
			case _: 2;
		}
		stack(pops, 0);
		if (code == IlOps.LEAVE) depth = 0;
		var d = labelDepth[l];
		// The code after a label marked while nothing reached it was dropped, so its offset is wrong.
		if (labelPos[l] >= 0 && d < 0) fail("a branch back to an unreached label");
		if (d >= 0 && d != depth) fail("stack depth " + depth + " meets " + d + " at a branch");
		labelDepth[l] = depth;
		opcode(code);
		fixups.push({at: this.code.length, end: this.code.length + 4, label: l});
		this.code.u32(0);
		if (transfers(code)) depth = -1;
	}

	public function ldarg(i:Int):Void {
		if (i < 4) op(IlOps.LDARG_0 + i, 0, 1) else if (i < 256) opI8(IlOps.LDARG_S, i, 0, 1) else opU16(IlOps.LDARG, i, 0, 1);
	}

	public function ldarga(i:Int):Void {
		if (i < 256) opI8(IlOps.LDARGA_S, i, 0, 1) else opU16(IlOps.LDARGA, i, 0, 1);
	}

	public function starg(i:Int):Void {
		if (i < 256) opI8(IlOps.STARG_S, i, 1, 0) else opU16(IlOps.STARG, i, 1, 0);
	}

	public function ldloc(i:Int):Void {
		if (i < 4) op(IlOps.LDLOC_0 + i, 0, 1) else if (i < 256) opI8(IlOps.LDLOC_S, i, 0, 1) else opU16(IlOps.LDLOC, i, 0, 1);
	}

	public function stloc(i:Int):Void {
		if (i < 4) op(IlOps.STLOC_0 + i, 1, 0) else if (i < 256) opI8(IlOps.STLOC_S, i, 1, 0) else opU16(IlOps.STLOC, i, 1, 0);
	}

	public function ldloca(i:Int):Void {
		if (i < 256) opI8(IlOps.LDLOCA_S, i, 0, 1) else opU16(IlOps.LDLOCA, i, 0, 1);
	}

	public function ldcI4(v:Int):Void {
		if (v >= -1 && v <= 8) op(IlOps.LDC_I4_0 + v, 0, 1) else if (v >= -128 && v <= 127) opI8(IlOps.LDC_I4_S, v & 0xFF, 0, 1)
		else opI32(IlOps.LDC_I4, v, 0, 1);
	}

	public function addLocal(t:hxc.codegen.dotnet.IlData.IlSigNorm):Int {
		locals.push(t);
		return locals.length - 1;
	}

	// A try block starts on an empty stack and ends with a `leave` the caller emits.
	public function beginTry():Void {
		settle();
		if (depth != 0) fail("a try block entered with a non-empty stack");
		tries.push({start: code.length, end: -1, handler: -1, flags: 0, classToken: 0, clauses: []});
	}

	// Ends the try block or the previous handler and starts a handler, which has the exception on the
	// stack.
	public function beginCatch(classToken:Int):Void {
		settle();
		var t = tries[tries.length - 1];
		if (t == null) fail("a catch outside a try");
		closeHandler(t);
		if (t.end < 0) t.end = code.length;
		t.handler = code.length;
		t.flags = 0;
		t.classToken = classToken;
		if (depth >= 0) fail("a try block or handler that falls through");
		depth = 1;
		if (maxStack < 1) maxStack = 1;
	}

	// Ends the try block and starts its finally handler, which starts on an empty stack and ends with
	// `endfinally`. A try block with a finally handler has no other handler.
	public function beginFinally():Void {
		settle();
		var t = tries[tries.length - 1];
		if (t == null) fail("a finally outside a try");
		if (t.end >= 0) fail("a finally after another handler");
		t.end = code.length;
		t.handler = code.length;
		t.flags = 2;
		t.classToken = 0;
		if (depth >= 0) fail("a try block that falls through");
		depth = 0;
	}

	function closeHandler(t:TryBlock):Void {
		if (t.handler < 0) return;
		t.clauses.push([t.flags, t.start, t.end - t.start, t.handler, code.length - t.handler, t.classToken]);
		t.handler = -1;
	}

	// How many try blocks are open, for `abandonTries`.
	public var openTries(get, never):Int;

	inline function get_openTries():Int return tries.length;

	// Recovery after a user-code statement failed to lower inside try blocks it opened: they are closed
	// without clauses, as the method's IL is not written.
	public function abandonTries(open:Int):Void {
		while (tries.length > open) tries.pop();
	}

	// Inner clauses come first in the table, so a try's clauses are added when it ends.
	public function endTry():Void {
		settle();
		var t = tries.pop();
		if (t == null) fail("endTry outside a try");
		if (depth >= 0) fail("a handler that falls through");
		closeHandler(t);
		for (c in t.clauses) clauses.push(c);
	}

	// Writes the branches, each in the short form when its target is in reach, and moves every offset recorded to
	// where it ends up. Shrinking a branch only brings others' targets closer, so a pass that finds a branch in reach
	// stays right whatever the rest of it finds, and the passes end when one finds none. The IL has no other offsets:
	// no `switch` is emitted.
	public function finish():Void {
		if (finished) return;
		finished = true;
		var n = fixups.length;
		var short = [for (_ in 0...n) false];
		// The bytes the first i branches have lost.
		var lost = [for (_ in 0...n + 1) 0];
		// Where the instruction now at `at` ends up.
		function moved(at:Int):Int {
			var lo = 0, hi = n;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (fixups[mid].end <= at) lo = mid + 1 else hi = mid;
			}
			return at - lost[lo];
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (i in 0...n) lost[i + 1] = lost[i] + (short[i] ? 3 : 0);
			for (i in 0...n) if (!short[i]) {
				var f = fixups[i], target = labelPos[f.label];
				if (target < 0) fail("a branch to an unmarked label");
				// Shrinking this branch moves its own end back, and a target after it with it.
				var d = moved(target) - moved(f.end) + (target < f.end ? 3 : 0);
				if (d >= -128 && d <= 127) {
					short[i] = true;
					changed = true;
				}
			}
		}
		var il = code.getBytes(), out = new IlBytes(), from = 0;
		for (i in 0...n) {
			var f = fixups[i], op = il.get(f.at - 1), d = moved(labelPos[f.label]) - moved(f.end);
			out.bytes(il.sub(from, f.at - 1 - from));
			if (short[i]) {
				out.u8(op == IlOps.LEAVE ? IlOps.LEAVE_S : op - IlOps.BR + IlOps.BR_S);
				out.u8(d & 0xFF);
			} else {
				out.u8(op);
				out.u32(d);
			}
			from = f.end;
		}
		out.bytes(il.sub(from, il.length - from));
		code = out;
		if (points != null) for (p in points) p.offset = moved(p.offset);
		function moveScopes(list:Array<LocalScope>) {
			for (s in list) {
				s.start = moved(s.start);
				s.end = moved(s.end);
				moveScopes(s.children);
			}
		}
		if (scopes != null) moveScopes(scopes);
		for (c in clauses) {
			var tryEnd = moved(c[1] + c[2]), handlerEnd = moved(c[3] + c[4]);
			c[1] = moved(c[1]);
			c[2] = tryEnd - c[1];
			c[3] = moved(c[3]);
			c[4] = handlerEnd - c[3];
		}
	}

	// The method body: a tiny header when it can be, else a fat one with its exception clauses.
	public function body(localsToken:Int):Bytes {
		if (tries.length > 0) fail("an unclosed try block");
		finish();
		var b = new IlBytes();
		var il = code.getBytes();
		if (il.length < 64 && maxStack <= 8 && locals.length == 0 && clauses.length == 0) {
			b.u8((il.length << 2) | 0x2);
			b.bytes(il);
			return b.getBytes();
		}
		b.u16(clauses.length > 0 ? 0x301B : 0x3013);
		b.u16(maxStack);
		b.u32(il.length);
		b.u32(localsToken);
		b.bytes(il);
		if (clauses.length > 0) {
			b.align(4);
			var size = clauses.length * 24 + 4;
			b.u8(0x41);
			b.u8(size & 0xFF);
			b.u8((size >> 8) & 0xFF);
			b.u8((size >> 16) & 0xFF);
			for (c in clauses) for (v in c) b.u32(v);
		}
		return b.getBytes();
	}
}
