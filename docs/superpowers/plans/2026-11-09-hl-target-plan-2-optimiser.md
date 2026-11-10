# HashLink target, Plan 2: the optimiser (`hlopt`) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `hxc --hl out.hl` with the optimiser on (the default, no `-D hl_no_opt`) writes `.hl` files
byte-identical to Haxe 4.3.7's for the Plan 1 programs plus programs aimed at the optimiser, and with
`-D dump` writes the same `dump/hlopt.txt`.

**Architecture:** a close port of Haxe 4.3.7's `hlopt.ml` into `src/hxc/codegen/hl/`. It has two files:
- `HlOpcodes.hx`: the per-opcode tables (`control`, `opcode_fx`, `opcode_map`, `opcode_eq`);
- `HlOpt.hx`: the block graph, the alias/null-check propagation, liveness, nop removal, the register
  remap and the dump.

`HlFunctions` calls it on each function as `genhl.ml` does. `hlopt.ml`'s per-function cache is dead code
in 4.3.7 (its `opt_cache := PMap.add …` is commented out, so every lookup misses), so it is not ported.
Turning the optimiser on also runs `genhl.ml`'s optimise-only allocator paths (`alloc_tmp`, `hold`,
`free`, `mallocs`). Those were ported in Plan 1 but no case has run them yet.

**Tech Stack:** Haxe 4.3 (hxc is self-hosting; built with
`AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex haxelib run aedifex build cpp .`), Haxe 4.3.7 at
`C:\HaxeToolkit\haxe` as the oracle, HashLink at `C:/SDKs/hashlink/hl.exe` (2.0.0), and the
haxe-conformance harness (`D:\_github\haxe-conformance`, `neko run.n`).

**Spec:** `docs/superpowers/specs/2026-11-08-hl-target-design.md` (milestone M3). Plan 1:
`docs/superpowers/plans/2026-11-08-hl-target-plan-1-bytecode.md`.

**Reference source:** Haxe tag `4.3.7`, `src/generators/hlopt.ml` (1103 lines), and `genhl.ml`:
- `alloc_tmp`, `hold`, `free` (lines 795–850);
- the call site (lines 3294–3300);
- `create_context` (lines 3990–3991).

Get it from `https://codeload.github.com/HaxeFoundation/haxe/tar.gz/refs/tags/4.3.7` into a scratch
folder, never into the repo.

## Global Constraints

- **Byte-identical output.** Output must be byte-identical to Haxe 4.3.7's for the same source and
  command line. A difference is a bug until it is fixed, or listed with a reason.
- **Branch.** Work on branch `hl-opt` from `c5f9545e` (`kha-port` with Plan 1 merged). Commits stay
  local; the user pushes.
- **Public repo.** No private app names in anything committed: file contents, file names, case names
  or commit messages. The controller gives the check command with each task. The commit author is the
  repo-local noreply address; don't change git config.
- **Imports.** `HlCode.hx`, `HlDump.hx`, `HlWriter.hx` and the new `HlOpcodes.hx` and `HlOpt.hx`
  import nothing from hxc outside `hxc.codegen.hl`, so the check tools can run them under
  `haxe --run`. The timer stays at the call site in `HlFunctions`.
- **Optimiser switch.** The optimiser runs unless `hl_no_opt` is defined (`create_context`). It runs on
  a function when `ctx.optimize && (gen_content = None || name <> ("",""))`, under the timer
  `["generate";"hl";"opt"]`.
- **Dump.** `-D dump` makes Haxe open `dump/hlopt.txt` at context creation and write one block per
  optimised function into it. With `hl_no_opt` the file stays empty, which Plan 1 already does.
- **OCaml evaluation order.** OCaml evaluates constructor and list-literal arguments right to left.
  In `code_graph`:
  - `[goto 0; goto d]` makes the `d` block first;
  - `goto 0 :: Array.to_list (Array.map goto pl)` maps the switch cases, in index order, before `goto 0`.

  Each `goto` conses onto `bprev`. `bprev` order decides which predecessor's state `propagate` reuses,
  and the order in which the assigns remap gathers.
- **Sorts.** OCaml `List.sort` is a stable merge sort, used on the remapped assigns, keyed by position.
- **Suites stay green:**
  - own suite: 202 checked, 0 failed at `c5f9545e`;
  - `.NET`: 736/736;
  - `tests/hl/run.sh` on `hl-output`: 27/27.

  `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std` for every hxc compile.

