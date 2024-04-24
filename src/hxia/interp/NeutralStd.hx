package hxia.interp;

// Seeds a HostRegistry with the neutral std surface (ABI.md): constructors and the static
// functions scripts reach for. Member calls on host values (Array/String/Map methods) are
// dispatched reflectively by the interpreter, so only constructors and statics need
// explicit bindings here. The `logSink` receives Sys.println / trace output.
class NeutralStd {
	public static function install(reg:HostRegistry, logSink:String->Void):Void {
		// Constructors
		reg.bindNew("Array", function(_) return []);
		reg.bindNew("haxe.ds.StringMap", function(_) return new haxe.ds.StringMap<Dynamic>());
		reg.bindNew("haxe.ds.IntMap", function(_) return new haxe.ds.IntMap<Dynamic>());
		reg.bindNew("haxe.ds.ObjectMap", function(_) return new haxe.ds.ObjectMap<Dynamic, Dynamic>());
		reg.bindNew("StringBuf", function(_) return new NeutralStringBuf());
		reg.bindNew("EReg", function(a) return new EReg(a[0], a[1]));
		reg.bindNew("haxe.io.Bytes", function(a) return haxe.io.Bytes.alloc(a[0]));

		// Map methods bound as typed IMap calls: on some targets (js) the map .set/.get are
		// inlined and DCE'd, so reflective dispatch cannot reach them. Interface dispatch does.
		for (mapType in ["haxe.ds.StringMap", "haxe.ds.IntMap", "haxe.ds.ObjectMap"]) {
			reg.bindMember(mapType, "set", function(o, a) { (o : haxe.Constraints.IMap<Dynamic, Dynamic>).set(a[0], a[1]); return null; });
			reg.bindMember(mapType, "get", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).get(a[0]));
			reg.bindMember(mapType, "exists", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).exists(a[0]));
			reg.bindMember(mapType, "remove", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).remove(a[0]));
			reg.bindMember(mapType, "keys", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).keys());
		}

		// StringBuf's non-inline methods are keyed by the shim's runtime type name (cppia inlines
		// `add` into field ops on `b`/`charBuf`, which the shim exposes directly).
		var sbuf = Type.getClassName(NeutralStringBuf);
		reg.bindMember(sbuf, "flush", function(o, a) { (o : NeutralStringBuf).flush(); return null; });
		reg.bindMember(sbuf, "addChar", function(o, a) { (o : NeutralStringBuf).addChar(a[0]); return null; });
		reg.bindMember(sbuf, "addSub", function(o, a) { (o : NeutralStringBuf).addSub(a[0], a[1], a[2]); return null; });
		reg.bindMember(sbuf, "toString", function(o, a) return (o : NeutralStringBuf).toString());

		// EReg is a native @:coreApi on js/cpp: its methods are not reflectively callable there,
		// so bind the surface as typed calls (they are direct on eval, but binding is uniform).
		reg.bindMember("EReg", "match", function(o, a) return (o : EReg).match(a[0]));
		reg.bindMember("EReg", "matched", function(o, a) return (o : EReg).matched(a[0]));
		reg.bindMember("EReg", "matchedLeft", function(o, a) return (o : EReg).matchedLeft());
		reg.bindMember("EReg", "matchedRight", function(o, a) return (o : EReg).matchedRight());
		reg.bindMember("EReg", "matchedPos", function(o, a) return (o : EReg).matchedPos());
		reg.bindMember("EReg", "replace", function(o, a) return (o : EReg).replace(a[0], a[1]));
		reg.bindMember("EReg", "split", function(o, a) return (o : EReg).split(a[0]));
		reg.bindMember("EReg", "matchSub", function(o, a) return (o : EReg).matchSub(a[0], a[1], a.length > 2 ? a[2] : -1));

		// Statics: the owned sinks + pure compute
		reg.bindStatic("Sys", "println", function(a) { logSink(Std.string(a[0])); return null; });
		reg.bindStatic("Std", "string", function(a) return Std.string(a[0]));
		reg.bindStatic("Std", "isOfType", function(a) return Std.isOfType(a[0], a[1]));
		reg.bindStatic("Std", "int", function(a) return Std.int(a[0]));
		reg.bindStatic("Std", "parseInt", function(a) return Std.parseInt(a[0]));
		reg.bindStatic("Std", "parseFloat", function(a) return Std.parseFloat(a[0]));
		// Int64 abstract-impl statics: cppia keys them by the impl class path. The host Int64 is
		// the same representation (shared heap), so values round-trip through these bindings.
		var i64 = "haxe._Int64.Int64_Impl_";
		reg.bindStatic(i64, "make", function(a) return haxe.Int64.make(a[0], a[1]));
		reg.bindStatic(i64, "ofInt", function(a) return haxe.Int64.ofInt(a[0]));
		reg.bindStatic(i64, "add", function(a) return haxe.Int64.add(a[0], a[1]));
		reg.bindStatic(i64, "sub", function(a) return haxe.Int64.sub(a[0], a[1]));
		reg.bindStatic(i64, "mul", function(a) return haxe.Int64.mul(a[0], a[1]));
		reg.bindStatic(i64, "toStr", function(a) return haxe.Int64.toStr(a[0]));
		reg.bindStatic(i64, "toInt", function(a) return haxe.Int64.toInt(a[0]));

		reg.bindStatic("Math", "abs", function(a) return Math.abs(a[0]));
		reg.bindStatic("Math", "floor", function(a) return Math.floor(a[0]));
		reg.bindStatic("Math", "max", function(a) return Math.max(a[0], a[1]));
		reg.bindStatic("Math", "min", function(a) return Math.min(a[0], a[1]));
	}
}
