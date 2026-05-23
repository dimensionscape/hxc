package hxc.eval;

import hxc.eval.EvalString.ByteString;

/**
 * The pcre2 binding the interpreter's EReg runs on, over the PCRE2 10.42 hxcpp already links. The
 * code units are 8-bit and the subject is the interpreter string's bytes: an EReg never sees host
 * text, so a string that is not valid UTF-8 matches byte for byte (matching passes `NO_UTF_CHECK`).
 */
enum Pcre2Error {
	Partial;
	BadPattern(msg:String, pos:Int);
	BadUTF;
	BadUTFOffset;
	MatchLimit;
	DepthLimit;
	WorkspaceSize;
	InternalError(msg:String);
}

// The binding's `Error` exception. Where a native does not catch it, it leaves the interpreter as
// an uncaught native exception. No printer is registered for it, so it prints generically: a
// constructor without arguments as its index, one with arguments as `_`.
class Pcre2Exception extends EvalExceptions.HostException {
	public final error:Pcre2Error;

	public function new(error:Pcre2Error) {
		super(render(error), false);
		this.error = error;
	}

	// The generic rendering: the constructors without arguments are numbered in declaration order
	// (0..5), and BadPattern / InternalError, which carry arguments, print as `_`.
	static function render(error:Pcre2Error):String {
		var inner = switch (error) {
			case Partial: "0";
			case BadUTF: "1";
			case BadUTFOffset: "2";
			case MatchLimit: "3";
			case DepthLimit: "4";
			case WorkspaceSize: "5";
			case BadPattern(_, _) | InternalError(_): "_";
		};
		return "Pcre2.Error(" + inner + ")";
	}
}

// Raised where the binding finds no match or no group.
class Pcre2NotFound {
	public function new() {}
}

// The compile-time and run-time flags, with the values pcre2.h 10.42 gives them.
enum abstract Pcre2Flag(Int) to Int {
	var CASELESS = 0x00000008;
	var DOTALL = 0x00000020;
	var MULTILINE = 0x00000400;
	var UCP = 0x00020000;
	var UTF = 0x00080000;
	var NOTEMPTY = 0x00000004;
	var NO_UTF_CHECK = 0x40000000;
}

@:buildXml('<files id="haxe"><compilerflag value="-I${HXCPP}/project/thirdparty/pcre2-10.42/src"/></files>')
@:cppFileCode('#define PCRE2_STATIC\n#define PCRE2_CODE_UNIT_WIDTH 8\n#include <pcre2.h>\n#include <string.h>\nextern int _hxcpp_argc;\nextern char **_hxcpp_argv;\nstatic unsigned char hxc_pcre2_empty[1] = {0};')
class Pcre2 {
	// The compiled pattern (pcre2_code*), kept as an address; freed with the regexp.
	final code:cpp.RawPointer<cpp.Void>;
	public final captureCount:Int;

	function new(code:cpp.RawPointer<cpp.Void>) {
		this.code = code;
		var n = 0;
		untyped __cpp__("uint32_t hxc_n = 0; pcre2_pattern_info((pcre2_code*){0}, PCRE2_INFO_CAPTURECOUNT, &hxc_n); {1} = (int)hxc_n", code, n);
		captureCount = n;
		cpp.vm.Gc.setFinalizer(this, cpp.Function.fromStaticFunction(finalize));
	}

	@:void static function finalize(r:Pcre2):Void {
		untyped __cpp__("pcre2_code_free((pcre2_code*){0})", r.code);
	}

