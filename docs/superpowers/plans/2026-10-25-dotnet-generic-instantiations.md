# .NET generic instantiations (milestone 3c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** generic Haxe classes behave under `--cs <dir> -D dotnet` as Haxe 4.3.7 gencs + hxcs make
them behave:
- the same CLR instantiations, through gencs's type-argument erasure;
- the same companion interfaces;
- the same casts between instantiations;
- the same reflection.

There are two deliberate exceptions. Haxe issue 8314 is fixed for `Array`, and gencs's broken parent
casts are fixed. Together these clear the cast errors that stop the server app, haxeui and the desktop app.

**Architecture:** `DotnetTypes.toSig` maps type arguments the way gencs does. Every type argument that
isn't "basic" becomes `object`, and any `Dynamic` argument makes the static type the class's
non-generic companion interface. A new `HxGeneric` analysis decides which generic classes get that
treatment.

A new `CompanionToIl` declares, for each such class, its companion interface and the cast methods:
`X_cast<T_c>` per class, one per parent, plus the static `__hx_cast<T_c_c>`. A new
`InstantiationCasts` emits the call to them wherever a value changes instantiation. Member access
through a companion-typed value goes dynamic, or through the interface for members that don't
mention a type parameter.

hxc's runtime copy gains `Array.hx`, which carries the #8314 forward.

