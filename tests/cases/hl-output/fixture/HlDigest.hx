import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.macro.Context;

class HlDigest {
	// Prints "== <path> <length> <md5>" once the .hl is written: the length and MD5 of its bytes with the
	// case directory replaced by $CASE and the std directory by $STD in the strings table and the
	// debug-files table. Those tables are length-prefixed, so they are decoded, substituted entry by entry and
	// written again with their lengths recomputed, and a substituted string's length in the ints table follows
	// it (see normalise); every other byte is kept. The result is only hashed, never
	// written. The std root is HAXE_STD_PATH, or else the class path entry that ends in hl/_std with that
	// removed; entries under it (std/hl/_std/) stay distinct as $STD/hl/_std/.
	// Each table is substituted only in the spellings Haxe 4.3.7 writes there, so that a compiler spelling a
	// root with the other separator still digests differently: the case directory only ever appears as
	// Path.get_full_path gives it (-D absolute-path), in the native spelling (\ on Windows); the std root
	// appears in the debug files as given (Haxe prefixes the class path verbatim), and in the strings both as
	// given and natively (a -D absolute-path PosInfos file name).
	public static function after(path:String):Void {
		Context.onAfterGenerate(function() {
			var subs = substitutions();
			var out = normalise(sys.io.File.getBytes(path), subs.strings, subs.files);
			Sys.println("== " + path + " " + out.length + " " + haxe.crypto.Md5.make(out).toHex());
		});
	}

	static function trimEnd(d:String):String {
		while (d.length > 0 && (StringTools.endsWith(d, "/") || StringTools.endsWith(d, "\\"))) d = d.substr(0, d.length - 1);
		return d;
	}

	static function native(d:String):String {
		return Sys.systemName() == "Windows" ? StringTools.replace(d, "/", "\\") : d;
	}

	// [from, to] pairs for each table, longest first.
	static function substitutions():{strings:Array<Array<String>>, files:Array<Array<String>>} {
		var std = Sys.getEnv("HAXE_STD_PATH");
		if (std == null || std == "") {
			std = "";
			for (cp in Context.getClassPath()) {
				var c = trimEnd(cp);
				var f = StringTools.replace(c, "\\", "/");
				if (StringTools.endsWith(f, "/hl/_std")) std = c.substr(0, c.length - "/hl/_std".length);
			}
		}
		std = trimEnd(std);
		var cwd = native(trimEnd(Sys.getCwd()));
		function list(pairs:Array<Array<String>>):Array<Array<String>> {
			var all:Array<Array<String>> = [];
			for (p in pairs) {
				if (p[0].length == 0) continue;
				var dup = false;
				for (x in all) if (x[0] == p[0]) dup = true;
				if (!dup) all.push(p);
			}
			all.sort((a, b) -> b[0].length - a[0].length);
			return all;
		}
		return {
			strings: list([[cwd, "$CASE"], [std, "$STD"], [native(std), "$STD"]]),
			files: list([[cwd, "$CASE"], [std, "$STD"]])
		};
	}

	static function sub(s:String, subs:Array<Array<String>>):String {
		for (r in subs) s = StringTools.replace(s, r[0], r[1]);
		return s;
	}

	// hl_read_index / write_index_gen
	static function readIndex(b:Bytes, pos:Int):{v:Int, pos:Int} {
		var c = b.get(pos++);
		if (c & 0x80 == 0) return {v: c & 0x7F, pos: pos};
		if (c & 0x40 == 0) {
			var v = b.get(pos++) | ((c & 31) << 8);
			return {v: c & 0x20 == 0 ? v : -v, pos: pos};
		}
		var v = ((c & 31) << 24) | (b.get(pos) << 16) | (b.get(pos + 1) << 8) | b.get(pos + 2);
		return {v: c & 0x20 == 0 ? v : -v, pos: pos + 3};
	}

