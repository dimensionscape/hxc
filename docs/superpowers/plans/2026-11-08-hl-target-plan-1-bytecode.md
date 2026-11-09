# HashLink target, Plan 1: unoptimised bytecode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `hxc --hl out.hl -D hl_no_opt` writes `.hl` files byte-identical to Haxe 4.3.7's for a set of
small programs (empty `main`, `trace`, and the core language), and they run on `hl.exe` as Haxe's do.

**Architecture:** a close port of Haxe 4.3.7's `hlcode.ml` (the code model and text dump) and
`genhl.ml` (typed AST → HL register code → `.hl` bytes) into `src/hxc/codegen/hl/`. The port sits after
hxc's filters and analyzer, like the JVM and .NET generators. The writer and dump are checked first
against `.hl` files that Haxe built (a read-back round trip). The generator is then checked function by
function against Haxe's `-D dump` output, until whole files match.

**Tech Stack:** Haxe 4.3 (hxc is self-hosting; built with `haxelib run aedifex build cpp .`), Haxe
4.3.7 at `C:\HaxeToolkit\haxe` as the oracle, HashLink at `C:/SDKs/hashlink/hl.exe` (2.0.0), the
haxe-conformance harness (`D:\_github\haxe-conformance`, `neko run.n`).

**Spec:** `docs/superpowers/specs/2026-11-08-hl-target-design.md`

**Reference source:** Haxe tag `4.3.7`, `src/generators/genhl.ml`, `hlcode.ml` (and, for Task 1,
`src/context/common.ml`, `src/compiler/compiler.ml`, `src/compiler/generate.ml`,
`src/filters/filters.ml`, `src/filters/exceptions.ml`, `src/codegen/codegen.ml`). Get it from
`https://codeload.github.com/HaxeFoundation/haxe/tar.gz/refs/tags/4.3.7`, into a scratch folder,
never into the repo.

## Where this plan sits

The spec's milestones become five plans. Each is written when the plan before it has landed, because
each depends on what the previous one finds:

| Plan | Spec milestone | Ends with |
| --- | --- | --- |
| **1 (this one)** | M1 + M2 | small programs byte-identical with `-D hl_no_opt`, debug info included |
| 2 | M3 | `hlopt.ml` ported; the same programs byte-identical with the optimiser on (the default) |
| 3 | M4 | haxe-conformance harness gets an HL target option; `unit.hl` identical; runs as Haxe's does |
| 4 | M5 | JoeClash `build.hxml` `game.hl` identical, plays |
| 5 | M6 | `hl2c.ml` + `hlc.json`; small cases, then JoeClash `build.android.hxml` |

## Global Constraints

- Output must be **byte-identical** to Haxe 4.3.7's for the same source and command line. A difference
  is a bug until fixed, or listed with a reason.
- Work on a branch from `kha-port` (`ce5ea5cb`), named `hl-target`. Commits are local; the user pushes
  (to the `hoseyjoe` fork, never `origin`).
- Public repo: no private app names in anything committed (file contents, file names, case names,
  commit messages); the controller gives the check command with each task. Commit author is the
  repo-local noreply address; don't change git config.
- The code model, dump and writer (`HlCode.hx`, `HlDump.hx`, `HlWriter.hx`) import nothing from hxc
  outside `hxc.codegen.hl`, so the round-trip tool can run them under Haxe's `--interp`.
- Defines that change output, from `genhl.ml`: `hl_no_opt`, `hl_no_debug` (debug info is written
  unless this is set, not only with `--debug`), `hl-ver`, `absolute-path`, `dump`. Plan 1 always
  sets `hl_no_opt`; with it unset, Plan 1's generator reports an error that the optimiser isn't
  ported yet (Plan 2).
- `hl-ver` defaults to the content of `<std>/hl/hl_version` (`1.12.0` in the 4.3.7 std), not to the
  `1.10.0` that `Defines.hx`'s description says.
- Bytecode version is 4 when the bytes table is empty, else 5 (`build_code`).
- hxc's own suite and `tests/dotnet/run.sh` stay green (`.NET` 736/736 at `kha-port`'s tip; check the
  count before starting).
- `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std` for every hxc compile in this plan.

## Review Focus

1. **Paths baked into the `.hl`.** Debug info holds file names, including absolute std paths
   (`C:\HaxeToolkit\haxe\std/hl/_std/Std.hx`) and paths as the command line gave them. Expected:
   identical to Haxe on the same machine, and the CI digest is unaffected by the machine's std location.
   Pinned by `HlDigest`'s normalisation (Task 3) and the `debug-paths` case (Task 7).
