package hxc.context;


import hxc.core.Json;
import hxc.data.Metas;

class MetaRegistry {
	static var metaCache:Null<Array<Array<JsonField>>> = null;
	static var defineCache:Null<Array<Array<JsonField>>> = null;

	static function toFields(list:Array<RegistryEntry>, tagKey:String):Array<Array<JsonField>> {
		return [for (e in list) {
			var fields:Array<JsonField> = [
				{name: "name", value: JString(e.name)},
				{name: tagKey, value: JString(e.tag)},
				{name: "doc", value: JString(e.doc)}
			];
			for (p in e.props)
				fields.push(switch (p) {
					case Params(a): {name: "params", value: strings(a)};
					case Platforms(a): {name: "platforms", value: strings(a)};
					case Targets(a): {name: "targets", value: strings(a)};
					case Links(a): {name: "links", value: strings(a)};
					case Internal: {name: "internal", value: JBool(true)};
					case Reserved: {name: "reserved", value: JBool(true)};
					case Deprecated(reason): {name: "deprecated", value: JString(reason)};
				});
			fields;
		}];
	}

	static function strings(a:Array<String>):JsonValue {
		return JArray([for (s in a) JString(s)]);
	}

	public static function metas():Array<Array<JsonField>> {
		if (metaCache == null) metaCache = toFields(hxc.data.Metas.all(), "metadata");
		return metaCache;
	}

	public static function defines():Array<Array<JsonField>> {
		if (defineCache == null) defineCache = toFields(hxc.data.Defines.all(), "define");
		return defineCache;
	}

	public static function field(fields:Array<JsonField>, name:String):Null<JsonValue> {
		for (f in fields) if (f.name == name) return f.value;
		return null;
	}

	public static function stringField(fields:Array<JsonField>, name:String, def:String):String {
		return switch (field(fields, name)) {
			case JString(s): s;
			case _: def;
		};
	}

	public static function boolField(fields:Array<JsonField>, name:String):Bool {
		return switch (field(fields, name)) {
			case JBool(b): b;
			case _: false;
		};
	}

	public static function arrayField(fields:Array<JsonField>, name:String):Array<JsonValue> {
		return switch (field(fields, name)) {
			case JArray(a): a;
			case _: [];
		};
	}
}
