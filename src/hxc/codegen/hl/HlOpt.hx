package hxc.codegen.hl;

import haxe.ds.IntMap;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlOpcodes;

// The HashLink optimiser: a port of Haxe 4.3.7's hlopt.ml lines 440-1097 (code_graph, remap_fun, _optimize,
// optimize) and its types (lines 24-51). The per-opcode tables are HlOpcodes. This file imports nothing
// outside hxc.codegen.hl.
//
// What decides bytes, and is kept from the OCaml:
// - OCaml evaluates constructor and list-literal arguments right to left: in code_graph `[goto 0; goto d]`
//   makes the d block first, and `goto 0 :: Array.to_list (Array.map goto pl)` makes the cases (in index
//   order) before `goto 0`. Each goto conses onto the target's bprev.
// - OCaml lists are arrays here with the head at index 0 (bnext, bprev, btrap, rbind).
// - propagate reuses its first predecessor's state array itself (not a copy) when that predecessor has one
//   successor, so later changes show in both.
// - The assigns remap folds with `loop p @ acc`, reverses, then sorts stably by position.
// - With no dump, the code the assigns remap looks back into is the optimised array itself (OCaml's
//   `old_code` is `f.code` then), so it sees the nops and the renamed reads.

// hlopt.ml: ISet, a Set.Make with `compare a b = b - a`. A set is a sorted array, decreasing (the order
// ISet.elements gives), never changed once made.
class HlISet {
	public static var empty(default, never):Array<Int> = [];

	public static function add(r:Int, s:Array<Int>):Array<Int> {
		var i = 0;
		while (i < s.length && s[i] > r) i++;
		if (i < s.length && s[i] == r) return s;
		var s2 = s.copy();
		s2.insert(i, r);
		return s2;
	}

	public static function union(a:Array<Int>, b:Array<Int>):Array<Int> {
		if (a.length == 0) return b;
		if (b.length == 0) return a;
		var out = [];
		var i = 0, j = 0;
		while (i < a.length && j < b.length) {
			var x = a[i], y = b[j];
			if (x == y) {
				out.push(x);
				i++;
				j++;
			} else if (x > y) {
				out.push(x);
				i++;
			} else {
				out.push(y);
				j++;
			}
		}
		while (i < a.length) out.push(a[i++]);
		while (j < b.length) out.push(b[j++]);
		return out;
	}

	// The predicate runs on every element (its effects are commutative here).
	public static function filter(p:Int->Bool, s:Array<Int>):Array<Int> {
		var out = [];
		for (r in s) if (p(r)) out.push(r);
		return out;
	}
}

// hlopt.ml: reg_state
class HlRegState {
	public var rindex:Int;
	public var ralias:HlRegState;
	// an OCaml list, head first
	public var rbind:Array<HlRegState> = [];
	public var rnullcheck = false;

	public function new(i:Int) {
		rindex = i;
		ralias = this;
	}
}

// hlopt.ml: block
class HlBlock {
	public var bstart:Int;
	public var bend = 0;
	public var bnext:Array<HlBlock> = [];
	public var bprev:Array<HlBlock> = [];
	public var bloop = false;
	public var bstate:Null<Array<HlRegState>> = null;
	public var bneed:Array<Int> = HlISet.empty;
	public var bneedAll:Null<Array<Int>> = null;
	// register -> position of its last write in the block (a PMap)
	public var bwrite:IntMap<Int> = new IntMap();
	public var btrap:Array<Int>;

	public function new(pos:Int, trapl:Array<Int>) {
		bstart = pos;
		btrap = trapl;
	}
}

// hlopt.ml: rctx
typedef HlRctx = {
	root:HlBlock,
	usedRegs:Int,
	nopCount:Int,
	blocksPos:IntMap<HlBlock>,
	// Hashtbl.add, and only ever looked up: the latest binding is the one found
	regMoved:IntMap<{r:Int, w:Int}>,
	liveBits:Array<Int>,
	regMap:Array<Int>
}

