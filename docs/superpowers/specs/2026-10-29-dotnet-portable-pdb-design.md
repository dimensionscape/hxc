# .NET milestone 5, the Portable PDB: design

Date: 2026-10-29
Status: ready for review by the person driving this

This extends milestone 5 of `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md` (the
main spec), whose Debug info bullet (`How it gets made`) and milestone list stay binding. Where this
document is more specific, it wins; where it is silent, the main spec decides.

## Intent

hxc's `-D dotnet` backend writes a DLL and nothing else. This adds the Portable PDB beside it, so that
a released, optimized server app logs `.hx` file:line in its stack traces, and a development build
steps through `.hx` files in Visual Studio and VS Code.

### Why

A read-only look at the server app found:

- **It logs two kinds of trace.** About 60 catch sites log Haxe's (`e.details()`,
  `haxe.CallStack.callStack()`, `CallStack.exceptionStack()`, through `CSTools.log`); the AI jobs and the
  migrator log .NET's (`Exception.ToString()`, `InnerException.StackTrace`). On .NET, hxcs's `CallStack`
  is built from `System.Diagnostics.StackTrace`, so both get file and line from the same PDB.
- **The PDB already ships.** The Docker scripts `dotnet publish` (`-c Release` for release, `-c Debug`
  for others) and the deployed app folder holds `HaxeServer.pdb` beside `HaxeServer.dll`. hxc's PDB
  takes the same path with no script change.
- **Today's traces don't show `.hx`.** The server's gencs build passes `-debug` and `-D real-position`,
  which turns off gencs's `#line` mapping (no `#line` in any of its 1,467 C# files). So today a trace
  names generated C#, and stepping goes through generated C#. Nobody knows why `real-position` was
  added. hxc writes no C#, so its PDB can only name `.hx`; this changes what the logs and the debugger
  show, and that is the intent.

## What the person driving this decided

- **Released builds:** what they read is the stack trace in the log. **Development:** VS Code or VS.
- **`.hx` everywhere**, in both kinds of trace and in the debugger (accepted when told today's traces
  name C#).
- **Short paths in the PDB** (`src/db/Foo.hx`), not the build machine's full paths, accepting that the
  debugger needs a `sourceFileMap` (VS Code) or a source-folder setting (VS) to find files.
- **Full paths are acceptable in development builds** if Visual Studio won't bind breakpoints to short
  ones: then `-D dotnet-debug-jit` builds use full paths by default, and released (`-debug` only)
  builds keep short ones (see Paths).
- **They run the debugger checks by hand**, from a checklist the builder writes.
- **hxc's runtime source is embedded** in the PDB (see hxc's runtime files).

## Goals

- `-debug` writes `<out>/<AssemblyName>.pdb` beside the DLL: a Portable PDB (the format of
  `System.Reflection.Metadata`'s PortablePdb, version 1.0) that the .NET 10 runtime's stack traces, VS 2022+
  and VS Code's C# debugger (`coreclr`) load.
- The DLL's debug directory has a CodeView entry and a PdbChecksum entry (SHA-256), as Roslyn writes for
  a portable PDB.
- Exception stack traces from an optimized build name the `.hx` file and line of each Haxe frame, in
  `Exception.ToString()`/`StackTrace` and in `haxe.CallStack`/`haxe.Exception.details()` output.
- Under `-D dotnet-debug-jit`: breakpoints bind in `.hx` files, step in / over / out follow `.hx`
  lines, and the Locals window shows the method's Haxe variables by their Haxe names.
- Deterministic across machines: the same source tree built in two folders, on two machines, gives
  byte-identical DLL and PDB (see Paths).

## Non-goals

- Embedded source for the user's own files, and Source Link (main spec: optional; the repos are
  private). See My calls for hxc's runtime files.
