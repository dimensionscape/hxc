# .NET interop with referenced assemblies (milestone 4a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The server app and the desktop app type-check **and lower** against their referenced .NET assemblies
under `--cs <dir> -D dotnet`, as Haxe 4.3.7 gencs + hxcs build them. That covers:
- `System.Nullable<T>`;
- generic .NET method overloads;
- nested and referenced .NET types;
- hand-written `@:native` externs, including their optional arguments;
- .NET indexers;
- .NET interface properties and `@:property`;
- delegates.

When this plan is done, the 24 server app classes that milestone 3 left out compile, and their bodies
are measured for the first time.

**Architecture:** Most of the work is in the extern side of the dotnet generator.
- **`ExternMembers`:** binds a Haxe extern member to its metadata member. It learns generic arity, C#'s
  implicit conversions, optional parameters, generic inference for hand-written externs, and indexers.
- **`NetRefs` (new):** finds the assembly that defines a type no `--net-lib`/`--net-std` assembly
  defines. It looks beside the `--net-lib`s, then in the .NET reference pack. These assemblies are used
  only for lowering and never for typing.
- **Metadata:** `ModuleBuilder` and `MetaTables` gain the Property, PropertyMap and MethodSemantics
  tables. `TclassToIl` uses them for interface properties and `@:property` vars.
- **`ClosuresToClass`:** gains gencs's delegate branch.
- **`TexprToIl`/`TexprOps`:** learn null into a .NET value type and `Nullable` comparisons.

