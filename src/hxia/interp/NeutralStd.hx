package hxia.interp;

// Seeds a HostRegistry with the neutral std surface (ABI.md): constructors and the static
// functions scripts reach for. Member calls on host values (Array/String/Map methods) are
// dispatched reflectively by the interpreter, so only constructors and statics need
// explicit bindings here. The `logSink` receives Sys.println / trace output.
class NeutralStd {
	// Box a bare Int back into a real haxe.Int64 on the js host (see the Int64 bindings below).
	// On the cpp host an Int64 is a native 64-bit int that the ops handle directly, and an
	// already-boxed value is an object (not `is Int`), so both pass through unchanged.
	static inline function b(x:Dynamic):Dynamic {
		#if js
		return (x != null && Std.isOfType(x, Int)) ? haxe.Int64.ofInt(x) : x;
		#else
		return x;
		#end
	}

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
		reg.markNeutralStatic("haxe.Json", haxe.Json);
		reg.markNeutralStatic("haxe.format.JsonPrinter", haxe.format.JsonPrinter);
		reg.markNeutralStatic("haxe.format.JsonParser", haxe.format.JsonParser);
		reg.markNeutralStatic("haxe.Log", haxe.Log);
		reg.markNeutralStatic("haxe.ds.ArraySort", haxe.ds.ArraySort);
		reg.markNeutralStatic("haxe.xml.Parser", haxe.xml.Parser);
		reg.markNeutralStatic("haxe.NativeStackTrace", haxe.NativeStackTrace);

		// Constructors
		reg.bindNew("Array", function(_) return []);
		reg.bindNew("haxe.ds.StringMap", function(_) return new haxe.ds.StringMap<Dynamic>());
		reg.bindNew("haxe.ds.IntMap", function(_) return new haxe.ds.IntMap<Dynamic>());
		reg.bindNew("haxe.ds.ObjectMap", function(_) return new haxe.ds.ObjectMap<Dynamic, Dynamic>());
		reg.bindNew("haxe.ds.WeakMap", function(_) return new haxe.ds.WeakMap<Dynamic, Dynamic>());
		reg.bindNew("haxe.ds.EnumValueMap", function(_) return new haxe.ds.EnumValueMap<Dynamic, Dynamic>());
		reg.bindNew("StringBuf", function(_) return new NeutralStringBuf());
		reg.bindNew("EReg", function(a) return new EReg(a[0], a[1]));
		reg.bindNew("String", function(a) return a.length > 0 ? Std.string(a[0]) : "");
		reg.bindNew("haxe.Template", function(a) return new haxe.Template(a[0]));
		reg.bindMember("haxe.Template", "execute", function(o, a) return (o : haxe.Template).execute(a[0], a.length > 1 ? a[1] : null));
		reg.bindNew("Date", function(a) return new Date(a[0], a[1], a[2], a[3], a[4], a[5]));
		// Date.now/fromTime/fromString are `inline` on js, so reflecting Date.<name> off the class
		// resolves to native js Date functions that return a number (ms), not a Haxe Date. Bind them
		// so a script's `Date.now()` yields a real host Date the serializer recognizes ("v", not "d").
		reg.bindStatic("Date", "now", function(_) return Date.now());
		reg.bindStatic("Date", "fromTime", function(a) return Date.fromTime(a[0]));
		reg.bindStatic("Date", "fromString", function(a) return Date.fromString(a[0]));
		// Date.toString is `inline` on js and lowers to a Haxe-format builder ("YYYY-MM-DD HH:MM:SS");
		// the mediator's reflective call would otherwise reach native js Date.toString (a locale string).
		reg.bindMember("Date", "toString", function(o, a) {
			var d:Date = o;
			inline function p(n:Int) return n < 10 ? "0" + n : "" + n;
			return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " + p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
		});
		// List is a shim (NeutralList) because `for (x in list)` / `list.iterator()` inline into
		// reads of the private head-node fields; the shim exposes them publicly. Its methods are
		// keyed by the shim's runtime type name, and Lambda.list is rebound to build a shim List.
		var mkList = function(_) return new NeutralList();
		reg.bindNew("List", mkList);
		reg.bindNew("haxe.ds.List", mkList);
		var nlist = Type.getClassName(NeutralList);
		reg.bindMember(nlist, "iterator", function(o, a) return (o : NeutralList).iterator());
		reg.bindMember(nlist, "add", function(o, a) { (o : NeutralList).add(a[0]); return null; });
		reg.bindMember(nlist, "push", function(o, a) { (o : NeutralList).push(a[0]); return null; });
		reg.bindMember(nlist, "pop", function(o, a) return (o : NeutralList).pop());
		reg.bindMember(nlist, "first", function(o, a) return (o : NeutralList).first());
		reg.bindMember(nlist, "last", function(o, a) return (o : NeutralList).last());
		reg.bindMember(nlist, "isEmpty", function(o, a) return (o : NeutralList).isEmpty());
		reg.bindMember(nlist, "clear", function(o, a) { (o : NeutralList).clear(); return null; });
		reg.bindMember(nlist, "remove", function(o, a) return (o : NeutralList).remove(a[0]));
		reg.bindMember(nlist, "toString", function(o, a) return (o : NeutralList).toString());
		reg.bindStatic("Lambda", "list", function(a) {
			var nl = new NeutralList();
			for (x in (a[0] : Iterable<Dynamic>))
				nl.add(x);
			return nl;
		});

