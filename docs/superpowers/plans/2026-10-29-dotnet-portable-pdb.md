# .NET milestone 5, the Portable PDB: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `-debug` makes hxc's `-D dotnet` backend write a Portable PDB beside the DLL, so traces from an optimized build name `.hx` lines, and `-D dotnet-debug-jit` builds step through `.hx` in VS and VS Code.

**Architecture:** `IlCode` records sequence points and local scopes as `TexprToIl` lowers each statement. A new `PdbBuilder` turns them, with document names from a new `PdbPaths`, into Portable PDB metadata, written by the table and root writers factored out of `MetaTables`. `ModuleBuilder.finish` writes the PDB first, derives its id from its hash, and hands `PeWriter` the CodeView, PdbChecksum and Reproducible entries, so the DLL's MVID depends on the PDB.

**Tech Stack:** Haxe (hxc, built with hxcpp), ECMA-335 and the Portable PDB format (https://github.com/dotnet/runtime/blob/main/docs/design/specs/PortablePdb-Metadata.md, and PE-COFF.md beside it for the debug directory entries), bash test harness `tests/dotnet/run.sh`, C# checker `tests/fixtures/hxccheck` (System.Reflection.Metadata).

**Spec:** `docs/superpowers/specs/2026-10-29-dotnet-portable-pdb-design.md`, which extends `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md` (the main spec). Read both.

## Global Constraints

- Case names, case text, fixtures, commit messages and repo docs never name the private apps, their classes, paths or email. Say "the server app" / "the desktop app", and keep their names and paths in the gitignored `measure/` folder only.
- The server app's and desktop app's checkouts, `C:/HaxeToolkit/haxe/lib`, global haxelib and hxcs are read-only. Copies go outside them.
- Never push or merge. Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Build: `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/ HAXE_STD_PATH=C:/HaxeToolkit/haxe/std HXCPP_COMPILE_CACHE=D:/_github/hxc-toolchain/hxcpp-cache haxelib run aedifex build cpp .` → `bin/cpp/windows/x64/release/bin/hxc.exe` (`HXC` below). `bin/hxc-windows-x64.exe` is stale; never use it.
- One case: `bash tests/dotnet/run.sh --compiler $HXC --std C:/HaxeToolkit/haxe/std --case <name>`; ALL: the same without `--case` (607 cases before this plan; every one keeps passing).
- Own suite: `cd D:/_github/haxe-conformance && neko run.n run --compiler $HXC --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected` (129 checks, 0 failures).
- Deterministic: same input, byte-identical DLL and PDB; no map iteration order reaches output.
- Without `-debug`, every DLL is byte-identical to the one hxc wrote before this plan.
- ILVerify stays clean (`run.sh` runs it on every case).
- Match the surrounding code: hxc's naming, comment density and idiom; no new comment style.
- PDB values: SHA-256 hash algorithm GUID `8829d00f-11b8-4213-878b-770e8597ac16`; Document language GUID C#'s `3f5162f8-07c6-11d3-9053-00c04fa302a1` *(plan's ruling on the spec's open choice: the Watch window should take C# syntax; Task 9's checklist confirms)*; EmbeddedSource kind GUID `0e8a571b-6926-466e-b4ad-8ab04611f5fe`; hidden line `0xFEEFEE`; `DebuggingModes` value `0x103` under `-D dotnet-debug-jit` only.
- Path names (spec, Paths): pathmap, then relative to the current folder, then `haxe-std/`, `haxelib/<library>/`, `hxc-runtime/`, then the full path with a warning. The CodeView path is the PDB's file name alone.

## Review Focus

1. A position hxc cannot resolve (file `?`, `Position.nullPos`, a macro position in a file that does not exist, the `-main` entry expression): a hidden point, never line 1 and never a crash. Test in Task 4 (`pdb-unresolved-positions`).
2. hxc's runtime files exist only inside hxc.exe: `Position.getInfos` resolves them only from the content cache, so their points must carry real lines, not the `unresolved()` line 1. Test in Task 6 (`pdb-runtime-source`'s line check).
3. A method whose points name two Documents (`-D keep-inline-positions` inlining another file's function): the sequence-point blob's document-change records. Test in Task 2 (`pdb-two-documents`).
4. The server app's scale (hundreds of documents, heaps past 64 KiB, so 4-byte heap and row indices in the PDB): System.Reflection.Metadata must read it. Test in Task 11 (HxcCheck `docs` and `pdb:` over the server app's PDB).
5. Dead code after a `throw` or `return` (IlCode drops it) and statements that emit no IL: sequence-point offsets must stay strictly increasing and inside the method's IL. Test: HxcCheck's invariant checks (Task 2) plus `pdb-dead-code` (Task 2).

## File Structure

