# HashLink (`--hl`) target: design

Date: 2026-11-08
Status: ready for review by the person driving this

## Intent

hxc accepts `--hl` today and writes nothing. This adds the HashLink backend: HL bytecode (`.hl`)
and HL/C (`.c` sources plus `hlc.json`), ported from Haxe 4.3.7's own HL generator so that hxc's
output is **byte-identical** to Haxe 4.3.7's for the same source and command line.

### Why

The driving project is **JoeClash** (`D:\_github\_JoeClash`), a Heaps game that already ships on
HashLink with Haxe 4.3.7:

- desktop: `build.hxml` writes `bin/hashlink/game.hl` with `--debug -dce full`, using heaps,
  hlsdl, loreline, haxeui-core, haxeui-heaps and epubreader, and the `ReaderFontSync.sync()` macro.
  `build.dev.hxml` and `build.cheat.hxml` add defines on top of it.
- Android: `build.android.hxml` writes HL/C to `bin/android/c/main.c` (adding heaps-android and
  `-D hl-no-audio`). `HlcPrune` then reads the `hlc.json` that compile wrote, and
  `haxelib run heaps-android` packages the APK.
- size: `src/` is 163 files, about 59k lines, before Heaps and haxeui.

JoeClash on `--hl` is the same kind of test as the Kha work (hxc branch `cpp-kha`): the same source
through Haxe 4.3.7 and through hxc must give identical output, and any difference is an hxc bug,
fixed in hxc with a conformance case.

Whether JoeClash's real builds later switch to hxc is **undecided**. It doesn't change this design:
identical output makes switching free later.

## Goals

1. `--hl out.hl` writes a `.hl` file byte-identical to Haxe 4.3.7's, with and without `--debug`,
   with the optimiser (`hlopt`) on and with `-D hl_no_opt`.
2. `--hl out.c` writes HL/C sources and `hlc.json` identical to Haxe 4.3.7's (file for file, as with
   `--cpp` for Kha).
3. Haxe's own unit suite (`haxe-conformance/tests/unit`), compiled by hxc with `--hl`, passes on
   `hl.exe`, the way Haxe's CI runs it.
4. JoeClash: `build.hxml` (desktop) and `build.android.hxml` (HL/C) give identical output through
   both compilers, and hxc's `game.hl` runs on `hl.exe` and plays.

## Non-goals

- **No HL interpreter.** `hlinterp.ml` (about 100 KB, used by Haxe for `--interp`-style HL runs and
  `-D hl_check`'s checks) isn't ported. `hl.exe` runs the output.
- Not building the APK or running it on a phone. Goal 4 stops at identical HL/C plus `hlc.json`.
  Running the HL/C build through heaps-android is a separate step.
- No HashLink versions or bytecode formats beyond what Haxe 4.3.7 itself writes.
- No speed work on the generated code. Identical output means identical speed.

## Anti-goals (a failure even if it runs)

- **Output that only "works".** A `.hl` that runs but differs from Haxe's doesn't meet the goal. A
  difference stays a bug until it's fixed or listed as a known divergence with a reason.
- Breaking any other target. hxc's own suite and the .NET suite (736/736 at `cpp-kha`'s tip) must
  stay green.
- Text in the public hxc repo that names the private apps (see the repo's rules: "the server app",
  "the desktop app").

## Constraints

- **Reference:** Haxe 4.3.7 (tag `4.3.7`, commit `e0b355c`), `src/generators/`: `genhl.ml`
  (130 KB), `hlcode.ml` (24 KB), `hlopt.ml` (33 KB), `hl2c.ml` (61 KB). The JVM port grew from
  229 KB of OCaml to 288 KB of Haxe (about 7.8k lines), so expect roughly 6–7k lines for the
  bytecode path and about 2k more for HL/C.
- **Oracle:** the installed Haxe 4.3.7 (`C:\HaxeToolkit\haxe`) and the Haxe 4.3.7 std, as for every
  other hxc target.
- **Runtime:** HashLink at `C:/SDKs/hashlink` (`hl.exe` reports 2.0.0). Haxe 4.3.7's default
  `hl-ver` is 1.10.0; JoeClash's main builds don't set it (only `buildDirectx.hxml` sets 1.16.0).
