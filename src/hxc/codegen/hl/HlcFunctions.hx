package hxc.codegen.hl;

import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlcNames;
import hxc.codegen.hl.HlcOcaml;
import hxc.codegen.hl.HlcWriter;

// HL/C function bodies: a port of Haxe 4.3.7's hl2c.ml generate_function (520-1099), opcode by opcode in
// hl2c's order. Where one hl2c expression has two side effects on the same state (define, hash), they run in
// OCaml's order: the arguments of a sprintf right to left, List.map and List.map2 left to right.
// This module imports nothing from hxc outside hxc.codegen.hl, so tools/hl/HlcCheck can run it under haxe --run.

// hl2c.ml: comparison
private enum Comparison {
	CEq;
	CNeq;
	CLt;
	CGt;
	CLte;
	CGte;
}

// hl2c.ml: output_options
private enum OutputOption {
	OOLabel;
	OOCase(i:Int);
	OODefault;
	OOIncreaseIndent;
	OODecreaseIndent;
	OOBeginBlock;
	OOEndBlock;
	OOBreak;
}

// A var_map entry: the key's two halves and the registers, in the order they were added (List.rev_map of
// the OCaml list, which holds them newest first).
private typedef LocalDecl = {name:String, stars:Int, regs:Array<String>};

class HlcFunctions {
	static function sComp(c:Comparison):String {
		return switch c {
			case CLt: "<";
			case CGt: ">";
			case CEq: "==";
			case CLte: "<=";
			case CGte: ">=";
			case CNeq: "!=";
		}
	}

	// hlcode.ml: tsame (the same port as HlTypes.tsame, which this module may not import)
	static function tsame(t1:HlType, t2:HlType):Bool {
		if (t1 == t2) return true;
		return switch [t1, t2] {
			case [HFun(args1, ret1), HFun(args2, ret2)] | [HMethod(args1, ret1), HMethod(args2, ret2)] if (args1.length == args2.length):
				for (i in 0...args1.length) if (!tsame(args1[i], args2[i])) return false;
				tsame(ret2, ret1);
			case [HObj(p1), HObj(p2)]: p1 == p2;
			case [HEnum(e1), HEnum(e2)]: e1 == e2;
			case [HStruct(p1), HStruct(p2)]: p1 == p2;
			case [HAbstract(_, a1), HAbstract(_, a2)]: a1 == a2;
			case [HVirtual(v1), HVirtual(v2)]:
				if (v1 == v2) return true;
				if (v1.vfields.length != v2.vfields.length) return false;
				for (i in 0...v1.vfields.length) {
					var f1 = v1.vfields[i], f2 = v2.vfields[i];
					if (!(f1.nameIndex == f2.nameIndex && tsame(f1.t, f2.t))) return false;
				}
				true;
			case [HNull(t1), HNull(t2)]: tsame(t1, t2);
			case [HRef(t1), HRef(t2)]: tsame(t1, t2);
			case _: false;
		}
	}

	// hlcode.ml: safe_cast (can a value of t1 be used as t2)
	static function safeCast(t1:HlType, t2:HlType):Bool {
		if (t1 == t2) return true;
		return switch [t1, t2] {
			case [_, HDyn]: HlCodeUtils.isDynamic(t1);
			case [HVirtual(v1), HVirtual(v2)] if (v2.vfields.length < v1.vfields.length):
				for (i in 0...v2.vfields.length) {
					var f1 = v1.vfields[i], f2 = v2.vfields[i];
					if (!(f1.name == f2.name && tsame(f1.t, f2.t))) return false;
				}
				true;
			case [HObj(p1), HObj(p2)] | [HStruct(p1), HStruct(p2)]:
				var p = p1;
				while (p != null && p.pname != p2.pname) p = p.psuper;
				p != null;
			case [HPacked(t1), HStruct(_)]:
				safeCast(t1, t2);
			case [HFun(args1, r1), HFun(args2, r2)] if (args1.length == args2.length):
				for (i in 0...args1.length) {
					var a1 = args1[i], a2 = args2[i];
					if (!(safeCast(a2, a1) || (a1.match(HDyn) && HlCodeUtils.isDynamic(a2)))) return false;
				}
				safeCast(r1, r2);
			case _:
				tsame(t1, t2);
		}
	}

	// OCaml's structural `=` on types (compare = 0, which is what HlTypeTable.same models).
	static inline function teq(a:HlType, b:HlType):Bool
		return HlTypeTable.same(a, b, []);

	static function die(what:String):Dynamic
		throw "hl2c: generate_function: " + what;

