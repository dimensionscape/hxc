package hxc.context;

// hxc.context.ServerCache: the compilation server's module reuse (changed directories, module checks,
// re-adding cached modules, the module-load hook) plus the directory finder. Enabled only while the wait
// server executes requests in-process; a one-shot compile never consults it.

import haxe.ds.StringMap;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals;

typedef CachedDirectory = {path:String, mtime:Float};

class ServerCache {
	public static var enabled = false;
	// The wait loop enables cache mode before the first request: from then on the parse hook keeps every
	// parsed file in the context's cache. A one-shot compile keeps the default hook, which caches nothing.
	public static var cacheMode = false;
	// Incremented per request; the checked and added marks compare against it.
	public static var compilationStep = 0;
	// The per-request memo of changed directories, keyed by signature.
	static var changedDirectories = new StringMap<Array<CachedDirectory>>();
	// sctx.delays: callbacks run after the request (a fresh context's directory registry populates
	// here so the scan does not slow the request that created the context).
	static var delays:Array<Void->Void> = [];
	// The class path the SIGNATURE was last seen with. A request that changes it for the same defines
	// clears the directory registry and marks the context uninitialised, so the class-path exploration runs
	// again.
	static var classPaths:haxe.ds.StringMap<String> = new haxe.ds.StringMap();

