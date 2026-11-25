# Inline C#, indexers and the last interop gaps (milestone 4b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The server app, its nativepdf build and the desktop app compile under `--cs <dir> -D dotnet` with
no inline-C# error. With the two small source changes in rulings 8 and 9, the server app writes
`HaxeServer.dll` for the first time. That DLL passes ILVerify against the deployed assemblies, and the
server app's no-browser export check prints the same results with it as with gencs's DLL.

**Architecture:**
- **Inline C# expressions** have three pieces:
  - **`CsSyntax` (new):** parses one C# expression, or a bare `throw`.
  - **A typer hook, `CsLift` (new):** under `-D dotnet`, turns every Haxe local, `this` and member of the
    current class that the C# text names into a `{N}` placeholder carrying the typed expression. Inlining,
    closure capture, boxing and DCE then see ordinary expressions.
  - **`CsToIl` (new):** resolves what is left (keyword, dotted and `global::` types, .NET members bound by
    4a's `ExternMembers` model) and lowers it to IL with C#'s semantics.
- **Rethrow:** `TexprFlow` keeps a stack of handlers and emits `rethrow` where the innermost one is a catch.
- **Indexers:** a new `IndexerToIl` writes gencs's indexer for every class with `__get`/`__set`, `Array`
  included, and for the companion interfaces.
- **The rest:**
  - `@:classCode`/`@:functionCode` refusals that no longer leave the class out;
  - IntPtr binding;
  - `CompilerGeneratedAttribute`;
  - C#'s rule for a `null` argument (4a's Ruling Z);
  - a front-end fix for `--macro addMetadata("@:build(…)")` on a std class.

**Tech Stack:** Haxe 4.3 (hxc's source), hxcpp via Aedifex, the .NET 10 SDK and its reference pack, and
Haxe 4.3.7 + hxcs (the oracle; installed locally).

**Spec:** `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`. The relevant parts:
- *How it gets made*, the **Inline C#** bullet: rulings 1-7 below amend it.
- *Milestones*, item 4: the 4a bullets give the extern-binding model this plan reuses, and the **4b**
  bullet is this plan's scope.
- *Casts between generic instantiations*: the recorded divergence for the missing `Array` indexer, which
  Task 6 retires.

Background: the 4a plan, `docs/superpowers/plans/2026-10-26-dotnet-interop-members.md`, and its ledger,
`.superpowers/sdd/2026-10-26-dotnet-interop-members/progress.md` (rulings A-Z, and the parked and carried
items).

**Research behind this plan.** Read the notes for the task you are on. They quote real gencs output and
give hxc's file:line for each piece. Real server-app paths appear only there, never in the repo.
- `D:/_hxc4b/csexpr/NOTES.md`: inline C# expressions; every real use (§1); gencs's substitution, result
  conversion and name binding (§2-3); rethrow (§4); decimal and multi-argument indexers (§5); the design
  with the IL of each pattern (§6); the error texts (§7).
- `D:/_hxc4b/codeblocks/NOTES.md`: `@:classCode` and `@:functionCode` (§1-2, §4); gencs's indexer rule,
  with flags, IL and the order of metadata rows (§3); the design (§5).
- `D:/_hxc4b/misc/NOTES.md`: the baseline (§1), IntPtr (§2), CompilerGenerated (§3), Ruling Z (§4).

Each notes directory has probe folders, each with `P.hx`, gencs's C# and both outputs.

**Test material** lives next to this plan in `docs/superpowers/plans/2026-10-27-dotnet-inline-cs/`:
- `csexpr.cases.txt`, `codeblocks.cases.txt` and `misc.cases.txt` hold the candidate cases. Every `@gencs`
  expectation in them is a real gencs net10.0 run. A divergence case carries hxc's expected output, with
  gencs's under `[gencs]`. A case gencs's C# cannot compile gives the C# error in its header comment. The
  `#` lines at the top of each file are notes, not case text. Refusal texts marked "proposed" are settled by
  §7 of the csexpr notes and by this plan; where the two differ, this plan wins.
- `netlib/ByNull.cs` holds the overloads Task 9's cases need. Append it to
  `tests/dotnet/netlib/ValLib/ValLib.cs`.
- `tools/stdall.sh <hxc> <out>` builds the whole standard library with the stub report. `tools/errors.py`
  classifies a log's errors. Neither names a private app.
- `measure/` is gitignored and local only:
  - `measure.sh <hxc> <tag>`: nativepdf, server and server-stubs;
  - `desktopapp.sh <hxc> all|noavalonia`;
  - `verify.sh <dll> <name>`: ILVerify against the deployed server's assemblies;
  - `nochrome.sh <hxc> <tag>`: the server app's no-browser export check, run on gencs's and hxc's DLLs;
  - `shape.sh <dll> <tag>`: the CLR shape of the 24 formerly left-out classes and the tool models.

  All of them write only under `$MEASURE_OUT`. With `OVERLAY=1`, `measure.sh` and `nochrome.sh` add
  `-cp measure/overlay`. The overlay holds the source changes of rulings 8 and 9 until the owner makes
  them. The last `-cp` is searched first (`Compiler.hx:966-972`).

"Add case X from F" means: copy that case's text verbatim from F to the end of
`tests/dotnet/cases.hx.txt`. If a case needs a piece a later task builds, move it to that task and say
so in the report.

**Branch:** `git switch -c dotnet-il-m4b main`. Don't push or open a PR.

## Rulings made for this plan

Each research area left open questions, each with a recommendation. These rulings settle them. The
execution ledger records them at the start, and the user reviews them with this plan.

1. **The subset is what real code uses, not the spec's shorter list.** It is one C# expression, or a
   bare `throw`. (csexpr Q1)
   - Placeholders `{N}`. A placeholder used twice evaluates its argument twice, as gencs's text substitution
     does.
   - `this`, simple names, dotted and `global::` names.
   - Keyword types (`bool`, `byte`, `sbyte`, `short`, `ushort`, `int`, `uint`, `long`, `ulong`, `char`,
     `float`, `double`, `decimal`, `string`, `object`), array types `T[]` and generic type names, as cast
     and `is` targets, `new` targets and static receivers.
   - Member access (fields, properties, enum members, constants), calls, indexers with any number of
     arguments, and `new T(args)`.
   - Casts (chained, and as a parenthesised receiver), `is`.
   - Unary `!` and `-`; binary arithmetic, comparisons, `==`/`!=`, `&&` and `||`, with C#'s numeric promotion.
   - Literals: integer, real (`d`, `f`, `m`), string, char, `true`, `false` and `null`.
   - Everything else is a lasting error that names the replacement: assignment, lambdas, `typeof`, `as`,
     `?:`, `ref`/`out`, statements, `throw <value>`, explicit type arguments, array creation, `default`,
     `?.`, `??`, interpolated strings, a `{N}` inside a string literal, and the rest of csexpr §7's table.
     (csexpr Q7)
   - `cs.Syntax.plainCode` is parsed the same way, with no placeholders.
2. **Names the C# text gives are resolved in the Haxe scope, in the typer.** (csexpr Q2, Q3)
   - The lift binds a simple name in head position that is a Haxe local, `this`, or a member of the current
     class chain. A `this.`-chain or member chain over non-extern Haxe fields is lifted whole, under
     `@:privateAccess`, which covers haxe-strings' `this.sb.b`.
   - Type names are not lifted; C# resolves them as CLR names.
   - Where gencs's C# silently reads something else (a renamed shadowing local, a local boxed by a closure, an
     inliner-substituted argument) or cannot resolve the name (unrolled loops, text-only captures, Haxe
     properties), hxc does better. Each case is recorded under *Interop divergences from gencs*.
3. **Result conversion is gencs's.** (csexpr Q8)
   - `untyped __cs__` takes its use's type through C#'s implicit conversions only, else a lasting error
     with C#'s code (CS0266/CS0029).
   - `cs.Syntax.code` is `Dynamic`: to `Int`, `Float`, `Bool` and `String` it converts through
     `Runtime.toInt`/`toDouble`/`toBool`/`toString`, and to anything else by C#'s explicit cast from the
     expression's own CLR type.
   - A `Null<T>` argument is boxed, as gencs's `toDynamic()` does.
4. **Rethrow.** (csexpr Q4)
   - Each of these emits IL `rethrow` when the innermost enclosing handler is a catch:
     - the bare `throw` (both spellings, `throw` and `throw;`, through `untyped __cs__` or `cs.Syntax.code`);
     - `cs.Lib.rethrow(e)`, which the std writes as `throw untyped __rethrow__`;
     - the exceptions filter's own `throw _g`. This is gencs parity: hxc emits `throw` there today and loses
       the thrower.
   - `throw e` of the innermost catch's user variable emits `rethrow` when that variable is never assigned in
     the catch. This is the spec's first-class form, and a recorded divergence: gencs writes `throw e;`,
     which resets the trace.
   - A bare `throw` or `cs.Lib.rethrow` that is not in a catch is a lasting error (CS0156). That includes one
     in a local function and one inside hxc's own try/finally (`__lock__`).
   - For one-source-tree parity, the server app may move to `cs.Lib.rethrow(e)`, which behaves the same
     under both compilers. Nothing requires it.
5. **No "decimal constant" feature.** No Haxe 4.3.7 form makes a `Decimal` from a constant except
   `new Decimal(x)`, which already matches gencs. Inline `(decimal)c` folds as Roslyn does: `Decimal::Zero`,
   `One` or `MinusOne`, or the `int32`/`int64`/5-argument constructor. A variable goes through
   `op_Implicit`/`op_Explicit`. The spec's decimal bullet is dropped. (csexpr Q5)
6. **Multi-argument indexers:** `x.get_Item(a, b)` and `x.set_Item(a, b, v)` are the documented
   first-class form. They already compile under both compilers. The spec's "through array access" is
   dropped. (csexpr Q6)
7. **DCE:** a member the lift turns into a placeholder is a real use, so DCE keeps it. A member named only
   through a qualified type name, if DCE removed it, is a lasting error naming `@:keep` (gencs: CS0117).
8. **`@:classCode` beyond `#pragma` lines stays an error, as the spec says, but the class is still
   compiled.** So uses no longer cascade with "left out" errors. (codeblocks Q1)
   - A `@:classCode` of `#pragma` lines only (comments and blank lines allowed) is ignored.
   - The server app replaces nativepdf `Zlib`'s injected method with hand-written `@:native` externs for
     `ZLibStream` and `CompressionLevel` (codeblocks §4). The bytes are the same under both compilers.
     `measure/overlay/nativepdf/Zlib.hx` is that change.
9. **`@:functionCode` is an error**, naming the replacement. The library's two constructor
   `@:functionCode`s (`BaseTextArea`, `BaseUiComponent`) are dead code in both apps. The owner wraps each in
   `#if !dotnet … #end`, which keeps gencs's output byte-identical; the overlay holds that change.
   (codeblocks Q2)
10. **gencs's indexer rule, for every class.** (codeblocks Q3-Q5)
    - Any class whose kept instance `__get`/`__set` survive DCE gets `get_Item`/`set_Item`, a Property row
      `Item` and `[DefaultMember("Item")]`. `Array` is one of them.
    - A class with a companion interface also gets the explicit `global::<Companion>.Item` pair with its
      MethodImpl rows, and the companion gets the abstract accessors and the attribute.
    - `a[i]` on a Haxe `ArrayAccess` class calls the nearest declaring accessor. That does better where
      gencs's C# fails with CS0200 (a subclass that overrides only `__get`).
    - Element reads, writes and `++`/`--` through a companion-typed `Array<Dynamic>` go through the companion
      indexer, as gencs's do, while compound `op=` keeps `callField`. This retires the spec's divergence 4: a
      write of the wrong type now throws, as it does in gencs-built servers today.
    - hxc's runtime `Array.__get`/`__set` get `@:keep`.
11. **IntPtr.** `ExternMembers.chain` binds IntPtr and UIntPtr members on `native int` / `native uint`.
    That removes the `Socket.select` stub. A cast between IntPtr/UIntPtr and a number is a lasting error,
    because gencs's output always throws there. (misc Q3)
12. **`CompilerGeneratedAttribute`** goes on the backing field and both accessors of every physical
    `@:property` var, exactly as Roslyn writes it, and never on the Property row.
13. **C#'s betterness for a `null` argument, and refinements to `converts`.** (misc Q1, Q2)
    - **The rule:** among the applicable candidates, the one whose parameter at each null position converts to
      every other candidate's binds (misc §4.3). A definite tie is a lasting error (CS0121). An undecidable one
      keeps the "cannot tell" refusal.
    - **A null into a declared `Nullable<T>`** is typed as declared, because gencs writes `default(T?)`.
    - **Conversion refinements now:**
      - (b): a reference type converts to no `Nullable<T>`;
      - (d): a generic method with a type parameter no argument binds does not apply.
    - **Carried to 4c:** (a), `Nullable<A>` to `Nullable<B>`, and (c), array covariance.
14. **The front-end bug that drops `--macro addMetadata("@:build(…)", "StringTools")` is fixed in 4b.**
    It silently changes the desktop app's string comparisons (csexpr §0 fact 9), and it hides the two
    `cs.Syntax.code` bodies of haxeui-cs's `OrdinalStringTools` from the measurement. (csexpr Q9)
15. **4b's exit.** The commands are in Task 11.
    - With `OVERLAY=1`, the server app, nativepdf and the desktop app have no error but the desktop app's
      resources (4c).
    - The server app writes `HaxeServer.dll`.
    - `verify.sh` reports only gencs's own BoxedPointer line.
    - `nochrome.sh` prints SAME.
    - `tools/stdall.sh` no longer lists `Socket.select`.
    - `shape.sh`'s differences are only 4c items.

## Global Constraints

- **3a's constraints still hold:**
  - `net10.0`; `--cs <dir> -D dotnet`; `-D dll-name`;
  - byte-identical output between two compiles, including with the reference pack;
  - hxc writes PE/IL itself;
  - ILVerify on every test assembly;
  - no silent miscompiles;
  - the code style of `src/hxc/codegen/jvm/` and of the surrounding dotnet code;
  - commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Match gencs.** Whatever stored data, reflection or the C# side can observe behaves like Haxe 4.3.7
  gencs + hxcs. Where gencs's C# fails to compile, hxc either refuses cleanly or does better, and each
  "does better" is recorded in the spec's *Interop divergences from gencs*. The oracle is gencs's C# built
  for `net10.0` with `tests/dotnet/gencs.csproj.in`.
- **The typer change is `-D dotnet`-only.** `CsLift` runs only when the platform is `cs` and `dotnet` is
  defined. Every other target's output stays byte-identical. OWN checks that.
- **Lasting errors** go through `Unsupported.error` ("dotnet: <what>", with no "yet"). Not-yet errors stay
  `Unsupported`. Inline C# is checked only where it survives DCE, as gencs does.
- **Unsupported constructs are clean errors.** In user code, anything not supported yet is an error at the
  construct's position, never an internal error and never a crash. In std code it becomes a stub.
- **Public repo:** nothing committed names the private apps, their libraries, paths or packages. Say "the
  server app" and "the desktop app", and use `serverapp-*` for case names. Before every commit, run the
  `git grep` that the local `measure/README.local.md` gives on the staged files, and check the message too.
  That file is gitignored, because the pattern itself names them.
- **Read-only:** the apps' checkouts, `D:/_github/haxeui-cs` and `C:/HaxeToolkit/haxe/lib`. Measurements
  build them out of tree (`measure/`).
- **Cases are compiled without `-debug`.**
- **Commands used below:**
  - BUILD: `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/ HAXE_STD_PATH=C:/HaxeToolkit/haxe/std HXCPP_COMPILE_CACHE=D:/_github/hxc-toolchain/hxcpp-cache haxelib run aedifex build cpp .`
  - CASE `<name>`: `MSBUILDDISABLENODEREUSE=1 timeout 900 tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --case <name>`
  - ALL: the same without `--case`, under `timeout 1800`; expected `all N cases passed`.
  - OWN: `cd D:/_github/haxe-conformance && neko run.n run --compiler D:/_github/hxc/bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected -j 4`; expected `0 failed`.
  - MEASURE `<tag>`: `MEASURE_OUT=D:/_hxc4b/measure docs/superpowers/plans/2026-10-27-dotnet-inline-cs/measure/measure.sh bin/cpp/windows/x64/release/bin/hxc.exe <tag>`, once plain and once with `OVERLAY=1` and tag `<tag>-ov`.

## Review Focus

These failure modes are implied by the spec but no research case tests them. Each line names its test,
which the owning task adds.

1. **A bare `throw` inside hxc's own try/finally within a catch.** `catch (e:Exception) { lock(o) {
   untyped __cs__("throw"); } }` puts `rethrow` inside a finally region, which is invalid IL (C#'s
   CS0724). It must be refused, not written. Test: `inline-cs-rethrow-in-lock-is-an-error` in Task 2. Its
   expected `[compile]` is the CS0156 text of Task 1, at the `__cs__` call.
2. **A Haxe local whose name is also a type or namespace head.** C#'s simple-name lookup takes the local.
   The lift must too, and `global::System.Math` must still reach the type when a local is named `System`.
   Test: `inline-cs-local-shadows-type-name @gencs` in Task 4. It covers `var Math = 3;
   cs.Syntax.code("Math + 1")` giving 4, and `var System = 1; cs.Syntax.code("global::System.Math.Abs(-2)")`
   giving 2.
3. **A Haxe function passed through a placeholder to a .NET delegate parameter.** For example,
   `cs.Syntax.code("{0}.ForEach({1})", list, f)` with `f:Int->Void`. gencs's C# fails here (CS1503: a
   `haxe.lang.Function` is no delegate). hxc must refuse, never bind an `object` overload or pass the closure
   object. Test: `inline-cs-function-to-delegate-is-an-error @netlib` in Task 3. Use
   `System.Collections.Generic.List<int>`; the refusal is 4a's "no .NET overload of … takes (…)" text.
4. **Rethrow of a catch variable that a closure captures.**
   - If the closure only reads it, `throw e` is still `rethrow`.
   - If the closure writes it, CapturedVars boxes it, it is no longer a `TLocal`, and the throw stays a
     plain `throw` of the current value.

   Test: `rethrow-captured-catch-variable @gencs` in Task 1. gencs writes `throw e;` in both shapes, so the
   first shape carries a `[gencs]` section like `rethrow-throw-caught-value`'s.
5. **A `cs.Syntax.code` result going into `Null<Int>`, a type parameter, and a `Dynamic` static field.**
   These are the desktop app's `HttpImageLoader._client` and generic helpers. Each converts as gencs does,
   with no `InvalidCastException` and no lost null. Test: `inline-cs-result-into-null-and-type-params
   @gencs` in Task 2. `[run]` is what gencs prints.

---

## File structure

| File | Responsibility |
| --- | --- |
| `src/hxc/codegen/dotnet/CsSyntax.hx` (new) | Lexer and parser for one C# expression or a bare `throw`; the `CsExpr` tree with offsets; recognizing outside-subset constructs well enough to name them |
| `src/hxc/codegen/dotnet/CsLift.hx` (new) | The typer-side lift of Haxe names into placeholders (called from `Calls.typeCallAccess` under `-D dotnet`) |
| `src/hxc/codegen/dotnet/CsToIl.hx` (new) | Resolution of placeholders, keyword/dotted/`global::` types and .NET members; C#'s operators, casts, literals and conversions; the two entry points |
| `src/hxc/typing/Calls.hx` | The `-D dotnet` hook after `__cs__` / `cs.Syntax.code` calls are typed (`typeCallAccess`, :695) |
| `src/hxc/codegen/dotnet/TexprFlow.hx`, `TexprToIl.hx` | The handler stack, `rethrow`, `throwExpr`'s rethrow cases |
| `src/hxc/codegen/dotnet/TexprCalls.hx` | `magicCall`'s `__cs__` and `__rethrow__`, the `cs.Syntax.code`/`plainCode` call case, indexer lowering for Haxe classes and companions |
| `src/hxc/codegen/dotnet/ExternMembers.hx` | A binding entry by CLR receiver and argument types for `CsToIl`; IntPtr in `chain`; null betterness, declared `Nullable` nulls, `converts` (b) and (d) |
| `src/hxc/codegen/dotnet/IndexerToIl.hx` (new) | gencs's `__get`/`__set` indexers: plans, accessors, companion members, `DefaultMember` |
| `src/hxc/codegen/dotnet/TclassToIl.hx`, `CompanionToIl.hx`, `SigWriter.hx` | `@:classCode`/`@:functionCode` refusals; indexer plans; indexed property signatures; `CompilerGenerated` rows |
| `src/hxc/codegen/dotnet/runtime/Array.hx` | `@:keep` on `__get`/`__set` |
| the macro/typer file that applies `addMetadata` (Task 10 finds it) | `@:build` added by `--macro addMetadata` on a std class |
| `tests/dotnet/cases.hx.txt`, `tests/dotnet/netlib/ValLib/ValLib.cs` | Cases; ByNull overloads |
| `docs/superpowers/specs/…-design.md`, `README.md` | The subset, rethrow, indexers, divergences, the 4b status |

---

### Task 1: Rethrow: the handler stack, the filter's `throw _g`, `cs.Lib.rethrow` and `throw e`

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprFlow.hx` (`throwExpr` :189, `tryExpr` :208, `tryFinally` :277),
  `TexprToIl.hx` (the stack's field; a closure's `TexprToIl` starts with an empty stack), `TexprCalls.hx`
  (`magicCall` :893: `__rethrow__`)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - `typedef HandlerFrame = {isCatch:Bool, v:Null<TVar>, body:Null<TExpr>}` and
    `TexprToIl.handlers:Array<HandlerFrame>`. `tryExpr` pushes one around each catch body, and `tryFinally`
    pushes `{isCatch: false}` around `fin()` only.
  - `TexprFlow.rethrow(pos:Position):Void` emits `rethrow` when the last frame is a catch. Otherwise it
    throws `Unsupported.error("a rethrow (a bare `throw`, cs.Lib.rethrow) must be directly inside a catch
    (C# error CS0156)", pos)`. Task 2 calls it for inline C#'s bare `throw`.
  - `TexprFlow.isRethrowable(v:TVar):Bool` is true when `v` is the last catch frame's variable and its
    `body` never assigns `v` (`=`, compound assignment, `++`/`--`).

