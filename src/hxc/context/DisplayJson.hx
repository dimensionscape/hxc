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

	static function sendJson(json:JsonValue):Void {
		throw new JsonDisplayOutput(Json.stringOfJson(json));
	}

	// Register implemented methods only; initialize advertises this set.
	static function handlers():Array<{name:String, f:HandlerContext->Void}> {
		return [
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
