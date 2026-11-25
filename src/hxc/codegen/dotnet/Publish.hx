package hxc.codegen.dotnet;

import sys.FileSystem;
import hxc.ast.Position;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.context.Context;

// -D dotnet-aot, -D dotnet-r2r and -D dotnet-exe: after the assembly is written and the after-generate callbacks
// have run, publishes it with the .NET SDK. The project has no C# of its own: the written assembly stands in for the
// compiler's output. -D dotnet-aot leaves a native program beside the assembly, which starts at hxc's entry
// point, with its arguments and its STAThread. -D dotnet-r2r puts the assembly back in place with ReadyToRun code
// beside its IL, so it runs and is referenced as before. -D dotnet-exe leaves a program beside the assembly that
// starts at the same entry point: a launcher, or one self-contained file.
class Publish {
	public static function check(ctx:Context, g:DotnetCtx, isDll:Bool):Void {
		if (ctx.defines.rawDefined("dotnet_r2r")) {
			if (ctx.defines.rawDefined("dotnet_aot"))
				g.error("-D dotnet-r2r and -D dotnet-aot can't be used together: a native program has no use for an assembly's ReadyToRun code", Position.nullPos);
			if (ctx.defines.rawDefined("dotnet_debug_jit"))
				g.error("-D dotnet-r2r and -D dotnet-debug-jit can't be used together: the precompiled code is optimized, which -D dotnet-debug-jit asks the JIT not to do", Position.nullPos);
		}
		if (ctx.defines.rawDefined("dotnet_exe")) {
			var kind = ctx.defines.rawDefinedValueSafe("dotnet_exe");
			if (kind != "launcher" && kind != "self-contained")
				g.error("-D dotnet-exe must be launcher or self-contained (not " + kind + ")", Position.nullPos);
			else if (ctx.defines.rawDefined("dotnet_aot"))
				g.error("-D dotnet-exe and -D dotnet-aot can't be used together: -D dotnet-aot's native program is already an executable", Position.nullPos);
			else if (isDll)
				g.error("-D dotnet-exe needs -main: a library has no entry point for a program to start at", Position.nullPos);
		}
		if (!ctx.defines.rawDefined("dotnet_aot")) return;
		if (isDll) g.error("-D dotnet-aot needs -main: a library has no entry point to start a native program at", Position.nullPos);
		var descriptor = descriptorOf(ctx);
		if (descriptor != null && !FileSystem.exists(descriptor))
			g.error("-D dotnet-aot-descriptor: " + descriptor + " was not found", Position.nullPos);
	}

	static function descriptorOf(ctx:Context):Null<String> {
		return ctx.defines.rawDefined("dotnet_aot_descriptor") ? ctx.defines.rawDefinedValueSafe("dotnet_aot_descriptor") : null;
	}

	public static function wanted(ctx:Context):Bool {
		return ctx.defines.rawDefined("dotnet_aot") || ctx.defines.rawDefined("dotnet_r2r") || ctx.defines.rawDefined("dotnet_exe");
	}

	// -D dotnet-exe comes after -D dotnet-r2r, so its program starts or holds the precompiled assembly.
	public static function publish(ctx:Context):Void {
		var dir = GenerateDotnet.outputDir(ctx);
		var name = GenerateDotnet.assemblyName(ctx, dir), version = NetSetup.dotnetVersion(ctx);
		if (ctx.defines.rawDefined("dotnet_aot")) {
			publishProject(ctx, dir, "aot", "-D dotnet-aot", aotProject(ctx, name, version));
			return;
		}
		if (ctx.defines.rawDefined("dotnet_r2r") && !publishProject(ctx, dir, "r2r", "-D dotnet-r2r", r2rProject(ctx, name, version))) return;
		if (ctx.defines.rawDefined("dotnet_exe")) {
			var kind = ctx.defines.rawDefinedValueSafe("dotnet_exe");
			publishProject(ctx, dir, "exe", "-D dotnet-exe=" + kind, exeProject(ctx, name, version, kind == "self-contained"));
		}
	}

	// Writes the project to <dir>/<kind> and publishes it, false if that fails.
	static function publishProject(ctx:Context, dir:String, kind:String, define:String, content:String):Bool {
		var project = FileSystem.fullPath(dir + "/" + kind);
		FileSystem.createDirectory(project);
		var file = project + "/" + kind + ".csproj";
		sys.io.File.saveContent(file, content);
		var log = project + "/publish.log";
		var result = run(["publish", file, "-c", "Release", "-nologo", "-v:q", "-nodeReuse:false"]);
		if (result == null) {
			ctx.addDiagnostic("dotnet: " + define + " needs the .NET SDK, and `dotnet` could not be started", Position.nullPos);
			return false;
		}
		sys.io.File.saveContent(log, result.output);
		if (result.code != 0) {
			ctx.addDiagnostic("dotnet: " + define + ": the publish failed (the whole report is in " + log + ")\n" + errorLines(result.output), Position.nullPos);
			return false;
		}
		return true;
	}