## Review Focus

1. **Very large functions.** Macro-built code in Heaps (hxsl) and haxeui produces functions with
   thousands of ops and blocks. `code_graph`'s `make_block`, `get_state` and `live` recurse once per
   block. Expected: they finish and match Haxe; no stack overflow in the hxcpp build. Pinned by the
   `opt-long-function` case (Task 4).
2. **Predecessor order.** It comes from OCaml's right-to-left argument evaluation (Global Constraints).
   Expected: the same `bprev` order as Haxe, so the same reused state and the same remapped assigns.
   Pinned by `opt-switch` and `opt-trycatch` (Task 1) through the `hlopt.txt` comparison (Task 3).
3. **Variable names after nops are removed.** `remap_fun` moves each assign whose op became a nop to
   the last write of the same value, or to an argument (`-reg-1`), then stable-sorts by position.
   Expected: the same debug assigns, and `hl.exe` shows the same locals. Pinned by `opt-assigns` (Task
   1) and its `--debug` twin `opt-assigns-debug` (Task 4).
4. **Exceptions.** Nested `try`, a `throw` inside `catch`, and an `OEndTrap true` that survives as
   unreachable code (the "unreachable" pass skips it). Expected: identical. Pinned by `opt-trycatch`
   (Task 1).
5. **The register type cache.**
   - `mallocs` is keyed by HL type through `HlTypes.typeKey`.
   - For virtuals, the key is fixed when the entry is inserted, while OCaml's `PMap` compares the live,
     mutable proto.
   - Expected: temporaries of anonymous-structure and closure types are reused exactly as Haxe reuses
     them.

   Pinned by `opt-temps` (Task 1), which mixes anonymous objects, closures and nested calls.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `src/hxc/codegen/hl/HlOpcodes.hx` | new: `HlControl` enum, `control`, `opcodeFx`, `opcodeMap`, `opcodeEq` (`hlopt.ml` lines 29–438) |
| `src/hxc/codegen/hl/HlOpt.hx` | new: block graph, `_optimize`, `remap_fun` with its dump, `optimize` entry (`hlopt.ml` lines 440–1097) |
| `src/hxc/codegen/hl/HlFunctions.hx` | call `HlOpt.optimize` at the end of `makeFun` (genhl 3294) |
| `src/hxc/codegen/hl/HlContext.hx` | `dumpOut:Null<StringBuf>` (genhl `dump_out`) |
| `src/hxc/codegen/hl/HlGenerate.hx` | drop the `NO_OPTIMISER` refusal; write `dumpOut` to `dump/hlopt.txt` |
| `tests/cases/hl-opt/` | new family: same shape as `hl-output`, without `-D hl_no_opt` |
| `tests/expected/hl-opt.json` | its recording from Haxe 4.3.7 |
| `tests/hl/run.sh` | `--family <name>` (default `hl-output`) |
| `tools/hl-compare.sh` | `HL_OPT=1` drops `-D hl_no_opt` and compares `dump/hlopt.txt` too |
| `tools/hl/HlOpcodesCheck.hx` | consistency check of `opcodeFx` against `opcodeMap` over Haxe-built `.hl` files |
| `README.md` | the `--hl` status row |

---

### Task 1: The `hl-opt` family and the tools

