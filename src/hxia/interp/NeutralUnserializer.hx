package hxia.interp;

import hxia.ScriptWorld;
import hxia.interp.NeutralBytes;
import hxia.interp.NeutralList;

// The reverse of NeutralSerializer. Overrides unserialize() to reconstruct the script value
// shapes through the tier-neutral ScriptWorld (script classes/enums are not host types, so the
// parent's resolver + Type.createEmptyInstance/createEnum cannot build them). unserialize()
// recurses virtually, so nested script values inside host arrays/maps/objects are handled here
// too; the script codes (c/w/j/A/B) fall back to the host path when the name is not a script
// type, and every other code defers to super.
@:access(haxe.Unserializer)
class NeutralUnserializer extends haxe.Unserializer {
	final world:ScriptWorld;

	public function new(s:String, world:ScriptWorld) {
		super(s);
		this.world = world;
	}

	override public function unserialize():Dynamic {
		switch (get(pos)) {
			case "c".code: // Class instance
				pos++;
				var name:String = unserialize();
				if (!world.hasClass(name))
					return unserializeHostClass(name);
				var o = world.createEmpty(name);
				cache.push(o);
				while (get(pos) != "g".code) {
					var field:String = unserialize();
					world.setInstanceField(o, field, unserialize());
				}
				pos++; // Consume 'g'
				return o;
			case "w".code: // Enum by constructor name
				pos++;
				var name:String = unserialize();
				if (!world.hasEnum(name))
					return unserializeHostEnum(name, false);
				var ctor:String = unserialize();
				var e = world.newEnum(name, world.ctorIndexOf(name, ctor), ctor, readEnumParams());
				cache.push(e);
				return e;
			case "j".code: // Enum by index
				pos++;
				var name:String = unserialize();
				if (!world.hasEnum(name))
					return unserializeHostEnum(name, true);
				pos++; // Consume ':'
				var index = readDigits();
				var e = world.newEnum(name, index, world.ctorNameOf(name, index), readEnumParams());
				cache.push(e);
				return e;
			case "A".code: // Class value
				pos++;
				var name:String = unserialize();
				return world.hasClass(name) ? world.classToken(name) : resolver.resolveClass(name);
			case "B".code: // Enum type value
				pos++;
				var name:String = unserialize();
				return world.hasEnum(name) ? world.enumToken(name) : resolver.resolveEnum(name);
			case "s".code: // Host Bytes -> the Bytes shim
				return NeutralBytes.fromHost(super.unserialize());
			case "l".code:
				// Build the List through the shim the script's `new List()` uses, so its Class matches
				// the script's `is List` across the neutral-static boundary.
				pos++;
				var l = new NeutralList();
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

	public static function run(s:String, world:ScriptWorld):Dynamic {
		var u = new NeutralUnserializer(s, world);
		return u.unserialize();
	}
}