2. **Table order.** Types, globals, strings, natives and functions are numbered in first-use order, and
   `genhl.ml` iterates `PMap`s and `Hashtbl`s in places (`pinterfaces`, `overrides`, the natives sort).
   Expected: the same numbering as Haxe on every run. Pinned by the `compile twice, same bytes` check in
   `tests/hl/run.sh` (Task 3) and the `interfaces-many` case (Task 5).
3. **Programs that touch native HL types** (`hl.Bytes`, `hl.NativeArray`, `hl.Ref`, `hl.I64`,
   `@:hlNative` classes). Expected: the same intrinsics and natives table as Haxe. Pinned by the
   `hl-natives` case (Task 6).
4. **Non-ASCII strings.** Strings go into the table as UTF-8 and become UCS2 at runtime (`to_utf8`,
   `alloc_string`). Expected: identical bytes, and `hl.exe` prints the same text. Pinned by the
   `strings-unicode` case (Task 4).
5. **`--debug` changes the code, not only the tables** (`assigns`, `hold`/`free` of registers kept for
   the debugger). Expected: identical with and without `--debug`. Pinned by the `debug-assigns` case
   (Task 6).

---

## File Structure

| File | Responsibility |
| --- | --- |
| `src/hxc/context/PlatformConfig.hx` (modify) | `hl()` config |
| `src/hxc/Compiler.hx` (modify) | `--hl` selects `Hl`; `hl-ver`/`hlc` setup; dispatch to `HlGenerate.generate` |
| `src/hxc/filters/Exceptions.hx`, `Filters.hx` (modify) | Hl in the exception filter's targets; no meta field on Hl |
| `src/hxc/codegen/FixOverrides.hx` (moved from `generators/cpp/CppFixOverrides.hx`) | shared by cpp, cppia and hl, as `Codegen.fix_overrides` is in Haxe |
| `src/hxc/codegen/hl/HlCode.hx` | `hlcode.ml`'s types and helpers |
| `src/hxc/codegen/hl/HlDump.hx` | `hlcode.ml`'s `tstr`, `ostr`, `dump` (the `-D dump` text) |
| `src/hxc/codegen/hl/HlWriter.hx` | `genhl.ml`'s `write_index_gen` and `write_code` |
| `src/hxc/codegen/hl/HlContext.hx` | `genhl.ml`'s context record, `lookup` tables, `method_context`, register alloc |
| `src/hxc/codegen/hl/HlTypes.hx` | `to_type`, `class_type`, `enum_type`, `real_type`, `resolve_class`, `alloc_*` |
| `src/hxc/codegen/hl/HlCasts.hx` | `eval_to`, `cast_to`, `unsafe_cast_to`, `to_string`, `make_const`, `make_string` |
| `src/hxc/codegen/hl/HlAccess.hx` | `object_access`, `direct_method_call`, `get_access`, `array_read`, `jump_expr`, `eval_args` |
| `src/hxc/codegen/hl/HlExpr.hx` | `eval_expr` except the `$` intrinsics |
| `src/hxc/codegen/hl/HlIntrinsics.hx` | `eval_expr`'s `TCall(TIdent "$…")` cases (lines 1650–2058) |
| `src/hxc/codegen/hl/HlAssign.hx` | `gen_assign_op` |
| `src/hxc/codegen/hl/HlFunctions.hx` | `make_fun`, `build_capture_vars`, `gen_method_wrapper`, `make_debug` |
| `src/hxc/codegen/hl/HlGenerate.hx` | `generate_static/member/type/static_init`, `add_types`, `build_code`, `generate` |
| `tools/hl/HlReader.hx`, `tools/hl/HlRoundTrip.hx` | read a `.hl` back into `HlCodeData` (test tool, not shipped) |
| `tools/hl-compare.sh` | build one program with both compilers; report the first differing table/function |
| `tests/cases/hl-setup/` | family: defines/config/typed-AST dump for `--hl` (CI) |
| `tests/cases/hl-output/` | family: `.hl` digests vs Haxe's (CI); also the programs `tests/hl/run.sh` runs |
| `tests/hl/run.sh` | local: both compilers, byte compare, compile-twice check, run both on `hl.exe` |

`genhl.ml` splits along its own function groups; keep each Haxe function's name in camelCase
(`eval_expr` → `evalExpr`) and say which OCaml function each one ports in a comment above it, as the
JVM port does.

---

### Task 1: `--hl` selects the HL platform

**Files:**
- Modify: `src/hxc/Compiler.hx:808-826` (the `-hl` group), `:1000-1024` (per-platform setup), `:1698-1735` (dispatch, later)
- Modify: `src/hxc/context/PlatformConfig.hx`
- Modify: `src/hxc/filters/Exceptions.hx:389`, `src/hxc/filters/Filters.hx:1384`
- Create: `tests/cases/hl-setup/family.json`, `cases.hx.txt`, `fixture/Probe.hx`
- Test: `tests/expected/hl-setup.json` (recorded from Haxe)

