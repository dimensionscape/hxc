package hxia.interp;

// Seeds a HostRegistry with the neutral std surface (ABI.md): constructors and the static
// functions scripts reach for. Member calls on host values (Array/String/Map methods) are
// dispatched reflectively by the interpreter, so only constructors and statics need
// explicit bindings here. The `logSink` receives Sys.println / trace output.
class NeutralStd {
	public static function install(reg:HostRegistry, logSink:String->Void):Void {
		// Authority-free std classes: their statics resolve reflectively when not explicitly
		// bound (the explicit bindings above keep priority and stay DCE-safe on every host).
		// Passing the Class handle also pins it through the host's DCE.
		reg.markNeutralStatic("Math", Math);
		reg.markNeutralStatic("Std", Std);
		reg.markNeutralStatic("Lambda", Lambda);
		reg.markNeutralStatic("StringTools", StringTools);
		reg.markNeutralStatic("Reflect", Reflect);
		reg.markNeutralStatic("Type", Type);
		reg.markNeutralStatic("Date", Date);
		reg.markNeutralStatic("Xml", Xml);

		// Constructors
		reg.bindNew("Array", function(_) return []);
		reg.bindNew("haxe.ds.StringMap", function(_) return new haxe.ds.StringMap<Dynamic>());
		reg.bindNew("haxe.ds.IntMap", function(_) return new haxe.ds.IntMap<Dynamic>());
		reg.bindNew("haxe.ds.ObjectMap", function(_) return new haxe.ds.ObjectMap<Dynamic, Dynamic>());
		reg.bindNew("haxe.ds.EnumValueMap", function(_) return new haxe.ds.EnumValueMap<Dynamic, Dynamic>());
		reg.bindNew("StringBuf", function(_) return new NeutralStringBuf());
		reg.bindNew("EReg", function(a) return new EReg(a[0], a[1]));
		reg.bindNew("Date", function(a) return new Date(a[0], a[1], a[2], a[3], a[4], a[5]));
		reg.bindNew("List", function(_) return new List<Dynamic>());
		reg.markNeutralStatic("List", List);

		// Bytes: cpp inlines get/set into buffer indexing on the shim's `b`/`length`, so the
		// factories return the shim and its non-inline methods are keyed by the shim type name.
		reg.bindStatic("haxe.io.Bytes", "alloc", function(a) return NeutralBytes.alloc(a[0]));
		reg.bindStatic("haxe.io.Bytes", "ofString", function(a) return NeutralBytes.ofString(a[0]));
		reg.bindStatic("haxe.io.Bytes", "ofHex", function(a) return NeutralBytes.ofHex(a[0]));
		var bytes = Type.getClassName(NeutralBytes);
		reg.bindMember(bytes, "get", function(o, a) return (o : NeutralBytes).get(a[0]));
		reg.bindMember(bytes, "set", function(o, a) { (o : NeutralBytes).set(a[0], a[1]); return null; });
		reg.bindMember(bytes, "getString", function(o, a) return (o : NeutralBytes).getString(a[0], a[1]));
		reg.bindMember(bytes, "toHex", function(o, a) return (o : NeutralBytes).toHex());
		reg.bindMember(bytes, "toString", function(o, a) return (o : NeutralBytes).toString());
		reg.bindMember(bytes, "blit", function(o, a) { (o : NeutralBytes).blit(a[0], a[1], a[2], a[3]); return null; });
		reg.bindMember(bytes, "fill", function(o, a) { (o : NeutralBytes).fill(a[0], a[1], a[2]); return null; });
		reg.bindMember(bytes, "sub", function(o, a) return (o : NeutralBytes).sub(a[0], a[1]));
		reg.bindMember(bytes, "compare", function(o, a) return (o : NeutralBytes).compare(a[0]));

		// Map methods bound as typed IMap calls: on some targets (js) the map .set/.get are
		// inlined and DCE'd, so reflective dispatch cannot reach them. Interface dispatch does.
		for (mapType in ["haxe.ds.StringMap", "haxe.ds.IntMap", "haxe.ds.ObjectMap", "haxe.ds.EnumValueMap"]) {
			reg.bindMember(mapType, "set", function(o, a) { (o : haxe.Constraints.IMap<Dynamic, Dynamic>).set(a[0], a[1]); return null; });
			reg.bindMember(mapType, "get", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).get(a[0]));
			reg.bindMember(mapType, "exists", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).exists(a[0]));
			reg.bindMember(mapType, "remove", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).remove(a[0]));
			reg.bindMember(mapType, "keys", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).keys());
			reg.bindMember(mapType, "iterator", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).iterator());
			reg.bindMember(mapType, "keyValueIterator", function(o, a) return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).keyValueIterator());
		}

		// Array: several helper methods (remove/contains/insert/...) are inlined or Haxe-defined
		// and not reflectively callable on js, so bind the surface as typed calls (dispatched by
		// the runtime type name "Array"). Functional args are script closures, callable as-is.
		reg.bindMember("Array", "push", function(o, a) return (o : Array<Dynamic>).push(a[0]));
		reg.bindMember("Array", "pop", function(o, a) return (o : Array<Dynamic>).pop());
		reg.bindMember("Array", "shift", function(o, a) return (o : Array<Dynamic>).shift());
		reg.bindMember("Array", "unshift", function(o, a) { (o : Array<Dynamic>).unshift(a[0]); return null; });
		reg.bindMember("Array", "remove", function(o, a) return (o : Array<Dynamic>).remove(a[0]));
		reg.bindMember("Array", "contains", function(o, a) return (o : Array<Dynamic>).contains(a[0]));
		reg.bindMember("Array", "indexOf", function(o, a) return (o : Array<Dynamic>).indexOf(a[0], a.length > 1 ? a[1] : 0));
		reg.bindMember("Array", "lastIndexOf", function(o, a) return (o : Array<Dynamic>).lastIndexOf(a[0], a.length > 1 ? a[1] : (o : Array<Dynamic>).length - 1));
		reg.bindMember("Array", "insert", function(o, a) { (o : Array<Dynamic>).insert(a[0], a[1]); return null; });
		reg.bindMember("Array", "splice", function(o, a) return (o : Array<Dynamic>).splice(a[0], a[1]));
		reg.bindMember("Array", "slice", function(o, a) return (o : Array<Dynamic>).slice(a[0], a.length > 1 ? a[1] : null));
		reg.bindMember("Array", "concat", function(o, a) return (o : Array<Dynamic>).concat(a[0]));
		reg.bindMember("Array", "join", function(o, a) return (o : Array<Dynamic>).join(a[0]));
		reg.bindMember("Array", "reverse", function(o, a) { (o : Array<Dynamic>).reverse(); return null; });
		reg.bindMember("Array", "sort", function(o, a) { (o : Array<Dynamic>).sort(a[0]); return null; });
		reg.bindMember("Array", "copy", function(o, a) return (o : Array<Dynamic>).copy());
		reg.bindMember("Array", "map", function(o, a) return (o : Array<Dynamic>).map(a[0]));
		reg.bindMember("Array", "filter", function(o, a) return (o : Array<Dynamic>).filter(a[0]));
		reg.bindMember("Array", "iterator", function(o, a) return (o : Array<Dynamic>).iterator());
		reg.bindMember("Array", "keyValueIterator", function(o, a) return (o : Array<Dynamic>).keyValueIterator());
		reg.bindMember("Array", "resize", function(o, a) { (o : Array<Dynamic>).resize(a[0]); return null; });

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
		reg.bindStatic("Sys", "print", function(a) { logSink(Std.string(a[0])); return null; });
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
		reg.bindStatic(i64, "toString", function(a) return haxe.Int64.toStr(a[0]));
		reg.bindStatic(i64, "toInt", function(a) return haxe.Int64.toInt(a[0]));

		reg.bindStatic("Math", "abs", function(a) return Math.abs(a[0]));
		reg.bindStatic("Math", "floor", function(a) return Math.floor(a[0]));
		reg.bindStatic("Math", "ceil", function(a) return Math.ceil(a[0]));
		reg.bindStatic("Math", "round", function(a) return Math.round(a[0]));
		reg.bindStatic("Math", "fceil", function(a) return Math.fceil(a[0]));
		reg.bindStatic("Math", "ffloor", function(a) return Math.ffloor(a[0]));
		reg.bindStatic("Math", "fround", function(a) return Math.fround(a[0]));
		reg.bindStatic("Math", "max", function(a) return Math.max(a[0], a[1]));
		reg.bindStatic("Math", "min", function(a) return Math.min(a[0], a[1]));
		reg.bindStatic("Math", "sqrt", function(a) return Math.sqrt(a[0]));
		reg.bindStatic("Math", "pow", function(a) return Math.pow(a[0], a[1]));
		reg.bindStatic("Math", "sin", function(a) return Math.sin(a[0]));
		reg.bindStatic("Math", "cos", function(a) return Math.cos(a[0]));
		reg.bindStatic("Math", "tan", function(a) return Math.tan(a[0]));
		reg.bindStatic("Math", "asin", function(a) return Math.asin(a[0]));
		reg.bindStatic("Math", "acos", function(a) return Math.acos(a[0]));
		reg.bindStatic("Math", "atan", function(a) return Math.atan(a[0]));
		reg.bindStatic("Math", "atan2", function(a) return Math.atan2(a[0], a[1]));
		reg.bindStatic("Math", "exp", function(a) return Math.exp(a[0]));
		reg.bindStatic("Math", "log", function(a) return Math.log(a[0]));
		reg.bindStatic("Math", "isNaN", function(a) return Math.isNaN(a[0]));
		reg.bindStatic("Math", "isFinite", function(a) return Math.isFinite(a[0]));
	}
}
