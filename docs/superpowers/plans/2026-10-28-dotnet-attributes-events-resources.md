# Attributes, resources, events and milestone 4's exit (milestone 4c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Milestone 4's exit holds. The server app builds `HaxeServer.dll` with its embedded resources. The
server app's C# solution compiles against that DLL with no change to its C# source. Its AI tool schemas equal
those of the gencs build the server's build script makes. ILVerify against the deployed assemblies prints
nothing. On the way, hxc stops dropping what it drops silently today: `@:meta`/`@:strict` attributes,
pseudo-attributes (std's `FPHelper` reads zeros, and `NativeStackTrace.exception` is shared across threads),
macro resources (on every target), and Haxe-defined events.

**Architecture:**
- **Attributes:** a new `AttributesToIl` resolves each `@:meta` entry with C#'s rules (the attribute type, its
  constructor chosen from constant arguments, named arguments, `AttributeUsage`), encodes the ECMA-335 blob and
  writes the CustomAttribute row. The three ad hoc encoders written so far (CompilerGenerated, DefaultMember,
  GenericInterface) move onto it.
  - Pseudo-attributes become type and field flags plus two new tables, ClassLayout and FieldLayout. They are
    decided when the class is planned.
  - A `NullableMetadata` part writes Roslyn's `Nullable`/`NullableContext` rows for the packages that
    `-D dotnet-nullable` names.
- **Resources:**
  - The macro API's `Context.addResource` and `getResources` use the compile's resources, which fixes every
    target.
  - A new `ResourcesToIl` writes the ManifestResource rows and the PE resources blob, and fills
    `haxe.Resource.content`.
- **Events:** a Cs filter adds Haxe's own `@:event` checks. A new `EventToIl` (shaped like `IndexerToIl`) writes
  the Event/EventMap/MethodSemantics rows, with custom and field-like accessors on the property precedent.
- **The exit pieces:**
  - `haxe.lang.Null<T>` gets the conversion from `T`, and `_ofDynamic`, that C# consumers compile against.
  - `haxe.lang.BoxedPointer` is no longer written.
- **The carried items that real code reaches, or that miscompile silently,** are fixed: gencs's `T1` rename,
  type-parameter argument inference, `EnumValueMap`, the `@:nativeGen` constraint binding, and the inline-C#
  `f` literal. The rest stay clean refusals, as ruling 17 lists.