	static function writeIndex(buf:BytesBuffer, v:Int) {
		if (v < 0x80) buf.addByte(v);
		else if (v < 0x2000) {
			buf.addByte(0x80 | (v >> 8));
			buf.addByte(v & 0xFF);
		} else {
			buf.addByte(0xC0 | (v >> 24));
			buf.addByte((v >> 16) & 0xFF);
			buf.addByte((v >> 8) & 0xFF);
			buf.addByte(v & 0xFF);
		}
	}

	// Reads the string table of n entries at pos (i32 size, the strings each ended by NUL, n lengths), writes it
	// again with each entry substituted, and returns where it ended. When `lengths` is given, each entry the
	// substitution changed maps its length in characters to the new one there (the first such entry wins).
	static function strings(b:Bytes, pos:Int, n:Int, subs:Array<Array<String>>, out:BytesBuffer, ?lengths:Map<Int, Int>):Int {
		var size = b.getInt32(pos);
		var data = pos + 4;
		var p = pos + 4 + size;
		var list = [];
		var at = data;
		for (_ in 0...n) {
			var r = readIndex(b, p);
			p = r.pos;
			var s = b.getString(at, r.v);
			var t = sub(s, subs);
			if (lengths != null && t != s && !lengths.exists(s.length)) lengths.set(s.length, t.length);
			list.push(t);
			at += r.v + 1;
		}
		var total = 0;
		var bodies = [for (s in list) Bytes.ofString(s)];
		for (x in bodies) total += x.length + 1;
		var head = Bytes.alloc(4);
		head.setInt32(0, total);
		out.add(head);
		for (x in bodies) {
			out.add(x);
			out.addByte(0);
		}
		for (x in bodies) writeIndex(out, x.length);
		return p;
	}

	static function normalise(b:Bytes, stringSubs:Array<Array<String>>, fileSubs:Array<Array<String>>):Bytes {
		var out = new BytesBuffer();
		var pos = 3; // HLB
		var version = b.get(pos++);
		var r = readIndex(b, pos);
		var flags = r.v;
		pos = r.pos;
		var counts = [];
		var nfields = 8 + (version >= 5 ? 1 : 0) + (version >= 4 ? 1 : 0); // ints floats strings [bytes] types globals natives functions [constants] entry
		for (_ in 0...nfields) {
			r = readIndex(b, pos);
			counts.push(r.v);
			pos = r.pos;
		}
		var nints = counts[0], nfloats = counts[1], nstrings = counts[2];
		var nbytes = version >= 5 ? counts[3] : 0;
		// A String constant is its bytes in the strings table and its length in characters in the ints table, so
		// a substituted string's old length is put back as its new one there: a -D absolute-path PosInfos file
		// name in the std otherwise makes the digest depend on how long the std's path is. The ints are pooled by
		// value, so a path whose length equals another constant still shares that entry, and digests differently
		// from a machine where it does not.
		var intsAt = pos;
		pos += nints * 4 + nfloats * 8;
		var lengths = new Map<Int, Int>();
		var table = new BytesBuffer();
		pos = strings(b, pos, nstrings, stringSubs, table, lengths);
		var head = b.sub(0, intsAt + nints * 4 + nfloats * 8);
		for (i in 0...nints) {
			var v = head.getInt32(intsAt + i * 4);
			if (lengths.exists(v)) head.setInt32(intsAt + i * 4, lengths.get(v));
		}
		out.add(head);
		out.add(table.getBytes());
		var start = pos;
		if (version >= 5) {
			var total = b.getInt32(pos);
			pos += 4 + total;
			for (_ in 0...nbytes) pos = readIndex(b, pos).pos;
		}
		if (flags & 1 != 0) {
			r = readIndex(b, pos);
			var nfiles = r.v;
			out.addBytes(b, start, r.pos - start);
			pos = strings(b, r.pos, nfiles, fileSubs, out);
		} else {
			out.addBytes(b, start, pos - start);
		}
		out.addBytes(b, pos, b.length - pos);
		return out.getBytes();
	}
}