**Interfaces:**
- Produces: `PlatformConfig.hl():PlatformConfig`; `platform == Hl` with `ctx.file` = the `--hl` value
  and the `hl/_std` overlay; defines `hl-ver` (always), `hlc` (when the file ends in `.c`).

- [ ] **Step 1: Write the family**

`family.json`: `{"name":"hl-setup","oracle":"haxe","kind":"compile-diff","cost":"quick","module":"P",
"args":["-cp",".","--main","$module"]}`. The family args name no target, so each case gives its own
`--hl …` after `+` (a second `--hl` would be "Multiple targets").

`fixture/Probe.hx`: `Probe.print()` (an init macro) prints, one per line: `hl-ver=` +
`Context.definedValue("hl-ver")`, `hlc=` + `Context.defined("hlc")`, `static=`, `sys=`,
`target.threaded=`, `target.atomics=`, `target.utf16=` (each `Context.defined`), and from
`Compiler.getConfiguration().platformConfig`: `padNulls`, `scoping.scope`, `scoping.flags`,
`exceptions.nativeThrows`.

Cases in `cases.hx.txt`:
- `config + --hl out.hl --no-output --macro Probe.print()`: `class P { static function main() {} }`.
- `config-hlc + --hl out/main.c --no-output --macro Probe.print()`: same program.
- `hl-ver-set + --hl out.hl --no-output --macro Probe.print() -D hl-ver=1.13.0`.
- `hl-types + --hl out.hl --no-output`: a program using `hl.Bytes.alloc(4)`, `new
  hl.NativeArray<Int>(2)`, `hl.Ref.make`, `hl.I64.ofInt(1)`, `untyped $new(Int)` assigned to locals and
  `trace`d: types without error.
- `hl-only-package-error + --hl out.hl --no-output`: `class P { static function main() {
  cpp.Lib.println(1); } }`: the forbidden-package error, as Haxe prints it.
- `typed-dump + --hl out.hl -D hl_no_opt -D dump --macro Probe.after('dump/hl/P.dump')`, where
  `Probe.after(path)` prints the file in `onAfterGenerate` like `cpp-output`'s `Dump.after`: a program
  with a class, an enum, a closure, a `switch` and a `try`/`catch`. This checks that hxc's filters and
  analyzer give the generator the same tree Haxe's genhl sees. (Until Task 4, hxc writes no `.hl` here;
  the dump is written before generation, so the case still compares.)

- [ ] **Step 2: Record Haxe's results**

Run (from `D:\_github\haxe-conformance`):
`neko run.n record --compiler haxe --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected --family hl-setup`
Expected: `tests/expected/hl-setup.json` written, one entry per case.

- [ ] **Step 3: Run with hxc to see them fail**

Run: `neko run.n run --compiler D:/_github/hxc/bin/hxc-windows-x64.exe --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected --family hl-setup`
Expected: FAIL (`hl-ver=` empty and `static=false`, since `--hl` leaves the platform at Cross today).

- [ ] **Step 4: Implement**

- `PlatformConfig.hl()`: `default_config with pf_capture_policy = CPWrapRef; pf_pad_nulls = true;
  pf_supports_threads = true; pf_supports_atomics = true` (`common.ml:759`), so `isStatic: true, sys:
  true, supportsOverload: false, capturePolicy: CPWrapRef, padNulls: true, addFinalReturn: false,
  canSkipNonNullableArgument: true, supportsRestArgs: false, usesUtf16: true, supportsUnicode: true,
  supportsThreads: true, supportsAtomics: true`; exceptions keep the defaults. Add `case Hl: hl();` to
  `get`.
- `Compiler.hx`: split `-hl`/`--hl` out of the no-generator group: `setPlatform(Hl); targetDir = "hl";
  ownPackages = ["hl"]; ctx.file = argValue(...)`. In per-platform setup, as `compiler.ml:143`: if
  `hl-ver` isn't defined, read `hl/hl_version` through the class path (trimmed) and define it; when it
  isn't found, fail with Haxe's message, `The file hl_version could not be found. Please make sure
  HAXE_STD_PATH is set to the standard library corresponding to the used compiler version.`
  Define `hlc` when `ctx.file`'s extension is `c` (`common.ml:977`).
- `Exceptions.hx:389`: add `Hl` to the targets list (`exceptions.ml:527`).
- `Filters.hx:1384`: skip `addMetaField` when `com.platform == Hl` (`filters.ml:758`).
- `EvalMacro.hx:2188-2198` (scoping in `getConfiguration`) needs no change: Hl uses the default
  `BlockScope` with no flags. Check the recorded `config` output agrees.

- [ ] **Step 5: Run the family and the regression suites**