typedef HlOptAssign = {name:Int, reg:Int};

class HlOpt {
	static inline var BIT_REGS = 30;

	static function die(?pos:haxe.PosInfos):Dynamic {
		throw "hl: internal error in the optimiser (" + pos.fileName + ":" + pos.lineNumber + ")";
	}

	static function nargsOf(f:HlFunction):Int {
		return switch f.ftype {
			case HFun(args, _): args.length;
			case _: die();
		}
	}

	// hlopt.ml: code_graph
	static function codeGraph(f:HlFunction):{blocksPos:IntMap<HlBlock>, root:HlBlock} {
		var code = f.code;
		var blocksPos = new IntMap<HlBlock>();
		var allBlocks = new IntMap<Bool>();
		for (i in 0...code.length) switch HlOpcodes.control(code[i]) {
			case CJAlways(d) | CJCond(d): allBlocks.set(i + 1 + d, true);
			case _:
		}
		function makeBlock(trapl:Array<Int>, pos:Int):HlBlock {
			var found = blocksPos.get(pos);
			if (found != null) return found;
			var b = new HlBlock(pos, trapl);
			blocksPos.set(pos, b);
			function goto(i:Int, tl:Array<Int>, d:Int):HlBlock {
				var b2 = makeBlock(tl, i + 1 + d);
				b2.bprev.unshift(b);
				return b2;
			}
			var i = pos;
			while (true) {
				if (i > pos && allBlocks.exists(i)) {
					b.bend = i - 1;
					b.bnext = [goto(i, b.btrap, -1)];
					break;
				}
				switch HlOpcodes.control(code[i]) {
					case CNo:
						i++;
						continue;
					case CRet:
						if (b.btrap.length != 0) die();
						b.bend = i;
					case CJAlways(d):
						b.bend = i;
						b.bnext = [goto(i, b.btrap, d)];
					case CSwitch(pl):
						b.bend = i;
						// `goto 0 :: Array.to_list (Array.map goto pl)`: the cases first, in order
						var cases = [for (p in pl) goto(i, b.btrap, p)];
						var b0 = goto(i, b.btrap, 0);
						b.bnext = [b0].concat(cases);
					case CJCond(d):
						b.bend = i;
						// `[goto 0; goto d]`: d first
						var bd = goto(i, b.btrap, d);
						var b0 = goto(i, b.btrap, 0);
						b.bnext = [b0, bd];
					case CTry(d):
						b.bend = i;
						var bd = goto(i, b.btrap, d);
						var b0 = goto(i, [i + 1 + d].concat(b.btrap), 0);
						b.bnext = [b0, bd];
					case CThrow:
						b.bend = i;
						if (b.btrap.length > 0) b.bnext = [goto(i, b.btrap.slice(1), b.btrap[0] - 1 - i)];
					case CCatch:
						if (b.btrap.length == 0) die();
						var p = b.btrap[0], pl = b.btrap.slice(1);
						b.bend = i;
						var bp = goto(i, pl, p - 1 - i);
						var b0 = goto(i, pl, 0);
						b.bnext = [b0, bp];
					case CLabel:
						b.bloop = true;
						i++;
						continue;
				}
				break;
			}
			return b;
		}
		var root = makeBlock([], 0);
		return {blocksPos: blocksPos, root: root};
	}

	static function hex(n:Int):String {
		return StringTools.hex(n);
	}

	// Printf's `%-<n>s`
	static function pad(s:String, n:Int):String {
		return s.length >= n ? s : StringTools.rpad(s, " ", n);
	}