**Tech Stack:** Haxe 4.3 (hxc's source), hxcpp via Aedifex, the .NET 10 SDK and its reference pack, and
Haxe 4.3.7 + hxcs (the oracle; installed locally).

**Spec:** `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`. The relevant parts are
*Goals* (native interop at least as good as gencs), *Constraints* ("reference drift", determinism) and
*Milestones* item 4 with its bullets. Background: the 3c plan,
`docs/superpowers/plans/2026-10-25-dotnet-generic-instantiations.md`, and its ledger
`.superpowers/sdd/2026-10-25-dotnet-generic-instantiations/progress.md`, which holds the carried
milestone 4 items.

**Milestone 4 is split into three plans.**
- **4a (this plan):** what the server app and the desktop app need from referenced assemblies to compile.
- **4b:** the inline-C# subset (`__cs__`, `cs.Syntax.code`, `@:functionCode`, `@:classCode`), `Array`'s
  companion indexer, and the remaining std stubs (`EReg.matched`, `Socket.select`/`setTimeout`,
  `Sys.command`, `Process`).
- **4c:** `@:nativeGen` details, attributes (`@:strict`, `@:meta`), nullability metadata for the AI tool
  schemas, events defined in Haxe, manifest resources (`-resource`, `Context.addResource`,
  `-D dotnet-embed`), the carried items (covariant-return `@:overload` overrides, gencs's `T1`
  renaming), and milestone 4's exit: `HaxeServer.dll` builds, `cs/Server` builds against it, the AI tool
  schemas match today's, and ILVerify against the deployed assemblies is clean.

4a goes first because the 24 left-out classes (about 13.9k lines) have never been lowered, and the
other plans can't be scoped honestly until they have been.

**Research behind this plan.** Read the notes for the task you are on. They quote real gencs output and
give hxc's file:line for each piece. The server app file:line refer to
`<server-app>/haxe`, the checkout the measurements come from.
- `D:/_hxc4a/values/NOTES.md`: `Nullable<T>`, optional parameters, indexers, extern signature
  matching, by-ref arguments.
- `D:/_hxc4a/members/NOTES.md`: generic .NET method overloads, interface properties, `@:property`
  vars, delegates, NativeArray, InterfaceImpl rows.
- `D:/_hxc4a/refs/NOTES.md`: nested types, types beside the `--net-lib`s, the reference pack,
  forwarders, and the measurement plan.

Each notes directory has a `probe/` (or `cases/`) folder with gencs's C# and both outputs.

**Test material** lives next to this plan in `docs/superpowers/plans/2026-10-26-dotnet-interop-members/`:
- `values.cases.txt`, `members.cases.txt` and `refs.cases.txt`: candidate cases in the `cases.hx.txt`
  format. Every `@gencs` expectation is a real gencs net10.0 run. A divergence case carries hxc's
  expected output with gencs's under `[gencs]`, or gives gencs's C# compile error in its header
  comment. The `#` lines at the top of each file are notes, not case text.
- `netlib/ValLib`, `netlib/M4Lib`, `netlib/LibA` and `netlib/LibB`: the fixture libraries the cases
  pass with `--net-lib`. Each has a `.cs` file and a `.csproj`.
- `measure/`:
  - `measure.sh <hxc> <tag>`: the server app nativepdf, server and server with the stub report;
  - `attribute.py <after.log> [<before.log>]`: groups the new errors by enclosing class and stars the
    24 left-out classes;
  - `desktopapp.sh <hxc> all|noavalonia`: the desktop app, run out of tree.

  All of them write only under `$MEASURE_OUT` (default `D:/_hxc4a/measure`).
- `experiment/NetRefs.hx` and `experiment/refs-experiment.diff`: the refs area's working experiment
  (the server app 222 → 204, the desktop app's `noavalonia` 95 → 12). It is a reference for Task 3, not code
  to copy. The refs notes §5 say which shortcuts not to keep.

"Add case X from F" means: copy that case's text verbatim from F to the end of
`tests/dotnet/cases.hx.txt`.

**Branch:** `git switch -c dotnet-il-m4a main`. Don't push or open a PR.

## Rulings made for this plan

Each research area left open questions, each with a recommendation. These rulings settle them. The
execution ledger records them at the start, and the user reviews them with this plan.

1. **Hand-written externs bind the member C# would bind, under a restricted rule.**
   - Try an exact signature match first, which is today's rule, so `@:libType` members don't change.
   - Otherwise exactly one applicable candidate is chosen, or the call is a compile error. A candidate
     is applicable through C#'s implicit conversions: identity, reference upcast along the metadata
     chain, boxing, the implicit numeric widenings, and `A` → `Nullable<A>`, followed by an
     optional-parameter or `params` tail.
   - A generic IL method is a candidate when its type arguments follow from the extern's declared
     parameter types alone (`JsonSerializer.Serialize(obj:Any)` → `Serialize<object>`).
   - The return type, and the type of a field or property, must convert implicitly too, or it is a
     compile error. That makes the earlier "mismatch = compile error" ask a rule.
   - Full C# betterness rules are not needed.

   (Values Q1 and Q3, members Q7.)
2. **`x == null` on a .NET struct matches gencs.**
   - On `Nullable<T>` it is `!HasValue`.
   - On any other struct it is `x.Equals(default(T))`, so it is true for `default(DateTime)`.

   (Values Q2.)
3. **`null` into a .NET value type is `default(T)`, as in gencs.** That includes the server app's
   `WebApiHelpers.hx:630`, which builds a `Nullable<DateTime>` that *has* a value, 0001-01-01. This is a
   latent the server app bug; hxc reproduces it, and the user decides whether the server app fixes it. (Values Q5.)
4. **A left-out Haxe-optional value-type argument of an extern stays refused**, with a message that
   names the cause. gencs's C# fails to compile it (CS1503). (Values Q6.)
5. **An unsafe `cast` between value types boxes then converts, as gencs does**, for `Nullable` and
   struct pairs only (the server app's `IsActive = cast <Bool>`). Other value-type pairs stay refused. (Values Q7.)
6. **Compound assignment on a `Dynamic`-typed indexer element calls `get_Item`/`set_Item` directly**
   where gencs goes through reflection. The data is the same. (Values Q4.)
7. **Interface properties follow gencs's InterfaceProps rule, with two refusals.**
   - Overriding only the getter of a get-only .NET interface property is refused (gencs: CS0506).
   - The value of a set call is its argument, not `set_X`'s return value, as in gencs.

   (Members Q1 and Q2.)
8. **`@:property` vars become real CLR properties in 4a.** Today hxc silently compiles them as public
   fields. Semantic Kernel and System.Text.Json read properties, so the server app's AI tools would see no
   parameters. (Members Q6.)
9. **Delegates follow gencs's three shapes, and gencs's C# compile errors stay refused.**
   - The three shapes: a closure class's `Delegate` method, a method group, and a conversion wrapper.
   - No `<>O` cache for static method groups; only reference equality can tell.
   - A conversion whose types don't match the delegate's `Invoke` is refused (gencs: CS0030).

   (Members Q3 and Q5.)
10. **Some things stay as they are.**
    - hxc's InterfaceImpl row order: the sets match gencs's, and `GetInterfaces()` order is unspecified.
      (Members Q4.)
    - The refusals at `TclassToIl.hx:611` (generic .NET interface methods implemented by Haxe), `:850`
      (overriding methods of generic .NET classes) and `ExternMembers.hx:168` (operators of generic .NET
      types). Neither the server app nor the desktop app reaches them. (Members Q8.)
11. **Framework types that no supplied assembly defines come from the .NET reference pack**, for
    lowering only, never for typing. (Refs Q1-Q5.)
    - **Where the pack is:** `<dotnet root>/packs/Microsoft.NETCore.App.Ref/<v>.0.<highest>/ref/net<v>.0`,
      where `v` is the `-D dotnet-version` (default 10). The dotnet root is `DOTNET_ROOT`, else the
      directory of `dotnet` on `PATH`.
    - **No pack:** if one is needed and not found, that is a compile error naming the missing pack. There
      is no fallback to the shared runtime.
    - **What "beside" follows:** only the transitive AssemblyRefs of the `--net-lib`s. Each is looked up
      in its referencing file's directory first, then in the pack.
    - **AssemblyRef identity:** the identity of the file that defines the type.
    - **A type still unresolved:** the error reads "no referenced assembly defines the .NET type X".
12. **The test harness gains `@netlib`.** A bare `@netlib` passes `ValLib.dll`, and
    `@netlib=<Name>[,<Name>…]` passes the named fixture DLLs. Every fixture DLL is copied beside both
    outputs, so a referenced-but-not-passed library is found the way a user's would be.

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
  "does better" is recorded in the spec. The oracle is gencs's C# built for `net10.0` with
  `tests/dotnet/gencs.csproj.in`, referencing the case's `--net-lib`s.
- **Typing never sees an assembly that wasn't passed.** Assemblies found beside a `--net-lib` or in the
  reference pack are reference-only. Haxe 4.3.7 reports "Type not found" for them, and so does hxc.
- **Unsupported constructs are clean errors.** In user code, anything not supported yet is an
  `Unsupported` error at the construct's position, never an internal error and never a crash. In std
  code it becomes a stub.
- **Read-only:** `<server-app>`, `<desktop-app>`, `D:/_github/haxeui-cs` and
  `C:/HaxeToolkit/haxe/lib`. Measurements run their builds out of tree (`measure/`).
- **Cases are compiled without `-debug`.**
- **Commands used below:**
  - BUILD: `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/ HAXE_STD_PATH=C:/HaxeToolkit/haxe/std HXCPP_COMPILE_CACHE=D:/_github/hxc-toolchain/hxcpp-cache haxelib run aedifex build cpp .`
  - CASE `<name>`: `MSBUILDDISABLENODEREUSE=1 timeout 900 tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --case <name>`
  - ALL: the same without `--case`, under `timeout 1800`; expected `all N cases passed`.
  - OWN: `cd D:/_github/haxe-conformance && neko run.n run --compiler D:/_github/hxc/bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected -j 4`; expected `0 failed`.
  - MEASURE `<tag>`: `docs/superpowers/plans/2026-10-26-dotnet-interop-members/measure/measure.sh bin/cpp/windows/x64/release/bin/hxc.exe <tag>`.

## Review Focus

1. **C# code reading a Haxe class's implementation of a .NET interface property.** the server app's `Shared.dll`
   calls `handler.systemPrompt` through `IChatHandler`. The C# side must see the property, and its value
   must come from the Haxe getter. Test: `netlib-iface-property-from-csharp @gencs @netlib=M4Lib` in
   Task 7. It adds a static `M4.PropReader.Describe(IHandler h)` to M4Lib that reads both properties
   through the interface.
2. **System.Text.Json serializing a `@:property` model, as the server app's AI tools do.** The JSON must have
   the properties' names and values, as gencs's build prints. Test: `property-json @gencs` in Task 8.
   It uses the framework extern from Task 3 and the generic inference from Task 5.
3. **Two hand-written extern overloads that both apply.** hxc must refuse the call, not pick one by
   metadata order. Ruling 1 is stricter than C# here: C# would pick the more specific overload, and hxc
   refuses, which is clean and can be relaxed later. Test: `netlib-extern-ambiguous-is-an-error @netlib` in Task 5.
4. **Removing an event handler with a delegate made from the same method again.**
   `c.add_Noted(this.onNote); c.remove_Noted(this.onNote)` must leave no handler, because .NET delegate equality
   compares target and method. That only works if a method group becomes a delegate over the method
   itself, not over a wrapper. Test: a remove line in `netlib-delegates-methods-and-combine` in Task 9.
5. **A delegate .NET code keeps and calls later, from another thread.** `Thread.create` and stored
   callbacks must still see the captured locals. Test: `thread-create @gencs` in Task 9, plus a
   stored-callback line in `netlib-delegates`.

---

## File structure

| File | Responsibility |
| --- | --- |
| `tests/dotnet/run.sh`, `tests/dotnet/netlib/{ValLib,M4Lib,LibA,LibB}/` (new) | `@netlib` fixtures: built once, passed to both compilers, copied beside both outputs, part of the gencs cache key |
| `src/hxc/codegen/dotnet/ExternMembers.hx` | Binding extern members to metadata: arity, applicability, optional tail, generic inference, return/field checks, indexers |
| `src/hxc/codegen/dotnet/NetRefs.hx` (new) | The assembly that defines a type outside the loaded libraries: beside the `--net-lib`s, then the reference pack, through forwarders |
| `src/hxc/codegen/dotnet/NetLibrary.hx`, `NetSetup.hx`, `IlData.hx`, `IlMetaReader.hx`, `src/hxc/context/Context.hx` | Reference-only libraries, AssemblyRef/forwarder accessors, the dotted-name map, Param constants and default attributes |
| `src/hxc/codegen/dotnet/DotnetTypes.hx`, `GenerateDotnet.hx` | `externPathOf` for nested types; `defined`/`externScope` through `NetRefs` |
| `src/hxc/codegen/dotnet/TexprToIl.hx`, `TexprOps.hx`, `TexprCalls.hx` | Null into value types, `Nullable` comparisons and strings, unsafe value casts, default arguments, indexer reads/writes/places, property calls |
| `src/hxc/codegen/dotnet/MetaTables.hx`, `ModuleBuilder.hx`, `SigWriter.hx` | PropertyMap, Property and MethodSemantics tables; the HasSemantics coded index; PROPERTY signatures |
| `src/hxc/codegen/dotnet/TclassToIl.hx`, `ReflectionMembers.hx` | Interface properties and `@:property` vars: accessors, backing fields, rows, reflection |
| `src/hxc/codegen/dotnet/ClosuresToClass.hx` | gencs's delegate branch: `Delegate` methods, method groups, conversion wrappers |
| `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`, `README.md` | Interop divergences; milestone 4 status; the .NET feature list |

---

### Task 1: `@netlib` fixtures in the test harness

**Files:**
- Create: `tests/dotnet/netlib/ValLib/ValLib.cs` and `ValLib.csproj`, and the same for `M4Lib`, `LibA`
  and `LibB`. Copy them from the sibling folder's `netlib/`.
- Modify: `tests/dotnet/run.sh` (its header comment, tag parsing, the hxc compiles, the gencs command,
  the csproj sed at about :221, the run directory, and the gencs cache key at about :378).
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - **Tag syntax:** `@netlib` (meaning `ValLib`) and `@netlib=<Name>[,<Name>…]`. Every later task's
    cases use these.
  - **Fixture directory:** `$HXC_TEST_TMP/netlib/`, where each fixture is built once per harness run
    (`dotnet build -c Release -o …`). The build is skipped when a hash of the fixture sources is
    unchanged. `LibA` references `LibB`, so both must land in the same directory.
  - **For a `@netlib` case:**
    - `--net-lib <abs>/<Name>.dll` for each named library, added to both hxc compiles and to gencs's
      haxe command;
    - a `<Reference Include="<abs>/<Name>.dll" />` for each, in the generated csproj;
    - **every** fixture DLL copied into hxc's output directory after the determinism `cmp`, and beside
      gencs's `P.dll`.
  - **The gencs cache key** covers the fixture sources.

- [ ] **Step 1: Add the regression cases and see them fail**

The research found these shapes already compile and match gencs, so each case should fail only because
the harness can't pass a `--net-lib` yet:
- from `values.cases.txt`: `netlib-nullable-dynamic`, `netlib-nullable-better`, `netlib-byref` and
  `netlib-byref-refused`;
- from `members.cases.txt`: `netlib-native-arrays` and `netlib-interface-impls`.

Then CASE each. The expected failure is "Type not found : vallib.…" or the like.

- [ ] **Step 2: Implement `@netlib` in `run.sh`**

Follow the values notes ("Harness change needed for the cases") with the refs notes' §6 additions.
Document the tag in the header comment, next to `@gencs`.

`netlib-nullable-better` is a deliberate divergence: gencs throws "Method get_Value not found". Add it
to the spec under a new milestone-4 subsection, *Interop divergences from gencs*. Later tasks append
to it.

- [ ] **Step 3: Run them**

CASE each from Step 1; expected `ok`. Run one more case with no `@netlib`, `hello` or any short case,
to check that cases without the tag are unchanged.

- [ ] **Step 4: Run everything and commit**

ALL, then OWN. Commit: `Pass fixture .NET libraries to .NET cases with @netlib`.

---

### Task 2: Generic arity in extern overload matching

**Files:**
- Modify: `src/hxc/codegen/dotnet/ExternMembers.hx` (`method`, the exact pass at about :134) and
  `TexprCalls.hx` (the guard at about :957)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `ExternMembers.method` never returns an IL method whose generic arity differs from the
  Haxe field's `cf.params.length`. Task 5's applicability pass builds on this exact pass.

- [ ] **Step 1: Add the cases and see them fail**

Add from `members.cases.txt`:
- `netlib-generic-overloads`;
- `netlib-generic-overload-picks-generic`;
- `netlib-generic-overload-order`;
- `netlib-generic-two-generic-overloads`;
- `netlib-generic-members-refused`.

CASE each. Expect "generic .NET methods" refusals, and, for `-picks-generic`, today's silent wrong
call (NHibernate's `List()` before `List<T>()`), which shows up as an `InvalidCastException` in `[run]`.

- [ ] **Step 2: Implement**

- Skip any IL method with `m.mtypes.length != cf.params.length` in the exact pass (members notes §2.6).
- Make the TexprCalls guard refuse in both directions, with the message "a .NET method with another
  generic arity (internal: overload matching)". The guard can only fire after a matching bug, so its
  message says so.

- [ ] **Step 3: Run them**

CASE each; expected `ok`.

- [ ] **Step 4: Run everything and commit**

ALL, then OWN. MEASURE `t2`: the server app should drop by 50 errors, to 172. Write the numbers in the
report.

Commit: `Match extern overloads by generic arity for .NET`.

---

### Task 3: Nested types, and types beside the `--net-lib`s or in the reference pack

**Files:**
- Create: `src/hxc/codegen/dotnet/NetRefs.hx`
- Modify:
  - `NetLibrary.hx`: a reference-only flag, plus AssemblyRef and forwarder accessors;
  - `NetSetup.hx`: locating the reference pack;
  - `src/hxc/context/Context.hx`: the dotted-name map and the resolver's state;
  - `DotnetTypes.hx`: `externPathOf` at about :184 and `defined` at about :202;
  - `ExternMembers.hx`: `rawClass`, `operators` and `enumUnderlying`;
  - `GenerateDotnet.hx`: `externScope` at about :420;
  - `TclassToIl.hx`: `interfaceClosure`'s `netPathMap` check at about :539.
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - **`Context.netDottedMap:Map<String, IlPath>`:** the dotted .NET name (`NetConverter.ilpathS`, which
    joins nested types with `.`) to its `IlPath`. `NetLibrary.load` fills it beside `netPathMap`; the
    first library wins.
  - **`NetRefs.of(ctx:Context):NetRefs`**, with:
    - `definer(path:IlPath):Null<NetLibrary>`: a loaded library first, then breadth-first over the
      `--net-lib`s' AssemblyRefs (beside the referencing file, then the pack), following forwarders,
      then a lazily built index of the pack for a hand-written extern no assembly references;
    - `missing(path:IlPath):String`: the refusal text for a type no step finds, which names the missing
      reference when one is known.
  - **`NetLibrary.refOnly:Bool`:** a library `NetRefs` loaded. It is never in `ctx.netLibs` or
    `netPathMap` and has no extern-type loader.
  - **`NetLibrary.assemblyRefs():Array<String>`** (names) and
    **`NetLibrary.forwarderTarget(path:IlPath):Null<String>`** (an assembly name).
  - **`NetSetup.referencePack(ctx:Context):Null<String>`**, which returns the `ref/net<v>.0` directory
    from ruling 11, or null.

- [ ] **Step 1: Add the cases and see them fail**

Add all six cases from `refs.cases.txt`:
- `netlib-nested-types`;
- `netlib-framework-extern`;
- `netlib-forwarded-extern`;
- `netlib-dependency-beside`;
- `netlib-dependency-not-typed`;
- `netlib-unknown-native-type`.

CASE each. Expect "outside the referenced assemblies" refusals. The expected text of
`netlib-unknown-native-type` changes in Step 2.

- [ ] **Step 2: Implement**

Follow refs notes §2a and §3; the experiment shows the shape. Don't copy its shortcuts (§5):
- it uses fixed dotnet roots, where ruling 11 finds the root;
- it walks the `--net-std` libraries' references;
- it scans the pack linearly.

Refusals:
- "no referenced assembly defines the .NET type X";
- the reference pack missing when one is needed: "the .NET <v> reference pack
  (Microsoft.NETCore.App.Ref) was not found; it is needed for X".

`netlib-dependency-beside` is a deliberate divergence: gencs fails with CS0012. Record it in the spec's
*Interop divergences from gencs*. Also correct the spec's milestone-4 bullet: `ToolFunction` is a
nested type of `Shared.dll`, not a type from its references.

- [ ] **Step 3: Run them**

CASE each; expected `ok`. Check that the AssemblyRef in `netlib-framework-extern`'s DLL is
`System.Text.Json 10.0.0.0 cc7b13ffcd2ddd51` (a metadata dump, or HxcCheck), and say how you checked.

- [ ] **Step 4: Run everything, measure, and commit**

- ALL, then OWN.
- MEASURE `t3`. The server app should lose 19 errors and gain at most `License.hx:468`'s
  `JsonSerializer.Serialize`, which Task 5 handles.
- Run `measure/desktopapp.sh` `all` and `noavalonia`; both should give the same errors.

Commit: `Resolve nested and referenced .NET types for lowering`.

---

### Task 4: `Nullable<T>` and `null` into .NET value types

**Files:**
- Modify:
  - `src/hxc/codegen/dotnet/TexprToIl.hx`: `convert` at about :270-285 and :350-356;
  - `DotnetTypes.hx`: a new static `isSystemNullable`;
  - `TexprOps.hx`: `compare` at about :267-300 and `stringifyTop` at about :743-770.
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces: `DotnetTypes.isSystemNullable(s:IlSigNorm):Bool` (static), true for
  `LValueType({ns:["System"], name:"Nullable`1"}, [_])`. Task 5's applicability uses it for
  `A` → `Nullable<A>`.

- [ ] **Step 1: Add the cases and see them fail**

Add from `values.cases.txt`:
- `netlib-nullable-null`;
- `netlib-nullable-string`;
- `netlib-struct-null`;
- `netlib-nullable-casts`.

CASE each. Expect the refusals "null as a value type", "comparing a value type with null" and
"conversions between value types", plus the `NullReferenceException` in `netlib-nullable-string`.

- [ ] **Step 2: Implement**

Follow values notes §1 ("IL hxc must emit", "What hxc's code needs"):
- `null` into any .NET value type is `default(T)` (ruling 3);
- `Nullable` compared with null uses `get_HasValue`;
- any other struct compared with null uses `Equals(default(T))` (ruling 2);
- an unsafe cast boxes then converts, for `Nullable` and struct pairs only (ruling 5);
- a `Nullable` in string context is `box` plus `Std.string`.

Keep the type-parameter refusal in `compare`.

- [ ] **Step 3: Run them**

CASE each; expected `ok`.

- [ ] **Step 4: Run everything, measure, and commit**

ALL, then OWN. MEASURE `t4`: the server app should lose the 71 errors of these two kinds.

Commit: `Lower null into .NET value types and Nullable comparisons as gencs does`.

---

### Task 5: Hand-written externs: implicit conversions, optional parameters, generic inference

**Files:**
- Modify:
  - `src/hxc/codegen/dotnet/IlData.hx`: `IlMethodArg` at about :142;
  - `IlMetaReader.hx`: Param constants at about :949-958, and the Param custom attributes;
  - `ExternMembers.hx`: `method` at about :119-157, and `field` at about :199;
  - `TexprCalls.hx`: `externCall`, `externCtor` and `pushArgs`, at about :387 and :950-1005.
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 2's exact pass; `DotnetTypes.isSystemNullable` (Task 4); `NetRefs` (Task 3), for
  externs over framework types.
- Produces:
  - **`IlMethodArg`** gains `constant:Null<IlConstant>` and `pdefault:Null<IlParamDefault>`.
  - **`enum IlParamDefault`**, in IlData.hx, with the cases
    `PDecimal(scale:Int, negative:Bool, hi:Int, mid:Int, lo:Int)`, `PDateTime(ticks:haxe.Int64)` and
    `PParamArray`.
  - **`ExternMembers.method`'s result** gains:
    - `omitted:Array<IlMethodArg>`: the trailing parameters the call leaves out;
    - `typeArgs:Null<Array<IlSigNorm>>`: the inferred type arguments, for a non-generic extern field
      bound to a generic IL method.
  - **`ExternMembers.implicitlyConverts(from:IlSigNorm, to:IlSigNorm):Bool`:** ruling 1's conversions.
  - **`TexprCalls.pushDefault(arg:IlMethodArg, slot:IlSigNorm):Void`:** one omitted argument, following
    the values notes §2 table.

- [ ] **Step 1: Add the cases and see them fail**

Add from `values.cases.txt`:
- `netlib-optional-defaults`;
- `netlib-optional-declared`;
- `netlib-optional-declared-value-type`;
- `netlib-extern-signature-match`.

Write two new cases:
- **`netlib-extern-ambiguous-is-an-error @netlib`** (Review Focus 3). Add to ValLib two overloads that
  both accept a declared `HPanel` argument through upcasts, for example `Pick(Visual)` and
  `Pick(Control)` declared as `Pick(p:HPanel)`. It expects the compile error "more than one .NET
  overload of ValLib.<Type>.Pick accepts (ValLib.Panel)" at the call.
- **`netlib-extern-generic-inference @gencs`**. It uses the server app's `CSTools.hx` extern shape over
  `System.Text.Json.JsonSerializer`: `Serialize(obj:Any):String` and
  `Serialize(obj:Any, opts:JsonSerializerOptions):String`. It serializes an anonymous object, a
  `@:nativeGen` class with plain fields, and a `List_1<Int>`, with and without
  `opts.IncludeFields = true`. It has no `[run]`, so gencs's output is the expectation.

CASE each. Expect the refusal "the .NET method … with these argument types" from
`ExternMembers.hx:152`.

- [ ] **Step 2: Implement**

Follow values notes §2 and §4, and members notes §2.4, with ruling 1:
- an exact pass first;
- then the applicability pass, with generic IL candidates inferred from the declared parameter types;
- exactly one candidate, or one of these refusals:
  - "no .NET overload of <Type>.<m> takes (<types>)";
  - "more than one .NET overload of <Type>.<m> accepts (<types>)".

Then:
- **Return types:** check them on a hand-written extern; a mismatch is "<Type>.<m> returns <IL type>,
  which does not convert to the declared <type>".
- **Fields and properties:** check `field` the same way, reads metadata → declared and writes declared
  → metadata.
- **Refusal wording (ruling 4):** "leaving out the optional value-type argument <name> of an extern
  method".

- [ ] **Step 3: Run them**

CASE each; expected `ok`.

- [ ] **Step 4: Run everything, measure, and commit**

- ALL, then OWN.
- MEASURE `t5`. `License.hx:468` should be gone, with nothing new in nativepdf.
- Run `measure/desktopapp.sh all`: DeviceScale and Focus should be gone.

Commit: `Bind hand-written .NET externs as C# would, with optional and inferred arguments`.

---

### Task 6: .NET indexers

**Files:**
- Modify:
  - `src/hxc/codegen/dotnet/ExternMembers.hx`: new `indexer`;
  - `TexprCalls.hx`: `arrayRead` at about :1223-1248;
  - `TexprToIl.hx`: `assign` at about :1058-1156 and `place` at about :1197, plus the property-store
    value refusal at about :1147.
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - **`typedef ExternIndexer`**, in ExternMembers.hx:
    `{parent:IlSigNorm, getter:Null<String>, setter:Null<String>, indexSig:IlSigNorm, valueSig:IlSigNorm}`.
  - **`ExternMembers.indexer(c:TClass, params:Array<T>):Null<ExternIndexer>`:** the indexer C# picks
    for one `int32` argument, from values notes §3 "Which indexer".
  - **The value of an assignment through an indexer or a .NET property** is the stored value, which
    one shared helper keeps.

- [ ] **Step 1: Add the cases and see them fail**

Add from `values.cases.txt`:
- `netlib-indexers`;
- `netlib-indexer-compound`;
- `netlib-indexer-dynamic-write`.

CASE each. Expect "array access" and "this kind of assignment".

- [ ] **Step 2: Implement**

Follow values notes §3 ("IL hxc must emit", "What hxc's code needs") and ruling 6. Also lift the
refusal "the value of an assignment to a .NET property" through the shared helper.

`netlib-indexer-dynamic-write` is a deliberate divergence: gencs fails with CS0266, and hxc converts.
Record it in the spec's *Interop divergences from gencs*, together with ruling 6.

- [ ] **Step 3: Run them**

CASE each; expected `ok`.

- [ ] **Step 4: Run everything, measure, and commit**

ALL, then OWN. MEASURE `t6`: the server app should lose the three `EmailNotifications.hx` errors.

Commit: `Lower .NET indexers and the value of .NET property stores`.

---

### Task 7: Property metadata, and Haxe classes implementing .NET interface properties

**Files:**
- Modify:
  - `src/hxc/codegen/dotnet/MetaTables.hx`: tables 0x15 PropertyMap, 0x17 Property and 0x18
    MethodSemantics, and the HasSemantics coded index;
  - `ModuleBuilder.hx`;
  - `SigWriter.hx`;
  - `TclassToIl.hx`: `interfaceImpls` at about :595, member planning, `virtuality`, and `write`;
  - `ReflectionMembers.hx`: at about :298;
  - `TexprCalls.hx` and `TexprToIl.hx`: calls to `get_X`/`set_X`.
- Test: `tests/dotnet/cases.hx.txt`, and `tests/dotnet/netlib/M4Lib/M4Lib.cs` (for `PropReader`)

**Interfaces:**
- Produces:
  - **`ModuleBuilder.property(owner:Int, name:String, sig:Bytes):Int`.** It writes a Property row, and
    the PropertyMap row for the owner's first property. Rows are grouped by owner, as `interfaceImpl`
    groups them.
  - **`ModuleBuilder.methodSemantics(semantics:Int, method:Int, property:Int):Void`.** Getter is
    `0x0002` and Setter is `0x0001`; the table is sorted by association.
  - **`SigWriter.property(type:IlSigNorm):Bytes`.** `PROPERTY | HASTHIS` (0x28), 0 parameters, then
    the type.
  - **`TclassToIl` property plan:** each property var in a class records its private body methods
    (`_get_X`, `_set_X`), its public accessors and its Property row. Task 8 adds `@:property` vars to
    the same plan.

- [ ] **Step 1: Add the cases and see them fail**

Add from `members.cases.txt`:
- `iface-property-bcl`;
- `netlib-iface-properties`;
- `netlib-iface-property-override`;
- `netlib-iface-property-getonly-override`.

Write `netlib-iface-property-from-csharp @gencs @netlib=M4Lib` (Review Focus 1):
- add to M4Lib a static `PropReader.Describe(IHandler h):string` returning
  `h.Guid + "|" + h.Prompt`, over M4Lib's existing `IHandler` (get-only `Guid` and `Prompt`, plus
  `Plugins()`);
- the Haxe class implements the properties with getters that count their calls;
- the case prints `Describe`'s result and the counts.

CASE each. Expect "properties of .NET interfaces".

- [ ] **Step 2: Implement**

Follow members notes §1.3-1.5 and ruling 7:
- gencs's InterfaceProps rule decides which vars become properties;
- the private non-virtual `_get_X`/`_set_X` bodies, and the public accessors, use the exact flags in the
  §1.4 table;
- every Haxe use goes through the public accessor;
- a set call's value is its argument;
- reflection lists `get_X`/`set_X` in `Type.getInstanceFields` and the var in `Reflect.fields`.

Refuse cleanly, each with its own message, the gencs C# compile errors listed in §1.5:
- a property reached only through a Haxe interface that extends the .NET one;
- a physical var implementing a .NET property;
- a property of a different type from the interface's;
- overriding only the getter of a get-only property.

- [ ] **Step 3: Run them**

CASE each; expected `ok`. Check with a metadata dump (members notes `tools/rows`) that `Handler`'s
Property, PropertyMap and MethodSemantics rows and accessor flags equal gencs's DLL. Say in the report
how you checked.

- [ ] **Step 4: Run everything, measure, and commit**

- ALL, then OWN.
- MEASURE `t7`. The 38 "left out: …ChatHandler" lines and the 365 skipped closure classes should be
  gone. Run `measure/attribute.py` against `t6` and put its summary line in the report. New errors in
  the 24 classes are expected; Tasks 8-10 deal with them.

Commit: `Write .NET property metadata and implement .NET interface properties`.

---

### Task 8: `@:property` vars as CLR properties

**Files:**
- Modify: `src/hxc/codegen/dotnet/TclassToIl.hx` (planning `@:property` vars), `ReflectionMembers.hx`,
  `TexprToIl.hx` and `TexprCalls.hx` (field reads and writes)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 7's property plan, `ModuleBuilder.property`/`methodSemantics` and `SigWriter.property`;
  Task 3's framework externs; Task 5's generic inference.

- [ ] **Step 1: Add the cases and see them fail**

Add `property-meta-vars` from `members.cases.txt`. Write `property-json @gencs` (Review Focus 2):
- a `@:nativeGen` class with `@:property public var name:String = "";`, `@:property public var count:Int`
  and a `Nullable_1<Int>` `@:property` set to null;
- serialized with the Task 5 `JsonSerializer` extern;
- printing the JSON, and `Reflect.fields`/`Type.getInstanceFields` of an instance.

It has no `[run]`. CASE each: today hxc prints `{}`, or JSON without the properties, where gencs prints
them.

- [ ] **Step 2: Implement**

Follow members notes §1.6 and ruling 8:
- a private `<X>k__BackingField`;
- public non-virtual `HideBySig | SpecialName` accessors;
- the Property and MethodSemantics rows;
- every Haxe access goes through the accessors, including the constructor's initializer and reflection.

- [ ] **Step 3: Run them**

CASE each; expected `ok`.

- [ ] **Step 4: Run everything and commit**

ALL, then OWN. Commit: `Compile @:property vars to CLR properties for .NET`.

---

### Task 9: Haxe functions as .NET delegates

**Files:**
- Modify:
  - `src/hxc/codegen/dotnet/ClosuresToClass.hx`: the delegate branch;
  - `TexprCalls.hx`: `magicCall`'s `__delegate__` at about :768;
  - `TexprToIl.hx`: the new expression form;
  - the std stub list that stubs `Thread.create`; find it with `grep -rn "Thread" src/hxc/codegen/dotnet`.
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 5's `ExternMembers` binding, for a delegate's `Invoke` and `.ctor` on its TypeSpec.

- [ ] **Step 1: Add the cases and see them fail**

Add from `members.cases.txt`:
- `netlib-delegates`;
- `netlib-delegates-methods-and-combine`;
- `delegate-type-mismatch`;
- `thread-create`.

Then extend two of them:
- **`netlib-delegates-methods-and-combine`** (Review Focus 4): on an M4Lib `Client`, add
  `c.add_Noted(this.onNote); c.remove_Noted(this.onNote); c.Fire("x");`, using an instance method
  `onNote(s:String):Void`. It should print M4Lib's "nobody noted x".
- **`netlib-delegates`** (Review Focus 5): add a stored callback. M4Lib keeps a `Func_2` from a
  capturing lambda, the Haxe frame returns, then M4Lib calls it twice.

These changes need fresh gencs output. The harness takes it live, so leave no hand-written `[run]`
where gencs compiles.

CASE each. Expect "untyped code" at each conversion.

- [ ] **Step 2: Implement**

Follow members notes §3.3-3.5 and ruling 9:
- a TFunction gets the closure class's `Delegate` method, typed from the delegate's `Invoke` after
  substitution, and its `__hx_invokeN` forwards to it;
- an FStatic, or an FClosure on a simple receiver, becomes a method group (`ldftn`, or `dup; ldvirtftn`);
- anything else gets a conversion wrapper;
- a delegate's `op_Addition`/`op_Subtraction` lower to `Delegate.Combine`/`Remove` plus `castclass`;
- a conversion whose types don't match is refused: "a function of type <t> converted to the .NET
  delegate <D>, whose Invoke takes <sig>".

Remove the `Thread.create` stub; `createWithEventLoop` follows from the same branch. Check with
`-D dotnet-stub-report` that neither is stubbed any more.

- [ ] **Step 3: Run them**

CASE each; expected `ok`.

- [ ] **Step 4: Run everything, measure, and commit**

- ALL, then OWN.
- MEASURE `t9`. The 4 visible delegate errors and the delegate errors in the 24 classes should be gone.
- Run `measure/desktopapp.sh all`: `Thread.create` should be absent from the stub report.

Commit: `Convert Haxe functions to .NET delegates as gencs does`.

---

### Task 10: Measure the 24 classes, close 4a's fallout, and document

**Files:**
- Modify: whatever the fallout needs, within this plan's constructs; the spec (milestone 4); `README.md`
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Measure and classify**

MEASURE `t10`, and run `measure/desktopapp.sh` with `all` and `noavalonia`. Classify every remaining
the server app, nativepdf and the desktop app error by cause, against its source line (`measure/attribute.py`,
and `tools/show.py` from the members notes). The causes are:

| Cause | Meaning |
| --- | --- |
| (a) 4a construct | this plan's constructs |
| (b) 3c construct | casts, companions, the Array forward, generic reflection: the refusals the spec says were never measured in these classes |
| (c) 4b | inline C#, `Array`'s indexer, std stubs |
| (d) 4c | attributes, resources, events, nullability |
| (e) other | anything else, with its cause |

Make a table in the report: cause, count, and example file:line.

- [ ] **Step 2: Fix (a) and (b)**

For each error of cause (a) or (b):
1. write a minimal case reproducing it, `@gencs` where gencs compiles it;
2. see the case fail;
3. fix it;
4. see the case pass.

If one cause needs more than about a day's work, or a design decision this plan doesn't make, don't fix
it. Write the shape, the count and a proposed rule in the report, and the controller rules on it.

- [ ] **Step 3: Document**

- **Spec, milestone 4 section:**
  - mark 4a's items done;
  - list 4b's and 4c's scope as above;
  - keep *Interop divergences from gencs* complete: the divergences from Tasks 1, 3 and 6, ruling 6,
    and any from Step 2.
- **`README.md`:** describe the interop that now works, and change the "not supported yet" list to
  what remains for 4b and 4c.
- **Rulings 3 and 11** are user-facing:
  - say in the README that a `null` into a .NET struct is `default(T)`;
  - say that framework types come from the .NET reference pack (the SDK must be installed).

- [ ] **Step 4: Run everything, measure, and commit**

- ALL, then OWN.
- MEASURE `final`, plus the desktop app `all` and `noavalonia`.
- The report gives:
  - nativepdf, server and the desktop app counts against 3c's 4 / 222 / 12;
  - the cause table;
  - the attribution summary for the 24 classes.

Commit: `Measure milestone 4a on the server app and the desktop app`.