- [ ] **Step 1: Add the cases and see them fail**

Add from `csexpr.cases.txt`: `inline-cs-rethrow-lib`, `rethrow-unmatched-catch` and
`rethrow-throw-caught-value`.

Write `rethrow-captured-catch-variable @gencs` (Review Focus 4). It has two catches of
`cs.system.InvalidOperationException` around a thrower:
- in the first, a closure reads `e` before `throw e`;
- in the second, a closure assigns `e`.

Each prints whether the trace names the thrower, as `rethrow-throw-caught-value` does. Fill `[run]` with
hxc's intended output (first shape: kept, true; second: false) and `[gencs]` with gencs's (false, false).

CASE each. Expected: `inline-cs-rethrow-lib` fails with "untyped code is not supported yet", and the
trace lines differ in the others.

- [ ] **Step 2: Implement**

Follow csexpr §4.3:
- `throwExpr` emits `rethrow` for:
  - `TThrow(TLocal v)` where `v` is the last catch frame's variable and `VGenerated` (the filter's `_g`);
  - `TThrow(TLocal v)` where `isRethrowable(v)` holds;
  - `TThrow(TIdent("__rethrow__"))` (cs.Lib.rethrow), through `rethrow`, so it refuses outside a catch.
- Anything else is `throw`, as today.

