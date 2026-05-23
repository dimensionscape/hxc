package hxc.eval;

import hxc.eval.EvalString.ByteString;
import hxc.eval.Pcre2;

/**
	The compiled pattern, its `~/pattern/options` text, the g flag, and the subject and match groups
	the last successful match left behind.
**/
class EvalRegex {
	public final r:Pcre2;
	public final rexString:ByteString;
	public final global:Bool;
	public var rString:ByteString;
	public var rGroups:Array<Pcre2Substrings>;

	public function new(r:Pcre2, rexString:ByteString, global:Bool) {
		this.r = r;
		this.rexString = rexString;
		this.global = global;
		rString = ByteString.empty;
		rGroups = [];
	}
}