		// Bytes: cpp inlines get/set into buffer indexing on the shim's `b`/`length`, so the
		// factories return the shim and its non-inline methods are keyed by the shim type name.
		reg.bindStatic("haxe.io.Bytes", "alloc", function(a) return NeutralBytes.alloc(a[0]));
		reg.bindStatic("haxe.io.Bytes", "ofString", function(a) return NeutralBytes.ofString(a[0]));
		reg.bindStatic("haxe.io.Bytes", "ofHex", function(a) return NeutralBytes.ofHex(a[0]));
		reg.bindStatic("haxe.io.Bytes", "ofData", function(a) return NeutralBytes.ofData(a[0]));
		reg.bindStatic("haxe.io.Bytes", "fastGet", function(a) return (a[0] : Array<Int>)[a[1]] & 0xFF);
		var bytes = Type.getClassName(NeutralBytes);
		reg.bindMember(bytes, "getData", function(o, a) return (o : NeutralBytes).getData());
		reg.bindMember(bytes, "get", function(o, a) return (o : NeutralBytes).get(a[0]));
		reg.bindMember(bytes, "set", function(o, a) { (o : NeutralBytes).set(a[0], a[1]); return null; });
		reg.bindMember(bytes, "getString", function(o, a) return (o : NeutralBytes).getString(a[0], a[1]));
		reg.bindMember(bytes, "toHex", function(o, a) return (o : NeutralBytes).toHex());
		reg.bindMember(bytes, "toString", function(o, a) return (o : NeutralBytes).toString());
		reg.bindMember(bytes, "blit", function(o, a) { (o : NeutralBytes).blit(a[0], a[1], a[2], a[3]); return null; });
		reg.bindMember(bytes, "fill", function(o, a) { (o : NeutralBytes).fill(a[0], a[1], a[2]); return null; });
		reg.bindMember(bytes, "sub", function(o, a) return (o : NeutralBytes).sub(a[0], a[1]));
		reg.bindMember(bytes, "compare", function(o, a) return (o : NeutralBytes).compare(a[0]));

		// BytesInput reads over a host Bytes; construct it from the shim and wrap Bytes it returns.
		reg.bindNew("haxe.io.BytesInput", function(a) return new haxe.io.BytesInput((a[0] : NeutralBytes).toHost(),
			a.length > 1 ? a[1] : 0, a.length > 2 ? a[2] : ((a[0] : NeutralBytes).length - (a.length > 1 ? a[1] : 0))));
		reg.bindMember("haxe.io.BytesInput", "readAll", function(o, a) return NeutralBytes.fromHost((o : haxe.io.BytesInput).readAll()));
		reg.bindMember("haxe.io.BytesInput", "readByte", function(o, a) return (o : haxe.io.BytesInput).readByte());
		reg.bindMember("haxe.io.BytesInput", "readString", function(o, a) return (o : haxe.io.BytesInput).readString(a[0]));
		reg.bindMember("haxe.io.BytesInput", "readLine", function(o, a) return (o : haxe.io.BytesInput).readLine());