- Hovering or watching a variable a closure captured, by its name in the source (needs Roslyn's
  hoisted-local naming, which the C# expression evaluator relies on). It stays reachable by expanding
  the closure object. A later milestone may add it.
- A Haxe expression evaluator. Watch and Immediate expressions are typed in the language the debugger
  uses for the method (see What the builder decides); Haxe syntax there is not a goal.
- Edit and Continue / Hot Reload (main spec non-goal).
- Windows PDB (`.pdb` in the MSF format), and a PDB embedded inside the DLL.
- Any change to the server app's repository (its `launch.json`, Docker scripts). The setup notes are
  documentation in hxc's repo, which the person driving this applies.

## Anti-goals

- A PDB that makes a trace name the wrong file or a line far from the code that threw. A line off by
  a statement inside an optimized method is the JIT's doing and acceptable; a frame naming a file
  that doesn't contain that method is a bug.
- A PDB or DLL that differs between two builds of the same source in two folders.
- A PDB that leaks the build machine's folders (`D:/...`, `C:/HaxeToolkit/...`, a user name) under the
  default settings.
- Breaking any current output: without `-debug`, the DLL stays byte-identical to today's; with
  `-debug` and without `-D dotnet-debug-jit`, the only DLL changes are the debug directory and what
  follows from it (MVID, timestamp, section sizes).
- A refusal or crash in the compiler because of debug info. A position hxc can't resolve gets a hidden
  sequence point, never an error.

## Constraints

- Everything in the main spec's Constraints: Haxe code inside hxc (no `System.Reflection.Metadata`),
  follow the JVM backend's shape (its `LineNumberTable` in `JvmCode.setLine`/`getLines` and
  `LocalVariableTable` in `JvmMethod`), deterministic, match the surrounding code.
- The never-commit rule for private app names applies to every test case, path and fixture: say
  "the server app".
- ILVerify stays clean; every existing case (607 in `tests/dotnet/run.sh` ALL, 129 in the own suite)
  keeps passing.

## How it gets made

### The files and flags (decided, main spec)

- `-debug` writes the PDB; without it there is no PDB and no debug directory, as with gencs.
- `-debug` does not turn off JIT optimization. `-D dotnet-debug-jit` adds
  `[assembly: System.Diagnostics.DebuggableAttribute(DebuggingModes.Default | DisableOptimizations |
  IgnoreSymbolStoreSequencePoints | EnableEditAndContinue)]`, minus EnableEditAndContinue *(my call:
  Edit and Continue is a non-goal, so the flag would promise something hxc can't do)*, i.e. the value
  `0x103`. `-D dotnet-debug-jit` without `-debug` is a compile error, since it has nothing to step
  through *(my call)*.
- Without `-D dotnet-debug-jit` there is no `DebuggableAttribute` (main spec), even under `-debug`,
  although Roslyn's Release build writes one with `IgnoreSymbolStoreSequencePoints`: that flag only
  concerns Windows PDBs, and leaving it out keeps the anti-goal below.
- The debug directory holds CodeView, PdbChecksum and an empty Reproducible entry, in that order, as
  Roslyn's deterministic build writes them *(my call)*.

### Paths (decided: short; the scheme is my call)

A Document row's name is the file's path with forward slashes, made short by the first rule that
fits:

1. A `-D dotnet-pathmap=<from>=<to>[,<from>=<to>...]` entry whose `<from>` prefixes the file's full
   path (case-insensitive on Windows, slashes normalized): replaced by `<to>`. The longest `<from>`
   wins. This is Roslyn's `-pathmap`, under a `-D` name *(name: my call)*.
2. A file under the compile's current folder: the path relative to it (`src/db/Foo.hx`).
3. A file under the Haxe std path (`HAXE_STD_PATH` or the std class path): `haxe-std/` plus the path
   under it (`haxe-std/haxe/Exception.hx`).
4. A file under a haxelib library's class path: `haxelib/<library>/` plus the path under that class
   path (`haxelib/thx.core/thx/Options.hx`). How hxc learns which class path came from which library
   (haxelib's `-cp` lines, its repository layout) is the builder's.
5. hxc's own runtime files (positions under `RuntimeSources.ROOT`, `<hxc-dotnet-runtime>/`):
   `hxc-runtime/` plus the path under it.
6. Anything else: the file's full path, unchanged, with a compiler warning once per file naming it and
   suggesting `-D dotnet-pathmap`. This is the only way a machine path reaches the PDB.

These names are the PDB's alone. The file names the DLL already holds (`haxe.PosInfos` strings from
`trace` and `?pos` arguments) keep Haxe's rule (`Calls.posInfosFile`) unchanged: it strips any class
path prefix, so std and haxelib files are already machine-free there (`thx/Options.hx`), and a file
under a relative class path keeps that relative path. `-D dotnet-pathmap` does not touch them. The
CodeView entry's path is the PDB's file name alone (`HaxeServer.pdb`) *(my call; Roslyn writes the
full output path unless pathmapped)*.

**The development fallback (decided).** The builder first checks, by the checklist below, whether VS
binds breakpoints in a short-path PDB with its source settings. If it does, short paths stay the
default everywhere. If it does not, `-D dotnet-debug-jit` switches the default to full paths (rule 2
becomes "the file's full path"; rules 3 to 5 likewise give full paths, except hxc's runtime files,
which have none), while `-D dotnet-pathmap` still applies. A `-debug`-only build always uses short
paths. The anti-goal on machine paths then holds for released builds only, and the result is
recorded in the spec.

hxc's README gains the debugger setup: a `sourceFileMap` example for VS Code's `launch.json`
(`"src/": "${workspaceFolder}/src/"`, `"haxe-std/": "C:/HaxeToolkit/haxe/std/"`, …) and the VS
equivalent (Debug Source Files / "Find source"). The builder confirms both work, by hand, and writes
down exactly what was needed.

### Documents

One Document row per source file that has at least one sequence point, ordered by first use
*(the builder may pick another deterministic order)*. Each has the SHA-256 of the file's bytes as read
by the compiler (hash algorithm GUID `8829d00f-11b8-4213-878b-770e8597ac16`), and a language GUID
(see What the builder decides).

### Sequence points (main spec: one per expression statement; the mapping is my call)

hxc's typed AST has no statements, so "statement" means:

- each expression in a function body's block, and in every nested block, that is not itself a block;
- a `var` declaration with a value (no point for one without);
- the condition of `if`, `while`, `do … while` (at the condition), and `switch`'s subject;
- `return`, `throw`, `break`, `continue`;
- the start of each `catch` (at the catch variable), and of each `case` body;
- a closure's body starts its own method, with its own points, by these same rules.

The position is the expression's own (`Position.getInfos`: start line/column to end line/column,
1-based columns as Portable PDB wants). Inlined code keeps whatever position the typer gave it: by
default the call site (Haxe's rule), and the inlined function's own file and lines under
`-D keep-inline-positions`, which means one method's points can name more than one Document (the
format allows it).

