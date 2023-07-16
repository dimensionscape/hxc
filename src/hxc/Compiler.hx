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

class Compiler {
	public function new() run(Sys.args());
	public static function main() run(Sys.args());

	public static function run(args:Array<String>):Void {
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
					i++;
				case "-v" | "--verbose":
					ctx.defines.rawDefine("verbose");
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

		if (mainClass == null) {
			Sys.println("hxc " + Globals.sVersion + " (" + Globals.platformName(platform) + ", no -main)");
			return;
		}
		var path = parseTypePath(mainClass);
		try {
			var m = ModuleLoader.loadModule(ctx, path, Position.nullPos);
			TypeResolve.resolveAll(ctx);
			TypeFields.typeAllModules(ctx);
			if (platform == Eval) {
				// --interp: run the program through the evaluator so its own output (Sys.println,
				// utest, ...) is the only thing on stdout, matching the canonical haxe oracle.
				var ectx = hxc.eval.EvalMain.create(false);
				hxc.eval.EvalMain.addModules(ectx, ctx.modules);
				hxc.eval.EvalMain.runMain(ectx, path);
			} else {
				Sys.println("Loaded " + Context.sTypePath(path) + " (" + m.types.length + " types) for " + Globals.platformName(platform));
			}
		} catch (e:Dynamic) {
			Sys.stderr().writeString("Error: " + Std.string(e) + "
");
			Sys.exit(1);
		}
	}

	static function parseTypePath(s:String):Path {
		var parts = s.split(".");
		var name = parts.pop();
		return {pack: parts, name: name};
	}
}
