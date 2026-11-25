# HashLink target, Plan 3: Haxe's unit suite on `hl.exe` (M4) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Haxe's unit suite (`haxe-conformance/tests/unit`), compiled by hxc with `compile-hl.hxml`, gives
a `unit.hl` byte-identical to Haxe 4.3.7's, and it runs on `hl.exe` exactly as Haxe's does. The
haxe-conformance harness checks both conditions in one command.

**Architecture:**
- A diagnosis script in hxc, `tools/hl-unit.sh`, compiles the suite with both compilers under `-D dump`
  and lists every function that differs. Tasks 3–5 use it to find each difference.
- A new corpus suite, `unit-hl`, goes in the haxe-conformance harness. It is the acceptance gate.
- Each difference gets fixed in hxc, with a case in `hl-output`.

**Tech Stack:** Haxe 4.3.7 (oracle and harness runtime), hxc (hxcpp build via aedifex), bash, neko, HashLink
2.0.0.

**Spec:** `docs/superpowers/specs/2026-11-08-hl-target-design.md`. The relevant sections are Goal 3,
"How it's checked" item 2 and Milestone M4.

## Where things stand (measured 2026-11-10 on `main` 2604a52d)

The build is compile-hl.hxml without `-D hl-check`, with the optimiser on.
- Both compilers compile the suite: Haxe in about 5 s, hxc in 12 s. hxc's `unit.hl` is 1 799 440 bytes,
  against Haxe's 1 799 389.
- Compared by `HlCompare` on `-D dump` builds:
  - strings: 10889/10890 identical. The only difference is the compile date (see Global Constraints).
  - floats: 43/149 identical; hxc's table has 150 entries.
  - functions: 8647/8671 identical, with one extra function in hxc.
  - every other table, objects/protos and constants: identical.
- The 24 differing functions have three causes:
  1. `unit/TestNumericSeparator.hx` `test`, `testWithSuffix` and `testJustBeforeSuffix`, plus the floats
     table. The HL generator reads a `TFloat` literal with `Std.parseFloat`, so `12.3_4` becomes `12.3`
     and `1_2.3_4` becomes `1`. hxc's eval already reads them right via `hxc.core.Numeric.parseFloatLit`.
     The call sites are `HlExpr.hx:63` and `HlFunctions.hx:249, 255, 287, 295`.
  2. `unit/issues/Issue6833.hx:5` `test`: an inline constructor (`KeyValueIterator` over
     `map.keys()`). hxc's registers r5/r6 are closures, typed `():virtual(...)`, where Haxe's are
     virtuals. Cause unknown.
  3. One extra anonymous function in hxc. Both compilers label these closures
     `C:/HaxeToolkit/haxe/std/hl/_std/Date.hx:0 (fun#)`, which means no real position. hxc has one more,
     which renumbers the 20 that follow (`#51`–`#71`). Cause unknown.
- Running on `hl.exe`: Haxe's `unit.hl` prints `START`, runs for about 0.6 s, then dies with
  `Uncaught exception: Null access` in `utest.ui.text.PrintReport._trace`. That is
  `PrintReport.hx:52`, the `haxe.Log.trace(s)` call, so `haxe.Log.trace` is null by the time the report
  prints. hxc's `unit.hl` dies the same way.
  - A small program shows that setting `haxe.Log.trace = null` and catching the `trace` works on this
    `hl.exe`, so `unitstd/haxe/Log.unit.hx`'s own `exc` check is not obviously the cause. Cause unknown.
  - Until it is found, no per-test result is visible on HL with either compiler.

## Global Constraints

- **Byte-identical output.** hxc's `unit.hl` is byte-identical to Haxe 4.3.7's from the same hxml, apart
  from the one compile-date string described in the next point. A difference is a bug until it is fixed
  or listed with a reason.
- **The compile date.** `unit.TestMain` traces `HelperMacros.getCompilationDate()`, a 19-character
  `YYYY-MM-DD hh:mm:ss` string in the strings table, so two Haxe builds differ there too. Comparisons
  ignore exactly one same-length window of differing bytes, provided both sides match
  `\d{4}-\d\d-\d\d \d\d:\d\d:\d\d` there. Any other difference counts.