**Hidden** points (line `0xFEEFEE`) go where code runs that no Haxe line wrote and a step would land
on otherwise: after a branch target that starts generated code, at a `finally`'s compiler glue, at
the start of the IL that boxes, casts or adapts a value between statements. Methods hxc wholly
invents (enum constructors' plumbing, reflection tables, `__hx_` helpers, property accessors from
`@:property` with no body of the user's, the static constructor's generated parts, closure classes'
`Invoke` adapters) get no points at all, so the debugger steps over them and stack traces show no
file for them *(my call)*. A field initializer that the class's constructor runs keeps its own `.hx`
position.

Every point is placed so that an optimized build's stack trace resolves a throw to the line of the
statement containing it. The IL offset of a `throw` (or the call that throws) must fall at or after
its statement's point and before the next one.

### Local scopes and names (main spec; the visibility rule is my call)

- A LocalScope row per Haxe block that declares a variable, nested as the blocks are, covering the
  block's IL range. A method with no named local gets one scope for the method body only if it has
  any local at all *(builder may drop empty scopes)*.
- LocalVariable rows name IL locals that hold a `TVar` whose kind is `VUser`, `VInlined` or
  `VAbstractThis` (shown as `this`). `VGenerated`, `VInlinedConstructorVariable`,
  `VExtractorVariable` and every IL local hxc adds for itself (spills, `switch` subjects, `finally`
  state) are left out; with `-D dotnet-debug-jit` they still exist, unnamed.
- Parameters are named by the Param table already, so nothing more is needed for them.
- A variable captured by a closure lives in a field of the closure's class, not an IL local, so it
  gets no LocalVariable row (see Non-goals).

### hxc's runtime files (decided)