**Files:**
- Create: `tests/cases/hl-opt/family.json`, `tests/cases/hl-opt/cases.hx.txt`, `tests/cases/hl-opt/fixture/` (same files as `hl-output`'s fixture)
- Create: `tests/expected/hl-opt.json` (recorded)
- Modify: `tests/hl/run.sh`, `tools/hl-compare.sh`

**Interfaces:**
- Produces:
  - `tests/hl/run.sh --family <name>`: reads `tests/cases/<name>/cases.hx.txt` and that family's
    `family.json`; the default is `hl-output`.
  - `HL_OPT=1 tools/hl-compare.sh <case dir>`: compiles without `-D hl_no_opt`; after the existing
    comparison it prints the first function block of `dump/hlopt.txt` that differs (blocks start at a
    line `<name>@<findex>`), or `hlopt.txt identical`.

- [ ] **Step 1: The family.** `family.json` is `hl-output`'s with `"name": "hl-opt"` and `-D hl_no_opt`
  removed from `args`. `cases.hx.txt` starts with all 27 `hl-output` programs, copied with their names
  and `+` args unchanged; the two families are run separately, so the same names don't collide. Then
  add these optimiser cases:
  - `opt-temps`: nested calls and arithmetic with many temporaries of one type; temporaries of an
    anonymous-structure type and of a closure type; a value held across a call.
  - `opt-loops`: `while` and `for` with `break` and `continue`, a do-while, a nested loop, and a
    variable live across the back edge.
  - `opt-switch`: an `Int` switch dense enough to emit `OSwitch`, an enum switch, and a switch on
    strings.
  - `opt-trycatch`:
    - nested `try`, with a `throw` inside `catch`, and a rethrow;
    - a `try` whose body always returns;
    - `catch (e:String)` alongside `catch (e:Dynamic)`.
  - `opt-nullcheck`: repeated field reads and writes on one object, the same after `new`, and through a
    local alias (`var b = a; b.x; a.y`).
  - `opt-unreachable`:
    - code after a `return` and after a `throw` in branches;
    - a value computed and never read (the "unused" `OMov`);
    - an `if` whose jump lands on the next op once dead code is removed ("nojmp").
  - `opt-closure-dyn`: a typed function stored in a `Dynamic`, then called (`OCallClosure` on `HDyn`,
    Issue3218 in `hlopt.ml`), alongside a `Dynamic` that holds a `Dynamic -> Dynamic`.
  - `opt-assigns`: locals that the optimiser merges or drops (`var a = x; var b = a; trace(b)`), an
    argument copied into a local, and a local whose only write is removed.
  - `opt-ref-struct`: an `hl.Ref<Int>` passed to a function, and an `@:struct` class with an `@:packed`
    field read twice (the packed `OField` null-check rule). Record from Haxe first; if Haxe 4.3.7
    rejects `@:packed`, keep only the `hl.Ref` half and say so in the report.

  Every case prints what it computes (`Sys.println`), so the run check means something.

- [ ] **Step 2: Record.** In `D:/_github/haxe-conformance`:
  `neko run.n record --compiler C:/HaxeToolkit/haxe/haxe.exe --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected --family hl-opt`
  Expected: every case recorded; Haxe compiles each one.

- [ ] **Step 3: Tools.** In `run.sh`, add `--family` and update the header comment. In
  `hl-compare.sh`, make `-D hl_no_opt` conditional on `HL_OPT` being unset, and add the `hlopt.txt`
  comparison as described in Interfaces. A plain `diff` of the first differing block is enough.

- [ ] **Step 4: Watch it fail.**
  - Run: `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std tests/hl/run.sh --compiler bin/hxc-windows-x64.exe --family hl-opt`
    Expected: every case `hxc failed`, with the "optimiser is not ported yet" message.
  - Run: `tests/hl/run.sh … --family hl-output`. Expected: `all 27 cases passed` (the default is
    unchanged).
  - Run: `neko run.n run … --family hl-opt`. Expected: FAIL on every case.

- [ ] **Step 5: Commit.**
  `git add tests/cases/hl-opt tests/expected/hl-opt.json tests/hl/run.sh tools/hl-compare.sh`, then
  `git commit -m "hl: hl-opt family (optimiser on), run.sh --family, hl-compare HL_OPT"`

---

### Task 2: Opcode tables (`HlOpcodes`)

**Files:**
- Create: `src/hxc/codegen/hl/HlOpcodes.hx`, `tools/hl/HlOpcodesCheck.hx`

**Interfaces:**
- Consumes: `HlOp`, `HlFunction` (HlCode.hx); `HlReader` (tools/hl, Plan 1).
- Produces:
  - `enum HlControl { CNo; CJCond(d:Int); CJAlways(d:Int); CTry(d:Int); CCatch; CSwitch(cases:Array<Int>); CRet; CThrow; CLabel; }`
  - `HlOpcodes.control(op:HlOp):HlControl`
  - `HlOpcodes.opcodeFx(frw:(r:Int, read:Bool) -> Void, op:HlOp):Void`: reads and writes in
    `opcode_fx`'s order.
  - `HlOpcodes.opcodeMap(read:Int->Int, write:Int->Int, op:HlOp):HlOp`: calls `read` before `write`
    for each op, in `opcode_map`'s order.
  - `HlOpcodes.opcodeEq(a:HlOp, b:HlOp):Bool`: `OType` compares the register by value and the type by
    identity; every other op compares structurally, with arrays element by element.

- [ ] **Step 1: The check tool.** `tools/hl/HlOpcodesCheck.hx`, run as
  `haxe -cp src -cp tools/hl --run HlOpcodesCheck <dir>`. It reads every `.hl` file in `<dir>` with
  `HlReader` and checks, for every op of every function:
  - (a) `opcodeEq(opcodeMap(r -> r, r -> r, op), op)`;
  - (b) the registers `opcodeFx` reports as read, in order, equal the registers `opcodeMap` passes to
    `read`, in order;
  - (c) the same for writes.

  The exceptions are `hlopt.ml`'s own asymmetries, listed in the tool:
  - `OIncr`/`ODecr`: `fx` reads and writes `a`; `map` only writes.
  - `ORef(d, a)`: `fx` also writes `a`.

  It prints `<n> ops checked, <k> mismatches`, lists the first 20 mismatches by op name, and exits 1 on
  any. The controller names a directory of Haxe-built `.hl` files to run it on. The `h.hl` files that
  `run.sh` keeps under `tests/hl/tmp` also work.

- [ ] **Step 2: Run it to make sure it fails.** Expected: it doesn't compile (`HlOpcodes` is missing).

- [ ] **Step 3: Implement `HlOpcodes.hx`.** Port `hlopt.ml` lines 29–438 literally: one `case` per
  OCaml match arm, keeping its order of `read` and `write` calls. Keep the `(* ??? *)` arms
  (`OEndTrap`) as OCaml has them.

- [ ] **Step 4: Run the check.** Expected: `<n> ops checked, 0 mismatches`, with every `HlOp`
  constructor that appears in the input covered.

- [ ] **Step 5: Commit.** `git add src/hxc/codegen/hl/HlOpcodes.hx tools/hl/HlOpcodesCheck.hx`, then
  `git commit -m "hl: opcode tables for the optimiser (control, opcode_fx, opcode_map)"`

---

### Task 3: The optimiser (`HlOpt`), wired in, with its dump

**Files:**
- Create: `src/hxc/codegen/hl/HlOpt.hx`
- Modify: `src/hxc/codegen/hl/HlFunctions.hx` (end of the function builder, where the comment
  "the optimiser (Hlopt) is Plan 2" is), `HlContext.hx`, `HlGenerate.hx`
- Modify: whatever `genhl.ml` optimise-only path differs (`HlContext.allocTmp`/`hold`/`free`,
  `HlTypes.typeKey` for `mallocs`)
- Test: `hl-opt` family; `tools/hl-compare.sh` with `HL_OPT=1`

**Interfaces:**
- Consumes: Task 2's `HlOpcodes`; `HlDump.ostr`, `HlDump.tstr`, `HlDump.fundeclName`;
  `HlTypes.isDynamic` (move it into `HlCode.hx` if needed, to keep the import constraint);
  `HlTypes.getIndex` or a port of `hlcode.ml`'s `resolve_field` for `is_packed_field`.
- Produces:
  - `HlOpt.optimize(dump:Null<String->Void>, getStr:Int->String, f:HlFunction):HlFunction`.
    `dump` gets one call per line, without the newline. OCaml's `hxf` argument fed only the dead cache,
    so it is dropped.
  - `HlContext.dumpOut:Null<StringBuf>`: set when `dump` is defined.

- [ ] **Step 1: Run the failing case.**
  `HL_OPT=1 tools/hl-compare.sh <dir holding opt-temps' P.hx>`. Expected: hxc refuses to run.

- [ ] **Step 2: Port `hlopt.ml` lines 440–1097 into `HlOpt.hx`.** Keep the OCaml structure:
  - `block` and `reg_state` are classes with the same mutable fields;
  - `ISet` is a set of ints;
  - `bwrite` is an int map;
  - `live_bits` uses the same 30-bit stride.

  Port each recursion as recursion (order matters), and each `List.fold_left`/`@` exactly, because
  the assigns remap's result order is then stable-sorted. These points decide bytes:
  - `code_graph`'s evaluation order (Global Constraints);
  - `propagate` reusing the first predecessor's state when that predecessor has one successor;
  - `Hashtbl.add` on `reg_moved` (the lookup finds the latest);
  - the "unreachable" pass skipping `OEndTrap true`;
  - `nojmp` only for forward jumps over nops;
  - the register map counting reads, writes and arguments;
  - `_optimize` rewriting `f.code` in place.
- [ ] **Step 3: Port the dump literally.** These orders decide the text:
  - `NEED=` lists `ISet.elements`, which is *decreasing*, because `ISet`'s compare is `b - a`.
  - `WRITE=` is in increasing register order.
  - `LIVE=` is in increasing register order.
  - `nvar_set` names come in reverse array order for one position (consed).
  - `%X` is upper-case hex, and `%-3X`/`%-20s` are left-justified.
  - The new-op column is empty when `opcodeEq(old, new)`.
  - `ARGS = …` is followed by an empty line, then two empty lines after the block.

- [ ] **Step 4: Wire it in.**
  - At the end of the function builder, when `ctx.optimize && (genContent == null || name is not ("",""))`,
    run `HlOpt.optimize(ctx.dumpOut == null ? null : line -> { ctx.dumpOut.add(line); ctx.dumpOut.add("\n"); }, i -> ctx.cstrings.arr[i], hlf)`
    under `Timer.timer(["generate","hl","opt"])`, and push the result.
  - In `HlGenerate.generateCode`, remove the `NO_OPTIMISER` refusal and its constant.
  - With `dump`, save `dumpOut` to `dump/hlopt.txt` after code generation; it is `""` when the
    optimiser is off.

- [ ] **Step 5: Build, then compare case by case** with `HL_OPT=1 tools/hl-compare.sh`, until each
  `hl-opt` case has identical tables, functions and `hlopt.txt`. Where the dump's *old-op* column
  differs, the code that went into the optimiser differs: that is `genhl`'s allocator (`allocTmp`,
  `hold`, `free`, `mallocs`), not `HlOpt`. Fix it there, against `genhl.ml` lines 795–850.

