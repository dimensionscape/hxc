package hxia.interp;

import hxia.interp.Interp.ScriptObject;
import hxia.interp.Interp.EnumValue;
import hxia.interp.Interp.ScriptClass;
import hxia.interp.Interp.ScriptEnum;
import hxia.interp.NeutralBytes;

// A script-aware Serializer. The host haxe.Serializer dispatches on Type.typeof and reads
// fields with Reflect, which cannot see script-defined types (a ScriptObject would serialize
// as hxia.interp.ScriptObject). This subclass intercepts the four script value shapes and
// writes them in the standard serialization format using their descriptors, delegating every
// host value to the battle-tested parent. It is paired with NeutralUnserializer; the two only
// need to round-trip (the corpus compares unserialized values, not the serialized bytes).
@:access(haxe.Serializer)
class NeutralSerializer extends haxe.Serializer {
	public function new() super();

	override public function serialize(v:Dynamic):Void {
		if (Std.isOfType(v, ScriptObject)) {
			var so:ScriptObject = v;
			if (useCache && serializeRef(v))
				return;
			buf.add("c");
			serializeString(so.cls.name);
			if (useCache)
				cache.push(v);
			for (fname in so.fields.keys()) {
				serializeString(fname);
				serialize(so.fields.get(fname));
			}
			buf.add("g");
		} else if (Std.isOfType(v, EnumValue)) {
			var ev:EnumValue = v;
			if (useCache) {
				if (serializeRef(v))
					return;
				cache.pop();
			}
			buf.add(useEnumIndex ? "j" : "w");
			serializeString(ev.enumType);
			if (useEnumIndex) {
				buf.add(":");
				buf.add(ev.index);
			} else {
				serializeString(ev.name);
			}
			buf.add(":");
			buf.add(ev.params.length);
			for (p in ev.params)
				serialize(p);
		} else if (Std.isOfType(v, NeutralBytes)) {
			// The interpreter's Bytes shim serializes as a real host Bytes ("s" base64), so the
			// output matches the standard format and round-trips back to a NeutralBytes.
			super.serialize((v : NeutralBytes).toHost());
		} else if (Std.isOfType(v, ScriptClass)) {
			buf.add("A");
			serializeString((v : ScriptClass).name);
		} else if (Std.isOfType(v, ScriptEnum)) {
			buf.add("B");
			serializeString((v : ScriptEnum).name);
		} else {
			super.serialize(v);
		}
	}

	public static function run(v:Dynamic):String {
		var s = new NeutralSerializer();
		s.serialize(v);
		return s.toString();
	}
}