	// The pattern's bytes, the compile options, no character tables; a failure is a
	// BadPattern(message, offset) error. The message is a 128-byte string that
	// pcre2_get_error_message fills up to its NUL; the rest is zeros.
	public static function compile(options:Int, pattern:ByteString):Pcre2 {
		var b = pattern.toBytes();
		var len = b.length;
		var errcode = 0;
		var erroffset = 0;
		var code:cpp.RawPointer<cpp.Void> = null;
		untyped __cpp__("{
			int hxc_err = 0; PCRE2_SIZE hxc_off = 0;
			PCRE2_SPTR hxc_p = {1} > 0 ? (PCRE2_SPTR){0}->b->GetBase() : hxc_pcre2_empty;
			{2} = (void*)pcre2_compile(hxc_p, (PCRE2_SIZE){1}, (uint32_t){3}, &hxc_err, &hxc_off, NULL);
			{4} = hxc_err; {5} = (int)hxc_off;
		}", b, len, code, options, errcode, erroffset);
		if (code == null) {
			var msg = "";
			untyped __cpp__("{ PCRE2_UCHAR hxc_buf[128]; memset(hxc_buf, 0, 128); pcre2_get_error_message({1}, hxc_buf, 128); {0} = ::String::create((const char*)hxc_buf, 128); }", msg, errcode);
			throw new Pcre2Exception(BadPattern(msg, erroffset));
		}
		return new Pcre2(code);
	}

	/**
	 * Pcre2_match with no callout: match `subj` from byte `pos` under the run-time `options`, filling
	 * `ovector` (start/end pairs for the whole match and every group, -1 for a group that did not take
	 * part). NOMATCH raises Pcre2NotFound, a malformed-UTF result BadUTF, and so on.
	 */
	public function match(options:Int, pos:Int, subj:haxe.io.Bytes, ovector:Array<Int>):Void {
		var len = subj.length;
		if (pos > len || pos < 0) throw new EvalExceptions.HostException("Invalid_argument(\"Pcre2.pcre2_match_stub: illegal position\")", false);
		var pairs = captureCount + 1;
		var out = new Array<Int>();
		out.resize(pairs * 2);
		var ret = 0;
		untyped __cpp__("{
			PCRE2_SPTR hxc_s = {2} > 0 ? (PCRE2_SPTR){1}->b->GetBase() : hxc_pcre2_empty;
			pcre2_match_data *hxc_md = pcre2_match_data_create_from_pattern((pcre2_code*){0}, NULL);
			int hxc_r = pcre2_match((pcre2_code*){0}, hxc_s, (PCRE2_SIZE){2}, (PCRE2_SIZE){3}, (uint32_t){4}, hxc_md, NULL);
			{5} = hxc_r;
			if (hxc_r >= 0) {
				PCRE2_SIZE *hxc_ov = pcre2_get_ovector_pointer(hxc_md);
				int hxc_k = hxc_r == 0 ? {7} : hxc_r;
				for (int hxc_i = 0; hxc_i < hxc_k * 2; hxc_i++)
					{6}[hxc_i] = hxc_ov[hxc_i] == PCRE2_UNSET ? -1 : (int)hxc_ov[hxc_i];
			}
			pcre2_match_data_free(hxc_md);
		}", code, subj, len, pos, options, ret, out, pairs);
		if (ret < 0) throw matchError(ret);
		// The pairs past the last one the match set are -1.
		var set = ret == 0 ? pairs : ret;
		for (i in 0...pairs * 2) ovector[i] = i < set * 2 ? out[i] : -1;
	}

	// A failed match's code as its exception.
	static function matchError(ret:Int):Dynamic {
		return switch (ret) {
			case -1: new Pcre2NotFound(); // PCRE2_ERROR_NOMATCH
			case -2: new Pcre2Exception(Partial); // PCRE2_ERROR_PARTIAL
			case -47: new Pcre2Exception(MatchLimit); // PCRE2_ERROR_MATCHLIMIT
			case -36: new Pcre2Exception(BadUTFOffset); // PCRE2_ERROR_BADUTFOFFSET
			case -53: new Pcre2Exception(DepthLimit); // PCRE2_ERROR_DEPTHLIMIT
			case -43: new Pcre2Exception(WorkspaceSize); // PCRE2_ERROR_DFA_WSSIZE
			case r if (r >= -23 && r <= -3): new Pcre2Exception(BadUTF); // PCRE2_ERROR_UTF8_ERR21 (-23) .. ERR1 (-3)
			case r: new Pcre2Exception(InternalError("pcre2_match_stub: unhandled PCRE2 error code: " + r));
		};
	}


	// Capturecount + 1 pairs, and the third the C side works in.
	public function makeOvector():Array<Int> {
		var subgroups1 = captureCount + 1;
		return [for (_ in 0...subgroups1 * 3) 0];
	}