	// hlopt.ml: remap_fun
	static function remapFun(ctx:HlRctx, f:HlFunction, dump:Null<String->Void>, getStr:Int->String, oldCode:Array<HlOp>):HlFunction {
		var code = f.code;
		var nregs = f.regs.length;
		var regRemap = ctx.usedRegs != nregs;
		var assigns = f.assigns;
		var nargs = nargsOf(f);

		var liveBits = ctx.liveBits;
		var regMap = ctx.regMap;

		var stride = Std.int((nregs + BIT_REGS - 1) / BIT_REGS);
		function isLive(r:Int, i:Int):Bool {
			var offset = Std.int(r / BIT_REGS);
			var mask = 1 << (r - offset * BIT_REGS);
			return liveBits[i * stride + offset] & mask != 0;
		}

		// remap assigns
		if (ctx.nopCount > 0) {
			function resolveBlock(p:Int):HlBlock {
				while (true) {
					var b = ctx.blocksPos.get(p);
					if (b != null) return b;
					p--;
				}
			}

			// the OCaml list acc, head first
			var newAssigns:Array<HlOptAssign> = [];
			for (a in assigns) {
				var i = a.name;
				var gmap = new IntMap<Bool>();
				// For a given assign at position p, that's been optimized out, let's try to find where the last
				// assign that maps to the same value is, and remap the variable name to it
				function loop(p:Int):Array<HlOptAssign> {
					if (p < 0 || !code[p].match(ONop(_))) return [{name: i, reg: p}];
					var moved = ctx.regMoved.get(p);
					var reg = moved == null ? -1 : moved.r;
					var lastW = moved == null ? -1 : moved.w;
					if (reg < 0) return [];
					if (reg < nargs) return [{name: i, reg: -reg - 1}];
					var b = resolveBlock(p);
					if (lastW >= b.bstart && lastW < b.bend && lastW < p) return loop(lastW);
					var wp = b.bwrite.exists(reg) ? b.bwrite.get(reg) : -1;
					function gather(b:HlBlock):Array<HlOptAssign> {
						if (gmap.exists(b.bstart)) return [];
						gmap.set(b.bstart, true);
						// lookup in all parent blocks, recursively, to fetch all last writes
						var acc:Array<HlOptAssign> = [];
						for (bp in b.bprev) {
							if (bp.bstart > b.bstart) continue;
							if (bp.bwrite.exists(reg)) {
								var wp = bp.bwrite.get(reg);
								if (wp > p) die();
								acc = loop(wp).concat(acc);
							} else {
								acc = gather(bp).concat(acc);
							}
						}
						return acc;
					}
					if (wp < 0) return gather(b);
					if (wp < p) return loop(wp);
					// lookup in writes between p-1 and block bstart
					var q = p - 1;
					while (true) {
						if (q < b.bstart) return gather(b);
						var found = false;
						HlOpcodes.opcodeFx((r, read) -> if (r == reg && !read) found = true, oldCode[q]);
						if (found) return loop(q);
						q--;
					}
				}
				newAssigns = loop(a.reg).concat(newAssigns);
			}
			newAssigns.reverse();
			// List.sort is a stable merge sort
			haxe.ds.ArraySort.sort(newAssigns, (a1, a2) -> a1.reg - a2.reg);
			assigns = newAssigns;
		}

		// done
		if (dump != null) {
			var write = dump;
			var oldAssigns = new IntMap<Int>();
			var newAssignsAt = new IntMap<Array<Int>>();
			for (a in f.assigns) if (a.reg >= 0) oldAssigns.set(a.reg, a.name);
			for (a in assigns) if (a.reg >= 0) {
				var l = newAssignsAt.get(a.reg);
				if (l == null) newAssignsAt.set(a.reg, l = []);
				l.unshift(a.name);
			}
			write(HlDump.fundeclName(f) + "@" + f.findex);
			var args = [];
			for (a in f.assigns) {
				if (a.reg >= 0) break;
				args.push(getStr(a.name) + ":" + a.reg);
			}
			write("ARGS = " + args.join(", "));
			write("");
			if (regRemap) {
				for (i in 0...nregs) {
					var m = regMap[i];
					write("\tr" + pad(Std.string(i), 2) + " " + pad(HlDump.tstr(f.regs[i]), 10)
						+ (m < 0 ? " unused" : m == i ? "" : " r" + pad(Std.string(m), 2)));
				}
			}
			for (i in 0...code.length) {
				var b = ctx.blocksPos.get(i);
				if (b != null) {
					write("\t----- [" + [for (b2 in b.bnext) hex(b2.bstart)].join(",") + "] (" + hex(b.bend) + ")");
					var need = [for (r in b.bneed) Std.string(r)].join(",");
					var keys = [for (r in b.bwrite.keys()) r];
					keys.sort((a, b) -> a - b);
					var wr = [for (r in keys) r + "@" + hex(b.bwrite.get(r))].join(" ");
					write("\t" + (b.bloop ? "LOOP " : "") + "NEED=" + need + "\tWRITE=" + wr);
				}
				var old = oldCode[i];
				var op = code[i];
				var live = [];
				for (r in 0...nregs) if (isLive(r, i)) live.push(r);
				var varSet = oldAssigns.exists(i) ? "set " + getStr(oldAssigns.get(i)) : "";
				var nvarSet = newAssignsAt.exists(i) ? "set " + [for (v in newAssignsAt.get(i)) getStr(v)].join(",") : "";
				write("\t@" + pad(hex(i), 3) + " " + pad(HlDump.ostr(Std.string, old), 20) + " "
					+ pad(HlOpcodes.opcodeEq(old, op) ? "" : HlDump.ostr(Std.string, op), 20) + " " + pad(varSet, 20) + " " + pad(nvarSet, 20)
					+ " LIVE=" + live.join(","));
			}
			write("");
			write("");
		}

		var outCode = code;
		var regs = f.regs;
		var debug = f.debug;

		if (ctx.nopCount > 0 || regRemap) {
			var newPos = [for (_ in 0...code.length) 0];
			var jumps = [];
			var outPos = 0;
			outCode = [];
			var newDebug = [];
			for (i in 0...code.length) {
				var op = code[i];
				newPos[i] = outPos;
				switch op {
					case ONop(_):
					case _:
						switch op {
							case OJTrue(_) | OJFalse(_) | OJNull(_) | OJNotNull(_) | OJSLt(_) | OJSGte(_) | OJSGt(_) | OJSLte(_) | OJNotLt(_) | OJNotGte(_) | OJULt(_) | OJUGte(_) | OJEq(_) | OJNotEq(_) | OJAlways(_) | OSwitch(_) | OTrap(_):
								jumps.push(i);
							case _:
						}
						if (regRemap) op = HlOpcodes.opcodeMap(r -> regMap[r], r -> regMap[r], op);
						outCode[outPos] = op;
						newDebug[outPos] = f.debug[i];
						outPos++;
				}
			}
			for (j in jumps) {
				function pos(d:Int):Int {
					return newPos[j + 1 + d] - newPos[j + 1];
				}
				var p = newPos[j];
				outCode[p] = switch outCode[p] {
					case OJTrue(r, d): OJTrue(r, pos(d));
					case OJFalse(r, d): OJFalse(r, pos(d));
					case OJNull(r, d): OJNull(r, pos(d));
					case OJNotNull(r, d): OJNotNull(r, pos(d));
					case OJSLt(a, b, d): OJSLt(a, b, pos(d));
					case OJSGte(a, b, d): OJSGte(a, b, pos(d));
					case OJSLte(a, b, d): OJSLte(a, b, pos(d));
					case OJSGt(a, b, d): OJSGt(a, b, pos(d));
					case OJULt(a, b, d): OJULt(a, b, pos(d));
					case OJUGte(a, b, d): OJUGte(a, b, pos(d));
					case OJNotLt(a, b, d): OJNotLt(a, b, pos(d));
					case OJNotGte(a, b, d): OJNotGte(a, b, pos(d));
					case OJEq(a, b, d): OJEq(a, b, pos(d));
					case OJNotEq(a, b, d): OJNotEq(a, b, pos(d));
					case OJAlways(d): OJAlways(pos(d));
					case OSwitch(r, cases, send): OSwitch(r, [for (c in cases) pos(c)], pos(send));
					case OTrap(r, d): OTrap(r, pos(d));
					case _: die();
				}
			}

			for (idx in 0...assigns.length) {
				var a = assigns[idx];
				if (a.reg >= 0) assigns[idx] = {name: a.name, reg: newPos[a.reg]};
			}

			debug = newDebug;
			if (regRemap) {
				var newRegs = [for (_ in 0...ctx.usedRegs) HVoid];
				for (i in 0...nregs) {
					var p = regMap[i];
					if (p >= 0) newRegs[p] = f.regs[i];
				}
				regs = newRegs;
			}
		}
		return {
			fpath: f.fpath,
			findex: f.findex,
			ftype: f.ftype,
			regs: regs,
			code: outCode,
			debug: debug,
			assigns: assigns
		};
	}

