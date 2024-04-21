package hxia.cli;

import hxia.Manifest;
import hxia.ManifestIo;

// The `hxia` command-line tool: a thin wrapper over hxc and the hxia macros so authors and hosts
// never assemble compiler flags by hand.
//
// hxia build --main <M> -o <out.cppia> [--cp <dir>]... [--profile core|sys] [--require a,b]
// hxia inspect <out.cppia> requirements census from the manifest sidecar
// hxia sdk --host-main <M> --out <dir> [--cp <dir>]... emit the typed host SDK
//
// This is the skeleton: build shells out to hxc (-cppia + --hxia + --require) and writes the
// manifest beside the artifact; embedding the manifest as a RESOURCES entry is the later
// neutral-emitter slice.
class Main {
	static var hxc = Sys.getEnv("HXIA_HXC");
	static var haxe = Sys.getEnv("HXIA_HAXE");

	static function main() {
		Sys.exit(dispatch(Sys.args()));
	}

	static function dispatch(args:Array<String>):Int {
		if (args.length == 0)
			return usage();
		var cmd = args.shift();
		return switch (cmd) {
			case "build": build(args);
			case "inspect": inspect(args);
			case "sdk": sdk(args);
			case _: usage();
		};
	}

	static function usage():Int {
		Sys.println("usage: hxia build|inspect|sdk ...");
		return 1;
	}

	static function opt(args:Array<String>, name:String):Null<String> {
		var i = args.indexOf(name);
		return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
	}

	static function multi(args:Array<String>, name:String):Array<String> {
		var out = [];
		var i = 0;
		while (i < args.length) {
			if (args[i] == name && i + 1 < args.length)
				out.push(args[i + 1]);
			i++;
		}
		return out;
	}

	static function build(args:Array<String>):Int {
		var main = opt(args, "--main");
		var out = opt(args, "-o");
		if (main == null || out == null) {
			Sys.println("hxia build: --main and -o are required");
			return 1;
		}
		var profile = opt(args, "--profile");
		if (profile == null)
			profile = "core";
		var requires = opt(args, "--require");
		var cps = multi(args, "--cp");

		var cmd = ["-main", main, "-cppia", out, "--hxia", profile];
		for (cp in cps) { cmd.push("-cp"); cmd.push(cp); }
		if (requires != null) { cmd.push("--require"); cmd.push(requires); }
		var rc = run(hxcBin(), cmd);
		if (rc != 0)
			return rc;

		var m:Manifest = {
			profile: profile,
			requires: requires == null ? [] : requires.split(","),
			formatVersion: 1,
			abiLevel: 430
		};
		sys.io.File.saveContent(out + ".manifest", ManifestIo.serialize(m));
		Sys.println("built " + out + " (+ .manifest)");
		return 0;
	}

	static function inspect(args:Array<String>):Int {
		var file = args[0];
		if (file == null) {
			Sys.println("hxia inspect: expected an artifact path");
			return 1;
		}
		var mf = file + ".manifest";
		if (!sys.FileSystem.exists(mf)) {
			Sys.println("no manifest for " + file);
			return 1;
		}
		var m = ManifestIo.parse(sys.io.File.getContent(mf));
		Sys.println("artifact: " + file);
		Sys.println("profile:  " + m.profile);
		Sys.println("requires: " + (m.requires.length == 0 ? "(none)" : m.requires.join(", ")));
		Sys.println("abi:      " + m.abiLevel);
		return 0;
	}

	static function sdk(args:Array<String>):Int {
		var hostMain = opt(args, "--host-main");
		var out = opt(args, "--out");
		if (hostMain == null || out == null) {
			Sys.println("hxia sdk: --host-main and --out are required");
			return 1;
		}
		var cps = multi(args, "--cp");
		var cmd = ["-main", hostMain, "--interp", "--macro", "hxia.macro.Sdk.emit('" + out + "')"];
		for (cp in cps) { cmd.push("-cp"); cmd.push(cp); }
		var rc = run(haxeBin(), cmd);
		if (rc == 0)
			Sys.println("emitted SDK to " + out);
		return rc;
	}

	static function hxcBin():String
		return hxc != null ? hxc : "haxe";

	static function haxeBin():String
		return haxe != null ? haxe : "haxe";

	static function run(bin:String, args:Array<String>):Int
		return Sys.command(bin, args);
}