**Tech Stack:** Haxe 4.3 (hxc's source), hxcpp via Aedifex, the .NET 10 SDK, and Haxe 4.3.7 + hxcs
(the oracle; installed locally).

**Spec:** `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`. The relevant parts are
*Compatibility*, *Casts between generic instantiations (Haxe issue 8314)*, which Task 1 rewrites to
the decisions below, and milestone 3's exit. Background:
- `docs/superpowers/plans/2026-10-22-dotnet-runtime-foundation.md` (3a): hxgen classes, the
  `__hx_*` reflection members, `Dynamic`, the `@gencs` harness and the embedded runtime.
- `docs/superpowers/plans/2026-10-23-dotnet-closures-enums-std.md` (3b): enums, closures, `Std`/`Type`,
  `@serial`, and method type-parameter inference over `Null<X>` (`DotnetTypes.inferParams`).

**Milestone 3 ends with this plan.** Its exit, from the spec, is that the differential suite against
gencs passes apart from the recorded deliberate divergences.

**Research behind this plan.** Read the notes for the task you are on; they quote real gencs output
and give hxc's file:line for each piece:
- `D:/_hxc3c/types/NOTES.md`: erasure, companion interfaces, parent casts, and access through
  companions.
- `D:/_hxc3c/casts/NOTES.md`: cast insertion, `__hx_cast`/`genericCast` semantics, the #8314 Array
  design member by member, and the inventory of real casts.
- `D:/_hxc3c/std/NOTES.md`: the std stubs and refusals 3c unblocks.

Each notes directory has a `probe/` (or `cases/`) folder with gencs's C# and outputs. The 3b notes
(`D:/_hxc3b/*/NOTES.md`) predate this research. Where they disagree, these notes win; for example
`Type.resolveClass("G")` is ``typeof(G`1<object>)``, not the companion.

**Test material** lives next to this plan in `docs/superpowers/plans/2026-10-25-dotnet-generic-instantiations/`.
- **Case files:** `erasure.cases.txt`, `companions.cases.txt`, `casts.cases.txt`,
  `companion-access.cases.txt`, `reflection.cases.txt`, `array8314.cases.txt` and `std.cases.txt`.
  They use the `cases.hx.txt` format, and every `@gencs` expectation is a real gencs net10.0 run.
  Divergence cases carry hxc's expected output and say where it comes from.
- **`verification.md`:** each case's status today.
- **`fixcasts.py`:** patches gencs's C# with the correct parent casts. It produced the `-fixed` cases'
  expectations.
- **`m4.cases.txt`:** cases set aside for milestone 4. Don't add them.

"Add case X from F" means: copy that case's text verbatim from F to the end of
`tests/dotnet/cases.hx.txt`.

**Branch:** `git switch -c dotnet-il-m3c main`. Don't push or open a PR.

## Decisions (made with the user before this plan; Task 1 writes them into the spec)

1. **gencs's typing is adopted.** Type-argument erasure follows types notes §1. Any `Dynamic`
   argument makes the static type the companion interface, so a typed value passed to an
   `X<Dynamic>` slot is the same object; there is no view and no copy. The hxgeneric "native
   generic" scan (§0.9) is included.
2. **Every parent cast is correct.** gencs's `P_cast<…>() { return this.X_cast<own params>(); }`
   always returns `this`. hxc emits types notes §4's rule instead, for interfaces and superclasses,
   std's maps included. This is a deliberate divergence like #8314.
3. **#8314 forwarding triggers on any cast of a non-forwarding ``Array`1<object>`` to a basic-element
   `Array`** (`Int`, `Float`, `Bool`, `String`, `UInt`, `Single`, `Int64`, …), whatever its static
   source. A cast between two typed instantiations still copies, as hxcs does, and so does a second
   reinterpretation to a different type.
4. **Paths where gencs throws but hxc's design works are left working**, and each is recorded as a
   divergence:
   - `return d` of a `Dynamic` as `Array<Int>`, which skips `__hx_cast` in gencs;
   - closure calls;
   - `map`/`filter` on a typed array held as `Array<Dynamic>`;
   - `Array<Int>` passed as `Array<Any>` (a C# compile error in gencs).
5. **These hxcs bugs that data depends on are reproduced:**
   - the map and `List` copy shares `hashes`/`_keys` with the original, which then gains `k => null`
     (casts fact 9);
   - `getResponseHeaderValues` NREs;
   - the Unserializer throws `ArgumentException` on enum constructor arguments of array or map type;
   - Json prints `"Box_cast":null`.

Rulings made for this plan (recorded in the 3c ledger at execution time):
- **`length` stays a public field.** A target keeps a back-reference `__hx_from` to its forwarder and
  writes `__hx_from.length` wherever it writes its own `length` (casts §2.3). hxc can't emit CLR
  properties yet.
- **The forward is installed under `Monitor.Enter(this)`/`Exit(this)`.** hxc has no `ref` arguments
  for `Interlocked`.
- **`-0.0` converts losslessly into `Int`.** `genericCast` gives 0, and the Serializer writes `z` for
  both.
- **`Reflect.field(a, "__a")` on a forwarder returns the stale storage**, as gencs's untyped original
  would.
- **The companion interface's members are copied exactly** (types §3), and so are the
  `IG__Statics_` holders. Array's `object this[int]` indexer comes from hxcs's `@:classCode`, which
  is milestone 4. Without it, `Array<Dynamic>` element access goes through `Runtime.callField`
  `"__get"`/`"__set"`, as hxc already does for `Dynamic` arrays. `get_Item`/`set_Item` are missing
  from `getInstanceFields(Array)`, and that difference is recorded.
- **`haxe.Resource` waits for milestone 4.** It needs manifest resources and harness support, and
  milestone 4 already lists `-resource`. 3c unblocks only its `StringMap` cast.
- **Still stubbed after 3c, all waiting for milestone 4:** `Thread.create`, `EReg.matched`,
  `Socket.select`/`setTimeout`, `Sys.command` and `Process`.
- **`-dce no` dropping `EnumValueMap`** ("interface methods implemented by a final inherited method")
  predates 3c and stays out of it.

## Global Constraints

- **3a's constraints still hold:**
  - `net10.0`; `--cs <dir> -D dotnet`; `-D dll-name`;
  - byte-identical output between two compiles;
  - hxc writes PE/IL itself;
  - ILVerify on every test assembly;
  - no silent miscompiles;
  - the code style of `src/hxc/codegen/jvm/` and of the surrounding dotnet code;
  - commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Match gencs.** Whatever stored data, reflection or the C# side can observe behaves like Haxe 4.3.7
  gencs + hxcs, hxcs bugs included, except for the deliberate divergences above. The oracle is gencs's
  C# built for `net10.0` with `tests/dotnet/gencs.csproj.in`.
- **CLR names follow gencs.** Companion interfaces are `<pack>.<Class>` with no arity. Cast methods
  are `<flatpath>_cast` (`G_cast`, `haxe_ds_StringMap_cast`) with type parameters `<T_c…>`, and the
  static helper is `__hx_cast<T_c_c…>`. The attribute is `haxe.lang.GenericInterface(typeof(X<object…>))`,
  and the base interfaces are `haxe.lang.IHxObject` and `haxe.lang.IGenericObject`. Interface static
  helpers go in `<pack>.<Iface>__Statics_`. Member order is as types notes §3 lists.
- **hxc's runtime copy contains no `__cs__`, `cs.Syntax.code`, `@:functionCode` or `@:classCode`.**
- **Unsupported constructs are clean errors.** In user code, anything not supported yet is an
  `Unsupported` error at the construct's position, never an internal error and never a crash. In std
  code it becomes a stub.
- **Cases are compiled without `-debug`.**
- **Commands used below:**
  - BUILD: `AEDIFEX_ROOT=D:/_github/hxc-toolchain/aedifex/ HAXE_STD_PATH=C:/HaxeToolkit/haxe/std HXCPP_COMPILE_CACHE=D:/_github/hxc-toolchain/hxcpp-cache haxelib run aedifex build cpp .`
  - CASE `<name>`: `MSBUILDDISABLENODEREUSE=1 timeout 900 tests/dotnet/run.sh --compiler bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --case <name>`
  - ALL: the same without `--case`, under `timeout 3600`; expected `all N cases passed`.
  - OWN: `cd D:/_github/haxe-conformance && neko run.n run --compiler D:/_github/hxc/bin/cpp/windows/x64/release/bin/hxc.exe --std C:/HaxeToolkit/haxe/std --cases D:/_github/hxc/tests/cases --expected D:/_github/hxc/tests/expected -j 4`; expected `0 failed`.

## Review Focus

1. **Two threads making the first cast of one unserialized array at once.** Both must get the same
   target, with no lost element, deadlock or exception. Haxe code can't start a thread until
   milestone 4 brings delegate conversion, so `cast-array-threads` is set aside in `m4.cases.txt`.
   The test drives the race from C# instead, the way `@stress-fieldlookup` already drives
   `FieldLookup`. Test: a new `@stress-arrayforward` tag and HxcCheck mode, in Task 9.
2. **The server app's `-dce full`.** Companion interfaces, cast methods and `Type.resolveClass` of a generic
   class that is only reached through serialized data must survive DCE exactly as gencs keeps them.
   Test: `generic-classes-dce-full @gencs + -dce full -D analyzer-optimize -D net-ver=40` in Task 7.
3. **Array's surface to the server app's C# and to reflection.**
   - `length` stays a public field: `Importer.cs` builds `new Array<string>()` and reads `.length`.
   - `__hx_fwd`/`__hx_from` never show in `Reflect.fields`, `Type.getInstanceFields` or
     `haxe.Serializer` output.
   - ``Array`1`` keeps its arity and namespace.

   Test: `array-clr-surface @gencs` in Task 9.
4. **Constructing a generic subclass after erasure.** `class Sub<U> extends G<U>`,
   `class SubI extends G<Int>` and `class SubC extends G<C>`, each with a super call and field
   initializers. These run through gencs's `__hx_ctor__G<T_c>` helper, which erasure re-instantiates.
   Test: `generic-subclass-construction @gencs` in Task 2.
5. **Generic-class data written by one build and read by the other.** A class with `Map<String,C>`,
   `Array<Int>`, `List<String>` and `G<C>` fields, serialized by hxc and unserialized by gencs, and
   the reverse. Test: `serial-generic-classes @serial + -D net-ver=40` in Task 11.

---

## File structure

| File | Responsibility |
| --- | --- |
| `src/hxc/codegen/dotnet/HxGeneric.hx` (new) | Which generic Haxe classes and interfaces are "hxgeneric", plus gencs's native-generic scan |
| `src/hxc/codegen/dotnet/DotnetTypes.hx` | `toSig`'s type-argument mapping (erasure), and the companion static type for `Dynamic` arguments |
| `src/hxc/codegen/dotnet/CompanionToIl.hx` (new) | Companion interfaces, `X_cast`, parent casts, `__hx_cast`, `__Statics_` holders |
| `src/hxc/codegen/dotnet/InstantiationCasts.hx` (new) | Emitting the cast wherever a value changes instantiation |
| `src/hxc/codegen/dotnet/TexprToIl.hx`, `TexprCalls.hx`, `TexprDynamic.hx`, `TexprFlow.hx` | Calling `InstantiationCasts`; access through companion types; `isOfType`/`catch` of generic classes |
| `src/hxc/codegen/dotnet/TclassToIl.hx`, `ReflectionMembers.hx`, `EnumToIl.hx` | The class side of companions, erased-interface overloads, `__hx_setField` casts, generic enum arguments |
| `src/hxc/codegen/dotnet/runtime/Array.hx` (new) | hxc's copy of hxcs's `Array` with the #8314 forward |
| `src/hxc/codegen/dotnet/runtime/cs/internal/Runtime.hx`, `runtime/Type.hx`, `runtime/Std.hx` | `eq` resolving forwards; `resolveClass`/`isOfType` through companions; retiring 3b's `Null` workarounds |
| `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md` | The revised generic-casts section |
| `tests/dotnet/cases.hx.txt`, `README.md` | Cases; the .NET feature list |

---

### Task 1: Revise the spec's generic-casts section

The section *Casts between generic instantiations (Haxe issue 8314)* was written before the research,
and parts of it are wrong. Rewrite it to the decisions, so every later task argues from a correct spec.

**Files:**
- Modify: `docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md`

**Interfaces:**
- Produces: the spec text that Tasks 2-12 cite.

- [ ] **Step 1: Correct "What hxcs does"**

Add these facts, citing the notes:
- gencs erases non-basic type arguments to `object` (types §1). So data from the Unserializer and
  Json shares storage with `Array<C>`/`Map<String,C>` slots, and only basic-argument instantiations
  copy.
- A typed value passed to an `X<Dynamic>` slot is the same object, through the companion interface.
  Delete "Going the other way … copies too".
- `genericCast` to `Int` rounds half to even (`1.5` → `2`).
- The map and `List` copy corrupts the original (casts fact 9).
- `Type.resolveClass("G")` is ``typeof(G`1<object>)``.

- [ ] **Step 2: Rewrite the decided design**

Rewrite the design from Decisions 1-5 and the rulings above:
- Erasure, and companion typing for `Dynamic` arguments.
- The forward, for basic-element targets only, triggered by any cast of a non-forwarding
  ``Array`1<object>``.
- Delete "A view the other way". It's unnecessary, because typed→`Array<Dynamic>` is an upcast.
- `length` as a field kept in sync. Remove the `(My call:)` property sentence.
- The `Monitor` install.
- "A wrong-typed write converts": add that typed code over an erased ``Array`1<object>``, such as an
  `Array<Null<Int>>` view of a reinterpreted array, also sees conversions (`push(null)` → `0`).
- Nested arrays: the outer array is ``Array`1<object>`` and never converts. Each inner array converts
  when an element read casts it.
- The server app also depends on `amf3haxe…ArrayCollection<T>` and promhx's `Promise/Stream/Deferred/AsyncBase<T>`,
  all same-instantiation under gencs.
- Add a paragraph on the parent-cast divergence (Decision 2) next to the 8314 one, with the
  `FallbackPromise<T> implements Thenable<T>` example and the rule from types §4.
- List the recorded divergences: Decisions 2-4, and the missing Array indexer.

- [ ] **Step 3: Commit**

Commit: `Revise the .NET spec's generic-casts section to gencs's erasure and companion typing`.

---

### Task 2: Type-argument erasure

**Files:**
- Create: `src/hxc/codegen/dotnet/HxGeneric.hx`
- Modify: `src/hxc/codegen/dotnet/DotnetTypes.hx` (`toSig`, around line 394, and the type-argument
  mapping at about 413-453), `GenerateDotnet.hx`, `TexprToIl.hx` (`boxTypeParam`, around 363),
  `TexprOps.hx` (about 700), `runtime/cs/internal/Runtime.hx` (`genericCast`, `__hx_boxTypeParam`,
  about 676-714) and `runtime/Type.hx` (`allEnums`, about 335-340)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `DotnetTypes.inferParams` (3b), which picks the Haxe type bound to each method type
  parameter. Keep it as is.
- Produces:
  - `HxGeneric.isHxGeneric(g:DotnetCtx, c:TClass):Bool`, cached per class. It is true for a generic
    hxgen class or interface that isn't `@:nativeGen` and passes types §0.9's field scan. It is false
    for non-generic classes.
  - `DotnetTypes.typeArg(t:T):IlSigNorm`, the §1 mapping of one argument of an hxgeneric
    instantiation.
  - `DotnetTypes.hasDynamicArg(params:Array<T>):Bool`, which follows typedefs and `Null<>`. Task 5
    uses it; this task leaves `X<Dynamic>` as ``X`1<object>``.

- [ ] **Step 1: Add the cases and see them fail**

Add from `erasure.cases.txt`: `type-argument-erasure`, `erasure-edge-rules`,
`native-generic-classes`, `method-type-argument-erasure`, `generic-instance-class-names`,
`all-enums-type` and `null-binding-casts-ret`.

Remove the existing cases `null-type-parameter-binding-refusal` and
`null-type-parameter-binding-local-refusal`, which pinned refusals that `null-binding-casts-ret`
replaces.

Add `generic-subclass-construction @gencs` (Review Focus 4). It covers `class G<T>` with a field
initializer and a constructor taking `T`; `Sub<U> extends G<U>`; `SubI extends G<Int>`; and
`SubC extends G<C>`. Each calls `super(...)`. The case prints `Std.string(Type.getClass(x))` and the
field values of each; no `[run]`.

CASE each. They should fail on names (``G`1[C]`` against ``G`1[System.Object]``) or with today's
refusals.

- [ ] **Step 2: Implement `HxGeneric` and `typeArg`**

`typeArg` follows the rule in types §1:
- type parameters stay;
- basic types map to their CLR type, including abstracts over basic types, .NET structs and enums,
  and `@:nativeGen` flat enums;
- `String`, `Null<String>` and abstracts over `String` map to `string`;
- everything else maps to `object`, including every `Null<X>` other than `Null<String>`.

`toSig` applies it to the arguments of every hxgeneric instantiation, whether it appears in a field,
local, parameter, return, `new`, method instantiation or closure-class instantiation (types §2).

The arguments of a non-hxgeneric generic (.NET generics, `@:nativeGen` classes, native-generic Haxe
classes) keep their real types. The exception is `Null<X>` of a value type, which becomes `object`.
Their own arguments then map by their own rule.

Haxe enums stay non-generic. 3b's `inferParams` result is mapped through `typeArg` too, so no type
argument is ever ``haxe.lang.Null`1<X>``.

- [ ] **Step 3: Retire 3b's `Null`-in-type-argument workarounds**

None of these can be reached any more (types §2, §9.10):
- `Runtime.__hx_boxTypeParam` and its call sites, including `TexprToIl.boxTypeParam`'s runtime call
  and `TexprOps` around line 700. They go back to a plain box, as hxcs does.
- `genericCast`'s `mkNullable` branch.
- `runtime/Type.hx`'s `allEnums` patch, which goes back to hxcs's text.

Check that the cases 3b's final review added still pass: `null-type-argument-inference`,
`null-return-type-inference`, `null-type-arguments` and `serial-null-type-arguments`.

- [ ] **Step 4: Run them**

CASE each case from Step 1; expected `ok`. Existing cases whose expectations name an un-erased
instantiation may change, and only to gencs's output. A `@gencs` case already compares against
gencs. For a case with a hand-written `[run]`, check the new line against a gencs run before changing
it.

- [ ] **Step 5: Run everything and commit**

ALL, then OWN. Commit: `Erase non-basic generic type arguments to object as gencs does`.

---

### Task 3: Bind an abstract's own type parameters on its implementation calls

The desktop app's 117 `thenshim.Thenable` errors are this bug, not casts (casts fact 7).
`abstract Pr<T>(Th<T>)`'s `then<R>` compiles to `Pr_Impl_.then<R,T>(this1:Th<T>, …)`. hxc doesn't
bind the abstract's own `T` at the call, and refuses it. A plain static generic works.

**Files:**
- Modify: `src/hxc/codegen/dotnet/DotnetTypes.hx` (`inferParams` and its callers), or the call site
  in `TexprCalls.hx` that builds the impl call's instantiation
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 2's `typeArg`.
- Produces: nothing other tasks call.

- [ ] **Step 1: Add the case**

Add `abstract-impl-type-parameters @gencs`, with the program from
`D:/_hxc3c/casts/probe/thenable/P.hx` verbatim and no `[run]`. gencs prints `1`, `a`, `1` and calls
`then<object,int>((Th<int>) …)`. Also add a second module-level abstract shaped like haxeui's
`DataSource`: a generic `@:from` static plus a function-typed `T`. Take its exact text from
`D:/_hxc3c/casts/probe/thenable2/P.hx`, and keep only lines gencs runs. CASE it: expected FAIL ("a
cast between instantiations of Th").

- [ ] **Step 2: Implement**

Bind the abstract's type parameters from the receiver argument's type (the `this1` parameter). Then
bind the method's own parameters by 3b's rule, and map both through `typeArg`.

- [ ] **Step 3: Run it, everything, and commit**

CASE: expected `ok`. Then ALL. Commit: `Bind an abstract's type parameters on its implementation calls for .NET`.

---

### Task 4: Companion interfaces and cast methods

This task is emission only. Nothing calls the cast methods yet; Task 5 does.

**Files:**
- Create: `src/hxc/codegen/dotnet/CompanionToIl.hx`
- Modify: `src/hxc/codegen/dotnet/TclassToIl.hx` (`planClass`, `interfaceClosure` and the class's
  interface list), `GenerateDotnet.hx` (declaring companions before classes) and
  `ReflectionMembers.hx` (only if member order needs it)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `HxGeneric.isHxGeneric`, `DotnetTypes.typeArg`.
- Produces:
  - `g.companionOf(c:TClass):IlSigNorm`, the companion interface type of an hxgeneric class or
    interface;
  - `g.castHelperOf(c:TClass):Int`, the method token of the static `__hx_cast<T_c_c…>(X me):object`.
    For an interface, the helper lives on `<Iface>__Statics_`;
  - `CompanionToIl.declare(g:DotnetCtx, c:TClass):Void` and `CompanionToIl.emit(g:DotnetCtx, c:TClass):Void`.

- [ ] **Step 1: Add the cases and see them fail**

Add from `companions.cases.txt`: `companion-members`, `type-argument-clr-shapes` and
`cast-member-order`. CASE each. `interface-cast-fixed` and `superclass-cast-fixed` go in Task 5,
because they need its call sites.

- [ ] **Step 2: The companion interface**

Follow types §3:
- the name and namespace;
- `[haxe.lang.GenericInterface(typeof(X<object…>))]`;
- base interfaces `IHxObject` and `IGenericObject`, plus the superclass's companion for a subclass;
- members in this order: own `X_cast<T_c…>()`, the cast methods of implemented generic interfaces
  that the superclass doesn't already implement, the superclass's cast redeclared, then every kept,
  non-static, non-dynamic, non-override method the class declares whose Haxe signature mentions no
  type parameter.

A generic interface `IG<T>` keeps only its T-mentioning members. Its companion takes `IG_cast` plus
the rest, and its static helper goes on `IG__Statics_`.

- [ ] **Step 3: The class side**

After the constructors and `__hx_ctor__X`, emit:
- `public static object __hx_cast<T_c_c…>(X me)`, which returns `me != null ? me.X_cast<T_c_c…>() : null`.
  A generic subclass hides it with `new`.
- `public virtual object X_cast<T_c…>()`, with gencs's body quoted in types §3. It returns `this`
  when `Runtime.eq(typeof(T), typeof(T_c))` holds for every parameter. Otherwise it builds `new X<T_c…>(EmptyObject.EMPTY)` and copies
  every field with `Reflect.fields`/`field`/`setField`. A `cs.NativeArray<T>` field is copied element
  by element through `Runtime.genericCast<T_c>`, skipping nulls; a `NativeArray<Array<T>>` field goes
  through `Array<object>.__hx_cast<T_c>`. It is non-virtual in a final class, and an `override` in
  a generic subclass.
- One parent cast per generic interface (deep) and generic superclass. Its body is
  `return this.X_cast<b1..bn>();`, with each `bk` chosen by types §4's rule (Decision 2). Order:
  own interfaces deep, then the superclass's list, then the superclass, keeping the last occurrence
  of a duplicate (types §3).
- A non-generic class implementing a generic interface gets `IG_cast<T_c>() { return this; }`.

The class's CLR interface list gains the companion, `IGenericObject` and the parents' companions.

- [ ] **Step 4: Run them**

CASE each: expected `ok`.

- [ ] **Step 5: Run everything and commit**

ALL: every case that passed before still passes. `Type.getInstanceFields` lists now start with
`X_cast`; update only cases whose gencs output already shows that. Commit:
`Emit companion interfaces and cast methods for generic Haxe classes`.

---

### Task 5: Casts between instantiations

**Files:**
- Create: `src/hxc/codegen/dotnet/InstantiationCasts.hx`
- Modify: `src/hxc/codegen/dotnet/TexprToIl.hx` (`coerce`, around 254-306;
  `checkInstantiationCast`, around 527; `checkedInstanceCast`, around 539; `castTo`, around 559),
  `ReflectionMembers.hx` (`fromDynamic`, around 371) and `TexprDynamic.hx` (`toSig`, around 242)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `g.companionOf`, `g.castHelperOf`, `DotnetTypes.typeArg`.
- Produces: `InstantiationCasts.emit(g:DotnetCtx, code:IlCode, from:IlSigNorm, to:IlSigNorm):Void`.
  It leaves the value on the stack typed as `to`:
  - nothing, when the erased instantiations are equal;
  - otherwise `castclass companion`, then `X<object…>.__hx_cast<to's args>`, then `castclass to`.

  For a generic-interface target the helper is on `__Statics_`.

- [ ] **Step 1: Add the cases and see them fail**

Add from `casts.cases.txt`: `cast-map-member` (it includes the server app's enum-keyed `Map` downcast shapes),
`cast-generic-copy`, `typed-instantiation-casts`, `cast-interface`, `cast-same-instantiation`,
`cast-contexts`, `cast-contexts-working` (Decision 4's `return` and closure-call lines),
`generic-cast-matrix`, `null-binding-casts-fa` and `map-fields-in-classes`.

Also add `interface-cast-fixed` and `superclass-cast-fixed` from `companions.cases.txt`. They aren't
`@gencs`: they are Decision 2's divergence. Their `[run]` comes from gencs's C# patched by
`fixcasts.py` in the test-material folder, which applies types §4's rule.

Leave `cast-same-instantiation-8314` and `generic-cast-matrix-8314` for Task 9; they need the Array
forward. Remove the existing case `null-return-type-inference-refusal`, which `null-binding-casts-fa`
replaces.

CASE each: expected FAIL ("a cast between instantiations of …").

- [ ] **Step 2: Replace every refusal and checked cast**

- `castTo` and `coerce` call `InstantiationCasts.emit` for every cast whose source and target are
  instantiations of the same hxgeneric class, or a generic interface it implements. That includes the
  `Map` abstract's `@:multiType` downcast of `IMap<K,V>` to its specialization, which is the bulk of
  the server app's errors (casts §3).
- `checkInstantiationCast`'s compile-time refusal and `checkedInstanceCast`'s
  `NotSupportedException` are replaced by the same call.
- `ReflectionMembers.fromDynamic` (`__hx_setField` into a generic field) and `TexprDynamic.toSig` use
  it too, as gencs's `__hx_setField` does (types §5).

Contexts follow casts §1.1: assignments, arguments, field reads and writes, array literals and `cast`.
Per Decision 4, also cast on `return` and on closure-call arguments, where gencs skips the cast and
throws. A typed→`Dynamic` cast needs no call.

- [ ] **Step 3: Run them**

CASE each: expected `ok`. The copy cases must show gencs's corruption of the original (Decision 5).

- [ ] **Step 4: Run everything and commit**

ALL. Commit: `Cast between generic instantiations through __hx_cast for .NET`.

---

### Task 6: `Dynamic`-argument instantiations typed as companions

**Files:**
- Modify: `src/hxc/codegen/dotnet/DotnetTypes.hx` (`toSig`), `TexprCalls.hx` (field reads/writes and
  calls on a companion-typed receiver), `TexprDynamic.hx`, `TexprToIl.hx`, `EnumToIl.hx` (generic enum
  arguments, around 152-159)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `DotnetTypes.hasDynamicArg`, `g.companionOf`, `InstantiationCasts.emit`.
- Produces: `DotnetTypes.isCompanionTyped(t:T):Bool`. Tasks 7-9 use it.

- [ ] **Step 1: Add the cases and see them fail**

Add from `companion-access.cases.txt`: `companion-access`, `companion-access-array-any` (Decision 4:
`Array<Int>` passed as `Array<Any>`, which gencs can't compile), `cast-array-view` and
`generic-enum-arguments`. CASE each.

- [ ] **Step 2: Static type**

A type with any `Dynamic` argument maps to the companion in every static position, and a `new` of it
is `X<object…>` (types §1). Typed→companion is a plain upcast.

- [ ] **Step 3: Access through a companion**

Follow types §5's table:
- a field or method whose Haxe signature mentions a type parameter goes through `Runtime.getField`,
  `getField_f`, `setField`, `setField_f` or `callField`. Use the hashes the table lists (`length`
  520590566, `push` 1247875546, `get` 5144726, …), or compute them with hxc's existing field-hash
  function, which must give the same values. A `callField` with no arguments passes `null`;
- T-free members are interface calls on the companion;
- `Array<Dynamic>`'s `a[i]` and `a[i] = v` are `callField(a, "__get"/"__set", …)` (ruling: no
  indexer);
- inlined `Array` members (`map`, `filter`, `iterator`) run over a companion-typed receiver through
  the same dynamic paths. Per Decision 4 they work on a typed array held as `Array<Dynamic>`.

Generic enum arguments `Array<T>` and `G<T>` become companion-typed fields and factory parameters,
which replaces the "enum arguments of generic class types" refusal.

- [ ] **Step 4: Run them, everything, and commit**

CASE each: expected `ok`. Then ALL. Commit: `Type Dynamic-argument generic instantiations as companion interfaces for .NET`.

---

### Task 7: Generic classes in reflection and type tests

**Files:**
- Modify: `src/hxc/codegen/dotnet/TexprDynamic.hx` (`isOfType`, around 691-715), `TexprFlow.hx`
  (`catch` of a generic class), `runtime/Type.hx` (`resolveClass`, `getInstanceFields`,
  `getClassFields`, `createInstance`, `createEmptyInstance`) and `runtime/Std.hx` (`isOfType` with a
  class value, `downcast`, `instance`)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `g.companionOf`, `DotnetTypes.isCompanionTyped`.
- Produces: nothing other tasks call.

- [ ] **Step 1: Add the cases and see them fail**

Add from `reflection.cases.txt`: `generic-reflection`, `resolve-generic-class`, `generic-is-of-type`,
`catch-generic-class`, `serverapp-generic-tools` and `list-lambda-generics`. The last two are regression
pins and already pass.

Add `generic-classes-dce-full @gencs + -dce full -D analyzer-optimize -D net-ver=40` (Review Focus 2).
It is a class `Box<T>` and a `Map<String,Box<Int>>` field reached only through
`haxe.Unserializer.run` of a string literal that gencs's `Serializer` wrote. It prints the round trip,
`Type.resolveClass("Box")` and `Type.getInstanceFields` of it; no `[run]`.

CASE each.

- [ ] **Step 2: Implement**

- `Std.isOfType(x, G)`, `x is G`, `Std.downcast`, `Std.instance` and `cs.Lib.as` with a constant
  generic class test the companion (types §5). Today `downcast` silently answers wrong (std §3.1).
- `Std.isOfType(v, t)` with a class value finds the interface whose
  `GenericInterface.generic == t`, as hxcs's `Std.hx:54-66` does.
- `catch (e:Array<Dynamic>)` and `catch (e:G<Dynamic>)` test and bind the companion.
- `Type.resolveClass("G")` finds the companion by name and returns its attribute's
  ``typeof(G`1<object>)``. It returns null for a native generic.
- A class constant `G` in Haxe code is ``typeof(G`1<object>)``.
- `getInstanceFields`, `createInstance` and `createEmptyInstance` work on the result.

- [ ] **Step 3: Run them, everything, and commit**

CASE each: expected `ok`. Then ALL. Commit: `Resolve and test generic Haxe classes through their companions for .NET`.

---

### Task 8: Erased generic interface implementations

**Files:**
- Modify: `src/hxc/codegen/dotnet/TclassToIl.hx` (`interfaceImpls` and bridges, around 518-606)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `DotnetTypes.typeArg`; Task 4's interface casts.
- Produces: nothing other tasks call.

- [ ] **Step 1: Add the cases and see them fail**

Add from `reflection.cases.txt`: `erased-interface-overload` and
`explicit-impl-erased-generic-interface`. CASE each.

- [ ] **Step 2: Implement**

When `Q implements IQ<C>` erases to ``IQ`1<object>``, emit gencs's shape before `C f(C x)` (types §3,
3b ledger line 183): a public virtual `object f(object x)` overload that casts and calls the typed
method. A member whose signature doesn't change keeps today's direct implementation. Where gencs
emits an explicit implementation instead, as std §2 L7 lists for return-only differences, copy it.

- [ ] **Step 3: Run them, everything, and commit**

CASE each: expected `ok`. Then ALL. Commit: `Implement erased generic interfaces with gencs's overloads for .NET`.

---

### Task 9: The #8314 Array forward

**Files:**
- Create: `src/hxc/codegen/dotnet/runtime/Array.hx`. Copy it from `C:/HaxeToolkit/haxe/std/cs/_std/Array.hx`
  and change it as below. The runtime root is first on the class path, so it shadows std (casts §2.1).
- Modify: the std call sites that read `__a` directly (`cs.Lib.nativeArray`, `haxe.Rest.of`). Add
  runtime copies of those, or route them through a resolving accessor.
- Modify: `tests/dotnet/run.sh` and `tests/fixtures/hxccheck/Program.cs`, for the `@stress-arrayforward`
  mode.
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Task 4's `Array_cast<T_c>`, Task 5's call sites.
- Produces: private runtime members `__hx_fwd:Dynamic`, `__hx_from:Array<Dynamic>` and
  `__hx_resolve():Array<Dynamic>`. They are hidden from `Reflect.fields`, `Type.getInstanceFields` and
  the Serializer.

- [ ] **Step 1: Add the cases and see them fail**

Add from `array8314.cases.txt`: `cast-array-convert`, `cast-array-lossless-serial`,
`cast-8314-issue`, `cast-array-dynamic-write`, `cast-array-nested`, `nested-array-element-cast`,
`cast-box-array-field` and `array-dynamic-view-members`. Add from `casts.cases.txt`:
`cast-same-instantiation-8314` and `generic-cast-matrix-8314`.

Add the race test (Review Focus 1):
- In `run.sh`, add a tag `@stress-arrayforward` next to `@stress-fieldlookup`.
- In `tests/fixtures/hxccheck/Program.cs`, add a mode `stress-arrayforward <dll>`. Each round it
  calls the case assembly's static `P.make():Array<Dynamic>`, which returns a fresh ``Array`1<object>``
  of ints such as `[1,2,3]` built through `haxe.Unserializer`. It starts 8 threads behind a barrier;
  each casts that one array with `P.toInts(a:Dynamic):Array<Int>` and pushes `i` onto the result.
- The mode passes when, in every round of 200, all threads got the same ``Array`1<int>`` instance,
  its length is 3 + 8, and the original's `length` equals it.
- Add the case `array-forward-race @stress-arrayforward` with that `P` and a `main` that prints `ok`.

Add `array-clr-surface @gencs` (Review Focus 3). It reflects over ``Array`1``: `length` is a public
`Int32` field; the namespace, name and arity are unchanged; and `Reflect.fields`,
`Type.getInstanceFields(Array)` without `get_Item`/`set_Item`, and `haxe.Serializer.run` of a
reinterpreted array show no `__hx_` member. Leave out the lines gencs prints from the `@:classCode`
indexer.

CASE each.

- [ ] **Step 2: The cast**

``Array`1<T>.Array_cast<T_c>`` follows casts §2.4:
- return `this` when the types are equal;
- return the existing forward if it is an `Array<T_c>`;
- a second, different type is copied from the forward target;
- for a basic `T_c`, when every element converts losslessly, build the target, set
  `target.__hx_from = this`, and install it under `Monitor`. A thread that loses the race returns the
  winner;
- otherwise use gencs's copy.

The lossless rules are in casts §1.3 and §2.4. `null` into a value type is lossy. `-0.0` into `Int`
is lossless (ruling).

- [ ] **Step 3: Every member resolves**

Follow casts §2.3's member table:
- every member that touches storage on ``Array`1<object>`` delegates to `__hx_resolve()` first;
- `map`, `filter`, `iterator`, `keyValueIterator`, `__unsafe_get` and `__unsafe_set` lose `inline`,
  which gencs also emits as real methods;
- every write of `length` also writes `__hx_from.length` when it isn't null;
- writes through a forwarder convert through `genericCast<T_target>` (spec: "A wrong-typed write
  converts").

- [ ] **Step 4: Run them, everything, and commit**

CASE each: expected `ok`. Then ALL. Commit: `Forward an unserialized Array to its typed reinterpretation (Haxe issue 8314)`.

---

### Task 10: Equality sees one array

**Files:**
- Modify: `src/hxc/codegen/dotnet/runtime/cs/internal/Runtime.hx` (`eq`, around 77-135),
  `runtime/Array.hx` (`Equals`/`GetHashCode` overrides) and `TexprOps.hx` (`==` where an operand is
  companion-typed, `Dynamic` or a type parameter)
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: `Array.__hx_resolve()`.
- Produces: nothing other tasks call.

- [ ] **Step 1: Add the case and see it fail**

Add `cast-4872-eq` from `array8314.cases.txt`. CASE it.

- [ ] **Step 2: Implement**

- `Runtime.eq` and `refEq` resolve both sides' forwards first.
- ``Array`1``'s `Equals`/`GetHashCode` compare and hash the resolved target. That covers `indexOf`,
  `lastIndexOf` and `ObjectMap` keys.
- `==` with an `Array<Dynamic>` (companion), `Dynamic` or type-parameter operand, against an operand
  that can be an Array, emits `Runtime.eq` (casts §2.6).

An ``Array`1<object>`` that isn't forwarding, and a typed array with no `__hx_from`, keep reference
identity.

- [ ] **Step 3: Run it, everything, and commit**

CASE: expected `ok`. Then ALL. Commit: `Compare an Array and its forward as one array for .NET`.

---

### Task 11: The std stubs, and the typed corpus

**Files:**
- Modify: whatever the cases expose, in the area that owns it
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: Tasks 2-10.
- Produces: nothing other tasks call.

- [ ] **Step 1: Add the cases**

Add from `std.cases.txt`: `timer-and-main-thread`, `xml-attributes`, `http-response-parsing`,
`enum-value-map-arguments`, `json-generic-values`, `serialize-generic-values`,
`cast-unserialize-typed` and `generic-class-serial`.

Add `serial-generic-classes @serial + -D net-ver=40` (Review Focus 5). Follow the `@serial` program
contract in `run.sh`'s header: `gen <file>` / `rt <in> <file>`. It holds instances of a class with
`Map<String,C>`, `Array<Int>`, `List<String>`, `G<C>` and `Map<E,Int>` fields, plus a `G<Int>` value,
with no expectation.

- [ ] **Step 2: Restore the typed corpus**

In `serial-corpus` and `serial-dates`:
- empty the program's `LATER` list, removing `classArray`;
- restore `classArray` and `classArray+cache+idx` in `serial-corpus`'s `[run]` and `[rt]`, verbatim
  from `docs/superpowers/plans/2026-10-23-dotnet-closures-enums-std/serial/expected.*.txt`, in their
  original position;
- add the `#if corpus_typed` blocks back to the case's program, and add
  `serial-corpus-typed @serial + -D net-ver=40 -D corpus_typed` with no expectation (D:/_hxc3b
  research and casts §6.10).

- [ ] **Step 3: Run them and fix**

CASE each. A difference belongs to the task whose area it is in. Fix it here with that area's file,
and list each fix in the report.

`-D dotnet-stub-report` on `timer-and-main-thread` must not list `HaxeThread.get`/`allocate`. On a
program using `Xml.parse` and `sys.Http`'s parser it must not list `Xml.*`, `readHttpResponse` or
`getResponseHeaderValues`.

- [ ] **Step 4: Run everything and commit**

ALL. Commit: `Unblock the std paths that cast between generic instantiations for .NET`.

---

### Task 12: The server app and the desktop app measurement, README

**Files:**
- Modify: `README.md`; anything the measurement shows is still 3c's
- Test: `tests/dotnet/cases.hx.txt`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Measure**

Run the nativepdf and server builds with `docs/superpowers/plans/2026-10-23-dotnet-closures-enums-std/serverapp/{dotnet,server-dotnet}.hxml`.
Run them from `<server-app>/haxe`, which is read-only, with
`HAXE_STD_PATH=C:/HaxeToolkit/haxe/std`, under `timeout`. Write the logs to `D:/_hxc3c/serverapp/`.

Also run the desktop app's probe from `<desktop-app>`, which is read-only:
`HAXE_STD_PATH=C:/HaxeToolkit/haxe/std tools/hxc-probe/run.sh <hxc.exe>`.

Group the errors by innermost cause. Report them in the task report next to 3b's numbers:
- nativepdf: 84;
- server: 876, of which 657 are generic-instantiation casts;
- The desktop app: 576, of which 540 are casts.

- [ ] **Step 2: What is left**

Every remaining error in these builds must have a cause outside 3c: milestone-4 interop, the server app's
`untyped __cs__`/`@:classCode`/`@:functionCode`, or a front-end bug already recorded. Fix any other
error, each with its own `@gencs` case.

- [ ] **Step 3: README, run everything and commit**

In the README's .NET feature list, add generic instantiations as gencs makes them, `__hx_cast`
casts, companion interfaces and the #8314 Array fix. List what is still missing: the Array indexer,
`Resource`, and the stubs that wait for milestone 4.

ALL, then OWN. Commit: `Measure milestone 3c on the server app and the desktop app`.
