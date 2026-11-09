import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.macro.Context;

class HlDigest {
	// Prints "== <path> <length> <md5>" once the .hl is written: the length and MD5 of its bytes with the
	// case directory replaced by $CASE and the std directory by $STD in the strings table and the
	// debug-files table (each spelled with / or \). Those tables are length-prefixed, so they are decoded,
	// substituted entry by entry and written again with their lengths recomputed; every other byte is kept.
	// The result is only hashed, never written. The std root is HAXE_STD_PATH, or the class path entry that
	// ends in hl/_std with that removed; entries under it (std/hl/_std/) stay distinct as $STD/hl/_std/.
	public static function after(path:String):Void {
		Context.onAfterGenerate(function() {
			var subs = substitutions();
			var out = normalise(sys.io.File.getBytes(path), subs);
			Sys.println("== " + path + " " + out.length + " " + haxe.crypto.Md5.make(out).toHex());
		});
	}

	static function trimEnd(d:String):String {
		while (d.length > 0 && (StringTools.endsWith(d, "/") || StringTools.endsWith(d, "\\"))) d = d.substr(0, d.length - 1);
		return d;
	}

	// [from, to] pairs, longest first, each directory in its / and \ spellings.
	static function substitutions():Array<Array<String>> {
		var roots:Array<Array<String>> = [[Sys.getCwd(), "$CASE"]];
		var std = Sys.getEnv("HAXE_STD_PATH");
		if (std != null && std != "") roots.push([std, "$STD"]);
		for (cp in Context.getClassPath()) {
			var c = StringTools.replace(trimEnd(cp), "\\", "/");
			if (StringTools.endsWith(c, "/hl/_std")) roots.push([c.substr(0, c.length - "/hl/_std".length), "$STD"]);
		}
		var all:Array<Array<String>> = [];
		for (r in roots) {
			var d = trimEnd(r[0]);
			if (d.length == 0) continue;
			var f = StringTools.replace(d, "\\", "/");
			var b = StringTools.replace(d, "/", "\\");
			for (s in [d, f, b]) {
				var dup = false;
				for (x in all) if (x[0] == s) dup = true;
				if (!dup) all.push([s, r[1]]);
			}
		}
		all.sort((a, b) -> b[0].length - a[0].length);
		return all;
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
	// again with each entry substituted, and returns where it ended.
	static function strings(b:Bytes, pos:Int, n:Int, subs:Array<Array<String>>, out:BytesBuffer):Int {
		var size = b.getInt32(pos);
		var data = pos + 4;
		var p = pos + 4 + size;
		var list = [];
		var at = data;
		for (_ in 0...n) {
			var r = readIndex(b, p);
			p = r.pos;
			list.push(sub(b.getString(at, r.v), subs));
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

	static function normalise(b:Bytes, subs:Array<Array<String>>):Bytes {
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
		pos += nints * 4 + nfloats * 8;
		out.addBytes(b, 0, pos);
		pos = strings(b, pos, nstrings, subs, out);
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
			pos = strings(b, r.pos, nfiles, subs, out);
		} else {
			out.addBytes(b, start, pos - start);
		}
		out.addBytes(b, pos, b.length - pos);
		return out.getBytes();
	}
}
