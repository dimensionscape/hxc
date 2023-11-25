package hxc;

import hxc.context.Context;
import hxc.context.Setup;
import hxc.context.ModuleLoader;
import hxc.typing.TypeResolve;
import hxc.typing.TypeFields;
import hxc.core.Globals;
import hxc.core.Globals.Platform;
import hxc.core.Globals.Path;
import hxc.ast.Position;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

@:buildXml('
<files id="pcre2-8">
	<compilerflag value="-DMATCH_LIMIT=4294967295U"/>
	<compilerflag value="-DMATCH_LIMIT_DEPTH=4294967295U"/>
	<compilerflag value="/USUPPORT_JIT" if="windows"/>
</files>
<files id="pcre2-16">
	<compilerflag value="-DMATCH_LIMIT=4294967295U"/>
	<compilerflag value="-DMATCH_LIMIT_DEPTH=4294967295U"/>
	<compilerflag value="/USUPPORT_JIT" if="windows"/>
</files>
')
class Compiler {
	public function new() run(Sys.args());
	public static function main() run(Sys.args());

	public static function run(args:Array<String>):Void {
		hxc.core.BinaryStdio.set();
		args = expandArgs(args);
		var ctx = new Context();
		ctx.args = args.copy();
		Setup.setupCommonContext(ctx);
		ModuleLoader.attach(ctx);
		// Close a still-open inferred method return before structural unification reads it; the field
		// types in whichever world (main or macro) owns its module.
		hxc.core.TypeUnification.forceOpenMethodHook = function(c, cf) {
			var com = ctx;
			var mc = hxc.eval.EvalMacro.getMacroCom();
			if (mc != null && c.module != null && mc.moduleLut.get(Context.pathKey(c.module.path)) == c.module) com = mc;
			try hxc.typing.TypeFields.forceFieldBody(com, c, cf) catch (_:Dynamic) {}
		};

		var userCp:Array<String> = [];
		var mainClass:Null<String> = null;
		var extraClasses:Array<String> = [];
		var platform:Platform = Cross;
		var targetDir:Null<String> = null; // The std overlay dir for the chosen target

		var i = 0;
		while (i < args.length) {
			var a = args[i++];
			switch (a) {
				case "-cp" | "-p" | "--class-path": userCp.push(args[i++]);
				case "-main" | "-m" | "--main": mainClass = args[i++];
				case "--resource": addResource(ctx, args[i++]);
				case "-D" | "--define":
					var kv = args[i++];
					var eq = kv.indexOf("=");
					// Normalizes '-' to '_' in the define key.
					if (eq < 0) ctx.defines.rawDefine(StringTools.replace(kv, "-", "_"));
					else ctx.defines.rawDefineValue(StringTools.replace(kv.substr(0, eq), "-", "_"), kv.substr(eq + 1));
				case "--interp":
					platform = Eval;
					targetDir = "eval";
					ctx.defines.rawDefine("interp");                                   
				case "-x":
					// X <class>: interpret <class>, i.e. --interp plus a startup class. .
					platform = Eval;
					targetDir = "eval";
					ctx.defines.rawDefine("interp");
					if (mainClass == null) mainClass = args[i++]; else i++;
				case "--run":
					// Run <module> [args...]: like -x but the trailing arguments are the program's own argv, not
					// compiler flags. (rewrites to `-x cl` with sys_args = rest).
					platform = Eval;
					targetDir = "eval";
					ctx.defines.rawDefine("interp");
					if (mainClass == null) mainClass = args[i++]; else i++;
					i = args.length; // Remaining args belong to the interpreted program
				case "-js" | "--js":
					platform = Js;
					targetDir = "js";
					ctx.file = args[i++];
				case "-cpp" | "--cpp":
					platform = Cpp;
					targetDir = "cpp";
					ctx.file = args[i++];
				case "--macro":
					ctx.initMacros.push(args[i++]);
				case "-v" | "--verbose":
					ctx.defines.rawDefine("verbose");
				case "--debug" | "-debug":
					// --debug also raises the debug define
					ctx.debug = true;
					ctx.defines.rawDefine("debug");
				case "--dce":
					ctx.defines.rawDefineValue("dce", args[i++]);
				case "--times":
					hxc.core.Timer.measureTimes = true;
				case "-w":
					var spec = args[i++];
					var wpos = new Position("-w " + spec, 0, 0);
					ctx.warningOptions.unshift(hxc.core.WarningList.parseOptions(spec, wpos));
				case _:
					// Every bare uppercase argument is a compilation root; the first doubles as the startup
					// class when -main is absent.
					if (!StringTools.startsWith(a, "-")) {
						var nm = a.split(".").pop();
						if (nm != null && nm.length > 0) {
							var c0 = nm.charCodeAt(0);
							if (c0 >= "A".code && c0 <= "Z".code) {
								if (mainClass == null) mainClass = a;
								else extraClasses.push(a);
							}
						}
					}
			}
		}

		// User -cp is searched before the std (it stays in front of the per-target overlay). Prepends
		// each -cp individually, so the last -cp on the command line ends up first; reverse the
		// source-order list to reproduce that.
		var cps = [for (p in userCp) Setup.addTrailingSlash(p)];
		cps.reverse();
		ctx.classPath = cps.concat(ctx.classPath);
		Setup.initPlatform(ctx, platform);
		if (targetDir != null) Setup.addStd(ctx, targetDir);
		ModuleLoader.initBasicTypes(ctx);
		// -D no-deprecation-warnings disables WDeprecated globally.
		if (ctx.defines.rawDefined("no_deprecation_warnings"))
			ctx.warningOptions.unshift([{warning: hxc.core.WarningList.Warning.WDeprecated, mode: hxc.core.WarningList.WarningMode.WMDisable}]);
		try {
			hxc.eval.EvalMacro.runInitMacros(ctx, ctx.initMacros);
		} catch (ex:hxc.eval.EvalExceptions.EvalRunTimeException) {
			flushPendingMessages(ctx);
			printPositionMessage("Uncaught exception " + hxc.eval.EvalStdLib.stringOf(ex.value), ex.pos);
			Sys.exit(1);
		} catch (e:hxc.core.TypingError) {
			flushPendingMessages(ctx);
			printPositionMessage(e.message, e.pos);
			Sys.exit(1);
		}

		if (mainClass == null) {
			Sys.println("hxc " + Globals.sVersion + " (" + Globals.platformName(platform) + ", no -main)");
			return;
		}
		var path = parseTypePath(mainClass);
		ctx.mainClass = path;
		try {
			var tLoad = hxc.core.Timer.timer(["parsing"]);
			ModuleLoader.loadModule(ctx, {pack: [], name: "Std"}, Position.nullPos);
			var m = ModuleLoader.loadModule(ctx, path, Position.nullPos);
			for (ec in extraClasses) ModuleLoader.loadModule(ctx, parseTypePath(ec), Position.nullPos);
			tLoad();
			var tType = hxc.core.Timer.timer(["typing"]);
			var tResolve = hxc.core.Timer.timer(["typing", "resolve"]);
			TypeResolve.resolveAll(ctx);
			tResolve();
			var tFields = hxc.core.Timer.timer(["typing", "fields"]);
			TypeFields.typeAllModules(ctx);
			tFields();
			tType();
			abortOnDiagnostics(ctx, platform);
			// Null safety runs before every expression filter and elimination so it sees the exprs as
			// typed.
			hxc.filters.DeprecationCheck.run(ctx);
			hxc.filters.NullSafety.run(ctx, ctx.types);
			hxc.typing.ExceptionFilters.run(ctx);
			hxc.typing.UnusedPure.run(ctx);
			if (platform == Eval) hxc.filters.Filters.runEvalAbstractCasts(new hxc.typing.TyperContext(ctx));
			hxc.debug.Dump.run(ctx);
			hxc.eval.EvalMacro.runGenerateCallbacks();
			abortOnDiagnostics(ctx, platform);
			// Fix com.main and the static-init type order before any target consumes them
			if (platform != Cross) hxc.typing.Finalization.run(ctx);
			// The filter pipeline runs for generated targets eval keeps its unfiltered path until the switch
			// is coordinated with the eval gate
			if (platform == Js) {
				var tFilter = hxc.core.Timer.timer(["filters"]);
				hxc.filters.Filters.run(new hxc.typing.TyperContext(ctx));
				tFilter();
				abortOnDiagnostics(ctx, platform);
				var tGen = hxc.core.Timer.timer(["generate", "js"]);
				hxc.generators.GenJS.generate(ctx);
				tGen();
			}
			if (platform == Eval) {
				// --interp: run the program through the evaluator so its own output (Sys.println,
				// utest, ...) is the only thing on stdout, matching what haxe --interp prints.
				var tInterp = hxc.core.Timer.timer(["interp"]);
				var ectx = hxc.eval.EvalMain.create(false, ctx.resources, ctx.defines, ctx.classPath, ctx);
				hxc.eval.EvalMain.addModules(ectx, ctx.modules, true);
				hxc.eval.EvalMain.runMain(ectx, path);
				tInterp();
			} else if (ctx.defines.rawDefined("verbose")) {
				// Compile-status line is a verbose-only aid; haxe prints nothing here on a successful compile.
				Sys.println("Loaded " + Context.sTypePath(path) + " (" + m.types.length + " types) for " + Globals.platformName(platform));
			}
		} catch (ex:hxc.eval.EvalExceptions.EvalRunTimeException) {
			// An uncaught exception escaping the interpreted program: render the thrown value and its
			// position, as the canonical eval target does, rather than the bare wrapper message.
			flushPendingMessages(ctx);
			printPositionMessage("Uncaught exception " + hxc.eval.EvalStdLib.stringOf(ex.value), ex.pos);
			for (p in ex.callPositions) printPositionMessage("Called from here", p);
			Sys.exit(1);
		} catch (e:hxc.parser.LexerError) {
			printPositionMessage(hxc.parser.LexerError.errorMsg(e.msg), e.pos);
			Sys.exit(1);
		} catch (e:hxc.parser.ParserError) {
			printPositionMessage(hxc.parser.ParserError.errorMsg(e.msg), e.pos);
			Sys.exit(1);
		} catch (e:hxc.context.Context.ContextError) {
			flushPendingMessages(ctx);
			printPositionMessage(e.message, e.pos);
			Sys.exit(1);
		} catch (e:hxc.core.TypingError) {
			flushPendingMessages(ctx);
			printPositionMessage(e.message, e.pos);
			Sys.exit(1);
		} catch (e:Dynamic) {
			Sys.stderr().writeString("Error: " + Std.string(e) + "\n");
			Sys.exit(1);
		}
		if (hxc.core.Timer.measureTimes) {
			hxc.core.Timer.closeTimes();
			hxc.core.Timer.reportTimes(function(s) Sys.stderr().writeString(s + "\n"));
		}
	}

	static function parseTypePath(s:String):Path {
		var parts = s.split(".");
		var name = parts.pop();
		return {pack: parts, name: name};
	}

	// A fatal error still reports the messages accumulated before it (warnings from macros, ...): the
	// message list is flushed on abort.
	static function flushPendingMessages(ctx:Context):Void {
		hxc.compiler.Messages.display(ctx);
		ctx.diagnostics = [];
	}

	static function abortOnDiagnostics(ctx:Context, platform:Platform):Void {
		// Display validates -D message.reporting (adding an error for an invalid mode) even with no other
		// messages, so an unknown reporting mode is reported on an otherwise clean compile.
		hxc.compiler.Messages.display(ctx);
		var hadError = ctx.hasError();
		ctx.diagnostics = [];
		if (hadError) Sys.exit(1);
	}

	static function expandArgs(args:Array<String>):Array<String> {
		return expandArgsInner(args, []);
	}

	static function expandArgsInner(args:Array<String>, seen:Array<String>):Array<String> {
		var out:Array<String> = [];
		var i = 0;
		while (i < args.length) {
			var a = args[i++];
			if (!StringTools.startsWith(a, "-") && StringTools.endsWith(a, ".hxml")) {
				out = out.concat(expandHxml(a, seen));
				continue;
			}
			if (a == "-lib" || a == "--library") {
				if (i >= args.length) throw "Missing library name";
				out = out.concat(expandHaxelib(args[i++], seen));
				continue;
			}
			out.push(a);
		}
		return out;
	}

	static function expandHxml(path:String, seen:Array<String>):Array<String> {
		var file = resolveHxml(path, seen.length == 0 ? null : seen[seen.length - 1]);
		var norm = StringTools.replace(file, "\\", "/");
		if (seen.indexOf(norm) >= 0) throw "Recursive hxml include: " + path;
		var nextSeen = seen.concat([norm]);
		var args:Array<String> = [];
		for (line in File.getContent(file).split("\n"))
			args = args.concat(parseHxmlLine(line));
		return expandArgsInner(args, nextSeen);
	}

	static function resolveHxml(path:String, ?from:String):String {
		if (FileSystem.exists(path)) return path;
		if (from != null) {
			var base = directoryOf(from);
			var p = base == "" ? path : base + "/" + path;
			if (FileSystem.exists(p)) return p;
		}
		return path;
	}

	static function expandHaxelib(lib:String, seen:Array<String>):Array<String> {
		var p = new Process("haxelib", ["path", lib]);
		var stdout = p.stdout.readAll().toString();
		var stderr = p.stderr.readAll().toString();
		var code = p.exitCode();
		p.close();
		if (code != 0) throw "haxelib path " + lib + " failed: " + stderr;
		var args:Array<String> = [];
		for (line in stdout.split("\n")) {
			var parsed = parseHxmlLine(line);
			if (parsed.length == 1 && !StringTools.startsWith(parsed[0], "-") && !StringTools.endsWith(parsed[0], ".hxml"))
				args = args.concat(["-cp", parsed[0]]);
			else
				args = args.concat(parsed);
		}
		return expandArgsInner(args, seen);
	}

	// An hxml line is at most a flag and one argument, split at the first space; surrounding quotes are
	// stripped per part and embedded quotes stay literal.
	static function parseHxmlLine(line:String):Array<String> {
		line = unquote(StringTools.trim(StringTools.replace(line, "\r", "")));
		if (line == "" || StringTools.startsWith(line, "#")) return [];
		if (line.charCodeAt(0) == "-".code) {
			var i = line.indexOf(" ");
			if (i < 0) return [line];
			var a = line.substr(0, i);
			var b = StringTools.trim(line.substr(i + 1));
			return [unquote(a), unquote(b)];
		}
		return [line];
	}

	static function unquote(s:String):String {
		var len = s.length;
		if (len > 1) {
			var f = s.charCodeAt(0), l = s.charCodeAt(len - 1);
			if ((f == "\"".code && l == "\"".code) || (f == "'".code && l == "'".code))
				return s.substr(1, len - 2);
		}
		return s;
	}

	static function directoryOf(path:String):String {
		var p = StringTools.replace(path, "\\", "/");
		var i = p.lastIndexOf("/");
		return i < 0 ? "" : p.substr(0, i);
	}

	static function printPositionMessage(msg:String, pos:Position):Void {
		// Classic message formatter: each continuation line gets a "... " prefix and repeats the position.
		var epos = Globals.getErrorPosRef(function(file, line) return '$file:$line:', pos);
		var lines = msg.split("
");
		var parts = [lines[0]];
		for (i in 1...lines.length) parts.push("... " + lines[i]);
		Sys.stderr().writeString(epos + " : " + parts.join("
" + epos + " : ") + "
");
	}

	static function addResource(ctx:Context, spec:String):Void {
		var parts = spec.split("@");
		if (parts.length > 2) throw "Invalid Resource format, expected file@name";
		var file = parts[0];
		var name = parts.length == 1 ? file : parts[1];
		if (ctx.resources.exists(name)) throw "Duplicate resource name " + name;
		ctx.resources.set(name, sys.io.File.getBytes(file));
	}
}
