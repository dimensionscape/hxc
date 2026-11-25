# Debugger sample for the .NET PDB

A small program (`src/sample/Main.hx`, `src/sample/Shapes.hx`) to step through in VS Code and Visual
Studio. It has a loop that calls an instance method in the other file, a local in an inner block, a
closure that captures a local, a `try`/`catch`, a `trace` and a call into hxc's runtime
(`Reflect.field`).

Build it from this folder (set `HAXE_STD_PATH` if hxc does not find the standard library):

```bash
hxc build.hxml
dotnet out/out.dll
```

That writes `out/out.dll`, `out/out.pdb` and `out/out.runtimeconfig.json` (hxc names the assembly after the
output folder). The build uses `-debug -D dotnet-debug-jit`. It also passes `--haxelib-global`, because
this folder sits inside hxc's checkout, whose `.haxelib` would hide the globally installed hxcs; a project
outside the checkout does not need that flag.

Open this folder in VS Code and start "Debug the sample (.NET)" (`.vscode/launch.json`). The steps to
follow, for VS Code and for Visual Studio, are in
`docs/superpowers/plans/2026-10-29-dotnet-portable-pdb/debugger-checklist.md`.
