package hxc.codegen.hl;

import hxc.codegen.hl.HlCode;

// hlopt.ml lines 29-438: the per-opcode tables the optimiser uses (control, opcode_fx, opcode_eq, opcode_map).
// This file imports nothing outside hxc.codegen.hl.
//
// OCaml evaluates constructor arguments right to left, so `OSetField (read a, f, read b)` calls `read` on b
// first. The ports below keep that: where an arm builds its op with two `read` calls inside the constructor
// (OSetField, ODynSet, OSetEnumField and the two-register jumps) the second register is read first.
// `let a = read a and b = read b in ...` is sequential, a first.

// hlopt.ml: control
enum HlControl {
	CNo;
	CJCond(d:Int);
	CJAlways(d:Int);
	CTry(d:Int);
	CCatch;
	CSwitch(cases:Array<Int>);
	CRet;
	CThrow;
	CLabel;
}

class HlOpcodes {
	public static function control(op:HlOp):HlControl {
		return switch op {
			case OJTrue(_, d) | OJFalse(_, d) | OJNull(_, d) | OJNotNull(_, d) | OJSLt(_, _, d) | OJSGte(_, _, d) | OJSGt(_, _, d) | OJSLte(_, _, d) | OJULt(_, _, d) | OJUGte(_, _, d) | OJEq(_, _, d) | OJNotEq(_, _, d) | OJNotLt(_, _, d) | OJNotGte(_, _, d):
				CJCond(d);
			case OJAlways(d):
				CJAlways(d);
			case OLabel(_):
				CLabel;
			case ORet(_):
				CRet;
			case OThrow(_) | ORethrow(_):
				CThrow;
			case OSwitch(_, cases, _):
				CSwitch(cases);
			case OTrap(_, d):
				CTry(d);
			case OEndTrap(_):
				CCatch;
			default:
				CNo;
		}
	}

	// hlopt.ml: opcode_fx. `frw(r, true)` is a read of r, `frw(r, false)` a write.
	public static function opcodeFx(frw:(r:Int, read:Bool) -> Void, op:HlOp):Void {
		function read(r:Int)
			frw(r, true);
		function write(r:Int)
			frw(r, false);
		switch op {
			case OMov(d, a) | ONeg(d, a) | ONot(d, a):
				read(a);
				write(d);
			case OInt(d, _) | OFloat(d, _) | OBool(d, _) | OBytes(d, _) | OString(d, _) | ONull(d):
				write(d);
			case OAdd(d, a, b) | OSub(d, a, b) | OMul(d, a, b) | OSDiv(d, a, b) | OUDiv(d, a, b) | OSMod(d, a, b) | OUMod(d, a, b) | OShl(d, a, b) | OSShr(d, a, b) | OUShr(d, a, b) | OAnd(d, a, b) | OOr(d, a, b) | OXor(d, a, b):
				read(a);
				read(b);
				write(d);
			case OIncr(a) | ODecr(a):
				read(a);
				write(a);
			case OCall0(d, _):
				write(d);
			case OCall1(d, _, a):
				read(a);
				write(d);
			case OCall2(d, _, a, b):
				read(a);
				read(b);
				write(d);
			case OCall3(d, _, a, b, c):
				read(a);
				read(b);
				read(c);
				write(d);
			case OCall4(d, _, a, b, c, k):
				read(a);
				read(b);
				read(c);
				read(k);
				write(d);
			case OCallN(d, _, rl) | OCallMethod(d, _, rl) | OCallThis(d, _, rl):
				for (r in rl) read(r);
				write(d);
			case OCallClosure(d, f, rl):
				read(f);
				for (r in rl) read(r);
				write(d);
			case OStaticClosure(d, _):
				write(d);
			case OInstanceClosure(d, _, a) | OVirtualClosure(d, a, _):
				read(a);
				write(d);
			case OGetGlobal(d, _):
				write(d);
			case OSetGlobal(_, a):
				read(a);
			case OField(d, a, _) | ODynGet(d, a, _):
				read(a);
				write(d);
			case OSetField(a, _, b) | ODynSet(a, _, b):
				read(a);
				read(b);
			case OGetThis(d, _):
				write(d);
			case OSetThis(_, a):
				read(a);
			case OJTrue(r, _) | OJFalse(r, _) | OJNull(r, _) | OJNotNull(r, _):
				read(r);
			case OJSLt(a, b, _) | OJSGte(a, b, _) | OJSGt(a, b, _) | OJSLte(a, b, _) | OJULt(a, b, _) | OJUGte(a, b, _) | OJNotLt(a, b, _) | OJNotGte(a, b, _) | OJEq(a, b, _) | OJNotEq(a, b, _):
				read(a);
				read(b);
			case OJAlways(_) | OLabel(_):
				// nothing
			case OToDyn(d, a) | OToSFloat(d, a) | OToUFloat(d, a) | OToInt(d, a) | OSafeCast(d, a) | OUnsafeCast(d, a) | OToVirtual(d, a):
				read(a);
				write(d);
			case ORet(r) | OThrow(r) | ORethrow(r) | OSwitch(r, _, _) | ONullCheck(r):
				read(r);
			case OTrap(r, _):
				write(r);
			case OEndTrap(_):
				// nothing (OCaml has `(* ??? *)` here)
			case OGetUI8(d, a, b) | OGetUI16(d, a, b) | OGetMem(d, a, b) | OGetArray(d, a, b):
				read(a);
				read(b);
				write(d);
			case OSetUI8(a, b, c) | OSetUI16(a, b, c) | OSetMem(a, b, c) | OSetArray(a, b, c):
				read(a);
				read(b);
				read(c);
			case ONew(d):
				write(d);
			case OArraySize(d, a) | OGetType(d, a) | OGetTID(d, a) | OUnref(d, a) | OSetref(d, a) | OEnumIndex(d, a) | OEnumField(d, a, _, _):
				read(a);
				write(d);
			case ORef(d, a):
				read(a);
				write(a); // prevent issue with 'a' being reused later - this is not exact as it can be set everytime we pass it to a function
				write(d);
			case OType(d, _) | OEnumAlloc(d, _):
				write(d);
			case OMakeEnum(d, _, rl):
				for (r in rl) read(r);
				write(d);
			case OSetEnumField(a, _, b):
				read(a);
				read(b);
			case OAssert(_):
				// nothing
			case ORefData(r, d):
				read(d);
				write(r);
			case ORefOffset(r, r2, off):
				read(r2);
				read(off);
				write(r);
			case ONop(_):
				// nothing
		}
	}