	// hlopt.ml: _optimize. Rewrites f.code in place.
	static function optimizeCode(f:HlFunction):HlRctx {
		return new HlOptPass(f).run();
	}

	// hlopt.ml: optimize. `dump` gets each line of dump/hlopt.txt, without its newline. OCaml's last argument
	// only fed a cache that 4.3.7 leaves commented out, so it is not here.
	public static function optimize(dump:Null<String->Void>, getStr:Int->String, f:HlFunction):HlFunction {
		var oldCode = dump == null ? f.code : f.code.copy();
		var rctx = optimizeCode(f);
		return remapFun(rctx, f, dump, getStr, oldCode);
	}
}

// hlopt.ml: _optimize, its closures as methods.
private class HlOptPass {
	static inline var BIT_REGS = 30;

	var f:HlFunction;
	var code:Array<HlOp>;
	var nregs:Int;
	var nopCount = 0;
	var readCounts:Array<Int>;
	var writeCounts:Array<Int>;
	var lastWrite:Array<Int>;
	var stride:Int;
	var liveBits:Array<Int>;
	var regMoved = new IntMap<{r:Int, w:Int}>();

	public function new(f:HlFunction) {
		this.f = f;
		code = f.code;
		nregs = f.regs.length;
		readCounts = [for (_ in 0...nregs) 0];
		writeCounts = [for (_ in 0...nregs) 0];
		lastWrite = [for (_ in 0...nregs) -1];
		stride = Std.int((nregs + BIT_REGS - 1) / BIT_REGS);
		liveBits = [for (_ in 0...code.length * stride) 0];
	}

