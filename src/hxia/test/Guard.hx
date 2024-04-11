package hxia.test;

import hxia.harness.Reporter;
import hxia.harness.Serializer;

// The conformance assertion API. Cases call these instead of printing; the reporter
// serializes each into the line protocol.
//
// The active case id is set by the runner around each case body so cases do not
// repeat it on every call.
class Guard {
	static var caseId:String = "?";

	public static function setCase(id:String):Void
		caseId = id;

	// Must match the derived portable expectation on every tier.
	public static function portable(v:Dynamic, tag:String):Void
		Reporter.event("portable", caseId, tag, Serializer.value(v));

	// Must hold everywhere; any false is a failure independent of the store.
	public static function invariant(cond:Bool, tag:String):Void
		Reporter.event("invariant", caseId, tag, cond ? "true" : "false");

	// Archived per case x target, never diffed; tag must carry a #dv- catalog ref.
	public static function hostDefined(v:Dynamic, tag:String):Void {
		if (tag.indexOf("#dv-") < 0)
			throw "Guard.hostDefined: tag '" + tag + "' needs a #dv-<catalog-id> suffix";
		Reporter.event("hostdefined", caseId, tag, Serializer.value(v));
	}

	// Must fail with a named boundary error; records the caught type name (message
	// excluded, messages vary). `no-throw` value is the boundary-leak failure.
	public static function excluded(f:() -> Void, tag:String):Void {
		var caught:String = "no-throw";
		try {
			f();
		} catch (e:Dynamic) {
			caught = errorType(e);
		}
		Reporter.event("excluded", caseId, tag, caught);
	}

	static function errorType(e:Dynamic):String {
		if (Std.isOfType(e, haxe.Exception))
			return Type.getClassName(Type.getClass((e : haxe.Exception)));
		var c = Type.getClass(e);
		return c == null ? "Dynamic" : Type.getClassName(c);
	}
}