- Create `src/hxc/codegen/dotnet/PdbBuilder.hx`: documents, per-method points and scopes, the PDB tables and `#Pdb` stream.
- Create `src/hxc/codegen/dotnet/PdbPaths.hx`: a source file's Document name; `-D dotnet-pathmap` parsing.
- Modify `IlCode.hx` (points, scopes, local names), `TexprToIl.hx`/`TexprFlow.hx` (where statements and catches are lowered), `TclassToIl.hx` (`emitMethod`: which methods get points, handing them to the builder), `ModuleBuilder.hx` (`finish`), `MetaTables.hx` (shared table/root writers, PDB coded index), `IlMeta.hx` (PDB table numbers), `PeWriter.hx` (debug directory), `GenerateDotnet.hx` (flags, writing `.pdb`), `AttributesToIl.hx` (`DebuggableAttribute`), `src/hxc/Compiler.hx` + `src/hxc/context/Context.hx` (haxelib class path → library name).
- Modify `tests/fixtures/hxccheck/Program.cs` (dump items), `tests/dotnet/run.sh` (`@optimized`, cross-folder second compile, machine-path scan), `tests/dotnet/cases.hx.txt` (cases).
- Create `tests/dotnet/debugger/` (sample program, hxml, `.vscode/launch.json`) and `docs/superpowers/plans/2026-10-29-dotnet-portable-pdb/debugger-checklist.md`.
- Modify `README.md` (debugging section) and the two specs (results).

---

### Task 1: The debug directory and an empty PDB

**Files:**
- Modify: `src/hxc/codegen/dotnet/MetaTables.hx`, `IlMeta.hx`, `PeWriter.hx`, `ModuleBuilder.hx`, `GenerateDotnet.hx`
- Create: `src/hxc/codegen/dotnet/PdbBuilder.hx`
- Modify: `tests/fixtures/hxccheck/Program.cs`, `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `TableIdx.IDocument = 0x30`, `IMethodDebugInformation = 0x31`, `ILocalScope = 0x32`, `ILocalVariable = 0x33`, `ILocalConstant = 0x34`, `IImportScope = 0x35`, `IStateMachineMethod = 0x36`, `ICustomDebugInformation = 0x37`, and a coded index kind `TableIdx.IHasCustomDebugInformation` (the next free kind number) with the spec's table list.
- Produces: `MetaTables.writeTables(written:Array<{table:Int, rows:Array<Row>, schema:Array<Int>}>, h:MetaHeaps, rowCounts:Array<Int>, sortedLo:Int, sortedHi:Int):Bytes` (the `#~` stream; `rowCounts` covers tables of another metadata, as the PDB's MethodDef columns need) and `MetaTables.writeRoot(version:String, streams:Array<{name:String, data:Bytes}>):{bytes:Bytes, offsets:Map<String, Int>}`. `writeMetadata` uses both and its output stays byte-identical.
- Produces: `MetaTables.rowCounts():Array<Int>` (64 entries, the DLL's tables).
- Produces: `class PdbBuilder { new(); method(token:Int, localsSig:Int, code:IlCode):Void; write(entryPoint:Int, typeSystemRows:Array<Int>, methodCount:Int):{bytes:Bytes, idOffset:Int} }`. In this task `method` stores nothing yet; `write` gives a PDB with one MethodDebugInformation row per MethodDef row (all empty), one root ImportScope row (empty imports blob), and a zeroed 20-byte id at `idOffset`.
- Produces: `typedef DebugDirectory = {pdbName:String, pdbId:Bytes, pdbHash:Bytes}` in PeWriter; `PeWriter.write` takes `debug:Null<DebugDirectory>` in its image argument.
- Produces: `ModuleBuilder.finish(entryPoint:Int, pdb:Null<PdbBuilder>, pdbName:String):{dll:Bytes, pdb:Null<Bytes>}`.
- Produces: `DotnetCtx.pdb:Null<PdbBuilder>`, non-null exactly when `ctx.debug`.
- Produces (HxcCheck): dump item `debugdir`.

- [ ] **Step 1: Keep a baseline compiler.** Build `HXC` at the plan's starting commit and copy it to `D:/_hxc5/hxc-base.exe` (Task 8 compares against it). Record its commit in the task report.

- [ ] **Step 2: Add HxcCheck's `debugdir` item.** It prints, in debug directory order: `codeview <path> age <age> portable|windows id-match|id-mismatch` (portable when MinorVersion is `0x504D`; the id is compared with the PDB's `DebugMetadataHeader.Id` read through `MetadataReaderProvider.FromPortablePdbStream` from `<dll dir>/<file name of path>`); `pdbchecksum <algorithm> match|mismatch` (SHA-256 of the PDB bytes with the 20 id bytes at `IdStartOffset` zeroed); `reproducible`; any other entry as `entry <type>`. Then `pdb rows match|mismatch` (MethodDebugInformation rows against MethodDef rows). With no debug directory it prints `debugdir none`, and `stray <name>.pdb` if that file is beside the DLL anyway. Update the usage comment at the top of Program.cs.

- [ ] **Step 3: Write the failing cases** in `tests/dotnet/cases.hx.txt`, near the other `@dump=assembly` cases:

```
--- pdb-written @lib @dump=debugdir + -debug
class P {}
===
[dump]
codeview P.pdb age 1 portable id-match
pdbchecksum SHA256 match
reproducible
pdb rows match
--- pdb-absent @lib @dump=debugdir
class P {}
===
[dump]
debugdir none
```

- [ ] **Step 4: Run them.** `run.sh --case pdb-written` fails with `debugdir none`; `pdb-absent` passes already.

- [ ] **Step 5: Factor `writeTables`/`writeRoot` out of `writeMetadata`; add the PDB table numbers and coded index; write `PdbBuilder.write`.** The `#Pdb` stream: id (20 bytes), EntryPoint (MethodDef token or 0), the mask of type-system tables with rows, their row counts. Streams in the order `#Pdb`, `#~`, `#Strings`, `#US`, `#GUID`, `#Blob`; root version string `PDB v1.0`. The PDB's own `MetaHeaps`.

- [ ] **Step 6: Debug directory in `PeWriter`.** Data directory 6 points at three 28-byte entries placed in `.text` (where is the builder's, deterministic): CodeView (type 2, MajorVersion `0x0100`, MinorVersion `0x504D`, TimeDateStamp = the id's last 4 bytes, data `RSDS` + GUID (id's first 16 bytes) + age 1 + `<pdbName>\0`), PdbChecksum (type 19, version 1.0, stamp 0, data `SHA256\0` + 32-byte hash), Reproducible (type 16, no data). Image hashing for the MVID happens after these are in place, as now.

- [ ] **Step 7: `ModuleBuilder.finish` and `GenerateDotnet`.** finish: metadata, then `pdb.write`, `hash = Sha256(pdb)` (id zeroed), id = hash's first 20 bytes with the GUID version/variant bits set as the MVID's are and the stamp's top bit set as the timestamp's is, patched in at `idOffset`, then `PeWriter.write` with `{pdbName, pdbId: id, pdbHash: hash}`. GenerateDotnet saves `<dir>/<name>.pdb` beside the DLL when `pdb != null`.

- [ ] **Step 8: Run both cases and ALL.** Both pass; ALL passes (607 + 2).

- [ ] **Step 9: Commit** `Write a Portable PDB and the debug directory under -debug, for .NET`.

### Task 2: Sequence points and Documents

**Files:**
- Modify: `IlCode.hx`, `TexprToIl.hx`, `TexprFlow.hx`, `TclassToIl.hx`, `PdbBuilder.hx`
- Create: `src/hxc/codegen/dotnet/PdbPaths.hx`
- Modify: `tests/fixtures/hxccheck/Program.cs`, `tests/dotnet/run.sh` (`//// <path>` files), `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 1's `PdbBuilder.method`, `DotnetCtx.pdb`.
- Produces: `typedef SeqPoint = {offset:Int, pos:Null<Position>}` (null `pos`: hidden) and `IlCode.points:Null<Array<SeqPoint>>` (non-null only when debugging); `IlCode.point(pos:Null<Position>):Void` records at the current offset when the code is reachable and the stack is empty, and replaces a point already at that offset.
- Produces: `TexprToIl.points:Bool` (false: lowering records nothing).
- Produces: `class PdbPaths { new(cwd:String); name(file:String):String }`, in this task only "relative to `cwd`, else the full path", slashes forward.
- Produces (HxcCheck): items `docs`, `doc:<name>`, `pdb:<type>`.

- [ ] **Step 1: HxcCheck items.** `docs`: one line per Document row, in row order: `document <name> <sha256|other> <csharp|language GUID>[ embedded ok|embedded mismatch]` (embedded: Task 6), or `documents none`. `doc:<name>`: that document's line, or `missing doc:<name>`. `pdb:<type>`: for each method of the type, in MethodDef order, that has points: `method <Type>::<name>`, then one line per point in IL order, `  <doc> <startLine>:<startCol>-<endLine>:<endCol>` or `  hidden`. Every dump of a PDB also checks, and prints `bad pdb: <what>` on failure: offsets strictly increasing, every offset inside the method's IL, every document index valid.

- [ ] **Step 2: Write the failing cases.**

```
--- pdb-statements @dump=doc:P.hx,pdb:P + -debug
class P {
	static function main() {
		var a = f();
		trace(a);
		if (a > 0) a++;
		while (a > 0) a--;
	}
	static function f() return 1;
}
===
[run]
P.hx:4: 1
[dump]
document P.hx sha256 csharp
method P::main
  P.hx 3:3-3:14
  P.hx 4:3-4:11
  P.hx 5:7-5:12
  P.hx 5:14-5:17
  P.hx 6:10-6:15
  P.hx 6:17-6:20
method P::f
  P.hx 8:22-8:30
```

`pdb-two-documents @dump=pdb:P + -debug -D keep-inline-positions`: P.hx's `main` runs `Q.report(2);` as a statement, where `Q` is in its own file `Q.hx` with `public static inline function report(x:Int):Void { var y = x * 2; trace(y); trace(y); }`. The harness writes one source file per case, so this task adds to `run.sh`: a source line `//// <path>` starts another file at that path, relative to the case folder (documented in the header comment). Expected: `method P::main` lists points in both `P.hx` and `Q.hx`, the `Q.hx` ones at `report`'s three statement lines, and the next `P.hx` statement's point after them.

`pdb-dead-code @dump=pdb:P + -debug`: a `main` whose block is `throw new haxe.Exception("x"); trace("never");` inside `if (Sys.args().length == 0) { ... }`. Expected: no `bad pdb:` line; the dead `trace` has no point.

Columns are 1-based and the end column is exclusive (the Portable PDB convention). If `Position.getInfos` counts differently, the code converts; the expectations above stay. If `-D dump=pretty` shows the analyzer turned these statements into others, keep the rules and change the source so the statements survive, saying so in the report.

- [ ] **Step 3: Run them.** They fail (`documents none`, no methods).

- [ ] **Step 4: Record points.** `IlCode.point` and `points` as in Interfaces. `TexprToIl` calls `point(s.pos)` before each element of a block that is not itself a block (`TexprToIl.block`), before a `var` with a value only (none without), at the condition of `if`/`while`/`do…while` (the condition with `TParenthesis`/`TMeta` stripped, at the IL that evaluates it), at a `switch`'s subject, and at a branch or loop body that is not a block. A closure's method gets its points by the same rules. Positions stay as the typer gave them.

- [ ] **Step 5: Which methods get points.** In `TclassToIl.emitMethod`, `lower.points` is true for `MField`, `MImplicitCtor`, `MClonedCtor`, `MStaticCtor` and `MCctor` only (these lower the user's expressions or field initializers); every other kind, `MEntryPoint` included, records nothing, and its MethodDebugInformation row stays empty. `emitMethod` passes the method token, the locals signature token it already computes, and `code` to `g.pdb.method`, for written bodies only (a stubbed body has no points).

- [ ] **Step 6: Documents and the sequence-point blob in `PdbBuilder`.** A Document per file in first-use order, name from `PdbPaths.name`, hash = SHA-256 of the file's bytes as on disk (`sys.io.File.getBytes`), language C#'s GUID. The blob as the format spec says: LocalSignature, InitialDocument when the method uses more than one document, delta-encoded records, document-change records, hidden points. Lines and columns from `Position.getInfos`.

- [ ] **Step 7: Run the three cases, then ALL.** Pass.

- [ ] **Step 8: Commit** `Write sequence points and Documents into the PDB, for .NET`.

### Task 3: Document names

**Files:**
- Modify: `PdbPaths.hx`, `GenerateDotnet.hx`, `src/hxc/Compiler.hx`, `src/hxc/context/Context.hx`, `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 2's `PdbPaths`.
- Produces: `PdbPaths.new(cwd:String, stdRoots:Array<String>, libraries:Array<{classPath:String, library:String}>, pathmap:Array<{from:String, to:String}>, warn:(String) -> Void)`; `static PdbPaths.parsePathmap(s:String, cwd:String):Null<Array<{from:String, to:String}>>` (null when malformed; a relative `<from>` is resolved against `cwd`).
- Produces: `Context.libraryClassPaths:Array<{classPath:String, library:String}>`, filled from `Compiler.addLibs`: a class path line of `haxelib path`'s output belongs to the library named by the next `-D <name>=<version>` line.

- [ ] **Step 1: Write the failing cases.**

```
--- pdb-names-relative @lib @module=pack.Mod @dump=doc:pack/Mod.hx,doc:haxe-std/haxe/Log.hx + -debug
package pack;
class Mod {
	public static function hello() {
		trace("x");
	}
}
===
[dump]
document pack/Mod.hx sha256 csharp
document haxe-std/haxe/Log.hx sha256 csharp
--- pdb-names-pathmap @lib @module=pack.Mod @dump=doc:src/pack/Mod.hx + -debug -D dotnet-pathmap=pack/=src/pack/
package pack;
class Mod {
	public static function hello() {
		trace("x");
	}
}
===
[dump]
document src/pack/Mod.hx sha256 csharp
--- pdb-pathmap-malformed @lib + -debug -D dotnet-pathmap=foo
class P {}
===
[compile]
dotnet: -D dotnet-pathmap must be <from>=<to> pairs separated by commas, like C:/work/=src/ (not foo)
```

(The `trace` output keeps Haxe's own `PosInfos` name: `-D dotnet-pathmap` never touches it.)

- [ ] **Step 2: Run them.** They fail (full std path; no pathmap).

- [ ] **Step 3: Implement the rules in the spec's order.** Matching is case-insensitive on Windows with slashes normalized, the longest `<from>` wins, and the std root is the `HAXE_STD_PATH` root, so an overlay keeps its segment (`haxe-std/cs/_std/haxe/NativeStackTrace.hx`). Runtime files (`RuntimeSources.ROOT`) become `hxc-runtime/` + the rest. Rule 6 warns once per file, through hxc's usual warning call, with exactly: `the PDB names <full path> by its full path, as it is outside the build folder, the Haxe std and haxelib libraries; -D dotnet-pathmap=<from>=<to> shortens it`.

- [ ] **Step 4: Check rules 4 and 6 by hand** (the harness cannot place files outside a case's folder): in a scratch folder outside any checkout, build a program that uses a haxelib library already installed globally (`haxelib list` shows them; `-lib` one with `.hx` code it calls), and one that adds `-cp <absolute folder outside the cwd>` with a class it calls, both with `--cs out -D dotnet -debug --haxelib-global`. Run `dotnet tests/fixtures/hxccheck/bin/out/HxcCheck.dll dump out/<name>.dll docs`. Expected: the library file as `haxelib/<library>/...`; the outside file by its full path, with the warning in the compile output. Paste both outputs into the task report.

- [ ] **Step 5: Run the cases, then ALL.** Pass.

- [ ] **Step 6: Commit** `Name the PDB's documents by short paths, with -D dotnet-pathmap, for .NET`.

### Task 4: Hidden points, catches and stack traces

**Files:**
- Modify: `TexprToIl.hx`, `TexprFlow.hx`, `PdbBuilder.hx`, `tests/dotnet/run.sh`, `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: harness tag `@optimized`: the case's program runs with `DOTNET_TieredCompilation=0` (fully optimized JIT from the first call); documented in run.sh's header comment.

- [ ] **Step 1: Write the failing cases.** First, update Task 2's expectations: every dumped method that falls off its end without a `return` gains a final `  hidden` (the implicit return), so `pdb-statements`'s `method P::main` ends with one. Then:

```
--- pdb-stack-trace + -debug
class P {
	static function main() {
		try {
			outer();
		} catch (e:haxe.Exception) {
			for (item in haxe.CallStack.exceptionStack(true))
				switch (item) {
					case FilePos(_, file, line, _) if (file == "P.hx"): Sys.println("haxe " + file + ":" + line);
					case _:
				}
			for (l in (cast e.native : cs.system.Exception).StackTrace.split("\n"))
				if (l.indexOf("P.hx:line ") >= 0) Sys.println("net " + StringTools.trim(l.substr(l.indexOf(" in ") + 4)));
		}
	}

	static function outer() {
		var n = 1;
		inner(n);
	}

	static function inner(n:Int) {
		if (n > 0) throw new haxe.Exception("boom");
	}
}
===
[run]
haxe P.hx:22
haxe P.hx:18
haxe P.hx:4
net P.hx:line 22
net P.hx:line 18
net P.hx:line 4
--- pdb-stack-trace-optimized @optimized + -debug
class P {
	static function main() {
		try {
			outer();
		} catch (e:haxe.Exception) {
			var lines = [for (item in haxe.CallStack.exceptionStack(true)) switch (item) {
				case FilePos(_, "P.hx", line, _): line;
				case _: -1;
			}].filter(l -> l >= 0);
			Sys.println("first " + lines[0]);
			Sys.println("known " + Lambda.foreach(lines, l -> l == 4 || l == 17 || l == 21));
		}
	}

	static function outer() {
		var n = 1;
		inner(n);
	}

	static function inner(n:Int) {
		if (n > 0) throw new haxe.Exception("boom");
	}
}
===
[run]
first 21
known true
```

(The optimized JIT may inline `outer`, dropping its frame; that is .NET's behavior and allowed. A method that always throws is not inlined, so the first frame is stable.)

In the shape of `pdb-stack-trace` (print the `P.hx` lines of both traces), add: `pdb-trace-nested-block` (the throw two blocks deep inside an `if` and a `while`), `pdb-trace-closure` (the throw inside a local function the caller calls; its frame names the closure's line), `pdb-trace-inline` (an `inline` function that throws: the frame line is the call site), `pdb-trace-inline-kept` (the same with `+ -D keep-inline-positions`: the line inside the inline function), `pdb-trace-field-init` (an instance field initializer `var x = thrower();` run by `new P()`: the frame line is the initializer's), `pdb-trace-rethrow` (a `catch` that `throw e;`s again: the haxe and .NET traces keep the original throw's line), `pdb-trace-static-init` (a static var initializer that throws, caught in `main` around the first access as `haxe.Exception` or the .NET `TypeInitializationException`'s inner exception: its frame names the initializer's line). Each expectation lists exactly the lines the rule gives, written from the source before running.

```
--- pdb-unresolved-positions @lib @dump=doc:nowhere.hx,pdb:P + -debug
import haxe.macro.Context;
class P {
	static macro function nowhere() {
		return macro @:pos(Context.makePosition({min: 0, max: 5, file: "nowhere.hx"})) Sys.println("n");
	}
	public static function g() {
		nowhere();
		Sys.println("after");
	}
}
===
[dump]
missing doc:nowhere.hx
method P::g
  hidden
  P.hx 8:3-8:23
  hidden
```

- [ ] **Step 2: Run them.** They fail (no hidden points; no `@optimized`).

- [ ] **Step 3: Implement.** `TexprToIl.finish()` records a hidden point before the implicit `ret`. A `catch` records a point at its variable's position before the IL that stores the exception, and each `case` body records one at its first statement (Task 2's block rule covers that once the case body is lowered as a block). `PdbBuilder` turns a point whose position does not resolve to a readable file or to a runtime file into a hidden point: `Position.getInfos` returns its `unresolved()` value then, which must be detected (file missing, `min < 0`), not written as line 1. `run.sh` gets `@optimized`.

- [ ] **Step 4: Run every `pdb-` case, then ALL.** Pass.

- [ ] **Step 5: Commit** `Hide generated code from the debugger and pin .hx stack traces, for .NET`.

### Task 5: Local scopes and variable names

**Files:**
- Modify: `IlCode.hx`, `TexprToIl.hx`, `TexprFlow.hx`, `PdbBuilder.hx`, `tests/fixtures/hxccheck/Program.cs`, `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `IlCode.openScope():Void`, `IlCode.closeScope():Void`, `IlCode.nameLocal(index:Int, name:String):Void` (no-ops unless debugging); `IlCode.scopes` (a tree of `{start:Int, end:Int, vars:Array<{index:Int, name:String}>, children:Array<...>}`, its type the builder's).
- Produces (HxcCheck): item `scopes:<type>`: per method with LocalScope rows, `method <Type>::<name>` then the scope tree, two spaces of indent per level, each scope a `scope` line followed by its `local <name>` lines in row order. It also checks, as `bad pdb:`, that rows are sorted (method, start ascending, length descending), nested, and inside the IL.

- [ ] **Step 1: Write the failing cases.**

```
--- pdb-locals @dump=scopes:P + -debug
class P {
	static function main() {
		var a = f();
		if (a > 0) {
			var b = a + 1;
			trace(b);
			trace(b);
		}
		for (i in 0...a) trace(i * i);
	}
	static function f() return 1;
}
===
[run]
P.hx:6: 2
P.hx:7: 2
P.hx:9: 0
[dump]
method P::main
  scope
    local a
    scope
      local b
    scope
      local i
```

`pdb-locals-hidden @dump=scopes:P + -debug`: a `main` with a `switch` on an enum value with a captured argument (`case Some(v): trace(v);`) and an array comprehension, which make `VGenerated` and extractor temporaries. Expected: only the user's names (`v` and the comprehension's own named variable), no `_g`, `tmp` or `_hx_` names. A variable captured by a closure (`var c = 1; var f = () -> c + 1; trace(f());`) has no `local c` line if it lives in the closure's class, which the expectation then shows; the builder writes what the rule gives.

- [ ] **Step 2: Run them.** They fail (no scopes).

- [ ] **Step 3: Implement.** `TexprToIl.block` opens a scope around each block and closes it after; a `var` (and a catch variable) whose `TVar` kind is `VUser`, `VInlined` or `VAbstractThis` gets `nameLocal` with its IL local (`VAbstractThis` as `this`). `PdbBuilder` writes LocalScope rows only for scopes with a named variable, re-parenting the children of dropped ones, and widens the function body's own block to the whole method `[0, IL size)` as the root. LocalVariable rows: attributes 0, the IL local's index, the name; ImportScope 1 on every scope. Locals with no name stay unnamed.

- [ ] **Step 4: Run every `pdb-` case, then ALL.** Pass.

- [ ] **Step 5: Commit** `Write local scopes and Haxe variable names into the PDB, for .NET`.

### Task 6: hxc's runtime source, embedded

**Files:**
- Modify: `PdbBuilder.hx`, `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `RuntimeSources.isVirtual(path)`, `RuntimeSources.get(relative)`.

- [ ] **Step 1: Write the failing case.**

```
--- pdb-runtime-source @dump=doc:hxc-runtime/cs/internal/Runtime.hx + -debug
class P {
	static function main() {
		var d:Dynamic = null;
		try {
			trace(d.foo);
		} catch (e:Dynamic) {
			var found = false;
			for (item in haxe.CallStack.exceptionStack(true)) switch (item) {
				case FilePos(_, file, line, _) if (file != null && StringTools.startsWith(file, "hxc-runtime/")): if (line > 1) found = true;
				case _:
			}
			Sys.println("runtime frame " + found);
		}
	}
}
===
[run]
runtime frame true
[dump]
document hxc-runtime/cs/internal/Runtime.hx sha256 csharp embedded ok
```

(If reading a field of null does not throw from `Runtime.hx`, the builder picks another runtime call that does and keeps the dump item's file the one the frame names.)

- [ ] **Step 2: Run it.** It fails (no `embedded`; the frame line may be 1, Review Focus 2).

- [ ] **Step 3: Implement.** A runtime Document's hash is the SHA-256 of the embedded text's UTF-8 bytes, and it gets a CustomDebugInformation row (parent: the Document, kind: EmbeddedSource GUID, value: int32 `0` then the UTF-8 bytes, uncompressed). The runtime file's lines come from its text: make sure `Position.getInfos` has it cached (register it from `RuntimeSources.get` when it is not).

- [ ] **Step 4: Run every `pdb-` case, then ALL.** Pass.

- [ ] **Step 5: Commit** `Embed hxc's runtime source in the PDB, for .NET`.

### Task 7: -D dotnet-debug-jit

**Files:**
- Modify: `GenerateDotnet.hx`, `AttributesToIl.hx`, `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `AttributesToIl.runtimeAttr` with `ATEnum(path, ATI4)` (as `EditorBrowsableState` is written).

- [ ] **Step 1: Write the failing cases.**

```
--- pdb-debug-jit + -debug -D dotnet-debug-jit
class P {
	static function main() {
		var t = cs.Lib.toNativeType(cs.system.diagnostics.DebuggableAttribute);
		var a:cs.system.diagnostics.DebuggableAttribute = cast cs.system.Attribute.GetCustomAttribute(cs.Lib.toNativeType(P).Assembly, t);
		Sys.println(a == null ? "none" : a.IsJITOptimizerDisabled + " " + a.IsJITTrackingEnabled + " " + (cast a.DebuggingFlags : Int));
	}
}
===
[run]
true true 259
```

`pdb-no-debug-jit + -debug`: the same source; expected `[run]` `none`. Then:

```
--- pdb-debug-jit-needs-debug @lib + -D dotnet-debug-jit
class P {}
===
[compile]
dotnet: -D dotnet-debug-jit needs -debug: without the PDB there are no .hx lines to step through
```

(Adjust only the Haxe spelling of the reflection calls if hxc needs another; the printed values are fixed.)

- [ ] **Step 2: Run them.** They fail.

- [ ] **Step 3: Implement.** `AttributesToIl.forAssembly` writes `DebuggableAttribute(DebuggingModes)` with `0x103` when `-D dotnet-debug-jit`, with the enum path `{ns: ["System", "Diagnostics"], nested: ["DebuggableAttribute"], name: "DebuggingModes"}` (in `System.Runtime`'s identity, as `runtimeAttr` pins it). GenerateDotnet reports the error above, as `-D dotnet-version`'s is reported, when the define is set without `ctx.debug`.

- [ ] **Step 4: Run every `pdb-` case, then ALL.** Pass.

- [ ] **Step 5: Commit** `Add -D dotnet-debug-jit, writing DebuggableAttribute, for .NET`.

### Task 8: Determinism across folders, no machine paths, no change without -debug

**Files:**
- Modify: `tests/dotnet/run.sh`
- Create: `D:/_hxc5/nodebug-compare.sh` (local, not committed)

- [ ] **Step 1: Cross-folder second compile.** In `run_case`, when the case's extra args contain `-debug`, the second compile runs on a copy of the case's source in `$casedir/m/` with `--cwd "$casedir/m"`, writing `m/b/P`, and the determinism loop compares `a/P/*` with `m/b/P/*`. Update run.sh's header comment.

- [ ] **Step 2: Machine-path scan.** For a case with `-debug`, the `.pdb` must not contain `$casedir`'s absolute path in any spelling (forward and back slashes, any case, as `grep -a -i -F` finds it), or the user profile folder: on a hit, the problem `the PDB holds a machine path: <path>`.

- [ ] **Step 3: Check the scan fails when it should.** Temporarily run one `pdb-` case with `+ -D dotnet-pathmap=pack/=<casedir's absolute path>/` in a local copy of the case (not committed): it reports the problem. Restore.

- [ ] **Step 4: No change without -debug.** Write `nodebug-compare.sh`: run ALL with `D:/_hxc5/hxc-base.exe` into `HXC_TEST_TMP=D:/_hxc5/base`, then with `HXC` into `D:/_hxc5/new` (both `-j 8`), then `cmp` every case's `a/P/*.dll` between the two for the cases without `-debug`. Expected: no difference (cases added by this plan exist in `new` only and are skipped). If the harness clears case folders after a run, keep them for this comparison by the builder's means and say how in the report.

- [ ] **Step 5: Run ALL.** Pass.

- [ ] **Step 6: Commit** `Check the PDB's determinism across folders and for machine paths, for .NET`.

### Task 9: Debugger setup, sample and checklist (then stop)

**Files:**
- Create: `tests/dotnet/debugger/Main.hx`, `tests/dotnet/debugger/build.hxml`, `tests/dotnet/debugger/.vscode/launch.json`, `tests/dotnet/debugger/README.md`
- Create: `docs/superpowers/plans/2026-10-29-dotnet-portable-pdb/debugger-checklist.md`
- Modify: `README.md`

- [ ] **Step 1: The sample.** `Main.hx` (package `sample`, file `src/sample/Main.hx`, plus one class in `src/sample/Shapes.hx`): a loop calling an instance method in the other file, a local in an inner block, a closure capturing a local, a `try`/`catch`, a `trace`, and a call into the runtime (`Reflect.field`). `build.hxml`: `-cp src --main sample.Main --cs out -D dotnet -debug -D dotnet-debug-jit` plus the std flags the README documents. `launch.json`: a `coreclr` launch of `out/Main.dll` (the name hxc gives) with `"justMyCode": false`, `"symbolOptions": {"searchPaths": ["${workspaceFolder}/out"]}` and `"sourceFileMap": {"src/": "${workspaceFolder}/src/", "haxe-std/": "C:/HaxeToolkit/haxe/std/"}`. Build it and run it once from the command line: it runs, and its trace names `src/sample/...` lines.

- [ ] **Step 2: The checklist.** One section per debugger (VS Code first, then VS 2022+), each a numbered list of: what to open, where to click, what should appear. Cover, in order: **(1) breakpoint binding** in `src/sample/Shapes.hx` before the program starts (VS Code with `sourceFileMap`; VS with the folder added under Debug Source Files, or opened through "Find source") (this result decides Task 10); step over a line, step into the other file, step out; the Locals window shows the Haxe names in the inner block and not after it; a Watch of a local in C# syntax (`a + 1`) and in Haxe-only syntax, noting which work; stepping into `Reflect.field` shows hxc's runtime source; an exception's Call Stack names `.hx` lines. Each item has a blank "result" line. No private app names.

- [ ] **Step 3: README.** A "Debugging .NET output" section: `-debug` and `-D dotnet-debug-jit`, the path names (the five rules and `-D dotnet-pathmap`), the `sourceFileMap` example, VS's source folder setting, and that the server app's PDB ships as before.

- [ ] **Step 4: Commit** `Add a debugger sample and checklist for the .NET PDB`.

- [ ] **Step 5: Stop.** The controller hands the checklist to the person driving this and waits for their results; that is not a decision but a step only they can do. Record the results in the checklist file, commit (`Record the debugger checklist's results, for .NET`), then go on.

### Task 10: The development fallback (only if a debugger did not bind)

Run this task only if the checklist's item (1) failed in VS or VS Code with short paths. Otherwise record "not needed" in the ledger and skip it.

**Files:** `PdbPaths.hx`, `GenerateDotnet.hx`, `tests/dotnet/cases.hx.txt`, `README.md`, the design spec

**Interfaces:**
- Produces: `PdbPaths` gains `fullPaths:Bool`; under it rules 2 to 4 give the file's full path (runtime files keep `hxc-runtime/`), `-D dotnet-pathmap` still applies first.

- [ ] **Step 1: Failing case** `pdb-debug-jit-full-paths @dump=docs + -debug -D dotnet-debug-jit`: one P.hx; expected its document named by its full path. The harness's machine-path scan (Task 8) must skip `-D dotnet-debug-jit` cases; the expected text cannot hold the case's folder, so this case's dump uses a new HxcCheck item `doc-tail:P.hx` that prints `document <...>/P.hx absolute` when the name is absolute and ends with `/P.hx` (or `relative` otherwise).
- [ ] **Step 2: Run it; it fails.**
- [ ] **Step 3: Implement** `fullPaths = ctx.defines.rawDefined("dotnet_debug_jit")`; update the scan, README and the design spec's Paths section ("the fallback was needed, because …").
- [ ] **Step 4: Run every `pdb-` case and ALL.** Pass. Ask the person to repeat checklist item (1).
- [ ] **Step 5: Commit** `Name documents by full paths in -D dotnet-debug-jit builds, for .NET`.

### Task 11: The server app exit and the record

**Files:**
- Create (local, gitignored): `docs/superpowers/plans/2026-10-29-dotnet-portable-pdb/measure/` scripts, copied from 4c's measure folder and changed
- Modify: both specs, `README.md:255` area if it lists milestone status

- [ ] **Step 1: Optimized build with a probe.** Copy 4c's `measure.sh` (and what it calls) into this plan's `measure/`, add `-debug`, and run it on a copy of the server app's source (as 4c did, outside the checkout) in which one function the no-browser runner reaches throws `new haxe.Exception("pdb probe")` at a known line, caught and logged by the app's own logging. Expected: the build has 0 errors, ILVerify is clean as in 4c, HxcCheck `docs` and `pdb:<a type with many methods>` read the PDB with no `bad pdb:` line (Review Focus 4), and the run's log shows the probe's `.hx` file and line in both the Haxe trace (`e.details()` or `CallStack`) and the .NET trace.

- [ ] **Step 2: Development build.** The same copy with `-D dotnet-debug-jit` and the `cs/Server` launch the person uses; hand them the checklist's VS Code and VS sections again for the server app (breakpoint in a file under the app's own class path, step, Locals). Record their results.

- [ ] **Step 3: Record.** In the main spec, milestone 5 gets an "Exit measured" paragraph (what was built, what both traces showed, the checklist's results, the language GUID's outcome, whether Task 10 ran) and its Debug info bullet points at the design spec. The design spec's "What the builder decides" items get their answers. No private names.

- [ ] **Step 4: Final run.** ALL and the own suite pass; record the counts.

- [ ] **Step 5: Commit** `Measure milestone 5: .hx stack traces and stepping in the server app`.
