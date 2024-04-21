package hxc.context;

// Dispatch JSON-RPC display methods through Completion responses. Unknown methods return -32601.

import hxc.core.Json;
import hxc.core.JsonRpc;
import hxc.core.Globals;
import hxc.context.Context;

// Completion unwinds to the compiler driver, which prints the payload and stops compilation.
class JsonDisplayOutput extends haxe.Exception {
	public var output:String;

	public function new(output:String) {
		super("json display output");
		this.output = output;
	}
}

typedef HandlerContext = {
	var com:Context;
	var jsonrpc:JsonRpcHandler;
	var sendResult:JsonValue->Void;
	var sendError:Array<JsonValue>->Void;
}

class DisplayJson {
	// Client supports completion-item resolution, as declared during initialize.
	static var supportsResolve = false;

	// Process-lifetime compilation cache; a one-shot process starts fresh.
	static var cache = new hxc.context.CompilationCache.CompilationCache();

	static var doNotCheckModules = false;
	static var legacyCompletion = false;
	static var serverPrintFlags = new haxe.ds.StringMap<Bool>();

	static var serverMessageNames = [
		"addedDirectory", "foundDirectories", "changedDirectories", "modulePathChanged",
		"notCached", "parsed", "removedDirectory", "reusing", "retyping", "skippingDep",
		"unchangedContent", "cachedModules", "arguments", "completion", "defines",
		"signature", "displayPosition", "stats", "message", "socketMessage",
		"uncaughtError", "newContext"
	];

	// Use lowercased full paths for case-insensitive filesystem keys.
	static function fileKey(full:String):String {
		return full.toLowerCase();
	}

	static function sendJson(json:JsonValue):Void {
		throw new JsonDisplayOutput(Json.stringOfJson(json));
	}

	// Configure the display file and offset, preserving the request ID for the later response.
	static function setDisplayFile(hctx:HandlerContext, mode:String, requiresOffset:Bool = true):Void {
		var file = hctx.jsonrpc.getStringParam("file");
		var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
		var offset = requiresOffset ? hctx.jsonrpc.getIntParam("offset") : 0;
		hctx.com.displaySpec = full + "@" + offset + "@" + mode;
		hctx.com.jsonRpcId = Json.stringOfJson(hctx.jsonrpc.id);
	}