	static function die(?pos:haxe.PosInfos):Dynamic {
		throw "hl: internal error in the optimiser (" + pos.fileName + ":" + pos.lineNumber + ")";
	}

	inline function setNop(index:Int, r:String):Void {
		code[index] = ONop(r);
		nopCount++;
	}

	inline function addRegMoved(p:Int, w:Int, r:Int):Void {
		regMoved.set(p, {r: r, w: lastWrite[r]});
	}

	function setLive(r:Int, min:Int, max:Int):Void {
		var offset = Std.int(r / BIT_REGS);
		var mask = 1 << (r - offset * BIT_REGS);
		if (min < 0 || max >= code.length) die();
		for (i in min...max + 1) {
			var p = i * stride + offset;
			liveBits[p] = liveBits[p] | mask;
		}
	}

	function isLive(r:Int, i:Int):Bool {
		var offset = Std.int(r / BIT_REGS);
		var mask = 1 << (r - offset * BIT_REGS);
		return liveBits[i * stride + offset] & mask != 0;
	}

	function emptyState():Array<HlRegState> {
		return [for (i in 0...nregs) new HlRegState(i)];
	}

	function isPackedField(o:Int, fid:Int):Bool {
		return switch f.regs[o] {
			case HStruct(p) | HObj(p):
				var ft = HlCodeUtils.resolveField(p, fid);
				if (ft == null) die();
				ft.t.match(HPacked(_));
			case _:
				false;
		}
	}

	function unalias(r:HlRegState):Void {
		r.ralias.rbind = r.ralias.rbind.filter(r2 -> r2 != r);
		r.ralias = r;
	}