	static function programName(name:String):String {
		return name + (Sys.systemName() == "Windows" ? ".exe" : "");
	}

	// -D dotnet-winexe: a GUI program on Windows, which opens no console window. Elsewhere the SDK ignores it.
	static function outputType(ctx:Context):String {
		return '    <OutputType>' + (ctx.defines.rawDefined("dotnet_winexe") ? "WinExe" : "Exe") + '</OutputType>';
	}

	// The assembly is rooted, as the runtime's reflection reaches its members by name, which the compiler can't see.
	static function aotProject(ctx:Context, name:String, version:Int):String {
		var items = ['    <TrimmerRootAssembly Include="' + escape(name) + '" />'];
		var descriptor = descriptorOf(ctx);
		if (descriptor != null) items.push('    <TrimmerRootDescriptor Include="' + escape(FileSystem.fullPath(descriptor)) + '" />');
		return projectFile(ctx, name, version, [outputType(ctx), '    <PublishAot>true</PublishAot>'], items, programName(name));
	}

	// For the machine's own OS and CPU. A launcher starts the assembly beside it on the installed .NET, by hxc's
	// runtimeconfig, so the publish writes none, nor a deps file. A self-contained program is one file that holds the
	// assembly, the --net-lib assemblies, their native libraries and the runtime, with the runtimeconfig and deps file
	// the publish writes for it; the native libraries are unpacked to a folder of the user's the first time it runs.
	static function exeProject(ctx:Context, name:String, version:Int, selfContained:Bool):String {
		var properties = [outputType(ctx), "    <RuntimeIdentifier>$(NETCoreSdkPortableRuntimeIdentifier)</RuntimeIdentifier>"];
		properties = properties.concat(selfContained ? [
			'    <SelfContained>true</SelfContained>',
			'    <PublishSingleFile>true</PublishSingleFile>',
			'    <IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>'
		] : [
			'    <SelfContained>false</SelfContained>',
			'    <UseAppHost>true</UseAppHost>',
			'    <GenerateDependencyFile>false</GenerateDependencyFile>',
			'    <GenerateRuntimeConfigurationFiles>false</GenerateRuntimeConfigurationFiles>'
		]);
		return projectFile(ctx, name, version, properties, [], programName(name), selfContained ? nativeLibraries(ctx) : []);
	}

	// A --net-lib assembly's native libraries, where a dotnet build leaves a NuGet package's: runtimes/<rid>/native
	// beside it for the machine's own OS and CPU, and runtimes/<os>/native for the rest (win for win-x64, linux-musl
	// for linux-musl-x64). Nothing tells the program to look there, so they go in the publish, as the SDK's own are.
	static function nativeLibraries(ctx:Context):Array<String> {
		var dirs = [];
		for (lib in ctx.netLibs) {
			if (lib.isStd) continue;
			var dir = haxe.io.Path.directory(FileSystem.fullPath(lib.filePath));
			if (dirs.indexOf(dir) < 0) dirs.push(dir);
		}
		if (dirs.length == 0) return [];
		function globs(item:String, rid:String):String {
			var files = [for (dir in dirs) for (ext in ["dll", "so", "dylib"]) escape(dir) + "/runtimes/" + rid + "/native/*." + ext];
			return '      <' + item + ' Include="' + files.join(";") + '" />';
		}
		return [
			'  <Target Name="NativeLibraries" AfterTargets="ComputeResolvedFilesToPublishList">',
			'    <PropertyGroup>',
			"      <NativeOs>$(RuntimeIdentifier.Substring(0, $(RuntimeIdentifier.LastIndexOf('-'))))</NativeOs>",
			'    </PropertyGroup>',
			'    <ItemGroup>',
			globs("NativeRid", "$(RuntimeIdentifier)"),
			globs("NativeOs", "$(NativeOs)"),
			"      <NativeOs Remove=\"@(NativeOs)\" Condition=\"Exists('%(RootDir)%(Directory)../../$(RuntimeIdentifier)/native/%(Filename)%(Extension)')\" />",
			'      <ResolvedFileToPublish Include="@(NativeRid)" RelativePath="%(Filename)%(Extension)" AssetType="native" CopyToPublishDirectory="PreserveNewest" />',
			'      <ResolvedFileToPublish Include="@(NativeOs)" RelativePath="%(Filename)%(Extension)" AssetType="native" CopyToPublishDirectory="PreserveNewest" />',
			'    </ItemGroup>',
			'  </Target>'
		];
	}