		// Crypto over Bytes: convert the shim to/from a host Bytes at the boundary so the real
		// algorithms run unchanged; string-input digests pass through directly.
		// The `complement` (padding) flag defaults to true; the cpp cppia passes an omitted optional as
		// an explicit null, so gate the default on a[1] != null (else null coerces to false on cpp and
		// encode drops the "=" padding / decode rejects it).
		reg.bindStatic("haxe.crypto.Base64", "encode", function(a) return haxe.crypto.Base64.encode((a[0] : NeutralBytes).toHost(), (a.length > 1 && a[1] != null) ? a[1] : true));
		reg.bindStatic("haxe.crypto.Base64", "decode", function(a) return NeutralBytes.fromHost(haxe.crypto.Base64.decode(a[0], (a.length > 1 && a[1] != null) ? a[1] : true)));
		reg.bindStatic("haxe.crypto.Md5", "encode", function(a) return haxe.crypto.Md5.encode(a[0]));
		reg.bindStatic("haxe.crypto.Md5", "make", function(a) return NeutralBytes.fromHost(haxe.crypto.Md5.make((a[0] : NeutralBytes).toHost())));
		reg.bindStatic("haxe.crypto.Sha1", "encode", function(a) return haxe.crypto.Sha1.encode(a[0]));
		reg.bindStatic("haxe.crypto.Sha1", "make", function(a) return NeutralBytes.fromHost(haxe.crypto.Sha1.make((a[0] : NeutralBytes).toHost())));
		reg.bindNew("haxe.crypto.BaseCode", function(a) return new haxe.crypto.BaseCode((a[0] : NeutralBytes).toHost()));
		reg.bindMember("haxe.crypto.BaseCode", "encodeString", function(o, a) return (o : haxe.crypto.BaseCode).encodeString(a[0]));
		reg.bindMember("haxe.crypto.BaseCode", "decodeString", function(o, a) return (o : haxe.crypto.BaseCode).decodeString(a[0]));
		reg.bindMember("haxe.crypto.BaseCode", "encodeBytes", function(o, a) return NeutralBytes.fromHost((o : haxe.crypto.BaseCode).encodeBytes((a[0] : NeutralBytes).toHost())));
		reg.bindMember("haxe.crypto.BaseCode", "decodeBytes", function(o, a) return NeutralBytes.fromHost((o : haxe.crypto.BaseCode).decodeBytes((a[0] : NeutralBytes).toHost())));

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
		// hxcpp lowers Array indexing intrinsics (Bytes.fastGet -> data.__unsafe_get) to these; on
		// the shared heap they are plain get/set on the underlying array.
		reg.bindMember("Array", "__unsafe_get", function(o, a) return (o : Array<Dynamic>)[a[0]]);
		reg.bindMember("Array", "__unsafe_set", function(o, a) { (o : Array<Dynamic>)[a[0]] = a[1]; return a[1]; });
		// Hxcpp sizes an array with __SetSize(Exact) - a large array literal is pre-sized before being
		// filled by index, and haxe.ds.Vector.new sizes its backing array this way (so Vector.length must
		// reflect it). Actually resize, don't no-op, or the length stays 0.
		reg.bindMember("Array", "__SetSizeExact", function(o, a) { (o : Array<Dynamic>).resize(a[0]); return o; });
		reg.bindMember("Array", "__SetSize", function(o, a) { (o : Array<Dynamic>).resize(a[0]); return o; });
		// Haxe's Array.toString is `[a,b,c]`; the native js/cpp Array.toString the mediator would
		// reflect gives the bracket-less `a,b,c`, so bind the Haxe form explicitly.
		reg.bindMember("Array", "toString", function(o, a) return "[" + (o : Array<Dynamic>).join(",") + "]");
		reg.bindMember("Array", "push", function(o, a) return (o : Array<Dynamic>).push(a[0]));
		reg.bindMember("Array", "pop", function(o, a) return (o : Array<Dynamic>).pop());
		reg.bindMember("Array", "shift", function(o, a) return (o : Array<Dynamic>).shift());
		reg.bindMember("Array", "unshift", function(o, a) { (o : Array<Dynamic>).unshift(a[0]); return null; });
		reg.bindMember("Array", "remove", function(o, a) return (o : Array<Dynamic>).remove(a[0]));
		reg.bindMember("Array", "contains", function(o, a) return (o : Array<Dynamic>).contains(a[0]));
		reg.bindMember("Array", "indexOf", function(o, a) return (o : Array<Dynamic>).indexOf(a[0], a.length > 1 ? a[1] : 0));
		reg.bindMember("Array", "lastIndexOf", function(o, a) return (o : Array<Dynamic>).lastIndexOf(a[0], (a.length > 1 && a[1] != null) ? a[1] : (o : Array<Dynamic>).length - 1));
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
		reg.bindMember(sbuf, "get_length", function(o, a) return (o : NeutralStringBuf).get_length());