IlCode already ends a block at RETHROW (IlCode.hx:199).

- [ ] **Step 3: Run them**

CASE each; expected `ok`.

- [ ] **Step 4: Spec, run everything, commit**

In the spec's Inline C# bullet, replace the rethrow sub-bullet with ruling 4's rules. Add
`rethrow-throw-caught-value` and the first shape of `rethrow-captured-catch-variable` to *Interop
divergences from gencs*.

ALL, then OWN. Commit: `Rethrow caught exceptions with IL rethrow for .NET, as gencs's throw; does`.

---

### Task 2: `CsSyntax` and `CsToIl`: placeholders, literals, operators, casts, `is`, bare `throw`

**Files:**
- Create: `src/hxc/codegen/dotnet/CsSyntax.hx`, `src/hxc/codegen/dotnet/CsToIl.hx`
- Modify: `TexprCalls.hx`. The `__cs__` case of `magicCall` (:926) goes to `CsToIl.code`, and
  `csIntLiteral` (:935) becomes the parser's integer literal. A new case in `call` before the extern path
  (about :566) handles `TField(_, FStatic(cs.Syntax, "code" | "plainCode"))`.
- Test: `tests/dotnet/cases.hx.txt` (also update `resource-is-an-error`, :63-72)

**Interfaces:**
- Consumes: `TexprFlow.rethrow(pos)` (Task 1).
- Produces (`CsSyntax`):

