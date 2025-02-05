package hxia;

import hxia.Errors;
import hxia.cppia.Loader;
import hxia.cppia.Decoder;
import hxia.interp.HostRegistry;
import hxia.interp.Interp;
import hxia.interp.NeutralBytes;

typedef Limits = {?fuelPerCall:Int, ?maxCallDepth:Int, ?maxAllocBytes:Int}

// One Runtime, N modules. Each artifact loads into its own namespace with its own registry and
// world, so two modules may define the same dotted path and remain distinct types; nothing resolves
// implicitly across namespaces. Load is explicit, boot is explicit and host-ordered, and a reload
// is just another load (a fresh namespace that cannot alias the running one).
//
// Holds the sandboxed tier always and the trusted-fast tier where the target has one; `load` picks
// per artifact by trust policy - a pinned artifact on js gets T1, everything else T3.
class Runtime {
	public var modules(default, null):haxe.ds.ReadOnlyArray<Module>;
	public var host(default, null):Host;

	final limits:Null<Limits>;
	final byId:Map<String, Module> = new Map();
	var counter = 0;
	var disposed = false;

	public function new(host:Host, ?limits:Limits) {
		this.host = host;
		this.limits = limits;
		this.modules = [];
	}

	public function load(bytes:haxe.io.Bytes, ?id:String):Module {
		if (disposed)
			throw new LoadError("runtime disposed");
		var ir = Loader.parse(bytes);
		var tree = Decoder.decode(ir);
		var strings = [for (b in ir.strings) b.getString(0, b.length)];
		var manifest = readManifest(tree, strings);

		// Permission before linkage: a script that may not run at all should not report what
		// it could not link to.
		var missing = Caps.missing(manifest.requires, [for (g in host.grants) g]);
		if (missing.length > 0)
			throw new PermissionError(missing);

		// Then the surface contract, still before linkage: a module built against a different SDK version
		// is refused as a version mismatch rather than reported later as a pile of unresolved members.
		// Only checked when both sides declared a hash.
		if (host.sdkSurfaceHash != null && manifest.sdkSurfaceHash != null
			&& host.sdkSurfaceHash != manifest.sdkSurfaceHash)
			throw new SurfaceError(host.sdkSurfaceHash, manifest.sdkSurfaceHash);

		var name = id != null ? id : "mod" + (counter++);
		if (byId.exists(name))
			throw new LoadError("module id already loaded: " + name);

		var reg = host.makeRegistry();
		installResources(reg, tree, strings);

		var trusted = host.isTrusted(haxe.crypto.Sha256.make(bytes).toHex());
		var mod = #if js trusted ? loadT1(name, manifest, ir, tree, reg) : #end loadT3(name, manifest, ir, reg);

		var all = [for (m in modules) m];
		all.push(mod);
		modules = all;
		byId.set(name, mod);
		return mod;
	}

	#if sys
	public function loadFile(path:String, ?id:String):Module
		return load(sys.io.File.getBytes(path), id);
	#end

	public function get(id:String):Null<Module>
		return byId.get(id);

	// Boot every loaded module in load order. A host that needs a different order boots the
	// modules itself; this is the common case, not a policy.
	public function bootAll():Void
		for (m in modules)
			m.boot();

	public function dispose():Void {
		disposed = true;
		modules = [];
		byId.clear();
	}


	function loadT3(name:String, manifest:Manifest, ir:hxia.cppia.ModuleIR, reg:HostRegistry):Module {
		var interp = new Interp(ir, reg, limits, host.makeMediator(reg));
		linkCheck(ir, Decoder.decode(ir), reg, interp);
		return new Module(name, manifest, "T3", interp, interp.boot, interp.run);
	}

	#if js
	function loadT1(name:String, manifest:Manifest, ir:hxia.cppia.ModuleIR, tree:hxia.cppia.OpTree.ModuleTree,
			reg:HostRegistry):Module {
		var jsHost = new hxia.lower.JsHost(reg, host.makeMediator(reg));
		hxia.interp.NeutralSerializer.install(reg, jsHost);
		linkCheck(ir, tree, reg, jsHost);
		var src = hxia.lower.JsLowerer.lower(ir, function(t) return reg.neutralStaticClass(t) != null);
		// The module body (statics, class init) runs on boot and yields main, so a host that
		// boots without running gets exactly the initialization step and nothing else.
		var mainFn:Null<Dynamic> = null;
		var boot = function() {
			var mod:Dynamic = js.Lib.eval(src);
			mainFn = mod(jsHost);
		};
		var run = function() {
			if (mainFn != null)
				mainFn();
		};
		return new Module(name, manifest, "T1", jsHost, boot, run);
	}
	#end


	function linkCheck(ir:hxia.cppia.ModuleIR, tree:hxia.cppia.OpTree.ModuleTree, reg:HostRegistry, world:ScriptWorld):Void {
		var unresolved = Linker.unresolvedTypes(ir, tree, function(t) return resolvable(t, reg, world));
		if (unresolved.length > 0)
			throw new LinkError(unresolved);
	}

	// Only the module's own types and the surface the host actually offered. Deliberately not "any
	// class present in the host binary": that would make every application class reachable by name and
	// reduce expose() to documentation.
	function resolvable(t:String, reg:HostRegistry, world:ScriptWorld):Bool {
		return world.hasClass(t)
			|| world.hasEnum(t)
			|| reg.knowsType(t)
			|| host.isExposed(t);
	}

	// The manifest travels inside the artifact as a RESOURCES entry. An artifact built before
	// that sidecar existed loads as core with no requests, which is the most restrictive
	// reading, not the most permissive: it can ask for nothing.
	static function readManifest(tree:hxia.cppia.OpTree.ModuleTree, strings:Array<String>):Manifest {
		for (res in tree.resources)
			if (strings[res.nameId] == "hxia.manifest")
				return ManifestIo.parse(res.data.getString(0, res.data.length));
		return {profile: "core", requires: [], formatVersion: 1, abiLevel: 1};
	}

	// A module's own embedded resources, served from the module - the host binary's haxe.Resource
	// holds the host's resources, never the script's.
	static function installResources(reg:HostRegistry, tree:hxia.cppia.OpTree.ModuleTree, strings:Array<String>):Void {
		var byName = new Map<String, haxe.io.Bytes>();
		for (res in tree.resources)
			byName.set(strings[res.nameId], res.data);
		var names = [for (n in byName.keys()) n];
		reg.bindStatic("haxe.Resource", "listNames", function(_) return names.copy());
		reg.bindStatic("haxe.Resource", "getString", function(a) {
			var b = byName.get(a[0]);
			return b == null ? null : b.getString(0, b.length);
		});
		reg.bindStatic("haxe.Resource", "getBytes", function(a) {
			var b = byName.get(a[0]);
			return b == null ? null : NeutralBytes.fromHost(b);
		});
	}
}