		// EReg is a native @:coreApi on js/cpp: its methods are not reflectively callable there,
		// so bind the surface as typed calls (they are direct on eval, but binding is uniform).
		reg.bindMember("EReg", "match", function(o, a) return (o : EReg).match(a[0]));
		reg.bindMember("EReg", "matched", function(o, a) return (o : EReg).matched(a[0]));
		reg.bindMember("EReg", "matchedLeft", function(o, a) return (o : EReg).matchedLeft());
		reg.bindMember("EReg", "matchedRight", function(o, a) return (o : EReg).matchedRight());
		reg.bindMember("EReg", "matchedPos", function(o, a) return (o : EReg).matchedPos());
		reg.bindMember("EReg", "replace", function(o, a) return (o : EReg).replace(a[0], a[1]));
		reg.bindMember("EReg", "split", function(o, a) return (o : EReg).split(a[0]));
		// The cpp cppia passes an omitted optional as an explicit null, so a.length is 3 even for the
		// 2-arg matchSub(s, pos) call; guard on a[2] != null to restore the -1 ("to end") default.
		reg.bindMember("EReg", "matchSub", function(o, a) return (o : EReg).matchSub(a[0], a[1], (a.length > 2 && a[2] != null) ? a[2] : -1));

		// `cca` is the charCodeAt alias that StringTools.fastCodeAt lowers to; the cppia inlines it
		// into callers (e.g. haxe.format.JsonParser.nextChar) and it is not reflectively callable on
		// either host. The cppia is cpp-compiled, so its inlined StringTools.isEof tests `c == 0`;
		// cca must therefore return the cpp past-end sentinel 0 on every host (js charCodeAt would
		// yield NaN past-end, which `== 0` never matches, so EOF is missed and parsing throws).
		reg.bindMember("String", "cca", function(o, a) {
			var s:String = o;
			var i:Int = a[0];
			return (i >= 0 && i < s.length) ? StringTools.fastCodeAt(s, i) : 0;
		});
		// Haxe String.charCodeAt returns Null<Int> (null past the ends); native js charCodeAt returns
		// NaN, which the mediator would surface instead, so `"".charCodeAt(0)` must yield null not NaN.
		reg.bindMember("String", "charCodeAt", function(o, a) {
			var s:String = o;
			var i:Int = a[0];
			return (i >= 0 && i < s.length) ? StringTools.fastCodeAt(s, i) : null;
		});
		// Substr: the cpp cppia passes an omitted optional `len` as an explicit null (substr(pos, null)).
		// The cpp host's String.substr reads null len as "to end"; the js host reaches the mediator's
		// reflective call to native js substr, which coerces null->0 and returns "". Route through the
		// Haxe String.substr (HxOverrides on js) so the "to end" case is honoured on every host.
		reg.bindMember("String", "substr", function(o, a) {
			var s:String = o;
			var pos:Int = a[0];
			return (a.length > 1 && a[1] != null) ? s.substr(pos, a[1]) : s.substr(pos);
		});
		// Substring has the same omitted-optional-as-null hazard (substring(start, null)); the Haxe
		// String.substring reads null end as "to end", native js substring coerces null->0.
		reg.bindMember("String", "substring", function(o, a) {
			var s:String = o;
			var start:Int = a[0];
			return (a.length > 1 && a[1] != null) ? s.substring(start, a[1]) : s.substring(start);
		});