```haxe
typedef CsExpr = {def:CsExprDef, pos:Int, len:Int} // offsets into the code string
enum CsExprDef {
	CPlaceholder(n:Int);
	CThis;
	CIdent(name:String);                 // a simple name, verbatim `@` stripped
	CGlobal(name:String);                // the segment after `global::`
	CKeywordType(name:String);           // `int` in `int.MinValue`
	CMember(e:CsExpr, name:String);
	CCall(e:CsExpr, args:Array<CsExpr>);
	CIndex(e:CsExpr, args:Array<CsExpr>);
	CNew(t:CsType, args:Array<CsExpr>);
	CCast(t:CsType, e:CsExpr);
	CIs(e:CsExpr, t:CsType);
	CUnop(op:String, e:CsExpr);
	CBinop(op:String, a:CsExpr, b:CsExpr);
	CLiteral(l:CsLiteral);
	CParen(e:CsExpr);
}
enum CsType {
	CTKeyword(name:String);
	CTNamed(global:Bool, segments:Array<String>, args:Array<CsType>);
	CTArray(t:CsType);
}
enum CsLiteral { LInt(text:String); LReal(text:String); LString(s:String); LChar(c:Int); LBool(b:Bool); LNull; }
enum CsParse {
	PExpr(e:CsExpr);
	PThrow;                                          // `throw` or `throw;`
	PRefused(what:String, replacement:String, pos:Int); // outside the subset, csexpr §7
	PError(reason:String, pos:Int);                  // does not parse
}
// CsSyntax.parse(text:String, placeholders:Bool):CsParse  (placeholders false for plainCode)
```