	// Register implemented methods only; initialize advertises this set.
	static function handlers():Array<{name:String, f:HandlerContext->Void}> {
		return [
			{name: "typer/compiledTypes", f: function(hctx) {
				hctx.com.displaySpec = "?@0@compiledTypes";
				hctx.com.jsonRpcId = Json.stringOfJson(hctx.jsonrpc.id);
			}},
			{name: "display/metadata", f: function(hctx) {
				// Compiler metadata is available directly; custom metadata requires init-macro registration.
				var includeCompiler = hctx.jsonrpc.getBoolParam("compiler");
				hctx.jsonrpc.getBoolParam("user");
				var out:Array<JsonValue> = [];
				if (includeCompiler) {
					var all = MetaRegistry.metas();
					all.sort(function(a, b) {
						var n1 = MetaRegistry.stringField(a, "metadata", "");
						var n2 = MetaRegistry.stringField(b, "metadata", "");
						return n1 < n2 ? -1 : n1 > n2 ? 1 : 0;
					});
					for (m in all) {
						// The Haxe 4.3.7 generated metadata list omits this newer meta.json entry.
						if (MetaRegistry.stringField(m, "metadata", "") == ":inlineConstructorArgument") continue;
						var params = MetaRegistry.arrayField(m, "params").copy();
						params.reverse();
						out.push(JObject([
						{name: "name", value: JString(MetaRegistry.stringField(m, "metadata", ""))},
						{name: "doc", value: JString(MetaRegistry.stringField(m, "doc", ""))},
						{name: "parameters", value: JArray(params)},
						{name: "platforms", value: JArray(MetaRegistry.arrayField(m, "platforms"))},
						{name: "targets", value: JArray(MetaRegistry.arrayField(m, "targets"))},
						{name: "internal", value: JBool(MetaRegistry.boolField(m, "internal"))},
						{name: "origin", value: JString("haxe compiler")},
						{name: "links", value: JArray(MetaRegistry.arrayField(m, "links"))}
					]));
					}
				}
				hctx.sendResult(JArray(out));
			}},
			{name: "display/defines", f: function(hctx) {
				var includeCompiler = hctx.jsonrpc.getBoolParam("compiler");
				hctx.jsonrpc.getBoolParam("user");
				var out:Array<JsonValue> = [];
				if (includeCompiler) {
					var all = MetaRegistry.defines();
					var named = [for (d in all) {
						name: StringTools.replace(MetaRegistry.stringField(d, "define", ""), "-", "_"),
						fields: d
					}];
					named.sort(function(a, b) return a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
					for (d in named) {
						var deprecated = MetaRegistry.field(d.fields, "deprecated");
						out.push(JObject([
							{name: "name", value: JString(d.name)},
							{name: "doc", value: JString(MetaRegistry.stringField(d.fields, "doc", ""))},
							{name: "parameters", value: JArray(MetaRegistry.arrayField(d.fields, "params"))},
							{name: "platforms", value: JArray(MetaRegistry.arrayField(d.fields, "platforms"))},
							{name: "origin", value: JString("haxe compiler")},
							{name: "deprecated", value: deprecated == null ? JNull : deprecated},
							{name: "links", value: JArray(MetaRegistry.arrayField(d.fields, "links"))}
						]));
					}
				}
				hctx.sendResult(JArray(out));
			}},
			{name: "display/signatureHelp", f: function(hctx) {
				setDisplayFile(hctx, "signature");
			}},
			{name: "display/completionItem/resolve", f: function(hctx) {
				// Completion resolution requires a prior server result; every index is invalid in a one-shot
				// process.
				var i = hctx.jsonrpc.getIntParam("index");
				hctx.sendError([JString("Invalid index: " + i)]);
			}},
			{name: "display/implementation", f: function(hctx) {
				setDisplayFile(hctx, "implementation");
			}},
			{name: "display/typeDefinition", f: function(hctx) {
				setDisplayFile(hctx, "typeDefinition");
			}},
			{name: "display/package", f: function(hctx) {
				setDisplayFile(hctx, "package", false);
			}},
			{name: "display/completion", f: function(hctx) {
				// Completion answers at report time. wasAutoTriggered sets the parser's trigger flag.
				setDisplayFile(hctx, "");
			}},
			{name: "display/hover", f: function(hctx) {
				setDisplayFile(hctx, "type");
			}},
			{name: "display/definition", f: function(hctx) {
				setDisplayFile(hctx, "position");
			}},
			{name: "display/references", f: function(hctx) {
				// Only normal reference search is implemented; descendant variants are not collected yet.
				setDisplayFile(hctx, "usage");
			}},
			{name: "display/diagnostics", f: function(hctx) {
				// Answer diagnostics only after compilation, using the stored request ID.
				var file = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getStringParam("file"), null);
				if (file != null) {
					var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
					hctx.com.displaySpec = full + "@0@diagnostics";
				} else {
					hctx.com.displaySpec = "?@0@diagnostics";
				}
				hctx.com.jsonRpcId = Json.stringOfJson(hctx.jsonrpc.id);
			}},
			{name: "server/readClassPaths", f: function(hctx) {
				// Initialize the context and report cached files; one-shot runs cache none.
				var cc = cache.getContext("current");
				cc.initialized = true;
				hctx.sendResult(JObject([{name: "files", value: JInt(cache.getFiles().length)}]));
			}},
			{name: "server/contexts", f: function(hctx) {
				// Omit contexts whose descriptive JSON is still JNull.
				var out = [for (cc in cache.contextList) if (!cc.json.match(JNull)) cc.json];
				hctx.sendResult(JArray(out));
			}},
			{name: "server/modules", f: function(hctx) {
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var cc = cache.getContext(sign);
				var out = [for (path in cc.modules.keys()) if (cc.modules.get(path).extra.kind != MFake) JString(path)];
				hctx.sendResult(JArray(out));
			}},
			{name: "server/module", f: function(hctx) {
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var path = hctx.jsonrpc.getStringParam("path");
				var cc = cache.getContext(sign);
				var m = cc.findModule(path);
				if (m == null) hctx.sendError([JString("No such module")]);
				// Cached-module generation is not implemented; empty caches do not reach this branch.
				hctx.sendError([JString("No such module")]);
			}},
			{name: "server/type", f: function(hctx) {
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var path = hctx.jsonrpc.getStringParam("modulePath");
				hctx.jsonrpc.getStringParam("typeName");
				var cc = cache.getContext(sign);
				var m = cc.findModule(path);
				if (m == null) hctx.sendError([JString("No such module")]);
				hctx.sendError([JString("No such type")]);
			}},
			{name: "server/typeContexts", f: function(hctx) {
				hctx.jsonrpc.getStringParam("modulePath");
				hctx.jsonrpc.getStringParam("typeName");
				var out = [];
				for (cc in cache.contextList) {
					if (cc.modules.keys().hasNext()) {}
				}
				hctx.sendResult(JArray(out));
			}},
			{name: "server/moduleCreated", f: function(hctx) {
				// Mark the file removed in every context so the next compilation rereads it.
				var file = hctx.jsonrpc.getStringParam("file");
				var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
				var key = fileKey(full);
				for (cc in cache.contextList) cc.removedFiles.set(key, full);
				hctx.sendResult(JString(full));
			}},
			{name: "server/files", f: function(hctx) {
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var cc = cache.getContext(sign);
				var keys = [for (k in cc.files.keys()) k];
				keys.sort(Reflect.compare);
				var out = [for (k in keys) {
					var cf = cc.files.get(k);
					JObject([
						{name: "file", value: JString(cf.path)},
						{name: "time", value: JFloat(cf.time)},
						{name: "pack", value: JString(cf.pack.join("."))},
						{name: "moduleName", value: cf.moduleName == null ? JNull : JString(cf.moduleName)}
					]);
				}];
				hctx.sendResult(JArray(out));
			}},
			{name: "server/invalidate", f: function(hctx) {
				var file = hctx.jsonrpc.getStringParam("file");
				var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
				var key = fileKey(full);
				cache.taintModules(key, "server/invalidate");
				cache.removeFiles(key);
				hctx.sendResult(JNull);
			}},
			{name: "server/configure", f: function(hctx) {
				var results:Array<JsonValue> = [];
				var printParams = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getObjectParam("print"), []);
				for (f in printParams) {
					var value = hctx.jsonrpc.getBool("value", f.value);
					if (serverMessageNames.indexOf(f.name) == -1)
						hctx.sendError([JString("Invalid print parame name: " + f.name)]);
					serverPrintFlags.set(f.name, value);
					results.push(JString("Printing " + f.name + " " + (value ? "enabled" : "disabled")));
				}
				hctx.jsonrpc.getOptParam(function() {
					var b = hctx.jsonrpc.getBoolParam("noModuleChecks");
					doNotCheckModules = b;
					results.unshift(JString("Module checks " + (b ? "disabled" : "enabled")));
					return 0;
				}, 0);
				hctx.jsonrpc.getOptParam(function() {
					var b = hctx.jsonrpc.getBoolParam("legacyCompletion");
					legacyCompletion = b;
					results.unshift(JString("Legacy completion " + (b ? "enabled" : "disabled")));
					return 0;
				}, 0);
				hctx.sendResult(JArray(results));
			}},
			{name: "server/memory", f: function(hctx) {
				// Heap sizes are unavailable and report zero; preserve the memory-report structure.
				hctx.sendResult(JObject([
					{name: "contexts", value: JArray([])},
					{name: "memory", value: JObject([
						{name: "totalCache", value: JInt(0)},
						{name: "contextCache", value: JInt(0)},
						{name: "haxelibCache", value: JInt(0)},
						{name: "directoryCache", value: JInt(0)},
						{name: "nativeLibCache", value: JInt(0)},
						{name: "additionalSizes", value: JArray([])}
					])}
				]));
			}},
			{name: "initialize", f: function(hctx) {
				supportsResolve = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getBoolParam("supportsResolve"), false);
				var methods = [for (h in handlers()) JString(h.name)];
				hctx.sendResult(JObject([
					{name: "methods", value: JArray(methods)},
					{name: "haxeVersion", value: JObject([
						{name: "major", value: JInt(Globals.versionMajor)},
						{name: "minor", value: JInt(Globals.versionMinor)},
						{name: "patch", value: JInt(Globals.versionRevision)},
						{name: "pre", value: Globals.versionPre == null ? JNull : JString(Globals.versionPre)},
						{name: "build", value: JNull}
					])},
					{name: "protocolVersion", value: JObject([
						{name: "major", value: JInt(0)},
						{name: "minor", value: JInt(5)},
						{name: "patch", value: JInt(0)}
					])}
				]));
			}}
		];
	}

	public static function parseInput(com:Context, input:String):Void {
		JsonRpc.handleJsonRpcError(function() {
			var request = JsonRpc.parseRequest(input);
			var jsonrpc = new JsonRpcHandler(request.id, request.method, request.params);

			function sendResult(json:JsonValue):Void {
				var fields:Array<JsonField> = [
					{name: "result", value: json},
					{name: "timestamp", value: JFloat(Sys.time())}
				];
				sendJson(JsonRpc.result(jsonrpc.id, JObject(fields)));
			}

			function sendError(jl:Array<JsonValue>):Void {
				sendJson(JsonRpc.error(jsonrpc.id, 0, "Compiler error", JArray(jl)));
			}

			var hctx:HandlerContext = {
				com: com,
				jsonrpc: jsonrpc,
				sendResult: sendResult,
				sendError: sendError
			};

			var found = null;
			for (h in handlers()) if (h.name == jsonrpc.methodName) {
				found = h.f;
				break;
			}
			if (found == null) JsonRpc.raiseMethodNotFound(jsonrpc.id, jsonrpc.methodName);
			found(hctx);
		}, sendJson);
	}
}