- **Build command:** `compile-hl.hxml` with every line containing `hl-check` removed, run from
  `tests/unit`. That keeps `-D hl-ver=1.13.0`, `--debug`, `--dce full`, `-lib utest` and the optimiser.
  It is the same command line for both compilers.
  - `HAXE_STD_PATH` is set to the same value for both compilers. Its spelling, `/` against `\`, ends up
    in the debug file table.
- **Pass bar** (from the spec):
  - `unit.hl` is identical in the sense above;
  - running hxc's `unit.hl` on `hl.exe` 2.0.0 gives the same exit code and the same output as Haxe's,
    once the `Generated at:` line is dropped. Failures Haxe has too are noted, not fixed.
- **Branches:**
  - hxc work happens on `hl-unit`, from `main` 2604a52d, in the worktree
    `D:/_github/hxc/.claude/worktrees/hl-unit`. Never work in `D:/_github/hxc` itself.
  - Harness work happens in `D:/_github/haxe-conformance`, on a new local branch `hl-unit` from
    `4349f29`. That checkout is detached today. Change only `harness/`, `run.n` and `README.md` there;
    `tests/` stays unchanged.
  - Commits stay local. The user pushes.
- **Building hxc.**
  - The worktree is ready: `bin/cpp` is seeded from the main checkout and `thirdparty/libuv` is
    checked out.
  - Build with `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex haxelib run aedifex build cpp .` from the
    worktree root. The post-build hook copies the result to `bin/hxc-windows-x64.exe`.
  - The first build of a task comes before its first measurement.
- **Public repos.** No private app names in anything committed (contents, file or case names, commit
  messages). The controller gives the check command.
- **Tools.**
  - `hl.exe` is at `C:/SDKs/hashlink/hl.exe` (2.0.0).
  - Haxe is at `C:/HaxeToolkit/haxe/haxe.exe`.
  - utest is the installed git checkout (`a055e05`).
  - Every hxc compile needs `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std`.
- **Suites stay green** at the end, all on `main`'s counts:
  - own suite: 255 checked, 0 failed;
  - `.NET`: 736/736;
  - `tests/hl/run.sh`: `hl-output` 33/33 plus the new cases, `hl-opt` 39/39.

  Never run two suites, or two unit-suite builds, at once.

## Review Focus

1. **The date mask hides a real difference.** A mask wider than the date, or one applied to a
   different-length file, would pass a wrong `unit.hl`. Task 2 tests that one changed byte outside the
   date window fails, and that a length difference fails.
2. **A stale `unit.hl` from an earlier run is compared.** If a compile fails and `bin/unit.hl` is left
   over from the run before, the check would compare old output. Task 2 deletes it before each compile,
   and a failed compile reports FAIL with the compiler's exit code.
3. **`hl.exe` is missing or not where it is expected.** The suite should fail with a message naming the
   path, not crash or report PASS. Task 2 tests a wrong `--hl-exe`.
4. **Float literals the suite doesn't cover.** Exponents with separators, a leading `.`, `f64` after `_`,
   negative literals, and an `Int`-typed field given a float literal (the `HlFunctions` call sites)
   should all read the way the lexer means. Task 3's case covers each form.
5. **`unit-hl` without `--haxe`.** It has nothing to compare against, so it should stop with a clear
   message rather than report PASS. Task 2 tests it.

## File Structure

| File | Task | Responsibility |
|---|---|---|
| `tools/hl/HlCompare.hx` (hxc) | 1 | `--all` lists every differing function |
| `tools/hl-unit.sh` (hxc) | 1 | builds the unit suite with both compilers under `-D dump`, compares, runs both |
| `harness/Corpus.hx`, `harness/Harness.hx` (haxe-conformance) | 2 | `unit-hl` suite and `--hl-exe` |
| `harness/UnitHl.hx` (haxe-conformance) | 2 | the build, date-masked compare and run of `unit-hl` |
| `run.n`, `README.md` (haxe-conformance) | 2 | rebuilt runner and its docs |
| `src/hxc/codegen/hl/HlExpr.hx`, `HlFunctions.hx` | 3 | float literals read with `Numeric.parseFloatLit` |
| wherever Tasks 4–5 find the cause | 4, 5 | the Issue6833 and extra-closure fixes |
| `tests/cases/hl-output/cases.hx.txt`, `tests/expected/hl-output.json` | 3–5 | one case per fix |
| `tests/hl/README.md` or the spec's divergence list | 6 | the `Log.trace` finding |
| `README.md` (hxc) | 7 | the `--hl` row mentions the unit suite |

---

### Task 1: Diagnosis tools: `HlCompare --all` and `tools/hl-unit.sh`

**Files:**
- Modify: `tools/hl/HlCompare.hx`
- Create: `tools/hl-unit.sh`

**Interfaces:**
- Produces:
  - `haxe -cp tools/hl --run HlCompare [--all] <expected dir> <actual dir>`. With `--all` it prints one
    line `differs: <label>` for every function whose body differs, before the existing
    `first differing function:` block. Without it, the output is unchanged.
  - `tools/hl-unit.sh [<haxe-conformance dir>]`. The default directory is `D:/_github/haxe-conformance`.
    The environment variables are `HXC` (default `bin/hxc-windows-x64.exe`), `HAXE` (default `haxe`) and
    `HAXE_STD_PATH` (default `C:/HaxeToolkit/haxe/std`, exported for both compilers). It works under
    `<hxc>/.hl-unit/` (gitignored):
    - writes `compile-hl.hxml` minus its `hl-check` lines as `.hl-unit/compile.hxml`;
    - in `<dir>/tests/unit`, deletes `bin/unit.hl` and `dump/`, compiles with Haxe plus `-D dump`, and
      moves `bin/unit.hl` and `dump/` to `.hl-unit/h/`;
    - does the same with hxc into `.hl-unit/x/`. A failed compile prints its log and exits 2;
    - runs `HlCompare --all .hl-unit/h .hl-unit/x`;
    - runs each `unit.hl` on `hl.exe` (`HL`, default `C:/SDKs/hashlink/hl.exe`) into
      `.hl-unit/{h,x}.run.txt`;
    - prints `runs: same` or `runs: differ` after dropping each file's `Generated at:` line.
  - It leaves no `dump/` or `bin/unit.hl` behind in `tests/unit`.

- [ ] **Step 1:** Add `--all` to `HlCompare`. Check that `tools/hl-compare.sh` on any hl-output case still
  prints exactly what it did.
- [ ] **Step 2:** Write `tools/hl-unit.sh`, and add `.hl-unit/` to `.gitignore`.
- [ ] **Step 3:** Build this branch (still `main`'s code) and run the script. Expected:
  - `functions: 8647/8671 identical`;
  - 24 `differs:` lines, as listed under "Where things stand";
  - `floats: 43/149 identical (150 in the second)`;
  - one string difference, the date;
  - `runs: same`.
  Paste the summary lines into the report.
- [ ] **Step 4: Commit.** `git add tools/hl/HlCompare.hx tools/hl-unit.sh .gitignore`, then
  `git commit -m "hl: tools/hl-unit.sh compares Haxe's unit suite built by both compilers"`

### Task 2: The harness `unit-hl` suite

All work happens in `D:/_github/haxe-conformance`. First run
`git switch -c hl-unit 4349f29`.

**Files:**
- Create: `harness/UnitHl.hx`
- Modify: `harness/Corpus.hx`, `harness/Harness.hx`, `README.md`, `run.n`

**Interfaces:**
- Produces:
  - `haxelib run haxe-conformance corpus unit-hl --compiler <exe> --haxe <haxe> [--std <path>] [--hl-exe <path>]`.
    Inside hxc, the equivalent is `neko run.n corpus unit-hl ...`.
  - `unit-hl` is not in `Corpus.all`, so it runs only when named.
  - `--hl-exe` defaults to `hl` on `PATH`.
  - `UnitHl.sameExceptDate(a:haxe.io.Bytes, b:haxe.io.Bytes):Bool`: true when the lengths are equal and
    all differing bytes fall inside one 19-byte window that matches
    `\d{4}-\d\d-\d\d \d\d:\d\d:\d\d` on both sides.
  - `UnitHl.run(...)` returns a `Corpus.SuiteResult`. Its `note` is one of:
    - `unit.hl identical; runs as Haxe's does (exit N)`
    - `the compiler failed (exit N)`, or `Haxe failed (exit N)`
    - `unit.hl differs from Haxe's at byte K`
    - `runs differently from Haxe's`
    - `--haxe is required`
    - `hl.exe not found: <path>`