- Produces (`CsToIl`): `new(tl:TexprToIl)` and `code(ret:Ret, e:TExpr, text:String, args:Array<TExpr>,
  isUntyped:Bool, pos:Position):Void`. Name resolution goes through one method, `resolveName(e:CsExpr):
  CsValue`, where:

  ```haxe
  enum CsValue {
  	VType(t:IlSigNorm);        // a type, as a static receiver or a cast target
  	VNamespace(path:Array<String>);
  	VPushed(t:IlSigNorm);      // a value already on the stack
  }
  ```

  In this task it handles keyword types only; any other name is the unknown-name error. Tasks 3 and 4
  extend it.

- [ ] **Step 1: Add the cases and see them fail**

Add from `csexpr.cases.txt`:
- `inline-cs-placeholders`;
- `inline-cs-rethrow-bare`;
- `inline-cs-decimal`;
- `inline-cs-bare-throw-outside-catch-is-an-error`;
- `inline-cs-untyped-result-conversion-is-an-error`;
- `inline-cs-code-not-constant-is-an-error`;
- `inline-cs-placeholder-out-of-bounds-is-an-error`.

Write `inline-cs-rethrow-in-lock-is-an-error` (Review Focus 1) and
`inline-cs-result-into-null-and-type-params @gencs` (Review Focus 5). The second assigns
`cs.Syntax.code("{0} + 1", i)` to:
- a `Null<Int>` local;
- a `Null<Float>` field;
- a `T` in a generic function called with `Int` and with `String`;
- a static `Dynamic` field, read back.

It prints each.

In `resource-is-an-error`, change the `untyped __cs__("x")` line's expected text to the unknown-name
error.

CASE each; expected "untyped code is not supported yet" failures.

- [ ] **Step 2: Implement `CsSyntax`**

It is a recursive-descent parser with C#'s precedence: unary, multiplicative, additive, relational with
`is`, equality, `&&`, `||`.
- A parenthesised type followed by an operand is a cast. Follow C#'s disambiguation for `(T)x` against
  `(e)`: a keyword type, or a dotted name followed by an identifier, literal, `(`, placeholder or `this`.
- `{N}` outside a string literal is `CPlaceholder`, and inside one it is `PRefused`.
- The outside-subset constructs of ruling 1 are recognized at their first token and give `PRefused` with
  csexpr §7's replacement text.

- [ ] **Step 3: Implement `CsToIl` for this task's forms**

Lower each form as csexpr §6.3 and the operator paragraph after it say:
- **Placeholders:** `tl.texpr(RValue(sig(arg.type)), arg)` at each use.
- **Literals:** integer suffixes through the old `csIntLiteral` rules.
- **Keyword-type casts and `is`:** `conv.*`, `unbox.any`, `castclass`, `isinst`; `ldnull; cgt.un`, as
  `magicCall`'s `__is__`.
- **Decimal (ruling 5):** a constant cast folds to `Decimal::Zero`, `One`, `MinusOne` or a constructor; a
  variable goes through `op_Implicit`/`op_Explicit`.
- **Arithmetic and comparisons:** with C#'s promotion, `.un` forms for unsigned and floats, and
  short-circuit `&&`/`||`.
- **`PThrow`:** `TexprFlow.rethrow(pos)`, in statement position only. As a value it is the "has no value"
  error.

**The result** follows ruling 3. Write `convertResult(cs:IlSigNorm, target:IlSigNorm, castLike:Bool)`:
- `untyped`: implicit conversions only (`ExternMembers.implicitlyConverts`); otherwise
  `Unsupported.error("the inline C# expression is a <cs>, which does not convert to <Haxe type> implicitly
  (C# error CS0266); add a cast in the C# text")`.
- `cs.Syntax.code`: box, then hxc's Dynamic conversion for `Int`/`Float`/`Bool`/`String`; otherwise the
  explicit cast.
- `RVoid` pops the value.

**Errors** are `Unsupported.error` with csexpr §7's texts, at the call's position. A non-constant code
string and an out-of-bounds placeholder use gencs's own texts.

- [ ] **Step 4: Run them**

CASE each; expected `ok`.

- [ ] **Step 5: Run everything and commit**

ALL, then OWN. Commit: `Compile inline C# placeholders, literals, operators and casts for .NET`.

---

### Task 3: `CsToIl`: CLR type names and .NET members

**Files:**
- Modify: `CsToIl.hx`; `ExternMembers.hx`, which gets a binding entry by CLR types; `DotnetTypes.hx`,
  `NetRefs.hx` if the type lookup needs an accessor
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `CsSyntax` and `CsToIl.resolveName` (Task 2); `NetRefs.definer` (4a).
- Produces:
  - **`ExternMembers.bindCs(recv:IlSigNorm, name:String, isStatic:Bool, args:Array<IlSigNorm>,
    argKinds:Array<ArgKind>, pos:Position)`.** It returns the bound method (token, instantiated parameter
    sigs, return sig) or throws one of 4a's refusal texts. It walks link by link with `resolve` (:648),
    exact first, then the one applicable overload. `ArgKind` is 4a's kind (plain, integer constant, null).
  - **`ExternMembers.memberCs(recv, name, isStatic)`** returns a field, literal constant or property
    getter, looked up from the receiver's type as 4a's field rule does.

