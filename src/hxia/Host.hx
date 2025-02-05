package hxia;

import hxia.interp.HostRegistry;
import hxia.interp.Mediator;
import hxia.interp.NeutralStd;

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

// An immutable description of what an application offers scripts. Everything a loaded
// module can reach comes from here: the std surface, the exposed host classes, the granted
// capability atoms, and the reflective-access policy that backs them.
class HostBuilder {
	var _profile:Profile = Core;
	var _grants:Array<Capability> = [];
	var _std:Bool = false;
	var _classes:Array<Class<Dynamic>> = [];
	var _packages:Array<String> = [];
	var _pins:Array<String> = [];
	var _signers:Array<{key:String, grants:Array<Capability>}> = [];
	var _log:Null<(LogLevel, String, ScriptPos) -> Void> = null;
	var _sdkHash:Null<String> = null;

	public function new() {}

	public function profile(p:Profile):HostBuilder {
		_profile = p;
		return this;
	}

	public function grant(c:Capability):HostBuilder {
		_grants.push(c);
		return this;
	}

	// The neutral std surface (ABI.md section 2). Also makes the reflective policy
	// permissive: "std is available" is exactly the permissive default the Mediator
	// documents, and a host that wants a closed surface simply does not call this.
	public function exposeStd():HostBuilder {
		_std = true;
		return this;
	}

	public function expose(cls:Class<Dynamic>):HostBuilder {
		_classes.push(cls);
		return this;
	}

	public function exposePackage(dotPath:String):HostBuilder {
		_packages.push(dotPath);
		return this;
	}

	// An artifact whose sha256 matches a pin is trusted, which lets the Runtime pick a trusted-fast
	// tier for it (see Runtime.load).
	public function pin(sha256:String):HostBuilder {
		_pins.push(sha256.toLowerCase());
		return this;
	}

	public function trustSigner(pubKey:String, grants:Array<Capability>):HostBuilder {
		_signers.push({key: pubKey, grants: grants});
		return this;
	}

	public function logSink(f:(level:LogLevel, msg:String, pos:ScriptPos) -> Void):HostBuilder {
		_log = f;
		return this;
	}

	// The surface hash of the SDK this host actually implements (hxia-sdk.hash, produced by
	// hxia.macro.Sdk when the externs were emitted). A module built against a different
	// version of that surface is refused at load instead of failing later on a member that
	// moved: declaring the hash is how a host opts into that check.
	public function sdkSurface(hash:String):HostBuilder {
		_sdkHash = hash;
		return this;
	}

	public function build():Host
		return new Host(_profile, _grants, _std, _classes, _packages, _pins, _signers, _log, _sdkHash);
}

class Host {
	public var profile(default, null):Profile;
	public var grants(default, null):haxe.ds.ReadOnlyArray<Capability>;
	public var pins(default, null):haxe.ds.ReadOnlyArray<String>;
	public var signers(default, null):haxe.ds.ReadOnlyArray<{key:String, grants:Array<Capability>}>;
	// Null when the host did not declare one, which means "do not check".
	public var sdkSurfaceHash(default, null):Null<String>;

	final std:Bool;
	final classes:Array<Class<Dynamic>>;
	final packages:Array<String>;
	final log:Null<(LogLevel, String, ScriptPos) -> Void>;
	// Dotted name -> class, for every exposed class (and the members policy below).
	final exposed:Map<String, Class<Dynamic>> = new Map();

	public function new(profile:Profile, grants:Array<Capability>, std:Bool, classes:Array<Class<Dynamic>>,
			packages:Array<String>, pins:Array<String>, signers:Array<{key:String, grants:Array<Capability>}>,
			log:Null<(LogLevel, String, ScriptPos) -> Void>, sdkSurfaceHash:Null<String>) {
		this.sdkSurfaceHash = sdkSurfaceHash;
		this.profile = profile;
		this.grants = grants.copy();
		this.std = std;
		this.classes = classes.copy();
		this.packages = packages.copy();
		this.pins = pins.copy();
		this.signers = signers.copy();
		this.log = log;
		for (c in this.classes) {
			var n = Type.getClassName(c);
			if (n != null)
				exposed.set(n, c);
		}
	}

	public static function build():HostBuilder
		return new HostBuilder();

	public function isExposed(typeName:String):Bool {
		if (exposed.exists(typeName))
			return true;
		for (p in packages)
			if (StringTools.startsWith(typeName, p + "."))
				return true;
		return false;
	}

	public function isTrusted(sha256:String):Bool
		return pins.indexOf(sha256.toLowerCase()) >= 0;

	public function emit(level:LogLevel, msg:String, pos:ScriptPos):Void {
		if (log != null)
			log(level, msg, pos);
	}

	// A registry carrying exactly this host's surface: the neutral std when exposeStd was
	// asked for, plus every exposed class as a constructible, statically-callable type. One
	// registry per module keeps module namespaces from sharing mutable binding state.
	public function makeRegistry():HostRegistry {
		var reg = new HostRegistry();
		if (std)
			NeutralStd.install(reg, function(line) emit(Info, line, {file: "", line: 0}));
		for (name in exposed.keys()) {
			var cls = exposed.get(name);
			reg.markNeutralStatic(name, cls);
			reg.bindNew(name, function(args) return Type.createInstance(cls, args));
		}
		return reg;
	}

	// The reflective-access policy the Mediator enforces. Without exposeStd the surface is
	// closed: only exposed classes and whatever the registry was told about. The unnamed
	// value shapes are always allowed - an anonymous object, a closure or null is not a host
	// class, so there is no authority for a capability policy to gate there.
	public function makePolicy(reg:HostRegistry):(String, String) -> Bool {
		if (std)
			return function(_, _) return true;
		return function(typeName:String, member:String) {
			return switch (typeName) {
				case "Anon" | "Function" | "Null" | "?": true;
				case _: isExposed(typeName)
					|| reg.neutralStaticClass(typeName) != null
					|| reg.memberBinding(typeName, member) != null;
			};
		};
	}

	public function makeMediator(reg:HostRegistry):Mediator
		return new Mediator(makePolicy(reg), function(t, m) return reg.memberBinding(t, m));
}
