package hxc.core;

import hxc.core.NotFound;

class Define {
	public var values:Map<String, String>;
	public var definesSignature:Null<String>;

	public function new(?values:Map<String, String>) {
		this.values = values == null ? new Map() : values;
		this.definesSignature = null;
	}

	public inline function rawDefined(k:String):Bool {
		return values.exists(k);
	}

	public function rawDefinedValue(k:String):String {
		if (!values.exists(k))
			throw new NotFound();
		return values.get(k);
	}

	public function rawDefinedValueSafe(k:String, ?def:String):String {
		return values.exists(k) ? values.get(k) : (def == null ? "" : def);
	}

	public function rawDefineValue(k:String, v:String):Void {
		values.set(k, v);
		definesSignature = null;
	}

	public inline function rawDefine(k:String):Void {
		rawDefineValue(k, "1");
	}

	// Defines for a macro context: the host defines minus target-platform names and no_traces, plus macro
	// and the macro platform name. Flash version defines are not handled (no flash backend).
	public static function adaptToMacroContext(src:Define):Define {
		var toRemove = new Map<String, Bool>();
		for (p in Globals.platforms)
			toRemove.set(Globals.platformName(p), true);
		toRemove.set("no_traces", true);
		var out = new Define();
		for (k => v in src.values)
			if (!toRemove.exists(k))
				out.values.set(k, v);
		out.rawDefine("macro");
		out.rawDefine(Globals.platformName(Globals.macroPlatform));
		return out;
	}
}