- [ ] **Step 1: Add the cases and see them fail**

Add from `csexpr.cases.txt`:
- `inline-cs-forms`;
- `inline-cs-outside-subset-is-an-error`;
- `inline-cs-unknown-name-is-an-error`.

Write `inline-cs-function-to-delegate-is-an-error @netlib` (Review Focus 3).

CASE each; expected unknown-name errors.

- [ ] **Step 2: Implement type names**

Follow csexpr §6.2.
- A keyword type is a System type.
- A dotted name follows C#'s rule. Each prefix is tried as a type: the current class's namespace first,
  then outward, then global. `global::` starts at the root.
- A type is one of:
  - a program class by its CLR path;
  - a loaded library type (`ctx.netPathMap`/`netDottedMap`);
  - any type `NetRefs.definer` finds, the reference pack included. The server app's `ZLibStream` is only
    there.
- Generic type names take their arguments; array types are `LVector`.

- [ ] **Step 3: Implement members, `new`, indexers and struct receivers**

- **Members:** members of program classes resolve through the class's plans. Members of CLR types go
  through `memberCs`/`bindCs`, with `args` = the argument CLR types.
  - A literal (an enum member, `int.MinValue`) loads its constant.
  - A property calls its getter.
  - An override binds at its first declaration, as Roslyn's `callvirt Object::GetHashCode()` does.
- **`new T(args)`** binds `.ctor` the same way.
- **An indexer with N arguments** is its `DefaultMember` property's `get_Item`, bound like a call.
- **A struct rvalue receiver** goes through a temporary and `ldloca` (`GetAwaiter().GetResult()`).
- **Errors:**
  - a member of a program class that DCE removed is ruling 7's error ("the inline C# member P.m was removed
    by DCE, as only C# text uses it; add @:keep to it");
  - a user-defined conversion other than decimal's is refused;
  - an unresolved name is "the inline C# name X is no local, member or type here (C# error CS0103)".

- [ ] **Step 4: Run them**

CASE each; expected `ok`.

- [ ] **Step 5: Run everything and commit**

ALL, then OWN. Commit: `Resolve .NET types and members in inline C# as C# binds them`.

---

### Task 4: `CsLift`: Haxe locals, `this` and members in inline C#

**Files:**
- Create: `src/hxc/codegen/dotnet/CsLift.hx`
- Modify: `src/hxc/typing/Calls.hx` (`typeCallAccess`, :695: the hook after the call is typed); `CsToIl.hx`
  (a placeholder whose argument is a method `TField` in call position calls that method directly)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `CsSyntax.parse` and the `CsExpr` offsets (Task 2).
- Produces: `CsLift.lift(ctx:TyperContext, code:String, args:Array<TExpr>, p:Position):Null<{code:String,
  args:Array<TExpr>}>`. It returns null when the string does not parse or names nothing to lift. The hook
  then rebuilds the call with the new string constant and arguments, keeping its shape:
  `TCall(TIdent "__cs__")` stays one, so the analyzer's `hasUnbound` (Analyzer.hx:886) behaves as before.

- [ ] **Step 1: Add the cases and see them fail**

Add from `csexpr.cases.txt`:
- `inline-cs-names`;
- `inline-cs-names-haxe-scope`;
- `inline-cs-names-gencs-cannot-resolve`;
- `inline-cs-indexer-multi-arg`;
- `inline-cs-serverapp-patterns`.

Write `inline-cs-local-shadows-type-name @gencs` (Review Focus 2).

CASE each; expected unknown-name errors.

- [ ] **Step 2: Implement the lift**

Follow csexpr §6.1 item 2.
- Only when the platform is `cs`, `dotnet` is defined and the code string is a constant.
- These are lifted:
  - a simple name in head position (not after `.`, not in a type position) that `ctx.locals` has;
  - `this`;
  - a member of the current class chain, typed by the identifier path without raising or producing
    `TIdent`;
  - a chain over non-extern Haxe fields, under `@:privateAccess`.
- A lifted name becomes `{k}` with its typed expression appended. Replace the spans from last to first.
  Existing placeholders keep their numbers.

- [ ] **Step 3: Run them**

CASE each; expected `ok`. Then dump one of them with `-D dump=record` and check that the placeholder
arguments are `TLocal`/`TField`.

- [ ] **Step 4: Spec, run everything, commit**

- **The Inline C# bullet:** rewrite the subset list as ruling 1. Rewrite name resolution and DCE as rulings
  2 and 7, and result conversion as ruling 3. Drop the decimal bullet (ruling 5) and the "array access"
  indexer bullet (ruling 6). Name `get_Item`/`set_Item` as the first-class form.
- **Divergences:** add `inline-cs-names-haxe-scope` and `inline-cs-names-gencs-cannot-resolve` to *Interop
  divergences from gencs*.

ALL, then OWN. Commit: `Resolve names in inline C# in the Haxe scope for .NET`.

---

### Task 5: `@:classCode` and `@:functionCode`

**Files:**
- Modify: `TclassToIl.hx`: `planClass` :253 stops leaving the class out; the static-constructor and method
  refusals are at :1790 and :1990.
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Add the cases and see them fail**

Add from `codeblocks.cases.txt`:
- `classcode-pragma-only-ignored`;
- `classcode-members-are-an-error`;
- `functioncode-constructor-is-an-error`;
- `functioncode-method-is-an-error`;
- `serverapp-zlib-through-externs`;
- `serverapp-guid-functioncode-guarded`.

The last two are regressions that pass today. CASE each.

- [ ] **Step 2: Implement**

Follow codeblocks §5.
- A `@:classCode` whose non-blank lines, once comments are dropped, all start with `#pragma` is ignored.
  It is recorded as "ignored #pragma @:classCode in X".
- Any other `@:classCode` is `Unsupported.error` at the class with codeblocks' first text, and the class
  is planned as without it.
- `@:functionCode` is `Unsupported.error` with codeblocks' second text, at the field.
- Std classes keep the record at :1544.

- [ ] **Step 3: Run them, the spec, run everything, commit**

CASE each; expected `ok`. In the spec's Inline C# bullet, keep "`#pragma` is ignored; other content is an
error". Add that the class is still compiled, and name the replacements, rulings 8 and 9.

ALL, then OWN. Commit: `Refuse C# in @:classCode and @:functionCode without leaving the class out`.

---

### Task 6: gencs's indexers from `__get`/`__set`, `Array`'s included

