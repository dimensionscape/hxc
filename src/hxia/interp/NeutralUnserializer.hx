package hxia.interp;

import hxia.interp.Interp.ScriptObject;
import hxia.interp.Interp.EnumValue;
import hxia.interp.Interp.ScriptClass;
import hxia.interp.Interp.ScriptEnum;
import hxia.interp.NeutralBytes;

// The reverse of NeutralSerializer. Overrides unserialize() to reconstruct the four script
// value shapes from their descriptors (script classes/enums are not host types, so the parent's
// resolver + Type.createEmptyInstance/createEnum cannot build them). unserialize() recurses
// virtually, so nested script values inside host arrays/maps/objects are handled here too; the
// script codes (c/w/j/A/B) fall back to the host path when the name is not a script type, and
// every other code defers to super.
@:access(haxe.Unserializer)
@:access(hxia.interp.Interp)
class NeutralUnserializer extends haxe.Unserializer {
	final interp:Interp;

	public function new(s:String, interp:Interp) {
		super(s);
		this.interp = interp;
	}

	inline function scriptClass(name:String):ScriptClass
		return interp.scriptClasses.get(name);

	inline function scriptEnum(name:String):ScriptEnum
		return interp.scriptEnums.get(name);

	override public function unserialize():Dynamic {
		switch (get(pos)) {
			case "c".code: // Class instance
				pos++;
				var name:String = unserialize();
				var sc = scriptClass(name);
				if (sc == null)
					return unserializeHostClass(name);
				var o = new ScriptObject(sc);
				cache.push(o);
				while (get(pos) != "g".code) {
					var field:String = unserialize();
					o.fields.set(field, unserialize());
				}
				pos++; // Consume 'g'
				return o;
			case "w".code: // Enum by constructor name
				pos++;
				var name:String = unserialize();
				var se = scriptEnum(name);
				if (se == null)
					return unserializeHostEnum(name, false);
				var ctor:String = unserialize();
				var e = interp.mkEnum(name, se.indexOf(ctor), ctor, readEnumParams());
				cache.push(e);
				return e;
			case "j".code: // Enum by index
				pos++;
				var name:String = unserialize();
				var se = scriptEnum(name);
				if (se == null)
					return unserializeHostEnum(name, true);
				pos++; // Consume ':'
				var index = readDigits();
				var e = interp.mkEnum(name, index, se.ctorNames[index], readEnumParams());
				cache.push(e);
				return e;
			case "A".code: // Class value
				pos++;
				var name:String = unserialize();
				return interp.scriptClasses.exists(name) ? (scriptClass(name) : Dynamic) : resolver.resolveClass(name);
			case "B".code: // Enum type value
				pos++;
				var name:String = unserialize();
				return interp.scriptEnums.exists(name) ? (scriptEnum(name) : Dynamic) : resolver.resolveEnum(name);
			case "s".code: // Host Bytes -> the interpreter's Bytes shim
				return NeutralBytes.fromHost(super.unserialize());
			case "l".code:
				// Build the List through the registry constructor the script's `new List()` uses,
				// so its Class matches the script's `is List` (the host Unserializer's internal List
				// is a distinct Class object across the neutral-static boundary on the interpreter).
				pos++;
				var l:haxe.ds.List<Dynamic> = interp.registry.construct("List", []);
				cache.push(l);
				while (get(pos) != "h".code)
					l.add(unserialize());
				pos++; // Consume 'h'
				return l;
			case _:
				return super.unserialize();
		}
	}

	// Read `:<argc>` then argc serialized params (shared by the w/j script-enum branches).
	function readEnumParams():Array<Dynamic> {
		pos++; // Consume ':'
		var argc = readDigits();
		return [for (_ in 0...argc) unserialize()];
	}

	// A host class instance whose name is not a script type: reconstruct via the resolver.
	function unserializeHostClass(name:String):Dynamic {
		var cl = resolver.resolveClass(name);
		if (cl == null)
			throw "Class not found " + name;
		var o = Type.createEmptyInstance(cl);
		cache.push(o);
		while (get(pos) != "g".code) {
			var field:String = unserialize();
			Reflect.setField(o, field, unserialize());
		}
		pos++;
		return o;
	}

	function unserializeHostEnum(name:String, byIndex:Bool):Dynamic {
		var edecl = resolver.resolveEnum(name);
		if (edecl == null)
			throw "Enum not found " + name;
		var tag:String;
		if (byIndex) {
			pos++; // Consume ':'
			tag = Type.getEnumConstructs(edecl)[readDigits()];
		} else {
			tag = unserialize();
		}
		pos++; // Consume ':'
		var argc = readDigits();
		var params = [for (_ in 0...argc) unserialize()];
		var e = Type.createEnum(edecl, tag, params);
		cache.push(e);
		return e;
	}

	public static function run(s:String, interp:Interp):Dynamic {
		var u = new NeutralUnserializer(s, interp);
		return u.unserialize();
	}
}