	public function exec(iflags:Int, pos:Int, subj:haxe.io.Bytes):Pcre2Substrings {
		var ov = makeOvector();
		match(iflags, pos, subj, ov);
		return new Pcre2Substrings(subj, ov);
	}

	// Every match from `pos`, an empty match retried with NOTEMPTY.
	public function execAll(iflags:Int, pos:Int, subj:haxe.io.Bytes):Array<Pcre2Substrings> {
		var first = exec(iflags, pos, subj);
		var nullFlags = iflags | (NOTEMPTY : Int);
		var subjLen = subj.length;
		var out = [first];
		var cur = first;
		var p = first.ovector[1];
		while (true) {
			var next:Null<Pcre2Substrings> = try {
				if (cur.ovector[0] == p && cur.ovector[1] == p) {
					if (p == subjLen) null else exec(nullFlags, p, subj);
				} else exec(iflags, p, subj);
			} catch (_:Pcre2NotFound) null;
			if (next == null) break;
			out.push(next);
			cur = next;
			p = next.ovector[1];
		}
		return out;
	}

	// The replacement template: `$n` a group, `$$` a dollar, `$&` the match,
	// `` $` `` and `$'` what precedes and follows it, `$+` the last group that took part, `$!` a
	// separator that stands for nothing, `$` before anything else dropped, a final `$` kept.
	static function subst(str:haxe.io.Bytes):{maxBr:Int, withLp:Bool, lst:Array<Pcre2SubstItem>} {
		var maxBr = 0;
		var withLp = false;
		var lst:Array<Pcre2SubstItem> = [];
		var lix = str.length - 1;
		var n = 0;
		while (lix >= n) {
			var i = n;
			while (i <= lix && str.get(i) != "$".code) i++;
			if (i > lix) {
				lst.push(SubstString(n, lix - n + 1));
				break;
			}
			if (i == lix) {
				lst.push(SubstString(n, lix - n + 1));
				break;
			}
			var i1 = i + 1;
			if (n != i) lst.push(SubstString(n, i - n));
			var c = str.get(i1);
			if (c >= "0".code && c <= "9".code) {
				var nr = c - "0".code;
				var j = i1 + 1;
				while (j <= lix && str.get(j) >= "0".code && str.get(j) <= "9".code) {
					nr = 10 * nr + str.get(j) - "0".code;
					j++;
				}
				if (nr > maxBr) maxBr = nr;
				lst.push(Backref(nr));
				if (j > lix) break;
				n = j;
			} else if (c == "!".code) {
				n = i1 + 1;
			} else if (c == "$".code) {
				lst.push(SubstString(i1, 1));
				n = i1 + 1;
			} else if (c == "&".code) {
				lst.push(Match);
				n = i1 + 1;
			} else if (c == "`".code) {
				lst.push(PreMatch);
				n = i1 + 1;
			} else if (c == "'".code) {
				lst.push(PostMatch);
				n = i1 + 1;
			} else if (c == "+".code) {
				withLp = true;
				lst.push(LastParenMatch);
				n = i1 + 1;
			} else {
				n = i1;
			}
		}
		return {maxBr: maxBr, withLp: withLp, lst: lst};
	}

	// Argv[0], the program's name exactly as the command line gave it (the host's resolved programPath
	// differs whenever it was started through a relative or slash-flipped path).
	static function programName():haxe.io.Bytes {
		var len = -1;
		untyped __cpp__("if (_hxcpp_argc > 0) {0} = (int)strlen(_hxcpp_argv[0])", len);
		if (len < 0) return haxe.io.Bytes.ofString(Sys.programPath());
		var b = haxe.io.Bytes.alloc(len);
		for (i in 0...len) b.set(i, untyped __cpp__("(int)(unsigned char)_hxcpp_argv[0][{0}]", i));
		return b;
	}