	public static function afterArgParsing(com:Context):Void {
		if (!enabled) return;
		var sign = com.defines.getSignature();
		var cp = com.classPath.join("
");
		var old = classPaths.get(sign);
		classPaths.set(sign, cp);
		if (old == null || old == cp) return;
		hxc.compiler.ServerMessage.classPathsChanged(com, "");
		changedDirectories.remove(sign);
		hxc.compiler.ToplevelScan.uninitialize(sign);
	}

	public static function resetRequest():Void {
		compilationStep++;
		changedDirectories = new StringMap();
		if (Sys.getEnv("HXC_SERVER_DBG") != null)
			Sys.stdout().writeString("[server] request step=" + compilationStep + "\n");
	}

	// What a stdio server queued while it answered runs once the answer is out.
	public static function addTask(f:Void->Void):Void delays.push(f);

	public static function runDelays():Void {
		var ds = delays;
		delays = [];
		for (d in ds) d();
	}

	// The file's mtime, or null when it cannot be stat'ed.
	static inline function statMtime(path:String):Null<Float> {
		var t = hxc.core.FileTime.statTimes(path);
		return t == null ? null : t.mtime;
	}

	// Lowercase-starting subdirectories, skipping those named after a DIFFERENT platform (a js/ dir is
	// invisible to a cpp compile).
	static function findDirectories(com:Context, recursive:Bool, paths:Array<String>):Array<String> {
		var target = Globals.platformName(com.platform);
		var targetDirs = [for (p in Globals.platforms) Globals.platformName(p)];
		var acc:Array<String> = [];
		function loop(dir:String):Void {
			var entries = try sys.FileSystem.readDirectory(dir) catch (_:Dynamic) return;
			for (file in entries) {
				if (file == "." || file == "..") continue;
				var c0 = file.charCodeAt(0);
				if (!(c0 >= "a".code && c0 <= "z".code)) continue;
				if (!(try sys.FileSystem.isDirectory(dir + file) catch (_:Dynamic) false)) continue;
				if (targetDirs.indexOf(file) >= 0 && file != target) continue;
				var full = dir + file;
				acc.push(full);
				if (recursive) loop(full + "/");
			}
		}
		for (dir in paths) loop(StringTools.endsWith(dir, "/") || StringTools.endsWith(dir, "\\") || dir == "" ? dir : dir + "/");
		return acc;
	}

	// Per-signature directory mtime tracking. A directory whose mtime advanced is "changed" (a file may
	// have appeared in it, shadowing a cached module); its new subdirectories join the registry. A
	// signature seen for the first time registers an empty list and defers the full class-path scan to a
	// delay.
	static function getChangedDirectories(com:Context):Array<CachedDirectory> {
		var sign = com.defines.getSignature();
		var memo = changedDirectories.get(sign);
		if (memo != null) return memo;
		var cache = hxc.context.DisplayJson.cache;
		var all = cache.findDirectories(sign);
		var dirs:Array<CachedDirectory>;
		if (all != null) {
			dirs = [];
			for (dir in all.copy()) {
				var time2 = statMtime(dir.path);
				if (time2 == null) {
					cache.removeDirectory(sign, dir.path);
					continue;
				}
				if (dir.mtime < time2) {
					dir.mtime = time2;
					for (sub in findDirectories(com, false, [dir.path]))
						if (!cache.hasDirectory(sign, sub)) {
							var st = statMtime(sub);
							if (st != null) cache.addDirectory(sign, {path: sub, mtime: st});
						}
					dirs.push({path: dir.path, mtime: time2});
				}
			}
		} else {
			// New context: seed empty (no shadowing checks on the first compile) and populate later.
			cache.addDirectories(sign, []);
			delays.push(function() {
				var out:Array<CachedDirectory> = [];
				function addDir(p:String):Void {
					var t = statMtime(p);
					if (t != null) out.push({path: p, mtime: t});
				}
				for (cp in com.classPath) addDir(cp);
				for (d in findDirectories(com, true, com.classPath)) addDir(d);
				cache.addDirectories(sign, out);
			});
			dirs = [];
		}
		changedDirectories.set(sign, dirs);
		return dirs;
	}

	// Can [m] be reused? null = yes; otherwise the skip reason.
	public static function checkModule(com:Context, m:ModuleDef, p:Position):Null<ModuleSkipReason> {
		var startMark = compilationStep;
		var unknownStateModules:Array<ModuleDef> = [];

		// A file for this module name inside a CHANGED directory that is newer than the module shadows it.
		function checkModuleShadowing(paths:Array<CachedDirectory>, m:ModuleDef):Null<ModuleSkipReason> {
			for (dir in paths) {
				var file = dir.path + (StringTools.endsWith(dir.path, "/") || StringTools.endsWith(dir.path, "\\") ? "" : "/") + m.path.name + ".hx";
				if (sys.FileSystem.exists(file)) {
					// fileTime, the clock time was read from
					var time = hxc.core.FileTime.fileTime(file);
					if (time > m.extra.time) return Shadowed(file);
				}
			}
			return null;
		}

		function check(m:ModuleDef):Null<ModuleSkipReason> {
			function hasPolicy(policy:ModuleCheckPolicy):Bool {
				for (x in m.extra.checkPolicy) if (x == policy) return true;
				return false;
			}
			function checkModulePath():Null<ModuleSkipReason> {
				return switch (m.extra.kind) {
					case MFake | MImport: null; // Don't get classpath
					case MExtern:
						// Hxc has no native-library extern loaders, so the library-file check reduces to shadowing.
						checkModuleShadowing(getChangedDirectories(com), m);
					case MCode:
						checkModuleShadowing(getChangedDirectories(com), m);
					case MMacro:
						// A macro module checks against the macro context's changed directories; hxc's
						// macro context shares the class paths, so the same registry serves.
						checkModuleShadowing(getChangedDirectories(com), m);
				}
			}
			function checkFile():Null<ModuleSkipReason> {
				var file = m.extra.file;
				// fileTime against time, one clock (statMtime is a stat call's, for directories)
				var time = hxc.core.FileTime.fileTime(file);
				if (time != m.extra.time) {
					// The CheckFileContentModification policy would re-parse and compare decls
					// here; the policy is only installed via server/configure, which hxc does not
					// accept yet, so a time change is always a content change.
					return FileChanged(file);
				}
				return null;
			}
			function checkDependencies():Null<ModuleSkipReason> {
				for (m2 in m.extra.deps) {
					var reason = check(m2);
					if (reason != null) return DependencyDirty(m2.path, reason);
				}
				return null;
			}
			function runChecks():Null<ModuleSkipReason> {
				if (!hasPolicy(NoCheckShadowing)) {
					var r = checkModulePath();
					if (r != null) return r;
				}
				if (!hasPolicy(NoCheckFileTimeModification) || haxe.io.Path.extension(m.extra.file) != "hx") {
					var r = checkFile();
					if (r != null) return r;
				}
				if (!hasPolicy(NoCheckDependencies)) {
					var r = checkDependencies();
					if (r != null) return r;
				}
				return null;
			}
			// If the module mark matches this compilation's mark, it was already checked.
			if (m.extra.checked == startMark) {
				return switch (m.extra.cacheState) {
					case MSGood | MSUnknown: null;
					case MSBad(reason): reason;
				}
			}
			m.extra.checked = startMark;
			var dirty:Null<ModuleSkipReason> = switch (m.extra.cacheState) {
				case MSBad(reason): reason; // Already dirty, stick to it
				case MSUnknown: throw "assert"; // An MSUnknown module always has the current mark
				case MSGood:
					m.extra.cacheState = MSUnknown;
					runChecks();
			};
			// Under the Retype policy a DependencyDirty module is offered to the retyper first; a
			// successful re-pairing keeps it, a failure leaves it dirty.
			switch (dirty) {
				case DependencyDirty(_, _) if (hasPolicy(Retype)):
					var reason = hxc.context.Retyper.attemptRetyping(com, m, p);
					if (reason == null) {
						hxc.compiler.ServerMessage.retyperOk(com, "", m);
						dirty = null;
					} else {
						hxc.compiler.ServerMessage.retyperFail(com, "", m, reason);
					}
				case _:
			}
			switch (dirty) {
				case null:
					// Clean is an assumption until the whole subgraph checks out.
					unknownStateModules.push(m);
				case reason:
					m.extra.cacheState = MSBad(reason);
			}
			return dirty;
		}

		var state = check(m);
		if (state == null) {
			for (m2 in unknownStateModules) m2.extra.cacheState = MSGood;
		} else {
			// The subgraph is dirty; anything still unknown must be re-checked when reached from a
			// different root, so back its mark off and assume good again.
			for (m2 in unknownStateModules) switch (m2.extra.cacheState) {
				case MSUnknown:
					m2.extra.checked = startMark - 1;
					m2.extra.cacheState = MSGood;
				case MSGood | MSBad(_):
			}
		}
		return state;
	}

	// Re-add the cached module and its dependency subgraph to the current compilation, restoring each type
	// from its typed snapshot.
	static function addModules(com:Context, mRoot:ModuleDef, p:Position):Void {
		function add(tabs:String, m0:ModuleDef, m:ModuleDef):Void {
			if (m.extra.added >= compilationStep) return;
			// The test is on the kind of the WALK ROOT, not of the module's immediate parent, so a
			// macro-created (MFake) root matches neither exclusion arm and its whole transitive subgraph is
			// walked, macro-world modules included. What stops it is adding the module itself: the
			// module-type check raises at the first type this compilation already registered, and the raise
			// ends the walk. A walk from one fake module stops before it reaches another fake module only
			// because the modules the macro world re-added this compilation are stamped already and skipped
			// (markMacroModuleReused).
			switch [m0.extra.kind, m.extra.kind] {
				case [MCode, MMacro] | [MMacro, MCode]:
					// A cross-context dependency was only checked; do not add it, just its resources.
					for (name in m.extra.bindedRes.keys())
						com.resources.set(name, haxe.io.Bytes.ofString(m.extra.bindedRes.get(name)));
				case _:
					m.extra.added = compilationStep;
					hxc.compiler.ServerMessage.reusing(com, tabs, m);
					for (t in m.types) TypeFunctions.tInfos(t).restore();
					// Adding the module: the duplicate-type check ran when the module first compiled;
					// re-adding only registers it with the current context.
					hxc.context.ModuleLoader.registerReusedModule(com, m);
					for (name in m.extra.bindedRes.keys())
						com.resources.set(name, haxe.io.Bytes.ofString(m.extra.bindedRes.get(name)));
					// Deps is an ordered map keyed by id: the walk visits the ids in ascending order.
					for (id in sortedDepIds(m)) add(tabs + "  ", m0, m.extra.deps.get(id));
			}
		}
		add("", mRoot, mRoot);
	}

	static function sortedDepIds(m:ModuleDef):Array<Int> {
		var ids = [for (id in m.extra.deps.keys()) id];
		ids.sort(function(a, b) return a < b ? -1 : a > b ? 1 : 0);
		return ids;
	}

	// Every module the macro world uses in a compilation counts as loaded again and re-added: stamped
	// added with this step, together with its macro-world dependencies. hxc keeps the macro com, so a
	// module that survived the previous compilation (and passed this one's check,
	// EvalMacro.evictStaleMacroModules) is still registered; it only takes the stamp, the first time the
	// macro world reaches it. A host walk that runs into it later skips it.
	public static function markMacroModuleReused(com:Context, mRoot:ModuleDef):Void {
		function add(tabs:String, m0:ModuleDef, m:ModuleDef):Void {
			if (m.extra.added >= compilationStep) return;
			if (!hxc.eval.EvalMacro.survivedIntoRequest(m)) return;
			switch [m0.extra.kind, m.extra.kind] {
				case [MCode, MMacro] | [MMacro, MCode]:
				case _:
					m.extra.added = compilationStep;
					hxc.compiler.ServerMessage.reusing(com, tabs, m);
					for (id in sortedDepIds(m)) add(tabs + "  ", m0, m.extra.deps.get(id));
			}
		}
		add("", mRoot, mRoot);
	}

	// Every module file parsed while the server serves a request is entered into the signature context's
	// parser cache. The module name stays unset here; it is filled in lazily, which nothing on this path
	// does, so server/files reports it as null.
	public static function cacheParsedFile(com:Context, file:String, pack:Array<String>, ?decls:Array<hxc.ast.Ast.TypeDecl>):Void {
		// The parse hook is the server's from its start, whether modules are reused or not.
		if (!cacheMode) return;
		// The DISPLAY file is cached only intact (no recovered parse errors) and only under a mode that
		// reads files whole (diagnostics, statistics, module symbols). A file whose #if reads `display`
		// gets no special treatment.
		if (hxc.parser.Parser.matchesDisplayFile(file)) {
			if (hxc.parser.Parser.syntaxErrors.length > 0) return;
			var parts = com.displaySpec == null ? [] : com.displaySpec.split("@");
			var mode = parts.length >= 3 ? parts[parts.length - 1] : "";
			if (mode != "diagnostics" && mode != "statistics" && mode != "module-symbols") return;
		}
		var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
		var time = hxc.core.FileTime.fileTime(full);
		var cc = hxc.context.DisplayJson.cache.getContext(com.defines.getSignature());
		// Path.UniqueKey: the lowercased full path (matching DisplayJson.fileKey).
		cc.setFile(full.toLowerCase(), {path: full, time: time, pack: pack, moduleName: null, decls: decls});
	}

	// The server's parse hook: a file the cache holds at the stamp it has on disk is not read again.
	public static function cachedParse(com:Context, file:String):Null<Array<hxc.ast.Ast.TypeDecl>> {
		if (!cacheMode) return null;
		var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
		var cf = hxc.context.DisplayJson.cache.getContext(com.defines.getSignature()).files.get(full.toLowerCase());
		if (cf == null || cf.decls == null) return null;
		var time = hxc.core.FileTime.fileTime(full);
		return time == cf.time ? cf.decls : null;
	}

	// The module-load hook. Looks the module up in the cache; if it is still valid, re-adds it (with its
	// subgraph) and returns it, else null and the caller re-types.
	public static function typeModule(com:Context, mpath:hxc.core.Globals.Path, p:Position):Null<ModuleDef> {
		var sign = com.defines.getSignature();
		var cc = hxc.context.DisplayJson.cache.getContext(sign);
		var m = cc.findModule(Context.sTypePath(mpath));
		if (m == null) return null;
		switch (checkModule(com, m, p)) {
			case null:
			case reason:
				hxc.compiler.ServerMessage.skippingDep(com, "", m, hxc.core.Genjson.sModuleSkipReason(reason));
				return null;
		}
		addModules(com, m, p);
		return m;
	}
}