	function propagate(b:HlBlock):Void {
		var state:Array<HlRegState>;
		if (b.bloop || b.bprev.length == 0) {
			state = emptyState();
		} else {
			var b2 = b.bprev[0];
			var s = getState(b2);
			if (b2.bnext.length == 0) die();
			if (b2.bnext.length > 1) {
				var s2 = emptyState();
				for (i in 0...nregs) {
					var sold = s[i], snew = s2[i];
					snew.ralias = s2[sold.ralias.rindex];
					snew.rbind = [for (x in sold.rbind) s2[x.rindex]];
					snew.rnullcheck = sold.rnullcheck;
				}
				s = s2;
			} // else reuse
			for (k in 1...b.bprev.length) {
				var st2 = getState(b.bprev[k]);
				for (i in 0...nregs) {
					var s1 = s[i], s2 = st2[i];
					if (s1.ralias.rindex != s2.ralias.rindex) s1.ralias = s1;
				}
				for (i in 0...nregs) {
					var s1 = s[i], s2 = st2[i];
					s1.rbind = s1.rbind.filter(x -> x.ralias == s1);
					s1.rnullcheck = s1.rnullcheck && s2.rnullcheck;
					if (s2.rbind.length > 0) {
						// fold_left consing onto s1.rbind, membership checked in s1.rbind as it was
						var acc = s1.rbind;
						for (sb2 in s2.rbind) {
							var x = s[sb2.rindex];
							if (x.ralias == s1 && s1.rbind.indexOf(x) < 0) acc = [x].concat(acc);
						}
						s1.rbind = acc;
					}
				}
			}
			state = s;
		}
		var i = b.bstart;
		function doRead(r:Int):Void {
			var w = lastWrite[r];
			if (w < b.bstart || w > i) {
				lastWrite[r] = i;
				setLive(r, b.bstart, i);
				b.bneed = HlISet.add(r, b.bneed);
			} else
				setLive(r, w + 1, i);
			readCounts[r]++;
		}
		function doWrite(r:Int):Void {
			var s = state[r];
			for (s2 in s.rbind) s2.ralias = s2;
			s.rbind = [];
			s.rnullcheck = false;
			lastWrite[r] = i;
			b.bwrite.set(r, i);
			writeCounts[r]++;
			unalias(s);
		}
		while (i <= b.bend) {
			var op = code[i];
			switch op {
				case OIncr(r) | ODecr(r) | ORef(_, r):
					unalias(state[r]);
				case OCallClosure(_, r, _) if (f.regs[r].match(HDyn) && switch f.regs[state[r].ralias.rindex] {
					case HFun(_, rt): !HlCodeUtils.isDynamic(rt);
					case HDyn: false;
					case _: true;
				}):
					unalias(state[r]); // Issue3218.hx
				case _:
			}
			op = HlOpcodes.opcodeMap(r -> state[r].ralias.rindex, w -> w, op);
			code[i] = op;
			switch op {
				case OMov(d, v) | OToInt(d, v) | OToSFloat(d, v) if (d == v):
					addRegMoved(i, d, v);
					setNop(i, "mov");
				case OMov(d, v):
					var sv = state[v];
					var sd = state[d];
					doRead(v);
					doWrite(d);
					sd.ralias = sv;
					sd.rnullcheck = sv.rnullcheck;
					if (sv.rbind.indexOf(sd) < 0) sv.rbind.unshift(sd);
				case OIncr(r) | ODecr(r):
					doRead(r);
					doWrite(r);
				case ONullCheck(r):
					var s = state[r];
					if (s.rnullcheck) setNop(i, "nullcheck") else {
						doRead(r);
						s.rnullcheck = true;
					}
				case ONew(r):
					var s = state[r];
					doWrite(r);
					s.rnullcheck = true;
				case OToVirtual(v, o):
					doRead(o);
					doWrite(v);
					state[v].rnullcheck = state[o].rnullcheck;
				case OField(r, o, fid) if (f.regs[r].match(HStruct(_))):
					doRead(o);
					doWrite(r);
					if (isPackedField(o, fid)) state[r].rnullcheck = true;
				case OGetThis(r, fid) if (f.regs[r].match(HStruct(_))):
					doWrite(r);
					if (isPackedField(0, fid)) state[r].rnullcheck = true;
				case _:
					HlOpcodes.opcodeFx((r, read) -> if (read) doRead(r) else doWrite(r), op);
			}
			i++;
		}
		b.bstate = state;
		for (b2 in b.bnext) getState(b2);
	}

