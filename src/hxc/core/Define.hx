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
}