**Tech Stack:** Haxe 4.3 (hxc's source), hxcpp via Aedifex, the .NET 10 SDK and its reference pack, and
Haxe 4.3.7 + hxcs (the oracle; installed locally).

**Spec:** `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`. The relevant parts:
- *Milestones*, item 4: the **4c** bullet is this plan's scope and the **Exit** its last task. The rulings below
  amend both. The 4a/4b bullets give the models this plan builds on: extern binding, the property precedent,
  indexers and inline C#.
- *Interop divergences from gencs*: tasks add entries and retire the member-order one.

Background: the 4b plan, `docs/superpowers/plans/2026-10-27-dotnet-inline-cs.md`, and its ledger,
`.superpowers/sdd/2026-10-27-dotnet-inline-cs/progress.md` (its 4c carry list and deferred minors). The 4a
ledger is `.superpowers/sdd/2026-10-26-dotnet-interop-members/progress.md`: Ruling S is the forwarding stub, and
Ruling W covers attributes and events, which are not written and give no error.

**Research behind this plan.** Read the notes for the task you are on. They quote real gencs output and Roslyn
metadata dumps, and give hxc's file:line for each piece. Real server-app paths appear only there, never in the
repo. Each area has probe folders, each with `P.hx`, gencs's C# and DLL, and both outputs.
- `D:/_hxc4c/attrs/NOTES.md`: `@:meta`/`@:strict`, with real uses, where gencs puts each target's attributes and
  Roslyn's rows (§1); the proposed `AttributesToIl` (§1, end); nullable metadata and the schemas (§2);
  `@:nativeGen` (§3); the attribute diff of the server DLLs (§4); ECMA-335 blob rules (§4, end).
  - `tools/adump` dumps CustomAttribute rows with decoded blobs (`--pseudo` for flags and layout).
  - `tools/schemas.sh <dll> <tag>` dumps the 133 AI tool schemas a HaxeServer.dll gives.
- `D:/_hxc4c/evres/NOTES.md`: events (§1: Haxe's checks, gencs's C#, Roslyn's rows and accessor flags, the
  proposal §1.6, the code to change §1.7) and resources (§2: the macro-API bug, Roslyn's rows and blob, the
  proposal §2.4, the code to change §2.5, the harness line §2.6). `tools/mdump` dumps events and resources.
- `D:/_hxc4c/carried/NOTES.md`: each carried item, with the ranking and cut line (§1) and Roslyn's shapes (§2).
  `tools/ildump` prints generic-parameter names, InterfaceImpl and MethodImpl rows; `tools/specs` prints
  external MethodSpecs.
- `D:/_hxc4c/exit/NOTES.md`: the server's real build and its text patches (§1); the C# solution against hxc's
  DLL (§2); ILVerify (§3); runtime-level differences (§4); the exit checklist (§5).
  - `sln-hxc/` is a copy of the C# solution, wired to a prebuilt DLL.
  - `tools/refcheck` and `tools/loadall` check binary compatibility.

**Test material** lives next to this plan in `docs/superpowers/plans/2026-10-28-dotnet-attributes-events-resources/`:
- `attrs.cases.txt`, `evres.cases.txt`, `carried.cases.txt` and `exit.cases.txt` hold the candidate cases.
  - Every `@gencs` expectation in them is a real gencs net10.0 run.
  - A divergence case carries hxc's expected output, with gencs's under `[gencs]`. A case gencs's C# cannot
    compile gives the C# error in its header comment.
  - The `#` lines above each case are notes, not case text.
  - Refusal texts are proposals, settled by this plan where it gives one; positions are the proposal's unless a
    task says otherwise.
- `netlib/CarLib/` and `netlib/EvLib/` are fixture projects, which go to `tests/dotnet/netlib/CarLib/` and
  `tests/dotnet/netlib/EvLib/`. Add each name to the `@netlib` list in `tests/dotnet/run.sh`'s header comment.
- `measure/` is gitignored and local only. Task 14 fills it, starting from the 4b plan's `measure/`; see that
  task.

"Add case X from F" means: copy that case's text verbatim from F to the end of `tests/dotnet/cases.hx.txt`. If a
case needs a piece a later task builds, move it to that task and say so in the report. Where a task changes a
candidate's expectation (a divergence or a refusal this plan rules), it says how.

**Branch:** `git switch -c dotnet-il-m4c main`. Don't push or open a PR.

## Global Constraints

- **Match gencs** wherever data, reflection or C# can observe a difference. Where gencs's C# fails to compile,
  hxc either refuses cleanly or does better, and each case where it does better is a recorded divergence: a
  test, plus an entry under *Interop divergences from gencs*. Never a silent wrong value.
- **Determinism:** each case's DLL must be byte-identical across two builds (the harness checks this). Every
  new table, row order and blob is a pure function of the compile.
- **ILVerify:** every case DLL passes the harness's ILVerify, including `-D unsafe` ones after Task 6.
- **Public repo:**
  - Case names, case text, commit messages and repo docs never name the private apps. Say "the server app" and
    "the desktop app", and use `serverapp-*` for case names.
  - Before every commit, run the check in the 4b plan's `measure/README.local.md`; its pattern lives only
    there.
- **Read-only:** the app checkouts, `C:/HaxeToolkit/haxe/lib`, and global haxelib/hxcs. The exit measurement
  builds copies of the C# solution under `measure/` only.
- **Attribute types the backend writes itself** (Nullable*, CompilerGenerated, EditorBrowsable,
  TargetFramework) are TypeRefs into `System.Runtime`. Never take them from another assembly that happens to
  define them; about 30 of the server's referenced assemblies have internal copies (attrs §0.7).
- **Tests:** after each task, `tests/dotnet/run.sh` (ALL) and the own suite both pass. If ALL runs out of forks
  while other sessions are busy, rerun the failing cases alone and say so in the report.

## Rulings made for this plan

Each research area left open questions, each with a recommendation. These rulings settle them. The execution
ledger records them at the start, and the user reviews them with this plan.

1. **"Today's" AI tool schemas are the ones the server's build script produces.** The deployed DLL was built
   without the script's patches, so it has no nullable metadata and still carries `BoxedPointer`. The baseline
   is gencs's C# with the script's four patches applied, as in `D:/_hxc4c/exit/out/gencs-builder/HaxeServer.dll`
   (attrs Q1, exit Q2). With it, 131 of the 133 tools' schemas differ from the deployed DLL's.
2. **Nullable metadata is opted into by `-D dotnet-nullable=<package>[,<package>…]`** (attrs Q2, Q3).
   - It covers every type of a module whose package is exactly one of those named, its closure classes
     included, which reproduces the script's `#nullable enable` patch. It does not cover sub-packages, which
     gives the patch's 34-of-108 model split.
   - The rows are Roslyn's, with its context compression, so dumps compare row for row.
   - The server's build passes `-D dotnet-nullable=ai.tools` where it patches today: an owner change, recorded
     in the spec's milestone-6 build-script item.
3. **Attribute inputs.**
   - The backend reads `@:meta` with exactly one expression, and nothing else. StrictMeta already rewrites
     `@:strict` into that form; its `":assemblyStrict"` match becomes `":cs.assemblyStrict"`, which yields
     `":cs.assemblyMeta"`.
   - `@:meta` with several parameters, and `@:meta("C# text")`, are lasting errors (gencs drops the first and
     pastes the second).
   - An attribute on a non-physical var is a lasting error naming the accessor as the place to put it, where
     gencs attaches it to the next C# member.
   - An argument `@:strict` is an error, where Haxe types it and gencs drops it.
   - The meta of a hxgen enum and of an enum constructor is dropped, as gencs drops it. (attrs Q4)
4. **C#'s compile errors for attributes become lasting `dotnet:` errors that name the C# code**: CS0579
   (duplicate), CS0592 (invalid target), CS0246 (unknown type or named argument), CS0616 (not an attribute),
   CS1503 (constructor arguments), CS0182 (not a constant), CS0121 (ambiguous constructor). A constructor is
   chosen from constant arguments by C#'s literal conversions and betterness for the attribute parameter types
   (bool, char, the integer types, float, double, string, `Type`, `object`, an enum, and one-dimensional arrays
   of those).
5. **Pseudo-attributes are flags and tables, never rows**: `Serializable` (type 0x2000), `NonSerialized` (field
   0x80), `StructLayout` (Sequential/Explicit/Auto; `Pack` and `Size` in a ClassLayout row) and `FieldOffset`
   (a FieldLayout row). Any other pseudo-attribute (`MethodImpl`, `DllImport`, `MarshalAs`, …) is a lasting
   error. (attrs Q6)
6. **Assembly and IDE attributes** (attrs Q5):
   - `@:noCompletion` members get `EditorBrowsable(EditorBrowsableState.Never)` where gencs writes it.
   - Every assembly gets `TargetFramework(".NETCoreApp,Version=v<net>", FrameworkDisplayName = ".NET <net>")`.
   - `@:cs.assemblyMeta` entries are written as assembly rows.
   - `Debuggable` waits for milestone 5's `-D dotnet-debug-jit`. The SDK's AssemblyTitle/FileVersion/… are not
     written.
7. **`@:nativeGen` gets gencs's optional-argument overloads** for constructors and methods, static ones
   included, each carrying the field's attributes. Constrained type parameters still get no
   GenericParamConstraint rows. Instead, a call that passes a constrained type parameter of a `@:nativeGen`
   class to an overloaded .NET method is refused ("hxc cannot tell which .NET overload of T.m the type
   parameter T's constraints select"), where gencs's C# binds by the `where` clause and hxc today binds
   `object` silently. (attrs §3, carried Q3)
8. **Resources are plain `-resource` and `Context.addResource`.** `-D dotnet-embed` is dropped from the spec:
   nothing defines it, and the server's lookup by `endsWith` works with `-resource`. (evres Q1)
   - The server's hxml gains the two `-resource` lines for its coach and tutorials files: an owner change, made
     in Task 14's overlay until then.
   - Manifest names are `src.Resources.` plus the runtime's own escape of the name (`Path.escape(name, true)`,
     per UTF-16 code unit). That is gencs's name for every ASCII name without `\`, and right where gencs's is
     wrong (non-ASCII and backslash names, which gencs lists but cannot read). This is a recorded divergence
     (evres Q2).
   - Two names with one manifest name are a lasting error.
9. **The macro-API resource fix lands for every target** (evres §0.1). `Context.addResource` replaces the entry
   in the compile's resources, keeping the first position, as Haxe does. `Context.getResources` returns them.
   This changes jvm, cpp and interp output, which now matches Haxe 4.3.7.
10. **Haxe-defined events are done in 4c**, after the exit pieces (evres Q3). They are silently wrong today:
    handlers are lost, a public field is written for the var, and Haxe's checks are missing.
    - Haxe's three checks come first, with Haxe's texts.
    - An event is field-like when both of its bodies are empty, and custom otherwise. gencs drops a body when
      the empty one is declared first, a divergence.
    - DCE keeps an event's var and both of its methods together, where gencs's C# fails with CS1061 (evres Q4).
    - haxeui's `@:event(...)` vars are `(default, set)` and are not events, as in Haxe.
11. **ILVerify "clean" means no output at all** (exit Q1). hxc's runtime gets its own
    `cs/internal/BoxedPointer.hx` without `@:keep`, so DCE drops the class that std's `cs.Boot` imports under
    `-D unsafe`. That matches the build script's patch 1. Keeping it alive explicitly, through `@:keep` or a
    use, still writes it; its field is then typed `void*`, as gencs's is.
12. **`haxe.lang.Null<T>` gets `op_Implicit(T)` and `_ofDynamic(object)`** with gencs's flags and bodies, and
    `initonly` on `value` and `hasValue`. The nested `__NoValue__` and its `op_Implicit` stay out, a recorded
    divergence (carried Q1): C# `Null<int> x = null` does not compile against hxc's DLL, and nothing does it.
    The extra public `toString()` stays, since it is hxc's runtime method that `ToString` calls.
13. **A `-main` build stays an exe with its runtimeconfig** (exit Q3). The server's C# references it as it would
    a library.
14. **The C# solution's wiring is the owner's change.** The spec's exit wording becomes: the projects that name
    Haxe types (SharedServer, WebAPI, Server, and the no-browser runner) reference the DLL, through one shared
    `.props` (exit Q4). Task 14 measures with that wiring in a copy.
15. **The inline-C# `f` literal that rounds twice is refused**, where its double is a float32 rounding midpoint
    ("hxc cannot round this float literal as C# does; write it with fewer digits"). Exact single rounding is
    not worth the cost; no inline C# has a float literal (carried Q4).
16. **Member order matches gencs** (carried Q2): the entry point, `.cctor`, the instance constructors, the
    static properties' accessors, `__hx_ctor_*` and the statics come before the instance members. This is
    Task 13, an isolated commit with its dump updates, and retires the spec's divergence. **It is the one task
    the user may drop**, which leaves the divergence recorded.
17. **These stay clean refusals past milestone 4**, as nothing real uses them:
    - covariant-return `@:overload` overrides;
    - static `@:property` accessors;
    - the forwarding stub (Ruling S);
    - .NET extern and other unsupported method groups;
    - 4b's `converts` refinements (a)/(c);
    - `{0}[i]` on program classes in inline C#;
    - `cs.Pointer.add`, the std stub.

    The spec's 4c bullet moves them to a "not supported" list. Their candidate cases in `carried.cases.txt`
    (`haxe-override-overload-covariant-return`, `netlib-iface-base-nonvirtual-forwarding-stub`,
    `property-var-static-accessors`, `property-var-static-accessors-generic`, `netlib-delegate-net-method-groups`,
    `delegate-haxe-method-groups-more`, `netlib-extern-conversions-nullable-and-arrays`,
    `inline-cs-program-class-indexer`) are not added. The existing refusal cases pin these items.
18. **`initonly` on `@:readOnly`/`final` fields in general is not done.** hxc writes a hxgen class's constructor
    body into `__hx_ctor_*`, a static method, where a store to an `initonly` field is unverifiable. Only
    `Null<T>`'s two fields get it (ruling 12). The 21 fields stay a recorded divergence that only reflection can
    see.
19. **`ReflectionMembers.floatLike` counts anonymous-structure-typed fields as gencs's `is_dynamic` does**, so
    the 343 classes get gencs's `__hx_getField_f`/`__hx_setField_f` overrides (exit §4). It is cheap and visible
    to reflection; behaviour already agrees.

## Review Focus

1. **A resource from a macro and the same name from `-resource`:** Haxe replaces in place and keeps the first
   position, so `listNames()` order and content must match Haxe 4.3.7 on interp, jvm and .NET. The test goes in
   Task 7 (`macro-resource-replaces-cli`).
2. **An attribute with an enum argument from a `--net-lib`, or a `Type` argument naming a generic or nested
   type:** the blob's SerString must be assembly-qualified exactly as Roslyn writes it, or .NET's reflection
   throws at `GetCustomAttributes`. The test goes in Task 1 (`attrs-meta-forms` covers enum, typeof and array;
   add `attrs-typeof-generic-nested`).
3. **Nullable metadata on a closure class, a generic struct field (`haxe.lang.Null<int>`) and an array of
   strings in one enabled module:** Roslyn's context compression must give the same rows, or
   `NullabilityInfoContext` reads them differently. The test goes in Task 4 (`attrs-nullable-opt-in` plus the
   row dump `attrs-nullable-rows`).
4. **A C# subscriber to an hxc-built class's Haxe event, at run time:** the fixture is compiled before hxc's DLL
   exists, so it subscribes through `EventInfo.AddEventHandler`, as a C# consumer compiled later binds the same
   rows. The Event row, EventMap sorting and accessor flags must let it bind. The test goes in Task 9
   (`event-csharp-subscribes`, on `resource-csharp-reads-manifest`'s EvLib pattern).
5. **A ClassLayout/FieldLayout table in a DLL with no struct that needs one, and in one with several:** an empty
   table must not be written, and rows must be sorted by parent, or the CLR refuses to load the type. The test
   goes in Task 2 (`attrs-pseudo-layout-and-serializable` plus `attrs-pseudo-layout-two-structs`).

---

### Task 1: The attribute encoder, and `@:meta`/`@:strict` rows

**Files:**
- Create: `src/hxc/codegen/dotnet/AttributesToIl.hx`
- Modify: `src/hxc/codegen/dotnet/IlBytes.hx` (`serString`), `ModuleBuilder.hx` (`customAttribute` callers),
  `TclassToIl.hx` (collect per member; the CompilerGenerated use at `:1647-1656`), `IndexerToIl.hx:246`
  (DefaultMember), `CompanionToIl.hx:362-381` (GenericInterface), `GenerateDotnet.hx:44`,
  `src/hxc/typing/StrictMeta.hx:246`
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - `AttributesToIl.forMember(g, owner:Int, meta:Metadata, target:AttrTarget, pos):Void`, where
    `AttrTarget = TType | TField | TMethod | TProperty | TParam | TAssembly`, writes every `@:meta` entry's row.
  - `AttributesToIl.write(g, owner:Int, ctor:AttrCtor, fixed:Array<AttrValue>, named:Array<AttrNamed>):Void` is
    for the backend's own attributes.
  - `AttributesToIl.runtimeAttr(g, ns:String, name:String, sig:Array<AttrType>):AttrCtor` gives a constructor
    pinned to `System.Runtime`.
  - `AttrValue` is an enum: `ABool`, `AInt(type, Int64)`, `AFloat(type, Float)`, `AString(Null<String>)`,
    `AType(String)`, `AEnum(enumName, type, Int64)`, `AArray(type, Null<Array<AttrValue>>)`, `ABoxed(AttrValue)`.
- Consumes: 4a's `ExternMembers`/`NetRefs` for attribute types and constructors; `IlMetaReader.readCustomAttr`
  (`IlMetaReader.hx:663`) for a .NET attribute's `AttributeUsage`.

- [ ] **Step 1: Add the cases.** From `attrs.cases.txt`: `serverapp-strict-tool-model`, `attrs-meta-forms`,
  `attrs-constructor-overload-from-literal`, `attrs-thread-static`, and the refusals `attrs-refuse-duplicate`,
  `-invalid-target`, `-unknown-type`, `-not-an-attribute`, `-constructor-arguments`, `-not-constant`,
  `-unknown-named-argument`, `-ambiguous-null`, `-meta-two-parameters`, `-meta-csharp-text`, `-non-physical-var`,
  `-strict-on-argument`. Write `attrs-typeof-generic-nested @gencs`:
  - attributes whose `Type` argument is `typeof(List_1<String>)`, a nested .NET type, and a type of the program;
  - an enum argument from a `--net-std` enum;
  - an `object` parameter receiving an int, a string and a `Type`.

  It prints each attribute's `ToString()` of its constructor arguments through `GetCustomAttributesData()`.
  Gencs's run is its expectation.
- [ ] **Step 2: Run them to see them fail.**
  `tests/dotnet/run.sh --compiler <hxc> --case serverapp-strict-tool-model` and the others. Expected: the
  `@gencs` ones print no attributes, and the refusals compile with no error.
- [ ] **Step 3: Implement `AttributesToIl`** as attrs §1 *Proposed module* steps 1-5, 7-9 describe.
  - Collect per member, in Haxe meta order.
  - Resolve the attribute type by C#'s two lookups (the path, then path + `Attribute`) over NetRefs and the
    program's classes.
  - Choose the constructor by ruling 4.
  - Named arguments are a public field (0x53) or a settable property (0x54).
  - Check `AttributeUsage` (ValidOn, AllowMultiple; default All, false).
  - Encode by attrs §4's blob rules.
  - Write the refusals with ruling 3's and 4's texts, positioned at the meta entry.
  - Move CompilerGenerated, DefaultMember and GenericInterface onto `write`; GenericInterface's type argument
    becomes assembly-qualified as Roslyn writes it.
  - Fix StrictMeta's name (ruling 3).
- [ ] **Step 4: Run the cases and the dumps they touch.** Expected: every new case passes. The existing `@dump`
  cases with a GenericInterface row change only in that blob; update their expectations from gencs's dump
  (`D:/_hxc4c/attrs/dump/`) and say which in the report.
- [ ] **Step 5: Run ALL and the own suite.** Expected: 0 failures.
- [ ] **Step 6: Spec and README.** In the spec's 4c bullet, attributes are written now, by rulings 3-4. In the
  README, drop "attributes are not written" from the not-yet list.
- [ ] **Step 7: Commit** ("Write @:meta and @:strict attributes for .NET").

### Task 2: Pseudo-attributes

**Files:**
- Modify: `src/hxc/codegen/dotnet/MetaTables.hx` (ClassLayout 0x0F `[U16, U32, T.ITypeDef]` and FieldLayout
  0x10 `[U32, T.IField]`, each sorted by parent, written only when non-empty), `ModuleBuilder.hx`
  (`classLayout`, `fieldLayout`), `TclassToIl.hx` (type flags at `planClass` ~`:608-617`, field flags where
  fields are planned), `AttributesToIl.hx` (`pseudo(meta):PseudoAttrs`, called at plan time; skips those
  entries in `forMember`)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 1's attribute type resolution.
- Produces: `AttributesToIl.pseudo(g, meta, target, pos):PseudoAttrs`, where
  `PseudoAttrs = {typeFlags:Int, fieldFlags:Int, layout:Null<{pack:Int, size:Int}>, offset:Null<Int>}`.

- [ ] **Step 1: Add the cases.** From `attrs.cases.txt`: `attrs-pseudo-layout-and-serializable` and
  `attrs-refuse-pseudo-attribute`. Write `attrs-pseudo-layout-two-structs @gencs`: two `@:struct` classes with
  explicit layout, one with `Pack`/`Size`, declared in reverse name order, plus `Bytes.setDouble`/`getDouble`
  and `FPHelper.floatToI32` round trips. It prints the values and `Marshal.SizeOf` of each.
- [ ] **Step 2: Run them to see them fail.** Expected: zeros where gencs prints `1.5 2.25`, as attrs §0.1 shows.
- [ ] **Step 3: Implement** ruling 5. The flags are decided in `planClass` and the field plans; the rows are
  written with the TypeDef/Field tokens.
- [ ] **Step 4: Run the cases.** Expected: pass, and ILVerify clean.
- [ ] **Step 5: Run ALL and the own suite.** Expected: 0 failures. No DLL without explicit layout changes bytes.
- [ ] **Step 6: Commit** ("Write StructLayout, FieldOffset, Serializable and NonSerialized for .NET").

### Task 3: Assembly and IDE attributes, and `@:nativeGen`

**Files:**
- Modify: `AttributesToIl.hx` (`TAssembly`, EditorBrowsable, TargetFramework), `GenerateDotnet.hx` (the
  assembly rows), `TclassToIl.hx` (a `MOptionalOverload(cf, n)` method kind for `@:nativeGen` classes, with ctor
  chaining), `ExternMembers.hx` (ruling 7's refusal for a constrained type parameter of a `@:nativeGen` class)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 1's `forMember` and `write`.
- Produces: the `MOptionalOverload(cf:ClassField, n:Int)` MethodKind, which is the first `n` parameters; it
  passes `null` or the default value for the rest.

- [ ] **Step 1: Add the cases.**
  - From `attrs.cases.txt`: `attrs-assembly-meta` and `attrs-nativegen-optional-overloads`.
  - From `carried.cases.txt`: `netlib-nativegen-constrained-type-param-argument`. Rename it `…-refused`, drop
    `@gencs`, and make the expectation ruling 7's error at the call, keeping gencs's output in the header
    comment.
  - Write `attrs-editor-browsable @gencs`: `@:noCompletion` on a field, a method and an interface accessor. It
    prints `EditorBrowsableAttribute.State` through reflection.
  - Add CarLib from this plan's `netlib/`.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** rulings 6 and 7, by attrs §3's description of gencs's overloads (gencs.ml:151-205).
  The overloads carry the field's attributes.
- [ ] **Step 4: Run the cases, then ALL and the own suite.** Expected: 0 failures. Every DLL gains the
  TargetFramework row, so update the `@dump` expectations that list assembly attributes and name them in the
  report.
- [ ] **Step 5: Commit** ("Write assembly attributes, EditorBrowsable and @:nativeGen's optional overloads for
  .NET").

### Task 4: Nullable metadata

**Files:**
- Create: `src/hxc/codegen/dotnet/NullableToIl.hx`
- Modify: `GenerateDotnet.hx` (read `-D dotnet-nullable`, and say what an invalid value is), `TclassToIl.hx`
  (members of enabled types), `ClosuresToClass.hx` (closure classes belong to their module)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 1's `runtimeAttr` and `write`.
- Produces: `NullableToIl.enabled(g, c:ClassType):Bool`, and `NullableToIl.write(g, typePlan)`, which runs after
  a type's members are written.

- [ ] **Step 1: Add the cases.** From `attrs.cases.txt`: `attrs-nullable-opt-in`. Its `[run]` is gencs with the
  patch applied by hand, and `[gencs]` the unpatched run; keep both, since ruling 2 makes the patched one hxc's
  target. Write `attrs-nullable-rows @lib @module=tools.P @dump=… + -D dotnet-nullable=tools`, covering:
  - a model with `String`, `Null<String>`, `Null<Int>`, `Array<String>`, `cs.system.Nullable_1<Int>` and
    `List_1<String>` properties;
  - a closure;
  - a type of another package in the same module;
  - a sub-package module.

  The expectation is the row dump of gencs's patched build (build it as `D:/_hxc4c/attrs/cases/nullable2/gp`
  was built).
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** attrs §2 *Roslyn's rules*:
  - each type reference's byte array, in pre-order;
  - `NullableContext` as the most common byte, with Roslyn's tie order, written only when it differs from the
    enclosing one;
  - `Nullable(0)` for the base type on each enabled type;
  - TypeRefs pinned to `System.Runtime`.
- [ ] **Step 4: Run the cases, then ALL and the own suite.** Expected: 0 failures, and no DLL without the
  define changes.
- [ ] **Step 5: Spec.** Ruling 2 goes into the 4c bullet, and the owner's define into the milestone-6
  build-script item.
- [ ] **Step 6: Commit** ("Write nullable metadata for the packages -D dotnet-nullable names").

### Task 5: `haxe.lang.Null<T>`'s C# surface

**Files:**
- Modify: `TclassToIl.hx` (a synthesized-member hook for the runtime Null class, beside `arrayIdentity` at
  `:578`, `:1450`), `src/hxc/codegen/dotnet/runtime/cs/internal/Null.hx` (its comment at `:25-29`; `value` and
  `hasValue` initonly)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:
  - `op_Implicit(!0):Null`1<!0>`, Public Static HideBySig SpecialName, with the body
    `ldarg.0; ldc.i4.1; newobj .ctor(!0, bool); ret`;
  - `_ofDynamic(object):Null`1<!0>`, Public Static HideBySig, with the body
    `ldarg.0; call ofDynamic<!0>(object); ret`.

  Both are in gencs's member order (carried §2 h).

- [ ] **Step 1: Add the cases.** From `exit.cases.txt`: `null-struct-csharp-surface` and
  `null-struct-csharp-metadata`. Per ruling 12, they become divergence cases:
  - the surface case's `[run]` has one `op_Implicit` and `False` for the nested type, with gencs's output under
    `[gencs]`;
  - the metadata dump drops `__NoValue__` and its `op_Implicit`.

  From `carried.cases.txt`: `nullable-csharp-operators`. Write `null-implicit-from-csharp @gencs @netlib=EvLib`,
  in which a fixture C# method calls a Haxe method with an optional `?b:Bool` by passing a C# `bool`, the
  server's consumer pattern. Add the fixture method to `EvLib.cs`, and add EvLib from this plan's `netlib/`.
- [ ] **Step 2: Run them to see them fail.** Expected: the fixture fails to build, or throws
  `MissingMethodException`.
- [ ] **Step 3: Implement** ruling 12.
- [ ] **Step 4: Run the cases, then ALL and the own suite.** Expected: 0 failures.
- [ ] **Step 5: Spec.** Add the `__NoValue__` divergence entry.
- [ ] **Step 6: Commit** ("Give haxe.lang.Null the implicit conversion C# code calls for .NET").

### Task 6: No `haxe.lang.BoxedPointer`

**Files:**
- Create: `src/hxc/codegen/dotnet/runtime/cs/internal/BoxedPointer.hx` (std's class without `@:keep`; when a
  program keeps it, its field must come out `void*` as gencs's does, not today's `object*`. Add a `@lib @dump`
  line for a kept one to the case.)
- Modify: `RuntimeSources.hx` / `RuntimeSourcesBuild.hx` if the runtime list is explicit
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Add the case.** From `exit.cases.txt`: `unsafe-define-verifies`.
- [ ] **Step 2: Run it to see it fail.** Expected: ILVerify's `UnmanagedPointer` line.
- [ ] **Step 3: Implement** ruling 11.
- [ ] **Step 4: Run the case, then ALL and the own suite.** Expected: 0 failures.
- [ ] **Step 5: Commit** ("Leave out haxe.lang.BoxedPointer unless a program keeps it, for .NET").

### Task 7: Macro resources, on every target

**Files:**
- Modify: `src/hxc/eval/EvalStdLib.hx:3393-3402` (`add_resource` writes through the host's `com.addResource` and
  the current module's bound resources; `get_resources` reads `com.resources`),
  `src/hxc/context/ServerCache.hx:278-290` (restore through `com.addResource`)
- Test: a new own-suite family `tests/cases/macro-resources/`, laid out as `tests/cases/build-macro-fields/`,
  with expectations from Haxe 4.3.7 `--interp`

- [ ] **Step 1: Write the cases**:
  - `macro-resource-listed`: a macro adds two resources, and main prints `listNames()` and `getString` of each;
  - `macro-resource-replaces-cli`: `-resource` gives `a`, then a macro adds `a` again with other bytes and adds
    `b`. Haxe keeps `a` first with the new bytes;
  - `macro-get-resources`: `Context.getResources()` from a macro sees the `-resource` files.

  Generate the expectations with Haxe 4.3.7, as `build-macro-fields` was.
- [ ] **Step 2: Run them to see them fail.** Expected: hxc prints only the `-resource` names, as evres §0.1
  shows.
- [ ] **Step 3: Implement** ruling 9.
- [ ] **Step 4: Run the own suite, the jvm cases and ALL.** Expected: 0 failures. The .NET cases still give
  today's resource error, since Task 8 lifts it.
- [ ] **Step 5: Commit** ("Keep resources added by macros in the compile's resources").

### Task 8: Manifest resources for .NET

**Files:**
- Create: `src/hxc/codegen/dotnet/ResourcesToIl.hx`, with `fillContent(ctx)`,
  `manifestName(name):String` and `embed(g)`
- Modify: `GenerateDotnet.hx:427-431` (replace the error), `ModuleBuilder.hx` (`manifestResource`; pass the blob
  to `finish`), `MetaTables.hx` (ManifestResource `[U32, U32, STR, T.IImplementation]`, written between
  AssemblyRef and GenericParam; the `IImplementation` coded index), `PeWriter.hx` (the resources directory in the
  CLI header, the blob after the metadata, the import table after `alignUp(…, 4)`; with no resources, today's
  bytes), `tests/dotnet/gencs.csproj.in` (evres §2.6's `EmbeddedResource` line), `tests/dotnet/cases.hx.txt`
  (drop `resource-is-an-error`)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 7's macro resources.
- Produces: `ResourcesToIl.manifestName(name:String):String`, which is `"src.Resources." + escape(name)`.

- [ ] **Step 1: Add the cases.** From `evres.cases.txt`: `resource-list-names-empty`, `resource-file-names`,
  `resource-macro-binary`, `resource-list-names-order`, `resource-csharp-reads-manifest`,
  `resource-non-ascii-name`, `resource-backslash-name` and `resource-escape-collision-is-an-error`. Use the
  error text proposed there, positioned at the second name's `-resource` argument, or at `nullPos` for a macro
  one.
- [ ] **Step 2: Run them to see them fail.** Expected: today's resource error, and an NRE in
  `resource-list-names-empty`.
- [ ] **Step 3: Implement** evres §2.4 items 2-6 with ruling 8's names:
  - rows in `resourceFoldOrder()`, with `content` in its reverse;
  - each entry a 4-byte length plus the data, padded to 8 bytes, the last one included.
- [ ] **Step 4: Run the cases, then ALL and the own suite.** Expected: 0 failures. The `gencs.csproj.in` change
  re-keys the gencs cache once.
- [ ] **Step 5: Spec and README.**
  - Resources are no longer an error; `-D dotnet-embed` is gone (ruling 8).
  - Add the divergence entry for non-ASCII and backslash names.
  - Also in the spec, the desktop app's build depends on Task 7.
- [ ] **Step 6: Commit** ("Embed manifest resources for .NET").

### Task 9: Events defined in Haxe: the checks, custom events and their rows

**Files:**
- Create: `src/hxc/codegen/dotnet/EventToIl.hx`, containing `EventPlan` and `planEvents(g, c, interfaces)`,
  called next to `planProperties` (`TclassToIl.hx:335`), and `write(g, plan)`, called after the properties loop
  (`:1603`)
- Modify:
  - `src/hxc/filters/Filters.hx` (`checkCsEvents` for `com.platform == Cs`, before DCE, with Haxe's texts and
    positions, adding `@:skipReflection` to the var and `@:pure(false)` to the methods);
  - the DCE keep rule (ruling 10);
  - `TclassToIl.hx` (the Haxe bodies become private `_add_X`/`_remove_X`; no field for a custom event's var;
    `SemanticsAttrs.ADD_ON = 0x8`, `REMOVE_ON = 0x10`; every Haxe call, reflection invoke and closure of
    `add_X`/`remove_X` goes to the accessor, as for properties);
  - `ModuleBuilder.hx` (`event(owner, flags, name, typeToken)`, grouped into EventMap like `property`);
  - `MetaTables.hx` (EventMap 0x12, Event 0x14, sorted).
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Produces:

  ```haxe
  EventPlan = {cf:ClassField, name:String, isStatic:Bool, fieldLike:Bool,
               adder:MethodPlan, remover:MethodPlan, backing:Null<FieldPlan>, token:Int}
  ```

  Task 10 fills in `fieldLike` and `backing`.

- [ ] **Step 1: Add the cases.**
  - From `evres.cases.txt`: `event-custom-instance-and-static`, `event-protected`, `event-declaration-order`,
    `event-dce-full-unread-var`, `event-dce-full-keep`, `event-public-is-an-error`,
    `event-missing-method-is-an-error`, `event-method-signature-is-an-error`, `event-generic-class-is-an-error`,
    `event-override-accessor-is-an-error`, `event-read-is-an-error`, `event-one-empty-body`,
    `netlib-event-accessor-override`, `netlib-event-consume` and `inline-cs-event-plus-equals-is-an-error`.
  - Write `event-csharp-subscribes @gencs @netlib=EvLib`: a fixture C# method does `+=` and `-=` on an
    hxc-built class's custom event (passed as `object` and reached by `dynamic`-free reflection: `GetEvent`,
    then `AddEventHandler`), then the Haxe side raises it.
  - Write `event-haxeui-builder-vars-are-not-events`: a `@:event(X)` var with `(default, set)` access compiles
    as a plain property, as in Haxe.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** evres §1.6 items 1-4 and 8, with Event rows ordered statics then instances, each in
  reverse declaration order.
- [ ] **Step 4: Run the cases, then ALL and the own suite.** Expected: 0 failures.
- [ ] **Step 5: Commit** ("Write Haxe-defined custom events for .NET, with Haxe's event checks").

### Task 10: Field-like events, interface events, and implementing a .NET interface's event

**Files:**
- Modify:
  - `EventToIl.hx`: field-like accessors. Their bodies are Roslyn's CompareExchange loop, which needs
    MemberRefs for `Delegate::Combine` and `Delegate::Remove` and a MethodSpec of
    `Interlocked::CompareExchange<T>`. The backing field is private (and static, for a static event) and carries
    CompilerGenerated.
  - `TclassToIl.hx`: the field-like var's reads and writes inside the class go to the backing field. Interface
    events get abstract accessors with flags `0x0DC6` and CompilerGenerated. In `interfaceImpls`, the refusal at
    `:787` becomes evres §1.6.7's check.
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Add the cases.** From `evres.cases.txt`: `event-field-like`, `event-haxe-interface`,
  `netlib-event-implements-interface` and `netlib-event-var-not-event-is-an-error`.
- [ ] **Step 2: Run them to see them fail.** Expected: "nobody for b" in `event-field-like`, and the refusal at
  `:787`.
- [ ] **Step 3: Implement** evres §1.6 items 5-7. A field-like var read outside its class is refused with
  CS0070's text.
- [ ] **Step 4: Run the cases, then ALL and the own suite.** Expected: 0 failures.
- [ ] **Step 5: Spec and README.** Haxe-defined events are now written (ruling 10, with its divergences). Drop
  them from the not-yet list.
- [ ] **Step 6: Commit** ("Write field-like and interface events for .NET").

### Task 11: Generic parity: the `T1` rename and type-parameter arguments

**Files:**
- Modify:
  - `TclassToIl.hx:421` and the interface-method path: use
    `renamedTypeParams(c):ObjectMap<ClassField, Array<String>>`, gencs's rule from carried §2 b.
  - `TexprCalls.hx:1280`: a Haxe class type parameter's argument infers the instantiation's type where the
    receiver gives one, as carried §2 f describes.
  - `ExternMembers.hx`: in `converts`, the type-parameter rule at `:1032` moves above the Decimal/Nullable
    `AUnknown` returns.
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Add the cases.** From `carried.cases.txt`: `method-type-param-renamed`,
  `netlib-extern-type-parameter-argument-inference` and `inline-cs-type-param-argument-overloaded`. For the two
  gencs bugs carried §2 b names (CS0246), hxc compiles both and renames consistently: add those lines as a
  divergence case, `method-type-param-renamed-override`.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** the three changes.
- [ ] **Step 4: Run the cases, then ALL and the own suite.** Expected: 0 failures.
- [ ] **Step 5: Spec.** Retire the `sh<T,T1>` divergence line and the type-parameter inference entry. Add the
  override-rename divergence.
- [ ] **Step 6: Commit** ("Rename shadowing method type parameters and infer type-parameter arguments as gencs
  does, for .NET").

### Task 12: Small fixes: `EnumValueMap`, the float literal, and float-like anonymous fields

**Files:**
- Modify:
  - `TclassToIl.hx`, `findImplementation` at `:1264`: accept an inherited method emitted virtual.
  - `GenerateDotnet.hx`, the loop at `:507`, and `TclassToIl.hx:1281-1288`: collect every final or inline
    program-class method that a subclass's interface maps to, and make it `VIRTUAL | FINAL | NEW_SLOT`
    (Roslyn's rule, carried §2 i).
  - `CsSyntax.hx` or `CsToIl.hx` (wherever `f` literals are folded): ruling 15.
  - `ReflectionMembers.hx:140`: ruling 19.
- Test: `tests/dotnet/cases.hx.txt`

- [ ] **Step 1: Add the cases.**
  - From `carried.cases.txt`: `iface-method-inherited-final` and `enum-value-map-imap-key-value-iterator`.
  - Also `inline-cs-float-literal-rounding`: drop `@gencs`, and make the midpoint line's expectation ruling
    15's error, keeping gencs's output in the header comment.
  - From `exit.cases.txt`: `reflect-getfield-f-anon-field`.
  - Update the `FromFinal` line of `class-and-struct-declaration-errors` (`cases.hx.txt`, near `:1109`) to
    what Roslyn's rule now compiles.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement.** Then run the 4b plan's `tools/stdall.sh`. Expected: `haxe.ds.EnumValueMap` is no
  longer skipped, and `cs.Pointer.add` is the only stub.
- [ ] **Step 4: Run the cases, then ALL and the own suite.** Expected: 0 failures.
- [ ] **Step 5: Commit** ("Implement interfaces by inherited final methods, refuse a double-rounded float
  literal, and count anonymous fields as float-like, for .NET").

### Task 13 (optional, ruling 16): gencs's member order

**Files:**
- Modify: `TclassToIl.hx`, the method order in `plan` (`:489-592`): move the entry point, `.cctor`, the static
  properties' accessors, `__hx_ctor_*` and the statics in front of the instance properties, in gencs's order
  (carried §2 j)
- Test: `tests/dotnet/cases.hx.txt` (the `@dump` expectations and the cases that print `GetMethods` order)

- [ ] **Step 1: Add the case.** From `carried.cases.txt`: `member-order-statics-after-constructors`.
- [ ] **Step 2: Run it to see it fail.**
- [ ] **Step 3: Implement.** Moving blocks only, with no new logic.
- [ ] **Step 4: Regenerate the expectations.** Run ALL. For each failing `@dump` or order-printing case, check
  that the diff is order only, then update its expectation. List them in the report.
- [ ] **Step 5: Run ALL and the own suite.** Expected: 0 failures.
- [ ] **Step 6: Spec.** Retire the member-order divergence.
- [ ] **Step 7: Commit** ("Order static members as gencs does, for .NET").

### Task 14: Milestone 4's exit

**Files:**
- Create (local, gitignored): `docs/superpowers/plans/2026-10-28-dotnet-attributes-events-resources/measure/`.
  Copy the 4b plan's `measure/` scripts and overlay into it. Add the server hxml's two `-resource` lines and
  `-D dotnet-nullable=ai.tools` to the overlay's hxml (standing in for the owner's changes, rulings 2 and 8).
  Then add:
  - `cssln.sh <dll> <tag>`: builds a copy of the C# solution under `$MEASURE_OUT` with ruling 14's wiring, from
    `D:/_hxc4c/exit/sln-hxc/`;
  - `schemas.sh`: from `D:/_hxc4c/attrs/tools/`;
  - `resources.sh <dll>`: lists the manifest resources and their sizes.
- Modify: the spec (the 4c bullet, the Exit, *Interop divergences*) and `README.md`

- [ ] **Step 1: Build.** `OVERLAY=1 measure.sh <hxc> m4c`. Expected: the server app, server-stubs and nativepdf
  each have 0 errors and write a DLL. Then `desktopapp.sh <hxc> all`. Expected: 0 errors, and all 217 resources.
  Compare the names with gencs's in `D:/_hxc4c/evres/desktop-gencs-resources.txt`.
- [ ] **Step 2: Resources.** `resources.sh` on hxc's server DLL. Expected: `src.Resources.coach.bin` and
  `src.Resources.tutorials.bin`, with gencs's byte sizes (5,044,147 and 2,644,821).
- [ ] **Step 3: The C# solution.** `cssln.sh <hxc DLL> m4c`. Expected: 0 errors. Then run
  `D:/_hxc4c/exit/tools/refcheck` and `loadall` the way exit §2 ran them. Expected: every reference made by
  consumers compiled against gencs's DLL resolves in hxc's, and every method JITs.
- [ ] **Step 4: ILVerify.** `verify.sh <hxc DLL> m4c`. Expected: no output.
- [ ] **Step 5: Schemas.** `schemas.sh <hxc DLL> hxc`, then a diff against
  `D:/_hxc4c/attrs/dump/schemas-gencs-patched.txt` (ruling 1). Expected: identical for all 133 tools,
  unstripped.
- [ ] **Step 6: The server's own checks and the shape.**
  - `nochrome.sh`: expected SAME.
  - `shape.sh` with the pattern fixed. 4b's `ai.tools.*_Model` matched nothing (attrs §2), so use a prefix the
    dumper takes. Expected: no lines if Task 13 ran; otherwise the statics order only.
  - The attribute diff with `D:/_hxc4c/attrs/tools/adump` against the gencs-builder DLL. Expected: only the
    differences rulings 6 and 18 leave: the SDK assembly attributes, Debuggable, DebuggerBrowsable,
    RefSafetyRules and DeclSecurity.
- [ ] **Step 7: Spec and README.**
  - The 4c bullet's "Its last step measured" paragraph gives these results, as 4a's and 4b's do.
  - The Exit takes ruling 14's wording.
  - Ruling 17's list becomes the "not supported" list.
  - The owner's changes are listed in one place: the two source changes from 4b, the two `-resource` lines,
    `-D dotnet-nullable=ai.tools`, and the shared `.props` that removes Builder's four text patches.
- [ ] **Step 8: Run ALL and the own suite** a last time. Expected: 0 failures.
- [ ] **Step 9: Commit** ("Measure milestone 4c: the server app meets milestone 4's exit").
