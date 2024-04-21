package hxc;

import hxc.context.Context;
import hxc.context.Setup;
import hxc.context.ModuleLoader;
import hxc.typing.TypeResolve;
import hxc.typing.TypeFields;
import hxc.core.Globals;
import hxc.core.Globals.Platform;
import hxc.core.Globals.Path;
import hxc.core.TypeFunctions;
import hxc.core.TPrinting;
import hxc.core.Type;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.eval.EvalContext;
import hxc.eval.EvalField;
import hxc.eval.EvalHash;
import hxc.eval.EvalValue;
import hxc.eval.EvalValue.EvalValueTools;
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
<linker id="exe" exe="link.exe" if="windows">
	<flag value="-LARGEADDRESSAWARE"/>
	<flag value="-STACK:134217728"/>
</linker>
')
class Compiler {
	public function new() run(Sys.args());
	public static function main() run(Sys.args());

	// + the wait loop: length-prefixed request/response over stdin/stderr; each request is one compilation.
	static function runWaitStdio():Void {
		var stdin = Sys.stdin();
		var stderr = Sys.stderr();
		while (true) {
			var len = try {
				var b0 = stdin.readByte();
				var b1 = stdin.readByte();
				var b2 = stdin.readByte();
				var b3 = stdin.readByte();
				b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
			} catch (_:haxe.io.Eof) break;
			var payload = try stdin.read(len).toString() catch (_:haxe.io.Eof) break;
			var lines = payload.split("\n");
			while (lines.length > 0 && lines[lines.length - 1] == "") lines.pop();
			var out = new StringBuf();
			try {
				var proc = new Process(Sys.programPath(), lines);
				var pout = proc.stdout.readAll().toString();
				var perr = proc.stderr.readAll().toString();
				var code = proc.exitCode();
				proc.close();
				if (perr.length > 0) {
					out.add(perr);
					if (!StringTools.endsWith(perr, "\n")) out.add("\n");
				}
				if (pout.length > 0) out.add("\x01" + StringTools.replace(pout, "\n", "\x01") + "\n");
				if (code != 0) out.add("\x02\n");
			} catch (e:Dynamic) {
				out.add("Error: " + Std.string(e) + "\n\x02\n");
			}
			var body = haxe.io.Bytes.ofString(out.toString());
			var head = haxe.io.Bytes.alloc(4);
			head.set(0, body.length & 0xFF);
			head.set(1, (body.length >> 8) & 0xFF);
			head.set(2, (body.length >> 16) & 0xFF);
			head.set(3, (body.length >> 24) & 0xFF);
			stderr.write(head);
			stderr.write(body);
			stderr.flush();
		}
	}