- How a run works:
  - The build command is the one in Global Constraints, written to a temp hxml outside `tests/`.
  - Haxe compiles first, then the compiler, each with `bin/unit.hl` deleted beforehand.
  - Each `unit.hl` is copied to a temp directory.
  - Both are run on `hl.exe`, and their exit codes and outputs (without the `Generated at:` line) are
    compared.
  - The temp directory is removed at the end.

- [ ] **Step 1: Tests first.** Add `harness/UnitHlCheck.hx`, run with `haxe -cp harness --run UnitHlCheck`.
  It asserts:
  - identical bytes → true;
  - only a date window differs → true;
  - a date plus one other byte → false;
  - one byte outside any date → false;
  - different lengths → false;
  - a differing window that isn't a date on both sides → false.
- [ ] **Step 2:** Implement `UnitHl`, the `unit-hl` step in `Corpus.run`, the `--hl-exe` option and the
  README rows.
- [ ] **Step 3:** Rebuild the runner with `haxe -cp harness -main Harness -neko run.n`. Check that
  `neko run.n` with no arguments still prints the usage.
- [ ] **Step 4: Behaviour checks.** Expect each of these:

  | Run | Expected |
  |---|---|
  | `--compiler C:/HaxeToolkit/haxe/haxe.exe --haxe C:/HaxeToolkit/haxe/haxe.exe` | PASS (Haxe against itself) |
  | hxc's `main` exe against Haxe | FAIL, `unit.hl differs from Haxe's at byte K` |
  | without `--haxe` | `--haxe is required` |
  | `--hl-exe D:/nope/hl.exe` | `hl.exe not found: D:/nope/hl.exe` |
  | a compiler that exits 1 (e.g. a stub `.cmd`) | `the compiler failed (exit 1)`, with no compare of a stale file |

  Also check that `git status` in `tests/` stays clean after each run.
- [ ] **Step 5:** Run `neko run.n run --compiler C:/HaxeToolkit/haxe/haxe.exe --family cli-nothing-to-compile`
  (or any small family) to show `run` is unaffected.
- [ ] **Step 6: Commit** in haxe-conformance:
  `git add harness README.md run.n`, then
  `git commit -m "corpus unit-hl: Haxe's unit suite on HashLink, byte-compared with Haxe and run on hl.exe"`

### Task 3: Float literals in the HL generator

**Files:**
- Modify: `src/hxc/codegen/hl/HlExpr.hx:63`, `src/hxc/codegen/hl/HlFunctions.hx:249, 255, 287, 295`
- Test: `tests/cases/hl-output/cases.hx.txt`, `tests/expected/hl-output.json`

**Interfaces:**
- Consumes: `hxc.core.Numeric.parseFloatLit(s:String):Float`, which strips the `_` separators. It is what
  eval uses, and genhl's `float_of_string` does the same.

- [ ] **Step 1:** Add the hl-output case `float-separators`, recorded with Haxe 4.3.7. It traces each of
  these, and stores some in fields: an `Int` field and `hl.UI8`/`hl.UI16` fields, so that
  `HlFunctions`' constant-to-field paths run.
  - `12.3_4`, `1_2.3_4`, `.3_4_5`, `1_2e3_4`, `1_2.3e4_5`;
  - `12.3_4f64`, `12.3_4_f64`, `-1_0.5`.
- [ ] **Step 2:** Run `tests/hl/run.sh --family hl-output --case float-separators`. Expect FAIL, with
  `differs from Haxe`.
- [ ] **Step 3:** Replace the five `Std.parseFloat(s)` calls with `hxc.core.Numeric.parseFloatLit(s)`.
- [ ] **Step 4:** Rebuild. The case should pass, and in `tools/hl-unit.sh`:
  - floats are identical;
  - the three `TestNumericSeparator` functions are gone from the `differs:` list.
- [ ] **Step 5: Commit.** `hl: float literals with numeric separators read as genhl's float_of_string does`

