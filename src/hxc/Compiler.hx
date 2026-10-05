package hxc;

import hxc.context.Context;
import hxc.context.Setup;
import hxc.context.ModuleLoader;
import hxc.typing.TypeResolve;
import hxc.typing.TypeFields;
import hxc.core.Globals;
import hxc.core.Globals.Platform;
import hxc.core.Globals.Path;
import hxc.core.Json.JsonValue;
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
	<flag value="-STACK:1073741824"/>
</linker>
<linker id="exe" if="emscripten">
	<flag value="-sALLOW_MEMORY_GROWTH=1"/>
	<flag value="-sSTACK_SIZE=67108864"/>
	<flag value="-sINITIAL_MEMORY=268435456"/>
	<flag value="-sFORCE_FILESYSTEM=1"/>
	<flag value="-sEXPORTED_RUNTIME_METHODS=[FS,callMain,ENV,NODEFS,MEMFS]"/>
	<flag value="-lnodefs.js"/>
	<flag value="-sMODULARIZE=1"/>
	<flag value="-sEXPORT_NAME=createHxc"/>
	<flag value="-sINVOKE_RUN=0"/>
	<flag value="--preload-file" if="HXC_WASM_PRELOAD_STD"/>
	<flag value="${HXC_WASM_STD_DIR}@/std" if="HXC_WASM_PRELOAD_STD"/>
	<flag value="--preload-file" if="HXC_WASM_PRELOAD_LIBS"/>
	<flag value="${HXC_WASM_OPENFL_DIR}@/libs/openfl" if="HXC_WASM_PRELOAD_LIBS"/>
	<flag value="--preload-file" if="HXC_WASM_PRELOAD_LIBS"/>
	<flag value="${HXC_WASM_LIME_DIR}@/libs/lime" if="HXC_WASM_PRELOAD_LIBS"/>
</linker>
')
// Unwinds an in-process wait-server request on a path that would exit the one-shot process (the
// server keeps serving after a failed compile). The argument callback runs outside an option
// handler, so a failure there reaches the top-level handler as a plain failure and is reported
// without the option parser's ": " ... "." framing.
private class ArgFailure extends haxe.Exception {}

private class RequestAbort extends haxe.Exception {
	public var code:Int;
	public function new(code:Int) { super("request abort " + code); this.code = code; }
}

// Abort unwinds compilation without adding a diagnostic.
private class CompileAbort extends haxe.Exception {
	public function new() super("abort");
}

class Compiler {
	// The aedifex program's entry constructs the class (ProgramMain), a plain build calls main(): both
	// start where the runtime's thread setup leaves the main thread, holding the runtime lock.
	public function new() {
		hxc.eval.EvalStdLib.gilEnter();
		run(Sys.args());
	}
	public static function main() {
		#if cpp
		// HXC_DBG_GC: measure how much of the wall clock is collection. "off" disables the collector for
		// the whole run (RSS grows unbounded, so one-shot compiles only); a number sets the target free
		// space percentage. DEBUG only.
		{
			var g = Sys.getEnv("HXC_DBG_GC");
			var wm = Sys.getEnv("HXC_DBG_GCWM");
			if (wm != null) {
				var mb = Std.parseInt(wm);
				if (mb != null) cpp.vm.Gc.setMinimumWorkingMemory(mb * 1024 * 1024);
			}
			if (g == "off") cpp.vm.Gc.enable(false);
			else if (g != null) {
				var pct = Std.parseInt(g);
				if (pct != null) cpp.vm.Gc.setTargetFreeSpacePercentage(pct);
			}
		}
		#end
		// The main thread holds the runtime lock from the start, and lets it go only in a blocking section
		// or at the tick's yield.
		hxc.eval.EvalStdLib.gilEnter();
		// A completion answer raised anywhere in a one-shot compilation is written to stderr and the
		// process exits 0.
		try run(Sys.args())
		catch (mj:hxc.context.DisplayJson.JsonDisplayOutput) Sys.stderr().writeString(mj.output)
		// The top-level handler wraps the whole compilation, argument processing included: a bad argument
		// and a plain failure both report "Error: " + msg at a NULL position, which prints with no
		// location prefix. Without it an argument failure escapes to the hxcpp runtime and prints in its
		// format ("Error : ..." with a stray space before the colon). The control-flow exceptions are
		// re-raised rather than reported; everything else, including a plain string raise, becomes one
		// reported message.
		catch (ra:RequestAbort) throw ra
		catch (af:ArgFailure) fatalArgError(af.message)
		catch (e:Dynamic) fatalArgError(Std.string(e));
	}

	static var argFailureCtx:Null<Context> = null;

	static function fatalArgError(msg:String, failure:Bool = true):Void {
		// A bad argument goes into the message list, which appends and leaves the flush to the end, so
		// anything an earlier argument queued (the --version line, a --help-defines dump) still prints,
		// and prints first. Writing straight to stderr would lose all of that. Any exception but a
		// failure or a bad argument prints unprefixed.
		var text = (failure ? "Error: " : "") + msg;
		var ctx = argFailureCtx;
		if (ctx != null) {
			ctx.addDiagnostic(text, Position.nullPos);
			flushPendingMessages(ctx);
		} else {
			Sys.stderr().writeString(text + "\n");
		}
		hxc.compiler.HostRuntime.exit(1);
	}

	// The wait loop: length-prefixed request/response over stdin/stderr; each request is one
	// compilation. Reset the per-request mutable statics so a wait-server request compiles like a
	// fresh process. The deliberately persistent set is untouched: Position.fileCache (the global file
	// table), DisplayJson's configure switches and CompilationCache (server state),
	// Context.nextStoredTypedExprId (module-global). When set, request-scoped answers (display JSON,
	// protocol errors) collect here instead of the process stderr, so the wait server can frame them.
	// Null outside in-process request execution.
	public static var requestOutput:Null<hxc.compiler.RequestOutput> = null;
	// The request's messages went out as its json-rpc error (Messages.display), which counts as a
	// completion answer: no failure marker follows.
	public static var jsonErrorSent:Bool = false;

	// STDOUT content produced during a server request (macro trace/print) joins the response channel, each
	// write encoded as "\x01" + s with every "\n" turned into an "\x01" continuation + a trailing "\n".
	// Returns false outside a request so the caller falls back to the real stdout.
	public static function serverPrint(s:String):Bool {
		if (requestOutput == null) return false;
		var b = haxe.io.Bytes.ofString(s);
		requestOutput.writeOut(b, 0, b.length);
		return true;
	}

	public static function resetForNextRequest():Void {
		hxc.typing.Typer.resetPerRequest();
		hxc.typing.TypeFields.resetPerRequest();
		hxc.typing.Typeload.resetPerRequest();
		hxc.parser.Parser.resetPerRequest();
		hxc.context.ModuleLoader.resetPerRequest();
		hxc.eval.EvalMacro.resetPerRequest();
		hxc.context.ServerCache.resetRequest();
		hxc.filters.DeprecationCheck.resetPerRequest();
		// The usage flags belong to one request (each json call sets them); the legacy @usage lane never
		// sets them, so they must not survive a json one.
		hxc.context.DisplayJson.usageDescendants = false;
		hxc.context.DisplayJson.usageBase = false;
		hxc.ast.Position.resetFileCache();
		hxc.compiler.Diagnostics.reset();
	}

	static function runWaitStdio():Void {
		hxc.core.BinaryStdio.setStdin();
		runWaitLoop(Sys.stdin(), Sys.stderr());
	}

	// The STARTUP arguments are parsed before entering the wait loop, so a --cwd given when the server was
	// launched is in effect for every request that follows; each request's own paths are then relative to
	// it.
	static function applyStartupArgs(args:Array<String>):Void {
		var i = 0;
		while (i < args.length) {
			var a = args[i++];
			if ((a == "--cwd" || a == "-C") && i < args.length) {
				var dir = args[i++];
				hxc.core.Cwd.set(dir);
			}
			// A verbose startup turns on every server message.
			if (a == "-v" || a == "--verbose") hxc.compiler.ServerMessage.enableAll();
		}
	}

	// --server-connect dials the given port and then runs the same request loop, since a socket is
	// framed exactly as stdin/stderr are. Only the endpoints differ.
	static function runWaitConnect(hostPort:String):Void {
		// "host:port", or a bare port on 127.0.0.1.
		var host = "127.0.0.1";
		var portStr = hostPort;
		var colon = hostPort.indexOf(":");
		if (colon >= 0) {
			host = hostPort.substr(0, colon);
			portStr = hostPort.substr(colon + 1);
		}
		var port = Std.parseInt(portStr);
		if (port == null) {
			Sys.stderr().writeString("Invalid port\n");
			hxc.compiler.HostRuntime.exit(1);
		}
		var sock = new sys.net.Socket();
		try sock.connect(new sys.net.Host(host), port) catch (e:Dynamic) {
			Sys.stderr().writeString("Couldn't connect on " + host + ":" + port + "\n");
			hxc.compiler.HostRuntime.exit(1);
		}
		runWaitLoop(sock.input, sock.output);
		try sock.close() catch (_:Dynamic) {}
	}


	// HXC_DBG_LIVEMEM=<file>: after each request, a full collection and then the live heap in KB, appended
	// to the file as `<request> <kb>`. The working set only ever grows, so the live heap is what shows a
	// leak.
	static var liveMemFile:Null<String> = Sys.getEnv("HXC_DBG_LIVEMEM");