**Files:**
- Create: `src/hxc/codegen/dotnet/IndexerToIl.hx`
- Modify:
  - `TclassToIl.hx`: plan after `ReflectionMembers.members` (:499), accessors before `ToString`, properties
    appended (:570), emit (:1975ff.);
  - `CompanionToIl.hx` (`declare` :289, attribute beside GenericInterface :357);
  - `SigWriter.hx` (`property` :90 takes index parameters);
  - `TexprCalls.hx`: split `isDynamicArrayAccess` (:1551), `arrayRead` (:1672);
  - `TexprToIl.hx`: assignment (:1153), `place` (:1266) gets a flag telling `++`/`--` from `op=`;
  - `TexprDynamic.hx` (:614), `TexprOps.hx` (:740);
  - `runtime/Array.hx` (`__get` :704, `__set` :710: `@:keep`).
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - `IndexerToIl.plan(g:DotnetCtx, c:TClass):Array<PropertyPlan>`. `PropertyPlan` gains
    `index:Array<IlSigNorm>`, and the accessor plans are a new `MethodPlan` kind
    `MIndexer(get:Null<TClassField>, set:Null<TClassField>, isSet:Bool, explicit:Null<IlSigNorm>)`.
  - `IndexerToIl.emit(...)` writes those accessors.
  - `TexprCalls.isCompanionArrayAccess(e1:TExpr):Bool`. `isDynamicArrayAccess` keeps only the `Dynamic`
    receiver.

- [ ] **Step 1: Add the cases and see them fail**

Add from `codeblocks.cases.txt`:
- `array-indexer-clr-surface`;
- `array-companion-element-access`;
- `array-companion-increment`;
- `haxe-class-indexers`;
- `haxe-class-indexer-follows-dce`;
- `haxe-class-indexer-kept-get`;
- `haxe-class-indexer-dce-full-is-an-error`;
- `haxe-class-indexer-readonly-store-is-an-error`;
- `haxe-class-indexer-hidden-setter`.

Add `array-companion-indexer` from `docs/superpowers/plans/2026-10-25-dotnet-generic-instantiations/m4.cases.txt`.
Update the existing cases as codeblocks §3 "What changes in existing cases" says:
- `cast-array-view`'s two `index write` lines become gencs's `InvalidCastException`;
- `array-clr-surface` (:13313) drops its `get_Item`/`set_Item` filters;
- so do the generic-reflection cases near :11678 and :11804.

CASE each.

- [ ] **Step 2: Implement the metadata**

codeblocks §3 "What gencs writes" and "What hxc must emit" give the flags, IL, row order, parameter names
(`index`/`value`, and `key`/`value` on explicit and companion accessors) and the `DefaultMember` blob
`01 00 04 49 74 65 6D 00 00`. Each refusal is `Unsupported.error`:
- **A `__get`/`__set` pair whose types disagree.**
- **A `__get` with no kept body:** "a[i] on X needs X.__get, which dead code elimination removed: mark it
  @:keep".
- **A store with no `__set`:** "X has no __set: a[i] on it cannot be assigned".

- [ ] **Step 3: Implement the lowering**

Lower as codeblocks §3 says:
- **Companion-typed arrays:**
  - a read is `callvirt Array::get_Item(int32)`;
  - a write is `set_Item(int32, object)`, keeping the value;
  - `++`/`--` go through a place whose load and store are those two;
  - `op=` keeps `callField`.
- **A Haxe `ArrayAccess` class** uses the nearest declaring accessor up the chain. Compound assignment and
  `++` go through the place the .NET indexer uses (TexprToIl.hx:1292ff.).

- [ ] **Step 4: Run them, the spec, run everything, commit**

CASE each; expected `ok`. Then fix the spec:
- retire "The `Array` indexer is missing" (about :259-266) and divergence 4 (about :402-406);
- correct "hxcs's `@:classCode`" to gencs's `__get`/`__set` rule in milestone 4's text and the 4b bullet;
- add `haxe-class-indexer-hidden-setter` to *Interop divergences from gencs*.

Correct the 3c comment at TexprCalls.hx:1551-1553 too.

ALL, then OWN. Commit: `Write gencs's indexers for classes with __get and __set, Array included, for .NET`.

---

### Task 7: IntPtr members and the `Socket.select` stub

**Files:**
- Modify: `ExternMembers.hx` (`chain` :212-236), `TexprToIl.hx` (`castExpr` :790)
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Add the cases and see them fail**

Add from `misc.cases.txt`: `netlib-intptr-calls`, `socket-select` and
`netlib-intptr-number-cast-is-an-error`. CASE each; expected "conversions between value types" refusals.

- [ ] **Step 2: Implement**

- In `chain`, after the value-type switch, at the first link and at each `sup` link:
  `parent = DotnetTypes.primitive(path) ?? parent` for IntPtr, UIntPtr and TypedReference (misc §2.5).
- In `castExpr`, before `viaOwn`: a cast with LIntPtr/LUIntPtr on one side and another value type on the
  other is `Unsupported.error` with the case's text.

- [ ] **Step 3: Run them, check the stub report, run everything, commit**

CASE each; expected `ok`. Run `tools/stdall.sh` with `D:/_hxc4b/t7`; `Socket.select` must be gone from its
list. In README.md:223, replace "`Socket.select` … is the one left" with what `stdall.sh` now lists
(`cs.Pointer.add` and `haxe.ds.EnumValueMap`; misc §0.2).

ALL, then OWN. Commit: `Bind IntPtr members on native int for .NET`.

---

### Task 8: `CompilerGeneratedAttribute` on `@:property` vars

**Files:**
- Modify: `TclassToIl.hx` (the `plan.properties` loop :1577); `GenerateDotnet.hx` (`externScope` :427
  reports `NetRefs.missing(path)` as `Unsupported.error`, not an internal error)
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Add the case and see it fail**

Add `property-var-compiler-generated` from `misc.cases.txt`. CASE it.

- [ ] **Step 2: Implement**

When `p.backing != null`, write three CustomAttribute rows on the backing field, the getter and the
setter. Each uses ctor `[System.Runtime.CompilerServices]CompilerGeneratedAttribute::.ctor()`, signature
`20 00 01`, scoped through `externScope`, and blob `01 00 00 00` (misc §3.3). Memoize the ctor token.

- [ ] **Step 3: Run it, the spec, run everything, commit**

