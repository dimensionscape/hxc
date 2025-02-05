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

		var m:Manifest = {
			profile: profile,
			requires: requires == null ? [] : requires.split(","),
			formatVersion: 1,
			abiLevel: 430
		};
		var sdkHash = opt(args, "--sdk-hash");
		if (sdkHash != null)
			m.sdkSurfaceHash = sdkHash;

		// The manifest travels inside the artifact, as the RESOURCES entry hxia.Runtime reads at load: a
		// capability request that can be separated from what it describes is not a contract. Written to a
		// temp file first because --resource takes a path.
		var mtext = ManifestIo.serialize(m);
		var mfile = out + ".manifest";
		sys.io.File.saveContent(mfile, mtext);

		var cmd = ["-main", main, "-cppia", out, "--hxia", profile];
		for (cp in cps) { cmd.push("-cp"); cmd.push(cp); }
		if (requires != null) { cmd.push("--require"); cmd.push(requires); }
		cmd.push("--resource");
		cmd.push(mfile + "@hxia.manifest");
		var rc = run(hxcBin(), cmd);
		if (rc != 0)
			return rc;

		// The side file stays for tooling that inspects without loading (and for `hxia
		// inspect` on a host with no runtime), but the embedded copy is the authoritative one.
		Sys.println("built " + out + " (manifest embedded, + .manifest for tooling)");
		return 0;
	}

	static function inspect(args:Array<String>):Int {
		var file = args[0];
		if (file == null) {
			Sys.println("hxia inspect: expected an artifact path");
			return 1;
		}
		// The EMBEDDED manifest is authoritative; the side file is only a fallback for an
		// artifact built before it travelled inside (or by a plain haxe -cppia).
		var m = embeddedManifest(file);
		var from = "embedded";
		if (m == null) {
			var mf = file + ".manifest";
			if (!sys.FileSystem.exists(mf)) {
				Sys.println("no manifest for " + file);
				return 1;
			}
			m = ManifestIo.parse(sys.io.File.getContent(mf));
			from = mf;
		}
		Sys.println("artifact: " + file);
		Sys.println("manifest: " + from);
		Sys.println("profile:  " + m.profile);
		Sys.println("requires: " + (m.requires.length == 0 ? "(none)" : m.requires.join(", ")));
		Sys.println("abi:      " + m.abiLevel);
		if (m.sdkSurfaceHash != null)
			Sys.println("sdk:      " + m.sdkSurfaceHash);
		return 0;
	}

	static function embeddedManifest(file:String):Null<Manifest> {
		try {
			var ir = hxia.cppia.Loader.parse(sys.io.File.getBytes(file));
			var tree = hxia.cppia.Decoder.decode(ir);
			var names = [for (b in ir.strings) b.getString(0, b.length)];
			for (res in tree.resources)
				if (names[res.nameId] == "hxia.manifest")
					return ManifestIo.parse(res.data.getString(0, res.data.length));
		} catch (_:Dynamic) {}
		return null;
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