	// hlopt.ml: opcode_eq. OType compares the register by value and the type by identity; the rest is
	// structural.
	public static function opcodeEq(a:HlOp, b:HlOp):Bool {
		return switch [a, b] {
			case [OType(r1, t1), OType(r2, t2)]:
				r1 == r2 && t1 == t2;
			case [OCallN(d1, f1, l1), OCallN(d2, f2, l2)]:
				d1 == d2 && f1 == f2 && sameArray(l1, l2);
			case [OCallMethod(d1, f1, l1), OCallMethod(d2, f2, l2)]:
				d1 == d2 && f1 == f2 && sameArray(l1, l2);
			case [OCallThis(d1, f1, l1), OCallThis(d2, f2, l2)]:
				d1 == d2 && f1 == f2 && sameArray(l1, l2);
			case [OCallClosure(d1, f1, l1), OCallClosure(d2, f2, l2)]:
				d1 == d2 && f1 == f2 && sameArray(l1, l2);
			case [OMakeEnum(d1, e1, l1), OMakeEnum(d2, e2, l2)]:
				d1 == d2 && e1 == e2 && sameArray(l1, l2);
			case [OSwitch(r1, c1, e1), OSwitch(r2, c2, e2)]:
				r1 == r2 && e1 == e2 && sameArray(c1, c2);
			default:
				Type.enumEq(a, b);
		}
	}

	static function sameArray(a:Array<Int>, b:Array<Int>):Bool {
		if (a.length != b.length)
			return false;
		for (i in 0...a.length)
			if (a[i] != b[i])
				return false;
		return true;
	}

