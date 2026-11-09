import hxc.codegen.hl.HlDump;
import hxc.codegen.hl.HlWriter;
import sys.io.File;

// Reads a .hl file Haxe wrote, writes it back with HlWriter and compares the bytes; with a -D dump text
// file also compares HlDump's output line by line. Usage: HlRoundTrip <file.hl> [<hlcode.txt>]
class HlRoundTrip {
	// A .hl file has no function names; the dump text does ("fun@N(..)" then "; file:line (name)").
	static function functionNames(dump:Array<String>):Map<Int, String> {
		var names = new Map<Int, String>();
		var header = ~/^\tfun@(\d+)\(/;
		var name = ~/^\t; .* \((.*)\)$/;
		var cur = -1;
		for (line in dump) {
			if (header.match(line)) {
				cur = Std.parseInt(header.matched(1));
			} else if (cur >= 0) {
				if (name.match(line)) names.set(cur, name.matched(1));
				cur = -1;
			}
		}
		return names;
	}

	static function main():Void {
		var args = Sys.args();
		if (args.length < 1) {
			Sys.println("usage: HlRoundTrip <file.hl> [<hlcode.txt>]");
			Sys.exit(2);
		}
		var theirs = File.getBytes(args[0]);
		var want:Array<String> = null;
		var names:Map<Int, String> = null;
		if (args.length > 1) {
			want = File.getContent(args[1]).split("\n");
			if (want[want.length - 1] == "") want.pop();
			names = functionNames(want);
		}
		var rd = HlReader.read(theirs, names);
		var failed = false;
		var ours = HlWriter.write(rd.code, rd.debug);
		var n = ours.length < theirs.length ? ours.length : theirs.length;
		var at = -1;
		for (i in 0...n) if (ours.get(i) != theirs.get(i)) {
			at = i;
			break;
		}
		if (at < 0 && ours.length != theirs.length) at = n;
		if (at < 0) {
			Sys.println("bytes ok " + theirs.length);
		} else {
			Sys.println("bytes differ at " + at + " (ours " + ours.length + ", theirs " + theirs.length + ")");
			failed = true;
		}
		if (want != null) {
			var got:Array<String> = [];
			HlDump.dump(function(s) got.push(s), rd.code);
			var bad = -1;
			var m = got.length < want.length ? got.length : want.length;
			for (i in 0...m) if (got[i] != want[i]) {
				bad = i;
				break;
			}
			if (bad < 0 && got.length != want.length) bad = m;
			if (bad < 0) {
				Sys.println("dump ok " + got.length);
			} else {
				Sys.println("dump differs at line " + (bad + 1) + ":");
				Sys.println("ours:   " + (bad < got.length ? got[bad] : "<end>"));
				Sys.println("theirs: " + (bad < want.length ? want[bad] : "<end>"));
				failed = true;
			}
		}
		if (failed) Sys.exit(1);
	}
}
