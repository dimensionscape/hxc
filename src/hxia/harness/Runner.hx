package hxia.harness;

import hxia.test.Guard;

// Runs a registered case set sequentially in one process, emitting the framed line
// protocol. A caught exception in a case body becomes a `crash` line and the run
// continues; a hard death truncates the stream and is caught by the missing end
// sentinel. An optional --case <id> argv filter aids debugging.
class Runner {
	public static function run(runId:String, cases:Array<Case>):Void {
		var only:Null<String> = null;
		var args = Io.args();
		var i = 0;
		while (i < args.length) {
			if (args[i] == "--case" && i + 1 < args.length) only = args[i + 1];
			i++;
		}
		Reporter.begin(runId);
		for (c in cases) {
			if (only != null && c.id() != only)
				continue;
			Guard.setCase(c.id());
			try {
				c.run();
			} catch (e:Dynamic) {
				Reporter.event("crash", c.id(), "-", errorType(e));
			}
		}
		Reporter.end();
	}

	static function errorType(e:Dynamic):String {
		if (Std.isOfType(e, haxe.Exception))
			return Type.getClassName(Type.getClass((e : haxe.Exception)));
		var c = Type.getClass(e);
		return c == null ? "Dynamic" : Type.getClassName(c);
	}
}