	public static function run(args:Array<String>):Void {
		hxc.core.BinaryStdio.set();
		// The mono seams (create, bind, classify) route through TypeUnification; without this
		// the printer's constraint rendering sees the CUnknown stub and drops " : Constraint".
		hxc.core.TypeUnification.install();
		args = expandArgs(args);
		var nextAt = args.indexOf("--next");
		if (nextAt >= 0) {
			var sections:Array<Array<String>> = [];
			var start = 0;
			while (start <= args.length) {
				var end = args.indexOf("--next", start);
				if (end < 0) end = args.length;
				sections.push(args.slice(start, end));
				if (end == args.length) break;
				start = end + 1;
			}
			// Everything before --each in the first section repeats for every section. (each_params).
			var eachAt = sections[0].indexOf("--each");
			if (eachAt >= 0) {
				var common = sections[0].slice(0, eachAt);
				sections[0] = sections[0].slice(eachAt + 1);
				for (i in 0...sections.length) sections[i] = common.concat(sections[i]);
			}
			var exitCode = 0;
			for (section in sections) {
				var proc = new Process(Sys.programPath(), section);
				var stdout = proc.stdout.readAll();
				var stderr = proc.stderr.readAll();
				var code = proc.exitCode();
				proc.close();
				if (stdout.length > 0) Sys.stdout().writeString(stdout.toString());
				if (stderr.length > 0) Sys.stderr().writeString(stderr.toString());
				if (code != 0) {
					exitCode = code;
					break;
				}
			}
			Sys.exit(exitCode);
		}
		// --wait stdio: the compilation-server loop. Requests arrive on stdin as 4-byte little-endian
		// length-prefixed blocks of newline-separated argument lines; each response goes to stderr with the
		// same framing. A line starting \x01 carries program stdout with embedded newlines encoded as \x01;
		// a \x02 line flags failure; anything else is a compiler message line.
		var waitAt = args.indexOf("--wait");
		if (waitAt >= 0 && waitAt + 1 < args.length && args[waitAt + 1] == "stdio") {
			runWaitStdio();
			return;
		}
		var ctx = new Context();
		ctx.args = args.copy();
		Setup.setupCommonContext(ctx);
		ModuleLoader.attach(ctx);
		// A cast-field candidate check must see the INFERRED signature; force the abstract's cast fields on
		// lookup.
		hxc.core.TypeUnification.buildAbstractRef = function(a:hxc.core.Type.TAbstract) {
			if (a.impl == null) return;
			inline function forceReal(cf:hxc.core.Type.TClassField):Void {
				var real = a.impl.statics.get(cf.name);
				if (real != null && real.expr == null) hxc.typing.TypeFields.forceFieldBody(ctx, a.impl, real);
			}
			for (c in a.fromField) forceReal(c.cf);
			for (c in a.toField) forceReal(c.cf);
		};
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
		var cmds:Array<String> = [];
		var noOutput = false;
		var helpUserDefines = false;
		var helpUserMetas = false;
		var platform:Platform = Cross;
		var targetDir:Null<String> = null; // The std overlay dir for the chosen target
		var javaOutSeen = false;

		var i = 0;
		while (i < args.length) {
			var a = args[i++];
			switch (a) {
				case "-cp" | "-p" | "--class-path": userCp.push(args[i++]);
				case "-main" | "-m" | "--main": mainClass = args[i++];
				case "--hxia":
					// The hxia profile mask: `--hxia core` (or sys). Masks the std surface at
					// typing per hxc.hxia.CapabilityMask; atoms are added by --require.
					ctx.defines.rawDefineValue("hxia", args[i++]);
				case "--require":
					// Grant capability atoms (comma-separated), accumulating across repeats.
					var prev = ctx.defines.rawDefinedValueSafe("hxia_require", "");
					var add = args[i++];
					ctx.defines.rawDefineValue("hxia_require", prev == "" ? add : prev + "," + add);
				case "--hxia-dump-atoms":
					// Print the member->atom table and exit; the test lane reads this.
					Sys.print(hxc.hxia.CapabilityMask.dump());
					return;
				case "--resource": addResource(ctx, args[i++]);
				case "--remap":
					var spec = args[i++];
					var sep = spec.indexOf(":");
					if (sep <= 0 || sep == spec.length - 1) throw "Invalid remap format, expected source:target";
					ctx.packageRemaps.set(spec.substr(0, sep), spec.substr(sep + 1));
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
				case "-cppia" | "--cppia":
					// Cppia is the cpp platform with the cppia define, and the output value is a file rather than
					// a directory.
					ctx.defines.rawDefine("cppia");
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
				case "--no-opt":
					ctx.foptimize = false;
				case "--dce" | "-dce":
					ctx.defines.rawDefineValue("dce", args[i++]);
				case "-java" | "--java":
					// No generator, but the deprecated --java + -D jvm spelling still warns after the
					// arguments are known.
					javaOutSeen = true;
					i++;
				case "-neko" | "--neko" | "-php" | "--php" | "-swf" | "--swf" | "-as3" | "-cs" | "--cs"
					| "-jvm" | "--jvm" | "-python" | "--python" | "-lua" | "--lua"
					| "-hl" | "--hl":
					// Targets without a generator here; the output-file value must still be consumed
					// so it does not parse as a compilation root.
					i++;
				case "--display":
					ctx.displaySpec = args[i++];
				case "-swf-lib" | "--swf-lib" | "-swf-lib-extern" | "--swf-lib-extern" | "-swf-version"
					| "--swf-version" | "-swf-header" | "--swf-header" | "-java-lib" | "--java-lib"
					| "-java-lib-extern" | "--java-lib-extern" | "-net-lib" | "--net-lib" | "-net-std"
					| "--net-std" | "-c-arg" | "--c-arg" | "--connect":
					// Options without an implementation here; the value must still be consumed.
					i++;
				case "--cwd" | "-C":
					// A nonexistent directory aborts with the argument error "Invalid directory".
					var dir = args[i++];
					if (!sys.FileSystem.exists(dir) || !sys.FileSystem.isDirectory(dir)) {
						Sys.stderr().writeString("Error: Invalid directory: " + dir + "\n");
						Sys.exit(1);
					}
					Sys.setCwd(dir);
				case "--cmd" | "-cmd":
					cmds.push(unquote(args[i++]));
				case "--version" | "-version":
					// Recorded as an info message, not printed directly: macros can see and filter it through
					// Context.getMessages.
					ctx.addDiagnostic(Globals.sVersionFull, Position.nullPos, 0, MessageSeverity.Information);
				case "--help-user-defines":
					helpUserDefines = true;
				case "--help-user-metas":
					helpUserMetas = true;
				case "--no-output":
					noOutput = true;
				case "--times":
					hxc.core.Timer.measureTimes = true;
				case "-w":
					var spec = args[i++];
					var wpos = new Position("-w " + spec, 0, 0);
					ctx.warningOptions.unshift(hxc.core.WarningList.parseOptions(spec, wpos));
				case _:
					// A bare uppercase argument is a compilation root (never the startup class: only -main
					// sets that); a bare lowercase argument includes the package.
					if (!StringTools.startsWith(a, "-")) {
						if (StringTools.endsWith(a, ".hx")) {
							// A bare .hx file path is a compilation class, not a package strips the suffix).
							extraClasses.push(a);
						} else {
						var nm = a.split(".").pop();
						if (nm != null && nm.length > 0) {
							var c0 = nm.charCodeAt(0);
							if (c0 >= "A".code && c0 <= "Z".code) extraClasses.push(a);
							else ctx.initMacros.push("include('" + a + "', true, null, null, true)");
						}
						}
					}
			}
		}

		// Nothing to compile, no macros to run, no commands: exit after argument handling, so `-version`
		// works without a std. The accumulated messages (the -version info line) still print.
		if (mainClass == null && extraClasses.length == 0 && ctx.initMacros.length == 0
			&& cmds.length == 0 && !helpUserDefines && !helpUserMetas && platform == Cross
			&& ctx.displaySpec == null) {
			flushPendingMessages(ctx);
			return;
		}

		// User -cp is searched before the std (it stays in front of the per-target overlay). Prepends
		// each -cp individually, so the last -cp on the command line ends up first; reverse the
		// source-order list to reproduce that.
		var cps = [for (p in userCp) Setup.addTrailingSlash(p)];
		cps.reverse();
		ctx.classPath = cps.concat(ctx.classPath);
		// The Cpp target defaults hxcpp_api_level=430 before adding its std (std/cpp gates APIs such as
		// cpp.EnumBase.getIndex behind it), and smart (unicode) strings are used unless explicitly
		// disabled. Set before addStd so the std #if guards read them.
		if (platform == Cpp) {
			if (!ctx.defines.rawDefined("hxcpp_api_level")) ctx.defines.rawDefineValue("hxcpp_api_level", "430");
			if (!ctx.defines.rawDefined("disable_unicode_strings") && !ctx.defines.rawDefined("hxcpp_smart_strings"))
				ctx.defines.rawDefine("hxcpp_smart_strings");
		}
		Setup.initPlatform(ctx, platform);
		if (targetDir != null) Setup.addStd(ctx, targetDir);
		ModuleLoader.initBasicTypes(ctx);
		// The startup class is known from -main during argument handling, so an init macro's
		// Context.getMainExpr / Compiler.getConfiguration already sees it.
		if (mainClass != null) ctx.mainClass = parseTypePath(mainClass);
		// The --java target with -D jvm and no --jvm flag.
		if (javaOutSeen && ctx.defines.rawDefined("jvm"))
			ctx.warning(hxc.core.WarningList.Warning.WDeprecated, [], "--java out.jar -D jvm is deprecated; use --jvm out.jar directly", Position.nullPos);
		// -D no-deprecation-warnings disables WDeprecated globally.
		if (ctx.defines.rawDefined("no_deprecation_warnings"))
			ctx.warningOptions.unshift([{warning: hxc.core.WarningList.Warning.WDeprecated, mode: hxc.core.WarningList.WarningMode.WMDisable}]);
		// A JSON payload on --display selects the JSON-RPC display protocol it to DisplayJson.parse_input).
		// An immediate response travels the Completion channel and ends the run; a handler that only
		// configures state (diagnostics) lets compilation continue and answers at report time.
		if (ctx.displaySpec != null && StringTools.startsWith(ctx.displaySpec, "{")) {
			try {
				hxc.context.DisplayJson.parseInput(ctx, ctx.displaySpec);
			} catch (out:hxc.context.DisplayJson.JsonDisplayOutput) {
				// Print the response verbatim without a trailing newline.
				Sys.stderr().writeString(out.output);
				return;
			}
		}
		// Legacy --display file@pos: the parser stops at a dot-path completion point of the display file,
		// which also joins the compile roots. The statics install before the init macros so a display
		// position typed during a --macro run records.
		var displayRoot:Null<Path> = null;
		{
			var dparts = displayParts(ctx);
			var dmode = dparts.length >= 3 ? dparts[2] : "";
			if (dmode == "package" && dparts.length >= 2) {
				var pack = displayFilePackage(ctx, dparts[0]);
				// A package answer: a string array over the protocol.
				if (ctx.jsonRpcId != null) {
					var parts = pack == "" ? [] : pack.split(".");
					Sys.stderr().writeString(jsonRpcAnswer(ctx, "[" + [for (s in parts) haxe.Json.stringify(s)].join(",") + "]"));
					return;
				}
				Sys.stderr().writeString(pack + "\n");
				return;
			}
			if (dparts.length >= 2 && (dmode == "" || dmode == "position" || dmode == "type" || dmode == "usage" || dmode == "toplevel" || dmode == "typeDefinition" || dmode == "implementation" || dmode == "signature")) {
				var doff = Std.parseInt(dparts[1]);
				if (doff != null) {
					hxc.parser.Parser.displayFile = dparts[0];
					hxc.parser.Parser.displayOffset = doff;
					hxc.typing.Typer.displayDefinition = dmode == "position";
					hxc.typing.Typer.displayHover = dmode == "type";
					hxc.typing.Typer.displayUsage = dmode == "usage";
					hxc.typing.Typer.displayToplevel = dmode == "toplevel";
					hxc.typing.Typer.displayTypeDefinition = dmode == "typeDefinition";
					hxc.typing.Typer.displayImplementation = dmode == "implementation";
					hxc.typing.Typer.displaySignature = dmode == "signature";
					var base = dparts[0];
					var slash = StringTools.replace(base, "\\", "/").lastIndexOf("/");
					if (slash >= 0) base = base.substr(slash + 1);
					if (StringTools.endsWith(base, ".hx")) base = base.substr(0, base.length - 3);
					displayRoot = {pack: [], name: base};
				}
			}
		}
		try {
			hxc.eval.EvalMacro.runInitMacros(ctx, ctx.initMacros);
			// The init-macro callbacks run after the stage changes and before root modules type.
			ctx.initMacrosDone = true;
			hxc.eval.EvalMacro.runAfterInitMacrosCallbacks();
		} catch (ex:hxc.eval.EvalExceptions.EvalRunTimeException) {
			printUncaughtException(ctx, ex, hxc.eval.EvalMacro.currentPosition());
		} catch (e:hxc.core.TypingError) {
			// Through the message store, so -D message.reporting picks the formatter and a
			// compound message renders its sub-lines as depth children.
			ctx.raiseTypingErrors = false;
			ctx.addDiagnostic(e.message, e.pos, e.depth);
			flushPendingMessages(ctx);
			Sys.exit(1);
		}

		// The init-macro stage is complete; init-only APIs warn past this point (com.stage >=
		// CInitMacrosDone). / -help-user-defines/--help-user-metas print after the init macros registered
		// the entries, then stop. (add_after_init_macros + Abort).
		if (helpUserDefines || helpUserMetas) {
			if (helpUserDefines) printUserDocs([
				for (k in ctx.userDefines.keys()) {name: k.split("_").join("-"), entry: ctx.userDefines.get(k), isMeta: false}
			]);
			if (helpUserMetas) printUserDocs([
				for (k in ctx.userMetas.keys()) {name: "@" + k, entry: ctx.userMetas.get(k), isMeta: true}
			]);
			return;
		}

		// A compile without -main still loads its roots, runs macros and filters, and generates; it just
		// has no entry call (nothing is printed).
		var path = mainClass == null ? null : parseTypePath(mainClass);
		ctx.mainClass = path;
		try {
			var tLoad = hxc.core.Timer.timer(["parsing"]);
			ModuleLoader.loadModule(ctx, {pack: [], name: "Std"}, Position.nullPos);
			if (displayRoot != null) ModuleLoader.loadModule(ctx, displayRoot, Position.nullPos);
			var m = path == null ? null : ModuleLoader.loadModule(ctx, path, Position.nullPos);
			for (ec in extraClasses) ModuleLoader.loadModule(ctx, parseTypePath(ec), Position.nullPos);
			// The cppia define adds cpp.cppia.HostClasses to the compile roots; it loads last (roots are
			// typed in reverse insertion order).
			if (platform == Cpp && ctx.defines.rawDefined("cppia"))
				ModuleLoader.loadModule(ctx, {pack: ["cpp", "cppia"], name: "HostClasses"}, Position.nullPos);
			tLoad();
			var tType = hxc.core.Timer.timer(["typing"]);
			var tResolve = hxc.core.Timer.timer(["typing", "resolve"]);
			TypeResolve.resolveAll(ctx);
			tResolve();
			if (hxc.filters.ImportCheck.run(ctx)) abortOnDiagnostics(ctx, platform);
			var tFields = hxc.core.Timer.timer(["typing", "fields"]);
			TypeFields.typeAllModules(ctx);
			tFields();
			// Unused plain imports load once the build pipeline has run, so their declaration errors
			// surface; the second typing pass covers them (an import always loads its module).
			hxc.filters.ImportCheck.loadPlainImports(ctx);
			hxc.eval.EvalMacro.runAfterTypingCallbacks(ctx);
			TypeFields.typeAllModules(ctx);
			tType();
			TypeFields.checkAbstractInheritance(ctx);
			TypeFields.checkFinalVars(ctx);
			TypeFields.checkRecursiveAbstracts(ctx);
			// A metadata argument containing the display position types as an expression so completion can
			// fire inside it (e.g. @:access(pack.| ). .
			if (hxc.parser.Parser.displayFile != null) checkDisplayMetadata(ctx);
			if (hxc.typing.Typer.displayDefinition) {
				var found = hxc.typing.Typer.displayFound;
				if (found == null) found = [];
				// A JSON-RPC request answers with Location objects; the legacy arg prints XML.
				if (ctx.jsonRpcId != null)
					Sys.stderr().writeString(jsonRpcAnswer(ctx, "[" + [for (p in found) jsonLocation(p)].join(",") + "]"))
				else
					Sys.stderr().writeString(hxc.compiler.DisplayXml.printPositions(found) + "\n");
				return;
			}
			if (hxc.typing.Typer.displayTypeDefinition) {
				// The captured expression's type resolves to its declaration name position.
				var h = hxc.typing.Typer.hoverFound;
				var hf = h == null ? hoverOnFieldName(ctx) : null;
				var t:Null<T> = h != null ? h.t : (hf != null ? hf.t : null);
				var p = t == null ? null : typeDefinitionPos(t);
				var locs = p == null ? "[null]" : "[" + jsonLocation(p) + "]";
				if (ctx.jsonRpcId != null)
					Sys.stderr().writeString(jsonRpcAnswer(ctx, locs))
				else
					Sys.stderr().writeString(hxc.compiler.DisplayXml.printPositions(p == null ? [] : [p]) + "\n");
				return;
			}
			if (hxc.typing.Typer.displayHover) {
				if (ctx.jsonRpcId != null) {
					var out = jsonHover(ctx);
					Sys.stderr().writeString(out == null ? jsonRpcAnswer(ctx, "null") : out);
					return;
				}
				var h:Null<{t:T, p:Position}> = hxc.typing.Typer.hoverFound;
				if (h == null) h = hoverOnFieldName(ctx);
				Sys.stderr().writeString(h == null ? "" : hxc.compiler.DisplayXml.printType(hxc.core.TPrinting.sTypeStr(h.t), h.p));
				return;
			}
			if (hxc.typing.Typer.displayImplementation) {
				var impls = collectImplementations(ctx);
				if (ctx.jsonRpcId != null)
					Sys.stderr().writeString(jsonRpcAnswer(ctx, "[" + [for (p in impls) jsonLocation(p)].join(",") + "]"))
				else
					Sys.stderr().writeString(hxc.compiler.DisplayXml.printPositions(impls) + "\n");
				return;
			}
			if (hxc.typing.Typer.displayUsage) {
				var usages = collectUsages(ctx);
				if (ctx.jsonRpcId != null)
					Sys.stderr().writeString(jsonRpcAnswer(ctx, "[" + [for (p in usages) jsonLocation(p)].join(",") + "]"))
				else
					Sys.stderr().writeString(hxc.compiler.DisplayXml.printPositions(usages) + "\n");
				return;
			}
			if (hxc.typing.Typer.fieldCompletionFound != null) {
				if (ctx.jsonRpcId != null) {
					var out = jsonCompletion(ctx);
					Sys.stderr().writeString(out == null ? jsonRpcAnswer(ctx, "null") : out);
					return;
				}
				Sys.stderr().writeString(hxc.compiler.DisplayXml.printFields(hxc.typing.Typer.fieldCompletionFound) + "\n");
				return;
			}
			if (isDisplay(ctx, "signature")) {
				if (ctx.jsonRpcId != null) {
					Sys.stderr().writeString(jsonSignature(ctx));
					return;
				}
				displaySignature(ctx);
				return;
			}
			if (!isDisplay(ctx, "diagnostics")) abortOnDiagnostics(ctx, platform);
			// Null safety runs before every expression filter and elimination so it sees the exprs as
			// typed.
			hxc.filters.DeprecationCheck.run(ctx);
			hxc.filters.NullSafety.run(ctx, ctx.types);
			// Interface conformance (missing/incompatible fields) is checked after all fields are typed. .
			hxc.filters.InterfaceCheck.run(ctx);
			// Definite-assignment runs after typing on the pre-optimization tree, independent of the target
			// runs in the shared filter pipeline).
			hxc.filters.LocalVarsInit.run(ctx);
			hxc.typing.UnusedPure.run(ctx);
			if (platform == Eval) hxc.filters.Filters.runEvalAbstractCasts(new hxc.typing.TyperContext(ctx));
			hxc.debug.Dump.run(ctx);
			// Fix com.main and the static-init type order before any target consumes them
			if (platform != Cross) hxc.typing.Finalization.run(ctx);
			// onGenerate callbacks run inside Filters.run a targetless compile has no filter pipeline, so
			// they fire here to keep macro tests observable.
			if (platform == Cross) hxc.eval.EvalMacro.runGenerateCallbacks(ctx);
			if (isDisplay(ctx, "diagnostics")) {
				displayDiagnostics(ctx);
				return;
			}
			abortOnDiagnostics(ctx, platform);
			// The shared filter pipeline also runs for eval, where it supplies inline constructors,
			// exception lowering, and closure/local passes before interpretation. Filters run even under
			// --no-output only generation on no_output), so analyzer value checks still report.
			if (platform == Js || platform == Cpp || platform == Eval || platform == Neko) {
				var tFilter = hxc.core.Timer.timer(["filters"]);
				hxc.filters.Filters.run(new hxc.typing.TyperContext(ctx));
				tFilter();
				abortOnDiagnostics(ctx, platform);
				// Typer/compiledTypes: every compiled type serializes after the filters.
				if (ctx.jsonRpcId != null && isDisplay(ctx, "compiledTypes")) {
					var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
					var l = [for (mt in ctx.types) hxc.core.Json.Json.stringOfJson(gen.generateModuleType(mt))];
					Sys.stderr().writeString(jsonRpcAnswer(ctx, "[" + l.join(",") + "]"));
					return;
				}
				if (!noOutput) {
					if (platform == Js) {
						var tGen = hxc.core.Timer.timer(["generate", "js"]);
						hxc.generators.GenJS.generate(ctx);
						tGen();
					} else if (platform == Cpp) {
						var tGen = hxc.core.Timer.timer(["generate", "cpp"]);
						hxc.generators.GenCpp.generate(ctx);
						tGen();
					}
				}
			}
			// A targetless compile still checks value misuse the filter stage would catch; the reference's
			// filters run regardless of output. . Main resolution (privacy, signature) also still applies.
			if (platform == Cross) {
				hxc.typing.Finalization.getMain(ctx, ctx.types);
				for (t in ctx.types) hxc.filters.FiltersCommon.runExpressionFilters(new hxc.typing.TyperContext(ctx), [
					{name: "check_abstract_as_value", f: hxc.filters.Filters.checkAbstractAsValue},
				], t);
				abortOnDiagnostics(ctx, platform);
			}
			hxc.eval.EvalMacro.runAfterGenerateCallbacks();
			// A generator error (a printed error during generation, e.g. a bad @:native code placeholder)
			// fails
			// the compile like the final error check does, so a real target that printed an error does not
			// exit 0.
			abortOnDiagnostics(ctx, platform);
			// The single success-path flush: everything recorded up to and including the
			// after-generate callbacks prints once, before interpreter output or --cmd runs.
			flushPendingMessages(ctx);
			if (platform == Eval) {
				// --interp: run the program through the evaluator so its own output (Sys.println,
				// utest, ...) is the only thing on stdout, matching what haxe --interp prints.
				var tInterp = hxc.core.Timer.timer(["interp"]);
				if (path != null) {
					var ectx = hxc.eval.EvalMain.create(false, ctx.resources, ctx.defines, ctx.classPath, ctx);
					// ctx.types is in sorted type order, so a static initializer reading another class's
					// static finds it already evaluated; ctx.modules is sorted by path and would run
					// initializers alphabetically.
					hxc.eval.EvalMain.addTypes(ectx, ctx.types, true);
					hxc.eval.EvalMain.runMain(ectx, path);
				}
				tInterp();
			} else if (ctx.defines.rawDefined("verbose") && path != null) {
				// Compile-status line is a verbose-only aid; haxe prints nothing here on a successful compile.
				Sys.println("Loaded " + Context.sTypePath(path) + " (" + m.types.length + " types) for " + Globals.platformName(platform));
			}
			// --cmd commands run in order after a successful compile; a `cd ` command changes the working
			// directory, any other spawns a shell command.
			if (!noOutput) for (c in cmds) {
				var r = runCommand(c);
				if (r != 0) throw "Command failed with error " + r;
			}
		} catch (tc:hxc.parser.Parser.TypePathCompletion) {
			handleTypePathCompletion(ctx, tc);
			return;
		} catch (dp:hxc.compiler.DisplayXml.DisplayPositions) {
			Sys.stderr().writeString(hxc.compiler.DisplayXml.printPositions(dp.positions) + "\n");
			return;
		} catch (tl:hxc.compiler.DisplayXml.ToplevelCompletion) {
			// No trailing newline: the completion string prints verbatim.
			Sys.stderr().writeString(hxc.compiler.DisplayXml.printToplevel(tl.items));
			return;
		} catch (ex:hxc.eval.EvalExceptions.EvalRunTimeException) {
			printUncaughtException(ctx, ex, Position.nullPos);
		} catch (e:hxc.parser.LexerError) {
			// A failure under diagnostics reporting emits the JSON report instead of the plain message;
			// parser and lexer failures use DKParserError.
			if (isDisplay(ctx, "diagnostics")) return diagnosticsAbort(ctx, hxc.parser.LexerError.errorMsg(e.msg), e.pos, 4);
			abortWithMessage(ctx, hxc.parser.LexerError.errorMsg(e.msg), e.pos);
		} catch (e:hxc.parser.ParserError) {
			if (isDisplay(ctx, "diagnostics")) return diagnosticsAbort(ctx, hxc.parser.ParserError.errorMsg(e.msg), e.pos, 4);
			abortWithMessage(ctx, hxc.parser.ParserError.errorMsg(e.msg), e.pos);
		} catch (e:hxc.context.Context.ContextError) {
			if (isDisplay(ctx, "diagnostics")) return diagnosticsAbort(ctx, e.message, e.pos, 2, e.depth);
			abortWithMessage(ctx, e.message, e.pos, e.depth);
		} catch (e:hxc.core.TypingError) {
			if (isDisplay(ctx, "diagnostics")) return diagnosticsAbort(ctx, e.message, e.pos, 2, e.depth);
			abortWithMessage(ctx, e.message, e.pos, e.depth);
		} catch (e:Dynamic) {
			Sys.stderr().writeString("Error: " + Std.string(e) + "\n");
			Sys.exit(1);
		}
		if (hxc.core.Timer.measureTimes) {
			hxc.core.Timer.closeTimes();
			hxc.core.Timer.reportTimes(function(s) Sys.stderr().writeString(s + "\n"));
		}
	}

