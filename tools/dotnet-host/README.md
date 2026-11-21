# hxc as a .NET program

hxc is written in Haxe, and its `--dotnet` target can compile it. This folder builds the compiler that
way: the same sources as the native executable, running on the .NET runtime instead of on hxcpp.

It is an alternative way to run hxc on Windows, not a replacement for the native build. On the large
projects it was measured on it compiles faster than the native executable and uses about 40% less memory;
on a small project it is slower to start by a few tenths of a second.

## Building it

Windows only. You need:

- a built native hxc, or an earlier result of this script;
- the .NET 10 SDK;
- Visual Studio's C++ tools, to compile PCRE2 and zlib once and to give the launcher a large stack;
- an hxcpp checkout, for the PCRE2 and zlib sources (`haxelib libpath hxcpp`, or set `HXCPP`);
- `HAXE_STD_PATH` set to the Haxe 4.3.7 standard library.

```sh
tools/dotnet-host/build.sh bin/hxc-windows-x64.exe bin/dotnet-host
```

The output folder then holds `hxc.exe`, `hxc.dll`, `hxc.runtimeconfig.json`, `HxcHostNative.dll`,
`pcre2-8.dll` and `hxczlib.dll`. Keep the six together; `hxc.exe` takes the same arguments as the native
compiler and needs the .NET 10 runtime installed. The two native libraries are PCRE2 and zlib built from
the sources hxcpp links into the native compiler, so regular expressions and compression in macros give
the same results on either. The first build takes about a minute, later ones about half that.

The compiler is as current as the sources it was built from: rebuild it when hxc changes.

## Using it through haxelib

`haxelib run hxc` runs `bin/hxc.exe` when there is one, and the native `bin/hxc-windows-x64.exe`
otherwise. To make it run this compiler, or to refresh it after hxc changes:

```sh
tools/dotnet-host/update-bin.sh
```

It builds with whichever of `bin/`'s two compilers is newer, in a folder outside the repository
(`%LOCALAPPDATA%\hxc\dotnet-host`, or `HXC_DOTNET_HOST_WORK`), and puts the six files in `bin/`. A compile
running at the time keeps the files it has open. After a change to the .NET generator itself, add
`--bootstrap`: the first build only runs the new generator, so it builds again with its own result and checks
the two are identical. Deleting `bin/hxc.exe` goes back to the native compiler, and `haxelib run hxc rebuild`
replaces it with a native one.

## What it is checked against

The result of this script building itself is byte-identical whichever compiler ran the build, native or
hosted, and CI checks that. CI also runs hxc's own cases and the conformance suite through it. Output for
the projects it was tried on (HashLink, .NET and JavaScript builds) is the same file the native compiler
writes.

## What does not work

- `eval.luv` in macros beyond the event loop, timers and async handles: no TCP, UDP, pipes, processes,
  file-system requests, signals or libuv threads.
- SSL sockets in macros (`sys.ssl`).

A macro that uses one of these fails with an error. The conformance cases they fail are listed in
`tests/divergences-dotnet-host.json`, which the CI job passes to the conformance run. Nothing else is
known to differ.

## How it differs inside

- `hxc.runtimeconfig.json` turns on the server garbage collector and turns off dynamic PGO; without them
  a large build takes about twice as long.
- The assembly is precompiled (ReadyToRun), so a small build does not wait for the JIT.
- The standard library's C# `StringMap` hashes strings with a per-process seed, so the build swaps in a
  copy that hashes them the same way in every run.
- `HXC_THREADS` and the other `HXC_` variables work as in the native compiler. The hxcpp ones
  (`HXCPP_...`) have no effect.
