package hxia;

// The profile a script compiles and runs under. `System` rather than `Sys`: an enum
// constructor named Sys shadows the Sys class wherever hxia.Host is imported.
enum Profile {
	Core;
	System;
}

enum LogLevel {
	Debug;
	Info;
	Warn;
	Error;
}

// An immutable description of what an application offers scripts. The shapes are
// the contract; bodies are stubs.
class HostBuilder {
	public function new() {}

	public function profile(p:Profile):HostBuilder
		throw new haxe.exceptions.NotImplementedException();

	public function grant(c:Capability):HostBuilder
		throw new haxe.exceptions.NotImplementedException();

	public function exposeStd():HostBuilder
		throw new haxe.exceptions.NotImplementedException();

	public function expose(cls:Class<Dynamic>):HostBuilder
		throw new haxe.exceptions.NotImplementedException();

	public function exposePackage(dotPath:String):HostBuilder
		throw new haxe.exceptions.NotImplementedException();

	public function pin(sha256:String):HostBuilder
		throw new haxe.exceptions.NotImplementedException();

	public function trustSigner(pubKey:String, grants:Array<Capability>):HostBuilder
		throw new haxe.exceptions.NotImplementedException();

	public function logSink(f:(level:LogLevel, msg:String, pos:ScriptPos) -> Void):HostBuilder
		throw new haxe.exceptions.NotImplementedException();

	public function build():Host
		throw new haxe.exceptions.NotImplementedException();
}

class Host {
	public static function build():HostBuilder
		throw new haxe.exceptions.NotImplementedException();
}