Run the Step 3 command. Expected: PASS for all `hl-setup` cases.
Run hxc's whole own suite (the CI "hxc's own tests" command with the local paths) and
`HAXE_STD_PATH=C:/HaxeToolkit/haxe/std tests/dotnet/run.sh --compiler bin/hxc-windows-x64.exe`.
Expected: both as green as before the change.

- [ ] **Step 6: Commit**

`git add src/hxc/Compiler.hx src/hxc/context/PlatformConfig.hx src/hxc/filters tests/cases/hl-setup tests/expected/hl-setup.json`
`git commit -m "hl: --hl selects the Hl platform (config, hl-ver, hlc, exceptions filter, no meta field)"`

---

### Task 2: Code model, dump and writer, checked by reading Haxe's `.hl` back

**Files:**
- Create: `src/hxc/codegen/hl/HlCode.hx`, `HlDump.hx`, `HlWriter.hx`
- Create: `tools/hl/HlReader.hx`, `tools/hl/HlRoundTrip.hx`, `tools/hl/roundtrip.sh`

**Interfaces:**
- Produces:
  - `enum HlType` with `hlcode.ml`'s `ttype` constructors and arguments, same names
    (`HVoid … HPacked(t:HlType)`); `HAbstract(name:String, nameIndex:Int)`.
  - `typedef HlClassProto`, `HlEnumProto`, `HlFieldProto`, `HlVirtualProto`: `hlcode.ml`'s records,
    fields in camelCase (`pname`, `pid`, `pclassglobal:Null<Int>`, `psuper:Null<HlClassProto>`, …).
    `pindex`, `pfunctions`, `pinterfaces` are lookups only (nothing in `genhl.ml`/`hlcode.ml`
    iterates them), so any map type does.
  - `enum HlOp`: `opcode`'s constructors, same names (`OMov(dst:Int, src:Int)`, …).
  - `typedef HlFunction` (`fundecl`): `fpath:{cls:String, name:String}`, `findex`, `ftype`, `regs:Array<HlType>`,
    `code:Array<HlOp>`, `debug:Array<{file:Int, line:Int}>`, `assigns:Array<{name:Int, reg:Int}>`.
  - `typedef HlCodeData` (`code`): `version`, `entrypoint`, `strings`, `bytes`, `ints`, `floats`,
    `globals`, `natives`, `functions`, `debugfiles`, `constants`.
  - `HlDump.tstr(t:HlType, ?detailed:Bool):String`, `HlDump.ostr(fstr:Int->String, o:HlOp):String`,
    `HlDump.dump(pr:String->Void, code:HlCodeData):Void`.
  - `HlWriter.write(code:HlCodeData, debug:Bool):haxe.io.Bytes`.
  - `HlReader.read(bytes:haxe.io.Bytes):{code:HlCodeData, debug:Bool}` (tools only).

- [ ] **Step 1: Make the reference files**

In a scratch folder, with Haxe 4.3.7, for each of `class P { static function main() {} }` (`-dce
full` and without) and `class Q { static function main() trace("hi"); }`: compile with `-D dump`,
once with `-D hl_no_opt` and once without, and once more with `-D hl_no_debug`. Keep each `.hl` and
its `dump/hlcode.txt`. Also copy JoeClash's existing `D:/_github/_JoeClash/bin/hashlink/game.hl`
(built by Haxe from `build.hxml`, `--debug`) with no dump; never build in the JoeClash checkout.
Expected: `.hl` files from about 54 KB (empty main) to several MB (JoeClash).

- [ ] **Step 2: Write `HlRoundTrip`**

`HlRoundTrip.main()` takes `<file.hl> [<hlcode.txt>]`: `HlReader.read` the file, `HlWriter.write`
it back with the same `debug` flag, and compare with the input. Prints `bytes ok <length>` or
`bytes differ at <offset> (ours <len>, theirs <len>)`. With a dump file, `HlDump.dump` into lines and
compare: `dump ok <lines>` or `dump differs at line <n>:` plus both lines. Exit 1 on any difference.
`roundtrip.sh <dir>` runs it on every `.hl` in `<dir>`, passing `<name>.hlcode.txt` beside it when
there is one: `haxe -cp src -cp tools/hl --run HlRoundTrip <file> [<dump>]`.

- [ ] **Step 3: Run it to see it fail**

