package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.codegen.dotnet.IlMeta.TypeDefSemantics;
import hxc.codegen.dotnet.IlMeta.TableIdx;
import hxc.codegen.dotnet.IlMeta.MetaAssembly;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMetaTools.IlNotFound;
import hxc.codegen.dotnet.NetConverter;

// an assembly indexed by Haxe path when it loads, whose classes are converted only when a module is
// asked for.
class NetLibrary {
	public var name(default, null):String;
	public var filePath(default, null):String;
	public var isStd(default, null):Bool;
	// an extern lib is only read, never copied next to the output
	public var isExtern:Bool = false;
	// Read by NetRefs only to lower references to it: never in ctx.netLibs or netPathMap, and without an
	// extern-type loader, so Haxe code cannot see its types.
	public var refOnly:Bool = false;

	var com:Context;
	var ilctx:Null<NetLibCtx> = null;
	// keyed by sTypePath; a type the library lacks is cached as null too
	var cache:Map<String, Null<IlClass>> = new Map();
	// rawClass's, keyed by IlPaths.key
	var rawCache:Map<String, Null<IlClass>> = new Map();

	public function new(com:Context, name:String, filePath:String, isStd:Bool) {
		this.com = com;
		this.name = name;
		this.filePath = filePath;
		this.isStd = isStd;
	}

	function netpathToHx(path:IlPath):Path return NetConverter.netpathToHx(isStd, path);

	public function load():Void {
		var pe = PeReader.read(sys.io.File.getBytes(filePath));
		var clrHeader = PeReader.readClrHeader(pe);
		var meta = IlMetaReader.readMetaTables(pe, clrHeader);
		var debug = com.defines.rawDefined("net_loader_debug");
		if (debug) Sys.println("for lib " + filePath);
		// the types are keyed again now that nested ones know their enclosing type
		meta.typedefs = new Map();
		for (td in meta.typedefOrder) {
			var path = IlMetaTools.getPath(TypeDef(td));
			var hx = netpathToHx(path);
			if (debug) Sys.println("found " + Globals.sTypePath(hx));
			if (!refOnly) {
				com.netPathMap.set(Globals.sTypePath(hx), path);
				var dotted = NetConverter.ilpathS(path);
				if (!com.netDottedMap.exists(dotted)) com.netDottedMap.set(dotted, path);
			}
			meta.typedefs.set(IlPaths.key(path), td);
		}
		ilctx = {nstd: isStd, ncom: com, nil: meta};
	}

	function getCtx():NetLibCtx {
		if (ilctx == null) load();
		return ilctx;
	}

	// The assembly's name, version, culture and public key token, as an AssemblyRef to it names it. The
	// token is the last 8 bytes of the public key's SHA-1, reversed.
	public function identity():ModuleBuilder.AssemblyIdentity {
		var a:Null<MetaAssembly> = null;
		for (m in getCtx().nil.tables[TableIdx.IAssembly]) switch (m) {
			case Assembly(r): a = r;
			case _:
		}
		if (a == null) throw "internal error: " + filePath + " has no Assembly row";
		var token:Null<haxe.io.Bytes> = null;
		if (a.publicKey != null && a.publicKey.length > 0) {
			var hash = haxe.crypto.Sha1.make(a.publicKey);
			token = haxe.io.Bytes.alloc(8);
			for (i in 0...8) token.set(i, hash.get(hash.length - 1 - i));
		}
		return {name: a.name, version: [a.major, a.minor, a.build, a.rev], culture: a.locale, publicKeyToken: token};
	}

	// Whether the assembly itself holds the type's definition (not a forwarder to it).
	public function definesType(path:IlPath):Bool {
		return getCtx().nil.typedefs.exists(IlPaths.key(path));
	}

	// The top-level types the assembly defines, in table order.
	public function topLevelTypes():Array<IlPath> {
		return [
			for (td in getCtx().nil.typedefOrder) {
				var path = IlMetaTools.getPath(TypeDef(td));
				if (path.nested.length == 0) path;
			}
		];
	}

