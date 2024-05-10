package hxc.context;

// Create cache contexts on demand by signature. One-shot runs retain no modules or files, and
// server/contexts omits contexts until addInfo supplies JSON.

import haxe.ds.StringMap;
import hxc.core.Json;

typedef CachedFile = {
	var path:String;
	var time:Float;
	var pack:Array<String>;
	var moduleName:Null<String>;
}

class CacheContext {
	public var index(default, null):Int;
	public var initialized = false;
	// Keyed by lowercased full path.
	public var files = new StringMap<CachedFile>();
	public var modules = new StringMap<hxc.core.Type.ModuleDef>();
	// Module fold order follows hash buckets keyed by the path tuple.
	public var moduleOrder = new hxc.core.NameHash.HashTableOrder();

	public function cacheModule(m:hxc.core.Type.ModuleDef):Void {
		var key = Context.sTypePath(m.path);
		modules.set(key, m);
		moduleOrder.add(key, hxc.core.NameHash.pathHash(m.path.pack, m.path.name));
	}
	public var removedFiles = new StringMap<String>();
	public var json:JsonValue = JNull;

	public function new(index:Int) {
		this.index = index;
	}

	public function findModule(path:String):Null<hxc.core.Type.ModuleDef> {
		return modules.get(path);
	}

	public function removeFile(key:String):Void {
		var f = files.get(key);
		if (f == null) return;
		files.remove(key);
		removedFiles.set(key, f.path);
	}
}

class CompilationCache {
	var contexts = new StringMap<CacheContext>();
	// Contexts in reverse creation order.
	public var contextList(default, null):Array<CacheContext> = [];

	public function new() {}

	public function getContext(sign:String):CacheContext {
		var cc = contexts.get(sign);
		if (cc == null) {
			var n = 0;
			for (_ in contexts.keys()) n++;
			cc = new CacheContext(n);
			contextList.unshift(cc);
			contexts.set(sign, cc);
		}
		return cc;
	}

	// (sign, key, file) triples across all contexts.
	public function getFiles():Array<{cc:CacheContext, key:String, file:CachedFile}> {
		var out = [];
		for (cc in contextList) for (key in cc.files.keys()) out.push({cc: cc, key: key, file: cc.files.get(key)});
		return out;
	}

	public function removeFiles(key:String):Void {
		for (cc in contextList) cc.removeFile(key);
	}

	// File invalidation is not implemented yet; one-shot caches contain no modules to invalidate.
	public function taintModules(key:String, reason:String):Void {
		for (cc in contextList) for (path in cc.modules.keys()) {
			var m = cc.modules.get(path);
			if (m.extra.file == key) {}
		}
	}

	// Register JSON to expose this context in server/contexts. List define keys in descending order.
	public function addInfo(sign:String, desc:String, platform:hxc.core.Globals.Platform, classPath:Array<String>, defines:hxc.core.Define):Int {
		var cc = getContext(sign);
		var keys = [for (k in defines.values.keys()) k];
		keys.sort(Reflect.compare);
		keys.reverse();
		cc.json = JObject([
			{name: "index", value: JInt(cc.index)},
			{name: "desc", value: JString(desc)},
			{name: "platform", value: JString(hxc.core.Globals.platformName(platform))},
			{name: "classPaths", value: JArray([for (s in classPath) JString(s)])},
			{name: "signature", value: JString(sign)},
			{name: "defines", value: JArray([for (k in keys) JObject([
				{name: "key", value: JString(k)},
				{name: "value", value: JString(defines.values.get(k))}
			])])}
		]);
		return cc.index;
	}

	// Cache finished modules under their own signatures, including modules whose signature differs
	// from the compilation's.
	public function cacheContext(com:Context):Void {
		var sign = com.defines.getSignature();
		var cc = getContext(sign);
		for (m in com.modules) {
			var mcc = (m.extra != null && m.extra.sign != null && m.extra.sign != "" && m.extra.sign != sign)
				? getContext(m.extra.sign) : cc;
			mcc.cacheModule(m);
		}
	}

	public function maybeAddContextSign(com:Context, desc:String):Void {
		addInfo(com.defines.getSignature(), desc, com.platform, com.classPath, com.defines);
	}

	// Exactly 32 hex characters, or an invalid-argument error.
	public static function digestFromHex(s:String):String {
		if (s.length != 32) throw new hxc.core.JsonRpc.InvalidArgument("Digest.from_hex");
		for (i in 0...32) {
			var c = s.charCodeAt(i);
			var hex = (c >= "0".code && c <= "9".code) || (c >= "a".code && c <= "f".code) || (c >= "A".code && c <= "F".code);
			if (!hex) throw new hxc.core.JsonRpc.InvalidArgument("Digest.from_hex");
		}
		return s.toLowerCase();
	}
}