Run: `tools/hl/roundtrip.sh <scratch folder>`
Expected: compile errors (`HlCode` etc. don't exist).

- [ ] **Step 4: Port `hlcode.ml` into `HlCode.hx` and `HlDump.hx`, `write_code` into `HlWriter.hx`, and write `HlReader.hx`**

The reader is the mirror of `write_code` (and of HashLink's `src/code.c` reader, at
`D:/_github/hashlink-full/src/code.c`, if a detail is unclear). Floats in the dump print as OCaml
prints them in `hlcode.ml` (`float_repres`-style; reuse hxc's existing OCaml float printing if there
is one). The dump's `objects protos` list comes from a `Hashtbl.fold` keyed by `pname`
(`hlcode.ml:647`): order it with `hxc.core.NameHash.HashTableOrder` and `NameHash.stringHash`, as
`CppGen.genResources` orders resource names.

- [ ] **Step 5: Run the round trip**

Run: `tools/hl/roundtrip.sh <scratch folder>`
Expected: `bytes ok` and `dump ok` for every file, JoeClash's included.

- [ ] **Step 6: Commit**

`git add src/hxc/codegen/hl tools/hl`
`git commit -m "hl: code model, -D dump text and .hl writer, checked by reading Haxe's .hl back"`

---

### Task 3: Test harness: `hl-output` family, `tests/hl/run.sh`, `tools/hl-compare.sh`

**Files:**
- Create: `tests/cases/hl-output/family.json`, `cases.hx.txt`, `fixture/HlDigest.hx`
- Create: `tests/hl/run.sh`, `tools/hl-compare.sh`
- Test: `tests/expected/hl-output.json`

**Interfaces:**
- Produces: `HlDigest.after(path:String)`; `tests/hl/run.sh --compiler <hxc> [--haxe <haxe>] [--hl <hl.exe>] [--case <pattern>] [-j <n>]`;
  `tools/hl-compare.sh <case dir> [extra args…]`, which prints the first differing dump section or function.
  Later tasks add cases to `tests/cases/hl-output/cases.hx.txt` only.

- [ ] **Step 1: Write the fixture and family**

`family.json`: `{"name":"hl-output","oracle":"haxe","kind":"compile-diff","cost":"quick","module":"P",
"args":["-cp",".","--main","$module","--hl","out.hl","-D","hl_no_opt","--macro","HlDigest.after('out.hl')"]}`.

`HlDigest.after(path)`: in `onAfterGenerate`, read the bytes, replace every occurrence of the case
directory (`Sys.getCwd()`, without the trailing slash, in `/` and `\` forms) with `$CASE` and of each
class-path entry that ends in `std/` (both forms) with `$STD`, then print
`== <path> <normalised length> <md5 of normalised bytes>`. The normalised bytes are only hashed, never
written.

First cases (they fail until Task 7): `empty-main` (`class P { static function main() {} }`),
`empty-main-dce-full` (`+ -dce full`), `trace-hello` (`trace("hi")`), `no-debug` (`trace("hi")
+ -D hl_no_debug`).

- [ ] **Step 2: Record Haxe's results**

Run the Task 1 Step 2 command with `--family hl-output`.
Expected: four entries in `tests/expected/hl-output.json`, each one line `== out.hl <n> <md5>`.

- [ ] **Step 3: Write `tests/hl/run.sh`**

Modelled on `tests/dotnet/run.sh`. It reads `tests/cases/hl-output/cases.hx.txt` with the family's
args. For each case: a fresh directory; compile with Haxe (`--haxe`, default `haxe`) into `h/` and
with hxc into `x/` and `y/` (twice); `cmp` `x/out.hl` with `y/out.hl` (else `nondeterministic`) and
with `h/out.hl` (else `differs from Haxe; see tools/hl-compare.sh`); then run `hl.exe h/out.hl` and
`hl.exe x/out.hl` and compare stdout and exit code (else `runs differently`). Print `ok <case>` or
the reason; exit 1 if any case fails.

- [ ] **Step 4: Write `tools/hl-compare.sh`**

Compile the case with both compilers and `-D dump` into separate directories. Compare the
`dump/hlcode.txt` files table by table (strings, ints, floats, globals, natives, then functions).
Functions are matched by their `; file:line (Class.method)` label, with `@N`/`fun@N` references
resolved to the names their tables give, so a function can match even while table numbering differs.
Print the first differing table entry, then `functions: <same>/<total> identical` and the first
differing function as a two-column diff. Also diff `dump/hl/*.dump` (the typed AST) and report the
first differing type, since a difference there is a typer/filter bug, not a generator one.

- [ ] **Step 5: Run them to see the expected failures**

Run: `neko run.n run … --family hl-output` → FAIL (hxc writes no `.hl`).
Run: `tests/hl/run.sh --compiler bin/hxc-windows-x64.exe` → each case `x/out.hl missing`.

- [ ] **Step 6: Commit**

`git add tests/cases/hl-output tests/expected/hl-output.json tests/hl tools/hl-compare.sh`
`git commit -m "hl: hl-output family, tests/hl/run.sh and tools/hl-compare.sh"`

---

### Task 4: Generator skeleton, type layer and the plain expressions

**Files:**
- Create: `HlContext.hx`, `HlTypes.hx`, `HlCasts.hx`, `HlAccess.hx`, `HlExpr.hx`, `HlFunctions.hx`, `HlGenerate.hx` (all in `src/hxc/codegen/hl/`)
- Move: `src/hxc/generators/cpp/CppFixOverrides.hx` → `src/hxc/codegen/FixOverrides.hx` (callers `CppGen.hx:41`, `CppiaGen.hx:538`)
- Modify: `src/hxc/Compiler.hx` (dispatch, after the dotnet branch)
- Test: `tests/cases/hl-output/cases.hx.txt`

**Interfaces:**
- Consumes: Task 2's `HlCode`/`HlDump`/`HlWriter`; Task 3's family and tools.
- Produces:
  - `HlGenerate.generate(ctx:hxc.context.Context):Void`: called as `platform == Hl` in the dispatch,
    logs `Generating hl: <file>`, timer `["generate","hl"]`; deletes an existing output file with the
    same extension first; runs `FixOverrides.fixOverrides` on every type; writes `dump/hlcode.txt` with
    `-D dump`; writes the `.hl` unless the file ends in `.c` (then reports `hl: HL/C output is not
    supported yet` — Plan 5); runs `haxelib run hashlink run "<file>"` with `-D run`.
  - `class HlContext` (the `genhl.ml` context record, field names camelCase), `HlLookup<K>` with
    `lookup(l, key, make:Void->V):Int` and `lookupAlloc(l, key, value):Int` (insertion order = index).
  - `HlTypes.toType(ctx, t:hxc.core.Type.T):HlType` and the other functions in the file table.
  - `HlExpr.evalExpr(ctx:HlContext, e:TExpr):Int` (returns the register), `HlCasts.evalTo(ctx, e, t:HlType):Int`.
  - **Placeholder for unported expressions** (removed in Task 6): an expression kind not ported yet emits
    `OThrow` of a fresh `OString "hl: unported <kind>"` register and records the function's label in
    `ctx.unported`; `generate` prints `hl: <n> functions use unported expressions` as a warning.
    This keeps the file writable so `hl-compare.sh` can count identical functions while the port is partial.

- [ ] **Step 1: Write the failing cases**

Add to `hl-output/cases.hx.txt` and record them (Task 1 Step 2 command, `--family hl-output`):
- `statics-strings`: static vars and functions, `Int`/`Float`/`Bool`/`String` arithmetic and
  comparisons, `Std.string`, string concatenation, `Sys.println`.
- `classes`: constructor with arguments, instance vars, methods, `super` calls, an override,
  a property with a getter.
- `control-flow`: `if`/`else`, `while`, `do … while`, `break`, `continue`, `for (i in 0...n)`, a nested
  loop, `return` from inside a loop.
- `strings-unicode`: `"héllo €"` and a string with a `\u{1F600}` escape printed with `Sys.println`, and
  their `.length`.

- [ ] **Step 2: Run to confirm they fail**

Run: `tests/hl/run.sh --compiler bin/hxc-windows-x64.exe --case "statics-*"` → `x/out.hl missing`.

- [ ] **Step 3: Port**

From `genhl.ml`: lines 139–1046 (helpers, context, types, allocs, registers, ops), the `HlCasts` and
`HlAccess` functions, `eval_expr`'s `TConst`, `TVar`, `TLocal`, `TReturn`, `TParenthesis`,
`TBlock`, `TCall` (super, static, member, plain), `TField` (incl. the `Array.length` case), `TNew`,
`TIf`, `TBinop` (arithmetic, comparison, bool `&&`/`||`, plain `=` assignment), `TUnop` (all but
`Spread`), `TWhile` (both), `TBreak`, `TContinue`, `TCast(_, None)` (both cases), `TMeta`, `TTypeExpr`,
`TIdent` (non-`$`), and `generate_static`, `generate_member`, `generate_type`,
`generate_static_init`, `add_types`, `build_code`, `generate` (minus `hl_check`/interp/HL/C).
`make_fun` without captures. Everything else goes through the placeholder.
Two `PMap.fold`s decide field order: over an anonymous type's `a_fields` (`genhl.ml:418`) and over a
class's `cl_fields` (`:565`). `PMap.fold` visits keys in increasing order
(`hxc.core.PMapOrder.sortedKeys` for `cl_fields`; the same name sort for `a_fields`), and consing in
the fold reverses that, so the list is in decreasing name order.

- [ ] **Step 4: Measure**

Run: `tools/hl-compare.sh` on each Step 1 case and on `empty-main`.
Expected: the string, int, float, globals tables identical for `statics-strings`, and every function
that has no placeholder identical (`functions: <same>/<total>`; record the numbers in the commit
message). The whole-file cases still fail; they pass at Task 7.

- [ ] **Step 5: Regression suites**

Run: hxc's own suite and `tests/dotnet/run.sh` (as Task 1 Step 5); `neko run.n run … --family cpp-output`
for the `FixOverrides` move. Expected: unchanged.

- [ ] **Step 6: Commit**

`git add -A src/hxc tests/cases/hl-output tests/expected/hl-output.json`
`git commit -m "hl: generator skeleton, type layer and plain expressions (N/M functions identical)"`

---

### Task 5: Objects, closures, arrays, switch and enums

**Files:**
- Modify: `HlExpr.hx`, `HlAccess.hx`, `HlFunctions.hx`, `HlCasts.hx`
- Create: `src/hxc/codegen/hl/HlAssign.hx`
- Test: `tests/cases/hl-output/cases.hx.txt`

**Interfaces:**
- Consumes: Task 4's `evalExpr`, `evalTo`, `HlLookup`, placeholder.
- Produces: `HlAssign.genAssignOp(ctx, op:Binop, e1:TExpr, e2:TExpr):Int`; `HlFunctions.makeFun` with
  captures; `HlFunctions.buildCaptureVars`, `genMethodWrapper`.

- [ ] **Step 1: Write and record the failing cases**

- `closures`: a local function capturing a loop variable and a modified outer local, a bound method
  closure `obj.method`, a static function as a value, a closure stored in a `Dynamic` and called.
- `anon-dynamic`: an anonymous object passed as a structure type and as `Dynamic`, `Reflect.field`,
  field reads/writes on `Dynamic`, a `Dynamic` call.
- `arrays`: `Array<Int>`, `Array<Float>`, `Array<String>`, `Array<Dynamic>`, `Array<P>`; `push`,
  index read/write, `a[i] += 1`, `for (x in a)`, `.map`, `.sort`.
- `enums-switch`: an enum with and without parameters, `switch` with captures and guards, `Type.enumIndex`,
  an `Int` switch with a default, a `String` switch.
- `compound-assign`: `+=`, `-=`, `*=`, `|=`, `<<=` on locals, fields, statics, array elements and
  properties; `x++`/`--x` on each.
- `interfaces-many`: one class implementing four interfaces and two classes implementing the same
  ones in a different order, called through each interface. (Pins table order, Review Focus 2.)
- `std-downcast`: `Std.isOfType`, `Std.downcast`, `Std.instance`, `Reflect.makeVarArgs`.

- [ ] **Step 2: Run to confirm they fail** — `tests/hl/run.sh --compiler bin/hxc-windows-x64.exe --case "<name>"`
  for each Step 1 case: `differs from Haxe`.

- [ ] **Step 3: Port** `eval_expr`'s `TFunction`, `TObjectDecl`, `TArrayDecl`, `TArray`, `TSwitch`,
  `TEnumParameter`, `TEnumIndex`, `TCast(_, Some _)`, the `Type.enumIndex`/`Reflect.makeVarArgs`/
  `Std.instance`/`Std.downcast` calls, `TBinop`'s compound assignments (`gen_assign_op`),
  `build_capture_vars`, `gen_method_wrapper`, and `make_fun`'s captured-variable paths.
  `build_capture_vars` orders the captured variables by a `PMap.fold` over `tvar` keys
  (`genhl.ml:3076`): OCaml compares the records structurally, `v_id` first, so the order is by
  variable id. hxc's ids must sort the same way as Haxe's for the closure's environment layout to
  match; if `closures` differs only there, fix the id assignment, not the generator.

- [ ] **Step 4: Measure** — `tools/hl-compare.sh` on the Step 1 cases and `empty-main`: every function
  without a placeholder identical; record `<same>/<total>`.

- [ ] **Step 5: Commit** — `git add -A src/hxc/codegen/hl tests/cases/hl-output tests/expected/hl-output.json`, then
  `git commit -m "hl: objects, closures, arrays, switch, enums (N/M functions identical)"`

---

### Task 6: Intrinsics, exceptions, natives and debug info; placeholder removed

**Files:**
- Create: `src/hxc/codegen/hl/HlIntrinsics.hx`
- Modify: `HlExpr.hx`, `HlFunctions.hx`, `HlGenerate.hx`
- Test: `tests/cases/hl-output/cases.hx.txt`

**Interfaces:**
- Consumes: everything above.
- Produces: `HlIntrinsics.evalIntrinsic(ctx, name:String, args:Array<TExpr>, e:TExpr):Int` for `$…`
  calls; `HlFunctions.makeDebug(ctx, positions):Array<{file:Int, line:Int}>`.

- [ ] **Step 1: Write and record the failing cases**

- `exceptions`: `throw` of a string, of a `haxe.Exception` subclass, of an `Int`; `catch (e:String)`,
  `catch (e:MyException)`, `catch (e:Dynamic)`, rethrow with `throw e`, `try` inside a loop with
  `break`, `e.stack` not printed (it holds paths), `e.message` printed.
- `hl-natives`: `hl.Bytes.alloc`/`setI32`/`getI32`, `hl.NativeArray<Int>` read/write/length,
  `hl.Ref<Int>` through a function taking `hl.Ref`, `hl.I64` arithmetic, a class with
  `@:hlNative("std")` and one with `@:hlNative("std", "prefix_")` empty methods (the `add_types`
  rewrite), `untyped $new`, `untyped $ref`.
- `int64-maps`: `haxe.Int64` arithmetic and `toString`, `Map<Int,String>`, `Map<String,Int>`,
  `haxe.ds.ObjectMap`, iteration over each.
- `debug-assigns + --debug`: locals reassigned in a loop and a closure capture, with `--debug`.
- `debug-paths + -cp sub`: the program's main class in a `sub/` class path, plus a helper class there.
- `resources + --macro haxe.macro.Context.addResource('b',haxe.io.Bytes.ofString('2')) --macro haxe.macro.Context.addResource('a',haxe.io.Bytes.ofString('1'))`:
  print `haxe.Resource.listNames()` and each `getString`. The `$resources` intrinsic walks
  `com.resources` with `Hashtbl.fold` (`genhl.ml:2001`): order the names with
  `hxc.core.NameHash.HashTableOrder` over `com.resourceOrder`, as `CppGen.genResources` does.

- [ ] **Step 2: Run to confirm they fail** — `tests/hl/run.sh --compiler bin/hxc-windows-x64.exe --case "<name>"`
  for each Step 1 case: `differs from Haxe`.

- [ ] **Step 3: Port** the `$` intrinsics (`genhl.ml` 1650–2058), `TThrow` (both), `TTry`,
  `TFor` (as `genhl.ml` does), the natives table and its sort in `generate`, `@:hlNative` handling in
  `add_types`, `make_debug`, `--debug` `assigns` and register holding (`hold`/`free`), and
  `-D absolute-path` (`genhl.ml:318`). Then delete the placeholder: an unported expression kind now
  reports `hl: unsupported expression <kind>` as an error at its position.

- [ ] **Step 4: Measure** — `tools/hl-compare.sh` on every `hl-output` case: `functions: M/M identical`
  and all tables identical. Fix differences here; a difference rooted in the typed AST dump goes to the
  typer or filters (with a case added to `hl-setup`'s `typed-dump` style).

- [ ] **Step 5: Commit** — `git add -A src/hxc/codegen/hl tests/cases/hl-output tests/expected/hl-output.json`, then
  `git commit -m "hl: intrinsics, exceptions, natives, debug info; no unported expressions"`

---

### Task 7: Whole-file identity and acceptance

**Files:**
- Modify: whatever the differences point at
- Modify: `README.md` (Status table: `--hl` row)
- Test: all `hl-output` cases, `hl-setup`, own suite, `.NET` suite

- [ ] **Step 1: Add the last cases and record them**

`generics-abstracts` (`@:generic` class, an abstract over `Int` with operators and `@:from`/`@:to`,
an `inline` function), `string-buf-math` (`StringBuf`, `Math.floor/sqrt/pow`, `Std.parseInt/parseFloat`,
float printing of `0.1`, `1e21`, `-0.0`, `Math.NaN`), `reflect-type` (`Type.getClassName`,
`Type.createInstance`, `Reflect.fields` on an anonymous object, `Type.typeof`).

- [ ] **Step 2: Run everything**

Run: `tests/hl/run.sh --compiler bin/hxc-windows-x64.exe`
Expected: `ok` for every case (identical to Haxe, identical across two compiles, same `hl.exe` output).
Run: `neko run.n run … --family hl-output,hl-setup`
Expected: PASS.

- [ ] **Step 3: Fix what differs**, with `tools/hl-compare.sh`, until Step 2 passes. A fix in the typer
  or filters gets an `hl-setup` case; a fix in the generator is covered by the case that found it.

- [ ] **Step 4: Regression suites** — own suite, `tests/dotnet/run.sh`, `cpp-output`: as before Task 1.

- [ ] **Step 5: README** — the `--hl` row moves out of "Accepted on the command line": `--hl x.hl`
  supported with `-D hl_no_opt` only; the optimiser (default) and HL/C (`.c`) not yet.

- [ ] **Step 6: Commit** — `git add -A src/hxc tests README.md`, then
  `git commit -m "hl: small programs byte-identical to Haxe 4.3.7 with -D hl_no_opt"`

- [ ] **Step 7: Rebuild the testing exe** — `haxelib run aedifex build cpp .` (the post-build hook
  copies it to `bin/hxc-windows-x64.exe`); confirm `bin/hxc-windows-x64.exe --hl` runs a case.