	// hlopt.ml: opcode_map
	public static function opcodeMap(read:Int->Int, write:Int->Int, op:HlOp):HlOp {
		return switch op {
			case OMov(d, a):
				var ra = read(a);
				OMov(write(d), ra);
			case ONeg(d, a):
				var ra = read(a);
				ONeg(write(d), ra);
			case ONot(d, a):
				var ra = read(a);
				ONot(write(d), ra);
			case OInt(d, idx):
				OInt(write(d), idx);
			case OFloat(d, idx):
				OFloat(write(d), idx);
			case OBool(d, b):
				OBool(write(d), b);
			case OBytes(d, idx):
				OBytes(write(d), idx);
			case OString(d, idx):
				OString(write(d), idx);
			case ONull(d):
				ONull(write(d));
			case OAdd(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OAdd(write(d), ra, rb);
			case OSub(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OSub(write(d), ra, rb);
			case OMul(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OMul(write(d), ra, rb);
			case OSDiv(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OSDiv(write(d), ra, rb);
			case OUDiv(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OUDiv(write(d), ra, rb);
			case OSMod(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OSMod(write(d), ra, rb);
			case OUMod(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OUMod(write(d), ra, rb);
			case OShl(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OShl(write(d), ra, rb);
			case OSShr(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OSShr(write(d), ra, rb);
			case OUShr(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OUShr(write(d), ra, rb);
			case OAnd(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OAnd(write(d), ra, rb);
			case OOr(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OOr(write(d), ra, rb);
			case OXor(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OXor(write(d), ra, rb);
			case OIncr(a):
				OIncr(write(a));
			case ODecr(a):
				ODecr(write(a));
			case OCall0(d, f):
				OCall0(write(d), f);
			case OCall1(d, f, a):
				var ra = read(a);
				OCall1(write(d), f, ra);
			case OCall2(d, f, a, b):
				var ra = read(a);
				var rb = read(b);
				OCall2(write(d), f, ra, rb);
			case OCall3(d, f, a, b, c):
				var ra = read(a);
				var rb = read(b);
				var rc = read(c);
				OCall3(write(d), f, ra, rb, rc);
			case OCall4(w, f, a, b, c, d):
				var ra = read(a);
				var rb = read(b);
				var rc = read(c);
				var rd = read(d);
				OCall4(write(w), f, ra, rb, rc, rd);
			case OCallN(d, f, rl):
				var rl = [for (r in rl) read(r)];
				OCallN(write(d), f, rl);
			case OCallMethod(d, f, rl):
				var rl = [for (r in rl) read(r)];
				OCallMethod(write(d), f, rl);
			case OCallThis(d, f, rl):
				var rl = [for (r in rl) read(r)];
				OCallThis(write(d), f, rl);
			case OCallClosure(d, f, rl):
				var rf = read(f);
				var rl = [for (r in rl) read(r)];
				OCallClosure(write(d), rf, rl);
			case OStaticClosure(d, f):
				OStaticClosure(write(d), f);
			case OInstanceClosure(d, f, a):
				var ra = read(a);
				OInstanceClosure(write(d), f, ra);
			case OVirtualClosure(d, a, f):
				var ra = read(a);
				OVirtualClosure(write(d), ra, f);
			case OGetGlobal(d, g):
				OGetGlobal(write(d), g);
			case OSetGlobal(g, r):
				OSetGlobal(g, read(r));
			case OField(d, a, f):
				var ra = read(a);
				OField(write(d), ra, f);
			case ODynGet(d, a, f):
				var ra = read(a);
				ODynGet(write(d), ra, f);
			case OSetField(a, f, b):
				var rb = read(b); // right to left, as OCaml evaluates a constructor's arguments
				OSetField(read(a), f, rb);
			case ODynSet(a, f, b):
				var rb = read(b);
				ODynSet(read(a), f, rb);
			case OGetThis(d, f):
				OGetThis(write(d), f);
			case OSetThis(f, a):
				OSetThis(f, read(a));
			case OJTrue(r, d):
				OJTrue(read(r), d);
			case OJFalse(r, d):
				OJFalse(read(r), d);
			case OJNull(r, d):
				OJNull(read(r), d);
			case OJNotNull(r, d):
				OJNotNull(read(r), d);
			case OJSLt(a, b, d):
				var rb = read(b);
				OJSLt(read(a), rb, d);
			case OJSGte(a, b, d):
				var rb = read(b);
				OJSGte(read(a), rb, d);
			case OJSGt(a, b, d):
				var rb = read(b);
				OJSGt(read(a), rb, d);
			case OJSLte(a, b, d):
				var rb = read(b);
				OJSLte(read(a), rb, d);
			case OJULt(a, b, d):
				var rb = read(b);
				OJULt(read(a), rb, d);
			case OJUGte(a, b, d):
				var rb = read(b);
				OJUGte(read(a), rb, d);
			case OJNotLt(a, b, d):
				var rb = read(b);
				OJNotLt(read(a), rb, d);
			case OJNotGte(a, b, d):
				var rb = read(b);
				OJNotGte(read(a), rb, d);
			case OJEq(a, b, d):
				var rb = read(b);
				OJEq(read(a), rb, d);
			case OJNotEq(a, b, d):
				var rb = read(b);
				OJNotEq(read(a), rb, d);
			case OJAlways(_) | OLabel(_):
				op;
			case OToDyn(d, a):
				var ra = read(a);
				OToDyn(write(d), ra);
			case OToSFloat(d, a):
				var ra = read(a);
				OToSFloat(write(d), ra);
			case OToUFloat(d, a):
				var ra = read(a);
				OToUFloat(write(d), ra);
			case OToInt(d, a):
				var ra = read(a);
				OToInt(write(d), ra);
			case OSafeCast(d, a):
				var ra = read(a);
				OSafeCast(write(d), ra);
			case OUnsafeCast(d, a):
				var ra = read(a);
				OUnsafeCast(write(d), ra);
			case OToVirtual(d, a):
				var ra = read(a);
				OToVirtual(write(d), ra);
			case ORet(r):
				ORet(read(r));
			case OThrow(r):
				OThrow(read(r));
			case ORethrow(r):
				ORethrow(read(r));
			case OSwitch(r, cases, def):
				OSwitch(read(r), cases, def);
			case ONullCheck(r):
				ONullCheck(read(r));
			case OTrap(r, d):
				OTrap(write(r), d);
			case OEndTrap(_):
				op; // ???
			case OGetUI8(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OGetUI8(write(d), ra, rb);
			case OGetUI16(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OGetUI16(write(d), ra, rb);
			case OGetMem(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OGetMem(write(d), ra, rb);
			case OGetArray(d, a, b):
				var ra = read(a);
				var rb = read(b);
				OGetArray(write(d), ra, rb);
			case OSetUI8(a, b, c):
				var ra = read(a);
				var rb = read(b);
				var rc = read(c);
				OSetUI8(ra, rb, rc);
			case OSetUI16(a, b, c):
				var ra = read(a);
				var rb = read(b);
				var rc = read(c);
				OSetUI16(ra, rb, rc);
			case OSetMem(a, b, c):
				var ra = read(a);
				var rb = read(b);
				var rc = read(c);
				OSetMem(ra, rb, rc);
			case OSetArray(a, b, c):
				var ra = read(a);
				var rb = read(b);
				var rc = read(c);
				OSetArray(ra, rb, rc);
			case ONew(d):
				ONew(write(d));
			case OArraySize(d, a):
				var ra = read(a);
				OArraySize(write(d), ra);
			case OGetType(d, a):
				var ra = read(a);
				OGetType(write(d), ra);
			case OGetTID(d, a):
				var ra = read(a);
				OGetTID(write(d), ra);
			case ORef(d, a):
				var ra = read(a);
				ORef(write(d), ra);
			case OUnref(d, a):
				var ra = read(a);
				OUnref(write(d), ra);
			case OSetref(d, a):
				var ra = read(a);
				OSetref(write(d), ra);
			case OEnumIndex(d, a):
				var ra = read(a);
				OEnumIndex(write(d), ra);
			case OEnumField(d, a, cs, idx):
				var ra = read(a);
				OEnumField(write(d), ra, cs, idx);
			case OType(d, t):
				OType(write(d), t);
			case OEnumAlloc(d, e):
				OEnumAlloc(write(d), e);
			case OMakeEnum(d, e, rl):
				var rl = [for (r in rl) read(r)];
				OMakeEnum(write(d), e, rl);
			case OSetEnumField(a, f, b):
				var rb = read(b);
				OSetEnumField(read(a), f, rb);
			case OAssert(_):
				op;
			case ORefData(r, d):
				var rd = read(d);
				ORefData(write(r), rd);
			case ORefOffset(r, r2, off):
				var rr2 = read(r2);
				var roff = read(off);
				ORefOffset(write(r), rr2, roff);
			case ONop(_):
				op;
		}
	}
}