hxc's copy of the hxcs runtime is embedded in the hxc binary and exists on no disk, so a debugger can
never find `hxc-runtime/cs/internal/Runtime.hx`. Its Document rows get an EmbeddedSource custom
debug info entry with the file's text: uncompressed (format value 0), or deflated if hxc already has
a deflate encoder *(the builder's choice; uncompressed is fine)*. The user's files never do.

### Determinism (main spec: content-derived ids)

- The PDB id (20 bytes: a GUID and a stamp) is derived from a SHA-256 of the PDB with the id zeroed,
  as Roslyn's deterministic mode does.
- The CodeView entry carries that id and the PDB file name, the PdbChecksum entry the PDB's SHA-256.
  Both are in the DLL before `PeWriter` hashes the image for the MVID and timestamp, so the MVID
  depends on the PDB, as Roslyn's does.
- The order of everything written (Documents, sequence points, scopes, variables) comes from the
  program, never from a map's iteration order.

### Tests (my call; the builder adds cases as needed)

- **Stack traces** (`tests/dotnet/run.sh` cases): a thrown and caught exception, printed through
  `haxe.CallStack.exceptionStack()`, `haxe.Exception.details()` and `.NET`'s `ToString()`, from a
  build with `-debug` and no `dotnet-debug-jit` (optimized), with expected output naming the `.hx`
  file and line of the throw and of each Haxe caller. Cases cover: a throw in a nested block, in a
  closure, in an inlined function (both with and without `-D keep-inline-positions`), in a field
  initializer, in a `catch` that rethrows, and in a static initializer. The expected lines must not
  depend on inlining the JIT may do: where a caller frame matters, the callee is marked
  `MethodImplOptions.NoInlining` through `@:meta(System.Runtime.CompilerServices.MethodImpl(...))`
  *(the builder confirms hxc writes that attribute's flag into the MethodDef's ImplFlags, or finds
  another way)*.
- **The PDB's contents**, read back by a checker that does not trust hxc's writer: the builder picks
  between `dotnet` tooling in the harness (a small C# tool using `System.Reflection.Metadata` that dumps
  Documents, sequence points and scopes as text, compared to expected text) or a reader in hxc's own
  test code. `dotnet-pdb2xml`-style output is the model.
- **Determinism:** the same case built from two folders with different absolute paths gives
  byte-identical DLL and PDB (an addition to `tests/cases/determinism` or run.sh's second-compile
  check), and the default build of every case writes no machine path into the PDB (a scan for the
  test folder's absolute path in the bytes).
- **No regression:** without `-debug`, every case's DLL is byte-identical to the one hxc writes today.
- **Debugger, by hand** (not in CI: a debugger session can't run there): breakpoints, step in / over /
  out, Locals, Watch, and stepping into hxc's runtime, in VS Code and VS, on a small case and on the
  server app built with `-D dotnet-debug-jit`. The builder prepares the builds and the `launch.json`,
  and writes a step-by-step checklist (`docs/` beside the plan) with what to click and what should
  appear; the person driving this runs it and reports, and the builder records the results. The VS
  breakpoint-binding check comes first, since it decides the development fallback.
- **Server app trace:** the server app built with `-debug` (optimized), made to throw at a known line,
  logs the `.hx` file and line in both its Haxe and .NET trace output. The server app's checkout is
  read-only, so the throw goes into a copy of its source outside the checkout (as the 4c measurement
  did), never into the checkout *(my call)*.
- **Determinism across folders** moves the source tree only; the Haxe toolchain stays where it is
  *(my call: rules 3 and 4 make std and haxelib names location-free anyway, and the file hashes
  don't depend on location)*.

## What the builder decides

- The PDB writer's file layout inside `src/hxc/codegen/dotnet/` (new files beside `PeWriter.hx`, the
  shared heaps reused or not), and how sequence points are recorded during IL emission (the JVM
  backend's `setLine` model is the starting point).
- The Document language GUID. Write the one that makes VS and VS Code's Locals and Watch windows
  work for `.hx` files; if an unknown language GUID leaves them without an expression evaluator, use
  C#'s (`3f5162f8-07c6-11d3-9053-00c04fa302a1`) and record the finding in the spec. Either way,
  record which syntax Watch accepts.
- Exactly where hidden points go, guided by "a step never lands on code no Haxe line wrote".
- How the haxelib library name is found for path rule 4.
- Whether stack-trace expected output is checked against gencs (`[gencs]` sections): gencs without
  `real-position` writes `#line` to `.hx`, so it can be a reference for line numbers, with its paths
  differing.

## Exit (main spec, with this document's detail)

- Breakpoints and stepping in `.hx` files in VS and VS Code, built with `-D dotnet-debug-jit`, on a
  small case and on the server app, checked by the person driving this from the builder's checklist,
  and the results written down.
- `.hx` file:line in exception stack traces from an optimized (`-debug` only) build, by test and on
  the server app, in both kinds of trace it logs.
- ILVerify clean, all existing cases pass, determinism across folders holds, and without `-debug` the
  DLLs are unchanged.
- The main spec's Debug info bullet and milestone 5 entry updated to point here, and the README's
  debugger setup written.