### Task 4: `Issue6833`: inline constructor over `map.keys()`

**Files:**
- Modify: wherever the cause is.
- Test: a hl-output case named after the behaviour, not after the issue number.

- [ ] **Step 1:** Reduce `unit/issues/Issue6833.hx` to a standalone hl-output case. Check with
  `tools/hl-compare.sh` (and `HL_OPT=1`) that it shows the same r5/r6 difference.
- [ ] **Step 2:** Find the cause.
  - `hl-compare.sh` also compares the typed AST, `dump/hl/*.dump`. If that differs, the bug is in hxc's
    typer, inliner or filters; follow Haxe's `inlineConstructors.ml`/`inline.ml`.
  - If the typed AST is identical, the bug is in genhl's port; follow the `TField`/`FClosure` arms of
    `genhl.ml`.
  - State the root cause in the commit message.
- [ ] **Step 3:** Fix it. The case should pass, and its function should be gone from
  `tools/hl-unit.sh`'s list.
- [ ] **Step 4:** If the fix is outside `src/hxc/codegen/hl`, run the own suite and the .NET suite before
  committing.
- [ ] **Step 5: Commit.**

### Task 5: The extra position-less closure

**Files:**
- Modify: wherever the cause is.
- Test: a hl-output case.

- [ ] **Step 1:** Identify hxc's extra function.
  - In `.hl-unit/x/dump/hlcode.txt`, the `Date.hx:0 (fun$N)` functions are matched to Haxe's in order.
    Find the first whose body has no counterpart.
  - Find who creates it: the `OClosure`/`OInstanceClosure` referring to its index, then the enclosing
    function's label.