- [ ] **Step 6: Run the family.**
  `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std tests/hl/run.sh --compiler bin/hxc-windows-x64.exe --family hl-opt`
  Expected: `all <n> cases passed`. `--family hl-output` still passes all 27.
  `neko run.n run … --family hl-output,hl-opt,hl-setup`: PASS.

- [ ] **Step 7: Commit.** `git add -A src/hxc tests`, then
  `git commit -m "hl: port hlopt (optimiser on by default); hl-opt cases byte-identical to Haxe 4.3.7"`

---

### Task 4: Stress cases and acceptance

**Files:**
- Modify: `tests/cases/hl-opt/cases.hx.txt`, `tests/expected/hl-opt.json`, `README.md`
- Modify: whatever the new cases point at
- Test: all `hl-*` families, own suite, `.NET` suite

- [ ] **Step 1: Add the stress cases and record them.**
  - `opt-long-function`: a `static macro function gen()` in `P` that builds 2000 statements
    `if (x == i) y += i;`, followed by a 400-case `Int` switch. `main` calls it once and prints `y`.
    Haxe compiles it.
  - `opt-assigns-debug`: `opt-assigns`'s program with `+ --debug`.
  - `opt-dump`: `opt-loops`' program with `+ -D dump`. The `.hl` must match; `run.sh`'s byte check
    covers it, and Step 2 checks `hlopt.txt` with `hl-compare.sh`.