	static function calcTransLst(subgroups2:Int, ov:Array<Int>, subj:haxe.io.Bytes, templ:haxe.io.Bytes,
			lst:Array<Pcre2SubstItem>, out:haxe.io.BytesBuffer):Void {
		var prefixLen = ov[0];
		var last = ov[1];
		function add(src:haxe.io.Bytes, ix:Int, len:Int) if (len > 0) out.addBytes(src, ix, len);
		for (item in lst) switch (item) {
			case SubstString(ix, len): add(templ, ix, len);
			case Backref(0):
				var prog = programName();
				add(prog, 0, prog.length);
			case Backref(k):
				var start = ov[k * 2];
				add(subj, start, ov[k * 2 + 1] - start);
			case Match: add(subj, prefixLen, last - prefixLen);
			case PreMatch: add(subj, 0, prefixLen);
			case PostMatch: add(subj, last, subj.length - last);
			case LastParenMatch:
				var pos = subgroups2 - 2;
				var ix = ov[pos];
				while (ix < 0) {
					pos -= 2;
					ix = ov[pos];
				}
				add(subj, ix, ov[pos + 1] - ix);
		}
	}

	// Replaces every match, building the result front to back.
	public function replace(iflags:Int, templ:haxe.io.Bytes, subj:haxe.io.Bytes):haxe.io.Bytes {
		var t = subst(templ);
		var subjLen = subj.length;
		var ov = makeOvector();
		var subgroups2 = (captureCount + 1) * 2;
		var nsubs = (subgroups2 >> 1) - 1;
		if (t.maxBr > nsubs) throw new EvalExceptions.HostException("Pcre2.replace: backreference denotes nonexistent subpattern", true);
		if (t.withLp && nsubs == 0) throw new EvalExceptions.HostException("Pcre2.replace: no backreferences", true);
		var out = new haxe.io.BytesBuffer();
		var curPos = 0;
		while (true) {
			var none = curPos > subjLen || (try { match(iflags, curPos, subj, ov); false; } catch (_:Pcre2NotFound) true);
			if (none) {
				var postfix = subjLen - curPos;
				if (postfix > 0) out.addBytes(subj, curPos, postfix);
				return out.getBytes();
			}
			var first = ov[0];
			var len = first - curPos;
			if (len > 0) out.addBytes(subj, curPos, len);
			calcTransLst(subgroups2, ov, subj, templ, t.lst, out);
			var next = first + 1;
			var last = ov[1];
			if (last < next) {
				if (first < subjLen) out.addBytes(subj, curPos + len, 1);
				curPos = next;
			} else curPos = last;
		}
	}

	public function replaceFirst(iflags:Int, templ:haxe.io.Bytes, subj:haxe.io.Bytes):haxe.io.Bytes {
		var t = subst(templ);
		var ov = makeOvector();
		var subgroups2 = (captureCount + 1) * 2;
		var nsubs = (subgroups2 >> 1) - 1;
		if (t.maxBr > nsubs) throw new EvalExceptions.HostException("Pcre2.replace_first: backreference denotes nonexistent subpattern", true);
		if (t.withLp && nsubs == 0) throw new EvalExceptions.HostException("Pcre2.replace_first: no backreferences", true);
		try match(iflags, 0, subj, ov) catch (_:Pcre2NotFound) return subj;
		var first = ov[0];
		var last = ov[1];
		var out = new haxe.io.BytesBuffer();
		out.addBytes(subj, 0, first);
		calcTransLst(subgroups2, ov, subj, templ, t.lst, out);
		out.addBytes(subj, last, subj.length - last);
		return out.getBytes();
	}
}

enum Pcre2SubstItem {
	SubstString(ix:Int, len:Int);
	Backref(n:Int);
	Match;
	PreMatch;
	PostMatch;
	LastParenMatch;
}

// A subject and its offset vector.
class Pcre2Substrings {
	public final subj:haxe.io.Bytes;
	public final ovector:Array<Int>;

	public function new(subj:haxe.io.Bytes, ovector:Array<Int>) {
		this.subj = subj;
		this.ovector = ovector;
	}

	public function numOfSubs():Int return Std.int(ovector.length / 3);

	// Pcre2NotFound for a group that did not take part.
	public function getSubstringOfs(n:Int):{first:Int, last:Int} {
		if (n < 0 || n >= numOfSubs()) throw new EvalExceptions.HostException("Invalid_argument(\"Pcre2.get_offset_start: illegal offset\")", false);
		var start = ovector[n * 2];
		if (start < 0) throw new Pcre2NotFound();
		return {first: start, last: ovector[n * 2 + 1]};
	}
}