	// The names of the assemblies this one references, in table order.
	public function assemblyRefs():Array<String> {
		var r = [];
		for (m in getCtx().nil.tables[TableIdx.IAssemblyRef]) switch (m) {
			case AssemblyRef(a): r.push(a.name);
			case _:
		}
		return r;
	}

	// The assembly a type forwarder of this one sends `path` to, or null. A nested type goes wherever its
	// outermost type does.
	public function forwarderTarget(path:IlPath):Null<String> {
		var top = path.nested.length > 0 ? path.nested[0] : path.name;
		for (m in getCtx().nil.tables[TableIdx.IExportedType]) switch (m) {
			case ExportedType(e) if (e.typeName == top && IlPaths.strsEq(e.typeNamespace, path.ns)):
				switch (e.implementation) {
					case AssemblyRef(r): return r.name;
					case _:
				}
			case _:
		}
		return null;
	}

	// The type's members as the assembly declares them, before the converter normalizes them.
	public function rawClass(path:IlPath):Null<IlClass> {
		var key = IlPaths.key(path);
		if (rawCache.exists(key)) return rawCache.get(key);
		// most assemblies asked for a type do not hold it: that is answered without a raise
		var r = !getCtx().nil.typedefs.exists(key) ? null : try IlMetaTools.convertClass(getCtx().nil, path) catch (_:IlNotFound) null;
		rawCache.set(key, r);
		return r;
	}

	// the top-level types, in table order
	public function listModules():Array<Path> {
		return [
			for (td in getCtx().nil.typedefOrder) {
				var path = IlMetaTools.getPath(TypeDef(td));
				if (path.nested.length == 0) netpathToHx(path);
			}
		];
	}

	public function lookup(path:Path):Null<IlClass> {
		var key = Globals.sTypePath(path);
		if (cache.exists(key)) return cache.get(key);
		var r:Null<IlClass> = try {
			var ctx = getCtx();
			var netPath = NetConverter.hxpathToNet(com, path);
			// A type is asked of every assembly until one holds it, so most of these answers are "not
			// here": that one is given without a raise.
			if (!ctx.nil.typedefs.exists(IlPaths.key(netPath))) null else {
				var cls = IlMetaTools.convertClass(ctx.nil, netPath);
				NetConverter.normalizeIlcls(ctx, cls);
			}
		} catch (_:IlNotFound) null;
		cache.set(key, r);
		return r;
	}

	// the class, then its nested types; a sealed delegate also gives the abstract that wraps it.
	public function build(path:Path, p:Position):Null<Array<TypeDecl>> {
		var p = new Position(filePath + " @ " + Globals.sTypePath(path), 0, 0);
		// the package is not used: the module path comes from the request
		var cp:Array<TypeDecl> = [];
		var debug = com.defines.rawDefined("net_loader_debug");
		function build(path:Path) {
			try {
				if (debug) Sys.println("looking up " + Globals.sTypePath(path));
				var cls = lookup(path);
				if (cls == null) return;
				var isDelegate = cls.csuper != null && switch (cls.csuper.snorm) {
					case LClass(p, _): p.ns.length == 1 && p.ns[0] == "System" && p.nested.length == 0
						&& (p.name == "Delegate" || p.name == "MulticastDelegate");
					case _: false;
				}
				if (isDelegate && cls.cflags.semantics.indexOf(SSealed) >= 0) {
					var ctx = getCtx();
					var hxcls = NetConverter.convertIlClass(ctx, p, cls, true);
					var delegate = NetConverter.convertDelegate(ctx, p, cls);
					cp.unshift(delegate);
					cp.unshift(hxcls);
				} else if (!NetConverter.isCompilerGenerated(cls)) {
					cp.unshift(NetConverter.convertIlClass(getCtx(), p, cls, false));
				} else
					return;
				for (ilpath in cls.cnested) build(netpathToHx(ilpath));
			} catch (_:IlNotFound) {} catch (_:NetExit) {}
		}
		build(path);
		return cp.length == 0 ? null : cp;
	}
}