- [ ] **Step 2: Run everything.**
  - `tests/hl/run.sh … --family hl-opt` and `--family hl-output`: all pass.
  - `HL_OPT=1 tools/hl-compare.sh` on `opt-dump`: `hlopt.txt identical`.
  - `neko run.n run … --family hl-output,hl-opt,hl-setup`: PASS.

  Fix what differs. If `opt-long-function` overflows the stack, keep the order of the recursion and
  give it an explicit work stack.

- [ ] **Step 3: Regression suites.**
  - own suite (`neko run.n run … -j 4`, no `--family`): 0 failed;
  - `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std tests/dotnet/run.sh --compiler bin/hxc-windows-x64.exe`:
    736/736.

  Never run two suites at once.

- [ ] **Step 4: README.** The `--hl` row: `--hl x.hl` is byte-identical to Haxe 4.3.7 on the
  `hl-output` (`-D hl_no_opt`) and `hl-opt` (optimiser on) cases; HL/C (`.c`) is not supported yet.

- [ ] **Step 5: Commit.** `git add -A src/hxc tests README.md`, then
  `git commit -m "hl: optimiser stress cases; --hl byte-identical with the optimiser on"`

- [ ] **Step 6: Rebuild the testing exe.**
  `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex haxelib run aedifex build cpp .` Then confirm
  `find src -newer bin/hxc-windows-x64.exe -type f` prints nothing.