	// Framework-dependent, for the machine's own OS and CPU: elsewhere the runtime ignores the ReadyToRun code and
	// runs the IL. hxc writes the runtimeconfig, so the publish writes none, nor a deps file.
	static function r2rProject(ctx:Context, name:String, version:Int):String {
		return projectFile(ctx, name, version, [
			"    <RuntimeIdentifier>$(NETCoreSdkPortableRuntimeIdentifier)</RuntimeIdentifier>",
			'    <SelfContained>false</SelfContained>',
			'    <PublishReadyToRun>true</PublishReadyToRun>',
			'    <GenerateDependencyFile>false</GenerateDependencyFile>',
			'    <GenerateRuntimeConfigurationFiles>false</GenerateRuntimeConfigurationFiles>'
		], [], name + ".dll");
	}

	// Joined with "\n" so the file is the same whatever line endings this source was checked out with. The
	// --net-lib assemblies are references; `published` is copied from the publish back to the output directory. The
	// assembly copied into place is touched, so a target that skips work its inputs are older than (the executable's
	// host, which -D dotnet-winexe changes) runs again when only the project has changed.
	static function projectFile(ctx:Context, name:String, version:Int, properties:Array<String>, items:Array<String>, published:String,
			?targets:Array<String>):String {
		items = items.copy();
		for (lib in ctx.netLibs) {
			if (lib.isStd) continue;
			var file = FileSystem.fullPath(lib.filePath);
			var simple = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file));
			items.push('    <Reference Include="' + escape(simple) + '"><HintPath>' + escape(file) + '</HintPath></Reference>');
		}
		var lines = ['<Project>', '  <Import Project="Sdk.props" Sdk="Microsoft.NET.Sdk" />', '  <PropertyGroup>'].concat(properties).concat([
			'    <TargetFramework>net' + version + '.0</TargetFramework>',
			'    <AssemblyName>' + escape(name) + '</AssemblyName>',
			'    <PublishDir>publish/</PublishDir>',
			'    <ProduceReferenceAssembly>false</ProduceReferenceAssembly>',
			'    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>',
			'    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>',
			'    <SatelliteResourceLanguages>en</SatelliteResourceLanguages>',
			'  </PropertyGroup>'
		]);
		if (items.length > 0) lines = lines.concat(['  <ItemGroup>', items.join("\n"), '  </ItemGroup>']);
		return lines.concat(['  <Import Project="Sdk.targets" Sdk="Microsoft.NET.Sdk" />']).concat(targets == null ? [] : targets).concat([
			'  <Target Name="CoreCompile">',
			'    <Copy SourceFiles="../' + escape(name) + '.dll" DestinationFiles="@(IntermediateAssembly)" />',
			'    <Touch Files="@(IntermediateAssembly)" />',
			'  </Target>',
			'  <Target Name="CopyPublished" AfterTargets="Publish">',
			'    <Copy SourceFiles="publish/' + escape(published) + '" DestinationFolder=".." />',
			'  </Target>',
			'</Project>',
			''
		]).join("\n");
	}

	// A name or path as MSBuild reads it literally, inside an XML attribute or element.
	static function escape(s:String):String {
		for (c in ["%", "$", "@", ";", "?", "*", "'"])
			s = s.split(c).join("%" + StringTools.hex(c.charCodeAt(0), 2));
		return StringTools.htmlEscape(s, true);
	}

	// Runs dotnet to its end, null if it can't start. MSBuild reports on stdout, so stderr is read second. On
	// Windows the SDK's linker lookup calls vswhere by name, and a Visual Studio install leaves it off the PATH.
	static function run(args:Array<String>):Null<{code:Int, output:String}> {
		var path = Sys.getEnv("PATH");
		var programFiles = Sys.getEnv("ProgramFiles(x86)");
		var installer = programFiles == null ? null : programFiles + "\\Microsoft Visual Studio\\Installer";
		var addVsWhere = installer != null && FileSystem.exists(installer);
		if (addVsWhere) Sys.putEnv("PATH", installer + ";" + path);
		var result = try {
			var p = new sys.io.Process("dotnet", args);
			var output = p.stdout.readAll().toString() + p.stderr.readAll().toString();
			var code = p.exitCode();
			p.close();
			{code: code, output: output};
		} catch (_:Dynamic) null;
		if (addVsWhere) Sys.putEnv("PATH", path);
		return result;
	}

	// MSBuild's error lines, each once, or the whole report if it has none.
	static function errorLines(output:String):String {
		var lines = [];
		for (l in output.split("\n")) {
			var line = StringTools.trim(l);
			if (line.indexOf(": error ") >= 0 && lines.indexOf(line) < 0) lines.push(line);
		}
		return lines.length > 0 ? lines.join("\n") : StringTools.trim(output);
	}
}
