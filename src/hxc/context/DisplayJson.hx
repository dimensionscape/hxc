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
	// The JSON generator reads request metadata lazily.
	static var currentRequest:Null<JsonRpcHandler> = null;

	// Use minimum field generation when the client supports resolving completion items.
	public static function createJsonContext(mayResolve:Bool):hxc.core.Genjson {
		var gen = new hxc.core.Genjson(mayResolve && supportsResolve ? GMMinimum : GMFull);
		var rpc = currentRequest;
		if (rpc != null) {
			var memo:Null<Array<String>> = null, done = false;
			gen.requestedMeta = function() {
				if (!done) {
					memo = rpc.getOptParam(function() return [for (j in rpc.getArrayParam("meta")) rpc.getString("Metadata name", j)], null);
					done = true;
				}
				return memo;
			};
		}
		return gen;
	}

	// Process-lifetime compilation cache; a one-shot process starts fresh.
	public static var cache = new hxc.context.CompilationCache.CompilationCache();

	static var doNotCheckModules = false;
	public static var legacyCompletion = false;
	// Find-references flags controlling expansion to related fields.
	public static var usageDescendants = false;
	public static var usageBase = false;
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

	static function strings(l:Array<String>):Array<JsonValue> return [for (x in l) JString(x)];

	// HasParam and Link registries prepend entries, so reverse them to restore registration order.
	static function revStrings(l:Array<String>):Array<JsonValue> {
		var c = l.copy();
		c.reverse();
		return [for (x in c) JString(x)];
	}

	static function sendJson(json:JsonValue):Void {
		throw new JsonDisplayOutput(Json.stringOfJson(json));
	}

	// Configure the display file and offset, preserving the request ID for the later response.
	static function setDisplayFile(hctx:HandlerContext, mode:String, requiresOffset:Bool = true,
			autoTriggered:Bool = false):Void {
		hxc.parser.Parser.wasAutoTriggered = autoTriggered;
		var file = hctx.jsonrpc.getStringParam("file");
		var full = hxc.core.PathKey.fullPath(file);
		var offset = requiresOffset ? hctx.jsonrpc.getIntParam("offset") : 0;
		hctx.com.displaySpec = full + "@" + offset + "@" + mode;
		// Prefer supplied unsaved contents over the file on disk.
		var contents = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getStringParam("contents"), null);
		hctx.com.fileContents = [{file: full, contents: contents}];
		hctx.com.jsonRpcId = Json.stringOfJson(hctx.jsonrpc.id);
	}

	// Register implemented methods only; initialize advertises this set.
	static function handlers():Array<{name:String, f:HandlerContext->Void}> {
		return [
			{name: "initialize", f: function(hctx) {
				supportsResolve = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getBoolParam("supportsResolve"), false);
				hxc.context.DisplayException.maxCompletionItems = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getIntParam("maxCompletionItems"), 0);
				var exclude = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getArrayParam("exclude"), []);
				hxc.compiler.ToplevelScan.exclude = [for (e in exclude) switch (e) {
					case JString(x): x;
					case _: throw "exclude entries are strings";
				}];
				// Visit handler hash buckets and prepend entries to preserve protocol method ordering.
				var order = new hxc.core.NameHash.HashTableOrder();
				for (h in handlers()) order.add(h.name, hxc.core.NameHash.NameHash.stringHash(h.name));
				var visit = order.visitOrder();
				visit.reverse();
				var methods = [for (n in visit) JString(n)];
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
			}},
			{name: "display/completionItem/resolve", f: function(hctx) {
				// Resolve against the server's last completion list using full generation. One-shot processes
				// have no prior items.
				var i = hctx.jsonrpc.getIntParam("index");
				var items = hxc.context.DisplayException.lastCompletionResult;
				if (i < 0 || i >= items.length) hctx.sendError([JString("Invalid index: " + i)]);
				else hctx.sendResult(JObject([
					{name: "item", value: items[i].toJson(new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull), null)}
				]));
			}},
			{name: "display/completion", f: function(hctx) {
				// Completion answers at report time. wasAutoTriggered sets the parser's trigger flag.
				setDisplayFile(hctx, "", true, hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getBoolParam("wasAutoTriggered"), false));
			}},
			{name: "display/definition", f: function(hctx) {
				setDisplayFile(hctx, "position");
			}},
			{name: "display/diagnostics", f: function(hctx) {
				// Answer diagnostics only after compilation, using the stored request ID.
				var file = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getStringParam("file"), null);
				if (file != null) {
					var full = hxc.core.PathKey.fullPath(file);
					hctx.com.displaySpec = full + "@0@diagnostics";
					hctx.com.fileContents = [{file: full, contents: null}];
				} else {
					// Without file, fileContents supplies the complete diagnostics file set and any unsaved
					// sources.
					var entries = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getArrayParam("fileContents"), []);
					var fcs:Array<{file:String, contents:Null<String>}> = [];
					for (e in entries) switch (e) {
						case JObject(fl):
							var ef = hctx.jsonrpc.getStringField("fileContents", "file", fl);
							var full = hxc.core.PathKey.fullPath(ef);
							var contents = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getStringField("fileContents", "contents", fl), null);
							fcs.push({file: full, contents: contents});
						case _: throw new hxc.core.JsonRpc.InvalidArgument("fileContents");
					}
					hctx.com.fileContents = fcs;
					hctx.com.displaySpec = (fcs.length == 0 ? "?" : fcs[0].file) + "@0@diagnostics";
				}
				hctx.com.jsonRpcId = Json.stringOfJson(hctx.jsonrpc.id);
			}},
			{name: "display/implementation", f: function(hctx) {
				setDisplayFile(hctx, "implementation");
			}},
			{name: "display/typeDefinition", f: function(hctx) {
				setDisplayFile(hctx, "typeDefinition");
			}},
			{name: "display/references", f: function(hctx) {
				// Reference-search kind selects whether to include base declarations and descendants.
				setDisplayFile(hctx, "usage");
				var kind = hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getStringParam("kind"), "normal");
				switch (kind) {
					case "withBaseAndDescendants": usageDescendants = true; usageBase = true;
					case "withDescendants": usageDescendants = true; usageBase = false;
					case _: usageDescendants = false; usageBase = false;
				}
			}},
			{name: "display/hover", f: function(hctx) {
				setDisplayFile(hctx, "type");
			}},
			{name: "display/package", f: function(hctx) {
				setDisplayFile(hctx, "package", false);
			}},
			{name: "display/signatureHelp", f: function(hctx) {
				setDisplayFile(hctx, "signature", true, hctx.jsonrpc.getOptParam(function() return hctx.jsonrpc.getBoolParam("wasAutoTriggered"), false));
			}},
			{name: "display/metadata", f: function(hctx) {
				// Merge compiler and custom metadata by name after init macros register library documentation.
				var includeCompiler = hctx.jsonrpc.getBoolParam("compiler");
				var includeUser = hctx.jsonrpc.getBoolParam("user");
				var com = hctx.com;
				function answer():Void {
					var named:Array<{name:String, v:JsonValue}> = [];
					if (includeCompiler) for (m in MetaRegistry.metas()) {
						var name = MetaRegistry.stringField(m, "metadata", "");
						// Omit this entry to match the compiler's metadata registry.
						if (name == ":inlineConstructorArgument") continue;
						// Reverse prepended HasParam entries to restore their order.
						var params = MetaRegistry.arrayField(m, "params").copy();
						params.reverse();
						named.push({name: name, v: JObject([
							{name: "name", value: JString(name)},
							{name: "doc", value: JString(MetaRegistry.stringField(m, "doc", ""))},
							{name: "parameters", value: JArray(params)},
							{name: "platforms", value: JArray(MetaRegistry.arrayField(m, "platforms"))},
							{name: "targets", value: JArray(MetaRegistry.arrayField(m, "targets"))},
							{name: "internal", value: JBool(MetaRegistry.boolField(m, "internal"))},
							{name: "origin", value: JString("haxe compiler")},
							{name: "links", value: JArray(MetaRegistry.arrayField(m, "links"))}
						])});
					}
					if (includeUser && com != null) for (k in com.userMetas.keys()) {
						var e = com.userMetas.get(k);
						named.push({name: k, v: JObject([
							{name: "name", value: JString(k)},
							{name: "doc", value: JString(e.doc)},
							{name: "parameters", value: JArray(revStrings(e.params))},
							{name: "platforms", value: JArray(strings(e.platforms))},
							{name: "targets", value: JArray(strings(e.targets))},
							// Custom metadata cannot decode UsedInternally and therefore is never marked internal.
							{name: "internal", value: JBool(false)},
							{name: "origin", value: JString(e.source == null ? "user-defined" : e.source)},
							{name: "links", value: JArray(revStrings(e.links))}
						])});
					}
					named.sort(function(a, b) return a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
					hctx.sendResult(JArray([for (n in named) n.v]));
				}
				if (com == null) answer() else com.afterInitMacros.push(answer);
			}},
			{name: "display/defines", f: function(hctx) {
				// Merge compiler and custom defines by name. Compiler keys retain underscores; custom keys
				// retain their registered spelling.
				var includeCompiler = hctx.jsonrpc.getBoolParam("compiler");
				var includeUser = hctx.jsonrpc.getBoolParam("user");
				var com = hctx.com;
				function answer():Void {
					var named:Array<{name:String, v:JsonValue}> = [];
					if (includeCompiler) for (d in MetaRegistry.defines()) {
						var name = StringTools.replace(MetaRegistry.stringField(d, "define", ""), "-", "_");
						var deprecated = MetaRegistry.field(d, "deprecated");
						named.push({name: name, v: JObject([
							{name: "name", value: JString(name)},
							{name: "doc", value: JString(MetaRegistry.stringField(d, "doc", ""))},
							{name: "parameters", value: JArray(MetaRegistry.arrayField(d, "params"))},
							{name: "platforms", value: JArray(MetaRegistry.arrayField(d, "platforms"))},
							{name: "origin", value: JString("haxe compiler")},
							{name: "deprecated", value: deprecated == null ? JNull : deprecated},
							{name: "links", value: JArray(MetaRegistry.arrayField(d, "links"))}
						])});
					}
					if (includeUser && com != null) for (k in com.userDefines.keys()) {
						var e = com.userDefines.get(k);
						named.push({name: k, v: JObject([
							{name: "name", value: JString(k)},
							{name: "doc", value: JString(e.doc)},
							{name: "parameters", value: JArray(revStrings(e.params))},
							{name: "platforms", value: JArray(strings(e.platforms))},
							{name: "origin", value: JString(e.source == null ? "user-defined" : e.source)},
							// Custom defines cannot decode Deprecated and therefore never report it.
							{name: "deprecated", value: JNull},
							{name: "links", value: JArray(revStrings(e.links))}
						])});
					}
					named.sort(function(a, b) return a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
					hctx.sendResult(JArray([for (n in named) n.v]));
				}
				if (com == null) answer() else com.afterInitMacros.push(answer);
			}},
			{name: "server/readClassPaths", f: function(hctx) {
				// Wait for init macros and key the context by request defines so later completions reuse the
				// same context.
				var com = hctx.com;
				function answer():Void {
					var cc = cache.getContext(com.defines.getSignature());
					cc.initialized = true;
					// Class-path exploration runs after the stdio response. Report the current cached count;
					// explored files appear on the next request.
					hxc.context.ServerCache.addTask(function() hxc.compiler.ToplevelScan.explore(com));
					hctx.sendResult(JObject([{name: "files", value: JInt(cache.getFiles().length)}]));
				}
				if (com == null) answer() else com.afterInitMacros.push(answer);
			}},
			{name: "server/contexts", f: function(hctx) {
				// Omit contexts whose descriptive JSON is still JNull.
				var out = [for (cc in cache.contextList) if (!cc.json.match(JNull)) cc.json];
				hctx.sendResult(JArray(out));
			}},
			{name: "server/modules", f: function(hctx) {
				// Exclude MFake modules and report in reverse hash-bucket visit order.
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var cc = cache.getContext(sign);
				var out:Array<JsonValue> = [];
				for (path in cc.moduleOrder.visitOrder()) {
					var m = cc.modules.get(path);
					if (m != null && m.extra.kind != MFake) out.push(JString(path));
				}
				out.reverse();
				hctx.sendResult(JArray(out));
			}},
			{name: "server/module", f: function(hctx) {
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var path = hctx.jsonrpc.getStringParam("path");
				var cc = cache.getContext(sign);
				var m = cc.findModule(path);
				if (m == null) hctx.sendError([JString("No such module")]);
				hctx.sendResult(hxc.core.Genjson.generateModule(cc, m));
			}},
			{name: "server/type", f: function(hctx) {
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var path = hctx.jsonrpc.getStringParam("modulePath");
				var typeName = hctx.jsonrpc.getStringParam("typeName");
				var cc = cache.getContext(sign);
				var m = cc.findModule(path);
				if (m == null) hctx.sendError([JString("No such module")]);
				for (mt in m.types) {
					// Restore each class before serialization to expose its pre-filter typed state.
					switch (mt) { case TClassDecl(c): c.restore(); case _: }
					var infos = hxc.core.TypeFunctions.tInfos(mt);
					if (infos.path.name == typeName)
						hctx.sendResult(new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMMinimum).generateModuleType(mt));
				}
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
				var full = hxc.core.PathKey.fullPath(file);
				var key = fileKey(full);
				for (cc in cache.contextList) cc.removedFiles.set(key, full);
				hctx.sendResult(JString(full));
			}},
			{name: "server/files", f: function(hctx) {
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var cc = cache.getContext(sign);
				var keys = [for (k in cc.files.keys()) k];
				hxc.core.StringSort.sort(keys);
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
				var full = hxc.core.PathKey.fullPath(file);
				var key = fileKey(full);
				cache.taintModules(key, "server/invalidate");
				hxc.eval.EvalMacro.evictMacroModulesOfFile(full, "server/invalidate");
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
					hxc.compiler.ServerMessage.setByName(f.name, value);
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
			{name: "server/memory/context", f: function(hctx) {
				// Report cached module paths and kinds. Heap sizes and cross-context leak detection are
				// unavailable, so sizes are zero and leak lists empty.
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var cc = cache.getContext(sign);
				var list:Array<JsonValue> = [];
				for (path in cc.moduleOrder.visitOrder()) {
					var m = cc.modules.get(path);
					if (m == null) continue;
					list.push(JObject([
						{name: "path", value: JString(path)},
						{name: "size", value: JInt(0)},
						{name: "hasTypes", value: JBool(m.extra.kind == MCode || m.extra.kind == MMacro)}
					]));
				}
				hctx.sendResult(JObject([
					{name: "leaks", value: JNull},
					{name: "syntaxCache", value: JObject([{name: "size", value: JInt(0)}])},
					{name: "moduleCache", value: JObject([
						{name: "size", value: JInt(0)},
						{name: "list", value: JArray(list)}
					])}
				]));
			}},
			{name: "server/memory/module", f: function(hctx) {
				// Report module types with prepended field and static lists. Zero heap sizes leave stable
				// sorting in insertion order.
				var sign = hxc.context.CompilationCache.CompilationCache.digestFromHex(hctx.jsonrpc.getStringParam("signature"));
				var m = cache.getContext(sign).findModule(hctx.jsonrpc.getStringParam("path"));
				if (m == null) throw new hxc.core.NotFound();
				var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
				function sized(name:String, p:hxc.ast.Position, ?fields:Array<JsonValue>):JsonValue {
					var l:Array<JsonField> = [
						{name: "name", value: JString(name)},
						{name: "size", value: JInt(0)},
						{name: "pos", value: gen.generatePosAsLocation(p)}
					];
					if (fields != null) l.push({name: "fields", value: JArray(fields)});
					return JObject(l);
				}
				var types:Array<JsonValue> = [];
				for (mt in m.types) {
					var fields:Array<JsonValue> = [];
					switch (mt) {
						case TClassDecl(c):
							for (cf in c.orderedFields) fields.unshift(sized(cf.name, cf.namePos));
							for (cf in c.orderedStatics) fields.unshift(sized(cf.name, cf.namePos));
						case _:
					}
					var inf = hxc.core.TypeFunctions.tInfos(mt);
					types.push(sized(hxc.core.Globals.sTypePath(inf.path), inf.namePos, fields));
				}
				hctx.sendResult(JObject([
					{name: "moduleExtra", value: JInt(0)},
					{name: "types", value: JArray(types)}
				]));
			}},
			{name: "typer/compiledTypes", f: function(hctx) {
				hctx.com.displaySpec = "?@0@compiledTypes";
				hctx.com.jsonRpcId = Json.stringOfJson(hctx.jsonrpc.id);
			}}
		];
	}

	public static function parseInput(com:Context, input:String):Void {
		JsonRpc.handleJsonRpcError(function() {
			var request = JsonRpc.parseRequest(input);
			var jsonrpc = new JsonRpcHandler(request.id, request.method, request.params);
			currentRequest = jsonrpc;

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