- **Defines that change output** (from `genhl.ml`): `hl_no_opt` (turns `hlopt` off), `hl_no_debug`
  (leaves debug info out; it's written by default, not just with `--debug`), `hl-ver`,
  `absolute-path`, `source-header` (HL/C header text), `dump`. `hl_check` needs the interpreter,
  so it's out (see Non-goals).
- **Heaps runs a lot of macros.** hxsl shaders are compiled and serialised by build macros at
  compile time, and haxeui-heaps adds its own. Those run in hxc's eval interpreter and must produce
  the same data as Haxe's eval, or `game.hl` differs.
- **The typed AST has to match too.** Byte-identical output needs hxc's typer, filters and analyzer
  to give genhl the same input as Haxe does (temp names, inlining, ordering). The Kha work needed
  three typer fixes for this. Expect more, especially from code that only HL builds use (the
  `std/hl/_std` overlay, `hl.*` types).
- **Branch:** start from `kha-port` (`ce5ea5cb`, unpushed), not `main`. It holds the typer fixes
  from the Kha work (`==`/`!=` cast-first, implicit `super()` at constructor typing, merging a
  property compound assignment's receiver bind), which JoeClash's output will need. *(My call.)*

## Decided

- **Port, don't redesign.** Follow `genhl.ml`, `hlcode.ml`, `hlopt.ml` and `hl2c.ml` closely, as the
  JVM port followed `genjvm.ml`. Byte-identical output leaves little room to do it differently, and
  a close port keeps differences easy to find.
- **HL/C is in this project**, as the last milestone (M6), after `.hl` works. *(Confirmed by the
  person driving this.)*
- **How it's checked:**
  1. A new `hl-output` family in hxc's own suite (`tests/cases/hl-output`, `oracle: haxe`,
     `kind: compile-diff`), shaped like `cpp-output`. Small programs whose `.hl` (and later HL/C)
     must match Haxe 4.3.7's recording. Every difference fixed in hxc gets a case here.
  2. Haxe's unit suite compiled with `--hl` and run on `hl.exe`. Today the haxe-conformance
     harness (`harness/Corpus.hx`) only runs `unit` through `compile-macro.hxml`, so this needs a
     target option in the harness. It goes in the haxe-conformance repo, in `harness/` only;
     `tests/` stays unchanged. Haxe's `tests/unit/compile-hl.hxml` sets `-D hl-check` (needs the
     interpreter, see Non-goals) and `-D hl-ver=1.13.0`. The harness drops `hl-check` for both
     compilers and keeps the rest. *(My call.)*
     **Pass bar** (as Goal 1 asks): hxc's `unit.hl` is byte-identical to Haxe 4.3.7's from the same
     hxml, and running it on `hl.exe` 2.0.0 fails only where Haxe's own `unit.hl` fails on the same
     `hl.exe` (the corpus `--haxe` mode). Failures Haxe has too are noted, not fixed. *(My call.)*
     **Where it runs:** the `hl-output` cases compare with recordings, so they run in hxc's GitHub
     CI like the other families. Anything that needs `hl.exe` (unit suite, JoeClash) runs only on
     this machine; adding HashLink to the CI runners isn't part of this. *(My call.)*
  3. JoeClash's `build.hxml` and `build.android.hxml`, compared output to output with Haxe 4.3.7.
     The game is played once from hxc's `game.hl`.
- **Milestones, in order** (each ends with its checks green):
  - **M1:** the `.hl` writer and the code tables, plus classes, statics, strings, `trace` and
    `Std`, with `-D hl_no_opt`. Hello world matches byte for byte.
  - **M2:** enums, closures (bound and static), virtuals and anonymous objects, `Dynamic`,
    exceptions, `hl.*` native types (`hl.Bytes`, `hl.NativeArray`, `hl.Ref`, `hl.I64`,
    `@:hlNative`), and debug info.
  - **M3:** `hlopt`, so the default (optimised) output matches.
  - **M4:** the unit suite passes on `hl.exe`.
  - **M5:** JoeClash `game.hl` matches and plays.
  - **M6:** HL/C (`hl2c.ml`) plus `hlc.json`; small cases, then JoeClash's Android build matches.
- **Running the result** follows Haxe: `--hl x.hl` with `-D run`/`--cmd` behaves as Haxe does;
  HL/C without `no-compilation` runs `haxelib run hashlink build`, as `genhl.ml` does.

- **Platform hookup is early work.** `--hl` is parsed in `src/hxc/Compiler.hx` (around line 810)
  but doesn't select the `Hl` platform fully, and little outside `Setup.hx` checks for `Hl`
  (std overlay, defines, forbidden packages, the analyzer's per-platform settings). M1 starts there.

## Left to the builder

- The module layout under `src/hxc/codegen/hl/` (or `generators/`), and how the port splits
  `genhl.ml` into files.
- How table ordering (types, globals, strings, functions) is made to match Haxe's. Haxe's order
  comes from first use and from its map iteration; `hxc.core.PMapOrder` already deals with the same
  problem elsewhere.
- Which unit-suite failures get fixed now and which become listed divergences, with a reason each.
- Tooling: a script that builds a case with both compilers and shows the first differing function
  (a `.hl` dump, like Haxe's `--dump`), and a JoeClash compare script like `tools/kha-compare.ps1`.
- Any README/`Status` table update when a milestone lands.