	// hl2c.ml: generate_function
	public static function generateFunction(ctx:HlcContext, f:HlFunction):Void {
		inline function line(s:String) HlcWriter.line(ctx, s);
		inline function expr(s:String) HlcWriter.expr(ctx, s);
		inline function define(s:String) HlcWriter.define(ctx, s);
		inline function block() HlcWriter.block(ctx);
		inline function unblock() HlcWriter.unblock(ctx);
		inline function typeValue(t:HlType) return HlcWriter.typeValue(ctx, t);
		var code = ctx.hlcode;

		var rid = -1;
		var clId = 0;
		inline function reg(id:Int) return "r" + id;

		// hl2c reads ctx.fun_index when a label is made, after the increment below.
		function labelName(p:Int):String
			return "label$" + ctx.filePrefix + ctx.funIndex + "_" + p;
		ctx.funIndex++;
		ctx.definedFuns.set(f.findex, true);
		for (t in f.regs) HlcWriter.defineType(ctx, t);
		HlcWriter.defineType(ctx, f.ftype);

		inline function rtype(r:Int) return f.regs[r];

		inline function funname(fid:Int) return HlcWriter.defineFunction(ctx, fid);

		function rcast(r:Int, t:HlType):String
			return tsame(rtype(r), t) ? reg(r) : "((" + HlcNames.ctype(t) + ")" + reg(r) + ")";

		function rfun(r:Int, args:Array<HlType>, t:HlType):String
			return HlcNames.castFun(reg(r) + "->fun", args, t);

		function rassign(r:Int, t:HlType):String {
			var rt = rtype(r);
			if (t.match(HVoid)) return "";
			var assign = reg(r) + " = ";
			if (tsame(t, rt)) return assign;
			if (!safeCast(t, rt)) return die("rassign: " + HlDump.tstr(t) + " to " + HlDump.tstr(rt));
			var casted = assign + "(" + HlcNames.ctype(rt) + ")";
			return switch t {
				case HPacked(_): casted + "&";
				default: casted;
			}
		}

		function rcasts(rl:Array<Int>, tl:Array<HlType>):String {
			if (rl.length != tl.length) die("List.map2: different lengths");
			return [for (i in 0...rl.length) rcast(rl[i], tl[i])].join(",");
		}

		function ocall(r:Int, fid:Int, args:Array<Int>) {
			var ft = ctx.ftable[fid];
			var rstr = rassign(r, ft.ret);
			var sargs = rcasts(args, ft.args);
			expr(rstr + funname(fid) + "(" + sargs + ")");
		}

		function dynPrefix(t:HlType):String {
			return switch t {
				case HUI8 | HUI16 | HI32 | HBool: "i";
				case HF32: "f";
				case HF64: "d";
				case HI64: "i64";
				default: "p";
			}
		}

		function typeValueOpt(t:HlType):String {
			return switch t {
				case HF32 | HF64 | HI64: "";
				default: "," + typeValue(t);
			}
		}

		function dynCall(r:Int, fr:Int, pl:Array<Int>) {
			line("{");
			block();
			if (pl.length > 0) {
				var items = [];
				for (p in pl) {
					items.push(switch rtype(p) {
						case HDyn: reg(p);
						case t: HlCodeUtils.isDynamic(t) ? "(vdynamic*)" + reg(p) : "hl_make_dyn(&" + reg(p) + "," + typeValue(t) + ")";
					});
				}
				expr("vdynamic *args[] = {" + items.join(",") + "}");
			}
			var rt = rtype(r);
			var ret = rt.match(HVoid) ? "" : HlCodeUtils.isDynamic(rt) ? reg(r) + " = (" + HlcNames.ctype(rt) + ")" : "vdynamic *ret = ";
			expr(ret + "hl_dyn_call((vclosure*)" + reg(fr) + "," + (pl.length == 0 ? "NULL" : "args") + "," + pl.length + ")");
			if (!rt.match(HVoid) && !HlCodeUtils.isDynamic(rt)) {
				// right to left: type_value_opt before the rest
				var opt = typeValueOpt(rt);
				expr(reg(r) + " = (" + HlcNames.ctype(rt) + ")hl_dyn_cast" + dynPrefix(rt) + "(&ret,&hlt_dyn" + opt + ")");
			}
			unblock();
			line("}");
		}

		function mcall(r:Int, fid:Int, pl:Array<Int>) {
			if (pl.length == 0) die("mcall without an object");
			var o = pl[0];
			var args = pl.slice(1);
			switch rtype(o) {
				case HObj(_) | HStruct(_):
					var vfun = HlcNames.castFun(HlcWriter.vobjProto(ctx, reg(o), fid),[rtype(o)].concat([for (a in args) rtype(a)]), rtype(r));
					expr(rassign(r, rtype(r)) + vfun + "(" + [for (x in pl) reg(x)].join(",") + ")");
				case HVirtual(vp):
					var rt = rtype(r);
					var meth = "hl_vfields(" + reg(o) + ")[" + fid + "]";
					meth = HlcNames.castFun(meth, [HDyn].concat([for (a in args) rtype(a)]), rt);
					line("if( hl_vfields(" + reg(o) + ")[" + fid + "] ) " + rassign(r, rt) + meth + "("
						+ [reg(o) + "->value"].concat([for (a in args) reg(a)]).join(",") + "); else {");
					block();
					if (args.length > 0)
						expr("void *args[] = {" + [for (p in args) HlcNames.isPtr(rtype(p)) ? reg(p) : "&" + reg(p)].join(",") + "}");
					var rt = rtype(r);
					var ret = if (rt.match(HVoid)) "" else if (HlcNames.isPtr(rt)) reg(r) + " = (" + HlcNames.ctype(rt) + ")" else {
						expr("vdynamic ret");
						"";
					}
					var vf = vp.vfields[fid];
					// right to left: the hash, then type_value
					var h = HlcWriter.hash(ctx, vf.nameIndex);
					var tv = typeValue(vf.t);
					expr(ret + "hl_dyn_call_obj(" + reg(o) + "->value," + tv + "," + h + "/*" + vf.name + "*/," + (args.length == 0 ? "NULL" : "args") + ","
						+ (HlcNames.isPtr(rt) || rt.match(HVoid) ? "NULL" : "&ret") + ")");
					if (!rt.match(HVoid) && !HlcNames.isPtr(rt)) expr(reg(r) + " = (" + HlcNames.ctype(rt) + ")ret.v." + dynPrefix(rt));
					unblock();
					line("}");
				default:
					die("mcall on " + HlDump.tstr(rtype(o)));
			}
		}

		function resolveField(o:HlClassProto, fid:Int):HlField {
			var fd = HlCodeUtils.resolveField(o, fid);
			if (fd == null) die("resolve_field: " + o.pname + " has no field " + fid);
			return fd;
		}

		function setField(obj:Int, fid:Int, v:Int) {
			switch rtype(obj) {
				case HObj(o) | HStruct(o):
					var fd = resolveField(o, fid);
					expr(reg(obj) + "->" + HlcWriter.objField(fid, fd.name) + " = " + rcast(v, fd.t));
				case HVirtual(vp):
					var vf = vp.vfields[fid];
					var t = vf.t;
					// right to left: type_value_opt, then the hash
					var opt = typeValueOpt(rtype(v));
					var h = HlcWriter.hash(ctx, vf.nameIndex);
					var dset = "hl_dyn_set" + dynPrefix(t) + "(" + reg(obj) + "->value," + h + "/*" + vf.name + "*/" + opt + "," + reg(v) + ")";
					var ct = HlcNames.ctype(t);
					expr("if( hl_vfields(" + reg(obj) + ")[" + fid + "] ) *(" + ct + "*)(hl_vfields(" + reg(obj) + ")[" + fid + "]) = (" + ct + ")" + reg(v)
						+ "; else " + dset);
				default:
					die("set_field on " + HlDump.tstr(rtype(obj)));
			}
		}

		function getField(r:Int, obj:Int, fid:Int) {
			switch rtype(obj) {
				case HObj(o) | HStruct(o):
					var fd = resolveField(o, fid);
					expr(rassign(r, fd.t) + reg(obj) + "->" + HlcWriter.objField(fid, fd.name));
				case HVirtual(vp):
					var vf = vp.vfields[fid];
					var t = vf.t;
					var ct = HlcNames.ctype(t);
					var opt = typeValueOpt(t);
					var h = HlcWriter.hash(ctx, vf.nameIndex);
					var dget = "(" + ct + ")hl_dyn_get" + dynPrefix(t) + "(" + reg(obj) + "->value," + h + "/*" + vf.name + "*/" + opt + ")";
					expr(rassign(r, t) + "hl_vfields(" + reg(obj) + ")[" + fid + "] ? (*(" + ct + "*)(hl_vfields(" + reg(obj) + ")[" + fid + "])) : " + dget);
				default:
					die("get_field on " + HlDump.tstr(rtype(obj)));
			}
		}

		var fret = switch f.ftype {
			case HFun(args, t):
				var sargs = [for (a in args) HlcNames.varType(reg(++rid), a)].join(",");
				line(HlcNames.ctype(t) + " " + funname(f.findex) + "(" + sargs + ") {");
				t;
			default:
				die("function type " + HlDump.tstr(f.ftype));
		}
		block();

		// var_map: keyed by ctype_no_ptr, iterated in OCaml's Hashtbl order.
		var varMap = new CamlHashtbl<LocalDecl>();
		for (i in 0...f.regs.length) {
			var t = f.regs[i];
			if (i <= rid || t.match(HVoid)) continue;
			var c = HlcNames.ctypeNoPtr(t);
			var key = OBlock(new OBlockRef(0, [OStr(new OString(c.name)), OInt(c.stars)]));
			var d = varMap.find(key);
			if (d == null) d = {name: c.name, stars: c.stars, regs: []};
			d.regs.push(reg(i));
			varMap.replace(key, d);
		}
		varMap.iter((_, d) -> {
			var prefix = StringTools.lpad("", "*", d.stars);
			expr(d.name + " " + [for (s in d.regs) prefix + s].join(", "));
		});

		// Each entry in the order output_at added it (the OCaml list reversed).
		var outputOptions:Array<Array<OutputOption>> = [for (_ in 0...f.code.length + 1) []];
		inline function outputAt(i:Int, oo:OutputOption) outputOptions[i].push(oo);
		function outputAt2(i:Int, ool:Array<OutputOption>) for (oo in ool) outputAt(i, oo);
		function hasLabel(i:Int):Bool {
			for (o in outputOptions[i]) if (o.match(OOLabel)) return true;
			return false;
		}

		var trapDepth = 0;
		var maxTrapDepth = 0;
		for (op in f.code) {
			switch op {
				case OTrap(_, _):
					trapDepth++;
					if (trapDepth > maxTrapDepth) maxTrapDepth = trapDepth;
				case OEndTrap(true):
					trapDepth--;
				case OStaticClosure(_, fid):
					var ft = ctx.ftable[fid];
					// right to left: funname, then type_value
					var name = funname(fid);
					var tv = typeValue(HFun(ft.args, ft.ret));
					expr("static vclosure cl$" + clId + " = { " + tv + ", " + name + ", 0 }");
					clId++;
				default:
			}
		}
		for (i in 0...maxTrapDepth) expr("hl_trap_ctx trap$" + i);
		clId = 0;

		function flushOptions(i:Int) {
			var opts = outputOptions[i];
			if (opts.length == 0) return;
			// put label after }
			if (hasLabel(i) && Lambda.exists(opts, o -> o.match(OOEndBlock))) {
				opts = [for (o in opts) if (!o.match(OOLabel)) o];
				opts.push(OOLabel);
			}
			for (o in opts) {
				switch o {
					case OOLabel: line(labelName(i) + ":");
					case OOCase(k): line("case " + k + ":");
					case OODefault: line("default:");
					case OOBreak: line("break;");
					case OOIncreaseIndent: block();
					case OODecreaseIndent: unblock();
					case OOBeginBlock: line("{");
					case OOEndBlock: line("}");
				}
			}
		}

		for (i in 0...f.code.length) {
			var op = f.code[i];
			flushOptions(i);
			function label(delta:Int):String {
				var addr = delta + i + 1;
				var l = labelName(addr);
				if (!hasLabel(addr)) outputAt(addr, OOLabel);
				return l;
			}
			function todo()
				expr("hl_fatal(\"" + HlDump.ostr(id -> "f" + id, op) + "\")");
			function compareOp(op:Comparison, a:Int, b:Int, d:Int):Void {
				function physCompare() {
					var l = label(d);
					expr("if( " + reg(a) + " " + sComp(op) + " " + rcast(b, rtype(a)) + " ) goto " + l);
				}
				var ra = reg(a), rb = reg(b);
				switch [rtype(a), rtype(b)] {
					case [HUI8 | HUI16 | HI32 | HF32 | HF64 | HBool | HI64, HUI8 | HUI16 | HI32 | HF32 | HF64 | HBool | HI64]:
						physCompare();
					case [HBytes, HBytes] | [HArray, HArray]:
						physCompare();
					case [HType, HType]:
						expr("if( hl_same_type(" + ra + "," + rb + ") " + sComp(op) + " 0 ) {} else goto " + label(d));
					case [HNull(t), HNull(_)]:
						var field = HlcNames.dynValueField(t);
						var pcompare = "(" + ra + field + " " + sComp(op) + " " + rb + field + ")";
						if (op == CEq)
							expr("if( " + ra + " == " + rb + " || (" + ra + " && " + rb + " && " + pcompare + ") ) goto " + label(d))
						else if (op == CNeq)
							expr("if( " + ra + " != " + rb + " && (!" + ra + " || !" + rb + " || " + pcompare + ") ) goto " + label(d))
						else
							expr("if( " + ra + " && " + rb + " && " + pcompare + " ) goto " + label(d));
					case [HDyn | HFun(_, _), _] | [_, HDyn | HFun(_, _)]:
						var inv = op == CGt || op == CGte ? "&& i != hl_invalid_comparison " : "";
						expr("{ int i = hl_dyn_compare((vdynamic*)" + ra + ",(vdynamic*)" + rb + "); if( i " + sComp(op) + " 0 " + inv + ") goto " + label(d) + "; }");
					case [HObj(oa), HObj(_)]:
						var fid = oa.pfunctions.get("__compare");
						if (fid == null) physCompare() else {
							// right to left: the label, then funname
							var l = label(d);
							var fn = funname(fid);
							if (op == CEq)
								expr("if( " + ra + " == " + rb + " || (" + ra + " && " + rb + " && " + fn + "(" + ra + ",(vdynamic*)" + rb + ") == 0) ) goto " + l)
							else if (op == CNeq)
								expr("if( " + ra + " != " + rb + " && (!" + ra + " || !" + rb + " || " + fn + "(" + ra + ",(vdynamic*)" + rb + ") != 0) ) goto " + l)
							else
								expr("if( " + ra + " && " + rb + " && " + fn + "(" + ra + ",(vdynamic*)" + rb + ") " + sComp(op) + " 0 ) goto " + l);
						}
					case [HStruct(_), HStruct(_)]:
						physCompare();
					case [HVirtual(_), HVirtual(_)]:
						if (op == CEq)
							expr("if( " + ra + " == " + rb + " || (" + ra + " && " + rb + " && " + ra + "->value && " + rb + "->value && " + ra + "->value == " + rb
								+ "->value) ) goto " + label(d))
						else if (op == CNeq)
							expr("if( " + ra + " != " + rb + " && (!" + ra + " || !" + rb + " || !" + ra + "->value || !" + rb + "->value || " + ra + "->value != "
								+ rb + "->value) ) goto " + label(d))
						else
							die("virtual comparison");
					case [HEnum(_), HEnum(_)] | [HDynObj, HDynObj] | [HAbstract(_, _), HAbstract(_, _)]:
						physCompare();
					case [HVirtual(_), HObj(_)]:
						if (op == CEq)
							expr("if( " + ra + " ? (" + rb + " && " + ra + "->value == (vdynamic*)" + rb + ") : (" + rb + " == NULL) ) goto " + label(d))
						else if (op == CNeq)
							expr("if( " + ra + " ? (" + rb + " == NULL || " + ra + "->value != (vdynamic*)" + rb + ") : (" + rb + " != NULL) ) goto " + label(d))
						else
							die("virtual/object comparison");
					case [HObj(_), HVirtual(_)]:
						compareOp(op, b, a, d);
					case [ta, tb]:
						throw "Don't know how to compare " + HlDump.tstr(ta) + " and " + HlDump.tstr(tb) + " (hlc)";
				}
			}
			switch op {
				case OMov(r, v):
					if (!rtype(r).match(HVoid)) expr(reg(r) + " = " + rcast(v, rtype(r)));
				case OInt(r, idx):
					var v = code.ints[idx];
					expr(reg(r) + " = " + (v == 0x80000000 ? "0x80000000" : Std.string(v)));
				case OFloat(r, idx):
					expr(reg(r) + " = " + HlcNames.floatLiteral(code.floats[idx]));
				case OBool(r, b):
					expr(reg(r) + " = " + (b ? "true" : "false"));
				case OBytes(r, idx):
					define("extern vbyte " + ctx.bytesNames[idx] + "[];");
					expr(reg(r) + " = " + ctx.bytesNames[idx]);
				case OString(r, idx):
					expr(reg(r) + " = (vbyte*)" + HlcWriter.string(ctx, idx));
				case ONull(r):
					expr(reg(r) + " = NULL");
				case OAdd(r, a, b):
					expr(reg(r) + " = " + reg(a) + " + " + reg(b));
				case OSub(r, a, b):
					expr(reg(r) + " = " + reg(a) + " - " + reg(b));
				case OMul(r, a, b):
					expr(reg(r) + " = " + reg(a) + " * " + reg(b));
				case OSDiv(r, a, b):
					switch rtype(r) {
						case HUI8 | HUI16 | HI32:
							expr(reg(r) + " = " + reg(b) + " == 0 ? 0 : " + reg(a) + " / " + reg(b));
						default:
							expr(reg(r) + " = " + reg(a) + " / " + reg(b));
					}
				case OUDiv(r, a, b):
					expr(reg(r) + " = " + reg(b) + " == 0 ? 0 : ((unsigned)" + reg(a) + ") / ((unsigned)" + reg(b) + ")");
				case OSMod(r, a, b):
					switch rtype(r) {
						case HUI8 | HUI16 | HI32 | HI64:
							expr(reg(r) + " = " + reg(b) + " == 0 ? 0 : " + reg(a) + " % " + reg(b));
						case HF32:
							expr(reg(r) + " = fmodf(" + reg(a) + "," + reg(b) + ")");
						case HF64:
							expr(reg(r) + " = fmod(" + reg(a) + "," + reg(b) + ")");
						default:
							die("smod on " + HlDump.tstr(rtype(r)));
					}
				case OUMod(r, a, b):
					expr(reg(r) + " = " + reg(b) + " == 0 ? 0 : ((unsigned)" + reg(a) + ") % ((unsigned)" + reg(b) + ")");
				case OShl(r, a, b):
					expr(reg(r) + " = " + reg(a) + " << " + reg(b));
				case OSShr(r, a, b):
					expr(reg(r) + " = " + reg(a) + " >> " + reg(b));
				case OUShr(r, a, b):
					switch rtype(r) {
						case HI64: expr(reg(r) + " = ((uint64)" + reg(a) + ") >> " + reg(b));
						default: expr(reg(r) + " = ((unsigned)" + reg(a) + ") >> " + reg(b));
					}
				case OAnd(r, a, b):
					expr(reg(r) + " = " + reg(a) + " & " + reg(b));
				case OOr(r, a, b):
					expr(reg(r) + " = " + reg(a) + " | " + reg(b));
				case OXor(r, a, b):
					expr(reg(r) + " = " + reg(a) + " ^ " + reg(b));
				case ONeg(r, v):
					expr(reg(r) + " = -" + reg(v));
				case ONot(r, v):
					expr(reg(r) + " = !" + reg(v));
				case OIncr(r):
					expr("++" + reg(r));
				case ODecr(r):
					expr("--" + reg(r));
				case OCall0(r, fid):
					ocall(r, fid, []);
				case OCall1(r, fid, a):
					ocall(r, fid, [a]);
				case OCall2(r, fid, a, b):
					ocall(r, fid, [a, b]);
				case OCall3(r, fid, a, b, c):
					ocall(r, fid, [a, b, c]);
				case OCall4(r, fid, a, b, c, d):
					ocall(r, fid, [a, b, c, d]);
				case OCallN(r, fid, rl):
					ocall(r, fid, rl);
				case OCallMethod(r, fid, pl):
					mcall(r, fid, pl);
				case OCallThis(r, fid, pl):
					mcall(r, fid, [0].concat(pl));
				case OCallClosure(r, cl, pl):
					switch rtype(cl) {
						case HDyn:
							dynCall(r, cl, pl);
						case HFun(args, ret):
							var sargs = rcasts(pl, args);
							expr(rassign(r, ret) + reg(cl) + "->hasValue ? " + rfun(cl, [HDyn].concat(args), ret) + "((vdynamic*)" + reg(cl) + "->value"
								+ (sargs == "" ? "" : "," + sargs) + ") : " + rfun(cl, args, ret) + "(" + sargs + ")");
						default:
							die("closure call on " + HlDump.tstr(rtype(cl)));
					}
				case OStaticClosure(r, _):
					expr(reg(r) + " = &cl$" + clId);
					clId++;
				case OInstanceClosure(r, fid, ptr):
					var ft = ctx.ftable[fid];
					// right to left: funname, then type_value
					var name = funname(fid);
					var tv = typeValue(HFun(ft.args, ft.ret));
					expr(reg(r) + " = hl_alloc_closure_ptr(" + tv + "," + name + "," + reg(ptr) + ")");
				case OVirtualClosure(r, o, m):
					switch rtype(o) {
						case HObj(p):
							var ft = ctx.ftable[p.pvirtuals[m]];
							var s = HlcWriter.vobjProto(ctx, reg(o), m);
							expr(reg(r) + " = hl_alloc_closure_ptr(" + typeValue(HFun(ft.args, ft.ret)) + "," + s + "," + reg(o) + ")");
						default:
							todo();
					}
				case OGetGlobal(r, g):
					HlcWriter.defineGlobal(ctx, g);
					expr(reg(r) + " = (" + HlcNames.ctype(rtype(r)) + ")" + ctx.gnames[g]);
				case OSetGlobal(g, r):
					HlcWriter.defineGlobal(ctx, g);
					expr(ctx.gnames[g] + " = (" + HlcNames.ctype(code.globals[g]) + ")" + reg(r));
				case ORet(r):
					if (rtype(r).match(HVoid)) expr("return") else expr("return " + rcast(r, fret));
				case OJTrue(r, d) | OJNotNull(r, d):
					expr("if( " + reg(r) + " ) goto " + label(d));
				case OJFalse(r, d) | OJNull(r, d):
					expr("if( !" + reg(r) + " ) goto " + label(d));
				case OJSLt(a, b, d):
					compareOp(CLt, a, b, d);
				case OJSGte(a, b, d):
					compareOp(CGte, a, b, d);
				case OJSGt(a, b, d):
					compareOp(CGt, a, b, d);
				case OJSLte(a, b, d):
					compareOp(CLte, a, b, d);
				case OJULt(a, b, d):
					expr("if( ((unsigned)" + reg(a) + ") < ((unsigned)" + reg(b) + ") ) goto " + label(d));
				case OJUGte(a, b, d):
					expr("if( ((unsigned)" + reg(a) + ") >= ((unsigned)" + reg(b) + ") ) goto " + label(d));
				case OJNotLt(a, b, d):
					expr("if( !(" + reg(a) + " < " + reg(b) + ") ) goto " + label(d));
				case OJNotGte(a, b, d):
					expr("if( !(" + reg(a) + " >= " + reg(b) + ") ) goto " + label(d));
				case OJEq(a, b, d):
					compareOp(CEq, a, b, d);
				case OJNotEq(a, b, d):
					compareOp(CNeq, a, b, d);
				case OJAlways(d):
					expr("goto " + label(d));
				case OLabel(_):
					if (!hasLabel(i)) line(label(-1) + ":");
				case OToDyn(r, v) if (rtype(v).match(HBool)):
					expr(reg(r) + " = hl_alloc_dynbool(" + reg(v) + ")");
				case OToDyn(r, v):
					var ptr = HlcNames.isPtr(rtype(v));
					if (ptr) {
						line("if( " + reg(v) + " == NULL ) " + reg(r) + " = NULL; else {");
						block();
					}
					expr(reg(r) + " = hl_alloc_dynamic(" + typeValue(rtype(v)) + ")");
					switch rtype(v) {
						case HUI8 | HUI16 | HI32 | HBool:
							expr(reg(r) + "->v.i = " + reg(v));
						case HI64:
							expr(reg(r) + "->v.i64 = " + reg(v));
						case HF32:
							expr(reg(r) + "->v.f = " + reg(v));
						case HF64:
							expr(reg(r) + "->v.d = " + reg(v));
						default:
							expr(reg(r) + "->v.ptr = " + reg(v));
					}
					if (ptr) {
						unblock();
						line("}");
					}
				case OToSFloat(r, v):
					expr(reg(r) + " = (" + HlcNames.ctype(rtype(r)) + ")" + reg(v));
				case OToUFloat(r, v):
					expr(reg(r) + " = (" + HlcNames.ctype(rtype(r)) + ")(unsigned)" + reg(v));
				case OToInt(r, v):
					expr(reg(r) + " = (int)" + reg(v));
				case ONew(r):
					switch rtype(r) {
						case HObj(o) | HStruct(o):
							expr(reg(r) + " = (" + HlcNames.tname(o.pname) + ")hl_alloc_obj(" + typeValue(rtype(r)) + ")");
						case HDynObj:
							expr(reg(r) + " = hl_alloc_dynobj()");
						case t = HVirtual(_):
							expr(reg(r) + " = hl_alloc_virtual(" + typeValue(t) + ")");
						default:
							die("new on " + HlDump.tstr(rtype(r)));
					}
				case OField(r, obj, fid):
					getField(r, obj, fid);
				case OSetField(obj, fid, v):
					setField(obj, fid, v);
				case OGetThis(r, fid):
					getField(r, 0, fid);
				case OSetThis(fid, r):
					setField(0, fid, r);
				case OThrow(r):
					expr("hl_throw((vdynamic*)" + reg(r) + ")");
				case ORethrow(r):
					expr("hl_rethrow((vdynamic*)" + reg(r) + ")");
				case OGetUI8(r, b, idx):
					expr(reg(r) + " = *(unsigned char*)(" + reg(b) + " + " + reg(idx) + ")");
				case OGetUI16(r, b, idx):
					expr(reg(r) + " = *(unsigned short*)(" + reg(b) + " + " + reg(idx) + ")");
				case OGetMem(r, b, idx):
					expr(reg(r) + " = *(" + HlcNames.ctype(rtype(r)) + "*)(" + reg(b) + " + " + reg(idx) + ")");
				case OGetArray(r, arr, idx):
					expr(reg(r) + " = ((" + HlcNames.ctype(rtype(r)) + "*)(" + reg(arr) + " + 1))[" + reg(idx) + "]");
				case OSetUI8(b, idx, r):
					expr("*(unsigned char*)(" + reg(b) + " + " + reg(idx) + ") = (unsigned char)" + reg(r));
				case OSetUI16(b, idx, r):
					expr("*(unsigned short*)(" + reg(b) + " + " + reg(idx) + ") = (unsigned short)" + reg(r));
				case OSetMem(b, idx, r):
					expr("*(" + HlcNames.ctype(rtype(r)) + "*)(" + reg(b) + " + " + reg(idx) + ") = " + reg(r));
				case OSetArray(arr, idx, v):
					expr("((" + HlcNames.ctype(rtype(v)) + "*)(" + reg(arr) + " + 1))[" + reg(idx) + "] = " + reg(v));
				case OSafeCast(r, v):
					var tsrc = rtype(v);
					var t = rtype(r);
					if (teq(tsrc, HNull(t)))
						expr(reg(r) + " = " + reg(v) + " ? " + reg(v) + HlcNames.dynValueField(t) + " : 0")
					else {
						// right to left: type_value_opt t, then type_value (rtype v)
						var opt = typeValueOpt(t);
						var tv = typeValue(rtype(v));
						expr(reg(r) + " = (" + HlcNames.ctype(t) + ")hl_dyn_cast" + dynPrefix(t) + "(&" + reg(v) + "," + tv + opt + ")");
					}
				case OUnsafeCast(r, v):
					expr(reg(r) + " = (" + HlcNames.ctype(rtype(r)) + ")" + reg(v));
				case OArraySize(r, a):
					expr(reg(r) + " = " + reg(a) + "->size");
				case OType(r, t):
					expr(reg(r) + " = " + typeValue(t));
				case OGetType(r, v):
					expr(reg(r) + " = " + reg(v) + " ? ((vdynamic*)" + reg(v) + ")->t : &hlt_void");
				case OGetTID(r, v):
					expr(reg(r) + " = " + reg(v) + "->kind");
				case ORef(r, v):
					expr(reg(r) + " = &" + reg(v));
				case OUnref(r, v):
					expr(reg(r) + " = *" + reg(v));
				case OSetref(r, v):
					expr("*" + reg(r) + " = " + reg(v));
				case OToVirtual(r, v):
					expr(reg(r) + " = hl_to_virtual(" + typeValue(rtype(r)) + ",(vdynamic*)" + reg(v) + ")");
				case ODynGet(r, o, sid):
					var t = rtype(r);
					var h = HlcWriter.hash(ctx, sid);
					expr(reg(r) + " = (" + HlcNames.ctype(t) + ")hl_dyn_get" + dynPrefix(t) + "((vdynamic*)" + reg(o) + "," + h + "/*" + code.strings[sid] + "*/"
						+ typeValueOpt(t) + ")");
				case ODynSet(o, sid, v):
					var h = HlcWriter.hash(ctx, sid);
					expr("hl_dyn_set" + dynPrefix(rtype(v)) + "((vdynamic*)" + reg(o) + "," + h + "/*" + code.strings[sid] + "*/" + typeValueOpt(rtype(v)) + ","
						+ reg(v) + ")");
				case OMakeEnum(r, cid, rl):
					var e = switch rtype(r) {
						case HEnum(e): e;
						default: die("makeenum on " + HlDump.tstr(rtype(r)));
					}
					var et = HlcWriter.enumConstrType(ctx, e, cid);
					var needTmp = rl.indexOf(r) >= 0;
					var tmp = if (!needTmp) reg(r) else {
						expr("{ venum *tmp");
						"tmp";
					}
					expr(tmp + " = hl_alloc_enum(" + typeValue(rtype(r)) + "," + cid + ")");
					var tl = e.efields[cid].t;
					for (k in 0...rl.length) expr("((" + et + "*)" + tmp + ")->p" + k + " = " + rcast(rl[k], tl[k]));
					if (needTmp) expr(reg(r) + " = tmp; }");
				case OEnumAlloc(r, cid):
					expr(reg(r) + " = hl_alloc_enum(" + typeValue(rtype(r)) + "," + cid + ")");
				case OEnumIndex(r, v):
					expr(reg(r) + " = HL__ENUM_INDEX__(" + reg(v) + ")");
				case OEnumField(r, e, cid, pid):
					switch rtype(e) {
						case HEnum(en):
							var tn = HlcWriter.enumConstrType(ctx, en, cid);
							var tl = en.efields[cid].t;
							expr(rassign(r, tl[pid]) + "((" + tn + "*)" + reg(e) + ")->p" + pid);
						default:
							die("enumfield on " + HlDump.tstr(rtype(e)));
					}
				case OSetEnumField(e, pid, r):
					switch rtype(e) {
						case HEnum(en):
							var tn = HlcWriter.enumConstrType(ctx, en, 0);
							var tl = en.efields[0].t;
							expr("((" + tn + "*)" + reg(e) + ")->p" + pid + " = (" + HlcNames.ctype(tl[pid]) + ")" + reg(r));
						default:
							die("setenumfield on " + HlDump.tstr(rtype(e)));
					}
				case OSwitch(r, idx, eend):
					line("switch(" + reg(r) + ") {");
					block();
					var pend = i + 1 + eend;
					// insert at end if we have another switch case here
					var old = outputOptions[pend];
					outputOptions[pend] = [];
					// insert cases
					outputAt2(i + 1, [OODefault, OOIncreaseIndent]);
					for (k in 0...idx.length) {
						var delta = idx[k];
						outputAt2(delta + i + 1, [OODecreaseIndent, OOCase(k), OOIncreaseIndent]);
						if (delta == eend) outputAt(pend, OOBreak);
					}
					// insert end switch
					outputAt2(pend, [OODecreaseIndent, OODecreaseIndent, OOEndBlock].concat(old));
				case ONullCheck(r):
					expr("if( " + reg(r) + " == NULL ) hl_null_access()");
				case OTrap(r, d):
					var l = label(d);
					expr("hl_trap(trap$" + trapDepth + "," + reg(r) + "," + l + ")");
					trapDepth++;
				case OEndTrap(b):
					expr("hl_endtrap(trap$" + (trapDepth - 1) + ")");
					if (b) trapDepth--;
				case OAssert(_):
					expr("hl_assert()");
				case ORefData(r, d):
					switch rtype(d) {
						case HArray:
							expr(reg(r) + " = (" + HlcNames.ctype(rtype(r)) + ")hl_aptr(" + reg(d) + ",void*)");
						default:
							die("refdata on " + HlDump.tstr(rtype(d)));
					}
				case ORefOffset(r, r2, off):
					expr(reg(r) + " = " + reg(r2) + " + " + reg(off));
				case ONop(_):
			}
		}
		flushOptions(f.code.length);
		unblock();
		line("}");
		line("");
	}
}