		// Statics: the owned sinks + pure compute
		reg.bindStatic("Sys", "println", function(a) { logSink(Std.string(a[0])); return null; });
		reg.bindStatic("Sys", "print", function(a) { logSink(Std.string(a[0])); return null; });
		reg.bindStatic("Sys", "systemName", function(_) return Sys.systemName());
		reg.bindStatic("Sys", "time", function(_) return Sys.time());
		reg.bindStatic("Sys", "getEnv", function(a) return Sys.getEnv(a[0]));
		reg.bindStatic("Std", "string", function(a) return Std.string(a[0]));
		reg.bindStatic("Std", "isOfType", function(a) return Std.isOfType(a[0], a[1]));
		reg.bindStatic("String", "fromCharCode", function(a) return String.fromCharCode(a[0]));
		reg.bindStatic("Std", "int", function(a) return Std.int(a[0]));
		reg.bindStatic("Std", "parseInt", function(a) return Std.parseInt(a[0]));
		reg.bindStatic("Std", "parseFloat", function(a) return Std.parseFloat(a[0]));
		// Int64 abstract-impl statics: cppia keys them by the impl class path. The host Int64 is
		// the same representation (shared heap), so values round-trip through these bindings.
		var i64 = "haxe._Int64.Int64_Impl_";
		// On the cpp target `haxe.Int64`'s underlying is the native `cpp.Int64` (a 64-bit int), so the
		// abstract's `@:from ofInt` cast (e.g. `var a:Int64 = 1`) inlines to a bare native int64 literal
		// with no runtime marker - in the cppia that reaches the interp as a PLAIN Int. On the cpp host
		// that is already a real 64-bit int and the ops below work as-is; on the js host it is a 32-bit
		// number missing the high word, so box it back into a real Int64 before any Int64 op reads
		// .high/.low. b() is identity on non-js and on already-boxed values (objects are not `is Int`).
		reg.bindStatic(i64, "make", function(a) return haxe.Int64.make(a[0], a[1]));
		reg.bindStatic(i64, "ofInt", function(a) return haxe.Int64.ofInt(a[0]));
		reg.bindStatic(i64, "add", function(a) return haxe.Int64.add(b(a[0]), b(a[1])));
		reg.bindStatic(i64, "sub", function(a) return haxe.Int64.sub(b(a[0]), b(a[1])));
		reg.bindStatic(i64, "mul", function(a) return haxe.Int64.mul(b(a[0]), b(a[1])));
		reg.bindStatic(i64, "toStr", function(a) return haxe.Int64.toStr(b(a[0])));
		reg.bindStatic(i64, "toString", function(a) return haxe.Int64.toStr(b(a[0])));
		reg.bindStatic(i64, "toInt", function(a) return haxe.Int64.toInt(b(a[0])));
		reg.bindStatic(i64, "compare", function(a) return haxe.Int64.compare(b(a[0]), b(a[1])));
		reg.bindStatic(i64, "ucompare", function(a) return haxe.Int64.ucompare(b(a[0]), b(a[1])));
		reg.bindStatic(i64, "divMod", function(a) return haxe.Int64.divMod(b(a[0]), b(a[1])));
		reg.bindStatic(i64, "div", function(a) return haxe.Int64.div(b(a[0]), b(a[1])));
		reg.bindStatic(i64, "mod", function(a) return haxe.Int64.mod(b(a[0]), b(a[1])));
		reg.bindStatic(i64, "neg", function(a) return haxe.Int64.neg(b(a[0])));
		reg.bindStatic(i64, "isNeg", function(a) return haxe.Int64.isNeg(b(a[0])));
		reg.bindStatic(i64, "isInt64", function(a) return haxe.Int64.isInt64(a[0]));
		reg.bindStatic(i64, "isZero", function(a) return haxe.Int64.isZero(b(a[0])));
		reg.bindStatic(i64, "parseString", function(a) return haxe.Int64.parseString(a[0]));
		reg.bindStatic(i64, "fromFloat", function(a) return haxe.Int64.fromFloat(a[0]));
		reg.bindStatic(i64, "getHigh", function(a) return haxe.Int64.getHigh(b(a[0])));
		reg.bindStatic(i64, "getLow", function(a) return haxe.Int64.getLow(b(a[0])));
		// High/low property getters (Int64 `var high(get, never)`); the cppia reads them as get_high/low.
		reg.bindStatic(i64, "get_high", function(a) return haxe.Int64.getHigh(b(a[0])));
		reg.bindStatic(i64, "get_low", function(a) return haxe.Int64.getLow(b(a[0])));
		// Comparison / bitwise @:op impls: all `inline`, so reflection cannot reach them; the cppia
		// keys them on the impl class. Bind the (Int64,Int64) and mixed (Int64,Int)/(Int,Int64) forms.
		reg.bindStatic(i64, "eq", function(a) return (b(a[0]) : haxe.Int64) == (b(a[1]) : haxe.Int64));
		reg.bindStatic(i64, "eqInt", function(a) return (b(a[0]) : haxe.Int64) == haxe.Int64.ofInt(a[1]));
		reg.bindStatic(i64, "neq", function(a) return (b(a[0]) : haxe.Int64) != (b(a[1]) : haxe.Int64));
		reg.bindStatic(i64, "neqInt", function(a) return (b(a[0]) : haxe.Int64) != haxe.Int64.ofInt(a[1]));
		reg.bindStatic(i64, "lt", function(a) return haxe.Int64.compare(b(a[0]), b(a[1])) < 0);
		reg.bindStatic(i64, "ltInt", function(a) return haxe.Int64.compare(b(a[0]), haxe.Int64.ofInt(a[1])) < 0);
		reg.bindStatic(i64, "intLt", function(a) return haxe.Int64.compare(haxe.Int64.ofInt(a[0]), b(a[1])) < 0);
		reg.bindStatic(i64, "lte", function(a) return haxe.Int64.compare(b(a[0]), b(a[1])) <= 0);
		reg.bindStatic(i64, "lteInt", function(a) return haxe.Int64.compare(b(a[0]), haxe.Int64.ofInt(a[1])) <= 0);
		reg.bindStatic(i64, "intLte", function(a) return haxe.Int64.compare(haxe.Int64.ofInt(a[0]), b(a[1])) <= 0);
		reg.bindStatic(i64, "gt", function(a) return haxe.Int64.compare(b(a[0]), b(a[1])) > 0);
		reg.bindStatic(i64, "gtInt", function(a) return haxe.Int64.compare(b(a[0]), haxe.Int64.ofInt(a[1])) > 0);
		reg.bindStatic(i64, "intGt", function(a) return haxe.Int64.compare(haxe.Int64.ofInt(a[0]), b(a[1])) > 0);
		reg.bindStatic(i64, "gte", function(a) return haxe.Int64.compare(b(a[0]), b(a[1])) >= 0);
		reg.bindStatic(i64, "gteInt", function(a) return haxe.Int64.compare(b(a[0]), haxe.Int64.ofInt(a[1])) >= 0);
		reg.bindStatic(i64, "intGte", function(a) return haxe.Int64.compare(haxe.Int64.ofInt(a[0]), b(a[1])) >= 0);
		// Complement/and/or/xor/shl/shr/ushr are private @:op impls; reach them through the abstract's
		// operators, which resolve to the same code without touching the private statics.
		reg.bindStatic(i64, "complement", function(a) return ~(b(a[0]) : haxe.Int64));
		reg.bindStatic(i64, "and", function(a) return (b(a[0]) : haxe.Int64) & (b(a[1]) : haxe.Int64));
		reg.bindStatic(i64, "or", function(a) return (b(a[0]) : haxe.Int64) | (b(a[1]) : haxe.Int64));
		reg.bindStatic(i64, "xor", function(a) return (b(a[0]) : haxe.Int64) ^ (b(a[1]) : haxe.Int64));
		reg.bindStatic(i64, "shl", function(a) return (b(a[0]) : haxe.Int64) << a[1]);
		reg.bindStatic(i64, "shr", function(a) return (b(a[0]) : haxe.Int64) >> a[1]);
		reg.bindStatic(i64, "ushr", function(a) return (b(a[0]) : haxe.Int64) >>> a[1]);
		reg.bindStatic(i64, "addInt", function(a) return haxe.Int64.add(b(a[0]), haxe.Int64.ofInt(a[1])));
		reg.bindStatic(i64, "subInt", function(a) return haxe.Int64.sub(b(a[0]), haxe.Int64.ofInt(a[1])));
		reg.bindStatic(i64, "intSub", function(a) return haxe.Int64.sub(haxe.Int64.ofInt(a[0]), b(a[1])));
		reg.bindStatic(i64, "mulInt", function(a) return haxe.Int64.mul(b(a[0]), haxe.Int64.ofInt(a[1])));
		reg.bindStatic(i64, "divInt", function(a) return haxe.Int64.div(b(a[0]), haxe.Int64.ofInt(a[1])));
		reg.bindStatic(i64, "intDiv", function(a) return haxe.Int64.div(haxe.Int64.ofInt(a[0]), b(a[1])));
		reg.bindStatic(i64, "modInt", function(a) return haxe.Int64.mod(b(a[0]), haxe.Int64.ofInt(a[1])));
		reg.bindStatic(i64, "intMod", function(a) return haxe.Int64.mod(haxe.Int64.ofInt(a[0]), b(a[1])));

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
