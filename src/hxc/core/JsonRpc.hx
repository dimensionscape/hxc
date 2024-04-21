package hxc.core;


import hxc.core.Json;

enum JsonRpcErrorKind {
	ParseError(s:String);
	InvalidRequest(s:String);
	MethodNotFound(id:JsonValue, name:String);
	InvalidParams(id:JsonValue);
	Custom(id:JsonValue, code:Int, message:String);
}

// An uncaught invalid argument prints as Invalid_argument("<arg>") on stderr with exit 1 (bad request
// params, a malformed hex digest).
class InvalidArgument extends haxe.Exception {
	public var arg:String;

	public function new(arg:String) {
		super("Invalid_argument(\"" + arg + "\")");
		this.arg = arg;
	}
}

class JsonRpcError extends haxe.Exception {
	public var kind:JsonRpcErrorKind;

	public function new(kind:JsonRpcErrorKind) {
		super("JsonRpc error");
		this.kind = kind;
	}
}

class JsonRpc {
	static var jsonrpcField:JsonField = {name: "jsonrpc", value: JString("2.0")};

	public static function result(id:JsonValue, data:JsonValue):JsonValue {
		return JObject([
			jsonrpcField,
			{name: "id", value: id},
			{name: "result", value: data}
		]);
	}

	public static function error(id:JsonValue, code:Int, message:String, ?data:JsonValue):JsonValue {
		var errorFields:Array<JsonField> = [
			{name: "code", value: JInt(code)},
			{name: "message", value: JString(message)}
		];
		if (data != null) errorFields.push({name: "data", value: data});
		return JObject([
			jsonrpcField,
			{name: "id", value: id},
			{name: "error", value: JObject(errorFields)}
		]);
	}

	public static function raiseMethodNotFound(id:JsonValue, name:String):Dynamic {
		throw new JsonRpcError(MethodNotFound(id, name));
	}

	public static function raiseCustom(id:JsonValue, code:Int, message:String):Dynamic {
		throw new JsonRpcError(Custom(id, code, message));
	}

	public static function raiseInvalidParams(id:JsonValue):Dynamic {
		throw new JsonRpcError(InvalidParams(id));
	}

	public static function handleJsonRpcError(f:Void->Void, output:JsonValue->Void):Void {
		try f() catch (e:JsonRpcError) {
			switch (e.kind) {
				case ParseError(s): output(error(JNull, -32700, s));
				case InvalidRequest(s): output(error(JNull, -32600, s));
				case MethodNotFound(id, meth): output(error(id, -32601, "Method `" + meth + "` not found"));
				case InvalidParams(id): output(error(id, -32602, "Invalid params"));
				case Custom(id, code, msg): output(error(id, code, msg));
			}
		}
	}

	public static function parseRequest(input:String):{id:JsonValue, method:String, params:Null<JsonValue>} {
		var json = try Json.parse(input) catch (e:JsonError) throw new JsonRpcError(ParseError(e.message));
		var fields = switch (json) {
			case JObject(fl): fl;
			case _: throw new JsonRpcError(InvalidRequest("not an object"));
		};
		function getField(name:String):JsonValue {
			for (f in fields) if (f.name == name) return f.value;
			throw new JsonRpcError(InvalidRequest("no `" + name + "` field"));
		}
		var id = getField("id");
		var meth = switch (getField("method")) {
			case JString(s): s;
			case _: throw new JsonRpcError(InvalidRequest("`method` field has invalid data"));
		};
		var params:Null<JsonValue> = null;
		for (f in fields) if (f.name == "params") params = f.value;
		return {id: id, method: meth, params: params};
	}
}

class JsonRpcHandler {
	public var id(default, null):JsonValue;
	public var methodName(default, null):String;
	var params:JsonValue;

	public function new(id:JsonValue, name:String, params:Null<JsonValue>) {
		this.id = id;
		this.methodName = name;
		this.params = params == null ? JNull : params;
	}

	function missingField(name:String, on:String):Dynamic {
		return JsonRpc.raiseCustom(id, 1, 'Missing param "' + name + '" on "' + on + '"');
	}

	function badType(desc:String, expected:String):Dynamic {
		return JsonRpc.raiseCustom(id, 2, 'Unexpected value for "' + desc + '", expected ' + expected);
	}

	public function getField(desc:String, fl:Array<JsonField>, name:String):JsonValue {
		for (f in fl) if (f.name == name) return f.value;
		return missingField(name, desc);
	}

	public function getString(desc:String, j:JsonValue):String {
		return switch (j) {
			case JString(s): s;
			case _: badType(desc, "String");
		};
	}

	public function getInt(desc:String, j:JsonValue):Int {
		return switch (j) {
			case JInt(i): i;
			case _: badType(desc, "String");
		};
	}

	public function getBool(desc:String, j:JsonValue):Bool {
		return switch (j) {
			case JBool(b): b;
			case _: badType(desc, "Bool");
		};
	}

	public function getArray(desc:String, j:JsonValue):Array<JsonValue> {
		return switch (j) {
			case JArray(a): a;
			case _: badType(desc, "Array");
		};
	}

	public function getObject(desc:String, j:JsonValue):Array<JsonField> {
		return switch (j) {
			case JObject(o): o;
			case _: badType(desc, "Object");
		};
	}

	public function getStringField(desc:String, name:String, fl:Array<JsonField>):String
		return getString(desc, getField(desc, fl, name));

	public function getIntField(desc:String, name:String, fl:Array<JsonField>):Int
		return getInt(desc, getField(desc, fl, name));

	public function getBoolField(desc:String, name:String, fl:Array<JsonField>):Bool
		return getBool(desc, getField(desc, fl, name));

	public function getArrayField(desc:String, name:String, fl:Array<JsonField>):Array<JsonValue>
		return getArray(desc, getField(desc, fl, name));

	public function getObjectField(desc:String, name:String, fl:Array<JsonField>):Array<JsonField>
		return getObject(desc, getField(desc, fl, name));

	function getObjParams():Array<JsonField> {
		return switch (params) {
			case JObject(fl): fl;
			case _: throw new InvalidArgument("params");
		};
	}

	public function getStringParam(name:String):String
		return getStringField("params", name, getObjParams());

	public function getIntParam(name:String):Int
		return getIntField("params", name, getObjParams());

	public function getBoolParam(name:String):Bool
		return getBoolField("params", name, getObjParams());

	public function getArrayParam(name:String):Array<JsonValue>
		return getArrayField("params", name, getObjParams());

	public function getObjectParam(name:String):Array<JsonField>
		return getObjectField("params", name, getObjParams());

	public function getOptParam<T>(f:Void->T, def:T):T {
		return try f() catch (_:JsonRpcError) def;
	}

	public function getParams():JsonValue return params;
}
