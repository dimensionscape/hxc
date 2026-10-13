import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
	The `haxelib run hxc` entry point.

	haxelib runs this with `haxe --run Run` from the library's folder, sets
	`HAXELIB_RUN=1`, and appends the caller's working directory as the last
	argument. hxc itself is a native binary, so this script finds the one for
	this platform (downloading it from the GitHub release on first use) and runs
	it in the caller's directory with the caller's arguments.

		haxelib run hxc build.hxml     compile, exactly as `haxe build.hxml`
		haxelib run hxc setup          download the binary now and print where it is
**/
class Run {
	static inline var REPO = "dimensionscape/hxc";

	static function main() {
		var args = Sys.args();
		var libDir = Path.addTrailingSlash(Sys.getCwd());
		if (Sys.getEnv("HAXELIB_RUN") == "1" && args.length > 0)
			Sys.setCwd(args.pop());

		var version:String = haxe.Json.parse(File.getContent(libDir + "haxelib.json")).version;
		var asset = assetName();
		if (asset == null)
			fail('there is no prebuilt hxc for ${Sys.systemName()} ${arch()} yet. Build it from source: https://github.com/$REPO#building');
		var bin = Path.normalize(libDir + "bin/" + asset);

		if (args[0] == "setup") {
			install(bin, asset, version);
			Sys.println('hxc $version is ready: $bin');
			return;
		}
		if (!FileSystem.exists(bin))
			install(bin, asset, version);

		useHaxeStd();
		// The child is a compiler, not a haxelib script: do not let it look like one.
		Sys.putEnv("HAXELIB_RUN", "");
		Sys.putEnv("HAXELIB_RUN_NAME", "");
		Sys.exit(Sys.command(bin, args));
	}

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
		} else {
			try {
				var p = new Process("uname", ["-m"]);
				var out = StringTools.trim(p.stdout.readAll().toString());
				p.close();
				out;
			} catch (_:Dynamic) null;
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
			fail('could not download $url\nDownload it yourself and save it as $bin');
		}
		FileSystem.rename(part, bin);
		if (Sys.systemName() != "Windows")
			Sys.command("chmod", ["+x", bin]);
	}

	/**
		hxc compiles against the Haxe standard library rather than shipping its own.
		Unless the caller already chose one, use the std of the haxe that is running
		this script, which haxelib guarantees is installed.
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