CASE it; expected `ok`. In the spec, remove "Roslyn's `CompilerGeneratedAttribute` … is not written (it
is milestone 4b's)". ALL, then OWN. Commit: `Mark @:property backing fields and accessors CompilerGenerated
for .NET`.

---

### Task 9: C#'s betterness for a `null` argument (Ruling Z)

**Files:**
- Modify: `ExternMembers.hx`:
  - `applies` :725 returns its instantiated parameters;
  - `Bound` :108 keeps them;
  - `resolve` :674;
  - the kinds at :327-330;
  - `converts` :869;
  - the texts in `method` :336-348, `indexer` and `byValueText` :379.
- Modify: `tests/dotnet/netlib/ValLib/ValLib.cs` (append `netlib/ByNull.cs`)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `Resolution.RNullAmbiguous` (a definite CS0121) beside `RAmbiguous` (undecidable).

- [ ] **Step 1: Add the cases and see them fail**

Add from `misc.cases.txt`:
- `netlib-extern-null-betterness`;
- `netlib-extern-null-betterness-conversions`;
- `netlib-extern-null-to-declared-nullable`;
- `netlib-extern-null-to-declared-nullable-mismatch-is-an-error`;
- `netlib-extern-null-ambiguous-is-an-error`.

Ruling 13 carries refinements (a) and (c). So move the rows of `netlib-extern-null-betterness-conversions`
that need them (`N3D`, `P2`; misc §4.4.5) into a new case,
`netlib-extern-null-betterness-unmodelled-refused`. It expects the "hxc cannot tell which one C# picks for
a null argument" text.

Delete these committed cases, which become bindings: `netlib-extern-null-to-class-or-object-refused`
(:17316), `netlib-extern-null-to-params-or-object-refused` (:17330) and
`netlib-extern-padded-optional-null-refused` (:17344). CASE each new one.

- [ ] **Step 2: Implement**

misc §4.3-§4.4, items 1-4, and items (b) and (d) of 4.4.5:
- `betterForNull(yes, wantLength, kinds)`;
- a declared-`Nullable<T>` null is `KPlain`;
- a reference type to `Nullable<T>` is `ANo` unless `T` declares `op_Implicit`;
- a generic candidate with an unbound type parameter is `ANo` when no lambda or method-group argument is
  present.

The texts are those in §4.4 item 3. Keep "declare the parameter's exact type" for integer constants only.

- [ ] **Step 3: Run them, the spec, run everything, commit**

CASE each; expected `ok`. Rewrite the spec's **Argument values** bullet as misc §4.4 item 6 says. Rewrite
README.md:133-137's null example.

ALL, then OWN. Commit: `Bind a null extern argument by C#'s betterness for .NET`.

---

### Task 10: `--macro addMetadata("@:build(…)")` on a std class

**Files:**
- Modify: the front-end code that applies `addMetadata` metadata and runs `@:build`. Find it from
  `addMetadata` in `src/hxc` (macro API → context → class building). Its user-class path works; the std
  class path does not.
- Test: `tests/dotnet/cases.hx.txt`, and an OWN case if the bug is target-independent

- [ ] **Step 1: Write the case and see it fail**

Add `macro-add-build-to-std-class @gencs + --macro addMetadata("@:build(P.M.build())","StringTools")`.
The source is csexpr's probe `p/ordinal2/` folded into one module: `class M` under `#if macro` replaces
`StringTools.startsWith`'s body with `return cs.Syntax.code("{0}.StartsWith({1},
global::System.StringComparison.Ordinal)", s, start)`.

`P.main` prints `StringTools.startsWith("\u00ADabc", "abc")`. Its `[run]` is gencs's `False`. CASE it;
expected `True` from hxc.

- [ ] **Step 2: Find the cause**

Use superpowers:systematic-debugging. The research's lead: the same macro applies to a user class, so
look for where std classes are loaded or built before `--macro` metadata is registered, or for a path
that skips it for std modules. If the fault is not dotnet-specific, also add a small OWN case under
`tests/cases` that prints through a non-cs target, with expected output from Haxe 4.3.7.

- [ ] **Step 3: Fix, run, commit**

CASE it; expected `ok`. ALL, then OWN. Commit: `Apply @:build added by --macro addMetadata to std classes`.

---

### Task 11: Measure the apps, close 4b's fallout, and document

**Files:**
- Modify: whatever the measurement shows; `README.md` (the .NET feature list and the milestone 4 status);
  the spec's 4b bullet ("done", the numbers)
- Local only: `D:/_hxc4b/measure/`

- [ ] **Step 1: Measure**

MEASURE `t11` (plain and `OVERLAY=1`), then `desktopapp.sh … all` and `noavalonia`, each with
`MEASURE_OUT=D:/_hxc4b/measure`.

Expected with the overlay:
- nativepdf 0 and the server app 0, each writing a DLL;
- the desktop app's only error is its resources (4c).

Expected without it:
- the server app 4: the `@:classCode`, the 2 `@:functionCode`, and `Zlib.hx:25`'s `zlibNative` as an
  unknown name;
- nativepdf 2.

Check the statements after poisoned variables (misc §0.1): XLSXBuilder's and ReportingTools' `cell.…`
lines and Sqlite's uses of `id`. If they have errors, fix them under this task, or record them and stop
to ask if a fix is beyond a few lines.

- [ ] **Step 2: Verify and run the server DLL**

- `verify.sh <server dll> t11`: expected exactly the one BoxedPointer line gencs's DLL gives.
- `nochrome.sh <hxc> t11` with `OVERLAY=1`: expected SAME.
- `shape.sh <server dll> t11`: every difference must be a 4c item (`@:meta`/`@:strict`, nullability,
  events) or a recorded divergence. List them in the report.
- `tools/stdall.sh`: `Socket.select` gone.

Fix anything else under this task.

- [ ] **Step 3: Document**

- **README.md:** the inline-C# subset and its replacements, rethrow, indexers, and the state of milestone 4
  (4c left).
- **The spec's 4b bullet:** done, with the measured numbers and the two source changes the server app and
  its library need (rulings 8 and 9), as 4a's bullet records its own.
- **The ledger:** carry these to 4c:
  - `converts` (a) and (c);
  - `haxe.lang.Null`'s `_ofDynamic`/`op_Implicit`/`__NoValue__` (codeblocks §1, a 3c carry-over);
  - `cs.Pointer.add` and `haxe.ds.EnumValueMap`.

- [ ] **Step 4: Run everything and commit**

ALL, then OWN. Commit `tools/stdall.sh` and `tools/errors.py` with this task. Commit: `Measure milestone 4b
on the server app and the desktop app`.