	// One line per entry: " name: params doc (platform only) (from source)", wrapped at 80 columns.
	static function printUserDocs(entries:Array<{name:String, entry:hxc.context.Context.UserDocEntry, isMeta:Bool}>):Void {
		entries.sort(function(a, b) return a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
		var maxLen = 0;
		for (en in entries) if (en.name.length > maxLen) maxLen = en.name.length;
		for (en in entries) {
			var d = en.entry;
			var params = d.params.length == 0 ? "" : (en.isMeta ? "(<" + d.params.join(">, <") + ">) " : "<" + d.params.join(">, <") + "> ");
			var pfs = switch (d.platforms.length) {
				case 0: "";
				case 1: " (" + d.platforms[0] + " only)";
				case _: " (for " + d.platforms.join(",") + ")";
			};
			var origin = d.source == null ? "" : " (from " + d.source + ")";
			Sys.println(" " + StringTools.rpad(en.name, " ", maxLen) + ": " + limitString(params + d.doc + pfs + origin, maxLen + 3));
		}
	}

	// Word-wraps at 80 columns, continuing lines indented to the given offset.
	static function limitString(s:String, offset:Int):String {
		var rest = 80 - offset;
		var out = new StringBuf();
		var col = 0;
		for (word in s.split(" ")) {
			if (word.length + col + 1 > rest) {
				out.add("\n");
				for (_ in 0...offset) out.add(" ");
				out.add(word);
				col = word.length;
			} else {
				if (col != 0) out.add(" ");
				out.add(word);
				col = col + 1 + word.length;
			}
		}
		return out.toString();
	}

	static function runCommand(cmd:String):Int {
		if (StringTools.startsWith(cmd, "cd ")) {
			Sys.setCwd(cmd.substr(3));
			return 0;
		}
		return Sys.command(cmd);
	}

	static function parseTypePath(s:String):Path {
		// A .hx file path is accepted where a class is expected (haxe -x Main.hx): strip the suffix and
		// split on slashes instead of dots.
		var parts:Array<String>;
		if (s.length > 3 && StringTools.endsWith(s, ".hx")) {
			var f = StringTools.replace(s.substr(0, s.length - 3), "\\", "/");
			parts = [for (p in f.split("/")) if (p != "") p];
		} else {
			parts = s.split(".");
		}
		var name = parts.pop();
		return {pack: parts, name: name};
	}

	// An uncaught interpreted exception prints its value at the throw position when one exists (dropping
	// the innermost duplicate stack frame), else at the catch position, then each stack frame
	// outermost-first as Called from here.
	static function printUncaughtException(ctx:Context, ex:hxc.eval.EvalExceptions.EvalRunTimeException, catchPos:Position):Void {
		if (catchPos == null) catchPos = Position.nullPos;
		var evalCtx = try EvalContext.getCtx() catch (_:Dynamic) null;
		if (evalCtx != null) switch (EvalValueTools.vresolve(ex.value)) {
			case VInstance(vi):
				var msg = hxc.eval.EvalStdLib.stringOf(EvalField.field(evalCtx, ex.value, EvalHash.hash("message")));
				if (msg == "null") msg = hxc.eval.EvalStdLib.stringOf(ex.value);
				var posValue = EvalField.field(evalCtx, ex.value, EvalHash.hash("pos"));
				var errorPos = switch (EvalValueTools.vresolve(posValue)) {
					case VInstance(pi): switch (pi.ikind) { case IPos(p): p; case _: Position.nullPos; };
					case VObject(obj): switch (obj.oproto) {
						case ODictionary(fields):
							var file = hxc.eval.EvalStdLib.stringOf(fields.get(EvalHash.hash("file")));
							var min = switch (fields.get(EvalHash.hash("min"))) { case VInt(i): i; case _: -1; };
							var max = switch (fields.get(EvalHash.hash("max"))) { case VInt(i): i; case _: -1; };
							new hxc.ast.Position(file, min, max);
						case _: Position.nullPos;
					};
					case _: Position.nullPos;
				};
				if (errorPos.min >= 0) {
					ctx.addDiagnostic(msg, qualifyStdPosition(ctx, errorPos));
					flushPendingMessages(ctx);
					Sys.exit(1);
				}
			case _:
		}
		// Frames run innermost first; an explicit throw position drops the innermost frame it
		// duplicates, and the catch position closes the stack (the reference's api-call env).
		var frames = [for (env in ex.envStack) qualifyStdPosition(ctx, hxc.eval.EvalExceptions.envPosition(env))];
		frames = [for (p in frames) if (p != null && p.file != "?") p];
		if (hxc.eval.EvalStdLib.stringOf(ex.value) == "Stack overflow") {
			var entryPos:Null<Position> = null;
			if (ctx.mainClass != null) for (mt in ctx.types) switch (mt) {
				case TClassDecl(c) if (c.path.pack.join(".") == ctx.mainClass.pack.join(".") && c.path.name == ctx.mainClass.name): entryPos = new Position(c.pos.file, c.pos.min, c.pos.min);
				case _:
				}
			if (entryPos == null && ctx.main != null) entryPos = ctx.main.pos;
			if (entryPos != null && entryPos.file != "?") frames.unshift(entryPos);
		}
		var explicit = ex.pos != null && !(ex.pos.file == "?" && ex.pos.min < 0);
		if (explicit && frames.length > 0) frames.shift();
		if (!(catchPos.file == "?" && catchPos.min < 0)) frames.push(catchPos);
		var p1 = explicit ? ex.pos : catchPos;
		// Reported through the message list so every -D message.reporting formatter renders it.
		var stack = [{message: "Uncaught exception " + hxc.eval.EvalStdLib.stringOf(ex.value), pos: p1}];
		for (p in frames) stack.push({message: "Called from here", pos: p});
		ctx.addDiagnosticStack(stack);
		flushPendingMessages(ctx);
		Sys.exit(1);
	}

	static function qualifyStdPosition(ctx:Context, p:Null<Position>):Null<Position> {
		if (p == null || p.file == null || p.file == "" || FileSystem.exists(p.file)) return p;
		for (root in ctx.stdPath) {
			var file = StringTools.endsWith(root, "\\") || StringTools.endsWith(root, "/") ? root + p.file : root + "/" + p.file;
			if (FileSystem.exists(file)) return new Position(file, p.min, p.max);
		}
		return p;
	}

	// A fatal error still reports the messages accumulated before it (warnings from macros, ...): the
	// message list is flushed on abort.
	static function flushPendingMessages(ctx:Context):Void {
		hxc.compiler.Messages.display(ctx);
		ctx.diagnostics = [];
	}

	static function displayParts(ctx:Context):Array<String> {
		return ctx.displaySpec == null ? [] : ctx.displaySpec.split("@");
	}

	// Legacy --display @package: the display file's package is its path relative to the classpath that
	// contains it, keeping the SHORTEST module path across classpaths. .
	static function displayFilePackage(ctx:Context, file:String):String {
		var real = try FileSystem.fullPath(file) catch (_:Dynamic) file;
		function norm(s:String):String {
			var n = StringTools.replace(s, "\\", "/");
			return Sys.systemName() == "Windows" ? n.toLowerCase() : n;
		}
		var realN = norm(real);
		var best:Null<Array<String>> = null;
		for (cp in ctx.classPath.concat(ctx.stdPath)) {
			var cpReal = try FileSystem.fullPath(cp == "" ? "." : cp) catch (_:Dynamic) continue;
			var cpN = norm(cpReal);
			if (!StringTools.endsWith(cpN, "/")) cpN += "/";
			if (realN.length <= cpN.length || realN.substr(0, cpN.length) != cpN) continue;
			var rest = StringTools.replace(real, "\\", "/").substr(cpN.length);
			var segs = rest.split("/");
			if (segs.length == 0) continue;
			segs.pop();
			if (best == null || segs.join(".").length < best.join(".").length) best = segs;
		}
		return best == null ? "" : best.join(".");
	}

	// A display position on a field declaration name makes the declared field itself the usage target.
	static function usageFieldAtDeclaration(ctx:Context):Null<hxc.core.Type.TClassField> {
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c):
				var all = c.orderedFields.concat(c.orderedStatics);
				if (c.constructor != null) all.push(c.constructor);
				for (f in all) if (hxc.typing.Typer.atHoverPos(f.namePos)) return f;
			case _:
		}
		return null;
	}

	// The classes extending or implementing the target class, or the fields overriding or implementing the
	// target field, sorted by file then position.
	static function collectImplementations(ctx:Context):Array<Position> {
		var cf = hxc.typing.Typer.usageTargetField;
		var targetClass = hxc.typing.Typer.usageTargetClass;
		if (cf == null && targetClass == null) {
			for (mt in ctx.types) switch (mt) {
				case TClassDecl(c) if (hxc.typing.Typer.atHoverPos(c.namePos)): targetClass = c;
				case _:
			}
		}
		if (cf == null && targetClass == null) cf = usageFieldAtDeclaration(ctx);
		var out:Array<Position> = [];
		if (targetClass != null) {
			// The implemented relation covers the full interface closure (own, inherited through supers,
			// and interface extends).
			function implementsTarget(c:hxc.core.Type.TClass):Bool {
				var seen:Array<hxc.core.Type.TClass> = [];
				function walk(c2:hxc.core.Type.TClass):Bool {
					if (seen.indexOf(c2) >= 0) return false;
					seen.push(c2);
					for (i in c2.interfaces) if (i.c == targetClass || walk(i.c)) return true;
					return c2.superClass != null && walk(c2.superClass.c);
				}
				return walk(c);
			}
			for (mt in ctx.types) switch (mt) {
				case TClassDecl(c) if (c != targetClass):
					if (c.superClass != null && c.superClass.c == targetClass) out.push(c.namePos)
					else if (implementsTarget(c)) out.push(c.namePos);
				case _:
			}
		} else if (cf != null) {
			// A field in c implements or overrides the target when any ancestor reached through the super
			// chain or the inherited interface closure declares the target field itself (the relations chain
			// transitively).
			for (mt in ctx.types) switch (mt) {
				case TClassDecl(c):
					var mine = c.fields.get(cf.name);
					if (mine == null || mine == cf) continue;
					var seen:Array<hxc.core.Type.TClass> = [];
					function declaresTarget(c2:hxc.core.Type.TClass):Bool {
						if (seen.indexOf(c2) >= 0) return false;
						seen.push(c2);
						if (c2 != c && c2.fields.get(cf.name) == cf) return true;
						for (i in c2.interfaces) if (declaresTarget(i.c)) return true;
						return c2.superClass != null && declaresTarget(c2.superClass.c);
					}
					if (declaresTarget(c)) out.push(mine.namePos);
				case _:
			}
		}
		out.sort(function(a, b) {
			if (a.file != b.file) return a.file < b.file ? -1 : 1;
			return a.min - b.min;
		});
		return out;
	}

	// Scan every typed field body for references to the captured @usage target. positions sort in source
	// order.
	static function collectUsages(ctx:Context):Array<Position> {
		var cf = hxc.typing.Typer.usageTargetField;
		var v = hxc.typing.Typer.usageTargetVar;
		var ef = hxc.typing.Typer.usageTargetEnumField;
		if (cf == null && v == null && ef == null) cf = usageFieldAtDeclaration(ctx);
		if (cf == null && v == null && ef == null) return [];
		var out:Array<Position> = [];
		function walk(e:hxc.core.Type.TExpr):Void {
			switch (e.expr) {
				case TField(_, FAnon(cf2) | FInstance(_, _, cf2) | FStatic(_, cf2) | FClosure(_, cf2)) if (cf != null && cf2 == cf): out.push(e.pos);
				case TField(_, FEnum(_, ef2)) if (ef != null && ef2 == ef): out.push(e.pos);
				case TLocal(v2) if (v != null && v2 == v): out.push(e.pos);
				case TNew(c2, _, _) if (cf != null && c2.constructor == cf): out.push(e.pos);
				case _:
			}
			hxc.core.TexprTools.iter(walk, e);
		}
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c):
				var all = c.orderedFields.concat(c.orderedStatics);
				if (c.constructor != null) all.push(c.constructor);
				for (f in all) if (f.expr != null) walk(f.expr);
			case _:
		}
		out.sort(function(a, b) {
			if (a.file != b.file) return a.file < b.file ? -1 : 1;
			return a.min - b.min;
		});
		return out;
	}

	// A hover on a field declaration name has no enclosing expression; the typed field's signature is
	// the result.
	static function hoverOnFieldName(ctx:Context):Null<{t:T, p:Position, cf:hxc.core.Type.TClassField, c:hxc.core.Type.TClass, scope:hxc.core.Type.ClassFieldScope}> {
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c):
				function found(cf:hxc.core.Type.TClassField, scope:hxc.core.Type.ClassFieldScope) {
					var t = switch (cf.type) {
						case TLazy(r): TypeFunctions.lazyType(r);
						case t: t;
					};
					return {t: t, p: cf.namePos, cf: cf, c: c, scope: scope};
				}
				for (cf in c.orderedFields) if (hxc.typing.Typer.atHoverPos(cf.namePos)) return found(cf, CFSMember);
				for (cf in c.orderedStatics) if (hxc.typing.Typer.atHoverPos(cf.namePos)) return found(cf, CFSStatic);
				if (c.constructor != null && hxc.typing.Typer.atHoverPos(c.constructor.namePos)) return found(c.constructor, CFSConstructor);
			case _:
		}
		return null;
	}

	// Import status: resolve the bare type name in the display file's module; the same path reads Imported,
	// a different one Shadowed, none Unimported.
	static function displayModule(ctx:Context):Null<hxc.core.Type.ModuleDef> {
		var df = hxc.parser.Parser.displayFile;
		if (df == null) return null;
		function norm(f:String):String {
			var full = try FileSystem.fullPath(f) catch (_:Dynamic) f;
			return StringTools.replace(full, "\\", "/").toLowerCase();
		}
		var want = norm(df);
		for (key in ctx.moduleLut.keys()) {
			var m = ctx.moduleLut.get(key);
			if (m.extra == null || m.extra.file == null) continue;
			if (norm(m.extra.file) == want) return m;
		}
		return null;
	}

	static function importStatusFor(ctx:Context, curMod:Null<hxc.core.Type.ModuleDef>, path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus {
		var mt = curMod == null ? null
			: try hxc.context.ModuleLoader.resolveBareType(ctx, curMod, path.name, Position.nullPos) catch (_:Dynamic) null;
		// The implicit StdTypes import and root modules resolve through the loader
		// (ModuleLoader.loadTypeDef).
		if (mt == null)
			mt = try hxc.context.ModuleLoader.loadTypeDef(ctx, {pack: [], name: path.name}, Position.nullPos) catch (_:Dynamic) null;
		if (mt == null) return Unimported;
		var got = TypeFunctions.tInfos(mt).path;
		return got.name == path.name && got.pack.join(".") == path.pack.join(".") ? Imported : Shadowed;
	}

	// Signatures as JSON: {activeSignature, activeParameter (the argument index with the trailing-Rest
	// clamp), signatures ([documentation?, args, ret] per signature), kind}.
	static function jsonSignature(ctx:Context):String {
		var sf = hxc.typing.Typer.signatureFound;
		if (sf == null) return jsonRpcAnswer(ctx, "null");
		var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t:T):hxc.core.Json.JsonValue
			return hxc.core.CompletionItem.CompletionTypeTools.toJson(gen,
				hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t));
		function isRest(t:T):Bool {
			return switch (TypeFunctions.follow(t)) {
				case TAbstract(a, _): a.path.pack.join(".") == "haxe" && a.path.name == "Rest";
				case _: false;
			};
		}
		function argIndex(args:Array<hxc.core.Type.TSignatureArg>, paramIndex:Int):Int {
			var index = 0;
			for (i in 0...args.length) {
				if (index == paramIndex) return paramIndex;
				if (i == args.length - 1 && index < paramIndex && isRest(args[i].t)) return index;
				index++;
			}
			return paramIndex;
		}
		var signatures:Array<hxc.core.Json.JsonValue> = [];
		for (s in sf.sigs) {
			var fields:Array<hxc.core.Json.JsonField> = [];
			if (s.doc != null) fields.push({name: "documentation", value: hxc.core.Json.JsonValue.JString(hxc.ast.Ast.genDocText(s.doc))});
			fields.push({name: "args", value: hxc.core.Json.JsonValue.JArray([for (a in s.args)
				hxc.core.Json.JsonValue.JObject([
					{name: "name", value: hxc.core.Json.JsonValue.JString(a.name)},
					{name: "opt", value: hxc.core.Json.JsonValue.JBool(a.opt)},
					{name: "t", value: ct(a.t)},
					{name: "value", value: hxc.core.Json.JsonValue.JNull}
				])])});
			fields.push({name: "ret", value: ct(s.ret)});
			signatures.push(hxc.core.Json.JsonValue.JObject(fields));
		}
		var active = sf.sigs.length == 0 ? sf.activeArg : argIndex(sf.sigs[0].args, sf.activeArg);
		var result = hxc.core.Json.JsonValue.JObject([
			{name: "activeSignature", value: hxc.core.Json.JsonValue.JInt(0)},
			{name: "activeParameter", value: hxc.core.Json.JsonValue.JInt(active)},
			{name: "signatures", value: hxc.core.Json.JsonValue.JArray(signatures)},
			{name: "kind", value: hxc.core.Json.JsonValue.JInt(0)}
		]);
		return jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(result));
	}

	// Unwrap monomorphs, lazies and Null wrappers, then the named module type's declaration position;
	// anything unnamed (functions, structures, unbound monomorphs) answers the null position.
	static function typeDefinitionPos(t:T):Null<Position> {
		function followNull(t:T):Null<T> {
			return switch (t) {
				case TMono(r): r.type == null ? null : followNull(r.type);
				case TLazy(f): followNull(TypeFunctions.lazyType(f));
				case TAbstract(a, [t1]) if (a.path.pack.length == 0 && a.path.name == "Null"): followNull(t1);
				case _: t;
			};
		}
		var t2 = followNull(t);
		if (t2 == null) return null;
		return switch (t2) {
			case TInst(c, _): c.namePos;
			case TEnum(en, _): en.namePos;
			case TType(td, _): td.namePos;
			case TAbstract(a, _): a.namePos;
			case _: null;
		};
	}

	// The completion response over the typed entries the field-completion collector recorded.
	static function jsonCompletion(ctx:Context):Null<String> {
		var jc = hxc.typing.Typer.jsonFieldCompletion;
		if (jc == null) return null;
		var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t);
		function classDecl(c:hxc.core.Type.TClass):hxc.core.Type.ModuleType {
			return switch (c.kind) {
				case KAbstractImpl(a): TAbstractDecl(a);
				case _: TClassDecl(c);
			};
		}
		var entries = jc.entries.copy();
		entries.sort(function(a, b) return a.cf.name < b.cf.name ? -1 : a.cf.name > b.cf.name ? 1 : 0);
		var items:Array<hxc.core.Json.JsonValue> = [];
		for (i in 0...entries.length) {
			var e = entries[i];
			var origin = e.builtIn ? hxc.core.CompletionItem.ClassFieldOrigin.BuiltIn
				: e.originAnon != null ? hxc.core.CompletionItem.ClassFieldOrigin.AnonymousStructure(e.originAnon)
				: e.originClass != null ? hxc.core.CompletionItem.ClassFieldOrigin.Self(classDecl(e.originClass))
				: hxc.core.CompletionItem.ClassFieldOrigin.Unknown;
			var t = switch (e.cf.type) {
				case TLazy(r): TypeFunctions.lazyType(r);
				case t: t;
			};
			items.push(hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, e.scope, e.cf, origin, true, ct(t), i));
		}
		// The Field completion mode: the receiver item, receiver range, iterator and keyValueIterator, plus
		// the receiver's module-type block when its type names one.
		var modeArgs:Array<hxc.core.Json.JsonField> = [];
		if (jc.receiver != null) {
			var recv = jc.receiver;
			modeArgs.push({name: "item", value: itemForTypedExpr(ctx, gen, recv, recv.type)});
			modeArgs.push({name: "range", value: gen.generatePosAsRange(recv.pos)});
			modeArgs.push({name: "iterator", value: hxc.core.Json.JsonValue.JNull});
			modeArgs.push({name: "keyValueIterator", value: hxc.core.Json.JsonValue.JNull});
			var followed = TypeFunctions.follow(recv.type);
			var mt:Null<hxc.core.Type.ModuleType> = switch (followed) {
				case TInst(c, _): classDecl(c);
				case TEnum(en, _): TEnumDecl(en);
				case TAbstract(a, _): TAbstractDecl(a);
				case _: null;
			};
			if (mt != null) {
				modeArgs.push({name: "type", value: hxc.core.CompletionItem.CompletionTypeTools.toJson(gen, ct(recv.type))});
				modeArgs.push({name: "moduleType", value: gen.generateModuleType(mt)});
				modeArgs.push({name: "moduleTypeFollowed", value: recv.type == followed ? hxc.core.Json.JsonValue.JNull : gen.generateModuleType(mt)});
			}
		}
		var mode = hxc.core.Json.JsonValue.JObject([
			{name: "kind", value: hxc.core.Json.JsonValue.JInt(0)},
			{name: "args", value: hxc.core.Json.JsonValue.JObject(modeArgs)}
		]);
		var off = hxc.parser.Parser.displayOffset;
		var insertPos = new Position(hxc.parser.Parser.displayFile, off, off);
		var result = hxc.core.Json.JsonValue.JObject([
			{name: "items", value: hxc.core.Json.JsonValue.JArray(items)},
			{name: "isIncomplete", value: hxc.core.Json.JsonValue.JBool(false)},
			{name: "mode", value: mode},
			{name: "filterString", value: hxc.core.Json.JsonValue.JString("")},
			{name: "replaceRange", value: gen.generatePosAsRange(insertPos)}
		]);
		return jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(result));
	}

	// The hover item built from a captured typed expression; shared by hover and the
	// completion mode's receiver item.
	static function itemForTypedExpr(ctx:Context, gen:hxc.core.Genjson, e:hxc.core.Type.TExpr, t:T):hxc.core.Json.JsonValue {
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t2:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t2);
		function classDecl(c:hxc.core.Type.TClass):hxc.core.Type.ModuleType {
			return switch (c.kind) {
				case KAbstractImpl(a): TAbstractDecl(a);
				case _: TClassDecl(c);
			};
		}
		var item:Null<hxc.core.Json.JsonValue> = null;
		switch (e.expr) {
			case TField(e1, fa):
				switch (fa) {
					case FStatic(c, cf):
						item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSStatic, cf, Self(classDecl(c)), true, ct(t));
					case FInstance(c, _, cf):
						item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSMember, cf, Self(classDecl(c)), true, ct(t));
					case FClosure(cwp, cf):
						var origin = if (cwp != null) hxc.core.CompletionItem.ClassFieldOrigin.Self(classDecl(cwp.c))
							else switch (TypeFunctions.follow(e1.type)) {
								case TAnon(an): hxc.core.CompletionItem.ClassFieldOrigin.AnonymousStructure(an);
								case _: hxc.core.CompletionItem.ClassFieldOrigin.Unknown;
							};
						item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSMember, cf, origin, true, ct(t));
					case FAnon(cf):
						var origin = switch (TypeFunctions.follow(e1.type)) {
							case TAnon(an): hxc.core.CompletionItem.ClassFieldOrigin.AnonymousStructure(an);
							case _: hxc.core.CompletionItem.ClassFieldOrigin.Unknown;
						};
						item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSMember, cf, origin, true, ct(t));
					case FEnum(en, ef):
						item = hxc.core.CompletionItem.CompletionItem.enumFieldToJson(gen, ef, Self(TEnumDecl(en)), true, ct(t));
					case FDynamic(_):
				}
			case TLocal(v):
				item = hxc.core.CompletionItem.CompletionItem.localToJson(gen, v, ct(t));
			case TNew(c, _, _) if (c.constructor != null):
				item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSConstructor, c.constructor, Self(classDecl(c)), true, ct(t));
			case _:
		}
		if (item == null) item = hxc.core.CompletionItem.CompletionItem.expressionToJson(gen, ct(t));
		return item;
	}

	// Hover as JSON: {documentation, range, item, expected}.
	static function jsonHover(ctx:Context):Null<String> {
		var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t);
		function classDecl(c:hxc.core.Type.TClass):hxc.core.Type.ModuleType {
			return switch (c.kind) {
				case KAbstractImpl(a): TAbstractDecl(a);
				case _: TClassDecl(c);
			};
		}
		var item:Null<hxc.core.Json.JsonValue> = null;
		var rangePos:Null<Position> = null;
		var doc:hxc.ast.Ast.Documentation = null;
		var h = hxc.typing.Typer.hoverFound;
		if (h != null) {
			rangePos = h.p;
			if (h.e != null) switch (h.e.expr) {
				case TField(e1, fa):
					switch (fa) {
						case FStatic(c, cf):
							doc = cf.doc;
							item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSStatic, cf, Self(classDecl(c)), true, ct(h.t));
						case FInstance(c, _, cf):
							doc = cf.doc;
							item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSMember, cf, Self(classDecl(c)), true, ct(h.t));
						case FClosure(cwp, cf):
							doc = cf.doc;
							var origin = if (cwp != null) hxc.core.CompletionItem.ClassFieldOrigin.Self(classDecl(cwp.c))
								else switch (TypeFunctions.follow(e1.type)) {
									case TAnon(an): hxc.core.CompletionItem.ClassFieldOrigin.AnonymousStructure(an);
									case _: hxc.core.CompletionItem.ClassFieldOrigin.Unknown;
								};
							item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSMember, cf, origin, true, ct(h.t));
						case FAnon(cf):
							doc = cf.doc;
							var origin = switch (TypeFunctions.follow(e1.type)) {
								case TAnon(an): hxc.core.CompletionItem.ClassFieldOrigin.AnonymousStructure(an);
								case _: hxc.core.CompletionItem.ClassFieldOrigin.Unknown;
							};
							item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSMember, cf, origin, true, ct(h.t));
						case FEnum(en, ef):
							doc = ef.doc;
							item = hxc.core.CompletionItem.CompletionItem.enumFieldToJson(gen, ef, Self(TEnumDecl(en)), true, ct(h.t));
						case FDynamic(_):
					}
				case TLocal(v):
					item = hxc.core.CompletionItem.CompletionItem.localToJson(gen, v, ct(h.t));
				case TNew(c, _, _) if (c.constructor != null):
					doc = c.constructor.doc;
					item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSConstructor, c.constructor, Self(classDecl(c)), true, ct(h.t));
				case _:
			}
			if (item == null) item = hxc.core.CompletionItem.CompletionItem.expressionToJson(gen, ct(h.t));
		} else {
			var hf = hoverOnFieldName(ctx);
			if (hf == null) return null;
			rangePos = hf.p;
			doc = hf.cf.doc;
			item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, hf.scope, hf.cf, Self(classDecl(hf.c)), true, ct(hf.t));
		}
		var result = hxc.core.Json.JsonValue.JObject([
			{name: "documentation", value: doc == null ? hxc.core.Json.JsonValue.JNull : hxc.core.Json.JsonValue.JString(hxc.ast.Ast.genDocText(doc))},
			{name: "range", value: gen.generatePosAsRange(rangePos)},
			{name: "item", value: item},
			{name: "expected", value: hxc.core.Json.JsonValue.JNull}
		]);
		return jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(result));
	}

	// The report covers only the requested display file (plus fileless positions).
	static function isDiagnosticsFile(ctx:Context, pfile:String):Bool {
		var parts = displayParts(ctx);
		if (parts.length == 0) return true;
		if (pfile == "?") return true;
		var want = try FileSystem.fullPath(parts[0]) catch (_:Dynamic) parts[0];
		var got = try FileSystem.fullPath(pfile) catch (_:Dynamic) pfile;
		return want.toLowerCase() == got.toLowerCase();
	}

	// Through the ported serializer.
	static function jsonLocation(p:Position):String {
		return hxc.core.Json.stringOfJson(new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull).generatePosAsLocation(p));
	}

	// The protocol envelope around a report-time answer.
	static function jsonRpcAnswer(ctx:Context, resultJson:String):String {
		return '{"jsonrpc":"2.0","id":' + ctx.jsonRpcId + ',"result":{"result":' + resultJson + ',"timestamp":' + Sys.time() + '}}';
	}

	static function diagnosticsAbort(ctx:Context, message:String, pos:Position, kind:Int, depth:Int = 0):Void {
		ctx.diagnostics.push({message: message, pos: pos, depth: depth, severity: MessageSeverity.Error, kind: kind});
		displayDiagnostics(ctx);
	}

	static function displayDiagnostics(ctx:Context):Void {
		var groups:Array<{file:String, items:Array<String>}> = [];
		for (d in ctx.diagnostics) {
			if (!isDiagnosticsFile(ctx, d.pos.file)) continue;
			var i = Position.getInfos(d.pos);
			var displayFile = d.pos.file;
			if (displayFile != "?" && !StringTools.startsWith(displayFile, "/") && displayFile.indexOf(":") != 1)
				displayFile = FileSystem.fullPath(displayFile);
			var severity = switch (d.severity) {
				case Information: 3;
				case Warning: 2;
				case Error: 1;
				case Hint: 4;
			};
			var kind = d.kind == null ? 2 : d.kind;
			var args = haxe.Json.stringify(d.message);
			var item = '{"kind":' + kind + ',"severity":' + severity
				+ ',"range":{"start":{"line":' + (i.line - 1) + ',"character":' + i.column
				+ '},"end":{"line":' + (i.endLine - 1) + ',"character":' + i.endColumn
				+ '}},"args":' + args + ',"relatedInformation":[]}';
			var group = null;
			for (g in groups) if (g.file == displayFile) { group = g; break; }
			if (group == null) { group = {file: displayFile, items: []}; groups.push(group); }
			group.items.push(item);
		}
		var out = [for (g in groups) '{"file":' + haxe.Json.stringify(g.file) + ',"diagnostics":[' + g.items.join(",") + ']}'];
		var raw = "[" + out.join(",") + "]";
		// A JSON-RPC-initiated diagnostics run answers with the protocol envelope; the legacy arg prints
		// the raw array. No trailing newline: the raw print.
		if (ctx.jsonRpcId != null)
			raw = jsonRpcAnswer(ctx, raw);
		Sys.stderr().writeString(raw);
	}

	static function displaySignature(ctx:Context):Void {
		var parts = displayParts(ctx);
		var file = parts.length > 0 ? parts[0] : "";
		var offset = parts.length > 1 ? Std.parseInt(parts[1]) : null;
		var identifier = "";
		var sourceDocumentation:Null<String> = null;
		if (offset != null) {
			var sourceFile = file;
			if (!FileSystem.exists(sourceFile)) for (m in ctx.modules) if (StringTools.endsWith(m.extra.file, file)) { sourceFile = m.extra.file; break; }
			if (FileSystem.exists(sourceFile)) {
				var source = File.getContent(sourceFile);
				function identChar(c:Int):Bool return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
				var cursor = offset;
				while (cursor > 0 && !identChar(source.charCodeAt(cursor))) cursor--;
				var start = cursor;
				while (start > 0 && identChar(source.charCodeAt(start - 1))) start--;
				var end = cursor;
				while (end < source.length && identChar(source.charCodeAt(end))) end++;
				identifier = source.substr(start, end - start);
				var decl = source.indexOf("function " + identifier);
				var open = decl < 0 ? -1 : source.lastIndexOf("/**", decl);
				var close = open < 0 ? -1 : source.indexOf("**/", open + 3);
				if (open >= 0 && close >= 0 && close < decl) sourceDocumentation = source.substr(open + 3, close - open - 3);
			}
		}
		var field:TClassField = null;
		if (offset != null) for (mt in ctx.types) switch (mt) {
			case TClassDecl(c):
				for (cf in c.orderedStatics.concat(c.orderedFields))
					if ((identifier == "" ? (cf.pos.max >= offset && cf.pos.min <= offset) : cf.name == identifier)
						&& (identifier != "" || StringTools.endsWith(cf.pos.file, file) || StringTools.endsWith(cf.pos.file, StringTools.replace(file, "/", "\\")))) field = cf;
			case _:
		}
		var sigs = [];
		if (field != null) switch (TypeFunctions.follow(field.type)) {
			case TFun(sig):
				var args:Array<String> = [];
				for (a in sig.args) args.push((a.opt ? "?" : "") + a.name + ":" + TPrinting.sTypeStr(a.t));
				var label = "(" + args.join(", ") + "):" + TPrinting.sTypeStr(sig.ret);
				var params = [for (a in sig.args) '{"label":' + haxe.Json.stringify((a.opt ? "?" : "") + a.name + ":" + TPrinting.sTypeStr(a.t)) + '}'];
				var docText = field.doc == null ? sourceDocumentation : Ast.genDocText(field.doc);
				var doc = docText == null ? "" : ',"documentation":' + haxe.Json.stringify(docText);
				sigs.push('{' + (doc == "" ? "" : doc.substr(1)) + (doc == "" ? "" : ",") + '"label":' + haxe.Json.stringify(label) + ',"parameters":[' + params.join(",") + ']}');
			case _:
		}
		if (sigs.length == 0) sigs.push('{"label":"():Void","parameters":[]}');
		Sys.stderr().writeString('{"signatures":[' + sigs.join(",") + '],"activeParameter":0,"activeSignature":0}\n');
	}

	// List the module's public types, plus the main type's public statics when completing an import.
	static function handleTypePathCompletion(ctx:Context, tc:hxc.parser.Parser.TypePathCompletion):Void {
		// Reset the display position so loading the module does not raise again (#6558).
		hxc.parser.Parser.displayOffset = -1;
		var fields:Array<hxc.compiler.DisplayXml.DisplayField> = [];
		if (tc.module != null) {
			// An uppercase last pack segment names the module and tc.module a subtype of it
			// sl_pack/s_module split).
			var pack = tc.pack.copy();
			var sModule = tc.module;
			if (pack.length > 0) {
				var lastPack = pack[pack.length - 1];
				if (lastPack.charCodeAt(0) >= "A".code && lastPack.charCodeAt(0) <= "Z".code) {
					sModule = lastPack;
					pack = pack.slice(0, pack.length - 1);
				}
			}
			var m = try ModuleLoader.loadModule(ctx, {pack: pack, name: sModule}, Position.nullPos) catch (e:Dynamic) {
				printPositionMessage("Could not load module " + Context.sTypePath({pack: tc.pack, name: tc.module}), Position.nullPos);
				Sys.exit(1);
				return;
			};
			try TypeFields.typeAllModules(ctx) catch (_:Dynamic) {}
			for (mt in m.types) {
				var info = hxc.core.TypeFunctions.tInfos(mt);
				if (info.isPrivate) continue;
				if (tc.module == sModule)
					fields.push({kind: "type", name: info.path.name, type: Context.sTypePath(info.path), doc: null});
				if (tc.isImport && info.path.name == tc.module) switch (mt) {
					case TClassDecl(c):
						for (cf in c.orderedStatics) {
							if (!hxc.core.TypeFunctions.hasClassFieldFlag(cf, CfPublic)) continue;
							var kind = cf.kind.match(Method(_)) ? "method" : "var";
							fields.push({kind: kind, name: cf.name, type: TPrinting.sTypeStr(cf.type), doc: cf.doc == null ? null : Ast.genDocText(cf.doc)});
						}
					case TEnumDecl(en):
						for (name in en.constrs.keys()) {
							var ef = en.constrs.get(name);
							var kind = hxc.core.TypeFunctions.follow(ef.type).match(TFun(_)) ? "method" : "var";
							fields.push({kind: kind, name: ef.name, type: TPrinting.sTypeStr(ef.type), doc: ef.doc == null ? null : Ast.genDocText(ef.doc)});
						}
					case _:
				}
			}
		} else {
			// A pure package prefix lists the package's modules and sub-packages across the classpaths. .
			var seen = new haxe.ds.StringMap<Bool>();
			for (cp in ctx.classPath) {
				var dir = cp + tc.pack.join("/");
				if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) continue;
				for (entry in try FileSystem.readDirectory(dir) catch (_:Dynamic) []) {
					if (seen.exists(entry)) continue;
					var full = dir + "/" + entry;
					if (StringTools.endsWith(entry, ".hx")) {
						var name = entry.substr(0, entry.length - 3);
						if (name.length > 0 && name.charCodeAt(0) >= "A".code && name.charCodeAt(0) <= "Z".code) {
							seen.set(entry, true);
							fields.push({kind: "type", name: name, type: "", doc: null});
						}
					} else if (FileSystem.isDirectory(full) && entry.length > 0
							&& entry.charCodeAt(0) >= "a".code && entry.charCodeAt(0) <= "z".code) {
						seen.set(entry, true);
						fields.push({kind: "package", name: entry, type: "", doc: null});
					}
				}
			}
		}
		Sys.stderr().writeString(hxc.compiler.DisplayXml.printFields(fields));
	}

	// Each metadata argument whose span encloses the display position types as an expression; failures
	// are ignored so a half-written path still reaches its completion raise.
	static function checkDisplayMetadata(ctx:Context):Void {
		for (key in ctx.moduleLut.keys()) {
			var m = ctx.moduleLut.get(key);
			for (mt in m.types) {
				var inf = hxc.core.TypeFunctions.tInfos(mt);
				var metas = [inf.meta];
				switch (mt) {
					case TClassDecl(c):
						for (cf in c.orderedStatics) metas.push(cf.meta);
						for (name in c.fields.keys()) metas.push(c.fields.get(name).meta);
					case _:
				}
				for (ml in metas) for (entry in ml) for (arg in entry.params) {
					if (!hxc.typing.Typer.atDisplayPos(arg.pos)) continue;
					var tctx = new hxc.typing.TyperContext(ctx);
					switch (mt) {
						case TClassDecl(c):
							tctx.curclass = c;
							tctx.typeParams = c.params;
						case _:
					}
					try hxc.typing.Typer.typeExpr(tctx, arg, hxc.core.WithType.WithTypeTools.value)
					catch (_:hxc.core.TypingError) {} catch (_:hxc.context.Context.ContextError) {}
				}
			}
		}
	}

	static function isDisplay(ctx:Context, mode:String):Bool {
		var parts = displayParts(ctx);
		return parts.length >= 3 && parts[2] == mode;
	}

	static function abortOnDiagnostics(ctx:Context, platform:Platform):Void {
		// Messages accumulate to one flush at the end, so a later macro callback can still read and
		// filter them; an abort prints what has accumulated and exits. Validation of -D message.reporting
		// adds an error for an invalid mode even with no other messages.
		hxc.compiler.Messages.validateModes(ctx);
		if (!ctx.hasError()) return;
		hxc.compiler.Messages.display(ctx);
		ctx.diagnostics = [];
		Sys.exit(1);
	}

	static function expandArgs(args:Array<String>):Array<String> {
		return expandArgsInner(args, []);
	}

	static function expandArgsInner(args:Array<String>, seen:Array<String>):Array<String> {
		var out:Array<String> = [];
		var i = 0;
		var libs:Array<String> = [];
		while (i < args.length) {
			var a = args[i++];
			if (!StringTools.startsWith(a, "-") && StringTools.endsWith(a, ".hxml")) {
				out = out.concat(expandHxml(a, seen));
				continue;
			}
			if (a == "-lib" || a == "--library") {
				if (i >= args.length) throw "Missing library name";
				libs.push(args[i++]);
				continue;
			}
			out.push(a);
		}
		// All libraries resolve through one haxelib call whose output appends after the other arguments.
		// .
		if (libs.length > 0) out = out.concat(expandHaxelibs(libs, seen));
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

	static function expandHaxelibs(libs:Array<String>, seen:Array<String>):Array<String> {
		// The hxcpp host's spawn intermittently fails outright under load; one retry covers it.
		var p = try new Process("haxelib", ["path"].concat(libs)) catch (_:Dynamic) {
			Sys.sleep(0.1);
			new Process("haxelib", ["path"].concat(libs));
		};
		var stdout = p.stdout.readAll().toString();
		var stderr = p.stderr.readAll().toString();
		var code = p.exitCode();
		p.close();
		if (code != 0) {
			// Distinguish a missing haxelib from its own error output.
			if (StringTools.trim(stdout) == "" && StringTools.trim(stderr) == "")
				throw "Failed to call haxelib (command not found ?)";
			throw StringTools.trim(stdout + (stdout != "" && stderr != "" ? "\n" : "") + stderr);
		}
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

	// A fatal error joins the message store before printing, so -D message.reporting picks the configured
	// formatter (every abort prints through it).
	static function abortWithMessage(ctx:Context, msg:String, pos:Position, depth:Int = 0):Void {
		ctx.raiseTypingErrors = false;
		ctx.addDiagnostic(msg, pos, depth);
		flushPendingMessages(ctx);
		Sys.exit(1);
	}

	static function printPositionMessage(msg:String, pos:Position):Void {
		// Classic message formatter: each continuation line gets a "... " prefix and repeats the position.
		var epos = Globals.getErrorPosRef(function(file, line) return '$file:$line:', pos);
		var lines = msg.split("\n");
		var parts = [lines[0]];
		for (i in 1...lines.length) parts.push("... " + lines[i]);
		Sys.stderr().writeString(epos + " : " + parts.join("\n" + epos + " : ") + "\n");
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