- [ ] **Step 2:** Reduce that to a standalone hl-output case that shows one extra function, and find the
  cause. Haxe makes these closures in genhl as wrappers, for example `make_fun` for method
  closures, enum constructor closures and `Reflect`/dynamic call wrappers.
- [ ] **Step 3:** Fix it. `tools/hl-unit.sh` should then print `functions: 8671/8671 identical` with no
  `only in the second` line.
- [ ] **Step 4: Commit.**

### Task 6: Why the unit suite ends with `haxe.Log.trace` null on HL

**Files:**
- Modify: `tests/hl/README.md` (findings).
- Possibly modify: `harness/UnitHl.hx`, `README.md` and `run.n` in haxe-conformance, only for the
  workaround described in Step 3.

- [ ] **Step 1:** Find the test that leaves `haxe.Log.trace` null. Use Haxe's own build, so the answer
  doesn't depend on hxc.
  - One way: an extra `--macro` on both command lines that wraps `haxe.Log.trace`'s setter. Another:
    compile with `-D UTEST_PRINT_TESTS`, which utest supports, to see which test runs last before the
    crash.
  - Time-box this to about an hour of investigation.
- [ ] **Step 2: Record the finding.** In `tests/hl/README.md`, under "Unit suite", record:
  - which test leaves `haxe.Log.trace` null;
  - why, on `hl.exe` 2.0.0;
  - that it happens with Haxe's own `unit.hl` too.
  If the cause is not found within the time-box, record what was ruled out.
- [ ] **Step 3: Optional workaround.** Use it only if a change on the harness side alone makes per-test
  results visible for both compilers, with tests/ unchanged and the same arguments added to both command
  lines (e.g. a define that utest reads). Make that change in `UnitHl`, and have it print the number of
  failing tests for each compiler. Otherwise the run comparison stays as Task 2 built it.
- [ ] **Step 4: Commit** in each repo that changed.

### Task 7: Acceptance

- [ ] **Step 1:** `tools/hl-unit.sh` prints identical tables and functions, apart from the date string,
  and `runs: same`.
- [ ] **Step 2:** The harness's `corpus unit-hl` against Haxe (with `--compiler` set to this branch's exe)
  gives PASS.
- [ ] **Step 3:** Run the regression suites one at a time, with the counts from Global Constraints:
  - `tests/hl/run.sh` for `hl-output` and for `hl-opt`;
  - the own suite (`neko run.n run ... -j 4 --std C:/HaxeToolkit/haxe/std`);
  - `.NET`.
- [ ] **Step 4:** In the hxc `README.md`, add to the `--hl` row that Haxe's unit suite (`compile-hl.hxml`)
  gives an identical `unit.hl`, checked with haxe-conformance's `corpus unit-hl`.
- [ ] **Step 5: Commit.**
  - `git add README.md tests/hl/README.md`
  - `git commit -m "hl: Haxe's unit suite gives a byte-identical unit.hl"`
- [ ] **Step 6:** Rebuild the testing exe. Then `find src -newer bin/hxc-windows-x64.exe -type f` prints
  nothing.
