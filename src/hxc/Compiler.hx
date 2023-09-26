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

class Compiler {
	public function new() run(Sys.args());
	public static function main() run(Sys.args());

	public static function run(args:Array<String>):Void {
		args = expandArgs(args);
		var ctx = new Context();
		Setup.setupCommonContext(ctx);
		ModuleLoader.attach(ctx);

		var userCp:Array<String> = [];
		var mainClass:Null<String> = null;
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
				case "-js" | "--js":
					platform = Js;
					targetDir = "js";
					i++; // Consume the output file
				case "-cpp" | "--cpp":
					platform = Cpp;
					targetDir = "cpp";
					i++; // Consume the output dir
				case "--macro":
					ctx.initMacros.push(args[i++]);
				case "-v" | "--verbose":
					ctx.defines.rawDefine("verbose");
				case "--dce":
					i++;
				case _:
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
		hxc.eval.EvalMacro.runInitMacros(ctx, ctx.initMacros);

		if (mainClass == null) {
			Sys.println("hxc " + Globals.sVersion + " (" + Globals.platformName(platform) + ", no -main)");
			return;
		}
		var path = parseTypePath(mainClass);
		try {
			var m = ModuleLoader.loadModule(ctx, path, Position.nullPos);
			TypeResolve.resolveAll(ctx);
			TypeFields.typeAllModules(ctx);
			abortOnDiagnostics(ctx);
			hxc.eval.EvalMacro.runGenerateCallbacks();
			abortOnDiagnostics(ctx);
			if (platform == Eval) {
				// --interp: run the program through the evaluator so its own output (Sys.println,
				// utest, ...) is the only thing on stdout, matching the canonical haxe oracle.
				var ectx = hxc.eval.EvalMain.create(false, ctx.resources, ctx.defines, ctx.classPath);
				hxc.eval.EvalMain.addModules(ectx, ctx.modules);
				hxc.eval.EvalMain.runMain(ectx, path);
			} else {
				Sys.println("Loaded " + Context.sTypePath(path) + " (" + m.types.length + " types) for " + Globals.platformName(platform));
			}
		} catch (ex:hxc.eval.EvalExceptions.EvalRunTimeException) {
			// An uncaught exception escaping the interpreted program: render the thrown value and its
			// position, as the canonical eval target does, rather than the bare wrapper message.
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
			printPositionMessage(e.message, e.pos);
			Sys.exit(1);
		} catch (e:hxc.core.TypingError) {
			printPositionMessage(e.message, e.pos);
			Sys.exit(1);
		} catch (e:Dynamic) {
			Sys.stderr().writeString("Error: " + Std.string(e) + "\n");
			Sys.exit(1);
		}
	}

	static function parseTypePath(s:String):Path {
		var parts = s.split(".");
		var name = parts.pop();
		return {pack: parts, name: name};
	}

	static function abortOnDiagnostics(ctx:Context):Void {
		if (!ctx.hasDiagnostics()) return;
		for (d in ctx.diagnostics) printPositionMessage(d.message, d.pos);
		Sys.exit(1);
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

	static function parseHxmlLine(line:String):Array<String> {
		line = StringTools.trim(StringTools.replace(line, "\r", ""));
		if (line == "" || StringTools.startsWith(line, "#")) return [];
		var out:Array<String> = [];
		var buf = new StringBuf();
		var quote = 0;
		var escaped = false;
		var i = 0;
		function flush() {
			var s = buf.toString();
			if (s.length > 0) {
				out.push(s);
				buf = new StringBuf();
			}
		}
		while (i < line.length) {
			var c = line.charCodeAt(i++);
			if (escaped) {
				buf.addChar(c);
				escaped = false;
				continue;
			}
			if (c == "\\".code && quote != 0) {
				escaped = true;
				continue;
			}
			if (quote != 0) {
				if (c == quote) quote = 0 else buf.addChar(c);
				continue;
			}
			if (c == "\"".code || c == "'".code) {
				quote = c;
				continue;
			}
			if (c == " ".code || c == "\t".code) {
				flush();
				continue;
			}
			buf.addChar(c);
		}
		flush();
		return out;
	}

	static function directoryOf(path:String):String {
		var p = StringTools.replace(path, "\\", "/");
		var i = p.lastIndexOf("/");
		return i < 0 ? "" : p.substr(0, i);
	}

	static function printPositionMessage(msg:String, pos:Position):Void {
		Sys.stderr().writeString(Globals.getErrorPosRef(function(file, line) return '$file:$line:', pos) + " : " + msg + "
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