	static function recordLiveMem():Void {
		cpp.vm.Gc.run(true);
		var out = sys.io.File.append(liveMemFile, false);
		out.writeString(censusCount + " " + Std.int(cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE) / 1024) + "\n");
		out.close();
	}

	// HXC_DBG_STATICCENSUS=N: a static-root census every N requests (HeapCensus.staticCensus).
	static var censusCount = 0;
	static var censusEvery:Int = {
		var v = Sys.getEnv("HXC_DBG_STATICCENSUS");
		v == null ? 0 : Std.parseInt(v);
	};

	// The wait loop's catch-all: a read that runs out of input fails with an end-of-input error, which is
	// reported (ServerMessage.uncaughtError) and answered as "\x02\n" + estr in the connection's own frame
	// before the loop waits again.
	// At stdin EOF every read fails the same way, so the server answers forever and never exits.
	static function answerNoMoreInput(stderr:haxe.io.Output):Void {
		var estr = "IO.No_more_input";
		hxc.compiler.ServerMessage.uncaughtError(estr);
		var body = haxe.io.Bytes.ofString("\x02\n" + estr);
		var head = haxe.io.Bytes.alloc(4);
		head.set(0, body.length & 0xFF);
		head.set(1, (body.length >> 8) & 0xFF);
		head.set(2, (body.length >> 16) & 0xFF);
		head.set(3, (body.length >> 24) & 0xFF);
		Sys.stdout().flush();
		stderr.write(head);
		stderr.write(body);
		stderr.flush();
	}

	static function runWaitLoop(stdin:haxe.io.Input, stderr:haxe.io.Output):Void {
		hxc.context.ServerCache.cacheMode = true;
		while (true) {
			// The connection is read with the interpreter lock released, so the interpreter's threads run
			// while the server waits for a request.
			var released = hxc.eval.EvalStdLib.gilRelease();
			var frame:Null<haxe.io.Bytes> = try {
				var b0 = stdin.readByte();
				var b1 = stdin.readByte();
				var b2 = stdin.readByte();
				var b3 = stdin.readByte();
				stdin.read(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24));
			} catch (_:haxe.io.Eof) null;
			if (released) hxc.eval.EvalStdLib.gilReacquire();
			if (frame == null) {
				answerNoMoreInput(stderr);
				continue;
			}
			var payload = frame.toString();
			// A \x01 byte splits the request: arguments before it, the display file's source after it
			// (cleared again after the request).
			var sep = payload.indexOf("\x01");
			if (sep >= 0) {
				hxc.context.ModuleLoader.currentStdin = payload.substr(sep + 1);
				payload = payload.substr(0, sep);
			} else {
				hxc.context.ModuleLoader.currentStdin = null;
			}
			// The argument text is hxml, not one raw argument per line: blank and # lines drop out, quotes
			// come off, and a flag line splits at its first space.
			var lines:Array<String> = [];
			for (line in payload.split("\n")) lines = lines.concat(parseHxmlLine(line));
			// Log request arguments before any other verbose output.
			hxc.compiler.ServerMessage.arguments(lines);
			var out = new StringBuf();
			// The stateful cache methods answer in the server process itself so cache state (contexts,
			// removed files, configure switches) persists across requests; compilations still run isolated
			// per request.
			var displayArg:Null<String> = null;
			for (i in 0...lines.length)
				if (lines[i] == "--display" && i + 1 < lines.length
						&& (StringTools.startsWith(lines[i + 1], "{") || StringTools.startsWith(lines[i + 1], "[")))
					displayArg = lines[i + 1];
			var parentMethod = false;
			if (displayArg != null) {
				var m = ~/"method"[ 	]*:[ 	]*"([^"]+)"/;
				if (m.match(displayArg)) {
					var name = m.matched(1);
					// Display/metadata and display/defines are not answered before the compilation. They register
					// an after-init-macros callback, because a -lib brings its documentation in through --macro
					// register*DescriptionFile. server/readClassPaths also runs inside a compilation, so its
					// context is the request's own define signature.
					parentMethod = (name == "initialize" || StringTools.startsWith(name, "server/"))
						&& name != "server/readClassPaths";
				}
			}
			if (parentMethod) {
				try {
					hxc.context.DisplayJson.parseInput(null, displayArg);
				} catch (o:hxc.context.DisplayJson.JsonDisplayOutput) {
					// Print the response verbatim without a trailing newline.
					out.add(o.output);
				} catch (e:hxc.core.JsonRpc.InvalidArgument) {
					// It is recorded as an error at a null position and the server answers the request with
					// those messages. Only the server has a request to answer; the one-shot --display
					// prints the message plainly and exits 1.
					var id = try hxc.core.JsonRpc.parseRequest(displayArg).id catch (_:Dynamic) JNull;
					out.add(hxc.core.Json.stringOfJson(hxc.core.JsonRpc.error(id, 0, "Compiler error", JArray([
						JObject([
							{name: "severity", value: JInt(1)},
							{name: "location", value: JNull},
							{name: "message", value: JString("Invalid_argument(\"" + e.arg + "\")")}
						])
					]))));
				} catch (e:Dynamic) {
					// The answer is "\x02\n" + estr: the marker line first, then the exception string, with
					// nothing appended after it.
					out.add("\x02\n" + Std.string(e));
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
				continue;
			}
			// In-process execution is the default; HXC_WAIT_CHILD=1 restores the isolated child-process mode
			// as an escape hatch.
			if (Sys.getEnv("HXC_WAIT_CHILD") == null) {
				// The request compiles in this process over the persistent caches; a failing compile aborts
				// only the request.
				resetForNextRequest();
				// A request reuses cache-valid modules and only re-types the dirty subgraph;
				// HXC_SERVER_NOREUSE=1 falls back to full recompilation.
				// Only ever set here (the in-process wait server), so a one-shot compile is untouched.
				hxc.context.ServerCache.enabled = Sys.getEnv("HXC_SERVER_NOREUSE") == null;
				requestOutput = new hxc.compiler.RequestOutput();
				jsonErrorSent = false;
				var failed = false;
				try {
					run(lines);
				} catch (mj:hxc.context.DisplayJson.JsonDisplayOutput) {
					// A completion answer raised ANYWHERE in the compilation (an init-macro callback
					// answering a display request, a macro calling send_json) is the request's answer and
					// is written as given.
					requestOutput.add(mj.output);
				} catch (_:RequestAbort) {
					failed = !jsonErrorSent;
				} catch (e:Dynamic) {
					requestOutput.add("Error: " + Std.string(e) + "\n");
					failed = true;
				}
				hxc.context.ServerCache.enabled = false;
				// A fresh signature's directory scan runs after the request.
				hxc.context.ServerCache.runDelays();
				var payloadOut = requestOutput.getBytes();
				requestOutput = null;
				// The answer is written as GIVEN. Every message already carries its own newline, and a
				// completion answer carries none, so the frame must not pad one on: a legacy diagnostics answer
				// is exactly "[]". The frame is the buffer's bytes as written.
				var frame2 = new haxe.io.BytesBuffer();
				frame2.addString(out.toString());
				frame2.addBytes(payloadOut, 0, payloadOut.length);
				if (failed) frame2.addString("\x02\n");
				var body2 = frame2.getBytes();
				var head2 = haxe.io.Bytes.alloc(4);
				head2.set(0, body2.length & 0xFF);
				head2.set(1, (body2.length >> 8) & 0xFF);
				head2.set(2, (body2.length >> 16) & 0xFF);
				head2.set(3, (body2.length >> 24) & 0xFF);
				stderr.write(head2);
				stderr.write(body2);
				stderr.flush();
				censusCount++;
				if (censusEvery > 0 && censusCount % censusEvery == 0) hxc.debug.HeapCensus.staticCensus("after request " + censusCount, 20000000);
				if (liveMemFile != null) recordLiveMem();
				hxc.debug.AllocTelemetry.afterRequest();
				continue;
			}
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

	// The top-level handler wraps the whole compilation, argument processing included: a bad argument
	// and a plain failure report "Error: " + msg at a NULL position, which prints with no location
	// prefix. This has to be its own frame rather than a catch in main(): on the hxcpp host, a catch
	// directly around the run() call does not fire for a raise this deep, so an argument failure would
	// escape to the runtime and print in its format ("Error : ...", on stdout, exit 127).
	public static function run(args:Array<String>):Void {
		try runInner(args)
		catch (ra:RequestAbort) throw ra
		catch (mj:hxc.context.DisplayJson.JsonDisplayOutput) throw mj
		catch (se:hxc.eval.EvalExceptions.EvalSysExit) {
			// A non-zero exit code marks the compile failed, then the accumulated messages are FLUSHED
			// before the code is returned. The macro that exits has usually queued the warnings saying why.
			var c = argFailureCtx;
			if (c != null) flushPendingMessages(c);
			hxc.compiler.HostRuntime.exit(se.code);
		}
		catch (af:ArgFailure) fatalArgError(af.message)
		catch (e:hxc.core.JsonRpc.InvalidArgument) fatalArgError(e.message, false)
		catch (e:Dynamic) fatalArgError(Std.string(e));
	}

	static function runInner(args:Array<String>):Void {
		hxc.core.BinaryStdio.set();
		// The mono seams (create, bind, classify) route through TypeUnification; without this
		// the printer's constraint rendering sees the CUnknown stub and drops " : Constraint".
		hxc.core.TypeUnification.install();
		// A --display given last moves to the front, and only that form marks the command line as a
		// display one, which compiles its first section alone.
		var hasDisplay = false;
		if (args.length >= 2 && args[args.length - 2] == "--display" && args[args.length - 1] != "memory") {
			hasDisplay = true;
			args = ["--display", args[args.length - 1]].concat(args.slice(0, args.length - 2));
		}
		// One section per --next, each expanded only once the one before it has compiled (an earlier
		// section can write the hxml a later one reads), stopping at the first failure. A section before
		// the last compiles in a child process over its expanded arguments; the last compiles here.
		var each = {v: ([] : Array<String>)};
		var section = processParams(args, each);
		while (section.rest.length > 0 && !hasDisplay) {
			var proc = new Process(Sys.programPath(), section.params);
			var stdout = proc.stdout.readAll();
			var stderr = proc.stderr.readAll();
			var code = proc.exitCode();
			proc.close();
			if (stdout.length > 0) Sys.stdout().writeString(stdout.toString());
			if (stderr.length > 0) answerOut(stderr.toString());
			if (code != 0) {
				exitRequest(code);
				return;
			}
			section = processParams(section.rest, each);
		}
		args = section.params;
		// --wait stdio: the compilation-server loop. Requests arrive on stdin as 4-byte little-endian
		// length-prefixed blocks of newline-separated argument lines; each response goes to stderr with the
		// same framing. A line starting \x01 carries program stdout with embedded newlines encoded as \x01;
		// a \x02 line flags failure; anything else is a compiler message line.
		var waitAt = args.indexOf("--wait");
		if (waitAt >= 0 && waitAt + 1 < args.length && args[waitAt + 1] == "stdio") {
			applyStartupArgs(args);
			runWaitStdio();
			return;
		}
		var connectAt = args.indexOf("--server-connect");
		if (connectAt >= 0 && connectAt + 1 < args.length) {
			applyStartupArgs(args);
			runWaitConnect(args[connectAt + 1]);
			return;
		}
		var ctx = new Context();
		// The top-level handler holds the same context whose message list the argument handlers have been
		// appending to, so an argument failure reports through that list rather than past it. Recorded
		// here so the top-level handler can reach it.
		argFailureCtx = ctx;
		ctx.args = args.copy();
		// sysArgs starts as the parameters; --run replaces it with the arguments after the module name.
		ctx.sysArgs = section.sysArgs != null ? section.sysArgs : args.copy();
		Setup.setupCommonContext(ctx);
		ModuleLoader.attach(ctx);
		// A cast-field candidate check must see the INFERRED signature; force the abstract's cast fields on
		// lookup.
		hxc.core.TypeUnification.buildAbstractRef = function(a:hxc.core.Type.TAbstract) {
			if (a.impl == null) return;
			// Same world selection as forceOpenMethodHook below: this hook is global but closes over the
			// host context, so a unification performed while typing in the macro world reached here and
			// typed a macro-world body with the host's basic types. The two worlds have separate StdTypes,
			// so the result was a Float that cannot unify with Float.
			var actx = ctx;
			var amc = hxc.eval.EvalMacro.getMacroCom();
			if (amc != null && a.module != null && amc.moduleLut.get(Context.pathKey(a.module.path)) == a.module)
				actx = amc;
			// Building an abstract means building its impl class, so the hook forces it before the
			// cast-snapshot syncing below. Otherwise a member of an abstract whose impl is not yet built
			// sees its statics still private: every member of an enum abstract reads as "Cannot access
			// private field" when the reading class is built first.
			hxc.typing.TypeResolve.forceBuild(actx, a.impl);
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
		var xmlOut:String = null;
		var jsonOut:String = null;
		var helpTables = false;
		// An argument that has already DONE its job (--version, the help tables, --cwd) leaves nothing to
		// compile without that being a mistake, so the compile exits quietly instead of printing the usage
		// screen.
		var didSomething = false;
		// A SECOND target is refused whatever it is. The targets hxc has no generator for still occupy the
		// slot, so `-swf x -js y` is a "Multiple targets" error too.
		var targetTaken = false;
		// The usage-screen gate asks whether the compile roots are still only Std, and a few arguments add
		// a root of their own: --php and the cppia define.
		var namedARoot = false;
		var platform:Platform = Cross;
		// The chosen platform's own package is exempt from the Forbidden rules, and --jvm lifts jvm; a
		// target with no generator here leaves the platform Cross, so its exemption is applied by hand once
		// the rules exist.
		var ownPackages:Array<String> = [];
		var targetDir:Null<String> = null; // The std overlay dir for the chosen target
		var javaOutSeen = false;
		// A target may be chosen once. The second one is a failure, which prints as `Error: <msg>` at a
		// null position.
		inline function setPlatform(p:hxc.core.Globals.Platform):Void {
			if (platform != Cross || targetTaken) throw new ArgFailure("Multiple targets");
			targetTaken = true;
			platform = p;
		}
		// Legacy flag deprecations queue during parsing and are emitted together once the arguments are
		// processed, before -D no-deprecation-warnings disables them.
		var deprecations:Array<String> = [];

		var i = 0;
		while (i < args.length) {
			var a = args[i++];
			// The option parser wraps a handler-raised bad-argument error as ": " + msg + "." before the
			// top-level handler prefixes "Error: ". An error raised outside the option parser (a
			// pre-argument like --cwd) has no such framing.
			try switch (a) {
				case "-cp" | "-p" | "--class-path": userCp.push(argValue(args, i++, a));
				case "-main" | "-m" | "--main":
					// A second main class is refused, even the same one.
					var cl = argValue(args, i++, a);
					if (mainClass != null) throw "Multiple --main classes specified";
					checkTypePath(cl);
					mainClass = cl;
				case "--hxia":
					// The hxia profile mask: `--hxia core` (or sys). Masks the std surface at
					// typing per hxc.hxia.CapabilityMask; atoms are added by --require.
					ctx.defines.rawDefineValue("hxia", argValue(args, i++, a));
				case "--require":
					// Grant capability atoms (comma-separated), accumulating across repeats.
					var prev = ctx.defines.rawDefinedValueSafe("hxia_require", "");
					var add = argValue(args, i++, a);
					ctx.defines.rawDefineValue("hxia_require", prev == "" ? add : prev + "," + add);
				case "--hxia-dump-atoms":
					// Print the member->atom table and exit; the test lane reads this.
					Sys.print(hxc.hxia.CapabilityMask.dump());
					return;
				// The RTTI type descriptions; both write even under --no-output
				case "--xml" | "-xml": xmlOut = argValue(args, i++, a);
				case "--json": jsonOut = argValue(args, i++, a);
				// The compilation server. Not implemented here, but the argument must still be consumed and
				// reported clearly - left unhandled it is taken as a class path and the build fails with a
				// misleading "Package <port> was not found".
				case "--server-listen":
					var spec = argValue(args, i++, a);
					throw "The compilation server is not supported (" + a + " " + spec + ")";
				case "--server-connect":
					// Handled before the argument loop; a request's own argument list repeats it.
					i++;
				case "--resource" | "-r" | "-resource": addResource(ctx, argValue(args, i++, a));
				case "--remap":
					var spec = argValue(args, i++, a);
					var sep = spec.indexOf(":");
					if (sep <= 0 || sep == spec.length - 1) throw "Invalid remap format, expected source:target";
					ctx.packageRemaps.set(spec.substr(0, sep), spec.substr(sep + 1));
				case "-D" | "--define":
					var kv = argValue(args, i++, a);
					var eq = kv.indexOf("=");
					// Normalizes '-' to '_' in the define key.
					if (eq < 0) ctx.defines.rawDefine(StringTools.replace(kv, "-", "_"));
					else ctx.defines.rawDefineValue(StringTools.replace(kv.substr(0, eq), "-", "_"), kv.substr(eq + 1));
				case "--interp":
					setPlatform(Eval);
					targetDir = "eval";
					ctx.defines.rawDefine("interp");                                   
				case "-x":
					// -x <class>: interpret <class>, i.e. --interp plus a startup class. A main class
					// already given must be the same one.
					var cl = argValue(args, i++, a);
					checkTypePath(cl);
					if (mainClass == null) mainClass = cl;
					else if (sTypePath(parseTypePath(cl)) != sTypePath(parseTypePath(mainClass)))
						throw "Multiple --main classes specified";
					ctx.defines.rawDefine("interp");
					setPlatform(Eval);
					targetDir = "eval";
				case "--run":
					// `--run <module>` has already been turned into `-x <module>`, so one that reaches here
					// named no module.
					throw "--run requires an argument: a Haxe module name";
				case "-L" | "--library" | "-lib":
					// Every library that names one has already been expanded.
					argValue(args, i++, a);
				case "--haxelib-global":
					// Read when the libraries are expanded; nothing to do here.
				case "-js" | "--js":
					setPlatform(Js);
					targetDir = "js";
					ctx.file = argValue(args, i++, a);
				case "-cpp" | "--cpp":
					setPlatform(Cpp);
					targetDir = "cpp";
					ctx.file = argValue(args, i++, a);
				case "-cppia" | "--cppia":
					// Cppia is the cpp platform with the cppia define, and the output value is a file rather than
					// a directory.
					ctx.defines.rawDefine("cppia");
					setPlatform(Cpp);
					targetDir = "cpp";
					ctx.file = argValue(args, i++, a);
				case "--macro":
					ctx.initMacros.push(argValue(args, i++, a));
				case "-v" | "--verbose":
					ctx.verbose = true;
				case "--debug" | "-debug":
					// --debug also raises the debug define
					ctx.debug = true;
					ctx.defines.rawDefine("debug");
				case "--no-opt":
					ctx.foptimize = false;
				case "--no-traces":
					ctx.defines.rawDefine("no_traces");
					deprecations.push("--no-traces has been deprecated, use -D no-traces instead");
				case "--no-inline":
					ctx.defines.rawDefine("no_inline");
					deprecations.push("--no-inline has been deprecated, use -D no-inline instead");
				case "--dce" | "-dce":
					// The mode is validated where the argument is read, so a bad one is a command-line error
					// rather than something the DCE filter discovers later.
					var dceMode = argValue(args, i++, a);
					switch (dceMode) {
						case "std" | "full" | "no":
						case _: throw "Invalid DCE mode, expected std | full | no";
					}
					ctx.defines.rawDefineValue("dce", dceMode);
				case "-java" | "--java":
					// No generator, but the deprecated --java + -D jvm spelling still warns after the
					// arguments are known.
					javaOutSeen = true;
					ownPackages = ["java"];
					// No java generator here, but the flag still occupies the target slot, so a second
					// target is the same "Multiple targets" error.
					if (targetTaken || platform != Cross) throw new ArgFailure("Multiple targets");
					targetTaken = true;
					i++;
				case "-neko" | "--neko":
					// No neko GENERATOR here, but the platform must still be set: it is set for every
					// target and only OUTPUT is gated on --no-output, so typing, the filter pipeline and
					// the analyzer all run and report. Leaving it Cross would skip every one of them and
					// accept anything targeted at neko in silence.
					setPlatform(Neko);
					targetDir = "neko";
					ctx.file = argValue(args, i++, a);
				case "-php" | "--php" | "-swf" | "--swf" | "-cs" | "--cs"
					| "--jvm" | "-python" | "--python" | "-lua" | "--lua"
					| "-hl" | "--hl":
					// Targets without a generator here; the output-file value must still be consumed
					// so it does not parse as a compilation root.
					if (targetTaken || platform != Cross) throw new ArgFailure("Multiple targets");
					targetTaken = true;
					// --php brings its own compile root (php.Boot), so the command line has named something even
					// when nothing else did. hxc has no php generator and cannot type that root, so only the fact
					// is recorded.
					if (a == "-php" || a == "--php") namedARoot = true;
					ownPackages = switch (a) {
						case "-php" | "--php": ["php"];
						case "-swf" | "--swf": ["flash"];
						case "-cs" | "--cs": ["cs"];
						case "--jvm": ["java", "jvm"];
						case "-python" | "--python": ["python"];
						case "-lua" | "--lua": ["lua"];
						case _: ["hl"];
					};
					i++;
				case "--display":
					ctx.displaySpec = argValue(args, i++, a);
				case "-c-arg" | "--c-arg":
					// The argument is prepended to cArgs.
					ctx.cArgs.unshift(argValue(args, i++, a));
				case "-swf-lib" | "--swf-lib" | "-swf-lib-extern" | "--swf-lib-extern" | "-swf-version"
					| "--swf-version" | "-swf-header" | "--swf-header" | "-java-lib" | "--java-lib"
					| "--java-lib-extern" | "-net-lib" | "--net-lib" | "-net-std"
					| "--net-std" | "--connect" | "--neko-lib-path":
					// Options without an implementation here; the value must still be consumed.
					// --neko-lib-path collects neko link paths; there is no neko generator here, so the
					// directory is consumed and dropped.
					i++;
				case "--cwd" | "-C":
					// A nonexistent directory aborts with the argument error "Invalid directory".
					var dir = argValue(args, i++, a);
					if (!sys.FileSystem.exists(dir) || !sys.FileSystem.isDirectory(dir)) {
						answerOut("Error: Invalid directory: " + dir + "\n");
						exitRequest(1);
					}
					hxc.core.Cwd.set(dir);
					didSomething = true;
				case "--cmd" | "-cmd":
					cmds.push(unquote(argValue(args, i++, a)));
				case "--version" | "-version":
					// Recorded as an info message, not printed directly: macros can see and filter it through
					// Context.getMessages.
					ctx.addDiagnostic(Globals.sVersionFull, Position.nullPos, 0, MessageSeverity.Information);
					didSomething = true;
				// `--help` answers with the usage screen and nothing else.
				case "--help" | "-help" | "-h":
					Sys.stdout().writeString(hxc.compiler.Usage.help());
					Sys.stdout().flush();
					exitRequest(0);
				case "--help-metas":
					// MetaRegistry embeds meta.json verbatim, so the doc text is already here; only the
					// internal entries are withheld.
					printCompilerDocs(true);
					helpTables = true;
					didSomething = true;
				case "--help-defines":
					printCompilerDocs(false);
					helpTables = true;
					didSomething = true;
				case "--help-user-defines":
					// The user entries exist once the init macros have registered them, so the listing is
					// an after-init callback, and its Abort ends the compile.
					didSomething = true;
					ctx.afterInitMacros.push(function() {
						printUserDocs([
							for (k in ctx.userDefines.keys()) {name: k.split("_").join("-"), entry: ctx.userDefines.get(k), isMeta: false}
						]);
						throw new CompileAbort();
					});
				case "--help-user-metas":
					didSomething = true;
					ctx.afterInitMacros.push(function() {
						printUserDocs([
							for (k in ctx.userMetas.keys()) {name: "@" + k, entry: ctx.userMetas.get(k), isMeta: true}
						]);
						throw new CompileAbort();
					});
				case "--no-output":
					noOutput = true;
				case "--times":
					hxc.core.Timer.measureTimes = true;
				case "-w":
					var spec = argValue(args, i++, a);
					var wpos = new Position("-w " + spec, 0, 0);
					ctx.warningOptions.unshift(hxc.core.WarningList.parseOptions(spec, wpos));
				case _:
					// An unrecognised argument is an error, reported with the message below. Falling
					// through in silence would let a typo'd flag look like it had been honoured.
					if (StringTools.startsWith(a, "-")) {
						// The name is read back out of the message with `[-A-Za-z]+`, so a trailing digit
						// is not part of what is looked for, and the near misses are appended.
						var name = "";
						for (k in 0...a.length) {
							var c = a.charCodeAt(k);
							if (c == "-".code || (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code)) name += a.charAt(k);
							else break;
						}
						var hint = hxc.compiler.Usage.suggest(name);
						// The argument parser frames a handler's failure as `: <msg>.`, and the suggestion is
						// appended to that, so the period belongs after the first line rather than after the block.
						// With one, the message is already framed. The separators are escapes, not literal newlines:
						// this file is checked out with CRLF, and a literal newline inside the string puts a CR in
						// the message.
						if (hint != null) throw new ArgFailure(": unknown option '" + a + "'.\nDid you mean:\n"
							+ (hint.length > 0 ? hint.substr(0, hint.length - 1) : ""));
						throw "unknown option '" + a + "'";
					}
					// A bare argument whose name starts uppercase is a compilation root (never the startup
					// class: only -main sets that), any other includes the package.
					if (!StringTools.startsWith(a, "-")) {
						// Every part of a bare argument is validated: the last one only for invalid characters, the
						// ones before it as package names. A failure names the whole argument, and is swallowed under
						// a display run.
						var perr = parsePathError(a);
						if (perr != null) {
							if (!ctx.ignoreError())
								throw new ArgFailure("Could not process argument " + a + "\n" + perr);
						} else {
							// An empty name (pack. or pack/.hx) makes startsUppercaseIdentifier throw
							// InvalidArgument, which the swallow above does not cover.
							var parts = getPathParts(a);
							if (hxc.core.StringHelper.startsUppercaseIdentifier(parts[parts.length - 1])) {
								extraClasses.push(a);
							} else {
								// Forcing the typing needs no flag: the nothing-to-compile check below
								// counts init macros.
								ctx.initMacros.push("include('" + a + "', true, null, null, true)");
							}
						}
					}
			} catch (af:ArgFailure) throw af
			catch (msg:String) throw ": " + msg + ".";
		}

		// The cppia define on the cpp target adds cpp.cppia.HostClasses as a compile root, which is why
		// `-cpp out -D cppia` alone is not an empty command line.
		if (platform == Cpp && ctx.defines.rawDefined("cppia")) {
			extraClasses.push("cpp.cppia.HostClasses");
			namedARoot = true;
		}

		// Nothing to compile, no macros to run, no commands: exit after argument handling, so `-version`
		// works without a std. The accumulated messages (the -version info line) still print.
		if (mainClass == null && extraClasses.length == 0 && ctx.initMacros.length == 0
			&& cmds.length == 0 && !helpTables && !namedARoot
			&& ctx.displaySpec == null) {
			// The gate is "the compile roots are only Std and typing is not forced", and it does not look at
			// the target - a bare target flag prints the usage screen and never loads the std it just added.
			// An argument that already did its job exits quietly instead.
			if (!didSomething) {
				Sys.stdout().writeString(hxc.compiler.Usage.text());
				Sys.stdout().flush();
			}
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
		for (pk in ownPackages) ctx.forbiddenPackages.remove(pk);
		if (targetDir != null) Setup.addStd(ctx, targetDir);
		// Run while the arguments are processed: a --display request whose mode does not type the whole
		// compile (usage, diagnostics and statistics do) defines `display` as that mode, "1" for the empty
		// one. A JSON payload defines it once its method is known, below.
		if (ctx.displaySpec != null && !StringTools.startsWith(ctx.displaySpec, "{") && !StringTools.startsWith(ctx.displaySpec, "[")) {
			var dp = ctx.displaySpec.split("@");
			// The split cuts at the first @, so the mode keeps any later ones.
			var smode = dp.length >= 3 ? dp.slice(2).join("@") : "";
			if (dp.length >= 2 && smode != "usage" && smode != "diagnostics" && smode != "statistics")
				ctx.defines.rawDefineValue("display", smode != "" ? smode : "1");
		}
		// The class path and the defines are logged right before the core types load. The defines are
		// walked in key order, and a define whose value is "1" prints as its bare name.
		if (ctx.verbose) {
			ctx.log("Classpath: " + ctx.classPath.join(";"));
			var keys = [for (k in ctx.defines.values.keys()) k];
			keys.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
			ctx.log("Defines: " + [for (k in keys) {
				var v = ctx.defines.values.get(k);
				v == "1" ? k : k + "=" + v;
			}].join(";"));
		}
		try ModuleLoader.initBasicTypes(ctx) catch (e:hxc.core.TypingError) {
			// The standard library is missing; reported like any other error, and that is the end of the
			// request.
			ctx.raiseTypingErrors = false;
			ctx.addDiagnostic(e.message, e.pos, e.depth);
			flushPendingMessages(ctx);
			exitRequest(1);
		}
		// The startup class is known from -main during argument handling, so an init macro's
		// Context.getMainExpr / Compiler.getConfiguration already sees it.
		if (mainClass != null) ctx.mainClass = parseTypePath(mainClass);
		// The queued legacy-flag deprecations emit here, in the order they were seen, before the
		// no-deprecation-warnings disable is installed below.
		for (s in deprecations)
			ctx.warning(hxc.core.WarningList.Warning.WDeprecated, [], s, Position.nullPos);
		// The --java target with -D jvm and no --jvm flag.
		if (javaOutSeen && ctx.defines.rawDefined("jvm"))
			ctx.warning(hxc.core.WarningList.Warning.WDeprecated, [], "--java out.jar -D jvm is deprecated; use --jvm out.jar directly", Position.nullPos);
		// -D no-deprecation-warnings disables WDeprecated globally.
		if (ctx.defines.rawDefined("no_deprecation_warnings"))
			ctx.warningOptions.unshift([{warning: hxc.core.WarningList.Warning.WDeprecated, mode: hxc.core.WarningList.WarningMode.WMDisable}]);
		// A JSON payload on --display selects the JSON-RPC display protocol. An immediate response travels
		// the Completion channel and ends the run; a handler that only configures state (diagnostics) lets
		// compilation continue and answers at report time.
		// Either bracket starts a JSON payload, so a malformed array payload is a JSON parse error rather
		// than a legacy file@position argument.
		if (ctx.displaySpec != null
				&& (StringTools.startsWith(ctx.displaySpec, "{") || StringTools.startsWith(ctx.displaySpec, "["))) {
			try {
				hxc.context.DisplayJson.parseInput(ctx, ctx.displaySpec);
			} catch (out:hxc.context.DisplayJson.JsonDisplayOutput) {
				// Print the response verbatim without a trailing newline.
				if (requestOutput != null) requestOutput.add(out.output)
				else answerOut(out.output);
				return;
			} catch (e:hxc.eval.EvalExceptions.HostException) {
				// A failure is "Error: <message>", any other native exception prints as itself, both at a
				// null position.
				var line = (e.failure ? "Error: " : "") + e.message + "\n";
				if (requestOutput != null) { requestOutput.add(line); return; }
				answerOut(line);
				exitRequest(1);
			} catch (e:hxc.core.JsonRpc.InvalidArgument) {
				// An uncaught Invalid_argument prints bare on stderr and exits 1.
				if (requestOutput != null) { requestOutput.add("Invalid_argument(\"" + e.arg + "\")\n"); return; }
				answerOut("Invalid_argument(\"" + e.arg + "\")\n");
				exitRequest(1);
			}
		}
		// Legacy --display file@pos: the parser stops at a dot-path completion point of the display file,
		// which also joins the compile roots. The statics install before the init macros so a display
		// position typed during a --macro run records.
		var displayRoot:Null<Path> = null;
		// A .macro.hx display file is not a compile root; only the macro context can load its module.
		var displayMacroRoot:Null<Path> = null;
		// Every file the display request names becomes a compile root, so a file the program never
		// reaches is still parsed and reported on.
		var displayRoots:Array<Path> = [];
		// Every mode that asks about a position, and a legacy @diagnostics, empties the compile roots and
		// drops the main class: the display module is all that is compiled. Usage, implementation,
		// statistics and JSON diagnostics keep them, workspace symbols too.
		var displayFileOnly = false;
		{
			var dparts = displayParts(ctx);
			var dmode = displayMode(ctx, dparts);
			if (dparts.length >= 2 || ctx.jsonRpcId != null && ctx.displaySpec != null)
				displayFileOnly = switch (dmode) {
					case "usage" | "implementation" | "statistics" | "compiledTypes" | "workspace-symbols": false;
					case "diagnostics": ctx.jsonRpcId == null;
					case _: true;
				};
			// The display file is processed before the init macros, so they see no main class.
			if (displayFileOnly) ctx.mainClass = null;
			// `display` is defined as "1" for every JSON method but display/diagnostics;
			// typer/compiledTypes is no display method.
			if (ctx.jsonRpcId != null && dparts.length >= 2 && dmode != "diagnostics" && dmode != "compiledTypes")
				ctx.defines.rawDefineValue("display", "1");
			if (dmode == "package" && dparts.length >= 2) {
				var pack = displayFilePackage(ctx, dparts[0]);
				// A package answer: a string array over the protocol.
				if (ctx.jsonRpcId != null) {
					var parts = pack == "" ? [] : pack.split(".");
					answerOut(jsonRpcAnswer(ctx, "[" + [for (s in parts) haxe.Json.stringify(s)].join(",") + "]"));
					return;
				}
				answerOut(pack + "\n");
				return;
			}
			// The symbol outline is read off the display file's cached DECLARATIONS, so it needs the parse
			// and nothing more (the packages and declarations of the files; locals are included when
			// unfiltered).
			if (dmode == "module-symbols" && dparts.length >= 2) {
				// The cache entry keeps the file path as RESOLVED, not absolutized, and both the reported file
				// and the container paths are derived from it.
				var dfile = dparts[0];
				hxc.parser.Parser.displayFile = dfile;
				var src = ModuleLoader.moduleFileContent(ctx, dfile);
				var pkg = hxc.parser.Parser.parseModuleString(src, dfile, ctx.defines);
				// No module-name entry on this path, even for a file that declares no type of its own name:
				// the outline holds only the declared symbols.
				var syms = hxc.compiler.DocumentSymbols.collectModuleSymbols(null, true, pkg);
				answerOut(hxc.compiler.DocumentSymbols.printModuleSymbols([{file: dfile, l: syms}], null));
				return;
			}
			// Every mode that names a file makes it a compile root, diagnostics included. Leaving
			// diagnostics out would mean a request with no other root compiles nothing and reports nothing.
			if (dparts.length >= 2 && (dmode == "" || dmode == "position" || dmode == "type" || dmode == "usage" || dmode == "toplevel" || dmode == "typeDefinition" || dmode == "implementation" || dmode == "signature" || dmode == "diagnostics")) {
				var doff = Std.parseInt(dparts[1]);
				if (doff != null) {
					hxc.parser.Parser.displayFile = dparts[0];
					hxc.parser.Parser.displayOffset = doff;
					hxc.typing.Typer.displayDefinition = dmode == "position";
					hxc.typing.Typer.displayHover = dmode == "type";
					if (dmode == "type" && ctx.jsonRpcId != null) hxc.typing.Typer.hoverSnapshot = h -> hoverSnapshot(ctx, h);
					if (ctx.jsonRpcId != null) hxc.typing.Typer.fieldCompletionSnapshot = () -> jsonCompletion(ctx);
					hxc.typing.Typer.displayUsage = dmode == "usage";
					// "toplevel" and the empty mode are the same default mode, and both answer with a toplevel
					// collection when the position is not a field access. Which printer runs follows the answer (a
					// field list prints <list>, a toplevel one <il>), not the request.
					hxc.typing.Typer.displayToplevel = dmode == "toplevel" || (dmode == "" && ctx.jsonRpcId == null);
					// The JSON completion request at a non-dot position answers the toplevel item set.
					hxc.typing.Typer.displayToplevelJson = ctx.jsonRpcId != null && dmode == "";
					hxc.typing.Typer.displayTypeDefinition = dmode == "typeDefinition";
					hxc.typing.Typer.displayImplementation = dmode == "implementation";
					hxc.typing.Typer.displaySignature = dmode == "signature";
					hxc.parser.Parser.displaySignatureMode = dmode == "signature";
					// Hover is the mode whose enclosure test takes the upper bound STRICTLY, which the
					// display position handling branches on.
					hxc.parser.Parser.displayHoverMode = dmode == "type";
					hxc.parser.Parser.displayCompletionMode = dmode == "" || dmode == "toplevel";
					// Every display mode EXCEPT the ones that report the compile itself ignores errors, and
					// the typer consults that (ignoreError) at the handful of places where an error would
					// cost the answer rather than describe it.
					ctx.ignoreErrors = dmode != "diagnostics" && dmode != "statistics";
					// Only the modes that report the COMPILE keep full typing. A mode that answers about
					// one position leaves it false, and the field typer reads that to type only the field
					// under the cursor.
					ctx.displayFullTyping = dmode == "diagnostics" || dmode == "statistics"
						|| dmode == "usage" || dmode == "implementation";
					// Only the report modes and a compile with no display at all inline.
					ctx.dmsInline = dmode == "diagnostics" || dmode == "statistics" || dmode == "compiledTypes";
					// The report mode is diagnostics only for a diagnostics request, so isDiagnosticsFile
					// answers false everywhere else.
					ctx.diagnosticsFileFilter = dmode != "diagnostics" ? null
						: function(f:String) return isDiagnosticsFile(ctx, f);
					// The compile root is the display file's path RELATIVE to its classpath, so a file in a
					// package loads as that package's module; the basename alone would look for it at the
					// classpath root. Each real file maps to a compile root; the marker the protocol uses when a
					// request names no file at all is not one.
					var path = dparts[0] == "?" ? null : displayModulePath(ctx, dparts[0]);
					if (path != null) {
						// A dotted module name is Name.macro (never a compile root: the compiler would not
						// find it) or Name.<target>, which loads as Name.
						var nparts = path.name.split(".");
						if (nparts.length == 1) displayRoot = path;
						else if (nparts.length == 2 && nparts[1] != "macro") displayRoot = {pack: path.pack, name: nparts[0]};
						// The module is loaded in the macro context instead.
						else if (nparts.length == 2) displayMacroRoot = {pack: path.pack, name: nparts[0]};
					}
					for (fc in ctx.fileContents) {
						var fp = displayModulePath(ctx, fc.file);
						if (fp == null) continue;
						var fnparts = fp.name.split(".");
						var root:Null<Path> = if (fnparts.length == 1) fp
							else if (fnparts.length == 2 && fnparts[1] != "macro") {pack: fp.pack, name: fnparts[0]}
							else null;
						if (root == null) continue;
						var dup = false;
						for (r in displayRoots) if (r.name == root.name && r.pack.join(".") == root.pack.join(".")) dup = true;
						if (!dup) displayRoots.push(root);
					}
				}
			}
		}
		// The context registers its descriptive json in the process cache before the init macros run, which
		// is what makes server/contexts list it.
		// afterArgParsing runs once the defines and the class path are final.
		hxc.context.ServerCache.afterArgParsing(ctx);
		// The reused macro com belongs to this compilation from here on (the macro com is cloned from each
		// compilation's com).
		hxc.eval.EvalMacro.syncMacroCom(ctx);
		// A display answer may come out of the .macro.hx load, and that load runs outside the main typing:
		// the answer ends the compile, so nothing after it types.
		var answeredBeforeTyping = false;
		try {
			// A .macro.hx display file loads into the macro context before the main typing, ahead of the
			// context registration and the init macros, and an answer it raises skips all of them.
			if (displayMacroRoot != null)
				try hxc.eval.EvalMacro.loadDisplayModuleInMacro(ctx, displayMacroRoot)
				catch (_:hxc.compiler.DisplayXml.DisplayRaised) answeredBeforeTyping = true;
			if (!answeredBeforeTyping) {
				hxc.context.DisplayJson.cache.maybeAddContextSign(ctx, "before_init_macros");
				hxc.eval.EvalMacro.runInitMacros(ctx, ctx.initMacros);
				// The init-macro callbacks run after the stage changes and before root modules type.
				ctx.initMacrosDone = true;
				// The context re-registers under its post-macro signature (init macros can add defines);
				// the last registration's desc wins.
				hxc.context.DisplayJson.cache.maybeAddContextSign(ctx, "after_init_macros");
				// The callbacks are one list in registration order, so the arguments' and the display request's
				// callbacks run ahead of the init macros', and again for any added while it ran. What a
				// callback raises ends the run and the compile.
				while (ctx.afterInitMacros.length > 0) {
					var aim = ctx.afterInitMacros;
					ctx.afterInitMacros = [];
					for (cb in aim) cb();
				}
			}
		} catch (_:CompileAbort) {
			// The compile ends quietly; the final flush prints what was queued and an error among it is the
			// exit code.
			var failed = ctx.hasError();
			flushPendingMessages(ctx);
			if (failed) exitRequest(1);
			return;
		} catch (ex:hxc.eval.EvalExceptions.EvalRunTimeException) {
			printUncaughtException(ctx, ex, hxc.eval.EvalMacro.currentPosition());
		} catch (e:hxc.eval.EvalExceptions.HostException) {
			// A failure is "Error: <message>", any other native exception prints as itself, both at a null
			// position - reported through the message list, behind the messages already recorded, so a
			// warning the compile queued before it prints first.
			abortWithMessage(ctx, (e.failure ? "Error: " : "") + e.message, Position.nullPos);
		} catch (e:hxc.core.JsonRpc.InvalidArgument) {
			// An uncaught Invalid_argument prints bare on stderr and exits 1.
			answerOut("Invalid_argument(\"" + e.arg + "\")\n");
			exitRequest(1);
		} catch (e:hxc.core.TypingError) {
			// Through the message store, so -D message.reporting picks the formatter and a compound message
			// renders its sub-lines as depth children. An Error with a Stack prints every located message
			// in it, as the FatalError below does.
			ctx.raiseTypingErrors = false;
			ctx.addTypingError(e.message, e.pos, e.depth, e.callChain);
			flushPendingMessages(ctx);
			exitRequest(1);
		} catch (e:hxc.core.TypingError.FatalError) {
			// A field's fatal error is reported like any other, and that is the end of the compile.
			if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null) Sys.println("[fatal-driver] " + e.message);
			ctx.raiseTypingErrors = false;
			ctx.addTypingError(e.message, e.pos, e.depth, e.callChain);
			flushPendingMessages(ctx);
			exitRequest(1);
		} catch (e:hxc.context.Context.ContextError) {
			// An Error out of an init macro's load - the macro module not being found - is reported like
			// any other.
			ctx.raiseTypingErrors = false;
			ctx.addTypingError(e.message, e.pos, e.depth, e.callChain);
			flushPendingMessages(ctx);
			exitRequest(1);
		} catch (e:hxc.parser.LexerError) {
			// The top-level handler wraps the whole compilation, init macros included, so a module an init
			// macro pulls in reports its parse failure like any other one does. Without these two the
			// failure would reach the outermost handler and print as "Error: ParserError".
			if (isDisplay(ctx, "diagnostics")) return diagnosticsAbort(ctx, hxc.parser.LexerError.errorMsg(e.msg), e.pos, 4);
			abortWithMessage(ctx, hxc.parser.LexerError.errorMsg(e.msg), e.pos);
		} catch (e:hxc.parser.ParserError) {
			if (isDisplay(ctx, "diagnostics")) return diagnosticsAbort(ctx, hxc.parser.ParserError.errorMsg(e.msg), e.pos, 4);
			abortWithMessage(ctx, hxc.parser.ParserError.errorMsg(e.msg), e.pos);
		}

		// A compile without -main still loads its roots, runs macros and filters, and generates; it just
		// has no entry call (nothing is printed).
		var path = mainClass == null || displayFileOnly ? null : parseTypePath(mainClass);
		ctx.mainClass = path;
		if (displayFileOnly) extraClasses = [];
		try {
			// A display answer raises: typing ends where one is raised, and nothing typed after it can
			// answer instead. The answer is the one recorded.
			try {
				if (answeredBeforeTyping) throw new hxc.compiler.DisplayXml.DisplayRaised();
				var tLoad = hxc.core.Timer.timer(["parsing"]);
				// Std is always in the compile roots and loads before the main class. Every display mode that
				// is not a report mode checks the display file against the cache before the compile roots load.
				// The DisplayInMacroBlock handler wraps the whole typing stage, and checking the display file
				// is the first thing that stage runs - so a display file whose cursor sits in a macro-only
				// block raises from there too. Guarding only the display root's own load would print the
				// exception as `Error: display in macro block` instead of recovering and reporting the missing
				// completion point.
				try {
					checkDisplayFile(ctx);
					// A display-file-only request empties the compile roots, Std included, so Std loads
					// only once something types against it.
					if (!displayFileOnly) ModuleLoader.loadModule(ctx, {pack: [], name: "Std"}, Position.nullPos);
				} catch (_:hxc.parser.Parser.DisplayInMacroBlock) {
					if (displayRoot != null) hxc.eval.EvalMacro.loadDisplayModuleInMacro(ctx, displayRoot);
				}
				// The parse of the display file raises DisplayInMacroBlock when the cursor is in a block only
				// the macro context turns on. The normal typing is abandoned and the module is loaded in that
				// context instead, where the display hook fires against the macro-world types. The handler
				// wraps the whole typing stage, which is the display-file check plus every root module load.
				// The display file can be reached through any of them, not only through its own root, so
				// guarding only that one would let the exception print itself as `Error: display in macro
				// block`.
				var m:Null<ModuleDef> = null;
				try {
					if (displayRoot != null) ModuleLoader.loadModule(ctx, displayRoot, Position.nullPos);
					for (r in displayRoots) try ModuleLoader.loadModule(ctx, r, Position.nullPos) catch (_:Dynamic) {}
					m = path == null ? null : ModuleLoader.loadModule(ctx, path, Position.nullPos);
					for (ec in extraClasses) ModuleLoader.loadModule(ctx, parseTypePath(ec), Position.nullPos);
				} catch (_:hxc.parser.Parser.DisplayInMacroBlock) {
					if (displayRoot != null) hxc.eval.EvalMacro.loadDisplayModuleInMacro(ctx, displayRoot);
				}
				// The cppia define adds cpp.cppia.HostClasses to the compile roots; it loads last (roots
				// are typed in reverse insertion order).
				if (platform == Cpp && ctx.defines.rawDefined("cppia"))
					ModuleLoader.loadModule(ctx, {pack: ["cpp", "cppia"], name: "HostClasses"}, Position.nullPos);
				tLoad();
				var tType = hxc.core.Timer.timer(["typing"]);
				var tResolve = hxc.core.Timer.timer(["typing", "resolve"]);
				TypeResolve.resolveAll(ctx);
				tResolve();
				var tFields = hxc.core.Timer.timer(["typing", "fields"]);
				TypeFields.typeAllModules(ctx);
				tFields();
				// Unused plain imports load once the build pipeline has run, so their declaration errors
				// surface; the second typing pass covers them (an import always loads its module).
				hxc.filters.ImportCheck.loadPlainImports(ctx);
				hxc.eval.EvalMacro.runAfterTypingCallbacks(ctx, () -> TypeFields.typeAllModules(ctx));
				TypeFields.typeAllModules(ctx);
				tType();
				TypeFields.checkRecursiveAbstracts(ctx);
			} catch (_:hxc.compiler.DisplayXml.DisplayRaised) {}
			// A metadata argument containing the display position types as an expression so completion can
			// fire inside it (e.g. @:access(pack.| ).
			// It runs as a PCheckConstraint delay of the typing, which an answer raised before it ends.
			if (hxc.parser.Parser.displayFile != null && !hxc.typing.Typer.answerRaised())
				try checkDisplayMetadata(ctx) catch (_:hxc.compiler.DisplayXml.DisplayRaised) {}
			// A line comment holding the cursor ends the request as a comment completion, in every mode and
			// in the json protocol alike: an empty keyword list (nothing) and the missing point. The lexer
			// only flags it and typing goes on, but what it types answers nothing.
			if (hxc.parser.Parser.commentAnswered) {
				answerOut("Error: No completion point was found\n");
				exitRequest(1);
			}
			// The typer raises when the unresolved name is the display subject, so the error answers the
			// request. That raise is caught while recovering the field body, so the answer path has to defer
			// to it explicitly - and only to it: an error anywhere else must still leave the answer alone.
			// Raising is not by itself the end of the request. The answer is raised from the marked
			// expression's own typing, so only a raise that escaped that typing leaves nothing to answer -
			// one caught inside it (a block's per-statement recovery) still lets the walk answer.
			// markedNodeFailed is that verdict, and the answer gate below already reads it.
			if (hxc.typing.Typer.displayDefinition && hxc.typing.Typer.displaySubjectError != null
				&& hxc.typing.Typer.markedNodeFailed) {
				// The recovery that caught the raise already recorded the message; re-adding it here printed it
				// twice. Only the decision to stop instead of answering belongs here.
				flushPendingMessages(ctx);
				exitRequest(1);
			}
			hxc.typing.Typer.resolveHoverMacroField(ctx);
			if (hxc.typing.Typer.displayDefinition) {
				var found = hxc.typing.Typer.displayFound;
				// The same vetoes as the hover lane's below: the preprocessor giving up at the display
				// position and a marked statement that raised first leave nothing marked, so the walk's
				// record goes too.
				if (found != null && hxc.typing.Typer.displayFoundFromWalk
					&& (hxc.typing.ExprPreprocessing.gaveUpAtDisplay || hxc.typing.Typer.markedStatementFailed))
					found = null;
				// In a module whose declarations raised, a variable of a class built before the error
				// answers as it binds; nothing else of that module runs.
				if (found == null) {
					var hf = hoverOnFieldName(ctx);
					if (hf != null && ctx.declErrored.exists(Context.pathKey(hf.c.path))) found = [hf.cf.namePos];
				}
				if (found == null) {
					// Under go-to-definition, a type declaration reports itself.
					var mt = displayTypeAtName(ctx);
					found = mt == null ? [] : [TypeFunctions.tInfos(mt).namePos];
				}
				// A display mode that exits during typing must raise its answer. Otherwise, report recorded
				// errors or the missing completion point. An empty definition list is valid only when the
				// marked expression was typed successfully and has no declaration. Errors from typing that
				// expression abort the request. If the preprocessor marks nothing, report the missing
				// completion point; do not infer an answer from an enclosing, unmarked node.
				if (!hxc.typing.Typer.markedNodeFailed
					&& (found.length > 0 || hxc.typing.ExprPreprocessing.markedNode != null)) {
					// A JSON-RPC request answers with Location objects; the legacy arg prints XML.
					if (ctx.jsonRpcId != null)
						answerOut(jsonRpcAnswer(ctx, "[" + [for (p in found) jsonLocation(p)].join(",") + "]"))
					else
						answerOut(hxc.compiler.DisplayXml.printPositions(found));
					return;
				}
			}
			if (hxc.typing.Typer.displayTypeDefinition) {
				// A hook that raises its POSITIONS outright (a module file, a type parameter's name,
				// the empty answer of `trace`) answers as the definition lane does.
				var direct = hxc.typing.Typer.displayFound;
				if (direct != null) {
					if (ctx.jsonRpcId != null)
						answerOut(jsonRpcAnswer(ctx, "[" + [for (p in direct) jsonLocation(p)].join(",") + "]"))
					else
						answerOut(hxc.compiler.DisplayXml.printPositions(direct));
					return;
				}
				// The captured expression's type resolves to its declaration name position.
				var h = hxc.typing.Typer.hoverFound;
				var hf = h == null ? hoverOnFieldName(ctx) : null;
				var t:Null<T> = h != null ? h.t : (hf != null ? hf.t : null);
				// Same rule as definition above. The two cases are not the same: no type at the cursor never
				// resolves a type position at all and falls through, while a type that has no module type
				// answers [null position], and that single null entry is the answer.
				if (t != null || hxc.typing.ExprPreprocessing.markedNode != null) {
					var p = t == null ? null : typeDefinitionPos(t);
					var locs = p == null ? "[null]" : "[" + jsonLocation(p) + "]";
					if (ctx.jsonRpcId != null)
						answerOut(jsonRpcAnswer(ctx, locs))
					else
						answerOut(hxc.compiler.DisplayXml.printPositions(p == null ? [] : [p]));
					return;
				}
			}
			if (hxc.typing.Typer.displayHover) {
				if (ctx.jsonRpcId != null) {
					// Metadata display raises at the metadata ENTRY, so it answers before whatever the
					// metadata is attached to - but not before a field declaration under the cursor, which
					// raised while the class was built.
					var mh = hxc.typing.Typer.fieldDeclHover != null ? null : jsonMetaHover(ctx);
					if (mh != null) { answerOut(mh); return; }
					// Unanswered, the request falls through like the legacy one.
					var out = jsonHover(ctx);
					if (out != null) { answerOut(out); return; }
				} else {
					// Under hover, the metadata name reports its own documentation, in its own element. Metadata
					// display raises as soon as the entry is reached, so it wins over the expression the metadata
					// is attached to; the parser only records the entry when the cursor is on the name. A name the
					// registry does not know (a custom metadata) answers nothing.
					var metaDoc = hxc.typing.Typer.fieldDeclHover != null ? null : displayMetaDoc(ctx);
					if (metaDoc != null) { answerOut("<metadata>" + metaDoc + "</metadata>"); return; }
					var h:Null<{t:T, p:Position}> = answeredHover();
					// The documentation comes from the hover's ITEM, and a type path answers with a type item,
					// whose documentation is the type's own - there is no expression to read it off. Asking the
					// expression only would print a type HINT's hover with no d attribute. The json lane builds
					// the item and so already asks the module type.
					if (h != null) mergeHoverCoreDoc(ctx, hxc.typing.Typer.hoverFound);
					var hdoc = h == null ? null : hoverDocumentation(hxc.typing.Typer.hoverFound);
					if (h == null) h = hoverOnFieldName(ctx);
					if (h == null) {
						var mt = displayTypeAtName(ctx);
						if (mt != null) {
							var inf = TypeFunctions.tInfos(mt);
							h = {t: TypeFunctions.typeOfModuleType(mt), p: inf.namePos};
							hdoc = inf.doc == null ? null : hxc.ast.Ast.genDocText(inf.doc);
						}
					}
					// An unanswered display request is not an empty answer. Falling through reports the compile
					// error the body recorded, or the missing completion point, which is what the client relies
					// on.
					if (h != null) {
						answerOut(hxc.compiler.DisplayXml.printType(hxc.core.TPrinting.sTypeStr(h.t), h.p, hdoc));
						return;
					}
				}
			}
			// A declaration error raises out of module type initialization and nothing on the way out
			// catches it, so a mode that answers only once typing is over - usage and implementation - never
			// gets there: the error is the output. hxc records it and abandons the module (TypeResolve
			// markModuleErrored), and the verdict is read back here.
			if ((hxc.typing.Typer.displayUsage || hxc.typing.Typer.displayImplementation) && ctx.declErrored.keys().hasNext()) {
				flushPendingMessages(ctx);
				exitRequest(1);
			}
			if (hxc.typing.Typer.displayImplementation) {
				var impls = collectImplementations(ctx);
				if (ctx.jsonRpcId != null)
					answerOut(jsonRpcAnswer(ctx, "[" + [for (p in impls) jsonLocation(p)].join(",") + "]"))
				else
					answerOut(hxc.compiler.DisplayXml.printPositions(impls));
				return;
			}
			if (hxc.typing.Typer.displayUsage) {
				var usages = collectUsages(ctx);
				if (ctx.jsonRpcId != null)
					answerOut(jsonRpcAnswer(ctx, "[" + [for (p in usages) jsonLocation(p)].join(",") + "]"))
				else
					answerOut(hxc.compiler.DisplayXml.printPositions(usages));
				return;
			}
			if (hxc.typing.Typer.fieldCompletionFound != null) {
				if (ctx.jsonRpcId != null) {
					var out = jsonCompletion(ctx);
					answerOut(out == null ? jsonRpcAnswer(ctx, "null") : out);
					return;
				}
				// The field printer supplies the list terminator; append no newline.
				answerOut(hxc.compiler.DisplayXml.printFields(hxc.typing.Typer.fieldCompletionFound));
				return;
			}
			// Signature display raises its answer, so a request that never reached one is not answered at
			// all - it falls through to the compile's own errors (such as "Not a callable type"), or to "no
			// completion point was found". An empty signature list would swallow that error.
			if (isDisplay(ctx, "signature") && hxc.typing.Typer.signatureFound != null) {
				if (ctx.jsonRpcId != null) {
					answerOut(jsonSignature(ctx));
					return;
				}
				displaySignature(ctx);
				return;
			}
			// A display position sitting on a metadata ENTRY completes the metadata name. That answer
			// raises from inside typing, so a field or type completion at the same spot answers first; here
			// the check runs after typing, so it has to come after every other answer has declined.
			// The parser flags it, because it is the only stage that sees only what the SOURCE wrote: a
			// typed field's metadata also holds injected entries, and those carry the position of the field
			// itself, which would swallow a completion anywhere in it.
			if (hxc.parser.Parser.displayMetaFound) {
				answerMetadataCompletion(ctx);
				return;
			}
			// A display mode that EXITS during typing has to have been answered by then. Reaching this point
			// means no hook covered the position, which is an error the client relies on, not a silent
			// success. An actual compile error wins: the request aborts on a recorded error before reporting
			// a missing completion point. The DELAYED type-declaration keyword list is answered here, once
			// nothing more specific has claimed the position.
			if (hxc.parser.Parser.delayedSyntaxCompletion != null && hxc.parser.Parser.displayCompletionMode) {
				// The XML lane prints the keywords; the JSON lane sends the same list as a completion
				// result. The type-declaration completion kind is 14.
				if (ctx.jsonRpcId != null)
					answerOut(jsonRpcAnswer(ctx, jsonKeywordCompletion(ctx, hxc.parser.Parser.delayedSyntaxCompletion, 14,
						hxc.parser.Parser.delayedSyntaxSubject == null ? null : hxc.parser.Parser.delayedSyntaxSubject.name,
						hxc.parser.Parser.delayedSyntaxSubject == null ? null : hxc.parser.Parser.delayedSyntaxSubject.pos)));
				else
					answerOut(hxc.compiler.DisplayXml.printKeywords(hxc.parser.Parser.delayedSyntaxCompletion));
				return;
			}
			// The request aborts with the recorded errors before reporting a missing point - but a COMMENT
			// that answered the request means lexing stopped there and the file was never typed at all, so
			// there are no errors to abort with. hxc lexes ahead and types, so its errors have to step
			// aside here.
			if (hxc.parser.Parser.displayFile != null
				// The abort reads the compilation context's error flag, which is set only where an error was
				// MESSAGED. A display run SWALLOWS the display file's own errors under the ignore-errors policy
				// and sets com's flag alone, reporting nothing. Asking com here would exit 1 in SILENCE on any
				// display file carrying a swallowed error, where the missing completion point must still be
				// reported.
					&& (!ctx.hasReportedError() || hxc.parser.Parser.commentAnswered)) {
				var dm = displayParts(ctx);
				var dmode = displayMode(ctx, dm);
				// No completion point was found, and the display file has a block only the MACRO context turns
				// on - so load it there and let the hooks fire against the macro-world types. Besides a
				// .macro.hx root and the parser's DisplayInMacroBlock raise, this is the third place a display
				// module loads in the macro context, the one that covers `#if macro` inside an ordinary file. A
				// display answer raised in there is the result, so it must not be caught here.
				if (hxc.parser.Parser.displayModuleHasMacroDefines && displayRoot != null)
					hxc.eval.EvalMacro.loadDisplayModuleInMacro(ctx, displayRoot);
				switch (dmode) {
					case "" | "position" | "type" | "typeDefinition" | "signature" | "toplevel" | "package":
						// A JSON request answers DisplayNoResult, which is a null result; only the legacy
						// lane reports the missing point as an error.
						if (ctx.jsonRpcId != null) {
							answerOut(jsonRpcAnswer(ctx, "null"));
							return;
						}
						answerOut("Error: No completion point was found\n");
						exitRequest(1);
					case _:
				}
			}
			if (!isDisplay(ctx, "diagnostics")) abortOnDiagnostics(ctx, platform);
			// Null safety runs before every expression filter and elimination so it sees the exprs as
			// typed.
			hxc.filters.DeprecationCheck.run(ctx);
			hxc.filters.NullSafety.run(ctx, ctx.types);
			// UnusedPure runs in Filters.run after inline_constructors: an inlined value block ends with a
			// read of its result local, and inline constructors consume exactly that read to splice the
			// block flat. Dropping the read earlier would leave a nested value-typed block for DCE to mark.
			hxc.typing.Finalization.run(ctx);
			// A fully-typed compile that populates the cache caches its modules into the process cache,
			// activating server/module and server/type lookups for later requests in the same process. Both
			// flags hold outside display runs, and a JSON diagnostics request sets them again, being a
			// whole-program report compilation; the LEGACY diagnostics request does not populate the cache.
			// A compilation that ERRORED is not cached, so its half-typed modules are not offered to the
			// next request.
			if (!ctx.hasError() && (ctx.displaySpec == null || (isDisplay(ctx, "diagnostics") && ctx.jsonRpcId != null))) {
				hxc.context.DisplayJson.cache.cacheContext(ctx);
				// The modules of the com being finished are cached, and the MACRO com is one of those (a
				// fresh one per compilation). Its modules carry the macro signature, so they land in that
				// context and the server's module check can report on them like any other.
				var mw = hxc.eval.EvalMacro.macroWorld();
				if (mw != null) hxc.context.DisplayJson.cache.cacheContext(mw);
				hxc.compiler.ServerMessage.cachedModules(ctx, "", ctx.modules.length);
			}
			if (!isDisplay(ctx, "diagnostics")) abortOnDiagnostics(ctx, platform);
			// The --xml / --json type descriptions are written after typing but before the target
			// generation, and are not gated on --no-output.
			function auxiliaryOutput():Void {
				// The output file is logged first; `--xml hx` (the old hx generator) logs nothing.
				if (xmlOut != null) {
					if (xmlOut != "hx") ctx.log("Generating xml: " + xmlOut);
					var tX = hxc.core.Timer.timer(["generate", "xml"]);
					hxc.codegen.GenXml.generate(ctx, xmlOut);
					tX();
				}
				if (jsonOut != null) {
					ctx.log("Generating json : " + jsonOut);
					var tJ = hxc.core.Timer.timer(["generate", "json"]);
					var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
					var l = [for (mt in ctx.types) hxc.core.Json.Json.stringOfJson(gen.generateModuleType(mt))];
					var jdir = haxe.io.Path.directory(jsonOut);
					if (jdir != "" && !sys.FileSystem.exists(jdir)) sys.FileSystem.createDirectory(jdir);
					sys.io.File.saveContent(jsonOut, "[" + l.join(",") + "]");
					tJ();
				}
			}
			// The shared filter pipeline also runs for eval, where it supplies inline constructors,
			// exception lowering, and closure/local passes before interpretation. Filters run even under
			// --no-output (only generation is gated on it), so analyzer value checks still report. In a
			// report mode an error MESSAGED during typing aborts here, before typing is finalized and before
			// the filters. A diagnostics request that meets one therefore gets no json report at all and the
			// message is printed plainly, exit 1. It reads the compilation context's printed-error flag,
			// which only addPrintedError sets - adding a diagnostics message does not - so an ordinary
			// typing error still produces the report as usual.
			if (isDisplay(ctx, "diagnostics") && ctx.hasPrintedError()) {
				// Only the printed errors (addPrintedError) are printed. Under a diagnostics request
				// everything else was
				// routed to the diagnostics store instead - an ordinary typing error goes there, and so do
				// info and warnings - and that store is only ever rendered by the report, which this path
				// does not produce.
				ctx.diagnostics = ctx.diagnostics.filter(function(d) return d.printedOnly == true);
				abortOnDiagnostics(ctx, platform);
			}
			{
				var tFilter = hxc.core.Timer.timer(["filters"]);
				hxc.filters.Filters.run(new hxc.typing.TyperContext(ctx));
				tFilter();
				if (isDisplay(ctx, "diagnostics")) {
					displayDiagnostics(ctx);
					return;
				}
				abortOnDiagnostics(ctx, platform);
				// Typer/compiledTypes: every compiled type serializes after the filters.
				if (ctx.jsonRpcId != null && isDisplay(ctx, "compiledTypes")) {
					var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
					var l = [for (mt in ctx.types) hxc.core.Json.Json.stringOfJson(gen.generateModuleType(mt))];
					answerOut(jsonRpcAnswer(ctx, "[" + l.join(",") + "]"));
					return;
				}
				auxiliaryOutput();
				// The dump happens at generation time, after every filter including the analyzer, so it shows
				// the tree generation actually sees. It is part of Generate.generate, which --no-output skips.
				if (!noOutput) {
					hxc.debug.Dump.run(ctx);
					// After the dump and before the generator runs; cppia is the cpp generator and logs as
					// "cpp".
					if (platform == Js) {
						ctx.log("Generating js: " + ctx.file);
						var tGen = hxc.core.Timer.timer(["generate", "js"]);
						hxc.generators.GenJS.generate(ctx);
						tGen();
					} else if (platform == Cpp) {
						ctx.log("Generating cpp: " + ctx.file);
						var tGen = hxc.core.Timer.timer(["generate", "cpp"]);
						hxc.generators.GenCpp.generate(ctx);
						tGen();
					}
				}
			}
			hxc.eval.EvalMacro.runAfterGenerateCallbacks();
			// A generator error (a printed error during generation, e.g. a bad @:native code placeholder)
			// fails
			// the compile like the final error check does, so a real target that printed an error does not
			// exit 0.
			abortOnDiagnostics(ctx, platform);
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
			}
			// --cmd commands run in order after a successful compile; a `cd ` command changes the working
			// directory, any other spawns a shell command.
			if (!noOutput) for (c in cmds) {
				var r = runCommand(ctx, c);
				if (r != 0) throw "Command failed with error " + r;
			}
		} catch (mj:hxc.context.DisplayJson.JsonDisplayOutput) {
			// Sending a json result raises a completion answer, so a macro that sent one ends the request
			// there and the compilation answers nothing further.
			answerOut(mj.output);
			return;
		} catch (tl:hxc.typing.Typer.JsonToplevelCompletion) {
			var answer = jsonToplevelCompletion(ctx, tl.items, tl.subjectName, tl.subjectPos, tl.wt, tl.patternOutermost, tl.noClass);
			if (answer != null) answerOut(answer);
			return;
		} catch (tc:hxc.parser.Parser.TypePathCompletion) {
			handleTypePathCompletion(ctx, tc);
			return;
		} catch (dp:hxc.compiler.DisplayXml.DisplayPositions) {
			answerOut(hxc.compiler.DisplayXml.printPositions(dp.positions));
			return;
		} catch (sc:hxc.compiler.DisplayXml.SyntaxCompletion) {
			if (ctx.jsonRpcId != null)
				answerOut(jsonRpcAnswer(ctx, jsonKeywordCompletion(ctx, sc.keywords, sc.kind, sc.subjectName, sc.subjectPos)));
			else
				answerOut(hxc.compiler.DisplayXml.printKeywords(sc.keywords));
			return;
		} catch (tl:hxc.compiler.DisplayXml.ToplevelCompletion) {
			// Metadata display raises at the metadata ENTRY, so a cursor on the entry answers with the
			// registry and not with whatever the expression the metadata is attached to would have
			// completed to.
			if (hxc.parser.Parser.displayMetaFound) { answerMetadataCompletion(ctx); return; }
			// The same collection answers as JSON when json output is set.
			if (ctx.jsonRpcId != null && tl.moduleTypes != null) {
				answerOut(jsonRpcAnswer(ctx, jsonTypeCompletion(ctx, tl)));
				return;
			}
			// No trailing newline: the completion string prints verbatim.
			{
				var seen = new haxe.ds.StringMap<Bool>();
				for (it in tl.items) if (it.path != null) seen.set(it.path, true);
				heritageScan(ctx, tl, seen, function(sf, td) switch (td.decl) {
					case EClass(d):
						var nm = d.dName.name;
						tl.items.push({kind: "type", name: nm,
							path: (sf.pack.length == 0 ? "" : sf.pack.join(".") + ".")
								+ (nm == sf.moduleName ? nm : sf.moduleName + "." + nm)});
					case _:
				});
			}
			answerOut(hxc.compiler.DisplayXml.printToplevel(tl.items));
			return;
		} catch (ex:hxc.eval.EvalExceptions.EvalRunTimeException) {
			printUncaughtException(ctx, ex, Position.nullPos);
		} catch (ch:hxc.parser.Parser.DisplayConditionHover) {
			answerConditionHover(ctx, ch);
			return;
		} catch (_:hxc.parser.Parser.DisplayNoResult) {
			// It was raised while the display file was parsed and it unwinds the whole compile, as any
			// display answer does. The legacy lane answers with an empty completion - nothing printed, exit
			// 0 - and the json lane with a null result.
			if (ctx.jsonRpcId != null) answerOut(jsonRpcAnswer(ctx, "null"));
			return;
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
			abortWithMessage(ctx, e.message, e.pos, e.depth, e.callChain);
		} catch (e:hxc.core.TypingError) {
			if (isDisplay(ctx, "diagnostics")) return diagnosticsAbort(ctx, e.message, e.pos, 2, e.depth);
			abortWithMessage(ctx, e.message, e.pos, e.depth, e.callChain);
		} catch (e:hxc.core.TypingError.FatalError) {
			// On the request path. Only a true fatal error travels past the diagnostics machinery: typing,
			// parser and lexer errors are caught there, so one of those still becomes a report even though
			// nothing on the way caught it. hxc's FatalError carries which kind it is.
			if (!e.bypassesDiagnostics && isDisplay(ctx, "diagnostics"))
				return diagnosticsAbort(ctx, e.message, e.pos, 2, e.depth);
			abortWithMessage(ctx, e.message, e.pos, e.depth, e.callChain);
		} catch (e:hxc.eval.EvalExceptions.HostException) {
			// A failure is "Error: <message>", any other native exception prints as itself, both at a null
			// position - reported through the message list, behind the messages already recorded, so a
			// warning the compile queued before it prints first.
			abortWithMessage(ctx, (e.failure ? "Error: " : "") + e.message, Position.nullPos);
		} catch (e:hxc.core.JsonRpc.InvalidArgument) {
			// An uncaught Invalid_argument prints bare on stderr and exits 1.
			answerOut("Invalid_argument(\"" + e.arg + "\")\n");
			exitRequest(1);
		} catch (e:RequestAbort) {
			// The request already reported and chose its exit code; it unwinds to the wait loop
			// rather than being reported a second time as an unexpected error.
			throw e;
		} catch (e:hxc.eval.EvalExceptions.EvalSysExit) {
			// An exit request is re-raised past the catch-all so it reaches the exit handler with its code
			// intact.
			throw e;
		} catch (e:Dynamic) {
			answerOut("Error: " + Std.string(e) + "\n");
			exitRequest(1);
		}
		// Collected messages display at the very end, after generation (which runs the --interp program)
		// and any --cmd. A clean run and an uncaught interp exception both reach here, so a deferred
		// warning follows the program's own output rather than preceding it. Compile errors abort earlier
		// via abortWithMessage and flush there.
		flushPendingMessages(ctx);
		if (hxc.core.Timer.measureTimes) {
			hxc.core.Timer.closeTimes();
			hxc.core.Timer.reportTimes(function(s) answerOut(s + "\n"));
		}
	}

	// One line per entry: " name: params doc (platform only) (from source)", wrapped at 80 columns.
	static function printUserDocs(entries:Array<{name:String, entry:hxc.context.Context.UserDocEntry, isMeta:Bool}>):Void {
		entries.sort(function(a, b) return a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
		var maxLen = 0;
		for (en in entries) if (en.name.length > maxLen) maxLen = en.name.length;
		for (en in entries) {
			var d = en.entry;
			var doc = docString(d.params, d.doc, d.platforms, en.isMeta, d.source);
			Sys.println(" " + StringTools.rpad(en.name, " ", maxLen) + ": " + limitString(doc, maxLen + 3));
		}
	}

	// Every COMPILER define/metadata is printed, sorted by name, padded to the longest, through the same
	// 80-column wrap the user variants use. A metadata carries its leading `@` and an internal entry is
	// skipped.
	static function printCompilerDocs(isMeta:Bool):Void {
		var R = hxc.context.MetaRegistry;
		var rows:Array<{name:String, doc:String}> = [];
		for (e in (isMeta ? R.metas() : R.defines())) {
			if (R.boolField(e, "internal")) continue;
			var name = R.stringField(e, isMeta ? "metadata" : "define", "");
			if (name == "") continue;
			// A define's documented name joins its `_`-separated parts with dashes, so a define is listed
			// with dashes; a metadata keeps its name and gains the leading `@`. The rename happens before
			// the list is sorted, so it decides the ordering too.
			var shown = isMeta ? "@" + name : name.split("_").join("-");
			rows.push({name: shown, doc: registryDoc(e, isMeta)});
		}
		rows.sort(function(a, b) return a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
		var maxLen = 0;
		for (r in rows) if (r.name.length > maxLen) maxLen = r.name.length;
		for (r in rows) Sys.println(" " + StringTools.rpad(r.name, " ", maxLen) + ": " + limitString(r.doc, maxLen + 3));
	}

	static function registryDoc(e:Array<hxc.core.Json.JsonField>, isMeta:Bool):String {
		var R = hxc.context.MetaRegistry;
		var params = [for (p in R.arrayField(e, "params")) switch (p) { case JString(v): v; case _: ""; }];
		// The platform list holds the json order and is printed reversed. The params are collected by
		// prepending per entry and then reversed, which restores json order - which is why params are not
		// reversed here.
		var plats = [for (p in R.arrayField(e, "platforms")) switch (p) { case JString(v): v; case _: ""; }];
		plats.reverse();
		return docString(params, R.stringField(e, "doc", ""), plats, isMeta);
	}

	// The documentation is one assembled string and every reader prints it: the --help list, the user
	// variants, and the hover `<metadata>` answer. The parts are the params prefix, the doc, the
	// platform list and the origin; a define differs only in how it brackets the params.
	static function docString(params:Array<String>, doc:String, platforms:Array<String>, isMeta:Bool,
			?origin:String):String {
		var pstr = params.length == 0 ? ""
			: (isMeta ? "(<" + params.join(">, <") + ">) " : "<" + params.join(">, <") + "> ");
		var pfs = switch (platforms.length) {
			case 0: "";
			case 1: " (" + platforms[0] + " only)";
			case _: " (for " + platforms.join(",") + ")";
		};
		return pstr + doc + pfs + (origin == null ? "" : " (from " + origin + ")");
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

	// %name% reads the environment first, then the supplied table, and an unresolved name stays as it
	// was written.
	static function expandEnv(path:String, h:Map<String, String>):String {
		var r = ~/%([A-Za-z0-9_]+)%/;
		var out = new StringBuf();
		var rest = path;
		while (r.match(rest)) {
			var key = r.matched(1);
			out.add(r.matchedLeft());
			var v = Sys.getEnv(key);
			if (v == null) v = h.get(key);
			out.add(v == null ? "%" + key + "%" : v);
			rest = r.matchedRight();
		}
		out.add(rest);
		return out.toString();
	}

	public static function runCommand(ctx:Context, cmd:String):Int {
		// A server request expands __file__ and __platform__ before running the command.
		if (requestOutput != null) {
			var h = new Map<String, String>();
			h.set("__file__", ctx.file == null ? "" : ctx.file);
			h.set("__platform__", Globals.platformName(ctx.platform));
			cmd = expandEnv(cmd, h);
		}
		// A "cd " with something after it changes the directory.
		if (cmd.length > 3 && StringTools.startsWith(cmd, "cd ")) {
			hxc.core.Cwd.set(cmd.substr(3));
			return 0;
		}
		// The command's streams are PIPED, and two threads relay what it writes as it writes it: stdout
		// through the compilation's output writer, stderr through its error writer (commWriteOut,
		// commWriteErr). Its stdin is a pipe nothing writes to.
		var proc = new sys.io.Process(cmd);
		function relay(input:haxe.io.Input, write:(haxe.io.Bytes, Int) -> Void):sys.thread.Lock {
			// Thread.create: the relay thread takes the next thread ident.
			hxc.compiler.HostRuntime.threadCreated();
			var done = new sys.thread.Lock();
			sys.thread.Thread.create(function() {
				// Read 1024 bytes at a time until a read answers nothing.
				var buf = haxe.io.Bytes.alloc(1024);
				try while (true) {
					var n = input.readBytes(buf, 0, 1024);
					if (n <= 0) break;
					write(buf, n);
				} catch (_:Dynamic) {}
				done.release();
			});
			return done;
		}
		var tout = relay(proc.stdout, commWriteOut);
		var terr = relay(proc.stderr, commWriteErr);
		// The two thread joins and closing the process are blocking sections.
		var released = hxc.eval.EvalStdLib.gilRelease();
		var code = try {
			tout.wait();
			terr.wait();
			// The exit status, whatever ended the process.
			var c = proc.exitCode();
			proc.close();
			c;
		} catch (e:Dynamic) {
			if (released) hxc.eval.EvalStdLib.gilReacquire();
			throw e;
		}
		if (released) hxc.eval.EvalStdLib.gilReacquire();
		return code;
	}

	// Print to stdout, then flush. In a request, the chunk goes into the request's buffer as an "\x01"
	// line.
	static function commWriteOut(b:haxe.io.Bytes, n:Int):Void {
		var req = requestOutput;
		if (req != null) {
			req.writeOut(b, 0, n);
			return;
		}
		var out = Sys.stdout();
		out.writeFullBytes(b, 0, n);
		out.flush();
	}

	// Write to the stderr channel. In a request, the chunk goes into the request's buffer as it is.
	static function commWriteErr(b:haxe.io.Bytes, n:Int):Void {
		var req = requestOutput;
		if (req != null) {
			req.addBytes(b, 0, n);
			return;
		}
		hxc.compiler.HostRuntime.stderrWrite(b, 0, n);
	}

	static function parseTypePath(s:String):Path {
		// A .hx file path is accepted where a class is expected (haxe -x Main.hx).
		var parts = getPathParts(s);
		var name = parts.pop();
		return {pack: parts, name: name};
	}

	// An uncaught interpreted exception prints its value at the throw position when one exists (dropping
	// the innermost duplicate stack frame), else at the catch position, then each stack frame
	// outermost-first as Called from here.
	static function printUncaughtException(ctx:Context, ex:hxc.eval.EvalExceptions.EvalRunTimeException, catchPos:Position):Void {
		if (catchPos == null) catchPos = Position.nullPos;
		// A haxe.macro.Error is an error of its own, its message at its position wherever that is (an init
		// macro's has min -1); any other value is uncaught.
		var info = hxc.eval.EvalMacro.runtimeMacroError(ex);
		if (info != null) {
			if (info.stack != null) {
				var stack:Array<{message:String, pos:Position, ?depth:Int}> = [for (m in info.stack) {message: m.message, pos: qualifyStdPosition(ctx, m.pos)}];
				ctx.addDiagnosticStack(stack);
			} else ctx.addDiagnostic(info.message, qualifyStdPosition(ctx, info.pos));
			flushPendingMessages(ctx);
			exitRequest(1);
		}
		// Frames run innermost first; an explicit throw position drops the innermost frame it duplicates.
		// The stack closes at the call's own entry environment, so the catch position only heads a raise
		// without a position of its own.
		var frames = [for (env in ex.envStack) qualifyStdPosition(ctx, hxc.eval.EvalExceptions.envPosition(env))];
		// Only a frame at the null position is dropped.
		frames = [for (p in frames) if (p != null && !hxc.eval.EvalExceptions.isNullPos(p)) p];
		var explicit = ex.pos != null && !(ex.pos.file == "?" && ex.pos.min < 0);
		if (explicit && frames.length > 0) frames.shift();
		var p1 = explicit ? ex.pos : catchPos;
		// Reported through the message list so every -D message.reporting formatter renders it.
		var stack = [{message: "Uncaught exception " + hxc.eval.EvalStdLib.stringOf(ex.value), pos: p1}];
		for (p in frames) stack.push({message: "Called from here", pos: p});
		ctx.addDiagnosticStack(stack);
		flushPendingMessages(ctx);
		exitRequest(1);
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

	// A legacy `file@pos@mode` names one of these modes, and any other is the default mode, the same
	// request as a bare `file@pos` (only the `display` define keeps the name written). The JSON path's own
	// mode names are not legacy ones and pass through.
	static final legacyModes = ["", "position", "usage", "package", "type", "toplevel", "module-symbols",
		"diagnostics", "statistics", "signature"];

	static function displayMode(ctx:Context, dparts:Array<String>):String {
		var dmode = dparts.length >= 3 ? dparts[2] : "";
		if (ctx.jsonRpcId != null || legacyModes.indexOf(dmode) >= 0 || dmode == "workspace-symbols") return dmode;
		return "";
	}

	// A path part is a package name except for the last, which is the module name; a rejected part makes
	// the whole candidate unusable. A package name wants a lowercase or _ first character, and every part
	// is checked for invalid characters.
	static function parsePathParts(rest:String):Null<Path> {
		var parts = getPathParts(rest);
		if (parts.length == 0) return null;
		function invalidChar(x:String):Bool {
			for (i in 1...x.length) {
				var c = x.charCodeAt(i);
				var ok = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code)
					|| (c >= "0".code && c <= "9".code) || c == "_".code || c == ".".code;
				if (!ok) return true;
			}
			return false;
		}
		var name = parts[parts.length - 1];
		if (invalidChar(name)) return null;
		var pack = parts.slice(0, parts.length - 1);
		for (x in pack) {
			if (x.length == 0) return null;
			var c = x.charCodeAt(0);
			if ((c < "a".code || c > "z".code) && c != "_".code) return null;
			if (invalidChar(x)) return null;
		}
		return {pack: pack, name: name};
	}

	// The display file's module path is its path relative to the classpath that contains it, keeping the
	// SHORTEST dot path across classpaths (a tie keeps the earlier classpath).
	static function displayModulePath(ctx:Context, file:String):Null<Path> {
		// The display file is held by its unique key (lowercased on Windows) and read back through the
		// real-path lookup, which spells each component that exists the way the file system does: a display
		// file that does not exist names its module in lower case.
		var real = StringTools.replace(hxc.core.PathKey.realPath(hxc.core.PathKey.key(file)), "\\", "/");
		var cps = ctx.classPath.concat(ctx.stdPath);
		function loop(i:Int):Null<Path> {
			if (i >= cps.length) return null;
			// The class path's real path with a trailing slash added, then an exact prefix
			var c = StringTools.replace(hxc.core.PathKey.realPath(cps[i] == "" ? "./" : cps[i]), "\\", "/");
			if (!StringTools.endsWith(c, "/")) c += "/";
			if (c.length >= real.length || c != real.substr(0, c.length)) return loop(i + 1);
			var parsed = parsePathParts(real.substr(c.length));
			if (parsed == null) return loop(i + 1);
			var other = loop(i + 1);
			if (other != null && sTypePath(other).length < sTypePath(parsed).length) return other;
			return parsed;
		}
		return loop(0);
	}

	static function sTypePath(p:Path):String {
		return p.pack.length == 0 ? p.name : p.pack.join(".") + "." + p.name;
	}

	// Legacy --display @package answers the package of that same derived module path.
	static function displayFilePackage(ctx:Context, file:String):String {
		var path = displayModulePath(ctx, file);
		return path == null ? "" : path.pack.join(".");
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

	static function modKey(m:hxc.core.Type.ModuleDef):String {
		return m.path.pack.join(".") + "." + m.path.name;
	}

	// The cursor on a type declaration name makes that type the subject, for a class, enum, typedef or
	// abstract alike.
	static function usageTypeAtDeclaration(ctx:Context):Null<hxc.core.Type.ModuleType> {
		for (mt in ctx.types)
			if (hxc.typing.Typer.atHoverPos(TypeFunctions.tInfos(mt).namePos)) return mt;
		return null;
	}

	// Scan every typed field body for references to the captured @usage target; positions sort in
	// source order. A non-static field search expands its target to a set of declarations, and only an
	// access resolving to one of them counts (the position check gates both the direct relation and
	// the related-class walk). It walks UP to the topmost class still declaring the name when the base
	// is wanted, then prefers the INTERFACES of whatever class that landed on, and then replaces the
	// whole set with every class in the compilation that extends one of them and declares the name.
	static function referenceTargets(ctx:Context, cf:hxc.core.Type.TClassField):Array<hxc.core.Type.TClassField> {
		var findDescendants = hxc.context.DisplayJson.usageDescendants;
		var findBase = hxc.context.DisplayJson.usageBase;
		if ((!findDescendants && !findBase) || TypeFunctions.hasClassFieldFlag(cf, CfStatic)) return [cf];
		var owner:Null<hxc.core.Type.TClass> = null;
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c2):
				for (f in c2.orderedFields) if (f == cf) { owner = c2; break; }
				if (owner != null) break;
			case _:
		}
		if (owner == null) return [cf];
		var baseCf = cf, baseC = owner;
		if (findBase) {
			var c2 = owner;
			while (c2.superClass != null) {
				var sup = c2.superClass.c;
				var f = sup.fields.get(cf.name);
				if (f == null) break;
				baseCf = f; baseC = sup; c2 = sup;
			}
		}
		// An interface that declares the name replaces the class in the set, recursively, so the search
		// is rooted at the topmost declaration of the member.
		function loopIface(c2:hxc.core.Type.TClass):Array<{cf:hxc.core.Type.TClassField, c:hxc.core.Type.TClass}> {
			var acc:Array<{cf:hxc.core.Type.TClassField, c:hxc.core.Type.TClass}> = [];
			for (i in c2.interfaces) for (r in loopIface(i.c)) acc.push(r);
			if (acc.length > 0) return acc;
			var f = c2.fields.get(cf.name);
			return f == null ? [] : [{cf: f, c: c2}];
		}
		var pairs:Array<{cf:hxc.core.Type.TClassField, c:hxc.core.Type.TClass}> = [];
		for (i in baseC.interfaces) for (r in loopIface(i.c)) pairs.push(r);
		if (pairs.length == 0) pairs = [{cf: baseCf, c: baseC}];
		if (!findDescendants) return [for (pr in pairs) pr.cf];
		// Extends is reflexive and follows both superclasses and interfaces.
		function ext(c2:hxc.core.Type.TClass, csup:hxc.core.Type.TClass):Bool {
			if (c2 == csup) return true;
			for (i in c2.interfaces) if (ext(i.c, csup)) return true;
			return c2.superClass == null ? false : ext(c2.superClass.c, csup);
		}
		var out:Array<hxc.core.Type.TClassField> = [];
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(child):
				var hit = false;
				for (pr in pairs) if (ext(child, pr.c)) { hit = true; break; }
				if (!hit) continue;
				var f = child.fields.get(cf.name);
				if (f != null) out.push(f);
			case _:
		}
		return out.length == 0 ? [cf] : out;
	}

	// An occurrence is reported as the name's width back from the end of the expression, not as the
	// expression's own span.
	static function patchStringPos(p:Position, name:String):Position {
		return new Position(p.file, p.max - name.length, p.max);
	}

	static function collectUsages(ctx:Context):Array<Position> {
		var cf = hxc.typing.Typer.usageTargetField;
		var v = hxc.typing.Typer.usageTargetVar;
		var ef = hxc.typing.Typer.usageTargetEnumField;
		var mtTarget = hxc.typing.Typer.usageTargetType;
		if (cf == null && v == null && ef == null && mtTarget == null) mtTarget = usageTypeAtDeclaration(ctx);
		if (cf == null && v == null && ef == null) cf = usageFieldAtDeclaration(ctx);
		var out:Array<Position> = [];
		if (cf == null && v == null && ef == null && mtTarget == null) return [];
		if (mtTarget != null) {
			// References are folded over the DECLARED symbols, and exactly the types of com.types and of
			// the macro com's are declared: a type that is in neither - a type parameter's class - has no
			// symbol, so nothing is reported for it.
			// The declaration itself decides, not the ModuleType wrapper around it.
			function isTarget(mt:hxc.core.Type.ModuleType):Bool {
				return switch [mt, mtTarget] {
					case [TClassDecl(a), TClassDecl(b)]: a == b;
					case [TEnumDecl(a), TEnumDecl(b)]: a == b;
					case [TTypeDecl(a), TTypeDecl(b)]: a == b;
					case [TAbstractDecl(a), TAbstractDecl(b)]: a == b;
					case _: false;
				};
			}
			var declared = Lambda.exists(ctx.types, isTarget);
			if (!declared) {
				var mw = hxc.eval.EvalMacro.macroWorld();
				declared = mw != null && mw != ctx && Lambda.exists(mw.types, isTarget);
			}
			if (!declared) return [];
			var want = TypeFunctions.tInfos(mtTarget).namePos;
			// A relation is added on each promoted type hint. The position check compares both ends and the
			// file, so an occurrence counts only when the hint resolved to this very declaration.
			var mods = new Map<String, Bool>();
			for (t in ctx.types) mods.set(modKey(TypeFunctions.tModule(t)), true);
			for (h in hxc.typing.Typeload.typeHints) {
				// Only modules that survived into com.types are checked, so a hint recorded from a
				// discarded module contributes nothing.
				if (h.m == null || !mods.exists(modKey(h.m))) continue;
				var hmt = try TypeFunctions.moduleTypeOfType(h.t) catch (_:hxc.core.ExitException) null;
				if (hmt == null) continue;
				var got = TypeFunctions.tInfos(hmt).namePos;
				if (got.min != want.min || got.max != want.max || got.file != want.file) continue;
				if (h.p.min == want.min && h.p.max == want.max && h.p.file == want.file) continue;
				var dup = false;
				for (o in out) if (o.min == h.p.min && o.max == h.p.max && o.file == h.p.file) { dup = true; break; }
				if (!dup) out.push(h.p);
			}
			// Type expressions also count as references.
			function walkT(e:hxc.core.Type.TExpr):Void {
				switch (e.expr) {
					// Reports the type name's width back from the end of the expression.
					case TTypeExpr(mt2) if (TypeFunctions.tInfos(mt2).namePos == want):
						out.push(patchStringPos(e.pos, TypeFunctions.tPath(mt2).name));
					case _:
				}
				hxc.core.TexprTools.iter(walkT, e);
			}
			for (mt in ctx.types) switch (mt) {
				case TClassDecl(c):
					var all = c.orderedFields.concat(c.orderedStatics);
					if (c.constructor != null) all.push(c.constructor);
					for (f in all) if (f.expr != null) walkT(f.expr);
				case _:
			}
			out.sort(function(a, b) {
				if (a.file != b.file) return a.file < b.file ? -1 : 1;
				return a.min - b.min;
			});
			return out;
		}
		// Collecting references. The recursion is explicit per node: a TField only walks its receiver when
		// that receiver is genuinely SHORTER (which is how a generated access is told apart), and
		// TTypeExpr, TNew and a super call do not walk into anything the arm did not name.
		var cfTargets = cf == null ? [] : referenceTargets(ctx, cf);
		function walk(e:hxc.core.Type.TExpr):Void {
			switch (e.expr) {
				case TField(e1, fa):
					if (e1.pos.min == e.pos.min && e1.pos.max != e.pos.max) walk(e1);
					switch (fa) {
						case FInstance(_, _, cf2):
							if (cf != null && (cf2 == cf || cfTargets.indexOf(cf2) >= 0))
								out.push(patchStringPos(e.pos, cf2.name));
						case FClosure(_, cf2):
							// A closure over an instance field is the same relation as an access.
							if (cf != null && (cf2 == cf || cfTargets.indexOf(cf2) >= 0))
								out.push(patchStringPos(e.pos, cf2.name));
						case FAnon(cf2) | FStatic(_, cf2):
							// A field reference is reported as the field name's width back from the end of the access,
							// so a property read through its getter `get_x` reports two characters before the `x` the
							// source wrote.
							if (cf != null && cf2 == cf) out.push(patchStringPos(e.pos, cf2.name));
						case FEnum(_, ef2):
							if (ef != null && ef2 == ef) out.push(patchStringPos(e.pos, ef2.name));
						case FDynamic(_):
					}
				// A local reference is keyed by the declaration's position, not by the tvar object: the matcher
				// duplicates its tvars, so a pattern variable's uses carry a different object than the one that
				// was captured. Only a use whose span is exactly the name's width counts, which leaves out the
				// synthesized locals a desugaring reuses the name for.
				case TLocal(v2) if (v != null && (v2 == v || (v2.name == v.name
						&& v2.pos.min == v.pos.min && v2.pos.max == v.pos.max
						&& v2.pos.file == v.pos.file))
					&& e.pos.max - e.pos.min == v2.name.length): out.push(e.pos);
				// Walk constructor arguments and report the construction's original span.
				case TNew(c2, _, el):
					for (a in el) walk(a);
					if (cf != null && c2.constructor == cf) out.push(e.pos);
				// A `super(...)` call references the super constructor, and the whole call expression is
				// the occurrence.
				case TCall({expr: TConst(TSuper), type: st}, el):
					for (a in el) walk(a);
					if (cf != null) switch (TypeFunctions.follow(st)) {
						case TInst(sc, _):
							var cur = sc;
							while (cur != null && cur.constructor != cf) cur = cur.superClass == null ? null : cur.superClass.c;
							if (cur != null) out.push(e.pos);
						case _:
					}
				case _:
					hxc.core.TexprTools.iter(walk, e);
			}
		}
		// After com.types the walk RECURSES into the macro com's types, so a reference that only exists in
		// the macro world - anything a macro function's own body does with its arguments - is counted too.
		// The host keeps no body for a macro field, so without this those uses are invisible.
		function walkTypes(types:Array<hxc.core.Type.ModuleType>):Void {
			for (mt in types) switch (mt) {
				case TClassDecl(c):
					var all = c.orderedFields.concat(c.orderedStatics);
					if (c.constructor != null) all.push(c.constructor);
					for (f in all) if (f.expr != null) walk(f.expr);
				case _:
			}
		}
		walkTypes(ctx.types);
		var mw = hxc.eval.EvalMacro.macroWorld();
		if (mw != null && mw != ctx) walkTypes(mw.types);
		// A relation is recorded once per position, so an occurrence both worlds typed - the display file's
		// own classes in a module the macro world loaded whole and finalized - is one usage.
		var seenPos = new Map<String, Bool>();
		var uniq:Array<Position> = [];
		for (o in out) {
			var k = o.file + ":" + o.min + ":" + o.max;
			if (seenPos.exists(k)) continue;
			seenPos.set(k, true);
			uniq.push(o);
		}
		out = uniq;
		out.sort(function(a, b) {
			if (a.file != b.file) return a.file < b.file ? -1 : 1;
			return a.min - b.min;
		});
		return out;
	}

	// The cursor on a type declaration name answers with that type itself, for a class, enum, typedef
	// or abstract alike.
	static function displayTypeAtName(ctx:Context):Null<hxc.core.Type.ModuleType> {
		for (mt in ctx.types)
			if (hxc.typing.Typer.atHoverPos(TypeFunctions.tInfos(mt).namePos)) return mt;
		return null;
	}

	// A hover on a field declaration name has no enclosing expression; the typed field's signature is
	// the result.
	static function hoverOnFieldName(ctx:Context):Null<{t:T, p:Position, cf:hxc.core.Type.TClassField, c:hxc.core.Type.TClass, scope:hxc.core.Type.ClassFieldScope}> {
		for (mt in ctx.types) switch (mt) {
			// A field's name answers while the field BINDS. A module whose declarations raised (TypeResolve
			// markModuleErrored) binds only in the classes built before the error, and there only their
			// VARIABLES answer at once: a method answers from its body's typing, a PTypeField delay the
			// raise never lets run.
			case TClassDecl(c) if (!ctx.declErrored.exists(Context.pathKey(c.path))
					|| ctx.declBuiltBeforeError.exists(Context.pathKey(c.path))):
				var varsOnly = ctx.declErrored.exists(Context.pathKey(c.path));
				function found(cf:hxc.core.Type.TClassField, scope:hxc.core.Type.ClassFieldScope) {
					var t = switch (cf.type) {
						case TLazy(r): TypeFunctions.lazyType(r);
						case t: t;
					};
					return {t: t, p: cf.namePos, cf: cf, c: c, scope: scope};
				}
				// Every overload but the first is kept on the first one's overloads, so a declaration name is
				// only found by looking there too.
				function pick(cf:hxc.core.Type.TClassField):Null<hxc.core.Type.TClassField> {
					if (varsOnly && !cf.kind.match(Var(_))) return null;
					if (hxc.typing.Typer.atHoverPos(cf.namePos)) return cf;
					for (o in cf.overloads) if (hxc.typing.Typer.atHoverPos(o.namePos)) return o;
					return null;
				}
				for (cf in c.orderedFields) switch (pick(cf)) { case null: case hit: return found(hit, CFSMember); }
				for (cf in c.orderedStatics) switch (pick(cf)) { case null: case hit: return found(hit, CFSStatic); }
				if (!varsOnly && c.constructor != null && hxc.typing.Typer.atHoverPos(c.constructor.namePos)) return found(c.constructor, CFSConstructor);
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
		var got = TypeFunctions.tPath(mt);
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
		var active = sf.sigs.length == 0 ? sf.activeArg : signatureArgIndex(sf.sigs[0].args, sf.activeArg);
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
	// The toplevel collection: locals, then the enclosing class fields, then every loaded type sorted by
	// name, then the literal set and the keyword list; mode kind 2 with empty args.
	// A collection raised under a WithType reports that type, the same type with follow mapped over its
	// immediate children, and - for a @:structInit class - the anonymous structure its constructor
	// arguments describe. Anything else contributes no fields at all.
	static function expectedTypeFields(gen:hxc.core.Genjson, ct:T->hxc.core.CompletionItem.CompletionType,
			wt:Null<hxc.core.WithType.WithType>):Array<hxc.core.Json.JsonField> {
		var t = switch (wt) { case null: null; case WithType(t, _): t; case _: null; };
		if (t == null) return [];
		var tf = TypeFunctions.map(TypeFunctions.follow, TypeFunctions.follow(t));
		var compatible:Array<hxc.core.Json.JsonValue> = [];
		var an = hxc.typing.Typer.structInitAnonForCompletion(wt);
		if (an != null) compatible.push(hxc.core.CompletionItem.CompletionTypeTools.toJson(gen, ct(TAnon(an))));
		return [
			{name: "expectedType", value: hxc.core.CompletionItem.CompletionTypeTools.toJson(gen, ct(t))},
			{name: "expectedTypeFollowed", value: hxc.core.CompletionItem.CompletionTypeTools.toJson(gen, ct(tf))},
			{name: "compatibleTypes", value: hxc.core.Json.JsonValue.JArray(compatible)}
		];
	}

	// The collection and sort for every JSON completion: the raw entries in collection order, the cache's
	// files and packages, the sort when nothing has been typed, the raise site's filter, and the items
	// written last.
	static function jsonCollectedItems(ctx:Context, entries:Array<hxc.typing.Typer.JsonToplevelEntry>, subjectName:Null<String>,
			wt:Null<hxc.core.WithType.WithType>, inPattern:Bool, noClass:Bool = false):Array<hxc.context.DisplayException.CompletionEntry> {
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t);
		// The half of the collection that ADDS: each item registers its name as it is added, which is what
		// decides a later item's qualification and a later type's import status. An item's type is read
		// when it is added, before the sort can bind anything; the item is serialized after the sort.
		var pending:Array<{info:hxc.typing.Typer.JsonItemInfo, group:Int, key:String, t:Null<T>, enumField:Bool,
			filterName:String, mk:(hxc.core.Genjson, Null<Int>)->hxc.core.Json.JsonValue}> = [];
		var namesSeen = new haxe.ds.StringMap<Bool>();
		var pathSeen = new haxe.ds.StringMap<Bool>();
		inline function pathKey(pack:Array<String>, moduleName:String, typeName:String):String
			return pack.join(".") + "." + moduleName + "." + typeName;
		// The filter name: what the completion filter scores the item by.
		function add(info:hxc.typing.Typer.JsonItemInfo, group:Int, key:String, t:Null<T>, enumField:Bool, name:Null<String>,
				filterName:String, mk:(hxc.core.Genjson, Null<Int>)->hxc.core.Json.JsonValue):Void {
			pending.push({info: info, group: group, key: key, t: t, enumField: enumField, filterName: filterName, mk: mk});
			if (name != null) namesSeen.set(name, true);
		}
		inline function lazyResolved(t:T):T return switch (t) {
			case TLazy(r): TypeFunctions.lazyType(r);
			case t2: t2;
		};
		// A path in a package that a wildcard import names is in scope as well.
		var curImports = curMod == null ? null : ctx.moduleImports.get(Context.pathKey(curMod.path));
		function inWildcard(statusPack:Array<String>):Bool {
			if (curImports != null) for (i in 0...curImports.wildcards.length) {
				// The wildcard packages are read at the raise: an answer raised from an import path sees
				// only the wildcards declared before that import.
				var at = curImports.answeredAt;
				if (at >= 0 && i < curImports.wildcardImp.length && curImports.wildcardImp[i] >= at) continue;
				var w = curImports.wildcards[i];
				if (w.pack.concat([w.name]).join(".") == statusPack.join(".")) return true;
			}
			return false;
		}
		// An item whose name is already listed is Shadowed; otherwise an import, a root path or a
		// wildcard-imported one is Imported, and anything else Unimported. The status path carries the
		// module segment for a sub-type (its full dot path).
		function importStatusOf(name:String, isImport:Bool, statusPack:Array<String>):Int
			return namesSeen.exists(name) ? 2 : (isImport || statusPack.length == 0 || inWildcard(statusPack) ? 0 : 1);
		var displayOff = hxc.parser.Parser.displayOffset;
		for (e in entries) switch (e) {
			case JTLocal(v):
				var c = ct(v.type);
				add({kind: "other"}, 0, hxc.typing.Typer.toplevelLocalKey(v, displayOff, wt), v.type, false, v.name, v.name,
					function(gen, i) return hxc.core.CompletionItem.CompletionItem.localToJson(gen, v, c, i));
			case JTField(cf, scope, origin, enumAbstract, qualified):
				// A class field's group comes from its origin and scope.
				var group = enumAbstract ? (inPattern ? -1 : 21) : switch [origin, scope] {
					case [Self(_), CFSMember | CFSConstructor]: 10;
					case [Parent(_), CFSMember | CFSConstructor]: 11;
					case [StaticExtension(_), _]: 12;
					case [Self(_), CFSStatic]: 13;
					case [StaticImport(_), _]: 14;
					case _: 15;
				};
				var q = qualified != null ? qualified : !namesSeen.exists(cf.name);
				var t = lazyResolved(cf.type);
				var c = ct(t);
				add({kind: "other"}, group, cf.name, t, false, cf.name, cf.name,
					function(gen, i) return hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, scope, cf, origin, q, c, i, enumAbstract));
			case JTEnumCtor(en, ef, origin, register):
				var q = !namesSeen.exists(ef.name);
				var c = ct(ef.type);
				add({kind: "other"}, inPattern ? -1 : 20, StringTools.lpad(Std.string(ef.index), "0", 4), ef.type, true, register,
					ef.name, function(gen, i) return hxc.core.CompletionItem.CompletionItem.enumFieldToJson(gen, ef, origin, q, c, i));
			// An enum's own path (pack, Name) is the key a module's main type Name has.
			case JTPath(p): pathSeen.set(pathKey(p.pack, p.name, p.name), true);
			case JTLiteral(name, t):
				var c = ct(t);
				add({kind: "other"}, 50, name, t, false, name, name,
					function(gen, i) return hxc.core.CompletionItem.CompletionItem.literalToJson(gen, name, c, i));
			case JTKeyword(name):
				add({kind: "other"}, 60, name, null, false, name, name,
					function(gen, i) return hxc.core.CompletionItem.CompletionItem.keywordToJson(name, i));
			case JTTypeParam(pc, t):
				var c = ct(t);
				add({kind: "typeparam", tparam: pc}, 30, pc.path.name, t, false, pc.path.name, pc.path.name,
					function(gen, i) return hxc.core.CompletionItem.CompletionItem.typeParamToJson(gen, pc, c, i));
			// The display module's own types and its imports, in scope (isImport).
			case JTType(mt, params):
				var infos = TypeFunctions.tInfos(mt);
				var path = infos.path;
				var key = pathKey(path.pack, infos.module.path.name, path.name);
				if (!pathSeen.exists(key)) {
					pathSeen.set(key, true);
					var statusPack = path.name == infos.module.path.name ? path.pack : path.pack.concat([infos.module.path.name]);
					var st = importStatusOf(path.name, true, statusPack);
					var tkey = path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name;
					add({kind: "type", mt: mt}, 31 + st, tkey, null, false, path.name, tkey,
						function(gen, i) return hxc.core.CompletionItem.CompletionItem.moduleTypeToJson(gen, mt, st, i, null, false, params));
				}
		}
		// The cache's files. They order by pack similarity to the current package with a stable sort, so
		// tied entries keep the order of the cache's own hash table, which is kept across the server's
		// requests (CacheContext.fileOrder).
		var byKey = new haxe.ds.StringMap<hxc.compiler.ToplevelScan.ScannedFile>();
		for (sf in hxc.compiler.ToplevelScan.get(ctx)) byKey.set(sf.key, sf);
		// The package of the class being typed, which is the module's - except where no class is, as at an
		// import or using path.
		var curpack = noClass || curMod == null ? [] : curMod.path.pack;
		function packSimilarity(p1:Array<String>, p2:Array<String>):Int {
			var n = 0;
			while (n < p1.length && n < p2.length && p1[n] == p2[n]) n++;
			return n;
		}
		// The list is built by PREPENDING inside a hash-table fold, so the processed order is the REVERSE
		// of the fold's ascending-bucket walk: non-ascending in stringHash(key) & 127.
		var foldOrder = hxc.compiler.ToplevelScan.foldOrder(ctx);
		foldOrder.reverse();
		var scannedFiles = [for (k in foldOrder) if (byKey.get(k) != null) byKey.get(k)];
		// Stable by construction: sort indices by -similarity keeping fold order on ties.
		var idxs = [for (i in 0...scannedFiles.length) i];
		idxs.sort(function(a, b) {
			var sa = packSimilarity(curpack, scannedFiles[a].pack);
			var sb = packSimilarity(curpack, scannedFiles[b].pack);
			return sa != sb ? sb - sa : a - b;
		});
		scannedFiles = [for (i in idxs) scannedFiles[i]];
		function packContains(pack:Array<String>, target:Array<String>):Bool {
			if (pack.length > target.length) return false;
			for (i in 0...pack.length) if (pack[i] != target[i]) return false;
			return true;
		}
		// Packages: a hash table keyed by the (pack, last segment) path, iterated in bucket order.
		var packageOrder = new hxc.core.NameHash.HashTableOrder();
		var packagePaths = new haxe.ds.StringMap<Array<String>>();
		function addPackage(full:Array<String>):Void {
			var key = full.join(".");
			packageOrder.add(key, hxc.core.NameHash.NameHash.pathHash(full.slice(0, full.length - 1), full[full.length - 1]));
			packagePaths.set(key, full);
		}
		for (sf in scannedFiles) {
			// Legacy completion lists a packaged file only by its toplevel package.
			if (hxc.context.DisplayJson.legacyCompletion && sf.pack.length > 0) {
				if (sf.pack.length == 1) addPackage(sf.pack);
				continue;
			}
			if (hxc.compiler.ToplevelScan.excluded(sf.pack, sf.moduleName)) continue;
			var contributed = false;
			for (td in sf.decls) {
				var name:Null<String> = null, isPrivate = false, meta:hxc.ast.Ast.Metadata = [];
				switch (td.decl) {
					case EClass(d): name = d.dName.name; isPrivate = d.dFlags.contains(HPrivate); meta = d.dMeta;
					case EEnum(d): name = d.dName.name; isPrivate = d.dFlags.contains(EPrivate); meta = d.dMeta;
					case ETypedef(d): name = d.dName.name; isPrivate = d.dFlags.contains(EPrivate); meta = d.dMeta;
					case EAbstract(d): name = d.dName.name; isPrivate = d.dFlags.contains(AbPrivate); meta = d.dMeta;
					case EStatic(d): name = d.dName.name; isPrivate = Lambda.exists(d.dFlags, function(f) return f.access == APrivate); meta = d.dMeta;
					case EImport(_) | EUsing(_): continue;
				}
				if (isPrivate || TypeFunctions.hasMeta(":noCompletion", meta)) continue;
				var key = pathKey(sf.pack, sf.moduleName, name);
				if (pathSeen.exists(key)) continue;
				pathSeen.set(key, true);
				// A module MAIN type whose package is a prefix of the current package registers its name as a
				// shadowing name, making later same-named types rank Shadowed. The status is computed before
				// registering, and order-sensitivity resolves through the reversed-fold file order above:
				// std/Type precedes haxe/macro/Type (Shadowed) while haxe/ds/List precedes std/List
				// (Unimported, never registered since its pack is not a prefix).
				var isMain = name == sf.moduleName && packContains(sf.pack, curpack);
				var st = importStatusOf(name, isMain, name == sf.moduleName ? sf.pack : sf.pack.concat([sf.moduleName]));
				var tdc = td;
				var sfc = sf;
				var tkey = sf.pack.length == 0 ? name : sf.pack.join(".") + "." + name;
				add({kind: "type", pack: sf.pack, moduleName: sf.moduleName, decl: td.decl}, 31 + st, tkey, null, false, isMain ? name : null, tkey,
					function(gen, i) return hxc.core.CompletionItem.CompletionItem.declTypeToJson(gen, sfc.pack, sfc.moduleName, tdc.decl, tdc.pos, st, i));
				contributed = true;
			}
			// A contributing module's package registers once.
			if (contributed && sf.pack.length > 0) addPackage(sf.pack);
		}
		// A visible package is listed under its last segment's name.
		for (key in packageOrder.visitOrder()) {
			var full = packagePaths.get(key);
			var visible = true;
			for (s in full) if (s.length > 0 && s.charCodeAt(0) == "_".code) visible = false;
			if (visible) add({kind: "package"}, 40, key, null, false, full[full.length - 1], key,
				function(gen, i) return hxc.core.CompletionItem.CompletionItem.packageToJson(full, i));
		}
		// Sort only when nothing has been typed yet (an empty name), with an expected type compared first,
		// which runs over the items in collection order and binds what it unifies; the sort is stable.
		var order = [for (i in 0...pending.length) i];
		if (subjectName == null) {
			var expected = hxc.typing.Typer.toplevelExpected(wt);
			var comps = [for (p in pending) expected == null ? 0 : hxc.typing.Typer.toplevelComp(p.t, p.enumField, expected)];
			order.sort(function(a, b) {
				var x = pending[a], y = pending[b];
				if (comps[a] != comps[b]) return comps[a] - comps[b];
				if (x.group != y.group) return x.group - y.group;
				if (x.key != y.key) return x.key < y.key ? -1 : 1;
				return a - b;
			});
		}
		// The items are written as JSON, under their final index, once the raise site's filter ran.
		return [for (k in order) {filterName: pending[k].filterName, info: pending[k].info, toJson: pending[k].mk}];
	}

	// An answer cut short at this same subject start is answered again from that list, without collecting
	// anything; otherwise the collection runs. The raise site's filter then keeps the order of what it
	// filters.
	static function collectAndRaiseItems(startPos:Position, collect:Void->Array<hxc.context.DisplayException.CompletionEntry>,
			filter:Null<hxc.typing.Typer.JsonItemInfo->Bool>):Array<hxc.context.DisplayException.CompletionEntry> {
		var last = hxc.context.DisplayException.lastCompletionPos;
		var items = last != null && startPos.min == last.min ? hxc.context.DisplayException.lastCompletionResult : collect();
		if (filter != null) items = [for (e in items) if (e.info != null && filter(e.info)) e];
		return items;
	}

	static function jsonToplevelCompletion(ctx:Context, entries:Array<hxc.typing.Typer.JsonToplevelEntry>,
			?subjectName:String, ?subjectPos:Position, ?wt:hxc.core.WithType.WithType, ?patternOutermost:Bool, noClass:Bool = false):Null<String> {
		var gen = hxc.context.DisplayJson.createJsonContext(true);
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t);
		var off = hxc.parser.Parser.displayOffset;
		var insertPos = new Position(hxc.parser.Parser.displayFile, off, off);
		// The subject's position is both its start and its insert.
		var startPos = subjectPos == null ? insertPos : subjectPos;
		var items = collectAndRaiseItems(startPos, function() return jsonCollectedItems(ctx, entries, subjectName, wt, patternOutermost != null, noClass), null);
		var subj = patchCompletionSubject(subjectName, startPos);
		// The Pattern completion kind is 11 and carries isOutermostPattern ahead of the same expected-type
		// fields; a pattern collection is re-raised as that.
		var modeArgs = expectedTypeFields(gen, ct, wt);
		if (patternOutermost != null)
			modeArgs = ([{name: "isOutermostPattern", value: hxc.core.Json.JsonValue.JBool(patternOutermost)}]
				: Array<hxc.core.Json.JsonField>).concat(modeArgs);
		var mode = hxc.core.Json.JsonValue.JObject([
			{name: "kind", value: hxc.core.Json.JsonValue.JInt(patternOutermost != null ? 11 : 2)},
			{name: "args", value: hxc.core.Json.JsonValue.JObject(modeArgs)}
		]);
		return jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(hxc.context.DisplayException.fieldsToJson(gen, items, mode, subj.name, subj.pos, startPos)));
	}

	static function jsonCompletion(ctx:Context):Null<String> {
		var jc = hxc.typing.Typer.jsonFieldCompletion;
		if (jc == null) return null;
		if (jc.snap != null) return jc.snap;
		var gen = hxc.context.DisplayJson.createJsonContext(true);
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
		function originOf(e:{cf:hxc.core.Type.TClassField, originClass:Null<hxc.core.Type.TClass>, originAnon:Null<hxc.core.Type.TAnon>,
				builtIn:Bool, ?fromParent:Bool, ?origin:hxc.core.CompletionItem.ClassFieldOrigin}):hxc.core.CompletionItem.ClassFieldOrigin {
			return jc.originModuleType != null ? hxc.core.CompletionItem.ClassFieldOrigin.Self(jc.originModuleType)
				: e.origin != null ? e.origin
				: e.builtIn ? hxc.core.CompletionItem.ClassFieldOrigin.BuiltIn
				: e.originAnon != null ? hxc.core.CompletionItem.ClassFieldOrigin.AnonymousStructure(e.originAnon)
				: e.originClass != null ? (e.fromParent == true
					? hxc.core.CompletionItem.ClassFieldOrigin.Parent(classDecl(e.originClass))
					: hxc.core.CompletionItem.ClassFieldOrigin.Self(classDecl(e.originClass)))
				: hxc.core.CompletionItem.ClassFieldOrigin.Unknown;
		}
		// A structure completion is already ordered by declaration position; a field completion is sorted
		// as a field with no expected type: the rank of the origin and scope and then the name - an enum
		// constructor (by its index) or an enum abstract's member first of all.
		if (jc.noSort != true) {
			var keyed = [for (i in 0...entries.length) {
				var e = entries[i];
				var g:Int, k:String;
				if (e.ef != null) {
					g = -1;
					k = StringTools.lpad(Std.string(e.ef.index), "0", 4);
				} else if (e.enumAbstract == true) {
					g = -1;
					k = e.cf.name;
				} else {
					g = switch [originOf(e), e.scope] {
						case [Self(_), CFSMember | CFSConstructor]: 10;
						case [Parent(_), CFSMember | CFSConstructor]: 11;
						case [StaticExtension(_), _]: 12;
						case [Self(_), CFSStatic]: 13;
						case [StaticImport(_), _]: 14;
						case _: 15;
					};
					k = e.cf.name;
				}
				{e: e, g: g, k: k, i: i};
			}];
			keyed.sort(function(a, b) return a.g != b.g ? a.g - b.g : a.k < b.k ? -1 : a.k > b.k ? 1 : a.i - b.i);
			entries = [for (x in keyed) x.e];
		}
		var items:Array<hxc.context.DisplayException.CompletionEntry> = [];
		for (i in 0...entries.length) {
			var e = entries[i];
			var origin = originOf(e);
			var t = e.itemType != null ? e.itemType : switch (e.cf.type) {
				case TLazy(r): TypeFunctions.lazyType(r);
				case t: t;
			};
			var c = ct(t);
			// An enum's statics answer as EnumField items, an enum abstract's members as EnumAbstractField
			// ones.
			if (e.ef != null) {
				var ef = e.ef;
				items.push({filterName: ef.name, toJson: function(gen, idx) return hxc.core.CompletionItem.CompletionItem.enumFieldToJson(gen, ef, origin, true, c, idx)});
			} else
				items.push({filterName: e.cf.name, toJson: function(gen, idx)
					return hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, e.scope, e.cf, origin, true, c, idx, e.enumAbstract == true)});
		}
		// A dotted receiver naming a loaded module adds the module's other public types, after the sort.
		if (jc.submodules != null) for (mt in jc.submodules) {
			var p = TypeFunctions.tInfos(mt).path;
			items.push({filterName: hxc.core.Globals.sTypePath(p),
				toJson: function(gen, idx) return hxc.core.CompletionItem.CompletionItem.moduleTypeToJson(gen, mt, 0, idx)});
		}
		// The Field completion mode: the receiver item, receiver range, iterator and keyValueIterator, plus
		// the receiver's module-type block when its type names one.
		var modeArgs:Array<hxc.core.Json.JsonField> = [];
		if (jc.receiver != null) {
			var recv = jc.receiver;
			modeArgs.push({name: "item", value: itemForTypedExpr(ctx, gen, recv, recv.type, jc.receiverQualified)});
			modeArgs.push({name: "range", value: gen.generatePosAsRange(recv.pos)});
			modeArgs.push({name: "iterator", value: jc.iterator == null ? hxc.core.Json.JsonValue.JNull
				: hxc.core.Json.JsonValue.JObject([{name: "type", value: gen.generateType(jc.iterator)}])});
			modeArgs.push({name: "keyValueIterator", value: jc.keyValueIterator == null ? hxc.core.Json.JsonValue.JNull
				: hxc.core.Json.JsonValue.JObject([
					{name: "key", value: gen.generateType(jc.keyValueIterator.key)},
					{name: "value", value: gen.generateType(jc.keyValueIterator.value)}
				])});
			// The module type the item's type names (reading a statics structure as its type) and, when
			// following changes the type, the one the followed type names - both with the abstract
			// implementation written out - or nothing at all when either names none.
			var t = recv.type;
			// `t == follow t`: follow also unwraps Null<T>.
			var followChanges = switch (t) {
				case TMono(r): r.type != null;
				case TLazy(_) | TType(_, _): true;
				case TAbstract({path: {pack: [], name: "Null"}}, [_]): true;
				case _: false;
			};
			var mtJson = try {
				var mt = TypeFunctions.moduleTypeOfType(t);
				var mtf = followChanges ? TypeFunctions.moduleTypeOfType(TypeFunctions.follow(t)) : null;
				gen.generateAbstractImpl = true;
				var j = {mt: gen.generateModuleType(mt), mtf: mtf == null ? hxc.core.Json.JsonValue.JNull : gen.generateModuleType(mtf)};
				gen.generateAbstractImpl = false;
				j;
			} catch (_:Dynamic) {
				gen.generateAbstractImpl = false;
				null;
			};
			if (mtJson != null) {
				modeArgs.push({name: "type", value: hxc.core.CompletionItem.CompletionTypeTools.toJson(gen, ct(t))});
				modeArgs.push({name: "moduleType", value: mtJson.mt});
				modeArgs.push({name: "moduleTypeFollowed", value: mtJson.mtf});
			}
		}
		var kind = jc.kind == null ? 0 : jc.kind;
		var mode = hxc.core.Json.JsonValue.JObject(kind == 0 ? [
			{name: "kind", value: hxc.core.Json.JsonValue.JInt(0)},
			{name: "args", value: hxc.core.Json.JsonValue.JObject(modeArgs)}
		] : [
			{name: "kind", value: hxc.core.Json.JsonValue.JInt(kind)}
		]);
		var off = hxc.parser.Parser.displayOffset;
		// The subject is the field name already typed, at the span that ends where the display expression
		// does and reaches back by that name's length.
		var subj = jc.subjectPos != null
			? patchCompletionSubject(jc.subjectName, jc.subjectPos)
			: patchCompletionSubject(hxc.parser.Parser.displayDotName,
				hxc.parser.Parser.displayDotPos != null
					? hxc.parser.Parser.displayDotPos
					: new Position(hxc.parser.Parser.displayFile, off, off));
		// The receiver is where the subject starts.
		var startPos = jc.receiver != null ? jc.receiver.pos : subj.pos;
		return jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(hxc.context.DisplayException.fieldsToJson(gen, items, mode, subj.name, subj.pos, startPos)));
	}

	// The hover item built from a captured typed expression; shared by hover and the completion mode's
	// receiver item.
	// The item an expression stands for, and the documentation a hover takes from it. `t` is the item's
	// type as the caller computed it (Typer.hoverItemType for a hover).
	static function exprItem(ctx:Context, gen:hxc.core.Genjson, e:hxc.core.Type.TExpr, t:T, qualified:String->Bool,
			ct:T->hxc.core.CompletionItem.CompletionType):{item:hxc.core.Json.JsonValue, doc:hxc.ast.Ast.Documentation} {
		var CI = hxc.core.CompletionItem.CompletionItem;
		function loop(e:hxc.core.Type.TExpr):{item:hxc.core.Json.JsonValue, doc:hxc.ast.Ast.Documentation} {
			return switch (e.expr) {
				// `abstract` is typed as ((this : Underlying) : Abstract).
				case TLocal(v) if (v.kind.match(VAbstractThis) && switch (TypeFunctions.follow(e.type)) {
						case TAbstract(a, tl): hxc.core.TypeUnification.typeIseqDefault(TypeFunctions.getUnderlyingType(a, tl), v.type);
						case _: false;
					}):
					{item: CI.literalToJson(gen, "abstract", ct(t)), doc: null};
				case TLocal(v) | TVarExpr(v, _):
					{item: CI.localToJson(gen, v, ct(t)), doc: null};
				// An abstract's own member is Self, one reached through `using` a StaticExtension, and an
				// enum abstract's value its own kind of item.
				case TField(e1, FStatic(c, cf0)):
					// A macro field shows its macro-world signature.
					var mt = hxc.eval.EvalMacro.macroFieldDisplayType(ctx, c, cf0);
					var cf = cf0;
					var t = t;
					if (mt != null) { cf = TypeFunctions.copyField(cf0); cf.type = mt; t = mt; }
					hxc.typing.CoreApi.mergeCoreDoc(ctx, TClassDecl(c));
					var decl = classDecl(c);
					var origin = switch [c.kind, e1.expr] {
						case [KAbstractImpl(_), _] if (TypeFunctions.hasClassFieldFlag(cf, CfImpl)): hxc.core.CompletionItem.ClassFieldOrigin.Self(decl);
						case [_, TMeta({name: ":staticExtension"}, _)]: hxc.core.CompletionItem.ClassFieldOrigin.StaticExtension(decl);
						case _: hxc.core.CompletionItem.ClassFieldOrigin.Self(decl);
					};
					var enumAbstract = c.kind.match(KAbstractImpl(_)) && TypeFunctions.hasClassFieldFlag(cf, CfEnum);
					{item: CI.classFieldToJson(gen, CFSStatic, cf, origin, qualified(cf.name), ct(t), null, enumAbstract), doc: cf.doc};
				// A member reached through a subclass is the declaring class's, as Parent.
				case TField(e1, FInstance(c, _, cf0) | FClosure({c: c}, cf0)):
					var mt = hxc.eval.EvalMacro.macroFieldDisplayType(ctx, c, cf0);
					var cf = cf0;
					var t = t;
					if (mt != null) { cf = TypeFunctions.copyField(cf0); cf.type = mt; t = mt; }
					hxc.typing.CoreApi.mergeCoreDoc(ctx, TClassDecl(c));
					var origin = switch (TypeFunctions.follow(e1.type)) {
						case TInst(c2, _) if (c2 != c): hxc.core.CompletionItem.ClassFieldOrigin.Parent(TClassDecl(c));
						case _: hxc.core.CompletionItem.ClassFieldOrigin.Self(TClassDecl(c));
					};
					{item: CI.classFieldToJson(gen, CFSMember, cf, origin, qualified(cf.name), ct(t)), doc: cf.doc};
				case TField(_, FEnum(en, ef)):
					{item: CI.enumFieldToJson(gen, ef, Self(TEnumDecl(en)), qualified(ef.name), ct(t)), doc: ef.doc};
				// A structure's field is the typedef's when it came through one.
				case TField(e1, FAnon(cf) | FClosure(null, cf)):
					switch (TypeFunctions.follow(e1.type)) {
						case TAnon(an):
							var origin = switch (e1.type) {
								case TType(td, _): hxc.core.CompletionItem.ClassFieldOrigin.Self(TTypeDecl(td));
								case _: hxc.core.CompletionItem.ClassFieldOrigin.AnonymousStructure(an);
							};
							{item: CI.classFieldToJson(gen, CFSMember, cf, origin, qualified(cf.name), ct(t)), doc: cf.doc};
						case _:
							{item: CI.expressionToJson(gen, ct(t)), doc: null};
					}
				// A type expression is a Type item, Imported, typed as the expression - an abstract's
				// implementation class as the abstract itself.
				case TTypeExpr(TClassDecl({kind: KAbstractImpl(a)})):
					hxc.typing.CoreApi.mergeCoreDoc(ctx, TAbstractDecl(a));
					var tl = TypeFunctions.extractParamTypes(a.params);
					var name = "Abstract<" + hxc.core.Globals.sTypePath(a.path)
						+ (tl.length == 0 ? "" : "<" + [for (x in tl) TPrinting.sTypeStr(x)].join(", ") + ">") + ">";
					var td = TypeFunctions.mkTypedef(a.module, {pack: [], name: name}, a.pos, Position.nullPos,
						TypeFunctions.mkAnon(new hxc.core.Ref(hxc.core.Type.AnonStatus.AbstractStatics(a))));
					td.isPrivate = true;
					{item: CI.moduleTypeToJson(gen, TAbstractDecl(a), 0, null, ct(TType(td, []))), doc: a.doc};
				case TTypeExpr(mt):
					hxc.typing.CoreApi.mergeCoreDoc(ctx, mt);
					{item: CI.moduleTypeToJson(gen, mt, 0, null, ct(t)), doc: TypeFunctions.tInfos(mt).doc};
				// This/super stays an Expression; any other constant is a Literal named by its printed form.
				case TConst(TThis | TSuper):
					{item: CI.expressionToJson(gen, ct(t)), doc: null};
				case TConst(c):
					{item: CI.literalToJson(gen, hxc.core.TPrinting.sConst(c), ct(t)), doc: null};
				// An object literal is its structure.
				case TObjectDecl(_):
					switch (TypeFunctions.follow(e.type)) {
						case TAnon(an): {item: CI.anonToJson(gen, an, ct(t)), doc: null};
						case _: {item: CI.expressionToJson(gen, ct(t)), doc: null};
					}
				// A construction is the constructor it resolved to, as the function producing the class.
				case TNew(c, tl, _) if (newConstructor(c) != null):
					hxc.typing.CoreApi.mergeCoreDoc(ctx, TClassDecl(c));
					var ncf = newConstructor(c);
					{item: CI.classFieldToJson(gen, CFSConstructor, ncf, Self(classDecl(c)), true,
						ct(ncf == c.constructor ? t : newItemType(c, tl, ncf))), doc: ncf.doc};
				// A cast is what it casts, a parenthesis or metadata what it wraps.
				case TCast(e1, _): loop(e1);
				case TParenthesis(e1) | TMeta(_, e1): loop(e1);
				case _:
					{item: CI.expressionToJson(gen, ct(t)), doc: null};
			};
		}
		return loop(e);
	}

	static function itemForTypedExpr(ctx:Context, gen:hxc.core.Genjson, e:hxc.core.Type.TExpr, t:T, ?isQualified:Bool):hxc.core.Json.JsonValue {
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t2:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t2);
		var item:Null<hxc.core.Json.JsonValue> = null;
		// A field item's isQualified comes from re-typing its bare name in the scope the expression was
		// typed in (Typer.retypeIsQualified), not from a constant.
		var hoverTctx = hxc.typing.Typer.hoverFound != null ? hxc.typing.Typer.hoverFound.tctx : null;
		inline function qualified(name:String):Bool
			return isQualified != null ? isQualified : hxc.typing.Typer.retypeIsQualified(hoverTctx, e, name, e.type);
		item = exprItem(ctx, gen, e, t, n -> qualified(n), ct).item;
		if (item == null) item = hxc.core.CompletionItem.CompletionItem.expressionToJson(gen, ct(t));
		return item;
	}

	// The hover `expected` field encodes the with-type at the hover point: WithType(t, src) gives {type,
	// name?}; a named Value gives {name}; anything else is null. ImplicitReturn never names itself.
	static function hoverExpectedJson(gen:hxc.core.Genjson, h:hxc.typing.Typer.HoverRecord):hxc.core.Json.JsonValue {
		if (h == null || h.wt == null) return hxc.core.Json.JsonValue.JNull;
		function nameJson(src:hxc.core.WithType.WithTypeSource):Null<hxc.core.Json.JsonValue> {
			return switch (src) {
				case FunctionArgument(si): hxc.core.Json.JsonValue.JObject([
					{name: "name", value: JString(si.name)},
					{name: "kind", value: JInt(0)},
					{name: "doc", value: si.doc == null ? JNull : JString(si.doc)}
				]);
				case StructureField(si): hxc.core.Json.JsonValue.JObject([
					{name: "name", value: JString(si.name)},
					{name: "kind", value: JInt(1)},
					{name: "doc", value: si.doc == null ? JNull : JString(si.doc)}
				]);
				case ImplicitReturn: null;
			}
		}
		return switch (h.wt) {
			case WithType(t, src):
				var fields:Array<hxc.core.Json.JsonField> = [{name: "type", value: gen.generateType(t)}];
				if (src != null) switch (nameJson(src)) {
					case null:
					case nj: fields.push({name: "name", value: nj});
				}
				hxc.core.Json.JsonValue.JObject(fields);
			case Value(src) if (src != null && !src.match(ImplicitReturn)):
				hxc.core.Json.JsonValue.JObject([{name: "name", value: nameJson(src)}]);
			case _:
				hxc.core.Json.JsonValue.JNull;
		}
	}

	// A field of a STRUCTURE is the structure's - or, reached through a typedef, that typedef's (Self) -
	// and a receiver that is no structure answers as an expression (null).
	static function anonFieldOrigin(e1:hxc.core.Type.TExpr):Null<hxc.core.CompletionItem.ClassFieldOrigin> {
		return switch (TypeFunctions.follow(e1.type)) {
			case TAnon(an): switch (e1.type) {
					case TType(td, _): hxc.core.CompletionItem.ClassFieldOrigin.Self(TTypeDecl(td));
					case _: hxc.core.CompletionItem.ClassFieldOrigin.AnonymousStructure(an);
				};
			case _: null;
		};
	}

	// The answer is raised from the marked expression's typing, so if that typing raised instead there
	// is no answer at all and the request aborts with the recorded errors. Answers are recorded by
	// position, so an enclosing node that typed cleanly would still have a candidate. The preprocessor
	// giving up vetoes the WALK's record only. A hook standing for a raise site still answers - a
	// cursor on a type hint is picked up while LOADING the type, whatever the expression walk decided
	// about it.
	static function answeredHover():Null<hxc.typing.Typer.HoverRecord> {
		var hf = hxc.typing.Typer.hoverFound;
		if (hf != null && hf.fromWalk == true && hxc.typing.ExprPreprocessing.gaveUpAtDisplay) hf = null;
		if (hf != null && hf.fromWalk == true && hxc.typing.Typer.markedStatementFailed) hf = null;
		return hxc.typing.Typer.markedNodeFailed ? null : hf;
	}

	// A hover answer raises and is serialized where it is caught, with nothing typed in between: a
	// class whose fields are still being added, a return type not yet inferred, an import not yet in
	// place all print as they stood at the raise. hxc records the answer and types on, so the record
	// carries its serialized item from the moment it is made.
	static function hoverSnapshot(ctx:Context, h:hxc.typing.Typer.HoverRecord):Dynamic {
		mergeHoverCoreDoc(ctx, h);
		return hoverItemOf(ctx, h);
	}

	// Hover as JSON: {documentation, range, item, expected}.
	static function jsonHover(ctx:Context):Null<String> {
		hxc.typing.Typer.resolveHoverMacroField(ctx);
		var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t);
		var item:Null<hxc.core.Json.JsonValue> = null;
		var rangePos:Null<Position> = null;
		var doc:hxc.ast.Ast.Documentation = null;
		var expected:hxc.core.Json.JsonValue = hxc.core.Json.JsonValue.JNull;
		var h = answeredHover();
		if (h != null) {
			rangePos = h.p;
			var snap:{item:hxc.core.Json.JsonValue, doc:hxc.ast.Ast.Documentation, expected:hxc.core.Json.JsonValue} =
				h.snap != null ? h.snap : hoverSnapshot(ctx, h);
			item = snap.item;
			doc = snap.doc;
			expected = snap.expected;
		} else {
			var hf = hoverOnFieldName(ctx);
			if (hf != null) {
				rangePos = hf.p;
				doc = hf.cf.doc;
				item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, hf.scope, hf.cf, Self(classDecl(hf.c)), true, ct(hf.t));
			} else {
				// Under hover, a type declaration name answers with that type, Imported, typed as its module
				// type, over the name; its doc is the type's own. A typedef answers before its type is loaded.
				var mt = displayTypeAtName(ctx);
				if (mt == null) return null;
				var inf = TypeFunctions.tInfos(mt);
				rangePos = inf.namePos;
				doc = inf.doc;
				item = hxc.core.CompletionItem.CompletionItem.moduleTypeToJson(gen, mt, 0, null, ct(TypeFunctions.typeOfModuleType(mt)),
					mt.match(TTypeDecl(_)));
			}
		}
		var result = hxc.core.Json.JsonValue.JObject([
			{name: "documentation", value: doc == null ? hxc.core.Json.JsonValue.JNull : hxc.core.Json.JsonValue.JString(hxc.ast.Ast.genDocText(doc))},
			{name: "range", value: gen.generatePosAsRange(rangePos)},
			{name: "item", value: item},
			{name: "expected", value: expected}
		]);
		return jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(result));
	}

	// The constructor access: an abstract impl's constructor is its `_new`, a class's its own or the
	// nearest inherited one; its item is qualified.
	static function newConstructor(c:hxc.core.Type.TClass):Null<hxc.core.Type.TClassField> {
		if (c.kind.match(KAbstractImpl(_))) return c.statics.get("_new");
		var cur = c;
		while (cur != null) {
			if (cur.constructor != null) return cur.constructor;
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return null;
	}

	// The constructor's type under the access's map, returning the class constructed.
	static function newItemType(c:hxc.core.Type.TClass, tl:Array<T>, cf:hxc.core.Type.TClassField):T {
		var params = switch (c.kind) {
			case KAbstractImpl(a): a.params;
			case _: c.params;
		};
		return switch (TypeFunctions.follow(TypeFunctions.applyParams(params, tl, cf.type))) {
			case TFun(sig): TFun({args: sig.args, ret: TInst(c, tl)});
			case t: t;
		};
	}

	static function classDecl(c:hxc.core.Type.TClass):hxc.core.Type.ModuleType {
		return switch (c.kind) {
			case KAbstractImpl(a): TAbstractDecl(a);
			case _: TClassDecl(c);
		};
	}

	static function hoverItemOf(ctx:Context, h:hxc.typing.Typer.HoverRecord):{item:hxc.core.Json.JsonValue, doc:hxc.ast.Ast.Documentation, expected:hxc.core.Json.JsonValue} {
		var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
		var curMod = displayModule(ctx);
		function importStatus(path:hxc.core.Globals.Path):hxc.core.CompletionItem.ImportStatus
			return importStatusFor(ctx, curMod, path);
		function ct(t:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(importStatus, t);
		var item:Null<hxc.core.Json.JsonValue> = null;
		var doc:hxc.ast.Ast.Documentation = null;
		// isQualified re-types the bare name in the scope the hovered expression was typed in; it is not a
		// constant.
		// A declaration's own item is qualified outright.
		inline function qualified(name:String):Bool
			return h.isQualified != null ? h.isQualified : hxc.typing.Typer.retypeIsQualified(h.tctx, h.e, name, h.e.type);
		// A field the cursor NAMES answers with that field's own item.
		if (h.fieldItem != null) {
			var fi = h.fieldItem;
			doc = fi.cf.doc;
			item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, fi.scope, fi.cf, fi.origin, true, ct(h.t));
		// A type path under the cursor answers with a Type item carrying its own type, not with the
		// expression that path sits in.
		} else if (h.mt != null) {
			doc = TypeFunctions.tInfos(h.mt).doc;
			item = hxc.core.CompletionItem.CompletionItem.moduleTypeToJson(gen, h.mt, 0, null, ct(h.t));
		} else if (h.e != null) {
			var r = exprItem(ctx, gen, h.e, h.t, n -> qualified(n), ct);
			item = r.item;
			doc = r.doc;
		}
		if (item == null) item = hxc.core.CompletionItem.CompletionItem.expressionToJson(gen, ct(h.t));
		return {item: item, doc: doc, expected: hoverExpectedJson(gen, h)};
	}

	// Every reported position goes through the real-path lookup, which on Windows canonicalizes
	// separators and case alike - absolute paths included, so a diagnostic on a file found under an
	// absolute class path reports backslashes, not the forward slashes the class-path join produced.
	// The lookup falls back to its own argument on failure, which is what the catch is.
	static function diagnosticsFile(pfile:String):String {
		if (pfile == "?") return pfile;
		return hxc.core.PathKey.realPath(pfile);
	}

	// The report covers only the requested display file (plus fileless positions).
	static function isDiagnosticsFile(ctx:Context, pfile:String):Bool {
		var parts = displayParts(ctx);
		if (parts.length == 0) return true;
		if (pfile == "?") return true;
		// An empty file list reports on every file (a project-wide diagnostics request), a non-empty one
		// only on its members - and a JSON request fills that list from the whole fileContents set.
		if (ctx.fileContents.length > 0) {
			var got = (try FileSystem.fullPath(pfile) catch (_:Dynamic) pfile).toLowerCase();
			for (fc in ctx.fileContents) if (fc.file.toLowerCase() == got) return true;
			return false;
		}
		if (parts[0] == "?") return true;
		var want = try FileSystem.fullPath(parts[0]) catch (_:Dynamic) parts[0];
		var got = try FileSystem.fullPath(pfile) catch (_:Dynamic) pfile;
		return want.toLowerCase() == got.toLowerCase();
	}

	// A position as a JSON location, through hxc's serializer.
	// A hover reports the documentation of the ITEM under the cursor, which is the field's, the enum
	// constructor's or the type's own doc.
	// A @:coreApi class's core documentation is merged for a static or member field, a type expression and
	// a construction before the item is built.
	static function mergeHoverCoreDoc(ctx:Context, h:Null<{?e:hxc.core.Type.TExpr, ?displayField:Bool}>):Void {
		// Only an expression's display merges; a field's display answer does not.
		if (h == null || h.e == null || h.displayField == true) return;
		switch (h.e.expr) {
			case TField(_, FStatic(c, _) | FInstance(c, _, _) | FClosure({c: c}, _)):
				hxc.typing.CoreApi.mergeCoreDoc(ctx, TClassDecl(c));
			case TTypeExpr(TClassDecl({kind: KAbstractImpl(a)})):
				hxc.typing.CoreApi.mergeCoreDoc(ctx, TAbstractDecl(a));
			case TTypeExpr(mt):
				hxc.typing.CoreApi.mergeCoreDoc(ctx, mt);
			case TNew(c, _, _):
				hxc.typing.CoreApi.mergeCoreDoc(ctx, TClassDecl(c));
			case _:
		}
	}

	static function hoverDocumentation(h:Null<{?e:hxc.core.Type.TExpr, ?mt:hxc.core.Type.ModuleType,
			?fieldItem:{cf:hxc.core.Type.TClassField, scope:hxc.core.Type.ClassFieldScope, origin:hxc.core.CompletionItem.ClassFieldOrigin}}>):Null<String> {
		if (h == null) return null;
		if (h.fieldItem != null) {
			var fdoc = h.fieldItem.cf.doc;
			return fdoc == null ? null : hxc.ast.Ast.genDocText(fdoc);
		}
		if (h.mt != null) {
			var mdoc = hxc.core.TypeFunctions.tInfos(h.mt).doc;
			return mdoc == null ? null : hxc.ast.Ast.genDocText(mdoc);
		}
		var e = h.e;
		if (e == null) return null;
		var doc:hxc.ast.Ast.Documentation = switch (e.expr) {
			case TField(_, FStatic(_, cf) | FInstance(_, _, cf) | FAnon(cf) | FClosure(_, cf)): cf.doc;
			case TField(_, FEnum(_, ef)): ef.doc;
			case TTypeExpr(mt): hxc.core.TypeFunctions.tInfos(mt).doc;
			// A construction's item is its constructor field.
			case TNew(c, _, _) if (newConstructor(c) != null): newConstructor(c).doc;
			case _: null;
		};
		return doc == null ? null : hxc.ast.Ast.genDocText(doc);
	}

	static function jsonLocation(p:Position):String {
		return hxc.core.Json.stringOfJson(new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull).generatePosAsLocation(p));
	}

	// A failing one-shot compile exits the process; an in-process wait-server request
	// aborts only the request.
	static function exitRequest(code:Int):Void {
		if (requestOutput != null) throw new RequestAbort(code) else hxc.compiler.HostRuntime.exit(code);
	}

	// A macro can push a raw json value out as the request result, through the same envelope every other
	// json answer uses.
	public static function sendMacroJson(ctx:Context, json:hxc.core.Json.JsonValue):Void {
		throw new hxc.context.DisplayJson.JsonDisplayOutput(jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(json)));
	}

	// Writes a request answer to the wait-server buffer when one is active, or the
	// process stderr in one-shot mode.
	static function answerOut(sv:String):Void {
		if (requestOutput != null) requestOutput.add(sv) else Sys.stderr().writeString(sv);
	}

	// The protocol envelope around a report-time answer.
	// The JSON shape every completion answers with - items, isIncomplete, the mode's kind, the filter
	// string and the range the client replaces. A SYNTAX completion goes through it too, so
	// display/completion at a type-declaration position answers as JSON.
	// The insert position is CUT at the cursor, so a cursor inside a name replaces only what precedes it,
	// and the filter string is shortened to that same width.
	static function patchCompletionSubject(name:Null<String>, p:Null<Position>):{name:Null<String>, pos:Null<Position>} {
		if (p == null) return {name: name, pos: p};
		var off = hxc.parser.Parser.displayOffset;
		var cut = new Position(p.file, p.min, off);
		if (name == null) return {name: null, pos: cut};
		var delta = cut.max - cut.min;
		return {name: delta > 0 && delta < name.length ? name.substr(0, delta) : name, pos: cut};
	}

	static function jsonKeywordCompletion(ctx:Context, keywords:Array<String>, kind:Int,
			?subjectName:String, ?subjectPos:Position):String {
		var items:Array<hxc.context.DisplayException.CompletionEntry> = [for (k in keywords) {filterName: k,
			toJson: function(gen, i) return hxc.core.CompletionItem.CompletionItem.keywordToJson(k, i)}];
		var gen = hxc.context.DisplayJson.createJsonContext(true);
		var subj = patchCompletionSubject(subjectName, subjectPos);
		var mode = hxc.core.Json.JsonValue.JObject([{name: "kind", value: hxc.core.Json.JsonValue.JInt(kind)}]);
		return hxc.core.Json.stringOfJson(hxc.context.DisplayException.fieldsToJson(gen, items, mode, subj.name, subj.pos, subjectPos));
	}

	// The completion JSON over a type collection: the module types the raise site carried, each as a
	// Type item, with the mode kind it recorded. The collection reaches the CLASS-PATH exploration as
	// well as the loaded types, so a class no compilation has touched is offered too, from its PARSED
	// declaration. The heritage filter travels on the raise and is applied here, where the answer is
	// built. both lanes need it, or a legacy `class C extends |` would offer only the classes that
	// happen to be loaded instead of the whole class path.
	static function heritageScan(ctx:Context, tl:hxc.compiler.DisplayXml.ToplevelCompletion,
			seen:haxe.ds.StringMap<Bool>, add:hxc.compiler.ToplevelScan.ScannedFile->hxc.ast.Ast.TypeDecl->Void):Void {
		if (tl.heritIsExtends == null) return;
		var isExtends = tl.heritIsExtends;
		for (sf in hxc.compiler.ToplevelScan.get(ctx)) for (td in sf.decls) switch (td.decl) {
			case EClass(d):
				if (d.dFlags.contains(HPrivate) || TypeFunctions.hasMeta(":noCompletion", d.dMeta)) continue;
				var nm = d.dName.name;
				var full = (sf.pack.length == 0 ? "" : sf.pack.join(".") + ".")
					+ (nm == sf.moduleName ? nm : sf.moduleName + "." + nm);
				if (seen.exists(full) || full == tl.heritSelf) continue;
				var isIface = d.dFlags.contains(HInterface);
				var basic = sf.pack.length == 0 && (nm == "Array" || nm == "String" || nm == "Date" || nm == "Xml");
				var keep = isIface ? (!isExtends || tl.heritIsInterface)
					: (isExtends && !tl.heritIsInterface && (!d.dFlags.contains(HFinal) || tl.heritHasHack) && !basic);
				if (!keep) continue;
				seen.set(full, true);
				add(sf, td);
			case _:
		}
	}

	static function jsonTypeCompletion(ctx:Context, tl:hxc.compiler.DisplayXml.ToplevelCompletion):String {
		var gen = hxc.context.DisplayJson.createJsonContext(true);
		var curMod = displayModule(ctx);
		var mts = tl.moduleTypes;
		var items:Array<hxc.context.DisplayException.CompletionEntry> = [];
		var off = hxc.parser.Parser.displayOffset;
		var startPos = tl.subjectPos != null ? tl.subjectPos : new Position(hxc.parser.Parser.displayFile, off, off);
		// The type half of the collection, through the same pipeline as the toplevel, with the raise site's
		// filter on top. An empty subject is what sorts.
		if (tl.jsonEntries != null) {
			var entries = tl.jsonEntries;
			items = collectAndRaiseItems(startPos,
				function() return jsonCollectedItems(ctx, entries, tl.subjectName == "" ? null : tl.subjectName, null, false,
					tl.noClass), tl.jsonFilter);
			mts = [];
		}
		if (tl.jsonEntries == null) for (mt in mts) {
			var inf = TypeFunctions.tInfos(mt);
			var st = hxc.core.CompletionItem.ImportStatusTools.toInt(importStatusFor(ctx, curMod, inf.path));
			items.push({filterName: hxc.core.Globals.sTypePath(inf.path),
				toJson: function(gen, i) return hxc.core.CompletionItem.CompletionItem.moduleTypeToJson(gen, mt, st, i)});
		}
		// The collection reaches the class-path exploration as well as the loaded types, so a type no
		// compilation has touched is offered too - from its PARSED declaration, which is all there is for
		// it. The heritage filter that produced this collection travels on it.
		if (tl.jsonEntries == null) {
			var seen = new haxe.ds.StringMap<Bool>();
			for (mt in mts) seen.set(hxc.core.Globals.sTypePath(TypeFunctions.tPath(mt)), true);
			heritageScan(ctx, tl, seen, function(sf, td) {
				var name = switch (td.decl) {
					case EClass(d): d.dName.name;
					case _: null;
				};
				items.push({filterName: sf.pack.length == 0 ? name : sf.pack.join(".") + "." + name,
					toJson: function(gen, i) return hxc.core.CompletionItem.CompletionItem.declTypeToJson(gen, sf.pack, sf.moduleName, td.decl, td.pos, 1, i)});
			});
		}
		var subj = patchCompletionSubject(tl.subjectName, tl.subjectPos);
		// StructExtension is the only one of these kinds carrying args.
		var modeFields:Array<hxc.core.Json.JsonField> = [{name: "kind", value: hxc.core.Json.JsonValue.JInt(tl.kind)}];
		if (tl.kind == 7) modeFields.push({name: "args", value: hxc.core.Json.JsonValue.JObject([
			{name: "isIntersectionType", value: hxc.core.Json.JsonValue.JBool(tl.structExtensionIsIntersection == true)}
		])});
		return hxc.core.Json.stringOfJson(hxc.context.DisplayException.fieldsToJson(gen, items, hxc.core.Json.JsonValue.JObject(modeFields), subj.name, subj.pos, startPos));
	}

	static function jsonRpcAnswer(ctx:Context, resultJson:String):String {
		return '{"jsonrpc":"2.0","id":' + ctx.jsonRpcId + ',"result":{"result":' + resultJson + ',"timestamp":' + Sys.time() + '}}';
	}

	static function diagnosticsAbort(ctx:Context, message:String, pos:Position, kind:Int, depth:Int = 0):Void {
		ctx.diagnostics.push({message: message, pos: pos, depth: depth, severity: MessageSeverity.Error, kind: kind});
		displayDiagnostics(ctx);
	}

	static inline var DK_UNUSED_IMPORT = 0;
	static inline var DK_UNRESOLVED_IDENTIFIER = 1;
	static inline var DK_COMPILER_MESSAGE = 2;
	static inline var DK_REMOVABLE_CODE = 3;
	static inline var DK_PARSER_ERROR = 4;

	// The condition hover is raised during the PARSE, so this is the whole answer: nothing is typed and
	// nothing else can win. The evaluated value is turned into the type the legacy lane prints.
	static function answerConditionHover(ctx:Context, ch:hxc.parser.Parser.DisplayConditionHover):Void {
		var basic = ctx.basic;
		// The SemVer type is a synthetic class in no module; only its name is ever printed.
		inline function tSemver():T
			return TInst(TypeFunctions.mkClass(TypeFunctions.nullModule,
				new hxc.core.Globals.Path([], "SemVer"), Position.nullPos, Position.nullPos), []);
		var doc:Null<String> = null;
		var t:T;
		var item:Null<hxc.core.Json.JsonValue> = null;
		var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
		function ct(t:T):hxc.core.CompletionItem.CompletionType
			return hxc.core.CompletionItem.CompletionTypeTools.fromType(
				function(_) return hxc.core.CompletionItem.ImportStatus.Imported, t);
		switch (ch.kind) {
			case CHDefine(name, value):
				t = basic.tstring;
				item = hxc.core.CompletionItem.CompletionItem.defineToJson(gen, name, value, ct(t));
			case CHVersion:
				t = TFun({args: [{name: "s", opt: false, t: basic.tstring}], ret: tSemver()});
				var cf = TypeFunctions.mkField("version", t, Position.nullPos, Position.nullPos, false, false);
				cf.doc = hxc.ast.Ast.docFromString(VERSION_DOC);
				cf.kind = Method(MethNormal);
				TypeFunctions.addClassFieldFlag(cf, CfPublic);
				doc = hxc.ast.Ast.genDocText(cf.doc);
				item = hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen,
					hxc.core.Type.ClassFieldScope.CFSStatic, cf,
					hxc.core.CompletionItem.ClassFieldOrigin.BuiltIn, true, ct(t));
			case CHLiteral(v):
				// The literal's TEXT and the type that goes with it.
				var lit:String;
				switch (v) {
					case TNull: lit = "null"; t = TMono(hxc.core.TypeUnification.monoCreate());
					case TBool(b): lit = b ? "true" : "false"; t = basic.tbool;
					case TFloat(f):
						// Float text must contain a decimal point.
						lit = Std.string(f);
						if (~/^-?[0-9]+$/.match(lit)) lit += ".";
						t = basic.tfloat;
					case TString(str): lit = '"' + hxc.core.StringHelper.sEscape(str) + '"'; t = basic.tstring;
					case TVersion(ver): lit = ver; t = tSemver();
				}
				item = hxc.core.CompletionItem.CompletionItem.literalToJson(gen, lit, ct(t));
		}
		if (ctx.jsonRpcId != null) {
			answerOut(jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(
				hxc.core.Json.JsonValue.JObject([
					{name: "documentation", value: doc == null ? hxc.core.Json.JsonValue.JNull : hxc.core.Json.JsonValue.JString(doc)},
					{name: "range", value: gen.generatePosAsRange(ch.pos)},
					{name: "item", value: item},
					{name: "expected", value: hxc.core.Json.JsonValue.JNull}
				]))));
			return;
		}
		answerOut(hxc.compiler.DisplayXml.printType(hxc.core.TPrinting.sTypeStr(t), ch.pos, doc));
	}

	// Verbatim: the `version()` builtin's documentation.
	static inline var VERSION_DOC = "Allows comparing defines (such as the version of a Haxelib or Haxe) with SemVer semantics.\r\nBoth the define and the string passed to `version()` must be valid semantic versions.\r\n\r\nExample:\r\n```haxe\r\n#if (haxe >= version(\"4.0.0-rc.3\"))\n\r\n```\r\n\r\nNote: this syntax does not parse with Haxe versions earlier than 4.0.0-rc.3,\r\nso it should be avoided if backwards-compatibility with earlier versions is needed.\r\n\r\n@see https://semver.org/";

	// A position that never had one is NULL, not a range. The null position has min = -1, and the same
	// test guards the location form.
	// One relatedInformation entry.
	static function relatedJson(p:Position, depth:Int, message:String):String {
		return '{"location":' + posAsLocation(p) + ',"depth":' + depth
			+ ',"message":' + haxe.Json.stringify(message) + '}';
	}

	// The file plus the range, null on the same test.
	static function posAsLocation(p:Position):String {
		if (p.min == -1) return "null";
		return '{"file":' + haxe.Json.stringify(diagnosticsFile(p.file))
			+ ',"range":' + posAsRange(p) + '}';
	}

	static function posAsRange(p:Position):String {
		if (p.min == -1) return "null";
		var i = Position.getInfos(p);
		return '{"start":{"line":' + (i.line - 1) + ',"character":' + i.column
			+ '},"end":{"line":' + (i.endLine - 1) + ',"character":' + i.endColumn + '}}';
	}

	static function displayDiagnostics(ctx:Context):Void {
		// Diagnostics are collected at REPORT time, after the filters, so what is walked is the same tree
		// the rest of the report describes.
		hxc.compiler.Diagnostics.collect(ctx, function(f) return isDiagnosticsFile(ctx, f));
		var groups:Array<{file:String, items:Array<String>}> = [];
		// The unresolved identifiers are their own kind (1) whose args are the suggestion list, and they
		// are emitted before the compiler messages, from the recorded list rather than from any error - a
		// name that recovered (a type hint, a recovered identifier) never produced one. Each candidate is
		// scored: an exact match is an IMPORT suggestion carrying the full type path (kind 0), anything
		// else a typo suggestion naming it (kind 1).
		// Every diagnostic added becomes the `current` one, the unresolved identifiers included, and a
		// position in a file this report does not cover CLEARS it rather than leaving the previous one
		// standing.
		var curGroup:Null<{file:String, items:Array<String>}> = null;
		var curIndex = -1;
		var curHead = "";
		var curRelated:Array<String> = [];
		for (u in ctx.unresolvedIdentifiers) {
			if (!isDiagnosticsFile(ctx, u.pos.file)) { curGroup = null; curIndex = -1; continue; }
			var displayFile = diagnosticsFile(u.pos.file);
			var args = "[" + [for (x in u.suggestions) '{"kind":' + x.kind + ',"name":' + haxe.Json.stringify(x.name) + "}"].join(",") + "]";
			var head = '{"kind":1,"severity":1,"range":' + posAsRange(u.pos) + ',"args":' + args;
			var group = null;
			for (g in groups) if (g.file == displayFile) { group = g; break; }
			if (group == null) { group = {file: displayFile, items: []}; groups.push(group); }
			group.items.push(head + ',"relatedInformation":[]}');
			curGroup = group; curIndex = group.items.length - 1; curHead = head; curRelated = [];
		}
		for (d in ctx.diagnostics) {
			// The report is filled from the diagnostics message store ALONE, so a message reported through
			// addPrintedError is printed by a plain compile and never appears here - the optimizer's
			// null-on-a-static-platform check is one, and it runs either way.
			if (d.printedOnly == true) continue;
			// A message at depth > 0 is not a diagnostic of its own. It joins the relatedInformation of the
			// one most recently added, and with none to join - its depth-0 line went to the other store, or
			// stood in a file this report does not cover - it is DROPPED, not promoted to the top level.
			if (d.depth > 0) {
				if (curGroup == null || curIndex < 0) continue;
				var lines = d.message.split("
");
				// The EXTRA lines are prepended to the list and the head line last, and the list is then
				// reverse-mapped, so a multi-line message prints its sub-lines before the line they belong to,
				// each carrying the continuation prefix.
				for (i in 1...lines.length) curRelated.push(relatedJson(d.pos, d.depth, "... " + lines[i]));
				curRelated.push(relatedJson(d.pos, d.depth, lines[0]));
				curGroup.items[curIndex] = curHead + ',"relatedInformation":[' + curRelated.join(",") + ']}';
				continue;
			}
			if (!isDiagnosticsFile(ctx, d.pos.file)) { curGroup = null; curIndex = -1; continue; }
			var displayFile = diagnosticsFile(d.pos.file);
			var severity = switch (d.severity) {
				case Information: 3;
				case Warning: 2;
				case Error: 1;
				case Hint: 4;
			};
			var kind = d.kind == null ? 2 : d.kind;
			var args = haxe.Json.stringify(d.message);
			var head = '{"kind":' + kind + ',"severity":' + severity
				+ ',"range":' + posAsRange(d.pos) + ',"args":' + args;
			var group = null;
			for (g in groups) if (g.file == displayFile) { group = g; break; }
			if (group == null) { group = {file: displayFile, items: []}; groups.push(group); }
			group.items.push(head + ',"relatedInformation":[]}');
			curGroup = group; curIndex = group.items.length - 1; curHead = head; curRelated = [];
		}
		// The MissingFields records are grouped by position, and one DKMissingFields is printed per
		// group: the module type the fields would be added to, the file it lives in, and one entry per
		// record carrying its fields and the cause. The context is GMMinimum.
		{
			var order:Array<String> = [];
			var groups2 = new haxe.ds.StringMap<Array<{pos:Position, on:hxc.core.Type.ModuleType,
				scope:hxc.core.Type.ClassFieldScope, fields:Array<{cf:hxc.core.Type.TClassField, t:T,
					ct:hxc.core.CompletionItem.CompletionType}>, cause:String}>>();
			for (mf in ctx.missingFields) {
				if (!isDiagnosticsFile(ctx, mf.pos.file)) continue;
				var key = mf.pos.file + ":" + mf.pos.min + ":" + mf.pos.max;
				var g = groups2.get(key);
				if (g == null) { g = []; groups2.set(key, g); order.push(key); }
				g.push(mf);
			}
			for (key in order) {
				var g = groups2.get(key);
				var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMMinimum);
				var mt = g[0].on;
				var entries:Array<String> = [];
				// A duplicate of a field already offered at this position is dropped, and `unique` is marked
				// when no other entry in the group offers the same name.
				var allNames = new haxe.ds.StringMap<Int>();
				for (mf in g) for (fe in mf.fields)
					allNames.set(fe.cf.name, (allNames.exists(fe.cf.name) ? allNames.get(fe.cf.name) : 0) + 1);
				for (mf in g) {
					var fields:Array<String> = [];
					for (fe in mf.fields) {
						// Use the type serialized when this record was created.
						var ct = hxc.core.CompletionItem.CompletionTypeTools.toJson(gen, fe.ct);
						fields.push(hxc.core.Json.stringOfJson(hxc.core.Json.JsonValue.JObject([
							{name: "field", value: gen.generateClassField(mf.scope, fe.cf)},
							{name: "type", value: ct},
							{name: "unique", value: hxc.core.Json.JsonValue.JBool(allNames.get(fe.cf.name) == 1)}
						])));
					}
					entries.push('{"fields":[' + fields.join(",") + '],"cause":{"kind":'
						+ haxe.Json.stringify(mf.cause) + ',"args":{}}}');
				}
				var inf = TypeFunctions.tInfos(mt);
				var mfile = inf.module == null || inf.module.extra.file == null ? "" : inf.module.extra.file;
				var args = '{"moduleType":' + hxc.core.Json.stringOfJson(gen.generateModuleType(mt))
					+ ',"moduleFile":' + haxe.Json.stringify(mfile)
					+ ',"entries":[' + entries.join(",") + ']}';
				var displayFile = diagnosticsFile(g[0].pos.file);
				var item = '{"kind":7,"severity":1,"range":' + posAsRange(g[0].pos)
					+ ',"args":' + args + ',"relatedInformation":[]}';
				var group = null;
				for (gg in groups) if (gg.file == displayFile) { group = gg; break; }
				if (group == null) { group = {file: displayFile, items: []}; groups.push(group); }
				group.items.push(item);
			}
		}
		// An import declaration nothing ever resolved through. They are read off com.modules, not off the
		// typer, so a module served back from the CACHE still reports its unused imports. com.modules is
		// empty until typing is finalized, so a report emitted for an error that escaped the typing stage
		// carries no import positions at all. hxc registers a module at LOAD time, so its list is full
		// long before generation - ask the flag instead.
		if (ctx.typesGenerated) for (m in ctx.modules) {
			for (e in m.extra.display.importPositions) {
				if (e.used || e.failed == true || !isDiagnosticsFile(ctx, e.p.file)) continue;
				var displayFile = diagnosticsFile(e.p.file);
				var item = '{"kind":' + DK_UNUSED_IMPORT + ',"severity":2,"range":' + posAsRange(e.p)
					+ ',"args":[],"relatedInformation":[]}';
				var group = null;
				for (g in groups) if (g.file == displayFile) { group = g; break; }
				if (group == null) { group = {file: displayFile, items: []}; groups.push(group); }
				group.items.push(item);
			}
		}
		// The removable code follows the messages, carrying its description and the range an editor would
		// delete (null when the declaration is shared).
		for (r in hxc.compiler.Diagnostics.removableCode) {
			if (!isDiagnosticsFile(ctx, r.p.file)) continue;
			var displayFile = diagnosticsFile(r.p.file);
			var args = '{"description":' + haxe.Json.stringify(r.s) + ',"range":'
				+ (r.prange == null ? "null" : posAsRange(r.prange)) + "}";
			var item = '{"kind":' + DK_REMOVABLE_CODE + ',"severity":2,"range":' + posAsRange(r.p)
				+ ',"args":' + args + ',"relatedInformation":[]}';
			var group = null;
			for (g in groups) if (g.file == displayFile) { group = g; break; }
			if (group == null) { group = {file: displayFile, items: []}; groups.push(group); }
			group.items.push(item);
		}
		// The file buckets come out in hash-table fold order, and that fold CONSES, so the printed array is
		// the REVERSE of the bucket visit order. The table starts at size 0 and is keyed by the bucket's
		// own name, and the groups here are in insertion order, which is what the model needs.
		var order = new hxc.core.NameHash.HashTableOrder();
		for (g in groups) order.add(g.file, hxc.core.NameHash.NameHash.stringHash(g.file));
		var visit = order.visitOrder();
		var ordered:Array<{file:String, items:Array<String>}> = [];
		var i = visit.length;
		while (i-- > 0) for (g in groups) if (g.file == visit[i]) { ordered.push(g); break; }
		// A fileless position buckets under the null position's own file, "?" (kept verbatim rather than
		// resolved), and that bucket prints as null.
		var out = [for (g in ordered) '{"file":' + (g.file == "?" ? "null" : haxe.Json.stringify(g.file))
			+ ',"diagnostics":[' + g.items.join(",") + ']}'];
		var raw = "[" + out.join(",") + "]";
		// A JSON-RPC-initiated diagnostics run answers with the protocol envelope; the legacy arg prints
		// the raw array. No trailing newline: the raw print.
		if (ctx.jsonRpcId != null)
			raw = jsonRpcAnswer(ctx, raw);
		answerOut(raw);
	}

	// The legacy signature answer is JSON too, shaped {signatures:[{documentation?, label,
	// parameters:[{label}]}], activeParameter, activeSignature}, where a label reads "(?n:T,
	// n2:T2):Ret" and a parameter label is that same "?n:T" piece. It reads the same signature payload
	// the json-rpc answer does.
	static function displaySignature(ctx:Context):Void {
		inline function sArg(a:hxc.core.Type.TSignatureArg):String
			return (a.opt ? "?" : "") + a.name + ":" + TPrinting.sTypeStr(a.t);
		var sf = hxc.typing.Typer.signatureFound;
		var sigs:Array<hxc.core.Json.JsonValue> = [];
		if (sf != null) for (s in sf.sigs) {
			var fields:Array<hxc.core.Json.JsonField> = [];
			if (s.doc != null) fields.push({name: "documentation", value: hxc.core.Json.JsonValue.JString(Ast.genDocText(s.doc))});
			fields.push({name: "label", value: hxc.core.Json.JsonValue.JString("(" + [for (a in s.args) sArg(a)].join(", ") + "):" + TPrinting.sTypeStr(s.ret))});
			fields.push({name: "parameters", value: hxc.core.Json.JsonValue.JArray([for (a in s.args)
				hxc.core.Json.JsonValue.JObject([{name: "label", value: hxc.core.Json.JsonValue.JString(sArg(a))}])])});
			sigs.push(hxc.core.Json.JsonValue.JObject(fields));
		}
		var active = (sf == null || sf.sigs.length == 0) ? 0 : signatureArgIndex(sf.sigs[0].args, sf.activeArg);
		answerOut(hxc.core.Json.Json.stringOfJson(hxc.core.Json.JsonValue.JObject([
			{name: "signatures", value: hxc.core.Json.JsonValue.JArray(sigs)},
			{name: "activeParameter", value: hxc.core.Json.JsonValue.JInt(active)},
			{name: "activeSignature", value: hxc.core.Json.JsonValue.JInt(0)}
		])));
	}

	// The active parameter is the requested index, except that a trailing rest argument absorbs every index
	// past its own.
	static function signatureArgIndex(args:Array<hxc.core.Type.TSignatureArg>, paramIndex:Int):Int {
		function isRest(t:T):Bool {
			return switch (TypeFunctions.follow(t)) {
				case TAbstract(a, _): a.path.pack.join(".") == "haxe" && a.path.name == "Rest";
				case _: false;
			}
		}
		for (i in 0...args.length) {
			if (i == paramIndex) return paramIndex;
			if (i == args.length - 1 && i < paramIndex && isRest(args[i].t)) return i;
		}
		return paramIndex;
	}

	// A type-path completion is one list of items - the packages and modules under the path, or the
	// enum constructors, sub-types and statics of the module it names - that the legacy lane prints
	// and the json lane writes as completion JSON, in the full generation mode, under the Field mode
	// over the module the path names.
	static function handleTypePathCompletion(ctx:Context, tc:hxc.parser.Parser.TypePathCompletion):Void {
		// Reset the display position so loading the module does not raise again. It is restored once the
		// module is loaded, so the answer's replace range is still cut at the cursor.
		var displayOff = hxc.parser.Parser.displayOffset;
		hxc.parser.Parser.displayOffset = -1;
		var items:Array<{field:hxc.compiler.DisplayXml.DisplayField, entry:hxc.context.DisplayException.CompletionEntry}> = [];
		if (tc.module != null) {
			// An uppercase last pack segment names the module and tc.module a sub-type of it.
			var pack = tc.pack.copy();
			var sModule = tc.module;
			if (pack.length > 0) {
				var lastPack = pack[pack.length - 1];
				if (lastPack.charCodeAt(0) >= "A".code && lastPack.charCodeAt(0) <= "Z".code) {
					sModule = lastPack;
					pack = pack.slice(0, pack.length - 1);
				}
			}
			// Lookup: a bare name resolved from the file's package retries each enclosing package.
			function lookup(pack:Array<String>):hxc.core.Type.ModuleDef {
				return try ModuleLoader.loadModule(ctx, {pack: pack, name: sModule}, Position.nullPos) catch (e:Dynamic) {
					if (!tc.curPackage || pack.length == 0) throw e;
					lookup(pack.slice(0, pack.length - 1));
				}
			}
			// A failure is an abort, which is reported as an error and answered with no fields: nothing on
			// the legacy lane, an empty list over JSON.
			var m = try lookup(pack) catch (e:Dynamic) null;
			if (m == null) {
				if (ctx.jsonRpcId == null) {
					abortWithMessage(ctx, "Could not load module " + Context.sTypePath({pack: tc.pack, name: tc.module}), Position.nullPos);
					return;
				}
			} else {
				// A type's import status is asked of a FRESH typer, so only what the bare name resolves to
				// from nowhere is Imported.
				function ct(t:T):hxc.core.CompletionItem.CompletionType
					return hxc.core.CompletionItem.CompletionTypeTools.fromType(function(path) return importStatusFor(ctx, null, path), t);
				var statics:Null<hxc.core.Type.TClass> = null;
				var enumStatics:Null<hxc.core.Type.TEnum> = null;
				var types = [];
				for (mt in m.types) {
					var info = hxc.core.TypeFunctions.tInfos(mt);
					// The module's main type is where an import finds its statics. Only that class is built;
					// nothing else of the module types.
					if (tc.isImport && info.path.name == tc.module) switch (mt) {
						case TClassDecl(c):
							c.build();
							statics = c;
						case TAbstractDecl({impl: c}) if (c != null):
							c.build();
							statics = c;
						case TEnumDecl(en): enumStatics = en;
						case _:
					}
					if (!info.isPrivate) types.push(mt);
				}
				// The sub-types are listed only when the path named the module itself.
				if (tc.module == sModule) for (mt in types) {
					var info = hxc.core.TypeFunctions.tInfos(mt);
					items.push({field: {kind: "type", name: info.path.name, type: Context.sTypePath(info.path), doc: null},
						entry: {filterName: hxc.core.Globals.sTypePath(info.path),
							toJson: function(gen, i) return hxc.core.CompletionItem.CompletionItem.moduleTypeToJson(gen, mt, 0, i)}});
				}
				// A public static, in the class's own scope.
				if (statics != null) {
					var c = statics;
					var origin = switch (c.kind) {
						case KAbstractImpl(a): hxc.core.CompletionItem.ClassFieldOrigin.Self(TAbstractDecl(a));
						case _: hxc.core.CompletionItem.ClassFieldOrigin.Self(TClassDecl(c));
					};
					for (cf in c.orderedStatics) {
						if (!hxc.core.TypeFunctions.hasClassFieldFlag(cf, CfPublic)) continue;
						var t = switch (cf.type) { case TLazy(r): TypeFunctions.lazyType(r); case t2: t2; };
						var c2 = ct(t);
						items.push({field: {kind: cf.kind.match(Method(_)) ? "method" : "var", name: cf.name, type: TPrinting.sTypeStr(cf.type),
								doc: cf.doc == null ? null : Ast.genDocText(cf.doc)},
							entry: {filterName: cf.name,
								toJson: function(gen, i) return hxc.core.CompletionItem.CompletionItem.classFieldToJson(gen, CFSStatic, cf, origin, true, c2, i, false, false)}});
					}
				}
				// The enum's constructors go IN FRONT, folded over the constructor map (ascending by name)
				// with a prepend - so they read descending.
				if (enumStatics != null) {
					var en = enumStatics;
					var names = [for (n in en.constrs.keys()) n];
					hxc.core.StringSort.sort(names);
					for (n in names) {
						var ef = en.constrs.get(n);
						var c2 = ct(ef.type);
						items.unshift({field: {kind: hxc.core.TypeFunctions.follow(ef.type).match(TFun(_)) ? "method" : "var", name: ef.name,
								type: TPrinting.sTypeStr(ef.type), doc: ef.doc == null ? null : Ast.genDocText(ef.doc)},
							entry: {filterName: ef.name,
								toJson: function(gen, i) return hxc.core.CompletionItem.CompletionItem.enumFieldToJson(gen, ef,
									hxc.core.CompletionItem.ClassFieldOrigin.Self(TEnumDecl(en)), true, c2, i)}});
					}
				}
			}
		} else {
			// The packages and then the modules the type-path read finds across the class paths, each
			// sorted and deduplicated.
			var r = readTypePath(ctx, tc.pack);
			// A package with neither modules nor sub-packages is an abort at the null position, "No modules
			// found in <pack>", not an empty list. Reported the way an abort is - the bare message - rather
			// than thrown from inside this completion handler, where only the request path's generic catch
			// would see it.
			if (r.packs.length == 0 && r.modules.length == 0 && ctx.jsonRpcId == null) {
				abortWithMessage(ctx, "No modules found in " + tc.pack.join("."), Position.nullPos);
				return;
			}
			for (n in r.packs) {
				var full = tc.pack.concat([n]);
				items.push({field: {kind: "package", name: n, type: "", doc: null},
					entry: {filterName: full.join("."), toJson: function(gen, i) return hxc.core.CompletionItem.CompletionItem.packageToJson(full, i)}});
			}
			for (n in r.modules) {
				var pack = tc.pack;
				items.push({field: {kind: "type", name: n, type: "", doc: null},
					entry: {filterName: pack.length == 0 ? n : pack.join(".") + "." + n, toJson: function(gen, i) return moduleRefToJson(pack, n, i)}});
			}
		}
		if (ctx.jsonRpcId != null) {
			var gen = hxc.context.DisplayJson.createJsonContext(false);
			// The mode's module path is the pack consumed so far, its last segment naming the module; an
			// empty pack gives the empty path.
			var mpack = tc.pack.copy();
			var mname = mpack.length == 0 ? "" : mpack.pop();
			var tp = tc.pos == null ? new Position(hxc.parser.Parser.displayFile, 0, 0) : tc.pos;
			var item = hxc.core.Json.JsonValue.JObject([
				{name: "kind", value: hxc.core.Json.JsonValue.JString("Module")},
				{name: "args", value: hxc.core.Json.JsonValue.JObject([
					{name: "path", value: hxc.core.Json.JsonValue.JObject([
						{name: "moduleName", value: hxc.core.Json.JsonValue.JString(mname)},
						{name: "pack", value: hxc.core.Json.JsonValue.JArray([for (x in mpack) hxc.core.Json.JsonValue.JString(x)])}
					])}
				])}
			]);
			var mode = hxc.core.Json.JsonValue.JObject([
				{name: "kind", value: hxc.core.Json.JsonValue.JInt(0)},
				{name: "args", value: hxc.core.Json.JsonValue.JObject([
					{name: "item", value: item},
					{name: "range", value: gen.generatePosAsRange(tp)},
					{name: "iterator", value: hxc.core.Json.JsonValue.JNull},
					{name: "keyValueIterator", value: hxc.core.Json.JsonValue.JNull}
				])}
			]);
			// The subject is the path segment, the insert position cut at the cursor by the completion
			// JSON.
			var result = hxc.context.DisplayException.fieldsToJson(gen, [for (it in items) it.entry], mode, null,
				new Position(tp.file, tp.min, displayOff), tp);
			answerOut(jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(result)));
			return;
		}
		answerOut(hxc.compiler.DisplayXml.printFields([for (it in items) it.field]));
	}

	// Every class path is read as `path + pack`, so the class path "" reads the bare pack; with no pack
	// that is "" itself, which on Windows lists as the root of the current drive (FindFirstFile of the root
	// pattern), and the stat of "" + "/" + f that follows is relative to that root as well.
	static function readTypePath(ctx:Context, pack:Array<String>):{packs:Array<String>, modules:Array<String>} {
		var p = pack.copy();
		if (p.length > 0 && ctx.packageRemaps.exists(p[0])) p[0] = ctx.packageRemaps.get(p[0]);
		var classes:Array<String> = [];
		var packages:Array<String> = [];
		var windows = Sys.systemName() == "Windows";
		for (path in ctx.classPath) {
			var dir = path + p.join("/");
			var r:Array<String> = try FileSystem.readDirectory(dir == "" && windows ? "/" : dir) catch (_:Dynamic) [];
			for (f in r) {
				var isDir = try FileSystem.isDirectory(dir + "/" + f) catch (_:Dynamic) false;
				if (isDir) {
					if (f.length > 0 && f.charCodeAt(0) >= "a".code && f.charCodeAt(0) <= "z".code) packages.push(f);
				} else {
					// What follows the last dot, lowercased.
					var dot = f.lastIndexOf(".");
					var ext = dot < 0 ? f : f.substr(dot + 1);
					if (ext.toLowerCase() == "hx" && f != "import.hx") {
						var c = f.substr(0, f.length - 3);
						if (c.indexOf(".") < 0 && (c.length < 2 || c.substr(c.length - 2) != "__")) classes.push(c);
					}
				}
			}
		}
		// Sorted, adjacent duplicates dropped.
		function unique(l:Array<String>):Array<String> {
			l.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
			var out:Array<String> = [];
			for (x in l) if (out.length == 0 || out[out.length - 1] != x) out.push(x);
			return out;
		}
		return {packs: unique(packages), modules: unique(classes)};
	}

	// A module that has not been loaded is named by its path alone, which is all the class-path walk
	// knows about it.
	static function moduleRefToJson(pack:Array<String>, name:String, index:Int):hxc.core.Json.JsonValue {
		return hxc.core.Json.JsonValue.JObject([
			{name: "kind", value: hxc.core.Json.JsonValue.JString("Module")},
			{name: "args", value: hxc.core.Json.JsonValue.JObject([
				{name: "path", value: hxc.core.Json.JsonValue.JObject([
					{name: "moduleName", value: hxc.core.Json.JsonValue.JString(name)},
					{name: "pack", value: hxc.core.Json.JsonValue.JArray([for (x in pack) hxc.core.Json.JsonValue.JString(x)])}
				])}
			])},
			{name: "index", value: hxc.core.Json.JsonValue.JInt(index)}
		]);
	}

	// Each metadata argument whose span encloses the display position is processed and typed as a value.
	// Nothing catches what that typing raises: the marked node raises its answer or its error.
	static function checkDisplayMetadata(ctx:Context):Void {
		for (key in ctx.moduleLut.keys()) {
			var m = ctx.moduleLut.get(key);
			for (mt in m.types) {
				var inf = hxc.core.TypeFunctions.tInfos(mt);
				// The global metadata check: a type's own metadata, and each class or abstract field's metadata
				// as DECLARED (before an @:overload is consumed into overloads). A module the display check
				// took from the cache checks its typed metadata instead: each field's, its overloads', and the
				// module statics'.
				var metas = [inf.meta];
				if (m == warmDisplayModule) {
					switch (mt) {
						case TClassDecl(c):
							var cfs = c.orderedStatics.copy();
							if (!c.kind.match(KAbstractImpl(_))) {
								cfs = cfs.concat(c.orderedFields);
								if (c.constructor != null) cfs.push(c.constructor);
							}
							for (cf in cfs) {
								metas.push(cf.meta);
								for (o in cf.overloads) metas.push(o.meta);
							}
						case _:
					}
				} else {
					var entryDecl = ctx.declOfType.get(Context.pathKey(inf.path));
					if (entryDecl != null) switch (entryDecl.decl) {
						// An abstract's fields are its impl class's (the check runs in that class's init).
						case EClass(d): for (cff in d.dData) metas.push(cff.cffMeta);
						case _:
					}
				}
				var fieldClass:Null<hxc.core.Type.TClass> = switch (mt) {
					case TClassDecl(c): c;
					case _: null;
				};
				for (mi in 0...metas.length) for (entry in metas[mi]) for (arg in entry.params) {
					if (!hxc.typing.Typer.atDisplayPos(arg.pos)) continue;
					var tctx = new hxc.typing.TyperContext(ctx);
					// A type's own metadata is checked from the module's context, whose class is the null class; a
					// field's from its class's.
					var c = mi == 0 ? null : fieldClass;
					if (c != null) {
						tctx.curclass = c;
						tctx.typeParams = c.params;
					}
					// The argument is typed through the ENCLOSING module's typer context, so a bare name
					// resolves against that module's own types and imports.
					var savedMod = ctx.currentModule;
					ctx.currentModule = m;
					hxc.typing.ExprPreprocessing.process(arg);
					try hxc.typing.Typer.typeExpr(tctx, arg, hxc.core.WithType.WithTypeTools.value) catch (e:Dynamic) {
						ctx.currentModule = savedMod;
						throw e;
					}
					ctx.currentModule = savedMod;
				}
			}
		}
	}

	// The documentation registered for the metadata name the cursor is on, or null when the registry
	// has no entry for it (every custom metadata, which answers nothing). The hover gets the same
	// assembled string the --help list prints - params prefix, doc, platforms, origin - not the bare
	// doc. An internal entry has no documentation and answers nothing.
	static function displayMetaDoc(ctx:Context):Null<String> {
		var want = hxc.parser.Parser.displayMetaName;
		if (want == null) return null;
		var user = ctx.userMetas.get(want.charAt(0) == ":" ? want.substr(1) : want);
		if (user != null) return docString(user.params, user.doc, user.platforms, true, user.source);
		for (mv in hxc.context.MetaRegistry.metas())
			if (hxc.context.MetaRegistry.stringField(mv, "metadata", "") == want) {
				// Only an INTERNAL entry has no documentation, so an entry with an empty doc still answers
				// with whatever its platforms add.
				if (hxc.context.MetaRegistry.boolField(mv, "internal")) return null;
				return registryDoc(mv, true);
			}
		return null;
	}

	// Completing a metadata name answers the whole registry as Metadata fields. The subject is null for the
	// completion marker, which is why a bare @ lists everything rather than filtering.
	// Every metadata, the compiler's and the user's, sorted by name together (plain string compare), each
	// as a Metadata item; the written name is the subject, none for the bare `@` (Meta.HxCompletion).
	// The Metadata item's args for a compiler metadata.
	static function registryMetaItem(mv:Array<hxc.core.Json.JsonField>):hxc.core.Json.JsonValue {
		var name = hxc.context.MetaRegistry.stringField(mv, "metadata", "");
		// Reverse prepended HasParam entries to restore their order.
		var params = hxc.context.MetaRegistry.arrayField(mv, "params").copy();
		params.reverse();
		return hxc.core.Json.JsonValue.JObject([
			{name: "name", value: hxc.core.Json.JsonValue.JString("@" + name)},
			{name: "doc", value: hxc.core.Json.JsonValue.JString(hxc.context.MetaRegistry.stringField(mv, "doc", ""))},
			{name: "parameters", value: hxc.core.Json.JsonValue.JArray(params)},
			{name: "platforms", value: hxc.core.Json.JsonValue.JArray(hxc.context.MetaRegistry.arrayField(mv, "platforms"))},
			{name: "targets", value: hxc.core.Json.JsonValue.JArray(hxc.context.MetaRegistry.arrayField(mv, "targets"))},
			{name: "internal", value: hxc.core.Json.JsonValue.JBool(hxc.context.MetaRegistry.boolField(mv, "internal"))},
			{name: "origin", value: hxc.core.Json.JsonValue.JString("haxe compiler")},
			{name: "links", value: hxc.core.Json.JsonValue.JArray(hxc.context.MetaRegistry.arrayField(mv, "links"))}
		]);
	}

	// Under hover with json output, a compiler metadata's name answers with its own item, which
	// documents nothing, over the entry; a custom one answers nothing here.
	static function jsonMetaHover(ctx:Context):Null<String> {
		var want = hxc.parser.Parser.displayMetaName;
		if (want == null || hxc.parser.Parser.displayMetaPos == null) return null;
		for (mv in hxc.context.MetaRegistry.metas())
			if (hxc.context.MetaRegistry.stringField(mv, "metadata", "") == want) {
				var gen = new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull);
				return jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(hxc.core.Json.JsonValue.JObject([
					{name: "documentation", value: hxc.core.Json.JsonValue.JNull},
					{name: "range", value: gen.generatePosAsRange(hxc.parser.Parser.displayMetaPos)},
					{name: "item", value: hxc.core.Json.JsonValue.JObject([
						{name: "kind", value: hxc.core.Json.JsonValue.JString("Metadata")},
						{name: "args", value: registryMetaItem(mv)}
					])},
					{name: "expected", value: hxc.core.Json.JsonValue.JNull}
				])));
			}
		return null;
	}

	static function answerMetadataCompletion(ctx:Context):Void {
		var metas:Array<{name:String, doc:String, json:hxc.core.Json.JsonValue}> = [];
		for (mv in hxc.context.MetaRegistry.metas()) {
			var name = hxc.context.MetaRegistry.stringField(mv, "metadata", "");
			// The 4.3.7 binary's generated Meta list predates this meta.json entry.
			if (name == ":inlineConstructorArgument") continue;
			metas.push({name: name, doc: hxc.context.MetaRegistry.stringField(mv, "doc", ""), json: registryMetaItem(mv)});
		}
		for (k in ctx.userMetas.keys()) {
			var e = ctx.userMetas.get(k);
			function strs(l:Array<String>):Array<hxc.core.Json.JsonValue> return [for (x in l) hxc.core.Json.JsonValue.JString(x)];
			var params = e.params.copy();
			params.reverse();
			var links = e.links.copy();
			links.reverse();
			metas.push({name: k, doc: e.doc, json: hxc.core.Json.JsonValue.JObject([
				{name: "name", value: hxc.core.Json.JsonValue.JString("@" + k)},
				{name: "doc", value: hxc.core.Json.JsonValue.JString(e.doc)},
				{name: "parameters", value: hxc.core.Json.JsonValue.JArray(strs(params))},
				{name: "platforms", value: hxc.core.Json.JsonValue.JArray(strs(e.platforms))},
				{name: "targets", value: hxc.core.Json.JsonValue.JArray(strs(e.targets))},
				{name: "internal", value: hxc.core.Json.JsonValue.JBool(false)},
				{name: "origin", value: hxc.core.Json.JsonValue.JString(e.source == null ? "user-defined" : e.source)},
				{name: "links", value: hxc.core.Json.JsonValue.JArray(strs(links))}
			])});
		}
		metas.sort(function(a, b) return a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
		if (ctx.jsonRpcId != null) {
			var items:Array<hxc.context.DisplayException.CompletionEntry> = [for (m in metas) {
				filterName: m.name,
				toJson: function(gen, i) {
					var fl:Array<hxc.core.Json.JsonField> = [
						{name: "kind", value: hxc.core.Json.JsonValue.JString("Metadata")},
						{name: "args", value: m.json}
					];
					if (i != null) fl.push({name: "index", value: hxc.core.Json.JsonValue.JInt(i)});
					return hxc.core.Json.JsonValue.JObject(fl);
				}
			}];
			var gen = hxc.context.DisplayJson.createJsonContext(true);
			var name = hxc.parser.Parser.displayMetaName;
			var mp = hxc.parser.Parser.displayMetaPos;
			var subj = patchCompletionSubject(name == hxc.parser.Parser.HX_COMPLETION_META ? null : name, mp);
			var mode = hxc.core.Json.JsonValue.JObject([{name: "kind", value: hxc.core.Json.JsonValue.JInt(3)}]);
			answerOut(jsonRpcAnswer(ctx, hxc.core.Json.Json.stringOfJson(
				hxc.context.DisplayException.fieldsToJson(gen, items, mode, subj.name, subj.pos, mp))));
			return;
		}
		answerOut(hxc.compiler.DisplayXml.printFields([for (m in metas) {kind: "metadata", name: "@" + m.name, type: "", doc: m.doc}]));
	}

	// The display file is looked up in the cache, and a file it does not hold is removed and its
	// modules tainted, so the request re-parses and re-types it instead of answering from something
	// stale. hxc does not answer from a cached module, so a successful lookup only means "leave the
	// cache alone".
	static function checkDisplayFile(ctx:Context):Void {
		warmDisplayModule = null;
		if (ctx.displaySpec == null) return;
		// The DMNone report modes (diagnostics, statistics, compiledTypes) are excluded at the call site,
		// which runs only when the display kind is not DMNone.
		if (isDisplay(ctx, "diagnostics") || isDisplay(ctx, "statistics") || isDisplay(ctx, "compiledTypes")) return;
		var parts = displayParts(ctx);
		if (parts.length == 0) return;
		var file = parts[0];
		if (file == null || file == "" || file == "?") return;
		var full = try sys.FileSystem.fullPath(file) catch (_:Dynamic) file;
		var key = full.toLowerCase();
		var cfile = hxc.context.DisplayJson.cache.findFile(key);
		if (cfile != null && checkDisplayModuleOf(ctx, full, cfile)) return;
		hxc.context.DisplayJson.cache.removeFiles(key);
		hxc.context.DisplayJson.cache.taintModules(key, "check_display_file");
	}

	// The display module the display-module check took from the cache, which is not typed again.
	static var warmDisplayModule:Null<ModuleDef> = null;

	// The display file's module goes through the module-typing hook, and one that comes back is checked as
	// a display module; anything that fails on the way is a lookup failure, which taints the file instead.
	static function checkDisplayModuleOf(ctx:Context, full:String, cfile:hxc.context.CompilationCache.CachedFile):Bool {
		if (cfile.decls == null) return false;
		var path = displayModulePath(ctx, full);
		if (path == null) return false;
		var nparts = path.name.split(".");
		if (nparts.length > 1) {
			if (nparts.length != 2 || nparts[1] == "macro") return false;
			path = {pack: path.pack, name: nparts[0]};
		}
		var m = try hxc.context.ServerCache.typeModule(ctx, path, Position.nullPos) catch (_:Dynamic) null;
		if (m == null) return false;
		// The module's IMPORT declarations run into it first (typing an import-only list into the module
		// adds no types), so a name in the field below resolves the way the file resolves it.
		hxc.context.ModuleLoader.typeImportsIntoModule(ctx, m,
			[for (d in cfile.decls) if (d.decl.match(EImport(_) | EUsing(_))) d]);
		// The display-module check pairs the cached SYNTAX back with the cached types by name position and
		// re-types the one field the cursor is in, so the display hooks fire on it. Its result is dropped:
		// the cached module is shared with every later request.
		for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (c.kind.match(KModuleFields(_))):
				// The module's own statics, found by name position and made into fields as module typing
				// does.
				var fields:Array<hxc.ast.Ast.ClassField> = [];
				for (dd in cfile.decls) switch (dd.decl) {
					case EStatic(sd): fields.push({cffName: sd.dName, cffDoc: sd.dDoc, cffPos: dd.pos, cffMeta: sd.dMeta,
						cffAccess: [{access: AStatic, pos: Position.nullPos}].concat(sd.dFlags), cffKind: sd.dData});
					case _:
				}
				ctx.declOfType.set(Context.pathKey(c.path), {decl: EClass({dName: {name: c.path.name, pos: c.namePos},
					dDoc: null, dParams: [], dMeta: [], dFlags: [HPrivate], dData: fields}), pos: c.pos});
				for (cf in c.orderedStatics) {
					if (!hxc.typing.Typer.atDisplayPos(cf.pos)) continue;
					var saved = cf.expr;
					cf.expr = null;
					try hxc.typing.TypeFields.forceFieldBody(ctx, c, cf) catch (e:Dynamic) { cf.expr = saved; throw e; }
					cf.expr = saved;
				}
			case TClassDecl(c):
				// :22/:53: the syntax is found by name position - an abstract's impl class carries the
				// abstract's own, so both kinds of declaration pair back the same way.
				var found = false;
				for (dd in cfile.decls) switch (dd.decl) {
					case EClass(cd) if (cd.dName.pos.min == c.namePos.min && cd.dName.pos.max == c.namePos.max):
						ctx.declOfType.set(Context.pathKey(c.path), {decl: dd.decl, pos: dd.pos});
						found = true;
					case EAbstract(ad):
						// For an abstract's impl class the check works off the ABSTRACT's fields, found by its name
						// position; hxc looks those fields up through the synthetic impl declaration, so it is
						// rebuilt here.
						switch (c.kind) {
							case KAbstractImpl(a) if (ad.dName.pos.min == a.namePos.min && ad.dName.pos.max == a.namePos.max):
								hxc.context.ModuleLoader.registerAbstractImplDecl(ctx, c, a, ad);
								found = true;
							case _:
						}
					case _:
				}
				if (!found) continue;
				for (cf in c.orderedFields.concat(c.orderedStatics)) {
					if (!hxc.typing.Typer.atDisplayPos(cf.pos)) continue;
					var saved = cf.expr;
					cf.expr = null;
					try hxc.typing.TypeFields.forceFieldBody(ctx, c, cf) catch (e:Dynamic) { cf.expr = saved; throw e; }
					cf.expr = saved;
				}
			case _:
		}
		warmDisplayModule = m;
		return true;
	}

	// These report modes collect messages instead of printing them.
	public static function isDiagnosticsRun(ctx:Context):Bool {
		return isDisplay(ctx, "diagnostics");
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
		exitRequest(1);
	}

	// A missing option value is an argument error; reading past the end would give null, and `haxe -D` (and
	// every other value-taking flag) would exit 0 in silence.
	static function argValue(args:Array<String>, i:Int, flag:String):String {
		if (i >= args.length) throw "option '" + flag + "' needs an argument";
		return args[i];
	}

	// Type-path parsing, run on -x and --main as the argument is read: the path check's verdict on the
	// parts, then the uppercase check on the name. Both raise a failure, which the option parser does not
	// frame.
	static function checkTypePath(s:String):Void {
		var perr = parsePathError(s);
		if (perr != null) throw new ArgFailure("Could not process argument " + s + "\n" + perr);
		try hxc.core.StringHelper.checkUppercase(parseTypePath(s).name)
		catch (e:haxe.Exception) throw new ArgFailure(e.message);
	}

	// Path parts: a .hx path loses the suffix and splits on either slash, anything else on dots. An empty
	// string gives no parts at all.
	static function getPathParts(f:String):Array<String> {
		if (f.length > 3 && f.substr(f.length - 3) == ".hx")
			return StringTools.replace(f.substr(0, f.length - 3), "\\", "/").split("/");
		return f == "" ? [] : f.split(".");
	}

	// Path parts plus the invalid-character and package-name checks. Returns the error message for the
	// first offending part, or null when the path is fine.
	static function parsePathError(f:String):Null<String> {
		var parts = getPathParts(f);
		function invalidChar(x:String):Null<String> {
			for (i in 1...x.length) {
				var c = x.charCodeAt(i);
				var ok = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code)
					|| (c >= "0".code && c <= "9".code) || c == "_".code || c == ".".code;
				if (!ok) return "Invalid character: " + hxc.core.StringHelper.sEscape(x.charAt(i));
			}
			return null;
		}
		// parse_path raises this one inside its own handler, which wraps it a second time.
		if (parts.length == 0) return "Could not process argument " + f + "\nPackage name must not be empty";
		for (k in 0...parts.length) {
			var x = parts[k];
			if (k == parts.length - 1) return invalidChar(x);
			if (x.length == 0) return "Package name must not be empty";
			var c0 = x.charCodeAt(0);
			if ((c0 < "a".code || c0 > "z".code) && c0 != "_".code)
				return "Package name must start with a lowercase letter";
			var e = invalidChar(x);
			if (e != null) return e;
		}
		return null;
	}

	// Expand one section of the command line before any argument is parsed. An hxml file's lines and a
	// library's haxelib lines are spliced in place of the argument that named them, --cwd takes effect at
	// once (a later hxml is read from the new directory), and --run ends the command line: what follows it
	// is the program's own argv.
	static function processParams(pl:Array<String>, each:{v:Array<String>}):{params:Array<String>, rest:Array<String>, sysArgs:Null<Array<String>>} {
		var curdir = Sys.getCwd();
		var addedLibs = new Map<String, Bool>();
		var acc:Array<String> = [];
		// --cwd takes effect immediately, so the directory is reset once the section's parameters are
		// known.
		function create(rest:Array<String>, sysArgs:Null<Array<String>>) {
			hxc.core.Cwd.set(curdir);
			return {params: each.v.concat(acc), rest: rest, sysArgs: sysArgs};
		}
		inline function isLib(a:String):Bool return a == "-L" || a == "--library" || a == "-lib";
		var l = pl;
		var i = 0;
		while (i < l.length) {
			var a = l[i];
			var hasValue = i + 1 < l.length;
			if (a == "--next") {
				// An empty --next is skipped
				if (acc.length == 0) {
					i++;
					continue;
				}
				return create(l.slice(i + 1), null);
			}
			if (a == "--each") {
				each.v = acc;
				acc = [];
				i++;
				continue;
			}
			if ((a == "--cwd" || a == "-C") && hasValue) {
				// Changed now since it affects hxml loading, and pushed as --cwd so the argument parser
				// changes it again.
				var dir = l[i + 1];
				var ok = FileSystem.exists(dir) && FileSystem.isDirectory(dir);
				if (ok) ok = hxc.core.Cwd.set(dir);
				if (!ok) throw new ArgFailure("Invalid directory: " + dir);
				acc.push("--cwd");
				acc.push(dir);
				i += 2;
				continue;
			}
			if (a == "--run" && hasValue) {
				acc.push("-x");
				acc.push(l[i + 1]);
				return create([], l.slice(i + 2));
			}
			if (isLib(a) && hasValue) {
				// A run of libraries resolves in one call, and a library this section already added is not
				// added again.
				var libs:Array<String> = [];
				var j = i;
				while (j + 1 < l.length && isLib(l[j])) {
					libs.push(l[j + 1]);
					j += 2;
				}
				var rest = l.slice(j);
				libs = [for (n in libs) if (!addedLibs.exists(n)) n];
				for (n in libs) addedLibs.set(n, true);
				l = addLibs(libs, rest).concat(rest);
				i = 0;
				continue;
			}
			// An hxml argument is not expanded when it follows -cmd, and one that cannot be read is pushed
			// back as the literal `<arg> (file not found)`.
			if (StringTools.endsWith(a, ".hxml") && !(acc.length > 0 && (acc[acc.length - 1] == "-cmd" || acc[acc.length - 1] == "--cmd"))) {
				var lines = try parseHxml(a) catch (_:Dynamic) null;
				if (lines == null) {
					acc.push(a + " (file not found)");
					i++;
				} else {
					l = lines.concat(l.slice(i + 1));
					i = 0;
				}
				continue;
			}
			acc.push(a);
			i++;
		}
		return create([], null);
	}

	// The file is opened as named, from the current directory, and split at every run of line breaks.
	static function parseHxml(file:String):Array<String> {
		if (!FileSystem.exists(file) || FileSystem.isDirectory(file)) throw "not found";
		var args:Array<String> = [];
		for (line in StringTools.replace(File.getContent(file), "\r", "\n").split("\n"))
			args = args.concat(parseHxmlLine(line));
		return args;
	}

	// One `haxelib path` call for the run of libraries. --haxelib-global is looked for in the
	// arguments after them.
	static function addLibs(libs:Array<String>, args:Array<String>):Array<String> {
		if (libs.length == 0) return [];
		var cmd = (args.indexOf("--haxelib-global") >= 0 ? ["--global"] : []).concat(["path"]).concat(libs);
		// The hxcpp host's spawn intermittently fails outright under load; one retry covers it.
		var p = try new Process("haxelib", cmd) catch (_:Dynamic) {
			Sys.sleep(0.1);
			new Process("haxelib", cmd);
		};
		var stdout = p.stdout.readAll().toString();
		var stderr = p.stderr.readAll().toString();
		var code = p.exitCode();
		p.close();
		if (code != 0) {
			// The two streams are read as LINE LISTS and joined with "\n", so a Windows child's trailing CR
			// stays in the message and reaches stderr verbatim; it is not trimmed.
			function inputList(sv:String):Array<String> {
				var a = sv.split("\n");
				if (a.length > 0 && a[a.length - 1] == "") a.pop();
				return a;
			}
			var outLines = inputList(stdout), errLines = inputList(stderr);
			if (outLines.length == 0 && errLines.length == 0)
				throw new ArgFailure("Failed to call haxelib (command not found ?)");
			if (outLines.length == 0 && errLines.length == 1
				&& StringTools.endsWith(StringTools.trim(errLines[0]), "Module not found: path"))
				throw new ArgFailure("The haxelib command has been strip'ed, please install it again");
			throw new ArgFailure(outLines.concat(errLines).join("\n"));
		}
		// Each non-empty stripped line - a bare path is a class path, `-L <dir>` a neko link path, anything
		// else a flag with the rest of the line after its first space.
		var out:Array<String> = [];
		for (line in stdout.split("\n")) {
			var l = StringTools.trim(line);
			if (l == "") continue;
			if (l.charCodeAt(0) != "-".code) {
				out.push("-cp");
				out.push(l);
				continue;
			}
			var sp = l.indexOf(" ");
			var param = sp < 0 ? l : l.substr(0, sp);
			var value = sp < 0 ? "" : l.substr(sp + 1);
			if (param == "-L") {
				out.push("--neko-lib-path");
				out.push(l.substr(3));
				continue;
			}
			out.push(param);
			if (value != "") out.push(value);
		}
		return out;
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

	// A fatal error joins the message store before printing, so -D message.reporting picks the configured
	// formatter (every abort prints through it).
	static function abortWithMessage(ctx:Context, msg:String, pos:Position, depth:Int = 0, ?stack:Array<{message:String, pos:Position, ?depth:Int}>):Void {
		if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null) Sys.println("[abort] " + msg.split("
")[0]);
		ctx.raiseTypingErrors = false;
		if (ctx.isDiagnosticsRun()) ctx.diagnostics = [];
		ctx.addTypingError(msg, pos, depth, stack);
		flushPendingMessages(ctx);
		exitRequest(1);
	}

	static function printPositionMessage(msg:String, pos:Position):Void {
		// Classic message formatter: each continuation line gets a "... " prefix and repeats the position.
		var epos = Globals.getErrorPosRef(function(file, line) return '$file:$line:', pos);
		var lines = msg.split("\n");
		var parts = [lines[0]];
		for (i in 1...lines.length) parts.push("... " + lines[i]);
		answerOut(epos + " : " + parts.join("\n" + epos + " : ") + "\n");
	}

	static function addResource(ctx:Context, spec:String):Void {
		var parts = spec.split("@");
		if (parts.length > 2) throw "Invalid Resource format, expected file@name";
		var file = parts[0];
		var name = parts.length == 1 ? file : parts[1];
		if (ctx.resources.exists(name)) throw "Duplicate resource name " + name;
		// A read failure becomes a message that names the file; letting the underlying error out would
		// print the raw exception value.
		// The failure is reported PLAIN (ArgFailure); a String thrown here would take the bad-argument
		// shape instead and come out as `: <msg>.`
		var bytes = try sys.io.File.getBytes(file) catch (_:Dynamic) throw new ArgFailure("Resource file not found: " + file);
		ctx.addResource(name, bytes);
	}
}
