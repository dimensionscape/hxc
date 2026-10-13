import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
	The `haxelib run hxc` entry point.

	haxelib runs this with `haxe --run Run` from the library's folder, sets `HAXELIB_RUN=1`, and
	appends the caller's working directory as the last argument.

		haxelib run hxc build.hxml     compile, exactly as `haxe build.hxml`
		haxelib run hxc setup          download the release binary for this platform
		haxelib run hxc rebuild        build hxc from this library's source

	A binary built with `rebuild` is used in preference to the downloaded one.
**/
class Run {
	static inline var REPO = "dimensionscape/hxc";
	static inline var HXCPP_REPO = "dimensionscape/hxcpp";
	static inline var AEDIFEX_INSTALL = "haxelib install aedifex 1.0.0-rc.3";

	static function main() {
		var args = Sys.args();
		var libDir = Path.addTrailingSlash(Sys.getCwd());
		if (Sys.getEnv("HAXELIB_RUN") == "1" && args.length > 0)
			Sys.setCwd(args.pop());

		var version:String = haxe.Json.parse(File.getContent(libDir + "haxelib.json")).version;
		var built = Path.normalize(libDir + "bin/" + (Sys.systemName() == "Windows" ? "hxc.exe" : "hxc"));
		var asset = assetName();
		var downloaded = asset != null ? Path.normalize(libDir + "bin/" + asset) : null;

		switch (args[0]) {
			case "setup":
				if (downloaded == null) fail(noPrebuilt());
				install(downloaded, asset, version);
				Sys.println('hxc $version is ready: $downloaded');
				return;
			case "rebuild":
				rebuild(libDir, built);
				Sys.println('hxc $version is built: $built');
				return;
			case _:
		}

		var bin = if (FileSystem.exists(built)) {
			built;
		} else {
			if (downloaded == null) fail(noPrebuilt());
			install(downloaded, asset, version);
			downloaded;
		}
		useHaxeStd();
		// The child is a compiler, not a haxelib script: do not let it look like one.
		Sys.putEnv("HAXELIB_RUN", "");
		Sys.putEnv("HAXELIB_RUN_NAME", "");
		Sys.exit(Sys.command(bin, args));
	}

	static function noPrebuilt():String
		return 'there is no prebuilt hxc for ${Sys.systemName()} ${arch()}. Build one with `haxelib run hxc rebuild`.';

	/** `hxc-<os>-<arch>[.exe]`, the name of the release asset for this machine. **/
	static function assetName():Null<String> {
		var os = switch (Sys.systemName()) {
			case "Windows": "windows";
			case "Linux": "linux";
			case "Mac": "macos";
			case _: return null;
		}
		var a = arch();
		if (a == null) return null;
		return 'hxc-$os-$a' + (os == "windows" ? ".exe" : "");
	}

	static function arch():Null<String> {
		var raw = if (Sys.systemName() == "Windows") {
			var w = Sys.getEnv("PROCESSOR_ARCHITEW6432");
			w != null ? w : Sys.getEnv("PROCESSOR_ARCHITECTURE");
		} else if (Sys.systemName() == "Mac" && output("sysctl", ["-n", "hw.optional.arm64"]) == "1") {
			// Apple silicon, also when Neko runs under Rosetta and uname reports x86_64.
			"arm64";
		} else {
			output("uname", ["-m"]);
		}
		return switch (raw == null ? "" : raw.toLowerCase()) {
			case "amd64" | "x86_64": "x64";
			case "arm64" | "aarch64": "arm64";
			case _: null;
		}
	}

	/** Downloads the release binary for `version` next to this script. **/
	static function install(bin:String, asset:String, version:String) {
		if (FileSystem.exists(bin)) return;
		FileSystem.createDirectory(Path.directory(bin));
		var url = 'https://github.com/$REPO/releases/download/$version/$asset';
		var part = bin + ".part";
		Sys.println('Downloading hxc $version for this platform...');
		// curl ships with Windows 10 and later, macOS and practically every Linux, and follows
		// GitHub's redirect to its download host.
		if (Sys.command("curl", ["-fL", "--retry", "2", "--progress-bar", "-o", part, url]) != 0) {
			if (FileSystem.exists(part)) FileSystem.deleteFile(part);
			fail('could not download $url\nDownload it yourself and save it as $bin, or build hxc with `haxelib run hxc rebuild`.');
		}
		FileSystem.rename(part, bin);
		if (Sys.systemName() != "Windows")
			Sys.command("chmod", ["+x", bin]);
	}

