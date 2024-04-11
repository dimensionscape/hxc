package hxia.harness;

// The line-protocol reporter. One line per guard event, written to stdout, identical
// on every target after transport normalization. Format:
//   kind TAB caseId TAB tag TAB value
// framed by `meta` begin/end sentinels; the end line carries the event count so a
// truncated (crashed) column is detectable.
class Reporter {
	static var events:Int = 0;
	static var started:Bool = false;

	static final ID = ~/^[A-Za-z0-9._-]+$/;

	public static function begin(runId:String):Void {
		if (started)
			return;
		started = true;
		events = 0;
		line("meta", "harness", "begin", runId);
	}

	public static function end():Void {
		line("meta", "harness", "end", Std.string(events));
	}

	public static function event(kind:String, caseId:String, tag:String, value:String):Void {
		checkId(caseId, "caseId");
		checkId(tagName(tag), "tag");
		events++;
		line(kind, caseId, tag, value);
	}

	// Tags may carry a `#dv-<id>` catalog suffix on hostDefined events; validate the
	// name part only.
	static function tagName(tag:String):String {
		var h = tag.indexOf("#");
		return h < 0 ? tag : tag.substr(0, h);
	}

	static function checkId(s:String, what:String):Void {
		if (!ID.match(s))
			throw "Reporter: illegal " + what + " '" + s + "' (must match [A-Za-z0-9._-]+)";
	}

	// Meta lines are excluded from expectation diffs; event lines never carry timestamps/paths/pids
	// (enforced by the orchestrator lint).
	static function line(a:String, b:String, c:String, d:String):Void {
		Io.write(a + "\t" + b + "\t" + c + "\t" + d + "\n");
	}
}
