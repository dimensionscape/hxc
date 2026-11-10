import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlOpcodes;
import sys.FileSystem;
import sys.io.File;

// Checks HlOpcodes against every op of every function in the .hl files of a directory:
//   (a) opcodeEq(opcodeMap(id, id, op), op)
//   (b) the registers opcodeFx reports as read equal the ones opcodeMap passes to read, in order
//   (c) the same for writes
// Exceptions are hlopt.ml's own asymmetries:
//   OIncr/ODecr: fx reads and writes `a`; map only writes it.
//   ORef(d, a): fx also writes `a` (before d).
//   OCaml evaluates constructor arguments right to left, so OSetField/ODynSet/OSetEnumField and the
//   two-register conditional jumps (OJSLt .. OJNotEq) call `read` on the second register first in map.
// Usage: haxe -cp src -cp tools/hl --run HlOpcodesCheck <dir>
class HlOpcodesCheck {
	static function opName(op:HlOp):String
		return Type.enumConstructor(op);

	static function main() {
		var args = Sys.args();
		if (args.length < 1) {
			Sys.println("usage: HlOpcodesCheck <dir>");
			Sys.exit(2);
		}
		var dir = args[0];
		var checked = 0;
		var mismatches:Array<String> = [];
		var nMis = 0;
		var seen = new Map<String, Int>();
		for (f in FileSystem.readDirectory(dir)) {
			if (!StringTools.endsWith(f, ".hl")) continue;
			var data = HlReader.read(File.getBytes(dir + "/" + f)).code;
			for (fn in data.functions) {
				for (op in fn.code) {
					checked++;
					var name = opName(op);
					seen.set(name, (seen.exists(name) ? seen.get(name) : 0) + 1);
					var fxR:Array<Int> = [], fxW:Array<Int> = [];
					HlOpcodes.opcodeFx((r, rd) -> (rd ? fxR : fxW).push(r), op);
					var mapR:Array<Int> = [], mapW:Array<Int> = [];
					var res = HlOpcodes.opcodeMap(r -> {
						mapR.push(r);
						r;
					}, r -> {
						mapW.push(r);
						r;
					}, op);
					var expR = fxR, expW = fxW;
					switch op {
						case OIncr(_) | ODecr(_):
							expR = [];
						case ORef(_, _):
							expW = [fxW[1]];
						case OSetField(_, _, _) | ODynSet(_, _, _) | OSetEnumField(_, _, _) | OJSLt(_, _, _) | OJSGte(_, _, _) | OJSGt(_, _, _) | OJSLte(_, _, _) | OJULt(_, _, _) | OJUGte(_, _, _) | OJNotLt(_, _, _) | OJNotGte(_, _, _) | OJEq(_, _, _) | OJNotEq(_, _, _):
							expR = fxR.copy();
							expR.reverse();
						default:
					}
					var bad = null;
					if (!HlOpcodes.opcodeEq(res, op)) bad = "map identity";
					else if (expR.join(",") != mapR.join(",")) bad = "reads fx=" + fxR + " map=" + mapR;
					else if (expW.join(",") != mapW.join(",")) bad = "writes fx=" + fxW + " map=" + mapW;
					if (bad != null) {
						nMis++;
						if (mismatches.length < 20) mismatches.push(name + ": " + bad);
					}
				}
			}
		}
		Sys.println(checked + " ops checked, " + nMis + " mismatches");
		for (m in mismatches) Sys.println("  " + m);
		var missing = [for (c in Type.getEnumConstructs(HlOp)) if (!seen.exists(c)) c];
		Sys.println("constructors not seen: " + missing.join(" "));
		if (nMis > 0) Sys.exit(1);
	}
}