	/** Builds hxc from this library's own source, with hxcpp and Aedifex. **/
	static function rebuild(libDir:String, target:String) {
		var hxcpp = libPath("hxcpp");
		var useFork = 'haxelib git hxcpp https://github.com/$HXCPP_REPO.git production';
		if (hxcpp == null || !FileSystem.exists(hxcpp + "project/thirdparty/mbedtls-flags.xml"))
			fail('building hxc needs hxcpp from https://github.com/$HXCPP_REPO/tree/production:\n  $useFork');
		var origin = try File.getContent(hxcpp + ".git/config") catch (_:Dynamic) "";
		if (origin.indexOf(HXCPP_REPO) < 0)
			Sys.stderr().writeString('Warning: the hxcpp in $hxcpp is not from $HXCPP_REPO. Builds may fail, '
				+ 'and large compiles can stall on its garbage collector. To use the fork:\n  $useFork\n');
		if (!FileSystem.exists(hxcpp + "hxcpp.n")) {
			Sys.println("Building the hxcpp command-line tool...");
			Sys.setCwd(hxcpp + "tools/hxcpp");
			if (Sys.command("haxe", ["compile.hxml"]) != 0) fail("could not build the hxcpp command-line tool");
		}
		var aedifex = libPath("aedifex");
		var aedifexVersion = aedifex == null ? null : try haxe.Json.parse(File.getContent(aedifex + "haxelib.json")).version catch (_:Dynamic) null;
		if (aedifexVersion == null || StringTools.startsWith(aedifexVersion, "0."))
			fail("building hxc needs Aedifex 1.0 or later:\n  " + AEDIFEX_INSTALL);

		Sys.setCwd(libDir);
		if (Sys.command("haxelib", ["run", "aedifex", "build", "cpp", "."]) != 0)
			fail("the build failed");
		var exe = findExecutable(libDir + "bin/cpp");
		if (exe == null) fail('the build did not produce an executable under ${libDir}bin/cpp');
		File.copy(exe, target);
		if (Sys.systemName() != "Windows")
			Sys.command("chmod", ["+x", target]);
	}

	static function findExecutable(dir:String):Null<String> {
		if (!FileSystem.exists(dir)) return null;
		for (entry in FileSystem.readDirectory(dir)) {
			var p = Path.join([dir, entry]);
			if (FileSystem.isDirectory(p)) {
				var found = findExecutable(p);
				if (found != null) return found;
			} else if ((entry == "hxc" || entry == "hxc.exe") && Path.withoutDirectory(dir) == "bin"
					&& dir.indexOf("/release/") >= 0) {
				return p;
			}
		}
		return null;
	}

	/** The folder of an installed library, with a trailing slash, or null. **/
	static function libPath(name:String):Null<String> {
		var p = output("haxelib", ["libpath", name]);
		return p != null && p != "" && FileSystem.exists(p) ? Path.addTrailingSlash(p) : null;
	}

	static function output(cmd:String, args:Array<String>):Null<String> {
		return try {
			var p = new Process(cmd, args);
			var out = StringTools.trim(p.stdout.readAll().toString());
			var code = p.exitCode();
			p.close();
			code == 0 ? out : null;
		} catch (_:Dynamic) null;
	}

	/**
		hxc compiles against the Haxe standard library rather than shipping its own. Unless the
		caller already chose one, use the std of the haxe that is running this script, which haxelib
		guarantees is installed.
	**/
	static function useHaxeStd() {
		var current = Sys.getEnv("HAXE_STD_PATH");
		if (current != null && current != "") return;
		var std = haxeStdPath();
		if (std == null) return;
		if (!StringTools.startsWith(haxeVersion(), "4.3"))
			Sys.stderr().writeString('Warning: hxc implements Haxe 4.3, but the installed haxe is ${haxeVersion()}. '
				+ 'If compiles fail in the standard library, set HAXE_STD_PATH to a Haxe 4.3 std.\n');
		Sys.putEnv("HAXE_STD_PATH", std);
	}

	/** The std directory of the haxe compiling this script, captured at compile time. **/
	static macro function haxeStdPath():haxe.macro.Expr {
		for (cp in haxe.macro.Context.getClassPath())
			if (cp != "" && sys.FileSystem.exists(haxe.io.Path.join([cp, "StdTypes.hx"])))
				return macro $v{cp};
		return macro null;
	}

	static macro function haxeVersion():haxe.macro.Expr
		return macro $v{haxe.macro.Context.definedValue("haxe")};

	static function fail(message:String):Dynamic {
		Sys.stderr().writeString('hxc: $message\n');
		Sys.exit(1);
		return null;
	}
}