	function getState(b:HlBlock):Array<HlRegState> {
		if (b.bstate != null) return b.bstate;
		// recurse before calculating
		for (b2 in b.bprev) if (b2.bstart < b.bstart) getState(b2);
		if (b.bstate != null) return b.bstate;
		propagate(b);
		return getState(b);
	}

	function live(b:HlBlock):Array<Int> {
		if (b.bneedAll != null) return b.bneedAll;
		function needSub(bl:Array<HlBlock>):Array<Int> {
			var acc = HlISet.empty;
			for (b2 in bl) {
				// loop : first pass does not recurse, second pass uses cache
				if (b2.bloop && b2.bstart < b.bstart) {
					if (b2.bneedAll != null) acc = HlISet.union(acc, b2.bneedAll);
				} else
					acc = HlISet.union(acc, live(b2));
			}
			return HlISet.filter(r -> {
				if (b.bwrite.exists(r)) {
					setLive(r, b.bwrite.get(r) + 1, b.bend);
					false;
				} else {
					setLive(r, b.bstart, b.bend);
					true;
				}
			}, acc);
		}
		b.bneedAll = HlISet.union(b.bneed, needSub(b.bnext));
		if (b.bloop) {
			// if we are a loop, we need a second pass to perform fixed point: first clear the cache within the
			// loop from backward, then rebuild the cache to make sure liveness ranges are correctly set
			function clear(b2:HlBlock):Void {
				if (b2.bneedAll != null && b2.bstart > b.bstart) {
					b2.bneedAll = null;
					for (b3 in b2.bprev) clear(b3);
				}
			}
			for (b2 in b.bprev) if (b2.bstart > b.bstart) clear(b2);
			for (b2 in b.bnext) live(b2);
			// do-while loop : recompute self after recompute all next
			b.bneedAll = HlISet.union(b.bneed, needSub(b.bnext));
		}
		return b.bneedAll;
	}

	public function run():HlRctx {
		var graph = @:privateAccess HlOpt.codeGraph(f);
		var blocksPos = graph.blocksPos, root = graph.root;

		propagate(root);

		// unreachable code
		var i = 0;
		while (i < code.length) {
			var b = blocksPos.get(i);
			if (b != null) {
				i = b.bend + 1;
				continue;
			}
			switch code[i] {
				case OEndTrap(true):
				case _: setNop(i, "unreach");
			}
			i++;
		}

		// liveness
		live(root);

		// nop
		for (i in 0...code.length) {
			switch code[i] {
				case OMov(d, r) if (!isLive(d, i + 1)):
					readCounts[r]--;
					writeCounts[d]--;
					addRegMoved(i, d, r);
					setNop(i, "unused");
				case OJAlways(d) if (d >= 0):
					var k = 0;
					while (true) {
						if (k == d) {
							setNop(i, "nojmp");
							break;
						}
						if (code[i + k + 1].match(ONop(_))) k++ else break;
					}
				case _:
			}
		}

		// reg map
		var usedRegs = 0;
		var regMap = readCounts;
		var nargs = @:privateAccess HlOpt.nargsOf(f);
		for (i in 0...nregs) {
			if (readCounts[i] > 0 || writeCounts[i] > 0 || i < nargs) {
				regMap[i] = usedRegs;
				usedRegs++;
			} else
				regMap[i] = -1;
		}
		return {
			root: root,
			blocksPos: blocksPos,
			nopCount: nopCount,
			usedRegs: usedRegs,
			liveBits: liveBits,
			regMap: regMap,
			regMoved: regMoved
		};
	}
}
