package hxia.interp;

import hxia.ScriptWorld;
import hxia.interp.NeutralBytes;
import hxia.interp.NeutralList;

// A script-aware Serializer. The host haxe.Serializer dispatches on Type.typeof and reads
// fields with Reflect, which cannot see script-defined types. This subclass intercepts the four
// script value shapes THROUGH the tier-neutral ScriptWorld interface and writes them in the
// standard serialization format, delegating every host value to the battle-tested parent. The
// same code serves the T3 interpreter and the T1 js lowerer; only the world differs.
@:access(haxe.Serializer)
class NeutralSerializer extends haxe.Serializer {
	final world:ScriptWorld;

	public function new(world:ScriptWorld) {
		super();
		this.world = world;
	}

	override public function serialize(v:Dynamic):Void {
		if (world.isInstance(v)) {
			if (useCache && serializeRef(v))
				return;
			buf.add("c");
			serializeString(world.instanceClassName(v));
			if (useCache)
				cache.push(v);
			for (fname in world.instanceFieldNames(v)) {
				serializeString(fname);
				serialize(world.getInstanceField(v, fname));
			}
			buf.add("g");
		} else if (world.isEnumVal(v)) {
			if (useCache) {
				if (serializeRef(v))
					return;
				cache.pop();
			}
			buf.add(useEnumIndex ? "j" : "w");
			serializeString(world.enumTypeName(v));
			if (useEnumIndex) {
				buf.add(":");
				buf.add(world.enumIndex(v));
			} else {
				serializeString(world.enumCtor(v));
			}
			var params = world.enumParams(v);
			buf.add(":");
			buf.add(params.length);
			for (p in params)
				serialize(p);
		} else if (Std.isOfType(v, NeutralBytes)) {
			// The Bytes shim serializes as a real host Bytes ("s" base64), so the output matches the
			// standard format and round-trips back to a NeutralBytes.
			super.serialize((v : NeutralBytes).toHost());
		} else if (Std.isOfType(v, NeutralList)) {
			// The List shim serializes in the standard "l" list format.
			if (useCache && serializeRef(v))
				return;
			buf.add("l");
			var node = (v : NeutralList).h;
			while (node != null) {
				serialize(node.item);
				node = node.next;
			}
			buf.add("h");
		} else if (world.isClassToken(v)) {
			buf.add("A");
			serializeString(world.tokenName(v));
		} else if (world.isEnumToken(v)) {
			buf.add("B");
			serializeString(world.tokenName(v));
		} else {
			super.serialize(v);
		}
	}

	public static function run(v:Dynamic, world:ScriptWorld):String {
		var s = new NeutralSerializer(world);
		s.serialize(v);
		return s.toString();
	}

	// Wire the script-aware serialization pair into a registry against the given world - shared by
	// every tier (the interpreter's installSerialization and the T1 runner both call this).
	public static function install(reg:HostRegistry, world:ScriptWorld):Void {
		reg.bindStatic("haxe.Serializer", "run", function(a) return run(a[0], world));
		reg.bindNew("haxe.Serializer", function(_) return new NeutralSerializer(world));
		reg.bindStatic("haxe.Unserializer", "run", function(a) return NeutralUnserializer.run(a[0], world));
		reg.bindNew("haxe.Unserializer", function(a) return new NeutralUnserializer(a[0], world));
		// USE_ENUM_INDEX / USE_CACHE static reads/writes still resolve to the host class.
		reg.markNeutralStatic("haxe.Serializer", haxe.Serializer);
		reg.markNeutralStatic("haxe.Unserializer", haxe.Unserializer);
	}
}
